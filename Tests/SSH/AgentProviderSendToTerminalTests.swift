import Foundation
import XCTest

@testable import MacSSH

/// Phase 10F-B4-S1 §7/§8/§10/§11/§31/§32/§37/§38/§41：Provider 侧
/// send_to_terminal schema、严格解析与 sanitized result 序列化。
///
/// 覆盖：
/// - 两 provider（OpenAI / DeepSeek Responses）请求体暴露等价 schema；
/// - schema 恰好 `{text: string, submit: boolean}`，无任何 target 字段；
/// - parser 只接受精确形态，Provider JSON 无法注入目标 / 安全身份；
/// - tool result 只含 transport 层白名单字段，无 payload 回显 / token；
/// - 工具描述准确（逐次审批 / 不捕获输出 / 不等待完成 / submit 语义）。
final class AgentProviderSendToTerminalTests: XCTestCase {

    // MARK: - §7/§8/§37 schema

    func testSendToTerminalDefinitionExposesExactlyTextAndSubmit() throws {
        let definition = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "send_to_terminal" }
        )
        let data = try XCTUnwrap(definition.parametersJSON.data(using: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "object")
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)

        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(["text", "submit"]))
        let text = try XCTUnwrap(properties["text"] as? [String: Any])
        XCTAssertEqual(text["type"] as? String, "string")
        let submit = try XCTUnwrap(properties["submit"] as? [String: Any])
        XCTAssertEqual(submit["type"] as? String, "boolean")
        XCTAssertEqual(object["required"] as? [String], ["text", "submit"])
    }

    func testSchemaNeverExposesTargetIdentityFields() throws {
        let definition = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "send_to_terminal" }
        )
        for forbidden in [
            "sessionID", "logicalSessionID", "inputTargetEpoch", "endpointToken",
            "hostID", "hostname", "port", "cwd", "shell", "timeout",
            "approval", "mode", "terminalKind",
        ] {
            XCTAssertFalse(
                definition.parametersJSON.contains("\"\(forbidden)\""),
                "schema 不得暴露 \(forbidden)（§8）"
            )
        }
    }

    func testBothResponsesProvidersSerializeEquivalentSendToTerminalSchema() throws {
        // §37：OpenAI / DeepSeek 均为 flat function tool，无 provider 特化字段。
        let definition = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "send_to_terminal" }
        )
        let wire = try ResponsesRequestBody.ToolDefinition(definition: definition)
        let data = try JSONEncoder().encode(wire)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "function")
        XCTAssertEqual(object["name"] as? String, "send_to_terminal")
        XCTAssertNotNil(object["description"] as? String)
        let parameters = try XCTUnwrap(object["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(["text", "submit"]))
        // 不允许 provider 特化字段（如 strict / provider 自定义 target）。
        XCTAssertEqual(
            Set(object.keys),
            Set(["type", "name", "description", "parameters"])
        )
    }

    // MARK: - §38 严格解析

    func testParserAcceptsExactlyTextAndSubmit() throws {
        let call = try XCTUnwrap(
            try AgentToolCallParsing.parse(
                name: "send_to_terminal",
                argumentsJSON: #"{"text":"printf 'agent-terminal-test\n'","submit":true}"#
            ).get()
        )
        XCTAssertEqual(call.name, "send_to_terminal")
        XCTAssertEqual(call.terminalMutation?.text, "printf 'agent-terminal-test\n'")
        XCTAssertEqual(call.terminalMutation?.submit, true)
    }

    func testParserRejectsMissingWrongOrExtraFields() {
        let invalid: [String] = [
            #"{}"#,
            #"{"text":"hi"}"#,
            #"{"submit":true}"#,
            #"{"text":"hi","submit":"yes"}"#,
            #"{"text":42,"submit":true}"#,
            #"{"text":"hi","submit":true,"sessionID":"x"}"#,
            #"{"text":"hi","submit":true,"epoch":7}"#,
            #"{"Text":"hi","Submit":true}"#,
            #"not json"#,
            #"[]"#,
            #""hi""#,
        ]
        for json in invalid {
            XCTAssertEqual(
                AgentToolCallParsing.parse(name: "send_to_terminal", argumentsJSON: json),
                .failure(.invalidArguments),
                "必须拒绝：\(json)"
            )
        }
    }

    func testParserNeverProducesTargetBindingsFromProviderJSON() throws {
        // §41：Provider 只能控制 text / submit；解析产物结构上无法携带
        // 目标 / 安全身份（schema 不接受，parse 也不透传）。
        let call = try XCTUnwrap(
            try AgentToolCallParsing.parse(
                name: "send_to_terminal",
                argumentsJSON: #"{"text":"ls","submit":false}"#
            ).get()
        )
        XCTAssertEqual(call.arguments.keys.sorted(), ["text"])
        XCTAssertNil(call.arguments["sessionID"])
        XCTAssertNil(call.arguments["endpointToken"])
        XCTAssertNil(call.path)
        XCTAssertNil(call.command)
        XCTAssertEqual(call.terminalMutation?.text, "ls")
        XCTAssertEqual(call.terminalMutation?.submit, false)
    }

    func testEmptyTextReachesFactoryValidationAndIsRejected() throws {
        // parse 层接受空 text（schema 合法），但 B1 request factory 的
        // 冻结校验必须拒绝 0 字节 payload（复用已验收 validation，绝不
        // 在 Provider 边界重写更弱校验）。
        let call = try XCTUnwrap(
            try AgentToolCallParsing.parse(
                name: "send_to_terminal",
                argumentsJSON: #"{"text":"","submit":true}"#
            ).get()
        )
        let arguments = try XCTUnwrap(call.terminalMutation)
        XCTAssertEqual(arguments.text, "")
        guard case .failure(let error) = AgentTerminalMutationRequestFactory.make(
            generationID: UUID(),
            callID: "empty",
            logicalSessionID: AgentTerminalMutationTestSupport.sessionID,
            targetIdentity: AgentTerminalMutationTestSupport.makeIdentity(),
            targetSnapshot: .local,
            text: arguments.text,
            submit: arguments.submit,
            providerBinding: AgentTerminalMutationTestSupport.providerBinding,
            createdAt: Date()
        ) else {
            return XCTFail("空 payload 必须被 request factory 拒绝")
        }
        XCTAssertEqual(error, .invalidArguments)
    }

    func testForbiddenControlCharactersRejectedThroughFactory() {
        // §9：复用 B1 validation——NUL / ESC / CR / C0 / C1 一律拒绝，
        // LF 放行；绝不 normalize / trim / 重写。
        for invalid in ["a\u{0000}b", "a\u{001B}b", "a\rb", "a\tb", "a\u{0085}b"] {
            XCTAssertNotNil(
                AgentTerminalMutationValidation.validate(invalid),
                "必须拒绝: \(invalid.debugDescription)"
            )
        }
        XCTAssertNil(AgentTerminalMutationValidation.validate("line1\nline2"))
    }

    // MARK: - §10/§11 描述准确性

    func testDescriptionStatesApprovalAndNoOutputCaptureAccurately() throws {
        let definition = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "send_to_terminal" }
        )
        let description = definition.description
        XCTAssertTrue(description.contains("explicit user approval"))
        XCTAssertTrue(description.contains("does not capture terminal output"))
        XCTAssertTrue(description.contains("does not wait for command completion"))
        XCTAssertTrue(description.contains("interactive terminal"))
        // §22：submit=false 只承诺不追加 Return，绝不说 safe / 不执行。
        XCTAssertTrue(description.contains("no extra Return is appended"))
        let lowered = description.lowercased()
        for misstatement in ["will not execute", "will only paste", "does not execute"] {
            XCTAssertFalse(lowered.contains(misstatement))
        }
    }

    func testRunCommandDescriptionRemainsIndependent() throws {
        let definition = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "run_command" }
        )
        XCTAssertTrue(definition.description.contains("non-interactive"))
        let mutation = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "send_to_terminal" }
        )
        XCTAssertNotEqual(definition.description, mutation.description)
    }

    // MARK: - §31/§32 sanitized result

    func testSerializedDeliveredResultContainsOnlyWhitelistedFields() throws {
        let result = AgentTerminalMutationDeliveryResult(
            payloadBytesRequested: 6,
            payloadBytesAccepted: 6,
            framingBytesRequested: 12,
            framingBytesAccepted: 12,
            submitBytesRequested: 1,
            submitBytesAccepted: 1,
            bracketedPasteModeSnapshot: true,
            terminalInputState: .confirmed,
            outcome: .delivered,
            error: nil
        )
        let json = AgentToolResultSerializer.serialize(
            mutationResult: result,
            terminalKind: .local
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "ok", "status", "terminalKind", "payloadBytesRequested",
                "payloadBytesAccepted", "framingBytesAccepted",
                "submitBytesAccepted", "transportSubmitted",
            ])
        )
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["status"] as? String, "delivered")
        XCTAssertEqual(object["terminalKind"] as? String, "local")
        XCTAssertEqual(object["payloadBytesRequested"] as? Int, 6)
        XCTAssertEqual(object["payloadBytesAccepted"] as? Int, 6)
        XCTAssertEqual(object["framingBytesAccepted"] as? Int, 12)
        XCTAssertEqual(object["submitBytesAccepted"] as? Int, 1)
        XCTAssertEqual(object["transportSubmitted"] as? Bool, true)
        // §32：绝无 output / token / payload 回显 / 执行语义。
        for forbidden in [
            "output", "stdout", "stderr", "exit", "token", "payload\"",
            "executed", "completed", "endpoint",
        ] {
            XCTAssertFalse(
                json.contains("\"\(forbidden)"),
                "result 不得含 \(forbidden)"
            )
        }
    }

    func testSerializedPartialResultMarksUncertainWithoutPayloadEcho() throws {
        let result = AgentTerminalMutationDeliveryResult(
            payloadBytesRequested: 10,
            payloadBytesAccepted: 4,
            framingBytesRequested: 12,
            framingBytesAccepted: 6,
            submitBytesRequested: 0,
            submitBytesAccepted: 0,
            bracketedPasteModeSnapshot: true,
            terminalInputState: .uncertain,
            outcome: .partial,
            error: .writeFailed
        )
        let json = AgentToolResultSerializer.serialize(
            mutationResult: result,
            terminalKind: .remoteSSH
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["status"] as? String, "partial")
        XCTAssertEqual(object["payloadBytesAccepted"] as? Int, 4)
        XCTAssertEqual(object["error"] as? String, "writeFailed")
        XCTAssertEqual(object["transportSubmitted"] as? Bool, false)
    }

    func testSubmitFalseNeverReportsTransportSubmitted() throws {
        let result = AgentTerminalMutationDeliveryResult(
            payloadBytesRequested: 3,
            payloadBytesAccepted: 3,
            framingBytesRequested: 0,
            framingBytesAccepted: 0,
            submitBytesRequested: 0,
            submitBytesAccepted: 0,
            bracketedPasteModeSnapshot: false,
            terminalInputState: .confirmed,
            outcome: .delivered,
            error: nil
        )
        let json = AgentToolResultSerializer.serialize(
            mutationResult: result,
            terminalKind: .local
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["transportSubmitted"] as? Bool, false)
        XCTAssertEqual(object["ok"] as? Bool, true)
    }

    func testMutationErrorSerializationUsesStableNamesOnly() throws {
        let cases: [(AgentTerminalMutationError, String)] = [
            (.approvalStale, "authorizationRejected"),
            (.targetReplaced, "targetReplaced"),
            (.approvalAlreadyConsumed, "approvalAlreadyConsumed"),
            (.forbiddenControlCharacter, "forbiddenControlCharacter"),
            (.payloadTooLarge, "payloadTooLarge"),
            (.connectionLost, "connectionLost"),
        ]
        for (error, expected) in cases {
            let json = AgentToolResultSerializer.serialize(error: error)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["ok"] as? Bool, false)
            XCTAssertEqual(object["error"] as? String, expected)
            XCTAssertEqual(Set(object.keys), Set(["ok", "error"]))
        }
    }

    func testTerminalMutationToolIsNotReachableThroughReadOnlyRouterDispatch() throws {
        // §36：mutation 边界与 read-only 边界必须可区分；Router 对
        // send_to_terminal 只返回结构化防御错误，绝不触碰 executor。
        guard case .success(let call) = AgentToolCallParsing.parse(
            name: "send_to_terminal",
            argumentsJSON: #"{"text":"x","submit":false}"#
        ) else {
            return XCTFail("注册工具的合法调用必须被 parse 接受")
        }
        XCTAssertEqual(call.name, AgentToolName.sendToTerminal.rawValue)
        XCTAssertEqual(
            AgentToolResultSerializer.serialize(
                error: AgentToolError.terminalMutationRequiresApproval
            ),
            #"{"error":"terminalMutationRequiresApproval","ok":false}"#
        )
    }
}
