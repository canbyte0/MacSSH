import Foundation
import Observation

/// Phase 10 传输运行时：全局唯一活跃传输限制、任务登记、生命周期联动。
///
/// 所有权（任务书）：
/// - 由 `AppState` 持有（App 层稳定对象），绝不属于任何 SwiftUI View——
///   切换页面 / 切换会话 / 关闭 Transfers 面板都不取消传输；
/// - 与 `SessionManager` 双向协作（均弱引用，AppState 统一持有两者）：
///   关闭 / Reconnect 会话前经 `cancelAndAwaitTransfers` 先取消并等待
///   传输清理完成，再走 SFTP / Terminal / 连接拆除；
///   上传成功后可安全刷新 Files 面板（同 session + 同目录 + 同连接）。
///
/// 第一版限制：**全局只允许一个活跃传输**（任务书）；并发请求直接
/// 拒绝并提示"已有文件正在传输，请等待当前任务完成或取消。"
///
/// 取消（协作式）：执行任务从不被 `Task.cancel()`——只置
/// `TransferCancellation` 标志；收尾（句柄关闭 + 临时文件清理）因此
/// 总能通过连接层的任务取消校验。拆除屏障等待执行任务终值，
/// 保证"等待清理完成"是可证明的。
///
/// 不写 SwiftData，不保存任何 Secret；日志只记录生命周期事件，
/// 不记录路径与内容细节。
@MainActor
@Observable
final class TransferManager {
    /// 全部传输任务（创建顺序；UI 按需倒序展示）。
    private(set) var tasks: [TransferTask] = []

    weak var sessionManager: SessionManager?

    // MARK: - 查询

    /// 全局活跃传输（第一版至多一个）。
    var activeTask: TransferTask? {
        tasks.first { !$0.state.isTerminal }
    }

    var hasActiveTransfer: Bool {
        activeTask != nil
    }

    /// 指定 Session 是否有活跃传输（关闭会话确认 / 会话隔离使用）。
    func hasActiveTransfer(forSession sessionID: UUID) -> Bool {
        tasks.contains { $0.sessionID == sessionID && !$0.state.isTerminal }
    }

    // MARK: - 入口（UI 调用；返回任务或拒绝文案）

    /// 上传本地文件到当前浏览目录。
    ///
    /// 拒绝顺序（均不创建任务）：已有活跃传输 → 会话 / 连接不可用 →
    /// 本地不是普通文件。创建任务后异步执行；预检失败（如远端已存在）
    /// 任务进入 Failed 并携带用户可见文案。
    @discardableResult
    func requestUpload(
        session: ManagedTerminalSession,
        localURL: URL
    ) -> (task: TransferTask?, rejection: String?) {
        if hasActiveTransfer {
            return (nil, "已有文件正在传输，请等待当前任务完成或取消。")
        }
        guard session.kind == .remoteSSH, !session.isClosed,
              let connection = session.connection,
              let sftp = session.sftpService,
              session.connectionInfo?.phase == .connected
        else {
            return (nil, "当前会话不可用。")
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: localURL.path,
            isDirectory: &isDirectory
        )
        guard exists, !isDirectory.boolValue else {
            return (nil, "只能上传普通文件。")
        }

        let remoteDirectory = sftp.currentPath
        let remoteTarget = RemotePath.join(remoteDirectory, child: localURL.lastPathComponent)
        let task = TransferTask(
            direction: .upload,
            sessionID: session.id,
            sessionTitle: session.title,
            remotePath: remoteTarget,
            localName: localURL.lastPathComponent,
            localURL: localURL
        )
        tasks.append(task)
        AppLogger.app.info("File upload started")
        runUpload(task, connection: connection, sftp: sftp, remoteDirectory: remoteDirectory)
        return (task, nil)
    }

    /// 下载远端普通文件到本地目标位置（覆盖由系统替换面板语义决定：
    /// NSSavePanel 已让用户确认同名覆盖；目录 / 符号链接 / 特殊文件
    /// 在 UI 层禁用，这里防御性再校验）。
    @discardableResult
    func requestDownload(
        session: ManagedTerminalSession,
        entry: SFTPFileEntry,
        destinationURL: URL
    ) -> (task: TransferTask?, rejection: String?) {
        if hasActiveTransfer {
            return (nil, "已有文件正在传输，请等待当前任务完成或取消。")
        }
        guard entry.kind == .regularFile else {
            return (nil, "仅支持下载普通文件。")
        }
        guard session.kind == .remoteSSH, !session.isClosed,
              let connection = session.connection,
              let sftp = session.sftpService,
              session.connectionInfo?.phase == .connected
        else {
            return (nil, "当前会话不可用。")
        }

        let remotePath = RemotePath.join(sftp.currentPath, child: entry.name)
        let task = TransferTask(
            direction: .download,
            sessionID: session.id,
            sessionTitle: session.title,
            remotePath: remotePath,
            localName: destinationURL.lastPathComponent,
            localURL: destinationURL,
            totalBytes: entry.sizeBytes.map { Int64(clamping: $0) }
        )
        tasks.append(task)
        AppLogger.app.info("File download started")
        runDownload(task, connection: connection, remotePath: remotePath)
        return (task, nil)
    }

    // MARK: - 取消与清理

    /// 请求取消（幂等）：只置标志，收尾由执行任务完成。
    func cancel(_ taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else {
            return
        }
        guard !task.state.isTerminal else {
            return
        }
        task.markCancelling()
        task.requestCancel()
    }

