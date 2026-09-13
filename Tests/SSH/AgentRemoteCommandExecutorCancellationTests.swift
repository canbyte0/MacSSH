import Darwin
import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B3 §54–§60/§71/§79/§80/§104–§106/§109/§110/§148：timeout / 取消 /
/// best-effort 远端终止 / 有界收口 / channel cleanup。
@MainActor
final class AgentRemoteCommandExecutorCancellationTests: XCTestCase {
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

    private func makeExecutor(
        policy: AgentRemoteCommandExecutionPolicy = AgentRemoteExecTestSupport.fastPolicy
    ) -> AgentRemoteCommandExecutor {
        AgentRemoteCommandExecutor(
            policy: policy,
            resolver: AgentRemoteExecTestSupport.makeResolver(mapping: [sessionID: connection])
        )
    }

    private func makeAuthorization(
        command: String
    ) async throws -> AgentCommandExecutionAuthorization {
        try await AgentRemoteExecTestSupport.makeAuthorization(
            coordinator: coordinator,
            sessionID: sessionID,
            command: command
        )
    }

    private func registeredChannelCount() async -> Int {
        await connection.openExecChannelCount
    }

    // MARK: - §104 timeout

    func testTimeoutRequestsTermAndReturnsTimedOutResult() async throws {
        // TERM 生效（远端进程结束）→ channel EOF → 有界收口。
        fake.setKillsOnSignal(true)
        let authorization = try await makeAuthorization(command: "sleep 30")
        let result = try await makeExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )

