import Foundation
import XCTest

@testable import MacSSH

/// Phase 10F-B1 任务书 §7/§8/§9/§10/§11/§12/§13/§20/§28：request 模型、
/// incarnation 身份契约与 factory 构造边界。
final class AgentTerminalMutationRequestTests: XCTestCase {
    // MARK: - Incarnation 身份契约（§9/§10/§11/§50）

    func testTargetIdentityBindsSessionEpochAndToken() {
        let identity = AgentTerminalMutationTestSupport.makeIdentity()
        XCTAssertEqual(identity.logicalSessionID, AgentTerminalMutationTestSupport.sessionID)
        XCTAssertEqual(identity.inputTargetEpoch, 7)
        XCTAssertNotEqual(
            identity,
            AgentTerminalInputTargetIdentity(
                logicalSessionID: identity.logicalSessionID,
                inputTargetEpoch: 8,
                endpointToken: identity.endpointToken
            ),
            "epoch 变化必须产生不同身份"
        )
        XCTAssertNotEqual(
            identity,
            AgentTerminalInputTargetIdentity(
                logicalSessionID: identity.logicalSessionID,
                inputTargetEpoch: identity.inputTargetEpoch,
                endpointToken: AgentTerminalEndpointToken.generate()
            ),
            "token 变化必须产生不同身份"
        )
    }

    func testEndpointTokenIsOpaqueNonSecretAppGenerated() {
        let token = AgentTerminalEndpointToken.generate()
        // UUID-style、非 secret、应用生成；诊断只暴露短前缀。
        XCTAssertEqual(token.shortDescription.count, 8)
        XCTAssertTrue(token.shortDescription.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(token, AgentTerminalEndpointToken.generate())
        // Hashable / Equatable 可用于确定性绑定。
        let same = AgentTerminalEndpointToken(rawValue: token.rawValue)
        XCTAssertEqual(token, same)
        XCTAssertEqual(token.hashValue, same.hashValue)
    }

    // MARK: - Request immutable / Equatable（§8/§20）

    func testRequestIsImmutableValueBindingAllFrozenFields() throws {
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        XCTAssertEqual(request.generationID, AgentTerminalMutationTestSupport.generationID)
        XCTAssertEqual(request.callID, "call-1")
        XCTAssertEqual(request.logicalSessionID, AgentTerminalMutationTestSupport.sessionID)
        XCTAssertEqual(request.targetIdentity.logicalSessionID, request.logicalSessionID)
        XCTAssertEqual(request.text, "echo hi")
        XCTAssertEqual(request.submit, true)
        XCTAssertEqual(
            request.providerBinding.snapshotID,
            AgentTerminalMutationTestSupport.providerSnapshotID
        )
        XCTAssertEqual(request.createdAt, AgentTerminalMutationTestSupport.createdAt)
        // immutable value object：全部字段为 let，值相等即结构相等。
        let copy = try AgentTerminalMutationTestSupport.makeRequestOrThrow()
        XCTAssertEqual(request, copy)
        // text / submit 任一不同 → 不同 request（§27/§28 绑定基础）。
        let differentSubmit = try AgentTerminalMutationTestSupport.makeRequestOrThrow(submit: false)
        XCTAssertNotEqual(request, differentSubmit)
        let differentText = try AgentTerminalMutationTestSupport.makeRequestOrThrow(text: "echo hai")
        XCTAssertNotEqual(request, differentText)
    }

    // MARK: - Factory 校验（§14）

    func testFactoryRejectsInvalidPayloads() {
        let base: (String) -> Result<AgentTerminalMutationRequest, AgentTerminalMutationError> = { text in
            AgentTerminalMutationRequestFactory.make(
                generationID: AgentTerminalMutationTestSupport.generationID,
                callID: "call-1",
                logicalSessionID: AgentTerminalMutationTestSupport.sessionID,
                targetIdentity: AgentTerminalMutationTestSupport.makeIdentity(),
                targetSnapshot: .local,
                text: text,
                submit: true,
                providerBinding: AgentTerminalMutationTestSupport.providerBinding,
                createdAt: AgentTerminalMutationTestSupport.createdAt
            )
        }
        XCTAssertEqual(base(""), .failure(.invalidArguments))
        XCTAssertEqual(
            base(String(repeating: "a", count: 65_537)),
            .failure(.payloadTooLarge)
        )
        XCTAssertEqual(base("a\u{0000}"), .failure(.forbiddenControlCharacter))
        XCTAssertEqual(base("a\u{000D}"), .failure(.forbiddenControlCharacter))
        XCTAssertEqual(base("a\u{001B}"), .failure(.forbiddenControlCharacter))
    }

    func testFactoryRejectsSessionIdentityMismatch() {
        let otherSession = UUID()
        XCTAssertEqual(
            AgentTerminalMutationRequestFactory.make(
                generationID: AgentTerminalMutationTestSupport.generationID,
                callID: "call-1",
                logicalSessionID: otherSession,
                targetIdentity: AgentTerminalMutationTestSupport.makeIdentity(
                    sessionID: AgentTerminalMutationTestSupport.sessionID
                ),
                targetSnapshot: .local,
                text: "echo hi",
                submit: true,
                providerBinding: AgentTerminalMutationTestSupport.providerBinding,
                createdAt: AgentTerminalMutationTestSupport.createdAt
            ),
            .failure(.invalidArguments),
            "顶层 session 与 identity 内 session 不一致 = 构造矛盾，拒绝"
        )
    }

    // MARK: - Provider 边界（§12：模型只控制 text/submit）

    func testProviderControlsOnlyTextAndSubmitInFactorySurface() throws {
        // factory 的 Provider 可控参数位只有 text / submit；session /
        // epoch / token / generation / provider snapshot 全部是应用侧
        // 冻结值的类型化参数（token 只能经 AgentTerminalEndpointToken
        // 传入，Provider 无法以字符串 / 指针形态提供）。
        _ = try AgentTerminalMutationTestSupport.makeRequestOrThrow(text: "x", submit: false)
        _ = try AgentTerminalMutationTestSupport.makeRequestOrThrow(text: "x", submit: true)
    }

    // MARK: - Redaction（§32/§62）

    func testRequestDescriptionNeverContainsPayloadOrHostOrToken() throws {
        let secretText = "echo SUPER-SECRET-PAYLOAD-XYZ && export TOKEN=abc"
        let request = try AgentTerminalMutationTestSupport.makeRequestOrThrow(
            targetSnapshot: .remote(hostDisplay: "secret-host.example.internal"),
            text: secretText,
            submit: false
        )
        for rendered in [request.description, request.debugDescription] {
            XCTAssertFalse(rendered.contains(secretText), "description 绝不含 payload")
            XCTAssertFalse(rendered.contains("SUPER-SECRET"), "description 绝不含 payload 片段")
            XCTAssertFalse(rendered.contains("secret-host"), "description 绝不含 host display")
            XCTAssertFalse(
                rendered.contains(request.targetIdentity.endpointToken.rawValue.uuidString),
                "description 绝不含完整 token"
            )
            XCTAssertTrue(rendered.contains("payloadBytes"), "只允许字节计数诊断")
        }
    }
}
