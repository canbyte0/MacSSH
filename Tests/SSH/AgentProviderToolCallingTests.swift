import XCTest

@testable import MacSSH

/// B4 §63/§64/§65：Responses function-call 流式组装 + continuation 重建测试
/// （OpenAI / DeepSeek 双 provider，100% offline URLProtocol stub）。
///
/// 覆盖：
/// - 单 call（arguments 跨多 delta 拼接）；
/// - 并行两 call（全部保留、按 output order）；
/// - text + call / call + final text；
/// - invalid JSON arguments（组装层原样透传，validation 在 loop 层）；
/// - duplicate call_id → streamProtocol（§15）；
/// - incomplete call（无 done）→ 绝不产出 toolCall（§59）；
/// - response.failed / response.incomplete → 结构化错误（§60）；
/// - unknown tool（组装层放行，执行层拒绝，§51）；
/// - function_call_output continuation 重建（§19/§58）；
/// - reasoning item 捕获 + 回放（§22/§65）+ 跨 provider 隔离（§53）；
/// - done 与累计 delta 不一致 → streamProtocol（§12）；
/// - cancel（Stop）→ 底层 URLSession 请求取消。
final class AgentProviderToolCallingTests: XCTestCase {

    // MARK: - Stub URLProtocol

    final class AgentToolCallingStubURLProtocol: URLProtocol {
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

        static func reset() { state.reset() }
        static func install(
            _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, [Data])
        ) {
            state.install(handler)
        }
        static func setNeverFinish(_ value: Bool) { state.setNeverFinish(value) }
        static var lastRequest: URLRequest? { state.lastRequest }
        static var requestCount: Int { state.requestCount }
        static var stopLoadingCount: Int { state.stopLoadingCount }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let snapshot = Self.state.recordStart(request: request)
            if snapshot.neverFinish { return }
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

    override func setUp() {
        super.setUp()
        AgentToolCallingStubURLProtocol.reset()
    }

    override func tearDown() {
        AgentToolCallingStubURLProtocol.reset()
        super.tearDown()
    }

