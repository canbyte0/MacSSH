import Observation
import SwiftData
import Foundation

/// 保存顶层页面选择，并持有独立于 SwiftUI 页面生命周期的会话状态。
@MainActor
@Observable
final class AppState {
    /// 简单偏好存储；仅由 AppState 访问，View 不直接读取 UserDefaults。
    private let userDefaults: UserDefaults

    /// 全局语言唯一状态源。修改后立即持久化，但不会重建任何 Runtime Manager。
    var language: AppLanguage {
        didSet {
            language.save(to: userDefaults)
        }
    }

    /// Sidebar 当前选择的顶层页面。
    var selectedSection: AppSection = .terminal

    /// 影响全部本地 zsh 的粘贴高亮；持久化后通过 SessionManager 立即广播，
    /// 不重启现有会话、不修改用户 Shell 配置，也不触碰 SSH。
    var pasteHighlightEnabled: Bool {
        didSet {
            userDefaults.set(pasteHighlightEnabled, forKey: AppPreferenceKey.pasteHighlightEnabled)
            sessionManager.setPasteHighlightEnabledForLocalSessions(pasteHighlightEnabled)
        }
    }

    /// SSH 连接工厂与共享安全服务（Phase 5 引入，Phase 6 扩展安全验证，
    /// Phase 8 起不再按 Host 持有单一连接——连接由 SessionManager
    /// 代表各 Remote Session 持有）。
    let sshService: SSHService

    /// 多 Terminal Session / Tab 的管理者（Phase 8），由本 App 层稳定
    /// 对象持有：切换 Sidebar / 页面不会销毁任何 Session。
    let sessionManager: SessionManager

    /// MacSSH 1.1 Phase 4：终端外观运行时协调器，由本 App 层稳定对象持有。
    /// 跟随 macOS Appearance 变化，把对应调色板应用到全部已注册的
    /// SwiftTerm `TerminalView`（Local / Remote、激活 / 非激活 Tab 一并覆盖）；
    /// 不重建任何 Runtime Session / Shell / SSH。
    let terminalAppearanceCoordinator: TerminalAppearanceCoordinator

    /// MacSSH 1.1 Phase 8：应用外观控制器，由本 App 层稳定对象持有。
    /// 单一 writer（任务书 §9 / §17）：应用外观偏好读写只由本控制器进行；
    /// Settings Picker 绑定 `controller.mode`。跟随用户请求模式设置
    /// `NSApp.appearance`，经 `TerminalAppearanceCoordinator` 同步刷新全部
    /// 已注册终端；system mode 下由 Coordinator 的 effectiveAppearance KVO
    /// 安全网处理系统外观变化。不重建任何 Runtime Session / Shell / SSH。
    let appearanceController: AppAppearanceController

    /// MacSSH 1.1 Phase 6：终端字符串高亮运行时协调器，由本 App 层稳定对象
    /// 持有。规则变更（add/edit/delete/enable/全局开关）经 Store 触发回调，
    /// 协调器无条件广播全部 live TerminalView 重绘（`terminal.updateFullScreen`
    /// + `needsDisplay`），不重建任何 Runtime Session / Shell / SSH / PTY /
    /// TerminalView；规则持久化在 UserDefaults（与 `language` 同类偏好）。
    let terminalHighlightCoordinator: TerminalHighlightCoordinator

    /// MacSSH 1.1 Phase 9：终端字号控制器，由本 App 层稳定对象持有。
    /// 单一 writer（任务书 §46）：终端字号偏好读写只由本控制器进行；
    /// SettingsView 减号/加号按钮绑定 `controller.size`，写入经 `didSet`
    /// 持久化并 apply。font **无外部触发源**（无 KVO / 系统信号 /
    /// `effectiveAppearance` 等价物），单一 writer 即单一 broadcaster——
    /// 不需像 Appearance 那样拆出独立 Coordinator。apply 经 SwiftTerm
    /// `font` public setter 内置 `resetFont()` → `computeFontDimensions` →
    /// `resize` → `sizeChanged` → Local `setWinSize` ioctl TIOCSWINSZ / Remote
    /// `resizeChannelPTY`，不重建任何 Runtime Session / Shell / SSH / PTY。
    let terminalFontSizeController: TerminalFontSizeController

