import Foundation
import Observation

/// 多 Terminal Session / Tab 的管理者（Phase 8 核心）。
///
/// 所有权（任务书 5/6/47）：
/// - 由 `AppState` 持有（App 层稳定对象），绝不属于
///   `TerminalWorkspaceView` 这类临时 SwiftUI View——切换 Sidebar
///   不会销毁任何 Session。
/// - `@MainActor` 管理显示状态与 Session 集合；底层阻塞网络 I/O 全部
///   发生在 `SSHConnection` actor 内，本类型不执行任何 libssh2 调用。
///
/// 生命周期职责：
/// - 创建（Local / Remote）、激活、关闭（幂等 teardown）、手动 Reconnect；
/// - Remote Session 拥有独立的 `SSHConnection`（任务书 42：禁止多 Tab
///   共享 `LIBSSH2_SESSION *`）；teardown 完整复用 Phase 7 的安全实现
///   （`RemoteTerminalService.stop()` + `SSHConnection.disconnect()`，
///   shared disconnectTask / single teardown owner / EAGAIN safe free），
///   不复制第二套 teardown。
///
/// 日志只记录 Session 生命周期事件，绝不记录终端内容或凭据（任务书 69/70）。
@MainActor
@Observable
final class SessionManager {
    /// 全部 Session（创建顺序；任务书 18：第一版不做拖动排序）。
    private(set) var sessions: [ManagedTerminalSession] = []

    /// 0 或 1 个 Active Session；绝不指向已删除 Session（任务书 17）。
    private(set) var activeSessionID: UUID?

    /// 等待用户确认的关闭请求（UI 观察，Root 层展示确认对话框）。
    private(set) var pendingCloseConfirmation: ManagedTerminalSession?

    /// 等待用户确认的 Host 整体断开请求（关闭该 Host 全部会话）。
    private(set) var pendingHostClose: HostCloseRequest?

    private let sshService: SSHService

    /// 传输运行时（Phase 10，AppState 装配；弱引用避免与
    /// `TransferManager.sessionManager` 形成引用环）。关闭 / Reconnect
    /// 会话前必须经其屏障取消并等待传输清理完成。
    weak var transferManager: TransferManager?

    /// MacSSH 1.1：由 AppState 装配的语言 provider；创建 Session 时复制，
    /// 失败文案按当前 App Locale 即时解析（任务书七十三：不缓存启动时文案）。
    @ObservationIgnored
    var localeProvider: (@MainActor () -> Locale)?

    /// MacSSH 1.1 Phase 4：由 AppState 装配的终端外观协调器（弱引用：
    /// 协调器由 AppState 强持有，本 Manager 仅持有弱引用，无引用环）。
    /// 新建 Local / Remote Service 后立即注册其 terminalView，使其跟随
    /// macOS Appearance 动态更新；不重建任何 Runtime Session。
    @ObservationIgnored
    weak var terminalAppearanceCoordinator: TerminalAppearanceCoordinator?

    /// MacSSH 1.1 Phase 6：终端字符串高亮协调器，由 AppState 装配注入。
    /// Local / Remote 创建 / Reconnect 路径在此调用 `register`，
    /// 与 `terminalAppearanceCoordinator` 同位置（避免遗漏初始 Tab）。
    weak var terminalHighlightCoordinator: TerminalHighlightCoordinator?

    /// MacSSH 1.1 Phase 9：终端字号控制器，由 AppState 装配注入（弱引用：
    /// controller 由 AppState 强持有，本 Manager 仅持有弱引用，无引用环）。
    /// Local / Remote 创建路径在此调用 `register`，与
    /// `terminalAppearanceCoordinator` / `terminalHighlightCoordinator`
    /// 同位置（避免遗漏初始 Tab）。Reconnect reattach 复用现有 TerminalView
    /// （已注册过），不需 register。
    @ObservationIgnored
    weak var terminalFontSizeController: TerminalFontSizeController?

    init(sshService: SSHService) {
        self.sshService = sshService
        // 与 Phase 2 行为一致：启动即拥有一个 Local Terminal。
        createLocalSession()
    }

    // MARK: - 查询

    var activeSession: ManagedTerminalSession? {
        sessions.first { $0.id == activeSessionID }
    }

