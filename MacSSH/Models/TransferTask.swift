import Foundation
import Observation

/// 传输方向（Phase 10 只支持单文件上传 / 下载）。
enum TransferDirection: Sendable {
    case upload
    case download
}

/// 传输状态机（任务书：字节数到达绝不等于 Completed——Completed 只能在
/// 数据完成 + 句柄正确关闭 + 发布 / 替换成功之后出现）。
enum TransferState: Equatable, Sendable {
    /// 队列中等待调度（Phase 11）：尚未触碰任何连接 / 文件资源。
    case pending
    /// 预检与准备（本地 / 远端校验、临时文件打开）。
    case preparing
    /// 流式传输进行中。
    case transferring
    /// 取消已请求：等待当前分块收尾与临时文件清理。
    case cancelling
    /// 数据完成 + 句柄关闭 + 发布 / 替换成功（终态）。
    case completed
    /// 失败终态；用户可见原因在 `TransferTask.failureError`（语言无关枚举）。
    case failed
    /// 取消终态（清理已完成）。
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .pending, .preparing, .transferring, .cancelling:
            return false
        }
    }

    /// 是否占用活跃传输槽位（全局 / 每会话并发限额计数用）：
    /// pending 不占槽（尚未触碰连接），进入 preparing 起占用，
    /// 终态释放（槽位释放等价于状态机终态，无需独立计数器漂移）。
    var occupiesActiveSlot: Bool {
        switch self {
        case .preparing, .transferring, .cancelling:
            return true
        case .pending, .completed, .failed, .cancelled:
            return false
        }
    }
}

/// 单个文件传输的运行时记录（Phase 10 建立，Phase 11 队列化）。
///
/// 职责边界（任务书）：
/// - 由 `TransferManager`（App 层稳定对象）持有，切换页面 / 切换会话 /
///   关闭 Transfers 面板都不影响传输；UI 只观察本对象；
/// - 纯内存对象，不进 SwiftData；绝不携带任何 Secret；
/// - 日志不记录路径细节，仅生命周期事件。
///
/// Phase 11 路径快照：`remotePath` / `localURL` / `sessionID` 在入队时冻结，
/// 后续 Files 导航绝不改变已排队任务的目标路径。
@MainActor
@Observable
final class TransferTask: Identifiable {
    let id = UUID()

    let direction: TransferDirection

    /// 所属 Session 标识（会话隔离与关闭联动使用）。
    let sessionID: UUID

    /// Session 显示名（Transfers 列表展示）。
    let sessionTitle: String

    /// 上传：目标远端路径；下载：源远端路径。仅列表展示。
    let remotePath: String

    /// 本地文件名（展示用）。
    let localName: String

    /// 上传源 / 下载目标的本地文件地址。
    let localURL: URL

    /// 总字节；未知大小时为 nil（进度不伪造 100%）。
    private(set) var totalBytes: Int64?

    /// 已传输字节（单调，只增不减）。
    private(set) var transferredBytes: Int64 = 0

    /// 平均速度（B/s）；未知 / 无意义时为 0，绝不出现 NaN / Infinity / 负值。
    private(set) var speedBytesPerSecond: Double = 0

    private(set) var state: TransferState = .pending

    /// 失败原因（**语言无关**的枚举，不缓存任何具体语言文案）。
    ///
    /// MacSSH 1.1 Phase 1（任务书七十三）：原实现在此缓存"失败时刻按当时
    /// App Locale 生成好的 String"，导致任务到达 failed 终态后，用户再切换
    /// 语言（zh→en→zh）列表仍显示失败瞬间的旧语言文案，且该状态是终态、
    /// 不会重算，属于不可恢复的展示错误。
    ///
    /// 现改为只缓存语言无关的 `TransferError`，展示时经
    /// `failureMessage(locale:)` 按**当前** App Locale 即时解析；
    /// 语言切换只更新文案，绝不重建 / 重置传输任务。
    ///
    /// 不携带 Secret；libssh2 / FX 原始码只进安全日志。
    private(set) var failureError: TransferError?

    /// 入队时刻。
    let queuedAt = Date()

