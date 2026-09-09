import Foundation

/// MacSSH 1.1 Phase 10C-D：OpenAI / DeepSeek Responses API 共享传输核心
/// （任务书 §3 / §4）。
///
/// 两个 provider 的 HTTP transport 与 SSE parsing 完全一致，从
/// `OpenAIResponsesProvider` 原样抽出（纯移动，OpenAI 行为零变化）：
/// - 请求体结构：`{model, input, stream}`（含完整多轮 history 重建）；
/// - endpoint：Base URL 追加 `responses` 路径；
/// - SSE 字节级组包循环（跨 chunk / EOF 宽容 flush）；
/// - HTTP status 映射与 transport 错误收敛；
/// - 取消所有权（onTermination → producer.cancel → data task 取消）。
///
/// Provider 差异点只经 `eventMapper` 注入（任务书 §4：provider-specific
/// terminal events——如 DeepSeek 对 `response.incomplete` 的结构化处理）。

// MARK: - Endpoint

enum ResponsesAPI {
    /// Responses endpoint 路径（追加到用户配置的 Base URL 之后）。
    /// OpenAI：`https://api.openai.com/v1` + `responses`；
    /// DeepSeek：`https://api.deepseek.com` + `responses`。
    static let responsesPath = "responses"
}

// MARK: - 请求体

/// Responses API 请求体（任务书 §6 / Phase 10C-D 任务书 §12：完整多轮
/// history；只含 model / input / stream——绝不含 tools / tool_choice /
/// function / functions / web_search / previous_response_id / conversation）。
struct ResponsesRequestBody: Encodable, Equatable {
    let model: String
    let input: [InputMessage]
    let stream: Bool

    /// input 数组元素：role + typed content parts。
    struct InputMessage: Encodable, Equatable {
        let role: String
        let content: [ContentPart]
    }

    struct ContentPart: Encodable, Equatable {
        let type: String
        let text: String
    }

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
    }

    /// 从本地消息历史构造 input（每次请求完整重建，任务书 §13：
    /// DeepSeek Responses API 不支持 previous_response_id / conversation，
    /// 本地方案正好正确，不得改成 server-side state）：
    /// - 保持 user / assistant 原始顺序（禁止只发最后一条 user message）；
    /// - failed 消息排除（partial 失败不是完整对话轮次）；
    /// - 前置一条轻量 context system 消息（仅 target 标识，绝不伪造 cwd）。
    static func input(
        messages: [AgentMessage],
        context: AgentSessionContext
    ) -> [InputMessage] {
        var result: [InputMessage] = []
        if let contextMessage = Self.contextMessage(for: context) {
            result.append(contextMessage)
        }
        for message in messages where message.state != .failed {
            result.append(
                InputMessage(
                    role: message.role.apiRole,
                    content: [
                        ContentPart(
                            type: message.role.contentPartType,
                            text: message.content
                        )
                    ]
                )
            )
        }
        return result
    }

    /// 轻量 context（不读 terminal buffer / scrollback / selection /
    /// shell env / SSH credentials——那些属于 10D）。
    private static func contextMessage(for context: AgentSessionContext) -> InputMessage? {
        var line = "Current terminal target: "
        switch context.kind {
        case .local:
            line += "Local"
        case .remoteSSH:
            line += "SSH · \(context.displayName)"
        }
        if let directory = context.displayDirectory {
            line += "\nCurrent directory: \(directory)"
        }
        return InputMessage(
            role: "system",
            content: [ContentPart(type: "input_text", text: line)]
        )
    }
}

private extension AgentMessage.Role {
    /// Responses API 的 role 名称。
    var apiRole: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }

    /// content part type：user / system 用 input_text；
    /// assistant 历史（模型上一轮输出）用 output_text。
    var contentPartType: String {
        switch self {
        case .user, .system: return "input_text"
        case .assistant: return "output_text"
        }
    }
}

// MARK: - 流事件模型与共享映射

/// 流事件（宽松解码：只取关心的字段，未知字段忽略）。
struct ResponsesStreamEvent: Decodable, Equatable {
    let type: String
    var delta: String?
    var code: String?
    var message: String?
}

/// SSEEvent → AgentEvent 共享映射（Phase 10C-D 任务书 §2 / §4）。
///
/// 共享处理：delta / completed / failed / error / 未知忽略。
/// `response.incomplete` 是 provider 特化点：OpenAI 保持 Phase 10C
/// 行为（忽略），DeepSeek 映射为结构化 incomplete 错误——差异由
/// `MappedEvent.incomplete` 交各 provider mapper 决定。
enum ResponsesStreamMapper {
    /// 中间映射结果：incomplete 单列，供 provider 特化。
    enum MappedEvent: Equatable {
        case agent(AgentEvent)
        case incomplete
        case ignored
    }

    /// 解析单个 SSE 事件的 data JSON 并分类。
    /// - Returns: nil = 未知 / 无需处理的事件（按规范忽略）。
    /// - Throws: `AgentProviderError`（error / response.failed 事件、
    ///   JSON 解码失败、delta 事件缺字段）。
    static func map(_ sseEvent: SSEEvent) throws -> MappedEvent {
        guard let data = sseEvent.data.data(using: .utf8) else {
            throw AgentProviderError.invalidResponse("event data is not valid UTF-8")
        }
        guard let decoded = try? JSONDecoder().decode(ResponsesStreamEvent.self, from: data) else {
            throw AgentProviderError.invalidResponse("malformed event JSON")
        }
        // event 名优先；缺失时回退 JSON `type` 字段。
        let eventName = sseEvent.event.isEmpty ? decoded.type : sseEvent.event
        switch eventName {
        case "response.output_text.delta":
            guard let delta = decoded.delta else {
                throw AgentProviderError.streamProtocol("delta event without delta field")
            }
            return .agent(.textDelta(delta))
        case "response.completed":
            return .agent(.completed)
        case "response.incomplete":
            return .incomplete
        case "response.failed":
            // 服务端在响应对象上报告失败（诊断日志只记安全字段）。
            AppLogger.agent.error("Agent provider stream failed: response.failed")
            throw AgentProviderError.serverError(statusCode: nil)
        case "error":
            AppLogger.agent.error("Agent provider stream error event: \(decoded.code ?? "unknown", privacy: .public)")
            throw AgentProviderError.serverError(statusCode: nil)
        default:
            // response.created / response.in_progress / output_item.* 等：
            // 未知或无需处理的事件，忽略。
            return .ignored
        }
    }
}

