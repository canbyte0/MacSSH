import SwiftData
import SwiftUI

/// Host Manager 直接观察 SwiftData，并在删除 Host 时同步清理 Keychain 凭据。
/// Phase 5 起同时提供真实 SSH 连接入口；连接状态由 SSHService 持有。
struct HostListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    private let credentialService = CredentialService.shared

    private var sshService: SSHService {
        appState.sshService
    }

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
        .sheet(item: hostTrustDialogBinding) { request in
            // Phase 6：根据 KnownHost 验证结果决定显示未知主机对话框或 Host Key Changed 警告。
            if case let .changed(storedFingerprint, storedKeyType) = request.info.hostKeyVerification {
                HostKeyChangedDialogView(
                    info: request.info,
                    storedFingerprint: storedFingerprint,
                    storedKeyType: storedKeyType,
                    onReplace: {
                        sshService.replaceTrustedKey(hostID: request.id)
                    },
                    onCancel: {
                        sshService.cancelHostTrust(hostID: request.id)
                    }
                )
                .interactiveDismissDisabled(true)
            } else {
                HostTrustDialogView(
                    info: request.info,
                    onTrustOnce: {
                        sshService.trustOnce(hostID: request.id)
                    },
                    onTrustAlways: {
                        sshService.trustAlways(hostID: request.id)
                    },
                    onCancel: {
                        sshService.cancelHostTrust(hostID: request.id)
                    }
                )
                .interactiveDismissDisabled(true)
            }
        }
        .alert(
            "Delete Host?",
            isPresented: hostDeleteAlertBinding,
            presenting: hostPendingDeletionID
        ) { hostID in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                AppLogger.persistence.info("Host deletion confirmed")
                deleteHost(withID: hostID)
            }
        } message: {
            _ in
            Text("This removes the Host metadata and its saved Keychain credentials from this Mac.")
        }
        .alert(
            "Delete Group?",
            isPresented: groupDeleteAlertBinding,
            presenting: groupPendingDeletionID
        ) { groupID in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteGroup(withID: groupID)
            }
        } message: {
            _ in
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
                            groupPendingDeletionID = group.id
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
                        HostRowView(
                            host: host,
                            connectionInfo: sshService.connectionInfo(for: host.id),
                            toggleFavorite: {
                                toggleFavorite(host)
                            },
                            connect: {
                                connect(host)
                            },
                            disconnect: {
                                disconnectHost(host)
                            },
                            openTerminal: {
                                appState.openRemoteTerminal(for: host)
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
                            if isHostConnected(host.id) {
                                Button("Open Terminal") {
                                    appState.openRemoteTerminal(for: host)
                                }

                                Button("Disconnect") {
                                    disconnectHost(host)
                                }
                            } else if !sshService.isConnectionActive(host.id) {
                                Button("Connect") {
                                    connect(host)
                                }
                            }

                            Button("Edit Host") {
                                hostEditorRequest = HostEditorRequest(host: host)
                            }

                            Button(host.favorite ? "Remove from Favorites" : "Add to Favorites") {
                                toggleFavorite(host)
                            }

                            Divider()

                            Button("Delete Host", role: .destructive) {
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

    // MARK: - SSH 连接（Phase 5）

    /// 发起连接；前置校验失败（Private Key、缺失凭据等）直接显示 failed 状态。
    private func connect(_ host: Host) {
        sshService.connect(to: host)
    }

    /// 断开连接（幂等）；先收起该主机的 Remote Terminal（由连接生命周期
    /// 驱动，Channel 关闭与 session 释放在 SSHConnection actor 内
    /// 按序完成），再断开连接本身。
    private func disconnectHost(_ host: Host) {
        appState.hostDidDisconnect(hostname: host.hostname, port: host.port)
        sshService.disconnect(hostID: host.id)
    }

    private func isHostConnected(_ hostID: UUID) -> Bool {
        sshService.connectionInfo(for: hostID)?.phase == .connected
    }

    /// 当前处于 awaitingHostTrust 的连接；sheet 展示其真实 Host Key。
    /// 使用独立 struct 规避 actor 隔离类型的 Identifiable 限制。
    private var hostTrustRequest: HostTrustRequest? {
        guard let info = sshService.connections.values.first(where: {
            $0.phase == .awaitingHostTrust
        }) else {
            return nil
        }
        return HostTrustRequest(id: info.hostID, info: info)
    }

    /// Trust 对话框关闭（Esc 等）等价于 Cancel，必须断开连接。
    private var hostTrustDialogBinding: Binding<HostTrustRequest?> {
        Binding(
            get: { hostTrustRequest },
            set: { newValue in
                guard newValue == nil, let current = hostTrustRequest else { return }
                sshService.cancelHostTrust(hostID: current.id)
            }
        )
    }

    /// Favorite 是普通 SwiftData 字段；切换后立即显式保存。
    private func toggleFavorite(_ host: Host) {
        host.favorite.toggle()
        host.updatedAt = .now
        saveOperation(successLog: "Host favorite updated", failureMessage: "Favorite could not be updated.")
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
                : "The Host was not deleted and macOS Keychain restoration also failed. Please retry."
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
            return keychainError.localizedDescription
        }
        return "The Host could not be deleted. Please try again."
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

/// 驱动 Host Trust 对话框 Sheet 的请求；以 HostID 作为稳定标识。
private struct HostTrustRequest: Identifiable {
    let id: UUID
    let info: SSHConnectionInfo
}
