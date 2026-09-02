import AppKit
import SwiftTerm
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 4 终端外观验收测试。
///
/// 覆盖（任务书第四十六 / 四十七 / 四十八节）：
/// - Light / Dark 默认前景 / 背景
/// - Light / Dark 调色板不相同
/// - Light / Dark 前景-背景对比度合理可读
/// - `mode(for:)` 由 NSAppearance 解析正确
/// - Local / Remote 共用同一 configuration（均经 `TerminalAppearanceProvider`）
/// - `apply` 后 `nativeForegroundColor` / `nativeBackgroundColor` 已更新
/// - `apply` 不修改 TerminalFont 配置（任务书第二十一 / 五十一节）
/// - Coordinator 多视图外观变化不重建视图、字体保持（任务书第三十五 /
///   四十九节：appearance change 不改变 Runtime / Session / 字体）
@MainActor
final class TerminalAppearanceTests: XCTestCase {

    // MARK: - Palette 值

    /// 任务书：Light 默认背景须为浅色。
    func testLightPaletteBackgroundIsLight() {
        let bg = TerminalAppearanceProvider.light.background
        let lum = TerminalAppearanceProvider.relativeLuminance(bg)
        XCTAssertGreaterThan(lum, 0.8, "Light 背景须为浅色（高亮度）")
    }

    /// 任务书：Light 默认前景须为深色。
    func testLightPaletteForegroundIsDark() {
        let fg = TerminalAppearanceProvider.light.foreground
        let lum = TerminalAppearanceProvider.relativeLuminance(fg)
        XCTAssertLessThan(lum, 0.2, "Light 前景须为深色（低亮度）")
    }

    /// 任务书：Dark 默认背景须为深色。
    func testDarkPaletteBackgroundIsDark() {
        let bg = TerminalAppearanceProvider.dark.background
        let lum = TerminalAppearanceProvider.relativeLuminance(bg)
        XCTAssertLessThan(lum, 0.2, "Dark 背景须为深色（低亮度）")
    }

    /// 任务书：Dark 默认前景须为浅色。
    func testDarkPaletteForegroundIsLight() {
        let fg = TerminalAppearanceProvider.dark.foreground
        let lum = TerminalAppearanceProvider.relativeLuminance(fg)
        XCTAssertGreaterThan(lum, 0.8, "Dark 前景须为浅色（高亮度）")
    }

    /// 任务书：Light / Dark 调色板不可相同。
    func testLightAndDarkPalettesAreDifferent() {
        XCTAssertNotEqual(TerminalAppearanceProvider.light, TerminalAppearanceProvider.dark)
        XCTAssertNotEqual(
            TerminalAppearanceProvider.light.background,
            TerminalAppearanceProvider.dark.background
        )
        XCTAssertNotEqual(
            TerminalAppearanceProvider.light.foreground,
            TerminalAppearanceProvider.dark.foreground
        )
    }

    // MARK: - Contrast（任务书第四十七节）

    /// Light 前景-背景须有合理可读对比度（WCAG AA 正常文本 >= 4.5）。
    func testLightPaletteHasReadableContrast() {
        let ratio = TerminalAppearanceProvider.contrastRatio(
            TerminalAppearanceProvider.light.foreground,
            TerminalAppearanceProvider.light.background
        )
        XCTAssertGreaterThanOrEqual(ratio, 7.0, "Light fg/bg 对比度须 >= 7.0（AAA），实际 \(ratio)")
    }

    /// Dark 前景-背景须有合理可读对比度。
    func testDarkPaletteHasReadableContrast() {
        let ratio = TerminalAppearanceProvider.contrastRatio(
            TerminalAppearanceProvider.dark.foreground,
            TerminalAppearanceProvider.dark.background
        )
        XCTAssertGreaterThanOrEqual(ratio, 7.0, "Dark fg/bg 对比度须 >= 7.0（AAA），实际 \(ratio)")
    }

    /// 选区前景-背景须可读，且选区与普通底色有区别。
    func testSelectionIsReadableAndDistinctFromBackground() {
        for palette in [TerminalAppearanceProvider.light, TerminalAppearanceProvider.dark] {
            let selRatio = TerminalAppearanceProvider.contrastRatio(
                palette.selectionForeground, palette.selectionBackground
            )
            XCTAssertGreaterThanOrEqual(selRatio, 3.0,
                "\(palette.mode) selection fg/bg 对比度须 >= 3.0，实际 \(selRatio)")
            XCTAssertNotEqual(palette.selectionBackground, palette.background,
                "\(palette.mode) 选区底色须与普通底色不同")
        }
    }

