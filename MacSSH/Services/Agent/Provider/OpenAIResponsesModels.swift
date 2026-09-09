import Foundation

/// MacSSH 1.1 Phase 10C：OpenAI Responses API 集中默认值（任务书 §6 / §9 / §10 / §28）。
///
/// 请求 / 流事件模型与传输循环已在 Phase 10C-D 抽出至共享
/// `ResponsesProviderCore`（OpenAI / DeepSeek 结构一致）；本文件只保留
/// OpenAI 默认值与 mapper 薄壳。Request body 硬性约束：只含
/// model / input / stream——绝不含 tools / tool_choice / function /
/// functions / previous_response_id（由 ProviderTests 断言）。
enum OpenAIResponsesDefaults {
    /// 默认模型（用户可在 Settings 改为账户可用的任意 model ID）。
    static let model = "gpt-5.6"

    /// 默认 Base URL（任务书 §10）。
    static let baseURL = URL(string: "https://api.openai.com/v1")!

    /// 请求空闲超时（秒）：任一新数据到达即重置——长生成不受影响，
    /// 只拦截「连接后长时间无任何数据」的挂死。不给整个 generation
    /// 设短固定超时；用户主动终止由 Stop 控制。
    static let idleTimeout: TimeInterval = 120

    /// 资源生命周期兜底上限（秒）：正常情况流式会自然完成或被 Stop 取消。
    static let resourceTimeout: TimeInterval = 3600

    /// 生产 URLSession 配置（超时策略见上；会话由调用方注入以便测试）。
    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}

/// OpenAI SSE → AgentEvent 映射薄壳（Phase 10C-D：共享映射 + 特化点）。
///
/// OpenAI 特化行为：`response.incomplete` 保持 Phase 10C 既有行为
/// （忽略——不在本 provider 的支持事件列表内，不改变已验收语义）。
enum OpenAIResponsesStreamMapper {
    /// 解析单个 SSE 事件的 data JSON 并映射为 AgentEvent。
    /// - Returns: nil = 未知 / 无需处理的事件（按规范忽略）。
    /// - Throws: `AgentProviderError`（error / response.failed 事件、
    ///   JSON 解码失败、delta 事件缺字段）。
    static func agentEvent(from sseEvent: SSEEvent) throws -> AgentEvent? {
        switch try ResponsesStreamMapper.map(sseEvent) {
        case .agent(let event):
            return event
        case .incomplete, .ignored:
            return nil
        }
    }
}
