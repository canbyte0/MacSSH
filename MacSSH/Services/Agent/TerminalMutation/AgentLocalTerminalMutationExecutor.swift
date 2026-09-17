import Foundation
@preconcurrency import SwiftTerm

// MARK: - Result domain

/// 对 PTY 输入状态的保守判断；confirmed 只表示 transport 层边界已知，
/// 不表示 shell 已消费、执行或渲染 payload。
enum AgentTerminalMutationTerminalInputState: Sendable, Equatable {
    case notAttempted
    case confirmed
    case uncertain
}

/// 交付层 outcome；`partial` 明确保留了不可自动续传的部分副作用。
enum AgentTerminalMutationDeliveryOutcome: Sendable, Equatable {
    case delivered
    case partial
    case failed
    case rejected
}

/// Local mutation 的 acknowledged delivery 结果。
struct AgentTerminalMutationDeliveryResult: Sendable, Equatable {
    let payloadBytesRequested: Int
    let payloadBytesAccepted: Int
    let framingBytesRequested: Int
    let framingBytesAccepted: Int
    let submitBytesRequested: Int
    let submitBytesAccepted: Int
    let bracketedPasteModeSnapshot: Bool
    let terminalInputState: AgentTerminalMutationTerminalInputState
    let outcome: AgentTerminalMutationDeliveryOutcome
    let error: AgentTerminalMutationError?
}

// MARK: - Accumulator

/// 交付期间只在 MainActor 内修改，避免跨 await 共享裸变量。
@MainActor
private final class AgentTerminalMutationDeliveryAccumulator {
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

    func recordFraming(_ result: AgentLocalTerminalMutationWriteResult, requested: Int) {
        framingBytesRequested += requested
        framingBytesAccepted += Self.clamp(result.acceptedBytes, to: requested)
        if let error = result.error {
            recordError(Self.map(error))
        } else if result.acceptedBytes < requested {
            recordError(.writeFailed)
        }
    }

    func recordPayload(_ result: AgentLocalTerminalMutationWriteResult) {
        payloadBytesAccepted = Self.clamp(result.acceptedBytes, to: payloadBytesRequested)
        if let error = result.error {
            recordError(Self.map(error))
        } else if result.acceptedBytes < payloadBytesRequested {
            recordError(.writeFailed)
        }
    }

    func recordSubmit(_ result: AgentLocalTerminalMutationWriteResult) {
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
        _ error: AgentLocalTerminalMutationTransportError
    ) -> AgentTerminalMutationError {
        switch error {
        case .processUnavailable:
            return .processUnavailable
        case .channelClosed:
            return .channelClosed
        case .writeFailed:
            return .writeFailed
        case .cancelled:
            return .cancelled
        case .transactionUnavailable:
            return .transactionUnavailable
        }
    }
}

// MARK: - Executor

/// Local acknowledged delivery engine。
///
/// 入口同时要求 B1 coordinator 产生的 execution authorization 与一个 exact
/// endpoint capability。成功 redeem 后仍只使用 redeem 返回的 immutable request；
/// 不存在任何动态会话解析、自动重试或输出捕获路径。
@MainActor
final class AgentLocalTerminalMutationExecutor {
    private let approvalCoordinator: AgentTerminalMutationApprovalCoordinator

    init(approvalCoordinator: AgentTerminalMutationApprovalCoordinator) {
        self.approvalCoordinator = approvalCoordinator
    }

    /// 尝试一次 Local mutation delivery。相同 authorization 第二次会在 redeem
    /// 处被拒绝，因此最多只能启动一次 physical transaction。
    func deliver(
        _ authorization: AgentTerminalMutationExecutionAuthorization,
        to endpoint: AgentLocalTerminalMutationEndpoint
    ) async -> AgentTerminalMutationDeliveryResult {
        let authorizationRequest = authorization.request
        let payloadBytes = authorizationRequest.text.utf8.count

        guard Self.authorizationIsInternallyConsistent(authorization) else {
            return Self.rejectedResult(
                payloadBytesRequested: payloadBytes,
                error: .approvalStale
            )
        }

        // 三个字段分别比较：session 相同不足以授权，epoch/token 任一漂移都拒绝。
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

        // admission 时读取一次，之后整个 physical transaction 固定使用这个值。
        guard let modeSnapshot = endpoint.bracketedPasteModeSnapshot() else {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: .targetReplaced)
        }

        let request: AgentTerminalMutationRequest
        do {
            // 这是 B1 唯一 redeem 路径；redeem 之前没有任何 PTY 写入。
            request = try await approvalCoordinator.redeem(authorization)
        } catch let error as AgentTerminalMutationError {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: error)
        } catch {
            return Self.rejectedResult(payloadBytesRequested: payloadBytes, error: .approvalStale)
        }

        let accumulator = AgentTerminalMutationDeliveryAccumulator(
            payloadBytesRequested: request.text.utf8.count,
            bracketedPasteModeSnapshot: modeSnapshot
        )

        // endpoint 可能在 redeem 的 actor await 期间进入 termination；再次检查只
        // 决定是否开始 transaction，不会把旧 capability 重定向到任何新对象。
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
        } catch let error as AgentLocalTerminalMutationTransportError {
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
        writer: any AgentLocalTerminalMutationTransactionWriter,
        accumulator: AgentTerminalMutationDeliveryAccumulator
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
                // START 的 6 bytes 已确认但同时有 transport error：保守停止 payload，
                // 最多尝试一次 forced END 修复，不重发 START。
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

        let carriageReturn: [UInt8] = [0x0D]
        accumulator.submitBytesRequested = carriageReturn.count
        let submitResult = await writer.write(carriageReturn[...], forceWhenCancelled: false)
        accumulator.recordSubmit(submitResult)
        // accepted == 1 已经在 transport 层提交；即使伴随 error 也不重试 CR。
        if submitResult.acceptedBytes == carriageReturn.count {
            accumulator.outcome = .delivered
        } else {
            accumulator.outcome = .partial
        }
    }

    /// 只用于已完整 START 后的单次 END repair；绝不用于 payload 或整帧重试。
    private func repairEnd(
        _ end: [UInt8],
        writer: any AgentLocalTerminalMutationTransactionWriter,
        accumulator: AgentTerminalMutationDeliveryAccumulator
    ) async {
        let repair = await writer.write(end[...], forceWhenCancelled: Task.isCancelled)
        accumulator.recordFraming(repair, requested: end.count)
        // 修复帧只看本次 acknowledged 前缀，不从累计 framing 反推，避免未来
        // 增加其他合法 framing 阶段时把历史字节误算为本次 END 结果。
        accumulator.terminalInputState = repair.fullyAccepted ? .confirmed : .uncertain
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
        _ error: AgentLocalTerminalMutationTransportError
    ) -> AgentTerminalMutationError {
        switch error {
        case .processUnavailable:
            return .processUnavailable
        case .channelClosed:
            return .channelClosed
        case .writeFailed:
            return .writeFailed
        case .cancelled:
            return .cancelled
        case .transactionUnavailable:
            return .transactionUnavailable
        }
    }
}
