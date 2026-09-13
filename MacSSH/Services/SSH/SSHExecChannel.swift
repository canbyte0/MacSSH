import Darwin
import Foundation

// MARK: - 值类型（transport-neutral：SSH 层绝不引用 Agent / Provider / approval）

/// Remote Independent Exec 的输出流。
///
/// stdout 与 stderr **分离**读取（libssh2 stream id 0 / 1），绝不底层合并
/// ——合并会让 Agent 无法区分正常输出与诊断输出。
enum SSHExecStream: Sendable, Equatable {
    case stdout
    case stderr

    /// libssh2 stream id：0 = 标准输出；`SSH_EXTENDED_DATA_STDERR` = 扩展数据。
    var streamID: Int32 {
        switch self {
        case .stdout: 0
        case .stderr: Int32(SSH_EXTENDED_DATA_STDERR)
        }
    }
}

/// SSH 协议信号名（RFC 4254 §6.9 "signal name"）。
///
/// 请求里发送的是协议名（`TERM` / `KILL`），绝不是本地 `SIGTERM` 形式。
enum SSHExecSignalName: String, Sendable, Equatable {
    case terminate = "TERM"
    case kill = "KILL"
}

/// exec channel 的终止快照（**值拷贝**：channel free 之后仍然有效）。
///
/// 语义（绝不伪造）：
/// - `exitStatus` 非 nil = 服务器给出了 exit status（远端进程正常终止）；
/// - `exitSignalName` 非 nil = 服务器给出了 SSH exit-signal 文本名
///   （如 `TERM` / `KILL` / `SEGV`）——**绝不**翻译成本地数字信号；
/// - 两者皆 nil = 服务器未提供（连接丢失 / 未收完协议消息），如实标记 unknown。
struct SSHExecChannelTermination: Sendable, Equatable {
    let exitStatus: Int32?
    let exitSignalName: String?
    let exitSignalErrorMessage: String?

    static let unknown = SSHExecChannelTermination(
        exitStatus: nil,
        exitSignalName: nil,
        exitSignalErrorMessage: nil
    )
}

/// exec channel 生命周期错误（transport 层；不携带任何命令内容 / 凭据）。
enum SSHExecChannelError: Error, Equatable, Sendable {
    /// 底层 SSH 连接已释放 / 正在断开。
    case connectionLost
    /// session channel 打开失败（服务器拒绝 / 协议错误）。
    case channelOpenFailed
    /// exec 请求被服务器拒绝。
    case execRequestRejected
    /// 本地 token 已进入关闭流程（或不再登记）。
    case channelClosed
    /// Channel 读取失败（非 EOF 的传输错误）。
    case channelReadFailed
    /// Channel 写侧操作（EOF）失败。
    case channelWriteFailed
    /// 服务器拒绝 / 不支持 signal request（best-effort 语义，不视为连接故障）。
    case signalRequestRejected
    /// 步骤预算耗尽（readiness 等待）——绝不 busy-spin。
    case timedOut
}

// MARK: - libssh2 调用的最小可注入边界

/// `SSHExecChannel.swift` 使用的 libssh2 调用的最小可注入边界。
///
/// 与 Phase 5 的 `SSHConnection.SessionTeardownOperations` 同款设计的测试接缝：
/// 生产环境为 `.live`（真实 libssh2）；测试可注入 fake，在**没有真实 SSH
/// 服务器**的前提下确定性覆盖 open / exec / EOF / stdout / stderr / EAGAIN /
/// exit status / exit signal / close / free / 连接丢失全链，并记录真实调用次数
/// （channel 泄漏与 double-free 审计）。生产路径仍然是唯一的
/// `SSHConnection` + libssh2 路径——本结构不是第二套实现，只是调用边界。
struct SSHExecChannelOperations: Sendable {
    let openSessionChannel: @Sendable (OpaquePointer) -> OpaquePointer?
    let requestExec: @Sendable (OpaquePointer, UnsafePointer<CChar>, UInt32) -> Int32
    let sendEOF: @Sendable (OpaquePointer) -> Int32
    let readStream: @Sendable (OpaquePointer, Int32, UnsafeMutablePointer<CChar>, Int) -> Int
    let isEOF: @Sendable (OpaquePointer) -> Int
    let requestSignal: @Sendable (OpaquePointer, UnsafePointer<CChar>, Int) -> Int32
    let closeChannel: @Sendable (OpaquePointer) -> Int32
    let waitClosed: @Sendable (OpaquePointer) -> Int32
    let freeChannel: @Sendable (OpaquePointer) -> Int32
    let hasExitStatus: @Sendable (OpaquePointer) -> Int
    let exitStatus: @Sendable (OpaquePointer) -> Int32
    let exitSignal: @Sendable (OpaquePointer) -> (name: String?, errorMessage: String?)
    /// session 级 last_errno（EAGAIN 判定；fake 必须同样提供）。
    let lastSessionError: @Sendable (OpaquePointer) -> Int32

