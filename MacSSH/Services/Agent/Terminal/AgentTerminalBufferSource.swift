import Foundation

/// terminal buffer 一行的 vendor-neutral 投影（任务书 §3：值模型绝不
/// 出现 `TerminalView` / `NSView` / `SSHConnection` / `BufferLine`）。
struct AgentTerminalLine: Sendable, Equatable {
    /// 纯文本：不含 SGR / 颜色 / cell metadata（§15）。
    let text: String
    /// 软换行续行（§13）。
    let isWrapped: Bool
}

/// terminal buffer 的窄适配接口（任务书 §7/§10/§12）。
///
/// 所有 SwiftTerm / view / buffer 访问都在 `@MainActor` 上进行；实现方
/// 只暴露提取算法所需的最小能力，便于用 fixture 测试算法、用真实
/// SwiftTerm 测试 adapter。
@MainActor
protocol AgentTerminalBufferSource {
    var rows: Int { get }
    var columns: Int { get }
    /// alternate screen 是否激活（§16）。
    var isAlternateScreen: Bool { get }
    /// 无选中返回 nil（§17）。
    var selectedText: String? { get }
    /// 缓冲区当前有效行号的起点（已被裁剪的历史行数，§12）。
    var firstValidRow: Int { get }
    /// scroll-invariant 绝对行号取值，越界返回 nil。
    func line(atScrollInvariantRow row: Int) -> AgentTerminalLine?
}
