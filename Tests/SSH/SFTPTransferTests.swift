import CryptoKit
import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 10 SFTP 传输真实测试：TransferManager 生命周期 + 流式
/// Upload / Download，经真实本机 sshd + 真实 libssh2 验证。
///
/// 前置：系统设置 → 共享 → 远程登录 已开启，并经
/// `Scripts/run-phase10-focus.sh` 生成测试私钥与 Phase 10 夹具。
@MainActor
final class SFTPTransferTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
    }

    private static let fixturePathFile = "/tmp/macssh_phase10_fixture_path"

    private var knownHostContainer: ModelContainer!
    private var knownHostService: KnownHostService!

    /// 本测试打开的连接；tearDown 统一断开，避免泄漏。
    private var openConnections: [SSHConnection] = []

    /// 本测试创建的本地临时文件；tearDown 统一清理。
    private var tempLocalFiles: [URL] = []

    /// 最近一次成功建连的 info（session 装配需要同一实例观察相位）。
    private var lastInfo: SSHConnectionInfo?

    override func setUp() async throws {
        continueAfterFailure = false
        openConnections = []
        tempLocalFiles = []
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        knownHostContainer = try ModelContainer(for: schema, configurations: [configuration])
        knownHostService = KnownHostService(modelContainer: knownHostContainer)
    }

    override func tearDown() async throws {
        for url in tempLocalFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempLocalFiles.removeAll()
        for connection in openConnections {
            await connection.disconnect()
        }
        openConnections.removeAll()
        await MainActor.run { knownHostService.removeAll() }
        knownHostService = nil
        knownHostContainer = nil
    }

    // MARK: - 测试 A：小尺寸矩阵往返（0B / 1B / 1KB / 64KB / 非整数倍）

    /// 上传与下载在 0 字节、1 字节、1KB、64KB、128KiB+17（非分块整数倍）
    /// 全部尺寸下字节精确往返；Completed 时进度精确等于总字节。
    func testA_SmallSizeUploadDownloadRoundTrip() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let sizes: [Int] = [0, 1, 1_024, 65_536, 131_089]
        for (index, size) in sizes.enumerated() {
            let connection = try await makeAuthenticatedTestKeyConnection()
            let manager = TransferManager()
            let session = try await makeLoadedSession(connection: connection, path: uploadDir)

            let content = makeContent(size: size, seed: index)
            let localURL = makeLocalFile(name: "size-\(size).bin", content: content)

            // 上传。
            let (uploadTask, rejection) = manager.requestUpload(session: session, localURL: localURL)
            XCTAssertNil(rejection, "尺寸 \(size)：上传请求被拒绝")
            let upload = try XCTUnwrap(uploadTask)
            try await waitForTerminal(upload)

            XCTAssertEqual(upload.state, .completed, "尺寸 \(size)：上传必须完成")
            XCTAssertEqual(upload.transferredBytes, Int64(size), "尺寸 \(size)：最终字节必须精确")
            XCTAssertEqual(upload.totalBytes, Int64(size))

            let remotePath = uploadDir + "/size-\(size).bin"
            let remoteData = try await connection.testReadWholeRemoteFile(remotePath)
            XCTAssertEqual(remoteData, content, "尺寸 \(size)：远端内容必须与本地一致")
            XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir), "尺寸 \(size)：不得残留上传临时文件")

            // 下载（新目标文件）。
            let downloadURL = makeLocalPath(name: "size-\(size)-roundtrip.bin")
            let entry = SFTPFileEntry(
                name: "size-\(size).bin",
                kind: .regularFile,
                sizeBytes: UInt64(size),
                modifiedAt: nil,
                permissions: 0o600,
                ownerUID: nil,
                ownerGID: nil
            )
            let (downloadTask, downloadRejection) = manager.requestDownload(
                session: session,
                entry: entry,
                destinationURL: downloadURL
            )
            XCTAssertNil(downloadRejection, "尺寸 \(size)：下载请求被拒绝")
            let download = try XCTUnwrap(downloadTask)
            try await waitForTerminal(download)

            XCTAssertEqual(download.state, .completed, "尺寸 \(size)：下载必须完成")
            XCTAssertEqual(download.transferredBytes, Int64(size))
            let downloaded = try Data(contentsOf: downloadURL)
            XCTAssertEqual(downloaded, content, "尺寸 \(size)：下载内容必须与源一致")
            XCTAssertFalse(hasResidualDownloadTempFiles(in: localDirectory(of: downloadURL)), "尺寸 \(size)：不得残留下载临时文件")

            await connection.disconnect()
        }
    }

    // MARK: - 测试 B：中文 / emoji / 空格 / 特殊字符文件名

    /// 全部文件名经上传往返后内容与名称完整保持。
    func testB_UnicodeAndSpecialFilenames() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let names = [
            "中文文件.txt",
            "emoji-😀🚀.txt",
            "hello world.txt",
            "special 'quote' \"double\".txt",
        ]
        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        for (index, name) in names.enumerated() {
            let content = makeContent(size: 2_048 + index * 17, seed: index)
            let localURL = makeLocalFile(name: name, content: content)

            let (task, rejection) = manager.requestUpload(session: session, localURL: localURL)
            XCTAssertNil(rejection, "\(name)：上传被拒绝")
            let upload = try XCTUnwrap(task)
            try await waitForTerminal(upload)
            XCTAssertEqual(upload.state, .completed, "\(name)：上传必须完成")

            let remoteData = try await connection.testReadWholeRemoteFile(uploadDir + "/" + name)
            XCTAssertEqual(remoteData, content, "\(name)：远端内容必须一致")
        }
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir))
    }

    // MARK: - 测试 C：100MB 大文件 + SHA256 + 内存上界观测

    /// 上传 100MB 随机数据（远端 SHA256 与本地一致）→ 下载到新位置
    /// （SHA256 再次一致）；传输期间进程常驻内存增幅必须有界
    /// （流式 1 MiB 分块：远低于文件总大小）。
    func testC_100MBRoundTripWithSHA256AndBoundedMemory() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let sourceURL = makeLocalPath(name: "big-100mb.bin")
        try generateRandomFile(at: sourceURL, megabytes: 100)
        tempLocalFiles.append(sourceURL)
        let sourceHash = try sha256(ofFileAt: sourceURL)

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        // 上传 + 内存观测。
        let rssBefore = currentResidentSize()
        let (uploadTask, rejection) = manager.requestUpload(session: session, localURL: sourceURL)
        XCTAssertNil(rejection)
        let upload = try XCTUnwrap(uploadTask)
        try await waitForTerminal(upload, timeout: 180)
        XCTAssertEqual(upload.state, .completed, "100MB 上传必须完成")
        XCTAssertEqual(upload.transferredBytes, 100 * 1_048_576)
        let rssAfterUpload = currentResidentSize()

        let remoteHash = try await sha256OfRemoteFile(connection, path: uploadDir + "/big-100mb.bin")
        XCTAssertEqual(remoteHash, sourceHash, "上传后远端 SHA256 必须与本地一致")

        // 下载 + 校验。
        let downloadURL = makeLocalPath(name: "big-100mb-download.bin")
        let entry = SFTPFileEntry(
            name: "big-100mb.bin",
            kind: .regularFile,
            sizeBytes: 100 * 1_048_576,
            modifiedAt: nil,
            permissions: 0o600,
            ownerUID: nil,
            ownerGID: nil
        )
        let (downloadTask, downloadRejection) = manager.requestDownload(
            session: session,
            entry: entry,
            destinationURL: downloadURL
        )
        XCTAssertNil(downloadRejection)
        let download = try XCTUnwrap(downloadTask)
        try await waitForTerminal(download, timeout: 180)
        XCTAssertEqual(download.state, .completed, "100MB 下载必须完成")

        let downloadHash = try sha256(ofFileAt: downloadURL)
        XCTAssertEqual(downloadHash, sourceHash, "下载文件 SHA256 必须与源一致")

        // 内存上界：100MB 文件绝不全量进内存；给系统留充分噪音余量，
        // 上界取 40 MiB（>> 1 MiB 分块缓冲，<< 100 MB 文件）。
        if rssBefore > 0, rssAfterUpload > 0 {
            let delta = rssAfterUpload - rssBefore
            XCTAssertLessThan(
                delta, 40 * 1_048_576,
                "100MB 上传期间内存增幅 \(delta) 超出流式上界（禁止整文件进内存）"
            )
        }
    }

    // MARK: - 测试 D：默认不覆盖已有远端文件

    /// 目标已存在：任务 Failed + 明确文案；远端原文件字节不被触碰；
    /// 无临时文件残留。
    func testD_UploadToExistingTargetFailsWithoutOverwrite() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        // 先成功上传一次，制造已存在目标。
        let original = Data("existing-remote-content".utf8)
        let localURL = makeLocalFile(name: "exists.bin", content: original)
        let (first, _) = manager.requestUpload(session: session, localURL: localURL)
        try await waitForTerminal(try XCTUnwrap(first))
        XCTAssertEqual(first?.state, .completed)

        // 同名再次上传（不同内容）：必须失败且不覆盖。
        let modified = Data("modified-content".utf8)
        let modifiedURL = makeLocalFile(name: "exists.bin", content: modified, uniqueDirectory: true)
        let (second, rejection) = manager.requestUpload(session: session, localURL: modifiedURL)
        XCTAssertNil(rejection)
        let repeated = try XCTUnwrap(second)
        try await waitForTerminal(repeated)

        XCTAssertEqual(repeated.state, .failed)
        XCTAssertEqual(
            repeated.failureMessage,
            "远程文件已存在，不会自动覆盖该文件。"
        )
        let remoteData = try await connection.testReadWholeRemoteFile(uploadDir + "/exists.bin")
        XCTAssertEqual(remoteData, original, "失败上传绝不允许触碰远端原文件")
        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir))
    }

    // MARK: - 测试 E：下载源不存在 / 仅普通文件

    /// 下载不存在文件 → Failed；非普通文件条目（目录 / 符号链接）请求层拒绝。
    func testE_DownloadMissingOrNonRegularRejected() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        let missingEntry = SFTPFileEntry(
            name: "no-such-file.bin",
            kind: .regularFile,
            sizeBytes: 10,
            modifiedAt: nil,
            permissions: 0o600,
            ownerUID: nil,
            ownerGID: nil
        )
        let (missingTask, _) = manager.requestDownload(
            session: session,
            entry: missingEntry,
            destinationURL: makeLocalPath(name: "no-such.bin")
        )
        let missing = try XCTUnwrap(missingTask)
        try await waitForTerminal(missing)
        XCTAssertEqual(missing.state, .failed, "下载不存在的文件必须失败")
        XCTAssertEqual(missing.failureMessage, "远程文件不存在。")

        // 目录与符号链接在请求层直接拒绝（绝不进入传输）。
        let dirEntry = SFTPFileEntry(
            name: "dir", kind: .directory, sizeBytes: nil,
            modifiedAt: nil, permissions: 0o755, ownerUID: nil, ownerGID: nil
        )
        let dirResult = manager.requestDownload(
            session: session,
            entry: dirEntry,
            destinationURL: makeLocalPath(name: "dir.bin")
        )
        XCTAssertNil(dirResult.task)
        XCTAssertEqual(dirResult.rejection, "仅支持下载普通文件。")

        let linkEntry = SFTPFileEntry(
            name: "link", kind: .symlink, sizeBytes: nil,
            modifiedAt: nil, permissions: 0o777, ownerUID: nil, ownerGID: nil
        )
        XCTAssertNil(manager.requestDownload(
            session: session,
            entry: linkEntry,
            destinationURL: makeLocalPath(name: "link.bin")
        ).task)
    }

    // MARK: - 测试 F：远端权限拒绝

    /// 上传到可列举但无写权限的目录：Failed + 权限文案；连接保持存活。
    func testF_UploadToRestrictedDirectoryFails() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: fixture + "/readonly")

        let localURL = makeLocalFile(name: "denied.bin", content: Data("denied".utf8))
        let (task, _) = manager.requestUpload(session: session, localURL: localURL)
        let upload = try XCTUnwrap(task)
        try await waitForTerminal(upload)

        XCTAssertEqual(upload.state, .failed, "权限拒绝目录上传必须失败")
        XCTAssertEqual(upload.failureMessage, "权限不足，无法完成传输。")

        let alive = await connection.hasLiveSession
        XCTAssertTrue(alive, "业务错误绝不断开连接")
    }

    // MARK: - 测试 G：取消上传 ×10（幂等 + 清理）

    /// 每轮：3MB 上传 → 首个分块后取消 → Cancelled；重复取消幂等；
    /// 无远端临时文件残留；句柄打开 / 关闭计数配对。
    func testG_CancelUploadTenTimes() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let content = makeContent(size: 3 * 1_048_576, seed: 7)
        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        for iteration in 1...10 {
            let localURL = makeLocalFile(name: "cancel-up-\(iteration).bin", content: content)
            let gate = RaceGate()
            await connection.setTestSFTPFileTransferChunkHook(armed: true) {
                await gate.arriveAndWaitRelease()
            }

            let (task, _) = manager.requestUpload(session: session, localURL: localURL)
            let upload = try XCTUnwrap(task)

            let arrived = try await waitForCondition(timeout: 30) {
                await gate.hasArrived()
            }
            XCTAssertTrue(arrived, "迭代 \(iteration)：分块接缝必须到达")

            manager.cancel(upload.id)
            manager.cancel(upload.id) // 幂等：重复取消绝不产生副作用。
            await gate.release()

            try await waitForTerminal(upload)
            XCTAssertEqual(upload.state, .cancelled, "迭代 \(iteration)：必须以取消终态收尾")
            await connection.setTestSFTPFileTransferChunkHook(armed: false, nil)
        }

        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir), "10 轮取消后不得残留临时文件")
        await assertFileHandleMetersBalanced(connection, iteration: "取消上传")
    }

    // MARK: - 测试 H：取消下载 ×10（幂等 + 本地清理）

    /// 每轮：3MB 下载 → 首个分块后取消 → Cancelled；本地无
    /// `.MacSSH-*.partial` 残留。
    func testH_CancelDownloadTenTimes() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let content = makeContent(size: 3 * 1_048_576, seed: 8)
        let remotePath = uploadDir + "/cancel-source.bin"
        try content.write(to: URL(fileURLWithPath: remotePath))

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        let entry = SFTPFileEntry(
            name: "cancel-source.bin",
            kind: .regularFile,
            sizeBytes: UInt64(content.count),
            modifiedAt: nil,
            permissions: 0o600,
            ownerUID: nil,
            ownerGID: nil
        )

        for iteration in 1...10 {
            let gate = RaceGate()
            await connection.setTestSFTPFileTransferChunkHook(armed: true) {
                await gate.arriveAndWaitRelease()
            }

            let (task, _) = manager.requestDownload(
                session: session,
                entry: entry,
                destinationURL: makeLocalPath(name: "cancel-down-\(iteration).bin")
            )
            let download = try XCTUnwrap(task)

            let arrived = try await waitForCondition(timeout: 30) {
                await gate.hasArrived()
            }
            XCTAssertTrue(arrived, "迭代 \(iteration)：分块接缝必须到达")

            manager.cancel(download.id)
            await gate.release()

            try await waitForTerminal(download)
            XCTAssertEqual(download.state, .cancelled, "迭代 \(iteration)：必须以取消终态收尾")
            await connection.setTestSFTPFileTransferChunkHook(armed: false, nil)
        }

        XCTAssertFalse(
            hasResidualDownloadTempFiles(in: tempLocalRoot),
            "10 轮取消后不得残留本地下载临时文件"
        )
        await assertFileHandleMetersBalanced(connection, iteration: "取消下载")
    }

    // MARK: - 测试 I：连接丢失 → Failed（绝不续传）

    /// 传输进行中（句柄已打开）断开连接：任务以连接丢失文案失败，
    /// 绝无自动重连 / 续传行为。
    func testI_ConnectionLostDuringUploadFailsWithoutResume() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let content = makeContent(size: 3 * 1_048_576, seed: 9)
        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        let gate = RaceGate()
        await connection.setTestSFTPAfterFileHandleOpenHook {
            await gate.arriveAndWaitRelease()
        }

        let localURL = makeLocalFile(name: "lost-conn.bin", content: content)
        let (task, _) = manager.requestUpload(session: session, localURL: localURL)
        let upload = try XCTUnwrap(task)

        let arrived = try await waitForCondition(timeout: 30) {
            await gate.hasArrived()
        }
        XCTAssertTrue(arrived, "句柄打开接缝必须到达")

        // 传输在途：先释放门闩让打开操作收尾（否则拆除排空屏障与
        // 门闩互等），再断开连接（模拟连接丢失）。
        await gate.release()
        await connection.disconnect()

        try await waitForTerminal(upload)
        XCTAssertEqual(upload.state, .failed, "连接丢失必须以失败收尾")
        let message = upload.failureMessage ?? ""
        XCTAssertTrue(
            message.hasPrefix("SSH 连接已断开，传输失败。"),
            "连接丢失文案前缀必须如实：\(message)"
        )
        // 诚实断言（P1-2 整改）：连接丢失后远端清理物理上不可能（不续传、
        // 不重连，任务书），.partial **确实残留**——测试绝不手工删除后再断言，
        // 而是先如实验证产品真实行为：残留存在 + 失败文案明示残留文件名。
        let residualNames = residualUploadTempFileNames(in: uploadDir)
        XCTAssertFalse(residualNames.isEmpty, "连接丢失后远端临时文件必然残留（产品真实行为）")
        XCTAssertTrue(
            residualNames.contains(where: { message.contains($0) }),
            "失败文案必须如实携带残留临时文件名：\(message)"
        )
        // 验证完成后清理夹具，避免污染后续用例（断言已在清理前完成）。
        cleanupResidualUploadTempFiles(in: uploadDir)
    }

    // MARK: - 测试 J：20 轮上传 + 20 轮下载生命周期

    /// 反复创建 / 完成传输：状态机一致、无泄漏（句柄与在途计数归零）。
    func testJ_TwentyUploadAndDownloadLifecycles() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        for iteration in 1...20 {
            let content = makeContent(size: 4_096 + iteration, seed: iteration)
            let localURL = makeLocalFile(name: "life-\(iteration).bin", content: content)

            let (uploadTask, _) = manager.requestUpload(session: session, localURL: localURL)
            let upload = try XCTUnwrap(uploadTask)
            try await waitForTerminal(upload)
            XCTAssertEqual(upload.state, .completed, "迭代 \(iteration)：上传必须完成")

            let entry = SFTPFileEntry(
                name: "life-\(iteration).bin",
                kind: .regularFile,
                sizeBytes: UInt64(content.count),
                modifiedAt: nil,
                permissions: 0o600,
                ownerUID: nil,
                ownerGID: nil
            )
            let (downloadTask, _) = manager.requestDownload(
                session: session,
                entry: entry,
                destinationURL: makeLocalPath(name: "life-\(iteration)-back.bin")
            )
            let download = try XCTUnwrap(downloadTask)
            try await waitForTerminal(download)
            XCTAssertEqual(download.state, .completed, "迭代 \(iteration)：下载必须完成")
        }

        await assertFileHandleMetersBalanced(connection, iteration: "生命周期")
        XCTAssertFalse(manager.hasActiveTransfer, "全部终态后不得有活跃传输")
    }

    // MARK: - 测试 K：传输 × Terminal 共存（echo + ping + Ctrl+C）

    /// 10MB 上传期间：同一连接上的交互 Shell 正常收发——
    /// echo 有输出、ping 可运行、Ctrl+C 可中断；上传照常完成。
    func testK_TerminalCoexistsWithUpload() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let content = makeContent(size: 10 * 1_048_576, seed: 11)
        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        try await connection.openInteractiveShell(columns: 80, rows: 24)

        let markerPath = "/tmp/macssh-p10-coexist-\(UUID().uuidString.prefix(8))"
        let (task, _) = manager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "coexist.bin", content: content)
        )
        let upload = try XCTUnwrap(task)

        // 传输进行中：Shell echo（副作用文件在本地验证）。
        try await connection.writeChannelInput(input("echo PHASE10_ALIVE > \(markerPath)\r"))
        let echoSeen = try await waitForCondition(timeout: 15) {
            FileManager.default.fileExists(atPath: markerPath)
        }
        XCTAssertTrue(echoSeen, "传输期间 Terminal echo 必须正常执行")
        try? FileManager.default.removeItem(atPath: markerPath)

        // ping 启动后用 Ctrl+C 中断：输入输出路径全程可用。
        try await connection.writeChannelInput(input("ping -c 100 127.0.0.1\r"))
        try await Task.sleep(nanoseconds: 500_000_000)
        try await connection.writeChannelInput(input("\u{3}"))
        try await connection.writeChannelInput(input("echo PHASE10_CTRL_C_OK > \(markerPath)\r"))
        let ctrlCSeen = try await waitForCondition(timeout: 15) {
            FileManager.default.fileExists(atPath: markerPath)
        }
        XCTAssertTrue(ctrlCSeen, "Ctrl+C 后 Shell 必须继续响应（传输不得独占连接）")
        try? FileManager.default.removeItem(atPath: markerPath)
        try await connection.writeChannelInput(input("exit\r"))

        try await waitForTerminal(upload, timeout: 60)
        XCTAssertEqual(upload.state, .completed, "Terminal 共存时上传必须完成")
    }

    // MARK: - 测试 L：传输 × Browser 共存

    /// 10MB 上传期间：Browser（SFTPService）仍可导航 / 刷新。
    func testL_BrowserCoexistsWithUpload() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let content = makeContent(size: 10 * 1_048_576, seed: 12)
        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        let browser = try XCTUnwrap(session.sftpService)
        let (task, _) = manager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "browser-coexist.bin", content: content)
        )
        let upload = try XCTUnwrap(task)

        // 传输进行中：导航到夹具根目录再刷新回上传目录。
        browser.loadAbsolute(path: fixture)
        let navigated = try await waitForCondition(timeout: 15) {
            browser.currentPath == fixture && browser.phase == .loaded
        }
        XCTAssertTrue(navigated, "传输期间 Browser 导航必须可用")

        browser.loadAbsolute(path: uploadDir)
        let back = try await waitForCondition(timeout: 15) {
            browser.currentPath == uploadDir && browser.phase == .loaded
        }
        XCTAssertTrue(back, "传输期间 Browser 返回导航必须可用")

        try await waitForTerminal(upload, timeout: 60)
        XCTAssertEqual(upload.state, .completed, "Browser 共存时上传必须完成")
    }

    // MARK: - 测试 M：每会话单活跃传输 + 队列补位 + 会话隔离（Phase 11）

    /// 会话槽位满时第二个请求不再拒绝而是入队保持 Pending；
    /// 首个完成后调度器事件驱动补位启动排队任务；
    /// `hasActiveTransfer(forSession:)` 按 Session 隔离。
    func testM_PerSessionSingleActiveAndQueueBackfill() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        let content = makeContent(size: 3 * 1_048_576, seed: 13)
        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        let gate = RaceGate()
        await connection.setTestSFTPFileTransferChunkHook(armed: true) {
            await gate.arriveAndWaitRelease()
        }

        let (first, _) = manager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "single-1.bin", content: content)
        )
        let firstTask = try XCTUnwrap(first)
        let firstArrived = try await waitForCondition(timeout: 30) { await gate.hasArrived() }
        XCTAssertTrue(firstArrived)
        XCTAssertTrue(manager.hasActiveTransfer)
        XCTAssertTrue(manager.hasActiveTransfer(forSession: session.id))
        XCTAssertFalse(manager.hasActiveTransfer(forSession: UUID()))

        // Phase 11：不再拒绝，而是入队等待（绝不触碰连接 / 文件）。
        let second = manager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "single-2.bin", content: content)
        )
        XCTAssertNil(second.rejection)
        let secondTask = try XCTUnwrap(second.task)
        XCTAssertEqual(secondTask.state, .pending, "会话槽位满时新任务必须排队")
        XCTAssertEqual(manager.activeTasks.count, 1, "每会话活跃传输不得超过 1")

        await gate.release()
        try await waitForTerminal(firstTask)
        XCTAssertEqual(firstTask.state, .completed)

        // 事件驱动补位：排队任务被启动并完成（无需任何轮询）。
        try await waitForTerminal(secondTask, timeout: 60)
        XCTAssertEqual(secondTask.state, .completed, "首任务完成后排队任务必须被调度完成")
        XCTAssertFalse(manager.hasActiveTransfer)
        await connection.setTestSFTPFileTransferChunkHook(armed: false, nil)
    }

    // MARK: - 测试 N：强制 partial write（高风险点确定性证据）

    /// 接缝把每次写入提交字节压到 100 KB（< 1 MiB 分块）：服务器真实只收到并写入该量，
    /// 强制 `offset += written` 重试循环每个分块真实执行 11 次以上。
    /// 断言：字节完整（内容逐字节一致）、写调用数远大于分块数、
    /// 无临时文件残留、句柄仪表配对。
    func testN_ForcedPartialWritesStayByteExact() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let uploadDir = fixture + "/upload"

        // 跨 2 个分块（1 MiB + 尾段），两个分块都被强制 partial 循环。
        let size = 1_100_003
        let content = makeContent(size: size, seed: 14)
        let connection = try await makeAuthenticatedTestKeyConnection()
        let manager = TransferManager()
        let session = try await makeLoadedSession(connection: connection, path: uploadDir)

        let baseline = await connection.sftpFileWriteCallCount
        await connection.setTestSFTPFileWriteMaxBytesPerCall(100_000)

        let localURL = makeLocalFile(name: "partial-write.bin", content: content)
        let (task, _) = manager.requestUpload(session: session, localURL: localURL)
        let upload = try XCTUnwrap(task)
        try await waitForTerminal(upload, timeout: 120)

        await connection.setTestSFTPFileWriteMaxBytesPerCall(nil)

        XCTAssertEqual(upload.state, .completed, "强制 partial write 下上传必须完成")
        XCTAssertEqual(upload.transferredBytes, Int64(size))

        // 字节完整：远端内容与本地源逐字节一致（不丢字节、不重复字节）。
        let remotePath = uploadDir + "/partial-write.bin"
        let remoteData = try await connection.testReadWholeRemoteFile(remotePath)
        XCTAssertEqual(remoteData, content, "partial write 下必须逐字节完整")
        defer { try? FileManager.default.removeItem(atPath: remotePath) }

        // 重试循环真实生效：调用数远超分块数（2）——
        // 每 1 MiB 分块在 cap 100 KB 下至少 11 次写入。
        let writeCalls = await connection.sftpFileWriteCallCount - baseline
        XCTAssertGreaterThan(writeCalls, 11, "必须真实发生连续 partial write（实际 \(writeCalls) 次）")

        XCTAssertFalse(hasResidualUploadTempFiles(in: uploadDir), "不得残留上传临时文件")
        await assertFileHandleMetersBalanced(connection, iteration: "强制 partial write")

        await connection.disconnect()
    }

    // MARK: - 辅助：会话装配

    /// 装配一个 Files 面板已加载指定目录的 Remote Session（测试专用：
    /// 复用真实 SFTPService 与 SSHConnection，不经过 SwiftUI）。
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

    // MARK: - 辅助：等待与断言

    private func waitForTerminal(
        _ task: TransferTask,
        timeout: TimeInterval = 30
    ) async throws {
        let done = try await waitForCondition(timeout: timeout) {
            task.state.isTerminal
        }
        XCTAssertTrue(done, "传输在 \(timeout) 秒内未到达终态（当前 \(task.state)）")
    }

    /// 句柄仪表配对断言：打开 == 关闭，无残留句柄，无在途操作。
    private func assertFileHandleMetersBalanced(
        _ connection: SSHConnection,
        iteration: String
    ) async {
        let opens = await connection.sftpFileHandleOpenCount
        let closes = await connection.sftpFileHandleCloseCount
        XCTAssertEqual(closes, opens, "\(iteration)：关闭数必须等于打开数")
        let residual = await connection.openSFTPFileHandleCount
        XCTAssertEqual(residual, 0, "\(iteration)：不得遗留打开的文件句柄")
        let inFlight = await connection.inFlightSFTPFileOperationCount
        XCTAssertEqual(inFlight, 0, "\(iteration)：在途文件操作计数必须归零")
    }

    // MARK: - 辅助：本地文件与夹具

    private var tempLocalRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p10-tests", isDirectory: true)
    }

    private func makeLocalPath(name: String) -> URL {
        let directory = tempLocalRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        tempLocalFiles.append(directory)
        return url
    }

    private func makeLocalFile(
        name: String,
        content: Data,
        uniqueDirectory: Bool = false
    ) -> URL {
        let url = uniqueDirectory
            ? makeLocalPath(name: name)
            : tempLocalRoot.appendingPathComponent(name)
        if !uniqueDirectory {
            try? FileManager.default.createDirectory(
                at: tempLocalRoot,
                withIntermediateDirectories: true
            )
            tempLocalFiles.append(url)
        }
        do {
            try content.write(to: url)
        } catch {
            XCTFail("本地测试文件写入失败：\(error)")
        }
        return url
    }

    private func localDirectory(of url: URL) -> URL {
        url.deletingLastPathComponent()
    }

    /// 确定性内容（可复现）：种子 + 循环字节。
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
        !residualUploadTempFileNames(in: remoteDirectory).isEmpty
    }

    /// 远端 == 本地（本机 sshd 服务夹具目录）：直接列举残留临时文件名。
    private func residualUploadTempFileNames(in remoteDirectory: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: remoteDirectory) else {
            return []
        }
        return names.filter { $0.hasPrefix(".macssh-upload-") }
    }

    /// 连接丢失用例专用：远端 == 本地，直接在文件系统清理无主临时文件。
    private func cleanupResidualUploadTempFiles(in remoteDirectory: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: remoteDirectory) else {
            return
        }
        for name in names where name.hasPrefix(".macssh-upload-") {
            try? FileManager.default.removeItem(atPath: remoteDirectory + "/" + name)
        }
    }

    private func hasResidualDownloadTempFiles(in directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains { $0.hasPrefix(".MacSSH-") && $0.hasSuffix(".partial") }
    }

    private func generateRandomFile(at url: URL, megabytes: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        process.arguments = [
            "if=/dev/urandom",
            "of=\(url.path)",
            "bs=1m",
            "count=\(megabytes)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "dd 生成随机文件失败")
    }

    // MARK: - 辅助：哈希与内存观测

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

    /// 流式读取远端文件计算 SHA256（经 SFTP，证明数据确实在服务器端）。
    private func sha256OfRemoteFile(
        _ connection: SSHConnection,
        path: String
    ) async throws -> Data {
        var hasher = SHA256()
        let handle = try await connection.sftpOpenFileForRead(path)
        var buffer = [UInt8]()
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

    private func input(_ text: String) -> ArraySlice<UInt8> {
        ArraySlice(Array(text.utf8))
    }

    // MARK: - 辅助：连接与环境（与 SFTPServiceTests 同源）

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
            "缺少测试 ed25519 私钥：请使用 Scripts/run-phase10-focus.sh 生成"
        )
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

    /// 用测试 ed25519 私钥建立完整认证连接（3 次重试，限流噪音防护）。
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

    /// 确定性竞态门闩（与 Phase 9 测试同源）。
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

/// 测试专用：整文件流式读回（仅测试断言使用，生产路径无此入口）。
extension SSHConnection {
    func testReadWholeRemoteFile(_ path: String) async throws -> Data {
        var result = Data()
        let handle = try await sftpOpenFileForRead(path)
        var buffer = [UInt8]()
        do {
            while true {
                let count = try await sftpReadFileChunk(handle, into: &buffer, maxLength: 1_048_576)
                if count == 0 {
                    break
                }
                result.append(contentsOf: buffer[0..<count])
            }
        } catch {
            await sftpCloseFileHandle(handle)
            throw error
        }
        await sftpCloseFileHandle(handle)
        return result
    }
}
