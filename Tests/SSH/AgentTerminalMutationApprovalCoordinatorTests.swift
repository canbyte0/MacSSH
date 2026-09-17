import Foundation
import XCTest

@testable import MacSSH

/// Phase 10F-B1 任务书 §17/§19/§23–§28/§34/§36–§39/§49/§50：
/// 审批状态机、immutable 绑定矩阵、incarnation 矩阵、generation 替换、
/// replay 与 deny / cancel 语义。B1 全程零终端字节（§18）。
///
/// 惯例（对齐 10E 测试）：await 一律发生在 XCTAssert / XCTUnwrap
/// autoclosure **之外**，先取值再断言。
final class AgentTerminalMutationApprovalCoordinatorTests: XCTestCase {
    // MARK: - Fixture

    private func makePending(
        request: AgentTerminalMutationRequest
    ) async -> (AgentTerminalMutationApprovalCoordinator, UUID) {
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        return (coordinator, approvalID)
    }

    private func approvedCoordinator(
        for request: AgentTerminalMutationRequest
    ) async -> (AgentTerminalMutationApprovalCoordinator, UUID) {
        let (coordinator, approvalID) = await makePending(request: request)
        _ = await coordinator.approve(approvalID)
        return (coordinator, approvalID)
    }

    private func snapshotOf(
        _ coordinator: AgentTerminalMutationApprovalCoordinator,
        _ approvalID: UUID
    ) async throws -> AgentTerminalMutationApprovalSnapshot {
        let value = await coordinator.snapshot(approvalID: approvalID)
        return try XCTUnwrap(value)
    }

    private func claimError(
        _ coordinator: AgentTerminalMutationApprovalCoordinator,
        approvalID: UUID,
        expected: AgentTerminalMutationClaimExpectations
    ) async -> AgentTerminalMutationError? {
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

    private func redeemError(
        _ coordinator: AgentTerminalMutationApprovalCoordinator,
        _ authorization: AgentTerminalMutationExecutionAuthorization
    ) async -> (request: AgentTerminalMutationRequest?, error: AgentTerminalMutationError?) {
        do {
            let request = try await coordinator.redeem(authorization)
            return (request, nil)
        } catch let error as AgentTerminalMutationError {
            return (nil, error)
        } catch {
            return (nil, nil)
        }
    }

    // MARK: - 基本状态机（§17）

    func testRegisterStartsAwaitingApprovalWithZeroAuthorization() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await makePending(request: request)
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .awaitingApproval)
        // pending 状态下 claim 必败：B1 不存在任何“直接执行”入口。
        let error = await claimError(
            coordinator,
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        XCTAssertEqual(error, .approvalNotApproved)
    }

    func testDenyIsTerminalAndProducesZeroAuthorization() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await makePending(request: request)
        let denyResult = await coordinator.deny(approvalID)
        XCTAssertEqual(denyResult, .performed)
        // 终局：不可再 approve / deny、不可 claim（零授权）。
        let lateApprove = await coordinator.approve(approvalID)
        XCTAssertEqual(lateApprove, .alreadyResolved(.denied))
        let lateDeny = await coordinator.deny(approvalID)
        XCTAssertEqual(lateDeny, .alreadyResolved(.denied))
        let error = await claimError(
            coordinator,
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        XCTAssertEqual(error, .approvalAlreadyResolved)
    }

    func testCancelAfterApproveInvalidatesClaim() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        let cancelResult = await coordinator.cancelApproval(approvalID)
        XCTAssertEqual(cancelResult, .performed)
        let lateApprove = await coordinator.approve(approvalID)
        XCTAssertEqual(lateApprove, .alreadyResolved(.cancelled), "cancel 后不可再 approve")
        let error = await claimError(
            coordinator,
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        XCTAssertEqual(error, .approvalCancelled)
    }

    // MARK: - 单次 approve / 单次 claim / 单次 redeem（§34/§35）

