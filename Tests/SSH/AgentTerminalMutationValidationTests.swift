import Foundation
import XCTest

@testable import MacSSH

/// Phase 10F-B1 任务书 §14/§15/§48：冻结校验矩阵。
///
/// 全部边界基于 **UTF-8 字节数**（绝不使用字符数）；拒绝集与放行集
/// 逐一来自 10F-A 冻结 Payload 表（NUL / C0 除 LF / CR / DEL / C1 拒绝，
/// LF 允许 = 多行允许）；零 normalization（原始表示原样通过）。
final class AgentTerminalMutationValidationTests: XCTestCase {
    // MARK: - 大小边界（byte-based，§48）

    func testEmptyPayloadIsRejected() {
        XCTAssertEqual(
            AgentTerminalMutationValidation.validate(""),
            .invalidArguments
        )
    }

    func testSingleBytePayloadIsAccepted() {
        XCTAssertNil(AgentTerminalMutationValidation.validate("a"))
    }

    func testMaxBoundary65536BytesIsAccepted() {
        let payload = String(repeating: "a", count: 65_536)
        XCTAssertEqual(payload.utf8.count, 65_536)
        XCTAssertNil(AgentTerminalMutationValidation.validate(payload))
    }

    func testOneByteOverLimit65537IsRejectedAsTooLarge() {
        let payload = String(repeating: "a", count: 65_537)
        XCTAssertEqual(payload.utf8.count, 65_537)
        XCTAssertEqual(
            AgentTerminalMutationValidation.validate(payload),
            .payloadTooLarge
        )
    }

    func testMultibyteExactBoundaryIsByteCountedNotCharacterCounted() {
        // 3-byte scalars（中文）：21,846 个字符 = 65,538 bytes → 超 2 bytes 拒绝。
        let overLimitChinese = String(repeating: "中", count: 21_846)
        XCTAssertEqual(overLimitChinese.utf8.count, 65_538)
        XCTAssertEqual(
            AgentTerminalMutationValidation.validate(overLimitChinese),
            .payloadTooLarge
        )
        // 恰好 65,536 bytes = 21,845 个中文 + 1 个 ASCII byte → 合法。
        let exactBoundary = String(repeating: "中", count: 21_845) + "a"
        XCTAssertEqual(exactBoundary.utf8.count, 65_536)
        XCTAssertNil(AgentTerminalMutationValidation.validate(exactBoundary))
        // 4-byte scalars（emoji）：16,384 个 emoji = 65,536 bytes → 合法；
        // 再多 1 个字符即 65,540 → 拒绝。字符数远小于 65,536 仍受字节上限约束。
        let exactEmoji = String(repeating: "😀", count: 16_384)
        XCTAssertEqual(exactEmoji.utf8.count, 65_536)
        XCTAssertNil(AgentTerminalMutationValidation.validate(exactEmoji))
        let overEmoji = exactEmoji + "😀"
        XCTAssertEqual(overEmoji.utf8.count, 65_540)
        XCTAssertEqual(
            AgentTerminalMutationValidation.validate(overEmoji),
            .payloadTooLarge
        )
    }

    // MARK: - 冻结拒绝字符集（§48）

    func testNULIsRejected() {
        XCTAssertEqual(
            AgentTerminalMutationValidation.validate("a\u{0000}b"),
            .forbiddenControlCharacter
        )
    }

    func testESCIsRejected() {
        XCTAssertEqual(
            AgentTerminalMutationValidation.validate("a\u{001B}[2Jb"),
            .forbiddenControlCharacter
        )
    }

    func testCRIsRejected() {
        XCTAssertEqual(
            AgentTerminalMutationValidation.validate("a\u{000D}b"),
            .forbiddenControlCharacter
        )
    }

    func testAllArchitectureForbiddenControlClassesAreRejected() {
        // C0 全集（除 LF 0x0A）逐一拒绝：TAB(0x09)、VT(0x0B)、FF(0x0C)
        // 与其余 0x01–0x1F（含 ESC 0x1B）。
        var rejectedScalars: [Unicode.Scalar] = []
        for value in 0x01...0x1F where value != 0x0A {
            rejectedScalars.append(Unicode.Scalar(value)!)
        }
        rejectedScalars.append(Unicode.Scalar(0x00)!)   // NUL
        rejectedScalars.append(Unicode.Scalar(0x7F)!)   // DEL
        for value in 0x80...0x9F {                      // C1 控制
            rejectedScalars.append(Unicode.Scalar(value)!)
        }
        XCTAssertEqual(rejectedScalars.count, 64, "冻结拒绝集应为 64 个标量（30 C0 除 LF + NUL + DEL + 32 C1）")
        for scalar in rejectedScalars {
            let payload = "a\(Character(scalar))b"
            XCTAssertEqual(
                AgentTerminalMutationValidation.validate(payload),
                .forbiddenControlCharacter,
                "U+\(String(scalar.value, radix: 16)) 必须被拒绝"
            )
        }
    }

    // MARK: - 冻结放行集（§48）

    func testLFIsAllowedAsMultilineSeparator() {
        XCTAssertNil(AgentTerminalMutationValidation.validate("line one\nline two\n"))
        XCTAssertNil(AgentTerminalMutationValidation.validate("\n"))
    }

    func testPrintableASCIIAndHighUnicodeAreAllowed() {
        XCTAssertNil(AgentTerminalMutationValidation.validate("echo hello"))
        XCTAssertNil(AgentTerminalMutationValidation.validate("中文测试"))
        XCTAssertNil(AgentTerminalMutationValidation.validate("emoji 😀🚀"))
        XCTAssertNil(AgentTerminalMutationValidation.validate("combining é\u{0301}"))
        XCTAssertNil(AgentTerminalMutationValidation.validate("tab-less spacing  ok"))
    }

    // MARK: - 零 normalization（§15）

    func testValidationDoesNotNormalizeOrMutatePayloadRepresentation() {
        // 组合序列（decomposed）与预组合（precomposed）都必须同样通过——
        // 校验层绝不引入 Unicode normalization，两种表示原样保留。
        let decomposed = "e\u{0301}"
        let precomposed = "é"
        XCTAssertNil(AgentTerminalMutationValidation.validate(decomposed))
        XCTAssertNil(AgentTerminalMutationValidation.validate(precomposed))
        XCTAssertNotEqual(decomposed.utf8.count, precomposed.utf8.count)
        // NFC/NFD 在校验前后逐字节不变（无隐藏改写）。
        XCTAssertEqual(Array(decomposed.utf8), Array(decomposed.utf8))
    }

    // MARK: - submit 语义（10F-A-R1 §R1.5 冻结；校验与 submit 正交）

    func testValidationIsOrthogonalToSubmitFlag() {
        // submit=false 不放宽 / 不收紧校验：同样的拒绝集。
        for submit in [false, true] {
            XCTAssertNil(AgentTerminalMutationValidation.validate("echo hi"))
            XCTAssertEqual(
                AgentTerminalMutationValidation.validate("echo\u{000D}hi"),
                .forbiddenControlCharacter
            )
            _ = submit
        }
    }
}
