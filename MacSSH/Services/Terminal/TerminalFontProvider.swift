import AppKit
import CoreText
import Foundation

/// MacSSH 终端字体的唯一权威来源（MacSSH 1.1 Phase 2 字体方案）。
///
/// 本地 Terminal 与远程 Terminal 都**只能**通过本类型获取字体，禁止在各 Service
/// 内自行 `NSFont(name:size:)`。统一管理：
/// - 默认字号 14 pt（用户在 Settings 中仍看到只读的 14 pt）。
/// - 基础字体：JetBrains Mono Regular/Bold/Italic/BoldItalic（App Bundle 自带）。
/// - 中文 fallback：PingFang SC（macOS 系统字体，不打包）。
/// - Emoji fallback：Apple Color Emoji（macOS 系统字体，不打包）。
///
/// 字体级联（CJK / Emoji）通过 `NSFontDescriptor` 的 `NSFontCascadeAttribute` 实现，
/// 由 CoreText 自动按 Unicode 覆盖挑选后续字体，不做手工按字符切分文本或整段切换字体。
///
/// 由于 JetBrains Mono 已进入 App Bundle（`Contents/Resources/`），运行时加载失败
/// 视为打包/配置缺陷（packaging defect）。本类型仍保留 `NSFont.monospacedSystemFont`
/// 作为防御性 fallback，避免极端情况下 Crash；但加载失败会留下 `.error` 日志，
/// 测试与验收必须明确把这种路径标记为 FAIL，而非"用户未安装"的正常路径。
///
/// ## Bundle font source verification（P1 修复）
///
/// **不能**仅靠 `NSFont(name: "JetBrainsMono-Regular") != nil` 判定字体来源：当
/// `~/Library/Fonts/` 已安装同名 JetBrains Mono 时，该 API 同样会返回非 nil，产生
/// 假阳性。本类型记录每个 Bundle URL 的真实注册结果（`registrationResults`），
/// 并通过 `CTFontCopyAttribute(kCTFontURLAttribute)` 校验创建出来的字体 URL 是否
/// 确实位于 `Bundle.main.bundleURL` 之内。任何一步失败，`isBundledFontRegistered`
/// 必须返回 false，并使测试失败。
enum TerminalFontProvider {
    /// 默认终端字号（pt）。Phase 2 字体方案强约束：14.0。
    static let defaultSize: CGFloat = 14.0

    /// 基础字体的 family name（JetBrains Mono 官方 family）。
    static let baseFamily = "JetBrains Mono"

    /// 中文 fallback family（macOS 系统字体，不打包）。
    static let cjkFallbackFamily = "PingFang SC"

    /// Emoji fallback family（macOS 系统字体，不打包）。
    static let emojiFallbackFamily = "Apple Color Emoji"

    /// App Bundle 中需要注册的四个 JetBrains Mono TTF 文件名（与 `ThirdParty/JetBrainsMono` 一致）。
    static let bundledFontFileNames = [
        "JetBrainsMono-Regular.ttf",
        "JetBrainsMono-Bold.ttf",
        "JetBrainsMono-Italic.ttf",
        "JetBrainsMono-BoldItalic.ttf"
    ]

    /// 终端字重 → JetBrains Mono PostScript name 映射（用于构造请求）。
    private enum Weight {
        case regular
        case bold
        case italic
        case boldItalic

        /// 对应的 family 内 member name（与 TTF name table SubFamily 一致）。
        var memberName: String {
            switch self {
            case .regular: "Regular"
            case .bold: "Bold"
            case .italic: "Italic"
            case .boldItalic: "Bold Italic"
            }
        }

        /// 用于 `NSFontDescriptor` 的 `NSFontFaceAttribute` 值。
        var faceName: String { memberName }

        /// 是否需要 Bold traits。
        var isBold: Bool {
            self == .bold || self == .boldItalic
        }

        /// 是否需要 Italic traits。
        var isItalic: Bool {
            self == .italic || self == .boldItalic
        }

        /// 对应 bundled TTF 文件名（与 `bundledFontFileNames` 一致）。
        var bundledFileName: String {
            "JetBrainsMono-" + memberName.replacingOccurrences(of: " ", with: "") + ".ttf"
        }

        /// 期望的 PostScript name。
        var expectedPostScriptName: String {
            "JetBrainsMono-" + memberName.replacingOccurrences(of: " ", with: "")
        }
    }

    // MARK: - Registration result record

