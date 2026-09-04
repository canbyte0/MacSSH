import AppKit
import SwiftUI

/// 右侧栏宽度约束的纯计算策略，供界面与单元测试共同使用。
enum RightSidebarWidthPolicy {
    /// 当前可用宽度下的动态上限；窗口足够宽时仍受设计最大值限制。
    static func maximumWidth(availableWidth: CGFloat) -> CGFloat {
        let widthPreservingTerminal = availableWidth
            - AppTheme.Layout.terminalMinimumWidthBesideSidebar
            - AppTheme.Layout.rightSidebarResizeHandleWidth

        return min(
            AppTheme.Layout.rightSidebarMaximumWidth,
            max(AppTheme.Layout.rightSidebarMinimumWidth, widthPreservingTerminal)
        )
    }

    /// 把建议宽度限制在静态下限与当前窗口的动态上限之间。
    static func clamp(_ proposedWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        min(
            max(proposedWidth, AppTheme.Layout.rightSidebarMinimumWidth),
            maximumWidth(availableWidth: availableWidth)
        )
    }
}

/// Terminal 页面（Phase 8）：Tab Bar + Active Session 终端内容。
///
/// Session 由 SessionManager（AppState）持有，切换 Tab 只改变展示
/// （`.id(session.id)` 保证切换时挂接正确 Session 的 TerminalView；
/// TerminalView 对象由各 Service 持有，脱离视图层级时 buffer 继续接收
/// 后台输出且不产生渲染开销）。
struct TerminalWorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 一次拖动开始时的宽度，用于避免增量事件累积误差。
    @State private var rightSidebarDragStartWidth: CGFloat?

    private var manager: SessionManager {
        appState.sessionManager
    }

    var body: some View {
        @Bindable var appState = appState

        GeometryReader { proxy in
            let sidebarWidth = RightSidebarWidthPolicy.clamp(
                appState.rightSidebarWidth,
                availableWidth: proxy.size.width
            )

            HStack(spacing: AppTheme.Spacing.none) {
                // 左/中：现有 Tab Bar + paneSelector + workspace content。
                // 展开右侧栏时此部分真实缩窄，SwiftTerm setFrameSize 触发
                // cols/rows 重算 → PTY/SSH resize（任务书 §1 / §60 / §63）。
                VStack(spacing: AppTheme.Spacing.none) {
                    TerminalTabBar()

                    Divider()

                    if let session = manager.activeSession {
                        paneSelector(for: session)

                        Divider()
                    }

                    workspaceContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 右侧命令侧边栏：整体保留原有开合 transition，左边缘支持拖动。
                if appState.isRightSidebarVisible {
                    HStack(spacing: AppTheme.Spacing.none) {
                        rightSidebarResizeHandle(
                            sidebarWidth: sidebarWidth,
                            availableWidth: proxy.size.width
                        )

                        TerminalRightSidebarView(width: sidebarWidth)
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            // 只让可见状态触发开合动画；拖动宽度时必须实时跟手，不插值延迟。
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: AppTheme.SidebarMotion.duration),
                value: appState.isRightSidebarVisible
            )
        }
        .navigationTitle(navigationTitle)
        .accessibilityIdentifier("workspace.terminal")
    }

    /// 7 pt 透明热区覆盖系统 1 pt 分隔线，兼顾易拖动与原生外观。
    private func rightSidebarResizeHandle(
        sidebarWidth: CGFloat,
        availableWidth: CGFloat
    ) -> some View {
        RightSidebarResizeHandle(
            onDragChanged: { translationX in
                if rightSidebarDragStartWidth == nil {
                    rightSidebarDragStartWidth = sidebarWidth
                }
                guard let startWidth = rightSidebarDragStartWidth else { return }

                // 分隔线向左移动（负位移）应增大右侧栏宽度。
                appState.rightSidebarWidth = RightSidebarWidthPolicy.clamp(
                    startWidth - translationX,
                    availableWidth: availableWidth
                )
            },
            onDragEnded: {
                rightSidebarDragStartWidth = nil
            }
        )
        .frame(width: AppTheme.Layout.rightSidebarResizeHandleWidth)
        .overlay {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                // 顶部图标栏不绘制竖线；从第一条横向 Divider 开始显示侧栏边界。
                // 仅缩短可见线条，完整的 7 pt 拖动热区保持不变。
                .padding(.top, AppTheme.Layout.tabBarHeight)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(verbatim: L10n.string(
                "sidebar_right.resize",
                defaultValue: "Resize Sidebar",
                locale: locale
            ))
        )
        .accessibilityValue(Text(verbatim: "\(Int(sidebarWidth.rounded())) pt"))
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat
            switch direction {
            case .increment:
                delta = AppTheme.Layout.rightSidebarKeyboardResizeStep
            case .decrement:
                delta = -AppTheme.Layout.rightSidebarKeyboardResizeStep
            @unknown default:
                return
            }

            appState.rightSidebarWidth = RightSidebarWidthPolicy.clamp(
                sidebarWidth + delta,
                availableWidth: availableWidth
            )
        }
        .accessibilityIdentifier("workspace.rightSidebar.resizeHandle")
    }

    /// Phase 9：per-session 的 Terminal / Files 分段控制。
    ///
    /// 切换只改变展示：Terminal 缓冲与 SFTP 运行时都保持存活。
    /// Local Session 的 Files 段禁用（文件浏览仅对 SSH 会话可用）。
    private func paneSelector(for session: ManagedTerminalSession) -> some View {
        Picker(
            "terminal.pane",
            selection: Binding(
                get: { session.activePane },
                set: { session.selectPane($0) }
            )
        ) {
            Text("terminal.pane")
                .tag(WorkspacePane.terminal)

            Text("files.title")
                .tag(WorkspacePane.files)
                .disabled(session.kind == .local)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, AppTheme.Spacing.regular)
        // 与右侧栏内容标题共用固定高度，保证第二条 Divider 横向对齐。
        .frame(height: AppTheme.Layout.terminalSecondaryBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("workspace.paneSelector")
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if let session = manager.activeSession {
            if session.kind == .remoteSSH, session.activePane == .files {
                SFTPBrowserView(session: session)
                    .id(session.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    terminalView(for: session)

                    sessionOverlay(for: session)
                }
            }
        } else {
            emptyWorkspace
        }
    }

    /// Active Session 的终端内容；同一 Session 内 View 保持稳定。
    ///
    /// Accessibility 标签在 SwiftUI 层按当前注入的 Locale 覆盖
    /// Service 层（AppKit）设置的英文默认值——语言切换立即生效，
    /// 且不在 Service 层注入语言状态（任务书十七：语言状态单一来源）。
    @ViewBuilder
    private func terminalView(for session: ManagedTerminalSession) -> some View {
        switch session.kind {
        case .local:
            if let service = session.localService {
                TerminalRepresentable(service: service)
                    .id(session.id)
                    .accessibilityLabel("terminal.local")
                    // 缩小 SwiftTerm 的真实 frame，使其自动按留白后的尺寸同步 PTY。
                    .padding(AppTheme.Layout.terminalContentInset)
                    .background(Color(nsColor: .textBackgroundColor))
            }

        case .remoteSSH:
            if let service = session.remoteService {
                RemoteTerminalRepresentable(service: service)
                    .id(session.id)
                    .accessibilityLabel(
                        Text(
                            verbatim: TerminalAccessibilityText.remoteTerminal(
                                hostName: session.hostDisplayName ?? session.hostname ?? "",
                                locale: locale
                            )
                        )
                    )
                    // Local / Remote 共用统一留白，行列计算仍由 SwiftTerm 负责。
                    .padding(AppTheme.Layout.terminalContentInset)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    // MARK: - 状态浮层

    /// 连接中 / 失败占位（尚无终端内容）与终态底栏（保留终端历史，
    /// 任务书 22/25/38）。
    @ViewBuilder
    private func sessionOverlay(for session: ManagedTerminalSession) -> some View {
        switch session.kind {
        case .local:
            if case .exited = session.displayState {
                sessionBanner(
                    L10n.string(
                        "terminal.shell_exited",
                        defaultValue: "Shell exited",
                        locale: locale
                    ),
                    session: session,
                    showsReconnect: false
                )
            }

        case .remoteSSH:
            if session.remoteService == nil {
                remotePlaceholder(for: session)
            } else {
                switch session.displayState {
                case .exited:
                    sessionBanner(
                        L10n.string(
                            "terminal.remote_shell_exited",
                            defaultValue: "Remote shell exited",
                            locale: locale
                        ),
                        session: session,
                        showsReconnect: true
                    )
                case .disconnected:
                    sessionBanner(
                        L10n.string(
                            "terminal.connection_lost",
                            defaultValue: "Connection lost",
                            locale: locale
                        ),
                        session: session,
                        showsReconnect: true
                    )
                case let .failed(message):
                    sessionBanner(
                        message ?? L10n.string(
                            "terminal.connection_failed",
                            defaultValue: "Connection failed",
                            locale: locale
                        ),
                        session: session,
                        showsReconnect: true
                    )
                case .connecting, .authenticating, .awaitingHostTrust:
                    // Reconnect 进行中：保留终端历史，仅提示进度。
                    sessionBanner(
                        session.statusText(locale: locale),
                        session: session,
                        showsReconnect: false
                    )
                case .starting, .opening, .active, .closing:
                    EmptyView()
                }
            }
        }
    }

    /// 尚未建立终端（首次连接中 / 失败）的占位内容。
    @ViewBuilder
    private func remotePlaceholder(for session: ManagedTerminalSession) -> some View {
        switch session.displayState {
        case .failed, .disconnected:
            VStack(spacing: AppTheme.Spacing.regular) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(Color.red)

                Text("terminal.connection_failed")
                    .font(.headline)

                Text(verbatim: session.localizedFailureMessage(locale: locale) ?? L10n.string(
                    "terminal.connection_failed_message",
                    defaultValue: "The connection could not be established.",
                    locale: locale
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppTheme.Spacing.spacious)

                HStack(spacing: AppTheme.Spacing.regular) {
                    Button("action.retry") {
                        manager.reconnectSession(id: session.id)
                    }
                    .accessibilityIdentifier("terminal.retry")

                    Button("action.close", role: .destructive) {
                        manager.requestClose(id: session.id)
                    }
                    .accessibilityIdentifier("terminal.close")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

        case .closing:
            VStack {
                ProgressView()
                Text("terminal.closing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        default:
            VStack(spacing: AppTheme.Spacing.regular) {
                ProgressView()

                Text(verbatim: session.statusText(locale: locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(
                Text(
                    verbatim: TerminalAccessibilityText.connectingTo(
                        hostName: session.hostDisplayName ?? "",
                        locale: locale
                    )
                )
            )
        }
    }

    /// 终端底部状态条：终态提示 + Reconnect / Close（不遮挡终端历史）。
    private func sessionBanner(
        _ text: String,
        session: ManagedTerminalSession,
        showsReconnect: Bool
    ) -> some View {
        VStack(spacing: AppTheme.Spacing.none) {
            Spacer()

            HStack(spacing: AppTheme.Spacing.regular) {
                Text(verbatim: text)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                if showsReconnect && session.canReconnect {
                    Button("action.reconnect") {
                        manager.reconnectSession(id: session.id)
                    }
                    .accessibilityIdentifier("terminal.reconnect")
                }

                Button("action.close", role: .destructive) {
                    manager.requestClose(id: session.id)
                }
                .accessibilityIdentifier("terminal.close")
            }
            .padding(.horizontal, AppTheme.Spacing.regular)
            .padding(.vertical, AppTheme.Spacing.compact)
            .background(.bar)
        }
    }

    /// 全部 Session 关闭后的空工作区（任务书 17/55）。
    private var emptyWorkspace: some View {
        ContentUnavailableView {
            Label("terminal.no_sessions", systemImage: "terminal")
        } description: {
            Text("terminal.empty_message")
        } actions: {
            Button("terminal.new") {
                manager.createLocalSession()
            }
            .accessibilityIdentifier("terminal.new")
        }
    }

    private var navigationTitle: String {
        guard let session = manager.activeSession else {
            return L10n.string(
                "terminal.title",
                defaultValue: "Terminal",
                locale: locale
            )
        }
        switch session.kind {
        case .local:
            return L10n.string(
                "terminal.local_title",
                defaultValue: "Terminal",
                locale: locale
            )
        case .remoteSSH:
            return L10n.format(
                "terminal.ssh_title",
                defaultValue: "SSH · %@",
                locale: locale,
                arguments: session.hostDisplayName ?? session.hostname ?? "Remote"
            )
        }
    }
}

/// AppKit 原生拖动热区。
///
/// 使用 cursor rect 而不是手动 push/pop 光标：鼠标离开热区后 AppKit 会自动
/// 恢复 Terminal 的 I-beam 或其他控件自己的光标，避免光标状态泄漏。
private struct RightSidebarResizeHandle: NSViewRepresentable {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> RightSidebarResizeHandleView {
        let view = RightSidebarResizeHandleView()
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: RightSidebarResizeHandleView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }
}

/// 以 window 坐标计算整次拖动位移，窗口布局更新不会造成跳变。
private final class RightSidebarResizeHandleView: NSView {
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStartX: CGFloat?

    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onDragChanged?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onDragEnded?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}
