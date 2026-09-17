import Foundation

// MARK: - Provider-neutral tool definition（B4 §3/§4/§5）

/// 工具定义（provider-neutral，§3）：domain 不依赖 OpenAI / DeepSeek JSON。
///
/// `parametersJSON` 是 JSON Schema 字符串（§5）；provider adapter 各自
/// 决定线格式（OpenAI / DeepSeek Responses 均为 flat function tool）。
struct AgentToolDefinition: Sendable, Equatable {
    let name: String
    let description: String
    let parametersJSON: String
}

/// 静态 allowlist（§4 hard gate）。
///
/// Provider 每轮请求只看到这里登记的 4 个 read-only 工具、10E-B4 的
/// `run_command`、10F-B4-S1 的 `send_to_terminal` 与 10F-C3 的
/// Local-only `write_file`：
/// - 禁止 Swift reflection 动态导出函数；
/// - 禁止按模型返回的任意 name 动态派发（执行点走 `AgentToolRegistry`
///   静态枚举，未知名字一律 `unknownTool` 拒绝）。
///
/// 工具描述面向模型（英文），只描述能力与边界，绝不包含路径示例之外的
/// 本机信息。
enum AgentToolCatalog: Sendable {
    /// 恰好 7 个工具（10F-C3 边界）。
    static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: AgentToolName.getTerminalContext.rawValue,
            description: "Get a bounded snapshot of the current terminal session: "
                + "recent output (up to 200 rows), current selection, rows and columns, "
                + "current working directory metadata, and whether the alternate screen "
                + "is active. Use this to understand what the user is doing in the terminal.",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        AgentToolDefinition(
            name: AgentToolName.getCurrentDirectory.rawValue,
            description: "Get the current working directory of the terminal session "
                + "with its source and confidence. Returns structured metadata, not a tool failure, "
                + "when the directory is unknown.",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        AgentToolDefinition(
            name: AgentToolName.listDirectory.rawValue,
            description: "List the entries of a directory. The path may be absolute or "
                + "relative to the terminal's current working directory. Returns up to 500 "
                + "entries in deterministic order (directories first, then symbolic links, "
                + "then files). Paths outside the terminal's working directory root are rejected.",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#
        ),
        AgentToolDefinition(
            name: AgentToolName.readFile.rawValue,
            description: "Read a UTF-8 text file. The path may be absolute or relative "
                + "to the terminal's current working directory. Returns at most 256 KiB of "
                + "text with truncation metadata. Binary files and paths outside the "
                + "terminal's working directory root are rejected.",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#
        ),
        AgentToolDefinition(
            name: AgentToolName.runCommand.rawValue,
            description: "Run one exact non-interactive shell command in the "
                + "originating terminal session's frozen working directory. "
                + "Every request requires explicit user approval. stdin is unavailable; "
                + "the command does not modify the user's interactive terminal state.",
            parametersJSON: #"{"type":"object","properties":{"command":{"type":"string","description":"The exact non-interactive shell command to run."}},"required":["command"],"additionalProperties":false}"#
        ),
        AgentToolDefinition(
            name: AgentToolName.sendToTerminal.rawValue,
            description: "Send text into the user's existing interactive terminal "
                + "session. The exact text is delivered to that terminal's input; the "
                + "terminal or a running interactive application may act on it "
                + "immediately. Every call requires explicit user approval in the "
                + "MacSSH app before anything is delivered. This tool does not capture "
                + "terminal output and does not wait for command completion. Set "
                + "submit to true to have MacSSH append a Return after the text; "
                + "submit false only means no extra Return is appended — the text may "
                + "still trigger a running interactive application. Use run_command "
                + "instead when you need non-interactive execution with captured output.",
            parametersJSON: #"{"type":"object","properties":{"text":{"type":"string","description":"The exact text to send to the interactive terminal."},"submit":{"type":"boolean","description":"Whether MacSSH appends a Return after the text."}},"required":["text","submit"],"additionalProperties":false}"#
        ),
        AgentToolDefinition(
            name: AgentToolName.writeFile.rawValue,
            description: "Create a new Local text file in the current approved write scope. "
                + "Every request requires explicit user approval. Existing destinations "
                + "are not overwritten. Content is UTF-8 text, maximum 256 KiB. "
                + "Remote file mutation is not supported.",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
        ),
    ]

    /// 全部工具名（供 gate 断言）。
    static var names: [String] { definitions.map(\.name) }

    /// §52：禁止出现在请求 tool definitions 中的名字（含读操作但依赖
    /// command execution 的 `git_status`）。`send_to_terminal` 与
    /// `write_file` 已分别在 10F-B4-S1 / 10F-C3 注册，不再是禁止名；
    /// `terminal_send` / `pasteText` / 其它文件写工具仍全部禁止。
    static let prohibitedNames: Set<String> = [
        "execute", "exec", "shell", "terminal_send",
        "pasteText", "delete_file", "rename_file", "mkdir",
        "move", "copy", "upload", "chmod", "chown", "truncate", "git_status",
    ]
}

// MARK: - 工具调用本地验证（B4 §6）

