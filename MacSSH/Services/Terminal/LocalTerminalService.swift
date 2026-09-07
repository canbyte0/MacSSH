import AppKit
import Darwin
import SwiftTerm

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

    /// SwiftTerm 官方提供的 AppKit 本地进程终端，内部使用 PTY 和异步 I/O。
    let terminalView: LocalProcessTerminalView

    /// 隐藏 SwiftTerm 整条滚动轨道，只显示与内容比例一致的短滑块。
    private let scrollIndicatorController: TerminalScrollIndicatorController

    /// 防止 SwiftUI 重建包装层时重复启动 Shell。
    private var hasStarted = false

    /// 每个 Local Session 独立持有控制通道，关闭会话时随 Service 一并释放。
    private var pasteHighlightControlChannel: PasteHighlightControlChannel?

    init(session: TerminalSession) {
        self.session = session

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
        }

        let configuration = LocalShellLauncher.makeConfiguration(
            pasteHighlightControlPath: pasteHighlightControlChannel?.fifoPath
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
        } else {
            closePasteHighlightControlChannel()
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
        guard session.processState == .starting || session.processState == .running else {
            return
        }
        terminalView.terminate()
        closePasteHighlightControlChannel()
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
    private func closePasteHighlightControlChannel() {
        pasteHighlightControlChannel?.close()
        pasteHighlightControlChannel = nil
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
            self?.closePasteHighlightControlChannel()
            self?.session.processState = .exited(exitCode)
            AppLogger.terminal.info("Local terminal process terminated")
        }
    }
}
