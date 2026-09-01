import CryptoKit
import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 11 大文件可靠性测试（本机 sshd + 真实 libssh2）：
/// - 1 GB 上传 / 下载：SHA256 三方一致（本地源 / 远端 / 下载回）；
/// - 1 GB ×3 循环：反复上传下载无累积错误、无残留、句柄配对；
/// - 1 GB 双会话串行：全局并发 1（Concurrent Transfer 属 2.0 路线），
///   会话 A 传输中会话 B 保持排队，先后全部完成；
/// - 10 GB 上传 / 下载：字节完整 + 传输全程峰值 RSS 采样有界 +
///   传输前后 RSS 增幅有界（流式 1 MiB 分块：绝不随文件大小线性增长）。
///
/// 夹具生成全程流式（/dev/urandom → dd），绝不整块进内存；
/// 每用例前磁盘空间预检（不足即 skip，绝不让测试把磁盘写满）。
@MainActor
final class SFTPLargeFileTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
    }

    private static let fixturePathFile = "/tmp/macssh_phase10_fixture_path"

    private var knownHostContainer: ModelContainer!
    private var knownHostService: KnownHostService!

    /// 本测试打开的连接；tearDown 统一断开。
    private var openConnections: [SSHConnection] = []

    /// 最近一次成功建连的 info（会话装配需要同一实例观察相位）。
    private var lastInfo: SSHConnectionInfo?

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

    // MARK: - 测试 A：1 GB 上传 + 下载（SHA256 三方一致）

    func testA_1GBUploadDownloadWithTripleSHA256() async throws {
        try await requireEnvironment(minFreeGB: 8)
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let sourceURL = largeFileDirectory().appendingPathComponent("big-1gb.bin")
        try generateStreamingRandomFile(at: sourceURL, gigabytes: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        defer { cleanupResidualUploadTempFiles(in: uploadDir) }
        let sourceHash = try sha256(ofFileAt: sourceURL)

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        // 上传。
        let (uploadTask, rejection) = manager.requestUpload(session: session, localURL: sourceURL)
        XCTAssertNil(rejection)
        let upload = try XCTUnwrap(uploadTask)
        try await waitForTerminal(upload, timeout: 600)
        XCTAssertEqual(upload.state, .completed, "1GB 上传必须完成（\(upload.failureMessage(locale: AppLanguage.defaultLanguage.locale) ?? "")）")
        XCTAssertEqual(upload.transferredBytes, 1_073_741_824)

        // 远端哈希（流式读回计算，证明数据确实在服务器端）。
        let remoteHash = try await sha256OfRemoteFile(connection, path: uploadDir + "/big-1gb.bin")
        XCTAssertEqual(remoteHash, sourceHash, "上传后远端 SHA256 必须与本地源一致")

        // 下载回本地新位置。
        let downloadURL = largeFileDirectory().appendingPathComponent("big-1gb-back.bin")
        defer { try? FileManager.default.removeItem(at: downloadURL) }
        let entry = SFTPFileEntry(
            name: "big-1gb.bin", kind: .regularFile, sizeBytes: 1_073_741_824,
            modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
        )
        let (downloadTask, downloadRejection) = manager.requestDownload(
            session: session, entry: entry, destinationURL: downloadURL
        )
        XCTAssertNil(downloadRejection)
        let download = try XCTUnwrap(downloadTask)
        try await waitForTerminal(download, timeout: 600)
        XCTAssertEqual(download.state, .completed, "1GB 下载必须完成")
        XCTAssertEqual(download.transferredBytes, 1_073_741_824)

        let downloadHash = try sha256(ofFileAt: downloadURL)
        XCTAssertEqual(downloadHash, sourceHash, "下载回文件 SHA256 必须与源一致")
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir))
        XCTAssertFalse(hasResidualDownloadTempFiles(in: largeFileDirectory()))
    }

    // MARK: - 测试 B：1 GB ×3 循环（无累积错误）

    func testB_1GBRoundTripThreeCycles() async throws {
        try await requireEnvironment(minFreeGB: 8)
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let sourceURL = largeFileDirectory().appendingPathComponent("cycle-1gb.bin")
        try generateStreamingRandomFile(at: sourceURL, gigabytes: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        defer { cleanupResidualUploadTempFiles(in: uploadDir) }
        let sourceHash = try sha256(ofFileAt: sourceURL)

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        for cycle in 1...3 {
            // 每轮：删除上一轮远端产物（保证不覆盖语义下可重新上传）。
            if cycle > 1 {
                try await connection.sftpUnlinkFile(uploadDir + "/cycle-\(cycle - 1)-1gb.bin")
            }
            // 目标名带轮次编号：与源文件名错开，避免复制前清目标误删源文件。
            let remoteName = "cycle-\(cycle)-1gb.bin"
            let renamed = makeLocalFileCopy(from: sourceURL, name: remoteName)

            let (uploadTask, _) = manager.requestUpload(session: session, localURL: renamed)
            let upload = try XCTUnwrap(uploadTask)
            try await waitForTerminal(upload, timeout: 600)
            XCTAssertEqual(upload.state, .completed, "循环 \(cycle) 上传必须完成（\(upload.failureMessage(locale: AppLanguage.defaultLanguage.locale) ?? "")）")

            let backURL = largeFileDirectory().appendingPathComponent("cycle-1gb-back-\(cycle).bin")
            let entry = SFTPFileEntry(
                name: remoteName, kind: .regularFile, sizeBytes: 1_073_741_824,
                modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
            )
            let (downloadTask, _) = manager.requestDownload(
                session: session, entry: entry, destinationURL: backURL
            )
            let download = try XCTUnwrap(downloadTask)
            try await waitForTerminal(download, timeout: 600)
            XCTAssertEqual(download.state, .completed, "循环 \(cycle) 下载必须完成（\(download.failureMessage(locale: AppLanguage.defaultLanguage.locale) ?? "")）")

            let backHash = try sha256(ofFileAt: backURL)
            XCTAssertEqual(backHash, sourceHash, "循环 \(cycle) 字节必须完整")
            try? FileManager.default.removeItem(at: backURL)
            try? FileManager.default.removeItem(at: renamed)
        }

        await assertFileHandleMetersBalanced(connection, iteration: "1GB 三轮循环")
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir))
    }

    // MARK: - 测试 C：1 GB 双会话串行（全局并发 1）

    /// 两个会话各 1 GB：全局上限 1 下第二个任务必须排队，
    /// 绝不与首个任务同时活跃；先后全部完成且无残留。
    func testC_1GBSerialAcrossTwoSessions() async throws {
        try await requireEnvironment(minFreeGB: 10)
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let source1 = largeFileDirectory().appendingPathComponent("ser-a.bin")
        let source2 = largeFileDirectory().appendingPathComponent("ser-b.bin")
        try generateStreamingRandomFile(at: source1, gigabytes: 1)
        defer { try? FileManager.default.removeItem(at: source1) }
        defer { cleanupResidualUploadTempFiles(in: uploadDir) }
        try generateStreamingRandomFile(at: source2, gigabytes: 1)
        defer { try? FileManager.default.removeItem(at: source2) }

        let connection1 = try await makeAuthenticatedTestKeyConnection()
        let connection2 = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session1 = try await makeLoadedSession(connection: connection1, path: uploadDir)
        let session2 = try await makeLoadedSession(connection: connection2, path: uploadDir)

        let (task1, _) = manager.requestUpload(session: session1, localURL: source1)
        let (task2, _) = manager.requestUpload(session: session2, localURL: source2)
        let upload1 = try XCTUnwrap(task1)
        let upload2 = try XCTUnwrap(task2)

        // 首个任务进入活跃后：第二个必须保持排队（全局并发 1，绝不并行）。
        let firstActive = try await waitForCondition(timeout: 60) {
            upload1.state != .pending
        }
        XCTAssertTrue(firstActive, "首个任务必须启动")
        XCTAssertEqual(upload2.state, .pending, "全局并发 1：第二个传输必须排队")
        XCTAssertEqual(manager.activeTasks.count, 1, "全局活跃传输绝不超过 1")
        let secondStillQueued = try await waitForCondition(timeout: 3) {
            upload1.state.occupiesActiveSlot && upload2.state == .pending
        }
        XCTAssertTrue(secondStillQueued, "首个传输进行中时第二个绝不提前启动")

        try await waitForTerminal(upload1, timeout: 900)
        XCTAssertEqual(upload1.state, .completed, "串行任务 1 必须完成")
        // 事件驱动补位：任务 1 终态后任务 2 经调度启动并完成。
        try await waitForTerminal(upload2, timeout: 900)
        XCTAssertEqual(upload2.state, .completed, "串行任务 2 必须完成")
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir))
    }

    // MARK: - 测试 D：10 GB 上传 + 下载（字节完整 + RSS 有界）

    /// 10 GB 往返：进度精确、字节完整；传输全程每 0.5 秒采样进程峰值
    /// RSS，峰值相对传输前基线的增幅必须有界（上界 64 MiB：>> 1 MiB
    /// 分块缓冲，<< 10 GB 文件——证明绝不随文件大小线性增长，
    /// 也绝不只比传输前后两点而漏掉过程中的持续上涨）。
    func testD_10GBUploadDownloadWithBoundedMemory() async throws {
        try await requireEnvironment(minFreeGB: 36)
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let sourceURL = largeFileDirectory().appendingPathComponent("big-10gb.bin")
        try generateStreamingRandomFile(at: sourceURL, gigabytes: 10)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        defer { cleanupResidualUploadTempFiles(in: uploadDir) }
        let sourceHash = try sha256(ofFileAt: sourceURL)

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        // 上传 + 内存观测（传输全程峰值 RSS 采样，绝不只看前后两点）。
        let rssBeforeUpload = currentResidentSize()
        let uploadSampler = RSSPeakSampler()
        await uploadSampler.start()
        let (uploadTask, rejection) = manager.requestUpload(session: session, localURL: sourceURL)
        XCTAssertNil(rejection)
        let upload = try XCTUnwrap(uploadTask)
        try await waitForTerminal(upload, timeout: 3_600)
        let uploadPeakRSS = await uploadSampler.stop()
        XCTAssertEqual(upload.state, .completed, "10GB 上传必须完成（\(upload.failureMessage(locale: AppLanguage.defaultLanguage.locale) ?? "")）")
        XCTAssertEqual(upload.transferredBytes, 10 * 1_073_741_824)
        if rssBeforeUpload > 0, uploadPeakRSS > 0 {
            XCTAssertLessThan(
                uploadPeakRSS - rssBeforeUpload, 64 * 1_048_576,
                "10GB 上传过程中峰值 RSS 增幅超出流式上界（禁止整文件进内存）"
            )
        }

        let remoteHash = try await sha256OfRemoteFile(connection, path: uploadDir + "/big-10gb.bin")
        XCTAssertEqual(remoteHash, sourceHash, "10GB 上传后远端 SHA256 必须一致")

        // 下载 + 内存观测。
        let downloadURL = largeFileDirectory().appendingPathComponent("big-10gb-back.bin")
        defer { try? FileManager.default.removeItem(at: downloadURL) }
        let entry = SFTPFileEntry(
            name: "big-10gb.bin", kind: .regularFile, sizeBytes: 10 * 1_073_741_824,
            modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
        )
        let rssBeforeDownload = currentResidentSize()
        let downloadSampler = RSSPeakSampler()
        await downloadSampler.start()
        let (downloadTask, _) = manager.requestDownload(
            session: session, entry: entry, destinationURL: downloadURL
        )
        let download = try XCTUnwrap(downloadTask)
        try await waitForTerminal(download, timeout: 3_600)
        let downloadPeakRSS = await downloadSampler.stop()
        XCTAssertEqual(download.state, .completed, "10GB 下载必须完成")
        XCTAssertEqual(download.transferredBytes, 10 * 1_073_741_824)
        if rssBeforeDownload > 0, downloadPeakRSS > 0 {
            XCTAssertLessThan(
                downloadPeakRSS - rssBeforeDownload, 64 * 1_048_576,
                "10GB 下载过程中峰值 RSS 增幅超出流式上界"
            )
        }

        let downloadHash = try sha256(ofFileAt: downloadURL)
        XCTAssertEqual(downloadHash, sourceHash, "10GB 下载回 SHA256 必须一致")
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir))
    }

    // MARK: - 辅助：流式夹具与目录

    private func largeFileDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p11-large-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 流式生成非零随机文件（/dev/urandom → dd，绝不整块进内存）。
    private func generateStreamingRandomFile(at url: URL, gigabytes: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        process.arguments = [
            "if=/dev/urandom",
            "of=\(url.path)",
            "bs=1m",
            "count=\(gigabytes * 1024)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "dd 生成随机文件失败")
    }

    /// 复制夹具源为独立本地文件（不同会话 / 不同轮次的上传入口用）。
    private func makeLocalFileCopy(from source: URL, name: String) -> URL {
        let url = largeFileDirectory().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            XCTFail("夹具复制失败：\(error)")
        }
        return url
    }

    // MARK: - 辅助：会话装配与等待

    private func makeLoadedSession(
        connection: SSHConnection,
        path: String
    ) async throws -> ManagedTerminalSession {
        openConnections.append(connection)
        try await connection.openSFTPSubsystemIfNeeded()

        let session = ManagedTerminalSession(
            remoteHostID: UUID(),
            hostDisplayName: "Loopback",
            hostname: testHostname,
            port: Int(testPort),
            baseTitle: "Loopback",
            titleCounter: 1
        )
        session.attach(connection: connection, info: try XCTUnwrap(lastInfo))

        let service = SFTPService(connection: connection)
        session.attachSFTPService(service)
        service.loadAbsolute(path: path)
        let loaded = try await waitForCondition(timeout: 20) {
            service.phase == .loaded && service.currentPath == path
        }
        XCTAssertTrue(loaded, "夹具目录加载超时（当前 \(service.phase)）")
        return session
    }

    private func waitForTerminal(
        _ task: TransferTask,
        timeout: TimeInterval
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
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return await predicate()
    }

    private func assertFileHandleMetersBalanced(
        _ connection: SSHConnection,
        iteration: String
    ) async {
        let opens = await connection.sftpFileHandleOpenCount
        let closes = await connection.sftpFileHandleCloseCount
        XCTAssertEqual(closes, opens, "\(iteration)：关闭数必须等于打开数")
        let residual = await connection.openSFTPFileHandleCount
        XCTAssertEqual(residual, 0, "\(iteration)：不得遗留打开的文件句柄")
    }

    // MARK: - 辅助：哈希与内存观测

    /// 流式本地文件 SHA256（1 MiB 分块，绝不全量进内存）。
    private func sha256(ofFileAt url: URL) throws -> Data {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// 流式远端文件 SHA256（经 SFTP，证明数据确实在服务器端）。
    private func sha256OfRemoteFile(
        _ connection: SSHConnection,
        path: String
    ) async throws -> Data {
        var hasher = SHA256()
        let handle = try await connection.sftpOpenFileForRead(path)
        var buffer = [UInt8]()
        do {
            while true {
                let count = try await connection.sftpReadFileChunk(
                    handle,
                    into: &buffer,
                    maxLength: 1_048_576
                )
                if count == 0 {
                    break
                }
                hasher.update(data: Data(buffer[0..<count]))
            }
        } catch {
            await connection.sftpCloseFileHandle(handle)
            throw error
        }
        await connection.sftpCloseFileHandle(handle)
        return Data(hasher.finalize())
    }

    /// 进程常驻内存（字节）；失败返回 0（调用方跳过断言）。
    private func currentResidentSize() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rawPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    /// 传输全程峰值 RSS 采样器：固定间隔采样进程常驻内存并记录峰值；
    /// 峰值有界即证明内存未在传输过程中持续上涨（弥补只比较传输前后两点的缺口）。
    private actor RSSPeakSampler {
        private var peak: Int64 = 0
        private var samplerTask: Task<Void, Never>?

        /// 启动采样（默认 0.5 秒一次；10 GB 传输足以采到数千个样本）。
        func start(interval: TimeInterval = 0.5) {
            peak = 0
            samplerTask?.cancel()
            samplerTask = Task {
                while !Task.isCancelled {
                    record(Self.residentSize())
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
        }

        /// 停止采样并返回观测到的峰值（失败采样不计入：峰值 0 时调用方跳过断言）。
        func stop() -> Int64 {
            samplerTask?.cancel()
            samplerTask = nil
            return peak
        }

        private func record(_ sample: Int64) {
            guard sample > 0 else {
                return
            }
            peak = max(peak, sample)
        }

        private static func residentSize() -> Int64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { infoPointer in
                infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPointer in
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rawPointer, &count)
                }
            }
            return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
        }
    }

    // MARK: - 辅助：环境预检

    /// 磁盘空间预检（任务书：不足即 skip，绝不让测试把磁盘写满）。
    private func requireEnvironment(minFreeGB: Int) async throws {
        try await requireLocalSSHAndTestKey()
        var stats = statfs()
        let directory = largeFileDirectory()
        let statResult = statfs(directory.path, &stats)
        if statResult == 0 {
            let freeBytes = Int64(stats.f_bavail) * Int64(stats.f_bsize)
            try XCTSkipUnless(
                freeBytes >= Int64(minFreeGB) * 1_073_741_824,
                "磁盘可用空间 \(freeBytes / 1_073_741_824) GB < 需求 \(minFreeGB) GB"
            )
        }
    }

    private func requireFixture() throws -> String {
        let exists = FileManager.default.fileExists(atPath: Self.fixturePathFile)
        try XCTSkipUnless(exists, "缺少传输夹具交接文件：请使用 Scripts/run-phase11-largefile.sh")
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
            "缺少测试 ed25519 私钥：请使用 Scripts/run-phase11-largefile.sh 生成"
        )
    }

    // MARK: - 辅助：连接（与 Phase 10 测试同源）

    private func hasResidualUploadTempFiles(in remoteDirectory: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: remoteDirectory) else {
            return false
        }
        return names.contains { $0.hasPrefix(".macssh-upload-") }
    }

    private func hasResidualDownloadTempFiles(in directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains { $0.hasPrefix(".MacSSH-") && $0.hasSuffix(".partial") }
    }

    /// 失败路径残留清理：本测试夹具目录就是本机文件系统（loopback sshd），
    /// 失败 / 断连时远端清理必然失败，但残留文件可直接经 FileManager 删除——
    /// 绝不把 `.partial` 残留泄漏给后续套件（防污染级联）。
    private func cleanupResidualUploadTempFiles(in remoteDirectory: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: remoteDirectory) else {
            return
        }
        for name in names where name.hasPrefix(".macssh-upload-") && name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(atPath: remoteDirectory + "/" + name)
        }
    }

    private func makeAuthenticatedTestKeyConnection() async throws -> SSHConnection {
        for _ in 1...3 {
            let info = SSHConnectionInfo(
                hostID: UUID(),
                hostname: testHostname,
                port: testPort,
                username: testUsername
            )
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
            let connection = SSHConnection(
                configuration: configuration,
                info: info,
                knownHostService: knownHostService,
                sessionTeardownOperations: .live
            )

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
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            XCTAssertTrue(reachedTerminalPhase, "连接必须到达 Trust 或 connected")

            if await MainActor.run(body: { info.phase == .awaitingHostTrust }) {
                await connection.resolveHostTrust(.trustOnce)
            }

            let connected = try await waitForCondition(timeout: 20) {
                await MainActor.run { info.phase == .connected }
            }
            XCTAssertTrue(connected, "测试私钥连接必须完成认证")
            lastInfo = info

            return connection
        }

        throw SSHError.connectionLost
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
