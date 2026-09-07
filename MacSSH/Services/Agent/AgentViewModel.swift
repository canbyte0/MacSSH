import Foundation
import Observation

/// MacSSH 1.1 Phase 10B：Agent Sidebar 视图模型（任务书 §8）。
///
/// 职责：当前 session 对应 conversation、draft、send / stop、mock streaming、
/// error state、session 切换、closed session cleanup。
/// 不负责：HTTP / SSH / Tool Router / Keychain（后续 Phase）。
///
/// target 解析与 `TerminalCommandDispatcher` 同哲学：每次 action 实时读取
/// active session，不缓存 stale target。
@MainActor
@Observable
final class AgentViewModel {
    private let store: AgentConversationStore
    private let provider: AgentProvider

    /// 当前 active Terminal session 解析器（每次实时读取）。
    private let activeSessionProvider: @MainActor () -> ManagedTerminalSession?

    /// 全部 session 解析器（closed session cleanup 用）。
    private let allSessionsProvider: @MainActor () -> [ManagedTerminalSession]

    /// 无 session 时发送被阻止的提示标记（View 按 Locale 渲染文案；
    /// session 恢复或下一次成功 send 时清除）。
    var showsNoSessionNotice = false

    init(
        store: AgentConversationStore,
        provider: AgentProvider,
        activeSessionProvider: @escaping @MainActor () -> ManagedTerminalSession?,
        allSessionsProvider: @escaping @MainActor () -> [ManagedTerminalSession]
    ) {
        self.store = store
        self.provider = provider
        self.activeSessionProvider = activeSessionProvider
        self.allSessionsProvider = allSessionsProvider
    }

    // MARK: - Active session / context

    var currentSession: ManagedTerminalSession? {
        activeSessionProvider()
    }

    /// 当前 session 的展示级 context 快照（nil = 无可用 session）。
    var activeContext: AgentSessionContext? {
        guard let session = currentSession else { return nil }
        return Self.context(for: session)
    }

    /// 当前 conversation（只读访问，不创建；创建经 ensureConversationForActiveSession，
    /// 避免在 View body 中修改 observable 状态）。
    var activeConversation: AgentConversation? {
        guard let session = currentSession else { return nil }
        return store.existingConversation(for: session.id)
    }

    /// 打开 Agent tab / 切换 session 时确保 conversation 存在（事件回调中调用）。
    func ensureConversationForActiveSession() {
        guard let session = currentSession else { return }
        showsNoSessionNotice = false
        _ = store.conversation(for: session.id)
    }

    /// 当前是否可发送：有 session、当前 conversation 非生成中、草稿 trim 后非空。
    var canSend: Bool {
        guard let conversation = activeConversation, !conversation.isGenerating else {
            return false
        }
        return !trimmedDraft(of: conversation).isEmpty
    }

    // MARK: - Send（任务书 §14）

    /// 发送当前 active conversation 的 draft：
    /// trim → 空 / 生成中不发送 → append user message → 清空 draft →
    /// append streaming 占位 → 启动 provider stream 逐 chunk 追加。
    /// 绝不触碰 terminalView / Process / SSH。
    func send() {
        guard let session = currentSession else {
            // 无 session：不发送，显示 non-fatal UI message。
            showsNoSessionNotice = true
            return
        }
        let conversation = store.conversation(for: session.id)
        let text = trimmedDraft(of: conversation)
        guard !text.isEmpty else { return }
        // 同一 session 同时只允许一个 generation（任务书 §16）。
        guard !conversation.isGenerating else { return }

        showsNoSessionNotice = false
        conversation.draft = ""
        conversation.append(AgentMessage(role: .user, content: text))
        startGeneration(in: conversation, context: Self.context(for: session))
    }

    /// 停止当前 conversation 的生成（任务书 §15）：
    /// 立即取消 task；partial 内容保留；之后仍可发送新消息。
    func stop() {
        activeConversation?.cancelGeneration()
    }

    // MARK: - Closed session cleanup（任务书 §18，composition 方式）

    /// 移除已关闭 session 的 conversation（先取消生成任务）。
    /// 由 AgentSidebarView 在 appear / session 数变化 / active 切换时调用；
    /// Agent domain 不侵入 SessionManager。
    func pruneConversations() {
        let validIDs = Set(allSessionsProvider().map(\.id))
        for (sessionID, conversation) in store.conversations
        where !validIDs.contains(sessionID) {
            conversation.cancelGeneration()
            store.removeConversation(for: sessionID)
        }
    }

    // MARK: - 生成循环

    private func startGeneration(
        in conversation: AgentConversation,
        context: AgentSessionContext
    ) {
        let assistantID = UUID()
        // provider 历史快照：包含刚 append 的 user message，不含占位。
        let history = conversation.messages

        // assistant streaming 占位（任务书 §14 第 5 步）：
        // chunk 经 appendChunk 流式追加到该消息。
        conversation.append(
            AgentMessage(id: assistantID, role: .assistant, content: "", state: .streaming)
        )

        let provider = provider
        let task = Task { @MainActor [weak self] in
            do {
                let stream = provider.stream(messages: history, context: context)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    conversation.appendChunk(chunk, to: assistantID)
                }
                if Task.isCancelled {
                    self?.finishCancelled(conversation, assistantID: assistantID)
                } else {
                    conversation.completeMessage(assistantID)
                }
            } catch is CancellationError {
                self?.finishCancelled(conversation, assistantID: assistantID)
            } catch {
                // mock error hook / 未来 provider 错误：标记 failed（保留 partial）。
                conversation.failMessage(assistantID)
            }
            conversation.endGeneration()
        }
        conversation.beginGeneration(task)
    }

    /// 停止后的收尾（任务书 §15 hard gate）：
    /// - partial 内容保留并标记 complete；
    /// - 尚未产生任何内容的占位移除（空占位不是"已生成的 partial content"）。
    private func finishCancelled(
        _ conversation: AgentConversation,
        assistantID: UUID
    ) {
        if let message = conversation.messages.first(where: { $0.id == assistantID }) {
            if message.content.isEmpty {
                conversation.removeMessage(assistantID)
            } else {
                conversation.completeMessage(assistantID)
            }
        }
    }

    // MARK: - 工具

    private func trimmedDraft(of conversation: AgentConversation) -> String {
        conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 ManagedTerminalSession 提取展示级 context（任务书 §12 轻量字段）。
    static func context(for session: ManagedTerminalSession) -> AgentSessionContext {
        switch session.kind {
        case .local:
            return AgentSessionContext(
                sessionID: session.id,
                kind: .local,
                displayName: "Local",
                currentDirectory: session.localService?.session.currentDirectory
            )
        case .remoteSSH:
            return AgentSessionContext(
                sessionID: session.id,
                kind: .remoteSSH,
                displayName: session.hostDisplayName ?? session.hostname ?? "SSH",
                currentDirectory: session.remoteService?.session.currentDirectory
            )
        }
    }
}
