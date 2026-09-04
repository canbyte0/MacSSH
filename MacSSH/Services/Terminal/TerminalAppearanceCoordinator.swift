import AppKit
import SwiftTerm

/// 终端外观运行时协调器（MacSSH 1.1 Phase 4 P2 整改版）。
///
/// 职责：跟踪 macOS Appearance 变化，并把对应调色板应用到**全部**已注册的
/// SwiftTerm `TerminalView`（Local 与 Remote、激活与非激活 Tab 一并覆盖）。
///
/// ## 为什么需要集中协调（任务书第三十五 / 三十九节）
///
/// `TerminalWorkspaceView` 只渲染 Active Session 的终端视图；非激活 Tab 的
/// `TerminalView` 对象仍由各 Service 持有（继续接收后台输出），但**不在**
/// SwiftUI 视图层级中。因此 `@Environment(\.colorScheme)` 不会对非激活 Tab
/// 触发更新。`NSApp.effectiveAppearance` 的 KVO 是 App 级信号，能覆盖全部
/// Session——保证非激活 Tab 切回时已是正确外观。
///
/// ## P2 整改要点（任务书 P2-1 / P2-2）
///
/// - **Observation 安装时机（P2-1）**：不再在 `init` 安装 KVO——`init` 在
///   SwiftUI `App.init` 阶段执行时 `NSApp` 可能仍为 nil，得到 nil observation
///   后**永不重试**，导致已存在 Terminal 不响应 Light↔Dark。改为在
///   `register(_:)` 中调用幂等的 `ensureObservationInstalled()`：TerminalView
///   真正创建时 AppKit 已要求 `NSApplication` 进入有效生命周期；若此刻仍为
///   nil（极早期），保持 nil 并由下次 `register` 重试。
/// - **去除全局 mode 去重（P2-2）**：不再保留 `lastAppliedMode`。appearance
///   callback 无条件遍历全部 live view apply——register 期间插入的新视图可能
///   让排队中的广播与全局 mode 去重冲突，误跳过已有视图（同一窗口出现两种
///   palette）。Appearance 改变频率极低，重复 apply 的成本远低于错误去重的
///   风险。
///
/// ## 不重建任何运行时（任务书第十四 / 十五 / 十六 / 四十节）
///
/// 只调用 `TerminalAppearanceProvider.apply(_:to:)`，仅作用 Presentation
/// 颜色：不重建 `TerminalView`、不重建 Runtime Session、不重启 Shell /
/// SSH / PTY、不触碰 cwd / scrollback / SFTP / 传输。光标、选区、ANSI
/// reset、clear、alternate screen、scrollback 重绘均由 `apply` 触发的
/// `colorsChanged()` 完整覆盖（见 `TerminalAppearanceProvider.apply` 注释）。
@MainActor
final class TerminalAppearanceCoordinator {
    /// 弱引用持有全部已注册终端视图（Session 关闭、Service 释放后自动 nil，
    /// 无需手工移除；`LocalProcessTerminalView` 是 `TerminalView` 的子类，
    /// 可统一注册）。`allObjects` 访问时自动回收已 nil 的槽位。
    private var terminalViews: NSHashTable<TerminalView> = .weakObjects()

    /// 当前外观观察令牌（非 nil 表示已安装；nil 表示尚未安装或安装失败待重试）。
    private var appearanceObservation: TerminalAppearanceObservationToken?

    /// 解析当前 `NSAppearance` 的接缝。生产读取 `NSApp?.effectiveAppearance`；
    /// 测试注入可变值以确定性验证 register / 广播行为，不依赖系统当前模式
    /// （任务书第四十八节，不依赖 XCTest 启动环境碰巧已有 NSApp）。
    private let appearanceResolver: @MainActor () -> NSAppearance?

    /// 安装 effectiveAppearance 观察的接缝。生产观察 `NSApp`（nil 时返回 nil
    /// 供下次 `register` 重试）；测试注入桩以验证安装时机与幂等性，不依赖真实
    /// NSApp 生命周期，也不为测试创建第二个 `NSApplication`（任务书第十一 /
    /// 十二节）。
    private let observationInstaller: @MainActor (@escaping @MainActor () -> Void) -> TerminalAppearanceObservationToken?

    /// - Parameters:
    ///   - appearanceResolver: 解析当前外观；默认读取 `NSApp?.effectiveAppearance`
    ///     （nil 回退 Light，与 `TerminalAppearanceProvider.mode(for:)` 一致）。
    ///   - observationInstaller: 安装外观变化观察；默认观察 `NSApp` 的
    ///     `effectiveAppearance` KVO，回调切回 MainActor 与视图操作建立同一线程边界。
    init(
        appearanceResolver: @escaping @MainActor () -> NSAppearance? = { NSApp?.effectiveAppearance },
        observationInstaller: @escaping @MainActor (@escaping @MainActor () -> Void) -> TerminalAppearanceObservationToken? = TerminalAppearanceCoordinator.installDefaultAppAppearanceObservation
    ) {
        self.appearanceResolver = appearanceResolver
        self.observationInstaller = observationInstaller
    }

    // MARK: - Public

    /// 注册一个终端视图并立即应用当前外观（任务书第三十四节：新建 Tab 无白闪）。
    /// 同时确保外观观察已安装（P2-1：`register` 是 NSApplication 已进入有效生命
    /// 周期的可靠时机）。已注册同一视图重复注册安全（`NSHashTable` 去重，apply 幂等）。
    ///
    /// 不修改任何会影响未来全局广播判定的状态（P2-2）。
    func register(_ terminalView: TerminalView) {
        ensureObservationInstalled()
        terminalViews.add(terminalView)
        // 只给该 view 应用当前外观。
        let palette = TerminalAppearanceProvider.palette(for: appearanceResolver())
        TerminalAppearanceProvider.apply(palette, to: terminalView)
    }

