# MacSSH 1.1 Phase 8A — Manual App Appearance 架构调查报告

> 角色：Independent Architecture Investigator（仅调查，未修改任何生产代码 / SwiftTerm fork / commit / merge / push / 未开始 Phase 8B）。
> 调查方法：源码逐文件审阅 + Apple `NSApplication.effectiveAppearance` 官方文档核对 + 现有测试套件审阅。**未运行 live GUI probe**（遵守 §57「STOP / 不修改生产代码」），源码级 + 官方文档证据充分；live probe 作为 Phase 8B 第一步经验确认（见 §58 known limitations）。

---

## 1. branch

`feature/macssh-1.1-manual-appearance`

创建自 `main`（`git fetch github` 后确认 local main 领先 `github/main` 1 commit、落后 0 commit —— local main 即最新，已含 Phase 7 提交 `46d87e1`/`245689d`）。

## 2. baseline SHA

`245689dd36421d2c8491d20dcd9388fc1c6c4f34`（= main HEAD，working tree clean）。

## 3. production modifications

**无。** 本阶段未修改任何 `.swift` 生产源码、SwiftTerm fork、entitlements、pbxproj、xcstrings。唯一产物为本报告文件（`Docs/Phase8A-ManualAppearance-Architecture-Investigation.md`）与分支创建。`git diff` 为空（仅新增本未跟踪报告）。

## 4. current Settings appearance UI

`MacSSH/Features/Settings/SettingsView.swift:86-90`：

```swift
Section("settings.section.appearance") {
    LabeledContent("settings.mode") {
        Text("settings.system_mode")
    }
}
```

只读 `LabeledContent`：左 `settings.mode`（zh「模式」/ en「Mode」），右 `settings.system_mode`（zh「跟随系统」/ en「System」）。**无交互、无选择器、无持久化** —— 永远显示「跟随系统」文案，App 实际也只跟随系统。

## 5. current appearance persistence

**无。** 全代码库（`MacSSH/`，排除 Tests/ThirdParty）无任何 appearance / mode / colorScheme 偏好写入 UserDefaults。`AppPreferenceKey`（`AppLanguage.swift:46-52`）仅有 `language`/`rightSidebarVisible`/`rightSidebarTab` 三个 key，无 appearance。App 当前行为 = 纯「跟随系统」（从不设置 `NSApp.appearance`，见 §15）。

## 6. current TerminalAppearanceProvider

`MacSSH/Services/Terminal/TerminalAppearanceProvider.swift`（enum，226 行）。

- `enum Mode: String, Equatable, Sendable { case light; case dark }`（`:44-47`）—— **只有 light/dark，没有 `system` case**（system 语义在 App 层，不在终端 palette 层；terminal palette 永远是某一具体模式）。
- `struct RGB`/`struct Palette`（`:50-63`），`Sendable`，确定性 sRGB 固定值（不依赖 `NSColor` 动态解析）。
- Light palette（`:68-74`）：fg `#000000`、bg `#FFFFFF`、selection bg `#B3D7FF`、selection fg `#000000`。
- Dark palette（`:80-86`）：fg `#FFFFFF`、bg `#1E1E1E`、selection bg `#264F78`、selection fg `#FFFFFF`。
- `mode(for appearance: NSAppearance?) -> Mode`（`:92-101`）：`bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .accessibilityHighContrastDarkAqua])`，dark 系→`.dark`，其余→`.light`；nil→`.light`。
- `palette(for:)`/`paletteForCurrentAppAppearance()`（`:104-116`）：后者 `@MainActor` 读 `NSApp?.effectiveAppearance`。
- `apply(_:to terminalView:)`（`:155-161`）：设 `nativeForegroundColor`/`nativeBackgroundColor`/`selectedTextBackgroundColor`/`selectedTextForegroundColor`，触发 SwiftTerm `colorsChanged()` 全量重绘（含 scrollback / clear / alternate screen）。
- `applyCurrentAppAppearance(to:)`（`:165-168`）：Service init 阶段一次性应用。
- 不触碰字体/几何；不调 `installColors`（保留 ANSI 16/256）。

**复用结论**：Phase 8 完全复用，不改 palette 值、不改 `apply`。仅可能新增「由 `AppAppearanceMode` 解析当前应作用模式」的薄接缝（见 §25/§45）。

## 7. current TerminalAppearanceCoordinator

`MacSSH/Services/Terminal/TerminalAppearanceCoordinator.swift`（`@MainActor final class`，185 行）。

- 弱引用注册表 `private var terminalViews: NSHashTable<TerminalView> = .weakObjects()`（`:43`）—— Local/Remote 统一（`LocalProcessTerminalView` 是 `TerminalView` 子类）；`allObjects` 访问自动回收已 nil 槽位。
- appearance 解析接缝 `appearanceResolver: @MainActor () -> NSAppearance?`，默认 `{ NSApp?.effectiveAppearance }`（`:51,65`）。
- observation 安装接缝 `observationInstaller`，默认 `installDefaultAppAppearanceObservation`（`:57,66`）。
- `register(_:)`（`:79-85`）：`ensureObservationInstalled()` + 加入 weak 表 + 立即 apply 当前 palette（新建 Tab 无白闪）。
- `ensureObservationInstalled()`（`:126-133`）：幂等，`appearanceObservation == nil` 才调 installer；installer 返回 nil（NSApp 未就绪）则保持 nil，下次 `register` 重试。
- `installDefaultAppAppearanceObservation`（`:139-157`）：`guard let app = NSApp` 后 `app.observe(\.effectiveAppearance, options: [.new])`，回调经 `Task { @MainActor in handler() }` 切回主线程。
- `applyCurrentAppearanceToAllRegisteredViews()`（`:163-170`，**private**）：**无条件**遍历全部 live view apply（P2-2：移除 `lastAppliedMode` 全局去重，避免 register 期间新视图插入时排队广播被误跳过）。
- 测试 seams：`applyModeForTesting(_:)`（`:91-96`）、`registeredViewCountForTesting`（`:99-101`）、`isObservationInstalledForTesting`（`:105-107`）、`compactRegistryForTesting()`（`:111-118`）。

