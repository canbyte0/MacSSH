import AppKit
import SwiftTerm

/// Phase 7 Remote SSH Terminal 的拥有者：SwiftTerm `TerminalView` ↔ SSH Shell Channel。
///
/// 职责（任务书第 6 节）：
/// - 持有 Remote Shell 的 Channel / PTY / 输入输出 / Resize（通过 `SSHConnection`
///   actor 的 `SSHChannel.swift` 扩展执行，所有 libssh2 调用保持 actor 串行边界）。
/// - 生命周期独立于 SwiftUI View：由 `AppState` 持有，切换 Sidebar 不销毁远端 Shell。
/// - 不重新认证：只复用 `SSHService` 已认证的 `SSHConnection`，绝不重读
///   Password / Passphrase。
///
/// 数据路径：
/// - 输入：Keyboard → SwiftTerm → `TerminalViewDelegate.send` → actor `writeChannelInput`。
/// - 输出：SSH Channel → 读取循环（EAGAIN poll，无 busy-loop）→ `terminalView.feed`
///   按原始 byte stream 消费（不做 String 重编码，保护 UTF-8 / ANSI / Emoji 边界）。
/// - Resize：SwiftTerm sizeChanged → actor `resizeChannelPTY`（远端 tput cols/lines 同步）。
@MainActor
final class RemoteTerminalService: NSObject {
    /// View 只观察该状态对象。
    let session: RemoteTerminalSession

    /// SwiftTerm 官方 AppKit 终端视图；显示能力（Font/Scrollback/选择/搜索/外观）
    /// 与 Local Terminal 同源。
    let terminalView: TerminalView

    /// 已认证的 SSH 连接（actor 引用）；Channel 操作全部经由它串行执行。
    ///
    /// Reconnect（Phase 8）时通过 `reattach(connection:)` 替换为新连接；
    /// 调用前旧连接必须已完成 disconnect（SessionManager 保证顺序）。
    private var connection: SSHConnection

    /// 持续拉取远端输出的读取循环。
    private var readLoopTask: Task<Void, Never>?

    /// 打开 Channel → PTY → Shell 的任务。
    ///
    /// 用户"刚打开就关闭"时（stop 先于打开完成），必须能定位并补偿
    /// 该任务，否则它随后创建的 Shell Channel 与读取循环无人关闭，
    /// 成为孤儿 Channel（直到连接断开才被回收）。
    private var openTask: Task<Void, Never>?

    /// stop() 已请求：打开任务完成后必须关闭刚打开的 Channel。
    private var hasStopped = false

    /// 防止 SwiftUI 重建包装层时重复打开 Channel。
    private var hasStarted = false

    /// 运行时代次：每次 `reattach` 递增。打开任务与读取循环在启动时
    /// 捕获当前代次，任何延迟恢复的旧代次任务都不得再写入状态或
    /// 操作连接（P1：旧任务跨越 reattach 时硬性失效）。
    private var runtimeGeneration: UInt64 = 0

    /// stop() 屏障任务：取消旧任务并等待其完全退出 + 关闭旧连接
    /// Channel。`stopBarrier()` 等待它，使拆除成为可等待的屏障。
    private var stopBarrierTask: Task<Void, Never>?

    /// 测试接缝（确定性竞态）：读取循环判定终止事件后、提交任何
    /// 状态写入前调用。生产环境恒为 nil。
    var testReadLoopExitHook: (@MainActor () async -> Void)?

    init(connection: SSHConnection, hostname: String, port: Int) {
        self.connection = connection
        self.session = RemoteTerminalSession(hostname: hostname, port: port)

        // 与 Local Terminal 相同的显示设置来源：同字体、xterm-256color、
        // 10,000 行 scrollback（计划书第 21 节）。
        //
        // MacSSH 1.1 Phase 5：Remote Terminal **不**启用 Local Terminal 的
        // VS16 preserve-base-width 兼容策略，保持 SwiftTerm 默认的
        // `.widenToEmojiWidth`。这是有意产品决策：远端 Linux / BSD / macOS
        // 的 wcwidth / glibc / musl / libc / locale / Unicode tables 可能与本机
        // macOS 不同，Remote 的正确宽度策略不能由本机 macOS wcwidth 决定。
        // 详见 Docs/SwiftTermFork.md。
        let options = TerminalOptions(
            cols: session.columns,
            rows: session.rows,
            termName: "xterm-256color",
            scrollback: 10_000
        )
        terminalView = TerminalView(
            frame: .zero,
            font: TerminalFontProvider.regularFont(),
            options: options
        )

        super.init()

        terminalView.terminalDelegate = self
        // MacSSH 1.1 Phase 4：与 Local Terminal 同源的终端外观来源
        // （任务书第二节：Local / Remote 共用同一套外观配置）。
        // 替换 `configureNativeColors()` 以避免动态色被一次性冻结为固定 RGB；
        // 运行中外观变化由 `TerminalAppearanceCoordinator` 统一协调。
        TerminalAppearanceProvider.applyCurrentAppAppearance(to: terminalView)
        terminalView.setAccessibilityIdentifier("terminal.remote")
        terminalView.setAccessibilityLabel("Remote Terminal \(hostname)")
    }

