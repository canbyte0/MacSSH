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
                statusText: appState.statusText,
                detailText: appState.statusDetail
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
        .sheet(item: hostTrustDialogBinding) { request in
            hostTrustDialog(for: request)
        }
        .alert(
            "Close SSH Session?",
            isPresented: closeConfirmationBinding
        ) {
            Button("Cancel", role: .cancel) {
                manager.cancelCloseConfirmation()
            }
            Button("Close", role: .destructive) {
                manager.confirmClose()
            }
        } message: {
            Text(
                "This will disconnect from "
                    + (manager.pendingCloseConfirmation?.hostDisplayName ?? "the host") + "."
            )
        }
        .alert(
            "Disconnect Host?",
            isPresented: hostCloseConfirmationBinding
        ) {
            Button("Cancel", role: .cancel) {
                manager.cancelHostClose()
            }
            Button("Disconnect", role: .destructive) {
                manager.confirmHostClose()
            }
        } message: {
            if let request = manager.pendingHostClose {
                Text(
                    "This will close \(request.sessionCount) terminal session(s) connected to "
                        + request.hostName + "."
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MacSSH Phase 8")
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
