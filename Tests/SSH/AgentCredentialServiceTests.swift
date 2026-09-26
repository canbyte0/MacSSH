import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 10C：AgentCredentialService 测试（任务书 §33）。
/// Phase 10C-D：provider-aware 凭据隔离（任务书 §7 / §11）。
///
/// 使用真实 macOS Keychain，但 service namespace 为每次运行唯一生成的
/// 测试隔离 namespace（不污染生产 `com.macssh.MacSSH.agent`，也不污染
/// SSH `CredentialService` 的 `com.macssh.MacSSH.credentials.*`）。
/// 测试 Key 使用固定假 Key，绝不使用真实 Key（任务书 §32 / §41）。
final class AgentCredentialServiceTests: XCTestCase {

    private var service: AgentCredentialService!
    private var otherNamespaceService: AgentCredentialService!

    override func setUp() {
        super.setUp()
        let namespace = "com.macssh.MacSSH.agent.tests.\(UUID().uuidString.lowercased())"
        service = AgentCredentialService(
            keychainService: KeychainService(queueLabel: "\(namespace).a.queue"),
            serviceNamespace: "\(namespace).a"
        )
        otherNamespaceService = AgentCredentialService(
            keychainService: KeychainService(queueLabel: "\(namespace).b.queue"),
            serviceNamespace: "\(namespace).b"
        )
    }

    override func tearDown() async throws {
        // 失败时也尽力清理两个随机测试 namespace。
        try? await service.deleteAPIKey(for: .openAI)
        try? await service.deleteAPIKey(for: .deepSeek)
        try? await otherNamespaceService.deleteAPIKey(for: .openAI)
        try? await otherNamespaceService.deleteAPIKey(for: .deepSeek)
        service = nil
        otherNamespaceService = nil
        try await super.tearDown()
    }

    // MARK: - save / read

    func testSaveAndReadRoundtrip() async throws {
        try await service.upsertAPIKey("test-api-key", for: .openAI)

        let key = try await service.readAPIKey(for: .openAI)
        XCTAssertEqual(key, "test-api-key")
    }

    // MARK: - update

    func testUpsertReplacesExistingKey() async throws {
        try await service.upsertAPIKey("test-api-key-old", for: .openAI)
        try await service.upsertAPIKey("test-api-key-new", for: .openAI)

        let key = try await service.readAPIKey(for: .openAI)
        XCTAssertEqual(key, "test-api-key-new", "upsert 必须替换旧 Key")
    }

    // MARK: - missing

    func testReadMissingKeyReturnsNil() async throws {
        let key = try await service.readAPIKey(for: .openAI)
        XCTAssertNil(key, "未配置时必须返回 nil（itemNotFound → nil）")
    }

    // MARK: - delete

    func testDeleteRemovesKey() async throws {
        try await service.upsertAPIKey("test-api-key", for: .openAI)
        try await service.deleteAPIKey(for: .openAI)

        let key = try await service.readAPIKey(for: .openAI)
        XCTAssertNil(key)
    }

    func testDeleteIsIdempotentWhenMissing() async throws {
        // 未配置时 delete 不抛错（UI 状态收敛到未配置）。
        try await service.deleteAPIKey(for: .openAI)
        try await service.deleteAPIKey(for: .openAI)
    }

    // MARK: - 空值防御

    func testEmptyKeyIsRejected() async throws {
        do {
            try await service.upsertAPIKey("", for: .openAI)
            XCTFail("空 Key 必须拒绝写入")
        } catch {
            // invalidSecret —— 不允许空 Key 覆盖已有配置。
        }
        let key = try await service.readAPIKey(for: .openAI)
        XCTAssertNil(key, "拒绝后不得残留任何 item")
    }

    // MARK: - provider 隔离（Phase 10C-D 任务书 §7 P1 hard gate）

    func testProviderAccountsAreIsolated() async throws {
        try await service.upsertAPIKey("openai-key", for: .openAI)
        try await service.upsertAPIKey("deepseek-key", for: .deepSeek)

        let openAIKey = try await service.readAPIKey(for: .openAI)
        let deepSeekKey = try await service.readAPIKey(for: .deepSeek)
        XCTAssertEqual(openAIKey, "openai-key")
        XCTAssertEqual(deepSeekKey, "deepseek-key")

        // 删除一个 provider 的 Key 不得波及另一个（§11 hard gate）。
        try await service.deleteAPIKey(for: .deepSeek)
        let openAIKeyAfterDelete = try await service.readAPIKey(for: .openAI)
        XCTAssertEqual(openAIKeyAfterDelete, "openai-key", "删除 deepseek Key 不得影响 openai Key")
        let deepSeekKeyAfterDelete = try await service.readAPIKey(for: .deepSeek)
        XCTAssertNil(deepSeekKeyAfterDelete)
    }

    // MARK: - namespace 隔离（任务书 §11 / §33）

    func testServiceNamespacesAreIsolatedAcrossWriteUpdateAndDelete() async throws {
        try await service.upsertAPIKey("test-api-key-a", for: .openAI)
        let initialA = try await service.readAPIKey(for: .openAI)
        let initialB = try await otherNamespaceService.readAPIKey(for: .openAI)
        XCTAssertEqual(initialA, "test-api-key-a")
        XCTAssertNil(initialB)

        try await otherNamespaceService.upsertAPIKey("test-api-key-b", for: .openAI)
        let afterWriteA = try await service.readAPIKey(for: .openAI)
        let afterWriteB = try await otherNamespaceService.readAPIKey(for: .openAI)
        XCTAssertEqual(afterWriteA, "test-api-key-a")
        XCTAssertEqual(afterWriteB, "test-api-key-b")

        try await service.upsertAPIKey("test-api-key-a-updated", for: .openAI)
        let afterUpdateA = try await service.readAPIKey(for: .openAI)
        let afterUpdateB = try await otherNamespaceService.readAPIKey(for: .openAI)
        XCTAssertEqual(afterUpdateA, "test-api-key-a-updated")
        XCTAssertEqual(afterUpdateB, "test-api-key-b")

        try await service.deleteAPIKey(for: .openAI)
        let afterDeleteA = try await service.readAPIKey(for: .openAI)
        let afterDeleteB = try await otherNamespaceService.readAPIKey(for: .openAI)
        XCTAssertNil(afterDeleteA)
        XCTAssertEqual(afterDeleteB, "test-api-key-b")

        try await otherNamespaceService.deleteAPIKey(for: .openAI)
        let afterDeleteBToo = try await otherNamespaceService.readAPIKey(for: .openAI)
        XCTAssertNil(afterDeleteBToo)
    }

    func testAccountDerivationDoesNotCrash() {
        // account 由 Provider 枚举集中推导（§8：调用方不得手写）——
        // 经读写行为间接验证；此处仅保证构造不崩溃且 service 可用。
        XCTAssertNotNil(service)
    }
}
