import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B2 §30–§33/§63/§64/§73：stdout / stderr 分离、cap、
/// drain-not-store、同时大输出无死锁、输出清洗（ANSI / NUL / 非法 UTF-8）。
final class AgentLocalCommandExecutorOutputTests: XCTestCase {
    private var workspace: AgentLocalCommandTestWorkspace!

    override func setUpWithError() throws {
        workspace = try AgentLocalCommandTestWorkspace()
    }

    override func tearDownWithError() throws {
        workspace.cleanup()
        workspace = nil
    }

    @discardableResult
    private func execute(_ command: String) async throws -> AgentCommandResult {
        let coordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: coordinator,
            command: command,
            workingDirectory: workspace.root.path
        )
        let executor = AgentLocalCommandExecutor(policy: AgentLocalCommandTestSupport.fastPolicy)
        return try await executor.execute(
            authorization: authorization,
            approvalCoordinator: coordinator
        )
    }

    // MARK: - §63 cap

    func testStdoutOverCapIsTruncatedButFullyDrained() async throws {
        let result = try await execute(#"awk 'BEGIN { for (i = 0; i < 400000; i++) printf "o" }'"#)
        XCTAssertEqual(result.exitCode, 0, "cap 后必须继续 drain（否则子进程阻塞/被杀）")
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertGreaterThanOrEqual(result.stdout.utf8.count, 256 * 1024 - 3)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 256 * 1024)
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse(result.stderrTruncated)
    }

    func testStderrOverCapIsTruncatedButFullyDrained() async throws {
        let result = try await execute(
            #"awk 'BEGIN { for (i = 0; i < 400000; i++) printf "e" }' 1>&2"#
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertGreaterThanOrEqual(result.stderr.utf8.count, 256 * 1024 - 3)
        XCTAssertEqual(result.stdout, "")
        XCTAssertFalse(result.stdoutTruncated)
    }

    func testSimultaneousHugeStdoutAndStderrDoesNotDeadlock() async throws {
        // §64 hard test：两流同时超过 cap，必须无死锁、双流全 drain、
        // 两个 truncated 标记正确、进程正常退出。
        let command = """
        awk 'BEGIN { for (i = 0; i < 400000; i++) printf "o" }' &
        awk 'BEGIN { for (i = 0; i < 400000; i++) printf "e" }' 1>&2 &
        wait
        """
        let result = try await execute(command)
        XCTAssertFalse(result.timedOut, "双流同时大输出绝不允许死锁（§64）")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertGreaterThanOrEqual(result.stdout.utf8.count, 256 * 1024 - 3)
        XCTAssertGreaterThanOrEqual(result.stderr.utf8.count, 256 * 1024 - 3)
    }

    func testSmallOutputIsNotMarkedTruncated() async throws {
        let result = try await execute(#"printf 'small\n'"#)
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertEqual(result.stdout, "small\n")
    }

    // MARK: - §38 ANSI / 控制序列

    func testCSIColorSequenceIsStripped() async throws {
        let result = try await execute(#"printf '\033[31mred\033[0m\n'"#)
        XCTAssertEqual(result.stdout, "red\n")
    }

    func testOSCSequenceIsStripped() async throws {
        let result = try await execute(#"printf '\033]0;title\007after\n'"#)
        XCTAssertEqual(result.stdout, "after\n")
    }

    func testOSCSequenceTerminatedByStringTerminatorIsStripped() async throws {
        let result = try await execute(#"printf '\033]0;title\033\\after\n'"#)
        XCTAssertEqual(result.stdout, "after\n")
    }

    func testDCSSequenceIsStripped() async throws {
        let result = try await execute(#"printf '\033P1;2|payload\033\\after\n'"#)
        XCTAssertEqual(result.stdout, "after\n")
    }

    func testC0ControlCharactersAreStrippedAndNewlineKept() async throws {
        let result = try await execute(#"printf 'a\007b\015c\nd\n'"#)
        XCTAssertEqual(result.stdout, "abc\nd\n", "C0 过滤保留 \\n（§38 冻结）")
    }

    func testC1CSISequenceIsStripped() async throws {
        // C1 CSI（U+009B，UTF-8 编码 C2 9B）同样按控制序列剥离。
        let result = try await execute(#"printf '\302\23331mplain\n'"#)
        XCTAssertEqual(result.stdout, "plain\n")
    }

    func testEscapeSequenceDoesNotAffectFollowingText() async throws {
        let result = try await execute(#"printf 'pre\033[2Kmid\033[1;1Hpost\n'"#)
        XCTAssertEqual(result.stdout, "premidpost\n")
    }

    // MARK: - §37/§39 编码 / NUL

    func testValidUTF8IsPreserved() async throws {
        let result = try await execute(#"printf '中文-😀-ok\n'"#)
        XCTAssertEqual(result.stdout, "中文-😀-ok\n")
        XCTAssertFalse(result.nonUTF8Detected)
        XCTAssertFalse(result.binaryOutputDetected)
    }

    func testInvalidUTF8IsReplacedAndFlagged() async throws {
        let result = try await execute(#"printf 'ok\377bad\n'"#)
        XCTAssertTrue(result.nonUTF8Detected)
        XCTAssertTrue(result.stdout.contains("\u{FFFD}"))
        XCTAssertTrue(result.stdout.hasPrefix("ok"))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNULByteMarksBinaryOutputAndCutsAtFirstNUL() async throws {
        let result = try await execute(#"printf 'before\000after\n'"#)
        XCTAssertTrue(result.binaryOutputDetected)
        XCTAssertEqual(result.stdout, "before", "NUL 之后不进入文本（绝不 Base64，§39）")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testEmptyOutputProducesEmptyResult() async throws {
        let result = try await execute("true")
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - 清洗器单元级（边界确定性）

    func testSanitizerTrimsIncompleteUTF8SuffixAtCapBoundary() {
        // "中文" 的 UTF-8 = E4 B8 AD E6 96 87；仅取 4 bytes（E6 后截断）。
        let bytes = Data([0xE4, 0xB8, 0xAD, 0xE6])
        let output = AgentLocalCommandOutputSanitizer.sanitize(bytes, capacityTruncated: true)
        XCTAssertEqual(output.text, "中")
        XCTAssertTrue(output.truncated)
        XCTAssertFalse(output.nonUTF8Detected)

        // 非 cap 截断的同一字节序列 → 非法字节替换 + 标记。
        let lossy = AgentLocalCommandOutputSanitizer.sanitize(bytes, capacityTruncated: false)
        XCTAssertTrue(lossy.nonUTF8Detected)
        XCTAssertEqual(lossy.text, "中\u{FFFD}")
    }

    func testSanitizerKeepsCompleteMultibyteSequenceAtCapBoundary() {
        let bytes = Data([0xE4, 0xB8, 0xAD]) // 完整"中"
        let output = AgentLocalCommandOutputSanitizer.sanitize(bytes, capacityTruncated: true)
        XCTAssertEqual(output.text, "中")
        XCTAssertFalse(output.nonUTF8Detected)
    }

    func testSanitizerStripsTrailingIncompleteEscapeSequence() {
        let output = AgentLocalCommandOutputSanitizer.sanitize(
            Data("text\u{1B}[".utf8), capacityTruncated: false
        )
        XCTAssertEqual(output.text, "text")
    }

    func testSanitizerLeavesTabOutPerFrozenPolicy() {
        // §38 冻结文本只保留 \n；\t 属 C0，严格剥离（报告披露）。
        let output = AgentLocalCommandOutputSanitizer.sanitize(
            Data("a\tb".utf8), capacityTruncated: false
        )
        XCTAssertEqual(output.text, "ab")
    }
}
