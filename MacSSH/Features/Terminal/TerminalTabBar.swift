import SwiftUI

/// Terminal Tab Bar（Phase 8）：多 Session Tab、状态指示、关闭与新建。
///
/// 扩展自 Phase 2 的单 Tab 实现（沿用 accent 下划线 + 淡色背景的样式
/// 语言，不引入第二套 Tab Bar）；Tab 只是 Session 的展示（任务书 4/14），
/// 点击仅切换 activeSessionID，绝不重建 Session。
struct TerminalTabBar: View {
    @Environment(AppState.self) private var appState

    private var manager: SessionManager {
        appState.sessionManager
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.none) {
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
                .buttonStyle(.plain)
                .help("New Local Terminal")
                .accessibilityLabel("New Local Terminal")
                .accessibilityIdentifier("tabBar.newSession")
            }
        }
        .frame(height: AppTheme.Layout.tabBarHeight)
        .background(.bar)
        .accessibilityLabel("Terminal Tabs")
        .accessibilityIdentifier("tabBar")
    }

    private func newLocalSession() {
        appState.selectedSection = .terminal
        manager.createLocalSession()
    }
}

/// 单个 Tab：标题 + 连接状态指示（Remote）+ 关闭按钮。
private struct TerminalTabItemView: View {
    let session: ManagedTerminalSession
    let isActive: Bool
    let activate: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack(spacing: AppTheme.Spacing.compact) {
                statusIndicator

                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isActive ? AppTheme.accentColor : .secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Tab")
                .accessibilityLabel("Close \(session.title) Tab")
                .accessibilityIdentifier("tabBar.close")
            }
            .padding(.horizontal, AppTheme.Spacing.regular)
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(isActive ? AppTheme.accentColor : Color.clear)
                .frame(height: 2)
        }
        .foregroundStyle(isActive ? AppTheme.accentColor : Color.primary)
        .background(
            isActive
                ? AppTheme.accentColor.opacity(0.10)
                : Color.clear,
            // 活动底纹只能覆盖 Tab 自身，不能延伸到窗口标题栏安全区。
            ignoresSafeAreaEdges: []
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isActive ? "Selected" : "")
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

    private var accessibilityLabel: String {
        let kindText = session.kind == .local ? "Local Terminal" : "SSH Terminal"
        return "\(session.title) \(kindText)"
    }
}
