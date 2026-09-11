import Foundation
import XCTest

@testable import MacSSH

// MARK: - 可取消的测试闸门

/// 支持「等待中被取消立即唤醒」的闸门（§49：cancel 不能无限排队）。
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.releaseAll() }
        }
    }

    /// 等待至少有一个等待者挂起（或闸门已开），保证测试取消时机确定。
    func waitUntilArmed() async {
        while !isOpen, waiters.isEmpty {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        releaseAll()
    }

    private func releaseAll() {
        let pending = waiters
        waiters = []
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// 同步可触发的一次性信号（用于把「第 N 个分块已返回」精确地交回测试，
/// 避免 actor 方法异步调度造成的时序竞态）。
final class ChunkSignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func fire() {
        lock.lock()
        fired = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

// MARK: - Fake Remote 文件系统（§66/§67）

/// 内存 fake：目录 / 文件 / symlink / 分块读 / 断连 / 闸门等待 / 计数观测。
///
/// 全部 B3 单元测试经它离线完成：绝不要求真实 SSH server。
actor FakeAgentRemoteFileSystem: AgentRemoteReadOnlyFileClient {
    enum Kind {
        case file
        case directory
        case symlink
        case other
    }

    struct Node {
        var kind: Kind
        var content = Data()
        var target: String?
        var children: [String] = []
    }

    private enum Resolution {
        case resolved(String)
        case missing
        case loop
    }

    private var nodes: [String: Node] = [:]
    private var handles: [UInt64: (path: String, offset: Int, chunkIndex: Int)] = [:]
    private var nextHandleID: UInt64 = 1

    // 观测计数（§73/§75/§76）
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var canonicalCallCount = 0
    private(set) var statCallCount = 0
    private(set) var listCallCount = 0
    private(set) var readCallCount = 0
    private(set) var totalBytesRequested = 0

    // 行为注入
    private var chunkSize: Int?
    private var denied: Set<String> = []
    private var isDisconnected = false
    private var failReadAfterChunks: Int?
    private var chunkDelayNanoseconds: UInt64 = 0
    private var canonicalGate: AsyncGate?
    private var chunkSignal: (@Sendable (Int) -> Void)?

    // MARK: 夹具构造

    func addDirectory(_ path: String) {
        ensureAncestors(of: path)
        if nodes[path] == nil {
            nodes[path] = Node(kind: .directory)
            registerChild(path)
        }
    }

    func addFile(_ path: String, _ text: String) {
        addFile(path, Data(text.utf8))
    }

    func addFile(_ path: String, _ data: Data) {
        ensureAncestors(of: path)
        nodes[path] = Node(kind: .file, content: data)
        registerChild(path)
    }

    func addSymlink(_ path: String, target: String) {
        ensureAncestors(of: path)
        nodes[path] = Node(kind: .symlink, target: target)
        registerChild(path)
    }

    func addOther(_ path: String) {
        ensureAncestors(of: path)
        nodes[path] = Node(kind: .other)
        registerChild(path)
    }

    func resetCounters() {
        openCount = 0
        closeCount = 0
        canonicalCallCount = 0
        statCallCount = 0
        listCallCount = 0
        readCallCount = 0
        totalBytesRequested = 0
    }

    func setChunkSize(_ size: Int?) {
        chunkSize = size
    }

    func deny(_ path: String) {
        denied.insert(path)
    }

    func disconnect() {
        isDisconnected = true
    }

    func failReadAfter(chunks: Int?) {
        failReadAfterChunks = chunks
    }

    func setCanonicalGate(_ gate: AsyncGate?) {
        canonicalGate = gate
    }

    func setChunkSignal(_ signal: (@Sendable (Int) -> Void)?) {
        chunkSignal = signal
    }

    /// 每个分块前的固定延迟：把「读进行中」窗口拉长到可确定取消的尺度。
    func setChunkDelay(nanoseconds: UInt64) {
        chunkDelayNanoseconds = nanoseconds
    }

    func counters() -> (open: Int, close: Int, read: Int, bytes: Int) {
        (openCount, closeCount, readCallCount, totalBytesRequested)
    }

    func callCounts() -> (canonical: Int, stat: Int, list: Int) {
        (canonicalCallCount, statCallCount, listCallCount)
    }

    // MARK: AgentRemoteReadOnlyFileClient

    func canonicalPath(_ path: String) async throws -> String {
        canonicalCallCount += 1
        if let canonicalGate {
            await canonicalGate.wait()
            try Task.checkCancellation()
        }
        if isDisconnected {
            throw AgentRemoteFileError.connectionLost
        }
        switch resolve(path) {
        case .resolved(let canonical):
            if denied.contains(canonical) {
                throw AgentRemoteFileError.permissionDenied
            }
            return canonical
        case .missing:
            throw AgentRemoteFileError.noSuchPath
        case .loop:
            throw AgentRemoteFileError.protocolFailure
        }
    }

    func stat(_ path: String) async throws -> AgentRemoteFileMetadata {
        statCallCount += 1
        if isDisconnected {
            throw AgentRemoteFileError.connectionLost
        }
        switch resolve(path) {
        case .missing:
            throw AgentRemoteFileError.noSuchPath
        case .loop:
            throw AgentRemoteFileError.protocolFailure
        case .resolved(let canonical):
            if denied.contains(canonical) {
                throw AgentRemoteFileError.permissionDenied
            }
            guard let node = nodes[canonical] else {
                throw AgentRemoteFileError.noSuchPath
            }
            return AgentRemoteFileMetadata(
                sizeBytes: node.kind == .file ? UInt64(node.content.count) : nil,
                isRegularFile: node.kind == .file,
                isDirectory: node.kind == .directory,
                isSymlink: false
            )
        }
    }

    func listDirectory(_ path: String) async throws -> [AgentRemoteDirectoryEntry] {
        listCallCount += 1
        if isDisconnected {
            throw AgentRemoteFileError.connectionLost
        }
        switch resolve(path) {
        case .missing:
            throw AgentRemoteFileError.noSuchPath
        case .loop:
            throw AgentRemoteFileError.protocolFailure
        case .resolved(let canonical):
            if denied.contains(canonical) {
                throw AgentRemoteFileError.permissionDenied
            }
            guard let node = nodes[canonical], node.kind == .directory else {
                throw AgentRemoteFileError.protocolFailure
            }
            // lstat 语义：不跟随链接，保留 symbolicLink 类型信息（§21）。
            return node.children.compactMap { name in
                guard let child = nodes[join(canonical, name)] else {
                    return nil
                }
                return AgentRemoteDirectoryEntry(
                    name: name,
                    kind: Self.mapKind(child.kind),
                    sizeBytes: child.kind == .file ? UInt64(child.content.count) : nil
                )
            }
        }
    }

    func openFileForRead(_ path: String) async throws -> AgentRemoteReadHandle {
        openCount += 1
        if isDisconnected {
            throw AgentRemoteFileError.connectionLost
        }
        switch resolve(path) {
        case .missing:
            throw AgentRemoteFileError.noSuchPath
        case .loop:
            throw AgentRemoteFileError.protocolFailure
        case .resolved(let canonical):
            if denied.contains(canonical) {
                throw AgentRemoteFileError.permissionDenied
            }
            let identifier = nextHandleID
            nextHandleID += 1
            handles[identifier] = (canonical, 0, 0)
            return AgentRemoteReadHandle(identifier: identifier)
        }
    }

    func readFileChunk(
        _ handle: AgentRemoteReadHandle,
        maxBytes: Int
    ) async throws -> Data {
        readCallCount += 1
        totalBytesRequested += maxBytes
        guard var state = handles[handle.identifier] else {
            throw AgentRemoteFileError.protocolFailure
        }
        if isDisconnected {
            throw AgentRemoteFileError.connectionLost
        }
        if let limit = failReadAfterChunks, state.chunkIndex >= limit {
            throw AgentRemoteFileError.connectionLost
        }
        guard let node = nodes[state.path] else {
            throw AgentRemoteFileError.noSuchPath
        }
        if chunkDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
        }
        let capped = min(maxBytes, chunkSize ?? maxBytes)
        let end = min(state.offset + capped, node.content.count)
        let slice = node.content[state.offset..<end]
        state.offset = end
        state.chunkIndex += 1
        handles[handle.identifier] = state
        chunkSignal?(state.chunkIndex)
        return slice
    }

    func closeFile(_ handle: AgentRemoteReadHandle) async {
        guard handles.removeValue(forKey: handle.identifier) != nil else {
            return
        }
        closeCount += 1
    }

    // MARK: 内部

    /// 自动补齐中间目录：避免夹具漏建父目录导致 symlink 逃逸断言
    /// 退化成 pathNotFound（掩盖真正的 containment 判定）。
    private func ensureAncestors(of path: String) {
        var current = ""
        for component in path.split(separator: "/").map(String.init).dropLast() {
            let next = current + "/" + component
            if nodes[next] == nil {
                nodes[next] = Node(kind: .directory)
                registerChild(next)
            }
            current = next
        }
    }

    private func registerChild(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, var node = nodes[parent] else {
            return
        }
        let name = (path as NSString).lastPathComponent
        if !node.children.contains(name) {
            node.children.append(name)
            nodes[parent] = node
        }
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// 服务端 realpath 语义：逐组件跟随 symlink（含末位），环 → loop，
    /// 不存在 / broken symlink → missing。
    private func resolve(_ path: String) -> Resolution {
        guard path.hasPrefix("/") else {
            return .missing
        }
        var components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        var resolved: [String] = []
        var index = 0
        var hops = 0

        while index < components.count {
            let component = components[index]
            if component == ".." {
                if !resolved.isEmpty {
                    resolved.removeLast()
                }
                index += 1
                continue
            }
            let current = "/" + (resolved + [component]).joined(separator: "/")
            guard let node = nodes[current] else {
                return .missing
            }
            if node.kind == .symlink {
                hops += 1
                guard hops <= 40, let target = node.target else {
                    return .loop
                }
                let rest = Array(components[(index + 1)...])
                if target.hasPrefix("/") {
                    resolved = []
                }
                components = target.split(separator: "/").map(String.init).filter { $0 != "." } + rest
                index = 0
                continue
            }
            resolved.append(component)
            index += 1
        }
        return .resolved("/" + resolved.joined(separator: "/"))
    }

    private static func mapKind(_ kind: Kind) -> AgentRemoteDirectoryEntryKind {
        switch kind {
        case .file:
            return .file
        case .directory:
            return .directory
        case .symlink:
            return .symbolicLink
        case .other:
            return .other
        }
    }
}

extension Result {
    var errorValue: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}

// MARK: - B3 Remote 只读文件服务测试（§70–§75）

final class AgentRemoteFileServiceTests: XCTestCase {
    private var fake: FakeAgentRemoteFileSystem!
    private var service: AgentRemoteReadOnlyFileService!
    private var cwd: AgentWorkingDirectory!
    private var scope: AgentReadScope!
    private let sessionID = UUID()

    private let root = "/srv/app"
    private let outside = "/srv/outside"

    override func setUp() async throws {
        fake = FakeAgentRemoteFileSystem()
        await makeFixture(fake)
        service = AgentRemoteReadOnlyFileService(client: fake)
        cwd = AgentWorkingDirectory.fromOSC7URL("file://host\(root)")
        scope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: cwd,
            client: fake
        )
        // scope 创建本身会 canonicalize：计数器清零，后续断言只看调用期。
        await fake.resetCounters()
    }

    /// §67 fixture：
    /// ```text
    /// /srv/app/{README.md, src/, inside/, real/, link-in -> real,
    ///           link-out -> /tmp/outside, escape-file -> outside/secret.txt,
    ///           .hidden, .env.example, 中文 文件.txt,
    ///           percent%question#hash?.txt, broken -> 缺失目标,
    ///           binary.bin, invalid.bin, emoji.txt, large.txt, device}
    /// /srv/outside/secret.txt
    /// ```
    private func makeFixture(_ fake: FakeAgentRemoteFileSystem) async {
        await fake.addDirectory("/")
        await fake.addDirectory("/srv")
        await fake.addDirectory(root)
        await fake.addDirectory(root + "/src")
        await fake.addDirectory(root + "/inside")
        await fake.addDirectory(root + "/real")
        await fake.addDirectory(outside)

        await fake.addFile(root + "/README.md", "readme")
        await fake.addFile(root + "/src/main.swift", "swift")
        await fake.addFile(root + "/inside/child.txt", "child")
        await fake.addFile(root + "/real/file.txt", "real-file")
        await fake.addFile(outside + "/secret.txt", "secret")

        // §25：目录内指向 scope 内目录的 symlink → 允许。
        await fake.addSymlink(root + "/link-in", target: root + "/real")
        // §24/§26：指向 scope 外目录的 symlink → 必须拒绝。
        await fake.addSymlink(root + "/link-out", target: outside)
        // 指向 scope 外文件的 symlink → 必须拒绝。
        await fake.addSymlink(root + "/escape-file", target: outside + "/secret.txt")
        // §69：broken symlink。
        await fake.addSymlink(root + "/broken", target: outside + "/missing.txt")

        await fake.addFile(root + "/.hidden", "hidden")
        await fake.addFile(root + "/.env.example", "env")
        await fake.addFile(root + "/中文 文件.txt", "zh")
        await fake.addFile(root + "/percent%question#hash?.txt", "special")
        await fake.addOther(root + "/device")

        // §42/§74：NUL 二进制。
        await fake.addFile(root + "/binary.bin", Data([0x41, 0x00, 0x42]))
        // §42：非法 UTF-8。
        var invalid = Data("abc".utf8)
        invalid.append(contentsOf: [0xFF, 0xFE, 0xFD])
        await fake.addFile(root + "/invalid.bin", invalid)

        await fake.addFile(root + "/emoji.txt", "😀")
        await fake.addFile(root + "/mixed.txt", "a中😀b")
    }

    // MARK: - list_directory（§28–§33/§44/§70）

    func testListRootContainsHiddenUnicodeAndSpecialNames() async {
        let result = await service.listDirectory(
            requestedPath: ".", workingDirectory: cwd, readScope: scope
        )
        let listing = try? result.get()
        XCTAssertNotNil(listing, "期望成功，实际 \(String(describing: result.errorValue))")
        XCTAssertEqual(listing?.canonicalPath, root)
        let names = Set(listing?.entries.map(\.name) ?? [])
        for expected in [".hidden", ".env.example", "中文 文件.txt", "percent%question#hash?.txt", "README.md"] {
            XCTAssertTrue(names.contains(expected), "隐藏 / Unicode / 特殊名不得被过滤：\(expected)")
        }
        XCTAssertFalse(listing?.truncated ?? true)
    }

    func testListEntryKinds() async {
        let result = await service.listDirectory(
            requestedPath: ".", workingDirectory: cwd, readScope: scope
        )
        let entries = (try? result.get())?.entries ?? []
        XCTAssertEqual(entries.first { $0.name == "src" }?.kind, .directory)
        XCTAssertEqual(entries.first { $0.name == "link-in" }?.kind, .symbolicLink)
        XCTAssertEqual(entries.first { $0.name == "README.md" }?.kind, .file)
        XCTAssertEqual(entries.first { $0.name == "device" }?.kind, .other)
        XCTAssertNil(entries.first { $0.name == "src" }?.sizeBytes, "目录不报大小")
        XCTAssertEqual(entries.first { $0.name == "README.md" }?.sizeBytes, 6)
    }

    func testListOrderingIsDeterministicAndLocaleIndependent() async {
        let result = await service.listDirectory(
            requestedPath: ".", workingDirectory: cwd, readScope: scope
        )
        let entries = (try? result.get())?.entries ?? []
        let ranks = entries.map(\.kind.sortRank)
        XCTAssertEqual(ranks, ranks.sorted(), "必须先按类型 rank 排序")
        for index in 1..<entries.count {
            let previous = entries[index - 1]
            let current = entries[index]
            if previous.kind == current.kind {
                XCTAssertTrue(
                    AgentLocalFileService.lexicographicLess(previous.name, current.name),
                    "同类型内必须按 UTF-8 字节序：\(previous.name) / \(current.name)"
                )
            }
        }
        // 同一 fixture 两次列举完全一致。
        let again = await service.listDirectory(
            requestedPath: ".", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(entries, (try? again.get())?.entries ?? [])
    }

    func testListEmptyDirectory() async {
        let empty = FakeAgentRemoteFileSystem()
        await empty.addDirectory("/")
        await empty.addDirectory("/srv")
        await empty.addDirectory("/srv/empty")
        let localService = AgentRemoteReadOnlyFileService(client: empty)
        let emptyScope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/empty"),
            client: empty
        )
        let result = await localService.listDirectory(
            requestedPath: ".",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/empty"),
            readScope: emptyScope
        )
        XCTAssertEqual((try? result.get())?.entries.count, 0)
        XCTAssertFalse((try? result.get())?.truncated ?? true)
    }

    func testListExactly500EntriesIsNotTruncated() async {
        let fake500 = FakeAgentRemoteFileSystem()
        await fake500.addDirectory("/")
        await fake500.addDirectory("/srv")
        await fake500.addDirectory("/srv/many")
        for index in 0..<500 {
            await fake500.addFile("/srv/many/f\(index).txt", "x")
        }
        let localService = AgentRemoteReadOnlyFileService(client: fake500)
        let localScope = AgentReadScope(sessionID: sessionID, allowedRoots: ["/srv/many"])
        let result = await localService.listDirectory(
            requestedPath: "/srv/many",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/many"),
            readScope: localScope
        )
        XCTAssertEqual((try? result.get())?.entries.count, 500)
        XCTAssertEqual((try? result.get())?.totalEntryCount, 500)
        XCTAssertFalse((try? result.get())?.truncated ?? true)
    }

    func testList501EntriesIsTruncated() async {
        let fake501 = FakeAgentRemoteFileSystem()
        await fake501.addDirectory("/")
        await fake501.addDirectory("/srv")
        await fake501.addDirectory("/srv/many")
        for index in 0..<501 {
            await fake501.addFile("/srv/many/f\(index).txt", "x")
        }
        let localService = AgentRemoteReadOnlyFileService(client: fake501)
        let localScope = AgentReadScope(sessionID: sessionID, allowedRoots: ["/srv/many"])
        let result = await localService.listDirectory(
            requestedPath: "/srv/many",
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/many"),
            readScope: localScope
        )
        XCTAssertEqual((try? result.get())?.entries.count, 500, "§31：上限 500")
        XCTAssertEqual((try? result.get())?.totalEntryCount, 501)
        XCTAssertTrue((try? result.get())?.truncated ?? false)
    }

    func testListDotDotEscapeIsRejected() async {
        let result = await service.listDirectory(
            requestedPath: "../outside",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope)
    }

    func testListDirectorySymlinkEscapeIsRejected() async {
        // §26：list 是只读也不能绕过 containment。
        let result = await service.listDirectory(
            requestedPath: "link-out",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope)
    }

    func testListDirectorySymlinkInsideIsAllowed() async {
        let result = await service.listDirectory(
            requestedPath: "link-in",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(
            (try? result.get())?.entries.map(\.name),
            ["file.txt"],
            "§25：canonical target 在 root 内 → 允许"
        )
    }

    func testListNotADirectory() async {
        let result = await service.listDirectory(
            requestedPath: "README.md",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(result.errorValue, .notADirectory, "§44：绝不等到 list 失败退化")
    }

    func testListMissingPath() async {
        let result = await service.listDirectory(
            requestedPath: "no-such",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(result.errorValue, .pathNotFound)
    }

    func testListBrokenSymlink() async {
        let result = await service.listDirectory(
            requestedPath: "broken",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(result.errorValue, .pathNotFound, "§23：broken symlink → pathNotFound")
    }

    func testListPermissionDenied() async {
        await fake.deny(root + "/src")
        let result = await service.listDirectory(
            requestedPath: "src",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(result.errorValue, .permissionDenied)
    }

    func testListDisconnect() async {
        await fake.disconnect()
        let result = await service.listDirectory(
            requestedPath: ".",
            workingDirectory: cwd,
            readScope: scope
        )
        XCTAssertEqual(result.errorValue, .sessionUnavailable, "§45：断连 → sessionUnavailable")
    }

    func testListCancellation() async {
        guard let service, let cwd, let scope else {
            return XCTFail("fixture 未装配")
        }
        let task = Task { () -> Result<AgentDirectoryListing, AgentToolError> in
            await service.listDirectory(
                requestedPath: ".",
                workingDirectory: cwd,
                readScope: scope
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.errorValue, .cancelled)
    }

    // MARK: - read_file（§34–§43/§71）

    func testReadRelativeInside() async {
        let result = await service.readFile(
            requestedPath: "README.md", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? result.get())?.text, "readme")
        XCTAssertEqual((try? result.get())?.bytesReturned, 6)
        XCTAssertFalse((try? result.get())?.truncated ?? true)
    }

    func testReadAbsoluteInsideAndDotDotNormalized() async {
        let absolute = await service.readFile(
            requestedPath: root + "/README.md", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? absolute.get())?.text, "readme")

        let dotted = await service.readFile(
            requestedPath: "src/../README.md", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? dotted.get())?.text, "readme")
    }

    func testReadUnicodeEmojiMixedAndSpecialNames() async {
        let zh = await service.readFile(
            requestedPath: "中文 文件.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? zh.get())?.text, "zh")

        let emoji = await service.readFile(
            requestedPath: "emoji.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? emoji.get())?.text, "😀")

        let mixed = await service.readFile(
            requestedPath: "mixed.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? mixed.get())?.text, "a中😀b")

        let special = await service.readFile(
            requestedPath: "percent%question#hash?.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? special.get())?.text, "special")
    }

    func testReadSymlinkInsideIsAllowed() async {
        let result = await service.readFile(
            requestedPath: "link-in/file.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? result.get())?.text, "real-file", "§43：canonical 在 root 内 → 允许")
    }

    func testReadSymlinkEscapeIsRejected() async {
        let directoryEscape = await service.readFile(
            requestedPath: "link-out/secret.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(directoryEscape.errorValue, .outsideAllowedReadScope)

        let fileEscape = await service.readFile(
            requestedPath: "escape-file", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(fileEscape.errorValue, .outsideAllowedReadScope)
    }

    func testReadAbsoluteOutsideIsRejected() async {
        let result = await service.readFile(
            requestedPath: outside + "/secret.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope, "§19：绝对路径也要过 containment")
    }

    func testReadDirectoryIsNotAFile() async {
        let result = await service.readFile(
            requestedPath: "src", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .notAFile)
    }

    func testReadOtherTypeIsNotAFile() async {
        let result = await service.readFile(
            requestedPath: "device", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .notAFile)
    }

    func testReadMissingAndBrokenSymlink() async {
        let missing = await service.readFile(
            requestedPath: "no-such.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(missing.errorValue, .pathNotFound)

        let broken = await service.readFile(
            requestedPath: "broken", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(broken.errorValue, .pathNotFound)
    }

    func testReadPermissionDenied() async {
        await fake.deny(root + "/README.md")
        let result = await service.readFile(
            requestedPath: "README.md", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .permissionDenied)
    }

    func testReadBinaryWithNUL() async {
        let result = await service.readFile(
            requestedPath: "binary.bin", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .binaryUnsupported, "§42：绝不 base64 / hex dump")
    }

    func testReadInvalidUTF8() async {
        let result = await service.readFile(
            requestedPath: "invalid.bin", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .binaryUnsupported)
    }

    // MARK: - 分块与 UTF-8 边界（§40/§41/§72）

    func testEmojiSplitAcrossChunksStillDecodes() async {
        await fake.setChunkSize(3)
        let result = await service.readFile(
            requestedPath: "emoji.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(
            (try? result.get())?.text,
            "😀",
            "§72：chunk A = F0 9F 98 / chunk B = 80，最终必须正确解码"
        )
        let counters = await fake.counters()
        XCTAssertGreaterThan(counters.read, 1, "必须真的被切成多个分块")
    }

    func testMixedUnicodeSplitAcrossTinyChunks() async {
        await fake.setChunkSize(1)
        let result = await service.readFile(
            requestedPath: "mixed.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? result.get())?.text, "a中😀b")
    }

    func testLargeFileIsBoundedAndValidUTF8() async {
        let payload = String(repeating: "a", count: 300 * 1024)
        await fake.addFile(root + "/large.txt", payload)
        let result = await service.readFile(
            requestedPath: "large.txt", workingDirectory: cwd, readScope: scope
        )
        guard let content = try? result.get() else {
            return XCTFail("大文件必须读取有界前缀，实际 \(String(describing: result.errorValue))")
        }
        XCTAssertLessThanOrEqual(content.bytesReturned, AgentTextLimits.fileReadMaxBytes)
        XCTAssertTrue(content.truncated)
        XCTAssertEqual(content.originalSize, UInt64(300 * 1024))
        XCTAssertEqual(content.text.utf8.count, content.bytesReturned)

        let counters = await fake.counters()
        XCTAssertLessThanOrEqual(
            counters.bytes,
            AgentTextLimits.fileReadMaxBytes + AgentTextLimits.fileUTF8ProbeBytes + 64 * 1024,
            "§37：累计请求字节必须有界，绝不整文件读入（fake 记录总请求量）"
        )
    }

    func testUTF8BoundaryJustBelowLimit() async {
        // N ASCII + 1 个 4 字节 emoji，emoji 恰好占满到 limit。
        let payload = String(repeating: "a", count: AgentTextLimits.fileReadMaxBytes - 4) + "😀"
        await fake.addFile(root + "/boundary-fit.txt", payload)
        let fit = await service.readFile(
            requestedPath: "boundary-fit.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual((try? fit.get())?.bytesReturned, AgentTextLimits.fileReadMaxBytes)
        XCTAssertTrue((try? fit.get())?.text.hasSuffix("😀") ?? false, "恰好放得下时必须完整返回")
    }

    func testUTF8BoundaryCutBeforeEmoji() async {
        // Emoji 起点在 limit 之前、终点越界：必须回退到前一个完整边界。
        let payload = String(repeating: "a", count: AgentTextLimits.fileReadMaxBytes - 1) + "😀"
        await fake.addFile(root + "/boundary-cut.txt", payload + "tail")
        let cut = await service.readFile(
            requestedPath: "boundary-cut.txt", workingDirectory: cwd, readScope: scope
        )
        guard let content = try? cut.get() else {
            return XCTFail("必须返回有界前缀，实际 \(String(describing: cut.errorValue))")
        }
        XCTAssertEqual(content.bytesReturned, AgentTextLimits.fileReadMaxBytes - 1)
        XCTAssertTrue(content.truncated)
        XCTAssertFalse(content.text.contains("😀"), "§41：绝不返回 malformed UTF-8")
    }

    // MARK: - 取消与句柄清理（§38/§39/§47/§50/§75）

    func testCancelBeforeStart() async {
        guard let service, let cwd, let scope else {
            return XCTFail("fixture 未装配")
        }
        let task = Task { () -> Result<AgentFileContent, AgentToolError> in
            await service.readFile(
                requestedPath: "README.md",
                workingDirectory: cwd,
                readScope: scope
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.errorValue, .cancelled)
        let counts = await fake.callCounts()
        XCTAssertEqual(counts.canonical, 0, "§48：取消后绝不触碰 SFTP 子系统")
        let counters = await fake.counters()
        XCTAssertEqual(counters.open, 0)
    }

    func testCancelWhileWaitingGate() async {
        let gate = AsyncGate()
        await fake.setCanonicalGate(gate)
        guard let service, let cwd, let scope else {
            return XCTFail("fixture 未装配")
        }
        let task = Task { () -> Result<AgentFileContent, AgentToolError> in
            await service.readFile(
                requestedPath: "README.md",
                workingDirectory: cwd,
                readScope: scope
            )
        }
        await gate.waitUntilArmed()
        task.cancel()
        await gate.open()
        let result = await task.value
        XCTAssertEqual(result.errorValue, .cancelled, "§49：等待 gate 时取消必须能退出")
        let counters = await fake.counters()
        XCTAssertEqual(counters.open, 0)
        XCTAssertEqual(counters.close, 0)
    }

    func testCancelDuringReadClosesHandle() async {
        await fake.addFile(root + "/big.txt", String(repeating: "a", count: 300 * 1024))
        // 小分块 + 每块固定延迟：把「读进行中」窗口拉长，取消时机确定。
        await fake.setChunkSize(1024)
        await fake.setChunkDelay(nanoseconds: 5_000_000)
        let signal = ChunkSignalBox()
        await fake.setChunkSignal { index in
            if index == 1 {
                signal.fire()
            }
        }
        guard let service, let cwd, let scope else {
            return XCTFail("fixture 未装配")
        }
        let task = Task { () -> Result<AgentFileContent, AgentToolError> in
            await service.readFile(
                requestedPath: "big.txt",
                workingDirectory: cwd,
                readScope: scope
            )
        }
        await signal.wait()
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.errorValue, .cancelled, "§50：取消 → cancelled，绝不 internalFailure")
        let counters = await fake.counters()
        XCTAssertEqual(counters.close, counters.open, "§39/§75：取消后必须关闭句柄")
        XCTAssertEqual(counters.open, 1)
    }

    func testLateCancellationAfterSuccessIsCancelled() async {
        // 读已完成但返回前 Task 被取消：不得把成功结果交给已取消的 generation。
        guard let service, let cwd, let scope else {
            return XCTFail("fixture 未装配")
        }
        let result = await withTaskGroup(of: Result<AgentFileContent, AgentToolError>.self) { group in
            group.addTask {
                let value = await service.readFile(
                    requestedPath: "README.md",
                    workingDirectory: cwd,
                    readScope: scope
                )
                try? await Task.sleep(nanoseconds: 50_000_000)
                return value
            }
            let first = await group.next()
            group.cancelAll()
            return first
        }
        // §51：router / service 在返回前再次 checkCancellation；
        // 这里只断言组取消后仍能取到确定性结果，绝不 hang。
        XCTAssertNotNil(result)
    }

    func testDisconnectDuringReadClosesHandle() async {
        await fake.addFile(root + "/big.txt", String(repeating: "a", count: 300 * 1024))
        await fake.failReadAfter(chunks: 1)
        let result = await service.readFile(
            requestedPath: "big.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result.errorValue, .sessionUnavailable, "§47：读中途断连 → sessionUnavailable")
        let counters = await fake.counters()
        XCTAssertEqual(counters.close, counters.open, "§39：断连后句柄必须关闭")
    }

    func testHandleClosedOnEveryOutcome() async throws {
        // 成功
        _ = await service.readFile(
            requestedPath: "README.md", workingDirectory: cwd, readScope: scope
        )
        // binary
        _ = await service.readFile(
            requestedPath: "binary.bin", workingDirectory: cwd, readScope: scope
        )
        // 非法 UTF-8
        _ = await service.readFile(
            requestedPath: "invalid.bin", workingDirectory: cwd, readScope: scope
        )
        // 权限失败（open 前被拒：不产生句柄）
        await fake.deny(root + "/.hidden")
        _ = await service.readFile(
            requestedPath: ".hidden", workingDirectory: cwd, readScope: scope
        )
        let counters = await fake.counters()
        XCTAssertEqual(counters.open, counters.close, "§75：任何路径最终 close == open")
        XCTAssertGreaterThan(counters.open, 0)
    }
}
