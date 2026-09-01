import Foundation

/// Phase 10 流式传输执行引擎（actor）：本地文件 I/O 与远端分块
/// 交替推进，全部发生在协作池执行器上，不阻塞 MainActor。
///
/// 流式强制（任务书：禁止整文件进内存）：
/// - 内存占用上界 = 单个分块缓冲（1 MiB），与文件总大小无关；
/// - 上传：本地读一块 → 远端写一块（partial write 循环 `offset += written`）；
/// - 下载：远端读一块 → 本地写一块；`libssh2_sftp_read` 返回 `> 0` 数据 /
///   `0` EOF / `< 0` 错误，三种语义绝不混淆。
///
/// 协作调度（任务书：大文件传输时 Terminal 必须能共存）：
/// - 远端每个分块独立持 / 放 FIFO 串行门（在 `SFTPFileOperations`），
///   分块之间让出执行器（`Task.yield`）；
/// - 本地磁盘 I/O 与远端 I/O 交替，连接永不被传输独占。
///
/// 取消（协作式，任务书：Cancel 幂等且必须响应 EAGAIN 等待）：
/// - 执行任务从不被 `Task.cancel()`；`cancellation.value` 在分块边界
///   与收尾路径轮询，置位后走清理（关闭句柄 + 删除临时文件）；
/// - 收尾调用不检查取消标志，取消 / 一般失败路径的句柄与临时文件都会被清理。
///
/// 如实告知的已知限制（连接丢失）：远端清理依赖同一条连接——
/// 连接丢失后远端 `.macssh-upload-*.partial` 物理上无法删除（不续传、
/// 不重连，任务书）；此时失败文案会如实携带残留临时文件名，
/// 绝不假装已清理。本地临时文件不受此限制（本地文件系统始终可清理）。
///
/// 安全发布 / 替换：
/// - 上传：远端临时文件 `.macssh-upload-<UUID>.partial`（目标同目录）
///   → 字节校验 → 关闭句柄 → `rename` 发布（目标已存在则失败并清理）；
/// - 下载：本地临时文件 `.MacSSH-<UUID>.partial`（目标同目录）
///   → 字节校验 → 关闭句柄 → `FileManager.replaceItemAt` 原子替换。
///
/// Completed 语义（任务书：字节数到达绝不等于完成）：
/// 只有 数据完成 + 句柄正确关闭 + 校验通过 + 发布 / 替换成功
/// 全部满足后本方法才正常返回。
actor SFTPTransferService {
    /// 传输分块大小：1 MiB。
    ///
    /// 理由：本地回环实测 100 MB 传输在 1 MiB 分块下吞吐接近上限
    /// （分块数 100，串行门交接开销可忽略），同时单分块预算 60s 与
    /// 协作让出频率都保持温和——更小分块增加门交接次数，更大分块
    /// 拉高取消响应延迟与内存占用上界。
    static let chunkSize = 1_048_576

    private let connection: SSHConnection

    init(connection: SSHConnection) {
        self.connection = connection
    }

    // MARK: - 上传

    /// 流式上传：本地文件 → 远端临时文件 → 校验 → 关闭 → rename 发布。
    ///
    /// - Parameter remoteTarget: 最终目标路径（调用方已完成"目标不存在"预检；
    ///   发布阶段仍由 `rename` flags = 0 兜底防覆盖）。
    /// - Parameter isCancelled: 协作式取消轮询（读取 `TransferCancellation`）。
    /// - Parameter onProgress: 单调进度回调（已传输字节）。
    /// - Returns: 实际传输的字节总数。
    /// - Throws: `TransferError`（取消 / 连接丢失 / 权限 / 本地 I/O / 校验）。
    func upload(
        localURL: URL,
        remoteDirectory: String,
        remoteTarget: String,
        isCancelled: @escaping @Sendable () async -> Bool,
        onProgress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Int64 {
        // 远端临时文件：与目标同目录，发布时 rename 才能保持原子。
        let tempPath = RemotePath.join(
            remoteDirectory,
            child: ".macssh-upload-\(UUID().uuidString).partial"
        )

        // 本地文件句柄：文件 I/O 错误统一映射为用户可见文案。
        let localFile: FileHandle
        do {
            localFile = try FileHandle(forReadingFrom: localURL)
        } catch {
            throw TransferError.localReadFailed
        }
        defer { try? localFile.close() }

        // 远端临时文件：EXCL 创建，服务器拒绝覆盖任何既有文件。
        let handle: SFTPFileHandle
        do {
            handle = try await connection.sftpOpenTemporaryFileForWrite(at: tempPath)
        } catch {
            throw await mapOperationError(error, cancellation: isCancelled)
        }

        var transferred: Int64 = 0
        var remoteHandleClosed = false
        var streamFailure: TransferError?

        var buffer = [UInt8]()
        buffer.reserveCapacity(Self.chunkSize)

        do {
            while true {
                if await isCancelled() {
                    throw TransferError.cancelled
                }

                // 本地读一块；读失败按本地 I/O 错误处理。
                let chunk: Data
                do {
                    chunk = try localFile.read(upToCount: Self.chunkSize) ?? Data()
                } catch {
                    throw TransferError.localReadFailed
                }
                if chunk.isEmpty {
                    break // EOF
                }

                transferred += Int64(chunk.count)
                try await writeChunk(chunk, handle: handle, isCancelled: isCancelled)
                await onProgress(transferred)

                // 测试接缝 + 协作让出：分块边界让 Terminal 读写 / Browser
                // 列举按 FIFO 插入，传输绝不独占连接。
                await connection.runTestSFTPFileTransferChunkHookIfArmed()
                await Task.yield()
            }

            // 关闭句柄（收尾路径不检查取消）：Completed 的必要条件之一。
            await connection.sftpCloseFileHandle(handle)
            remoteHandleClosed = true

            if await isCancelled() {
                throw TransferError.cancelled
            }

            // 字节校验：远端临时文件大小必须与本地写入总数完全一致。
            let stat: SFTPFileStatResult
            do {
                stat = try await connection.sftpStatFile(tempPath)
            } catch {
                throw await mapOperationError(error, cancellation: isCancelled)
            }
            guard stat.sizeBytes == transferred else {
                AppLogger.app.error(
                    "Upload byte verification failed (local \(transferred), remote \(stat.sizeBytes.map(String.init) ?? "nil"))"
                )
                throw TransferError.verificationFailed
            }

            if await isCancelled() {
                throw TransferError.cancelled
            }

            // 发布：rename 失败（如目标在他进程中新出现）→ 清理临时文件。
            do {
                try await connection.sftpRenameFile(from: tempPath, to: remoteTarget)
            } catch {
                throw await mapRenameError(error, cancellation: isCancelled)
            }
        } catch let error as TransferError {
            streamFailure = error
        } catch {
            streamFailure = TransferError(sftpError: sftpError(from: error))
        }

        // 收尾：句柄必须关闭、失败 / 取消时临时文件尽力删除。
        if !remoteHandleClosed {
            await connection.sftpCloseFileHandle(handle)
        }
        if streamFailure != nil {
            await removeRemoteTemporaryFile(tempPath)
        }
        if var failure = streamFailure {
            // 如实告知：连接丢失时上面的远端清理必然失败，临时文件
            // 确实残留——把残留文件名写进失败文案，绝不假装已清理。
            if case .connectionLost = failure {
                failure = .connectionLost(
                    remoteResidue: (tempPath as NSString).lastPathComponent
                )
            }
            throw failure
        }
        return transferred
    }

    /// partial write 循环：整块写完才返回（`offset += written`），
    /// 分块边界轮询取消；服务器部分确认时绝不重发已确认字节。
    ///
    /// 缓冲以 `[UInt8]`（Sendable）跨 actor 传递；部分确认时只对
    /// 剩余段重试（`removeFirst`），已确认字节绝不重发。
    private func writeChunk(
        _ chunk: Data,
        handle: SFTPFileHandle,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws {
        var pending = [UInt8](chunk)
        let totalCount = pending.count
        var offset = 0
        while offset < totalCount {
            if await isCancelled() {
                throw TransferError.cancelled
            }

            let written: Int
            do {
                written = try await connection.sftpWriteFileChunk(handle, buffer: pending)
            } catch {
                throw await mapOperationError(error, cancellation: isCancelled)
            }
            guard written > 0 else {
                throw TransferError.remoteWriteFailed
            }
            offset += written
            pending.removeFirst(written)
        }
    }

    // MARK: - 下载

    /// 流式下载：远端文件 → 本地临时文件 → 校验 → 关闭 → 原子替换。
    ///
    /// - Parameter expectedBytes: 调用方预检得到的总大小（用于完成校验；
    ///   服务器未提供大小时传 nil，只校验读到 EOF）。
    /// - Returns: 实际下载字节总数。
    /// - Throws: `TransferError`。
    func download(
        remotePath: String,
        localDestination: URL,
        expectedBytes: Int64?,
        isCancelled: @escaping @Sendable () async -> Bool,
        onProgress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Int64 {
        let directoryURL = localDestination.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(
            ".MacSSH-\(UUID().uuidString).partial"
        )

        // 远端只读打开。
        let handle: SFTPFileHandle
        do {
            handle = try await connection.sftpOpenFileForRead(remotePath)
        } catch {
            throw await mapOperationError(error, cancellation: isCancelled)
        }

        // 本地临时文件：与目标同目录（同卷，保证替换是原子 rename）。
        FileManager.default.createFile(
            atPath: tempURL.path,
            contents: nil
        )
        let localFile: FileHandle
        do {
            localFile = try FileHandle(forWritingTo: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            await connection.sftpCloseFileHandle(handle)
            throw TransferError.localWriteFailed
        }
        defer { try? localFile.close() }

        var transferred: Int64 = 0
        var remoteHandleClosed = false
        var streamFailure: TransferError?

        var buffer = [UInt8]()
        buffer.reserveCapacity(Self.chunkSize)

        do {
            while true {
                if await isCancelled() {
                    throw TransferError.cancelled
                }

                // 远端读一块：> 0 数据 / 0 EOF / < 0 错误（映射为异常）。
                let readCount: Int
                do {
                    readCount = try await connection.sftpReadFileChunk(
                        handle,
                        into: &buffer,
                        maxLength: Self.chunkSize
                    )
                } catch {
                    throw await mapOperationError(error, cancellation: isCancelled)
                }
                if readCount == 0 {
                    break // EOF：数据读完。
                }

                // 本地写一块；写失败按本地错误处理（不污染远端状态）。
                do {
                    try localFile.write(contentsOf: Data(buffer[0..<readCount]))
                } catch {
                    throw TransferError.localWriteFailed
                }

                transferred += Int64(readCount)
                await onProgress(transferred)

                await connection.runTestSFTPFileTransferChunkHookIfArmed()
                await Task.yield()
            }

            // 关闭句柄：句柄正确关闭之后才允许发布替换。
            await connection.sftpCloseFileHandle(handle)
            remoteHandleClosed = true

            if await isCancelled() {
                throw TransferError.cancelled
            }

            // 字节校验：预检大小存在时必须完全一致。
            if let expectedBytes, transferred != expectedBytes {
                AppLogger.app.error(
                    "Download byte verification failed (expected \(expectedBytes), received \(transferred))"
                )
                throw TransferError.verificationFailed
            }

            if await isCancelled() {
                throw TransferError.cancelled
            }

            // 原子替换（目标不存在时等同原子放置）。注意：本实现返回的
            // 是**新文件所在位置**的 URL，绝不是旧文件的备份——绝不能删除，
            // 否则刚下载的文件会被误删。
            do {
                _ = try FileManager.default.replaceItemAt(
                    localDestination,
                    withItemAt: tempURL
                )
            } catch {
                throw TransferError.publishFailed
            }
            guard FileManager.default.fileExists(atPath: localDestination.path) else {
                throw TransferError.publishFailed
            }
        } catch let error as TransferError {
            streamFailure = error
        } catch {
            streamFailure = TransferError(sftpError: sftpError(from: error))
        }

        // 收尾：句柄必须关闭；失败 / 取消时本地临时文件必须删除。
        if !remoteHandleClosed {
            await connection.sftpCloseFileHandle(handle)
        }
        if streamFailure != nil {
            try? FileManager.default.removeItem(at: tempURL)
        }
        if let streamFailure {
            throw streamFailure
        }
        return transferred
    }

    // MARK: - 私有

    /// 失败路径删除远端临时文件（尽力而为：拆除 / 断开时连接层自身
    /// 会快速拒绝，这里不产生新错误；失败时仅记日志，不记路径细节）。
    /// 注意：连接丢失场景下本清理必然失败，残留由失败文案如实告知。
    private func removeRemoteTemporaryFile(_ path: String) async {
        do {
            try await connection.sftpUnlinkFile(path)
        } catch {
            AppLogger.app.error("Transfer temp file cleanup failed: \(error)")
        }
    }

    /// 通用错误映射：取消优先（用户语义），其后统一按 SFTP 业务错误。
    private func mapOperationError(
        _ error: Error,
        cancellation: @escaping @Sendable () async -> Bool
    ) async -> TransferError {
        if await cancellation() {
            return .cancelled
        }
        return TransferError(sftpError: sftpError(from: error))
    }

    /// rename 失败映射：目标已存在（预检后被他进程创建）给出明确文案。
    private func mapRenameError(
        _ error: Error,
        cancellation: @escaping @Sendable () async -> Bool
    ) async -> TransferError {
        if await cancellation() {
            return .cancelled
        }
        let sftp = sftpError(from: error)
        if sftp == .noSuchPath || sftp == .permissionDenied || sftp == .connectionLost {
            return TransferError(sftpError: sftp)
        }
        return .remoteFileExists
    }

    private func sftpError(from error: Error) -> SFTPError {
        (error as? SFTPError) ?? .connectionLost
    }
}
