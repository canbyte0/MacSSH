import AppKit
import Foundation
import SwiftData
@preconcurrency import SwiftTerm
import XCTest

@testable import MacSSH

/// Phase 10F-B3-S2 focused tests：只验证 Remote exact endpoint 与 acknowledged
/// delivery，不注册 Provider 工具、不改变 Agent loop、不打开独立 exec channel。
@MainActor
final class AgentRemoteTerminalMutationTests: XCTestCase {
    private var knownHostContainer: ModelContainer!
    private var knownHostService: KnownHostService!

    override func setUp() async throws {
        continueAfterFailure = false
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        knownHostContainer = try ModelContainer(for: schema, configurations: [configuration])
        knownHostService = KnownHostService(modelContainer: knownHostContainer)
    }

    override func tearDown() async throws {
        knownHostService.removeAll()
        knownHostService = nil
        knownHostContainer = nil
    }

    // MARK: - Framing and accounting

    func testModeOnUsesCanonicalFrameAndOptionalCR() async throws {
        let first = try await makeAuthorized(text: "echo hi", submit: true)
        let mode = ModeBox(true)
        let transport = FakeRemoteInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: mode)

        let result = await AgentRemoteTerminalMutationExecutor(
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
                + EscapeSequences.bracketedPasteEnd + EscapeSequences.cmdRet
        )
        XCTAssertEqual(mode.readCount, 1, "Remote bracket mode 必须只读取一次")
    }

    func testModeOffOmitsFramingAndKeepsSubmitIndependent() async throws {
        let first = try await makeAuthorized(text: "echo hi", submit: false)
        let transport = FakeRemoteInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))

        let result = await AgentRemoteTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertEqual(result.framingBytesRequested, 0)
        XCTAssertEqual(result.framingBytesAccepted, 0)
        XCTAssertEqual(result.submitBytesRequested, 0)
        XCTAssertEqual(result.submitBytesAccepted, 0)
        XCTAssertEqual(transport.physicalBytes, Array("echo hi".utf8))
    }

    func testBracketModeSnapshotIsFrozenAcrossRemoteStages() async throws {
        let first = try await makeAuthorized(text: "payload", submit: false)
        let mode = ModeBox(true)
        let transport = FakeRemoteInputTransport()
        transport.onWrite = { index in
            if index == 0 {
                mode.value = false
            }
        }
        let endpoint = makeEndpoint(transport: transport, mode: mode)

        let result = await AgentRemoteTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertTrue(result.bracketedPasteModeSnapshot)
        XCTAssertEqual(mode.readCount, 1)
        XCTAssertEqual(
            transport.physicalBytes,
            EscapeSequences.bracketedPasteStart + Array("payload".utf8)
                + EscapeSequences.bracketedPasteEnd
        )
    }

    // MARK: - Identity and replay

    func testRemoteIdentityAndTargetKindAreAllRequired() async throws {
        let session = AgentTerminalMutationTestSupport.sessionID
        let epoch = AgentTerminalMutationTestSupport.makeIdentity().inputTargetEpoch
        let token = AgentTerminalMutationTestSupport.makeIdentity().endpointToken

        let cases: [(String, UUID, AgentTerminalInputTargetEpoch, AgentTerminalEndpointToken, AgentTerminalMutationTargetSnapshot)] = [
            (
                "session",
                UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!,
                epoch,
                token,
                .remote(hostDisplay: "Remote A")
            ),
            ("epoch", session, epoch + 1, token, .remote(hostDisplay: "Remote A")),
            (
                "token",
                session,
                epoch,
                AgentTerminalEndpointToken(
                    rawValue: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
                ),
                .remote(hostDisplay: "Remote A")
            ),
            ("kind", session, epoch, token, .local),
            ("host-display", session, epoch, token, .remote(hostDisplay: "Remote B")),
        ]

        for (label, endpointSession, endpointEpoch, endpointToken, snapshot) in cases {
            let first = try await makeAuthorized(
                sessionID: session,
                epoch: epoch,
                token: token,
                targetSnapshot: snapshot,
                callID: "identity-(label)"
            )
            let transport = FakeRemoteInputTransport()
            let endpoint = makeEndpoint(
                transport: transport,
                mode: ModeBox(false),
                sessionID: endpointSession,
                epoch: endpointEpoch,
                token: endpointToken
            )

            let result = await AgentRemoteTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            XCTAssertEqual(result.error, .targetReplaced, label)
            XCTAssertEqual(result.outcome, .rejected, label)
            XCTAssertEqual(result.payloadBytesAccepted, 0, label)
            XCTAssertEqual(transport.transactionCount, 0, label)
        }
    }

    func testInvalidatedRemoteEndpointNeverStartsDelivery() async throws {
        let first = try await makeAuthorized(callID: "invalidated")
        let transport = FakeRemoteInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        endpoint.invalidate()

        let result = await AgentRemoteTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.error, .targetReplaced)
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(transport.transactionCount, 0)
    }

    func testSequentialReplayAddsNoRemoteTransactionOrBytes() async throws {
        let first = try await makeAuthorized(
            targetSnapshot: .remote(hostDisplay: "Remote A"),
            submit: true,
            callID: "sequential-replay"
        )
        let transport = FakeRemoteInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        let executor = AgentRemoteTerminalMutationExecutor(approvalCoordinator: first.coordinator)

        let initial = await executor.deliver(first.authorization, to: endpoint)
        let byteCount = transport.physicalBytes.count
        let transactionCount = transport.transactionCount
        let replay = await executor.deliver(first.authorization, to: endpoint)

        XCTAssertEqual(initial.outcome, .delivered)
        XCTAssertEqual(replay.error, .approvalAlreadyConsumed)
        XCTAssertEqual(replay.outcome, .rejected)
        XCTAssertEqual(transport.transactionCount, transactionCount)
        XCTAssertEqual(transport.transactionCount, 1)
        XCTAssertEqual(transport.physicalBytes.count, byteCount)
    }

    func testConcurrentReplayHasOneWinner() async throws {
        let first = try await makeAuthorized(
            targetSnapshot: .remote(hostDisplay: "Remote A"),
            submit: false,
            callID: "concurrent-replay"
        )
        let transport = FakeRemoteInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        let executor = AgentRemoteTerminalMutationExecutor(approvalCoordinator: first.coordinator)
        let barrier = TwoPartyStartBarrier()

        let taskA = Task { @MainActor in
            await barrier.arriveAndWait()
            return await executor.deliver(first.authorization, to: endpoint)
        }
        let taskB = Task { @MainActor in
            await barrier.arriveAndWait()
            return await executor.deliver(first.authorization, to: endpoint)
        }
        let results = await [taskA.value, taskB.value]

        XCTAssertEqual(results.filter { $0.outcome == .delivered }.count, 1)
        XCTAssertEqual(
            results.filter { $0.outcome == .rejected && $0.error == .approvalAlreadyConsumed }.count,
            1
        )
        XCTAssertEqual(transport.transactionCount, 1)
    }

    func testMultipleRemoteExecutorsShareCoordinatorLedger() async throws {
        let first = try await makeAuthorized(
            targetSnapshot: .remote(hostDisplay: "Remote A"),
            submit: true,
            callID: "multiple-executors"
        )
        let transport = FakeRemoteInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
        let executorA = AgentRemoteTerminalMutationExecutor(approvalCoordinator: first.coordinator)
        let executorB = AgentRemoteTerminalMutationExecutor(approvalCoordinator: first.coordinator)
        let barrier = TwoPartyStartBarrier()

        let taskA = Task { @MainActor in
            await barrier.arriveAndWait()
            return await executorA.deliver(first.authorization, to: endpoint)
        }
        let taskB = Task { @MainActor in
            await barrier.arriveAndWait()
            return await executorB.deliver(first.authorization, to: endpoint)
        }
        let results = await [taskA.value, taskB.value]

        XCTAssertEqual(results.filter { $0.outcome == .delivered }.count, 1)
        XCTAssertEqual(transport.transactionCount, 1)
        XCTAssertEqual(transport.physicalBytes, Array("echo hi\r".utf8))
    }

    /// Remote replay stress：每轮都使用新的 approved request，但在该轮中并发
    /// 竞争同一个 authorization，验证 coordinator ledger 不依赖 executor 实例。
    func testConcurrentReplayStressFiftyRounds() async throws {
        for round in 0..<50 {
            let first = try await makeAuthorized(
                targetSnapshot: .remote(hostDisplay: "Remote A"),
                submit: false,
                callID: "stress-\(round)"
            )
            let transport = FakeRemoteInputTransport()
            let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))
            let executorA = AgentRemoteTerminalMutationExecutor(approvalCoordinator: first.coordinator)
            let executorB = AgentRemoteTerminalMutationExecutor(approvalCoordinator: first.coordinator)
            let barrier = TwoPartyStartBarrier()

            let taskA = Task { @MainActor in
                await barrier.arriveAndWait()
                return await executorA.deliver(first.authorization, to: endpoint)
            }
            let taskB = Task { @MainActor in
                await barrier.arriveAndWait()
                return await executorB.deliver(first.authorization, to: endpoint)
            }
            let results = await [taskA.value, taskB.value]

            XCTAssertEqual(results.filter { $0.outcome == .delivered }.count, 1, "round (round)")
            XCTAssertEqual(transport.transactionCount, 1, "round (round)")
            XCTAssertEqual(transport.physicalBytes, Array("echo hi".utf8), "round (round)")
        }
    }

    // MARK: - Partial delivery and cancellation

    func testPartialStartMatrixNeverSendsPayloadOrRepair() async throws {
        let start = EscapeSequences.bracketedPasteStart
        for accepted in 0...6 {
            let first = try await makeAuthorized(
                targetSnapshot: .remote(hostDisplay: "Remote A"),
                submit: false,
                callID: "start-\(accepted)"
            )
            let transport = FakeRemoteInputTransport(steps: [
                .init(acceptedBytes: accepted, error: accepted == start.count ? nil : .writeFailed)
            ])
            let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))

            let result = await AgentRemoteTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            let expectedFramingBytes = accepted == start.count ? start.count * 2 : start.count
            XCTAssertEqual(result.framingBytesRequested, expectedFramingBytes, "accepted \(accepted)")
            let expectedAcceptedFramingBytes = accepted == start.count
                ? start.count * 2
                : accepted
            XCTAssertEqual(
                result.framingBytesAccepted,
                expectedAcceptedFramingBytes,
                "accepted \(accepted)"
            )
            if accepted == 0 {
                XCTAssertEqual(result.outcome, .failed)
                XCTAssertEqual(result.terminalInputState, .confirmed)
            } else if accepted < start.count {
                XCTAssertEqual(result.outcome, .partial)
                XCTAssertEqual(result.terminalInputState, .uncertain)
            } else {
                XCTAssertEqual(result.outcome, .delivered)
                XCTAssertEqual(result.payloadBytesAccepted, 7)
                XCTAssertEqual(result.framingBytesAccepted, 12)
                XCTAssertEqual(transport.writeBatches.count, 3)
            }
            if accepted < start.count {
                XCTAssertEqual(transport.writeBatches.count, 1, "START partial 不得 repair")
                XCTAssertEqual(result.payloadBytesAccepted, 0)
            }
        }
    }

    func testPartialPayloadRecordsPrefixAndUsesOnlyOneRepairEnd() async throws {
        let payload = Array("echo hi".utf8)
        for accepted in [0, 1, 3, payload.count] {
            let first = try await makeAuthorized(
                targetSnapshot: .remote(hostDisplay: "Remote A"),
                submit: true,
                callID: "payload-\(accepted)"
            )
            let transport = FakeRemoteInputTransport(steps: [
                .init(acceptedBytes: 6, error: nil),
                .init(
                    acceptedBytes: accepted,
                    error: accepted == payload.count ? nil : .writeFailed
                ),
            ])
            let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))

            let result = await AgentRemoteTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            XCTAssertEqual(result.payloadBytesAccepted, accepted)
            if accepted < payload.count {
                XCTAssertEqual(transport.writeBatches.count, 3, "payload failure has one END repair")
                XCTAssertEqual(result.framingBytesRequested, 12)
                XCTAssertEqual(result.framingBytesAccepted, 12)
                XCTAssertEqual(result.submitBytesRequested, 0)
                XCTAssertEqual(result.outcome, accepted == 0 ? .failed : .partial)
            } else {
                XCTAssertEqual(result.outcome, .delivered)
                XCTAssertEqual(result.submitBytesAccepted, 1)
                XCTAssertEqual(transport.writeBatches.count, 4)
            }
        }
    }

    func testPartialEndMatrixNeverRetriesOrSubmits() async throws {
        let end = EscapeSequences.bracketedPasteEnd
        for accepted in 0...6 {
            let first = try await makeAuthorized(
                targetSnapshot: .remote(hostDisplay: "Remote A"),
                submit: true,
                callID: "end-\(accepted)"
            )
            let transport = FakeRemoteInputTransport(steps: [
                .init(acceptedBytes: 6, error: nil),
                .init(acceptedBytes: 7, error: nil),
                .init(
                    acceptedBytes: accepted,
                    error: accepted == end.count ? nil : .writeFailed
                ),
            ])
            let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))

            let result = await AgentRemoteTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            if accepted < end.count {
                XCTAssertEqual(result.terminalInputState, .uncertain)
                XCTAssertEqual(result.outcome, .partial)
                XCTAssertEqual(result.submitBytesRequested, 0)
                XCTAssertEqual(transport.writeBatches.count, 3)
            } else {
                XCTAssertEqual(result.terminalInputState, .confirmed)
                XCTAssertEqual(result.outcome, .delivered)
                XCTAssertEqual(result.submitBytesAccepted, 1)
                XCTAssertEqual(transport.writeBatches.count, 4)
            }
        }
    }

    func testCarriageReturnIsNeverRetried() async throws {
        for accepted in [0, 1] {
            let first = try await makeAuthorized(
                targetSnapshot: .remote(hostDisplay: "Remote A"),
                submit: true,
                callID: "cr-\(accepted)"
            )
            let transport = FakeRemoteInputTransport(steps: [
                .init(acceptedBytes: 7, error: nil),
                .init(acceptedBytes: accepted, error: accepted == 1 ? nil : .writeFailed),
            ])
            let endpoint = makeEndpoint(transport: transport, mode: ModeBox(false))

            let result = await AgentRemoteTerminalMutationExecutor(
                approvalCoordinator: first.coordinator
            ).deliver(first.authorization, to: endpoint)

            XCTAssertEqual(result.submitBytesRequested, 1)
            XCTAssertEqual(result.submitBytesAccepted, accepted)
            XCTAssertEqual(transport.writeBatches.count, 2)
            XCTAssertEqual(result.outcome, accepted == 1 ? .delivered : .partial)
        }
    }

    /// 连接在 payload 已确认部分之后丢失：保留 accepted prefix，最多做一次
    /// best-effort END repair，不重发 payload，也不把 CR 投向 replacement。
    func testConnectionLossPreservesPrefixWithoutReconnectOrRetry() async throws {
        let first = try await makeAuthorized(
            targetSnapshot: .remote(hostDisplay: "Remote A"),
            submit: true,
            callID: "connection-loss"
        )
        let start = EscapeSequences.bracketedPasteStart
        let end = EscapeSequences.bracketedPasteEnd
        let payload = Array("echo hi".utf8)
        let transport = FakeRemoteInputTransport(steps: [
            .init(acceptedBytes: start.count, error: nil),
            .init(acceptedBytes: 3, error: .connectionLost),
            .init(acceptedBytes: 0, error: .connectionLost),
        ])
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))

        let result = await AgentRemoteTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.error, .connectionLost)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.payloadBytesAccepted, 3)
        XCTAssertEqual(result.framingBytesRequested, start.count + end.count)
        XCTAssertEqual(result.framingBytesAccepted, start.count)
        XCTAssertEqual(result.submitBytesAccepted, 0)
        XCTAssertEqual(transport.writeBatches.count, 3)
        XCTAssertEqual(
            transport.physicalBytes,
            start + Array(payload.prefix(3))
        )
    }

    func testCancellationBeforePhysicalWriteProducesZeroBytes() async throws {
        let first = try await makeAuthorized(
            targetSnapshot: .remote(hostDisplay: "Remote A"),
            callID: "cancel-before-write"
        )
        let transport = FakeRemoteInputTransport()
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))
        let executor = AgentRemoteTerminalMutationExecutor(approvalCoordinator: first.coordinator)
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
        XCTAssertEqual(transport.transactionCount, 0)
    }

    // MARK: - Reconnect and B3 exact capability

    func testOldAuthorizationCannotTargetReplacementEpochOrToken() async throws {
        let oldToken = AgentTerminalMutationTestSupport.makeIdentity().endpointToken
        let first = try await makeAuthorized(
            epoch: 7,
            token: oldToken,
            targetSnapshot: .remote(hostDisplay: "Remote A"),
            callID: "reconnect-stale"
        )
        let oldTransport = FakeRemoteInputTransport()
        let oldEndpoint = makeEndpoint(
            transport: oldTransport,
            mode: ModeBox(false),
            epoch: 7,
            token: oldToken
        )
        let replacementTransport = FakeRemoteInputTransport()
        let replacementEndpoint = makeEndpoint(
            transport: replacementTransport,
            mode: ModeBox(false),
            epoch: 8,
            token: AgentTerminalEndpointToken.generate()
        )
        oldEndpoint.invalidate()

        let result = await AgentRemoteTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: replacementEndpoint)

        XCTAssertEqual(result.error, .targetReplaced)
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(oldTransport.transactionCount, 0)
        XCTAssertEqual(replacementTransport.transactionCount, 0)
    }

    func testExactB3CapabilityWinsWhenConnectionsShareNumericGeneration() async throws {
        let connectionA = makeConnection()
        let connectionB = makeConnection()
        let probeA = B3InputBackendProbe()
        let probeB = B3InputBackendProbe()
        await connectionA.installTestInteractiveInputBackend(
            { bytes, offset in await probeA.accept(bytes: bytes, offset: offset) },
            readinessWait: {}
        )
        await connectionB.installTestInteractiveInputBackend(
            { bytes, offset in await probeB.accept(bytes: bytes, offset: offset) },
            readinessWait: {}
        )
        let endpointValueA = await connectionA.interactiveInputEndpoint()
        let endpointValueB = await connectionB.interactiveInputEndpoint()
        let inputEndpointA = try XCTUnwrap(endpointValueA)
        let inputEndpointB = try XCTUnwrap(endpointValueB)
        XCTAssertEqual(inputEndpointA.generation, inputEndpointB.generation)

        let logicalSessionID = UUID()
        let terminalView = TerminalView(
            frame: .zero,
            options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color")
        )
        let endpoint = AgentRemoteTerminalMutationEndpoint(
            logicalSessionID: logicalSessionID,
            inputTargetEpoch: 1,
            endpointToken: AgentTerminalEndpointToken.generate(),
            hostDisplayName: "Remote A",
            inputEndpoint: inputEndpointA,
            terminalView: terminalView
        )
        let first = try await makeAuthorized(
            sessionID: logicalSessionID,
            epoch: endpoint.inputTargetEpoch,
            token: endpoint.endpointToken,
            targetSnapshot: .remote(hostDisplay: "Remote A"),
            text: "B3-exact",
            submit: false,
            callID: "exact-capability"
        )

        let result = await AgentRemoteTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        let receivedByA = await probeA.snapshot()
        let receivedByB = await probeB.snapshot()
        XCTAssertEqual(receivedByA, Array("B3-exact".utf8))
        XCTAssertEqual(receivedByB, [])
    }

    // MARK: - Isolation and source security gates

    func testOrdinaryInputIsReleasedOnlyAfterRemoteTransaction() async throws {
        let first = try await makeAuthorized(
            targetSnapshot: .remote(hostDisplay: "Remote A"),
            text: "payload",
            submit: false,
            callID: "ordering"
        )
        let transport = FakeRemoteInputTransport()
        transport.onWrite = { index in
            if index == 0 {
                transport.enqueueOrdinary(Array("keyboard".utf8))
            }
        }
        let endpoint = makeEndpoint(transport: transport, mode: ModeBox(true))

        let result = await AgentRemoteTerminalMutationExecutor(
            approvalCoordinator: first.coordinator
        ).deliver(first.authorization, to: endpoint)

        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertEqual(
            transport.physicalBytes,
            EscapeSequences.bracketedPasteStart + Array("payload".utf8)
                + EscapeSequences.bracketedPasteEnd + Array("keyboard".utf8)
        )
    }

    func testRemoteMutationSourceHasNoActiveLookupOrExecMutationPath() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executorPath = sourceRoot
            .appendingPathComponent("MacSSH/Services/Agent/TerminalMutation/AgentRemoteTerminalMutationExecutor.swift")
        let endpointPath = sourceRoot
            .appendingPathComponent("MacSSH/Services/Agent/TerminalMutation/AgentRemoteTerminalMutationEndpoint.swift")
        let executorSource = try String(contentsOf: executorPath, encoding: .utf8)
        let endpointSource = try String(contentsOf: endpointPath, encoding: .utf8)
        let source = executorSource + endpointSource

        XCTAssertFalse(source.contains("writeChannelInput("))
        XCTAssertFalse(source.contains("AgentRemoteCommandExecutor"))
        XCTAssertFalse(source.contains("SSHExecChannel"))
        XCTAssertFalse(source.contains("TerminalView.pasteText"))
        XCTAssertFalse(source.contains("activeSession"))
        XCTAssertFalse(source.contains("selectedSession"))
        XCTAssertFalse(source.contains("run_command"))
        XCTAssertFalse(source.contains("print(") || source.contains("logger.info(\"payload"))
    }

    // MARK: - Fixtures

    private func makeEndpoint(
        transport: FakeRemoteInputTransport,
        mode: ModeBox,
        sessionID: UUID = AgentTerminalMutationTestSupport.sessionID,
        epoch: AgentTerminalInputTargetEpoch = 7,
        token: AgentTerminalEndpointToken = AgentTerminalMutationTestSupport.makeIdentity().endpointToken
    ) -> AgentRemoteTerminalMutationEndpoint {
        AgentRemoteTerminalMutationEndpoint(
            logicalSessionID: sessionID,
            inputTargetEpoch: epoch,
            endpointToken: token,
            hostDisplayName: "Remote A",
            transport: transport,
            modeSnapshotProvider: { mode.read() }
        )
    }

    private func makeAuthorized(
        sessionID: UUID = AgentTerminalMutationTestSupport.sessionID,
        epoch: AgentTerminalInputTargetEpoch = 7,
        token: AgentTerminalEndpointToken = AgentTerminalMutationTestSupport.makeIdentity().endpointToken,
        targetSnapshot: AgentTerminalMutationTargetSnapshot = .remote(hostDisplay: "Remote A"),
        text: String = "echo hi",
        submit: Bool = true,
        callID: String = UUID().uuidString
    ) async throws -> (
        coordinator: AgentTerminalMutationApprovalCoordinator,
        authorization: AgentTerminalMutationExecutionAuthorization
    ) {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
            callID: callID,
            sessionID: sessionID,
            epoch: epoch,
            token: token,
            targetSnapshot: targetSnapshot,
            text: text,
            submit: submit
        )
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        return (coordinator, authorization)
    }

    private func makeConnection() -> SSHConnection {
        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: "b3-s2-test.invalid",
            port: 22,
            username: "tester"
        )
        let configuration = SSHConnection.Configuration(
            hostID: info.hostID,
            hostname: info.hostname,
            port: info.port,
            username: info.username,
            authenticationType: .password,
            credentialID: nil,
            privateKeyPath: nil,
            privateKeyID: nil
        )
        return SSHConnection(
            configuration: configuration,
            info: info,
            knownHostService: knownHostService
        )
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

