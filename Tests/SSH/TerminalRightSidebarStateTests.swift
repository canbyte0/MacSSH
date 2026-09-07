import SwiftData
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 7：右侧栏状态测试（任务书 §73 / Phase 7A 验收）。
@MainActor
final class TerminalRightSidebarStateTests: XCTestCase {

    func testCommandSidebarTabRawValues() {
        XCTAssertEqual(CommandSidebarTab.history.rawValue, "history")
        XCTAssertEqual(CommandSidebarTab.savedCommands.rawValue, "savedCommands")
        // MacSSH 1.1 Phase 10B：Agent tab。
        XCTAssertEqual(CommandSidebarTab.agent.rawValue, "agent")
        XCTAssertEqual(CommandSidebarTab.allCases.count, 3)
        XCTAssertEqual(
            CommandSidebarTab.allCases,
            [.history, .savedCommands, .agent],
            "CaseIterable 顺序：history → savedCommands → agent"
        )
    }

    func testCommandSidebarTabSystemImages() {
        XCTAssertEqual(CommandSidebarTab.history.systemImage, "clock.arrow.circlepath")
        // savedCommands 用 command.square（Phase 7A 验收 §58）
        XCTAssertEqual(CommandSidebarTab.savedCommands.systemImage, "command.square")
        // agent 用 sparkles（Phase 10B 任务书 §3，不引入自定义图片资产）
        XCTAssertEqual(CommandSidebarTab.agent.systemImage, "sparkles")
    }

    func testTabRoundTripFromRawValue() {
        XCTAssertEqual(CommandSidebarTab(rawValue: "history"), .history)
        XCTAssertEqual(CommandSidebarTab(rawValue: "savedCommands"), .savedCommands)
        XCTAssertEqual(CommandSidebarTab(rawValue: "agent"), .agent)
        XCTAssertNil(CommandSidebarTab(rawValue: "invalid"), "无效值应返回 nil")
    }

    /// Phase 10B 任务书 §30：agent tab 的 persisted raw value 可恢复。
    @MainActor
    func testPersistedAgentTabRestores() throws {
        let appState = try makeAppState(storedTabRawValue: "agent")
        XCTAssertEqual(appState.selectedRightSidebarTab, .agent)
    }

    /// Phase 10B 任务书 §30：invalid stored value 回落 history（既有行为回归）。
    @MainActor
    func testInvalidPersistedTabFallsBackToHistory() throws {
        let appState = try makeAppState(storedTabRawValue: "bogus")
        XCTAssertEqual(appState.selectedRightSidebarTab, .history)
    }

    /// Agent tab 的 localizedTitle 按 Locale 解析（不缓存、不泄漏 raw key）。
    func testCommandSidebarTabLocalizedTitles() {
        let zh = CommandSidebarTab.agent.localizedTitle(locale: AppLanguage.simplifiedChinese.locale)
        let en = CommandSidebarTab.agent.localizedTitle(locale: AppLanguage.english.locale)
        XCTAssertEqual(zh, "智能助手")
        XCTAssertEqual(en, "Agent")
        XCTAssertNotEqual(zh, CommandSidebarTab.agent.rawValue)

        // 既有 tab 标题回归。
        XCTAssertEqual(
            CommandSidebarTab.history.localizedTitle(locale: AppLanguage.english.locale),
            "History"
        )
        XCTAssertEqual(
            CommandSidebarTab.savedCommands.localizedTitle(locale: AppLanguage.english.locale),
            "Saved Commands"
        )
    }

    /// 构造内存态 AppState（绝不动用户真实偏好 / 持久化存储），
    /// 可注入已持久化的 rightSidebarTab raw value。
    @MainActor
    private func makeAppState(storedTabRawValue: String?) throws -> AppState {
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let suiteName = "MacSSH.TerminalRightSidebarStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        if let storedTabRawValue {
            defaults.set(storedTabRawValue, forKey: AppPreferenceKey.rightSidebarTab)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return AppState(modelContainer: container, userDefaults: defaults)
    }

