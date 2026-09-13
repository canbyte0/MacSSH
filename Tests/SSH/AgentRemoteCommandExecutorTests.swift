import Darwin
import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B3 §44–§52/§96/§100/§101/§113/§114/§138：Remote executor 主流程。
///
/// 全部用例都跑在真实 `SSHConnection` + fake libssh2 边界上：executor 的
/// authorization / session 解析 / drain / cap / 终止映射 / 释放逻辑全是生产实现。
@MainActor
final class AgentRemoteCommandExecutorTests: XCTestCase {
    private var fake: AgentRemoteExecFakeLibssh2!
    private var connection: SSHConnection!
    private var coordinator: AgentCommandApprovalCoordinator!
    private var sessionID: UUID!

    override func setUp() async throws {
        fake = AgentRemoteExecFakeLibssh2()
        connection = try await AgentRemoteExecTestSupport.makeFakeSessionConnection(fake: fake)
        coordinator = AgentCommandApprovalCoordinator()
        sessionID = UUID()
    }

    override func tearDown() async throws {
        await connection.disconnect()
        connection = nil
        fake = nil
        coordinator = nil
        sessionID = nil
    }

    // MARK: - helpers

    private func makeAuthorization(
        command: String,
        sessionID: UUID? = nil
    ) async throws -> AgentCommandExecutionAuthorization {
        try await AgentRemoteExecTestSupport.makeAuthorization(
            coordinator: coordinator,
            sessionID: sessionID ?? self.sessionID,
            command: command
        )
    }

    private func makeExecutor(
        resolver: AgentRemoteCommandSessionResolver,
        policy: AgentRemoteCommandExecutionPolicy = AgentRemoteExecTestSupport.fastPolicy
    ) -> AgentRemoteCommandExecutor {
        AgentRemoteCommandExecutor(policy: policy, resolver: resolver)
    }

    private func makeDefaultExecutor(
        policy: AgentRemoteCommandExecutionPolicy = AgentRemoteExecTestSupport.fastPolicy
    ) -> AgentRemoteCommandExecutor {
        makeExecutor(
            resolver: AgentRemoteExecTestSupport.makeResolver(mapping: [sessionID: connection]),
            policy: policy
        )
    }

    /// 一次成功命令的脚本：stdout / stderr 数据 + 双流 EOF + exit status。
    private func scriptSuccessfulCommand(
        stdout: [String] = [],
        stderr: [String] = [],
        exitStatus: Int32 = 0
    ) {
        fake.enqueueStdout(stdout)
        fake.enqueueStdoutRead(.eof)
        fake.enqueueStderr(stderr)
        fake.enqueueStderrRead(.eof)
        fake.setExitStatus(exitStatus)
    }

    // MARK: - §56 基础执行

    func testSuccessfulCommandReturnsExitStatusAndSeparateStreams() async throws {
        scriptSuccessfulCommand(stdout: ["hello-b3\n"], stderr: ["warn-b3\n"], exitStatus: 0)
        let authorization = try await makeAuthorization(command: "printf 'hello-b3\\n'")

        let result = try await makeDefaultExecutor().execute(
            authorization: authorization,
            approvalCoordinator: coordinator
        )

        XCTAssertEqual(result.result.stdout, "hello-b3\n")
        XCTAssertEqual(result.result.stderr, "warn-b3\n")
        XCTAssertEqual(result.result.exitCode, 0)
        XCTAssertEqual(result.termination, .exitStatus(0))
        XCTAssertNil(result.result.terminationSignal, "§52：Remote 绝不写本地 numeric signal")
        XCTAssertFalse(result.result.timedOut)
        XCTAssertFalse(result.result.cancelled)
        XCTAssertFalse(result.result.stdoutTruncated)
        XCTAssertFalse(result.result.stderrTruncated)
        XCTAssertFalse(result.result.binaryOutputDetected)
        XCTAssertFalse(result.result.nonUTF8Detected)
        XCTAssertFalse(result.remoteTerminationRequested)
        XCTAssertGreaterThan(result.result.duration, .zero)
        XCTAssertGreaterThanOrEqual(
            fake.sendEOFCallCount, 1,
            "§29：exec 成功后立即发送 stdin EOF（cleanup 路径还会 best-effort 再发一次）"
        )
        XCTAssertEqual(fake.openCallCount, 1)
        XCTAssertEqual(fake.execRequestCallCount, 1)
        XCTAssertEqual(fake.freeCallCount, 1)
        let open = await connection.openExecChannelCount
        XCTAssertEqual(open, 0)
    }

