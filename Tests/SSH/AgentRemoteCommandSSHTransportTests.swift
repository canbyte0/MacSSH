import Darwin
import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B3 §19–§70/§98–§107/§137/§146/§147：SSH 层 exec channel 生命周期。
///
/// 全部用例都跑在**真实 `SSHConnection` actor** 上（生产实现的 guard / EAGAIN
/// 循环 / exactly-once 释放逻辑都在场），只有 libssh2 调用边界被 fake 替身
/// 占用：无需真实 SSH 服务器即可确定性覆盖 open → exec → EOF → 双流读取 →
/// signal → exit status / exit signal → close → free 全链。
@MainActor
final class AgentRemoteCommandSSHTransportTests: XCTestCase {
    private var fake: AgentRemoteExecFakeLibssh2!
    private var connection: SSHConnection!

    override func setUp() async throws {
        fake = AgentRemoteExecFakeLibssh2()
        connection = try await AgentRemoteExecTestSupport.makeFakeSessionConnection(fake: fake)
    }

    override func tearDown() async throws {
        await connection.disconnect()
        connection = nil
        fake = nil
    }

    private func openChannel(_ command: String = "printf 'hi\\n'") async throws -> UUID {
        try await connection.openExecChannel(command: command, isCancelled: { false })
    }

    private func registeredChannelCount() async -> Int {
        await connection.openExecChannelCount
    }

    /// fake 句柄必须在 `disconnect()`（tearDown）之前清除：teardown 会把
    /// 非 nil 的 shell / SFTP 句柄交给真实 libssh2 释放。
    private func registerFakeHandleCleanup() {
        let target = connection!
        addTeardownBlock {
            await target.setTestShellChannelIdentity(nil)
            await target.setTestSFTPSubsystemIdentity(nil)
        }
    }

    // MARK: - §20/§21/§22/§137 open + exec

    func testOpenSendsExecRequestAndRegistersChannel() async throws {
        let token = try await openChannel("echo hi")
        XCTAssertEqual(fake.openCallCount, 1)
        XCTAssertEqual(fake.execRequestCallCount, 1)
        XCTAssertEqual(fake.execRequestCommands, ["echo hi"])
        let probed1 = await registeredChannelCount()
        XCTAssertEqual(probed1, 1)
        let openCount = await connection.execChannelOpenCount
        XCTAssertEqual(openCount, 1)

        await connection.closeExecChannel(token)
        let probed2 = await registeredChannelCount()
        XCTAssertEqual(probed2, 0)
        let freeCount = await connection.execChannelFreeCount
        XCTAssertEqual(freeCount, 1)
    }

    func testOpenEAGAINResumesWithoutBusyLoop() async throws {
        fake.enqueueOpen(.eagain)
        fake.enqueueOpen(.eagain)
        fake.enqueueOpen(.ok)

        let token = try await openChannel()
        XCTAssertEqual(fake.openCallCount, 3, "EAGAIN 必须重试，且只在 readiness 之后")
        XCTAssertEqual(fake.execRequestCallCount, 1)
        let probed3 = await registeredChannelCount()
        XCTAssertEqual(probed3, 1)
        await connection.closeExecChannel(token)
    }

    func testExecRequestEAGAINResumes() async throws {
        fake.enqueueExecRequest(.eagain)
        fake.enqueueExecRequest(.ok)
        let token = try await openChannel("echo hi")
        XCTAssertEqual(fake.execRequestCallCount, 2)
        await connection.closeExecChannel(token)
    }

    func testOpenRejectedFailsWithoutLeakingChannel() async throws {
        fake.enqueueOpen(.rejected)
        do {
            _ = try await openChannel()
            XCTFail("服务器拒绝 open 必须抛结构化错误")
        } catch let error as SSHExecChannelError {
            XCTAssertEqual(error, .channelOpenFailed)
        }
        let probed4 = await registeredChannelCount()
        XCTAssertEqual(probed4, 0, "半开 channel 绝不残留")
        XCTAssertEqual(fake.freeCallCount, 0, "channel 从未创建 ⇒ 绝不 free")
    }

