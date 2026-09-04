import SwiftUI

/// MacSSH 1.1 Phase 7：Terminal 右侧栏容器（历史记录 / 常用命令）。
///
/// 任务书 §2 / §5 / §36 / Phase 7A 验收 §57–§62：
/// - 顶部固定两个 icon-only 按钮（history / savedCommands），一次只选一个；
/// - 下方内容区独立 ScrollView，滚动时顶部图标不跟随；
/// - 选中态明显高亮，hover native 反馈，tooltip + accessibilityLabel；
/// - 不用文字 segmented picker。
struct TerminalRightSidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: AppTheme.Spacing.none) {
            sidebarHeader(selectedTab: $appState.selectedRightSidebarTab)

            Divider()

            sidebarContent(tab: appState.selectedRightSidebarTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: AppTheme.Layout.rightSidebarWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("workspace.rightSidebar")
    }

    // MARK: - 顶部固定图标 tab

    private func sidebarHeader(selectedTab: Binding<CommandSidebarTab>) -> some View {
        HStack(spacing: AppTheme.Spacing.compact) {
            ForEach(CommandSidebarTab.allCases, id: \.self) { tab in
                sidebarTabButton(tab: tab, isSelected: selectedTab.wrappedValue == tab) {
                    selectedTab.wrappedValue = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact)
        .background(.bar)
    }

    private func sidebarTabButton(
        tab: CommandSidebarTab,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: AppTheme.ButtonInteraction.compactIconBackgroundDiameter,
                       height: AppTheme.ButtonInteraction.compactIconBackgroundDiameter)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tab == .history
              ? L10n.string("sidebar_right.history", defaultValue: "History", locale: locale)
              : L10n.string("sidebar_right.saved_commands", defaultValue: "Saved Commands", locale: locale))
        .accessibilityLabel(tab == .history
                            ? L10n.string("sidebar_right.history", defaultValue: "History", locale: locale)
                            : L10n.string("sidebar_right.saved_commands", defaultValue: "Saved Commands", locale: locale))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("sidebar_right.tab.\(tab.rawValue)")
    }

    // MARK: - 内容区

    @ViewBuilder
    private func sidebarContent(tab: CommandSidebarTab) -> some View {
        switch tab {
        case .history:
            CommandHistorySidebarView()
        case .savedCommands:
            SavedCommandsSidebarView()
        }
    }
}
