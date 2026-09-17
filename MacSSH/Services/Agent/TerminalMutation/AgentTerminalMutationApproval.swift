import Foundation

// MARK: - Approval 状态（任务书 §17；语义复制已验收的 10E 状态机）

/// Approval 状态机的状态。
///
/// transition **单向**：`awaitingApproval` → `approved` / `denied` /
/// `cancelled`；`approved` → `executionClaimed`；`executionClaimed` →
/// `redeemed`。禁止 `denied → approved`、`cancelled → approved`、
/// `executionClaimed → approved`、任何终态回退。`denied` / `cancelled` /
/// `redeemed` 为终态。
///
/// 不变式（§17）：
/// - 一个 request 至多一次成功 approval claim（CAS `approved →
///   executionClaimed`）；
/// - 一个 claim 至多一次成功 redeem（permit 单次消费）；
/// - deny / cancel → 零授权；replay → 拒绝；
/// - double approve / double redeem → 第二次拒绝。
///
/// 状态只存在于 coordinator 内部；对外只暴露 read-only snapshot。
/// B1 全程零副作用：任何状态都不触发 transport 写入（§18：B1 只实现到
/// REDEEM，SIDE EFFECT 属 B2/B3）。
enum AgentTerminalMutationApprovalState: Sendable, Equatable {
    case awaitingApproval
    case approved
    case denied
    case cancelled
    case executionClaimed
    case redeemed
}

// MARK: - 决策解析（语义对齐 10E：userDenied 与 cancelled 严格区分）

/// `awaitDecision` 的解析结果。
///
/// `denied` = 用户主动拒绝（userDenied 语义，终局、零授权、不可后续
/// approve）；`cancelled` = Stop / generation 取消 / session 关闭 /
/// 目标失效。Provider continuation 接线属 B4，本阶段不消费。
enum AgentTerminalMutationApprovalResolution: Sendable, Equatable {
    case approved
    case denied
    case cancelled
}

// MARK: - 转移结果

/// 用户决策类转移（approve / deny / cancel）的结果。
///
/// 竞争败者得到 `alreadyResolved(当前终态)`（恰好一个 terminal
/// transition 生效）；不存在的 approvalID 得到 `notFound`。
enum AgentTerminalMutationApprovalActionResult: Sendable, Equatable {
    case performed
    case alreadyResolved(AgentTerminalMutationApprovalState)
    case notFound
}

// MARK: - Claim 期望绑定（任务书 §19/§23/§25/§49）

/// claim 时呈递的期望绑定。generation / logical session / provider
/// snapshot 必须与审批记录逐一相等，否则 `bindingMismatch`；
/// **epoch / endpoint token** 必须与冻结的 incarnation 身份逐一相等，
/// 否则 `targetReplaced`（§23：sessionID 相等绝不构成授权）。
/// text / submit **不在期望参数内**——它们由 coordinator 保存的
/// immutable request 结构性保证（§20）。
struct AgentTerminalMutationClaimExpectations: Sendable, Equatable {
    let generationID: UUID
    let logicalSessionID: UUID
    let providerSnapshotID: UUID
    let inputTargetEpoch: AgentTerminalInputTargetEpoch
    let endpointToken: AgentTerminalEndpointToken
}

// MARK: - UI 快照（任务书 §40；read-only，非修改通道）

/// UI 可读的 approval 快照：**read-only 值**，绝不构成修改 authority
/// 的通道（所有 transition 只能经 coordinator actor 方法）。
/// 未来 mutation 审批卡片消费本类型即可获得全部所需展示数据
/// （Local / Remote、session / host 快照、epoch 短身份、exact text、
/// submit 标志、payload 字节数）；卡片内 payload 不可编辑。
/// `card.status == approved` 绝不等价于已执行。
struct AgentTerminalMutationApprovalSnapshot: Sendable, Equatable {
    let id: UUID
    let request: AgentTerminalMutationRequest
    let state: AgentTerminalMutationApprovalState
}

extension AgentTerminalMutationApprovalSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
    /// redacted：绝不输出 payload 文本 / host display（§32）。
    var description: String {
        "AgentTerminalMutationApprovalSnapshot(id: \(id.uuidString), "
            + "state: \(state), request: <redacted>)"
    }

    var debugDescription: String { description }
}
