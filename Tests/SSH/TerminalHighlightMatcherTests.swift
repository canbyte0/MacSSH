import SwiftTerm
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 6：终端字符串高亮 matcher 测试。
///
/// 覆盖任务书第 50 节 matcher test matrix：
/// - ASCII / 中间 / 重复 / case-sensitive / case-insensitive / ERROR_CODE
/// - CJK（规则 ERROR + 规则 错误）
/// - Emoji（😀 ERROR ❤️，前置 emoji 不偏移）
/// - VS16（⚠️ ERROR / ❤️ ERROR，preserve / widen 双策略）
/// - combining mark（e + U+0301 + ERROR）
/// - ZWJ（👩‍💻 ERROR）
/// - ANSI（ESC[31m...ESC[0m，matcher 只见 ERROR）
/// - overlapping rules（first-rule-wins）
/// - disabled rule / global disabled / empty rule
/// - wrapped split limitation（ERRO|R 跨物理行 → 0 命中）
@MainActor
final class TerminalHighlightMatcherTests: XCTestCase {

    // MARK: - Helpers

    private final class NullDelegate: TerminalDelegate {
        func sizeChanged(source: Terminal, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: Terminal) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private let delegate = NullDelegate()

    /// 喂入文本后取第 0 行的 matches。
    private func matches(for feed: String,
                         rules: [TerminalHighlightRule],
                         options: TerminalOptions = TerminalOptions(cols: 40, rows: 5, scrollback: 100)) -> [TerminalHighlightMatcher.Match] {
        let term = Terminal(delegate: delegate, options: options)
        term.feed(text: feed)
        guard let line = term.getScrollInvariantLine(row: 0) else {
            XCTFail("row 0 不存在"); return []
        }
        return TerminalHighlightMatcher.matches(inLine: line, terminal: term, rules: rules)
    }

    private func rule(_ text: String, color: TerminalHighlightColor = .red,
                      caseSensitive: Bool = true, enabled: Bool = true,
                      sortOrder: Int = 0) -> TerminalHighlightRule {
        TerminalHighlightRule(id: UUID(), text: text, color: color,
                              isCaseSensitive: caseSensitive, isEnabled: enabled,
                              sortOrder: sortOrder)
    }

    // MARK: - ASCII

    func testPlainError() {
        let m = matches(for: "ERROR\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 0)
        XCTAssertEqual(m.first?.endColumn, 5)
        XCTAssertEqual(m.first?.color, .red)
    }

    func testErrorInMiddle() {
        let m = matches(for: "abc ERROR xyz\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 4)
        XCTAssertEqual(m.first?.endColumn, 9)
    }

    func testRepeatedMatches() {
        let m = matches(for: "ERROR ERROR ERROR\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m.map { [$0.startColumn, $0.endColumn] },
                       [[0, 5], [6, 11], [12, 17]])
    }

    func testCaseSensitiveDoesNotMatchLower() {
        let m = matches(for: "error\r\n", rules: [rule("ERROR", caseSensitive: true)])
        XCTAssertTrue(m.isEmpty)
    }

    func testCaseInsensitiveMatchesLower() {
        let m = matches(for: "error\r\n", rules: [rule("ERROR", caseSensitive: false)])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 0)
    }

    func testSubstringInsideLonger() {
        let m = matches(for: "ERROR_CODE\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 0)
        XCTAssertEqual(m.first?.endColumn, 5)
    }

    // MARK: - CJK

    func testCjkWithErrorInMiddle() {
        let m = matches(for: "中文 ERROR 测试\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 5)
        XCTAssertEqual(m.first?.endColumn, 10)
    }

    func testCjkRuleMatchesCjk() {
        let m = matches(for: "中文错误测试\r\n", rules: [rule("错误")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 4)
        XCTAssertEqual(m.first?.endColumn, 8)
    }

    // MARK: - Emoji

    func testEmojiBeforeErrorDoesNotShift() {
        let m = matches(for: "😀 ERROR ❤️\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 3)
        XCTAssertEqual(m.first?.endColumn, 8)
    }

    // MARK: - VS16

    func testVs16PreserveWarningError() {
        let opts = TerminalOptions(cols: 40, rows: 5, scrollback: 100,
                                   variationSelector16WidthPolicy: .preserveBaseWidth)
        let m = matches(for: "⚠️ ERROR\r\n", rules: [rule("ERROR")], options: opts)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 2)
        XCTAssertEqual(m.first?.endColumn, 7)
    }

    func testVs16WidenWarningError() {
        let opts = TerminalOptions(cols: 40, rows: 5, scrollback: 100,
                                   variationSelector16WidthPolicy: .widenToEmojiWidth)
        let m = matches(for: "⚠️ ERROR\r\n", rules: [rule("ERROR")], options: opts)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 3)
        XCTAssertEqual(m.first?.endColumn, 8)
    }

    func testVs16PreserveHeartError() {
        let opts = TerminalOptions(cols: 40, rows: 5, scrollback: 100,
                                   variationSelector16WidthPolicy: .preserveBaseWidth)
        let m = matches(for: "❤️ ERROR\r\n", rules: [rule("ERROR")], options: opts)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 2)
        XCTAssertEqual(m.first?.endColumn, 7)
    }

    // MARK: - Combining / ZWJ

    func testCombiningMarkBeforeError() {
        // e + U+0301 combining acute → 合并进单 cell（宽 1），ERROR [2,7)
        let m = matches(for: "e\u{301} ERROR\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 2)
        XCTAssertEqual(m.first?.endColumn, 7)
    }

    func testZwjSequenceBeforeError() {
        // 👩‍💻 = 👩 ZWJ 💻 → 合并单 cell（宽 2），ERROR [3,8)
        let m = matches(for: "\u{1F469}\u{200D}\u{1F4BB} ERROR\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 3)
        XCTAssertEqual(m.first?.endColumn, 8)
    }

    // MARK: - ANSI

    func testAnsiEscapeStrippedFromMatcher() {
        // ESC[31m ERROR ESC[0m → matcher 只见 "ERROR"
        let m = matches(for: "\u{1b}[31mERROR\u{1b}[0m\r\n", rules: [rule("ERROR")])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 0)
        XCTAssertEqual(m.first?.endColumn, 5)
    }

    // MARK: - Overlap semantics

    func testOverlapFirstRuleWins() {
        // ERROR (sortOrder 0, red) 与 ERR (sortOrder 1, blue) 重叠：
        // ERROR 先匹配 [0,5)，ERR [0,3) 与之重叠 → 整段放弃
        let m = matches(for: "ERROR\r\n", rules: [
            rule("ERROR", color: .red, sortOrder: 0),
            rule("ERR", color: .blue, sortOrder: 1),
        ])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.startColumn, 0)
        XCTAssertEqual(m.first?.endColumn, 5)
        XCTAssertEqual(m.first?.color, .red)
    }

    func testOverlapNonOverlappingBothAccepted() {
        // ERROR (sortOrder 0) + tail "tail" (sortOrder 1) 不重叠 → 两者都接受
        let m = matches(for: "ERROR tail\r\n", rules: [
            rule("ERROR", color: .red, sortOrder: 0),
            rule("tail", color: .blue, sortOrder: 1),
        ])
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].color, .red)
        XCTAssertEqual(m[1].color, .blue)
    }