**复用结论**：Phase 8 **不重写** Coordinator。唯一最小改动：把 private `applyCurrentAppearanceToAllRegisteredViews()` 暴露为 internal/public `applyCurrentAppearance()`（或新增 public wrapper），供 `AppAppearanceController` 在手动切换后**同步显式**调用（§24）。KVO 路径保留作为 system 模式下系统外部切换的安全网。

## 8. current observation mechanism

KVO on `NSApplication.effectiveAppearance`。安装点 = `register(_:)`（不在 `init`，P2-1 整改：`init` 阶段 NSApp 可能仍 nil）。

## 9. observed object / keyPath

- observed object：`NSApp`（`NSApplication` 单例）。
- keyPath：`\.effectiveAppearance`（`NSApplication.effectiveAppearance`）。
- options：`[.new]`。
- 回调线程：AppKit 主线程投递 → 显式 `Task { @MainActor in handler() }` 切回 MainActor（`:148-152`）。

## 10. system Light→Dark path

macOS 系统外观 Light→Dark（App 当前 `NSApp.appearance == nil` 即跟随系统）→ `NSApp.effectiveAppearance` 由 aqua 变 darkAqua → KVO `\.effectiveAppearance` 触发 → `Task { @MainActor in handler() }` → `applyCurrentAppearanceToAllRegisteredViews()` → `palette(for: appearanceResolver())`（此时 `NSApp?.effectiveAppearance` 已 dark）→ 遍历 weak 表全部 live `TerminalView` `apply(_:to:)` → `colorsChanged()` 全量重绘（含非激活 Tab，因为 weak 表持有全部 Service 持有的 TerminalView，不依赖 SwiftUI 视图层级）。

## 11. Local update path

- 创建：`SessionManager.createLocalSession()`（`SessionManager.swift:116-135`）→ `LocalTerminalService(session:)` → `LocalTerminalService.init` 在 `terminalView` 创建后立即 `TerminalAppearanceProvider.applyCurrentAppAppearance(to: terminalView)`（`LocalTerminalService.swift:60`，一次性初始应用）→ `SessionManager` 紧接 `terminalAppearanceCoordinator?.register(service.terminalView)`（`:130`，纳入动态更新）。
- AppState 装配末尾回填注册初始 Local Session（`AppState.swift:150-160`）。
- 运行时外观变化：经 Coordinator KVO 广播（§10）。

## 12. Remote update path

- 创建：`SessionManager.createRemoteSession(host:)` → `runConnectFlow` → 认证成功后 `RemoteTerminalService(connection:hostname:port:)`（`RemoteTerminalService.swift:65`）→ init 创建 `TerminalView(frame:...)`（`:84-89`）后 `TerminalAppearanceProvider.applyCurrentAppAppearance(to: terminalView)`（`:99`）→ `SessionManager` `terminalAppearanceCoordinator?.register(service.terminalView)`（`SessionManager.swift:447`）。
- Reconnect 复用原 TerminalView（`reattach`），不重新注册（外观已就位）。
- 运行时外观变化：经 Coordinator KVO 广播（§10）。

## 13. existing-session registry

`NSHashTable<TerminalView>.weakObjects()`（Coordinator `:43`）。Session 关闭 / Service 释放后槽位自动 nil，无需手工移除。`allObjects` 访问时自动回收。广播 `applyCurrentAppearanceToAllRegisteredViews()` 遍历 `allObjects` → 覆盖全部 live Local/Remote、激活/非激活 Tab（非激活 Tab 的 TerminalView 仍由各 Service 持有接收后台输出，虽不在 SwiftUI 层级但仍在 weak 表中）。**Phase 8 直接复用，满足 §2 全作用域 + §21 existing sessions 实时更新**。

## 14. new-session backfill

两条 backfill 点均已存在，Phase 8 无需新增：
1. `AppState.init` 末尾（`AppState.swift:150-160`）：注册 `SessionManager.init` 已创建的初始 Local Session 的 terminalView（回填，避免只注册后来新建 Tab 的遗漏）。
2. `SessionManager.createLocalSession`（`:130`）/ `createRemoteSession` flow（`:447`）：新建 Session 时立即 register + Service init 已 apply。

**关键**：Service init 的 `applyCurrentAppAppearance` 读 `NSApp?.effectiveAppearance`。只要 `AppAppearanceController` 在 **AppState.init 创建 SessionManager 之前** 设好 `NSApp.appearance`（§30），新 Session 一创建即正确（§22，无白闪）。

## 15. NSApp.appearance system behavior

设 `NSApp.appearance = nil`：
- App 恢复跟随 macOS 系统外观（`effectiveAppearance` 解析为系统当前）。
- 系统随后 Light↔Dark → `effectiveAppearance` 自动变 → KVO 触发 → Coordinator apply。
- 来源：Apple `NSApplication.effectiveAppearance` 文档（effectiveAppearance = `appearance` 若设置，否则系统外观；`appearance` 默认 nil）。

## 16. NSApp.appearance light behavior

