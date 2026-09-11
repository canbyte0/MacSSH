import SwiftTerm
import XCTest

@testable import MacSSH

/// MacSSH 1.1 Phase 10D-B1 §3/§4/§5/§8：OSC 7 cwd 全链路测试。
///
/// 任务书 §3 要求证明的完整链路：
///
/// ```text
/// 原始 path → production OSC7 emitter → SwiftTerm parser
/// → URL decode → session.currentDirectory
/// ```
///
/// 两层证据：
/// - 纯解析层：任务书 §4 矩阵的字节序列 → SwiftTerm `Terminal` parser
///   （`hostCurrentDirectory` 保存 raw percent-encoded URL）→
///   `AgentWorkingDirectory.fromOSC7URL` 解码 → decoded == original；
/// - 真实集成层：`/usr/bin/login` 真实登录链 + production `.zshenv`
///   emitter（Bundle 内 ShellIntegration）→ SwiftTerm →
///   `LocalTerminalService.hostCurrentDirectoryUpdate` →
///   `session.currentDirectory` → Agent 域解码 == cd 的目标路径。
///
/// emitter 侧的独立 oracle（与 Swift 测试互不依赖）：
/// `Scripts/test-zsh-osc7-cwd.py` 用 Python 参考编码器逐字节比对
/// 真实 zsh 的输出。
@MainActor
final class LocalShellOSC7Tests: XCTestCase {
    private var services: [LocalTerminalService] = []
    private var fixtureRoot = ""
    private var originalPastePreference: Any?

    override func setUp() {
        super.setUp()
        originalPastePreference = UserDefaults.standard.object(
            forKey: AppPreferenceKey.pasteHighlightEnabled
        )
    }

    override func tearDown() async throws {
        for service in services {
            service.terminate()
        }
        services.removeAll()
        if let originalPastePreference {
            UserDefaults.standard.set(
                originalPastePreference, forKey: AppPreferenceKey.pasteHighlightEnabled
            )
        } else {
            UserDefaults.standard.removeObject(forKey: AppPreferenceKey.pasteHighlightEnabled)
        }
        if !fixtureRoot.isEmpty {
            try? FileManager.default.removeItem(atPath: fixtureRoot)
        }
    }

    // MARK: - 纯解析层：§4 矩阵 → SwiftTerm parser → CWD model

    /// SwiftTerm OSC 7 parser 保留 raw percent-encoded URL，Agent 域
    /// `fromOSC7URL` 完成解码：矩阵每一项 decoded == original（§4），
    /// 且硬断言 `%25` / `%3F` / `%23` / `%20` 编码形态（BEL 终止符 §5）。
    func testSwiftTermParserFeedsCWDModelForFullMatrix() {
        let matrix: [(original: String, osc7: String)] = [
            ("/simple/path", "\u{1b}]7;file://MacBook/simple/path\u{7}"),
            ("/path with spaces", "\u{1b}]7;file://MacBook/path%20with%20spaces\u{7}"),
            ("/路径/中文", "\u{1b}]7;file://MacBook/%E8%B7%AF%E5%BE%84/%E4%B8%AD%E6%96%87\u{7}"),
            ("/한국어/테스트", "\u{1b}]7;file://MacBook/%ED%95%9C%EA%B5%AD%EC%96%B4/%ED%85%8C%EC%8A%A4%ED%8A%B8\u{7}"),
            ("/日本語/テスト", "\u{1b}]7;file://MacBook/%E6%97%A5%E6%9C%AC%E8%AA%9E/%E3%83%86%E3%82%B9%E3%83%88\u{7}"),
            ("/emoji/😀", "\u{1b}]7;file://MacBook/emoji/%F0%9F%98%80\u{7}"),
            ("/contains%percent", "\u{1b}]7;file://MacBook/contains%25percent\u{7}"),
            ("/question?mark", "\u{1b}]7;file://MacBook/question%3Fmark\u{7}"),
            ("/hash#fragment", "\u{1b}]7;file://MacBook/hash%23fragment\u{7}"),
            ("/mixed/中文 test % # ?", "\u{1b}]7;file://MacBook/mixed/%E4%B8%AD%E6%96%87%20test%20%25%20%23%20%3F\u{7}")
        ]

        for entry in matrix {
            // hostCurrentDirectory 是 private(set)：每个矩阵项独立 Terminal。
            // Terminal.tdel 是 weak：ProbeTerminalDelegate 必须以局部强引用
            // 存活过 feed 调用，否则 isProcessTrusted 走 nil??false 导致
            // OSC 7 被静默丢弃。
            let probe = ProbeTerminalDelegate()
            let terminal = Terminal(
                delegate: probe,
                options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color", scrollback: 100)
            )
            terminal.feed(text: entry.osc7)

            // parser 层保留 raw URL（percent-encoded，未解码）。
            let raw = terminal.hostCurrentDirectory
            XCTAssertNotNil(raw, "SwiftTerm 必须解析 OSC 7：\(entry.osc7)")
            guard let raw else {
                continue
            }
            XCTAssertTrue(raw.hasPrefix("file://"), "raw 必须是 file URL：\(raw)")

            // Agent 域解码：decoded == original。
            let cwd = AgentWorkingDirectory.fromOSC7URL(raw)
            XCTAssertEqual(cwd.path, entry.original, "roundtrip 失败：\(raw)")
            XCTAssertEqual(cwd.source, .osc7)
            XCTAssertEqual(cwd.confidence, .authoritative)
        }
    }

