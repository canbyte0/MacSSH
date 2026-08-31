import AppKit
import SwiftUI

/// Phase 9 SFTP Browser（只读）：路径栏 + 懒加载列表 + 状态覆盖。
///
/// UI 只观察 `SFTPService` 与 `ManagedTerminalSession`，绝不触碰 libssh2；
/// 导航 / 刷新 / 重试全部委托业务层（原子提交与竞态防护在业务层）。
struct SFTPBrowserView: View {
    @Environment(AppState.self) private var appState

    let session: ManagedTerminalSession

    @State private var selection: SFTPFileEntry.ID?

    private var manager: SessionManager {
        appState.sessionManager
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
        } else {
            unavailablePane
        }
    }

    // MARK: - 路径栏

    /// Parent（根目录禁用）+ 当前路径（只读、可选中复制）+ Refresh。
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
    /// 单击选中、双击进入目录；右键仅 Refresh / Copy Path（只读）。
    private func entriesTable(_ service: SFTPService) -> some View {
        Table(service.entries, selection: $selection) {
            TableColumn("Name") { entry in
                Label {
                    Text(entry.name)
                } icon: {
                    Image(systemName: iconName(for: entry))
                        .foregroundStyle(iconColor(for: entry))
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
