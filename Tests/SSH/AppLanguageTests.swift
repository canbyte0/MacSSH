import Foundation
import SwiftData
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 1：AppLanguage 单元测试。
///
/// 覆盖：
/// - 默认语言为 zh-Hans（无论系统 Locale）
/// - locale identifier 与 rawValue 一致
/// - 合法偏好持久化与恢复
/// - 非法 / 损坏偏好安全 fallback 为 zh-Hans
/// - Picker 显示名始终为语言自身（不随 App Locale 切换）
/// - 语言切换绝不重建 Runtime（Session / Manager 实例稳定）
final class AppLanguageTests: XCTestCase {
    // MARK: - 默认语言

    /// 任务书第四节：无保存偏好时始终回退简体中文，
    /// 不跟随系统语言。这是 MacSSH 1.1 的硬性产品要求。
    func testDefaultLanguageIsSimplifiedChinese() {
        XCTAssertEqual(AppLanguage.defaultLanguage, .simplifiedChinese)
        XCTAssertEqual(AppLanguage.defaultLanguage.rawValue, "zh-Hans")
    }

    // MARK: - Locale identifier

    /// 注入 SwiftUI 的 Locale identifier 与 rawValue 完全一致，
    /// 避免项目内散落 "zh" / "zh_CN" / "zh-Hans" / "en-US" / "en"。
    func testLocaleIdentifiersAreStable() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.locale.identifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.english.locale.identifier, "en")
    }

    // MARK: - 持久化往返

    /// 用户切换 English 后持久化 rawValue，UserDefaults 的值必须
    /// 与 rawValue 严格一致（不写"英文"等本地化字面量）。
    func testEnglishPreferenceRoundTrip() throws {
        let defaults = try makeIsolatedDefaults()
        AppLanguage.english.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.language), "en")
        XCTAssertEqual(AppLanguage.load(from: defaults), .english)
    }

    func testSimplifiedChinesePreferenceRoundTrip() throws {
        let defaults = try makeIsolatedDefaults()
        AppLanguage.simplifiedChinese.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.language), "zh-Hans")
        XCTAssertEqual(AppLanguage.load(from: defaults), .simplifiedChinese)
    }

    // MARK: - 非法偏好 fallback

    /// 任务书七十七：UserDefaults 被人为写入不支持的语言（fr / xxx）
    /// 时不得 Crash，必须安全回退 zh-Hans。
    func testInvalidPreferenceFallsBackToSimplifiedChinese() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("fr", forKey: AppPreferenceKey.language)
        XCTAssertEqual(AppLanguage.load(from: defaults), .simplifiedChinese)

        defaults.set("xxx", forKey: AppPreferenceKey.language)
        XCTAssertEqual(AppLanguage.load(from: defaults), .simplifiedChinese)
    }

    /// 完全没有保存偏好时也回退 zh-Hans（首次启动场景）。
    func testMissingPreferenceFallsBackToSimplifiedChinese() throws {
        let defaults = try makeIsolatedDefaults()
        XCTAssertNil(defaults.string(forKey: AppPreferenceKey.language))
        XCTAssertEqual(AppLanguage.load(from: defaults), .simplifiedChinese)
    }

    // MARK: - Picker 显示名稳定性

    /// 任务书第六节：语言 Picker 中的选项名称固定使用语言自身写法，
    /// 不随 App Locale 切换——误切 English 后仍能看到"简体中文"入口。
    func testPickerDisplayNameIsLanguageNative() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.displayName, "简体中文")
        XCTAssertEqual(AppLanguage.english.displayName, "English")
    }

    // MARK: - CaseIterable

    /// Picker 顺序稳定：简体中文在前，English 在后。
    func testCaseIterableOrderIsStable() {
        XCTAssertEqual(AppLanguage.allCases.first, .simplifiedChinese)
        XCTAssertEqual(AppLanguage.allCases.last, .english)
        XCTAssertEqual(AppLanguage.allCases.count, 2)
    }

    // MARK: - 语言切换运行时稳定性（任务书十八 / 六十七 / 七十二）

    /// 任务书十八（最高风险点）：语言改变只能更新 UI。
    /// 连续切换 20 次（任务书六十七）后，SessionManager /
    /// TransferManager / SSHService 实例必须保持同一对象，
    /// Local Shell 的 Service 引用与 Session 数量 / 激活指针全部不变。
    @MainActor
    func testRapidLanguageSwitchingNeverRebuildsRuntime() throws {
        let appState = try makeAppState()
        let manager = appState.sessionManager
        let transfers = appState.transferManager
        let sshService = appState.sshService

        // 启动即拥有一个 Local Terminal（SessionManager init 语义）。
        let initialSession = try XCTUnwrap(manager.activeSession)
        let initialLocalService = initialSession.localService
        let initialSessionID = initialSession.id

        // 任务书六十七：连续 20 次快速切换，不得 Crash / 重建 / 泄漏。
        for index in 0..<20 {
            appState.language = index.isMultiple(of: 2)
                ? .english
                : .simplifiedChinese
        }

        // Runtime 身份完全保持：AppState 不因语言切换重建。
        XCTAssertTrue(appState.sessionManager === manager, "SessionManager 绝不重建")
        XCTAssertTrue(appState.transferManager === transfers, "TransferManager 绝不重建")
        XCTAssertTrue(appState.sshService === sshService, "SSHService 绝不重建")

        // Local Shell 会话保持：数量、ID、激活指针、Service 实例不变。
        XCTAssertEqual(manager.sessions.count, 1, "Local Session 数量不变")
        XCTAssertEqual(manager.activeSessionID, initialSessionID, "激活指针不变")
        XCTAssertEqual(manager.sessions.first?.id, initialSessionID)
        XCTAssertTrue(manager.sessions.first?.localService === initialLocalService, "Local Shell 运行时不重建")

        // 技术名语言无关（任务书三十四一致性：编号与标识稳定）。
        XCTAssertEqual(initialSession.title, "Local")
        XCTAssertEqual(initialSession.titleCounter, 1)
    }

    /// 语言切换后 Manager 的 Locale provider 立即反映新语言
    /// （动态文案入口，任务书七十三：不缓存启动时文案）。
    @MainActor
    func testLocaleProviderTracksLanguageChanges() throws {
        let appState = try makeAppState()
        let transfers = appState.transferManager

        appState.language = .english
        XCTAssertEqual(
            transfers.localeProvider?(),
            AppLanguage.english.locale,
            "切换 English 后 provider 必须立即返回 en"
        )

        appState.language = .simplifiedChinese
        XCTAssertEqual(
            transfers.localeProvider?(),
            AppLanguage.simplifiedChinese.locale,
            "切换中文后 provider 必须立即返回 zh-Hans"
        )
    }

    /// 切换语言只更新 Tab 显示文案，不改变技术名与编号
    /// （任务书三十三 / 三十四：displayTitle 本地化，title 稳定）。
    @MainActor
    func testDisplayTitleLocalizesWhileTechnicalTitleStaysStable() throws {
        let appState = try makeAppState()
        let session = try XCTUnwrap(appState.sessionManager.activeSession)

        XCTAssertEqual(session.title, "Local")
        XCTAssertEqual(
            session.displayTitle(locale: AppLanguage.simplifiedChinese.locale),
            "终端"
        )
        XCTAssertEqual(
            session.displayTitle(locale: AppLanguage.english.locale),
            "Local Terminal"
        )
        // 技术名不随语言变化。
        appState.language = .english
        XCTAssertEqual(session.title, "Local")
    }

    // MARK: - 工具

    /// 构造内存态 AppState（绝不动用户真实偏好 / 持久化存储）。
    @MainActor
    private func makeAppState() throws -> AppState {
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let suiteName = "MacSSH.AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return AppState(modelContainer: container, userDefaults: defaults)
    }

    /// 用临时 suite 隔离 UserDefaults，绝不动用户真实偏好。
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "MacSSH.AppLanguageTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "AppLanguageTests", code: 1, userInfo: nil)
        }
        return defaults
    }
}
