import SwiftData
import SwiftUI

/// MacSSH 的应用入口，装配全局状态、SwiftData 容器和根视图。
@main
struct MacSSHApp: App {
    /// 全局状态独立于具体页面生命周期，并持有 Phase 2 本地 Terminal 会话。
    @State private var appState = AppState()

    /// Phase 3 使用本地持久化容器；不启用 CloudKit，也不保存任何 Secret。
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            Host.self,
            HostGroup.self
        ])
        let configuration = ModelConfiguration(
            "MacSSH",
            schema: schema,
            cloudKitDatabase: .none
        )

        do {
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            // 持久化不可用时不能降级为易丢失的内存 Mock 数据。
            fatalError("Unable to create the SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("MacSSH") {
            RootView()
                .environment(appState)
                .modelContainer(modelContainer)
                .tint(AppTheme.accentColor)
        }
        .defaultSize(
            width: AppTheme.Window.defaultWidth,
            height: AppTheme.Window.defaultHeight
        )
    }
}
