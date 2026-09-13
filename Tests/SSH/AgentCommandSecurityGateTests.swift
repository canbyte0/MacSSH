import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B1 §48/§49/§50/§51/§52/§53/§54/§55/§56/§58/§97：B1 安全门。
///
/// 静态 source gate + Provider 边界 + 执行能力零依赖：
/// - Command foundation 生产文件中执行 / 注入 / 凭据 / 持久化 token = 0；
/// - `AgentViewModel` 只经 coordinator 接线，不允许 raw executor shortcut；
/// - Provider tool definitions 恰 5 个，只有 run_command 从禁止集合迁移；
/// - parser 严格接受 run_command 的唯一 command 字段。
final class AgentCommandSecurityGateTests: XCTestCase {
    // MARK: - 源码定位（与 LocalizationTests 同款 #filePath 反推）

    private func repositoryRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        // <root>/Tests/SSH/AgentCommandSecurityGateTests.swift → 上溯 3 层。
        var url = fileURL
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("MacSSH.xcodeproj").path
        ) else {
            throw NSError(domain: "AgentCommandSecurityGateTests", code: 1, userInfo: nil)
        }
        return url
    }

    private func commandFoundationSources() throws -> [(name: String, body: String)] {
        let commandDirectory = try repositoryRoot()
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Services", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("Command", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: commandDirectory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 5, "Command foundation 应恰为 5 个文件（无 executor 文件）")
        return try files.map {
            (name: $0.lastPathComponent, body: try String(contentsOf: $0, encoding: .utf8))
        }
    }

    // MARK: - §52/§53/§54/§104：执行 / 注入能力 = 0

    func testCommandFoundationContainsNoExecutionCapability() throws {
        // 真正执行路径 token。注释与代码一并禁止出现——提及即视为意图，
        // gate 从严（§97：new command foundation reachable execution = 0）。
        let executionTokens = [
            "Process(", "NSTask", "posix_spawn", "posix_spawnp", "fork(", "execve",
            "execl", "system(", "popen(", "libssh2_", "channel_exec", "requestExec",
            "TerminalCommandDispatcher", "pasteText", "send(data", "send_to_terminal",
            "startProcess", "launchPath", "executableURL",
        ]
        for file in try commandFoundationSources() {
            for token in executionTokens {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含执行能力 token: \(token)"
                )
            }
        }
    }

    // MARK: - §56/§58：凭据 = 0 / 持久化 = 0

    func testCommandFoundationContainsNoCredentialOrPersistenceAccess() throws {
        let forbiddenTokens = [
            "CredentialService", "Keychain", "apiKey", "APIKey", "api_key",
            "authorizationHeader", "Bearer ", "password", "passphrase",
            "UserDefaults", "SwiftData", "ModelContainer", "modelContext",
            "FileManager", "URLSession", "FileHandle", "OutputStream",
        ]
        for file in try commandFoundationSources() {
            for token in forbiddenTokens {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含凭据 / 持久化 / 网络 token: \(token)"
                )
            }
        }
    }

    // MARK: - B4：Provider 边界精确扩大一项

    func testCatalogHasExactlyFiveToolsWithOneCommandTool() {
        XCTAssertEqual(AgentToolCatalog.definitions.count, 5, "B4 后必须恰 5 个定义")
        XCTAssertEqual(
            Set(AgentToolCatalog.names),
            [
                "get_terminal_context",
                "get_current_directory",
                "list_directory",
                "read_file",
                "run_command",
            ]
        )
    }

    func testRunCommandIsAllowlistedButStandaloneMutationToolsRemainProhibited() {
        XCTAssertFalse(AgentToolCatalog.prohibitedNames.contains("run_command"))
        for name in ["execute", "exec", "shell", "terminal_send", "send_to_terminal",
                     "write_file", "delete_file", "rename_file", "mkdir", "chmod"] {
            XCTAssertTrue(AgentToolCatalog.prohibitedNames.contains(name))
            XCTAssertFalse(AgentToolCatalog.names.contains(name))
        }
    }

    func testParserStrictlyAcceptsOnlyRunCommandCommandField() {
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "run_command", argumentsJSON: #"{"command":"ls"}"#),
            .success(AgentToolCall(.runCommand, arguments: ["command": "ls"]))
        )
        XCTAssertEqual(
            AgentToolCallParsing.parse(
                name: "run_command", argumentsJSON: #"{"command":"ls","cwd":"/tmp"}"#
            ),
            .failure(.invalidArguments)
        )
    }

    // MARK: - B4：AgentViewModel 只经审批链接线

    func testAgentViewModelHasCoordinatorWiringWithoutTerminalInjection() throws {
        let viewModelURL = try repositoryRoot()
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Services", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("AgentViewModel.swift")
        let source = try String(contentsOf: viewModelURL, encoding: .utf8)
        for token in [
            "AgentCommandApprovalCoordinator",
            "AgentCommandRequest",
            "AgentCommandRequestFactory",
            "run_command",
        ] {
            XCTAssertTrue(
                source.contains(token),
                "B4：AgentViewModel 必须包含审批接线（token: \(token)）"
            )
        }
        XCTAssertFalse(source.contains("TerminalCommandDispatcher"))
        XCTAssertFalse(source.contains("send_to_terminal"))
    }

    // MARK: - §29：B1 无任何执行 API（domain 契约）

    func testApprovalFoundationExposesNoExecutionPath() async throws {
        // 结构性证明：pending 状态下 claim 必败——B1 domain 中不存在任何
        // "直接执行"入口，唯一通道是 claim 的原子 CAS（approved 才放行）。
        let coordinator = AgentCommandApprovalCoordinator()
        let request = try AgentCommandTestSupport.makeRequestOrThrow()
        let approvalID = await coordinator.register(request)
        do {
            _ = try await coordinator.claimExecution(
                approvalID: approvalID,
                expected: AgentCommandClaimExpectations(
                    generationID: request.generationID,
                    sessionID: request.sessionID,
                    providerSnapshotID: request.providerBinding.snapshotID
                )
            )
            XCTFail("非 approved 状态不得产出授权（§29：B1 无执行 API）")
        } catch let error as AgentCommandError {
            XCTAssertEqual(error, .approvalNotApproved)
        }
    }
}
