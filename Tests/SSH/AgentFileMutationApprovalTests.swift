import Foundation
import XCTest

@testable import MacSSH

/// C1 one-time approval/claim/redeem tests；每一个 permit 都只代表 future C2 的机会。
final class AgentFileMutationApprovalTests: XCTestCase {
    /// decision-before-wait 必须立即返回已落定的 approval，不得悬挂或重复
    /// 创建 permit；三种终态都只能从 coordinator 账本读取。
    func testAwaitDecisionReturnsAlreadyResolvedDecisionImmediately() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let approvedRequest = try await AgentFileMutationTestSupport.makeRequest(
            root: root, path: "approved.txt", callID: "await-approved"
        )
        let approvedCoordinator = AgentFileMutationApprovalCoordinator()
        let approvedID = await approvedCoordinator.register(approvedRequest)
        _ = await approvedCoordinator.approve(approvedID)
        let approvedDecision = try await approvedCoordinator.awaitDecision(approvalID: approvedID)
        XCTAssertEqual(approvedDecision, .approved)

        let deniedRequest = try await AgentFileMutationTestSupport.makeRequest(
            root: root, path: "denied.txt", callID: "await-denied"
        )
        let deniedCoordinator = AgentFileMutationApprovalCoordinator()
        let deniedID = await deniedCoordinator.register(deniedRequest)
        _ = await deniedCoordinator.deny(deniedID)
        let deniedDecision = try await deniedCoordinator.awaitDecision(approvalID: deniedID)
        XCTAssertEqual(deniedDecision, .denied)

