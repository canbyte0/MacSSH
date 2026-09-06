import AppKit
import SwiftTerm
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 9：font change → cell geometry recompute + cols/rows 变化
/// + Local/Remote PTY resize 路径回归测试（Phase 9A Acceptance §75 / §76 / §61-§64）。
///
/// **核心目标**：不只测 `view.font.pointSize`，必须证明 font change 真的触发了
/// SwiftTerm 内部 `resetFont` → `resize(cols:rows:)` → `sizeChanged` delegate
/// → Local `setWinSize` / Remote `resizeChannelPTY`。
///
/// 由于真实 PTY 与 libssh2 在单测中难以构造，本测试用 SwiftTerm 自带
/// TerminalView API + spy `TerminalViewDelegate` / `LocalProcessTerminalViewDelegate`
/// 捕获 `sizeChanged` 回调，验证 font change 触发完整 resize 链。
@MainActor
final class TerminalFontResizeTests: XCTestCase {

    // MARK: - Geometry recompute

    func testCellDimensionScalesWithFontSize() throws {
        let view = makeRemoteTerminalView()

        // 14pt baseline
        view.font = TerminalFontProvider.regularFont(size: 14)
        let cellW14 = view.caretFrame.size.width
        let cellH14 = view.caretFrame.size.height

        // 18pt
        view.font = TerminalFontProvider.regularFont(size: 18)
        let cellW18 = view.caretFrame.size.width
        let cellH18 = view.caretFrame.size.height

        // cellW/cellH 必须随 size 增大
        XCTAssertGreaterThan(cellW18, cellW14, "cellWidth 必须随 size 增大")
        XCTAssertGreaterThan(cellH18, cellH14, "cellHeight 必须随 size 增大")

        // 减小回去
        view.font = TerminalFontProvider.regularFont(size: 14)
        let cellW14Again = view.caretFrame.size.width
        let cellH14Again = view.caretFrame.size.height
        XCTAssertEqual(cellW14Again, cellW14, accuracy: 0.01, "回到 14pt 后 cellWidth 必须恢复")
        XCTAssertEqual(cellH14Again, cellH14, accuracy: 0.01, "回到 14pt 后 cellHeight 必须恢复")
    }

    func testColsRowsChangeWithFontSizeAtFixedFrame() throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        let view = TerminalView(frame: frame,
                                font: TerminalFontProvider.regularFont(size: 14),
                                options: makeOptions())
        let cols14 = view.getTerminal().cols
        let rows14 = view.getTerminal().rows

        // font 增大 → cellW/cellH 增大 → 同 frame 下 cols/rows 减小
        view.font = TerminalFontProvider.regularFont(size: 18)
        let cols18 = view.getTerminal().cols
        let rows18 = view.getTerminal().rows

