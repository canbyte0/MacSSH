import Foundation

/// MacSSH 1.1 Phase 10C / 10D-B4：OpenAI Responses API 生产 Provider
/// （任务书 §16 / §17 / §18 / §19 / §23 / B4 §21/§22）。
///
/// - HTTP transport / SSE 解析 / function-call 组装：共享
///   `ResponsesProviderCore`（B4 §11）；
/// - 手动上下文管理（§21）：每轮从本地 transcript 完整重建 input，
///   不依赖 `previous_response_id`；
/// - reasoning item 保留（§22 hard gate）：core 的 assembler 捕获
///   `reasoning` output item 为 OpenAI-scoped opaque continuation
///   item，由请求重建阶段 verbatim 回放；
/// - `response.incomplete` 保持忽略语义（Phase 10C 已验收行为）。
struct OpenAIResponsesProvider: AgentProvider {
    /// 请求启动时刻的不可变配置快照（任务书 §25 / B4 §54）。
    let configuration: AgentProviderRequest

    /// 注入的 URLSession（测试经 URLProtocol stub 注入，100% offline）。
    let session: URLSession

    func stream(
        transcript: [AgentMessage],
        tools: [AgentToolDefinition],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        ResponsesProviderCore(
            configuration: configuration,
            session: session,
            providerScope: .openAI,
            eventMapper: OpenAIResponsesStreamMapper.mappedEvent(from:)
        )
        .stream(transcript: transcript, tools: tools, context: context)
    }
}
