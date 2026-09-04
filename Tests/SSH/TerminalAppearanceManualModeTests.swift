import AppKit
import SwiftTerm
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 8：终端手动外观模式集成测试（任务书 §39 / §40 / §41）。
///
/// 经 harness 耦合「controller apply 设置 appearance」与「coordinator resolver
/// 读取 appearance」，忠实模拟生产中 `NSApp.appearance ↔ effectiveAppearance
/// ↔ coordinator resolver` 链路，不依赖真实 `NSApplication` 生命周期。
///
/// 覆盖：
/// - 2+ existing views：manual Light → 全 Light；manual Dark → 全 Dark
/// - new registered view → 立即得到当前 resolved appearance（首帧无白闪，§22）
/// - explicit apply → 全部已注册视图刷新（§41）
/// - KVO system 回归不破坏：resolved 变化仍广播全部视图（Phase 4 回归，§40）
/// - 无全局 lastApplied 去重：重复同模式仍 apply 全部视图（§23）
@MainActor
final class TerminalAppearanceManualModeTests: XCTestCase {

    // MARK: - 2+ existing views：manual Light / Dark

    /// manual Dark → 全部已注册视图 Dark；manual Light → 全部 Light。
    func testManualDarkAndLightApplyToAllExistingViews() throws {
        let harness = try makeHarness()
        let coordinator = harness.coordinator
        let controller = harness.controller

        let local = makeLocalProcessTerminalView()
        let remoteA = makeRemoteTerminalView()
        let remoteB = makeRemoteTerminalView()
        for v in [local, remoteA, remoteB] { coordinator.register(v) }

        // 起点为 light（resolved = aqua）。
        assertBackground(local, equals: .light)
        assertBackground(remoteA, equals: .light)
        assertBackground(remoteB, equals: .light)

        // manual Dark：controller 设 darkAqua → coordinator applyCurrent → 全 Dark。
        controller.setMode(.dark)
        assertBackground(local, equals: .dark)
        assertBackground(remoteA, equals: .dark)
        assertBackground(remoteB, equals: .dark)

        // manual Light：全部回到 Light。
        controller.setMode(.light)
        assertBackground(local, equals: .light)
        assertBackground(remoteA, equals: .light)
        assertBackground(remoteB, equals: .light)

        // 回到 Dark 验证可重复切换。
        controller.setMode(.dark)
        assertBackground(local, equals: .dark)
        assertBackground(remoteA, equals: .dark)
        assertBackground(remoteB, equals: .dark)
    }

    // MARK: - new registered view → immediate current（§22）

    /// 当前 mode = dark 时新建视图，register 后立即 Dark，不先 Light 再切 Dark。
    func testNewlyRegisteredViewGetsCurrentManualModeImmediately() throws {
        let harness = try makeHarness()
        let coordinator = harness.coordinator
        let controller = harness.controller

        controller.setMode(.dark)
        // 此时 resolved 已 darkAqua（controller apply 设置）。

        let newLocal = makeLocalProcessTerminalView()
        let newRemote = makeRemoteTerminalView()
        coordinator.register(newLocal)
        coordinator.register(newRemote)

        assertBackground(newLocal, equals: .dark)
        assertBackground(newRemote, equals: .dark)

        // 切回 light 后再注册一个，立即 Light。
        controller.setMode(.light)
        let another = makeRemoteTerminalView()
        coordinator.register(another)
        assertBackground(another, equals: .light)
    }

    // MARK: - explicit apply 刷新全部（§41）

    /// 即使 resolved 已是请求模式，显式 controller.apply() 仍刷新全部已注册视图。
    func testExplicitApplyRefreshesAllRegisteredViews() throws {
        let harness = try makeHarness()
        let coordinator = harness.coordinator
        let controller = harness.controller
        let holder = harness.holder

        let a = makeRemoteTerminalView()
        let b = makeRemoteTerminalView()
        coordinator.register(a)
        coordinator.register(b)

        controller.setMode(.dark)
        assertBackground(a, equals: .dark)
        assertBackground(b, equals: .dark)

        // 模拟 resolver 漂移到 light（如 system 模式下系统切到 light），
        // 但 mode 仍 dark：显式 apply 应重新断言 dark。
        holder.value = NSAppearance(named: .aqua)
        controller.apply()

        assertBackground(a, equals: .dark)
        assertBackground(b, equals: .dark)
    }

    // MARK: - 无全局 lastApplied 去重（§23）

