import Foundation

// MARK: - 一次性执行授权（任务书 §21/§22；语义对齐 10E ExecutionAuthorization）

/// Approval coordinator 产生的 **opaque capability**：未来 B2/B3 消费
/// 交付授权的唯一凭证。
///
/// 安全语义：
/// - 本类型由 coordinator 在 claim 的原子 CAS 转移（`approved →
///   executionClaimed`）中生成，permit 随即登记进 coordinator 内部账本；
///   `redeem` 时核对 permit 与已登记值，任何自行拼装的实例都会被
///   `approvalStale` 拒绝——构造控制 + 状态校验双保险，单次消费语义
///   成立（复制本值重复 redeem 同样失败）；
/// - `request` 是 coordinator 保存的 **immutable 原 request**：exact
///   text + exact submit + exact 目标 incarnation 身份（generation /
///   callID / logical session / epoch / endpoint token）+ provider 快照，
///   即 §19/§25 冻结的全部绑定字段；调用方绝不重读 / 重传任何值；
/// - **只承载 identity / binding**：本类型不做 transport I/O、不解析
///   当前目标、不持有 active-tab / session 查找闭包 / 连接查找闭包。
///   B2/B3 将凭本授权中的 incarnation 身份对账一个真实
///   `TerminalMutationEndpoint`（capability 持具体 endpoint 对象强引用，
///   具备 acknowledged writer 语义）后才允许交付——该分离在此显式声明
///   （任务书 §22）。
struct AgentTerminalMutationExecutionAuthorization: Sendable, Equatable {
    let approvalID: UUID
    let generationID: UUID
    let callID: String
    let logicalSessionID: UUID
    let targetIdentity: AgentTerminalInputTargetIdentity
    /// 冻结的原始 request（仅供未来 B2/B3 executor 消费；UI 一律走 snapshot）。
    let request: AgentTerminalMutationRequest
    /// 单次消费凭据：coordinator 生成并登记；外部无法获得合法未消费值。
    let permit: UUID

    /// Controlled initializer：只在 coordinator 的 claim 转移中调用。
    init(
        approvalID: UUID,
        generationID: UUID,
        callID: String,
        logicalSessionID: UUID,
        targetIdentity: AgentTerminalInputTargetIdentity,
        request: AgentTerminalMutationRequest,
        permit: UUID
    ) {
        self.approvalID = approvalID
        self.generationID = generationID
        self.callID = callID
        self.logicalSessionID = logicalSessionID
        self.targetIdentity = targetIdentity
        self.request = request
        self.permit = permit
    }
}

extension AgentTerminalMutationExecutionAuthorization: CustomStringConvertible, CustomDebugStringConvertible {
    /// redacted：绝不输出 payload / token / permit（§32）。
    var description: String {
        "AgentTerminalMutationExecutionAuthorization(approvalID: \(approvalID.uuidString), "
            + "generationID: \(generationID.uuidString), callID: \(callID), "
            + "logicalSessionID: \(logicalSessionID.uuidString), "
            + "inputTargetEpoch: \(targetIdentity.inputTargetEpoch), "
            + "content: <redacted>)"
    }

    var debugDescription: String { description }
}
