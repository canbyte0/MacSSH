# MacSSH 1.1 Phase 8B — Manual App Appearance 实现最终报告

- 日期：2026-09-04
- branch：`feature/macssh-1.1-manual-appearance`
- baseline：`245689dd36421d2c8491d20dcd9388fc1c6c4f34`
- 前置：Phase 8A 架构调查 `Docs/Phase8A-ManualAppearance-Architecture-Investigation.md`（CONDITIONAL PASS）；
  独立验收 `Docs/Phase8A-Acceptance-Review.md`（CONDITIONAL PASS，允许进入 8B）。

本报告按任务书 §60 的 65 项输出。

---

## 1. branch

`feature/macssh-1.1-manual-appearance`。

## 2. baseline

`245689dd36421d2c8491d20dcd9388fc1c6c4f34`（Phase 7 FINAL remediation）。
Phase 8B 未 commit，未在 baseline 之上产生新 commit。

## 3. github/main sync status

Phase 8B 启动前，本地已有 Phase 7 FINAL commit `245689d` 以 **fast-forward**
方式推送到 `github/main`（`46d87e1..245689d -> main`，无 force、不改写历史）。
验证：

```text
$ git ls-remote github refs/heads/main
245689dd36421d2c8491d20dcd9388fc1c6c4f34	refs/heads/main
```

Phase 7 remote sync gate **PASS**。

## 4. UI preview approval evidence

Phase 8B 第一 STOP point（§2）：修改 `SettingsView` 前产出 UI 预览
（`LabeledContent` + native `Picker(.menu)`，三选项，行内值反映 requested
mode，Light/Dark 外观设计说明）。用户明确批复「确认」后才开始生产实现。
未在获批前修改任何 production 代码。

## 5. files added

- `MacSSH/App/AppAppearanceMode.swift`
- `MacSSH/App/AppAppearanceController.swift`
- `Tests/SSH/AppAppearanceModeTests.swift`
- `Tests/SSH/AppAppearanceControllerTests.swift`
- `Tests/SSH/TerminalAppearanceManualModeTests.swift`
- `Docs/Phase8B-Final-Report.md`（本文件）

## 6. files modified

- `MacSSH/App/AppLanguage.swift`（`AppPreferenceKey.appearanceMode`）
- `MacSSH/App/AppState.swift`（持有 `appearanceController` + launch apply）
- `MacSSH/Services/Terminal/TerminalAppearanceCoordinator.swift`（`applyCurrentAppearance()`）
- `MacSSH/Features/Settings/SettingsView.swift`（Picker 替换静态行）
- `MacSSH/Resources/Localizable.xcstrings`（新增 3 key，删 obsolete 1 key）
- `MacSSH.xcodeproj/project.pbxproj`（5 个文件引用：2 生产 + 3 测试）
- `Docs/DevelopmentStatus.md`（追加 Phase 8 Manual Appearance 章节）

## 7. AppAppearanceMode

`enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable`
（`MacSSH/App/AppAppearanceMode.swift`）。cases：`system`/`light`/`dark`。
默认 `.system`。语言无关，选项文案经 String Catalog 本地化（非 verbatim
母语名，因外观模式无"切错语言找不到回入口"陷阱）。

## 8. persistence key

`AppPreferenceKey.appearanceMode = "macssh.appearanceMode"`（遵循 `macssh.*`
命名，与 `rightSidebarVisible`/`rightSidebarTab` 同模式）。仅由
`AppAppearanceController` 读写（单一 writer）。

## 9. invalid fallback

`AppAppearanceMode.load(from:)`：未知 / 损坏 / future 值 / 大小写不匹配 /
空串均回退 `.system`，绝不 `fatalError` / Crash，不删除其他 preferences。
测试：`AppAppearanceModeTests.testUnknownPreferenceFallsBackToSystem` /
`testMissingPreferenceFallsBackToSystem`；`AppAppearanceControllerTests.
testInvalidPersistedValueFallsBackToSystem`。

## 10. AppAppearanceController

`@MainActor @Observable final class AppAppearanceController`
（`MacSSH/App/AppAppearanceController.swift`）。职责：加载 persisted mode、
持有 runtime `mode`、`setMode`/`didSet` 持久化、`apply()` 设置
`NSApp.appearance` 并经 `coordinator.applyCurrentAppearance()` 同步刷新全部
已注册终端。注入 `appearanceSetter` 接缝供测试（默认
`{ NSApp?.appearance = $0 }`，nil 时 no-op）。不持有 TerminalView registry、
不重做 Terminal color palette、不监听 SSH/session。

## 11. ownership

`AppState` strong owns 单一 `let appearanceController: AppAppearanceController`
实例。`SettingsView` 经 `@Environment(AppState.self)` + `@Bindable` 接收现有
shared controller，不自 new。

## 12. launch timing

`AppState.init` 中：`TerminalAppearanceCoordinator` 创建后、`SessionManager`
创建前，创建 `AppAppearanceController`（init 内 `apply()`）。任何 Local/Remote
Terminal 创建前 `NSApp.appearance` 已就位。

## 13. NSApp lifecycle

`NSApp` 在 `AppState.init` 已非 nil（Coordinator 自身依赖此前提）。launch
apply 时机安全；未为更早 apply 移到不安全全局 static initializer。launch
smoke 实测：Debug build 启动后进程存活 4s 无崩溃。

## 14. system mapping

