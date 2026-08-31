import Observation
import SwiftData

/// 保存顶层页面选择，并持有独立于 SwiftUI 页面生命周期的会话状态。
@MainActor
@Observable
final class AppState {
    /// Sidebar 当前选择的顶层页面。
    var selectedSection: AppSection = .terminal

    /// SSH 连接工厂与共享安全服务（Phase 5 引入，Phase 6 扩展安全验证，
    /// Phase 8 起不再按 Host 持有单一连接——连接由 SessionManager
    /// 代表各 Remote Session 持有）。
    let sshService: SSHService

    /// 多 Terminal Session / Tab 的管理者（Phase 8），由本 App 层稳定
    /// 对象持有：切换 Sidebar / 页面不会销毁任何 Session。
    let sessionManager: SessionManager

    /// 传输运行时（Phase 10）：由本 App 层稳定对象持有——切换页面 /
    /// 切换会话 / 关闭 Transfers 面板都不取消传输；关闭传输所属会话时
    /// 经 `cancelAndAwaitTransfers` 屏障先取消并等待清理。
    let transferManager: TransferManager

    init(modelContainer: ModelContainer) {
        let sshService = SSHService(modelContainer: modelContainer)
        self.sshService = sshService
        let sessionManager = SessionManager(sshService: sshService)
        let transferManager = TransferManager()
        // 双向弱引用装配（两者均由本对象强持有，绝不形成引用环）。
        transferManager.sessionManager = sessionManager
        sessionManager.transferManager = transferManager
        self.sessionManager = sessionManager
        self.transferManager = transferManager

        // 日志不包含密码、私钥、终端内容或其他敏感信息。
        AppLogger.app.info("Application state initialized")
    }

    // MARK: - Hosts 页入口（Phase 8）

    /// Hosts 页 Connect / Open Terminal：创建新的 Remote Terminal Session
    /// 并切换到 Terminal 页（同 Host 重复点击 = 继续新建，任务书 36/37）。
    func connectHost(_ host: Host) {
        sessionManager.createRemoteSession(host: host)
        selectedSection = .terminal
    }

    /// Hosts 页 Disconnect：关闭该 Host 的全部 Terminal Session
    /// （有活跃会话时先经 SessionManager 确认）。
    func disconnectHost(_ host: Host) {
        sessionManager.requestCloseAllSessions(hostID: host.id, hostName: host.name)
    }

    /// 主窗口底部左侧展示当前阶段或 Active Session 状态（任务书 66）。
    var statusText: String {
        guard selectedSection == .terminal else {
            if selectedSection == .transfers, let active = transferManager.activeTask {
                return "传输中 · \(active.localName)"
            }
            return "Phase 10 · SFTP Transfers"
        }

        guard let session = sessionManager.activeSession else {
            return "No Terminal Sessions"
        }
        return session.statusText
    }

    /// Terminal 页面显示 Active Session 的 PTY 尺寸，其他页面显示页面名称。
    var statusDetail: String {
        guard selectedSection == .terminal else {
            return selectedSection.title
        }

        guard let session = sessionManager.activeSession else {
            return ""
        }
        return session.sizeText
    }
}
