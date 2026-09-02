import AppKit
import SwiftTerm
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 5 — VS16 preserve-base-width 兼容验收测试。
///
/// 这些测试在 MacSSH 侧验证：
/// - Local Terminal 启用 `.preserveBaseWidth`，与 macOS zsh（系统 wcwidth）一致；
/// - Remote Terminal 保持 SwiftTerm 默认 `.widenToEmojiWidth`（有意产品决策）；
/// - 链接进来的 SwiftTerm fork 在 preserve 模式下产出正确宽度且 bracketed
///   paste 重绘不再漂移（`echo '⚠️ ❤️'` 历史行保持干净），而默认模式仍按既有
///   行为扩宽（证明默认行为不变）。
///
/// 真实缺陷（Phase 5 根因）：SwiftTerm 默认把 ⚠/❤ + VS16 扩展为 width 2，
/// 而 macOS zsh 按 width 1 处理，导致 bracketed paste 重绘时光标列分叉、历史行
/// 漂移成 `eecho ...` / `ececho ...`。preserve 模式使两侧 width 一致。
///
/// 仅使用 SwiftTerm 公开 API（不依赖 internal `translateBufferLineToString`），
/// 以行格、cell width 与 `getCharacter(for:)` 重建可见行文本做断言。
@MainActor
final class TerminalVS16WidthPolicyTests: XCTestCase {

    // MARK: - Local / Remote 策略配置

    /// Local Terminal 必须启用 VS16 preserve-base-width 兼容策略。
    func testLocalTerminalServiceUsesPreserveBaseWidthPolicy() {
        let session = TerminalSession(shellPath: "/bin/zsh")
        let service = LocalTerminalService(session: session)

        let policy = service.terminalView.getTerminal().options.variationSelector16WidthPolicy
        XCTAssertEqual(
            policy,
            .preserveBaseWidth,
            "Local Terminal 必须启用 preserveBaseWidth 以匹配 macOS zsh wcwidth"
        )
    }

    /// Remote Terminal 保持 SwiftTerm 默认策略（.widenToEmojiWidth）。
    /// RemoteTerminalService 的 TerminalOptions 构造不指定 policy 参数 → 取默认。
    func testRemoteTerminalUsesSwiftTermDefaultPolicy() {
        // TerminalOptions.default 与 RemoteTerminalService 构造时使用的 options
        // 都不指定 variationSelector16WidthPolicy，因此取 SwiftTerm 默认值。
        let defaultPolicy = TerminalOptions.default.variationSelector16WidthPolicy
        let remoteOptions = TerminalOptions(
            cols: 80,
            rows: 24,
            termName: "xterm-256color",
            scrollback: 10_000
        )
        XCTAssertEqual(
            remoteOptions.variationSelector16WidthPolicy,
            .widenToEmojiWidth,
            "Remote Terminal 必须保持 SwiftTerm 默认 widenToEmojiWidth"
        )
        XCTAssertEqual(remoteOptions.variationSelector16WidthPolicy, defaultPolicy,
                       "Remote Terminal options policy 必须与 SwiftTerm 默认一致")
    }

    // MARK: - 链接进来的 SwiftTerm fork 行为（端到端）

    /// ⚠ (U+26A0) + VS16 在 preserve 模式下保持 width 1（与 zsh 一致）。
    func testPreserveBaseWidthKeepsWarningSignNarrow() {
        let terminal = makeHeadless(policy: .preserveBaseWidth)
        terminal.feed(text: "\u{26A0}\u{FE0F}x")
        XCTAssertEqual(terminal.getCharData(col: 0, row: 0)?.width, 1)
        // 无 width-0 续接格；下一个 glyph 落在 col 1。
        XCTAssertEqual(terminal.getCharacter(col: 1, row: 0), "x")
    }

    /// ❤ (U+2764) + VS16 在 preserve 模式下保持 width 1。
    func testPreserveBaseWidthKeepsHeartNarrow() {
        let terminal = makeHeadless(policy: .preserveBaseWidth)
        terminal.feed(text: "\u{2764}\u{FE0F}x")
        XCTAssertEqual(terminal.getCharData(col: 0, row: 0)?.width, 1)
        XCTAssertEqual(terminal.getCharacter(col: 1, row: 0), "x")
    }

    /// 默认模式下 ⚠️ / ❤️ 仍为 width 2（证明 patch 默认行为不变、向后兼容）。
    func testDefaultPolicyStillWidensVS16Bases() {
        let terminal = makeHeadless(policy: .widenToEmojiWidth)
        terminal.feed(text: "\u{26A0}\u{FE0F}x")
        XCTAssertEqual(terminal.getCharData(col: 0, row: 0)?.width, 2)
        XCTAssertEqual(terminal.getCharacter(col: 2, row: 0), "x")
    }

    /// VS16 scalar 在 preserve 模式下仍保留在 grapheme cluster 中（未被剥离）。
    func testVS16ScalarPreservedInClusterUnderPreservePolicy() {
        let terminal = makeHeadless(policy: .preserveBaseWidth)
        terminal.feed(text: "\u{26A0}\u{FE0F}")
        guard let ch = terminal.getCharacter(col: 0, row: 0) else {
            return XCTFail("expected character at (0,0)")
        }
        XCTAssertTrue(ch.unicodeScalars.contains { $0.value == 0xFE0F })
        XCTAssertTrue(ch.unicodeScalars.contains { $0.value == 0x26A0 })
    }

