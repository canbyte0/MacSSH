import SwiftUI

/// Terminal Tab Bar（Phase 8）：多 Session Tab、状态指示、关闭与新建。
///
/// Tab 使用 macOS 原生动态色圆角矩形表达选中与未选中状态；
/// Tab 只是 Session 的展示（任务书 4/14），
/// 点击仅切换 activeSessionID，绝不重建 Session。
struct TerminalTabBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale
    // 探针和覆盖层共用一个原生控件，SwiftUI 更新时不重复创建。
    @State private var tabScrollbar = TerminalTabScrollbarProbe(accessibilityLabel: "")

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
                        // 透明留白也属于按钮，避免只有细小的加号图形能够命中。
                        .contentShape(Rectangle())
                }
                .buttonStyle(TerminalNewSessionButtonStyle())
                .help("terminal.new_local")
                .accessibilityLabel("terminal.new_local")
                .accessibilityIdentifier("tabBar.newSession")
            }
            // 为首尾标签留出与标签间距一致的边距，避免圆角紧贴容器边缘。
            .padding(.horizontal, AppTheme.Spacing.compact)
            .background {
                // 在原滚动容器内挂接细滚动条，不占用标签与正文的布局高度。
                TerminalTabScrollbarBridge(probe: tabScrollbar, accessibilityLabel: L10n.string(
                    "accessibility.terminal_tabs",
                    defaultValue: "Terminal tabs",
                    locale: locale
                ))
                .frame(width: 0, height: 0)
            }
        }
        .frame(height: AppTheme.Layout.tabBarHeight)
        .overlay(alignment: .bottom) {
            // 可见滑块仅 3 pt；底部 8 pt 覆盖层接收原生拖动，不占用正文高度。
            TerminalTabScrollbarTrack(probe: tabScrollbar)
                .frame(height: 8)
                .padding(.horizontal, AppTheme.Spacing.compact)
        }
        .background(.bar)
        .accessibilityLabel("accessibility.terminal_tabs")
        .accessibilityIdentifier("tabBar")
    }

    private func newLocalSession() {
        appState.selectedSection = .terminal
        manager.createLocalSession()
    }
}

/// 新增按钮使用 Button 自带的按压状态，避免为反馈额外注册零距离拖动手势。
/// 仅用于标签栏的新增入口，保持其他按钮的现有交互以及 28 pt 悬停底色。
private struct TerminalNewSessionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let hovering = isEnabled && isHovering
        let pressing = isEnabled && configuration.isPressed
        let scale = reduceMotion ? 1 : pressing
            ? AppTheme.ButtonInteraction.pressedScale
            : hovering ? AppTheme.ButtonInteraction.hoveredScale : 1
        let opacity = pressing
            ? AppTheme.ButtonInteraction.pressedBackgroundOpacity
            : hovering ? AppTheme.ButtonInteraction.hoverBackgroundOpacity : 0

        configuration.label
            .scaleEffect(scale)
            .background {
                Circle()
                    .fill(Color.primary.opacity(opacity))
                    .frame(
                        width: AppTheme.ButtonInteraction.compactIconBackgroundDiameter,
                        height: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
                    )
                    // 装饰底色不参与事件分发，点击仍由原生 Button 处理。
                    .allowsHitTesting(false)
            }
            // 缩放只影响视觉；42 × 42 pt 的完整命中区域保持稳定。
            .contentShape(Rectangle())
            .animation(
                reduceMotion ? nil : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
                value: hovering
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: AppTheme.ButtonInteraction.pressDuration),
                value: pressing
            )
            .onHover { isHovering = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovering = false }
            }
    }
}

/// 单个 Tab：标题 + 连接状态指示（Remote）+ 关闭按钮。
private struct TerminalTabItemView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var renameFieldFocused: Bool
    @State private var isRenaming = false
    @State private var renameDraft = ""

    let session: ManagedTerminalSession
    let isActive: Bool
    let activate: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.compact) {
            statusIndicator

            if isRenaming {
                // 原位编辑只改变当前 Session 的 Tab 别名，不重建终端运行时。
                TextField("terminal.rename_tab_placeholder", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .focused($renameFieldFocused)
                    .task {
                        // 原生菜单关闭时会把焦点还给终端；等菜单完成关闭后
                        // 再聚焦输入框，右键选择“重命名”即可直接输入。
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled, isRenaming else { return }
                        renameFieldFocused = true
                    }
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .onChange(of: renameFieldFocused) { _, isFocused in
                        if !isFocused && isRenaming { commitRename() }
                    }
                    .accessibilityIdentifier("tabBar.renameField")
            } else {
                Text(verbatim: session.tabTitle(locale: locale))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: session.customTabTitle == nil ? nil : 180, alignment: .leading)
                    .help(session.tabTitle(locale: locale))
            }

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
                        title: session.tabTitle(locale: locale),
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
        .onTapGesture {
            if !isRenaming { activate() }
        }
        .contextMenu {
            Button {
                beginRename()
            } label: {
                Label("terminal.rename_tab", systemImage: "pencil")
            }
            Button(role: .destructive, action: close) {
                Label("terminal.close_tab", systemImage: "xmark")
            }
        }
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

    /// 打开当前标签的编辑框；取消时仍可恢复显示原有名称。
    private func beginRename() {
        renameDraft = session.tabTitle(locale: locale)
        isRenaming = true
    }

    /// Enter 或失焦提交；非法名称保持原标签名。
    private func commitRename() {
        guard isRenaming else { return }
        session.renameTab(to: renameDraft)
        isRenaming = false
        renameFieldFocused = false
    }

    /// Esc 直接退出编辑，不改 Session 数据。
    private func cancelRename() {
        isRenaming = false
        renameFieldFocused = false
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
                    title: session.tabTitle(locale: locale),
                    locale: locale
                )
            )
        case .remoteSSH:
            Text(
                verbatim: TerminalAccessibilityText.sshTab(
                    title: session.tabTitle(locale: locale),
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
