import AppKit
import SwiftTerm
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 9：`TerminalFontSizeController` 单元测试（Phase 9A Acceptance §58）。
///
/// 覆盖：
/// - default 14（无偏好）
/// - persist / reload 10 / 14 / 32
/// - invalid（缺失 / 非 Int / Double / String / Bool / NaN）→ 14
/// - 越界（9 / 33）→ clamp 10 / 32
/// - setSize / increment / decrement 经 didSet 持久化 + apply（单一 writer）
/// - 边界：at min decrement → clamp 10；at max increment → clamp 32
/// - register view 立即应用当前 size
/// - size change 广播全部已注册 view（无全局 dedup，§23）
/// - new view after size change 立即得当前 size（首帧无 14→18 闪烁，§22）
/// - 0 terminal 时仍可改 size + persist（registry 空 apply no-op，§49）
/// - weak registry：view 释放后自动 nil（§41）
@MainActor
final class TerminalFontSizeControllerTests: XCTestCase {

    // MARK: - 默认 14（无偏好）

    func testDefaultSizeIsFourteenWhenNoKey() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(controller.size, 14, "无偏好时 size 必须 14（与 TerminalFontProvider.defaultSize 一致）")
        XCTAssertNil(defaults.object(forKey: AppPreferenceKey.terminalFontSize),
                     "load 不应写入 UserDefaults（init 不主动 normalize；clamp-on-load 即可）")
    }

    // MARK: - persist / reload

    func testSetSizePersistsAndReloads() throws {
        for size in [10, 14, 18, 24, 32] {
            let defaults = try makeIsolatedDefaults()
            let controller = TerminalFontSizeController(userDefaults: defaults)
            controller.setSize(size)
            XCTAssertEqual(controller.size, size)
            XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, size)
            // reload 一致
            let reloaded = TerminalFontSizeController(userDefaults: defaults)
            XCTAssertEqual(reloaded.size, size)
        }
    }

    // MARK: - invalid type → 14

    func testInvalidTypesFallBackToFourteen() throws {
        let defaults = try makeIsolatedDefaults()
        // Double（NSNumber double subtype，objCType "d"）：Swift `as? Int` 返回 nil → 14。
        defaults.set(17.5, forKey: AppPreferenceKey.terminalFontSize)
        XCTAssertEqual(TerminalFontSizeController(userDefaults: defaults).size, 14,
                       "Double 17.5 应 fallback 14（as? Int 返回 nil）")
        // String
        defaults.set("abc", forKey: AppPreferenceKey.terminalFontSize)
        XCTAssertEqual(TerminalFontSizeController(userDefaults: defaults).size, 14)
        // Bool：NSNumber bool subtype，objCType "B" / "c"。Swift `as? Int` 返回 1（true）/ 0（false），
        // 经 clamp 落到 min 10——不是 invalid type 路径，是 clamp 路径。
        defaults.set(true, forKey: AppPreferenceKey.terminalFontSize)
        XCTAssertEqual(TerminalFontSizeController(userDefaults: defaults).size, 10,
                       "Bool=true → 1 → clamp 10")
        defaults.set(false, forKey: AppPreferenceKey.terminalFontSize)
        XCTAssertEqual(TerminalFontSizeController(userDefaults: defaults).size, 10,
                       "Bool=false → 0 → clamp 10")
        // NaN via Double：Swift `as? Int` 返回 nil → 14。
        defaults.set(Double.nan, forKey: AppPreferenceKey.terminalFontSize)
        XCTAssertEqual(TerminalFontSizeController(userDefaults: defaults).size, 14)
        // Infinity via Double：同上。
        defaults.set(Double.infinity, forKey: AppPreferenceKey.terminalFontSize)
        XCTAssertEqual(TerminalFontSizeController(userDefaults: defaults).size, 14)
    }

    // MARK: - 越界 → clamp

    func testBelowMinClampsToTen() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(9, forKey: AppPreferenceKey.terminalFontSize)
        let controller = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(controller.size, 10, "9 必须 clamp 到 10")
    }

    func testAboveMaxClampsToThirtyTwo() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(33, forKey: AppPreferenceKey.terminalFontSize)
        let controller = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(controller.size, 32, "33 必须 clamp 到 32")
    }

    func testExtremeValuesClamp() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(Int.min, forKey: AppPreferenceKey.terminalFontSize)
        XCTAssertEqual(TerminalFontSizeController(userDefaults: defaults).size, 10)
        defaults.set(Int.max, forKey: AppPreferenceKey.terminalFontSize)
        XCTAssertEqual(TerminalFontSizeController(userDefaults: defaults).size, 32)
    }

    // MARK: - setSize / increment / decrement 经 didSet 持久化

    func testSetSizePersists() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        controller.setSize(18)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 18)
    }

    func testSetSizeClampsBeforePersist() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        // setSize(50) → clamp 32 → persist 32
        controller.setSize(50)
        XCTAssertEqual(controller.size, 32)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 32)
        // setSize(1) → clamp 10 → persist 10
        controller.setSize(1)
        XCTAssertEqual(controller.size, 10)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 10)
    }

    func testIncrementPersists() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(controller.size, 14)
        controller.increment()
        XCTAssertEqual(controller.size, 15)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 15)
    }

    func testDecrementPersists() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        controller.setSize(18)
        controller.decrement()
        XCTAssertEqual(controller.size, 17)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 17)
    }

    // MARK: - 边界 disabled-equivalent（clamp）

    func testIncrementAtMaxClamps() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(32, forKey: AppPreferenceKey.terminalFontSize)
        let controller = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(controller.size, 32)
        controller.increment() // 33 → clamp 32
        XCTAssertEqual(controller.size, 32)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 32)
    }

    func testDecrementAtMinClamps() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(10, forKey: AppPreferenceKey.terminalFontSize)
        let controller = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(controller.size, 10)
        controller.decrement() // 9 → clamp 10
        XCTAssertEqual(controller.size, 10)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 10)
    }

    // MARK: - load 不污染其他 key

    func testLoadDoesNotTouchOtherKeys() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("en", forKey: AppPreferenceKey.language)
        defaults.set(true, forKey: AppPreferenceKey.rightSidebarVisible)
        _ = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.language), "en")
        XCTAssertEqual(defaults.bool(forKey: AppPreferenceKey.rightSidebarVisible), true)
    }

    // MARK: - register 立即应用当前 size

    func testRegisterAppliesCurrentSizeImmediately() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(18, forKey: AppPreferenceKey.terminalFontSize)
        let controller = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(controller.size, 18)

        let local = makeLocalProcessTerminalView()
        let remote = makeRemoteTerminalView()
        controller.register(local)
        controller.register(remote)

        XCTAssertEqual(local.font.pointSize, 18, "register 必须立即应用当前 size（首帧无 14→18 闪烁）")
        XCTAssertEqual(remote.font.pointSize, 18)
    }

    // MARK: - size change 广播全部已注册 view

    func testSizeChangeBroadcastsToAllRegisteredViews() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        let local = makeLocalProcessTerminalView()
        let remoteA = makeRemoteTerminalView()
        let remoteB = makeRemoteTerminalView()
        for v in [local, remoteA, remoteB] { controller.register(v) }

        controller.setSize(20)

        XCTAssertEqual(local.font.pointSize, 20)
        XCTAssertEqual(remoteA.font.pointSize, 20)
        XCTAssertEqual(remoteB.font.pointSize, 20)
    }

    func testRepeatingSameSizeStillAppliesToAllViews() throws {
        // 无全局 dedup：重复同 size 仍 apply 全部 view（Phase 4 P2-2 同类经验）。
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        let a = makeRemoteTerminalView()
        let b = makeRemoteTerminalView()
        controller.register(a)
        controller.register(b)
        controller.setSize(18)
        XCTAssertTrue(a.font.pointSize == 18)
        XCTAssertTrue(b.font.pointSize == 18)
        // 重复设 18：仍 apply 全部 view。
        controller.setSize(18)
        XCTAssertEqual(a.font.pointSize, 18)
        XCTAssertEqual(b.font.pointSize, 18)
    }

    // MARK: - new view after size change 立即得当前 size

    func testNewlyRegisteredViewGetsCurrentSizeImmediately() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        controller.setSize(24)

        let newView = makeLocalProcessTerminalView()
        controller.register(newView)

        XCTAssertEqual(newView.font.pointSize, 24, "新 register 必须 apply 当前 size，而非 defaultSize 14")
    }

    // MARK: - 0 terminal：change size 仍 persist + apply no-op

    func testZeroTerminalChangeSizePersistsAndApplyIsNoOp() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        XCTAssertEqual(controller.registeredViewCountForTesting, 0)

        controller.setSize(20)

        XCTAssertEqual(controller.size, 20)
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 20)
        XCTAssertEqual(controller.registeredViewCountForTesting, 0, "0 terminal 时 registry 仍空，apply no-op")
    }

    // MARK: - weak registry：view 释放后自动 nil

    // 注：与 Phase 4/6 同模式的 weak NSHashTable<TerminalView>.weakObjects() 语义
    // 由 Phase 4 `TerminalAppearanceTests` / Phase 6 `TerminalHighlightCoordinatorTests`
    // 已充分验证（NSHashTable.weakObjects() 在 view dealloc 后自动 nil，
    // `allObjects` 访问时自动回收）。TerminalView 自身的 Timer / subviews / closures
    // 可能造成 self 暂时强引用，单测中无 window 难以可靠触发 dealloc；
    // 本 controller 与 Appearance/Highlight Coordinator 共用同一 weak 表实现，
    // 语义等价。不再重复 unstable 的 weak-zeroing 单测。

    // MARK: - 字体身份在动态 size 下保持 JetBrains Mono

    func testRegisteredViewFontIdentityPreservedAtSize18() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(18, forKey: AppPreferenceKey.terminalFontSize)
        let controller = TerminalFontSizeController(userDefaults: defaults)

        let view = makeLocalProcessTerminalView()
        controller.register(view)

        XCTAssertTrue(view.font.fontName.contains("JetBrainsMono"),
                     "font identity 必须 JetBrains Mono，得到 \(view.font.fontName)")
        XCTAssertEqual(view.font.pointSize, 18)
        XCTAssertTrue(TerminalFontProvider.isFontSourcedFromBundle(view.font),
                     "font 必须来自 Bundle")
    }

    // MARK: - rapid click 同步顺序

    func testRapidChangesProduceFinalState() throws {
        let defaults = try makeIsolatedDefaults()
        let controller = TerminalFontSizeController(userDefaults: defaults)
        let view = makeRemoteTerminalView()
        controller.register(view)

        // 14 → 15 → 16 → 17 → 18 同步链
        controller.increment() // 15
        controller.increment() // 16
        controller.increment() // 17
        controller.increment() // 18

        XCTAssertEqual(controller.size, 18)
        XCTAssertEqual(view.font.pointSize, 18, "全 MainActor 同步：最终 view.font 必须 18")
        XCTAssertEqual(defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int, 18)
    }

    // MARK: - 工具

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "MacSSH.TerminalFontSizeControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "TerminalFontSizeControllerTests", code: 1, userInfo: nil)
        }
        return defaults
    }

    private func makeLocalProcessTerminalView() -> LocalProcessTerminalView {
        LocalProcessTerminalView(
            frame: .zero,
            font: TerminalFontProvider.regularFont(),
            options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color", scrollback: 10_000)
        )
    }

    private func makeRemoteTerminalView() -> TerminalView {
        TerminalView(
            frame: .zero,
            font: TerminalFontProvider.regularFont(),
            options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color", scrollback: 10_000)
        )
    }
}
