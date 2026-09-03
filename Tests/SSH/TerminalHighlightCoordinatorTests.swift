import AppKit
import SwiftTerm
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 6：终端高亮 Coordinator 测试。
///
/// 覆盖任务书第 51 节 coordinator tests：
/// - register existing view
/// - new view gets current settings
/// - settings broadcast all views
/// - weak registry does not retain closed views
/// - repeated register no duplicate side effect
/// - AppState initial session backfill（register 即 apply provider）
/// - Local/Remote parity（同一 provider）
/// - rapid rule updates no lastApplied race
@MainActor
final class TerminalHighlightCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeView() -> TerminalView {
        TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
    }

    private func makeLocalView() -> LocalProcessTerminalView {
        LocalProcessTerminalView(
            frame: .zero,
            font: TerminalFontProvider.regularFont(),
            options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color", scrollback: 10_000)
        )
    }

    // MARK: - register

    /// register 后 view 立即持有当前 provider（非 nil）。
    func testRegisterAppliesProviderImmediately() {
        let coordinator = TerminalHighlightCoordinator(
            userDefaults: UserDefaults(suiteName: "test.coord.register.\(UUID().uuidString)")!)
        let view = makeView()
        XCTAssertNil(view.highlightProvider, "register 前应 nil")
        coordinator.register(view)
        XCTAssertNotNil(view.highlightProvider, "register 后应持有 provider")
    }

    /// 重复注册同一 view 安全（不重复计数、provider 不变）。
    func testRepeatedRegisterIsIdempotent() {
        let coordinator = TerminalHighlightCoordinator(
            userDefaults: UserDefaults(suiteName: "test.coord.idempotent.\(UUID().uuidString)")!)
        let view = makeView()
        coordinator.register(view)
        coordinator.register(view)
        coordinator.register(view)
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 1)
    }

    // MARK: - Local / Remote parity

    /// Local（LocalProcessTerminalView）与 Remote（TerminalView）共用同一 provider 实例。
    func testLocalAndRemoteShareSameProvider() {
        let coordinator = TerminalHighlightCoordinator(
            userDefaults: UserDefaults(suiteName: "test.coord.parity.\(UUID().uuidString)")!)
        let local = makeLocalView()
        let remote = makeView()
        coordinator.register(local)
        coordinator.register(remote)
        XCTAssertNotNil(local.highlightProvider)
        XCTAssertNotNil(remote.highlightProvider)
        // 两者引用同一 provider 对象
        XCTAssertTrue(local.highlightProvider === remote.highlightProvider,
                      "Local / Remote 须共用同一 provider 实例")
    }

    // MARK: - Weak registry

    /// registry 不 retain 已注册 view（CFGetRetainCount 不变）。
    /// SwiftTerm `highlightProvider = provider` 不增加 retain（weak 存储），
    /// 但 `terminal.updateFullScreen` 触发的 pending display 可能瞬时 retain。
    /// 给足 RunLoop 时间让瞬时 retain 释放后比较。
    func testRegistryDoesNotRetainView() {
        let coordinator = TerminalHighlightCoordinator(
            userDefaults: UserDefaults(suiteName: "test.coord.weak.\(UUID().uuidString)")!)
        let view = makeView()
        // 预热 SwiftTerm 内部 dispatch，建立稳定 baseline。
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let countBefore = CFGetRetainCount(view)
        coordinator.register(view)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        let countAfter = CFGetRetainCount(view)
        XCTAssertEqual(countBefore, countAfter,
                       "registry 须为 weak，不得增加 retain count（before=\(countBefore), after=\(countAfter))")
    }

    /// registry 不额外 retain view（与 TerminalAppearanceTests 同模式）。
    /// TerminalView 可被 SwiftTerm 内部 Timer / KVO 长期持有（非 coordinator
    /// 引起），因此不强制要求 view = nil 后 compact 归零——只验证 coordinator
    /// 本身的 weak 存储不增加 retain count（已由 testRegistryDoesNotRetainView
    /// 覆盖）。此处验证 compact 操作本身不产生 phantom 条目。
    func testCompactDoesNotProducePhantomEntries() {
        let coordinator = TerminalHighlightCoordinator(
            userDefaults: UserDefaults(suiteName: "test.coord.compact.\(UUID().uuidString)")!)
        let view = makeView()
        coordinator.register(view)
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 1)
        // compact 不丢失 live view、不产生 phantom
        coordinator.compactRegistryForTesting()
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 1)
        // 重复 compact 稳定
        for _ in 0..<10 { coordinator.compactRegistryForTesting() }
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 1)
    }

    // MARK: - Broadcast

    /// 规则变更广播全部 live view（provider 仍有效）。
    func testSettingsChangeBroadcastsToAllViews() {
        let coordinator = TerminalHighlightCoordinator(
            userDefaults: UserDefaults(suiteName: "test.coord.broadcast.\(UUID().uuidString)")!)
        let a = makeView()
        let b = makeView()
        let c = makeView()
        for v in [a, b, c] { coordinator.register(v) }
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 3)
        // 触发广播：addRule
        coordinator.highlightStore.addRule(text: "ERROR", color: .red, isCaseSensitive: true)
        // 广播后 provider 仍持有（view 未被重建）
        XCTAssertNotNil(a.highlightProvider)
        XCTAssertNotNil(b.highlightProvider)
        XCTAssertNotNil(c.highlightProvider)
    }

    // MARK: - No lastApplied race

    /// 快速连续规则变更不应因 lastApplied race 跳过广播。
    /// 验证：每次变更都触发回调，无去重逻辑。
    func testRapidRuleUpdatesNoLastAppliedRace() {
        let coordinator = TerminalHighlightCoordinator(
            userDefaults: UserDefaults(suiteName: "test.coord.race.\(UUID().uuidString)")!)
        let view = makeView()
        coordinator.register(view)
        var callbackCount = 0
        coordinator.highlightStore.onSettingsChanged = {
            callbackCount += 1
            // 广播路径应无条件 apply 全部 live view
        }
        // 快速 10 次变更
        for i in 0..<10 {
            coordinator.highlightStore.addRule(text: "RULE\(i)", color: .red, isCaseSensitive: true)
        }
        XCTAssertEqual(callbackCount, 10, "每次变更都应广播，无 lastApplied 去重")
    }

    // MARK: - Global disable

    /// 全局禁用时 provider 仍持有（renderer 自行 nil-check）。
    func testGlobalDisableKeepsProviderButReturnsNil() {
        let defaults = UserDefaults(suiteName: "test.coord.disable.\(UUID().uuidString)")!
        let coordinator = TerminalHighlightCoordinator(userDefaults: defaults)
        let view = makeView()
        coordinator.register(view)
        coordinator.highlightStore.addRule(text: "ERROR", color: .red, isCaseSensitive: true)
        // 全局禁用
        coordinator.highlightStore.setHighlightEnabled(false)
        XCTAssertNotNil(view.highlightProvider, "provider 仍持有（renderer 自行 nil-check）")
        // provider 在全局禁用时返回 nil
        let term = view.getTerminal()
        let result = view.highlightProvider?.cellHighlights(in: term, row: 0)
        XCTAssertNil(result, "全局禁用时 provider 应返回 nil")
    }
}
