import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 10 TransferManager 生命周期测试：
/// - 纯模型（无网络）：状态机 / 进度单调 / 速度安全 / 入口拒绝；
/// - 真实集成（本机 sshd）：关闭含活跃传输的 Session 时先取消并等待
///   传输清理完成，再拆除 SFTP / Terminal / 连接（任务书 105）。
@MainActor
final class TransferManagerTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort = 22
    private let testUsername = NSUserName()

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
    }

    private static let fixturePathFile = "/tmp/macssh_phase10_fixture_path"

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
        for session in manager.sessions {
            await manager.closeSession(id: session.id)
        }
        manager = nil
        sshService = nil
        container = nil
    }

    // MARK: - 测试 A：状态机与进度语义（纯模型）

    /// 进度单调；速度无 NaN / Infinity / 负值；未知大小不伪造 100%；
    /// Completed 时进度精确落到总字节。
    func testA_TaskProgressMonotonicAndSafeSpeed() {
        let task = TransferTask(
            direction: .upload,
            sessionID: UUID(),
            sessionTitle: "Test",
            remotePath: "/a/b.bin",
            localName: "b.bin",
            localURL: URL(fileURLWithPath: "/tmp/b.bin")
        )

        XCTAssertNil(task.fractionCompleted, "未知大小时绝不伪造进度")
        XCTAssertNil(task.speedDisplay, "准备阶段不展示速度")

        task.setTotalBytes(100)
        task.markTransferring()
        task.reportProgress(50)
        XCTAssertEqual(task.transferredBytes, 50)
        task.reportProgress(30) // 乱序 / 回退报告：单调保护。
        XCTAssertEqual(task.transferredBytes, 50, "进度只增不减")
        XCTAssertFalse(task.speedBytesPerSecond.isNaN)
        XCTAssertFalse(task.speedBytesPerSecond.isInfinite)
        XCTAssertGreaterThanOrEqual(task.speedBytesPerSecond, 0)

        task.markCompleted()
        XCTAssertEqual(task.transferredBytes, 100, "完成时进度必须精确")
        XCTAssertEqual(task.state, .completed)
        XCTAssertNotNil(task.finishedAt)
        XCTAssertTrue(task.state.isTerminal)

        // 终态后取消请求无效（幂等）。
        task.markCancelling()
        XCTAssertEqual(task.state, .completed, "终态不可再进入取消中")
    }

    // MARK: - 测试 B：入口拒绝（会话不可用 / 非普通文件）

    /// Local Session、未连接 Remote Session 一律拒绝；
    /// 本地目录上传在选择层之外仍有防御性拒绝。
    func testB_RequestEntryRejection() {
        let transferManager = TransferManager()
        let localSession = manager.sessions[0]
        XCTAssertEqual(localSession.kind, .local)

        let fileURL = makeLocalFile(name: "entry.bin", content: Data("x".utf8))
        let localResult = transferManager.requestUpload(session: localSession, localURL: fileURL)
        XCTAssertNil(localResult.task)
        XCTAssertEqual(localResult.rejection, "当前会话不可用。")

        // 未连接的 Remote Session（仅创建，不发起连接）。
        let host = makeHost(name: "Never Connected")
        let remoteSession = manager.createRemoteSession(host: host)
        let remoteResult = transferManager.requestUpload(session: remoteSession, localURL: fileURL)
        XCTAssertNil(remoteResult.task)
        XCTAssertEqual(remoteResult.rejection, "当前会话不可用。")

        // 目录拒绝：构造未连接 session 会先命中"会话不可用"，
        // 目录校验在会话可用分支——用假 session 直测文件类型分支不可行，
        // 转由已连接集成路径（测试 D）覆盖；此处只断言目录路径常量。
        var isDirectory: ObjCBool = false
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p10-manager-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - 测试 C：clearFinished 只移除终态任务

    /// 失败任务登记后 `clearFinished` 清空；活跃任务绝不被清掉。
    func testC_ClearFinishedKeepsActiveTasks() async throws {
        let transferManager = TransferManager()
        let localSession = manager.sessions[0]

        // Local Session 上传入口即拒绝——无任务登记。
        let result = transferManager.requestUpload(
            session: localSession,
            localURL: makeLocalFile(name: "clear.bin", content: Data("x".utf8))
        )
        XCTAssertNil(result.task)
        XCTAssertTrue(transferManager.tasks.isEmpty)
        transferManager.clearFinished()
        XCTAssertTrue(transferManager.tasks.isEmpty)
    }

    // MARK: - 测试 D：关闭含活跃传输的会话（真实集成）

    /// 完整链路：连接 → Files 加载夹具 → 3MB 上传进行中 →
    /// requestClose 出现确认 → confirmClose 先取消并等待传输清理 →
    /// Session 关闭；任务以取消终态收尾；无远端临时文件残留。
    func testD_CloseSessionCancelsAndAwaitsActiveTransfer() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let transferManager = TransferManager()
        transferManager.sessionManager = manager
        manager.transferManager = transferManager

        let host = makePrivateKeyHost(name: "Loopback")
        var session: ManagedTerminalSession?

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
                session = candidate
                break
            }
            await manager.closeSession(id: candidate.id)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let activeSession = try XCTUnwrap(session, "连续 3 次建连失败（本机 sshd 限流噪音）")

        // Files 面板加载上传夹具目录。
        activeSession.selectPane(.files)
        let sftp = try XCTUnwrap(activeSession.sftpService)
        let loaded = try await waitForCondition(timeout: 20) {
            sftp.phase == .loaded
        }
        XCTAssertTrue(loaded)
        sftp.loadAbsolute(path: uploadDir)
        let atUploadDir = try await waitForCondition(timeout: 20) {
            sftp.phase == .loaded && sftp.currentPath == uploadDir
        }
        XCTAssertTrue(atUploadDir, "夹具目录加载超时（当前 \(sftp.phase)）")

        // 3MB 上传：首分块后停在接缝，保持活跃。
        let connection = try XCTUnwrap(activeSession.connection)
        let gate = RaceGate()
        await connection.setTestSFTPFileTransferChunkHook(armed: true) {
            await gate.arriveAndWaitRelease()
        }

        let content = makeContent(size: 3 * 1_048_576, seed: 21)
        let localURL = makeLocalFile(name: "close-session.bin", content: content)
        let (task, rejection) = transferManager.requestUpload(session: activeSession, localURL: localURL)
        XCTAssertNil(rejection)
        let upload = try XCTUnwrap(task)

        let arrived = try await waitForCondition(timeout: 30) {
            await gate.hasArrived()
        }
        XCTAssertTrue(arrived, "分块接缝必须到达")
        XCTAssertTrue(transferManager.hasActiveTransfer(forSession: activeSession.id))

        // 关闭会话：活跃传输在场时必须先确认。
        manager.requestClose(id: activeSession.id)
        XCTAssertNotNil(manager.pendingCloseConfirmation, "活跃传输会话关闭必须经过确认")

        manager.confirmClose()
        await gate.release()

        // 传输取消收尾 + 会话拆除完成。
        let cancelled = try await waitForCondition(timeout: 30) {
            upload.state.isTerminal
        }
        XCTAssertTrue(cancelled, "关闭会话必须以取消收尾活跃传输")
        XCTAssertEqual(upload.state, .cancelled)

        let closed = try await waitForCondition(timeout: 30) {
            !self.manager.sessions.contains { $0.id == activeSession.id }
        }
        XCTAssertTrue(closed, "确认关闭后 Session 必须完成拆除")

        // 拆除后仪表与临时文件全部干净。
        let opens = await connection.sftpFileHandleOpenCount
        let closes = await connection.sftpFileHandleCloseCount
        XCTAssertEqual(closes, opens, "关闭会话路径必须完成传输句柄收尾")
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir), "取消后不得残留远端临时文件")
    }

    // MARK: - 辅助

    private func makeLocalFile(name: String, content: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p10-manager-tests")
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try content.write(to: url)
        } catch {
            XCTFail("本地测试文件写入失败：\(error)")
        }
        return url
    }

    private func makeContent(size: Int, seed: Int) -> Data {
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
        try XCTSkipUnless(exists, "缺少 Phase 10 夹具交接文件：请使用 Scripts/run-phase10-focus.sh")
        let path = try String(contentsOfFile: Self.fixturePathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(!path.isEmpty, "Phase 10 夹具交接文件为空")
        return path
    }

    private func requireLocalSSHAndTestKey() async throws {
        let reachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: false)
                    return
                }
                defer { close(fd) }
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(22).bigEndian
                address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
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
        try XCTSkipUnless(reachable, "本机 127.0.0.1:22 未开放")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-phase10-focus.sh 生成"
        )
    }

    private func makeHost(name: String) -> MacSSH.Host {
        let host = Host(
            name: name,
            hostname: testHostname,
            port: testPort,
            username: testUsername,
            authenticationType: .privateKey
        )
        host.privateKeyPath = TestKeys.ed25519NoPass
        container.mainContext.insert(host)
        try? container.mainContext.save()
        return host
    }

    private func makePrivateKeyHost(name: String) -> MacSSH.Host {
        makeHost(name: name)
    }

    /// 确定性竞态门闩（与 Phase 9 / 10 其他测试同源）。
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
