import Foundation
import XCTest

@testable import MacSSH

/// B4 §67/§68/§69/§84–§86：Agent tool loop 端到端测试（ViewModel 级）。
///
/// 覆盖：
/// - 0/1/2/多 tool 轮次、串行执行顺序、10 轮上限与第 11 轮终止；
/// - 可恢复 tool error（outside scope 等）作为 result 继续；
/// - unknown tool / invalid arguments 本地拒绝；
/// - fatal sessionUnavailable 安全收尾；
/// - Stop 全链（streaming / tool 执行中 / tool 后 continuation 前）
///   与 late events 隔离；
/// - Local A/B、Remote A/B、Local/Remote 会话隔离（scope / backend /
///   conversation / card 全保持 origin）；
/// - B1/B3 read scope enforcement 不被 B4 wiring 绕开；
/// - tool result 可见性先于数据外发（§37/§84）；
/// - 无隐藏 prefetch（§85）、result 不放大 B2/B3 bounds（§86）。
@MainActor
final class AgentToolLoopTests: XCTestCase {

    // MARK: - Fixture

    private var base = ""
    private var directoryA = ""
    private var directoryB = ""

    private var localSessionA = UUID()
    private var localSessionB = UUID()
    private var remoteSessionA = UUID()
    private var remoteSessionB = UUID()

    private var sessions: [UUID: ManagedTerminalSession] = [:]
    private var handles: [UUID: AgentTerminalSessionHandle] = [:]
    private var services: [UUID: AgentRemoteReadOnlyFileService] = [:]

    private var fakeRemoteA: FakeAgentRemoteFileSystem!
    private var fakeRemoteB: FakeAgentRemoteFileSystem!

    private var router: AgentToolRouter!
    private var resolver: LoopRemoteResolver!

    private final class LoopRemoteResolver: AgentRemoteReadOnlyServiceResolving {
        private let lookup: (UUID) -> AgentRemoteReadOnlyFileService?
        private(set) var lookupCount = 0

        init(lookup: @escaping @MainActor (UUID) -> AgentRemoteReadOnlyFileService?) {
            self.lookup = lookup
        }

        func remoteFileService(for sessionID: UUID) -> AgentRemoteReadOnlyFileService? {
            lookupCount += 1
            return lookup(sessionID)
        }
    }

    /// 可控 buffer fixture。
    private final class FixtureBufferSource: AgentTerminalBufferSource {
        let lines: [String]
        init(_ lines: [String]) { self.lines = lines }
        var rows: Int { max(24, lines.count) }
        var columns: Int { 80 }
        var isAlternateScreen: Bool { false }
        var selectedText: String? { nil }
        var firstValidRow: Int { 0 }
        func line(atScrollInvariantRow row: Int) -> AgentTerminalLine? {
            guard row >= 0, row < lines.count else { return nil }
            return AgentTerminalLine(text: lines[row], isWrapped: false)
        }
    }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSSH.B4Loop.\(UUID().uuidString)", isDirectory: true)
            .path
        directoryA = base + "/A"
        directoryB = base + "/B"
        for directory in [directoryA, directoryB] {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
        }
        try "content-A".write(
            toFile: directoryA + "/file.txt", atomically: true, encoding: .utf8
        )
        try "content-B".write(
            toFile: directoryB + "/file.txt", atomically: true, encoding: .utf8
        )
        try "sub-A".write(
            toFile: directoryA + "/sub.txt", atomically: true, encoding: .utf8
        )
        // scope 外 fixture（B4 wiring 不得绕开 B1 containment）。
        let outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "TOP-SECRET".write(
            toFile: outside + "/secret.txt", atomically: true, encoding: .utf8
        )
        // symlink escape fixture。
        try? FileManager.default.createSymbolicLink(
            atPath: directoryA + "/escape",
            withDestinationPath: outside
        )

