import Foundation

/// MacSSH 1.1 Phase 10C-D / 10D-B4：DeepSeek Responses API 生产 Provider
/// （任务书 §1 / §2 / §12 / §13 / B4 §10/§20/§58/§66）。
///
/// - Base URL：`https://api.deepseek.com`（官方 SDK 语义，不带 /v1），
///   endpoint = Base URL + `/responses`（§10：不得改回 Chat Completions）；
/// - SSE：semantic events，无 Chat Completions 风格 `data: [DONE]`，
///   依赖共享 ResponsesProviderCore 的字节级组包；
/// - `response.incomplete` → 结构化 `AgentProviderError.incompleteResponse`；
/// - B4：function tools / tool_choice / function_call /
///   function_call_output 与 OpenAI 同构（共享 core）；`parallel_tool_calls`
///   行为由 Provider 自己处理，MacSSH 不依赖该字段；
/// - stateless continuation（§20）：每轮发送完整本地 transcript 重建的
///   input，绝不使用 previous_response_id / conversation；
/// - reasoning 差异（§66）：adapter 自行吸收——reasoning output item
///   捕获为 DeepSeek-scoped opaque item（domain 不解读）；provider
///   切换后绝不互相回放（§53）。

enum DeepSeekResponsesDefaults {
    /// 默认模型（任务书 §1）。
    static let model = "deepseek-v4-flash"

    /// 默认 Base URL（任务书 §1：官方示例 base_url = https://api.deepseek.com）。
    static let baseURL = URL(string: "https://api.deepseek.com")!
}

/// DeepSeek SSE → MappedEvent 映射（共享映射 + incomplete 特化）。
enum DeepSeekResponsesStreamMapper {
    /// - Returns: nil = 未知 / 无需处理的事件（忽略，不 crash）。
    /// - Throws: `AgentProviderError`（含 `incompleteResponse`——
    ///   `response.incomplete` 终态：partial 内容由 ViewModel 保留，
    ///   错误分类驱动 agent.provider.error.incomplete 文案）。
    static func mappedEvent(from sseEvent: SSEEvent) throws -> ResponsesStreamMapper.MappedEvent {
        switch try ResponsesStreamMapper.map(sseEvent) {
        case .incomplete:
            AppLogger.agent.error("Agent provider stream incomplete: response.incomplete")
            throw AgentProviderError.incompleteResponse
        case let mapped:
            return mapped
        }
    }
}

struct DeepSeekResponsesProvider: AgentProvider {
    /// 请求启动时刻的不可变配置快照（任务书 §25 / §9 / B4 §54）。
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
            providerScope: .deepSeek,
            eventMapper: DeepSeekResponsesStreamMapper.mappedEvent(from:)
        )
        .stream(transcript: transcript, tools: tools, context: context)
    }
}
