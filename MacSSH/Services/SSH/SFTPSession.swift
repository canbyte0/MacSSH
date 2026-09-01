import Darwin
import Foundation

/// Phase 9：只读 SFTP 能力，以 extension 形式挂在既有 `SSHConnection` actor 上。
///
/// 分层（任务书：SFTPBrowserView → SFTPService → SFTPSession → SSHConnection → libssh2）：
/// 本文件就是"SFTPSession"层——全部 `LIBSSH2_SFTP *` / `LIBSSH2_SFTP_HANDLE *`
/// 调用的唯一发生地，保持在 `SSHConnection` actor 串行边界内，
/// 与 Terminal Shell Channel 复用**同一条**已认证连接（不二次登录）。
///
/// 只读约束（任务书禁止任何写操作）：本文件只调用
/// `libssh2_sftp_init / realpath / opendir / readdir / closedir / shutdown`，
/// 绝不出现 write / unlink / mkdir / rmdir / rename / setstat。
///
/// EAGAIN 与协作调度：
/// - 每个 libssh2 调用返回 EAGAIN 时复用 `waitForLibssh2Readiness`
///   （block_directions → poll），等待期间 actor 挂起，Terminal 读写可穿插，
///   不形成 CPU busy-loop；
/// - 大目录列举每搬运 32 个条目主动让出一次 actor（`Task.yield`），
///   即使服务器持续同步返回数据也不饿死 Terminal。
///
/// 生命周期（P1 整改后）：
/// - 子系统初始化经在途任务去重（幂等）；初始化失败不断开健康连接；
/// - 打开的目录句柄登记在 `openSFTPDirectoryHandles`——登记是**关闭
///   所有权的认领令牌**：句柄只在真正摘除它的一方手里关闭；
/// - 整个列举（含收尾 closedir）计入在途计数，
///   `closeSFTPResourcesForTeardown()`（disconnect 专用）先**排空全部
///   在途列举**，再关闭无主残留句柄、最后 `libssh2_sftp_shutdown`
///   （顺序：目录句柄 → SFTP 子系统 → Channel → Session → socket），
///   杜绝 double-close / use-after-free；
/// - 所有跨 await 恢复点都重新校验 session / sftp / handle 身份，
///   绝不触碰已被拆除流程释放的指针。
///
/// 操作串行门（第二轮整改）：
/// - `LIBSSH2_SFTP` 的 `open_state` / `readdir_state` / request ID 是
///   子系统级共享状态：列举 / realpath / 拆除收尾经同一 FIFO 串行门执行，
///   任一时刻至多一个持门者——旧操作因 EAGAIN 挂起（actor 让出）期间，
///   新操作绝不进入同一状态机，直到旧操作完整收尾（含 closedir）。
extension SSHConnection {
    /// SFTP 各步骤独立超时预算（与计划书第 42 节 10 秒基线一致；
    /// 大目录列举总预算放宽，优雅关闭步骤收紧）。
    private enum SFTPTimeouts {
        static let subsystemInit: TimeInterval = 10
        static let realpath: TimeInterval = 10
        static let opendir: TimeInterval = 10
        static let listTotal: TimeInterval = 60
        static let closedir: TimeInterval = 3
        static let shutdown: TimeInterval = 3
    }

    /// `LIBSSH2_SFTP_ATTRIBUTES.flags` 位与文件类型位
    /// （C 宏在 Swift 中不可靠，显式定义协议常量）。
    private enum SFTPProtocol {
        static let attrSize: UInt = 0x1
        static let attrUidGid: UInt = 0x2
        static let attrPermissions: UInt = 0x4
        static let attrAcModTime: UInt = 0x8

        static let modeMask: UInt = 0o170000
        static let ifDir: UInt = 0o040000
        static let ifLnk: UInt = 0o120000
        static let ifReg: UInt = 0o100000
    }

    /// 单次 readdir 文件名缓冲起始值与上限（过小时按协议错误扩缓冲，
    /// 绝不静默截断文件名）。
    private static let readdirBufferInitial = 4096
    private static let readdirBufferMaximum = 262_144

    /// 协作调度：每搬运多少个条目让出一次 actor。
    private static let yieldEveryEntries = 32

    // MARK: - 观察点（测试 / 拆除）

    var hasSFTPSubsystem: Bool { sftpSubsystem != nil }

