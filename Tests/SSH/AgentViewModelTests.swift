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
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let producer = Task {
                    continuation.yield("部分内容")
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    producer.cancel()
                }
            }
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
}
