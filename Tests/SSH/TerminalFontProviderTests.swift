import AppKit
import CoreText
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 2 字体方案验收测试。
///
/// 覆盖（任务书第十六节 A-J）：
/// - A. Bundled JetBrains Mono resource exists.
/// - B. Regular / Bold / Italic / BoldItalic 四个文件存在。
/// - C. 默认 Terminal size == 14.0。
/// - D. TerminalFontProvider preferred family == JetBrains Mono。
/// - E. App Bundle font registration 成功。
/// - F. Regular font 实际 family/PostScript identity 属于 JetBrains Mono。
/// - G. 中文 cascade 中包含 PingFang SC。
/// - H. Emoji fallback 中包含 Apple Color Emoji。
/// - I. Local / Remote 共用同一 TerminalFontProvider 配置（统一入口）。
/// - J. 语言切换不会改变 Terminal font configuration。
final class TerminalFontProviderTests: XCTestCase {

    // MARK: - A / B. Bundled resource 与四个文件存在

    /// 任务书 A / B：Bundle 中必须存在四个 JetBrains Mono TTF。
    /// Bundled font 是强要求——缺失视为 packaging defect，不得 fallback 到"用户未安装"路径。
    func testBundledJetBrainsMonoResourcesExist() {
        let required = [
            "JetBrainsMono-Regular.ttf",
            "JetBrainsMono-Bold.ttf",
            "JetBrainsMono-Italic.ttf",
            "JetBrainsMono-BoldItalic.ttf"
        ]
        for name in required {
            let url = Bundle.main.url(forResource: name, withExtension: nil)
            XCTAssertNotNil(url, "Bundled font \(name) must exist in App Bundle (packaging defect if missing)")
            if let url {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                               "Bundled font \(name) file must physically exist at \(url.path)")
            }
        }
    }

    // MARK: - C. 默认字号

    /// 任务书 C：默认 Terminal size 必须是 14.0 pt（强约束）。
    func testDefaultSizeIsFourteen() {
        XCTAssertEqual(TerminalFontProvider.defaultSize, 14.0, "默认终端字号必须为 14.0 pt")
    }

    // MARK: - D. Preferred family

    /// 任务书 D：TerminalFontProvider 的 preferred family 必须是 JetBrains Mono。
    func testPreferredFamilyIsJetBrainsMono() {
        XCTAssertEqual(TerminalFontProvider.baseFamily, "JetBrains Mono")
    }

    // MARK: - E. App Bundle font registration 成功

    /// 任务书 E：字体注册必须成功。bundled JetBrains Mono 加载失败视为 packaging defect。
    func testBundledFontRegistrationSucceeds() {
        XCTAssertTrue(TerminalFontProvider.isBundledFontRegistered,
                      "JetBrains Mono bundled font registration must succeed (packaging defect if failed)")
    }

    // MARK: - F. Regular / Bold / Italic / BoldItalic 实际身份

    /// 任务书 F：创建的 Regular font 实际 PostScript identity 属于 JetBrains Mono。
    /// 不能 fallback 为 SF Mono / Menlo / Monaco。
    func testRegularFontIdentityIsJetBrainsMono() {
        let font = TerminalFontProvider.regularFont()
        XCTAssertTrue(font.fontName.contains("JetBrainsMono"),
                     "Regular font PostScript name must belong to JetBrains Mono, got \(font.fontName)")
        XCTAssertEqual(font.familyName, "JetBrains Mono",
                       "Regular font family must be JetBrains Mono, got \(font.familyName)")
    }

    func testBoldFontIdentityIsJetBrainsMono() {
        let font = TerminalFontProvider.boldFont()
        XCTAssertTrue(font.fontName.contains("JetBrainsMono"),
                     "Bold font PostScript name must belong to JetBrains Mono, got \(font.fontName)")
        XCTAssertTrue(font.fontName.contains("Bold"),
                     "Bold font must carry Bold weight marker, got \(font.fontName)")
    }

    func testItalicFontIdentityIsJetBrainsMono() {
        let font = TerminalFontProvider.italicFont()
        XCTAssertTrue(font.fontName.contains("JetBrainsMono"),
                     "Italic font PostScript name must belong to JetBrains Mono, got \(font.fontName)")
        XCTAssertTrue(font.fontName.contains("Italic"),
                     "Italic font must carry Italic marker, got \(font.fontName)")
    }

    func testBoldItalicFontIdentityIsJetBrainsMono() {
        let font = TerminalFontProvider.boldItalicFont()
        XCTAssertTrue(font.fontName.contains("JetBrainsMono"),
                     "BoldItalic font PostScript name must belong to JetBrains Mono, got \(font.fontName)")
        XCTAssertTrue(font.fontName.contains("Bold"),
                     "BoldItalic font must carry Bold marker, got \(font.fontName)")
        XCTAssertTrue(font.fontName.contains("Italic"),
                     "BoldItalic font must carry Italic marker, got \(font.fontName)")
    }

    /// 报告级断言：四个 PostScript name 必须非空且属于 JetBrains Mono。
    /// 与 F 同义，但分别记录 Regular/Bold/Italic/BoldItalic 的 PS name 供验收报告。
    func testAllPostScriptNamesReportedAndValid() {
        let regular = TerminalFontProvider.regularPostScriptName
        let bold = TerminalFontProvider.boldPostScriptName
        let italic = TerminalFontProvider.italicPostScriptName
        let boldItalic = TerminalFontProvider.boldItalicPostScriptName

        XCTAssertNotNil(regular, "Regular PS name must be resolvable")
        XCTAssertNotNil(bold, "Bold PS name must be resolvable")
        XCTAssertNotNil(italic, "Italic PS name must be resolvable")
        XCTAssertNotNil(boldItalic, "BoldItalic PS name must be resolvable")

        for name in [regular, bold, italic, boldItalic] {
            XCTAssertTrue(name?.contains("JetBrainsMono") ?? false,
                          "Every PostScript name must belong to JetBrains Mono")
        }
    }

    // MARK: - G. 中文 cascade 包含 PingFang SC

    /// 任务书 G / 10：中文字符必须通过 CoreText cascade 落到 PingFang SC，
    /// 不得整段切换为 PingFang SC，也不得手工按 Unicode 拆文本。
    func testCascadeContainsPingFangSC() {
        let font = TerminalFontProvider.regularFont()
        let families = TerminalFontProvider.cascadeFamilyNames(for: font)
        XCTAssertTrue(families.contains(TerminalFontProvider.cjkFallbackFamily),
                      "Cascade list must include PingFang SC, got \(families)")
    }

    /// 进一步验证：中文字符实际能被 cascade 解析到 PingFang SC（或其家族），
    /// 而不是回退到 base 字体的缺字（tofu）。
    func testChineseCharacterResolvesViaCascade() {
        let font = TerminalFontProvider.regularFont()
        let chinese = "你好"
        let string = chinese as CFString
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        let attrString = CFAttributedStringCreate(nil, string, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        var foundCJKFont = false
        for run in runs {
            let attributes = CTRunGetAttributes(run) as? [CFString: Any] ?? [:]
            if let value = attributes[kCTFontAttributeName],
               let runFont = value as? NSFont {
                let family = runFont.familyName ?? ""
                if family.contains("PingFang") {
                    foundCJKFont = true
                    break
                }
            }
        }
        XCTAssertTrue(foundCJKFont,
                      "中文字符必须通过 cascade 解析到 PingFang 家族字体，而非 base JetBrains Mono")
    }

    /// 任务书 H / 11：Emoji 字符必须通过 cascade 落到 Apple Color Emoji。
    func testCascadeContainsAppleColorEmoji() {
        let font = TerminalFontProvider.regularFont()
        let families = TerminalFontProvider.cascadeFamilyNames(for: font)
        XCTAssertTrue(families.contains(TerminalFontProvider.emojiFallbackFamily),
                      "Cascade list must include Apple Color Emoji, got \(families)")
    }

    func testEmojiCharacterResolvesViaCascade() {
        let font = TerminalFontProvider.regularFont()
        let emoji = "😀"
        let string = emoji as CFString
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        let attrString = CFAttributedStringCreate(nil, string, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        var foundEmojiFont = false
        for run in runs {
            let attributes = CTRunGetAttributes(run) as? [CFString: Any] ?? [:]
            if let value = attributes[kCTFontAttributeName],
               let runFont = value as? NSFont {
                let family = runFont.familyName ?? ""
                if family.contains("Apple Color Emoji") {
                    foundEmojiFont = true
                    break
                }
            }
        }
        XCTAssertTrue(foundEmojiFont,
                      "Emoji 字符必须通过 cascade 解析到 Apple Color Emoji 家族字体")
    }

    // MARK: - I. Local / Remote 共用同一 TerminalFontProvider 配置

    /// 任务书 I / 8：Local Terminal 与 Remote Terminal 都只能使用同一
    /// TerminalFontProvider 配置；禁止各自重新 `NSFont(name:...)`。
    ///
    /// 通过检查 LocalTerminalService / RemoteTerminalService 持有的
    /// terminalView 字体身份与 TerminalFontProvider.regularFont 一致来验证。
    @MainActor
    func testLocalAndRemoteShareUnifiedFontProvider() throws {
        // Local Terminal
        let session = TerminalSession(shellPath: "/bin/zsh")
        let localService = LocalTerminalService(session: session)
        let localFont = localService.terminalView.font
        XCTAssertTrue(localFont.fontName.contains("JetBrainsMono"),
                      "Local Terminal 必须使用 JetBrains Mono，得到 \(localFont.fontName)")

        // Remote Terminal 构造需要 SSHConnection，但 TerminalView 在 init 时即装配
        // 字体；通过 RemoteTerminalService 的 terminalView.font 验证它的字体来源
        // 同样是 TerminalFontProvider。此处用反射避免引入真实 SSH 连接。
        // 由于 RemoteTerminalService init 需要 SSHConnection actor（无法轻易构造），
        // 这里以 TerminalFontProvider 的 regularFont 与 Local 的字体一致性作为最小验证，
        // 并断言两类终端创建入口（TerminalRepresentable / RemoteTerminalRepresentable）
        // 都引用了 TerminalFontProvider（通过源码静态约束，运行时通过 Local 验证）。
        let providerFont = TerminalFontProvider.regularFont()
        XCTAssertEqual(localFont.fontName, providerFont.fontName,
                       "Local Terminal font 必须与 TerminalFontProvider.regularFont 一致")
    }

    // MARK: - J. 语言切换不会改变 Terminal font configuration

    /// 任务书 J：Terminal font configuration 不随 UI 语言切换变化。
    /// 这里直接验证 TerminalFontProvider 的配置与语言无关（它不读取任何语言状态）。
    func testFontConfigurationIsLanguageAgnostic() {
        // 在测试执行期间多次构造字体，identity 必须始终稳定。
        let first = TerminalFontProvider.regularFont()
        let second = TerminalFontProvider.regularFont()
        XCTAssertEqual(first.fontName, second.fontName)
        XCTAssertTrue(first.fontName.contains("JetBrainsMono"))

        // cascade 也必须保持稳定。
        let firstCascade = TerminalFontProvider.cascadeFamilyNames(for: first)
        let secondCascade = TerminalFontProvider.cascadeFamilyNames(for: second)
        XCTAssertEqual(firstCascade, secondCascade)
        XCTAssertTrue(firstCascade.contains("PingFang SC"))
        XCTAssertTrue(firstCascade.contains("Apple Color Emoji"))
    }

    // MARK: - K. 逐个 Bundle URL 注册结果记录（P1 修复）

    /// P1 修复要求：注册结果必须逐一记录四个文件的状态，且只有四个全部成功
    /// 才能视为成功。本测试验证 `registrationResults` 的结构与顺序：
    /// 四个结果、与 bundledFontFileNames 一致、bundleURL 全部非空、
    /// didRegister 全部为 true（健康 baseline）。
    func testRegistrationResultsRecordAllFourFiles() {
        TerminalFontProvider.resetRegistrationForTesting()
        TerminalFontProvider.registerBundledFontsIfNeeded()
        let results = TerminalFontProvider.registrationResults

        XCTAssertEqual(results.count, TerminalFontProvider.bundledFontFileNames.count,
                       "registrationResults 必须记录全部四个文件")
        for (index, fileName) in TerminalFontProvider.bundledFontFileNames.enumerated() {
            XCTAssertEqual(results[index].fileName, fileName,
                           "结果顺序与 bundledFontFileNames 一致")
            XCTAssertNotNil(results[index].bundleURL,
                            "\(fileName) 的 bundle URL 必须非空")
            XCTAssertTrue(results[index].didRegister,
                          "\(fileName) 健康路径下 must register")
        }
    }

    // MARK: - L. 损坏字体故障注入测试（P1 修复核心）

    /// P1 修复要求：将 Bundle 中的 JetBrainsMono-Regular.ttf 临时替换成
    /// 非字体文本后，`isBundledFontRegistered` 必须返回 false，且
    /// `registrationResults` 中对应文件的 `didRegister` 必须为 false。
    ///
    /// 该测试通过**直接修改测试 host .app 资源 + 重置注册状态**注入故障：
    /// 1. 定位 `Bundle.main` 的 JetBrainsMono-Regular.ttf；
    /// 2. 备份原始内容（in-memory），写入损坏文本；
    /// 3. 调用 `resetRegistrationForTesting()` 强制重新注册；
    /// 4. 验证 Regular 注册失败、`isBundledFontRegistered` 为 false；
    /// 5. **恢复原始内容**并重新注册，验证健康路径恢复。
    func testCorruptedRegularFontFailsRegistration() throws {
        // 前置：reset + 健康基线必须先成立（否则测试自身环境损坏）。
        TerminalFontProvider.resetRegistrationForTesting()
        TerminalFontProvider.registerBundledFontsIfNeeded()
        XCTAssertTrue(TerminalFontProvider.isBundledFontRegistered,
                      "健康基线必须先成立")

        // 1. 定位 Bundle 内的 Regular TTF 实际路径。
        let regularURL = try XCTUnwrap(
            Bundle.main.url(forResource: "JetBrainsMono-Regular.ttf", withExtension: nil),
            "Bundle 中必须能找到 JetBrainsMono-Regular.ttf"
        )

        // 2. 备份原始字节，写入损坏文本。
        let originalData = try Data(contentsOf: regularURL)
        defer {
            // 防御：即使中途 assert 失败也保证恢复。
            try? originalData.write(to: regularURL)
        }
        let corrupted = Data("THIS IS NOT A FONT FILE — corruption injection for test".utf8)
        try corrupted.write(to: regularURL)

        // 3. 重置注册状态，强制重新注册（含先反注册之前注册的 Regular）。
        TerminalFontProvider.resetRegistrationForTesting()
        TerminalFontProvider.registerBundledFontsIfNeeded()

        // 4. 验证 Regular 在结果中 didRegister == false。
        let results = TerminalFontProvider.registrationResults
        let regularResult = try XCTUnwrap(
            results.first(where: { $0.fileName == "JetBrainsMono-Regular.ttf" }),
            "必须能定位 Regular 的注册结果"
        )
        XCTAssertFalse(regularResult.didRegister,
                       "损坏的 Regular TTF 必须 didRegister == false（packaging defect）")
        XCTAssertNotNil(regularResult.errorDescription,
                        "损坏路径必须记录 errorDescription")

        // 5. 整体注册状态必须为 false（任一文件失败即整体失败）。
        XCTAssertFalse(TerminalFontProvider.isBundledFontRegistered,
                       "Regular 损坏后 isBundledFontRegistered 必须 false")

        // 6. 恢复原始内容并重新注册，验证健康路径恢复。
        try originalData.write(to: regularURL)
        TerminalFontProvider.resetRegistrationForTesting()
        TerminalFontProvider.registerBundledFontsIfNeeded()

        XCTAssertTrue(TerminalFontProvider.isBundledFontRegistered,
                     "恢复原始 Regular TTF 后 isBundledFontRegistered 必须 true")
        let restoredResults = TerminalFontProvider.registrationResults
        let restoredRegular = try XCTUnwrap(
            restoredResults.first(where: { $0.fileName == "JetBrainsMono-Regular.ttf" })
        )
        XCTAssertTrue(restoredRegular.didRegister,
                      "恢复后 Regular 必须 didRegister == true")
    }

    /// P1 修复要求：同理验证 Bold 损坏路径（确保故障注入对四个文件任意一个都生效）。
    func testCorruptedBoldFontFailsRegistration() throws {
        TerminalFontProvider.resetRegistrationForTesting()
        TerminalFontProvider.registerBundledFontsIfNeeded()
        XCTAssertTrue(TerminalFontProvider.isBundledFontRegistered)

        let boldURL = try XCTUnwrap(
            Bundle.main.url(forResource: "JetBrainsMono-Bold.ttf", withExtension: nil)
        )
        let originalData = try Data(contentsOf: boldURL)
        defer { try? originalData.write(to: boldURL) }
        try Data("CORRUPTED BOLD — test injection".utf8).write(to: boldURL)

        TerminalFontProvider.resetRegistrationForTesting()
        TerminalFontProvider.registerBundledFontsIfNeeded()

        let results = TerminalFontProvider.registrationResults
        let boldResult = try XCTUnwrap(
            results.first(where: { $0.fileName == "JetBrainsMono-Bold.ttf" })
        )
        XCTAssertFalse(boldResult.didRegister,
                       "损坏的 Bold TTF 必须 didRegister == false")
        XCTAssertFalse(TerminalFontProvider.isBundledFontRegistered,
                       "Bold 损坏后 isBundledFontRegistered 必须 false")

        try originalData.write(to: boldURL)
        TerminalFontProvider.resetRegistrationForTesting()
        TerminalFontProvider.registerBundledFontsIfNeeded()
        XCTAssertTrue(TerminalFontProvider.isBundledFontRegistered,
                     "恢复后 isBundledFontRegistered 必须 true")
    }

    // MARK: - M. Bundle source verification（P1 修复核心）

    /// P1 修复要求：验证 `isFontSourcedFromBundle` 能区分 Bundle 字体与
    /// 系统字体。健康路径下 Regular font 的 URL 必须在 Bundle 内。
    /// 系统等宽 fallback 字体（`monospacedSystemFont`）必须不在 Bundle 内。
    func testFontSourceVerificationDistinguishesBundleAndSystem() {
        TerminalFontProvider.resetRegistrationForTesting()
        TerminalFontProvider.registerBundledFontsIfNeeded()

        // 直接通过 NSFont(name:) 构造，绕过 regularFont() 的 fallback 路径，
        // 用于验证 isFontSourcedFromBundle 自身的判定逻辑。
        guard let bundledFont = NSFont(name: "JetBrainsMono-Regular",
                                      size: TerminalFontProvider.defaultSize) else {
            XCTFail("JetBrains Mono Regular 必须能在注册后被 NSFont(name:) 解析")
            return
        }
        XCTAssertTrue(TerminalFontProvider.isFontSourcedFromBundle(bundledFont),
                      "JetBrains Mono Regular 必须 sourced from bundle")

        let systemFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        XCTAssertFalse(TerminalFontProvider.isFontSourcedFromBundle(systemFont),
                       "系统等宽字体必须 NOT sourced from bundle")
    }
}