    /// 单个 Bundle 字体文件的真实注册结果。
    ///
    /// `bundleURL` 为 nil 表示 Bundle 内未找到该文件（packaging defect）；
    /// `didRegister` 为 false 表示 `CTFontManagerRegisterFontsForURL` 失败
    /// 或文件内容损坏（packaging defect）。
    struct BundledFontRegistrationResult: Equatable, Sendable {
        let fileName: String
        let bundleURL: URL?
        let didRegister: Bool
        let errorDescription: String?
    }

    /// 注册结果记录（供测试与验收逐个文件验证）。
    ///
    /// 顺序与 `bundledFontFileNames` 一致；只在 `registerBundledFontsIfNeeded()`
    /// 内写入。`registrationResults` 必须包含全部四个文件，且四个 `didRegister`
    /// 全部为 true 才能视为注册成功。
    nonisolated(unsafe) private(set) static var registrationResults: [BundledFontRegistrationResult] = []

    /// 是否已经执行过一次注册（即使失败也标记为 true，避免重复注册掩盖结果）。
    /// 测试可通过 `resetRegistrationForTesting()` 强制重置以重新注册。
    nonisolated(unsafe) private static var didAttemptRegistration = false

    // MARK: - Bundle Font Registration

    /// 一次性注册 App Bundle 中的 JetBrains Mono 字体。
    ///
    /// macOS 在 App 启动时若配置 `ATSApplicationFontsPath` 会自动扫描注册；但本项目
    /// 采用运行时显式注册作为权威路径，不依赖 Info.plist key，避免拷贝目录结构变化
    /// 导致的不可靠性。注册是幂等的（重复调用安全），但每次调用都会逐个记录结果，
    /// 供 `isBundledFontRegistered` 与测试严格判定。
    ///
    /// 必须在主线程或同步上下文调用一次（通常在 `MacSSHApp.init` 之前或同等早期）。
    /// 注册失败不抛出异常，但会留下 `.error` 日志；调用方应通过
    /// `isBundledFontRegistered` 判定是否成功。
    static func registerBundledFontsIfNeeded() {
        guard !didAttemptRegistration else { return }
        performRegistration()
    }

