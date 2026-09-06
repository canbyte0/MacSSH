import AppKit
import Observation
import SwiftTerm

/// MacSSH 1.1 Phase 9：终端字号控制器（任务书 §46 / Phase 9A Acceptance §30）。
///
/// 单一 writer（与 `AppAppearanceController` 同模式）：终端字号偏好的读写只由
/// 本控制器进行。SettingsView 的减号/加号按钮绑定 `controller.size`，写入经
/// `didSet` 持久化并 apply；不存在 SettingsView / AppState / 其他 View 各自写
/// UserDefaults 或 `@AppStorage` 的多 source of truth。
///
/// ## Source of truth 单一链
///
/// Persisted requested size (`UserDefaults`) → `TerminalFontSizeController.size`
/// → `TerminalFontProvider.regularFont(size:)` → per-`TerminalView.font`。不另外
/// 维护 `terminalFontSizeRuntime` / `swiftUIFontSize` / `terminalViewPointSize`
/// 等第二套状态。`TerminalFontProvider` 保持 stateless，只接收 size 参数构造
/// NSFont。
///
/// ## 合并 preference + registry + broadcast（不分 Coordinator）
///
/// 与 `AppAppearanceController`（Phase 8）拆出 `TerminalAppearanceCoordinator`
/// 的模式不同：font **无外部触发源**（无 KVO、无系统信号、无 `effectiveAppearance`
/// 等价物）——只在用户操作时变化。单一 writer 即单一 broadcaster，单一
/// MainActor 同步链，无 `Task { @MainActor in }` 异步 hop。因此 Controller 同时
/// 持有 preference + weak `TerminalView` registry + apply 广播——合并更简。
///
/// apply 路径与 `TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()`
/// 完全同构：遍历 `NSHashTable<TerminalView>.weakObjects()` 全部 live view，
/// `view.font = TerminalFontProvider.regularFont(size: CGFloat(size))`。后续 cell
/// geometry recompute + cols/rows resize + Local/Remote PTY resize 全部由 SwiftTerm
/// `font` public setter 内置 `resetFont()` 完成——本控制器不重复 resize 逻辑。
///
/// ## 不重建任何运行时（任务书第十四 / 十五 / 十六 / 四十节）
///
/// 只调用 `TerminalView.font` public setter 与 `TerminalFontProvider.regularFont(size:)`，
/// 仅作用 Presentation 字号：不重建 `TerminalView`、不重建 Runtime Session、
/// 不重启 Shell / SSH / PTY、不触碰 cwd / scrollback / SFTP / 传输。光标、选区、
/// ANSI reset、clear、alternate screen、scrollback reflow 均由 SwiftTerm `font`
/// setter 的 `resetFont()` → `resize(cols:rows:)` 内置完整覆盖。
@MainActor
@Observable
final class TerminalFontSizeController {
    /// 默认字号（与 `TerminalFontProvider.defaultSize` 一致）。老用户无该 key
    /// 时返回此值，行为与现状完全相同——避免出现"升级后字号突然变化"。
    static let defaultSize: Int = 14

    /// 允许的最小字号。低于此值会让 JetBrains Mono 字形过窄、行高过紧。
    static let minSize: Int = 10

    /// 允许的最大字号。高于此值在常见窗口尺寸下 cols/rows 过少，影响可用性。
    static let maxSize: Int = 32

    /// 步进。用户每次点击 −/+ 改变 1 pt（避免跳变）。
    static let step: Int = 1

    /// 偏好存储；只由本控制器读写 `terminalFontSize` key（单一 writer）。
    private let userDefaults: UserDefaults

    /// 弱引用持有全部已注册终端视图（与
    /// `TerminalAppearanceCoordinator.terminalViews` /
    /// `TerminalHighlightCoordinator.terminalViews` 同模式）。Session 关闭 / Service
    /// 释放后自动 nil，无需手工移除；`LocalProcessTerminalView` 是 `TerminalView`
    /// 的子类，可统一注册。`allObjects` 访问时自动回收已 nil 的槽位。
    @ObservationIgnored
    private var terminalViews: NSHashTable<TerminalView> = .weakObjects()

    /// Runtime requested size（Int 10...32）。SettingsView 减号/加号按钮绑定本属性；
    /// 写入经 `didSet` 持久化并 apply。API boundary 转 CGFloat：
    /// `TerminalFontProvider.regularFont(size: CGFloat(controller.size))`。
    var size: Int {
        didSet {
            // 防御性 clamp：SettingsView 的 −/+ 按钮已通过 `.disabled(size <= minSize)`
            // / `.disabled(size >= maxSize)` 在边界禁用，正常 UI 流不会越界。
            // 但 `setSize(_:)` / 外部调用方 / 测试可能越界——二次 clamp 保证
            // `UserDefaults` 与 runtime 始终在 [10, 32]。若 newValue 被夹回，
            // 重新赋值会触发 didSet；下一轮 clamp 必为 no-op（已夹内），递归终止。
            let clamped = Self.clamp(size)
            if clamped != size {
                size = clamped
                return
            }
            userDefaults.set(size, forKey: AppPreferenceKey.terminalFontSize)
            applyFontSizeToAllRegisteredViews()
        }
    }

