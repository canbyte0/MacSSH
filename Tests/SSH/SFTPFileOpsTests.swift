import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 10 整改（计划书口径：upload / download / rename / delete / mkdir）：
/// 用户级文件操作（Rename / Delete / Mkdir）业务层真实测试，
/// 经真实本机 sshd + 真实 libssh2 验证。
///
/// 前置：系统设置 → 共享 → 远程登录 已开启，并经
/// `Scripts/run-phase10-focus.sh` 生成测试私钥与 Phase 10 夹具
/// （`upload` 可写 / `readonly` 555 / `restricted` 000）。
///
/// 远端 == 本地（本机 sshd 服务夹具目录）：文件系统断言直接经
/// `FileManager` 验证，与 `SFTPService` 的条目观察互为印证。
@MainActor
final class SFTPFileOpsTests: XCTestCase {
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

    /// 本测试在夹具内创建的文件 / 目录；tearDown 统一清理。
    private var createdPaths: [String] = []

    override func setUp() async throws {
        continueAfterFailure = false
        openConnections = []
        createdPaths = []
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
        for path in createdPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        createdPaths.removeAll()
        await MainActor.run { knownHostService.removeAll() }
        knownHostService = nil
        knownHostContainer = nil
    }

    // MARK: - 测试 A：重命名提交并刷新列表

    /// 同级重命名：服务器文件改名、旧名消失、列表自动刷新出新名；
    /// 字节内容不被触碰。
    func testA_RenameFileCommitsAndRefreshes() async throws {
        try await requireLocalSSHAndTestKey()
        let uploadDir = try requireFixture() + "/upload"
        let connection = try await makeAuthenticatedTestKeyConnection()

        let sourcePath = uploadDir + "/ops-rename-src.txt"
        let destinationPath = uploadDir + "/ops-rename-dst.txt"
        FileManager.default.createFile(atPath: sourcePath, contents: Data("rename-me".utf8))
        createdPaths.append(sourcePath)
        createdPaths.append(destinationPath)

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: uploadDir)
        try await waitForLoaded(service)

        let entry = try XCTUnwrap(service.entries.first { $0.name == "ops-rename-src.txt" })
        service.renameEntry(entry, to: "ops-rename-dst.txt")

