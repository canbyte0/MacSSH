import SwiftUI

/// Terminal 页面（Phase 8）：Tab Bar + Active Session 终端内容。
///
/// Session 由 SessionManager（AppState）持有，切换 Tab 只改变展示
/// （`.id(session.id)` 保证切换时挂接正确 Session 的 TerminalView；
/// TerminalView 对象由各 Service 持有，脱离视图层级时 buffer 继续接收
/// 后台输出且不产生渲染开销）。
struct TerminalWorkspaceView: View {
    @Environment(AppState.self) private var appState

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
            "Pane",
            selection: Binding(
                get: { session.activePane },
                set: { session.selectPane($0) }
            )
        ) {
            Text("Terminal")
                .tag(WorkspacePane.terminal)

            Text("Files")
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
    @ViewBuilder
    private func terminalView(for session: ManagedTerminalSession) -> some View {
        switch session.kind {
        case .local:
            if let service = session.localService {
                TerminalRepresentable(service: service)
                    .id(session.id)
            }

        case .remoteSSH:
            if let service = session.remoteService {
                RemoteTerminalRepresentable(service: service)
                    .id(session.id)
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
                    "Shell exited",
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
                    sessionBanner("Remote shell exited", session: session, showsReconnect: true)
                case .disconnected:
                    sessionBanner("Connection lost", session: session, showsReconnect: true)
                case let .failed(message):
                    sessionBanner(
                        message ?? "Connection failed",
                        session: session,
                        showsReconnect: true
                    )
                case .connecting, .authenticating, .awaitingHostTrust:
                    // Reconnect 进行中：保留终端历史，仅提示进度。
                    sessionBanner(
                        session.statusText,
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

                Text("Connection Failed")
                    .font(.headline)

                Text(session.failureMessage ?? "The connection could not be established.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppTheme.Spacing.spacious)

                HStack(spacing: AppTheme.Spacing.regular) {
                    Button("Retry") {
                        manager.reconnectSession(id: session.id)
                    }
                    .accessibilityIdentifier("terminal.retry")

                    Button("Close", role: .destructive) {
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
                Text("Closing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        default:
            VStack(spacing: AppTheme.Spacing.regular) {
                ProgressView()

                Text(session.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Connecting to \(session.hostDisplayName ?? "")")
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
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                if showsReconnect && session.canReconnect {
                    Button("Reconnect") {
                        manager.reconnectSession(id: session.id)
                    }
                    .accessibilityIdentifier("terminal.reconnect")
                }

                Button("Close", role: .destructive) {
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
            Label("No Terminal Sessions", systemImage: "terminal")
        } description: {
            Text("Create a terminal to get started.")
        } actions: {
            Button("New Terminal") {
                manager.createLocalSession()
            }
            .accessibilityIdentifier("terminal.new")
        }
    }

    private var navigationTitle: String {
        guard let session = manager.activeSession else {
            return "Terminal"
        }
        switch session.kind {
        case .local:
            return "Local Terminal"
        case .remoteSSH:
            return "SSH · \(session.hostDisplayName ?? session.hostname ?? "Remote")"
        }
    }
}
