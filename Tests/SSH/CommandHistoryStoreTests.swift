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
        // 2026-09-05 去重语义：replay 相同命令不再新增重复行，
        // 而是刷新该行时间戳与 source 快照，使其保持最新并置顶。
        store.append(command: "ls", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "ls", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "historyReplay")
        let entries = store.recentEntries()
        XCTAssertEqual(entries.count, 1, "History replay 相同命令不应再新增重复行")
        XCTAssertEqual(entries.first?.source, "historyReplay", "source 快照应刷新为最近一次执行")
    }

    // MARK: - dedupe（2026-09-05 用户授权行为变更）

    func testAppendDuplicateKeepsSingleEntryWithLatestSnapshot() {
        let firstSession = UUID()
        let secondSession = UUID()
        store.append(command: "git status", sessionID: firstSession, sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "git status", sessionID: secondSession, sessionKind: "remoteSSH", hostDisplayName: "web-01", source: "historyReplay")
        let entries = store.recentEntries()
        XCTAssertEqual(entries.count, 1, "相同 command 只应保留一条")
        XCTAssertEqual(entries.first?.sessionID, secondSession, "sessionID 快照应刷新为最近一次执行")
        XCTAssertEqual(entries.first?.sessionKind, "remoteSSH")
        XCTAssertEqual(entries.first?.hostDisplayName, "web-01")
    }

    func testAppendDuplicateMovesToTop() {
        store.append(command: "aaa", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "bbb", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "ccc", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "aaa", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        let commands = store.recentEntries().map { $0.command }
        XCTAssertEqual(commands.count, 3, "重复命令不应新增行")
        XCTAssertEqual(commands.first, "aaa", "重复执行的命令应置顶到第一个")
        XCTAssertEqual(Set(commands).count, 3, "列表中不应存在重复 command")
    }

    func testInitMergesPreExistingDuplicates() throws {
        // 绕过 store 直接向容器插入重复行，模拟去重语义引入前的存量数据。
        let context = container.mainContext
        let old = CommandHistoryEntry(
            command: "pwd",
            executedAt: Date(timeIntervalSince1970: 1000),
            sessionID: UUID(),
            sessionKind: "local",
            hostDisplayName: nil,
            source: "savedCommand"
        )
        let newer = CommandHistoryEntry(
            command: "pwd",
            executedAt: Date(timeIntervalSince1970: 2000),
            sessionID: UUID(),
            sessionKind: "remoteSSH",
            hostDisplayName: "nas",
            source: "historyReplay"
        )
        context.insert(old)
        context.insert(newer)
        try context.save()

        // 新 store 初始化时应合并存量重复，保留 executedAt 最新的一条。
        let freshDefaults = UserDefaults(suiteName: "Merge-\(UUID().uuidString)")!
        let freshStore = CommandHistoryStore(modelContainer: container, userDefaults: freshDefaults)
        let entries = freshStore.recentEntries()
        XCTAssertEqual(entries.count, 1, "存量重复应合并为一条")
        XCTAssertEqual(entries.first?.id, newer.id, "应保留 executedAt 最新的一条")
        XCTAssertEqual(entries.first?.hostDisplayName, "nas")
    }

    func testDifferentCommandsAreNotDeduplicated() {
        store.append(command: "ls", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "ls -la", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        store.append(command: "ls ", sessionID: UUID(), sessionKind: "local", hostDisplayName: nil, source: "savedCommand")
        XCTAssertEqual(store.recentEntries().count, 3, "去重为精确匹配，不做 trim/规范化")
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
