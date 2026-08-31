import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 9 SFTP 业务层真实测试：SFTPService（状态 / 导航原子性 /
/// 竞态防护 / 生命周期）与 ManagedTerminalSession 面板接入，
/// 经真实本机 sshd + 真实 libssh2 验证。
///
/// 前置：系统设置 → 共享 → 远程登录 已开启，并经
/// `Scripts/run-ssh-tests.sh` 生成测试私钥与 Phase 9 SFTP 夹具。
@MainActor
final class SFTPServiceTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
    }

    private static let fixturePathFile = "/tmp/macssh_phase9_fixture_path"

    private var knownHostContainer: ModelContainer!
    private var knownHostService: KnownHostService!

    /// 本测试打开的连接；tearDown 统一断开，避免泄漏。
    private var openConnections: [SSHConnection] = []

    override func setUp() async throws {
        continueAfterFailure = false
        openConnections = []
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        knownHostContainer = try ModelContainer(for: schema, configurations: [configuration])
        knownHostService = KnownHostService(modelContainer: knownHostContainer)
    }

    override func tearDown() async throws {
        for connection in openConnections {
            await connection.disconnect()
        }
        openConnections.removeAll()
        await MainActor.run { knownHostService.removeAll() }
        knownHostService = nil
        knownHostContainer = nil
    }

    // MARK: - 测试 A：启动加载初始目录

    /// startIfNeeded：子系统初始化 + `realpath(".")` + 列举；
    /// 得到绝对路径与非空条目（用户 HOME 必有内容）。
    func testA_StartLoadsInitialDirectory() async throws {
        try await requireLocalSSHAndTestKey()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.startIfNeeded()

        let loaded = try await waitForCondition(timeout: 20) { service.phase == .loaded }
        XCTAssertTrue(loaded, "启动后必须到达 loaded，实际 \(service.phase)")
        XCTAssertTrue(service.currentPath.hasPrefix("/"))
        XCTAssertFalse(service.entries.isEmpty, "HOME 目录必有内容")

        // 幂等：再次 startIfNeeded 不触发重复加载。
        let pathBefore = service.currentPath
        service.startIfNeeded()
        XCTAssertEqual(service.currentPath, pathBefore)
    }

    // MARK: - 测试 B：导航原子提交

    /// 进入子目录成功后路径与条目一起更新；Parent 回到原目录。
    func testB_NavigateIntoChildAndParentCommitAtomically() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: fixture)
        try await waitForLoaded(service)

        let dirA = try XCTUnwrap(service.entries.first { $0.name == "dir-a" })
        XCTAssertTrue(dirA.isDirectory)

        service.navigate(into: dirA)
        try await waitForConditionAssert { service.currentPath == fixture + "/dir-a" }
        XCTAssertEqual(service.entries.map(\.name), ["nested.txt"])

        // 非目录条目拒绝导航（文件 / 符号链接不进入）。
        let nested = try XCTUnwrap(service.entries.first { $0.name == "nested.txt" })
        service.navigate(into: nested)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.currentPath, fixture + "/dir-a", "文件条目绝不触发导航")

        service.goParent()
        try await waitForConditionAssert { service.currentPath == fixture }
        XCTAssertTrue(service.entries.contains { $0.name == "file.txt" })
    }

    // MARK: - 测试 C：Unicode / 隐藏 / 符号链接条目

    /// 中文、emoji、空格、隐藏文件与符号链接全部可见且类型正确。
    func testC_UnicodeHiddenAndSymlinkEntriesVisible() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: fixture)
        try await waitForLoaded(service)

        let byName = Dictionary(uniqueKeysWithValues: service.entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["中文.txt"]?.kind, .regularFile, "中文文件名必须完整可见")
        XCTAssertEqual(byName["emoji-😀.txt"]?.kind, .regularFile, "emoji 文件名必须完整可见")
        XCTAssertEqual(byName["hello world.txt"]?.kind, .regularFile, "空格文件名必须完整可见")
        XCTAssertEqual(byName[".hidden"]?.kind, .regularFile, "隐藏文件默认可见")
        XCTAssertEqual(byName["symlink"]?.kind, .symlink, "符号链接必须识别")

        XCTAssertNil(byName["."])
        XCTAssertNil(byName[".."])

        // 排序一次完成：目录优先，随后本地化自然序。
        let firstDirIndex = service.entries.firstIndex { $0.isDirectory }
        let lastDirIndex = service.entries.lastIndex { $0.isDirectory }
        if let firstDirIndex, let lastDirIndex {
            let firstFileIndex = service.entries.firstIndex { !$0.isDirectory }
            if let firstFileIndex {
                XCTAssertLessThan(lastDirIndex, firstFileIndex, "目录必须整体排在文件之前")
                XCTAssertNotNil(firstDirIndex)
            }
        }
    }

    // MARK: - 测试 D：导航失败保持原状态

    /// 进入权限拒绝目录：业务错误展示，原路径与原列表保持不变，
    /// 连接不断开（绝不自动断开）。
    func testD_NavigateFailureKeepsPriorState() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: fixture)
        try await waitForLoaded(service)

        let entriesBefore = service.entries

        let restricted = try XCTUnwrap(service.entries.first { $0.name == "restricted" })
        service.navigate(into: restricted)

        let failed = try await waitForCondition(timeout: 20) {
            if case let .failed(error) = service.phase {
                return error == .permissionDenied
            }
            return false
        }
        XCTAssertTrue(failed, "权限拒绝必须映射为业务错误，实际 \(service.phase)")

        XCTAssertEqual(service.currentPath, fixture, "失败后路径保持不变")
        XCTAssertEqual(service.entries, entriesBefore, "失败后列表保持不变")

        let alive = await connection.hasLiveSession
        XCTAssertTrue(alive, "业务错误绝不断开连接")

        // Retry 语义（refresh 文档语义）：失败态下 Retry 重新加载
        // **保留的当前目录**——权限拒绝是确定性的，Retry 不重撞失败目标，
        // 而是恢复可用列表；必须不崩溃、不断开连接。
        service.refresh()
        let recovered = try await waitForCondition(timeout: 20) {
            service.phase == .loaded
        }
        XCTAssertTrue(recovered, "Retry 后必须回到 loaded，实际 \(service.phase)")
        XCTAssertEqual(service.currentPath, fixture, "Retry 后路径仍为保留路径")
        XCTAssertEqual(service.entries, entriesBefore, "Retry 后列表恢复原列表")
    }

    // MARK: - 测试 E：快速导航竞态——最后请求获胜

    /// 连续发起多个加载请求：过期结果绝不覆盖新结果（generation 防护）。
    func testE_RapidNavigationLastRequestWins() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: fixture)
        try await waitForLoaded(service)

        // 连续三次请求：中间目录只是过客。
        service.loadAbsolute(path: fixture + "/dir-a")
        service.loadAbsolute(path: fixture + "/dir-b")
        service.loadAbsolute(path: fixture + "/empty")

        try await waitForLoaded(service)
        try await waitForConditionAssert { service.currentPath == fixture + "/empty" }
        XCTAssertTrue(service.entries.isEmpty, "最终必须是最后请求的目录内容")
    }

    // MARK: - 测试 F：根目录 Parent 禁用

    /// `/` 的 parent 仍是 `/`；isAtRoot 为真（UI 据此禁用按钮）。
    func testF_ParentAtRootIsNoop() async throws {
        try await requireLocalSSHAndTestKey()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: "/")
        try await waitForLoaded(service)

        XCTAssertTrue(service.isAtRoot)

        service.goParent()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.currentPath, "/", "根目录 Parent 必须为空操作")
        XCTAssertTrue(service.isAtRoot)
    }

    // MARK: - 测试 G：Reattach 重建并恢复路径

    /// Reconnect 后绑定全新连接：状态回到 idle；重新启动后
    /// 恢复最近成功路径（绝不复用旧连接的子系统）。
    func testG_ReattachRebuildsAndRestoresPath() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let first = try await makeAuthenticatedTestKeyConnection()
        let second = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: first)
        service.loadAbsolute(path: fixture + "/dir-a")
        try await waitForLoaded(service)

        await service.reattach(connection: second)
        XCTAssertEqual(service.phase, .idle, "reattach 后必须回到 idle")
        XCTAssertTrue(service.entries.isEmpty)

        service.startIfNeeded()
        try await waitForLoaded(service)
        XCTAssertEqual(
            service.currentPath,
            fixture + "/dir-a",
            "Reconnect 后应恢复最近成功路径"
        )
        XCTAssertEqual(service.entries.map(\.name), ["nested.txt"])

        // 旧连接此时才允许拆除（SessionManager 的顺序保证）；
        // 旧子系统绝不复用。
        await first.disconnect()
        let firstSubsystem = await first.hasSFTPSubsystem
        XCTAssertFalse(firstSubsystem)
    }

    // MARK: - 测试 H：stopBarrier 终止语义

    /// 拆除屏障可等待完成；停止后一切请求成为空操作，不产生状态写入。
    func testH_StopBarrierIsSafeAndTerminal() async throws {
        try await requireLocalSSHAndTestKey()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.startIfNeeded()
        await service.stopBarrier()

        let phaseAfterStop = service.phase
        service.refresh()
        service.loadAbsolute(path: "/")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(service.phase, phaseAfterStop, "停止后不得再有状态写入")

        // 幂等屏障。
        await service.stopBarrier()
    }

    // MARK: - 测试 I：多会话隔离

    /// 两个连接 + 两个 Service：一个导航不影响另一个的路径与条目。
    func testI_MultiSessionIsolation() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connectionOne = try await makeAuthenticatedTestKeyConnection()
        let connectionTwo = try await makeAuthenticatedTestKeyConnection()

        let serviceOne = SFTPService(connection: connectionOne)
        let serviceTwo = SFTPService(connection: connectionTwo)

        serviceOne.loadAbsolute(path: fixture + "/dir-a")
        serviceTwo.startIfNeeded()

        try await waitForLoaded(serviceOne)
        try await waitForLoaded(serviceTwo)

        XCTAssertEqual(serviceOne.currentPath, fixture + "/dir-a")
        XCTAssertNotEqual(serviceTwo.currentPath, serviceOne.currentPath)

        let twoPath = serviceTwo.currentPath
        let twoEntries = serviceTwo.entries

        serviceOne.goParent()
        try await waitForConditionAssert { serviceOne.currentPath == fixture }

        XCTAssertEqual(serviceTwo.currentPath, twoPath, "另一会话路径绝不受影响")
        XCTAssertEqual(serviceTwo.entries, twoEntries, "另一会话条目绝不受影响")
    }

    // MARK: - 测试 J：空目录状态

    /// 空目录：loaded + 空条目（UI 展示 Empty Directory）。
    func testJ_EmptyDirectoryLoadedState() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: fixture + "/empty")
        try await waitForLoaded(service)

        XCTAssertEqual(service.phase, .loaded)
        XCTAssertTrue(service.entries.isEmpty)
    }

    // MARK: - 测试 K：1000 条目无 N+1 stat

    /// 大目录单次列举完整返回；每个条目的权限与时间都随列举到达
    /// （attributes 由服务器在 READDIR 中回显——绝无逐条 stat）。
    func testK_LargeDirectoryAttributesArriveWithListing() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)

        let start = Date()
        service.loadAbsolute(path: fixture + "/big")
        try await waitForLoaded(service, timeout: 30)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(service.entries.count, 1_000)
        XCTAssertTrue(
            service.entries.allSatisfy { $0.permissions != nil && $0.modifiedAt != nil },
            "全部条目属性必须随列举一次到达（无 N+1 stat）"
        )
        XCTAssertLessThan(elapsed, 20, "1000 条目业务层加载耗时异常：\(elapsed) 秒")
    }

    // MARK: - 测试 L：面板切换不重建子系统

    /// Terminal ↔ Files 反复切换 5 轮：SFTP 子系统只初始化一次，
    /// 路径与条目稳定（切换只改变展示）。
    func testL_PaneSwitchDoesNotReinitSubsystem() async throws {
        try await requireLocalSSHAndTestKey()
        let connection = try await makeAuthenticatedTestKeyConnection()

        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: testHostname,
            port: testPort,
            username: testUsername
        )
        info.phase = .connected

        let session = ManagedTerminalSession(
            remoteHostID: UUID(),
            hostDisplayName: "Phase9PaneHost",
            hostname: testHostname,
            port: Int(testPort),
            baseTitle: "Phase9PaneHost",
            title: "Phase9PaneHost"
        )
        session.attach(connection: connection, info: info)

        session.selectPane(.files)
        let service = try XCTUnwrap(session.sftpService, "切换到 Files 必须惰性创建 SFTP 运行时")
        try await waitForLoaded(service)

        let pathBefore = service.currentPath

        // 反复切换 5 轮。
        for _ in 0..<5 {
            session.selectPane(.terminal)
            XCTAssertEqual(session.activePane, .terminal)
            session.selectPane(.files)
            XCTAssertEqual(session.activePane, .files)
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let initCount = await connection.sftpSubsystemInitCount
        XCTAssertEqual(initCount, 1, "面板切换绝不重建 SFTP 子系统")
        XCTAssertTrue(session.sftpService === service, "运行时对象必须复用")
        XCTAssertEqual(service.currentPath, pathBefore, "切换不得改变浏览状态")
    }

    // MARK: - 测试 M：快速导航——旧请求完整收尾前新请求绝不进入状态机（第二轮整改）

    /// P1 确定性竞态（第二轮整改核心）：第一条目录请求进入 EAGAIN 等价
    /// 挂起（测试接缝）后发起第二条导航——第二条在第一条**完全收尾
    /// （含收尾 closedir）**之前绝不发起任何 `libssh2` 调用（打开计数
    /// 保持 1）；最终提交的路径与条目都必须来自最后一个目标目录。
    /// 连续运行 5 次（每次全新连接）。
    func testM_RapidNavigationSecondWaitsForFirstFullExit() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        for iteration in 1...5 {
            try await runNavigationOverlapRace(fixture: fixture, iteration: iteration)
        }
    }

    private func runNavigationOverlapRace(fixture: String, iteration: Int) async throws {
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: fixture)
        try await waitForLoaded(service)

        // 基准：初始夹具加载恰好打开并关闭 1 个句柄。
        let opensBaseline = await connection.sftpDirectoryHandleOpenCount
        XCTAssertEqual(opensBaseline, 1, "迭代 \(iteration)：初始加载打开 1 个句柄")

        // 接缝：第一次导航的列举挂起在句柄已打开、readdir 未开始处
        // （EAGAIN 等价窗口），持有连接层串行门。
        let gate = RaceGate()
        await connection.setTestSFTPAfterHandleOpenHook { await gate.arriveAndWaitRelease() }

        service.loadAbsolute(path: fixture + "/empty")
        let arrived = try await waitForCondition(timeout: 15) { await gate.hasArrived() }
        XCTAssertTrue(arrived, "迭代 \(iteration)：第一条导航必须到达 readdir 窗口门闩")

        // 第二条导航：旧任务被取消并被等待完全退出，新任务排队。
        service.loadAbsolute(path: fixture + "/dir-a")
        try await Task.sleep(nanoseconds: 300_000_000)

        // 第一条请求挂起期间：第二条绝不发起任何 libssh2 调用——
        // 打开计数停在 2（初始加载 + 挂起请求各 1 次），持续整个窗口；
        // 挂起请求也绝不提交状态（路径不变、仍在加载）。
        let opensDuring = await connection.sftpDirectoryHandleOpenCount
        XCTAssertEqual(
            opensDuring, opensBaseline + 1,
            "迭代 \(iteration)：挂起时刻只有第一条导航打开了句柄"
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        let opensStillDuring = await connection.sftpDirectoryHandleOpenCount
        XCTAssertEqual(
            opensStillDuring, opensBaseline + 1,
            "迭代 \(iteration)：第一条完全收尾前第二条绝不 opendir"
        )
        XCTAssertEqual(
            service.currentPath, fixture,
            "迭代 \(iteration)：挂起期间路径保持原值"
        )
        XCTAssertEqual(
            service.phase, .loading,
            "迭代 \(iteration)：挂起期间保持加载态"
        )

        // 释放：第一条以取消语义收尾（含 closedir）退出，第二条随后执行。
        await gate.release()

        try await waitForLoaded(service)

        // 路径与条目都必须来自最后一个目标目录（条目非空且特征唯一，
        // 绝不可能是第一条目标或挂起请求的残留）。
        XCTAssertEqual(
            service.currentPath, fixture + "/dir-a",
            "迭代 \(iteration)：最终路径必须是最后一个目标目录"
        )
        XCTAssertEqual(
            service.entries.map(\.name), ["nested.txt"],
            "迭代 \(iteration)：最终条目必须来自最后一个目标目录"
        )

        // 竞态窗口内恰好新增一次打开（第二条导航）；全部打开都有
        // 对应的关闭（含被取消请求的收尾关闭）。
        let opens = await connection.sftpDirectoryHandleOpenCount
        XCTAssertEqual(
            opens, opensBaseline + 2,
            "迭代 \(iteration)：两条导航各打开 1 个句柄"
        )
        let closes = await connection.sftpDirectoryHandleCloseCount
        XCTAssertEqual(
            closes, opens,
            "迭代 \(iteration)：关闭数必须等于打开数（含被取消请求的收尾关闭）"
        )
        let handles = await connection.openSFTPDirectoryHandleCount
        XCTAssertEqual(handles, 0, "迭代 \(iteration)：不得遗留打开的目录句柄")
        let inFlight = await connection.inFlightSFTPListingCount
        XCTAssertEqual(inFlight, 0, "迭代 \(iteration)：在途计数必须归零")

        await connection.setTestSFTPAfterHandleOpenHook(nil)
        await connection.disconnect()
    }

    // MARK: - 辅助

    private func waitForLoaded(
        _ service: SFTPService,
        timeout: TimeInterval = 20
    ) async throws {
        let loaded = try await waitForCondition(timeout: timeout) {
            service.phase == .loaded
        }
        XCTAssertTrue(loaded, "等待 loaded 超时，实际 \(service.phase)")
    }

    /// 等待断言成立（导航提交是原子瞬间，轮询观察即可）。
    private func waitForConditionAssert(
        timeout: TimeInterval = 20,
        where predicate: () -> Bool
    ) async throws {
        let met = try await waitForCondition(timeout: timeout) { predicate() }
        XCTAssertTrue(met, "条件在 \(timeout) 秒内未成立")
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

    private func requireFixture() throws -> String {
        let exists = FileManager.default.fileExists(atPath: Self.fixturePathFile)
        try XCTSkipUnless(exists, "缺少 Phase 9 夹具交接文件：请使用 Scripts/run-ssh-tests.sh")
        let path = try String(contentsOfFile: Self.fixturePathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(!path.isEmpty, "Phase 9 夹具交接文件为空")
        return path
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
    /// 退避 0.5 秒；成功建连后的全部断言不受任何弱化。
    private func makeAuthenticatedTestKeyConnection() async throws -> SSHConnection {
        for _ in 1...3 {
            let info = makeInfo()
            let connection = makeConnection(info: info)
            openConnections.append(connection)

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

    /// 确定性竞态门闩：列举到达接缝后停在此处等待释放；
    /// 测试在释放前断言第二条导航未进入 `libssh2`（测试 M）。
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
}

/// RemotePath 纯函数语义单测（不需要真实连接）。
final class RemotePathTests: XCTestCase {
    func testNormalized() {
        XCTAssertEqual(RemotePath.normalized(""), "/")
        XCTAssertEqual(RemotePath.normalized("/"), "/")
        XCTAssertEqual(RemotePath.normalized("//"), "/")
        XCTAssertEqual(RemotePath.normalized("//etc"), "/etc")
        XCTAssertEqual(RemotePath.normalized("/a//b/"), "/a/b")
        XCTAssertEqual(RemotePath.normalized("/a/b"), "/a/b")
    }

    func testParent() {
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/a"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/a/b"), "/a")
        XCTAssertEqual(RemotePath.parent(of: "/a/b//c"), "/a/b")
    }

    func testJoin() {
        XCTAssertEqual(RemotePath.join("/", child: "etc"), "/etc")
        XCTAssertEqual(RemotePath.join("/a", child: "b"), "/a/b")
        XCTAssertEqual(RemotePath.join("/a/", child: "b"), "/a/b")
        XCTAssertEqual(RemotePath.join("/a", child: "."), "/a")
        XCTAssertEqual(RemotePath.join("/a/b", child: ".."), "/a")
        XCTAssertEqual(RemotePath.join("/", child: ".."), "/")
        XCTAssertEqual(RemotePath.join("/a", child: ""), "/a")
        // 绝不产生双斜杠。
        XCTAssertFalse(RemotePath.join("/", child: "中文 目录").contains("//"))
    }

    func testIsRoot() {
        XCTAssertTrue(RemotePath.isRoot("/"))
        XCTAssertTrue(RemotePath.isRoot("//"))
        XCTAssertFalse(RemotePath.isRoot("/a"))
    }
}
