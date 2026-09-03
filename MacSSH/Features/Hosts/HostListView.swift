import SwiftData
import SwiftUI

/// Host Manager 直接观察 SwiftData，并在删除 Host 时同步清理 Keychain 凭据。
/// Phase 8 起 Connect / Open Terminal 直接创建 Remote Terminal Session
///（per-session 连接，由 SessionManager 管理）。
struct HostListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Environment(AppState.self) private var appState
    private let credentialService = CredentialService.shared

    /// @Query 让插入、编辑和删除在保存后立即反映到列表。
    @Query(sort: \Host.name) private var hosts: [Host]
    @Query(sort: \HostGroup.name) private var groups: [HostGroup]

    @State private var selectedFilter: HostListFilter? = .all
    @State private var selectedHostID: UUID?
    @State private var searchText = ""
    @State private var hostEditorRequest: HostEditorRequest?
    @State private var groupEditorRequest: HostGroupEditorRequest?
    @State private var hostPendingDeletionID: UUID?
    @State private var groupPendingDeletionID: UUID?
    @State private var operationErrorMessage: String?
    @State private var credentialOperationInProgress = false
    @FocusState private var isHostListFocused: Bool

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
        // 显式按当前 Locale 解析标题，避免 NavigationSplitView 缓存旧语言。
        .navigationTitle(
            L10n.string("hosts.title", defaultValue: "Hosts", locale: locale)
        )
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("hosts.search"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editSelectedHost()
                } label: {
                    Label("hosts.edit", systemImage: "pencil")
                }
                .disabled(selectedHost == nil)
                .help("hosts.edit_selected_help")
                .accessibilityIdentifier("hosts.edit")

                Menu {
                    Button {
                        hostEditorRequest = HostEditorRequest(host: nil)
                    } label: {
                        Label("hosts.new", systemImage: "server.rack")
                    }

                    Button {
                        groupEditorRequest = HostGroupEditorRequest(group: nil)
                    } label: {
                        Label("groups.new", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("action.add", systemImage: "plus")
                }
                .help("hosts.add_help")
                .accessibilityIdentifier("hosts.add")
            }
        }
        .sheet(item: $hostEditorRequest) { request in
            HostEditorView(host: request.host, groups: groups)
        }
        .sheet(item: $groupEditorRequest) { request in
            HostGroupEditorView(group: request.group)
        }
        .alert(
            "hosts.delete_title",
            isPresented: hostDeleteAlertBinding,
            presenting: hostPendingDeletionID
        ) { hostID in
            Button("action.cancel", role: .cancel) {}
            Button("action.delete", role: .destructive) {
                AppLogger.persistence.info("Host deletion confirmed")
                deleteHost(withID: hostID)
            }
        } message: {
            _ in
            Text("hosts.delete_message")
        }
        .alert(
            "groups.delete_title",
            isPresented: groupDeleteAlertBinding,
            presenting: groupPendingDeletionID
        ) { groupID in
            Button("action.cancel", role: .cancel) {}
            Button("action.delete", role: .destructive) {
                deleteGroup(withID: groupID)
            }
        } message: {
            _ in
            Text("groups.delete_message")
        }
        .alert("hosts.error_title", isPresented: operationErrorBinding) {
            Button("action.ok", role: .cancel) {}
        } message: {
            Text(verbatim: operationErrorMessage ?? L10n.string(
                "error.operation_failed",
                defaultValue: "The operation could not be completed.",
                locale: locale
            ))
        }
        .accessibilityIdentifier("workspace.hosts")
    }

    /// Host Manager 内部的分类 Sidebar，使用 SwiftData Group 作为真实数据源。
    private var filterSidebar: some View {
        List(selection: $selectedFilter) {
            Section("hosts.title") {
                filterRow(
                    title: "hosts.favorites",
                    systemImage: "star.fill",
                    count: hosts.filter(\.favorite).count,
                    filter: .favorites
                )

                filterRow(
                    title: "hosts.all",
                    systemImage: "server.rack",
                    count: hosts.count,
                    filter: .all
                )
            }

            Section("groups.title") {
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
                        Button("groups.rename") {
                            groupEditorRequest = HostGroupEditorRequest(group: group)
                        }

                        Divider()

                        Button("groups.delete", role: .destructive) {
                            groupPendingDeletionID = group.id
                        }
                    }
                }

                Button {
                    groupEditorRequest = HostGroupEditorRequest(group: nil)
                } label: {
                    Label("groups.new", systemImage: "plus")
                }
                .buttonStyle(AppInteractiveButtonStyle(baseStyle: PlainButtonStyle()))
                .accessibilityIdentifier("hosts.newGroup")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("accessibility.hosts_sidebar")
    }

    /// 右侧内容区显示当前筛选标题和 Host 列表。
    private var hostContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: currentFilterTitle)
                        .font(.title2.bold())

                    Text(verbatim: hostCountDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(AppTheme.Spacing.regular)

            Divider()

            List(selection: $selectedHostID) {
                if filteredHosts.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(emptyStateTitleKey)
                        } icon: {
                            Image(systemName: searchText.isEmpty ? "server.rack" : "magnifyingglass")
                        }
                    } description: {
                        Text(emptyStateDescriptionKey)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredHosts) { host in
                        HostRowView(
                            host: host,
                            summary: appState.sessionManager.hostSessionSummary(hostID: host.id),
                            toggleFavorite: {
                                toggleFavorite(host)
                            },
                            connect: {
                                connect(host)
                            },
                            disconnect: {
                                disconnectHost(host)
                            }
                        )
                        .tag(host.id)
                        .contentShape(Rectangle())
                        // 显式同步选择状态，确保整行普通单击可启用编辑和键盘删除。
                        .onTapGesture {
                            selectedHostID = host.id
                            isHostListFocused = true
                        }
                        // 双击编辑与单击选择并行；双击时先选中当前 Host，再打开编辑表单。
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    hostEditorRequest = HostEditorRequest(host: host)
                                }
                        )
                        .contextMenu {
                            if hasSessions(host.id) {
                                Button("hosts.open_terminal") {
                                    connect(host)
                                }

                                Button("action.disconnect") {
                                    disconnectHost(host)
                                }
                            } else {
                                Button("action.connect") {
                                    connect(host)
                                }
                            }

                            Button("hosts.edit") {
                                hostEditorRequest = HostEditorRequest(host: host)
                            }

                            Button {
                                toggleFavorite(host)
                            } label: {
                                Text(
                                    host.favorite
                                        ? LocalizedStringKey("hosts.remove_favorite")
                                        : LocalizedStringKey("hosts.add_favorite")
                                )
                            }

                            Divider()

                            Button("hosts.delete", role: .destructive) {
                                hostPendingDeletionID = host.id
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            // 单击 Host 后让列表成为键盘焦点，使 macOS Delete 命令进入当前列表。
            .focused($isHostListFocused)
            .onDeleteCommand {
                if let selectedHost {
                    hostPendingDeletionID = selectedHost.id
                }
            }
        }
    }

    /// 构造带数量的原生筛选行。
    private func filterRow(
        title: LocalizedStringKey,
        systemImage: String,
        count: Int,
        filter: HostListFilter
    ) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
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
            L10n.string("hosts.all", defaultValue: "All Hosts", locale: locale)
        case .favorites:
            L10n.string("hosts.favorites", defaultValue: "Favorites", locale: locale)
        case let .group(groupID):
            groups.first { $0.id == groupID }?.name ?? L10n.string(
                "groups.singular",
                defaultValue: "Group",
                locale: locale
            )
        }
    }

    private var hostCountDescription: String {
        let count = filteredHosts.count
        if count == 1 {
            return L10n.string("hosts.count.one", defaultValue: "1 Host", locale: locale)
        }
        return L10n.format(
            "hosts.count.other",
            defaultValue: "%lld Hosts",
            locale: locale,
            arguments: Int64(count)
        )
    }

    private var emptyStateTitleKey: LocalizedStringKey {
        searchText.isEmpty ? "hosts.empty" : "search.no_results"
    }

    private var emptyStateDescriptionKey: LocalizedStringKey {
        searchText.isEmpty ? "hosts.empty_message" : "hosts.search_empty_message"
    }

    private func editSelectedHost() {
        guard let selectedHost else {
            return
        }
        hostEditorRequest = HostEditorRequest(host: selectedHost)
    }

    // MARK: - SSH 连接（Phase 8）

    /// 创建新的 Remote Terminal Session（同 Host 可多开，任务书 36/37）；
    /// Trust 对话框与连接失败状态由 Terminal Session / Root 层展示。
    private func connect(_ host: Host) {
        appState.connectHost(host)
    }

    /// 关闭该 Host 的全部 Terminal Session（有活跃会话时先经确认）。
    private func disconnectHost(_ host: Host) {
        appState.disconnectHost(host)
    }

    private func hasSessions(_ hostID: UUID) -> Bool {
        !appState.sessionManager.hostSessionSummary(hostID: hostID).isEmpty
    }

    /// Favorite 是普通 SwiftData 字段；切换后立即显式保存。
    private func toggleFavorite(_ host: Host) {
        host.favorite.toggle()
        host.updatedAt = .now
        saveOperation(
            successLog: "Host favorite updated",
            failureMessage: L10n.string(
                "hosts.favorite_update_failed",
                defaultValue: "Favorite could not be updated.",
                locale: locale
            )
        )
    }

    /// 删除 Host 前先清理其 Password/Passphrase；SwiftData 失败时用内存备份补偿恢复。
    private func deleteHost(withID hostID: UUID) {
        guard !credentialOperationInProgress else {
            AppLogger.persistence.error("Host deletion ignored because another credential operation is active")
            return
        }

        guard let host = hosts.first(where: { $0.id == hostID }) else {
            AppLogger.persistence.error("Host deletion target was not found")
            return
        }

        AppLogger.persistence.info("Host deletion started")
        credentialOperationInProgress = true
        Task { @MainActor in
            await deleteHostAndCredentials(host)
        }
    }

    @MainActor
    private func deleteHostAndCredentials(_ host: Host) async {
        var backup = HostCredentialBackup()

        do {
            if let credentialID = host.credentialID {
                backup.password = try await readPasswordIfPresent(credentialID: credentialID)
            }

            if let privateKeyID = host.privateKeyID {
                backup.privateKeyPassphrase = try await readPassphraseIfPresent(privateKeyID: privateKeyID)
            }

            if let password = backup.password {
                try await credentialService.deletePassword(credentialID: password.id)
            }

            if let passphrase = backup.privateKeyPassphrase {
                try await credentialService.deletePrivateKeyPassphrase(privateKeyID: passphrase.id)
            }

            modelContext.delete(host)
            do {
                try modelContext.save()
            } catch {
                throw HostDeletionError.persistenceFailed
            }

            if selectedHostID == host.id {
                selectedHostID = nil
            }
            hostPendingDeletionID = nil
            AppLogger.persistence.info("Host and associated credentials deleted")
        } catch {
            modelContext.rollback()
            let restored = await restoreCredentials(from: backup)
            operationErrorMessage = restored
                ? userFacingDeletionMessage(for: error)
                : L10n.string(
                    "hosts.delete_keychain_restore_failed",
                    defaultValue: "The Host was not deleted and macOS Keychain restoration also failed. Please retry.",
                    locale: locale
                )
            AppLogger.persistence.error("Failed to delete Host and associated credentials")
        }

        credentialOperationInProgress = false
    }

    private func readPasswordIfPresent(credentialID: UUID) async throws -> StoredCredential? {
        do {
            let secret = try await credentialService.readPassword(credentialID: credentialID)
            return StoredCredential(id: credentialID, secret: secret)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    private func readPassphraseIfPresent(privateKeyID: UUID) async throws -> StoredCredential? {
        do {
            let secret = try await credentialService.readPrivateKeyPassphrase(privateKeyID: privateKeyID)
            return StoredCredential(id: privateKeyID, secret: secret)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    /// 只在删除事务失败时执行；Secret 不进入日志、SwiftData 或长期状态。
    private func restoreCredentials(from backup: HostCredentialBackup) async -> Bool {
        do {
            if let password = backup.password {
                try await credentialService.upsertPassword(
                    password.secret,
                    credentialID: password.id
                )
            }

            if let passphrase = backup.privateKeyPassphrase {
                try await credentialService.upsertPrivateKeyPassphrase(
                    passphrase.secret,
                    privateKeyID: passphrase.id
                )
            }
            return true
        } catch {
            AppLogger.security.error("Credential restoration after Host deletion failed")
            return false
        }
    }

    private func userFacingDeletionMessage(for error: Error) -> String {
        if let keychainError = error as? KeychainError {
            return keychainError.localizedDescription(locale: locale)
        }
        return L10n.string(
            "hosts.delete_failed",
            defaultValue: "The Host could not be deleted. Please try again.",
            locale: locale
        )
    }

    private func deleteGroup(withID groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            return
        }

        if selectedFilter == .group(group.id) {
            selectedFilter = .all
        }

        modelContext.delete(group)
        groupPendingDeletionID = nil
        saveOperation(
            successLog: "Host group deleted",
            failureMessage: L10n.string(
                "groups.delete_failed",
                defaultValue: "The Group could not be deleted.",
                locale: locale
            )
        )
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
            get: { hostPendingDeletionID != nil },
            set: { isPresented in
                if !isPresented {
                    hostPendingDeletionID = nil
                }
            }
        )
    }

    private var groupDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { groupPendingDeletionID != nil },
            set: { isPresented in
                if !isPresented {
                    groupPendingDeletionID = nil
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

/// 删除 Host 时短暂保存补偿所需 Secret，生命周期只覆盖当前异步操作。
private struct HostCredentialBackup {
    var password: StoredCredential?
    var privateKeyPassphrase: StoredCredential?
}

private struct StoredCredential {
    let id: UUID
    let secret: String
}

private enum HostDeletionError: Error {
    case persistenceFailed
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
