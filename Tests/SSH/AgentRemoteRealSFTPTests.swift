import Darwin
import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// 10D-B3 §79–§85/§119–§127：真实本机 sshd + 真实 libssh2 的聚焦验收。
///
/// 前置：系统设置 → 共享 → 远程登录 已开启，且测试私钥
/// `/tmp/macssh_phase6_ed25519` 已生成、其公钥已加入 `authorized_keys`
/// （`Scripts/run-phase10-focus.sh` 会做这件事；B3 复用它，避免重复实现
/// 凭据装置）。
///
/// 缺失任一前置 → `XCTSkip`（由 XCTest 自身跳过，绝不整 suite 排除）。
///
/// 夹具全部位于 `/tmp/macssh-agent-b3-<uuid>` 与
/// `/tmp/macssh-agent-b3-outside-<uuid>`：绝不触碰 `~/.ssh` / `~/.aws` /
/// `/etc` 或任何用户项目。
@MainActor
final class AgentRemoteRealSFTPTests: XCTestCase {
    private let testHostname = "127.0.0.1"
    private let testPort: UInt16 = 22
    private let testUsername = NSUserName()

    private enum TestKeys {
        static let ed25519NoPass = "/tmp/macssh_phase6_ed25519"
    }

    private var knownHostContainer: ModelContainer!
    private var knownHostService: KnownHostService!
    private var openConnections: [SSHConnection] = []

    private var root = ""
    private var outside = ""
    private var sessionID = UUID()
    private var cwd: AgentWorkingDirectory!
    private var scope: AgentReadScope!
    private var service: AgentRemoteReadOnlyFileService!

