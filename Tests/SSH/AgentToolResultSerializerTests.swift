import Foundation
import XCTest

@testable import MacSSH

/// B4 §29–§33/§86：Tool Result 结构化序列化测试。
///
/// 硬 gate：
/// - 成功 `{"ok": true, ...}` / 失败 `{"ok": false, "error": "<name>"}`；
/// - 绝不出现 NSError dump / libssh2 raw dump / Swift debugDescription；
/// - bounds 元数据如实输出（不放大、不隐藏 truncated）。
final class AgentToolResultSerializerTests: XCTestCase {

    private func json(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
        )
    }

    // MARK: - Terminal context（§31）

    func testTerminalContextResultShape() throws {
        let context = AgentTerminalContext(
            sessionID: UUID(),
            sessionKind: .remoteSSH,
            targetDisplayName: "prod-box",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/app"),
            rows: 40,
            columns: 120,
            selectedText: "selected",
            recentOutput: "recent line",
            alternateScreen: true,
            selectionTruncated: false,
            outputTruncated: true
        )
        let object = try json(AgentToolResultSerializer.serialize(.terminalContext(context)))

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["sessionKind"] as? String, "remoteSSH")
        XCTAssertEqual(object["target"] as? String, "prod-box")
        XCTAssertEqual(object["rows"] as? Int, 40)
        XCTAssertEqual(object["columns"] as? Int, 120)
        XCTAssertEqual(object["selection"] as? String, "selected")
        XCTAssertEqual(object["recentOutput"] as? String, "recent line")
        XCTAssertEqual(object["alternateScreen"] as? Bool, true)
        XCTAssertEqual(object["outputTruncated"] as? Bool, true)
        XCTAssertEqual(object["selectionTruncated"] as? Bool, false)

        let cwd = try XCTUnwrap(object["cwd"] as? [String: Any])
        XCTAssertEqual(cwd["path"] as? String, "/srv/app")
        XCTAssertEqual(cwd["source"] as? String, "osc7")
        XCTAssertEqual(cwd["confidence"] as? String, "authoritative")
    }

    func testTerminalContextSelectionNilIsExplicitNull() throws {
        let context = AgentTerminalContext(
            sessionID: UUID(),
            sessionKind: .local,
            targetDisplayName: "Local",
            workingDirectory: .unavailable,
            rows: 24,
            columns: 80,
            selectedText: nil,
            recentOutput: "",
            alternateScreen: false,
            selectionTruncated: false,
            outputTruncated: false
        )
        let data = try XCTUnwrap(
            AgentToolResultSerializer.serialize(.terminalContext(context)).data(using: .utf8)
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertTrue(object["selection"] is NSNull, "无选中必须是显式 null")
        let cwd = try XCTUnwrap(object["cwd"] as? [String: Any])
        XCTAssertTrue(cwd["path"] is NSNull)
        XCTAssertEqual(cwd["confidence"] as? String, "unavailable")
    }

    // MARK: - Current directory（§30）

    func testCurrentDirectoryResultShape() throws {
        let available = AgentCurrentDirectoryResult(
            sessionID: UUID(),
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/Users/me/proj")
        )
        let availableObject = try json(
            AgentToolResultSerializer.serialize(.currentDirectory(available))
        )
        XCTAssertEqual(availableObject["ok"] as? Bool, true)
        XCTAssertEqual(availableObject["path"] as? String, "/Users/me/proj")
        XCTAssertEqual(availableObject["source"] as? String, "osc7")
        XCTAssertEqual(availableObject["confidence"] as? String, "authoritative")

        // unavailable 是 success 三元组（不是 tool failure，§19/§30）。
        let unavailable = AgentCurrentDirectoryResult(
            sessionID: UUID(),
            workingDirectory: .unavailable
        )
        let unavailableObject = try json(
            AgentToolResultSerializer.serialize(.currentDirectory(unavailable))
        )
        XCTAssertEqual(unavailableObject["ok"] as? Bool, true, "unavailable 不等于工具失败")
        XCTAssertTrue(unavailableObject["path"] is NSNull)
        XCTAssertEqual(unavailableObject["source"] as? String, "unavailable")
        XCTAssertEqual(unavailableObject["confidence"] as? String, "unavailable")
    }

    // MARK: - File content（§32）

    func testFileContentResultShape() throws {
        let content = AgentFileContent(
            text: "hello 世界",
            truncated: true,
            bytesReturned: 12,
            originalSize: 300_000
        )
        let object = try json(AgentToolResultSerializer.serialize(.fileContent(content)))
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["text"] as? String, "hello 世界")
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertEqual(object["bytesReturned"] as? Int, 12)
        XCTAssertEqual(object["originalSize"] as? Int, 300_000)
    }

    func testFileContentUnknownOriginalSizeIsExplicitNull() throws {
        let content = AgentFileContent(
            text: "x", truncated: false, bytesReturned: 1, originalSize: nil
        )
        let data = try XCTUnwrap(
            AgentToolResultSerializer.serialize(.fileContent(content)).data(using: .utf8)
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertTrue(object["originalSize"] is NSNull)
    }

    // MARK: - Directory listing（§33）

    func testDirectoryListingResultShapeAndOrderPreserved() throws {
        let listing = AgentDirectoryListing(
            canonicalPath: "/srv/app",
            entries: [
                AgentDirectoryEntry(name: "sub", kind: .directory, sizeBytes: nil),
                AgentDirectoryEntry(name: "link", kind: .symbolicLink, sizeBytes: nil),
                AgentDirectoryEntry(name: "a.txt", kind: .file, sizeBytes: 12),
            ],
            truncated: true,
            totalEntryCount: 601
        )
        let object = try json(AgentToolResultSerializer.serialize(.directoryListing(listing)))
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["path"] as? String, "/srv/app")
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertEqual(object["totalEntryCount"] as? Int, 601)

        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["name"] as? String }, ["sub", "link", "a.txt"], "保持 backend 固定顺序")
        XCTAssertEqual(entries[0]["kind"] as? String, "directory")
        XCTAssertEqual(entries[1]["kind"] as? String, "symbolicLink")
        XCTAssertEqual(entries[2]["kind"] as? String, "file")
        XCTAssertEqual(entries[2]["sizeBytes"] as? Int, 12)
        XCTAssertTrue(entries[0]["sizeBytes"] is NSNull, "目录不携带 size")
    }

    // MARK: - 错误（§29）

    func testEveryToolErrorSerializesToStableStructuredName() throws {
        let expected: [AgentToolError: String] = [
            .sessionUnavailable: "sessionUnavailable",
            .invalidArguments: "invalidArguments",
            .cwdUnavailable: "cwdUnavailable",
            .outsideAllowedReadScope: "outsideAllowedReadScope",
            .unknownTool: "unknownTool",
            .unsupportedForSession: "unsupportedForSession",
            .scopeSessionMismatch: "scopeSessionMismatch",
            .pathNotFound: "pathNotFound",
            .permissionDenied: "permissionDenied",
            .notAFile: "notAFile",
            .notADirectory: "notADirectory",
            .fileTooLarge: "fileTooLarge",
            .binaryUnsupported: "binaryUnsupported",
            .cancelled: "cancelled",
            .internalFailure: "internalFailure",
        ]
        for (error, name) in expected {
            let object = try json(AgentToolResultSerializer.serialize(error: error))
            XCTAssertEqual(object["ok"] as? Bool, false)
            XCTAssertEqual(object["error"] as? String, name)
            XCTAssertEqual(AgentToolResultSerializer.name(of: error), name)
        }
    }

    func testSerializedResultsNeverContainRawDumps() throws {
        let samples: [String] = [
            AgentToolResultSerializer.serialize(error: .internalFailure),
            AgentToolResultSerializer.serialize(
                .fileContent(
                    AgentFileContent(text: "t", truncated: false, bytesReturned: 1, originalSize: 1)
                )
            ),
            AgentToolResultSerializer.serialize(
                .directoryListing(
                    AgentDirectoryListing(
                        canonicalPath: "/x", entries: [], truncated: false, totalEntryCount: 0
                    )
                )
            ),
        ]
        for sample in samples {
            for forbidden in [
                "Error Domain", "NSError", "libssh2", "LIBSSH2", "SFTPError",
                "Swift.", "0x", "Optional(",
            ] {
                XCTAssertFalse(
                    sample.contains(forbidden),
                    "Tool Result 绝不得包含 raw dump：\(forbidden) → \(sample)"
                )
            }
        }
    }
}
