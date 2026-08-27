import SwiftUI

/// Phase 2 只展示唯一的 Local Tab；多 Tab 必须等计划书后续阶段。
struct TerminalTabBar: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.none) {
            VStack(spacing: AppTheme.Spacing.none) {
                Label("Local", systemImage: "terminal")
                    .padding(.horizontal, AppTheme.Spacing.regular)
                    .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(AppTheme.accentColor)
                    .frame(height: 2)
            }
            .foregroundStyle(AppTheme.accentColor)
            .background(AppTheme.accentColor.opacity(0.10))
            .accessibilityLabel("Local Terminal Tab")
            .accessibilityValue("Selected")
            .accessibilityIdentifier("tabBar.local")

            Button(action: {}) {
                Image(systemName: "plus")
                    .frame(width: AppTheme.Layout.tabBarHeight)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("New sessions are introduced in a later phase")
            .accessibilityIdentifier("tabBar.newSession")

            Spacer(minLength: 0)
        }
        .frame(height: AppTheme.Layout.tabBarHeight)
        .background(.bar)
        .accessibilityLabel("Terminal Tabs")
    }
}
