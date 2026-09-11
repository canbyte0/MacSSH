import Darwin
import Foundation
import XCTest

@testable import MacSSH

/// 10D-B2 §20–§29/§38/§39：Local 只读文件服务测试。
///
/// 全部使用 temporary fixture：绝不读取开发者真实敏感文件。
final class AgentLocalFileServiceTests: XCTestCase {
    private var base = ""
    private var root = ""
    private var outside = ""
    private var sessionID = UUID()
    private var scope: AgentReadScope!
    private var cwd: AgentWorkingDirectory!
    private let service = AgentLocalFileService()

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSSH.B2Files.\(UUID().uuidString)", isDirectory: true)
            .path
        root = base + "/root"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root + "/subdir", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "readme".write(toFile: root + "/file.txt", atomically: true, encoding: .utf8)
        try "inner".write(toFile: root + "/subdir/inner.txt", atomically: true, encoding: .utf8)
        try "hidden".write(toFile: root + "/.hidden", atomically: true, encoding: .utf8)
        try "env".write(toFile: root + "/.env.example", atomically: true, encoding: .utf8)
        try "secret".write(toFile: outside + "/secret.txt", atomically: true, encoding: .utf8)
        // 目录内指向 scope 外目录的 symlink（§28/§39）。
        try FileManager.default.createSymbolicLink(
            atPath: root + "/link", withDestinationPath: "../outside"
        )
        // 目录内指向 scope 内文件的 symlink（§28：target 在内 → 允许）。
        try FileManager.default.createSymbolicLink(
            atPath: root + "/link-in", withDestinationPath: "file.txt"
        )
        // 特殊文件名（§38）。
        try "u".write(toFile: root + "/中文 文件.txt", atomically: true, encoding: .utf8)
        try "p".write(toFile: root + "/percent%question#hash?.txt", atomically: true, encoding: .utf8)
        // 二进制：NUL（§27）。
        let binary = Data([0x41, 0x00, 0x42])
        try binary.write(to: URL(fileURLWithPath: root + "/binary.bin"))
        // 非法 UTF-8（§27）。
        var invalid = Data("abc".utf8)
        invalid.append(contentsOf: [0xFF, 0xFE, 0xFD])
        try invalid.write(to: URL(fileURLWithPath: root + "/invalid.bin"))

