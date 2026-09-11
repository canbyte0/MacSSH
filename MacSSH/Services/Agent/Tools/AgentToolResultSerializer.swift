import Foundation

/// B4 §29–§33：Tool Result → Provider 的结构化 JSON 序列化。
///
/// 硬约束：
/// - 只输出结构化 JSON（成功 `{"ok": true, ...}` / 失败
///   `{"ok": false, "error": "..."}`），绝不发送
///   NSError dump / libssh2 raw dump / Swift debugDescription（§29）；
/// - 不放大 B2/B3 的任何 limit（§32/§86）：terminal ≤256 KiB、
///   file ≤256 KiB、directory ≤500 entries——本层只做序列化，边界由
///   backend 保证；
/// - 错误名是 vendor-neutral 的稳定分类字符串，模型可解释并向用户
///   说明（§28）。
enum AgentToolResultSerializer: Sendable {

    /// 取消 / 未执行的统一结构化输出（§45–§48：call_id 配对恒成立）。
    static let cancelledOutput = #"{"ok":false,"error":"cancelled"}"#

    // MARK: - 成功结果

    /// 成功结果 → `{"ok": true, ...}` JSON string。
    static func serialize(_ result: AgentToolResult) -> String {
        switch result {
        case .terminalContext(let context):
            return encode(terminalContextObject(context))
        case .currentDirectory(let currentDirectory):
            return encode(currentDirectoryObject(currentDirectory.workingDirectory))
        case .directoryListing(let listing):
            return encode(directoryListingObject(listing))
        case .fileContent(let content):
            return encode(fileContentObject(content))
        }
    }

    // MARK: - 错误结果

    /// 工具错误 → `{"ok": false, "error": "<name>"}` JSON string（§29）。
    static func serialize(error: AgentToolError) -> String {
        encode([
            "ok": false,
            "error": name(of: error),
        ])
    }

    /// 工具错误分类的稳定字符串名（模型可见）。
    static func name(of error: AgentToolError) -> String {
        switch error {
        case .sessionUnavailable: return "sessionUnavailable"
        case .invalidArguments: return "invalidArguments"
        case .cwdUnavailable: return "cwdUnavailable"
        case .outsideAllowedReadScope: return "outsideAllowedReadScope"
        case .unknownTool: return "unknownTool"
        case .unsupportedForSession: return "unsupportedForSession"
        case .scopeSessionMismatch: return "scopeSessionMismatch"
        case .pathNotFound: return "pathNotFound"
        case .permissionDenied: return "permissionDenied"
        case .notAFile: return "notAFile"
        case .notADirectory: return "notADirectory"
        case .fileTooLarge: return "fileTooLarge"
        case .binaryUnsupported: return "binaryUnsupported"
        case .cancelled: return "cancelled"
        case .internalFailure: return "internalFailure"
        }
    }

    // MARK: - 各结果形态（§30/§31/§32/§33）

    /// §31：terminal context——session kind / target display / cwd
    /// metadata / rows / columns / selection / recentOutput /
    /// alternateScreen / truncation flags。
    private static func terminalContextObject(
        _ context: AgentTerminalContext
    ) -> [String: Any] {
        [
            "ok": true,
            "sessionKind": sessionKindName(context.sessionKind),
            "target": context.targetDisplayName,
            "cwd": cwdObject(context.workingDirectory),
            "rows": context.rows,
            "columns": context.columns,
            "selection": context.selectedText as Any? ?? NSNull(),
            "selectionTruncated": context.selectionTruncated,
            "recentOutput": context.recentOutput,
            "outputTruncated": context.outputTruncated,
            "alternateScreen": context.alternateScreen,
        ]
    }

    /// §30：current directory——至少 path / source / confidence；
    /// unavailable 是 success 三元组而非 tool failure。
    private static func currentDirectoryObject(
        _ workingDirectory: AgentWorkingDirectory
    ) -> [String: Any] {
        var object: [String: Any] = ["ok": true]
        object.merge(cwdObject(workingDirectory)) { _, new in new }
        return object
    }

    /// file content（§32）：text-only / UTF-8 / truncated metadata。
    private static func fileContentObject(_ content: AgentFileContent) -> [String: Any] {
        [
            "ok": true,
            "text": content.text,
            "truncated": content.truncated,
            "bytesReturned": content.bytesReturned,
            "originalSize": content.originalSize.map { Int($0) } as Any? ?? NSNull(),
        ]
    }

    /// directory listing（§33）：≤500 entries / truncated flag /
    /// deterministic ordering（顺序由 backend 固定，serializer 保持原序）。
    private static func directoryListingObject(
        _ listing: AgentDirectoryListing
    ) -> [String: Any] {
        [
            "ok": true,
            "path": listing.canonicalPath,
            "entries": listing.entries.map(entryObject(_:)),
            "truncated": listing.truncated,
            "totalEntryCount": listing.totalEntryCount,
        ]
    }

    private static func entryObject(_ entry: AgentDirectoryEntry) -> [String: Any] {
        var object: [String: Any] = [
            "name": entry.name,
            "kind": entry.kind.rawValue,
        ]
        object["sizeBytes"] = entry.sizeBytes.map { Int($0) } as Any? ?? NSNull()
        return object
    }

    /// cwd 三元组（§9：绝不只给裸路径）。
    private static func cwdObject(_ workingDirectory: AgentWorkingDirectory) -> [String: Any] {
        [
            "path": workingDirectory.path as Any? ?? NSNull(),
            "source": sourceName(workingDirectory.source),
            "confidence": confidenceName(workingDirectory.confidence),
        ]
    }

    // MARK: - 内部

    private static func sessionKindName(_ kind: AgentTerminalSessionKind) -> String {
        switch kind {
        case .local: return "local"
        case .remoteSSH: return "remoteSSH"
        }
    }

    private static func sourceName(_ source: AgentCWDSource) -> String {
        switch source {
        case .osc7: return "osc7"
        case .sessionDefault: return "sessionDefault"
        case .unavailable: return "unavailable"
        }
    }

    private static func confidenceName(_ confidence: AgentCWDConfidence) -> String {
        switch confidence {
        case .authoritative: return "authoritative"
        case .approximate: return "approximate"
        case .unavailable: return "unavailable"
        }
    }

    /// 确定性 JSON 输出（sortedKeys + 不转义斜杠：路径可读）。
    private static func encode(_ object: [String: Any]) -> String {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        else {
            // 不可能路径：结构全部由基础类型构成。保守返回结构化错误，
            // 绝不透传不可序列化对象。
            return #"{"ok":false,"error":"internalFailure"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
