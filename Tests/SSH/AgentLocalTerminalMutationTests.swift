import Foundation
@preconcurrency import SwiftTerm
import XCTest

@testable import MacSSH

/// Phase 10F-B2-S3 focused tests：只验证 Local exact endpoint 与 acknowledged
/// delivery，不注册 Provider 工具、不连接 Remote、不触碰用户文件。
@MainActor
final class AgentLocalTerminalMutationTests: XCTestCase {
    // MARK: - Framing

    func testModeOnUsesCanonicalSixByteFrameAndOptionalCR() async throws {
        let first = try await makeAuthorized(text: "echo hi", submit: true)
        let mode = ModeBox(true)
        let transport = FakeInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: mode)
        let result = await AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertEqual(result.payloadBytesRequested, 7)
        XCTAssertEqual(result.payloadBytesAccepted, 7)
        XCTAssertEqual(result.framingBytesRequested, 12)
        XCTAssertEqual(result.framingBytesAccepted, 12)
        XCTAssertEqual(result.submitBytesRequested, 1)
        XCTAssertEqual(result.submitBytesAccepted, 1)
        XCTAssertEqual(result.bracketedPasteModeSnapshot, true)
        XCTAssertEqual(result.terminalInputState, .confirmed)
        XCTAssertEqual(
            transport.physicalBytes,
            EscapeSequences.bracketedPasteStart + Array("echo hi".utf8)
                + EscapeSequences.bracketedPasteEnd + [0x0D]
        )
        XCTAssertEqual(mode.readCount, 1, "mode 必须只在 admission 读取一次")
    }

    func testModeOffOmitsFramingAndKeepsSubmitIndependent() async throws {
        let first = try await makeAuthorized(text: "echo hi", submit: false)
        let transport = FakeInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        let result = await AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertEqual(result.framingBytesRequested, 0)
        XCTAssertEqual(result.framingBytesAccepted, 0)
        XCTAssertEqual(result.submitBytesRequested, 0)
        XCTAssertEqual(result.submitBytesAccepted, 0)
        XCTAssertEqual(transport.physicalBytes, Array("echo hi".utf8))
    }

    func testModeSnapshotIsFrozenAcrossLaterStages() async throws {
        let first = try await makeAuthorized(text: "payload", submit: false)
        let mode = ModeBox(true)
        let transport = FakeInputTransport()
        transport.onWrite = { index in
            if index == 0 {
                mode.value = false
            }
        }
        let endpoint = makeEndpoint(transport: transport, mode: mode)
        let result = await AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertEqual(result.bracketedPasteModeSnapshot, true)
        XCTAssertEqual(
            transport.physicalBytes,
            EscapeSequences.bracketedPasteStart + Array("payload".utf8)
                + EscapeSequences.bracketedPasteEnd
        )
        XCTAssertEqual(mode.readCount, 1)
    }

    // MARK: - Identity and one-time redemption

    func testEachEndpointIdentityFieldIsRequired() async throws {
        let session = AgentTerminalMutationTestSupport.sessionID
        let epoch = AgentTerminalMutationTestSupport.makeIdentity().inputTargetEpoch
        let token = AgentTerminalMutationTestSupport.makeIdentity().endpointToken
        let cases: [(String, UUID, AgentTerminalInputTargetEpoch, AgentTerminalEndpointToken)] = [
            ("session", UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!, epoch, token),
            ("epoch", session, epoch + 1, token),
            ("token", session, epoch, AgentTerminalEndpointToken(
                rawValue: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
            )),
        ]

        for (label, endpointSession, endpointEpoch, endpointToken) in cases {
            let first = try await makeAuthorized(
                sessionID: session,
                epoch: epoch,
                token: token,
                callID: "identity-(label)"
            )
            let transport = FakeInputTransport()
            let endpoint = AgentLocalTerminalMutationEndpoint(
                logicalSessionID: endpointSession,
                inputTargetEpoch: endpointEpoch,
                endpointToken: endpointToken,
                transport: transport,
                modeSnapshotProvider: { false }
            )
            let result = await AgentLocalTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            XCTAssertEqual(result.error, .targetReplaced, label)
            XCTAssertEqual(result.outcome, .rejected, label)
            XCTAssertEqual(result.payloadBytesAccepted, 0, label)
            XCTAssertEqual(transport.transactionCount, 0, label)
        }
    }

    func testInvalidatedEndpointNeverStartsDelivery() async throws {
        let first = try await makeAuthorized(callID: "invalidated")
        let transport = FakeInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        endpoint.invalidate()

        let result = await AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.error, .targetReplaced)
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(transport.transactionCount, 0)
    }

    func testRedeemedAuthorizationCanStartAtMostOneTransaction() async throws {
        let first = try await makeAuthorized(callID: "one-time")
        let transport = FakeInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        let executor = AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        )

        let initial = await executor.deliver(first.authorization, to: endpoint)
        let replay = await executor.deliver(first.authorization, to: endpoint)

        XCTAssertEqual(initial.outcome, .delivered)
        XCTAssertEqual(replay.error, .approvalAlreadyConsumed)
        XCTAssertEqual(replay.outcome, .rejected)
        XCTAssertEqual(transport.transactionCount, 1)
        XCTAssertEqual(transport.physicalBytes, Array("echo hi\r".utf8))
    }

    /// Authorization 是可复制的值类型时，复制只能共享同一个 coordinator ledger；
    /// 第二份副本必须在任何 transaction / physical write 之前被拒绝。
    func testCopiedAuthorizationHasExactlyOnePhysicalDelivery() async throws {
        let first = try await makeAuthorized(
            submit: false,
            callID: "copied-authorization"
        )
        let authorizationA = first.authorization
        let authorizationB = first.authorization
        let transport = FakeInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        let executor = AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        )

        let firstResult = await executor.deliver(authorizationA, to: endpoint)
        let physicalBytesAfterFirst = transport.physicalBytes.count
        let transactionCountAfterFirst = transport.transactionCount
        let replayResult = await executor.deliver(authorizationB, to: endpoint)

        XCTAssertEqual(firstResult.outcome, .delivered)
        XCTAssertEqual(replayResult.outcome, .rejected)
        XCTAssertEqual(replayResult.error, .approvalAlreadyConsumed)
        XCTAssertEqual(transport.transactionCount, transactionCountAfterFirst)
        XCTAssertEqual(transport.transactionCount, 1)
        XCTAssertEqual(
            transport.physicalBytes.count,
            physicalBytesAfterFirst,
            "authorization 副本的 replay 不得增加物理字节"
        )
        XCTAssertEqual(transport.physicalBytes, Array("echo hi".utf8))
    }

    /// 两个调用者先经 barrier 同步到同一入口，再竞争同一 authorization；
    /// coordinator actor 的 redeem 线性化点必须只允许一个 side effect。
    func testConcurrentReplayHasOneWinnerAndZeroDuplicateBytes() async throws {
        let first = try await makeAuthorized(
            submit: false,
            callID: "concurrent-replay"
        )
        let transport = FakeInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        let executor = AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        )
        let startBarrier = TwoPartyStartBarrier()

        let taskA = Task { @MainActor in
            await startBarrier.arriveAndWait()
            return await executor.deliver(first.authorization, to: endpoint)
        }
        let taskB = Task { @MainActor in
            await startBarrier.arriveAndWait()
            return await executor.deliver(first.authorization, to: endpoint)
        }
        let results = await [taskA.value, taskB.value]
        let delivered = results.filter { $0.outcome == .delivered }
        let rejected = results.filter {
            $0.outcome == .rejected && $0.error == .approvalAlreadyConsumed
        }

        XCTAssertEqual(delivered.count, 1, "同一 authorization 只能有一个赢家")
        XCTAssertEqual(rejected.count, 1, "第二个并发调用必须稳定 replay 拒绝")
        XCTAssertEqual(transport.transactionCount, 1)
        XCTAssertEqual(
            transport.physicalBytes,
            Array("echo hi".utf8),
            "并发 replay 不得产生重复 payload bytes"
        )
    }

    /// replay ledger 必须属于 coordinator，而不是某个 executor 实例；
    /// 两个独立 executor 使用同一授权仍只能取得一个 transaction。
    func testMultipleExecutorInstancesShareExactlyOnceAuthorizationLedger() async throws {
        let first = try await makeAuthorized(
            submit: true,
            callID: "multiple-executors"
        )
        let transport = FakeInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        let executorA = AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        )
        let executorB = AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        )
        let startBarrier = TwoPartyStartBarrier()

        let taskA = Task { @MainActor in
            await startBarrier.arriveAndWait()
            return await executorA.deliver(first.authorization, to: endpoint)
        }
        let taskB = Task { @MainActor in
            await startBarrier.arriveAndWait()
            return await executorB.deliver(first.authorization, to: endpoint)
        }
        let results = await [taskA.value, taskB.value]
        let delivered = results.filter { $0.outcome == .delivered }
        let rejected = results.filter {
            $0.outcome == .rejected && $0.error == .approvalAlreadyConsumed
        }

        XCTAssertEqual(delivered.count, 1, "不同 executor 只能有一个 side-effect winner")
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(transport.transactionCount, 1)
        XCTAssertEqual(
            transport.physicalBytes,
            Array("echo hi\r".utf8),
            "不同 executor 不得重复写入 payload 或 CR"
        )
    }

    // MARK: - Partial matrices

    func testPartialStartMatrixNeverSendsPayloadOrRepairForOneToFive() async throws {
        let start = EscapeSequences.bracketedPasteStart
        for accepted in 0...6 {
            let first = try await makeAuthorized(submit: false, callID: "start-(accepted)")
            let transport = FakeInputTransport(steps: [
                .init(
                    acceptedBytes: accepted,
                    error: accepted == start.count ? nil : .writeFailed
                )
            ])
            let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))
            let result = await AgentLocalTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            if accepted == 0 {
                XCTAssertEqual(result.terminalInputState, .confirmed)
                XCTAssertEqual(result.outcome, .failed)
                XCTAssertEqual(transport.physicalBytes, [])
            } else if accepted < start.count {
                XCTAssertEqual(result.terminalInputState, .uncertain)
                XCTAssertEqual(result.outcome, .partial)
                XCTAssertEqual(transport.physicalBytes, Array(start.prefix(accepted)))
            } else {
                XCTAssertEqual(result.outcome, .delivered)
                XCTAssertEqual(result.framingBytesAccepted, 12)
                XCTAssertEqual(result.payloadBytesAccepted, 7)
                XCTAssertEqual(
                    transport.physicalBytes,
                    start + Array("echo hi".utf8) + EscapeSequences.bracketedPasteEnd
                )
            }
            if accepted < start.count {
                XCTAssertEqual(result.payloadBytesAccepted, 0, "START partial 不得触发 payload")
            }
        }
    }

    func testPartialPayloadMatrixRecordsPrefixAndAttemptsOnlyOneRepairEnd() async throws {
        let payload = Array("echo hi".utf8)
        for accepted in [0, 1, 3, payload.count] {
            let first = try await makeAuthorized(submit: true, callID: "payload-(accepted)")
            let transport = FakeInputTransport(steps: [
                .init(acceptedBytes: 6, error: nil),
                .init(
                    acceptedBytes: accepted,
                    error: accepted == payload.count ? nil : .writeFailed
                ),
            ])
            let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))
            let result = await AgentLocalTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            XCTAssertEqual(result.payloadBytesAccepted, accepted)
            if accepted < payload.count {
                XCTAssertEqual(transport.writeBatches.count, 3, "payload 失败最多一个 END repair")
                XCTAssertFalse(
                    transport.writeBatches.dropFirst().dropLast().contains(payload),
                    "payload 不得被整段重发"
                )
                XCTAssertEqual(result.framingBytesRequested, 12)
                XCTAssertEqual(result.framingBytesAccepted, 12)
                XCTAssertEqual(result.submitBytesRequested, 0)
                let expectedOutcome: AgentTerminalMutationDeliveryOutcome = accepted == 0
                    ? .failed
                    : .partial
                XCTAssertEqual(result.outcome, expectedOutcome)
            } else {
                XCTAssertEqual(result.outcome, .delivered)
                XCTAssertEqual(result.submitBytesAccepted, 1)
            }
        }
    }

    func testPartialEndMatrixIsUncertainAndNeverRetriesOrSubmits() async throws {
        let end = EscapeSequences.bracketedPasteEnd
        for accepted in 0...6 {
            let first = try await makeAuthorized(submit: true, callID: "end-(accepted)")
            let transport = FakeInputTransport(steps: [
                .init(acceptedBytes: 6, error: nil),
                .init(acceptedBytes: 7, error: nil),
                .init(
                    acceptedBytes: accepted,
                    error: accepted == end.count ? nil : .writeFailed
                ),
            ])
            let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))
            let result = await AgentLocalTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            if accepted < end.count {
                XCTAssertEqual(result.terminalInputState, .uncertain)
                XCTAssertEqual(result.submitBytesRequested, 0)
                XCTAssertEqual(result.outcome, .partial)
                XCTAssertEqual(transport.writeBatches.count, 3)
            } else {
                XCTAssertEqual(result.terminalInputState, .confirmed)
                XCTAssertEqual(result.submitBytesAccepted, 1)
                XCTAssertEqual(result.outcome, .delivered)
                XCTAssertEqual(transport.writeBatches.count, 4)
            }
        }
    }

    func testSubmitMatrixDoesNotRetryCarriageReturn() async throws {
        let noSubmit = try await makeAuthorized(submit: false, callID: "submit-false")
        let noSubmitTransport = FakeInputTransport()
        let noSubmitResult = await AgentLocalTerminalMutationExecutor(
            approvalCoordinator: noSubmit.coordinator
        ).deliver(
            noSubmit.authorization,
            to: makeEndpoint(transport: noSubmitTransport, mode: ModeBox(false))
        )
        XCTAssertEqual(noSubmitResult.submitBytesRequested, 0)
        XCTAssertEqual(noSubmitTransport.writeBatches.count, 1)

        for accepted in [0, 1] {
            let first = try await makeAuthorized(submit: true, callID: "submit-(accepted)")
            let transport = FakeInputTransport(steps: [
                .init(acceptedBytes: 7, error: nil),
                .init(acceptedBytes: accepted, error: accepted == 1 ? nil : .writeFailed),
            ])
            let result = await AgentLocalTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(
                first.authorization,
                to: makeEndpoint(transport: transport, mode: ModeBox(false))
            )
            XCTAssertEqual(result.submitBytesRequested, 1)
            XCTAssertEqual(result.submitBytesAccepted, accepted)
            XCTAssertEqual(transport.writeBatches.count, 2, "CR 不得重试")
            let expectedOutcome: AgentTerminalMutationDeliveryOutcome = accepted == 1
                ? .delivered
                : .partial
            XCTAssertEqual(result.outcome, expectedOutcome)
        }
    }

    // MARK: - Cancellation and ordering

    func testCancellationBeforePhysicalWriteProducesZeroBytes() async throws {
        let first = try await makeAuthorized(callID: "cancel-before-write")
        let transport = FakeInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))
        let executor = AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        )
        let task = Task { @MainActor in
            await executor.deliver(first.authorization, to: endpoint)
        }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.error, .cancelled)
        XCTAssertEqual(result.payloadBytesAccepted, 0)
        XCTAssertEqual(result.framingBytesAccepted, 0)
        XCTAssertEqual(result.submitBytesAccepted, 0)
        XCTAssertEqual(transport.physicalBytes, [])
    }

    func testCancellationMatrixNeverRetriesOrCrossesStageBoundary() async throws {
        let cases: [(name: String, mode: Bool, submit: Bool, cancelAtWrite: Int)] = [
            ("start", true, false, 0),
            ("payload", true, false, 1),
            ("end", true, true, 2),
            ("cr", false, true, 1),
        ]

        for testCase in cases {
            let first = try await makeAuthorized(
                submit: testCase.submit,
                callID: "cancel-\(testCase.name)"
            )
            let transport = FakeInputTransport()
            let cancellation = CancellationBox()
            transport.onWrite = { index in
                if index == testCase.cancelAtWrite {
                    cancellation.cancel()
                }
            }
            let endpoint = makeEndpoint(
                transport: transport,
                mode: ModeBox(testCase.mode)
            )
            let executor = AgentLocalTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            )
            let task = Task { @MainActor in
                await executor.deliver(first.authorization, to: endpoint)
            }
            cancellation.task = task
            let result = await task.value

            let expectedWriteCount: Int
            switch testCase.name {
            case "start":
                expectedWriteCount = 2 // START + 唯一一次 forced END repair。
            case "payload", "end":
                expectedWriteCount = 3 // START + payload/END，均不重试。
            case "cr":
                expectedWriteCount = 2 // payload + CR；CR 已确认时也不重试。
            default:
                XCTFail("未知 cancellation stage")
                expectedWriteCount = 0
            }
            XCTAssertEqual(
                transport.writeBatches.count,
                expectedWriteCount,
                "\(testCase.name) 取消不得整段重试"
            )
            if testCase.name == "cr" {
                XCTAssertEqual(result.submitBytesAccepted, 1)
                XCTAssertEqual(result.outcome, .delivered)
            } else {
                XCTAssertEqual(result.error, .cancelled, testCase.name)
                XCTAssertEqual(result.outcome, .partial, testCase.name)
            }
        }
    }

    func testOrdinaryInputQueuedDuringMutationCannotInterleave() async throws {
        let first = try await makeAuthorized(text: "payload", submit: false, callID: "ordering")
        let transport = FakeInputTransport()
        transport.onWrite = { index in
            if index == 0 {
                transport.enqueueOrdinary(Array("keyboard".utf8))
            }
        }
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))
        let result = await AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertEqual(
            transport.physicalBytes,
            EscapeSequences.bracketedPasteStart + Array("payload".utf8)
                + EscapeSequences.bracketedPasteEnd + Array("keyboard".utf8)
        )
    }

    // MARK: - Real local PTY

    func testRealCatPTYReceivesApprovedPayloadThroughExactEndpoint() async throws {
        let view = LocalProcessTerminalView(
            frame: .zero,
            options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color")
        )
        defer { view.terminate() }
        view.startProcess(executable: "/bin/cat")
        guard view.process.running else {
            throw XCTSkip("/bin/cat PTY could not start on this machine")
        }

        // 等待固定 inputTransport 完成 attach；此处不发送任何 payload。
        try await view.process.inputTransport.withExclusiveInputTransaction { @Sendable _ in }

        let endpoint = AgentLocalTerminalMutationEndpoint(
            logicalSessionID: AgentTerminalMutationTestSupport.sessionID,
            inputTargetEpoch: 1,
            endpointToken: AgentTerminalEndpointToken.generate(),
            process: view.process,
            terminalView: view
        )
        let first = try await makeAuthorized(
            sessionID: endpoint.logicalSessionID,
            epoch: endpoint.inputTargetEpoch,
            token: endpoint.endpointToken,
            text: "MacSSH-S3-cat",
            submit: false,
            callID: "real-cat"
        )
        let result = await AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertEqual(result.payloadBytesAccepted, "MacSSH-S3-cat".utf8.count)
        let deadline = Date().addingTimeInterval(3)
        var echoed = false
        while Date() < deadline {
            let data = view.terminal.getBufferAsData(kind: .normal)
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("MacSSH-S3-cat") {
                echoed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(echoed, "approved payload 必须从 exact Local PTY 经 cat 回显")

        // 真实 PTY 已观察到首次回显后，重放同一 authorization 不能再进入
        // inputTransport；用 terminal buffer 的物理观察值证明没有重复字节。
        let terminalBytesAfterFirstDelivery = view.terminal.getBufferAsData(kind: .normal)
        let replay = await AgentLocalTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)
        let terminalBytesAfterReplay = view.terminal.getBufferAsData(kind: .normal)

        XCTAssertEqual(replay.outcome, .rejected)
        XCTAssertEqual(replay.error, .approvalAlreadyConsumed)
        XCTAssertEqual(
            terminalBytesAfterReplay,
            terminalBytesAfterFirstDelivery,
            "真实 Local PTY replay 不得增加任何可观察字节"
        )
    }

    // MARK: - Fixtures

    private func makeEndpoint(
        transport: FakeInputTransport,
        mode: ModeBox,
        sessionID: UUID = AgentTerminalMutationTestSupport.sessionID,
        epoch: AgentTerminalInputTargetEpoch = 7,
        token: AgentTerminalEndpointToken = AgentTerminalMutationTestSupport.makeIdentity().endpointToken
    ) -> AgentLocalTerminalMutationEndpoint {
        AgentLocalTerminalMutationEndpoint(
            logicalSessionID: sessionID,
            inputTargetEpoch: epoch,
            endpointToken: token,
            transport: transport,
            modeSnapshotProvider: { mode.read() }
        )
    }

    private func makeAuthorized(
        sessionID: UUID = AgentTerminalMutationTestSupport.sessionID,
        epoch: AgentTerminalInputTargetEpoch = 7,
        token: AgentTerminalEndpointToken = AgentTerminalMutationTestSupport.makeIdentity().endpointToken,
        text: String = "echo hi",
        submit: Bool = true,
        callID: String = UUID().uuidString
    ) async throws -> (
        coordinator: AgentTerminalMutationApprovalCoordinator,
        authorization: AgentTerminalMutationExecutionAuthorization
    ) {
        let identity = AgentTerminalInputTargetIdentity(
            logicalSessionID: sessionID,
            inputTargetEpoch: epoch,
            endpointToken: token
        )
        let request: AgentTerminalMutationRequest
        switch AgentTerminalMutationRequestFactory.make(
            generationID: UUID(),
            callID: callID,
            logicalSessionID: sessionID,
            targetIdentity: identity,
            targetSnapshot: .local,
            text: text,
            submit: submit,
            providerBinding: AgentTerminalMutationTestSupport.providerBinding,
            createdAt: Date()
        ) {
        case .success(let value):
            request = value
        case .failure(let error):
            throw error
        }

        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(
                generationID: request.generationID,
                sessionID: sessionID,
                providerSnapshotID: request.providerBinding.snapshotID,
                epoch: epoch,
                token: token
            )
        )
        return (coordinator, authorization)
    }
}

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
private final class CancellationBox {
    var task: Task<AgentTerminalMutationDeliveryResult, Never>?

