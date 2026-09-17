import Foundation
import XCTest
@preconcurrency import SwiftTerm

@testable import MacSSH

/// Phase 10F-B4-S1 §16/§24–§29/§42–§56/§61：send_to_terminal 的 Agent loop
/// 端到端集成（ViewModel 级）。
///
/// 覆盖：
/// - proposal pause（awaitingApproval + 冻结 request + 0 字节）；
/// - approval resume → Local/Remote 交付 → sanitized result → continuation；
/// - Deny / pending Stop / 双击审批 / **replay 同一 callID** 零重复副作用；
/// - Target switch / Local replacement / Remote reconnect → 0 字节到替换目标；
/// - partial / uncertain → loop halt（无自动 Provider continuation）；
/// - bracket mode ON / OFF 的 loop 级结果（复用 B2 framing）；
/// - 真实 Local /bin/cat 与 deterministic Remote seam 的 E2E；
/// - 仅 `.awaitingApproval` 存在审批按钮（运行中无二次审批机会）。
@MainActor
final class AgentToolLoopSendToTerminalTests: XCTestCase {

    // MARK: - Fixtures

    private var sessionA: ManagedTerminalSession!
    private var sessionB: ManagedTerminalSession!
    private var remoteSession: ManagedTerminalSession!

    private var endpoints: [UUID: AgentTerminalMutationEndpointCapability] = [:]
    private var localTransports: [UUID: FakeLocalMutationTransport] = [:]
    private var localModes: [UUID: ModeBox] = [:]
    private var remoteTransports: [UUID: FakeRemoteMutationTransport] = [:]

    private var router: AgentToolRouter!

    override func setUp() async throws {
        sessionA = ManagedTerminalSession(
            localService: LocalTerminalService(session: TerminalSession(shellPath: "/bin/zsh")),
            baseTitle: "Local",
            titleCounter: 1
        )
        sessionB = ManagedTerminalSession(
            localService: LocalTerminalService(session: TerminalSession(shellPath: "/bin/zsh")),
            baseTitle: "Local",
            titleCounter: 2
        )
        remoteSession = ManagedTerminalSession(
            remoteHostID: UUID(),
            hostDisplayName: "Remote A",
            hostname: "a.example",
            port: 22,
            baseTitle: "RemoteA",
            titleCounter: 3
        )
        router = AgentToolRouter(
            sessionProvider: TerminalAgentContextProvider(handleLookup: { [weak self] id in
                self?.handle(for: id)
            })
        )
    }

    private func handle(for sessionID: UUID) -> AgentTerminalSessionHandle? {
        guard let session = allSessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return AgentTerminalSessionHandle(session: session)
    }

    private var allSessions: [ManagedTerminalSession] {
        [sessionA, sessionB, remoteSession].compactMap { $0 }
    }

    // MARK: - Endpoint installation

    @discardableResult
    private func installLocalEndpoint(
        for sessionID: UUID,
        mode: Bool = false,
        epoch: AgentTerminalInputTargetEpoch = 1
    ) -> FakeLocalMutationTransport {
        let transport = FakeLocalMutationTransport()
        let modeBox = ModeBox(mode)
        endpoints[sessionID] = .local(makeLocalEndpoint(
            sessionID: sessionID,
            transport: transport,
            modeBox: modeBox,
            epoch: epoch
        ))
        localTransports[sessionID] = transport
        localModes[sessionID] = modeBox
        return transport
    }

    private func makeLocalEndpoint(
        sessionID: UUID,
        transport: FakeLocalMutationTransport,
        modeBox: ModeBox,
        epoch: AgentTerminalInputTargetEpoch
    ) -> AgentLocalTerminalMutationEndpoint {
        AgentLocalTerminalMutationEndpoint(
            logicalSessionID: sessionID,
            inputTargetEpoch: epoch,
            endpointToken: AgentTerminalEndpointToken.generate(),
            transport: transport,
            modeSnapshotProvider: { modeBox.read() }
        )
    }

    private func makeRemoteEndpoint(
        sessionID: UUID,
        transport: FakeRemoteMutationTransport,
        modeBox: ModeBox,
        hostDisplayName: String = "Remote A",
        epoch: AgentTerminalInputTargetEpoch = 1
    ) -> AgentRemoteTerminalMutationEndpoint {
        AgentRemoteTerminalMutationEndpoint(
            logicalSessionID: sessionID,
            inputTargetEpoch: epoch,
            endpointToken: AgentTerminalEndpointToken.generate(),
            hostDisplayName: hostDisplayName,
            transport: transport,
            modeSnapshotProvider: { modeBox.read() }
        )
    }