设 `NSApp.appearance = NSAppearance(named: .aqua)`：
- `effectiveAppearance` 解析为 aqua（Light），无论系统当前 Light/Dark。
- App 全局强制 Light；系统外观后续变化不影响（effectiveAppearance 保持 aqua → KVO 不触发，Terminal 保持 Light）。

## 17. NSApp.appearance dark behavior

设 `NSApp.appearance = NSAppearance(named: .darkAqua)`：
- `effectiveAppearance` 解析为 darkAqua（Dark），无论系统当前。
- App 全局强制 Dark；系统外观变化不覆盖（effectiveAppearance 保持 darkAqua → KVO 不触发，Terminal 保持 Dark）。

## 18. SwiftUI response

`NSApp.appearance` 是 App 级外观权威。AppKit 把 effective appearance 传播到全部 NSWindow/NSView；SwiftUI 的 `@Environment(\.colorScheme)` 与 `effectiveAppearance` 由同一来源派生。设 `NSApp.appearance` 后，SwiftUI 的 NavigationSplitView / Sidebar / Toolbar / Menu / Sheet / Settings / Phase 7 Right Sidebar **自动跟随**（均用系统语义色 / dynamic color）。**无需 `.preferredColorScheme`**（§19）。

## 19. Settings window response

MacSSH **没有独立 Settings scene/window**。`MacSSHApp.body` 仅一个 `WindowGroup("MacSSH") { RootView()... }`（`MacSSHApp.swift:67-83`）；Settings 是 `RootView.selectedWorkspace` 的 `case .settings: SettingsView()`（`RootView.swift:113-114`），与主窗口同一窗口同一 detail 区。因此设 `NSApp.appearance` 同时覆盖主窗口与 Settings 视图。**不存在「只改主窗口、Settings 不同步」问题**（§28 满足）。

## 20. Sidebar response

`AppSidebar`（`Components/Sidebar/AppSidebar.swift`）+ `NavigationSplitView`（`RootView.swift:17-22`）全部使用系统语义色（如 `Color(nsColor: .windowBackgroundColor)` 见 `RootView.swift:35`）。`AppTheme.accentColor = .teal`（`AppTheme.swift:7`，系统色）。`NSApp.appearance` 改变后全部自动重绘。无需额外代码。

## 21. Menu/sheet response

系统原生 `CommandMenu`（`MacSSHApp.swift:138`）、`.sheet`（`RootView.swift:41`）、`.alert`（`:44,79`）、Toolbar（`AppToolbarContent`）均由 AppKit/SwiftUI 按 effective appearance 自动渲染。`NSApp.appearance` 覆盖之。Phase 8 不额外 override（§30 系统原生跟随，不 override）。

## 22. Terminal KVO response to manual override

`NSApp.effectiveAppearance` 是 `\.effectiveAppearance` KVO 的被观察量。手动设 `NSApp.appearance` 改变 effectiveAppearance → **当 resolved 值实际变化时 KVO 触发**（Apple 文档确认）。

逐案（§19 要求的 5 转换）：
| 转换 | effectiveAppearance 变化？ | KVO 触发？ | Terminal 结果 |
|---|---|---|---|
| system→light（系统=Dark） | darkAqua→aqua | ✅ 触发 | →Light ✓ |
| system→light（系统=Light） | aqua→aqua（不变） | ❌ 不触发 | 已 Light ✓ |
| system→dark（系统=Light） | aqua→darkAqua | ✅ 触发 | →Dark ✓ |
| system→dark（系统=Dark） | darkAqua→darkAqua（不变） | ❌ 不触发 | 已 Dark ✓ |
| light→dark | aqua→darkAqua | ✅ 触发 | →Dark ✓ |
| dark→light | darkAqua→aqua | ✅ 触发 | →Light ✓ |
| manual→system（系统=Light） | darkAqua→aqua | ✅ 触发 | →Light ✓ |
| manual→system（系统=Dark） | darkAqua→darkAqua（不变） | ❌ 不触发 | 已 Dark ✓ |

**结论**：现有 KVO 对全部手动 case 都得到正确结果。不触发的两种是「目标值与当前相同」——Terminal 本就正确，非 bug。

## 23. KVO gaps

1. **异步 hop**：KVO 回调经 `Task { @MainActor in handler() }`（Coordinator `:148-152`），下一 runloop 才 apply。对 Settings 实时切换（§32）可接受（sub-frame）；**对启动首帧不可依赖**——但启动路径不靠 KVO，而靠 Service init 的同步 `applyCurrentAppAppearance`（§14/§30）。
2. **no-fire 边沿**（§22 表中两行）：resolved 值未变时不触发。结果正确，但若 Coordinator 内部曾有全局 dedup（P2-2 已移除 `lastAppliedMode`）可能误判；现已无 dedup，无问题。
3. **测试覆盖盲区**：现有 `TerminalAppearanceTests` 全部用注入 `observationInstaller` 桩验证（§48），不验证真实 NSApp KVO 对手动 `appearance` 赋值的触发——需 Phase 8B live probe / 新测试补强（§47/§58）。

## 24. explicit coordinator update necessity

**需要**（推荐，§20）。理由：KVO 虽覆盖全部 case（§22），但 (a) 异步 hop；(b) 测试不易直接驱动真实 NSApp KVO。建立**确定性同步路径**：

```
AppAppearanceController.setMode(_:) / apply()
  → NSApp.appearance = <nil | .aqua | .darkAqua>
  → terminalAppearanceCoordinator.applyCurrentAppearance()   // 显式同步
```

