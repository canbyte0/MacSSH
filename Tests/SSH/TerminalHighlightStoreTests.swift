import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 6：终端高亮 Store 测试。
///
/// 覆盖任务书第 52 节 persistence tests：
/// - empty defaults
/// - round trip
/// - invalid JSON fallback
/// - disabled global
/// - rule order
/// - color rawValue
/// - schema backward compatibility
@MainActor
final class TerminalHighlightStoreTests: XCTestCase {

    // MARK: - Defaults

    /// key 不存在时回退默认（enabled=true, rules=[]）。
    func testEmptyDefaultsWhenKeyMissing() {
        let defaults = UserDefaults(suiteName: "test.highlight.empty.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().first!.key)
        let store = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertTrue(store.settings.isHighlightEnabled)
        XCTAssertTrue(store.settings.rules.isEmpty)
    }

    // MARK: - Round trip

    func testRoundTrip() {
        let defaults = UserDefaults(suiteName: "test.highlight.roundtrip.\(UUID().uuidString)")!
        let store = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertTrue(store.addRule(text: "ERROR", color: .red, isCaseSensitive: true))
        XCTAssertTrue(store.addRule(text: "warning", color: .yellow, isCaseSensitive: false))
        XCTAssertEqual(store.settings.rules.count, 2)
        XCTAssertEqual(store.settings.rules[0].text, "ERROR")
        XCTAssertEqual(store.settings.rules[0].color, .red)
        XCTAssertEqual(store.settings.rules[1].text, "warning")
        XCTAssertEqual(store.settings.rules[1].color, .yellow)

        // 重新加载——从 UserDefaults 恢复
        let reloaded = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.settings.rules.count, 2)
        XCTAssertEqual(reloaded.settings.rules[0].text, "ERROR")
        XCTAssertEqual(reloaded.settings.rules[1].text, "warning")
    }

    // MARK: - Invalid JSON fallback

    func testInvalidJSONFallsBackToDefaults() {
        let suite = "test.highlight.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // 写入损坏 JSON
        defaults.set(Data("{\"isHighlightEnabled\":\"notabool\"}".utf8),
                     forKey: TerminalHighlightStore.storageKey)
        let store = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertTrue(store.settings.isHighlightEnabled, "损坏 JSON 回退默认 enabled=true")
        XCTAssertTrue(store.settings.rules.isEmpty, "损坏 JSON 回退默认 rules=[]")
    }

    // MARK: - Disabled global

