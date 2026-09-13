import Foundation

// MARK: - 执行期冻结上限（Phase 10E-A Limits 表）

/// Local executor 的执行期上限（10E-A 冻结值；集中定义，禁止散落）。
enum AgentCommandExecutionLimits: Sendable {
    /// stdout 存储上限 256 KiB：达到后**继续 drain、停止保存**（§32/§33）。
    static let stdoutMaxBytes = 256 * 1024
    /// stderr 存储上限 256 KiB（与 stdout 独立计数，互不挤占）。
    static let stderrMaxBytes = 256 * 1024
    /// production timeout：60s（模型不可指定，10E-A §29）。
    static let defaultTimeout: Duration = .seconds(60)
    /// hard max：600s（App 内部上限；超出 clamp）。
    static let maxTimeout: Duration = .seconds(600)
    /// 终止宽限期：SIGTERM → 5s → SIGKILL（10E-A §27/§94）。
    static let terminationGracePeriod: Duration = .seconds(5)
    /// 子进程退出后等待管道收尾的窗口（§31：残留后代持有 pipe 时
    /// 绝不以无限等待换取 EOF——超窗即做最后一次非阻塞 drain 后收口）。
    static let postExitDrainWindow: Duration = .milliseconds(150)
    /// SIGKILL 进程组后确认组清空的有界窗口（SIGKILL 不可被忽略/屏蔽；
    /// 超窗未空只可能是不可中断态，按 P3 记录）。
    static let killConfirmWindow: Duration = .seconds(1)
    /// waitpid / 触发检查的轮询 tick（同时是 poll 等待上限）。
    static let waitPollIntervalMilliseconds: Int32 = 10
    /// 单次 read 缓冲（管道容量量级，避免多次系统调用）。
    static let readChunkBytes = 64 * 1024
}

// MARK: - 执行策略（App-owned；绝不暴露给模型）

/// Local command 的执行策略。
///
/// 10E-A 冻结：`timeout` 与 `terminationGracePeriod` 全部 App 决定，
/// 模型 / Provider 没有任何参数路径可以到达本类型（§29/§126/Limits）。
/// 构造仅用于 App 内部与测试注入（§42/§45），timeout clamp 到
/// `[1ms, 600s]`。
struct AgentLocalCommandExecutionPolicy: Sendable, Equatable {
    let timeout: Duration
    let terminationGracePeriod: Duration

    /// production：60s timeout / 5s grace（固定值）。
    static let production = AgentLocalCommandExecutionPolicy(
        timeout: AgentCommandExecutionLimits.defaultTimeout,
        terminationGracePeriod: AgentCommandExecutionLimits.terminationGracePeriod
    )

    /// App-internal 构造（测试注入短 timeout / grace；绝不来自模型）。
    init(timeout: Duration, terminationGracePeriod: Duration) {
        self.timeout = min(
            max(timeout, .milliseconds(1)),
            AgentCommandExecutionLimits.maxTimeout
        )
        self.terminationGracePeriod = max(terminationGracePeriod, .milliseconds(1))
    }
}

// MARK: - 执行错误（infrastructure / approval；绝不含 command exit）

/// Local executor 的错误分类（§38/§106：与「命令以 127 退出」严格区分）。
///
/// 刻意**不含** timeout / cancelled——两者是 frozen result 字段
/// （10E-A §94：timeout / cancellation 产生 `AgentCommandResult` 而不是错误）。
enum AgentCommandExecutionError: Error, Equatable, Sendable {
    /// 本地 executor 只执行 `.local` target（§11/§55；Remote 属 10E-B3，
    /// B2 绝不实现 remote fallback）。
    case remoteExecutionUnsupported
    /// redeem / ledger gate 拒绝：伪造、重复消费、stale、跨 ledger（§7/§52）。
    case authorizationRejected(AgentCommandError)
    /// 账户 shell 不可用（绝对路径且可执行均不满足）。
    case shellUnavailable
    /// 冻结 working directory 不存在 / 非目录 / 不可进入（§18：
    /// 绝不 fallback HOME / App cwd / 当前 session cwd）。
    case workingDirectoryUnavailable
    /// posix_spawn 本身失败（携带 errno，仅内部诊断；
    /// Provider 层序列化为 `executorUnavailable`，绝不外泄 errno，§76/§38）。
    case spawnFailed(Int32)
}

// MARK: - 执行结果（10E-A Output Model 冻结形态）

/// 一次 command 的执行结果。
///
/// 字段与 10E-A §34 冻结模型逐一对应；stdout / stderr 分离、各自
/// truncated 标记；timeout / cancellation 是**结果状态**而非错误。
struct AgentCommandResult: Sendable, Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32?
    let terminationSignal: Int32?
    let timedOut: Bool
    let cancelled: Bool
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let binaryOutputDetected: Bool
    let nonUTF8Detected: Bool
    let duration: Duration
}

extension AgentCommandResult: CustomStringConvertible, CustomDebugStringConvertible {
    /// redacted：绝不输出 stdout / stderr 内容（§74 零内容日志）。
    var description: String {
        "AgentCommandResult(exitCode: \(exitCode.map(String.init) ?? "nil"), "
            + "terminationSignal: \(terminationSignal.map(String.init) ?? "nil"), "
            + "timedOut: \(timedOut), cancelled: \(cancelled), "
            + "stdoutTruncated: \(stdoutTruncated), stderrTruncated: \(stderrTruncated), "
            + "binaryOutputDetected: \(binaryOutputDetected), "
            + "nonUTF8Detected: \(nonUTF8Detected), "
            + "duration: \(duration), content: <redacted>)"
    }

    var debugDescription: String { description }
}