    func testEmptyOutputStillCompletes() async throws {
        scriptSuccessfulCommand()
        let authorization = try await makeAuthorization(command: "true")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(result.result.stdout, "")
        XCTAssertEqual(result.result.stderr, "")
        XCTAssertEqual(result.termination, .exitStatus(0))
    }

    func testApprovedCWDWrapperAndOriginalCommandReachTransportVerbatim() async throws {
        scriptSuccessfulCommand()
        let authorization = try await makeAuthorization(command: "printf A\nprintf B")
        _ = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        let payload = try XCTUnwrap(fake.execRequestCommands.first)
        XCTAssertEqual(
            payload,
            "cd '" + AgentRemoteExecTestSupport.remoteWorkingDirectory + "' || exit $?\nprintf A\nprintf B",
            "§35/§39：只有 App 生成的 cwd 前缀 + 原样 command"
        )
    }

    func testExecutorRemainsUsableForSecondCommand() async throws {
        scriptSuccessfulCommand(stdout: ["one\n"])
        let firstAuthorization = try await makeAuthorization(command: "echo one")
        let executor = makeDefaultExecutor()
        let first = try await executor.execute(
            authorization: firstAuthorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(first.result.stdout, "one\n")

        scriptSuccessfulCommand(stdout: ["two\n"])
        let secondAuthorization = try await makeAuthorization(command: "echo two")
        let second = try await executor.execute(
            authorization: secondAuthorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(second.result.stdout, "two\n")
        XCTAssertEqual(fake.openCallCount, 2)
        XCTAssertEqual(fake.freeCallCount, 2, "§146：openCount == freeCount")
    }

    // MARK: - §50/§101 exit status（valid result，不是 infrastructure error）

    func testNonZeroExitIsValidResultNotInfrastructureError() async throws {
        scriptSuccessfulCommand(stdout: ["boom\n"], exitStatus: 7)
        let authorization = try await makeAuthorization(command: "exit 7")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(result.result.exitCode, 7)
        XCTAssertEqual(result.termination, .exitStatus(7))
        XCTAssertFalse(result.result.timedOut)
    }

    func testCommandNotFoundStyleExitCodeIsValidResult() async throws {
        scriptSuccessfulCommand(stderr: ["not found\n"], exitStatus: 127)
        let authorization = try await makeAuthorization(command: "nonexistent_b3")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(result.result.exitCode, 127)
        XCTAssertEqual(result.termination, .exitStatus(127))
    }

    // MARK: - §51/§52/§102 exit signal（provider-neutral）

    func testExitSignalIsReportedAsTextWithoutFabricatingNumericSignal() async throws {
        fake.enqueueStdout(Array<String>())
        fake.enqueueStdoutRead(.eof)
        fake.enqueueStderr(Array<String>())
        fake.enqueueStderrRead(.eof)
        fake.clearExitStatus()
        fake.setExitSignal(name: "TERM", errorMessage: "terminated")

        let authorization = try await makeAuthorization(command: "sleep 30")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(result.termination, .exitSignal(name: "TERM", errorMessage: "terminated"))
        XCTAssertNil(result.result.exitCode, "§51：绝不伪造 exit code")
        XCTAssertNil(result.result.terminationSignal, "§52：绝不伪造本地数字信号")
        XCTAssertFalse(result.result.timedOut)
    }

    func testUnknownTerminationWhenServerProvidesNeither() async throws {
        fake.enqueueStdout(Array<String>())
        fake.enqueueStdoutRead(.eof)
        fake.enqueueStderr(Array<String>())
        fake.enqueueStderrRead(.eof)
        fake.clearExitStatus()
        let authorization = try await makeAuthorization(command: "true")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(result.termination, .unknown)
        XCTAssertNil(result.result.exitCode)
    }

    // MARK: - §46/§47/§100 双流 cap + 公平 drain

    func testStdoutAndStderrCapsTruncateButKeepDraining() async throws {
        let bigChunk = String(repeating: "a", count: 64 * 1024)
        fake.enqueueStdout(Array(repeating: bigChunk, count: 7)) // 448 KiB > 256 KiB cap
        fake.enqueueStdoutRead(.eof)
        let bigErrorChunk = String(repeating: "b", count: 64 * 1024)
        fake.enqueueStderr(Array(repeating: bigErrorChunk, count: 7))
        fake.enqueueStderrRead(.eof)
        fake.setExitStatus(0)

        let authorization = try await makeAuthorization(command: "big-output")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )

        XCTAssertTrue(result.result.stdoutTruncated)
        XCTAssertTrue(result.result.stderrTruncated)
        XCTAssertEqual(
            result.result.stdout.utf8.count,
            AgentCommandExecutionLimits.stdoutMaxBytes,
            "§46：stdout 存储 cap = 256 KiB（超出部分继续 drain、停止保存）"
        )
        XCTAssertEqual(
            result.result.stderr.utf8.count,
            AgentCommandExecutionLimits.stderrMaxBytes,
            "§46：stderr 独立计数、互不挤占"
        )
        XCTAssertGreaterThanOrEqual(
            fake.stdoutReadCallCount, 8,
            "cap 之后仍然继续 drain（7 数据块 + EOF）"
        )
        XCTAssertGreaterThanOrEqual(fake.stderrReadCallCount, 8)
        XCTAssertFalse(result.result.timedOut, "§45/§100：双流交错大输出绝不 deadlock")
    }

    func testBinaryAndNonUTF8OutputAreFlaggedNotFatal() async throws {
        fake.enqueueStdoutBytes([
            Array("A".utf8) + [0x00] + Array("B".utf8),
        ])
        fake.enqueueStdoutRead(.eof)
        fake.enqueueStderrBytes([[0xFF, 0xFE, 0x41]])
        fake.enqueueStderrRead(.eof)
        fake.setExitStatus(0)

        let authorization = try await makeAuthorization(command: "binary")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertTrue(result.result.binaryOutputDetected, "§39：NUL 命中即 binaryDetected")
        XCTAssertTrue(result.result.nonUTF8Detected)
        XCTAssertTrue(result.result.stdout.hasPrefix("A"))
        XCTAssertFalse(result.result.stdout.contains("B"), "NUL 之后内容被截断")
    }

    func testANSISequencesAreStrippedFromRemoteOutput() async throws {
        fake.enqueueStdout(["\u{1B}[31mred\u{1B}[0m\n", "\u{1B}]0;title\u{7}done\n"])
        fake.enqueueStdoutRead(.eof)
        fake.enqueueStderr(Array<String>())
        fake.enqueueStderrRead(.eof)
        fake.setExitStatus(0)
        let authorization = try await makeAuthorization(command: "ansi")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(result.result.stdout, "red\ndone\n")
        XCTAssertFalse(result.result.stdout.contains("\u{1B}"))
    }

    func testExecLifecycleDoesNotTouchPTYOrSFTPHandles() async throws {
        let shellIdentity: UInt = 0xAAA0_1001
        let sftpIdentity: UInt = 0xBBB0_1002
        await connection.setTestShellChannelIdentity(shellIdentity)
        await connection.setTestSFTPSubsystemIdentity(sftpIdentity)
        let target = connection!
        addTeardownBlock {
            await target.setTestShellChannelIdentity(nil)
            await target.setTestSFTPSubsystemIdentity(nil)
        }

        scriptSuccessfulCommand(stdout: ["ok\n"])
        let authorization = try await makeAuthorization(command: "echo ok")
        _ = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )

        let shellIntact = await connection.isShellChannelIdentity(shellIdentity)
        XCTAssertTrue(shellIntact, "exec 生命周期绝不触碰 PTY channel")
        let sftpIntact = await connection.isSFTPSubsystemIdentity(sftpIdentity)
        XCTAssertTrue(sftpIntact, "exec 生命周期绝不触碰 SFTP 子系统")
    }

