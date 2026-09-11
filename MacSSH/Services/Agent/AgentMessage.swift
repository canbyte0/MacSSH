import Foundation

/// MacSSH 1.1 Phase 10B/10D-B4：Agent 会话时间线中的单条消息。
///
/// B4 起消息内容为三种形态（§17/§49）：
/// - `.text`：user / assistant / system 文本（含流式 partial）；
/// - `.tool`：tool card（`AgentToolActivity`，UI 可见，§37–§41）；
/// - `.providerContinuation`：provider-scoped opaque item（reasoning 回放
///   载体，§22/§23：不渲染、不落盘、不解释）。
///
/// 三者共享同一有序数组，保证「assistant partial text → tool card →
/// continuation text」的最终顺序合理（§49）。
struct AgentMessage: Identifiable, Equatable, Sendable {
    /// 消息角色。`.tool` 供 UI 分发与 accessibility 使用。
    enum Role: Equatable, Sendable {
        case user
        case assistant
        case system
        case tool
    }

    /// 消息的渲染 / 生成状态（仅对 `.text` 有意义；`.tool` 的状态在
    /// `AgentToolActivity.status`，`.providerContinuation` 恒为 complete）。
    enum State: Equatable, Sendable {
        /// 内容已定稿。
        case complete
        /// 正在流式接收 chunk。
        case streaming
        /// 生成失败（content 可为 partial，保留不删除）。
        case failed
    }

    /// 消息内容（B4 起为枚举，见类型注释）。
    enum Content: Equatable, Sendable {
        case text(String)
        case tool(AgentToolActivity)
        case providerContinuation(AgentProviderContinuationItem)
    }

    let id: UUID
    let role: Role
    var content: Content
    var state: State
    /// 失败分类（仅 `.failed` 状态有意义；驱动 agent.provider.error.*
    /// 本地化文案）。
    var failure: AgentFailureKind?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        state: State = .complete,
        failure: AgentFailureKind? = nil
    ) {
        self.init(
            id: id,
            role: role,
            content: .text(content),
            state: state,
            failure: failure
        )
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: Content,
        state: State = .complete,
        failure: AgentFailureKind? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.state = state
        self.failure = failure
    }

    /// 文本内容访问器：非 `.text` 形态返回空串（供既有调用点与测试）。
    var text: String {
        if case .text(let value) = content {
            return value
        }
        return ""
    }

    /// Tool activity 访问器（非 `.tool` 返回 nil）。
    var toolActivity: AgentToolActivity? {
        if case .tool(let activity) = content {
            return activity
        }
        return nil
    }

    /// 是否进入 UI 渲染（§23：provider continuation item 绝不渲染——
    /// 它只是 reasoning 等 opaque 回放载体）。
    var isRenderable: Bool {
        if case .providerContinuation = content {
            return false
        }
        return true
    }
}
