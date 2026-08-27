import SwiftUI

/// Phase 1 的只读 Hosts Mock 页面；不创建 Host 模型或持久化数据。
struct HostListView: View {
    /// 不包含地址、用户名或凭据的展示数据。
    private let mockHosts = [
        MockHostSummary(id: "favorite-demo", name: "Demo Server", group: "Favorites", isFavorite: true),
        MockHostSummary(id: "work-web", name: "Web Server", group: "Work", isFavorite: false),
        MockHostSummary(id: "personal-nas", name: "Home NAS", group: "Personal", isFavorite: false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            pageHeader

            Divider()

            List {
                Section("Favorites") {
                    ForEach(mockHosts.filter(\.isFavorite)) { host in
                        hostRow(host)
                    }
                }

                Section("Groups") {
                    ForEach(mockHosts.filter { !$0.isFavorite }) { host in
                        hostRow(host)
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Hosts")
        .accessibilityIdentifier("workspace.hosts")
    }

    /// 页面标题明确说明当前数据不可连接或编辑。
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            Text("Hosts")
                .font(.title2.bold())

            Text("Read-only mock hosts for the Phase 1 layout")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.spacious)
    }

    /// 单个 Mock Host 行只展示名称和分组。
    private func hostRow(_ host: MockHostSummary) -> some View {
        HStack(spacing: AppTheme.Spacing.regular) {
            Image(systemName: host.isFavorite ? "star.fill" : "server.rack")
                .foregroundStyle(host.isFavorite ? .yellow : AppTheme.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                Text(host.group)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Mock")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
/// Host Manager 实现前使用的私有展示结构。
private struct MockHostSummary: Identifiable {
    let id: String
    let name: String
    let group: String
    let isFavorite: Bool
}