    static let live = SSHExecChannelOperations(
        openSessionChannel: { session in
            // 函数式宏 `libssh2_channel_open_session` 在 Swift 中不可用，
            // 必须调用底层 _ex 函数（与 Interactive Shell 相同参数）。
            libssh2_channel_open_ex(
                session,
                "session",
                7,
                2 * 1024 * 1024,
                32_768,
                nil,
                0
            )
        },
        requestExec: { channel, commandPointer, commandLength in
            // `libssh2_channel_exec` 是宏：真实入口是 process_startup("exec")。
            libssh2_channel_process_startup(channel, "exec", 4, commandPointer, commandLength)
        },
        sendEOF: { channel in
            libssh2_channel_send_eof(channel)
        },
        readStream: { channel, streamID, buffer, capacity in
            libssh2_channel_read_ex(channel, streamID, buffer, capacity)
        },
        isEOF: { channel in
            Int(libssh2_channel_eof(channel))
        },
        requestSignal: { channel, namePointer, nameLength in
            libssh2_channel_signal_ex(channel, namePointer, nameLength)
        },
        closeChannel: { channel in
            libssh2_channel_close(channel)
        },
        waitClosed: { channel in
            libssh2_channel_wait_closed(channel)
        },
        freeChannel: { channel in
            libssh2_channel_free(channel)
        },
        hasExitStatus: { channel in
            Int(libssh2_channel_has_exit_status(channel))
        },
        exitStatus: { channel in
            libssh2_channel_get_exit_status(channel)
        },
        exitSignal: { channel in
            var signalPointer: UnsafeMutablePointer<CChar>?
            var signalLength = 0
            var messagePointer: UnsafeMutablePointer<CChar>?
            var messageLength = 0
            var languagePointer: UnsafeMutablePointer<CChar>?
            var languageLength = 0
            let rc = libssh2_channel_get_exit_signal(
                channel,
                &signalPointer,
                &signalLength,
                &messagePointer,
                &messageLength,
                &languagePointer,
                &languageLength
            )
            guard rc == 0 else { return (nil, nil) }
            return (
                Self.copyString(signalPointer, signalLength),
                Self.copyString(messagePointer, messageLength)
            )
        },
        lastSessionError: { session in
            libssh2_session_last_errno(session)
        }
    )

    /// 复制 libssh2 返回值内的字符串（内存由 libssh2 持有，绝不调用
    /// libssh2_free），随即转成 Swift String。
    private static func copyString(
        _ pointer: UnsafeMutablePointer<CChar>?,
        _ length: Int
    ) -> String? {
        guard let pointer, length > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: length),
            as: UTF8.self
        )
    }
}

// MARK: - exec channel 登记记录

/// 单个 exec channel 的登记记录（所有权与释放的唯一 authority）。
///
/// 不变式：`closeTask != nil` 表示该 token 已进入关闭流程——`closeTask` 必为
/// 该 token 的唯一释放者；其他所有操作在同步段校验后立即拒绝。任务体结束时
/// 从 registry 摘除自己，保证「任务完成 ⇒ 登记消失」。
struct SSHExecChannelRecord {
    let channel: OpaquePointer
    var closeTask: Task<Void, Never>?
}

// MARK: - SSHConnection 扩展

