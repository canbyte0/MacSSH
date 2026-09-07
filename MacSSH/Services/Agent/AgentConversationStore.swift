import Foundation
import Observation

/// MacSSH 1.1 Phase 10B：`[sessionID: AgentConversation]` 的 memory-only
/// 注册表（任务书 §7）。
///
/// - 不使用 SwiftData；App 重启不恢复。
/// - session 关闭时经 `removeConversation(for:)` 显式取消生成任务并移除
///   会话（任务书 §18 推荐显式 cleanup）；调用方为 AgentViewModel 的
///   `pruneConversations()`（composition，不侵入 SessionManager）。
@MainActor
@Observable
final class AgentConversationStore {
    private(set) var conversations: [UUID: AgentConversation] = [:]

    init() {}

    /// 获取（必要时创建）指定 session 的 conversation。
    /// 仅在事件回调（onAppear / onChange / send）中调用，不在 View body 中调用。
    func conversation(for sessionID: UUID) -> AgentConversation {
        if let existing = conversations[sessionID] {
            return existing
        }
        let conversation = AgentConversation(sessionID: sessionID)
        conversations[sessionID] = conversation
        return conversation
    }

    /// 只读访问（View body 安全，不创建）。
    func existingConversation(for sessionID: UUID) -> AgentConversation? {
        conversations[sessionID]
    }

    /// 移除指定 session 的 conversation（先取消生成任务）。
    func removeConversation(for sessionID: UUID) {
        conversations[sessionID]?.cancelGeneration()
        conversations[sessionID] = nil
    }

    /// 当前 conversation 数量（测试 / 诊断）。
    var count: Int {
        conversations.count
    }
}