    func cancel() {
        task?.cancel()
    }
}

@MainActor
private final class FakeInputTransport: AgentLocalTerminalMutationInputTransport {
    struct Step {
        let acceptedBytes: Int
        let error: AgentLocalTerminalMutationTransportError?
    }

    var steps: [Step]
    var writeBatches: [[UInt8]] = []
    var physicalBytes: [UInt8] = []
    var forceFlags: [Bool] = []
    var transactionCount = 0
    var onWrite: ((Int) -> Void)?
    private var inTransaction = false
    private var heldOrdinary: [[UInt8]] = []

    init(steps: [Step] = []) {
        self.steps = steps
    }

    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentLocalTerminalMutationTransactionWriter) async throws -> Void
    ) async throws {
        transactionCount += 1
        inTransaction = true
        defer {
            inTransaction = false
            let queued = heldOrdinary.flatMap { $0 }
            physicalBytes.append(contentsOf: queued)
            heldOrdinary.removeAll()
        }
        try await body(FakeInputWriter(transport: self))
    }

    func enqueueOrdinary(_ bytes: [UInt8]) {
        if inTransaction {
            heldOrdinary.append(bytes)
        } else {
            physicalBytes.append(contentsOf: bytes)
        }
    }

    fileprivate func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) -> AgentLocalTerminalMutationWriteResult {
        let requested = bytes.count
        let step = steps.isEmpty
            ? Step(acceptedBytes: requested, error: nil)
            : steps.removeFirst()
        let accepted = min(max(step.acceptedBytes, 0), requested)
        let prefix = Array(bytes.prefix(accepted))
        writeBatches.append(prefix)
        physicalBytes.append(contentsOf: prefix)
        forceFlags.append(forceWhenCancelled)
        onWrite?(writeBatches.count - 1)
        return AgentLocalTerminalMutationWriteResult(
            requestedBytes: requested,
            acceptedBytes: accepted,
            error: step.error
        )
    }
}

@MainActor
private final class FakeInputWriter: AgentLocalTerminalMutationTransactionWriter {
    private let transport: FakeInputTransport

    init(transport: FakeInputTransport) {
        self.transport = transport
    }

    func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) async -> AgentLocalTerminalMutationWriteResult {
        transport.write(bytes, forceWhenCancelled: forceWhenCancelled)
    }
}

/// 仅允许两个并发调用在同一闸门释放后继续，保证 race 测试不是 sleep-only。
private actor TwoPartyStartBarrier {
    private var arrivals = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivals += 1
        guard arrivals < 2 else {
            let continuations = waiting
            waiting.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
            return
        }

        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }
}
