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
    }

    private func newLocalSession() {
        appState.selectedSection = .terminal
        appState.sessionManager.createLocalSession()
    }
}
