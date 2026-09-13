import Darwin
import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B2 §10/§40/§44–§49/§65–§70：timeout / Task 取消 /
/// 进程组终止 / reap（绝无 zombie）。
final class AgentLocalCommandExecutorCancellationTests: XCTestCase {
    private var workspace: AgentLocalCommandTestWorkspace!

    override func setUpWithError() throws {
        workspace = try AgentLocalCommandTestWorkspace()
    }

    override func tearDownWithError() throws {
        workspace.cleanup()
        workspace = nil
    }

    // MARK: - helpers

    @discardableResult
    private func execute(
        _ command: String,
        policy: AgentLocalCommandExecutionPolicy
    ) async throws -> AgentCommandResult {
        let coordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: coordinator,
            command: command,
            workingDirectory: workspace.root.path
        )
        let executor = AgentLocalCommandExecutor(policy: policy)
        return try await executor.execute(
            authorization: authorization,
            approvalCoordinator: coordinator
        )
    }

    private func makeCancelTestInputs(command: String) async throws -> (
        executor: AgentLocalCommandExecutor,
        coordinator: AgentCommandApprovalCoordinator,
        authorization: AgentCommandExecutionAuthorization
    ) {
        let coordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: coordinator,
            command: command,
            workingDirectory: workspace.root.path
        )
        return (
            AgentLocalCommandExecutor(policy: AgentLocalCommandTestSupport.fastPolicy),
            coordinator,
            authorization
        )
    }

    private func waitForFile(_ path: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private func readPID(fromFileAt path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parsePID(prefix: String, from text: String) -> pid_t? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        where token.hasPrefix(prefix) {
            return pid_t(token.dropFirst(prefix.count))
        }
        return nil
    }

    // MARK: - §14 进程组

    func testChildRunsInItsOwnProcessGroup() async throws {
        let result = try await execute(
            AgentLocalCommandTestSupport.processIdentifierProbe,
            policy: AgentLocalCommandTestSupport.fastPolicy
        )
        let identifiers = try XCTUnwrap(
            AgentLocalCommandTestSupport.parseProcessIdentifiers(from: result.stdout)
        )
        XCTAssertEqual(identifiers.pgid, identifiers.pid, "§14：child PGID == child PID")
        let reaped = await AgentLocalCommandTestProcessProbe.waitUntilGone(identifiers.pid)
        XCTAssertTrue(reaped, "§40：正常退出路径必须完成 reap（无 zombie）")
    }

    func testNormalCompletionReapsChildWithoutZombie() async throws {
        let result = try await execute(
            AgentLocalCommandTestSupport.processIdentifierProbe,
            policy: AgentLocalCommandTestSupport.fastPolicy
        )
        XCTAssertEqual(result.exitCode, 0)
        let identifiers = try XCTUnwrap(
            AgentLocalCommandTestSupport.parseProcessIdentifiers(from: result.stdout)
        )
        let reaped = await AgentLocalCommandTestProcessProbe.waitUntilGone(identifiers.pid)
        XCTAssertTrue(reaped, "reap 后 kill(pid, 0) 必须 ESRCH（zombie 仍会响应信号）")
    }

    // MARK: - §65/§44 timeout

    func testTimeoutTerminatesProcessGroupAndReaps() async throws {
        let policy = AgentLocalCommandExecutionPolicy(
            timeout: .milliseconds(150),
            terminationGracePeriod: .milliseconds(300)
        )
        let result = try await execute(
            AgentLocalCommandTestSupport.processIdentifierProbe + "\nsleep 30",
            policy: policy
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.cancelled)
        XCTAssertNil(result.exitCode)
        XCTAssertEqual(result.terminationSignal, SIGTERM)
        let identifiers = try XCTUnwrap(
            AgentLocalCommandTestSupport.parseProcessIdentifiers(from: result.stdout)
        )
        let reaped = await AgentLocalCommandTestProcessProbe.waitUntilGone(identifiers.pid)
        XCTAssertTrue(reaped)
    }

    func testTimeoutKillsOrdinaryDescendantInSameProcessGroup() async throws {
        let policy = AgentLocalCommandExecutionPolicy(
            timeout: .milliseconds(150),
            terminationGracePeriod: .milliseconds(300)
        )
        let command = """
        sleep 30 &
        printf 'BG=%s\\n' "$!"
        wait
        """
        let result = try await execute(command, policy: policy)
        XCTAssertTrue(result.timedOut)
        let backgroundPID = try XCTUnwrap(parsePID(prefix: "BG=", from: result.stdout))
        let descendantGone = await AgentLocalCommandTestProcessProbe.waitUntilGone(backgroundPID)
        XCTAssertTrue(descendantGone, "§48：同组普通 descendant 必须随 killpg 终止")
    }

    // MARK: - §66 SIGTERM 抵抗

    func testSIGTERMResistantCommandIsKilledAfterGrace() async throws {
        let policy = AgentLocalCommandExecutionPolicy(
            timeout: .milliseconds(150),
            terminationGracePeriod: .milliseconds(200)
        )
        let result = try await execute("trap '' TERM\nsleep 30", policy: policy)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(
            result.terminationSignal, SIGKILL,
            "§44/§45：宽限期后必须 SIGKILL 进程组"
        )
    }

    // MARK: - §67 Task 取消

    func testTaskCancellationTerminatesCommandAndReaps() async throws {
        let markerPath = workspace.path("cancel-child.pid")
        let command = "printf 'partial-before-cancel\\n'\necho $$ > '\(markerPath)'\nsleep 30"
        let inputs = try await makeCancelTestInputs(command: command)
        let executor = inputs.executor
        let coordinator = inputs.coordinator
        let authorization = inputs.authorization
        let task = Task {
            try await executor.execute(
                authorization: authorization,
                approvalCoordinator: coordinator
            )
        }
        let markerAppeared = await waitForFile(markerPath)
        XCTAssertTrue(markerAppeared, "取消前子进程应已完成 spawn")

        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled, "§46/§67：取消必须反映在 result 上")
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stdout.contains("partial-before-cancel"))

        let childPID = try XCTUnwrap(readPID(fromFileAt: markerPath))
        let childGone = await AgentLocalCommandTestProcessProbe.waitUntilGone(childPID)
        XCTAssertTrue(childGone, "§67：取消后 child 必须被终止并 reap（无进程泄漏）")
    }

    func testCancelBeforeExecutionDoesNotSpawnOrConsumeAuthorization() async throws {
        let markerPath = workspace.path("should-not-exist")
        let command = "touch '\(markerPath)'"
        let inputs = try await makeCancelTestInputs(command: command)

        let task = Task { () -> AgentCommandResult in
            // 先确保取消已落定，再调用 executor（§68：预先取消）。
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await inputs.executor.execute(
                authorization: inputs.authorization,
                approvalCoordinator: inputs.coordinator
            )
        }
        task.cancel()

        let outcome = await task.result
        switch outcome {
        case .success:
            XCTFail("§68：预先取消不得 spawn")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "实际错误：\(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerPath),
            "§68：取消路径零 side effect"
        )
        // §68：redeem 之前中止不消费 authorization（B1 既定语义：
        // 记录仍为 executionClaimed、redeemed == false）。
        let snapshot = await inputs.coordinator.snapshot(approvalID: inputs.authorization.approvalID)
        XCTAssertEqual(snapshot?.state, .executionClaimed)
    }

    // MARK: - §69 取消竞态压力

    func testCancellationRaceStressLeavesNoOrphanProcess() async throws {
        let delays: [UInt64] = [0, 2_000_000, 6_000_000, 12_000_000, 25_000_000, 45_000_000]
        for (index, delay) in delays.enumerated() {
            let markerPath = workspace.path("race-\(index).pid")
            let command = "echo $$ > '\(markerPath)'\nsleep 30"
            let inputs = try await makeCancelTestInputs(command: command)
            let executor = inputs.executor
            let coordinator = inputs.coordinator
            let authorization = inputs.authorization
            let task = Task {
                try await executor.execute(
                    authorization: authorization,
                    approvalCoordinator: coordinator
                )
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            task.cancel()

            let outcome = await task.result
            switch outcome {
            case .success(let result):
                XCTAssertTrue(result.cancelled, "第 \(index) 轮：取消后的成功返回必须 cancelled")
                XCTAssertFalse(result.timedOut)
            case .failure(let error):
                XCTAssertTrue(
                    error is CancellationError,
                    "第 \(index) 轮：spawn 前取消必须抛 CancellationError，实际：\(error)"
                )
            }
            if let childPID = readPID(fromFileAt: markerPath) {
                let childGone = await AgentLocalCommandTestProcessProbe.waitUntilGone(childPID)
                XCTAssertTrue(childGone, "第 \(index) 轮：child \(childPID) 不得残留")
            }
        }
    }

    // MARK: - §105 退出路径清理

    func testExecutorRemainsUsableAfterTimeoutAndCancellation() async throws {
        let timeoutPolicy = AgentLocalCommandExecutionPolicy(
            timeout: .milliseconds(120),
            terminationGracePeriod: .milliseconds(200)
        )
        let first = try await execute("sleep 30", policy: timeoutPolicy)
        XCTAssertTrue(first.timedOut)

        let second = try await execute(#"printf 'still-alive\n'"#, policy: timeoutPolicy)
        XCTAssertEqual(second.stdout, "still-alive\n")
        XCTAssertEqual(second.exitCode, 0)
        XCTAssertFalse(second.timedOut)
    }

    func testTimeoutTerminatesBackgroundDescendantAndReapsGroup() async throws {
        let policy = AgentLocalCommandExecutionPolicy(
            timeout: .milliseconds(150),
            terminationGracePeriod: .milliseconds(300)
        )
        let command = """
        sleep 30 &
        printf 'BG=%s\\n' "$!"
        sleep 30
        """
        let result = try await execute(command, policy: policy)
        XCTAssertTrue(result.timedOut)
        let backgroundPID = try XCTUnwrap(parsePID(prefix: "BG=", from: result.stdout))
        let descendantGone = await AgentLocalCommandTestProcessProbe.waitUntilGone(backgroundPID)
        XCTAssertTrue(descendantGone)
    }
}