    private let testAPIKey = "b4-test-key"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentToolCallingStubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    private func makeOpenAIProvider() -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(
            configuration: AgentProviderRequest(
                model: "test-model",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: testAPIKey
            ),
            session: makeSession()
        )
    }

    private func makeDeepSeekProvider() -> DeepSeekResponsesProvider {
        DeepSeekResponsesProvider(
            configuration: AgentProviderRequest(
                model: "deepseek-test-model",
                baseURL: URL(string: "https://api.deepseek.com")!,
                apiKey: testAPIKey
            ),
            session: makeSession()
        )
    }

    private func makeMessages() -> [AgentMessage] {
        [AgentMessage(role: .user, content: "读取 README.md 并总结")]
    }

    private func makeContext() -> AgentSessionContext {
        AgentSessionContext(
            sessionID: UUID(),
            kind: .local,
            displayName: "Local",
            currentDirectory: "file://localhost/tmp/project"
        )
    }

    private static func httpResponse(statusCode: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil
        )!
    }

    private func installSSE(_ body: String, splitIntoChunks: Int = 1) {
        let baseURL = URL(string: "https://stub.invalid")!
        var built: [Data] = []
        if splitIntoChunks <= 1 {
            built = [Data(body.utf8)]
        } else {
            let bytes = Array(body.utf8)
            let size = max(1, bytes.count / splitIntoChunks)
            var index = 0
            while index < bytes.count {
                let end = min(index + size, bytes.count)
                built.append(Data(bytes[index..<end]))
                index = end
            }
        }
        let chunks = built
        AgentToolCallingStubURLProtocol.install { request in
            (Self.httpResponse(statusCode: 200, url: request.url ?? baseURL), chunks)
        }
    }

    private func collectEvents(
        from provider: AgentProvider,
        transcript: [AgentMessage]? = nil
    ) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await event in provider.stream(
            transcript: transcript ?? makeMessages(),
            tools: AgentToolCatalog.definitions,
            context: makeContext()
        ) {
            events.append(event)
        }
        return events
    }

    private func requestBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
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
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody(of: request)) as? [String: Any]
        )
    }

    // MARK: - SSE fixtures

    /// 单 call：arguments 拆成两个 delta。
    private static let singleCallSSE = #"""
    event: response.created
    data: {"type":"response.created"}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_abc","name":"read_file","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"{\"pa"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"th\":\"README.md\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":1,"arguments":"{\"path\":\"README.md\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_abc","name":"read_file","arguments":"{\"path\":\"README.md\"}"}}

    event: response.completed
    data: {"type":"response.completed"}

    """#

    private static let expectedSingleCall = AgentProviderToolCall(
        callID: "call_abc",
        name: "read_file",
        argumentsJSON: #"{"path":"README.md"}"#
    )

    // MARK: - §11/§12/§62 单 call 组装（OpenAI）

    func testOpenAISingleCallIsAssembledFromDeltas() async throws {
        installSSE(Self.singleCallSSE, splitIntoChunks: 7)
        let events = try await collectEvents(from: makeOpenAIProvider())
        XCTAssertEqual(events, [.toolCall(Self.expectedSingleCall), .completed])
    }

    func testDeepSeekSingleCallIsAssembledFromDeltas() async throws {
        installSSE(Self.singleCallSSE, splitIntoChunks: 5)
        let events = try await collectEvents(from: makeDeepSeekProvider())
        XCTAssertEqual(events, [.toolCall(Self.expectedSingleCall), .completed])
    }

    // MARK: - §13 并行两 call（全部保留，output order）

    func testParallelCallsAreBothEmittedInOutputOrder() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_2","call_id":"call_2","name":"list_directory","arguments":""}}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"path\":\"a.txt\"}"}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_2","arguments":"{\"path\":\".\"}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"a.txt\"}"}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_2","call_id":"call_2","name":"list_directory","arguments":"{\"path\":\".\"}"}}

        event: response.completed
        data: {"type":"response.completed"}

        """#
        installSSE(sse)
        let events = try await collectEvents(from: makeOpenAIProvider())
        XCTAssertEqual(
            events,
            [
                .toolCall(AgentProviderToolCall(callID: "call_1", name: "read_file", argumentsJSON: #"{"path":"a.txt"}"#)),
                .toolCall(AgentProviderToolCall(callID: "call_2", name: "list_directory", argumentsJSON: #"{"path":"."}"#)),
                .completed,
            ],
            "同一 response 的多个 function call 必须全部保留（§13），且按 output order"
        )
    }

    // MARK: - §49 text + call / call + final text

    func testTextThenCallKeepsPartialTextFirst() async throws {
        let sse = #"""
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"让我看看文件…"}

        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"path\":\"x\"}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"x\"}"}}

        event: response.completed
        data: {"type":"response.completed"}

        """#
        installSSE(sse)
        let events = try await collectEvents(from: makeOpenAIProvider())
        XCTAssertEqual(
            events,
            [
                .textDelta("让我看看文件…"),
                .toolCall(AgentProviderToolCall(callID: "call_1", name: "read_file", argumentsJSON: #"{"path":"x"}"#)),
                .completed,
            ]
        )
    }

    func testCallThenFinalTextKeepsBoth() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{}"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"已经读取完成。"}

        event: response.completed
        data: {"type":"response.completed"}

        """#
        installSSE(sse)
        let events = try await collectEvents(from: makeOpenAIProvider())
        XCTAssertEqual(
            events,
            [
                .toolCall(AgentProviderToolCall(callID: "call_1", name: "read_file", argumentsJSON: "{}")),
                .textDelta("已经读取完成。"),
                .completed,
            ]
        )
    }

    // MARK: - invalid JSON arguments（组装层原样透传，validation 在 loop §6）

    func testInvalidJSONArgumentsArePassedThroughRaw() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{not valid json"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{not valid json"}}

        event: response.completed
        data: {"type":"response.completed"}

        """#
        installSSE(sse)
        let events = try await collectEvents(from: makeOpenAIProvider())
        XCTAssertEqual(
            events,
            [
                .toolCall(AgentProviderToolCall(callID: "call_1", name: "read_file", argumentsJSON: "{not valid json")),
                .completed,
            ],
            "组装层不解释 arguments；非法 JSON 由执行层 invalidArguments 拒绝"
        )
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "read_file", argumentsJSON: "{not valid json"),
            .failure(.invalidArguments)
        )
    }

    // MARK: - §15 duplicate call_id / 重复 item

    func testDuplicateCallIDIsStreamProtocolError() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"dup","name":"read_file","arguments":""}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_2","call_id":"dup","name":"list_directory","arguments":""}}

        """#
        installSSE(sse)
        do {
            _ = try await collectEvents(from: makeOpenAIProvider())
            XCTFail("duplicate call_id 必须报 streamProtocol")
        } catch let error as AgentProviderError {
            guard case .streamProtocol = error else {
                return XCTFail("应为 streamProtocol，实际 \(error)")
            }
        }
    }

    func testArgumentsDeltaForUnknownItemIsStreamProtocolError() async throws {
        let sse = #"""
        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_missing","delta":"{}"}

        """#
        installSSE(sse)
        do {
            _ = try await collectEvents(from: makeOpenAIProvider())
            XCTFail("未知 item 的 arguments delta 必须报 streamProtocol（§61）")
        } catch let error as AgentProviderError {
            guard case .streamProtocol = error else {
                return XCTFail("应为 streamProtocol，实际 \(error)")
            }
        }
    }

    // MARK: - §12 done 与累计 delta 不一致

    func testArgumentsDoneMismatchWithDeltasIsStreamProtocolError() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"path\":\"a\"}"}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"path\":\"b\"}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"b\"}"}}

        """#
        installSSE(sse)
        do {
            _ = try await collectEvents(from: makeOpenAIProvider())
            XCTFail("done 与累计 delta 不一致必须报 streamProtocol（§12）")
        } catch let error as AgentProviderError {
            guard case .streamProtocol = error else {
                return XCTFail("应为 streamProtocol，实际 \(error)")
            }
        }
    }

    // MARK: - §59 incomplete call（无 done）绝不产出 toolCall

    func testIncompleteCallWithoutDoneProducesNoToolCall() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"pa"}

        event: response.completed
        data: {"type":"response.completed"}

        """#
        installSSE(sse)
        let events = try await collectEvents(from: makeOpenAIProvider())
        XCTAssertEqual(events, [.completed], "未 finalize 的残缺 call 绝不执行（§59）")
    }

    // MARK: - §60 failed response / DeepSeek incomplete

    func testFailedResponseProducesErrorAndNoToolCall() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{}"}}

        event: response.failed
        data: {"type":"response.failed","message":"boom"}

        """#
        installSSE(sse)
        do {
            _ = try await collectEvents(from: makeOpenAIProvider())
            XCTFail("response.failed 必须抛错")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .serverError(statusCode: nil))
        }
    }

    func testDeepSeekIncompleteResponseIsStructuredError() async throws {
        let sse = #"""
        event: response.incomplete
        data: {"type":"response.incomplete","message":"max output"}

        """#
        installSSE(sse)
        do {
            _ = try await collectEvents(from: makeDeepSeekProvider())
            XCTFail("DeepSeek response.incomplete 必须抛 incompleteResponse")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .incompleteResponse)
        }
    }

    // MARK: - §51 unknown tool 组装层放行（执行层拒绝）

    func testUnknownToolNameIsAssembledButNeverDispatched() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"run_command","arguments":"{\"command\":\"git status\"}"}}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"command\":\"git status\"}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"run_command","arguments":"{\"command\":\"git status\"}"}}

        event: response.completed
        data: {"type":"response.completed"}

        """#
        installSSE(sse)
        let events = try await collectEvents(from: makeOpenAIProvider())
        XCTAssertEqual(
            events.first,
            .toolCall(
                AgentProviderToolCall(
                    callID: "call_1",
                    name: "run_command",
                    argumentsJSON: #"{"command":"git status"}"#
                )
            ),
            "解析层完整保留 provider 的 call（domain 负责拒绝）"
        )
        // 执行层静态注册表：hard reject（§51）。
        XCTAssertEqual(
            AgentToolCallParsing.parse(
                name: "run_command",
                argumentsJSON: #"{"command":"git status"}"#
            ),
            .failure(.unknownTool)
        )
    }

    // MARK: - §19/§58 function_call_output continuation 重建

    private func makeToolTranscript(scope: AgentProviderScope = .openAI) -> [AgentMessage] {
        [
            AgentMessage(role: .user, content: "读取 README.md"),
            AgentMessage(
                role: .tool,
                content: .tool(
                    AgentToolActivity(
                        callID: "call_abc",
                        toolName: "read_file",
                        argumentsJSON: #"{"path":"README.md"}"#,
                        displayTarget: "README.md",
                        status: .success,
                        resultJSON: ##"{"ok":true,"text":"# MacSSH","truncated":false,"bytesReturned":8,"originalSize":8}"##,
                        isError: false
                    )
                )
            ),
            AgentMessage(role: .tool, content: .providerContinuation(
                AgentProviderContinuationItem(
                    providerScope: scope,
                    kind: "reasoning",
                    itemJSON: #"{"type":"reasoning","id":"rs_1","summary":[]}"#
                )
            )),
        ]
    }

    func testContinuationRequestRebuildsFunctionCallAndOutputPair() async throws {
        installSSE(Self.singleCallSSE)
        // 第一轮先正常调用一次，确保请求路径真实（URLProtocol 记录 body）。
        _ = try await collectEvents(from: makeOpenAIProvider(), transcript: makeToolTranscript())

        let request = try XCTUnwrap(AgentToolCallStub.lastRequest)
        let json = try requestJSON(of: request)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])

        // system context + user + function_call + function_call_output + reasoning
        XCTAssertEqual(input.count, 5)
        XCTAssertEqual(input[1]["role"] as? String, "user")

        let callItem = input[2]
        XCTAssertEqual(callItem["type"] as? String, "function_call")
        XCTAssertEqual(callItem["call_id"] as? String, "call_abc")
        XCTAssertEqual(callItem["name"] as? String, "read_file")
        XCTAssertEqual(callItem["arguments"] as? String, #"{"path":"README.md"}"#)

        let outputItem = input[3]
        XCTAssertEqual(outputItem["type"] as? String, "function_call_output")
        XCTAssertEqual(outputItem["call_id"] as? String, "call_abc", "call_id 必须严格配对（§14/§58）")
        let output = try XCTUnwrap(outputItem["output"] as? String)
        XCTAssertTrue(output.contains("\"ok\":true"))

        // Tool Result 绝不伪装成 user message（§19 hard gate）。
        for item in input where item["role"] != nil {
            XCTAssertNotEqual(item["role"] as? String, "tool")
        }

        // §22/§65：OpenAI reasoning item verbatim 回放。
        let reasoningItem = input[4]
        XCTAssertEqual(reasoningItem["type"] as? String, "reasoning")
        XCTAssertEqual(reasoningItem["id"] as? String, "rs_1")
    }

    /// B4 live 修复回归：同一 tool turn 的多个 call 必须以
    /// 「全部 function_call → 全部 function_call_output」分组回放
    /// （DeepSeek thinking mode 对末尾 tool turn 的 reasoning 校验依赖
    /// 该顺序；交错顺序会 400）。
    func testParallelCallOutputsAreGroupedAfterAllCalls() async throws {
        installSSE(Self.singleCallSSE)
        let transcript: [AgentMessage] = [
            AgentMessage(role: .user, content: "同时读两个文件"),
            AgentMessage(role: .tool, content: .tool(AgentToolActivity(
                callID: "call_1", toolName: "read_file",
                argumentsJSON: #"{"path":"a.txt"}"#, displayTarget: "a.txt",
                status: .success, resultJSON: #"{"ok":true,"text":"A"}"#, isError: false
            ))),
            AgentMessage(role: .tool, content: .tool(AgentToolActivity(
                callID: "call_2", toolName: "read_file",
                argumentsJSON: #"{"path":"b.txt"}"#, displayTarget: "b.txt",
                status: .success, resultJSON: #"{"ok":true,"text":"B"}"#, isError: false
            ))),
        ]
        _ = try await collectEvents(from: makeOpenAIProvider(), transcript: transcript)

        let request = try XCTUnwrap(AgentToolCallStub.lastRequest)
        let json = try requestJSON(of: request)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        let types = input.map { $0["type"] as? String ?? "message" }
        XCTAssertEqual(
            types,
            ["message", "message", "function_call", "function_call", "function_call_output", "function_call_output"],
            "多个 call 必须分组：先全部 function_call，再全部 function_call_output"
        )
        XCTAssertEqual(input[2]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[3]["call_id"] as? String, "call_2")
        XCTAssertEqual(input[4]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[5]["call_id"] as? String, "call_2")
    }

    /// Phase 10D-B4-R1 live 修复回归（P1-R1）：assistant 文本 + reasoning +
    /// tool call 出现在同一轮次时，回放必须把 reasoning item 前移到
    /// assistant 文本消息之前。真实 DeepSeek API 对照实验：`[text,
    /// reasoning, calls]` → 400 "The `reasoning_text` in the thinking mode
    /// must be passed back to the API."；`[reasoning, text, calls]` → 200。
    func testReasoningPrecedesAssistantTextInContinuationReplay() async throws {
        installSSE(Self.singleCallSSE)
        let transcript: [AgentMessage] = [
            AgentMessage(role: .user, content: "读取两个文件"),
            AgentMessage(role: .assistant, content: "我先读取这两个文件。"),
            AgentMessage(role: .tool, content: .providerContinuation(
                AgentProviderContinuationItem(
                    providerScope: .deepSeek,
                    kind: "reasoning",
                    itemJSON: #"{"type":"reasoning","id":"rs_1","summary":[]}"#
                )
            )),
            AgentMessage(role: .tool, content: .tool(AgentToolActivity(
                callID: "call_1", toolName: "read_file",
                argumentsJSON: #"{"path":"a.txt"}"#, displayTarget: "a.txt",
                status: .success, resultJSON: #"{"ok":true,"text":"A"}"#, isError: false
            ))),
        ]
        _ = try await collectEvents(from: makeDeepSeekProvider(), transcript: transcript)

        let request = try XCTUnwrap(AgentToolCallStub.lastRequest)
        let json = try requestJSON(of: request)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        let types = input.map { $0["type"] as? String ?? "message" }
        XCTAssertEqual(
            types,
            ["message", "message", "reasoning", "message", "function_call", "function_call_output"],
            "reasoning 必须在 assistant 文本消息之前回放（R1 live 400 根因）"
        )
        XCTAssertEqual(input[2]["id"] as? String, "rs_1")
        XCTAssertEqual(input[3]["role"] as? String, "assistant")
        XCTAssertEqual(input[4]["call_id"] as? String, "call_1")
    }

    func testCrossProviderOpaqueItemsAreNotReplayed() async throws {
        installSSE(Self.singleCallSSE)
        // transcript 中是 DeepSeek-scoped item，但请求发给 OpenAI
        // provider——绝不回放（§53 hard gate）。
        _ = try await collectEvents(
            from: makeOpenAIProvider(),
            transcript: makeToolTranscript(scope: .deepSeek)
        )
        let request = try XCTUnwrap(AgentToolCallStub.lastRequest)
        let json = try requestJSON(of: request)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 4, "异构 provider opaque item 绝不进入 input")
        for item in input {
            XCTAssertNotEqual(item["type"] as? String, "reasoning")
        }
    }

    func testDeepSeekContinuationRebuildsFullLocalTranscript() async throws {
        installSSE(Self.singleCallSSE)
        _ = try await collectEvents(
            from: makeDeepSeekProvider(),
            transcript: makeToolTranscript(scope: .deepSeek)
        )
        let request = try XCTUnwrap(AgentToolCallStub.lastRequest)
        let json = try requestJSON(of: request)
        // stateless（§20）：full transcript，绝无 server-side state。
        XCTAssertNil(json["previous_response_id"])
        XCTAssertNil(json["conversation"])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 5, "system + user + function_call + function_call_output + reasoning")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[4]["type"] as? String, "reasoning")
    }

    // MARK: - §22 reasoning item 捕获

    func testReasoningItemIsCapturedAsOpaqueContinuationItem() async throws {
        let sse = #"""
        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_9","summary":[]}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_9","summary":[],"encrypted_content":"opaque-blob"}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"path\":\"a\"}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"a\"}"}}

        event: response.completed
        data: {"type":"response.completed"}

        """#
        installSSE(sse)
        let events = try await collectEvents(from: makeOpenAIProvider())
        XCTAssertEqual(events.count, 3)
        guard case .providerItem(let item) = events[0] else {
            return XCTFail("第一个事件必须是 opaque reasoning item")
        }
        XCTAssertEqual(item.providerScope, .openAI)
        XCTAssertEqual(item.kind, "reasoning")
        XCTAssertTrue(item.itemJSON.contains("\"rs_9\""))
        XCTAssertTrue(item.itemJSON.contains("opaque-blob"))
        guard case .toolCall(let call) = events[1], call.callID == "call_1" else {
            return XCTFail("reasoning 之后必须是 toolCall")
        }

        // DeepSeek provider 对同一 reasoning 流产出 deepSeek-scoped item
        // （absorb 差异，§66）——绝不标成 openAI。
        installSSE(sse)
        let deepSeekEvents = try await collectEvents(from: makeDeepSeekProvider())
        guard case .providerItem(let deepSeekItem) = deepSeekEvents[0] else {
            return XCTFail("DeepSeek 同样捕获 reasoning item")
        }
        XCTAssertEqual(deepSeekItem.providerScope, .deepSeek)
    }

    // MARK: - cancel（Stop）所有权

    func testCancellationStopsUnderlyingRequestDuringToolStream() async throws {
        AgentToolCallingStubURLProtocol.setNeverFinish(true)
        let baseURL = URL(string: "https://stub.invalid")!
        AgentToolCallingStubURLProtocol.install { request in
            (Self.httpResponse(statusCode: 200, url: request.url ?? baseURL), [])
        }
        let provider = makeOpenAIProvider()
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
        let deadline = Date().addingTimeInterval(5)
        while AgentToolCallingStubURLProtocol.requestCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        consumer.cancel()
        while AgentToolCallingStubURLProtocol.stopLoadingCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let events = await consumer.value
        XCTAssertTrue(events.isEmpty, "取消后不得产出任何 toolCall")
        XCTAssertGreaterThan(AgentToolCallingStubURLProtocol.stopLoadingCount, 0)
    }
}

// MARK: - Stub 便捷访问

private extension AgentProviderToolCallingTests {
    /// 与实例无关的静态 stub 访问（供闭包外读取）。
    typealias AgentToolCallStub = AgentToolCallingStubURLProtocol
}