    /// - Parameters:
    ///   - userDefaults: 偏好存储；只读写 `terminalFontSize` key。测试可注入
    ///     隔离 suite（`UserDefaults(suiteName:)`），不污染真实 standard。
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // init 内赋值不触发 didSet（Swift 语义）。launch 时 registry 为空，
        // 即使触发 apply 也是 no-op——新 Terminal 在 SessionManager.register
        // 时才真正应用当前 size。
        self.size = Self.load(from: userDefaults)
    }

    // MARK: - Public API

    /// 注册一个终端视图并立即应用当前字号（与
    /// `TerminalAppearanceCoordinator.register(_:)` 同模式：新建 Tab 无首帧
    /// 14→18 闪烁）。重复注册同一 view 安全（`NSHashTable.add(_:)` 幂等 +
    /// `view.font =` 幂等 computed property setter）。
    ///
    /// **调用时机**：Service 创建后、SwiftUI 插入 view 前同步调用（与
    /// Appearance/Highlight 同注册点）。此时 view frame 通常为 `.zero` →
    /// SwiftTerm `resetFont()` 跳过 `resize`，只更新 `cellDimension`；之后
    /// SwiftUI `setFrameSize` 触发 `processSizeChange` 用正确 cellDimension
    /// 计算 cols/rows，首帧即请求字号。
    func register(_ terminalView: TerminalView) {
        terminalViews.add(terminalView)
        terminalView.font = TerminalFontProvider.regularFont(size: CGFloat(size))
    }

    /// 显式设置字号（任务书 §10）。经 `size` setter → `didSet` 持久化并 apply。
    /// 供非 SwiftUI 调用方与测试使用；SettingsView 减号/加号按钮调用
    /// `increment()` / `decrement()` 同样经 `size` setter 走 `didSet`。
    func setSize(_ newSize: Int) {
        size = newSize
    }

    /// 加号按钮入口：`size += step`，自动经 `didSet` 持久化并 apply。
    /// 32 时按钮已 `.disabled`，但本方法仍作防御性 clamp。
    func increment() {
        size += Self.step
    }

    /// 减号按钮入口：`size -= step`，同上。
    /// 10 时按钮已 `.disabled`，但本方法仍作防御性 clamp。
    func decrement() {
        size -= Self.step
    }

    /// 显式 apply 当前 requested size 到全部已注册终端（任务书 §13 / §14）。
    /// 与 `AppAppearanceController.apply()` 同语义——用于 launch load 后或外部
    /// 状态变更需要重新同步时调用。生产路径在 `size.didSet` 内自动 apply，
    /// 通常不需直接调用本方法。
    func apply() {
        applyFontSizeToAllRegisteredViews()
    }

    // MARK: - Loading & normalization

    /// 从 UserDefaults 安全 load 字号。
    ///
    /// **必须用 `object(forKey:) as? Int`** 而非 `integer(forKey:)`：
    /// - 缺失 key：`object(forKey:)` 返回 nil → fallback `defaultSize` (14)
    /// - 非 Int 类型（Double / String / Bool / NaN-via-Double）：
    ///   `as? Int` 返回 nil → fallback 14
    /// - 合法 Int 越界：clamp 10...32
    /// - NaN / Infinity：无法存为 Int；外部写入 Double.nan → `as? Int` nil → 14
    ///
    /// Int 天然排除 NaN/Infinity，校验面最小。`integer(forKey:)` 对缺失返回 0
    /// 无法与"用户存了 0"区分，因此**不可用**。
    static func load(from defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int else {
            return defaultSize
        }
        return clamp(stored)
    }

    /// 钳制 size 到 `[minSize, maxSize]`。
    static func clamp(_ value: Int) -> Int {
        min(max(value, minSize), maxSize)
    }

    // MARK: - Testing seams

    /// 仅供测试：当前 live view 数（访问 `allObjects` 时自动回收已 nil 槽位，
    /// 与 `TerminalAppearanceCoordinator.registeredViewCountForTesting` 同模式，
    /// 用于断言 50 次 create/close 后 live count = 0）。
    @ObservationIgnored
    var registeredViewCountForTesting: Int {
        terminalViews.allObjects.count
    }

    /// 仅供测试：重建 weak 表，回收所有已 nil 的槽位（生产路径访问
    /// `allObjects` 已自动回收，无需调用）。
    func compactRegistryForTesting() {
        let live = terminalViews.allObjects
        let fresh = NSHashTable<TerminalView>.weakObjects()
        for view in live {
            fresh.add(view)
        }
        terminalViews = fresh
    }

    // MARK: - Apply

    /// 遍历全部 live 已注册视图 apply 当前字号（P2-2 模式：无条件无 dedup）。
    ///
    /// 与 `TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()`
    /// 同构：不保留全局 `lastAppliedSize`，重复同一 size 仍 apply——register
    /// 期间新视图插入时排队广播不会因 dedup 误跳过既有 view。Terminal 数量
    /// 有限、字号改变频率极低，重复 apply 的成本远低于错误去重导致同一窗口
    /// 出现两种字号的风险。
    private func applyFontSizeToAllRegisteredViews() {
        let font = TerminalFontProvider.regularFont(size: CGFloat(size))
        let liveViewCount = terminalViews.allObjects.count
        let appliedSize = size
        for view in terminalViews.allObjects {
            view.font = font
        }
        AppLogger.terminal.info("Terminal font size applied to \(liveViewCount, privacy: .public) view(s) (size=\(appliedSize, privacy: .public))")
    }
}
