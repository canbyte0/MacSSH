import SwiftUI

/// Terminal 页面（Phase 8）：Tab Bar + Active Session 终端内容。
///
/// Session 由 SessionManager（AppState）持有，切换 Tab 只改变展示
/// （`.id(session.id)` 保证切换时挂接正确 Session 的 TerminalView；
/// TerminalView 对象由各 Service 持有，脱离视图层级时 buffer 继续接收
/// 后台输出且不产生渲染开销）。
struct TerminalWorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale

    private var manager: SessionManager {
        appState.sessionManager
    }

    var body: some View {
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
        .navigationTitle(navigationTitle)
        .accessibilityIdentifier("workspace.terminal")
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
        .padding(.vertical, AppTheme.Spacing.compact / 2)
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
            }

        case .remoteSSH:
            if let service = session.remoteService {
                RemoteTerminalRepresentable(service: service)
                    .id(session.id)
                    .accessibilityLabel(
                        Text("terminal.remote \(session.hostDisplayName ?? session.hostname ?? "")")
                    )
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
                Text("terminal.connecting_to \(session.hostDisplayName ?? "")")
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
                defaultValue: "Local Terminal",
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
