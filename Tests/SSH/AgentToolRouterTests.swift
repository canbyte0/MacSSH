import Foundation
import XCTest

@testable import MacSSH

/// 10D-B2 §31–§34/§41/§42：工具注册表与分发测试。
///
/// 全部走 temporary fixture；Remote 用例刻意使用与 Local 相同的 cwd
/// 路径，证明 Remote 文件工具被拒时绝不偷用本地 FileManager 读取同名
/// 路径（§32 P1 hard gate）。
@MainActor
final class AgentToolRouterTests: XCTestCase {
    private var base = ""
    private var directoryA = ""
    private var directoryB = ""
    private var sessionA = UUID()
    private var sessionB = UUID()
    private var handles: [UUID: AgentTerminalSessionHandle] = [:]
    private var scopeA: AgentReadScope!
    private var scopeB: AgentReadScope!
    private var router: AgentToolRouter!

    /// 可控的 buffer fixture（同时统计 probe，便于断言有界）。
    private final class FixtureBufferSource: AgentTerminalBufferSource {
        let text: String
        init(_ text: String) { self.text = text }
        var rows: Int { 24 }
        var columns: Int { 80 }
        var isAlternateScreen: Bool { false }
        var selectedText: String? { nil }
        var firstValidRow: Int { 0 }
        func line(atScrollInvariantRow row: Int) -> AgentTerminalLine? {
            row == 0 ? AgentTerminalLine(text: text, isWrapped: false) : nil
        }
    }

