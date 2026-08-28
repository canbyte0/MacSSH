import CoreGraphics
import SwiftUI

/// 应用基础视觉令牌，全部使用系统动态颜色以自动适配明暗模式。
enum AppTheme {
    /// 应用的克制强调色；使用 SwiftUI 系统颜色，不绑定固定色值。
    static var accentColor: Color { .teal }

    /// 主窗口尺寸令牌。
    enum Window {
        static let defaultWidth: CGFloat = 1_120
        static let defaultHeight: CGFloat = 720
        static let minimumWidth: CGFloat = 760
        static let minimumHeight: CGFloat = 520
    }

    /// 主界面使用的间距令牌。
    enum Spacing {
        static let none: CGFloat = 0
        static let compact: CGFloat = 8
        static let regular: CGFloat = 16
        static let spacious: CGFloat = 24
    }

    /// NavigationSplitView 和底部状态栏尺寸。
    enum Layout {
        static let sidebarMinimumWidth: CGFloat = 180
        static let sidebarIdealWidth: CGFloat = 220
        static let sidebarMaximumWidth: CGFloat = 280
        static let hostSidebarMinimumWidth: CGFloat = 170
        static let hostSidebarIdealWidth: CGFloat = 190
        static let hostSidebarMaximumWidth: CGFloat = 240
        static let tabBarHeight: CGFloat = 42
        static let statusBarHeight: CGFloat = 28
    }
}