    /// 传输运行时（Phase 10）：由本 App 层稳定对象持有——切换页面 /
    /// 切换会话 / 关闭 Transfers 面板都不取消传输；关闭传输所属会话时
    /// 经 `cancelAndAwaitTransfers` 屏障先取消并等待清理。
    let transferManager: TransferManager

    /// MacSSH 1.1 Phase 7：常用命令分组与命令的持久化 Store（SwiftData）。
    /// 由本 App 层稳定对象持有——切换页面不会销毁命令数据。
    let savedCommandStore: SavedCommandStore

    /// MacSSH 1.1 Phase 7：命令历史 Store（SwiftData + historyEnabled UserDefaults）。
    /// 只记录通过 MacSSH Execute 明确执行的命令（P1 安全边界：禁止 keyboard interception）。
    let commandHistoryStore: CommandHistoryStore

    /// MacSSH 1.1 Phase 7：统一 Paste / Execute 调度器。每次 action 实时读 activeSession，
    /// 不缓存 stale target；disconnected → disable；成功 Execute 后 append history + 恢复焦点。
    let commandDispatcher: TerminalCommandDispatcher

    /// MacSSH 1.1 Phase 10B：Agent 会话注册表（memory-only，per-terminal-session）。
    /// 仅由 AppState 装配持有；Agent domain 不侵入 Terminal / SSH service。
    let agentConversationStore: AgentConversationStore

    /// MacSSH 1.1 Phase 10B：Agent Sidebar 视图模型（mock provider，无网络 / 无执行）。
    /// 每次 action 实时读 SessionManager.activeSession，不缓存 stale target。
    let agentViewModel: AgentViewModel

    /// MacSSH 1.1 Phase 7：右侧栏是否展开（UI preference，UserDefaults 持久化）。
    var isRightSidebarVisible: Bool {
        didSet {
            userDefaults.set(isRightSidebarVisible, forKey: AppPreferenceKey.rightSidebarVisible)
        }
    }

    /// MacSSH 1.1 Phase 7：右侧栏当前选中 tab（history / savedCommands）。
    var selectedRightSidebarTab: CommandSidebarTab {
        didSet {
            userDefaults.set(selectedRightSidebarTab.rawValue, forKey: AppPreferenceKey.rightSidebarTab)
        }
    }

    /// 右侧命令栏在当前 App 运行期间的宽度。
    ///
    /// 此状态有意不写入 UserDefaults：切换页面或收起再展开时保留，
    /// 完全退出并重新启动后恢复为设计默认值。
    var rightSidebarWidth: CGFloat = AppTheme.Layout.rightSidebarWidth

