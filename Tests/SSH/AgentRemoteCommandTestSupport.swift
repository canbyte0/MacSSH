import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

// MARK: - fake libssh2 exec 边界

/// 单次注入的 libssh2 调用结果（open / exec / EOF / signal / close 族）。
enum AgentRemoteExecFakeOutcome: Sendable {
    /// 成功（open → channel；其余 → 0）。
    case ok
    /// `LIBSSH2_ERROR_EAGAIN`。
    case eagain
    /// 非 EAGAIN 的拒绝（服务器拒绝 / 协议错误）。
    case rejected
    /// 传输级失败（open 时表现为 lastSessionError 非 EAGAIN）。
    case transportFailure
}

/// 单次注入的读取结果。
enum AgentRemoteExecFakeReadStep: Sendable {
    case bytes([UInt8])
    /// 返回 0（无数据、未 EOF）——等价 EAGAIN 的可重试状态。
    case wouldBlock
    /// 返回 `LIBSSH2_ERROR_EAGAIN`。
    case eagain
    /// 返回 0 且 channel EOF 位置位。
    case eof
    /// 返回 `LIBSSH2_ERROR_SOCKET_RECV`（连接级失败）。
    case socketFailure
    /// 返回其他非 EAGAIN 错误（协议级失败）。
    case failure
}

/// Phase 10E-B3 的确定性 libssh2 exec 边界替身（**仅测试**）。
///
/// 覆盖 open / exec / EOF / stdout / stderr / EAGAIN / exit status / exit
/// signal / signal request / close / free / 连接丢失；记录真实调用次数，
/// 用于 channel 泄漏与 double-free 审计。生产路径不使用本类型。
final class AgentRemoteExecFakeLibssh2: @unchecked Sendable {
    /// fake 指针身份（不指向真实内存；计算属性避免非 Sendable 静态存储）。
    static var sessionPointer: OpaquePointer { OpaquePointer(bitPattern: 0x5E55_1000)! }
    static var channelPointer: OpaquePointer { OpaquePointer(bitPattern: 0xC4A0_2000)! }

    private let lock = NSLock()

    // MARK: 脚本（按调用次序消费；耗尽后使用默认值）
    private var openScript: [AgentRemoteExecFakeOutcome] = []
    private var execScript: [AgentRemoteExecFakeOutcome] = []
    private var eofScript: [AgentRemoteExecFakeOutcome] = []
    private var signalScript: [AgentRemoteExecFakeOutcome] = []
    private var closeScript: [AgentRemoteExecFakeOutcome] = []
    private var waitClosedScript: [AgentRemoteExecFakeOutcome] = []
    private var freeScript: [Int32] = []
    private var stdoutScript: [AgentRemoteExecFakeReadStep] = []
    private var stderrScript: [AgentRemoteExecFakeReadStep] = []
    /// 单次 read 容量小于注入块时，剩余字节留待下一次 read（与 libssh2 一致）。
    private var stdoutPending: [UInt8] = []
    private var stderrPending: [UInt8] = []
    private var channelEOF = false
    /// 最近一次 open 结果：`libssh2_session_last_errno` 的等价值。
    private var lastOpenOutcome: AgentRemoteExecFakeOutcome = .ok

    /// 信号请求是否模拟「远端进程被终止」（置位 channel EOF）。
    /// 默认 false：TERM / KILL 被忽略（最坏情形，验证有界收口）。
    private var killsOnSignal = false

    private var exitStatusValue: Int32?
    private var hasExitStatus = false
    private var exitSignalValue: (String?, String?) = (nil, nil)

    // MARK: 计数
    private var storedOpenCallCount = 0
    private var storedExecRequestCallCount = 0
    private var storedExecRequestCommands: [String] = []
    private var storedSendEOFCallCount = 0
    private var storedStdoutReadCallCount = 0
    private var storedStderrReadCallCount = 0
    private var storedSignalCallCount = 0
    private var storedRequestedSignals: [String] = []
    private var storedCloseCallCount = 0
    private var storedWaitClosedCallCount = 0
    private var storedFreeCallCount = 0
    private var storedHasExitStatusCallCount = 0
    private var storedExitStatusCallCount = 0
    private var storedExitSignalCallCount = 0

    // MARK: 配置

    func enqueueOpen(_ outcome: AgentRemoteExecFakeOutcome) {
        lock.lock(); defer { lock.unlock() }
        openScript.append(outcome)
    }

    func enqueueExecRequest(_ outcome: AgentRemoteExecFakeOutcome) {
        lock.lock(); defer { lock.unlock() }
        execScript.append(outcome)
    }

