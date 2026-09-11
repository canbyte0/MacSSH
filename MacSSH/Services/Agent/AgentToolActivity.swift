import Foundation

/// B4：单次工具调用的会话时间线条目（UI tool card + provider transcript
/// 数据的单一来源，§17/§38/§41）。
///
/// 生命周期：
/// 1. Provider 组装出完整 `AgentProviderToolCall` → 以 `.running` 状态
///    append（§37 privacy gate：数据外发前 UI 必须可见）；
/// 2. 执行（成功 / 可恢复失败 / 取消）→ 更新 `status` 与 `resultJSON`；
/// 3. transcript 重建时输出为一对 `function_call` + `function_call_output`
///    （§14：call_id 严格配对；`resultJSON` 为空时输出结构化 cancelled
///    错误，保证配对恒成立）。
///
/// `displayTarget` 只是用户本地可见的展示信息（§40）；绝不进入日志。
struct AgentToolActivity: Equatable, Sendable {
    /// Tool card 状态（§38）。
    enum Status: Equatable, Sendable {
        case running
        case success
        case failure
        case cancelled

        /// 语言无关的状态标记（accessibility / scroll trigger / 测试断言用）。
        var rawMarker: String {
            switch self {
            case .running: return "running"
            case .success: return "success"
            case .failure: return "failure"
            case .cancelled: return "cancelled"
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
        status: Status = .running,
        resultJSON: String? = nil,
        isError: Bool = false
    ) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.displayTarget = displayTarget
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