    @discardableResult
    private func installRemoteEndpoint(
        for sessionID: UUID,
        mode: Bool = false,
        hostDisplayName: String = "Remote A",
        epoch: AgentTerminalInputTargetEpoch = 1
    ) -> FakeRemoteMutationTransport {
        let transport = FakeRemoteMutationTransport()
        let modeBox = ModeBox(mode)
        endpoints[sessionID] = .remote(makeRemoteEndpoint(
            sessionID: sessionID,
            transport: transport,
            modeBox: modeBox,
            hostDisplayName: hostDisplayName,
            epoch: epoch
        ))
        remoteTransports[sessionID] = transport
        return transport
    }

    // MARK: - ViewModel

    private final class SessionBox {
        var session: ManagedTerminalSession?
    }

    private func makeViewModel(
        provider: ScriptedProvider,
        box: SessionBox
    ) -> AgentViewModel {
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        return AgentViewModel(
            store: AgentConversationStore(),
            provider: provider,
            toolRouter: router,
            mutationApprovalCoordinator: coordinator,
            localMutationExecutor: AgentLocalTerminalMutationExecutor(
                approvalCoordinator: coordinator
            ),
            remoteMutationExecutor: AgentRemoteTerminalMutationExecutor(
                approvalCoordinator: coordinator
            ),
            mutationEndpointProvider: { [weak self] sessionID in
                self?.endpoints[sessionID]
            },
            activeSessionProvider: { box.session },
            allSessionsProvider: { [weak self] in self?.allSessions ?? [] },
            handleProvider: { [weak self] session in
                self?.handle(for: session.id) ?? AgentTerminalSessionHandle(session: session)
            }
        )
    }

    // MARK: - Helpers

