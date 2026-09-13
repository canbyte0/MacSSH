import Foundation

// MARK: - Remote exec payload 构造（10E-A §31/§38 冻结 wrapper）

/// Remote exec 的 payload 构造器：**App 唯一允许生成的 shell 片段**就是
/// 「进入 approved cwd」的前缀 wrapper，模型原始 command 原样保留。
///
/// 冻结语义：
/// - cwd 只来自 `AgentCommandRequest.workingDirectory`（authoritative OSC 7，
///   B1 factory 已拒绝 approximate / unavailable / 相对路径）；
/// - cwd 经专用单引号引用 helper 编码（`'` → `'\''`），绝不裸插值；
/// - wrapper 形如 `cd '<cwd>' || exit $?\n<command>`：cwd 失败 → 原 command
///   **零执行**（remote shell 以非零码退出），绝不 fallback HOME / 登录目录 / `/`；
/// - 原 command **不 trim、不规范化空白、不改引号、不加任何东西**，多行 /
///   注释 / here-doc 语义保持不变；
/// - exec payload 有 App 侧确定性上界：越界返回 `execPayloadTooLarge`，
///   **绝不** silent truncate（SSH exec 无 App 可控 cwd 参数，故必须前缀 wrapper）。
enum AgentRemoteCommandBuilder {
    /// 构造最终 exec payload。
    ///
    /// - Parameter command: 已审批的原始 command（B1 已校验 ≤16 KiB UTF-8）。
    /// - Parameter workingDirectory: 已审批的 authoritative 绝对 cwd。
    static func build(
        command: String,
        workingDirectory: String
    ) -> Result<String, AgentRemoteCommandExecutionError> {
        guard workingDirectory.utf8.count <= AgentRemoteCommandExecutionLimits.maxWorkingDirectoryBytes else {
            return .failure(.execPayloadTooLarge)
        }
        let payload = "cd " + shellSingleQuote(workingDirectory) + " || exit $?\n" + command
        guard payload.utf8.count <= AgentRemoteCommandExecutionLimits.maxExecPayloadBytes else {
            return .failure(.execPayloadTooLarge)
        }
        return .success(payload)
    }

    /// 单引号 shell 引用（POSIX `sh` / `bash` / `zsh` / `dash` 通用形式）。
    ///
    /// - `abc` → `'abc'`
    /// - `/a/bob's project` → `'/a/bob'\''s project'`
    ///
    /// 单引号内除 `'` 外的所有字符（包括 `$`、反引号、反斜杠、`!`、`\n`、
    /// Unicode / emoji）都是字面量，不会被 shell 展开。cwd 由 B1 factory
    /// 保证是绝对路径，不存在 `-` 开头被当作 option 的路径。
    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
