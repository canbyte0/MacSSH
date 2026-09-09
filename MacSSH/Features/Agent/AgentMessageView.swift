import SwiftUI

/// MacSSH 1.1 Phase 10B：单条 Agent 消息行（任务书 §20）。
///
/// macOS 原生、低装饰：
/// - User：右对齐 + 轻微背景卡片；
/// - Agent：左对齐、无气泡；
/// - 结构固定为 role label + content + state，不做 iOS 式大圆角聊天气泡。
struct AgentMessageView: View {
    let message: AgentMessage

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(
            alignment: message.role == .user ? .trailing : .leading,
            spacing: AppTheme.Spacing.compact / 4
        ) {
            Text(verbatim: roleLabel)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            messageContent

            stateView
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.message.\(message.role.accessibilityKey)")
    }

    // MARK: - 内容

    @ViewBuilder
    private var messageContent: some View {
        let text = Text(verbatim: displayContent)
            .font(.system(size: 13))
            .textSelection(.enabled)

        if message.role == .user {
            text
                .padding(.horizontal, AppTheme.Spacing.compact)
                .padding(.vertical, AppTheme.Spacing.compact / 2)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
        } else {
            text
        }
    }

    /// 展示内容：失败且无 partial 内容时按失败分类显示错误文案
    /// （任务书 §20：结构化错误经 localization 映射，不暴露 raw error）。
    private var displayContent: String {
        if message.state == .failed && message.content.isEmpty {
            return failureText
        }
        return message.content
    }

    /// 失败分类 → 本地化文案（agent.provider.error.*，任务书 §36）。
    private var failureText: String {
        switch message.failure {
        case .missingCredential:
            L10n.string(
                "agent.provider.error.missing_credential",
                defaultValue: "AI service is not configured. Add an API Key in Settings.",
                locale: locale
            )
        case .authentication:
            L10n.string(
                "agent.provider.error.authentication",
                defaultValue: "Authentication failed. Check your API Key.",
                locale: locale
            )
        case .forbidden:
            L10n.string(
                "agent.provider.error.forbidden",
                defaultValue: "The AI service rejected the request.",
                locale: locale
            )
        case .rateLimited:
            L10n.string(
                "agent.provider.error.rate_limit",
                defaultValue: "Rate limit reached. Try again later.",
                locale: locale
            )
        case .server:
            L10n.string(
                "agent.provider.error.server",
                defaultValue: "The AI service had a problem. Try again later.",
                locale: locale
            )
        case .network:
            L10n.string(
                "agent.provider.error.network",
                defaultValue: "Network error. Check your connection.",
                locale: locale
            )
        case .invalidResponse:
            L10n.string(
                "agent.provider.error.invalid_response",
                defaultValue: "The AI service returned an unreadable response.",
                locale: locale
            )
        case .incomplete:
            L10n.string(
                "agent.provider.error.incomplete",
                defaultValue: "The response was cut off before completion. Try again or simplify your request.",
                locale: locale
            )
        case .generic, nil:
            L10n.string(
                "agent.error.generic",
                defaultValue: "Unable to generate response.",
                locale: locale
            )
        }
    }

    // MARK: - 状态

    @ViewBuilder
    private var stateView: some View {
        switch message.state {
        case .streaming:
            ProgressView()
                .controlSize(.mini)
        case .failed:
            // 有 partial 内容的失败：内容已展示，此处补一行错误提示。
            if !message.content.isEmpty {
                Text(verbatim: failureText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .complete:
            EmptyView()
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user:
            L10n.string("agent.role.user", defaultValue: "You", locale: locale)
        case .assistant:
            L10n.string("agent.role.assistant", defaultValue: "Agent", locale: locale)
        case .system:
            L10n.string("agent.role.system", defaultValue: "System", locale: locale)
        }
    }
}

private extension AgentMessage.Role {
    /// accessibility identifier 用的语言无关 key。
    var accessibilityKey: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }
}
