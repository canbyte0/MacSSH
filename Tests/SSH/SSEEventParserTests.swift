import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 10C：SSEEventParser 测试（任务书 §31）。
///
/// 全部内存构造，不联网。覆盖：单 chunk 单事件 / 跨 chunk 分裂 /
/// 单 chunk 多事件 / CRLF / LF / 空行分隔 / UTF-8 跨 chunk 分裂 /
/// delta / completed / error / 未知事件忽略 / malformed JSON / EOF flush。
final class SSEEventParserTests: XCTestCase {

    // MARK: - 1. one event one chunk

    func testOneEventOneChunk() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("event: response.completed\ndata: {}\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "response.completed", data: "{}")])
    }

    // MARK: - 2. one event split across chunks

    func testOneEventSplitAcrossChunks() {
        let parser = SSEEventParser()
        var events: [SSEEvent] = []
        events += parser.feed(Data("event: response.output_text.de".utf8))
        events += parser.feed(Data("lta\ndata: {\"delta\":\"Hi\"".utf8))
        events += parser.feed(Data("}\n\n".utf8))
        XCTAssertEqual(
            events,
            [SSEEvent(event: "response.output_text.delta", data: #"{"delta":"Hi"}"#)]
        )
    }

    // MARK: - 3. multiple events in one chunk

    func testMultipleEventsInOneChunk() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("data: first\n\ndata: second\n\n".utf8))
        XCTAssertEqual(
            events,
            [
                SSEEvent(event: "", data: "first"),
                SSEEvent(event: "", data: "second"),
            ]
        )
    }

    // MARK: - 4. CRLF

    func testCRLFLineEndings() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("event: response.completed\r\ndata: {}\r\n\r\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "response.completed", data: "{}")])
    }

    // MARK: - 5. LF

    func testLFLineEndings() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("event: response.completed\ndata: {}\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "response.completed", data: "{}")])
    }

    // MARK: - 6. blank event separators

