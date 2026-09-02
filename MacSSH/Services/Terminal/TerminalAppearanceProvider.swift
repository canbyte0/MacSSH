import AppKit
import SwiftTerm

/// MacSSH 终端外观（明 / 暗模式）的唯一权威来源（MacSSH 1.1 Phase 4）。
///
/// 与 `TerminalFontProvider` 职责严格分离（任务书第四节）：本类型只负责终端的
/// 默认前景 / 背景 / 选区颜色，不涉及字体、字号、级联或单元格几何。本地 Terminal
/// 与远程 Terminal 共用同一配置（任务书第二节），杜绝 Local / Remote 外观不一致。
///
/// ## 为什么不继续使用 `configureNativeColors()`
///
/// `SwiftTerm.TerminalView.configureNativeColors()` 设置：
///
/// ```
/// nativeForegroundColor = NSColor.textColor           // 动态语义色
/// nativeBackgroundColor = NSColor.textBackgroundColor // 动态语义色
/// ```
///
/// 但 `nativeBackgroundColor` 的 setter（`Mac/MacTerminalView.swift`）立即执行：
///
/// ```
/// terminal.backgroundColor = nativeBackgroundColor.getTerminalColor()
/// ```
///
/// `getTerminalColor()`（`Mac/MacExtensions.swift`）会把动态 `NSColor` 一次性解析
/// 成**固定 RGB `Color`**（UInt16 分量），冻结在 `Terminal` 实例中。`Terminal`
/// 的 `backgroundColor` / `foregroundColor` 是固定 RGB，**不会**在外观变化时
/// 重新解析；SwiftTerm 的 `TerminalView` 也不覆盖
/// `viewDidChangeEffectiveAppearance`。MacSSH 既有代码也从未在外观变化时重新
/// 应用颜色。这就是「App 进入 Dark 但 Terminal viewport 仍为白色」的根因
/// （任务书第四十四节）：颜色在 Service init 时被解析一次后永远冻结。
///
/// ## 本类型的策略
///
/// - 直接提供按模式确定的**不透明 sRGB 固定值**，不再依赖 `NSColor.textColor`
///   等动态色的运行时解析时机，从根源消除冻结问题。
/// - 颜色值集中管理（任务书第八节，不散落 magic color）：均为 macOS 语义色
///   在 Light / Dark 下的等价解析值，与 macOS 原生 Terminal 协调、清晰可读。
/// - `Palette` 仅承载 `RGB`（`Sendable`），使 `TerminalAppearanceTests` 可不
///   依赖系统当前模式做确定性断言（任务书第四十八节）。
enum TerminalAppearanceProvider {
    /// 终端外观模式。语言无关，**只**跟随 macOS Appearance（任务书第一节：
    /// Language 与 Appearance 完全独立）。
    enum Mode: String, Equatable, Sendable {
        case light
        case dark
    }

    /// 确定性的 sRGB 颜色分量（用于测试断言，不依赖 `NSColor` 动态解析）。
    struct RGB: Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    /// 一套终端外观调色板（固定模式，确定值，`Sendable`）。
    struct Palette: Equatable, Sendable {
        let mode: Mode
        let foreground: RGB
        let background: RGB
        let selectionBackground: RGB
        let selectionForeground: RGB
    }

    /// Light 调色板：等价于 `NSColor.textColor` / `NSColor.textBackgroundColor`
    /// 在 Light Appearance 下的解析值——黑字 / 白底；选区使用 macOS 标准浅蓝
    /// （`selectedTextBackgroundColor` 的 Light 解析近似），黑字在浅蓝上可读。
    static let light = Palette(
        mode: .light,
        foreground: RGB(red: 0x00, green: 0x00, blue: 0x00),
        background: RGB(red: 0xFF, green: 0xFF, blue: 0xFF),
        selectionBackground: RGB(red: 0xB3, green: 0xD7, blue: 0xFF),
        selectionForeground: RGB(red: 0x00, green: 0x00, blue: 0x00)
    )

    /// Dark 调色板：等价于 `NSColor.textColor` / `NSColor.textBackgroundColor`
    /// 在 Dark Appearance 下的解析值——白字 / 近黑底 `#1E1E1E`（即 macOS Dark
    /// 窗口表面，与 App 暗色 chrome 协调）；选区使用 macOS 标准深蓝，白字在
    /// 深蓝上可读。
    static let dark = Palette(
        mode: .dark,
        foreground: RGB(red: 0xFF, green: 0xFF, blue: 0xFF),
        background: RGB(red: 0x1E, green: 0x1E, blue: 0x1E),
        selectionBackground: RGB(red: 0x26, green: 0x4F, blue: 0x78),
        selectionForeground: RGB(red: 0xFF, green: 0xFF, blue: 0xFF)
    )

    // MARK: - Appearance → Palette

