import Foundation
import XCTest

@testable import MacSSH

/// 10D-B3 §52–§56/§76/§77/§78：Router Remote 接线与会话绑定测试。
@MainActor
final class AgentRemoteRouterTests: XCTestCase {
    private var handles: [UUID: AgentTerminalSessionHandle] = [:]
    private var services: [UUID: AgentRemoteReadOnlyFileService] = [:]
    private var resolver: FakeRemoteServiceResolver!
    private var router: AgentToolRouter!

    private let sessionA = UUID()
    private let sessionB = UUID()
    private let localSession = UUID()

    private var fakeA: FakeAgentRemoteFileSystem!
    private var fakeB: FakeAgentRemoteFileSystem!

    private var scopeA: AgentReadScope!
    private var scopeB: AgentReadScope!

    private var localDirectory = ""
    private var localScope: AgentReadScope!

    /// 仅供测试观察：router / resolver **绝不允许**读取它（§56）。
    private var activeSessionID: UUID!

    private final class FakeRemoteServiceResolver: AgentRemoteReadOnlyServiceResolving {
        private let lookup: (UUID) -> AgentRemoteReadOnlyFileService?
        private(set) var lookupCount = 0

        init(lookup: @escaping @MainActor (UUID) -> AgentRemoteReadOnlyFileService?) {
            self.lookup = lookup
        }

        func remoteFileService(for sessionID: UUID) -> AgentRemoteReadOnlyFileService? {
            lookupCount += 1
            return lookup(sessionID)
        }
    }

