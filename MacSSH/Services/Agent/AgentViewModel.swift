import Foundation
import Observation

/// MacSSH 1.1 Phase 10C / 10D-B4：Agent Sidebar 视图模型
/// （任务书 §8 / §15 / §17 / B4 §24–§28 / §42–§48 / §67）。
///
/// 职责：当前 session 对应 conversation、draft、send / stop、provider
/// 流式事件消费、tool loop（冻结 scope → provider → 串行执行 → 结果
/// 回填 → continuation）、结构化错误态（AgentFailureKind）、notConfigured
/// 状态、session 切换、closed session cleanup。
/// 不负责：HTTP / SSH（HTTP 全部在 Provider 层，§17）。
///
/// B4 generation 语义（§25/§48）：
/// - 每次 Send 创建 `generationID` + origin `sessionID` + 冻结
///   `AgentReadScope`，三者在整个 tool loop 内不变；
/// - 绝不每轮重新读取 activeSession、绝不重新扩大 readScope；
/// - 所有事件写入都经 generation identity guard，late provider events
///   绝不落入新 generation 或另一 session。
///
/// target 解析每次 action 都绑定 origin session，不缓存 stale target。
@MainActor
@Observable
final class AgentViewModel {
    /// B4 §26：tool round hard cap（一轮 provider response 中至少包含
    /// 一个 function call = 1 tool round；达到 10 后仍请求工具 → 终止）。
    static let maxToolRounds = 10

    private let store: AgentConversationStore
    private let provider: AgentProvider
    private let toolRouter: AgentToolRouter
    private let remoteServiceResolver: (any AgentRemoteReadOnlyServiceResolving)?
    /// B4 审批 authority：UI 只能通过下面的 façade 调用 approve/deny；
    /// executor 只能通过同一 actor 的 claim/redeem 消费授权。
    private let approvalCoordinator: AgentCommandApprovalCoordinator
    private let localCommandExecutor: AgentLocalCommandExecutor
    private let remoteCommandExecutor: AgentRemoteCommandExecutor

    /// 10F-B4-S1 mutation 审批 authority（B1 已验收状态机；UI façade 同上）。
    private let mutationApprovalCoordinator: AgentTerminalMutationApprovalCoordinator
    private let localMutationExecutor: AgentLocalTerminalMutationExecutor
    private let remoteMutationExecutor: AgentRemoteTerminalMutationExecutor

    /// 10F-C3 Local file write 的独立 one-time approval authority；不与
    /// command 或 interactive terminal mutation coordinator 混用。
    private let fileMutationApprovalCoordinator: AgentFileMutationApprovalCoordinator
    /// C2 executor 的构造 seam：production 只构造 accepted Local executor，
    /// focused loop tests 可注入相同 C2 语义的 deterministic executor。
    private let localFileMutationExecutorFactory:
        @Sendable (
            AgentFileMutationExecutionAuthorization,
            AgentLocalFileMutationTargetCapability,
            AgentFileMutationApprovalCoordinator
        ) -> AgentLocalFileMutationExecutor

    /// 按 origin sessionID 冻结一次 mutation endpoint capability
    /// （§13：proposal admission 时刻解析；§14：绝不延迟到 Approve /
    /// executor 启动，绝无 active-tab fallback）。nil = 未接线（测试默认），
    /// send_to_terminal 提案收敛为结构化 sessionUnavailable 失败。
    private let mutationEndpointProvider:
        (@MainActor (UUID) async -> AgentTerminalMutationEndpointCapability?)?

    /// cardID → proposal admission 时冻结的 endpoint capability。
    /// 生命周期与 pending mutation card 一致：proposal 建立时写入，
    /// 交付终态或 generation 收尾时清除（内存 only，绝不落盘）。
    private var pendingMutationEndpoints: [UUID: AgentTerminalMutationEndpointCapability] = [:]

    /// 当前 active Terminal session 解析器（每次实时读取）。
    private let activeSessionProvider: @MainActor () -> ManagedTerminalSession?

    /// 全部 session 解析器（closed session cleanup 用）。
    private let allSessionsProvider: @MainActor () -> [ManagedTerminalSession]

