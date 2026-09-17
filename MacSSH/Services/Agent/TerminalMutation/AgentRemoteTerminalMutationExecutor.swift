import Foundation
@preconcurrency import SwiftTerm

// MARK: - Remote acknowledged delivery engine

/// Remote mutation 的 acknowledged delivery engine。
///
/// 入口同时要求 B1 coordinator 产生的一次性 authorization 与一个 exact
/// Remote endpoint。成功 redeem 后只使用 coordinator 保存的 immutable request；
/// 不做 active-session lookup、不捕获 shell 输出、不打开 exec channel，且不做
/// whole-mutation retry。
@MainActor
final class AgentRemoteTerminalMutationExecutor {
    private let approvalCoordinator: AgentTerminalMutationApprovalCoordinator

    init(approvalCoordinator: AgentTerminalMutationApprovalCoordinator) {
        self.approvalCoordinator = approvalCoordinator
    }

    /// 尝试一次 Remote mutation delivery；第二次使用同一 authorization 会在
    /// coordinator redeem 处被拒绝，因此最多只能开始一条 physical transaction。
    func deliver(
        _ authorization: AgentTerminalMutationExecutionAuthorization,
        to endpoint: AgentRemoteTerminalMutationEndpoint
    ) async -> AgentTerminalMutationDeliveryResult {
        let authorizationRequest = authorization.request
        let payloadBytes = authorizationRequest.text.utf8.count

        guard Self.authorizationIsInternallyConsistent(authorization) else {
            return Self.rejectedResult(
                payloadBytesRequested: payloadBytes,
                error: .approvalStale
            )
        }

        // Remote request 的现有 hostDisplay 是展示快照；这里只验证 Remote
        // kind 与同一应用绑定的 display snapshot，不把它当作寻址机制。
        guard Self.remoteTargetMatches(authorizationRequest, endpoint: endpoint) else {
            return Self.rejectedResult(
                payloadBytesRequested: payloadBytes,
                error: .targetReplaced
            )
        }
        guard authorization.logicalSessionID == endpoint.logicalSessionID else {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: .targetReplaced)
        }
        guard authorization.targetIdentity.inputTargetEpoch == endpoint.inputTargetEpoch else {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: .targetReplaced)
        }
        guard authorization.targetIdentity.endpointToken == endpoint.endpointToken else {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: .targetReplaced)
        }
        guard endpoint.isAvailable else {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: .targetReplaced)
        }

        // admission 时只从 exact TerminalView 读取一次；后续所有阶段都使用
        // 同一个冻结值，即使 Terminal 在 transaction 中切换 mode 也不重读。
        guard let modeSnapshot = endpoint.bracketedPasteModeSnapshot() else {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: .targetReplaced)
        }

        let request: AgentTerminalMutationRequest
        do {
            // B1 唯一 redeem 线性化点；任何 Remote 字节都必须发生在 redeem 之后。
            request = try await approvalCoordinator.redeem(authorization)
        } catch let error as AgentTerminalMutationError {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: error)
        } catch {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: .approvalStale)
        }

        let accumulator = AgentRemoteTerminalMutationDeliveryAccumulator(
            payloadBytesRequested: request.text.utf8.count,
            bracketedPasteModeSnapshot: modeSnapshot
        )

        // redeem 的 actor await 期间 endpoint 可能已进入 stop / reconnect；
        // 此处只拒绝旧 capability，绝不寻找或改投 replacement endpoint。
        guard endpoint.isAvailable else {
            accumulator.recordError(.targetReplaced)
            accumulator.terminalInputState = .notAttempted
            accumulator.outcome = .rejected
            return accumulator.makeResult()
        }
        guard !Task.isCancelled else {
            accumulator.recordError(.cancelled)
            accumulator.terminalInputState = .confirmed
            accumulator.outcome = .failed
            return accumulator.makeResult()
        }

        do {
            try await endpoint.withExclusiveInputTransaction { writer in
                await self.perform(
                    request: request,
                    modeSnapshot: modeSnapshot,
                    writer: writer,
                    accumulator: accumulator
                )
            }
        } catch let error as AgentRemoteTerminalMutationTransportError {
            accumulator.recordError(Self.map(error))
            accumulator.terminalInputState = .confirmed
            accumulator.outcome = .failed
        } catch let error as SSHInteractiveInputTransportError {
            accumulator.recordError(Self.map(error))
            accumulator.terminalInputState = .confirmed
            accumulator.outcome = .failed
        } catch {
            accumulator.recordError(.transactionUnavailable)
            accumulator.terminalInputState = .confirmed
            accumulator.outcome = .failed
        }

        return accumulator.makeResult()
    }

    private func perform(
        request: AgentTerminalMutationRequest,
        modeSnapshot: Bool,
        writer: any AgentRemoteTerminalMutationTransactionWriter,
        accumulator: AgentRemoteTerminalMutationDeliveryAccumulator
    ) async {
        let start = EscapeSequences.bracketedPasteStart
        let end = EscapeSequences.bracketedPasteEnd
        let payload = Array(request.text.utf8)

        if modeSnapshot {
            guard !Task.isCancelled else {
                accumulator.recordError(.cancelled)
                return
            }
            let startResult = await writer.write(start[...], forceWhenCancelled: false)
            accumulator.recordFraming(startResult, requested: start.count)
            if startResult.acceptedBytes == 0 {
                accumulator.terminalInputState = .confirmed
                accumulator.outcome = .failed
                return
            }
            if startResult.acceptedBytes < start.count {
                accumulator.terminalInputState = .uncertain
                accumulator.outcome = .partial
                return
            }
            if startResult.error != nil {
                // START 的完整 prefix 已确认；不重发 START，最多发送一次
                // forced END repair，并停止 payload / CR。
                await repairEnd(end, writer: writer, accumulator: accumulator)
                accumulator.outcome = .partial
                return
            }
            if Task.isCancelled {
                accumulator.recordError(.cancelled)
                await repairEnd(end, writer: writer, accumulator: accumulator)
                accumulator.outcome = .partial
                return
            }
        }

        let payloadResult = await writer.write(payload[...], forceWhenCancelled: false)
        accumulator.recordPayload(payloadResult)
        let payloadFullyAccepted = payloadResult.acceptedBytes == payload.count
            && payloadResult.error == nil
        if !payloadFullyAccepted {
            if modeSnapshot {
                // START 已完整确认；payload 不完整时只允许一次 END repair。
                await repairEnd(end, writer: writer, accumulator: accumulator)
            } else {
                accumulator.terminalInputState = payloadResult.acceptedBytes > 0
                    ? .uncertain
                    : .confirmed
            }
            accumulator.outcome = payloadResult.acceptedBytes > 0 ? .partial : .failed
            return
        }

        if Task.isCancelled {
            accumulator.recordError(.cancelled)
            if modeSnapshot {
                await repairEnd(end, writer: writer, accumulator: accumulator)
            }
            accumulator.outcome = .partial
            return
        }

        if modeSnapshot {
            let endResult = await writer.write(end[...], forceWhenCancelled: false)
            accumulator.recordFraming(endResult, requested: end.count)
            if endResult.acceptedBytes < end.count || endResult.error != nil {
                accumulator.terminalInputState = .uncertain
                accumulator.outcome = .partial
                return
            }
            accumulator.terminalInputState = .confirmed
        }

        guard request.submit else {
            accumulator.outcome = .delivered
            return
        }
        guard !Task.isCancelled else {
            accumulator.recordError(.cancelled)
            accumulator.outcome = .partial
            return
        }

        // 与 SwiftTerm 的终端输入协议共享 canonical CR 定义；不在 Remote
        // mutation 层重新定义或转换提交字节。
        let carriageReturn = EscapeSequences.cmdRet
        accumulator.submitBytesRequested = carriageReturn.count
        let submitResult = await writer.write(carriageReturn[...], forceWhenCancelled: false)
        accumulator.recordSubmit(submitResult)
        // CR accepted 1 即表示 transport-level submitted；无论如何不重试 CR。
        accumulator.outcome = submitResult.acceptedBytes == carriageReturn.count
            ? .delivered
            : .partial
    }

    /// 仅在 START 完整确认后执行一次 best-effort END repair；不恢复 payload，
    /// 也不发送 CR，不把 partial 升级为 delivered。
    private func repairEnd(
        _ end: [UInt8],
        writer: any AgentRemoteTerminalMutationTransactionWriter,
        accumulator: AgentRemoteTerminalMutationDeliveryAccumulator
    ) async {
        let repair = await writer.write(end[...], forceWhenCancelled: Task.isCancelled)
        accumulator.recordFraming(repair, requested: end.count)
        accumulator.terminalInputState = repair.fullyAccepted ? .confirmed : .uncertain
    }

    private static func remoteTargetMatches(
        _ request: AgentTerminalMutationRequest,
        endpoint: AgentRemoteTerminalMutationEndpoint
    ) -> Bool {
        guard endpoint.terminalKind == .remoteSSH else {
            return false
        }
        guard case let .remote(hostDisplay) = request.targetSnapshot else {
            return false
        }
        return hostDisplay == endpoint.hostDisplayName
    }

    private static func authorizationIsInternallyConsistent(
        _ authorization: AgentTerminalMutationExecutionAuthorization
    ) -> Bool {
        authorization.generationID == authorization.request.generationID
            && authorization.callID == authorization.request.callID
            && authorization.logicalSessionID == authorization.request.logicalSessionID
            && authorization.targetIdentity == authorization.request.targetIdentity
    }

    private static func rejectedResult(
        payloadBytesRequested: Int,
        error: AgentTerminalMutationError
    ) -> AgentTerminalMutationDeliveryResult {
        AgentTerminalMutationDeliveryResult(
            payloadBytesRequested: payloadBytesRequested,
            payloadBytesAccepted: 0,
            framingBytesRequested: 0,
            framingBytesAccepted: 0,
            submitBytesRequested: 0,
            submitBytesAccepted: 0,
            bracketedPasteModeSnapshot: false,
            terminalInputState: .notAttempted,
            outcome: .rejected,
            error: error
        )
    }

    private static func map(
        _ error: AgentRemoteTerminalMutationTransportError
    ) -> AgentTerminalMutationError {
        switch error {
        case .connectionLost:
            return .connectionLost
        case .channelClosed:
            return .channelClosed
        case .targetReplaced:
            return .targetReplaced
        case .writeFailed:
            return .writeFailed
        case .cancelled:
            return .cancelled
        case .transactionUnavailable:
            return .transactionUnavailable
        }
    }

    private static func map(
        _ error: SSHInteractiveInputTransportError
    ) -> AgentTerminalMutationError {
        switch error {
        case .connectionLost:
            return .connectionLost
        case .channelClosed:
            return .channelClosed
        case .targetReplaced:
            return .targetReplaced
        case .writeFailed:
            return .writeFailed
        case .cancelled:
            return .cancelled
        case .transactionUnavailable:
            return .transactionUnavailable
        }
    }
}

