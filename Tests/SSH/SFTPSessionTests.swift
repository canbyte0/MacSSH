import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 9 SFTP 底层真实测试：SSHConnection actor 上的 SFTP 扩展
/// （子系统初始化 / realpath / 列举 / 错误映射 / 句柄与拆除）
/// 经真实本机 sshd + 真实 libssh2 验证。
///
/// 前置：系统设置 → 共享 → 远程登录 已开启，并经
/// `Scripts/run-ssh-tests.sh` 生成测试私钥与 Phase 9 SFTP 夹具。
@MainActor
final class SFTPSessionTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    /// 测试专用无 Passphrase 私钥（脚本生成，退出删除）。
    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
    }

    /// Phase 9 夹具根路径交接文件（脚本写入，仅含路径）。
    private static let fixturePathFile = "/tmp/macssh_phase9_fixture_path"

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

    // MARK: - 测试 A：子系统初始化幂等

    /// 已认证连接上初始化一次即成功；重复调用不重复握手；
    /// 断开后子系统随连接释放。
    func testA_SubsystemInitIsIdempotentAndReleasedOnDisconnect() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()

        try await connection.openSFTPSubsystemIfNeeded()
        var hasSubsystem = await connection.hasSFTPSubsystem
        XCTAssertTrue(hasSubsystem, "已认证连接上 sftp_init 必须成功")

        var initCount = await connection.sftpSubsystemInitCount
        XCTAssertEqual(initCount, 1)

        // 幂等：再次调用不重新初始化（计数不变）。
        try await connection.openSFTPSubsystemIfNeeded()
        initCount = await connection.sftpSubsystemInitCount
        XCTAssertEqual(initCount, 1, "重复初始化必须去重，绝不重复握手")

        await connection.disconnect()
        hasSubsystem = await connection.hasSFTPSubsystem
        XCTAssertFalse(hasSubsystem, "断开后 SFTP 子系统必须随连接释放")
    }

    // MARK: - 测试 B：初始目录来自 realpath(".")

    /// 初始目录绝不硬编码 `/` 或 `~`：`realpath(".")` 返回登录目录
    /// （本机为用户 HOME），为规范绝对路径。
    func testB_RealpathInitialDirectoryIsAbsoluteHome() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let initial = try await connection.sftpRealpath(".")
        XCTAssertTrue(initial.hasPrefix("/"), "realpath(\".\") 必须为绝对路径，实际 \(initial)")
        XCTAssertFalse(initial.contains("~"), "初始目录绝不包含未展开的 ~")
        XCTAssertFalse(initial.isEmpty)

        let resolvedHome = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath().path
        let resolvedInitial = URL(fileURLWithPath: initial)
            .resolvingSymlinksInPath().path
        XCTAssertEqual(
            resolvedInitial,
            resolvedHome,
            "本机 sshd 的登录目录应为用户 HOME"
        )

        await connection.disconnect()
    }

    // MARK: - 测试 C：夹具列举完整性与元数据

    /// 列举夹具根目录：全部条目（含隐藏 / 中文 / emoji / 空格 / 符号链接）
    /// 完整可见，`.` / `..` 被过滤，类型按 attributes 标志识别。
    func testC_ListFixtureRootCompleteEntriesAndMetadata() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let entries = try await connection.sftpListDirectory(fixture)
        let names = Set(entries.map(\.name))

        let expected = expectedFixtureNames()
        for name in expected {
            XCTAssertTrue(names.contains(name), "夹具条目缺失：\(name)")
        }
        XCTAssertFalse(names.contains("."), "`.` 必须过滤")
        XCTAssertFalse(names.contains(".."), "`..` 必须过滤")

        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["dir-a"]?.kind, .directory)
        XCTAssertEqual(byName["empty"]?.kind, .directory)
        XCTAssertEqual(byName["file.txt"]?.kind, .regularFile)
        XCTAssertEqual(byName["symlink"]?.kind, .symlink, "符号链接必须按 permissions 类型位识别")
        XCTAssertEqual(byName[".hidden"]?.kind, .regularFile)

        // 大小与本地文件系统一致（本机夹具，可对照）。
        let fileEntry = try XCTUnwrap(byName["file.txt"])
        let localSize = try FileManager.default
            .attributesOfItem(atPath: fixture + "/file.txt")[.size] as? NSNumber
        XCTAssertEqual(
            fileEntry.sizeBytes,
            localSize.map { UInt64($0.uint64Value) },
            "SFTP 回报大小必须与真实文件一致"
        )

        // 权限位与本地一致（取低 12 位：含 setuid/sticky）。
        let localPermissions = try FileManager.default
            .attributesOfItem(atPath: fixture + "/file.txt")[.posixPermissions] as? NSNumber
        if let localPermissions {
            XCTAssertEqual(
                fileEntry.permissions.map { $0 & 0o7777 },
                UInt32(localPermissions.intValue) & 0o7777,
                "permissions 必须按 attributes 标志回显真实模式位"
            )
        }

        // 修改时间合理（夹具刚创建，应在最近一天内）。
        if let modified = fileEntry.modifiedAt {
            XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 86_400)
        }

        await connection.disconnect()
    }

    // MARK: - 测试 D：子目录导航

    /// 列举子目录（路径拼接不产生 `//`，语义由服务器决定）。
    func testD_ListSubdirectoryAfterJoin() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let target = RemotePath.join(fixture, child: "dir-a")
        XCTAssertEqual(target, fixture + "/dir-a", "join 绝不产生双斜杠")

        let entries = try await connection.sftpListDirectory(target)
        XCTAssertEqual(entries.map(\.name), ["nested.txt"])

        await connection.disconnect()
    }

    // MARK: - 测试 E：不存在路径为业务错误

    /// noSuchPath 是业务错误：不崩溃、不断开连接，后续操作继续可用。
    func testE_NoSuchPathIsBusinessErrorAndConnectionSurvives() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        do {
            _ = try await connection.sftpListDirectory(fixture + "/no-such-directory")
            XCTFail("不存在路径必须失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .noSuchPath)
        }

        var alive = await connection.hasLiveSession
        XCTAssertTrue(alive, "业务错误绝不断开健康连接")

        // 后续列举继续可用。
        let entries = try await connection.sftpListDirectory(fixture)
        XCTAssertFalse(entries.isEmpty)

        await connection.disconnect()
        alive = await connection.hasLiveSession
        XCTAssertFalse(alive)
    }

    // MARK: - 测试 F：权限拒绝为业务错误

    /// permissionDenied（chmod 000 目录）：业务错误，不断开连接。
    func testF_PermissionDeniedIsBusinessErrorAndConnectionSurvives() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        do {
            _ = try await connection.sftpListDirectory(fixture + "/restricted")
            XCTFail("权限拒绝目录列举必须失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .permissionDenied)
        }

        let alive = await connection.hasLiveSession
        XCTAssertTrue(alive, "权限拒绝绝不断开连接")

        let entries = try await connection.sftpListDirectory(fixture)
        XCTAssertTrue(entries.contains { $0.name == "restricted" })

        await connection.disconnect()
    }

    // MARK: - 测试 G：长文件名完整回显

    /// 200 字符文件名：缓冲增长路径下完整回显，绝不静默截断。
    func testG_LongFilenameIsNotTruncated() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let longName = String(repeating: "n", count: 200) + ".txt"
        let entries = try await connection.sftpListDirectory(fixture)
        XCTAssertTrue(
            entries.contains { $0.name == longName },
            "200 字符文件名必须完整回显（不截断、不替换）"
        )

        await connection.disconnect()
    }

    // MARK: - 测试 H：1000 条目目录性能

    /// 1000 条目目录单次列举完整且有界（协作调度 + EAGAIN 挂起，
    /// 无忙等）。阈值取宽松上限，主要验证完整性与无异常耗时。
    func testH_ThousandEntryDirectoryListsCompletelyAndPromptly() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let start = Date()
        let entries = try await connection.sftpListDirectory(fixture + "/big")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(entries.count, 1_000, "1000 条目必须全部返回")
        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.contains("f-0001.txt"))
        XCTAssertTrue(names.contains("f-1000.txt"))
        XCTAssertLessThan(elapsed, 15, "1000 条目列举耗时异常：\(elapsed) 秒")

        var handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(handles, 0, "列举结束后不得遗留打开的目录句柄")

        await connection.disconnect()
        handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(handles, 0)
    }

    // MARK: - 测试 I：列举进行中连接断开

    /// 列举 1000 条目期间并发断开：要么列举先完成，要么以业务错误
    /// 结束——绝不崩溃、绝不 double-close、句柄全部释放。
    func testI_DisconnectDuringListingNoCrashNoLeak() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let listing = Task { try await connection.sftpListDirectory(fixture + "/big") }
        try await Task.sleep(nanoseconds: 20_000_000)
        await connection.disconnect()

        do {
            let entries = try await listing.value
            // 列举抢在断开前完成也合法：断言此后资源仍全部释放。
            XCTAssertEqual(entries.count, 1_000)
        } catch let error as SFTPError {
            XCTAssertTrue(
                error == .connectionLost || error == .operationCancelled,
                "列举中断开应得到业务错误，实际 \(error)"
            )
        } catch is CancellationError {
            // 取消语义同样可接受。
        }

        let handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(handles, 0, "断开后不得遗留任何目录句柄")
        let hasSubsystem = await connection.hasSFTPSubsystem
        XCTAssertFalse(hasSubsystem)
    }

    // MARK: - 测试 J：拆除释放全部 SFTP 资源

    /// 多次列举后断开：子系统与全部句柄释放，幂等无泄漏。
    func testJ_TeardownReleasesAllSFTPResources() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        _ = try await connection.sftpListDirectory(fixture)
        _ = try await connection.sftpListDirectory(fixture + "/dir-a")
        _ = try await connection.sftpListDirectory(fixture + "/big")

        await connection.disconnect()

        let hasSubsystem = await connection.hasSFTPSubsystem
        let handles = await connection.openSFTPDirectoryHandleCount
        let alive = await connection.hasLiveSession
        XCTAssertFalse(hasSubsystem)
        XCTAssertEqual(handles, 0)
        XCTAssertFalse(alive)

        // 幂等：再次断开不崩溃。
        await connection.disconnect()
    }

    // MARK: - 测试 K：Terminal 与 SFTP 共存同一 Session

    /// 同一 `LIBSSH2_SESSION` 上：Shell Channel 打开在先，SFTP 初始化
    /// 与列举不干扰 Terminal；列举完成后 Shell 输入输出仍然正常。
    func testK_TerminalAndSFTPCoexistOnSameSession() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()

        // 先开 Shell（Terminal 在场）。
        try await connection.openInteractiveShell(columns: 80, rows: 24)

        // 再初始化 SFTP 并列举——绝不重建登录、绝不干扰 Shell。
        try await connection.openSFTPSubsystemIfNeeded()
        let entries = try await connection.sftpListDirectory(fixture)
        XCTAssertFalse(entries.isEmpty)

        let initCount = await connection.sftpSubsystemInitCount
        XCTAssertEqual(initCount, 1, "SFTP 子系统只初始化一次（不重建登录）")

        // Terminal 仍然可用：回显命令输出必须可达。
        let marker = "macssh-p9-coexist-\(UUID().uuidString.prefix(8))"
        try await connection.writeChannelInput("echo \(marker)\n".utf8ArraySlice)
        let sawMarker = try await readUntilMarker(connection, marker: marker, timeout: 10)
        XCTAssertTrue(sawMarker, "SFTP 列举后 Terminal 必须仍然正常工作")

        await connection.disconnect()
    }

    // MARK: - 测试 L：Reconnect 重建、绝不复用旧子系统

    /// 旧连接断开后，在全新连接上重新初始化成功；
    /// 旧子系统已随旧连接释放，绝不复用。
    func testL_ReconnectRebuildsSubsystemOnNewSession() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let first = try await makeAuthenticatedTestKeyConnection()
        try await first.openSFTPSubsystemIfNeeded()
        _ = try await first.sftpListDirectory(fixture)
        await first.disconnect()

        let firstHasSubsystem = await first.hasSFTPSubsystem
        XCTAssertFalse(firstHasSubsystem, "旧连接的 SFTP 子系统必须已释放")

        let second = try await makeAuthenticatedTestKeyConnection()
        try await second.openSFTPSubsystemIfNeeded()
        let secondHasSubsystem = await second.hasSFTPSubsystem
        XCTAssertTrue(secondHasSubsystem, "全新连接必须能重新初始化 SFTP")

        let entries = try await second.sftpListDirectory(fixture)
        XCTAssertFalse(entries.isEmpty)

        await second.disconnect()
    }

    // MARK: - 测试 M：未初始化 / 已断开时的失败语义

    /// 连接已断开后发起 SFTP 操作：得到业务错误，不崩溃、不悬挂。
    func testM_SFTPOperationsAfterDisconnectFailGracefully() async throws {
        try await requireLocalSSHAndTestKey()

        let connection = try await makeAuthenticatedTestKeyConnection()
        await connection.disconnect()

        do {
            try await connection.openSFTPSubsystemIfNeeded()
            XCTFail("已断开连接上的 SFTP 初始化必须失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .connectionLost)
        }

        do {
            _ = try await connection.sftpListDirectory("/")
            XCTFail("已断开连接上的列举必须失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .connectionLost)
        }
    }

    // MARK: - 测试 N：列举在 readdir EAGAIN 窗口挂起时并发断开（P1 整改）

    /// P1 竞态窗口一：列举因 EAGAIN 挂起在 readdir 窗口（测试接缝的
    /// 确定性等价）。此时并发 `disconnect()`：拆除必须停在排空屏障
    /// （绝不摘走在途句柄、绝不 closedir、绝不 shutdown）；释放后列举
    /// 以业务错误退出并由自己完成唯一一次关闭。连续运行 10 次：
    /// 每次都必须无 double-close、无崩溃、无悬挂、无残留句柄。
    func testN_DisconnectWhileListingSuspendedInReaddirWindow() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        for iteration in 1...10 {
            try await runReaddirWindowRace(fixture: fixture, iteration: iteration)
            // 迭代间让本机 sshd 回收未认证连接额度，避免限流噪音。
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func runReaddirWindowRace(fixture: String, iteration: Int) async throws {
        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let gate = RaceGate()
        await connection.setTestSFTPAfterHandleOpenHook { await gate.arriveAndWaitRelease() }

        // 列举：句柄已打开并登记，停在 readdir 窗口（EAGAIN 等价）。
        let target = RemotePath.join(fixture, child: "dir-a")
        let listing = Task { try await connection.sftpListDirectory(target) }

        let arrived = try await waitForCondition(timeout: 15) { await gate.hasArrived() }
        XCTAssertTrue(arrived, "迭代 \(iteration)：列举必须到达 readdir 窗口门闩")

        // 并发断开：拆除必须停在排空屏障——在途句柄不得被摘除、
        // 不得被关闭、子系统不得被 shutdown。
        let disconnectTask = Task { await connection.disconnect() }
        try await Task.sleep(nanoseconds: 300_000_000)

        var subsystemAlive = await connection.hasSFTPSubsystem
        XCTAssertTrue(
            subsystemAlive,
            "迭代 \(iteration)：门闩释放前拆除不得抢先 shutdown"
        )
        var handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(
            handles, 1,
            "迭代 \(iteration)：拆除不得摘除在途列举的句柄"
        )

        // 释放：列举在下一校验点以业务错误退出，认领并关闭自己持有的
        // 句柄（唯一关闭方）；随后拆除完成排空并收尾。
        await gate.release()

        do {
            _ = try await listing.value
            XCTFail("迭代 \(iteration)：断开已请求，列举必须以业务错误退出")
        } catch let error as SFTPError {
            XCTAssertEqual(
                error, .connectionLost,
                "迭代 \(iteration)：应为 connectionLost，实际 \(error)"
            )
        }

        await disconnectTask.value

        subsystemAlive = await connection.hasSFTPSubsystem
        XCTAssertFalse(subsystemAlive, "迭代 \(iteration)：断开后子系统必须已释放")
        handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(handles, 0, "迭代 \(iteration)：不得遗留任何目录句柄")

        let opens = await connection.sftpDirectoryHandleOpenCount
        let closes = await connection.sftpDirectoryHandleCloseCount
        XCTAssertEqual(opens, 1, "迭代 \(iteration)：应恰好打开 1 个目录句柄")
        XCTAssertEqual(
            closes, opens,
            "迭代 \(iteration)：关闭数必须等于打开数（无 double-close、无残留）"
        )

        await connection.setTestSFTPAfterHandleOpenHook(nil)
    }

    // MARK: - 测试 O：收尾 closedir 在 EAGAIN 窗口挂起时并发断开（P1 整改）

    /// P1 竞态窗口二：列举完成、关闭所有权已认领，收尾 closedir 因
    /// EAGAIN 挂起（测试接缝的确定性等价）。此时并发 `disconnect()`：
    /// `libssh2_sftp_shutdown` 绝不得在 closedir 在途期间执行
    /// （否则 use-after-free）。释放后列举正常返回，拆除随后完成。
    /// 连续运行 10 次。
    func testO_DisconnectWhileClosedirSuspendedInCloseWindow() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        for iteration in 1...10 {
            try await runClosedirWindowRace(fixture: fixture, iteration: iteration)
            // 迭代间让本机 sshd 回收未认证连接额度，避免限流噪音。
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func runClosedirWindowRace(fixture: String, iteration: Int) async throws {
        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let gate = RaceGate()
        await connection.setTestSFTPBeforeHandleCloseHook { await gate.arriveAndWaitRelease() }

        let target = RemotePath.join(fixture, child: "dir-a")
        let listing = Task { try await connection.sftpListDirectory(target) }

        let arrived = try await waitForCondition(timeout: 15) { await gate.hasArrived() }
        XCTAssertTrue(arrived, "迭代 \(iteration)：收尾 closedir 必须到达门闩")

        // 此刻列举侧已认领关闭所有权：句柄已摘除，但 closedir 未执行，
        // 在途计数仍为 1——拆除必须因此停在排空屏障。
        var inFlight = await connection.inFlightSFTPListingCount
        XCTAssertEqual(inFlight, 1, "迭代 \(iteration)：closedir 在途即在途列举未结束")
        var handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(handles, 0, "迭代 \(iteration)：认领后句柄应已摘除")

        // 并发断开：closedir 在途期间绝不允许 libssh2_sftp_shutdown。
        let disconnectTask = Task { await connection.disconnect() }
        try await Task.sleep(nanoseconds: 300_000_000)

        var subsystemAlive = await connection.hasSFTPSubsystem
        XCTAssertTrue(
            subsystemAlive,
            "迭代 \(iteration)：closedir 在途时绝不得执行 shutdown"
        )

        // 释放：closedir 完成，列举正常返回；拆除排空后收尾。
        await gate.release()

        let entries = try await listing.value
        XCTAssertEqual(
            entries.map(\.name), ["nested.txt"],
            "迭代 \(iteration)：列举必须完整成功"
        )

        await disconnectTask.value

        subsystemAlive = await connection.hasSFTPSubsystem
        XCTAssertFalse(subsystemAlive, "迭代 \(iteration)：断开后子系统必须已释放")
        handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(handles, 0, "迭代 \(iteration)：不得遗留任何目录句柄")
        inFlight = await connection.inFlightSFTPListingCount
        XCTAssertEqual(inFlight, 0, "迭代 \(iteration)：在途计数必须归零")

        let opens = await connection.sftpDirectoryHandleOpenCount
        let closes = await connection.sftpDirectoryHandleCloseCount
        XCTAssertEqual(opens, 1, "迭代 \(iteration)：应恰好打开 1 个目录句柄")
        XCTAssertEqual(
            closes, opens,
            "迭代 \(iteration)：关闭数必须等于打开数（无 double-close、无残留）"
        )

        await connection.setTestSFTPBeforeHandleCloseHook(nil)
    }

    // MARK: - 测试 P：并发列举经串行门严格串行化（第二轮整改）

    /// P1 竞态窗口三（第二轮整改）：第一个列举因 EAGAIN 挂起在 readdir
    /// 窗口（测试接缝的确定性等价），持有串行门；此时第二个并发列举
    /// 必须排在门外——第一个列举**完整收尾（含 closedir）**之前，
    /// 第二个绝不发起任何 `libssh2` 调用（打开计数保持 1）。释放后
    /// 第二个列举完整得到自己目标目录的内容：后一请求绝不接走前一
    /// 请求的响应。连续运行 10 次。
    func testP_ConcurrentListingsSerializeOnOperationGate() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        for iteration in 1...10 {
            try await runGateSerializationRace(fixture: fixture, iteration: iteration)
            // 迭代间让本机 sshd 回收未认证连接额度，避免限流噪音。
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func runGateSerializationRace(fixture: String, iteration: Int) async throws {
        let connection = try await makeAuthenticatedTestKeyConnection()
        try await connection.openSFTPSubsystemIfNeeded()

        let gate = RaceGate()
        await connection.setTestSFTPAfterHandleOpenHook { await gate.arriveAndWaitRelease() }

        // 第一个列举：挂起在 readdir 窗口（EAGAIN 等价），持有串行门。
        let targetOne = RemotePath.join(fixture, child: "dir-a")
        let firstListing = Task { try await connection.sftpListDirectory(targetOne) }

        let arrived = try await waitForCondition(timeout: 15) { await gate.hasArrived() }
        XCTAssertTrue(arrived, "迭代 \(iteration)：第一个列举必须到达 readdir 窗口门闩")

        // 第二个并发列举：连接层直接并发调用，必须排在串行门外。
        let targetTwo = RemotePath.join(fixture, child: "dir-b")
        let secondListing = Task { try await connection.sftpListDirectory(targetTwo) }

        // 确定性等待：第二个列举已登记在途计数（排在门外），
        // 但尚未进入 libssh2——打开计数保持 1、登记中只有第一个句柄。
        let queued = try await waitForCondition(timeout: 15) {
            await connection.inFlightSFTPListingCount == 2
        }
        XCTAssertTrue(queued, "迭代 \(iteration)：第二个列举必须已登记并排队")

        var opens = await connection.sftpDirectoryHandleOpenCount
        XCTAssertEqual(
            opens, 1,
            "迭代 \(iteration)：第一个列举收尾前第二个绝不 opendir"
        )
        var handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(
            handles, 1,
            "迭代 \(iteration)：登记中不得出现第二个列举的句柄"
        )

        // 释放：第一个列举完整收尾（含 closedir）后，串行门移交给第二个。
        await gate.release()

        let firstEntries = try await firstListing.value
        XCTAssertEqual(
            firstEntries.map(\.name), ["nested.txt"],
            "迭代 \(iteration)：第一个列举必须完整成功"
        )

        // dir-b 为空目录：第二个列举得到空列表——条目来自自己的目标，
        // 绝非接走第一个列举的响应。
        let secondEntries = try await secondListing.value
        XCTAssertTrue(
            secondEntries.isEmpty,
            "迭代 \(iteration)：第二个列举必须是 dir-b 自身内容（空目录）"
        )

        opens = await connection.sftpDirectoryHandleOpenCount
        XCTAssertEqual(opens, 2, "迭代 \(iteration)：两次列举共打开 2 个句柄")
        let closes = await connection.sftpDirectoryHandleCloseCount
        XCTAssertEqual(
            closes, opens,
            "迭代 \(iteration)：关闭数必须等于打开数（无 double-close、无残留）"
        )
        handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(handles, 0, "迭代 \(iteration)：不得遗留打开的目录句柄")
        let inFlight = await connection.inFlightSFTPListingCount
        XCTAssertEqual(inFlight, 0, "迭代 \(iteration)：在途计数必须归零")

        await connection.setTestSFTPAfterHandleOpenHook(nil)
        await connection.disconnect()
    }

    // MARK: - 辅助

    /// 确定性竞态门闩：列举 / 关闭任务到达后停在此处等待释放；
    /// 测试在释放前断言拆除被排空屏障扣住（测试 N / O）。
    private actor RaceGate {
        private var arrived = false
        private var released = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func arriveAndWaitRelease() async {
            arrived = true
            if released {
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseContinuation = continuation
            }
        }

        func hasArrived() -> Bool {
            arrived
        }

        func release() {
            released = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    /// 夹具根路径（脚本写入的交接文件）；缺失即跳过（诚实报告环境限制）。
    private func requireFixture() throws -> String {
        let exists = FileManager.default.fileExists(atPath: Self.fixturePathFile)
        try XCTSkipUnless(exists, "缺少 Phase 9 夹具交接文件：请使用 Scripts/run-ssh-tests.sh")
        let path = try String(contentsOfFile: Self.fixturePathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(!path.isEmpty, "Phase 9 夹具交接文件为空")
        return path
    }

    /// 夹具根目录预期条目（与脚本创建保持一致）。
    private func expectedFixtureNames() -> [String] {
        [
            "dir-a",
            "dir-b",
            "empty",
            "restricted",
            "big",
            "file.txt",
            "中文.txt",
            "emoji-😀.txt",
            "hello world.txt",
            ".hidden",
            "symlink",
            String(repeating: "n", count: 200) + ".txt",
        ]
    }

    private func makeInfo() -> SSHConnectionInfo {
        SSHConnectionInfo(
            hostID: UUID(),
            hostname: testHostname,
            port: testPort,
            username: testUsername
        )
    }

    private func makeConnection(info: SSHConnectionInfo) -> SSHConnection {
        let configuration = SSHConnection.Configuration(
            hostID: info.hostID,
            hostname: info.hostname,
            port: info.port,
            username: info.username,
            authenticationType: .privateKey,
            credentialID: nil,
            privateKeyPath: TestKeys.ed25519NoPass,
            privateKeyID: nil
        )
        return SSHConnection(
            configuration: configuration,
            info: info,
            knownHostService: knownHostService,
            sessionTeardownOperations: .live
        )
    }

    /// 用测试 ed25519 私钥建立完整认证连接（不触碰 Keychain）。
    ///
    /// 本机 sshd 对数十次连续建连可能瞬时限流（握手期 socket 被断开，
    /// 建连以 .failed 收尾）：这是环境噪音而非产品缺陷，有限重试 3 次、
    /// 退避 0.5 秒；成功建连后的全部竞态断言不受任何弱化。
    private func makeAuthenticatedTestKeyConnection() async throws -> SSHConnection {
        for _ in 1...3 {
            let info = makeInfo()
            let connection = makeConnection(info: info)

            Task { await connection.connect() }

            let reachedTerminalPhase = try await waitForCondition(timeout: 20) {
                await MainActor.run {
                    switch info.phase {
                    case .awaitingHostTrust, .connected:
                        return true
                    case .failed(_):
                        return true
                    default:
                        return false
                    }
                }
            }

            if reachedTerminalPhase, case .failed(_) = info.phase {
                // 限流噪音：退避后重建（旧连接已在失败路径释放全部资源）。
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            XCTAssertTrue(
                reachedTerminalPhase,
                "连接必须到达 Trust 或 connected"
            )

            if await MainActor.run(body: { info.phase == .awaitingHostTrust }) {
                await connection.resolveHostTrust(.trustOnce)
            }

            let connected = try await waitForCondition(timeout: 20) {
                await MainActor.run { info.phase == .connected }
            }
            XCTAssertTrue(connected, "测试私钥连接必须完成认证")

            return connection
        }

        throw SSHError.connectionLost
    }

    /// 读取 Channel 输出直到出现 marker。
    private func readUntilMarker(
        _ connection: SSHConnection,
        marker: String,
        timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let markerData = Data(marker.utf8)
        var rolling = Data()

        while Date() < deadline {
            let output = try await connection.readChannelOutput()
            if !output.bytes.isEmpty {
                rolling.append(contentsOf: output.bytes)
                if rolling.count > 65_536 {
                    rolling.removeFirst(rolling.count - 65_536)
                }
            }
            if rolling.range(of: markerData) != nil {
                return true
            }
            if output.isEOF {
                return false
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

    private func requireLocalSSHAndTestKey() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-ssh-tests.sh 生成"
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

                if result == 0 {
                    continuation.resume(returning: true)
                    return
                }

                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let polled = poll(&pollFD, 1, 100)
                    if polled > 0 {
                        var errorValue: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &errorValue, &length)
                        continuation.resume(returning: errorValue == 0)
                        return
                    }
                }
                continuation.resume(returning: false)
            }
        }
    }
}

private extension String {
    /// Shell 输入辅助：UTF-8 字节切片。
    var utf8ArraySlice: ArraySlice<UInt8> {
        ArraySlice(Array(utf8))
    }
}
