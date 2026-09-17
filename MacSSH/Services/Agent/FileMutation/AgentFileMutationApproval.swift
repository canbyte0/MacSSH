import Foundation

/// File-mutation approval 的单向状态；C1 到 `redeemed` 即停止。
enum AgentFileMutationApprovalState: Sendable, Equatable {
    case awaitingApproval
    case approved
    case denied
    case cancelled
    case executionClaimed
    case redeemed
}

/// UI/future orchestration 可读取的决策结论；它本身不授予 side-effect permit。
enum AgentFileMutationApprovalResolution: Sendable, Equatable {
    case approved
    case denied
    case cancelled
}

/// 用户决策的竞争结果。
enum AgentFileMutationApprovalActionResult: Sendable, Equatable {
    case performed
    case alreadyResolved(AgentFileMutationApprovalState)
    case notFound
}

/// claim 必须逐项呈递 request 的 application-generated binding。
struct AgentFileMutationClaimExpectations: Sendable, Equatable {
    let generationID: UUID
    let callID: String
    let logicalSessionID: UUID
    let providerSnapshotID: UUID
    let targetIdentity: AgentFileMutationTargetIdentity
}

/// UI 可读取的 immutable snapshot；没有状态修改能力。
struct AgentFileMutationApprovalSnapshot: Sendable {
    let id: UUID
    let request: AgentFileMutationRequest
    let state: AgentFileMutationApprovalState
}

extension AgentFileMutationApprovalSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
    /// 不让默认 reflection 泄漏 path 或 payload。
    var description: String {
        "AgentFileMutationApprovalSnapshot(id: \(id.uuidString), state: \(state), request: <redacted>)"
    }

    var debugDescription: String { description }
}

/// coordinator claim 后生成的一次性 capability；复制该值不会复制 permit。
struct AgentFileMutationExecutionAuthorization: Sendable {
    let approvalID: UUID
    let generationID: UUID
    let callID: String
    let logicalSessionID: UUID
    let targetIdentity: AgentFileMutationTargetIdentity
    let request: AgentFileMutationRequest
    let permit: UUID

    /// authorization 只能由 coordinator 在成功 claim 后签发。
    private init(
        approvalID: UUID,
        generationID: UUID,
        callID: String,
        logicalSessionID: UUID,
        targetIdentity: AgentFileMutationTargetIdentity,
        request: AgentFileMutationRequest,
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

    /// coordinator 唯一的内部签发入口；没有接受 Provider 自定义 identity 的参数。
    static func issue(
        approvalID: UUID,
        request: AgentFileMutationRequest,
        permit: UUID
    ) -> AgentFileMutationExecutionAuthorization {
        AgentFileMutationExecutionAuthorization(
            approvalID: approvalID,
            generationID: request.generationID,
            callID: request.callID,
            logicalSessionID: request.logicalSessionID,
            targetIdentity: request.targetIdentity,
            request: request,
            permit: permit
        )
    }
}

extension AgentFileMutationExecutionAuthorization: CustomStringConvertible, CustomDebugStringConvertible {
    /// permit、display path 和 content 均不出现在诊断输出。
    var description: String {
        "AgentFileMutationExecutionAuthorization(approvalID: \(approvalID.uuidString), "
            + "generationID: \(generationID.uuidString), callID: \(callID), "
            + "logicalSessionID: \(logicalSessionID.uuidString), content: <redacted>)"
    }

    var debugDescription: String { description }
}
