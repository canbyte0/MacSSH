import AppKit
import Darwin
import SwiftTerm

/// zsh Shell Integration 手动命令帧的编解码器。
///
/// Shell 端用大写十六进制把 UTF-8 bytes 编成单行，以 `\n` 分帧：
/// - 命令内的换行不会破坏边界；
/// - 不需要在 shell 内启动 `base64` 子进程；
/// - 解码严格限长，损坏或过大帧直接丢弃。
enum ShellCommandHistoryCodec {
    static let maxCommandByteCount = 64 * 1024
    static let maxFrameByteCount = maxCommandByteCount * 2

    static func decode(hexLine: Data) -> String? {
        guard !hexLine.isEmpty,
              hexLine.count <= maxFrameByteCount,
              hexLine.count.isMultiple(of: 2)
        else {
            return nil
        }

        var decoded = Data()
        decoded.reserveCapacity(hexLine.count / 2)
        var index = hexLine.startIndex
        while index < hexLine.endIndex {
            let next = hexLine.index(after: index)
            guard let high = nibble(hexLine[index]),
                  let low = nibble(hexLine[next])
            else {
                return nil
            }
            decoded.append((high << 4) | low)
            index = hexLine.index(after: next)
        }
        guard decoded.count <= maxCommandByteCount,
              let command = String(data: decoded, encoding: .utf8),
              !command.isEmpty
        else {
            return nil
        }
        return command
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 65 + 10
        case 97...102: return byte - 97 + 10
        default: return nil
        }
    }
}

/// 在专用串行队列上组装 FIFO 字节，处理拆包、粘包和过大帧恢复。
final class ShellCommandHistoryFrameAccumulator: @unchecked Sendable {
    private var pending = Data()
    private var discardingOversizedFrame = false

    func ingest(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        pending.append(data)
        var commands: [String] = []

        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if discardingOversizedFrame {
                discardingOversizedFrame = false
                continue
            }
            if let command = ShellCommandHistoryCodec.decode(hexLine: Data(line)) {
                commands.append(command)
            }
        }

        if pending.count > ShellCommandHistoryCodec.maxFrameByteCount {
            // 当前无换行的帧已超限：丢弃已收到部分，并一直忽略到
            // 下一个换行，避免把后续片段误当成新命令。
            pending.removeAll(keepingCapacity: true)
            discardingOversizedFrame = true
        }
        return commands
    }
}

/// 单个本地 zsh 会话的手动命令事件通道。
///
/// App 创建 `0700` 私有目录 + `0600` FIFO，zsh `preexec` 只在命令真正
/// 开始执行前写入帧。该通道不读键盘、不读终端输出，也不会捕获
/// password prompt、REPL 或 tmux 内部输入。
final class ShellCommandHistoryChannel: @unchecked Sendable {
    let fifoPath: String

    private let lifecycleLock = NSLock()
    private var readSource: DispatchSourceRead?

    init?(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        onCommand: @escaping @Sendable (String) -> Void
    ) {
        let directoryURL = temporaryDirectory.appendingPathComponent(
            "MacSSH-command-history-\(UUID().uuidString)",
            isDirectory: true
        )
        let fifoURL = directoryURL.appendingPathComponent("events.fifo")
        fifoPath = fifoURL.path

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        guard mkfifo(fifoPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            try? fileManager.removeItem(at: directoryURL)
            return nil
        }

        let fileDescriptor = open(fifoPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            try? fileManager.removeItem(at: directoryURL)
            return nil
        }

        let accumulator = ShellCommandHistoryFrameAccumulator()
        let queue = DispatchQueue(label: "com.macssh.shell-command-history")
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    for command in accumulator.ingest(Data(bytes.prefix(count))) {
                        onCommand(command)
                    }
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                break
            }
        }
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
            // Shell 成功打开 FIFO 后会先移除入口；若尚未打开，此处
            // 统一清理该通道自己的随机私有目录。
            try? FileManager.default.removeItem(at: directoryURL)
        }
        readSource = source
        source.resume()
    }

    deinit {
        close()
    }

    /// 幂等停止监听；描述符与私有目录由 cancel handler 收敛。
    func close() {
        lifecycleLock.lock()
        let source = readSource
        readSource = nil
        lifecycleLock.unlock()
        source?.cancel()
    }
}