/// Remote Independent Exec：在**同一个已认证 libssh2 session** 上打开一条
/// **独立** exec session channel（无 PTY、stdin EOF），与 Interactive Shell
/// Channel / SFTP subsystem 并存、互不干扰。
///
/// 并发边界（与 Phase 7 / Phase 9 完全一致）：
/// - 全部 libssh2 调用发生在 `SSHConnection` actor 隔离内；调用方只拿到
///   不透明 token（`UUID`），**绝不**把 `LIBSSH2_CHANNEL *` 带出 actor；
/// - EAGAIN 复用现有 `waitForLibssh2Readiness`（block_directions → poll，
///   ≤0.25s 切片），等待期间 actor 挂起，PTY / SFTP 可继续穿插，绝不 busy-spin；
/// - 读操作是单次非阻塞调用（返回空 = 暂时无数据），等待由调用方经
///   `waitForExecChannelActivity` 完成——长命令绝不会整段占住 actor；
/// - 每个 token **至多一次** `libssh2_channel_free`：`closeTask` 是唯一释放者，
///   teardown 与 executor 关闭路径并发时等待同一任务（无 double-free /
///   use-after-free / 泄漏）。
///
/// 本层是 transport/domain-neutral 的：不出现 approval / generation /
/// provider / Agent 概念（Agent 语义全部在 Agent 层）。
extension SSHConnection {
    /// exec channel 各步骤独立预算（与既有 10s 基线风格一致）。
    enum ExecChannelTimeouts {
        static let open: TimeInterval = 10
        static let execRequest: TimeInterval = 10
        static let sendEOF: TimeInterval = 5
        static let signal: TimeInterval = 3
        static let finish: TimeInterval = 3
        static let release: TimeInterval = 3
        /// 单次 readiness 等待切片上限（绝不长时间占住调用方）。
        static let readinessSlice: TimeInterval = 0.25
        /// 释放重试间隔（非取消敏感的固定让出）。
        static let releaseRetryMilliseconds: UInt64 = 50
    }

    /// 单次 read 搬运上限（与 Interactive Shell 相同的包大小量级）。
    private static let execReadBufferSize = 32_768

    // MARK: - 观察点（测试 / 拆除）

    /// 当前登记的 exec channel 数（只暴露计数，绝不带出指针）。
    var openExecChannelCount: Int {
        execChannels.count
    }

    /// 测试接缝（生产恒 nil）：exec channel 的 readiness 等待替换。
    ///
    /// fake session 没有真实 socket，无法走 poll 路径；注入后
    /// `waitForLibssh2Readiness` 不再被触碰（fake 操作同样不触碰 libssh2）。
    func setTestExecChannelReadinessWait(
        _ hook: (@Sendable (TimeInterval) async -> Void)?
    ) {
        testExecChannelReadinessWait = hook
    }

    /// 测试接缝（生产不使用）：登记 fake session 指针。
    ///
    /// fake session 没有真实握手 / socket；配套注入的
    /// `execChannelOperations` 提供全部 libssh2 调用。仅用于 exec channel
    /// 生命周期的确定性测试（无真实 SSH 服务器）。
    func setTestSessionPointer(_ pointer: OpaquePointer?) {
        session = pointer
    }

    /// 测试接缝（生产不使用）：登记 fake Interactive Shell Channel 句柄身份
    /// （nil = 清除）。用整数身份（而非指针）避免把非 Sendable 指针跨隔离域
    /// 传递；用于断言 exec 生命周期绝不触碰 PTY channel。
    ///
    /// ⚠️ 测试必须在 `disconnect()` 之前清除 fake 句柄——否则 teardown 会把
    /// fake 指针交给真实 libssh2。
    func setTestShellChannelIdentity(_ identity: UInt?) {
        shellChannel = identity.flatMap { OpaquePointer(bitPattern: $0) }
    }

    /// 测试接缝（生产不使用）：登记 fake SFTP 子系统句柄身份（nil = 清除）。
    func setTestSFTPSubsystemIdentity(_ identity: UInt?) {
        sftpSubsystem = identity.flatMap { OpaquePointer(bitPattern: $0) }
    }

    /// 测试接缝（生产不使用）：比较 Interactive Shell Channel 句柄身份
    /// （布尔结果可跨隔离域；指针本身不出 actor）。
    func isShellChannelIdentity(_ identity: UInt) -> Bool {
        shellChannel == OpaquePointer(bitPattern: identity)
    }

    /// 测试接缝（生产不使用）：比较 SFTP 子系统句柄身份。
    func isSFTPSubsystemIdentity(_ identity: UInt) -> Bool {
        sftpSubsystem == OpaquePointer(bitPattern: identity)
    }