    func session(withID id: UUID) -> ManagedTerminalSession? {
        sessions.first { $0.id == id }
    }

    /// 等待 Host Trust 决策的 Session（全局 Trust 对话框数据源）。
    var pendingTrustSession: ManagedTerminalSession? {
        sessions.first { $0.connectionInfo?.phase == .awaitingHostTrust }
    }

    /// Host 在 Terminal 侧的聚合状态（Hosts 页行尾展示）。
    struct HostSessionSummary: Equatable {
        /// Shell 活跃（active）的会话数。
        var activeSessionCount = 0
        /// 连接 / 认证 / 打开中的会话数。
        var busySessionCount = 0
        /// 最近一个 busy 会话的语义状态；View 按当前 Locale 生成文案。
        var busyDisplayState: TerminalSessionDisplayState?

        var isEmpty: Bool {
            activeSessionCount == 0 && busySessionCount == 0
        }
    }

    func hostSessionSummary(hostID: UUID) -> HostSessionSummary {
        var summary = HostSessionSummary()
        for session in sessions where session.hostID == hostID {
            switch session.displayState {
            case .active:
                summary.activeSessionCount += 1
            case .starting, .connecting, .authenticating, .awaitingHostTrust, .opening:
                summary.busySessionCount += 1
                summary.busyDisplayState = session.displayState
            case .exited, .disconnected, .failed, .closing:
                break
            }
        }
        return summary
    }

    // MARK: - 创建

    /// 创建新的 Local Terminal（`+` / ⌘T）：新 Shell + 新 PTY + 新 SwiftTerm。
    @discardableResult
    func createLocalSession() -> ManagedTerminalSession {
        let service = LocalTerminalService(
            session: TerminalSession(shellPath: LoginShellResolver.resolve())
        )
        let session = ManagedTerminalSession(
            localService: service,
            baseTitle: "Local",
            titleCounter: nextTitleCounter(base: "Local")
        )
        session.localeProvider = localeProvider
        sessions.append(session)
        activeSessionID = session.id
        // MacSSH 1.1 Phase 4：注册新 Local Terminal 视图，立即应用当前外观
        // 并纳入 macOS Appearance 动态更新（不重启 Shell / 不改变 PID / cwd）。
        terminalAppearanceCoordinator?.register(service.terminalView)
        // MacSSH 1.1 Phase 6：同一注册点挂接高亮 provider，新 Tab 立即生效。
        terminalHighlightCoordinator?.register(service.terminalView)
        // MacSSH 1.1 Phase 9：同一注册点挂接字号 controller，新 Tab 立即应用
        // 当前字号（在 SwiftUI 插入 view 前同步设置 view.font，首帧即请求
        // 字号，无 14→18 闪烁）。
        terminalFontSizeController?.register(service.terminalView)
        AppLogger.app.info("Local terminal session created")
        return session
    }

    /// 创建新的 Remote SSH Terminal Session 并立即发起完整连接流程
    /// （TCP → KnownHost 验证 → 认证 → Channel → PTY → Shell）。
    ///
    /// 同一 Host 重复调用 = 继续新建 Session（任务书 37），每条连接独立。
    @discardableResult
    func createRemoteSession(host: Host) -> ManagedTerminalSession {
        let session = ManagedTerminalSession(
            remoteHostID: host.id,
            hostDisplayName: host.name,
            hostname: host.hostname,
            port: host.port,
            baseTitle: host.name,
            titleCounter: nextTitleCounter(base: host.name)
        )
        session.localeProvider = localeProvider
        sessions.append(session)
        activeSessionID = session.id
        AppLogger.app.info("Remote terminal session created")
        runConnectFlow(session, host: host, reconnectingService: nil)
        return session
    }

    // MARK: - 激活

    /// Tab 切换只改 activeSessionID 与 UI 展示（任务书 15）：
    /// 不重建 Shell、不重新认证、不重建 Channel。
    func activateSession(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else {
            return
        }
        guard activeSessionID != id else {
            return
        }
        activeSessionID = id
        AppLogger.app.info("Terminal session activated")
    }

    /// ⌘1~⌘9：按位置激活（任务书 35：只切换，不触发连接/重建）。
    func activateTab(at index: Int) {
        guard sessions.indices.contains(index) else {
            return
        }
        activateSession(id: sessions[index].id)
    }