    /// 打开 Remote Shell（幂等）：复用已认证 Session 建立 Channel → PTY → Shell，
    /// 成功后启动读取循环。初始尺寸使用当前已知值；SwiftTerm 完成 layout 后
    /// 通过 `sizeChanged` 立即同步真实尺寸。
    ///
    /// P1：打开任务在创建时捕获代次与连接——任何延迟恢复都只作用于
    /// 打开它的那条连接，绝不读取可被 `reattach` 替换的可变属性。
    func startIfNeeded() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        // stop() 先于打开到达（如 SwiftUI 重建包装层的间隙）：不打开。
        guard !hasStopped else {
            return
        }
        session.phase = .opening

        let generation = runtimeGeneration
        let openConnection = connection
        openTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                let initialColumns = session.columns
                let initialRows = session.rows
                try await openConnection.openInteractiveShell(
                    columns: initialColumns,
                    rows: initialRows
                )

                // stop() 在打开进行中到达：读取循环从未启动，无人再关这个
                // Channel——立即补偿关闭，不留孤儿。
                guard !hasStopped else {
                    await openConnection.closeShellChannel()
                    return
                }

                // 代次已更换（屏障语义下不应发生；防御）：不触碰新一代
                // 状态，只清理自己打开的 Channel。
                guard runtimeGeneration == generation else {
                    await openConnection.closeShellChannel()
                    return
                }

                // 竞态窗口：SwiftTerm 首次 layout 在打开期间完成时，其
                // sizeChanged 的 resize 因 Channel 尚未存在被丢弃。打开
                // 完成后按当前已知尺寸补偿同步一次，远端 PTY 必与视图一致。
                if session.columns != initialColumns || session.rows != initialRows {
                    do {
                        try await openConnection.resizeChannelPTY(
                            columns: session.columns,
                            rows: session.rows
                        )
                    } catch {
                        AppLogger.terminal.error("Remote PTY resize failed")
                    }
                }

