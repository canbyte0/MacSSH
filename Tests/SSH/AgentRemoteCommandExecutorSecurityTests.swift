import Darwin
import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B3 §8–§14/§111/§112/§128–§134/§145：授权边界 + 静态安全门。
@MainActor
final class AgentRemoteCommandExecutorSecurityTests: XCTestCase {
    private var fake: AgentRemoteExecFakeLibssh2!
    private var connection: SSHConnection!
    private var coordinator: AgentCommandApprovalCoordinator!
    private var sessionID: UUID!

    override func setUp() async throws {
        fake = AgentRemoteExecFakeLibssh2()
        connection = try await AgentRemoteExecTestSupport.makeFakeSessionConnection(fake: fake)
        coordinator = AgentCommandApprovalCoordinator()
        sessionID = UUID()
    }

    override func tearDown() async throws {
        await connection.disconnect()
        connection = nil
        fake = nil
        coordinator = nil
        sessionID = nil
    }

    // MARK: - helpers

    private func makeExecutor() -> AgentRemoteCommandExecutor {
        AgentRemoteCommandExecutor(
            policy: AgentRemoteExecTestSupport.fastPolicy,
            resolver: AgentRemoteExecTestSupport.makeResolver(mapping: [sessionID: connection])
        )
    }

    private func makeAuthorization(
        command: String = "echo hi",
        sessionID: UUID? = nil,
        target: AgentCommandTarget? = nil
    ) async throws -> AgentCommandExecutionAuthorization {
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            sessionID: sessionID ?? self.sessionID,
            target: target ?? .remote(displayName: "b3-remote"),
            command: command,
            workingDirectory: AgentWorkingDirectory(
                path: AgentRemoteExecTestSupport.remoteWorkingDirectory,
                source: .osc7,
                confidence: .authoritative
            )
        )
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        return try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentCommandClaimExpectations(
                generationID: request.generationID,
                sessionID: request.sessionID,
                providerSnapshotID: request.providerBinding.snapshotID
            )
        )
    }

    // MARK: - §111/§112 零 SSH side effect

    func testForgedAuthorizationProducesZeroSSHSideEffects() async throws {
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            sessionID: sessionID,
            target: .remote(displayName: "b3-remote"),
            command: "echo forged",
            workingDirectory: AgentWorkingDirectory(
                path: AgentRemoteExecTestSupport.remoteWorkingDirectory,
                source: .osc7,
                confidence: .authoritative
            )
        )
        let forged = AgentCommandExecutionAuthorization(
            approvalID: UUID(),
            generationID: request.generationID,
            callID: request.callID,
            sessionID: request.sessionID,
            request: request,
            permit: UUID()
        )
        do {
            _ = try await makeExecutor().execute(
                authorization: forged, approvalCoordinator: coordinator
            )
            XCTFail("§112：伪造 authorization 绝不允许打开 SSH exec channel")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .authorizationRejected(.approvalStale))
        }
        XCTAssertEqual(fake.openCallCount, 0, "§112：channelOpenCount = 0")
        XCTAssertEqual(fake.execRequestCallCount, 0, "§112：execRequestCount = 0")
        XCTAssertEqual(fake.freeCallCount, 0)
    }

    func testReplayedAuthorizationNeverOpensSecondChannel() async throws {
        fake.enqueueStdout(["ok\n"])
        fake.enqueueStdoutRead(.eof)
        fake.enqueueStderr(Array<String>())
        fake.enqueueStderrRead(.eof)
        fake.setExitStatus(0)

        let authorization = try await makeAuthorization(command: "echo ok")
        let executor = makeExecutor()
        let first = try await executor.execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        XCTAssertEqual(first.result.exitCode, 0)
        XCTAssertEqual(fake.openCallCount, 1)

        do {
            _ = try await executor.execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("§113：同一 authorization 绝不允许第二次执行")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .authorizationRejected(.approvalAlreadyClaimed))
        }
        XCTAssertEqual(fake.openCallCount, 1, "§113：第二次尝试 = 0 additional opens")
        XCTAssertEqual(fake.execRequestCallCount, 1)
    }

    func testCrossLedgerAuthorizationProducesZeroSideEffects() async throws {
        let authorization = try await makeAuthorization(command: "echo cross-ledger")
        let otherCoordinator = AgentCommandApprovalCoordinator()
        do {
            _ = try await makeExecutor().execute(
                authorization: authorization, approvalCoordinator: otherCoordinator
            )
            XCTFail("§111：跨 ledger 的 authorization 必须被拒绝")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .authorizationRejected(.approvalStale))
        }
        XCTAssertEqual(fake.openCallCount, 0)
    }

    func testLocalTargetAuthorizationIsRejectedBeforeRedeem() async throws {
        let authorization = try await makeAuthorization(
            command: "echo local",
            target: .local(displayName: "Local")
        )
        do {
            _ = try await makeExecutor().execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("§10：Remote executor 绝不执行 .local target")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .localExecutionUnsupported)
        }
        XCTAssertEqual(fake.openCallCount, 0, "target 校验在 redeem 之前 ⇒ 零 side effect")
        // 未消费授权（仍处于 executionClaimed，未被 redeem）。
        let snapshot = await coordinator.snapshot(approvalID: authorization.approvalID)
        XCTAssertEqual(snapshot?.state, .executionClaimed)
    }

    func testAuthorizationBoundToAnotherSessionNeverExecutesOnThisConnection() async throws {
        let otherSessionID = UUID()
        let authorization = try await makeAuthorization(
            command: "echo other-session",
            sessionID: otherSessionID
        )
        do {
            _ = try await makeExecutor().execute(
                authorization: authorization, approvalCoordinator: coordinator
            )
            XCTFail("§14：非 origin sessionID 必须 sessionUnavailable（绝不 fallback 到可用连接）")
        } catch let error as AgentRemoteCommandExecutionError {
            XCTAssertEqual(error, .sessionUnavailable)
        }
        XCTAssertEqual(fake.openCallCount, 0)
    }

    func testProviderCredentialValuesNeverReachExecPayload() async throws {
        let credentials = [
            "OPENAI_API_KEY": "sk-fake-b3-openai-credential",
            "DEEPSEEK_API_KEY": "dsk-fake-b3-deepseek-credential",
            "GITHUB_TOKEN": "ghp_fake_b3_token",
        ]
        for (key, value) in credentials {
            setenv(key, value, 1)
        }
        defer {
            for key in credentials.keys {
                unsetenv(key)
            }
        }

        fake.enqueueStdout(["done\n"])
        fake.enqueueStdoutRead(.eof)
        fake.enqueueStderr(Array<String>())
        fake.enqueueStderrRead(.eof)
        fake.setExitStatus(0)

        let authorization = try await makeAuthorization(command: "echo done")
        _ = try await makeExecutor().execute(
            authorization: authorization, approvalCoordinator: coordinator
        )
        let payload = try XCTUnwrap(fake.execRequestCommands.first)
        for (key, value) in credentials {
            XCTAssertFalse(payload.contains(value), "\(key) 的值绝不得进入 exec payload")
        }
        XCTAssertEqual(payload, "cd '" + AgentRemoteExecTestSupport.remoteWorkingDirectory + "' || exit $?\necho done")
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
            throw NSError(domain: "AgentRemoteCommandExecutorSecurityTests", code: 1)
        }
        return url
    }

    private func remoteLayerSources() throws -> [(name: String, body: String)] {
        let directory = try repositoryRoot()
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Services", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("Command", isDirectory: true)
            .appendingPathComponent("Execution", isDirectory: true)
            .appendingPathComponent("Remote", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(
            files.map(\.lastPathComponent),
            [
                "AgentRemoteCommandBuilder.swift",
                "AgentRemoteCommandExecutor.swift",
                "AgentRemoteCommandSessionResolver.swift",
            ],
            "Remote 层文件集合必须显式冻结"
        )
        return try files.map {
            (name: $0.lastPathComponent, body: try String(contentsOf: $0, encoding: .utf8))
        }
    }

    // MARK: - §145 静态安全门

    func testRemoteLayerContainsNoCredentialInjectionOrPersistenceTokens() throws {
        let forbidden = [
            "CredentialService", "Keychain", "privateKey", "passphrase",
            "password", "apiKey", "APIKey", "Bearer ",
            "TerminalCommandDispatcher", "pasteText", "send_to_terminal",
            "TerminalView", "localService", "writeChannelInput",
            "FileManager", "URLSession", "SwiftData", "ModelContainer", "UserDefaults",
            "print(", "NSLog", "os_log", "OSLog", "Logger(",
            "run_command",
        ]
        for file in try remoteLayerSources() {
            for token in forbidden {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含禁止 token：\(token)"
                )
            }
        }
    }

    func testExecutorExposesNoRawCommandOrSessionIDEntryPoint() throws {
        let sources = try remoteLayerSources()
        let executor = try XCTUnwrap(
            sources.first { $0.name == "AgentRemoteCommandExecutor.swift" }?.body
        )
        for token in [
            "func execute(command", "func execute(request", "func execute(sessionID",
            "func run(_ command", "func spawn(command",
        ] {
            XCTAssertFalse(executor.contains(token), "不得存在 raw command API：\(token)")
        }

        let declarationStart = try XCTUnwrap(executor.range(of: "func execute("))
        let parameters = executor[declarationStart.upperBound...].prefix { $0 != ")" }
        let parameterText = String(parameters)
        XCTAssertTrue(parameterText.contains("authorization: AgentCommandExecutionAuthorization"))
        XCTAssertTrue(parameterText.contains("approvalCoordinator: AgentCommandApprovalCoordinator"))
        for forbidden in ["command:", "cwd:", "sessionID", "stdin", "timeout", "environment", "connection"] {
            XCTAssertFalse(
                parameterText.contains(forbidden),
                "execute 参数不得包含 caller 提供的 \(forbidden)"
            )
        }
    }

    func testSSHExecLayerStaysDomainNeutral() throws {
        let path = try repositoryRoot()
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Services", isDirectory: true)
            .appendingPathComponent("SSH", isDirectory: true)
            .appendingPathComponent("SSHExecChannel.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        for token in [
            "AgentCommand", "AgentRemoteCommand", "AgentProvider", "OpenAI", "DeepSeek",
            "approvalID", "generationID", "providerSnapshot", "ToolCard", "AgentTool",
        ] {
            XCTAssertFalse(
                source.contains(token),
                "§87/§88：SSH 层必须 transport/domain-neutral（不得含 \(token)）"
            )
        }
        // credential 路径绝不出现在 SSH exec 层。
        for token in ["CredentialService", "Keychain", "passphrase", "password"] {
            XCTAssertFalse(source.contains(token), "SSH exec 层不得含凭据 token：\(token)")
        }
    }

    func testAgentViewModelWiresRemoteExecutorThroughSessionResolver() throws {
        let viewModelURL = try repositoryRoot()
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Services", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("AgentViewModel.swift")
        let source = try String(contentsOf: viewModelURL, encoding: .utf8)
        for token in [
            "AgentRemoteCommandExecutor", "remoteCommandExecutor", "sessionID",
        ] {
            XCTAssertTrue(
                source.contains(token),
                "B4：AgentViewModel 必须接线 Remote executor（token: \(token)）"
            )
        }
    }

    func testProviderBoundaryAdvertisesSevenToolsWithRunCommandAndMutations() {
        XCTAssertEqual(AgentToolCatalog.definitions.count, 7, "10F-C3 后必须恰 7 个定义")
        XCTAssertEqual(
            Set(AgentToolCatalog.names),
            ["get_terminal_context", "get_current_directory", "list_directory",
             "read_file", "run_command", "send_to_terminal", "write_file"]
        )
        XCTAssertFalse(AgentToolCatalog.prohibitedNames.contains("run_command"))
        XCTAssertFalse(AgentToolCatalog.prohibitedNames.contains("send_to_terminal"))
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "run_command", argumentsJSON: #"{"command":"ls"}"#),
            .success(AgentToolCall(.runCommand, arguments: ["command": "ls"]))
        )
    }

    func testStandaloneMutationToolsRemainProhibited() {
        XCTAssertTrue(AgentToolCatalog.names.contains("send_to_terminal"))
        for name in [
            "delete_file", "rename_file", "mkdir", "chmod",
            "pasteText", "execute", "shell", "terminal_send",
        ] {
            XCTAssertTrue(
                AgentToolCatalog.prohibitedNames.contains(name),
                "§133/§134：\(name) 必须仍在禁止名单"
            )
            XCTAssertFalse(AgentToolCatalog.names.contains(name), "\(name) 绝不可注册")
        }
    }

    func testRemoteResultModelHasNoFabricatedLocalSignalOrCredentialFields() {
        let result = AgentRemoteCommandResult(
            result: AgentCommandResult(
                stdout: "x",
                stderr: "",
                exitCode: 1,
                terminationSignal: nil,
                timedOut: false,
                cancelled: false,
                stdoutTruncated: false,
                stderrTruncated: false,
                binaryOutputDetected: false,
                nonUTF8Detected: false,
                duration: .milliseconds(1)
            ),
            termination: .exitSignal(name: "KILL", errorMessage: nil),
            remoteTerminationRequested: true
        )
        let fieldNames = Mirror(reflecting: result).children.compactMap(\.label).sorted()
        XCTAssertEqual(
            fieldNames,
            ["remoteTerminationRequested", "result", "termination"],
            "Remote 结果字段显式冻结"
        )
        XCTAssertNil(result.result.terminationSignal, "§52：Remote 绝不写本地 numeric signal")
    }
}
