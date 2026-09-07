import Foundation

/// MacSSH 1.1 Phase 10B：最小 Provider 协议（任务书 §11）。
///
/// 只承担「消息历史 + session 上下文 → 流式文本」。
/// 不定义 tool definitions / function calling schema / vendor JSON——
/// 这些属于 Phase 10C 及以后，避免 provider lock-in。
protocol AgentProvider: Sendable {
    /// 流式生成回复：按 chunk 产出文本，结束时正常 finish；
    /// 消费方取消消费 Task 时，流应尽快终止（mock 实现经
    /// onTermination 取消生产任务）。
    func stream(
        messages: [AgentMessage],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<String, Error>
}
