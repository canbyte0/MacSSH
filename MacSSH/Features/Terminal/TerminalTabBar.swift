import SwiftUI

/// Terminal Tab Bar（Phase 8）：多 Session Tab、状态指示、关闭与新建。
///
/// Tab 使用 macOS 原生动态色圆角矩形表达选中与未选中状态；
/// Tab 只是 Session 的展示（任务书 4/14），
/// 点击仅切换 activeSessionID，绝不重建 Session。
struct TerminalTabBar: View {
    @Environment(AppState.self) private var appState

    private var manager: SessionManager {
        appState.sessionManager
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.compact) {
                ForEach(manager.sessions) { session in
                    TerminalTabItemView(
                        session: session,
                        isActive: session.id == manager.activeSessionID,
                        activate: {
                            manager.activateSession(id: session.id)
                        },
                        close: {
                            manager.requestClose(id: session.id)
                        }
                    )
                }

                Button(action: newLocalSession) {
                    Image(systemName: "plus")
                        .frame(width: AppTheme.Layout.tabBarHeight, height: AppTheme.Layout.tabBarHeight)
                }
                .buttonStyle(
                    AppInteractiveButtonStyle(
                        baseStyle: PlainButtonStyle(),
                        // 点击区域仍为完整 Tab Bar 高度，仅收紧可见悬停底色。
                        compactBackgroundDiameter: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
                    )
                )
                .help("terminal.new_local")
                .accessibilityLabel("terminal.new_local")
                .accessibilityIdentifier("tabBar.newSession")
            }
            // 为首尾标签留出与标签间距一致的边距，避免圆角紧贴容器边缘。
            .padding(.horizontal, AppTheme.Spacing.compact)
        }
        .frame(height: AppTheme.Layout.tabBarHeight)
        .background(.bar)
        .accessibilityLabel("accessibility.terminal_tabs")
        .accessibilityIdentifier("tabBar")
    }

    private func newLocalSession() {
        appState.selectedSection = .terminal
        manager.createLocalSession()
    }
}

/// 单个 Tab：标题 + 连接状态指示（Remote）+ 关闭按钮。
private struct TerminalTabItemView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: ManagedTerminalSession
    let isActive: Bool
    let activate: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.compact) {
            statusIndicator

            Text(verbatim: session.displayTitle(locale: locale))
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? AppTheme.accentColor : .secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AppInteractiveButtonStyle(baseStyle: PlainButtonStyle()))
            .help("terminal.close_tab")
            .accessibilityLabel(
                Text(
                    verbatim: TerminalAccessibilityText.closeTab(
                        title: session.displayTitle(locale: locale),
                        locale: locale
                    )
                )
            )
            .accessibilityIdentifier("tabBar.close")
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .frame(height: AppTheme.Layout.terminalTabHeight)
        .foregroundStyle(isActive ? AppTheme.accentColor : Color.primary)
        .background {
            RoundedRectangle(
                cornerRadius: AppTheme.Layout.terminalTabCornerRadius,
                style: .continuous
            )
            .fill(isActive ? AppTheme.accentColor.opacity(0.12) : Color.clear)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: AppTheme.Layout.terminalTabCornerRadius,
                style: .continuous
            )
            // 未选中标签使用轻量动态描边；选中标签使用当前强调色的浅色填充。
            .strokeBorder(isActive ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1)
        }
        // 42 - 34 = 8 pt，上下各 4 pt，确保四个圆角不被 Tab Bar 边缘裁切。
        .padding(.vertical, (AppTheme.Layout.tabBarHeight - AppTheme.Layout.terminalTabHeight) / 2)
        .contentShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Layout.terminalTabCornerRadius,
                style: .continuous
            )
        )
        .onTapGesture(perform: activate)
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
            value: isActive
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isActive ? Text("accessibility.selected") : Text(verbatim: ""))
        .accessibilityIdentifier("tabBar.\(session.title)")
    }

    /// 连接状态指示（任务书 14）：● Connected / ○ Disconnected /
    /// ◌ Connecting；Local 无指示点。
    @ViewBuilder
    private var statusIndicator: some View {
        switch session.kind {
        case .local:
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

        case .remoteSSH:
            switch session.displayState {
            case .active:
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)

            case .connecting, .authenticating, .awaitingHostTrust, .opening, .starting:
                Circle()
                    .stroke(AppTheme.accentColor, lineWidth: 1.5)
                    .frame(width: 7, height: 7)

            case .exited, .disconnected:
                Circle()
                    .stroke(.secondary, lineWidth: 1.5)
                    .frame(width: 7, height: 7)

            case .failed:
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)

            case .closing:
                Circle()
                    .stroke(.tertiary, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var accessibilityLabel: Text {
        switch session.kind {
        case .local:
            Text(
                verbatim: TerminalAccessibilityText.localTab(
                    title: session.displayTitle(locale: locale),
                    locale: locale
                )
            )
        case .remoteSSH:
            Text(
                verbatim: TerminalAccessibilityText.sshTab(
                    title: session.displayTitle(locale: locale),
                    locale: locale
                )
            )
        }
    }
}

/// Terminal 动态 Accessibility 文案的唯一格式化入口。
///
/// String Catalog 使用稳定的基础 key（例如 `terminal.close_named_tab`）并在
/// value 中声明 `%@`。不能写成 `Text("key \(value)")`，否则 SwiftUI 会把
/// 整段插值表达式当成另一个 key，最终让 VoiceOver 读出 `terminal.*`。
enum TerminalAccessibilityText {
    static func localTab(title: String, locale: Locale) -> String {
        L10n.format(
            "terminal.local_tab_accessibility",
            defaultValue: "Local terminal tab: %@",
            locale: locale,
            arguments: title
        )
    }

    static func sshTab(title: String, locale: Locale) -> String {
        L10n.format(
            "terminal.ssh_tab_accessibility",
            defaultValue: "SSH terminal tab: %@",
            locale: locale,
            arguments: title
        )
    }

    static func closeTab(title: String, locale: Locale) -> String {
        L10n.format(
            "terminal.close_named_tab",
            defaultValue: "Close tab: %@",
            locale: locale,
            arguments: title
        )
    }

    static func remoteTerminal(hostName: String, locale: Locale) -> String {
        L10n.format(
            "terminal.remote",
            defaultValue: "Remote Terminal: %@",
            locale: locale,
            arguments: hostName
        )
    }

    static func connectingTo(hostName: String, locale: Locale) -> String {
        L10n.format(
            "terminal.connecting_to",
            defaultValue: "Connecting to %@",
            locale: locale,
            arguments: hostName
        )
    }
}
