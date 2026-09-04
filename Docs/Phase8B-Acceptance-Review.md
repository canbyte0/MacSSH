# MacSSH 1.1 Phase 8B — Independent Code Acceptance
# Manual App Appearance

> 角色：Independent Code Reviewer（非 Phase 8A 调查者，非 Phase 8B 开发者）。
> 验证方法：源码逐文件复核 + Git diff/remote 状态独立确认 + fresh DerivedData Debug/Release clean build + 全套测试独立运行 + /tmp AppKit live probe。**未修改任何生产代码 / SwiftTerm fork / commit / merge / push / 未开始下一 Phase。**
> 验证日期：2026-09-04。

---

## 1. Acceptance result

**PASS — 允许进入用户 GUI 验收。**

理由：Phase 8B 的 65 项 Final Report 结论经独立复核全部成立；source of truth 单一链清晰；单一 writer 保证；launch apply 时机安全；fresh DerivedData Debug/Release clean build 均 BUILD SUCCEEDED、0 production warnings；全 MacSSH 测试 **445 executed / 114 skipped / 0 failures**；3 个新测试类 26 用例全执行 0 skip；LocalizationTests 21/0（obsolete key gate PASS）；SwiftTerm pin 未变；安全/性能基线未触碰。

代码路径层面无 P1/P2 阻断项。剩余风险均为 **GUI 视觉验收项**（launch flash、manual-vs-system 跨系统切换、Settings 同步刷新、Right Sidebar/Terminal 视觉回归），AI 无法目视判定，留给用户 GUI 验收。

---

## 2. P1

**无 P1。**

逐项核查：
- **App launch crash**：`AppAppearanceController.init` 只读 UserDefaults + 设 `NSApp.appearance`（经 `appearanceSetter` 默认 `NSApp?.appearance = $0`，nil 时 no-op）+ 调 `coordinator.applyCurrentAppearance()`（registry 空时 no-op）。无同步 I/O、无网络、无 SwiftData、无 fatalError。live probe 确认 `nil/.aqua/.darkAqua` 均安全。
- **appearance controller lifecycle crash**：controller 是纯内存 `@MainActor @Observable`，由 `AppState` strong own。`mode` didSet 不递归（didSet 内 `apply()` 读 `mode` 不写 `mode`）。
- **UserDefaults corruption crash**：`AppAppearanceMode.load(from:)` 对未知/损坏/空串/大小写不匹配值回退 `.system`，不 crash（`testUnknownPreferenceFallsBackToSystem` / `testInvalidPersistedValueFallsBackToSystem` 验证）。
- **Terminal view ownership leak**：Phase 8 只暴露 1 个 Coordinator wrapper 方法（`applyCurrentAppearance()`），不重写 Coordinator、不动 weak `NSHashTable<TerminalView>` registry、不改 `register`。Controller 不持有任何 TerminalView。
- **安全基线破坏**：git diff 仅含 appearance 相关文件（App/AppAppearanceMode.swift, App/AppAppearanceController.swift, App/AppLanguage.swift, App/AppState.swift, Services/Terminal/TerminalAppearanceCoordinator.swift, Features/Settings/SettingsView.swift, Resources/Localizable.xcstrings, pbxproj, Docs）。未触碰 Keychain/CredentialService/KnownHost/SSH/SFTP/libssh2/OpenSSL/Entitlements/Hardened Runtime。

---

## 3. P2

**无 P2。**

