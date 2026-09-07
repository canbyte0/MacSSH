import SwiftUI

/// MacSSH 1.1 Phase 10B：Agent 顶部 context header（任务书 §5）。
///
/// - Local：`● Local`（有 OSC 7 cwd 时 `● Local · ~/project`）；
/// - Remote：`● SSH · hostDisplayName`（缺失回落 hostname）；
/// - 无可用 session：`Session unavailable`（Composer 同步禁用，
///   绝不让 Agent UI 看起来还能操作失效 session）。
/// - cwd 只在结构化来源存在时显示，绝不伪造。
struct AgentContextHeaderView: View {
    /// nil = 无可用 active session。
    let context: AgentSessionContext?

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("agent.title")
                .font(.headline)
            targetLine
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .frame(
            maxWidth: .infinity,
            minHeight: AppTheme.Layout.terminalSecondaryBarHeight,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.context.header")
    }

    @ViewBuilder
    private var targetLine: some View {
        if let context {
            HStack(spacing: AppTheme.Spacing.compact / 2) {
                Circle()
                    .fill(Color(nsColor: .systemGreen))
                    .frame(width: 6, height: 6)
                Text(verbatim: targetText(for: context))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text("agent.context.unavailable")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 目标标识：Local（可带 cwd 缩略）/ SSH · host。文案在 View 层按当前
    /// Locale 解析，不缓存。
    private func targetText(for context: AgentSessionContext) -> String {
        switch context.kind {
        case .local:
            let label = L10n.string(
                "agent.context.local",
                defaultValue: "Local",
                locale: locale
            )
            if let directory = context.displayDirectory {
                return "\(label) · \(directory)"
            }
            return label
        case .remoteSSH:
            let label = L10n.string(
                "agent.context.ssh",
                defaultValue: "SSH",
                locale: locale
            )
            return "\(label) · \(context.displayName)"
        }
    }
}