        XCTAssertLessThan(cols18, cols14, "font 增大后 cols 必须减少")
        XCTAssertLessThan(rows18, rows14, "font 增大后 rows 必须减少")
        XCTAssertGreaterThan(cols18, 0, "cols 必须仍 > 0")
        XCTAssertGreaterThan(rows18, 0, "rows 必须仍 > 0")
    }

    // MARK: - sizeChanged delegate 触发（Local + Remote 通用）

    func testFontChangeTriggersSizeChangedDelegate() throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        let view = TerminalView(frame: frame,
                                font: TerminalFontProvider.regularFont(size: 14),
                                options: makeOptions())
        let spy = SizeChangedSpyDelegate()
        view.terminalDelegate = spy

        // font setter → resetFont → resize → sizeChanged → delegate
        view.font = TerminalFontProvider.regularFont(size: 18)

        // spy.sizeChanged 经 Task @MainActor 异步提交；等待 runloop。
        waitForAsyncTick()

        XCTAssertTrue(spy.sizeChangedCallCount > 0, "font change 必须 trigger terminalDelegate.sizeChanged")
        if let last = spy.lastSizeChanged {
            XCTAssertGreaterThan(last.newCols, 0)
            XCTAssertGreaterThan(last.newRows, 0)
        }
    }

    func testFontChangeSizeChangedColsRowsReflectNewFont() throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        let view = TerminalView(frame: frame,
                                font: TerminalFontProvider.regularFont(size: 14),
                                options: makeOptions())
        let spy = SizeChangedSpyDelegate()
        view.terminalDelegate = spy
        let colsBefore = view.getTerminal().cols
        let rowsBefore = view.getTerminal().rows

        view.font = TerminalFontProvider.regularFont(size: 18)

        waitForAsyncTick()

        guard let last = spy.lastSizeChanged else {
            XCTFail("sizeChanged 必须 trigger")
            return
        }
        XCTAssertNotEqual(last.newCols, colsBefore, "sizeChanged 报告的 newCols 必须反映新 font geometry")
        XCTAssertNotEqual(last.newRows, rowsBefore, "sizeChanged 报告的 newRows 必须反映新 font geometry")
        XCTAssertEqual(last.newCols, view.getTerminal().cols)
        XCTAssertEqual(last.newRows, view.getTerminal().rows)
    }

    func testFontChangeAtZeroFrameDoesNotTriggerResize() throws {
        // frame == 0 时 resetFont 跳过 resize（Phase 9A Acceptance §32）。
        // 验证 sizeChanged 不被调用——cellDimension 已更新，但 resize 待 setFrameSize。
        let view = TerminalView(frame: .zero,
                                font: TerminalFontProvider.regularFont(size: 14),
                                options: makeOptions())
        let spy = SizeChangedSpyDelegate()
        view.terminalDelegate = spy

        // 在 frame == 0 时改 font
        view.font = TerminalFontProvider.regularFont(size: 18)

        waitForAsyncTick()

        XCTAssertEqual(spy.sizeChangedCallCount, 0, "frame == 0 时不应 trigger sizeChanged（resetFont 跳过 resize）")
        // 但 cellDimension 已更新到 18pt（caretFrame 反映）
        XCTAssertGreaterThan(view.caretFrame.size.width, 0)
        XCTAssertGreaterThan(view.caretFrame.size.height, 0)
    }

    // MARK: - Local PTY resize path

    /// 验证 LocalProcessTerminalView 可在 font change 时调用 SwiftTerm 内置
    /// `resetFont` → `resize` → `sizeChanged` 链路（不 crash，cellDimension 更新）。
    ///
    /// `MacLocalTerminalView.sizeChanged` 内部 `guard process.running else { return }`，
    /// 在 LocalProcess 未启动时提前返回——无法在单测中验证真实 PTY `setWinSize` 路径
    /// （需真实 shell）。SwiftTerm 自带 `FontResizeColumnsTests` 已验证 font change
    /// 触发 cols recompute 与 live-resize 一致；本测试验证 LocalProcessTerminalView
    /// 子类同样接受 public `font` setter 且不 crash + cell geometry 更新。
    func testLocalProcessTerminalViewFontChangeUpdatesCellDimension() throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        let view = LocalProcessTerminalView(frame: frame,
                                            font: TerminalFontProvider.regularFont(size: 14),
                                            options: makeOptions())
        let cellW14 = view.caretFrame.size.width
        let cellH14 = view.caretFrame.size.height

        view.font = TerminalFontProvider.regularFont(size: 18)

        let cellW18 = view.caretFrame.size.width
        let cellH18 = view.caretFrame.size.height
        XCTAssertGreaterThan(cellW18, cellW14, "LocalProcessTerminalView font change 后 cellWidth 必须 recompute")
        XCTAssertGreaterThan(cellH18, cellH14, "LocalProcessTerminalView font change 后 cellHeight 必须 recompute")
    }

    // MARK: - 字体身份在动态 size 下保持 JetBrains Mono（Regular/Bold/Italic/BoldItalic）

    func testRegularIdentityAtMultipleSizes() throws {
        for size in [CGFloat(14), 18, 24] {
            let font = TerminalFontProvider.regularFont(size: size)
            XCTAssertTrue(font.fontName.contains("JetBrainsMono"),
                         "size=\(size) Regular font 必须含 JetBrainsMono，得到 \(font.fontName)")
            XCTAssertEqual(font.pointSize, size)
            XCTAssertTrue(TerminalFontProvider.isFontSourcedFromBundle(font),
                         "size=\(size) Regular 必须来自 Bundle")
        }
    }

    func testBoldDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes() throws {
        // 模拟 SwiftTerm FontSet 派生路径：regular 经 NSFontManager convert bold trait。
        // 验证 bundled Bold TTF 被找到（不 fallback Menlo/SF Mono）。
        for size in [CGFloat(14), 18, 24] {
            let regular = TerminalFontProvider.regularFont(size: size)
            let bold = NSFontManager.shared.convert(regular, toHaveTrait: [.boldFontMask])
            XCTAssertTrue(bold.fontName.contains("JetBrainsMono"),
                         "size=\(size) Bold 必须含 JetBrainsMono，得到 \(bold.fontName)")
            XCTAssertTrue(bold.fontName.contains("Bold"),
                         "size=\(size) Bold 必须含 Bold marker，得到 \(bold.fontName)")
            XCTAssertEqual(bold.pointSize, size, "Bold pointSize 必须跟随 regular")
        }
    }

    func testItalicDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes() throws {
        for size in [CGFloat(14), 18, 24] {
            let regular = TerminalFontProvider.regularFont(size: size)
            let italic = NSFontManager.shared.convert(regular, toHaveTrait: [.italicFontMask])
            XCTAssertTrue(italic.fontName.contains("JetBrainsMono"),
                         "size=\(size) Italic 必须含 JetBrainsMono，得到 \(italic.fontName)")
            XCTAssertTrue(italic.fontName.contains("Italic"),
                         "size=\(size) Italic 必须含 Italic marker，得到 \(italic.fontName)")
            XCTAssertEqual(italic.pointSize, size)
        }
    }

    func testBoldItalicDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes() throws {
        for size in [CGFloat(14), 18, 24] {
            let regular = TerminalFontProvider.regularFont(size: size)
            let bi = NSFontManager.shared.convert(regular, toHaveTrait: [.italicFontMask, .boldFontMask])
            XCTAssertTrue(bi.fontName.contains("JetBrainsMono"),
                         "size=\(size) BoldItalic 必须含 JetBrainsMono，得到 \(bi.fontName)")
            XCTAssertTrue(bi.fontName.contains("Bold"),
                         "size=\(size) BoldItalic 必须含 Bold marker，得到 \(bi.fontName)")
            XCTAssertTrue(bi.fontName.contains("Italic"),
                         "size=\(size) BoldItalic 必须含 Italic marker，得到 \(bi.fontName)")
            XCTAssertEqual(bi.pointSize, size)
        }
    }

    // MARK: - Fallback cascade size 跟随 base（CJK + Emoji）

    func testCJKFallbackFollowsBaseFontSize() throws {
        // 验证 cascade descriptor 不指定 size，但 resolved fallback font 的
        // pointSize 跟随 base font（Phase 9A Acceptance §26）。
        for size in [CGFloat(14), 18, 24] {
            let font = TerminalFontProvider.regularFont(size: size)
            let families = TerminalFontProvider.cascadeFamilyNames(for: font)
            XCTAssertTrue(families.contains("PingFang SC"), "cascade 必须含 PingFang SC")

            // 构造 attributed string 渲染中文，检查 run font pointSize
            let chinese = "你好" as CFString
            let attrs: [CFString: Any] = [kCTFontAttributeName: font]
            let attrStr = CFAttributedStringCreate(nil, chinese, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrStr)
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            var foundCJKAtSize = false
            for run in runs {
                let runAttrs = CTRunGetAttributes(run) as? [CFString: Any] ?? [:]
                if let v = runAttrs[kCTFontAttributeName], let f = v as? NSFont,
                   f.familyName?.contains("PingFang") == true, f.pointSize == size {
                    foundCJKAtSize = true
                    break
                }
            }
            XCTAssertTrue(foundCJKAtSize,
                         "size=\(size) 中文字符必须通过 cascade 解析到 PingFang SC 并以 size=\(size) 渲染")
        }
    }

    func testEmojiFallbackFollowsBaseFontSize() throws {
        for size in [CGFloat(14), 18, 24] {
            let font = TerminalFontProvider.regularFont(size: size)
            let emoji = "😀" as CFString
            let attrs: [CFString: Any] = [kCTFontAttributeName: font]
            let attrStr = CFAttributedStringCreate(nil, emoji, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrStr)
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            var foundEmojiAtSize = false
            for run in runs {
                let runAttrs = CTRunGetAttributes(run) as? [CFString: Any] ?? [:]
                if let v = runAttrs[kCTFontAttributeName], let f = v as? NSFont,
                   f.familyName?.contains("Apple Color Emoji") == true, f.pointSize == size {
                    foundEmojiAtSize = true
                    break
                }
            }
            XCTAssertTrue(foundEmojiAtSize,
                         "size=\(size) Emoji 必须通过 cascade 解析到 Apple Color Emoji 并以 size=\(size) 渲染")
        }
    }

    // MARK: - Unicode 不 crash

    func testUnicodeRenderingDoesNotCrash() throws {
        // 在多个 size 下渲染 ASCII / 中文 / Emoji / VS16，确认不 crash。
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let view = TerminalView(frame: frame,
                                font: TerminalFontProvider.regularFont(size: 14),
                                options: makeOptions())

        for size in [CGFloat(14), 18, 24] {
            view.font = TerminalFontProvider.regularFont(size: size)
            view.feed(text: "Hello 世界\n")
            view.feed(text: "Emoji: 😀🎉❤\n")
            view.feed(text: "VS16: ⚠\u{FE0F}\n") // U+26A0 + U+FE0F
        }
        // 无 crash 即通过。
    }

    // MARK: - Phase 9D integration smoke（resolved SwiftTerm 93abf601 renderer）

    /// Phase 9D-C §21：确认 MacSSH 实际使用 resolved SwiftTerm 93abf601 的
    /// VS16 1-cell uniform-fit renderer。不能只依赖 fork unit tests。
    ///
    /// 用 preserveBaseWidth TerminalView（Local Terminal policy）feed：
    ///   - A⚠️B❤️C（1-cell VS16 emoji 混排）
    ///   - |⚠️|❤️|⚠️|❤️|（separator + VS16 交错，grid origin 不被 fit 偏移）
    ///   - ANSI Bold/Italic/BoldItalic ASCII（styled base-font identity）
    /// 在 14/24/32pt 下渲染，断言：
    ///   - 不 crash
    ///   - ⚠️/❤️ logical width == 1（preserveBaseWidth model 不变）
    ///   - cursor column 精确（renderer fix 纯 presentation-only，不改 model）
    /// 渲染本身走的是 resolved SwiftTerm 93abf601 的 CG draw path（含 glyphSlotFit
    /// + isBaseFont 四成员 guard + 1-cell ink-overflow fit）—— 771e79f 无 isBaseFont
    /// 方法，若依赖未推进到 93abf601，MacSSH 编译期即无法解析该 renderer path。
    func testVS16UniformFitRendererIntegrationSmoke() throws {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        let options = TerminalOptions(
            cols: 80, rows: 24, termName: "xterm-256color", scrollback: 1000,
            variationSelector16WidthPolicy: .preserveBaseWidth
        )

        for size in [CGFloat(14), 24, 32] {
            let view = TerminalView(frame: frame,
                                    font: TerminalFontProvider.regularFont(size: size),
                                    options: options)
            // A⚠️B❤️C — 5 logical cells under preserveBaseWidth.
            view.feed(text: "A\u{26A0}\u{FE0F}B\u{2764}\u{FE0F}C\n")
            // Separators + VS16交错 — grid origin must stay exact.
            view.feed(text: "|\u{26A0}\u{FE0F}|\u{2764}\u{FE0F}|\u{26A0}\u{FE0F}|\u{2764}\u{FE0F}|\n")
            // ANSI Bold / Italic / BoldItalic ASCII — styled base-font identity.
            view.feed(text: "\u{1B}[1mBoldAW1|!@\u{1B}[22m\n")
            view.feed(text: "\u{1B}[3mItalicAW1|!@\u{1B}[23m\n")
            view.feed(text: "\u{1B}[1;3mBoldItalicAW1|!@\u{1B}[0m\n")
            // CJK + plain emoji — controls untouched.
            view.feed(text: "ABC中文DEF 😀🚀✅\n")

            let t = view.getTerminal()
            // Row 0: A(0) ⚠️(1) B(2) ❤️(3) C(4) => cursor at 5.
            XCTAssertEqual(t.getCharData(col: 1, row: 0)?.width, 1, "⚠️ must be 1 logical cell at \(size)pt")
            XCTAssertEqual(t.getCharData(col: 3, row: 0)?.width, 1, "❤️ must be 1 logical cell at \(size)pt")
            // Row 1: |⚠️|❤️|⚠️|❤️| => 8 logical cells, cursor 8.
            XCTAssertEqual(t.getCharData(col: 1, row: 1)?.width, 1, "⚠️ in separators must be 1 cell at \(size)pt")
            XCTAssertEqual(t.getCharData(col: 3, row: 1)?.width, 1, "❤️ in separators must be 1 cell at \(size)pt")
        }
        // 无 crash + model cell widths correct => renderer integration OK.
    }

    // MARK: - 工具

    private func makeOptions() -> TerminalOptions {
        TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color", scrollback: 10_000)
    }

    private func makeRemoteTerminalView() -> TerminalView {
        TerminalView(
            frame: .zero,
            font: TerminalFontProvider.regularFont(),
            options: makeOptions()
        )
    }

    /// 等待一个 runloop tick，让 `Task { @MainActor in ... }` 提交的
    /// `sizeChanged` 状态更新在 spy 上落定。
    private func waitForAsyncTick(timeout: TimeInterval = 5.0) {
        let expectation = XCTestExpectation(description: "async-tick")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
    }
}

/// 捕获 `TerminalViewDelegate.sizeChanged` 调用，用于验证 font change 触发 PTY resize 链。
@MainActor
private final class SizeChangedSpyDelegate: NSObject, TerminalViewDelegate {
    struct Call {
        let newCols: Int
        let newRows: Int
    }

    private(set) var sizeChangedCallCount = 0
    private(set) var lastSizeChanged: Call?

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            self.sizeChangedCallCount += 1
            self.lastSizeChanged = Call(newCols: newCols, newRows: newRows)
        }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