// MARK: - 传输核心

/// 共享 HTTP transport + SSE 解析循环（从 OpenAIResponsesProvider 纯移动，
/// 行为零变化）。Provider 薄壳只注入 `eventMapper`。
struct ResponsesProviderCore: AgentProvider {
    /// 请求启动时刻的不可变配置快照（任务书 §25 / Phase 10C-D §9）。
    let configuration: AgentProviderRequest

    /// 注入的 URLSession（测试经 URLProtocol stub 注入，100% offline）。
    let session: URLSession

    /// Provider 特化的 SSE 事件映射（共享映射 + provider 差异点）。
    /// `@Sendable`：provider 薄壳只注入无捕获的静态函数，满足 Swift 6
    /// 严格并发下 struct 的 Sendable 约束。
    let eventMapper: @Sendable (SSEEvent) throws -> AgentEvent?

    func stream(
        messages: [AgentMessage],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let body = ResponsesRequestBody(
                        model: configuration.model,
                        input: ResponsesRequestBody.input(
                            messages: messages,
                            context: context
                        ),
                        stream: true
                    )
                    let urlRequest = try Self.makeURLRequest(
                        configuration: configuration,
                        body: body
                    )
                    AppLogger.agent.info("Agent provider request started")

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    try Self.validate(response: response)

                    // SSE 解析：`bytes.lines` 会丢弃空行——而空行正是
                    // SSE 事件分隔符，必须按原始字节流组包。逐字节累计，
                    // 遇换行整行（含空行）喂入状态化 parser，覆盖「一个
                    // 事件跨多个网络 chunk」的组包逻辑。
                    let parser = SSEEventParser()
                    func dispatch(_ events: [SSEEvent]) throws {
                        for event in events {
                            if let agentEvent = try eventMapper(event) {
                                continuation.yield(agentEvent)
                            }
                        }
                    }
                    var pendingLine: [UInt8] = []
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        pendingLine.append(byte)
                        guard byte == 0x0A else { continue }
                        try dispatch(parser.feed(Data(pendingLine)))
                        pendingLine.removeAll(keepingCapacity: true)
                    }
                    // EOF：残余未换行字节宽容处理为最后一行，finish()
                    // 产出未以空行结尾的最后一个事件。
                    if !pendingLine.isEmpty {
                        try dispatch(parser.feed(Data(pendingLine)))
                    }
                    try dispatch(parser.finish())
                    continuation.finish()
                } catch let error as AgentProviderError {
                    if error == .cancelled {
                        AppLogger.agent.info("Agent provider stream cancelled")
                    }
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    AppLogger.agent.info("Agent provider stream cancelled")
                    continuation.finish(throwing: AgentProviderError.cancelled)
                } catch let urlError as URLError {
                    continuation.finish(throwing: Self.mapTransportError(urlError))
                } catch {
                    // 非预期错误一律收敛为 transport 分类，不向 UI 透传
                    // 任意错误描述（可能含敏感信息）。
                    continuation.finish(throwing: AgentProviderError.transport("unexpected transport failure"))
                }
            }
            // 消费方终止（Stop / 会话关闭 / Task 取消）→ 取消 producer
            // → URLSession 请求被取消，杜绝「UI 已 Stop 但 HTTP 仍在收 token」。
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    // MARK: - 请求构造

    private static func makeURLRequest(
        configuration: AgentProviderRequest,
        body: ResponsesRequestBody
    ) throws -> URLRequest {
        let baseURL = configuration.baseURL
        guard
            let scheme = baseURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw AgentProviderError.invalidBaseURL
        }
        let endpoint = baseURL.appending(path: ResponsesAPI.responsesPath)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - 响应校验（HTTP status 映射，两 provider 共享）

    private static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AgentProviderError.invalidResponse("non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            // 日志只记 status；绝不记 Authorization / Key / body。
            AppLogger.agent.error("Agent provider request failed: HTTP 401")
            throw AgentProviderError.unauthorized
        case 403:
            AppLogger.agent.error("Agent provider request failed: HTTP 403")
            throw AgentProviderError.forbidden
        case 429:
            AppLogger.agent.error("Agent provider request failed: HTTP 429")
            throw AgentProviderError.rateLimited
        case 500...599:
            AppLogger.agent.error("Agent provider request failed: HTTP \(http.statusCode, privacy: .public)")
            throw AgentProviderError.serverError(statusCode: http.statusCode)
        default:
            AppLogger.agent.error("Agent provider request failed: HTTP \(http.statusCode, privacy: .public)")
            throw AgentProviderError.invalidResponse("unexpected HTTP status \(http.statusCode)")
        }
    }

    private static func mapTransportError(_ error: URLError) -> AgentProviderError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .transport("timed out")
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .secureConnectionFailed:
            return .transport("connection failure")
        default:
            return .transport("transport failure")
        }
    }
}
