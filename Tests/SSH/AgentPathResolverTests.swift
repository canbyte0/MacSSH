import Darwin
import XCTest

@testable import MacSSH

/// MacSSH 1.1 Phase 10D-B1 §12–§23：AgentPathResolver 测试。
///
/// 覆盖（任务书 hard gate）：
/// - `..` traversal（§15：root 内允许、root 外拒绝）；
/// - symlink escape（§16：词法在 root 内、canonical 在 root 外 → 拒绝）；
/// - 不存在尾部组件不得绕过 symlink containment（§18，Foundation
///   `resolvingSymlinksInPath` 的已知缺口）；
/// - root 自身经 symlink（§19）；
/// - 绝对路径越界（§21：fixture 外部目录模拟 /etc/passwd，不读真实敏感文件）；
/// - cwd 不可用时绝不 fallback HOME（§13）；
/// - remote approximate 策略（§23）；
/// - tilde 展开后仍要过 containment（§14）。
final class AgentPathResolverTests: XCTestCase {
    private var rawBase = ""
    private var canonicalBase = ""

    override func setUpWithError() throws {
        rawBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSSH.PathResolver.\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            atPath: rawBase + "/root/subdir", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: rawBase + "/outside", withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            atPath: rawBase + "/real", withIntermediateDirectories: false
        )
        try "readme".write(toFile: rawBase + "/root/file.txt", atomically: true, encoding: .utf8)
        try "secret".write(toFile: rawBase + "/outside/secret.txt", atomically: true, encoding: .utf8)
        try "final".write(toFile: rawBase + "/real/final.txt", atomically: true, encoding: .utf8)
        // root/link -> ../outside（相对 target：拼接在 link 所在目录）。
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/root/link", withDestinationPath: "../outside"
        )
        // root/abs -> 绝对路径 outside（绝对 target：重置到根再解）。
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/root/abs", withDestinationPath: rawBase + "/outside"
        )
        // root/chain -> chain2 -> ../real（symlink 链）。
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/root/chain", withDestinationPath: "chain2"
        )
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/root/chain2", withDestinationPath: "../real"
        )
        // loop-a <-> loop-b（ELOOP）。
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/loop-a", withDestinationPath: "loop-b"
        )
        try FileManager.default.createSymbolicLink(
            atPath: rawBase + "/loop-b", withDestinationPath: "loop-a"
        )
        // 独立 oracle：libc realpath（kernel 语义）。实测 Foundation 的
        // resolvingSymlinksInPath 不解析 /var → /private/var 前缀（即使
        // 路径存在），与 walker 语义不一致，不能当 oracle。
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

    // MARK: - 辅助

    private func authoritative(_ path: String) -> AgentWorkingDirectory {
        AgentWorkingDirectory(path: path, source: .osc7, confidence: .authoritative)
    }

    /// 以「authoritative OSC 7 cwd = path」构造 scope（root 已 canonical 化）。
    private func makeScope(
        _ path: String, kind: AgentPathResolver.SessionKind = .local
    ) -> AgentReadScope {
        AgentReadScope.make(
            sessionID: UUID(), workingDirectory: authoritative(path), kind: kind
        )
    }

    private func resolve(
        _ requested: String,
        cwd: AgentWorkingDirectory,
        scope: AgentReadScope,
        home: String? = nil,
        kind: AgentPathResolver.SessionKind = .local
    ) -> Result<String, AgentToolError> {
        AgentPathResolver.resolve(
            requestedPath: requested,
            workingDirectory: cwd,
            readScope: scope,
            homeDirectory: home,
            kind: kind
        )
    }

    // MARK: - canonicalize：词法规范化

    /// `.` / `..` / 重复斜杠 / 尾部斜杠 / 根特例全部按 kernel 词法规则归一。
    func testCanonicalizeNormalizesDotDotAndSlashes() {
        let resolver = AgentPathResolver.self
        XCTAssertEqual(resolver.canonicalize("/a/./b/../c", kind: .local), "/a/c")
        XCTAssertEqual(resolver.canonicalize("///a//b//c", kind: .local), "/a/b/c")
        XCTAssertEqual(resolver.canonicalize("/a/b/", kind: .local), "/a/b")
        XCTAssertEqual(resolver.canonicalize("/a/b/.", kind: .local), "/a/b")
        XCTAssertEqual(resolver.canonicalize("/", kind: .local), "/")
        XCTAssertEqual(resolver.canonicalize("/..", kind: .local), "/")
        XCTAssertEqual(resolver.canonicalize("/../a", kind: .local), "/a")
    }

    /// 相对输入直接拒绝（nil → internalFailure）。
    func testCanonicalizeRejectsRelativeInput() {
        XCTAssertNil(AgentPathResolver.canonicalize("a/b", kind: .local))
    }

    /// 首个不存在的组件之后不可能再有可解析对象：剩余尾部纯词法处理。
    func testCanonicalizeNonexistentPathIsLexical() {
        XCTAssertEqual(
            AgentPathResolver.canonicalize("/definitely/not/here/../a", kind: .local),
            "/definitely/not/a"
        )
    }

    // MARK: - canonicalize：symlink（§16/§18/§19）

    /// raw 路径的 /var symlink 前缀必须被解析（macOS temporary directory
    /// 天然覆盖 §19：root 经 symlink 时 canonical 化）。
    func testCanonicalizeResolvesExistingPathThroughVarSymlink() {
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/file.txt", kind: .local),
            canonicalBase + "/root/file.txt"
        )
    }

    /// 中间 symlink：`root/link/secret.txt` → `outside/secret.txt`（§16）。
    func testCanonicalizeResolvesMidPathSymlink() {
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/link/secret.txt", kind: .local),
            canonicalBase + "/outside/secret.txt"
        )
    }

    /// 末位 symlink：`root/link` → `outside`。
    func testCanonicalizeResolvesTrailingSymlink() {
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/link", kind: .local),
            canonicalBase + "/outside"
        )
    }

    /// §18 hard gate：`root/link/missing.txt`（link → outside、尾部不存在）
    /// 必须先解 link 再追加尾部——Foundation 对该形态不解析中间 symlink，
     /// 词法 containment 判定会放行而 kernel open 沿 link 逃逸。
    func testCanonicalizeResolvesSymlinkBeforeNonexistentTail() {
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/link/missing.txt", kind: .local),
            canonicalBase + "/outside/missing.txt"
        )
    }

    /// 任务书 §18 明确要求实证 Foundation 的缺口行为（对不存在尾部组件
    /// 不解析中间 symlink）——这是自研 walker 存在的理由。若未来 Foundation
    /// 修复该行为，本断言失败是提醒重新评估，而非安全回归。
    ///
    /// 注：Foundation 的 resolvingSymlinksInPath 实测也不解析 /var 前缀
    /// （与 realpath 语义不同），故用后缀断言聚焦本测试主题——缺口在
    /// link 组件，不在 /var。
    func testFoundationResolvingSymlinksLeavesNonexistentTailUnresolved() {
        let foundation = URL(fileURLWithPath: rawBase + "/root/link/missing.txt")
            .resolvingSymlinksInPath().path
        XCTAssertTrue(
            foundation.hasSuffix("/root/link/missing.txt"),
            "Foundation 对不存在尾部必须保留词法 link 组件（实际：\(foundation)）"
        )
        XCTAssertNotEqual(
            foundation, canonicalBase + "/outside/missing.txt",
            "Foundation 已能解析该形态？重新评估自研 walker 的必要性"
        )
    }

    /// symlink 链：root/chain → chain2 → ../real。
    func testCanonicalizeFollowsSymlinkChain() {
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/chain", kind: .local),
            canonicalBase + "/real"
        )
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/chain/final.txt", kind: .local),
            canonicalBase + "/real/final.txt"
        )
    }

    /// 绝对 symlink target：解析重置到根。
    func testCanonicalizeAbsoluteSymlinkTargetResetsToRoot() {
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/abs/secret.txt", kind: .local),
            canonicalBase + "/outside/secret.txt"
        )
    }

    /// symlink 环：按 ELOOP 语义返回 nil（resolve 层映射 internalFailure）。
    func testCanonicalizeReturnsNilForSymlinkLoop() {
        XCTAssertNil(AgentPathResolver.canonicalize(rawBase + "/loop-a", kind: .local))
        XCTAssertNil(AgentPathResolver.canonicalize(rawBase + "/loop-a/whatever", kind: .local))
    }

    /// `link/..` 的 kernel 语义：先解 symlink 再弹（相对 target 拼接后
    /// `..` 作用于解析结果所在目录）。
    func testCanonicalizeDotDotAfterSymlinkUsesKernelSemantics() {
        // root/link -> ../outside：link/.. = outside 的父目录 = base。
        // root/link/../outside/secret.txt = base/outside/secret.txt。
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/link/../outside/secret.txt", kind: .local),
            canonicalBase + "/outside/secret.txt"
        )
    }

    // MARK: - canonicalize：remote（§23）

    /// remote 只做词法规范化：不解析 symlink（含 /var 前缀——本地状态
    /// 与远端无关）、处理 `.`/`..`。
    func testRemoteCanonicalizationIsPurelyLexical() {
        XCTAssertEqual(
            AgentPathResolver.canonicalize(rawBase + "/root/link/secret.txt", kind: .remote),
            rawBase + "/root/link/secret.txt",
            "remote 模式绝不探测本地文件系统"
        )
        XCTAssertEqual(
            AgentPathResolver.canonicalize("/srv/./app/../x", kind: .remote),
            "/srv/x"
        )
    }

    // MARK: - resolve：参数与 tilde（§12/§14）

    /// 空路径 → invalidArguments。
    func testResolveRejectsEmptyPath() {
        let result = resolve("", cwd: authoritative(rawBase + "/root"), scope: makeScope(rawBase + "/root"))
        XCTAssertEqual(result, .failure(.invalidArguments))
    }

    /// `~user` 形式、remote tilde、无 HOME 的本地 tilde 全部拒绝。
    func testResolveRejectsInvalidTildeForms() {
        let localScope = makeScope(rawBase + "/root")
        let localCWD = authoritative(rawBase + "/root")
        XCTAssertEqual(
            resolve("~user/file", cwd: localCWD, scope: localScope, home: rawBase + "/root"),
            .failure(.invalidArguments)
        )
        XCTAssertEqual(
            resolve("~", cwd: authoritative("/srv/app"), scope: makeScope("/srv/app", kind: .remote), kind: .remote),
            .failure(.invalidArguments)
        )
        XCTAssertEqual(
            resolve("~", cwd: localCWD, scope: localScope, home: nil),
            .failure(.invalidArguments)
        )
    }

    /// tilde 展开后必须再过 containment（§14：展开 ≠ 允许）。
    func testResolveTildeExpansionStillRequiresContainment() {
        let scope = makeScope(rawBase + "/root")

        // HOME 在 root 内：允许。
        XCTAssertEqual(
            resolve("~", cwd: authoritative(rawBase + "/root"), scope: scope, home: rawBase + "/root"),
            .success(canonicalBase + "/root")
        )
        XCTAssertEqual(
            resolve("~/file.txt", cwd: authoritative(rawBase + "/root"), scope: scope, home: rawBase + "/root"),
            .success(canonicalBase + "/root/file.txt")
        )

        // HOME 在 root 外（§14 示例：~/.ssh/id_ed25519 类比）：
        // 展开成功仍必须拒绝。
        XCTAssertEqual(
            resolve("~/.ssh/id_ed25519", cwd: authoritative(rawBase + "/root"), scope: scope, home: rawBase + "/outside"),
            .failure(.outsideAllowedReadScope)
        )
    }

    // MARK: - resolve：相对路径与 cwd（§13）

    /// authoritative cwd + 相对路径：拼接后 canonical 化再判 containment。
    func testResolveAppendsRelativeToAuthoritativeCWD() {
        let scope = makeScope(rawBase + "/root")
        XCTAssertEqual(
            resolve("file.txt", cwd: authoritative(rawBase + "/root"), scope: scope),
            .success(canonicalBase + "/root/file.txt")
        )
        XCTAssertEqual(
            resolve("subdir/../file.txt", cwd: authoritative(rawBase + "/root"), scope: scope),
            .success(canonicalBase + "/root/file.txt")
        )
    }

    /// cwd 非 authoritative（approximate / unavailable）：相对路径
    /// → cwdUnavailable，绝不 fallback HOME / App cwd（§13 hard gate）。
    func testResolveRejectsRelativePathWithoutAuthoritativeCWD() {
        let scope = makeScope(rawBase + "/root")
        XCTAssertEqual(
            resolve("file.txt", cwd: .sessionDefault(path: rawBase + "/root"), scope: scope),
            .failure(.cwdUnavailable)
        )
        XCTAssertEqual(
            resolve("file.txt", cwd: .unavailable, scope: scope),
            .failure(.cwdUnavailable)
        )
        // HOME 在场也不得成为 fallback（显式传 home 证明没有暗中使用）。
        XCTAssertEqual(
            resolve("file.txt", cwd: .unavailable, scope: scope, home: rawBase + "/root"),
            .failure(.cwdUnavailable)
        )
    }

    // MARK: - resolve：traversal / symlink / 越界（§15/§16/§18/§21）

    /// §15 允许例：`root/src/../README.md` 形式的 `..` 回到 root 内 → 允许。
    func testResolveAllowsDotDotStayingInsideRoot() {
        let scope = makeScope(rawBase + "/root")
        XCTAssertEqual(
            resolve("subdir/../file.txt", cwd: authoritative(rawBase + "/root"), scope: scope),
            .success(canonicalBase + "/root/file.txt")
        )
    }

    /// §15 拒绝例：`root/../../outside` → canonical 在 root 外 → 拒绝。
    func testResolveRejectsDotDotEscape() {
        let scope = makeScope(rawBase + "/root")
        XCTAssertEqual(
            resolve("../../outside/secret.txt", cwd: authoritative(rawBase + "/root"), scope: scope),
            .failure(.outsideAllowedReadScope)
        )
        XCTAssertEqual(
            resolve("../outside/secret.txt", cwd: authoritative(rawBase + "/root"), scope: scope),
            .failure(.outsideAllowedReadScope)
        )
    }

    /// §16 hard gate：`root/link/secret.txt` 词法在 root 内、canonical 在
    /// root 外 → 拒绝。相对形式与绝对形式都必须拒绝。
    func testResolveRejectsSymlinkEscape() {
        let scope = makeScope(rawBase + "/root")
        let cwd = authoritative(rawBase + "/root")
        XCTAssertEqual(
            resolve("link/secret.txt", cwd: cwd, scope: scope),
            .failure(.outsideAllowedReadScope)
        )
        XCTAssertEqual(
            resolve(rawBase + "/root/link/secret.txt", cwd: cwd, scope: scope),
            .failure(.outsideAllowedReadScope)
        )
    }

    /// §18 hard gate：`root/link/missing.txt`（尾部不存在）同样拒绝——
    /// 不得因不存在而绕过 symlink containment。
    func testResolveRejectsSymlinkEscapeToNonexistentTail() {
        let scope = makeScope(rawBase + "/root")
        let cwd = authoritative(rawBase + "/root")
        XCTAssertEqual(
            resolve("link/missing.txt", cwd: cwd, scope: scope),
            .failure(.outsideAllowedReadScope)
        )
    }

    /// §21 hard gate：绝对路径请求 root 外（fixture 的 outside 目录模拟
    /// /etc/passwd 场景，不读真实敏感路径）→ 拒绝。
    func testResolveRejectsAbsoluteOutsideRoot() {
        let scope = makeScope(rawBase + "/root")
        let cwd = authoritative(rawBase + "/root")
        XCTAssertEqual(
            resolve(rawBase + "/outside/secret.txt", cwd: cwd, scope: scope),
            .failure(.outsideAllowedReadScope)
        )
        XCTAssertEqual(
            resolve("/etc/passwd", cwd: cwd, scope: scope),
            .failure(.outsideAllowedReadScope)
        )
    }

    /// 绝对路径请求 root 内：成功返回 canonical 形式。
    func testResolveAcceptsCanonicalTargetInsideRoot() {
        let scope = makeScope(rawBase + "/root")
        XCTAssertEqual(
            resolve(rawBase + "/root/file.txt", cwd: authoritative(rawBase + "/root"), scope: scope),
            .success(canonicalBase + "/root/file.txt")
        )
    }

    /// scope root 为 `/`：包含一切 canonical 绝对路径（语义文档化）。
    func testResolveAcceptsAnyCanonicalPathWhenRootIsSlash() {
        let scope = AgentReadScope.make(
            sessionID: UUID(), workingDirectory: authoritative("/"), kind: .local
        )
        XCTAssertEqual(
            resolve(rawBase + "/root/file.txt", cwd: .unavailable, scope: scope),
            .success(canonicalBase + "/root/file.txt")
        )
    }

    /// symlink 环上的请求（root = "/" 足够宽）→ internalFailure（ELOOP）。
    func testResolveReturnsInternalFailureForSymlinkLoop() {
        let scope = AgentReadScope.make(
            sessionID: UUID(), workingDirectory: authoritative("/"), kind: .local
        )
        XCTAssertEqual(
            resolve(rawBase + "/loop-a", cwd: .unavailable, scope: scope),
            .failure(.internalFailure)
        )
    }

    // MARK: - resolve：remote policy（§23）

    /// remote authoritative：`root=/srv/app` + `./README.md` → 策略允许
    /// 解析（词法），产出 canonical 绝对路径。
    func testRemoteAuthoritativePolicyPermitsRelativeResolution() {
        let scope = makeScope("/srv/app", kind: .remote)
        let cwd = authoritative("/srv/app")
        XCTAssertEqual(
            resolve("./README.md", cwd: cwd, scope: scope, kind: .remote),
            .success("/srv/app/README.md")
        )
        XCTAssertEqual(
            resolve("src/../README.md", cwd: cwd, scope: scope, kind: .remote),
            .success("/srv/app/README.md")
        )
    }

    /// remote approximate（sessionDefault）：相对路径 → cwdUnavailable；
    /// 绝对路径 → 空 roots 拒绝（outsideAllowedReadScope）。
    /// sessionDefault 路径本身也绝不在 allowedRoots 里（§23 hard gate）。
    func testRemoteApproximatePolicyRejectsEverything() {
        let scope = AgentReadScope.make(
            sessionID: UUID(), workingDirectory: .sessionDefault(path: "/home/user"), kind: .remote
        )
        XCTAssertEqual(
            resolve("README.md", cwd: .sessionDefault(path: "/home/user"), scope: scope, kind: .remote),
            .failure(.cwdUnavailable)
        )
        XCTAssertEqual(
            resolve("/home/user/file", cwd: .sessionDefault(path: "/home/user"), scope: scope, kind: .remote),
            .failure(.outsideAllowedReadScope)
        )
    }
}
