import Darwin
import Foundation

/// stat 返回的最小文件属性（只取传输需要的字段；按 `flags` 取值，
/// 缺失字段保持 nil，绝不猜测默认值）。
struct SFTPFileStatResult: Equatable, Sendable {
    let sizeBytes: Int64?
    let isRegularFile: Bool
    let isDirectory: Bool
    let isSymlink: Bool
}

/// 传输文件句柄包装：底层 `LIBSSH2_SFTP_HANDLE *` 的全部操作由
/// `SSHConnection` actor + FIFO 串行门串行执行；包装只是跨 actor 的
/// 身份令牌，因此可以安全标记 `@unchecked Sendable`。
struct SFTPFileHandle: Equatable, @unchecked Sendable {
    let raw: OpaquePointer
}

/// Phase 10：SFTP **文件级**操作能力，以 extension 形式挂在既有
/// `SSHConnection` actor 上（与 `SFTPSession.swift` 的目录列举层并列，
/// 全部 `LIBSSH2_SFTP *` / `LIBSSH2_SFTP_HANDLE *` 调用保持在本 actor
/// 串行边界内）。
///
/// 操作面（计划书 Phase 10：upload / download / rename / delete / mkdir）：
/// - `stat` / 只读打开 / 写入打开（临时文件，EXCL 防覆盖）/ 分块
///   `read` / `write` / `close_handle`；
/// - `rename`：传输发布（临时文件 → 目标）与用户重命名共用；
///   `flags = 0` 时 OpenSSH 走 posix-rename 扩展，目标已存在则失败——
///   传输发布"默认不覆盖"与用户重命名"不覆盖已有名称"的协议级保证；
/// - `unlink`：传输失败清理临时文件与用户删除文件共用；
/// - `mkdir`：用户新建目录（权限 0755）。
///
/// 串行门与协作调度（任务书：FIFO 门不得绕过，但传输不得独占连接）：
/// - 每个文件级操作（含单个分块）独立持门进出——传输分块之间
///   Terminal 读写 / Browser 列举都能按 FIFO 插入，大文件传输期间
///   连接不被独占；
/// - 旧操作因 EAGAIN 挂起（actor 让出）期间新操作绝不进入同一
///   `LIBSSH2_SFTP` 状态机；
/// - EAGAIN 一律复用 `waitForLibssh2Readiness`（block_directions →
///   poll / 零方向退避），绝不 busy-loop；文件句柄 close 同样有界
///   重试，不因 EAGAIN 泄漏句柄。
///
/// 拆除安全（镜像目录句柄模式）：
/// - 打开的文件句柄登记在 `openSFTPFileHandles`——登记是关闭所有权的
///   认领令牌：句柄只在真正摘除它的一方手里关闭；
/// - 每个文件级操作（连同其收尾关闭）计入 `inFlightSFTPFileOperationCount`，
///   `closeSFTPResourcesForTeardown()` 先排空全部在途文件操作，
///   再关闭无主残留句柄、最后 `libssh2_sftp_shutdown`；
/// - 打开操作把登记留在计数内（直到句柄关闭才递减），保证
///   "打开后未开始分块就被拆除"的窗口同样被排空屏障覆盖。
extension SSHConnection {
    /// 文件级操作超时预算（每步独立；分块预算覆盖单分块的完整往返）。
    private enum SFTPFileTimeouts {
        static let stat: TimeInterval = 10
        static let open: TimeInterval = 10
        static let chunkIO: TimeInterval = 60
        static let close: TimeInterval = 5
        static let rename: TimeInterval = 10
        static let unlink: TimeInterval = 10
        static let mkdir: TimeInterval = 10
    }

    /// SSH_FXF_* 打开标志（协议常量；C 宏在 Swift 中不可靠，显式定义）。
    private enum SFTPFileFlags {
        static let read: UInt = 0x1
        static let write: UInt = 0x2
        static let creat: UInt = 0x8
        static let excl: UInt = 0x20
    }