    // MARK: - 打开（open session channel → exec request）

    /// 打开独立 exec session channel 并发出 exec 请求（**无 PTY**）。
    ///
    /// - `command` 是调用方构造完成的**最终 payload**（SSH 层绝不读取
    ///   Terminal cwd / 不重写命令）；
    /// - `isCancelled` 是调用方的取消谓词：置位后请求步骤在下一个 readiness
    ///   切片内以 `CancellationError` 退出（有界响应，绝不等 server 数据）；
    /// - 任何一步失败都立即释放半开 channel（绝不留下无人认领的句柄）；
    /// - 成功后返回不透明 token，调用方必须最终 `closeExecChannel`。
    func openExecChannel(
        command: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> UUID {
        let session = try execTransportGuard()

        let openDeadline = Date().addingTimeInterval(ExecChannelTimeouts.open)
        let channel = try await openExecSessionChannel(
            session: session,
            deadline: openDeadline,
            isCancelled: isCancelled
        )

        let token = UUID()
        execChannels[token] = SSHExecChannelRecord(channel: channel)
        execChannelOpenCount += 1

        do {
            try await requestExecOnChannel(
                session: session,
                channel: channel,
                command: command,
                deadline: Date().addingTimeInterval(ExecChannelTimeouts.execRequest),
                isCancelled: isCancelled
            )
        } catch {
            // 失败 / 取消清理：绝不留下半开 channel（调用方尚未持有 token）。
            await closeExecChannel(token)
            throw error
        }

        AppLogger.ssh.info("Remote exec channel opened")
        return token
    }

    // MARK: - stdin = EOF

    /// 告知远端「客户端不再发送任何 stdin 数据」。
    ///
    /// exec 请求成功后立即调用；绝不转发 Terminal 键盘输入、绝不等待输入。
    func sendExecChannelEOF(
        _ token: UUID,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        let session = try execTransportGuard()
        let deadline = Date().addingTimeInterval(ExecChannelTimeouts.sendEOF)

        while true {
            if isCancelled() {
                throw CancellationError()
            }
            guard session == self.session,
                  let record = execChannels[token], record.closeTask == nil
            else {
                throw SSHExecChannelError.channelClosed
            }

            let rc = execChannelOperations.sendEOF(record.channel)
            if rc == 0 {
                return
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await execWaitForReadiness(session: session, deadline: deadline)
                continue
            }
            AppLogger.ssh.error("Exec channel EOF failed with libssh2 code \(rc)")
            throw SSHExecChannelError.channelWriteFailed
        }
    }

    // MARK: - 读取（单次非阻塞；stdout / stderr 分离）

    /// 单次非阻塞读取指定流。
    ///
    /// 返回 `(bytes, isEOF)`：
    /// - `bytes` 非空：本次读到的原始字节；
    /// - `bytes` 为空且 `isEOF == false`：暂时无数据（等价 EAGAIN）——
    ///   调用方经 `waitForExecChannelActivity` 等待后重试，绝不在此内部轮询；
    /// - `isEOF == true`：远端已发送该流 EOF。
    func readExecChannelOutput(
        _ token: UUID,
        stream: SSHExecStream
    ) async throws -> (bytes: [UInt8], isEOF: Bool) {
        let session = try execTransportGuard()
        guard session == self.session,
              let record = execChannels[token], record.closeTask == nil
        else {
            throw SSHExecChannelError.channelClosed
        }

        var buffer = [UInt8](repeating: 0, count: Self.execReadBufferSize)
        let bytesRead = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return 0 }
            return base.withMemoryRebound(to: CChar.self, capacity: pointer.count) { charPointer in
                execChannelOperations.readStream(
                    record.channel,
                    stream.streamID,
                    charPointer,
                    pointer.count
                )
            }
        }

        if bytesRead > 0 {
            return (Array(buffer[0..<bytesRead]), false)
        }

        if bytesRead == 0 || bytesRead == LIBSSH2_ERROR_EAGAIN {
            // 0（无更多数据）/ EAGAIN（传输层暂不可读）：以 EOF 位区分
            // 「命令输出结束」与「稍后还有数据」。
            let reachedEOF = execChannelOperations.isEOF(record.channel) == 1
            return ([], reachedEOF)
        }

