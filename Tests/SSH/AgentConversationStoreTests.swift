import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 10B：AgentConversationStore 测试（任务书 §30）。
@MainActor
final class AgentConversationStoreTests: XCTestCase {

    func testNewSessionGetsEmptyConversation() {
        let store = AgentConversationStore()
        let sessionID = UUID()

        let conversation = store.conversation(for: sessionID)

        XCTAssertEqual(conversation.sessionID, sessionID)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertTrue(conversation.draft.isEmpty)
        XCTAssertFalse(conversation.isGenerating)
        XCTAssertEqual(store.count, 1)
    }

    func testConversationIsStableAcrossRequests() {
        let store = AgentConversationStore()
        let sessionID = UUID()

        let first = store.conversation(for: sessionID)
        let second = store.conversation(for: sessionID)

        XCTAssertTrue(first === second, "同一 session 必须复用同一 conversation 实例")
        XCTAssertEqual(store.count, 1)
    }

    func testExistingConversationDoesNotCreate() {
        let store = AgentConversationStore()
        let unknownSessionID = UUID()

        XCTAssertNil(store.existingConversation(for: unknownSessionID))
        XCTAssertEqual(store.count, 0, "只读访问不得创建 conversation")
    }

    func testAppendUserMessage() {
        let store = AgentConversationStore()
        let conversation = store.conversation(for: UUID())

        conversation.append(AgentMessage(role: .user, content: "hello"))

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.role, .user)
        XCTAssertEqual(conversation.messages.first?.text, "hello")
        XCTAssertEqual(conversation.messages.first?.state, .complete)
    }

    func testAppendAssistantAndStreamingTransitions() {
        let store = AgentConversationStore()
        let conversation = store.conversation(for: UUID())

        let assistant = AgentMessage(role: .assistant, content: "", state: .streaming)
        conversation.append(assistant)
        conversation.appendChunk("这是 ", to: assistant.id)
        conversation.appendChunk("chunk", to: assistant.id)
        conversation.completeMessage(assistant.id)

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.text, "这是 chunk")
        XCTAssertEqual(conversation.messages.first?.state, .complete)
    }

    func testFailMessageKeepsPartialContent() {
        let store = AgentConversationStore()
        let conversation = store.conversation(for: UUID())

        let assistant = AgentMessage(role: .assistant, content: "", state: .streaming)
        conversation.append(assistant)
        conversation.appendChunk("partial", to: assistant.id)
        conversation.failMessage(assistant.id)

        XCTAssertEqual(conversation.messages.first?.text, "partial", "失败时 partial 内容必须保留")
        XCTAssertEqual(conversation.messages.first?.state, .failed)
    }

    func testSessionIsolation() {
        let store = AgentConversationStore()
        let conversationA = store.conversation(for: UUID())
        let conversationB = store.conversation(for: UUID())

        conversationA.append(AgentMessage(role: .user, content: "A1"))

        XCTAssertFalse(conversationA.messages.isEmpty)
        XCTAssertTrue(conversationB.messages.isEmpty, "不同 session 的消息不得串线")
        XCTAssertEqual(store.count, 2)
    }

    /// Local 与 Remote session（不同 UUID）各自独立——store 只按 UUID 键，
    /// 对 session kind 天然不敏感。
    func testLocalAndRemoteConversationsAreIndependent() {
        let store = AgentConversationStore()
        let localConversation = store.conversation(for: UUID())
        let remoteConversation = store.conversation(for: UUID())

        localConversation.append(AgentMessage(role: .user, content: "local message"))
        remoteConversation.append(AgentMessage(role: .user, content: "remote message"))

        XCTAssertEqual(localConversation.messages.first?.text, "local message")
        XCTAssertEqual(remoteConversation.messages.first?.text, "remote message")
    }

    func testRemoveConversation() {
        let store = AgentConversationStore()
        let sessionID = UUID()
        _ = store.conversation(for: sessionID)

        store.removeConversation(for: sessionID)

        XCTAssertNil(store.existingConversation(for: sessionID))
        XCTAssertEqual(store.count, 0)
    }

    func testRemoveConversationCancelsGeneration() async {
        let store = AgentConversationStore()
        let sessionID = UUID()
        let conversation = store.conversation(for: sessionID)

        let generationFinished = expectation(description: "generation task finished after cancel")
        let task = Task<Void, Never> {
            // 挂起直到被取消。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            generationFinished.fulfill()
        }
        conversation.beginGeneration(task, generationID: UUID())
        XCTAssertTrue(conversation.isGenerating)

        store.removeConversation(for: sessionID)

        await fulfillment(of: [generationFinished], timeout: 2)
        XCTAssertTrue(task.isCancelled, "移除 conversation 必须取消其生成任务")
        XCTAssertNil(store.existingConversation(for: sessionID))
    }

    /// 生成状态 per-session 隔离：A 生成中不影响 B。
    func testGenerationStateIsolation() {
        let store = AgentConversationStore()
        let conversationA = store.conversation(for: UUID())
        let conversationB = store.conversation(for: UUID())

        let task = Task<Void, Never> {}
        conversationA.beginGeneration(task, generationID: UUID())

        XCTAssertTrue(conversationA.isGenerating)
        XCTAssertFalse(conversationB.isGenerating)

        conversationA.endGeneration()
        XCTAssertFalse(conversationA.isGenerating)
        XCTAssertNil(conversationA.generationTask)
    }
}