// MARK: - Delivery accounting

/// Remote delivery 只在 MainActor 内累积结果，避免跨 await 共享裸变量；该模型
/// 与 Local 使用同一个 `AgentTerminalMutationDeliveryResult`，保持 partial
/// delivery 的可比性。
@MainActor
private final class AgentRemoteTerminalMutationDeliveryAccumulator {
    let payloadBytesRequested: Int
    let bracketedPasteModeSnapshot: Bool
    var payloadBytesAccepted = 0
    var framingBytesRequested = 0
    var framingBytesAccepted = 0
    var submitBytesRequested = 0
    var submitBytesAccepted = 0
    var terminalInputState: AgentTerminalMutationTerminalInputState = .confirmed
    var outcome: AgentTerminalMutationDeliveryOutcome = .failed
    var error: AgentTerminalMutationError?

    init(payloadBytesRequested: Int, bracketedPasteModeSnapshot: Bool) {
        self.payloadBytesRequested = payloadBytesRequested
        self.bracketedPasteModeSnapshot = bracketedPasteModeSnapshot
    }

    func recordError(_ error: AgentTerminalMutationError) {
        if self.error == nil {
            self.error = error
        }
    }

    func recordFraming(
        _ result: AgentRemoteTerminalMutationWriteResult,
        requested: Int
    ) {
        framingBytesRequested += requested
        framingBytesAccepted += Self.clamp(result.acceptedBytes, to: requested)
        if let error = result.error {
            recordError(Self.map(error))
        } else if result.acceptedBytes < requested {
            recordError(.writeFailed)
        }
    }

