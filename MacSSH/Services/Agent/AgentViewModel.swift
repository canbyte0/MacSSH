import Foundation
import Observation

/// MacSSH 1.1 Phase 10C：Agent Sidebar 视图模型（任务书 §8 / §15 / §17）。
///
/// 职责：当前 session 对应 conversation、draft、send / stop、provider 流式
/// 事件消费、结构化错误态（AgentFailureKind）、notConfigured 状态、
/// session 切换、closed session cleanup。
/// 不负责：HTTP / SSH / Tool Router（HTTP 全部在 Provider 层，任务书 §17）。
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

    /// Provider 配置就绪状态（任务书 §15）：notConfigured → Send disabled +
    /// 侧边栏「尚未配置 AI 服务」提示。由 View 在 appear / tab 切换时经
    /// refreshProviderConfiguration 刷新；Settings 保存 / 删除 Key 后也会刷新。
    private(set) var providerState: AgentProviderConfigurationState = .ready

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

    /// 当前是否可发送：Provider 已配置、有 session、当前 conversation
    /// 非生成中、草稿 trim 后非空（任务书 §15：未配置时 Send disabled）。
    var canSend: Bool {
        guard providerState == .ready else { return false }
        guard let conversation = activeConversation, !conversation.isGenerating else {
            return false
        }
        return !trimmedDraft(of: conversation).isEmpty
    }

    /// 刷新 Provider 配置就绪状态（Keychain 读取一次）。
    func refreshProviderConfiguration() async {
        providerState = await provider.configurationState()
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
        // Provider 未配置：不发起任何请求（任务书 §15；UI 已由 canSend
        // 禁用，此处为双保险——状态刷新存在窗口期）。
        guard providerState == .ready else { return }
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
        // provider 历史快照（任务书 §6）：完整多轮历史——含刚 append 的
        // user message，不含 streaming 占位与 failed 消息（partial 失败
        // 不是完整对话轮次）；禁止只发最后一条 user message。
        let history = conversation.messages.filter { $0.state != .failed }

        // assistant streaming 占位（任务书 §14 第 5 步）：
        // chunk 经 appendChunk 流式追加到该消息。
        conversation.append(
            AgentMessage(id: assistantID, role: .assistant, content: "", state: .streaming)
        )

        let provider = provider
        let task = Task { @MainActor [weak self] in
            do {
                let stream = provider.stream(messages: history, context: context)
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        conversation.appendChunk(delta, to: assistantID)
                    case .completed:
                        break
                    }
                }
                if Task.isCancelled {
                    self?.finishCancelled(conversation, assistantID: assistantID)
                } else {
                    conversation.completeMessage(assistantID)
                }
            } catch is CancellationError {
                self?.finishCancelled(conversation, assistantID: assistantID)
            } catch let error as AgentProviderError {
                if error == .cancelled {
                    self?.finishCancelled(conversation, assistantID: assistantID)
                } else {
                    // 结构化失败（401/429/网络等）：kind 驱动本地化文案，
                    // partial 内容保留（任务书 §20 / §22）。
                    conversation.failMessage(assistantID, kind: error.displayKind)
                }
            } catch {
                // 未知错误（含 mock /mock-error hook）：收敛为 generic 分类。
                conversation.failMessage(assistantID, kind: .generic)
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
