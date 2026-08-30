import SwiftData
import XCTest

@testable import MacSSH

/// Phase 6 Fix：Host Editor 表单校验测试。
///
/// 覆盖阻塞项：Authentication = Private Key 时，
/// `privateKeyPath` 为 nil / 空字符串 / 纯空白都必须阻止保存，
/// 不得生成已知无法连接的 Private Key Host。
@MainActor
final class HostEditorValidationTests: XCTestCase {
    // MARK: - Private Key Path 校验（Phase 6 Fix 阻塞项）

    func test_privateKeyPathNilIsInvalid() {
        XCTAssertFalse(
            HostEditorView.hasValidPrivateKeyPath(nil),
            "privateKeyPath == nil（未选择文件）必须阻止保存"
        )
    }

    func test_privateKeyPathEmptyStringIsInvalid() {
        XCTAssertFalse(
            HostEditorView.hasValidPrivateKeyPath(""),
            "privateKeyPath == \"\" 必须阻止保存"
        )
    }

    func test_privateKeyPathWhitespaceOnlyIsInvalid() {
        XCTAssertFalse(
            HostEditorView.hasValidPrivateKeyPath("   "),
            "纯空白 privateKeyPath 必须视为无效"
        )
        XCTAssertFalse(
            HostEditorView.hasValidPrivateKeyPath(" \n\t "),
            "混合空白字符同样必须视为无效"
        )
    }

    func test_privateKeyPathRealPathIsValid() {
        XCTAssertTrue(HostEditorView.hasValidPrivateKeyPath("/Users/example/.ssh/id_ed25519"))
        // 含空格的真实路径（NSOpenPanel 可能返回）依然有效。
        XCTAssertTrue(HostEditorView.hasValidPrivateKeyPath("/Users/example/My Keys/id_rsa"))
        // 前后带空格的路径：有实际内容，交由连接层做存在性校验。
        XCTAssertTrue(HostEditorView.hasValidPrivateKeyPath(" /Users/example/.ssh/id_ed25519 "))
    }

    // MARK: - SSHService 前置校验（与编辑器同一标准）

    /// Private Key Host 的私钥路径为 nil / 空白时，prepareConnection 必须
    /// 立即产生 rejected(.failed(.privateKeyPathMissing))，不创建 SSH 连接。
    func test_sshServicePrivateKeyHostWithWhitespaceOnlyPathFailsFast() throws {
        for invalidPath in [nil, "", "   "] {
            let container = try makeInMemoryContainer()
            let context = container.mainContext
            let host = Host(
                name: "Phase 6 Fix Whitespace Path",
                hostname: "127.0.0.1",
                port: 22,
                username: NSUserName(),
                authenticationType: .privateKey,
                credentialID: nil,
                privateKeyID: nil,
                privateKeyPath: invalidPath
            )
            context.insert(host)

            let service = SSHService(modelContainer: container)
            let preparation = service.prepareConnection(for: host)

            guard case let .rejected(info) = preparation else {
                XCTFail(
                    "路径 \(invalidPath.debugDescription) 应立即 rejected，实际：\(String(describing: preparation))"
                )
                continue
            }
            guard case let .failed(error) = info.phase else {
                XCTFail(
                    "路径 \(invalidPath.debugDescription) 应立即失败，实际：\(info.phase)"
                )
                continue
            }
            XCTAssertEqual(
                error,
                .privateKeyPathMissing,
                "nil / 空 / 纯空白路径都必须前置失败为 privateKeyPathMissing"
            )
        }
    }

    // MARK: - 辅助

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
