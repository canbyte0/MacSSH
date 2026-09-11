import Foundation

/// Agent 会话类型（任务书 §3/§9）。
///
/// 与 `TerminalSessionKind` 同名概念，但这是 vendor-neutral 的独立
/// 枚举：值模型绝不引用 SwiftTerm / AppKit / SSH 类型。
enum AgentTerminalSessionKind: Sendable, Equatable {
    case local
    case remoteSSH
}

/// 单个终端会话的 terminal context 快照（任务书 §3/§6/§16/§17）。
///
/// 纯 `Sendable` 值：提取完成后不再持有任何 view / buffer / 连接对象。
struct AgentTerminalContext: Sendable, Equatable {
    let sessionID: UUID
    let sessionKind: AgentTerminalSessionKind
    /// Local 固定技术名 "Local"；Remote 为 host 显示名（用户数据不翻译）。
    let targetDisplayName: String
    /// 结构化 cwd：path + source + confidence 三元组（§9，绝不只给裸路径）。
    let workingDirectory: AgentWorkingDirectory

    let rows: Int
    let columns: Int

    /// 无选中时为 nil（§17）。
    let selectedText: String?
    /// 当前活动 buffer（alt screen 时即 alt buffer，§16）的尾部纯文本。
    let recentOutput: String

    let alternateScreen: Bool

    let selectionTruncated: Bool
    let outputTruncated: Bool
}

/// `get_current_directory` 的结构化结果（任务书 §19）。
///
/// 冻结语义：path 不存在时返回 **success + unavailable 三元组**，
/// 让模型区分「未知」与「工具故障」；只有 session 不存在才
/// `sessionUnavailable`。
struct AgentCurrentDirectoryResult: Sendable, Equatable {
    let sessionID: UUID
    let workingDirectory: AgentWorkingDirectory
}

/// 会话的 vendor-neutral 句柄：provider 内部使用，绝不外泄 view 类型。
struct AgentTerminalSessionHandle {
    let id: UUID
    let sessionKind: AgentTerminalSessionKind
    let displayName: String
    let workingDirectory: AgentWorkingDirectory
    /// Local / Remote 都已存在 SwiftTerm view；关闭或无 view 时为 nil。
    let bufferSource: (any AgentTerminalBufferSource)?
}
