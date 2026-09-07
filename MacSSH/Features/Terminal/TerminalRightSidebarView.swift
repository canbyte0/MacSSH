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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 由外层工作区根据拖动位置和当前窗口宽度计算出的实际宽度。
    let width: CGFloat

    init(width: CGFloat = AppTheme.Layout.rightSidebarWidth) {
        self.width = width
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: AppTheme.Spacing.none) {
            sidebarHeader(selectedTab: $appState.selectedRightSidebarTab)

            Divider()

            sidebarContent(tab: appState.selectedRightSidebarTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
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
        // 与主面板 TerminalTabBar 共用同一高度，使本栏下方 Divider
        // 以及内容 Header 下方 Divider 都落在相同的水平坐标。
        .frame(height: AppTheme.Layout.tabBarHeight)
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
        // 显式 `.plain` 会覆盖 WindowGroup 的统一按钮动画，因此在此重新套用
        // 同一交互样式；固定圆形底色不会扩大可见 hover 范围。
        .buttonStyle(AppInteractiveButtonStyle(
            baseStyle: PlainButtonStyle(),
            compactBackgroundDiameter: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
        ))
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
            value: isSelected
        )
        .help(tab.localizedTitle(locale: locale))
        .accessibilityLabel(tab.localizedTitle(locale: locale))
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
        case .agent:
            // MacSSH 1.1 Phase 10B：Agent tab（UI Shell，mock provider，无网络/执行）。
            AgentSidebarView()
        }
    }
}
