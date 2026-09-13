import Darwin
import Foundation

// MARK: - 小工具

/// 单流输出存储：达到 cap 后**继续计数、停止保存**（§32/§33
/// drain-not-store；绝不因 cap 停止读取 pipe——那会让子进程永久阻塞）。
struct AgentLocalCommandOutputAccumulator: Sendable {
    let cap: Int
    private(set) var stored = Data()
    private(set) var totalBytes = 0

    /// 是否发生过 cap 截断（`stored` 少于 `totalBytes`）。
    var capacityTruncated: Bool { totalBytes > cap }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        totalBytes += bytes.count
        let remaining = cap - stored.count
        guard remaining > 0 else { return }
        if bytes.count <= remaining {
            stored.append(contentsOf: bytes)
        } else {
            stored.append(contentsOf: bytes.prefix(remaining))
        }
    }
}

// MARK: - 终止控制

/// spawn 后的生命周期控制：Task 取消（`onCancel`，任意线程、同步）与
/// 执行循环线程之间的双向通道。
///
/// 锁的作用域刻意覆盖 **killpg 与 waitpid 两侧**：杜绝「reap 后 pid
/// 被内核复用 → 取消路径误伤无关进程组」的竞态（进程组信号只在
/// `finished == false` 时发送，且发送期间不可能并发 reap）。
final class AgentLocalCommandProcessControl: @unchecked Sendable {
    struct ExitStatus: Sendable, Equatable {
        let exitCode: Int32?
        let terminationSignal: Int32?
    }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var terminationRequested = false
    private var finished = false
    private var exitStatus: ExitStatus?

    /// 登记子进程（spawn 成功后立即调用）。若终止请求早于 spawn
    /// （取消与 spawn 的合法竞态窗口，§10），登记时立刻 SIGTERM——
    /// 绝不出现「已取消的 caller + 无人管理的 child」。
    func attach(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        self.pid = pid
        if terminationRequested {
            signalLocked(SIGTERM)
        }
    }

    /// 请求终止：置位 + 立即对已登记进程组 SIGTERM。
    /// 允许重复调用（SIGTERM 幂等；已 reap 后不再发送）。
    func requestTermination() {
        lock.lock()
        defer { lock.unlock() }
        terminationRequested = true
        signalLocked(SIGTERM)
    }

    /// 宽限期到期后的强杀（SIGKILL 进程组）。
    func forceKill() {
        lock.lock()
        defer { lock.unlock() }
        signalLocked(SIGKILL)
    }

    func isTerminationRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }

    /// WNOHANG 探测 + reap（唯一 reap 入口，§40：绝不遗留 zombie）。
    /// 返回 nil 表示尚未退出；退出状态首次即缓存，后续调用返回同一值。
    func pollExit() -> ExitStatus? {
        lock.lock()
        defer { lock.unlock() }
        if let exitStatus {
            return exitStatus
        }
        guard pid > 0 else { return nil }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            let decoded = Self.decode(status: status)
            exitStatus = decoded
            finished = true
            return decoded
        }
        if result == -1, errno == ECHILD {
            // 已被第三方回收（不应发生）：如实标记完成，状态未知。
            let decoded = ExitStatus(exitCode: nil, terminationSignal: nil)
            exitStatus = decoded
            finished = true
            return decoded
        }
        return nil
    }

    /// 测试 / 诊断：是否已完成 reap。
    var hasFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    // MARK: - Private

    /// 锁内发送进程组信号（pid 复用防线：finished 后绝不发送）。
    private func signalLocked(_ signal: Int32) {
        guard pid > 0, !finished else { return }
        // ESRCH（组已空）容忍；不重试、不升级。
        _ = killpg(pid, signal)
    }

    /// waitpid status 解码。`WIFEXITED` / `WEXITSTATUS` / `WIFSIGNALED` /
    /// `WTERMSIG` 是 C 宏（Swift 不可见），按 Darwin `sys/wait.h` 的位编码
    /// 展开（唯一实现，测试覆盖 exit / signal / timeout 三种形态）。
    private static func decode(status: Int32) -> ExitStatus {
        let signal = status & 0x7F
        if signal == 0 {
            return ExitStatus(exitCode: (status >> 8) & 0xFF, terminationSignal: nil)
        }
        if signal == 0x7F {
            // stopped 状态（未使用 WUNTRACED，不应出现）：如实返回未知。
            return ExitStatus(exitCode: nil, terminationSignal: nil)
        }
        return ExitStatus(exitCode: nil, terminationSignal: signal)
    }
}

