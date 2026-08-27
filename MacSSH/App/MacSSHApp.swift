import SwiftUI

/// MacSSH 的应用入口，只负责装配全局状态和根视图。
@main
struct MacSSHApp: App {
    /// 全局状态独立于具体页面生命周期，并持有 Phase 2 本地 Terminal 会话。
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("MacSSH") {
            RootView()
                .environment(appState)
                .tint(AppTheme.accentColor)
        }
        .defaultSize(
            width: AppTheme.Window.defaultWidth,
            height: AppTheme.Window.defaultHeight
        )
    }
}