        if bytesRead == LIBSSH2_ERROR_CHANNEL_CLOSED {
            throw SSHExecChannelError.channelClosed
        }
        if Self.isConnectionLevelFailure(bytesRead) {
            AppLogger.ssh.error("Exec channel read hit connection failure \(bytesRead)")
            throw SSHExecChannelError.connectionLost
        }
        AppLogger.ssh.error("Exec channel read failed with libssh2 code \(bytesRead)")
        throw SSHExecChannelError.channelReadFailed
    }

    /// 有界等待「channel 上可能有新数据」（readiness）。
    ///
    /// 返回 `true` = socket 报告就绪；`false` = 切片到期（非错误）。
    /// 绝不 busy-spin：等待全部经由 `waitForLibssh2Readiness` 的 poll。
    /// 本方法**不**检查 Task 取消——它是 drain 循环的节拍器，切片本身
    /// 就是取消响应的上界。
    @discardableResult
    func waitForExecChannelActivity(_ token: UUID, budget: TimeInterval) async throws -> Bool {
        let session = try execTransportGuard()
        guard session == self.session,
              let record = execChannels[token], record.closeTask == nil
        else {
            throw SSHExecChannelError.channelClosed
        }

        let deadline = Date().addingTimeInterval(budget)
        do {
            try await execWaitForReadiness(session: session, deadline: deadline)
            return true
        } catch let error as SSHExecChannelError where error == .timedOut {
            return false
        }
    }

    // MARK: - 信号请求（best-effort）

    /// best-effort 请求远端终止（`TERM` / `KILL`）。
    ///
    /// 服务器可能不支持 / 忽略 / 拒绝：此情况下抛
    /// `SSHExecChannelError.signalRequestRejected`，调用方继续 channel 清理，
    /// **绝不**因此断开整个 SSH 连接。本方法不检查取消——终止请求必须
    /// 在取消后仍然尽力发出。
    func requestExecChannelSignal(
        _ token: UUID,
        signal: SSHExecSignalName
    ) async throws {
        let session = try execTransportGuard()
        let deadline = Date().addingTimeInterval(ExecChannelTimeouts.signal)

        while true {
            guard session == self.session,
                  let record = execChannels[token], record.closeTask == nil
            else {
                throw SSHExecChannelError.channelClosed
            }

            let rc: Int32 = signal.rawValue.withCString { pointer in
                execChannelOperations.requestSignal(
                    record.channel,
                    pointer,
                    signal.rawValue.utf8.count
                )
            }
            if rc == 0 {
                return
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await execWaitForReadiness(session: session, deadline: deadline)
                continue
            }
            AppLogger.ssh.error("Exec channel signal request failed with libssh2 code \(rc)")
            throw SSHExecChannelError.signalRequestRejected
        }
    }

    // MARK: - 收尾（close → 状态读取；必须在 free 之前）

    /// 关闭 channel 并读取 exit status / exit signal（**必须在 free 之前**）。
    ///
    /// 顺序（libssh2 语义）：`channel_close`（EAGAIN 重试）→
    /// `has_exit_status` / `get_exit_status` → `get_exit_signal` →
    /// `wait_closed`（有界，尽力而为）。返回值是纯值快照，free 之后仍有效。
    ///
    /// 返回后 channel 仍在登记中；释放由 `closeExecChannel` 完成。
    func finishExecChannel(_ token: UUID) async throws -> SSHExecChannelTermination {
        let session = try execTransportGuard()
        let deadline = Date().addingTimeInterval(ExecChannelTimeouts.finish)

        // 1) channel close（EAGAIN 重试；其他错误也继续尝试读取状态）。
        while true {
            guard session == self.session,
                  let record = execChannels[token], record.closeTask == nil
            else {
                throw SSHExecChannelError.channelClosed
            }
            let rc = execChannelOperations.closeChannel(record.channel)
            if rc == 0 {
                break
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await execWaitForReadiness(session: session, deadline: deadline)
                continue
            }
            AppLogger.ssh.error("Exec channel close failed with libssh2 code \(rc)")
            break
        }

        // 2) exit status / exit signal（在 free 之前读取）。
        guard session == self.session,
              let record = execChannels[token], record.closeTask == nil
        else {
            throw SSHExecChannelError.channelClosed
        }
        let channel = record.channel
        let exitStatus: Int32? = execChannelOperations.hasExitStatus(channel) != 0
            ? execChannelOperations.exitStatus(channel)
            : nil
        let signalResult = execChannelOperations.exitSignal(channel)

        // 3) 等待远端确认关闭（有界；失败只记录，不影响返回值）。
        let waitDeadline = Date().addingTimeInterval(min(1, ExecChannelTimeouts.finish))
        while true {
            guard session == self.session,
                  let current = execChannels[token], current.closeTask == nil
            else {
                break
            }
            let rc = execChannelOperations.waitClosed(current.channel)
            if rc == 0 {
                break
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                do {
                    try await execWaitForReadiness(session: session, deadline: waitDeadline)
                } catch {
                    break
                }
                continue
            }
            break
        }

        return SSHExecChannelTermination(
            exitStatus: exitStatus,
            exitSignalName: signalResult.name,
            exitSignalErrorMessage: signalResult.errorMessage
        )
    }

    // MARK: - 释放（exactly-once）

    /// 释放 channel（幂等）：同一 token 的并发 / 重复调用等待同一任务。
    ///
    /// 只处理**本次 exec channel**：绝不触碰 Interactive Shell Channel /
    /// SFTP subsystem / Session / socket。
    func closeExecChannel(_ token: UUID) async {
        guard let record = execChannels[token] else {
            return // 幂等：已释放或从未登记。
        }
        if let running = record.closeTask {
            await running.value
            return
        }

        let channel = record.channel
        let task = Task { await self.performTrackedExecChannelClose(token: token, channel: channel) }
        execChannels[token]?.closeTask = task
        await task.value
    }

    /// 断开专用：释放**全部** exec channel（teardown 语义）。
    ///
    /// 收敛保证：`disconnect()` 已置位断开标志，`openExecChannel` 入口拒绝任何
    /// 新打开；循环内只会有在途关闭任务的相继完成与残余 token 的关闭。
    func closeAllExecChannelsForTeardown() async {
        while !execChannels.isEmpty {
            guard let token = execChannels.keys.first else { break }
            if let running = execChannels[token]?.closeTask {
                await running.value
                continue
            }
            await closeExecChannel(token)
        }
    }

    // MARK: - Private：打开步骤

    /// Session Channel 打开（EAGAIN → readiness；绝不 busy-spin）。
    private func openExecSessionChannel(
        session: OpaquePointer,
        deadline: Date,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> OpaquePointer {
        while true {
            if isCancelled() {
                throw CancellationError()
            }
            guard session == self.session else {
                throw SSHExecChannelError.connectionLost
            }

            if let channel = execChannelOperations.openSessionChannel(session) {
                return channel
            }

            guard execChannelOperations.lastSessionError(session) == LIBSSH2_ERROR_EAGAIN else {
                AppLogger.ssh.error("Exec channel open was rejected by the server")
                throw SSHExecChannelError.channelOpenFailed
            }
            try await execWaitForReadiness(session: session, deadline: deadline)
        }
    }

    /// exec 请求（`process_startup` 的 exec 变体）。
    private func requestExecOnChannel(
        session: OpaquePointer,
        channel: OpaquePointer,
        command: String,
        deadline: Date,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        while true {
            if isCancelled() {
                throw CancellationError()
            }
            guard session == self.session,
                  execChannels.values.contains(where: { $0.channel == channel })
            else {
                throw SSHExecChannelError.channelClosed
            }

            let rc: Int32 = command.withCString { pointer in
                execChannelOperations.requestExec(channel, pointer, UInt32(command.utf8.count))
            }
            if rc == 0 {
                return
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await execWaitForReadiness(session: session, deadline: deadline)
                continue
            }
            AppLogger.ssh.error("Exec request failed with libssh2 code \(rc)")
            throw SSHExecChannelError.execRequestRejected
        }
    }

    // MARK: - Private：释放步骤

    /// 关闭任务体：实际释放步骤 + 结束时摘除登记（任务完成 ⇒ 登记消失）。
    private func performTrackedExecChannelClose(token: UUID, channel: OpaquePointer) async {
        defer {
            if execChannels[token]?.channel == channel {
                execChannels[token] = nil
            }
        }
        await performExecChannelRelease(channel)
    }

    /// 优雅释放：send EOF（尽力）→ close（尽力）→ wait closed（尽力）→
    /// free（EAGAIN 重试，有界）。
    ///
    /// 每一步失败都继续清理；绝不留下悬空句柄。释放预算用尽时记录诊断，
    /// **不**声称远端进程已终止（channel close ≠ 远端进程死亡证明）。
    private func performExecChannelRelease(_ channel: OpaquePointer) async {
        let deadline = Date().addingTimeInterval(ExecChannelTimeouts.release)

        _ = try? await runExecChannelOperation(channel: channel, deadline: deadline) {
            execChannelOperations.sendEOF(channel)
        }
        _ = try? await runExecChannelOperation(channel: channel, deadline: deadline) {
            execChannelOperations.closeChannel(channel)
        }
        _ = try? await runExecChannelOperation(channel: channel, deadline: deadline) {
            execChannelOperations.waitClosed(channel)
        }

        while true {
            let rc = execChannelOperations.freeChannel(channel)
            if rc == 0 {
                execChannelFreeCount += 1
                break
            }
            if rc != LIBSSH2_ERROR_EAGAIN {
                AppLogger.ssh.error("Exec channel free failed with libssh2 code \(rc)")
                break
            }
            guard Date() < deadline else {
                AppLogger.ssh.error("Exec channel free timed out; session teardown will reclaim it")
                break
            }
            // 固定让出（非取消敏感）：绝不因 Task 取消把重试退化成 CPU 空转。
            await Self.execPause(milliseconds: ExecChannelTimeouts.releaseRetryMilliseconds)
        }

        AppLogger.ssh.info("Remote exec channel closed")
    }

    /// 对返回 Int32 的 channel 操作执行 EAGAIN 重试（有界）。
    private func runExecChannelOperation(
        channel: OpaquePointer,
        deadline: Date,
        _ operation: () -> Int32
    ) async throws -> Int32 {
        while true {
            let rc = operation()
            if rc != LIBSSH2_ERROR_EAGAIN {
                return rc
            }
            guard Date() < deadline else {
                throw SSHExecChannelError.timedOut
            }
            await Self.execPause(milliseconds: ExecChannelTimeouts.releaseRetryMilliseconds)
        }
    }

    // MARK: - Private：readiness 与守卫

    /// exec 操作的 readiness 等待：切片有界；切片到期抛 `.timedOut`（非错误，
    /// 由调用方决定重试或收口）。
    private func execWaitForReadiness(session: OpaquePointer, deadline: Date) async throws {
        if let hook = testExecChannelReadinessWait {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw SSHExecChannelError.timedOut
            }
            await hook(min(remaining, ExecChannelTimeouts.readinessSlice))
            return
        }

        do {
            try await waitForLibssh2Readiness(session: session, deadline: deadline)
        } catch is CancellationError {
            // 取消态下 libssh2 零方向退避的 Task.sleep 会立即返回：折算为
            // 一次非取消敏感的固定让出，避免 CPU 空转（总预算由 deadline 兜底）。
            await Self.execPause(milliseconds: 20)
        } catch let error as SSHError where error == .connectionTimeout {
            throw SSHExecChannelError.timedOut
        }
    }

    /// exec 操作的连接守卫：断开中 / 无 session 一律 `connectionLost`。
    private func execTransportGuard() throws -> OpaquePointer {
        do {
            try throwIfDisconnectRequested()
        } catch {
            throw SSHExecChannelError.connectionLost
        }
        guard let session else {
            throw SSHExecChannelError.connectionLost
        }
        return session
    }

    /// 非取消敏感的固定让出（避免取消态下 sleep 立即返回导致的空转）。
    private static func execPause(milliseconds: UInt64) async {
        await Task.detached {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        }.value
    }

    /// 非 EAGAIN 的传输级失败（连接已不可用）与协议级失败区分。
    private static func isConnectionLevelFailure(_ code: Int) -> Bool {
        code == LIBSSH2_ERROR_SOCKET_RECV
            || code == LIBSSH2_ERROR_SOCKET_SEND
            || code == LIBSSH2_ERROR_SOCKET_DISCONNECT
    }
}
