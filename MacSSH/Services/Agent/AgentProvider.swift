import Foundation

/// MacSSH 1.1 Phase 10C：Provider 协议（任务书 §11 / §15 / §17）。
///
/// 只承担「消息历史 + session 上下文 → 流式 AgentEvent」。
/// 不定义 tool definitions / function calling schema / vendor JSON——
/// 避免后续 Phase 的 provider lock-in。
protocol AgentProvider: Sendable {
    /// 流式生成回复：增量产出 `textDelta`，正常结束以 `completed` 收尾。
    /// 消费方取消消费 Task 时，流应尽快终止并取消底层网络工作
    /// （任务书 §19 hard gate：禁止 UI 已 Stop 但 HTTP 仍在后台收 token）。
    func stream(
        messages: [AgentMessage],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error>

    /// 配置就绪状态（任务书 §15）：notConfigured → 侧边栏提示 +
    /// Send 拦截。默认 ready（Mock / 测试 provider 无配置概念）。
    func configurationState() async -> AgentProviderConfigurationState
}

extension AgentProvider {
    func configurationState() async -> AgentProviderConfigurationState {
        .ready
    }
}

/// Provider 配置就绪状态（任务书 §15）。
enum AgentProviderConfigurationState: Sendable, Equatable {
    case ready
    case notConfigured
}
