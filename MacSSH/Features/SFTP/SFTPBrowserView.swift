import AppKit
import SwiftUI

/// Phase 9 SFTP Browser：路径栏 + 懒加载列表 + 状态覆盖。
/// Phase 10（计划书口径）：
/// - 路径栏 Upload / Download / **新建文件夹**（单文件流式传输由
///   `TransferManager` 接管；面板选择结束后才启动异步传输，
///   绝不阻塞 SSH actor）；
/// - 条目右键菜单 **重命名… / 删除**（删除仅普通文件，确认后才执行）；
/// - 全部写操作经 `SFTPService` 串行执行，成功后自动刷新列表。
///
/// UI 只观察 `SFTPService` 与 `ManagedTerminalSession`，绝不触碰 libssh2；
/// 导航 / 刷新 / 重试 / 文件操作全部委托业务层（原子提交与竞态防护在业务层）。
struct SFTPBrowserView: View {
    @Environment(AppState.self) private var appState

    let session: ManagedTerminalSession

    @State private var selection: SFTPFileEntry.ID?

    /// 传输入口拒绝 / 预检失败的临时提示（如远端已存在不覆盖）。
    @State private var transferNotice: String?

    /// 新建文件夹对话框：输入缓冲 + 呈现状态。
    @State private var mkdirDialogActive = false
    @State private var mkdirName = ""

    /// 重命名对话框：目标条目 + 输入缓冲（预填当前名）。
    @State private var renameTarget: SFTPFileEntry?
    @State private var renameName = ""

    /// 删除确认对话框：目标条目（仅普通文件）。
    @State private var deleteTarget: SFTPFileEntry?

    private var manager: SessionManager {
        appState.sessionManager
    }

    private var transferManager: TransferManager {
        appState.transferManager
    }

    private var service: SFTPService? {
        session.sftpService
    }

    var body: some View {
        if let service {
            VStack(spacing: AppTheme.Spacing.none) {
                pathBar(service)

                Divider()

                content(service)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                footer(service)
            }
            .accessibilityIdentifier("sftp.browser")
            .alert(
                "无法开始传输",
                isPresented: transferNoticeBinding
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(transferNotice ?? "")
            }
            // 文件操作失败提示（业务层写入，置空即收起）。
            .alert(
                "操作失败",
                isPresented: fileOperationNoticeBinding(service)
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(service.fileOperationNotice ?? "")
            }
            // 新建文件夹：输入名称 → 业务层在当前目录创建（0755）。
            .alert("新建文件夹", isPresented: $mkdirDialogActive) {
                TextField("文件夹名称", text: $mkdirName)
                Button("创建") {
                    service.createDirectory(named: mkdirName)
                    mkdirName = ""
                }
                Button("取消", role: .cancel) {
                    mkdirName = ""
                }
            }
            // 重命名：预填当前名；同级重命名，目标名已存在由服务器拒绝。
            .alert("重命名", isPresented: renameDialogBinding) {
                TextField("新名称", text: $renameName)
                Button("重命名") {
                    if let entry = renameTarget {
                        service.renameEntry(entry, to: renameName)
                    }
                    renameTarget = nil
                }
                Button("取消", role: .cancel) {
                    renameTarget = nil
                }
            }
            // 删除确认：仅普通文件；删除后无法撤销。
            .alert(
                "确定删除 “\(deleteTarget?.name ?? "")”？",
                isPresented: deleteDialogBinding
            ) {
                Button("删除", role: .destructive) {
                    if let entry = deleteTarget {
                        service.deleteEntry(entry)
                    }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) {
                    deleteTarget = nil
                }
            } message: {
                Text("删除后无法撤销。")
            }
        } else {
            unavailablePane
        }
    }

    // MARK: - 路径栏

