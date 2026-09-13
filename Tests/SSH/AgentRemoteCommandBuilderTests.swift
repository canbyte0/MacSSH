import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B3 §31–§41/§90–§96：Remote exec payload（cwd wrapper + 原 command）。
///
/// 这些测试是**纯字符串证明**：wrapper 只增加「进入 approved cwd」前缀，
/// 模型 command 的字节序列绝不改变，cwd 中的任意 shell 元字符都不能产生
/// 额外 token / 注入第二条命令。
final class AgentRemoteCommandBuilderTests: XCTestCase {
    private func payload(
        _ command: String,
        cwd: String = "/tmp/project"
    ) throws -> String {
        switch AgentRemoteCommandBuilder.build(command: command, workingDirectory: cwd) {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    // MARK: - §38/§39 wrapper 形状 + 原 command 逐字节保留

    func testWrapperIsCWDGuardFollowedByVerbatimCommand() throws {
        let command = "printf 'A\\n'\nprintf 'B\\n'"
        let built = try payload(command)
        XCTAssertEqual(built, "cd '/tmp/project' || exit $?\n" + command)
        XCTAssertTrue(built.hasSuffix("\n" + command), "原 command 必须是 payload 的精确后缀")
    }

    func testCommandIsNeverTrimmedOrNormalized() throws {
        let command = "  printf '<%s>' '  keep  '  \n"
        let built = try payload(command)
        XCTAssertTrue(built.hasSuffix(command), "空白 / 结尾换行绝不 trim / 规范化")
        XCTAssertEqual(built.components(separatedBy: "\n").dropFirst().joined(separator: "\n"), command)
    }

    func testDollarAndBacktickInCommandAreNotExpandedClientSide() throws {
        let command = #"printf '%s\n' '$HOME' "`uname`""#
        let built = try payload(command)
        XCTAssertTrue(built.hasSuffix(command), "§91：$HOME / 反引号绝不在 client 侧展开")
    }

    func testMultilineCommandStaysMultiline() throws {
        let command = "printf A\nprintf B"
        let built = try payload(command)
        XCTAssertEqual(built, "cd '/tmp/project' || exit $?\nprintf A\nprintf B")
        XCTAssertEqual(built.components(separatedBy: "\n").count, 3)
    }

    func testCommentFirstCommandRemainsValidAfterWrapper() throws {
        let command = "# first line\nprintf ok"
        let built = try payload(command)
        XCTAssertEqual(built, "cd '/tmp/project' || exit $?\n# first line\nprintf ok")
        // wrapper 行之后才是注释行：注释不会吞掉 wrapper，wrapper 也不会
        // 让注释行变成语法错误（两行都在 original command 内）。
        XCTAssertEqual(built.components(separatedBy: "\n").count, 3)
    }

    func testHereDocumentIsNotBrokenByWrapper() throws {
        let command = "cat <<'MACSSH_EOF'\nhello\nMACSSH_EOF"
        let built = try payload(command)
        XCTAssertEqual(built, "cd '/tmp/project' || exit $?\n" + command)
        XCTAssertTrue(built.hasSuffix(command), "§41/§94：here-doc 语义（含终止符）绝不被 wrapper 破坏")
    }

    // MARK: - §36/§37 cwd 单引号引用（注入面）

    func testCWDWithSpacesIsSingleQuoted() throws {
        let built = try payload("pwd", cwd: "/tmp/a b")
        XCTAssertEqual(built, "cd '/tmp/a b' || exit $?\npwd")
    }

    func testCWDWithSingleQuoteUsesEscapeSequence() throws {
        let built = try payload("pwd", cwd: "/tmp/it's")
        XCTAssertEqual(built, "cd '/tmp/it'\\''s' || exit $?\npwd")
        XCTAssertEqual(
            AgentRemoteCommandBuilder.shellSingleQuote("/tmp/it's"),
            "'/tmp/it'\\''s'"
        )
    }

    func testCWDWithDoubleQuoteDollarBacktickBackslashAreLiteral() throws {
        for cwd in ["/tmp/a\"b", "/tmp/$HOME", "/tmp/`uname`", "/tmp/a\\b"] {
            let built = try payload("pwd", cwd: cwd)
            XCTAssertEqual(
                built,
                "cd '" + cwd + "' || exit $?\npwd",
                "cwd \(cwd) 必须整体落在单引号内（零展开）"
            )
        }
    }

    func testCWDWithUnicodeEmojiHashPercentQuestionAreLiteral() throws {
        for cwd in ["/tmp/中文目录", "/tmp/😀", "/tmp/a#b", "/tmp/a%b", "/tmp/a?b", "/tmp/a!b"] {
            let built = try payload("pwd", cwd: cwd)
            XCTAssertEqual(built, "cd '" + cwd + "' || exit $?\npwd")
        }
    }

    func testCWDWithNewlineStaysInsideSingleQuotes() throws {
        let cwd = "/tmp/a\nb"
        let built = try payload("pwd", cwd: cwd)
        // 换行落在单引号内 ⇒ shell 仍视为同一个 token（不产生第二条命令）。
        XCTAssertEqual(built, "cd '/tmp/a\nb' || exit $?\npwd")
    }

    func testCWDInjectionPayloadsProduceNoExtraTokens() throws {
        let hostilePaths = [
            "/tmp/x'; rm -rf /tmp/marker; echo '",
            "/tmp/x$(touch /tmp/marker)",
            "/tmp/x`touch /tmp/marker`",
            "/tmp/x\ntouch /tmp/marker",
        ]
        for cwd in hostilePaths {
            let built = try payload("pwd", cwd: cwd)
            // wrapper 的前缀必须恰为「cd + 整体引用的 cwd + guard」，其后只有
            // 原 command：hostile 字符全部留在单引号内（零展开 / 零提前闭合）。
            XCTAssertTrue(
                built.hasPrefix(
                    "cd " + AgentRemoteCommandBuilder.shellSingleQuote(cwd) + " || exit $?\n"
                ),
                "cwd 必须整体被引用：\(cwd)"
            )
            XCTAssertTrue(built.hasSuffix("\npwd"))
        }
    }

    /// 用真实 `/bin/sh` 证明 wrapper 的注入面：cwd 不存在 ⇒ guard 立即退出、
    /// 原 command 零执行；cwd 存在（含单引号 / 空格）⇒ 精确进入该目录。
    func testHostileCWDWrapperThroughRealShell() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macssh-b3-builder-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 1) 不存在的 hostile cwd：cd 失败 ⇒ `|| exit $?` 生效 ⇒ 原 command 零执行。
        let marker = workspace.appendingPathComponent("marker").path
        let missingCWD = workspace.appendingPathComponent("missing'; touch \"\(marker)\" ;'").path
        let missingPayload = try payload("touch '\(marker)'", cwd: missingCWD)
        let missingRun = try runThroughShell(missingPayload, workingDirectory: workspace.path)
        XCTAssertNotEqual(missingRun.exitCode, 0, "cwd 不存在 ⇒ 原 command 零执行（非零退出）")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker),
            "§37：cwd 中的引号必须被转义，绝不产生额外 shell token"
        )

        // 2) 真实存在的 hostile cwd（空格 + 单引号）：精确进入该目录。
        let tricky = workspace.appendingPathComponent("dir with 'quote' and spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: tricky, withIntermediateDirectories: true)
        let trickyPayload = try payload("pwd -P", cwd: tricky.path)
        let trickyRun = try runThroughShell(trickyPayload, workingDirectory: "/")
        XCTAssertEqual(trickyRun.exitCode, 0)
        // 用 inode 身份比较（`pwd -P` 会解析 /var → /private/var 等符号链接，
        // 字符串比较不可靠）：报告路径必须就是 approved cwd 指向的真实目录。
        let reportedPath = trickyRun.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedIdentity = try fileIdentity(reportedPath)
        let expectedIdentity = try fileIdentity(tricky.path)
        XCTAssertEqual(reportedIdentity.device, expectedIdentity.device)
        XCTAssertEqual(reportedIdentity.inode, expectedIdentity.inode)
    }

    /// (device, inode) 身份：与路径字符串 / 符号链接无关。
    private func fileIdentity(_ path: String) throws -> (device: dev_t, inode: ino_t) {
        var status = stat()
        guard stat(path, &status) == 0 else {
            throw NSError(domain: "AgentRemoteCommandBuilderTests", code: 1)
        }
        return (status.st_dev, status.st_ino)
    }

    /// 用 `/bin/sh -c` 执行 payload（等价 remote shell 的 exec 语义）。
    private func runThroughShell(
        _ payload: String,
        workingDirectory: String
    ) throws -> (exitCode: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", payload]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - §38 cwd 失败守卫

    func testCWDFailureGuardPreventsOriginalCommandExecution() throws {
        let built = try payload("touch /tmp/should-not-exist", cwd: "/tmp/does-not-exist")
        let firstLine = try XCTUnwrap(built.components(separatedBy: "\n").first)
        XCTAssertEqual(firstLine, "cd '/tmp/does-not-exist' || exit $?")
        XCTAssertTrue(
            firstLine.hasSuffix("|| exit $?"),
            "§95：cwd 进入失败必须以 remote shell 非零码退出，绝不 fallback 默认目录"
        )
    }

    // MARK: - §96 长度上界（溢出安全的确定性错误）

    func testCommandAtMaximumLengthStillBuilds() throws {
        let command = String(repeating: "a", count: AgentCommandLimits.maxCommandBytes)
        let built = try payload(command)
        XCTAssertEqual(
            built.utf8.count,
            "cd '/tmp/project' || exit $?\n".utf8.count + AgentCommandLimits.maxCommandBytes
        )
    }

    func testOversizedWorkingDirectoryFailsDeterministically() {
        let oversized = "/" + String(repeating: "a", count: AgentRemoteCommandExecutionLimits.maxWorkingDirectoryBytes)
        switch AgentRemoteCommandBuilder.build(command: "pwd", workingDirectory: oversized) {
        case .success:
            XCTFail("越界 cwd 必须返回 deterministic 错误（绝不 silent truncate）")
        case .failure(let error):
            XCTAssertEqual(error, .execPayloadTooLarge)
        }
    }

    func testPayloadLimitIsLargeEnoughForMaximumCommandAndCWD() throws {
        // 16 KiB command + 8 KiB cwd 仍必须成功（上界不误伤合法输入）。
        let command = String(repeating: "b", count: AgentCommandLimits.maxCommandBytes)
        let cwd = "/" + String(repeating: "c", count: AgentRemoteCommandExecutionLimits.maxWorkingDirectoryBytes - 1)
        let built = try payload(command, cwd: cwd)
        XCTAssertTrue(built.hasSuffix(command))
    }

    func testQuoteHelperIsIdempotentForSafePaths() {
        XCTAssertEqual(AgentRemoteCommandBuilder.shellSingleQuote("/tmp/plain"), "'/tmp/plain'")
        XCTAssertEqual(
            AgentRemoteCommandBuilder.shellSingleQuote("a'b'c"),
            "'a'\\''b'\\''c'"
        )
    }
}
