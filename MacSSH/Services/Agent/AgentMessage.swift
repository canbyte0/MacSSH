import Foundation

/// MacSSH 1.1 Phase 10B：Agent 会话中的单条消息（UI Shell 阶段，仅纯文本）。
///
/// 任务书 §6：`State` 只含 complete / streaming / failed；
/// toolCall / toolResult / approval 属于后续 Phase，本阶段禁止引入。
struct AgentMessage: Identifiable, Equatable, Sendable {
    /// 消息角色。
    enum Role: Equatable, Sendable {
        case user
        case assistant
        case system
    }

    /// 消息的渲染 / 生成状态。
    enum State: Equatable, Sendable {
        /// 内容已定稿。
        case complete
        /// 正在流式接收 chunk。
        case streaming
        /// 生成失败（content 可为 partial，保留不删除）。
        case failed
    }

    let id: UUID
    let role: Role
    var content: String
    var state: State
    /// 失败分类（仅 `.failed` 状态有意义；驱动 agent.provider.error.*
    /// 本地化文案，Phase 10C 任务书 §20）。
    var failure: AgentFailureKind?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        state: State = .complete,
        failure: AgentFailureKind? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.state = state
        self.failure = failure
    }
}
