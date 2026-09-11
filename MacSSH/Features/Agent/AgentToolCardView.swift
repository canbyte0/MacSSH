import SwiftUI

/// B4 §37–§41：Tool Activity UI（read-only 工具自动执行，但每个 tool call
/// 必须有 UI 可见痕迹——privacy hard gate：绝不后台静默读文件并发给
/// Provider）。
///
/// 卡片只展示（§39）：
/// - 工具类型（本地化；未知 / prohibited 名字原样展示并标为"工具调用"）；
/// - 安全的目标信息（用户可理解的 path 或空，§40）；
/// - 状态：running / success / failure / cancelled（§38）。
///
/// 默认不展开完整文件内容 / 终端输出 / 目录列表（§39）。
struct AgentToolCardView: View {
    let activity: AgentToolActivity

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact / 2) {
            Image(systemName: toolIconName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(verbatim: toolLabel)
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            if let target = activity.displayTarget {
                Text(verbatim: target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppTheme.Spacing.compact / 2)

            statusView
        }
        .padding(.horizontal, AppTheme.Spacing.compact)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.tool_card")
        .accessibilityValue(statusKey)
    }

    // MARK: - 状态（§38）

    @ViewBuilder
    private var statusView: some View {
        switch activity.status {
        case .running:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(verbatim: statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .failure:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(verbatim: statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .cancelled:
            Text(verbatim: statusText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusKey: String {
        switch activity.status {
        case .running: return "running"
        case .success: return "success"
        case .failure: return "failure"
        case .cancelled: return "cancelled"
        }
    }

    private var statusText: String {
        switch activity.status {
        case .running:
            L10n.string("agent.tool.status.running", defaultValue: "Running", locale: locale)
        case .success:
            L10n.string("agent.tool.status.success", defaultValue: "Done", locale: locale)
        case .failure:
            L10n.string("agent.tool.status.failure", defaultValue: "Failed", locale: locale)
        case .cancelled:
            L10n.string("agent.tool.status.cancelled", defaultValue: "Cancelled", locale: locale)
        }
    }

    // MARK: - 工具名与图标（§39）

    /// 已知 4 工具 → 本地化名称；未知 / prohibited 名字原样展示原始
    /// 名字（绝不隐藏模型实际请求了什么）。
    private var toolLabel: String {
        switch activity.toolName {
        case AgentToolName.getTerminalContext.rawValue:
            return L10n.string(
                "agent.tool.get_terminal_context",
                defaultValue: "Read terminal context",
                locale: locale
            )
        case AgentToolName.getCurrentDirectory.rawValue:
            return L10n.string(
                "agent.tool.get_current_directory",
                defaultValue: "Get current directory",
                locale: locale
            )
        case AgentToolName.listDirectory.rawValue:
            return L10n.string(
                "agent.tool.list_directory",
                defaultValue: "List directory",
                locale: locale
            )
        case AgentToolName.readFile.rawValue:
            return L10n.string(
                "agent.tool.read_file",
                defaultValue: "Read file",
                locale: locale
            )
        default:
            return activity.toolName
        }
    }

    private var toolIconName: String {
        switch activity.toolName {
        case AgentToolName.getTerminalContext.rawValue:
            return "terminal"
        case AgentToolName.getCurrentDirectory.rawValue:
            return "folder"
        case AgentToolName.listDirectory.rawValue:
            return "list.bullet"
        case AgentToolName.readFile.rawValue:
            return "doc.text"
        default:
            return "wrench.and.screwdriver"
        }
    }
}