    func enqueueSendEOF(_ outcome: AgentRemoteExecFakeOutcome) {
        lock.lock(); defer { lock.unlock() }
        eofScript.append(outcome)
    }

    func enqueueSignal(_ outcome: AgentRemoteExecFakeOutcome) {
        lock.lock(); defer { lock.unlock() }
        signalScript.append(outcome)
    }

    func enqueueClose(_ outcome: AgentRemoteExecFakeOutcome) {
        lock.lock(); defer { lock.unlock() }
        closeScript.append(outcome)
    }

    func enqueueWaitClosed(_ outcome: AgentRemoteExecFakeOutcome) {
        lock.lock(); defer { lock.unlock() }
        waitClosedScript.append(outcome)
    }

    func enqueueFree(_ code: Int32) {
        lock.lock(); defer { lock.unlock() }
        freeScript.append(code)
    }

    func enqueueStdoutRead(_ step: AgentRemoteExecFakeReadStep) {
        lock.lock(); defer { lock.unlock() }
        stdoutScript.append(step)
    }

    func enqueueStderrRead(_ step: AgentRemoteExecFakeReadStep) {
        lock.lock(); defer { lock.unlock() }
        stderrScript.append(step)
    }

    /// 把文本 / 字节块追加为若干 `.bytes` 步骤。
    func enqueueStdout(_ chunks: [String]) {
        for chunk in chunks {
            enqueueStdoutRead(.bytes(Array(chunk.utf8)))
        }
    }

    func enqueueStderr(_ chunks: [String]) {
        for chunk in chunks {
            enqueueStderrRead(.bytes(Array(chunk.utf8)))
        }
    }

    /// 追加 `.bytes` 步骤（原始字节，用于二进制 / 非 UTF-8 用例）。
    func enqueueStdoutBytes(_ chunks: [[UInt8]]) {
        for chunk in chunks {
            enqueueStdoutRead(.bytes(chunk))
        }
    }

    func enqueueStderrBytes(_ chunks: [[UInt8]]) {
        for chunk in chunks {
            enqueueStderrRead(.bytes(chunk))
        }
    }

    func markChannelEOF() {
        lock.lock(); defer { lock.unlock() }
        channelEOF = true
    }

    /// 复位流状态与脚本（多轮压测复用同一 fake 时使用；killsOnSignal 等配置保持不变）。
    func resetChannelAndScripts() {
        lock.lock(); defer { lock.unlock() }
        channelEOF = false
        stdoutScript.removeAll()
        stderrScript.removeAll()
        stdoutPending.removeAll()
        stderrPending.removeAll()
        openScript.removeAll()
        execScript.removeAll()
        eofScript.removeAll()
        signalScript.removeAll()
        closeScript.removeAll()
        waitClosedScript.removeAll()
        freeScript.removeAll()
        lastOpenOutcome = .ok
    }

    func setKillsOnSignal(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        killsOnSignal = value
    }

    func setExitStatus(_ status: Int32) {
        lock.lock(); defer { lock.unlock() }
        exitStatusValue = status
        hasExitStatus = true
    }

    func clearExitStatus() {
        lock.lock(); defer { lock.unlock() }
        exitStatusValue = nil
        hasExitStatus = false
    }

    func setExitSignal(name: String?, errorMessage: String?) {
        lock.lock(); defer { lock.unlock() }
        exitSignalValue = (name, errorMessage)
    }

    // MARK: 计数读取

    var openCallCount: Int { locked { storedOpenCallCount } }
    var execRequestCallCount: Int { locked { storedExecRequestCallCount } }
    var execRequestCommands: [String] { locked { storedExecRequestCommands } }
    var sendEOFCallCount: Int { locked { storedSendEOFCallCount } }
    var stdoutReadCallCount: Int { locked { storedStdoutReadCallCount } }
    var stderrReadCallCount: Int { locked { storedStderrReadCallCount } }
    var signalCallCount: Int { locked { storedSignalCallCount } }
    var requestedSignals: [String] { locked { storedRequestedSignals } }
    var closeCallCount: Int { locked { storedCloseCallCount } }
    var waitClosedCallCount: Int { locked { storedWaitClosedCallCount } }
    var freeCallCount: Int { locked { storedFreeCallCount } }
    var hasExitStatusCallCount: Int { locked { storedHasExitStatusCallCount } }
    var exitStatusCallCount: Int { locked { storedExitStatusCallCount } }
    var exitSignalCallCount: Int { locked { storedExitSignalCallCount } }