    func testBlankSeparatorsDoNotDispatchEmptyEvents() {
        let parser = SSEEventParser()
        // 连续空行只 dispatch 一个事件，不产出空事件。
        let events = parser.feed(Data("data: payload\n\n\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "", data: "payload")])
    }

    /// 事件之间多个空行：各 dispatch 一次，不多不少。
    func testRepeatedBlankLinesBetweenEvents() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("data: a\n\n\n\ndata: b\n\n".utf8))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data, "a")
        XCTAssertEqual(events[1].data, "b")
    }

    // MARK: - 7. Unicode safely split across chunks

    func testUnicodeMultibyteSplitAcrossChunks() {
        let payload = "你好，世界"
        var bytes = Array("data: ".utf8)
        bytes += Array(payload.utf8)
        bytes += Array("\n\n".utf8)
        // 在「你」的多字节序列内部切开（data: 之后第 1 字节处）。
        let splitIndex = "data: ".utf8.count + 1

        let parser = SSEEventParser()
        let first = parser.feed(Data(bytes[0..<splitIndex]))
        let second = parser.feed(Data(bytes[splitIndex...]))

        XCTAssertTrue(first.isEmpty, "半行不得提前产出事件")
        XCTAssertEqual(second, [SSEEvent(event: "", data: payload)])
    }

    /// 三字节 UTF-8 字符在中间字节处分裂。
    func testUnicodeSplitAtMiddleByte() {
        let payload = "終"
        let payloadBytes = Array(payload.utf8)
        XCTAssertEqual(payloadBytes.count, 3, "测试前提：三字节字符")

        let parser = SSEEventParser()
        let first = parser.feed(Data("data: ".utf8 + payloadBytes[0...1]))
        let second = parser.feed(Data(payloadBytes[2...] + "\n\n".utf8))

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [SSEEvent(event: "", data: payload)])
    }

    // MARK: - 8. response.output_text.delta

    func testDeltaEventMapsToTextDelta() throws {
        let event = SSEEvent(
            event: "response.output_text.delta",
            data: #"{"type":"response.output_text.delta","delta":"Hello, I can"}"#
        )
        let mapped = try OpenAIResponsesStreamMapper.mappedEvent(from: event)
        XCTAssertEqual(mapped, .agent(.textDelta("Hello, I can")))
    }

    /// event 名缺失时回退 JSON `type` 字段（OpenAI 默认不带 event: 行）。
    func testDeltaEventWithoutEventNameFallsBackToTypeField() throws {
        let event = SSEEvent(
            event: "",
            data: #"{"type":"response.output_text.delta","delta":"fallback"}"#
        )
        XCTAssertEqual(
            try OpenAIResponsesStreamMapper.mappedEvent(from: event),
            .agent(.textDelta("fallback"))
        )
    }

    /// delta 事件缺 delta 字段 → streamProtocol 错误。
    func testDeltaEventWithoutDeltaFieldThrowsStreamProtocol() {
        let event = SSEEvent(
            event: "response.output_text.delta",
            data: #"{"type":"response.output_text.delta"}"#
        )
        XCTAssertThrowsError(try OpenAIResponsesStreamMapper.mappedEvent(from: event)) { error in
            guard case .streamProtocol = error as? AgentProviderError else {
                return XCTFail("应为 streamProtocol，实际 \(error)")
            }
        }
    }

    // MARK: - 9. response.completed

    func testCompletedEventMapsToCompleted() throws {
        let event = SSEEvent(
            event: "response.completed",
            data: #"{"type":"response.completed"}"#
        )
        XCTAssertEqual(try OpenAIResponsesStreamMapper.mappedEvent(from: event), .agent(.completed))
    }

    // MARK: - 10. error

    func testErrorEventThrowsServerError() {
        let event = SSEEvent(
            event: "error",
            data: #"{"type":"error","code":"server_error"}"#
        )
        XCTAssertThrowsError(try OpenAIResponsesStreamMapper.mappedEvent(from: event)) { error in
            XCTAssertEqual(error as? AgentProviderError, .serverError(statusCode: nil))
        }
    }

    /// response.failed 事件同样映射 serverError。
    func testResponseFailedEventThrowsServerError() {
        let event = SSEEvent(
            event: "response.failed",
            data: #"{"type":"response.failed"}"#
        )
        XCTAssertThrowsError(try OpenAIResponsesStreamMapper.mappedEvent(from: event)) { error in
            XCTAssertEqual(error as? AgentProviderError, .serverError(statusCode: nil))
        }
    }

    // MARK: - 11. unknown event ignored

    func testUnknownEventIsIgnored() throws {
        for name in ["response.created", "response.in_progress", "output_item.added", "custom"] {
            let event = SSEEvent(event: name, data: #"{"type":"\#(name)"}"#)
            XCTAssertEqual(
                try OpenAIResponsesStreamMapper.mappedEvent(from: event),
                .ignored,
                "未知事件 \(name) 必须忽略"
            )
        }
    }

    // MARK: - 12. malformed JSON

    func testMalformedJSONThrowsInvalidResponse() {
        let event = SSEEvent(event: "response.output_text.delta", data: "not-json")
        XCTAssertThrowsError(try OpenAIResponsesStreamMapper.mappedEvent(from: event)) { error in
            guard case .invalidResponse = error as? AgentProviderError else {
                return XCTFail("应为 invalidResponse，实际 \(error)")
            }
        }
    }

    // MARK: - 13. final EOF

    func testFinishFlushesPendingEventWithoutTrailingBlankLine() {
        let parser = SSEEventParser()
        // 服务端最后一个事件后直接关闭连接（无结尾空行）。
        _ = parser.feed(Data("event: response.completed\ndata: {}".utf8))
        XCTAssertEqual(
            parser.finish(),
            [SSEEvent(event: "response.completed", data: "{}")]
        )
        // finish 幂等：重复调用不再产出。
        XCTAssertEqual(parser.finish(), [])
    }

    /// EOF 宽容 flush：已 dispatch 的事件不重复产出；残余未换行字节按
    /// 最后一行处理（截断的半行会经 mapper JSON 解析显式报错，不静默吞掉）。
    func testFinishTreatsTrailingBytesAsFinalLine() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("data: complete\n\ndata: incompl".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "", data: "complete")])
        XCTAssertEqual(parser.finish(), [SSEEvent(event: "", data: "incompl")])
    }

    // MARK: - SSE 规范补充

    /// 多行 data 以换行拼接。
    func testMultiLineDataIsJoinedByNewline() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("data: line1\ndata: line2\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "", data: "line1\nline2")])
    }

    /// 注释行 / 未知字段（id / retry）按规范忽略。
    func testCommentsAndUnknownFieldsIgnored() {
        let parser = SSEEventParser()
        let events = parser.feed(
            Data(": keep-alive comment\nid: 42\nretry: 100\ndata: payload\n\n".utf8)
        )
        XCTAssertEqual(events, [SSEEvent(event: "", data: "payload")])
    }

    /// 无 data 行的事件不 dispatch（SSE 规范）。
    func testEventWithoutDataNotDispatched() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("event: response.completed\n\n".utf8))
        XCTAssertTrue(events.isEmpty)
    }

    /// 冒号后前导空格只剥一个（SSE 规范）。
    func testSingleLeadingSpaceAfterColonIsStripped() {
        let parser = SSEEventParser()
        let events = parser.feed(Data("data:  two spaces\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "", data: " two spaces")])
    }
}