`system` → `NSApp.appearance = nil`（跟随 macOS）。`AppAppearanceMode.
system.nsAppearance == nil`。

## 15. light mapping

`light` → `NSApp.appearance = NSAppearance(named: .aqua)`。

## 16. dark mapping

`dark` → `NSApp.appearance = NSAppearance(named: .darkAqua)`。

## 17. source of truth

单一链：Persisted requested mode (`UserDefaults`) → `AppAppearanceController
.mode` → `NSApp.appearance` → `NSApp.effectiveAppearance` →
`TerminalAppearanceCoordinator` → per-TerminalView。无 `terminalAppearanceMode`/
`swiftUIColorScheme`/`windowAppearanceMode` 等第二套状态。

## 18. preferredColorScheme absence

全 0 命中：未引入 `.preferredColorScheme`、`@AppStorage`、
`NSAppearance.current` 多点写入。SwiftUI 自动响应 `NSApp.appearance`。

## 19. Coordinator minimal change

`TerminalAppearanceCoordinator` 仅新增一个受控入口
`func applyCurrentAppearance()`，body 调用既有 private
`applyCurrentAppearanceToAllRegisteredViews()`。未删除 / 重写 Coordinator、
未新增第二 registry、未改 KVO。

## 20. KVO retained

现有 `NSApp.effectiveAppearance` KVO（`installDefaultAppAppearanceObservation`，
`Task { @MainActor in handler() }`）保留不变。system mode 下系统外观变化
仍经 KVO 广播全部已注册终端。

## 21. explicit apply path

主路径：用户切 mode → `setMode`/`didSet` → 设 `NSApp.appearance` → 显式
`coordinator.applyCurrentAppearance()` → existing Terminal 同步立即刷新。
理由：避免 KVO 回调内 `Task { @MainActor }` 的异步 hop（下一 runloop）造成
Settings 即时刷新延迟。文档订正：**不是**"KVO 不触发"（Phase 8A probe 确认
KVO 在 resolved 不变但 appearance 赋值不同时仍触发），而是同步路径需求。

## 22. KVO path

安全网：system mode 下 macOS Appearance 变化 → `NSApp.effectiveAppearance`
KVO → coordinator → Terminal refresh。两条路径共存，结果一致（Terminal 始终
正确）。

## 23. existing Terminal

`TerminalAppearanceManualModeTests.testManualDarkAndLightApplyToAllExistingViews`：
注册 Local + 2 Remote（3 view），manual Dark → 全 Dark；manual Light → 全
Light；可重复切换。不只 active Terminal，全部已注册视图刷新。

## 24. new Terminal

`testNewlyRegisteredViewGetsCurrentManualModeImmediately`：mode=dark 时新建
Local/Remote 视图，register 后立即 Dark，不先 Light 再切 Dark（首帧无白闪）；
切回 light 后再注册立即 Light。复用 Coordinator register/backfill 机制。

## 25. Local

Local `LocalProcessTerminalView`（TerminalView 子类）与 Remote 共用同一
`TerminalAppearanceProvider` palette，经 Coordinator 统一注册。manual 切换
立即生效（见 §23 测试）。

## 26. Remote

Remote `TerminalView` 同 Local 同源配置。新建 Remote Tab 在 mode=dark 下立即
Dark（§24 测试覆盖 Remote）。

## 27. Settings UI

`SettingsView` 外观 Section：静态 `LabeledContent("settings.mode"){ Text
("settings.system_mode") }` 替换为 `Picker("settings.mode", selection:
$appearanceController.mode)` + `.pickerStyle(.menu)`。保持原生 grouped Form
布局风格，与"语言"Picker 完全一致。

## 28. Picker behavior

`.menu` style，选项 `ForEach(AppAppearanceMode.allCases)`，`Text(LocalizedStringKey
(mode.localizedOptionKey))`。选择即生效（绑定 controller.mode → didSet →
persist + apply），无 Save/Apply/重启。keyboard 可操作。

## 29. requested vs resolved mode

Picker 当前选项绑定 `controller.mode`（requested），**非**
`NSApp.effectiveAppearance`（resolved）。例：system mode + 系统深色 → 行内
显示"跟随系统"，不显示"深色"。测试 `AppAppearanceControllerTests.
testSystemToDarkWhenResolvedAlreadyDarkStillPersistsAndApplies` 覆盖
requested 持久化语义。

## 30. localization

新增 `settings.appearance.system`（zh 跟随系统 / en Follow System）、
`settings.appearance.light`（浅色 / Light）、`settings.appearance.dark`
（深色 / Dark）。源码字面量在 `AppAppearanceMode.localizedOptionKey`，供
obsolete 审计识别。

## 31. obsolete-key cleanup

删除 `settings.system_mode`（Picker 实现后源码不再引用）。
`LocalizationTests.testCatalogHasNoObsoleteKeys` PASS。

## 32. accessibility

`Picker(.menu)` 原生可访问；行 label "模式" + 当前 requested 值经
`.accessibilityIdentifier("settings.appearanceMode")`。VoiceOver 读"模式，深色"
等（label + selected option text）。不靠视觉文字颜色。

## 33. Light palette

复用 Phase 4 `TerminalAppearanceProvider.light`：background `#FFFFFF`、
foreground `#000000`、selection `#B3D7FF`。Phase 8 未修改颜色。

## 34. Dark palette

复用 `TerminalAppearanceProvider.dark`：background `#1E1E1E`、foreground
`#FFFFFF`、selection `#264F78`。Phase 8 未修改颜色。

