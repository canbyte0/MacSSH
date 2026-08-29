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

    /// 更新 Host Key 验证结果。
    func setHostKeyVerification(_ verification: HostKeyVerification) {
        self.hostKeyVerification = verification
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
        credentialService: CredentialService = .shared,
        knownHostService: KnownHostService
    ) {
        self.configuration = configuration
        self.info = info
        self.credentialService = credentialService
        self.knownHostService = knownHostService
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