    init(
        modelContainer: ModelContainer,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        language = AppLanguage.load(from: userDefaults)
        pasteHighlightEnabled = userDefaults.bool(forKey: AppPreferenceKey.pasteHighlightEnabled)

        let sshService = SSHService(modelContainer: modelContainer)
        self.sshService = sshService

        // MacSSH 1.1 Phase 4：协调器须在 SessionManager 之前创建——
        // SessionManager 构造时即创建首个 Local Session，由 AppState 在装配
        // 完成后回填注册其 terminalView（与 localeProvider 回填模式一致）。
        let terminalAppearanceCoordinator = TerminalAppearanceCoordinator()
        self.terminalAppearanceCoordinator = terminalAppearanceCoordinator

        // MacSSH 1.1 Phase 8：外观控制器须在 SessionManager 之前创建并 apply
        // ——任何 Local/Remote Terminal 创建前 NSApp.appearance 已确定，首帧
        // 即为请求模式，避免 Light→Dark / Dark→Light 闪烁（任务书 §18 / §20）。
        // 单一 writer：只有本控制器读写 appearanceMode 偏好。Coordinator registry
        // 此刻为空，apply 的 terminal 刷新 no-op；NSApp.appearance 已就位。
        let appearanceController = AppAppearanceController(
            userDefaults: userDefaults,
            coordinator: terminalAppearanceCoordinator
        )
        self.appearanceController = appearanceController

        // MacSSH 1.1 Phase 6：高亮协调器须同样在 SessionManager 之前创建，
        // 初始 Local Session 的 terminalView 由本装配末尾回填注册（与外观
        // 协调器同一模式，避免只注册后来新建 Tab 的遗漏）。
        let terminalHighlightCoordinator = TerminalHighlightCoordinator(userDefaults: userDefaults)
        self.terminalHighlightCoordinator = terminalHighlightCoordinator

        // MacSSH 1.1 Phase 9：字号控制器须在 SessionManager 之前创建——
        // SessionManager 构造时即创建首个 Local Session，由 AppState 在装配
        // 完成后回填注册其 terminalView（与 Appearance / Highlight 同模式）。
        // 此时 registry 为空，apply 的 terminal 刷新 no-op；request size
        // 已就位（load 后 `size` 已是用户上次设置）。
        // 单一 writer：只有本控制器读写 `terminalFontSize` 偏好。
        let terminalFontSizeController = TerminalFontSizeController(userDefaults: userDefaults)
        self.terminalFontSizeController = terminalFontSizeController

        let sessionManager = SessionManager(sshService: sshService)
        let transferManager = TransferManager()
        // 双向弱引用装配（两者均由本对象强持有，绝不形成引用环）。
        transferManager.sessionManager = sessionManager
        sessionManager.transferManager = transferManager
        sessionManager.terminalAppearanceCoordinator = terminalAppearanceCoordinator
        sessionManager.terminalHighlightCoordinator = terminalHighlightCoordinator
        // MacSSH 1.1 Phase 9：与 Appearance / Highlight 同模式注入 weak 引用。
        sessionManager.terminalFontSizeController = terminalFontSizeController
        self.sessionManager = sessionManager
        self.transferManager = transferManager

        // MacSSH 1.1 Phase 7：命令侧边栏 Store + Dispatcher 装配。
        // 必须在 localeProvider 闭包（捕获 self）之前初始化全部 Phase 7 非可选属性。
        let savedCommandStore = SavedCommandStore(modelContainer: modelContainer)
        let commandHistoryStore = CommandHistoryStore(
            modelContainer: modelContainer,
            userDefaults: userDefaults
        )
        let commandDispatcher = TerminalCommandDispatcher(
            sessionManager: sessionManager,
            historyStore: commandHistoryStore
        )
        self.savedCommandStore = savedCommandStore
        self.commandHistoryStore = commandHistoryStore
        self.commandDispatcher = commandDispatcher

        // MacSSH 1.1 Phase 10B：Agent 装配（任务书 §9 最小集成）。
        // AppState 持有 Store / ViewModel；具体 active session 由 ViewModel
        // 经闭包实时解析（弱引用 SessionManager，Agent domain 不反向持有），
        // SessionManager 完全不感知 Agent（不改 Terminal service）。
        let agentConversationStore = AgentConversationStore()
        let agentViewModel = AgentViewModel(
            store: agentConversationStore,
            provider: MockAgentProvider(),
            activeSessionProvider: { [weak sessionManager] in
                sessionManager?.activeSession
            },
            allSessionsProvider: { [weak sessionManager] in
                sessionManager?.sessions ?? []
            }
        )
        self.agentConversationStore = agentConversationStore
        self.agentViewModel = agentViewModel

        // Phase 7 右侧栏 UI preference（UserDefaults 持久化，默认收起 + 默认 history tab）。
        if userDefaults.object(forKey: AppPreferenceKey.rightSidebarVisible) == nil {
            self.isRightSidebarVisible = false
        } else {
            self.isRightSidebarVisible = userDefaults.bool(forKey: AppPreferenceKey.rightSidebarVisible)
        }
        if let storedTab = userDefaults.string(forKey: AppPreferenceKey.rightSidebarTab),
           let tab = CommandSidebarTab(rawValue: storedTab) {
            self.selectedRightSidebarTab = tab
        } else {
            self.selectedRightSidebarTab = .history
        }

        // Phase 1（1.1 Localization）：调度器 / 拒绝路径按当前 App Locale
        // 生成用户文案；语言切换只更新文案，绝不重建传输队列或 Session。
        transferManager.localeProvider = { [weak self] in
            self?.language.locale ?? AppLanguage.defaultLanguage.locale
        }
        sessionManager.localeProvider = { [weak self] in
            self?.language.locale ?? AppLanguage.defaultLanguage.locale
        }
        // 启动时 SessionManager.init 已创建初始 Local Session；回填 provider。
        for session in sessionManager.sessions {
            session.localeProvider = sessionManager.localeProvider
            // MacSSH 1.1 Phase 4：回填注册初始 Local Session 的 terminalView，
            // 立即应用当前 App Effective Appearance；之后外观变化由协调器 KVO
            // 统一推进到全部 Session（含后续新建 / Reconnect 的 Remote Tab）。
            if let terminalView = session.localService?.terminalView {
                terminalAppearanceCoordinator.register(terminalView)
                // MacSSH 1.1 Phase 6：同一回填点注册高亮 provider——初始
                // Local Session 的高亮立即生效，不等首次 draw。
                terminalHighlightCoordinator.register(terminalView)
                // MacSSH 1.1 Phase 9：同一回填点注册字号 controller——初始
                // Local Session 的字号立即应用（实际 SessionManager.createLocalSession
                // 内已通过 weak controller 注册过，此处的 register 是冗余但
                // 幂等的——与 Appearance / Highlight 同模式，保留对称）。
                terminalFontSizeController.register(terminalView)
            }
        }

        // Phase 11：SFTPService 的 Rename / Delete 经本闸查询传输冲突。
        TransferConflictGate.install(manager: transferManager)

        // 日志不包含密码、私钥、终端内容或其他敏感信息。
        AppLogger.app.info("Application state initialized")
    }

