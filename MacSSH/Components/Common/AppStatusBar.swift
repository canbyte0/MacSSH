import SwiftUI

/// 主窗口底部的轻量状态栏，Terminal 页面展示运行状态和 PTY 尺寸。
struct AppStatusBar: View {
    let statusText: String
    let detailText: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.compact) {
            Text(statusText)

            Spacer()

            Text(detailText)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppTheme.Spacing.regular)
        .frame(height: AppTheme.Layout.statusBarHeight)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statusBar")
    }
}
