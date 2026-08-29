import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 5 SSH 基础连接真实测试。
///
/// 测试服务器：本机 sshd（Remote Login），即用户明确控制的真实 OpenSSH Server。
/// Password 由测试脚本通过 macOS Keychain 的安全输入提示写入固定的测试专用 item，
/// 测试进程只持有 credential 引用；任何源码、环境变量、断言与日志都不包含 Password 本身。
///
/// 需要：
/// - 系统设置 → 通用 → 共享 → 远程登录 已开启
/// - 运行 Scripts/run-ssh-tests.sh，由脚本创建并在退出时删除测试专用 Keychain item
@MainActor
final class SSHConnectionTests: XCTestCase {
    /// 测试目标：本机 sshd。
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    /// 仅用于真实 SSH 验收；与测试脚本中的 account 保持一致，不属于生产 Host 数据。
    private let liveCredentialID = UUID(uuidString: "7d54a5bf-3032-4db2-9267-a643fe75c229")!

    /// 测试专用私钥文件（由 Scripts/run-ssh-tests.sh 生成并在退出时删除）。
    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
        static let ed25519WithPass = "/tmp/macssh_phase6_ed25519_pass"
        /// 带 Passphrase 私钥的随机 Passphrase（脚本写入 600 权限临时文件；读后即删，不进任何日志）。
        static let ed25519WithPassSecret = "/tmp/macssh_phase6_ed25519_pass.secret"
        /// 未加入 authorized_keys 的私钥（用于“错误 Private Key”验收）。
        static let unauthorized = "/tmp/macssh_phase6_ed25519_unauthorized"
        static let rsa = "/tmp/macssh_phase6_rsa"
        static let ecdsa = "/tmp/macssh_phase6_ecdsa"
    }

    /// 每个测试独立的 Keychain 凭据标识。
    private var credentialID: UUID!

    /// 每个测试独立的 KnownHost 持久化容器（内存），保证 KnownHost 状态不跨测试泄漏。
    private var knownHostContainer: ModelContainer!
    private var knownHostService: KnownHostService!

    /// 测试中临时创建的 Private Key Passphrase 凭据；在 tearDown 统一清理。
    private var extraPassphraseIDs: [UUID] = []

    override func setUp() async throws {
        continueAfterFailure = false
        credentialID = UUID()
        extraPassphraseIDs = []
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        knownHostContainer = try ModelContainer(for: schema, configurations: [configuration])
        knownHostService = KnownHostService(modelContainer: knownHostContainer)
    }

    override func tearDown() async throws {
        // 尽力清理测试凭据；Secret 不进入任何日志。
        if let credentialID {
            _ = try? await CredentialService.shared.deletePassword(credentialID: credentialID)
        }
        for passID in extraPassphraseIDs {
            _ = try? await CredentialService.shared.deletePrivateKeyPassphrase(privateKeyID: passID)
        }
        extraPassphraseIDs.removeAll()
        // 清理本测试可能持久化的 KnownHost，避免影响真实 App 的持久化存储（内存容器本身已隔离）。
        await MainActor.run { knownHostService.removeAll() }
        knownHostService = nil
        knownHostContainer = nil
    }

    // MARK: - 测试 A：正确凭据完整流程

    /// connecting → handshaking → awaitingHostTrust → Trust Once → authenticating → connected
    func testA_FullFlowWithTrustOnceReachesConnected() async throws {
        try await requireLocalSSHAndLiveCredential()

        let info = makeInfo()
        let connection = makeConnection(info: info, credentialID: liveCredentialID)
        let connectTask = Task { await connection.connect() }

        // 依次观察真实阶段推进。
        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        let keyInfo = await MainActor.run { info.hostKey }
        XCTAssertNotNil(keyInfo, "Host Key 必须来自真实 handshake")
        XCTAssertTrue(
            keyInfo!.fingerprintSHA256.hasPrefix("SHA256:"),
            "Fingerprint 应为 OpenSSH SHA256 格式"
        )
        XCTAssertFalse(keyInfo!.keyType.isEmpty)

        await connection.resolveHostTrust(.trustOnce)

        _ = try await waitForPhase(info, "Trust Once 后到达 connected") { $0 == .connected }

        await connection.disconnect()
        _ = try await waitForPhase(info, "断开") { $0 == .disconnected }

        _ = await connectTask.result
    }

    // MARK: - 测试 B：错误 Password

    func testB_WrongPasswordFailsWithAuthenticationFailure() async throws {
        try await requireLocalSSH()

        // 保存一个确定错误的密码（不是真实密码）。
        try await CredentialService.shared.savePassword(
            "macssh-wrong-password-\(UUID().uuidString)",
            credentialID: credentialID
        )

        let info = makeInfo()
        let connection = makeConnection(info: info, credentialID: credentialID)
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        // 必须以 authenticationFailed 结束，不能崩溃或永久卡死。
        let final = try await waitForPhase(info, "错误密码得到 authenticationFailed", timeout: 20) {
            if case let .failed(error) = $0 { return error == .authenticationFailed }
            return false
        }

        if case let .failed(error) = final {
            XCTAssertEqual(error, .authenticationFailed)
        }

        // 断开幂等：失败后再次 disconnect 不崩溃。
        await connection.disconnect()
        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 C：错误 Username

    func testC_WrongUsernameFails() async throws {
        try await requireLocalSSHAndLiveCredential()

        let wrongUsername = "macssh_no_such_user_\(Int.random(in: 1000...9999))"
        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: testHostname,
            port: testPort,
            username: wrongUsername
        )
        let connection = makeConnection(info: info, credentialID: liveCredentialID)
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        let final = try await waitForPhase(info, "错误用户名得到认证失败", timeout: 20) {
            if case let .failed(error) = $0 { return error == .authenticationFailed }
            return false
        }

        if case let .failed(error) = final {
            XCTAssertEqual(error, .authenticationFailed)
        }

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 D：错误端口（无服务监听）

    func testD_ClosedPortConnectionRefused() async throws {
        let closedPort: UInt16 = 22_022

        // 测试前提：确认该端口确实没有监听。
        XCTAssertTrue(
            try isPortClosed(port: closedPort),
            "测试前提：端口 \(closedPort) 不应有服务监听"
        )

        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: testHostname,
            port: closedPort,
            username: testUsername
        )
        let connection = makeConnection(info: info, credentialID: nil)
        let connectTask = Task { await connection.connect() }

        let final = try await waitForPhase(info, "关闭端口得到 connectionRefused", timeout: 15) {
            if case let .failed(error) = $0 { return error == .connectionRefused }
            return false
        }

        if case let .failed(error) = final {
            XCTAssertEqual(error, .connectionRefused)
        }

        // 幂等断开两次，验证 Socket 清理且不崩溃。
        await connection.disconnect()
        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 E：不可达地址触发超时

    func testE_UnreachableAddressTimesOut() async throws {
        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: "10.255.255.1", // TEST-NET-2，不可路由
            port: 22,
            username: testUsername
        )
        let connection = makeConnection(info: info, credentialID: nil)
        let connectTask = Task { await connection.connect() }

        let start = Date()
        let final = try await waitForPhase(info, "不可达地址超时", timeout: 25) {
            if case let .failed(error) = $0 { return error == .connectionTimeout }
            return false
        }
        let elapsed = Date().timeIntervalSince(start)

        if case let .failed(error) = final {
            XCTAssertEqual(error, .connectionTimeout)
        }
        XCTAssertGreaterThanOrEqual(elapsed, 9, "应等待约 10 秒超时预算")
        XCTAssertLessThanOrEqual(elapsed, 22, "不应显著超过 10 秒预算")

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 F：不可解析 Hostname

    func testF_BadHostnameDNSFails() async throws {
        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: "macssh-nonexistent-\(UUID().uuidString).invalid",
            port: 22,
            username: testUsername
        )
        let connection = makeConnection(info: info, credentialID: nil)
        let connectTask = Task { await connection.connect() }

        let final = try await waitForPhase(info, "错误 Hostname 得到 DNS 失败", timeout: 15) {
            if case let .failed(error) = $0 { return error == .dnsResolutionFailed }
            return false
        }

        if case let .failed(error) = final {
            XCTAssertEqual(error, .dnsResolutionFailed)
        }

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 G：Host Trust Cancel（硬性安全验收）

    func testG_TrustCancelNeverAuthenticates() async throws {
        // 只需要本机 sshd 可达（handshake 需要），认证本身不会发生。
        try await requireLocalSSH()

        // 凭据即使存在也不会被使用；这里不保存任何真实 Secret。
        let info = makeInfo()
        let connection = makeConnection(info: info, credentialID: nil)
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        let keyInfo = await MainActor.run { info.hostKey }
        XCTAssertNotNil(keyInfo, "必须使用真实 handshake 返回的 Host Key，禁止伪造 Fingerprint")

        // Cancel：必须断开且绝不发送 Password。
        await connection.resolveHostTrust(.cancel)

        let final = try await waitForPhase(info, "Cancel 后结束连接", timeout: 10) {
            $0 == .disconnected || $0 == .failed(.hostTrustRejected)
        }

        switch final {
        case .failed(let error):
            XCTAssertEqual(error, .hostTrustRejected)
        case .disconnected:
            break // 用户取消路径同样合法
        default:
            XCTFail("Cancel 后不应出现其他状态：\(final)")
        }

        // 关键安全断言：整个过程绝不能进入 authenticating（即未发送任何认证请求）。
        // 由于我们通过编程方式在 awaitingHostTrust 即取消，此处补充验证最终状态
        // 不是 authenticationFailed —— 若实现错误地发送密码，服务器会拒绝并得到
        // authenticationFailed 而非 hostTrustRejected。
        if case let .failed(error) = final {
            XCTAssertNotEqual(error, .authenticationFailed, "Cancel 后绝不能发送密码")
        }

        // 幂等断开两次，验证资源彻底释放且不崩溃。
        await connection.disconnect()
        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 H：Credential 缺失

    @MainActor
    func testH_MissingCredentialFailsFast() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let host = Host(
            name: "Phase 5 Test Missing Credential",
            hostname: testHostname,
            port: Int(testPort),
            username: testUsername,
            authenticationType: .password,
            credentialID: nil
        )
        context.insert(host)

        let service = SSHService(modelContainer: container)
        service.connect(to: host)

        // 前置校验应立即失败，明确 credentialNotFound，而非假的认证失败。
        let info = service.connectionInfo(for: host.id)
        XCTAssertNotNil(info)
        if case let .failed(error) = info?.phase {
            XCTAssertEqual(error, .credentialNotFound)
            XCTAssertEqual(
                info?.failureMessage,
                SSHError.credentialNotFound.errorDescription
            )
        } else {
            XCTFail("缺少凭据应立即 failed(.credentialNotFound)，实际：\(String(describing: info?.phase))")
        }
    }

    // MARK: - 测试 I：Private Key Host 未配置私钥路径（Phase 6 前置校验）

    @MainActor
    func testI_PrivateKeyHostWithoutPathFailsFast() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let host = Host(
            name: "Phase 6 Test Private Key No Path",
            hostname: testHostname,
            port: Int(testPort),
            username: testUsername,
            authenticationType: .privateKey,
            credentialID: nil,
            privateKeyID: nil,
            privateKeyPath: nil
        )
        context.insert(host)

        let service = SSHService(modelContainer: container)
        service.connect(to: host)

        let info = service.connectionInfo(for: host.id)
        XCTAssertNotNil(info)
        if case let .failed(error) = info?.phase {
            XCTAssertEqual(error, .privateKeyPathMissing)
            XCTAssertEqual(
                info?.failureMessage,
                SSHError.privateKeyPathMissing.errorDescription
            )
        } else {
            XCTFail("无路径的 Private Key Host 应立即 failed(.privateKeyPathMissing)，实际：\(String(describing: info?.phase))")
        }
    }

    // MARK: - 20 次 Connect/Disconnect 资源泄漏验证

    func test_TwentyConnectDisconnectCyclesNoLeak() async throws {
        try await requireLocalSSHAndLiveCredential()

        let fdProbeBefore = probeFileDescriptor()
        let threadsBefore = threadCount()

        for cycle in 1...20 {
            let info = makeInfo()
            let connection = makeConnection(info: info, credentialID: liveCredentialID)
            let connectTask = Task { await connection.connect() }

            _ = try await waitForPhase(
                info,
                "第 \(cycle) 轮等待 Host Trust",
                timeout: 15
            ) { $0 == .awaitingHostTrust }

            await connection.resolveHostTrust(.trustOnce)

            _ = try await waitForPhase(
                info,
                "第 \(cycle) 轮连接成功",
                timeout: 15
            ) { $0 == .connected }

            await connection.disconnect()
            _ = try await waitForPhase(info, "第 \(cycle) 轮断开") { $0 == .disconnected }

            _ = await connectTask.result
        }

        // 资源泄漏检查：FD 与线程数不应持续增长。
        let fdProbeAfter = probeFileDescriptor()
        let threadsAfter = threadCount()

        XCTAssertLessThanOrEqual(
            fdProbeAfter - fdProbeBefore,
            2,
            "20 次连接后 FD 不应持续增长（before=\(fdProbeBefore), after=\(fdProbeAfter)）"
        )
        XCTAssertLessThanOrEqual(
            threadsAfter - threadsBefore,
            4,
            "20 次连接后线程数不应持续增长（before=\(threadsBefore), after=\(threadsAfter)）"
        )
    }

    // MARK: - 空闲 CPU 验证（连接成功后空闲 30 秒）

    func test_IdleCPUAfterConnected() async throws {
        try await requireLocalSSHAndLiveCredential()

        let info = makeInfo()
        let connection = makeConnection(info: info, credentialID: liveCredentialID)
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)
        _ = try await waitForPhase(info, "连接成功") { $0 == .connected }

        // 连接成功后空闲 30 秒，测量进程 CPU 时间增量。
        let usageBefore = Self.processCPUSeconds()
        try await Task.sleep(nanoseconds: 30_000_000_000)
        let usageAfter = Self.processCPUSeconds()

        let cpuDelta = usageAfter - usageBefore
        XCTAssertLessThanOrEqual(
            cpuDelta,
            1.0,
            "空闲 30 秒 CPU 增量应接近 0（实测 \(String(format: "%.3f", cpuDelta)) 秒），不得 EAGAIN busy-loop"
        )

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - EAGAIN 等待策略回归

    /// libssh2 未报告阻塞方向时必须异步退避，不能监听通常立即可写的 POLLOUT。
    func test_EAGAINZeroDirectionsUsesBoundedBackoff() async throws {
        XCTAssertEqual(
            SSHConnection.libssh2WaitPlan(directions: 0, remaining: 10),
            .backoff(seconds: 1)
        )
        XCTAssertEqual(
            SSHConnection.libssh2WaitPlan(directions: 0, remaining: 0.25),
            .backoff(seconds: 0.25)
        )

        // 实际执行与生产路径相同的 1 秒异步退避：墙钟时间应流逝，
        // 但进程 CPU 增量应远低于单核 busy-loop 约 1 秒的消耗。
        let wallStart = Date()
        let cpuStart = Self.processCPUSeconds()
        try await SSHConnection.suspendForLibssh2Backoff(seconds: 1)
        let wallElapsed = Date().timeIntervalSince(wallStart)
        let cpuDelta = Self.processCPUSeconds() - cpuStart

        XCTAssertGreaterThanOrEqual(wallElapsed, 0.9, "零方向退避必须真实挂起任务")
        XCTAssertLessThan(
            cpuDelta,
            0.2,
            "1 秒退避期间 CPU 增量应显著低于 busy-loop（实测 \(cpuDelta) 秒）"
        )
    }

    /// 正常 EAGAIN 仍严格按照 libssh2 报告的读写方向等待 socket。
    func test_EAGAINBlockDirectionsMapToPollEvents() {
        XCTAssertEqual(
            SSHConnection.libssh2WaitPlan(
                directions: Int32(LIBSSH2_SESSION_BLOCK_INBOUND),
                remaining: 10
            ),
            .poll(events: Int16(POLLIN))
        )
        XCTAssertEqual(
            SSHConnection.libssh2WaitPlan(
                directions: Int32(LIBSSH2_SESSION_BLOCK_OUTBOUND),
                remaining: 10
            ),
            .poll(events: Int16(POLLOUT))
        )
        XCTAssertEqual(
            SSHConnection.libssh2WaitPlan(
                directions: Int32(
                    LIBSSH2_SESSION_BLOCK_INBOUND | LIBSSH2_SESSION_BLOCK_OUTBOUND
                ),
                remaining: 10
            ),
            .poll(events: Int16(POLLIN | POLLOUT))
        )
    }

    // MARK: - 测试 J：Trust Always 持久化 + 第二次连接免对话框（Phase 6 A+B）

    /// 首次 Trust Always → KnownHost 持久化；第二次连接（同一 knownHostService）直接 trusted，
    /// 不再进入 awaitingHostTrust 即到达 connected。证明不是内存缓存。
    func testJ_TrustAlwaysPersistsAndSecondConnectSkipsDialog() async throws {
        try await requireLocalSSHAndLiveCredential()

        // 第一次连接：未知主机 → Trust Always → connected，并持久化 KnownHost。
        let info1 = makeInfo()
        let connection1 = makeConnection(info: info1, credentialID: liveCredentialID)
        let task1 = Task { await connection1.connect() }

        _ = try await waitForPhase(info1, "首次等待 Host Trust") { $0 == .awaitingHostTrust }
        let verification1 = await MainActor.run { info1.hostKeyVerification }
        XCTAssertEqual(verification1, .unknown, "首次连接应为未知主机")

        await connection1.resolveHostTrust(.trustAlways)
        _ = try await waitForPhase(info1, "Trust Always 后 connected") { $0 == .connected }

        // KnownHost 必须已持久化（hostname + port 命中）。
        let stored = await MainActor.run {
            knownHostService.lookup(hostname: testHostname, port: Int(testPort))
        }
        XCTAssertNotNil(stored, "Trust Always 必须写入 KnownHost")
        XCTAssertFalse(stored?.hostKey.isEmpty ?? true, "KnownHost 必须保存完整 Host Key 字节")

        await connection1.disconnect()
        _ = try await waitForPhase(info1, "首次断开") { $0 == .disconnected }
        _ = await task1.result

        // 第二次连接（新 SSHConnection，复用同一 knownHostService）：
        // Host Key 匹配 → trusted → 直接认证，不进入 awaitingHostTrust。
        let info2 = makeInfo()
        let connection2 = makeConnection(info: info2, credentialID: liveCredentialID)
        let task2 = Task { await connection2.connect() }

        _ = try await waitForPhase(info2, "第二次连接直接 connected", timeout: 20) { $0 == .connected }
        let verification2 = await MainActor.run { info2.hostKeyVerification }
        XCTAssertEqual(verification2, .trusted, "第二次连接 Host Key 应匹配已信任记录")

        await connection2.disconnect()
        _ = try await waitForPhase(info2, "第二次断开") { $0 == .disconnected }
        _ = await task2.result
    }

    // MARK: - 测试 K：Host Key Changed 硬性阻断，绝不发送凭据（Phase 6 D，无需凭据）

    /// 预置一个错误的 KnownHost（与真实服务器 Host Key 不同），
    /// 连接应识别为 changed 并在认证前阻断；Cancel 后以 hostKeyChanged 失败，
    /// 全程不进入 authenticating。
    func testK_HostKeyChangedBlocksBeforeAuth() async throws {
        try await requireLocalSSH()

        // 预置错误 KnownHost：用一段不可能匹配真实 Host Key 的字节。
        let bogusKey = Data(repeating: 0xDE, count: 33)
        _ = try knownHostService.trust(
            hostname: testHostname,
            port: Int(testPort),
            keyType: "ssh-ed25519",
            hostKey: bogusKey,
            fingerprint: "SHA256:bbbbogusbbbbogusbbbbogusbbbbogusbbbbogusbbb="
        )

        let info = makeInfo()
        // 即使存在凭据也不会被使用；不保存任何真实 Secret。
        let connection = makeConnection(info: info, credentialID: nil)
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "Changed 后等待 Host Trust") { $0 == .awaitingHostTrust }
        let verification = await MainActor.run { info.hostKeyVerification }
        if case .changed = verification {
            // 期望：changed
        } else {
            XCTFail("Host Key 不匹配时应为 .changed，实际：\(String(describing: verification))")
        }

        // Cancel：必须以 hostKeyChanged 失败，绝不进入认证。
        await connection.resolveHostTrust(.cancel)

        let final = try await waitForPhase(info, "Changed Cancel 后阻断", timeout: 10) {
            if case let .failed(error) = $0 { return error == .hostKeyChanged }
            return false
        }
        if case let .failed(error) = final {
            XCTAssertEqual(error, .hostKeyChanged, "Changed 阻断不得发送 Password 或私钥")
            XCTAssertNotEqual(error, .authenticationFailed, "阻断阶段绝不能发送凭据")
        }

        await connection.disconnect()
        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 L：ED25519 私钥（无 Passphrase）认证成功（Phase 6）

    /// 使用测试专用 ed25519 私钥（无 Passphrase）认证。
    /// 测试 key 由 Scripts/run-ssh-tests.sh 生成并加入 authorized_keys，测试结束删除。
    func testL_PrivateKeyEd25519NoPassphraseAuthenticates() async throws {
        try await requireLocalSSH()
        let keyPath = TestKeys.ed25519NoPass
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: keyPath),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成并加入 authorized_keys"
        )

        let info = makeInfo()
        let connection = makeConnection(
            info: info,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: keyPath,
            privateKeyID: nil
        )
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "私钥连接等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        _ = try await waitForPhase(info, "私钥认证成功 connected", timeout: 20) { $0 == .connected }

        await connection.disconnect()
        _ = try await waitForPhase(info, "私钥连接断开") { $0 == .disconnected }
        _ = await connectTask.result
    }

    // MARK: - 测试 M：错误 Passphrase 认证失败（Phase 6）

    /// 使用带 Passphrase 的测试私钥，但保存一个错误 Passphrase，
    /// 应得到 privateKeyPassphraseIncorrect，不崩溃、不泄漏 Passphrase。
    func testM_WrongPassphraseFails() async throws {
        try await requireLocalSSH()
        let keyPath = TestKeys.ed25519WithPass
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: keyPath),
            "缺少测试带 Passphrase 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        // 保存一个确定错误的 Passphrase；在 tearDown 统一清理。
        let wrongPassID = UUID()
        extraPassphraseIDs.append(wrongPassID)
        try await CredentialService.shared.savePrivateKeyPassphrase(
            "macssh-wrong-passphrase-\(UUID().uuidString)",
            privateKeyID: wrongPassID
        )

        let info = makeInfo()
        let connection = makeConnection(
            info: info,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: keyPath,
            privateKeyID: wrongPassID
        )
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "私钥连接等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        let final = try await waitForPhase(info, "错误 Passphrase 得到失败", timeout: 20) {
            if case let .failed(error) = $0 {
                return error == .privateKeyPassphraseIncorrect
            }
            return false
        }
        if case let .failed(error) = final {
            XCTAssertEqual(error, .privateKeyPassphraseIncorrect)
        }

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 N：私钥文件不存在（Phase 6 Fix：保存有效路径后文件被删除）

    /// 模拟“Host 保存了有效私钥路径、之后文件被删除”：
    /// 复制有效测试私钥到临时路径后立即删除，连接必须以 privateKeyFileNotFound 失败，
    /// 不卡在认证中。
    func testN_PrivateKeyFileNotFound() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        let deletedKeyPath = "/tmp/macssh_phase6_deleted_\(UUID().uuidString)"
        try FileManager.default.copyItem(atPath: TestKeys.ed25519NoPass, toPath: deletedKeyPath)
        try FileManager.default.removeItem(atPath: deletedKeyPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedKeyPath))

        let info = makeInfo()
        let connection = makeConnection(
            info: info,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: deletedKeyPath,
            privateKeyID: nil
        )
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        let final = try await waitForPhase(info, "私钥文件不存在失败", timeout: 15) {
            if case let .failed(error) = $0 { return error == .privateKeyFileNotFound }
            return false
        }
        if case let .failed(error) = final {
            XCTAssertEqual(error, .privateKeyFileNotFound)
        }

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 O：Trust Always 持久化失败必须中止认证（Phase 6 Fix 安全阻塞项）

    /// Trust Always → KnownHost save failure → Authentication MUST NOT start。
    ///
    /// 注入“读正常、写失败”的 KnownHostService；knownHostPersistenceFailed 只可能由
    /// 信任决策持久化失败抛出，且抛出点位于进入 authenticating 之前——
    /// 若实现错误地继续认证，会得到 credentialNotFound / authenticationFailed 而非本错误。
    /// 同时高频采样阶段历史，双重验证从未进入 authenticating。
    func testO_TrustAlwaysPersistFailureBlocksAuthentication() async throws {
        try await requireLocalSSH()

        let failingService = makeFailingSaveKnownHostService()
        let info = makeInfo()
        // credentialID 为 nil：错误地继续认证会得到 credentialNotFound，可被断言区分。
        let connection = makeConnection(info: info, credentialID: nil, knownHostService: failingService)
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        let verification = await MainActor.run { info.hostKeyVerification }
        XCTAssertEqual(verification, .unknown, "无已存记录时应为未知主机")

        let recorder = PhaseRecorder()
        let sampler = Task {
            while !Task.isCancelled {
                let phase = await MainActor.run { info.phase }
                recorder.record(phase)
                if phase == .disconnected || Self.isFailed(phase) { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { sampler.cancel() }

        await connection.resolveHostTrust(.trustAlways)

        let final = try await waitForPhase(info, "Trust Always 持久化失败必须显式失败", timeout: 15) {
            if case let .failed(error) = $0 { return error == .knownHostPersistenceFailed }
            return false
        }
        if case let .failed(error) = final {
            XCTAssertEqual(
                error,
                .knownHostPersistenceFailed,
                "KnownHost 保存失败必须中止认证并返回明确业务错误"
            )
        }

        try await Task.sleep(nanoseconds: 200_000_000) // 让采样器收尾。
        XCTAssertFalse(
            recorder.sawAuthenticating,
            "持久化失败后绝不能进入 authenticating（采样到的阶段均未包含）"
        )

        // 保存失败后不得残留任何信任记录（回滚验证）。
        let stored = knownHostService.lookup(hostname: testHostname, port: Int(testPort))
        XCTAssertNil(stored, "持久化失败后不得留下内存中的信任记录")

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 P：Replace Trusted Key 持久化失败必须中止认证（Phase 6 Fix 安全阻塞项）

    /// Host Key Changed → Replace → Persist failure → Authentication not called → 连接显式失败。
    /// 旧 KnownHost 不得被错误标记为已成功替换。
    func testP_ReplaceTrustedKeyPersistFailureBlocksAuthentication() async throws {
        try await requireLocalSSH()

        // 正常服务预置与真实服务器不同的旧 Host Key（Changed 前提）。
        let bogusKey = Data(repeating: 0xDE, count: 33)
        _ = try knownHostService.trust(
            hostname: testHostname,
            port: Int(testPort),
            keyType: "ssh-ed25519",
            hostKey: bogusKey,
            fingerprint: "SHA256:oldbogusoldbogusoldbogusoldbogusoldbogusold="
        )

        let failingService = makeFailingSaveKnownHostService()
        let info = makeInfo()
        let connection = makeConnection(info: info, credentialID: nil, knownHostService: failingService)
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Key Changed 警告") { $0 == .awaitingHostTrust }
        let verification = await MainActor.run { info.hostKeyVerification }
        guard case .changed = verification else {
            XCTFail("预置旧 Key 与真实 Key 不同时应为 .changed，实际：\(String(describing: verification))")
            return
        }

        let recorder = PhaseRecorder()
        let sampler = Task {
            while !Task.isCancelled {
                let phase = await MainActor.run { info.phase }
                recorder.record(phase)
                if phase == .disconnected || Self.isFailed(phase) { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { sampler.cancel() }

        // 用户选择 Replace（UI 二次确认之后的决策）。
        await connection.resolveHostTrust(.replaceTrustedKey)

        let final = try await waitForPhase(info, "Replace 持久化失败必须显式失败", timeout: 15) {
            if case let .failed(error) = $0 { return error == .knownHostPersistenceFailed }
            return false
        }
        if case let .failed(error) = final {
            XCTAssertEqual(
                error,
                .knownHostPersistenceFailed,
                "替换保存失败必须中止认证并返回明确业务错误"
            )
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            recorder.sawAuthenticating,
            "替换持久化失败后绝不能进入 authenticating"
        )

        // 旧 KnownHost 保持原样（不得被标记为已成功替换）。
        let stored = knownHostService.lookup(hostname: testHostname, port: Int(testPort))
        XCTAssertEqual(stored?.hostKey, bogusKey, "替换失败后旧 KnownHost 必须保持不变")

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 Q：Replace Trusted Key 成功后重连免警告（Phase 6 Fix 真实验收）

    /// 预置旧 Key（与真实服务器不同，等价于服务器换钥后的客户端视角）→
    /// Changed 警告 → Replace → 持久化成功 → Private Key 认证 → Connected；
    /// 再次连接：当前 Key 与新保存的 Key 匹配 → 无警告、直接 Connected。
    func testQ_ReplaceTrustedKeyPersistsAndReconnectsWithoutWarning() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成并加入 authorized_keys"
        )

        let bogusKey = Data(repeating: 0xDE, count: 33)
        _ = try knownHostService.trust(
            hostname: testHostname,
            port: Int(testPort),
            keyType: "ssh-ed25519",
            hostKey: bogusKey,
            fingerprint: "SHA256:oldbogusoldbogusoldbogusoldbogusoldbogusold="
        )

        // 第一次连接：Changed → Replace → 持久化 → 私钥认证 → Connected。
        let info1 = makeInfo()
        let connection1 = makeConnection(
            info: info1,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.ed25519NoPass,
            privateKeyID: nil
        )
        let task1 = Task { await connection1.connect() }

        _ = try await waitForPhase(info1, "等待 Host Key Changed 警告") { $0 == .awaitingHostTrust }
        let verification1 = await MainActor.run { info1.hostKeyVerification }
        guard case .changed = verification1 else {
            XCTFail("预置旧 Key 不同时应为 .changed，实际：\(String(describing: verification1))")
            return
        }

        await connection1.resolveHostTrust(.replaceTrustedKey)
        _ = try await waitForPhase(info1, "Replace 后私钥认证成功", timeout: 20) { $0 == .connected }

        // 替换后的 KnownHost 必须已保存真实服务器 Key。
        let realKey = await MainActor.run { info1.hostKey?.hostKeyBlob }
        let stored = knownHostService.lookup(hostname: testHostname, port: Int(testPort))
        XCTAssertEqual(stored?.hostKey, realKey, "Replace 必须持久化当前真实 Host Key")

        await connection1.disconnect()
        _ = try await waitForPhase(info1, "首次断开") { $0 == .disconnected }
        _ = await task1.result

        // 第二次连接：Key 匹配新保存记录 → 不再警告，直接认证连接。
        let info2 = makeInfo()
        let connection2 = makeConnection(
            info: info2,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.ed25519NoPass,
            privateKeyID: nil
        )
        let task2 = Task { await connection2.connect() }

        _ = try await waitForPhase(info2, "第二次连接直接 connected", timeout: 20) { $0 == .connected }
        let verification2 = await MainActor.run { info2.hostKeyVerification }
        XCTAssertEqual(verification2, .trusted, "第二次连接 Host Key 应匹配替换后的记录")

        await connection2.disconnect()
        _ = try await waitForPhase(info2, "第二次断开") { $0 == .disconnected }
        _ = await task2.result
    }

    // MARK: - 测试 R：Trust Always 落盘持久化（容器重建等价于 App 重启）

    /// Trust Always 写入的是磁盘 SwiftData 存储；用同一 store URL 重建 ModelContainer
    /// （等价于完全退出后重新启动的持久化语义），第二次连接免对话框直达 connected。
    func testR_TrustAlwaysOnDiskPersistenceAcrossContainerReload() async throws {
        try await requireLocalSSHAndLiveCredential()

        let storeURL = URL(fileURLWithPath: "/tmp/macssh_phase6_ondisk_\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
        }

        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let onDiskConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let container1 = try ModelContainer(for: schema, configurations: [onDiskConfiguration])
        let service1 = KnownHostService(modelContainer: container1)

        // 第一次连接：Trust Always → 认证成功 → 落盘。
        let info1 = makeInfo()
        let connection1 = SSHConnection(
            configuration: makeConfiguration(info: info1, credentialID: liveCredentialID),
            info: info1,
            knownHostService: service1
        )
        let task1 = Task { await connection1.connect() }

        _ = try await waitForPhase(info1, "首次等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection1.resolveHostTrust(.trustAlways)
        _ = try await waitForPhase(info1, "Trust Always 后 connected") { $0 == .connected }
        await connection1.disconnect()
        _ = try await waitForPhase(info1, "首次断开") { $0 == .disconnected }
        _ = await task1.result

        // 重建容器（等价于重启后从磁盘加载）：必须读到已保存的 KnownHost。
        let container2 = try ModelContainer(for: schema, configurations: [onDiskConfiguration])
        let service2 = KnownHostService(modelContainer: container2)
        let reloaded = service2.lookup(hostname: testHostname, port: Int(testPort))
        XCTAssertNotNil(reloaded, "Trust Always 必须真实落盘，容器重建后仍可读取")
        let firstHostKey = await MainActor.run { info1.hostKey?.hostKeyBlob }
        XCTAssertEqual(
            reloaded?.hostKey,
            firstHostKey,
            "落盘的必须是真实服务器 Host Key"
        )

        // 第二次连接（新容器 + 新服务）：免对话框直接 connected。
        let info2 = makeInfo()
        let connection2 = SSHConnection(
            configuration: makeConfiguration(info: info2, credentialID: liveCredentialID),
            info: info2,
            knownHostService: service2
        )
        let task2 = Task { await connection2.connect() }

        _ = try await waitForPhase(info2, "重启等价后直接 connected", timeout: 20) { $0 == .connected }
        let verification2 = await MainActor.run { info2.hostKeyVerification }
        XCTAssertEqual(verification2, .trusted)

        await connection2.disconnect()
        _ = try await waitForPhase(info2, "第二次断开") { $0 == .disconnected }
        _ = await task2.result
    }

    // MARK: - 测试 S：Forget Known Host 后回到 Unknown Host（回归）

    /// Trust Always 持久化 → Forget（remove）→ 重新连接必须重新出现 Unknown Host 对话框。
    func testS_ForgetRestoresUnknownHostDialog() async throws {
        try await requireLocalSSH()

        // 第一次连接：Trust Always 持久化（credentialID 为 nil，认证会失败，
        // 但信任记录在认证开始前已写入；失败状态不影响本测试关注点）。
        let info1 = makeInfo()
        let connection1 = makeConnection(info: info1, credentialID: nil)
        let task1 = Task { await connection1.connect() }

        _ = try await waitForPhase(info1, "首次等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection1.resolveHostTrust(.trustAlways)
        _ = try await waitForPhase(info1, "首次连接终结", timeout: 15) {
            $0 == .failed(.credentialNotFound) || $0 == .connected
        }
        await connection1.disconnect()
        _ = await task1.result

        let stored = knownHostService.lookup(hostname: testHostname, port: Int(testPort))
        XCTAssertNotNil(stored, "Trust Always 应已写入记录")

        // Forget：删除信任记录。
        try knownHostService.remove(stored!)
        XCTAssertNil(knownHostService.lookup(hostname: testHostname, port: Int(testPort)))

        // 重新连接：必须重新出现 Unknown Host 对话框（Trust Once / Trust Always / Cancel）。
        let info2 = makeInfo()
        let connection2 = makeConnection(info: info2, credentialID: nil)
        let task2 = Task { await connection2.connect() }

        _ = try await waitForPhase(info2, "Forget 后重新等待 Host Trust") { $0 == .awaitingHostTrust }
        let verification2 = await MainActor.run { info2.hostKeyVerification }
        XCTAssertEqual(verification2, .unknown, "Forget 后再次连接必须回到 Unknown Host")

        await connection2.resolveHostTrust(.cancel)
        _ = try await waitForPhase(info2, "Cancel 后结束", timeout: 10) {
            $0 == .disconnected || $0 == .failed(.hostTrustRejected)
        }
        await connection2.disconnect()
        _ = await task2.result
    }

    // MARK: - 测试 T：未授权 Private Key 认证失败（不回退 Password）

    /// 使用未加入 authorized_keys 的私钥：必须 privateKeyAuthenticationFailed，
    /// 不崩溃、不卡死、不自动尝试 Password。
    func testT_UnauthorizedPrivateKeyFails() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.unauthorized),
            "缺少未授权测试私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        let info = makeInfo()
        let connection = makeConnection(
            info: info,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.unauthorized,
            privateKeyID: nil
        )
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        let final = try await waitForPhase(info, "未授权私钥认证失败", timeout: 20) {
            if case let .failed(error) = $0 { return error == .privateKeyAuthenticationFailed }
            return false
        }
        if case let .failed(error) = final {
            XCTAssertEqual(
                error,
                .privateKeyAuthenticationFailed,
                "未授权私钥必须 privateKeyAuthenticationFailed，且不得自动回退 Password"
            )
        }

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 U：正确 Passphrase 认证成功（Phase 6 Fix 真实验收）

    /// ED25519 + Passphrase：Passphrase 经 CredentialService 存入 Keychain，
    /// 真实连接读取并解密私钥认证成功。Passphrase 值不进入任何日志、断言或输出。
    func testU_CorrectPassphraseAuthenticates() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519WithPass)
                && FileManager.default.fileExists(atPath: TestKeys.ed25519WithPassSecret),
            "缺少带 Passphrase 测试私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        // 读取脚本生成的随机 Passphrase 后立即删除临时文件；
        // 通过 CredentialService（真实 Keychain）保存，tearDown 统一清理。
        let passphrase = try String(
            contentsOf: URL(fileURLWithPath: TestKeys.ed25519WithPassSecret),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(atPath: TestKeys.ed25519WithPassSecret)
        XCTAssertFalse(passphrase.isEmpty)

        let passID = UUID()
        extraPassphraseIDs.append(passID)
        try await CredentialService.shared.savePrivateKeyPassphrase(passphrase, privateKeyID: passID)

        let info = makeInfo()
        let connection = makeConnection(
            info: info,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.ed25519WithPass,
            privateKeyID: passID
        )
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        _ = try await waitForPhase(info, "正确 Passphrase 认证成功", timeout: 20) { $0 == .connected }

        await connection.disconnect()
        _ = try await waitForPhase(info, "断开") { $0 == .disconnected }
        _ = await connectTask.result
    }

    // MARK: - 测试 V / W：RSA / ECDSA 私钥认证（真实测试边界）

    /// RSA 私钥（无 Passphrase）真实认证。只有真实执行通过才算“已验证支持”。
    func testV_RSAKeyAuthenticates() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.rsa),
            "缺少测试 RSA 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        let info = makeInfo()
        let connection = makeConnection(
            info: info,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.rsa,
            privateKeyID: nil
        )
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        _ = try await waitForPhase(info, "RSA 私钥认证成功", timeout: 20) { $0 == .connected }

        await connection.disconnect()
        _ = try await waitForPhase(info, "断开") { $0 == .disconnected }
        _ = await connectTask.result
    }

    /// ECDSA 私钥（无 Passphrase）真实认证。只有真实执行通过才算“已验证支持”。
    func testW_ECDSAKeyAuthenticates() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ecdsa),
            "缺少测试 ECDSA 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        let info = makeInfo()
        let connection = makeConnection(
            info: info,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.ecdsa,
            privateKeyID: nil
        )
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)

        _ = try await waitForPhase(info, "ECDSA 私钥认证成功", timeout: 20) { $0 == .connected }

        await connection.disconnect()
        _ = try await waitForPhase(info, "断开") { $0 == .disconnected }
        _ = await connectTask.result
    }

    // MARK: - 20 次 Private Key Connect / Disconnect 资源泄漏验证（Phase 6 Fix）

    func test_TwentyPrivateKeyConnectDisconnectCyclesNoLeak() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        let fdProbeBefore = probeFileDescriptor()
        let threadsBefore = threadCount()
        let memoryBefore = residentMemoryBytes()

        for cycle in 1...20 {
            let info = makeInfo()
            let connection = makeConnection(
                info: info,
                credentialID: nil,
                authenticationType: .privateKey,
                privateKeyPath: TestKeys.ed25519NoPass,
                privateKeyID: nil
            )
            let connectTask = Task { await connection.connect() }

            _ = try await waitForPhase(
                info,
                "第 \(cycle) 轮等待 Host Trust",
                timeout: 15
            ) { $0 == .awaitingHostTrust }

            await connection.resolveHostTrust(.trustOnce)

            _ = try await waitForPhase(
                info,
                "第 \(cycle) 轮私钥连接成功",
                timeout: 20
            ) { $0 == .connected }

            await connection.disconnect()
            _ = try await waitForPhase(info, "第 \(cycle) 轮断开") { $0 == .disconnected }

            _ = await connectTask.result
        }

        let fdProbeAfter = probeFileDescriptor()
        let threadsAfter = threadCount()
        let memoryAfter = residentMemoryBytes()

        XCTAssertLessThanOrEqual(
            fdProbeAfter - fdProbeBefore,
            2,
            "20 次私钥连接后 FD 不应持续增长（before=\(fdProbeBefore), after=\(fdProbeAfter)）"
        )
        XCTAssertLessThanOrEqual(
            threadsAfter - threadsBefore,
            4,
            "20 次私钥连接后线程数不应持续增长（before=\(threadsBefore), after=\(threadsAfter)）"
        )
        XCTAssertLessThanOrEqual(
            memoryAfter - memoryBefore,
            32 * 1024 * 1024,
            "20 次私钥连接后常驻内存不应持续增长（before=\(memoryBefore), after=\(memoryAfter)）"
        )
    }

    // MARK: - Private Key 连接空闲 CPU 验证（Phase 6 Fix）

    func test_IdleCPUAfterPrivateKeyConnected() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        let info = makeInfo()
        let connection = makeConnection(
            info: info,
            credentialID: nil,
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.ed25519NoPass,
            privateKeyID: nil
        )
        let connectTask = Task { await connection.connect() }

        _ = try await waitForPhase(info, "等待 Host Trust") { $0 == .awaitingHostTrust }
        await connection.resolveHostTrust(.trustOnce)
        _ = try await waitForPhase(info, "私钥连接成功", timeout: 20) { $0 == .connected }

        // 认证成功进入 Connected 后空闲 30 秒：不得 EAGAIN busy-loop。
        let usageBefore = Self.processCPUSeconds()
        try await Task.sleep(nanoseconds: 30_000_000_000)
        let cpuDelta = Self.processCPUSeconds() - usageBefore

        XCTAssertLessThanOrEqual(
            cpuDelta,
            1.0,
            "私钥连接空闲 30 秒 CPU 增量应接近 0（实测 \(String(format: "%.3f", cpuDelta)) 秒）"
        )

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - Secret 字节清零机制（Phase 6 Fix：Passphrase 清零测试边界）

    /// 直接断言清零机制本身。真实成功路径（testL/testU）与失败路径（testM/testT）
    /// 都执行 defer 清零代码路径；物理内存清零无法从 Swift 直接断言，
    /// 该边界在 DevelopmentStatus 中如实说明。
    func test_zeroSecretBytesOverwritesArray() {
        var bytes = Array("macssh-secret-test-value".utf8CString)
        XCTAssertTrue(
            bytes.contains { $0 != 0 },
            "前置：缓冲区应含非零 Secret 字节"
        )

        SSHConnection.zeroSecretBytes(&bytes)

        XCTAssertTrue(
            bytes.allSatisfy { $0 == 0 },
            "清零后所有字节必须为 0"
        )
    }

    func test_zeroSecretBytesOverwritesManualBuffer() {
        let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 16)
        defer { buffer.deallocate() }
        for index in 0..<16 {
            buffer[index] = CChar(truncatingIfNeeded: 0x41 + index)
        }

        SSHConnection.zeroSecretBytes(buffer)

        XCTAssertTrue(
            buffer.allSatisfy { $0 == 0 },
            "清零后手动缓冲区所有字节必须为 0"
        )
    }

    // MARK: - 辅助

    private func makeInfo() -> SSHConnectionInfo {
        SSHConnectionInfo(
            hostID: UUID(),
            hostname: testHostname,
            port: testPort,
            username: testUsername
        )
    }

    private func makeConfiguration(
        info: SSHConnectionInfo,
        credentialID: UUID?,
        authenticationType: AuthenticationType = .password,
        privateKeyPath: String? = nil,
        privateKeyID: UUID? = nil
    ) -> SSHConnection.Configuration {
        SSHConnection.Configuration(
            hostID: info.hostID,
            hostname: info.hostname,
            port: info.port,
            username: info.username,
            authenticationType: authenticationType,
            credentialID: credentialID,
            privateKeyPath: privateKeyPath,
            privateKeyID: privateKeyID
        )
    }

    /// 构造被测连接；credentialID 为 nil 表示无凭据配置；
    /// knownHostService 可注入“保存失败”的服务以覆盖持久化失败路径。
    private func makeConnection(
        info: SSHConnectionInfo,
        credentialID: UUID?,
        authenticationType: AuthenticationType = .password,
        privateKeyPath: String? = nil,
        privateKeyID: UUID? = nil,
        knownHostService service: KnownHostService? = nil
    ) -> SSHConnection {
        let config = makeConfiguration(
            info: info,
            credentialID: credentialID,
            authenticationType: authenticationType,
            privateKeyPath: privateKeyPath,
            privateKeyID: privateKeyID
        )
        return SSHConnection(
            configuration: config,
            info: info,
            knownHostService: service ?? knownHostService
        )
    }

    /// 注入“读正常、写失败”的 KnownHostService（共享本测试的内存容器）。
    private func makeFailingSaveKnownHostService() -> KnownHostService {
        KnownHostService(modelContainer: knownHostContainer) { _ in
            throw NSError(domain: "SSHConnectionTests", code: 1)
        }
    }

    private static func isFailed(_ phase: SSHConnectionPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    /// 高频采样连接阶段历史，用于断言“从未进入 authenticating”。
    /// 与终态错误断言（knownHostPersistenceFailed 只能在进入 authenticating 之前抛出）
    /// 互为补充的双重验证。
    private final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [SSHConnectionPhase] = []

        func record(_ phase: SSHConnectionPhase) {
            lock.lock()
            defer { lock.unlock() }
            samples.append(phase)
        }

        var sawAuthenticating: Bool {
            lock.lock()
            defer { lock.unlock() }
            return samples.contains { $0 == .authenticating }
        }
    }

    /// 轮询等待阶段满足条件；超时记录失败并返回最后状态。
    private func waitForPhase(
        _ info: SSHConnectionInfo,
        _ description: String,
        timeout: TimeInterval = 15,
        where predicate: (SSHConnectionPhase) -> Bool
    ) async throws -> SSHConnectionPhase {
        let deadline = Date().addingTimeInterval(timeout)
        var lastPhase = await MainActor.run { info.phase }
        while Date() < deadline {
            lastPhase = await MainActor.run { info.phase }
            if predicate(lastPhase) {
                return lastPhase
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待阶段超时（\(description)），最后状态：\(lastPhase.statusText)")
        return lastPhase
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// 需要本机 sshd 的测试调用；不可达时跳过。
    private func requireLocalSSH() async throws {
        let reachable = await isTCPPortOpen(host: testHostname, port: testPort)
        try XCTSkipUnless(
            reachable,
            "本机 127.0.0.1:22 未开放：请在 系统设置 → 通用 → 共享 → 远程登录 中开启"
        )
    }

    /// 需要本机 sshd + 测试脚本预置 Keychain 凭据的测试调用。
    private func requireLocalSSHAndLiveCredential() async throws {
        try await requireLocalSSH()
        let credentialExists = (try? await CredentialService.shared.readPassword(
            credentialID: liveCredentialID
        )) != nil
        try XCTSkipUnless(
            credentialExists,
            "缺少 Phase 5 测试专用 Keychain 凭据：请使用 Scripts/run-ssh-tests.sh"
        )
    }

    /// 确认本机某端口无服务监听（测试 D 的前提）。
    private func isPortClosed(port: UInt16) throws -> Bool {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(testHostname))

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "SSHConnectionTests", code: 1)
        }
        defer { close(fd) }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 // 连接失败（含 ECONNREFUSED）即视为无监听。
    }

    private func isTCPPortOpen(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr = in_addr(s_addr: inet_addr(host))

                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: false)
                    return
                }
                defer { close(fd) }

                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.connect(
                            fd,
                            sockaddrPointer,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }

                var ready = false
                if result == 0 {
                    ready = true
                } else if errno == EINPROGRESS {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, 2000) > 0 {
                        // POLLOUT 也会在异步 connect 失败时触发；必须读取
                        // SO_ERROR，不能把 ECONNREFUSED 误判成端口开放。
                        var socketError: Int32 = 0
                        var errorLength = socklen_t(MemoryLayout<Int32>.size)
                        let status = getsockopt(
                            fd,
                            SOL_SOCKET,
                            SO_ERROR,
                            &socketError,
                            &errorLength
                        )
                        ready = status == 0 && socketError == 0
                    }
                }

                continuation.resume(returning: ready)
            }
        }
    }

    /// 通过打开 /dev/null 探测当前 FD 高位值，用于泄漏检测。
    private func probeFileDescriptor() -> Int32 {
        let fd = open("/dev/null", O_RDONLY)
        let value = fd
        if fd >= 0 {
            close(fd)
        }
        return value
    }

    /// 当前进程线程数（Mach task_threads）。
    private func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        let kr = task_threads(mach_task_self_, &threads, &count)
        guard kr == KERN_SUCCESS, let threads else { return -1 }

        let size = vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: threads)),
            size
        )
        return Int(count)
    }

    /// 当前进程常驻内存（字节），用于 20 次连接循环的内存增长检查。
    private func residentMemoryBytes() -> Int64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int64(info.resident_size)
    }

    /// 进程累计 CPU 时间（用户 + 系统，秒）。
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
