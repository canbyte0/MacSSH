import Foundation
import Observation

/// MacSSH 1.1 Phase 10B：单个 Terminal Session 的 Agent 会话（任务书 §7）。
///
/// 生命周期绑定 `ManagedTerminalSession.id`：
/// - 切换 tab 返回后 conversation 仍在；
/// - session 关闭后由 `AgentConversationStore.removeConversation(for:)`
///   显式移除（先取消生成任务）；
/// - App 重启不恢复（memory-only，不进 SwiftData）。
///
/// 生成任务 per-session 存储在 conversation 上（任务书 §16）：
/// 不同 Terminal session 的 generation 互不阻塞。
@MainActor
@Observable
final class AgentConversation {
    /// 绑定的 Terminal Session（UUID 即唯一 key）。
    let sessionID: UUID

    /// 全部消息（user / assistant / system，按时间顺序）。
    private(set) var messages: [AgentMessage] = []

    /// Composer 草稿（per-session，切 tab 互不干扰）。
    var draft = ""

    /// 当前是否有流式生成进行中（同一 session 同时只允许一个 generation）。
    private(set) var isGenerating = false

    /// 本会话的生成任务（结束路径统一经 endGeneration 清空）。
    private(set) var generationTask: Task<Void, Never>?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    var isEmpty: Bool {
        messages.isEmpty
    }

    // MARK: - 消息

    func append(_ message: AgentMessage) {
        messages.append(message)
    }

    /// 流式追加 chunk 到指定消息。
    func appendChunk(_ chunk: String, to messageID: UUID) {
        guard let index = indexOf(messageID) else { return }
        messages[index].content += chunk
    }

    /// 标记指定消息定稿。
    func completeMessage(_ messageID: UUID) {
        guard let index = indexOf(messageID) else { return }
        messages[index].state = .complete
    }

    /// 标记指定消息失败（保留 partial 内容，任务书 §22）；
    /// kind 驱动 UI 错误文案（任务书 §20）。
    func failMessage(_ messageID: UUID, kind: AgentFailureKind = .generic) {
        guard let index = indexOf(messageID) else { return }
        messages[index].state = .failed
        messages[index].failure = kind
    }

    /// 移除指定消息（用于停止时尚未产生任何内容的 assistant 占位——
    /// 空占位不属于"已生成的 partial content"）。
    func removeMessage(_ messageID: UUID) {
        messages.removeAll { $0.id == messageID }
    }

    private func indexOf(_ messageID: UUID) -> Int? {
        messages.firstIndex { $0.id == messageID }
    }

    // MARK: - 生成任务

    /// 登记生成任务并置 isGenerating。
    func beginGeneration(_ task: Task<Void, Never>) {
        generationTask = task
        isGenerating = true
    }

    /// 生成结束（完成 / 失败 / 取消），恢复可发送状态。
    func endGeneration() {
        generationTask = nil
        isGenerating = false
    }

    /// 取消进行中的生成任务（幂等；无任务时为空操作）。
    func cancelGeneration() {
        generationTask?.cancel()
    }
}
