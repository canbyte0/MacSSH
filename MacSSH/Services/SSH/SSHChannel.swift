import Darwin
import Foundation

/// Phase 7：Interactive Shell Channel 能力，以 extension 形式挂在既有
/// `SSHConnection` actor 上。
///
/// 并发边界（与 Phase 5 建立的规则一致）：
/// - `LIBSSH2_SESSION *` 与 `LIBSSH2_CHANNEL *` 的**全部** libssh2 调用都发生在
///   `SSHConnection` actor 隔离内；本扩展的所有方法都是 actor 方法，
///   Swift actor 保证同步段串行，绝不会出现 read/write/resize 并发进入
///   同一个 session/channel handle。
/// - EAGAIN 等待复用现有 `waitForLibssh2Readiness`（block_directions → poll），
///   等待期间 actor 挂起（Swift actor 可重入），**已建立** Channel 上的
///   读 / 写 / Resize 可安全穿插，不存在 CPU busy-loop。打开窗口期
///   （PTY / Shell 请求在途）例外：resize / write 必须先等待在途打开
///   尘埃落定，否则同一 Channel 上的穿插调用会触发
///   LIBSSH2_ERROR_BAD_USE 并破坏打开序列。
/// - 读取循环在 poll 上以有界时长阻塞 GCD 线程，空闲时近似零 CPU。
///
/// 生命周期（任务书第 6 节职责划分）：
/// - `SSHConnection`：TCP / Handshake / KnownHost / Authentication / Session 生命周期。
/// - 本扩展 + `RemoteTerminalService`：Channel / PTY / Shell / Input / Output / Resize。
extension SSHConnection {
    /// Channel / PTY / Shell 各阶段的独立超时预算（与计划书第 42 节 10 秒一致）。
    private enum ChannelTimeouts {
        static let channelOpen: TimeInterval = 10
        static let ptyRequest: TimeInterval = 10
        static let shellRequest: TimeInterval = 10
        static let resize: TimeInterval = 10
        /// 大段 paste 的写预算放宽，避免慢网络下误报失败。
        static let write: TimeInterval = 30
        /// 空闲读取等待：poll 阻塞在 GCD 线程，超时后回到读取循环再试。
        static let idleReadPoll: TimeInterval = 1.0
        /// Channel 优雅关闭各步骤预算。
        static let gracefulClose: TimeInterval = 3
    }

    /// 读取缓冲上限：单次 read 最多搬运的字节数（libssh2 默认包 32768）。
    private static let readBufferSize = 32_768

    // MARK: - 生命周期

    /// 是否已存在打开的 Shell Channel。
    var hasOpenShellChannel: Bool {
        shellChannel != nil
    }

    /// 校验跨 await 捕获的 session / channel 指针仍然有效。
    ///
    /// 所有 Channel 操作都可能在 poll 等待中挂起（actor 可重入）；期间
    /// `disconnect()` 或 `closeShellChannel()` 可能已经释放底层指针。
    /// 恢复后必须先确认指针身份一致才允许继续触碰 libssh2，杜绝 use-after-free：
    /// - 取消标志：establish 中被请求断开时立即退出；
    /// - session 身份：disconnect 已释放 session 时按连接丢失退出；
    /// - channel 身份：Channel 已被关闭 / 替换时按 Channel 关闭退出。
    private func validateChannelOperation(
        session: OpaquePointer,
        channel: OpaquePointer?
    ) throws {
        try throwIfDisconnectRequested()
        guard session == self.session else {
            throw RemoteTerminalError.connectionLost
        }
        if let channel {
            guard channel == shellChannel else {
                throw RemoteTerminalError.channelClosed
            }
        }
    }

