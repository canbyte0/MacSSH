import Foundation

// MARK: - Approval Coordinator（任务书 §16/§17；语义复制已验收的 10E 状态机）

/// Terminal-mutation 专用审批状态机的**唯一 authority**。
///
/// **刻意不与 command 审批复用同一类型**（10F-A 冻结：interactive
/// terminal mutation ≠ command execution，见
/// `AgentTerminalInputTargetIdentity.swift` 顶部语义分界）。结构与
/// 已验收的 command coordinator 同构：actor 隔离 + 单向状态机 +
/// CAS claim + permit redeem + waiter exactly-once + denied ≠ cancelled。
/// 泛型 approval core 抽象推迟到 10F 之后（不在 B1 重构 10E 代码）。
///
/// 相对 command 域的两处 mutation 专属差异（本文件冻结）：
/// 1. claim 期望额外绑定 **incarnation 身份**（epoch / endpoint token），
///    不匹配 → `targetReplaced`（§23：sessionID 相等绝不构成授权；
///    重连 / shell 重启 = 新 epoch → 旧审批确定性 stale）；
/// 2. **claim 后未 redeem 的授权可被 generation / session 取消失效**
///    （§39 冻结规则：授权一经取消即零授权，redeem 失败
///    `approvalStale`； redeem 完成后 transport 取消语义属 B2/B3，
///    B1 止步于此）。逐条 `cancelApproval` 不触碰已 claim 记录。
///
/// `actor` 隔离统一串行化全部竞争操作（§33）：approve / deny /
/// cancelApproval / Stop（cancelGeneration）/ session close
/// （cancelSession）/ claim / redeem / 双击 / waiter 注册与恢复。
/// 记录 **memory-only**：绝不落任何存储 / 偏好 / 文件通道；无任何
/// 持久化信任概念（无任何永久放行 / 会话级信任 / 自动批准语义；
/// §29/§30：每次 mutation 都必须逐次审批，即使是 `pwd`）。
///
/// 决策等待语义（对齐 10E）：同一 approval 允许多个 waiter，每个
/// waiter 恰好恢复一次并得到同一 resolution；决策已落定后再 wait
/// 立即返回已存解析。waiter 自身 Task 取消 ≠ 取消 approval
/// （只摘除该 waiter，不产生任何执行授权，无 orphan continuation）。
actor AgentTerminalMutationApprovalCoordinator {
    /// 决策 waiter（resume exactly once）。
    private struct DecisionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<AgentTerminalMutationApprovalResolution, Error>
    }

    /// 内部账本条目（状态只在本 actor 内可变）。
    private struct Record {
        let id: UUID
        let request: AgentTerminalMutationRequest
        var state: AgentTerminalMutationApprovalState
        /// claim 成功时生成的单次消费凭据。
        var permit: UUID?
        /// 登记 / 快照排序用的单调序号。
        let order: Int
    }

    private var records: [UUID: Record] = [:]
    private var waiters: [UUID: [DecisionWaiter]] = [:]
    private var orderCounter = 0

    // MARK: - 创建（任务书 §26：callID 绑定；§36：replay 拒绝）

    /// 登记一条 pending approval（初始 `awaitingApproval`，此刻不存在
    /// 任何执行授权）。
    ///
    /// 同一 `(generationID, callID)` 幂等：重复登记返回既有 approvalID，
    /// 绝不产生第二个审批（replay 防线）。两次**不同** callID 即使
    /// text / submit 完全相同也是**两次不同 mutation**（§26：call A
    /// 的审批永远不能授权 call B）。
    @discardableResult
    func register(_ request: AgentTerminalMutationRequest) async -> UUID {
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
            order: orderCounter
        )
        return id
    }

    // MARK: - 用户决策（§17/§34/§38）

    /// `awaitingApproval → approved`。approve 本身**不产生任何终端
    /// 字节**（§18：B1 零副作用），只授予一次未来 claim 的资格。
    /// 双击竞态下恰好一次 `performed`，败者 `alreadyResolved`。
    func approve(_ approvalID: UUID) async -> AgentTerminalMutationApprovalActionResult {
        transition(approvalID, to: .approved)
    }

    /// `awaitingApproval → denied`（userDenied 语义，§38：终局——
    /// 产生零授权、不可后续 approve / redeem）。
    func deny(_ approvalID: UUID) async -> AgentTerminalMutationApprovalActionResult {
        transition(approvalID, to: .denied)
    }

    /// 单条取消：`awaitingApproval | approved → cancelled`
    /// （approved 未 claim 仍可被 Stop 失效）。已 claim 的记录不可经
    /// 逐条审批路径撤销（generation / session 级取消才负责已 claim
    /// 未 redeem 的失效，见类型注释差异 2）。
    @discardableResult
    func cancelApproval(_ approvalID: UUID) async -> AgentTerminalMutationApprovalActionResult {
        guard var record = records[approvalID] else { return .notFound }
        switch record.state {
        case .awaitingApproval, .approved:
            record.state = .cancelled
            records[approvalID] = record
            resumeWaiters(approvalID: approvalID, resolution: .cancelled)
            return .performed
        case .denied, .cancelled, .executionClaimed, .redeemed:
            return .alreadyResolved(record.state)
        }
    }

    // MARK: - 批量失效 / 清理（任务书 §24/§39）

    /// 失效某 generation 的全部未完成授权（Stop / generation 替换）。
    ///
    /// **包含已 claim 未 redeem 的记录**（§39 冻结规则：授权尚未消费
    /// 时，generation / request 取消使其失效 → 零授权）。返回失效条数。
    @discardableResult
    func cancelGeneration(_ generationID: UUID) async -> Int {
        cancelPending(where: { $0.request.generationID == generationID })
    }

    /// 失效某 logical session 的全部未完成授权（session close）。
    @discardableResult
    func cancelSession(_ sessionID: UUID) async -> Int {
        cancelPending(where: { $0.request.logicalSessionID == sessionID })
    }

    /// 清除某 generation 的全部记录（conversation teardown；resolved
    /// 记录不永久积累）。仍有 waiter 的记录先以 cancelled 恢复，
    /// 绝不泄漏 continuation。返回清除条数。
    @discardableResult
    func purgeGeneration(_ generationID: UUID) async -> Int {
        purge(where: { $0.request.generationID == generationID })
    }

    /// 清除某 session 的全部记录（session teardown）。
    @discardableResult
    func purgeSession(_ sessionID: UUID) async -> Int {
        purge(where: { $0.request.logicalSessionID == sessionID })
    }

    // MARK: - 单次执行授权（任务书 §17/§19/§23/§25/§49/§50）

    /// 原子 claim：`approved → executionClaimed`，返回一次性授权。
    ///
    /// 检查顺序：存在性 → 逻辑绑定一致性（generation / logical session /
    /// provider snapshot，任一不符 `bindingMismatch`）→ **incarnation
    /// 绑定一致性**（epoch / endpoint token，任一不符 `targetReplaced`）
    /// → 状态。
    ///
    /// - `awaitingApproval` → `approvalNotApproved`；
    /// - `denied` → `approvalAlreadyResolved`；
    /// - `cancelled` → `approvalCancelled`；
    /// - `executionClaimed` / `redeemed` → `approvalAlreadyConsumed`
    ///   （只有第一次 claim 成功）。
    ///
    /// 返回的 authorization 携带 coordinator 保存的 immutable request；
    /// 调用方绝不重传 text / submit / 目标身份。
    func claimExecution(
        approvalID: UUID,
        expected: AgentTerminalMutationClaimExpectations
    ) async throws -> AgentTerminalMutationExecutionAuthorization {
        guard var record = records[approvalID] else {
            throw AgentTerminalMutationError.approvalNotFound
        }
        guard
            record.request.generationID == expected.generationID,
            record.request.logicalSessionID == expected.logicalSessionID,
            record.request.providerBinding.snapshotID == expected.providerSnapshotID
        else {
            throw AgentTerminalMutationError.bindingMismatch
        }
        // Incarnation 绑定（§23/§50）：epoch 或 token 任一漂移 →
        // 目标已被替换，旧审批确定性 stale，零授权。
        guard
            record.request.targetIdentity.inputTargetEpoch == expected.inputTargetEpoch,
            record.request.targetIdentity.endpointToken == expected.endpointToken
        else {
            throw AgentTerminalMutationError.targetReplaced
        }
        switch record.state {
        case .awaitingApproval:
            throw AgentTerminalMutationError.approvalNotApproved
        case .denied:
            throw AgentTerminalMutationError.approvalAlreadyResolved
        case .cancelled:
            throw AgentTerminalMutationError.approvalCancelled
        case .executionClaimed, .redeemed:
            throw AgentTerminalMutationError.approvalAlreadyConsumed
        case .approved:
            let permit = UUID()
            record.state = .executionClaimed
            record.permit = permit
            records[approvalID] = record
            return AgentTerminalMutationExecutionAuthorization(
                approvalID: record.id,
                generationID: record.request.generationID,
                callID: record.request.callID,
                logicalSessionID: record.request.logicalSessionID,
                targetIdentity: record.request.targetIdentity,
                request: record.request,
                permit: permit
            )
        }
    }

    /// 消费一次性授权（单次消费语义）：首次返回 coordinator 保存的
    /// 原 immutable request（exact text + exact submit + exact 目标
    /// 身份，B2/B3 据此对账 `TerminalMutationEndpoint`）。
    ///
    /// 检查顺序：记录存在性 → permit 核对（不匹配 → `approvalStale`）
    /// → 状态（`redeemed` 且 permit 匹配 → `approvalAlreadyConsumed`
    /// 单次消费防线；其余非 claim 态 → `approvalStale`，如已被
    /// generation / session 取消）。
    ///
    /// 本方法**绝不执行任何交付**（§18：B1 到 REDEEM 为止；观察到任何
    /// 终端字节即越界）。
    func redeem(
        _ authorization: AgentTerminalMutationExecutionAuthorization
    ) async throws -> AgentTerminalMutationRequest {
        guard var record = records[authorization.approvalID] else {
            throw AgentTerminalMutationError.approvalStale
        }
        guard record.permit == authorization.permit else {
            throw AgentTerminalMutationError.approvalStale
        }
        switch record.state {
        case .executionClaimed:
            record.state = .redeemed
            records[authorization.approvalID] = record
            return record.request
        case .redeemed:
            throw AgentTerminalMutationError.approvalAlreadyConsumed
        case .awaitingApproval, .approved, .denied, .cancelled:
            throw AgentTerminalMutationError.approvalStale
        }
    }

    // MARK: - 读取

    /// 单条 read-only 快照（不存在返回 nil）。
    func snapshot(approvalID: UUID) async -> AgentTerminalMutationApprovalSnapshot? {
        records[approvalID].map { AgentTerminalMutationApprovalSnapshot(
            id: $0.id, request: $0.request, state: $0.state
        ) }
    }

    /// 某 generation 的全部快照（按登记序）。
    func snapshots(generationID: UUID) async -> [AgentTerminalMutationApprovalSnapshot] {
        records.values
            .filter { $0.request.generationID == generationID }
            .sorted { $0.order < $1.order }
            .map { AgentTerminalMutationApprovalSnapshot(
                id: $0.id, request: $0.request, state: $0.state
            ) }
    }

    // MARK: - 决策等待

    /// 等待决策。决策先于等待 → 立即返回已存解析；等待先于决策 →
    /// 恢复一次。denied → `.denied`；cancelled → `.cancelled`；
    /// approved / executionClaimed / redeemed → `.approved`。
    ///
    /// waiter Task 自身被取消 → 抛 `CancellationError`，approval 状态
    /// 不变、不自动批准、不产生执行授权（lifecycle 归 generation 取消
    /// 路径统一处理）。
    func awaitDecision(approvalID: UUID) async throws -> AgentTerminalMutationApprovalResolution {
        guard let record = records[approvalID] else {
            throw AgentTerminalMutationError.approvalNotFound
        }
        // decision-before-wait：立即返回，绝不悬挂。
        if let resolution = Self.resolution(of: record.state) {
            return resolution
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await self.suspendDecisionWaiter(waiterID: waiterID, approvalID: approvalID)
        }, onCancel: {
            // 只取消本 waiter：generation 路径才负责取消 approval。
            Task { await self.removeWaiter(waiterID: waiterID, approvalID: approvalID) }
        })
    }

    private func suspendDecisionWaiter(
        waiterID: UUID,
        approvalID: UUID
    ) async throws -> AgentTerminalMutationApprovalResolution {
        // fast path 与挂起点之间存在 actor 重入窗口：决策可能已落定。
        guard let record = records[approvalID] else {
            throw AgentTerminalMutationError.approvalNotFound
        }
        if let resolution = Self.resolution(of: record.state) {
            return resolution
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[approvalID, default: []].append(
                DecisionWaiter(id: waiterID, continuation: continuation)
            )
            // 竞态自愈：onCancel 触发早于登记。摘除并立即以取消恢复，
            // 保证 resume exactly once。
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

    /// 决策落定后恢复全部 waiter（各恰好一次）。
    private func resumeWaiters(
        approvalID: UUID,
        resolution: AgentTerminalMutationApprovalResolution
    ) {
        guard let pending = waiters.removeValue(forKey: approvalID) else { return }
        for waiter in pending {
            waiter.continuation.resume(returning: resolution)
        }
    }

    // MARK: - 计数（test-only introspection；只暴露计数，绝不暴露 payload）

    /// pending（awaitingApproval / approved 未 claim）总数。
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
            $0.request.logicalSessionID == sessionID && Self.isPending($0.state)
        }.count
    }

    // MARK: - Private

    /// 决策类转移的统一实现（actor 隔离内原子执行）。
    private func transition(
        _ approvalID: UUID,
        to newState: AgentTerminalMutationApprovalState
    ) -> AgentTerminalMutationApprovalActionResult {
        guard var record = records[approvalID] else { return .notFound }
        guard record.state == .awaitingApproval else {
            // 败者得到 alreadyResolved，绝不二次终态转移。
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

    /// 批量失效：awaiting / approved / **已 claim 未 redeem** 全部 →
    /// cancelled（§39 冻结规则）；redeemed 为终态不动。
    private func cancelPending(
        where predicate: (Record) -> Bool
    ) -> Int {
        let ids = records
            .filter { predicate($0.value) && Self.isCancellable($0.value.state) }
            .map(\.key)
        for id in ids {
            guard var record = records[id] else { continue }
            record.state = .cancelled
            record.permit = nil
            records[id] = record
            resumeWaiters(approvalID: id, resolution: .cancelled)
        }
        return ids.count
    }

    private func purge(where predicate: (Record) -> Bool) -> Int {
        let ids = records.filter { predicate($0.value) }.map(\.key)
        for id in ids {
            // 记录可能仍有 waiter：先以 cancelled 恢复再移除。
            resumeWaiters(approvalID: id, resolution: .cancelled)
            records[id] = nil
            waiters[id] = nil
        }
        return ids.count
    }

    private static func isPending(_ state: AgentTerminalMutationApprovalState) -> Bool {
        switch state {
        case .awaitingApproval, .approved: return true
        case .denied, .cancelled, .executionClaimed, .redeemed: return false
        }
    }

    private static func isCancellable(_ state: AgentTerminalMutationApprovalState) -> Bool {
        switch state {
        case .awaitingApproval, .approved, .executionClaimed: return true
        case .denied, .cancelled, .redeemed: return false
        }
    }

    private static func resolution(
        of state: AgentTerminalMutationApprovalState
    ) -> AgentTerminalMutationApprovalResolution? {
        switch state {
        case .awaitingApproval: return nil
        case .approved, .executionClaimed, .redeemed: return .approved
        case .denied: return .denied
        case .cancelled: return .cancelled
        }
    }
}