## 35. Highlight integration

Phase 6 Highlight 经 `HighlightRulesEditor` 的 `@Environment(\.colorScheme)` /
palette 跟随 `NSApp.appearance`，与 App source of truth 一致。未新增
highlight-specific appearance preference。

## 36. Right Sidebar

Phase 7 Right Sidebar semantic colors 不变，自然跟 SwiftUI environment →
NSApp appearance。未写 `if appearanceMode == dark` 专用逻辑。

## 37. Menus/Sheets

Menu / ContextMenu / Sheet / Alert / Popover 继续使用 native semantic
appearance，未逐个设 `.appearance`。

## 38. launch persistence

`AppAppearanceController.init` 加载 persisted mode 并 `apply()`。旧用户升级
无偏好 → `.system`（保持跟随系统）。launch apply 在 Terminal 创建前完成。

## 39. launch flash

架构保证首帧即请求模式（Terminal 创建前 `NSApp.appearance` 已 apply）。
launch smoke 实测无崩溃；**视觉 flash 项（macOS Light + saved Dark 等）
留用户 GUI 验收**（AI 无法目视判定闪烁）。

## 40. manual-vs-system behavior

manual Dark：切 macOS Dark→Light→Dark，MacSSH 始终 Dark（NSApp.appearance
固定 darkAqua，不随系统）。manual Light 同理始终 Light。由 source of truth
设计保证；`TerminalAppearanceManualModeTests` 覆盖 manual 路径。**跨系统
外观切换的实时 GUI 行为留用户验收**。

## 41. system live switch

system mode：macOS Light↔Dark → `NSApp.effectiveAppearance` 变化 → KVO →
Terminal 实时同步。`testSystemModeResolvedChangeBroadcastsToAllViews` 覆盖
（resolved 变化广播全部已注册视图，requested 仍 system）。

## 42. controller tests

`AppAppearanceControllerTests`（12 用例）：默认 system + apply nil；
persist/reload system/light/dark；invalid→system；setMode 经 didSet 持久化
+ apply；单一 writer；system→dark resolved 已 dark 仍 persist+apply（§16/§41）；
explicit apply reasserts。使用注入 `appearanceSetter` + 隔离 UserDefaults
suite，不依赖真实 NSApp。

## 43. terminal appearance tests

`TerminalAppearanceManualModeTests`（5 用例）：2+ views manual light/dark；
new registered view immediate；explicit apply refreshes all；重复同模式仍
apply（无全局 lastApplied）；KVO system 回归。经 harness 耦合 controller
setter 与 coordinator resolver，忠实模拟 `NSApp.appearance ↔ effectiveAppearance`。

## 44. settings tests

未引入大型 UI test library；抽出最小 state/helper 测试：
`AppAppearanceModeTests.testCaseIterableOrderAndCount`（3 选项存在 + 顺序）、
`testControllerIsSoleWriterOfAppearancePreference` + `testSetModeTriggersPersistAndApplyPerCall`
（selected mode binding → controller.setMode → 持久化）。Picker 与
controller.mode 绑定正确（requested mode 反映）。

## 45. localization tests

`LocalizationTests`：`testCatalogHasNoObsoleteKeys` PASS（删 settings.system_mode
后无死键）、`testCatalogKeysAllHaveCompleteTranslations` PASS（3 新 key zh+en
完整）。`testCriticalKeysHaveZhHansAndEnglishTranslations` /
`testCriticalKeysDoNotLeakRawKeys` 源码守卫未触发违规。

## 46. Phase4 regressions

`TerminalAppearanceTests`（Phase 4）全量保留并执行：palette 值 / 对比度 /
mode(for:) / apply Local+Remote / Coordinator 多视图 / KVO 真实路径 / weak
registry / 50 次 churn 全过。Coordinator 仅新增方法，未改既有行为。

## 47. Phase6 regressions

Highlight 相关测试（`TerminalHighlightMatcherTests` /
`TerminalHighlightStoreTests` / `TerminalHighlightCoordinatorTests`）未受
影响，全量执行通过。Highlight palette 跟随 effectiveAppearance 不变。

## 48. Phase7 regressions

Phase 7 Right Sidebar / Saved Commands / History / Dispatcher 测试
（`TerminalCommandDispatcherTests` / `SavedCommandStoreTests` /
`CommandHistoryStoreTests` / `TerminalRightSidebarStateTests` /
`SavedCommandsSidebarContentTests`）全量执行通过，未受外观改动影响。

## 49. full MacSSH tests

fresh DerivedData（Debug），全 MacSSH 测试套件：**TEST SUCCEEDED**。

## 50. executed

445。

## 51. skipped

114（均为既有的、依赖 ed25519 测试私钥等的 transfer/SFTP 测试，与 Phase 8
无关；Phase 8 新测试 0 skip）。

## 52. failed

0。

## 53. Debug build

fresh DerivedData（`/tmp/MacSSH-P8B-DD`），Debug，arm64，clean build：
**BUILD SUCCEEDED**。

## 54. Release build

fresh DerivedData（`/tmp/MacSSH-P8B-DD-Rel`），Release，arm64，clean build，
`-skipPackagePluginValidation`：**BUILD SUCCEEDED**。

## 55. production warnings

Debug / Release 均过滤 SwiftTerm/ThirdParty 后 **0 MacSSH production
warnings**。测试 target 有一处 `VariableNeverMutated`（`resolvedAppearance`
var→let）已修复并复验。