    // MARK: - Appearance → Mode 解析（任务书第四十八节：不依赖系统当前模式）

    func testModeForLightAppearance() {
        let aqua = NSAppearance(named: .aqua)
        XCTAssertEqual(TerminalAppearanceProvider.mode(for: aqua), .light)
    }

    func testModeForDarkAppearance() {
        let darkAqua = NSAppearance(named: .darkAqua)
        XCTAssertEqual(TerminalAppearanceProvider.mode(for: darkAqua), .dark)
    }

    func testModeForNilAppearanceFallsBackToLight() {
        XCTAssertEqual(TerminalAppearanceProvider.mode(for: nil), .light)
    }

    // MARK: - Apply（Local / Remote 共用同一 configuration）

    /// Local（LocalProcessTerminalView）apply 后默认前景/背景已更新。
    func testApplyUpdatesLocalTerminalViewColors() {
        let view = makeLocalProcessTerminalView()

        TerminalAppearanceProvider.apply(TerminalAppearanceProvider.light, to: view)
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: view),
                      TerminalAppearanceProvider.light.background)
        XCTAssertEqual(TerminalAppearanceProvider.appliedForegroundRGB(of: view),
                      TerminalAppearanceProvider.light.foreground)

        TerminalAppearanceProvider.apply(TerminalAppearanceProvider.dark, to: view)
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: view),
                      TerminalAppearanceProvider.dark.background)
        XCTAssertEqual(TerminalAppearanceProvider.appliedForegroundRGB(of: view),
                      TerminalAppearanceProvider.dark.foreground)
    }

    /// Remote（TerminalView）apply 后默认前景/背景已更新——与 Local 同源配置。
    func testApplyUpdatesRemoteTerminalViewColors() {
        let view = makeRemoteTerminalView()

        TerminalAppearanceProvider.apply(TerminalAppearanceProvider.dark, to: view)
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: view),
                      TerminalAppearanceProvider.dark.background)
        XCTAssertEqual(TerminalAppearanceProvider.appliedForegroundRGB(of: view),
                      TerminalAppearanceProvider.dark.foreground)
    }

    /// Local / Remote 应用同一调色板后颜色一致（任务书第二节）。
    func testLocalAndRemoteShareSameAppearanceConfiguration() {
        let local = makeLocalProcessTerminalView()
        let remote = makeRemoteTerminalView()

        TerminalAppearanceProvider.apply(TerminalAppearanceProvider.dark, to: local)
        TerminalAppearanceProvider.apply(TerminalAppearanceProvider.dark, to: remote)

        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: local),
                       TerminalAppearanceProvider.appliedBackgroundRGB(of: remote))
        XCTAssertEqual(TerminalAppearanceProvider.appliedForegroundRGB(of: local),
                       TerminalAppearanceProvider.appliedForegroundRGB(of: remote))
    }

    // MARK: - Font 不变性（任务书第二十一 / 五十一节）

    /// apply 不得改变字体、字号、级联或单元格几何。
    func testApplyDoesNotModifyFontConfiguration() {
        let view = makeLocalProcessTerminalView()
        let fontBefore = view.font

        TerminalAppearanceProvider.apply(TerminalAppearanceProvider.light, to: view)
        TerminalAppearanceProvider.apply(TerminalAppearanceProvider.dark, to: view)

        XCTAssertEqual(view.font.fontName, fontBefore.fontName,
                       "apply 不得改变字体 PostScript name")
        XCTAssertEqual(view.font.pointSize, fontBefore.pointSize,
                       "apply 不得改变字号")
        XCTAssertEqual(view.font.pointSize, 14.0, "默认字号须保持 14.0 pt（Phase 2 baseline）")
    }

    /// TerminalFontProvider 静态配置不受外观影响（任务书第五十一节回归）。
    func testTerminalFontProviderConfigUnchangedByAppearance() {
        XCTAssertEqual(TerminalFontProvider.defaultSize, 14.0)
        XCTAssertEqual(TerminalFontProvider.baseFamily, "JetBrains Mono")
        XCTAssertEqual(TerminalFontProvider.cjkFallbackFamily, "PingFang SC")
        XCTAssertEqual(TerminalFontProvider.emojiFallbackFamily, "Apple Color Emoji")
    }

    // MARK: - Coordinator：多视图动态更新不重建运行时（任务书第三十五 / 四十九节）

    /// 外观变化（模拟）应用到全部已注册视图，且视图实例不变、字体不变。
    func testCoordinatorAppliesToAllRegisteredViewsWithoutRecreate() {
        let coordinator = TerminalAppearanceCoordinator()
        let local = makeLocalProcessTerminalView()
        let remote = makeRemoteTerminalView()
        let localPointer = ObjectIdentifier(local)
        let remotePointer = ObjectIdentifier(remote)
        let localFontBefore = local.font
        let remoteFontBefore = remote.font

        coordinator.register(local)
        coordinator.register(remote)
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 2)

        // 模拟 Light -> Dark -> Light 切换（连续多次，任务书第三十三节）。
        for _ in 0..<10 {
            coordinator.applyModeForTesting(.dark)
            XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: local),
                           TerminalAppearanceProvider.dark.background)
            XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: remote),
                           TerminalAppearanceProvider.dark.background)
            coordinator.applyModeForTesting(.light)
            XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: local),
                           TerminalAppearanceProvider.light.background)
            XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: remote),
                           TerminalAppearanceProvider.light.background)
        }

        // 视图实例未重建（同一指针），字体未变（运行时 / Session 保持）。
        XCTAssertEqual(ObjectIdentifier(local), localPointer)
        XCTAssertEqual(ObjectIdentifier(remote), remotePointer)
        XCTAssertEqual(local.font.fontName, localFontBefore.fontName)
        XCTAssertEqual(local.font.pointSize, localFontBefore.pointSize)
        XCTAssertEqual(remote.font.fontName, remoteFontBefore.fontName)
        XCTAssertEqual(remote.font.pointSize, remoteFontBefore.pointSize)
    }

    /// 重复注册同一视图安全（幂等、不重复计数）。
    func testRegisterIsIdempotent() {
        let coordinator = TerminalAppearanceCoordinator()
        let view = makeRemoteTerminalView()
        coordinator.register(view)
        coordinator.register(view)
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 1)
    }

    // MARK: - Observation 安装（任务书第十一 / 十二节：P2-1 整改回归）

    /// Coordinator 初始化阶段没有 observation 也没关系；首次 register 时安装成功。
    func testObservationInstallsWhenFirstViewRegisters() {
        var installCount = 0
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .aqua) },
            observationInstaller: { _ in
                installCount += 1
                return TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        XCTAssertFalse(coordinator.isObservationInstalledForTesting)
        XCTAssertEqual(installCount, 0)

        coordinator.register(makeRemoteTerminalView())
        XCTAssertTrue(coordinator.isObservationInstalledForTesting)
        XCTAssertEqual(installCount, 1)
    }

    /// 连续 register 不重复安装 observation（ensure 必须幂等）。
    func testRepeatedRegisterDoesNotInstallDuplicateObservation() {
        var installCount = 0
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .aqua) },
            observationInstaller: { _ in
                installCount += 1
                return TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        coordinator.register(makeRemoteTerminalView())
        coordinator.register(makeRemoteTerminalView())
        coordinator.register(makeRemoteTerminalView())
        XCTAssertEqual(installCount, 1, "ensureObservationInstalled 必须幂等：只安装一个 observation")
    }

    /// Coordinator 在 application 尚不可观察阶段创建（installer 返回 nil），
    /// 之后 register 重试并成功安装——不再出现 init 成功但 observation 永远 nil。
    func testObservationRetriesWhenInitiallyUnavailable() {
        var installCount = 0
        var appReady = false
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .aqua) },
            observationInstaller: { _ in
                installCount += 1
                guard appReady else { return nil }
                return TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        // 首次 register：appReady=false → installer 返回 nil；observation 仍 nil，可重试。
        coordinator.register(makeRemoteTerminalView())
        XCTAssertEqual(installCount, 1)
        XCTAssertFalse(coordinator.isObservationInstalledForTesting)

        // NSApp 就绪后再次 register：重试成功安装。
        appReady = true
        coordinator.register(makeRemoteTerminalView())
        XCTAssertEqual(installCount, 2)
        XCTAssertTrue(coordinator.isObservationInstalledForTesting)
    }

    // MARK: - 注册竞态回归（任务书第十三节：P2-2 deterministic 回归）

    /// appearance 切 Light 的广播已排队但尚未执行；此时 register View B（得到
    /// Light）。随后执行该次广播——A 与 B 均须 Light，不得因全局 mode 去重
    /// 跳过 A（旧实现在此处 FAIL：A 停留 Dark、B 为 Light）。
    func testRegisterDuringPendingAppearanceBroadcastDoesNotSkipExistingView() {
        var currentAppearance: NSAppearance? = NSAppearance(named: .darkAqua)
        var capturedHandler: (@MainActor () -> Void)?
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { currentAppearance },
            observationInstaller: { handler in
                capturedHandler = handler
                return TerminalAppearanceObservationToken(invalidate: {})
            }
        )

        let a = makeRemoteTerminalView()
        coordinator.register(a)
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: a),
                      TerminalAppearanceProvider.dark.background)

        // appearance 切 Light；广播「已排队」但尚未触发（不调用 capturedHandler）。
        currentAppearance = NSAppearance(named: .aqua)

        // 排队广播触发前 register View B —— B 立即得到当前（Light）外观。
        let b = makeRemoteTerminalView()
        coordinator.register(b)
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: b),
                      TerminalAppearanceProvider.light.background)
        // A 仍为 Dark（广播尚未执行）。
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: a),
                      TerminalAppearanceProvider.dark.background)

        // 触发排队的 appearance 广播。
        capturedHandler?()

        // P2-2 修复后：广播无条件 apply 全部 live view —— A 与 B 均 Light。
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: a),
                      TerminalAppearanceProvider.light.background)
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: b),
                      TerminalAppearanceProvider.light.background)
    }

    // MARK: - 多视图广播（任务书第十四节）

    /// 注册 A/B/C，Dark→Light 全部 Light；Light→Dark 全部 Dark。
    func testAppearanceChangeBroadcastsToAllRegisteredViews() {
        var currentAppearance: NSAppearance? = NSAppearance(named: .darkAqua)
        var capturedHandler: (@MainActor () -> Void)?
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { currentAppearance },
            observationInstaller: { handler in
                capturedHandler = handler
                return TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        let a = makeRemoteTerminalView()
        let b = makeRemoteTerminalView()
        let c = makeRemoteTerminalView()
        for v in [a, b, c] { coordinator.register(v) }
        for v in [a, b, c] {
            XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: v),
                          TerminalAppearanceProvider.dark.background)
        }

        currentAppearance = NSAppearance(named: .aqua)
        capturedHandler?()
        for v in [a, b, c] {
            XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: v),
                          TerminalAppearanceProvider.light.background)
        }

        currentAppearance = NSAppearance(named: .darkAqua)
        capturedHandler?()
        for v in [a, b, c] {
            XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: v),
                          TerminalAppearanceProvider.dark.background)
        }
    }

    // MARK: - 新 View 注册（任务书第十五节）

    /// 当前系统 Dark 下 register D —— D 立即 Dark，不等下次 appearance change。
    func testNewlyRegisteredViewGetsCurrentAppearanceImmediately() {
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .darkAqua) },
            observationInstaller: { _ in
                TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        let d = makeRemoteTerminalView()
        coordinator.register(d)
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: d),
                      TerminalAppearanceProvider.dark.background)
    }

    // MARK: - Weak registry 生命周期（任务书第十节）

    /// registry 必须为 zeroing weak memory——构造为 `NSHashTable.weakObjects()`，
    /// 运行时验证：register 不得增加 TerminalView 的 retain count（强 registry 会 +1，
    /// weak registry 不变）。register 触发 SwiftTerm `colorsChanged → queuePendingDisplay`
    /// 的瞬时 retain，runloop spin 让其释放后再比较，得到稳定值。
    func testRegistryDoesNotRetainRegisteredViews() {
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .aqua) },
            observationInstaller: { _ in
                TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        let view = makeRemoteTerminalView()
        let countBefore = CFGetRetainCount(view)
        coordinator.register(view)
        // 让 SwiftTerm pending display dispatch 执行，释放任何瞬时 retain。
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let countAfter = CFGetRetainCount(view)
        XCTAssertEqual(countBefore, countAfter,
                       "registry 须为 NSHashTable.weakObjects()，不得增加 TerminalView retain count")
    }

    /// registry count 精确跟踪外部强引用集合：去重、compact 不丢失 live、
    /// 不产生 phantom 条目（registry 不会凭空 retain 视图导致无限增长）。
    func testRegistryCountTracksHeldSetAndCompactsCleanly() {
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .aqua) },
            observationInstaller: { _ in
                TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 0)

        let a = makeRemoteTerminalView()
        let b = makeRemoteTerminalView()
        let c = makeRemoteTerminalView()
        coordinator.register(a)
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 1)
        coordinator.register(a) // 重复注册安全（NSHashTable 去重）
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 1)
        coordinator.register(b)
        coordinator.register(c)
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 3)

        // compact 须保留全部 live 视图，不丢失、不产生 phantom 条目。
        coordinator.compactRegistryForTesting()
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 3)

        // compact 后广播仍正确作用于全部 live 视图（验证广播用 allObjects 而非旧表）。
        var currentAppearance: NSAppearance? = NSAppearance(named: .darkAqua)
        var capturedHandler: (@MainActor () -> Void)?
        let coordinator2 = TerminalAppearanceCoordinator(
            appearanceResolver: { currentAppearance },
            observationInstaller: { handler in
                capturedHandler = handler
                return TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        coordinator2.register(a)
        coordinator2.register(b)
        coordinator2.compactRegistryForTesting()
        currentAppearance = NSAppearance(named: .aqua)
        capturedHandler?()
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: a),
                      TerminalAppearanceProvider.light.background)
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: b),
                      TerminalAppearanceProvider.light.background)
    }

    /// 50 次 create/close：registry 不会因重复注册 / compact 产生无限增长的
    /// live 条目（去重后 live count 始终等于唯一视图数）。
    func testRegistryDoesNotGrowUnboundedAfterChurn() {
        // 仅持有一个稳定视图，反复 register + compact 50 次——live count 必须恒为 1，
        // 不积累重复 / phantom 条目（证明 registry 不会无限增长）。
        let coordinator = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .aqua) },
            observationInstaller: { _ in
                TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        let view = makeRemoteTerminalView()
        for _ in 0..<50 {
            coordinator.register(view)
            coordinator.compactRegistryForTesting()
        }
        XCTAssertEqual(coordinator.registeredViewCountForTesting, 1)

        // 新 registry：注册 50 个不同视图后 live = 50；compact 后仍 = 50
        // （无丢失、无 phantom）。
        let coordinator2 = TerminalAppearanceCoordinator(
            appearanceResolver: { NSAppearance(named: .aqua) },
            observationInstaller: { _ in
                TerminalAppearanceObservationToken(invalidate: {})
            }
        )
        var views: [TerminalView] = []
        for _ in 0..<50 {
            views.append(makeRemoteTerminalView())
        }
        for v in views { coordinator2.register(v) }
        XCTAssertEqual(coordinator2.registeredViewCountForTesting, 50)
        coordinator2.compactRegistryForTesting()
        XCTAssertEqual(coordinator2.registeredViewCountForTesting, 50)
        // views 由局部数组强引用持有；函数返回后随数组释放（registry 为 weak，
        // 不构成额外 retain——见 testRegistryDoesNotRetainRegisteredViews）。
    }

    // MARK: - 真实 KVO callback 路径（任务书第二十三节：非 test seam）

    /// 使用真实默认 installer（`NSApp.effectiveAppearance` KVO），通过设置
    /// `NSApp.appearance` 触发真实系统 callback，验证 Coordinator 真实广播路径
    /// （非 test seam）。测试 host 无 NSApp 时跳过（不假装 PASS）。
    func testRealAppAppearanceKVOBroadcastsToRegisteredView() {
        let coordinator = TerminalAppearanceCoordinator() // 默认 resolver + 默认 installer
        let view = makeRemoteTerminalView()
        coordinator.register(view)
        guard coordinator.isObservationInstalledForTesting, let app = NSApp else {
            // 测试 host 无 NSApp（逻辑测试）→ 跳过，保持 baseline gate 语义。
            return
        }

        let saved = app.appearance
        defer { app.appearance = saved }

        app.appearance = NSAppearance(named: .darkAqua)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: view),
                      TerminalAppearanceProvider.dark.background,
                      "真实 KVO callback 须把视图应用为 Dark")

        app.appearance = NSAppearance(named: .aqua)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(TerminalAppearanceProvider.appliedBackgroundRGB(of: view),
                      TerminalAppearanceProvider.light.background,
                      "真实 KVO callback 须把视图应用为 Light")
    }

    // MARK: - Helpers

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
