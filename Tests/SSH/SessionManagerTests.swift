import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 8 SessionManager 多 Session 生命周期与竞态测试。
///
/// 两类用例：
/// - 纯生命周期（无网络）：创建 / 激活 / 关闭 / 幂等 / 邻居激活 /
///   元数据隔离 / 前置拒绝状态 / 20× Local 循环泄漏 / 5 Session 空闲 CPU；
/// - 真实集成（本机 sshd + 脚本预置测试私钥）：同 Host 多 Session 独立
///   Shell、close-while-connecting、double close + disconnect 并发、
///   exit + close、reconnect + close、Reconnect 完整回环、
///   20× Remote 完整生命周期（任务书 61/93）。
///
/// 集成用例的输出断言走真实数据路径：SSH Channel → Service 读取循环 →
/// SwiftTerm buffer（`getBufferAsData`），不经任何旁路读取。
///
/// 任何源码、断言与日志都不包含 Password / Passphrase / 终端内容。
@MainActor
final class SessionManagerTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort = 22
    private let testUsername = NSUserName()

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
        /// RFC 5737 TEST-NET-1：保证不可路由，TCP 连接在 10 秒预算内
        /// 稳定停留在 connecting，用于 close-while-connecting。
        static let nonRoutableHost = "192.0.2.1"
    }

    private var container: ModelContainer!
    private var sshService: SSHService!
    private var manager: SessionManager!

    override func setUp() async throws {
        continueAfterFailure = false
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        sshService = SSHService(modelContainer: container)
        manager = SessionManager(sshService: sshService)
    }

    override func tearDown() async throws {
        // 关闭剩余 Session（真实子进程 / 连接必须结束，避免跨用例泄漏）。
        let remaining = manager.sessions
        for session in remaining {
            await manager.closeSession(id: session.id)
        }
        manager = nil
        sshService = nil
        container = nil
    }

    // MARK: - 纯生命周期（无网络）

    /// Manager 启动即拥有一个 Local Session 且 active 指针有效（与 Phase 2 行为一致）。
    func testA_ManagerStartsWithActiveLocalSession() {
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions[0].kind, .local)
        XCTAssertEqual(manager.activeSessionID, manager.sessions[0].id)
        XCTAssertEqual(manager.sessions[0].title, "Local")
    }

    /// ⌘T 语义：每次创建都是独立 Shell runtime（独立 TerminalSession /
    /// LocalProcessTerminalView），标题编号 Local / Local 2 / Local 3。
    func testB_CreateMultipleLocalSessionsWithIndependentRuntime() {
        let first = manager.sessions[0]
        let second = manager.createLocalSession()
        _ = manager.createLocalSession()

        XCTAssertEqual(manager.sessions.count, 3)
        XCTAssertEqual(manager.activeSessionID, manager.sessions[2].id)
        XCTAssertEqual(
            manager.sessions.map(\.title),
            ["Local", "Local 2", "Local 3"],
            "同基准标题第 2 个起编号（任务书 13）"
        )

        // 独立 runtime：不同对象、不同 PTY / Shell 状态载体。
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.localService === second.localService)
        XCTAssertFalse(first.localService?.terminalView === second.localService?.terminalView)
        XCTAssertFalse(first.localService?.session === second.localService?.session)

        // Local + Remote 元数据隔离：Remote 字段在 Local Session 上为 nil。
        XCTAssertNil(first.hostID)
        XCTAssertNil(first.hostname)
        XCTAssertNil(first.remoteService)
    }

    /// ⌘1~⌘9：只切换 activeSessionID，不触发连接 / 重建（越界 / 未知 ID 忽略）。
    func testC_ActivateTabSwitchesWithoutRebuild() {
        let first = manager.sessions[0]
        _ = manager.createLocalSession()
        _ = manager.createLocalSession()

        manager.activateTab(at: 0)
        XCTAssertEqual(manager.activeSessionID, first.id)
        XCTAssertEqual(manager.sessions.count, 3, "激活不得改变 Session 集合")

        manager.activateTab(at: 2)
        XCTAssertEqual(manager.activeSessionID, manager.sessions[2].id)

        let before = manager.activeSessionID
        manager.activateTab(at: 9)
        XCTAssertEqual(manager.activeSessionID, before)

        manager.activateSession(id: UUID())
        XCTAssertEqual(manager.activeSessionID, before, "不存在的 Session 不得激活")
    }

    /// 关闭非 Active Session：active 不变，其余不受影响（任务书 53）。
    func testD_CloseInactiveSessionKeepsActive() async {
        _ = manager.createLocalSession()
        _ = manager.createLocalSession()
        let activeBefore = manager.activeSessionID
        let inactive = manager.sessions[0]

        await manager.closeSession(id: inactive.id)

        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.activeSessionID, activeBefore)
        XCTAssertFalse(manager.sessions.contains { $0.id == inactive.id })
    }

    /// 关闭 Active Tab：优先激活左侧相邻，无左侧则右侧（任务书 17/54）。
    func testE_CloseActiveSessionActivatesLeftNeighbor() async {
        let a = manager.sessions[0]
        let b = manager.createLocalSession()
        let c = manager.createLocalSession()
        XCTAssertEqual(manager.activeSessionID, c.id)

        await manager.closeSession(id: c.id)
        XCTAssertEqual(manager.activeSessionID, b.id)

        await manager.closeSession(id: b.id)
        XCTAssertEqual(manager.activeSessionID, a.id)
    }

    /// 关闭第一个 Tab（无左侧）：右侧相邻激活。
    func testF_CloseFirstSessionActivatesRightNeighbor() async {
        let a = manager.sessions[0]
        let b = manager.createLocalSession()
        manager.activateSession(id: a.id)

        await manager.closeSession(id: a.id)
        XCTAssertEqual(manager.activeSessionID, b.id)
    }

    /// 关闭全部 Session：activeSessionID 为 nil（不指向已删除 Session）。
    func testG_CloseLastSessionLeavesEmptyState() async {
        let a = manager.sessions[0]
        await manager.closeSession(id: a.id)

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.activeSessionID)
        XCTAssertNil(manager.activeSession)
    }

    /// 全部关闭后 ⌘T 仍可重建（SessionManager 生命周期正常，任务书 56）。
    func testH_RecreateAfterClosingAll() async {
        let a = manager.sessions[0]
        await manager.closeSession(id: a.id)

        let newSession = manager.createLocalSession()
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.activeSessionID, newSession.id)
        XCTAssertEqual(
            newSession.title, "Local 2",
            "P2 单调编号：计数器随 Manager 存活，全部关闭后编号不回收"
        )
    }

    /// 重复关闭同一 Session：第二次 no-op，不崩溃（任务书 46 幂等）。
    func testI_DuplicateCloseIsIdempotent() async {
        let a = manager.sessions[0]
        await manager.closeSession(id: a.id)
        let countAfterFirst = manager.sessions.count

        await manager.closeSession(id: a.id)
        XCTAssertEqual(manager.sessions.count, countAfterFirst)
        XCTAssertNil(manager.activeSessionID)
    }

    /// 前置拒绝的 Remote Session（缺少凭据）：保留 Tab 展示 failed，
    /// 可直接关闭（无需确认），canReconnect 为 true（任务书 38）。
    func testJ_RejectedRemoteSessionKeepsFailedTab() async throws {
        let host = try makeHost(
            name: "NoCredential",
            authenticationType: .password,
            credentialID: nil,
            privateKeyPath: nil
        )
        let session = manager.createRemoteSession(host: host)

        let rejected = try await waitForCondition(timeout: 2) {
            self.isFailed(session) && session.connectTask == nil
        }
        XCTAssertTrue(rejected, "缺少凭据必须进入 failed（当前 \(session.statusText)）")
        XCTAssertTrue(session.canReconnect)
        XCTAssertFalse(session.requiresCloseConfirmation, "失败会话关闭不得弹确认")

        await manager.closeSession(id: session.id)
        XCTAssertFalse(manager.sessions.contains { $0.id == session.id })
    }

    /// Reconnect 状态机：failed → Reconnect（仍缺凭据 → 再次 failed）；
    /// 连接任务在途时 canReconnect 为 false（任务书 23）。
    func testK_ReconnectStateTransitions() async throws {
        let host = try makeHost(
            name: "NoCredential",
            authenticationType: .password,
            credentialID: nil,
            privateKeyPath: nil
        )
        let session = manager.createRemoteSession(host: host)
        _ = try await waitForCondition(timeout: 2) {
            self.isFailed(session)
        }

        manager.reconnectSession(id: session.id)
        XCTAssertFalse(session.canReconnect, "Reconnect 在途时不得再次触发")

        _ = try await waitForCondition(timeout: 2) {
            session.reconnectTask == nil && session.connectTask == nil
        }
        XCTAssertTrue(isFailed(session), "仍缺凭据的 Reconnect 必须再次 failed（当前 \(session.displayState)）")

        // Host 删除后：Reconnect 无 Profile 可用（静默 no-op）。
        container.mainContext.delete(host)
        try container.mainContext.save()
        manager.reconnectSession(id: session.id)
        _ = try await waitForCondition(timeout: 1) {
            session.reconnectTask == nil
        }
        XCTAssertTrue(isFailed(session), "Host 删除后 Reconnect no-op，状态保持 failed（当前 \(session.displayState)）")
    }

    /// Host 聚合状态：前置拒绝（缺凭据）的 Session 不计入 busy/active。
    func testL_HostSessionSummaryAggregation() async throws {
        let host = try makeHost(
            name: "Summary",
            authenticationType: .password,
            credentialID: nil,
            privateKeyPath: nil
        )
        let session = manager.createRemoteSession(host: host)

        // 等前置拒绝落位后再聚合；否则 Session 仍在 busy(connecting)。
        _ = try await waitForCondition(timeout: 2) {
            self.isFailed(session)
        }

        let summary = manager.hostSessionSummary(hostID: host.id)
        XCTAssertTrue(summary.isEmpty, "前置拒绝的 Session 不计入 busy/active（当前 active=\(summary.activeSessionCount) busy=\(summary.busySessionCount)）")
        XCTAssertTrue(manager.hostSessionSummary(hostID: UUID()).isEmpty, "无关 Host 为空")
    }

    /// 失败 Session 的 requestClose 直接关闭，不登记确认请求（任务书 22）。
    func testM_RequestCloseWithoutConfirmationForFailedSession() async throws {
        let host = try makeHost(
            name: "NoCredential",
            authenticationType: .password,
            credentialID: nil,
            privateKeyPath: nil
        )
        let session = manager.createRemoteSession(host: host)
        let failed = try await waitForCondition(timeout: 2) {
            self.isFailed(session)
        }
        XCTAssertTrue(failed, "前置拒绝必须先进入 failed（当前 \(session.statusText)）")

        manager.requestClose(id: session.id)
        XCTAssertNil(manager.pendingCloseConfirmation, "失败会话关闭不得登记确认请求")
        _ = try await waitForCondition(timeout: 2) {
            !self.manager.sessions.contains { $0.id == session.id }
        }
    }

    // MARK: - 真实集成（本机 sshd + 测试私钥）

    /// 同 Host 两个 Remote Session：两条独立 SSHConnection + 独立 Shell，
    /// cwd 互不影响（任务书 12/49，核心场景 2/4）。
    func testN_TwoRemoteSessionsSameHostHaveIndependentShells() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")

        let sessionA = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(sessionA, timeout: 25)

        let sessionB = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(sessionB, timeout: 25)

        XCTAssertEqual(sessionA.title, "Loopback")
        XCTAssertEqual(sessionB.title, "Loopback 2", "同 Host 第 2 个 Session 编号")

        // 独立连接对象（禁止共享 LIBSSH2_SESSION *，任务书 42）。
        let connectionA = try XCTUnwrap(sessionA.connection)
        let connectionB = try XCTUnwrap(sessionB.connection)
        XCTAssertFalse(connectionA === connectionB)
        XCTAssertFalse(sessionA.remoteService === sessionB.remoteService)

        // 独立 Shell：A 在 /tmp、B 在 HOME；输出走各自 SwiftTerm buffer。
        let markerA1 = "PHASE8_A1_AT_$PWD"
        try await sendCommand(connectionA, "cd /tmp; echo \(quoted(markerA1))")
        let bufferA1 = try await waitForBufferText(sessionA, marker: "/tmp", timeout: 15)
        XCTAssertTrue(bufferA1.contains("/tmp"), "Session A 必须位于 /tmp")

        let markerB1 = "PHASE8_B1_AT_$PWD"
        try await sendCommand(connectionB, "cd ~; echo \(quoted(markerB1))")
        let bufferB1 = try await waitForBufferText(
            sessionB,
            marker: NSHomeDirectory(),
            timeout: 15
        )
        XCTAssertTrue(bufferB1.contains(NSHomeDirectory()), "Session B 必须位于 HOME")

        // B 执行后 A 的 cwd 不受影响（真正独立的 Shell）。
        let markerA2 = "PHASE8_A2_AT_$PWD"
        try await sendCommand(connectionA, "echo \(quoted(markerA2))")
        let bufferA2 = try await waitForBufferText(sessionA, marker: "/tmp", timeout: 15)
        XCTAssertTrue(bufferA2.contains("/tmp"), "Session A 的 cwd 必须保持 /tmp")

        // 关闭 A：B 不受影响。
        await manager.closeSession(id: sessionA.id)
        XCTAssertFalse(manager.sessions.contains { $0.id == sessionA.id })
        XCTAssertEqual(sessionB.displayState, .active, "关闭 A 不得断开 B")
    }

    /// Connecting 中关闭 Tab：连接被取消清理，Session 移除，无孤儿连接
    /// （任务书 39）。
    func testO_CloseWhileConnectingCancelsConnection() async throws {
        // 不可路由地址：TCP 停留在 connecting（10 秒预算内不完成），不依赖 sshd。
        let host = try makeHost(
            name: "Blackhole",
            hostname: TestKeys.nonRoutableHost,
            port: 12345,
            authenticationType: .password,
            credentialID: UUID(),
            privateKeyPath: nil
        )
        let session = manager.createRemoteSession(host: host)

        // 必须等连接真正装配完成并进入 connecting；displayState == .connecting
        // 在未装配时也会作为 fallback 成立，那时关闭走的是另一条路径。
        let connecting = try await waitForCondition(timeout: 5) {
            session.connection != nil && session.connectionInfo?.phase == .connecting
        }
        XCTAssertTrue(connecting, "必须先观察到已真正开始的 connecting（当前 \(session.statusText)）")

        await manager.closeSession(id: session.id)
        XCTAssertFalse(manager.sessions.contains { $0.id == session.id })
        XCTAssertNotEqual(
            manager.activeSessionID,
            session.id,
            "active 指针不得指向已删除 Session"
        )

        // 后台 connect 随 teardown 取消/清理，连接状态必须收敛到终态（无孤儿）。
        // 不可路由地址会耗尽 TCP 预算后 failed(.connectionTimeout)；被中止的
        // 等待则收敛到 disconnected。两者都代表资源已清理。
        let settled = try await waitForCondition(timeout: 20) {
            guard let phase = session.connectionInfo?.phase else {
                return false
            }
            switch phase {
            case .disconnected, .failed:
                return true
            default:
                return false
            }
        }
        XCTAssertTrue(settled, "关闭后连接必须收敛，实际 \(String(describing: session.connectionInfo?.phase))")
    }

    /// Double close + disconnect 并发（任务书 45/46）：单次移除、无崩溃、
    /// 状态收敛。
    func testP_DoubleCloseAndDisconnectConcurrently() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")
        let session = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(session, timeout: 25)

        let closeTask1 = Task { await manager.closeSession(id: session.id) }
        let closeTask2 = Task { await manager.closeSession(id: session.id) }
        let disconnectTask = Task {
            if let connection = session.connection {
                await connection.disconnect()
            }
        }
        await closeTask1.value
        await closeTask2.value
        await disconnectTask.value

        XCTAssertEqual(
            manager.sessions.filter { $0.id == session.id }.count,
            0,
            "重复关闭只移除一次"
        )

        let settled = try await waitForCondition(timeout: 10) {
            session.connectionInfo?.phase == .disconnected
        }
        XCTAssertTrue(settled, "并发 teardown 后连接必须收敛到 disconnected")
    }

    /// 远端 exit + 用户关闭并发：无崩溃，资源正常清理（任务书 45）。
    func testQ_RemoteExitThenCloseNoCrash() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")
        let session = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(session, timeout: 25)

        try await sendCommand(session.connection, "exit")
        let exited = try await waitForCondition(timeout: 10) {
            session.displayState == .exited
        }
        XCTAssertTrue(exited, "远端 exit 后必须进入 exited（当前 \(session.statusText)）")

        await manager.closeSession(id: session.id)
        XCTAssertFalse(manager.sessions.contains { $0.id == session.id })
    }

    /// Reconnect 完整回环（Private Key，任务书 57/59）：exit → Reconnect →
    /// 新连接新 Shell，echo 成功；旧连接不复用（任务书 26）。
    func testR_ReconnectAfterExitCreatesNewConnection() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")
        let session = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(session, timeout: 25)

        let oldConnection = try XCTUnwrap(session.connection)
        let oldRemoteService = try XCTUnwrap(session.remoteService)
        try await sendCommand(oldConnection, "exit")
        _ = try await waitForCondition(timeout: 10) {
            session.displayState == .exited
        }

        XCTAssertTrue(session.canReconnect)
        manager.reconnectSession(id: session.id)

        let reconnected = try await waitForCondition(timeout: 25) {
            session.displayState == .active
        }
        XCTAssertTrue(reconnected, "Reconnect 必须重新建立 Shell（当前 \(session.statusText)）")

        // 新连接对象；旧 TerminalView 复用（保留历史，任务书 25/27）。
        let newConnection = try XCTUnwrap(session.connection)
        XCTAssertFalse(newConnection === oldConnection, "Reconnect 不得复用旧 SSHConnection")
        XCTAssertTrue(session.remoteService === oldRemoteService, "TerminalView/历史必须复用")

        let marker = "PHASE8_RECONNECT_KEY_OK"
        try await sendCommand(newConnection, "echo \(quoted(marker))")
        let buffer = try await waitForBufferText(session, marker: marker, timeout: 15)
        XCTAssertTrue(buffer.contains(marker), "Reconnect 后 Shell 必须可交互")
    }

    /// Reconnect + Close 并发（任务书 45/60）：teardown 阶段关闭，
    /// 不建立新连接，无崩溃。
    func testS_ReconnectThenCloseDuringTeardown() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")
        let session = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(session, timeout: 25)

        try await sendCommand(session.connection, "exit")
        _ = try await waitForCondition(timeout: 10) {
            session.displayState == .exited
        }

        manager.reconnectSession(id: session.id)
        await manager.closeSession(id: session.id)

        XCTAssertFalse(manager.sessions.contains { $0.id == session.id })
        XCTAssertTrue(session.isClosed, "Reconnect 进行中关闭必须终止会话")

        let settled = try await waitForCondition(timeout: 10) {
            session.connectionInfo?.phase == .disconnected
        }
        XCTAssertTrue(settled, "旧连接必须完成释放")
    }

    /// 关闭同 Host 全部 Session（Hosts 页 Disconnect 路径）。
    func testT_CloseAllSessionsForHost() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")
        let sessionA = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(sessionA, timeout: 25)
        let sessionB = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(sessionB, timeout: 25)

        await manager.closeAllSessions(hostID: host.id)

        XCTAssertTrue(
            manager.sessions.filter { $0.hostID == host.id }.isEmpty,
            "该 Host 的全部 Session 必须移除"
        )
    }

    // MARK: - 资源预算（任务书 61 / 93 / 94）

    /// 20× New Local → Close：FD / 线程 / 常驻内存不得持续增长（任务书 61/93）。
    func testU_TwentyLocalSessionCreateCloseCyclesNoLeak() async throws {
        let fdBefore = probeFileDescriptor()
        let threadsBefore = threadCount()
        let memoryBefore = residentMemoryBytes()

        for cycle in 1...20 {
            let session = manager.createLocalSession()
            XCTAssertTrue(
                manager.sessions.contains { $0.id == session.id },
                "第 \(cycle) 轮：Local Session 必须创建"
            )
            await manager.closeSession(id: session.id)
            XCTAssertFalse(
                manager.sessions.contains { $0.id == session.id },
                "第 \(cycle) 轮：Local Session 必须移除"
            )
        }

        // 释放稳定窗口：等待 autorelease / 延迟释放收敛。
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let fdAfter = probeFileDescriptor()
        let threadsAfter = threadCount()
        let memoryAfter = residentMemoryBytes()

        XCTAssertLessThanOrEqual(
            fdAfter - fdBefore,
            2,
            "20 次 Local Session 后 FD 不应持续增长（before=\(fdBefore), after=\(fdAfter)）"
        )
        XCTAssertLessThanOrEqual(
            threadsAfter - threadsBefore,
            4,
            "20 次 Local Session 后线程数不应持续增长（before=\(threadsBefore), after=\(threadsAfter)）"
        )
        if memoryBefore > 0, memoryAfter > 0 {
            XCTAssertLessThanOrEqual(
                memoryAfter - memoryBefore,
                64 * 1024 * 1024,
                "20 次 Local Session 后常驻内存增长应有界（before=\(memoryBefore), after=\(memoryAfter)）"
            )
        }
    }

    /// 5 个空闲 Session 保持 30 秒：CPU 不得 busy-loop（任务书 94）。
    func testV_FiveIdleLocalSessionsNoBusyLoop() async throws {
        // Manager 启动已含 1 个默认 Local Session；再创建 4 个达到 5 个。
        for _ in 1...4 {
            _ = manager.createLocalSession()
        }
        XCTAssertEqual(manager.sessions.count, 5, "必须同时持有 5 个 Session")

        // 启动沉降后开始测量。
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let usageBefore = Self.processCPUSeconds()
        try await Task.sleep(nanoseconds: 30_000_000_000)
        let usageAfter = Self.processCPUSeconds()

        let cpuDelta = usageAfter - usageBefore
        XCTAssertLessThanOrEqual(
            cpuDelta,
            1.0,
            "5 个空闲 Session 30 秒 CPU 增量应接近 0（实测 \(String(format: "%.3f", cpuDelta)) 秒）"
        )
    }

    /// 20× New Remote → Connect → Open Shell → Close（SessionManager 层级），
    /// 每轮连接必须收敛、无孤儿，最终 FD / 线程不持续增长（任务书 61/93）。
    func testW_TwentyRemoteSessionLifecycleCyclesNoLeak() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")

        let fdBefore = probeFileDescriptor()
        let threadsBefore = threadCount()

        for cycle in 1...20 {
            let session = manager.createRemoteSession(host: host)
            try await resolveTrustAndAwaitActive(session, timeout: 25)
            await manager.closeSession(id: session.id)

            let settled = try await waitForCondition(timeout: 15) {
                guard let phase = session.connectionInfo?.phase else { return true }
                switch phase {
                case .disconnected, .failed: return true
                default: return false
                }
            }
            XCTAssertTrue(settled, "第 \(cycle) 轮：关闭后连接必须收敛")
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let fdAfter = probeFileDescriptor()
        let threadsAfter = threadCount()

        XCTAssertLessThanOrEqual(
            fdAfter - fdBefore,
            3,
            "20 次 Remote Session 后 FD 不应持续增长（before=\(fdBefore), after=\(fdAfter)）"
        )
        XCTAssertLessThanOrEqual(
            threadsAfter - threadsBefore,
            4,
            "20 次 Remote Session 后线程数不应持续增长（before=\(threadsBefore), after=\(threadsAfter)）"
        )
    }

    // MARK: - P1 验收整改：确定性竞态与 Reconnect 覆盖

    /// 确定性竞态（P1 整改核心）：阻塞旧读取循环 → 发起 reattach →
    /// reattach 必须被屏障扣住直到旧任务退出 → 释放 → 新 Channel
    /// 仍 active 且可执行命令；旧代次提交通知必须排在重连标记之前
    /// （串行提交，绝不交错覆盖新一代状态）。
    func testX_ReattachHeldUntilStaleReadLoopExits() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")
        let session = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(session, timeout: 25)
        guard let remote = session.remoteService else {
            return XCTFail("active Remote Session 必须持有 remoteService")
        }

        let gate = RaceGate()
        remote.testReadLoopExitHook = { await gate.arriveAndWaitRelease() }

        // 远端 `exit`：旧读取循环判定 EOF 终止事件后停在门闩（状态未提交）。
        try await sendCommand(session.connection, "exit")
        let arrived = try await waitForCondition(timeout: 15) { await gate.hasArrived() }
        XCTAssertTrue(arrived, "旧读取循环必须到达终止门闩")
        XCTAssertEqual(
            remote.session.phase, .active,
            "门闩释放前旧代次状态不得提交（仍应为 active）"
        )

        // 旧任务被阻塞期间准备全新已认证连接（KnownHost 已信任，无对话框）。
        guard case let .ready(newConnection, info) = sshService.prepareConnection(for: host) else {
            return XCTFail("prepareConnection 必须 ready")
        }
        defer { Task { await newConnection.disconnect() } }
        await newConnection.connect()
        XCTAssertEqual(info.phase, .connected, "KnownHost 已信任：第二次连接应直达 connected")

        // 发起 reattach：必须被拆除屏障扣住（旧读取循环尚未退出）。
        let reattachFinished = CompletionFlag()
        let reattachTask = Task {
            await remote.reattach(connection: newConnection)
            await reattachFinished.set()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let finishedEarly = await reattachFinished.isSet
        XCTAssertFalse(finishedEarly, "旧任务未退出前 reattach 不得完成")

        // 释放旧任务 → 屏障完成 → reattach 落定。
        await gate.release()
        await reattachTask.value

        remote.startIfNeeded()
        let active = try await waitForCondition(timeout: 20) {
            remote.session.phase == .active
        }
        XCTAssertTrue(active, "新一代 Shell 必须 active（当前 \(remote.session.phase)）")

        // 新 Channel 仍 active 且可执行命令。
        let channelOpen = await newConnection.hasOpenShellChannel
        XCTAssertTrue(channelOpen, "新连接的 Shell Channel 必须保持打开")
        let marker = "PHASE8_REATTACH_RACE_OK"
        try await sendCommand(newConnection, "echo \(quoted(marker))")
        let buffer = try await waitForBufferText(session, marker: marker, timeout: 15)
        XCTAssertTrue(buffer.contains("--- Reconnected ---"), "必须存在重连标记")
        if let reconnected = buffer.range(of: "--- Reconnected ---") {
            let prefix = buffer[..<reconnected.lowerBound]
            XCTAssertTrue(
                prefix.contains("[Remote shell exited]"),
                "旧代次终止通知必须先于重连标记提交（串行而非交错）"
            )
        }
    }

    /// 取消分支回归（P1）：活跃会话被取消的旧读取循环不得在 reattach
    /// 之后把新一代状态覆盖成 connectionLost。
    func testY_CancelledReadLoopCannotOverwriteReattachedGeneration() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")
        let session = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(session, timeout: 25)
        guard let remote = session.remoteService else {
            return XCTFail("active Remote Session 必须持有 remoteService")
        }

        let gate = RaceGate()
        remote.testReadLoopExitHook = { await gate.arriveAndWaitRelease() }

        // 取消旧读取循环（只取消；屏障等待由 reattach 扣住）。
        remote.stop()
        let arrived = try await waitForCondition(timeout: 15) { await gate.hasArrived() }
        XCTAssertTrue(arrived, "被取消的读取循环必须到达终止门闩")

        guard case let .ready(newConnection, info) = sshService.prepareConnection(for: host) else {
            return XCTFail("prepareConnection 必须 ready")
        }
        defer { Task { await newConnection.disconnect() } }
        await newConnection.connect()
        XCTAssertEqual(info.phase, .connected)

        let reattachFinished = CompletionFlag()
        let reattachTask = Task {
            await remote.reattach(connection: newConnection)
            await reattachFinished.set()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let finishedEarly = await reattachFinished.isSet
        XCTAssertFalse(finishedEarly, "旧任务未退出前 reattach 不得完成")

        await gate.release()
        await reattachTask.value

        remote.startIfNeeded()
        let active = try await waitForCondition(timeout: 20) {
            remote.session.phase == .active
        }
        XCTAssertTrue(
            active,
            "取消分支不得覆盖新一代状态：最终必须 active（当前 \(remote.session.phase)）"
        )

        let marker = "PHASE8_CANCEL_RACE_OK"
        try await sendCommand(newConnection, "echo \(quoted(marker))")
        let buffer = try await waitForBufferText(session, marker: marker, timeout: 15)
        if let reconnected = buffer.range(of: "--- Reconnected ---") {
            let suffix = buffer[reconnected.upperBound...]
            XCTAssertFalse(
                suffix.contains("[Connection closed]"),
                "重连标记之后不得出现旧代次的断开通知"
            )
        }
    }

    /// 真实 Connection Lost 后的完整手动 Reconnect（P1 补覆盖）：
    /// 杀掉本连接 sshd 子进程 → 会话进入 disconnected → Reconnect
    /// 建立全新连接 → Shell 恢复可用。
    func testZ_ReconnectAfterRealConnectionLost() async throws {
        try await requireLocalSSHAndTestKey()
        let host = try makePrivateKeyHost(name: "Loopback")

        let before = Self.userSSHDProcessIDs()
        let session = manager.createRemoteSession(host: host)
        try await resolveTrustAndAwaitActive(session, timeout: 25)
        guard let oldConnection = session.connection else {
            return XCTFail("active Session 必须持有连接")
        }

        // 唯一识别本连接的 sshd 子进程（只杀新增的，绝不触碰既有会话）。
        let after = Self.userSSHDProcessIDs()
        let newProcesses = after.subtracting(before)
        guard newProcesses.count == 1, let victim = newProcesses.first else {
            return XCTFail("无法唯一识别每连接 sshd 子进程：\(newProcesses)")
        }
        kill(victim, SIGKILL)

        let lost = try await waitForCondition(timeout: 20) {
            session.displayState == .disconnected
        }
        XCTAssertTrue(lost, "Connection Lost 后必须进入 disconnected（当前 \(session.statusText)）")
        XCTAssertTrue(session.canReconnect)

        manager.reconnectSession(id: session.id)
        let active = try await waitForCondition(timeout: 30) {
            session.displayState == .active
        }
        XCTAssertTrue(active, "Reconnect 必须恢复 active（当前 \(session.statusText)）")

        XCTAssertFalse(session.canReconnect, "active 后不得再允许重连")
        XCTAssertTrue(
            session.connection !== oldConnection,
            "Reconnect 必须使用全新连接（绝不复用旧 LIBSSH2_SESSION）"
        )

        let marker = "PHASE8_LOST_RECONNECT_OK"
        try await sendCommand(session.connection, "echo \(quoted(marker))")
        _ = try await waitForBufferText(session, marker: marker, timeout: 15)
    }

    // MARK: - P2 验收整改：标题编号

    /// 关闭中间 Tab 后再创建：单调编号不得回收，绝不产生同名 Tab。
    func testAA_TitleNumberingNeverDuplicatesAfterClosingMiddleTab() async throws {
        XCTAssertEqual(manager.sessions.first?.title, "Local")

        let second = manager.createLocalSession()
        let third = manager.createLocalSession()
        XCTAssertEqual(second.title, "Local 2")
        XCTAssertEqual(third.title, "Local 3")

        // 关闭中间 Tab（Local 2）：旧实现会让下一个新 Tab 再次得到重复编号。
        await manager.closeSession(id: second.id)

        let fourth = manager.createLocalSession()
        XCTAssertEqual(fourth.title, "Local 4", "关闭中间 Tab 后编号必须单调前进")

        let titles = manager.sessions.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "存活 Tab 标题不得重复：\(titles)")

        // 同 Host 多 SSH Session 同一规则（前置拒绝路径，不发生真实连接）。
        let host = try makeHost(
            name: "Loopback",
            authenticationType: .privateKey,
            credentialID: nil,
            privateKeyPath: "   "
        )
        let r1 = manager.createRemoteSession(host: host)
        let r2 = manager.createRemoteSession(host: host)
        let r3 = manager.createRemoteSession(host: host)
        XCTAssertEqual(r1.title, "Loopback")
        XCTAssertEqual(r2.title, "Loopback 2")
        XCTAssertEqual(r3.title, "Loopback 3")
        await manager.closeSession(id: r2.id)
        let r4 = manager.createRemoteSession(host: host)
        XCTAssertEqual(r4.title, "Loopback 4", "SSH 同 Host 编号同样必须单调前进")

        let remoteTitles = manager.sessions.filter { $0.hostID == host.id }.map(\.title)
        XCTAssertEqual(
            Set(remoteTitles).count, remoteTitles.count,
            "同 Host Tab 标题不得重复：\(remoteTitles)"
        )
    }

    // MARK: - 辅助

    /// 确定性竞态门闩：旧读取循环到达终止点后停在此处，
    /// 测试在释放前断言 reattach 被屏障扣住（testX / testY）。
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

    /// reattach 任务完成标记（Swift 的 Task 无 isFinished 属性）：
    /// 任务体完成后置位，测试据此断言屏障期间 reattach 不得提前完成。
    private actor CompletionFlag {
        private(set) var isSet = false

        func set() {
            isSet = true
        }
    }

    /// 当前用户所有 sshd 进程（含每连接子进程）的 PID 集合。
    /// 连接前后取差集即可唯一识别本连接的远端会话进程（与
    /// RemoteTerminalTests 相同实现）。
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
            if command == "sshd" || command.hasSuffix("/sshd") || command.hasPrefix("sshd-session") {
                pids.insert(pid)
            }
        }
        return pids
    }

    /// 在内存容器中创建并保存 Host。
    private func makeHost(
        name: String,
        hostname: String = "127.0.0.1",
        port: Int = 22,
        authenticationType: AuthenticationType,
        credentialID: UUID?,
        privateKeyPath: String?
    ) throws -> MacSSH.Host {
        let host = Host(
            name: name,
            hostname: hostname,
            port: port,
            username: testUsername,
            authenticationType: authenticationType
        )
        host.credentialID = credentialID
        host.privateKeyPath = privateKeyPath
        container.mainContext.insert(host)
        try container.mainContext.save()
        return host
    }

    /// 本机 sshd + 脚本预置测试私钥的 Host（无 Passphrase，不触碰 Keychain）。
    private func makePrivateKeyHost(name: String) throws -> MacSSH.Host {
        try makeHost(
            name: name,
            hostname: testHostname,
            port: testPort,
            authenticationType: .privateKey,
            credentialID: nil,
            privateKeyPath: TestKeys.ed25519NoPass
        )
    }

    /// 首次连接等待 Trust 对话框并以 **Trust Always** 持久化 KnownHost，
    /// 随后等待 Shell active。
    ///
    /// 必须用 `.trustAlways` 而非 `.trustOnce`：后者不写 KnownHost，
    /// Reconnect / 第二条连接的**重新 Host Key 验证**（产品正确行为，
    /// 绝不绕过）会再次停在等待确认，导致 testR / testX / testY / testZ
    /// 挂起。持久化后重新验证自动通过，测试仍完整走过验证路径。
    private func resolveTrustAndAwaitActive(
        _ session: ManagedTerminalSession,
        timeout: TimeInterval
    ) async throws {
        let trustOrConnected = try await waitForCondition(timeout: timeout) {
            guard let info = session.connectionInfo else {
                return false
            }
            return info.phase == .awaitingHostTrust || info.phase == .connected
        }
        XCTAssertTrue(trustOrConnected, "连接必须推进到 Trust/Connected（当前 \(session.statusText)）")

        if session.connectionInfo?.phase == .awaitingHostTrust {
            manager.resolveHostTrust(sessionID: session.id, decision: .trustAlways)
        }

        let active = try await waitForCondition(timeout: timeout) {
            session.displayState == .active
        }
        XCTAssertTrue(active, "Remote Session 必须进入 active（当前 \(session.statusText)）")
    }

    /// 把 marker 中的 `_` 替换为 `"_"`：命令回显因引号不匹配 marker，
    /// 只有真实输出匹配（与 RemoteTerminalTests 相同技巧）。
    private func quoted(_ marker: String) -> String {
        marker.replacingOccurrences(of: "_", with: "\"_\"")
    }

    /// 轮询 Session 的 SwiftTerm buffer（normal buffer 含 scrollback），
    /// 直到出现 marker；返回当时的 buffer 文本。
    private func waitForBufferText(
        _ session: ManagedTerminalSession,
        marker: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let terminal = session.remoteService?.terminalView.terminal {
                let data = terminal.getBufferAsData(kind: .normal)
                if let text = String(data: data, encoding: .utf8), text.contains(marker) {
                    return text
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("在 \(timeout)s 内未在 SwiftTerm buffer 中观察到 marker")
        return ""
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

    /// displayState 是否为 failed（前置拒绝 / 连接失败都会携带可读
    /// failureMessage，不是 .failed(nil)，故用模式匹配而非等值比较）。
    private func isFailed(_ session: ManagedTerminalSession) -> Bool {
        if case .failed = session.displayState {
            return true
        }
        return false
    }

    /// 向 Session 的 Shell Channel 写入一行命令（\r 结束）。
    private func sendCommand(_ connection: SSHConnection?, _ command: String) async throws {
        guard let connection else {
            return
        }
        try await connection.writeChannelInput(Array("\(command)\r".utf8)[...])
    }

    private func requireLocalSSH() async throws {
        let reachable = await isTCPPortOpen(host: testHostname, port: UInt16(testPort))
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

                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                continuation.resume(returning: connected)
            }
        }
    }

    /// 通过打开 /dev/null 探测当前 FD 高位值，用于泄漏检测。
    private func probeFileDescriptor() -> Int32 {
        let fd = open("/dev/null", O_RDONLY)
        if fd >= 0 {
            close(fd)
        }
        return fd
    }

    /// 当前进程线程数（Mach task_threads）。
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

    /// 当前进程常驻内存（字节），用于生命周期循环的内存增长检查。
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

    /// 进程累计 CPU 时间（用户 + 系统，秒）。
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
