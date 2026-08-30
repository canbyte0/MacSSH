import SwiftUI

/// Host 列表中的原生行，只展示普通元数据与连接状态，不展示任何凭据。
struct HostRowView: View {
    let host: Host
    let connectionInfo: SSHConnectionInfo?
    let toggleFavorite: () -> Void
    let connect: () -> Void
    let disconnect: () -> Void
    /// Phase 7：在已认证连接上打开 Remote Terminal。
    let openTerminal: () -> Void

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

    /// 行尾连接状态：真实状态机阶段 + Connect/Disconnect 动作。
    @ViewBuilder
    private var connectionStatusView: some View {
        let phase = connectionInfo?.phase ?? .idle

        switch phase {
        case .idle, .disconnected:
            connectButton(label: "Connect", help: "Connect to this host")

        case .connecting, .handshaking, .awaitingHostTrust, .authenticating:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(phase.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(phase.statusText)
            }

        case .connected:
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                openTerminalButton
                disconnectButton(label: "Connected")
            }

        case .disconnecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Disconnecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                connectButton(label: "Retry", help: failureHelpText)
            }
        }
    }

    private var failureHelpText: String {
        connectionInfo?.failureMessage ?? "The connection failed."
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

    private func disconnectButton(label: String) -> some View {
        Button(action: disconnect) {
            Text(label)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .help("Disconnect from this host")
        .accessibilityIdentifier("hostRow.disconnect")
    }

    /// Phase 7：已认证连接上打开 Remote Terminal（复用连接，不重新认证）。
    private var openTerminalButton: some View {
        Button(action: openTerminal) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .help("Open Remote Terminal")
        .accessibilityLabel("Open Remote Terminal")
        .accessibilityIdentifier("hostRow.openTerminal")
    }
}