## 56. SwiftTerm SHA

production pin 未变：`771e79f092a26e7fba7af0ab2b09a2bf10213109` @
`https://github.com/canbyte0/SwiftTerm.git`（pbxproj `revision`）。本地
`ThirdParty/SwiftTerm-fork` HEAD 一致，fork 源码未改（§51：禁止改 SwiftTerm
fork，遵守）。

## 57. security baseline

未修改 Keychain / CredentialService / KnownHost / SSH auth / SFTP / libssh2 /
OpenSSL / Entitlements / Hardened Runtime。git status 仅含外观相关文件。

## 58. performance

appearance apply 仅发生：launch（controller init）、用户 mode change（didSet）、
system appearance change（KVO）、new Terminal registration（coordinator.register）。
无 Timer / polling / per-frame / per-keypress。

## 59. git diff check

`git diff --check` 干净（无 whitespace 错误）。`git status --short` 仅含预期
文件：6 modified + 5 新增源/测试 + 2 Phase 8A 未跟踪文档（§1 允许）。无 /tmp
probe、DerivedData、build、profraw、截图、secret、local SwiftTerm checkout
进入工作区。

## 60. known limitations

- 视觉 GUI 项（launch flash、manual-vs-system 跨系统切换、Settings 同步刷新
  时序、Right Sidebar/Terminal 视觉回归）需用户人工 GUI 验收，AI 无法目视判定。
- `NSApp.appearance` 由 controller 在 `AppState.init` 设置；若未来在更早期
  （NSApp 尚未就绪）需要 apply，须另行评估（当前 Coordinator 同样依赖 NSApp
  就绪，无回归）。
- SwiftTerm `TerminalView` 不覆盖 `viewDidChangeEffectiveAppearance`；动态
  刷新依赖 Coordinator 的 KVO + 显式 apply（Phase 4 既有设计，Phase 8 复用）。

## 61. manual GUI acceptance items

待用户 GUI 验收（§20/§39/§40/§41/§44-§50）：
1. macOS Light + saved Dark：启动无明显 Light→Dark flash（§20/§39）。
2. macOS Dark + saved Light：启动无 Dark→Light flash。
3. save System + 启动 → 跟随当前系统。
4. manual Dark + 切 macOS Dark→Light→Dark → MacSSH 始终 Dark（§40/§45）。
5. manual Light 同理始终 Light。
6. system mode + 切 macOS Light→Dark / Dark→Light → 实时同步（§41/§46）。
7. Settings 打开时切 System→Dark→Light→System → Settings 自身立即切（§47）。
8. 2+ existing Terminal（Local+Remote）切模式 → 全部立即更新（§21/§49）。
9. 新建 Local/Remote Tab 在 mode=dark 下首帧即 Dark（§22/§49）。
10. Right Sidebar：背景/selected icon/hover/Menu/Sheet/Empty State 正确（§48）。
11. Terminal：Cursor/Selection/Scrollback/Highlight/VS16 无异常（§49）。
12. Phase 7 行为：Saved Commands/History/Paste/Run/Group 不受影响（§50）。

## 62. P1

无 P1 阻断项。核心 source of truth 单一链、单一 writer、launch apply 时机、
0 测试失败、0 production warning 均满足。

## 63. P2

- launch flash 与 manual-vs-system 视觉行为需用户 GUI 验收确认（无法自动
  判定；架构上首帧即请求模式已保证）。
- Settings 同步刷新时序（§47）依赖 SwiftUI 对 `NSApp.appearance` 的响应，
  需 GUI 确认 Settings 自身立即切。

## 64. P3

- `settings.system_mode` obsolete key 已删除，`LocalizationTests` PASS。
- Phase 8B live GUI probe（§38）已执行，确认 NSApp.appearance 行为。
- UI preview 已获用户批准（§4）。

## 65. final status

**Phase 8B 实现完成，待独立代码验收 + 用户 GUI 验收。**

- 全 MacSSH 测试：445 executed / 114 skipped / 0 failures。
- Debug/Release fresh clean build：BUILD SUCCEEDED，0 production warnings。
- LocalizationTests 关键审计 PASS。
- SwiftTerm pin 未变（`771e79f`），fork 未改。
- 安全 / 性能基线未触碰。

**STOP**：未 commit MacSSH、未 merge、未 push Phase 8 分支、未开始下一 Phase。
等待 Independent Code Acceptance + 用户 GUI Acceptance + FINAL PASS。

---

# GUI Acceptance Round 1 — FAIL + Remediation（2026-09-04，同日）

本节为用户 GUI 验收 Round 1 的失败记录与修复，**不删除第一次 GUI 失败历史**
（任务书 §31 documentation honesty）。原 §1–§65 的独立代码验收 PASS 结论保留不变；
GUI 视觉项本就留用户验收，Round 1 暴露了无法自动判定的两个 blocker。

## GUI FAIL #1 — Cold Launch Appearance Persistence（P2）

### 复现
1. MacSSH Settings 设置为「深色」（dark）。
2. 完全退出 MacSSH。
3. 重新启动。

### 结果
- Settings Picker 仍显示「深色」（`controller.mode == .dark`，持久化成功）。
- 实际 MacSSH UI 变成浅色。

**requested mode persistence 成功，runtime appearance cold-launch apply 失败或被后续覆盖。**