逐项核查 P2 候选：
- **Light/Dark Picker 只改 UI 不改 App**：Picker 绑定 `$appearanceController.mode`，经 `@Bindable` → `mode` didSet → `save(to:)` + `apply()` → `appearanceSetter(mode.nsAppearance)` + `coordinator.applyCurrentAppearance()`。完整链路经源码 + 单元测试（`testSetModeLightPersistsAndAppliesAqua` / `testSetModeDarkPersistsAndAppliesDarkAqua`）+ 集成测试（`testManualDarkAndLightApplyToAllExistingViews`）三重确认。
- **Terminal 与 App 模式不一致**：两者同源（`NSApp.effectiveAppearance`）。Controller 设 `NSApp.appearance` → `effectiveAppearance` 解析 → Coordinator apply Terminal palette。无第二套 terminal mode。
- **existing Terminal 不刷新**：`coordinator.applyCurrentAppearance()` 遍历 weak registry 全部 live view（`testManualDarkAndLightApplyToAllExistingViews` 验证 3 views 全刷新）。
- **new Terminal mode 错误**：`NSApp.appearance` 在 `AppState.init` 创建 SessionManager 前 apply → Service init `applyCurrentAppAppearance` 读到正确值（`testNewlyRegisteredViewGetsCurrentManualModeImmediately` 验证新建 view 立即正确）。
- **system 不跟随**：`mode = .system` → `NSApp.appearance = nil` → 跟随系统（live probe 确认）。KVO 保留作安全网（`testSystemModeResolvedChangeBroadcastsToAllViews` 验证）。
- **manual 被系统覆盖**：`NSApp.appearance` 非 nil 时手动优先，`effectiveAppearance = resolved(appearance ?: system)`（live probe 确认 `.aqua`/`.darkAqua` 强制覆盖系统）。
- **requested/persisted mode divergence**：`mode` didSet 同时 `save(to:)` + `apply()`，requested 与 persisted 始终一致（`testControllerIsSoleWriterOfAppearancePreference` 验证）。
- **startup apply 太晚**：`AppState.init` 顺序 = coordinator → controller（init 内 apply）→ SessionManager。窗口未创建（`MacSSHApp.body` 未求值）。code-path 无 flash。
- **Localization tests failure**：21 tests / 0 failures。`testCatalogHasNoObsoleteKeys` PASS（`settings.system_mode` 已删，3 新 key 在 `AppAppearanceMode.localizedOptionKey` 字面量被 obsolete 扫描器识别）。
- **full tests failure**：445/114/0。

---

## 4. P3

- **launch flash GUI 目视**：代码路径保证首帧即请求模式（Terminal 创建前 `NSApp.appearance` 已 apply），但 macOS Light + saved Dark 等实际视觉闪烁需用户 GUI 验收（§80）。
- **manual-vs-system 跨系统切换 GUI**：代码 + probe 确认 AppKit semantics，但实时 GUI 行为留用户验收（§81）。
- **一次 mode change 双 repaint**：controller 显式 apply + KVO 回调（下一 runloop）可能对同一批 view 执行两次 refresh。无循环、无持续重复，harmless（§79）。
- **测试子目录命名**：3 新测试类放 `Tests/SSH/`（与既有 `TerminalAppearanceTests`/`LocalizationTests` 同目录），而非报告 §56 推荐的 `Tests/App/`。属命名约定，非阻塞。

---

## 5. branch

`feature/macssh-1.1-manual-appearance`（`git branch --show-current` 确认）。

## 6. baseline

`245689dd36421d2c8491d20dcd9388fc1c6c4f34`（`git rev-parse HEAD` 确认，Phase 7 FINAL remediation，working tree 含未 commit 的 Phase 8B 改动）。

## 7. github/main

`245689dd36421d2c8491d20dcd9388fc1c6c4f34`（`git ls-remote github refs/heads/main` 确认）。Phase 7 remote sync gate **PASS**（fast-forward push `46d87e1..245689d -> main`，无 force）。

## 8. git diff summary

7 modified + 8 untracked（含 3 Phase 8A/8B docs + 2 新生产源码 + 3 新测试）。

```
 Docs/DevelopmentStatus.md                          | 72 +++++
 MacSSH.xcodeproj/project.pbxproj                   | 20 +++
 MacSSH/App/AppLanguage.swift                       |  2 +
 MacSSH/App/AppState.swift                          | 19 +++
 MacSSH/Features/Settings/SettingsView.swift        | 15 +++-
 MacSSH/Resources/Localizable.xcstrings             | 68 +++++----
 MacSSH/Services/Terminal/TerminalAppearanceCoordinator.swift | 15 +++
 7 files changed, 192 insertions(+), 19 deletions(-)
```

`git diff --check` 干净（无 whitespace 错误）。

## 9. unrelated changes

**无。** 全部修改属于 appearance 范围：AppAppearanceMode/AppAppearanceController/AppState/Coordinator/SettingsView/Localizable/pbxproj/Docs。未触碰 SSH/SFTP/Keychain/KnownHost/CredentialService/SwiftTerm fork/Entitlements。

## 10. files added

- `MacSSH/App/AppAppearanceMode.swift`（68 行，enum + load/save + nsAppearance + localizedOptionKey）
- `MacSSH/App/AppAppearanceController.swift`（100 行，@MainActor @Observable controller）
- `Tests/SSH/AppAppearanceModeTests.swift`（9 用例）
- `Tests/SSH/AppAppearanceControllerTests.swift`（12 用例）
- `Tests/SSH/TerminalAppearanceManualModeTests.swift`（5 用例）
- `Docs/Phase8B-Final-Report.md`（本阶段报告）
- `Docs/Phase8A-ManualAppearance-Architecture-Investigation.md`（8A 调查，未跟踪）
- `Docs/Phase8A-Acceptance-Review.md`（8A 验收，未跟踪）

