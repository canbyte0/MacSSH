import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 7：右侧栏状态测试（任务书 §73 / Phase 7A 验收）。
@MainActor
final class TerminalRightSidebarStateTests: XCTestCase {

    func testCommandSidebarTabRawValues() {
        XCTAssertEqual(CommandSidebarTab.history.rawValue, "history")
        XCTAssertEqual(CommandSidebarTab.savedCommands.rawValue, "savedCommands")
        XCTAssertEqual(CommandSidebarTab.allCases.count, 2)
    }

    func testCommandSidebarTabSystemImages() {
        XCTAssertEqual(CommandSidebarTab.history.systemImage, "clock.arrow.circlepath")
        // savedCommands 用 command.square（Phase 7A 验收 §58）
        XCTAssertEqual(CommandSidebarTab.savedCommands.systemImage, "command.square")
    }

    func testTabRoundTripFromRawValue() {
        XCTAssertEqual(CommandSidebarTab(rawValue: "history"), .history)
        XCTAssertEqual(CommandSidebarTab(rawValue: "savedCommands"), .savedCommands)
        XCTAssertNil(CommandSidebarTab(rawValue: "invalid"), "无效值应返回 nil")
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
}