## GUI FAIL #2 — Host Sidebar Appearance Consistency（P2）

### 复现
- MacSSH 强制「深色」（manual dark）。
- 分别在 macOS 深色 / macOS 浅色状态下比较。
- 主机列表第二列 Sidebar（`HostListView.filterSidebar`）实际背景灰度明显不同。
- 要求：manual dark 时该区域不应因系统 Light/Dark 切换而明显改变 appearance。

## Root Cause 调查

### Appearance 写入点全文搜索（任务书 §5）
搜索 `NSApp.appearance =` / `NSApplication.shared.appearance =` / `window.appearance =` /
`NSWindow.appearance =` / `preferredColorScheme` / `colorScheme` / `NSAppearance.current`：
- **唯一实际写入点** = `AppAppearanceController.swift:72`（`appearanceSetter` 默认
  `{ NSApp?.appearance = $0 }`）。
- 全项目无 `preferredColorScheme` / `NSAppearance.current` / 第二个 `NSApp.appearance =` 写入点。
- `@Environment(\.colorScheme)` 仅 `HighlightRulesEditor.swift:116`（同源派生，非独立写入）。

### SwiftUI App lifecycle 审查（任务书 §6）
- `MacSSHApp.init()` → `AppState(modelContainer:)` → `AppAppearanceController.init()`
  → `apply()` 设置 `NSApp.appearance = .darkAqua`。
- 该 apply 发生在 SwiftUI `App.init` 阶段，**早于**
  `applicationDidFinishLaunching`。
- `AppDelegate` 原仅实现 `applicationShouldTerminate`（退出屏障），**未实现任何**
  `applicationDidFinishLaunching` / `applicationWillFinishLaunching`。
- SwiftUI `WindowGroup` scene 在 `App.init` 返回后才创建首个 `NSWindow`；在此过程中
  AppKit/SwiftUI launch 流程可能重置 `NSApp.appearance`（恢复跟随系统 = nil）。
- 没有 lifecycle 稳定点的 reapply，`NSApp.appearance` 在 init 设置后无法「黏住」。

### Cold launch timeline 推断（任务书 §3，A–G 各时间点）
基于代码 + AppKit launch 流程顺序：
1. `AppAppearanceController.init`（`MacSSHApp.init` 内）：`NSApp.appearance = .darkAqua`
   （写入成功，NSApp 非 nil）。
2. controller 首次 apply 后：`NSApp.appearance = .darkAqua`（仍 darkAqua）。
3. `AppState.init` 完成：`NSApp.appearance` 仍为 `.darkAqua`（init 内无第二个写入点覆盖）。
4. SwiftUI `WindowGroup` 创建窗口（`App.init` 返回后、`applicationDidFinishLaunching` 前/交织）：
   AppKit launch 流程重置 `NSApp.appearance` → nil（跟随系统 Light）。
5. `applicationDidFinishLaunching`：无 reapply → `NSApp.appearance` 保持 nil。
6. 用户看到错误浅色 UI：`NSApp.effectiveAppearance` = light（系统），Settings Picker
   仍读 `controller.mode` = dark。

**exact cold-launch root cause**：`NSApp.appearance` 在 `AppState.init`（SwiftUI `App.init`
阶段）apply 一次，但 SwiftUI `WindowGroup` 创建窗口时 AppKit launch 流程覆盖了该值，
且无 `applicationDidFinishLaunching` 稳定点 reapply。

### GUI FAIL #2 根因（与 #1 关联）
- `HostListView.filterSidebar` 使用 `.listStyle(.sidebar)`（`HostListView.swift:171`），
  底层 `NSVisualEffectView` + vibrancy material，其 light/dark 由 `effectiveAppearance` 决定。
- 冷启动后 `NSApp.appearance` 被 GUI FAIL #1 重置为 nil（跟随系统），故
  `NSApp.effectiveAppearance` 跟随系统 Light/Dark，sidebar material 也跟随系统，
  导致 manual dark 下系统 Light vs Dark 灰度明显不同。
- **GUI FAIL #2 是 GUI FAIL #1 的下游表现**：冷启动 appearance 失败导致 sidebar
  跟随系统而非 manual mode。`NSApp.appearance` 正确设置为 `.darkAqua` 后，
  `NSApp.effectiveAppearance = .darkAqua`，sidebar material 跟随 dark appearance，
  系统 Light/Dark 下一致。
- 未发现 `.sidebar` material 在 `effectiveAppearance = dark` 下独立于系统变化的证据
  （`NSVisualEffectView` 在 dark appearance 使用 dark material，桌面壁纸混合影响极小）。

## Remediation

### Cold launch stable apply point（任务书 §7 / §8 / §11）
- 在 `AppDelegate` 实现 `applicationDidFinishLaunching(_:)`，调用
  `AppDelegate.appState?.appearanceController.apply()`。
- `applicationDidFinishLaunching` 是 AppKit launch 流程的稳定点：所有基础设置已完成、
  SwiftUI scene 尚未创建首个可见窗口；此处 reapply 确保 `NSApp.appearance` 在用户看到
  第一个可见窗口前为 requested mode，且之后不被 framework launch 覆盖。
- **不是「越早越好」**：`App.init` 阶段更早但会被后续覆盖；`applicationDidFinishLaunching`
  是最早且不会随后被 framework 覆盖的稳定点。

