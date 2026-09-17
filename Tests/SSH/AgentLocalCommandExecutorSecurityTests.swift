import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B2 §52–§55/§74/§77–§79/§101–§104/§107：授权边界 + 静态安全门。
final class AgentLocalCommandExecutorSecurityTests: XCTestCase {
    private var workspace: AgentLocalCommandTestWorkspace!

    override func setUpWithError() throws {
        workspace = try AgentLocalCommandTestWorkspace()
    }

    override func tearDownWithError() throws {
        workspace.cleanup()
        workspace = nil
    }

    // MARK: - 源码定位

    private func repositoryRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        var url = fileURL
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("MacSSH.xcodeproj").path
        ) else {
            throw NSError(domain: "AgentLocalCommandExecutorSecurityTests", code: 1)
        }
        return url
    }

    private func executionSources() throws -> [(name: String, body: String)] {
        let directory = try repositoryRoot()
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Services", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("Command", isDirectory: true)
            .appendingPathComponent("Execution", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map {
            (name: $0.lastPathComponent, body: try String(contentsOf: $0, encoding: .utf8))
        }
    }

    // MARK: - §101 执行路径静态门

    func testExecutionLayerContainsOnlyAuthorizedSpawnFamily() throws {
        let sources = try executionSources()
        XCTAssertEqual(
            sources.map(\.name),
            [
                "AgentCommandResult.swift",
                "AgentLocalCommandEnvironment.swift",
                "AgentLocalCommandExecutor.swift",
                "AgentLocalCommandOutputSanitizer.swift",
                "AgentLocalCommandProcess.swift",
            ],
            "Execution 层文件集合必须显式冻结"
        )

        let forbiddenTokens = [
            "NSTask", "Process(", "system(", "popen(", "fork(", "execve", "execl",
            "posix_spawnp", "libssh2_", "channel_exec", "SSHConnection",
            "TerminalCommandDispatcher", "pasteText", "send_to_terminal",
            "LocalProcessTerminalView", "forkpty", "openpty",
            "FileManager", "FileHandle", "OutputStream", "URLSession",
            "Keychain", "CredentialService", "apiKey", "APIKey", "password",
            "passphrase", "Bearer ", "UserDefaults", "SwiftData", "ModelContainer",
            "print(", "NSLog", "os_log", "OSLog", "Logger(",
        ]
        for file in sources {
            for token in forbiddenTokens {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含禁止 token：\(token)"
                )
            }
        }
        // posix_spawn 是 B2 唯一授权的 Local spawn 家族（§12）。
        XCTAssertTrue(
            sources.contains {
                $0.name == "AgentLocalCommandProcess.swift" && $0.body.contains("posix_spawn(")
            },
            "Local spawn 必须是 posix_spawn"
        )
    }

    // MARK: - §103/§107 无 raw command API

    func testExecutorExposesNoRawCommandOrRequestEntryPoint() throws {
        let sources = try executionSources()
        for file in sources {
            for token in [
                "execute(command", "execute(request", "execute(rawCommand",
                "run(command", "spawn(command", "func run(_ command",
            ] {
                XCTAssertFalse(file.body.contains(token), "\(file.name) 不得含 raw command API：\(token)")
            }
        }

        let executor = try XCTUnwrap(
            sources.first { $0.name == "AgentLocalCommandExecutor.swift" }?.body
        )
        let declarationStart = try XCTUnwrap(executor.range(of: "func execute("))
        let parameters = executor[declarationStart.upperBound...].prefix { $0 != ")" }
        let parameterText = String(parameters)
        XCTAssertTrue(parameterText.contains("authorization: AgentCommandExecutionAuthorization"))
        XCTAssertTrue(parameterText.contains("approvalCoordinator: AgentCommandApprovalCoordinator"))
        for forbidden in ["command:", "cwd:", "shell", "timeout", "stdin", "environment"] {
            XCTAssertFalse(
                parameterText.contains(forbidden),
                "§107：execute 参数不得包含 caller 提供的 \(forbidden)"
            )
        }
    }

    // MARK: - §74/§102 零日志 / 零凭据 / 零持久化（gate 已在 §101 覆盖，此处补 result 侧）

    func testResultModelFieldsAreFrozenAndDescriptionIsRedacted() {
        let result = AgentCommandResult(
            stdout: "SECRET-STDOUT-CONTENT",
            stderr: "SECRET-STDERR-CONTENT",
            exitCode: 0,
            terminationSignal: nil,
            timedOut: false,
            cancelled: false,
            stdoutTruncated: false,
            stderrTruncated: false,
            binaryOutputDetected: false,
            nonUTF8Detected: false,
            duration: .milliseconds(5)
        )
        let fieldNames = Mirror(reflecting: result).children.compactMap(\.label).sorted()
        XCTAssertEqual(
            fieldNames,
            [
                "binaryOutputDetected", "cancelled", "duration", "exitCode",
                "nonUTF8Detected", "stderr", "stderrTruncated", "stdout",
                "stdoutTruncated", "terminationSignal", "timedOut",
            ],
            "§36：result 字段集合显式冻结（无 PID / fd / 凭据字段）"
        )
        let rendered = String(describing: result) + String(reflecting: result)
        XCTAssertFalse(rendered.contains("SECRET-STDOUT-CONTENT"))
        XCTAssertFalse(rendered.contains("SECRET-STDERR-CONTENT"))
        XCTAssertTrue(rendered.contains("<redacted>"))
    }

    // MARK: - §53 forged authorization（强 side-effect 证明）

    func testForgedAuthorizationExecutesZeroTimesWithStrongSideEffect() async throws {
        let markerPath = workspace.path("should-not-exist")
        let coordinator = AgentCommandApprovalCoordinator()
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            command: "touch '\(markerPath)'",
            workingDirectory: AgentWorkingDirectory(
                path: workspace.root.path, source: .osc7, confidence: .authoritative
            )
        )
        // 伪造：不存在的 permit（构造控制之外的拼装实例）。
        let forged = AgentCommandExecutionAuthorization(
            approvalID: UUID(),
            generationID: request.generationID,
            callID: request.callID,
            sessionID: request.sessionID,
            request: request,
            permit: UUID()
        )
        let executor = AgentLocalCommandExecutor(policy: AgentLocalCommandTestSupport.fastPolicy)
        do {
            _ = try await executor.execute(authorization: forged, approvalCoordinator: coordinator)
            XCTFail("§53：伪造 authorization 绝不允许 spawn")
        } catch let error as AgentCommandExecutionError {
            XCTAssertEqual(error, .authorizationRejected(.approvalStale))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerPath),
            "§53：伪造授权必须在 spawn 前被 ledger 拒绝（零 side effect）"
        )
    }

    // MARK: - §54/§104 replay / duplicate execution

    func testValidAuthorizationExecutesExactlyOnceThenReplayIsRejected() async throws {
        let markerPath = workspace.path("did-run")
        let coordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: coordinator,
            command: "touch '\(markerPath)'",
            workingDirectory: workspace.root.path
        )
        let executor = AgentLocalCommandExecutor(policy: AgentLocalCommandTestSupport.fastPolicy)

        let first = try await executor.execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(first.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath))

        // 再次执行同一 authorization（复制 struct 语义相同）：spawn 前失败。
        try FileManager.default.removeItem(atPath: markerPath)
        do {
            _ = try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("§104：同一 authorization 绝不允许第二次执行")
        } catch let error as AgentCommandExecutionError {
            XCTAssertEqual(error, .authorizationRejected(.approvalAlreadyClaimed))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerPath),
            "§54：第二次调用不得产生任何 side effect"
        )
    }

    func testAuthorizationFromAnotherLedgerExecutesZeroTimes() async throws {
        let markerPath = workspace.path("cross-ledger")
        let issuingCoordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: issuingCoordinator,
            command: "touch '\(markerPath)'",
            workingDirectory: workspace.root.path
        )
        let otherCoordinator = AgentCommandApprovalCoordinator()
        let executor = AgentLocalCommandExecutor(policy: AgentLocalCommandTestSupport.fastPolicy)
        do {
            _ = try await executor.execute(
                authorization: authorization, approvalCoordinator: otherCoordinator
            )
            XCTFail("§52：跨 ledger 的 authorization 必须被拒绝")
        } catch let error as AgentCommandExecutionError {
            // B1 冻结语义：另一 ledger 不认识该 approvalID → redeem 抛
            // approvalStale（不是 approvalNotFound——那是 register/claim 的语义）。
            XCTAssertEqual(error, .authorizationRejected(.approvalStale))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    // MARK: - §55 remote target

    func testRemoteAuthorizationIsRejectedWithoutSpawn() async throws {
        let markerPath = workspace.path("remote-marker")
        let coordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: coordinator,
            command: "touch '\(markerPath)'",
            workingDirectory: workspace.root.path,
            target: .remote(displayName: "web-01")
        )
        let executor = AgentLocalCommandExecutor(policy: AgentLocalCommandTestSupport.fastPolicy)
        do {
            _ = try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("§11/§55：Local executor 绝不执行 remote target")
        } catch let error as AgentCommandExecutionError {
            XCTAssertEqual(error, .remoteExecutionUnsupported)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
        // remote 拒绝发生在 redeem 之前 → 不消费授权（可稍后由 B3 处理）。
        let snapshot = await coordinator.snapshot(approvalID: authorization.approvalID)
        XCTAssertEqual(snapshot?.state, .executionClaimed)
    }

    // MARK: - §77/§78/§79 provider / view-model 边界

    func testProviderAdvertisesRunCommandOnlyThroughB4Allowlist() {
        // 10F-B4-S1：catalog 精确扩大为 6（+ send_to_terminal，任务书 §40）。
        XCTAssertEqual(AgentToolCatalog.definitions.count, 6)
        XCTAssertTrue(AgentToolCatalog.names.contains("run_command"))
        XCTAssertTrue(AgentToolCatalog.names.contains("send_to_terminal"))
        XCTAssertFalse(AgentToolCatalog.prohibitedNames.contains("run_command"))
        XCTAssertFalse(AgentToolCatalog.prohibitedNames.contains("send_to_terminal"))
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "run_command", argumentsJSON: #"{"command":"ls"}"#),
            .success(AgentToolCall(.runCommand, arguments: ["command": "ls"]))
        )
    }

    func testAgentViewModelUsesExecutorOnlyWithApprovalWiring() throws {
        let viewModelURL = try repositoryRoot()
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Services", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("AgentViewModel.swift")
        let source = try String(contentsOf: viewModelURL, encoding: .utf8)
        for token in ["AgentLocalCommandExecutor", "run_command", "claimExecution"] {
            XCTAssertTrue(
                source.contains(token),
                "B4：AgentViewModel 必须接入审批后的 Local executor（token: \(token)）"
            )
        }
        XCTAssertFalse(source.contains("TerminalCommandDispatcher"))
    }

    // MARK: - §102 fake provider credentials 不进入子进程

    func testFakeProviderCredentialsNeverReachChildEnvironmentOrArgv() async throws {
        let fakeCredentials = [
            "OPENAI_API_KEY": "sk-fake-b2-openai-credential",
            "DEEPSEEK_API_KEY": "dsk-fake-b2-deepseek-credential",
            "AWS_SECRET_ACCESS_KEY": "aws-fake-b2-secret",
            "GITHUB_TOKEN": "ghp-fake-b2-token",
        ]
        for (key, value) in fakeCredentials {
            setenv(key, value, 1)
        }
        defer {
            for key in fakeCredentials.keys {
                unsetenv(key)
            }
        }

        let coordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: coordinator,
            command: "env; ps -ww -o args= -p $$",
            workingDirectory: workspace.root.path
        )
        let executor = AgentLocalCommandExecutor(policy: AgentLocalCommandTestSupport.fastPolicy)
        let result = try await executor.execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(result.exitCode, 0)
        for (key, value) in fakeCredentials {
            XCTAssertFalse(result.stdout.contains(key), "\(key) 不得进入 child env / argv")
            XCTAssertFalse(result.stdout.contains(value))
        }
    }
}