KVO 保留作为 **system 模式下系统外部切换** 的安全网（controller 不被调用时）。两条路径汇于同一 `applyCurrentAppearanceToAllRegisteredViews()`，无双重状态。最小改动 = 把该 private 方法暴露为 `func applyCurrentAppearance()`（internal/public），不重写 Coordinator。

## 25. recommended AppAppearanceMode

```swift
enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let defaultMode: AppAppearanceMode = .system   // 默认 + 老用户升级行为不变

    var id: Self { self }

    /// 解析为应作用到 NSApp 的 NSAppearance。system → nil（跟随系统）。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    static func load(from defaults: UserDefaults) -> AppAppearanceMode {
        guard let raw = defaults.string(forKey: AppPreferenceKey.appearanceMode),
              let mode = AppAppearanceMode(rawValue: raw)
        else { return .defaultMode }   // 未知/损坏/未来 enum case → system，绝不 crash
    }
    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: AppPreferenceKey.appearanceMode)
    }
}
```

完全沿用 `AppLanguage`（`AppLanguage.swift:6-43`）模板：`String` rawValue、`CaseIterable`/`Identifiable`/`Sendable`、`load`/`save`、default + 损坏回退。`system`→`nil` 是关键（§15/§40）。

## 26. recommended persistence

`UserDefaults`（手动 `load`/`save`，**不**用 `@AppStorage`）。新 key 加到 `AppPreferenceKey`：

```swift
static let appearanceMode = "macssh.appearanceMode"
```

理由（§36/§37）：
- `@AppStorage` 是 View 级响应式存储，无法在 **AppState.init 早期、窗口创建前** 设 `NSApp.appearance`（View init 发生在 body 求值 = 窗口已创建之后 → 启动闪屏）。
- `@AppStorage` 无法在写入时触发 `NSApp.appearance =` 副作用 + Coordinator 通知（需 separate `.onChange`，多写者）。
- 手动 UserDefaults = 单一写者、可控 apply 时机，与 `AppLanguage`/`rightSidebarVisible` 一致。

注：`AppPreferenceKey.language = "appLanguage"`（无 `macssh.` 前缀）与右侧栏 `macssh.rightSidebar*` / 高亮 `macssh.terminalHighlightSettings` 命名不一致；新 key 采用 `macssh.` 前缀风格（与 Phase 6/7 既有 key 一致）。

## 27. invalid-value fallback

`load` 对未知 rawValue / 缺失 key / 损坏值返回 `.system`（§25），不 crash。与 `AppLanguage.load` 回退 `.defaultLanguage` 同构（`AppLanguage.swift:30-37`）。未来新增 enum case（如 `.highContrastDark`）旧版读到未知值也安全回退。

## 28. recommended AppAppearanceController

`@MainActor`（`NSApp.appearance` 必须 main-thread；与 `TerminalAppearanceCoordinator` 同 actor 边界）。

推荐方案 A（独立 controller，测试性优，与 `TerminalAppearanceCoordinator` 持有模式对齐）：

```swift
@MainActor
@Observable
final class AppAppearanceController {
    private let userDefaults: UserDefaults
    private weak var terminalAppearanceCoordinator: TerminalAppearanceCoordinator?
    /// 测试接缝：注入 NSApp 赋值（生产 = { NSApp?.appearance = $0 }）
    private let appearanceSetter: @MainActor (NSAppearance?) -> Void

    private(set) var mode: AppAppearanceMode

    init(
        userDefaults: UserDefaults = .standard,
        coordinator: TerminalAppearanceCoordinator,
        appearanceSetter: @escaping @MainActor (NSAppearance?) -> Void = { NSApp?.appearance = $0 }
    ) {
        self.userDefaults = userDefaults
        self.terminalAppearanceCoordinator = coordinator
        self.appearanceSetter = appearanceSetter
        self.mode = AppAppearanceMode.load(from: userDefaults)
    }

    /// 启动与运行时切换共用：写 NSApp.appearance + 同步通知 Coordinator。
    func apply() {
        appearanceSetter(mode.nsAppearance)
        terminalAppearanceCoordinator?.applyCurrentAppearance()   // §24 同步路径
    }

    /// Settings Picker 绑定入口。
    func setMode(_ newMode: AppAppearanceMode) {
        guard newMode != mode else { return }
        mode = newMode
        newMode.save(to: userDefaults)
        apply()
    }
}
```

备选方案 B（更最小，无新类）：把 `var appearanceMode: AppAppearanceMode` 直接放 `AppState`（`didSet { save + apply }`），`apply` 内联设 `NSApp.appearance` + 调 Coordinator。与 `language` 完全同模式。

**推荐 A**：测试性（注入 `appearanceSetter` 桩、注入 Coordinator 桩）与 `TerminalAppearanceCoordinator` 既有测试 seams 对齐；`AppState` 已是多个 coordinator 的拥有聚合点，再加一个 controller 一致。`@Observable` 让 SettingsView 直接 `@Bindable` 绑定 `mode`（或经 `AppState` 转发）。

## 29. ownership

`AppState` 强持有（与 `terminalAppearanceCoordinator`/`terminalHighlightCoordinator`/`sessionManager` 同模式）。`AppState.swift:35` 已有 `let terminalAppearanceCoordinator`；新增 `let appAppearanceController: AppAppearanceController`。生命周期 = App 全程（`AppState` 由 `MacSSHApp` `@State` 持有）。**不允许 SettingsView 自建 controller**（§34，避免短命 View 持有 App 级状态）。

## 30. launch apply timing

**最早安全 apply 点 = `AppState.init` 顶部**（`userDefaults` 赋值后、`SessionManager` 创建前）。

