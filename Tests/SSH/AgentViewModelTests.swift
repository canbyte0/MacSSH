import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 10B：AgentViewModel 测试（任务书 §30）。
///
/// Provider 均为内存 mock（零延迟 / 可控挂起），不依赖网络与 wall-clock。
@MainActor
final class AgentViewModelTests: XCTestCase {

    /// 测试用可变 session 框（注入 ViewModel 闭包）。
    private final class SessionBox {
        var session: ManagedTerminalSession?
    }

    /// 先产出一个 chunk 再长期挂起的 provider：验证 Stop 取消与 partial 保留。
    private struct PartialThenSlowProvider: AgentProvider {
        func stream(
            messages: [AgentMessage],
            context: AgentSessionContext
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                let producer = Task {
                    continuation.yield(.textDelta("部分内容"))
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    producer.cancel()
                }
            }
        }
    }

    /// 延迟产出 delta 的 provider：验证「A streaming 中切到 B 后 A 的 delta
    /// 只进入 A conversation」（任务书 §24 hard gate）。
    private struct DelayedDeltaProvider: AgentProvider {
        func stream(
            messages: [AgentMessage],
            context: AgentSessionContext
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                let producer = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    continuation.yield(.textDelta("A-delta"))
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    producer.cancel()
                }
            }
        }
    }

    /// 可脚本化 provider（Phase 10C provider-style fake，任务书 §35）：
    /// 按调用次数弹出预设结果（成功事件序列或错误）；记录每次收到的
    /// 完整 messages，供多轮 history 断言。
    private final class ScriptedAgentProvider: AgentProvider, @unchecked Sendable {
        struct Call {
            let messages: [AgentMessage]
            let context: AgentSessionContext
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var scripts: [Result<[AgentEvent], Error>]
        var configuration: AgentProviderConfigurationState = .ready

        init(scripts: [Result<[AgentEvent], Error>]) {
            self.scripts = scripts
        }

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        func stream(
            messages: [AgentMessage],
            context: AgentSessionContext
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            lock.lock()
            _calls.append(Call(messages: messages, context: context))
            let result: Result<[AgentEvent], Error>
            if scripts.count > 1 {
                result = scripts.removeFirst()
            } else if let only = scripts.first {
                result = only
            } else {
                result = .success([.textDelta("reply"), .completed])
            }
            lock.unlock()

            return AsyncThrowingStream { continuation in
                let producer = Task {
                    switch result {
                    case .success(let events):
                        for event in events {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                        continuation.finish()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    producer.cancel()
                }
            }
        }

        func configurationState() async -> AgentProviderConfigurationState {
            configuration
        }
    }

    // MARK: - 构造

    private func makeLocalSession() -> ManagedTerminalSession {
        ManagedTerminalSession(
            localService: LocalTerminalService(session: TerminalSession(shellPath: "/bin/zsh")),
            baseTitle: "Local",
            titleCounter: 1
        )
    }

    private func makeRemoteSession() -> ManagedTerminalSession {
        ManagedTerminalSession(
            remoteHostID: UUID(),
            hostDisplayName: "Example",
            hostname: "example.com",
            port: 22,
            baseTitle: "Example",
            titleCounter: 1
        )
    }

    private func makeViewModel(
        store: AgentConversationStore = AgentConversationStore(),
        provider: AgentProvider = MockAgentProvider(chunkDelay: .zero),
        box: SessionBox
    ) -> AgentViewModel {
        AgentViewModel(
            store: store,
            provider: provider,
            activeSessionProvider: { box.session },
            allSessionsProvider: { box.session.map { [$0] } ?? [] }
        )
    }

    // MARK: - Send 基础行为

    func testSendTrimsInput() async throws {
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "  hello world  \n"
        viewModel.send()
        let generationTask = try XCTUnwrap(conversation.generationTask)
        await generationTask.value

        XCTAssertEqual(conversation.messages.first?.role, .user)
        XCTAssertEqual(conversation.messages.first?.content, "hello world", "发送前必须 trim 空白")
        XCTAssertTrue(conversation.draft.isEmpty, "发送后 draft 必须清空")
    }

    func testEmptyInputIsIgnored() {
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = viewModel.activeConversation
        conversation?.draft = "   \n\t "
        viewModel.send()

        XCTAssertEqual(conversation?.messages.isEmpty, true, "空白输入不得发送")
        XCTAssertFalse(conversation?.isGenerating ?? true, "空白输入不得启动生成")
    }

    func testMockResponseIsStreamedToCompletion() async throws {
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "为什么 git status 报错？"
        viewModel.send()
        let generationTask = try XCTUnwrap(conversation.generationTask)
        await generationTask.value

        XCTAssertEqual(conversation.messages.count, 2)
        let assistant = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.state, .complete)
        XCTAssertEqual(assistant.content, MockAgentProvider.replyText)
        XCTAssertFalse(conversation.isGenerating)
    }

    // MARK: - Stop（任务书 §15 hard gate）

    func testStopCancelsEmptyPlaceholderRemovalAndAllowsNextSend() async throws {
        let box = SessionBox()
        box.session = makeLocalSession()
        // 长 chunk 延迟：send 后立即 stop，流式尚未产出任何内容。
        let viewModel = makeViewModel(provider: MockAgentProvider(chunkDelay: .seconds(60)), box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "hello"
        viewModel.send()
        let generationTask = try XCTUnwrap(conversation.generationTask)
        XCTAssertTrue(conversation.isGenerating)
        XCTAssertEqual(conversation.messages.count, 2, "user + streaming 占位")

        viewModel.stop()
        await generationTask.value

        XCTAssertFalse(conversation.isGenerating, "Stop 后必须立即恢复可发送状态")
        XCTAssertEqual(
            conversation.messages.count,
            1,
            "未产生任何内容的 assistant 占位必须移除（只保留 user 消息）"
        )

        // 下一条消息仍可以发送：立即开始第二个 generation 并可再次停止
        // （不等待慢速 provider 完成，避免 wall-clock 依赖）。
        conversation.draft = "again"
        viewModel.send()
        let nextTask = try XCTUnwrap(conversation.generationTask)
        XCTAssertTrue(conversation.isGenerating, "Stop 后必须能再次发送")
        XCTAssertEqual(
            conversation.messages.count,
            3,
            "hello + again 两条 user 消息 + 新 streaming 占位"
        )

        viewModel.stop()
        await nextTask.value
        XCTAssertFalse(conversation.isGenerating)
    }

    func testStopKeepsPartialAssistantContent() async throws {
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(provider: PartialThenSlowProvider(), box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "长回复测试"
        viewModel.send()
        let generationTask = try XCTUnwrap(conversation.generationTask)

        // 等待首个（也是唯一的）chunk 到达。
        let deadline = Date().addingTimeInterval(2)
        while conversation.messages.last?.content.isEmpty != false, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(conversation.messages.last?.content, "部分内容")

        viewModel.stop()
        await generationTask.value

        XCTAssertEqual(conversation.messages.last?.content, "部分内容", "已生成的 partial 内容不得删除")
        XCTAssertEqual(conversation.messages.last?.state, .complete, "停止后 partial 标记为 complete")
        XCTAssertFalse(conversation.isGenerating)
    }

    // MARK: - 失败与恢复（任务书 §22）

    func testMockErrorFailsAndRecovers() async throws {
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "/mock-error"
        viewModel.send()
        let failedTask = try XCTUnwrap(conversation.generationTask)
        await failedTask.value

        let failed = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertFalse(conversation.isGenerating, "失败后生成状态必须恢复")

        // 失败后可以重新 Send（正常消息成功流式完成）。
        conversation.draft = "恢复测试"
        viewModel.send()
        let recoveredTask = try XCTUnwrap(conversation.generationTask)
        await recoveredTask.value

        XCTAssertEqual(conversation.messages.count, 4, "user + failed assistant + user + complete assistant")
        XCTAssertEqual(conversation.messages.last?.state, .complete)
        XCTAssertEqual(conversation.messages.last?.content, MockAgentProvider.replyText)
    }

    // MARK: - 并发发送策略（任务书 §16）

    func testDuplicateSendIsBlockedWhileGenerating() async throws {
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(provider: PartialThenSlowProvider(), box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "first"
        viewModel.send()
        let generationTask = try XCTUnwrap(conversation.generationTask)
        XCTAssertTrue(conversation.isGenerating)
        XCTAssertFalse(viewModel.canSend, "生成中 canSend 必须为 false")

        conversation.draft = "second"
        viewModel.send()

        XCTAssertEqual(conversation.messages.count, 2, "生成中第二次 send 必须被忽略")
        XCTAssertEqual(conversation.draft, "second", "被阻止的 send 不得清空 draft")
        XCTAssertTrue(conversation.isGenerating, "原 generation 仍在进行，不得被替换")

        viewModel.stop()
        await generationTask.value
    }

    // MARK: - 会话切换（任务书 §17 hard gate）

    func testSessionSwitchSelectsCorrectConversation() async throws {
        let box = SessionBox()
        let sessionA = makeLocalSession()
        let sessionB = makeLocalSession()
        box.session = sessionA
        let viewModel = makeViewModel(box: box)

        // Local A：发送 "A1"。
        viewModel.ensureConversationForActiveSession()
        let conversationA = try XCTUnwrap(viewModel.activeConversation)
        conversationA.draft = "A1"
        viewModel.send()
        let taskA = try XCTUnwrap(conversationA.generationTask)
        await taskA.value
        XCTAssertEqual(conversationA.messages.count, 2)

        // 切换 Local B：conversation 必须为空（不串线）。
        box.session = sessionB
        viewModel.ensureConversationForActiveSession()
        let conversationB = try XCTUnwrap(viewModel.activeConversation)
        XCTAssertFalse(conversationA === conversationB)
        XCTAssertTrue(conversationB.isEmpty, "Local B 不得看到 A 的消息")

        conversationB.draft = "B1"
        viewModel.send()
        let taskB = try XCTUnwrap(conversationB.generationTask)
        await taskB.value
        XCTAssertEqual(conversationB.messages.count, 2)

        // 切回 Local A："A1" 仍在。
        box.session = sessionA
        XCTAssertEqual(viewModel.activeConversation?.messages.count, 2)
        XCTAssertEqual(conversationA.messages.first?.content, "A1")
        XCTAssertEqual(viewModel.activeConversation?.messages.first?.content, "A1")
    }

    // MARK: - 关闭 session cleanup（任务书 §18）

    func testClosedSessionConversationIsPruned() async throws {
        let store = AgentConversationStore()
        let box = SessionBox()
        let sessionA = makeLocalSession()
        box.session = sessionA
        let viewModel = makeViewModel(store: store, box: box)

        viewModel.ensureConversationForActiveSession()
        let conversationA = try XCTUnwrap(store.existingConversation(for: sessionA.id))
        conversationA.draft = "A1"
        viewModel.send()
        let generationTask = try XCTUnwrap(conversationA.generationTask)
        await generationTask.value
        XCTAssertTrue(store.existingConversation(for: sessionA.id) === conversationA)

        // sessionA 关闭（不再存在于 sessions 列表）：prune 后 conversation 释放。
        let sessionB = makeLocalSession()
        box.session = sessionB
        viewModel.ensureConversationForActiveSession()
        viewModel.pruneConversations()

        XCTAssertNil(store.existingConversation(for: sessionA.id), "关闭 session 的 conversation 必须移除")
        XCTAssertNotNil(store.existingConversation(for: sessionB.id), "存活 session 的 conversation 保留")
    }

    // MARK: - 无 session 防御

    func testSendWithoutSessionShowsNoticeAndDoesNothing() {
        let box = SessionBox()
        box.session = nil
        let viewModel = makeViewModel(box: box)

        XCTAssertNil(viewModel.activeContext)
        XCTAssertNil(viewModel.activeConversation)
        XCTAssertFalse(viewModel.canSend)

        viewModel.send()

        XCTAssertTrue(viewModel.showsNoSessionNotice, "无 session 时发送必须显示 non-fatal 提示")
        XCTAssertNil(viewModel.activeConversation, "不得创建任何 conversation")
    }

    // MARK: - Context 提取（任务书 §12）

    func testContextForLocalAndRemoteSessions() {
        let local = makeLocalSession()
        let localContext = AgentViewModel.context(for: local)
        XCTAssertEqual(localContext.kind, .local)
        XCTAssertEqual(localContext.displayName, "Local")
        XCTAssertEqual(localContext.sessionID, local.id)
        XCTAssertNil(localContext.currentDirectory, "未收到 OSC 7 时 cwd 必须为 nil（不伪造）")

        let remote = makeRemoteSession()
        let remoteContext = AgentViewModel.context(for: remote)
        XCTAssertEqual(remoteContext.kind, .remoteSSH)
        XCTAssertEqual(remoteContext.displayName, "Example")
        XCTAssertEqual(remoteContext.sessionID, remote.id)
    }

    func testDisplayDirectoryHomeAbbreviationAndFallbacks() {
        let home = NSHomeDirectory()

        // 本机 home 前缀缩略为 ~。
        let localContext = AgentSessionContext(
            sessionID: UUID(),
            kind: .local,
            displayName: "Local",
            currentDirectory: "file://localhost\(home)/project"
        )
        XCTAssertEqual(localContext.displayDirectory, "~/project")

        // home 本身。
        let homeContext = AgentSessionContext(
            sessionID: UUID(),
            kind: .local,
            displayName: "Local",
            currentDirectory: "file://localhost\(home)"
        )
        XCTAssertEqual(homeContext.displayDirectory, "~")

        // 远端路径（非本机 home 前缀）：原样展示，不伪造缩略。
        let remoteContext = AgentSessionContext(
            sessionID: UUID(),
            kind: .remoteSSH,
            displayName: "Example",
            currentDirectory: "file://remotehost/home/user/work"
        )
        XCTAssertEqual(remoteContext.displayDirectory, "/home/user/work")

        // 无 cwd / 非法 cwd：nil，绝不推测。
        let nilContext = AgentSessionContext(
            sessionID: UUID(),
            kind: .local,
            displayName: "Local",
            currentDirectory: nil
        )
        XCTAssertNil(nilContext.displayDirectory)

        let invalidContext = AgentSessionContext(
            sessionID: UUID(),
            kind: .local,
            displayName: "Local",
            currentDirectory: "not a url"
        )
        XCTAssertNil(invalidContext.displayDirectory)
    }

    // MARK: - 多轮 history（Phase 10C 任务书 §6 / §35）

    func testMultiTurnHistoryIsForwardedToProvider() async throws {
        let provider = ScriptedAgentProvider(scripts: [])
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(provider: provider, box: box)
        viewModel.ensureConversationForActiveSession()

        // 第一轮：user "我叫 Alice" → assistant "你好 Alice"。
        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "我叫 Alice"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value

        // 第二轮：provider 必须收到完整多轮 history（含刚 append 的 user）。
        conversation.draft = "我叫什么？"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value

        XCTAssertEqual(provider.calls.count, 2)
        let secondCall = try XCTUnwrap(provider.calls.last)
        XCTAssertEqual(
            secondCall.messages.map(\.role),
            [.user, .assistant, .user],
            "必须发送完整有序多轮 history，禁止只发最后一条 user message"
        )
        XCTAssertEqual(secondCall.messages[0].content, "我叫 Alice")
        XCTAssertEqual(secondCall.messages[1].content, "reply")
        XCTAssertEqual(secondCall.messages[2].content, "我叫什么？")
    }

    // MARK: - 结构化失败与恢复（Phase 10C 任务书 §20 / §35）

    func testUnauthorizedFailureMapsKindAndRecovers() async throws {
        let provider = ScriptedAgentProvider(scripts: [
            .failure(AgentProviderError.unauthorized),
            .success([.textDelta("recovered"), .completed]),
        ])
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(provider: provider, box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "first"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value

        let failed = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failure, .authentication, "401 必须映射为 authentication 分类")
        XCTAssertFalse(conversation.isGenerating, "失败后可发送状态必须恢复")

        // 401 后可恢复：下一条消息正常完成。
        conversation.draft = "second"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value

        let recovered = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(recovered.state, .complete)
        XCTAssertEqual(recovered.content, "recovered")
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testRateLimitedFailureMapsKindAndRecovers() async throws {
        let provider = ScriptedAgentProvider(scripts: [
            .failure(AgentProviderError.rateLimited),
            .success([.textDelta("recovered"), .completed]),
        ])
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(provider: provider, box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "first"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value

        let failed = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failure, .rateLimited, "429 必须映射为 rateLimited 分类")

        // 429 后可恢复。
        conversation.draft = "second"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value
        XCTAssertEqual(conversation.messages.last?.state, .complete)
    }

    func testMissingCredentialFailureMapsKind() async throws {
        let provider = ScriptedAgentProvider(scripts: [
            .failure(AgentProviderError.missingCredential),
        ])
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(provider: provider, box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "hello"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value

        let failed = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(failed.failure, .missingCredential, "missingCredential 不得伪装成 generic")
    }

    /// failed 消息不进入后续请求 history（partial 失败不是完整轮次）。
    func testFailedMessagesExcludedFromNextRequestHistory() async throws {
        let provider = ScriptedAgentProvider(scripts: [
            .failure(AgentProviderError.transport("network down")),
            .success([.textDelta("ok"), .completed]),
        ])
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(provider: provider, box: box)
        viewModel.ensureConversationForActiveSession()

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "first"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value

        conversation.draft = "second"
        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value

        let secondCall = try XCTUnwrap(provider.calls.last)
        XCTAssertEqual(
            secondCall.messages.map(\.role),
            [.user, .user],
            "failed assistant 消息不得进入下一次请求 history"
        )
    }

    // MARK: - Provider 配置状态（Phase 10C 任务书 §15 / §35）

    func testNotConfiguredProviderDisablesSend() async throws {
        let provider = ScriptedAgentProvider(scripts: [])
        provider.configuration = .notConfigured
        let box = SessionBox()
        box.session = makeLocalSession()
        let viewModel = makeViewModel(provider: provider, box: box)
        viewModel.ensureConversationForActiveSession()

        await viewModel.refreshProviderConfiguration()
        XCTAssertEqual(viewModel.providerState, .notConfigured)

        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "hello"
        XCTAssertFalse(viewModel.canSend, "notConfigured 时 canSend 必须为 false")

        viewModel.send()
        XCTAssertFalse(conversation.isGenerating, "notConfigured 时不得发起任何请求")
        XCTAssertTrue(provider.calls.isEmpty, "provider 不得被调用")

        // 配置后恢复：refresh → ready → 可发送。
        provider.configuration = .ready
        await viewModel.refreshProviderConfiguration()
        XCTAssertEqual(viewModel.providerState, .ready)
        XCTAssertTrue(viewModel.canSend)

        viewModel.send()
        try await XCTUnwrap(conversation.generationTask).value
        XCTAssertEqual(conversation.messages.last?.content, "reply")
        XCTAssertEqual(provider.calls.count, 1)
    }

    // MARK: - A streaming 中切到 B（Phase 10C 任务书 §24 hard gate）

    func testSessionADeltasStayInAAfterSwitchToB() async throws {
        let box = SessionBox()
        let sessionA = makeLocalSession()
        let sessionB = makeLocalSession()
        box.session = sessionA
        let viewModel = makeViewModel(provider: DelayedDeltaProvider(), box: box)
        viewModel.ensureConversationForActiveSession()

        let conversationA = try XCTUnwrap(viewModel.activeConversation)
        conversationA.draft = "A"
        viewModel.send()
        let taskA = try XCTUnwrap(conversationA.generationTask)

        // A 仍在 streaming 时切换到 B。
        box.session = sessionB
        viewModel.ensureConversationForActiveSession()
        let conversationB = try XCTUnwrap(viewModel.activeConversation)
        XCTAssertFalse(conversationA === conversationB)

        // A 的 delta 在切换之后到达。
        try await waitUntil { conversationA.messages.last?.content == "A-delta" }

        // B conversation 不得出现 A 的任何 delta（高优先级 target isolation gate）。
        XCTAssertTrue(conversationB.isEmpty, "A 的 delta 只能追加到 A conversation")

        viewModel.stop()
        await taskA.value
        XCTAssertEqual(conversationA.messages.last?.content, "A-delta")
        XCTAssertEqual(conversationA.messages.last?.state, .complete)
        XCTAssertTrue(conversationB.isEmpty)
    }

    // MARK: - 工具（测试辅助）

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("条件在 \(timeout)s 内未满足")
    }
}