    func testAppPreferenceKeysExist() {
        XCTAssertEqual(AppPreferenceKey.rightSidebarVisible, "macssh.rightSidebarVisible")
        XCTAssertEqual(AppPreferenceKey.rightSidebarTab, "macssh.rightSidebarTab")
    }

    func testCommandHistoryStoreKey() {
        XCTAssertEqual(CommandHistoryStore.historyEnabledKey, "macssh.commandHistoryEnabled")
    }

    func testMaxEntries() {
        XCTAssertEqual(CommandHistoryStore.maxEntries, 1000)
    }

    /// 开启和关闭使用同一段 220 ms 动画，保持双向节奏一致。
    func testRightSidebarAnimationDuration() {
        XCTAssertEqual(AppTheme.SidebarMotion.duration, 0.22, accuracy: 0.0001)
    }

    /// 分组动画略短于整栏开合，确保内容展开与收起轻快且双向一致。
    func testRightSidebarGroupAnimationDuration() {
        XCTAssertEqual(AppTheme.SidebarMotion.groupDuration, 0.18, accuracy: 0.0001)
    }

    /// 默认值和静态范围与已确认的交互设计一致。
    func testRightSidebarWidthDefaultsAndBounds() {
        XCTAssertEqual(AppTheme.Layout.rightSidebarWidth, 300)
        XCTAssertEqual(AppTheme.Layout.rightSidebarMinimumWidth, 240)
        XCTAssertEqual(AppTheme.Layout.rightSidebarMaximumWidth, 520)
        XCTAssertEqual(AppTheme.Layout.terminalMinimumWidthBesideSidebar, 320)
        XCTAssertEqual(AppTheme.Layout.rightSidebarResizeHandleWidth, 7)
    }

    /// 主面板和右侧两种内容页必须使用相同的二级栏高度，防止横线错位回归。
    func testTerminalSecondaryBarHeight() {
        XCTAssertEqual(AppTheme.Layout.terminalSecondaryBarHeight, 28)
    }

    /// Terminal 标签必须在栏内留出四边间距，并保持圆角矩形而不是胶囊形。
    func testTerminalTabRoundedRectangleMetrics() {
        XCTAssertEqual(AppTheme.Layout.tabBarHeight, 42)
        XCTAssertEqual(AppTheme.Layout.terminalTabHeight, 34)
        XCTAssertEqual(AppTheme.Layout.terminalTabCornerRadius, 12)
        XCTAssertLessThan(
            AppTheme.Layout.terminalTabCornerRadius,
            AppTheme.Layout.terminalTabHeight / 2
        )
    }

    /// 宽窗口下建议值应稳定限制在 240...520 pt。
    func testRightSidebarWidthPolicyClampsToStaticBounds() {
        XCTAssertEqual(RightSidebarWidthPolicy.clamp(100, availableWidth: 1_200), 240)
        XCTAssertEqual(RightSidebarWidthPolicy.clamp(360, availableWidth: 1_200), 360)
        XCTAssertEqual(RightSidebarWidthPolicy.clamp(800, availableWidth: 1_200), 520)
    }

    /// 窗口较窄时动态上限应为 Terminal 保留至少 320 pt。
    func testRightSidebarWidthPolicyProtectsTerminalSpace() {
        let availableWidth: CGFloat = 700
        let expectedMaximum = availableWidth
            - AppTheme.Layout.terminalMinimumWidthBesideSidebar
            - AppTheme.Layout.rightSidebarResizeHandleWidth

        XCTAssertEqual(
            RightSidebarWidthPolicy.maximumWidth(availableWidth: availableWidth),
            expectedMaximum
        )
        XCTAssertEqual(
            RightSidebarWidthPolicy.clamp(500, availableWidth: availableWidth),
            expectedMaximum
        )
    }
}