    /// 真正开始执行（调度启动）的时刻；pending 期间为 nil——
    /// 速度只从实际开始时刻起算，绝不把排队时间算进去。
    private(set) var startedAt: Date?

    private(set) var finishedAt: Date?

    /// pending 且所属会话已断开：展示"等待连接"与普通过队区分（调度器维护）。
    private(set) var awaitingConnection = false

    // MARK: - 内部运行时（Manager 维护，非观察语义）

    /// 取消标志：协作式取消的唯一信号源。执行任务**从不**被
    /// `Task.cancel()`——这保证收尾（句柄关闭 + 临时文件清理）
    /// 仍能通过连接层的任务取消校验。
    let cancellation = TransferCancellation()

    /// 执行任务；拆除屏障 `cancelAndAwaitTransfers` 等待其终值。
    var executionTask: Task<Void, Never>?

    /// 进度节流存储（非观察语义）：上次提交时刻。
    @ObservationIgnored
    var lastProgressCommit = Date.distantPast

    /// 入队时登记的所属会话弱引用（非观察语义）：生产路径调度器始终经
    /// SessionManager 解析**当前**会话；仅未装配 SessionManager 的测试直连
    /// 场景回退本引用，启动时仍从会话取当前连接（重连后是新 generation）。
    @ObservationIgnored
    weak var sessionRef: ManagedTerminalSession?

    init(
        direction: TransferDirection,
        sessionID: UUID,
        sessionTitle: String,
        remotePath: String,
        localName: String,
        localURL: URL,
        totalBytes: Int64? = nil
    ) {
        self.direction = direction
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.remotePath = remotePath
        self.localName = localName
        self.localURL = localURL
        self.totalBytes = totalBytes
    }

    // MARK: - Manager 专用写入

    /// 调度启动：pending → preparing 原子转换的一部分（仅 pending 可进入，
    /// 防重复调度的第二道闸——首次成功进入者才是启动者）。
    /// - Returns: 是否由本次调用完成转换。
    @discardableResult
    func markStarted() -> Bool {
        guard state == .pending else {
            return false
        }
        state = .preparing
        startedAt = Date()
        return true
    }

    /// pending 等待连接标记（调度器在会话断开时维护；重连后复位）。
    func setAwaitingConnection(_ awaiting: Bool) {
        awaitingConnection = awaiting
    }

    /// 设置总大小（预检后；启动时重新快照，绝不沿用入队时的旧值）。
    func setTotalBytes(_ bytes: Int64) {
        totalBytes = bytes
    }

    /// 进入流式传输阶段。
    func markTransferring() {
        state = .transferring
    }

    /// 进入取消收尾阶段（幂等；仅非终态可进入）。
    func markCancelling() {
        guard !state.isTerminal else {
            return
        }
        state = .cancelling
    }

    /// 报告进度：单调（只增不减）；速度取实际开始后的整段平均，
    /// 分母非正时置 0，绝不出现 NaN / Infinity / 负值。
    func reportProgress(_ bytes: Int64) {
        transferredBytes = max(transferredBytes, bytes)
        lastProgressCommit = Date()
        let elapsed = Date().timeIntervalSince(startedAt ?? queuedAt)
        if elapsed > 0 {
            speedBytesPerSecond = Double(transferredBytes) / elapsed
        } else {
            speedBytesPerSecond = 0
        }
    }

    /// 完成（终态）：进度精确落到总字节，速度重算一次。
    func markCompleted() {
        if let totalBytes {
            transferredBytes = totalBytes
        }
        let elapsed = Date().timeIntervalSince(startedAt ?? queuedAt)
        if elapsed > 0 {
            speedBytesPerSecond = Double(transferredBytes) / elapsed
        } else {
            speedBytesPerSecond = 0
        }
        state = .completed
        finishedAt = Date()
    }

    /// 失败（终态）：只记录语言无关的原因枚举。
    ///
    /// 绝不接收已本地化好的 String —— 那会把失败瞬间的 App 语言固化进
    /// 终态记录，之后切换语言无法挽回（任务书七十三）。
    func markFailed(error: TransferError) {
        failureError = error
        state = .failed
        finishedAt = Date()
    }

    /// 取消收尾完成（终态）。
    func markCancelled() {
        state = .cancelled
        finishedAt = Date()
    }