                session.phase = .active
                startReadLoop()
            } catch {
                // stop() 已请求（打开被取消等）：静默退出，不更新状态。
                guard !hasStopped else {
                    return
                }
                // 代次已更换：旧代次的失败不得覆盖新一代状态。
                guard runtimeGeneration == generation else {
                    return
                }

                // 打开失败（Channel/PTY/Shell 被拒绝或连接已断）：状态明确，
                // 终端保留（无半开 Channel；连接层已清理）。
                if let terminalError = error as? RemoteTerminalError {
                    session.phase = .failed(terminalError)
                } else if let sshError = error as? SSHError,
                    sshError == .cancelled || sshError == .connectionLost
                {
                    session.phase = .connectionLost
                } else {
                    session.phase = .failed(.channelOpenFailed)
                }
                feedLocalNotice("Terminal could not be opened: \(describeOpenFailure(error))")
            }
        }
    }

    /// 停止 Remote Terminal（幂等）：取消打开与读取任务并关闭 Channel。
    ///
    /// 与 `startIfNeeded()` 的竞态（打开进行中就收到关闭）由三层补偿闭合：
    /// - 打开任务被取消后失败：`openInteractiveShell` 失败路径自身清理；
    /// - 打开恰好已完成：打开任务检测 `hasStopped` 后立即关闭 Channel；
    /// - 屏障任务的 `closeShellChannel()` 兜底（与上述并发时，
    ///   actor 内的在途等待保证互不重复释放、不留孤儿）。
    ///
    /// 需要确认旧任务**完全退出**（关闭 / Reconnect）时，必须使用
    /// `stopBarrier()` 而不是本方法。不销毁终端缓冲——用户仍可查看历史。
    func stop() {
        beginStop()
    }

    /// 可等待的拆除屏障（P1）：发起停止并等待旧打开任务、读取循环
    /// **完全退出**（含其 Channel 补偿关闭）后才返回。关闭与 Reconnect
    /// 必须经过本屏障——旧任务尘埃落定前，绝不允许 reattach 或释放
    /// 旧连接，结构性消除"旧任务跨越 reattach 恢复"的竞态。
    func stopBarrier() async {
        beginStop()
        await stopBarrierTask?.value
    }

    /// 停止的同步部分（幂等）：置标志、取消任务、登记屏障任务。
    ///
    /// 屏障任务捕获**当时的**连接与任务引用：延迟关闭绝不读取可被
    /// `reattach` 替换的可变属性（P1 修复要求）。
    private func beginStop() {
        guard !hasStopped else {
            return
        }
        hasStopped = true
        openTask?.cancel()
        readLoopTask?.cancel()

        let capturedConnection = connection
        let open = openTask
        let read = readLoopTask
        stopBarrierTask = Task { @MainActor in
            // 先等待旧任务真正退出，再关闭旧连接上的 Channel。
            await open?.value
            await read?.value
            await capturedConnection.closeShellChannel()
        }
    }

    /// 等待在途的打开任务真正结束（含其补偿关闭 Channel）。
    ///
    /// 打开任务的每个结束路径都已完成 Channel 清理：
    /// 成功后被 `hasStopped` 补偿关闭、失败被 `openInteractiveShell`
    /// 的失败路径清理、取消被 catch 分支静默吸收（同样已清理）。
    func waitForOpenTaskToFinish() async {
        await openTask?.value
    }

    /// 手动 Reconnect（Phase 8）：挂接一条全新已认证连接并复位运行时，
    /// 复用同一 `TerminalView` 保留终端历史（任务书 25）。
    ///
    /// P1：reattach 自带防御屏障——旧运行时若未完全停止，先取消并
    /// **等待**旧任务全部退出，随后才替换连接并递增代次。绝不复用
    /// 已释放的 `LIBSSH2_SESSION *` / `LIBSSH2_CHANNEL *`。
    func reattach(connection newConnection: SSHConnection) async {
        if hasStarted {
            await stopBarrier()
        }
        runtimeGeneration &+= 1
        connection = newConnection
        hasStarted = false
        hasStopped = false
        session.phase = .opening
        session.terminalTitle = nil
        session.currentDirectory = nil
        feedLocalNotice("--- Reconnected ---")
        AppLogger.terminal.info("Remote terminal reattached to a new connection")
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

    // MARK: - 读取循环

    /// 读取循环终止时携带的事件类型（先判定、后提交，中间插入测试接缝）。
    private enum ReadLoopTerminalEvent {
        case shellExited
        case readError(RemoteTerminalError)
        case cancelled
        case readTimeout
    }

    /// 持续读取远端输出并喂给 SwiftTerm；空闲时阻塞在 poll（无 CPU busy-loop）。
    ///
    /// P1：循环启动时捕获代次与连接；任何状态写入前都重新校验代次，
    /// 延迟恢复的旧代次循环绝不更新新一代 Session、绝不触碰新连接。
    private func startReadLoop() {
        let generation = runtimeGeneration
        let loopConnection = connection
        readLoopTask = Task { @MainActor [weak self] in
            await self?.readLoopBody(generation: generation, loopConnection: loopConnection)
        }
    }

    /// 读取循环主体：采集输出直到出现终止事件（EOF/错误/取消），
    /// 经测试接缝后，在代次校验通过的前提下一次性提交状态。
    private func readLoopBody(
        generation: UInt64,
        loopConnection: SSHConnection
    ) async {
        var event: ReadLoopTerminalEvent?

        while event == nil && !Task.isCancelled {
            do {
                let output = try await loopConnection.readChannelOutput()

                // 读取可能在挂起中被 reattach 跨越（测试接缝 / 异常路径）：
                // 旧代次的输出不得喂给新一代终端。
                guard runtimeGeneration == generation else {
                    return
                }

                if !output.bytes.isEmpty {
                    // 原始 byte stream 直接交给 SwiftTerm 消费，
                    // 不做 String 重编码（保护 UTF-8 / ANSI / 二进制序列边界）。
                    terminalView.feed(byteArray: output.bytes[...])
                }

                if output.isEOF {
                    // 远端 `exit` / Channel 关闭：保留屏幕与历史，标记退出。
                    event = .shellExited
                }
            } catch is CancellationError {
                event = .cancelled
            } catch let error as RemoteTerminalError {
                event = .readError(error)
            } catch let error as SSHError where error == .cancelled {
                // 用户断开：连接层已清理，读取循环安静退出。
                event = .cancelled
            } catch let error as SSHError where error == .connectionTimeout {
                // 读取等待超预算（传输长时间无响应）：按连接丢失处理。
                event = .readTimeout
            } catch {
                event = Task.isCancelled
                    ? .cancelled
                    : .readError(.channelReadFailed)
            }
        }

        if event == nil {
            event = .cancelled
        }

        // 测试接缝（确定性竞态）：终止事件已判定、状态尚未提交。
        if let hook = testReadLoopExitHook {
            await hook()
        }

        // 释放后代次可能已更换：旧代次不得再写入任何状态或操作连接。
        guard runtimeGeneration == generation else {
            return
        }

        switch event! {
        case .shellExited:
            await handleShellExit(connection: loopConnection)
        case .readError(let error):
            await handleReadError(error, connection: loopConnection)
        case .cancelled:
            if session.phase == .active || session.phase == .opening {
                session.phase = .connectionLost
                feedLocalNotice("[Connection closed]")
            }
        case .readTimeout:
            session.phase = .connectionLost
            feedLocalNotice("[Connection lost]")
        }
    }

    /// 远端 Shell 退出（EOF）：Channel 由读取循环侧触发关闭，状态明确。
    ///
    /// 关闭使用**捕获的**连接并在本任务内等待完成：`stopBarrier()`
    /// 等待读取循环退出即同时覆盖该清理，不留延迟关闭跨越 reattach。
    private func handleShellExit(connection closedConnection: SSHConnection) async {
        session.phase = .exited
        feedLocalNotice("[Remote shell exited]")
        await closedConnection.closeShellChannel()
        AppLogger.terminal.info("Remote shell exited")
    }

    /// 读取失败：区分 Channel 关闭 / 连接丢失 / 传输错误。
    /// 关闭同样使用捕获的连接并在本任务内等待完成。
    private func handleReadError(
        _ error: RemoteTerminalError,
        connection closedConnection: SSHConnection
    ) async {
        switch error {
        case .channelClosed:
            session.phase = .exited
            feedLocalNotice("[Remote shell exited]")
        case .connectionLost:
            session.phase = .connectionLost
            feedLocalNotice("[Connection lost]")
        default:
            // 传输中断（含服务器主动断开）：保留终端缓冲，展示断开状态。
            session.phase = .connectionLost
            feedLocalNotice("[Connection lost]")
        }
        AppLogger.terminal.error("Remote terminal read loop ended: \(error)")
        await closedConnection.closeShellChannel()
    }

    /// 在终端本地显示一条非交互提示（不进入任何日志，仅终端缓冲）。
    private func feedLocalNotice(_ text: String) {
        terminalView.feed(text: "\r\n\(text)\r\n")
    }

    private func describeOpenFailure(_ error: Error) -> String {
        if let terminalError = error as? RemoteTerminalError {
            return terminalError.errorDescription ?? "The remote terminal could not be opened."
        }
        if let sshError = error as? SSHError {
            return sshError.errorDescription ?? "The SSH connection is no longer available."
        }
        return "The remote terminal could not be opened."
    }
}

