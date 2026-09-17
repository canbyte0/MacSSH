import Foundation

/// Local file-mutation proposal 的 memory-only、one-time approval authority。
///
/// actor 串行化 approve/deny/cancel/claim/redeem，确保同一 request 的一个
/// claim 和一个 redeem 至多各有一个赢家。C1 只产出 immutable request permit，
/// 不包含任何文件发布、内容 I/O、Provider 注册或 UI 接线。
actor AgentFileMutationApprovalCoordinator {
    /// 请求决策的 waiter；每一个只能恢复一次。
    private struct DecisionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<AgentFileMutationApprovalResolution, Error>
    }

    /// 内部唯一可变账本。
    private struct Record {
        let id: UUID
        let request: AgentFileMutationRequest
        var state: AgentFileMutationApprovalState
        var permit: UUID?
        let order: Int
    }

    private var records: [UUID: Record] = [:]
    private var waiters: [UUID: [DecisionWaiter]] = [:]
    private var orderCounter = 0

    /// 登记 request；同一 generation/call 的重放只返回原 approval ID。
    @discardableResult
    func register(_ request: AgentFileMutationRequest) -> UUID {
        if let existing = records.values.first(where: {
            $0.request.generationID == request.generationID && $0.request.callID == request.callID
        }) {
            return existing.id
        }
        let id = UUID()
        orderCounter += 1
        records[id] = Record(
            id: id,
            request: request,
            state: .awaitingApproval,
            permit: nil,
            order: orderCounter
        )
        return id
    }

    /// 显式批准仅改变状态；不消费 descriptor，也不执行任何 side effect。
    func approve(_ approvalID: UUID) -> AgentFileMutationApprovalActionResult {
        transition(approvalID, to: .approved)
    }

    /// 显式拒绝会立即失效并关闭该 proposal 的 parent capability。
    func deny(_ approvalID: UUID) async -> AgentFileMutationApprovalActionResult {
        guard var record = records[approvalID] else { return .notFound }
        guard record.state == .awaitingApproval else { return .alreadyResolved(record.state) }
        record.state = .denied
        records[approvalID] = record
        resumeWaiters(approvalID: approvalID, resolution: .denied)
        _ = await record.request.parentCapability.invalidate()
        return .performed
    }

    /// 取消单个 pending/approved proposal；已 claim 的 permit 只可经 generation/session 失效。
    @discardableResult
    func cancelApproval(_ approvalID: UUID) async -> AgentFileMutationApprovalActionResult {
        guard var record = records[approvalID] else { return .notFound }
        switch record.state {
        case .awaitingApproval, .approved:
            record.state = .cancelled
            records[approvalID] = record
            resumeWaiters(approvalID: approvalID, resolution: .cancelled)
            _ = await record.request.parentCapability.invalidate()
            return .performed
        case .denied, .cancelled, .executionClaimed, .redeemed:
            return .alreadyResolved(record.state)
        }
    }

    /// generation cancellation 也会失效已 claim 但未 redeem 的 permit。
    @discardableResult
    func cancelGeneration(_ generationID: UUID) async -> Int {
        await cancelPending(where: { $0.request.generationID == generationID })
    }

    /// session close 不从 UI active state 寻址，只按 request 的 frozen identity 失效。
    @discardableResult
    func cancelSession(_ logicalSessionID: UUID) async -> Int {
        await cancelPending(where: { $0.request.logicalSessionID == logicalSessionID })
    }

    /// conversation teardown 清除 generation 所有记录并确定性关闭未释放 capability。
    @discardableResult
    func purgeGeneration(_ generationID: UUID) async -> Int {
        await purge(where: { $0.request.generationID == generationID })
    }

    /// session teardown 清除该 session 所有记录并确定性关闭未释放 capability。
    @discardableResult
    func purgeSession(_ logicalSessionID: UUID) async -> Int {
        await purge(where: { $0.request.logicalSessionID == logicalSessionID })
    }

    /// 原子 claim：只有 `approved` 能走到 `executionClaimed`。
    func claimExecution(
        approvalID: UUID,
        expected: AgentFileMutationClaimExpectations
    ) throws -> AgentFileMutationExecutionAuthorization {
        guard var record = records[approvalID] else {
            throw AgentFileMutationError.approvalNotFound
        }
        guard
            record.request.generationID == expected.generationID,
            record.request.callID == expected.callID,
            record.request.logicalSessionID == expected.logicalSessionID,
            record.request.providerBinding.snapshotID == expected.providerSnapshotID,
            record.request.targetIdentity == expected.targetIdentity
        else {
            throw AgentFileMutationError.bindingMismatch
        }
        switch record.state {
        case .awaitingApproval:
            throw AgentFileMutationError.approvalRequired
        case .denied:
            throw AgentFileMutationError.userDenied
        case .cancelled:
            throw AgentFileMutationError.generationCancelled
        case .executionClaimed, .redeemed:
            throw AgentFileMutationError.approvalAlreadyClaimed
        case .approved:
            let permit = UUID()
            record.state = .executionClaimed
            record.permit = permit
            records[approvalID] = record
            return AgentFileMutationExecutionAuthorization.issue(
                approvalID: approvalID,
                request: record.request,
                permit: permit
            )
        }
    }

    /// 单次消费 permit 并返回 coordinator 保存的 immutable request。
    func redeem(
        _ authorization: AgentFileMutationExecutionAuthorization
    ) throws -> AgentFileMutationRequest {
        guard var record = records[authorization.approvalID] else {
            throw AgentFileMutationError.targetStale
        }
        guard
            record.permit == authorization.permit,
            record.request.generationID == authorization.generationID,
            record.request.callID == authorization.callID,
            record.request.logicalSessionID == authorization.logicalSessionID,
            record.request.targetIdentity == authorization.targetIdentity,
            record.request.payloadIdentity == authorization.request.payloadIdentity,
            record.request.payloadUTF8 == authorization.request.payloadUTF8
        else {
            throw AgentFileMutationError.targetStale
        }
        switch record.state {
        case .executionClaimed:
            record.state = .redeemed
            records[authorization.approvalID] = record
            return record.request
        case .redeemed:
            throw AgentFileMutationError.approvalAlreadyConsumed
        case .awaitingApproval, .approved, .denied, .cancelled:
            throw AgentFileMutationError.targetStale
        }
    }

    /// 读取单条 snapshot；不存在时返回 nil。
    func snapshot(approvalID: UUID) -> AgentFileMutationApprovalSnapshot? {
        records[approvalID].map {
            AgentFileMutationApprovalSnapshot(id: $0.id, request: $0.request, state: $0.state)
        }
    }

    /// generation 内 snapshot 以登记顺序返回。
    func snapshots(generationID: UUID) -> [AgentFileMutationApprovalSnapshot] {
        records.values
            .filter { $0.request.generationID == generationID }
            .sorted { $0.order < $1.order }
            .map { AgentFileMutationApprovalSnapshot(id: $0.id, request: $0.request, state: $0.state) }
    }

    // MARK: - Decision waiting

    /// Wait for the explicit user decision. A decision that happened before
    /// the waiter is installed is returned immediately; a decision that races
    /// with suspension resumes the waiter exactly once.
    func awaitDecision(approvalID: UUID) async throws -> AgentFileMutationApprovalResolution {
        guard let record = records[approvalID] else {
            throw AgentFileMutationError.approvalNotFound
        }
        if let resolution = Self.resolution(of: record.state) {
            return resolution
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await self.suspendDecisionWaiter(
                waiterID: waiterID,
                approvalID: approvalID
            )
        }, onCancel: {
            // Cancelling the waiter does not approve or cancel the proposal;
            // generation/session lifecycle owns those state transitions.
            Task {
                await self.removeWaiter(
                    waiterID: waiterID,
                    approvalID: approvalID
                )
            }
        })
    }

    private func suspendDecisionWaiter(
        waiterID: UUID,
        approvalID: UUID
    ) async throws -> AgentFileMutationApprovalResolution {
        // Recheck after the actor suspension window: approve/deny/cancel may
        // have won before the continuation was registered.
        guard let record = records[approvalID] else {
            throw AgentFileMutationError.approvalNotFound
        }
        if let resolution = Self.resolution(of: record.state) {
            return resolution
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[approvalID, default: []].append(
                DecisionWaiter(id: waiterID, continuation: continuation)
            )
            // Cancellation can arrive before registration; remove and resume
            // with CancellationError so the continuation is resumed once.
            if Task.isCancelled {
                removeWaiter(waiterID: waiterID, approvalID: approvalID)
            }
        }
    }

    /// Remove one waiter and resume it as cancelled; a resolved waiter is a
    /// no-op because the decision path removes it first.
    private func removeWaiter(waiterID: UUID, approvalID: UUID) {
        guard var list = waiters[approvalID],
              let index = list.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = list[index]
        list = list.enumerated().compactMap { offset, value in
            offset == index ? nil : value
        }
        waiters[approvalID] = list.isEmpty ? nil : list
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// 同步且不关闭 capability 的唯一 approve 转移。
    private func transition(
        _ approvalID: UUID,
        to newState: AgentFileMutationApprovalState
    ) -> AgentFileMutationApprovalActionResult {
        guard var record = records[approvalID] else { return .notFound }
        guard record.state == .awaitingApproval else { return .alreadyResolved(record.state) }
        record.state = newState
        records[approvalID] = record
        resumeWaiters(approvalID: approvalID, resolution: .approved)
        return .performed
    }

    /// 将 matching records 先原子标记为 cancelled，再逐一关闭 capability。
    private func cancelPending(where predicate: (Record) -> Bool) async -> Int {
        let ids = records
            .filter { predicate($0.value) && Self.isCancellable($0.value.state) }
            .map(\.key)
        var capabilities: [AgentLocalFileMutationTargetCapability] = []
        for id in ids {
            guard var record = records[id] else { continue }
            record.state = .cancelled
            records[id] = record
            capabilities.append(record.request.parentCapability)
            resumeWaiters(approvalID: id, resolution: .cancelled)
        }
        for capability in capabilities {
            _ = await capability.invalidate()
        }
        return ids.count
    }

    /// purge 总会关闭其 capability，即使 record 已被 redeem。
    private func purge(where predicate: (Record) -> Bool) async -> Int {
        let ids = records.filter { predicate($0.value) }.map(\.key)
        var capabilities: [AgentLocalFileMutationTargetCapability] = []
        for id in ids {
            guard let record = records[id] else { continue }
            capabilities.append(record.request.parentCapability)
            resumeWaiters(approvalID: id, resolution: .cancelled)
            records[id] = nil
            waiters[id] = nil
        }
        for capability in capabilities {
            _ = await capability.invalidate()
        }
        return ids.count
    }

    /// awaiting/approved/claimed-but-unredeemed 是 generation/session cancellation 的对象。
    private static func isCancellable(_ state: AgentFileMutationApprovalState) -> Bool {
        switch state {
        case .awaitingApproval, .approved, .executionClaimed:
            return true
        case .denied, .cancelled, .redeemed:
            return false
        }
    }

    /// 所有 waiter 先从账本移除再恢复，避免 double resume。
    private func resumeWaiters(
        approvalID: UUID,
        resolution: AgentFileMutationApprovalResolution
    ) {
        guard let pending = waiters.removeValue(forKey: approvalID) else { return }
        for waiter in pending {
            waiter.continuation.resume(returning: resolution)
        }
    }

    private static func resolution(
        of state: AgentFileMutationApprovalState
    ) -> AgentFileMutationApprovalResolution? {
        switch state {
        case .awaitingApproval: return nil
        case .approved, .executionClaimed, .redeemed: return .approved
        case .denied: return .denied
        case .cancelled: return .cancelled
        }
    }
}
