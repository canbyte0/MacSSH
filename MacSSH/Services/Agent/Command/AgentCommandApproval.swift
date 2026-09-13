import Foundation

// MARK: - Approval 状态（任务书 §19）

/// Approval 状态机的状态。
///
/// transition **单向**（§19）：`awaitingApproval` → `approved` / `denied` /
/// `cancelled`；`approved` → `executionClaimed` / `cancelled`。
/// 禁止 `denied → approved`、`cancelled → approved`、
/// `executionClaimed → approved`。`denied` / `cancelled` /
/// `executionClaimed` 为终态。
///
/// 状态只存在于 coordinator 内部（§70）；对外只暴露 read-only snapshot。
enum AgentCommandApprovalState: Sendable, Equatable {
    case awaitingApproval
    case approved
    case denied
    case cancelled
    case executionClaimed
}

// MARK: - 决策解析（任务书 §22/§60）

/// `awaitDecision` 的解析结果。
///
/// §60 语义冻结：用户主动 Reject（`denied`）与取消（`cancelled`）
/// **严格区分**——Reject 未来序列化为 `{"ok":false,"error":"userDenied"}`，
/// Stop / session close 收敛为 cancelled / stale。Provider wiring 属 B4。
enum AgentCommandApprovalResolution: Sendable, Equatable {
    case approved
    /// 用户主动 Reject（userDenied 语义）。
    case denied
    /// Stop / generation 取消 / session 关闭导致的失效。
    case cancelled
}

// MARK: - 转移结果（任务书 §27/§28）

/// 用户决策类转移（approve / deny / cancel）的结果。
///
/// 竞争败者得到 `alreadyResolved(当前终态)`（§27：恰好一个 terminal
/// transition 生效）；不存在的 approvalID 得到 `notFound`。
enum AgentCommandApprovalActionResult: Sendable, Equatable {
    /// 转移发生。
    case performed
    /// approval 已处于终态，本次为 no-op（携带当前状态）。
    case alreadyResolved(AgentCommandApprovalState)
    /// approvalID 未知。
    case notFound
}

// MARK: - Claim 期望绑定（任务书 §78–§80）

/// claim 时呈递的期望绑定：generation / session / provider snapshot
/// 必须与审批记录逐一相等，否则 `bindingMismatch`。
/// command / cwd **不在期望参数内**——它们由 coordinator 保存的
/// immutable request 结构性保证（§43/§44）。
struct AgentCommandClaimExpectations: Sendable, Equatable {
    let generationID: UUID
    let sessionID: UUID
    let providerSnapshotID: UUID
}

// MARK: - UI 快照（任务书 §69/§70）

/// UI 可读的 approval 快照：**read-only 值**，绝不构成修改 authority
/// 的通道（§70：所有 transition 只能经 coordinator actor 方法）。
/// 未来 Tool Card 展示 `awaitingApproval` 等状态时消费本类型；
/// `card.status == approved` 绝不等价于可执行（§35）。
struct AgentCommandApprovalSnapshot: Sendable, Equatable {
    let id: UUID
    let request: AgentCommandRequest
    let state: AgentCommandApprovalState
}

extension AgentCommandApprovalSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
    /// redacted：绝不输出 command / cwd / displayName（§57）。
    var description: String {
        "AgentCommandApprovalSnapshot(id: \(id.uuidString), state: \(state), request: <redacted>)"
    }

    var debugDescription: String { description }
}
