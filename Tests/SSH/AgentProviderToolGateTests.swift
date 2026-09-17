import Foundation
import XCTest

@testable import MacSSH

/// B4 §4/§5/§7/§8/§9/§50/§52 hard gate：
/// Provider 请求只暴露静态 allowlist 的 4 个 read-only 工具、B4 的
/// command/terminal mutation 工具和 C3 的 Local file mutation 工具。
///
/// - 请求体键集合 = {model, input, stream, tools, tool_choice}；
/// - tools 恰好 7 个 function、名字来自静态注册表（绝非 reflection /
///   动态导出）；
/// - 禁用工具类型（web_search / file_search / computer / code_interpreter /
///   MCP / apply_patch）与未授权危险工具名绝不出现；
/// - tool_choice 恒为 "auto"（绝不 required / 用户可编辑）；
/// - 普通文本中的伪工具标记（DSML 等）绝不触发结构化工具路径（§50）。
final class AgentProviderToolGateTests: XCTestCase {
    // MARK: - §7 请求体键集合

    private func makeBody(
        tools: [AgentToolDefinition] = AgentToolCatalog.definitions
    ) throws -> ResponsesRequestBody {
        try ResponsesRequestBody(
            model: "gpt-test",
            input: [
                ResponsesRequestBody.InputItem.message(
                    role: "user", text: "hello", partType: "input_text"
                )
            ],
            stream: true,
            tools: tools.map(ResponsesRequestBody.ToolDefinition.init(definition:)),
            toolChoice: "auto"
        )
    }

