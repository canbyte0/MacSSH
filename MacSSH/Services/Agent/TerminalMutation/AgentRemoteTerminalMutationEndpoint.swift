import AppKit
@preconcurrency import SwiftTerm

// MARK: - Remote input transport seam

/// Remote mutation 层使用的稳定传输错误；不把 SSH actor 或 libssh2 细节
/// 泄漏到 Agent 领域。生产 endpoint 只允许从 B3 acknowledged transaction
/// 进入，不调用普通 `writeChannelInput`。
enum AgentRemoteTerminalMutationTransportError: Error, Equatable, Sendable {
    case connectionLost
    case channelClosed
    case targetReplaced
    case writeFailed
    case cancelled
    case transactionUnavailable
}

/// Remote 一次物理写入的 acknowledged 结果；acceptedBytes 永远表示已确认
/// 的连续 prefix，即使同时返回 error 也不得归零。
struct AgentRemoteTerminalMutationWriteResult: Equatable, Sendable {
    let requestedBytes: Int
    let acceptedBytes: Int
    let error: AgentRemoteTerminalMutationTransportError?

    var fullyAccepted: Bool {
        acceptedBytes == requestedBytes && error == nil
    }
}

/// Remote exclusive transaction 中暴露给 Agent executor 的窄写入能力。
@MainActor
protocol AgentRemoteTerminalMutationTransactionWriter: AnyObject, Sendable {
    func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) async -> AgentRemoteTerminalMutationWriteResult
}

/// Remote endpoint 的唯一多写入 transaction 能力。
@MainActor
protocol AgentRemoteTerminalMutationInputTransport: AnyObject, Sendable {
    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentRemoteTerminalMutationTransactionWriter) async throws -> Void
    ) async throws
}

// MARK: - B3 adapter

/// 将 B3-S1 的 acknowledged transaction writer 收窄给 Remote mutation。
@MainActor
private final class SSHRemoteTerminalMutationTransactionWriter: AgentRemoteTerminalMutationTransactionWriter {
    private let transaction: SSHInteractiveInputTransaction

    init(transaction: SSHInteractiveInputTransaction) {
        self.transaction = transaction
    }

    func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) async -> AgentRemoteTerminalMutationWriteResult {
        // B3 writer 自身已经实现取消时的精确 settlement；force 参数在
        // Remote endpoint 上保留，用于唯一一次 repair END，绝不重试 payload。
        _ = forceWhenCancelled
        let result = await transaction.writeAcknowledged(bytes)
        return AgentRemoteTerminalMutationWriteResult(
            requestedBytes: result.requestedBytes,
            acceptedBytes: result.acceptedBytes,
            error: Self.map(result.error)
        )
    }

    private static func map(
        _ error: SSHInteractiveInputTransportError?
    ) -> AgentRemoteTerminalMutationTransportError? {
        switch error {
        case nil:
            return nil
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

// MARK: - Remote incarnation capability

/// 一个 Remote interactive shell incarnation 的不可替代 mutation capability。
///
/// 该对象同时强持有：
/// - B3-S1 返回的 exact `SSHInteractiveInputEndpoint`，其内部绑定 exact
///   `SSHConnection` actor 与 exact shell incarnation；
/// - 当次 Remote `TerminalView`，只用于 admission 时读取 bracketed-paste
///   mode，不作为输入 authority。
///
/// endpoint 创建后只读身份不会改变；生命周期 owner 只能使其失效，不能把它
/// 重定向到另一条连接、另一代 shell 或另一枚 token。
@MainActor
final class AgentRemoteTerminalMutationEndpoint {
    let logicalSessionID: UUID
    let inputTargetEpoch: AgentTerminalInputTargetEpoch
    let endpointToken: AgentTerminalEndpointToken
    let terminalKind: AgentTerminalSessionKind = .remoteSSH
    let hostDisplayName: String

    /// 精确 B3 capability；绝不从 SessionManager 或 RemoteTerminalService
    /// 的可变 connection 属性重新解析。
    private let exactInputEndpoint: SSHInteractiveInputEndpoint?
    private let inputTransport: (any AgentRemoteTerminalMutationInputTransport)?
    private let exactTerminalView: TerminalView?
    private let testModeSnapshotProvider: (@MainActor () -> Bool)?
    private(set) var isAvailable = true

    /// 生产 endpoint：绑定当前已经成功打开的 Remote interactive shell。
    init(
        logicalSessionID: UUID,
        inputTargetEpoch: AgentTerminalInputTargetEpoch,
        endpointToken: AgentTerminalEndpointToken,
        hostDisplayName: String,
        inputEndpoint: SSHInteractiveInputEndpoint,
        terminalView: TerminalView
    ) {
        self.logicalSessionID = logicalSessionID
        self.inputTargetEpoch = inputTargetEpoch
        self.endpointToken = endpointToken
        self.hostDisplayName = hostDisplayName
        exactInputEndpoint = inputEndpoint
        inputTransport = nil
        exactTerminalView = terminalView
        testModeSnapshotProvider = nil
    }

    /// 测试专用 deterministic transport 构造入口；生产生命周期不使用。
    init(
        logicalSessionID: UUID,
        inputTargetEpoch: AgentTerminalInputTargetEpoch,
        endpointToken: AgentTerminalEndpointToken,
        hostDisplayName: String,
        transport: any AgentRemoteTerminalMutationInputTransport,
        modeSnapshotProvider: @escaping @MainActor () -> Bool
    ) {
        self.logicalSessionID = logicalSessionID
        self.inputTargetEpoch = inputTargetEpoch
        self.endpointToken = endpointToken
        self.hostDisplayName = hostDisplayName
        exactInputEndpoint = nil
        inputTransport = transport
        exactTerminalView = nil
        testModeSnapshotProvider = modeSnapshotProvider
    }

    /// Shell stop / exit / reconnect 开始时撤销旧 capability；旧对象仍可被
    /// 外部持有，但之后不会再申请新的 mutation transaction。
    func invalidate() {
        isAvailable = false
    }

    /// 在 transaction admission 前只读取一次精确目标终端的 bracket mode。
    func bracketedPasteModeSnapshot() -> Bool? {
        guard isAvailable else {
            return nil
        }
        if let exactTerminalView {
            return exactTerminalView.terminal?.bracketedPasteMode ?? false
        }
        return testModeSnapshotProvider?()
    }

    /// Remote mutation 的唯一物理入口；生产路径只能经过 B3 exclusive
    /// transaction，普通 keyboard / paste 仍走 B3 shared FIFO。
    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentRemoteTerminalMutationTransactionWriter) async throws -> Void
    ) async throws {
        guard isAvailable else {
            throw AgentRemoteTerminalMutationTransportError.targetReplaced
        }

        if let exactInputEndpoint {
            try await exactInputEndpoint.withExclusiveInteractiveInputTransaction { transaction in
                try await body(SSHRemoteTerminalMutationTransactionWriter(transaction: transaction))
            }
            return
        }

        guard let inputTransport else {
            throw AgentRemoteTerminalMutationTransportError.channelClosed
        }
        try await inputTransport.withExclusiveInputTransaction(body)
    }
}
