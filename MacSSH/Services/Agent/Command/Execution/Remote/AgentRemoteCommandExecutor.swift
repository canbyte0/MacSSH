import Darwin
import Foundation

// MARK: - 执行期上限（Remote 复用 B2 冻结值 + Remote 专属节拍）

/// Remote exec 的执行期上限。
///
/// stdout / stderr cap、timeout、grace、killConfirm 等**全部复用**
/// `AgentCommandExecutionLimits`（B2 冻结值，§46/§54：不新建第二套输出 / 时间
/// 配置）；本类型只新增 Remote transport 节拍与 payload 上界。
enum AgentRemoteCommandExecutionLimits: Sendable {
    /// drain 循环的单次活动等待切片：**取消响应上界**（绝不长时间等待数据）。
    static let activityWaitSlice: TimeInterval = 0.1
    /// 单轮每流最多搬运的分块数（drain 循环周期性让出 actor，PTY / SFTP 不被饿死）。
    static let maxDrainChunksPerTurn = 16
    /// approved cwd 的 UTF-8 字节上限（PATH_MAX 量级；越界 → 确定性错误）。
    static let maxWorkingDirectoryBytes = 8 * 1024
    /// exec payload 的 App 侧确定性上界（16 KiB command + cwd + wrapper 开销）。
    /// 越界 **绝不** silent truncate（libssh2 / SSH 协议本身没有这么低的 hard limit，
    /// 该上界是 App 侧防御，见 B3 报告）。
    static let maxExecPayloadBytes = AgentCommandLimits.maxCommandBytes + 8 * 1024 + 64
}

// MARK: - 策略（复用 B2 冻结的同一类型）

/// Remote 与 Local 共享**同一个**时间策略类型（B2 的
/// `AgentLocalCommandExecutionPolicy`）：60s default / 600s hard max / 5s grace
/// 都来自 `AgentCommandExecutionLimits`，Remote 绝不新建第二套时间配置。
///
/// 模型 / Provider 没有任何参数路径可以到达本类型。
typealias AgentRemoteCommandExecutionPolicy = AgentLocalCommandExecutionPolicy

// MARK: - 错误（infrastructure / approval；绝不含 command exit）

/// Remote executor 的错误分类（与「远端命令以 127 退出」严格区分）。
///
/// 刻意**不含** timeout / cancelled——两者是 frozen result 字段（timeout /
/// cancellation 产生 `AgentRemoteCommandResult` 而不是错误）。
enum AgentRemoteCommandExecutionError: Error, Equatable, Sendable {
    /// Local target 不属于 Remote executor（§10；绝不 fallback 到 Local executor）。
    case localExecutionUnsupported
    /// redeem / ledger gate 拒绝：伪造、重复消费、stale、跨 ledger（§9）。
    case authorizationRejected(AgentCommandError)
    /// origin session 不存在 / 已关闭（§14：绝不重连、绝不 fallback active session）。
    case sessionUnavailable
    /// 连接已不再认证 / 已释放（session 在 redeem 与 open 之间关闭等竞态，§53）。
    case connectionUnavailable
    /// exec channel 打开失败（§53）。
    case channelOpenFailed
    /// exec 请求被服务器拒绝（§53）。
    case execRequestRejected
    /// channel 读 / 写 / 协议 / 生命周期失败（§53）。
    case channelFailure
    /// exec payload 超过 App 侧确定性上界（§96：绝不 silent truncate）。
    case execPayloadTooLarge
}

// MARK: - 终止表示（provider-neutral；绝不伪造本地信号数字）

/// Remote 命令的终止方式。
///
/// §51/§52：远端 SSH exit-signal 是**文本协议名**（`TERM` / `KILL` / `SEGV`），
/// 绝不翻译成本地 `Int32` 信号号；也绝不因远端信号缺失而伪造信号。
enum AgentRemoteCommandTermination: Sendable, Equatable {
    /// 服务器给出 exit status（远端进程正常终止）。
    case exitStatus(Int32)
    /// 服务器给出 SSH exit-signal 文本名（如 `TERM`）；`errorMessage` 可选。
    case exitSignal(name: String, errorMessage: String?)
    /// 服务器既未给出 exit status 也未给出 exit signal（连接丢失 / 未收完协议消息）。
    case unknown

