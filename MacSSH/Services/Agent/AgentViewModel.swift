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
        conversation.cancelGeneration()
        Task {
            _ = await approvalCoordinator.cancelGeneration(generationID)
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

        Task {
            _ = await approvalCoordinator.approve(approvalID)
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

        Task {
            _ = await approvalCoordinator.deny(approvalID)
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
        for (sessionID, conversation) in store.conversations
        where !validIDs.contains(sessionID) {
            conversation.cancelGeneration()
            Task {
                _ = await approvalCoordinator.cancelSession(sessionID)
                _ = await approvalCoordinator.purgeSession(sessionID)
            }
            store.removeConversation(for: sessionID)
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

    /// Provider call 到达时建立卡片。run_command 严格执行：validate →
    /// immutable request → register → visible card；read-only call 则立即
    /// 发布 running card，保持原有 streaming/Stop 可观察性。
    private func appendToolCardForProviderCall(
        _ providerCall: AgentProviderToolCall,
        generationID: UUID,
        sessionID: UUID,
        frozenHandle: AgentTerminalSessionHandle,
        providerSnapshotID: UUID,
        generationProvider: any AgentProvider,
        approvalCoordinator: AgentCommandApprovalCoordinator,
        conversation: AgentConversation
    ) async -> UUID {
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
            let cardID = appendToolCard(
                AgentToolActivity(runningFrom: providerCall),
                to: conversation
            )
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return cardID
        case .success(let value):
            parsed = value
        }

        guard let command = parsed.command else {
            let cardID = appendToolCard(
                AgentToolActivity(runningFrom: providerCall),
                to: conversation
            )
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: .invalidArguments),
                isError: true
            )
            return cardID
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
            let cardID = appendToolCard(
                AgentToolActivity(runningFrom: providerCall),
                to: conversation
            )
            conversation.updateToolActivity(
                cardID,
                status: .failure,
                resultJSON: AgentToolResultSerializer.serialize(error: error),
                isError: true
            )
            return cardID
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
