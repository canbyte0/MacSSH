import AppKit
import SwiftData
import SwiftUI

/// MacSSH 的应用入口，装配全局状态、SwiftData 容器和根视图。
@main
struct MacSSHApp: App {
    /// 全局状态独立于具体页面生命周期，持有本地 Terminal 与 SSH 连接。
    @State private var appState: AppState

    /// Phase 11 退出屏障（任务书三十五）：退出前取消并等待全部传输收尾，
    /// 不做后台继续传输，无崩溃 / 无 double-free。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 使用本地持久化容器；Secret 只进入 Keychain，不进入 SwiftData 或 CloudKit。
    private let modelContainer: ModelContainer

    init() {
        // MacSSH 1.1 Phase 2 字体方案：在 App 启动早期注册 App Bundle 内的
        // JetBrains Mono（位于 Contents/Resources/）。注册是幂等的。
        // 失败不 Crash（保留 monospaced fallback），但视为 packaging defect，
        // 测试必须 FAIL。
        TerminalFontProvider.registerBundledFontsIfNeeded()

        // Phase 5.1：启动时记录一次非敏感的依赖安全基线身份（libssh2 pinned commit 与
        // OpenSSL 版本）。该引用同时把 build-generated 身份常量编译进 App 二进制，
        // 使 strings/otool 可直接验证 App 链接的依赖与 MANIFEST pin 一致。
        AppLogger.app.info(
            "dependency baseline: libssh2 \(MACSSH_LIBSSH2_VERSION, privacy: .public) @ \(MACSSH_LIBSSH2_COMMIT, privacy: .public) (OpenSSL \(MACSSH_OPENSSL_VERSION, privacy: .public))"
        )

        let schema = Schema([
            Host.self,
            HostGroup.self,
            KnownHost.self,
            // MacSSH 1.1 Phase 7：命令侧边栏 SwiftData model。
            // 新增 model 属 additive lightweight migration（不改现有 model 字段）；
            // on-disk 迁移测试（SwiftDataMigrationTests）证明现有数据保留。
            // MacSSH 1.1 Phase 7：命令侧边栏 SwiftData model。
            // 类名 SavedCommandGroup 避免与 SwiftUI CommandGroup 碰撞。
            SavedCommandGroup.self,
            SavedCommand.self,
            CommandHistoryEntry.self
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
        // Phase 11 退出屏障装配：AppDelegate 需要访问 TransferManager，
        // 窗口层级反查不可靠，改用弱引用静态注入。
        AppDelegate.appState = _appState.wrappedValue
    }

    var body: some Scene {
        WindowGroup("MacSSH") {
            RootView()
                .environment(appState)
                .modelContainer(modelContainer)
                .tint(AppTheme.accentColor)
                // 在 WindowGroup 根部统一覆盖默认 Button，确保 Toolbar 与 Sheet 也继承动画。
                .buttonStyle(AppInteractiveButtonStyle(baseStyle: DefaultButtonStyle()))
        }
        .defaultSize(
            width: AppTheme.Window.defaultWidth,
            height: AppTheme.Window.defaultHeight
        )
        .commands {
            terminalCommands
        }
    }

    /// Phase 11 App Quit 屏障（任务书三十五）：
    /// `applicationShouldTerminate` 返回 `.terminateLater` 阻断默认退出流程 →
    /// 取消全部传输（pending 直接终态 / running 协作式取消）并等待执行任务收尾 →
    /// `reply(.terminateNow)` 完成退出。期间绝不后台继续传输。
    @MainActor
    final class AppDelegate: NSObject, NSApplicationDelegate {
        /// 应用入口装配的弱引用（App 生命周期内唯一，仅退出屏障读取）。
        static weak var appState: AppState?

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            guard let manager = AppDelegate.appState?.transferManager else {
                return .terminateNow
            }
            let hasPending = manager.tasks.contains { $0.state == .pending }
            guard manager.hasActiveTransfer || hasPending else {
                return .terminateNow
            }
            Task { @MainActor in
                await manager.cancelAndAwaitAllTransfers()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
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
            Button {
                let manager = appState.sessionManager
                if manager.sessions.isEmpty {
                    NSApp.keyWindow?.performClose(nil)
                } else if let active = manager.activeSession {
                    manager.requestClose(id: active.id)
                }
            } label: {
                Text(verbatim: L10n.string(
                    "action.close",
                    defaultValue: "Close",
                    locale: appState.language.locale
                ))
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandMenu(L10n.string(
            "menu.terminal",
            defaultValue: "Terminal",
            locale: appState.language.locale
        )) {
            Button {
                appState.selectedSection = .terminal
                appState.sessionManager.createLocalSession()
            } label: {
                Text(verbatim: L10n.string(
                    "terminal.new_local",
                    defaultValue: "New Local Terminal",
                    locale: appState.language.locale
                ))
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            // ⌘1~⌘9：按创建顺序激活对应 Tab。
            ForEach(1..<10, id: \.self) { index in
                Button {
                    appState.selectedSection = .terminal
                    appState.sessionManager.activateTab(at: index - 1)
                } label: {
                    Text(verbatim: L10n.format(
                        "terminal.show_tab",
                        defaultValue: "Show Tab %lld",
                        locale: appState.language.locale,
                        arguments: Int64(index)
                    ))
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
    }
}