## 11. files modified

- `MacSSH/App/AppLanguage.swift`：+`AppPreferenceKey.appearanceMode = "macssh.appearanceMode"`
- `MacSSH/App/AppState.swift`：+`appearanceController` 属性 + init 创建 apply（coordinator 后、SessionManager 前）
- `MacSSH/Services/Terminal/TerminalAppearanceCoordinator.swift`：+`func applyCurrentAppearance()`（wrapper of private `applyCurrentAppearanceToAllRegisteredViews()`）
- `MacSSH/Features/Settings/SettingsView.swift`：静态 `LabeledContent` → `Picker(.menu)` 绑定 `$appearanceController.mode`
- `MacSSH/Resources/Localizable.xcstrings`：+3 key（`settings.appearance.system/light/dark`）、删 `settings.system_mode`
- `MacSSH.xcodeproj/project.pbxproj`：注册 5 新文件（2 生产 + 3 测试）
- `Docs/DevelopmentStatus.md`：+Phase 8 Manual Appearance 章节

## 12. AppAppearanceMode

`enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable`（`MacSSH/App/AppAppearanceMode.swift:17`）。cases：`system`/`light`/`dark`。**唯一三种模式**。无 `auto`/`terminalOnly`/`perWindow`/`custom`。

## 13. default mode

`.system`（`:24` `static let defaultMode: AppAppearanceMode = .system`）。`testDefaultModeIsSystem` 验证。

## 14. invalid fallback

`load(from:)`（`:55-62`）：`guard let storedValue = defaults.string(forKey:), let mode = AppAppearanceMode(rawValue: storedValue) else { return .defaultMode }`。未知/损坏/空串/大小写不匹配 → `.system`。`testUnknownPreferenceFallsBackToSystem` / `testMissingPreferenceFallsBackToSystem` / `testInvalidPersistedValueFallsBackToSystem` 验证。不 crash，不删除其他 preferences。

## 15. NSAppearance mapping

`nsAppearance`（`:32-38`）：
- `system` → `nil`（跟随 macOS）
- `light` → `NSAppearance(named: .aqua)`
- `dark` → `NSAppearance(named: .darkAqua)`

`testNsAppearanceMapping` 验证。无 `NSAppearance.current`、无 `preferredColorScheme`、无 window-specific appearance。

## 16. preference key

`AppPreferenceKey.appearanceMode = "macssh.appearanceMode"`（`AppLanguage.swift:53`，集中定义）。全代码库无裸字符串散落（`AppAppearanceMode.load/save` + tests 均引用 `AppPreferenceKey.appearanceMode`）。

## 17. single writer

**只有 `AppAppearanceController` 读写 `appearanceMode` key。** `mode` didSet（`:58`）调 `mode.save(to: userDefaults)`。`setMode`（`:88-90`）经 setter → didSet。无 SettingsView 直接 `UserDefaults.set`、无 `@AppStorage`、无 AppState 再次自行写 preference。`testControllerIsSoleWriterOfAppearancePreference` 验证。

## 18. @AppStorage absence

全 `MacSSH/` 搜索 `@AppStorage` → **0 命中**（唯一出现 = `AppAppearanceController.swift:9` 注释「不存在 ... @AppStorage 的多 source of truth」）。

## 19. preferredColorScheme absence

全 `MacSSH/` 搜索 `preferredColorScheme` → **0 命中**。

## 20. controller architecture

`@MainActor @Observable final class AppAppearanceController`（`AppAppearanceController.swift:35-37`）。职责：
- load mode（init `:78`）
- hold mode（`:53` `var mode`）
- persist mode（didSet `:58` `save(to:)`）
- set NSApp.appearance（`:97` `appearanceSetter(mode.nsAppearance)`）
- explicit terminal coordinator refresh（`:98` `coordinator.applyCurrentAppearance()`）

**不**：自己维护 TerminalView registry（注入 coordinator）、自己决定 Terminal palette（复用 Phase 4）、监听 SSH/session lifecycle。

## 21. MainActor

`@MainActor`（`:35`）。`NSApp.appearance` 与 `TerminalView` 颜色属性均 MainActor。`setMode`/`apply` 全 main-thread。无 background thread 写 `NSApp.appearance`。

## 22. Observation/binding

