import AppKit
import Foundation
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 8：`AppAppearanceController` 单元测试（任务书 §36 / §37 / §41 / §43）。
///
/// 覆盖：
/// - 默认 → system（无偏好）
/// - persist / reload system / light / dark
/// - invalid persisted value → system（不 Crash）
/// - system apply → NSApp.appearance nil；light → .aqua；dark → .darkAqua
/// - setMode 经 didSet 持久化并 apply（单一 writer，任务书 §9 / §43）
/// - no-change case：resolved 已 Dark、requested system→dark 仍 persist + apply（§16 / §41）
/// - 测试隔离：独立 UserDefaults suite，不污染 standard（§37）
@MainActor
final class AppAppearanceControllerTests: XCTestCase {

    // MARK: - 默认 system

    /// 无偏好时 controller.mode == .system，且 init apply 把 NSApp.appearance 设为 nil。
    func testDefaultModeIsSystemAndAppliesNil() throws {
        let defaults = try makeIsolatedDefaults()
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        XCTAssertEqual(controller.mode, .system)
        // init 显式 apply 一次：system → appearance nil。
        XCTAssertEqual(recorder.calls, [nil] as [NSAppearance?])
    }

    // MARK: - persist / apply 各模式

    /// setMode(.system) → 持久化 system + apply nil。
    func testSetModeSystemPersistsAndApplies() throws {
        let defaults = try makeIsolatedDefaults()
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        controller.setMode(.light) // 先切 light 制造非 system 起点
        controller.setMode(.system)

        XCTAssertEqual(controller.mode, .system)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "system")
        XCTAssertEqual(recorder.calls.last, nil as NSAppearance?)
    }

    func testSetModeLightPersistsAndAppliesAqua() throws {
        let defaults = try makeIsolatedDefaults()
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        controller.setMode(.light)

        XCTAssertEqual(controller.mode, .light)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "light")
        XCTAssertEqual(recorder.calls.last, NSAppearance(named: .aqua))
    }

    func testSetModeDarkPersistsAndAppliesDarkAqua() throws {
        let defaults = try makeIsolatedDefaults()
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        controller.setMode(.dark)

        XCTAssertEqual(controller.mode, .dark)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "dark")
        XCTAssertEqual(recorder.calls.last, NSAppearance(named: .darkAqua))
    }

    // MARK: - reload

    /// 已持久化 system → 新 controller reload .system，init apply nil。
    func testReloadSystemAppliesNil() throws {
        let defaults = try makeIsolatedDefaults()
        AppAppearanceMode.system.save(to: defaults)
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        XCTAssertEqual(controller.mode, .system)
        XCTAssertEqual(recorder.calls, [nil] as [NSAppearance?])
    }

    func testReloadLightAppliesAqua() throws {
        let defaults = try makeIsolatedDefaults()
        AppAppearanceMode.light.save(to: defaults)
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        XCTAssertEqual(controller.mode, .light)
        XCTAssertEqual(recorder.calls, [NSAppearance(named: .aqua)])
    }

    func testReloadDarkAppliesDarkAqua() throws {
        let defaults = try makeIsolatedDefaults()
        AppAppearanceMode.dark.save(to: defaults)
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        XCTAssertEqual(controller.mode, .dark)
        XCTAssertEqual(recorder.calls, [NSAppearance(named: .darkAqua)])
    }

    // MARK: - invalid persisted value → system

    /// UserDefaults 存在 future / 损坏值时 reload 安全回退 system，不 Crash。
    func testInvalidPersistedValueFallsBackToSystem() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("futureValue", forKey: AppPreferenceKey.appearanceMode)

        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        XCTAssertEqual(controller.mode, .system)
        XCTAssertEqual(recorder.calls, [nil] as [NSAppearance?])
    }

    // MARK: - mode change 经 didSet 持久化并 apply（单一 writer）

    /// setMode 经 mode setter → didSet 持久化 + apply。每次 setMode 增加一次 setter 调用。
    func testSetModeTriggersPersistAndApplyPerCall() throws {
        let defaults = try makeIsolatedDefaults()
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        let initialCallCount = recorder.calls.count
        controller.setMode(.dark)
        XCTAssertEqual(recorder.calls.count, initialCallCount + 1)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "dark")

        controller.setMode(.light)
        XCTAssertEqual(recorder.calls.count, initialCallCount + 2)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "light")

        controller.setMode(.system)
        XCTAssertEqual(recorder.calls.count, initialCallCount + 3)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "system")
    }

    /// 单一 writer（任务书 §9）：只有 controller 写 appearanceMode key，
    /// setMode 后 defaults 中该 key 反映 requested rawValue。
    func testControllerIsSoleWriterOfAppearancePreference() throws {
        let defaults = try makeIsolatedDefaults()
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        for mode in AppAppearanceMode.allCases {
            controller.setMode(mode)
            XCTAssertEqual(
                defaults.string(forKey: AppPreferenceKey.appearanceMode),
                mode.rawValue,
                "setMode 后 appearanceMode 必须为 \(mode.rawValue)"
            )
        }
    }

    // MARK: - no-change / resolved-unchanged case（任务书 §16 / §41）

    /// 系统已 Dark（resolved = darkAqua），requested system→dark。即使 resolved
    /// effectiveAppearance 不产生有意义模式变化，显式 apply 仍执行，且 requested
    /// 必须保存为 dark（任务书 §16 / §41）。
    func testSystemToDarkWhenResolvedAlreadyDarkStillPersistsAndApplies() throws {
        let defaults = try makeIsolatedDefaults()
        let recorder = AppearanceRecorder()
        // resolved 已 Dark（模拟系统处于深色）。
        let resolvedAppearance: NSAppearance? = NSAppearance(named: .darkAqua)
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { resolvedAppearance },
            observationInstaller: { _ in TerminalAppearanceObservationToken(invalidate: {}) }
        )
        let controller = AppAppearanceController(
            userDefaults: defaults,
            coordinator: coordinator,
            appearanceSetter: { recorder.record($0) }
        )

        // 默认 system；init apply 设 nil（system），不因 resolved 已 dark 而跳过。
        XCTAssertEqual(controller.mode, .system)
        XCTAssertEqual(recorder.calls, [nil] as [NSAppearance?])

        // requested system → dark：resolved 仍 dark，但显式 apply 必须执行 +
        // requested 必须持久化为 dark。
        controller.setMode(.dark)
        XCTAssertEqual(controller.mode, .dark)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "dark")
        // setter 收到 darkAqua（system 的 nil 之后）。
        XCTAssertEqual(recorder.calls, [nil, NSAppearance(named: .darkAqua)] as [NSAppearance?])
        // resolved 未被改变（setter 不改 resolvedAppearance——本测试只验证 controller 路径）。
        XCTAssertEqual(resolvedAppearance, NSAppearance(named: .darkAqua))
    }

    /// 显式 controller.apply() 不依赖 mode 变化即可刷新（任务书 §41）。
    func testExplicitApplyReassertsRequestedAppearance() throws {
        let defaults = try makeIsolatedDefaults()
        AppAppearanceMode.dark.save(to: defaults)
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        let callsBefore = recorder.calls.count
        controller.apply() // 显式 apply，mode 未变
        XCTAssertEqual(recorder.calls.count, callsBefore + 1)
        XCTAssertEqual(recorder.calls.last, NSAppearance(named: .darkAqua))
        // requested mode 不变。
        XCTAssertEqual(controller.mode, .dark)
    }

    // MARK: - cold launch lifecycle（GUI Remediation Round 1 / 任务书 §12）

    /// 冷启动 lifecycle 模拟：persisted dark → controller init（early apply）
    /// → lifecycle stable reapply（`applicationDidFinishLaunching` 等价调用
    /// `apply()`）→ appearance setter 最后值为 darkAqua。
    ///
    /// 复现 GUI FAIL #1 的修复语义：init 内 apply 设置一次，lifecycle 稳定点
    /// reapply 再设置一次，最终 setter 收到 darkAqua（不被 framework 覆盖，
    /// 因测试只断言 controller 路径的最终值，framework 覆盖由真实 lifecycle
    /// hook 修复）。
    func testColdLaunchPersistedDarkStableReapplyDarkAqua() throws {
        let defaults = try makeIsolatedDefaults()
        AppAppearanceMode.dark.save(to: defaults)
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        // init early apply：recorder 已收到 darkAqua 一次。
        XCTAssertEqual(controller.mode, .dark)
        XCTAssertEqual(recorder.calls, [NSAppearance(named: .darkAqua)])

        // 模拟 applicationDidFinishLaunching 稳定点 reapply（任务书 §11 幂等）。
        controller.apply()
        XCTAssertEqual(recorder.calls.count, 2)
        // 最终 setter 值仍为 darkAqua。
        XCTAssertEqual(recorder.calls.last, NSAppearance(named: .darkAqua))
        // requested mode 未被 reapply 改写。
        XCTAssertEqual(controller.mode, .dark)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "dark")
    }

    /// persisted light → init apply + stable reapply → 最终 aqua。
    func testColdLaunchPersistedLightStableReapplyAqua() throws {
        let defaults = try makeIsolatedDefaults()
        AppAppearanceMode.light.save(to: defaults)
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        XCTAssertEqual(controller.mode, .light)
        XCTAssertEqual(recorder.calls, [NSAppearance(named: .aqua)])

        controller.apply()
        XCTAssertEqual(recorder.calls.count, 2)
        XCTAssertEqual(recorder.calls.last, NSAppearance(named: .aqua))
        XCTAssertEqual(controller.mode, .light)
    }

    /// persisted system → init apply + stable reapply → 最终 nil（跟随系统）。
    func testColdLaunchPersistedSystemStableReapplyNil() throws {
        let defaults = try makeIsolatedDefaults()
        AppAppearanceMode.system.save(to: defaults)
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        XCTAssertEqual(controller.mode, .system)
        XCTAssertEqual(recorder.calls, [nil] as [NSAppearance?])

        controller.apply()
        XCTAssertEqual(recorder.calls.count, 2)
        XCTAssertEqual(recorder.calls.last, nil as NSAppearance?)
        XCTAssertEqual(controller.mode, .system)
    }

    /// cold launch 无偏好（旧用户升级）→ 默认 system → init + reapply 均 nil，
    /// 保持跟随系统默认体验（任务书 §5）。
    func testColdLaunchNoPreferenceDefaultsSystemReapplyNil() throws {
        let defaults = try makeIsolatedDefaults()
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        XCTAssertEqual(controller.mode, .system)
        XCTAssertEqual(recorder.calls, [nil] as [NSAppearance?])

        controller.apply()
        XCTAssertEqual(recorder.calls.count, 2)
        XCTAssertEqual(recorder.calls.last, nil as NSAppearance?)
    }

    /// cold launch idempotency（§11）：多次 stable reapply 不改 requested mode、
    /// 不写异常 UserDefaults、不产生非预期 setter 调用外的副作用。
    func testColdLaunchMultipleStableReappliesAreIdempotent() throws {
        let defaults = try makeIsolatedDefaults()
        AppAppearanceMode.dark.save(to: defaults)
        let recorder = AppearanceRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        // init apply 1 次 + 3 次 lifecycle reapply = 4 次 setter 调用。
        controller.apply()
        controller.apply()
        controller.apply()
        XCTAssertEqual(recorder.calls.count, 4)
        // 每次都是 darkAqua。
        for value in recorder.calls {
            XCTAssertEqual(value, NSAppearance(named: .darkAqua))
        }
        // requested mode 与持久化值未变。
        XCTAssertEqual(controller.mode, .dark)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.appearanceMode), "dark")
    }

    // MARK: - 工具

    /// 捕获 controller 设置的 NSAppearance 序列，用于断言 nil / .aqua / .darkAqua。
    private final class AppearanceRecorder {
        private(set) var calls: [NSAppearance?] = []
        func record(_ appearance: NSAppearance?) { calls.append(appearance) }
    }

    /// 装配 controller：注入隔离 defaults + 测试 coordinator（resolved 固定 light）
    /// + 捕获 setter。
    private func makeController(
        defaults: UserDefaults,
        recorder: AppearanceRecorder
    ) -> AppAppearanceController {
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .aqua) },
            observationInstaller: { _ in TerminalAppearanceObservationToken(invalidate: {}) }
        )
        return AppAppearanceController(
            userDefaults: defaults,
            coordinator: coordinator,
            appearanceSetter: { recorder.record($0) }
        )
    }

    /// 用临时 suite 隔离 UserDefaults，绝不动用户真实偏好（任务书 §37）。
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "MacSSH.AppAppearanceControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "AppAppearanceControllerTests", code: 1, userInfo: nil)
        }
        return defaults
    }
}
