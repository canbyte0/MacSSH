import Foundation
import XCTest

@testable import MacSSH

/// 10D-B3 §17–§26/§68/§69：Remote 路径解析器测试（全部 offline fake）。
final class AgentRemotePathResolverTests: XCTestCase {
    private var fake: FakeAgentRemoteFileSystem!
    private var sessionID = UUID()
    private var scope: AgentReadScope!
    private let root = "/srv/app"
    private let outside = "/srv/outside"

    private var authoritative: AgentWorkingDirectory {
        AgentWorkingDirectory.fromOSC7URL("file://host\(root)")
    }

    /// §17：SFTP realpath(".") 只是 session default——绝不当作 interactive
    /// shell cwd。
    private var approximate: AgentWorkingDirectory {
        AgentWorkingDirectory.sessionDefault(path: root)
    }

    override func setUp() async throws {
        fake = FakeAgentRemoteFileSystem()
        await fake.addDirectory("/")
        await fake.addDirectory("/srv")
        await fake.addDirectory(root)
        await fake.addDirectory(root + "/src")
        await fake.addDirectory(root + "/real")
        await fake.addDirectory(outside)
        await fake.addFile(root + "/README.md", "readme")
        await fake.addFile(root + "/src/main.swift", "swift")
        await fake.addFile(root + "/real/file.txt", "real")
        await fake.addFile(outside + "/secret.txt", "secret")
        await fake.addSymlink(root + "/link-in", target: root + "/real")
        await fake.addSymlink(root + "/link-out", target: outside)
        await fake.addSymlink(root + "/broken", target: outside + "/missing.txt")

        sessionID = UUID()
        scope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: authoritative,
            client: fake
        )
        // scope 创建本身会 canonicalize：计数器清零，后续断言只看调用期。
        await fake.resetCounters()
    }

    private func resolve(
        _ path: String,
        workingDirectory: AgentWorkingDirectory? = nil,
        readScope: AgentReadScope? = nil
    ) async -> Result<String, AgentToolError> {
        await AgentRemotePathResolver.resolve(
            requestedPath: path,
            workingDirectory: workingDirectory ?? authoritative,
            readScope: readScope ?? scope,
            client: fake
        )
    }

    // MARK: - 允许路径（§68/§127）

    func testAuthoritativeRelativeInside() async {
        let result = await resolve("README.md")
        XCTAssertEqual(try? result.get(), root + "/README.md")
    }

    func testAuthoritativeDotPath() async {
        let result = await resolve("./src/main.swift")
        XCTAssertEqual(try? result.get(), root + "/src/main.swift")
    }

    func testAbsoluteInside() async {
        let result = await resolve(root + "/src/main.swift")
        XCTAssertEqual(try? result.get(), root + "/src/main.swift")
    }

    func testDotDotRemainsInside() async {
        let result = await resolve("src/../README.md")
        XCTAssertEqual(try? result.get(), root + "/README.md")
    }

    func testLexicalNormalizationOfRedundantSeparators() async {
        let result = await resolve("//srv//app//.//src//main.swift")
        XCTAssertEqual(try? result.get(), root + "/src/main.swift")
    }

    // MARK: - 拒绝路径（§18/§19/§24/§26）

    func testDotDotEscapeIsRejected() async {
        let result = await resolve("../outside/secret.txt")
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope)
    }

    func testAbsoluteOutsideIsRejected() async {
        let result = await resolve(outside + "/secret.txt")
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope)
    }

    func testEmptyPathIsInvalidArguments() async {
        let result = await resolve("")
        XCTAssertEqual(result.errorValue, .invalidArguments)
    }

    func testTildeIsInvalidArguments() async {
        let bare = await resolve("~")
        let relative = await resolve("~/README.md")
        XCTAssertEqual(bare.errorValue, .invalidArguments)
        XCTAssertEqual(relative.errorValue, .invalidArguments)
    }

    func testRootPrefixSiblingIsRejected() async {
        // `/srv/app-evil` 绝不能被 `/srv/app` 前缀吞掉。
        await fake.addDirectory("/srv/app-evil")
        await fake.addFile("/srv/app-evil/x.txt", "x")
        let result = await resolve("/srv/app-evil/x.txt")
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope, "§17：path-component aware")
    }

    // MARK: - cwd 语义（§17/§18/§126）

    func testApproximateCWDRelativeIsCwdUnavailable() async {
        // sessionDefault 只是近似：绝不作为相对路径基准。
        let result = await resolve("README.md", workingDirectory: approximate)
        XCTAssertEqual(result.errorValue, .cwdUnavailable)
    }

    func testApproximateCWDAbsoluteIsOutsideScope() async {
        // §126：approximate cwd 不创建 allowedRoot → 绝对路径也被拒。
        let approximateScope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: approximate,
            client: fake
        )
        XCTAssertEqual(approximateScope.allowedRoots, [], "§17：approximate 绝不自动成为 root")
        let result = await resolve(
            root + "/README.md",
            workingDirectory: approximate,
            readScope: approximateScope
        )
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope)
    }

    func testUnavailableCWDRelativeIsCwdUnavailable() async {
        let result = await resolve("README.md", workingDirectory: .unavailable)
        XCTAssertEqual(result.errorValue, .cwdUnavailable)
    }

    func testUnavailableCWDAbsoluteIsOutsideScope() async {
        let unavailableScope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: .unavailable,
            client: fake
        )
        XCTAssertEqual(unavailableScope.allowedRoots, [])
        let result = await resolve(
            root + "/README.md",
            workingDirectory: .unavailable,
            readScope: unavailableScope
        )
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope)
    }

    // MARK: - symlink（§24–§26/§69）

    func testSymlinkInsideTargetIsAllowed() async {
        let result = await resolve("link-in/file.txt")
        XCTAssertEqual(try? result.get(), root + "/real/file.txt")
    }

    func testSymlinkEscapeIsRejected() async {
        let result = await resolve("link-out/secret.txt")
        XCTAssertEqual(
            result.errorValue,
            .outsideAllowedReadScope,
            "§24：词法上在 root 内也绝不放行——只看 canonical target"
        )
    }

    func testDirectorySymlinkEscapeIsRejected() async {
        let result = await resolve("link-out")
        XCTAssertEqual(result.errorValue, .outsideAllowedReadScope, "§26")
    }

    func testBrokenSymlinkIsPathNotFound() async {
        let result = await resolve("broken")
        XCTAssertEqual(result.errorValue, .pathNotFound, "§23")
    }

    func testNonexistentIsPathNotFound() async {
        let result = await resolve("no-such.txt")
        XCTAssertEqual(result.errorValue, .pathNotFound)
    }

    func testPermissionDeniedIsMapped() async {
        await fake.deny(root + "/README.md")
        let result = await resolve("README.md")
        XCTAssertEqual(result.errorValue, .permissionDenied)
    }

    func testConnectionLostIsSessionUnavailable() async {
        await fake.disconnect()
        let result = await resolve("README.md")
        XCTAssertEqual(result.errorValue, .sessionUnavailable, "§45")
    }

    func testCancellationBeforeCanonicalization() async {
        let directory = authoritative
        guard let readScope = scope, let client = fake else {
            return XCTFail("fixture 未装配")
        }
        let task = Task { () -> Result<String, AgentToolError> in
            await AgentRemotePathResolver.resolve(
                requestedPath: "README.md",
                workingDirectory: directory,
                readScope: readScope,
                client: client
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.errorValue, .cancelled)
    }

    // MARK: - Remote scope 创建（§16/§17）

    func testRemoteScopeCanonicalizesAuthoritativeRoot() async {
        // root 自身是 symlink 时，allowedRoot 必须存最终 canonical root。
        await fake.addSymlink("/srv/shortcut", target: root)
        let shortcutScope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/shortcut"),
            client: fake
        )
        XCTAssertEqual(shortcutScope.allowedRoots, [root])
    }

    func testRemoteScopeIsEmptyWhenRootMissing() async {
        let missingScope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: AgentWorkingDirectory.fromOSC7URL("file://host/srv/nope"),
            client: fake
        )
        XCTAssertEqual(missingScope.allowedRoots, [], "canonicalize 失败绝不退回词法 root")
    }

    func testRemoteScopeIsEmptyWhenDisconnected() async {
        await fake.disconnect()
        let lostScope = await AgentReadScope.makeRemote(
            sessionID: sessionID,
            workingDirectory: authoritative,
            client: fake
        )
        XCTAssertEqual(lostScope.allowedRoots, [])
    }

    // MARK: - 词法规范化（§22）

    func testLexicalNormalize() {
        XCTAssertEqual(AgentRemotePathResolver.lexicalNormalize("/a/b/../c"), "/a/c")
        XCTAssertEqual(AgentRemotePathResolver.lexicalNormalize("/a//b/./c"), "/a/b/c")
        XCTAssertEqual(AgentRemotePathResolver.lexicalNormalize("/../.."), "/")
        XCTAssertNil(AgentRemotePathResolver.lexicalNormalize("relative/path"))
    }
}
