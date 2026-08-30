import Observation
import SwiftData

/// 保存顶层页面选择，并持有独立于 SwiftUI 页面生命周期的会话状态。
@MainActor
@Observable
final class AppState {
    /// Sidebar 当前选择的顶层页面。
    var selectedSection: AppSection = .terminal

    /// Phase 2 唯一本地 Terminal 会话状态。
    let terminalSession: TerminalSession

    /// 持有 SwiftTerm View 和 PTY，避免切换 Sidebar 时意外结束 Shell。
    let localTerminalService: LocalTerminalService

    /// SSH 连接的唯一业务入口（Phase 5 引入，Phase 6 扩展安全验证）；连接独立于 View 生命周期。
    let sshService: SSHService

    /// Phase 7 当前唯一的 Remote SSH Terminal；由 AppState 持有，
    /// 切换 Sidebar 不销毁远端 Shell。Remote 会话存在期间直接占用
    /// Terminal 工作区展示；Local/SSH Tab、Close、Switch、Reconnect
    /// 属于计划书 Phase 8，本阶段不实现。
    private(set) var remoteTerminalService: RemoteTerminalService?

    init(modelContainer: ModelContainer) {
        let terminalSession = TerminalSession(shellPath: LoginShellResolver.resolve())
        self.terminalSession = terminalSession
        localTerminalService = LocalTerminalService(session: terminalSession)
        sshService = SSHService(modelContainer: modelContainer)

        // 日志不包含密码、私钥、终端内容或其他敏感信息。
        AppLogger.app.info("Application state initialized")
    }

    // MARK: - Remote Terminal（Phase 7）

    /// 在已认证连接上打开 Remote SSH Terminal 并切换到 Terminal 页面。
    ///
    /// 复用 `SSHService` 已认证的 `SSHConnection`（绝不重新认证 / 重读凭据）；
    /// 同一时间只保持一个 Remote Terminal，切换目标主机时先关闭旧 Channel。
    func openRemoteTerminal(for host: Host) {
        guard let info = sshService.connectionInfo(for: host.id),
            info.phase == .connected,
            let connection = sshService.connectionActor(for: host.id)
        else {
            return
        }

        // 已有同主机的活动 Remote Terminal：不重建 Shell，仅回到 Terminal 页。
        if let existing = remoteTerminalService,
            existing.session.hostname == host.hostname,
            existing.session.port == host.port,
            existing.session.phase == .active || existing.session.phase == .opening
        {
            selectedSection = .terminal
            return
        }

        // 换主机（或旧会话已结束）：关闭旧 Channel 后替换。
        //
        // stop() 的 Channel 关闭是异步的（fire-and-forget Task），"旧
        // Terminal 异步停止后立即创建新 Terminal"的安全性由 actor 层保证：
        // 同一 SSHConnection 上的下一次 openInteractiveShell 会在入口先等待
        // 在途关闭任务完成（SSHChannel.openInteractiveShell），不会与旧
        // 清理交错产生半开 / 覆盖 Channel。
        if let existing = remoteTerminalService {
            existing.stop()
            remoteTerminalService = nil
        }

        let service = RemoteTerminalService(
            connection: connection,
            hostname: host.hostname,
            port: host.port
        )
        remoteTerminalService = service
        selectedSection = .terminal
        AppLogger.app.info("Remote terminal requested for connected host")
    }

    /// 主机断开时收起其 Remote Terminal（连接生命周期驱动，非 Tab Close）。
    ///
    /// 断开后 Terminal 工作区回到 Local Terminal。会话已自然结束
    /// （远端 `exit` / 连接丢失）时保留终端展示终止状态，等待用户
    /// 再次 Open Terminal 替换或断开主机收起。
    ///
    /// 本方法先 stop()（异步关闭 Channel）再断开连接——两者的交错由
    /// SSHConnection.disconnect 的关闭循环安全收敛：断开一开始置位
    /// 断开标志（拒绝新打开），等待在途打开 / 关闭任务并循环关闭全部
    /// Channel 后才释放 Session，不会留下悬空 Channel。
    func hostDidDisconnect(hostname: String, port: Int) {
        guard let remote = remoteTerminalService,
            remote.session.hostname == hostname,
            remote.session.port == port
        else {
            return
        }

        remote.stop()
        remoteTerminalService = nil
    }

    /// 主窗口底部左侧展示当前阶段或 Terminal 状态。
    var statusText: String {
        guard selectedSection == .terminal else {
            return "Phase 7 · Remote SSH Terminal"
        }

        if let remote = remoteTerminalService {
            return remote.session.statusText
        }
        return terminalSession.statusText
    }

    /// Terminal 页面显示 PTY 尺寸，其他页面继续显示页面名称。
    var statusDetail: String {
        guard selectedSection == .terminal else {
            return selectedSection.title
        }

        if let remote = remoteTerminalService {
            return remote.session.sizeText
        }
        return terminalSession.sizeText
    }
}
