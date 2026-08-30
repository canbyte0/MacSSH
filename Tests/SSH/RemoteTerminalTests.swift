import AppKit
import Darwin
import Foundation
import SwiftData
import SwiftUI
import XCTest

@testable import MacSSH

/// 固定 `session_disconnect` EAGAIN 重入窗口的异步闸门。
private actor DisconnectEAGAINGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasBeenReleased = false

    var isWaiting: Bool {
        continuation != nil
    }

    func waitUntilReleased() async {
        guard !hasBeenReleased else {
            return
        }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        hasBeenReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/// Session teardown 测试探针：第一次 disconnect 固定返回 EAGAIN；真实 free
/// 完成后拦截任何重复 free，既能稳定断言 double-free，又不会让缺陷版本崩溃。
private final class SessionTeardownProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDisconnectCallCount = 0
    private var storedFreeInvocationCount = 0
    private var storedSuccessfulFreeCount = 0
    private var storedDuplicateFreeCount = 0
    private var didCompleteFree = false

    var disconnectCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDisconnectCallCount
    }

    var freeInvocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFreeInvocationCount
    }

    var successfulFreeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSuccessfulFreeCount
    }

    var duplicateFreeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDuplicateFreeCount
    }

    func disconnect(session: OpaquePointer, reason: String) -> Int32 {
        lock.lock()
        storedDisconnectCallCount += 1
        let shouldForceEAGAIN = storedDisconnectCallCount == 1
        lock.unlock()

        if shouldForceEAGAIN {
            return Int32(LIBSSH2_ERROR_EAGAIN)
        }
        return libssh2_session_disconnect_ex(
            session,
            SSH_DISCONNECT_BY_APPLICATION,
            reason,
            ""
        )
    }

    func free(session: OpaquePointer) -> Int32 {
        lock.lock()
        storedFreeInvocationCount += 1
        if didCompleteFree {
            storedDuplicateFreeCount += 1
            lock.unlock()
            return 0
        }
        lock.unlock()

        let rc = libssh2_session_free(session)
        if rc == 0 {
            lock.lock()
            didCompleteFree = true
            storedSuccessfulFreeCount += 1
            lock.unlock()
        }
        return rc
    }
}

