import Foundation

/// Agent 工具的「变更风险」轴：工具对系统的写入能力（任务书 10D-B1 §11）。
enum AgentToolRisk: Sendable, Equatable {
    /// 不修改任何系统状态。
    case readOnly
    /// 修改系统状态但原则上可恢复（写文件、重命名、新建目录等）。
    case modifying
    /// 不可恢复地破坏数据（删除、覆盖等），必须最高级别确认。
    case destructive
}

/// Agent 工具的「数据披露」轴：读取数据前必须满足的策略（任务书 §11）。
enum AgentDataAccessPolicy: Sendable, Equatable {
    /// 只访问终端会话上下文（受限行数的 scrollback 尾部），
    /// 不触碰文件系统。
    case sessionContext
    /// 读取文件数据前必须先经过 `AgentReadScope` 路径校验。
    case scopedFileRead
}

// 两个 enum 必须独立定义、绝不合并：
//
//     readOnly（不变更系统）≠ 可以随便读
//
// 变更风险与披露风险是正交轴。例如未来的 read_file 是 readOnly +
// scopedFileRead：它不改系统，但披露数据前仍必须通过 scope 校验；
// 而 get_terminal_context 是 readOnly + sessionContext。混淆两轴
// 会让「只读」工具绕过文件访问策略——这正是任务书 §11 的硬要求。