    func testSetHighlightEnabledFalse() {
        let defaults = UserDefaults(suiteName: "test.highlight.disabled.\(UUID().uuidString)")!
        let store = TerminalHighlightStore(userDefaults: defaults)
        store.setHighlightEnabled(false)
        XCTAssertFalse(store.settings.isHighlightEnabled)
        // 持久化生效
        let reloaded = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.settings.isHighlightEnabled)
    }

    // MARK: - Rule order

    func testSortedRulesBySortOrderThenId() {
        let defaults = UserDefaults(suiteName: "test.highlight.order.\(UUID().uuidString)")!
        let store = TerminalHighlightStore(userDefaults: defaults)
        // addRule 自动追加 sortOrder；但这里测试自定义 sortOrder 排序
        store.replaceAllRules([
            TerminalHighlightRule(id: UUID(), text: "C", color: .blue,
                                  isCaseSensitive: true, isEnabled: true, sortOrder: 2),
            TerminalHighlightRule(id: UUID(), text: "A", color: .red,
                                  isCaseSensitive: true, isEnabled: true, sortOrder: 0),
            TerminalHighlightRule(id: UUID(), text: "B", color: .yellow,
                                  isCaseSensitive: true, isEnabled: true, sortOrder: 1),
        ])
        let sorted = store.settings.sortedRules
        XCTAssertEqual(sorted.map(\.text), ["A", "B", "C"])
    }

    // MARK: - Color rawValue

    func testColorRawValueStable() {
        XCTAssertEqual(TerminalHighlightColor.red.rawValue, "red")
        XCTAssertEqual(TerminalHighlightColor.orange.rawValue, "orange")
        XCTAssertEqual(TerminalHighlightColor.yellow.rawValue, "yellow")
        XCTAssertEqual(TerminalHighlightColor.green.rawValue, "green")
        XCTAssertEqual(TerminalHighlightColor.blue.rawValue, "blue")
        XCTAssertEqual(TerminalHighlightColor.purple.rawValue, "purple")
        XCTAssertEqual(TerminalHighlightColor.gray.rawValue, "gray")
    }

    // MARK: - Schema backward compatibility

    /// 新增 optional 字段时老 JSON 不 crash。
    /// 模拟：只有 isHighlightEnabled + rules（每条只有 id+text+color），
    /// 缺 isCaseSensitive/isEnabled/sortOrder → 回退默认。
    func testSchemaBackwardCompatibility() {
        let suite = "test.highlight.schema.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // 构造"老格式" JSON：规则只有 id + text + color
        let oldJSON = """
        {"isHighlightEnabled": true, "rules": [
            {"id": "00000000-0000-0000-0000-000000000001", "text": "ERROR", "color": "red"}
        ]}
        """
        defaults.set(Data(oldJSON.utf8), forKey: TerminalHighlightStore.storageKey)
        let store = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertEqual(store.settings.rules.count, 1)
        XCTAssertEqual(store.settings.rules[0].text, "ERROR")
        // 缺失字段回退默认
        XCTAssertEqual(store.settings.rules[0].isCaseSensitive, false)
        XCTAssertEqual(store.settings.rules[0].isEnabled, true)
        XCTAssertEqual(store.settings.rules[0].sortOrder, 0)
    }

    // MARK: - Empty rule defense

    func testAddRuleRejectsEmptyText() {
        let defaults = UserDefaults(suiteName: "test.highlight.emptyrule.\(UUID().uuidString)")!
        let store = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertFalse(store.addRule(text: "", color: .red, isCaseSensitive: true))
        XCTAssertFalse(store.addRule(text: "   ", color: .red, isCaseSensitive: true))
        XCTAssertTrue(store.settings.rules.isEmpty)
    }

    // MARK: - CRUD

    func testUpdateRule() {
        let defaults = UserDefaults(suiteName: "test.highlight.update.\(UUID().uuidString)")!
        let store = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertTrue(store.addRule(text: "ERROR", color: .red, isCaseSensitive: true))
        let id = store.settings.rules[0].id
        XCTAssertTrue(store.updateRule(id: id, text: "WARNING", color: .yellow,
                                      isCaseSensitive: false, isEnabled: false))
        XCTAssertEqual(store.settings.rules[0].text, "WARNING")
        XCTAssertEqual(store.settings.rules[0].color, .yellow)
        XCTAssertFalse(store.settings.rules[0].isCaseSensitive)
        XCTAssertFalse(store.settings.rules[0].isEnabled)
    }

    func testDeleteRule() {
        let defaults = UserDefaults(suiteName: "test.highlight.delete.\(UUID().uuidString)")!
        let store = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertTrue(store.addRule(text: "ERROR", color: .red, isCaseSensitive: true))
        let id = store.settings.rules[0].id
        XCTAssertTrue(store.deleteRule(id: id))
        XCTAssertTrue(store.settings.rules.isEmpty)
        // 重复删除幂等
        XCTAssertFalse(store.deleteRule(id: id))
    }

    func testSetRuleEnabled() {
        let defaults = UserDefaults(suiteName: "test.highlight.toggle.\(UUID().uuidString)")!
        let store = TerminalHighlightStore(userDefaults: defaults)
        XCTAssertTrue(store.addRule(text: "ERROR", color: .red, isCaseSensitive: true))
        let id = store.settings.rules[0].id
        store.setRuleEnabled(id: id, isEnabled: false)
        XCTAssertFalse(store.settings.rules[0].isEnabled)
        store.setRuleEnabled(id: id, isEnabled: true)
        XCTAssertTrue(store.settings.rules[0].isEnabled)
    }

    // MARK: - 变更通知

    func testOnSettingsChangedFiresOnAnyMutation() {
        let defaults = UserDefaults(suiteName: "test.highlight.notify.\(UUID().uuidString)")!
        let store = TerminalHighlightStore(userDefaults: defaults)
        var callCount = 0
        store.onSettingsChanged = { callCount += 1 }
        store.setHighlightEnabled(false)     // 1
        store.addRule(text: "ERROR", color: .red, isCaseSensitive: true)  // 2
        let id = store.settings.rules[0].id
        store.setRuleEnabled(id: id, isEnabled: false)  // 3
        store.deleteRule(id: id)             // 4
        XCTAssertEqual(callCount, 4, "每次变更都应触发回调")
    }
}