`AppState.init` 当前顺序（`AppState.swift:81-168`）：
1. `userDefaults =`（:85）
2. `language = load`（:86）
3. `sshService`（:88-89）
4. `terminalAppearanceCoordinator = TerminalAppearanceCoordinator()`（:94-95）
5. `terminalHighlightCoordinator`（:100-101）
6. **`sessionManager = SessionManager(sshService:)`（:103）← 此处 `SessionManager.init` 立即 `createLocalSession()`，创建首个 Local TerminalView 并 `applyCurrentAppAppearance`（读 `NSApp.effectiveAppearance`）**
7. ... 回填注册初始 Local Session（:150-160）

**推荐插入点**：在 step 4（coordinator 创建）之后、step 6（SessionManager）之前，创建 `AppAppearanceController`（注入 coordinator）并 `apply()`。此时：
- `NSApp.appearance` 已设（窗口尚未创建 → 无闪屏）。
- step 6 首个 Local TerminalView 创建时 `applyCurrentAppAppearance` 读到正确 `effectiveAppearance`（§14/§22）。
- `NSApp` 在 `MacSSHApp.init`（`@NSApplicationDelegateAdaptor` 确保 NSApplication 先于 App.init 创建）阶段已非 nil（Coordinator installer 的 `guard let app = NSApp` 注释亦证实「TerminalView 真正创建时 NSApplication 存在」）。

`MacSSHApp.init`（`MacSSHApp.swift:61`）创建 `AppState` 在 `body` 求值（窗口创建）之前 → 满足「Scene creation 前」。

## 31. flash risk

**极低**。`NSApp.appearance` 在 `AppState.init`（窗口创建前）设置。窗口首帧即正确 appearance。唯一理论边沿：若 `NSApp` 在 `AppState.init` 顶部仍 nil（实际不会，见 §30），`appearanceSetter` 用 `NSApp?.appearance =`（optional set）静默跳过，退化为跟随系统（= `system` 默认行为），不崩。可接受。

## 32. Settings UI design

保持当前单行（`SettingsView.swift:86-90`），把只读 `LabeledContent` 换成原生 `Picker(.menu)`，与现有语言 Picker（`SettingsView.swift:32-40`，`.pickerStyle(.menu)`）风格完全一致：

```swift
Section("settings.section.appearance") {
    Picker("settings.mode", selection: $appState.appAppearanceController.mode) {   // 或经 AppState 转发
        Text("settings.appearance.system").tag(AppAppearanceMode.system)
        Text("settings.appearance.light").tag(AppAppearanceMode.light)
        Text("settings.appearance.dark").tag(AppAppearanceMode.dark)
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("settings.appearanceMode")
}
```

不做：三个大按钮、自定义颜色 card、segmented（除非既有 Settings 风格要求——现有是 Form `.grouped` + `.menu` Picker，故沿用）。`mode` 变更经 `setMode`（didSet/onReceive）即时 apply（§32 live switching，无 Apply/Save/Restart）。

## 33. localization

新 3 key（遵循既有 `settings.*` 点分命名，与 `settings.section.appearance`/`settings.mode` 同前缀）：

| key | en | zh-Hans |
|---|---|---|
| `settings.appearance.system` | Follow System | 跟随系统 |
| `settings.appearance.light` | Light | 浅色 |
| `settings.mode.dark` → `settings.appearance.dark` | Dark | 深色 |

（任务书 §16 建议 `appearance.mode.*`；本报告推荐 `settings.appearance.*` 以与既有 `settings.*` 体系一致，`LocalizationTests` 正则扫描源码字面量亦更规整。最终 key 名由实现阶段定，但须 en+zh-Hans 完整、`testCatalogHasNoObsoleteKeys` 通过。）

**注意**：现有 `settings.system_mode`（zh「跟随系统」/ en「System」）在新 UI 后将无 production 使用点 → 变 obsolete key → `LocalizationTests.testCatalogHasNoObsoleteKeys` FAIL（Phase 7B remediation 教训）。Phase 8B 须**删除 `settings.system_mode`** 或将其 rawValue 复用为新 `settings.appearance.system`（推荐删除以保持命名一致）。不得硬编码 UI 字符串。

## 34. accessibility

`Picker(.menu)` 原生键盘可达（Tab 聚焦、Space/Enter 展开、上下选择）、VoiceOver 读 label（`settings.mode`「模式」）+ 当前值（「跟随系统」）。`.accessibilityIdentifier("settings.appearanceMode")`。不依赖颜色状态表达（§17 满足）。

## 35. Light palette

复用 `TerminalAppearanceProvider.light`（`:68-74`）：bg `#FFFFFF`、fg `#000000`、selection `#B3D7FF`。**不改**（§24）。

## 36. Dark palette

复用 `TerminalAppearanceProvider.dark`（`:80-86`）：bg `#1E1E1E`、fg `#FFFFFF`、selection `#264F78`。**不改**（§25）。

## 37. Highlight integration

`TerminalHighlightPalette.nsColor(for:appearance:)`（`TerminalHighlightPalette.swift:44-51`）按 `appearance.bestMatch` 取 light/dark RGBA。`TerminalHighlightProviderImpl.cellHighlights`（`TerminalHighlightProviderImpl.swift:45`）**每帧**读 `NSApp?.effectiveAppearance`（无缓存）→ 手动 appearance 切换后立即正确解析。

重绘触发链：`TerminalAppearanceCoordinator.apply` → SwiftTerm `colorsChanged()` → `terminal.updateFullScreen()` → 重新调 `cellHighlights` → 高亮色重解析。故 manual appearance 切换后高亮 palette 自动同步（§26）。