/// raw JSON arguments → typed arguments 的本地验证（§6 hard gate：
/// 即使 Provider 支持 schema / strict，也不相信模型参数一定正确）。
///
/// 执行链固定为：
///
/// ```text
/// raw JSON string
///   → Decodable / strict typed arguments（path 或 command）
///   → validate（path 工具缺 path / 类型错误 / 非法 JSON）
///   → AgentToolRouter（静态注册表派发）
/// ```
///
/// - 非法 JSON → `.invalidArguments`
/// - path 工具缺失 path / path 非 String → `.invalidArguments`
/// - run_command 缺失 command、command 非 String、未知字段或非法 JSON
///   → `.invalidArguments`
/// - send_to_terminal 非 `{text: String, submit: Bool}` 精确形态
///   → `.invalidArguments`
/// - write_file 非 `{path: String, content: String}` 精确形态、超过
///   256 KiB UTF-8、含 U+0000 或 path 结构非法 → `.invalidArguments`
/// - 未知工具名 → `.unknownTool`
/// - 无参数工具：arguments 为空串或 `{}` 视为合法；其余键宽容忽略
///   （拒绝与否不影响安全——工具本身不接受任何参数）。
enum AgentToolCallParsing: Sendable {
    /// Path 工具的 typed arguments。
    private struct TypedArguments: Decodable {
        let path: String?
    }

    /// 解析结果：`.call` 携带 router 需要的 `AgentToolCall`。
    static func parse(
        name: String,
        argumentsJSON: String
    ) -> Result<AgentToolCall, AgentToolError> {
        // 1. 静态注册表（§4/§51：未知名字绝不派发）。
        guard let tool = AgentToolRegistry.lookup(name) else {
            return .failure(.unknownTool)
        }

        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. run_command 采用严格字典校验，不能依赖 Decoder 忽略未知键。
        if tool == .runCommand {
            guard
                let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any],
                Set(dictionary.keys) == Set(["command"]),
                let command = dictionary["command"] as? String
            else {
                return .failure(.invalidArguments)
            }
            return .success(AgentToolCall(name: name, arguments: ["command": command]))
        }

        // 2b. send_to_terminal 同样采用严格字典校验（10F-B4-S1 §38：
        //     恰好 text: String + submit: Bool，任何多余 / 缺失 / 类型
        //     错误 / 非法 JSON 一律 invalidArguments；text 内容本身由
        //     B1 request factory 的 validation 二次把关）。
        if tool == .sendToTerminal {
            guard
                let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any],
                Set(dictionary.keys) == Set(["text", "submit"]),
                let text = dictionary["text"] as? String,
                let submit = dictionary["submit"] as? Bool
            else {
                return .failure(.invalidArguments)
            }
            return .success(AgentToolCall(
                name: name,
                arguments: ["text": text],
                terminalMutation: AgentToolTerminalMutationArguments(
                    text: text,
                    submit: submit
                )
            ))
        }

        // 2c. write_file 是 Provider boundary 的严格文本契约：必须恰好
        // path + content 两个 String，不能让 JSONDecoder 忽略安全字段。
        if tool == .writeFile {
            guard
                let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any],
                Set(dictionary.keys) == Set(["path", "content"]),
                let path = dictionary["path"] as? String,
                let content = dictionary["content"] as? String,
                AgentFileMutationRequestFactory.isStructurallyValidPath(path),
                !content.utf8.contains(0),
                Data(content.utf8).count <= AgentFileMutationLimits.maxPayloadBytes
            else {
                return .failure(.invalidArguments)
            }
            return .success(AgentToolCall(
                name: name,
                arguments: ["path": path, "content": content]
            ))
        }

        // 3. raw JSON → Decodable（§6）。
        let typed: TypedArguments
        if trimmed.isEmpty {
            typed = TypedArguments(path: nil)
        } else {
            guard
                let data = trimmed.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(TypedArguments.self, from: data)
            else {
                return .failure(.invalidArguments)
            }
            typed = decoded
        }

        // 4. validate：path 工具必须有非空 path（§6：缺失 path → invalidArguments）。
        var arguments: [String: String] = [:]
        switch tool {
        case .getTerminalContext, .getCurrentDirectory:
            break
        case .listDirectory, .readFile:
            guard let path = typed.path, !path.isEmpty else {
                return .failure(.invalidArguments)
            }
            arguments["path"] = path
        case .runCommand:
            // 已在严格分支中返回；保留穷尽性保护，绝不向 Router 派发裸命令。
            return .failure(.invalidArguments)
        case .sendToTerminal:
            // 已在严格分支中返回；保留穷尽性保护。
            return .failure(.invalidArguments)
        case .writeFile:
            // 已在严格分支中返回；保留穷尽性保护。
            return .failure(.invalidArguments)
        }
        return .success(AgentToolCall(name: name, arguments: arguments))
    }

    /// Tool card 的展示目标（§40）：path 工具显示请求 path（用户本地
    /// 可见）；其余为 nil。解析失败时返回 nil，绝不因展示层抛错。
    static func displayTarget(of call: AgentProviderToolCall) -> String? {
        guard
            let data = call.argumentsJSON.data(using: .utf8),
            let typed = try? JSONDecoder().decode(TypedArguments.self, from: data),
            let path = typed.path,
            !path.isEmpty
        else {
            return nil
        }
        return path
    }
}