    func testRequestBodyEncodesExactlyModelInputStreamToolsToolChoice() throws {
        let body = try makeBody()
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["model", "input", "stream", "tools", "tool_choice"]
        )
    }

    func testToolChoiceIsAlwaysAutoNeverRequired() throws {
        let body = try makeBody()
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(
            serialized.contains("\"tool_choice\":\"required\""),
            "tool_choice 绝不 required（§8）"
        )
        XCTAssertFalse(serialized.contains("\"tool_choice\":\"none\""))
    }

    // MARK: - §4 静态 allowlist

    func testCatalogContainsExactlySevenToolsWithFourReadOnlyTools() {
        XCTAssertEqual(AgentToolCatalog.definitions.count, 7)
        XCTAssertEqual(
            Set(AgentToolCatalog.names),
            [
                "get_terminal_context",
                "get_current_directory",
                "list_directory",
                "read_file",
                "run_command",
                "send_to_terminal",
                "write_file",
            ]
        )
        // 与执行层静态注册表一一对应（§4：静态枚举派发，非 reflection）。
        XCTAssertEqual(
            Set(AgentToolCatalog.names),
            Set(AgentToolName.allCases.map(\.rawValue))
        )
        XCTAssertEqual(AgentToolName.runCommand.risk, .modifying)
        XCTAssertEqual(AgentToolName.sendToTerminal.risk, .modifying)
        for tool in AgentToolName.allCases
        where tool != .runCommand && tool != .sendToTerminal && tool != .writeFile {
            XCTAssertEqual(tool.risk, .readOnly, "read-only 工具风险不应改变")
        }
    }

    func testToolDefinitionsAreFunctionTypeFlatResponsesFormat() throws {
        let body = try makeBody()
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 7)
        for tool in tools {
            XCTAssertEqual(tool["type"] as? String, "function")
            XCTAssertNotNil(tool["name"] as? String)
            XCTAssertNotNil(tool["description"] as? String)
            let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["type"] as? String, "object")
            XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        }
    }

    func testPathToolsDeclareRequiredSingleStringPathParameter() throws {
        let body = try makeBody()
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
            switch name {
            case "list_directory", "read_file":
                XCTAssertEqual(parameters["required"] as? [String], ["path"])
                XCTAssertEqual(properties.count, 1)
                let path = try XCTUnwrap(properties["path"] as? [String: Any])
                XCTAssertEqual(path["type"] as? String, "string")
            case "get_terminal_context", "get_current_directory":
                XCTAssertTrue(properties.isEmpty, "无参数工具不得声明 properties")
                XCTAssertNil(parameters["required"])
            case "run_command":
                XCTAssertEqual(parameters["required"] as? [String], ["command"])
                XCTAssertEqual(properties.count, 1)
                let command = try XCTUnwrap(properties["command"] as? [String: Any])
                XCTAssertEqual(command["type"] as? String, "string")
            case "send_to_terminal":
                // §7/§8：恰好 text: string + submit: boolean，无任何
                // target / session / epoch / token / mode 字段。
                XCTAssertEqual(parameters["required"] as? [String], ["text", "submit"])
                XCTAssertEqual(properties.count, 2)
                let text = try XCTUnwrap(properties["text"] as? [String: Any])
                XCTAssertEqual(text["type"] as? String, "string")
                let submit = try XCTUnwrap(properties["submit"] as? [String: Any])
                XCTAssertEqual(submit["type"] as? String, "boolean")
                for forbidden in [
                    "sessionID", "logicalSessionID", "inputTargetEpoch", "endpointToken",
                    "hostID", "hostname", "port", "cwd", "shell", "timeout",
                    "approval", "mode", "terminalKind",
                ] {
                    XCTAssertNil(
                        properties[forbidden],
                        "send_to_terminal schema 不得暴露目标身份字段 \(forbidden)（§8）"
                    )
                }
            case "write_file":
                // C3：path/content 均为 required string；target identity
                // 与 overwrite/append 等未来语义不得暴露给 Provider。
                XCTAssertEqual(parameters["required"] as? [String], ["path", "content"])
                XCTAssertEqual(properties.count, 2)
                XCTAssertEqual(
                    try XCTUnwrap(properties["path"] as? [String: Any])["type"] as? String,
                    "string"
                )
                XCTAssertEqual(
                    try XCTUnwrap(properties["content"] as? [String: Any])["type"] as? String,
                    "string"
                )
                for forbidden in [
                    "sessionID", "logicalSessionID", "providerSnapshotID", "targetToken",
                    "parentFD", "cwd", "overwrite", "append", "mode", "remote",
                ] {
                    XCTAssertNil(properties[forbidden])
                }
            default:
                XCTFail("未知工具 \(name)")
            }
        }
    }

    // MARK: - §52 禁止工具名 / 类型

    func testProhibitedNamesNeverAppearInDefinitionsOrSerializedBody() throws {
        let body = try makeBody()
        let serialized = try XCTUnwrap(
            String(data: try JSONEncoder().encode(body), encoding: .utf8)
        )
        for prohibited in [
            "execute", "exec", "shell", "terminal_send",
            "delete_file", "rename_file", "mkdir", "git_status",
            "chmod", "chown", "truncate", "upload",
        ] {
            XCTAssertFalse(
                serialized.contains("\"\(prohibited)\""),
                "tool definitions 不得包含 \(prohibited)"
            )
        }
        for tool in AgentToolCatalog.definitions {
            XCTAssertFalse(AgentToolCatalog.prohibitedNames.contains(tool.name))
        }
    }

    /// C3：Provider 边界必须严格接收两个 required String，并逐字保留
    /// whitespace、Unicode、embedded newline；任何额外字段都拒绝。
    func testWriteFileParserPreservesExactTextAndRejectsInvalidShapes() {
        let content = "  中文🙂e\u{301}\n末尾空格  \n"
        let valid = #"{"path":"notes.txt","content":"  中文🙂é\n末尾空格  \n"}"#
        let parsed = AgentToolCallParsing.parse(name: "write_file", argumentsJSON: valid)
        XCTAssertEqual(
            parsed,
            .success(AgentToolCall(
                name: "write_file",
                arguments: ["path": "notes.txt", "content": content]
            ))
        )

        for invalid in [
            #"{"path":"notes.txt"}"#,
            #"{"content":"x"}"#,
            #"{"path":"notes.txt","content":"x","overwrite":true}"#,
            #"{"path":"notes.txt","content":1}"#,
            #"{"path":"notes.txt","content":"x\u0000y"}"#,
            #"{"path":"notes/..","content":"x"}"#,
        ] {
            XCTAssertEqual(
                AgentToolCallParsing.parse(name: "write_file", argumentsJSON: invalid),
                .failure(.invalidArguments),
                "invalid write_file shape must fail before approval"
            )
        }

        let oversized = String(repeating: "a", count: AgentFileMutationLimits.maxPayloadBytes + 1)
        let oversizedJSON = try? JSONSerialization.data(withJSONObject: [
            "path": "too-large.txt", "content": oversized,
        ])
        XCTAssertEqual(
            AgentToolCallParsing.parse(
                name: "write_file",
                argumentsJSON: String(decoding: oversizedJSON ?? Data(), as: UTF8.self)
            ),
            .failure(.invalidArguments)
        )
    }

    /// C3：schema 字符串本身固定为 {path, content}，不隐式添加未来写入
    /// 能力或 target identity 字段。
    func testWriteFileDefinitionHasExactSchema() throws {
        let definition = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "write_file" }
        )
        XCTAssertEqual(
            definition.parametersJSON,
            #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
        )
        XCTAssertTrue(definition.description.contains("explicit user approval"))
        XCTAssertTrue(definition.description.contains("Existing destinations are not overwritten"))
        XCTAssertTrue(definition.description.contains("Remote file mutation is not supported"))
    }

    func testHumanFacingToolDescriptionsDoNotGrantCommandExecution() throws {
        // read-only 描述不得暗示可执行命令；run_command 必须明确 approval
        // 与 non-interactive 边界，不能把它伪装成 read-only。
        for tool in AgentToolCatalog.definitions where tool.name != "run_command" {
            let text = tool.description.lowercased()
            for forbidden in ["run a command", "execute a command", "shell command", "git status"] {
                XCTAssertFalse(
                    text.contains(forbidden),
                    "\(tool.name) 描述不得暗示命令执行：\(forbidden)"
                )
            }
        }
        let runCommand = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "run_command" }
        )
        XCTAssertTrue(runCommand.description.contains("explicit user approval"))
        XCTAssertTrue(runCommand.description.contains("non-interactive"))

        // §10/§11：send_to_terminal 描述必须准确说明逐次审批、不捕获输出、
        // 不等待完成；submit=false 只承诺不追加 Return（绝不描述为
        // safe / 不执行 / 仅粘贴）。
        let sendToTerminal = try XCTUnwrap(
            AgentToolCatalog.definitions.first { $0.name == "send_to_terminal" }
        )
        let description = sendToTerminal.description.lowercased()
        XCTAssertTrue(description.contains("explicit user approval"))
        XCTAssertTrue(description.contains("does not capture terminal output"))
        XCTAssertTrue(description.contains("does not wait for command completion"))
        XCTAssertTrue(description.contains("no extra return is appended"))
        for misstatement in [
            "will not execute", "will only paste", "safe to review",
            "does not execute", "never executes",
        ] {
            XCTAssertFalse(
                description.contains(misstatement),
                "submit=false 不得描述为不执行 / 仅粘贴（§10/§22）：\(misstatement)"
            )
        }
    }

    // MARK: - §50 普通文本中的伪工具标记绝不解析

    func testRawTextToolMarkupIsJustTextDelta() throws {
        for pseudo in [
            "<tool>read_file</tool>",
            #"<DSML invoke name="bash">"#,
            "```tool\nrun_command\n```",
        ] {
            // 经 JSONSerialization 构造合法 payload（pseudo 含引号 / 换行）。
            let payload = try JSONSerialization.data(withJSONObject: [
                "type": "response.output_text.delta",
                "delta": pseudo,
            ])
            let event = SSEEvent(
                event: "response.output_text.delta",
                data: String(decoding: payload, as: UTF8.self)
            )
            XCTAssertEqual(
                try ResponsesStreamMapper.map(event),
                .agent(.textDelta(pseudo)),
                "伪工具文本必须作为普通文本 delta（§50：绝不解析）"
            )
        }
    }

    // MARK: - §11 function-call 事件进入共享映射（B4 起不再是 ignored）

    func testFunctionCallEventsMapToAssemblyEvents() throws {
        let added = SSEEvent(
            event: "response.output_item.added",
            data: #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}"#
        )
        guard case .outputItemAdded = try ResponsesStreamMapper.map(added) else {
            return XCTFail("output_item.added 必须进入组装路径")
        }

        let delta = SSEEvent(
            event: "response.function_call_arguments.delta",
            data: #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}"#
        )
        XCTAssertEqual(
            try ResponsesStreamMapper.map(delta),
            .functionCallArgumentsDelta(itemID: "fc_1", delta: "{}")
        )

        let done = SSEEvent(
            event: "response.function_call_arguments.done",
            data: #"{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{}"}"#
        )
        XCTAssertEqual(
            try ResponsesStreamMapper.map(done),
            .functionCallArgumentsDone(itemID: "fc_1", arguments: "{}")
        )

        let itemDone = SSEEvent(
            event: "response.output_item.done",
            data: #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{}"}}"#
        )
        guard case .outputItemDone = try ResponsesStreamMapper.map(itemDone) else {
            return XCTFail("output_item.done 必须进入组装路径")
        }
    }

    func testTextDeltaStillWorks() throws {
        let event = SSEEvent(
            event: "response.output_text.delta",
            data: #"{"type":"response.output_text.delta","delta":"hello"}"#
        )
        XCTAssertEqual(
            try ResponsesStreamMapper.map(event),
            .agent(.textDelta("hello"))
        )
    }

    // MARK: - §6 本地验证仍是权威（raw JSON → typed → validate）

    func testLocalParsingRejectsInvalidArgumentsAndUnknownTools() {
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "read_file", argumentsJSON: "{broken"),
            .failure(.invalidArguments)
        )
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "read_file", argumentsJSON: "{}"),
            .failure(.invalidArguments),
            "缺失 path → invalidArguments（§6）"
        )
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "read_file", argumentsJSON: #"{"path":42}"#),
            .failure(.invalidArguments)
        )
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "execute", argumentsJSON: #"{"path":"/etc"}"#),
            .failure(.unknownTool),
            "§51：未知 / 禁止工具名绝不派发；run_command 本身已是 allowlist 工具"
        )
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "get_terminal_context", argumentsJSON: "{}"),
            .success(AgentToolCall(name: "get_terminal_context", arguments: [:]))
        )
        XCTAssertEqual(
            AgentToolCallParsing.parse(
                name: "read_file",
                argumentsJSON: #"{"path":"README.md"}"#
            ),
            .success(AgentToolCall(name: "read_file", arguments: ["path": "README.md"]))
        )
    }
}
