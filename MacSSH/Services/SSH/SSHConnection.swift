import Darwin
import Foundation

/// UI 观察的单个 SSH 连接状态镜像。
///
/// `SSHConnection` actor 在后台推进连接，并把阶段变化同步到这个
/// `@MainActor` 对象；SwiftUI View 只读取它，绝不直接触碰 libssh2。
@MainActor
@Observable
final class SSHConnectionInfo {
    /// 对应的 SwiftData Host 业务标识。
    let hostID: UUID

    /// 连接目标地址（非敏感展示信息）。
    let hostname: String
    let port: UInt16
    let username: String

    /// 当前连接阶段。
    var phase: SSHConnectionPhase = .idle

    /// Handshake 完成后的真实服务器 Host Key 身份。
    var hostKey: SSHHostKeyInfo?

    /// Phase 6：握手后对照 KnownHost 的持久化验证结果。
    ///
    /// - `unknown`：无已保存记录，显示首次连接对话框（Trust Once / Trust Always / Cancel）。
    /// - `trusted`：与已保存记录一致，直接放行认证，不显示对话框。
    /// - `changed`：与已保存记录不一致，显示 Host Key Changed 警告
    ///   （Cancel / Replace Trusted Key 二次确认），阻断认证直到用户明确替换。
    var hostKeyVerification: HostKeyVerification?

    /// 失败时缓存的业务错误枚举（语言无关）。
    ///
    /// MacSSH 1.1 Phase 1：UI 不直接读 `failureMessage`（英文 fallback），
    /// 改为读 `failureError` 并按当前 App Locale 即时解析——语言切换
    /// 立即生效，不在连接层缓存启动时文案（任务书七十三）。
    var failureError: SSHError?

    /// 失败时的英文 fallback 文案（debug / 诊断用途，非 UI 主路径）。
    /// UI 应通过 `failureError?.localizedDescription(locale:)` 展示。
    var failureMessage: String?

    init(hostID: UUID, hostname: String, port: UInt16, username: String) {
        self.hostID = hostID
        self.hostname = hostname
        self.port = port
        self.username = username
    }

    /// 更新阶段；由 SSHConnection actor 调用。
    func setPhase(_ phase: SSHConnectionPhase) {
        self.phase = phase
    }

    /// 更新 Host Key 身份。
    func setHostKey(_ hostKey: SSHHostKeyInfo) {
        self.hostKey = hostKey
    }

    /// 更新 Host Key 验证结果。
    func setHostKeyVerification(_ verification: HostKeyVerification) {
        self.hostKeyVerification = verification
    }

    /// 更新失败信息：同时记录语言无关的业务错误枚举与英文 fallback 文案。
    /// UI 按 Locale 即时解析 `failureError`，不读 `failureMessage`。
    func setFailure(error: SSHError, fallbackMessage: String? = nil) {
        failureError = error
        failureMessage = fallbackMessage ?? error.errorDescription
    }

    /// 更新失败信息。
    func setFailure(message: String) {
        failureMessage = message
    }
}