/// 单个本地 zsh 会话的粘贴高亮控制通道。
///
/// App 通过仅当前用户可访问的命名管道发送 `1` / `0`；zsh 的 ZLE 文件描述符
/// handler 在行编辑器内部读取并重绘当前输入行。整个过程不向 PTY 输入流注入
/// 命令或按键，也不重启 Shell、不修改用户启动文件。
final class PasteHighlightControlChannel {
    /// 传给 ShellIntegration 的命名管道路径。
    let fifoPath: String

    /// App 端以读写、非阻塞方式持有管道：即使 zsh 尚未完成启动，也能先排队
    /// 最新设置；`O_CLOEXEC` 防止 fork 后该 App 端描述符泄漏到登录链。
    private var fileDescriptor: Int32 = -1
    private let directoryURL: URL

    init?(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        directoryURL = temporaryDirectory.appendingPathComponent(
            "MacSSH-paste-highlight-\(UUID().uuidString)",
            isDirectory: true
        )
        let fifoURL = directoryURL.appendingPathComponent("control.fifo")
        fifoPath = fifoURL.path

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }

        guard mkfifo(fifoPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            try? fileManager.removeItem(at: directoryURL)
            return nil
        }

        fileDescriptor = open(fifoPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            try? fileManager.removeItem(at: directoryURL)
            return nil
        }
    }

    deinit {
        close()
    }

    /// 幂等关闭描述符并删除本会话创建的私有临时目录。
    func close() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        // 目录由本对象创建且名称含随机 UUID，只清理本会话自己的控制通道。
        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// 把最新开关值写入 FIFO；两字节写入小于 `PIPE_BUF`，不会产生半条消息。
    @discardableResult
    func send(isEnabled: Bool) -> Bool {
        guard fileDescriptor >= 0 else {
            return false
        }
        let bytes: [UInt8] = isEnabled ? [49, 10] : [48, 10]
        let written = bytes.withUnsafeBytes { buffer in
            write(fileDescriptor, buffer.baseAddress, buffer.count)
        }
        return written == bytes.count
    }
}

/// 管理 Phase 2 唯一本地 Shell、PTY 和 SwiftTerm View 的生命周期。
@MainActor
final class LocalTerminalService: NSObject {
    /// View 只观察该状态对象，不直接控制 PTY 子进程。
    let session: TerminalSession

    /// 与 ManagedTerminalSession 相同的逻辑身份；endpoint 不从活动标签反推。
    let logicalSessionID: UUID

    /// SwiftTerm 官方提供的 AppKit 本地进程终端，内部使用 PTY 和异步 I/O。
    let terminalView: LocalProcessTerminalView

    /// 隐藏 SwiftTerm 整条滚动轨道，只显示与内容比例一致的短滑块。
    private let scrollIndicatorController: TerminalScrollIndicatorController

    /// 防止 SwiftUI 重建包装层时重复启动 Shell。
    private var hasStarted = false

    /// Local service 只允许一次 PTY incarnation；每次成功 attach 时递增。
    private var nextInputTargetEpoch: AgentTerminalInputTargetEpoch = 0
    private var currentMutationEndpoint: AgentLocalTerminalMutationEndpoint?
    private var endpointPreparationTask: Task<AgentLocalTerminalMutationEndpoint?, Never>?

    /// 每个 Local Session 独立持有控制通道，关闭会话时随 Service 一并释放。
    private var pasteHighlightControlChannel: PasteHighlightControlChannel?

    /// 每个 Local zsh Session 独立的手动命令上报通道。
    private var shellCommandHistoryChannel: ShellCommandHistoryChannel?

    /// Store 由 AppState 强持有；Service 仅作为本会话事件转发者。
    private weak var commandHistoryStore: CommandHistoryStore?