    override func setUp() async throws {
        fakeA = FakeAgentRemoteFileSystem()
        fakeB = FakeAgentRemoteFileSystem()
        await makeRemote(fakeA, root: "/srv/A", content: "A")
        await makeRemote(fakeB, root: "/srv/B", content: "B")

        localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSSH.B3Router.\(UUID().uuidString)", isDirectory: true)
            .path
        try? FileManager.default.createDirectory(
            atPath: localDirectory, withIntermediateDirectories: true
        )
        try? "local-content".write(
            toFile: localDirectory + "/file.txt", atomically: true, encoding: .utf8
        )

        handles = [
            sessionA: Self.remoteHandle(id: sessionA, directory: "/srv/A"),
            sessionB: Self.remoteHandle(id: sessionB, directory: "/srv/B"),
            localSession: Self.localHandle(id: localSession, directory: localDirectory)
        ]
        services = [
            sessionA: AgentRemoteReadOnlyFileService(client: fakeA),
            sessionB: AgentRemoteReadOnlyFileService(client: fakeB)
        ]
        resolver = FakeRemoteServiceResolver { [weak self] id in
            self?.services[id]
        }
        router = AgentToolRouter(
            sessionProvider: TerminalAgentContextProvider(handleLookup: { [weak self] id in
                self?.handles[id]
            }),
            remoteServiceResolver: resolver
        )

        scopeA = await AgentReadScope.makeRemote(
            sessionID: sessionA,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/A"),
            client: fakeA
        )
        scopeB = await AgentReadScope.makeRemote(
            sessionID: sessionB,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/B"),
            client: fakeB
        )
        localScope = AgentReadScope.make(
            sessionID: localSession,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(localDirectory)"),
            kind: .local
        )
        // A 的服务器上也存在一个 scope 外的目录（用户迟到的 cd 目标）：
        // §55 断言「存在但越界」而非「不存在」。
        await fakeA.addFile("/srv/private/file.txt", "private")
        // scope 创建本身会 canonicalize：计数器清零，后续断言只看调用期。
        await fakeA.resetCounters()
        await fakeB.resetCounters()
        activeSessionID = sessionA
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: localDirectory)
    }

    private func makeRemote(
        _ fake: FakeAgentRemoteFileSystem,
        root: String,
        content: String
    ) async {
        await fake.addDirectory("/")
        await fake.addDirectory("/srv")
        await fake.addDirectory(root)
        await fake.addFile(root + "/file.txt", content)
    }

    private static func remoteHandle(
        id: UUID,
        directory: String
    ) -> AgentTerminalSessionHandle {
        AgentTerminalSessionHandle(
            id: id,
            sessionKind: .remoteSSH,
            displayName: "remote",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directory)"),
            bufferSource: nil
        )
    }

    private static func localHandle(
        id: UUID,
        directory: String
    ) -> AgentTerminalSessionHandle {
        AgentTerminalSessionHandle(
            id: id,
            sessionKind: .local,
            displayName: "Local",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directory)"),
            bufferSource: nil
        )
    }

    // MARK: - A/B 隔离（§8/§76）

    func testSessionAReadsOnlyItsOwnRemoteFilesystem() async throws {
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionA,
            readScope: scopeA
        )
        guard case .fileContent(let content)? = try? result.get() else {
            return XCTFail("期望 fileContent，实际 \(result)")
        }
        XCTAssertEqual(content.text, "A")

        let countsB = await fakeB.callCounts()
        let countersB = await fakeB.counters()
        XCTAssertEqual(countsB.canonical, 0, "§76：B client 绝不能被触发")
        XCTAssertEqual(countsB.stat, 0)
        XCTAssertEqual(countsB.list, 0)
        XCTAssertEqual(countersB.open, 0)
    }

    func testActiveSessionChangeDoesNotAlterToolTarget() async throws {
        // 用户把 active tab 切到 B：A 的 tool 目标绝不能随之改变。
        activeSessionID = sessionB
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionA,
            readScope: scopeA
        )
        guard case .fileContent(let content)? = try? result.get() else {
            return XCTFail("期望 fileContent，实际 \(result)")
        }
        XCTAssertEqual(content.text, "A", "§56/§76：active session 变化不得影响 tool target")
        let countersB = await fakeB.counters()
        XCTAssertEqual(countersB.open, 0)
    }

    func testSessionBReadsOnlyItsOwnRemoteFilesystem() async throws {
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionB,
            readScope: scopeB
        )
        guard case .fileContent(let content)? = try? result.get() else {
            return XCTFail("期望 fileContent，实际 \(result)")
        }
        XCTAssertEqual(content.text, "B")
        let countersA = await fakeA.counters()
        XCTAssertEqual(countersA.open, 0)
    }

    func testRemoteListDirectoryReachesCorrectBackend() async throws {
        let result = await router.execute(
            call: AgentToolCall(.listDirectory),
            sessionID: sessionB,
            readScope: scopeB
        )
        guard case .directoryListing(let listing)? = try? result.get() else {
            return XCTFail("期望 directoryListing，实际 \(result)")
        }
        XCTAssertEqual(listing.entries.map(\.name), ["file.txt"])
        XCTAssertEqual(listing.canonicalPath, "/srv/B")
        let countsA = await fakeA.callCounts()
        XCTAssertEqual(countsA.list, 0)
    }

    // MARK: - scope / session 绑定（§10/§54/§77）

    func testWrongScopeSessionIsRejectedWithoutTouchingEitherBackend() async {
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionA,
            readScope: scopeB
        )
        XCTAssertEqual(result, .failure(.scopeSessionMismatch))
        let countsA = await fakeA.callCounts()
        let countsB = await fakeB.callCounts()
        XCTAssertEqual(countsA.canonical + countsA.stat + countsA.list, 0)
        XCTAssertEqual(countsB.canonical + countsB.stat + countsB.list, 0)
        XCTAssertEqual(resolver.lookupCount, 0, "§77：mismatch 绝不解析任何远端服务")
    }

    // MARK: - 关闭 / 不可用会话（§9/§78）

    func testUnavailableRemoteSessionIsSessionUnavailable() async {
        services.removeValue(forKey: sessionA)
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionA,
            readScope: scopeA
        )
        XCTAssertEqual(result, .failure(.sessionUnavailable), "§9：绝不 fallback 到 B / 本地 / 重连")
    }

    func testUnknownSessionIsSessionUnavailable() async {
        let unknown = UUID()
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: unknown,
            readScope: AgentReadScope(sessionID: unknown, allowedRoots: ["/srv/A"])
        )
        XCTAssertEqual(result, .failure(.sessionUnavailable))
    }

    // MARK: - scope 冻结（§55）

    func testScopeIsFrozenAtGenerationStart() async {
        // 用户 shell 已 cd 到 /srv/private，迟到的 tool call 仍只能访问 /srv/A。
        handles[sessionA] = Self.remoteHandle(id: sessionA, directory: "/srv/private")
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionA,
            readScope: scopeA
        )
        XCTAssertEqual(
            result,
            .failure(.outsideAllowedReadScope),
            "§55：scope 绝不随 Remote 当前 cwd 扩大"
        )
    }

    // MARK: - Local 行为不变（§52/§87）

    func testLocalReadFileIsUnchanged() async throws {
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: localSession,
            readScope: localScope
        )
        guard case .fileContent(let content)? = try? result.get() else {
            return XCTFail("Local 读取必须保持 B2 行为，实际 \(result)")
        }
        XCTAssertEqual(content.text, "local-content")
        let countsA = await fakeA.callCounts()
        XCTAssertEqual(countsA.canonical, 0, "Local 绝不能走 Remote 后端")
    }

    func testLocalListDirectoryIsUnchanged() async throws {
        let result = await router.execute(
            call: AgentToolCall(.listDirectory),
            sessionID: localSession,
            readScope: localScope
        )
        guard case .directoryListing(let listing)? = try? result.get() else {
            return XCTFail("Local 列举必须保持 B2 行为，实际 \(result)")
        }
        XCTAssertEqual(listing.entries.map(\.name), ["file.txt"])
    }

    // MARK: - 取消（§42/§48）

    func testRemoteCancelBeforeStart() async {
        let task = Task { @MainActor () -> Result<AgentToolResult, AgentToolError> in
            await self.router.execute(
                call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
                sessionID: self.sessionA,
                readScope: self.scopeA
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
        let countsA = await fakeA.callCounts()
        XCTAssertEqual(countsA.canonical, 0, "§48：取消后绝不启动 SFTP 操作")
    }
}
