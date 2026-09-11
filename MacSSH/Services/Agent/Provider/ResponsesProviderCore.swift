import Foundation

/// MacSSH 1.1 Phase 10C-D / 10D-B4：OpenAI / DeepSeek Responses API 共享
/// 传输核心（任务书 §3 / §4 / B4 §7–§13 / §19–§23 / §61–§62）。
///
/// 两个 provider 的 HTTP transport 与 SSE parsing 完全一致：
/// - 请求体结构：`{model, input, stream, tools, tool_choice}`（B4 §7：
///   tools 只含 function 类型；tool_choice 恒为 `auto`，§8）；
/// - input 是异构数组：message / function_call / function_call_output /
///   provider opaque item（§19：每轮从本地结构化 transcript 完整重建，
///   绝不把 Tool Result 伪装成普通 user message）；
/// - SSE 字节级组包循环（跨 chunk / EOF 宽容 flush）；
/// - function-call 流式组装（§11：Runtime 只接收完整 AgentToolCall）；
/// - HTTP status 映射与 transport 错误收敛；
/// - 取消所有权（onTermination → producer.cancel → data task 取消）。
///
/// Provider 差异点只经 `eventMapper` 注入（如 DeepSeek 对
/// `response.incomplete` 的结构化处理）。

// MARK: - Endpoint

enum ResponsesAPI {
    /// Responses endpoint 路径（追加到用户配置的 Base URL 之后）。
    /// OpenAI：`https://api.openai.com/v1` + `responses`；
    /// DeepSeek：`https://api.deepseek.com` + `responses`。
    static let responsesPath = "responses"
}

// MARK: - 请求体（B4 §7–§10 / §19–§23）

