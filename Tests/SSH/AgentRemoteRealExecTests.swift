import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 10E-B3 §117–§124：真实本机 sshd + 真实 libssh2 的 Remote exec 验收。
///
/// 前置（与 `AgentRemoteRealSFTPTests` 相同的既有 fixture，**不新建凭据 / 不改
/// 系统设置**）：系统设置 → 共享 → 远程登录 已开启，且测试私钥
/// `/tmp/macssh_phase6_ed25519` 已生成、其公钥已加入 `authorized_keys`。
/// 缺失任一前置 → `XCTSkip`（不计入 external exclusion；进入 skipped）。
///
/// 所有 fixture 目录位于 `FileManager.default.temporaryDirectory` 下的
/// `macssh-b3-exec-<uuid>`：绝不修改 HOME / ~/.ssh / 生产 repository。
@MainActor
final class AgentRemoteRealExecTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
    }

    private var knownHostContainer: ModelContainer!
    private var knownHostService: KnownHostService!
    private var openConnections: [SSHConnection] = []
    private var root = ""
    private var sessionID = UUID()

    override func setUp() async throws {
        continueAfterFailure = false
        openConnections = []
        sessionID = UUID()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-b3-exec-" + UUID().uuidString.lowercased())
            .path
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        knownHostContainer = try ModelContainer(for: schema, configurations: [configuration])
        knownHostService = KnownHostService(modelContainer: knownHostContainer)
    }

    override func tearDown() async throws {
        for connection in openConnections {
            await connection.disconnect()
        }
        openConnections.removeAll()
        try? FileManager.default.removeItem(atPath: root)
        knownHostService?.removeAll()
        knownHostService = nil
        knownHostContainer = nil
    }

    // MARK: - 装配

    private func prepare() async throws -> SSHConnection {
        try await requireLocalSSHAndTestKey()
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true
        )
        return try await makeAuthenticatedTestKeyConnection()
    }

    /// 只把 `self.sessionID` 解析到给定连接（其余 sessionID 一律 nil）。
    private func executor(
        for connection: SSHConnection,
        policy: AgentRemoteCommandExecutionPolicy
    ) -> AgentRemoteCommandExecutor {
        let boundSessionID = sessionID
        return AgentRemoteCommandExecutor(
            policy: policy,
            resolver: AgentRemoteCommandSessionResolver { requested in
                requested == boundSessionID ? connection : nil
            }
        )
    }

    private static let livePolicy = AgentRemoteCommandExecutionPolicy(
        timeout: .seconds(15),
        terminationGracePeriod: .milliseconds(300)
    )

    @discardableResult
    private func execute(
        _ command: String,
        on connection: SSHConnection,
        workingDirectory: String? = nil,
        policy: AgentRemoteCommandExecutionPolicy = AgentRemoteRealExecTests.livePolicy,
        sessionID: UUID? = nil,
        resolver: AgentRemoteCommandSessionResolver? = nil
    ) async throws -> AgentRemoteCommandResult {
        let boundSessionID = self.sessionID
        let effectiveResolver = resolver ?? AgentRemoteCommandSessionResolver { requested in
            requested == boundSessionID ? connection : nil
        }
        let coordinator = AgentCommandApprovalCoordinator()
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            sessionID: sessionID ?? boundSessionID,
            target: .remote(displayName: "b3-live"),
            command: command,
            workingDirectory: AgentWorkingDirectory(
                path: workingDirectory ?? root,
                source: .osc7,
                confidence: .authoritative
            )
        )
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentCommandClaimExpectations(
                generationID: request.generationID,
                sessionID: request.sessionID,
                providerSnapshotID: request.providerBinding.snapshotID
            )
        )
        return try await AgentRemoteCommandExecutor(
            policy: policy, resolver: effectiveResolver
        ).execute(
            authorization: authorization,
            approvalCoordinator: coordinator
        )
    }

    // MARK: - §123 权威 cwd

    func testRealPWDMatchesApprovedAuthoritativeCWD() async throws {
        let connection = try await prepare()
        let result = try await execute("pwd -P", on: connection)
        let expected = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        XCTAssertEqual(result.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        XCTAssertEqual(result.termination, .exitStatus(0))
    }

    func testRealCWDWithSpacesAndSingleQuoteIsQuotedSafely() async throws {
        let connection = try await prepare()
        let tricky = root + "/dir with 'quote' and spaces"
        try FileManager.default.createDirectory(atPath: tricky, withIntermediateDirectories: true)

        let result = try await execute("pwd -P && printf 'reachable\\n'", on: connection, workingDirectory: tricky)
        let expected = URL(fileURLWithPath: tricky).resolvingSymlinksInPath().path
        XCTAssertEqual(result.result.stdout, expected + "\nreachable\n")
        XCTAssertEqual(result.termination, .exitStatus(0))
    }

    // MARK: - §50/§122 stdout / stderr / exit status

    func testRealStdoutAndStderrAreSeparateStreams() async throws {
        let connection = try await prepare()
        let result = try await execute(
            "printf 'to-stdout\\n'; printf 'to-stderr\\n' >&2",
            on: connection
        )
        XCTAssertEqual(result.result.stdout, "to-stdout\n")
        XCTAssertEqual(result.result.stderr, "to-stderr\n")
        XCTAssertEqual(result.termination, .exitStatus(0))
    }

    func testRealExitSevenIsValidResultNotInfrastructureError() async throws {
        let connection = try await prepare()
        let result = try await execute("exit 7", on: connection)
        XCTAssertEqual(result.result.exitCode, 7)
        XCTAssertEqual(result.termination, .exitStatus(7))
        XCTAssertFalse(result.result.timedOut)
    }

    func testRealCommandNotFoundYieldsOneHundredTwentySeven() async throws {
        let connection = try await prepare()
        let result = try await execute("nonexistent_command_phase10e_b3_xyz", on: connection)
        XCTAssertEqual(result.result.exitCode, 127)
        XCTAssertFalse(result.result.stderr.isEmpty)
    }

    // MARK: - §103/§122 stdin EOF

    func testRealStdinIsImmediatelyAtEOF() async throws {
        let connection = try await prepare()
        let result = try await execute(#"cat; printf 'cat-exit=%s\n' "$?""#, on: connection)
        XCTAssertEqual(result.result.stdout, "cat-exit=0\n")
        XCTAssertFalse(result.result.timedOut)
    }

    // MARK: - §40/§41/§93/§94 多行 / 注释 / here-doc

    func testRealMultilineCommentAndHereDocumentKeepSemantics() async throws {
        let connection = try await prepare()
        let result = try await execute(
            "# comment line\nprintf 'first\\n'\ncat <<'MACSSH_EOF'\nhello\nMACSSH_EOF",
            on: connection
        )
        XCTAssertEqual(result.result.stdout, "first\nhello\n")
        XCTAssertEqual(result.termination, .exitStatus(0))
    }

    // MARK: - §100/§122 大输出

    func testRealLargeOutputIsTruncatedAtCapsWithoutDeadlock() async throws {
        let connection = try await prepare()
        let result = try await execute(
            "awk 'BEGIN { for (i = 0; i < 400000; i++) printf \"a\" }'"
                + "; awk 'BEGIN { for (i = 0; i < 400000; i++) printf \"b\" }' >&2",
            on: connection
        )
        XCTAssertTrue(result.result.stdoutTruncated)
        XCTAssertTrue(result.result.stderrTruncated)
        XCTAssertEqual(result.result.stdout.utf8.count, AgentCommandExecutionLimits.stdoutMaxBytes)
        XCTAssertEqual(result.result.stderr.utf8.count, AgentCommandExecutionLimits.stderrMaxBytes)
        XCTAssertFalse(result.result.timedOut, "双流大输出绝不 deadlock")
    }

    // MARK: - §104/§105/§122 timeout / 取消

    func testRealTimeoutReturnsTimedOutAndCleansChannel() async throws {
        let connection = try await prepare()
        let policy = AgentRemoteCommandExecutionPolicy(
            timeout: .seconds(1),
            terminationGracePeriod: .milliseconds(300)
        )
        let result = try await execute("sleep 30", on: connection, policy: policy)
        XCTAssertTrue(result.result.timedOut)
        XCTAssertTrue(result.remoteTerminationRequested)
        let open = await connection.openExecChannelCount
        XCTAssertEqual(open, 0, "§66：timeout 后 exec channel 必须已释放")
        // §124：不声称远端进程必然死亡——只报告本地清理与 best-effort 请求。
    }

    func testRealCancellationReturnsCancelledAndCleansChannel() async throws {
        let connection = try await prepare()
        let coordinator = AgentCommandApprovalCoordinator()
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            sessionID: sessionID,
            target: .remote(displayName: "b3-live"),
            command: "sleep 30",
            workingDirectory: AgentWorkingDirectory(
                path: root, source: .osc7, confidence: .authoritative
            )
        )
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentCommandClaimExpectations(
                generationID: request.generationID,
                sessionID: request.sessionID,
                providerSnapshotID: request.providerBinding.snapshotID
            )
        )
        let executor = executor(for: connection, policy: Self.livePolicy)
        let task = Task {
            try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()

        let result = try await task.value
        XCTAssertTrue(result.result.cancelled)
        XCTAssertFalse(result.result.timedOut)
        XCTAssertTrue(result.remoteTerminationRequested)
        let open = await connection.openExecChannelCount
        XCTAssertEqual(open, 0)
    }

    // MARK: - §73/§74/§115/§116/§122 PTY / SFTP 共存

    func testRealPTYRemainsResponsiveAcrossExecLifecycle() async throws {
        let connection = try await prepare()
        try await connection.openInteractiveShell(columns: 80, rows: 24)
        _ = try await drainShellOutput(connection, seconds: 2)

        let execResult = try await execute("printf 'EXEC-DONE\\n'", on: connection)
        XCTAssertEqual(execResult.result.stdout, "EXEC-DONE\n")

        let ptyOutput = try await runShellCommand(connection, "printf 'PTY-OK\\n'")
        XCTAssertTrue(ptyOutput.contains("PTY-OK"), "§73：exec 之后 PTY 必须仍可输入 / 输出")
        let shellOpen = await connection.hasOpenShellChannel
        XCTAssertTrue(shellOpen, "§63：exec 绝不关闭 interactive shell channel")
    }

    func testRealSFTPRemainsUsableAcrossExecLifecycle() async throws {
        let connection = try await prepare()
        try FileManager.default.createDirectory(
            atPath: root + "/sftp-probe", withIntermediateDirectories: true
        )
        try "probe".write(toFile: root + "/sftp-probe/file.txt", atomically: true, encoding: .utf8)

        try await connection.openSFTPSubsystemIfNeeded()
        let before = try await connection.sftpRealpath(".")
        XCTAssertFalse(before.isEmpty)

        let execResult = try await execute("printf 'exec-in-between\\n'", on: connection)
        XCTAssertEqual(execResult.result.stdout, "exec-in-between\n")

        let after = try await connection.sftpRealpath(".")
        XCTAssertEqual(before, after, "§74/§116：exec 前后 SFTP 子系统必须保持可用")
        let hasSFTP = await connection.hasSFTPSubsystem
        XCTAssertTrue(hasSFTP)
    }

    // MARK: - §146 泄漏审计

    func testRealChannelLeakAuditAfterMultipleExecutions() async throws {
        let connection = try await prepare()
        for index in 0..<3 {
            let result = try await execute("printf 'run-\(index)\\n'", on: connection)
            XCTAssertEqual(result.result.stdout, "run-\(index)\n")
        }
        let open = await connection.openExecChannelCount
        let opened = await connection.execChannelOpenCount
        let freed = await connection.execChannelFreeCount
        XCTAssertEqual(open, 0)
        XCTAssertEqual(opened, freed, "§146：openCount == freeCount")
    }

    // MARK: - §12/§14 session 绑定

    func testRealUnknownSessionIDIsSessionUnavailableWhileConnectionStaysUsable() async throws {
        let connection = try await prepare()
        let unknownSessionID = UUID()
        do {
            _ = try await execute(
                "printf 'should-not-run\\n'",
                on: connection,
                sessionID: unknownSessionID
            )
            XCTFail("§14：未知 sessionID 必须 sessionUnavailable")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .sessionUnavailable)
        }
        let open = await connection.openExecChannelCount
        XCTAssertEqual(open, 0, "session 解析失败 ⇒ 零 channel open")

        // 连接仍然可用（绝不因解析失败被断开 / 重连）。
        let result = try await execute("printf 'still-usable\\n'", on: connection)
        XCTAssertEqual(result.result.stdout, "still-usable\n")
    }

    func testRealTwoSessionsResolveToTheirOwnConnections() async throws {
        try await requireLocalSSHAndTestKey()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let directoryA = root + "/session-a"
        let directoryB = root + "/session-b"
        try FileManager.default.createDirectory(atPath: directoryA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: directoryB, withIntermediateDirectories: true)

        let connectionA = try await makeAuthenticatedTestKeyConnection()
        let connectionB = try await makeAuthenticatedTestKeyConnection()
        let sessionA = UUID()
        let sessionB = UUID()
        let resolver = AgentRemoteCommandSessionResolver { requested in
            if requested == sessionA { return connectionA }
            if requested == sessionB { return connectionB }
            return nil
        }

        let resultA = try await execute(
            "pwd -P", on: connectionA, workingDirectory: directoryA,
            sessionID: sessionA, resolver: resolver
        )
        let resultB = try await execute(
            "pwd -P", on: connectionB, workingDirectory: directoryB,
            sessionID: sessionB, resolver: resolver
        )

        XCTAssertEqual(
            resultA.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            URL(fileURLWithPath: directoryA).resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            resultB.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            URL(fileURLWithPath: directoryB).resolvingSymlinksInPath().path
        )
        XCTAssertNotEqual(resultA.result.stdout, resultB.result.stdout)
    }

    // MARK: - 真实连接（测试装置，绝不属生产路径）

    private func makeAuthenticatedTestKeyConnection() async throws -> SSHConnection {
        for _ in 1...3 {
            let info = SSHConnectionInfo(
                hostID: UUID(),
                hostname: testHostname,
                port: testPort,
                username: testUsername
            )
            let configuration = SSHConnection.Configuration(
                hostID: info.hostID,
                hostname: info.hostname,
                port: info.port,
                username: info.username,
                authenticationType: .privateKey,
                credentialID: nil,
                privateKeyPath: TestKeys.ed25519NoPass,
                privateKeyID: nil
            )
            let connection = SSHConnection(
                configuration: configuration,
                info: info,
                knownHostService: knownHostService,
                sessionTeardownOperations: .live
            )
            openConnections.append(connection)
            Task { await connection.connect() }

            let reachedTerminalPhase = try await waitForCondition(timeout: 20) {
                switch info.phase {
                case .awaitingHostTrust, .connected, .failed:
                    return true
                default:
                    return false
                }
            }
            if reachedTerminalPhase, case .failed = info.phase {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            XCTAssertTrue(reachedTerminalPhase, "连接必须到达 Trust 或 connected")
            if case .awaitingHostTrust = info.phase {
                await connection.resolveHostTrust(.trustOnce)
            }
            let connected = try await waitForCondition(timeout: 20) {
                info.phase == .connected
            }
            XCTAssertTrue(connected, "测试私钥连接必须完成认证")
            return connection
        }
        throw SSHError.connectionLost
    }

    private func requireLocalSSHAndTestKey() async throws {
        let reachable = await Self.isTCPPortOpen(host: testHostname, port: testPort)
        try XCTSkipUnless(reachable, "本机 127.0.0.1:22 未开放（Remote Login 未开启）")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-phase10-focus.sh 生成"
        )
    }

    // MARK: - PTY 辅助

    private func drainShellOutput(
        _ connection: SSHConnection,
        seconds: TimeInterval
    ) async throws -> String {
        var collected = ""
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (bytes, isEOF) = try await connection.readChannelOutput()
            if bytes.isEmpty {
                try await Task.sleep(nanoseconds: 50_000_000)
                if isEOF { break }
                continue
            }
            collected += String(decoding: bytes, as: UTF8.self)
        }
        return collected
    }

    private func runShellCommand(
        _ connection: SSHConnection,
        _ command: String,
        timeout: TimeInterval = 10
    ) async throws -> String {
        try await connection.writeChannelInput(ArraySlice(Array(command.utf8)))
        var collected = ""
        let deadline = Date().addingTimeInterval(timeout)
        var lastChange = Date()
        while Date() < deadline {
            let (bytes, isEOF) = try await connection.readChannelOutput()
            if !bytes.isEmpty {
                collected += String(decoding: bytes, as: UTF8.self)
                lastChange = Date()
            } else if Date().timeIntervalSince(lastChange) > 0.4 {
                break
            }
            if isEOF { break }
            if bytes.isEmpty {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return collected
    }

    private func waitForCondition(
        timeout: TimeInterval,
        predicate: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: predicate) {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private static func isTCPPortOpen(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if result == 0 {
                    continuation.resume(returning: true)
                    return
                }
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pollFD, 1, 100) > 0 {
                        var errorValue: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &errorValue, &length)
                        continuation.resume(returning: errorValue == 0)
                        return
                    }
                }
                continuation.resume(returning: false)
            }
        }
    }
}
