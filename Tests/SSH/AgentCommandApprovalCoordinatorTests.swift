import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B1 §18–§25/§39–§45/§59/§69/§74–§82/§87：approval 状态机
/// 与一次性执行授权（串行语义；并发压力在 Concurrency suite）。
@MainActor
final class AgentCommandApprovalCoordinatorTests: XCTestCase {
    private var coordinator: AgentCommandApprovalCoordinator!

    override func setUp() async throws {
        coordinator = AgentCommandApprovalCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
    }

    // MARK: - Fixture

    private func makeGeneration() -> (generationID: UUID, sessionID: UUID, snapshotID: UUID) {
        (UUID(), UUID(), UUID())
    }

    private func registerPending(
        generationID: UUID,
        sessionID: UUID = UUID(),
        snapshotID: UUID = UUID(),
        callID: String = "call_1",
        command: String = "echo hi"
    ) async throws -> UUID {
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            generationID: generationID,
            callID: callID,
            sessionID: sessionID,
            command: command,
            snapshotID: snapshotID
        )
        return await coordinator.register(request)
    }

    private func expectations(
        _ request: AgentCommandRequest
    ) -> AgentCommandClaimExpectations {
        AgentCommandClaimExpectations(
            generationID: request.generationID,
            sessionID: request.sessionID,
            providerSnapshotID: request.providerBinding.snapshotID
        )
    }

    /// snapshot 读取 helper：await 必须发生在 XCTAssert autoclosure 之外。
    private func approvalSnapshot(for approvalID: UUID) async throws -> AgentCommandApprovalSnapshot {
        let value = await coordinator.snapshot(approvalID: approvalID)
        return try XCTUnwrap(value)
    }

    // MARK: - 新建 pending（§20）

    func testNewApprovalStartsAwaitingApproval() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            snapshotID: generation.snapshotID
        )
        let snapshot = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(snapshot.state, .awaitingApproval)
        let pendingCount = await coordinator.pendingApprovalCount()
        XCTAssertEqual(pendingCount, 1)
        // §20：此刻不存在任何执行授权——claim 必须失败。
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID, expected: expectations(snapshot.request)
            )
            XCTFail("awaitingApproval 不可 claim（§75）")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalNotApproved)
        }
    }

    func testDuplicateCallIDRegistersIdempotently() async throws {
        let generation = makeGeneration()
        let first = try await registerPending(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            snapshotID: generation.snapshotID,
            callID: "call_dup"
        )
        let second = try await registerPending(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            snapshotID: generation.snapshotID,
            callID: "call_dup"
        )
        XCTAssertEqual(first, second, "同 generation 同 callID 绝不产生第二个审批")
        let pendingForGeneration = await coordinator.pendingApprovalCount(generationID: generation.generationID)
        XCTAssertEqual(pendingForGeneration, 1)
    }

    // MARK: - Approve / Deny（§21/§22）

    func testApproveTransitionsToApprovedWithoutExecutingAnything() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let result = await coordinator.approve(approvalID)
        XCTAssertEqual(result, .performed)
        let snapshot = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(snapshot.state, .approved)
        // approve 只是资格授予：没有 claim 前 executor 无从获得授权。
    }

    func testDenyTransitionsToDeniedAndMapsUserDeniedSemantics() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let result = await coordinator.deny(approvalID)
        XCTAssertEqual(result, .performed)
        let snapshot = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(snapshot.state, .denied)
        // §60：userDenied 与 cancelled 是不同语义（Resolution 分离）。
        let resolution = try await coordinator.awaitDecision(approvalID: approvalID)
        XCTAssertEqual(resolution, .denied)
        // denied 后 claim 失败。
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID, expected: expectations(snapshot.request)
            )
            XCTFail("denied 不可 claim")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalAlreadyResolved)
        }
    }

    // MARK: - Cancellation（§23/§24/§25）

    func testStopBeforeApprovalInvalidatesApproval() async throws {
        // §24：pending → generation cancelled → 用户随后点 Approve 必须 no-op。
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let invalidated = await coordinator.cancelGeneration(generation.generationID)
        XCTAssertEqual(invalidated, 1)
        let snapshot = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(snapshot.state, .cancelled)
        let result = await coordinator.approve(approvalID)
        XCTAssertEqual(result, .alreadyResolved(.cancelled), "取消后 Approve 必须 no-op")
        // execution authorization = none：claim 失败。
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID, expected: expectations(snapshot.request)
            )
            XCTFail("cancelled 不可 claim（§77）")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalCancelled)
        }
    }

    func testSessionCloseBeforeApprovalInvalidatesApproval() async throws {
        // §25：origin session 关闭后 Approve 必须 stale / cancelled，
        // 绝不重新绑定 active session。
        let generation = makeGeneration()
        let approvalID = try await registerPending(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            snapshotID: generation.snapshotID
        )
        let invalidated = await coordinator.cancelSession(generation.sessionID)
        XCTAssertEqual(invalidated, 1)
        let result = await coordinator.approve(approvalID)
        XCTAssertEqual(result, .alreadyResolved(.cancelled))
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID,
                expected: AgentCommandClaimExpectations(
                    generationID: generation.generationID,
                    sessionID: generation.sessionID,
                    providerSnapshotID: generation.snapshotID
                )
            )
            XCTFail("session close 后不可 claim")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalCancelled)
        }
    }

    func testStopAfterApproveBeforeClaimInvalidatesClaim() async throws {
        // §30 hard gate：approve → Stop → claim 必须失败。
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        _ = await coordinator.approve(approvalID)
        let invalidated = await coordinator.cancelGeneration(generation.generationID)
        XCTAssertEqual(invalidated, 1, "approved 未 claim 仍可被 Stop 失效")
        let snapshot = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(snapshot.state, .cancelled)
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID, expected: expectations(snapshot.request)
            )
            XCTFail("Stop after approve 必须 invalidate pre-execution claim")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalCancelled)
        }
    }

    func testCancelApprovalDirectly() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let result = await coordinator.cancelApproval(approvalID)
        XCTAssertEqual(result, .performed)
        let snapshot = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(snapshot.state, .cancelled)
        // 已 cancelled 再 cancel → no-op。
        let second = await coordinator.cancelApproval(approvalID)
        XCTAssertEqual(second, .alreadyResolved(.cancelled))
    }

    func testCancelGenerationLeavesOtherGenerationsUntouched() async throws {
        let genA = makeGeneration()
        let genB = makeGeneration()
        _ = try await registerPending(generationID: genA.generationID)
        let approvalB = try await registerPending(generationID: genB.generationID)
        let invalidated = await coordinator.cancelGeneration(genA.generationID)
        XCTAssertEqual(invalidated, 1)
        let snapshotB = try await approvalSnapshot(for: approvalB)
        XCTAssertEqual(snapshotB.state, .awaitingApproval, "A 的取消绝不波及 B")
        let pendingCount = await coordinator.pendingApprovalCount()
        XCTAssertEqual(pendingCount, 1)
    }

    // MARK: - 单次 claim（§29/§31/§74）

    func testClaimOnceSucceedsAndSecondClaimFails() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            snapshotID: generation.snapshotID
        )
        _ = await coordinator.approve(approvalID)
        let snapshot = try await approvalSnapshot(for: approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID, expected: expectations(snapshot.request)
        )
        XCTAssertEqual(authorization.request.command, snapshot.request.command)
        XCTAssertEqual(authorization.request.workingDirectory, snapshot.request.workingDirectory)
        XCTAssertEqual(authorization.request.sessionID, snapshot.request.sessionID)

        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID, expected: expectations(snapshot.request)
            )
            XCTFail("§74：同一 approval 不可 claim 两次")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalAlreadyClaimed)
        }
        let after = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(after.state, .executionClaimed)
    }

    func testRedeemIsSingleUse() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        _ = await coordinator.approve(approvalID)
        let snapshot = try await approvalSnapshot(for: approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID, expected: expectations(snapshot.request)
        )
        let redeemed = try await coordinator.redeem(authorization)
        XCTAssertEqual(redeemed, snapshot.request, "§43：executor 拿到的是 coordinator 保存的原 request")
        do {
            _ = try await coordinator.redeem(authorization)
            XCTFail("§32：授权单次消费，重复 redeem 必须失败")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalAlreadyClaimed)
        }
    }

    func testRedeemRejectsUnregisteredPermit() async throws {
        // 伪造 / 不认识的 permit → approvalStale（§32：有效性由状态背书）。
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        _ = await coordinator.approve(approvalID)
        let snapshot = try await approvalSnapshot(for: approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID, expected: expectations(snapshot.request)
        )
        let forged = AgentCommandExecutionAuthorization(
            approvalID: authorization.approvalID,
            generationID: authorization.generationID,
            callID: authorization.callID,
            sessionID: authorization.sessionID,
            request: authorization.request,
            permit: UUID()
        )
        do {
            _ = try await coordinator.redeem(forged)
            XCTFail("伪造 permit 必须被拒绝")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalStale)
        }
    }

    // MARK: - 绑定校验（§78–§80）

    func testClaimWithWrongGenerationFails() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        _ = await coordinator.approve(approvalID)
        let snapshot = try await approvalSnapshot(for: approvalID)
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID,
                expected: AgentCommandClaimExpectations(
                    generationID: UUID(),
                    sessionID: generation.sessionID,
                    providerSnapshotID: generation.snapshotID
                )
            )
            XCTFail("generation A 的审批不得以 generation B 身份 claim")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .bindingMismatch)
        }
        // 失败的 claim 不消耗授权（state 仍 approved，正确绑定可 claim）。
        _ = try await coordinator.claimExecution(
            approvalID: approvalID, expected: expectations(snapshot.request)
        )
    }

    func testClaimWithWrongSessionFails() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        _ = await coordinator.approve(approvalID)
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID,
                expected: AgentCommandClaimExpectations(
                    generationID: generation.generationID,
                    sessionID: UUID(),
                    providerSnapshotID: generation.snapshotID
                )
            )
            XCTFail("session A 的审批不得以 session B 身份 claim（§45/§79）")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .bindingMismatch)
        }
    }

    func testClaimWithWrongProviderSnapshotFails() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        _ = await coordinator.approve(approvalID)
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID,
                expected: AgentCommandClaimExpectations(
                    generationID: generation.generationID,
                    sessionID: generation.sessionID,
                    providerSnapshotID: UUID()
                )
            )
            XCTFail("snapshot A 的审批不得以 snapshot B 身份 claim（§80/§42）")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .bindingMismatch)
        }
    }

    func testClaimUnknownApprovalFails() async {
        do {
            _ = try await coordinator.claimExecution(
                approvalID: UUID(),
                expected: AgentCommandClaimExpectations(
                    generationID: UUID(), sessionID: UUID(), providerSnapshotID: UUID()
                )
            )
            XCTFail("未知 approvalID 必须 approvalNotFound")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalNotFound)
        } catch {
            XCTFail("非 domain 错误: \(error)")
        }
    }

    // MARK: - Exact integrity（§43/§44/§45）

    func testClaimedRequestIsExactlyTheApprovedRequest() async throws {
        let generation = makeGeneration()
        let command = "echo A && pwd\nls -la"
        let approvalID = try await registerPending(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            snapshotID: generation.snapshotID,
            command: command
        )
        let pending = try await approvalSnapshot(for: approvalID)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID, expected: expectations(pending.request)
        )
        // Approve A 执行时必须仍是 A：command / cwd / session 逐一相等。
        XCTAssertEqual(authorization.request, pending.request)
        XCTAssertEqual(authorization.request.command, command)
        XCTAssertEqual(authorization.request.workingDirectory, pending.request.workingDirectory)
        XCTAssertEqual(authorization.request.sessionID, generation.sessionID)
    }

    // MARK: - A/B 隔离（§81/§96）

    func testApprovalsOfDifferentSessionsAreIsolatedFromActiveSessionMetadata() async throws {
        let sessionA = UUID()
        let sessionB = UUID()
        let approvalA = try await registerPending(generationID: UUID(), sessionID: sessionA)
        let approvalB = try await registerPending(generationID: UUID(), sessionID: sessionB)
        // 任意"active session metadata"切换不影响 coordinator——它只认
        // approvalID / request.sessionID（§81：不关心 active tab）。
        _ = await coordinator.approve(approvalA)
        let snapshotA = try await approvalSnapshot(for: approvalA)
        XCTAssertEqual(snapshotA.state, .approved)
        let snapshotB = try await approvalSnapshot(for: approvalB)
        XCTAssertEqual(snapshotB.state, .awaitingApproval, "Approve A 只能影响 A")
        XCTAssertEqual(snapshotA.request.sessionID, sessionA)
        XCTAssertEqual(snapshotB.request.sessionID, sessionB)
    }

    func testApprovalsOfDifferentGenerationsAreIsolated() async throws {
        let genA = makeGeneration()
        let genB = makeGeneration()
        let approvalA = try await registerPending(generationID: genA.generationID)
        let approvalB = try await registerPending(generationID: genB.generationID)
        _ = await coordinator.approve(approvalA)
        // generation B 取消不影响 A 的 approved 状态。
        _ = await coordinator.cancelGeneration(genB.generationID)
        let snapshotA = try await approvalSnapshot(for: approvalA)
        XCTAssertEqual(snapshotA.state, .approved)
        let snapshotB = try await approvalSnapshot(for: approvalB)
        XCTAssertEqual(snapshotB.state, .cancelled)
    }

    // MARK: - Await decision（§82–§85；并发版在 Concurrency suite）

    func testApproveThenAwaitReturnsImmediately() async throws {
        // §82：decision-before-wait 绝不悬挂。
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        _ = await coordinator.approve(approvalID)
        let resolution = try await coordinator.awaitDecision(approvalID: approvalID)
        XCTAssertEqual(resolution, .approved)
    }

    func testWaitThenApproveResumesOnce() async throws {
        // §83：waiter 先启动、决策后到 → 恰好恢复一次。
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let waiter = Task { try await coordinator.awaitDecision(approvalID: approvalID) }
        // 让 waiter 先挂起。
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await coordinator.approve(approvalID)
        let resolution = try await waiter.value
        XCTAssertEqual(resolution, .approved)
    }

    func testWaitThenDenyResumesWithDenied() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let waiter = Task { try await coordinator.awaitDecision(approvalID: approvalID) }
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await coordinator.deny(approvalID)
        let resolution = try await waiter.value
        XCTAssertEqual(resolution, .denied)
    }

    func testWaitThenCancelGenerationResumesWithCancelled() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let waiter = Task { try await coordinator.awaitDecision(approvalID: approvalID) }
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await coordinator.cancelGeneration(generation.generationID)
        let resolution = try await waiter.value
        XCTAssertEqual(resolution, .cancelled)
    }

    func testWaiterTaskCancellationDoesNotCancelApproval() async throws {
        // §86：waiter 自身取消 ≠ 取消 approval；不自动批准、不产生授权。
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let waiter = Task { try await coordinator.awaitDecision(approvalID: approvalID) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("被取消的 waiter 必须以 CancellationError 结束")
        } catch is CancellationError {
            // 预期路径。
        }
        let snapshot = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(snapshot.state, .awaitingApproval, "approval 生命周期归 generation，不随 waiter 取消")
        // 后续正常决策仍可用。
        _ = await coordinator.approve(approvalID)
        let resolution = try await coordinator.awaitDecision(approvalID: approvalID)
        XCTAssertEqual(resolution, .approved)
    }

    func testWaitOnUnknownApprovalThrowsNotFound() async {
        do {
            _ = try await coordinator.awaitDecision(approvalID: UUID())
            XCTFail("未知 approvalID 必须 approvalNotFound")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalNotFound)
        } catch {
            XCTFail("非 domain 错误: \(error)")
        }
    }

    // MARK: - 清理（§39–§41/§87）

    func testCancelGenerationDropsPendingRecords() async throws {
        let generation = makeGeneration()
        _ = try await registerPending(generationID: generation.generationID, callID: "call_1")
        _ = try await registerPending(generationID: generation.generationID, callID: "call_2")
        _ = try await registerPending(generationID: UUID(), callID: "call_3")
        let invalidated = await coordinator.cancelGeneration(generation.generationID)
        XCTAssertEqual(invalidated, 2)
        let pendingForGeneration = await coordinator.pendingApprovalCount(generationID: generation.generationID)
        XCTAssertEqual(pendingForGeneration, 0)
        let pendingOther = await coordinator.pendingApprovalCount()
        XCTAssertEqual(pendingOther, 1, "其他 generation 不受影响")
    }

    func testSessionCancelDropsPendingRecordsForThatSessionOnly() async throws {
        let sessionA = UUID()
        let sessionB = UUID()
        _ = try await registerPending(generationID: UUID(), sessionID: sessionA)
        _ = try await registerPending(generationID: UUID(), sessionID: sessionB)
        let invalidated = await coordinator.cancelSession(sessionA)
        XCTAssertEqual(invalidated, 1)
        let pendingSessionA = await coordinator.pendingApprovalCount(sessionID: sessionA)
        XCTAssertEqual(pendingSessionA, 0)
        let pendingSessionB = await coordinator.pendingApprovalCount(sessionID: sessionB)
        XCTAssertEqual(pendingSessionB, 1)
    }

    func testPurgeRemovesAllRecordsForGeneration() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        _ = try await registerPending(generationID: generation.generationID, callID: "call_2")
        // 一条已 approve（pending），一条保持 awaiting。
        _ = await coordinator.approve(approvalID)
        let removed = await coordinator.purgeGeneration(generation.generationID)
        XCTAssertEqual(removed, 2)
        let snapshot = await coordinator.snapshot(approvalID: approvalID)
        XCTAssertNil(snapshot, "purge 后记录消失")
        let pendingForGeneration = await coordinator.pendingApprovalCount(generationID: generation.generationID)
        XCTAssertEqual(pendingForGeneration, 0)
    }

    func testNormalResolveDropsPendingCount() async throws {
        let generation = makeGeneration()
        let approvalID = try await registerPending(generationID: generation.generationID)
        let pendingCount = await coordinator.pendingApprovalCount()
        XCTAssertEqual(pendingCount, 1)
        _ = await coordinator.approve(approvalID)
        let snapshot = try await approvalSnapshot(for: approvalID)
        _ = try await coordinator.claimExecution(
            approvalID: approvalID, expected: expectations(snapshot.request)
        )
        let pendingAfterClaim = await coordinator.pendingApprovalCount()
        XCTAssertEqual(pendingAfterClaim, 0, "executionClaimed 不再 pending")
        // 记录保留（bounded retention 由 teardown purge 承担）。
        let after = try await approvalSnapshot(for: approvalID)
        XCTAssertEqual(after.state, .executionClaimed)
    }
}
