import SwiftUI

/// Terminal 页面：Local Terminal（Phase 2）；Remote SSH Terminal 会话
/// 存在期间直接占用整个工作区展示（Phase 7）。
///
/// Local/SSH Tab、Close、Switch、Reconnect 属于计划书 Phase 8，
/// 本阶段不提供 Tab 化管理：Remote 会话的收起由连接生命周期驱动
/// （Hosts 页断开主机，或再次 Open Terminal 替换）。
struct TerminalWorkspaceView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            // Remote 会话占用整个工作区时隐藏 Tab Bar（Tab 切换属 Phase 8）。
            if appState.remoteTerminalService == nil {
                TerminalTabBar()

                Divider()
            }

            terminalContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(navigationTitle)
        .accessibilityIdentifier("workspace.terminal")
    }

    /// 当前展示的终端内容；会话由 AppState 持有，切换 Sidebar 不销毁 Shell。
    @ViewBuilder
    private var terminalContent: some View {
        if let remote = appState.remoteTerminalService {
            RemoteTerminalRepresentable(service: remote)
        } else {
            TerminalRepresentable(service: appState.localTerminalService)
        }
    }

    private var navigationTitle: String {
        appState.remoteTerminalService.map { "SSH · \($0.session.hostname)" }
            ?? "Local Terminal"
    }
}
