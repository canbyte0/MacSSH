import Foundation

/// MacSSH 1.1 Phase 10C：OpenAI Responses API 生产 Provider
/// （任务书 §16 / §17 / §18 / §19 / §23）。
///
/// Phase 10C-D：HTTP transport 与 SSE 解析循环抽出至共享
/// `ResponsesProviderCore`（纯移动，行为零变化）；本类型退化为薄壳，
/// 只注入 OpenAI 的事件映射（`response.incomplete` 保持忽略语义）。
struct OpenAIResponsesProvider: AgentProvider {
    /// 请求启动时刻的不可变配置快照（任务书 §25）。
    let configuration: AgentProviderRequest

    /// 注入的 URLSession（测试经 URLProtocol stub 注入，100% offline）。
    let session: URLSession

    func stream(
        messages: [AgentMessage],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        ResponsesProviderCore(
            configuration: configuration,
            session: session,
            eventMapper: OpenAIResponsesStreamMapper.agentEvent(from:)
        )
        .stream(messages: messages, context: context)
    }
}