    /// 由 `NSAppearance` 解析出对应模式（任务书第五 / 四十八节）。
    /// 未知 / nil 回退 Light（与 macOS 默认一致，绝不 Crash）。
    static func mode(for appearance: NSAppearance?) -> Mode {
        guard let appearance else { return .light }
        let match = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .accessibilityHighContrastDarkAqua])
        switch match {
        case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua:
            return .dark
        default:
            return .light
        }
    }

    /// 由 `NSAppearance` 解析出对应调色板。
    static func palette(for appearance: NSAppearance?) -> Palette {
        mode(for: appearance) == .dark ? dark : light
    }

    /// 由当前 App Effective Appearance 解析调色板（供 Service 初始化与
    /// Coordinator 注册时一次性应用；任务书第六节禁止只在 `init` 读取后
    /// 永不更新——动态更新由 `TerminalAppearanceCoordinator` 负责）。
    ///
    /// `@MainActor`：读取 `NSApp.effectiveAppearance`（MainActor-isolated）。
    @MainActor
    static func paletteForCurrentAppAppearance() -> Palette {
        palette(for: NSApp?.effectiveAppearance)
    }

    // MARK: - Apply（公开 SwiftTerm API；任务书第四十二节）

    /// 将一套调色板应用到 SwiftTerm `TerminalView`（Local / Remote 通用，
    /// `LocalProcessTerminalView` 是 `TerminalView` 的子类）。
    ///
    /// 使用的公开 API：
    /// - `nativeForegroundColor`：setter 把 `_nativeFg` 更新为新色，并经
    ///   `Terminal.foregroundColor.didSet` 回调 view 的
    ///   `setForegroundColor(source:color:)` delegate → `colorsChanged()`
    ///   （清空 `attributes` / `urlAttributes` 缓存、`clearCGColorCache()`、
    ///   `layer.backgroundColor` 同步、`terminal.updateFullScreen()`、
    ///   `queuePendingDisplay()`）。
    /// - `nativeBackgroundColor`：同上路径，并更新 `terminal.backgroundColor`
    ///   （覆盖 erase / clear / alternate screen 的底色）与 `layer.backgroundColor`
    ///   （覆盖外框 margin）。Metal renderer 关闭时 layer 即负责底色；开启时
    ///   其 `clearColor` 实时读取 `effectiveNativeBackgroundColor`。
    /// - `selectedTextBackgroundColor` / `selectedTextForegroundColor`：触发
    ///   `updateFullScreen` + `queuePendingDisplay`。
    ///
    /// 覆盖范围（任务书第九 ~ 十三节）：默认前景 / 默认背景 / ESC[0m reset
    /// 回到当前模式默认色（因 `terminal.foreground/background` 已更新）、
    /// `clear` 与 `ESC[2J`/`ESC[K` 使用当前 `terminal.backgroundColor`、
    /// alternate screen 进出均使用当前底色、scrollback 经 `colorsChanged`
    /// 清缓存 + `updateFullScreen` 全量重绘（不会出现一半白一半黑）。
    ///
    /// 不触碰 `caretColor` / `caretTextColor`：`cursorColorIsDefault` /
    /// `cursorTextColorIsDefault` 维持初始 `true`，`effectiveCaretColor` /
    /// caret 文本色实时读取 `effectiveNativeForegroundColor` /
    /// `effectiveNativeBackgroundColor`，光标随默认前景 / 背景自动在明暗模式
    /// 下保持可见（任务书第十八节）。
    ///
    /// 不修改字体、字号、级联或单元格几何（任务书第二十一 / 五十一节）。
    /// 不调用 `installColors`：保留 SwiftTerm 自带 ANSI 16/256 palette
    /// （任务书第二十四 / 四十三节，仅调整默认 fg/bg）。
    ///
    /// `@MainActor`：`TerminalView` 的颜色属性由 SwiftTerm 标注为 MainActor-isolated，
    /// 本方法仅在 MainActor 上下文（Service init、Coordinator）调用。
    @MainActor
    static func apply(_ palette: Palette, to terminalView: TerminalView) {
        terminalView.nativeForegroundColor = nsColor(for: palette.foreground)
        terminalView.nativeBackgroundColor = nsColor(for: palette.background)
        terminalView.selectedTextBackgroundColor = nsColor(for: palette.selectionBackground)
        terminalView.selectedTextForegroundColor = nsColor(for: palette.selectionForeground)
    }

    /// 解析当前 App Effective Appearance 并应用到指定 `TerminalView`
    /// （Service init 阶段的初始应用；动态更新由 Coordinator 负责）。
    @MainActor
    static func applyCurrentAppAppearance(to terminalView: TerminalView) {
        apply(paletteForCurrentAppAppearance(), to: terminalView)
    }

    // MARK: - Read-back（供测试断言当前已应用的颜色，不依赖系统模式）

    /// 读取 `TerminalView` 当前已应用的 `nativeBackgroundColor`（sRGB）。
    @MainActor
    static func appliedBackgroundRGB(of terminalView: TerminalView) -> RGB {
        rgb(of: terminalView.nativeBackgroundColor)
    }

    /// 读取 `TerminalView` 当前已应用的 `nativeForegroundColor`（sRGB）。
    @MainActor
    static func appliedForegroundRGB(of terminalView: TerminalView) -> RGB {
        rgb(of: terminalView.nativeForegroundColor)
    }

    // MARK: - Contrast（任务书第四十七节，量化判定可读对比度）

    /// WCAG 2.x 相对亮度（输入 RGB，输出 0...1）。
    static func relativeLuminance(_ rgb: RGB) -> Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255.0
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
    }

    /// WCAG 对比度比（1.0 ... 21.0）；越高越可读。
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - Color conversion（私有）

    /// 由 RGB 构造不透明 sRGB `NSColor`（固定值，不动态解析）。
    private static func nsColor(for rgb: RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red) / 255.0,
            green: CGFloat(rgb.green) / 255.0,
            blue: CGFloat(rgb.blue) / 255.0,
            alpha: 1.0
        )
    }

    /// 把 `NSColor` 解析为 sRGB `RGB`（用于测试断言当前已应用的颜色）。
    private static func rgb(of color: NSColor) -> RGB {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            return RGB(red: 0, green: 0, blue: 0)
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, Int((v * 255.0).rounded()))))
        }
        return RGB(red: clamp(r), green: clamp(g), blue: clamp(b))
    }
}
