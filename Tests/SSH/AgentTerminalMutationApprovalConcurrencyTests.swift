import Foundation
import XCTest

@testable import MacSSH

/// Phase 10F-B1 任务书 §33/§51：审批状态机并发 hard race。
///
/// 全部用 actor 隔离 + task group 实现确定性竞争（无 sleep-based race）：
/// 无论 approve / deny / cancel / claim / redeem 如何交错，恰好一个
/// terminal transition 或一次有效 claim / redeem 胜出；cancellation
/// 赢得 race 后绝不允许出现有效授权（线性化点：claim 的 CAS 转移、
/// redeem 的 permit 消费）。
final class AgentTerminalMutationApprovalConcurrencyTests: XCTestCase {
    // MARK: - Fixture

    private func makePendingApproval() async throws -> (
        coordinator: AgentTerminalMutationApprovalCoordinator,
        approvalID: UUID,
        request: AgentTerminalMutationRequest
    ) {
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let approvalID = await coordinator.register(request)
        return (coordinator, approvalID, request)
    }

    /// await 必须发生在 XCTAssert autoclosure 之外（对齐 10E 测试惯例）。
    private func snapshotOf(
        _ coordinator: AgentTerminalMutationApprovalCoordinator,
        _ approvalID: UUID
    ) async throws -> AgentTerminalMutationApprovalSnapshot {
        let value = await coordinator.snapshot(approvalID: approvalID)
        return try XCTUnwrap(value)
    }

    // MARK: - approve vs approve（§34）

    func testHundredConcurrentApprovesProduceExactlyOneTransition() async throws {
        let (coordinator, approvalID, _) = try await makePendingApproval()

        let results = try await withThrowingTaskGroup(
            of: AgentTerminalMutationApprovalActionResult.self
        ) { group in
            for _ in 0..<100 {
                group.addTask { await coordinator.approve(approvalID) }
            }
            var collected: [AgentTerminalMutationApprovalActionResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.filter { $0 == .performed }.count, 1, "100 个并发 approve 必须恰好一个生效")
        XCTAssertEqual(results.filter { $0 == .notFound }.count, 0)
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .approved)
    }

    // MARK: - approve vs deny（§38）

