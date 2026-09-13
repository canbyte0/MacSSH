import Darwin
import Foundation

/// Local Independent Command Executor（Phase 10E-B2）。
///
/// 唯一执行入口：`execute(authorization:approvalCoordinator:)`。
///
/// 安全不变量（§6–§9/§103）：
/// - **绝不接受裸命令文本 / 裸 request**：API 形状上不存在以命令字符串
///   或未经 ledger 验证的 request 为参数的入口；调用方无法提供
///   未经验证的 `AgentCommandRequest`；
/// - redeem 由本类型**内部**完成（caller 不能自行 redeem 后传入）；
/// - `AgentCommandExecutionAuthorization` 本身**不是信任根**（§7）：
///   forged / 跨 ledger / 重复消费的 authorization 在任何 spawn 之前被
///   coordinator 账本拒绝；
/// - 顺序固定：authorization → target validation → 取消检查 → redeem →
///   final 取消检查 → spawn（§9）。
///
/// B4 由 AgentViewModel 在审批 claim/redeem 后调用；Provider 只接收
/// bounded、structured result，绝不获得 executor 或 terminal 写入入口。
struct AgentLocalCommandExecutor: Sendable {
    /// App-owned 执行策略（timeout / grace；绝不来自模型，§107）。
    let policy: AgentLocalCommandExecutionPolicy

    init(policy: AgentLocalCommandExecutionPolicy = .production) {
        self.policy = policy
    }

    // MARK: - 唯一执行入口

    /// 执行一次已审批的 Local command。
    ///
    /// - 抛 `AgentCommandExecutionError.authorizationRejected`：
    ///   伪造 / 重复 / stale / 跨 ledger / 未批准（零 spawn，零 side effect）；
    /// - 抛 `AgentCommandExecutionError.remoteExecutionUnsupported`：
    ///   Remote target 一律不属于 Local executor（B2 无 remote fallback，§11）；
    /// - 抛 `CancellationError`：redeem 之前或 spawn 之前的取消
    ///   （零 spawn）；
    /// - timeout / 执行期取消 → 返回带 `timedOut` / `cancelled` 的
    ///   `AgentCommandResult`（10E-A §94 冻结：不是错误）。
    func execute(
        authorization: AgentCommandExecutionAuthorization,
        approvalCoordinator: AgentCommandApprovalCoordinator
    ) async throws -> AgentCommandResult {
        let control = AgentLocalCommandProcessControl()
        return try await withTaskCancellationHandler {
            try await executeAuthorized(
                authorization: authorization,
                approvalCoordinator: approvalCoordinator,
                control: control
            )
        } onCancel: {
            // 同步、任意线程：只置位并（若已 spawn）SIGTERM 进程组。
            control.requestTermination()
        }
    }

    // MARK: - 内部流程

    private func executeAuthorized(
        authorization: AgentCommandExecutionAuthorization,
        approvalCoordinator: AgentCommandApprovalCoordinator,
        control: AgentLocalCommandProcessControl
    ) async throws -> AgentCommandResult {
        // 1. target validation（redeem 前；remote 绝不消费任何凭据，§11/§55）
        if case .remote = authorization.request.target {
            throw AgentCommandExecutionError.remoteExecutionUnsupported
        }

        // 2. 取消检查：此时取消 → authorization 不被消费、零 spawn（§68）
        try Task.checkCancellation()

        // 3. redeem：唯一 ledger gate（§7/§8：authorization 对象 ≠ 权限）
        let request: AgentCommandRequest
        do {
            request = try await approvalCoordinator.redeem(authorization)
        } catch let error as AgentCommandError {
            throw AgentCommandExecutionError.authorizationRejected(error)
        }

        // 4. 以 redeem 返回的 immutable request 复检 target（defense in depth）
        if case .remote = request.target {
            throw AgentCommandExecutionError.remoteExecutionUnsupported
        }

        // 5. redeem 之后、spawn 之前的 final 取消检查（§9 冻结顺序）
        try Task.checkCancellation()

        // 6. shell：账户 shell（pw_shell）`-c`，非 login 非 interactive（§19/§20）
        let shellPath = LoginShellResolver.resolve()
        guard shellPath.hasPrefix("/"), access(shellPath, X_OK) == 0 else {
            throw AgentCommandExecutionError.shellUnavailable
        }

        // 7. cwd：canonical（kernel 语义）+ 可进入性；缺一即
        //    workingDirectoryUnavailable，绝不 fallback HOME / App cwd /
        //    当前 session cwd（§16–§18）
        guard
            let canonicalWorkingDirectory = AgentPathResolver.canonicalize(
                request.workingDirectory, kind: .local
            ),
            Self.isEnterableDirectory(canonicalWorkingDirectory)
        else {
            throw AgentCommandExecutionError.workingDirectoryUnavailable
        }

        // 8. 执行（专用线程；redeem 后的 request 是全部执行参数的唯一来源）
        let environment = AgentLocalCommandEnvironment.makeEnvironment()
        let arguments = ["-c", request.command]
        let policySnapshot = policy
        return try await Self.performOnExecutionThread {
            let outcome = try AgentLocalCommandProcess.run(
                executablePath: shellPath,
                arguments: arguments,
                environment: environment,
                workingDirectory: canonicalWorkingDirectory,
                policy: policySnapshot,
                control: control
            )
            return AgentCommandResult(
                stdout: outcome.stdout.text,
                stderr: outcome.stderr.text,
                exitCode: outcome.exitCode,
                terminationSignal: outcome.terminationSignal,
                timedOut: outcome.timedOut,
                cancelled: outcome.cancelled,
                stdoutTruncated: outcome.stdout.truncated,
                stderrTruncated: outcome.stderr.truncated,
                binaryOutputDetected: outcome.stdout.binaryDetected
                    || outcome.stderr.binaryDetected,
                nonUTF8Detected: outcome.stdout.nonUTF8Detected
                    || outcome.stderr.nonUTF8Detected,
                duration: outcome.duration
            )
        }
    }

    // MARK: - 执行线程桥

    /// 执行线程池：绝不占用 Swift cooperative pool（长命令不阻塞
    /// 其它 async 工作；命令本身的串行化由上层 loop 语义保证）。
    private static let executionQueue = DispatchQueue(
        label: "com.macssh.agent.local-command-execution",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func performOnExecutionThread<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            executionQueue.async {
                do {
                    let value = try body()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 文件系统探针（纯 POSIX；绝不 fallback）

    private static func isEnterableDirectory(_ path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }
        return access(path, X_OK) == 0
    }
}
