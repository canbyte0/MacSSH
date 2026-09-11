import Foundation
import SwiftData
import SwiftTerm
import XCTest

@testable import MacSSH

/// 10D-B2 §3–§17/§40：terminal context 提取测试。
///
/// 两类证据：
/// - fixture adapter：精确控制 buffer 形态（行数 / wrapped / 尾部空行 /
///   超大 scrollback），并统计 probe 次数证明有界（§12）；
/// - pinned SwiftTerm 集成：用 `HeadlessTerminal` 驱动真实 buffer，证明
///   adapter 没接错（纯文本 / 无 ANSI / wrapped / alt screen / rows-cols）。
@MainActor
final class AgentTerminalContextTests: XCTestCase {
    // MARK: - Fixture adapter

    private final class FixtureBufferSource: AgentTerminalBufferSource {
        var rows = 24
        var columns = 80
        var isAlternateScreen = false
        var selectedText: String?
        var firstValidRow = 0
        var lines: [AgentTerminalLine] = []
        private(set) var probeCount = 0

        func line(atScrollInvariantRow row: Int) -> AgentTerminalLine? {
            probeCount += 1
            guard row >= firstValidRow, row < firstValidRow + lines.count else {
                return nil
            }
            return lines[row - firstValidRow]
        }
    }

    private func makeSource(
        _ texts: [String],
        wrapped: Set<Int> = [],
        firstValidRow: Int = 0,
        rows: Int = 24,
        columns: Int = 80,
        alternate: Bool = false,
        selection: String? = nil
    ) -> FixtureBufferSource {
        let source = FixtureBufferSource()
        source.firstValidRow = firstValidRow
        source.rows = rows
        source.columns = columns
        source.isAlternateScreen = alternate
        source.selectedText = selection
        source.lines = texts.enumerated().map { index, text in
            AgentTerminalLine(text: text, isWrapped: wrapped.contains(index))
        }
        return source
    }

    private func makeProvider(handles: [UUID: AgentTerminalSessionHandle]) -> TerminalAgentContextProvider {
        TerminalAgentContextProvider(handleLookup: { handles[$0] })
    }

    private func handle(
        id: UUID = UUID(),
        kind: AgentTerminalSessionKind = .local,
        directory: String? = nil,
        source: (any AgentTerminalBufferSource)? = nil
    ) -> AgentTerminalSessionHandle {
        AgentTerminalSessionHandle(
            id: id,
            sessionKind: kind,
            displayName: kind == .local ? "Local" : "test-host",
            workingDirectory: directory.map { AgentWorkingDirectory.fromOSC7URL("file://host\($0)") }
                ?? .unavailable,
            bufferSource: source
        )
    }

    // MARK: - 行数矩阵（§12/§13）