    var openSFTPDirectoryHandleCount: Int { openSFTPDirectoryHandles.count }

    // MARK: - 竞态测试接缝（生产恒为 nil）

    /// 安装 / 清除 readdir 窗口接缝（测试 N 专用）。
    func setTestSFTPAfterHandleOpenHook(_ hook: (@Sendable () async -> Void)?) {
        testSFTPAfterHandleOpenHook = hook
    }

    /// 安装 / 清除 closedir 窗口接缝（测试 O 专用）。
    func setTestSFTPBeforeHandleCloseHook(_ hook: (@Sendable () async -> Void)?) {
        testSFTPBeforeHandleCloseHook = hook
    }

    // MARK: - 子系统初始化

    /// 幂等初始化 SFTP 子系统（在已认证的 Session 上）。
    ///
    /// 并发安全：在途初始化登记为 `sftpInitTask`，并发调用等待同一结果；
    /// 断开标志置位后入口立即拒绝（初始化失败 / 断开都不影响既有 Terminal）。
    func openSFTPSubsystemIfNeeded() async throws {
        while true {
            try throwSFTPErrorIfDisconnectRequested()

            if let running = sftpInitTask {
                _ = try? await running.value
                continue
            }

            if sftpSubsystem != nil {
                return
            }

            guard let session else {
                throw SFTPError.connectionLost
            }

            let initTask = Task { [session] in
                try await performTrackedSFTPSubsystemInit(session: session)
            }
            sftpInitTask = initTask
            try await initTask.value
            return
        }
    }

    /// 初始化任务体：实际 `libssh2_sftp_init` 循环 + 结束时清空在途登记。
    private func performTrackedSFTPSubsystemInit(session: OpaquePointer) async throws {
        defer { sftpInitTask = nil }

        let deadline = Date().addingTimeInterval(SFTPTimeouts.subsystemInit)

        while true {
            try validateSFTPOperation(session: session, sftp: nil)

            if let sftp = libssh2_sftp_init(session) {
                sftpSubsystem = sftp
                sftpSubsystemInitCount += 1
                AppLogger.ssh.info("SFTP subsystem initialized")
                return
            }

            let lastError = libssh2_session_last_errno(session)
            guard lastError == LIBSSH2_ERROR_EAGAIN else {
                AppLogger.ssh.error("SFTP subsystem init failed with libssh2 code \(lastError)")
                throw SFTPError.subsystemInitFailed
            }

            try await sftpWaitForReadiness(session: session, deadline: deadline)
        }
    }

    /// 解析远端路径为规范绝对路径（初始目录使用 `realpath(".")`，
    /// 绝不硬编码 `/` 或 `~`）。
    ///
    /// 缓冲按 PATH_MAX（4096）准备；服务器路径语义下这已是上限容量。
    /// 与列举相同持串行门执行——`realpath` 同样触碰 `LIBSSH2_SFTP`
    /// 子系统级共享状态（第二轮整改）。
    func sftpRealpath(_ path: String) async throws -> String {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }

        let deadline = Date().addingTimeInterval(SFTPTimeouts.realpath)
        var buffer = [CChar](repeating: 0, count: 4096)