    init(
        session: TerminalSession,
        logicalSessionID: UUID = UUID(),
        commandHistoryStore: CommandHistoryStore? = nil
    ) {
        self.session = session
        self.logicalSessionID = logicalSessionID
        self.commandHistoryStore = commandHistoryStore

        // 计划书要求默认限制为 10,000 行，并使用 xterm-256color 能力。
        //
        // MacSSH 1.1 Phase 5：本地 Terminal 启用 VS16 preserve-base-width 兼容
        // 策略。macOS zsh 使用系统 wcwidth()，把 ⚠ (U+26A0)、❤ (U+2764) 等
        // emoji-VS16 基字符按 width 1 处理、VS16 (U+FE0F) 按 width 0 处理；而
        // SwiftTerm 默认会把这类基字符 + VS16 扩展为 width 2。两侧 width 不一致
        // 会导致 bracketed paste 重绘时光标列分叉，历史行漂移成 `eecho ...`。
        // 本策略保留基字符 width 1（与 zsh 一致），VS16 仍留在 grapheme cluster
        // 中（emoji presentation 不变），只改变 cell 列宽。详见
        // Docs/SwiftTermFork.md。Remote Terminal 不启用本策略（保持默认）。
        let options = TerminalOptions(
            cols: session.columns,
            rows: session.rows,
            termName: "xterm-256color",
            scrollback: 10_000,
            variationSelector16WidthPolicy: .preserveBaseWidth
        )
        let terminalView = ScrollTrackingLocalProcessTerminalView(
            frame: .zero,
            font: TerminalFontProvider.regularFont(),
            options: options
        )
        self.terminalView = terminalView
        scrollIndicatorController = TerminalScrollIndicatorController(terminalView: terminalView)

        super.init()

        terminalView.processDelegate = self
        terminalView.scrollIndicatorNeedsUpdate = { [weak self] in
            self?.scrollIndicatorController.update()
        }
        // MacSSH 1.1 Phase 4：用 TerminalAppearanceProvider 替换 SwiftTerm 的
        // `configureNativeColors()`。后者把动态 `NSColor.textBackgroundColor`
        // 经 `getTerminalColor()` 一次性解析成固定 RGB 冻结进 `Terminal`，
        // 且外观变化时永不重新解析——这是「App 进入 Dark 但 Terminal 仍白」
        // 的根因。此处只做初始应用；运行中外观变化由
        // `TerminalAppearanceCoordinator` 统一协调。
        TerminalAppearanceProvider.applyCurrentAppAppearance(to: terminalView)
        terminalView.setAccessibilityIdentifier("terminal.local")
        terminalView.setAccessibilityLabel("Local Terminal")
    }

    /// 使用账户配置中的 login shell 启动唯一的本地 PTY 会话。
    ///
    /// Phase 3：优先经 `/usr/bin/login -p -f <user>` 走 macOS 原生登录链
    /// （与 Terminal.app "Default login shell" 同构，`Last login`、SHELL、
    /// PATH、startup files 均由系统机制建立）；登录链不可用时按
    /// `LocalShellLauncher` 策略回退并记录原因。
    func startIfNeeded() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        session.processState = .starting
        if URL(fileURLWithPath: session.shellPath).lastPathComponent == "zsh" {
            pasteHighlightControlChannel = PasteHighlightControlChannel()
            if commandHistoryStore != nil {
                shellCommandHistoryChannel = ShellCommandHistoryChannel { [weak self] command in
                    Task { @MainActor [weak self] in
                        guard let self, let store = self.commandHistoryStore else { return }
                        store.append(
                            command: command,
                            sessionID: self.logicalSessionID,
                            sessionKind: "local",
                            hostDisplayName: nil,
                            source: CommandSource.manualShell.rawValue
                        )
                    }
                }
            }
        }

        let configuration = LocalShellLauncher.makeConfiguration(
            pasteHighlightControlPath: pasteHighlightControlChannel?.fifoPath,
            commandHistoryEventPath: shellCommandHistoryChannel?.fifoPath
        )
        switch configuration.strategy {
        case .systemLogin:
            AppLogger.terminal.info("Local terminal launching via system login chain")
        case let .directShell(reason):
            AppLogger.terminal.warning(
                "Local terminal falling back to direct shell launch (\(String(describing: reason)))"
            )
        }
        AppLogger.terminal.info("Local terminal resolved shell path: \(configuration.resolvedShellPath, privacy: .public)")