// MARK: - Local 进程执行核心

/// `posix_spawn` 执行核心（10E-A §8/§27/§28/§29/§94 冻结）。
///
/// 同步、单线程：poll 事件循环同时服务 stdout / stderr 两根 pipe
/// （任一 pipe 有数据即读、另一 pipe 绝不阻塞本流 → §31/§64 无死锁），
/// 同时承担 waitpid(WNOHANG) 轮询、timeout、SIGTERM→grace→SIGKILL
/// 升级与退出口 drain 收尾。
///
/// spawn 家族**固定为 `posix_spawn`**（§12/§101）：绝不使用任何
/// Foundation 进程包装、C 标准库包装或 fork 家族替代品。
enum AgentLocalCommandProcess {
    struct ExecutionOutcome: Sendable {
        let exitCode: Int32?
        let terminationSignal: Int32?
        let timedOut: Bool
        let cancelled: Bool
        let stdout: AgentLocalCommandOutputSanitizer.SanitizedOutput
        let stderr: AgentLocalCommandOutputSanitizer.SanitizedOutput
        let duration: Duration
    }

    // MARK: - 主入口

    static func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        policy: AgentLocalCommandExecutionPolicy,
        control: AgentLocalCommandProcessControl
    ) throws -> ExecutionOutcome {
        // MARK: 双 pipe（stdout / stderr 分离，绝不底层合并 §30）
        var stdoutPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else {
            throw AgentCommandExecutionError.spawnFailed(errno)
        }
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stderrPipe) == 0 else {
            closeDescriptors(&stdoutPipe)
            throw AgentCommandExecutionError.spawnFailed(errno)
        }
        defer {
            closeDescriptors(&stdoutPipe)
            closeDescriptors(&stderrPipe)
        }
        configureParentReadDescriptor(stdoutPipe[0])
        configureParentReadDescriptor(stderrPipe[0])

        // MARK: file actions
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw AgentCommandExecutionError.spawnFailed(errno)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // stdin → /dev/null（§27：closed/EOF，绝不连接 Terminal stdin）
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        // 显式关闭父进程侧 fd（配合 CLOEXEC_DEFAULT 的确定性）
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])
        // cwd 只来自 approved immutable request（§16/§17：绝不重读 session cwd）
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)

        // MARK: attributes（独立进程组 + CLOEXEC_DEFAULT）
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw AgentCommandExecutionError.spawnFailed(errno)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            )
        ) == 0 else {
            throw AgentCommandExecutionError.spawnFailed(errno)
        }
        // pgroup = 0 → 子进程进入以自身 pid 为 pgid 的新进程组（§14）
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw AgentCommandExecutionError.spawnFailed(errno)
        }
        // 信号状态重置（对冻结的「SIGTERM → grace → SIGKILL」链的支撑性
        // 补充）：实测 GUI App 进程继承的 signal disposition / mask 会进入
        // 子进程（后台 job 收不到组 SIGTERM，TERM 链退化为纯 SIGKILL 等待）。
        // 子进程以「全部默认 disposition + 空屏蔽字」起步，等同 Terminal
        // 启动语义——App 自身进程状态绝不泄漏进 command 环境。
        var defaultSignalSet = sigset_t()
        sigfillset(&defaultSignalSet)
        guard posix_spawnattr_setsigdefault(&attributes, &defaultSignalSet) == 0 else {
            throw AgentCommandExecutionError.spawnFailed(errno)
        }
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        guard posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0 else {
            throw AgentCommandExecutionError.spawnFailed(errno)
        }

        // MARK: spawn
        let spawnNanoseconds = monotonicNanoseconds()
        let childPID: pid_t = try withCStringArray([executablePath] + arguments) { argv in
            try withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
                var pid: pid_t = 0
                let result = posix_spawn(&pid, executablePath, &fileActions, &attributes, argv, envp)
                guard result == 0 else {
                    throw AgentCommandExecutionError.spawnFailed(result)
                }
                return pid
            }
        }
        // 父进程侧立即关闭 write 端：EOF 判定的前提
        close(stdoutPipe[1])
        stdoutPipe[1] = -1
        close(stderrPipe[1])
        stderrPipe[1] = -1
        control.attach(pid: childPID)

        // MARK: 事件循环
        var stdoutAccumulator = AgentLocalCommandOutputAccumulator(
            cap: AgentCommandExecutionLimits.stdoutMaxBytes
        )
        var stderrAccumulator = AgentLocalCommandOutputAccumulator(
            cap: AgentCommandExecutionLimits.stderrMaxBytes
        )
        var stdoutEOF = false
        var stderrEOF = false
        var exitStatus: AgentLocalCommandProcessControl.ExitStatus?
        var timedOut = false
        var terminating = false
        var killSent = false
        var groupCleanupSatisfied = false
        var graceDeadline: UInt64 = 0
        var killConfirmDeadline: UInt64 = 0
        var drainDeadline: UInt64 = 0
        var readBuffer = [UInt8](
            repeating: 0, count: AgentCommandExecutionLimits.readChunkBytes
        )

        let timeoutDeadline = spawnNanoseconds + nanoseconds(policy.timeout)
        let graceNanos = nanoseconds(policy.terminationGracePeriod)
        let drainWindowNanos = nanoseconds(AgentCommandExecutionLimits.postExitDrainWindow)
        let killConfirmNanos = nanoseconds(AgentCommandExecutionLimits.killConfirmWindow)

        while true {
            drainAvailable(
                stdoutFD: stdoutPipe[0],
                stderrFD: stderrPipe[0],
                stdoutEOF: &stdoutEOF,
                stderrEOF: &stderrEOF,
                stdoutAccumulator: &stdoutAccumulator,
                stderrAccumulator: &stderrAccumulator,
                buffer: &readBuffer
            )

            if exitStatus == nil, let reaped = control.pollExit() {
                exitStatus = reaped
                drainDeadline = monotonicNanoseconds() + drainWindowNanos
            }

            let now = monotonicNanoseconds()

            // 1) 终止触发：timeout 只在 child 运行时评估（§41/§44）；
            //    Task 取消（§46/§47）无论 child 状态都必须清组。
            if exitStatus == nil, !terminating, now >= timeoutDeadline {
                timedOut = true
                terminating = true
                graceDeadline = now + graceNanos
                control.requestTermination()
            }
            if !terminating, control.isTerminationRequested() {
                terminating = true
                graceDeadline = now + graceNanos
            }

            // 2) 组清理（§47/§48）：TERM 已发 → 组仍非空则等宽限 → SIGKILL。
            //    判定依据是**进程组**而非直接 child——直接 child 先退出
            //    （例如退避的后台 job 仍在组内）绝不跳过升级。
            if terminating, !groupCleanupSatisfied {
                if Self.isProcessGroupEmpty(childPID) {
                    groupCleanupSatisfied = true
                } else if !killSent, now >= graceDeadline {
                    control.forceKill()
                    killSent = true
                    killConfirmDeadline = now + killConfirmNanos
                } else if killSent, now >= killConfirmDeadline {
                    // 有界确认：SIGKILL 后仍超窗未空（理论 D 状态，P3）→ 收口。
                    groupCleanupSatisfied = true
                }
            }

            // 3) 退出：终止路径必须等组清理完成（保证无残余普通 descendant）
            if exitStatus != nil, !terminating || groupCleanupSatisfied {
                if (stdoutEOF && stderrEOF) || now >= drainDeadline {
                    // 收口前最后一次非阻塞 drain（带走已到达数据）
                    drainAvailable(
                        stdoutFD: stdoutPipe[0],
                        stderrFD: stderrPipe[0],
                        stdoutEOF: &stdoutEOF,
                        stderrEOF: &stderrEOF,
                        stdoutAccumulator: &stdoutAccumulator,
                        stderrAccumulator: &stderrAccumulator,
                        buffer: &readBuffer
                    )
                    break
                }
            }

            waitForActivity(
                stdoutFD: stdoutPipe[0],
                stderrFD: stderrPipe[0],
                stdoutEOF: stdoutEOF,
                stderrEOF: stderrEOF
            )
        }

        let endNanoseconds = monotonicNanoseconds()
        return ExecutionOutcome(
            exitCode: exitStatus?.exitCode,
            terminationSignal: exitStatus?.terminationSignal,
            timedOut: timedOut,
            cancelled: !timedOut && control.isTerminationRequested(),
            stdout: AgentLocalCommandOutputSanitizer.sanitize(
                stdoutAccumulator.stored,
                capacityTruncated: stdoutAccumulator.capacityTruncated
            ),
            stderr: AgentLocalCommandOutputSanitizer.sanitize(
                stderrAccumulator.stored,
                capacityTruncated: stderrAccumulator.capacityTruncated
            ),
            duration: .nanoseconds(Int64(endNanoseconds - spawnNanoseconds))
        )
    }

    // MARK: - I/O

    private static func drainAvailable(
        stdoutFD: Int32,
        stderrFD: Int32,
        stdoutEOF: inout Bool,
        stderrEOF: inout Bool,
        stdoutAccumulator: inout AgentLocalCommandOutputAccumulator,
        stderrAccumulator: inout AgentLocalCommandOutputAccumulator,
        buffer: inout [UInt8]
    ) {
        drainStream(
            fd: stdoutFD, eof: &stdoutEOF,
            accumulator: &stdoutAccumulator, buffer: &buffer
        )
        drainStream(
            fd: stderrFD, eof: &stderrEOF,
            accumulator: &stderrAccumulator, buffer: &buffer
        )
    }

    /// 单流非阻塞 drain：读至 EAGAIN / EOF（cap 命中后继续读、不再存）。
    private static func drainStream(
        fd: Int32,
        eof: inout Bool,
        accumulator: inout AgentLocalCommandOutputAccumulator,
        buffer: inout [UInt8]
    ) {
        guard fd >= 0, !eof else { return }
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                accumulator.append(buffer[0..<count])
                if count < buffer.count {
                    return
                }
            } else if count == 0 {
                eof = true
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno == EINTR {
                continue
            } else {
                eof = true
                return
            }
        }
    }

    /// 等待数据到达或 tick 到期（poll 同时是 timeout / reap 检查的节拍）。
    private static func waitForActivity(
        stdoutFD: Int32,
        stderrFD: Int32,
        stdoutEOF: Bool,
        stderrEOF: Bool
    ) {
        let tick = AgentCommandExecutionLimits.waitPollIntervalMilliseconds
        guard !(stdoutEOF && stderrEOF) else {
            usleep(useconds_t(tick) * 1000)
            return
        }
        var descriptors = [
            pollfd(fd: stdoutEOF ? -1 : stdoutFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: stderrEOF ? -1 : stderrFD, events: Int16(POLLIN), revents: 0),
        ]
        _ = poll(&descriptors, 2, tick)
    }

    // MARK: - POSIX 辅助

    /// 进程组是否已无成员（信号 0 探测：ESRCH → 空；
    /// 其余失败（如 EPERM）保守判为非空，继续清理链）。
    private static func isProcessGroupEmpty(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 0 else { return true }
        if killpg(processGroupID, 0) == 0 {
            return false
        }
        return errno == ESRCH
    }

    private static func configureParentReadDescriptor(_ fd: Int32) {
        let statusFlags = fcntl(fd, F_GETFL, 0)
        if statusFlags >= 0 {
            _ = fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    private static func closeDescriptors(_ descriptors: inout [Int32]) {
        for index in descriptors.indices where descriptors[index] >= 0 {
            close(descriptors[index])
            descriptors[index] = -1
        }
    }

    /// strdup 的 C 字符串数组（含 NULL 终止），调用后统一释放。
    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) rethrows -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
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