        XCTAssertTrue(result.result.timedOut, "§79：timeout 是结果状态（不是错误）")
        XCTAssertFalse(result.result.cancelled)
        XCTAssertTrue(result.remoteTerminationRequested, "§79：best-effort 终止请求已尝试")
        XCTAssertEqual(fake.requestedSignals.first, "TERM", "§57/§59：先请求 TERM")
        XCTAssertEqual(fake.freeCallCount, 1)
        let probed16 = await registeredChannelCount()
        XCTAssertEqual(probed16, 0)
    }

    func testTimeoutIgnoringTermEscalatesToKillAndClosesChannelWithinBounds() async throws {
        // TERM / KILL 都不生效（最坏情形）：必须在有界时间内收口，绝不无限等待。
        fake.setKillsOnSignal(false)
        let authorization = try await makeAuthorization(command: "sleep 30")
        let started = Date()
        let result = try await makeExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.result.timedOut)
        XCTAssertEqual(fake.requestedSignals, ["TERM", "KILL"], "§59：grace 之后升级为 best-effort KILL")
        XCTAssertLessThan(elapsed, 5, "§59/§66：绝不无限等待远端终止")
        XCTAssertEqual(fake.freeCallCount, 1)
        let probed17 = await registeredChannelCount()
        XCTAssertEqual(probed17, 0)
        let liveSession = await connection.hasLiveSession
        XCTAssertTrue(liveSession, "§62：command timeout 绝不断开整个 SSH 连接")
    }

    func testTimeoutReportsUnknownTerminationWithoutFabricatingExitCode() async throws {
        fake.setKillsOnSignal(false)
        fake.clearExitStatus()
        let authorization = try await makeAuthorization(command: "sleep 30")
        let result = try await makeExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertTrue(result.result.timedOut)
        XCTAssertEqual(result.termination, .unknown)
        XCTAssertNil(result.result.exitCode)
    }

    // MARK: - §105 cancellation

    func testTaskCancellationReturnsCancelledResultAndCleansUpChannel() async throws {
        fake.setKillsOnSignal(true)
        let authorization = try await makeAuthorization(command: "sleep 30")
        let executor = makeExecutor()
        let task = Task {
            try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        let cancelledAt = Date()
        task.cancel()

        let result = try await task.value
        let cancelLatency = Date().timeIntervalSince(cancelledAt)
        XCTAssertTrue(result.result.cancelled, "§80：取消必须反映在 result 上")
        XCTAssertFalse(result.result.timedOut)
        XCTAssertTrue(result.remoteTerminationRequested)
        XCTAssertLessThan(cancelLatency, 1.5, "§71：取消响应必须有界（不等待远端数据）")
        XCTAssertEqual(fake.requestedSignals.first, "TERM")
        XCTAssertEqual(fake.freeCallCount, 1, "§105：channel close/free exactly once")
        let probed18 = await registeredChannelCount()
        XCTAssertEqual(probed18, 0)
    }

    func testCancelBeforeExecutionThrowsCancellationAndConsumesNothing() async throws {
        let authorization = try await makeAuthorization(command: "sleep 30")
        let executor = makeExecutor()
        let task = Task { () -> AgentRemoteCommandResult in
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
        }
        task.cancel()

        let outcome = await task.result
        switch outcome {
        case .success:
            XCTFail("§109：channel 打开之前的取消不得返回结果")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "实际错误：\(error)")
        }
        XCTAssertEqual(fake.openCallCount, 0, "§109：取消 ⇒ 零 channel open")
        XCTAssertEqual(fake.freeCallCount, 0)
        // §68 语义延续：redeem 之前中止不消费 authorization。
        let snapshot = await coordinator.snapshot(approvalID: authorization.approvalID)
        XCTAssertEqual(snapshot?.state, .executionClaimed)
    }

    func testCancelBetweenRedeemAndChannelOpenBlocksOpen() async throws {
        let authorization = try await makeAuthorization(command: "sleep 30")
        // resolver 在 redeem 之后被调用：此处挂起，取消落地后放行。
        let resolver = AgentRemoteCommandSessionResolver { [connection] _ in
            try? await Task.sleep(nanoseconds: 60_000_000)
            return connection
        }
        let executor = AgentRemoteCommandExecutor(
            policy: AgentRemoteExecTestSupport.fastPolicy, resolver: resolver
        )
        let task = Task {
            try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        task.cancel()

        let outcome = await task.result
        switch outcome {
        case .success:
            XCTFail("§109：redeem ↔ open 之间的取消必须阻止 channel open")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "实际错误：\(error)")
        }
        XCTAssertEqual(fake.openCallCount, 0, "§109：final cancellation gate 必须生效")
        // 授权在 redeem 时已被消费：重放必须在 SSH side effect 之前被拒绝。
        do {
            _ = try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("已消费的 authorization 不得第二次执行")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .authorizationRejected(.approvalAlreadyClaimed))
        }
        XCTAssertEqual(fake.openCallCount, 0)
    }

    // MARK: - §60/§106 signal 不被支持

    func testSignalUnsupportedStillCleansChannelAndKeepsConnectionUsable() async throws {
        fake.setKillsOnSignal(false)
        fake.enqueueSignal(.rejected)
        fake.enqueueSignal(.rejected)
        let authorization = try await makeAuthorization(command: "sleep 30")
        let result = try await makeExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )

        XCTAssertTrue(result.result.timedOut)
        XCTAssertTrue(result.remoteTerminationRequested, "请求已发出（best-effort，不保证远端终止）")
        XCTAssertEqual(fake.requestedSignals, ["TERM", "KILL"])
        XCTAssertEqual(fake.freeCallCount, 1, "§106：signal 不被支持仍然完成 channel cleanup")
        let probed19 = await registeredChannelCount()
        XCTAssertEqual(probed19, 0)
        let probed20 = await connection.hasLiveSession
        XCTAssertTrue(probed20, "§60：绝不因 signal 失败断开 SSH 连接")
    }

    // MARK: - §148 取消竞态压力

    func testCancellationStressLeavesNoChannelLeakOrDoubleFree() async throws {
        fake.setKillsOnSignal(true)
        let delays: [UInt64] = [0, 2_000_000, 5_000_000, 10_000_000, 20_000_000, 40_000_000]
        let executor = makeExecutor()

        for (index, delay) in delays.enumerated() {
            fake.resetChannelAndScripts()
            let authorization = try await makeAuthorization(command: "sleep 30")
            let task = Task {
                try await executor.execute(
                    authorization: authorization, approvalCoordinator: coordinator
                )
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            task.cancel()

            let outcome = await task.result
            switch outcome {
            case .success(let result):
                XCTAssertTrue(result.result.cancelled, "第 \(index) 轮：取消后的成功返回必须 cancelled")
                XCTAssertFalse(result.result.timedOut)
            case .failure(let error):
                XCTAssertTrue(
                    error is CancellationError,
                    "第 \(index) 轮：open 之前取消必须抛 CancellationError，实际：\(error)"
                )
            }
            XCTAssertEqual(
                fake.freeCallCount, fake.openCallCount,
                "第 \(index) 轮：§146 open == free（无泄漏 / 无 double-free）"
            )
            let probed21 = await registeredChannelCount()
            XCTAssertEqual(probed21, 0, "第 \(index) 轮：零 channel 残留")
        }
    }

    func testExecutorRemainsUsableAfterTimeoutAndCancellation() async throws {
        fake.setKillsOnSignal(true)
        let firstAuthorization = try await makeAuthorization(command: "sleep 30")
        let executor = makeExecutor()
        let timedOut = try await executor.execute(
            authorization: firstAuthorization, approvalCoordinator: coordinator
        )
        XCTAssertTrue(timedOut.result.timedOut)

        fake.enqueueStdout(["still-alive\n"])
        fake.enqueueStdoutRead(.eof)
        fake.enqueueStderr(Array<String>())
        fake.enqueueStderrRead(.eof)
        fake.setExitStatus(0)
        let secondAuthorization = try await makeAuthorization(command: "echo still-alive")
        let second = try await executor.execute(
            authorization: secondAuthorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(second.result.stdout, "still-alive\n")
        XCTAssertEqual(second.result.exitCode, 0)
        XCTAssertFalse(second.result.timedOut)
        XCTAssertEqual(fake.freeCallCount, fake.openCallCount)
    }
}