// MARK: - SwiftTerm Bridge

extension RemoteTerminalService: TerminalViewDelegate {
    /// 键盘 / paste 产生的真实 terminal input bytes → SSH Channel。
    /// SwiftTerm 在主线程调用 delegate；发送 SwiftTerm 产生的原始字节流，
    /// 不把键盘事件转成 Shell 命令字符串。
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.connection.writeChannelInput(data)
            } catch {
                // 写入失败：状态交给读取循环统一收敛（EOF/断开），此处只记录。
                AppLogger.terminal.error("Remote terminal input delivery failed")
            }
        }
    }

    /// SwiftTerm 尺寸变化（窗口 Resize / 首次 layout）→ Remote PTY Resize。
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let sizeChanged = self.session.columns != newCols || self.session.rows != newRows
            self.session.columns = newCols
            self.session.rows = newRows

            guard sizeChanged else {
                return
            }

            do {
                try await self.connection.resizeChannelPTY(columns: newCols, rows: newRows)
            } catch {
                // Resize 失败不中断会话（记录诊断，终端继续可用）。
                AppLogger.terminal.error("Remote PTY resize failed")
            }
        }
    }

    /// 远端 Shell 设置的窗口标题，不记录终端内容。
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.session.terminalTitle = title
        }
    }

    /// 远端 Shell 报告的当前目录，不主动读取远端文件。
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            self?.session.currentDirectory = directory
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // requestOpenLink / bell / clipboardCopy / clipboardRead / iTermContent
    // 使用 SwiftTerm macOS 默认实现（打开链接 / 系统提示音 / 空剪贴板策略）。
}
