import Foundation
import Observation

/// Terminal Session 的类型。
enum TerminalSessionKind: Equatable, Sendable {
    case local
    case remoteSSH
}

/// Session 工作区当前展示的内容面板（Phase 9：Terminal / Files 分段）。
///
/// 切换面板只改变展示：Terminal 缓冲与 SFTP 运行时都保持存活，
/// 不重建任何底层资源。
enum WorkspacePane: Equatable {
    case terminal
    case files
}

/// Session 在 UI 层的统一展示状态（任务书 44：Local 与 SSH 不强行共用
/// 底层状态机，由本枚举提供映射）。
enum TerminalSessionDisplayState: Equatable {
    case starting
    case connecting
    case authenticating
    case awaitingHostTrust
    case opening
    case active
    case exited
    case disconnected
    case failed(String?)
    case closing
}

/// SessionManager 管理的单个 Terminal Session（Phase 8 统一运行时模型）。
///
/// 设计边界（任务书 4/7/8）：
/// - Session 独立于 SwiftUI View 存在；Tab/View 只观察和展示本对象。
/// - 不为 Local/Remote 另建重复状态模型：Local 复用 Phase 2 的
///   `TerminalSession`/`LocalTerminalService`，Remote 复用 Phase 7 的
///   `RemoteTerminalSession`/`RemoteTerminalService`/`SSHConnection`。
/// - 运行时状态只保存在内存，不进 SwiftData（不做 Session Restore）。
@MainActor
@Observable
final class ManagedTerminalSession: Identifiable {
    let id = UUID()

    let kind: TerminalSessionKind

    let createdAt = Date()

    /// 编号前的基准标题（"Local" 或 Host 显示名）。
    let baseTitle: String

    /// 创建时分配的稳定标题；同基准第 2 个起编号（Local 2 / Aliyun 2）。
    let title: String

    // MARK: - Local runtime（kind == .local 时非 nil）

    let localService: LocalTerminalService?

    // MARK: - Remote runtime（kind == .remoteSSH 时非 nil）

    /// 关联的 SwiftData Host 业务标识（复用 Host Profile 做 Reconnect）。
    let hostID: UUID?

    /// Host 显示名（Tab 标题与确认对话框使用；不含凭据）。
    let hostDisplayName: String?

    let hostname: String?
    let port: Int?

    private(set) var connection: SSHConnection?

    /// UI 观察的连接状态镜像（connecting/authenticating/awaitingHostTrust/…）。
    private(set) var connectionInfo: SSHConnectionInfo?

    /// Shell 运行时；连接成功后创建，Reconnect 时复用（保留 Terminal 历史）。
    private(set) var remoteService: RemoteTerminalService?

    /// Phase 9：SFTP 浏览运行时；首次打开 Files 面板时惰性创建，
    /// Terminal ↔ Files 切换复用（子系统不重建），Reconnect 时 reattach
    /// 到全新连接（绝不复用旧 `LIBSSH2_SFTP *`）。
    private(set) var sftpService: SFTPService?

    /// Phase 9：工作区当前展示的面板；切换只改变展示，底层资源保持存活。
    /// 只允许经 `selectPane(_:)` 修改（切换到 Files 时惰性启动 SFTP 运行时）。
    private(set) var activePane: WorkspacePane = .terminal

    // MARK: - 生命周期任务（SessionManager 登记与清理）

    /// 连接主流程任务（TCP → KnownHost 验证 → 认证）。
    var connectTask: Task<Void, Never>?

    /// 手动 Reconnect 任务（含旧 runtime 完整 teardown）。
    var reconnectTask: Task<Void, Never>?

    /// 关闭已请求：所有异步路径据此停止后续步骤。
    private(set) var isClosed = false

    init(
        localService: LocalTerminalService,
        baseTitle: String,
        title: String
    ) {
        kind = .local
        self.localService = localService
        self.baseTitle = baseTitle
        self.title = title
        hostID = nil
        hostDisplayName = nil
        hostname = nil
        port = nil
    }

    init(
        remoteHostID: UUID,
        hostDisplayName: String,
        hostname: String,
        port: Int,
        baseTitle: String,
        title: String
    ) {
        kind = .remoteSSH
        localService = nil
        self.hostID = remoteHostID
        self.hostDisplayName = hostDisplayName
        self.hostname = hostname
        self.port = port
        self.baseTitle = baseTitle
        self.title = title
    }

    // MARK: - Runtime 装配（SessionManager 调用）

    /// 挂接新连接（首次连接与 Reconnect 共用；调用前旧连接必须已完成 teardown）。
    func attach(connection: SSHConnection, info: SSHConnectionInfo) {
        self.connection = connection
        connectionInfo = info
    }

    /// 前置校验拒绝（缺少凭据 / Host 参数非法等）：保留 Tab 展示失败状态。
    func attachRejected(info: SSHConnectionInfo) {
        connectionInfo = info
        connection = nil
    }

    /// 连接认证成功后挂接 Shell 运行时（首次连接）。
    func attachRemoteService(_ service: RemoteTerminalService) {
        remoteService = service
    }

    /// 挂接 SFTP 运行时（SessionManager / 测试装配）。
    func attachSFTPService(_ service: SFTPService) {
        sftpService = service
    }

