import SwiftUI

/// Phase 2 本地 Terminal 页面，组合单一 Tab Bar 和真实 SwiftTerm Workspace。
struct TerminalWorkspaceView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            TerminalTabBar()

            Divider()

            TerminalRepresentable(service: appState.localTerminalService)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Local Terminal")
        .accessibilityIdentifier("workspace.terminal")
    }
}