        while true {
            try validateSFTPOperation(session: session, sftp: sftp)

            // 函数式宏 `libssh2_sftp_realpath` 在 Swift 中不可用；
            // 它背后的真实函数是 `libssh2_sftp_symlink_ex` + REALPATH 模式。
            let rc = path.withCString { pathPointer in
                buffer.withUnsafeMutableBufferPointer { bufferPointer -> Int32 in
                    guard let base = bufferPointer.baseAddress else {
                        return LIBSSH2_ERROR_INVAL
                    }
                    return libssh2_sftp_symlink_ex(
                        sftp,
                        pathPointer,
                        UInt32(path.utf8.count),
                        base,
                        UInt32(bufferPointer.count),
                        LIBSSH2_SFTP_REALPATH
                    )
                }
            }

            if rc >= 0 {
                let utf8Bytes = buffer.prefix(Int(rc)).map(UInt8.init)
                return String(decoding: utf8Bytes, as: UTF8.self)
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await sftpWaitForReadiness(session: session, deadline: deadline)
                continue
            }

            throw sftpFailureError(session: session, sftp: sftp)
        }
    }

    // MARK: - 目录列举（OPENDIR → READDIR → CLOSEDIR）

    /// 列举远端目录的全部条目（只读）。
    ///
    /// 所有权屏障（P1 整改）：
    /// - 整个列举（含收尾 closedir）登记进 `inFlightSFTPListingCount`；
    ///   拆除侧必须先等计数归零才能关闭剩余句柄 / `libssh2_sftp_shutdown`，
    ///   杜绝“closedir 仍在 EAGAIN 挂起时子系统被释放”的 use-after-free；
    /// - 句柄只在**真正从登记中摘除它的一方**手里关闭（认领互斥，
    ///   摘除段无跨 await）——本方未认领到则绝不触碰该句柄，
    ///   绝不 double-close；
    /// - 断开已请求时入口立即拒绝。
    ///
    /// 串行门（第二轮整改）：
    /// - 登记先于进门——排队中的列举同样被拆除排空屏障覆盖；
    /// - 持门执行完整操作生命周期（opendir → readdir → closedir），
    ///   旧列举即便因 EAGAIN 挂起，新列举也绝不进入同一
    ///   `LIBSSH2_SFTP` 共享状态机，直到旧列举完全收尾；
    /// - 排队结束后重新校验身份——等待期间连接 / 子系统可能已被拆除。
    ///
    /// 条目元数据直接来自 `LIBSSH2_SFTP_ATTRIBUTES`（按 flags 取值），
    /// 不做 N+1 stat，不解析 longentry。
    /// 文件名按 UTF-8 解码（非法字节替换，不崩溃）；`.` / `..` 过滤。
    func sftpListDirectory(_ path: String) async throws -> [SFTPFileEntry] {
        guard let session, let sftp = sftpSubsystem else {
            throw SFTPError.connectionLost
        }
        try validateSFTPOperation(session: session, sftp: sftp)

        // 登记先于进门：在途计数必须覆盖排队等待者，
        // 拆除排空才不会遗漏尚未进入 libssh2 的请求。
        inFlightSFTPListingCount += 1
        defer { completeInFlightSFTPListing() }

        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }

        // 排队可能跨越拆除：恢复后重新校验取消 / 断开 / 子系统身份。
        try validateSFTPOperation(session: session, sftp: sftp)

        let deadline = Date().addingTimeInterval(SFTPTimeouts.listTotal)
        let handle = try await openDirectoryHandle(
            session: session,
            sftp: sftp,
            path: path,
            deadline: deadline
        )
        openSFTPDirectoryHandles.append(handle)

        var listFailure: Error?
        let entries: [SFTPFileEntry]
        do {
            entries = try await readDirectoryEntries(
                session: session,
                sftp: sftp,
                handle: handle,
                deadline: deadline
            )
        } catch {
            entries = []
            listFailure = error
        }

        // 认领关闭所有权：仅当本方从登记中真正摘除了句柄才关闭。
        // 摘除与判断在同一 actor 串行段完成，无跨 await，认领互斥。
        if claimDirectoryHandleForClose(handle) {
            await closeDirectoryHandle(session: session, sftp: sftp, handle: handle)
        }

        if let listFailure {
            throw listFailure
        }
        return entries
    }

    /// 认领关闭所有权：从登记中摘除成功（返回 true）的一方才可关闭句柄。
    /// 整个方法体无 await——actor 串行段内原子完成，两路不可能同时认领。
    private func claimDirectoryHandleForClose(_ handle: OpaquePointer) -> Bool {
        guard let index = openSFTPDirectoryHandles.firstIndex(of: handle) else {
            return false
        }
        openSFTPDirectoryHandles.remove(at: index)
        return true
    }

    /// 在途列举结束（含收尾 closedir）：递减计数；归零时唤醒拆除侧
    /// 的排空等待。同步执行，绝不跨 await。
    private func completeInFlightSFTPListing() {
        inFlightSFTPListingCount -= 1
        if inFlightSFTPListingCount == 0,
           let continuation = sftpListingDrainContinuation {
            sftpListingDrainContinuation = nil
            continuation.resume()
        }
    }

    /// 拆除屏障：等待全部在途列举（连同其收尾 closedir）完全结束。
    ///
    /// 断开标志置位后新列举在入口即被拒绝，计数只减不增；每个在途列举
    /// 的等待都有截止时间预算（列举 60s / closedir 3s），排空必然在
    /// 有界时间内完成，绝不悬挂。
    private func waitForInFlightSFTPListingsToDrain() async {
        while inFlightSFTPListingCount > 0 {
            await withCheckedContinuation { continuation in
                if inFlightSFTPListingCount == 0 {
                    continuation.resume()
                } else {
                    sftpListingDrainContinuation = continuation
                }
            }
        }
    }

    // MARK: - 操作串行门（第二轮整改）

    /// 获取 SFTP 操作串行门（FIFO）。
    ///
    /// `LIBSSH2_SFTP` 的 `open_state` / `readdir_state` / request ID 是
    /// 子系统级共享状态：旧操作因 EAGAIN 挂起（actor 让出）期间，新操作
    /// 若直接进入同一子系统，两次 `opendir`/`readdir` 会交错，后一请求
    /// 可能接走前一请求的响应。串行门保证任一时刻至多一个持门者
    /// 执行 SFTP 操作——新操作必须等旧操作**完整收尾（含 closedir）**。
    ///
    /// 无 await 段内完成占用判定与排队登记；拿不到门时挂起等待移交。
    func acquireSFTPOperationGate() async {
        guard sftpOperationGateActive else {
            sftpOperationGateActive = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sftpOperationGateWaiters.append(continuation)
        }
    }

    /// 释放串行门：有等待者时把所有权直接移交给队首（占用标志保持，
    /// 绝不先置空闲再争抢）；无等待者时置空闲。整个方法体无 await，
    /// 在 actor 串行段内原子完成。
    func releaseSFTPOperationGate() {
        if let next = sftpOperationGateWaiters.first {
            sftpOperationGateWaiters.removeFirst()
            next.resume()
        } else {
            sftpOperationGateActive = false
        }
    }

    /// OPENDIR；EAGAIN 按阻塞方向等待，协议错误映射为业务错误
    /// （不存在 / 权限不足等）。
    private func openDirectoryHandle(
        session: OpaquePointer,
        sftp: OpaquePointer,
        path: String,
        deadline: Date
    ) async throws -> OpaquePointer {
        while true {
            try validateSFTPOperation(session: session, sftp: sftp)

            // 函数式宏 `libssh2_sftp_opendir` 在 Swift 中不可用；
            // 它背后的真实函数是 `libssh2_sftp_open_ex` + OPENDIR 类型。
            let handle = path.withCString { pathPointer in
                libssh2_sftp_open_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    0,
                    0,
                    LIBSSH2_SFTP_OPENDIR
                )
            }
            if let handle {
                // 测试仪表：与关闭计数配对，竞态测试断言两者相等
                // （任何 double-close 都会使关闭数超出打开数）。
                sftpDirectoryHandleOpenCount += 1
                return handle
            }

            let lastError = libssh2_session_last_errno(session)
            guard lastError == LIBSSH2_ERROR_EAGAIN else {
                throw sftpFailureError(session: session, sftp: sftp)
            }

            try await sftpWaitForReadiness(session: session, deadline: deadline)
        }
    }

    /// READDIR 循环；每 32 个条目让出 actor 一次（协作调度，不饿死 Terminal）。
    private func readDirectoryEntries(
        session: OpaquePointer,
        sftp: OpaquePointer,
        handle: OpaquePointer,
        deadline: Date
    ) async throws -> [SFTPFileEntry] {
        var entries: [SFTPFileEntry] = []
        var nameBuffer = [CChar](repeating: 0, count: Self.readdirBufferInitial)
        var entriesSinceYield = 0

        // 竞态测试接缝（生产恒为 nil）：句柄已打开并登记、readdir 尚未开始——
        // 正是拆除可交错的 EAGAIN 挂起窗口的确定性等价物。
        await testSFTPAfterHandleOpenHook?()

        while true {
            try validateDirectoryListing(session: session, sftp: sftp, handle: handle)

            var attributes = LIBSSH2_SFTP_ATTRIBUTES(
                flags: 0,
                filesize: 0,
                uid: 0,
                gid: 0,
                permissions: 0,
                atime: 0,
                mtime: 0
            )

            // 函数式宏 `libssh2_sftp_readdir` 在 Swift 中不可用，调用 _ex
            // （longentry 传 nil：绝不依赖 / 解析长格式文本）。
            let rc = nameBuffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else {
                    return LIBSSH2_ERROR_INVAL
                }
                return libssh2_sftp_readdir_ex(
                    handle,
                    base,
                    pointer.count,
                    nil,
                    0,
                    &attributes
                )
            }

            if rc > 0 {
                let nameBytes = nameBuffer[0..<Int(rc)].map(UInt8.init)
                let name = String(decoding: nameBytes, as: UTF8.self)
                if name != "." && name != ".." {
                    entries.append(makeEntry(name: name, attributes: attributes))

                    // 协作调度：让出 actor，Terminal 读写得以穿插；
                    // 恢复后循环顶部的身份校验保证句柄仍然有效。
                    entriesSinceYield += 1
                    if entriesSinceYield >= Self.yieldEveryEntries {
                        entriesSinceYield = 0
                        await Task.yield()
                    }
                }
                continue
            }

            if rc == 0 {
                return entries
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await sftpWaitForReadiness(session: session, deadline: deadline)
                continue
            }

            if rc == LIBSSH2_ERROR_BUFFER_TOO_SMALL {
                // 单个文件名超出当前缓冲：扩缓冲重试，绝不静默截断。
                guard nameBuffer.count < Self.readdirBufferMaximum else {
                    AppLogger.ssh.error("SFTP filename exceeds maximum buffer size")
                    throw SFTPError.protocolFailure(code: 0)
                }
                nameBuffer = [CChar](repeating: 0, count: nameBuffer.count * 2)
                continue
            }

            throw sftpFailureError(session: session, sftp: sftp)
        }
    }

    /// CLOSEDIR（EAGAIN 重试，有界预算）；身份校验失败说明拆除已回收
    /// 该句柄，直接返回，绝不触碰已释放指针。
    ///
    /// 关闭计数按**成功关闭**递增（EAGAIN 重试不重复计数），
    /// 竞态测试据此断言关闭数与打开数相等（无 double-close、无残留）。
    private func closeDirectoryHandle(
        session: OpaquePointer,
        sftp: OpaquePointer,
        handle: OpaquePointer
    ) async {
        // 竞态测试接缝（生产恒为 nil）：句柄已被认领、closedir 尚未执行——
        // closedir EAGAIN 挂起窗口的确定性等价物。拆除排空屏障必须
        // 等这里的收尾关闭完成，否则该接缝会让拆除在排空等待中停住。
        await testSFTPBeforeHandleCloseHook?()

        let deadline = Date().addingTimeInterval(SFTPTimeouts.closedir)

        while true {
            guard session == self.session, sftp == sftpSubsystem else {
                return
            }

            // 函数式宏 `libssh2_sftp_closedir` 在 Swift 中不可用；
            // 它背后的真实函数是 `libssh2_sftp_close_handle`。
            let rc = libssh2_sftp_close_handle(handle)
            if rc == 0 {
                sftpDirectoryHandleCloseCount += 1
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                do {
                    try await waitForLibssh2Readiness(session: session, deadline: deadline)
                } catch {
                    AppLogger.ssh.error("SFTP directory close timed out")
                    return
                }
                continue
            }

            AppLogger.ssh.error("SFTP directory close failed with libssh2 code \(rc)")
            return
        }
    }

    /// 由 `LIBSSH2_SFTP_ATTRIBUTES` 构造业务模型；按 `flags` 决定字段存在性，
    /// 缺失字段保持 nil（UI 显示 "—"），绝不猜测默认值。
    private func makeEntry(
        name: String,
        attributes: LIBSSH2_SFTP_ATTRIBUTES
    ) -> SFTPFileEntry {
        let hasPermissions = attributes.flags & SFTPProtocol.attrPermissions != 0

        let kind: SFTPFileEntry.Kind
        if hasPermissions {
            switch attributes.permissions & SFTPProtocol.modeMask {
            case SFTPProtocol.ifDir:
                kind = .directory
            case SFTPProtocol.ifLnk:
                kind = .symlink
            case SFTPProtocol.ifReg:
                kind = .regularFile
            default:
                kind = .other
            }
        } else {
            kind = .other
        }

        return SFTPFileEntry(
            name: name,
            kind: kind,
            sizeBytes: attributes.flags & SFTPProtocol.attrSize != 0
                ? attributes.filesize : nil,
            modifiedAt: attributes.flags & SFTPProtocol.attrAcModTime != 0
                ? Date(timeIntervalSince1970: TimeInterval(attributes.mtime)) : nil,
            permissions: hasPermissions
                ? UInt32(clamping: attributes.permissions) : nil,
            ownerUID: attributes.flags & SFTPProtocol.attrUidGid != 0
                ? UInt32(clamping: attributes.uid) : nil,
            ownerGID: attributes.flags & SFTPProtocol.attrUidGid != 0
                ? UInt32(clamping: attributes.gid) : nil
        )
    }

    // MARK: - 拆除（断开专用）

    /// 断开专用：关闭**全部** SFTP 资源（teardown 语义，任务书顺序
    /// 目录句柄 → SFTP 子系统；之后由调用方继续 Channel → Session → socket）。
    ///
    /// 拆除屏障（P1 整改）：
    /// - 先等在途初始化任务落定（断开标志已置位，它会在下一个校验点退出）；
    /// - **再等全部在途列举连同其收尾 closedir 完全结束**（排空屏障）。
    ///   断开标志置位后新列举在入口即被拒绝，在途列举的每个等待都有
    ///   截止时间预算，排空必然在有界时间内完成；
    /// - 排空后**再取得串行门**（第二轮整改）：`realpath` 不计入在途
    ///   列举，只有串行门能扣住它；断开标志置位后它在下一个校验点
    ///   退出并释放门，等待有界；
    /// - 持门期间登记中仍存在的是**无主残留句柄**（列举侧已在收尾时
    ///   认领摘除的不会出现在这里），由本路径逐个关闭——不再与任何
    ///   在途列举竞争同一指针；
    /// - 最后 `libssh2_sftp_shutdown`（EAGAIN 按方向等待，不 busy-loop）。
    ///   此刻绝无任何 closedir 仍在途，杜绝子系统的 use-after-free。
    /// 拆除完成后 `sftpSubsystem == nil` 且登记为空，幂等可重入。
    func closeSFTPResourcesForTeardown() async {
        if let initTask = sftpInitTask {
            _ = try? await initTask.value
        }

        // 排空屏障：在途列举（含收尾 closedir）全部结束之前，
        // 绝不关闭任何句柄、绝不执行 shutdown。
        await waitForInFlightSFTPListingsToDrain()

        // Phase 10 排空屏障：在途文件传输分块（连同其收尾关闭）全部结束。
        // 正常路径由 TransferManager 先行取消并等待；这里是拆除侧最后防线。
        await waitForInFlightSFTPFileOperationsToDrain()

        // 串行门：持门关闭残留句柄与 shutdown，绝不与任何仍在
        // `LIBSSH2_SFTP` 共享状态机内的操作（如 realpath）交错。
        await acquireSFTPOperationGate()
        defer { releaseSFTPOperationGate() }

        while let handle = openSFTPDirectoryHandles.popLast() {
            guard let session, let sftp = sftpSubsystem else {
                return
            }
            await closeDirectoryHandle(session: session, sftp: sftp, handle: handle)
        }

        // Phase 10：排空后登记中仍存在的是无主残留文件句柄（传输侧已在
        // 收尾时认领摘除的不会出现在这里），由本路径逐个关闭。
        while let handle = openSFTPFileHandles.popLast() {
            guard let session, let sftp = sftpSubsystem else {
                return
            }
            await closeFileHandle(session: session, sftp: sftp, handle: handle)
        }

        guard let session, let sftp = sftpSubsystem else {
            return
        }
        // 先从共享状态摘除指针（无 await 段），再释放——与 Session 释放
        // 相同的 double-free 防线。
        sftpSubsystem = nil
        await shutdownSFTPSubsystem(session: session, sftp: sftp)
        AppLogger.ssh.info("SFTP resources closed for teardown")
    }

    /// `libssh2_sftp_shutdown` 的 EAGAIN 安全包装（有界预算）。
    private func shutdownSFTPSubsystem(session: OpaquePointer, sftp: OpaquePointer) async {
        let deadline = Date().addingTimeInterval(SFTPTimeouts.shutdown)

        while true {
            guard session == self.session else {
                return
            }

            let rc = libssh2_sftp_shutdown(sftp)
            if rc == 0 {
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                do {
                    try await waitForLibssh2Readiness(session: session, deadline: deadline)
                } catch {
                    AppLogger.ssh.error("SFTP subsystem shutdown timed out")
                    return
                }
                continue
            }

            AppLogger.ssh.error("SFTP subsystem shutdown failed with libssh2 code \(rc)")
            return
        }
    }

    // MARK: - 私有：校验与错误映射

    /// 跨 await 恢复后的身份校验：取消标志 / session / sftp 子系统
    /// 任一失效即按连接丢失退出，杜绝 use-after-free。
    ///
    /// 任务取消检查也在这里统一发生：SFTPService 的在途请求被新请求
    /// 取代（或拆除屏障取消）时，操作在下一个校验点即退出；
    /// 拆除路径自身的任务从不被取消，本检查对其恒为无操作。
    ///
    /// `internal` 供同模块的 `SFTPFileOperations.swift` 扩展（Phase 10
    /// 文件传输）复用；actor 隔离不变。
    func validateSFTPOperation(session: OpaquePointer, sftp: OpaquePointer?) throws {
        try Task.checkCancellation()
        try throwSFTPErrorIfDisconnectRequested()
        guard session == self.session else {
            throw SFTPError.connectionLost
        }
        if let sftp {
            guard sftp == sftpSubsystem else {
                throw SFTPError.connectionLost
            }
        }
    }

    /// 断开已请求：SFTP 层统一映射为 `connectionLost`
    /// （不向业务层泄漏 SSHError 细节）。
    /// `disconnectRequested` 是 SSHConnection.swift 的文件级私有状态，
    /// 因此经由 internal 的 `throwIfDisconnectRequested()` 判定。
    private func throwSFTPErrorIfDisconnectRequested() throws {
        do {
            try throwIfDisconnectRequested()
        } catch {
            throw SFTPError.connectionLost
        }
    }

    /// 列举中的额外校验：句柄必须仍在登记中（否则拆除已关闭它）。
    private func validateDirectoryListing(
        session: OpaquePointer,
        sftp: OpaquePointer,
        handle: OpaquePointer
    ) throws {
        try validateSFTPOperation(session: session, sftp: sftp)
        guard openSFTPDirectoryHandles.contains(handle) else {
            throw SFTPError.connectionLost
        }
    }

    /// readiness 等待的统一映射：超时 / 取消 → 业务错误（不泄漏 SSHError 细节）。
    /// `internal` 供同模块的 `SFTPFileOperations.swift` 扩展复用。
    func sftpWaitForReadiness(
        session: OpaquePointer,
        deadline: Date
    ) async throws {
        do {
            try await waitForLibssh2Readiness(session: session, deadline: deadline)
        } catch is CancellationError {
            throw SFTPError.operationCancelled
        } catch {
            throw SFTPError.connectionLost
        }
    }

    /// 失败码映射：`LIBSSH2_ERROR_SFTP_PROTOCOL` 时读取
    /// `libssh2_sftp_last_error()`（紧随失败调用，中间无其他 sftp 调用），
    /// 其余按传输层错误 → 连接丢失。
    /// `internal` 供同模块的 `SFTPFileOperations.swift` 扩展复用。
    func sftpFailureError(session: OpaquePointer, sftp: OpaquePointer) -> SFTPError {
        let lastError = libssh2_session_last_errno(session)
        if lastError == LIBSSH2_ERROR_SFTP_PROTOCOL {
            let statusCode = UInt32(libssh2_sftp_last_error(sftp))
            return SFTPError(sftpStatusCode: statusCode)
        }
        // 传输层错误：附带 libssh2 内部描述（含 socket 层失败细节），
        // 偶发断连（如 -8 SOCKET_RECV）取证必需。
        var reasonPointer: UnsafeMutablePointer<CChar>?
        var reasonLength: Int32 = 0
        _ = libssh2_session_last_error(session, &reasonPointer, &reasonLength, 0)
        let reason = reasonPointer.map { String(cString: $0) } ?? "—"
        // recv 失败后同线程内立即采集的 errno：区分对端 FIN（干净关闭，
        // errno 多为陈旧值）、对端 RST（ECONNRESET）、本端 fd 异常等。
        let socketErrno = errno
        AppLogger.ssh.error(
            "SFTP transport failed with libssh2 code \(lastError) (\(reason), errno \(socketErrno)/\(String(cString: strerror(socketErrno))))"
        )
        return .connectionLost
    }
}