`@Observable`（`:36`）。`mode` 是 observed property。SettingsView `@Bindable var appearanceController = appState.appearanceController`（`SettingsView.swift:29`）→ `Picker("settings.mode", selection: $appearanceController.mode)`（`:93`）。Picker 改变 → `mode` setter → didSet → persist + apply。**真正经 Controller**，非 local @State snapshot。

## 23. didSet semantics

`mode` didSet（`:54-61`）：`mode.save(to: userDefaults)` → `apply()`。顺序 = persist → set NSApp.appearance → coordinator.applyCurrentAppearance()。无递归（didSet 内不写 `mode`）。无无限 didSet。无重复写回循环。非法 raw fallback 在 `load(from:)` 层处理，不进 didSet（init 赋值不触发 didSet，`:77` 注释）。

## 24. init/load order

init（`:69-83`）：
1. `self.userDefaults = userDefaults`（`:74`）
2. `self.coordinator = coordinator`（`:75`）
3. `self.appearanceSetter = appearanceSetter`（`:76`）
4. `self.mode = AppAppearanceMode.load(from: userDefaults)`（`:78`，init 赋值不触发 didSet）
5. `apply()`（`:82`，显式首次 apply）

先 resolve persisted requested mode，再首次 apply。**不会**先 system 再 dark → 无启动 flash。

## 25. appearanceSetter seam

init 参数 `appearanceSetter: @escaping @MainActor (NSAppearance?) -> Void = { NSApp?.appearance = $0 }`（`:72`）。生产默认 seam 确实写 `NSApp.appearance`（nil 时 optional set no-op）。tests 注入 `{ recorder.record($0) }`（`AppAppearanceControllerTests`）或 `{ holder.value = $0 }`（`TerminalAppearanceManualModeTests`）捕获 requested NSAppearance。test seam 与 production path 是**同一逻辑**（`apply()` 内 `appearanceSetter(mode.nsAppearance)` → `coordinator.applyCurrentAppearance()`），只是 setter 实现不同。

## 26. coordinator injection

Controller init 接收 `coordinator: TerminalAppearanceCoordinator`（`:71`），存为 `private let coordinator`（`:42`）。`AppState.init`（`AppState.swift:110-113`）创建 controller 时注入**已有的** `terminalAppearanceCoordinator`（shared instance）。不创建第二 Coordinator。

## 27. explicit apply order

`apply()`（`:96-99`）：`appearanceSetter(mode.nsAppearance)` → `coordinator.applyCurrentAppearance()`。Terminal apply 发生在 `NSApp.appearance` 更新后。顺序正确。

## 28. KVO retained

`TerminalAppearanceCoordinator` 的 `installDefaultAppAppearanceObservation`（`:139-157`）KVO `app.observe(\.effectiveAppearance, options: [.new])` 保留不变。Phase 8 diff 只新增 `applyCurrentAppearance()` wrapper，未删除/禁用/替换 KVO。

## 29. KVO object/keyPath

observed object = `NSApp`（`NSApplication` 单例），keyPath = `\.effectiveAppearance`（`NSApplication.effectiveAppearance`），options `[.new]`（`TerminalAppearanceCoordinator.swift:148`）。**不是** `appearance`（非 nil appearance 只影响 resolved，KVO 观察 resolved 才能捕获系统切换）。

## 30. KVO callback

callback `Task { @MainActor in handler() }`（`:150-152`）→ `handler()` = `[weak self] in self?.applyCurrentAppearanceToAllRegisteredViews()` → `palette(for: appearanceResolver())` → 遍历 weak 表 `allObjects` → `apply(_:to:)` per live view。MainActor 切回主线程。无新 race（Phase 4 既有设计）。

## 31. coordinator wrapper

`func applyCurrentAppearance()`（`TerminalAppearanceCoordinator.swift:97-99`）body = `applyCurrentAppearanceToAllRegisteredViews()`（private `:163-170` 的受控 wrapper）。**不复制** palette/update logic。单行委托。

## 32. registry

Phase 8 **未新增**第二套 TerminalView registry。仍使用 Phase 4 `private var terminalViews: NSHashTable<TerminalView> = .weakObjects()`（`:43`）。

## 33. weak lifecycle

registered TerminalViews 仍 weak（`NSHashTable<TerminalView>.weakObjects()`）。Appearance Controller 不持有任何 TerminalView（只持有 `coordinator`，coordinator 内部 weak 表）。不造成 Session 泄漏。

## 34. no lastApplied

