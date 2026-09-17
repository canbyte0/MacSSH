import AppKit
import SwiftTerm

// MARK: - Local input transport seam

/// Local mutation 层使用的稳定传输错误；不把 SwiftTerm 的 errno 或对象细节
/// 泄漏到 Agent 领域。生产实现只允许从 SwiftTerm 的 exclusive transaction 进入。
enum AgentLocalTerminalMutationTransportError: Error, Equatable, Sendable {
    case processUnavailable
    case channelClosed
    case writeFailed
    case cancelled
    case transactionUnavailable
}

/// 一次物理写入的 acknowledged 结果。acceptedBytes 始终表示已确认的前缀。
struct AgentLocalTerminalMutationWriteResult: Equatable, Sendable {
    let requestedBytes: Int
    let acceptedBytes: Int
    let error: AgentLocalTerminalMutationTransportError?

    var fullyAccepted: Bool {
        acceptedBytes == requestedBytes && error == nil
    }
}

/// exclusive transaction 中可用的窄写入能力。
@MainActor
protocol AgentLocalTerminalMutationTransactionWriter: AnyObject, Sendable {
    func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) async -> AgentLocalTerminalMutationWriteResult
}

/// Local endpoint 唯一使用的多写入 transaction 能力。
@MainActor
protocol AgentLocalTerminalMutationInputTransport: AnyObject, Sendable {
    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentLocalTerminalMutationTransactionWriter) async throws -> Void
    ) async throws
}

// SwiftTerm 该固定 revision 的 writer 由自己的 transport authority 串行化；
// MacSSH 只把它包进下方的窄 capability，不把 writer 暴露给其他路径。
extension LocalProcessInputTransactionWriter: @retroactive @unchecked Sendable {}

// MARK: - SwiftTerm adapter

/// 将固定 revision 的 SwiftTerm writer 收窄成 Agent 交付层需要的接口。
@MainActor
private final class SwiftTermLocalTerminalMutationWriter: AgentLocalTerminalMutationTransactionWriter {
    private let writer: LocalProcessInputTransactionWriter

    init(writer: LocalProcessInputTransactionWriter) {
        self.writer = writer
    }

    func write(
        _ bytes: ArraySlice<UInt8>,
        forceWhenCancelled: Bool
    ) async -> AgentLocalTerminalMutationWriteResult {
        let result = await writer.write(bytes, forceWhenCancelled: forceWhenCancelled)
        return AgentLocalTerminalMutationWriteResult(
            requestedBytes: result.requestedBytes,
            acceptedBytes: result.acceptedBytes,
            error: Self.map(result.error)
        )
    }

    private static func map(
        _ error: LocalProcessInputTransportError?
    ) -> AgentLocalTerminalMutationTransportError? {
        switch error {
        case nil:
            return nil
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

/// 生产 adapter 强引用固定的 SwiftTerm input transport；不通过会话或标签
/// 重新解析目标。
@MainActor
private final class SwiftTermLocalTerminalMutationTransport: AgentLocalTerminalMutationInputTransport {
    private let transport: LocalProcessInputTransport

    init(transport: LocalProcessInputTransport) {
        self.transport = transport
    }

    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentLocalTerminalMutationTransactionWriter) async throws -> Void
    ) async throws {
        do {
            try await transport.withExclusiveInputTransaction { @Sendable writer in
                try await body(SwiftTermLocalTerminalMutationWriter(writer: writer))
            }
        } catch let error as LocalProcessInputTransportError {
            throw Self.map(error)
        }
    }

    private static func map(
        _ error: LocalProcessInputTransportError
    ) -> AgentLocalTerminalMutationTransportError {
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

// MARK: - Incarnation capability

/// 一个 Local PTY/process incarnation 的不可替代 capability。
///
/// 生产初始化器同时强引用准确的 `LocalProcess`、`LocalProcessInputTransport`
/// 和为 bracketed-paste snapshot 所需的 terminal view。endpoint 的 identity
/// 只使用 session / epoch / token 三元组；物理 authority 永远来自这一次
/// 初始化时捕获的对象，不从任何可变会话集合解析。
@MainActor
final class AgentLocalTerminalMutationEndpoint {
    let logicalSessionID: UUID
    let inputTargetEpoch: AgentTerminalInputTargetEpoch
    let endpointToken: AgentTerminalEndpointToken

    /// 强引用旧 process，保证 capability 的 authority 不会被数字 fd 替代。
    private let exactProcess: LocalProcess?
    private let exactTerminalView: LocalProcessTerminalView?
    private let inputTransport: any AgentLocalTerminalMutationInputTransport
    private let testModeSnapshotProvider: (@MainActor () -> Bool)?
    private(set) var isAvailable = true

    /// 生产 endpoint：绑定一个已经启动且已经 attach inputTransport 的 PTY。
    init(
        logicalSessionID: UUID,
        inputTargetEpoch: AgentTerminalInputTargetEpoch,
        endpointToken: AgentTerminalEndpointToken,
        process: LocalProcess,
        terminalView: LocalProcessTerminalView
    ) {
        self.logicalSessionID = logicalSessionID
        self.inputTargetEpoch = inputTargetEpoch
        self.endpointToken = endpointToken
        exactProcess = process
        exactTerminalView = terminalView
        inputTransport = SwiftTermLocalTerminalMutationTransport(
            transport: process.inputTransport
        )
        testModeSnapshotProvider = nil
    }

    /// 仅供 MacSSH focused tests 使用的 deterministic transport 构造入口。
    /// 测试 authority 仍是一个独立 endpoint 对象，不会进入生产会话解析。
    init(
        logicalSessionID: UUID,
        inputTargetEpoch: AgentTerminalInputTargetEpoch,
        endpointToken: AgentTerminalEndpointToken,
        transport: any AgentLocalTerminalMutationInputTransport,
        modeSnapshotProvider: @escaping @MainActor () -> Bool
    ) {
        self.logicalSessionID = logicalSessionID
        self.inputTargetEpoch = inputTargetEpoch
        self.endpointToken = endpointToken
        exactProcess = nil
        exactTerminalView = nil
        inputTransport = transport
        testModeSnapshotProvider = modeSnapshotProvider
    }

    /// 生命周期 owner 在 termination 开始时调用；旧对象仍可存活，但不再接收新交付。
    func invalidate() {
        isAvailable = false
    }

    /// 在 transaction admission 前只读取一次准确 Terminal 的 bracketed mode。
    func bracketedPasteModeSnapshot() -> Bool? {
        guard isAvailable else {
            return nil
        }
        if let exactTerminalView {
            return exactTerminalView.terminal?.bracketedPasteMode ?? false
        }
        return testModeSnapshotProvider?()
    }

    /// 交付层的唯一物理入口：固定 transport 的 exclusive multi-write transaction。
    func withExclusiveInputTransaction(
        _ body: @escaping @MainActor @Sendable (any AgentLocalTerminalMutationTransactionWriter) async throws -> Void
    ) async throws {
        guard isAvailable else {
            throw AgentLocalTerminalMutationTransportError.channelClosed
        }
        try await inputTransport.withExclusiveInputTransaction(body)
    }
}