    func testExecRequestRejectedReleasesHalfOpenChannel() async throws {
        fake.enqueueExecRequest(.rejected)
        do {
            _ = try await openChannel()
            XCTFail("exec 请求被拒绝必须抛结构化错误")
        } catch let error as SSHExecChannelError {
            XCTAssertEqual(error, .execRequestRejected)
        }
        let probed5 = await registeredChannelCount()
        XCTAssertEqual(probed5, 0)
        XCTAssertEqual(fake.freeCallCount, 1, "半开 channel 必须释放（一次）")
    }

    func testOpenWithoutSessionThrowsConnectionLost() async throws {
        let orphanFake = AgentRemoteExecFakeLibssh2()
        let orphan = try await AgentRemoteExecTestSupport.makeFakeSessionConnection(fake: orphanFake)
        await orphan.setTestSessionPointer(nil)
        do {
            _ = try await orphan.openExecChannel(command: "echo hi", isCancelled: { false })
            XCTFail("session 不可用必须抛 connectionLost（绝不重连）")
        } catch let error as SSHExecChannelError {
            XCTAssertEqual(error, .connectionLost)
        }
        XCTAssertEqual(orphanFake.openCallCount, 0, "无 session ⇒ 零 channel open")
    }

    // MARK: - §29/§67 stdin EOF

    func testSendEOFIsSentOnOpenedChannel() async throws {
        let token = try await openChannel()
        try await connection.sendExecChannelEOF(token, isCancelled: { false })
        XCTAssertEqual(fake.sendEOFCallCount, 1)
        await connection.closeExecChannel(token)
    }

    func testSendEOFEAGAINResumes() async throws {
        let token = try await openChannel()
        fake.enqueueSendEOF(.eagain)
        fake.enqueueSendEOF(.ok)
        try await connection.sendExecChannelEOF(token, isCancelled: { false })
        XCTAssertEqual(fake.sendEOFCallCount, 2)
        await connection.closeExecChannel(token)
    }

    func testSendEOFAbortsOnCancellationPredicate() async throws {
        let token = try await openChannel()
        fake.enqueueSendEOF(.eagain)
        do {
            try await connection.sendExecChannelEOF(token, isCancelled: { true })
            XCTFail("取消谓词置位后必须立即以 CancellationError 退出")
        } catch is CancellationError {
            // 预期的有界取消响应。
        }
        XCTAssertEqual(fake.sendEOFCallCount, 0, "取消谓词在首个切片内生效 ⇒ 零调用")
        await connection.closeExecChannel(token)
    }

    // MARK: - §44/§45/§68 stdout / stderr 分离

    func testStdoutAndStderrAreReadAsSeparateStreams() async throws {
        let token = try await openChannel()
        fake.enqueueStdout(["to-stdout\n"])
        fake.enqueueStderr(["to-stderr\n"])

        let stdout = try await connection.readExecChannelOutput(token, stream: .stdout)
        let stderr = try await connection.readExecChannelOutput(token, stream: .stderr)
        XCTAssertEqual(String(decoding: stdout.bytes, as: UTF8.self), "to-stdout\n")
        XCTAssertFalse(stdout.isEOF)
        XCTAssertEqual(String(decoding: stderr.bytes, as: UTF8.self), "to-stderr\n")
        XCTAssertFalse(stderr.isEOF)
        XCTAssertEqual(fake.stdoutReadCallCount, 1)
        XCTAssertEqual(fake.stderrReadCallCount, 1)
        await connection.closeExecChannel(token)
    }

    func testReadWithoutDataReportsNotEOFAndEOFWhenChannelEOFSet() async throws {
        let token = try await openChannel()

        let empty = try await connection.readExecChannelOutput(token, stream: .stdout)
        XCTAssertTrue(empty.bytes.isEmpty)
        XCTAssertFalse(empty.isEOF, "无数据 ≠ EOF（调用方继续等待）")

        fake.markChannelEOF()
        let afterEOF = try await connection.readExecChannelOutput(token, stream: .stdout)
        XCTAssertTrue(afterEOF.bytes.isEmpty)
        XCTAssertTrue(afterEOF.isEOF)
        await connection.closeExecChannel(token)
    }

    func testReadSocketFailureSurfacesConnectionLost() async throws {
        let token = try await openChannel()
        fake.enqueueStdoutRead(.socketFailure)
        do {
            _ = try await connection.readExecChannelOutput(token, stream: .stdout)
            XCTFail("传输级失败必须抛 connectionLost")
        } catch let error as SSHExecChannelError {
            XCTAssertEqual(error, .connectionLost)
        }
        await connection.closeExecChannel(token)
    }

