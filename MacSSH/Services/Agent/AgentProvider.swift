import Foundation

/// MacSSH 1.1 Phase 10C / 10D-B4：Provider 协议（任务书 §11 / §15 / §17 /
/// B4 §3/§19）。
///
/// 只承担「结构化 transcript + 静态 tool definitions + session 上下文 →
/// 流式 AgentEvent」。Vendor JSON 线格式（OpenAI / DeepSeek Responses
/// function tool 布局）由各 provider adapter 收敛，domain 不感知。
protocol AgentProvider: Sendable {
    /// 流式生成回复：
    /// - `textDelta` 增量产出；
    /// - `toolCall` 携带**完整组装**的调用（§11 hard gate：SSE fragment
    ///   拼接只在 provider 内部）；
    /// - `providerItem` 为 opaque continuation item（§22/§23）；
    /// - 正常结束以 `completed` 收尾。
    ///
    /// - Parameters:
    ///   - transcript: 本地结构化会话时间线（user / assistant 文本、
    ///     tool 条目、provider continuation item；§19：每轮完整重建，
    ///     禁止只发最后一条 user message）。
    ///   - tools: generation 固定的 tool definitions（§56 快照）。
    ///   - context: 展示级 session 上下文（system context 消息来源）。
    ///
    /// 消费方取消消费 Task 时，流应尽快终止并取消底层网络工作
    /// （任务书 §19 hard gate）。
    func stream(
        transcript: [AgentMessage],
        tools: [AgentToolDefinition],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error>

    /// 配置就绪状态（任务书 §15）：notConfigured → 侧边栏提示 +
    /// Send 拦截。默认 ready（Mock / 测试 provider 无配置概念）。
    func configurationState() async -> AgentProviderConfigurationState

    /// B4 §54/§55：为单个 generation 冻结 provider 快照。
    ///
    /// 返回的 provider 固定 provider kind / model / baseURL / credential，
    /// 供 tool loop 的**每一轮** continuation 使用——generation 中途用户
    /// 修改 Settings / 删除 Key / 切换 provider 绝不影响本次 generation。
    ///
    /// 默认实现返回 `self`（Mock 与已冻结的具体 provider）。
    /// `ResolvingAgentProvider` 在此完成「Settings + Keychain 各读一次」
    /// 的解析；凭据缺失时抛 `AgentProviderError.missingCredential`。
    func snapshotForGeneration() async throws -> any AgentProvider
}

extension AgentProvider {
    func configurationState() async -> AgentProviderConfigurationState {
        .ready
    }

    func snapshotForGeneration() async throws -> any AgentProvider {
        self
    }
}

/// Provider 配置就绪状态（任务书 §15）。
enum AgentProviderConfigurationState: Sendable, Equatable {
    case ready
    case notConfigured
}