    /// 请求取消（幂等）：只置标志，收尾由执行任务完成。
    func requestCancel() {
        cancellation.request()
    }

    // MARK: - 展示

    /// 进度比例；未知大小时为 nil（indeterminate，绝不伪造 100%）。
    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    /// 状态文案：按当前 App Locale 生成；pending 区分普通过队与等待连接，
    /// 绝不显示 0% / 0 B/s。语言切换只更新文案，绝不重建传输任务或 Session。
    func stateDisplay(locale: Locale) -> String {
        switch state {
        case .pending:
            return awaitingConnection
                ? L10n.string("transfer.state.waiting_for_connection", defaultValue: "Waiting for connection", locale: locale)
                : L10n.string("transfer.state.waiting", defaultValue: "Waiting", locale: locale)
        case .preparing:
            return L10n.string("transfer.state.preparing", defaultValue: "Preparing", locale: locale)
        case .transferring:
            return L10n.string("transfer.state.transferring", defaultValue: "Transferring", locale: locale)
        case .cancelling:
            return L10n.string("transfer.state.cancelling", defaultValue: "Cancelling", locale: locale)
        case .completed:
            return L10n.string("transfer.state.completed", defaultValue: "Completed", locale: locale)
        case .failed:
            return L10n.string("transfer.state.failed", defaultValue: "Failed", locale: locale)
        case .cancelled:
            return L10n.string("transfer.state.cancelled", defaultValue: "Cancelled", locale: locale)
        }
    }

    /// 失败原因文案：按**当前** App Locale 即时解析（任务书七十三）。
    ///
    /// 这是失败文案的**唯一**展示入口——UI 绝不读取失败时刻缓存的字符串。
    /// 未失败（无 `failureError`）时返回 nil。
    ///
    /// 注：`TransferError.generic` 携带的是底层诊断文案（如本地 I/O
    /// 错误描述），本身不含可本地化的语义，因此该 case 在切换语言时
    /// 文案不变；其余全部 case（含协议错误）均随 Locale 切换。
    func failureMessage(locale: Locale) -> String? {
        failureError?.message(locale: locale)
    }

    /// "12.3 MB / 64.0 MB"；未知大小时只显示已传输量。
    var progressDisplay: String {
        let done = Self.formatBytes(transferredBytes)
        guard let totalBytes else {
            return done
        }
        return "\(done) / \(Self.formatBytes(totalBytes))"
    }

    /// 平均速度文案；传输中且大于 0 才展示。
    var speedDisplay: String? {
        guard state == .transferring, speedBytesPerSecond > 0 else {
            return nil
        }
        return "\(Self.formatBytes(Int64(speedBytesPerSecond)))/s"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 协作式取消标志（Sendable）：Manager 置位，执行任务在每个分块
/// 边界与收尾路径轮询；绝不使用 `Task.cancel()`（见 `executionTask` 说明）。
final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isRequested = false

    func request() {
        lock.lock()
        isRequested = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRequested
    }
}

/// 传输业务错误（执行层 → 用户可见文案的唯一映射点）。
///
/// 不携带 Secret；libssh2 / FX 原始码只进安全日志，
/// 不直接进入用户可见信息。
enum TransferError: Error, Equatable {
    /// 用户取消。
    case cancelled
    /// 底层 SSH 连接已不可用（断开 / 拆除 / 连接丢失）。
    /// 上传失败时可携带远端残留临时文件名——如实告知：连接丢失后
    /// 远端清理物理上不可能（不续传、不重连），绝不假装已清理。
    case connectionLost(remoteResidue: String? = nil)
    /// 远端已存在同名文件；Phase 10 默认不覆盖。
    case remoteFileExists
    /// 所属 Session 已不存在（调度器防御路径：会话已关闭 / 已移除）。
    case sessionMissing
    /// 远端权限不足。
    case permissionDenied
    /// 远端文件不存在（下载源消失）。
    case remoteFileMissing
    /// 本地文件无法读取（不存在 / 权限不足 / 文件系统错误）。
    case localReadFailed
    /// 本地临时文件无法写入（磁盘满 / 权限不足 / 路径无效）。
    case localWriteFailed
    /// 服务器写入异常（连接未断开但服务器拒绝接收数据）。
    case remoteWriteFailed
    /// 服务器报告 SFTP 协议错误（连接未断开、非权限 / 路径类失败）。
    /// 来源：`SFTPError.protocolFailure`（SFTPSession / SFTPFileOperations
    /// 均可能真实抛出），必须走独立语言无关 case，禁止固化英文文案。
    case remoteProtocolError
    /// 传输校验失败（远端字节数与已传输字节不一致）。
    case verificationFailed
    /// 发布 / 替换本地目标文件失败（替换操作被系统拒绝）。
    case publishFailed
    /// 其他错误（本地 I/O 等底层**诊断**文案；协议错误已有独立 case，
    /// 禁止把用户可见的英文句子放进本 case 固化语言）。
    case generic(String)

