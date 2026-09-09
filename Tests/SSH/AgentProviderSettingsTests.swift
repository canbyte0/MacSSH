import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 10C：AgentProviderSettings 测试（任务书 §34）。
///
/// 使用隔离 UserDefaults suite；明确检查 macssh.agent.* 键集合，
/// 证明 API Key 绝不进入 UserDefaults（任务书 §11 hard gate）。
final class AgentProviderSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "macssh.agent.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try? super.tearDown()
    }

    // MARK: - 默认值

    func testLoadWithEmptyDefaultsReturnsProviderDefaults() {
        let settings = AgentProviderSettings.load(from: defaults)
        XCTAssertEqual(settings, AgentProviderSettings.default)
        XCTAssertEqual(settings.provider, .openAI)
        XCTAssertEqual(settings.model, OpenAIResponsesDefaults.model)
        XCTAssertEqual(settings.baseURL, OpenAIResponsesDefaults.baseURL)
    }

    // MARK: - DeepSeek 默认模型（Phase 10C-D-R §4：硬断言 v4-flash）

    func testDeepSeekDefaultModelIsV4Flash() {
        // DeepSeek 当前 Responses API 正式模型；官方 changelog 标记
        // deepseek-chat / deepseek-reasoner 已于 2026-07-24 停用，
        // 绝不得作为 production default。
        XCTAssertEqual(DeepSeekResponsesDefaults.model, "deepseek-v4-flash")
        XCTAssertEqual(AgentProviderSettings.Provider.deepSeek.defaultModel, "deepseek-v4-flash")
        XCTAssertEqual(
            DeepSeekResponsesDefaults.baseURL,
            URL(string: "https://api.deepseek.com")!
        )

        // 旧模型 ID 绝不作为任何 provider 默认值出现。
        XCTAssertNotEqual(DeepSeekResponsesDefaults.model, "deepseek-chat")
        XCTAssertNotEqual(DeepSeekResponsesDefaults.model, "deepseek-reasoner")
        XCTAssertNotEqual(OpenAIResponsesDefaults.model, "deepseek-chat")
    }

    func testFreshDeepSeekLoadWithOnlyProviderKeyUsesV4Flash() {
        // fresh install 路径：只选了 Provider=DeepSeek、未存过 model /
        // baseURL —— load 归一化后必须直接得到可用的 v4-flash 配置。
        defaults.set(
            AgentProviderSettings.Provider.deepSeek.rawValue,
            forKey: AgentProviderSettings.Keys.provider
        )

        let settings = AgentProviderSettings.load(from: defaults)
        XCTAssertEqual(settings.provider, .deepSeek)
        XCTAssertEqual(settings.model, "deepseek-v4-flash")
        XCTAssertEqual(settings.baseURL.absoluteString, "https://api.deepseek.com")
    }

    // MARK: - Provider 切换（Phase 10C-D-R §4：默认跟随 + 自定义保留）

    func testSwitchingFromOpenAIDefaultToDeepSeekUsesV4Flash() {
        // OpenAI 默认值（未自定义）→ 切 DeepSeek：跟随新 provider 默认。
        let switched = AgentProviderSettings.switchingDefaults(
            from: .openAI,
            to: .deepSeek,
            model: AgentProviderSettings.Provider.openAI.defaultModel,
            baseURL: AgentProviderSettings.Provider.openAI.defaultBaseURL
        )
        XCTAssertEqual(switched.model, "deepseek-v4-flash")
        XCTAssertEqual(switched.baseURL.absoluteString, "https://api.deepseek.com")
    }

    func testSwitchingDeepSeekToOpenAIToDeepSeekRoundtrip() {
        // DeepSeek 默认 → OpenAI → DeepSeek：两跳都正确跟随默认值。
        let first = AgentProviderSettings.switchingDefaults(
            from: .deepSeek,
            to: .openAI,
            model: "deepseek-v4-flash",
            baseURL: URL(string: "https://api.deepseek.com")!
        )
        XCTAssertEqual(first.model, OpenAIResponsesDefaults.model)
        XCTAssertEqual(first.baseURL, OpenAIResponsesDefaults.baseURL)

        let second = AgentProviderSettings.switchingDefaults(
            from: .openAI,
            to: .deepSeek,
            model: first.model,
            baseURL: first.baseURL
        )
        XCTAssertEqual(second.model, "deepseek-v4-flash")
        XCTAssertEqual(second.baseURL.absoluteString, "https://api.deepseek.com")
    }

    func testSwitchingPreservesCustomModelAndCustomBaseURL() {
        // 用户自定义值：切 provider 时必须保留，不得静默覆盖。
        let customBaseURL = URL(string: "https://deepseek-proxy.example.com")!
        let switched = AgentProviderSettings.switchingDefaults(
            from: .openAI,
            to: .deepSeek,
            model: "my-custom-model",
            baseURL: customBaseURL
        )
        XCTAssertEqual(switched.model, "my-custom-model")
        XCTAssertEqual(switched.baseURL, customBaseURL)

        // 空白 model 视为未配置 → 跟随新 provider 默认。
        let blankSwitched = AgentProviderSettings.switchingDefaults(
            from: .openAI,
            to: .deepSeek,
            model: "   ",
            baseURL: customBaseURL
        )
        XCTAssertEqual(blankSwitched.model, "deepseek-v4-flash")
    }

    func testStoredLegacyDeepSeekModelValueIsPreservedAsCustom() {
        // Phase 10C-D-R §3：MacSSH 的默认值从未是 deepseek-chat（默认
        // 自始为 deepseek-v4-flash），因此任何已存储的旧模型字符串都与
        // 用户自定义值不可区分——按既有「自定义值保留」规则原样保留，
        // 不做迁移 / 强制覆盖（无法可靠区分即不扩大范围）。
        defaults.set("deepseek-chat", forKey: AgentProviderSettings.Keys.model)
        defaults.set(
            AgentProviderSettings.Provider.deepSeek.rawValue,
            forKey: AgentProviderSettings.Keys.provider
        )

        let settings = AgentProviderSettings.load(from: defaults)
        XCTAssertEqual(settings.model, "deepseek-chat", "存储值按自定义保留，不强制迁移")
        XCTAssertEqual(settings.provider, .deepSeek)
    }

    // MARK: - 持久化（provider / model / base URL）

    func testProviderModelAndBaseURLPersistenceAndReload() {
        let custom = AgentProviderSettings(
            provider: .openAI,
            model: "custom-model-id",
            baseURL: URL(string: "https://example.test/v1")!
        )
        custom.save(to: defaults)

        let reloaded = AgentProviderSettings.load(from: defaults)
        XCTAssertEqual(reloaded, custom)
        XCTAssertEqual(reloaded.provider, .openAI)
        XCTAssertEqual(reloaded.model, "custom-model-id")
        XCTAssertEqual(reloaded.baseURL.absoluteString, "https://example.test/v1")
    }

    func testModelPersistenceTrimsWhitespace() {
        defaults.set("  spaced-model  \n", forKey: AgentProviderSettings.Keys.model)

        let settings = AgentProviderSettings.load(from: defaults)
        XCTAssertEqual(settings.model, "spaced-model")
    }

    // MARK: - 非法值回退（load 侧宽容，UI 保存侧拦截）

    func testInvalidBaseURLFallsBackToDefault() {
        for invalid in ["not a url", "ftp://example.com", "javascript:alert(1)", ""] {
            defaults.set(invalid, forKey: AgentProviderSettings.Keys.baseURL)
            let settings = AgentProviderSettings.load(from: defaults)
            XCTAssertEqual(
                settings.baseURL,
                OpenAIResponsesDefaults.baseURL,
                "非法 Base URL「\(invalid)」必须回退默认"
            )
        }
    }

    func testEmptyModelFallsBackToDefault() {
        defaults.set("   \n\t ", forKey: AgentProviderSettings.Keys.model)

        let settings = AgentProviderSettings.load(from: defaults)
        XCTAssertEqual(settings.model, OpenAIResponsesDefaults.model)
    }

    func testUnknownProviderFallsBackToOpenAI() {
        defaults.set("someFutureProvider", forKey: AgentProviderSettings.Keys.provider)

        let settings = AgentProviderSettings.load(from: defaults)
        XCTAssertEqual(settings.provider, .openAI)
    }

    // MARK: - Base URL 校验器

    func testValidatedBaseURLAcceptsHTTPAndHTTPS() {
        XCTAssertNotNil(AgentProviderSettings.validatedBaseURL(from: "https://api.openai.com/v1"))
        XCTAssertNotNil(AgentProviderSettings.validatedBaseURL(from: "http://localhost:8080/v1"))
        XCTAssertNotNil(AgentProviderSettings.validatedBaseURL(from: "  https://api.openai.com/v1  "))
    }

    func testValidatedBaseURLRejectsInvalidInput() {
        XCTAssertNil(AgentProviderSettings.validatedBaseURL(from: "not a url"))
        XCTAssertNil(AgentProviderSettings.validatedBaseURL(from: "ftp://example.com"))
        XCTAssertNil(AgentProviderSettings.validatedBaseURL(from: "javascript:alert(1)"))
        XCTAssertNil(AgentProviderSettings.validatedBaseURL(from: "https://"))
        XCTAssertNil(AgentProviderSettings.validatedBaseURL(from: ""))
    }

    // MARK: - API Key 绝不进入 UserDefaults（任务书 §11 / §34 hard gate）

    func testSaveNeverWritesAPIKeyIntoUserDefaults() {
        let settings = AgentProviderSettings(
            provider: .openAI,
            model: "custom-model",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        settings.save(to: defaults)

        // macssh.agent.* 键集合必须恰好为 3 个非敏感键。
        let agentKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("macssh.agent") }
            .sorted()
        XCTAssertEqual(
            agentKeys,
            [
                AgentProviderSettings.Keys.baseURL,
                AgentProviderSettings.Keys.model,
                AgentProviderSettings.Keys.provider,
            ].sorted(),
            "macssh.agent.* 只允许 provider / model / baseURL 三个非敏感键"
        )

        // 全 suite 值扫描：任何地方都不得出现 Key 材料。
        for (key, value) in defaults.dictionaryRepresentation() {
            let valueString = String(describing: value)
            XCTAssertFalse(
                valueString.contains("test-api-key"),
                "UserDefaults 键「\(key)」不得包含 API Key 材料"
            )
            XCTAssertFalse(
                valueString.hasPrefix("sk-"),
                "UserDefaults 键「\(key)」不得包含 sk- 前缀 Key"
            )
        }
    }
}
