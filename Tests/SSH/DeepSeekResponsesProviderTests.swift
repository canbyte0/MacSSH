import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 10C-D：DeepSeekResponsesProvider 测试（任务书 §14 / §15）。
///
/// 全部经自定义 URLProtocol stub 注入（100% offline）：
/// - 请求侧：endpoint `https://api.deepseek.com/responses`（Base URL 不带
///   /v1，任务书 §1）、POST / Authorization Bearer / stream=true / model /
///   有序多轮 history / 无 tools / 无 previous_response_id；
/// - 流侧：delta / completed / incomplete（结构化错误）/ failed /
///   未知事件忽略 / 401 / 403 / 429 / 500 / malformed SSE；
/// - 取消：Stop 取消消费 → 底层 URLSession 请求 stopLoading；
/// - 安全：错误信息绝不携带 API Key；
/// - Resolver 凭据隔离（任务书 §15）：DeepSeek Key 只发给 DeepSeek，
///   绝不发给 OpenAI（P1 hard gate）。
///
/// 测试 Key 固定使用 fake 值（openai-test-key / deepseek-test-key），
/// 绝不使用真实 Key。
final class DeepSeekResponsesProviderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeepSeekStubURLProtocol.reset()
    }

    override func tearDown() async throws {
        DeepSeekStubURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Stub URLProtocol（结构同 AgentProviderStubURLProtocol，
    // 本文件独立持有，避免跨测试类共享可变状态）

    final class DeepSeekStubURLProtocol: URLProtocol {
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

    private let testAPIKey = "deepseek-test-key"
    private let testBaseURL = URL(string: "https://api.deepseek.com")!

    private func makeSession(timeout: TimeInterval = 60) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekStubURLProtocol.self]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private func makeProvider(
        session: URLSession,
        model: String = "deepseek-v4-flash",
        baseURL: URL = URL(string: "https://api.deepseek.com")!
    ) -> DeepSeekResponsesProvider {
        DeepSeekResponsesProvider(
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
            AgentMessage(role: .user, content: "记住这个数字：7319"),
            AgentMessage(role: .assistant, content: "好的，7319"),
            AgentMessage(role: .user, content: "数字是多少？"),
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
        for try await event in provider.stream(
            transcript: makeMessages(),
            tools: AgentToolCatalog.definitions,
            context: makeContext()
        ) {
            events.append(event)
        }
        return events
    }

    /// 成功 SSE 流（semantic events：created / in_progress 噪音 + 两个
    /// delta + completed；DeepSeek 无 [DONE]，任务书 §2）。
    private func successSSEChunks() -> [Data] {
        let body = """
        event: response.created
        data: {"type":"response.created"}

        event: response.in_progress
        data: {"type":"response.in_progress"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"你好"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"，MacSSH"}

        event: response.completed
        data: {"type":"response.completed"}

        """
        let bytes = Array(body.utf8)
        let mid = bytes.count / 2
        return [Data(bytes[0..<mid]), Data(bytes[mid...])]
    }

    private func installSuccessHandler() {
        let baseURL = testBaseURL
        let chunks = successSSEChunks()
        DeepSeekStubURLProtocol.install { request in
            (
                Self.httpResponse(statusCode: 200, url: request.url ?? baseURL),
                chunks
            )
        }
    }

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

    // MARK: - 请求侧（endpoint / method / headers / body，任务书 §14）

    func testRequestEndpointMethodAndHeaders() async throws {
        installSuccessHandler()
        _ = try await collectEvents(from: makeProvider(session: makeSession()))

        let request = try XCTUnwrap(DeepSeekStubURLProtocol.lastRequest)
        // Base URL 不带 /v1（任务书 §1）：endpoint = https://api.deepseek.com/responses。
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/responses")
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

    /// Phase 10C-D-R §5：fresh DeepSeek 默认路径的 hard assertion——
    /// 不是手工传入 model，而是走 `AgentProviderSettings.load` 归一化
    /// （隔离 UserDefaults 只存 provider=deepseek，模拟 fresh install
    /// 只选 Provider 不改 Model）→ resolver → 序列化请求必须携带
    /// `"model": "deepseek-v4-flash"`。
    func testFreshDeepSeekDefaultRequestUsesV4Flash() async throws {
        let suiteName = "macssh.agent.resolver.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            AgentProviderSettings.Provider.deepSeek.rawValue,
            forKey: AgentProviderSettings.Keys.provider
        )

        let credentialService = makeIsolatedCredentialService()
        try await credentialService.upsertAPIKey(testAPIKey, for: .deepSeek)
        addTeardownBlock {
            try await credentialService.deleteAPIKey(for: .deepSeek)
        }
        installSuccessHandler()

        let settings = AgentProviderSettings.load(from: defaults)
        let resolver = ResolvingAgentProvider(
            settingsLoader: { settings },
            credentialService: credentialService,
            session: makeSession()
        )
        _ = try await collectEvents(from: resolver)

        let request = try XCTUnwrap(DeepSeekStubURLProtocol.lastRequest)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.deepseek.com/responses",
            "fresh 默认路径必须发往 DeepSeek 官方 endpoint"
        )
        let json = try requestJSON(of: request)
        XCTAssertEqual(
            json["model"] as? String,
            "deepseek-v4-flash",
            "fresh DeepSeek 默认请求必须携带 deepseek-v4-flash（Phase 10C-D-R §5）"
        )
    }

    func testRequestBodyModelStreamOrderedHistoryAndNoForbiddenFields() async throws {
        installSuccessHandler()
        _ = try await collectEvents(
            from: makeProvider(session: makeSession(), model: "deepseek-v4-pro")
        )

        let request = try XCTUnwrap(DeepSeekStubURLProtocol.lastRequest)
        let json = try requestJSON(of: request)

        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-pro")

        // 有序多轮 history：system context 前置 + user/assistant/user。
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
        XCTAssertEqual(try text(of: input[1]), "记住这个数字：7319")
        XCTAssertEqual(try text(of: input[2]), "好的，7319")
        XCTAssertEqual(try text(of: input[3]), "数字是多少？")

        // B4 §7/§10 hard gate：DeepSeek Responses 与 OpenAI 同构——
        // tools 只含 4 个 read-only function 工具 + tool_choice=auto；
        // 禁用字段（server-side state / 危险工具名）绝不出现。
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 4)
        XCTAssertEqual(
            Set(tools.compactMap { $0["type"] as? String }),
            ["function"]
        )
        XCTAssertEqual(
            Set(tools.compactMap { $0["name"] as? String }),
            Set(AgentToolCatalog.names)
        )
        XCTAssertEqual(json["tool_choice"] as? String, "auto")

        let rawBody = String(decoding: requestBody(of: request), as: UTF8.self)
        for forbidden in [
            "web_search", "file_search", "computer", "code_interpreter",
            "previous_response_id", "conversation", "run_command",
            "write_file", "delete_file", "mkdir", "git_status",
        ] {
            XCTAssertFalse(
                rawBody.contains("\"\(forbidden)\""),
                "request body 不得包含 \(forbidden)"
            )
        }
    }

    // MARK: - 流侧（delta / completed / incomplete / failed / 未知，任务书 §2）

    func testTextDeltaDeliveryAndCompletion() async throws {
        installSuccessHandler()
        let events = try await collectEvents(from: makeProvider(session: makeSession()))

        XCTAssertEqual(
            events,
            [
                .textDelta("你好"),
                .textDelta("，MacSSH"),
                .completed,
            ],
            "必须增量转发 delta（created / in_progress 噪音事件忽略），completed 收尾"
        )
    }

    func testIncompleteEventThrowsStructuredIncompleteError() async throws {
        let baseURL = testBaseURL
        DeepSeekStubURLProtocol.install { request in
            (
                Self.httpResponse(statusCode: 200, url: request.url ?? baseURL),
                [
                    Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"部分内容\"}\n\n".utf8),
                    Data("event: response.incomplete\ndata: {\"type\":\"response.incomplete\"}\n\n".utf8),
                ]
            )
        }
        do {
            _ = try await collectEvents(from: makeProvider(session: makeSession()))
            XCTFail("response.incomplete 必须抛结构化错误")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .incompleteResponse)
            XCTAssertEqual(error.displayKind, .incomplete)
            // 错误信息绝不携带 API Key（任务书 §14 hard gate）。
            XCTAssertFalse(String(describing: error).contains(testAPIKey))
        }
    }

    func testResponseFailedEventThrowsServerError() async throws {
        let baseURL = testBaseURL
        DeepSeekStubURLProtocol.install { request in
            (
                Self.httpResponse(statusCode: 200, url: request.url ?? baseURL),
                [Data("event: response.failed\ndata: {\"type\":\"response.failed\"}\n\n".utf8)]
            )
        }
        do {
            _ = try await collectEvents(from: makeProvider(session: makeSession()))
            XCTFail("response.failed 必须抛错")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .serverError(statusCode: nil))
            XCTAssertFalse(String(describing: error).contains(testAPIKey))
        }
    }

    func testUnknownEventIsIgnored() async throws {
        let baseURL = testBaseURL
        DeepSeekStubURLProtocol.install { request in
            (
                Self.httpResponse(statusCode: 200, url: request.url ?? baseURL),
                [
                    Data("event: custom.deepseek.event\ndata: {\"type\":\"custom.deepseek.event\"}\n\n".utf8),
                    Data("event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n".utf8),
                ]
            )
        }
        // 未知事件忽略、不 crash，completed 正常收尾。
        let events = try await collectEvents(from: makeProvider(session: makeSession()))
        XCTAssertEqual(events, [.completed])
    }

    // MARK: - HTTP 错误映射（任务书 §14）

    private func expectHTTPError(
        statusCode: Int,
        expected: AgentProviderError
    ) async throws {
        let baseURL = testBaseURL
        DeepSeekStubURLProtocol.install { request in
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

    // MARK: - malformed stream

    func testMalformedSSEMapsToInvalidResponse() async throws {
        let baseURL = testBaseURL
        DeepSeekStubURLProtocol.install { request in
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

    // MARK: - 取消所有权（任务书 §14）

    func testConsumerCancellationCancelsUnderlyingURLRequest() async throws {
        DeepSeekStubURLProtocol.setNeverFinish(true)
        let baseURL = testBaseURL
        DeepSeekStubURLProtocol.install { request in
            (Self.httpResponse(statusCode: 200, url: request.url ?? baseURL), [])
        }
        let provider = makeProvider(session: makeSession())
        let stream = provider.stream(
            transcript: makeMessages(),
            tools: AgentToolCatalog.definitions,
            context: makeContext()
        )

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

        try await waitUntil { DeepSeekStubURLProtocol.requestCount > 0 }
        consumer.cancel()

        try await waitUntil { DeepSeekStubURLProtocol.stopLoadingCount > 0 }
        let events = await consumer.value
        XCTAssertTrue(events.isEmpty, "取消后不得再收到任何 delta")
    }

    // MARK: - ResolvingAgentProvider 凭据隔离（任务书 §15，P1 hard gate）

    private func makeResolver(
        provider: AgentProviderSettings.Provider,
        credentialService: AgentCredentialService,
        session: URLSession
    ) -> ResolvingAgentProvider {
        let settings = AgentProviderSettings(
            provider: provider,
            model: provider.defaultModel,
            baseURL: provider.defaultBaseURL
        )
        return ResolvingAgentProvider(
            settingsLoader: { settings },
            credentialService: credentialService,
            session: session
        )
    }

    private func makeIsolatedCredentialService() -> AgentCredentialService {
        let namespace = "com.macssh.MacSSH.agent.tests.\(UUID().uuidString.lowercased())"
        return AgentCredentialService(serviceNamespace: namespace)
    }

    func testResolverUsesDeepSeekCredentialOnlyForDeepSeek() async throws {
        let credentialService = makeIsolatedCredentialService()
        try await credentialService.upsertAPIKey("deepseek-test-key", for: .deepSeek)
        try await credentialService.upsertAPIKey("openai-test-key", for: .openAI)
        addTeardownBlock {
            try await credentialService.deleteAPIKey(for: .deepSeek)
            try await credentialService.deleteAPIKey(for: .openAI)
        }
        installSuccessHandler()

        let resolver = makeResolver(
            provider: .deepSeek,
            credentialService: credentialService,
            session: makeSession()
        )
        _ = try await collectEvents(from: resolver)

        let request = try XCTUnwrap(DeepSeekStubURLProtocol.lastRequest)
        // DeepSeek 请求只携带 DeepSeek Key，发往 DeepSeek endpoint。
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer deepseek-test-key"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/responses")

        let state = await resolver.configurationState()
        XCTAssertEqual(state, .ready)
    }

    func testResolverNeverSendsDeepSeekCredentialToOpenAI() async throws {
        let credentialService = makeIsolatedCredentialService()
        try await credentialService.upsertAPIKey("deepseek-test-key", for: .deepSeek)
        try await credentialService.upsertAPIKey("openai-test-key", for: .openAI)
        addTeardownBlock {
            try await credentialService.deleteAPIKey(for: .deepSeek)
            try await credentialService.deleteAPIKey(for: .openAI)
        }
        installSuccessHandler()

        // OpenAI provider 的请求必须携带 OpenAI Key（绝不是 DeepSeek Key）。
        let resolver = makeResolver(
            provider: .openAI,
            credentialService: credentialService,
            session: makeSession()
        )
        _ = try await collectEvents(from: resolver)

        let request = try XCTUnwrap(DeepSeekStubURLProtocol.lastRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer openai-test-key",
            "OpenAI 请求绝不携带 DeepSeek Key（任务书 §7 P1 hard gate）"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
    }

    func testResolverWithoutDeepSeekKeyThrowsMissingCredential() async throws {
        let credentialService = makeIsolatedCredentialService()
        addTeardownBlock {
            try await credentialService.deleteAPIKey(for: .deepSeek)
        }
        installSuccessHandler()

        let resolver = makeResolver(
            provider: .deepSeek,
            credentialService: credentialService,
            session: makeSession()
        )
        do {
            _ = try await collectEvents(from: resolver)
            XCTFail("未配置 DeepSeek Key 必须抛 missingCredential")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .missingCredential)
        }
        XCTAssertEqual(
            DeepSeekStubURLProtocol.requestCount,
            0,
            "未配置 Key 时绝不发出网络请求"
        )

        let state = await resolver.configurationState()
        XCTAssertEqual(state, .notConfigured)
    }
}