        // ManagedTerminalSession.id 由构造方生成——所有 key 必须使用
        // 真实 id（不得用自造 UUID 做索引）。
        let sessionLA = ManagedTerminalSession(
            localService: LocalTerminalService(session: TerminalSession(shellPath: "/bin/zsh")),
            baseTitle: "Local", titleCounter: 1
        )
        let sessionLB = ManagedTerminalSession(
            localService: LocalTerminalService(session: TerminalSession(shellPath: "/bin/zsh")),
            baseTitle: "Local", titleCounter: 2
        )
        let sessionRA = ManagedTerminalSession(
            remoteHostID: UUID(), hostDisplayName: "RemoteA", hostname: "a.example",
            port: 22, baseTitle: "RemoteA", titleCounter: 3
        )
        let sessionRB = ManagedTerminalSession(
            remoteHostID: UUID(), hostDisplayName: "RemoteB", hostname: "b.example",
            port: 22, baseTitle: "RemoteB", titleCounter: 4
        )
        localSessionA = sessionLA.id
        localSessionB = sessionLB.id
        remoteSessionA = sessionRA.id
        remoteSessionB = sessionRB.id
        sessions = [
            localSessionA: sessionLA,
            localSessionB: sessionLB,
            remoteSessionA: sessionRA,
            remoteSessionB: sessionRB,
        ]

        fakeRemoteA = FakeAgentRemoteFileSystem()
        fakeRemoteB = FakeAgentRemoteFileSystem()
        await fakeRemoteA.addDirectory("/")
        await fakeRemoteA.addDirectory("/srv")
        await fakeRemoteA.addDirectory("/srv/A")
        await fakeRemoteA.addFile("/srv/A/file.txt", "remote-content-A")
        await fakeRemoteB.addDirectory("/")
        await fakeRemoteB.addDirectory("/srv")
        await fakeRemoteB.addDirectory("/srv/B")
        await fakeRemoteB.addFile("/srv/B/file.txt", "remote-content-B")

        handles = [
            localSessionA: Self.localHandle(
                id: localSessionA, directory: directoryA, output: "output-A"
            ),
            localSessionB: Self.localHandle(
                id: localSessionB, directory: directoryB, output: "output-B"
            ),
            remoteSessionA: Self.remoteHandle(id: remoteSessionA, directory: "/srv/A"),
            remoteSessionB: Self.remoteHandle(id: remoteSessionB, directory: "/srv/B"),
        ]
        services = [
            remoteSessionA: AgentRemoteReadOnlyFileService(client: fakeRemoteA),
            remoteSessionB: AgentRemoteReadOnlyFileService(client: fakeRemoteB),
        ]
        resolver = LoopRemoteResolver { [weak self] id in
            self?.services[id]
        }
        router = AgentToolRouter(
            sessionProvider: TerminalAgentContextProvider(handleLookup: { [weak self] id in
                self?.handles[id]
            }),
            remoteServiceResolver: resolver
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    private static func localHandle(
        id: UUID,
        directory: String,
        output: String
    ) -> AgentTerminalSessionHandle {
        AgentTerminalSessionHandle(
            id: id,
            sessionKind: .local,
            displayName: "Local",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directory)"),
            bufferSource: FixtureBufferSource([output])
        )
    }

