import Foundation
import XCTest

@testable import MacSSH

/// Phase 10F-B1 任务书 §5/§18/§29/§30/§41/§42/§44/§45/§52：B1 安全门
/// （10F-B4-S1 / 10F-C3 更新：catalog 恰 7 个，`send_to_terminal` 与
/// `write_file` 已注册、各自严格 schema 形态由 parser 接受；别名 / 其它
/// 文件写工具仍全部禁止）。
///
/// 静态 source gate + Provider 边界 + 执行能力零依赖：
/// - B1 TerminalMutation domain 中：交付 / 注入能力 token = 0；凭据 /
///   持久化 / 信任升级 token = 0；UI 会话解析 fallback = 0；
    /// - Provider tool 注册表 10F-C3 后恰 7 个，别名仍留在禁止集合；
/// - parser 只接受精确 `{text: String, submit: Bool}` 形态。
///
/// Token 列表刻意从严：生产源文件中“提及即视为意图”（含注释），
/// 因此本阶段生产代码注释一律使用转述（如“未来 mutation 工具”）。
final class AgentTerminalMutationSecurityGateTests: XCTestCase {
    // MARK: - 源码定位（与 10E gate 同款 #filePath 反推）

    private func repositoryRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        var url = fileURL
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("MacSSH.xcodeproj").path
        ) else {
            throw NSError(domain: "AgentTerminalMutationSecurityGateTests", code: 1, userInfo: nil)
        }
        return url
    }

    private func terminalMutationSources() throws -> [(name: String, body: String)] {
        let directory = try repositoryRoot()
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Services", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("TerminalMutation", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(
            files.count,
            11,
            "TerminalMutation 生产目录应包含 B1 domain、Local / Remote endpoint/delivery "
                + "与 10F-B4-S1 endpoint capability"
        )
        return try files.map {
            (name: $0.lastPathComponent, body: try String(contentsOf: $0, encoding: .utf8))
        }
    }

    private func b1DomainSources() throws -> [(name: String, body: String)] {
        let names = Set([
            "AgentTerminalInputTargetIdentity.swift",
            "AgentTerminalMutationValidation.swift",
            "AgentTerminalMutationRequest.swift",
            "AgentTerminalMutationApproval.swift",
            "AgentTerminalMutationApprovalCoordinator.swift",
            "AgentTerminalMutationExecutionAuthorization.swift",
        ])
        let sources = try terminalMutationSources().filter { names.contains($0.name) }
        XCTAssertEqual(sources.count, names.count, "B1 domain 文件必须完整存在")
        return sources
    }

    private func localDeliverySources() throws -> [(name: String, body: String)] {
        let names = Set([
            "AgentLocalTerminalMutationEndpoint.swift",
            "AgentLocalTerminalMutationExecutor.swift",
        ])
        let sources = try terminalMutationSources().filter { names.contains($0.name) }
        XCTAssertEqual(sources.count, names.count, "S3 endpoint/delivery 文件必须完整存在")
        return sources
    }

    // MARK: - §5/§18/§52：交付 / 注入能力 = 0

    func testTerminalMutationDomainContainsNoDeliveryCapability() throws {
        // 任何终端字节注入路径的 token 一律禁止（提及即意图）。
        let deliveryTokens = [
            "pasteText", "send(data", "sendReturn", "writeChannelInput",
            "LocalProcess", "TerminalView", "SwiftTerm", "DispatchIO",
            "libssh2_", "channel_write", "CommandHistoryStore", "TerminalCommandDispatcher",
        ]
        for file in try b1DomainSources() {
            for token in deliveryTokens {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含交付 / 注入能力 token: \(token)"
                )
            }
        }
    }

    // MARK: - §56/§58 对齐：凭据 = 0 / 持久化 = 0 / 网络 = 0

    func testTerminalMutationDomainContainsNoCredentialOrPersistenceAccess() throws {
        let forbiddenTokens = [
            "CredentialService", "Keychain", "apiKey", "APIKey", "api_key",
            "authorizationHeader", "Bearer ", "password", "passphrase",
            "privateKey", "UserDefaults", "SwiftData", "ModelContainer",
            "modelContext", "FileManager", "URLSession", "FileHandle",
            "OutputStream", "SSHConnection", "unsafeMutableRawPointer",
        ]
        for file in try b1DomainSources() {
            for token in forbiddenTokens {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含凭据 / 持久化 / 网络 / raw pointer token: \(token)"
                )
            }
        }
    }

    // MARK: - §29/§30：无持久化 / 自动审批概念

    func testTerminalMutationDomainContainsNoPersistentApprovalConcept() throws {
        let forbiddenTokens = [
            "alwaysAllow", "Always Allow", "allowForSession", "Allow for Session",
            "trustTerminal", "Trust Terminal", "trustHost", "Trust Host",
            "allowSimilar", "Allow Similar", "autoApprove", "auto_approve",
            "safeMutation", "safeCommand", "autoApproval",
        ]
        for file in try b1DomainSources() {
            for token in forbiddenTokens {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含持久化 / 自动审批概念 token: \(token)"
                )
            }
        }
    }

    // MARK: - §13/§29 对齐：无 active-tab / 活动会话 fallback

    func testTerminalMutationDomainContainsNoActiveSessionFallback() throws {
        let forbiddenTokens = [
            "activeSession", "SessionManager", "selectedTab", "firstTerminal",
            "matchingHostname", "ActiveInputTarget", "CommandSource",
        ]
        for file in try b1DomainSources() {
            for token in forbiddenTokens {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含活动 tab / 会话解析 fallback token: \(token)"
                )
            }
        }
    }

    // MARK: - §22/§52：authorization 不含目标解析闭包 / I/O 能力

    func testTerminalMutationDomainContainsNoResolutionOrIOCapability() throws {
        let forbiddenTokens = [
            "URLSession", "Process(", "NSTask", "posix_spawn", "system(",
            "popen(", "Task.sleep", "FileHandle", "OutputStream",
        ]
        for file in try b1DomainSources() {
            for token in forbiddenTokens {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含 I/O / 目标解析能力 token: \(token)"
                )
            }
        }
    }

    // MARK: - §44：Provider 工具注册表 gate（10F-C3 后恰 7 个）

    func testCatalogHasExactlySevenToolsWithRegisteredMutationTools() {
        XCTAssertEqual(AgentToolCatalog.definitions.count, 7, "10F-C3 后必须恰 7 个定义")
        XCTAssertEqual(
            Set(AgentToolCatalog.names),
            [
                "get_terminal_context",
                "get_current_directory",
                "list_directory",
                "read_file",
                "run_command",
                "send_to_terminal",
                "write_file",
            ],
            "10F-C3 精确注册 send_to_terminal 与 write_file"
        )
        XCTAssertTrue(AgentToolCatalog.names.contains("send_to_terminal"))
        XCTAssertTrue(AgentToolCatalog.names.contains("write_file"))
    }

    func testMutationAliasesRemainInProhibitedList() {
        // send_to_terminal 与 write_file 已注册；其余别名与未来写工具仍禁止。
        XCTAssertFalse(AgentToolCatalog.prohibitedNames.contains("send_to_terminal"))
        for name in [
            "terminal_send",
            "delete_file", "rename_file", "mkdir", "move", "copy", "chmod", "chown",
        ] {
            XCTAssertTrue(
                AgentToolCatalog.prohibitedNames.contains(name),
                "\(name) 必须保持在禁止集合"
            )
            XCTAssertFalse(AgentToolCatalog.names.contains(name))
        }
    }

    func testParserStrictlyAcceptsOnlyRegisteredMutationToolShape() {
        // §38：精确 {text: String, submit: Bool} 才被接受。
        let validJSON = #"{"text":"echo hi","submit":true}"#
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "send_to_terminal", argumentsJSON: validJSON),
            .success(AgentToolCall(
                name: "send_to_terminal",
                arguments: ["text": "echo hi"],
                terminalMutation: AgentToolTerminalMutationArguments(
                    text: "echo hi",
                    submit: true
                )
            ))
        )
        // C3 的 file tool 是静态注册的，并使用独立的 path/content shape。
        XCTAssertEqual(
            AgentToolCallParsing.parse(name: "write_file", argumentsJSON: #"{"path":"/tmp/x","content":"y"}"#),
            .success(AgentToolCall(
                name: "write_file",
                arguments: ["path": "/tmp/x", "content": "y"]
            ))
        )
    }

    // MARK: - §16：不与 command 审批复用类型

    func testTerminalMutationUsesDedicatedCoordinatorNotCommandCoordinator() throws {
        // domain 内所有类型名必须 terminal-mutation 专属；绝不借用
        // command coordinator 类型实现 mutation 审批。
        for file in try b1DomainSources() {
            XCTAssertFalse(
                file.body.contains("AgentCommandApprovalCoordinator"),
                "\(file.name) 不得引用 command 审批 coordinator 类型"
            )
            XCTAssertFalse(
                file.body.contains("AgentCommandRequest("),
                "\(file.name) 不得构造 command request"
            )
        }
        // 存在专属 coordinator 类型（结构性检查经运行时实例化）。
        _ = AgentTerminalMutationApprovalCoordinator()
    }

    // MARK: - S3 endpoint/delivery source gate

    func testLocalDeliveryUsesOnlyTheExactExclusiveTransportEntry() throws {
        let sources = try localDeliverySources()
        let forbidden = [
            "activeSession", "SessionManager", "selectedTab", "firstTerminal",
            "TerminalCommandDispatcher", "pasteText", "LocalProcess.send",
            "childfd", "Darwin.write", "SSHConnection.writeChannelInput",
        ]
        for file in sources {
            for token in forbidden {
                XCTAssertFalse(
                    file.body.contains(token),
                    "\(file.name) 不得包含动态寻址或旁路写入 token: \(token)"
                )
            }
        }
        let endpoint = sources.first { $0.name == "AgentLocalTerminalMutationEndpoint.swift" }?.body ?? ""
        let executor = sources.first { $0.name == "AgentLocalTerminalMutationExecutor.swift" }?.body ?? ""
        XCTAssertTrue(endpoint.contains("LocalProcessInputTransport"))
        XCTAssertTrue(endpoint.contains("withExclusiveInputTransaction"))
        XCTAssertTrue(executor.contains("withExclusiveInputTransaction"))
    }

    // MARK: - §21/§22：authorization 携带 identity/binding、不含闭包

    func testAuthorizationCarriesBindingOnly() async throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        let coordinator = AgentTerminalMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentTerminalMutationTestSupport.expectations(for: request)
        )
        // 授权只含冻结值：全部字段为 value 类型（无闭包 / 无解析入口）。
        XCTAssertEqual(authorization.generationID, request.generationID)
        XCTAssertEqual(authorization.callID, request.callID)
        XCTAssertEqual(authorization.logicalSessionID, request.logicalSessionID)
        XCTAssertEqual(authorization.targetIdentity, request.targetIdentity)
        XCTAssertEqual(authorization.request, request)
        // description redacted：不含 payload / token / permit。
        XCTAssertFalse(authorization.description.contains(request.text))
        XCTAssertFalse(authorization.description.contains(request.targetIdentity.endpointToken.rawValue.uuidString))
        XCTAssertFalse(authorization.description.contains(authorization.permit.uuidString))
    }

    // MARK: - 10F-B4-S1 §58/§59：Provider 接线安全源码审计

    private func agentSource(named relativePath: String) throws -> String {
        try String(
            contentsOf: try repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testViewModelMutationPathContainsNoLegacyOrExecInjectionTokens() throws {
        let source = try agentSource(
            named: "MacSSH/Services/Agent/AgentViewModel.swift"
        )
        // 正接线断言（§12/§13/§15/§16）。
        for token in [
            "AgentTerminalMutationApprovalCoordinator",
            "AgentTerminalMutationRequestFactory",
            "pendingMutationEndpoints",
            "mutationEndpointProvider",
            "AgentLocalTerminalMutationExecutor",
            "AgentRemoteTerminalMutationExecutor",
            "send_to_terminal",
        ] {
            XCTAssertTrue(source.contains(token), "mutation 接线缺失：\(token)")
        }
        // 负向：绝不复用 legacy / exec / 粘贴通道；绝无 payload 日志（§58/§59）。
        for token in [
            "pasteText", "TerminalCommandDispatcher", "SSHExecChannel",
            "writeChannelInput", "LocalProcess.send(",
            "print(", "NSLog", "os_log", "Logger(",
        ] {
            XCTAssertFalse(
                source.contains(token),
                "AgentViewModel 不得包含 token：\(token)"
            )
        }
        // §13/§14：endpoint 只在 admission 经 mutationEndpointProvider
        // 按 sessionID 冻结一次；绝不延迟到 Approve 之后解析目标。
        XCTAssertTrue(
            source.contains("await mutationEndpointProvider?(sessionID)"),
            "endpoint snapshot 必须发生在 proposal admission"
        )
    }

    func testEndpointCapabilityResolverNeverFallsBackToActiveSession() throws {
        let source = try agentSource(
            named: "MacSSH/Services/Agent/TerminalMutation/AgentTerminalMutationEndpointCapability.swift"
        )
        // 只按显式 sessionID 取回；绝无 active / selected / first fallback，
        // 绝无自动重连，绝无日志。
        for token in [
            "activeSession", "selectedTab", "activeTab", "firstSession",
            "reconnect", "print(", "NSLog", "os_log", "Logger(",
        ] {
            XCTAssertFalse(
                source.contains(token),
                "endpoint resolver 不得包含 token：\(token)"
            )
        }
        XCTAssertTrue(source.contains("forSessionID"))
        XCTAssertTrue(source.contains("agentLocalTerminalMutationEndpoint()"))
        XCTAssertTrue(source.contains("agentRemoteTerminalMutationEndpoint"))
    }

    func testTerminalMutationCardNeverLogsOrEchoesEndpointToken() throws {
        let cardSource = try agentSource(named: "MacSSH/Features/Agent/AgentToolCardView.swift")
        // 卡片只展示 immutable request 的 text / submit / target snapshot；
        // 绝不展示 endpoint token / permit / 原始 argv 等内部身份。
        for token in [
            "endpointToken", "shortDescription", "permit",
            "print(", "NSLog", "os_log", "Logger(",
        ] {
            XCTAssertFalse(
                cardSource.contains(token),
                "mutation 卡片不得包含 token：\(token)"
            )
        }
        XCTAssertTrue(cardSource.contains("mutationRequest"))
        XCTAssertTrue(cardSource.contains("terminalApproveAccessibilityIdentifier"))
        XCTAssertTrue(cardSource.contains("terminalDenyAccessibilityIdentifier"))
    }
}