    /// 把粘贴高亮设置广播到全部已打开的 Local zsh；Remote Session 不参与。
    /// 各 Local Service 通过独立控制 FIFO 通知 ZLE，不重建 Session / Shell / PTY。
    func setPasteHighlightEnabledForLocalSessions(_ isEnabled: Bool) {
        for session in sessions {
            session.localService?.setPasteHighlightEnabled(isEnabled)
        }
    }

    // MARK: - 关闭

    /// UI 关闭入口（Tab 按钮 / ⌘W / Host Disconnect）：需要确认的
    /// SSH 活跃会话先登记确认请求，其余直接关闭。
    func requestClose(id: UUID) {
        guard let session = session(withID: id), !session.isClosed else {
            return
        }
        guard session.requiresCloseConfirmation else {
            Task { await closeSession(id: id) }
            return
        }
        pendingCloseConfirmation = session
    }

    func cancelCloseConfirmation() {
        pendingCloseConfirmation = nil
    }

    func confirmClose() {
        guard let session = pendingCloseConfirmation else {
            return
        }
        pendingCloseConfirmation = nil
        Task { await closeSession(id: session.id) }
    }

    /// 关闭 Session（幂等；任务书 34/46）：同步完成 UI 移除与激活指针
    /// 修正，再 await 真实资源清理。重复关闭 / UI 与断开同时触发时，
    /// 第二次调用找不到已移除的 Session，自动 no-op。
    ///
    /// Remote teardown 顺序与 Phase 7 相同：`stop()`（Channel 优雅关闭）
    /// → `disconnect()`（shared disconnectTask / 全 Channel 关闭循环 /
    /// EAGAIN 安全 free）。
    func closeSession(id: UUID) async {
        guard let session = session(withID: id), !session.isClosed else {
            return
        }
        if pendingCloseConfirmation === session {
            pendingCloseConfirmation = nil
        }
        removeSession(session)
        await teardown(session)
    }

    /// 关闭一个 Host 的全部 Session（Hosts 页 Disconnect，用户已确认）。
    /// 顺序 teardown（每条连接独立，串行完成保证日志与状态可预期）。
    func closeAllSessions(hostID: UUID) async {
        let targets = sessions.filter { $0.hostID == hostID }
        guard !targets.isEmpty else {
            return
        }
        for session in targets {
            removeSession(session)
        }
        for session in targets {
            await teardown(session)
        }
    }

    /// UI 入口：断开 Host（关闭其全部会话）；有活跃会话时先确认。
    func requestCloseAllSessions(hostID: UUID, hostName: String) {
        let targets = sessions.filter { $0.hostID == hostID }
        guard !targets.isEmpty else {
            return
        }
        if targets.contains(where: { $0.requiresCloseConfirmation }) {
            pendingHostClose = HostCloseRequest(
                hostID: hostID,
                hostName: hostName,
                sessionCount: targets.count
            )
        } else {
            Task { await closeAllSessions(hostID: hostID) }
        }
    }

    func cancelHostClose() {
        pendingHostClose = nil
    }

    func confirmHostClose() {
        guard let request = pendingHostClose else {
            return
        }
        pendingHostClose = nil
        Task { await closeAllSessions(hostID: request.hostID) }
    }

