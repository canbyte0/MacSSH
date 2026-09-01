import AppKit
import SwiftUI

/// 主界面容器：Sidebar + Terminal（多 Session Tabs）/ Hosts / SSH 安全能力。
struct RootView: View {
    /// 从应用入口注入的全局状态。
    @Environment(AppState.self) private var appState

    private var manager: SessionManager {
        appState.sessionManager
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: AppTheme.Spacing.none) {
            NavigationSplitView {
                AppSidebar(selection: $appState.selectedSection)
            } detail: {
                selectedWorkspace
            }
            .navigationSplitViewStyle(.balanced)

            Divider()

            AppStatusBar(
                statusText: appState.statusText(locale: appState.language.locale),
                detailText: appState.statusDetail(locale: appState.language.locale)
            )
        }
        .frame(
            minWidth: AppTheme.Window.minimumWidth,
            minHeight: AppTheme.Window.minimumHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            AppToolbarContent()
        }
        // 语言变化只刷新 View hierarchy；AppState 与全部 Runtime Manager 保持原实例。
        .environment(\.locale, appState.language.locale)
        .sheet(item: hostTrustDialogBinding) { request in
            hostTrustDialog(for: request)
        }
        .alert(
            "session.close.title",
            isPresented: closeConfirmationBinding
        ) {
            Button("action.cancel", role: .cancel) {
                manager.cancelCloseConfirmation()
            }
            Button("action.close", role: .destructive) {
                manager.confirmClose()
            }
        } message: {
            if let session = manager.pendingCloseConfirmation {
                let transferCount = appState.transferManager.transferCount(forSession: session.id)
                if transferCount > 0 {
                    // Phase 11（任务书二十六）：关闭确认明确列出任务数与后果。
                    Text(verbatim: L10n.format(
                        "session.close.active_transfers",
                        defaultValue: "This SSH session has %lld file transfer tasks. Closing it will cancel active and waiting transfers.",
                        locale: appState.language.locale,
                        arguments: Int64(transferCount)
                    ))
                } else {
                    Text(verbatim: L10n.format(
                        "session.close.disconnect_host",
                        defaultValue: "This will disconnect from %@.",
                        locale: appState.language.locale,
                        arguments: session.hostDisplayName ?? L10n.string(
                            "host.generic_name",
                            defaultValue: "the host",
                            locale: appState.language.locale
                        )
                    ))
                }
            }
        }
        .alert(
            "host.disconnect.title",
            isPresented: hostCloseConfirmationBinding
        ) {
            Button("action.cancel", role: .cancel) {
                manager.cancelHostClose()
            }
            Button("action.disconnect", role: .destructive) {
                manager.confirmHostClose()
            }
        } message: {
            if let request = manager.pendingHostClose {
                Text(verbatim: L10n.format(
                    "host.disconnect.sessions_message",
                    defaultValue: "This will close %lld terminal session(s) connected to %@.",
                    locale: appState.language.locale,
                    arguments: Int64(request.sessionCount), request.hostName
                ))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("accessibility.macssh_workspace")
    }

    /// 根据 Sidebar 选择装配当前阶段允许的 Workspace。
    @ViewBuilder
    private var selectedWorkspace: some View {
        switch appState.selectedSection {
        case .terminal:
            TerminalWorkspaceView()
        case .hosts:
            HostListView()
        case .transfers:
            TransferListView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: - Host Trust 对话框（Phase 6 安全语义不变，Phase 8 起绑定到 Session）

    /// 驱动全局 Trust 对话框的请求；以 SessionID 作为稳定标识。
    /// Session 在等待决策期间被关闭时（Tab 已消失）对话框自动收起，
    /// teardown 内的 disconnect() 会以 cancel 结束等待，不留孤儿连接
    /// （任务书 40）。
    private struct HostTrustDialogRequest: Identifiable {
        let id: UUID
        let info: SSHConnectionInfo
    }

    private var hostTrustDialogRequest: HostTrustDialogRequest? {
        guard let session = manager.pendingTrustSession,
            let info = session.connectionInfo
        else {
            return nil
        }
        return HostTrustDialogRequest(id: session.id, info: info)
    }

    private var hostTrustDialogBinding: Binding<HostTrustDialogRequest?> {
        Binding(
            get: { hostTrustDialogRequest },
            set: { newValue in
                guard newValue == nil, let current = hostTrustDialogRequest else { return }
                manager.resolveHostTrust(sessionID: current.id, decision: .cancel)
            }
        )
    }

    @ViewBuilder
    private func hostTrustDialog(for request: HostTrustDialogRequest) -> some View {
        // Phase 6：根据 KnownHost 验证结果决定显示未知主机对话框或
        // Host Key Changed 警告。
        if case let .changed(storedFingerprint, storedKeyType) = request.info.hostKeyVerification {
            HostKeyChangedDialogView(
                info: request.info,
                storedFingerprint: storedFingerprint,
                storedKeyType: storedKeyType,
                onReplace: {
                    manager.resolveHostTrust(sessionID: request.id, decision: .replaceTrustedKey)
                },
                onCancel: {
                    manager.resolveHostTrust(sessionID: request.id, decision: .cancel)
                }
            )
            .interactiveDismissDisabled(true)
        } else {
            HostTrustDialogView(
                info: request.info,
                onTrustOnce: {
                    manager.resolveHostTrust(sessionID: request.id, decision: .trustOnce)
                },
                onTrustAlways: {
                    manager.resolveHostTrust(sessionID: request.id, decision: .trustAlways)
                },
                onCancel: {
                    manager.resolveHostTrust(sessionID: request.id, decision: .cancel)
                }
            )
            .interactiveDismissDisabled(true)
        }
    }

    // MARK: - 关闭确认

    private var closeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { manager.pendingCloseConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    manager.cancelCloseConfirmation()
                }
            }
        )
    }

    private var hostCloseConfirmationBinding: Binding<Bool> {
        Binding(
            get: { manager.pendingHostClose != nil },
            set: { isPresented in
                if !isPresented {
                    manager.cancelHostClose()
                }
            }
        )
    }
}