全代码库搜索 `lastAppliedMode`/`lastAppearance`/global current terminal mode cache → **0 命中**。`applyCurrentAppearanceToAllRegisteredViews()` 无条件无 dedup（Phase 4 P2-2 已移除）。`testRepeatingSameModeStillAppliesToAllViews` 验证重复同模式仍 apply。

## 35. AppState ownership

`AppState` strong owns exactly one `let appearanceController: AppAppearanceController`（`AppState.swift:43`）。SettingsView 经 `@Environment(AppState.self)` + `@Bindable` 接收现有 shared controller（`SettingsView.swift:29`），不自 new。

## 36. AppState init order

`AppState.init`（`AppState.swift:102-114`）：
1. `terminalAppearanceCoordinator = TerminalAppearanceCoordinator()`（`:102`）
2. `appearanceController = AppAppearanceController(userDefaults:coordinator:)`（`:110-113`，init 内 apply）
3. `sessionManager = SessionManager(sshService:)`（后续，创建首个 Local TerminalView）

SessionManager 创建任何 Terminal 前，requested appearance 已 apply。

## 37. NSApp lifecycle safety

`NSApp` 在 `AppState.init` 已非 nil。证据链：SwiftUI `@main App` 运行时先创建 `NSApplication.shared`（NSApp），再调 `App.init()`。`MacSSHApp.init`（`MacSSHApp.swift:61`）创建 `AppState`。Coordinator `installDefaultAppAppearanceObservation` 自身 `guard let app = NSApp`（`:142`）依赖此前提。Phase 8 未把 NSApp 访问提前到更早危险阶段。

## 38. startup requested mode

`AppAppearanceController.init` `:78` `self.mode = AppAppearanceMode.load(from: userDefaults)` → `:82` `apply()`。若 saved = dark，首次 requested mode 就是 dark（`appearanceSetter(.darkAqua)`）。**不会**先 system 再 dark。`testReloadDarkAppliesDarkAqua` 验证。

## 39. Settings hierarchy

`SettingsView.swift:87-101`：`Section("settings.section.appearance")` 内 `Picker("settings.mode", selection:)` + `.pickerStyle(.menu)` + `.accessibilityIdentifier`。保持原生 grouped Form 布局，与「语言」Picker（`:32-40`）风格完全一致。非 3 cards / segmented / custom color selector。

## 40. Picker options

`ForEach(AppAppearanceMode.allCases)` → system / light / dark（`CaseIterable` 顺序 = `[.system, .light, .dark]`，`testCaseIterableOrderAndCount` 验证）。本地化：Follow System / Light / Dark（en），跟随系统 / 浅色 / 深色（zh-Hans）。

## 41. Picker binding

`Picker("settings.mode", selection: $appearanceController.mode)`（`:93`）。get = `controller.mode`，set = `controller.mode =`（经 didSet persist + apply）。真正经过 Controller，非 local @State。

## 42. requested-vs-resolved

Picker 当前选项绑定 `controller.mode`（**requested**），非 `NSApp.effectiveAppearance`（resolved）。例：system mode + 系统深色 → 行内显示「跟随系统」，不显示「深色」。`AppAppearanceController` 注释 `:50-52` 明确。`testSystemToDarkWhenResolvedAlreadyDarkStillPersistsAndApplies` 覆盖 requested 持久化语义。

## 43. localization

`Localizable.xcstrings` diff：+3 key（`settings.appearance.system`/`.light`/`.dark`，en Follow System/Light/Dark，zh-Hans 跟随系统/浅色/深色），-1 key（`settings.system_mode`）。`testLocalizedOptionKeysAreDistinctAndLocalized` / `testLocalizedOptionValuesMatchSpec` 验证三 key 互异、zh+en 非空且不同、不泄漏 raw key。

## 44. obsolete key

`settings.system_mode` 已从 String Catalog 删除（xcstrings diff `-`）。全 `MacSSH/` 搜索 `settings.system_mode` → **0 命中**。`testCatalogHasNoObsoleteKeys` PASS。

## 45. accessibility

`Picker(.menu)` 原生键盘可达。label = `settings.mode`（zh「模式」/ en「Mode」）。`.accessibilityIdentifier("settings.appearanceMode")`。VoiceOver 读 label + 当前 selected option text。不靠视觉颜色区别。

## 46. SwiftUI propagation

全 `MacSSH/` 搜索 `if.*appearanceMode`/`if.*colorScheme ==` → **0 命中 UI 分支**（唯一匹配 = `SettingsView.swift:100` accessibilityIdentifier 字符串 + Controller 注释）。SwiftUI 主要依赖 semantic colors + `NSApp.appearance` 自动传播。无大量 `if mode == dark` 分支。

