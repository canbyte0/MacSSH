import CryptoKit
import Foundation
import XCTest

@testable import MacSSH

/// Phase 10F-C1-R1 冻结 payload 契约的 focused tests。
///
/// 契约（canonical 定义见 `AgentFileMutationLimits`）：
/// - content type：TEXT ONLY；encoding：exact UTF-8（authority = 精确字节）。
/// - allowed size：`0...262144` bytes（含两端）；空 payload 合法。
/// - binary / base64：Phase 10F-C 不支持（binary file mutation DEFERRED）。
/// - 零归一化：无 trim / 无换行归一 / 无 NFC/NFD / 无 BOM 插入 / 无行尾改写。
/// - 校验点在 proposal factory（审批之前）；超限整体拒绝，绝不截断。
final class AgentFileMutationPayloadContractTests: XCTestCase {

    // MARK: - Helpers

    /// 从 test source 反推 checkout root（与 SecurityGate tests 同一手法）。
    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("MacSSH.xcodeproj").path) else {
            throw NSError(domain: "AgentFileMutationPayloadContractTests", code: 1)
        }
        return url
    }

    /// 断言 request 恰好冻结给定 content 的精确 UTF-8 字节（零归一化），
    /// 且未产生任何文件副作用；最后释放 parent capability。
    private func assertExactByteFreeze(
        _ request: AgentFileMutationRequest,
        content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertEqual(request.content, content, "content 不得被改写", file: file, line: line)
        let expected = Data(content.utf8)
        XCTAssertEqual(request.payloadUTF8, expected, "payload 必须是精确 UTF-8 字节", file: file, line: line)
        XCTAssertEqual(request.payloadIdentity.byteCount, expected.count, file: file, line: line)
        XCTAssertEqual(
            request.payloadIdentity.sha256,
            Data(SHA256.hash(data: expected)),
            file: file,
            line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: request.displayPath),
            "C1 阶段不得创建目标文件",
            file: file,
            line: line
        )
        _ = await request.parentCapability.invalidate()
    }

    // MARK: - Central limit

    /// 契约常量必须恰好等于 262144 bytes（256 KiB）。
    func testMaxPayloadBytesConstantIsExactly256KiB() {
        XCTAssertEqual(AgentFileMutationLimits.maxPayloadBytes, 262_144)
        XCTAssertEqual(AgentFileMutationLimits.maxPayloadBytes, 256 * 1024)
    }

    /// 生产源码中 payload 上限字面量只允许出现在 canonical 定义一处，
    /// 其余文件必须引用 `AgentFileMutationLimits.maxPayloadBytes`。
    func testPayloadLimitLiteralHasSingleCanonicalProductionDefinition() throws {
        let directory = try repositoryRoot()
            .appendingPathComponent("MacSSH/Services/Agent/FileMutation", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            let body = try String(contentsOf: file, encoding: .utf8)
            let carriesLiteral = body.contains("262144")
                || body.contains("262_144")
                || body.contains("256 * 1024")
            if file.lastPathComponent == "AgentFileMutationModels.swift" {
                XCTAssertTrue(carriesLiteral, "canonical 定义文件必须真实携带上限常量")
            } else {
                XCTAssertFalse(
                    carriesLiteral,
                    "\(file.lastPathComponent) 不得散落 payload 上限 magic number；必须引用 AgentFileMutationLimits"
                )
            }
        }
    }

    // MARK: - Boundary validation: 0 / 1 / 262144 / 262145

    /// 0 bytes：合法。空 String 是合法 payload，future C2 将据此创建空文件。
    func testEmptyPayloadIsAllowedAndFrozenExactly() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "empty.txt",
            content: "",
            callID: "payload-empty"
        )

        XCTAssertEqual(request.content, "")
        XCTAssertEqual(request.payloadUTF8, Data())
        XCTAssertEqual(request.payloadIdentity.byteCount, 0)
        XCTAssertEqual(request.payloadIdentity.sha256, Data(SHA256.hash(data: Data())))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.displayPath))
        _ = await request.parentCapability.invalidate()
    }

    /// 1 byte：合法且逐字节冻结。
    func testSingleBytePayloadIsAllowed() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "one.txt",
            content: "x",
            callID: "payload-one-byte"
        )

        XCTAssertEqual(request.payloadUTF8, Data([0x78]))
        XCTAssertEqual(request.payloadIdentity.byteCount, 1)
        _ = await request.parentCapability.invalidate()
    }

    /// 262144 bytes（多字节构成）：合法。上限按 UTF-8 字节计，
    /// 87381 个「中」（各 3 bytes）+ 1 个 ASCII 字节 = 恰好 262144。
    func testExactLimitMultiBytePayloadIsAccepted() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let exact = String(repeating: "中", count: 87_381) + "a"
        XCTAssertEqual(Data(exact.utf8).count, AgentFileMutationLimits.maxPayloadBytes)

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "exact-limit.txt",
            content: exact,
            callID: "payload-exact-limit"
        )
        await assertExactByteFreeze(request, content: exact)
    }

    /// 262145 bytes：整体拒绝（`.payloadTooLarge`），绝不截断成 262144 的
    /// 成功 request，也绝无文件副作用。
    func testOneByteOverLimitIsRejectedWithoutTruncation() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let scope = try AgentFileMutationTestSupport.makeScope(root: root)

        let over = String(repeating: "中", count: 87_381) + "ab"
        XCTAssertEqual(Data(over.utf8).count, AgentFileMutationLimits.maxPayloadBytes + 1)

        let result = await AgentFileMutationRequestFactory.make(
            generationID: scope.logicalSessionID,
            callID: "payload-over-limit",
            logicalSessionID: scope.logicalSessionID,
            writeScope: scope,
            userSuppliedPath: "truncated.txt",
            content: over,
            providerBinding: AgentFileMutationTestSupport.providerBinding,
            createdAt: AgentFileMutationTestSupport.createdAt
        )

        XCTAssertEqual(result, .failure(.payloadTooLarge))
        if case .success = result {
            XCTFail("超限 payload 必须整体拒绝，不得截断为成功 request")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("truncated.txt").path),
            "超限拒绝不得产生任何文件"
        )
    }

    /// 上限按字节而非字符计：87382 个字符（远小于 262144 字符）但
    /// 262146 bytes，必须拒绝。
    func testLimitCountsUTF8BytesNotCharacters() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let scope = try AgentFileMutationTestSupport.makeScope(root: root)

        let deceptive = String(repeating: "中", count: 87_382)
        XCTAssertLessThan(deceptive.count, AgentFileMutationLimits.maxPayloadBytes)
        XCTAssertEqual(Data(deceptive.utf8).count, AgentFileMutationLimits.maxPayloadBytes + 2)

        let result = await AgentFileMutationRequestFactory.make(
            generationID: scope.logicalSessionID,
            callID: "payload-bytes-not-chars",
            logicalSessionID: scope.logicalSessionID,
            writeScope: scope,
            userSuppliedPath: "bytes-not-chars.txt",
            content: deceptive,
            providerBinding: AgentFileMutationTestSupport.providerBinding,
            createdAt: AgentFileMutationTestSupport.createdAt
        )
        XCTAssertEqual(result, .failure(.payloadTooLarge))
    }

    // MARK: - Unicode / content matrix

    /// ASCII / Chinese / Emoji / combining / LF / CRLF / trailing newline /
    /// no trailing newline / empty / embedded NUL / 显式 BOM / tab：
    /// 全部逐字节精确冻结。
    func testUnicodeContentMatrixIsPreservedByteForByte() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let matrix: [(label: String, content: String)] = [
            ("ascii", "Hello, MacSSH 1.1!"),
            ("chinese", "中文内容与 English 混排"),
            ("emoji", "🙂👍👨‍👩‍👧"),
            ("combining", "e\u{301}cole"),
            ("lf-only", "line1\nline2\n"),
            ("crlf", "line1\r\nline2\r\n"),
            ("lf-crlf-mixed", "a\r\nb\nc"),
            ("trailing-newline", "ends with newline\n"),
            ("no-trailing-newline", "ends without newline"),
            ("empty", ""),
            ("embedded-nul", "before\u{0}after"),
            ("explicit-bom", "\u{FEFF}BOM is content bytes"),
            ("tab", "\tindented\t"),
        ]

        for (index, entry) in matrix.enumerated() {
            let request = try await AgentFileMutationTestSupport.makeRequest(
                root: root,
                path: "matrix-\(index).txt",
                content: entry.content,
                callID: "payload-matrix-\(entry.label)"
            )
            await assertExactByteFreeze(request, content: entry.content)
        }
    }

    /// 零归一化：不 trim（首尾空白/换行保留）、NFC 与 NFD 各自保留且互不
    /// 归一、无 BOM 插入（无 BOM 的 payload 不得以 EF BB BF 开头）。
    func testPayloadIsNotTrimmedOrNormalized() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let padded = "  \t\n  中文🙂  \n\t  "
        let paddedRequest = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "padded.txt",
            content: padded,
            callID: "payload-padded"
        )
        await assertExactByteFreeze(paddedRequest, content: padded)

        let nfc = "caf\u{e9}"
        let nfd = "cafe\u{301}"
        XCTAssertNotEqual(Data(nfc.utf8), Data(nfd.utf8))
        let nfcRequest = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "nfc.txt",
            content: nfc,
            callID: "payload-nfc"
        )
        await assertExactByteFreeze(nfcRequest, content: nfc)
        let nfdRequest = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "nfd.txt",
            content: nfd,
            callID: "payload-nfd"
        )
        await assertExactByteFreeze(nfdRequest, content: nfd)
        XCTAssertNotEqual(nfcRequest.payloadUTF8, nfdRequest.payloadUTF8)

        let noBom = "plain content without BOM"
        let noBomRequest = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "no-bom.txt",
            content: noBom,
            callID: "payload-no-bom"
        )
        XCTAssertEqual(noBomRequest.payloadUTF8, Data(noBom.utf8))
        XCTAssertFalse(
            Array(noBomRequest.payloadUTF8.prefix(3)).elementsEqual([0xEF, 0xBB, 0xBF]),
            "不得向 payload 注入 BOM"
        )
        _ = await noBomRequest.parentCapability.invalidate()
    }

    // MARK: - NUL semantics

    /// 文件内容中的 NUL 合法且精确保留——file payload 不继承 terminal 输入
    /// 域的 C0 控制字符限制；对照：路径中的 NUL 仍然非法。
    func testEmbeddedNULInContentIsLegalAndDoesNotInheritTerminalInputRestrictions() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let withNUL = "a\u{0}b\u{0}"
        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "nul-content.txt",
            content: withNUL,
            callID: "payload-nul-content"
        )
        XCTAssertEqual(request.payloadUTF8, Data([0x61, 0x00, 0x62, 0x00]))
        XCTAssertEqual(request.payloadIdentity.byteCount, 4)
        _ = await request.parentCapability.invalidate()

        let scope = try AgentFileMutationTestSupport.makeScope(root: root)
        let pathWithNUL = await AgentFileMutationRequestFactory.make(
            generationID: scope.logicalSessionID,
            callID: "payload-nul-path",
            logicalSessionID: scope.logicalSessionID,
            writeScope: scope,
            userSuppliedPath: "bad\u{0}name.txt",
            content: "x",
            providerBinding: AgentFileMutationTestSupport.providerBinding,
            createdAt: AgentFileMutationTestSupport.createdAt
        )
        XCTAssertEqual(pathWithNUL, .failure(.invalidPath))
    }
}