`HighlightRulesEditor.HighlightRuleRow` 的色点用 `@Environment(\.colorScheme)`（`HighlightRulesEditor.swift:116,122`）—— SwiftUI colorScheme 由 `effectiveAppearance` 派生，跟随 `NSApp.appearance` 自动。无双重 source（§45）。

## 38. existing session behavior

切换 appearance 时，`AppAppearanceController.apply` → `coordinator.applyCurrentAppearance()` → 遍历 weak 表全部 live view（Local A/B、Remote C 全含）apply。非激活 Tab 也在表内（Service 持有）。**全部实时更新**（§21 满足）。

## 39. new session behavior

`NSApp.appearance` 已在 `AppState.init` 设好。新建 Local（`SessionManager.createLocalSession:130`）/ Remote（`:447`）时 Service init `applyCurrentAppAppearance` 读到正确 `effectiveAppearance` → **一创建即正确**（§22 满足，无先 Default Light 再 repaint）。

## 40. system mode semantics

`mode = .system` → `NSApp.appearance = nil` → 跟随系统。系统 Light→Dark / Dark→Light 立即生效（KVO 触发，无需重启）。`effectiveAppearance` 等价 `NSApp.appearance == nil`（§40/§10）。

## 41. light mode semantics

`mode = .light` → `NSApp.appearance = .aqua`。即使系统 Dark，App 仍 Light；系统 Dark→Light / Light→Dark 不影响（effectiveAppearance 保持 aqua，KVO 不触发，Terminal 保持 Light）。

## 42. dark mode semantics

`mode = .dark` → `NSApp.appearance = .darkAqua`。即使系统 Light，App 仍 Dark；系统切换不覆盖（§11/§12）。

## 43. manual-vs-system precedence

`effectiveAppearance = resolved(appearance ?: system)`。`appearance` 非 nil 时**手动优先**，系统变化不覆盖（§16/§17/§22 表）。`system` 模式 = `appearance = nil` = 退回系统。语义清晰、单一公式。

## 44. actor/threading

`NSApp.appearance` 必须 main-thread。`AppAppearanceController` 标 `@MainActor`；`TerminalAppearanceCoordinator` 已 `@MainActor`。`setMode`/`apply` 全 main-thread。无跨线程 race（§33）。

## 45. source-of-truth design

**单一链**（§9）：

```
AppAppearanceMode (UserDefaults)
  → AppAppearanceController
  → NSApp.appearance
  → NSApp.effectiveAppearance
  → [KVO 安全网 + 显式 applyCurrentAppearance() 同步路径]
  → TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()
  → TerminalAppearanceProvider.apply(_:to:) per live TerminalView
```

不引入 `.preferredColorScheme`（§8/§19 SwiftUI 自动跟随 `NSApp.appearance`）。`@Environment(\.colorScheme)`（仅 HighlightRuleRow 色点用）是**只读派生**，非独立 source。

## 46. duplicated-state risks

- ❌ 不并设 `@AppStorage` + controller（两写者，§36）。
- ❌ 不并设 `NSApp.appearance` + `.preferredColorScheme`（两 source，§9/§19）。
- ❌ 不重新引入全局 `lastAppliedMode`（Coordinator P2-2 已移除，§23）。
- ✅ 单 controller、单 UserDefaults key、单 `NSApp.appearance` 写入点。

## 47. test plan（Phase 8B）

1. **AppAppearanceModeTests**：`load` 默认 `.system`、未知 rawValue → `.system`、`save`/`load` round-trip、`nsAppearance`（system→nil、light→aqua、dark→darkAqua）、`CaseIterable` 顺序。
2. **AppAppearanceControllerTests**：注入 `appearanceSetter` 桩 + Coordinator 桩。
   - `setMode(.dark)` → setter 收到 `.darkAqua` + coordinator.applyCurrentAppearance() 被调。
   - `setMode` 同值 no-op（不重复 apply）。
   - `init` 从 UserDefaults load 正确 mode。
   - `apply()` 写 NSApp.appearance + 通知 coordinator。
   - 持久化：`setMode` 后 new controller load 到同值（§43）。
   - 损坏 raw value → `.system`。
3. **TerminalAppearanceManualModeTests**：真实 Local/Remote TerminalView + 注入 controller/coordinator。
   - 注册 2 Local + 1 Remote，`setMode(.dark)` 后全部 `appliedBackgroundRGB == dark.background`（§44）。
   - 新建 Local/Remote 立即 dark（§45）。
   - `setMode(.system)` 后注入 appearance 变化（system Light→Dark）→ 全部更新（§46）。
   - `setMode(.dark)` 后注入系统变化 → Terminal 保持 dark（manual 不被覆盖，§46）。
4. **AppearanceSettingsTests**：Picker 绑定、`accessibilityIdentifier`、无 obsolete key（`testCatalogHasNoObsoleteKeys`，删除 `settings.system_mode` 后通过）。

不依赖 GUI 手测（§39 要求）。新增 live probe（§58）经验确认 5 转换（§19）作为 8B 首步。

## 48. Phase 4 regression

`TerminalAppearanceTests`（`Tests/SSH/TerminalAppearanceTests.swift`，~20 tests）全部不改：palette 值、`contrastRatio`、`mode(for:)`、`apply` 到 Local/Remote、Coordinator register 幂等 / observation 安装时机 / 重试 / register-期间-广播不跳过（P2-2 race）/ appearance 变化广播全部。Phase 8 不改 Coordinator 内部（仅暴露 1 方法）、不改 palette → 全部继续过。

