import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B1 §26–§28/§71–§73/§95：审批状态机的并发 hard race。
///
/// 核心不变式：**exactly one approval authority** —— 无论 approve /
/// deny / cancel / claim 如何交错，恰好一个 terminal transition 或
/// 一次有效 claim 胜出；一旦 cancellation 赢得 race，绝不允许出现
/// 有效 execution claim（线性化点：claim 的 CAS 转移）。
final class AgentCommandApprovalConcurrencyTests: XCTestCase {
    // MARK: - Fixture

    private func makePendingApproval() async throws -> (
        coordinator: AgentCommandApprovalCoordinator,
        approvalID: UUID,
        request: AgentCommandRequest
    ) {
        let coordinator = AgentCommandApprovalCoordinator()
        let request = try AgentCommandTestSupport.makeRequestOrThrow()
        let approvalID = await coordinator.register(request)
        return (coordinator, approvalID, request)
    }

    private func expectations(_ request: AgentCommandRequest) -> AgentCommandClaimExpectations {
        AgentCommandClaimExpectations(
            generationID: request.generationID,
            sessionID: request.sessionID,
            providerSnapshotID: request.providerBinding.snapshotID
        )
    }

    /// await 必须发生在 XCTAssert / XCTUnwrap autoclosure 之外。
    private func snapshotOf(
        _ coordinator: AgentCommandApprovalCoordinator,
        _ approvalID: UUID
    ) async throws -> AgentCommandApprovalSnapshot {
        let value = await coordinator.snapshot(approvalID: approvalID)
        return try XCTUnwrap(value)
    }

    // MARK: - Double approve（§28/§71）

    func testHundredConcurrentApprovesProduceExactlyOneTransition() async throws {
        let (coordinator, approvalID, _) = try await makePendingApproval()

        let results = try await withThrowingTaskGroup(
            of: AgentCommandApprovalActionResult.self
        ) { group in
            for _ in 0..<100 {
                group.addTask { await coordinator.approve(approvalID) }
            }
            var collected: [AgentCommandApprovalActionResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        let performed = results.filter { $0 == .performed }
        let alreadyResolved = results.filter {
            $0 == .alreadyResolved(.approved) || $0 == .alreadyResolved(.awaitingApproval)
        }
        XCTAssertEqual(performed.count, 1, "100 个并发 approve 必须恰好一个生效")
        XCTAssertEqual(alreadyResolved.count, 99, "其余 99 个必须 alreadyResolved")
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .approved)
    }

    // MARK: - Approve vs deny（§27/§72）

    func testFiftyApproveFiftyDenyProduceExactlyOneTerminalDecision() async throws {
        let (coordinator, approvalID, _) = try await makePendingApproval()

        let results = try await withThrowingTaskGroup(
            of: AgentCommandApprovalActionResult.self
        ) { group in
            for index in 0..<100 {
                group.addTask {
                    index % 2 == 0
                        ? await coordinator.approve(approvalID)
                        : await coordinator.deny(approvalID)
                }
            }
            var collected: [AgentCommandApprovalActionResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.filter { $0 == .performed }.count, 1, "恰好一个 terminal decision")
        XCTAssertEqual(results.filter { $0 == .notFound }.count, 0)
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertTrue(
            snapshot.state == .approved || snapshot.state == .denied,
            "终态必须是 approved / denied 之一，实际 \(snapshot.state)"
        )
        // 终态与唯一生效转移一致。
        if snapshot.state == .approved {
            XCTAssertTrue(results.contains(.performed))
        }
    }

    // MARK: - Claim race（§29/§74：单次 claim）

    func testConcurrentClaimsProduceExactlyOneAuthorization() async throws {
        let (coordinator, approvalID, request) = try await makePendingApproval()
        _ = await coordinator.approve(approvalID)

        var successes = 0
        var alreadyClaimed = 0
        let expected = expectations(request)
        try await withThrowingTaskGroup(of: AgentCommandError?.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    do {
                        _ = try await coordinator.claimExecution(
                            approvalID: approvalID, expected: expected
                        )
                        return nil
                    } catch let error as AgentCommandError {
                        return error
                    }
                }
            }
            for try await error in group {
                if let error {
                    XCTAssertEqual(error, .approvalAlreadyClaimed)
                    alreadyClaimed += 1
                } else {
                    successes += 1
                }
            }
        }
        XCTAssertEqual(successes, 1, "并发 claim 恰好一个成功（§74）")
        XCTAssertEqual(alreadyClaimed, 49)
    }

    // MARK: - Approve vs cancel vs claim（§26/§73）