    private static func remoteHandle(id: UUID, directory: String) -> AgentTerminalSessionHandle {
        AgentTerminalSessionHandle(
            id: id,
            sessionKind: .remoteSSH,
            displayName: "remote",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directory)"),
            bufferSource: FixtureBufferSource(["remote-output"])
        )
    }

    // MARK: - Scripted provider

    /// 简易门：把 provider 事件产出时机交给测试（late-event 测试）。
    private actor LoopGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
        }
    }

    private final class LoopScriptedProvider: AgentProvider, @unchecked Sendable {
        enum Round {
            case events([AgentEvent])
            case failure(Error)
            /// 产出给定事件后长期挂起（Stop / 取消测试）。
            case eventsThenHang([AgentEvent])
            /// 等 gate 打开后产出事件（late-event / §48 测试）。
            case gatedEvents([AgentEvent], LoopGate)
        }

        struct Call {
            let transcript: [AgentMessage]
            let tools: [AgentToolDefinition]
            let context: AgentSessionContext
        }

        // 全部交互发生在 MainActor（ViewModel / 测试）；producer Task 只
        // 使用创建时捕获的 round 值，不触碰实例状态——无需加锁。
        private(set) var calls: [Call] = []
        private var rounds: [Round]
        private(set) var snapshotCount = 0
        /// 若设置：snapshotForGeneration 返回该 provider（模拟冻结的
        /// 具体 provider 实例），后续 rounds 全部由它服务。
        var snapshotOverride: (any AgentProvider)?
        var configuration: AgentProviderConfigurationState = .ready

        init(rounds: [Round] = []) {
            self.rounds = rounds
        }

        func stream(
            transcript: [AgentMessage],
            tools: [AgentToolDefinition],
            context: AgentSessionContext
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            calls.append(Call(transcript: transcript, tools: tools, context: context))
            let round: Round
            if rounds.count > 1 {
                round = rounds.removeFirst()
            } else if let only = rounds.first {
                round = only
            } else {
                round = .events([.textDelta("reply"), .completed])
            }

            return AsyncThrowingStream { continuation in
                let producer = Task {
                    switch round {
                    case .events(let events):
                        for event in events {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                        continuation.finish()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    case .eventsThenHang(let events):
                        for event in events {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                        try? await Task.sleep(for: .seconds(60))
                        continuation.finish()
                    case .gatedEvents(let events, let gate):
                        await gate.wait()
                        for event in events {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in
                    producer.cancel()
                }
            }
        }

        func snapshotForGeneration() async throws -> any AgentProvider {
            snapshotCount += 1
            if let override = snapshotOverride { return override }
            return self
        }

        func configurationState() async -> AgentProviderConfigurationState {
            configuration
        }
    }

    /// 测试用 Session 框（切换 active session）。
    private final class SessionBox {
        var session: ManagedTerminalSession?
    }

    // MARK: - ViewModel 构造

    private func makeViewModel(
        provider: LoopScriptedProvider,
        box: SessionBox,
        store: AgentConversationStore = AgentConversationStore()
    ) -> AgentViewModel {
        AgentViewModel(
            store: store,
            provider: provider,
            toolRouter: router,
            remoteServiceResolver: resolver,
            activeSessionProvider: { box.session },
            allSessionsProvider: { box.session.map { [$0] } ?? [] },
            handleProvider: { [weak self] session in
                self?.handles[session.id]
                    ?? AgentTerminalSessionHandle(session: session)
            }
        )
    }

    private func send(
        _ text: String,
        in viewModel: AgentViewModel,
        box: SessionBox
    ) async throws -> AgentConversation {
        viewModel.ensureConversationForActiveSession()
        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = text
        viewModel.send()
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value
        return conversation
    }

    private func toolCall(
        _ callID: String = "call_1",
        name: String,
        argumentsJSON: String
    ) -> AgentEvent {
        .toolCall(
            AgentProviderToolCall(
                callID: callID,
                name: name,
                argumentsJSON: argumentsJSON
            )
        )
    }

    private func toolCards(in conversation: AgentConversation) -> [AgentMessage] {
        conversation.messages.filter { $0.toolActivity != nil }
    }

    /// 解析 structured tool result JSON（测试断言用）。
    private func resultJSON(of message: AgentMessage) throws -> [String: Any] {
        let activity = try XCTUnwrap(message.toolActivity)
        let data = try XCTUnwrap(activity.resultJSON?.data(using: .utf8))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("条件在 \(timeout)s 内未满足")
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 5,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("条件在 \(timeout)s 内未满足")
    }

    // MARK: - §67 基础轮次

    func testZeroToolCallCompletesNormally() async throws {
        let provider = LoopScriptedProvider(rounds: [.events([.textDelta("你好"), .completed])])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("hi", in: viewModel, box: box)

        XCTAssertEqual(provider.calls.count, 1, "0 tool call → 只有一轮请求")
        XCTAssertTrue(toolCards(in: conversation).isEmpty)
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages.last?.text, "你好")
        XCTAssertEqual(conversation.messages.last?.state, .complete)
        XCTAssertFalse(conversation.isGenerating)
    }

    func testSingleToolRoundExecutesThenContinuesWithResult() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                .textDelta("让我读取文件…"),
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .events([.textDelta("文件内容是 content-A"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("读文件", in: viewModel, box: box)

        XCTAssertEqual(provider.calls.count, 2, "tool round 后必须有 continuation")
        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 1)
        let result = try resultJSON(of: cards[0])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["text"] as? String, "content-A", "本地读取必须命中 A 目录 fixture")
        XCTAssertEqual(cards[0].toolActivity?.status, .success)

        // §37/§84：第二轮请求（数据外发）时，tool card 已带完整结果。
        let secondCall = provider.calls[1]
        XCTAssertEqual(secondCall.transcript.count, 3, "user + round-1 文本 + tool card")
        let cardInTranscript = try XCTUnwrap(
            secondCall.transcript.first(where: { $0.toolActivity != nil })
        )
        XCTAssertEqual(cardInTranscript.toolActivity?.status, .success)
        XCTAssertNotNil(cardInTranscript.toolActivity?.resultJSON)

        XCTAssertEqual(conversation.messages.last?.text, "文件内容是 content-A")
        XCTAssertEqual(conversation.messages.last?.state, .complete)
    }

    func testMultipleToolCallsSameRoundExecuteSeriallyInOrder() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall("call_1", name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                toolCall("call_2", name: "read_file", argumentsJSON: #"{"path":"sub.txt"}"#),
                .completed,
            ]),
            .events([.textDelta("两个都读完了"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("读两个文件", in: viewModel, box: box)

        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 2, "同 response 的多个 call 必须全部保留（§13）")
        XCTAssertEqual(cards[0].toolActivity?.callID, "call_1")
        XCTAssertEqual(cards[1].toolActivity?.callID, "call_2")
        let first = try resultJSON(of: cards[0])
        let second = try resultJSON(of: cards[1])
        XCTAssertEqual(first["text"] as? String, "content-A")
        XCTAssertEqual(second["text"] as? String, "sub-A")
        // §27：执行完所有 calls 后才一次性 continuation。
        XCTAssertEqual(provider.calls.count, 2)
        let transcriptCards = provider.calls[1].transcript.filter { $0.toolActivity != nil }
        XCTAssertEqual(transcriptCards.count, 2)
    }

    func testTwoSequentialToolRounds() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall("call_1", name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .events([
                toolCall("call_2", name: "list_directory", argumentsJSON: #"{"path":"."}"#),
                .completed,
            ]),
            .events([.textDelta("完成"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("两步操作", in: viewModel, box: box)

        XCTAssertEqual(provider.calls.count, 3)
        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].toolActivity?.status, .success)
        XCTAssertEqual(cards[1].toolActivity?.status, .success)
        let listing = try resultJSON(of: cards[1])
        XCTAssertEqual(listing["ok"] as? Bool, true)
        XCTAssertNotNil(listing["entries"])
        XCTAssertEqual(conversation.messages.last?.text, "完成")
    }

    func testTenRoundsAllowedEleventhRoundTerminated() async throws {
        // 11 个 tool-bearing rounds：前 10 个执行，第 11 个触发 hard cap。
        let rounds: [LoopScriptedProvider.Round] = (1...11).map { round in
            .events([
                toolCall(
                    "call_\(round)",
                    name: "read_file",
                    argumentsJSON: #"{"path":"file.txt"}"#
                ),
                .completed,
            ])
        }
        let provider = LoopScriptedProvider(rounds: rounds)
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("疯狂读取", in: viewModel, box: box)

        XCTAssertEqual(provider.calls.count, 11, "第 11 轮 provider response 必须已发生（随后终止）")
        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 11)
        for (index, card) in cards.enumerated() where index < 10 {
            XCTAssertEqual(card.toolActivity?.status, .success, "第 \(index + 1) 轮应执行")
        }
        XCTAssertEqual(cards[10].toolActivity?.status, .cancelled, "第 11 轮绝不执行")

        let failed = try XCTUnwrap(conversation.messages.last { $0.state == .failed })
        XCTAssertEqual(failed.failure, .toolRoundLimit)
        XCTAssertFalse(conversation.isGenerating, "超限后必须安全收尾")
    }

    // MARK: - §28 tool errors are results

    func testOutsideScopeErrorBecomesResultAndGenerationContinues() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"/etc/hosts"}"#),
                .completed,
            ]),
            .events([.textDelta("我无法读取该路径。"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("读 /etc/hosts", in: viewModel, box: box)

        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 1)
        let result = try resultJSON(of: cards[0])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "outsideAllowedReadScope")
        XCTAssertEqual(cards[0].toolActivity?.status, .failure)
        XCTAssertEqual(provider.calls.count, 2, "普通 tool error 必须继续（§28）")
        XCTAssertEqual(conversation.messages.last?.text, "我无法读取该路径。")
        XCTAssertEqual(conversation.messages.last?.state, .complete)
    }

    func testUnknownToolIsRejectedAsResult() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "run_command", argumentsJSON: #"{"command":"git status"}"#),
                .completed,
            ]),
            .events([.textDelta("我无法执行命令。"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("执行 git status", in: viewModel, box: box)

        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 1, "未知工具必须产生可见 card（绝不静默）")
        let result = try resultJSON(of: cards[0])
        XCTAssertEqual(result["error"] as? String, "unknownTool")
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testInvalidArgumentsBecomeResult() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: "{}"),
                .completed,
            ]),
            .events([.textDelta("参数不合法。"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("读文件", in: viewModel, box: box)

        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 1)
        let result = try resultJSON(of: cards[0])
        XCTAssertEqual(result["error"] as? String, "invalidArguments")
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testSessionUnavailableFailsGenerationSafely() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "get_terminal_context", argumentsJSON: "{}"),
                .completed,
            ]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        // router 句柄表删掉该 session → sessionUnavailable。
        handles[localSessionA] = nil
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("看一下终端", in: viewModel, box: box)

        XCTAssertEqual(provider.calls.count, 1, "sessionUnavailable 属于无法继续，不得 continuation")
        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 1)
        let result = try resultJSON(of: cards[0])
        XCTAssertEqual(result["error"] as? String, "sessionUnavailable")
        let failed = try XCTUnwrap(conversation.messages.last { $0.state == .failed })
        XCTAssertEqual(failed.failure, .sessionUnavailable)
        XCTAssertFalse(conversation.isGenerating)
    }

    // MARK: - §45/§46/§47/§48 Stop

    func testStopBeforeToolExecutionPreventsExecution() async throws {
        // provider 产出 toolCall 后挂起：Stop 落在「call 已返回、执行前」；
        // 第二轮脚本用于验证 Stop 后仍可发送新消息。
        let provider = LoopScriptedProvider(rounds: [
            .eventsThenHang([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
            ]),
            .events([.textDelta("recovered"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        viewModel.ensureConversationForActiveSession()
        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "读文件"
        viewModel.send()
        let task = try XCTUnwrap(conversation.generationTask)

        try await waitUntil { conversation.messages.contains { $0.toolActivity != nil } }
        viewModel.stop()
        await task.value

        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].toolActivity?.status, .cancelled, "§45：Stop 后绝不执行 tool")
        let result = try resultJSON(of: cards[0])
        XCTAssertEqual(result["error"] as? String, "cancelled")
        XCTAssertEqual(provider.calls.count, 1, "不得 continuation")
        XCTAssertFalse(conversation.isGenerating)

        // Stop 后仍可发送新消息（§44 恢复性）。
        conversation.draft = "再来一次"
        viewModel.send()
        if let nextTask = conversation.generationTask {
            await nextTask.value
        }
        XCTAssertFalse(conversation.isGenerating)
    }

    func testStopDuringRemoteToolExecutionPropagatesCancellation() async throws {
        // Remote 会话 + 分块延迟：把「读进行中」窗口拉长到可确定取消。
        await fakeRemoteA.setChunkSize(4)
        await fakeRemoteA.setChunkDelay(nanoseconds: 150_000_000)
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .events([.textDelta("不该出现的第二轮"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[remoteSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        viewModel.ensureConversationForActiveSession()
        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "读远端文件"
        viewModel.send()
        let task = try XCTUnwrap(conversation.generationTask)

        // 等待真实进入 SFTP 读（chunk 计数 > 0）后取消。
        try await waitUntilAsync { await self.fakeRemoteA.readCallCount > 0 }
        viewModel.stop()
        await task.value

        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].toolActivity?.status, .cancelled, "§46：取消必须传播到 backend")
        XCTAssertEqual(provider.calls.count, 1, "§47：Stop 后绝不发送下一轮 request")
        XCTAssertFalse(conversation.isGenerating)

        let remoteOpenCount = await fakeRemoteA.openCount
        XCTAssertGreaterThan(remoteOpenCount, 0, "读确实进行过")
        let closeCount = await fakeRemoteA.closeCount
        XCTAssertEqual(closeCount, remoteOpenCount, "§39/§75：取消路径也必须关闭句柄")
    }

    func testLateProviderEventsAfterStopDoNotLeak() async throws {
        let gate = LoopGate()
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .gatedEvents([.textDelta("late-"), .completed], gate),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        viewModel.ensureConversationForActiveSession()
        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = "读文件"
        viewModel.send()
        let task = try XCTUnwrap(conversation.generationTask)

        // 等待第二轮请求已发出（late 事件尚未产出，gate 未开）后 Stop。
        try await waitUntil { provider.calls.count == 2 }
        viewModel.stop()
        await task.value

        let countAfterStop = conversation.messages.count
        // Stop 之后才让旧 stream 产出 late 事件。
        await gate.open()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            conversation.messages.count,
            countAfterStop,
            "§48：取消后到达的 SSE 绝不写入 conversation"
        )
        XCTAssertFalse(conversation.isGenerating)
        XCTAssertFalse(
            conversation.messages.contains { $0.text == "late-" },
            "late delta 必须被丢弃"
        )
    }

    // MARK: - §67 Provider failure after tool

    func testProviderFailureAfterToolKeepsToolResultAndFails() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .failure(AgentProviderError.serverError(statusCode: 500)),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("读文件", in: viewModel, box: box)

        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].toolActivity?.status, .success, "已执行的 tool 结果保留")
        let failed = try XCTUnwrap(conversation.messages.last { $0.state == .failed })
        XCTAssertEqual(failed.failure, .server)
        XCTAssertFalse(conversation.isGenerating)
    }

    // MARK: - §54/§55 generation provider 快照

    func testGenerationUsesFrozenProviderSnapshotForAllRounds() async throws {
        let outer = LoopScriptedProvider(rounds: [])
        let frozen = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .events([.textDelta("done"), .completed]),
        ])
        outer.snapshotOverride = frozen
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: outer, box: box)

        _ = try await send("读文件", in: viewModel, box: box)

        XCTAssertEqual(outer.snapshotCount, 1, "每个 generation 只解析一次 provider 快照")
        XCTAssertTrue(outer.calls.isEmpty, "所有轮次必须走冻结实例，绝不重新解析")
        XCTAssertEqual(frozen.calls.count, 2)
    }

    // MARK: - §42/§68 会话隔离

    func testLocalABIsolationKeepsScopeBackendConversationAndCardOnOrigin() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .eventsThenHang([.textDelta("A-done")]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        viewModel.ensureConversationForActiveSession()
        let conversationA = try XCTUnwrap(viewModel.activeConversation)
        conversationA.draft = "读取 file.txt"
        viewModel.send()
        let taskA = try XCTUnwrap(conversationA.generationTask)

        // §42：tool 执行 / continuation 期间切到 Local B。
        box.session = sessions[localSessionB]
        viewModel.ensureConversationForActiveSession()
        let conversationB = try XCTUnwrap(viewModel.activeConversation)
        XCTAssertFalse(conversationA === conversationB)

        // A 的第二轮文本到达（B 已激活），随后取消 A 的 generation。
        try await waitUntil { conversationA.messages.last?.text == "A-done" }
        conversationA.cancelGeneration()
        await taskA.value

        let cards = toolCards(in: conversationA)
        XCTAssertEqual(cards.count, 1, "§42：card 只出现在 A")
        let result = try resultJSON(of: cards[0])
        XCTAssertEqual(result["text"] as? String, "content-A", "必须读 A 的 scope/backend")
        XCTAssertEqual(conversationA.messages.last?.text, "A-done", "回答只出现在 A")
        XCTAssertEqual(conversationA.messages.last?.state, .complete, "Stop 保留 partial")
        XCTAssertTrue(conversationB.isEmpty, "B 绝不出现 A 的 card / 回答 / 消息")
        XCTAssertFalse(conversationA.isGenerating)
    }

    func testRemoteABIsolationUsesOriginBackendOnly() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .events([.textDelta("remote-A-done"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[remoteSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        viewModel.ensureConversationForActiveSession()
        let conversationA = try XCTUnwrap(viewModel.activeConversation)
        conversationA.draft = "读远端文件"
        viewModel.send()
        let taskA = try XCTUnwrap(conversationA.generationTask)

        box.session = sessions[remoteSessionB]
        viewModel.ensureConversationForActiveSession()
        let conversationB = try XCTUnwrap(viewModel.activeConversation)

        await taskA.value

        let cards = toolCards(in: conversationA)
        let result = try resultJSON(of: cards[0])
        XCTAssertEqual(result["text"] as? String, "remote-content-A", "只能读 origin session 的远端后端")
        XCTAssertTrue(conversationB.isEmpty)
        let readsB = await fakeRemoteB.readCallCount
        XCTAssertEqual(readsB, 0, "B 的后端绝不被触碰")
        let canonicalB = await fakeRemoteB.canonicalCallCount
        XCTAssertLessThanOrEqual(canonicalB, 0, "B 的 canonicalize 也不发生")
    }

    func testLocalRemoteCrossIsolation() async throws {
        let providerLocal = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .events([.textDelta("local-done"), .completed]),
        ])
        let providerRemote = LoopScriptedProvider(rounds: [
            .events([
                toolCall(name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#),
                .completed,
            ]),
            .events([.textDelta("remote-done"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModelLocal = makeViewModel(provider: providerLocal, box: box)

        let localConversation = try await send("读本地", in: viewModelLocal, box: box)
        let localResult = try resultJSON(of: toolCards(in: localConversation)[0])
        XCTAssertEqual(localResult["text"] as? String, "content-A")

        box.session = sessions[remoteSessionB]
        let viewModelRemote = makeViewModel(provider: providerRemote, box: box)
        let remoteConversation = try await send("读远端", in: viewModelRemote, box: box)
        let remoteResult = try resultJSON(of: toolCards(in: remoteConversation)[0])
        XCTAssertEqual(remoteResult["text"] as? String, "remote-content-B")

        XCTAssertFalse(localConversation === remoteConversation)
        let readsA = await fakeRemoteA.readCallCount
        XCTAssertEqual(readsA, 0, "Local 会话绝不触碰任何远端后端")
    }

    // MARK: - §69 read scope enforcement 不被 B4 wiring 绕开

    func testReadScopeEnforcementThroughLoop() async throws {
        // 同一 Local A scope 下依次验证：相对命中 / 绝对命中 / ../ 逃逸 /
        // 绝对越界 / symlink 逃逸 / cwd unavailable。
        let provider = LoopScriptedProvider(rounds: [
            .events([toolCall("c1", name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#), .completed]),
            .events([toolCall("c2", name: "read_file", argumentsJSON: #"{"path":"\#(directoryA)/sub.txt"}"#), .completed]),
            .events([toolCall("c3", name: "read_file", argumentsJSON: #"{"path":"../outside/secret.txt"}"#), .completed]),
            .events([toolCall("c4", name: "read_file", argumentsJSON: #"{"path":"\#(base)/outside/secret.txt"}"#), .completed]),
            .events([toolCall("c5", name: "read_file", argumentsJSON: #"{"path":"escape/secret.txt"}"#), .completed]),
            .events([.textDelta("summary"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("侦察", in: viewModel, box: box)

        let cards = toolCards(in: conversation)
        XCTAssertEqual(cards.count, 5)
        // c1/c2 命中。
        XCTAssertEqual(try resultJSON(of: cards[0])["text"] as? String, "content-A")
        XCTAssertEqual(try resultJSON(of: cards[1])["text"] as? String, "sub-A")
        // c3/c4/c5 全部拒绝，且正文绝不泄漏（P1 gate）。
        for index in 2...4 {
            let result = try resultJSON(of: cards[index])
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["error"] as? String, "outsideAllowedReadScope")
            XCTAssertFalse(
                String(describing: result).contains("TOP-SECRET"),
                "越界请求绝不得泄漏正文"
            )
        }

        // cwd unavailable：空 roots 拒绝一切（§34/§35）。
        let providerNoCwd = LoopScriptedProvider(rounds: [
            .events([toolCall("c1", name: "read_file", argumentsJSON: #"{"path":"file.txt"}"#), .completed]),
            .events([.textDelta("nope"), .completed]),
        ])
        handles[localSessionB] = AgentTerminalSessionHandle(
            id: localSessionB,
            sessionKind: .local,
            displayName: "Local",
            workingDirectory: .unavailable,
            bufferSource: FixtureBufferSource(["x"])
        )
        box.session = sessions[localSessionB]
        let viewModelNoCwd = makeViewModel(provider: providerNoCwd, box: box)
        let conversationNoCwd = try await send("读文件", in: viewModelNoCwd, box: box)
        let noCwdResult = try resultJSON(of: toolCards(in: conversationNoCwd)[0])
        XCTAssertEqual(noCwdResult["ok"] as? Bool, false)
        XCTAssertTrue(
            ["cwdUnavailable", "outsideAllowedReadScope"].contains(noCwdResult["error"] as? String ?? ""),
            "cwd 不可用必须安全拒绝，实际：\(noCwdResult)"
        )
        XCTAssertFalse(String(describing: noCwdResult).contains("content-B"))
    }

    // MARK: - §85 无隐藏 prefetch

    func testNoHiddenPrefetchWhenNoToolCall() async throws {
        let provider = LoopScriptedProvider(rounds: [
            .events([.textDelta("纯文本回答"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[remoteSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        await fakeRemoteA.resetCounters()

        _ = try await send("你好", in: viewModel, box: box)

        // 唯一允许的 generation-start 文件操作 = Remote scope canonicalize。
        let counts = await fakeRemoteA.callCounts()
        XCTAssertEqual(counts.stat, 0, "不得预取 stat")
        XCTAssertEqual(counts.list, 0, "不得预取目录")
        let reads = await fakeRemoteA.readCallCount
        XCTAssertEqual(reads, 0, "不得预取文件内容")
        XCTAssertEqual(counts.canonical, 1, "只允许 scope canonicalization 一次")
    }

    // MARK: - §86 result 不放大 bounds

    func testFileAndDirectoryResultsStayBounded() async throws {
        // 600 个条目目录 + 300 KiB 文件（必须在 A scope root 内）。
        let bigDirectory = directoryA + "/big"
        try FileManager.default.createDirectory(atPath: bigDirectory, withIntermediateDirectories: true)
        for index in 0..<600 {
            _ = FileManager.default.createFile(
                atPath: bigDirectory + "/f\(String(format: "%04d", index)).dat",
                contents: Data()
            )
        }
        let bigText = String(repeating: "a", count: 300 * 1024)
        try bigText.write(toFile: bigDirectory + "/big.txt", atomically: true, encoding: .utf8)

        let provider = LoopScriptedProvider(rounds: [
            .events([toolCall("c1", name: "read_file", argumentsJSON: #"{"path":"big/big.txt"}"#), .completed]),
            .events([toolCall("c2", name: "list_directory", argumentsJSON: #"{"path":"big"}"#), .completed]),
            .events([.textDelta("done"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessions[localSessionA]
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try await send("读大文件", in: viewModel, box: box)
        let cards = toolCards(in: conversation)

        let fileResult = try resultJSON(of: cards[0])
        XCTAssertEqual(fileResult["truncated"] as? Bool, true)
        let bytesReturned = try XCTUnwrap(fileResult["bytesReturned"] as? Int)
        XCTAssertLessThanOrEqual(bytesReturned, 256 * 1024, "§32：≤256 KiB，绝不放大")

        let listing = try resultJSON(of: cards[1])
        XCTAssertEqual(listing["truncated"] as? Bool, true)
        let entries = try XCTUnwrap(listing["entries"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(entries.count, 500, "§33：≤500 entries，绝不放大")
        XCTAssertEqual(listing["totalEntryCount"] as? Int, 601)
    }
}
