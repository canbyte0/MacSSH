import Foundation

// MARK: - 冻结上限（Phase 10F-A Payload 表；任务书 §14/§48）

/// interactive terminal mutation 文本校验的冻结上限（集中定义，
/// 对齐 `AgentCommandLimits` / `AgentTextLimits` 惯例）。
///
/// 上限是 **UTF-8 字节数**，不是字符数（多字节边界必须逐一测试）；
/// 常量冻结，模型无法经 schema 协商。
enum AgentTerminalMutationLimits: Sendable {
    /// payload 最小 1 UTF-8 byte（空 payload 拒绝）。
    static let minPayloadBytes = 1
    /// payload 最大 64 KiB = 65,536 UTF-8 bytes（10F-A 冻结）。
    static let maxPayloadBytes = 64 * 1024
}

// MARK: - 错误（任务书 §31）

/// Terminal mutation domain 的稳定错误。
///
/// 全部 case 不带关联值：可判等、可测试；绝不把 payload 文本、
/// 凭据、Provider 响应体、raw pointer 塞进错误对象传播（§31/§32）。
/// `userDenied` / `cancelled` 以 resolution 语义表达（见
/// `AgentTerminalMutationApprovalResolution`），与 command 域的
/// denied ≠ cancelled 划分保持一致。
enum AgentTerminalMutationError: Error, Equatable, Sendable {
    /// 空 payload（0 bytes）或构造参数自相矛盾（10F-A 冻结：空拒绝，
    /// 绝不静默转成任何其它表示）。
    case invalidArguments
    /// payload 超过 65,536 UTF-8 bytes（§14：byte limit ≠ character count）。
    case payloadTooLarge
    /// 命中冻结拒绝字符集：NUL / C0（除 LF）/ CR / DEL / C1（§14）。
    case forbiddenControlCharacter
    /// approvalID 不存在（未登记或已被 purge）。
    case approvalNotFound
    /// claim 时 approval 尚未被批准。
    case approvalNotApproved
    /// approval 已到达终态（如 denied），转移 / claim 不再有效。
    case approvalAlreadyResolved
    /// approval 已因 Stop / generation / session 取消而失效。
    case approvalCancelled
    /// 呈递的授权凭据与 coordinator 状态不匹配（stale / 不认识的 permit）。
    case approvalStale
    /// 同一 approval 的第二次 claim / 第二次消费（单次语义，§34/§35）。
    case approvalAlreadyConsumed
    /// claim 期望绑定与审批记录不一致（generation / logical session /
    /// provider snapshot 任一不匹配，§19/§25）。
    case bindingMismatch
    /// 目标 incarnation 不再匹配（epoch / endpoint token 变化 =
    /// targetReplaced / stale，§23/§50）；零授权、零交付。
    case targetReplaced
    /// Local PTY 已不可用；不会再向新 incarnation 寻址。
    case processUnavailable
    /// Remote SSH 连接已丢失；旧 capability 不会重定向到新连接。
    case connectionLost
    /// Local PTY 输入 channel 已关闭；旧 capability 不会重定向。
    case channelClosed
    /// 物理写入未完整确认；结果中的 accepted 字节数保留精确前缀。
    case writeFailed
    /// 交付任务取消；已经确认的前缀不会回滚。
    case cancelled
    /// 固定输入事务无法取得；不会发送任何 mutation 字节。
    case transactionUnavailable
}

// MARK: - 校验（任务书 §14/§15/§48）

/// mutation 文本校验（10F-A 冻结策略）。
///
/// 规则全部基于 **UTF-8 字节数**：
/// - `1 ... 65536` bytes（§14）；
/// - **拒绝集**（字节/标量层面判死，出现即拒绝，绝不静默改写表示）：
///   NUL (U+0000)；C0 控制 U+0001–U+001F **除 LF (U+000A)**（含 TAB /
///   VT / FF——首版一并拒绝，避免 tab-completion 注入）；CR (U+000D)；
///   DEL (U+007F)；C1 控制 (U+0080–U+009F)。由此 ESC / CSI / OSC / BEL
///   序列在 payload 层面不可能出现；
/// - **多行允许**：LF (U+000A) 是唯一放行的控制标量（行分隔）；
/// - **无任何 normalization**（§15）：不 trim、不重写引号、不插入 /
///   删除换行、不做 CR/LF 转换、不做 Unicode normalize——审批绑定的是
///   被接受的原样 UTF-8 文本；若表示被拒，就拒绝该表示；
/// - `submit == false` 只承诺“不追加额外 CR”，**不承诺“不执行”**
///   （10F-A-R1 §R1.5 冻结；payload 自身可能触发交互程序行为）。
enum AgentTerminalMutationValidation: Sendable {
    /// 返回 nil 表示合法；否则给出首个命中的错误。
    static func validate(_ text: String) -> AgentTerminalMutationError? {
        let byteCount = text.utf8.count
        if byteCount < AgentTerminalMutationLimits.minPayloadBytes {
            return .invalidArguments
        }
        if byteCount > AgentTerminalMutationLimits.maxPayloadBytes {
            return .payloadTooLarge
        }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0000,                     // NUL
                 0x0001...0x0009,           // C0：含 TAB，排除 LF(0x0A)
                 0x000B...0x000C,           // VT / FF
                 0x000D,                    // CR（绝不静默转 LF / 删除）
                 0x000E...0x001F,           // C0 其余（含 ESC 0x1B）
                 0x007F,                    // DEL
                 0x0080...0x009F:           // C1 控制
                return .forbiddenControlCharacter
            default:
                continue
            }
        }
        return nil
    }
}