    /// 只有 exit status 才映射到共享结果模型的 `exitCode`（绝不伪造）。
    var exitCode: Int32? {
        if case .exitStatus(let code) = self {
            return code
        }
        return nil
    }
}

// MARK: - 结果（复用 B2 `AgentCommandResult` + Remote 终止信息）

/// Remote 命令的完整结果。
///
/// - `result` 与 Local 完全同构（stdout / stderr / caps / truncation /
///   timeout / cancelled / duration 语义一致）；
/// - `result.terminationSignal` 恒为 nil（该字段是本地 numeric signal 专用，
///   Remote 绝不写入）；
/// - 远端终止方式见 `termination`（exit status 或 SSH exit-signal 文本）；
/// - `remoteTerminationRequested` 表示取消 / timeout 时是否 best-effort
///   请求过 TERM / KILL（不暴露 libssh2 原始细节）。
struct AgentRemoteCommandResult: Sendable, Equatable {
    let result: AgentCommandResult
    let termination: AgentRemoteCommandTermination
    let remoteTerminationRequested: Bool
}

extension AgentRemoteCommandResult: CustomStringConvertible, CustomDebugStringConvertible {
    /// redacted：绝不输出 stdout / stderr 内容（零内容日志）。
    var description: String {
        "AgentRemoteCommandResult(termination: \(termination), "
            + "remoteTerminationRequested: \(remoteTerminationRequested), "
            + "result: \(result), content: <redacted>)"
    }

    var debugDescription: String { description }
}

// MARK: - 取消标志通道