    func testReadProtocolFailureSurfacesChannelReadFailed() async throws {
        let token = try await openChannel()
        fake.enqueueStdoutRead(.failure)
        do {
            _ = try await connection.readExecChannelOutput(token, stream: .stdout)
            XCTFail("协议级失败必须抛 channelReadFailed")
        } catch let error as SSHExecChannelError {
            XCTAssertEqual(error, .channelReadFailed)
        }
        await connection.closeExecChannel(token)
    }

    func testWaitForActivityReturnsFalseWhenBudgetExpired() async throws {
        let token = try await openChannel()
        let observed = try await connection.waitForExecChannelActivity(token, budget: 0)
        XCTAssertFalse(observed, "预算耗尽的 readiness 等待不是错误，只是未观测到活动")
        await connection.closeExecChannel(token)
    }

    // MARK: - §57/§58/§60 signal request

    func testSignalRequestUsesProtocolNames() async throws {
        let token = try await openChannel()
        try await connection.requestExecChannelSignal(token, signal: .terminate)
        try await connection.requestExecChannelSignal(token, signal: .kill)
        XCTAssertEqual(fake.requestedSignals, ["TERM", "KILL"], "绝不发送 SIGTERM / SIGKILL 形式")
        await connection.closeExecChannel(token)
    }

    func testSignalRequestEAGAINResumes() async throws {
        let token = try await openChannel()
        fake.enqueueSignal(.eagain)
        fake.enqueueSignal(.ok)
        try await connection.requestExecChannelSignal(token, signal: .terminate)
        XCTAssertEqual(fake.signalCallCount, 2)
        await connection.closeExecChannel(token)
    }

    func testSignalRejectionIsStructuredAndDoesNotKillConnection() async throws {
        let token = try await openChannel()
        fake.enqueueSignal(.rejected)
        do {
            try await connection.requestExecChannelSignal(token, signal: .terminate)
            XCTFail("服务器拒绝 signal request 必须抛结构化错误")
        } catch let error as SSHExecChannelError {
            XCTAssertEqual(error, .signalRequestRejected)
        }
        // §60：signal 被拒绝绝不导致连接断开——channel 与 session 都还在。
        let probed6 = await registeredChannelCount()
        XCTAssertEqual(probed6, 1)
        let hasSession = await connection.hasLiveSession
        XCTAssertTrue(hasSession)
        await connection.closeExecChannel(token)
    }

    // MARK: - §50/§51/§69 exit status / exit signal（free 之前）

    func testFinishReadsExitStatusBeforeFreeAndReturnsCommittableSnapshot() async throws {
        let token = try await openChannel()
        fake.setExitStatus(7)

        let termination = try await connection.finishExecChannel(token)
        XCTAssertEqual(termination.exitStatus, 7)
        XCTAssertNil(termination.exitSignalName)
        XCTAssertEqual(fake.hasExitStatusCallCount, 1)
        XCTAssertEqual(fake.exitStatusCallCount, 1)
        XCTAssertEqual(fake.freeCallCount, 0, "§69：free 之前读取 exit status")

        await connection.closeExecChannel(token)
        XCTAssertEqual(fake.freeCallCount, 1)
        XCTAssertEqual(termination.exitStatus, 7, "快照是值：free 之后仍有效")
    }

    func testFinishReturnsTextualExitSignalInsteadOfNumericSignal() async throws {
        let token = try await openChannel()
        fake.clearExitStatus()
        fake.setExitSignal(name: "TERM", errorMessage: "terminated by signal")

        let termination = try await connection.finishExecChannel(token)
        XCTAssertNil(termination.exitStatus)
        XCTAssertEqual(termination.exitSignalName, "TERM")
        XCTAssertEqual(termination.exitSignalErrorMessage, "terminated by signal")
        await connection.closeExecChannel(token)
    }

    func testFinishReturnsUnknownWhenServerProvidesNothing() async throws {
        let token = try await openChannel()
        fake.clearExitStatus()
        let termination = try await connection.finishExecChannel(token)
        XCTAssertEqual(termination, .unknown)
        await connection.closeExecChannel(token)
    }

