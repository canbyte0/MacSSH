import AppKit
import Darwin
import SwiftTerm

/// 管理 Phase 2 唯一本地 Shell、PTY 和 SwiftTerm View 的生命周期。
@MainActor
final class LocalTerminalService: NSObject {
    /// View 只观察该状态对象，不直接控制 PTY 子进程。
    let session: TerminalSession

    /// SwiftTerm 官方提供的 AppKit 本地进程终端，内部使用 PTY 和异步 I/O。
    let terminalView: LocalProcessTerminalView

    /// 防止 SwiftUI 重建包装层时重复启动 Shell。
    private var hasStarted = false

    init(session: TerminalSession) {
        self.session = session

        // 计划书要求默认限制为 10,000 行，并使用 xterm-256color 能力。
        let options = TerminalOptions(
            cols: session.columns,
            rows: session.rows,
            termName: "xterm-256color",
            scrollback: 10_000
        )
        terminalView = LocalProcessTerminalView(
            frame: .zero,
            font: TerminalFontProvider.regularFont(),
            options: options
        )

        super.init()

        terminalView.processDelegate = self
        terminalView.configureNativeColors()
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

        let configuration = LocalShellLauncher.makeConfiguration()
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
            self?.session.processState = .exited(exitCode)
            AppLogger.terminal.info("Local terminal process terminated")
        }
    }
}
