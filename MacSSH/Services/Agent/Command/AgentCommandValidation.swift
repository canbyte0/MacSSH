import Foundation

// MARK: - 冻结上限（Phase 10E-A Limits 表）

/// run_command 输入校验的冻结上限（任务书 10E-B1 §13/§14；集中定义，
/// 对齐 `AgentTextLimits` 惯例，禁止散落在调用方）。
enum AgentCommandLimits: Sendable {
    /// command 的 UTF-8 字节上限：16 KiB = 16,384 bytes。
    /// 边界语义：16384 bytes 合法；16385 bytes 非法（§14 逐一测试）。
    static let maxCommandBytes = 16 * 1024
}

// MARK: - 错误（任务书 §59）

/// Command domain 的 vendor-neutral 错误。
///
/// 刻意 **不包含** spawn 失败 / timeout / exit status 等——那些属于
/// 后续 executor（10E-B2 Local / 10E-B3 Remote），本层绝不提前承诺。
/// 全部 case 不带关联值：可判等、可测试，绝不把 command / cwd 内容
/// 塞进错误对象传播（§57 零内容日志的组成部分）。
enum AgentCommandError: Error, Equatable, Sendable {
    /// command 非法：空 / whitespace-only / 含 U+0000（§13/§67）。
    case invalidCommand
    /// command 超过 16 KiB UTF-8 字节（§13/§14）。
    case commandTooLong
    /// cwd 非权威或非绝对路径（§16/§62：唯一正确结果是失败，绝不 fallback）。
    case cwdUnavailable
    /// approvalID 不存在（未登记或已被 purge）。
    case approvalNotFound
    /// claim 时 approval 尚未被批准（§75：awaitingApproval 不可 claim）。
    case approvalNotApproved
    /// approval 已到达终态（如 denied），转移 / claim 不再有效（§27）。
    case approvalAlreadyResolved
    /// approval 已因 Stop / generation / session 取消而失效（§24/§25/§77）。
    case approvalCancelled
    /// 呈递的授权凭据与 coordinator 状态不匹配（stale / 不认识的 permit）。
    case approvalStale
    /// 同一 approval 的第二次 claim / 第二次消费（§31/§74：单次语义）。
    case approvalAlreadyClaimed
    /// claim 期望绑定与审批记录不一致（§78–§80：generation / session /
    /// provider snapshot 任一不匹配）。
    case bindingMismatch
}

// MARK: - 校验（任务书 §13/§14/§65/§67/§68）

/// command 文本校验。
///
/// 规则全部基于 **UTF-8 字节数**（§14：byte limit ≠ Character count，
/// Unicode 测试必须证明这一点）：
/// - 含 U+0000 → invalid（绝不进入未来执行通道，§67）；
/// - 空 / whitespace-only → invalid（§65：trim 仅用于本判定）；
/// - 超过 16 KiB UTF-8 bytes → invalid（§13）；
/// - 多行允许（§13）；除 whitespace 判定外绝不改写原始 bytes，
///   保存 / 审批 / 未来执行的一律是原始 command（§65/§66：不 trim、
///   不重写引号、不添加 sudo / cd / shell flags、不删除 newline）。
enum AgentCommandValidation: Sendable {
    /// 返回 nil 表示合法；否则给出首个命中的错误。
    static func validate(_ command: String) -> AgentCommandError? {
        // U+0000 按字节判定，覆盖任何 grapheme 组合形态（§67）。
        if command.utf8.contains(0) {
            return .invalidCommand
        }
        // whitespace-only 仅用于判定；原始 command 原样保存（§65）。
        if command.isEmpty
            || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalidCommand
        }
        if command.utf8.count > AgentCommandLimits.maxCommandBytes {
            return .commandTooLong
        }
        return nil
    }
}
