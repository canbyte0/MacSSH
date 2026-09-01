import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 11 资源稳定性测试（本机 sshd + 真实 libssh2）：
/// 传输高峰（双会话传输队列，全局串行执行）→ 全部终态 → 会话拆除后，
/// FD / socket / 线程数 / RSS 必须回落到基线附近（泄漏检测），
/// 且空闲期间绝不 busy-loop（CPU 增量接近 0）。
///
/// 前置与 `TransferQueueRealTests` 相同：本机远程登录已开启，
/// 并经 `Scripts/run-phase11-focus.sh` 生成测试私钥与夹具。
@MainActor
final class TransferResourceTests: XCTestCase {
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

    // MARK: - 测试 A：基线 → 传输高峰 → 拆除 → 恢复

    /// 双会话各上传 8 个 256 KB 文件（全局串行排满队列），
    /// 全部完成并拆除会话后：FD / socket / 线程数回落基线附近，
    /// RSS 增长有界；随后空闲 10 秒，CPU 增量接近 0。
    func testA_ResourcesReturnToBaselineAfterTransferBurst() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        // ── 基线（任何会话 / 传输都未开始）──
        let baselineFD = probeFileDescriptor()
        let baselineSockets = openSocketCount()
        let baselineThreads = threadCount()
        let baselineRSS = residentMemoryBytes()

        // ── 高峰：双会话传输队列（全局串行执行）──
        let session1 = try await connectSession(name: "Resource-A")
        let session2 = try await connectSession(name: "Resource-B")
        try await loadDirectory(session1, path: uploadDir)
        try await loadDirectory(session2, path: uploadDir)

        var tasks = [TransferTask]()
        for session in [session1, session2] {
            for index in 1...8 {
                let localURL = makeLocalFile(
                    name: "res-\(session.id.uuidString.prefix(8))-\(index).bin",
                    content: makeContent(size: 256 * 1024, seed: index)
                )
                let result = transferManager.requestUpload(session: session, localURL: localURL)
                XCTAssertNil(result.rejection, "资源测试任务入队被拒绝")
                if let task = result.task {
                    tasks.append(task)
                }
            }
        }
        XCTAssertEqual(tasks.count, 16)

        let drained = try await waitForCondition(timeout: 120) {
            self.transferManager.tasks.allSatisfy { $0.state.isTerminal }
        }
        XCTAssertTrue(drained, "16 个传输必须全部到达终态")
        for task in tasks {
            XCTAssertEqual(task.state, .completed, "资源测试传输必须完成（\(task.failureMessage(locale: AppLanguage.defaultLanguage.locale) ?? "")）")
        }

        // ── 峰值采样（会话仍持有：socket / FD 应高于基线）──
        let peakSockets = openSocketCount()
        XCTAssertGreaterThanOrEqual(
            peakSockets, baselineSockets + 2,
            "双会话同时持有连接应至少新增 2 个 socket（基线 \(baselineSockets)，峰值 \(peakSockets)）"
        )

        // ── 拆除：关闭全部会话，等待资源回收 ──
        await manager.closeSession(id: session1.id)
        await manager.closeSession(id: session2.id)
        let sessionsGone = try await waitForCondition(timeout: 30) {
            !self.manager.sessions.contains { $0.id == session1.id || $0.id == session2.id }
        }
        XCTAssertTrue(sessionsGone, "会话拆除必须完成")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // ── 恢复断言 ──
        let afterFD = probeFileDescriptor()
        let afterSockets = openSocketCount()
        let afterThreads = threadCount()
        let afterRSS = residentMemoryBytes()

        // FD 探测只能证明"无持续增长"，容差必须覆盖宿主层系统噪声：
        // xcodebuild 测试宿主会启动真实 App 入口（Local Terminal + os_log /
        // XPC / SwiftData 惰性打开若干 FD，实测最多约 6 个且时机不定）。
        // 真实泄漏随传输数线性增长（16 次传输 ≫ 容差），绝不被本容差掩盖；
        // socket / 线程 / RSS 另有独立断言共同兜底。
        XCTAssertLessThanOrEqual(
            afterFD - baselineFD,
            8,
            "传输高峰 + 拆除后 FD 不应持续增长（基线 \(baselineFD)，恢复后 \(afterFD)）"
        )
        XCTAssertLessThanOrEqual(
            afterSockets - baselineSockets,
            1,
            "会话拆除后 socket 必须全部关闭（基线 \(baselineSockets)，峰值 \(peakSockets)，恢复后 \(afterSockets)）"
        )
        XCTAssertLessThanOrEqual(
            afterThreads - baselineThreads,
            4,
            "传输高峰 + 拆除后线程数不应持续增长（基线 \(baselineThreads)，恢复后 \(afterThreads)）"
        )
        if baselineRSS > 0, afterRSS > 0 {
            XCTAssertLessThanOrEqual(
                afterRSS - baselineRSS,
                64 * 1024 * 1024,
                "传输高峰 + 拆除后 RSS 增长应有界（基线 \(baselineRSS)，恢复后 \(afterRSS)）"
            )
        }

        // ── 空闲 CPU：拆除后 10 秒绝不 busy-loop ──
        let cpuBefore = Self.processCPUSeconds()
        try await Task.sleep(nanoseconds: 10_000_000_000)
        let cpuDelta = Self.processCPUSeconds() - cpuBefore
        XCTAssertLessThanOrEqual(
            cpuDelta,
            1.0,
            "拆除后空闲 10 秒 CPU 增量应接近 0（实测 \(String(format: "%.3f", cpuDelta)) 秒）"
        )
    }

    // MARK: - 辅助：真实会话连接（与 TransferQueueRealTests 同源）

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
            .appendingPathComponent("macssh-p11-resource-tests", isDirectory: true)
    }

    private func makeLocalFile(name: String, content: Data) -> URL {
        try? FileManager.default.createDirectory(at: tempLocalRoot, withIntermediateDirectories: true)
        let url = tempLocalRoot.appendingPathComponent(name)
        try? content.write(to: url)
        return url
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
        let reachable = await isTCPPortOpen(host: testHostname, port: testPort)
        try XCTSkipUnless(reachable, "本机 127.0.0.1:22 未开放")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-phase11-focus.sh 生成"
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

    // MARK: - 辅助：资源测量

    /// 通过打开 /dev/null 探测当前 FD 高位值，用于泄漏检测。
    private func probeFileDescriptor() -> Int32 {
        let fd = open("/dev/null", O_RDONLY)
        if fd >= 0 {
            close(fd)
        }
        return fd
    }

    /// 当前进程打开的 socket 数量（PROC_PIDLISTFDS；socket 类型常量 = 2）。
    /// 失败返回 -1（调用方跳过断言）。
    private func openSocketCount() -> Int {
        let needed = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return -1 }
        let capacity = Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let got = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard got > 0 else { return -1 }
        let entries = Int(got) / MemoryLayout<proc_fdinfo>.stride
        return fds.prefix(entries).filter { $0.proc_fdtype == 2 }.count
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

    /// 当前进程常驻内存（字节）。
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
