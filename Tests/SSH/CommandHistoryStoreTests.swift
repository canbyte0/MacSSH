import SwiftData
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 7：CommandHistoryStore 测试（任务书 §71 / Phase 7A 验收）。
@MainActor
final class CommandHistoryStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var store: CommandHistoryStore!
    private let testDefaults = UserDefaults(suiteName: "CommandHistoryStoreTest-\(UUID().uuidString)")!

    override func setUpWithError() throws {
        let schema = Schema([
            SavedCommandGroup.self,
            SavedCommand.self,
            CommandHistoryEntry.self
        ])
        let config = ModelConfiguration(
            "CommandHistoryStoreTest",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [config])
        testDefaults.set(true, forKey: CommandHistoryStore.historyEnabledKey)
        store = CommandHistoryStore(
            modelContainer: container,
            userDefaults: testDefaults
        )
    }

    // MARK: - historyEnabled

    func testHistoryEnabledDefaultOn() {
        let freshDefaults = UserDefaults(suiteName: "Fresh-\(UUID().uuidString)")!
        let freshStore = CommandHistoryStore(modelContainer: container, userDefaults: freshDefaults)
        XCTAssertTrue(freshStore.historyEnabled, "historyEnabled 默认应为 On")
    }

    func testDisabledDoesNotWrite() {
        store.historyEnabled = false
        store.append(command: "ls", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        XCTAssertEqual(store.recentEntries().count, 0, "historyEnabled=false 时不应写入")
    }

    // MARK: - append

    func testAppendExecute() {
        store.append(command: "git status", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        XCTAssertEqual(store.recentEntries().count, 1)
        XCTAssertEqual(store.recentEntries().first?.command, "git status")
    }

    func testNoPasteRecord() {
        // Paste 不调用 append——这里只验证 append 本身不受外部影响。
        // 实际 Paste 不记 history 的逻辑在 Dispatcher 层（Paste 不调 append）。
        store.append(command: "git status", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        XCTAssertEqual(store.recentEntries().count, 1)
    }

    func testReplayAppend() {
        store.append(command: "ls", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "ls", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "historyReplay")
        XCTAssertEqual(store.recentEntries().count, 2, "History replay 应再新增一条")
    }

    func testEntriesForSession() {
        let sessionID = UUID()
        store.append(command: "ls", sessionID: sessionID, sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "pwd", sessionID: UUID(), sessionKind: "remoteSSH", hostDisplayName: "server", source: "savedCommand")
        XCTAssertEqual(store.entries(forSession: sessionID).count, 1)
        XCTAssertEqual(store.entries(forSession: sessionID).first?.command, "ls")
    }

    func testClosedSessionPersistence() {
        let sessionID = UUID()
        store.append(command: "ls", sessionID: sessionID, sessionKind: "remoteSSH", hostDisplayName: "web-01", source: "savedCommand")
        // session 对象销毁后，history 仍可通过 hostDisplayName 快照显示。
        let entry = store.recentEntries().first
        XCTAssertEqual(entry?.hostDisplayName, "web-01")
        XCTAssertEqual(entry?.sessionKind, "remoteSSH")
    }

    // MARK: - retention

    func testRetentionPrunesOldest() {
        for i in 0..<(CommandHistoryStore.maxEntries + 10) {
            store.append(
                command: "cmd\(i)",
                sessionID: UUID(),
                sessionKind: "local",
                hostDisplayName: nil,
                source: "savedCommand"
            )
        }
        XCTAssertEqual(store.recentEntries().count, CommandHistoryStore.maxEntries)
        // 最旧的 10 条（cmd0..cmd9）应被删除。
        let allCommands = store.recentEntries().map { $0.command }
        XCTAssertFalse(allCommands.contains("cmd0"), "最旧条目应被 prune")
        XCTAssertFalse(allCommands.contains("cmd9"), "第 10 条也应被 prune")
        XCTAssertTrue(allCommands.contains("cmd\(CommandHistoryStore.maxEntries + 9)"), "最新条目应保留")
    }

    // MARK: - clear

    func testClear() {
        store.append(command: "ls", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "pwd", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.clear()
        XCTAssertEqual(store.recentEntries().count, 0)
    }

    func testClearOnlyDeletesHistory() throws {
        // 确保 clear 不删 SavedCommand/Groups（这些在不同 Store）。
        let cmdStore = SavedCommandStore(modelContainer: container)
        _ = try cmdStore.addCommand(command: "git status")
        store.clear()
        XCTAssertEqual(cmdStore.ungroupedCommands().count, 1, "clear history 不应删 SavedCommand")
    }
}
