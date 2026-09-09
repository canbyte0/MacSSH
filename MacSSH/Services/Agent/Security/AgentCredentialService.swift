import Foundation

/// MacSSH 1.1 Phase 10C：Agent API Key 的 Keychain 存取（任务书 §11 / §13）。
/// Phase 10C-D：provider-aware 凭据隔离（任务书 §7 / §8 / §11）。
///
/// 独立 service namespace `com.macssh.MacSSH.agent`，account 按 provider
/// 隔离（`openai` / `deepseek`）——与 SSH `CredentialService`
/// （`com.macssh.MacSSH.credentials.*`）完全隔离，互不可见、互不污染。
///
/// 凭据隔离 hard gate（任务书 §7 P1）：provider=openAI 只读写 openai
/// account，provider=deepSeek 只读写 deepseek account——绝不能拿
/// OpenAI Key 发给 DeepSeek（或反向）。account 字符串由本服务从
/// Provider 枚举推导，View / 调用方不得手写（任务书 §8）。
///
/// 日志边界：只记录生命周期事件，绝不记录 Key 本体。
struct AgentCredentialService: Sendable {
    /// Keychain service namespace（测试注入独立 namespace）。
    private let serviceNamespace: String

    private let keychainService: KeychainService

    init(
        keychainService: KeychainService = KeychainService(
            queueLabel: "com.macssh.MacSSH.keychain.agent"
        ),
        serviceNamespace: String = "com.macssh.MacSSH.agent"
    ) {
        self.keychainService = keychainService
        self.serviceNamespace = serviceNamespace
    }

    /// 保存 / 替换指定 provider 的 API Key（UTF-8；空 Key 抛 invalidSecret）。
    func upsertAPIKey(
        _ key: String,
        for provider: AgentProviderSettings.Provider
    ) async throws {
        let data = try Self.encoded(key)
        try await keychainService.upsert(
            data,
            service: serviceNamespace,
            account: Self.account(for: provider)
        )
        AppLogger.security.info("Agent API key upserted")
    }

    /// 读取指定 provider 的 API Key；未配置（itemNotFound）返回 nil。
    /// 只在构造 provider request 时调用，不长期存入 AppState /
    /// Conversation / UserDefaults。
    func readAPIKey(
        for provider: AgentProviderSettings.Provider
    ) async throws -> String? {
        do {
            let data = try await keychainService.read(
                service: serviceNamespace,
                account: Self.account(for: provider)
            )
            guard let key = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return key
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    /// 删除指定 provider 的 API Key（幂等：未配置时视为成功，UI 状态
    /// 收敛到未配置）。只删除该 provider 自己的 account，绝不波及其他
    /// provider 的凭据（任务书 §11 hard gate）。
    func deleteAPIKey(
        for provider: AgentProviderSettings.Provider
    ) async throws {
        do {
            try await keychainService.delete(
                service: serviceNamespace,
                account: Self.account(for: provider)
            )
        } catch KeychainError.itemNotFound {
            return
        }
        AppLogger.security.info("Agent API key deleted")
    }

    /// account 由 Provider 枚举集中推导（任务书 §8：调用方不得手写）。
    private static func account(
        for provider: AgentProviderSettings.Provider
    ) -> String {
        switch provider {
        case .openAI:
            return "openai"
        case .deepSeek:
            return "deepseek"
        }
    }

    /// String 仅在调用期间转换为 Data；空 Key 拒绝写入。
    private static func encoded(_ key: String) throws -> Data {
        guard !key.isEmpty else {
            throw KeychainError.invalidSecret
        }
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        return data
    }
}