/// Task 取消（`onCancel`，任意线程、同步）与执行循环之间的单向标志通道。
///
/// 与 B2 的进程组控制同款设计：`onCancel` 只置位不做异步工作；执行循环在
/// 每个活动等待切片（≤100ms）后读取标志，取消响应有界——绝不等待远端数据。
final class AgentRemoteCommandControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false

    func requestCancellation() {
        lock.lock()
        defer { lock.unlock() }
        cancellationRequested = true
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

// MARK: - Executor

/// Remote SSH Independent Exec Executor（Phase 10E-B3）。
///
/// 唯一执行入口：`execute(authorization:approvalCoordinator:)`。
///
/// 安全不变量：
/// - **绝不接受裸命令文本 / 裸 request / 裸 sessionID**：API 形状上不存在
///   以命令字符串、sessionID 或未经验证的 request 为参数的执行入口；
/// - redeem 由本类型内部完成（caller 不能自行 redeem 后传入）；
/// - `AgentCommandExecutionAuthorization` 本身不是信任根：forged / 跨 ledger /
///   重复消费在**任何 SSH side effect 之前**被 coordinator 账本拒绝；
/// - 顺序固定：authorization → target validation → 取消检查 → redeem →
///   final 取消检查 → session 解析（显式 sessionID）→ 取消门 →
///   open exec channel（§9 冻结链）；
/// - 只复用 origin session 的**已存在、已认证** `SSHConnection`：绝不新建
///   TCP / SSH 认证 / 凭据读取，绝不自动重连、绝不 fallback 到其它 session；
/// - 取消语义：channel 本地清理 **GUARANTEED**；远端 signal 请求 **BEST-EFFORT**；
///   远端进程 / 其后代是否死亡 **NOT GUARANTEED**（绝不宣称已杀死远端进程）。
///
/// B4 由 AgentViewModel 在审批 claim/redeem 后调用；Provider 只接收
/// bounded、structured result，绝不获得 SSH exec channel 或 session resolver。
struct AgentRemoteCommandExecutor: Sendable {
    /// App-owned 执行策略（timeout / grace；绝不来自模型）。
    let policy: AgentRemoteCommandExecutionPolicy
    /// 显式 sessionID → 已认证连接的解析器（绝不 activeSession fallback）。
    let resolver: AgentRemoteCommandSessionResolver

    init(
        policy: AgentRemoteCommandExecutionPolicy = .production,
        resolver: AgentRemoteCommandSessionResolver
    ) {
        self.policy = policy
        self.resolver = resolver
    }

    // MARK: - 唯一执行入口

    /// 执行一次已审批的 Remote command。
    ///
    /// - 抛 `AgentRemoteCommandExecutionError.localExecutionUnsupported`：
    ///   Local target（redeem 之前，不消费凭据）；
    /// - 抛 `AgentRemoteCommandExecutionError.authorizationRejected`：
    ///   伪造 / 重复 / stale / 跨 ledger（零 SSH side effect）；
    /// - 抛 `AgentRemoteCommandExecutionError.sessionUnavailable` /
    ///   `connectionUnavailable`：origin session 不可用（绝不重连 / fallback）；
    /// - 抛 `CancellationError`：channel 打开之前的取消（零 channel 残留）；
    /// - timeout / 执行期取消 → 返回带 `timedOut` / `cancelled` 的结果
    ///   （不是错误）。
    func execute(
        authorization: AgentCommandExecutionAuthorization,
        approvalCoordinator: AgentCommandApprovalCoordinator
    ) async throws -> AgentRemoteCommandResult {
        let control = AgentRemoteCommandControl()
        return try await withTaskCancellationHandler {
            try await executeAuthorized(
                authorization: authorization,
                approvalCoordinator: approvalCoordinator,
                control: control
            )
        } onCancel: {
            // 同步、任意线程：只置位；执行循环在每个切片内观察到。
            control.requestCancellation()
        }
    }

    // MARK: - 内部流程

    private func executeAuthorized(
        authorization: AgentCommandExecutionAuthorization,
        approvalCoordinator: AgentCommandApprovalCoordinator,
        control: AgentRemoteCommandControl
    ) async throws -> AgentRemoteCommandResult {
        // 1. target validation（redeem 前；Local 绝不消费任何凭据）
        if case .local = authorization.request.target {
            throw AgentRemoteCommandExecutionError.localExecutionUnsupported
        }

        // 2. 取消检查：redeem 之前 → 零 side effect、不消费授权
        try Task.checkCancellation()

        // 3. redeem：唯一 ledger gate（authorization 对象 ≠ 权限）
        let request: AgentCommandRequest
        do {
            request = try await approvalCoordinator.redeem(authorization)
        } catch let error as AgentCommandError {
            throw AgentRemoteCommandExecutionError.authorizationRejected(error)
        }

        // 4. 以 redeem 返回的 immutable request 复检 target（defense in depth）
        if case .local = request.target {
            throw AgentRemoteCommandExecutionError.localExecutionUnsupported
        }

        // 5. redeem 之后、任何 SSH side effect 之前的 final 取消检查
        try Task.checkCancellation()

        // 6. payload：approved cwd 前缀 wrapper + 原 command 原样（唯一
        //    App 生成的 shell 片段；模型 command 绝不 escaping / 重写）
        let payload: String
        switch AgentRemoteCommandBuilder.build(
            command: request.command,
            workingDirectory: request.workingDirectory
        ) {
        case .success(let value):
            payload = value
        case .failure(let error):
            throw error
        }

        // 7. session 解析：只按 approved immutable sessionID（绝不 activeSession）
        guard let connection = await resolver.connection(forSessionID: request.sessionID) else {
            throw AgentRemoteCommandExecutionError.sessionUnavailable
        }

        // 8. open 之前最后一道取消门（cancel → 0 channel open）
        try Task.checkCancellation()
        if control.isCancellationRequested {
            throw CancellationError()
        }

        // 9. 执行（redeem 后的 request 是全部执行参数的唯一来源）
        return try await runExecution(
            connection: connection,
            payload: payload,
            control: control
        )
    }

    // MARK: - 执行主体

    private func runExecution(
        connection: SSHConnection,
        payload: String,
        control: AgentRemoteCommandControl
    ) async throws -> AgentRemoteCommandResult {
        let startedNanoseconds = Self.monotonicNanoseconds()

        // 唯一 SSH side effect 起点：独立 exec session channel（无 PTY）
        let channel: UUID
        do {
            channel = try await connection.openExecChannel(
                command: payload,
                isCancelled: { control.isCancellationRequested }
            )
        } catch is CancellationError {
            // 打开期取消：SSH 层已释放半开 channel，调用方零残留。
            throw CancellationError()
        } catch let error as SSHExecChannelError {
            throw Self.mapExecError(error)
        }

        do {
            do {
                try await connection.sendExecChannelEOF(
                    channel,
                    isCancelled: { control.isCancellationRequested }
                )
            } catch is CancellationError {
                // 取消落在「exec 已发出、drain 未开始」之间：不中断——
                // drain 循环的首轮会观察到取消标志并走终止路径
                // （TERM → grace → KILL → cleanup）。
            }
            return try await driveExecChannel(
                connection: connection,
                channel: channel,
                control: control,
                startedNanoseconds: startedNanoseconds
            )
        } catch let error as SSHExecChannelError {
            await connection.closeExecChannel(channel)
            throw Self.mapExecError(error)
        } catch {
            await connection.closeExecChannel(channel)
            throw error
        }
    }

    /// drain / timeout / 取消 / 终止 / 收尾主循环。
    ///
    /// 双流公平 drain（绝不先把 stdout 读完再读 stderr），cap 之后继续 drain、
    /// 停止保存；每个活动等待切片（≤100ms）后重估 timeout / 取消。
    private func driveExecChannel(
        connection: SSHConnection,
        channel: UUID,
        control: AgentRemoteCommandControl,
        startedNanoseconds: UInt64
    ) async throws -> AgentRemoteCommandResult {
        var stdoutAccumulator = AgentLocalCommandOutputAccumulator(
            cap: AgentCommandExecutionLimits.stdoutMaxBytes
        )
        var stderrAccumulator = AgentLocalCommandOutputAccumulator(
            cap: AgentCommandExecutionLimits.stderrMaxBytes
        )
        var stdoutEOF = false
        var stderrEOF = false
        var timedOut = false
        var cancelled = false
        var terminating = false
        var remoteTerminationRequested = false
        var killRequested = false
        var graceDeadline: UInt64 = 0
        var killConfirmDeadline: UInt64 = 0

        let timeoutNanoseconds = Self.nanoseconds(policy.timeout)
        let graceNanoseconds = Self.nanoseconds(policy.terminationGracePeriod)
        let killConfirmNanoseconds = Self.nanoseconds(AgentCommandExecutionLimits.killConfirmWindow)

        while true {
            var receivedBytes = false
            if try await drainExecStream(
                connection: connection,
                channel: channel,
                stream: .stdout,
                eof: &stdoutEOF,
                accumulator: &stdoutAccumulator
            ) {
                receivedBytes = true
            }
            if try await drainExecStream(
                connection: connection,
                channel: channel,
                stream: .stderr,
                eof: &stderrEOF,
                accumulator: &stderrAccumulator
            ) {
                receivedBytes = true
            }

            // 正常完成：两流都已 EOF（exit status 在收尾阶段读取）。
            if stdoutEOF && stderrEOF {
                break
            }

            let now = Self.monotonicNanoseconds()

            if !terminating, control.isCancellationRequested || Task.isCancelled {
                cancelled = true
                terminating = true
                remoteTerminationRequested = true
                graceDeadline = now + graceNanoseconds
                try? await connection.requestExecChannelSignal(channel, signal: .terminate)
            } else if !terminating, now >= startedNanoseconds + timeoutNanoseconds {
                timedOut = true
                terminating = true
                remoteTerminationRequested = true
                graceDeadline = Self.monotonicNanoseconds() + graceNanoseconds
                try? await connection.requestExecChannelSignal(channel, signal: .terminate)
            }

            if terminating {
                let terminationNow = Self.monotonicNanoseconds()
                if !killRequested, terminationNow >= graceDeadline {
                    // 宽限到期：best-effort KILL（服务器可忽略 / 不支持）。
                    killRequested = true
                    killConfirmDeadline = terminationNow + killConfirmNanoseconds
                    try? await connection.requestExecChannelSignal(channel, signal: .kill)
                } else if killRequested, terminationNow >= killConfirmDeadline {
                    // 有界收口：signal 可能被忽略，绝不无限等待——
                    // 如实按 best-effort 远端终止语义报告。
                    break
                }
            }

            // 有界活动等待（取消响应上界 = 本切片；绝不等待远端数据）。
            let observedActivity = try await connection.waitForExecChannelActivity(
                channel,
                budget: AgentRemoteCommandExecutionLimits.activityWaitSlice
            )
            if receivedBytes {
                // 有数据即让出，保证 PTY / SFTP 不被大量输出饿死（§25）。
                await Task.yield()
            } else if observedActivity {
                // socket 报告可读但本轮读不出字节（libssh2 内部半包状态）：
                // 插入最小退避，杜绝「可读但无数据」形成紧循环（绝不 busy-spin）。
                await Self.minimalBackoff()
            }
        }

        // 收尾：close → exit status / exit signal（free 之前）→ free。
        // 与并发 teardown 的竞态按 unknown 终止如实报告（不 crash / 不 fallback）。
        let terminationSnapshot: SSHExecChannelTermination
        do {
            terminationSnapshot = try await connection.finishExecChannel(channel)
        } catch let error as SSHExecChannelError where error == .channelClosed {
            terminationSnapshot = .unknown
        }
        await connection.closeExecChannel(channel)

        let termination = Self.termination(from: terminationSnapshot)
        let stdoutSanitized = AgentLocalCommandOutputSanitizer.sanitize(
            stdoutAccumulator.stored,
            capacityTruncated: stdoutAccumulator.capacityTruncated
        )
        let stderrSanitized = AgentLocalCommandOutputSanitizer.sanitize(
            stderrAccumulator.stored,
            capacityTruncated: stderrAccumulator.capacityTruncated
        )
        let duration = Duration.nanoseconds(
            Int64(Self.monotonicNanoseconds() - startedNanoseconds)
        )

        return AgentRemoteCommandResult(
            result: AgentCommandResult(
                stdout: stdoutSanitized.text,
                stderr: stderrSanitized.text,
                exitCode: termination.exitCode,
                terminationSignal: nil,
                timedOut: timedOut,
                cancelled: cancelled,
                stdoutTruncated: stdoutSanitized.truncated,
                stderrTruncated: stderrSanitized.truncated,
                binaryOutputDetected: stdoutSanitized.binaryDetected
                    || stderrSanitized.binaryDetected,
                nonUTF8Detected: stdoutSanitized.nonUTF8Detected
                    || stderrSanitized.nonUTF8Detected,
                duration: duration
            ),
            termination: termination,
            remoteTerminationRequested: remoteTerminationRequested
        )
    }

    /// 单流非阻塞 drain：读至空（等价 EAGAIN）或 EOF；cap 之后继续读、不再存。
    ///
    /// 单轮最多搬运 `maxDrainChunksPerTurn` 块，保证 drain 循环周期性让出。
    private func drainExecStream(
        connection: SSHConnection,
        channel: UUID,
        stream: SSHExecStream,
        eof: inout Bool,
        accumulator: inout AgentLocalCommandOutputAccumulator
    ) async throws -> Bool {
        guard !eof else { return false }

        var received = false
        var chunks = 0
        while chunks < AgentRemoteCommandExecutionLimits.maxDrainChunksPerTurn {
            let read = try await connection.readExecChannelOutput(channel, stream: stream)
            if read.isEOF {
                eof = true
                return received
            }
            if read.bytes.isEmpty {
                return received
            }
            accumulator.append(read.bytes[...])
            received = true
            chunks += 1
        }
        return received
    }

    // MARK: - 映射与工具

    private static func termination(
        from snapshot: SSHExecChannelTermination
    ) -> AgentRemoteCommandTermination {
        if let exitStatus = snapshot.exitStatus {
            return .exitStatus(exitStatus)
        }
        if let name = snapshot.exitSignalName {
            return .exitSignal(name: name, errorMessage: snapshot.exitSignalErrorMessage)
        }
        return .unknown
    }

    /// SSH transport 错误 → Remote executor 的 infrastructure 错误分类。
    private static func mapExecError(_ error: SSHExecChannelError) -> AgentRemoteCommandExecutionError {
        switch error {
        case .connectionLost:
            .connectionUnavailable
        case .channelOpenFailed:
            .channelOpenFailed
        case .execRequestRejected:
            .execRequestRejected
        case .channelClosed, .channelReadFailed, .channelWriteFailed, .timedOut:
            .channelFailure
        case .signalRequestRejected:
            // executor 对 signal 请求统一 `try?`（best-effort，§60）；此分支
            // 不参与主流程，仅为穷尽性保留。
            .channelFailure
        }
    }

    /// 非取消敏感的最小退避（避免取消态下 sleep 立即返回导致空转）。
    private static func minimalBackoff() async {
        await Task.detached {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }.value
    }

    private static func monotonicNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        return UInt64(seconds) * 1_000_000_000
            + UInt64(attoseconds / 1_000_000_000)
    }
}
