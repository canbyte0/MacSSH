import Foundation

// MARK: - 一次性执行授权（任务书 §29/§31/§32）

/// Approval coordinator 产生的 **opaque capability**：未来 executor
/// 消费执行授权的唯一凭证。
///
/// 安全语义（§32）：
/// - **不允许当作"批准证明"的裸 `{command: String}`**：本类型由
///   coordinator 在 claim 的原子 CAS 转移（`approved → executionClaimed`）
///   中生成，permit 随即登记进 coordinator 内部账本；
/// - init 是 internal controlled initializer，但 **凭据有效性由
///   coordinator 状态背书**：`redeem` 时核对 permit 与已登记值，
///   任何自行拼装的实例都会被 `approvalStale` 拒绝——构造控制 +
///   状态校验双保险，单次消费语义成立（§31：一个 approval 最多一次
///   有效 claim；复制本值重复 redeem 同样失败）；
/// - `request` 是 coordinator 内保存的 **immutable 原 request**
///   （§43/§44/§45：approved 的 command A 执行时仍是 command A、cwd /
///   session 不得漂移；executor 绝不在 claim 时重新传入或重读这些值）。
struct AgentCommandExecutionAuthorization: Sendable, Equatable {
    let approvalID: UUID
    let generationID: UUID
    let callID: String
    let sessionID: UUID
    /// 冻结的原始 request（仅供未来 executor 消费；UI 一律走 snapshot）。
    let request: AgentCommandRequest
    /// 单次消费凭据：coordinator 生成并登记；外部无法获得合法未消费值。
    let permit: UUID

    /// Controlled initializer：只在 coordinator 的 claim 转移中调用。
    init(
        approvalID: UUID,
        generationID: UUID,
        callID: String,
        sessionID: UUID,
        request: AgentCommandRequest,
        permit: UUID
    ) {
        self.approvalID = approvalID
        self.generationID = generationID
        self.callID = callID
        self.sessionID = sessionID
        self.request = request
        self.permit = permit
    }
}

extension AgentCommandExecutionAuthorization: CustomStringConvertible, CustomDebugStringConvertible {
    /// redacted：绝不输出 command / cwd / permit / displayName（§57）。
    var description: String {
        "AgentCommandExecutionAuthorization(approvalID: \(approvalID.uuidString), "
            + "generationID: \(generationID.uuidString), callID: \(callID), "
            + "sessionID: \(sessionID.uuidString), content: <redacted>)"
    }

    var debugDescription: String { description }
}
