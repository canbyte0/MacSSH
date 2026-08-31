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
    /// 预检与准备（本地 / 远端校验、临时文件打开）。
    case preparing
    /// 流式传输进行中。
    case transferring
    /// 取消已请求：等待当前分块收尾与临时文件清理。
    case cancelling
    /// 数据完成 + 句柄关闭 + 发布 / 替换成功（终态）。
    case completed
    /// 失败终态；用户可见原因在 `TransferTask.failureMessage`。
    case failed
    /// 取消终态（清理已完成）。
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .preparing, .transferring, .cancelling:
            return false
        }
    }
}

/// 单个文件传输的运行时记录（Phase 10）。
///
/// 职责边界（任务书）：
/// - 由 `TransferManager`（App 层稳定对象）持有，切换页面 / 切换会话 /
///   关闭 Transfers 面板都不影响传输；UI 只观察本对象；
/// - 纯内存对象，不进 SwiftData；绝不携带任何 Secret；
/// - 日志不记录路径细节，仅生命周期事件。
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

    private(set) var state: TransferState = .preparing

    /// 失败时的用户可见原因（不含 Secret 与原始 libssh2 码）。
    private(set) var failureMessage: String?

    let startedAt = Date()
    private(set) var finishedAt: Date?

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

    /// 设置总大小（预检后；仅一次，准备阶段）。
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

    /// 报告进度：单调（只增不减）；速度取整段平均，
    /// 分母非正时置 0，绝不出现 NaN / Infinity / 负值。
    func reportProgress(_ bytes: Int64) {
        transferredBytes = max(transferredBytes, bytes)
        lastProgressCommit = Date()
        let elapsed = Date().timeIntervalSince(startedAt)
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
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed > 0 {
            speedBytesPerSecond = Double(transferredBytes) / elapsed
        } else {
            speedBytesPerSecond = 0
        }
        state = .completed
        finishedAt = Date()
    }

    /// 失败（终态）。
    func markFailed(message: String) {
        failureMessage = message
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

    /// 状态文案（中文，任务书示例）。
    var stateDisplay: String {
        switch state {
        case .preparing:
            return "准备中"
        case .transferring:
            return "传输中"
        case .cancelling:
            return "正在取消"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
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
    /// 远端权限不足。
    case permissionDenied
    /// 远端文件不存在（下载源消失）。
    case remoteFileMissing
    /// 其他错误（含本地 I/O、校验、协议错误）。
    case generic(String)

    /// UI 展示的用户可读信息（中文，任务书示例文案）。
    var message: String {
        switch self {
        case .cancelled:
            return "传输已取消。"
        case let .connectionLost(remoteResidue):
            if let remoteResidue {
                return "SSH 连接已断开，传输失败。远端可能残留临时文件 \(remoteResidue)，可稍后手动清理。"
            }
            return "SSH 连接已断开，传输失败。"
        case .remoteFileExists:
            return "远程文件已存在。Phase 10 当前不会自动覆盖该文件。"
        case .permissionDenied:
            return "权限不足，无法完成传输。"
        case .remoteFileMissing:
            return "远程文件不存在。"
        case let .generic(text):
            return text
        }
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
            self = .generic("服务器报告传输错误。")
        }
    }
}
