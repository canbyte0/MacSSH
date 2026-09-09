import Foundation

/// MacSSH 1.1 Phase 10C：Provider 流式事件（任务书 §17）。
///
/// Provider 必须真正增量 yield `textDelta`（逐段文本，GUI 表现为
/// `Hello → Hello, I → Hello, I can → …`），禁止「等完整 response
/// 再一次性显示」。流正常结束时以 `completed` 收尾（随后 stream finish）。
enum AgentEvent: Sendable, Equatable {
    /// 增量文本 delta。
    case textDelta(String)
    /// 流正常结束（模型完成回复）。
    case completed
}