## 47. Settings propagation

Settings 是 `RootView.selectedWorkspace` 的 `case .settings`（非独立 scene），与主窗口同 `WindowGroup`。设 `NSApp.appearance` 同时覆盖主窗口与 Settings 视图。SwiftUI `@Environment(\.colorScheme)` 由 `effectiveAppearance` 派生 → 自动跟随。无固定 Light UI。

## 48. Right Sidebar

Phase 7 Right Sidebar（`TerminalRightSidebarView`/`SavedCommandsSidebarView`/`CommandHistorySidebarView`）用系统语义色。Phase 8 diff 未触碰这些文件。无 hard-coded white/black 新增。

## 49. Highlight integration

`HighlightRulesEditor.swift:116` `@Environment(\.colorScheme) private var colorScheme`（Phase 6 既有，Phase 8 未改）。`TerminalHighlightProviderImpl.swift:45` 每帧读 `NSApp?.effectiveAppearance`（无缓存）。两者与 `NSApp.appearance` 同源，无独立 persisted mode。

## 50. Light palette

`TerminalAppearanceProvider.light`：bg `#FFFFFF`、fg `#000000`、selection bg `#B3D7FF`。Phase 8 diff 未修改 `TerminalAppearanceProvider.swift`。`TerminalAppearanceTests` 验证 palette 值不变。

## 51. Dark palette

`TerminalAppearanceProvider.dark`：bg `#1E1E1E`、fg `#FFFFFF`、selection bg `#264F78`。Phase 8 未改。`TerminalAppearanceTests` 验证。

## 52. existing Local

`testManualDarkAndLightApplyToAllExistingViews`：注册 Local + 2 Remote（3 view），manual Dark → 全 Dark；manual Light → 全 Light；可重复切换。不只 active Terminal，全部已注册视图刷新。

## 53. existing Remote

同 §52 测试：2 Remote TerminalView 经同一 Coordinator weak registry 更新。非只有 Local。

## 54. new Terminal

`testNewlyRegisteredViewGetsCurrentManualModeImmediately`：mode=dark 时新建 Local/Remote 视图，register 后立即 Dark，不先 Light 再切 Dark。切回 light 后再注册立即 Light。复用 Coordinator register/backfill 机制。

## 55. system KVO regression

`testSystemModeResolvedChangeBroadcastsToAllViews`：system mode 下 resolved Light→Dark→Light，KVO handler 广播全部已注册视图。requested 仍 system。Phase 4 KVO 安全网未退化。

## 56. manual precedence

`mode = .dark` → `NSApp.appearance = .darkAqua`。live probe 确认 `.darkAqua` 强制 Dark（effective = dark），无论系统当前。系统变化不覆盖（effective 保持 darkAqua）。代码层可证明。`testManualDarkAndLightApplyToAllExistingViews` 覆盖 manual 路径。

## 57. manual→system

`dark → system`：`mode = .system` → `NSApp.appearance = nil` → live probe 确认重新跟随系统（`.darkAqua → nil` → eff=light when system=Light）。Terminal explicit apply 立即同步当前系统 resolved mode（`coordinator.applyCurrentAppearance()` 在 didSet 内调用）。

## 58. no-change transition

例：system currently Dark，`system → dark`：resolved effectiveAppearance 仍 darkAqua。`testSystemToDarkWhenResolvedAlreadyDarkStillPersistsAndApplies` 验证：requested mode = dark（UserDefaults = dark），setter 收到 darkAqua，explicit coordinator apply 安全执行。mode 状态正确持久化。

## 59. Mode tests

`AppAppearanceModeTests`：**9 tests, 0 failures**（独立运行确认）。覆盖：3 raw values、default system、CaseIterable 顺序/数量、missing/unknown/empty/大小写 fallback、round-trip persistence、nsAppearance 映射、localizedOptionKey 互异/本地化/不泄漏 raw key、具体文案锁定。

## 60. Controller tests

`AppAppearanceControllerTests`：**12 tests, 0 failures**（独立运行确认，含在 26 total）。覆盖：默认 system + apply nil、persist/reload system/light/dark、invalid→system、setMode 经 didSet 持久化+apply（per call）、单一 writer、system→dark resolved 已 dark 仍 persist+apply、explicit apply reasserts。

## 61. Terminal manual tests