/// 拥有并串行管理一条真实 SSH 连接的 actor。
///
/// 一个 `LIBSSH2_SESSION *` 只允许一个所有者；本 actor 就是这个唯一
/// 串行所有者。所有 libssh2 / socket 调用都发生在 actor 隔离内，
/// EAGAIN 通过 `poll` + `libssh2_session_block_directions()` 等待，
/// 不做 CPU busy-loop。Phase 5 的终点是 authenticated session：
/// 不打开 Shell Channel，不初始化 SFTP。
actor SSHConnection {
    /// 一条连接的非敏感配置快照。
    struct Configuration: Sendable {
        let hostID: UUID
        let hostname: String
        let port: UInt16
        let username: String
        let authenticationType: AuthenticationType
        /// Password Host：指向 Keychain Password 的引用。
        let credentialID: UUID?
        /// Private Key Host：私钥文件路径（文件本身，非 Secret）。
        let privateKeyPath: String?
        /// Private Key Host：指向 Keychain Passphrase 的引用；无 Passphrase 私钥为 nil。
        let privateKeyID: UUID?
    }

    /// libssh2 Session teardown 的最小可注入边界。
    ///
    /// 生产环境使用真实 libssh2 API；测试可稳定制造
    /// `libssh2_session_disconnect_ex` 的 EAGAIN 与 actor 重入窗口，并记录
    /// Session 实际释放次数，避免依赖网络时序碰运气。
    struct SessionTeardownOperations: Sendable {
        let disconnect: @Sendable (OpaquePointer, String) -> Int32
        let free: @Sendable (OpaquePointer) -> Int32
        let afterDisconnectEAGAIN: @Sendable () async -> Void

        static let live = SessionTeardownOperations(
            disconnect: { session, reason in
                libssh2_session_disconnect_ex(
                    session,
                    SSH_DISCONNECT_BY_APPLICATION,
                    reason,
                    ""
                )
            },
            free: { session in
                libssh2_session_free(session)
            },
            afterDisconnectEAGAIN: {}
        )
    }

    /// 各阶段独立超时（计划书第 42 节：Connection Timeout 10 秒）。
    private enum Timeouts {
        static let dnsAndTCP: TimeInterval = 10
        static let handshake: TimeInterval = 10
        static let authentication: TimeInterval = 10
        static let gracefulDisconnect: TimeInterval = 1
    }

    /// libssh2 返回 EAGAIN 后的下一步等待方式。
    ///
    /// 正常情况下按库报告的阻塞方向等待 socket；如果方向掩码为 0，
    /// 则必须退避，不能订阅通常会立即就绪的 POLLOUT 而形成 busy-loop。
    enum Libssh2WaitPlan: Equatable, Sendable {
        case poll(events: Int16)
        case backoff(seconds: TimeInterval)
    }

    private let configuration: Configuration
    private let info: SSHConnectionInfo
    private let credentialService: CredentialService
    private let knownHostService: KnownHostService
    private let sessionTeardownOperations: SessionTeardownOperations

    /// 只允许本 actor 访问的 libssh2 session。
    ///
    /// `internal` 供同模块的 `SSHChannel.swift` 扩展（Phase 7 Remote Terminal）
    /// 复用；actor 隔离保证所有访问仍串行发生在本 actor 内。
    var session: OpaquePointer?

    /// 只允许本 actor 访问的 TCP socket。
    private var socketFD: Int32 = -1

    /// Phase 7：Interactive Shell Channel（`LIBSSH2_CHANNEL *`）。
    ///
    /// 与 session 相同的并发边界：只允许本 actor（含 `SSHChannel.swift` 扩展）
    /// 访问；断开 / 失败路径由 `closeShellChannel()` 统一释放，不泄漏。
    var shellChannel: OpaquePointer?

    /// Phase 7：进行中的 Shell Channel 优雅关闭任务。
    ///
    /// `closeShellChannel()` 的清理步骤跨 await（actor 可重入）：
    /// 并发的 `disconnect()` 可能在清理进行中进入；若不等待，它会先释放
    /// session，清理流程随后继续触碰已失效的 channel（use-after-free）。
    /// 该任务让所有关闭调用方都等到清理真正完成后才返回。
    ///
    /// 不变式（第二轮验收整改）：登记由任务体自身在结束时清空
    /// （`performTrackedGracefulShellChannelClose` 的 defer），保证
    /// "任务完成后槽位必为空"——等待方恢复时不会看到已完成任务的残留
    /// 登记，`disconnect()` 的关闭循环也因此不会在残留登记上空转。
    var shellChannelCloseTask: Task<Void, Never>?

    /// Phase 7：进行中的 Shell Channel 打开任务。
    ///
    /// `openInteractiveShell()` 的打开步骤跨 await（actor 可重入）：
    /// 并发调用都会通过 `shellChannel == nil` 守卫、各自打开 Channel，
    /// 后完成者覆盖前者，被覆盖的 Channel 无人释放（泄漏）。
    /// 该任务让并发打开去重：后来者等待在途打开的结果后再决策
    /// （成功幂等复用 / 失败重新尝试）。
    ///
    /// 不变式（第二轮验收整改）：登记由任务体自身在结束时清空
    /// （`performTrackedInteractiveShellOpen` 的 defer）。`disconnect()`
    /// 依赖该不变式等待在途打开，并确认没有 Channel 残留后才释放 Session。
    var shellChannelOpenTask: Task<Void, Error>?

    /// 进行中的 Session 断开任务。
    ///
    /// `disconnect()` 会跨 Channel teardown、disconnect EAGAIN 等多个 await，
    /// actor 在等待期间可重入。所有并发断开调用必须等待同一个任务，绝不各自
    /// 捕获并释放同一个 `LIBSSH2_SESSION *`。
    private var disconnectTask: Task<Void, Never>?

    /// Phase 9：SFTP 子系统句柄（`LIBSSH2_SFTP *`）。
    ///
    /// 与 session / shellChannel 相同的并发边界：只允许本 actor
    /// （含 `SFTPSession.swift` 扩展）访问。在已认证 Session 上按需初始化，
    /// Terminal ↔ Files 切换不重建；Reconnect 随旧连接释放，绝不复用。
    /// 断开路径由 `closeSFTPResourcesForTeardown()` 统一释放，不泄漏。
    var sftpSubsystem: OpaquePointer?

    /// Phase 9：在途目录列举打开的句柄（`LIBSSH2_SFTP_HANDLE *`）登记。
    ///
    /// 登记本身不是并发屏障，而是**关闭所有权的认领令牌**：句柄只在
    /// “从登记中真正摘除它的那一方”手里被关闭（摘除发生在无跨 await 的
    /// actor 串行段，认领互斥）。拆除侧在排空在途列举之前绝不摘除任何
    /// 句柄，因此所有权不会在两路之间易手。
    var openSFTPDirectoryHandles: [OpaquePointer] = []

    /// Phase 9：进行中的 SFTP 子系统初始化任务。
    ///
    /// 初始化跨 await（actor 可重入）：并发调用都会通过
    /// `sftpSubsystem == nil` 守卫、各自初始化，后完成者覆盖前者，
    /// 被覆盖的句柄无人释放（泄漏）。该任务让并发初始化去重。
    /// 登记由任务体自身在结束时清空（`performTrackedSFTPSubsystemInit`）。
    var sftpInitTask: Task<Void, Error>?

    /// Phase 9：在途目录列举计数（含其收尾的 closedir）。
    ///
    /// 拆除必须先等本计数归零（在途列举连同其 closedir 完全结束），
    /// 才能关闭剩余句柄 / `libssh2_sftp_shutdown`——否则在 EAGAIN 挂起的
    /// closedir 会在子系统释放后继续触碰已释放内存（use-after-free）。
    var inFlightSFTPListingCount = 0

    /// Phase 9：拆除等待在途列举排空使用的续体（同一时刻至多一个
    /// 拆除任务，`disconnectTask` 保证单飞，续体不会重复登记）。
    var sftpListingDrainContinuation: CheckedContinuation<Void, Never>?

    /// Phase 10：在途文件传输打开的句柄（`LIBSSH2_SFTP_HANDLE *`）登记。
    ///
    /// 与目录句柄相同的并发边界：登记是**关闭所有权的认领令牌**，
    /// 句柄只在真正摘除它的一方手里关闭；拆除侧在排空在途传输之前
    /// 绝不摘除任何句柄。
    var openSFTPFileHandles: [OpaquePointer] = []

    /// Phase 10：在途文件级 SFTP 操作计数（传输分块 open/read/write/
    /// close/rename/unlink/stat，连同其收尾关闭）。
    ///
    /// 拆除必须先等本计数归零才能关闭残留句柄 / `libssh2_sftp_shutdown`——
    /// 否则 EAGAIN 挂起的分块操作会在子系统释放后触碰已释放内存。
    /// 正常路径由 `TransferManager.cancelAndAwaitTransfers` 先行排空，
    /// 本计数是拆除侧的最后防线。
    var inFlightSFTPFileOperationCount = 0

    /// Phase 10：拆除等待在途文件操作排空使用的续体（与列举排空相同，
    /// `disconnectTask` 单飞保证续体不会重复登记）。
    var sftpFileOperationDrainContinuation: CheckedContinuation<Void, Never>?

    /// Phase 9（第二轮整改）：SFTP 操作串行门占用标志。
    ///
    /// vendored libssh2 的 `LIBSSH2_SFTP` 携带**子系统级共享状态**
    /// （`open_state` / `readdir_state` / 在途 request ID）。两个操作若借
    /// actor 在 EAGAIN 等待处的重入间隙并行执行，会互踩这些状态——
    /// 后一请求可能接走前一请求的响应，句柄与协议状态串线。
    /// 串行门保证任一时刻至多一个持门者执行 SFTP 操作（含收尾
    /// closedir 与拆除 shutdown），等待者按 FIFO 排队，释放时直接把
    /// 所有权移交给队首（绝不先置空闲再争抢）。
    var sftpOperationGateActive = false

    /// Phase 9（第二轮整改）：SFTP 操作串行门 FIFO 等待队列。
    var sftpOperationGateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Phase 9 测试仪表：`libssh2_sftp_init` 实际成功次数。
    /// 用于断言 Terminal ↔ Files 切换、刷新绝不重复初始化子系统。
    var sftpSubsystemInitCount = 0

    /// Phase 9 测试仪表：目录句柄打开 / 关闭（实际 `close_handle` 调用）次数。
    /// 竞态测试断言两者相等——任何 double-close 都会使关闭数超出打开数。
    var sftpDirectoryHandleOpenCount = 0
    var sftpDirectoryHandleCloseCount = 0

    /// Phase 10 测试仪表：文件句柄打开 / 关闭次数。
    /// 传输测试断言两者相等（无 double-close、无残留、无泄漏）。
    var sftpFileHandleOpenCount = 0
    var sftpFileHandleCloseCount = 0

    /// Phase 10 测试仪表：`libssh2_sftp_write` 成功调用次数。
    /// 强制 partial write 测试断言调用数大于分块数，
    /// 证明重试循环（`offset += written`）真实生效。
    var sftpFileWriteCallCount = 0

    /// Phase 9 测试接缝（生产恒 nil）：列举在句柄登记后、首次 readdir 前
    /// 被阻塞——readdir 返回 EAGAIN 挂起窗口的确定性等价，供并发
    /// disconnect 竞态测试复现受控交错。
    var testSFTPAfterHandleOpenHook: (@Sendable () async -> Void)?

    /// Phase 9 测试接缝（生产恒 nil）：认领关闭所有权后、实际调用
    /// `close_handle` 前被阻塞——closedir 返回 EAGAIN 挂起窗口的确定性等价。
    var testSFTPBeforeHandleCloseHook: (@Sendable () async -> Void)?

    /// Phase 10 测试接缝（生产恒为 nil，armed 标志位控制，默认关闭——
    /// 避免每次传输分块都付出一次异步调用的性能代价）：
    /// 每个**传输分块**完成后调用——分块协作调度与确定性取消测试窗口。
    var testSFTPFileTransferChunkHook: (@Sendable () async -> Void)?
    var testSFTPFileTransferChunkHookArmed = false

    /// Phase 10 测试接缝（生产恒为 nil）：传输文件句柄打开并登记后、
    /// 首个分块前——拆除竞态测试的受控窗口（镜像目录句柄接缝）。
    var testSFTPAfterFileHandleOpenHook: (@Sendable () async -> Void)?

    /// Phase 10 测试接缝（生产恒为 nil）：文件句柄被认领关闭后、
    /// 实际 `close_handle` 前的确定性窗口（镜像目录句柄接缝）。
    var testSFTPBeforeFileHandleCloseHook: (@Sendable () async -> Void)?

    /// Phase 10 测试接缝（生产恒为 nil）：单次写入字节上限——设置后
    /// `sftpWriteFileChunk` 每次调用最多向服务器提交该字节数，
    /// 确定性强制连续 partial write（服务器真实只收到并写入该字节数，
    /// 账面与真实完全一致，绝不伪报已写字节）。
    var testSFTPFileWriteMaxBytesPerCall: Int?

    /// 只暴露可跨 actor 读取的所有权状态，不把非 Sendable 的 C 指针带出 actor。
    var hasLiveSession: Bool {
        session != nil
    }

    /// 测试只观察任务登记状态，不把任务句柄带出 actor。
    var hasActiveDisconnectTask: Bool {
        disconnectTask != nil
    }

    /// Host Trust 对话框等待中的 continuation。
    private var trustContinuation: CheckedContinuation<SSHHostTrustDecision, Never>?

    /// 防止重复进入 connect 流程。
    private var hasStarted = false

    /// establish 流程是否正在运行。
    /// 运行期间 disconnect() 只设置请求标志，由 establish 的
    /// 失败路径统一清理，避免 use-after-free。
    private var isEstablishing = false

    /// establish 运行中收到断开请求。
    private var disconnectRequested = false

    init(
        configuration: Configuration,
        info: SSHConnectionInfo,
        credentialService: CredentialService = .shared,
        knownHostService: KnownHostService,
        sessionTeardownOperations: SessionTeardownOperations = .live
    ) {
        self.configuration = configuration
        self.info = info
        self.credentialService = credentialService
        self.knownHostService = knownHostService
        self.sessionTeardownOperations = sessionTeardownOperations
    }

    // MARK: - 连接主流程

    /// 执行完整的连接流程；任何失败都会清理全部资源。
    func connect() async {
        guard !hasStarted else { return }
        hasStarted = true
        isEstablishing = true
        defer { isEstablishing = false }

        do {
            try await establish()
        } catch let error as SSHError {
            await fail(with: error)
        } catch {
            await fail(with: .connectionLost)
        }
    }

    private func establish() async throws {
        try throwIfDisconnectRequested()

        await transition(to: .connecting)
        AppLogger.ssh.info("SSH connection started")

        // 1. DNS + TCP
        socketFD = try await connectTCP(
            hostname: configuration.hostname,
            port: configuration.port,
            timeout: Timeouts.dnsAndTCP
        )
        try throwIfDisconnectRequested()

        AppLogger.ssh.info("TCP connection established")

        // 2. SSH Session + Handshake
        try await performHandshake()
        try throwIfDisconnectRequested()

        // 3. 取得真实 Host Key 并对照持久化 KnownHost 验证身份（Phase 6）
        let hostKey = try extractHostKeyInfo()
        await info.setHostKey(hostKey)

        let stored = await knownHostService.lookup(
            hostname: configuration.hostname,
            port: Int(configuration.port)
        )
        let verification: HostKeyVerification
        if let stored {
            if stored.hostKey == hostKey.hostKeyBlob {
                verification = .trusted
            } else {
                verification = .changed(
                    storedFingerprint: stored.fingerprint,
                    storedKeyType: stored.keyType
                )
            }
        } else {
            verification = .unknown
        }
        await info.setHostKeyVerification(verification)

        // 已信任：直接放行认证，不显示对话框。
        // 未知 / 变化：进入 awaitingHostTrust 等待 UI 决策。
        //   未知 → Trust Once / Trust Always / Cancel
        //   变化 → Cancel / Replace Trusted Key（UI 负责二次危险确认）
        // 任何阻断路径都在认证之前抛出，保证 Password 与私钥绝不发送。
        if verification != .trusted {
            await transition(to: .awaitingHostTrust)
            let decision = await awaitHostTrustDecision()
            try throwIfDisconnectRequested()
            try await resolveHostKeyDecision(decision, verification: verification, hostKey: hostKey)
        } else {
            AppLogger.ssh.info("Host key matches trusted record")
        }

        // 4. 认证（Password 或 Private Key，由 Host 配置决定，不互相回退）
        await transition(to: .authenticating)
        switch configuration.authenticationType {
        case .password:
            try await authenticateWithPassword()
        case .privateKey:
            try await authenticateWithPrivateKey()
        }
        try throwIfDisconnectRequested()

        // 5. 认证完成即 Phase 6 的终点（不打开 Shell Channel，不初始化 SFTP）
        await transition(to: .connected)
        AppLogger.ssh.info("SSH authentication succeeded")
    }

    /// 处理用户在 Host Trust 对话框上的决策；Trust Always / Replace 会更新 KnownHost。
    ///
    /// Cancel 在“变化”场景抛 `hostKeyChanged`，在“未知”场景抛 `hostTrustRejected`；
    /// 两者都保证在认证之前终止，绝不发送 Password 或私钥。
    private func resolveHostKeyDecision(
        _ decision: SSHHostTrustDecision,
        verification: HostKeyVerification,
        hostKey: SSHHostKeyInfo
    ) async throws {
        switch decision {
        case .cancel:
            AppLogger.ssh.info("Host trust cancelled by user")
            switch verification {
            case .changed:
                throw SSHError.hostKeyChanged
            case .unknown, .trusted:
                throw SSHError.hostTrustRejected
            }

        case .trustOnce:
            // 仅对未知主机合法；变化场景下 UI 不应发送，防御性按取消处理。
            guard case .unknown = verification else {
                throw SSHError.hostTrustRejected
            }
            AppLogger.ssh.info("Host trust accepted for current connection only")

        case .trustAlways:
            guard case .unknown = verification else {
                throw SSHError.hostTrustRejected
            }
            // 安全契约：只有 KnownHost 真正落盘成功才允许继续认证。
            // 持久化失败会抛 knownHostPersistenceFailed，establish 在进入
            // authenticating 之前终止，Password 与私钥绝不发送。
            _ = try await knownHostService.trust(
                hostname: configuration.hostname,
                port: Int(configuration.port),
                keyType: hostKey.keyType,
                hostKey: hostKey.hostKeyBlob,
                fingerprint: hostKey.fingerprintSHA256
            )
            AppLogger.ssh.info("Host trusted and persisted (Trust Always)")

        case .replaceTrustedKey:
            // 仅变化场景合法；UI 已完成二次危险确认后才发送此决策。
            guard case .changed = verification else {
                throw SSHError.hostTrustRejected
            }
            // 与 Trust Always 相同的安全契约：替换保存失败必须中止认证，
            // 旧 KnownHost 保持不变，绝不标记为已成功替换。
            _ = try await knownHostService.trust(
                hostname: configuration.hostname,
                port: Int(configuration.port),
                keyType: hostKey.keyType,
                hostKey: hostKey.hostKeyBlob,
                fingerprint: hostKey.fingerprintSHA256
            )
            AppLogger.ssh.info("Trusted host key replaced after user confirmation")
        }
    }

    // MARK: - Host Trust 决策入口

    /// UI 在 Host Trust 对话框上做出的选择。
    func resolveHostTrust(_ decision: SSHHostTrustDecision) {
        trustContinuation?.resume(returning: decision)
        trustContinuation = nil
    }

    /// 幂等断开：正常发送 disconnect 并释放全部资源。
    ///
    /// 连接流程运行中只登记请求，由 establish 的失败路径统一清理，
    /// 防止在 libssh2 调用进行中释放 session 造成 use-after-free。
    ///
    /// 第二轮验收整改（P1：close → reopen → disconnect 交错时，新 Channel
    /// 可能随 Session 释放成为悬空 `shellChannel`，后续关闭路径
    /// use-after-free）：
    /// - 断开**一开始**就置位断开标志：新的 Channel 打开在入口校验立即
    ///   失败，在途打开 / 读写 / Resize 在下一个校验点尽快退出
    ///   （此前标志在 Session 释放前才置位，断开期间仍可能有新 Channel
    ///   被打开）；
    /// - 关闭循环：等待在途打开 / 关闭任务并反复检查，直到无 Channel 且
    ///   无在途任务——保证本方法返回即"Channel 全部释放"，之后才释放
    ///   Session。等待期间不会再有新打开（入口已被断开标志拒绝），
    ///   循环必然收敛。
    ///
    /// 第三轮验收整改（P1：并发 disconnect double-free）：断开工作登记为
    /// 共享 `disconnectTask`，所有并发调用等待同一任务；Session 释放前在
    /// 无 await 的 actor 同步段重新确认指针所有权并先把 `self.session` 置 nil，
    /// 即使未来调用链再次引入重入点，也不会由两个任务释放同一指针。
    func disconnect() async {
        // 对话框还挂着时先结束等待，走取消路径。
        resolveHostTrust(.cancel)

        if isEstablishing {
            disconnectRequested = true
            return
        }

        // 已有断开流程：合并并等待同一个任务，禁止第二条 teardown 流程。
        if let running = disconnectTask {
            await running.value
            return
        }

        guard session != nil || socketFD >= 0 else { return }

        // 断开从一开始就生效（此前在 Session 释放前才置位）：
        // - openInteractiveShell 入口校验立即失败，不再接受新打开；
        // - 在途 Channel 操作在下一个校验点尽快退出。
        disconnectRequested = true

        let task = Task {
            await performTrackedDisconnect()
        }
        disconnectTask = task
        await task.value
    }

    /// 共享断开任务体；登记由任务自身清空，保证任务完成后槽位必为空。
    ///
    /// 释放顺序（Phase 9 任务书）：目录句柄 → SFTP 子系统 → Shell Channel
    /// → SSH Session → socket；全部完成后才返回。
    private func performTrackedDisconnect() async {
        defer { disconnectTask = nil }

        await transition(to: .disconnecting)

        // 关闭全部 SFTP 资源（等在途初始化、关闭登记中的目录句柄、
        // 关闭子系统；幂等，无 SFTP 时为空操作）。
        await closeSFTPResourcesForTeardown()

        // 关闭全部 Shell Channel（等待在途打开 / 关闭并循环检查）。
        await closeAllShellChannelsForTeardown()

        if let ownedSession = session {
            // 尽力发送 disconnect 消息（最多等待 1 秒），失败也不阻塞清理。
            // 断开标志已提前置位，不能走会检查该标志的 runWithRetry，
            // 改用不检查标志的专用发送路径，保持 Phase 5 的优雅断开行为。
            await sendGracefulDisconnectMessage(
                session: ownedSession,
                reason: "Disconnected by user"
            )

            // libssh2_session_free 会连带回收属于该 Session 的全部 Channel；
            // 上方关闭循环已保证 shellChannel 为 nil，不存在对已释放指针的
            // 后续访问（后续任何 stop()/读取循环退出路径调用的
            // closeShellChannel 都是幂等空操作）。
            // 所有权确认、置 nil 与第一次 free 调用之间没有 await：actor 不可
            // 重入。先从共享状态摘除指针，再释放，构成 double-free 的最后防线。
            if ownedSession == self.session {
                self.session = nil
                let initialFreeResult = sessionTeardownOperations.free(ownedSession)
                await finishReleasingOwnedSession(
                    ownedSession,
                    initialResult: initialFreeResult
                )
            }
        }

        closeSocket()
        await transition(to: .disconnected)
        AppLogger.ssh.info("SSH connection closed")
    }

    /// 尽力发送 SSH disconnect 消息（EAGAIN 时按阻塞方向等待，1 秒预算）。
    ///
    /// 专用于断开流程：不检查 `disconnectRequested`（断开开始时已置位，
    /// 该标志只用于让在途 Channel 操作尽快退出）；每次调用前校验
    /// session 身份，防止与并发的第二次 disconnect 交错后
    /// 触碰已释放指针。
    private func sendGracefulDisconnectMessage(session: OpaquePointer, reason: String) async {
        let deadline = Date().addingTimeInterval(Timeouts.gracefulDisconnect)

        while true {
            // 身份校验：并发的另一个 disconnect 可能已释放 session。
            guard session == self.session else {
                return
            }

            // libssh2_session_disconnect 是函数式宏，Swift 必须调用 _ex 函数。
            let rc = sessionTeardownOperations.disconnect(session, reason)
            if rc != LIBSSH2_ERROR_EAGAIN {
                return
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return
            }
            // EAGAIN：与 Phase 5 相同的 poll 等待（无 busy-loop）；
            // 超时 / 异常按尽力而为处理，不阻塞清理。
            do {
                try await waitForLibssh2Readiness(session: session, deadline: deadline)
            } catch {
                return
            }

            // readiness 已完成且下一轮身份校验尚未开始：生产环境为空操作；
            // 测试在这里打开异步闸门，缺陷版本也不会先读取已释放的 Session。
            await sessionTeardownOperations.afterDisconnectEAGAIN()
        }
    }

    /// 释放已从 `self.session` 摘除、由当前断开任务独占的 Session。
    ///
    /// libssh2 官方文档说明 `libssh2_session_free` 在 non-blocking 模式同样
    /// 可能返回 EAGAIN，因此按 socket readiness 重试；共享状态已经置 nil，
    /// 等待期间其他 actor 调用无法重新取得或释放该指针。
    private func finishReleasingOwnedSession(
        _ ownedSession: OpaquePointer,
        initialResult: Int32
    ) async {
        let deadline = Date().addingTimeInterval(Timeouts.gracefulDisconnect)
        var rc = initialResult

        while true {
            if rc == 0 {
                return
            }
            guard rc == LIBSSH2_ERROR_EAGAIN else {
                AppLogger.ssh.error("SSH session free failed with libssh2 code \(rc)")
                return
            }

            do {
                try await waitForLibssh2Readiness(session: ownedSession, deadline: deadline)
            } catch {
                AppLogger.ssh.error("SSH session free timed out")
                return
            }
            rc = sessionTeardownOperations.free(ownedSession)
        }
    }

    // MARK: - Handshake

    private func performHandshake() async throws {
        await transition(to: .handshaking)

        guard let newSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            closeSocket()
            throw SSHError.sessionInitializationFailed
        }
        session = newSession

        // 全程 non-blocking；EAGAIN 交给 poll 等待。
        libssh2_session_set_blocking(newSession, 0)

        applyRekeySafeMethodPreferences(newSession)

        let rc = try await runWithRetry(
            session: newSession,
            budget: Timeouts.handshake
        ) {
            libssh2_session_handshake(newSession, self.socketFD)
        }

        guard rc == 0 else {
            throw SSHError.handshakeFailed(libssh2Code: Int(rc))
        }
        AppLogger.ssh.info("SSH handshake completed")
    }

    /// Phase 11 P1 修复（第三轮整改）：仅排除 mlkem768x25519-sha256 等
    /// post-quantum kex 路径（trace 取证定位其 rekey 时 ssh-ed25519
    /// hostkey 签名验证间歇返回 0），**保留 libssh2 默认 kex 列表的全部
    /// 其他安全算法**以维持与标准 OpenSSH 服务器的兼容性——含仅支持
    /// `diffie-hellman-group14-sha256` 的服务器。
    ///
    /// 名单 = libssh2 默认 kex 列表减去
    /// `mlkem768x25519-sha256` / `mlkem768nistp256-sha256` /
    /// `mlkem1024nistp384-sha384` 三个。这是**排除**而非**覆盖**：
    /// 任何支持 libssh2 默认 kex 之一的服务器都能协商成功，仅 mlkem
    /// 系被排除（其非标准 OpenSSH 必选算法，curve25519/group14 等为
    /// 标准基线，排除 mlkem 不破坏兼容）。
    ///
    /// Host Key **不限制**（保持 libssh2 默认协商），避免对仅支持
    /// 某类 hostkey 的服务器造成兼容性破坏；rekey 的 ssh-ed25519
    /// 签名验证在 curve25519 kex 路径下稳定（根因是 mlkem rekey 的
    /// H 计算路径，非 ed25519 verify 本身——同 verify 函数首次
    /// handshake 成功即证）。
    ///
    /// `method_pref rc=0` 只代表名单设置成功，不代表协商成功；本方法
    /// 不依赖 rc 判断兼容性，名单本身保证覆盖 libssh2 默认安全算法。
    private func applyRekeySafeMethodPreferences(_ session: OpaquePointer) {
        let kexPrefs = "curve25519-sha256,curve25519-sha256@libssh.org," +
            "ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521," +
            "diffie-hellman-group-exchange-sha256," +
            "diffie-hellman-group16-sha512,diffie-hellman-group18-sha512," +
            "diffie-hellman-group14-sha256"
        let rcKex = libssh2_session_method_pref(
            session, Int32(LIBSSH2_METHOD_KEX), kexPrefs)
        if rcKex != 0 {
            AppLogger.ssh.info(
                "kex method_pref rc=\(rcKex), using libssh2 defaults")
        }
    }

    /// 协商的 KEX 算法名（回归测试断言排除 mlkem 路径）。
    var negotiatedKexMethod: String? {
        guard let session else { return nil }
        return libssh2_session_methods(session, LIBSSH2_METHOD_KEX)
            .map { String(cString: $0) }
    }

    /// 从 handshake 后的 session 中提取真实 Host Key 身份信息。
    private func extractHostKeyInfo() throws -> SSHHostKeyInfo {
        guard let session else {
            throw SSHError.connectionLost
        }

        var keyLength: Int = 0
        guard
            let keyBytes = libssh2_session_hostkey(session, &keyLength, nil),
            keyLength > 0
        else {
            throw SSHError.hostKeyUnavailable
        }

        let blob = Data(bytes: keyBytes, count: keyLength)

        // SHA256 fingerprint（OpenSSH 格式：无 padding base64）。
        // libssh2_hostkey_hash 返回 const char *。
        guard
            let hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256),
            let fingerprint = Self.opensshSHA256Fingerprint(from: hash)
        else {
            throw SSHError.hostKeyUnavailable
        }

        // 从 public key blob 解析算法名（STRING：4 字节大端长度 + 名称）。
        let keyType = Self.keyAlgorithmName(from: blob) ?? "unknown"

        return SSHHostKeyInfo(
            keyType: keyType,
            fingerprintSHA256: fingerprint,
            hostKeyBlob: blob
        )
    }

    // MARK: - Password Authentication

    private func authenticateWithPassword() async throws {
        guard let credentialID = configuration.credentialID else {
            throw SSHError.credentialNotFound
        }

        guard let session else {
            throw SSHError.connectionLost
        }

        let usernameBytes = Array(configuration.username.utf8CString)

        // 先查询服务器支持的认证方法；用户名错误时该请求同样会失败。
        guard let supportedMethods = try await requestAuthenticationMethods(
            session: session,
            usernameBytes: usernameBytes
        ) else {
            throw SSHError.authenticationFailed
        }
        guard supportedMethods.contains("password") else {
            throw SSHError.passwordAuthenticationUnsupported
        }

        // 只在真正需要时从 Keychain 读取密码，并尽快结束其作用域。
        var passwordBytes: [CChar]
        do {
            // 将 String 限制在最小作用域；后续只让可覆写的 CChar 缓冲区
            // 跨越 libssh2 的异步重试过程。
            let password = try await credentialService.readPassword(credentialID: credentialID)
            guard !password.isEmpty else {
                throw SSHError.credentialNotFound
            }
            passwordBytes = Array(password.utf8CString)
        } catch KeychainError.itemNotFound {
            throw SSHError.credentialNotFound
        }
        defer {
            // 统一 Secret 清零入口；defer 保证认证成功 / 失败 / 取消路径都执行。
            Self.zeroSecretBytes(&passwordBytes)
        }

        // 指针需要跨 await 存活，必须手动分配而不是 withUnsafeBufferPointer
        // （同步闭包内不允许 await）。
        let usernameBuffer = UnsafeMutableBufferPointer<CChar>.allocate(
            capacity: usernameBytes.count
        )
        usernameBytes.withUnsafeBufferPointer { source in
            _ = usernameBuffer.initialize(from: source)
        }
        defer { usernameBuffer.deallocate() }

        let passwordBuffer = UnsafeMutableBufferPointer<CChar>.allocate(
            capacity: passwordBytes.count
        )
        passwordBytes.withUnsafeBufferPointer { source in
            _ = passwordBuffer.initialize(from: source)
        }
        defer {
            Self.zeroSecretBytes(passwordBuffer)
            passwordBuffer.deallocate()
        }

        // libssh2_userauth_password 是函数式宏，Swift 必须调用 _ex 函数。
        let rc: Int32 = try await runWithRetry(
            session: session,
            budget: Timeouts.authentication
        ) {
            libssh2_userauth_password_ex(
                session,
                usernameBuffer.baseAddress,
                UInt32(usernameBuffer.count - 1),
                passwordBuffer.baseAddress,
                UInt32(passwordBuffer.count - 1),
                nil
            )
        }

        guard rc == 0 else {
            // 用户名或密码被服务器拒绝；错误信息不携带任何 Secret。
            throw SSHError.authenticationFailed
        }
    }

    // MARK: - Private Key Authentication

    /// 使用 OpenSSH 私钥文件进行 publickey 认证（Phase 6）。
    ///
    /// - 全程 non-blocking：EAGAIN 交给现有 poll + block_directions 逻辑，不在主线程阻塞。
    /// - Passphrase 从 `CredentialService` 读取（生命周期最短化，调用结束后逐字节覆写）；
    ///   无 Passphrase 私钥 `privateKeyID` 为 nil，向 libssh2 传 NULL。
    /// - 认证方式由 Host 配置决定，不回退 Password。
    /// - 日志不记录 Passphrase 或私钥内容。
    private func authenticateWithPrivateKey() async throws {
        guard let session else {
            throw SSHError.connectionLost
        }

        // 1. 私钥文件存在性与可读性（在调用 libssh2 前优雅失败，不卡在认证中）。
        guard let privateKeyPath = configuration.privateKeyPath,
              !privateKeyPath.isEmpty
        else {
            throw SSHError.privateKeyPathMissing
        }
        guard FileManager.default.fileExists(atPath: privateKeyPath) else {
            throw SSHError.privateKeyFileNotFound
        }
        guard FileManager.default.isReadableFile(atPath: privateKeyPath) else {
            throw SSHError.privateKeyFileUnreadable
        }

        let usernameBytes = Array(configuration.username.utf8CString)
        let privateKeyPathBytes = Array(privateKeyPath.utf8CString)

        // 2. 服务器认证方式发现；不支持 publickey 时明确报错，不回退 Password。
        guard let supportedMethods = try await requestAuthenticationMethods(
            session: session,
            usernameBytes: usernameBytes
        ) else {
            throw SSHError.privateKeyAuthenticationFailed
        }
        guard supportedMethods.contains("publickey") else {
            throw SSHError.publicKeyAuthenticationUnsupported
        }

        // 3. Passphrase（可选）。无 Passphrase 私钥：privateKeyID 为 nil，传 NULL。
        var passphraseBytes: [CChar] = []
        var passphraseSupplied = false
        if let privateKeyID = configuration.privateKeyID {
            do {
                let passphrase = try await credentialService.readPrivateKeyPassphrase(
                    privateKeyID: privateKeyID
                )
                guard !passphrase.isEmpty else {
                    throw SSHError.privateKeyPassphraseRequired
                }
                passphraseBytes = Array(passphrase.utf8CString)
                passphraseSupplied = true
            } catch KeychainError.itemNotFound {
                // 配置了 privateKeyID 但 Keychain 缺失：视为需要 Passphrase 但未保存。
                throw SSHError.privateKeyPassphraseRequired
            }
        }
        // 原始 Passphrase 字节副本与 libssh2 缓冲区使用同一清零标准；
        // defer 覆盖后续全部路径（错误 Passphrase、认证失败、超时、
        // 连接中断、意外错误、成功），不会因提前 throw 留下可控 Secret。
        defer {
            Self.zeroSecretBytes(&passphraseBytes)
        }

        // 指针需跨 await 存活，手动分配；Passphrase 缓冲区用后逐字节覆写。
        let usernameBuffer = UnsafeMutableBufferPointer<CChar>.allocate(
            capacity: usernameBytes.count
        )
        usernameBytes.withUnsafeBufferPointer { source in
            _ = usernameBuffer.initialize(from: source)
        }
        defer { usernameBuffer.deallocate() }

        let privateKeyBuffer = UnsafeMutableBufferPointer<CChar>.allocate(
            capacity: privateKeyPathBytes.count
        )
        privateKeyPathBytes.withUnsafeBufferPointer { source in
            _ = privateKeyBuffer.initialize(from: source)
        }
        defer { privateKeyBuffer.deallocate() }

        let passphraseBuffer: UnsafeMutableBufferPointer<CChar>? = passphraseSupplied
            ? UnsafeMutableBufferPointer<CChar>.allocate(capacity: passphraseBytes.count)
            : nil
        if let passphraseBuffer {
            passphraseBytes.withUnsafeBufferPointer { source in
                _ = passphraseBuffer.initialize(from: source)
            }
        }
        defer {
            if let passphraseBuffer {
                Self.zeroSecretBytes(passphraseBuffer)
                passphraseBuffer.deallocate()
            }
        }

        // 4. libssh2 文件私钥认证；publickey 传 NULL，由 libssh2 从私钥推导公钥。
        let rc: Int32 = try await runWithRetry(
            session: session,
            budget: Timeouts.authentication
        ) {
            let passphrasePointer: UnsafePointer<CChar>? =
                passphraseBuffer?.baseAddress.map { UnsafePointer($0) }
            return libssh2_userauth_publickey_fromfile_ex(
                session,
                usernameBuffer.baseAddress,
                UInt32(usernameBuffer.count - 1),
                nil,
                privateKeyBuffer.baseAddress,
                passphrasePointer
            )
        }

        // 5. 结果映射（不携带 Secret）。
        guard rc != 0 else {
            return
        }

        switch rc {
        case LIBSSH2_ERROR_KEYFILE_AUTH_FAILED:
            // 解密私钥失败：提供了 Passphrase 即为错误 Passphrase；
            // 未提供则表示私钥需要 Passphrase 但未配置。
            throw passphraseSupplied
                ? SSHError.privateKeyPassphraseIncorrect
                : SSHError.privateKeyPassphraseRequired
        case LIBSSH2_ERROR_FILE:
            // 实测 libssh2 1.11.2_DEV：对加密 OpenSSH 私钥，只要 Passphrase 无法成功解密
            // （错误 / 未提供 / 空串），一律返回 LIBSSH2_ERROR_FILE 而非 KEYFILE_AUTH_FAILED。
            // 文件存在性与可读性已在前置校验确认，因此先判断私钥是否加密：
            // - 已加密：错误 / 缺失 Passphrase（而不是文件权限问题）；
            // - 未加密：私钥格式损坏或无法解析。
            if Self.isEncryptedOpenSSHPrivateKey(at: privateKeyPath) {
                throw passphraseSupplied
                    ? SSHError.privateKeyPassphraseIncorrect
                    : SSHError.privateKeyPassphraseRequired
            }
            throw SSHError.privateKeyFileUnreadable
        case LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED, LIBSSH2_ERROR_AUTHENTICATION_FAILED:
            // 密钥可加载但服务器拒绝（不在 authorized_keys）。
            throw SSHError.privateKeyAuthenticationFailed
        default:
            throw SSHError.privateKeyAuthenticationFailed
        }
    }

    /// 判断私钥文件是否为加密的 OpenSSH 格式私钥。
    ///
    /// OpenSSH 私钥文件是 PEM 文本（BEGIN/END OPENSSH PRIVATE KEY 之间的 base64），
    /// base64 解码后才是 "openssh-key-v1" 二进制头部；头部第二字段 ciphername
    /// 不等于 "none" 表示私钥已加密（如 "aes256-ctr" + kdf "bcrypt"）。
    /// 只读取文件头，不加载整个私钥，不记录任何 Secret；无法解析时按未加密处理。
    private static func isEncryptedOpenSSHPrivateKey(at path: String) -> Bool {
        guard
            let fileData = FileManager.default.contents(atPath: path),
            let text = String(data: fileData, encoding: .utf8)
        else {
            return false
        }

        let lines = text.components(separatedBy: .newlines)
        guard
            let beginIndex = lines.firstIndex(of: "-----BEGIN OPENSSH PRIVATE KEY-----"),
            let endIndex = lines.firstIndex(of: "-----END OPENSSH PRIVATE KEY-----"),
            beginIndex < endIndex
        else {
            return false
        }

        let base64 = lines[(beginIndex + 1)..<endIndex].joined()
        guard let data = Data(base64Encoded: base64) else {
            return false
        }

        let magic = Data("openssh-key-v1\0".utf8)
        guard data.count > magic.count + 4,
              data.prefix(magic.count) == magic
        else {
            return false
        }

        var offset = magic.count
        guard let cipherLength = readUInt32(data, at: &offset),
              cipherLength > 0,
              offset + Int(cipherLength) <= data.count
        else {
            return false
        }

        let cipherName = String(
            data: data[offset..<(offset + Int(cipherLength))],
            encoding: .utf8
        )
        return cipherName != "none"
    }

    /// 读取 big-endian UInt32；不足 4 字节返回 nil。
    private static func readUInt32(_ data: Data, at offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data.subdata(in: offset..<(offset + 4)).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        offset += 4
        return value
    }

    /// 查询服务器支持的认证方法列表；返回 nil 表示请求本身失败。
    private func requestAuthenticationMethods(
        session: OpaquePointer,
        usernameBytes: [CChar]
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(Timeouts.authentication)

        // 指针需要跨 await 存活，手动分配。
        let usernameBuffer = UnsafeMutableBufferPointer<CChar>.allocate(
            capacity: usernameBytes.count
        )
        usernameBytes.withUnsafeBufferPointer { source in
            _ = usernameBuffer.initialize(from: source)
        }
        defer { usernameBuffer.deallocate() }

        return try await runUserAuthList(
            session: session,
            username: usernameBuffer,
            deadline: deadline
        )
    }

    private func runUserAuthList(
        session: OpaquePointer,
        username: UnsafeMutableBufferPointer<CChar>,
        deadline: Date
    ) async throws -> String? {
        while true {
            if let methods = libssh2_userauth_list(
                session,
                username.baseAddress,
                UInt32(username.count - 1)
            ) {
                // 返回值由 libssh2 session 内部管理；这里只复制成 Swift
                // 字符串，禁止调用 libssh2_free，否则 session 清理时会重复释放。
                let value = String(cString: methods)
                return value
            }

            let lastError = libssh2_session_last_errno(session)
            guard lastError == LIBSSH2_ERROR_EAGAIN else {
                return nil
            }

            try await waitForLibssh2Readiness(session: session, deadline: deadline)
        }
    }

    // MARK: - TCP 连接

    /// DNS 解析 + 非阻塞 TCP 连接；全程带超时，不阻塞 actor 执行器。
    private func connectTCP(
        hostname: String,
        port: UInt16,
        timeout: TimeInterval
    ) async throws -> Int32 {
        let addresses = try await resolveHostname(hostname, port: port)
        guard !addresses.isEmpty else {
            throw SSHError.dnsResolutionFailed
        }

        let deadline = Date().addingTimeInterval(timeout)

        for address in addresses {
            try throwIfDisconnectRequested()

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw SSHError.connectionTimeout
            }

            if let fd = try await connectOnce(address: address, timeout: remaining) {
                return fd
            }
        }

        // 所有候选地址都无法建立连接。
        throw SSHError.connectionRefused
    }

    /// 对单个地址发起非阻塞连接；返回 nil 表示该地址失败，可尝试下一个。
    private func connectOnce(address: Data, timeout: TimeInterval) async throws -> Int32? {
        var family: Int32 = AF_UNSPEC
        address.withUnsafeBytes { raw in
            if raw.count >= MemoryLayout<sockaddr>.size {
                family = Int32(raw.load(as: sockaddr.self).sa_family)
            }
        }

        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SSHError.socketError(errno: errno)
        }

        // 设置非阻塞。
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var result: Int32 = -1
        address.withUnsafeBytes { raw in
            // 显式 Darwin.connect：避免与 actor 自身的 connect() 方法混淆。
            guard let base = raw.baseAddress else { return }
            result = Darwin.connect(
                fd,
                base.assumingMemoryBound(to: sockaddr.self),
                socklen_t(raw.count)
            )
        }

        if result == 0 {
            return fd
        }

        let connectErrno = errno
        if connectErrno != EINPROGRESS {
            close(fd)
            // 一个 DNS 名称可能同时解析出 IPv6/IPv4。当前候选地址拒绝连接时
            // 返回 nil，让调用方继续尝试后续地址。
            if connectErrno == ECONNREFUSED {
                return nil
            }
            throw Self.mapConnectError(connectErrno)
        }

        // 等待连接完成（POLLOUT），带剩余超时。
        let remainingMs = Int32((timeout * 1000).rounded(.up))
        let ready = await pollSocket(fd: fd, events: Int16(POLLOUT), timeoutMs: remainingMs)
        if !ready {
            close(fd)
            throw SSHError.connectionTimeout
        }

        // 检查最终连接错误。
        var soError: Int32 = 0
        var soErrorLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLength)

        if soError == 0 {
            return fd
        }

        close(fd)
        if soError == ECONNREFUSED {
            return nil // 该地址拒绝连接，尝试下一个
        }
        throw Self.mapConnectError(soError)
    }

    /// 在后台线程执行阻塞的 getaddrinfo，避免占用 actor 执行器。
    private func resolveHostname(_ hostname: String, port: UInt16) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_flags = AI_ADDRCONFIG
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(hostname, String(port), &hints, &result)
                guard status == 0, let first = result else {
                    continuation.resume(throwing: SSHError.dnsResolutionFailed)
                    return
                }
                defer { freeaddrinfo(result) }

                var addresses: [Data] = []
                var current: UnsafeMutablePointer<addrinfo>? = first
                while let entry = current {
                    let family = entry.pointee.ai_family
                    if family == AF_INET || family == AF_INET6,
                        let sockaddrPointer = entry.pointee.ai_addr
                    {
                        addresses.append(
                            Data(bytes: sockaddrPointer, count: Int(entry.pointee.ai_addrlen))
                        )
                    }
                    current = entry.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }

    // MARK: - EAGAIN 等待

    /// 执行一个可能返回 EAGAIN 的 libssh2 调用，就绪前用 poll 等待。
    private func runWithRetry(
        session: OpaquePointer,
        budget: TimeInterval,
        _ operation: () throws -> Int32
    ) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(budget)

        while true {
            try throwIfDisconnectRequested()

            let rc = try operation()
            if rc != LIBSSH2_ERROR_EAGAIN {
                return rc
            }
            try await waitForLibssh2Readiness(session: session, deadline: deadline)
        }
    }

    /// 等待 poll 单切片上限（Phase 11 testA 停滞根治）。
    ///
    /// 背景：EAGAIN 调用返回后到等待方 `poll()` 开始之间存在执行器跳转间隙；
    /// 同一 actor 上串行调度到的其他任务（终端读循环等）可能在间隙内把已到达的
    /// 数据消费进 libssh2 内部队列——此时 socket 已空，一次睡满预算的 poll 永不
    /// 被唤醒（数据在队列中，poll 无法感知），操作白白耗光预算后失败。
    /// 切片后：切片到期而总预算未耗尽即返回，调用方重试 libssh2 调用
    /// （队列中已有数据时立即完成），最坏只多等一个切片。
    private static let readinessPollMaximumSlice: TimeInterval = 0.25

    /// 按 libssh2 报告的阻塞方向等待 socket 就绪；总预算耗尽才抛超时。
    ///
    /// poll 以短切片为上限（见 `readinessPollMaximumSlice`）：切片内就绪 → 返回；
    /// 切片到期而总预算未耗尽 → 正常返回由调用方重试其 libssh2 调用（绝不把可完成
    /// 的操作睡死在空 socket 上）；总预算耗尽 → `connectionTimeout`。
    ///
    /// `internal` 供同模块的 `SSHChannel.swift` 扩展复用（actor 隔离不变）。
    func waitForLibssh2Readiness(
        session: OpaquePointer,
        deadline: Date
    ) async throws {
        let directions = libssh2_session_block_directions(session)
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw SSHError.connectionTimeout
        }

        switch Self.libssh2WaitPlan(directions: directions, remaining: remaining) {
        case let .poll(events):
            let slice = min(remaining, Self.readinessPollMaximumSlice)
            let ready = await pollSocket(
                fd: socketFD,
                events: events,
                timeoutMs: Int32((slice * 1000).rounded(.up))
            )
            if ready {
                return
            }
            guard deadline.timeIntervalSinceNow > 0 else {
                throw SSHError.connectionTimeout
            }

        case let .backoff(seconds):
            // 与 libssh2 自身的阻塞等待策略一致：方向未知时最多暂停 1 秒。
            // Task.sleep 会挂起当前任务并释放 actor 执行器，不消耗 CPU 自旋。
            try await Self.suspendForLibssh2Backoff(seconds: seconds)
        }
    }

    /// 将 libssh2 的阻塞方向转换成可测试的等待计划。
    ///
    /// `directions == 0` 是 libssh2 明确可能出现的边缘状态；此时使用
    /// 有上限的异步退避，防止可写 socket 让 poll 立即返回并反复重试。
    static func libssh2WaitPlan(
        directions: Int32,
        remaining: TimeInterval
    ) -> Libssh2WaitPlan {
        var events: Int16 = 0
        if directions & Int32(LIBSSH2_SESSION_BLOCK_INBOUND) != 0 {
            events |= Int16(POLLIN)
        }
        if directions & Int32(LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0 {
            events |= Int16(POLLOUT)
        }

        guard events != 0 else {
            return .backoff(seconds: min(1, remaining))
        }
        return .poll(events: events)
    }

    /// 实际执行零方向退避；保持为独立入口便于回归测试验证墙钟时间与 CPU。
    static func suspendForLibssh2Backoff(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded(.up))
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    /// 在 GCD 线程上执行 poll；未就绪（超时）返回 false。
    private func pollSocket(fd: Int32, events: Int16, timeoutMs: Int32) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let ready = poll(&descriptor, 1, timeoutMs) > 0
                continuation.resume(returning: ready)
            }
        }
    }

    // MARK: - Host Trust 等待

    private func awaitHostTrustDecision() async -> SSHHostTrustDecision {
        await withCheckedContinuation { continuation in
            trustContinuation = continuation
        }
    }

    // MARK: - 清理

    /// 连接流程中被请求断开时使用的内部取消信号。
    ///
    /// `internal` 供同模块的 `SSHChannel.swift` 扩展复用（actor 隔离不变）。
    func throwIfDisconnectRequested() throws {
        if disconnectRequested {
            throw SSHError.cancelled
        }
    }

    /// 失败路径统一清理；保证不留 socket / session / channel 泄漏。
    private func fail(with error: SSHError) async {
        // Phase 7：失败同样先释放 Shell Channel。
        await closeShellChannel()

        if let ownedSession = session {
            _ = try? await runWithRetry(
                session: ownedSession,
                budget: Timeouts.gracefulDisconnect
            ) {
                self.sessionTeardownOperations.disconnect(
                    ownedSession,
                    "Connection failed"
                )
            }
            if ownedSession == self.session {
                self.session = nil
                let initialFreeResult = sessionTeardownOperations.free(ownedSession)
                await finishReleasingOwnedSession(
                    ownedSession,
                    initialResult: initialFreeResult
                )
            }
        }
        closeSocket()

        // 用户主动取消时展示为 disconnected，其余展示 failed。
        // MacSSH 1.1：缓存语言无关的 SSHError 枚举，UI 按 Locale 即时解析。
        if error == .cancelled {
            await transition(to: .disconnected)
        } else {
            await info.setFailure(error: error)
            await transition(to: .failed(error))
        }
        AppLogger.ssh.error("SSH connection failed: \(String(describing: error))")
    }

    private func closeSocket() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    // MARK: - 状态同步

    private func transition(to phase: SSHConnectionPhase) async {
        await info.setPhase(phase)
    }

    // MARK: - 工具

    /// 逐字节覆写 Secret 字节数组并尽快结束其生命周期。
    ///
    /// Swift 没有跨版本稳定暴露 explicit_bzero；统一入口便于 Password 与
    /// Passphrase 保持相同安全标准，并作为测试 hook 验证清零机制。
    /// defer 路径调用本方法，保证成功 / 失败 / 取消 / 异常路径都执行清理。
    static func zeroSecretBytes(_ bytes: inout [CChar]) {
        for index in bytes.indices {
            bytes[index] = 0
        }
    }

    /// `UnsafeMutableBufferPointer` 版本的 Secret 清零；用后立即覆写再释放。
    static func zeroSecretBytes(_ buffer: UnsafeMutableBufferPointer<CChar>) {
        for index in buffer.indices {
            buffer[index] = 0
        }
    }

    private static func mapConnectError(_ errnoValue: Int32) -> SSHError {
        switch errnoValue {
        case ECONNREFUSED:
            .connectionRefused
        case ETIMEDOUT, ENETUNREACH, EHOSTUNREACH:
            .connectionTimeout
        default:
            .socketError(errno: errnoValue)
        }
    }

    /// 将 32 字节 SHA256 hash 转为 OpenSSH 格式 fingerprint。
    private static func opensshSHA256Fingerprint(from hash: UnsafePointer<CChar>) -> String? {
        let digest = Data(bytes: hash, count: 32)
        let base64 = digest.base64EncodedString()
        let trimmed = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(trimmed)"
    }

    /// 从 SSH public key blob 解析算法名（格式：长度前缀字符串）。
    private static func keyAlgorithmName(from blob: Data) -> String? {
        guard blob.count > 4 else { return nil }
        let nameLength = blob.prefix(4).reduce(0) { result, byte in
            (result << 8) | Int(byte)
        }
        guard nameLength > 0, blob.count >= 4 + nameLength else { return nil }
        let nameData = blob.subdata(in: 4..<(4 + nameLength))
        return String(data: nameData, encoding: .utf8)
    }
}
