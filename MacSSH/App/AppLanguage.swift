import Foundation

/// MacSSH 1.1 支持的应用语言。
///
/// 本阶段明确不跟随系统语言；无偏好或偏好损坏时始终回退简体中文。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let defaultLanguage: AppLanguage = .simplifiedChinese

    var id: Self { self }

    /// SwiftUI 根层注入的 Locale identifier，集中避免项目内散落语言代码。
    var locale: Locale {
        Locale(identifier: rawValue)
    }

    /// Picker 固定使用语言自己的名称，避免误切后无法识别切回入口。
    var displayName: String {
        switch self {
        case .simplifiedChinese:
            "简体中文"
        case .english:
            "English"
        }
    }

    /// 从简单偏好中恢复语言；未知值安全回退简体中文，不触发崩溃。
    static func load(from defaults: UserDefaults) -> AppLanguage {
        guard let storedValue = defaults.string(forKey: AppPreferenceKey.language),
              let language = AppLanguage(rawValue: storedValue)
        else {
            return .defaultLanguage
        }
        return language
    }

    /// 持久化公开枚举 rawValue，不保存任何敏感信息。
    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: AppPreferenceKey.language)
    }
}

/// 简单 App 偏好的集中 key，禁止在各 View 重复硬编码。
enum AppPreferenceKey {
    static let language = "appLanguage"
    /// MacSSH 1.1 Phase 7：右侧栏展开状态（Bool）。
    static let rightSidebarVisible = "macssh.rightSidebarVisible"
    /// MacSSH 1.1 Phase 7：右侧栏选中 tab（CommandSidebarTab rawValue）。
    static let rightSidebarTab = "macssh.rightSidebarTab"
    /// MacSSH 1.1 Phase 8：应用外观模式（AppAppearanceMode rawValue：system/light/dark）。
    static let appearanceMode = "macssh.appearanceMode"
    /// MacSSH 1.1 Phase 9：终端字号（Int，10...32，step 1，default 14）。
    static let terminalFontSize = "macssh.terminalFontSize"
    /// 本地 zsh 粘贴高亮偏好；未设置时关闭，新终端启动时读取。
    static let pasteHighlightEnabled = "macssh.pasteHighlightEnabled"
}

/// 非 SwiftUI 场景使用的集中本地化入口。
///
/// SwiftUI 静态文案直接使用稳定 String Catalog key；只有模型状态、错误映射
/// 或 AppKit API 需要 `String` 时才使用本工具并显式传入 Locale。
enum L10n {
    /// 稳定 key（`StaticString`）优先：编译器可在编译期校验 key 常量。
    static func string(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        locale: Locale
    ) -> String {
        String(
            localized: LocalizedStringResource(
                key,
                defaultValue: defaultValue,
                locale: locale,
                bundle: .main
            )
        )
    }

    /// 动态 key 入口：仅供 String Catalog 审计测试遍历 key 列表使用，
    /// 生产 UI 一律使用 `StaticString` 重载。
    ///
    /// `LocalizedStringResource` 只接受 `StaticString` key，因此动态 key
    /// 直接定位该语言的 `.lproj` 并在 `Localizable` 表中查找；未命中时
    /// 回退 `defaultValue`（审计测试传空串即可识别缺失翻译）。
    static func string(
        _ key: String,
        defaultValue: String.LocalizationValue,
        locale: Locale
    ) -> String {
        guard let bundle = localizationBundle(for: locale) else {
            return String(localized: defaultValue, locale: locale)
        }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        // 未命中时 Bundle 返回 key 本身——回退 defaultValue，绝不让 raw key
        // 通过本入口泄漏。
        return value == key ? String(localized: defaultValue, locale: locale) : value
    }

    /// 稳定 key（`StaticString`）优先：编译器可在编译期校验 key 常量。
    static func format(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        locale: Locale,
        arguments: CVarArg...
    ) -> String {
        String(
            format: string(key, defaultValue: defaultValue, locale: locale),
            locale: locale,
            arguments: arguments
        )
    }

    /// 动态 key 入口：仅供 String Catalog 审计测试遍历 key 列表使用。
    static func format(
        _ key: String,
        defaultValue: String.LocalizationValue,
        locale: Locale,
        arguments: CVarArg...
    ) -> String {
        let template = string(key, defaultValue: defaultValue, locale: locale)
        return String(format: template, locale: locale, arguments: arguments)
    }

    /// 定位主 Bundle 内指定语言的 `.lproj` 目录（String Catalog 编译产物）。
    private static func localizationBundle(for locale: Locale) -> Bundle? {
        guard let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