        terminalView.startProcess(
            executable: configuration.executable,
            args: configuration.args,
            environment: configuration.environment,
            execName: configuration.execName,
            currentDirectory: configuration.currentDirectory
        )

        if terminalView.process.running {
            session.processState = .running
            AppLogger.terminal.info("Local terminal started with account login shell")
            scheduleMutationEndpointPreparation()
        } else {
            invalidateMutationEndpoint()
            closeShellIntegrationChannels()
            session.processState = .failedToStart
            AppLogger.terminal.error("Local terminal failed to start")
        }
    }

    /// 结束本地 Shell 子进程与 PTY（关闭 Tab 时调用；幂等）。
    ///
    /// 必须真正停止子进程（任务书 19），不得只把 View 从列表移除。
    ///
    /// Phase 3 登录链说明：`terminalView.terminate()` 关闭 PTY master，
    /// kernel 向会话发送 SIGHUP / EIO 使整链退出（实证：login 与 shell
    /// 均随之终止）。但 SwiftTerm 同时取消了它的退出监视，且对 setuid
    /// root 的 `/usr/bin/login` 发 SIGTERM 会因 EPERM 无效——因此由本层
    /// 负责 `waitpid` 回收子进程并推进状态，杜绝僵尸 login 与 UI 停留
    /// running（Phase 3 任务书 49/50/51）。
    func terminate() {
        invalidateMutationEndpoint()
        guard session.processState == .starting || session.processState == .running else {
            return
        }
        terminalView.terminate()
        closeShellIntegrationChannels()
        AppLogger.terminal.info("Local terminal process termination requested")

        let pid = terminalView.process.shellPid
        guard pid > 0 else {
            session.processState = .exited(nil)
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            // 轮询 reap（进程退出后僵尸立即回收；上限 10 秒兜底，
            // 避免异常进程导致挂死）。
            var status: Int32 = 0
            var reaped = false
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    reaped = true
                    break
                }
                // 已被其他路径回收（自然退出与 terminate 的竞态）。
                if result < 0 && errno == ECHILD {
                    reaped = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            // POSIX wait status：低 7 位为 0 表示正常退出，高 8 位为退出码
            //（等价 WIFEXITED / WEXITSTATUS，Swift 下宏不可直接使用）。
            let exitedNormally = (status & 0x7F) == 0
            let exitCode: Int32? = (reaped && exitedNormally) ? ((status >> 8) & 0xFF) : nil
            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }
                // childMonitor 可能已先回调（自然退出竞态）；只在尚未
                // 到达终态时推进，绝不覆盖已提交的状态。
                if self.session.processState == .starting || self.session.processState == .running {
                    self.session.processState = .exited(exitCode)
                }
                AppLogger.terminal.info(
                    "Local terminal termination settled (reaped: \(reaped))"
                )
            }
        }
    }

    // MARK: - Agent Local Endpoint

    /// 返回当前 Local PTY incarnation 的 exact capability。
    ///
    /// endpoint 只在 SwiftTerm exclusive transaction 成功取得后创建；这个空
    /// transaction 是 attach readiness probe，不向 PTY 写入任何字节。由于
    /// `LocalProcess` 在本服务生命周期内不会重新 start/adopt，创建后的对象
    /// 永远不会指向替换后的输入 channel。
    func agentLocalTerminalMutationEndpoint() async -> AgentLocalTerminalMutationEndpoint? {
        if !hasStarted {
            startIfNeeded()
        }
        if let currentMutationEndpoint {
            return currentMutationEndpoint
        }
        guard session.processState == .running, terminalView.process.running else {
            return nil
        }
        if let endpointPreparationTask {
            return await endpointPreparationTask.value
        }
        scheduleMutationEndpointPreparation()
        guard let endpointPreparationTask else {
            return nil
        }
        return await endpointPreparationTask.value
    }

    /// 通过 SwiftTerm 自身的 exclusive API 确认 inputTransport 已 attach。
    private func scheduleMutationEndpointPreparation() {
        guard endpointPreparationTask == nil,
              currentMutationEndpoint == nil,
              hasStarted,
              session.processState == .running,
              terminalView.process.running
        else {
            return
        }

        let process = terminalView.process!
        let terminalView = self.terminalView
        let logicalSessionID = self.logicalSessionID
        endpointPreparationTask = Task { @MainActor [weak self] in
            defer { self?.endpointPreparationTask = nil }

            do {
                // 只验证固定 transport 已可取得 transaction，不发送 mutation 内容。
                try await process.inputTransport.withExclusiveInputTransaction { @Sendable _ in }
            } catch {
                return nil
            }

            guard let self,
                  self.hasStarted,
                  self.session.processState == .running,
                  process.running,
                  terminalView.process === process
            else {
                return nil
            }
            if let current = self.currentMutationEndpoint {
                return current
            }

            self.nextInputTargetEpoch &+= 1
            let endpoint = AgentLocalTerminalMutationEndpoint(
                logicalSessionID: logicalSessionID,
                inputTargetEpoch: self.nextInputTargetEpoch,
                endpointToken: AgentTerminalEndpointToken.generate(),
                process: process,
                terminalView: terminalView
            )
            self.currentMutationEndpoint = endpoint
            return endpoint
        }
    }

    /// termination 开始时撤销当前 capability；旧 endpoint 本身仍绑定旧 authority。
    private func invalidateMutationEndpoint() {
        currentMutationEndpoint?.invalidate()
        currentMutationEndpoint = nil
        endpointPreparationTask?.cancel()
        endpointPreparationTask = nil
    }

    /// 终端重新进入可见 Workspace 后恢复键盘焦点。
    func focusWhenAvailable() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let window = terminalView.window else {
                return
            }

            window.makeFirstResponder(terminalView)
        }
    }

    /// 立即同步本会话的 zsh 粘贴高亮，不向 PTY 输入任何命令或按键。
    func setPasteHighlightEnabled(_ isEnabled: Bool) {
        // 尚未启动的会话会在 `startIfNeeded()` 中直接读取最新持久化值，
        // 无需提前创建 FIFO 或排队消息。
        guard hasStarted else {
            return
        }
        // 本设置只定义本地 zsh 行编辑器行为；其他账户 Shell 保持原生。
        guard URL(fileURLWithPath: session.shellPath).lastPathComponent == "zsh" else {
            return
        }
        guard pasteHighlightControlChannel?.send(isEnabled: isEnabled) == true else {
            AppLogger.terminal.warning("Local paste highlight runtime update unavailable")
            return
        }
        AppLogger.terminal.info("Local paste highlight runtime setting updated")
    }

    /// 统一释放控制通道；进程启动失败、主动关闭和自然退出均调用。
    private func closeShellIntegrationChannels() {
        pasteHighlightControlChannel?.close()
        pasteHighlightControlChannel = nil
        shellCommandHistoryChannel?.close()
        shellCommandHistoryChannel = nil
    }
}

extension LocalTerminalService: LocalProcessTerminalViewDelegate {
    /// SwiftTerm 已在内部将新尺寸同步给 PTY；这里只更新展示状态。
    nonisolated func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {
        Task { @MainActor [weak self] in
            self?.session.columns = newCols
            self?.session.rows = newRows
            self?.scrollIndicatorController.update()
        }
    }

    /// 接收 Shell 设置的标题，不记录终端内容。
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.session.terminalTitle = title
        }
    }

    /// 接收 Shell 报告的当前目录，不主动读取用户文件。
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            self?.session.currentDirectory = directory
        }
    }

    /// 子进程结束回调可能来自 SwiftTerm 的后台 I/O 队列，统一切回主线程更新 UI 状态。
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.invalidateMutationEndpoint()
            self?.closeShellIntegrationChannels()
            self?.session.processState = .exited(exitCode)
            AppLogger.terminal.info("Local terminal process terminated")
        }
    }
}
