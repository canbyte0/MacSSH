import SwiftData
import SwiftUI

/// MacSSH 的应用入口，装配全局状态、SwiftData 容器和根视图。
@main
struct MacSSHApp: App {
    /// 全局状态独立于具体页面生命周期，持有本地 Terminal 与 SSH 连接。
    @State private var appState: AppState

    /// 使用本地持久化容器；Secret 只进入 Keychain，不进入 SwiftData 或 CloudKit。
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

        _appState = State(initialValue: AppState(modelContainer: modelContainer))
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
