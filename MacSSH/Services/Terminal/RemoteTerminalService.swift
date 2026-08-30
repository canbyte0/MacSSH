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
    private let connection: SSHConnection

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

    init(connection: SSHConnection, hostname: String, port: Int) {
        self.connection = connection
        self.session = RemoteTerminalSession(hostname: hostname, port: port)

        // 与 Local Terminal 相同的显示设置来源：同字体、xterm-256color、
        // 10,000 行 scrollback（计划书第 21 节）。
        let options = TerminalOptions(
            cols: session.columns,
            rows: session.rows,
            termName: "xterm-256color",
            scrollback: 10_000
        )
        terminalView = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            options: options
        )

        super.init()

        terminalView.terminalDelegate = self
        terminalView.configureNativeColors()
        terminalView.setAccessibilityIdentifier("terminal.remote")
        terminalView.setAccessibilityLabel("Remote Terminal \(hostname)")
    }

    /// 打开 Remote Shell（幂等）：复用已认证 Session 建立 Channel → PTY → Shell，
    /// 成功后启动读取循环。初始尺寸使用当前已知值；SwiftTerm 完成 layout 后
    /// 通过 `sizeChanged` 立即同步真实尺寸。
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

        openTask = Task { @MainActor in
            do {
                let initialColumns = session.columns
                let initialRows = session.rows
                try await connection.openInteractiveShell(
                    columns: initialColumns,
                    rows: initialRows
                )

                // stop() 在打开进行中到达：读取循环从未启动，无人再关这个
                // Channel——立即补偿关闭，不留孤儿。
                guard !hasStopped else {
                    await connection.closeShellChannel()
                    return
                }

                // 竞态窗口：SwiftTerm 首次 layout 在打开期间完成时，其
                // sizeChanged 的 resize 因 Channel 尚未存在被丢弃。打开
                // 完成后按当前已知尺寸补偿同步一次，远端 PTY 必与视图一致。
                if session.columns != initialColumns || session.rows != initialRows {
                    do {
                        try await connection.resizeChannelPTY(
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

    /// 停止 Remote Terminal：取消打开与读取任务并关闭 Channel（幂等）。
    ///
    /// 与 `startIfNeeded()` 的竞态（打开进行中就收到关闭）由三层补偿闭合：
    /// - 打开任务被取消后失败：`openInteractiveShell` 失败路径自身清理；
    /// - 打开恰好已完成：打开任务检测 `hasStopped` 后立即关闭 Channel；
    /// - 本方法的 `closeShellChannel()` 兜底（与上述并发时，
    ///   actor 内的在途等待保证互不重复释放、不留孤儿）。
    ///
    /// 打开任务引用保留（已取消）：供 `waitForOpenTaskToFinish()`
    /// 等待"打开 + 补偿关闭"全部尘埃落定；`hasStopped` 防止再次使用。
    ///
    /// 不销毁终端缓冲——用户仍可查看历史内容。
    func stop() {
        hasStopped = true
        openTask?.cancel()
        readLoopTask?.cancel()
        readLoopTask = nil

        Task { @MainActor in
            await connection.closeShellChannel()
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

    /// 持续读取远端输出并喂给 SwiftTerm；空闲时阻塞在 poll（无 CPU busy-loop）。
    private func startReadLoop() {
        readLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                do {
                    let output = try await self.connection.readChannelOutput()

                    if !output.bytes.isEmpty {
                        // 原始 byte stream 直接交给 SwiftTerm 消费，
                        // 不做 String 重编码（保护 UTF-8 / ANSI / 二进制序列边界）。
                        self.terminalView.feed(byteArray: output.bytes[...])
                    }

                    if output.isEOF {
                        // 远端 `exit` / Channel 关闭：保留屏幕与历史，标记退出。
                        self.handleShellExit()
                        return
                    }
                } catch let error as RemoteTerminalError {
                    self.handleReadError(error)
                    return
                } catch let error as SSHError where error == .cancelled {
                    // 用户断开：连接层已清理，读取循环安静退出。
                    if self.session.phase == .active || self.session.phase == .opening {
                        self.session.phase = .connectionLost
                        self.feedLocalNotice("[Connection closed]")
                    }
                    return
                } catch let error as SSHError where error == .connectionTimeout {
                    // 读取等待超预算（传输长时间无响应）：按连接丢失处理。
                    self.session.phase = .connectionLost
                    self.feedLocalNotice("[Connection lost]")
                    return
                } catch {
                    self.handleReadError(.channelReadFailed)
                    return
                }
            }
        }
    }

    /// 远端 Shell 退出（EOF）：Channel 由读取循环侧触发关闭，状态明确。
    private func handleShellExit() {
        session.phase = .exited
        feedLocalNotice("[Remote shell exited]")
        Task { @MainActor in
            await connection.closeShellChannel()
        }
        AppLogger.terminal.info("Remote shell exited")
    }

    /// 读取失败：区分 Channel 关闭 / 连接丢失 / 传输错误。
    private func handleReadError(_ error: RemoteTerminalError) {
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
        Task { @MainActor in
            await connection.closeShellChannel()
        }
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