## 49. Phase 6 regression

`TerminalHighlightPalette` / `TerminalHighlightCoordinator` / `TerminalHighlightProviderImpl` 不改。高亮色经 `effectiveAppearance` 重解析（§37）。`HighlightRulesEditor` 的 `@Environment(\.colorScheme)` 跟随 `NSApp.appearance`。Phase 6 Highlight 回归测试全过。

## 50. Phase 7 regression

Phase 7 Right Sidebar（`TerminalRightSidebarView`/`SavedCommandsSidebarView`/`CommandHistorySidebarView`）用系统语义色 → 跟随 `NSApp.appearance` 自动（§27）。命令 Paste/Run/History 与 appearance 无关。Phase 7 测试套件 0 failure 不受影响。

## 51. security

Phase 8 不触碰：Keychain、KnownHost、CredentialService、SSH auth、libssh2、OpenSSL、Entitlements、SwiftTerm fork。无新 fork patch（§59）。`AppAppearanceMode` 仅 UI preference，无敏感数据。

## 52. performance

appearance apply 仅在 (a) 用户 mode 变更 / (b) 系统外观变更（system 模式）时触发。无 per-frame / per-keystroke / per-cell 重算。Coordinator 遍历 live view 数量有限。`TerminalHighlightProviderImpl` 每帧重解析 `effectiveAppearance` 是 Phase 6 既有行为（非 Phase 8 引入）。无 polling（§54）。

## 53. P1 risks

1. **NSApp.appearance KVO 时序**：异步 hop（`Task@MainActor`）+ no-fire 边沿。**缓解**：显式 `applyCurrentAppearance()` 同步路径（§24），不单靠 KVO。设计上 KVO 是安全网非主路径。
2. **启动闪屏**：若 apply 晚于窗口创建。**缓解**：`AppState.init` 顶部 apply（窗口前，§30/§31）。

## 54. P2 risks

1. **obsolete key `settings.system_mode`**：新 UI 后无使用点 → `testCatalogHasNoObsoleteKeys` FAIL。**缓解**：Phase 8B 删除该 key（Phase 7B remediation 教训，§33）。
2. **`HighlightRulesEditor.colorScheme` 与 `NSApp.appearance` 时序**：两者同源（effectiveAppearance）无 divergence；但 Settings 实时切换瞬间色点与 Terminal 高亮须同步刷新——由 Coordinator apply 带动的 `updateFullScreen` 保证。Phase 8B 验证（§47 test 3）。
3. **`AppPreferenceKey.language` 无 `macssh.` 前缀**（既有不一致）：新 key 用 `macssh.appearanceMode`（§26），不回改 `language`（避免无关 churn）。

## 55. P3 risks

1. **live probe 未运行**（§58）：源码 + Apple 文档已确认（§15-§17/§22），但未经验证真实 NSApp KVO 对手动 `appearance` 赋值的 5 转换。Phase 8B 首步补 live probe / 注入式测试。
2. **多窗口未来**（§29）：当前单 `WindowGroup`。Phase 8 v1 = 全 App global appearance（不做 per-window）。未来多窗口若需 per-window，再评估；当前 `NSApp.appearance` 全局足够。

## 56. recommended Phase 8B files

新增：
- `MacSSH/App/AppAppearanceMode.swift`（enum + load/save + nsAppearance，§25）。
- `MacSSH/App/AppAppearanceController.swift`（`@MainActor @Observable`，§28）。
- 测试：`Tests/App/AppAppearanceModeTests.swift`、`Tests/App/AppAppearanceControllerTests.swift`、`Tests/Terminal/TerminalAppearanceManualModeTests.swift`（+ AppearanceSettings 断言并入既有 LocalizationTests）。

修改（最小）：
- `MacSSH/App/AppState.swift`：新增 `appAppearanceController` 属性 + init 顶部创建 apply（§29/§30）。
- `MacSSH/App/AppLanguage.swift`：`AppPreferenceKey` 加 `appearanceMode`（§26）。
- `MacSSH/Services/Terminal/TerminalAppearanceCoordinator.swift`：暴露 `func applyCurrentAppearance()`（public/internal wrapper of private `applyCurrentAppearanceToAllRegisteredViews()`，§24）。
- `MacSSH/Features/Settings/SettingsView.swift`：`LabeledContent`→`Picker(.menu)`（§32）。
- `MacSSH/Resources/Localizable.xcstrings`：+3 key（`settings.appearance.system/light/dark`）、删 `settings.system_mode`（§33）。
- `MacSSH.xcodeproj/project.pbxproj`：注册新文件 + 新测试文件。

不改：SwiftTerm fork、palette、`TerminalAppearanceProvider`、`TerminalHighlightPalette/Coordinator/ProviderImpl`、SSH/Keychain/Entitlements、`MacSSHApp.swift`（AppState 已足够，§29）。

## 57. recommended implementation sequence

1. `AppAppearanceMode` + `AppPreferenceKey.appearanceMode` + `AppAppearanceModeTests`（纯逻辑，无 UI）。
2. `TerminalAppearanceCoordinator.applyCurrentAppearance()` 暴露（1 方法 + 测试）。
3. `AppAppearanceController` + `AppAppearanceControllerTests`（注入 seams）。
4. `AppState` 持有 + init 顶部 apply（launch timing，§30）。
5. `SettingsView` Picker + `Localizable.xcstrings`（3 key + 删 `settings.system_mode`）。
6. `TerminalAppearanceManualModeTests`（existing/new/system-manual 覆盖，§47）。
7. live probe 经验确认 5 转换（§58）。
8. Debug + Release clean build / 全套测试 / 0 production warning（§51）。
9. 阶段报告。

