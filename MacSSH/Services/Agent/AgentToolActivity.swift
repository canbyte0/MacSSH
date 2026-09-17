import Foundation

/// B4：单次工具调用的会话时间线条目（UI tool card + provider transcript
/// 数据的单一来源，§17/§38/§41）。
///
/// 生命周期：
/// 1. Provider 组装出完整 `AgentProviderToolCall` → read-only call 以
///    `.running` 状态 append；run_command 先完成参数校验、immutable request
///    和 approval record，再以 `.awaitingApproval` append（§37）；
/// 2. 执行（成功 / 可恢复失败 / 取消）→ 更新 `status` 与 `resultJSON`；
/// 3. transcript 重建时输出为一对 `function_call` + `function_call_output`
///    （§14：call_id 严格配对；`resultJSON` 为空时输出结构化 cancelled
///    错误，保证配对恒成立）。
///
/// `displayTarget` 只是用户本地可见的展示信息（§40）；绝不进入日志。
struct AgentToolActivity: Equatable, Sendable {
    /// Tool card 状态（§38）。
    ///
    /// 10E-B1 foundation 扩展（任务书 §46/§88）：`awaitingApproval` /
    /// `denied` 为 command approval 的 domain 状态；B4 通过卡片 UI 让它们
    /// 成为可达的逐次审批状态。
    enum Status: Equatable, Sendable {
        case running
        /// 等待用户审批（10E-B1 foundation；B4 提供可达 UI）。
        case awaitingApproval
        case success
        case failure
        /// 用户拒绝（userDenied，10E-B1 foundation）。
        case denied
        case cancelled
        /// 命令已执行但达到 App-owned timeout，结果仍可继续发送 Provider。
        case timedOut
        /// 10F-B4-S1 §29/§55：terminal mutation 交付结果为 partial /
        /// uncertain——已确认前缀副作用存在，loop 停止并要求用户可见。
        case partial

        /// 语言无关的状态标记（accessibility / scroll trigger / 测试断言用）。
        var rawMarker: String {
            switch self {
            case .running: return "running"
            case .awaitingApproval: return "awaiting_approval"
            case .success: return "success"
            case .failure: return "failure"
            case .denied: return "denied"
            case .cancelled: return "cancelled"
            case .timedOut: return "timed_out"
            case .partial: return "partial"
            }
        }
    }

    /// Provider `call_id`（continuation 配对 hard identity，§14）。
    let callID: String
    /// Provider 返回的原始工具名（可能是 unknown / prohibited 名字，
    /// 一律原样展示，执行层静态注册表拒绝）。
    let toolName: String
    /// Provider 原始 arguments JSON（未解释；解析失败也不影响 card）。
    let argumentsJSON: String
    /// 用户可理解的展示目标（path 工具为请求 path；其余 nil）。
    let displayTarget: String?

    /// B4 命令审批 ID；read-only tool 为 nil。
    let approvalID: UUID?
    /// B4 的 immutable request；只供本地 UI 显示和 runtime identity guard，
    /// 不进入 Provider transcript 的 tool result。
    let commandRequest: AgentCommandRequest?
    /// 10F-B4-S1 的 immutable mutation request；只供本地 UI 显示与
    /// runtime 对账，payload 绝不进入日志或 Provider tool result echo。
    let mutationRequest: AgentTerminalMutationRequest?

    /// 当前状态（UI 渲染依据）。
    var status: Status
    /// 发送给 Provider 的结构化结果 JSON（§29）；执行完成前为 nil。
    var resultJSON: String?
    /// 结果是否为错误（对应 `{"ok": false, ...}`）。
    var isError: Bool

    init(
        callID: String,
        toolName: String,
        argumentsJSON: String,
        displayTarget: String?,
        approvalID: UUID? = nil,
        commandRequest: AgentCommandRequest? = nil,
        mutationRequest: AgentTerminalMutationRequest? = nil,
        status: Status = .running,
        resultJSON: String? = nil,
        isError: Bool = false
    ) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.displayTarget = displayTarget
        self.approvalID = approvalID
        self.commandRequest = commandRequest
        self.mutationRequest = mutationRequest
        self.status = status
        self.resultJSON = resultJSON
        self.isError = isError
    }

    /// 从完整 provider tool call 构造 running 状态的 activity（§37）。
    init(runningFrom call: AgentProviderToolCall) {
        self.init(
            callID: call.callID,
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            displayTarget: AgentToolCallParsing.displayTarget(of: call)
        )
    }
}