        let cancelledRequest = try await AgentFileMutationTestSupport.makeRequest(
            root: root, path: "cancelled.txt", callID: "await-cancelled"
        )
        let cancelledCoordinator = AgentFileMutationApprovalCoordinator()
        let cancelledID = await cancelledCoordinator.register(cancelledRequest)
        _ = await cancelledCoordinator.cancelApproval(cancelledID)
        let cancelledDecision = try await cancelledCoordinator.awaitDecision(approvalID: cancelledID)
        XCTAssertEqual(cancelledDecision, .cancelled)
    }

    /// waiter 先挂起、再 approve 时只能恢复一次；取消 waiter 只取消等待本身，
    /// 不会把 proposal 偷改成 approved 或自动取得 execution authorization。
    func testAwaitDecisionResumesOnceAndWaiterCancellationIsNotApproval() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root, path: "waited.txt", callID: "await-race"
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)

        let waiter = Task {
            try await coordinator.awaitDecision(approvalID: approvalID)
        }
        await Task.yield()
        _ = await coordinator.approve(approvalID)
        let waiterDecision = try await waiter.value
        XCTAssertEqual(waiterDecision, .approved)
        let approvalState = await coordinator.snapshot(approvalID: approvalID)?.state
        XCTAssertEqual(approvalState, .approved)

        let cancelledRequest = try await AgentFileMutationTestSupport.makeRequest(
            root: root, path: "waiter-cancelled.txt", callID: "await-cancelled-waiter"
        )
        let cancelledCoordinator = AgentFileMutationApprovalCoordinator()
        let cancelledID = await cancelledCoordinator.register(cancelledRequest)
        let cancelledWaiter = Task {
            () -> Result<AgentFileMutationApprovalResolution, Error> in
            do {
                return .success(try await cancelledCoordinator.awaitDecision(approvalID: cancelledID))
            } catch {
                return .failure(error)
            }
        }
        await Task.yield()
        cancelledWaiter.cancel()
        let cancellationResult = await cancelledWaiter.value
        if case .success = cancellationResult {
            XCTFail("取消 waiter 不得得到 approval decision")
        }
        let cancelledState = await cancelledCoordinator.snapshot(approvalID: cancelledID)?.state
        XCTAssertEqual(cancelledState, .awaitingApproval)
        _ = await cancelledCoordinator.cancelApproval(cancelledID)
    }

    /// approve → claim → redeem 返回 coordinator 保存的同一 immutable proposal，且不创建文件。
    func testExplicitApprovalClaimsAndRedeemsExactRequestOnce() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let request = try await AgentFileMutationTestSupport.makeRequest(root: root, content: "末尾无换行")
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)

        let approvalResult = await coordinator.approve(approvalID)
        XCTAssertEqual(approvalResult, .performed)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )
        let redeemed = try await coordinator.redeem(authorization)

        XCTAssertEqual(redeemed.payloadUTF8, Data("末尾无换行".utf8))
        XCTAssertEqual(redeemed.payloadIdentity, request.payloadIdentity)
        XCTAssertEqual(redeemed.targetIdentity, request.targetIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: redeemed.displayPath))
        do {
            _ = try await coordinator.redeem(authorization)
            XCTFail("同一 authorization 第二次 redeem 必须失败")
        } catch let error as AgentFileMutationError {
            XCTAssertEqual(error, .approvalAlreadyConsumed)
        }
        await coordinator.purgeGeneration(request.generationID)
    }

    /// deny 和 generation cancellation 都应关闭 parent capability，且不给任何 permit。
    func testDenyAndGenerationCancellationInvalidateCapability() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let deniedRequest = try await AgentFileMutationTestSupport.makeRequest(root: root, path: "denied.txt")
        let deniedCoordinator = AgentFileMutationApprovalCoordinator()
        let deniedID = await deniedCoordinator.register(deniedRequest)
        let denialResult = await deniedCoordinator.deny(deniedID)
        let deniedCapabilityOpen = await deniedRequest.parentCapability.isOpen()
        XCTAssertEqual(denialResult, .performed)
        XCTAssertFalse(deniedCapabilityOpen)
        do {
            _ = try await deniedCoordinator.claimExecution(
                approvalID: deniedID,
                expected: AgentFileMutationTestSupport.expectations(for: deniedRequest)
            )
            XCTFail("deny 后不可 claim")
        } catch let error as AgentFileMutationError {
            XCTAssertEqual(error, .userDenied)
        }

        let cancelledRequest = try await AgentFileMutationTestSupport.makeRequest(root: root, path: "cancelled.txt", callID: "cancelled")
        let cancelledCoordinator = AgentFileMutationApprovalCoordinator()
        let cancelledID = await cancelledCoordinator.register(cancelledRequest)
        let cancellationApproval = await cancelledCoordinator.approve(cancelledID)
        let cancelledCount = await cancelledCoordinator.cancelGeneration(cancelledRequest.generationID)
        let cancelledCapabilityOpen = await cancelledRequest.parentCapability.isOpen()
        XCTAssertEqual(cancellationApproval, .performed)
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertFalse(cancelledCapabilityOpen)
        do {
            _ = try await cancelledCoordinator.claimExecution(
                approvalID: cancelledID,
                expected: AgentFileMutationTestSupport.expectations(for: cancelledRequest)
            )
            XCTFail("generation cancel 后不可 claim")
        } catch let error as AgentFileMutationError {
            XCTAssertEqual(error, .generationCancelled)
        }
    }

    /// tab/session B 的 stale binding 不得 fallback 到 A；只有原 session A 能继续消费自己的 permit。
    func testClaimRejectsStaleBinding() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let request = try await AgentFileMutationTestSupport.makeRequest(root: root)
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let original = AgentFileMutationTestSupport.expectations(for: request)
        let stale = AgentFileMutationClaimExpectations(
            generationID: original.generationID,
            callID: original.callID,
            logicalSessionID: UUID(),
            providerSnapshotID: original.providerSnapshotID,
            targetIdentity: original.targetIdentity
        )

        do {
            _ = try await coordinator.claimExecution(approvalID: approvalID, expected: stale)
            XCTFail("stale logical session 不得取得 claim")
        } catch let error as AgentFileMutationError {
            XCTAssertEqual(error, .bindingMismatch)
        }
        let validAuthorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: original
        )
        let redeemed = try await coordinator.redeem(validAuthorization)
        XCTAssertEqual(redeemed.logicalSessionID, request.logicalSessionID)
        XCTAssertEqual(redeemed.targetIdentity.logicalSessionID, request.logicalSessionID)
        await coordinator.purgeGeneration(request.generationID)
    }

    /// proposal 后即使终端当前 CWD 改为 B，approval/redeem 仍只返回从 A 捕获的 capability/target。
    func testApprovalRedeemPreservesProposalWorkingDirectoryAfterCWDChanges() async throws {
        let rootA = try AgentFileMutationTestSupport.makeTemporaryRoot()
        let rootB = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer {
            AgentFileMutationTestSupport.removeTemporaryRoot(rootA)
            AgentFileMutationTestSupport.removeTemporaryRoot(rootB)
        }
        let request = try await AgentFileMutationTestSupport.makeRequest(root: rootA, path: "from-a.txt")
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)

        // 此变量仅模拟随后终端报告的 CWD B；C1 不读取 active/current terminal state。
        let laterWorkingDirectory = try AgentFileMutationTestSupport.canonicalPathForAssertion(rootB.path)
        XCTAssertNotEqual(request.proposalWorkingDirectory, laterWorkingDirectory)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )
        let redeemed = try await coordinator.redeem(authorization)

        XCTAssertEqual(redeemed.proposalWorkingDirectory, request.proposalWorkingDirectory)
        XCTAssertEqual(redeemed.targetIdentity.basename, "from-a.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootB.appendingPathComponent("from-a.txt").path))
        await coordinator.purgeGeneration(request.generationID)
    }

    /// 已 claim 的 proposal 在 session teardown 前 redeem 时必须失效并关闭 parent capability。
    func testSessionCancellationInvalidatesClaimedAuthorizationBeforeRedeem() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let sessionID = UUID()
        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "session-cancelled.txt",
            sessionID: sessionID
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )

        let cancelledCount = await coordinator.cancelSession(sessionID)
        let capabilityOpen = await request.parentCapability.isOpen()
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertFalse(capabilityOpen)
        do {
            _ = try await coordinator.redeem(authorization)
            XCTFail("session cancellation 后不得 redeem")
        } catch let error as AgentFileMutationError {
            XCTAssertEqual(error, .targetStale)
        }
    }

    /// 50 并发 claim 的线性化点在 actor 内，恰好一个 authorization 获胜。
    func testFiftyConcurrentClaimsHaveExactlyOneWinner() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let request = try await AgentFileMutationTestSupport.makeRequest(root: root)
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let expected = AgentFileMutationTestSupport.expectations(for: request)

        let results = await withTaskGroup(of: Result<AgentFileMutationExecutionAuthorization, AgentFileMutationError>.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    do {
                        return .success(try await coordinator.claimExecution(approvalID: approvalID, expected: expected))
                    } catch let error as AgentFileMutationError {
                        return .failure(error)
                    } catch {
                        return .failure(.targetStale)
                    }
                }
            }
            var collected: [Result<AgentFileMutationExecutionAuthorization, AgentFileMutationError>] = []
            for await result in group { collected.append(result) }
            return collected
        }

        let authorizations = results.compactMap { try? $0.get() }
        let errors = results.compactMap { result -> AgentFileMutationError? in
            if case let .failure(error) = result { return error }
            return nil
        }
        XCTAssertEqual(authorizations.count, 1)
        XCTAssertEqual(errors.count, 49)
        XCTAssertTrue(errors.allSatisfy { $0 == .approvalAlreadyClaimed })
        await coordinator.purgeGeneration(request.generationID)
    }

    /// sequential/copy/concurrent/multi-consumer replay 都不能得到第二个 redeem permit。
    func testReplayProtectionHasExactlyOneRedeemWinnerAcrossConsumers() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let request = try await AgentFileMutationTestSupport.makeRequest(root: root)
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )
        let copiedAuthorization = authorization

        let results = await withTaskGroup(of: Result<AgentFileMutationRequest, AgentFileMutationError>.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    do {
                        return .success(try await coordinator.redeem(copiedAuthorization))
                    } catch let error as AgentFileMutationError {
                        return .failure(error)
                    } catch {
                        return .failure(.targetStale)
                    }
                }
            }
            var collected: [Result<AgentFileMutationRequest, AgentFileMutationError>] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.compactMap { try? $0.get() }.count, 1)
        XCTAssertEqual(
            results.compactMap { result -> AgentFileMutationError? in
                if case let .failure(error) = result { return error }
                return nil
            }.filter { $0 == .approvalAlreadyConsumed }.count,
            49
        )

        let otherCoordinator = AgentFileMutationApprovalCoordinator()
        do {
            _ = try await otherCoordinator.redeem(authorization)
            XCTFail("不同 consumer/coordinator 不认识该 permit")
        } catch let error as AgentFileMutationError {
            XCTAssertEqual(error, .targetStale)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.displayPath))
        await coordinator.purgeGeneration(request.generationID)
    }
}