    /// 在**已认证**的 Session 上打开 Interactive Shell Channel：
    /// open session channel → request PTY（真实初始尺寸）→ request shell。
    ///
    /// 任何一步失败都会释放 Channel（不留半开 Channel），并抛出对应业务错误；
    /// 不触碰 Phase 6 已通过的 KnownHost / Authentication 流程。
    ///
    /// 并发安全（打开步骤跨 await，actor 可重入）：
    /// - 在途打开去重：并发调用先等待在途打开的结果再决策
    ///   （成功幂等复用 / 失败重新尝试）。
    /// - 在途关闭串行（第二轮验收整改）：打开前必须等待在途的
    ///   `shellChannelCloseTask` 完成——否则 close → reopen → disconnect
    ///   交错时，新 Channel 可能在旧清理进行中打开，随后随 Session 释放
    ///   成为悬空指针。
    /// - 断开拒绝：`disconnect()` 从一开始就置位断开标志，本方法入口
    ///   校验立即失败，不会在断开流程中再打开新 Channel。
    func openInteractiveShell(columns: Int, rows: Int) async throws {
        // 等待在途打开 / 在途关闭全部尘埃落定后再决策（循环防止等待
        // 期间又出现的任务被漏掉；任务登记由任务体自身清空，
        // 不会残留已完成任务导致空转）。
        while shellChannelOpenTask != nil || shellChannelCloseTask != nil {
            if let running = shellChannelOpenTask {
                try? await running.value
                continue
            }
            if let closing = shellChannelCloseTask {
                await closing.value
                continue
            }
        }

        guard let session else {
            throw RemoteTerminalError.connectionLost
        }
        guard shellChannel == nil else {
            // 已有 Channel：幂等返回，不重复打开。
            return
        }
        try throwIfDisconnectRequested()

        let openTask = Task {
            try await performTrackedInteractiveShellOpen(
                session: session,
                columns: columns,
                rows: rows
            )
        }
        shellChannelOpenTask = openTask
        try await openTask.value
    }

    /// 打开任务体：实际打开步骤 + 任务结束时清空在途登记。
    ///
    /// 登记清空放在任务体内（actor 隔离的 defer，成功 / 失败路径都执行），
    /// 保证"任务完成后槽位必为空"——等待方恢复时不会看到已完成任务的
    /// 残留登记，`disconnect()` 的关闭循环也因此不会空转。
    private func performTrackedInteractiveShellOpen(
        session: OpaquePointer,
        columns: Int,
        rows: Int
    ) async throws {
        defer { shellChannelOpenTask = nil }
        try await performInteractiveShellOpen(
            session: session,
            columns: columns,
            rows: rows
        )
    }

    /// `openInteractiveShell()` 的实际打开步骤；在独立 Task 中执行，
    /// 供并发调用方等待与去重。
    private func performInteractiveShellOpen(
        session: OpaquePointer,
        columns: Int,
        rows: Int
    ) async throws {
        // 1. open session channel（函数式宏在 Swift 中必须调用 _ex 底层函数）。
        let channel = try await openSessionChannel(session: session, budget: ChannelTimeouts.channelOpen)
        shellChannel = channel
        do {
            // 2. request PTY：xterm-256color + SwiftTerm 真实初始尺寸（非固定 80×24）。
            try await requestPTY(
                session: session,
                channel: channel,
                term: "xterm-256color",
                columns: max(1, columns),
                rows: max(1, rows),
                budget: ChannelTimeouts.ptyRequest
            )

            // 3. request shell。
            try await requestShell(
                session: session,
                channel: channel,
                budget: ChannelTimeouts.shellRequest
            )
        } catch {
            // 失败清理：绝不留下半开 Channel。
            await closeShellChannel()
            throw error
        }

        AppLogger.terminal.info("Remote shell channel opened")
    }

    /// 读取 Channel 输出（非阻塞 + EAGAIN poll）。
    ///
    /// 返回 `(bytes, isEOF)`：
    /// - `bytes` 非空：本次读到的原始字节（UTF-8 / ANSI / 二进制 control sequence
    ///   均按原始 byte stream 传递，不做 String 重编码）。
    /// - `isEOF == true`：远端已发送 EOF（例如用户执行 `exit`）。
    /// - 空闲（无数据且未 EOF）：在 poll 上等待有界时长后返回空数组，
    ///   读取循环按需再次调用；不 busy-loop。
    func readChannelOutput() async throws -> (bytes: [UInt8], isEOF: Bool) {
        guard let session else {
            throw RemoteTerminalError.connectionLost
        }
        guard let channel = shellChannel else {
            throw RemoteTerminalError.channelClosed
        }

        var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)

