import Foundation

// MARK: - Endpoint capability（10F-B4-S1 §13/§15）

/// 一次 send_to_terminal proposal 在 admission 时刻冻结的 endpoint
/// capability：Local 或 Remote 二选一，强引用已验收 B2/B3 的 exact
/// endpoint 对象。
///
/// 该值只在 proposal admission（卡片创建前）解析一次，之后整个
/// approval → claim → redeem → delivery 生命周期都使用同一个冻结
/// capability——绝不延迟到用户点击 Approve 或 executor 启动时再查找，
/// 也绝不从 active tab / selected session 回退（§13/§14）。
enum AgentTerminalMutationEndpointCapability {
    case local(AgentLocalTerminalMutationEndpoint)
    case remote(AgentRemoteTerminalMutationEndpoint)

    /// 授权目标身份三元组（session + epoch + token）。
    var targetIdentity: AgentTerminalInputTargetIdentity {
        switch self {
        case .local(let endpoint):
            return AgentTerminalInputTargetIdentity(
                logicalSessionID: endpoint.logicalSessionID,
                inputTargetEpoch: endpoint.inputTargetEpoch,
                endpointToken: endpoint.endpointToken
            )
        case .remote(let endpoint):
            return AgentTerminalInputTargetIdentity(
                logicalSessionID: endpoint.logicalSessionID,
                inputTargetEpoch: endpoint.inputTargetEpoch,
                endpointToken: endpoint.endpointToken
            )
        }
    }

    /// 展示快照（Local / Remote host display，非授权身份，§8）。
    var targetSnapshot: AgentTerminalMutationTargetSnapshot {
        switch self {
        case .local:
            return .local
        case .remote(let endpoint):
            return .remote(hostDisplay: endpoint.hostDisplayName)
        }
    }

    var logicalSessionID: UUID {
        targetIdentity.logicalSessionID
    }
}

// MARK: - 生产 resolver（最小 terminal/session integration）

/// 按 **origin sessionID** 解析一次 mutation endpoint capability。
///
/// 契约（对齐已验收的 `SessionManagerAgentRemoteServiceResolver`）：
/// - 只按显式 `sessionID` 查找；绝不依赖当前选中页 / 当前可见会话 /
///   任何全局指针（§13/§14）；
/// - Local 经 `LocalTerminalService.agentLocalTerminalMutationEndpoint()`
///   （accepted B2 capability），Remote 经 SessionManager 已验收的
///   `agentRemoteTerminalMutationEndpoint(forSessionID:)`（accepted B3
///   capability）——本类型只做取回，绝不构造、重定向或缓存 endpoint；
/// - 不可寻址（已关闭 / 断开 / PTY 退出 / shell 未 active）时返回 nil，
///   调用方收敛为结构化失败；绝不 fallback 其它会话或自动重连。
@MainActor
final class SessionManagerTerminalMutationEndpointResolver {
    private let sessionLookup: @MainActor (UUID) -> ManagedTerminalSession?
    private let remoteEndpointLookup: @MainActor (UUID) -> AgentRemoteTerminalMutationEndpoint?

    init(
        sessionLookup: @escaping @MainActor (UUID) -> ManagedTerminalSession?,
        remoteEndpointLookup: @escaping @MainActor (UUID) -> AgentRemoteTerminalMutationEndpoint?
    ) {
        self.sessionLookup = sessionLookup
        self.remoteEndpointLookup = remoteEndpointLookup
    }

    convenience init(sessionManager: SessionManager) {
        self.init(
            sessionLookup: { sessionID in
                sessionManager.session(withID: sessionID)
            },
            remoteEndpointLookup: { sessionID in
                sessionManager.agentRemoteTerminalMutationEndpoint(forSessionID: sessionID)
            }
        )
    }

    func endpointCapability(
        forSessionID sessionID: UUID
    ) async -> AgentTerminalMutationEndpointCapability? {
        guard let session = sessionLookup(sessionID), !session.isClosed else {
            return nil
        }
        switch session.kind {
        case .local:
            guard let service = session.localService else {
                return nil
            }
            guard let endpoint = await service.agentLocalTerminalMutationEndpoint() else {
                return nil
            }
            return .local(endpoint)
        case .remoteSSH:
            guard session.remoteService != nil else {
                return nil
            }
            guard let endpoint = remoteEndpointLookup(sessionID) else {
                return nil
            }
            return .remote(endpoint)
        }
    }
}
