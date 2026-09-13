import Foundation
import XCTest

@testable import MacSSH

/// Phase 10E-B1 §9/§15/§16/§17/§61/§62/§63/§11：request factory 与
/// authoritative cwd 域要求。
final class AgentCommandRequestTests: XCTestCase {
    // MARK: - 合法构造

    func testFactoryProducesImmutableRequestWithAuthoritativeCWD() throws {
        let generationID = UUID()
        let sessionID = UUID()
        let snapshotID = UUID()
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            generationID: generationID,
            sessionID: sessionID,
            command: "echo hi",
            workingDirectory: AgentWorkingDirectory(
                path: "/Users/dev/project",
                source: .osc7,
                confidence: .authoritative
            ),
            snapshotID: snapshotID
        )
        XCTAssertEqual(request.generationID, generationID)
        XCTAssertEqual(request.sessionID, sessionID)
        XCTAssertEqual(request.command, "echo hi")
        XCTAssertEqual(request.workingDirectory, "/Users/dev/project")
        XCTAssertEqual(request.providerBinding.snapshotID, snapshotID)
        // 全部字段 let（编译期 immutable）；此处确认值逐一保真。
        XCTAssertEqual(request.callID, "call_test_1")
    }

    func testFactoryPreservesRemoteTargetMetadata() throws {
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            target: .remote(displayName: "web-01"),
            command: "ls"
        )
        XCTAssertEqual(request.target, .remote(displayName: "web-01"))
    }

    // MARK: - cwd 权威性（§16/§62/§63：绝不 fallback）

    func testApproximateCWDIsRejectedWithCWDUnavailable() {
        let result = AgentCommandRequestFactory.make(
            generationID: UUID(),
            callID: "call_1",
            sessionID: UUID(),
            target: .local(displayName: "Local"),
            command: "echo hi",
            workingDirectory: .sessionDefault(path: "/tmp/project"),
            providerBinding: AgentCommandTestSupport.makeBinding()
        )
        XCTAssertEqual(result, .failure(.cwdUnavailable))
    }

    func testUnavailableCWDIsRejectedWithCWDUnavailable() {
        let result = AgentCommandRequestFactory.make(
            generationID: UUID(),
            callID: "call_1",
            sessionID: UUID(),
            target: .remote(displayName: "web-01"),
            command: "echo hi",
            workingDirectory: .unavailable,
            providerBinding: AgentCommandTestSupport.makeBinding()
        )
        XCTAssertEqual(result, .failure(.cwdUnavailable))
    }

    func testRelativeCWDIsRejectedEvenIfAuthoritative() {
        // 权威但非绝对路径（防御性）：一样拒绝（§62 path 必须 absolute）。
        let result = AgentCommandRequestFactory.make(
            generationID: UUID(),
            callID: "call_1",
            sessionID: UUID(),
            target: .local(displayName: "Local"),
            command: "echo hi",
            workingDirectory: AgentWorkingDirectory(
                path: "relative/dir",
                source: .osc7,
                confidence: .authoritative
            ),
            providerBinding: AgentCommandTestSupport.makeBinding()
        )
        XCTAssertEqual(result, .failure(.cwdUnavailable))
    }

    func testEmptyPathAuthoritativeCWDIsRejected() {
        let result = AgentCommandRequestFactory.make(
            generationID: UUID(),
            callID: "call_1",
            sessionID: UUID(),
            target: .local(displayName: "Local"),
            command: "echo hi",
            workingDirectory: AgentWorkingDirectory(
                path: "",
                source: .osc7,
                confidence: .authoritative
            ),
            providerBinding: AgentCommandTestSupport.makeBinding()
        )
        XCTAssertEqual(result, .failure(.cwdUnavailable))
    }

    func testLocalAndRemoteTargetsShareSameCWDRequirement() {
        // §63：两种 target 使用同一域要求——approximate cwd 对 Remote
        // 同样拒绝（sessionDefault 绝不进入 command request）。
        for target in [AgentCommandTarget.local(displayName: "Local"), .remote(displayName: "R")] {
            let result = AgentCommandRequestFactory.make(
                generationID: UUID(),
                callID: "call_1",
                sessionID: UUID(),
                target: target,
                command: "echo hi",
                workingDirectory: .sessionDefault(path: "/tmp"),
                providerBinding: AgentCommandTestSupport.makeBinding()
            )
            XCTAssertEqual(result, .failure(.cwdUnavailable))
        }
    }

    // MARK: - command 校验经 factory（§13 委托）

    func testFactoryRejectsInvalidCommands() {
        for command in ["", "   \n\t ", "echo\u{0000}x", String(repeating: "a", count: 16_385)] {
            let result = AgentCommandRequestFactory.make(
                generationID: UUID(),
                callID: "call_1",
                sessionID: UUID(),
                target: .local(displayName: "Local"),
                command: command,
                workingDirectory: AgentCommandTestSupport.makeAuthoritativeCWD(),
                providerBinding: AgentCommandTestSupport.makeBinding()
            )
            XCTAssertNotEqual(
                try? result.get().command, command,
                "非法 command 不得产出 request"
            )
        }
    }

    // MARK: - Provider binding（§11：无 credential 字段）

    func testProviderBindingCarriesNoCredentialFields() throws {
        let binding = AgentCommandTestSupport.makeBinding()
        // 结构只有 snapshotID / provider / model / baseURL 四个非敏感字段；
        // snapshotID 是 opaque identity。反射断言字段集合恒定（防止未来
        // 意外加入 credential 字段）。
        let mirror = Mirror(reflecting: binding)
        let fieldNames = mirror.children.compactMap(\.label).sorted()
        XCTAssertEqual(fieldNames, ["baseURL", "model", "provider", "snapshotID"])
    }

    func testProviderBindingEqualityIgnoresNothingSecret() throws {
        // provider / model / baseURL 全部非敏感（与 AgentProviderSettings
        // 同语义）；两个不同 snapshotID 的 binding 不相等。
        let a = AgentCommandTestSupport.makeBinding()
        let b = AgentCommandProviderBinding(
            snapshotID: UUID(),
            provider: .openAI,
            model: "test-model",
            baseURL: URL(string: "https://example.invalid/v1")!
        )
        XCTAssertNotEqual(a.snapshotID, b.snapshotID)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - 红acted 描述（§57 零内容日志）

    func testRequestDescriptionNeverContainsCommandOrCWD() throws {
        let secretCommand = "cat ~/.ssh/id_rsa && echo SECRET-TOKEN-XYZ"
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            command: secretCommand,
            workingDirectory: AgentWorkingDirectory(
                path: "/private/secret/cwd",
                source: .osc7,
                confidence: .authoritative
            )
        )
        let description = String(describing: request)
        let debugDescription = String(reflecting: request)
        for rendered in [description, debugDescription] {
            XCTAssertFalse(rendered.contains(secretCommand), "description 绝不泄漏 command")
            XCTAssertFalse(rendered.contains("SECRET-TOKEN-XYZ"))
            XCTAssertFalse(rendered.contains("/private/secret/cwd"), "description 绝不泄漏 cwd")
        }
    }
}

extension AgentCommandTestSupport {
    static func makeAuthoritativeCWD() -> AgentWorkingDirectory {
        AgentWorkingDirectory(path: "/tmp/project", source: .osc7, confidence: .authoritative)
    }

    static func makeBinding(snapshotID: UUID = UUID()) -> AgentCommandProviderBinding {
        AgentCommandProviderBinding(
            snapshotID: snapshotID,
            provider: .openAI,
            model: "test-model",
            baseURL: URL(string: "https://example.invalid/v1")!
        )
    }
}