        while true {
            try validateChannelOperation(session: session, channel: channel)

            let bytesRead = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else {
                    return 0
                }
                return base.withMemoryRebound(to: CChar.self, capacity: pointer.count) { charPointer in
                    libssh2_channel_read_ex(channel, 0, charPointer, pointer.count)
                }
            }

            if bytesRead > 0 {
                return (Array(buffer[0..<bytesRead]), false)
            }

            if bytesRead == 0 {
                // 0 = 无更多数据可读；区分 EOF 与"暂时没有数据"。
                if libssh2_channel_eof(channel) == 1 {
                    return ([], true)
                }
                // 无数据且未 EOF：与 EAGAIN 路径一致的有界等待后返回空。
                // poll 等待在 socket 可读时立即唤醒，空闲时长只决定空转频率。
                try await idleWait(session: session, seconds: ChannelTimeouts.idleReadPoll)
                return ([], false)
            }

            if bytesRead == LIBSSH2_ERROR_EAGAIN {
                // EOF 可能与 EAGAIN 同时出现（远端 exit 后传输层暂无新数据）：
                // 先检查 EOF，避免在已退出的 Channel 上无意义地继续等待。
                if libssh2_channel_eof(channel) == 1 {
                    return ([], true)
                }
                // Channel 缓冲无数据且传输层暂不可读：按 libssh2 报告的方向
                // poll socket（最多 idleReadPoll 秒）；等待期间 actor 挂起，
                // 写入 / Resize 可安全穿插。空闲超时不是错误，返回空数据，
                // 由调用方（读取循环）按需再次调用；绝不能在此内部 continue
                // 轮询——否则空闲 Channel 上本方法永不返回（挂起调用方）。
                try await idleWait(session: session, seconds: ChannelTimeouts.idleReadPoll)
                return ([], false)
            }

            if bytesRead == LIBSSH2_ERROR_CHANNEL_CLOSED {
                return ([], true)
            }

