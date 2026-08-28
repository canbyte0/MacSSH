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

    /// 失败时展示给用户的错误信息（不含 Secret）。
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
        let credentialID: UUID?
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

    /// 只允许本 actor 访问的 libssh2 session。
    private var session: OpaquePointer?

    /// 只允许本 actor 访问的 TCP socket。
    private var socketFD: Int32 = -1

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
        credentialService: CredentialService = .shared
    ) {
        self.configuration = configuration
        self.info = info
        self.credentialService = credentialService
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

        // 3. 取得真实 Host Key 并等待用户确认（Phase 5 只支持 Trust Once）
        let hostKey = try extractHostKeyInfo()
        await info.setHostKey(hostKey)
        await transition(to: .awaitingHostTrust)

        let decision = await awaitHostTrustDecision()
        try throwIfDisconnectRequested()

        guard decision == .trustOnce else {
            AppLogger.ssh.info("Host trust rejected for current connection")
            throw SSHError.hostTrustRejected
        }
        AppLogger.ssh.info("Host trust accepted for current connection")

        // 4. Password Authentication
        await transition(to: .authenticating)
        try await authenticateWithPassword()
        try throwIfDisconnectRequested()

        // 5. 认证完成即 Phase 5 的终点
        await transition(to: .connected)
        AppLogger.ssh.info("Password authentication succeeded")
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
    func disconnect() async {
        // 对话框还挂着时先结束等待，走取消路径。
        resolveHostTrust(.cancel)

        if isEstablishing {
            disconnectRequested = true
            return
        }

        guard session != nil || socketFD >= 0 else { return }

        await transition(to: .disconnecting)

        if let session {
            // 尽力发送 disconnect 消息（最多等待 1 秒），失败也不阻塞清理。
            // libssh2_session_disconnect 是函数式宏，Swift 必须调用 _ex 函数。
            _ = try? await runWithRetry(session: session, budget: Timeouts.gracefulDisconnect) {
                libssh2_session_disconnect_ex(
                    session,
                    SSH_DISCONNECT_BY_APPLICATION,
                    "Disconnected by user",
                    ""
                )
            }
            libssh2_session_free(session)
            self.session = nil
        }

        closeSocket()
        await transition(to: .disconnected)
        AppLogger.ssh.info("SSH connection closed")
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

        return SSHHostKeyInfo(keyType: keyType, fingerprintSHA256: fingerprint)
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
            // Swift 没有跨版本稳定暴露 explicit_bzero；逐字节覆写后立即
            // 结束缓冲区生命周期，避免 Secret 长期保留在可控内存中。
            for index in passwordBytes.indices {
                passwordBytes[index] = 0
            }
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
            for index in passwordBuffer.indices {
                passwordBuffer[index] = 0
            }
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

    /// 按 libssh2 报告的阻塞方向等待 socket 就绪；超时抛出错误。
    private func waitForLibssh2Readiness(
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
            let ready = await pollSocket(
                fd: socketFD,
                events: events,
                timeoutMs: Int32((remaining * 1000).rounded(.up))
            )
            if !ready {
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
    private func throwIfDisconnectRequested() throws {
        if disconnectRequested {
            throw SSHError.cancelled
        }
    }

    /// 失败路径统一清理；保证不留 socket / session 泄漏。
    private func fail(with error: SSHError) async {
        if let session {
            _ = try? await runWithRetry(
                session: session,
                budget: Timeouts.gracefulDisconnect
            ) {
                libssh2_session_disconnect_ex(
                    session,
                    SSH_DISCONNECT_BY_APPLICATION,
                    "Connection failed",
                    ""
                )
            }
            libssh2_session_free(session)
            self.session = nil
        }
        closeSocket()

        // 用户主动取消时展示为 disconnected，其余展示 failed。
        if error == .cancelled {
            await transition(to: .disconnected)
        } else {
            await info.setFailure(message: error.errorDescription ?? "The connection failed.")
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
