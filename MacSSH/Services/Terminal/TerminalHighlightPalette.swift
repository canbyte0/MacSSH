import AppKit

/// MacSSH 1.1 Phase 6：高亮预设颜色的 Light / Dark 调色板。
///
/// - 只做 **background decoration**（半透明），不改变任何前景色；
/// - 半透明让 ANSI background 透出，减少对原终端着色的破坏；
/// - Light / Dark 各一套 sRGB 值，保证两种外观下都可读；
/// - 高亮色在渲染时按当前 Appearance 即时解析（无缓存），Light/Dark 切换
///   由既有 `TerminalAppearanceCoordinator` 的全量重绘广播带动重新解析。
enum TerminalHighlightPalette {

    /// sRGB 分量（0...255）+ alpha（0...1）。
    struct RGBA: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    /// 预设颜色在指定外观下的半透明背景值。
    static func rgba(for color: TerminalHighlightColor, dark: Bool) -> RGBA {
        switch (color, dark) {
        case (.red, false):      RGBA(red: 255, green: 80, blue: 80, alpha: 0.35)
        case (.red, true):       RGBA(red: 255, green: 99, blue: 99, alpha: 0.30)
        case (.orange, false):   RGBA(red: 255, green: 149, blue: 0, alpha: 0.35)
        case (.orange, true):    RGBA(red: 255, green: 159, blue: 10, alpha: 0.30)
        case (.yellow, false):   RGBA(red: 255, green: 204, blue: 0, alpha: 0.35)
        case (.yellow, true):    RGBA(red: 255, green: 214, blue: 10, alpha: 0.30)
        case (.green, false):    RGBA(red: 52, green: 199, blue: 89, alpha: 0.35)
        case (.green, true):     RGBA(red: 48, green: 209, blue: 88, alpha: 0.30)
        case (.blue, false):     RGBA(red: 10, green: 132, blue: 255, alpha: 0.35)
        case (.blue, true):      RGBA(red: 10, green: 132, blue: 255, alpha: 0.30)
        case (.purple, false):   RGBA(red: 175, green: 82, blue: 222, alpha: 0.35)
        case (.purple, true):    RGBA(red: 191, green: 90, blue: 242, alpha: 0.30)
        case (.gray, false):     RGBA(red: 142, green: 142, blue: 147, alpha: 0.35)
        case (.gray, true):      RGBA(red: 142, green: 142, blue: 147, alpha: 0.30)
        }
    }

    /// 解析为 `NSColor`（sRGB，半透明）。
    ///
    /// - Parameter appearance: nil 或未知外观回退 Light（与
    ///   `TerminalAppearanceProvider.mode(for:)` 一致）。
    static func nsColor(for color: TerminalHighlightColor, appearance: NSAppearance?) -> NSColor {
        let dark = appearance?.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
        let rgba = rgba(for: color, dark: dark)
        return NSColor(srgbRed: rgba.red / 255.0,
                       green: rgba.green / 255.0,
                       blue: rgba.blue / 255.0,
                       alpha: rgba.alpha)
    }

    /// 规则列表展示用的不透明色块（UI 色点 / Picker）。
    static func swatchColor(for color: TerminalHighlightColor, dark: Bool) -> NSColor {
        let rgba = rgba(for: color, dark: dark)
        return NSColor(srgbRed: rgba.red / 255.0,
                       green: rgba.green / 255.0,
                       blue: rgba.blue / 255.0,
                       alpha: 1)
    }
}
