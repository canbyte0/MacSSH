import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 10C：OpenAIResponsesProvider 测试（任务书 §32）。
///
/// 全部经自定义 URLProtocol stub 注入（100% offline，任务书 §10 / §16）：
/// - 请求侧：endpoint / POST / Authorization / Content-Type / Accept /
///   stream=true / model / 有序多轮 history / 无 tools 字段；
/// - 流侧：增量 delta / completed / 401 / 403 / 429 / 500 / malformed SSE；
/// - 取消：Stop 取消消费 → 底层 URLSession 请求 stopLoading（§19 hard gate）；
/// - 超时：transport timeout 映射（§23）；
/// - 安全：错误信息绝不携带 API Key（§21）。
///
/// 测试 Key 固定使用 "test-api-key"（任务书 §32），绝不使用真实 Key。
final class OpenAIResponsesProviderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentProviderStubURLProtocol.reset()
    }

    override func tearDown() async throws {
        AgentProviderStubURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Stub URLProtocol

    /// URLProtocol stub：记录请求、按 handler 返回 (response, chunks)；
    /// neverFinish 模式不回调任何 client 方法（挂死连接——超时 / 取消测试）。
    ///
    /// Swift 6 strict concurrency：所有可变状态收进 `static let` 持有的
    /// `@unchecked Sendable` state box（内部 NSLock 保护），不使用
    /// static var 全局可变状态。
    final class AgentProviderStubURLProtocol: URLProtocol {
        private static let state = StubState()

        private final class StubState: @unchecked Sendable {
            private let lock = NSLock()
            private var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data]))?
            private var lastRequestValue: URLRequest?
            private var requestCountValue = 0
            private var stopLoadingCountValue = 0
            private var neverFinishValue = false

            func reset() {
                lock.lock()
                defer { lock.unlock() }
                handler = nil
                lastRequestValue = nil
                requestCountValue = 0
                stopLoadingCountValue = 0
                neverFinishValue = false
            }

            func install(
                _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, [Data])
            ) {
                lock.lock()
                defer { lock.unlock() }
                self.handler = handler
            }

            func setNeverFinish(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                neverFinishValue = value
            }

            var lastRequest: URLRequest? {
                lock.lock()
                defer { lock.unlock() }
                return lastRequestValue
            }

            var requestCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return requestCountValue
            }

            var stopLoadingCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return stopLoadingCountValue
            }

            /// 记录 startLoading 并在锁内取出当前 handler / neverFinish 快照。
            func recordStart(
                request: URLRequest
            ) -> (handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data]))?, neverFinish: Bool) {
                lock.lock()
                defer { lock.unlock() }
                requestCountValue += 1
                lastRequestValue = request
                return (handler, neverFinishValue)
            }

            func recordStop() {
                lock.lock()
                defer { lock.unlock() }
                stopLoadingCountValue += 1
            }
        }

        static func reset() {
            state.reset()
        }

        static func install(
            _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, [Data])
        ) {
            state.install(handler)
        }

        static func setNeverFinish(_ value: Bool) {
            state.setNeverFinish(value)
        }

        static var lastRequest: URLRequest? {
            state.lastRequest
        }

        static var requestCount: Int {
            state.requestCount
        }

        static var stopLoadingCount: Int {
            state.stopLoadingCount
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let snapshot = Self.state.recordStart(request: request)
            if snapshot.neverFinish {
                return
            }
            guard let handler = snapshot.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, chunks) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for chunk in chunks {
                    client?.urlProtocol(self, didLoad: chunk)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {
            Self.state.recordStop()
        }
    }

    // MARK: - 构造

    private let testAPIKey = "test-api-key"
    private let testBaseURL = URL(string: "https://api.openai.com/v1")!

    private func makeSession(timeout: TimeInterval = 60) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentProviderStubURLProtocol.self]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private func makeProvider(
        session: URLSession,
        model: String = "test-model",
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(
            configuration: AgentProviderRequest(
                model: model,
                baseURL: baseURL,
                apiKey: testAPIKey
            ),
            session: session
        )
    }

    private func makeMessages() -> [AgentMessage] {
        [
            AgentMessage(role: .user, content: "我叫 Alice"),
            AgentMessage(role: .assistant, content: "你好 Alice"),
            AgentMessage(role: .user, content: "我叫什么？"),
        ]
    }

    private func makeContext() -> AgentSessionContext {
        AgentSessionContext(
            sessionID: UUID(),
            kind: .local,
            displayName: "Local",
            currentDirectory: nil
        )
    }

    private static func httpResponse(statusCode: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private func collectEvents(
        from provider: AgentProvider
    ) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await event in provider.stream(messages: makeMessages(), context: makeContext()) {
            events.append(event)
        }
        return events
    }

    /// 成功 SSE 流（含 created 噪音事件 + 两个 delta + completed）。
    private func successSSEChunks() -> [Data] {
        let body = """
        event: response.created
        data: {"type":"response.created"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hello"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"，世界"}

        event: response.completed
        data: {"type":"response.completed"}

        """
        // 整体切成两半（事件边界处切开），验证跨 chunk 组包。
        let bytes = Array(body.utf8)
        let mid = bytes.count / 2
        return [Data(bytes[0..<mid]), Data(bytes[mid...])]
    }

    private func installSuccessHandler() {
        // handler 为 @Sendable——不得捕获非 Sendable 的 self（XCTestCase），
        // 所需值在闭包外取快照。
        let baseURL = testBaseURL
        let chunks = successSSEChunks()
        AgentProviderStubURLProtocol.install { request in
            (
                Self.httpResponse(statusCode: 200, url: request.url ?? baseURL),
                chunks
            )
        }
    }

    /// URLProtocol 下请求 body 经 httpBodyStream 传输；统一在此读出。
    private func requestBody(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func requestJSON(of request: URLRequest) throws -> [String: Any] {
        let body = requestBody(of: request)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("条件在 \(timeout)s 内未满足")
    }

    // MARK: - 请求侧（endpoint / method / headers / body）

    func testRequestEndpointMethodAndHeaders() async throws {
        installSuccessHandler()
        _ = try await collectEvents(from: makeProvider(session: makeSession()))

        let request = try XCTUnwrap(AgentProviderStubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(testAPIKey)"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "text/event-stream"
        )
    }

    func testRequestBodyModelStreamOrderedHistoryAndNoTools() async throws {
        installSuccessHandler()
        _ = try await collectEvents(from: makeProvider(session: makeSession()))

        let request = try XCTUnwrap(AgentProviderStubURLProtocol.lastRequest)
        let json = try requestJSON(of: request)

        // stream=true（任务书 §32）。
        XCTAssertEqual(json["stream"] as? Bool, true)
        // 请求使用启动时配置的 model（任务书 §9 / §25）。
        XCTAssertEqual(json["model"] as? String, "test-model")

        // 有序多轮 history（任务书 §6）：system context 前置 + user/assistant/user。
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 4, "system context + 3 轮消息")
        XCTAssertEqual(input[0]["role"] as? String, "system")
        let systemParts = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        let systemText = try XCTUnwrap(systemParts.first?["text"] as? String)
        XCTAssertTrue(
            systemText.contains("Current terminal target: Local"),
            "context 消息必须包含轻量 target 标识，实际：\(systemText)"
        )

        XCTAssertEqual(input[1]["role"] as? String, "user")
        XCTAssertEqual(input[2]["role"] as? String, "assistant")
        XCTAssertEqual(input[3]["role"] as? String, "user")

        func text(of message: [String: Any]) throws -> String {
            let parts = try XCTUnwrap(message["content"] as? [[String: Any]])
            return try XCTUnwrap(parts.first?["text"] as? String)
        }
        XCTAssertEqual(try text(of: input[1]), "我叫 Alice")
        XCTAssertEqual(try text(of: input[2]), "你好 Alice")
        XCTAssertEqual(try text(of: input[3]), "我叫什么？")

        // content part type：user= input_text，assistant 历史 = output_text。
        let assistantParts = try XCTUnwrap(input[2]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantParts.first?["type"] as? String, "output_text")

        // 硬性禁止字段（任务书 §28 hard gate）。
        let rawBody = String(decoding: requestBody(of: request), as: UTF8.self)
        for forbidden in ["tools", "tool_choice", "function", "functions", "previous_response_id"] {
            XCTAssertFalse(
                rawBody.contains("\"\(forbidden)\""),
                "request body 不得包含 \(forbidden)"
            )
        }
    }

    /// failed 消息不得进入 request history（partial 失败不是完整轮次）。
    func testFailedMessagesAreExcludedFromRequestBody() async throws {
        installSuccessHandler()
        var messages = makeMessages()
        messages[1] = AgentMessage(
            id: messages[1].id,
            role: .assistant,
            content: "partial broken",
            state: .failed,
            failure: .network
        )
        var events: [AgentEvent] = []
        for try await event in makeProvider(session: makeSession())
            .stream(messages: messages, context: makeContext()) {
            events.append(event)
        }

        let request = try XCTUnwrap(AgentProviderStubURLProtocol.lastRequest)
        let json = try requestJSON(of: request)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3, "system + user + user（failed assistant 排除）")
    }

    // MARK: - 流侧（delta / completed）

    func testTextDeltaDeliveryAndCompletion() async throws {
        installSuccessHandler()
        let events = try await collectEvents(from: makeProvider(session: makeSession()))

        XCTAssertEqual(
            events,
            [
                .textDelta("Hello"),
                .textDelta("，世界"),
                .completed,
            ],
            "必须增量转发 delta（created 噪音事件忽略），completed 收尾"
        )
    }

    // MARK: - HTTP 错误映射（任务书 §20）

    private func expectHTTPError(
        statusCode: Int,
        expected: AgentProviderError
    ) async throws {
        let baseURL = testBaseURL
        AgentProviderStubURLProtocol.install { request in
            (
                Self.httpResponse(statusCode: statusCode, url: request.url ?? baseURL),
                [Data(#"{"error":{"message":"bad key"}}"#.utf8)]
            )
        }
        do {
            _ = try await collectEvents(from: makeProvider(session: makeSession()))
            XCTFail("HTTP \(statusCode) 必须抛错")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, expected)
            // 错误信息绝不携带 API Key（任务书 §21 hard gate）。
            XCTAssertFalse(
                String(describing: error).contains(testAPIKey),
                "错误描述不得泄露 API Key"
            )
            XCTAssertFalse(
                String(describing: error).contains("bad key"),
                "错误描述不得透传 provider error body"
            )
        }
    }

    func testHTTP401MapsToUnauthorized() async throws {
        try await expectHTTPError(statusCode: 401, expected: .unauthorized)
    }

    func testHTTP403MapsToForbidden() async throws {
        try await expectHTTPError(statusCode: 403, expected: .forbidden)
    }

    func testHTTP429MapsToRateLimited() async throws {
        try await expectHTTPError(statusCode: 429, expected: .rateLimited)
    }

    func testHTTP500MapsToServerError() async throws {
        try await expectHTTPError(statusCode: 500, expected: .serverError(statusCode: 500))
    }

    // MARK: - malformed SSE

    func testMalformedSSEMapsToInvalidResponse() async throws {
        let baseURL = testBaseURL
        AgentProviderStubURLProtocol.install { request in
            (
                Self.httpResponse(statusCode: 200, url: request.url ?? baseURL),
                [Data("data: {broken json\n\n".utf8)]
            )
        }
        do {
            _ = try await collectEvents(from: makeProvider(session: makeSession()))
            XCTFail("malformed SSE 必须抛错")
        } catch let error as AgentProviderError {
            guard case .invalidResponse = error else {
                return XCTFail("应为 invalidResponse，实际 \(error)")
            }
            XCTAssertFalse(String(describing: error).contains(testAPIKey))
        }
    }

    // MARK: - 取消所有权（任务书 §19 hard gate）

    func testConsumerCancellationCancelsUnderlyingURLRequest() async throws {
        AgentProviderStubURLProtocol.setNeverFinish(true)
        let baseURL = testBaseURL
        AgentProviderStubURLProtocol.install { request in
            (Self.httpResponse(statusCode: 200, url: request.url ?? baseURL), [])
        }
        let provider = makeProvider(session: makeSession())
        let stream = provider.stream(messages: makeMessages(), context: makeContext())

        let consumer = Task {
            var events: [AgentEvent] = []
            do {
                for try await event in stream {
                    events.append(event)
                }
            } catch {
                // 预期 cancelled。
            }
            return events
        }

        // 等待请求真正发出后再取消（模拟 Stop）。
        try await waitUntil { AgentProviderStubURLProtocol.requestCount > 0 }
        consumer.cancel()

        // 底层 URLSession 请求必须被取消——禁止「UI 已 Stop 但 HTTP 仍在收 token」。
        try await waitUntil { AgentProviderStubURLProtocol.stopLoadingCount > 0 }
        let events = await consumer.value
        XCTAssertTrue(events.isEmpty, "取消后不得再收到任何 delta")
    }

    // MARK: - Transport timeout（任务书 §23）

    func testTransportTimeoutMapsToTransportError() async throws {
        // 传输层超时（连接后长时间无任何数据）：URLError.timedOut →
        // transport("timed out")——空闲超时由注入 session 的
        // timeoutIntervalForRequest 承担（新数据到达即重置），整个
        // generation 不设短固定超时，用户主动终止由 Stop 控制。
        AgentProviderStubURLProtocol.install { _ in
            throw URLError(.timedOut)
        }
        let provider = makeProvider(session: makeSession(timeout: 1.0))

        do {
            _ = try await collectEvents(from: provider)
            XCTFail("挂死连接必须超时")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .transport("timed out"))
            XCTAssertFalse(String(describing: error).contains(testAPIKey))
        }
    }

    // MARK: - Base URL 校验

    func testNonHTTPSchemeBaseURLIsRejected() async throws {
        let provider = makeProvider(
            session: makeSession(),
            baseURL: URL(string: "ftp://api.openai.com/v1")!
        )
        do {
            _ = try await collectEvents(from: provider)
            XCTFail("非 http(s) scheme 必须拒绝")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .invalidBaseURL)
        }
        XCTAssertEqual(AgentProviderStubURLProtocol.requestCount, 0, "不得发出任何请求")
    }

    // MARK: - ResolvingAgentProvider（任务书 §14 / §25 / §26）

    func testResolvingProviderWithoutKeyThrowsMissingCredentialAndSendsNoRequest() async throws {
        let namespace = "com.macssh.MacSSH.agent.tests.\(UUID().uuidString.lowercased())"
        let credentialService = AgentCredentialService(serviceNamespace: namespace)
        installSuccessHandler()

        let resolving = ResolvingAgentProvider(
            credentialService: credentialService,
            session: makeSession()
        )
        do {
            _ = try await collectEvents(from: resolving)
            XCTFail("未配置 Key 必须抛 missingCredential")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .missingCredential)
            XCTAssertEqual(error.displayKind, .missingCredential)
        }
        XCTAssertEqual(
            AgentProviderStubURLProtocol.requestCount,
            0,
            "未配置 Key 时绝不发出网络请求"
        )

        let state = await resolving.configurationState()
        XCTAssertEqual(state, .notConfigured)
        // 幂等清理测试 namespace。
        try await credentialService.deleteAPIKey(for: .openAI)
    }

    func testResolvingProviderUsesConfigurationSnapshotPerRequest() async throws {
        let namespace = "com.macssh.MacSSH.agent.tests.\(UUID().uuidString.lowercased())"
        let credentialService = AgentCredentialService(serviceNamespace: namespace)
        try await credentialService.upsertAPIKey(testAPIKey, for: .openAI)
        addTeardownBlock {
            try await credentialService.deleteAPIKey(for: .openAI)
        }
        installSuccessHandler()

        // 配置在两次请求之间变更：每次请求启动时读取一次快照。
        // settingsLoader 为 @Sendable——可变 model 经 @unchecked Sendable
        // box 传递（锁由测试串行调用保证，box 仅解决编译期捕获检查）。
        final class ModelBox: @unchecked Sendable {
            var value: String
            init(_ value: String) { self.value = value }
        }
        let currentModel = ModelBox("model-a")
        let resolving = ResolvingAgentProvider(
            settingsLoader: {
                AgentProviderSettings(
                    provider: .openAI,
                    model: currentModel.value,
                    baseURL: URL(string: "https://api.openai.com/v1")!
                )
            },
            credentialService: credentialService,
            session: makeSession()
        )

        _ = try await collectEvents(from: resolving)
        var json = try requestJSON(of: XCTUnwrap(AgentProviderStubURLProtocol.lastRequest))
        XCTAssertEqual(json["model"] as? String, "model-a")

        currentModel.value = "model-b"
        _ = try await collectEvents(from: resolving)
        json = try requestJSON(of: XCTUnwrap(AgentProviderStubURLProtocol.lastRequest))
        XCTAssertEqual(json["model"] as? String, "model-b", "下一次请求才使用新配置")

        let state = await resolving.configurationState()
        XCTAssertEqual(state, .ready)
    }
}
