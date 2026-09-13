import Foundation

/// Remote exec 的 **session 解析器**：只按显式 `sessionID` 解析 origin Remote
/// session 的**已存在、已认证** `SSHConnection`。
///
/// 安全不变量（10E-B3 §11–§17）：
/// - 解析只接受 approved immutable request 的 `sessionID`（UUID 身份），
///   绝不使用 `displayName` / hostname 文本 / currently selected tab /
///   `activeSession` / 最近连接的主机做任何推断；
/// - 找不到（session 已关闭 / sessionID 未知）→ nil（executor 映射为
///   `sessionUnavailable`），**绝不**重连、绝不新建 TCP/SSH 认证、
///   绝不 fallback 到其它 session；
/// - 返回的连接必须已经在 `.connected` 状态：executor 只复用这条连接的
///   已认证 session，不读取任何凭据（Password / 私钥 / Passphrase / API key）。
///
/// 本类型是纯粹的「查找 + 返回」函数对象：production 装配把
/// `SessionManager` 的按 id 查找绑定进来（B4 接线点）；测试可注入任意
/// lookup 闭包（A/B session 隔离、陌生 sessionID、无连接场景）。
struct AgentRemoteCommandSessionResolver: Sendable {
    private let lookup: @Sendable (UUID) async -> SSHConnection?

    /// App-internal 构造（production 装配 / 测试注入）。
    init(lookup: @escaping @Sendable (UUID) async -> SSHConnection?) {
        self.lookup = lookup
    }

    /// 无任何 session 可解析（默认装配；绝不退化为「当前会话」）。
    static let unavailable = AgentRemoteCommandSessionResolver { _ in nil }

    /// 解析 origin session 的已认证连接；nil = 不可用（绝不 fallback）。
    func connection(forSessionID sessionID: UUID) async -> SSHConnection? {
        await lookup(sessionID)
    }
}

// MARK: - Production 装配（B4 接线点）

extension AgentRemoteCommandSessionResolver {
    /// 绑定 `SessionManager` 的**按 id 查找**（与 `TerminalAgentContextProvider`
    /// 同一查找语义）。
    ///
    /// 只接受同时满足以下条件的会话：
    /// - 存在且未被关闭；
    /// - `kind == .remoteSSH`（Local session 绝不当作 Remote target）；
    /// - `connectionInfo?.phase == .connected`（已认证的连接才可复用）；
    /// - 已挂接 `SSHConnection`。
    ///
    /// 本阶段（B3）不接入任何 Agent 生产路径——它是 B4 的唯一接线点。
    @MainActor
    static func live(sessionManager: SessionManager) -> AgentRemoteCommandSessionResolver {
        AgentRemoteCommandSessionResolver { sessionID in
            await MainActor.run {
                guard let session = sessionManager.session(withID: sessionID),
                      session.kind == .remoteSSH,
                      !session.isClosed,
                      session.connectionInfo?.phase == .connected,
                      let connection = session.connection
                else {
                    return nil
                }
                return connection
            }
        }
    }
}
