import SwiftUI

/// macOS 原生 Sidebar，只负责顶层页面选择。
struct AppSidebar: View {
    /// 与 AppState 双向绑定的页面选择。
    @Binding var selection: AppSection

    var body: some View {
        List(AppSection.allCases, selection: $selection) { section in
            Label {
                Text(section.titleKey)
            } icon: {
                Image(systemName: section.systemImage)
            }
                .tag(section)
                .accessibilityIdentifier("sidebar.\(section.rawValue)")
        }
        .listStyle(.sidebar)
        .navigationTitle("MacSSH")
        .navigationSplitViewColumnWidth(
            min: AppTheme.Layout.sidebarMinimumWidth,
            ideal: AppTheme.Layout.sidebarIdealWidth,
            max: AppTheme.Layout.sidebarMaximumWidth
        )
        .accessibilityLabel("accessibility.main_sidebar")
    }
}