    // MARK: - §14/§108 session 不可用

    func testSessionUnavailableProducesStructuredErrorAndZeroChannelOpen() async throws {
        let missingSessionID = UUID()
        let authorization = try await makeAuthorization(command: "echo hi", sessionID: missingSessionID)
        do {
            _ = try await makeDefaultExecutor().execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("session 不存在必须抛 sessionUnavailable（绝不 fallback 其它 session）")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .sessionUnavailable)
        }
        XCTAssertEqual(fake.openCallCount, 0, "§112：零 channel side effect")
        XCTAssertEqual(fake.execRequestCallCount, 0)
        XCTAssertEqual(fake.freeCallCount, 0)
    }

    func testAuthorizationIsConsumedEvenWhenSessionIsGone() async throws {
        let missingSessionID = UUID()
        let authorization = try await makeAuthorization(command: "echo hi", sessionID: missingSessionID)
        let executor = makeDefaultExecutor()
        _ = try? await executor.execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        // redeem 已消费：第二次执行必须在 SSH side effect 之前被 ledger 拒绝。
        do {
            _ = try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("同一 authorization 绝不允许第二次执行")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .authorizationRejected(.approvalAlreadyClaimed))
        }
        XCTAssertEqual(fake.openCallCount, 0)
    }

    func testSessionClosedBetweenResolveAndOpenFailsSafely() async throws {
        // §108：redeem → session 关闭 → executor 尝试 open：
        // 必须 fail safely（结构化错误 + 零 channel 残留 + 不重连）。
        let resolver = AgentRemoteCommandSessionResolver { [connection] _ in
            await connection?.setTestSessionPointer(nil)
            return connection
        }
        let authorization = try await makeAuthorization(command: "echo hi")
        do {
            _ = try await makeExecutor(resolver: resolver).execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("session 关闭后必须抛 connectionUnavailable")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .connectionUnavailable)
        }
        XCTAssertEqual(fake.openCallCount, 0, "session 已释放 ⇒ 零 open")
        let open = await connection.openExecChannelCount
        XCTAssertEqual(open, 0)
    }

    // MARK: - §16/§113/§114 A/B session 隔离

    func testABSessionIsolationUsesOnlyOriginConnection() async throws {
        let fakeA = fake!
        let fakeB = AgentRemoteExecFakeLibssh2()
        let connectionB = try await AgentRemoteExecTestSupport.makeFakeSessionConnection(fake: fakeB)
        defer { Task { await connectionB.disconnect() } }

        let sessionA = UUID()
        let sessionB = UUID()
        let recordings = AgentRemoteExecRecordingBox()
        let resolver = AgentRemoteCommandSessionResolver { [connection] sessionID in
            await recordings.append(sessionID)
            if sessionID == sessionA { return connection }
            if sessionID == sessionB { return connectionB }
            return nil
        }

        fakeA.enqueueStdout(["from-a\n"])
        fakeA.enqueueStdoutRead(.eof)
        fakeA.enqueueStderr(Array<String>())
        fakeA.enqueueStderrRead(.eof)
        fakeA.setExitStatus(0)

        let authorization = try await AgentRemoteExecTestSupport.makeAuthorization(
            coordinator: coordinator, sessionID: sessionA, command: "echo from-a"
        )
        let result = try await makeExecutor(resolver: resolver).execute(
            authorization: authorization, approvalCoordinator: coordinator
        )

        XCTAssertEqual(result.result.stdout, "from-a\n")
        XCTAssertEqual(fakeA.openCallCount, 1, "§114：Connection A openCount = 1")
        XCTAssertEqual(fakeB.openCallCount, 0, "§114：Connection B openCount = 0")
        XCTAssertEqual(fakeB.freeCallCount, 0)
        // A 的 payload 只可能来自 approved request（session A 的 cwd / command）。
        XCTAssertEqual(
            fakeA.execRequestCommands,
            ["cd '" + AgentRemoteExecTestSupport.remoteWorkingDirectory + "' || exit $?\necho from-a"]
        )
        let requested = await recordings.values
        XCTAssertEqual(requested, [sessionA], "§12/§114：只解析 origin sessionID，绝不查询其它会话")
    }

    func testResolverIsQueriedOnlyWithTheApprovedSessionID() async throws {
        let recorded = AgentRemoteExecRecordingBox()
        let resolver = AgentRemoteCommandSessionResolver { [connection] sessionID in
            await recorded.append(sessionID)
            return connection
        }
        scriptSuccessfulCommand(stdout: ["x\n"])
        let authorization = try await makeAuthorization(command: "echo x")
        _ = try await makeExecutor(resolver: resolver).execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        let requested = await recorded.values
        XCTAssertEqual(requested, [sessionID], "§12：只按 approved immutable sessionID 解析")
    }

    // MARK: - §53/§107 连接丢失（infrastructure error）

    func testConnectionLossMidCommandSurfacesInfrastructureErrorAndFreesChannel() async throws {
        fake.enqueueStdout(["partial\n"])
        fake.enqueueStdoutRead(.socketFailure)

        let authorization = try await makeAuthorization(command: "long-running")
        do {
            _ = try await makeDefaultExecutor().execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("§53：连接丢失必须是结构化 infrastructure error")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .connectionUnavailable)
        }
        XCTAssertEqual(fake.freeCallCount, 1, "§107/§146：channel 句柄 cleanup exactly once")
        let open = await connection.openExecChannelCount
        XCTAssertEqual(open, 0)
    }

    func testExecRequestRejectedSurfacesStructuredErrorWithoutChannelLeak() async throws {
        fake.enqueueExecRequest(.rejected)
        let authorization = try await makeAuthorization(command: "echo hi")
        do {
            _ = try await makeDefaultExecutor().execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("exec 请求被拒绝必须抛 execRequestRejected")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .execRequestRejected)
        }
        XCTAssertEqual(fake.freeCallCount, 1)
        let open = await connection.openExecChannelCount
        XCTAssertEqual(open, 0)
    }

    // MARK: - §84 日志卫生

    func testResultDescriptionIsRedacted() async throws {
        scriptSuccessfulCommand(stdout: ["SECRET-B3-OUT"], stderr: ["SECRET-B3-ERR"], exitStatus: 3)
        let authorization = try await makeAuthorization(command: "echo secret")
        let result = try await makeDefaultExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        let rendered = String(describing: result) + String(reflecting: result)
        XCTAssertFalse(rendered.contains("SECRET-B3-OUT"))
        XCTAssertFalse(rendered.contains("SECRET-B3-ERR"))
        XCTAssertTrue(rendered.contains("<redacted>"))
        XCTAssertTrue(rendered.contains("exitStatus"))
    }
}

/// 记录 resolver 收到的 sessionID（actor：跨并发安全）。
private actor AgentRemoteExecRecordingBox {
    private(set) var values: [UUID] = []

    func append(_ value: UUID) {
        values.append(value)
    }
}
