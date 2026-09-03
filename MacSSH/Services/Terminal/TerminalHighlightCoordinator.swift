import AppKit
import SwiftTerm

/// MacSSH 1.1 Phase 6：终端字符串高亮运行时协调器。
///
/// 职责：
/// - 持有 `TerminalHighlightStore` 与单例 `TerminalHighlightProviderImpl`；
/// - 弱引用（`NSHashTable<TerminalView>.weakObjects()`）跟踪全部 live
///   TerminalView，Session 关闭 / Service 释放后自动 nil，无手工移除；
/// - register 新 view 时立即应用当前 provider（新建 Tab 无白闪）；
/// - store 变更回调挂接 → 无条件广播全部 live view 重绘
///   （`terminal.updateFullScreen()` + `needsDisplay`），**不使用**
///   全局 lastApplied state（避免 Phase 4 同类 race）；
/// - 不重建任何 Runtime Session / Shell / SSH / PTY / TerminalView。
///
/// Local / Remote 共用同一 provider 与同一 Coordinator——matcher 只看
/// `BufferLine` 文本，与连接类型无关（Phase 6A 已证）。
@MainActor
final class TerminalHighlightCoordinator {

    private let store: TerminalHighlightStore
    private let provider: TerminalHighlightProviderImpl
    private var terminalViews: NSHashTable<TerminalView> = .weakObjects()

    /// 测试与构造共用：可注入自定义 store（便于测试断言无副作用）。
    init(store: TerminalHighlightStore) {
        self.store = store
        self.provider = TerminalHighlightProviderImpl(store: store)
        // 变更通知挂接到本类的广播——store 任何 CRUD / 全局开关切换都会
        // 立即触发全部 live view 重绘。
        store.onSettingsChanged = { [weak self] in
            self?.broadcastRedrawToAllRegisteredViews()
        }
    }

    // MARK: - 便捷构造

    /// 生产默认：基于 `.standard` UserDefaults 创建 store + coordinator。
    convenience init(userDefaults: UserDefaults = .standard) {
        self.init(store: TerminalHighlightStore(userDefaults: userDefaults))
    }

    // MARK: - Public API

    /// 暴露 store 给 AppState / SettingsView / 测试。
    var highlightStore: TerminalHighlightStore { store }

    /// 注册一个 TerminalView 并立即应用当前 provider（新建 Tab 无白闪）。
    /// 重复注册同一 view 安全（`NSHashTable` 去重，apply 幂等）。
    func register(_ terminalView: TerminalView) {
        terminalViews.add(terminalView)
        terminalView.highlightProvider = provider
    }

    /// 取消注册某 view（一般无需调用——Session 关闭后 weak 自动 nil；
    /// 测试与 Reconnect 路径可显式调用：清空其 provider 引用即可）。
    func unregister(_ terminalView: TerminalView) {
        terminalView.highlightProvider = nil
        // NSHashTable 弱引用：view 被外部释放后槽位自动 nil；
        // 此处不再操作 table（remove 在 weak 表上无额外效果）。
    }

    // MARK: - 测试 seams

    /// 仅测试：当前 live view 数（访问 allObjects 时自动回收已 nil 槽位）。
    var registeredViewCountForTesting: Int {
        terminalViews.allObjects.count
    }

    /// 仅测试：重建 weak 表（验证 50 次 create/close 后 live count = 0）。
    func compactRegistryForTesting() {
        let live = terminalViews.allObjects
        let fresh = NSHashTable<TerminalView>.weakObjects()
        for view in live {
            fresh.add(view)
        }
        terminalViews = fresh
    }

    // MARK: - 广播

    /// 无条件遍历全部 live view 重绘——任何 store 变更（add/edit/delete/
    /// enable/disable/全局开关/批量替换）都立即生效。
    ///
    /// 不保留全局 lastApplied 状态：register 期间新视图插入、广播排队时
    /// 不会因 mode 去重误跳过既有 view（Phase 4 P2-2 同类经验）。
    private func broadcastRedrawToAllRegisteredViews() {
        let liveViews = terminalViews.allObjects
        for view in liveViews {
            view.terminal.updateFullScreen()
            view.needsDisplay = true
        }
        AppLogger.terminal.info("Terminal highlight redraw broadcast to \(liveViews.count, privacy: .public) view(s)")
    }
}