    func testEmptyBufferYieldsEmptyOutput() {
        let source = makeSource([])
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.bytesReturned, 0)
    }

    func testSingleLineOutput() {
        let source = makeSource(["only line"])
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertEqual(result.text, "only line")
        XCTAssertFalse(result.truncated)
    }

    func testTwentyFourLinesAreKeptInOrder() {
        let source = makeSource((0..<24).map { "line-\($0)" })
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertEqual(result.text.split(separator: "\n").count, 24)
        XCTAssertTrue(result.text.hasPrefix("line-0"))
        XCTAssertTrue(result.text.hasSuffix("line-23"))
    }

    func testTwoHundredRowsAreNotTruncated() {
        let source = makeSource((0..<200).map { "row-\($0)" })
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.text.split(separator: "\n").count, 200)
        XCTAssertTrue(result.text.hasPrefix("row-0"))
    }

    func testTwoHundredOneRowsAreCappedAndMarkedTruncated() {
        let source = makeSource((0..<201).map { "row-\($0)" })
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertTrue(result.truncated, "超出 200 physical rows 必须标记截断")
        XCTAssertEqual(result.text.split(separator: "\n").count, 200)
        XCTAssertFalse(result.text.contains("row-0"), "只取尾部 200 行")
        XCTAssertTrue(result.text.hasSuffix("row-200"))
    }

    func testTenThousandLineScrollbackUsesBoundedProbes() {
        let source = makeSource((0..<10_000).map { "row-\($0)" })
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        // 总行访问 = 探测次数 + 实际取用的 200 行；探测部分必须 ≤ 32（§12）。
        let probes = source.probeCount - 200
        XCTAssertLessThanOrEqual(
            probes,
            TerminalRecentOutputSnapshotter.maxProbes,
            "绝不得 O(10,000) 扫描后才取 200 行（§12）"
        )
        XCTAssertEqual(result.text.split(separator: "\n").count, 200)
        XCTAssertTrue(result.text.hasSuffix("row-9999"))
    }

    func testTrimmedScrollbackStartsAtFirstValidRow() {
        // 已被裁剪的历史行（firstValidRow = 5000）：探测必须从有效起点开始。
        let source = makeSource((0..<300).map { "row-\($0)" }, firstValidRow: 5_000)
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertTrue(result.text.hasSuffix("row-299"))
        XCTAssertEqual(result.text.split(separator: "\n").count, 200)
    }

    // MARK: - wrapped / 尾部空行（§13/§14）

    func testWrappedRowsAreJoinedWithoutExtraNewline() {
        let source = makeSource(["long-command-start", "continuation-tail"], wrapped: [1])
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertEqual(result.text, "long-command-startcontinuation-tail")
        XCTAssertFalse(result.text.contains("\n"), "软换行绝不插入新换行（§13）")
    }

    func testWrappedRowStillCountsTowardsPhysicalRowCap() {
        // 250 physical rows（其中 50 行是续行）→ 仍按 physical rows 上限截断。
        var texts = [String]()
        for index in 0..<250 {
            texts.append("seg-\(index)")
        }
        let source = makeSource(texts, wrapped: Set(1..<250))
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.text.contains("\n"), "全是续行 → 合并为单个 logical line")
    }

    func testTrailingBlankRowsAreTrimmedButInteriorPreserved() {
        let source = makeSource(["first", "   ", "", "middle", "  ", ""])
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertEqual(result.text, "first\n   \n\nmiddle", "只裁尾部纯空白行（§14）")
    }

    func testLeadingSpacesArePreserved() {
        let source = makeSource(["    indented", "normal"])
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertTrue(result.text.hasPrefix("    indented"))
    }

    // MARK: - 预算（§4/§5）

    func testSelectionAndOutputShareTextualPayloadBudget() {
        let bigLine = String(repeating: "a", count: 2_000)
        let source = makeSource(
            (0..<200).map { _ in bigLine },
            selection: String(repeating: "s", count: AgentTextLimits.selectionMaxBytes)
        )
        let context = snapshotContext(source: source, selection: source.selectedText)
        XCTAssertEqual(context.selectedText?.utf8.count, AgentTextLimits.selectionMaxBytes)
        XCTAssertFalse(context.selectionTruncated)
        XCTAssertTrue(context.outputTruncated)
        XCTAssertEqual(
            context.recentOutput.utf8.count,
            AgentTextLimits.terminalTextualPayloadMaxBytes - AgentTextLimits.selectionMaxBytes,
            "recent output 只能用总预算的剩余部分（§4）"
        )
        let total = (context.selectedText?.utf8.count ?? 0) + context.recentOutput.utf8.count
        XCTAssertLessThanOrEqual(total, AgentTextLimits.terminalTextualPayloadMaxBytes)
    }

    func testSelectionTruncationAt64KiB() {
        let selection = String(repeating: "中", count: 30_000) // 90,000 bytes > 64 KiB
        let context = snapshotContext(source: makeSource(["out"]), selection: selection)
        XCTAssertTrue(context.selectionTruncated)
        XCTAssertLessThanOrEqual(
            context.selectedText?.utf8.count ?? 0,
            AgentTextLimits.selectionMaxBytes
        )
    }

    func testUnicodeAndEmojiSurviveByteBudget() {
        let source = makeSource(["中文输出 😀 完成", "second 😀😀"])
        let context = snapshotContext(source: source, selection: nil)
        XCTAssertTrue(context.recentOutput.contains("中文输出 😀 完成"))
        XCTAssertFalse(context.outputTruncated)
    }

    // MARK: - selection / alt screen / rows / cols（§16/§17）

    func testNoSelectionYieldsNil() {
        let context = snapshotContext(source: makeSource(["x"], selection: nil), selection: nil)
        XCTAssertNil(context.selectedText)
        XCTAssertFalse(context.selectionTruncated)
    }

    func testEmptySelectionIsTreatedAsNoSelection() {
        let source = makeSource(["x"], selection: "")
        let context = snapshotContext(source: source, selection: source.selectedText)
        XCTAssertNil(context.selectedText)
    }

    func testAlternateScreenFlagIsReported() {
        let source = makeSource(["alt"], alternate: true)
        let context = snapshotContext(source: source, selection: nil)
        XCTAssertTrue(context.alternateScreen)
        XCTAssertEqual(context.recentOutput, "alt", "alt screen 时读取 active buffer（§16）")
    }

    func testRowsAndColumnsAreReported() {
        let source = makeSource(["x"], rows: 40, columns: 120)
        let context = snapshotContext(source: source, selection: nil)
        XCTAssertEqual(context.rows, 40)
        XCTAssertEqual(context.columns, 120)
    }

    func testMissingBufferSourceYieldsZeroGeometryAndEmptyOutput() {
        let id = UUID()
        let provider = makeProvider(handles: [id: handle(id: id, source: nil)])
        let context = try? XCTUnwrap(provider.snapshot(for: id))
        XCTAssertEqual(context?.rows, 0)
        XCTAssertEqual(context?.columns, 0)
        XCTAssertEqual(context?.recentOutput, "")
        XCTAssertNil(context?.selectedText)
    }

    // MARK: - session 绑定（§6）

    func testSnapshotIsBoundToExplicitSessionIDNotActiveSession() {
        // 引用语义容器：provider 的查找闭包必须看到后续移除，才能证明
        // 「A 关闭后绝不 fallback 到 B」。
        final class Store {
            var handles: [UUID: AgentTerminalSessionHandle] = [:]
        }
        let store = Store()
        let provider = TerminalAgentContextProvider(handleLookup: { store.handles[$0] })
        let idA = UUID()
        let idB = UUID()
        store.handles = [
            idA: handle(id: idA, directory: "/tmp/A", source: makeSource(["output-A"])),
            idB: handle(id: idB, directory: "/tmp/B", source: makeSource(["output-B"]))
        ]

        // 模拟「用户 active tab 切到 B」：provider 只按 sessionID 查找，
        // 不持有任何 active / selected 状态。
        _ = store.handles[idB]
        let contextA = provider.snapshot(for: idA)
        XCTAssertEqual(contextA?.recentOutput, "output-A")
        XCTAssertEqual(contextA?.sessionID, idA)

        // A 关闭 → nil，绝不 fallback 到 B。
        store.handles.removeValue(forKey: idA)
        XCTAssertNil(provider.snapshot(for: idA))
        XCTAssertEqual(provider.snapshot(for: idB)?.recentOutput, "output-B")
    }

    func testUnknownSessionYieldsNil() {
        let provider = makeProvider(handles: [:])
        XCTAssertNil(provider.snapshot(for: UUID()))
    }

    func testCurrentDirectoryResultKeepsConfidence() {
        let id = UUID()
        let provider = makeProvider(handles: [id: handle(id: id, directory: "/tmp/project")])
        let result = provider.currentDirectory(for: id)
        XCTAssertEqual(result?.workingDirectory.path, "/tmp/project")
        XCTAssertEqual(result?.workingDirectory.confidence, .authoritative)
        XCTAssertEqual(result?.workingDirectory.source, .osc7)
    }

    func testCurrentDirectoryUnavailableIsReportedAsUnavailableNotNilPath() {
        let id = UUID()
        let provider = makeProvider(handles: [id: handle(id: id, directory: nil)])
        let result = provider.currentDirectory(for: id)
        XCTAssertNil(result?.workingDirectory.path)
        XCTAssertEqual(result?.workingDirectory.confidence, .unavailable)
    }

    // MARK: - pinned SwiftTerm 集成（§40）

    func testRealTerminalExtractionIsPlainTextWithoutANSI() {
        let headless = HeadlessTerminal(onEnd: { _ in })
        headless.terminal.feed(text: "\u{1B}[31mRED-ALERT\u{1B}[0m\nsecond line\n")
        let source = SwiftTermTerminalBufferSource(terminal: headless.terminal)
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertTrue(result.text.contains("RED-ALERT"))
        XCTAssertFalse(result.text.contains("\u{1B}"), "绝不向模型暴露 SGR / ANSI（§15）")
        XCTAssertFalse(result.text.contains("[31m"))
        XCTAssertTrue(result.text.contains("second line"))
    }

    func testRealTerminalWrappedRowsAreMerged() {
        let headless = HeadlessTerminal(
            options: TerminalOptions(cols: 20, rows: 10),
            onEnd: { _ in }
        )
        headless.terminal.feed(text: String(repeating: "A", count: 50))
        let source = SwiftTermTerminalBufferSource(terminal: headless.terminal)
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertEqual(result.text, String(repeating: "A", count: 50), "wrapped 续行合并为一行")
        XCTAssertFalse(result.text.contains("\n"))
    }

    func testRealTerminalAlternateScreenIsDetected() {
        let headless = HeadlessTerminal(onEnd: { _ in })
        headless.terminal.feed(text: "normal-line\n")
        XCTAssertFalse(headless.terminal.isCurrentBufferAlternate)
        headless.terminal.feed(text: "\u{1B}[?1049h")
        XCTAssertTrue(headless.terminal.isCurrentBufferAlternate, "alt screen 激活（§16）")
        headless.terminal.feed(text: "alt-line\n")
        let source = SwiftTermTerminalBufferSource(terminal: headless.terminal)
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertTrue(source.isAlternateScreen)
        XCTAssertTrue(result.text.contains("alt-line"), "读 active buffer，绝不偷切回 scrollback")
        XCTAssertFalse(result.text.contains("normal-line"))
    }

    func testRealTerminalReportsRowsAndColumns() {
        let headless = HeadlessTerminal(
            options: TerminalOptions(cols: 100, rows: 30),
            onEnd: { _ in }
        )
        let source = SwiftTermTerminalBufferSource(terminal: headless.terminal)
        XCTAssertEqual(source.rows, 30)
        XCTAssertEqual(source.columns, 100)
        XCTAssertEqual(source.firstValidRow, 0)
    }

    /// 宽字符（CJK / Emoji）在 terminal buffer 里占 2 cell，后续 cell 是
    /// NUL padding：提取必须跳过，绝不能把 NUL 交给模型层。
    ///
    /// 实测 pinned SwiftTerm `40d473b1`：astral emoji（U+1F600）在 buffer
    /// 里被渲染为「宽占位 + padding」，因此 context 得到的是占位间距而非
    /// emoji 本身——这是 upstream 渲染行为（与 App 真实 terminal 同一
    /// 代码路径），不是本层提取缺陷；emoji 的字节级完整性由 fixture 用例
    /// `testUnicodeAndEmojiSurviveByteBudget` 覆盖。
    func testRealTerminalWideCharactersProduceNoNullPadding() {
        let headless = HeadlessTerminal(onEnd: { _ in })
        headless.terminal.feed(text: "中文 输出 😀 ok\n")
        let source = SwiftTermTerminalBufferSource(terminal: headless.terminal)
        let result = TerminalRecentOutputSnapshotter.snapshot(
            source: source, byteBudget: AgentTextLimits.terminalTextualPayloadMaxBytes
        )
        XCTAssertFalse(result.text.contains("\0"), "宽字符 padding NUL 必须被跳过")
        XCTAssertFalse(result.text.contains("\u{FFFD}"))
        XCTAssertTrue(result.text.contains("中文"))
        XCTAssertTrue(result.text.contains("输出"))
        XCTAssertTrue(result.text.contains("ok"))
    }

    // MARK: - 生产装配：真实 Local session（§45）

    /// 用真实 `SessionManager` + 真实 Local shell 会话验证生产装配：
    /// provider 只按 sessionID 取值，且能读到真实 SwiftTerm view 的几何。
    func testProductionProviderReadsRealLocalSessionByID() async throws {
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let manager = SessionManager(sshService: SSHService(modelContainer: container))
        let first = manager.createLocalSession()
        let second = manager.createLocalSession()
        let provider = TerminalAgentContextProvider(sessionManager: manager)

        let contextFirst = provider.snapshot(for: first.id)
        XCTAssertEqual(contextFirst?.sessionID, first.id)
        XCTAssertEqual(contextFirst?.sessionKind, .local)
        XCTAssertEqual(contextFirst?.targetDisplayName, "Local")
        XCTAssertGreaterThan(contextFirst?.rows ?? 0, 0, "必须读到真实 SwiftTerm view 的 rows")
        XCTAssertGreaterThan(contextFirst?.columns ?? 0, 0)

        let contextSecond = provider.snapshot(for: second.id)
        XCTAssertEqual(contextSecond?.sessionID, second.id)
        XCTAssertNotEqual(contextFirst?.sessionID, contextSecond?.sessionID)

        // 未知 / 已关闭 session：nil，绝不 fallback 到其它会话。
        let removedID = first.id
        await manager.closeSession(id: removedID)
        XCTAssertNil(provider.snapshot(for: removedID))
        await manager.closeSession(id: second.id)
    }

    // MARK: - 辅助

    private func snapshotContext(
        source: FixtureBufferSource,
        selection: String?
    ) -> AgentTerminalContext {
        let id = UUID()
        source.selectedText = selection
        let provider = makeProvider(handles: [id: handle(id: id, source: source)])
        guard let context = provider.snapshot(for: id) else {
            fatalError("unexpected nil snapshot")
        }
        return context
    }
}