    func testApproveCancelClaimRaceNeverYieldsValidClaimAfterCancellation() async throws {
        // §73 invariant（线性化点 = claim CAS）：
        // - claim 成功 ⇒ approve 先于 cancel 完成，cancelGeneration 对该
        //   approval 返回 0（executionClaimed 不可经审批路径撤销——属于
        //   未来 executor cancellation 语义）；
        // - cancel 失效 ≥1 ⇒ claim 必然失败（approvalCancelled 等）。
        // 绝不允许 "state says cancelled 但 authorization 仍有效"。
        for round in 0..<25 {
            let (coordinator, approvalID, request) = try await makePendingApproval()
            let expected = expectations(request)

            let outcome = await withTaskGroup(
                of: String.self
            ) { group in
                group.addTask {
                    let result = await coordinator.approve(approvalID)
                    return "approve:\(result == .performed ? "performed" : "lost")"
                }
                group.addTask {
                    let count = await coordinator.cancelGeneration(request.generationID)
                    return "cancel:\(count)"
                }
                group.addTask {
                    do {
                        _ = try await coordinator.claimExecution(
                            approvalID: approvalID,
                            expected: expected
                        )
                        return "claim:ok"
                    } catch let error as AgentCommandError {
                        return "claim:\(error)"
                    } catch {
                        return "claim:unexpected"
                    }
                }
                var collected: [String] = []
                for await value in group {
                    collected.append(value)
                }
                return collected
            }

            let claimOutcome = outcome.first { $0.hasPrefix("claim:") } ?? "claim:missing"
            let cancelOutcome = outcome.first { $0.hasPrefix("cancel:") } ?? "cancel:missing"

            if claimOutcome == "claim:ok" {
                XCTAssertEqual(
                    cancelOutcome, "cancel:0",
                    "round \(round)：claim 成功后该 approval 不得再被审批路径取消"
                )
            } else {
                // claim 失败：cancel 必须失效了它（或 cancel 尚未轮到——
                // claim 先因 approvalNotApproved 失败时 cancel 必然 ≥1，
                // 因为 approve 与 cancel 都在 claim 前? 不——三种顺序都可能；
                // 断言严格不变式：只要 cancel 失效了（=1），claim 必败）。
                if cancelOutcome == "cancel:1" {
                    XCTAssertTrue(
                        claimOutcome == "claim:approvalCancelled"
                            || claimOutcome == "claim:approvalNotApproved",
                        "round \(round)：cancellation 生效后 claim 必须失败，实际 \(claimOutcome)"
                    )
                }
            }

            // 终态一致性：cancelled 状态下绝不能有有效授权。
            let snapshot = try await snapshotOf(coordinator, approvalID)
            if snapshot.state == .cancelled {
                XCTAssertNotEqual(claimOutcome, "claim:ok", "round \(round)：cancelled 但 claim 成功")
            }
        }
    }

    func testConcurrentCancelAndApproveConvergeToSingleOutcome() async throws {
        // §26：并发 approve + cancelGeneration 最终只能是
        // approved-and-still-valid 或 cancelled 之一。
        for _ in 0..<25 {
            let (coordinator, approvalID, request) = try await makePendingApproval()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await coordinator.approve(approvalID) }
                group.addTask { _ = await coordinator.cancelGeneration(request.generationID) }
            }
            let snapshot = try await snapshotOf(coordinator, approvalID)
            XCTAssertTrue(
                snapshot.state == .approved || snapshot.state == .cancelled,
                "只允许两种合法结局，实际 \(snapshot.state)"
            )
            if snapshot.state == .cancelled {
                do {
                    _ = try await coordinator.claimExecution(
                        approvalID: approvalID, expected: self.expectations(request)
                    )
                    XCTFail("cancelled 状态下 claim 必须失败（§26）")
                } catch let error as AgentCommandError {
                    XCTAssertEqual(error, .approvalCancelled)
                }
            }
        }
    }

    // MARK: - Waiter resume exactly once（§37/§95）

    func testDecisionRacingWaiterStartResumesExactlyOnce() async throws {
        // waiter 启动与决策落定竞争：waiter 要么立即拿到已存解析，
        // 要么被恢复一次；绝不悬挂、绝不二次恢复（二次恢复会触发
        // 运行时崩溃，测试通过即证明无 double resume）。
        for _ in 0..<20 {
            let (coordinator, approvalID, _) = try await makePendingApproval()
            let waiter = Task { try await coordinator.awaitDecision(approvalID: approvalID) }
            let resolver = Task { await coordinator.approve(approvalID) }
            let resolution = try await waiter.value
            _ = await resolver.value
            XCTAssertEqual(resolution, .approved)
        }
    }

    func testCancelAndDecisionRacingWaitersAllResumeExactlyOnce() async throws {
        // cancelGeneration 与 waiter 挂起竞争：waiter 全部以 cancelled
        // 恢复恰好一次。
        for _ in 0..<10 {
            let (coordinator, approvalID, request) = try await makePendingApproval()
            let waiter = Task { try await coordinator.awaitDecision(approvalID: approvalID) }
            let canceller = Task { _ = await coordinator.cancelGeneration(request.generationID) }
            let resolution = try await waiter.value
            _ = await canceller.value
            XCTAssertEqual(resolution, .cancelled)
        }
    }

    func testMultipleWaitersAllReceiveSameResolutionOnceEach() async throws {
        // §38 定义语义：多个 waiter 允许，每个恰好一次、同一 resolution；
        // 不产生多个执行尝试（awaitDecision 返回的是决策，不是授权）。
        let (coordinator, approvalID, _) = try await makePendingApproval()
        let waiters = (0..<5).map { _ in
            Task { try await coordinator.awaitDecision(approvalID: approvalID) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await coordinator.approve(approvalID)
        for waiter in waiters {
            let resolution = try await waiter.value
            XCTAssertEqual(resolution, .approved)
        }
        // 决策已落定后再 wait → 立即返回已存解析（§38 repeat wait）。
        let lateResolution = try await coordinator.awaitDecision(approvalID: approvalID)
        XCTAssertEqual(lateResolution, .approved)
    }
}