    func testDoubleApproveIsRejected() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await makePending(request: request)
        let first = await coordinator.approve(approvalID)
        XCTAssertEqual(first, .performed)
        let second = await coordinator.approve(approvalID)
        XCTAssertEqual(second, .alreadyResolved(.approved))
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .approved)
    }

    func testDoubleClaimIsRejected() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        let expected = AgentTerminalMutationTestSupport.expectations(for: request)
        _ = try await coordinator.claimExecution(approvalID: approvalID, expected: expected)
        let error = await claimError(coordinator, approvalID: approvalID, expected: expected)
        XCTAssertEqual(error, .approvalAlreadyConsumed, "第二次 claim 必须失败")
    }

    func testDoubleRedeemIsRejected() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        let firstRedeem = await redeemError(coordinator, authorization)
        XCTAssertNil(firstRedeem.error)
        XCTAssertEqual(firstRedeem.request, request, "redeem 返回冻结的原 request")
        let secondRedeem = await redeemError(coordinator, authorization)
        XCTAssertNil(secondRedeem.request)
        XCTAssertEqual(secondRedeem.error, .approvalAlreadyConsumed, "第二次 redeem 必须失败")
    }

    func testForgedAuthorizationIsRejectedAsStale() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        // 自行拼装的 permit 不在账本内 → approvalStale（构造控制 + 状态校验双保险）。
        let forged = AgentTerminalMutationExecutionAuthorization(
            approvalID: approvalID,
            generationID: request.generationID,
            callID: request.callID,
            logicalSessionID: request.logicalSessionID,
            targetIdentity: request.targetIdentity,
            request: request,
            permit: UUID()
        )
        let result = await redeemError(coordinator, forged)
        XCTAssertNil(result.request)
        XCTAssertEqual(result.error, .approvalStale)
    }

    // MARK: - Replay（§36）

    func testReplayAfterFullConsumptionIsRejected() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await makePending(request: request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        _ = try await coordinator.redeem(authorization)

        // 同一 request identity 重放：
        // - register 幂等 → 返回既有 approvalID，绝不产生第二个审批；
        // - late approve → alreadyResolved（终态 redeemed）；
        // - claim / redeem → approvalAlreadyConsumed。
        let replayID = await coordinator.register(request)
        XCTAssertEqual(replayID, approvalID, "同 (generation, callID) 重放不得新建审批")
        let lateApprove = await coordinator.approve(replayID)
        XCTAssertEqual(lateApprove, .alreadyResolved(.redeemed))
        let claimErr = await claimError(
            coordinator,
            approvalID: replayID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        XCTAssertEqual(claimErr, .approvalAlreadyConsumed)
        let redeemAgain = await redeemError(coordinator, authorization)
        XCTAssertEqual(redeemAgain.error, .approvalAlreadyConsumed)
        let snapshot = try await snapshotOf(coordinator, replayID)
        XCTAssertEqual(snapshot.state, .redeemed)
        let pending = await coordinator.pendingApprovalCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - 绑定矩阵（§19/§49：逐字段 mismatch 必败）

    func testClaimMismatchGenerationFails() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        let expected = AgentTerminalMutationClaimExpectations(
            generationID: UUID(),
            logicalSessionID: request.logicalSessionID,
            providerSnapshotID: request.providerBinding.snapshotID,
            inputTargetEpoch: request.targetIdentity.inputTargetEpoch,
            endpointToken: request.targetIdentity.endpointToken
        )
        let error = await claimError(coordinator, approvalID: approvalID, expected: expected)
        XCTAssertEqual(error, .bindingMismatch)
    }

    func testClaimMismatchLogicalSessionFails() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        let expected = AgentTerminalMutationClaimExpectations(
            generationID: request.generationID,
            logicalSessionID: UUID(),
            providerSnapshotID: request.providerBinding.snapshotID,
            inputTargetEpoch: request.targetIdentity.inputTargetEpoch,
            endpointToken: request.targetIdentity.endpointToken
        )
        let error = await claimError(coordinator, approvalID: approvalID, expected: expected)
        XCTAssertEqual(error, .bindingMismatch)
    }

    func testClaimMismatchProviderSnapshotFails() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        // Provider B 快照身份不得消费 Provider A 的审批（§25）。
        let providerB = AgentCommandProviderBinding(
            snapshotID: UUID(),
            provider: .deepSeek,
            model: "other-model",
            baseURL: URL(string: "https://other.example.invalid")!
        )
        let expected = AgentTerminalMutationClaimExpectations(
            generationID: request.generationID,
            logicalSessionID: request.logicalSessionID,
            providerSnapshotID: providerB.snapshotID,
            inputTargetEpoch: request.targetIdentity.inputTargetEpoch,
            endpointToken: request.targetIdentity.endpointToken
        )
        let error = await claimError(coordinator, approvalID: approvalID, expected: expected)
        XCTAssertEqual(error, .bindingMismatch)
    }

    func testClaimMismatchEpochAndTokenYieldTargetReplaced() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        // epoch 不匹配（同 session 新 epoch）→ targetReplaced。
        let epochMismatch = AgentTerminalMutationClaimExpectations(
            generationID: request.generationID,
            logicalSessionID: request.logicalSessionID,
            providerSnapshotID: request.providerBinding.snapshotID,
            inputTargetEpoch: request.targetIdentity.inputTargetEpoch + 1,
            endpointToken: request.targetIdentity.endpointToken
        )
        let epochError = await claimError(
            coordinator, approvalID: approvalID, expected: epochMismatch
        )
        XCTAssertEqual(epochError, .targetReplaced)
        // token 不匹配（同 session 同 epoch 新 token）→ targetReplaced。
        let tokenMismatch = AgentTerminalMutationClaimExpectations(
            generationID: request.generationID,
            logicalSessionID: request.logicalSessionID,
            providerSnapshotID: request.providerBinding.snapshotID,
            inputTargetEpoch: request.targetIdentity.inputTargetEpoch,
            endpointToken: AgentTerminalEndpointToken.generate()
        )
        let tokenError = await claimError(
            coordinator, approvalID: approvalID, expected: tokenMismatch
        )
        XCTAssertEqual(tokenError, .targetReplaced)
        // 两次失败都不消耗审批：正确期望仍可 claim。
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        XCTAssertEqual(authorization.request, request)
    }

    // MARK: - Incarnation 矩阵（§50；纯确定性 domain 测试，无真实重连）

    func testIncarnationMatrix() async throws {
        let sessionA = UUID()
        let token1 = AgentTerminalEndpointToken.generate()
        let token2 = AgentTerminalEndpointToken.generate()

        // 1. 同 session / 同 epoch / 同 token → eligible。
        do {
            let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
                sessionID: sessionA, epoch: 3, token: token1
            )
            let (coordinator, approvalID) = await approvedCoordinator(for: request)
            let error = await claimError(
                coordinator,
                approvalID: approvalID,
                expected: AgentTerminalMutationTestSupport.expectations(for: request)
            )
            XCTAssertNil(error, "完全一致的 incarnation 必须可 claim")
        }

        // 2. 同 session / 新 epoch → targetReplaced。
        do {
            let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
                sessionID: sessionA, epoch: 3, token: token1
            )
            let (coordinator, approvalID) = await approvedCoordinator(for: request)
            let error = await claimError(
                coordinator,
                approvalID: approvalID,
                expected: AgentTerminalMutationTestSupport.expectations(
                    sessionID: sessionA, epoch: 4, token: token1
                )
            )
            XCTAssertEqual(error, .targetReplaced, "同 session 新 epoch = targetReplaced")
        }

        // 3. 同 session / 同 epoch / 新 token → targetReplaced。
        do {
            let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
                sessionID: sessionA, epoch: 3, token: token1
            )
            let (coordinator, approvalID) = await approvedCoordinator(for: request)
            let error = await claimError(
                coordinator,
                approvalID: approvalID,
                expected: AgentTerminalMutationTestSupport.expectations(
                    sessionID: sessionA, epoch: 3, token: token2
                )
            )
            XCTAssertEqual(error, .targetReplaced, "同 epoch 新 token = targetReplaced")
        }

        // 4. 不同 session / 同数值 epoch → 拒绝（sessionID 相等绝不单独授权）。
        do {
            let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
                sessionID: sessionA, epoch: 3, token: token1
            )
            let (coordinator, approvalID) = await approvedCoordinator(for: request)
            let error = await claimError(
                coordinator,
                approvalID: approvalID,
                expected: AgentTerminalMutationTestSupport.expectations(
                    sessionID: UUID(), epoch: 3, token: token1
                )
            )
            XCTAssertEqual(error, .bindingMismatch, "不同 session 必须拒绝")
        }

        // 5. 旧目标在“重连”后（建模为新 epoch）→ stale：批准于 epoch 3，
        //    claim 呈递 epoch 4 → targetReplaced（零授权，状态未消耗）。
        do {
            let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
                sessionID: sessionA, epoch: 3, token: token1
            )
            let (coordinator, approvalID) = await approvedCoordinator(for: request)
            let error = await claimError(
                coordinator,
                approvalID: approvalID,
                expected: AgentTerminalMutationTestSupport.expectations(
                    sessionID: sessionA, epoch: 4, token: token1
                )
            )
            XCTAssertEqual(error, .targetReplaced, "重连后旧审批 deterministic stale")
            let snapshot = try await snapshotOf(coordinator, approvalID)
            XCTAssertEqual(snapshot.state, .approved)
        }
    }

    // MARK: - Generation 替换（§24）

    func testGenerationReplacementInvalidatesOldApprovalDeterministically() async throws {
        let oldRequest = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
            generationID: UUID()
        )
        let newRequest = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
            generationID: UUID(), callID: "call-new"
        )
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let oldID = await coordinator.register(oldRequest)
        let newID = await coordinator.register(newRequest)
        // Generation A 拥有 pending mutation（此处已 approve），随后 B 替换 A：
        _ = await coordinator.approve(oldID)
        _ = await coordinator.cancelGeneration(oldRequest.generationID)

        // A 的 late approve / claim：零授权（不依赖 UI 消失）。
        let lateApprove = await coordinator.approve(oldID)
        XCTAssertEqual(lateApprove, .alreadyResolved(.cancelled))
        let claimErr = await claimError(
            coordinator,
            approvalID: oldID,
            expected: AgentTerminalMutationTestSupport.expectations(for: oldRequest)
        )
        XCTAssertEqual(claimErr, .approvalCancelled)
        // B 的审批不受影响。
        let newSnapshot = try await snapshotOf(coordinator, newID)
        XCTAssertEqual(newSnapshot.state, .awaitingApproval)
    }

    // MARK: - Claim 后 / Redeem 前的 generation 取消（§39 冻结规则）

    func testGenerationCancelAfterClaimBeforeRedeemInvalidatesAuthorization() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        // 取消已 claim 未 redeem 的授权 → 零授权（§39 冻结规则）。
        let cancelled = await coordinator.cancelGeneration(request.generationID)
        XCTAssertEqual(cancelled, 1)
        let result = await redeemError(coordinator, authorization)
        XCTAssertNil(result.request)
        XCTAssertEqual(result.error, .approvalStale)
    }

    func testRedeemCompletingBeforeGenerationCancelIsTerminal() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await approvedCoordinator(for: request)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        _ = try await coordinator.redeem(authorization)
        // redeem 已完成（终态 redeemed）：generation 取消不再影响。
        let cancelled = await coordinator.cancelGeneration(request.generationID)
        XCTAssertEqual(cancelled, 0, "redeemed 为终态，不可再取消")
        let snapshot = try await snapshotOf(coordinator, approvalID)
        XCTAssertEqual(snapshot.state, .redeemed)
    }

    // MARK: - callID 绑定（§26）

    func testIdenticalTextWithDifferentCallIDsAreDistinctMutations() async throws {
        // call A 与 call B 文本完全相同，仍然是两次不同 mutation：
        // A 的审批永远不能授权 B。
        let requestA = try AgentTerminalMutationTestSupport.makeRequestOrThrow(callID: "call-A")
        let requestB = try AgentTerminalMutationTestSupport.makeRequestOrThrow(callID: "call-B")
        XCTAssertNotEqual(requestA, requestB)
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let idA = await coordinator.register(requestA)
        let idB = await coordinator.register(requestB)
        XCTAssertNotEqual(idA, idB)
        _ = await coordinator.approve(idA)
        let authorizationA = try await coordinator.claimExecution(
            approvalID: idA,
            expected: AgentTerminalMutationTestSupport.expectations(for: requestA)
        )
        let redeemA = await redeemError(coordinator, authorizationA)
        XCTAssertNil(redeemA.error, "A 的授权对 A 自身 record redeem 应成功")
        XCTAssertEqual(redeemA.request, requestA)
        // B 未批准：不可 claim（默认 fixture 除 callID 外绑定一致，
        // 拦截点 = 状态机：A 的审批绝不产生 B 的 claim 资格）。
        let errorB = await claimError(
            coordinator,
            approvalID: idB,
            expected: AgentTerminalMutationTestSupport.expectations(for: requestA)
        )
        XCTAssertEqual(errorB, .approvalNotApproved, "B 未批准不可 claim")
        // 结构性证明：即使 B 后来被批准并 claim，A 的 authorization
        // 仍只指向 A 的 record——绝不返回 B 的 request。
        _ = await coordinator.approve(idB)
        let authorizationB = try await coordinator.claimExecution(
            approvalID: idB,
            expected: AgentTerminalMutationTestSupport.expectations(for: requestB)
        )
        XCTAssertNotEqual(authorizationA, authorizationB)
        let redeemAAgain = await redeemError(coordinator, authorizationA)
        XCTAssertEqual(redeemAAgain.error, .approvalAlreadyConsumed)
        XCTAssertNotEqual(redeemAAgain.request, requestB)
        let snapshotB = try await snapshotOf(coordinator, idB)
        XCTAssertEqual(snapshotB.state, .executionClaimed)
    }

    // MARK: - submit 绑定（§27）

    func testSubmitMismatchIsADifferentRequestAndNeverCrossAuthorized() async throws {
        let pasteOnly = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
            callID: "call-paste", submit: false
        )
        let withSubmit = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
            callID: "call-submit", submit: true
        )
        XCTAssertNotEqual(pasteOnly, withSubmit, "{text, submit:false} ≠ {text, submit:true}")
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let idPaste = await coordinator.register(pasteOnly)
        let idSubmit = await coordinator.register(withSubmit)
        _ = await coordinator.approve(idPaste)
        let authorization = try await coordinator.claimExecution(
            approvalID: idPaste,
            expected: AgentTerminalMutationTestSupport.expectations(for: pasteOnly)
        )
        let redeemResult = await redeemError(coordinator, authorization)
        XCTAssertEqual(redeemResult.request?.submit, false, "redeem 保持 exact submit=false")
        XCTAssertEqual(redeemResult.request, pasteOnly)
        XCTAssertNotEqual(redeemResult.request, withSubmit)
        // submit=true 的请求仍是独立未批准 mutation。
        let snapshotSubmit = try await snapshotOf(coordinator, idSubmit)
        XCTAssertEqual(snapshotSubmit.state, .awaitingApproval)
    }

    // MARK: - Exact UTF-8 绑定（§28）

    func testExactUTF8PayloadBindingAcrossScriptClasses() async throws {
        let cases: [String] = [
            "echo hi",                 // ASCII
            "echo 中文测试",            // Chinese
            "echo 😀🚀",               // Emoji
            "echo e\u{0301}combining", // 组合序列（decomposed）
            "line1\nline2\nline3",     // multiline
        ]
        for (index, text) in cases.enumerated() {
            let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
                callID: "call-\(index)", text: text, submit: false
            )
            let (coordinator, approvalID) = await approvedCoordinator(for: request)
            let authorization = try await coordinator.claimExecution(
                approvalID: approvalID,
                expected: AgentTerminalMutationTestSupport.expectations(for: request)
            )
            let redeemResult = await redeemError(coordinator, authorization)
            XCTAssertEqual(redeemResult.request?.text, text, "exact payload 原样绑定（无隐藏 normalization）")
            XCTAssertEqual(redeemResult.request.map { Array($0.text.utf8) }, Array(text.utf8), "逐字节一致")
        }
    }

    // MARK: - 跨 request 混淆（§37）

    func testCrossRequestConfusionNeverCrossesAuthorization() async throws {
        let requestA = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
            callID: "call-A", text: "echo A", submit: true
        )
        let requestB = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
            generationID: UUID(), callID: "call-B", sessionID: UUID(),
            epoch: 9,
            token: AgentTerminalEndpointToken.generate(),
            targetSnapshot: .remote(hostDisplay: "other-host"),
            text: "echo B", submit: false
        )
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let idA = await coordinator.register(requestA)
        let idB = await coordinator.register(requestB)
        // 只批准 A。
        _ = await coordinator.approve(idA)
        let authorizationA = try await coordinator.claimExecution(
            approvalID: idA,
            expected: AgentTerminalMutationTestSupport.expectations(for: requestA)
        )
        // B 呈递 A 的 generation / session / provider / epoch / token → bindingMismatch。
        let crossError = await claimError(
            coordinator,
            approvalID: idB,
            expected: AgentTerminalMutationTestSupport.expectations(for: requestA)
        )
        XCTAssertEqual(crossError, .bindingMismatch, "B 不得用 A 的绑定身份 claim")
        // A 的 authorization redeem 只返回 A 的冻结 request。
        let redeemResult = await redeemError(coordinator, authorizationA)
        XCTAssertEqual(redeemResult.request, requestA)
        XCTAssertNotEqual(redeemResult.request, requestB)
        // B 仍处于未批准状态，零授权。
        let snapshotB = try await snapshotOf(coordinator, idB)
        XCTAssertEqual(snapshotB.state, .awaitingApproval)
    }

    // MARK: - awaitDecision（waiter exactly-once）

    func testAwaitDecisionResolvesExactlyOncePerState() async throws {
        // decision-before-wait：立即返回。
        do {
            let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
            let (coordinator, approvalID) = await makePending(request: request)
            _ = await coordinator.deny(approvalID)
            let resolution = try await coordinator.awaitDecision(approvalID: approvalID)
            XCTAssertEqual(resolution, .denied)
        }
        // wait-before-decision：决策恢复全部 waiter，各恰好一次。
        do {
            let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
            let (coordinator, approvalID) = await makePending(request: request)
            async let first = coordinator.awaitDecision(approvalID: approvalID)
            async let second = coordinator.awaitDecision(approvalID: approvalID)
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = await coordinator.approve(approvalID)
            let resolutions = try await [first, second]
            XCTAssertEqual(resolutions, [.approved, .approved])
        }
    }

    func testWaiterTaskCancellationDoesNotCancelApproval() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let (coordinator, approvalID) = await makePending(request: request)
        let waiterTask = Task {
            try await coordinator.awaitDecision(approvalID: approvalID)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiterTask.cancel()
        do {
            _ = try await waiterTask.value
            XCTFail("被取消的 waiter 应抛 CancellationError")
        } catch is CancellationError {
            // 预期路径。
        }
        // approval 不受 waiter 取消影响：仍可正常 approve → claim。
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        XCTAssertEqual(authorization.request, request)
    }
}