    override func setUp() async throws {
        continueAfterFailure = false
        openConnections = []
        root = "/tmp/macssh-agent-b3-" + UUID().uuidString.lowercased()
        outside = "/tmp/macssh-agent-b3-outside-" + UUID().uuidString.lowercased()
        sessionID = UUID()
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
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: outside)
        knownHostService?.removeAll()
        knownHostService = nil
        knownHostContainer = nil
    }

    // MARK: - §81/§119 真实 list_directory

    func testRealListDirectory() async throws {
        try await prepare()
        let result = await service.listDirectory(
            requestedPath: ".", workingDirectory: cwd, readScope: scope
        )
        guard let listing = try? result.get() else {
            return XCTFail("真实列举失败：\(String(describing: result.errorValue))")
        }
        let names = Set(listing.entries.map(\.name))
        for expected in ["README.txt", "unicode-中文.txt", "large.txt", ".hidden", "inside"] {
            XCTAssertTrue(names.contains(expected), "§33/§119：缺失 \(expected)")
        }
        XCTAssertEqual(listing.entries.first { $0.name == "inside" }?.kind, .directory)
        XCTAssertEqual(listing.entries.first { $0.name == "link-in" }?.kind, .symbolicLink)
        XCTAssertEqual(listing.entries.first { $0.name == "README.txt" }?.kind, .file)
        XCTAssertGreaterThan(
            listing.entries.first { $0.name == "README.txt" }?.sizeBytes ?? 0,
            0
        )
    }

    // MARK: - §82/§120 真实 read_file

    func testRealReadFileASCIIAndUnicode() async throws {
        try await prepare()
        let ascii = await service.readFile(
            requestedPath: "README.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? ascii.get())?.text, "b3-readme")

        let unicode = await service.readFile(
            requestedPath: "unicode-中文.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? unicode.get())?.text, "中文内容 😀")

        let nested = await service.readFile(
            requestedPath: "inside/child.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? nested.get())?.text, "child")
    }

    func testRealReadLargeFileIsBounded() async throws {
        try await prepare()
        let result = await service.readFile(
            requestedPath: "large.txt", workingDirectory: cwd, readScope: scope
        )
        guard let content = try? result.get() else {
            return XCTFail("大文件必须有界读取：\(String(describing: result.errorValue))")
        }
        XCTAssertLessThanOrEqual(content.bytesReturned, AgentTextLimits.fileReadMaxBytes)
        XCTAssertTrue(content.truncated)
        XCTAssertEqual(content.originalSize, UInt64(300 * 1024))
        XCTAssertEqual(content.text.utf8.count, content.bytesReturned)
    }

    func testRealReadBinaryIsRejected() async throws {
        try await prepare()
        let result = await service.readFile(
            requestedPath: "binary.bin", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .binaryUnsupported)
    }

    // MARK: - §121/§122/§127 真实 scope 与 symlink

    func testRealSymlinkInsideIsAllowed() async throws {
        try await prepare()
        let result = await service.readFile(
            requestedPath: "link-in/child.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? result.get())?.text, "real-child")
    }

    func testRealSymlinkEscapeIsRejected() async throws {
        try await prepare()
        let result = await service.readFile(
            requestedPath: "link-out/secret.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(
            result.errorValue,
            .outsideAllowedReadScope,
            "§121：symlink 逃逸必须被 canonicalization 拦截"
        )
    }

    func testRealAbsoluteOutsideIsRejected() async throws {
        try await prepare()
        let result = await service.readFile(
            requestedPath: outside + "/secret.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope)
    }

    func testRealDotDotEscapeIsRejected() async throws {
        try await prepare()
        let outsideName = (outside as NSString).lastPathComponent
        let result = await service.readFile(
            requestedPath: "../" + outsideName + "/secret.txt",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope)
    }

    // MARK: - §83/§123/§124 PTY 共存

    /// Agent SFTP 读取期间：PTY 仍可输入 / 输出，shell channel 不关闭，
    /// 且 shell cwd 不被改变（§13/§62/§84）。
    func testRealPTYCoexistenceAndNoCWDMutation() async throws {
        try await prepare()
        let connection = try XCTUnwrap(openConnections.first)

        try await connection.openInteractiveShell(columns: 80, rows: 24)
        _ = try await drainShellOutput(connection, seconds: 2)

        let before = try await shellCWD(connection)

        // 3 秒窗口内持续执行 Agent SFTP 读取；同时操作 PTY。
        let deadline = Date().addingTimeInterval(3)
        let reader = Task { () -> Int in
            var completed = 0
            while Date() < deadline {
                let result = await self.service.readFile(
                    requestedPath: "README.txt",
                    workingDirectory: self.cwd,
                    readScope: self.scope
                )
                if case .success = result {
                    completed += 1
                }
            }
            return completed
        }

        let output = try await runShellCommand(connection, "printf 'PTY_OK\\n'")
        let completed = await reader.value

        XCTAssertGreaterThan(completed, 0, "Agent SFTP 读取必须持续成功")
        XCTAssertTrue(
            output.contains("PTY_OK"),
            "§123：SFTP 读取期间 PTY 必须仍然可用，实际输出：\(output)"
        )
        let shellChannelStillOpen = await connection.hasOpenShellChannel
        XCTAssertTrue(
            shellChannelStillOpen,
            "§13：Agent read 绝不能关闭 interactive shell channel"
        )

        let after = try await shellCWD(connection)
        XCTAssertEqual(before, after, "§84/§124：Agent read 绝不能改变 shell cwd")
    }

    // MARK: - §78/§85/§125 会话不可用

    func testRealDisconnectedSessionIsSessionUnavailable() async throws {
        try await prepare()
        let connection = try XCTUnwrap(openConnections.first)
        await connection.disconnect()

        let read = await service.readFile(
            requestedPath: "README.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(read.errorValue, .sessionUnavailable)
        let listing = await service.listDirectory(
            requestedPath: ".", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(listing.errorValue, .sessionUnavailable)
    }

    /// §110：生产 resolver 只按 origin sessionID 取会话的 existing
    /// connection；没有连接（未连接 / 已关闭）→ nil（router 映射
    /// `sessionUnavailable`），绝不重连、绝不 fallback。
    func testProductionResolverRequiresExistingConnection() async throws {
        try await requireLocalSSHAndTestKey()
        let session = ManagedTerminalSession(
            remoteHostID: UUID(),
            hostDisplayName: "b3-probe",
            hostname: testHostname,
            port: Int(testPort),
            baseTitle: "b3-probe",
            titleCounter: 1
        )
        let resolver = SessionManagerAgentRemoteServiceResolver { [session] id in
            id == session.id ? session : nil
        }
        XCTAssertNil(
            resolver.remoteFileService(for: session.id),
            "§9/§78：无 existing connection → 绝不返回服务"
        )

        let connection = try await makeAuthenticatedTestKeyConnection()
        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: testHostname,
            port: testPort,
            username: testUsername
        )
        session.attach(connection: connection, info: info)
        info.phase = .connected
        XCTAssertNotNil(
            resolver.remoteFileService(for: session.id),
            "§110：origin session 的已认证连接必须可用"
        )
        XCTAssertNil(
            resolver.remoteFileService(for: UUID()),
            "§110：陌生 sessionID 绝不被解析（绝不按 host 猜测）"
        )
    }

    // MARK: - 装配

    /// 建连 + 建夹具 + 建 Remote scope + 建 B3 服务。
    private func prepare() async throws {
        try await requireLocalSSHAndTestKey()
        try makeFixture()
        let connection = try await makeAuthenticatedTestKeyConnection()
        let client = SSHConnectionAgentRemoteFileClient(connection: connection)
        service = AgentRemoteReadOnlyFileService(client: client)
        cwd = AgentWorkingDirectory.fromOSC7URL("file://host\(root)")
        // §16：authoritative cwd 经**服务端** canonicalization 后成为 root
        // （本机 /tmp 是 symlink，canonical root 与请求路径不同，正是该
        // 语义的真实证明）。
        scope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: cwd,
            client: client
        )
        XCTAssertFalse(scope.allowedRoots.isEmpty, "真实 canonical root 必须建立成功")
    }

    private func makeFixture() throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: root + "/inside", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: root + "/real", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "b3-readme".write(toFile: root + "/README.txt", atomically: true, encoding: .utf8)
        try "中文内容 😀".write(
            toFile: root + "/unicode-中文.txt", atomically: true, encoding: .utf8
        )
        try "child".write(toFile: root + "/inside/child.txt", atomically: true, encoding: .utf8)
        try "real-child".write(toFile: root + "/real/child.txt", atomically: true, encoding: .utf8)
        try "hidden".write(toFile: root + "/.hidden", atomically: true, encoding: .utf8)
        try "secret".write(toFile: outside + "/secret.txt", atomically: true, encoding: .utf8)
        try Data([0x41, 0x00, 0x42]).write(to: URL(fileURLWithPath: root + "/binary.bin"))
        let large = String(repeating: "a", count: 300 * 1024)
        try large.write(toFile: root + "/large.txt", atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(atPath: root + "/link-in", withDestinationPath: root + "/real")
        try manager.createSymbolicLink(atPath: root + "/link-out", withDestinationPath: outside)
    }

    // MARK: - 真实连接（测试装置，绝不属生产路径）

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
            openConnections.append(connection)
            Task { await connection.connect() }

            let reachedTerminalPhase = try await waitForCondition(timeout: 20) {
                switch info.phase {
                case .awaitingHostTrust, .connected:
                    return true
                case .failed:
                    return true
                default:
                    return false
                }
            }
            if reachedTerminalPhase, case .failed = info.phase {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            XCTAssertTrue(reachedTerminalPhase, "连接必须到达 Trust 或 connected")

            if case .awaitingHostTrust = info.phase {
                await connection.resolveHostTrust(.trustOnce)
            }
            let connected = try await waitForCondition(timeout: 20) {
                info.phase == .connected
            }
            XCTAssertTrue(connected, "测试私钥连接必须完成认证")
            return connection
        }
        throw SSHError.connectionLost
    }

    private func requireLocalSSHAndTestKey() async throws {
        let reachable = await Self.isTCPPortOpen(host: testHostname, port: testPort)
        try XCTSkipUnless(reachable, "本机 127.0.0.1:22 未开放")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: TestKeys.ed25519NoPass),
            "缺少测试 ed25519 私钥：请使用 Scripts/run-phase10-focus.sh 生成"
        )
    }

    // MARK: - PTY 辅助

    private func drainShellOutput(
        _ connection: SSHConnection,
        seconds: TimeInterval
    ) async throws -> String {
        var collected = ""
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (bytes, isEOF) = try await connection.readChannelOutput()
            if bytes.isEmpty {
                try await Task.sleep(nanoseconds: 50_000_000)
                if isEOF { break }
                continue
            }
            collected += String(decoding: bytes, as: UTF8.self)
        }
        return collected
    }

    private func runShellCommand(
        _ connection: SSHConnection,
        _ command: String,
        timeout: TimeInterval = 10
    ) async throws -> String {
        try await connection.writeChannelInput(ArraySlice(Array(command.utf8)))
        var collected = ""
        let deadline = Date().addingTimeInterval(timeout)
        var lastChange = Date()
        while Date() < deadline {
            let (bytes, isEOF) = try await connection.readChannelOutput()
            if !bytes.isEmpty {
                collected += String(decoding: bytes, as: UTF8.self)
                lastChange = Date()
            } else if Date().timeIntervalSince(lastChange) > 0.4 {
                break
            }
            if isEOF { break }
            if bytes.isEmpty {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return collected
    }

    private func shellCWD(_ connection: SSHConnection) async throws -> String {
        let output = try await runShellCommand(connection, "pwd\n")
        let lines = output.split(separator: "\n").map(String.init)
        return lines.last { $0.hasPrefix("/") } ?? ""
    }

    // MARK: - 通用等待

    private func waitForCondition(
        timeout: TimeInterval,
        predicate: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: predicate) {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private static func isTCPPortOpen(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
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
                    if poll(&pollFD, 1, 100) > 0 {
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