    // MARK: - Hosts 页入口（Phase 8）

    /// Hosts 页 Connect / Open Terminal：创建新的 Remote Terminal Session
    /// 并切换到 Terminal 页（同 Host 重复点击 = 继续新建，任务书 36/37）。
    func connectHost(_ host: Host) {
        sessionManager.createRemoteSession(host: host)
        selectedSection = .terminal
    }

    /// Hosts 页 Disconnect：关闭该 Host 的全部 Terminal Session
    /// （有活跃会话时先经 SessionManager 确认）。
    func disconnectHost(_ host: Host) {
        sessionManager.requestCloseAllSessions(hostID: host.id, hostName: host.name)
    }

    /// 主窗口底部左侧展示当前阶段或 Active Session 状态（任务书 66）。
    func statusText(locale: Locale) -> String {
        guard selectedSection == .terminal else {
            if selectedSection == .transfers,
               let summary = transferManager.queueSummary(locale: locale) {
                return summary
            }
            return L10n.string(
                "status.transfer_queue",
                defaultValue: "Transfer Queue",
                locale: locale
            )
        }

        guard let session = sessionManager.activeSession else {
            return L10n.string(
                "terminal.no_sessions",
                defaultValue: "No Terminal Sessions",
                locale: locale
            )
        }
        return session.statusText(locale: locale)
    }

    /// Terminal 页面显示 Active Session 的 PTY 尺寸，其他页面显示页面名称。
    func statusDetail(locale: Locale) -> String {
        guard selectedSection == .terminal else {
            return selectedSection.localizedTitle(locale: locale)
        }

        guard let session = sessionManager.activeSession else {
            return ""
        }
        return session.sizeText
    }
}