    func testFiftyApproveFiftyDenyProduceExactlyOneTerminalDecision() async throws {
        let (coordinator, approvalID, _) = try await makePendingApproval()

        let results = try await withThrowingTaskGroup(
            of: AgentTerminalMutationApprovalActionResult.self
        ) { group in
            for index in 0..<100 {
                group.addTask {
                    index % 2 == 0
                        ? await coordinator.approve(approvalID)
                        : await coordinator.deny(approvalID)
                }
            }
            var collected: [AgentTerminalMutationApprovalActionResult] = []
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
    }

    // MARK: - approve vs cancel（§39）

    func testApproveVersusCancelRaceYieldsCancelledOrApprovedThenCancelled() async throws {
        let (coordinator, approvalID, request) = try await makePendingApproval()

        let results = try await withThrowingTaskGroup(
            of: AgentTerminalMutationApprovalActionResult.self
        ) { group in
            group.addTask { await coordinator.approve(approvalID) }
            group.addTask { await coordinator.cancelApproval(approvalID) }
            var collected: [AgentTerminalMutationApprovalActionResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        // 线性化序只允许两种：approve→cancel（两次 performed）或
        // cancel→approve（一次 performed + alreadyResolved）。
        let performed = results.filter { $0 == .performed }.count
        XCTAssertTrue(performed == 1 || performed == 2, "performed 次数必须为 1 或 2，实际 \(performed)")
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .cancelled, "cancel 生效后终态必为 cancelled（approved 未 claim 仍可取消）")
        // 无论谁赢：claim 之后都必须失败（零授权）。
        let expected = AgentTerminalMutationTestSupport.expectations(for: request)
        do {
            _ = try await coordinator.claimExecution(approvalID: approvalID, expected: expected)
            XCTFail("竞态结束后 claim 必须失败")
        } catch let error as AgentTerminalMutationError {
            XCTAssertEqual(error, .approvalCancelled)
        }
    }

    // MARK: - redeem vs redeem（§35）

    func testFiftyConcurrentRedeemsProduceExactlyOneSuccess() async throws {
        let (coordinator, approvalID, request) = try await makePendingApproval()
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )

        let results = try await withThrowingTaskGroup(
            of: Result<AgentTerminalMutationRequest, Error>.self
        ) { group in
            for _ in 0..<50 {
                group.addTask {
                    do {
                        return .success(try await coordinator.redeem(authorization))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<AgentTerminalMutationRequest, Error>] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        let successes = results.compactMap { try? $0.get() }
        XCTAssertEqual(successes.count, 1, "50 个并发 redeem 必须恰好一个成功")
        XCTAssertEqual(successes.first, request, "唯一成功的 redeem 返回冻结原 request")
        let failures = results.filter {
            (try? $0.get()) == nil
        }.compactMap {
            $0.getError() as? AgentTerminalMutationError
        }
        XCTAssertEqual(failures.count, 49)
        for error in failures {
            XCTAssertEqual(error, .approvalAlreadyConsumed)
        }
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .redeemed)
    }

    // MARK: - claim race（§17：一次 claim）

    func testConcurrentClaimsProduceExactlyOneAuthorization() async throws {
        let (coordinator, approvalID, request) = try await makePendingApproval()
        _ = await coordinator.approve(approvalID)
        let expected = AgentTerminalMutationTestSupport.expectations(for: request)

        let errors = try await withThrowingTaskGroup(
            of: AgentTerminalMutationError?.self
        ) { group in
            for _ in 0..<50 {
                group.addTask {
                    do {
                        _ = try await coordinator.claimExecution(
                            approvalID: approvalID, expected: expected
                        )
                        return nil
                    } catch let error as AgentTerminalMutationError {
                        return error
                    } catch {
                        return nil
                    }
                }
            }
            var collected: [AgentTerminalMutationError?] = []
            for try await error in group {
                collected.append(error)
            }
            return collected
        }

        let successes = errors.filter { $0 == nil }
        XCTAssertEqual(successes.count, 1, "恰好一次有效 claim")
        XCTAssertEqual(errors.filter { $0 == .approvalAlreadyConsumed }.count, 49)
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .executionClaimed)
    }

    // MARK: - invalidate generation vs approve（§24/§51）

    func testGenerationInvalidationVersusApproveLeavesZeroAuthorization() async throws {
        let (coordinator, approvalID, request) = try await makePendingApproval()

        let results = try await withThrowingTaskGroup(
            of: AgentTerminalMutationApprovalActionResult.self
        ) { group in
            group.addTask { await coordinator.approve(approvalID) }
            group.addTask {
                _ = await coordinator.cancelGeneration(request.generationID)
                return .notFound
            }
            var collected: [AgentTerminalMutationApprovalActionResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        // 无论交错顺序：approve 至多生效一次；generation 取消覆盖该授权。
        XCTAssertEqual(results.filter { $0 == .performed }.count <= 1 ? 1 : 0, 1)
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .cancelled, "无论 approve 先后，最终均为 cancelled")
        // 零授权终局：claim 必败。
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID,
                expected: AgentTerminalMutationTestSupport.expectations(for: request)
            )
            XCTFail("generation 失效后 claim 必须失败")
        } catch let error as AgentTerminalMutationError {
            XCTAssertEqual(error, .approvalCancelled)
        }
    }

    // MARK: - invalidate generation vs redeem（§39/§51）

    func testGenerationInvalidationVersusRedeemHasExactlyOneLegalWinner() async throws {
        let (coordinator, approvalID, request) = try await makePendingApproval()
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )

        let (redeemSucceeded, finalSnapshot) = try await withThrowingTaskGroup(
            of: (Bool, AgentTerminalMutationApprovalSnapshot).self
        ) { group -> (Bool, AgentTerminalMutationApprovalSnapshot) in
            group.addTask { () -> (Bool, AgentTerminalMutationApprovalSnapshot) in
                do {
                    _ = try await coordinator.redeem(authorization)
                    let snapshot = await coordinator.snapshot(approvalID: approvalID)
                    return (true, try XCTUnwrap(snapshot))
                } catch {
                    let snapshot = await coordinator.snapshot(approvalID: approvalID)
                    return (false, try XCTUnwrap(snapshot))
                }
            }
            group.addTask { () -> (Bool, AgentTerminalMutationApprovalSnapshot) in
                _ = await coordinator.cancelGeneration(request.generationID)
                let snapshot = await coordinator.snapshot(approvalID: approvalID)
                return (false, try XCTUnwrap(snapshot))
            }
            var redeemSucceeded = false
            var finalSnapshot: AgentTerminalMutationApprovalSnapshot?
            for try await (redeemed, snapshot) in group {
                if redeemed { redeemSucceeded = true }
                finalSnapshot = finalSnapshot ?? snapshot
            }
            return (redeemSucceeded, try XCTUnwrap(finalSnapshot))
        }

        if redeemSucceeded {
            // redeem 赢得线性化点：终态 redeemed，取消无法再影响。
            XCTAssertEqual(finalSnapshot.state, .redeemed)
        } else {
            // 取消赢得线性化点：授权失效，redeem 失败。
            XCTAssertEqual(finalSnapshot.state, .cancelled)
        }
        // 无论谁赢：再次 redeem 必须失败（无第二次授权）。
        do {
            _ = try await coordinator.redeem(authorization)
            XCTFail("竞态结束后 redeem 必须失败（最多一次成功已发生）")
        } catch let error as AgentTerminalMutationError {
            XCTAssertTrue(
                error == .approvalStale || error == .approvalAlreadyConsumed,
                "实际错误 \(error)"
            )
        }
    }

    // MARK: - 不变式：cancellation 后绝不出现有效授权（§33 硬不变式）

    func testConcurrentCancelAndApproveNeverYieldsClaimableApproval() async throws {
        for _ in 0..<20 {
            let (coordinator, approvalID, request) = try await makePendingApproval()
            _ = try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        if index % 2 == 0 {
                            _ = await coordinator.approve(approvalID)
                        } else {
                            _ = await coordinator.cancelGeneration(
                                AgentTerminalMutationTestSupport.generationID
                            )
                        }
                    }
                }
            }
            let snapshot = try await snapshotOf(coordinator, approvalID)
            XCTAssertEqual(
                snapshot.state, .cancelled,
                "cancelGeneration 在 actor 内串行覆盖 approved，终局恒为 cancelled"
            )
            // 终局零授权。
            do {
                _ = try await coordinator.claimExecution(
                    approvalID: approvalID,
                    expected: AgentTerminalMutationTestSupport.expectations(for: request)
                )
                XCTFail("竞态结束后 claim 必须失败")
            } catch let error as AgentTerminalMutationError {
                XCTAssertEqual(error, .approvalCancelled)
            }
        }
    }
}

// MARK: - Result 错误提取 helper（仅测试用）

private extension Result {
    func getError() -> (any Error)? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
