import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B1 §13/§14/§65/§66/§67/§68：command 文本校验。
///
/// 冻结规则（全部基于 UTF-8 字节，绝不按 Character count）：
/// - 空 / whitespace-only → invalid；
/// - U+0000 → invalid；
/// - 16384 bytes → 合法；16385 bytes → 非法（边界逐一测试）；
/// - 多行允许；
/// - 绝不改写原始 bytes（不 trim 保存值、不 normalize）。
final class AgentCommandValidationTests: XCTestCase {
    // MARK: - 空 / 空白

    func testEmptyCommandIsInvalid() {
        XCTAssertEqual(AgentCommandValidation.validate(""), .invalidCommand)
    }

    func testWhitespaceOnlyCommandIsInvalid() {
        XCTAssertEqual(AgentCommandValidation.validate("   \n\t "), .invalidCommand)
        XCTAssertEqual(AgentCommandValidation.validate(" "), .invalidCommand)
        XCTAssertEqual(AgentCommandValidation.validate("\n"), .invalidCommand)
        XCTAssertEqual(AgentCommandValidation.validate("\t\t"), .invalidCommand)
    }

    // MARK: - 多行（§13/§65 允许）

    func testMultilineCommandIsAllowed() {
        XCTAssertEqual(AgentCommandValidation.validate("echo hi\npwd"), nil)
        XCTAssertEqual(AgentCommandValidation.validate("echo a\necho b\necho c"), nil)
    }

    // MARK: - NUL（§67）

    func testNULByteIsRejected() {
        XCTAssertEqual(AgentCommandValidation.validate("echo\u{0000}test"), .invalidCommand)
        // 前导 / 独立 NUL 同样拒绝。
        XCTAssertEqual(AgentCommandValidation.validate("\u{0000}"), .invalidCommand)
        XCTAssertEqual(AgentCommandValidation.validate("echo \u{0000}"), .invalidCommand)
    }

    // MARK: - 16 KiB UTF-8 字节边界（§14）

    func testExactly16384ASCIIBytesIsAllowed() {
        let command = String(repeating: "a", count: 16_384)
        XCTAssertEqual(command.utf8.count, 16_384)
        XCTAssertEqual(AgentCommandValidation.validate(command), nil)
    }

    func test16385ASCIIBytesIsRejected() {
        let command = String(repeating: "a", count: 16_385)
        XCTAssertEqual(command.utf8.count, 16_385)
        XCTAssertEqual(AgentCommandValidation.validate(command), .commandTooLong)
    }

    // MARK: - Unicode 字节语义（§68：byte limit ≠ Character count）

    func testCJKCommandsAreMeasuredInUTF8BytesNotCharacterCount() {
        // 5461 × "中" = 16,383 bytes（合法）；5462 × "中" = 16,386 bytes（超限）。
        // 两者 Character count（5461 / 5462）都远小于 16,384——证明按字节判定。
        XCTAssertEqual("中".utf8.count, 3)
        XCTAssertEqual(AgentCommandValidation.validate(String(repeating: "中", count: 5_461)), nil)
        XCTAssertEqual(
            AgentCommandValidation.validate(String(repeating: "中", count: 5_462)),
            .commandTooLong
        )
    }

    func testEmojiCommandsAreMeasuredInUTF8BytesNotCharacterCount() {
        // 4096 × "😀" = 16,384 bytes（合法）；4097 × "😀" = 16,388 bytes（超限）。
        XCTAssertEqual("😀".utf8.count, 4)
        XCTAssertEqual(AgentCommandValidation.validate(String(repeating: "😀", count: 4_096)), nil)
        XCTAssertEqual(
            AgentCommandValidation.validate(String(repeating: "😀", count: 4_097)),
            .commandTooLong
        )
    }

    func test16384CharactersOfCJKExceedsByteLimit() {
        // Character count 恰为 16,384 但 UTF-8 bytes = 49,152 → 必须拒绝
        //（§14/§68：limit 是字节数，不是 Character count）。
        let command = String(repeating: "中", count: 16_384)
        XCTAssertEqual(command.count, 16_384)
        XCTAssertEqual(command.utf8.count, 49_152)
        XCTAssertEqual(AgentCommandValidation.validate(command), .commandTooLong)
    }

    // MARK: - 原始 bytes 保持（§65/§66：绝不 trim / normalize）

    func testLeadingAndTrailingWhitespaceIsPreservedInValidCommand() throws {
        let command = "   echo hi   "
        XCTAssertEqual(AgentCommandValidation.validate(command), nil)
        // 校验不产生"trim 后的规范形"——保存 / 审批值由 factory 原样保留。
        let request = try AgentCommandTestSupport.makeRequestOrThrow(command: command)
        XCTAssertEqual(request.command, command)
    }

    func testNewlinesArePreservedAndNeverNormalized() throws {
        let command = "echo hi\npwd\n\nls -la"
        XCTAssertEqual(AgentCommandValidation.validate(command), nil)
        let request = try AgentCommandTestSupport.makeRequestOrThrow(command: command)
        XCTAssertEqual(request.command, command)
    }

    func testNoAutomaticRewritingOfModelCommand() throws {
        // §66：不自动加 sudo / cd / shell flags、不改写引号。
        let command = "'quoted string' && echo $HOME | wc -c"
        XCTAssertEqual(AgentCommandValidation.validate(command), nil)
        let request = try AgentCommandTestSupport.makeRequestOrThrow(command: command)
        XCTAssertEqual(request.command, command)
    }

    // MARK: - 上限常量（冻结值集中）

    func testFrozenLimitValue() {
        XCTAssertEqual(AgentCommandLimits.maxCommandBytes, 16_384)
    }
}

/// 测试共享 fixture（仅测试 target 内使用）。
enum AgentCommandTestSupport {
    /// 经 factory 构造合法 request（全部默认值可覆盖）。
    static func makeRequestOrThrow(
        generationID: UUID = UUID(),
        callID: String = "call_test_1",
        sessionID: UUID = UUID(),
        target: AgentCommandTarget = .local(displayName: "Local"),
        command: String = "echo hi",
        workingDirectory: AgentWorkingDirectory = AgentWorkingDirectory(
            path: "/tmp/project",
            source: .osc7,
            confidence: .authoritative
        ),
        snapshotID: UUID = UUID()
    ) throws -> AgentCommandRequest {
        switch AgentCommandRequestFactory.make(
            generationID: generationID,
            callID: callID,
            sessionID: sessionID,
            target: target,
            command: command,
            workingDirectory: workingDirectory,
            providerBinding: AgentCommandProviderBinding(
                snapshotID: snapshotID,
                provider: .openAI,
                model: "test-model",
                baseURL: URL(string: "https://example.invalid/v1")!
            )
        ) {
        case .success(let request):
            return request
        case .failure(let error):
            throw error
        }
    }
}
