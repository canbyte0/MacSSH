import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 7B GUI Acceptance Remediation 2：Saved Commands global empty-state 判定逻辑测试。
///
/// 验证 `SavedCommandsSidebarContent.shouldShowGlobalEmpty(groups:, commands:)`：
/// global empty 只有在 groups 与 commands 均为空时才为 true。
/// 存在空 group（即使 0 command）不得判为 global empty（否则会隐藏刚创建的空分组，
/// GUI Acceptance Round 1 FAIL #1 根因）。
final class SavedCommandsSidebarContentTests: XCTestCase {

    // A. 0 groups + 0 commands → global empty = true
    func testNoGroupsNoCommandsIsGlobalEmpty() {
        XCTAssertTrue(SavedCommandsSidebarContent.shouldShowGlobalEmpty(groups: [], commands: []))
    }

    // B. 1 empty group + 0 commands → global empty = false（空分组必须可见）
    func testOneEmptyGroupNoCommandsIsNotGlobalEmpty() {
        let group = SavedCommandGroup(name: "Git", sortOrder: 0)
        XCTAssertFalse(SavedCommandsSidebarContent.shouldShowGlobalEmpty(groups: [group], commands: []))
    }

    // C. 0 groups + 1 ungrouped command → false
    func testNoGroupsOneUngroupedCommandIsNotGlobalEmpty() {
        let cmd = SavedCommand(command: "ls", group: nil, sortOrder: 0)
        XCTAssertFalse(SavedCommandsSidebarContent.shouldShowGlobalEmpty(groups: [], commands: [cmd]))
    }

    // D. 1 group + 1 grouped command → false
    func testOneGroupOneGroupedCommandIsNotGlobalEmpty() {
        let group = SavedCommandGroup(name: "Git", sortOrder: 0)
        let cmd = SavedCommand(command: "git status", group: group, sortOrder: 0)
        XCTAssertFalse(SavedCommandsSidebarContent.shouldShowGlobalEmpty(groups: [group], commands: [cmd]))
    }

    // E. multiple empty groups + 0 commands → false
    func testMultipleEmptyGroupsNoCommandsIsNotGlobalEmpty() {
        let groups = [
            SavedCommandGroup(name: "Git", sortOrder: 0),
            SavedCommandGroup(name: "Docker", sortOrder: 1)
        ]
        XCTAssertFalse(SavedCommandsSidebarContent.shouldShowGlobalEmpty(groups: groups, commands: []))
    }

    /// Immediate group visibility：groups=[Git], commands=[] → globalEmpty false，
    /// 且 visible groups 应包含 Git（listContent 会渲染 groupList，即 Git 立即可见）。
    func testImmediateGroupVisibilityWhenNoCommands() {
        let git = SavedCommandGroup(name: "Git", sortOrder: 0)
        let groups = [git]
        let globalEmpty = SavedCommandsSidebarContent.shouldShowGlobalEmpty(groups: groups, commands: [])
        XCTAssertFalse(globalEmpty, "存在 group 时不得显示 global empty，分组应立即可见")
        XCTAssertTrue(groups.contains { $0.id == git.id }, "Git 仍在 visible groups 中")
    }
}
