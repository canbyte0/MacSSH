import Foundation

@testable import MacSSH

/// Phase 10F-B1 测试 fixtures：集中构造合法 request / 绑定期望，
/// 保证各测试文件的确定性（不复用 10E 的测试支撑，避免跨域耦合）。
enum AgentTerminalMutationTestSupport {
    static let generationID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let sessionID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
    static let providerSnapshotID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
    static let createdAt = Date(timeIntervalSince1970: 1_760_000_000)

    static var providerBinding: AgentCommandProviderBinding {
        AgentCommandProviderBinding(
            snapshotID: providerSnapshotID,
            provider: .deepSeek,
            model: "deepseek-test",
            baseURL: URL(string: "https://api.example.invalid")!
        )
    }

    static func makeIdentity(
        sessionID: UUID = AgentTerminalMutationTestSupport.sessionID,
        epoch: AgentTerminalInputTargetEpoch = 7,
        token: AgentTerminalEndpointToken = AgentTerminalEndpointToken(
            rawValue: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!
        )
    ) -> AgentTerminalInputTargetIdentity {
        AgentTerminalInputTargetIdentity(
            logicalSessionID: sessionID,
            inputTargetEpoch: epoch,
            endpointToken: token
        )
    }

    static func makeRequestOrThrow(
        generationID: UUID = AgentTerminalMutationTestSupport.generationID,
        callID: String = "call-1",
        sessionID: UUID = AgentTerminalMutationTestSupport.sessionID,
        epoch: AgentTerminalInputTargetEpoch = 7,
        token: AgentTerminalEndpointToken = AgentTerminalEndpointToken(
            rawValue: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!
        ),
        targetSnapshot: AgentTerminalMutationTargetSnapshot = .local,
        text: String = "echo hi",
        submit: Bool = true
    ) throws -> AgentTerminalMutationRequest {
        let identity = makeIdentity(sessionID: sessionID, epoch: epoch, token: token)
        switch AgentTerminalMutationRequestFactory.make(
            generationID: generationID,
            callID: callID,
            logicalSessionID: sessionID,
            targetIdentity: identity,
            targetSnapshot: targetSnapshot,
            text: text,
            submit: submit,
            providerBinding: providerBinding,
            createdAt: createdAt
        ) {
        case .success(let request):
            return request
        case .failure(let error):
            throw error
        }
    }

    static func expectations(
        generationID: UUID = AgentTerminalMutationTestSupport.generationID,
        sessionID: UUID = AgentTerminalMutationTestSupport.sessionID,
        providerSnapshotID: UUID = AgentTerminalMutationTestSupport.providerSnapshotID,
        epoch: AgentTerminalInputTargetEpoch = 7,
        token: AgentTerminalEndpointToken = AgentTerminalEndpointToken(
            rawValue: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!
        )
    ) -> AgentTerminalMutationClaimExpectations {
        AgentTerminalMutationClaimExpectations(
            generationID: generationID,
            logicalSessionID: sessionID,
            providerSnapshotID: providerSnapshotID,
            inputTargetEpoch: epoch,
            endpointToken: token
        )
    }

    /// 与 request 内冻结身份一致的默认 claim 期望。
    static func expectations(
        for request: AgentTerminalMutationRequest
    ) -> AgentTerminalMutationClaimExpectations {
        AgentTerminalMutationClaimExpectations(
            generationID: request.generationID,
            logicalSessionID: request.logicalSessionID,
            providerSnapshotID: request.providerBinding.snapshotID,
            inputTargetEpoch: request.targetIdentity.inputTargetEpoch,
            endpointToken: request.targetIdentity.endpointToken
        )
    }
}
