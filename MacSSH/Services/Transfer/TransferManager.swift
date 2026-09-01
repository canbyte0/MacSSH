import Foundation
import Observation

/// Phase 11 Transfer Queue：多任务排队 + 事件驱动调度 + 全局串行传输。
///
/// 所有权（任务书）：
/// - 由 `AppState` 持有（App 层稳定对象），绝不属于任何 SwiftUI View——
///   切换页面 / 切换会话 / 关闭 Transfers 面板都不影响队列运行；
/// - 与 `SessionManager` 双向协作（均弱引用，AppState 统一持有两者）：
///   关闭 / Reconnect 会话前经屏障先取消并等待传输清理完成，
///   再走 SFTP / Terminal / 连接拆除；重连成功后通知调度器补位。
///
/// 并发策略（任务书八 / 十：集中定义，不散落在 View / Service）：
/// - 全局至多 1 个活跃传输（1.0 严格串行；Concurrent Transfer
///   属计划书 2.0 路线，本阶段绝不提前实现）；
/// - 每 SSH Session 至多 1 个活跃传输（全局 1 下自然满足，保留作防御语义）；
/// - 槽位计数直接从任务状态机推导（`occupiesActiveSlot`），
///   完成 / 失败 / 取消即释放，不存在需要手动维护的独立计数器漂移。
///
/// 调度（任务书十二 / 十三：事件驱动 + 防重入）：
/// - 绝不轮询（无 Timer）；入队 / 完成 / 失败 / 取消 / 重连触发 `scheduleNext()`；
/// - MainActor 串行 + `isScheduling` 闩 + `markStarted()`（pending → preparing
///   原子转换）双保险——同一任务绝不会被启动两次；
/// - FIFO + 资格过滤：遍历时跳过暂不符合条件的任务继续寻找，
///   无队头阻塞；同一 Session 内部严格保持入队顺序（绝不越位）。
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
    /// 全局活跃传输上限（任务书八：集中定义的常量）。
    /// 1.0 固定为 1：所有传输全局串行排队（Concurrent Transfer 属 2.0 路线）。
    static let maximumConcurrentTransfers = 1

    /// 每个 SSH Session 活跃传输上限（任务书九：同一连接至多 1 个）。
    static let maximumActiveTransfersPerSession = 1

    /// 队列内存安全上限（任务书三十六：集中定义，超出即拒绝入队）。
    static let maximumQueueLength = 1000

    /// 全部传输任务（创建顺序 = FIFO 基准；UI 按需倒序展示）。
    private(set) var tasks: [TransferTask] = []

    weak var sessionManager: SessionManager?

    /// 由 AppState 装配的语言 provider：调度器与拒绝路径据此按当前 App Locale
    /// 生成用户文案；不持有 AppState，避免引用环。语言切换只更新文案，
    /// 绝不重建传输任务或 Session。
    @ObservationIgnored
    var localeProvider: (@MainActor () -> Locale)?

    /// 调度与拒绝路径统一入口；装配前 fallback 到 zh-Hans，绝不 Crash。
    private var schedulingLocale: Locale {
        MainActor.assumeIsolated { localeProvider?() ?? AppLanguage.defaultLanguage.locale }
    }

    /// 调度防重入闩（MainActor 串行内仍上锁：事件密集时避免重复扫描启动）。
    @ObservationIgnored
    private var isScheduling = false

    // MARK: - 查询

    /// 活跃传输（占用槽位：preparing / transferring / cancelling）。
    var activeTasks: [TransferTask] {
        tasks.filter { $0.state.occupiesActiveSlot }
    }

    var activeTask: TransferTask? {
        activeTasks.first
    }

    var hasActiveTransfer: Bool {
        !activeTasks.isEmpty
    }

    /// 指定 Session 是否有活跃传输（关闭会话确认 / 会话隔离使用）。
    func hasActiveTransfer(forSession sessionID: UUID) -> Bool {
        tasks.contains { $0.sessionID == sessionID && $0.state.occupiesActiveSlot }
    }

    /// 指定 Session 的未终态任务数（活跃 + 排队；关闭确认文案使用）。
    func transferCount(forSession sessionID: UUID) -> Int {
        tasks.count { $0.sessionID == sessionID && !$0.state.isTerminal }
    }

    /// 底部状态栏汇总（按当前 App Locale 生成）：例如
    /// "2 传输中 · 3 等待"（zh-Hans）/ "2 Transferring · 3 Waiting"（en）；
    /// 无任务时返回 nil。
    func queueSummary(locale: Locale) -> String? {
        let running = activeTasks.count
        let waiting = tasks.count { $0.state == .pending }
        guard running + waiting > 0 else {
            return nil
        }
        var parts: [String] = []
        if running > 0 {
            parts.append(L10n.format(
                "transfer.queue.running",
                defaultValue: "%lld Transferring",
                locale: locale,
                arguments: Int64(running)
            ))
        }
        if waiting > 0 {
            parts.append(L10n.format(
                "transfer.queue.waiting",
                defaultValue: "%lld Waiting",
                locale: locale,
                arguments: Int64(waiting)
            ))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 入口（UI 调用；返回任务或拒绝文案）

    /// 上传本地文件到当前浏览目录（Phase 11：入队，不再"已有任务即拒绝"）。
    ///
    /// 拒绝顺序（均不创建任务）：队列已满 → 本地不是普通文件 →
    /// 会话不可用 → 与在途 / 排队任务的远端目标冲突。
    /// 入队后任务为 pending，由调度器按策略启动；启动时重新预检
    /// （源文件 / 远端目标以实际执行时刻为准）。
    @discardableResult
    func requestUpload(
        session: ManagedTerminalSession,
        localURL: URL
    ) -> (task: TransferTask?, rejection: String?) {
        if tasks.count >= Self.maximumQueueLength {
            return (nil, L10n.string(
                "error.transfer.queue_full",
                defaultValue: "The transfer queue is full. Please wait for some tasks to finish.",
                locale: schedulingLocale
            ))
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: localURL.path,
            isDirectory: &isDirectory
        )
        guard exists, !isDirectory.boolValue else {
            return (nil, L10n.string(
                "error.transfer.upload_regular_file_only",
                defaultValue: "Only regular files can be uploaded.",
                locale: schedulingLocale
            ))
        }

        guard session.kind == .remoteSSH, !session.isClosed,
              let sftp = session.sftpService
        else {
            return (nil, L10n.string(
                "error.transfer.session_unavailable",
                defaultValue: "The current session is unavailable.",
                locale: schedulingLocale
            ))
        }

        let remoteDirectory = sftp.currentPath
        let remoteTarget = RemotePath.join(remoteDirectory, child: localURL.lastPathComponent)
        if hasUploadConflict(sessionID: session.id, remoteTarget: remoteTarget) {
            return (nil, L10n.string(
                "error.transfer.upload_conflict",
                defaultValue: "A task uploading to the same remote destination is already in the queue.",
                locale: schedulingLocale
            ))
        }

        let task = TransferTask(
            direction: .upload,
            sessionID: session.id,
            sessionTitle: session.title,
            remotePath: remoteTarget,
            localName: localURL.lastPathComponent,
            localURL: localURL
        )
        enqueue(task, session: session)
        return (task, nil)
    }

    /// 下载远端普通文件到本地目标位置（入队；启动时重新 stat 快照大小）。
    @discardableResult
    func requestDownload(
        session: ManagedTerminalSession,
        entry: SFTPFileEntry,
        destinationURL: URL
    ) -> (task: TransferTask?, rejection: String?) {
        if tasks.count >= Self.maximumQueueLength {
            return (nil, L10n.string(
                "error.transfer.queue_full",
                defaultValue: "The transfer queue is full. Please wait for some tasks to finish.",
                locale: schedulingLocale
            ))
        }
        guard entry.kind == .regularFile else {
            return (nil, L10n.string(
                "error.transfer.download_regular_file_only",
                defaultValue: "Only regular files can be downloaded.",
                locale: schedulingLocale
            ))
        }
        guard session.kind == .remoteSSH, !session.isClosed else {
            return (nil, L10n.string(
                "error.transfer.session_unavailable",
                defaultValue: "The current session is unavailable.",
                locale: schedulingLocale
            ))
        }
        if hasDownloadConflict(localDestination: destinationURL) {
            return (nil, L10n.string(
                "error.transfer.download_conflict",
                defaultValue: "A task downloading to the same local destination is already in the queue.",
                locale: schedulingLocale
            ))
        }

        let remotePath = RemotePath.join(session.sftpService?.currentPath ?? "", child: entry.name)
        let task = TransferTask(
            direction: .download,
            sessionID: session.id,
            sessionTitle: session.title,
            remotePath: remotePath,
            localName: destinationURL.lastPathComponent,
            localURL: destinationURL,
            totalBytes: entry.sizeBytes.map { Int64(clamping: $0) }
        )
        enqueue(task, session: session)
        return (task, nil)
    }

    /// 入队：登记会话弱引用 → 登记 → 事件驱动调度（任务书十二：任务加入即触发）。
    private func enqueue(_ task: TransferTask, session: ManagedTerminalSession?) {
        task.sessionRef = session
        tasks.append(task)
        AppLogger.app.info("Transfer queued")
        scheduleNext()
    }

    // MARK: - 冲突预检（任务书八十五~八十七：最低要求明确处理，不做文件锁框架）

    /// 同 Session 已有未终态上传指向同一远端目标 → 冲突。
    private func hasUploadConflict(sessionID: UUID, remoteTarget: String) -> Bool {
        tasks.contains {
            $0.sessionID == sessionID
                && $0.direction == .upload
                && !$0.state.isTerminal
                && $0.remotePath == remoteTarget
        }
    }

    /// 任意未终态下载指向同一本地目标 → 冲突（绝不两个任务发布到同一目的地）。
    private func hasDownloadConflict(localDestination: URL) -> Bool {
        tasks.contains {
            $0.direction == .download
                && !$0.state.isTerminal
                && $0.localURL == localDestination
        }
    }

    // MARK: - 调度器（事件驱动，绝不轮询）

    /// 调度下一批任务：全局 / 每会话限额内的合格 pending 任务全部启动。
    ///
    /// 事件入口：入队、完成、失败、取消收尾、会话重连。防重入闩 +
    /// `markStarted()` 原子转换保证同一任务绝不重复启动（任务书十三 / 十四）。
    /// 遍历跳过不合格任务继续寻找——A2 受限时绝不阻塞 B1（任务书四十五）。
    func scheduleNext() {
        guard !isScheduling else {
            return
        }
        isScheduling = true
        defer { isScheduling = false }

        var startedAny = false
        for (taskIndex, task) in tasks.enumerated() {
            guard activeTasks.count < Self.maximumConcurrentTransfers else {
                break // 全局槽位满：后续任务保持 pending。
            }
            guard task.state == .pending else {
                continue
            }

            let sessionState = sessionAvailability(for: task)
            switch sessionState {
            case .missing:
                // Session 已被移除（关闭屏障会先取消任务；此为防御路径，
                // 不 fatalError，安全收尾，任务书九十九）。
                //
                // 只写语言无关枚举，绝不在此按 schedulingLocale 生成文案——
                // failed 是终态，缓存的字符串在之后切换语言时无法更新。
                task.markStarted()
                task.markFailed(error: .sessionMissing)
                AppLogger.app.error("Scheduler found a task without session")
                continue
            case .disconnected:
                // 连接丢失：不启动、不重复失败，保持等待（任务书二十三）。
                task.setAwaitingConnection(true)
                continue
            case .activeOccupied:
                // 该会话已有活跃传输（每会话 1）；同会话严格保序——
                // 本任务之后的同会话任务也绝无资格，跳过继续找别的会话。
                task.setAwaitingConnection(false)
                continue
            case .available:
                task.setAwaitingConnection(false)
            }

            // 同会话保序（任务书四十六）：只有该会话最早的 pending 才有资格，
            // 绝不允许 A3 越过 A2（索引比较，避免依赖 Equatable）。
            let isHeadOfSession = !tasks.enumerated().contains { candidateIndex, candidate in
                candidate.sessionID == task.sessionID && candidate.state == .pending
                    && candidateIndex != taskIndex
                    && (candidate.queuedAt < task.queuedAt
                        || (candidate.queuedAt == task.queuedAt && candidateIndex < taskIndex))
            }
            guard isHeadOfSession else {
                continue
            }

            // 原子启动：首个成功完成 pending → preparing 转换者才是启动者。
            guard task.markStarted() else {
                continue
            }
            startedAny = true
            startExecution(task)
        }
        _ = startedAny
    }

    /// 会话可用性（调度资格判定）。
    private enum SessionAvailability {
        /// Session 存在且已连接。
        case available
        /// Session 存在且有活跃传输（每会话限额已满）。
        case activeOccupied
        /// Session 存在但连接不可用（等待重连，不启动）。
        case disconnected
        /// Session 已不存在（已关闭移除）。
        case missing
    }

    /// 会话解析：生产路径始终经 SessionManager 取**当前**会话（重连后是全新
    /// generation）；仅未装配 SessionManager 的测试直连场景回退入队时的弱引用。
    private func resolveSession(for task: TransferTask) -> ManagedTerminalSession? {
        sessionManager?.session(withID: task.sessionID) ?? task.sessionRef
    }

    private func sessionAvailability(for task: TransferTask) -> SessionAvailability {
        guard let session = resolveSession(for: task), !session.isClosed else {
            return .missing
        }
        guard session.kind == .remoteSSH else {
            return .missing
        }
        if hasActiveTransfer(forSession: task.sessionID) {
            return .activeOccupied
        }
        guard session.connection != nil,
              session.connectionInfo?.phase == .connected
        else {
            return .disconnected
        }
        return .available
    }

    /// Session 重连成功（SessionManager 在新连接装配完成后调用）：
    /// 复位等待连接标记并立即补位调度（任务书十七 / 二十三）。
    func notifySessionReconnected(sessionID: UUID) {
        for task in tasks where task.sessionID == sessionID && task.state == .pending {
            task.setAwaitingConnection(false)
        }
        scheduleNext()
    }

    // MARK: - 执行

    /// 启动一个任务的执行（调度器已通过 `markStarted()` 取得唯一所有权）。
    /// 启动时重新解析**当前**连接（路径快照冻结，但连接对象以执行时刻为准——
    /// 重连后是全新 generation，旧连接绝不复用）。
    private func startExecution(_ task: TransferTask) {
        guard let session = resolveSession(for: task),
              !session.isClosed,
              let connection = session.connection,
              session.connectionInfo?.phase == .connected
        else {
            // 调度与断开竞态：启动瞬间连接已不可用——如实失败（任务书十七：
            // 绝不自动续传 / 自动重试，Retry 属计划书 2.0 路线）。
            task.markFailed(error: .connectionLost(remoteResidue: nil))
            AppLogger.app.error("Transfer start aborted: session unavailable")
            scheduleNext()
            return
        }

        let service = SFTPTransferService(connection: connection)
        let isCancelled: @Sendable () async -> Bool = { [cancellation = task.cancellation] in
            cancellation.value
        }
        let onProgress = makeProgressReporter(task)

        task.executionTask = Task { @MainActor [weak self] in
            defer { task.executionTask = nil }

            do {
                switch task.direction {
                case .upload:
                    try await Self.executeUpload(
                        task,
                        connection: connection,
                        service: service,
                        isCancelled: isCancelled,
                        onProgress: onProgress
                    )
                    if let self {
                        await self.notifyUploadCompleted(task: task, connection: connection)
                    }
                case .download:
                    try await Self.executeDownload(
                        task,
                        connection: connection,
                        service: service,
                        isCancelled: isCancelled,
                        onProgress: onProgress
                    )
                }
                task.markCompleted()
                AppLogger.app.info("File transfer completed")
            } catch let error as TransferError {
                Self.finish(task, with: error)
            } catch {
                Self.finish(task, with: TransferError(sftpError: (error as? SFTPError) ?? .connectionLost))
            }

            // 任务到达终态（槽位释放）→ 事件驱动补位（任务书二十~二十二）。
            self?.scheduleNext()
        }
    }

    /// 上传执行体：启动时重新预检（任务书三十八 / 四十：以实际执行时刻为准）。
    private static func executeUpload(
        _ task: TransferTask,
        connection: SSHConnection,
        service: SFTPTransferService,
        isCancelled: @escaping @Sendable () async -> Bool,
        onProgress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        // 本地源重新检查：存在 / 普通文件 / 重新快照大小。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: task.localURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw TransferError.localReadFailed
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: task.localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        task.setTotalBytes(size)

        try await connection.openSFTPSubsystemIfNeeded()

        // 默认不覆盖：目标已存在直接失败（发布侧另有协议级防线）。
        if try await remoteFileExists(connection, path: task.remotePath) {
            throw TransferError.remoteFileExists
        }

        let remoteDirectory = RemotePath.parent(of: task.remotePath)
        task.markTransferring()
        _ = try await service.upload(
            localURL: task.localURL,
            remoteDirectory: remoteDirectory,
            remoteTarget: task.remotePath,
            isCancelled: isCancelled,
            onProgress: onProgress
        )
    }

    /// 下载执行体：启动时重新 stat（任务书三十九 / 四十：不信入队时的旧 metadata）。
    private static func executeDownload(
        _ task: TransferTask,
        connection: SSHConnection,
        service: SFTPTransferService,
        isCancelled: @escaping @Sendable () async -> Bool,
        onProgress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        try await connection.openSFTPSubsystemIfNeeded()

        let stat = try await connection.sftpStatFile(task.remotePath)
        guard stat.isRegularFile else {
            throw TransferError.remoteFileMissing
        }
        // 注意：远端非普通文件已被业务预检在入队时拒绝，stat.isRegularFile
        // 仅为防御路径（入队后远端可能变更为目录 / 符号链接）。失败语义统一
        // 走 remoteFileMissing，提示用户重新选择下载条目。
        if let sizeBytes = stat.sizeBytes {
            task.setTotalBytes(sizeBytes)
        }

        task.markTransferring()
        _ = try await service.download(
            remotePath: task.remotePath,
            localDestination: task.localURL,
            expectedBytes: stat.sizeBytes,
            isCancelled: isCancelled,
            onProgress: onProgress
        )
    }

    /// 进度回调：单调提交；节流约 150ms 一次（5~7 次/秒），
    /// 最终字节精确提交（绝不丢最后的 100%）。每任务独立，
    /// 绝不共用全局进度（任务书四十七 / 四十八）。
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
    ///
    /// 失败只写入**语言无关**的 `TransferError`，绝不写入按当时 Locale 生成
    /// 好的字符串——failed 是终态，缓存的文案在之后切换语言时无法更新
    /// （任务书七十三）。展示由 `TransferTask.failureMessage(locale:)` 即时解析。
    ///
    /// 日志走 `errorDescription`（英文 fallback）：日志是诊断通道，不参与 UI，
    /// 不受语言切换影响。
    private static func finish(_ task: TransferTask, with error: TransferError) {
        if error == .cancelled {
            task.markCancelled()
            AppLogger.app.info("File transfer cancelled")
        } else {
            task.markFailed(error: error)
            AppLogger.app.error("File transfer failed: \(error.errorDescription ?? "", privacy: .public)")
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

    // MARK: - 取消 / 移除

    /// 请求取消（幂等）：
    /// - pending：直接终态取消——绝不创建句柄 / 打开文件 / 触碰连接（任务书十八）；
    /// - 运行中：只置标志（复用 Phase 10 协作式取消，绝不写第二套）。
    func cancel(_ taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else {
            return
        }
        switch task.state {
        case .pending:
            task.markCancelled()
            AppLogger.app.info("Pending transfer cancelled")
            scheduleNext()
        case .preparing, .transferring:
            task.markCancelling()
            task.requestCancel()
        case .cancelling, .completed, .failed, .cancelled:
            break
        }
    }

    /// 从列表移除终态任务（任务书三十三：仅终态可移除；
    /// Running / Pending 请使用取消）。
    func remove(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        guard tasks[index].state.isTerminal else {
            return
        }
        tasks.remove(at: index)
    }

    /// Transfers 页 Clear Finished：只清终态，绝不动
    /// pending / 运行中 / 取消收尾中的任务（任务书三十二）。
    func clearFinished() {
        tasks.removeAll { $0.state.isTerminal }
    }

    // MARK: - 拆除屏障

    /// 关闭会话 / Reconnect / 退出前调用（任务书二十六 / 八十一 / 八十二）：
    /// 1) pending 直接取消（无 C 句柄，不进 SFTP 清理）；
    /// 2) 活跃传输请求取消并等待执行任务完全结束（含句柄关闭与临时文件清理）。
    /// 本方法返回即传输侧无在途操作，其后的 SFTP / SSH 拆除绝不交错。
    func cancelAndAwaitTransfers(forSession sessionID: UUID) async {
        let targets = tasks.filter { $0.sessionID == sessionID && !$0.state.isTerminal }
        for task in targets {
            cancel(task.id)
        }
        for task in targets {
            await task.executionTask?.value
        }
    }

    /// Reconnect 专用拆除屏障（任务书十七 / 二十三）：
    /// 只取消并等待占活跃槽的任务（旧传输绝不触碰新连接，generation 安全），
    /// 绝不动排队的 pending——重连成功后由 `notifySessionReconnected`
    /// 触发调度，pending 经新连接继续。典型场景是连接已丢失：
    /// running 早已 failed，本方法立即返回；即便仍有收尾中任务，
    /// 等待后连接不可用使调度资格检查不过，不会有新任务启动，
    /// 循环必然收敛（与 `cancelAndAwaitTransfers` 的"全取消"语义区分）。
    func cancelAndAwaitRunningTransfersForReconnect(forSession sessionID: UUID) async {
        while true {
            let targets = tasks.filter {
                $0.sessionID == sessionID && $0.state.occupiesActiveSlot
            }
            if targets.isEmpty {
                return
            }
            for task in targets {
                cancel(task.id)
            }
            for task in targets {
                await task.executionTask?.value
            }
        }
    }

    /// App 退出前：取消全部未终态任务并等待收尾（任务书三十五：
    /// 不做后台继续传输；无崩溃、无 double-free）。
    func cancelAndAwaitAllTransfers() async {
        let targets = tasks.filter { !$0.state.isTerminal }
        for task in targets {
            cancel(task.id)
        }
        for task in targets {
            await task.executionTask?.value
        }
    }

    // MARK: - 文件操作冲突防护（任务书八十九 / 九十）

    /// 该远端路径是否正被该会话的活跃传输使用
    /// （下载源 / 上传目标与临时文件所在目录的发布目标）；
    /// SFTPService 的 Rename / Delete 在执行前查询，冲突即拒绝。
    /// Mkdir 不冲突（任务书九十一）。
    func isRemotePathInActiveTransfer(sessionID: UUID, remotePath: String) -> Bool {
        tasks.contains {
            $0.sessionID == sessionID
                && $0.state.occupiesActiveSlot
                && $0.remotePath == remotePath
        }
    }
}

/// 传输冲突防护的注入点（任务书八十九 / 九十）：SFTPService 在创建时不持有
/// TransferManager（惰性创建于 Session 内部），由 AppState 在启动时把
/// 当前 TransferManager 的查询装入本闸；未装配（单元测试直连）时恒为不冲突。
enum TransferConflictGate {
    /// (sessionID, remotePath) → 是否正被该会话的活跃传输使用。
    @MainActor
    static var isRemotePathInActiveTransfer: ((UUID, String) -> Bool)?

    /// 装配 / 拆除（仅 AppState 调用；重复装配以最后一次为准）。
    @MainActor
    static func install(manager: TransferManager?) {
        guard let manager else {
            isRemotePathInActiveTransfer = nil
            return
        }
        isRemotePathInActiveTransfer = { sessionID, path in
            manager.isRemotePathInActiveTransfer(sessionID: sessionID, remotePath: path)
        }
    }
}