    /// 重复切同一模式多次，每次都 apply 全部视图——不存在「已是 Dark 所以跳过」
    /// 的全局去重（P2-2 / §23 回归）。
    func testRepeatingSameModeStillAppliesToAllViews() throws {
        let harness = try makeHarness()
        let coordinator = harness.coordinator
        let controller = harness.controller

        let a = makeRemoteTerminalView()
        let b = makeRemoteTerminalView()
        coordinator.register(a)
        coordinator.register(b)

        for _ in 0..<5 {
            controller.setMode(.dark)
            assertBackground(a, equals: .dark)
            assertBackground(b, equals: .dark)
        }
        for _ in 0..<5 {
            controller.setMode(.light)
            assertBackground(a, equals: .light)
            assertBackground(b, equals: .light)
        }
    }

    // MARK: - KVO system 回归（§40）

    /// system 模式下 resolved 变化（系统 Light↔Dark）仍广播全部已注册视图——
    /// controller 显式路径不得破坏 Phase 4 KVO 安全网。
    func testSystemModeResolvedChangeBroadcastsToAllViews() throws {
        let defaults = try makeIsolatedDefaults()
        let holder = AppearanceHolder(NSAppearance(named: .aqua))
        var capturedHandler: (@MainActor () -> Void)?
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { holder.value },
            observationInstaller: { handler in
                capturedHandler = handler
                return TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        let controller = AppAppearanceController(
            userDefaults: defaults,
            coordinator: coordinator,
            appearanceSetter: { holder.value = $0 }
        )
        // system 模式（默认）：controller init apply 把 holder 设为 nil。
        // 手动恢复为 aqua 以模拟「system 跟随系统当前 light」。
        XCTAssertEqual(controller.mode, .system)
        holder.value = NSAppearance(named: .aqua)

        let a = makeRemoteTerminalView()
        let b = makeRemoteTerminalView()
        for v in [a, b] { coordinator.register(v) }
        assertBackground(a, equals: .light)
        assertBackground(b, equals: .light)

        // 系统切到 Dark（resolved 变化）：KVO handler 广播全部已注册视图。
        holder.value = NSAppearance(named: .darkAqua)
        capturedHandler?()
        assertBackground(a, equals: .dark)
        assertBackground(b, equals: .dark)

        // 系统切回 Light。
        holder.value = NSAppearance(named: .aqua)
        capturedHandler?()
        assertBackground(a, equals: .light)
        assertBackground(b, equals: .light)

        // requested 仍为 system（未因系统变化而改变）。
        XCTAssertEqual(controller.mode, .system)
    }

    // MARK: - 工具

    /// 共享外观持有者：controller 的 apply 经 setter 更新它，coordinator 的 resolver
    /// 读取它——等价于生产 `NSApp.appearance ↔ effectiveAppearance`。
    private final class AppearanceHolder {
        var value: NSAppearance?
        init(_ initial: NSAppearance?) { self.value = initial }
    }

    private struct Harness {
        let coordinator: TerminalAppearanceCoordinator
        let controller: AppAppearanceController
        let holder: AppearanceHolder
    }

    /// 装配 controller + coordinator + 共享 holder，resolved 起点为 aqua（light）。
    private func makeHarness() throws -> Harness {
        let defaults = try makeIsolatedDefaults()
        let holder = AppearanceHolder(NSAppearance(named: .aqua))
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { holder.value },
            observationInstaller: { _ in TerminalAppearanceObservationToken(invalidate: {}) }
        )
        let controller = AppAppearanceController(
            userDefaults: defaults,
            coordinator: coordinator,
            appearanceSetter: { holder.value = $0 }
        )
        return Harness(coordinator: coordinator, controller: controller, holder: holder)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "MacSSH.TerminalAppearanceManualModeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "TerminalAppearanceManualModeTests", code: 1, userInfo: nil)
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

    private func assertBackground(
        _ view: TerminalView,
        equals palette: TerminalAppearanceProvider.Palette,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            TerminalAppearanceProvider.appliedBackgroundRGB(of: view),
            palette.background,
            "\(palette.mode) background 未应用",
            file: file,
            line: line
        )
    }
}

private extension TerminalAppearanceProvider.Palette {
    static var light: TerminalAppearanceProvider.Palette { TerminalAppearanceProvider.light }
    static var dark: TerminalAppearanceProvider.Palette { TerminalAppearanceProvider.dark }
}
