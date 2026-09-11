import Foundation

// MARK: - Provider scope（B4 §23/§53）

/// Provider 身份标签（请求快照的一部分）。
///
/// 唯一职责：给 opaque continuation item 标注归属——provider 切换后
/// （如 DeepSeek → OpenAI），异构 provider 的原始 item 绝不互相回放
/// （§53 hard gate）。rawValue 与 `AgentProviderSettings.Provider` 一致。
enum AgentProviderScope: String, Sendable, Equatable {
    case openAI = "openai"
    case deepSeek = "deepseek"

    init(settingsProvider: AgentProviderSettings.Provider) {
        switch settingsProvider {
        case .openAI: self = .openAI
        case .deepSeek: self = .deepSeek
        }
    }
}

// MARK: - 完整组装的工具调用（B4 §3/§11/§14）

/// Provider 流式组装完成后的**完整** function call（§11 hard gate）。
///
/// `ResponsesProviderCore` 负责把 SSE 的 output_item / arguments delta /
/// arguments done 事件组装为该值；Agent runtime（ViewModel / Router）
/// 绝不自行拼接 SSE argument fragments，也不接触 provider-specific 的
/// `itemID` / `outputIndex`。
///
/// - `callID`：Provider 返回的 `call_id`，是 continuation 配对的
///   hard identity（§14）——绝不用 item_id / UUID / tool name 替代。
/// - `argumentsJSON`：canonical 完整 JSON arguments string
///   （§12：`response.function_call_arguments.done.arguments` 为准）。
///   组装层不解释其内容；执行前的本地验证属于 loop 层。
struct AgentProviderToolCall: Sendable, Equatable {
    let callID: String
    let name: String
    let argumentsJSON: String
}

// MARK: - Provider-specific opaque continuation item（B4 §22/§23）

/// Provider 范围内的 opaque continuation item（§22 hard gate）。
///
/// 典型来源：OpenAI reasoning 模型在 function calling 时的
/// `reasoning` output item。MacSSH 自管上下文时，官方要求在后续
/// request input 中回放这些 item。
///
/// 硬约束（§23）：
/// - **provider-scoped**：只回放给同一 provider（`providerScope` 标注）；
/// - **memory-only**：只存在于 conversation transcript，不落盘；
/// - **not rendered**：UI 不渲染（AgentMessageView 对该 content 返回空）；
/// - **not logged**：绝不写日志；
/// - **not interpreted**：Router / domain 绝不解读 payload 语义——
///   原样透传给对应 provider 的 request builder。
struct AgentProviderContinuationItem: Sendable, Equatable {
    /// 归属 provider：回放时的过滤依据（§53）。
    let providerScope: AgentProviderScope
    /// item 类型标签（如 "reasoning"）；仅作诊断标识，不参与解释。
    let kind: String
    /// Provider 原始 item JSON（verbatim）；结构对 MacSSH 完全 opaque。
    let itemJSON: String
}