    // MARK: - Disabled / empty / global

    func testDisabledRuleProducesNoMatch() {
        let m = matches(for: "ERROR\r\n", rules: [rule("ERROR", enabled: false)])
        XCTAssertTrue(m.isEmpty)
    }

    func testEmptyRuleTextProducesNoMatch() {
        let m = matches(for: "ERROR\r\n", rules: [rule("")])
        XCTAssertTrue(m.isEmpty)
    }

    func testWhitespaceOnlyRuleTextProducesNoMatch() {
        let m = matches(for: "ERROR\r\n", rules: [rule("   ")])
        XCTAssertTrue(m.isEmpty)
    }

    // MARK: - Wrapped split limitation

    func testWrappedSplitDoesNotMatch() {
        // "XXXXX ERROR" in 10-col terminal → row0="XXXXX ERRO", row1="R"
        // 物理行独立匹配：两行都无完整 ERROR → 0 命中（v1 limitation）
        let opts = TerminalOptions(cols: 10, rows: 5, scrollback: 100)
        let term = Terminal(delegate: delegate, options: opts)
        term.feed(text: "XXXXX ERROR\n")
        var total = 0
        while term.getScrollInvariantLine(row: total) != nil { total += 1 }
        var allMatches: [TerminalHighlightMatcher.Match] = []
        for row in 0..<total {
            guard let line = term.getScrollInvariantLine(row: row) else { continue }
            allMatches += TerminalHighlightMatcher.matches(
                inLine: line, terminal: term, rules: [rule("ERROR")])
        }
        XCTAssertTrue(allMatches.isEmpty,
                      "wrap 拆词（ERRO|R）不应匹配（v1 limitation），实际 \(allMatches)")
    }

    // MARK: - Copy safety（matcher 不影响 buffer 文本）

    func testMatcherDoesNotChangeBufferText() {
        let term = Terminal(delegate: delegate,
                            options: TerminalOptions(cols: 40, rows: 5, scrollback: 100))
        term.feed(text: "abc ERROR xyz\r\n")
        guard let line = term.getScrollInvariantLine(row: 0) else {
            XCTFail("row 0 不存在"); return
        }
        _ = TerminalHighlightMatcher.matches(inLine: line, terminal: term,
                                             rules: [rule("ERROR")])
        // buffer 文本不受 matcher 影响
        let text = term.getText(start: Position(col: 0, row: 0),
                                end: Position(col: 13, row: 0))
        XCTAssertEqual(text, "abc ERROR xyz")
    }
}
