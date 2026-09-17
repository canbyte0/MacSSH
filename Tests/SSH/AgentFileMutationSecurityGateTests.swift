import Foundation
import XCTest

@testable import MacSSH

/// C1 source and catalog gates：生产 domain 只能捕获/read/fstat directory metadata。
final class AgentFileMutationSecurityGateTests: XCTestCase {
    /// 从 test source 反推 checkout root，避免依赖运行时 cwd。
    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("MacSSH.xcodeproj").path) else {
            throw NSError(domain: "AgentFileMutationSecurityGateTests", code: 1)
        }
        return url
    }

    /// 只读取 C1 的四个 domain/capability source；C2 executor 有意包含
    /// mutation syscall，不能把它误当成 C1 的 no-side-effect gate 对象。
    private func productionSources() throws -> [(name: String, body: String)] {
        let directory = try repositoryRoot()
            .appendingPathComponent("MacSSH/Services/Agent/FileMutation", isDirectory: true)
        let c1Names: Set<String> = [
            "AgentFileMutationModels.swift",
            "AgentLocalFileMutationTargetCapability.swift",
            "AgentFileMutationApproval.swift",
            "AgentFileMutationApprovalCoordinator.swift",
        ]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { c1Names.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 4)
        var sources: [(name: String, body: String)] = []
        for file in files {
            let body = try String(contentsOf: file, encoding: .utf8)
            sources.append((name: file.lastPathComponent, body: body))
        }
        return sources
    }

    /// C2 executor 必须把 side effect 限定在已验证 parent FD 的低层 *at syscall；
    /// 高层文件写入与 overwrite primitive 不得进入 production source。
    private func c2ExecutorSource() throws -> String {
        let file = try repositoryRoot()
            .appendingPathComponent(
                "MacSSH/Services/Agent/FileMutation/AgentLocalFileMutationExecutor.swift"
            )
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// C1 不得提前出现任何 filesystem mutation API；测试允许 capability 的 directory-only open/close/fstat。
    func testProductionSourcesContainNoMutationSyscallOrHighLevelWriteAPI() throws {
        let bannedPatterns = [
            #"\bmkdir\s*\("#, #"\bmkdirat\s*\("#, #"\bcreat\s*\("#,
            #"\bopenat\s*\("#, #"O_CREAT"#, #"\bwrite\s*\("#,
            #"\bpwrite\s*\("#, #"\bftruncate\s*\("#, #"\bfsync\s*\("#,
            #"\brename\s*\("#, #"\brenameat\s*\("#, #"\brenameatx_np\s*\("#,
            #"\blink\s*\("#, #"\blinkat\s*\("#, #"\bunlink\s*\("#,
            #"\bunlinkat\s*\("#, #"\bremove\s*\("#, #"\bchmod\s*\("#,
            #"\bchown\s*\("#, "FileManager.createFile", "Data.write", "String.write"
        ]
        for source in try productionSources() {
            for pattern in bannedPatterns {
                let range = source.body.range(of: pattern, options: .regularExpression)
                XCTAssertNil(range, "\(source.name) 不得包含 C1 mutation token: \(pattern)")
            }
        }
    }

    /// capability 唯一允许的 open 必须是 directory/read-only/no-follow，不能打开 final target。
    func testCapabilityUsesSafeDirectoryOnlyCaptureFlags() throws {
        let sources = try productionSources()
        let capability = try XCTUnwrap(
            sources.first(where: { $0.name == "AgentLocalFileMutationTargetCapability.swift" })?.body
        )
        XCTAssertTrue(capability.contains("O_DIRECTORY"))
        XCTAssertTrue(capability.contains("O_CLOEXEC"))
        XCTAssertTrue(capability.contains("O_NOFOLLOW"))
        XCTAssertFalse(capability.contains("O_CREAT"))
        XCTAssertTrue(capability.contains("AT_SYMLINK_NOFOLLOW"))
    }

    func testC2ExecutorUsesRequiredNoClobberStagingPrimitives() throws {
        let source = try c2ExecutorSource()
        for requiredToken in [
            "mkdirat",
            "openat",
            "O_CREAT",
            "O_EXCL",
            "O_CLOEXEC",
            "O_NOFOLLOW",
            "fsync",
            "renameatx_np",
            "RENAME_EXCL",
            "RENAME_NOFOLLOW_ANY",
            "linkat",
            "unlinkat"
        ] {
            XCTAssertTrue(source.contains(requiredToken), "C2 production source missing \(requiredToken)")
        }

        XCTAssertFalse(source.contains("FileManager.createFile"))
        XCTAssertFalse(source.contains("Data.write"))
        XCTAssertFalse(source.contains("String.write"))
        XCTAssertNil(source.range(of: #"\bO_TRUNC\s*[|,)]"#, options: .regularExpression))
        XCTAssertNil(source.range(of: #"\brename\s*\("#, options: .regularExpression))
        XCTAssertNil(source.range(of: #"\bmkdir\s*\("#, options: .regularExpression))
    }

    /// C3 Provider catalog/tool parser/router 必须注册精确的 7 个工具。
    func testToolCatalogRegistersExactlySevenToolsIncludingFileMutation() {
        XCTAssertEqual(AgentToolCatalog.definitions.count, 7)
        XCTAssertEqual(
            Set(AgentToolCatalog.names),
            ["get_terminal_context", "get_current_directory", "list_directory", "read_file", "run_command", "send_to_terminal", "write_file"]
        )
        XCTAssertFalse(AgentToolCatalog.prohibitedNames.contains("write_file"))
        XCTAssertEqual(AgentToolRegistry.lookup("write_file"), .writeFile)
    }

    /// request/approval/authorization 的默认描述都必须把 path/content/permit 保留为 redacted。
    func testDescriptionsDoNotLogPayloadOrTargetPath() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let secret = "PRIVATE-KEY-CONTENT-DO-NOT-LOG"
        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "super-secret-target.txt",
            content: secret
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )

        for text in [request.description, request.debugDescription, authorization.description, authorization.debugDescription] {
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains("super-secret-target"))
            XCTAssertFalse(text.contains(authorization.permit.uuidString))
        }
        await coordinator.purgeGeneration(request.generationID)
    }
}
