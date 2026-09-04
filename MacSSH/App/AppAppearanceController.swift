import AppKit
import Observation

/// MacSSH 1.1 Phase 8：应用外观控制器（任务书 §10）。
///
/// 单一 writer（任务书 §9）：应用外观偏好的读写只由本控制器进行。
/// SettingsView 的 Picker 绑定 `controller.mode`，写入经 `didSet` 持久化并
/// apply；不存在 SettingsView / AppState / 其他 View 各自写 UserDefaults 或
/// `@AppStorage` 的多 source of truth。
///
/// ## Source of truth 单一链（任务书 §11）
///
/// Persisted requested mode (`UserDefaults`) → `AppAppearanceController.mode`
/// → `NSApp.appearance` → `NSApp.effectiveAppearance` → `TerminalAppearanceCoordinator`
/// → per-TerminalView。不另外维护 `terminalAppearanceMode` /
/// `swiftUIColorScheme` / `windowAppearanceMode` 等第二套状态。
///
/// ## apply 两条路径共存（任务书 §15）
///
/// - 主路径（同步）：用户切 mode → `setMode`/`didSet` → 设置 `NSApp.appearance`
///   → 显式 `coordinator.applyCurrentAppearance()` → existing Terminal 立即刷新。
/// - 安全网（异步）：system mode 下 macOS Appearance 变化 →
///   `NSApp.effectiveAppearance` KVO（Coordinator 已有）→ Terminal refresh。
///
/// 显式 apply 的理由是避免 KVO 回调内 `Task { @MainActor in handler() }`
/// 的异步 hop（下一 runloop）造成 Settings 即时刷新延迟——**不是**「KVO
/// 不触发」（Phase 8A probe 确认 KVO 在 resolved 不变但 appearance 赋值
/// 不同时仍触发；文档须准确，任务书 §15）。
///
/// ## 不持有 TerminalView registry / 不重做 palette（任务书 §10）
///
/// TerminalView registry 与 Terminal color palette 全部复用 Phase 4
/// `TerminalAppearanceCoordinator`；本控制器只设置 `NSApp.appearance` 并
/// 通过 Coordinator 的受控入口触发刷新。
@MainActor
@Observable
final class AppAppearanceController {
    /// 偏好存储；只由本控制器读写 `appearanceMode` key（任务书 §9 单一 writer）。
    private let userDefaults: UserDefaults

    /// 终端外观协调器（Phase 4）；复用其 registry 与 KVO，不另建第二套。
    private let coordinator: TerminalAppearanceCoordinator

    /// 设置 `NSApp.appearance` 的接缝。生产读取 `NSApp`（nil 时 no-op，绝不
    /// Crash）；测试注入捕获闭包，确定性断言 nil / `.aqua` / `.darkAqua`，
    /// 不依赖真实 `NSApplication` 生命周期。
    private let appearanceSetter: @MainActor (NSAppearance?) -> Void

    /// Runtime requested mode（任务书 §11）。Picker 绑定本属性；写入经 `didSet`
    /// 持久化并 apply。`system` 不代表「当前 resolved 模式」，而是「请求跟随
    /// 系统」——Settings 行内值始终反映 requested mode，非 resolved
    /// （任务书 §31）。
    var mode: AppAppearanceMode {
        didSet {
            // 不做 resolved-mode 去重（任务书 §16 / §41）：即使 resolved
            // effectiveAppearance 未变化（如系统已 Dark、system→dark），显式
            // apply 仍须刷新全部已注册视图。requested mode 已改变即 apply。
            mode.save(to: userDefaults)
            apply()
        }
    }

    /// - Parameters:
    ///   - userDefaults: 偏好存储；只读写 `appearanceMode` key。
    ///   - coordinator: Phase 4 终端外观协调器；apply 时经其受控入口刷新
    ///     全部已注册 `TerminalView`。
    ///   - appearanceSetter: 设置 `NSApp.appearance` 的接缝；默认
    ///     `NSApp?.appearance = $0`（nil 时 no-op）。测试注入以断言映射。
    init(
        userDefaults: UserDefaults,
        coordinator: TerminalAppearanceCoordinator,
        appearanceSetter: @escaping @MainActor (NSAppearance?) -> Void = { NSApp?.appearance = $0 }
    ) {
        self.userDefaults = userDefaults
        self.coordinator = coordinator
        self.appearanceSetter = appearanceSetter
        // init 内赋值不触发 didSet（Swift 语义）；显式 apply 一次。
        self.mode = AppAppearanceMode.load(from: userDefaults)
        // 启动 apply：任何 Local/Remote Terminal 创建前 NSApp.appearance 已
        // 确定，首帧即为请求模式，避免 Light→Dark / Dark→Light 闪烁
        // （任务书 §18 / §20）。此时 Coordinator registry 为空，apply no-op。
        apply()
    }

    /// 显式设置 requested mode（任务书 §10）。经 `mode` setter → `didSet`
    /// 持久化并 apply。供非 SwiftUI 调用方与测试使用；SwiftUI Picker 直接
    /// 绑定 `$controller.mode` 同样走 `didSet`。
    func setMode(_ newMode: AppAppearanceMode) {
        mode = newMode
    }

    /// 应用当前 requested mode：设置 `NSApp.appearance` 并同步刷新全部已注册
    /// 终端视图（任务书 §13 / §14）。
    ///
    /// `@MainActor`：`NSApp.appearance` 与 `TerminalView` 颜色属性均 MainActor。
    func apply() {
        appearanceSetter(mode.nsAppearance)
        coordinator.applyCurrentAppearance()
    }
}
