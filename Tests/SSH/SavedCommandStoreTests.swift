import SwiftData
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 7：SavedCommandStore 测试（任务书 §70 / Phase 7A 验收）。
@MainActor
final class SavedCommandStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var store: SavedCommandStore!

    override func setUpWithError() throws {
        let schema = Schema([
            SavedCommandGroup.self,
            SavedCommand.self,
            CommandHistoryEntry.self
        ])
        let config = ModelConfiguration(
            "SavedCommandStoreTest",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [config])
        store = SavedCommandStore(modelContainer: container)
    }

    // MARK: - Group CRUD

    func testAddGroup() throws {
        let group = try store.addGroup(name: "Git")
        XCTAssertEqual(group.name, "Git")
        XCTAssertFalse(group.id == UUID())
        XCTAssertEqual(store.allGroups().count, 1)
    }

    func testAddGroupRejectsEmptyName() {
        XCTAssertThrowsError(try store.addGroup(name: "")) { error in
            XCTAssertEqual(error as? SavedCommandError, .emptyGroupName)
        }
        XCTAssertThrowsError(try store.addGroup(name: "   ")) { error in
            XCTAssertEqual(error as? SavedCommandError, .emptyGroupName)
        }
    }

    func testRenameGroup() throws {
        let group = try store.addGroup(name: "Old")
        try store.renameGroup(id: group.id, name: "New")
        let fetched = store.allGroups().first
        XCTAssertEqual(fetched?.name, "New")
    }

    func testDeleteGroupNullifiesCommands() throws {
        let group = try store.addGroup(name: "Git")
        _ = try store.addCommand(command: "git status", groupID: group.id)
        _ = try store.addCommand(command: "git pull", groupID: group.id)

        try store.deleteGroup(id: group.id)

        XCTAssertEqual(store.allGroups().count, 0)
        // Commands moved to ungrouped (not deleted).
        XCTAssertEqual(store.ungroupedCommands().count, 2)
    }

    // MARK: - Command CRUD + validation

    func testAddCommand() throws {
        _ = try store.addCommand(command: "git status")
        XCTAssertEqual(store.ungroupedCommands().count, 1)
        XCTAssertEqual(store.ungroupedCommands().first?.command, "git status")
    }

    func testRejectsEmptyCommand() {
        XCTAssertThrowsError(try store.addCommand(command: "")) { error in
            XCTAssertEqual(error as? SavedCommandError, .invalidCommand)
        }
        XCTAssertThrowsError(try store.addCommand(command: "   ")) { error in
            XCTAssertEqual(error as? SavedCommandError, .invalidCommand)
        }
    }

    func testRejectsMultilineCommand() {
        XCTAssertThrowsError(try store.addCommand(command: "a\nb")) { error in
            XCTAssertEqual(error as? SavedCommandError, .invalidCommand)
        }
        XCTAssertThrowsError(try store.addCommand(command: "a\rb")) { error in
            XCTAssertEqual(error as? SavedCommandError, .invalidCommand)
        }
        XCTAssertThrowsError(try store.addCommand(command: "a\r\nb")) { error in
            XCTAssertEqual(error as? SavedCommandError, .invalidCommand)
        }
    }

    func testRejectsNUL() {
        XCTAssertThrowsError(try store.addCommand(command: "echo \u{0}")) { error in
            XCTAssertEqual(error as? SavedCommandError, .invalidCommand)
        }
    }

    func testRejectsUnicodeLineSeparators() {
        XCTAssertThrowsError(try store.addCommand(command: "a\u{2028}b")) { error in
            XCTAssertEqual(error as? SavedCommandError, .invalidCommand)
        }
        XCTAssertThrowsError(try store.addCommand(command: "a\u{2029}b")) { error in
            XCTAssertEqual(error as? SavedCommandError, .invalidCommand)
        }
    }

    func testAllowsTAB() throws {
        _ = try store.addCommand(command: "echo\ttest")
        XCTAssertEqual(store.ungroupedCommands().first?.command, "echo\ttest")
    }

    func testAllowsESC() throws {
        _ = try store.addCommand(command: "printf '\\e[31mred\\e[0m'")
        XCTAssertEqual(store.ungroupedCommands().first?.command, "printf '\\e[31mred\\e[0m'")
    }

    func testAllowsBEL() throws {
        _ = try store.addCommand(command: "printf '\\a'")
        XCTAssertEqual(store.ungroupedCommands().first?.command, "printf '\\a'")
    }

    func testPreservesLeadingWhitespace() throws {
        _ = try store.addCommand(command: "  echo test")
        XCTAssertEqual(store.ungroupedCommands().first?.command, "  echo test")
    }

    func testAllowsSingleLineMultiCommand() throws {
        _ = try store.addCommand(command: "cd /tmp && ls")
        XCTAssertEqual(store.ungroupedCommands().first?.command, "cd /tmp && ls")
    }

    func testUpdateCommand() throws {
        let cmd = try store.addCommand(command: "git status")
        try store.updateCommand(id: cmd.id, command: "git pull")
        XCTAssertEqual(store.ungroupedCommands().first?.command, "git pull")
    }

    func testDeleteCommand() throws {
        let cmd = try store.addCommand(command: "git status")
        try store.deleteCommand(id: cmd.id)
        XCTAssertEqual(store.ungroupedCommands().count, 0)
    }

    func testDeleteCommandIdempotent() throws {
        try store.deleteCommand(id: UUID()) // 不 crash
    }

    // MARK: - Remediation P2：Group Rename relationship 保持 + Grouped Command Edit 保持 group

    /// 任务书 §18 / 验收 §31/§4：Rename 必须真正 rename 原对象，
    /// 不创建新 group 再删旧 group（避免破坏 relationship）。
    /// 验证：rename 后同一 id、name 更新、内部 commands 关系不变。
    func testRenameGroupPreservesCommandsRelationship() throws {
        let group = try store.addGroup(name: "Git")
        let originalGroupID = group.id
        let cmd1 = try store.addCommand(command: "git status", groupID: group.id)
        let cmd2 = try store.addCommand(command: "git pull", groupID: group.id)
        XCTAssertEqual(store.commands(inGroup: group.id).count, 2)

        try store.renameGroup(id: group.id, name: "Git Tools")

        // 同一 id（真正 rename 原对象，未删后建）。allGroups() 非 throwing。
        let renamed = store.allGroups().first { $0.id == originalGroupID }
        XCTAssertEqual(renamed?.name, "Git Tools", "rename 应更新 name")
        XCTAssertEqual(renamed?.id, originalGroupID, "rename 不得改变 group id")
        // commands 关系不变：仍属该 group，数量不变，group 引用 id 不变。
        let groupedCommands = store.commands(inGroup: originalGroupID)
        XCTAssertEqual(groupedCommands.count, 2, "rename 不应破坏 command-group relationship")
        XCTAssertTrue(groupedCommands.contains { $0.id == cmd1.id })
        XCTAssertTrue(groupedCommands.contains { $0.id == cmd2.id })
        XCTAssertEqual(groupedCommands.first?.group?.id, originalGroupID)
    }

    /// 验收 §19：grouped command Edit 后 command 更新、group id 保持不变（不脱离分组）。
    /// 修复 P2-3（原分组内 Edit 为空操作）的回归保护：确保 update API 真正作用于分组内命令。
    func testUpdateGroupedCommandPreservesGroup() throws {
        let group = try store.addGroup(name: "Docker")
        let cmd = try store.addCommand(command: "git status", groupID: group.id)
        let originalGroupID = group.id

        try store.updateCommand(id: cmd.id, command: "git status --short")

        // command 文本更新。
        let updated = store.commands(inGroup: originalGroupID).first { $0.id == cmd.id }
        XCTAssertEqual(updated?.command, "git status --short")
        // group 关系保持（仍属原 group）。
        XCTAssertEqual(updated?.group?.id, originalGroupID, "编辑分组内命令不得改变其 group")
        // 该 group 仍含此命令，未变成未分组。
        XCTAssertEqual(store.commands(inGroup: originalGroupID).count, 1)
        XCTAssertEqual(store.ungroupedCommands().count, 0, "编辑不得把命令移出分组到未分组")
    }

    // MARK: - GUI Acceptance Round 1 Remediation 2：分组内新增命令

    /// GUI Acceptance Round 1 FAIL #2 修复回归：分组内新增命令必须直接绑定 target group。
    /// 验证 §10：command.group?.id == group.id；commands(inGroup:) 立即含该 command；
    /// 不先显示在 Ungrouped；ungroupedCommands() 为 0。
    func testAddCommandToGroupBindsTargetGroup() throws {
        let group = try store.addGroup(name: "Git")

        let cmd = try store.addCommand(command: "git status", groupID: group.id)

        XCTAssertEqual(cmd.group?.id, group.id, "新增命令应直接绑定 target group")
        let grouped = store.commands(inGroup: group.id)
        XCTAssertEqual(grouped.count, 1, "commands(inGroup:) 应立即包含该 command")
        XCTAssertEqual(grouped.first?.id, cmd.id)
        XCTAssertEqual(store.ungroupedCommands().count, 0, "分组内新增命令不得先进入 Ungrouped")
    }
}