/// Phase 7 Remote SSH Terminal 真实集成测试。
///
/// 测试服务器：本机 sshd（真实 libssh2 + 真实 PTY + 真实 shell）。
/// 凭据与测试密钥由 `Scripts/run-ssh-tests.sh` 预置，退出自动清理；
/// 任何源码、断言与日志都不包含 Password / Passphrase。
@MainActor
final class RemoteTerminalTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    /// 与测试脚本一致的测试专用 Keychain 凭据 account。
    private let liveCredentialID = UUID(uuidString: "7d54a5bf-3032-4db2-9267-a643fe75c229")!

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
        static let ed25519Pass = "/tmp/macssh_phase6_ed25519_pass"
        static let ed25519PassSecret = "/tmp/macssh_phase6_ed25519_pass.secret.p7"
    }

    /// htop（计划书 Phase 7 验收命令）的常见安装路径；测试服务器为本机。
    private static let htopInstallCandidates = [
        "/opt/homebrew/bin/htop",
        "/usr/local/bin/htop",
        "/usr/bin/htop"
    ]

    private var knownHostContainer: ModelContainer!
    private var knownHostService: KnownHostService!

    override func setUp() async throws {
        continueAfterFailure = false
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        knownHostContainer = try ModelContainer(for: schema, configurations: [configuration])
        knownHostService = KnownHostService(modelContainer: knownHostContainer)
    }

    override func tearDown() async throws {
        await MainActor.run { knownHostService.removeAll() }
        knownHostService = nil
        knownHostContainer = nil
    }

    // MARK: - 测试 A：Shell Channel 完整交互（Password 认证）

    /// Password 认证 → open channel → PTY → shell → 写入 echo → 读到输出 → exit → EOF。
    func testA_PasswordShellChannelEchoRoundtrip() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)
        let channelOpen = await connection.hasOpenShellChannel
        XCTAssertTrue(channelOpen, "Channel/PTY/Shell 建立成功")

        // 写入 → 远端执行 → 读回输出（原始 byte stream）。
        // marker 在命令中用引号拆分：PTY 回显的命令行因此不含连续 marker，
        // 只有远端真实输出（引号在 shell 解析时移除）才会匹配。
        try await connection.writeChannelInput(input("echo PHASE7_PASSWORD_\"TERMINAL_OK\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_PASSWORD_TERMINAL_OK".utf8),
            timeout: 15
        )
        XCTAssertTrue(found.containsMarker, "必须读到远端 echo 输出")

        // 远端 exit → EOF。
        try await connection.writeChannelInput(input("exit\r"))
        let eof = try await waitForEOF(connection, timeout: 10)
        XCTAssertTrue(eof, "exit 后必须收到 Channel EOF")

        await connection.closeShellChannel()
        let channelClosed = await connection.hasOpenShellChannel
        XCTAssertFalse(channelClosed, "Channel 关闭后不得残留")
    }

    // MARK: - 测试 B：Shell Channel（Private Key 认证）

    func testB_PrivateKeyShellChannelEchoRoundtrip() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )

        let connection = try await makeAuthenticatedConnection(
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.ed25519NoPass
        )
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 100, rows: 30)

        try await connection.writeChannelInput(input("echo PHASE7_PRIVATE_KEY_\"TERMINAL_OK\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_PRIVATE_KEY_TERMINAL_OK".utf8),
            timeout: 15
        )
        XCTAssertTrue(found.containsMarker, "Private Key 认证后的 Shell 必须可交互")

        try await connection.writeChannelInput(input("exit\r"))
        _ = try await waitForEOF(connection, timeout: 10)
    }

    // MARK: - 测试 C：PTY Resize 同步

    /// resize → 远端 stty size 必须反映新尺寸（交互式 PTY 链路证明）。
    func testC_ResizePTYSyncsRemoteSize() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 80, rows: 24)

        // 等待 shell 就绪后同步新尺寸，再读取远端报告。
        try await connection.resizeChannelPTY(columns: 101, rows: 37)
        try await connection.writeChannelInput(input("stty size\r"))
        let found = try await readUntil(
            connection,
            marker: Data("37 101".utf8),
            timeout: 15
        )
        XCTAssertTrue(found.containsMarker, "远端 stty size 必须与 resize 后的 101 × 37 一致")
    }

    // MARK: - 测试 D：UTF-8 / 中文 / Emoji 原始字节流

    func testD_UTF8ChineseEmojiRoundtrip() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        // 命令中把输出拆成两个 echo 参数：回显的命令行含引号因此不匹配
        // marker；真实输出为参数拼接结果（单空格分隔），逐字节与 marker 一致。
        try await connection.writeChannelInput(input("echo '中文测试' '😀🚀'\r"))
        let found = try await readUntil(
            connection,
            marker: Data("中文测试 😀🚀".utf8),
            timeout: 15
        )
        XCTAssertTrue(found.containsMarker, "中文 + Emoji 必须无乱码地往返（UTF-8 byte stream）")
    }

    // MARK: - 测试 E：大量输出

    /// seq 1 100000：读循环持续搬运、无崩溃、无额外无限累积（仅流式搜索）。
    func testE_LargeOutputStreaming() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 200, rows: 50)

        try await connection.writeChannelInput(input("seq 1 100000; echo PHASE7_SEQ_\"DONE\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_SEQ_DONE".utf8),
            timeout: 60
        )
        XCTAssertTrue(found.containsMarker, "大量输出必须完整流过 Channel")
        XCTAssertGreaterThan(
            found.totalBytes,
            400_000,
            "100000 行 seq 输出应有数百 KB 量级（实际 \(found.totalBytes) 字节）"
        )
    }

    // MARK: - 测试 I：vim 全屏交互（任务书第 45 节）

    /// vim 进入 → alternate screen 全屏绘制 → :q 退出 → 回到 shell：
    /// 证明 PTY 全屏与控制序列双向链路真实可用（不是 vim --version）。
    /// 用 ESC[?1049h / ESC[?1049l（进入/离开 alternate screen）作为
    /// vim 生命周期标记——这是全屏程序最可靠的控制序列证据。
    func testI_VimFullScreenRoundtrip() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        let altScreenEnter = Data("\u{1b}[?1049h".utf8)
        let altScreenLeave = Data("\u{1b}[?1049l".utf8)

        // 远端启动 vim（macOS 自带）。
        try await connection.writeChannelInput(input("vim\r"))
        let entered = try await readUntil(
            connection,
            marker: altScreenEnter,
            timeout: 20
        )
        XCTAssertTrue(entered.containsMarker, "vim 必须进入 alternate screen 全屏模式")

        // 退出：Esc 确保普通模式，然后 :q + Enter。
        try await connection.writeChannelInput(input("\u{1b}:q\r"))
        let exited = try await readUntil(
            connection,
            marker: altScreenLeave,
            timeout: 20
        )
        XCTAssertTrue(exited.containsMarker, "vim :q 必须离开 alternate screen 并恢复终端")

        // vim 退出后 shell 恢复：执行 marker 命令验证可继续交互。
        try await connection.writeChannelInput(input("echo PHASE7_VIM_\"EXITED\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_VIM_EXITED".utf8),
            timeout: 20
        )
        XCTAssertTrue(found.containsMarker, "vim :q 后必须回到交互 shell（可继续执行命令）")
    }

    // MARK: - 测试 J：Ctrl+C 中断远端进程（任务书第 47 节）

    /// ping（无 -c，持续运行）→ 发送 0x03 → 远端进程必须被中断 → shell 恢复。
    func testJ_CtrlCInterruptsRemotePing() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        // 持续 ping（不带 -c，只有 Ctrl+C 能停止）。
        try await connection.writeChannelInput(input("ping 127.0.0.1\r"))
        let pinging = try await readUntil(
            connection,
            marker: Data("bytes".utf8),
            timeout: 20
        )
        XCTAssertTrue(pinging.containsMarker, "ping 必须已在远端运行并输出")

        // Ctrl+C = 0x03（真实 terminal input byte，非字符串拼接）。
        try await connection.writeChannelInput(input("\u{03}"))
        // 中断后 shell 恢复：执行 marker 命令验证。
        try await connection.writeChannelInput(input("echo PHASE7_CTRLC_\"OK\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_CTRLC_OK".utf8),
            timeout: 20
        )
        XCTAssertTrue(
            found.containsMarker,
            "Ctrl+C 后 shell 必须恢复可交互（远端 ping 被真实中断）"
        )
    }

    // MARK: - 测试 K：ANSI 颜色序列（任务书第 16 节）

    /// `ls --color=always`：输出必须包含原始 ANSI escape 序列（ESC [ … m），
    /// 证明彩色输出未被 transport 破坏（原始 byte stream 直通）。
    func testK_ANSIColorSequencesPassThrough() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        try await connection.writeChannelInput(input("ls --color=always / | head -3; echo PHASE7_ANSI_\"DONE\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_ANSI_DONE".utf8),
            timeout: 20
        )
        XCTAssertTrue(found.containsMarker, "ls --color 必须执行完成")

        // ANSI CSI 序列证据：ESC '['（任意控制序列起始，含 SGR 颜色）。
        let escMarker = Data([0x1b, UInt8(ascii: "[")])
        XCTAssertTrue(
            found.rollingSnapshot.contains(escMarker),
            "输出必须包含原始 ANSI CSI 转义序列（ESC[...，含颜色 SGR）"
        )
    }

    // MARK: - 测试 L：top 全屏交互（计划书 Phase 7 验收命令）

    /// top（macOS 自带）：ncurses 全屏 → alternate screen → 持续刷新 →
    /// 'q' 退出 → 恢复 shell。与 testI（vim）一致，以 ESC[?1049h /
    /// ESC[?1049l 作为全屏程序生命周期证据。
    ///
    /// 认证走 Private Key（认证方式与全屏交互无关；Password 认证的
    /// Shell 链路由 testA 覆盖）。
    func testL_TopFullScreenRoundtrip() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        let altScreenEnter = Data("\u{1b}[?1049h".utf8)
        let altScreenLeave = Data("\u{1b}[?1049l".utf8)

        try await connection.writeChannelInput(input("top\r"))
        let entered = try await readUntil(
            connection,
            marker: altScreenEnter,
            timeout: 20
        )
        XCTAssertTrue(entered.containsMarker, "top 必须进入 alternate screen 全屏模式")

        // 让 top 刷新数秒：期间输出持续流过 Channel（统计行真实更新）。
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // 'q' 退出 top。
        try await connection.writeChannelInput(input("q"))
        let exited = try await readUntil(
            connection,
            marker: altScreenLeave,
            timeout: 20
        )
        XCTAssertTrue(exited.containsMarker, "top 'q' 后必须离开 alternate screen 并恢复终端")

        // 退出后 shell 恢复：执行 marker 命令验证可继续交互。
        try await connection.writeChannelInput(input("echo PHASE7_TOP_\"EXITED\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_TOP_EXITED".utf8),
            timeout: 20
        )
        XCTAssertTrue(found.containsMarker, "top 退出后必须回到交互 shell（可继续执行命令）")
    }

    // MARK: - 测试 M：nano 全屏编辑交互（计划书 Phase 7 验收命令）

    /// nano（macOS 自带）：进入编辑器 → 真实输入文本（进编辑缓冲）→
    /// ^X 触发 "Save modified buffer" 询问（证明输入真实生效）→
    /// 'N' 放弃修改退出 → 恢复 shell。
    ///
    /// 认证走 Private Key（与 testL 相同理由）。
    func testM_NanoFullScreenRoundtrip() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        let altScreenEnter = Data("\u{1b}[?1049h".utf8)
        let altScreenLeave = Data("\u{1b}[?1049l".utf8)

        try await connection.writeChannelInput(input("nano\r"))
        let entered = try await readUntil(
            connection,
            marker: altScreenEnter,
            timeout: 20
        )
        XCTAssertTrue(entered.containsMarker, "nano 必须进入 alternate screen 全屏模式")

        // 在编辑器内真实输入文本：键盘字节流 → PTY → nano 编辑缓冲。
        try await connection.writeChannelInput(input("phase7 nano buffer edit"))

        // ^X（Control-X = 0x18）退出；缓冲有修改时 nano 必须先询问保存。
        try await connection.writeChannelInput(input("\u{18}"))
        let asked = try await readUntil(
            connection,
            marker: Data("Save modified buffer".utf8),
            timeout: 20
        )
        XCTAssertTrue(
            asked.containsMarker,
            "输入过文本后 ^X 必须触发保存询问（证明输入真实进入 nano 缓冲）"
        )

        // 'N' 放弃修改退出。
        try await connection.writeChannelInput(input("N"))
        let exited = try await readUntil(
            connection,
            marker: altScreenLeave,
            timeout: 20
        )
        XCTAssertTrue(exited.containsMarker, "nano 放弃修改后必须离开 alternate screen 并恢复终端")

        try await connection.writeChannelInput(input("echo PHASE7_NANO_\"EXITED\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_NANO_EXITED".utf8),
            timeout: 20
        )
        XCTAssertTrue(found.containsMarker, "nano 退出后必须回到交互 shell（可继续执行命令）")
    }

    // MARK: - 测试 N：htop 全屏交互（计划书 Phase 7 验收命令）

    /// htop（Homebrew 安装于本机测试服务器）：全屏 → 持续刷新 →
    /// 'q' 退出 → 恢复 shell。未安装时明确 skip（不静默通过）。
    ///
    /// 认证走 Private Key（与 testL 相同理由）。
    func testN_HtopFullScreenRoundtrip() async throws {
        try await requireLocalSSHAndTestKey()

        // 测试服务器为本机：SSH 远端与本地文件系统一致，直接探测候选路径。
        let htopPath = Self.htopInstallCandidates.first {
            FileManager.default.fileExists(atPath: $0)
        }
        try XCTSkipUnless(
            htopPath != nil,
            "测试服务器未安装 htop（候选路径：\(Self.htopInstallCandidates.joined(separator: ", "))）"
        )

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        let altScreenEnter = Data("\u{1b}[?1049h".utf8)
        let altScreenLeave = Data("\u{1b}[?1049l".utf8)

        // 使用绝对路径启动：sshd login shell 的 PATH 未必包含 Homebrew。
        try await connection.writeChannelInput(input("\(htopPath!)\r"))
        let entered = try await readUntil(
            connection,
            marker: altScreenEnter,
            timeout: 20
        )
        XCTAssertTrue(entered.containsMarker, "htop 必须进入 alternate screen 全屏模式")

        // 让 htop 刷新数秒：期间输出持续流过 Channel（进程列表真实更新）。
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // 'q' 退出 htop。
        try await connection.writeChannelInput(input("q"))
        let exited = try await readUntil(
            connection,
            marker: altScreenLeave,
            timeout: 20
        )
        XCTAssertTrue(exited.containsMarker, "htop 'q' 后必须离开 alternate screen 并恢复终端")

        try await connection.writeChannelInput(input("echo PHASE7_HTOP_\"EXITED\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_HTOP_EXITED".utf8),
            timeout: 20
        )
        XCTAssertTrue(found.containsMarker, "htop 退出后必须回到交互 shell（可继续执行命令）")
    }

    // MARK: - 测试 O：打开与立即关闭的竞态（不留孤儿 Channel）

    /// `startIfNeeded()` 发起打开后立即 `stop()`（用户"刚打开就关闭"）：
    /// 打开任务完成或被取消后必须补偿关闭 Channel——读取循环从未启动，
    /// 无人关闭就是孤儿 Channel（此前缺陷：打开任务不保存、不检查停止标志）。
    func testO_ImmediateStopDuringOpenLeavesNoOrphanChannel() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        let service = RemoteTerminalService(
            connection: connection,
            hostname: testHostname,
            port: Int(testPort)
        )

        // 发起打开后立刻停止：打开任务与 stop() 竞争，任何执行顺序
        // 都不允许在打开完成后留下无人管理的 Channel。
        service.startIfNeeded()
        service.stop()

        // 等待打开任务真正结束（含其 hasStopped 补偿关闭 / 失败清理 /
        // 取消静默路径）——之后 Channel 状态才是终局。
        await service.waitForOpenTaskToFinish()

        let hasChannel = await connection.hasOpenShellChannel
        XCTAssertFalse(
            hasChannel,
            "打开与立即关闭竞争后不得残留孤儿 Channel（stop 的补偿关闭必须生效）"
        )

        // 连接仍可正常使用（Channel 关闭未破坏 session）。
        try await connection.openInteractiveShell(columns: 80, rows: 24)
        try await connection.writeChannelInput(input("echo PHASE7_STOP_RACE_\"OK\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_STOP_RACE_OK".utf8),
            timeout: 20
        )
        XCTAssertTrue(found.containsMarker, "竞态关闭后同一连接必须还能打开新 Shell")
    }

    // MARK: - 测试 P：close → reopen → disconnect 并发（第二轮验收 P1）

    /// 第二轮验收 P1 交错：旧 Channel 在途关闭 + 重新打开新 Channel +
    /// disconnect 并发。此前缺陷：`closeShellChannel()` 只等旧关闭任务
    /// 即返回、不检查新 Channel；`disconnect()` 不等在途打开、断开标志
    /// 在 Session 释放前才置位——新 Channel 可能在 Session 释放后仍登记在
    /// `shellChannel`（悬空指针），后续 stop() / 读取循环退出路径关闭它时
    /// use-after-free。
    ///
    /// 修复机制下的不变式：disconnect 返回后不得残留 Channel（悬空指针
    /// 会让 `hasOpenShellChannel` 为 true）且不得有在途打开 / 关闭登记。
    ///
    /// 多轮不同偏移覆盖多种到达顺序：0 = 关闭 / 打开 / 断开几乎同时；
    /// 其余让前一步部分推进后再注入下一步。每轮全新连接。
    func testP_CloseReopenDisconnectConcurrentNoDanglingChannel() async throws {
        try await requireLocalSSHAndTestKey()

        let offsetsNanoseconds: [UInt64] = [0, 5_000_000, 20_000_000, 50_000_000]

        for (cycle, offset) in offsetsNanoseconds.enumerated() {
            let connection = try await makeAuthenticatedTestKeyConnection()

            // 1. 打开第一个 Shell。
            try await connection.openInteractiveShell(columns: 80, rows: 24)
            let firstOpen = await connection.hasOpenShellChannel
            XCTAssertTrue(firstOpen, "第 \(cycle + 1) 轮：首个 Shell 必须打开成功")

            // 2. 旧 Channel 的异步关闭（模拟 stop() 的异步清理）与重新打开并发：
            //    打开入口必须等待在途关闭完成后才建立新 Channel。
            let closeTask = Task { await connection.closeShellChannel() }
            let reopenTask = Task {
                try await connection.openInteractiveShell(columns: 100, rows: 30)
            }
            if offset > 0 {
                try? await Task.sleep(nanoseconds: offset)
            }

            // 3. disconnect 与上述两者并发（模拟 hostDidDisconnect：
            //    stop() 异步关闭 + sshService.disconnect() 立即到达）。
            await connection.disconnect()

            // 4. 全部任务尘埃落定后断言不变式。
            _ = await closeTask.result
            _ = await reopenTask.result

            let dangling = await connection.hasOpenShellChannel
            XCTAssertFalse(
                dangling,
                "第 \(cycle + 1) 轮：disconnect 后 shellChannel 必须为 nil（不得悬空）"
            )

            let openPending = await connection.shellChannelOpenTask
            XCTAssertNil(
                openPending,
                "第 \(cycle + 1) 轮：disconnect 后不得有在途打开登记"
            )
            let closePending = await connection.shellChannelCloseTask
            XCTAssertNil(
                closePending,
                "第 \(cycle + 1) 轮：disconnect 后不得有在途关闭登记"
            )
        }
    }

    // MARK: - 测试 Q：并发 disconnect + session disconnect EAGAIN（第三轮验收 P1）

    /// 第一条 disconnect 在 `libssh2_session_disconnect_ex` 返回 EAGAIN 后通过
    /// 测试闸门稳定挂起；第二条 disconnect 此时进入 actor。两条调用必须合并
    /// 等待同一个 `disconnectTask`，整个流程只能成功释放一次 Session。
    func testQ_ConcurrentDisconnectsCoalesceDuringSessionDisconnectEAGAIN() async throws {
        try await requireLocalSSHAndTestKey()

        let gate = DisconnectEAGAINGate()
        let probe = SessionTeardownProbe()
        let operations = SSHConnection.SessionTeardownOperations(
            disconnect: { session, reason in
                probe.disconnect(session: session, reason: reason)
            },
            free: { session in
                probe.free(session: session)
            },
            afterDisconnectEAGAIN: {
                await gate.waitUntilReleased()
            }
        )

        let connection = try await makeAuthenticatedTestKeyConnection(
            sessionTeardownOperations: operations
        )

        let firstDisconnect = Task { await connection.disconnect() }
        let reachedEAGAINWindow = try await waitForCondition(timeout: 5) {
            await gate.isWaiting
        }
        guard reachedEAGAINWindow else {
            await gate.release()
            _ = await firstDisconnect.result
            XCTFail("第一条 disconnect 必须进入稳定的 EAGAIN 重入窗口")
            return
        }

        // 第一条任务仍挂起时启动第二条；给 actor 足够时间处理第二个入口。
        let secondDisconnect = Task { await connection.disconnect() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let callsWhileSuspended = probe.disconnectCallCount
        let freesWhileSuspended = probe.freeInvocationCount

        // 先释放闸门再断言，确保断言失败时也不会遗留挂起任务。
        await gate.release()
        _ = await firstDisconnect.result
        _ = await secondDisconnect.result

        XCTAssertEqual(
            callsWhileSuspended,
            1,
            "并发第二条 disconnect 必须等待共享任务，不得启动第二条 teardown"
        )
        XCTAssertEqual(
            freesWhileSuspended,
            0,
            "第一条 disconnect 的 EAGAIN 窗口内不得由第二条任务提前释放 Session"
        )
        XCTAssertEqual(probe.successfulFreeCount, 1, "Session 必须且只能成功释放一次")
        XCTAssertEqual(probe.duplicateFreeCount, 0, "不得发生重复 libssh2_session_free")

        let hasLiveSession = await connection.hasLiveSession
        XCTAssertFalse(hasLiveSession, "disconnect 完成后 Session 所有权必须清空")
        let hasActiveDisconnectTask = await connection.hasActiveDisconnectTask
        XCTAssertFalse(hasActiveDisconnectTask, "disconnect 完成后共享任务登记必须清空")
    }

    // MARK: - 测试 R：less 分页器（最终复验验收命令：less）

    /// less /etc/services（本机行数足够分页）：进入 alternate screen →
    /// Space 翻页（按键后输出继续流动）→ G 跳到文件末尾（END 标记）→
    /// q 退出 → shell 恢复。
    ///
    /// 说明：验收命令原文为 `less /etc/hosts`；该文件仅约 10 行，在 35 行
    /// PTY 内单屏装下、无页可翻，改用必然分页的 /etc/services 验证同一
    /// 滚动链路；`less /etc/hosts` 的进入/退出行为由同一机制覆盖。
    func testR_LessPagerFullScreenRoundtrip() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        let altScreenEnter = Data("\u{1b}[?1049h".utf8)
        let altScreenLeave = Data("\u{1b}[?1049l".utf8)

        try await connection.writeChannelInput(input("less /etc/services\r"))
        let entered = try await readUntil(connection, marker: altScreenEnter, timeout: 20)
        XCTAssertTrue(entered.containsMarker, "less 必须进入 alternate screen 全屏模式")

        // Space 翻页：按键后必须有新的屏幕内容流出（重绘 / 下一页）。
        try await connection.writeChannelInput(input(" "))
        let pageFlow = try await readUntil(
            connection,
            marker: Data("PHASE7_LESS_NEVER_MATCH".utf8),
            timeout: 3
        )
        XCTAssertGreaterThan(
            pageFlow.totalBytes,
            0,
            "Space 后 less 必须有内容输出（滚动真实生效）"
        )

        // G 跳到文件末尾：less 显示 END。
        try await connection.writeChannelInput(input("G"))
        let reachedEnd = try await readUntil(connection, marker: Data("END".utf8), timeout: 10)
        XCTAssertTrue(reachedEnd.containsMarker, "G 后 less 必须到达文件末尾并显示 END")

        // q 退出 → 恢复终端与 shell。
        try await connection.writeChannelInput(input("q"))
        let exited = try await readUntil(connection, marker: altScreenLeave, timeout: 20)
        XCTAssertTrue(exited.containsMarker, "less q 必须离开 alternate screen 并恢复终端")

        try await connection.writeChannelInput(input("echo PHASE7_LESS_\"EXITED\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_LESS_EXITED".utf8),
            timeout: 20
        )
        XCTAssertTrue(found.containsMarker, "less 退出后必须回到交互 shell")
    }

    // MARK: - 测试 S：256 Color 与 TrueColor 真实颜色输出

    /// 远端 printf 产生真实 SGR 颜色序列并直通：
    /// - 256 Color：ESC[38;5;208m
    /// - TrueColor：ESC[38;2;255;100;0m
    /// 命令行回显中 \033 是字面文本，只有远端 printf 真实输出才含 ESC 字节，
    /// 不会误匹配（与 testA/D/E 相同的引号拆分机制）。
    func testS_TrueColorAnd256ColorSequencesPassThrough() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        // 引号拆分必须放在单引号格式串“外面”：格式串内的双引号是字面内容，
        // 会原样出现在远端输出里导致无引号 marker 永不匹配。
        try await connection.writeChannelInput(
            input("printf '\\033[38;5;208m'PHASE7_COLOR256_\"MARK\"'\\033[0m\\n'\r")
        )
        let color256 = try await readUntil(
            connection,
            marker: Data("\u{1b}[38;5;208mPHASE7_COLOR256_MARK".utf8),
            timeout: 15
        )
        XCTAssertTrue(color256.containsMarker, "256 Color SGR 序列必须从远端原始输出直通")

        try await connection.writeChannelInput(
            input("printf '\\033[38;2;255;100;0m'PHASE7_TRUECOLOR_\"MARK\"'\\033[0m\\n'\r")
        )
        let trueColor = try await readUntil(
            connection,
            marker: Data("\u{1b}[38;2;255;100;0mPHASE7_TRUECOLOR_MARK".utf8),
            timeout: 15
        )
        XCTAssertTrue(trueColor.containsMarker, "TrueColor SGR 序列必须从远端原始输出直通")
    }

    // MARK: - 测试 T：ED25519 带 Passphrase 的完整 Remote Terminal 链路

    /// 带 Passphrase 的 ED25519：读取脚本生成的随机 Passphrase（.p7 副本，
    /// 读后即删，值不进任何日志 / 断言）→ 经真实
    /// CredentialService→KeychainService 保存 → 认证 → Channel → PTY →
    /// Shell → echo 往返 → EOF。
    func testT_PassphraseKeyRemoteTerminalRoundtrip() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519Pass),
            "缺少带 Passphrase 测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519PassSecret),
            "缺少 Passphrase 临时文件（.p7 副本）：请使用 Scripts/run-ssh-tests.sh 预置"
        )

        let passphrase = try String(contentsOfFile: TestKeys.ed25519PassSecret, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: TestKeys.ed25519PassSecret)

        let passID = UUID()
        defer {
            Task {
                try? await CredentialService.shared.deletePrivateKeyPassphrase(privateKeyID: passID)
            }
        }
        try await CredentialService.shared.savePrivateKeyPassphrase(passphrase, privateKeyID: passID)

        let connection = try await makeAuthenticatedConnection(
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.ed25519Pass,
            privateKeyID: passID
        )
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 100, rows: 30)

        try await connection.writeChannelInput(input("echo PHASE7_PASSPHRASE_KEY_\"TERMINAL_OK\"\r"))
        let found = try await readUntil(
            connection,
            marker: Data("PHASE7_PASSPHRASE_KEY_TERMINAL_OK".utf8),
            timeout: 15
        )
        XCTAssertTrue(found.containsMarker, "带 Passphrase 私钥认证后的 Shell 必须可交互")

        try await connection.writeChannelInput(input("exit\r"))
        _ = try await waitForEOF(connection, timeout: 10)
    }

    // MARK: - 测试 U：Connection Lost（可控杀掉每连接 sshd 子进程）

    /// 可控断开：认证后本机 sshd 为本会话 fork 了以当前用户运行的
    /// 每连接子进程；kill 它使 OS 强制关闭 TCP 连接，模拟真实
    /// Connection Lost。读取循环必须在有界时间内以明确的终止状态
    /// （.connectionLost / .exited）结束，Channel 清理完成，不挂起、
    /// 不 busy-loop、不 Crash。
    func testU_ConnectionLostReadLoopTerminatesCleanly() async throws {
        try await requireLocalSSHAndTestKey()

        let sshdBeforeConnect = Self.userSSHDProcessIDs()

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        let service = RemoteTerminalService(
            connection: connection,
            hostname: testHostname,
            port: Int(testPort)
        )
        service.startIfNeeded()
        await service.waitForOpenTaskToFinish()

        let active = try await waitForCondition(timeout: 15) {
            await MainActor.run { service.session.phase == .active }
        }
        guard active else {
            service.stop()
            XCTFail("Remote Terminal 必须先进入 active 才能测试 Connection Lost")
            return
        }

        // 识别本连接新出现的 sshd 子进程（只杀新增的，绝不触碰既有会话）。
        let sshdAfterConnect = Self.userSSHDProcessIDs()
        let newSSHDProcesses = sshdAfterConnect.subtracting(sshdBeforeConnect)
        guard newSSHDProcesses.count == 1, let victim = newSSHDProcesses.first else {
            service.stop()
            XCTFail("无法唯一识别每连接 sshd 子进程：\(newSSHDProcesses)")
            return
        }

        let cpuStart = Self.processCPUSeconds()
        kill(victim, SIGKILL)

        // 读取循环必须在有界时间内终止并更新终止状态（不得无限挂起）。
        let terminated = try await waitForCondition(timeout: 20) {
            await MainActor.run {
                service.session.phase == .connectionLost || service.session.phase == .exited
            }
        }
        let cpuDelta = Self.processCPUSeconds() - cpuStart
        XCTAssertTrue(terminated, "Connection Lost 后读取循环必须终止且状态更新")
        XCTAssertLessThanOrEqual(
            cpuDelta,
            3.0,
            "Connection Lost 检测期间 CPU 增量不得 busy-loop（实测 \(String(format: "%.3f", cpuDelta)) 秒）"
        )

        // Channel 清理完成，不残留。
        let cleaned = try await waitForCondition(timeout: 15) {
            let open = await connection.hasOpenShellChannel
            return open == false
        }
        XCTAssertTrue(cleaned, "Connection Lost 后 Channel 必须清理完成")

        // 传输已死的情况下 disconnect 仍必须收敛返回（不挂起、不 Crash）。
        await connection.disconnect()
    }

    // MARK: - 测试 V：Sidebar 往返 Session 保持（服务层等价验证）

    /// 模拟 Remote Terminal → Hosts → Remote Terminal 的 SwiftUI 生命周期：
    /// 离开页面时 SwiftUI 真实执行的收尾是 `dismantleNSView`；回到页面
    /// `makeNSView` 会再次调用 `startIfNeeded()`（幂等）。全程 Service 与
    /// Shell 由 AppState 持有：不重建 Channel、不重新认证、远端 cwd 保持
    /// （远端即本机，用文件系统副作用文件在本地直接验证）。
    func testV_SidebarRoundtripKeepsShellAndWorkingDirectory() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        let service = RemoteTerminalService(
            connection: connection,
            hostname: testHostname,
            port: Int(testPort)
        )
        let probePath = "/tmp/macssh_phase7_sidebar_probe.txt"
        try? FileManager.default.removeItem(atPath: probePath)
        defer { try? FileManager.default.removeItem(atPath: probePath) }

        service.startIfNeeded()
        await service.waitForOpenTaskToFinish()
        let active = try await waitForCondition(timeout: 15) {
            await MainActor.run { service.session.phase == .active }
        }
        guard active else {
            service.stop()
            XCTFail("Remote Terminal 必须进入 active")
            return
        }

        // 建立远端 cwd = /tmp（login shell 起始于 home）。
        try await connection.writeChannelInput(input("cd /tmp\r"))
        try await Task.sleep(nanoseconds: 500_000_000)

        // 离开 Terminal 页面（切到 Hosts）：SwiftUI 拆卸包装视图。
        RemoteTerminalRepresentable.dismantleNSView(service.terminalView, coordinator: ())
        try await Task.sleep(nanoseconds: 300_000_000)

        // 离开期间会话与 Shell 必须原样保持。
        let stillActive = await MainActor.run { service.session.phase == .active }
        XCTAssertTrue(stillActive, "离开页面后 Remote Terminal 会话必须保持 active")
        let channelKept = await connection.hasOpenShellChannel
        XCTAssertTrue(channelKept, "离开页面后 Shell Channel 必须保持（不重建、不断开）")

        // 回到 Terminal 页面：makeNSView 再次调用 startIfNeeded()（幂等 no-op）。
        service.startIfNeeded()

        // 相对路径重定向：仅当 cwd 保持 /tmp 时该文件才会落在 /tmp。
        try await connection.writeChannelInput(input("pwd > macssh_phase7_sidebar_probe.txt\r"))
        guard let probeContent = try await waitForFileContent(at: probePath, timeout: 15) else {
            service.stop()
            XCTFail("pwd 副作用文件未写入 /tmp：Sidebar 往返后 cwd 未保持")
            return
        }
        XCTAssertTrue(
            probeContent.contains("tmp"),
            "往返后远端 cwd 必须仍为 /tmp（实际：\(probeContent.trimmingCharacters(in: .whitespacesAndNewlines))）"
        )

        let activeAfter = await MainActor.run { service.session.phase == .active }
        XCTAssertTrue(activeAfter, "回到页面后 Remote Terminal 必须仍可交互")

        service.stop()
    }

    // MARK: - 测试 W：真实窗口 Resize → 远端 tput 链路

    /// 真实 `NSWindow` + `NSHostingView(RemoteTerminalRepresentable)`
    /// （与生产 UI 同构）：实际改变窗口 frame → AppKit/SwiftUI 布局 →
    /// SwiftTerm `sizeChanged` → actor `resizeChannelPTY` → 远端
    /// `tput cols` / `tput lines` 报告值必须与 SwiftTerm / 状态栏
    /// （`session.columns` / `session.rows`）一致。
    ///
    /// tput 探针写入文件后在本地读取（远端即本机文件系统）。
    func testW_WindowResizePropagatesToRemoteTput() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        let service = RemoteTerminalService(
            connection: connection,
            hostname: testHostname,
            port: Int(testPort)
        )
        let probePath = "/tmp/macssh_phase7_tput_probe.txt"
        try? FileManager.default.removeItem(atPath: probePath)
        defer { try? FileManager.default.removeItem(atPath: probePath) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: RemoteTerminalRepresentable(service: service))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        service.startIfNeeded()
        await service.waitForOpenTaskToFinish()
        let active = try await waitForCondition(timeout: 15) {
            await MainActor.run { service.session.phase == .active }
        }
        guard active else {
            service.stop()
            XCTFail("Remote Terminal 必须进入 active")
            return
        }

        // 等待首次 layout 产生真实尺寸（80×24 是默认值）。
        _ = try await waitForCondition(timeout: 10) {
            await MainActor.run {
                service.session.columns != 80 || service.session.rows != 24
            }
        }

        // 第一次收敛等待：sizeChanged → actor resizeChannelPTY 是异步链路，
        // 远端 PTY 尺寸可能滞后于 SwiftTerm 状态，必须轮询直到一致。
        guard let sizeBefore = try await waitForRemoteSizeConverged(
            service: service,
            connection: connection,
            probePath: probePath
        ) else {
            service.stop()
            XCTFail("resize 前远端 tput 必须收敛到 SwiftTerm 尺寸")
            return
        }
        let colsBefore = await MainActor.run { service.session.columns }
        let rowsBefore = await MainActor.run { service.session.rows }
        XCTAssertEqual(sizeBefore.columns, colsBefore, "远端 tput cols 必须与 SwiftTerm 列数一致")
        XCTAssertEqual(sizeBefore.rows, rowsBefore, "远端 tput lines 必须与 SwiftTerm 行数一致")

        // 真实窗口 Resize。
        let origin = window.frame.origin
        window.setFrame(
            NSRect(x: origin.x, y: origin.y - 180, width: 1100, height: 700),
            display: true,
            animate: false
        )
        window.contentView?.layoutSubtreeIfNeeded()

        let resized = try await waitForCondition(timeout: 10) {
            await MainActor.run {
                service.session.columns != colsBefore || service.session.rows != rowsBefore
            }
        }
        XCTAssertTrue(resized, "窗口 Resize 必须驱动 SwiftTerm 尺寸变化")

        // 第二次收敛等待：远端必须最终同步新尺寸。
        guard let sizeAfter = try await waitForRemoteSizeConverged(
            service: service,
            connection: connection,
            probePath: probePath
        ) else {
            service.stop()
            XCTFail("resize 后远端 tput 必须收敛到新 SwiftTerm 尺寸")
            return
        }
        let colsAfter = await MainActor.run { service.session.columns }
        let rowsAfter = await MainActor.run { service.session.rows }
        XCTAssertEqual(sizeAfter.columns, colsAfter, "Resize 后远端 tput cols 必须与新 SwiftTerm 列数一致")
        XCTAssertEqual(sizeAfter.rows, rowsAfter, "Resize 后远端 tput lines 必须与新 SwiftTerm 行数一致")
        XCTAssertNotEqual(sizeBefore.columns, sizeAfter.columns, "窗口 Resize 必须真实改变远端列数")

        service.stop()
    }

    // MARK: - 测试 X：Remote exit 终态（服务层）

    /// 远端 `exit`：读取循环收到 EOF → phase = .exited、状态文案显示
    /// "Exited"，Channel 清理完成；不 Crash、不挂起。终端缓冲保留供用户
    /// 查看历史（视觉确认列入人工验收）。
    func testX_RemoteExitEntersExitedStateWithoutCrash() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        defer { Task { await connection.disconnect() } }

        let service = RemoteTerminalService(
            connection: connection,
            hostname: testHostname,
            port: Int(testPort)
        )
        service.startIfNeeded()
        await service.waitForOpenTaskToFinish()

        let active = try await waitForCondition(timeout: 15) {
            await MainActor.run { service.session.phase == .active }
        }
        guard active else {
            service.stop()
            XCTFail("Remote Terminal 必须进入 active")
            return
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        try await connection.writeChannelInput(input("exit\r"))

        let exited = try await waitForCondition(timeout: 15) {
            await MainActor.run { service.session.phase == .exited }
        }
        XCTAssertTrue(exited, "远端 exit 后状态必须为 exited（不 Crash、不挂起）")

        let statusText = await MainActor.run { service.session.statusText }
        XCTAssertTrue(
            statusText.contains("Exited"),
            "状态文案必须明确显示退出状态（实际：\(statusText)）"
        )

        let cleaned = try await waitForCondition(timeout: 15) {
            let open = await connection.hasOpenShellChannel
            return open == false
        }
        XCTAssertTrue(cleaned, "远端 exit 后 Channel 必须清理完成")
    }

    // MARK: - 测试 F：Channel 打开失败清理（未认证 Session）

    /// 在未认证的 Session 上请求 shell：libssh2 打开 Channel 会被服务器拒绝，
    /// openInteractiveShell 必须失败且不留下半开 Channel。
    func testF_ShellRequestOnUnauthenticatedSessionFails() async throws {
        try await requireLocalSSH()

        // 只完成 handshake + Trust Once（停在认证之前）。
        let info = makeInfo()
        let connection = makeConnection(info: info, credentialID: nil)
        let connectTask = Task { await connection.connect() }

        _ = try await waitForCondition(timeout: 15) {
            await MainActor.run { info.phase == .awaitingHostTrust }
        }
        await connection.resolveHostTrust(.trustOnce)

        // 无凭据 → 认证失败终止（credentialNotFound），Session 已清理。
        _ = try await waitForCondition(timeout: 15) {
            await MainActor.run {
                if case let .failed(error) = info.phase {
                    return error == .credentialNotFound
                }
                return false
            }
        }

        // 认证失败后 Session 已释放：Channel 打开必须明确失败。
        do {
            try await connection.openInteractiveShell(columns: 80, rows: 24)
            XCTFail("Session 已清理时不得成功打开 Shell Channel")
        } catch {
            let noChannel = await connection.hasOpenShellChannel
            XCTAssertFalse(noChannel, "失败路径不得残留 Channel")
        }

        await connection.disconnect()
        _ = await connectTask.result
    }

    // MARK: - 测试 G：空闲 CPU（Shell Channel 打开状态）

    func testG_IdleCPUWithOpenShellChannel() async throws {
        try await requireLocalSSHAndLiveCredential()

        let connection = try await makeAuthenticatedConnection()
        defer { Task { await connection.disconnect() } }

        try await connection.openInteractiveShell(columns: 120, rows: 35)

        // 读取循环等价物：连续 readChannelOutput 空闲轮询（与生产读取循环同机制）。
        let cpuStart = Self.processCPUSeconds()
        let wallStart = Date()

        while Date().timeIntervalSince(wallStart) < 30 {
            let output = try await connection.readChannelOutput()
            // 空闲时输出为空且非 EOF；不允许 CPU 忙等。
            if output.isEOF {
                break
            }
        }

        let cpuDelta = Self.processCPUSeconds() - cpuStart
        // 阈值校准说明：检测目标是 busy-loop（空闲时 CPU ≈ 墙钟，即 ≥ 25s）。
        // Debug 构建的 Swift 并发（actor 跳转 + GCD continuation）每次迭代有
        // 数十毫秒开销，30 次迭代 + 环境负载差异实测可达 ~2s（≈6.8% CPU）。
        // 5.0s（16.7%）阈值远离 busy-loop 特征，同时容忍 Debug 开销波动；
        // Release 构建实测远低于该值。
        XCTAssertLessThanOrEqual(
            cpuDelta,
            5.0,
            "空闲 30 秒 CPU 增量不得接近墙钟（实测 \(String(format: "%.3f", cpuDelta)) 秒），读取等待不得 busy-loop"
        )
    }

    // MARK: - 测试 H：20 × Connect → Terminal → Echo → Disconnect 资源泄漏

    func testH_TwentyConnectTerminalDisconnectCyclesNoLeak() async throws {
        try await requireLocalSSHAndLiveCredential()

        let fdProbeBefore = probeFileDescriptor()
        let threadsBefore = threadCount()
        let memoryBefore = residentMemoryBytes()

        for cycle in 1...20 {
            let connection = try await makeAuthenticatedConnection()

            try await connection.openInteractiveShell(columns: 120, rows: 35)
            try await connection.writeChannelInput(input("echo PHASE7_CYCLE_\(cycle)_\"OK\"\r"))
            let found = try await readUntil(
                connection,
                marker: Data("PHASE7_CYCLE_\(cycle)_OK".utf8),
                timeout: 15
            )
            XCTAssertTrue(found.containsMarker, "第 \(cycle) 轮 echo 必须成功")

            await connection.disconnect()
        }

        let fdProbeAfter = probeFileDescriptor()
        let threadsAfter = threadCount()
        let memoryAfter = residentMemoryBytes()

        XCTAssertLessThanOrEqual(
            fdProbeAfter - fdProbeBefore,
            2,
            "20 轮 Connect/Terminal/Disconnect 后 FD 不应持续增长"
        )
        XCTAssertLessThanOrEqual(
            threadsAfter - threadsBefore,
            4,
            "20 轮后线程数不应持续增长"
        )
        XCTAssertLessThanOrEqual(
            memoryAfter - memoryBefore,
            32 * 1024 * 1024,
            "20 轮后常驻内存不应持续增长"
        )
    }

    // MARK: - 辅助

    /// 把终端输入字符串转为原始 UTF-8 字节切片（与 SwiftTerm delegate send 的
    /// 数据形态一致）。
    private func input(_ text: String) -> ArraySlice<UInt8> {
        Array(text.utf8)[...]
    }

    /// 当前以当前用户运行的 sshd 进程 PID 集合（认证后的每连接子进程）。
    private static func userSSHDProcessIDs() -> Set<pid_t> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-u", NSUserName(), "-o", "pid=,comm="]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        var pids = Set<pid_t>()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = pid_t(fields[0]) else {
                continue
            }
            let command = String(fields[1])
            // 新版 macOS OpenSSH 的每连接会话进程名为 "sshd-session: user@tty"；
            // 旧版为 "sshd" / "/usr/sbin/sshd"。三种形态都要匹配。
            if command == "sshd" || command.hasSuffix("/sshd") || command.hasPrefix("sshd-session") {
                pids.insert(pid)
            }
        }
        return pids
    }

    /// 轮询等待文件出现并非空（远端即本机：Shell 副作用文件可在本地验证）。
    private func waitForFileContent(at path: String, timeout: TimeInterval) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: path),
                let text = String(data: data, encoding: .utf8), !text.isEmpty
            {
                return text
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 在已打开的 Shell Channel 上运行 tput 探针，把远端 PTY 尺寸写入文件。
    private func runTputProbe(connection: SSHConnection, probePath: String) async throws {
        try? FileManager.default.removeItem(atPath: probePath)
        try await connection.writeChannelInput(input("tput cols > \(probePath)\r"))
        try await connection.writeChannelInput(input("tput lines >> \(probePath)\r"))
    }

    /// 等待 tput 探针文件出现并解析 (cols, lines)。
    private func waitForTputProbe(
        at path: String,
        timeout: TimeInterval = 10
    ) async throws -> (columns: Int, rows: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if numbers.count >= 2 {
                    return (numbers[0], numbers[1])
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 轮询直到远端 tput 报告尺寸与 SwiftTerm 当前尺寸一致。
    ///
    /// sizeChanged → resizeChannelPTY 是异步链路：SwiftTerm 状态可能先于
    /// 远端 PTY 更新，固定延时不可靠，必须按收敛判定。
    private func waitForRemoteSizeConverged(
        service: RemoteTerminalService,
        connection: SSHConnection,
        probePath: String,
        timeout: TimeInterval = 12
    ) async throws -> (columns: Int, rows: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let target = await MainActor.run {
                (columns: service.session.columns, rows: service.session.rows)
            }
            try await runTputProbe(connection: connection, probePath: probePath)
            if let probed = try await waitForTputProbe(at: probePath, timeout: 6),
                probed.columns == target.columns,
                probed.rows == target.rows
            {
                return probed
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    private func makeInfo() -> SSHConnectionInfo {
        SSHConnectionInfo(
            hostID: UUID(),
            hostname: testHostname,
            port: testPort,
            username: testUsername
        )
    }

    private func makeConnection(
        info: SSHConnectionInfo,
        credentialID: UUID?,
        authenticationType: AuthenticationType = .password,
        privateKeyPath: String? = nil,
        privateKeyID: UUID? = nil,
        sessionTeardownOperations: SSHConnection.SessionTeardownOperations = .live
    ) -> SSHConnection {
        let configuration = SSHConnection.Configuration(
            hostID: info.hostID,
            hostname: info.hostname,
            port: info.port,
            username: info.username,
            authenticationType: authenticationType,
            credentialID: credentialID,
            privateKeyPath: privateKeyPath,
            privateKeyID: privateKeyID
        )
        return SSHConnection(
            configuration: configuration,
            info: info,
            knownHostService: knownHostService,
            sessionTeardownOperations: sessionTeardownOperations
        )
    }

    /// 建立完整认证连接（Trust Once + Password/Private Key）。
    private func makeAuthenticatedConnection(
        authenticationType: AuthenticationType = .password,
        privateKeyPath: String? = nil,
        privateKeyID: UUID? = nil,
        sessionTeardownOperations: SSHConnection.SessionTeardownOperations = .live
    ) async throws -> SSHConnection {
        let info = makeInfo()
        let credentialID: UUID? = authenticationType == .password ? liveCredentialID : nil
        let connection = makeConnection(
            info: info,
            credentialID: credentialID,
            authenticationType: authenticationType,
            privateKeyPath: privateKeyPath,
            privateKeyID: privateKeyID,
            sessionTeardownOperations: sessionTeardownOperations
        )

        Task { await connection.connect() }

        _ = try await waitForCondition(timeout: 20) {
            await MainActor.run {
                info.phase == .awaitingHostTrust || info.phase == .connected
            }
        }

        if await MainActor.run(body: { info.phase == .awaitingHostTrust }) {
            await connection.resolveHostTrust(.trustOnce)
        }

        let connected = try await waitForCondition(timeout: 20) {
            await MainActor.run { info.phase == .connected }
        }
        let finalPhaseText = await MainActor.run { info.phase.statusText }
        XCTAssertTrue(connected, "连接必须完成认证进入 connected，实际 \(finalPhaseText)")

        return connection
    }

    /// 持续读取 Channel 输出直到出现 marker（流式搜索，不无限累积）。
    private func readUntil(
        _ connection: SSHConnection,
        marker: Data,
        timeout: TimeInterval
    ) async throws -> (containsMarker: Bool, totalBytes: Int, rollingSnapshot: Data) {
        let deadline = Date().addingTimeInterval(timeout)
        var totalBytes = 0
        // 保留最近 64KB 用于跨块 marker 匹配；总字节数单独累计。
        var rolling = Data()

        while Date() < deadline {
            let output = try await connection.readChannelOutput()

            if !output.bytes.isEmpty {
                totalBytes += output.bytes.count
                rolling.append(contentsOf: output.bytes)
                if rolling.count > 65_536 {
                    rolling.removeFirst(rolling.count - 65_536)
                }
            }

            if rolling.range(of: marker) != nil {
                return (true, totalBytes, rolling)
            }

            if output.isEOF {
                return (false, totalBytes, rolling)
            }
        }

        return (false, totalBytes, rolling)
    }

    /// 等待 Channel EOF。
    private func waitForEOF(_ connection: SSHConnection, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let output = try await connection.readChannelOutput()
            if output.isEOF {
                return true
            }
        }
        return false
    }

    private func waitForCondition(
        timeout: TimeInterval,
        where predicate: () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return await predicate()
    }

    private func requireLocalSSH() async throws {
        let reachable = await isTCPPortOpen(host: testHostname, port: testPort)
        try XCTSkipUnless(
            reachable,
            "本机 127.0.0.1:22 未开放：请在 系统设置 → 通用 → 共享 → 远程登录 中开启"
        )
    }

    /// 私钥路径前置：本机 sshd 可达 + 测试 ed25519 私钥存在（脚本预置）。
    private func requireLocalSSHAndTestKey() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
        )
    }

    /// 用测试 ed25519 私钥建立完整认证连接（无 Passphrase，不触碰 Keychain）。
    private func makeAuthenticatedTestKeyConnection(
        sessionTeardownOperations: SSHConnection.SessionTeardownOperations = .live
    ) async throws -> SSHConnection {
        try await makeAuthenticatedConnection(
            authenticationType: .privateKey,
            privateKeyPath: TestKeys.ed25519NoPass,
            sessionTeardownOperations: sessionTeardownOperations
        )
    }

    private func requireLocalSSHAndLiveCredential() async throws {
        try await requireLocalSSH()
        let credentialExists = (try? await CredentialService.shared.readPassword(
            credentialID: liveCredentialID
        )) != nil
        try XCTSkipUnless(
            credentialExists,
            "缺少测试专用 Keychain 凭据：请使用 Scripts/run-ssh-tests.sh"
        )
    }

    private func isTCPPortOpen(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr = in_addr(s_addr: inet_addr(host))

                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: false)
                    return
                }
                defer { close(fd) }

                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.connect(
                            fd,
                            sockaddrPointer,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }

                var ready = false
                if result == 0 {
                    ready = true
                } else if errno == EINPROGRESS {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, 2000) > 0 {
                        var socketError: Int32 = 0
                        var errorLength = socklen_t(MemoryLayout<Int32>.size)
                        let status = getsockopt(
                            fd,
                            SOL_SOCKET,
                            SO_ERROR,
                            &socketError,
                            &errorLength
                        )
                        ready = status == 0 && socketError == 0
                    }
                }

                continuation.resume(returning: ready)
            }
        }
    }

    private func probeFileDescriptor() -> Int32 {
        let fd = open("/dev/null", O_RDONLY)
        let value = fd
        if fd >= 0 {
            close(fd)
        }
        return value
    }

    private func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        let kr = task_threads(mach_task_self_, &threads, &count)
        guard kr == KERN_SUCCESS, let threads else { return -1 }

        let size = vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: threads)),
            size
        )
        return Int(count)
    }

    private func residentMemoryBytes() -> Int64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int64(info.resident_size)
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