    // MARK: - App-level explicit apply（MacSSH 1.1 Phase 8）

    /// 受控入口：供 `AppAppearanceController` 在用户切换 mode 并设置
    /// `NSApp.appearance` 之后**同步**刷新全部已注册终端视图。
    ///
    /// 与 KVO 回调路径语义完全一致（无条件遍历 apply 当前 palette，无全局
    /// 去重——P2-2）。显式调用避免依赖 KVO 回调内 `Task { @MainActor in handler() }`
    /// 的异步 hop（下一 runloop），使 Settings 切换 mode 后 existing Terminal
    /// **立即**刷新（任务书 §14 / §15）。即使 resolved effectiveAppearance
    /// 未产生有意义模式变化（系统已 Dark、system→dark），显式 apply 仍安全刷新
    /// 全部 registered views（任务书 §16 / §41）。
    func applyCurrentAppearance() {
        applyCurrentAppearanceToAllRegisteredViews()
    }

    // MARK: - Testing seams

    /// 仅供测试：模拟一次 appearance 变化并把指定模式应用到全部已注册视图，
    /// 用于确定性断言「外观变化不重建视图 / 不改变字体」。不读写任何全局去重状态。
    func applyModeForTesting(_ mode: TerminalAppearanceProvider.Mode) {
        let palette = mode == .dark ? TerminalAppearanceProvider.dark : TerminalAppearanceProvider.light
        for view in terminalViews.allObjects {
            TerminalAppearanceProvider.apply(palette, to: view)
        }
    }

    /// 仅供测试：当前已注册视图数量（经 weak 表访问时自动清理后的存活数）。
    var registeredViewCountForTesting: Int {
        terminalViews.allObjects.count
    }

    /// 仅供测试：外观观察是否已安装（验证 `ensureObservationInstalled` 幂等与
    /// 延迟安装 / 重试）。
    var isObservationInstalledForTesting: Bool {
        appearanceObservation != nil
    }

    /// 仅供测试：重建 weak 表，回收所有已 nil 的槽位（验证 50 次 create/close
    /// 后 live count = 0）。生产路径访问 `allObjects` 已自动回收，无需调用。
    func compactRegistryForTesting() {
        let live = terminalViews.allObjects
        let fresh = NSHashTable<TerminalView>.weakObjects()
        for view in live {
            fresh.add(view)
        }
        terminalViews = fresh
    }

    // MARK: - Observation

    /// 幂等安装外观观察：仅在尚未安装（`appearanceObservation == nil`）时调用
    /// `observationInstaller`。若 installer 返回 nil（`NSApp` 尚未就绪），保持
    /// nil，下次 `register` 会重试。连续调用 1 / 10 / 100 次只存在一个
    /// observation（任务书第五节：observation 必须幂等）。
    private func ensureObservationInstalled() {
        guard appearanceObservation == nil else {
            return
        }
        appearanceObservation = observationInstaller { [weak self] in
            self?.applyCurrentAppearanceToAllRegisteredViews()
        }
    }

    /// 生产环境默认 KVO 安装器：观察 `NSApp.effectiveAppearance`。仅在 main-thread
    /// path（`register`）调用，此时 `NSApplication` 已进入有效生命周期；若仍为
    /// nil（极早期），返回 nil 供下次重试——**绝不创建「第二个」`NSApplication`**，
    /// 不引入私有 API（任务书第四节）。
    private static func installDefaultAppAppearanceObservation(
        handler: @escaping @MainActor () -> Void
    ) -> TerminalAppearanceObservationToken? {
        guard let app = NSApp else {
            // NSApplication 尚未进入有效生命周期。保持 nil；下次 `register` 的
            // `ensureObservationInstalled` 会重试。TerminalView 真正创建时 AppKit
            // 已要求 NSApplication 存在，因此 register 阶段通常一次安装成功。
            return nil
        }
        let observation = app.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            // AppKit 在主线程投递 KVO；显式切回 MainActor 与视图操作建立同一线程边界。
            Task { @MainActor in
                handler()
            }
        }
        return TerminalAppearanceObservationToken {
            observation.invalidate()
        }
    }

    /// appearance 变化回调：**无条件**遍历全部 live 已注册视图 apply 当前 palette
    /// （P2-2：移除 `lastAppliedMode` 全局去重，避免 register 期间新视图插入时
    /// 排队广播被误跳过）。Terminal 数量有限、Appearance 改变频率极低，重复
    /// apply 的成本远低于错误去重导致同一窗口出现两种 palette 的风险。
    private func applyCurrentAppearanceToAllRegisteredViews() {
        let palette = TerminalAppearanceProvider.palette(for: appearanceResolver())
        let liveViews = terminalViews.allObjects
        for view in liveViews {
            TerminalAppearanceProvider.apply(palette, to: view)
        }
        AppLogger.terminal.info("Terminal appearance updated to \(palette.mode.rawValue, privacy: .public)")
    }
}

/// 外观观察令牌：封装观察的失效逻辑，使 Coordinator 可在不直接持有
/// `NSKeyValueObservation` 的情况下管理生命周期——测试可注入桩 token
/// 验证安装时机与幂等性，无需创建真实 `NSApplication` 或真实 KVO。
final class TerminalAppearanceObservationToken {
    private let invalidateAction: () -> Void
    init(invalidate: @escaping () -> Void) {
        self.invalidateAction = invalidate
    }
    func invalidate() {
        invalidateAction()
    }
}
