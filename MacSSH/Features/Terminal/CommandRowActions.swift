import SwiftUI

/// MacSSH 1.1 Phase 7：命令行 hover 显示的 Paste / Run 动作按钮（共享组件）。
///
/// 任务书 §51 / §54 / Phase 7A 验收 §66–§67：
/// - 默认隐藏，hover 显示（视觉）；
/// - 但 keyboard focus / VoiceOver 仍可访问（`opacity(0)` 不移除 accessibility tree，
///   不设 `.focusable(false)`/`.accessibilityHidden(true)`）；
/// - Run 图标 `play.fill`，Paste 图标 `doc.on.clipboard`；
/// - 双语 tooltip + accessibilityLabel。
struct CommandRowActions: View {
    let onPaste: () -> Void
    let onExecute: () -> Void
    /// 当前是否有可写的 active terminal（disabled 时按钮置灰，任务书 §44）。
    var enabled: Bool = true

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: AppTheme.Spacing.compact) {
            Button(action: onPaste) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13))
            }
            .buttonStyle(AppInteractiveButtonStyle(
                baseStyle: BorderlessButtonStyle(),
                compactBackgroundDiameter: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
            ))
            .help(L10n.string("sidebar_right.paste", defaultValue: "Paste into Terminal", locale: locale))
            .accessibilityLabel(L10n.string("sidebar_right.paste", defaultValue: "Paste into Terminal", locale: locale))
            .accessibilityIdentifier("sidebar_right.paste")
            .disabled(!enabled)

            Button(action: onExecute) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(AppInteractiveButtonStyle(
                baseStyle: BorderlessButtonStyle(),
                compactBackgroundDiameter: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
            ))
            .help(L10n.string("sidebar_right.execute", defaultValue: "Run Command", locale: locale))
            .accessibilityLabel(L10n.string("sidebar_right.execute", defaultValue: "Run Command", locale: locale))
            .accessibilityIdentifier("sidebar_right.execute")
            .disabled(!enabled)
        }
    }
}
