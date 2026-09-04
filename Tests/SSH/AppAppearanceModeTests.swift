import AppKit
import Foundation
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 8：`AppAppearanceMode` 单元测试（任务书 §42）。
///
/// 覆盖：
/// - raw values（system / light / dark）
/// - `CaseIterable` 顺序与数量
/// - 默认值 = `.system`（旧用户升级保持跟随系统，任务书 §5）
/// - 非法 / 损坏 / future 值安全回退 `.system`，不 Crash（任务书 §8）
/// - 持久化往返（save / load）
/// - `nsAppearance` 映射（nil / .aqua / .darkAqua，任务书 §13）
/// - 本地化选项身份（三 key 互异、zh-Hans / en 均非空且不同、不泄漏 raw key）
final class AppAppearanceModeTests: XCTestCase {

    // MARK: - raw values

    func testRawValues() {
        XCTAssertEqual(AppAppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppAppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppAppearanceMode.dark.rawValue, "dark")
    }

    // MARK: - 默认值

    /// 任务书 §5：默认 system，旧用户无偏好时保持跟随系统行为。
    func testDefaultModeIsSystem() {
        XCTAssertEqual(AppAppearanceMode.defaultMode, .system)
    }

    // MARK: - CaseIterable

    /// Picker 顺序稳定：system / light / dark。
    func testCaseIterableOrderAndCount() {
        XCTAssertEqual(AppAppearanceMode.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppAppearanceMode.allCases.count, 3)
        XCTAssertFalse(AppAppearanceMode.allCases.isEmpty)
    }

    // MARK: - 非法偏好 fallback（任务书 §8）

    /// 缺少偏好时回退 system。
    func testMissingPreferenceFallsBackToSystem() throws {
        let defaults = try makeIsolatedDefaults()
        XCTAssertNil(defaults.string(forKey: AppPreferenceKey.appearanceMode))
        XCTAssertEqual(AppAppearanceMode.load(from: defaults), .system)
    }

    /// 未知 / future 值回退 system，绝不 Crash。
    func testUnknownPreferenceFallsBackToSystem() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("futureValue", forKey: AppPreferenceKey.appearanceMode)
        XCTAssertEqual(AppAppearanceMode.load(from: defaults), .system)

        defaults.set("DARK", forKey: AppPreferenceKey.appearanceMode) // 大小写敏感
        XCTAssertEqual(AppAppearanceMode.load(from: defaults), .system)

        defaults.set("", forKey: AppPreferenceKey.appearanceMode)
        XCTAssertEqual(AppAppearanceMode.load(from: defaults), .system)
    }

    // MARK: - 持久化往返

    func testRoundTripPersistence() throws {
        let defaults = try makeIsolatedDefaults()
        for mode in AppAppearanceMode.allCases {
            mode.save(to: defaults)
            XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), mode.rawValue)
            XCTAssertEqual(AppAppearanceMode.load(from: defaults), mode)
        }
    }

    // MARK: - nsAppearance 映射（任务书 §13）

    func testNsAppearanceMapping() {
        XCTAssertNil(AppAppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppAppearanceMode.light.nsAppearance, NSAppearance(named: .aqua))
        XCTAssertEqual(AppAppearanceMode.dark.nsAppearance, NSAppearance(named: .darkAqua))
    }

    // MARK: - 本地化选项身份（任务书 §32）

    /// 三选项 key 互异；每个 key 在 zh-Hans / en 都有非空翻译、且互不相同、
    /// 不泄漏 raw key。
    func testLocalizedOptionKeysAreDistinctAndLocalized() {
        let keys = AppAppearanceMode.allCases.map(\.localizedOptionKey)
        XCTAssertEqual(Set(keys).count, 3, "三选项 key 必须互异")

        let zh = AppLanguage.simplifiedChinese.locale
        let en = AppLanguage.english.locale
        for mode in AppAppearanceMode.allCases {
            let zhValue = L10n.string(mode.localizedOptionKey, defaultValue: "", locale: zh)
            let enValue = L10n.string(mode.localizedOptionKey, defaultValue: "", locale: en)
            XCTAssertFalse(zhValue.isEmpty, "\(mode.rawValue) zh-Hans 翻译为空")
            XCTAssertFalse(enValue.isEmpty, "\(mode.rawValue) en 翻译为空")
            XCTAssertNotEqual(zhValue, enValue, "\(mode.rawValue) zh == en — 未本地化")
            XCTAssertNotEqual(zhValue, mode.localizedOptionKey, "\(mode.rawValue) zh 泄漏 raw key")
            XCTAssertNotEqual(enValue, mode.localizedOptionKey, "\(mode.rawValue) en 泄漏 raw key")
        }
    }

    /// 锁定具体文案（任务书 §32）：zh-Hans 跟随系统/浅色/深色，en Follow System/Light/Dark。
    func testLocalizedOptionValuesMatchSpec() {
        let zh = AppLanguage.simplifiedChinese.locale
        let en = AppLanguage.english.locale
        XCTAssertEqual(
            L10n.string(AppAppearanceMode.system.localizedOptionKey, defaultValue: "", locale: zh),
            "跟随系统"
        )
        XCTAssertEqual(
            L10n.string(AppAppearanceMode.light.localizedOptionKey, defaultValue: "", locale: zh),
            "浅色"
        )
        XCTAssertEqual(
            L10n.string(AppAppearanceMode.dark.localizedOptionKey, defaultValue: "", locale: zh),
            "深色"
        )
        XCTAssertEqual(
            L10n.string(AppAppearanceMode.system.localizedOptionKey, defaultValue: "", locale: en),
            "Follow System"
        )
        XCTAssertEqual(
            L10n.string(AppAppearanceMode.light.localizedOptionKey, defaultValue: "", locale: en),
            "Light"
        )
        XCTAssertEqual(
            L10n.string(AppAppearanceMode.dark.localizedOptionKey, defaultValue: "", locale: en),
            "Dark"
        )
    }

    // MARK: - 工具

    /// 用临时 suite 隔离 UserDefaults，绝不动用户真实偏好（任务书 §37）。
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "MacSSH.AppAppearanceModeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "AppAppearanceModeTests", code: 1, userInfo: nil)
        }
        return defaults
    }
}