    func testFinishEAGAINOnCloseResumes() async throws {
        let token = try await openChannel()
        fake.setExitStatus(0)
        fake.enqueueClose(.eagain)
        fake.enqueueWaitClosed(.eagain)
        let termination = try await connection.finishExecChannel(token)
        XCTAssertEqual(termination.exitStatus, 0)
        XCTAssertEqual(fake.closeCallCount, 2)
        XCTAssertEqual(fake.waitClosedCallCount, 2)
        await connection.closeExecChannel(token)
    }

    // MARK: - §65/§66/§146/§147 exactly-once 释放

    func testCloseIsIdempotentAndFreesExactlyOnce() async throws {
        let token = try await openChannel()
        await connection.closeExecChannel(token)
        await connection.closeExecChannel(token)
        await connection.closeExecChannel(token)
        XCTAssertEqual(fake.freeCallCount, 1, "§147：free ≤ 1（无 double-free）")
        let probed7 = await registeredChannelCount()
        XCTAssertEqual(probed7, 0)
    }

    func testConcurrentCloseWaitsForTheSameSingleRelease() async throws {
        let token = try await openChannel()
        let target = connection!
        async let first: Void = target.closeExecChannel(token)
        async let second: Void = target.closeExecChannel(token)
        _ = await (first, second)
        XCTAssertEqual(fake.freeCallCount, 1)
        let probed8 = await registeredChannelCount()
        XCTAssertEqual(probed8, 0)
    }

    func testCloseOnUnknownTokenIsNoOp() async throws {
        await connection.closeExecChannel(UUID())
        XCTAssertEqual(fake.freeCallCount, 0)
    }

    func testFreeEAGAINIsRetriedWithinBudget() async throws {
        let token = try await openChannel()
        fake.enqueueFree(Int32(LIBSSH2_ERROR_EAGAIN))
        fake.enqueueFree(0)
        await connection.closeExecChannel(token)
        XCTAssertEqual(fake.freeCallCount, 2)
        let freeCount = await connection.execChannelFreeCount
        XCTAssertEqual(freeCount, 1)
        let probed9 = await registeredChannelCount()
        XCTAssertEqual(probed9, 0)
    }

    // MARK: - §62/§63/§64 teardown 集成

    func testTeardownClosesAllExecChannelsWithoutTouchingOthers() async throws {
        let first = try await openChannel("echo one")
        let second = try await openChannel("echo two")
        let probed10 = await registeredChannelCount()
        XCTAssertEqual(probed10, 2)

        await connection.disconnect()

        XCTAssertEqual(fake.freeCallCount, 2, "每个打开的 channel 恰好释放一次")
        let probed11 = await registeredChannelCount()
        XCTAssertEqual(probed11, 0)
        let hasSession = await connection.hasLiveSession
        XCTAssertFalse(hasSession)
        // teardown 之后 close 是幂等 no-op（绝不 double-free）。
        await connection.closeExecChannel(first)
        await connection.closeExecChannel(second)
        XCTAssertEqual(fake.freeCallCount, 2)
    }

    func testExecLifecycleNeverTouchesShellChannelOrSFTPSubsystemHandles() async throws {
        // 手工登记 fake 的「PTY channel」与「SFTP subsystem」句柄：
        // exec 生命周期结束后二者必须原样存在（绝不被 close / free / 替换）。
        let shellIdentity: UInt = 0xAAA0_0001
        let sftpIdentity: UInt = 0xBBB0_0002
        await connection.setTestShellChannelIdentity(shellIdentity)
        await connection.setTestSFTPSubsystemIdentity(sftpIdentity)
        registerFakeHandleCleanup()

        let token = try await openChannel()
        _ = try await connection.finishExecChannel(token)
        await connection.closeExecChannel(token)

        let shellIntact = await connection.isShellChannelIdentity(shellIdentity)
        XCTAssertTrue(shellIntact, "exec 绝不触碰 PTY channel")
        let sftpIntact = await connection.isSFTPSubsystemIdentity(sftpIdentity)
        XCTAssertTrue(sftpIntact, "exec 绝不触碰 SFTP 子系统")
        XCTAssertEqual(fake.freeCallCount, 1)
    }
}
