import Foundation

// MARK: - Approval Coordinator（任务书 §33/§34）

/// 审批状态机的**唯一 authority**（§33/§35）。
///
/// `actor` 隔离统一串行化全部竞争操作（§34）：approve / deny /
/// cancelApproval / Stop（cancelGeneration）/ session close
/// （cancelSession）/ claim / 双击 / waiter 注册与恢复。散落在
/// `@MainActor Bool` 上的审批状态绝不构成安全边界——UI 只能读
/// snapshot（§69），`card.status == approved` 绝不触发任何执行（§35）。
///
/// 记录 **memory-only**（§58）：绝不落任何存储 / 偏好 / 文件通道。
/// lifecycle 归属：generation 拥有 approval 生命周期（§86），
/// Stop / generation 替换 / conversation-teardown 走 `cancelGeneration`
/// / `purgeGeneration`；session close 走 `cancelSession` / `purgeSession`
/// （§39–§41）。
///
/// 决策等待语义（§36–§38）：允许同一 approval 的多个 waiter，每个
/// waiter **恰好恢复一次**并得到同一 resolution；决策已落定后再 wait
/// 立即返回已存解析（§82）。waiter 自身 Task 取消 ≠ 取消 approval
/// （§86：只摘除该 waiter，不产生任何执行授权，无 orphan continuation）。
actor AgentCommandApprovalCoordinator {
    /// 决策 waiter（§37：resume exactly once）。
    private struct DecisionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<AgentCommandApprovalResolution, Error>
    }

    /// 内部账本条目（§70：状态只在本 actor 内可变）。
    private struct Record {
        let id: UUID
        let request: AgentCommandRequest
        var state: AgentCommandApprovalState
        /// claim 成功时生成的单次消费凭据（§32）。
        var permit: UUID?
        /// redeem 是否已消费（§31/§32 单次消费语义）。
        var redeemed: Bool
        /// 登记 / 快照排序用的单调序号。
        let order: Int
    }

    private var records: [UUID: Record] = [:]
    private var waiters: [UUID: [DecisionWaiter]] = [:]
    private var orderCounter = 0

    // MARK: - 创建（任务书 §18/§20）

    /// 登记一条 pending approval（初始 `awaitingApproval`，§20：此刻
    /// 不存在任何执行授权）。
    ///
    /// 同一 `(generationID, callID)` 幂等（10E-A §109 duplicate call_id
    /// 防线）：重复登记返回既有 approvalID，**绝不产生第二个审批**。
    @discardableResult
    func register(_ request: AgentCommandRequest) async -> UUID {
        if let existing = records.values.first(where: {
            $0.request.generationID == request.generationID
                && $0.request.callID == request.callID
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
            redeemed: false,
            order: orderCounter
        )
        return id
    }

    // MARK: - 用户决策（任务书 §21/§22/§27/§28）

    /// `awaitingApproval → approved`。approve 本身**不执行任何命令**
    /// （§21），只授予一次未来 execution claim 的资格。
    /// 双击竞态下恰好一次 `performed`（§28），败者 `alreadyResolved`。
    func approve(_ approvalID: UUID) async -> AgentCommandApprovalActionResult {
        transition(approvalID, to: .approved)
    }

    /// `awaitingApproval → denied`（userDenied 语义，§22/§60）。
    func deny(_ approvalID: UUID) async -> AgentCommandApprovalActionResult {
        transition(approvalID, to: .denied)
    }

    /// 单条取消：`awaitingApproval | approved → cancelled`
    /// （approved 未 claim 仍可被 Stop 失效，§30）。已 claim 的 approval
    /// 不可经审批路径撤销（§73：claim 之后属于未来 executor 取消语义）。
    @discardableResult
    func cancelApproval(_ approvalID: UUID) async -> AgentCommandApprovalActionResult {
        guard var record = records[approvalID] else { return .notFound }
        switch record.state {
        case .awaitingApproval, .approved:
            record.state = .cancelled
            records[approvalID] = record
            resumeWaiters(approvalID: approvalID, resolution: .cancelled)
            return .performed
        case .denied, .cancelled, .executionClaimed:
            return .alreadyResolved(record.state)
        }
    }

    // MARK: - 批量失效 / 清理（任务书 §23/§39–§41）

    /// 失效某 generation 的全部 pending approval（Stop / generation
    /// 替换）。返回失效条数。已终态（denied / cancelled /
    /// executionClaimed）的记录不动。
    @discardableResult
    func cancelGeneration(_ generationID: UUID) async -> Int {
        cancelPending(where: { $0.request.generationID == generationID })
    }

    /// 失效某 session 的全部 pending approval（session close，§41）。
    @discardableResult
    func cancelSession(_ sessionID: UUID) async -> Int {
        cancelPending(where: { $0.request.sessionID == sessionID })
    }

    /// 清除某 generation 的全部记录（conversation teardown；§39：
    /// resolved 记录不永久积累）。仍有 waiter 的 pending 记录先以
    /// cancelled 恢复，绝不泄漏 continuation（§37）。返回清除条数。
    @discardableResult
    func purgeGeneration(_ generationID: UUID) async -> Int {
        purge(where: { $0.request.generationID == generationID })
    }

    /// 清除某 session 的全部记录（session teardown）。
    @discardableResult
    func purgeSession(_ sessionID: UUID) async -> Int {
        purge(where: { $0.request.sessionID == sessionID })
    }

    // MARK: - 单次执行授权（任务书 §29–§32/§74–§80）

    /// 原子 claim：`approved → executionClaimed`，返回一次性授权。
    ///
    /// 检查顺序：存在性 → 绑定一致性（§78–§80）→ 状态。
    /// - 绑定不一致 → `bindingMismatch`；
    /// - `awaitingApproval` → `approvalNotApproved`（§75）；
    /// - `denied` → `approvalAlreadyResolved`；
    /// - `cancelled` → `approvalCancelled`（§30/§77：Stop after approve
    ///   使 claim 失败——10E-A 冻结的 Stop 安全门）；
    /// - `executionClaimed` → `approvalAlreadyClaimed`（§74：只有第一次
    ///   claim 成功）。
    ///
    /// 返回的 authorization 携带 coordinator 保存的 immutable request
    /// （§43/§44/§45）；调用方绝不重传 command / cwd / session。
    func claimExecution(
        approvalID: UUID,
        expected: AgentCommandClaimExpectations
    ) async throws -> AgentCommandExecutionAuthorization {
        guard var record = records[approvalID] else {
            throw AgentCommandError.approvalNotFound
        }
        guard
            record.request.generationID == expected.generationID,
            record.request.sessionID == expected.sessionID,
            record.request.providerBinding.snapshotID == expected.providerSnapshotID
        else {
            throw AgentCommandError.bindingMismatch
        }
        switch record.state {
        case .awaitingApproval:
            throw AgentCommandError.approvalNotApproved
        case .denied:
            throw AgentCommandError.approvalAlreadyResolved
        case .cancelled:
            throw AgentCommandError.approvalCancelled
        case .executionClaimed:
            throw AgentCommandError.approvalAlreadyClaimed
        case .approved:
            let permit = UUID()
            record.state = .executionClaimed
            record.permit = permit
            records[approvalID] = record
            return AgentCommandExecutionAuthorization(
                approvalID: record.id,
                generationID: record.request.generationID,
                callID: record.request.callID,
                sessionID: record.request.sessionID,
                request: record.request,
                permit: permit
            )
        }
    }

    /// 消费一次性授权（§32 单次消费语义）：首次返回 coordinator 保存的
    /// 原 request；permit 不匹配 → `approvalStale`；重复消费 →
    /// `approvalAlreadyClaimed`。
    func redeem(
        _ authorization: AgentCommandExecutionAuthorization
    ) async throws -> AgentCommandRequest {
        guard var record = records[authorization.approvalID] else {
            throw AgentCommandError.approvalStale
        }
        guard
            record.state == .executionClaimed,
            record.permit == authorization.permit
        else {
            throw AgentCommandError.approvalStale
        }
        guard !record.redeemed else {
            throw AgentCommandError.approvalAlreadyClaimed
        }
        record.redeemed = true
        records[authorization.approvalID] = record
        return record.request
    }

    // MARK: - 读取（任务书 §69）

    /// 单条 read-only 快照（不存在返回 nil）。
    func snapshot(approvalID: UUID) async -> AgentCommandApprovalSnapshot? {
        records[approvalID].map { AgentCommandApprovalSnapshot(
            id: $0.id, request: $0.request, state: $0.state
        ) }
    }

    /// 某 generation 的全部快照（按登记序，确定性问题排查友好）。
    func snapshots(generationID: UUID) async -> [AgentCommandApprovalSnapshot] {
        records.values
            .filter { $0.request.generationID == generationID }
            .sorted { $0.order < $1.order }
            .map { AgentCommandApprovalSnapshot(
                id: $0.id, request: $0.request, state: $0.state
            ) }
    }

    // MARK: - 决策等待（任务书 §36–§38/§82–§86）

    /// 等待决策。决策先于等待 → 立即返回已存解析（§82）；等待先于
    /// 决策 → 恢复一次（§83/§84/§85）。denied → `.denied`；
    /// cancelled → `.cancelled`；approved / executionClaimed → `.approved`。
    ///
    /// waiter Task 自身被取消 → 抛 `CancellationError`，approval 状态
    /// 不变、不自动批准、不产生执行授权（§86；lifecycle 归 generation
    /// 取消路径统一处理）。
    func awaitDecision(approvalID: UUID) async throws -> AgentCommandApprovalResolution {
        guard let record = records[approvalID] else {
            throw AgentCommandError.approvalNotFound
        }
        // decision-before-wait（§82）：立即返回，绝不悬挂。
        if let resolution = Self.resolution(of: record.state) {
            return resolution
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await self.suspendDecisionWaiter(waiterID: waiterID, approvalID: approvalID)
        }, onCancel: {
            // 只取消本 waiter（§86）：generation 路径才负责取消 approval。
            Task { await self.removeWaiter(waiterID: waiterID, approvalID: approvalID) }
        })
    }

    private func suspendDecisionWaiter(
        waiterID: UUID,
        approvalID: UUID
    ) async throws -> AgentCommandApprovalResolution {
        // fast path 与挂起点之间存在 actor 重入窗口：决策可能已落定。
        guard let record = records[approvalID] else {
            throw AgentCommandError.approvalNotFound
        }
        if let resolution = Self.resolution(of: record.state) {
            return resolution
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[approvalID, default: []].append(
                DecisionWaiter(id: waiterID, continuation: continuation)
            )
            // 竞态自愈：onCancel 触发早于登记。摘除并立即以取消恢复，
            // 保证 resume exactly once（§37）。
            if Task.isCancelled {
                removeWaiter(waiterID: waiterID, approvalID: approvalID)
            }
        }
    }

    /// 摘除指定 waiter 并以 CancellationError 恢复；不存在则 no-op
    /// （决策恢复与取消恢复互斥——双方都先从账本摘除再 resume）。
    private func removeWaiter(waiterID: UUID, approvalID: UUID) {
        guard var list = waiters[approvalID],
              let index = list.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = list.remove(at: index)
        if list.isEmpty {
            waiters[approvalID] = nil
        } else {
            waiters[approvalID] = list
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// 决策落定后恢复全部 waiter（各恰好一次，§38）。
    private func resumeWaiters(
        approvalID: UUID,
        resolution: AgentCommandApprovalResolution
    ) {
        guard let pending = waiters.removeValue(forKey: approvalID) else { return }
        for waiter in pending {
            waiter.continuation.resume(returning: resolution)
        }
    }

    // MARK: - 计数（任务书 §87 test-only introspection）

    /// pending（awaitingApproval / approved 未 claim）总数。
    /// 只暴露计数，绝不暴露 command 内容（§87）。
    func pendingApprovalCount() async -> Int {
        records.values.filter { Self.isPending($0.state) }.count
    }

    func pendingApprovalCount(generationID: UUID) async -> Int {
        records.values.filter {
            $0.request.generationID == generationID && Self.isPending($0.state)
        }.count
    }

    func pendingApprovalCount(sessionID: UUID) async -> Int {
        records.values.filter {
            $0.request.sessionID == sessionID && Self.isPending($0.state)
        }.count
    }

    // MARK: - Private

    /// 决策类转移的统一实现（actor 隔离内原子执行）。
    private func transition(
        _ approvalID: UUID,
        to newState: AgentCommandApprovalState
    ) -> AgentCommandApprovalActionResult {
        guard var record = records[approvalID] else { return .notFound }
        guard record.state == .awaitingApproval else {
            // §27/§28：败者得到 alreadyResolved，绝不二次终态转移。
            return .alreadyResolved(record.state)
        }
        record.state = newState
        records[approvalID] = record
        resumeWaiters(
            approvalID: approvalID,
            resolution: newState == .approved ? .approved : .denied
        )
        return .performed
    }

    private func cancelPending(
        where predicate: (Record) -> Bool
    ) -> Int {
        let ids = records
            .filter { predicate($0.value) && Self.isPending($0.value.state) }
            .map(\.key)
        for id in ids {
            guard var record = records[id] else { continue }
            record.state = .cancelled
            records[id] = record
            resumeWaiters(approvalID: id, resolution: .cancelled)
        }
        return ids.count
    }

    private func purge(where predicate: (Record) -> Bool) -> Int {
        let ids = records.filter { predicate($0.value) }.map(\.key)
        for id in ids {
            // pending 记录可能仍有 waiter：先以 cancelled 恢复再移除（§37）。
            resumeWaiters(approvalID: id, resolution: .cancelled)
            records[id] = nil
            waiters[id] = nil
        }
        return ids.count
    }

    private static func isPending(_ state: AgentCommandApprovalState) -> Bool {
        switch state {
        case .awaitingApproval, .approved: return true
        case .denied, .cancelled, .executionClaimed: return false
        }
    }

    private static func resolution(
        of state: AgentCommandApprovalState
    ) -> AgentCommandApprovalResolution? {
        switch state {
        case .awaitingApproval: return nil
        case .approved, .executionClaimed: return .approved
        case .denied: return .denied
        case .cancelled: return .cancelled
        }
    }
}
