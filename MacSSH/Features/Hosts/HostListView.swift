import SwiftData
import SwiftUI

/// Phase 3 Host Manager：直接观察 SwiftData，并提供 Host 与 Group 的原生管理界面。
struct HostListView: View {
    @Environment(\.modelContext) private var modelContext

    /// @Query 让插入、编辑和删除在保存后立即反映到列表。
    @Query(sort: \Host.name) private var hosts: [Host]
    @Query(sort: \HostGroup.name) private var groups: [HostGroup]

    @State private var selectedFilter: HostListFilter? = .all
    @State private var selectedHostID: UUID?
    @State private var searchText = ""
    @State private var hostEditorRequest: HostEditorRequest?
    @State private var groupEditorRequest: HostGroupEditorRequest?
    @State private var hostPendingDeletion: Host?
    @State private var groupPendingDeletion: HostGroup?
    @State private var operationErrorMessage: String?

    var body: some View {
        HSplitView {
            filterSidebar
                .frame(
                    minWidth: AppTheme.Layout.hostSidebarMinimumWidth,
                    idealWidth: AppTheme.Layout.hostSidebarIdealWidth,
                    maxWidth: AppTheme.Layout.hostSidebarMaximumWidth
                )

            hostContent
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Hosts")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Hosts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editSelectedHost()
                } label: {
                    Label("Edit Host", systemImage: "pencil")
                }
                .disabled(selectedHost == nil)
                .help("Edit selected Host")
                .accessibilityIdentifier("hosts.edit")

                Menu {
                    Button {
                        hostEditorRequest = HostEditorRequest(host: nil)
                    } label: {
                        Label("New Host", systemImage: "server.rack")
                    }

                    Button {
                        groupEditorRequest = HostGroupEditorRequest(group: nil)
                    } label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a Host or Group")
                .accessibilityIdentifier("hosts.add")
            }
        }
        .sheet(item: $hostEditorRequest) { request in
            HostEditorView(host: request.host, groups: groups)
        }
        .sheet(item: $groupEditorRequest) { request in
            HostGroupEditorView(group: request.group)
        }
        .alert("Delete Host?", isPresented: hostDeleteAlertBinding) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deletePendingHost()
            }
        } message: {
            Text("This removes the Host metadata from this Mac. No credentials are stored in Phase 3.")
        }
        .alert("Delete Group?", isPresented: groupDeleteAlertBinding) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deletePendingGroup()
            }
        } message: {
            Text("Hosts in this Group will be kept and moved to Ungrouped.")
        }
        .alert("Host Manager Error", isPresented: operationErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationErrorMessage ?? "The operation could not be completed.")
        }
        .accessibilityIdentifier("workspace.hosts")
    }

    /// Host Manager 内部的分类 Sidebar，使用 SwiftData Group 作为真实数据源。
    private var filterSidebar: some View {
        List(selection: $selectedFilter) {
            Section("Hosts") {
                filterRow(
                    title: "Favorites",
                    systemImage: "star.fill",
                    count: hosts.filter(\.favorite).count,
                    filter: .favorites
                )

                filterRow(
                    title: "All Hosts",
                    systemImage: "server.rack",
                    count: hosts.count,
                    filter: .all
                )
            }

            Section("Groups") {
                ForEach(groups) { group in
                    HStack {
                        Label(group.name, systemImage: "folder")
                        Spacer()
                        Text(String(group.hosts.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(HostListFilter.group(group.id))
                    .contextMenu {
                        Button("Rename Group") {
                            groupEditorRequest = HostGroupEditorRequest(group: group)
                        }

                        Divider()

                        Button("Delete Group", role: .destructive) {
                            groupPendingDeletion = group
                        }
                    }
                }

                Button {
                    groupEditorRequest = HostGroupEditorRequest(group: nil)
                } label: {
                    Label("New Group", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hosts.newGroup")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Hosts Sidebar")
    }

    /// 右侧内容区显示当前筛选标题和 Host 列表。
    private var hostContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentFilterTitle)
                        .font(.title2.bold())

                    Text(hostCountDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(AppTheme.Spacing.regular)

            Divider()

            List(selection: $selectedHostID) {
                if filteredHosts.isEmpty {
                    ContentUnavailableView(
                        emptyStateTitle,
                        systemImage: searchText.isEmpty ? "server.rack" : "magnifyingglass",
                        description: Text(emptyStateDescription)
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredHosts) { host in
                        HostRowView(host: host) {
                            toggleFavorite(host)
                        }
                        .tag(host.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            hostEditorRequest = HostEditorRequest(host: host)
                        }
                        .contextMenu {
                            Button("Edit Host") {
                                hostEditorRequest = HostEditorRequest(host: host)
                            }

                            Button(host.favorite ? "Remove from Favorites" : "Add to Favorites") {
                                toggleFavorite(host)
                            }

                            Divider()

                            Button("Delete Host", role: .destructive) {
                                hostPendingDeletion = host
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                if let selectedHost {
                    hostPendingDeletion = selectedHost
                }
            }
        }
    }

    /// 构造带数量的原生筛选行。
    private func filterRow(
        title: String,
        systemImage: String,
        count: Int,
        filter: HostListFilter
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(String(count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(filter)
    }

    /// 先应用 Favorite/Group，再按 Name 或 Hostname 做不区分大小写搜索。
    private var filteredHosts: [Host] {
        hosts.filter { host in
            let matchesFilter: Bool = switch selectedFilter ?? .all {
            case .all:
                true
            case .favorites:
                host.favorite
            case let .group(groupID):
                host.group?.id == groupID
            }

            guard matchesFilter else {
                return false
            }

            let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSearch.isEmpty else {
                return true
            }

            return host.name.localizedStandardContains(trimmedSearch)
                || host.hostname.localizedStandardContains(trimmedSearch)
        }
    }

    private var selectedHost: Host? {
        hosts.first { $0.id == selectedHostID }
    }

    private var currentFilterTitle: String {
        switch selectedFilter ?? .all {
        case .all:
            "All Hosts"
        case .favorites:
            "Favorites"
        case let .group(groupID):
            groups.first { $0.id == groupID }?.name ?? "Group"
        }
    }

    private var hostCountDescription: String {
        let count = filteredHosts.count
        return count == 1 ? "1 Host" : "\(count) Hosts"
    }

    private var emptyStateTitle: String {
        searchText.isEmpty ? "No Hosts" : "No Results"
    }

    private var emptyStateDescription: String {
        if searchText.isEmpty {
            "Add a Host to begin organizing connection metadata."
        } else {
            "No Host name or hostname matches your search."
        }
    }

    private func editSelectedHost() {
        guard let selectedHost else {
            return
        }
        hostEditorRequest = HostEditorRequest(host: selectedHost)
    }

    /// Favorite 是普通 SwiftData 字段；切换后立即显式保存。
    private func toggleFavorite(_ host: Host) {
        host.favorite.toggle()
        host.updatedAt = .now
        saveOperation(successLog: "Host favorite updated", failureMessage: "Favorite could not be updated.")
    }

    private func deletePendingHost() {
        guard let hostPendingDeletion else {
            return
        }

        if selectedHostID == hostPendingDeletion.id {
            selectedHostID = nil
        }

        modelContext.delete(hostPendingDeletion)
        self.hostPendingDeletion = nil
        saveOperation(successLog: "Host deleted", failureMessage: "The Host could not be deleted.")
    }

    private func deletePendingGroup() {
        guard let groupPendingDeletion else {
            return
        }

        if selectedFilter == .group(groupPendingDeletion.id) {
            selectedFilter = .all
        }

        modelContext.delete(groupPendingDeletion)
        self.groupPendingDeletion = nil
        saveOperation(successLog: "Host group deleted", failureMessage: "The Group could not be deleted.")
    }

    /// 所有列表内的轻量修改共用同一保存路径，日志不包含 Host 数据。
    private func saveOperation(successLog: String, failureMessage: String) {
        do {
            try modelContext.save()
            AppLogger.persistence.info("\(successLog, privacy: .public)")
        } catch {
            modelContext.rollback()
            operationErrorMessage = failureMessage
            AppLogger.persistence.error("Host Manager persistence operation failed")
        }
    }

    private var hostDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { hostPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    hostPendingDeletion = nil
                }
            }
        )
    }

    private var groupDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { groupPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    groupPendingDeletion = nil
                }
            }
        )
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    operationErrorMessage = nil
                }
            }
        )
    }
}

/// Host Manager Sidebar 的最小筛选状态，不写入数据库。
private enum HostListFilter: Hashable {
    case favorites
    case all
    case group(UUID)
}

/// 统一驱动创建和编辑 Host 的单个 Sheet。
private struct HostEditorRequest: Identifiable {
    let id: UUID
    let host: Host?

    init(host: Host?) {
        self.host = host
        id = host?.id ?? UUID()
    }
}

/// 统一驱动创建和重命名 Group 的单个 Sheet。
private struct HostGroupEditorRequest: Identifiable {
    let id: UUID
    let group: HostGroup?

    init(group: HostGroup?) {
        self.group = group
        id = group?.id ?? UUID()
    }
}