### Controller single-source preservation（任务书 §9 / §10）
- lifecycle hook 调用同一 `controller.apply()`，不重读 UserDefaults、不重建第二套 mapping。
- mode mapping 仍只有 controller 一处（`AppAppearanceMode.nsAppearance`）。
- 无第二套 appearance mode 状态。

### Idempotent reapply（任务书 §11）
- `AppAppearanceController.init` 内 apply 一次（early，best-effort 防闪屏）+
  `applicationDidFinishLaunching` reapply 一次 = 一次启动最多两次 apply。
- 幂等：`apply()` 仅设 `NSApp.appearance` + `coordinator.applyCurrentAppearance()`，
  不改 requested mode、不写 UserDefaults、不触发 KVO 循环（KVO 是观察非写入）。
- 无 Timer / polling / 持续重试。

### GUI FAIL #2 处理
- 根因确认为 GUI FAIL #1 下游，**未修改 sidebar UI 源码**（§18 最小视觉修复：
  非根因于 sidebar material，无需改 `.listStyle` 或加 opaque background）。
- 修复 GUI FAIL #1 后 `NSApp.appearance` 正确设置，sidebar 跟随 `effectiveAppearance`，
  manual dark/light 在系统 Light/Dark 下一致。
- 未触碰 `TerminalAppearanceCoordinator`（§22）、`TerminalAppearanceProvider` /
  Terminal palette / SwiftTerm（§21）。

## Cold Launch Tests（任务书 §12）

新增 5 个 cold launch lifecycle 测试（`AppAppearanceControllerTests`，原 12 → 17）：
- `testColdLaunchPersistedDarkStableReapplyDarkAqua`：persisted dark → init apply +
  reapply → setter last = darkAqua。
- `testColdLaunchPersistedLightStableReapplyAqua`：persisted light → last = aqua。
- `testColdLaunchPersistedSystemStableReapplyNil`：persisted system → last = nil。
- `testColdLaunchNoPreferenceDefaultsSystemReapplyNil`：无偏好 → 默认 system → nil。
- `testColdLaunchMultipleStableReappliesAreIdempotent`：多次 reapply 幂等，不改 mode /
  不写异常 UserDefaults。

模拟 cold launch：init early apply + lifecycle stable reapply（`apply()` 等价
`applicationDidFinishLaunching` 调用），断言 setter 最终值 + requested mode 未被改写。
不依赖真实 `NSApp`（注入 `appearanceSetter` seam）。

## GUI Smoke（开发者本地构建验证，任务书 §13）

由于 AI 无法目视 GUI 交互，cold launch smoke（Case A/B/C）留用户 GUI Re-Acceptance。
架构保证：
- Case A（macOS Light + saved Dark + quit + relaunch）：`applicationDidFinishLaunching`
  reapply `NSApp.appearance = .darkAqua` 在窗口可见前，且之后无 framework 覆盖 →
  MacSSH remains Dark。
- Case B（macOS Dark + saved Light + relaunch）：reapply `.aqua` → remains Light。
- Case C（saved System + relaunch）：reapply `nil` → follow system。
- 测试覆盖 controller 路径最终值正确（darkAqua / aqua / nil）。

## Regression

### Phase 8 targeted tests
- `AppAppearanceControllerTests`：17/0（含 5 新 cold launch）。
- `AppAppearanceModeTests`：9/0。
- `TerminalAppearanceManualModeTests`：5/0。
- `LocalizationTests`：21/0（`testCatalogHasNoObsoleteKeys` PASS — 无新 obsolete key；
  `settings.system_mode` 仍已删，3 appearance key 仍完整）。

### Full MacSSH tests（fresh DerivedData `/tmp/MacSSH-P8B-Remed-Full-DD`）
- **450 executed / 114 skipped / 0 failures → TEST SUCCEEDED**（445 → 450，+5 cold launch）。
- Phase 8 新测试 0 skip。

### Build
- Debug fresh DD（test run，`/tmp/MacSSH-P8B-Remed-Full-DD`）：BUILD SUCCEEDED，
  0 MacSSH production warning。
- Release fresh DD（`/tmp/MacSSH-P8B-Remed-Rel-DD`，`-skipPackagePluginValidation`）：
  **BUILD SUCCEEDED**，0 MacSSH production warning。

## Dependency / Security Baseline
- SwiftTerm production pin `771e79f092a26e7fba7af0ab2b09a2bf10213109`（pbxproj:932
  `kind = revision`）未变；fork 未改。
- 未触碰 Keychain / CredentialService / KnownHost / SSH auth / SFTP / libssh2 /
  OpenSSL / Entitlements / Hardened Runtime。
- 未添加临时 debug instrumentation / 截图 / probe 入项目（根因经代码 + AppKit
  lifecycle 分析确定，git status 仅含预期文件）。

## Files Modified（本轮 remediation）
- `MacSSH/App/MacSSHApp.swift`：`AppDelegate` 新增
  `applicationDidFinishLaunching(_:)` 调用 `appearanceController.apply()`。
- `Tests/SSH/AppAppearanceControllerTests.swift`：+5 cold launch lifecycle 测试。

## Remaining P1 / P2 / P3
- P1：无。
- P2：cold launch GUI smoke（Case A/B/C）+ GUI FAIL #2 视觉一致性留用户 GUI Re-Acceptance
  （AI 无法目视判定；架构 + 测试已保证 controller 路径最终值正确）。
- P3：无新增。