    /// generation 开始时构造会话句柄（cwd 快照 / buffer source 来源）。
    /// 默认 = 真实 `ManagedTerminalSession` 构造；测试可注入 fixture 句柄
    /// （与 `TerminalAgentContextProvider(handleLookup:)` 同一测试哲学）。
    private let handleProvider: @MainActor (ManagedTerminalSession) -> AgentTerminalSessionHandle

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
        toolRouter: AgentToolRouter,
        remoteServiceResolver: (any AgentRemoteReadOnlyServiceResolving)? = nil,
        approvalCoordinator: AgentCommandApprovalCoordinator = AgentCommandApprovalCoordinator(),
        localCommandExecutor: AgentLocalCommandExecutor = AgentLocalCommandExecutor(),
        remoteCommandExecutor: AgentRemoteCommandExecutor = AgentRemoteCommandExecutor(
            resolver: .unavailable
        ),
        mutationApprovalCoordinator: AgentTerminalMutationApprovalCoordinator = AgentTerminalMutationApprovalCoordinator(),
        localMutationExecutor: AgentLocalTerminalMutationExecutor? = nil,
        remoteMutationExecutor: AgentRemoteTerminalMutationExecutor? = nil,
        fileMutationApprovalCoordinator: AgentFileMutationApprovalCoordinator = AgentFileMutationApprovalCoordinator(),
        localFileMutationExecutorFactory: (@Sendable (
            AgentFileMutationExecutionAuthorization,
            AgentLocalFileMutationTargetCapability,
            AgentFileMutationApprovalCoordinator
        ) -> AgentLocalFileMutationExecutor)? = nil,
        mutationEndpointProvider: (@MainActor (UUID) async -> AgentTerminalMutationEndpointCapability?)? = nil,
        activeSessionProvider: @escaping @MainActor () -> ManagedTerminalSession?,
        allSessionsProvider: @escaping @MainActor () -> [ManagedTerminalSession],
        handleProvider: @escaping @MainActor (ManagedTerminalSession) -> AgentTerminalSessionHandle = {
            AgentTerminalSessionHandle(session: $0)
        }
    ) {
        self.store = store
        self.provider = provider
        self.toolRouter = toolRouter
        self.remoteServiceResolver = remoteServiceResolver
        self.approvalCoordinator = approvalCoordinator
        self.localCommandExecutor = localCommandExecutor
        self.remoteCommandExecutor = remoteCommandExecutor
        self.mutationApprovalCoordinator = mutationApprovalCoordinator
        // executor 必须与审批 authority 共享同一 coordinator（redeem 单次
        // 消费语义），默认自洽构造；测试可注入 deterministic executor。
        self.localMutationExecutor = localMutationExecutor
            ?? AgentLocalTerminalMutationExecutor(
                approvalCoordinator: mutationApprovalCoordinator
            )
        self.remoteMutationExecutor = remoteMutationExecutor
            ?? AgentRemoteTerminalMutationExecutor(
                approvalCoordinator: mutationApprovalCoordinator
            )
        self.fileMutationApprovalCoordinator = fileMutationApprovalCoordinator
        self.localFileMutationExecutorFactory = localFileMutationExecutorFactory
            ?? { authorization, targetCapability, approvalCoordinator in
                AgentLocalFileMutationExecutor(
                    authorization: authorization,
                    targetCapability: targetCapability,
                    approvalCoordinator: approvalCoordinator
                )
            }
        self.mutationEndpointProvider = mutationEndpointProvider
        self.activeSessionProvider = activeSessionProvider
        self.allSessionsProvider = allSessionsProvider
        self.handleProvider = handleProvider
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

    // MARK: - Send（任务书 §14 / B4 §24/§25）

    /// 发送当前 active conversation 的 draft：
    /// trim → 空 / 生成中不发送 → append user message → 清空 draft →
    /// 启动 generation（冻结 provider 快照 + readScope → tool loop）。
    /// 绝不触碰 terminalView / Process / SSH exec。
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
        startGeneration(in: conversation, session: session)
    }

    /// 停止当前 conversation 的生成（任务书 §15 / B4 §44）：
    /// 立即取消 task（传播到 provider 流、tool 执行、round 间 continuation）；
    /// partial 内容与 tool card 状态保留；之后仍可发送新消息。
    func stop() {
        guard let conversation = activeConversation,
              let generationID = conversation.generationID
        else { return }

        // 先取消 generation task，保证 Stop 与 claim/redeem/spawn 竞争时
        // generation 不能继续推进；随后由同一 coordinator actor 失效所有
        // pending approval，使旧卡的迟到 Approve 永远不能执行。
        // 10F §27/§39：pending terminal mutation 同样立即失效 → 0 字节。
        conversation.cancelGeneration()
        Task {
            _ = await approvalCoordinator.cancelGeneration(generationID)
            _ = await mutationApprovalCoordinator.cancelGeneration(generationID)
            _ = await fileMutationApprovalCoordinator.cancelGeneration(generationID)
        }
    }

    // MARK: - Approval façade（B4 UI 只经此处触碰 coordinator）

    /// UI Approve 只改变 coordinator 状态，绝不直接调用 executor。
    func approveCommand(cardID: UUID, sessionID: UUID) {
        guard let conversation = store.existingConversation(for: sessionID),
              let activity = conversation.messages.first(where: { $0.id == cardID })?.toolActivity,
              activity.status == .awaitingApproval,
              let approvalID = activity.approvalID
        else { return }

        // command 与 terminal mutation 共用 approvalID 字段但分属两个
        // coordinator：按工具名路由，绝不把 mutation approval 递给
        // command coordinator（反之亦然）。
        if activity.toolName == AgentToolName.sendToTerminal.rawValue {
            Task {
                _ = await mutationApprovalCoordinator.approve(approvalID)
            }
        } else if activity.toolName == AgentToolName.writeFile.rawValue {
            Task {
                _ = await fileMutationApprovalCoordinator.approve(approvalID)
            }
        } else {
            Task {
                _ = await approvalCoordinator.approve(approvalID)
            }
        }
    }

    /// UI Deny 只改变 coordinator 状态；`userDenied` tool result 由等待中的
    /// generation 统一写入，避免按钮路径伪造普通 user message。
    func denyCommand(cardID: UUID, sessionID: UUID) {
        guard let conversation = store.existingConversation(for: sessionID),
              let activity = conversation.messages.first(where: { $0.id == cardID })?.toolActivity,
              activity.status == .awaitingApproval,
              let approvalID = activity.approvalID
        else { return }

        if activity.toolName == AgentToolName.sendToTerminal.rawValue {
            Task {
                _ = await mutationApprovalCoordinator.deny(approvalID)
            }
        } else if activity.toolName == AgentToolName.writeFile.rawValue {
            Task {
                _ = await fileMutationApprovalCoordinator.deny(approvalID)
            }
        } else {
            Task {
                _ = await approvalCoordinator.deny(approvalID)
            }
        }
    }

    // MARK: - Closed session cleanup（任务书 §18，composition 方式）

    /// 移除已关闭 session 的 conversation（先取消生成任务）。
    /// 由 AgentSidebarView 在 appear / session 数变化 / active 切换时调用；
    /// Agent domain 不侵入 SessionManager。session close 同时失效并清理
    /// 审批记录，保证旧 UI 卡片无法影响后续 generation。
    func pruneConversations() {
        let validIDs = Set(allSessionsProvider().map(\.id))
        let approvalCoordinator = self.approvalCoordinator
        let mutationApprovalCoordinator = self.mutationApprovalCoordinator
        for (sessionID, conversation) in store.conversations
        where !validIDs.contains(sessionID) {
            conversation.cancelGeneration()
            Task {
                _ = await approvalCoordinator.cancelSession(sessionID)
                _ = await approvalCoordinator.purgeSession(sessionID)
                _ = await mutationApprovalCoordinator.cancelSession(sessionID)
                _ = await mutationApprovalCoordinator.purgeSession(sessionID)
                _ = await fileMutationApprovalCoordinator.cancelSession(sessionID)
                _ = await fileMutationApprovalCoordinator.purgeSession(sessionID)
            }
            // 该会话的 pending mutation endpoint 引用随 conversation 一起
            // 清理（endpoint 对象仍绑定旧 incarnation，其 admission 自会
            // 被 isAvailable 拒绝；这里只断开 ViewModel 的强引用）。
            dropPendingMutationEndpoints(forSessionID: sessionID)
            store.removeConversation(for: sessionID)
        }
    }

    /// 丢弃某 session 的冻结 endpoint 引用（不触碰 endpoint 对象本身）。
    private func dropPendingMutationEndpoints(forSessionID sessionID: UUID) {
        pendingMutationEndpoints = pendingMutationEndpoints.filter {
            $0.value.logicalSessionID != sessionID
        }
    }

    // MARK: - Generation（B4 §24–§28）

    /// 启动一次 generation：冻结身份与 scope，然后运行 tool loop。
    private func startGeneration(
        in conversation: AgentConversation,
        session: ManagedTerminalSession
    ) {
        let generationID = UUID()
        let sessionID = session.id
        let context = Self.context(for: session)
        // §25：origin session 的 cwd 快照（scope / 相对路径基准的唯一来源）。
        let handle = handleProvider(session)
        // providerSnapshotID 在 generation 创建时生成，并贯穿所有 command
        // request；Settings / Keychain 的变化不会改变这个 opaque identity。
        let providerSnapshotID = UUID()

        // 第一轮 assistant streaming 占位在 send 的同步路径创建
        // （Phase 10B/10C 已验收行为：send 返回即可见 user + placeholder）。
        let firstAssistantID = UUID()
        conversation.append(
            AgentMessage(
                id: firstAssistantID,
                role: .assistant,
                content: "",
                state: .streaming
            )
        )

        let provider = self.provider
        let toolRouter = self.toolRouter
        let remoteServiceResolver = self.remoteServiceResolver
        let approvalCoordinator = self.approvalCoordinator
        let localCommandExecutor = self.localCommandExecutor
        let remoteCommandExecutor = self.remoteCommandExecutor
        let mutationApprovalCoordinator = self.mutationApprovalCoordinator
        let localMutationExecutor = self.localMutationExecutor
        let remoteMutationExecutor = self.remoteMutationExecutor
        let fileMutationApprovalCoordinator = self.fileMutationApprovalCoordinator
        let localFileMutationExecutorFactory = self.localFileMutationExecutorFactory
        let mutationEndpointProvider = self.mutationEndpointProvider

        let task = Task { @MainActor [weak self] in
            // §54/§55：generation 级 provider 快照——整个 tool loop 的
            // 每一轮 continuation 都使用同一实例（凭据 / model / baseURL
            // 冻结；中途改 Settings 只影响下一次 Send）。
            let generationProvider: any AgentProvider
            do {
                generationProvider = try await provider.snapshotForGeneration()
            } catch let error as AgentProviderError {
                self?.failGeneration(
                    conversation,
                    assistantID: firstAssistantID,
                    kind: error.displayKind
                )
                conversation.endGeneration()
                return
            } catch {
                self?.failGeneration(
                    conversation,
                    assistantID: firstAssistantID,
                    kind: .generic
                )
                conversation.endGeneration()
                return
            }

            // §34：generation 开始时构建 readScope；Remote 经服务端
            // canonicalization（§85：唯一允许的 generation-start 文件
            // 系统操作，绝不预取内容）。§35：失败 → 空 roots，工具随后
            // 安全拒绝。
            let readScope = await Self.freezeReadScope(
                sessionID: sessionID,
                sessionKind: handle.sessionKind,
                workingDirectory: handle.workingDirectory,
                remoteServiceResolver: remoteServiceResolver
            )

            if Task.isCancelled {
                self?.finishCancelled(conversation, assistantID: firstAssistantID)
                conversation.endGeneration()
                return
            }

            await self?.runToolLoop(
                conversation: conversation,
                generationID: generationID,
                sessionID: sessionID,
                context: context,
                readScope: readScope,
                frozenHandle: handle,
                providerSnapshotID: providerSnapshotID,
                generationProvider: generationProvider,
                approvalCoordinator: approvalCoordinator,
                localCommandExecutor: localCommandExecutor,
                remoteCommandExecutor: remoteCommandExecutor,
                mutationApprovalCoordinator: mutationApprovalCoordinator,
                localMutationExecutor: localMutationExecutor,
                remoteMutationExecutor: remoteMutationExecutor,
                fileMutationApprovalCoordinator: fileMutationApprovalCoordinator,
                localFileMutationExecutorFactory: localFileMutationExecutorFactory,
                mutationEndpointProvider: mutationEndpointProvider,
                toolRouter: toolRouter,
                firstAssistantID: firstAssistantID
            )
        }
        conversation.beginGeneration(task, generationID: generationID)
    }

    /// 单次 generation 的 tool loop（§24/§26/§27/§44–§48）。
    ///
    /// 每轮：provider → 组装事件（text / toolCall / opaque item）→
    /// 串行执行本轮全部 calls（§27：按 output order，执行完全部后再
    /// 一次性 continuation）→ 下一轮。任意阶段取消都安全收尾。
    private func runToolLoop(
        conversation: AgentConversation,
        generationID: UUID,
        sessionID: UUID,
        context: AgentSessionContext,
        readScope: AgentReadScope,
        frozenHandle: AgentTerminalSessionHandle,
        providerSnapshotID: UUID,
        generationProvider: any AgentProvider,
        approvalCoordinator: AgentCommandApprovalCoordinator,
        localCommandExecutor: AgentLocalCommandExecutor,
        remoteCommandExecutor: AgentRemoteCommandExecutor,
        mutationApprovalCoordinator: AgentTerminalMutationApprovalCoordinator,
        localMutationExecutor: AgentLocalTerminalMutationExecutor,
        remoteMutationExecutor: AgentRemoteTerminalMutationExecutor,
        fileMutationApprovalCoordinator: AgentFileMutationApprovalCoordinator,
        localFileMutationExecutorFactory: @Sendable (
            AgentFileMutationExecutionAuthorization,
            AgentLocalFileMutationTargetCapability,
            AgentFileMutationApprovalCoordinator
        ) -> AgentLocalFileMutationExecutor,
        mutationEndpointProvider: (@MainActor (UUID) async -> AgentTerminalMutationEndpointCapability?)?,
        toolRouter: AgentToolRouter,
        firstAssistantID: UUID
    ) async {
        var toolRoundCount = 0
        var nextAssistantID: UUID? = firstAssistantID

        while true {
            // identity guard（§48）：generation 已被替换 / 清理时立即停止，
            // 绝不写入其它 generation。
            guard conversation.generationID == generationID else { return }

            // transcript 快照（§19：每轮完整本地重建）：包含此前所有
            // 轮次的文本 / tool 条目 / opaque item；本轮 empty streaming
            // 占位绝不进入请求（Phase 10B/10C 已验收语义）。
            let assistantID: UUID
            let transcript: [AgentMessage]
            if let provided = nextAssistantID {
                // 首轮占位已在 send 的同步路径创建（行为契约）。
                assistantID = provided
                nextAssistantID = nil
                transcript = conversation.messages.filter {
                    $0.id != assistantID && $0.state != .failed
                }
            } else {
                // 后续轮次 placeholder（§49：text → tool card →
                // continuation text 的顺序合理）。
                assistantID = UUID()
                // failed 文本消息不是完整轮次（Phase 10B/10C 已验收语义）。
                transcript = conversation.messages.filter { $0.state != .failed }
                conversation.append(
                    AgentMessage(id: assistantID, role: .assistant, content: "", state: .streaming)
                )
            }
            // 完整 call 到达后立即按 Provider output order 建立 card；
            // run_command 的 helper 会先完成 validate/build/register，再发布
            // awaitingApproval card，保证 card 永远先于 executor side effect。
            var pending: [PendingToolCall] = []

            do {
                let stream = generationProvider.stream(
                    transcript: transcript,
                    tools: AgentToolCatalog.definitions,
                    context: context
                )
                for try await event in stream {
                    try Task.checkCancellation()
                    guard conversation.generationID == generationID else { return }
                    switch event {
                    case .textDelta(let delta):
                        conversation.appendChunk(delta, to: assistantID)
                    case .toolCall(let call):
                        let cardID = await appendToolCardForProviderCall(
                            call,
                            generationID: generationID,
                            sessionID: sessionID,
                            frozenHandle: frozenHandle,
                            providerSnapshotID: providerSnapshotID,
                            generationProvider: generationProvider,
                            approvalCoordinator: approvalCoordinator,
                            mutationApprovalCoordinator: mutationApprovalCoordinator,
                            fileMutationApprovalCoordinator: fileMutationApprovalCoordinator,
                            mutationEndpointProvider: mutationEndpointProvider,
                            conversation: conversation
                        )
                        pending.append(PendingToolCall(call: call, cardID: cardID))
                    case .providerItem(let item):
                        // §22/§23：opaque 存储（不渲染 / 不日志 / 不解释），
                        // 供后续轮次按 provider scope 回放。
                        conversation.append(
                            AgentMessage(role: .assistant, content: .providerContinuation(item))
                        )
                    case .completed:
                        break
                    }
                }

                // 本轮 placeholder 收尾（§49）：有 text → 定稿；纯 tool
                // 轮次的空占位移除（tool card 直接展示）。
                let hasText = !(conversation.text(of: assistantID) ?? "").isEmpty
                if pending.isEmpty || hasText {
                    conversation.completeMessage(assistantID)
                } else {
                    conversation.removeMessage(assistantID)
                }

                // §67：0 tool call → 正常回答，generation 结束。
                guard !pending.isEmpty else {
                    conversation.endGeneration()
                    return
                }

                // §26 hard cap：第 11 个 tool round 终止 generation。
                toolRoundCount += 1
                if toolRoundCount > Self.maxToolRounds {
                    cancelRunningToolCards(in: conversation)
                    failGeneration(
                        conversation,
                        assistantID: assistantID,
                        kind: .toolRoundLimit
                    )
                    conversation.endGeneration()
                    return
                }

                // §27：按 provider output order 串行执行本轮全部 calls；
                // 执行完所有 calls 后才进入 continuation。
                for item in pending {
                    // §45：Stop 在「function call 已返回、Router 执行前」
                    // 到达 → 绝不执行 tool。
                    try Task.checkCancellation()
                    let outcome = try await executeTool(
                        item.call,
                        generationID: generationID,
                        cardID: item.cardID,
                        sessionID: sessionID,
                        readScope: readScope,
                        providerSnapshotID: providerSnapshotID,
                        approvalCoordinator: approvalCoordinator,
                        localCommandExecutor: localCommandExecutor,
                        remoteCommandExecutor: remoteCommandExecutor,
                        mutationApprovalCoordinator: mutationApprovalCoordinator,
                        localMutationExecutor: localMutationExecutor,
                        remoteMutationExecutor: remoteMutationExecutor,
                        fileMutationApprovalCoordinator: fileMutationApprovalCoordinator,
                        localFileMutationExecutorFactory: localFileMutationExecutorFactory,
                        toolRouter: toolRouter,
                        conversation: conversation
                    )
                    if outcome == .fatalSessionUnavailable {
                        // §28/§43：会话不可用属于「无法继续」——安全收尾，
                        // 绝不改去其它 session。
                        cancelRunningToolCards(in: conversation)
                        failGeneration(
                            conversation,
                            assistantID: assistantID,
                            kind: .sessionUnavailable
                        )
                        conversation.endGeneration()
                        return
                    }
                    if outcome == .fatalMutationUncertain {
                        // 10F-B4-S1 §29：partial / uncertain 交付结果绝不
                        // 在同一 generation 内自动续 Provider——停止 loop，
                        // surface 用户可见交付状态（card 已是 partial）。
                        cancelRunningToolCards(in: conversation)
                        failGeneration(
                            conversation,
                            assistantID: assistantID,
                            kind: .terminalMutationUncertain
                        )
                        conversation.endGeneration()
                        return
                    }
                }

                // §47 hard race：tool 全部完成、continuation 即将发起的
                // 窗口内 Stop → 绝不发送下一轮 provider request。
                try Task.checkCancellation()
            } catch is CancellationError {
                cancelRunningToolCards(in: conversation)
                finishCancelled(conversation, assistantID: assistantID)
                conversation.endGeneration()
                return
            } catch let error as AgentProviderError {
                if error == .cancelled {
                    cancelRunningToolCards(in: conversation)
                    finishCancelled(conversation, assistantID: assistantID)
                    conversation.endGeneration()
                    return
                }
                // §49：provider 失败时 partial text 保留（failMessage 语义），
                // 未执行的 tool card 收敛为 cancelled。
                cancelRunningToolCards(in: conversation)
                failGeneration(
                    conversation,
                    assistantID: assistantID,
                    kind: error.displayKind
                )
                conversation.endGeneration()
                return
            } catch {
                cancelRunningToolCards(in: conversation)
                failGeneration(conversation, assistantID: assistantID, kind: .generic)
                conversation.endGeneration()
                return
            }

            // 继续下一轮：transcript 已包含本轮 tool card 的结果（§27）。
        }
    }

    private struct PendingToolCall: Sendable {
        let call: AgentProviderToolCall
        let cardID: UUID
    }

    /// Provider call 到达时建立卡片。run_command / send_to_terminal /
    /// write_file 严格
    /// 执行：validate → immutable request → register → visible card；
    /// read-only call 则立即发布 running card，保持原有 streaming/Stop
    /// 可观察性。
    private func appendToolCardForProviderCall(
        _ providerCall: AgentProviderToolCall,
        generationID: UUID,
        sessionID: UUID,
        frozenHandle: AgentTerminalSessionHandle,
        providerSnapshotID: UUID,
        generationProvider: any AgentProvider,
        approvalCoordinator: AgentCommandApprovalCoordinator,
        mutationApprovalCoordinator: AgentTerminalMutationApprovalCoordinator,
        fileMutationApprovalCoordinator: AgentFileMutationApprovalCoordinator,
        mutationEndpointProvider: (@MainActor (UUID) async -> AgentTerminalMutationEndpointCapability?)?,
        conversation: AgentConversation
    ) async -> UUID {
        if providerCall.name == AgentToolName.sendToTerminal.rawValue {
            return await appendTerminalMutationCard(
                providerCall,
                generationID: generationID,
                sessionID: sessionID,
                providerSnapshotID: providerSnapshotID,
                generationProvider: generationProvider,
                mutationApprovalCoordinator: mutationApprovalCoordinator,
                mutationEndpointProvider: mutationEndpointProvider,
                conversation: conversation
            )
        }

        if providerCall.name == AgentToolName.writeFile.rawValue {
            return await appendFileMutationCard(
                providerCall,
                generationID: generationID,
                sessionID: sessionID,
                frozenHandle: frozenHandle,
                providerSnapshotID: providerSnapshotID,
                generationProvider: generationProvider,
                fileMutationApprovalCoordinator: fileMutationApprovalCoordinator,
                conversation: conversation
            )
        }

        guard providerCall.name == AgentToolName.runCommand.rawValue else {
            return appendToolCard(
                AgentToolActivity(runningFrom: providerCall),
                to: conversation
            )
        }

        let parsed: AgentToolCall
        switch AgentToolCallParsing.parse(
            name: providerCall.name,
            argumentsJSON: providerCall.argumentsJSON
        ) {
        case .failure(let error):
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                to: conversation
            )
        case .success(let value):
            parsed = value
        }

        guard let command = parsed.command else {
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(
                    error: AgentToolError.invalidArguments
                ),
                to: conversation
            )
        }

        let metadata = generationProvider.commandProviderMetadata
        let providerBinding = AgentCommandProviderBinding(
            snapshotID: providerSnapshotID,
            provider: metadata.provider,
            model: metadata.model,
            baseURL: metadata.baseURL
        )
        let target: AgentCommandTarget
        switch frozenHandle.sessionKind {
        case .local:
            target = .local(displayName: frozenHandle.displayName)
        case .remoteSSH:
            target = .remote(displayName: frozenHandle.displayName)
        }

        switch AgentCommandRequestFactory.make(
            generationID: generationID,
            callID: providerCall.callID,
            sessionID: sessionID,
            target: target,
            command: command,
            workingDirectory: frozenHandle.workingDirectory,
            providerBinding: providerBinding
        ) {
        case .failure(let error):
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                to: conversation
            )
        case .success(let request):
            let approvalID = await approvalCoordinator.register(request)
            let activity = AgentToolActivity(
                callID: providerCall.callID,
                toolName: providerCall.name,
                argumentsJSON: providerCall.argumentsJSON,
                displayTarget: nil,
                approvalID: approvalID,
                commandRequest: request,
                status: .awaitingApproval
            )
            return appendToolCard(activity, to: conversation)
        }
    }

    /// 10F-B4-S1 send_to_terminal proposal（§12/§13/§16）：
    /// parse → **admission 时刻冻结 endpoint capability**（§13：绝不延迟到
    /// Approve / executor 启动 / loop resume）→ immutable request →
    /// register → awaitingApproval card。任何一步失败都发布零副作用失败
    /// 卡片，绝不触碰 executor / 终端字节。
    private func appendTerminalMutationCard(
        _ providerCall: AgentProviderToolCall,
        generationID: UUID,
        sessionID: UUID,
        providerSnapshotID: UUID,
        generationProvider: any AgentProvider,
        mutationApprovalCoordinator: AgentTerminalMutationApprovalCoordinator,
        mutationEndpointProvider: (@MainActor (UUID) async -> AgentTerminalMutationEndpointCapability?)?,
        conversation: AgentConversation
    ) async -> UUID {
        let parsed: AgentToolCall
        switch AgentToolCallParsing.parse(
            name: providerCall.name,
            argumentsJSON: providerCall.argumentsJSON
        ) {
        case .failure(let error):
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                to: conversation
            )
        case .success(let value):
            parsed = value
        }

        guard let arguments = parsed.terminalMutation else {
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(
                    error: AgentToolError.invalidArguments
                ),
                to: conversation
            )
        }

        // Endpoint snapshot at admission：按 origin sessionID 解析一次，
        // 之后整条链固定使用该 capability（绝无 active-tab fallback）。
        guard let capability = await mutationEndpointProvider?(sessionID) else {
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(
                    error: AgentToolError.sessionUnavailable
                ),
                to: conversation
            )
        }

        let metadata = generationProvider.commandProviderMetadata
        let providerBinding = AgentCommandProviderBinding(
            snapshotID: providerSnapshotID,
            provider: metadata.provider,
            model: metadata.model,
            baseURL: metadata.baseURL
        )

        switch AgentTerminalMutationRequestFactory.make(
            generationID: generationID,
            callID: providerCall.callID,
            logicalSessionID: capability.logicalSessionID,
            targetIdentity: capability.targetIdentity,
            targetSnapshot: capability.targetSnapshot,
            text: arguments.text,
            submit: arguments.submit,
            providerBinding: providerBinding,
            createdAt: Date()
        ) {
        case .failure(let error):
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                to: conversation
            )
        case .success(let request):
            let approvalID = await mutationApprovalCoordinator.register(request)
            let activity = AgentToolActivity(
                callID: providerCall.callID,
                toolName: providerCall.name,
                argumentsJSON: providerCall.argumentsJSON,
                displayTarget: nil,
                approvalID: approvalID,
                mutationRequest: request,
                status: .awaitingApproval
            )
            let cardID = appendToolCard(activity, to: conversation)
            pendingMutationEndpoints[cardID] = capability
            return cardID
        }
    }

    /// 10F-C3 write_file proposal（§14–§18）：仅允许 Local；在 card 可见
    /// 前完成严格 parse、proposal-time write scope / parent capability 捕获、
    /// exact payload freeze 与 file approval 登记。任何失败都只生成零副作用
    /// 的结构化失败 card，不会触碰 C2 executor。
    private func appendFileMutationCard(
        _ providerCall: AgentProviderToolCall,
        generationID: UUID,
        sessionID: UUID,
        frozenHandle: AgentTerminalSessionHandle,
        providerSnapshotID: UUID,
        generationProvider: any AgentProvider,
        fileMutationApprovalCoordinator: AgentFileMutationApprovalCoordinator,
        conversation: AgentConversation
    ) async -> UUID {
        let parsed: AgentToolCall
        switch AgentToolCallParsing.parse(
            name: providerCall.name,
            argumentsJSON: providerCall.argumentsJSON
        ) {
        case .failure(let error):
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                to: conversation
            )
        case .success(let value):
            parsed = value
        }

        guard frozenHandle.sessionKind == .local else {
            // C3 是 Local-only；绝不把同一个 Provider path 降级到 SFTP、
            // SSH exec 或 Remote terminal。
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(
                    error: AgentToolError.unsupportedForSession
                ),
                to: conversation
            )
        }

        guard let path = parsed.path, let content = parsed.content else {
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(
                    error: AgentToolError.invalidArguments
                ),
                to: conversation
            )
        }

        let providerMetadata = generationProvider.commandProviderMetadata
        let providerBinding = AgentCommandProviderBinding(
            snapshotID: providerSnapshotID,
            provider: providerMetadata.provider,
            model: providerMetadata.model,
            baseURL: providerMetadata.baseURL
        )

        let writeScope: AgentWriteScope
        switch AgentWriteScope.make(
            logicalSessionID: sessionID,
            workingDirectory: frozenHandle.workingDirectory
        ) {
        case .failure(let error):
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                to: conversation
            )
        case .success(let value):
            writeScope = value
        }

        let proposal = await AgentFileMutationRequestFactory.make(
            generationID: generationID,
            callID: providerCall.callID,
            logicalSessionID: sessionID,
            writeScope: writeScope,
            userSuppliedPath: path,
            content: content,
            providerBinding: providerBinding,
            createdAt: Date()
        )

        let request: AgentFileMutationRequest
        switch proposal {
        case .failure(let error):
            return appendFailedToolCard(
                providerCall,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                to: conversation
            )
        case .success(let value):
            request = value
        }

        let approvalID = await fileMutationApprovalCoordinator.register(request)
        // register 对同一 generation/call 是幂等的；重放时沿用第一次
        // proposal 的 immutable request，不能让第二次 Provider 参数替换
        // target/payload 或获得新的 parent capability。
        let recordedRequest = await fileMutationApprovalCoordinator
            .snapshot(approvalID: approvalID)?.request ?? request
        if recordedRequest.parentCapability !== request.parentCapability {
            // 第二次 proposal 可能已经捕获了一个新的 parent FD；它没有
            // 进入 authoritative ledger，必须立即关闭，避免 replay 泄漏。
            _ = await request.parentCapability.invalidate()
        }
        let activity = AgentToolActivity(
            callID: providerCall.callID,
            toolName: providerCall.name,
            argumentsJSON: providerCall.argumentsJSON,
            displayTarget: recordedRequest.displayPath,
            approvalID: approvalID,
            fileMutationRequest: recordedRequest,
            status: .awaitingApproval
        )
        return appendToolCard(activity, to: conversation)
    }

    /// 零副作用失败卡片（结构化 tool error；call_id 配对恒成立）。
    private func appendFailedToolCard(
        _ providerCall: AgentProviderToolCall,
        resultJSON: String,
        to conversation: AgentConversation
    ) -> UUID {
        let cardID = appendToolCard(
            AgentToolActivity(runningFrom: providerCall),
            to: conversation
        )
        conversation.updateToolActivity(
            cardID,
            status: .failure,
            resultJSON: resultJSON,
            isError: true
        )
        return cardID
    }

    /// 执行单个 tool call；卡片已由 `appendToolCardForProviderCall` 发布。
    private func executeTool(
        _ providerCall: AgentProviderToolCall,
        generationID: UUID,
        cardID: UUID,
        sessionID: UUID,
        readScope: AgentReadScope,
        providerSnapshotID: UUID,
        approvalCoordinator: AgentCommandApprovalCoordinator,
        localCommandExecutor: AgentLocalCommandExecutor,
        remoteCommandExecutor: AgentRemoteCommandExecutor,
        mutationApprovalCoordinator: AgentTerminalMutationApprovalCoordinator,
        localMutationExecutor: AgentLocalTerminalMutationExecutor,
        remoteMutationExecutor: AgentRemoteTerminalMutationExecutor,
        fileMutationApprovalCoordinator: AgentFileMutationApprovalCoordinator,
        localFileMutationExecutorFactory: @Sendable (
            AgentFileMutationExecutionAuthorization,
            AgentLocalFileMutationTargetCapability,
            AgentFileMutationApprovalCoordinator
        ) -> AgentLocalFileMutationExecutor,
        toolRouter: AgentToolRouter,
        conversation: AgentConversation
    ) async throws -> ToolExecutionOutcome {
        // §6：raw JSON → typed arguments → validate。未知工具 / 非法参数在
        // 这里收敛为结构化 tool error，绝不执行、绝不猜测（§51）。
        let parsedCall: AgentToolCall
        switch AgentToolCallParsing.parse(
            name: providerCall.name,
            argumentsJSON: providerCall.argumentsJSON
        ) {
        case .failure(let error):
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return .completed
        case .success(let call):
            parsedCall = call
        }

        if parsedCall.name == AgentToolName.writeFile.rawValue {
            guard
                let activity = conversation.messages.first(where: { $0.id == cardID })?.toolActivity,
                let approvalID = activity.approvalID,
                let request = activity.fileMutationRequest
            else {
                // 参数或 proposal admission 已失败；此处是防御性 no-op。
                return .completed
            }
            return try await executeWriteFile(
                cardID: cardID,
                approvalID: approvalID,
                request: request,
                generationID: generationID,
                sessionID: sessionID,
                providerSnapshotID: providerSnapshotID,
                fileMutationApprovalCoordinator: fileMutationApprovalCoordinator,
                localFileMutationExecutorFactory: localFileMutationExecutorFactory,
                conversation: conversation
            )
        }

        if parsedCall.name == AgentToolName.sendToTerminal.rawValue {
            guard
                let activity = conversation.messages.first(where: { $0.id == cardID })?.toolActivity,
                let approvalID = activity.approvalID,
                let request = activity.mutationRequest
            else {
                // 参数 / endpoint 在 card 创建阶段已失败；防御性 no-op。
                return .completed
            }
            return try await executeSendToTerminal(
                cardID: cardID,
                approvalID: approvalID,
                request: request,
                generationID: generationID,
                sessionID: sessionID,
                providerSnapshotID: providerSnapshotID,
                mutationApprovalCoordinator: mutationApprovalCoordinator,
                localMutationExecutor: localMutationExecutor,
                remoteMutationExecutor: remoteMutationExecutor,
                conversation: conversation
            )
        }

        if parsedCall.name == AgentToolName.runCommand.rawValue {
            guard
                let activity = conversation.messages.first(where: { $0.id == cardID })?.toolActivity,
                let approvalID = activity.approvalID,
                let request = activity.commandRequest
            else {
                // 参数或 cwd 在 card 创建阶段已失败；这里是防御性 no-op。
                return .completed
            }
            return try await executeRunCommand(
                cardID: cardID,
                approvalID: approvalID,
                request: request,
                generationID: generationID,
                sessionID: sessionID,
                providerSnapshotID: providerSnapshotID,
                approvalCoordinator: approvalCoordinator,
                localCommandExecutor: localCommandExecutor,
                remoteCommandExecutor: remoteCommandExecutor,
                conversation: conversation
            )
        }

        let result = await toolRouter.execute(
            call: parsedCall,
            sessionID: sessionID,
            readScope: readScope
        )
        switch result {
        case .success(let toolResult):
            conversation.updateToolActivity(
                cardID,
                status: .success,
                resultJSON: AgentToolResultSerializer.serialize(toolResult),
                isError: false
            )
            return .completed
        case .failure(.cancelled):
            // §46：Stop during tool → 传播取消，绝不转成普通失败。
            conversation.updateToolActivity(
                cardID,
                status: .cancelled,
                resultJSON: AgentToolResultSerializer.cancelledOutput,
                isError: true
            )
            throw CancellationError()
        case .failure(.sessionUnavailable):
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: AgentToolError.sessionUnavailable),
                isError: true
            )
            return .fatalSessionUnavailable
        case .failure(let error):
            // §28：普通 tool error 是 result，模型可以解释并继续。
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return .completed
        }
    }

    /// 10F-C3 write_file 执行闭环：等待显式决定 → C1 原子 claim →
    /// accepted C2 Local executor → sanitized publication result。只有
    /// C2 executor 可以触碰 filesystem；本方法不重取 path/content，也不
    /// 把 published + cleanupResidue 误报为失败或触发重试。
    private func executeWriteFile(
        cardID: UUID,
        approvalID: UUID,
        request: AgentFileMutationRequest,
        generationID: UUID,
        sessionID: UUID,
        providerSnapshotID: UUID,
        fileMutationApprovalCoordinator: AgentFileMutationApprovalCoordinator,
        localFileMutationExecutorFactory: @Sendable (
            AgentFileMutationExecutionAuthorization,
            AgentLocalFileMutationTargetCapability,
            AgentFileMutationApprovalCoordinator
        ) -> AgentLocalFileMutationExecutor,
        conversation: AgentConversation
    ) async throws -> ToolExecutionOutcome {
        do {
            let decision = try await fileMutationApprovalCoordinator.awaitDecision(
                approvalID: approvalID
            )
            switch decision {
            case .denied:
                // Deny 已由 coordinator 失效 capability；再次 invalidate
                // 是幂等的防御性收尾，仍然不产生任何 filesystem mutation。
                _ = await request.parentCapability.invalidate()
                conversation.updateToolActivity(
                    cardID,
                    status: .denied,
                    resultJSON: AgentToolResultSerializer.userDeniedOutput,
                    isError: true
                )
                return .completed
            case .cancelled:
                _ = await request.parentCapability.invalidate()
                conversation.updateToolActivity(
                    cardID,
                    status: .cancelled,
                    resultJSON: AgentToolResultSerializer.cancelledOutput,
                    isError: true
                )
                throw CancellationError()
            case .approved:
                // Stop 与 Approve 的竞争在 claim 前再检查一次；取消不能
                // 通过 stale UI card 进入 C2。
                try Task.checkCancellation()
            }

            let authorization: AgentFileMutationExecutionAuthorization
            do {
                authorization = try await fileMutationApprovalCoordinator.claimExecution(
                    approvalID: approvalID,
                    expected: AgentFileMutationClaimExpectations(
                        generationID: generationID,
                        callID: request.callID,
                        logicalSessionID: sessionID,
                        providerSnapshotID: providerSnapshotID,
                        targetIdentity: request.targetIdentity
                    )
                )
            } catch let error as AgentFileMutationError {
                _ = await request.parentCapability.invalidate()
                if error == .generationCancelled {
                    conversation.updateToolActivity(
                        cardID,
                        status: .cancelled,
                        resultJSON: AgentToolResultSerializer.cancelledOutput,
                        isError: true
                    )
                    throw CancellationError()
                }
                conversation.updateToolActivity(
                    cardID,
                    status: .failure,
                    resultJSON: AgentToolResultSerializer.serialize(error: error),
                    isError: true
                )
                return .completed
            }

            let executionCapability = authorization.request.parentCapability
            // claim 成功即代表已获唯一授权；先发布 running，再让 C2
            // executor 观察 redeem。此后不再出现第二个 Approve/Deny 窗口。
            conversation.updateToolActivity(
                cardID,
                status: .running,
                resultJSON: "",
                isError: false
            )

            let executor = localFileMutationExecutorFactory(
                authorization,
                executionCapability,
                fileMutationApprovalCoordinator
            )
            let result = await executor.execute()
            // C2 已完成其 side effect / cleanup 尝试；关闭 proposal-owned
            // parent FD，避免 approval record 的 capability 长期占用资源。
            _ = await executionCapability.invalidate()

            let serialized = AgentToolResultSerializer.serialize(
                fileMutationResult: result,
                request: authorization.request
            )

            if result.published {
                // published=true 是不可逆事实。即便 Stop 与 publication
                // 竞态发生，也必须保留成功（含 cleanup warning）而不能
                // 转成 retryable "not executed"。
                conversation.updateToolActivity(
                    cardID,
                    status: .success,
                    resultJSON: serialized,
                    isError: false
                )
                return .completed
            }

            if result.error == nil {
                // C2 当前总是提供 published Bool + stable error；若未来
                // seam 允许出现无 error 的 unpublished 结果，按 unknown
                // publication state 立即停止 loop，绝不自动重试。
                conversation.updateToolActivity(
                    cardID,
                    status: .partial,
                    resultJSON: serialized,
                    isError: true
                )
                return .fatalMutationUncertain
            }

            if Task.isCancelled || result.error == .cancelled {
                conversation.updateToolActivity(
                    cardID,
                    status: .cancelled,
                    resultJSON: AgentToolResultSerializer.cancelledOutput,
                    isError: true
                )
                throw CancellationError()
            }

            // 确定性 unpublished failure 可作为一次 tool result 回给
            // Provider；Agent loop 不会基于它自动重新执行 write_file。
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: serialized,
                isError: true
            )
            return .completed
        } catch is CancellationError {
            // 对等待/claim 阶段的取消做统一安全收尾。若 C2 已返回
            // published=true，上面的成功分支已经返回，不会被这里覆盖。
            _ = await request.parentCapability.invalidate()
            conversation.updateToolActivity(
                cardID,
                status: .cancelled,
                resultJSON: AgentToolResultSerializer.cancelledOutput,
                isError: true
            )
            throw CancellationError()
        } catch let error as AgentFileMutationError {
            _ = await request.parentCapability.invalidate()
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return .completed
        }
    }

    /// B4 run_command 完整链：严格 request → register → card → await
    /// decision → claim → executor redeem → bounded result。
    private func executeRunCommand(
        cardID: UUID,
        approvalID: UUID,
        request: AgentCommandRequest,
        generationID: UUID,
        sessionID: UUID,
        providerSnapshotID: UUID,
        approvalCoordinator: AgentCommandApprovalCoordinator,
        localCommandExecutor: AgentLocalCommandExecutor,
        remoteCommandExecutor: AgentRemoteCommandExecutor,
        conversation: AgentConversation
    ) async throws -> ToolExecutionOutcome {

        do {
            let decision = try await approvalCoordinator.awaitDecision(approvalID: approvalID)
            switch decision {
            case .denied:
                conversation.updateToolActivity(
                    cardID,
                    status: .denied,
                    resultJSON: AgentToolResultSerializer.userDeniedOutput,
                    isError: true
                )
                return .completed
            case .cancelled:
                conversation.updateToolActivity(
                    cardID,
                    status: .cancelled,
                    resultJSON: AgentToolResultSerializer.cancelledOutput,
                    isError: true
                )
                throw CancellationError()
            case .approved:
                try Task.checkCancellation()
            }

            let authorization = try await approvalCoordinator.claimExecution(
                approvalID: approvalID,
                expected: AgentCommandClaimExpectations(
                    generationID: generationID,
                    sessionID: sessionID,
                    providerSnapshotID: providerSnapshotID
                )
            )

            // R2 P2-1：claim 成功即代表本次执行已获授权。先同步发布
            // running，再把 authorization 交给 executor；因此 Local 的
            // posix_spawn 或 Remote 的 SSH exec side effect 发生前，UI
            // 已移除 Approve / Deny，用户不会再看到失实的 awaitingApproval。
            conversation.updateToolActivity(
                cardID,
                status: .running,
                resultJSON: "",
                isError: false
            )

            let result: CommandExecutionOutput
            switch request.target {
            case .local:
                let localResult = try await localCommandExecutor.execute(
                    authorization: authorization,
                    approvalCoordinator: approvalCoordinator
                )
                result = .local(localResult)
            case .remote:
                let remoteResult = try await remoteCommandExecutor.execute(
                    authorization: authorization,
                    approvalCoordinator: approvalCoordinator
                )
                result = .remote(remoteResult)
            }

            if Task.isCancelled || result.isCancelled {
                conversation.updateToolActivity(
                    cardID,
                    status: .cancelled,
                    resultJSON: AgentToolResultSerializer.cancelledOutput,
                    isError: true
                )
                throw CancellationError()
            }

            conversation.updateToolActivity(
                cardID,
                status: result.isTimedOut ? .timedOut : .success,
                resultJSON: result.serialized,
                isError: false
            )
            return .completed
        } catch is CancellationError {
            conversation.updateToolActivity(
                cardID,
                status: .cancelled,
                resultJSON: AgentToolResultSerializer.cancelledOutput,
                isError: true
            )
            throw CancellationError()
        } catch let error as AgentCommandError {
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return .completed
        } catch let error as AgentCommandExecutionError {
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return .completed
        } catch let error as AgentRemoteCommandExecutionError {
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return .completed
        }
    }

    /// 10F-B4-S1 send_to_terminal 完整链（§16 生命周期）：
    /// waitingForUser（card 已发布）→ await decision → claim → running →
    /// redeem（executor 内）→ dispatch 冻结 capability → sanitized result。
    ///
    /// 安全不变式：
    /// - 只使用 proposal admission 冻结的 endpoint capability（§13/§14：
    ///   绝无 active-tab fallback；stale → 0 字节安全失败）；
    /// - Local 只经 accepted B2 executor，Remote 只经 accepted B3
    ///   executor（§15/§34/§35：绝不复用命令执行器 / SSH exec 通道 /
    ///   粘贴 API 或 legacy 命令调度器）；
    /// - partial / uncertain → `.fatalMutationUncertain`（§29：同一
    ///   generation 绝不自动续 Provider）。
    private func executeSendToTerminal(
        cardID: UUID,
        approvalID: UUID,
        request: AgentTerminalMutationRequest,
        generationID: UUID,
        sessionID: UUID,
        providerSnapshotID: UUID,
        mutationApprovalCoordinator: AgentTerminalMutationApprovalCoordinator,
        localMutationExecutor: AgentLocalTerminalMutationExecutor,
        remoteMutationExecutor: AgentRemoteTerminalMutationExecutor,
        conversation: AgentConversation
    ) async throws -> ToolExecutionOutcome {
        // 冻结 capability 必须存在（card 创建失败时卡片本身就是失败态，
        // 这里绝不会被调用）。
        guard let capability = pendingMutationEndpoints[cardID] else {
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(
                    error: AgentTerminalMutationError.targetReplaced
                ),
                isError: true
            )
            return .completed
        }

        do {
            let decision = try await mutationApprovalCoordinator.awaitDecision(
                approvalID: approvalID
            )
            switch decision {
            case .denied:
                // §26：Deny → 零终端字节、proposal 失效、稳定 userDenied。
                pendingMutationEndpoints[cardID] = nil
                conversation.updateToolActivity(
                    cardID,
                    status: .denied,
                    resultJSON: AgentToolResultSerializer.userDeniedOutput,
                    isError: true
                )
                return .completed
            case .cancelled:
                // §27：Stop 使 pending proposal 失效，0 字节。
                pendingMutationEndpoints[cardID] = nil
                conversation.updateToolActivity(
                    cardID,
                    status: .cancelled,
                    resultJSON: AgentToolResultSerializer.cancelledOutput,
                    isError: true
                )
                throw CancellationError()
            case .approved:
                try Task.checkCancellation()
            }

            let identity = capability.targetIdentity
            let authorization: AgentTerminalMutationExecutionAuthorization
            do {
                authorization = try await mutationApprovalCoordinator.claimExecution(
                    approvalID: approvalID,
                    expected: AgentTerminalMutationClaimExpectations(
                        generationID: generationID,
                        logicalSessionID: sessionID,
                        providerSnapshotID: providerSnapshotID,
                        inputTargetEpoch: identity.inputTargetEpoch,
                        endpointToken: identity.endpointToken
                    )
                )
            } catch let error as AgentTerminalMutationError {
                // §14/§23：targetReplaced（incarnation 漂移）/ bindingMismatch /
                // approvalCancelled 等 → 零授权、零交付。
                pendingMutationEndpoints[cardID] = nil
                conversation.updateToolActivity(
                    cardID,
                    status: .failure,
                    resultJSON: AgentToolResultSerializer.serialize(error: error),
                    isError: true
                )
                return .completed
            }

            // claim 成功即代表本次交付已获授权。先同步发布 running，
            // 再进入 executor；因此任何物理写入前 Approve / Deny 已移除
            // （§24：无双批准窗口）。
            conversation.updateToolActivity(
                cardID,
                status: .running,
                resultJSON: "",
                isError: false
            )

            let result: AgentTerminalMutationDeliveryResult
            let terminalKind: AgentTerminalSessionKind
            switch capability {
            case .local(let endpoint):
                terminalKind = .local
                result = await localMutationExecutor.deliver(authorization, to: endpoint)
            case .remote(let endpoint):
                terminalKind = .remoteSSH
                result = await remoteMutationExecutor.deliver(authorization, to: endpoint)
            }
            pendingMutationEndpoints[cardID] = nil

            if Task.isCancelled || result.error == .cancelled {
                conversation.updateToolActivity(
                    cardID,
                    status: .cancelled,
                    resultJSON: AgentToolResultSerializer.cancelledOutput,
                    isError: true
                )
                throw CancellationError()
            }

            let serialized = AgentToolResultSerializer.serialize(
                mutationResult: result,
                terminalKind: terminalKind
            )

            if result.outcome == .partial
                || result.terminalInputState == .uncertain {
                // §29：partial / uncertain 副作用 → 停止 loop，用户可见。
                conversation.updateToolActivity(
                    cardID,
                    status: .partial,
                    resultJSON: serialized,
                    isError: true
                )
                return .fatalMutationUncertain
            }

            conversation.updateToolActivity(
                cardID,
                status: result.outcome == .delivered ? .success : .failure,
                resultJSON: serialized,
                isError: result.outcome != .delivered
            )
            return .completed
        } catch is CancellationError {
            pendingMutationEndpoints[cardID] = nil
            conversation.updateToolActivity(
                cardID,
                status: .cancelled,
                resultJSON: AgentToolResultSerializer.cancelledOutput,
                isError: true
            )
            throw CancellationError()
        } catch let error as AgentTerminalMutationError {
            pendingMutationEndpoints[cardID] = nil
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return .completed
        }
    }

    /// 运行期输出的统一视图，避免 provider loop 直接依赖 Local/Remote
    /// executor 的不同结果类型。
    private enum CommandExecutionOutput: Sendable {
        case local(AgentCommandResult)
        case remote(AgentRemoteCommandResult)

        var isCancelled: Bool {
            switch self {
            case .local(let result): return result.cancelled
            case .remote(let result): return result.result.cancelled
            }
        }

        var isTimedOut: Bool {
            switch self {
            case .local(let result): return result.timedOut
            case .remote(let result): return result.result.timedOut
            }
        }

        var serialized: String {
            switch self {
            case .local(let result):
                return AgentToolResultSerializer.serialize(commandResult: result)
            case .remote(let result):
                return AgentToolResultSerializer.serialize(commandResult: result)
            }
        }
    }

    /// 添加单条 tool card，并在返回前使其进入 conversation 时间线。
    private func appendToolCard(
        _ activity: AgentToolActivity,
        to conversation: AgentConversation
    ) -> UUID {
        let cardID = UUID()
        conversation.append(
            AgentMessage(id: cardID, role: .tool, content: .tool(activity))
        )
        return cardID
    }

    private enum ToolExecutionOutcome: Equatable {
        case completed
        case fatalSessionUnavailable
        /// 10F-B4-S1 §29：terminal mutation 交付 partial / uncertain——
        /// 停止 loop（绝不自动续 Provider），副作用状态 surfaced 到卡片。
        case fatalMutationUncertain
    }

    /// 停止后的收尾（任务书 §15 hard gate / B4 §45–§48）：
    /// - partial 内容保留并标记 complete；
    /// - 尚未产生任何内容的占位移除（空占位不是"已生成的 partial content"）。
    private func finishCancelled(
        _ conversation: AgentConversation,
        assistantID: UUID
    ) {
        if let message = conversation.messages.first(where: { $0.id == assistantID }) {
            if message.text.isEmpty {
                conversation.removeMessage(assistantID)
            } else {
                conversation.completeMessage(assistantID)
            }
        }
    }

    /// 结构化失败收尾：placeholder 已被移除（纯 tool 轮次）时补一条
    /// failed 消息，保证失败始终可见。
    private func failGeneration(
        _ conversation: AgentConversation,
        assistantID: UUID,
        kind: AgentFailureKind
    ) {
        if conversation.messages.contains(where: { $0.id == assistantID }) {
            conversation.failMessage(assistantID, kind: kind)
        } else {
            conversation.append(
                AgentMessage(role: .assistant, content: "", state: .failed, failure: kind)
            )
        }
    }

    /// 把当前 generation 中仍处于 running / awaitingApproval 的 tool card
    /// 收敛为 cancelled（§45–§48：未执行 / 未完成的调用绝不留下无结果
    /// 状态——transcript 重建时按 cancelled 输出，call_id 配对恒成立）。
    private func cancelRunningToolCards(in conversation: AgentConversation) {
        for message in conversation.messages {
            guard
                case .tool(let activity) = message.content,
                activity.status == .running || activity.status == .awaitingApproval
            else { continue }
            conversation.updateToolActivity(
                message.id,
                status: .cancelled,
                resultJSON: AgentToolResultSerializer.cancelledOutput,
                isError: true
            )
        }
    }

    // MARK: - Read scope 冻结（B4 §34/§35）

    /// generation 开始时构建 readScope，此后不再重算：
    /// - Local：authoritative OSC7 cwd → 本地 canonical root；
    /// - Remote：authoritative OSC7 cwd → SFTP 服务端 canonicalize；
    /// - cwd 非权威 / canonicalize 失败 / session 不可寻址 → 空 roots
    ///   （绝不 fallback approximate，绝不偷偷扩大）。
    private static func freezeReadScope(
        sessionID: UUID,
        sessionKind: AgentTerminalSessionKind,
        workingDirectory: AgentWorkingDirectory,
        remoteServiceResolver: (any AgentRemoteReadOnlyServiceResolving)?
    ) async -> AgentReadScope {
        switch sessionKind {
        case .local:
            return AgentReadScope.make(
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                kind: .local
            )
        case .remoteSSH:
            guard let service = remoteServiceResolver?.remoteFileService(for: sessionID) else {
                return AgentReadScope(sessionID: sessionID, allowedRoots: [])
            }
            return await AgentReadScope.makeRemote(
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                client: service.client
            )
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
