import AppKit

/// MacSSH 1.1 Phase 8：应用外观模式（任务书 §45 Settings `## Appearance` 规范）。
///
/// 三态：
/// - `system`：跟随 macOS（`NSApp.appearance = nil`）
/// - `light`：强制浅色（`.aqua`）
/// - `dark`：强制深色（`.darkAqua`）
///
/// 与 `TerminalAppearanceProvider.Mode`（light/dark）严格区分：后者只描述终端
/// palette 的**已解析**具体模式；本枚举描述用户在 Settings 选择的**请求**
/// 模式，`system` 由 `NSApp.effectiveAppearance` 实时解析为 light/dark。
///
/// 语言无关：Appearance 与 Language 完全独立（任务书第一节），选项文案经
/// String Catalog 本地化，不使用 verbatim 母语名（外观模式无「切错语言找不到
/// 回入口」的陷阱）。
enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    /// 默认值：跟随系统。旧用户升级时若无偏好，保持原有跟随系统行为不变
    /// （任务书 §5：不能改变现有用户默认体验）。
    static let defaultMode: AppAppearanceMode = .system

    var id: Self { self }

    /// 映射到 `NSApp.appearance` 的具体值（任务书 §13）。
    /// - `system` → `nil`（跟随 macOS）
    /// - `light` → `.aqua`
    /// - `dark` → `.darkAqua`
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Picker 选项对应的 String Catalog key。
    ///
    /// 返回 `String`（非 `LocalizedStringKey`）以保持本枚举可独立单测，
    /// 且源码字面量供 `LocalizationTests.testCatalogHasNoObsoleteKeys` 的
    /// 扫描器识别——三个 key 必须在源码中被引用一次。
    var localizedOptionKey: String {
        switch self {
        case .system: "settings.appearance.system"
        case .light: "settings.appearance.light"
        case .dark: "settings.appearance.dark"
        }
    }

    /// 从偏好中恢复模式；未知 / 损坏 / future 值安全回退 `.system`，
    /// 绝不 Crash，不删除其他偏好（任务书 §8）。
    static func load(from defaults: UserDefaults) -> AppAppearanceMode {
        guard let storedValue = defaults.string(forKey: AppPreferenceKey.appearanceMode),
              let mode = AppAppearanceMode(rawValue: storedValue)
        else {
            return .defaultMode
        }
        return mode
    }

    /// 持久化公开枚举 rawValue，不保存任何敏感信息。
    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: AppPreferenceKey.appearanceMode)
    }
}