        try await waitForConditionAssert {
            service.entries.contains { $0.name == "ops-rename-dst.txt" }
        }
        XCTAssertNil(service.entries.first { $0.name == "ops-rename-src.txt" }, "旧名必须消失")
        XCTAssertNil(service.fileOperationNotice, "成功操作不得留下错误提示")
        XCTAssertEqual(service.phase, .loaded)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourcePath), "服务器旧名必须消失")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: destinationPath)),
            Data("rename-me".utf8),
            "重命名绝不触碰字节内容"
        )
    }

    // MARK: - 测试 B：重命名到已有名称失败且不覆盖

    /// `flags = 0` 的 posix-rename 协议级防线：目标名已存在时失败，
    /// 两个文件的字节都不被触碰；错误提示如实展示。
    func testB_RenameToExistingNameFailsWithoutOverwrite() async throws {
        try await requireLocalSSHAndTestKey()
        let uploadDir = try requireFixture() + "/upload"
        let connection = try await makeAuthenticatedTestKeyConnection()

        let pathA = uploadDir + "/ops-collide-a.txt"
        let pathB = uploadDir + "/ops-collide-b.txt"
        FileManager.default.createFile(atPath: pathA, contents: Data("AAA".utf8))
        FileManager.default.createFile(atPath: pathB, contents: Data("BBB".utf8))
        createdPaths.append(pathA)
        createdPaths.append(pathB)

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: uploadDir)
        try await waitForLoaded(service)

        let entryA = try XCTUnwrap(service.entries.first { $0.name == "ops-collide-a.txt" })
        service.renameEntry(entryA, to: "ops-collide-b.txt")

        try await waitForNotice(service)
        XCTAssertEqual(service.fileOperationNotice, "操作失败：目标名称可能已存在，或服务器拒绝。")

        // 两个文件都保持原样：绝不覆盖。
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pathA)), Data("AAA".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pathB)), Data("BBB".utf8))
        XCTAssertEqual(service.phase, .loaded, "业务错误不得破坏浏览状态")
    }

    // MARK: - 测试 C：删除普通文件

    /// 删除：服务器文件消失、列表刷新移除条目；连接保持健康。
    func testC_DeleteRegularFile() async throws {
        try await requireLocalSSHAndTestKey()
        let uploadDir = try requireFixture() + "/upload"
        let connection = try await makeAuthenticatedTestKeyConnection()

        let path = uploadDir + "/ops-delete-me.txt"
        FileManager.default.createFile(atPath: path, contents: Data("delete-me".utf8))
        createdPaths.append(path)

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: uploadDir)
        try await waitForLoaded(service)

        let entry = try XCTUnwrap(service.entries.first { $0.name == "ops-delete-me.txt" })
        service.deleteEntry(entry)

        try await waitForConditionAssert {
            !service.entries.contains { $0.name == "ops-delete-me.txt" }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "服务器文件必须已删除")
        XCTAssertNil(service.fileOperationNotice)
        XCTAssertEqual(service.phase, .loaded)
    }

    // MARK: - 测试 D：目录删除被业务层拦截

    /// 目录删除不在 Phase 10 范围（避免递归风险）：业务层直接拒绝，
    /// 绝不发起任何服务器调用。
    func testD_DeleteDirectoryRejectedByService() async throws {
        try await requireLocalSSHAndTestKey()
        let uploadDir = try requireFixture() + "/upload"
        let connection = try await makeAuthenticatedTestKeyConnection()

        let dirPath = uploadDir + "/ops-no-delete-dir"
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        createdPaths.append(dirPath)

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: uploadDir)
        try await waitForLoaded(service)

        let entry = try XCTUnwrap(service.entries.first { $0.name == "ops-no-delete-dir" })
        service.deleteEntry(entry)

        // 同步拒绝：立即给出提示，目录安然无恙。
        XCTAssertEqual(service.fileOperationNotice, "仅支持删除普通文件。")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory),
            "目录绝不被删除"
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - 测试 E：新建目录

    /// mkdir：目录出现于列表（目录类型）、权限 0755、可进入。
    func testE_MkdirCreatesDirectory() async throws {
        try await requireLocalSSHAndTestKey()
        let uploadDir = try requireFixture() + "/upload"
        let connection = try await makeAuthenticatedTestKeyConnection()

        let dirPath = uploadDir + "/ops-new-dir"
        createdPaths.append(dirPath)

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: uploadDir)
        try await waitForLoaded(service)

        service.createDirectory(named: "ops-new-dir")

        try await waitForConditionAssert {
            service.entries.contains { $0.name == "ops-new-dir" && $0.isDirectory }
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let attributes = try FileManager.default.attributesOfItem(atPath: dirPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions, 0o755, "新建目录权限必须为 0755")
    }

    // MARK: - 测试 F：重复同名目录失败

    /// 同名已存在：服务器拒绝，错误提示如实展示；不产生副作用。
    func testF_MkdirDuplicateFails() async throws {
        try await requireLocalSSHAndTestKey()
        let uploadDir = try requireFixture() + "/upload"
        let connection = try await makeAuthenticatedTestKeyConnection()

        let dirPath = uploadDir + "/ops-dup-dir"
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        createdPaths.append(dirPath)

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: uploadDir)
        try await waitForLoaded(service)

        service.createDirectory(named: "ops-dup-dir")
        try await waitForNotice(service)
        XCTAssertEqual(service.fileOperationNotice, "操作失败：目标名称可能已存在，或服务器拒绝。")
        XCTAssertEqual(service.phase, .loaded)
    }

    // MARK: - 测试 G：只读目录内新建失败且连接健康

    /// `readonly`（555）目录内新建：权限拒绝业务错误 + 规定文案；
    /// 连接保持健康（随后可正常列举其他目录）。
    func testG_MkdirInReadOnlyDirectoryFails() async throws {
        try await requireLocalSSHAndTestKey()
        let fixture = try requireFixture()
        let readonlyDir = fixture + "/readonly"
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: readonlyDir)
        try await waitForLoaded(service)

        service.createDirectory(named: "ops-denied")
        try await waitForNotice(service)
        XCTAssertEqual(service.fileOperationNotice, "权限不足，无法完成操作。")

        // 连接健康：随后可正常列举夹具根目录。
        service.loadAbsolute(path: fixture)
        try await waitForLoaded(service)
        XCTAssertTrue(service.entries.contains { $0.name == "upload" })
    }

    // MARK: - 测试 H：非法名称在业务层拦截

    /// 空名 / 含 `/` / `.` / `..`：业务层直接拒绝，不发起服务器调用。
    func testH_InvalidNamesRejectedLocally() async throws {
        try await requireLocalSSHAndTestKey()
        let uploadDir = try requireFixture() + "/upload"
        let connection = try await makeAuthenticatedTestKeyConnection()

        let service = SFTPService(connection: connection)
        service.loadAbsolute(path: uploadDir)
        try await waitForLoaded(service)

        for invalid in ["", "   ", "a/b", ".", ".."] {
            service.fileOperationNotice = nil
            service.createDirectory(named: invalid)
            XCTAssertEqual(
                service.fileOperationNotice,
                "名称无效：不能为空、包含 / 或为 . / ..。",
                "非法名称 \(invalid) 必须被本地拦截"
            )
        }
        XCTAssertEqual(service.phase, .loaded)
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

    /// 等待错误提示出现（操作失败是异步提交）。
    private func waitForNotice(
        _ service: SFTPService,
        timeout: TimeInterval = 20
    ) async throws {
        let noticed = try await waitForCondition(timeout: timeout) {
            service.fileOperationNotice != nil
        }
        XCTAssertTrue(noticed, "等待错误提示超时")
    }

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
        try XCTSkipUnless(
            exists,
            "缺少 Phase 10 夹具交接文件：请使用 Scripts/run-phase10-focus.sh"
        )
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

    /// 用测试 ed25519 私钥建立完整认证连接（不触碰 Keychain）。
    /// 本机 sshd 限流噪音防护：有限重试 3 次、退避 0.5 秒（与既有测试一致）。
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
