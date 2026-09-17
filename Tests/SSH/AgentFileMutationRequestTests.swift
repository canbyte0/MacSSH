import Darwin
import Foundation
import XCTest

@testable import MacSSH

/// C1 request/capability tests：所有可变 fixture 都是测试数据，不属于生产 C1 side effect。
final class AgentFileMutationRequestTests: XCTestCase {
    /// relative path 必须在 proposal 时绑定 CWD A，而非任何之后的活动目录 B。
    func testRelativePathFreezesProposalTimeCWDAndExactUTF8Payload() async throws {
        let rootA = try AgentFileMutationTestSupport.makeTemporaryRoot()
        let rootB = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer {
            AgentFileMutationTestSupport.removeTemporaryRoot(rootA)
            AgentFileMutationTestSupport.removeTemporaryRoot(rootB)
        }
        try FileManager.default.createDirectory(at: rootA.appendingPathComponent("nested"), withIntermediateDirectories: false)

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: rootA,
            path: "nested/资料🙂.txt",
            content: "ASCII\n中文\n🙂\ne\u{301}\n"
        )

        // /var 在 macOS 上是 /private/var 的兼容符号链接；以真实路径验证冻结语义。
        XCTAssertEqual(
            request.proposalWorkingDirectory,
            try AgentFileMutationTestSupport.canonicalPathForAssertion(rootA.path)
        )
        XCTAssertEqual(
            request.displayPath,
            URL(fileURLWithPath: try AgentFileMutationTestSupport.canonicalPathForAssertion(
                rootA.appendingPathComponent("nested").path
            )).appendingPathComponent("资料🙂.txt").path
        )
        XCTAssertEqual(request.targetIdentity.basename, "资料🙂.txt")
        XCTAssertEqual(request.payloadUTF8, Data("ASCII\n中文\n🙂\ne\u{301}\n".utf8))
        XCTAssertEqual(request.payloadIdentity.byteCount, request.payloadUTF8.count)
        XCTAssertNotEqual(
            request.proposalWorkingDirectory,
            try AgentFileMutationTestSupport.canonicalPathForAssertion(rootB.path)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.displayPath), "C1 不得创建目标文件")
        let isOpen = await request.parentCapability.isOpen()
        let identityMatches = await request.parentCapability.stillMatchesCapturedDirectory()
        XCTAssertTrue(isOpen)
        XCTAssertTrue(identityMatches)
        _ = await request.parentCapability.invalidate()
    }

    /// 绝对路径与相对路径均沿用现有 read_file 已接受的基本形态。
    func testAbsolutePathIsAcceptedInsideFrozenWriteScope() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: nested.appendingPathComponent("absolute.txt").path
        )
        // 与相对路径用例一致，绝对输入的比较也消除 /var 的兼容路径表示差异。
        XCTAssertEqual(
            request.displayPath,
            URL(fileURLWithPath: try AgentFileMutationTestSupport.canonicalPathForAssertion(nested.path))
                .appendingPathComponent("absolute.txt").path
        )
        _ = await request.parentCapability.invalidate()
    }

    /// 空白、Unicode 与组合字符都是合法 basename 字节，C1 必须原样冻结而非 trim/normalize。
    func testWhitespaceAndUnicodeBasenameIsPreservedExactly() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let basename = "  资料🙂-e\u{301}  .txt  "

        let request = try await AgentFileMutationTestSupport.makeRequest(root: root, path: basename)

        XCTAssertEqual(request.userSuppliedPath, basename)
        XCTAssertEqual(request.targetIdentity.basename, basename)
        XCTAssertEqual(request.displayPath, request.proposalWorkingDirectory + "/" + basename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.displayPath))
        _ = await request.parentCapability.invalidate()
    }

    /// C1 不会静默纠正空 path、NUL、空 final component、`.` 或 `..`。
    func testStructuralPathFailuresAreRejectedBeforeApproval() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let scope = try AgentFileMutationTestSupport.makeScope(root: root)

        for path in ["", "file/", ".", "..", "folder/.", "folder/..", "a\u{0000}b"] {
            let result = await AgentFileMutationRequestFactory.make(
                generationID: UUID(),
                callID: "invalid-\(UUID().uuidString)",
                logicalSessionID: scope.logicalSessionID,
                writeScope: scope,
                userSuppliedPath: path,
                content: "x",
                providerBinding: AgentFileMutationTestSupport.providerBinding,
                createdAt: AgentFileMutationTestSupport.createdAt
            )
            XCTAssertEqual(result, .failure(.invalidPath), "path \(path.debugDescription) 必须拒绝")
        }
    }

    /// 256 KiB 上限严格按 UTF-8 bytes 而不是 character count 计算。
    func testPayloadLimitAndNoNormalization() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let exact = String(repeating: "a", count: AgentFileMutationLimits.maxPayloadBytes)
        let accepted = try await AgentFileMutationTestSupport.makeRequest(root: root, content: exact)
        XCTAssertEqual(accepted.content, exact)
        XCTAssertEqual(accepted.payloadUTF8, Data(exact.utf8))
        XCTAssertEqual(accepted.payloadIdentity.byteCount, AgentFileMutationLimits.maxPayloadBytes)
        _ = await accepted.parentCapability.invalidate()

        let rejected = await AgentFileMutationRequestFactory.make(
            generationID: UUID(),
            callID: "large",
            logicalSessionID: AgentFileMutationTestSupport.sessionID,
            writeScope: try AgentFileMutationTestSupport.makeScope(root: root),
            userSuppliedPath: "large.txt",
            content: String(repeating: "a", count: AgentFileMutationLimits.maxPayloadBytes + 1),
            providerBinding: AgentFileMutationTestSupport.providerBinding,
            createdAt: AgentFileMutationTestSupport.createdAt
        )
        XCTAssertEqual(rejected, .failure(.payloadTooLarge))
    }

    /// existing regular file、directory 和 symlink 一律是 create-only proposal failure。
    func testExistingTargetKindsAreRejectedWithoutFollowingSymlink() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let existingFile = root.appendingPathComponent("file")
        let existingDirectory = root.appendingPathComponent("directory", isDirectory: true)
        let existingLink = root.appendingPathComponent("link")
        _ = FileManager.default.createFile(atPath: existingFile.path, contents: Data("old".utf8))
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: existingLink.path,
            withDestinationPath: root.appendingPathComponent("missing-target").path
        )

        let scope = try AgentFileMutationTestSupport.makeScope(root: root)
        for path in ["file", "directory", "link"] {
            let result = await AgentFileMutationRequestFactory.make(
                generationID: UUID(),
                callID: "exists-\(path)",
                logicalSessionID: scope.logicalSessionID,
                writeScope: scope,
                userSuppliedPath: path,
                content: "new",
                providerBinding: AgentFileMutationTestSupport.providerBinding,
                createdAt: AgentFileMutationTestSupport.createdAt
            )
            XCTAssertEqual(result, .failure(.destinationAlreadyExists))
        }
        XCTAssertEqual(try String(contentsOf: existingFile), "old")
    }

    /// 缺失 parent、file parent 和 final-parent symlink 各有确定性 failure。
    func testParentFailuresAndFinalParentSymlinkAreRejected() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let parentFile = root.appendingPathComponent("not-a-directory")
        _ = FileManager.default.createFile(atPath: parentFile.path, contents: Data())
        let actualDirectory = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: actualDirectory.path)
        let scope = try AgentFileMutationTestSupport.makeScope(root: root)

        let missing = await AgentFileMutationRequestFactory.make(
            generationID: UUID(), callID: "missing", logicalSessionID: scope.logicalSessionID,
            writeScope: scope, userSuppliedPath: "missing/new.txt", content: "x",
            providerBinding: AgentFileMutationTestSupport.providerBinding, createdAt: AgentFileMutationTestSupport.createdAt
        )
        XCTAssertEqual(missing, .failure(.parentUnavailable))

        let fileParent = await AgentFileMutationRequestFactory.make(
            generationID: UUID(), callID: "file-parent", logicalSessionID: scope.logicalSessionID,
            writeScope: scope, userSuppliedPath: "not-a-directory/new.txt", content: "x",
            providerBinding: AgentFileMutationTestSupport.providerBinding, createdAt: AgentFileMutationTestSupport.createdAt
        )
        XCTAssertEqual(fileParent, .failure(.parentNotDirectory))

        let symlinkParent = await AgentFileMutationRequestFactory.make(
            generationID: UUID(), callID: "symlink-parent", logicalSessionID: scope.logicalSessionID,
            writeScope: scope, userSuppliedPath: "parent-link/new.txt", content: "x",
            providerBinding: AgentFileMutationTestSupport.providerBinding, createdAt: AgentFileMutationTestSupport.createdAt
        )
        XCTAssertEqual(symlinkParent, .failure(.parentSymlinkRejected))
    }

    /// 50 次 rename/replacement 后 capability 均继续指向旧目录 object，绝不按 path 重定向。
    func testParentRenameAndReplacementCannotRetargetCapability() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        for iteration in 0..<50 {
            let parent = root.appendingPathComponent("parent-\(iteration)", isDirectory: true)
            let archived = root.appendingPathComponent("archived-\(iteration)", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let request = try await AgentFileMutationTestSupport.makeRequest(
                root: root,
                path: "parent-\(iteration)/new.txt",
                callID: "replacement-\(iteration)"
            )
            let capturedIdentity = request.targetIdentity.parentCapabilityIdentity

            try FileManager.default.moveItem(at: parent, to: archived)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)

            let identityMatches = await request.parentCapability.stillMatchesCapturedDirectory()
            XCTAssertTrue(identityMatches, "iteration \(iteration) 不得被 replacement retarget")
            XCTAssertEqual(request.targetIdentity.parentCapabilityIdentity, capturedIdentity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: archived.appendingPathComponent("new.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("new.txt").path))
            _ = await request.parentCapability.invalidate()
        }
    }

    /// C1 不保留目标名；目标在 proposal 后出现仅留给 C2 create-only preflight 处理。
    func testLaterTargetCreationDoesNotCreateOrRetargetProposal() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let request = try await AgentFileMutationTestSupport.makeRequest(root: root, path: "appears-later.txt")
        let laterTarget = root.appendingPathComponent("appears-later.txt")

        XCTAssertTrue(FileManager.default.createFile(atPath: laterTarget.path, contents: Data("other-writer".utf8)))
        XCTAssertEqual(try String(contentsOf: laterTarget), "other-writer")
        XCTAssertEqual(request.targetIdentity.basename, "appears-later.txt")
        XCTAssertEqual(request.displayPath, request.proposalWorkingDirectory + "/appears-later.txt")
        _ = await request.parentCapability.invalidate()
    }

    /// capability token 让同一目录的两次 capture 也不会因 raw FD reuse 被误认为同一 authority。
    func testCapabilityIdentityUsesLifetimeTokenInsteadOfRawDescriptorNumber() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let first = try await AgentFileMutationTestSupport.makeRequest(root: root, path: "one.txt")
        let firstIdentity = first.targetIdentity.parentCapabilityIdentity
        _ = await first.parentCapability.invalidate()
        let second = try await AgentFileMutationTestSupport.makeRequest(root: root, path: "two.txt")
        let secondIdentity = second.targetIdentity.parentCapabilityIdentity

        XCTAssertEqual(firstIdentity.deviceID, secondIdentity.deviceID)
        XCTAssertEqual(firstIdentity.inode, secondIdentity.inode)
        XCTAssertNotEqual(firstIdentity.capabilityToken, secondIdentity.capabilityToken)
        _ = await second.parentCapability.invalidate()
    }

    /// 100 次 capture/invalidate 后系统 open-fd 数不得持续增长。
    func testCapabilityLifecycleStressHasNoFDGrowth() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let baseline = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count

        for index in 0..<100 {
            let request = try await AgentFileMutationTestSupport.makeRequest(
                root: root,
                path: "cycle-\(index).txt",
                callID: "cycle-\(index)"
            )
            let initiallyOpen = await request.parentCapability.isOpen()
            let invalidated = await request.parentCapability.invalidate()
            let finallyOpen = await request.parentCapability.isOpen()
            XCTAssertTrue(initiallyOpen)
            XCTAssertTrue(invalidated)
            XCTAssertFalse(finallyOpen)
        }

        let final = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(final, baseline + 1, "100 次 lifecycle 不得累积 FD leak")
    }
}