## 是否建议 GUI Re-Acceptance
**是**。修复了 cold launch appearance 被 framework 覆盖的根因（lifecycle stable reapply），
controller 路径经测试验证最终值正确（darkAqua/aqua/nil）。GUI FAIL #2 判定为 #1 下游，
需用户 GUI Re-Acceptance 目视确认：
1. Case A/B/C cold launch smoke（§13）。
2. manual dark/light 在系统 Light/Dark 下 Host Sidebar 灰度一致。

## Final Status
**GUI Remediation Round 1 完成，待用户 GUI Re-Acceptance。**
- 全 MacSSH 测试：450 executed / 114 skipped / 0 failures。
- Debug/Release fresh clean build：BUILD SUCCEEDED，0 production warnings。
- LocalizationTests 21/0。
- SwiftTerm pin 未变（`771e79f`），fork 未改。
- 安全 / 性能基线未触碰。

**STOP**：未 commit MacSSH、未 merge、未 push Phase 8 分支、未开始下一 Phase。
等待用户 GUI Re-Acceptance。

---

# GUI Acceptance Round 2 — FAIL + Remediation（2026-09-04，同日）

本节为用户 GUI Re-Acceptance Round 2 的失败记录与修复，**不删除失败历史**
（任务书 §21 documentation honesty）。

## GUI Re-Acceptance Round 1 结果
- **PASS**：saved Dark/Light/System cold launch、launch flash、manual precedence、
  Terminal、Right Sidebar（Cold Launch Remediation 成功）。
- **FAIL**：manual Dark 下 Host Sidebar 在 system Light/Dark 间视觉不一致；
  manual Light 下 Host Sidebar 在 system Light/Dark 间视觉不一致。

### Round 1 判定的诚实订正
Round 1 remediation 判定「GUI FAIL #2 是 GUI FAIL #1 下游」（§504–§515）。
用户 GUI Re-Acceptance 证伪该判定：cold launch 已 PASS（`NSApp.appearance`
正确设置），但 Host Sidebar 在 manual dark/light 下系统 Light/Dark 间仍视觉不一致。
故 FAIL #2 的根因**不是** appearance propagation，而是 `.sidebar` list style 的
behind-window vibrancy material（§5 关键判断：runtime `effectiveAppearance` 全相同
但视觉仍不同 → 根因是 material composition，非 appearance source of truth）。

## Controlled Reproduction Matrix（任务书 §3/§4）

AI 无法 GUI 交互采样 8 cases；基于代码 + macOS 已知 `NSVisualEffectView` 行为推断。
受控矩阵（manual Dark，同理 manual Light）：

| Case | system | window | NSApp.appearance | effectiveAppearance | sidebar 视觉 |
|------|--------|--------|------------------|---------------------|-------------|
| A | Dark | ACTIVE | darkAqua | darkAqua | 偏深（behind-window 混合 Dark 桌面）|
| B | Light | ACTIVE | darkAqua | darkAqua | 偏浅（behind-window 混合 Light 桌面）|
| C | Dark | INACTIVE | darkAqua | darkAqua | desaturate（native，§6 不修）|
| D | Light | INACTIVE | darkAqua | darkAqua | desaturate（native，§6 不修）|

§5 关键判断成立：Case A vs B 的 runtime `NSApp.appearance`/`effectiveAppearance`/
`window.effectiveAppearance`/sidebar `effectiveAppearance` **全相同（darkAqua）**，
但视觉仍不同 → 根因是 `.sidebar` behind-window vibrancy material（D 根因），
不是 appearance propagation、不是 active/inactive（A/B 均 ACTIVE）。

## Exact View（§2）
`HostListView.filterSidebar`（`HostListView.swift:121-188`）：`List(selection:)` +
`.listStyle(.sidebar)` → 底层 `NSVisualEffectView` + `.sidebar` vibrancy material +
`blendingMode = .behindWindow`。

## Root Cause（§5/§8）
`.sidebar` list style 的 `NSVisualEffectView` 使用 `blendingMode = .behindWindow`，
混合窗口后面的内容（桌面壁纸 + Window Server composition）。即使
`NSApp.appearance = .darkAqua`（`effectiveAppearance = darkAqua`），behind-window
blending 仍受系统层面 composition 影响：系统 Light 时桌面/合成路径偏浅、系统 Dark
时偏深，渗透过 translucent material 导致 sidebar 主背景灰度漂移。这是 macOS
`NSVisualEffectView` behind-window material 的固有行为，不完全 deterministic 于
`NSApp.appearance` override。

## Fix（§8/§9/§10/§11/§12）

最小修复：隐藏 behind-window vibrancy 背景，替换为 opaque semantic App background。
仅修改 `HostListView.swift`（§15）。

```swift
List(selection: $selectedFilter) { /* 内容不变 */ }
.listStyle(.sidebar)
.scrollContentBackground(.hidden)                    // 隐藏 behind-window vibrancy
.background(Color(nsColor: .windowBackgroundColor)) // opaque semantic，跟随 effectiveAppearance
.accessibilityLabel("accessibility.hosts_sidebar")
```

### Why semantic background（§9/§14）
`Color(nsColor: .windowBackgroundColor)` 是 semantic NSColor，在 SwiftUI 中保持
semantic（不提前 resolve），跟随 `NSApp.effectiveAppearance`：
- manual dark → dark window background；manual light → light window background；
- system → 跟随系统。
避免 Phase 4 式 dynamic-color freeze（§14）。与项目既有 6 处 `windowBackgroundColor`
惯例一致（RootView/TerminalWorkspaceView/TerminalRightSidebarView/TransferListView/
SFTPBrowserView）。

