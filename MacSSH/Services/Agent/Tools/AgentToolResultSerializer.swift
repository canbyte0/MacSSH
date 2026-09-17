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

    /// B4 user-denied 输出：只表达权限结果，绝不伪造 stdout / stderr。
    static let userDeniedOutput = #"{"ok":false,"error":"userDenied"}"#

    // MARK: - run_command 结果

    /// Local / Remote executor 的共享结构化结果。stdout/stderr 已在
    /// executor 内经过既有 sanitizer 和 256 KiB cap，这里只负责稳定编码。
    static func serialize(commandResult result: AgentCommandResult) -> String {
        encodeCommandResult(result, extra: [:])
    }

    /// Remote 结果保留 provider-neutral 的终止信息，不泄露 libssh2 细节。
    static func serialize(commandResult result: AgentRemoteCommandResult) -> String {
        var extra: [String: Any] = [
            "remote_termination_requested": result.remoteTerminationRequested,
        ]
        switch result.termination {
        case .exitStatus(let status):
            extra["remote_termination"] = "exit_status"
            extra["remote_exit_code"] = Int(status)
        case .exitSignal(let name, _):
            extra["remote_termination"] = "exit_signal"
            extra["remote_signal"] = name
        case .unknown:
            extra["remote_termination"] = "unknown"
        }
        return encodeCommandResult(result.result, extra: extra)
    }

    /// command domain 校验错误在 approval / executor 之前收敛为稳定名称。
    static func serialize(error: AgentCommandError) -> String {
        encodeError(name: commandErrorName(error))
    }

    /// Local executor infrastructure 错误只向 Provider 暴露稳定分类。
    static func serialize(error: AgentCommandExecutionError) -> String {
        switch error {
        case .authorizationRejected(let error):
            return encodeError(name: commandErrorName(error))
        case .remoteExecutionUnsupported:
            return encodeError(name: "remoteExecutionUnsupported")
        case .shellUnavailable:
            return encodeError(name: "executorUnavailable")
        case .workingDirectoryUnavailable:
            return encodeError(name: "workingDirectoryUnavailable")
        case .spawnFailed:
            return encodeError(name: "executorUnavailable")
        }
    }

    /// Remote executor infrastructure 错误只向 Provider 暴露稳定分类。
    static func serialize(error: AgentRemoteCommandExecutionError) -> String {
        switch error {
        case .authorizationRejected(let error):
            return encodeError(name: commandErrorName(error))
        case .localExecutionUnsupported:
            return encodeError(name: "localExecutionUnsupported")
        case .sessionUnavailable:
            return encodeError(name: "sessionUnavailable")
        case .connectionUnavailable:
            return encodeError(name: "connectionUnavailable")
        case .channelOpenFailed:
            return encodeError(name: "channelOpenFailed")
        case .execRequestRejected:
            return encodeError(name: "execRequestRejected")
        case .channelFailure:
            return encodeError(name: "channelFailure")
        case .execPayloadTooLarge:
            return encodeError(name: "execPayloadTooLarge")
        }
    }

    // MARK: - send_to_terminal 结果（10F-B4-S1 §31/§32）

    /// Terminal mutation 交付结果的 sanitized 结构化输出。
    ///
    /// 只含 transport 层事实（§31）：status / terminalKind /
    /// payloadBytesRequested / payloadBytesAccepted / framingBytesAccepted /
    /// submitBytesAccepted / transportSubmitted。绝不包含终端输出、
    /// 凭据、endpoint token、指针或 payload 回显；`delivered` 仅表示
    /// transport 层交付（§28：绝不暗示命令执行 / 完成）。
    static func serialize(
        mutationResult result: AgentTerminalMutationDeliveryResult,
        terminalKind: AgentTerminalSessionKind
    ) -> String {
        var object: [String: Any] = [
            "ok": result.outcome == .delivered,
            "status": mutationStatusName(result.outcome),
            "terminalKind": sessionKindName(terminalKind),
            "payloadBytesRequested": result.payloadBytesRequested,
            "payloadBytesAccepted": result.payloadBytesAccepted,
            "framingBytesAccepted": result.framingBytesAccepted,
            "submitBytesAccepted": result.submitBytesAccepted,
            "transportSubmitted": Self.transportSubmitted(result),
        ]
        if let error = result.error {
            object["error"] = mutationErrorName(error)
        }
        return encode(object)
    }

    /// Terminal mutation domain 错误 → 稳定分类名。
    static func serialize(error: AgentTerminalMutationError) -> String {
        encodeError(name: mutationErrorName(error))
    }

    private static func mutationStatusName(
        _ outcome: AgentTerminalMutationDeliveryOutcome
    ) -> String {
        switch outcome {
        case .delivered: return "delivered"
        case .partial: return "partial"
        case .failed: return "failed"
        case .rejected: return "rejected"
        }
    }

    /// transportSubmitted：submit=true 且 CR 已被 transport 确认接受。
    /// submit=false 时没有请求提交字节，恒为 false（§10：只承诺不追加
    /// Return，绝不暗示「已提交」）。
    private static func transportSubmitted(
        _ result: AgentTerminalMutationDeliveryResult
    ) -> Bool {
        result.submitBytesRequested > 0
            && result.submitBytesAccepted == result.submitBytesRequested
    }

    private static func mutationErrorName(_ error: AgentTerminalMutationError) -> String {
        switch error {
        case .invalidArguments: return "invalidArguments"
        case .payloadTooLarge: return "payloadTooLarge"
        case .forbiddenControlCharacter: return "forbiddenControlCharacter"
        case .approvalNotFound: return "approvalNotFound"
        case .approvalNotApproved: return "approvalNotApproved"
        case .approvalAlreadyResolved: return "approvalAlreadyResolved"
        case .approvalCancelled: return "approvalCancelled"
        case .approvalStale: return "authorizationRejected"
        case .approvalAlreadyConsumed: return "approvalAlreadyConsumed"
        case .bindingMismatch: return "bindingMismatch"
        case .targetReplaced: return "targetReplaced"
        case .processUnavailable: return "processUnavailable"
        case .connectionLost: return "connectionLost"
        case .channelClosed: return "channelClosed"
        case .writeFailed: return "writeFailed"
        case .cancelled: return "cancelled"
        case .transactionUnavailable: return "transactionUnavailable"
        }
    }

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
        case .commandRequiresApproval: return "commandRequiresApproval"
        case .terminalMutationRequiresApproval: return "terminalMutationRequiresApproval"
        case .fileMutationRequiresApproval: return "fileMutationRequiresApproval"
        }
    }

    // MARK: - write_file 结果（10F-C3）

    /// Local file mutation 的唯一 Provider 结果入口。
    ///
    /// `request.displayPath` 是用户已经批准的冻结目标；content、payload
    /// bytes、parent FD、target token 与 staging 名称永远不进入结果。已
    /// 发布但私有 residue 未清理时仍输出 `ok=true` / `published=true`，
    /// 由 cleanupResidue 表示 warning，禁止被 Agent loop 当成可重试失败。
    static func serialize(
        fileMutationResult result: AgentLocalFileMutationResult,
        request: AgentFileMutationRequest
    ) -> String {
        var object: [String: Any] = [
            "ok": result.published,
            "status": result.published
                ? "published"
                : fileMutationStatusName(result.error),
            "path": request.displayPath,
            "published": result.published,
            "payloadBytesRequested": result.payloadBytesRequested,
            "payloadBytesWritten": result.payloadBytesWritten,
            "cleanupComplete": result.cleanupComplete,
            "cleanupResidue": result.cleanupResidue,
        ]
        if let method = result.publicationMethod {
            object["publicationMethod"] = method.rawValue
        }
        if !result.published, let error = result.error {
            object["error"] = fileMutationErrorName(error)
        }
        return encode(object)
    }

    /// Proposal / claim 失败只输出稳定的 domain error；不携带 request 内容。
    static func serialize(error: AgentFileMutationError) -> String {
        encode(["ok": false, "error": fileMutationErrorName(error)])
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

    private static func encodeCommandResult(
        _ result: AgentCommandResult,
        extra: [String: Any]
    ) -> String {
        var object: [String: Any] = [
            "ok": true,
            "executed": true,
            "exit_code": result.exitCode.map { Int($0) } as Any? ?? NSNull(),
            "stdout": result.stdout,
            "stderr": result.stderr,
            "stdout_truncated": result.stdoutTruncated,
            "stderr_truncated": result.stderrTruncated,
            "timed_out": result.timedOut,
            "cancelled": result.cancelled,
            "binary_output_detected": result.binaryOutputDetected,
            "non_utf8_detected": result.nonUTF8Detected,
        ]
        object.merge(extra) { _, new in new }
        return encode(object)
    }

    private static func encodeError(name: String) -> String {
        encode(["ok": false, "error": name])
    }

    private static func commandErrorName(_ error: AgentCommandError) -> String {
        switch error {
        case .invalidCommand, .commandTooLong:
            return "invalidArguments"
        case .cwdUnavailable:
            return "cwdUnavailable"
        case .approvalNotFound:
            return "approvalNotFound"
        case .approvalNotApproved:
            return "approvalNotApproved"
        case .approvalAlreadyResolved:
            return "approvalAlreadyResolved"
        case .approvalCancelled:
            return "approvalCancelled"
        case .approvalStale:
            return "authorizationRejected"
        case .approvalAlreadyClaimed:
            return "approvalAlreadyClaimed"
        case .bindingMismatch:
            return "bindingMismatch"
        }
    }

    /// C2 的内部错误 → Provider 可解释且不可误导为自动重试的分类。
    private static func fileMutationStatusName(_ error: AgentFileMutationError?) -> String {
        guard let error else { return "notPublished" }
        return fileMutationErrorName(error)
    }

    private static func fileMutationErrorName(_ error: AgentFileMutationError) -> String {
        switch error {
        case .invalidPath: return "invalidPath"
        case .payloadTooLarge: return "payloadTooLarge"
        case .cwdUnavailable: return "cwdUnavailable"
        case .outsideWriteScope: return "outsideWriteScope"
        case .parentUnavailable: return "parentUnavailable"
        case .parentNotDirectory: return "parentNotDirectory"
        case .parentSymlinkRejected: return "parentSymlinkRejected"
        case .destinationAlreadyExists: return "destinationAlreadyExists"
        case .targetStale: return "targetStale"
        case .approvalNotFound: return "approvalNotFound"
        case .approvalRequired: return "approvalRequired"
        case .userDenied: return "userDenied"
        case .generationCancelled: return "cancelled"
        case .approvalAlreadyClaimed: return "approvalAlreadyClaimed"
        case .approvalAlreadyConsumed: return "approvalAlreadyConsumed"
        case .bindingMismatch: return "bindingMismatch"
        case .parentCapabilityUnavailable, .parentCapabilityStale:
            return "targetStale"
        case .stagingDirectoryCreationFailed, .stagingDirectoryOpenFailed,
             .stagingDirectoryValidationFailed, .tempFileCreationFailed,
             .tempFileValidationFailed, .payloadWriteFailed, .zeroByteWrite,
             .publicationFailed, .fallbackPublicationFailed:
            return "writeFailed"
        case .tempSyncFailed:
            return "syncFailed"
        case .sourceReplaced:
            return "targetStale"
        case .cleanupResidue:
            return "cleanupResidue"
        case .cancelled:
            return "cancelledBeforePublication"
        }
    }
}
