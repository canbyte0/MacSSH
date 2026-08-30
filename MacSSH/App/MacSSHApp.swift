import AppKit
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
        // Phase 5.1：启动时记录一次非敏感的依赖安全基线身份（libssh2 pinned commit 与
        // OpenSSL 版本）。该引用同时把 build-generated 身份常量编译进 App 二进制，
        // 使 strings/otool 可直接验证 App 链接的依赖与 MANIFEST pin 一致。
        AppLogger.app.info(
            "dependency baseline: libssh2 \(MACSSH_LIBSSH2_VERSION, privacy: .public) @ \(MACSSH_LIBSSH2_COMMIT, privacy: .public) (OpenSSL \(MACSSH_OPENSSL_VERSION, privacy: .public))"
        )

        let schema = Schema([
            Host.self,
            HostGroup.self,
            KnownHost.self
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
        .commands {
            terminalCommands
        }
    }

    /// Phase 8 快捷键（任务书 32~35）：⌘T 新建 Local、⌘W 关闭 Active、
    /// ⌘1~⌘9 切换 Tab（只切换，不触发连接 / 重建 Shell）。
    ///
    /// SwiftUI 的 `CommandGroupPlacement` 没有 Close Window 分组；系统
    /// "Close Window ⌘W" 与 "New Tab ⌘T" 都在 File 菜单的 `.newItem` 组。
    /// 整体替换该组即可覆盖 ⌘W 并移除系统 ⌘T（避免与新建 Local 冲突）。
    @CommandsBuilder
    private var terminalCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            // ⌘W：有 Session 时关闭 Active Terminal（走确认流程），
            // 无 Session 时保持系统语义（关闭窗口）。
            Button("Close") {
                let manager = appState.sessionManager
                if manager.sessions.isEmpty {
                    NSApp.keyWindow?.performClose(nil)
                } else if let active = manager.activeSession {
                    manager.requestClose(id: active.id)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandMenu("Terminal") {
            Button("New Local Terminal") {
                appState.selectedSection = .terminal
                appState.sessionManager.createLocalSession()
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            // ⌘1~⌘9：按创建顺序激活对应 Tab。
            ForEach(1..<10, id: \.self) { index in
                Button("Show Tab \(index)") {
                    appState.selectedSection = .terminal
                    appState.sessionManager.activateTab(at: index - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
    }
}
