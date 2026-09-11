import Foundation

/// MacSSH 1.1 Phase 10C/10D-B4：Provider 流式事件（任务书 §17 / B4 §16）。
///
/// Provider 必须真正增量 yield `textDelta`（逐段文本），禁止「等完整
/// response 再一次性显示」。流正常结束时以 `completed` 收尾（随后
/// stream finish）。
///
/// B4 硬约束（§11/§16）：
/// - `toolCall` 携带的必须是**完整组装**的调用（call_id + name +
///   canonical arguments JSON）——SSE argument fragment 拼接只发生在
///   Provider 传输层内部；
/// - 不向 Agent runtime 暴露 provider-specific 的
///   `argumentsDelta` / `outputItemAdded` / `outputIndex`；
/// - `providerItem` 是 opaque 的 provider continuation item（reasoning
///   回放载体，§22/§23）——domain 不解释、UI 不渲染。
enum AgentEvent: Sendable, Equatable {
    /// 增量文本 delta。
    case textDelta(String)
    /// 完整组装的工具调用（§11）。
    case toolCall(AgentProviderToolCall)
    /// Provider-scoped opaque continuation item（reasoning 等，§22/§23）。
    case providerItem(AgentProviderContinuationItem)
    /// 流正常结束（模型完成回复）。
    case completed
}
