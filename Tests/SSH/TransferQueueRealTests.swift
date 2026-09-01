import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 11 Transfer Queue 真实队列测试（本机 sshd + 真实 libssh2）：
/// - 50 任务队列压力：全部完成，全程全局 ≤1 / 每会话 ≤1；
/// - 失败隔离：源缺失 / 目标已存在 / 权限拒绝不阻塞后续任务；
/// - 随机取消压力：取消与完成混跑，无死锁、句柄配对；
/// - 多会话隔离：全局串行（并发属 2.0），关闭一会话不影响另一会话；
/// - generation 隔离：断线后重连，排队任务经新连接完成。
///
/// 前置：本机远程登录已开启，并经 `Scripts/run-phase10-focus.sh`
/// 同款流程生成测试私钥与夹具（本套件由 `Scripts/run-phase11-focus.sh` 驱动）。
@MainActor
final class TransferQueueRealTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
    }

    private static let fixturePathFile = "/tmp/macssh_phase10_fixture_path"

    private var container: ModelContainer!
    private var sshService: SSHService!
    private var manager: SessionManager!
    private var transferManager: TransferManager!

    override func setUp() async throws {
        continueAfterFailure = false
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        sshService = SSHService(modelContainer: container)
        manager = SessionManager(sshService: sshService)
        transferManager = TransferManager()
        transferManager.sessionManager = manager
        manager.transferManager = transferManager
    }

    override func tearDown() async throws {
        for session in manager.sessions {
            await manager.closeSession(id: session.id)
        }
        manager = nil
        sshService = nil
        container = nil
    }

    // MARK: - 测试 A：50 任务队列压力（单会话串行完成）

    /// 50 个小文件上传全部入队：单会话内严格串行（每会话 1），
    /// 事件驱动补位直到全部完成；全程活跃 ≤ 限额；终态后队列干净。
    func testA_FiftyTaskQueueDrainsCompletely() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let session = try await connectSession(name: "Queue-50")
        try await loadDirectory(session, path: uploadDir)

        var tasks = [TransferTask]()
        var observedMaxActive = 0
        for index in 1...50 {
            let localURL = makeLocalFile(
                name: "queue-\(index).bin",
                content: makeContent(size: 1_024 + index, seed: index)
            )
            let result = transferManager.requestUpload(session: session, localURL: localURL)
            XCTAssertNil(result.rejection, "任务 \(index) 入队被拒绝")
            if let task = result.task {
                tasks.append(task)
            }
        }
        XCTAssertEqual(tasks.count, 50)

        // 等待全部终态；期间采样并发限额（事件驱动，绝无轮询驱动测试）。
        let drained = try await waitForCondition(timeout: 180) {
            observedMaxActive = max(observedMaxActive, self.transferManager.activeTasks.count)
            return self.transferManager.tasks.allSatisfy { $0.state.isTerminal }
        }
        XCTAssertTrue(drained, "50 任务必须全部到达终态")
        XCTAssertLessThanOrEqual(
            observedMaxActive, TransferManager.maximumConcurrentTransfers,
            "全局活跃传输绝不超过上限"
        )
        for (index, task) in tasks.enumerated() {
            XCTAssertEqual(task.state, .completed, "任务 \(index + 1) 必须完成（\(task.failureMessage ?? "")）")
        }
        XCTAssertNil(transferManager.queueSummary(locale: AppLanguage.defaultLanguage.locale), "全部终态后汇总必须为空")
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir))
    }

    // MARK: - 测试 B：失败隔离（不阻塞后续任务）

    /// 队列混入三类失败（源缺失 / 目标已存在 / 权限拒绝）：
    /// 失败任务如实终态，后续正常任务照常完成——队头失败绝不阻塞队列。
    func testB_FailureIsolationDoesNotBlockQueue() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"
        let readonlyDir = fixture + "/readonly"

        let session = try await connectSession(name: "Queue-FailIso")
        try await loadDirectory(session, path: uploadDir)

        // 1) 正常。
        let ok1 = try XCTUnwrap(transferManager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "iso-ok-1.bin", content: Data("one".utf8))
        ).task)

        // 2) 下载缺失源 → failed（remoteFileMissing）。
        let missing = try XCTUnwrap(transferManager.requestDownload(
            session: session,
            entry: SFTPFileEntry(
                name: "no-such-source.bin", kind: .regularFile, sizeBytes: 1,
                modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
            ),
            destinationURL: makeLocalDestination(name: "iso-missing.bin")
        ).task)

        // 3) 上传到已存在目标 → failed（先制造已存在文件）。
        try Data("existing".utf8).write(to: URL(fileURLWithPath: uploadDir + "/iso-exists.bin"))
        let exists = try XCTUnwrap(transferManager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "iso-exists.bin", content: Data("new".utf8))
        ).task)

        // 4) 上传到只读目录 → failed（permissionDenied）：
        //    用导航快照构造目标——先切到 readonly 再入队，然后切回。
        let sftp = try XCTUnwrap(session.sftpService)
        sftp.loadAbsolute(path: readonlyDir)
        let atReadonly = try await waitForCondition(timeout: 20) {
            sftp.currentPath == readonlyDir && sftp.phase == .loaded
        }
        XCTAssertTrue(atReadonly)
        let denied = try XCTUnwrap(transferManager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "iso-denied.bin", content: Data("denied".utf8))
        ).task)
        sftp.loadAbsolute(path: uploadDir)
        // 导航是异步的：必须等回 uploadDir 后再入队尾部任务，
        // 否则目标路径快照还停在 readonly 目录（权限拒绝）。
        let backAtUpload = try await waitForCondition(timeout: 20) {
            sftp.currentPath == uploadDir && sftp.phase == .loaded
        }
        XCTAssertTrue(backAtUpload)

        // 5) 正常。
        let ok2 = try XCTUnwrap(transferManager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "iso-ok-2.bin", content: Data("two".utf8))
        ).task)

        let drained = try await waitForCondition(timeout: 120) {
            self.transferManager.tasks.allSatisfy { $0.state.isTerminal }
        }
        XCTAssertTrue(drained)

        XCTAssertEqual(ok1.state, .completed, "失败任务绝不阻塞首个正常任务")
        XCTAssertEqual(missing.state, .failed)
        XCTAssertEqual(missing.failureMessage, "远程文件不存在。")
        XCTAssertEqual(exists.state, .failed)
        XCTAssertEqual(exists.failureMessage, "远程文件已存在，不会自动覆盖该文件。")
        XCTAssertEqual(denied.state, .failed)
        XCTAssertEqual(denied.failureMessage, "权限不足，无法完成传输。")
        XCTAssertEqual(ok2.state, .completed, "失败任务绝不阻塞尾部正常任务")
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir))
    }

    // MARK: - 测试 C：随机取消压力（20 轮 × 取消运行中任务）

    /// 每轮：3MB 上传 → 首分块后取消 → Cancelled 终态 + 句柄配对 +
    /// 无临时文件残留。20 轮连跑证明取消路径可重复、无资源累积。
    func testC_CancelRunningTwentyTimes() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let content = makeContent(size: 3 * 1_048_576, seed: 17)
        let session = try await connectSession(name: "Queue-Cancel")
        try await loadDirectory(session, path: uploadDir)
        let connection = try XCTUnwrap(session.connection)

        for iteration in 1...20 {
            let gate = RaceGate()
            await connection.setTestSFTPFileTransferChunkHook(armed: true) {
                await gate.arriveAndWaitRelease()
            }

            let localURL = makeLocalFile(name: "cancel-\(iteration).bin", content: content)
            let task = try XCTUnwrap(
                transferManager.requestUpload(session: session, localURL: localURL).task
            )
            let arrived = try await waitForCondition(timeout: 30) { await gate.hasArrived() }
            XCTAssertTrue(arrived, "轮 \(iteration)：分块接缝必须到达")

            transferManager.cancel(task.id)
            transferManager.cancel(task.id) // 幂等。
            await gate.release()

            try await waitForTerminal(task)
            XCTAssertEqual(task.state, .cancelled, "轮 \(iteration) 必须取消收尾")
            await connection.setTestSFTPFileTransferChunkHook(armed: false, nil)
        }

        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir), "20 轮取消后不得残留临时文件")
        let opens = await connection.sftpFileHandleOpenCount
        let closes = await connection.sftpFileHandleCloseCount
        XCTAssertEqual(closes, opens, "20 轮取消后句柄必须配对")
    }

    // MARK: - 测试 D：多会话隔离（全局串行 + 关闭不影响对方）

    /// 两个会话各排 3 个任务：全局上限 1 下所有传输严格串行，
    /// 会话 A 任务运行时会话 B 绝不提前启动；关闭会话 A 只取消其任务，
    /// 会话 B 的任务照常完成。
    func testD_MultiSessionIsolationAndScopedTeardown() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let sessionA = try await connectSession(name: "Queue-A")
        let sessionB = try await connectSession(name: "Queue-B")
        try await loadDirectory(sessionA, path: uploadDir)
        try await loadDirectory(sessionB, path: uploadDir)

        // 门闩把会话 A 的首个任务钉在运行中，观测全局串行格局。
        let connectionA = try XCTUnwrap(sessionA.connection)
        let gate = RaceGate()
        await connectionA.setTestSFTPFileTransferChunkHook(armed: true) {
            await gate.arriveAndWaitRelease()
        }

        let content = makeContent(size: 2 * 1_048_576, seed: 19)
        var tasksA = [TransferTask]()
        var tasksB = [TransferTask]()
        for index in 1...3 {
            tasksA.append(try XCTUnwrap(transferManager.requestUpload(
                session: sessionA,
                localURL: makeLocalFile(name: "iso-a-\(index).bin", content: content)
            ).task))
        }
        for index in 1...3 {
            tasksB.append(try XCTUnwrap(transferManager.requestUpload(
                session: sessionB,
                localURL: makeLocalFile(name: "iso-b-\(index).bin", content: content)
            ).task))
        }

        // A1 被钉住时：全局恰 1 个活跃；会话 B 队首必须保持排队（全局串行，
        // Concurrent Transfer 属 2.0 路线，绝不提前启动）。
        let aPinned = try await waitForCondition(timeout: 30) { await gate.hasArrived() }
        XCTAssertTrue(aPinned, "会话 A 首个任务必须被钉住")
        XCTAssertEqual(transferManager.activeTasks.count, 1, "全局活跃传输必须恰为 1（串行）")
        XCTAssertTrue(self.transferManager.hasActiveTransfer(forSession: sessionA.id))
        XCTAssertFalse(
            self.transferManager.hasActiveTransfer(forSession: sessionB.id),
            "全局串行：会话 A 运行中会话 B 绝不并行启动"
        )
        XCTAssertEqual(tasksB[0].state, .pending)
        // 同会话保序：A2/A3、B2/B3 保持排队。
        XCTAssertEqual(tasksA[1].state, .pending)
        XCTAssertEqual(tasksB[1].state, .pending)

        // 关闭会话 A：只取消 A 的任务（确认流程 → 屏障 → 拆除）。
        manager.requestClose(id: sessionA.id)
        XCTAssertNotNil(manager.pendingCloseConfirmation)
        manager.confirmClose()
        await gate.release()

        let aDone = try await waitForCondition(timeout: 60) {
            tasksA.allSatisfy { $0.state.isTerminal }
        }
        XCTAssertTrue(aDone, "关闭会话必须收尾其全部任务")
        for task in tasksA {
            XCTAssertTrue(
                task.state == .cancelled || task.state == .completed,
                "会话 A 任务必须以取消或已完成收尾（\(task.state)）"
            )
        }

        // 会话 B 的任务必须继续完成（隔离性核心断言）。
        let bDone = try await waitForCondition(timeout: 120) {
            tasksB.allSatisfy { $0.state == .completed }
        }
        XCTAssertTrue(bDone, "关闭会话 A 绝不影响会话 B 的队列")
        await connectionA.setTestSFTPFileTransferChunkHook(armed: false, nil)
    }

    // MARK: - 测试 E：断线保持等待 + 重连后经新连接完成（generation 隔离）

    /// 连接断开：运行中任务失败，排队任务保持等待（等待连接）；
    /// 用户重连后调度器经**新**连接补位完成排队任务，绝不复用旧连接。
    func testE_DisconnectHoldsPendingAndReconnectCompletes() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let session = try await connectSession(name: "Queue-Reconnect")
        try await loadDirectory(session, path: uploadDir)
        let oldConnection = try XCTUnwrap(session.connection)

        // 门闩钉住首个任务，让第二个任务停在排队。
        let gate = RaceGate()
        await oldConnection.setTestSFTPFileTransferChunkHook(armed: true) {
            await gate.arriveAndWaitRelease()
        }
        let content = makeContent(size: 1_048_576, seed: 23)
        let running = try XCTUnwrap(transferManager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "rc-running.bin", content: content)
        ).task)
        let waiting = try XCTUnwrap(transferManager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "rc-waiting.bin", content: content)
        ).task)
        let arrived = try await waitForCondition(timeout: 30) { await gate.hasArrived() }
        XCTAssertTrue(arrived)
        XCTAssertEqual(waiting.state, .pending)

        // 断线：释放门闩让运行任务撞上断开 → failed；等待任务保持。
        await gate.release()
        await oldConnection.disconnect()
        let runningFailed = try await waitForCondition(timeout: 60) {
            running.state.isTerminal
        }
        XCTAssertTrue(runningFailed)
        XCTAssertEqual(running.state, .failed, "断线时运行中任务必须失败")

        let heldPending = try await waitForCondition(timeout: 15) {
            self.transferManager.tasks.contains { $0.id == waiting.id && $0.state == .pending }
        }
        XCTAssertTrue(heldPending, "断线后排队任务必须保持等待")
        XCTAssertTrue(waiting.awaitingConnection, "必须展示等待连接")
        XCTAssertEqual(waiting.stateDisplay(locale: AppLanguage.defaultLanguage.locale), "等待连接")

        // 重连前提（任务书 23）：仅终态且无在途连接任务才允许手动 Reconnect，
        // 否则 `reconnectSession` 的合法 guard 直接返回。断线拆卸收敛到
        // 可重连态需要时间，测试必须确定性等待，绝不与其竞态。
        let reconnectable = try await waitForCondition(timeout: 30) {
            session.canReconnect
        }
        XCTAssertTrue(reconnectable, "断线拆卸收敛后会话必须进入可重连态")

        // 重连：新连接装配完成后调度器补位。
        manager.reconnectSession(id: session.id)
        let reconnected = try await waitForCondition(timeout: 40) {
            session.connectionInfo?.phase == .connected && session.connection !== oldConnection
        }
        XCTAssertTrue(reconnected, "重连必须成功且是全新连接")

        try await waitForTerminal(waiting, timeout: 120)
        XCTAssertEqual(waiting.state, .completed, "重连后排队任务必须经新连接完成")

        // 清理运行任务断线残留（如实：断线后远端临时文件必然残留）。
        cleanupResidualUploadTempFiles(in: uploadDir)
    }

    // MARK: - 辅助：真实会话连接

    /// 创建并连接一个私钥 Remote Session（3 次重试，限流噪音防护）。
    private func connectSession(name: String) async throws -> ManagedTerminalSession {
        let host = makePrivateKeyHost(name: name)
        for _ in 1...3 {
            let candidate = manager.createRemoteSession(host: host)
            let settled = try await waitForCondition(timeout: 25) {
                if candidate.connectionInfo?.phase == .awaitingHostTrust {
                    self.manager.resolveHostTrust(sessionID: candidate.id, decision: .trustAlways)
                }
                switch candidate.displayState {
                case .active, .failed, .disconnected, .exited:
                    return true
                default:
                    return false
                }
            }
            if settled, candidate.displayState == .active {
                return candidate
            }
            await manager.closeSession(id: candidate.id)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw SSHError.connectionLost
    }

    /// 打开 Files 面板并加载指定目录。
    private func loadDirectory(_ session: ManagedTerminalSession, path: String) async throws {
        session.selectPane(.files)
        let sftp = try XCTUnwrap(session.sftpService)
        let started = try await waitForCondition(timeout: 20) { sftp.phase != .idle }
        XCTAssertTrue(started, "Files 面板必须启动（当前 \(sftp.phase)）")
        let firstLoad = try await waitForCondition(timeout: 20) { sftp.phase == .loaded }
        XCTAssertTrue(firstLoad)
        sftp.loadAbsolute(path: path)
        let atPath = try await waitForCondition(timeout: 20) {
            sftp.phase == .loaded && sftp.currentPath == path
        }
        XCTAssertTrue(atPath, "夹具目录加载超时（当前 \(sftp.phase)）")
    }

    // MARK: - 辅助：本地文件与夹具

    private var tempLocalRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p11-real-tests", isDirectory: true)
    }

    private func makeLocalFile(name: String, content: Data) -> URL {
        try? FileManager.default.createDirectory(at: tempLocalRoot, withIntermediateDirectories: true)
        let url = tempLocalRoot.appendingPathComponent(name)
        try? content.write(to: url)
        return url
    }

    private func makeLocalDestination(name: String) -> URL {
        let directory = tempLocalRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func makeContent(size: Int, seed: Int) -> Data {
        guard size > 0 else {
            return Data()
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(size)
        for index in 0..<size {
            bytes.append(UInt8(truncatingIfNeeded: index &* 31 &+ seed &+ (index >> 8)))
        }
        return Data(bytes)
    }

    private func hasResidualUploadTempFiles(in remoteDirectory: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: remoteDirectory) else {
            return false
        }
        return names.contains { $0.hasPrefix(".macssh-upload-") }
    }

    private func cleanupResidualUploadTempFiles(in remoteDirectory: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: remoteDirectory) else {
            return
        }
        for name in names where name.hasPrefix(".macssh-upload-") {
            try? FileManager.default.removeItem(atPath: remoteDirectory + "/" + name)
        }
    }

    private func waitForTerminal(
        _ task: TransferTask,
        timeout: TimeInterval = 30
    ) async throws {
        let done = try await waitForCondition(timeout: timeout) {
            task.state.isTerminal
        }
        XCTAssertTrue(done, "传输在 \(timeout) 秒内未到达终态（当前 \(task.state)）")
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

    // MARK: - 辅助：环境与凭据

    private func requireFixture() throws -> String {
        let exists = FileManager.default.fileExists(atPath: Self.fixturePathFile)
        try XCTSkipUnless(exists, "缺少传输夹具交接文件：请使用 Scripts/run-phase11-focus.sh")
        let path = try String(contentsOfFile: Self.fixturePathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(!path.isEmpty, "夹具交接文件为空")
        return path
    }

    private func requireLocalSSHAndTestKey() async throws {
        try await requireLocalSSH()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-phase11-focus.sh 生成"
        )
    }

    private func requireLocalSSH() async throws {
        let reachable = await isTCPPortOpen(host: testHostname, port: testPort)
        try XCTSkipUnless(
            reachable,
            "本机 127.0.0.1:22 未开放：请在 系统设置 → 通用 → 共享 → 远程登录 中开启"
        )
    }

    private func makePrivateKeyHost(name: String) -> MacSSH.Host {
        let host = Host(
            name: name,
            hostname: testHostname,
            port: Int(testPort),
            username: testUsername,
            authenticationType: .privateKey
        )
        host.privateKeyPath = TestKeys.ed25519NoPass
        container.mainContext.insert(host)
        try? container.mainContext.save()
        return host
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
                            socklen_t(MemoryLayout<sockaddr_in>.size
                        ))
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

    /// 确定性竞态门闩（与 Phase 9 / 10 测试同源）。
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