    private func toolCall(
        _ callID: String = "call_1",
        text: String,
        submit: Bool
    ) -> AgentEvent {
        let arguments = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "submit": submit,
        ])
        return .toolCall(
            AgentProviderToolCall(
                callID: callID,
                name: "send_to_terminal",
                argumentsJSON: String(decoding: arguments ?? Data(), as: UTF8.self)
            )
        )
    }

    private func beginSend(
        _ text: String,
        in viewModel: AgentViewModel
    ) throws -> AgentConversation {
        viewModel.ensureConversationForActiveSession()
        let conversation = try XCTUnwrap(viewModel.activeConversation)
        conversation.draft = text
        viewModel.send()
        return conversation
    }

    private func toolCard(
        in conversation: AgentConversation
    ) throws -> AgentMessage {
        try XCTUnwrap(conversation.messages.first { $0.toolActivity != nil })
    }

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

    // MARK: - §16/§12 proposal pause

    func testProposalPausesAtAwaitingApprovalWithFrozenRequestAndZeroBytes() async throws {
        let transport = installLocalEndpoint(for: sessionA.id)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "printf 'A'", submit: true), .completed]),
            .events([.textDelta("continued"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }

        let card = try toolCard(in: conversation)
        let activity = try XCTUnwrap(card.toolActivity)
        let request = try XCTUnwrap(activity.mutationRequest)
        XCTAssertEqual(request.text, "printf 'A'")
        XCTAssertEqual(request.submit, true)
        XCTAssertEqual(request.logicalSessionID, sessionA.id)
        XCTAssertEqual(request.targetSnapshot, .local)

        // §12/§13：proposal 阶段 0 字节；approval 未决定前无任何 transaction。
        XCTAssertEqual(transport.transactionCount, 0)
        XCTAssertEqual(transport.physicalBytes, [])
        XCTAssertEqual(provider.calls.count, 1, "审批等待期间不得发起 continuation")

        // 收尾（Deny 保持零副作用）。
        viewModel.denyCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value
    }

    // MARK: - §30/§31/§28 approval resume + sanitized result + continuation

    func testApprovalResumesLocalDeliveryAndSerializerReportsTransportFacts() async throws {
        let transport = installLocalEndpoint(for: sessionA.id, mode: false)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo hi", submit: true), .completed]),
            .events([.textDelta("已发送"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        let card = try toolCard(in: conversation)

        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
        XCTAssertEqual(activity.status, .success)
        XCTAssertEqual(transport.transactionCount, 1)
        XCTAssertEqual(transport.physicalBytes, Array("echo hi".utf8) + [0x0D])

        let result = try resultJSON(of: toolCard(in: conversation))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["status"] as? String, "delivered")
        XCTAssertEqual(result["terminalKind"] as? String, "local")
        XCTAssertEqual(result["payloadBytesRequested"] as? Int, 7)
        XCTAssertEqual(result["payloadBytesAccepted"] as? Int, 7)
        XCTAssertEqual(result["submitBytesAccepted"] as? Int, 1)
        XCTAssertEqual(result["transportSubmitted"] as? Bool, true)

        // §53：交付完成 → 允许一次 continuation（sanitized transport 结果）。
        XCTAssertEqual(provider.calls.count, 2)
        if provider.calls.count == 2 {
            let toolMessages = provider.calls[1].transcript.filter { $0.toolActivity != nil }
            XCTAssertEqual(toolMessages.count, 1)
            XCTAssertTrue(toolMessages[0].toolActivity?.resultJSON?.contains("\"delivered\"") == true)
        }
        XCTAssertEqual(conversation.isGenerating, false)
    }

    func testSubmitFalseNeverAppendsCarriageReturnThroughLoop() async throws {
        let transport = installLocalEndpoint(for: sessionA.id, mode: false)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo hi\n", submit: false), .completed]),
            .events([.textDelta("ok"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        viewModel.approveCommand(
            cardID: try toolCard(in: conversation).id,
            sessionID: conversation.sessionID
        )
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        XCTAssertEqual(transport.physicalBytes, Array("echo hi\n".utf8))
        let result = try resultJSON(of: toolCard(in: conversation))
        XCTAssertEqual(result["transportSubmitted"] as? Bool, false)
        XCTAssertEqual(result["submitBytesAccepted"] as? Int, 0)
    }

    // MARK: - §45 Deny

    func testDenyInvalidatesProposalWithZeroBytesAndStableUserDenied() async throws {
        let transport = installLocalEndpoint(for: sessionA.id)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo hi", submit: true), .completed]),
            .events([.textDelta("已按你的选择跳过"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        let card = try toolCard(in: conversation)
        viewModel.denyCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
        XCTAssertEqual(activity.status, .denied)
        XCTAssertEqual(
            activity.resultJSON,
            AgentToolResultSerializer.userDeniedOutput
        )
        XCTAssertEqual(transport.transactionCount, 0)
        XCTAssertEqual(transport.physicalBytes, [])
        // Denial 允许 textual continuation（§30/§54：绝不无限重提同一调用）。
        XCTAssertEqual(provider.calls.count, 2)
        let allCards = conversation.messages.filter { $0.toolActivity != nil }
        XCTAssertEqual(allCards.count, 1, "同一 generation 不得自动重提相同调用")
    }

    // MARK: - §46 pending Stop

    func testStopWhilePendingInvalidatesProposalWithZeroBytes() async throws {
        let transport = installLocalEndpoint(for: sessionA.id)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo hi", submit: true), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        viewModel.stop()
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
        XCTAssertEqual(activity.status, .cancelled)
        XCTAssertEqual(transport.transactionCount, 0)
        XCTAssertEqual(transport.physicalBytes, [])
        XCTAssertEqual(provider.calls.count, 1, "Stop 后不得发起 continuation")
    }

    // MARK: - §47 double approval

    func testDoubleApprovalYieldsSingleTransaction() async throws {
        let transport = installLocalEndpoint(for: sessionA.id, mode: true)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo hi", submit: true), .completed]),
            .events([.textDelta("ok"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        let card = try toolCard(in: conversation)
        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        XCTAssertEqual(transport.transactionCount, 1, "双击审批只能产生一个 transaction")
        XCTAssertEqual(
            transport.physicalBytes,
            EscapeSequences.bracketedPasteStart + Array("echo hi".utf8)
                + EscapeSequences.bracketedPasteEnd + [0x0D]
        )
        let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
        XCTAssertEqual(activity.status, .success)
    }

    // MARK: - §48 replay（同一 callID 第二次零副作用）

    func testReplayedCallIdentityYieldsNoSecondSideEffect() async throws {
        let transport = installLocalEndpoint(for: sessionA.id, mode: false)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall("call-dup", text: "echo hi", submit: false), .completed]),
            .events([toolCall("call-dup", text: "echo hi", submit: false), .completed]),
            .events([.textDelta("done"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        let firstCard = try toolCard(in: conversation)
        viewModel.approveCommand(cardID: firstCard.id, sessionID: conversation.sessionID)

        // 第二轮重放同一 callID：coordinator.register 幂等返回已消费记录，
        // awaitDecision 立即得到 approved resolution，claim 在单次消费
        // 防线处被拒绝——全程无需（也不可能）第二次用户审批。
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        XCTAssertEqual(transport.transactionCount, 1, "同一审批最多一个物理 transaction")
        XCTAssertEqual(transport.physicalBytes, Array("echo hi".utf8))

        let cards = conversation.messages.filter { $0.toolActivity != nil }
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].toolActivity?.status, .success)
        XCTAssertEqual(cards[1].toolActivity?.status, .failure)
        let secondResult = try resultJSON(of: cards[1])
        XCTAssertEqual(secondResult["error"] as? String, "approvalAlreadyConsumed")
    }

    // MARK: - §42 target switch

    func testTargetSwitchNeverRetargetsToOtherTerminal() async throws {
        let transportA = installLocalEndpoint(for: sessionA.id, mode: false)
        let transportB = installLocalEndpoint(for: sessionB.id, mode: false)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo A", submit: false), .completed]),
            .events([.textDelta("ok"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }

        // proposal 建立后 UI 切到 B：审批绝不重定向。
        box.session = sessionB
        let card = try toolCard(in: conversation)
        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        XCTAssertEqual(transportA.physicalBytes, Array("echo A".utf8))
        XCTAssertEqual(transportB.physicalBytes, [], "B 必须收到 0 字节")
        XCTAssertEqual(transportB.transactionCount, 0)
    }

    // MARK: - §43 Local replacement

    func testLocalReplacementYieldsZeroBytesToReplacementEndpoint() async throws {
        let transportOld = installLocalEndpoint(for: sessionA.id, mode: false, epoch: 1)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo old", submit: false), .completed]),
            .events([.textDelta("stale handled"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }

        // PTY 被替换：旧 endpoint 失效，新 incarnation 就位（新 transport/epoch）。
        endpoints[sessionA.id]?.localEndpointForTests?.invalidate()
        let transportNew = FakeLocalMutationTransport()
        endpoints[sessionA.id] = .local(makeLocalEndpoint(
            sessionID: sessionA.id,
            transport: transportNew,
            modeBox: ModeBox(false),
            epoch: 2
        ))

        let card = try toolCard(in: conversation)
        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        XCTAssertEqual(transportNew.transactionCount, 0)
        XCTAssertEqual(transportNew.physicalBytes, [], "替换 PTY 必须收到 0 字节")
        XCTAssertEqual(transportOld.transactionCount, 0)
        let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
        XCTAssertEqual(activity.status, .failure)
        let result = try resultJSON(of: toolCard(in: conversation))
        XCTAssertEqual(result["error"] as? String, "targetReplaced")
    }

    // MARK: - §44 Remote reconnect

    func testRemoteReconnectYieldsZeroBytesToNewConnection() async throws {
        let transportOld = installRemoteEndpoint(for: remoteSession.id, epoch: 1)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo remote", submit: false), .completed]),
            .events([.textDelta("stale handled"), .completed]),
        ])
        let box = SessionBox()
        box.session = remoteSession
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }

        // 重连：旧 endpoint 失效，新连接 endpoint 就位。
        endpoints[remoteSession.id]?.remoteEndpointForTests?.invalidate()
        let transportNew = FakeRemoteMutationTransport()
        endpoints[remoteSession.id] = .remote(makeRemoteEndpoint(
            sessionID: remoteSession.id,
            transport: transportNew,
            modeBox: ModeBox(false),
            epoch: 2
        ))

        let card = try toolCard(in: conversation)
        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        XCTAssertEqual(transportNew.transactionCount, 0)
        XCTAssertEqual(transportNew.physicalBytes, [], "新连接必须收到 0 字节")
        XCTAssertEqual(transportOld.transactionCount, 0)
        let result = try resultJSON(of: toolCard(in: conversation))
        XCTAssertEqual(result["error"] as? String, "targetReplaced")
    }

    // MARK: - §29 partial halt

    func testPartialDeliveryHaltsLoopWithoutProviderContinuation() async throws {
        let transport = installLocalEndpoint(for: sessionA.id, mode: false)
        transport.steps = [FakeLocalMutationTransport.Step(acceptedBytes: 3, error: nil)]
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo hi", submit: false), .completed]),
            .events([.textDelta("不应到达"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        let card = try toolCard(in: conversation)
        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
        XCTAssertEqual(activity.status, .partial)
        XCTAssertEqual(
            provider.calls.count,
            1,
            "§29：partial / uncertain 结果绝不在同一 generation 内自动续 Provider"
        )
        XCTAssertEqual(conversation.isGenerating, false)
        let result = try resultJSON(of: toolCard(in: conversation))
        XCTAssertEqual(result["status"] as? String, "partial")
        XCTAssertEqual(result["ok"] as? Bool, false)
        // failure 消息 surfaced 用户可见状态。
        XCTAssertTrue(
            conversation.messages.contains {
                $0.state == .failed && $0.failure == .terminalMutationUncertain
            }
        )
    }

    // MARK: - §51 bracket mode at loop level

    func testBracketModeOnAndOffProduceExactFramingThroughLoop() async throws {
        for mode in [true, false] {
            endpoints.removeAll()
            let transport = installLocalEndpoint(for: sessionA.id, mode: mode)
            let provider = ScriptedProvider(rounds: [
                .events([toolCall(text: "echo hi", submit: true), .completed]),
                .events([.textDelta("ok"), .completed]),
            ])
            let box = SessionBox()
            box.session = sessionA
            let viewModel = makeViewModel(provider: provider, box: box)

            let conversation = try beginSend("发送", in: viewModel)
            try await waitUntil {
                conversation.messages.first { $0.toolActivity != nil }?
                    .toolActivity?.status == .awaitingApproval
            }
            let card = try toolCard(in: conversation)
            viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
            let task = try XCTUnwrap(conversation.generationTask)
            await task.value

            let expected: [UInt8]
            if mode {
                expected = EscapeSequences.bracketedPasteStart + Array("echo hi".utf8)
                    + EscapeSequences.bracketedPasteEnd + [0x0D]
            } else {
                expected = Array("echo hi".utf8) + [0x0D]
            }
            XCTAssertEqual(transport.physicalBytes, expected, "mode=\(mode)")
            let result = try resultJSON(of: toolCard(in: conversation))
            XCTAssertEqual(result["framingBytesAccepted"] as? Int, mode ? 12 : 0)
            let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
            XCTAssertEqual(activity.status, .success)
        }
    }

    // MARK: - §41 provider cannot override target

    func testProviderInjectedTargetFieldsAreRejectedBeforeAnyBytes() async throws {
        let transport = installLocalEndpoint(for: sessionA.id)
        let provider = ScriptedProvider(rounds: [
            .events([
                .toolCall(AgentProviderToolCall(
                    callID: "call-inject",
                    name: "send_to_terminal",
                    argumentsJSON: #"{"text":"echo hi","submit":true,"sessionID":"00000000-0000-0000-0000-000000000000"}"#
                )),
                .completed,
            ]),
            .events([.textDelta("rejected"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
        XCTAssertEqual(activity.status, .failure)
        XCTAssertEqual(activity.mutationRequest, nil)
        let result = try resultJSON(of: toolCard(in: conversation))
        XCTAssertEqual(result["error"] as? String, "invalidArguments")
        XCTAssertEqual(transport.transactionCount, 0)
        XCTAssertEqual(transport.physicalBytes, [])
    }

    // MARK: - §50 Remote deterministic seam E2E

    func testRemoteEndpointDeliversThroughExactSeamAtLoopLevel() async throws {
        let transport = installRemoteEndpoint(for: remoteSession.id, mode: false)
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: "echo remote", submit: true), .completed]),
            .events([.textDelta("ok"), .completed]),
        ])
        let box = SessionBox()
        box.session = remoteSession
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        let card = try toolCard(in: conversation)
        let request = try XCTUnwrap(card.toolActivity?.mutationRequest)
        XCTAssertEqual(request.targetSnapshot, .remote(hostDisplay: "Remote A"))

        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        XCTAssertEqual(transport.physicalBytes, Array("echo remote".utf8) + [0x0D])
        let result = try resultJSON(of: toolCard(in: conversation))
        XCTAssertEqual(result["status"] as? String, "delivered")
        XCTAssertEqual(result["terminalKind"] as? String, "remoteSSH")
        XCTAssertEqual(result["submitBytesAccepted"] as? Int, 1)
    }

    // MARK: - §49 Real Local /bin/cat E2E

    func testRealLocalCatEndToEndThroughAgentLoop() async throws {
        let view = LocalProcessTerminalView(
            frame: .zero,
            options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color")
        )
        defer { view.terminate() }
        view.startProcess(executable: "/bin/cat")
        guard view.process.running else {
            throw XCTSkip("/bin/cat PTY could not start on this machine")
        }
        try await view.process.inputTransport.withExclusiveInputTransaction { @Sendable _ in }

        let endpoint = AgentLocalTerminalMutationEndpoint(
            logicalSessionID: sessionA.id,
            inputTargetEpoch: 1,
            endpointToken: AgentTerminalEndpointToken.generate(),
            process: view.process,
            terminalView: view
        )
        endpoints[sessionA.id] = .local(endpoint)

        let payload = "MacSSH-B4S1-cat"
        let provider = ScriptedProvider(rounds: [
            .events([toolCall(text: payload, submit: false), .completed]),
            .events([.textDelta("ok"), .completed]),
        ])
        let box = SessionBox()
        box.session = sessionA
        let viewModel = makeViewModel(provider: provider, box: box)

        let conversation = try beginSend("发送", in: viewModel)
        try await waitUntil {
            conversation.messages.first { $0.toolActivity != nil }?
                .toolActivity?.status == .awaitingApproval
        }
        let card = try toolCard(in: conversation)
        viewModel.approveCommand(cardID: card.id, sessionID: conversation.sessionID)
        let task = try XCTUnwrap(conversation.generationTask)
        await task.value

        let activity = try XCTUnwrap(toolCard(in: conversation).toolActivity)
        XCTAssertEqual(activity.status, .success)
        let result = try resultJSON(of: toolCard(in: conversation))
        XCTAssertEqual(result["status"] as? String, "delivered")
        XCTAssertEqual(result["payloadBytesAccepted"] as? Int, payload.utf8.count)

        // cat 回显证明 exact PTY 收到了已批准 payload（无害 fixture）。
        let deadline = Date().addingTimeInterval(3)
        var echoed = false
        while Date() < deadline {
            let data = view.terminal.getBufferAsData(kind: .normal)
            if (String(data: data, encoding: .utf8) ?? "").contains(payload) {
                echoed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(echoed, "已批准 payload 必须经 /bin/cat 回显")
    }

    // MARK: - §55 UI status contract

    func testApprovalActionsExistOnlyInPendingState() {
        XCTAssertTrue(AgentToolCardView.showsApprovalActions(for: .awaitingApproval))
        for status: AgentToolActivity.Status in [
            .running, .success, .failure, .denied, .cancelled, .timedOut, .partial,
        ] {
            XCTAssertFalse(
                AgentToolCardView.showsApprovalActions(for: status),
                "\(status.rawMarker) 不得提供审批按钮（§24：无双批准窗口）"
            )
        }
    }

    func testTerminalMutationAccessibilityIdentifiersAreStableAndDistinct() {
        XCTAssertEqual(AgentToolCardView.terminalApproveAccessibilityIdentifier, "agent.terminal.approve")
        XCTAssertEqual(AgentToolCardView.terminalDenyAccessibilityIdentifier, "agent.terminal.deny")
        XCTAssertNotEqual(
            AgentToolCardView.terminalApproveAccessibilityIdentifier,
            AgentToolCardView.approveAccessibilityIdentifier
        )
        XCTAssertNotEqual(
            AgentToolCardView.terminalDenyAccessibilityIdentifier,
            AgentToolCardView.denyAccessibilityIdentifier
        )
    }
}

// MARK: - Scripted provider

/// 与 AgentToolLoopTests 的 LoopScriptedProvider 同款：交互全部发生在
/// MainActor（ViewModel / 测试），producer Task 只消费创建时捕获的 round，
/// 不触碰实例状态——无需加锁（@unchecked Sendable 的既有测试哲学）。
private final class ScriptedProvider: AgentProvider, @unchecked Sendable {
    enum Round {
        case events([AgentEvent])
    }

    struct Call {
        let transcript: [AgentMessage]
        let tools: [AgentToolDefinition]
        let context: AgentSessionContext
    }

    // 只在 MainActor 上下文访问。
    private(set) var calls: [Call] = []
    private var rounds: [Round]

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
            // 单轮 fixture：末轮被复用（与既有 LoopScriptedProvider 一致）；
            // 测试必须保证末轮可终止（纯文本轮），避免无谓的 round limit。
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
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }
}

// MARK: - Fixtures

@MainActor
private final class ModeBox {
    var value: Bool
    private(set) var readCount = 0

    init(_ value: Bool) {
        self.value = value
    }

    func read() -> Bool {
        readCount += 1
        return value
    }
}

@MainActor
private final class FakeLocalMutationTransport: AgentLocalTerminalMutationInputTransport {
    struct Step {
        let acceptedBytes: Int
        let error: AgentLocalTerminalMutationTransportError?
    }

    var steps: [Step] = []
    var writeBatches: [[UInt8]] = []
    var physicalBytes: [UInt8] = []
    var transactionCount = 0

    init(steps: [Step] = []) {
        self.steps = steps
    }

    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentLocalTerminalMutationTransactionWriter) async throws -> Void
    ) async throws {
        transactionCount += 1
        try await body(FakeLocalMutationWriter(transport: self))
    }

    fileprivate func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) -> AgentLocalTerminalMutationWriteResult {
        _ = forceWhenCancelled
        let requested = bytes.count
        let step = steps.isEmpty
            ? Step(acceptedBytes: requested, error: nil)
            : steps.removeFirst()
        let accepted = min(max(step.acceptedBytes, 0), requested)
        let prefix = Array(bytes.prefix(accepted))
        writeBatches.append(prefix)
        physicalBytes.append(contentsOf: prefix)
        return AgentLocalTerminalMutationWriteResult(
            requestedBytes: requested,
            acceptedBytes: accepted,
            error: step.error
        )
    }
}

@MainActor
private final class FakeLocalMutationWriter: AgentLocalTerminalMutationTransactionWriter {
    private let transport: FakeLocalMutationTransport

    init(transport: FakeLocalMutationTransport) {
        self.transport = transport
    }

    func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) async -> AgentLocalTerminalMutationWriteResult {
        transport.write(bytes, forceWhenCancelled: forceWhenCancelled)
    }
}

@MainActor
private final class FakeRemoteMutationTransport: AgentRemoteTerminalMutationInputTransport {
    struct Step {
        let acceptedBytes: Int
        let error: AgentRemoteTerminalMutationTransportError?
    }

    var steps: [Step] = []
    var physicalBytes: [UInt8] = []
    var transactionCount = 0

    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentRemoteTerminalMutationTransactionWriter) async throws -> Void
    ) async throws {
        transactionCount += 1
        try await body(FakeRemoteMutationWriter(transport: self))
    }

    fileprivate func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) -> AgentRemoteTerminalMutationWriteResult {
        _ = forceWhenCancelled
        let requested = bytes.count
        let step = steps.isEmpty
            ? Step(acceptedBytes: requested, error: nil)
            : steps.removeFirst()
        let accepted = min(max(step.acceptedBytes, 0), requested)
        let prefix = Array(bytes.prefix(accepted))
        physicalBytes.append(contentsOf: prefix)
        return AgentRemoteTerminalMutationWriteResult(
            requestedBytes: requested,
            acceptedBytes: accepted,
            error: step.error
        )
    }
}

@MainActor
private final class FakeRemoteMutationWriter: AgentRemoteTerminalMutationTransactionWriter {
    private let transport: FakeRemoteMutationTransport

    init(transport: FakeRemoteMutationTransport) {
        self.transport = transport
    }

    func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) async -> AgentRemoteTerminalMutationWriteResult {
        transport.write(bytes, forceWhenCancelled: forceWhenCancelled)
    }
}

// MARK: - Endpoint capability test accessors

private extension AgentTerminalMutationEndpointCapability {
    var localEndpointForTests: AgentLocalTerminalMutationEndpoint? {
        if case .local(let endpoint) = self {
            return endpoint
        }
        return nil
    }

    var remoteEndpointForTests: AgentRemoteTerminalMutationEndpoint? {
        if case .remote(let endpoint) = self {
            return endpoint
        }
        return nil
    }
}