    /// 从集合移除并修正 activeSessionID（任务书 17/54）：
    /// 关闭 Active Tab 优先激活左侧相邻，没有左侧则右侧；全部关闭则为 nil。
    private func removeSession(_ session: ManagedTerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            return
        }
        sessions.remove(at: index)
        if activeSessionID == session.id {
            let neighbor = index > 0 ? sessions[index - 1] : sessions.first
            activeSessionID = neighbor?.id
        }
        AppLogger.app.info("Terminal session closed")
    }

    /// 真实资源清理（一次 teardown owner）：
    /// - Local：终止 Shell 子进程与 PTY（任务书 19）；
    /// - Remote：**传输屏障**（取消并等待活跃传输完成清理，任务书 105）
    ///   → SFTP 屏障（取消并等待在途列举）→ stopBarrier()（屏障：
    ///   取消并等待旧任务完全退出 + 关闭 Channel）→ disconnect()
    ///   （内部顺序：文件句柄 → 目录句柄 → SFTP → Channel → Session → socket）。
    private func teardown(_ session: ManagedTerminalSession) async {
        session.markClosed()

        switch session.kind {
        case .local:
            session.localService?.terminate()

        case .remoteSSH:
            // Phase 10：传输先于一切 SFTP 拆除——取消并等待执行任务终值，
            // 保证句柄关闭与临时文件清理完成，绝不与随后的 shutdown 交错。
            if let transfers = transferManager {
                await transfers.cancelAndAwaitTransfers(forSession: session.id)
            }
            if let sftp = session.sftpService {
                await sftp.stopBarrier()
            }
            if let remote = session.remoteService {
                await remote.stopBarrier()
            }
            if let connection = session.connection {
                await connection.disconnect()
            }
        }
    }

    // MARK: - Reconnect

    /// 手动 Reconnect（任务书 23~26）：仅 Remote 终态可用。
    ///
    /// 顺序（任务书 60）：旧 runtime 完整 teardown（stop + disconnect，
    /// 旧 Channel/Session/socket 全部释放）→ 全新 `SSHConnection` 走完整
    /// 流程（TCP → **重新 KnownHost 验证** → 认证 → Channel → PTY → Shell），
    /// 绝不复用旧的 `LIBSSH2_SESSION *` / `LIBSSH2_CHANNEL *`。
    /// Terminal 历史（SwiftTerm buffer）保留，显示 "--- Reconnected ---"。
    func reconnectSession(id: UUID) {
        guard let session = session(withID: id), session.canReconnect else {
            return
        }

        // Host Profile 仍存在才可重连（Host 被删除时只能关闭 Tab）。
        guard let hostID = session.hostID,
            let host = sshService.host(withID: hostID)
        else {
            return
        }

        AppLogger.app.info("Remote terminal reconnect started")
        session.reconnectTask = Task { @MainActor [weak self, weak session] in
            guard let self else {
                return
            }
            defer { session?.reconnectTask = nil }

            // 1. 旧 runtime 完整 teardown（屏障：等待旧打开 / 读取 / 列举 / 传输
            //    任务完全退出，不与新连接争用；P1）。
            //    Phase 11：Reconnect 只取消并等待运行中任务（旧传输绝不触碰
            //    新连接，generation 安全）；排队的 pending 保留，重连成功后
            //    由调度器经新连接继续（任务书十七 / 二十三）。
            if let transfers = self.transferManager, let sessionID = session?.id {
                await transfers.cancelAndAwaitRunningTransfersForReconnect(forSession: sessionID)
            }
            if let sftp = session?.sftpService {
                await sftp.stopBarrier()
            }
            if let remote = session?.remoteService {
                await remote.stopBarrier()
            }
            if let connection = session?.connection {
                await connection.disconnect()
            }
            guard let session, !session.isClosed else {
                return
            }

            // 2. 全新连接（含重新 KnownHost 验证与认证）。
            self.runConnectFlow(session, host: host, reconnectingService: session.remoteService)
        }
    }

    // MARK: - Host Trust 决策（Phase 6 安全语义不变）

    func resolveHostTrust(sessionID: UUID, decision: SSHHostTrustDecision) {
        guard let session = session(withID: sessionID) else {
            return
        }
        guard let connection = session.connection else {
            return
        }
        Task { await connection.resolveHostTrust(decision) }
    }

    // MARK: - 连接流程（创建与 Reconnect 共用）

    /// prepare → connect（TCP / KnownHost / 认证）→ 打开 Shell。
    ///
    /// `reconnectingService` 非 nil 时为 Reconnect：认证成功后
    /// `reattach` 复用原 TerminalView；否则创建新的 RemoteTerminalService。
    ///
    /// 与 Close 的竞态（任务书 39/45）：连接中关闭 Tab 时 Session 已被
    /// 移除且 `isClosed` 置位；connect() 返回后不再打开 Shell，并对该
    /// 连接补一次完整 disconnect，不留孤儿连接（后台 connect 完成也
    /// 不会访问已释放 Session）。
    private func runConnectFlow(
        _ session: ManagedTerminalSession,
        host: Host,
        reconnectingService: RemoteTerminalService?
    ) {
        let task = Task { @MainActor [weak self, weak session] in
            // 任务登记在创建后同步完成（MainActor 串行），defer 清空安全。
            defer { session?.connectTask = nil }
            guard let self else {
                return
            }

            switch self.sshService.prepareConnection(for: host) {
            case let .rejected(info):
                guard let session, !session.isClosed else {
                    return
                }
                session.attachRejected(info: info)

            case let .ready(connection, info):
                guard let session, !session.isClosed else {
                    // prepare 与 close 竞态：直接释放这条没人认领的连接。
                    await connection.disconnect()
                    return
                }
                session.attach(connection: connection, info: info)

                await connection.connect()

                // 连接中关闭 Tab：isClosed 已置位，补完整断开后退出。
                guard !session.isClosed else {
                    await connection.disconnect()
                    return
                }

                guard info.phase == .connected else {
                    // 失败 / 用户取消：保留 Tab 展示失败或断开状态（Retry / Close）。
                    return
                }

                self.sshService.recordSuccessfulConnection(for: host)

                if let service = reconnectingService {
                    await service.reattach(connection: connection)
                    service.startIfNeeded()
                } else {
                    let service = RemoteTerminalService(
                        connection: connection,
                        hostname: host.hostname,
                        port: host.port
                    )
                    session.attachRemoteService(service)
                    // MacSSH 1.1 Phase 4：注册新 Remote Terminal 视图
                    // （与 Local 同源外观配置；不重连 / 不重建连接）。
                    terminalAppearanceCoordinator?.register(service.terminalView)
                    // MacSSH 1.1 Phase 6：Remote 同样启用高亮——matcher 只看
                    // BufferLine 文本，与连接类型无关（Phase 6A 已证）。
                    terminalHighlightCoordinator?.register(service.terminalView)
                    // MacSSH 1.1 Phase 9：Remote 同样应用当前字号——
                    // Local / Remote 在 font 构造与注册上完全同源。
                    terminalFontSizeController?.register(service.terminalView)
                    service.startIfNeeded()
                }

                // Phase 9：SFTP 子系统随旧连接释放，Reconnect 必须重建——
                // reattach 绑定新连接并复位（绝不复用旧 `LIBSSH2_SFTP *`）；
                // Files 面板在场时立即重新启动（可选恢复原路径）。
                if let sftp = session.sftpService {
                    await sftp.reattach(connection: connection)
                    if session.activePane == .files {
                        sftp.startIfNeeded()
                    }
                } else if session.activePane == .files {
                    // P2 整改：连接过程中切到 Files 时因尚未认证，
                    // `ensureSFTPService()` 直接返回、运行时未创建；
                    // 认证成功后必须补创建，否则 Files 面板永远停在加载态。
                    session.ensureSFTPService()
                }

                // Phase 11：重连成功 → 通知传输队列补位（等待连接的排队任务
                // 此时才有资格启动；绝不自动续传，任务书十七 / 二十三）。
                self.transferManager?.notifySessionReconnected(sessionID: session.id)
            }
        }

        // 创建与 Reconnect 共用：连接流程登记为 connectTask；任务体
        // 结束时自行清空。Reconnect 的外层任务只在启动本流程前持有
        // reconnectTask（teardown 阶段），返回时清空。
        session.connectTask = task
    }

    // MARK: - 标题编号（任务书 13）

    /// 同基准标题的单调计数器（P2：关闭中间 Tab 后编号不回收，
    /// 绝不产生两个同名 Tab——Local / Local 2 / Local 3，关闭
    /// Local 2 后新建得到 Local 4）。Session 生命周期仅在内存，
    /// 计数器随 Manager 存活，不需要持久化。
    private var titleCounters: [String: Int] = [:]

    /// 同基准标题的第 2 个起编号：Local / Local 2 / Aliyun / Aliyun 2。
    /// 创建时分配并保持稳定（不随其他 Tab 关闭重排或回收）。
    /// 计数 key 使用语言无关的技术名，语言切换不影响编号连续性。
    private func nextTitleCounter(base: String) -> Int {
        let counter = titleCounters[base, default: 0] + 1
        titleCounters[base] = counter
        return counter
    }
}

/// Host 整体断开的确认请求。
struct HostCloseRequest: Equatable {
    let hostID: UUID
    let hostName: String
    let sessionCount: Int
}
