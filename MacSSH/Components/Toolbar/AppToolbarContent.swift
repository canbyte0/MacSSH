import SwiftUI

/// 顶层原生 Toolbar；Hosts 页面由自身提供管理操作。
struct AppToolbarContent: ToolbarContent {
    @Environment(AppState.self) private var appState

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("MacSSH")
                .font(.headline)
        }

        if appState.selectedSection != .hosts {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newLocalSession) {
                    Label("toolbar.new_session", systemImage: "plus")
                }
                .help("toolbar.new_local_terminal_help")
                .accessibilityIdentifier("toolbar.newSession")
            }
        }

        // MacSSH 1.1 Phase 7：右侧命令侧边栏 toggle（仅 Terminal 页显示）。
        // 任务书 §3 / §40 / §64：native toolbar button，不浮在 Terminal 上。
        if appState.selectedSection == .terminal {
            @Bindable var appState = appState
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.isRightSidebarVisible.toggle()
                } label: {
                    Image(systemName: appState.isRightSidebarVisible
                          ? "sidebar.right"
                          : "sidebar.right")
                }
                .help(appState.isRightSidebarVisible
                      ? L10n.string("sidebar_right.hide", defaultValue: "Hide Sidebar", locale: appState.language.locale)
                      : L10n.string("sidebar_right.show", defaultValue: "Show Sidebar", locale: appState.language.locale))
                .accessibilityLabel(appState.isRightSidebarVisible
                                    ? L10n.string("sidebar_right.hide", defaultValue: "Hide Sidebar", locale: appState.language.locale)
                                    : L10n.string("sidebar_right.show", defaultValue: "Show Sidebar", locale: appState.language.locale))
                .accessibilityIdentifier("toolbar.toggleRightSidebar")
            }
        }
    }

    private func newLocalSession() {
        appState.selectedSection = .terminal
        appState.sessionManager.createLocalSession()
    }
}
