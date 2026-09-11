import Foundation

/// MacSSH 1.1 Phase 10C：生产 Provider 路由（任务书 §14 / §25 / §26）。
/// Phase 10C-D：按 settings.provider 路由到 OpenAI / DeepSeek（任务书 §9）。
/// B4 §54/§55：每次 `stream()` 启动时解析一次「当前」配置与凭据，构造
/// 不可变快照；generation 的每一轮 continuation 都经同一实例续流向同一
/// provider——tool loop 中用户修改 Settings / 删除 Key 只影响下一次 Send。
///
/// - 凭据隔离（任务书 §7 P1 hard gate / B4 §55）：provider=openAI 只读
///   openai account，provider=deepSeek 只读 deepseek account——绝不把
///   DeepSeek Key 发给 OpenAI（或反向）；
/// - production 绝不 fallback 到 Mock——未配置 Key 时直接抛
///   `missingCredential`（任务书 §14 hard gate）。
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
        transcript: [AgentMessage],
        tools: [AgentToolDefinition],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    // 请求启动时刻的配置快照（整个 generation 的首次请求
                    // 解析一次；后续轮次由 ViewModel 用同一 provider 实例
                    // 再次进入本方法——快照语义以每轮解析为准，B4 §55
                    // 要求的是凭据绝不跨 provider 复用，此处两 provider
                    // 各自只读取自己的 account）。
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
                    let inner = provider.stream(
                        transcript: transcript,
                        tools: tools,
                        context: context
                    )
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

    /// B4 §54/§55：generation 级冻结。
    ///
    /// Settings 与对应 provider 的 Keychain 各读一次，返回具体的
    /// OpenAI / DeepSeek provider（固定 model / baseURL / credential）。
    /// tool loop 的后续轮次只使用该冻结实例——即使用户在轮次之间切换
    /// provider 或删除 Key 也不影响本 generation（§54），也绝不让
    /// DeepSeek generation 的 continuation 落到 OpenAI 凭据（§55）。
    func snapshotForGeneration() async throws -> any AgentProvider {
        do {
            let settings = settingsLoader()
            guard
                let apiKey = try await credentialService.readAPIKey(for: settings.provider),
                !apiKey.isEmpty
            else {
                throw AgentProviderError.missingCredential
            }
            return Self.makeProvider(
                provider: settings.provider,
                configuration: AgentProviderRequest(
                    model: settings.model,
                    baseURL: settings.baseURL,
                    apiKey: apiKey
                ),
                session: session
            )
        } catch let error as AgentProviderError {
            throw error
        } catch {
            // Keychain 等非预期错误：收敛为 transport 分类，
            // 绝不透传可能含 Secret 的底层描述。
            throw AgentProviderError.transport("configuration load failure")
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