    /// 强制重新执行一次注册（仅供测试注入损坏字体后复测）。
    ///
    /// 生产代码不得调用本方法。`CTFontManagerUnregisterFontsForURL` 会先反注册
    /// 上一次注册的字体（避免重复注册造成的结果污染），然后重新执行注册流程。
    ///
    /// **测试隔离设计**：测试 host 进程内多次注册会让
    /// `CTFontManagerRegisterFontsForURL` 报 "已经在指定范围内注册"。
    /// 因此每次测试必须先调用本方法反注册之前所有已成功注册的 URL，
    /// 再注入损坏内容或恢复后重新注册。
    static func resetRegistrationForTesting() {
        // 测试隔离：对 Bundle 中四个 TTF 全部尝试反注册，而不论之前 results 如何。
        // 原因：测试 host 启动时 `MacSSHApp.init` 已经注册过一次，且测试间相互
        // 可能产生各种中间状态。对每个 URL 都调用一次 unregister，CTFontManager
        // 对未注册的 URL 会返回 false 但不会污染目标状态——这是清理，不是错误。
        for fileName in bundledFontFileNames {
            guard let url = Bundle.main.url(forResource: fileName, withExtension: nil) else {
                continue
            }
            var unregisterError: Unmanaged<CFError>?
            let ok = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &unregisterError)
            if !ok, let cfError = unregisterError?.takeRetainedValue() {
                AppLogger.terminal.error("Unregister attempt for \(fileName, privacy: .public): \(cfError.localizedDescription, privacy: .public)")
            }
        }
        registrationResults = []
        didAttemptRegistration = false
    }

    /// 实际执行注册：逐个解析 Bundle URL + 逐个调用 CTFontManager + 记录结果。
    private static func performRegistration() {
        didAttemptRegistration = true
        var results: [BundledFontRegistrationResult] = []
        results.reserveCapacity(bundledFontFileNames.count)

        for fileName in bundledFontFileNames {
            // Bundle.main 在测试 host 环境下指向 MacSSH.app；测试 target 自身运行时
            // 同样使用 TEST_HOST 指向的 .app（见 pbxproj TEST_HOST 设置）。
            let url = Bundle.main.url(forResource: fileName, withExtension: nil)

            guard let url else {
                AppLogger.terminal.error("JetBrains Mono bundle font \(fileName, privacy: .public) not found (packaging defect)")
                results.append(BundledFontRegistrationResult(
                    fileName: fileName,
                    bundleURL: nil,
                    didRegister: false,
                    errorDescription: "Bundle resource not found"
                ))
                continue
            }

            var errorRef: Unmanaged<CFError>?
            let didRegister = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef)
            let errorDescription: String?
            if !didRegister {
                let message = errorRef?.takeRetainedValue().localizedDescription ?? "unknown CTFontManager error"
                errorDescription = message
                AppLogger.terminal.error("JetBrains Mono font registration failed for \(fileName, privacy: .public): \(message, privacy: .public) (packaging defect)")
            } else {
                errorDescription = nil
            }
            results.append(BundledFontRegistrationResult(
                fileName: fileName,
                bundleURL: url,
                didRegister: didRegister,
                errorDescription: errorDescription
            ))
        }

        registrationResults = results

        let registeredCount = results.filter(\.didRegister).count
        if registeredCount == bundledFontFileNames.count {
            AppLogger.terminal.info("JetBrains Mono bundled fonts registered (\(registeredCount, privacy: .public) files)")
        } else {
            AppLogger.terminal.error("JetBrains Mono bundled fonts partially registered (\(registeredCount, privacy: .public)/\(bundledFontFileNames.count, privacy: .public)) (packaging defect)")
        }
    }

    // MARK: - Font Construction

    /// Regular 终端字体（默认）：JetBrains Mono Regular + 中文/Emoji cascade。
    static func regularFont(size: CGFloat = defaultSize) -> NSFont {
        registerBundledFontsIfNeeded()
        return font(weight: .regular, size: size)
    }

    /// Bold 终端字体：JetBrains Mono Bold + 中文/Emoji cascade。
    static func boldFont(size: CGFloat = defaultSize) -> NSFont {
        registerBundledFontsIfNeeded()
        return font(weight: .bold, size: size)
    }

    /// Italic 终端字体：JetBrains Mono Italic + 中文/Emoji cascade。
    static func italicFont(size: CGFloat = defaultSize) -> NSFont {
        registerBundledFontsIfNeeded()
        return font(weight: .italic, size: size)
    }

    /// Bold + Italic 终端字体：JetBrains Mono Bold Italic + 中文/Emoji cascade。
    static func boldItalicFont(size: CGFloat = defaultSize) -> NSFont {
        registerBundledFontsIfNeeded()
        return font(weight: .boldItalic, size: size)
    }

    /// 构造指定字重的字体；JetBrains Mono 不可用时退回系统等宽字体（仅作 Crash 防御，
    /// 该路径视为 packaging defect，必须在测试中标记 FAIL）。
    private static func font(weight: Weight, size: CGFloat) -> NSFont {
        // 优先按 PostScript-style name 请求（最精确，不会触发系统合成）。
        // JetBrains Mono 的 PS name 形如 "JetBrainsMono-Regular"。
        let psName = weight.expectedPostScriptName
        if let font = NSFont(name: psName, size: size) {
            // 仅当字体 URL 确实在 Bundle 内时才视为成功；否则可能是
            // ~/Library/Fonts 的同名同族字体，必须拒绝并进入 fallback。
            if isFontSourcedFromBundle(font) {
                return applyCascade(to: font)
            }
            AppLogger.terminal.error("JetBrains Mono \(weight.memberName) resolved from non-bundle source (system-installed JetBrains Mono dependency — packaging defect)")
        }

        // 回退：通过 family + face 构造。
        let descriptor = NSFontDescriptor(
            fontAttributes: [
                .family: baseFamily,
                .face: weight.faceName,
                .size: size
            ]
        )
        if let font = NSFont(descriptor: descriptor, size: size) {
            // 验证 family 仍是 JetBrains Mono，避免 face 解析失败后系统替换为其他字体。
            if (font.familyName == baseFamily || font.fontName.contains("JetBrainsMono"))
                && isFontSourcedFromBundle(font) {
                return applyCascade(to: font)
            }
        }

        // 防御性 fallback：系统等宽字体。该路径视为 packaging defect。
        AppLogger.terminal.error("JetBrains Mono \(weight.memberName) load failed — using monospaced system fallback (packaging defect)")
        let fallback = NSFont.monospacedSystemFont(ofSize: size, weight: weight.isBold ? .bold : .regular)
        return applyCascade(to: fallback)
    }

    /// 为字体附加中文与 Emoji 的级联 fallback。
    ///
    /// CoreText 在渲染时按 Unicode 覆盖自动从 cascade list 中挑选合适的后续字体，
    /// 不需要业务代码按字符切分文本或手动切换字体。
    private static func applyCascade(to font: NSFont) -> NSFont {
        let cascadeList: [NSFontDescriptor] = [
            NSFontDescriptor(fontAttributes: [.family: cjkFallbackFamily]),
            NSFontDescriptor(fontAttributes: [.family: emojiFallbackFamily])
        ]
        let attributes: [NSFontDescriptor.AttributeName: Any] = [
            .cascadeList: cascadeList
        ]
        let descriptor = font.fontDescriptor.addingAttributes(attributes)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Verification Helpers

    /// JetBrains Mono 是否在当前进程从 App Bundle 成功注册/可用。
    ///
    /// **不**只看 `NSFont(name:)` 是否返回非 nil —— 当 `~/Library/Fonts/` 已安装
    /// 同名 JetBrains Mono 时，该 API 会假阳性。本方法严格判定：
    /// 1. 四个 Bundle URL 全部存在（packaging defect 检查）；
    /// 2. 四个全部 `CTFontManagerRegisterFontsForURL` 成功；
    /// 3. 创建出来的 Regular NSFont 的 URL（`kCTFontURLAttribute`）确实位于
    ///    `Bundle.main.bundleURL` 之内，证明字体来自 Bundle 而非系统目录。
    ///
    /// 任一条件不满足即返回 false，并视为 packaging defect。
    static var isBundledFontRegistered: Bool {
        registerBundledFontsIfNeeded()
        // 条件 1 + 2：四个结果全为 didRegister 且 bundleURL 非空。
        guard registrationResults.count == bundledFontFileNames.count,
              registrationResults.allSatisfy({ $0.bundleURL != nil && $0.didRegister })
        else { return false }

        // 条件 3：实际创建一个 Regular 字体并验证其 URL 在 Bundle 内。
        guard let font = NSFont(name: "JetBrainsMono-Regular", size: defaultSize),
              isFontSourcedFromBundle(font)
        else { return false }
        return true
    }

    /// 返回当前可解析的 JetBrains Mono Regular PostScript name（用于验收报告）。
    /// 失败返回 nil。
    static var regularPostScriptName: String? {
        registerBundledFontsIfNeeded()
        return NSFont(name: "JetBrainsMono-Regular", size: defaultSize)?.fontName
    }

    static var boldPostScriptName: String? {
        registerBundledFontsIfNeeded()
        return NSFont(name: "JetBrainsMono-Bold", size: defaultSize)?.fontName
    }

    static var italicPostScriptName: String? {
        registerBundledFontsIfNeeded()
        return NSFont(name: "JetBrainsMono-Italic", size: defaultSize)?.fontName
    }

    static var boldItalicPostScriptName: String? {
        registerBundledFontsIfNeeded()
        return NSFont(name: "JetBrainsMono-BoldItalic", size: defaultSize)?.fontName
    }

    /// 列出给定字体的 cascade list 中包含的 family name（用于验收中文/Emoji fallback）。
    static func cascadeFamilyNames(for font: NSFont) -> [String] {
        guard let list = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] else {
            return []
        }
        return list.compactMap { $0.object(forKey: .family) as? String }
    }

    // MARK: - Bundle source verification

    /// 验证给定字体的物理 URL 确实位于 `Bundle.main.bundleURL` 之内。
    ///
    /// **P1 修复核心**：避免开发机已安装 `~/Library/Fonts/JetBrains Mono` 造成的
    /// 假阳性。CoreText 的 `kCTFontURLAttribute` 在字体从 Bundle 注册成功时
    /// 返回该 TTF 的 Bundle 内 URL；如果字体来自系统目录，URL 将位于
    /// `/System/Library/Fonts/` 或 `~/Library/Fonts/`，本方法返回 false。
    ///
    /// 对系统等宽 fallback 字体（无 URL）返回 false。
    static func isFontSourcedFromBundle(_ font: NSFont) -> Bool {
        let raw = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute)
        guard let url = raw as? URL else { return false }

        // 重要：`/tmp` 在 macOS 上是 `/private/tmp` 的符号链接。
        // `Bundle.main.bundleURL` 解析后返回 `/private/tmp/...`，
        // 而 `CTFontCopyAttribute` 返回的字体 URL 可能保留 `/tmp/...`。
        // 两边都必须 resolvingSymlinksInPath，否则 prefix-match 会假阴性。
        let fontPath = url.resolvingSymlinksInPath().path
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path

        // Bundle URL 末尾通常带斜杠（如 .../MacSSH.app/）；
        // 为避免 prefix-match 假阳性，统一用 bundlePath + "/" 作为前缀。
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        return fontPath.hasPrefix(prefix)
    }
}