## 58. known limitations

1. **未运行 live GUI probe**：遵守 §57「不修改生产代码 / STOP」。§7/§18/§19 由源码 + Apple `effectiveAppearance` 文档确认（KVO 可观察、设 `appearance` 当 resolved 变化时触发、nil 跟随系统）。Phase 8B 首步建议：最小 live probe（临时测试或手动）经验确认 §22 表 5 转换，尤其 no-fire 边沿（dark→system-when-system-dark、system→dark-when-system-dark）确为「已正确不触发」而非隐藏 bug。
2. KVO 异步 hop（§23）：运行时切换 sub-frame 可接受；启动不靠 KVO（靠 Service init 同步 apply）。
3. `AppPreferenceKey.language` 命名不一致未回改（§54 P2-3，避免无关 churn）。

## 59. 是否需要 SwiftTerm fork change

**不需要。** Phase 8 全程不触碰 SwiftTerm。`NSApp.appearance` 是 AppKit App 级 API；SwiftTerm `TerminalView` 作为 NSView 子类自动经 AppKit effective appearance 传播。终端颜色经 MacSSH 自有 `TerminalAppearanceProvider.apply`（Phase 4 已替换 `configureNativeColors`），不依赖 SwiftTerm 内部 appearance 逻辑。`TerminalView.effectiveAppearance`（AppKit）随 `NSApp.appearance` 实时变化（§18）。无新 fork patch、不改 production pin `771e79f092a26e7fba7af0ab2b09a2bf10213109`。

## 60. 是否建议进入 Phase 8B

**是，建议进入。** 架构清晰、改动最小（1 新 enum + 1 新 controller + 1 暴露方法 + 1 Picker + 3 localizable key）、复用 Phase 4 稳定基础设施（Coordinator KVO + weak registry + `apply`）、无 SwiftTerm/security 触碰、风险可控（P1/P2 均有缓解）。`effectiveAppearance` 单一公式统一 system/light/dark 语义（§43），无双重 source of truth。

## 61. final status

**STOP。** Phase 8A 架构调查完成。未修改生产代码 / SwiftTerm fork / commit / merge / push / 未开始 Phase 8B。等待独立架构验收。

---

## 附录：§55 二十问速答

1. **现有 Terminal Appearance source of truth 是什么？** `NSApp.effectiveAppearance`（Coordinator KVO `\.effectiveAppearance` + `appearanceResolver = { NSApp?.effectiveAppearance }`）。无持久化、无 manual mode（App 永远 `NSApp.appearance == nil`）。
2. **现有 system appearance observation 链？** `NSApp.observe(\.effectiveAppearance, [.new])` → `Task@MainActor` → `applyCurrentAppearanceToAllRegisteredViews()` → `palette(for:)` → `apply(_:to:)` per live view（§8-§10）。
3. **NSApp.appearance 手动设置是否足够控制全 App？** 是。`NSApp.appearance` 是 App 级权威，传播全部 window/view/SwiftUI（§15-§18）。
4. **SwiftUI 是否自动跟随 NSApp.appearance？** 是（`@Environment(\.colorScheme)`/effective appearance 同源派生，§18）。
5. **是否需要 preferredColorScheme？** 不需要（§19，避免双重 source）。
6. **manual app appearance 是否触发现有 Terminal KVO？** 当 `effectiveAppearance` 实际变化时触发；不变时不触发但 Terminal 已正确（§22 表）。
7. **如果不触发，最小修复？** 不需修复（结果正确）。但建议显式 `applyCurrentAppearance()` 同步路径（§24）作为确定性主路径。
8. **existing Local/Remote sessions 如何实时更新？** Coordinator weak 表广播覆盖全部 live view（§13/§38）。
9. **new sessions 如何拿到当前模式？** Service init `applyCurrentAppAppearance` 读 `NSApp.effectiveAppearance`（launch 前已设）+ register（§14/§39）。
10. **Highlight palette 如何同步？** ProviderImpl 每帧重读 `effectiveAppearance`（无缓存）+ Coordinator apply 带动 `updateFullScreen` 重绘（§37）。
11. **AppAppearanceMode 存哪里？** UserDefaults `macssh.appearanceMode`（§26）。
12. **UserDefaults key / fallback 策略？** `macssh.appearanceMode`，未知/损坏 → `.system`（§27）。
13. **controller 应由谁持有？** `AppState` 强持有（§29）。
14. **何时在 launch apply，避免 flash？** `AppState.init` 顶部、SessionManager 创建前、窗口创建前（§30/§31）。
15. **Settings UI 应使用 Menu / Picker / 其他？** 原生 `Picker(.menu)`（§32），与语言 Picker 一致。
16. **system/light/dark 对应哪个 NSAppearance？** system→nil、light→`.aqua`、dark→`.darkAqua`（§25/§15-§17）。
17. **manual mode 下系统切换是否会错误覆盖？** 不会。`appearance` 非 nil 时手动优先，系统变化不改变 `effectiveAppearance`（§43）。
18. **Settings window 是否同步？** 是。Settings 非独立 scene，与主窗口同 `WindowGroup`（§19）。
19. **Right Sidebar 是否自动同步？** 是。系统语义色跟随 `NSApp.appearance`（§27/§50）。
20. **测试架构是什么？** 4 类：Mode/Controller/ManualMode/Settings（含 localization obsolete-key gate），注入 seams，不依赖真实 NSApp KVO（§47）。
