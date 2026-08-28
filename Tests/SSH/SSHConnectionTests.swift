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

    /// 每个测试独立的 Keychain 凭据标识。
    private var credentialID: UUID!

    override func setUp() async throws {
        continueAfterFailure = false
        credentialID = UUID()
    }

    override func tearDown() async throws {
        // 尽力清理测试凭据；Secret 不进入任何日志。
        if let credentialID {
            _ = try? await CredentialService.shared.deletePassword(credentialID: credentialID)
        }
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

    // MARK: - 测试 I：Private Key Host 明确不支持

    @MainActor
    func testI_PrivateKeyHostExplicitlyUnavailable() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let host = Host(
            name: "Phase 5 Test Private Key",
            hostname: testHostname,
            port: Int(testPort),
            username: testUsername,
            authenticationType: .privateKey,
            credentialID: nil
        )
        context.insert(host)

        let service = SSHService(modelContainer: container)
        service.connect(to: host)

        let info = service.connectionInfo(for: host.id)
        XCTAssertNotNil(info)
        if case let .failed(error) = info?.phase {
            XCTAssertEqual(error, .privateKeyAuthenticationUnavailable)
            XCTAssertEqual(
                info?.failureMessage,
                "Private key authentication is not available in Phase 5."
            )
        } else {
            XCTFail("Private Key Host 应明确提示 Phase 5 不支持")
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

    // MARK: - 辅助

    private func makeInfo() -> SSHConnectionInfo {
        SSHConnectionInfo(
            hostID: UUID(),
            hostname: testHostname,
            port: testPort,
            username: testUsername
        )
    }

    /// 构造被测连接；credentialID 为 nil 表示无凭据配置。
    private func makeConnection(
        info: SSHConnectionInfo,
        credentialID: UUID?
    ) -> SSHConnection {
        let config = SSHConnection.Configuration(
            hostID: info.hostID,
            hostname: info.hostname,
            port: info.port,
            username: info.username,
            authenticationType: .password,
            credentialID: credentialID
        )
        return SSHConnection(configuration: config, info: info)
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
        let schema = Schema([Host.self, HostGroup.self])
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

    /// 进程累计 CPU 时间（用户 + 系统，秒）。
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
