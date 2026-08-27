import Observation

/// 保存顶层页面选择，并持有独立于 SwiftUI 页面生命周期的本地 Terminal 会话。
@MainActor
@Observable
final class AppState {
    /// Sidebar 当前选择的顶层页面。
    var selectedSection: AppSection = .terminal

    /// Phase 2 唯一本地 Terminal 会话状态。
    let terminalSession: TerminalSession

    /// 持有 SwiftTerm View 和 PTY，避免切换 Sidebar 时意外结束 Shell。
    let localTerminalService: LocalTerminalService

    init() {
        let terminalSession = TerminalSession(shellPath: LoginShellResolver.resolve())
        self.terminalSession = terminalSession
        localTerminalService = LocalTerminalService(session: terminalSession)

        // 日志不包含密码、私钥、终端内容或其他敏感信息。
        AppLogger.app.info("Phase 2 application state initialized")
    }

    /// 主窗口底部左侧展示当前阶段或本地 Terminal 状态。
    var statusText: String {
        selectedSection == .terminal
            ? terminalSession.statusText
            : "Phase 2 · Local Terminal"
    }

    /// Terminal 页面显示 PTY 尺寸，其他页面继续显示页面名称。
    var statusDetail: String {
        selectedSection == .terminal
            ? terminalSession.sizeText
            : selectedSection.title
    }
}