`TerminalAppearanceManualModeTests`：**5 tests, 0 failures**（独立运行确认）。覆盖：2+ views manual light/dark、new registered view immediate、explicit apply refreshes all、重复同模式仍 apply（无 lastApplied）、KVO system 回归。

## 62. test isolation

3 新测试类均用 `UserDefaults(suiteName: "MacSSH.<TestClass>.<UUID>")` 临时 suite 隔离（`AppAppearanceModeTests:137-143` / `AppAppearanceControllerTests:234-240` / `TerminalAppearanceManualModeTests:215-221`）。不污染 `UserDefaults.standard`。

## 63. NSApp cleanup

**测试不触碰真实 `NSApp`**。`AppAppearanceModeTests` 纯 enum 逻辑。`AppAppearanceControllerTests` 注入 `appearanceSetter: { recorder.record($0) }`。`TerminalAppearanceManualModeTests` 注入 `appearanceSetter: { holder.value = $0 }`（共享 holder 模拟 `NSApp.appearance ↔ effectiveAppearance`）。无需 defer/teardown restore NSApp。无测试顺序依赖。

## 64. live probe

`/tmp/macssh_p8b_probe/probe.swift`（未入库，仅 /tmp）独立确认（system=Light）：
```
initial: appearance=nil eff=light kvo=0
nil: eff=light kvo=1           (nil→nil 仍触发，确认 Phase 8A 发现)
aqua: eff=light kvo=1          (resolved 不变但 appearance 赋值变化，KVO 触发)
darkAqua: eff=dark kvo=1       (强制 Dark ✓)
darkAqua->nil: eff=light kvo=1 (manual→system，重新跟随系统 ✓)
```
确认：nil→跟随系统、.aqua→Light、.darkAqua→Dark、.darkAqua→nil→重新跟随系统。KVO 触发频率 ≥ Phase 8A 预测（显式 apply 的真正理由 = 避免异步 hop，非「KVO 不触发」）。

## 65. full MacSSH tests

fresh DerivedData（Debug），全 MacSSH 测试套件：**TEST SUCCEEDED**。

## 66. executed

**445**（`Executed 445 tests, with 114 tests skipped and 0 failures`）。

## 67. skipped

**114**（均为既有 transfer/SFTP 测试依赖 ed25519 测试私钥等，与 Phase 8 无关；Phase 8 新测试 **0 skip**）。

## 68. failed

**0**。

## 69. Phase4 regression

`TerminalAppearanceTests`：**28 tests, 0 failures**（独立运行确认）。覆盖 palette 值/对比度/`mode(for:)`/apply Local+Remote/Coordinator register 幂等/observation 安装/重试/register-期间-广播不跳过/appearance 变化广播。Phase 8 仅新增 wrapper 方法，未改既有行为。

## 70. Phase6 regression

`TerminalHighlightCoordinatorTests` / `TerminalHighlightMatcherTests` / `TerminalHighlightStoreTests` 全量执行通过（全测试套件 445/0 内）。Highlight palette 跟随 effectiveAppearance 不变。

## 71. Phase7 regression

`TerminalCommandDispatcherTests` / `SavedCommandStoreTests` / `CommandHistoryStoreTests` / `TerminalRightSidebarStateTests` / `SwiftDataMigrationTests` 全量执行通过（全测试套件 445/0 内）。Right Sidebar semantic colors 不变。

## 72. Debug build

fresh DerivedData（`/tmp/MacSSH-P8B-Accept-DD`），Debug，arm64，clean build（`-skipPackagePluginValidation`）：**BUILD SUCCEEDED**。

## 73. Release build

fresh DerivedData（`/tmp/MacSSH-P8B-Accept-DD-Rel`），Release，arm64，clean build（`-skipPackagePluginValidation`）：**BUILD SUCCEEDED**。

## 74. production warnings

Debug/Release 均过滤 SwiftTerm/ThirdParty/argument-parser 后 **0 MacSSH production warnings**（`grep "warning:" | grep -v SwiftTerm/ThirdParty/...` 空输出）。

## 75. SwiftTerm SHA

`771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `https://github.com/canbyte0/SwiftTerm.git`（`pbxproj:932` `revision = 771e79f...`）。fresh resolve 确认从 GitHub checkout。

## 76. SwiftTerm unchanged

Phase 8 未修改 Package pin / fork / dependency identity。pbxproj diff 仅新增 5 个文件引用（2 生产 + 3 测试），未触碰 `XCRemoteSwiftPackageReference`。`ThirdParty/SwiftTerm-fork` 未改。

## 77. security baseline