    /// UI 展示的用户可读信息；按当前 App Locale 生成。
    /// 不携带 Secret；libssh2 / FX 原始码只进安全日志，不直接进入用户可见信息。
    func message(locale: Locale) -> String {
        switch self {
        case .cancelled:
            return L10n.string("error.transfer.cancelled", defaultValue: "The transfer was cancelled.", locale: locale)
        case let .connectionLost(remoteResidue):
            if let remoteResidue {
                return L10n.format(
                    "error.transfer.connection_lost_residue",
                    defaultValue: "The SSH connection was lost and the transfer failed. A temporary file may remain on the server: %@. You can clean it up manually later.",
                    locale: locale,
                    arguments: remoteResidue
                )
            }
            return L10n.string(
                "error.transfer.connection_lost",
                defaultValue: "The SSH connection was lost and the transfer failed.",
                locale: locale
            )
        case .sessionMissing:
            return L10n.string(
                "error.transfer.session_missing",
                defaultValue: "The session no longer exists.",
                locale: locale
            )
        case .remoteFileExists:
            return L10n.string(
                "error.transfer.remote_file_exists",
                defaultValue: "A file with the same name already exists on the server and will not be overwritten.",
                locale: locale
            )
        case .permissionDenied:
            return L10n.string(
                "error.transfer.permission_denied",
                defaultValue: "Permission denied; the transfer could not be completed.",
                locale: locale
            )
        case .remoteFileMissing:
            return L10n.string(
                "error.transfer.remote_file_missing",
                defaultValue: "The remote file no longer exists.",
                locale: locale
            )
        case .localReadFailed:
            return L10n.string(
                "error.transfer.local_read_failed",
                defaultValue: "The local file could not be read.",
                locale: locale
            )
        case .localWriteFailed:
            return L10n.string(
                "error.transfer.local_write_failed",
                defaultValue: "The local temporary file could not be written.",
                locale: locale
            )
        case .remoteWriteFailed:
            return L10n.string(
                "error.transfer.remote_write_failed",
                defaultValue: "The server reported an error while writing data.",
                locale: locale
            )
        case .remoteProtocolError:
            return L10n.string(
                "error.transfer.remote_protocol_error",
                defaultValue: "The server reported a protocol error during the transfer.",
                locale: locale
            )
        case .verificationFailed:
            return L10n.string(
                "error.transfer.verification_failed",
                defaultValue: "Transfer verification failed; the byte count does not match.",
                locale: locale
            )
        case .publishFailed:
            return L10n.string(
                "error.transfer.publish_failed",
                defaultValue: "Replacing the destination file failed.",
                locale: locale
            )
        case let .generic(text):
            return text
        }
    }

    /// LocalizedError 兜底：非 UI 路径使用英文 fallback，与既有测试兼容。
    var errorDescription: String? {
        message(locale: Locale(identifier: "en"))
    }

    /// SFTP 业务错误映射（连接层统一入口）。
    init(sftpError: SFTPError) {
        switch sftpError {
        case .connectionLost, .subsystemInitFailed:
            self = .connectionLost(remoteResidue: nil)
        case .noSuchPath:
            self = .remoteFileMissing
        case .permissionDenied:
            self = .permissionDenied
        case .operationCancelled:
            self = .cancelled
        case .protocolFailure:
            self = .remoteProtocolError
        }
    }
}