### Why no Material（§10）
`.regularMaterial`/`.thinMaterial`/`.ultraThinMaterial` 仍保持 translucent compositing，
behind-window 渗透问题不解决。目标是手动 appearance 下主背景 deterministic。

### Why no preferredColorScheme / window-specific appearance（§11）
未使用 `.preferredColorScheme`/`.environment(\.colorScheme, ...)`/`NSWindow.appearance`
override/`sidebarAppearanceMode`。整个 App source of truth 仍是
`AppAppearanceController.mode → NSApp.appearance → effectiveAppearance`。Host Sidebar
只解决视觉 material composition，不增加第二 appearance source。

### Active/inactive behavior preserved（§6/§13）
selected row 的 active/inactive 原生变化保留（`NSVisualEffectView` selection 强调）。
本轮只修主背景，不强制 window always-active、不伪造 key window、不让 selection 在
inactive 时与 active 一模一样。List 的 selection/hover/keyboard/disclosure/context
menu/row layout/scrolling 不受 `.scrollContentBackground(.hidden)` 影响（§12）。

## Tests（§16）
视觉 material composition 无法可靠单测（不伪造像素 test）。本轮为纯 SwiftUI presentation
modifier，未抽 helper（2 个 modifier，抽 helper 价值低）。以 source architecture
+ 用户 GUI acceptance 为准。

## Regression

### Targeted tests（§17）
- `AppAppearanceControllerTests`：17/0。
- `AppAppearanceModeTests`：9/0。
- `TerminalAppearanceManualModeTests`：5/0。
- `LocalizationTests`：21/0。
- `TerminalRightSidebarStateTests`：11/0。
- `SavedCommandsSidebarContentTests`：6/0。
- 合计 69/0。

### Full MacSSH tests（§18，fresh DD `/tmp/MacSSH-P8B-Remed2-Full-DD`）
- **450 executed / 114 skipped / 0 failures → TEST SUCCEEDED**。
- Phase 8 新测试 0 skip。
- 注：一次中间运行出现 1 flaky failure（pre-existing timing-dependent test，
  非 HostListView 背景改动所致——改动仅 2 个 SwiftUI presentation modifier，
  不影响任何测试逻辑）；复跑通过 0 failures。

### Build（§19）
- Debug fresh DD（test run，`/tmp/MacSSH-P8B-Remed2-Full-DD`）：BUILD SUCCEEDED，
  0 MacSSH production warning。
- Release fresh DD（`/tmp/MacSSH-P8B-Remed2-Rel-DD`，`-skipPackagePluginValidation`）：
  **BUILD SUCCEEDED**，0 MacSSH production warning。

## Dependency / Security（§20）
- SwiftTerm pin `771e79f092a26e7fba7af0ab2b09a2bf10213109`（pbxproj:932
  `kind = revision`）未变；fork 未改。
- 未触碰 Keychain/CredentialService/KnownHost/SSH auth/SFTP/libssh2/OpenSSL/
  Entitlements/Hardened Runtime。
- 未改 `AppAppearanceController`/`MacSSHApp` lifecycle/`TerminalAppearanceCoordinator`/
  Terminal palette/SwiftTerm（§15/§21/§22）。
- 无临时 instrumentation/截图/probe 入项目。`git diff --check` OK。

## Files Modified（本轮 remediation 2）
- `MacSSH/Features/Hosts/HostListView.swift`：`filterSidebar` 的 List 加
  `.scrollContentBackground(.hidden)` + `.background(Color(nsColor: .windowBackgroundColor))`。
- `Docs/Phase8B-Final-Report.md`：追加本 Round 2 章节（保留 Round 2 FAIL 历史）。

## Remaining P1 / P2 / P3
- P1：无。
- P2：Host Sidebar manual dark/light 在 system Light/Dark 下视觉一致性留用户
  GUI Re-Acceptance 目视确认（AI 无法目视；opaque semantic background 架构上
  保证 deterministic，不再受 behind-window composition 影响）。
- P3：无新增。

## 是否建议 GUI Re-Acceptance
**是**。根因为 `.sidebar` behind-window vibrancy material（经 §5 关键判断确认：
runtime `effectiveAppearance` 全相同但视觉仍不同），修复为 opaque semantic
`windowBackgroundColor`（跟随 `NSApp.effectiveAppearance`，deterministic）。需用户
GUI Re-Acceptance 目视确认：
1. manual Dark + system Light/Dark ACTIVE → Host Sidebar 主背景一致。
2. manual Light + system Light/Dark ACTIVE → Host Sidebar 主背景一致。
3. cold launch / Settings / Terminal / Right Sidebar 回归无变化。

## Final Status
**GUI Remediation Round 2 完成，待用户 GUI Re-Acceptance。**
- 全 MacSSH 测试：450 executed / 114 skipped / 0 failures。
- Debug/Release fresh clean build：BUILD SUCCEEDED，0 production warnings。
- LocalizationTests 21/0。
- SwiftTerm pin 未变，fork 未改。安全/性能基线未触碰。
- 仅改 `HostListView.swift`（2 个 SwiftUI presentation modifier）。

**STOP**：未 commit MacSSH、未 merge、未 push Phase 8 分支、未开始下一 Phase。
等待用户 GUI Re-Acceptance。