    /// Parent（根目录禁用）+ 当前路径（只读、可选中复制）+ Refresh。
    /// Phase 10：Upload / Download（列表加载完成才可用）。
    private func pathBar(_ service: SFTPService) -> some View {
        HStack(spacing: AppTheme.Spacing.compact) {
            Button {
                service.goParent()
            } label: {
                Label("Parent", systemImage: "arrow.left")
            }
            .disabled(service.phase != .loaded || service.isAtRoot)
            .accessibilityIdentifier("sftp.parent")

            Text(service.currentPath)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sftp.currentPath")

            Button {
                presentUploadPanel(service)
            } label: {
                Label("上传", systemImage: "arrow.up.doc")
            }
            .disabled(service.phase != .loaded)
            .accessibilityIdentifier("sftp.upload")

            Button {
                presentDownloadPanel(service)
            } label: {
                Label("下载", systemImage: "arrow.down.doc")
            }
            .disabled(service.phase != .loaded || selectedDownloadableEntry(service) == nil)
            .accessibilityIdentifier("sftp.download")

            Button {
                mkdirName = ""
                mkdirDialogActive = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            .disabled(service.phase != .loaded || service.isFileOperationRunning)
            .accessibilityIdentifier("sftp.mkdir")

            Button {
                service.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(service.phase == .loading)
            .accessibilityIdentifier("sftp.refresh")
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact)
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ service: SFTPService) -> some View {
        switch service.phase {
        case .idle, .loading:
            loadingPane(session.statusText)
        case .loaded:
            if service.entries.isEmpty {
                emptyPane
            } else {
                entriesTable(service)
            }
        case let .failed(error):
            errorPane(service, error: error)
        }
    }

    private func loadingPane(_ status: String) -> some View {
        VStack(spacing: AppTheme.Spacing.regular) {
            ProgressView()

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("sftp.loading")
    }

    private var emptyPane: some View {
        ContentUnavailableView {
            Label("Empty Directory", systemImage: "folder")
        } description: {
            Text("This directory has no visible entries.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("sftp.empty")
    }

    /// 懒加载表格：目录优先已由业务层排序，UI 不再重排；
    /// 单击选中、双击进入目录；行右键提供重命名 / 删除（Phase 10），
    /// 表格级右键保留 Refresh / Copy Path。
    private func entriesTable(_ service: SFTPService) -> some View {
        Table(service.entries, selection: $selection) {
            TableColumn("Name") { entry in
                Label {
                    Text(entry.name)
                } icon: {
                    Image(systemName: iconName(for: entry))
                        .foregroundStyle(iconColor(for: entry))
                }
                .contextMenu {
                    Button("重命名…") {
                        beginRename(entry)
                    }
                    .disabled(service.isFileOperationRunning)
                    .accessibilityIdentifier("sftp.rename")

                    Button("删除", role: .destructive) {
                        beginDelete(entry)
                    }
                    .disabled(entry.kind != .regularFile || service.isFileOperationRunning)
                    .accessibilityIdentifier("sftp.delete")
                }
            }
            .width(min: 180)

            TableColumn("Size") { entry in
                Text(entry.sizeDisplay)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70)

            TableColumn("Modified") { entry in
                Text(entry.modifiedDisplay)
                    .foregroundStyle(.secondary)
            }
            .width(min: 130)

            TableColumn("Permissions") { entry in
                Text(entry.permissionsDisplay)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90)
        }
        .onTapGesture(count: 2) {
            openSelectedDirectory(service)
        }
        .contextMenu {
            Button("Refresh") {
                service.refresh()
            }

            Button("Copy Path") {
                copyCurrentPath(service)
            }
        }
        .accessibilityIdentifier("sftp.entries")
    }

    private func errorPane(_ service: SFTPService, error: SFTPError) -> some View {
        VStack(spacing: AppTheme.Spacing.regular) {
            Image(systemName: error == .connectionLost ? "wifi.slash" : "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(Color.red)

            Text(error == .connectionLost ? "Connection Lost" : "Unable to Load Directory")
                .font(.headline)

            Text(error.errorDescription ?? "An unknown error occurred.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.spacious)

            if error == .connectionLost {
                // 绝不静默重连：复用 Phase 8 手动 Reconnect，
                // 重连成功后由 runConnectFlow 重启 Files 面板。
                Button("Reconnect") {
                    manager.reconnectSession(id: session.id)
                }
                .disabled(!session.canReconnect)
                .accessibilityIdentifier("sftp.reconnect")
            } else {
                Button("Retry") {
                    service.refresh()
                }
                .accessibilityIdentifier("sftp.retry")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("sftp.error")
    }

    // MARK: - 底栏

    /// 条目数 + 当前路径（跟随列表提交，导航失败不抖动）。
    private func footer(_ service: SFTPService) -> some View {
        HStack(spacing: AppTheme.Spacing.regular) {
            Text("\(service.entries.count) items")
                .foregroundStyle(.secondary)

            Spacer()

            Text(service.currentPath)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .accessibilityIdentifier("sftp.footer")
    }

    // MARK: - 无 SFTP 运行时（Local / 未连接 / 断开）

    @ViewBuilder
    private var unavailablePane: some View {
        Group {
            switch session.kind {
            case .local:
                VStack(spacing: AppTheme.Spacing.regular) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.title)
                        .foregroundStyle(.secondary)

                    Text("Files are only available for SSH sessions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("sftp.localDisabled")

            case .remoteSSH:
                switch session.displayState {
                case .exited, .disconnected, .failed:
                    VStack(spacing: AppTheme.Spacing.regular) {
                        Image(systemName: "wifi.slash")
                            .font(.title)
                            .foregroundStyle(.secondary)

                        Text("Connection is not active.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Button("Reconnect") {
                            manager.reconnectSession(id: session.id)
                        }
                        .disabled(!session.canReconnect)
                        .accessibilityIdentifier("sftp.reconnect")
                    }
                    .accessibilityIdentifier("sftp.disconnected")

                default:
                    loadingPane(session.statusText)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 行为

    /// 双击进入目录（仅目录；文件双击无操作）。
    private func openSelectedDirectory(_ service: SFTPService) {
        guard
            let selection,
            let entry = service.entries.first(where: { $0.id == selection })
        else {
            return
        }
        self.selection = nil
        service.navigate(into: entry)
    }

    private func copyCurrentPath(_ service: SFTPService) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.currentPath, forType: .string)
    }

    // MARK: - 传输入口（Phase 10）

    /// 提示弹框绑定：消息置空时收起。
    private var transferNoticeBinding: Binding<Bool> {
        Binding(
            get: { transferNotice != nil },
            set: { newValue in
                if !newValue {
                    transferNotice = nil
                }
            }
        )
    }

    /// 文件操作错误提示绑定：业务层消息置空时收起。
    private func fileOperationNoticeBinding(_ service: SFTPService) -> Binding<Bool> {
        Binding(
            get: { service.fileOperationNotice != nil },
            set: { newValue in
                if !newValue {
                    service.fileOperationNotice = nil
                }
            }
        )
    }

    /// 重命名对话框呈现绑定：目标条目置空即收起。
    private var renameDialogBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { newValue in
                if !newValue {
                    renameTarget = nil
                }
            }
        )
    }

    /// 删除确认对话框呈现绑定：目标条目置空即收起。
    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { newValue in
                if !newValue {
                    deleteTarget = nil
                }
            }
        )
    }

    /// 打开重命名对话框：预填当前名（全选由系统默认行为完成）。
    private func beginRename(_ entry: SFTPFileEntry) {
        renameName = entry.name
        renameTarget = entry
    }

    /// 打开删除确认对话框。
    private func beginDelete(_ entry: SFTPFileEntry) {
        deleteTarget = entry
    }

    /// 选中且可下载的条目（仅普通文件；目录 / 符号链接 / 特殊文件禁用）。
    private func selectedDownloadableEntry(_ service: SFTPService) -> SFTPFileEntry? {
        guard
            let selection,
            let entry = service.entries.first(where: { $0.id == selection }),
            entry.kind == .regularFile
        else {
            return nil
        }
        return entry
    }

    /// 上传：NSOpenPanel 选普通文件（目录在选择层即被排除），
    /// 选择结束后才启动异步传输，面板期间不阻塞 SSH actor。
    private func presentUploadPanel(_ service: SFTPService) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "上传"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let result = transferManager.requestUpload(session: session, localURL: url)
        if let rejection = result.rejection {
            transferNotice = rejection
        }
    }

    /// 下载：NSSavePanel 选目标位置（默认名 = 远端文件名），
    /// 同名覆盖由用户在面板内确认；确认后启动异步传输。
    private func presentDownloadPanel(_ service: SFTPService) {
        guard let entry = selectedDownloadableEntry(service) else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = entry.name
        panel.prompt = "下载"
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let result = transferManager.requestDownload(
            session: session,
            entry: entry,
            destinationURL: url
        )
        if let rejection = result.rejection {
            transferNotice = rejection
        }
    }

    // MARK: - 图标

    private func iconName(for entry: SFTPFileEntry) -> String {
        switch entry.kind {
        case .directory:
            return "folder.fill"
        case .regularFile:
            return "doc"
        case .symlink:
            return "arrow.turn.up.right"
        case .other:
            return "doc.questionmark"
        }
    }

    private func iconColor(for entry: SFTPFileEntry) -> Color {
        switch entry.kind {
        case .directory:
            return .blue
        case .symlink:
            return AppTheme.accentColor
        case .regularFile, .other:
            return .secondary
        }
    }
}
