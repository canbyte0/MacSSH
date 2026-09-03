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

        /// Terminal 内容与容器边缘之间的统一留白，单位为 macOS 逻辑点。
        static let terminalContentInset: CGFloat = 6
    }

    /// 应用内按钮交互动画参数，集中管理以保持所有功能页一致。
    enum ButtonInteraction {
        static let hoveredScale: CGFloat = 1.04
        static let pressedScale: CGFloat = 0.97
        static let hoverBackgroundOpacity = 0.07
        static let pressedBackgroundOpacity = 0.12
        static let backgroundOutset: CGFloat = 3
        static let hoverDuration = 0.12
        static let pressDuration = 0.08
    }
}

/// 在不替换原生按钮外观的前提下，为任意 PrimitiveButtonStyle 增加统一交互动画。
///
/// 内层 Button 继续使用调用方传入的 `.automatic`、`.plain`、`.borderless`
/// 或 `.bordered` 样式，因此按钮角色、键盘操作、颜色和边框语义保持不变。
struct AppInteractiveButtonStyle<BaseStyle: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let baseStyle: BaseStyle

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(baseStyle)
        .modifier(AppButtonInteractionModifier())
    }
}

/// 每个按钮独立维护悬停和按压状态；禁用按钮不响应动画。
private struct AppButtonInteractionModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    @GestureState private var isPressing = false

    func body(content: Content) -> some View {
        let hovering = isEnabled && isHovering
        let pressing = isEnabled && isPressing
        let scale = interactionScale(hovering: hovering, pressing: pressing)
        let backgroundOpacity = interactionBackgroundOpacity(
            hovering: hovering,
            pressing: pressing
        )

        content
            .scaleEffect(scale)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
                    // 负 padding 只扩大可见底色，不改变按钮原有布局尺寸。
                    .padding(-AppTheme.ButtonInteraction.backgroundOutset)
            }
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
                value: hovering
            )
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: AppTheme.ButtonInteraction.pressDuration),
                value: pressing
            )
            .onHover { hovering in
                isHovering = isEnabled && hovering
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    isHovering = false
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressing) { _, state, _ in
                        state = isEnabled
                    }
            )
    }

    /// Reduce Motion 开启时保留状态底色，但不执行缩放动画。
    private func interactionScale(hovering: Bool, pressing: Bool) -> CGFloat {
        guard !reduceMotion else {
            return 1
        }
        if pressing {
            return AppTheme.ButtonInteraction.pressedScale
        }
        return hovering ? AppTheme.ButtonInteraction.hoveredScale : 1
    }

    private func interactionBackgroundOpacity(hovering: Bool, pressing: Bool) -> Double {
        if pressing {
            return AppTheme.ButtonInteraction.pressedBackgroundOpacity
        }
        return hovering ? AppTheme.ButtonInteraction.hoverBackgroundOpacity : 0
    }
}