    // MARK: 生产注入边界

    var operations: SSHExecChannelOperations {
        SSHExecChannelOperations(
            openSessionChannel: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                storedOpenCallCount += 1
                let outcome = openScript.isEmpty ? .ok : openScript.removeFirst()
                lastOpenOutcome = outcome
                switch outcome {
                case .ok: return Self.channelPointer
                case .eagain, .rejected, .transportFailure: return nil
                }
            },
            requestExec: { [self] _, commandPointer, commandLength in
                lock.lock(); defer { lock.unlock() }
                storedExecRequestCallCount += 1
                storedExecRequestCommands.append(
                    String(
                        decoding: UnsafeRawBufferPointer(
                            start: commandPointer, count: Int(commandLength)
                        ),
                        as: UTF8.self
                    )
                )
                return Self.code(for: execScript.isEmpty ? .ok : execScript.removeFirst())
            },
            sendEOF: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                storedSendEOFCallCount += 1
                return Self.code(for: eofScript.isEmpty ? .ok : eofScript.removeFirst())
            },
            readStream: { [self] _, streamID, buffer, capacity in
                lock.lock(); defer { lock.unlock() }
                if streamID == 0 {
                    storedStdoutReadCallCount += 1
                } else {
                    storedStderrReadCallCount += 1
                }
                if streamID == 0, !stdoutPending.isEmpty {
                    let served = Self.copyToBuffer(stdoutPending, buffer, capacity)
                    stdoutPending.removeFirst(served)
                    return served
                }
                if streamID != 0, !stderrPending.isEmpty {
                    let served = Self.copyToBuffer(stderrPending, buffer, capacity)
                    stderrPending.removeFirst(served)
                    return served
                }
                let step = streamID == 0
                    ? (stdoutScript.isEmpty ? .wouldBlock : stdoutScript.removeFirst())
                    : (stderrScript.isEmpty ? .wouldBlock : stderrScript.removeFirst())
                switch step {
                case .bytes(let data):
                    let served = Self.copyToBuffer(data, buffer, capacity)
                    if served < data.count {
                        let remainder = Array(data.dropFirst(served))
                        if streamID == 0 {
                            stdoutPending = remainder
                        } else {
                            stderrPending = remainder
                        }
                    }
                    return served
                case .wouldBlock:
                    return 0
                case .eagain:
                    return Int(LIBSSH2_ERROR_EAGAIN)
                case .eof:
                    channelEOF = true
                    return 0
                case .socketFailure:
                    return Int(LIBSSH2_ERROR_SOCKET_RECV)
                case .failure:
                    return Int(LIBSSH2_ERROR_PROTO)
                }
            },
            isEOF: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                return channelEOF ? 1 : 0
            },
            requestSignal: { [self] _, namePointer, nameLength in
                lock.lock(); defer { lock.unlock() }
                storedSignalCallCount += 1
                let name = String(
                    decoding: UnsafeRawBufferPointer(start: namePointer, count: nameLength),
                    as: UTF8.self
                )
                storedRequestedSignals.append(name)
                let outcome = signalScript.isEmpty ? .ok : signalScript.removeFirst()
                if killsOnSignal, case .ok = outcome {
                    channelEOF = true
                }
                return Self.code(for: outcome)
            },
            closeChannel: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                storedCloseCallCount += 1
                return Self.code(for: closeScript.isEmpty ? .ok : closeScript.removeFirst())
            },
            waitClosed: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                storedWaitClosedCallCount += 1
                return Self.code(for: waitClosedScript.isEmpty ? .ok : waitClosedScript.removeFirst())
            },
            freeChannel: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                storedFreeCallCount += 1
                return freeScript.isEmpty ? 0 : freeScript.removeFirst()
            },
            hasExitStatus: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                storedHasExitStatusCallCount += 1
                return hasExitStatus ? 1 : 0
            },
            exitStatus: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                storedExitStatusCallCount += 1
                return exitStatusValue ?? 0
            },
            exitSignal: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                storedExitSignalCallCount += 1
                return exitSignalValue
            },
            lastSessionError: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                // 与 libssh2 语义等价：最近一次 open 未成功时报告其原因
                // （EAGAIN 可重试；拒绝 / 传输失败不可重试）。
                switch lastOpenOutcome {
                case .ok, .eagain:
                    return LIBSSH2_ERROR_EAGAIN
                case .rejected, .transportFailure:
                    return LIBSSH2_ERROR_SOCKET_SEND
                }
            }
        )
    }

    // MARK: Private

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// 把至多 `capacity` 字节写入读缓冲；返回实际写入数。
    private static func copyToBuffer(
        _ data: [UInt8],
        _ buffer: UnsafeMutablePointer<CChar>,
        _ capacity: Int
    ) -> Int {
        let count = min(data.count, capacity)
        for index in 0..<count {
            buffer[index] = CChar(bitPattern: data[index])
        }
        return count
    }

    private static func code(for outcome: AgentRemoteExecFakeOutcome) -> Int32 {
        switch outcome {
        case .ok: 0
        case .eagain: LIBSSH2_ERROR_EAGAIN
        case .rejected: Int32(LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED)
        case .transportFailure: LIBSSH2_ERROR_SOCKET_SEND
        }
    }
}