/// Responses API 请求体（B4：tools + tool_choice + 异构 input）。
struct ResponsesRequestBody: Encodable, Equatable {
    let model: String
    let input: [InputItem]
    let stream: Bool
    /// 仅 function tools（§7）；nil 时不序列化 tools 字段。
    let tools: [ToolDefinition]?
    /// 恒为 "auto"（§8：不 required、不给用户任意可编辑值）。
    let toolChoice: String?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
        case tools
        case toolChoice = "tool_choice"
    }

    /// Responses-format flat function tool definition（§9：
    /// provider-specific 线格式在此收敛，domain 只见
    /// `AgentToolDefinition`）。strict 字段省略——本地 validation 才是
    /// 安全边界（§9），不依赖 provider-side strict）。
    struct ToolDefinition: Encodable, Equatable, Sendable {
        let type = "function"
        let name: String
        let description: String
        let parameters: ResponsesJSONValue

        init(definition: AgentToolDefinition) throws {
            name = definition.name
            description = definition.description
            parameters = try ResponsesJSONValue.parse(definition.parametersJSON)
        }
    }

    /// input 数组元素（§19/§20/§21/§22/§23）。
    enum InputItem: Encodable, Equatable, Sendable {
        /// 普通消息（system context / user / assistant 文本）。
        case message(role: String, text: String, partType: String)
        /// assistant 发起的工具调用（call_id 配对身份，§14）。
        case functionCall(callID: String, name: String, arguments: String)
        /// 工具结果（§29：结构化 JSON string）。
        case functionCallOutput(callID: String, output: String)
        /// Provider opaque item verbatim 回放（reasoning 等，§22/§23：
        /// 已由调用方按 scope 过滤）。
        case providerRaw(ResponsesJSONValue)

        enum CodingKeys: String, CodingKey {
            case type
            case role
            case content
            case callID = "call_id"
            case name
            case arguments
            case output
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .message(let role, let text, let partType):
                try container.encode(role, forKey: .role)
                try container.encode(
                    [ContentPart(type: partType, text: text)],
                    forKey: .content
                )
            case .functionCall(let callID, let name, let arguments):
                try container.encode("function_call", forKey: .type)
                try container.encode(callID, forKey: .callID)
                try container.encode(name, forKey: .name)
                try container.encode(arguments, forKey: .arguments)
            case .functionCallOutput(let callID, let output):
                try container.encode("function_call_output", forKey: .type)
                try container.encode(callID, forKey: .callID)
                try container.encode(output, forKey: .output)
            case .providerRaw(let value):
                try value.encode(to: encoder)
            }
        }
    }

    /// content part（消息形态的 input 元素）。
    struct ContentPart: Encodable, Equatable, Sendable {
        let type: String
        let text: String
    }

    /// 从本地结构化 transcript 完整重建 input（§19 hard gate）：
    /// - system context 消息前置（轻量 target 标识）；
    /// - failed 文本消息排除（partial 失败不是完整对话轮次）；
    /// - tool 条目输出为严格配对的
    ///   `function_call` + `function_call_output`（§14/§58）；
    /// - provider continuation item 只回放同 scope 的（§53 hard gate：
    ///   绝不把 OpenAI raw item 塞给 DeepSeek，反之亦然）。
    static func inputItems(
        transcript: [AgentMessage],
        context: AgentSessionContext,
        providerScope: AgentProviderScope
    ) -> [InputItem] {
        var result: [InputItem] = []
        if let contextMessage = Self.contextMessage(for: context) {
            result.append(contextMessage)
        }
        var index = 0
        while index < transcript.count {
            let message = transcript[index]
            switch message.content {
            case .text(let text):
                guard message.state != .failed, !text.isEmpty else {
                    index += 1
                    continue
                }
                result.append(
                    .message(
                        role: message.role.apiRole,
                        text: text,
                        partType: message.role.contentPartType
                    )
                )
                index += 1
            case .tool:
                // 同一 tool turn 的连续 tool card：先输出全部 function_call，
                // 再输出全部 function_call_output（分组）。
                //
                // 这是 DeepSeek 思考模式的硬要求（thinking mode + tools：
                // 服务端对**末尾** tool turn 做「reasoning_text 是否回传」
                // 校验时按 function_call 连续块回溯；交错顺序
                // `fc1, fco1, fc2, fco2` 会让校验在 fco1 处中断并误判
                // reasoning 缺失 → HTTP 400）。分组顺序同时是 OpenAI
                // Responses parallel tool calls 的标准回放形态。
                var run: [AgentToolActivity] = []
                while index < transcript.count,
                      case .tool(let activity) = transcript[index].content {
                    run.append(activity)
                    index += 1
                }
                for activity in run {
                    result.append(
                        .functionCall(
                            callID: activity.callID,
                            name: activity.toolName,
                            arguments: activity.argumentsJSON
                        )
                    )
                }
                for activity in run {
                    result.append(
                        .functionCallOutput(
                            callID: activity.callID,
                            // 执行完成前被中断（Stop / fatal）：结构化
                            // cancelled 输出保证 call_id 配对恒成立
                            // （§14/§45/§47）。
                            output: activity.resultJSON
                                ?? #"{"ok":false,"error":"cancelled"}"#
                        )
                    )
                }
            case .providerContinuation(let item):
                if item.providerScope == providerScope,
                   let raw = try? ResponsesJSONValue.parse(item.itemJSON) {
                    // Phase 10D-B4-R1 live 定位（DeepSeek thinking mode）：
                    // 同一 assistant 轮次内 reasoning item 必须先于 assistant
                    // 文本消息回放。UI 时间线里 streaming placeholder 先于
                    // 流式 reasoning item 存在，回放 [text, reasoning, calls]
                    // 会被服务端拒绝（400 "The `reasoning_text` in the
                    // thinking mode must be passed back to the API."），
                    // [reasoning, text, calls] 通过（proxy 抓包对照 + 真实
                    // API 变体实验确认）。因此仅当 reasoning 紧跟 assistant
                    // 文本消息时把它前移一位；其余位置（纯 tool 轮次等）
                    // 保持不变。
                    if item.kind == "reasoning",
                       let last = result.last,
                       case .message(let role, _, _) = last,
                       role == "assistant" {
                        result.insert(.providerRaw(raw), at: result.count - 1)
                    } else {
                        result.append(.providerRaw(raw))
                    }
                }
                index += 1
            }
        }
        return result
    }

    /// 轻量 context（不读 terminal buffer / scrollback / selection /
    /// shell env / SSH credentials；文件内容只能来自真实 tool call，§85）。
    private static func contextMessage(for context: AgentSessionContext) -> InputItem? {
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
        return .message(
            role: "system",
            text: line,
            partType: "input_text"
        )
    }
}

