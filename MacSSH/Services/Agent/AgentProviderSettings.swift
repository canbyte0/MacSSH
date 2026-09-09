import Foundation

/// MacSSH 1.1 Phase 10C：Provider 非敏感配置（任务书 §8 / §10）。
/// Phase 10C-D：Provider 扩展为 OpenAI / DeepSeek 双实现（任务书 §5 / §6）。
///
/// 只含 provider / model / baseURL——**API Key 绝不进入本结构与
/// UserDefaults**（hard gate；由 AgentProviderSettingsTests 断言
/// macssh.agent.* 键集合）。
struct AgentProviderSettings: Sendable, Equatable {
    /// UserDefaults 持久化 rawValue：openai / deepseek（任务书 §5）。
    enum Provider: String, CaseIterable, Sendable, Equatable {
        case openAI = "openai"
        case deepSeek = "deepseek"
    }

    var provider: Provider
    var model: String
    var baseURL: URL
}

extension AgentProviderSettings.Provider {
    /// Settings Picker 显示名 localization key（Phase 10C-D 任务书 §18；
    /// 模式同 AppAppearanceMode.localizedOptionKey）。
    var localizedNameKey: String {
        switch self {
        case .openAI:
            return "agent.settings.provider.openai"
        case .deepSeek:
            return "agent.settings.provider.deepseek"
        }
    }

    /// Provider 默认 model（任务书 §6：集中定义，不得散落 View / 测试）。
    var defaultModel: String {
        switch self {
        case .openAI:
            return OpenAIResponsesDefaults.model
        case .deepSeek:
            return DeepSeekResponsesDefaults.model
        }
    }

    /// Provider 默认 Base URL（任务书 §6）。
    var defaultBaseURL: URL {
        switch self {
        case .openAI:
            return OpenAIResponsesDefaults.baseURL
        case .deepSeek:
            return DeepSeekResponsesDefaults.baseURL
        }
    }
}

extension AgentProviderSettings {
    /// UserDefaults keys（任务书 §8）。
    enum Keys {
        static let provider = "macssh.agent.provider"
        static let model = "macssh.agent.model"
        static let baseURL = "macssh.agent.baseURL"
    }

    /// 默认值集中来自 provider defaults（任务书 §9）。
    static let `default` = AgentProviderSettings(
        provider: .openAI,
        model: AgentProviderSettings.Provider.openAI.defaultModel,
        baseURL: AgentProviderSettings.Provider.openAI.defaultBaseURL
    )

    /// 读取并归一化：缺省 / 非法值回退「当前 provider」的默认值
    /// （非法 Base URL 不抛错——Settings UI 在保存侧拦截，这里保证
    /// provider 永远拿到可用配置）。
    static func load(from defaults: UserDefaults = .standard) -> AgentProviderSettings {
        let provider = Self.provider(from: defaults.string(forKey: Keys.provider))
        let storedModel = defaults.string(forKey: Keys.model)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = storedModel.isEmpty ? provider.defaultModel : storedModel

        let baseURL = defaults.string(forKey: Keys.baseURL)
            .flatMap(validatedBaseURL(from:)) ?? provider.defaultBaseURL

        return AgentProviderSettings(
            provider: provider,
            model: model,
            baseURL: baseURL
        )
    }

    /// Provider 解码：rawValue（openai / deepseek）；未知值（含
    /// Phase 10C candidate 期曾短暂写入的 "openAI" 首字母大写形式）
    /// 回退 OpenAI——与既有持久化行为一致，绝不因此抛错。
    private static func provider(from stored: String?) -> Provider {
        guard let stored else { return .openAI }
        if let provider = Provider(rawValue: stored) {
            return provider
        }
        if stored == "openAI" {
            return .openAI
        }
        return .openAI
    }

    /// 持久化非敏感配置（API Key 不经过本类型）。
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(model, forKey: Keys.model)
        defaults.set(baseURL.absoluteString, forKey: Keys.baseURL)
    }

    /// 智能切换（任务书 §6）：从 `old` 切到 `new` 时计算 model /
    /// baseURL 的目标草稿值——当前值仍为旧 provider 默认值 → 跟随
    /// 新 provider 默认值；已被用户自定义 → 保留原值（不得静默覆盖）。
    /// 切换必须原子持久化（provider 与 baseURL 同步落盘），防止
    /// 「provider 已切、baseURL 仍指向另一服务商」把 Key 发往错误服务器。
    static func switchingDefaults(
        from old: Provider,
        to new: Provider,
        model: String,
        baseURL: URL
    ) -> (model: String, baseURL: URL) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let switchedModel = trimmedModel.isEmpty || trimmedModel == old.defaultModel
            ? new.defaultModel
            : trimmedModel
        let switchedBaseURL = baseURL == old.defaultBaseURL
            ? new.defaultBaseURL
            : baseURL
        return (switchedModel, switchedBaseURL)
    }

    /// Base URL 校验（任务书 §10）：合法 URL、scheme 为 http/https、
    /// 含 host。测试服务器经 URLProtocol 注入，不放宽生产校验。
    static func validatedBaseURL(from string: String) -> URL? {
        guard
            let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else { return nil }
        return url
    }
}