    /// 拆除屏障（关闭会话 / Reconnect / 退出前调用）：
    /// 请求取消该 Session 的全部活跃传输，并等待执行任务完全结束
    /// （含句柄关闭与临时文件清理）。本方法返回即传输侧无在途操作。
    func cancelAndAwaitTransfers(forSession sessionID: UUID) async {
        let targets = tasks.filter { $0.sessionID == sessionID && !$0.state.isTerminal }
        for task in targets {
            cancel(task.id)
        }
        for task in targets {
            await task.executionTask?.value
        }
    }

    /// Transfers 页 Clear：移除全部终态任务。
    func clearFinished() {
        tasks.removeAll { $0.state.isTerminal }
    }

    // MARK: - 执行

    /// 上传执行任务：预检（本地可读 → 子系统 → 远端目标不存在）→
    /// 流式传输（`SFTPTransferService`）→ 终态 + 成功时安全刷新 Files。
    private func runUpload(
        _ task: TransferTask,
        connection: SSHConnection,
        sftp: SFTPService,
        remoteDirectory: String
    ) {
        let service = SFTPTransferService(connection: connection)
        let isCancelled: @Sendable () async -> Bool = { [cancellation = task.cancellation] in
            cancellation.value
        }
        let onProgress = makeProgressReporter(task)

        task.executionTask = Task { @MainActor [weak self] in
            defer { task.executionTask = nil }

            do {
                // 本地预检：可读的普通文件与总大小（进度分母）。
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: task.localURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else {
                    throw TransferError.generic("本地文件不可用。")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: task.localURL.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                task.setTotalBytes(size)

                try await connection.openSFTPSubsystemIfNeeded()

                // 默认不覆盖：目标已存在直接失败（发布侧另有协议级防线）。
                if try await Self.remoteFileExists(connection, path: task.remotePath) {
                    throw TransferError.remoteFileExists
                }

                task.markTransferring()
                _ = try await service.upload(
                    localURL: task.localURL,
                    remoteDirectory: remoteDirectory,
                    remoteTarget: task.remotePath,
                    isCancelled: isCancelled,
                    onProgress: onProgress
                )
                task.markCompleted()
                AppLogger.app.info("File upload completed")
                await self?.notifyUploadCompleted(task: task, connection: connection)
            } catch let error as TransferError {
                Self.finish(task, with: error)
            } catch {
                Self.finish(task, with: TransferError(sftpError: (error as? SFTPError) ?? .connectionLost))
            }
        }
    }

    /// 下载执行任务：预检（子系统 → 远端源存在且为普通文件）→
    /// 流式传输 → 终态。下载完成**不刷新** Files（任务书）。
    private func runDownload(
        _ task: TransferTask,
        connection: SSHConnection,
        remotePath: String
    ) {
        let service = SFTPTransferService(connection: connection)
        let isCancelled: @Sendable () async -> Bool = { [cancellation = task.cancellation] in
            cancellation.value
        }
        let onProgress = makeProgressReporter(task)

        task.executionTask = Task { @MainActor in
            defer { task.executionTask = nil }

            do {
                try await connection.openSFTPSubsystemIfNeeded()

                let stat = try await connection.sftpStatFile(remotePath)
                guard stat.isRegularFile else {
                    throw TransferError.generic("仅支持下载普通文件。")
                }
                if let sizeBytes = stat.sizeBytes {
                    task.setTotalBytes(sizeBytes)
                }

                task.markTransferring()
                _ = try await service.download(
                    remotePath: remotePath,
                    localDestination: task.localURL,
                    expectedBytes: stat.sizeBytes,
                    isCancelled: isCancelled,
                    onProgress: onProgress
                )
                task.markCompleted()
                AppLogger.app.info("File download completed")
            } catch let error as TransferError {
                Self.finish(task, with: error)
            } catch {
                Self.finish(task, with: TransferError(sftpError: (error as? SFTPError) ?? .connectionLost))
            }
        }
    }

    /// 进度回调：单调提交；节流约 150ms 一次（5~7 次/秒），
    /// 最终字节精确提交（绝不丢最后的 100%）。
    private func makeProgressReporter(_ task: TransferTask) -> @Sendable (Int64) async -> Void {
        { [weak task] bytes in
            guard let task else {
                return
            }
            await MainActor.run {
                guard !task.state.isTerminal else {
                    return
                }
                let isFinal = task.totalBytes.map { bytes >= $0 } ?? false
                let due = Date().timeIntervalSince(task.lastProgressCommit) >= 0.15
                if isFinal || due {
                    task.reportProgress(bytes)
                }
            }
        }
    }

    /// 终态写入：区分取消 / 失败（取消是用户语义，不写失败文案）。
    private static func finish(_ task: TransferTask, with error: TransferError) {
        if error == .cancelled {
            task.markCancelled()
            AppLogger.app.info("File transfer cancelled")
        } else {
            task.markFailed(message: error.message)
            AppLogger.app.error("File transfer failed")
        }
    }

    /// 上传成功后的安全刷新（任务书）：仅当 Files 面板仍在同一
    /// Session + 同一连接 + 同一目录时才刷新——用户已导航 / 已重连
    /// 时绝不影响新状态（generation 安全）。
    private func notifyUploadCompleted(task: TransferTask, connection: SSHConnection) async {
        guard let session = sessionManager?.session(withID: task.sessionID),
              !session.isClosed,
              session.connection === connection,
              let sftp = session.sftpService,
              sftp.currentPath == RemotePath.parent(of: task.remotePath),
              sftp.phase == .loaded
        else {
            return
        }
        sftp.refresh()
    }

    /// 远端路径存在性检查：不存在 → false；权限不足等按错误上抛。
    private static func remoteFileExists(
        _ connection: SSHConnection,
        path: String
    ) async throws -> Bool {
        do {
            _ = try await connection.sftpStatFile(path)
            return true
        } catch let error as SFTPError where error == .noSuchPath {
            return false
        }
    }
}