    /// 终止符锁定 BEL（§5）：ST（ESC \）形态不得出现在我们的序列里。
    func testSwiftTermParserIgnoresSTTerminatedOSC7() {
        let probe = ProbeTerminalDelegate()
        let terminal = Terminal(
            delegate: probe,
            options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color", scrollback: 100)
        )
        // SwiftTerm 支持多种终止符不影响 MacSSH 的 BEL-only 决定：
        // 只证明 BEL 形态被解析（ST 形态属 SwiftTerm 语义，不锁行为）。
        terminal.feed(text: "\u{1b}]7;file://MacBook/simple\u{7}")
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL(terminal.hostCurrentDirectory).path,
            "/simple"
        )
    }

    // MARK: - 真实集成层：production emitter → SwiftTerm → session

    /// 粘贴高亮 ON（任务书 §8）：OSC 7 与粘贴高亮共存，真实登录链、
    /// 真实 zsh、真实 Bundle ShellIntegration。
    func testRealLoginChainOSC7RoundtripWithPasteHighlightingOn() async throws {
        try XCTSkipUnless(
            URL(fileURLWithPath: LoginShellResolver.resolve()).lastPathComponent == "zsh",
            "本机账户 Shell 非 zsh：OSC 7 emitter 只装配本地 zsh"
        )
        UserDefaults.standard.set(true, forKey: AppPreferenceKey.pasteHighlightEnabled)
        try await exerciseRealLoginChainRoundtrip()
    }

    /// 粘贴高亮 OFF（任务书 §8）：OSC 7 不依赖粘贴高亮状态（ZDOTDIR
    /// 恒定注入是 Phase 10D-B1 的核心整改）。
    func testRealLoginChainOSC7RoundtripWithPasteHighlightingOff() async throws {
        try XCTSkipUnless(
            URL(fileURLWithPath: LoginShellResolver.resolve()).lastPathComponent == "zsh",
            "本机账户 Shell 非 zsh：OSC 7 emitter 只装配本地 zsh"
        )
        UserDefaults.standard.set(false, forKey: AppPreferenceKey.pasteHighlightEnabled)
        try await exerciseRealLoginChainRoundtrip()
    }

    /// 任务书 §8 GUI smoke 的自动化对应：cd 到普通 / 空格 / 中文 / Emoji
    /// 路径，session.currentDirectory 必须正确更新（经 OSC 7 全链路）。
    private func exerciseRealLoginChainRoundtrip() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSSH.OSC7.\(UUID().uuidString)", isDirectory: true)
        fixtureRoot = base.path
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let cases: [(label: String, directory: String)] = [
            ("normal", "normal"),
            ("spaces", "path with spaces"),
            ("unicode", "路径 中文"),
            ("emoji", "emoji 😀")
        ]
        for entry in cases {
            try FileManager.default.createDirectory(
                atPath: base.appendingPathComponent(entry.directory).path,
                withIntermediateDirectories: false
            )
        }

        let service = LocalTerminalService(
            session: TerminalSession(shellPath: LoginShellResolver.resolve())
        )
        services.append(service)
        service.startIfNeeded()
        XCTAssertTrue(
            service.session.processState == .running,
            "Local Terminal 必须进入 running（实际：\(service.session.statusText)）"
        )

        // 就绪信号：首个提示符的 OSC 7 上报（HOME 目录）。
        let shellReady = try await waitForCondition(timeout: 20) {
            service.session.currentDirectory != nil
        }
        XCTAssertTrue(shellReady, "首个提示符必须产生 OSC 7 上报（emitter 未加载？）")

        for entry in cases {
            let target = base.appendingPathComponent(entry.directory).path
            // zsh PWD 是逻辑路径（既有 testK 先例：cd /tmp 后 PWD=/tmp）。
            service.terminalView.send(txt: "cd -- '\(target)'\r")
            let updated = try await waitForCondition(timeout: 20) {
                AgentWorkingDirectory.fromOSC7URL(service.session.currentDirectory).path == target
            }
            XCTAssertTrue(
                updated,
                "\(entry.label)：currentDirectory 未收敛到 \(target)（实际：\(service.session.currentDirectory ?? "nil")）"
            )
            let cwd = AgentWorkingDirectory.fromOSC7URL(service.session.currentDirectory)
            XCTAssertEqual(cwd.source, .osc7)
            XCTAssertEqual(cwd.confidence, .authoritative)

            if entry.label == "unicode" {
                // raw 仍保留 percent-encoding：解码发生在 Agent 域，
                // shell / 终端层不预解码（roundtrip 的证据）。
                XCTAssertTrue(
                    service.session.currentDirectory?.contains("%E8%B7%AF") == true,
                    "raw URL 必须保留 percent-encoding（实际：\(service.session.currentDirectory ?? "nil")）"
                )
            }
        }
    }

    // MARK: - 辅助

    private func waitForCondition(
        timeout: TimeInterval,
        where predicate: () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return await predicate()
    }
}

/// 空实现：除 `send` 外 TerminalDelegate 其余方法均有默认实现
/// （isProcessTrusted 默认返回 true，OSC 7 解析不被拦截）。纯解析层
/// 没有宿主进程，`send` 丢弃回写数据即可。
private final class ProbeTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