            // 其他传输错误：记录诊断码（不含终端内容），抛业务错误。
            let lastError = libssh2_session_last_errno(session)
            AppLogger.terminal.error("Channel read failed with libssh2 code \(lastError)")
            throw RemoteTerminalError.channelReadFailed
        }
    }

    /// 空闲等待：复用 block_directions poll / 退避机制，超时静默返回（非错误）。
    private func idleWait(session: OpaquePointer, seconds: TimeInterval) async throws {
        do {
            try await waitForLibssh2Readiness(
                session: session,
                deadline: Date().addingTimeInterval(seconds)
            )
        } catch let error as SSHError where error == .connectionTimeout {
            // 空闲超时：正常返回，由调用方决定后续动作。
        }
    }

    /// 写入用户输入（键盘 / paste）到 Channel。
    ///
    /// 处理 partial write：`libssh2_channel_write_ex` 可能只写一部分或返回 EAGAIN，
    /// 以 offset + remaining 循环直到全部写完、出错或超预算；不假设一次写完。
    func writeChannelInput(_ data: ArraySlice<UInt8>) async throws {
        // 打开窗口期内 PTY / Shell 请求尚未完成：提前穿插的写入与 resize
        // 同因——会在同一 Channel 上触发 LIBSSH2_ERROR_BAD_USE 并破坏打开
        // 序列；等待在途打开 / 关闭尘埃落定后再写入（字节不丢，仅顺延）。
        while shellChannelOpenTask != nil || shellChannelCloseTask != nil {
            if let opening = shellChannelOpenTask {
                try? await opening.value
                continue
            }
            if let closing = shellChannelCloseTask {
                await closing.value
                continue
            }
        }

        guard let session else {
            throw RemoteTerminalError.connectionLost
        }
        guard let channel = shellChannel else {
            throw RemoteTerminalError.channelClosed
        }
        guard !data.isEmpty else {
            return
        }

        let bytes = Array(data)
        let deadline = Date().addingTimeInterval(ChannelTimeouts.write)
        var offset = 0

        while offset < bytes.count {
            try validateChannelOperation(session: session, channel: channel)

            let written = bytes.withUnsafeBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress?.advanced(by: offset) else {
                    return 0
                }
                return base.withMemoryRebound(
                    to: CChar.self,
                    capacity: bytes.count - offset
                ) { charPointer in
                    libssh2_channel_write_ex(channel, 0, charPointer, bytes.count - offset)
                }
            }

            if written > 0 {
                offset += written
                continue
            }

            if written == LIBSSH2_ERROR_EAGAIN {
                try await waitForLibssh2Readiness(session: session, deadline: deadline)
                continue
            }

            if written == LIBSSH2_ERROR_CHANNEL_CLOSED {
                throw RemoteTerminalError.channelClosed
            }

            let lastError = libssh2_session_last_errno(session)
            AppLogger.terminal.error("Channel write failed with libssh2 code \(lastError)")
            throw RemoteTerminalError.channelWriteFailed
        }
    }

    /// 同步 Remote PTY 尺寸（窗口 Resize → 远端 tput cols/lines）。
    func resizeChannelPTY(columns: Int, rows: Int) async throws {
        // 打开窗口期内 PTY / Shell 请求尚未完成：提前穿插的 resize 会在同一
        // Channel 上触发 LIBSSH2_ERROR_BAD_USE 并破坏打开序列（后续 Shell
        // 请求直接失败）——等待在途打开 / 关闭尘埃落定后再决策。
        while shellChannelOpenTask != nil || shellChannelCloseTask != nil {
            if let opening = shellChannelOpenTask {
                try? await opening.value
                continue
            }
            if let closing = shellChannelCloseTask {
                await closing.value
                continue
            }
        }

        guard let session else {
            throw RemoteTerminalError.connectionLost
        }
        guard let channel = shellChannel else {
            return
        }

        let deadline = Date().addingTimeInterval(ChannelTimeouts.resize)
        while true {
            try validateChannelOperation(session: session, channel: channel)

            let rc = libssh2_channel_request_pty_size_ex(
                channel,
                Int32(max(1, columns)),
                Int32(max(1, rows)),
                0,
                0
            )

            if rc == 0 {
                AppLogger.terminal.info("Remote PTY resized to \(columns) × \(rows)")
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await waitForLibssh2Readiness(session: session, deadline: deadline)
                continue
            }

            let lastError = libssh2_session_last_errno(session)
            AppLogger.terminal.error("PTY resize failed with libssh2 code \(lastError)")
            throw RemoteTerminalError.resizeFailed
        }
    }

    /// 优雅关闭 Shell Channel：send EOF → close → wait closed → free。
    ///
    /// 幂等且并发安全：
    /// - 在途等待：清理步骤跨 await（actor 重入窗口），若另一流程的清理
    ///   正在进行，本次调用挂起等待该任务完成后才返回。
    /// - 登记清空在任务体内（defer），任务完成后槽位必为空。
    /// - 每一步失败都尽力继续清理，最终释放 `LIBSSH2_CHANNEL *`；
    ///   任何路径（用户断开 / 远端退出 / 连接丢失 / 失败清理）都不泄漏 Channel。
    ///
    /// 语义边界（第二轮验收整改）：本方法只负责关闭"当前登记的"Channel，
    /// 等待在途清理后直接返回、**不**重新检查 `shellChannel`——等待期间
    /// 完成的新打开属于新的会话（close → reopen 流程），由其自身的关闭
    /// 路径负责；若在此重新检查并关闭，旧会话的关闭路径会在 reopen 后
    /// 误杀新 Terminal 的 Channel（按 actor 恢复顺序非确定性触发）。
    /// **断开路径需要的是"关闭全部 Channel"**，由
    /// `closeAllShellChannelsForTeardown()`（`disconnect()` 调用）保证：
    /// 先等待在途打开，再循环检查直到清空。
    func closeShellChannel() async {
        // 已有清理在跑：等待其完成后返回（语义见上方"语义边界"）。
        if let running = shellChannelCloseTask {
            await running.value
            return
        }

        guard let channel = shellChannel else {
            return
        }
        shellChannel = nil

        let closeTask = Task {
            await performTrackedGracefulShellChannelClose(channel)
        }
        shellChannelCloseTask = closeTask
        await closeTask.value
    }

    /// 关闭任务体：实际清理步骤 + 任务结束时清空在途登记。
    ///
    /// 登记清空放在任务体内（actor 隔离的 defer），保证"任务完成后槽位
    /// 必为空"——等待方恢复时不会看到已完成任务的残留登记，
    /// `closeAllShellChannelsForTeardown()` 的循环因此必然收敛。
    private func performTrackedGracefulShellChannelClose(_ channel: OpaquePointer) async {
        defer { shellChannelCloseTask = nil }
        await performGracefulShellChannelClose(channel)
    }

    /// 断开专用：关闭**全部** Shell Channel（teardown 语义）。
    ///
    /// 与 `closeShellChannel()`（只关闭当前登记的 Channel，reopen 语义）
    /// 的区别：本方法等待在途打开 / 关闭任务并**循环检查直到清空**——
    /// 第二轮验收 P1 的修复核心。此前 `disconnect()` 只调用一次
    /// `closeShellChannel()`：若旧 Channel 的清理在途、新 Channel 恰好在
    /// 等待期间打开，该方法"等完旧任务即返回"而不检查新 Channel，
    /// Session 释放后 `shellChannel` 成为悬空指针。
    ///
    /// 收敛保证：调用方（`disconnect()`）已置位断开标志，
    /// `openInteractiveShell()` 入口校验会拒绝任何新打开，循环内只会
    /// 出现在途任务的相继完成与残余 Channel 的关闭，必然终止。
    /// 在途打开最迟在其各步骤预算内结束（成功 → Channel 被本轮关闭；
    /// 失败 → 打开路径自身的失败清理已释放半开 Channel）。
    func closeAllShellChannelsForTeardown() async {
        while shellChannelOpenTask != nil
            || shellChannelCloseTask != nil
            || shellChannel != nil
        {
            if let openTask = shellChannelOpenTask {
                _ = try? await openTask.value
                continue
            }
            if let closeTask = shellChannelCloseTask {
                await closeTask.value
                continue
            }
            // 无在途任务但 Channel 仍在（例如打开恰好在断开标志置位前完成）。
            await closeShellChannel()
        }
    }

    /// `closeShellChannel()` 的实际清理步骤；在独立 Task 中执行，
    /// 供并发调用方（disconnect / stop / 读取循环退出）等待完成。
    private func performGracefulShellChannelClose(_ channel: OpaquePointer) async {
        let deadline = Date().addingTimeInterval(ChannelTimeouts.gracefulClose)

        // 1. 通知远端我方不再发送（尽力而为）。
        _ = try? await runChannelOperation(
            channel: channel,
            budget: ChannelTimeouts.gracefulClose
        ) {
            libssh2_channel_send_eof(channel)
        }

        // 2. 关闭 Channel（EAGAIN 重试）。
        _ = try? await runChannelOperation(channel: channel, budget: ChannelTimeouts.gracefulClose) {
            libssh2_channel_close(channel)
        }

        // 3. 等待远端确认关闭（尽力而为，不阻塞清理）。
        _ = try? await runChannelOperation(channel: channel, budget: ChannelTimeouts.gracefulClose) {
            libssh2_channel_wait_closed(channel)
        }

        // 4. 释放 Channel（EAGAIN 重试直到成功，防止泄漏）。
        while true {
            let rc = libssh2_channel_free(channel)
            if rc == 0 {
                break
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                if Date() > deadline {
                    AppLogger.terminal.error("Channel free timed out; session teardown will reclaim it")
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            // 其他错误：session teardown 也会回收 channel 资源，记录后继续。
            AppLogger.terminal.error("Channel free failed with libssh2 code \(rc)")
            break
        }

        AppLogger.terminal.info("Remote shell channel closed")
    }

    // MARK: - 私有：Channel 建立步骤

    /// 打开 Session Channel；返回 EAGAIN 时按阻塞方向等待，不 busy-loop。
    private func openSessionChannel(
        session: OpaquePointer,
        budget: TimeInterval
    ) async throws -> OpaquePointer {
        let deadline = Date().addingTimeInterval(budget)

        while true {
            try validateChannelOperation(session: session, channel: nil)

            // 函数式宏 libssh2_channel_open_session 在 Swift 中不可用，
            // 必须调用底层 _ex 函数；窗口/包大小使用 libssh2 默认值
            // （LIBSSH2_CHANNEL_WINDOW_DEFAULT = 2MB / PACKET_DEFAULT = 32768）。
            if let channel = libssh2_channel_open_ex(
                session,
                "session",
                7,
                2 * 1024 * 1024,
                32_768,
                nil,
                0
            ) {
                return channel
            }

            let lastError = libssh2_session_last_errno(session)
            guard lastError == LIBSSH2_ERROR_EAGAIN else {
                AppLogger.terminal.error("Channel open failed with libssh2 code \(lastError)")
                throw RemoteTerminalError.channelOpenFailed
            }

            try await waitForLibssh2Readiness(session: session, deadline: deadline)
        }
    }

    /// 请求 PTY：xterm-256color + 真实初始尺寸。
    private func requestPTY(
        session: OpaquePointer,
        channel: OpaquePointer,
        term: String,
        columns: Int,
        rows: Int,
        budget: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(budget)

        while true {
            try validateChannelOperation(session: session, channel: channel)

            // 函数式宏 libssh2_channel_request_pty 的 Swift 等价：直接调 _ex。
            let rc = term.withCString { termPointer in
                libssh2_channel_request_pty_ex(
                    channel,
                    termPointer,
                    UInt32(term.utf8.count),
                    nil,
                    0,
                    Int32(columns),
                    Int32(rows),
                    0,
                    0
                )
            }

            if rc == 0 {
                AppLogger.terminal.info("Remote PTY requested (\(columns) × \(rows), \(term))")
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await waitForLibssh2Readiness(session: session, deadline: deadline)
                continue
            }

            AppLogger.terminal.error("PTY request failed with libssh2 code \(rc)")
            throw RemoteTerminalError.ptyRequestFailed
        }
    }

    /// 请求启动 Remote Shell。
    private func requestShell(
        session: OpaquePointer,
        channel: OpaquePointer,
        budget: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(budget)

        while true {
            try validateChannelOperation(session: session, channel: channel)

            // 函数式宏 libssh2_channel_shell 的 Swift 等价：process_startup("shell")。
            let rc = libssh2_channel_process_startup(channel, "shell", 5, nil, 0)

            if rc == 0 {
                AppLogger.terminal.info("Remote shell started")
                return
            }

            if rc == LIBSSH2_ERROR_EAGAIN {
                try await waitForLibssh2Readiness(session: session, deadline: deadline)
                continue
            }

            AppLogger.terminal.error("Shell request failed with libssh2 code \(rc)")
            throw RemoteTerminalError.shellRequestFailed
        }
    }

    /// 对返回 Int32 的 Channel 操作执行 EAGAIN 重试包装。
    private func runChannelOperation(
        channel: OpaquePointer,
        budget: TimeInterval,
        _ operation: () throws -> Int32
    ) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(budget)

        while true {
            let rc = try operation()
            if rc != LIBSSH2_ERROR_EAGAIN {
                return rc
            }
            if Date() > deadline {
                return rc
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