    /// 普通 Emoji（😀/🚀/👍）在 preserve 模式下保持 width 2。
    func testPlainEmojiKeepWidthTwoUnderPreservePolicy() {
        let terminal = makeHeadless(policy: .preserveBaseWidth)
        terminal.feed(text: "\u{1F600}\u{1F680}\u{1F44D}x")
        XCTAssertEqual(terminal.getCharData(col: 0, row: 0)?.width, 2)
        XCTAssertEqual(terminal.getCharData(col: 2, row: 0)?.width, 2)
        XCTAssertEqual(terminal.getCharData(col: 4, row: 0)?.width, 2)
        XCTAssertEqual(terminal.getCharacter(col: 6, row: 0), "x")
    }

    /// CJK 在两种策略下都保持 width 2。
    func testCJKUnaffectedByPolicy() {
        for policy in [VariationSelector16WidthPolicy.widenToEmojiWidth,
                       VariationSelector16WidthPolicy.preserveBaseWidth] {
            let terminal = makeHeadless(policy: policy)
            terminal.feed(text: "中文")
            XCTAssertEqual(terminal.getCharData(col: 0, row: 0)?.width, 2)
            XCTAssertEqual(terminal.getCharData(col: 2, row: 0)?.width, 2)
        }
    }

    // MARK: - 真实缺陷回归：bracketed paste 重绘 + copy

    private static let redrawCommand = "echo '\u{26A0}\u{FE0F} \u{2764}\u{FE0F}'"

    /// preserve 模式下，模拟 zsh bracketed paste 重绘（按 host width 回退并重印命令）
    /// 后历史行必须保持干净，不能漂移成 `ececho ...`。
    func testBracketedPasteRedrawStaysCleanUnderPreservePolicy() {
        let terminal = makeHeadless(policy: .preserveBaseWidth)
        terminal.feed(text: Self.redrawCommand)
        // preserve 模式下命令占 10 列（与 zsh 一致）。
        XCTAssertEqual(terminal.buffer.x, 10)

        // 模拟 host 按其 width model（10）回退并重印同一命令。
        terminal.feed(text: "\u{1b}[10D")
        XCTAssertEqual(terminal.buffer.x, 0)
        terminal.feed(text: Self.redrawCommand)

        XCTAssertEqual(lineString(terminal, row: 0), Self.redrawCommand)
    }

    /// 默认模式下同样的重绘会因 width 不一致而漂移（证明缺陷真实存在、patch 针对性修复）。
    func testBracketedPasteRedrawDivergesUnderDefaultPolicy() {
        let terminal = makeHeadless(policy: .widenToEmojiWidth)
        terminal.feed(text: Self.redrawCommand)
        // 默认模式命令占 12 列（⚠️/❤️ 各 width 2）。
        XCTAssertEqual(terminal.buffer.x, 12)

        terminal.feed(text: "\u{1b}[10D")
        terminal.feed(text: Self.redrawCommand)

        XCTAssertNotEqual(lineString(terminal, row: 0), Self.redrawCommand)
    }

    /// copy/历史行抽取必须与视觉文本一致（preserve 模式）。
    func testCopyLineExtractionMatchesVisibleTextUnderPreservePolicy() {
        let terminal = makeHeadless(policy: .preserveBaseWidth)
        terminal.feed(text: Self.redrawCommand)
        XCTAssertEqual(lineString(terminal, row: 0), Self.redrawCommand)
    }

    /// 长 Emoji 命令行在 preserve 模式下历史行与抽取均正确。
    func testLongEmojiCommandLinePreservePolicy() {
        let terminal = makeHeadless(policy: .preserveBaseWidth)
        let command = "echo '\u{1F600} \u{1F680} \u{2705} \u{26A0}\u{FE0F} \u{2764}\u{FE0F} \u{1F44D}'"
        terminal.feed(text: command)
        XCTAssertEqual(lineString(terminal, row: 0), command)
    }

    /// ASCII 与中文命令在 preserve 模式下正常。
    func testAsciiAndCjkCommandsPreservePolicy() {
        let terminal = makeHeadless(policy: .preserveBaseWidth)
        terminal.feed(text: "echo TEST")
        XCTAssertEqual(lineString(terminal, row: 0), "echo TEST")
        terminal.feed(text: "\r\n")
        terminal.feed(text: "echo '\u{4E2D}\u{6587}\u{6D4B}\u{8BD5}\u{FF1A}\u{4F60}\u{597D}\u{4E16}\u{754C}'")
        XCTAssertEqual(
            lineString(terminal, row: 1),
            "echo '\u{4E2D}\u{6587}\u{6D4B}\u{8BD5}\u{FF1A}\u{4F60}\u{597D}\u{4E16}\u{754C}'"
        )
    }

    // MARK: - Helpers

    private func makeHeadless(policy: VariationSelector16WidthPolicy) -> Terminal {
        let headless = HeadlessTerminal(
            options: TerminalOptions(variationSelector16WidthPolicy: policy)
        ) { _ in }
        return headless.terminal!
    }

    /// 用公开 API 重建指定行的可见文本：遍历每一列，跳过 width-0 续接格，
    /// 用 `getCharacter(for:)` 取 grapheme，并去除行尾空白/NUL。
    private func lineString(_ terminal: Terminal, row: Int) -> String {
        var result = ""
        for col in 0..<terminal.cols {
            guard let cd = terminal.getCharData(col: col, row: row) else { continue }
            // width-0 是宽字符的续接格，已随主格输出，跳过避免重复。
            if cd.width > 0 {
                result.append(terminal.getCharacter(for: cd))
            }
        }
        // trimRight：去除行尾 NUL 与空格（来自未填充格）。
        while let last = result.last, last == "\u{0}" || last == " " {
            result.removeLast()
        }
        return result
    }
}