// MARK: - 测试装配

/// Phase 10E-B3 测试共享装配。
///
/// 所有 fake 连接都是**真实 `SSHConnection` actor** + 注入的 fake libssh2 边界：
/// 生产路径本身不被替换，只是 libssh2 调用边界被替身占用（无真实服务器）。
enum AgentRemoteExecTestSupport {
    /// 快速失败策略（200ms timeout / 100ms grace）——绝不真的等 production 60s。
    static let fastPolicy = AgentRemoteCommandExecutionPolicy(
        timeout: .milliseconds(200),
        terminationGracePeriod: .milliseconds(100)
    )

    /// 任意「远端」cwd（fake transport 不解析路径；仅 builder 语义在此层无关）。
    static let remoteWorkingDirectory = "/tmp/macssh-b3-fake-remote"

    /// 每次调用创建独立的 in-memory KnownHost 容器（不触碰用户数据）。
    @MainActor
    static func makeKnownHostService() throws -> KnownHostService {
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return KnownHostService(modelContainer: container)
    }

    /// 构造真实 `SSHConnection`（**不** connect）：session 与 readiness 等待由
    /// fake 提供——除 libssh2 边界外，全部逻辑都是生产实现。
    @MainActor
    static func makeFakeSessionConnection(
        fake: AgentRemoteExecFakeLibssh2
    ) async throws -> SSHConnection {
        let knownHostService = try makeKnownHostService()
        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: "127.0.0.1",
            port: 22,
            username: "b3-fake"
        )
        let configuration = SSHConnection.Configuration(
            hostID: info.hostID,
            hostname: info.hostname,
            port: info.port,
            username: info.username,
            authenticationType: .privateKey,
            credentialID: nil,
            privateKeyPath: nil,
            privateKeyID: nil
        )
        let connection = SSHConnection(
            configuration: configuration,
            info: info,
            knownHostService: knownHostService,
            sessionTeardownOperations: SSHConnection.SessionTeardownOperations(
                disconnect: { _, _ in 0 },
                free: { _ in 0 },
                afterDisconnectEAGAIN: {}
            ),
            execChannelOperations: fake.operations
        )
        // fake session（绝不调用真实 libssh2；readiness 走注入 hook）。
        await connection.setTestExecChannelReadinessWait { slice in
            // 真实 poll 的等价物：固定让出一个很短的片段（绝不让测试睡满预算）。
            let capped = min(slice, 0.01)
            try? await Task.sleep(nanoseconds: UInt64(capped * 1_000_000_000))
        }
        await connection.setTestSessionPointer(AgentRemoteExecFakeLibssh2.sessionPointer)
        return connection
    }

    /// 显式 sessionID → 连接（A/B 隔离测试用不同实例）。
    static func makeResolver(
        mapping: [UUID: SSHConnection]
    ) -> AgentRemoteCommandSessionResolver {
        AgentRemoteCommandSessionResolver { sessionID in
            mapping[sessionID]
        }
    }

    /// 走完整 request → approval → claim 链，产出一次性授权（Remote target）。
    static func makeAuthorization(
        coordinator: AgentCommandApprovalCoordinator,
        sessionID: UUID,
        command: String,
        workingDirectory: String = AgentRemoteExecTestSupport.remoteWorkingDirectory,
        targetDisplayName: String = "b3-remote"
    ) async throws -> AgentCommandExecutionAuthorization {
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            sessionID: sessionID,
            target: .remote(displayName: targetDisplayName),
            command: command,
            workingDirectory: AgentWorkingDirectory(
                path: workingDirectory,
                source: .osc7,
                confidence: .authoritative
            )
        )
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        return try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentCommandClaimExpectations(
                generationID: request.generationID,
                sessionID: request.sessionID,
                providerSnapshotID: request.providerBinding.snapshotID
            )
        )
    }
}
