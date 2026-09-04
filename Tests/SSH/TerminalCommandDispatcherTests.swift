import SwiftData
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 7：TerminalCommandDispatcher 测试（任务书 §69 / Phase 7A 验收 §74）。
///
/// 用 `resolveActive` 闭包注入 mock `ActiveInputTarget`，记录 pasteText/sendReturn/restoreFocus 调用，
/// 不依赖真实 SwiftTerm TerminalView 或 SessionManager。
final class TerminalCommandDispatcherTests: XCTestCase {

    /// Mock input target：记录 pasteText/sendReturn/restoreFocus 调用。
    @MainActor
    private final class MockInputTarget {
        private(set) var pastedTexts: [String] = []
        private(set) var returnCount = 0
        private(set) var focusCount = 0

        func pasteText(_ text: String) { pastedTexts.append(text) }
        func sendReturn() { returnCount += 1 }
        func restoreFocus() { focusCount += 1 }
    }

    @MainActor
    private func makeDispatcher(mock: MockInputTarget) -> (dispatcher: TerminalCommandDispatcher, mock: MockInputTarget) {
        // 用最小 SessionManager + CommandHistoryStore。
        let sshService = SSHService(modelContainer: try! ModelContainer(
            for: Schema([Host.self, HostGroup.self, KnownHost.self]),
            configurations: [ModelConfiguration("DispTest", isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        ))
        let sessionManager = SessionManager(sshService: sshService)
        let historyContainer = try! ModelContainer(
            for: Schema([SavedCommandGroup.self, SavedCommand.self, CommandHistoryEntry.self]),
            configurations: [ModelConfiguration("HistTest", isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let historyStore = CommandHistoryStore(
            modelContainer: historyContainer,
            userDefaults: UserDefaults(suiteName: "DispTest-\(UUID().uuidString)")!
        )
        let target = ActiveInputTarget(
            pasteText: { mock.pasteText($0) },
            sendReturn: { mock.sendReturn() },
            restoreFocus: { mock.restoreFocus() },
            sessionID: UUID(),
            sessionKind: "local",
            hostDisplayName: nil
        )
        let dispatcher = TerminalCommandDispatcher(
            sessionManager: sessionManager,
            historyStore: historyStore,
            resolveActive: { target }
        )
        return (dispatcher, mock)
    }

    // MARK: - Paste

    @MainActor
    func testPasteSendsCommandOnly() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        dispatcher.paste(command: "git status")
        XCTAssertEqual(mock.pastedTexts, ["git status"])
        XCTAssertEqual(mock.returnCount, 0, "Paste 不应发送 Return")
    }

    @MainActor
    func testPasteNoHistory() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        dispatcher.paste(command: "git status")
        // Paste 不记 history——historyStore 应为空。
        XCTAssertEqual(dispatcher.historyStore.recentEntries().count, 0)
    }

    @MainActor
    func testPasteRestoresFocus() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        dispatcher.paste(command: "ls")
        XCTAssertEqual(mock.focusCount, 1)
    }

    // MARK: - Execute

    @MainActor
    func testExecuteSendsCommandAndReturn() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        dispatcher.execute(command: "git status", source: .savedCommand)
        XCTAssertEqual(mock.pastedTexts, ["git status"])
        XCTAssertEqual(mock.returnCount, 1, "Execute 应发送一次 Return")
    }

    @MainActor
    func testExecuteAppendsHistory() {
        let (dispatcher, _) = makeDispatcher(mock: MockInputTarget())
        dispatcher.execute(command: "git status", source: .savedCommand)
        let entries = dispatcher.historyStore.recentEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.command, "git status")
        XCTAssertEqual(entries.first?.source, "savedCommand")
    }

    @MainActor
    func testHistoryReplayAppendsNewEntry() {
        let (dispatcher, _) = makeDispatcher(mock: MockInputTarget())
        dispatcher.execute(command: "ls", source: .savedCommand)
        dispatcher.execute(command: "ls", source: .historyReplay)
        let entries = dispatcher.historyStore.recentEntries()
        XCTAssertEqual(entries.count, 2, "History replay 应再新增一条")
        // recentEntries 按 executedAt 降序（newest first）；replay 是最新一条。
        XCTAssertEqual(entries.first?.source, "historyReplay")
    }

    @MainActor
    func testExecuteRestoresFocus() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        dispatcher.execute(command: "ls", source: .savedCommand)
        XCTAssertEqual(mock.focusCount, 1)
    }

    // MARK: - No active target

    @MainActor
    func testNoActiveTargetIsNoOp() {
        let sshService = SSHService(modelContainer: try! ModelContainer(
            for: Schema([Host.self, HostGroup.self, KnownHost.self]),
            configurations: [ModelConfiguration("NoTarget", isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        ))
        let sessionManager = SessionManager(sshService: sshService)
        let historyContainer = try! ModelContainer(
            for: Schema([SavedCommandGroup.self, SavedCommand.self, CommandHistoryEntry.self]),
            configurations: [ModelConfiguration("NoTargetHist", isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let historyStore = CommandHistoryStore(
            modelContainer: historyContainer,
            userDefaults: UserDefaults(suiteName: "NoTarget-\(UUID().uuidString)")!
        )
        // resolveActive 返回 nil（无 active terminal）。
        let dispatcher = TerminalCommandDispatcher(
            sessionManager: sessionManager,
            historyStore: historyStore,
            resolveActive: { nil }
        )
        dispatcher.paste(command: "ls")
        dispatcher.execute(command: "ls", source: .savedCommand)
        XCTAssertEqual(historyStore.recentEntries().count, 0, "无 active target 时不应记 history")
    }

    @MainActor
    func testRapidExecuteOrdering() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        for cmd in ["a", "b", "c", "d"] {
            dispatcher.execute(command: cmd, source: .savedCommand)
        }
        XCTAssertEqual(mock.pastedTexts, ["a", "b", "c", "d"], "快速连续 Execute 应按序发送")
        XCTAssertEqual(mock.returnCount, 4)
    }

    // MARK: - UTF-8 / quotes

    @MainActor
    func testUTF8Preserved() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        dispatcher.paste(command: "echo '中文 😀'")
        XCTAssertEqual(mock.pastedTexts, ["echo '中文 😀'"])
    }

    @MainActor
    func testQuotesPreserved() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        let cmd = "printf '%s\\n' \"$HOME test\""
        dispatcher.paste(command: cmd)
        XCTAssertEqual(mock.pastedTexts, [cmd])
    }

    @MainActor
    func testLeadingSpacesPreserved() {
        let (dispatcher, mock) = makeDispatcher(mock: MockInputTarget())
        dispatcher.paste(command: "  echo test")
        XCTAssertEqual(mock.pastedTexts, ["  echo test"])
    }
}