    private actor CancellationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume(returning: ())
            continuation = nil
        }

        func waitUntilArmed() async {
            while continuation == nil, !isOpen {
                await Task.yield()
            }
        }
    }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSSH.B2Router.\(UUID().uuidString)", isDirectory: true)
            .path
        directoryA = base + "/A"
        directoryB = base + "/B"
        try FileManager.default.createDirectory(atPath: directoryA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: directoryB, withIntermediateDirectories: true)
        try "content-A".write(toFile: directoryA + "/file.txt", atomically: true, encoding: .utf8)
        try "content-B".write(toFile: directoryB + "/file.txt", atomically: true, encoding: .utf8)

        sessionA = UUID()
        sessionB = UUID()
        handles = [
            sessionA: Self.makeHandle(
                id: sessionA, kind: .local, directory: directoryA, output: "output-A"
            ),
            sessionB: Self.makeHandle(
                id: sessionB, kind: .local, directory: directoryB, output: "output-B"
            )
        ]
        scopeA = AgentReadScope.make(
            sessionID: sessionA,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directoryA)"),
            kind: .local
        )
        scopeB = AgentReadScope.make(
            sessionID: sessionB,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directoryB)"),
            kind: .local
        )
        router = AgentToolRouter(
            sessionProvider: TerminalAgentContextProvider(handleLookup: { [weak self] id in
                self?.handles[id]
            })
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    private static func makeHandle(
        id: UUID,
        kind: AgentTerminalSessionKind,
        directory: String,
        output: String
    ) -> AgentTerminalSessionHandle {
        AgentTerminalSessionHandle(
            id: id,
            sessionKind: kind,
            displayName: kind == .local ? "Local" : "remote-host",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directory)"),
            bufferSource: FixtureBufferSource(output)
        )
    }

    // MARK: - 静态注册表（§30/§31）

    func testRegistryContainsExactlyFourTools() {
        XCTAssertEqual(AgentToolRegistry.all.count, 4)
        XCTAssertEqual(AgentToolRegistry.lookup("get_terminal_context"), .getTerminalContext)
        XCTAssertEqual(AgentToolRegistry.lookup("get_current_directory"), .getCurrentDirectory)
        XCTAssertEqual(AgentToolRegistry.lookup("list_directory"), .listDirectory)
        XCTAssertEqual(AgentToolRegistry.lookup("read_file"), .readFile)
    }

    func testRegistryRejectsUnknownNames() {
        XCTAssertNil(AgentToolRegistry.lookup("run_command"))
        XCTAssertNil(AgentToolRegistry.lookup("write_file"))
        XCTAssertNil(AgentToolRegistry.lookup("send_to_terminal"))
        XCTAssertNil(AgentToolRegistry.lookup("read_file "))
    }

    func testPolicyMetadataMapping() {
        XCTAssertEqual(AgentToolName.getTerminalContext.risk, .readOnly)
        XCTAssertEqual(AgentToolName.getCurrentDirectory.dataAccessPolicy, .sessionContext)
        XCTAssertEqual(AgentToolName.listDirectory.dataAccessPolicy, .scopedFileRead)
        XCTAssertEqual(AgentToolName.readFile.dataAccessPolicy, .scopedFileRead)
    }

    func testUnknownToolIsRejected() async {
        let result = await router.execute(
            call: AgentToolCall(name: "run_command", arguments: ["path": "/tmp"]),
            sessionID: sessionA,
            readScope: scopeA
        )
        XCTAssertEqual(result, .failure(.unknownTool))
    }

    // MARK: - scope / session 绑定（§33/§34）

    func testScopeSessionMismatchIsHardRejected() async {
        // sessionID = A，但 scope 是 B 的 → 必须 hard reject（P1）。
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionA,
            readScope: scopeB
        )
        XCTAssertEqual(result, .failure(.scopeSessionMismatch))
    }

    func testUnknownSessionIsSessionUnavailable() async {
        let unknown = UUID()
        let result = await router.execute(
            call: AgentToolCall(.getTerminalContext),
            sessionID: unknown,
            readScope: AgentReadScope(sessionID: unknown, allowedRoots: [])
        )
        XCTAssertEqual(result, .failure(.sessionUnavailable))
    }

    func testClosedSessionDoesNotFallBackToOtherSession() async {
        // 模拟 A 关闭：从句柄表移除 → 绝不能 fallback 到 B。
        handles.removeValue(forKey: sessionA)
        let result = await router.execute(
            call: AgentToolCall(.getTerminalContext),
            sessionID: sessionA,
            readScope: scopeA
        )
        XCTAssertEqual(result, .failure(.sessionUnavailable))
    }

    // MARK: - terminal context / cwd（§18/§19）

    func testLocalTerminalContext() async throws {
        let result = await router.execute(
            call: AgentToolCall(.getTerminalContext),
            sessionID: sessionA,
            readScope: scopeA
        )
        guard case .terminalContext(let context)? = try? result.get() else {
            return XCTFail("期望 terminalContext，实际 \(result)")
        }
        XCTAssertEqual(context.sessionID, sessionA)
        XCTAssertEqual(context.sessionKind, .local)
        XCTAssertEqual(context.recentOutput, "output-A")
    }

    func testRemoteTerminalContextIsAllowed() async throws {
        let remoteID = UUID()
        handles[remoteID] = Self.makeHandle(
            id: remoteID, kind: .remoteSSH, directory: directoryA, output: "remote-output"
        )
        let scope = AgentReadScope.make(
            sessionID: remoteID,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/app"),
            kind: .remote
        )
        let result = await router.execute(
            call: AgentToolCall(.getTerminalContext),
            sessionID: remoteID,
            readScope: scope
        )
        guard case .terminalContext(let context)? = try? result.get() else {
            return XCTFail("Remote terminal context 必须允许（§51）")
        }
        XCTAssertEqual(context.sessionKind, .remoteSSH)
        XCTAssertEqual(context.recentOutput, "remote-output")
    }

    func testRemoteCurrentDirectoryIsAllowed() async throws {
        let remoteID = UUID()
        handles[remoteID] = Self.makeHandle(
            id: remoteID, kind: .remoteSSH, directory: "/srv/app", output: ""
        )
        let scope = AgentReadScope.make(
            sessionID: remoteID,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/app"),
            kind: .remote
        )
        let result = await router.execute(
            call: AgentToolCall(.getCurrentDirectory),
            sessionID: remoteID,
            readScope: scope
        )
        guard case .currentDirectory(let directory)? = try? result.get() else {
            return XCTFail("Remote cwd 元信息必须允许（§51）")
        }
        XCTAssertEqual(directory.workingDirectory.path, "/srv/app")
        XCTAssertEqual(directory.workingDirectory.confidence, .authoritative)
    }

    func testCurrentDirectorySuccessWithUnavailableSemantics() async throws {
        let unavailable = UUID()
        handles[unavailable] = AgentTerminalSessionHandle(
            id: unavailable,
            sessionKind: .local,
            displayName: "Local",
            workingDirectory: .unavailable,
            bufferSource: nil
        )
        let scope = AgentReadScope(sessionID: unavailable, allowedRoots: [])
        let result = await router.execute(
            call: AgentToolCall(.getCurrentDirectory),
            sessionID: unavailable,
            readScope: scope
        )
        guard case .currentDirectory(let directory)? = try? result.get() else {
            return XCTFail("path 不存在必须 success + unavailable（§19 冻结语义）")
        }
        XCTAssertNil(directory.workingDirectory.path)
        XCTAssertEqual(directory.workingDirectory.confidence, .unavailable)
    }

    // MARK: - Local 文件工具（§20/§24）

    func testLocalReadFile() async throws {
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionA,
            readScope: scopeA
        )
        guard case .fileContent(let content)? = try? result.get() else {
            return XCTFail("期望 fileContent，实际 \(result)")
        }
        XCTAssertEqual(content.text, "content-A")
    }

    func testLocalListDirectory() async throws {
        let result = await router.execute(
            call: AgentToolCall(.listDirectory),
            sessionID: sessionA,
            readScope: scopeA
        )
        guard case .directoryListing(let listing)? = try? result.get() else {
            return XCTFail("期望 directoryListing，实际 \(result)")
        }
        XCTAssertTrue(listing.entries.contains { $0.name == "file.txt" })
    }

    func testReadFileWithoutPathIsInvalidArguments() async {
        let result = await router.execute(
            call: AgentToolCall(.readFile),
            sessionID: sessionA,
            readScope: scopeA
        )
        XCTAssertEqual(result, .failure(.invalidArguments))
    }

    // MARK: - A/B 隔离（§33）

    func testSessionAOnlyReadsItsOwnDirectory() async throws {
        // B 创建在前、A 在后；即便 B 是「更新」的会话，A 的请求仍只走 A。
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionA,
            readScope: scopeA
        )
        guard case .fileContent(let content)? = try? result.get() else {
            return XCTFail("期望 fileContent")
        }
        XCTAssertEqual(content.text, "content-A")

        let resultB = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionB,
            readScope: scopeB
        )
        guard case .fileContent(let contentB)? = try? resultB.get() else {
            return XCTFail("期望 fileContent")
        }
        XCTAssertEqual(contentB.text, "content-B")
    }

    func testCrossScopeReadIsRejectedEvenForExistingFile() async {
        // scope A 但请求 session B：B 目录下确实存在同名文件，仍必须拒绝。
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: sessionB,
            readScope: scopeA
        )
        XCTAssertEqual(result, .failure(.scopeSessionMismatch))
    }

    // MARK: - Remote 文件工具硬 gate（§32/§51）

    /// B3（§52/§78）：Remote 文件工具改走 Remote 只读后端；
    /// 没有可用 Remote 服务（未装配 resolver / 会话不可寻址）时必须是
    /// `sessionUnavailable`——**绝不**退回本地 FileManager 读取
    /// Mac 上同名路径（P1）。
    func testRemoteReadFileWithoutRemoteServiceIsSessionUnavailable() async {
        let remoteID = UUID()
        handles[remoteID] = Self.makeHandle(
            id: remoteID, kind: .remoteSSH, directory: directoryA, output: ""
        )
        let scope = AgentReadScope.make(
            sessionID: remoteID,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directoryA)"),
            kind: .remote
        )
        let result = await router.execute(
            call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
            sessionID: remoteID,
            readScope: scope
        )
        XCTAssertEqual(
            result,
            .failure(.sessionUnavailable),
            "Remote 绝不能用本地 FileManager 读取同名路径（P1）"
        )
    }

    func testRemoteListDirectoryWithoutRemoteServiceIsSessionUnavailable() async {
        let remoteID = UUID()
        handles[remoteID] = Self.makeHandle(
            id: remoteID, kind: .remoteSSH, directory: directoryA, output: ""
        )
        let scope = AgentReadScope.make(
            sessionID: remoteID,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host\(directoryA)"),
            kind: .remote
        )
        let result = await router.execute(
            call: AgentToolCall(.listDirectory),
            sessionID: remoteID,
            readScope: scope
        )
        XCTAssertEqual(result, .failure(.sessionUnavailable))
    }

    // MARK: - 取消（§42）

    func testCancellationBeforeExecutionYieldsCancelled() async {
        let gate = CancellationGate()
        let task = Task { @MainActor () -> Result<AgentToolResult, AgentToolError> in
            await gate.wait()
            return await self.router.execute(
                call: AgentToolCall(.readFile, arguments: ["path": "file.txt"]),
                sessionID: self.sessionA,
                readScope: self.scopeA
            )
        }
        await gate.waitUntilArmed()
        task.cancel()
        await gate.open()
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled), "取消绝不能转成 internalFailure")
    }
}
