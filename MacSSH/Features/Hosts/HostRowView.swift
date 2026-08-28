import SwiftUI

/// Host 列表中的原生行，只展示普通元数据，不展示任何凭据。
struct HostRowView: View {
    let host: Host
    let toggleFavorite: () -> Void

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
        }
        .padding(.vertical, 5)
    }
}
