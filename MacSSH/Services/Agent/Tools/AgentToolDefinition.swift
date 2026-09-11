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
/// Provider 每轮请求只看到这里登记的 4 个 read-only 工具：
/// - 禁止 Swift reflection 动态导出函数；
/// - 禁止按模型返回的任意 name 动态派发（执行点走 `AgentToolRegistry`
///   静态枚举，未知名字一律 `unknownTool` 拒绝）。
///
/// 工具描述面向模型（英文），只描述能力与边界，绝不包含路径示例之外的
/// 本机信息。
enum AgentToolCatalog: Sendable {
    /// 恰好 4 个工具（§1 Phase boundary）。
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
    ]

    /// 全部工具名（供 gate 断言）。
    static var names: [String] { definitions.map(\.name) }

    /// §52：禁止出现在请求 tool definitions 中的名字（含读操作但依赖
    /// command execution 的 `git_status`）。
    static let prohibitedNames: Set<String> = [
        "run_command", "execute", "shell", "terminal_send", "send_to_terminal",
        "pasteText", "write_file", "delete_file", "rename_file", "mkdir",
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
///   → Decodable typed arguments（仅认 path: String）
///   → validate（path 工具缺 path / 类型错误 / 非法 JSON）
///   → AgentToolRouter（静态注册表派发）
/// ```
///
/// - 非法 JSON → `.invalidArguments`
/// - path 工具缺失 path / path 非 String → `.invalidArguments`
/// - 未知工具名 → `.unknownTool`
/// - 无参数工具：arguments 为空串或 `{}` 视为合法；其余键宽容忽略
///   （拒绝与否不影响安全——工具本身不接受任何参数）。
enum AgentToolCallParsing: Sendable {
    /// 本阶段唯一的 typed arguments 形态（§5：全部工具只允许 path: String）。
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

        // 2. raw JSON → Decodable（§6）。
        let typed: TypedArguments
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // 3. validate：path 工具必须有非空 path（§6：缺失 path → invalidArguments）。
        var arguments: [String: String] = [:]
        switch tool {
        case .getTerminalContext, .getCurrentDirectory:
            break
        case .listDirectory, .readFile:
            guard let path = typed.path, !path.isEmpty else {
                return .failure(.invalidArguments)
            }
            arguments["path"] = path
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