        sessionID = UUID()
        cwd = AgentWorkingDirectory.fromOSC7URL("file://host\(root)")
        scope = AgentReadScope.make(sessionID: sessionID, workingDirectory: cwd, kind: .local)
    }

    override func tearDownWithError() throws {
        // chmod 000 的条目先恢复，保证清理成功。
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root + "/no-perm.txt")
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: - read_file：允许路径（§38）

    func testReadRelativeInsideScope() async {
        let result = await service.readFile(
            requestedPath: "file.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(try? result.get().text, "readme")
        XCTAssertEqual(try? result.get().truncated, false)
        XCTAssertEqual(try? result.get().bytesReturned, 6)
    }

    func testReadAbsoluteInsideScope() async {
        let result = await service.readFile(
            requestedPath: root + "/file.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(try? result.get().text, "readme")
    }

    func testReadDotDotNormalizedInsideScope() async {
        let result = await service.readFile(
            requestedPath: "subdir/../file.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(try? result.get().text, "readme")
    }

    func testReadUnicodeSpaceAndReservedFilenames() async throws {
        let unicode = await service.readFile(
            requestedPath: "中文 文件.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(try? unicode.get().text, "u")

        let reserved = await service.readFile(
            requestedPath: "percent%question#hash?.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(try? reserved.get().text, "p")
    }

    func testReadSymlinkWhoseTargetIsInsideScope() async {
        // canonicalization 跟随 symlink：target = root/file.txt 在 scope 内 → 允许。
        let result = await service.readFile(
            requestedPath: "link-in", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(try? result.get().text, "readme")
    }

    // MARK: - read_file：拒绝路径（§28/§38）

    func testRejectDotDotEscape() async {
        let result = await service.readFile(
            requestedPath: "../outside/secret.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.outsideAllowedReadScope))
    }

    func testRejectSymlinkEscape() async {
        let result = await service.readFile(
            requestedPath: "link/secret.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.outsideAllowedReadScope))
    }

    func testRejectSymlinkEscapeToNonexistentTail() async {
        let result = await service.readFile(
            requestedPath: "link/missing.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.outsideAllowedReadScope))
    }

    func testMissingFileIsPathNotFound() async {
        let result = await service.readFile(
            requestedPath: "missing.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.pathNotFound))
    }

    func testDirectoryPassedToReadFileIsNotAFile() async {
        let result = await service.readFile(
            requestedPath: "subdir", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.notAFile))
    }

    func testInvalidUTF8IsBinaryUnsupported() async {
        let result = await service.readFile(
            requestedPath: "invalid.bin", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.binaryUnsupported))
    }

    func testNULByteIsBinaryUnsupported() async {
        let result = await service.readFile(
            requestedPath: "binary.bin", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.binaryUnsupported))
    }

    func testUntrustedCWDRelativePathIsCwdUnavailable() async {
        let approximate = AgentWorkingDirectory.sessionDefault(path: root)
        let result = await service.readFile(
            requestedPath: "file.txt", workingDirectory: approximate, readScope: scope
        )
        XCTAssertEqual(result, .failure(.cwdUnavailable))
        let unavailable = await service.readFile(
            requestedPath: "file.txt", workingDirectory: .unavailable, readScope: scope
        )
        XCTAssertEqual(unavailable, .failure(.cwdUnavailable))
    }

    func testPermissionDeniedWhereDeterministicallyTestable() async throws {
        try XCTSkipIf(geteuid() == 0, "root 不受文件权限限制")
        let path = root + "/no-perm.txt"
        try "locked".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        let result = await service.readFile(
            requestedPath: "no-perm.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.permissionDenied))
    }

    // MARK: - read_file：bounded read（§25/§26）

    func testLargeFileIsBoundedAndTruncated() async throws {
        let limit = AgentTextLimits.fileReadMaxBytes
        let payload = Data(repeating: UInt8(ascii: "a"), count: limit + 44 * 1024)
        try payload.write(to: URL(fileURLWithPath: root + "/large.txt"))

        let result = await service.readFile(
            requestedPath: "large.txt", workingDirectory: cwd, readScope: scope
        )
        let content = try XCTUnwrap(try? result.get())
        XCTAssertTrue(content.truncated)
        XCTAssertEqual(content.bytesReturned, limit, "绝不超过 256 KiB 硬上限")
        XCTAssertEqual(content.text.utf8.count, limit)
        XCTAssertEqual(content.originalSize, UInt64(limit + 44 * 1024))
    }

    func testEmojiStraddlingLimitIsNotMistakenForBinary() async throws {
        let limit = AgentTextLimits.fileReadMaxBytes
        // emoji 跨在 256 KiB 边界上：占 limit-2 .. limit+1。
        var payload = Data(repeating: UInt8(ascii: "a"), count: limit - 2)
        payload.append(Data("😀".utf8))
        try payload.write(to: URL(fileURLWithPath: root + "/boundary.txt"))

        let result = await service.readFile(
            requestedPath: "boundary.txt", workingDirectory: cwd, readScope: scope
        )
        let content = try XCTUnwrap(try? result.get())
        XCTAssertTrue(content.truncated)
        XCTAssertEqual(content.bytesReturned, limit - 2, "回退到 code point 边界")
        XCTAssertEqual(content.text, String(repeating: "a", count: limit - 2))
        XCTAssertFalse(content.text.contains("\u{FFFD}"), "绝不产生替换字符")
    }

    func testEmojiEndingExactlyAtLimitIsNotTruncated() async throws {
        let limit = AgentTextLimits.fileReadMaxBytes
        var payload = Data(repeating: UInt8(ascii: "a"), count: limit - 4)
        payload.append(Data("😀".utf8))
        try payload.write(to: URL(fileURLWithPath: root + "/exact.txt"))

        let result = await service.readFile(
            requestedPath: "exact.txt", workingDirectory: cwd, readScope: scope
        )
        let content = try XCTUnwrap(try? result.get())
        XCTAssertFalse(content.truncated)
        XCTAssertEqual(content.bytesReturned, limit)
        XCTAssertTrue(content.text.hasSuffix("😀"))
    }

    func testChineseStraddlingLimitIsNotMistakenForBinary() async throws {
        let limit = AgentTextLimits.fileReadMaxBytes
        var payload = Data(repeating: UInt8(ascii: "a"), count: limit - 1)
        payload.append(Data("中".utf8)) // 3 bytes：limit-1, limit, limit+1
        try payload.write(to: URL(fileURLWithPath: root + "/zh-boundary.txt"))

        let result = await service.readFile(
            requestedPath: "zh-boundary.txt", workingDirectory: cwd, readScope: scope
        )
        let content = try XCTUnwrap(try? result.get())
        XCTAssertTrue(content.truncated)
        XCTAssertEqual(content.bytesReturned, limit - 1)
    }

    // MARK: - list_directory（§21/§22/§23/§39）

    func testListDirectoryIncludesHiddenFiles() async throws {
        let result = await service.listDirectory(
            requestedPath: ".", workingDirectory: cwd, readScope: scope
        )
        let listing = try XCTUnwrap(try? result.get())
        let names = Set(listing.entries.map(\.name))
        XCTAssertTrue(names.contains(".hidden"))
        XCTAssertTrue(names.contains(".env.example"))
    }

    func testListDirectoryReportsKindsIncludingSymlink() async throws {
        let result = await service.listDirectory(
            requestedPath: ".", workingDirectory: cwd, readScope: scope
        )
        let listing = try XCTUnwrap(try? result.get())
        let kinds = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0.kind) })
        XCTAssertEqual(kinds["file.txt"], .file)
        XCTAssertEqual(kinds["subdir"], .directory)
        XCTAssertEqual(kinds["link"], .symbolicLink, "条目本身是链接必须告知模型（§21）")
        XCTAssertEqual(kinds["link-in"], .symbolicLink)
        let fileEntry = try XCTUnwrap(listing.entries.first { $0.name == "file.txt" })
        XCTAssertEqual(fileEntry.sizeBytes, 6)
        let dirEntry = try XCTUnwrap(listing.entries.first { $0.name == "subdir" })
        XCTAssertNil(dirEntry.sizeBytes)
    }

    func testListEmptyDirectory() async throws {
        let empty = root + "/empty"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let result = await service.listDirectory(
            requestedPath: "empty", workingDirectory: cwd, readScope: scope
        )
        let listing = try XCTUnwrap(try? result.get())
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertFalse(listing.truncated)
        XCTAssertEqual(listing.totalEntryCount, 0)
    }

    func testListDirectoryOnFileIsNotADirectory() async {
        let result = await service.listDirectory(
            requestedPath: "file.txt", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.notADirectory))
    }

    func testListDirectoryRejectsSymlinkEscape() async {
        let result = await service.listDirectory(
            requestedPath: "link", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.outsideAllowedReadScope))
    }

    func testListDirectoryRejectsOutsideScope() async {
        let result = await service.listDirectory(
            requestedPath: "../outside", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.outsideAllowedReadScope))
    }

    func testListDirectoryMissingIsPathNotFound() async {
        let result = await service.listDirectory(
            requestedPath: "missing-dir", workingDirectory: cwd, readScope: scope
        )
        XCTAssertEqual(result, .failure(.pathNotFound))
    }

    func testListDirectoryExactly500Entries() async throws {
        let directory = root + "/five-hundred"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for index in 0..<500 {
            try Data("x".utf8).write(to: URL(fileURLWithPath: "\(directory)/f-\(index).txt"))
        }
        let result = await service.listDirectory(
            requestedPath: "five-hundred", workingDirectory: cwd, readScope: scope
        )
        let listing = try XCTUnwrap(try? result.get())
        XCTAssertEqual(listing.entries.count, 500)
        XCTAssertFalse(listing.truncated)
        XCTAssertEqual(listing.totalEntryCount, 500)
    }

    func testListDirectory501EntriesIsTruncated() async throws {
        let directory = root + "/five-oh-one"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for index in 0..<501 {
            try Data("x".utf8).write(to: URL(fileURLWithPath: "\(directory)/f-\(index).txt"))
        }
        let result = await service.listDirectory(
            requestedPath: "five-oh-one", workingDirectory: cwd, readScope: scope
        )
        let listing = try XCTUnwrap(try? result.get())
        XCTAssertEqual(listing.entries.count, 500)
        XCTAssertTrue(listing.truncated)
        XCTAssertEqual(listing.totalEntryCount, 501)
    }

    func testOrderingIsDeterministicAndLocaleIndependent() async throws {
        let directory = root + "/ordering"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: directory + "/adir", withIntermediateDirectories: false)
        // 刻意避开仅大小写不同的名字：macOS APFS 默认大小写不敏感，
        // 同名文件会互相覆盖，导致 fixture 不确定。
        for name in ["beta.txt", "Alpha.txt", "gamma.txt", "中文.txt", "_under.txt"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: "\(directory)/\(name)"))
        }
        try FileManager.default.createSymbolicLink(
            atPath: directory + "/zlink", withDestinationPath: "a.txt"
        )

        let firstResult = await service.listDirectory(
            requestedPath: "ordering", workingDirectory: cwd, readScope: scope
        )
        let secondResult = await service.listDirectory(
            requestedPath: "ordering", workingDirectory: cwd, readScope: scope
        )
        let first = try XCTUnwrap(try? firstResult.get())
        let second = try XCTUnwrap(try? secondResult.get())
        XCTAssertEqual(first.entries, second.entries, "同输入必须完全确定性")

        // 目录 → 链接 → 文件；同类内按 UTF-8 字节序（大写字母 < 下划线 < 小写 < 中文）。
        XCTAssertEqual(
            first.entries.map(\.name),
            ["adir", "zlink", "Alpha.txt", "_under.txt", "beta.txt", "gamma.txt", "中文.txt"]
        )
    }
}