private extension AgentMessage.Role {
    /// Responses API 的 role 名称（tool card / continuation item 不走
    /// message 形态，无需 role）。
    var apiRole: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        case .tool: return "assistant"
        }
    }

    /// content part type：user / system 用 input_text；
    /// assistant 历史（模型上一轮输出）用 output_text。
    var contentPartType: String {
        switch self {
        case .user, .system: return "input_text"
        case .assistant, .tool: return "output_text"
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
    // B4 function-call 组装事件（§11/§61/§62）。
    var item: ResponsesOutputItem?
    var itemID: String?
    var arguments: String?

    enum CodingKeys: String, CodingKey {
        case type
        case delta
        case code
        case message
        case item
        case itemID = "item_id"
        case arguments
    }
}

/// SSEEvent → MappedEvent 共享映射（Phase 10C-D 任务书 §2 / §4 / B4 §11）。
///
/// 共享处理：text delta / completed / failed / error / function-call
/// 事件 / 未知忽略。`response.incomplete` 是 provider 特化点：OpenAI
/// 忽略，DeepSeek 映射为结构化 incomplete 错误——差异由 provider
/// mapper 决定（core 不做 incomplete 判定）。
enum ResponsesStreamMapper {
    /// 中间映射结果（B4 扩展：function-call / output-item 事件单列，
    /// 由 core 的 assembler 消费）。
    enum MappedEvent: Equatable {
        case agent(AgentEvent)
        case incomplete
        case ignored
        case functionCallArgumentsDelta(itemID: String, delta: String)
        case functionCallArgumentsDone(itemID: String, arguments: String)
        case outputItemAdded(ResponsesOutputItem)
        case outputItemDone(ResponsesOutputItem)
    }

    /// 解析单个 SSE 事件的 data JSON 并分类。
    /// - Returns: `.ignored` = 未知 / 无需处理的事件（按规范忽略）。
    /// - Throws: `AgentProviderError`（error / response.failed 事件、
    ///   JSON 解码失败、delta 事件缺字段、function-call 事件缺字段）。
    static func map(_ sseEvent: SSEEvent) throws -> MappedEvent {
        guard let data = sseEvent.data.data(using: .utf8) else {
            throw AgentProviderError.invalidResponse("event data is not valid UTF-8")
        }
        let decoded: ResponsesStreamEvent
        do {
            decoded = try JSONDecoder().decode(ResponsesStreamEvent.self, from: data)
        } catch {
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
        case "response.function_call_arguments.delta":
            guard let itemID = decoded.itemID, let delta = decoded.delta else {
                throw AgentProviderError.streamProtocol("function_call_arguments.delta without item_id or delta")
            }
            return .functionCallArgumentsDelta(itemID: itemID, delta: delta)
        case "response.function_call_arguments.done":
            guard let itemID = decoded.itemID else {
                throw AgentProviderError.streamProtocol("function_call_arguments.done without item_id")
            }
            // arguments 允许空串，但字段本身必须存在。
            guard let arguments = decoded.arguments else {
                throw AgentProviderError.streamProtocol("function_call_arguments.done without arguments")
            }
            return .functionCallArgumentsDone(itemID: itemID, arguments: arguments)
        case "response.output_item.added":
            return try mapOutputItem(decoded, kind: .added)
        case "response.output_item.done":
            return try mapOutputItem(decoded, kind: .done)
        default:
            // response.created / response.in_progress /
            // reasoning_summary_text.* 等未知或无需处理的事件：忽略。
            return .ignored
        }
    }

    private static func mapOutputItem(
        _ decoded: ResponsesStreamEvent,
        kind: OutputItemKind
    ) throws -> MappedEvent {
        guard let item = decoded.item else {
            throw AgentProviderError.streamProtocol("output_item event without item")
        }
        // 只关心 function_call 与 reasoning；message 等其它 item 的文本
        // 已由 output_text.delta 事件承载。
        switch item.type {
        case "function_call", "reasoning":
            switch kind {
            case .added:
                return .outputItemAdded(item)
            case .done:
                return .outputItemDone(item)
            }
        default:
            return .ignored
        }
    }

    private enum OutputItemKind {
        case added
        case done
    }
}

// MARK: - 传输核心

/// 共享 HTTP transport + SSE 解析 + function-call 组装循环。
/// Provider 薄壳注入 `eventMapper`（provider 差异点）与 `providerScope`。
struct ResponsesProviderCore: AgentProvider {
    /// 请求启动时刻的不可变配置快照（任务书 §25 / Phase 10C-D §9 /
    /// B4 §54：provider / model / baseURL / credential 全部来自快照，
    /// generation 中途绝不切换）。
    let configuration: AgentProviderRequest

    /// 注入的 URLSession（测试经 URLProtocol stub 注入，100% offline）。
    let session: URLSession

    /// Provider 身份（B4 §23/§53：opaque continuation item 的 scope 标注）。
    let providerScope: AgentProviderScope

    /// Provider 特化的 SSE 事件映射（共享映射 + provider 差异点）。
    /// `@Sendable`：provider 薄壳只注入无捕获的静态函数。
    let eventMapper: @Sendable (SSEEvent) throws -> ResponsesStreamMapper.MappedEvent

    func stream(
        transcript: [AgentMessage],
        tools: [AgentToolDefinition],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let body = try Self.makeRequestBody(
                        configuration: configuration,
                        transcript: transcript,
                        tools: tools,
                        context: context,
                        providerScope: providerScope
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
                    let assembler = ResponsesFunctionCallAssembler(providerScope: providerScope)
                    func dispatch(_ events: [SSEEvent]) throws {
                        for event in events {
                            switch try eventMapper(event) {
                            case .agent(let agentEvent):
                                continuation.yield(agentEvent)
                            case .incomplete, .ignored:
                                break
                            case .functionCallArgumentsDelta(let itemID, let delta):
                                try assembler.appendArgumentsDelta(itemID: itemID, delta: delta)
                            case .functionCallArgumentsDone(let itemID, let arguments):
                                try assembler.recordArgumentsDone(itemID: itemID, arguments: arguments)
                            case .outputItemAdded(let item):
                                try assembler.registerItemAdded(item)
                            case .outputItemDone(let item):
                                for agentEvent in try assembler.finalizeItem(item) {
                                    continuation.yield(agentEvent)
                                }
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

    private static func makeRequestBody(
        configuration: AgentProviderRequest,
        transcript: [AgentMessage],
        tools: [AgentToolDefinition],
        context: AgentSessionContext,
        providerScope: AgentProviderScope
    ) throws -> ResponsesRequestBody {
        let toolDefinitions = try tools.map(ResponsesRequestBody.ToolDefinition.init(definition:))
        return ResponsesRequestBody(
            model: configuration.model,
            input: ResponsesRequestBody.inputItems(
                transcript: transcript,
                context: context,
                providerScope: providerScope
            ),
            stream: true,
            tools: toolDefinitions.isEmpty ? nil : toolDefinitions,
            toolChoice: toolDefinitions.isEmpty ? nil : "auto"
        )
    }

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
