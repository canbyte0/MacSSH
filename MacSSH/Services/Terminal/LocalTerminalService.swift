import AppKit
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
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            options: options
        )

        super.init()

        terminalView.processDelegate = self
        terminalView.configureNativeColors()
        terminalView.setAccessibilityIdentifier("terminal.local")
        terminalView.setAccessibilityLabel("Local Terminal")
    }

    /// 使用账户配置中的 login shell 启动唯一的本地 PTY 会话。
    func startIfNeeded() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        session.processState = .starting

        let shellName = URL(fileURLWithPath: session.shellPath).lastPathComponent
        terminalView.startProcess(
            executable: session.shellPath,
            execName: "-\(shellName)",
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
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
    /// 必须真正停止子进程（任务书 19），不得只把 View 从列表移除；
    /// 子进程结束后 SwiftTerm 会回调 `processTerminated` 更新状态。
    func terminate() {
        guard session.processState == .starting || session.processState == .running else {
            return
        }
        terminalView.terminate()
        AppLogger.terminal.info("Local terminal process termination requested")
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
