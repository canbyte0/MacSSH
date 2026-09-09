import Foundation

/// MacSSH 1.1 Phase 10C-D：DeepSeek Responses API 生产 Provider
/// （任务书 §1 / §2 / §12 / §13）。
///
/// - Base URL：`https://api.deepseek.com`（官方 SDK 语义，不带 /v1），
///   endpoint = Base URL + `/responses`；
/// - SSE：semantic events，无 Chat Completions 风格 `data: [DONE]`，
///   依赖共享 ResponsesProviderCore 的字节级组包（不引入 [DONE] 依赖）；
/// - `response.incomplete` → 结构化 `AgentProviderError.incompleteResponse`
///   （任务书 §2：structured provider error / incomplete result）；
/// - HTTP transport / 取消所有权 / status 映射与 OpenAI 完全共享；
/// - Request body 同样只含 model / input / stream（任务书 §12 hard gate：
///   DeepSeek 官方虽支持 tool calls，本阶段仍禁止）。

enum DeepSeekResponsesDefaults {
    /// 默认模型（任务书 §1：第一版支持 deepseek-v4-flash / v4-pro；
    /// 默认建议 flash。Phase 10C 只做文本，不实现 vision 模型）。
    static let model = "deepseek-v4-flash"

    /// 默认 Base URL（任务书 §1：官方示例 base_url = https://api.deepseek.com）。
    static let baseURL = URL(string: "https://api.deepseek.com")!
}

/// DeepSeek SSE → AgentEvent 映射（共享映射 + incomplete 特化）。
enum DeepSeekResponsesStreamMapper {
    /// - Returns: nil = 未知 / 无需处理的事件（忽略，不 crash）。
    /// - Throws: `AgentProviderError`（含 `incompleteResponse`——
    ///   `response.incomplete` 终态：partial 内容由 ViewModel 保留，
    ///   错误分类驱动 agent.provider.error.incomplete 文案）。
    static func agentEvent(from sseEvent: SSEEvent) throws -> AgentEvent? {
        switch try ResponsesStreamMapper.map(sseEvent) {
        case .agent(let event):
            return event
        case .incomplete:
            AppLogger.agent.error("Agent provider stream incomplete: response.incomplete")
            throw AgentProviderError.incompleteResponse
        case .ignored:
            return nil
        }
    }
}

struct DeepSeekResponsesProvider: AgentProvider {
    /// 请求启动时刻的不可变配置快照（任务书 §25 / §9）。
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
            eventMapper: DeepSeekResponsesStreamMapper.agentEvent(from:)
        )
        .stream(messages: messages, context: context)
    }
}
