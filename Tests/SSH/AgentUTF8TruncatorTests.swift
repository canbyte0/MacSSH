import Foundation
import XCTest

@testable import MacSSH

/// 10D-B2 §4/§5/§26：UTF-8 截断 helper 测试。
///
/// 预算一律按 UTF-8 bytes 计算，绝不在 Character（中文 / Emoji /
/// 组合字符）的 UTF-8 序列中间截断。
final class AgentUTF8TruncatorTests: XCTestCase {
    // MARK: - 字节计数

    func testByteCountUsesUTF8NotCharacterCount() {
        XCTAssertEqual(AgentUTF8Truncator.byteCount(of: "abc"), 3)
        XCTAssertEqual(AgentUTF8Truncator.byteCount(of: "中文"), 6)
        XCTAssertEqual(AgentUTF8Truncator.byteCount(of: "😀"), 4)
        // Character count 只有 1，UTF-8 是 4 —— 断言两者不同以固化语义。
        XCTAssertEqual("😀".count, 1)
    }

    // MARK: - 不截断

    func testNoTruncationWithinBudget() {
        let result = AgentUTF8Truncator.truncate("hello", byteLimit: 5)
        XCTAssertEqual(result.text, "hello")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.bytesReturned, 5)
    }

    func testEmptyString() {
        let result = AgentUTF8Truncator.truncate("", byteLimit: 100)
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.bytesReturned, 0)
    }

    func testZeroBudget() {
        let result = AgentUTF8Truncator.truncate("abc", byteLimit: 0)
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.bytesReturned, 0)
    }

    // MARK: - ASCII 边界

    func testASCIIExactBoundaryIsNotTruncated() {
        let result = AgentUTF8Truncator.truncate("12345", byteLimit: 5)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.text, "12345")
    }

    func testASCIIOverBoundaryTruncates() {
        let result = AgentUTF8Truncator.truncate("123456", byteLimit: 5)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text, "12345")
        XCTAssertEqual(result.bytesReturned, 5)
    }

    // MARK: - 多字节不得切半（§5）

    func testChineseCharacterIsNeverSplit() {
        // 中 = 3 bytes；预算 5 → 只能放 1 个「中」（剩 2 bytes 放不下第二个）。
        let result = AgentUTF8Truncator.truncate("中中文", byteLimit: 5)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text, "中")
        XCTAssertEqual(result.bytesReturned, 3)
    }

    func testEmojiDroppedWhenOnlyThreeBytesLeft() {
        // 😀 = 4 bytes；只剩 3 bytes → 整个 Emoji 都不返回（§5 明确示例）。
        let result = AgentUTF8Truncator.truncate("a😀", byteLimit: 4)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text, "a")
        XCTAssertEqual(result.bytesReturned, 1)

        let fitted = AgentUTF8Truncator.truncate("a😀", byteLimit: 5)
        XCTAssertEqual(fitted.text, "a😀")
        XCTAssertTrue(fitted.truncated == false)
        XCTAssertEqual(fitted.bytesReturned, 5)
    }

    func testCombiningSequenceIsNeverSplit() {
        // "e" + U+0301（组合重音）= 一个 Character，3 bytes。
        let combined = "e\u{0301}"
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(AgentUTF8Truncator.byteCount(of: combined), 3)
        let result = AgentUTF8Truncator.truncate(combined + "x", byteLimit: 2)
        XCTAssertEqual(result.text, "", "组合序列放不下时整个丢弃，绝不切半")
        XCTAssertEqual(result.bytesReturned, 0)
    }

    func testMixedScriptTruncationStaysValidUTF8() {
        let text = String(repeating: "a中😀", count: 50)
        let result = AgentUTF8Truncator.truncate(text, byteLimit: 101)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(AgentUTF8Truncator.byteCount(of: result.text), result.bytesReturned)
        XCTAssertLessThanOrEqual(result.bytesReturned, 101)
        // 截断结果必须是合法 UTF-8（回读字节一致）。
        XCTAssertEqual(Array(result.text.utf8).count, result.bytesReturned)
    }

    // MARK: - 数据层前缀边界（§26）

    func testUTF8PrefixBoundaryBacksOffContinationBytes() {
        // "a" + 😀(4 bytes)：limit 落在 Emoji 第 3 字节。
        var data = Data("a".utf8)
        data.append(Data("😀".utf8))
        XCTAssertEqual(data.count, 5)
        XCTAssertEqual(AgentUTF8Truncator.utf8PrefixBoundary(in: data, byteLimit: 3), 1)
        XCTAssertEqual(AgentUTF8Truncator.utf8PrefixBoundary(in: data, byteLimit: 5), 5)
        XCTAssertEqual(AgentUTF8Truncator.utf8PrefixBoundary(in: data, byteLimit: 100), 5)
    }

    func testUTF8PrefixBoundaryWithChinese() {
        var data = Data("abc".utf8)
        data.append(Data("中文".utf8))
        XCTAssertEqual(data.count, 9)
        // 4 → 落在「中」的第 1 字节之后：回退到 3。
        XCTAssertEqual(AgentUTF8Truncator.utf8PrefixBoundary(in: data, byteLimit: 4), 3)
        XCTAssertEqual(AgentUTF8Truncator.utf8PrefixBoundary(in: data, byteLimit: 6), 6)
    }

    // MARK: - 严格 UTF-8 解码（§27）

    func testStrictDecodeAcceptsValidUTF8() {
        let data = Data("中文😀".utf8)
        XCTAssertEqual(AgentUTF8Truncator.decodeStrictUTF8(data), "中文😀")
    }

    func testStrictDecodeRejectsInvalidUTF8() {
        var data = Data("abc".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        XCTAssertNil(AgentUTF8Truncator.decodeStrictUTF8(data))
    }

    // MARK: - 常量（§4/§25）

    func testHardLimits() {
        XCTAssertEqual(AgentTextLimits.recentOutputMaxRows, 200)
        XCTAssertEqual(AgentTextLimits.selectionMaxBytes, 64 * 1024)
        XCTAssertEqual(AgentTextLimits.terminalTextualPayloadMaxBytes, 256 * 1024)
        XCTAssertEqual(AgentTextLimits.fileReadMaxBytes, 256 * 1024)
    }
}
