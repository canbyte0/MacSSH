import Foundation

/// MacSSH 1.1 Phase 10C：生产 Provider 路由（任务书 §14 / §25 / §26）。
/// Phase 10C-D：按 settings.provider 路由到 OpenAI / DeepSeek（任务书 §9）。
///
/// 每次 `stream()` 启动时解析一次「当前」配置（UserDefaults Settings 与
/// 对应 provider 的 Keychain API Key 各读一次，任务书 §26），构造不可变
/// `AgentProviderRequest` 委托给具体 provider：
/// - streaming 中修改 Settings / 删除 API Key：当前请求继续使用启动时
///   快照，下一次 Send 才使用新配置（任务书 §25）；
/// - production 绝不 fallback 到 Mock——未配置 Key 时直接抛
///   `missingCredential`（任务书 §14 hard gate）；
/// - 凭据隔离（任务书 §7 P1 hard gate）：provider=openAI 只读 openai
///   account，provider=deepSeek 只读 deepseek account——绝不把
///   DeepSeek Key 发给 OpenAI（或反向）。
struct ResolvingAgentProvider: AgentProvider {
    private let settingsLoader: @Sendable () -> AgentProviderSettings
    private let credentialService: AgentCredentialService
    private let session: URLSession

    init(
        settingsLoader: @escaping @Sendable () -> AgentProviderSettings = {
            AgentProviderSettings.load()
        },
        credentialService: AgentCredentialService = AgentCredentialService(),
        session: URLSession = URLSession(
            configuration: OpenAIResponsesDefaults.makeSessionConfiguration()
        )
    ) {
        self.settingsLoader = settingsLoader
        self.credentialService = credentialService
        self.session = session
    }

    func stream(
        messages: [AgentMessage],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    // 请求启动时刻的配置快照（整个请求生命周期内不变）。
                    let settings = settingsLoader()
                    guard
                        let apiKey = try await credentialService.readAPIKey(
                            for: settings.provider
                        ),
                        !apiKey.isEmpty
                    else {
                        throw AgentProviderError.missingCredential
                    }
                    let provider = Self.makeProvider(
                        provider: settings.provider,
                        configuration: AgentProviderRequest(
                            model: settings.model,
                            baseURL: settings.baseURL,
                            apiKey: apiKey
                        ),
                        session: session
                    )
                    // 委托转发：保持事件顺序与错误类型，传播取消。
                    let inner = provider.stream(messages: messages, context: context)
                    do {
                        for try await event in inner {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch let error as AgentProviderError {
                        continuation.finish(throwing: error)
                    } catch is CancellationError {
                        continuation.finish(throwing: AgentProviderError.cancelled)
                    } catch {
                        continuation.finish(throwing: AgentProviderError.transport("provider relay failure"))
                    }
                } catch let error as AgentProviderError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: AgentProviderError.cancelled)
                } catch {
                    // Keychain 等非预期错误：收敛为 transport 分类，
                    // 绝不透传可能含 Secret 的底层描述。
                    continuation.finish(throwing: AgentProviderError.transport("configuration load failure"))
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    func configurationState() async -> AgentProviderConfigurationState {
        do {
            let provider = settingsLoader().provider
            guard
                let apiKey = try await credentialService.readAPIKey(for: provider),
                !apiKey.isEmpty
            else {
                return .notConfigured
            }
            return .ready
        } catch {
            // Keychain 读取失败：保守视为未配置（不发起请求）。
            return .notConfigured
        }
    }

    /// 按快照 provider 构造具体 provider（任务书 §9）。
    private static func makeProvider(
        provider: AgentProviderSettings.Provider,
        configuration: AgentProviderRequest,
        session: URLSession
    ) -> any AgentProvider {
        switch provider {
        case .openAI:
            return OpenAIResponsesProvider(
                configuration: configuration,
                session: session
            )
        case .deepSeek:
            return DeepSeekResponsesProvider(
                configuration: configuration,
                session: session
            )
        }
    }
}