    /// UI 切换到 Files 面板时调用（MainActor 串行，幂等）：
    /// 仅已认证的 Remote Session 可惰性创建并启动 SFTP 运行时；
    /// Local Session 与未连接状态由 UI 展示禁用 / 断开提示，不创建。
    func ensureSFTPService() {
        guard kind == .remoteSSH, sftpService == nil, !isClosed else {
            return
        }
        guard let connection, connectionInfo?.phase == .connected else {
            return
        }
        let service = SFTPService(connection: connection)
        sftpService = service
        service.startIfNeeded()
    }

    /// 工作区分段控制切换面板（任务书：切换只改展示，不重建底层资源）。
    /// 切换到 Files 时惰性创建并启动 SFTP 运行时；已存在则复用（子系统不重建）。
    func selectPane(_ pane: WorkspacePane) {
        guard pane != activePane else {
            return
        }
        activePane = pane
        if pane == .files {
            ensureSFTPService()
        }
    }

    /// 关闭已请求；幂等。
    func markClosed() {
        isClosed = true
    }

    // MARK: - 统一展示状态

    /// UI 层统一状态：Remote 优先连接级失败/进行态，其次 Shell 生命周期，
    /// 最后回落连接 connected 态。
    var displayState: TerminalSessionDisplayState {
        if isClosed {
            return .closing
        }

        switch kind {
        case .local:
            guard let local = localService else {
                return .starting
            }
            switch local.session.processState {
            case .starting:
                return .starting
            case .running:
                return .active
            case .exited:
                return .exited
            case .failedToStart:
                return .failed(nil)
            }

        case .remoteSSH:
            if let info = connectionInfo {
                switch info.phase {
                case .failed:
                    return .failed(info.failureMessage)
                case .connecting, .handshaking:
                    return .connecting
                case .awaitingHostTrust:
                    return .awaitingHostTrust
                case .authenticating:
                    return .authenticating
                case .disconnecting:
                    return .closing
                default:
                    break
                }
            }

            if let remote = remoteService {
                switch remote.session.phase {
                case .opening:
                    return .opening
                case .active:
                    return .active
                case .exited:
                    return .exited
                case .connectionLost:
                    return .disconnected
                case .failed:
                    return .failed(connectionInfo?.failureMessage)
                }
            }

            if connectionInfo?.phase == .connected {
                return .opening
            }
            return .connecting
        }
    }

    /// 关闭前是否需要确认（任务书 21/22）：仅 SSH 活跃会话确认；
    /// 已 exit / 断开 / 失败的会话直接关闭，避免误导提示。
    /// awaitingHostTrust 时全局 Trust 对话框已在场，关闭等同取消，不二次确认。
    var requiresCloseConfirmation: Bool {
        guard kind == .remoteSSH else {
            return false
        }
        switch displayState {
        case .connecting, .authenticating, .opening, .active:
            return true
        case .starting, .awaitingHostTrust, .exited, .disconnected, .failed, .closing:
            return false
        }
    }

    /// 是否可手动 Reconnect（任务书 23：仅终态且无在途连接任务；
    /// connecting/active/Reconnect 进行中均不可）。
    var canReconnect: Bool {
        guard kind == .remoteSSH, reconnectTask == nil, connectTask == nil else {
            return false
        }
        switch displayState {
        case .exited, .disconnected, .failed:
            return true
        case .starting, .connecting, .authenticating, .awaitingHostTrust, .opening, .active, .closing:
            return false
        }
    }

    var failureMessage: String? {
        connectionInfo?.failureMessage
    }

    // MARK: - 状态栏

    /// 状态栏左侧（跟随 activeSession，任务书 66）。
    var statusText: String {
        switch kind {
        case .local:
            guard let local = localService else {
                return "Local"
            }
            let shellName = URL(fileURLWithPath: local.session.shellPath).lastPathComponent
            switch displayState {
            case .starting:
                return "Local · \(shellName) · Starting"
            case .active:
                return "Local · \(shellName)"
            case .exited:
                return "Local · \(shellName) · Exited"
            case .failed:
                return "Local · \(shellName) · Failed to Start"
            default:
                return "Local · \(shellName)"
            }

        case .remoteSSH:
            let host = hostDisplayName ?? hostname ?? "SSH"

            // Files 面板活跃时状态栏展示 SFTP 上下文（任务书状态栏要求）。
            if activePane == .files, displayState == .active {
                if let sftp = sftpService {
                    return "SFTP ● \(host) · \(sftp.currentPath)"
                }
                return "SFTP ● \(host)"
            }

            switch displayState {
            case .starting, .connecting:
                return "SSH · \(host) · Connecting…"
            case .authenticating:
                return "SSH · \(host) · Authenticating…"
            case .awaitingHostTrust:
                return "SSH · \(host) · Verifying Host…"
            case .opening:
                return "SSH · \(host) · Opening…"
            case .active:
                return "SSH ● \(host)"
            case .exited:
                return "SSH · \(host) · Exited"
            case .disconnected:
                return "SSH ○ \(host) · Disconnected"
            case .failed:
                return "SSH ○ \(host) · Failed"
            case .closing:
                return "SSH · \(host) · Closing…"
            }
        }
    }

    /// 状态栏右侧的 PTY 字符网格尺寸。
    var sizeText: String {
        switch kind {
        case .local:
            return localService?.session.sizeText ?? "80 × 24"
        case .remoteSSH:
            return remoteService?.session.sizeText ?? "80 × 24"
        }
    }
}
