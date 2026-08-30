import SwiftUI

/// Host 列表中的原生行，只展示普通元数据与该 Host 的 Terminal Session
/// 聚合状态，不展示任何凭据。
struct HostRowView: View {
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
            .help(host.favorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(host.favorite ? "Remove from Favorites" : "Add to Favorites")

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

                Text(host.group?.name ?? "Ungrouped")
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
            connectButton(label: "Connect", help: "Open a new terminal session on this host")
        }
    }

    private var busyText: String {
        if let statusText = summary.busyStatusText {
            let components = statusText.components(separatedBy: " · ")
            if components.count > 2 {
                return components.dropFirst(2).joined(separator: " · ")
            }
            return statusText
        }
        return "Connecting…"
    }

    private func connectButton(label: String, help: String) -> some View {
        Button(action: connect) {
            Text(label)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityIdentifier("hostRow.connect")
    }

    private func disconnectButton() -> some View {
        Button(action: disconnect) {
            Text("Disconnect")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .help("Close all terminal sessions for this host")
        .accessibilityIdentifier("hostRow.disconnect")
    }

    /// 打开新的 Remote Terminal Session（同 Host 可多开）。
    private var openTerminalButton: some View {
        Button(action: connect) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .help("Open Remote Terminal")
        .accessibilityLabel("Open Remote Terminal")
        .accessibilityIdentifier("hostRow.openTerminal")
    }
}