    func recordPayload(_ result: AgentRemoteTerminalMutationWriteResult) {
        payloadBytesAccepted = Self.clamp(result.acceptedBytes, to: payloadBytesRequested)
        if let error = result.error {
            recordError(Self.map(error))
        } else if result.acceptedBytes < payloadBytesRequested {
            recordError(.writeFailed)
        }
    }

    func recordSubmit(_ result: AgentRemoteTerminalMutationWriteResult) {
        submitBytesAccepted = Self.clamp(result.acceptedBytes, to: submitBytesRequested)
        if let error = result.error, result.acceptedBytes < submitBytesRequested {
            recordError(Self.map(error))
        } else if result.acceptedBytes < submitBytesRequested {
            recordError(.writeFailed)
        }
    }

    func makeResult() -> AgentTerminalMutationDeliveryResult {
        AgentTerminalMutationDeliveryResult(
            payloadBytesRequested: payloadBytesRequested,
            payloadBytesAccepted: payloadBytesAccepted,
            framingBytesRequested: framingBytesRequested,
            framingBytesAccepted: framingBytesAccepted,
            submitBytesRequested: submitBytesRequested,
            submitBytesAccepted: submitBytesAccepted,
            bracketedPasteModeSnapshot: bracketedPasteModeSnapshot,
            terminalInputState: terminalInputState,
            outcome: outcome,
            error: error
        )
    }

    private static func clamp(_ value: Int, to requested: Int) -> Int {
        min(max(value, 0), max(requested, 0))
    }

    private static func map(
        _ error: AgentRemoteTerminalMutationTransportError
    ) -> AgentTerminalMutationError {
        switch error {
        case .connectionLost:
            return .connectionLost
        case .channelClosed:
            return .channelClosed
        case .targetReplaced:
            return .targetReplaced
        case .writeFailed:
            return .writeFailed
        case .cancelled:
            return .cancelled
        case .transactionUnavailable:
            return .transactionUnavailable
        }
    }
}
