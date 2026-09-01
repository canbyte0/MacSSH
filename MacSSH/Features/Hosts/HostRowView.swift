import SwiftUI

/// Host 列表中的原生行，只展示普通元数据与该 Host 的 Terminal Session
/// 聚合状态，不展示任何凭据。
struct HostRowView: View {
    @Environment(\.locale) private var locale

    let host: Host
    /// 该 Host 在 Terminal 侧的聚合会话状态（Phase 8 per-session 连接）。
    let summary: SessionManager.HostSessionSummary
    let toggleFavorite: () -> Void
    /// Connect：创建新的 Remote Terminal Session（同 Host 多会话，任务书 37）。
    let connect: () -> Void
    /// Disconnect：关闭该 Host 的全部 Terminal Session（经确认）。
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.regular) {
            Button(action: toggleFavorite) {
                Image(systemName: host.favorite ? "star.fill" : "star")
                    .foregroundStyle(host.favorite ? .yellow : .secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help(host.favorite ? Text("hosts.remove_favorite") : Text("hosts.add_favorite"))
            .accessibilityLabel(
                host.favorite ? Text("hosts.remove_favorite") : Text("hosts.add_favorite")
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                    .font(.body.weight(.medium))

                Text(host.hostname)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.regular)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(host.username) · \(host.port)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(verbatim: host.group?.name ?? L10n.string(
                    "hosts.ungrouped",
                    defaultValue: "Ungrouped",
                    locale: locale
                ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            connectionStatusView
                .frame(minWidth: 130, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    /// 行尾状态：按该 Host 的 Terminal Session 聚合展示。
    ///
    /// - 活跃会话 > 0：绿点 + Open Terminal（新会话）+ Disconnect；
    /// - 连接中：进度与阶段文案；
    /// - 其他（无会话）：Connect。
    /// 连接失败不再驱动行状态——失败详情保留在 Terminal Tab
    ///（Retry / Close，任务书 38）。
    @ViewBuilder
    private var connectionStatusView: some View {
        if summary.activeSessionCount > 0 {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                openTerminalButton

                disconnectButton()
            }
        } else if summary.busySessionCount > 0 {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(busyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(busyText)
            }
        } else {
            connectButton
        }
    }

    private var busyText: String {
        switch summary.busyDisplayState {
        case .authenticating:
            return L10n.string("status.authenticating", defaultValue: "Authenticating…", locale: locale)
        case .awaitingHostTrust:
            return L10n.string("status.verifying_host", defaultValue: "Verifying Host…", locale: locale)
        case .opening:
            return L10n.string("status.opening", defaultValue: "Opening…", locale: locale)
        case .starting, .connecting:
            return L10n.string("status.connecting", defaultValue: "Connecting…", locale: locale)
        case .active, .exited, .disconnected, .failed, .closing, .none:
            return L10n.string("status.connecting", defaultValue: "Connecting…", locale: locale)
        }
    }

    private var connectButton: some View {
        Button(action: connect) {
            Text("action.connect")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .help("hosts.open_new_terminal_help")
        .accessibilityIdentifier("hostRow.connect")
    }

    private func disconnectButton() -> some View {
        Button(action: disconnect) {
            Text("action.disconnect")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .help("hosts.disconnect_all_help")
        .accessibilityIdentifier("hostRow.disconnect")
    }

    /// 打开新的 Remote Terminal Session（同 Host 可多开）。
    private var openTerminalButton: some View {
        Button(action: connect) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .help("hosts.open_remote_terminal")
        .accessibilityLabel("hosts.open_remote_terminal")
        .accessibilityIdentifier("hostRow.openTerminal")
    }
}