Phase 8 未修改 Keychain / CredentialService / KnownHost / SSH auth / SFTP / libssh2 / OpenSSL / Entitlements / Hardened Runtime。git status 仅含 appearance 相关文件。

## 78. performance

appearance apply 仅发生：launch（controller init）、用户 mode change（didSet）、system appearance change（KVO）、new Terminal registration（coordinator.register）。无 Timer / polling / per-frame / per-keypress。

## 79. duplicate refresh assessment

某些 mode transition（如 system→dark when system=Dark）可能：controller 显式 apply（同步）+ KVO 回调（下一 runloop）对同一批 view 执行两次 refresh。**无循环、无持续重复、无性能问题**。harmless duplicate repaint。**P3/acceptable**。

## 80. launch flash code-path status

**code-path PASS**。`NSApp.appearance` 在 `AppState.init`（窗口创建前，`MacSSHApp.body` 未求值）设置。首个 Local TerminalView 创建时（SessionManager.init 内）`applyCurrentAppAppearance` 读到正确 `effectiveAppearance`。逐案：system 启动无变化；light 启动（系统=Dark）首帧即 Light；dark 启动（系统=Light）首帧即 Dark。**GUI visual pending**（AI 无法目视判定闪烁）。

## 81. manual-vs-system code-path status

**code-path PASS**。live probe 确认 AppKit semantics：`.aqua`/`.darkAqua` 强制覆盖系统；`nil` 跟随系统；`.darkAqua→nil` 重新跟随。代码层 source of truth 单链清晰。**整个 SwiftUI + Terminal 实际视觉留给用户 GUI 验收**。

## 82. git diff check

`git diff --check` 干净（无 whitespace 错误）。`git status --short` 仅含预期文件：7 modified + 8 untracked（3 docs + 2 生产源码 + 3 测试）。无 DerivedData / build / profraw / /tmp probe / 截图 / secret / local SwiftTerm checkout 进入工作区。

## 83. docs accuracy

`Docs/Phase8B-Final-Report.md`：65 项结论经独立复核全部成立。files added/modified、test counts（9/12/5=26）、full tests（445/114/0）、build（Debug+Release SUCCEEDED）、SwiftTerm SHA（`771e79f`）、baseline（`245689d`）均与真实一致。`Docs/DevelopmentStatus.md` Phase 8 章节与真实一致。`TerminalAppearanceTests` 实际 28（报告 §46 称「~20 tests」，轻微低估，不影响结论）。

## 84. remaining P1

**无。**

## 85. remaining P2

**无。**

## 86. remaining P3

1. **launch flash GUI 目视**：code-path PASS，GUI visual pending。
2. **manual-vs-system 跨系统切换 GUI**：code-path PASS，GUI pending。
3. **Settings 同步刷新时序 GUI**：依赖 SwiftUI 对 `NSApp.appearance` 的响应，需 GUI 确认。
4. **Right Sidebar/Terminal 视觉回归 GUI**：semantic colors 跟随，需 GUI 确认。
5. **一次 mode change 双 repaint**（§79）：harmless，无循环。
6. **测试子目录命名**：放 `Tests/SSH/` 而非报告推荐的 `Tests/App/`，属约定。

## 87. 是否允许进入用户 GUI 验收

**允许进入用户 GUI 验收。**

代码路径层面全部 PASS：source of truth 单一链、单一 writer、launch apply 时机、0 测试失败、0 production warning、SwiftTerm pin 未变、安全/性能基线未触碰。剩余风险均为 GUI 视觉项，AI 无法目视判定。

## 88. final status

**PASS — 允许进入用户 GUI 验收。**

- 全 MacSSH 测试：**445 executed / 114 skipped / 0 failures**。
- Phase 8 新测试：9 + 12 + 5 = 26 用例，全执行 0 skip 0 failure。
- LocalizationTests：21/0（obsolete key gate PASS）。
- TerminalAppearanceTests（Phase 4 回归）：28/0。
- Debug/Release fresh clean build：BUILD SUCCEEDED，0 production warnings。
- SwiftTerm pin `771e79f` 未变，fork 未改。
- 安全/性能基线未触碰。
- live probe 确认 NSApp.appearance 语义。

待用户 GUI 验收项（§80/§81/§86）：launch flash、manual-vs-system 跨系统切换、Settings 同步刷新、Right Sidebar/Terminal 视觉回归。

**STOP。** 未修改生产代码 / SwiftTerm fork / commit / merge / push Phase 8 分支 / 未开始下一 Phase。等待用户 GUI Acceptance + FINAL PASS。
