import Darwin
import XCTest

@testable import MacSSH

/// MacSSH 1.1 Phase 10D-B1 §10/§17/§19：AgentReadScope 策略测试。
///
/// 断言核心：
/// - 只有 authoritative cwd 才成为 allowedRoot，创建时立即 canonical 化
///   （含 root 自身经过 symlink 的 §19 特例）；
/// - approximate / unavailable / 非绝对 cwd 一律空 roots——绝不因为
///   `sessionDefault = /home/user` 就自动加入（任务书 §23）；
/// - containment 是 path-component aware 的（§17），含 `/` root 特例。
///
/// fixture 全部位于 XCTest temporary directory（任务书 §22），
/// 不触碰真实敏感路径。
final class AgentReadScopeTests: XCTestCase {
    private var rawBase = ""
    private var canonicalBase = ""

    override func setUpWithError() throws {
        // rawBase 含 /var → /private/var symlink 前缀（macOS temporary
        // directory 的天然形态）；canonicalBase 用 libc realpath（kernel
        // 语义）做独立 oracle。实测 Foundation 的 resolvingSymlinksInPath
        // 不解析 /var 前缀（即使路径存在），与 resolver 语义不一致，
        // 不能当 oracle。
        rawBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSSH.ScopeTests.\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            atPath: rawBase + "/root/subdir", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: rawBase + "/outside", withIntermediateDirectories: false
        )
        // root/link -> ../outside：相对 symlink，逃出 root。
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/root/link", withDestinationPath: "../outside"
        )
        // loop-a <-> loop-b：canonical 化必失败。
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/loop-a", withDestinationPath: "loop-b"
        )
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/loop-b", withDestinationPath: "loop-a"
        )
        canonicalBase = try XCTUnwrap(Self.realpathOracle(rawBase))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: rawBase)
    }

    /// libc realpath：canonical 期望值的独立 oracle（kernel 语义，
    /// 解析包括 /var 在内的全部 symlink 组件）。
    private static func realpathOracle(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(path, &buffer) != nil else {
            return nil
        }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func authoritative(_ path: String) -> AgentWorkingDirectory {
        AgentWorkingDirectory(path: path, source: .osc7, confidence: .authoritative)
    }

    // MARK: - allowedRoots 构造规则（§10/§19/§23）

    /// authoritative cwd（OSC 7）→ allowedRoots = [canonical root]。
    /// raw 路径含 symlink 前缀（/var）：root 存储前必须 canonical 化（§19）。
    func testAuthoritativeLocalCWDYieldsCanonicalRoot() {
        let scope = AgentReadScope.make(
            sessionID: UUID(), workingDirectory: authoritative(rawBase + "/root"), kind: .local
        )
        XCTAssertEqual(scope.allowedRoots, [canonicalBase + "/root"])
    }

    /// scope root 自身经过 symlink：`root/link -> ../outside` 作为 cwd 时，
    /// 存储的必须是最终 canonical root（outside），绝不存词法路径（§19）。
    func testSymlinkedRootIsStoredCanonical() {
        let scope = AgentReadScope.make(
            sessionID: UUID(), workingDirectory: authoritative(rawBase + "/root/link"), kind: .local
        )
        XCTAssertEqual(scope.allowedRoots, [canonicalBase + "/outside"])
    }

    /// symlink 环上的 cwd：canonical 化失败 → roots = []，宁可拒绝读取。
    func testLoopingCWDYieldsEmptyRoots() {
        let scope = AgentReadScope.make(
            sessionID: UUID(), workingDirectory: authoritative(rawBase + "/loop-a"), kind: .local
        )
        XCTAssertEqual(scope.allowedRoots, [])
    }

    /// approximate（SFTP session default）cwd：携带 path 但 roots 必须为空
    /// ——绝不自动加入 allowedRoots（任务书 §23 hard gate）。
    func testApproximateCWDYieldsEmptyRoots() {
        let scope = AgentReadScope.make(
            sessionID: UUID(),
            workingDirectory: .sessionDefault(path: "/home/user"),
            kind: .remote
        )
        XCTAssertEqual(scope.allowedRoots, [])
    }

    func testUnavailableCWDYieldsEmptyRoots() {
        let scope = AgentReadScope.make(
            sessionID: UUID(), workingDirectory: .unavailable, kind: .local
        )
        XCTAssertEqual(scope.allowedRoots, [])
    }

    /// 空 / 相对路径即便声称 authoritative 也必须拒绝（防御性：工厂
    /// 构造不会产出该组合，但 make 不得信任输入形态）。
    func testNonAbsoluteCWDYieldsEmptyRoots() {
        for path in ["", "relative/path"] {
            let scope = AgentReadScope.make(
                sessionID: UUID(), workingDirectory: authoritative(path), kind: .local
            )
            XCTAssertEqual(scope.allowedRoots, [], "path=\(path) 必须得到空 roots")
        }
    }

    // MARK: - Remote policy（§10/§23）

    /// 远程 authoritative cwd：root 只做词法规范化；本地文件系统对远端
    /// 路径无权威性——用「与本地同名但本地是 symlink」的路径证明
    /// remote 模式绝不探测本地文件系统。
    func testRemoteScopeIsLexicalWithoutLocalProbing() {
        let scope = AgentReadScope.make(
            sessionID: UUID(),
            workingDirectory: authoritative(rawBase + "/root/link"),
            kind: .remote
        )
        // 本地 root/link 是指向 outside 的 symlink；remote 模式必须原样保留。
        XCTAssertEqual(scope.allowedRoots, [rawBase + "/root/link"])
    }

    /// 远程策略表达（任务书 §23 示例）：root=/srv/app。
    func testRemoteAuthoritativePolicyExpressed() {
        let scope = AgentReadScope.make(
            sessionID: UUID(), workingDirectory: authoritative("/srv/app"), kind: .remote
        )
        XCTAssertEqual(scope.allowedRoots, ["/srv/app"])
    }

    // MARK: - Containment（§17）

    /// path-component aware containment：裸 `hasPrefix(root)` 会把
    /// `/project-evil` 误判进 `/project`（任务书 §17 反例）。
    func testContainmentIsPathComponentAware() {
        XCTAssertTrue(AgentReadScope.isPath("/project/file", containedInRoot: "/project"))
        XCTAssertTrue(AgentReadScope.isPath("/project", containedInRoot: "/project"))
        XCTAssertFalse(AgentReadScope.isPath("/project-evil", containedInRoot: "/project"))
        XCTAssertFalse(AgentReadScope.isPath("/projectevil", containedInRoot: "/project"))
        XCTAssertFalse(AgentReadScope.isPath("/proj", containedInRoot: "/project"))
        XCTAssertFalse(AgentReadScope.isPath("/project/file", containedInRoot: "/project-evil"))
        XCTAssertFalse(AgentReadScope.isPath("/", containedInRoot: "/project"))
    }

    /// `/` root 特例：包含一切绝对路径（调用方保证 target 是 canonical
    /// 绝对路径）。
    func testRootSlashContainsEveryAbsolutePath() {
        XCTAssertTrue(AgentReadScope.isPath("/anything", containedInRoot: "/"))
        XCTAssertTrue(AgentReadScope.isPath("/a/b/c", containedInRoot: "/"))
        XCTAssertTrue(AgentReadScope.isPath("/", containedInRoot: "/"))
    }

    /// contains 检查所有 roots；空 roots 拒绝一切。
    func testContainsChecksAllRootsAndEmptyRootsRejectAll() {
        let multi = AgentReadScope(
            sessionID: UUID(),
            allowedRoots: [canonicalBase + "/root", canonicalBase + "/outside"]
        )
        XCTAssertTrue(multi.contains(canonicalBase + "/root/file.txt"))
        XCTAssertTrue(multi.contains(canonicalBase + "/outside/secret.txt"))
        XCTAssertFalse(multi.contains(canonicalBase + "/other"))

        let empty = AgentReadScope(sessionID: UUID(), allowedRoots: [])
        XCTAssertFalse(empty.contains("/anything"))
        XCTAssertFalse(empty.contains("/"))
    }

    // MARK: - 会话绑定（§33 预备）

    /// scope 与终端会话绑定：sessionID 原样存储（执行层必须校验配对，
    /// 错误 session 的 scope 是 P1——本阶段建立 domain 表达）。
    func testSessionIDIsBoundToScope() {
        let id = UUID()
        let scope = AgentReadScope.make(
            sessionID: id, workingDirectory: authoritative(rawBase + "/root"), kind: .local
        )
        XCTAssertEqual(scope.sessionID, id)
    }
}
