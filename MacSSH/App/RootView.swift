import AppKit
import SwiftUI

/// 主界面容器，保留 Phase 2 Terminal 并装配 Phase 3 Host Manager。
struct RootView: View {
    /// 从应用入口注入的全局状态。
    @Environment(AppState.self) private var appState

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MacSSH Phase 3")
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
}