    /// `LIBSSH2_SFTP_ATTRIBUTES` 位与文件类型位（与列举层同源的协议常量）。
    private enum SFTPFileMode {
        static let attrSize: UInt = 0x1
        static let attrPermissions: UInt = 0x4
        static let modeMask: UInt = 0o170000
        static let ifDir: UInt = 0o040000
        static let ifLnk: UInt = 0o120000
        static let ifReg: UInt = 0o100000
    }

    /// 临时上传文件的创建权限（仅属主读写）。
    private static let uploadTempMode = 0o600

    /// 用户新建目录的权限（属主全权 + 组 / 其他可读可进入）。
    private static let mkdirMode = 0o755

    // MARK: - 观察点（测试 / 拆除）

    var openSFTPFileHandleCount: Int { openSFTPFileHandles.count }

    // MARK: - 竞态测试接缝（生产恒为 nil）

    /// 安装 / 清除传输分块接缝（带 armed 开关：默认关闭，
    /// 避免生产传输每分块付出一次异步调用代价）。
    func setTestSFTPFileTransferChunkHook(
        armed: Bool,
        _ hook: (@Sendable () async -> Void)?
    ) {
        testSFTPFileTransferChunkHookArmed = armed
        testSFTPFileTransferChunkHook = hook
    }

    /// 安装 / 清除文件句柄打开后接缝。
    func setTestSFTPAfterFileHandleOpenHook(_ hook: (@Sendable () async -> Void)?) {
        testSFTPAfterFileHandleOpenHook = hook
    }

    /// 安装 / 清除文件句柄关闭前接缝。
    func setTestSFTPBeforeFileHandleCloseHook(_ hook: (@Sendable () async -> Void)?) {
        testSFTPBeforeFileHandleCloseHook = hook
    }

    /// 设置 / 清除单次写入字节上限（强制 partial write 接缝）：
    /// 设置后每次 `libssh2_sftp_write` 最多提交该字节数，服务器真实只写入该量，
    /// 确定性验证上层 `offset += written` 重试循环的字节完整性。
    func setTestSFTPFileWriteMaxBytesPerCall(_ cap: Int?) {
        testSFTPFileWriteMaxBytesPerCall = cap
    }

    // MARK: - stat

    /// 查询远端路径属性（上传预检目标存在性 / 下载取总大小）。
    ///
    /// 路径不存在抛 `noSuchPath`，权限不足抛 `permissionDenied`
    /// （业务错误：保持连接与 Terminal 不变）。
    func sftpStatFile(_ path: String) async throws -> SFTPFileStatResult {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }

        inFlightSFTPFileOperationCount += 1
        defer { completeInFlightSFTPFileOperation() }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }
        try validateSFTPOperation(session: session, sftp: sftp)

        let deadline = Date().addingTimeInterval(SFTPFileTimeouts.stat)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES(
            flags: 0,
            filesize: 0,
            uid: 0,
            gid: 0,
            permissions: 0,
            atime: 0,
            mtime: 0
        )

        while true {
            try validateSFTPOperation(session: session, sftp: sftp)

            let rc = path.withCString { pathPointer in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    LIBSSH2_SFTP_STAT,
                    &attributes
                )
            }

            if rc == 0 {
                return makeStatResult(attributes)
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await sftpWaitForReadiness(session: session, deadline: deadline)
                continue
            }

            throw sftpFailureError(session: session, sftp: sftp)
        }
    }

    // MARK: - 打开（OPENFILE）

    /// 只读打开远端文件（下载入口）。
    ///
    /// 登记先于进门语义：计数在进门之前递增，`defer` 在打开失败时递减；
    /// 打开成功则把计数保留到句柄关闭（覆盖"打开后尚未分块就被拆除"窗口）。
    /// 取消 / 断开 / 权限 / 不存在经统一校验与错误映射。
    func sftpOpenFileForRead(_ path: String) async throws -> SFTPFileHandle {
        try await openFileHandle(
            path: path,
            flags: SFTPFileFlags.read,
            deadline: Date().addingTimeInterval(SFTPFileTimeouts.open)
        )
    }

    /// 写入打开（传输专用临时文件）：`WRITE|CREAT|EXCL`——
    /// 目标已存在时服务器直接拒绝，绝不静默覆盖任何远端文件；
    /// 权限 0600（仅属主读写）。
    func sftpOpenTemporaryFileForWrite(at path: String) async throws -> SFTPFileHandle {
        try await openFileHandle(
            path: path,
            flags: SFTPFileFlags.write | SFTPFileFlags.creat | SFTPFileFlags.excl,
            deadline: Date().addingTimeInterval(SFTPFileTimeouts.open)
        )
    }

    private func openFileHandle(
        path: String,
        flags: UInt,
        deadline: Date
    ) async throws -> SFTPFileHandle {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }

        inFlightSFTPFileOperationCount += 1
        var opened = false
        defer {
            if !opened {
                completeInFlightSFTPFileOperation()
            }
        }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }
        try validateSFTPOperation(session: session, sftp: sftp)

        while true {
            try validateSFTPOperation(session: session, sftp: sftp)

            // 函数式宏 `libssh2_sftp_open` 在 Swift 中不可用；
            // 它背后的真实函数是 `libssh2_sftp_open_ex` + OPENFILE 类型。
            let handle = path.withCString { pathPointer in
                libssh2_sftp_open_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    flags,
                    Self.uploadTempMode,
                    LIBSSH2_SFTP_OPENFILE
                )
            }
            if let handle {
                openSFTPFileHandles.append(handle)
                sftpFileHandleOpenCount += 1
                opened = true

                // 竞态测试接缝（生产恒为 nil）：句柄已打开并登记、
                // 首个分块尚未开始的确定性窗口。
                await testSFTPAfterFileHandleOpenHook?()
                return SFTPFileHandle(raw: handle)
            }

            let lastError = libssh2_session_last_errno(session)
            guard lastError == LIBSSH2_ERROR_EAGAIN else {
                throw sftpFailureError(session: session, sftp: sftp)
            }

            try await sftpWaitForReadiness(session: session, deadline: deadline)
        }
    }

    // MARK: - 分块读写（单分块 = 单次持门周期）

    /// 读取一个分块：`> 0` 数据字节数，`0` = EOF，负值已映射为错误。
    ///
    /// 单个分块是一个完整持门周期（含其 EAGAIN 等待）；返回后调用方
    /// 做本地写盘等 I/O 期间门是空闲的——Terminal / Browser 可插入。
    /// 句柄必须仍在登记中（否则拆除已回收它）。
    ///
    /// - Parameter buffer: 读入缓冲；不足 `maxLength` 时自动扩容，
    ///   绝不截断数据。
    /// - Returns: 实际读取字节数；`0` 表示文件结束（EOF 语义）。
    func sftpReadFileChunk(
        _ handle: SFTPFileHandle,
        into buffer: inout [UInt8],
        maxLength: Int
    ) async throws -> Int {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }

        inFlightSFTPFileOperationCount += 1
        defer { completeInFlightSFTPFileOperation() }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }
        try validateSFTPFileHandle(session: session, sftp: sftp, handle: handle)

        let deadline = Date().addingTimeInterval(SFTPFileTimeouts.chunkIO)
        if buffer.count < maxLength {
            buffer = [UInt8](repeating: 0, count: maxLength)
        }

        while true {
            try validateSFTPFileHandle(session: session, sftp: sftp, handle: handle)

            let rc = buffer.withUnsafeMutableBytes { rawPointer -> Int in
                guard let base = rawPointer.baseAddress else {
                    return Int(LIBSSH2_ERROR_INVAL)
                }
                return libssh2_sftp_read(handle.raw, base, maxLength)
            }

            if rc >= 0 {
                return rc
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await sftpWaitForReadiness(session: session, deadline: deadline)
                continue
            }

            throw sftpFailureError(session: session, sftp: sftp)
        }
    }

    /// 写入一个分块的**一段**（partial write 语义）：返回实际写入字节数
    /// `> 0`；调用方必须循环推进 `offset += written` 直到整段写完。
    ///
    /// 返回 0 按协议错误处理（服务器未消费任何字节会让循环空转）。
    func sftpWriteFileChunk(
        _ handle: SFTPFileHandle,
        buffer: [UInt8]
    ) async throws -> Int {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }
        guard buffer.count > 0 else {
            return 0
        }

        inFlightSFTPFileOperationCount += 1
        defer { completeInFlightSFTPFileOperation() }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }
        try validateSFTPFileHandle(session: session, sftp: sftp, handle: handle)

        let deadline = Date().addingTimeInterval(SFTPFileTimeouts.chunkIO)
        // 强制 partial write 接缝（生产恒为 nil）：每次调用最多提交
        // cap 字节——服务器真实只写入该量，账面与真实完全一致。
        let byteCount = min(buffer.count, testSFTPFileWriteMaxBytesPerCall ?? .max)

        while true {
            try validateSFTPFileHandle(session: session, sftp: sftp, handle: handle)

            let rc = buffer.withUnsafeBytes { rawPointer -> Int in
                guard let base = rawPointer.baseAddress else {
                    return Int(LIBSSH2_ERROR_INVAL)
                }
                return libssh2_sftp_write(
                    handle.raw,
                    base.assumingMemoryBound(to: CChar.self),
                    byteCount
                )
            }

            if rc > 0 {
                sftpFileWriteCallCount += 1
                return rc
            }

            if rc == 0 {
                AppLogger.ssh.error("SFTP file write consumed zero bytes")
                throw SFTPError.protocolFailure(code: 0)
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await sftpWaitForReadiness(session: session, deadline: deadline)
                continue
            }

            throw sftpFailureError(session: session, sftp: sftp)
        }
    }

    /// 传输分块完成后的测试接缝触发（仅测试启用时付出异步调用代价）。
    /// 由 `SFTPTransferService` 在每个分块结束时调用。
    func runTestSFTPFileTransferChunkHookIfArmed() async {
        if testSFTPFileTransferChunkHookArmed {
            await testSFTPFileTransferChunkHook?()
        }
    }

    // MARK: - 关闭（EAGAIN 有界重试）

    /// 关闭文件句柄（幂等；认领式所有权）：
    /// 仅当本方从登记中真正摘除了句柄才执行关闭，绝不 double-close。
    ///
    /// 本方法**不检查任务取消**也不抛错——收尾路径（取消 / 失败清理）
    /// 必须能完整关闭句柄；EAGAIN 按方向等待（有界预算），超时记日志
    /// 返回，不触碰已拆除的指针（每次循环顶部重新校验身份）。
    /// 计数在认领成功后递减（无论关闭结果），与打开计数配对。
    ///
    /// 串行门（Phase 11 testA 整改）：`libssh2_sftp_close_handle` 同样触碰
    /// `LIBSSH2_SFTP` 子系统级共享状态，正常路径必须持门执行，绝不与任一
    /// 在途操作交错；拆除路径已在持门状态下直接调用内部 `closeFileHandle`，
    /// 不经本方法，认领幂等保证两路绝不重复关闭。
    func sftpCloseFileHandle(_ handle: SFTPFileHandle) async {
        guard claimFileHandleForClose(handle) else {
            return
        }
        defer { completeInFlightSFTPFileOperation() }

        guard let session, let sftp = sftpSubsystem else {
            return
        }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }

        await closeFileHandle(session: session, sftp: sftp, handle: handle.raw)
    }

    /// 认领关闭所有权：从登记中摘除成功（返回 true）的一方才可关闭句柄。
    /// 整个方法体无 await——actor 串行段内原子完成，两路不可能同时认领。
    private func claimFileHandleForClose(_ handle: SFTPFileHandle) -> Bool {
        guard let index = openSFTPFileHandles.firstIndex(of: handle.raw) else {
            return false
        }
        openSFTPFileHandles.remove(at: index)
        return true
    }

    /// `libssh2_sftp_close_handle` 的 EAGAIN 安全执行（拆除与正常路径共用；
    /// 调用方必须已持串行门——正常路径经 `sftpCloseFileHandle` 进门，
    /// 拆除路径持门直调）。
    ///
    /// 关闭计数按**成功关闭**递增（EAGAIN 重试不重复计数），
    /// 测试据此断言关闭数与打开数相等（无 double-close、无残留）。
    func closeFileHandle(
        session: OpaquePointer,
        sftp: OpaquePointer,
        handle: OpaquePointer
    ) async {
        // 竞态测试接缝（生产恒为 nil）：句柄已被认领、关闭尚未执行——
        // 关闭 EAGAIN 挂起窗口的确定性等价物。拆除排空屏障必须
        // 等这里的收尾关闭完成。
        await testSFTPBeforeFileHandleCloseHook?()

        let deadline = Date().addingTimeInterval(SFTPFileTimeouts.close)

        while true {
            guard session == self.session, sftp == sftpSubsystem else {
                return
            }

            let rc = libssh2_sftp_close_handle(handle)
            if rc == 0 {
                sftpFileHandleCloseCount += 1
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                do {
                    try await waitForLibssh2Readiness(session: session, deadline: deadline)
                } catch {
                    AppLogger.ssh.error("SFTP file close timed out")
                    return
                }
                continue
            }

            AppLogger.ssh.error("SFTP file close failed with libssh2 code \(rc)")
            return
        }
    }

    // MARK: - rename / unlink / mkdir（传输内部与用户操作共用）

    /// 重命名：`flags = 0` 使服务器按 `posix-rename@openssh.com`
    /// 语义执行——目标已存在时失败，绝不静默覆盖。
    /// 两个调用方：传输发布（临时文件 → 目标）与用户重命名。
    ///
    /// 失败映射：`SFTP_PROTOCOL` → FX 状态码（发布层据此区分
    /// "目标已存在"与其他协议错误）；传输层错误 → 连接丢失。
    func sftpRenameFile(from source: String, to destination: String) async throws {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }

        inFlightSFTPFileOperationCount += 1
        defer { completeInFlightSFTPFileOperation() }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }
        try validateSFTPOperation(session: session, sftp: sftp)

        let deadline = Date().addingTimeInterval(SFTPFileTimeouts.rename)

        while true {
            try validateSFTPOperation(session: session, sftp: sftp)

            let rc = source.withCString { sourcePointer in
                destination.withCString { destinationPointer in
                    libssh2_sftp_rename_ex(
                        sftp,
                        sourcePointer,
                        UInt32(source.utf8.count),
                        destinationPointer,
                        UInt32(destination.utf8.count),
                        0
                    )
                }
            }

            if rc == 0 {
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await sftpWaitForReadiness(session: session, deadline: deadline)
                continue
            }

            throw sftpFailureError(session: session, sftp: sftp)
        }
    }

    /// 删除文件：传输失败清理临时文件与用户删除共用。
    /// 仅能删除普通文件（协议层 `unlink` 语义；目录删除不在
    /// Phase 10 范围，避免递归风险，由业务层拦截）。
    func sftpUnlinkFile(_ path: String) async throws {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }

        inFlightSFTPFileOperationCount += 1
        defer { completeInFlightSFTPFileOperation() }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }
        try validateSFTPOperation(session: session, sftp: sftp)

        let deadline = Date().addingTimeInterval(SFTPFileTimeouts.unlink)

        while true {
            try validateSFTPOperation(session: session, sftp: sftp)

            let rc = path.withCString { pathPointer in
                libssh2_sftp_unlink_ex(sftp, pathPointer, UInt32(path.utf8.count))
            }

            if rc == 0 {
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await sftpWaitForReadiness(session: session, deadline: deadline)
                continue
            }

            throw sftpFailureError(session: session, sftp: sftp)
        }
    }

    /// 新建目录（用户操作）：权限 0755；目标已存在 / 上级目录不存在 /
    /// 权限不足均由 `sftpFailureError` 映射为业务错误（保持连接不变）。
    func sftpCreateDirectory(at path: String) async throws {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }

        inFlightSFTPFileOperationCount += 1
        defer { completeInFlightSFTPFileOperation() }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }
        try validateSFTPOperation(session: session, sftp: sftp)

        let deadline = Date().addingTimeInterval(SFTPFileTimeouts.mkdir)

        while true {
            try validateSFTPOperation(session: session, sftp: sftp)

            let rc = path.withCString { pathPointer in
                libssh2_sftp_mkdir_ex(sftp, pathPointer, UInt32(path.utf8.count), Self.mkdirMode)
            }

            if rc == 0 {
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await sftpWaitForReadiness(session: session, deadline: deadline)
                continue
            }

            throw sftpFailureError(session: session, sftp: sftp)
        }
    }

    // MARK: - 在途计数与排空屏障（拆除安全）

    /// 在途文件操作结束：递减计数；归零时唤醒拆除侧的排空等待。
    /// 同步执行，绝不跨 await。
    private func completeInFlightSFTPFileOperation() {
        inFlightSFTPFileOperationCount -= 1
        if inFlightSFTPFileOperationCount == 0,
           let continuation = sftpFileOperationDrainContinuation {
            sftpFileOperationDrainContinuation = nil
            continuation.resume()
        }
    }

    /// 拆除屏障：等待全部在途文件操作（连同其收尾关闭）完全结束。
    ///
    /// 断开标志置位后新操作在入口即被拒绝（`validateSFTPOperation`
    /// 与调用方的取消协作），计数只减不增；每个在途操作的等待都有
    /// 截止时间预算，排空必然在有界时间内完成，绝不悬挂。
    /// 供 `closeSFTPResourcesForTeardown()` 调用。
    func waitForInFlightSFTPFileOperationsToDrain() async {
        while inFlightSFTPFileOperationCount > 0 {
            await withCheckedContinuation { continuation in
                if inFlightSFTPFileOperationCount == 0 {
                    continuation.resume()
                } else {
                    sftpFileOperationDrainContinuation = continuation
                }
            }
        }
    }

    // MARK: - 私有：校验与映射

    /// 分块操作的额外校验：句柄必须仍在登记中（否则拆除已回收它）。
    private func validateSFTPFileHandle(
        session: OpaquePointer,
        sftp: OpaquePointer,
        handle: SFTPFileHandle
    ) throws {
        try validateSFTPOperation(session: session, sftp: sftp)
        guard openSFTPFileHandles.contains(handle.raw) else {
            throw SFTPError.connectionLost
        }
    }

    /// 由 `LIBSSH2_SFTP_ATTRIBUTES` 构造传输所需的最小属性快照。
    private func makeStatResult(_ attributes: LIBSSH2_SFTP_ATTRIBUTES) -> SFTPFileStatResult {
        let hasPermissions = attributes.flags & SFTPFileMode.attrPermissions != 0
        let fileTypeBits = hasPermissions
            ? attributes.permissions & SFTPFileMode.modeMask : 0

        return SFTPFileStatResult(
            sizeBytes: attributes.flags & SFTPFileMode.attrSize != 0
                ? Int64(clamping: attributes.filesize) : nil,
            isRegularFile: fileTypeBits == SFTPFileMode.ifReg,
            isDirectory: fileTypeBits == SFTPFileMode.ifDir,
            isSymlink: fileTypeBits == SFTPFileMode.ifLnk
        )
    }
}