/// Remote fake transport：每次 write 都记录请求 batch 与 exact accepted prefix，
/// 并在 transaction 退出后才释放普通输入，模拟 B3 shared authority。
@MainActor
private final class FakeRemoteInputTransport: AgentRemoteTerminalMutationInputTransport {
    struct Step: Sendable {
        let acceptedBytes: Int
        let error: AgentRemoteTerminalMutationTransportError?
    }

    var steps: [Step]
    var onWrite: ((Int) -> Void)?
    private(set) var writeBatches: [[UInt8]] = []
    private(set) var physicalBytes: [UInt8] = []
    private(set) var transactionCount = 0
    private var ordinaryBatches: [[UInt8]] = []

    init(steps: [Step] = []) {
        self.steps = steps
    }

    func enqueueOrdinary(_ bytes: [UInt8]) {
        ordinaryBatches.append(bytes)
    }

    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentRemoteTerminalMutationTransactionWriter) async throws -> Void
    ) async throws {
        transactionCount += 1
        try await body(FakeRemoteInputWriter(transport: self))
        physicalBytes.append(contentsOf: ordinaryBatches.flatMap { $0 })
        ordinaryBatches.removeAll()
    }

    func nextResult(for requestedBytes: Int) -> AgentRemoteTerminalMutationWriteResult {
        let step = steps.isEmpty
            ? Step(acceptedBytes: requestedBytes, error: nil)
            : steps.removeFirst()
        return AgentRemoteTerminalMutationWriteResult(
            requestedBytes: requestedBytes,
            acceptedBytes: min(max(step.acceptedBytes, 0), requestedBytes),
            error: step.error
        )
    }

    func recordWrite(_ bytes: [UInt8], result: AgentRemoteTerminalMutationWriteResult) {
        let index = writeBatches.count
        writeBatches.append(bytes)
        onWrite?(index)
        physicalBytes.append(contentsOf: bytes.prefix(result.acceptedBytes))
    }
}

@MainActor
private final class FakeRemoteInputWriter: AgentRemoteTerminalMutationTransactionWriter {
    private let transport: FakeRemoteInputTransport

    init(transport: FakeRemoteInputTransport) {
        self.transport = transport
    }

    func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) async -> AgentRemoteTerminalMutationWriteResult {
        _ = forceWhenCancelled
        let array = Array(bytes)
        let result = transport.nextResult(for: array.count)
        transport.recordWrite(array, result: result)
        return result
    }
}

private actor TwoPartyStartBarrier {
    private var arrivals = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrivals += 1
        guard arrivals < 2 else {
            continuation?.resume()
            continuation = nil
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private actor B3InputBackendProbe {
    private var receivedBytes: [UInt8] = []

    func accept(bytes: [UInt8], offset: Int) -> SSHInteractiveInputTestWriteStep {
        let suffix = Array(bytes[offset...])
        receivedBytes.append(contentsOf: suffix)
        return .accepted(suffix.count)
    }

    func snapshot() -> [UInt8] {
        receivedBytes
    }
}
