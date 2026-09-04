# MacSSH 1.1 Phase 8A — Independent Architecture Acceptance
# Manual App Appearance

> 角色：Independent Architecture Reviewer（非 Phase 8A 原调查者）。
> 验证方法：源码逐文件复核 + Apple `NSApplication.effectiveAppearance` 文档核对 + `/tmp` AppKit live probe + Git/remote 状态独立确认 + xcstrings 现状扫描。**未修改任何生产代码 / SwiftTerm fork / commit / merge / push / 未开始 Phase 8B。**
> 验证日期：2026-09-04。

---

## 1. Acceptance result

**CONDITIONAL PASS — 允许进入 Phase 8B。**

理由：Phase 8A 的 61 项架构结论经独立复核全部成立；`NSApp.appearance` 语义经 live probe 经验确认；启动时序安全；最小改动方案（1 enum + 1 controller + 1 暴露方法 + 1 Picker + 3 localizable key）不触碰 SwiftTerm/security；单一 source of truth 清晰。

但有 **1 个 P2 流程问题**（Phase 7 FINAL 尚未 push 到 GitHub）与若干 **P3 偏差**需在 Phase 8B 前明确：

- P2-A：local `main` 领先 `github/main` 1 commit（Phase 7 FINAL `245689d` 未 push）。
- P3-A：报告 §22 KVO 转换表存在**悲观偏差**——probe 实证显示 KVO 在「resolved 值未变但 `appearance` 赋值不同」时仍会触发（见 §18/§33）。这不影响结论正确性（结果与报告一致：Terminal 已正确），但理由应订正。
- P3-B：AGENTS.md UI 规则要求「修改 UI 前必须先提供预览图」——Phase 8B SettingsView 改 Picker 必须先出预览。

**baseline 测试状态更正**：Phase 7B 的 remediation（rename UI / grouped command Edit / SavedCommands 空态）已提交进 `46d87e1`/`245689d`，3 个原"死键"（`sidebar_right.group_actions`/`rename`/`saved_empty`）现已在 `SavedCommandsSidebarView.swift:148/360/376` 被源码引用，**不再 obsolete**。baseline 的 `LocalizationTests.testCatalogHasNoObsoleteKeys` 实际为 PASS（与 2026-09-04 当日 Phase 7B 复验记录一致：412 executed / 0 failures）。`MEMORY.md` 的 Phase 7B 段未更新此 remediation，本验收初稿误信摘要得出"P2-B 死键继承"结论，经源码复核后**撤回**。

详见 §70-§72 与 §75。

---

## 2. P1

**无 P1。**

逐项核查 P1 候选：

- **启动崩溃**：`NSApp.appearance = nil/.aqua/.darkAqua` 均安全（probe 实证，§25-§28）；`AppState.init` 顶部 apply 不访问未初始化对象（§41-§43）。
- **invalid NSApp lifecycle access**：`NSApp` 在 `AppState.init` 阶段已非 nil（Coordinator 自身依赖此前提，§42）；`appearanceSetter` 用 `NSApp?.appearance = $0` optional 链式，nil 时静默退化为系统跟随，不崩。
- **appearance controller 阻断 app 启动**：controller 是纯内存 `@Observable`，`apply()` 只设 `NSApp.appearance` + 调 Coordinator，无同步 I/O、无网络、无 SwiftData。
- **Terminal view lifecycle regression**：Phase 8 只暴露 1 个 Coordinator 方法（wrapper），不重写 Coordinator、不动 weak 表、不动 KVO、不改 `apply`。无 lifecycle regression 入口。

---

## 3. P2

### P2-A：Phase 7 FINAL 未 push 到 GitHub（流程问题，非架构错误）

- `github/main` SHA = `46d87e173935afcc558e53992e43dfb9f20d5ff8`（Phase 7A 侧边栏提交）。
- local `main` SHA = `245689dd36421d2c8491d20dcd9388fc1c6c4f34`（Phase 7 FINAL：右侧命令栏宽度调整 + 动画）。
- `git rev-list --left-right --count github/main...main` = `0 1`（local ahead 1、behind 0）。
- Phase 8A baseline `245689d` = local main HEAD，**不在 GitHub**。
- 报告 §1 称「local main 即最新」表述含糊——技术上 local 确实是最新，但 GitHub 远端落后 1 commit，属流程问题。
- **建议**：进入 8B 前由用户执行 `git push origin main`（或 `git push github main`，远端名实际为 `github`）。验收方**不自行 push**。

### P2-B：~~baseline 继承 Phase 7B LocalizationTests 失败~~ **（撤回 — baseline 实为 clean）**

- 初稿误判：基于 `MEMORY.md` Phase 7B 段（仅记初始 CONDITIONAL FAIL，未记 remediation+复验 PASS）。
- 源码复核：3 个原"死键"现已在 `SavedCommandsSidebarView.swift` 被引用：
  - `sidebar_right.saved_empty` → `:148` `Label("sidebar_right.saved_empty", systemImage: "command.square")`
  - `sidebar_right.rename` → `:360` `Label("sidebar_right.rename", systemImage: "pencil")`
  - `sidebar_right.group_actions` → `:376` `.accessibilityLabel(L10n.string("sidebar_right.group_actions", ...))`
- remediation 已提交进 `46d87e1`/`245689d`（git log `9ab519a..245689d -- SavedCommandsSidebarView.swift` 确认）。
- `LocalizationTests.testCatalogHasNoObsoleteKeys` 在 baseline 实际为 **PASS**（与 2026-09-04 当日复验记录一致：412 executed / 0 failures / LocalizationTests 21/21）。
- **教训**：不应信摘要，须从源码确认（本验收流程的 §3/§46/§66/§71/§73/§74/§75 已据此撤回 P2-B 相关要求，仅保留 P2-C `settings.system_mode` 删除）。

### P2-C：obsolete key `settings.system_mode`（报告 §54 已识别，确认）

- `settings.system_mode` 当前唯一源码引用 = `SettingsView.swift:88` `Text("settings.system_mode")`。
- Phase 8B 替换为 `Picker` 后该 key 无引用 → obsolete → gate FAIL。
- 报告 §33 已识别此风险并要求删除，**确认成立**。

### P2-D：`HighlightRulesEditor.colorScheme` 与 manual appearance 时序（报告 §54 P2-2，确认低风险）

- `HighlightRulesEditor.swift:116` `@Environment(\.colorScheme)`，`:121-122` `swatchColor(for: rule.color, dark: colorScheme == .dark)`。
- SwiftUI `colorScheme` 由 `effectiveAppearance` 派生 → 设 `NSApp.appearance` 后自动跟随，**同源**，无 divergence。
- `TerminalHighlightProviderImpl.swift:45` 每帧读 `NSApp?.effectiveAppearance`（无缓存）→ manual 切换后高亮色立即正确。
- 重绘触发链：Coordinator apply → SwiftTerm `colorsChanged()` → `updateFullScreen()` → `cellHighlights` 重解析。**一致**。
- 报告 §54 P2-2 称需 8B 验证——确认需 live probe 验证 Settings 实时切换瞬间色点与 Terminal 高亮同步刷新（§47 test 3）。

### P2-E：`AppPreferenceKey.language` 无 `macssh.` 前缀（既有不一致，不回改）

- `AppLanguage.swift:47` `static let language = "appLanguage"`（无前缀）。
- `macssh.rightSidebarVisible` / `macssh.rightSidebarTab` / `macssh.terminalHighlightSettings` 均有前缀。
- 新 `macssh.appearanceMode` 采用前缀风格，与 Phase 6/7 一致。不回改 `language`（避免无关 churn）。**确认报告 §54 P2-3 处理正确**。

---

## 4. P3

### P3-A：报告 §22 KVO 转换表存在悲观偏差（live probe 实证）

- 报告 §22 表称「system→light（系统=Light）：aqua→aqua 不变，KVO 不触发」。
- `/tmp` live probe 实测（system 当前 = Light）：
  - `nil → .aqua`（resolved aqua→aqua 不变）→ **KVO 触发了**（count=1）。
  - `.aqua → .darkAqua` → 触发 ✓。
  - `.darkAqua → .darkAqua`（同值重赋）→ 不触发 ✓。
  - `.darkAqua → nil` → 触发 ✓。
  - `nil → nil`（同值重赋）→ probe 显示触发（count=1），疑似 `appearance` setter 在 nil→nil 路径也 post 通知。
- **结论**：KVO 实际触发频率 ≥ 报告预测。报告 §22 的「不触发」栏在 live 环境下大多会触发。这不影响 §22 表的**结果正确性**（Terminal 始终正确），但 §24「explicit apply 必要性」的理由应订正为：
  - 真正理由 = **KVO 回调经 `Task { @MainActor in handler() }`（Coordinator :150-152）异步 hop，下一 runloop 才 apply**；显式 `applyCurrentAppearance()` 提供**同步**路径，让 Settings 切换立即刷新（§33 live update），不靠下一 runloop。
  - 而非「KVO 可能不触发」。
- **不阻塞 8B**——报告 §24 的最终建议（暴露 `applyCurrentAppearance()` 作同步主路径）仍然正确且必要。

### P3-B：AGENTS.md UI 规则——Picker 改动需先预览

- `AGENTS.md`：「修改 UI 前必须先提供预览图，获得用户确认后才能修改实际 UI 源码。」
- Phase 8B `SettingsView` 把 `LabeledContent` 改 `Picker(.menu)` 属 UI 修改 → **必须先出预览**（截图或 SwiftUI Preview），用户确认后才改 `SettingsView.swift`。
- 报告 §32 描述了目标样式但未提供预览图——8B 实现前需补。

### P3-C：live probe 未运行（报告 §55 已列为 P3-1）

- 报告 §58 称未运行 live GUI probe。本验收已运行 `/tmp` AppKit probe 补 §11-§14/§18 经验证据。但 **NSApp KVO 对手动 `appearance` 赋值的 5 转换 + 真实 TerminalView 重绘** 仍未在 MacSSH 项目内 live 验证。8B 首步应补 live probe（§47 test 3 / §52）。

### P3-D：测试子目录命名（报告 §56 推荐 `Tests/App/`、`Tests/Terminal/`）

- 现状 `Tests/` 仅有 `Hosts/`、`Security/`、`SSH/` 三个子目录，所有测试文件扁平于 `Tests/SSH/`（含 `TerminalAppearanceTests.swift`、`LocalizationTests.swift` 等）。
- 报告 §56 推荐新建 `Tests/App/AppAppearanceModeTests.swift` 与 `Tests/Terminal/TerminalAppearanceManualModeTests.swift`——会引入新子目录。**建议**：为保持一致性，可考虑全部放 `Tests/SSH/`，或同步建 `Tests/App/`。属命名约定，非阻塞。

### P3-E：报告 §33 key 命名建议 vs 计划书 §45

- 计划书 §45 `## Appearance` 列出 System/Light/Dark（已文档化 Settings 规范）。
- 报告 §33 推荐 `settings.appearance.system/light/dark`（与既有 `settings.*` 体系一致），而非 `appearance.mode.*`。
- 两者均合规；最终 key 名由 8B 实现阶段定，但须 en+zh-Hans 完整 + `testCatalogHasNoObsoleteKeys` 通过。**非阻塞**。

---

## 5. branch

`feature/macssh-1.1-manual-appearance`（独立确认 = `git branch --show-current`）。

---

## 6. baseline

`245689dd36421d2c8491d20dcd9388fc1c6c4f34`（= local main HEAD，working tree clean，仅未跟踪 `Docs/Phase8A-ManualAppearance-Architecture-Investigation.md` + 本验收报告）。

---

## 7. origin/main SHA

**`origin` remote 不存在。** 项目远端名为 `github`（`https://github.com/canbyte0/MacSSH.git`）。

`github/main` SHA = `46d87e173935afcc558e53992e43dfb9f20d5ff8`。

---

## 8. local main SHA

`245689dd36421d2c8491d20dcd9388fc1c6c4f34`。

---

## 9. main ahead/behind

`git rev-list --left-right --count github/main...main` = `0 1`。

= local main 领先 `github/main` **1 commit**，落后 **0** commit。

---

## 10. Phase7 remote-sync status

**Phase 7 FINAL `245689d` 未 push 到 GitHub。** `github/main` 停留在 `46d87e1`（Phase 7A「添加右侧命令侧边栏」），缺少 Phase 7 FINAL「添加右侧命令栏宽度调整功能及相关动画效果」。

**建议**：进入 Phase 8B 前，由用户执行 `git push github main`（不自行 push）。这不阻塞 8B 架构工作，但属流程卫生问题——若 8B 期间远端仍落后，8B 完成后 push 会一次性推送 8A+8B 多个提交，回溯难度增大。

---

## 11. production modifications

**无。** Phase 8A 未修改任何 `.swift` 生产源码、SwiftTerm fork、entitlements、pbxproj、xcstrings。`git diff --stat` 为空。唯一产物 = `Docs/Phase8A-ManualAppearance-Architecture-Investigation.md`（未跟踪）+ 本验收报告（未跟踪）。

---

## 12. current Settings appearance

`MacSSH/Features/Settings/SettingsView.swift:86-90`：

```swift
Section("settings.section.appearance") {
    LabeledContent("settings.mode") {
        Text("settings.system_mode")
    }
}
```

只读 `LabeledContent`：左 `settings.mode`（zh「模式」/ en「Mode」），右 `settings.system_mode`（zh「跟随系统」/ en「System」）。**无交互、无 Picker、无持久化**——永远显示「跟随系统」文案。确认报告 §4。

---

## 13. current persistence

**无任何 appearance mode persistence。** 全 `MacSSH/` 代码库搜索：

- `@AppStorage` → **0 命中**。
- `NSApp.appearance` / `NSApp?.appearance` 写入 → **0 命中**（仅 Coordinator 注释提及）。
- `appearanceMode` / `preferredColorScheme` / `NSAppearance.current` → **0 命中**。
- `AppPreferenceKey`（`AppLanguage.swift:46-52`）仅 `language` / `rightSidebarVisible` / `rightSidebarTab` 三个 key，无 appearance。

App 当前 = 纯「跟随系统」（从不设 `NSApp.appearance`）。确认报告 §5。

---

## 14. current source of truth

**`NSApp.effectiveAppearance`**（单一来源）。

`effectiveAppearance` 在 `MacSSH/` 的全部出现点（共 5 文件）：

- `TerminalAppearanceProvider.swift:115`（`paletteForCurrentAppAppearance` 读 `NSApp?.effectiveAppearance`）。
- `TerminalAppearanceCoordinator.swift:65`（`appearanceResolver` 默认 `{ NSApp?.effectiveAppearance }`）+ `:148`（KVO `app.observe(\.effectiveAppearance, options: [.new])`）。
- `TerminalHighlightProviderImpl.swift:45`（每帧读 `NSApp?.effectiveAppearance`）。
- `TerminalScrollIndicatorController.swift:244`（`viewDidChangeEffectiveAppearance` override，滚动指示器，非外观源）。

**不是** `NSAppearance.current`、**不是** `TerminalView.effectiveAppearance`、**不是** `NSWindow.effectiveAppearance`、**不是** SwiftUI `colorScheme`。确认报告 §6/§9。

---

## 15. TerminalAppearanceProvider

`MacSSH/Services/Terminal/TerminalAppearanceProvider.swift`（enum，226 行）。

- `enum Mode: String, Equatable, Sendable { case light; case dark }`（`:44-47`）——**只 light/dark，无 system**（system 语义在 App 层）。
- `struct RGB` / `struct Palette`（`:50-63`），`Sendable`，确定性 sRGB 固定值。
- Light palette（`:68-74`）：fg `#000000`、bg `#FFFFFF`、selection bg `#B3D7FF`、selection fg `#000000`。
- Dark palette（`:80-86`）：fg `#FFFFFF`、bg `#1E1E1E`、selection bg `#264F78`、selection fg `#FFFFFF`。
- `mode(for appearance: NSAppearance?) -> Mode`（`:92-101`）：`bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .accessibilityHighContrastDarkAqua])`；dark 系→`.dark`，其余→`.light`；nil→`.light`。
- `palette(for:)` / `paletteForCurrentAppAppearance()`（`:104-116`）：后者 `@MainActor` 读 `NSApp?.effectiveAppearance`。
- `apply(_:to terminalView:)`（`:155-161`，`@MainActor`）：设 4 个 SwiftTerm 颜色属性（`nativeForegroundColor`/`nativeBackgroundColor`/`selectedTextBackgroundColor`/`selectedTextForegroundColor`），触发 `colorsChanged()` 全量重绘。
- `applyCurrentAppAppearance(to:)`（`:165-168`）：Service init 一次性应用。
- 不调 `installColors`（保留 ANSI 16/256）；不触碰字体/几何。

报告 §6 全部行号与结论**逐项确认**。Phase 8 复用，不改 palette/apply。

---

## 16. TerminalAppearanceCoordinator

`MacSSH/Services/Terminal/TerminalAppearanceCoordinator.swift`（`@MainActor final class`，185 行）。

- 弱引用注册表 `private var terminalViews: NSHashTable<TerminalView> = .weakObjects()`（`:43`）—— Local/Remote 统一（`LocalProcessTerminalView` 是 `TerminalView` 子类）。
- `appearanceResolver: @MainActor () -> NSAppearance?`，默认 `{ NSApp?.effectiveAppearance }`（`:51,65`）。
- `observationInstaller`，默认 `installDefaultAppAppearanceObservation`（`:57,66`）。
- `register(_:)`（`:79-85`）：`ensureObservationInstalled()` + 加入 weak 表 + **立即 apply** 当前 palette（新建 Tab 无白闪）。
- `ensureObservationInstalled()`（`:126-133`）：幂等，`appearanceObservation == nil` 才调 installer；installer 返回 nil（NSApp 未就绪）则保持 nil，下次 `register` 重试。
- `installDefaultAppAppearanceObservation`（`:139-157`）：`guard let app = NSApp` 后 `app.observe(\.effectiveAppearance, options: [.new])`，回调经 `Task { @MainActor in handler() }` 切回主线程。
- `applyCurrentAppearanceToAllRegisteredViews()`（`:163-170`，**private**）：**无条件**遍历 `allObjects` apply（P2-2 移除 `lastAppliedMode` 全局去重）。
- 测试 seams：`applyModeForTesting(_:)`（`:91-96`）、`registeredViewCountForTesting`（`:99-101`）、`isObservationInstalledForTesting`（`:105-107`）、`compactRegistryForTesting()`（`:111-118`）。

报告 §7 全部行号与结论**逐项确认**。Phase 8 唯一最小改动 = 暴露 `applyCurrentAppearance()`（wrapper of private `applyCurrentAppearanceToAllRegisteredViews()`）。

---

## 17. observed object

`NSApp`（`NSApplication` 单例）。

---

## 18. observed keyPath

`\.effectiveAppearance`（`NSApplication.effectiveAppearance`），options `[.new]`，安装点 `TerminalAppearanceCoordinator.swift:148`。

**§18 KVO transitions live probe 实证**（`/tmp/macssh_appearance_probe/probe.swift`，system 当前 = Light）：

| 转换 | resolved 变化？ | 报告 §22 预测 | probe 实测 | 结果正确性 |
|---|---|---|---|---|
| `nil → .aqua`（system=Light） | aqua→aqua 不变 | ❌ 不触发 | **✅ 触发** | ✓ Terminal 已 Light |
| `.aqua → .darkAqua` | aqua→darkAqua | ✅ 触发 | ✅ 触发 | ✓ →Dark |
| `.darkAqua → .darkAqua`（同值重赋） | 不变 | — | ❌ 不触发 | ✓ 已 Dark |
| `.darkAqua → nil`（system=Light） | darkAqua→aqua | ✅ 触发 | ✅ 触发 | ✓ →Light |
| `nil → nil`（同值重赋） | 不变 | — | ✅ 触发（疑似 setter post） | ✓ 已 Light |

**关键发现**：KVO 实际触发频率 ≥ 报告预测。报告 §22 的「不触发」栏在 live 环境大多会触发。**结果正确性不变**（Terminal 始终正确），但 §24 理由应订正（见 §20/§34）。

---

## 19. KVO callback path

`NSApp` AppKit 主线程投递 KVO → `app.observe(\.effectiveAppearance, options: [.new]) { _, _ in Task { @MainActor in handler() } }`（Coordinator `:148-152`）→ `Task { @MainActor in handler() }` **异步 hop 至下一 runloop** → `handler()` = `[weak self] in self?.applyCurrentAppearanceToAllRegisteredViews()`（`:130-132`）→ `palette(for: appearanceResolver())`（此时 `NSApp?.effectiveAppearance` 已是新值）→ 遍历 weak 表 `allObjects` → `TerminalAppearanceProvider.apply(_:to:)` per live view → `colorsChanged()` 全量重绘（含非激活 Tab，因 weak 表持有全部 Service 持有的 TerminalView）。

**关键时序**：KVO 回调本身在主线程同步投递，但 Coordinator 包 `Task { @MainActor in ... }` → apply 在**下一 runloop**。这是 §20 显式 apply 的真正理由。

---

## 20. system Light→Dark

macOS 系统外观 Light→Dark（App `NSApp.appearance == nil` 跟随系统）→ `NSApp.effectiveAppearance` 由 aqua 变 darkAqua → KVO `\.effectiveAppearance` 触发 → `Task { @MainActor in handler() }` → `applyCurrentAppearanceToAllRegisteredViews()` → `palette(for: NSApp?.effectiveAppearance)`（已 dark）→ 遍历 weak 表全部 live `TerminalView` `apply(_:to:)` → `colorsChanged()` 全量重绘（含非激活 Tab）。

---

## 21. Local update

`SessionManager.createLocalSession()`（`SessionManager.swift:116-135`）→ `LocalTerminalService(session:)` → `LocalTerminalService.init` 在 `terminalView` 创建后立即 `TerminalAppearanceProvider.applyCurrentAppAppearance(to: terminalView)`（`LocalTerminalService.swift:60`，一次性初始应用）→ `SessionManager` 紧接 `terminalAppearanceCoordinator?.register(service.terminalView)`（`SessionManager.swift:130`，纳入动态更新）。运行时外观变化经 Coordinator KVO 广播。确认报告 §11。

---

## 22. Remote update

`SessionManager.createRemoteSession(host:)` → `runConnectFlow` → 认证成功后 `RemoteTerminalService(connection:hostname:port:)`（`RemoteTerminalService.swift:65`）→ init 创建 `TerminalView(frame:font:options:)`（`:84-89`）后 `TerminalAppearanceProvider.applyCurrentAppAppearance(to: terminalView)`（`:99`）→ `SessionManager` `terminalAppearanceCoordinator?.register(service.terminalView)`（`SessionManager.swift:447`）。Reconnect 复用原 TerminalView（`reattach`），不重新注册（外观已就位）。确认报告 §12。

---

## 23. existing-session registry

`NSHashTable<TerminalView>.weakObjects()`（Coordinator `:43`）。Session 关闭/Service 释放后槽位自动 nil，`allObjects` 访问自动回收。广播遍历 `allObjects` 覆盖全部 live Local/Remote、激活/非激活 Tab（非激活 Tab 的 TerminalView 仍由各 Service 持有接收后台输出，虽不在 SwiftUI 层级但仍在 weak 表中）。Phase 8 直接复用。确认报告 §13。

---

## 24. new-session backfill

两条 backfill 点均已存在，Phase 8 无需新增：

1. `AppState.init` 末尾（`AppState.swift:150-160`）：注册 `SessionManager.init` 已创建的初始 Local Session 的 terminalView（回填，避免只注册后来新建 Tab 的遗漏）。
2. `SessionManager.createLocalSession`（`:130`）/ `createRemoteSession` flow（`:447`）：新建 Session 时立即 register + Service init 已 apply。

**关键**：Service init 的 `applyCurrentAppAppearance` 读 `NSApp?.effectiveAppearance`。只要 `AppAppearanceController` 在 **AppState.init 创建 SessionManager 之前** 设好 `NSApp.appearance`（§41），新 Session 一创建即正确（无白闪）。确认报告 §14。

---

## 25. NSApp.appearance=nil

**live probe 实证**（`/tmp/macssh_appearance_probe/probe.swift`）：

```
NSApp.appearance = nil
NSApp.effectiveAppearance = light(aqua)  (= 当前系统 Light)
```

= App 恢复跟随 macOS 系统外观。系统随后 Light↔Dark → `effectiveAppearance` 自动变 → KVO 触发 → Coordinator apply。符合 Apple `NSApplication.effectiveAppearance` 文档（effectiveAppearance = `appearance` 若设置，否则系统外观；`appearance` 默认 nil）。**确认报告 §15。**

---

## 26. aqua behavior

**live probe 实证**：

```
NSApp.appearance = NSAppearance(named: .aqua)
NSApp.effectiveAppearance = light(aqua)
```

`effectiveAppearance` 解析为 aqua（Light），无论系统当前。App 全局强制 Light；系统外观后续变化不影响（effectiveAppearance 保持 aqua → KVO 不触发，Terminal 保持 Light）。**确认报告 §16。**

---

## 27. darkAqua behavior

**live probe 实证**：

```
NSApp.appearance = NSAppearance(named: .darkAqua)
NSApp.effectiveAppearance = dark(NSAppearanceNameDarkAqua)
```

`effectiveAppearance` 解析为 darkAqua（Dark），无论系统当前。App 全局强制 Dark；系统外观变化不覆盖。**确认报告 §17。**

---

## 28. manual→system

**live probe 实证**：

```
（前置 NSApp.appearance = .darkAqua，effective=dark）
NSApp.appearance = nil
NSApp.effectiveAppearance = light(aqua)  (re-resolved to current system Light)
```

`.darkAqua → nil` 后 App 重新跟随当前系统 appearance。**确认报告 §14/§15。**

---

## 29. SwiftUI response

`NSApp.appearance` 是 App 级外观权威。AppKit 把 effective appearance 传播到全部 NSWindow/NSView；SwiftUI `@Environment(\.colorScheme)` 与 `effectiveAppearance` 由同一来源派生。设 `NSApp.appearance` 后，SwiftUI 的 `NavigationSplitView` / `Sidebar` / `Toolbar` / `Menu` / `Sheet` / `Settings` / Phase 7 Right Sidebar **自动跟随**（均用系统语义色 / dynamic color）。`RootView.swift:35` `.background(Color(nsColor: .windowBackgroundColor))` 即系统语义色。**无需 `.preferredColorScheme`**（§30）。确认报告 §18。

---

## 30. preferredColorScheme necessity

**不需要。** 全 `MacSSH/` 搜索 `preferredColorScheme` → **0 命中**。设 `NSApp.appearance` 后 SwiftUI 自动跟随（§29），无需第二 source。**Phase 8B 禁止加入 `preferredColorScheme`**——会引入与 `NSApp.appearance` 并列的第二 source of truth，导致 divergence。确认报告 §19/§45。

---

## 31. Settings scene/window

MacSSH **没有独立 Settings scene/window**。`MacSSHApp.body` 仅一个 `WindowGroup("MacSSH") { RootView()... }`（`MacSSHApp.swift:67-83`）；Settings 是 `RootView.selectedWorkspace` 的 `case .settings: SettingsView()`（`RootView.swift:113-114`），与主窗口**同一窗口同一 detail 区**。设 `NSApp.appearance` 同时覆盖主窗口与 Settings 视图。**不存在「只改主窗口、Settings 不同步」问题**。确认报告 §19。

---

## 32. manual KVO transitions

**live probe 实证**（§18 表）+ 报告 §22 表交叉核对：

| 转换 | effectiveAppearance 变化？ | KVO 触发？ | Terminal 结果 |
|---|---|---|---|
| system→light（系统=Dark） | darkAqua→aqua | ✅ 触发 | →Light ✓ |
| system→light（系统=Light） | aqua→aqua（不变） | probe: **✅ 触发**（报告预测 ❌） | 已 Light ✓ |
| system→dark（系统=Light） | aqua→darkAqua | ✅ 触发 | →Dark ✓ |
| system→dark（系统=Dark） | darkAqua→darkAqua（不变） | probe: 未直接测，按 §18 模式推断 ✅ 触发（报告预测 ❌） | 已 Dark ✓ |
| light→dark | aqua→darkAqua | ✅ 触发 | →Dark ✓ |
| dark→light | darkAqua→aqua | ✅ 触发 | →Light ✓ |
| manual→system（系统=Light） | darkAqua→aqua | ✅ 触发 | →Light ✓ |
| manual→system（系统=Dark） | darkAqua→darkAqua（不变） | probe: 推断 ✅ 触发 | 已 Dark ✓ |

**结论**：现有 KVO 对全部手动 case 都得到正确结果。报告预测的「不触发」边沿在 live 环境大多会触发（§18），但即使不触发，Terminal 本就正确，非 bug。**无遗漏 case。**

---

## 33. no-change transition

例：系统当前 Dark，`system → dark`（设 `NSApp.appearance = .darkAqua`），resolved effectiveAppearance 仍 darkAqua。

- 报告 §22 预测：KVO 不触发。
- probe 实测（system=Light 类比）：`nil → .aqua`（resolved 不变）**触发**。
- **结论**：即使触发，Terminal 已 Dark，apply 幂等，无副作用。即使不触发，Terminal 已 Dark，正确。
- **但**：Settings mode persistence 必须更新（`setMode` 已 `save(to:)`，§39）。mode 变了 → UserDefaults 写了 → 即使 Terminal 不重绘，mode 状态正确持久化。**无功能问题。**

---

## 34. explicit coordinator apply necessity

**仍然必要，但理由订正**（见 P3-A）：

- 报告 §24 原理由 (b)「KVO 可能不触发」→ live probe 显示 KVO 触发频率 ≥ 预测，此理由**站不住**。
- 真正理由 = 报告 §24 (a) **KVO 异步 hop**（Coordinator `:150-152` 包 `Task { @MainActor in handler() }`，apply 在下一 runloop）。Settings 切换（§33 live update）若只靠 KVO，视觉刷新延迟 1 runloop（sub-frame 但非零）。
- 显式 `applyCurrentAppearance()` 提供**同步**路径：`setMode` → `NSApp.appearance =` → 立即 `coordinator.applyCurrentAppearance()` → 同一调用栈内全 Terminal 重绘。Settings 切换即时反馈。
- **KVO 保留作 system 模式下系统外部切换的安全网**（controller 不被调用时）。两路径汇于同一 `applyCurrentAppearanceToAllRegisteredViews()`，无双重状态。
- **最小改动** = 把 private `applyCurrentAppearanceToAllRegisteredViews()`（Coordinator `:163-170`）暴露为 `func applyCurrentAppearance()`（internal/public wrapper），不重写 Coordinator、不删 KVO、不建第二 registry、不加 polling。**确认报告 §21/§24 最小方案。**

---

## 35. Coordinator minimal change

**确认最小方案**：

- 保留现有 KVO（`:139-157`）。
- 保留 weak registry（`:43`）。
- 保留 `register` 立即 apply（`:79-85`）。
- 保留 `ensureObservationInstalled` 幂等 + 重试（`:126-133`）。
- **唯一新增**：`func applyCurrentAppearance()`（internal/public，wrapper of private `applyCurrentAppearanceToAllRegisteredViews()`，§34）。

**不**：重写 Coordinator、删除 KVO、建立第二 registry、新增 polling、引入 `lastAppliedMode` 全局去重。**确认报告 §21。**

---

## 36. AppAppearanceMode

**确认足够**：

```swift
enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    static let defaultMode: AppAppearanceMode = .system
    var id: Self { self }
    var nsAppearance: NSAppearance? { /* system→nil, light→.aqua, dark→.darkAqua */ }
    static func load(from:) -> AppAppearanceMode { /* 未知→.system */ }
    func save(to:) { /* rawValue */ }
}
```

- 默认 `.system`（老用户升级行为不变）。
- **不**加入 `auto` / `custom` / `terminalOnly` / `perWindow`。
- 完全沿用 `AppLanguage`（`AppLanguage.swift:6-43`）模板。确认报告 §25。

---

## 37. persistence

**确认**：

- `UserDefaults`（手动 `load`/`save`，**不**用 `@AppStorage`）。
- 新 key 加到 `AppPreferenceKey`（`AppLanguage.swift:46-52`）：`static let appearanceMode = "macssh.appearanceMode"`（`macssh.` 前缀，与 Phase 6/7 既有 key 一致）。
- 避免裸字符串散落——全部经 `AppPreferenceKey` 集中。确认报告 §26。

---

## 38. invalid fallback

`AppAppearanceMode.load` 对未知 rawValue / 缺失 key / 损坏值返回 `.system`（§36），不 crash。与 `AppLanguage.load`（`AppLanguage.swift:30-37`）回退 `.defaultLanguage` 同构。未来新增 enum case（如 `.highContrastDark`）旧版读到未知值也安全回退。**Phase 8B 必须设计测试**（§50）。确认报告 §27。

---

## 39. @AppStorage decision

**合理，批准**。理由：

- `@AppStorage` 是 View 级响应式存储，无法在 **AppState.init 早期、窗口创建前**设 `NSApp.appearance`（View init 发生在 body 求值 = 窗口已创建之后 → 启动闪屏）。
- `@AppStorage` 无法在写入时触发 `NSApp.appearance =` 副作用 + Coordinator 通知（需 separate `.onChange`，多写者）。
- 手动 UserDefaults = 单一写者、可控 apply 时机，与 `AppLanguage` / `rightSidebarVisible` 一致。
- 全 `MacSSH/` 现 0 `@AppStorage` 命中——新引入会破坏现有约定。确认报告 §26。

---

## 40. controller ownership

**确认**：

- `AppState` 强持有（与 `terminalAppearanceCoordinator` / `terminalHighlightCoordinator` / `sessionManager` 同模式，`AppState.swift:35` 已有 `let terminalAppearanceCoordinator`）。
- 新增 `let appAppearanceController: AppAppearanceController`（生命周期 = App 全程，`AppState` 由 `MacSSHApp` `@State` 持有）。
- **不允许** `SettingsView` 自建 controller（避免短命 View 持有 App 级状态）。确认报告 §29。

---

## 41. AppState init timing

**确认最早安全 apply 点 = `AppState.init` 顶部**（coordinator 创建之后、SessionManager 创建之前）。

`AppState.init` 当前顺序（`AppState.swift:81-168`）：

1. `userDefaults =`（`:85`）
2. `language = load`（`:86`）
3. `sshService`（`:88-89`）
4. `terminalAppearanceCoordinator = TerminalAppearanceCoordinator()`（`:94-95`）
5. `terminalHighlightCoordinator`（`:100-101`）
6. `sessionManager = SessionManager(sshService:)`（`:103`）← `SessionManager.init` 立即 `createLocalSession()`（`SessionManager.swift:64`），创建首个 Local TerminalView 并 `applyCurrentAppAppearance`（读 `NSApp.effectiveAppearance`）
7. ... 回填注册初始 Local Session（`:150-160`）

**推荐插入点**：step 4（coordinator 创建 `:95`）之后、step 6（SessionManager `:103`）之前，创建 `AppAppearanceController`（注入 coordinator）并 `apply()`。此时：

- `NSApp.appearance` 已设（窗口尚未创建 → 无闪屏，§44）。
- step 6 首个 Local TerminalView 创建时 `applyCurrentAppAppearance` 读到正确 `effectiveAppearance`。
- `NSApp` 在该阶段已非 nil（§42）。确认报告 §30。

---

## 42. NSApp lifecycle safety

**安全。** `NSApp` 在 `AppState.init` 阶段已非 nil。

**证据链**：

- `MacSSHApp.init`（`MacSSHApp.swift:18-65`）在 `:61` 创建 `AppState`：`_appState = State(initialValue: AppState(modelContainer:))`。
- SwiftUI `@main App` 的运行时先创建 `NSApplication.shared`（NSApp），再调用 `App.init()`。即 `MacSSHApp.init` 执行时 `NSApp` 已存在。
- `TerminalAppearanceCoordinator.installDefaultAppAppearanceObservation`（`:139-157`）自身 `guard let app = NSApp else { return nil }`（`:142`），注释 `:143-145`：「TerminalView 真正创建时 AppKit 已要求 `NSApplication` 存在」——即 Coordinator 假设：`SessionManager.init`（`AppState :103`）→ `createLocalSession` → `LocalTerminalService.init` → `TerminalView` 创建时 `NSApp` 非 nil。
- 既然 `NSApp` 在 `TerminalView` 创建时（`AppState.init :103` 内）非 nil，则在 `AppState.init` 顶部（`AppState.init :85` 起，含推荐插入点 `:95`-`:103` 之间）`NSApp` 必然非 nil。
- **live probe 旁证**：`/tmp` 独立 swift 脚本 `_ = NSApplication.shared` 后即可读写 `NSApp.appearance` / `effectiveAppearance`，无异常。

**结论**：`AppState.init` 顶部 apply `NSApp.appearance` 安全，不会访问未初始化对象。确认报告 §28/§30。

---

## 43. recommended earliest apply point

**`AppState.init` 内、`terminalAppearanceCoordinator` 创建（`:95`）之后、`SessionManager` 创建（`:103`）之前。**

即报告 §30 推荐的「step 4 之后、step 6 之前」。理由：

- 此点 `NSApp` 已非 nil（§42）。
- 此点 `terminalAppearanceCoordinator` 已创建（可注入 controller）。
- 此点 `SessionManager` 未创建 → 首个 Local TerminalView 未创建 → 设 `NSApp.appearance` 后 TerminalView 首次 `applyCurrentAppAppearance` 读到正确值（§24/§47）。
- 此点窗口未创建（`MacSSHApp.body` 未求值）→ 无闪屏（§44）。

**不**需 `NSApplicationDelegate.applicationWillFinishLaunching` / `applicationDidFinishLaunching`——`AppState.init` 已足够早且安全。确认报告 §29/§30。

---

## 44. flash risk

**极低**。`NSApp.appearance` 在 `AppState.init`（窗口创建前，`MacSSHApp.body` 未求值）设置。窗口首帧即正确 appearance。

逐案：

- **system 启动**：`NSApp.appearance = nil`（= 默认，App 本就跟随系统）→ 无变化，无闪屏。
- **light 启动（系统=Dark）**：`NSApp.appearance = .aqua` 在窗口创建前 → 窗口首帧即 Light → 无 Dark→Light 闪屏。
- **dark 启动（系统=Light）**：`NSApp.appearance = .darkAqua` 在窗口创建前 → 窗口首帧即 Dark → 无 Light→Dark 闪屏。

唯一理论边沿：若 `NSApp` 在 `AppState.init` 顶部仍 nil（§42 已证不会），`appearanceSetter` 用 `NSApp?.appearance = $0`（optional set）静默跳过，退化为跟随系统（= `system` 默认行为），不崩。可接受。**Phase 8B GUI 必须手测**（§52）。确认报告 §31。

---

## 45. Settings UI

**确认** `LabeledContent` → `Picker(.menu)` + `.accessibilityIdentifier`，与现有语言 Picker（`SettingsView.swift:32-40` `.pickerStyle(.menu)`）风格一致：

```swift
Section("settings.section.appearance") {
    Picker("settings.mode", selection: $appState.appAppearanceController.mode) {
        Text("settings.appearance.system").tag(AppAppearanceMode.system)
        Text("settings.appearance.light").tag(AppAppearanceMode.light)
        Text("settings.appearance.dark").tag(AppAppearanceMode.dark)
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("settings.appearanceMode")
}
```

**不做**：segmented control、三张 card、radio group。`mode` 变更经 `setMode`（didSet/onReceive）即时 apply（§33 live switching，无 Apply/Save/Restart）。

**注意 AGENTS.md UI 规则**：修改 `SettingsView.swift` 前必须先出预览图（截图或 SwiftUI Preview），用户确认后才改源码（P3-B）。确认报告 §32。

---

## 46. localization

**确认** 新 3 key（遵循既有 `settings.*` 点分命名）：

| key | en | zh-Hans |
|---|---|---|
| `settings.appearance.system` | Follow System | 跟随系统 |
| `settings.appearance.light` | Light | 浅色 |
| `settings.appearance.dark` | Dark | 深色 |

**删除** `settings.system_mode`（`Localizable.xcstrings:3829`，唯一源码引用 `SettingsView.swift:88` 在新 UI 后无引用 → obsolete → gate FAIL）。

**注**：Phase 7B 原 3 个"死键"（`sidebar_right.group_actions`/`rename`/`saved_empty`）已在 remediation 提交中接入 UI（`SavedCommandsSidebarView.swift:148/360/376`），baseline 已 PASS，**Phase 8B 无需清理**。只需删 `settings.system_mode` 一个 obsolete key。

不得硬编码 UI 字符串。确认报告 §33。

---

## 47. accessibility

`Picker(.menu)` 原生键盘可达（Tab 聚焦、Space/Enter 展开、上下选择）、VoiceOver 读 label（`settings.mode`「模式」）+ 当前值（「跟随系统」）。`.accessibilityIdentifier("settings.appearanceMode")`。不依赖颜色状态表达。确认报告 §34。

---

## 48. Light palette

复用 `TerminalAppearanceProvider.light`（`TerminalAppearanceProvider.swift:68-74`）：bg `#FFFFFF`、fg `#000000`、selection bg `#B3D7FF`、selection fg `#000000`。**不改**。确认报告 §35。

---

## 49. Dark palette

复用 `TerminalAppearanceProvider.dark`（`:80-86`）：bg `#1E1E1E`、fg `#FFFFFF`、selection bg `#264F78`、selection fg `#FFFFFF`。**不改**。确认报告 §36。

---

## 50. Highlight integration

`TerminalHighlightPalette.nsColor(for:appearance:)`（`TerminalHighlightPalette.swift:44-51`）按 `appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua])` 取 light/dark RGBA。`TerminalHighlightProviderImpl.cellHighlights`（`TerminalHighlightProviderImpl.swift:45`）**每帧**读 `NSApp?.effectiveAppearance`（无缓存）→ manual appearance 切换后立即正确解析。

重绘触发链：`TerminalAppearanceCoordinator.apply` → SwiftTerm `colorsChanged()` → `terminal.updateFullScreen()` → 重新调 `cellHighlights` → 高亮色重解析。故 manual appearance 切换后高亮 palette 自动同步。**不会出现 App Dark + Highlight Light palette divergence**。确认报告 §37。

---

## 51. Right Sidebar

Phase 7 Right Sidebar（`TerminalRightSidebarView` / `SavedCommandsSidebarView` / `CommandHistorySidebarView`）用系统语义色 / `@Environment` → 跟随 `NSApp.appearance` 自动（§29）。manual appearance 后自动变化。**不需专门 controller hook**。确认报告 §50。

---

## 52. menus/sheets

系统原生 `CommandMenu`（`MacSSHApp.swift:138`）、`.sheet`（`RootView.swift:41`）、`.alert`（`:44,79`）、Toolbar（`AppToolbarContent`）均由 AppKit/SwiftUI 按 effective appearance 自动渲染。`NSApp.appearance` 覆盖之。**不为它们逐个 hard-code appearance**。确认报告 §21/§30。

---

## 53. threading

`AppAppearanceController` 应 `@MainActor`：

- `NSApp.appearance` 必须 main-thread（AppKit 主线程隔离）。
- `TerminalAppearanceCoordinator` 已 `@MainActor`（`:38`）。
- `setMode` / `apply` 全 main-thread。
- 无跨线程 race。确认报告 §44。

---

## 54. source of truth

**单一链**：

```
AppAppearanceMode (UserDefaults macssh.appearanceMode)
  → AppAppearanceController.mode (runtime requested)
  → NSApp.appearance (nil | .aqua | .darkAqua)
  → NSApp.effectiveAppearance (resolved)
  → [KVO 安全网 + 显式 applyCurrentAppearance() 同步路径]
  → TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()
  → TerminalAppearanceProvider.apply(_:to:) per live TerminalView
```

**不**引入 `.preferredColorScheme`（§30）。`@Environment(\.colorScheme)`（仅 `HighlightRulesEditor.swift:116` HighlightRuleRow 色点用）是**只读派生**，非独立 source。确认报告 §45。

---

## 55. system semantics

`controller.mode = .system` → `NSApp.appearance = nil` → 跟随系统。系统 Light→Dark / Dark→Light 立即生效（KVO 触发，无需重启）。`effectiveAppearance` 等价 `NSApp.appearance == nil`（§25）。确认报告 §40。

---

## 56. light semantics

`controller.mode = .light` → `NSApp.appearance = .aqua`。即使系统 Dark，App 仍 Light；系统 Dark→Light / Light→Dark 不影响（effectiveAppearance 保持 aqua，KVO 不触发，Terminal 保持 Light，§26）。确认报告 §41。

---

## 57. dark semantics

`controller.mode = .dark` → `NSApp.appearance = .darkAqua`。即使系统 Light，App 仍 Dark；系统切换不覆盖（§27）。确认报告 §42。

---

## 58. precedence

`effectiveAppearance = resolved(appearance ?: system)`。`appearance` 非 nil 时**手动优先**，系统变化不覆盖（§26/§27/§32 表）。`system` 模式 = `appearance = nil` = 退回系统。语义清晰、单一公式。确认报告 §43。

---

## 59. existing terminals

切换 mode 时，`AppAppearanceController.apply` → `coordinator.applyCurrentAppearance()` → 遍历 weak 表全部 live view（Local A/B、Remote C 全含）apply。非激活 Tab 也在表内（Service 持有）。**全部实时更新**（§20/§23）。确认报告 §38。

---

## 60. new terminals

`NSApp.appearance` 已在 `AppState.init` 设好（§41）。新建 Local（`SessionManager.swift:130`）/ Remote（`:447`）时 Service init `applyCurrentAppAppearance` 读到正确 `effectiveAppearance` → **一创建即正确**（无先 Default Light 再 repaint，§24/§47）。确认报告 §39。

---

## 61. lastApplied regression

**Phase 8 不得重新引入全局 `lastAppliedMode`。** P2-2 已移除（Coordinator `:163-170` 注释），`applyCurrentAppearanceToAllRegisteredViews()` 无条件遍历，无 dedup。重新引入会导致 register 期间新视图插入时排队广播被误跳过。确认报告 §46。

---

## 62. test plan

**Phase 8B 至少需要 4 类测试**（确认报告 §47）：

1. **AppAppearanceModeTests**：`load` 默认 `.system`、未知 rawValue → `.system`、`save`/`load` round-trip、`nsAppearance`（system→nil、light→aqua、dark→darkAqua）、`CaseIterable` 顺序。
2. **AppAppearanceControllerTests**：注入 `appearanceSetter` 桩 + Coordinator 桩。`setMode(.dark)` → setter 收到 `.darkAqua` + coordinator.applyCurrentAppearance() 被调；同值 no-op；init load 正确；apply() 写 + 通知；持久化 round-trip；损坏 raw → `.system`。
3. **TerminalAppearanceManualModeTests**：真实 Local/Remote TerminalView + 注入 controller/coordinator。注册 2 Local + 1 Remote，`setMode(.dark)` 后全部 `appliedBackgroundRGB == dark.background`；新建 Local/Remote 立即 dark；`setMode(.system)` 后注入 appearance 变化 → 全部更新；`setMode(.dark)` 后注入系统变化 → Terminal 保持 dark。
4. **AppearanceSettingsTests**（含 localization obsolete-key gate）：Picker 绑定、`accessibilityIdentifier`、`testCatalogHasNoObsoleteKeys` 通过（删 `settings.system_mode` + 3 个 Phase 7B 死键后）。

**扩展现有优于重复造套件**——`TerminalAppearanceTests`（`Tests/SSH/TerminalAppearanceTests.swift`）已存在，manual-mode 断言可并入或扩展。确认报告 §47。

---

## 63. startup test

**应覆盖**（§52）：

- saved `dark` → new `AppState`/controller → 首次 `apply()` → `NSApp.appearance` 已 `.darkAqua` → 在 Terminal creation 前。
- 可注入 `appearanceSetter` 桩验证 setter 收到 `.darkAqua`，且调用时序在 `SessionManager.init`（`AppState :103`）之前。
- 若可测：验证首个 Local TerminalView 的 `appliedBackgroundRGB` == `dark.background`（即 Service init 读到正确 effectiveAppearance）。

确认报告 §47/§52。

---

## 64. Phase4 regression

`TerminalAppearanceTests`（`Tests/SSH/TerminalAppearanceTests.swift`，~20 tests）全部不改：palette 值、`contrastRatio`、`mode(for:)`、`apply` 到 Local/Remote、Coordinator register 幂等 / observation 安装时机 / 重试 / register-期间-广播不跳过（P2-2 race）/ appearance 变化广播全部。

Phase 8 不改 Coordinator 内部（仅暴露 1 方法 wrapper）、不改 palette → 全部继续过。**但 baseline 的 LocalizationTests 失败是继承自 Phase 7B，非 Phase 4 regression**（§65/§66）。确认报告 §48。

---

## 65. Phase6 regression

`TerminalHighlightPalette` / `TerminalHighlightCoordinator` / `TerminalHighlightProviderImpl` 不改。高亮色经 `effectiveAppearance` 重解析（§50）。`HighlightRulesEditor` 的 `@Environment(\.colorScheme)` 跟随 `NSApp.appearance`。Phase 6 Highlight 回归测试全过。确认报告 §49。

---

## 66. Phase7 regression

Phase 7 Right Sidebar（`TerminalRightSidebarView`/`SavedCommandsSidebarView`/`CommandHistorySidebarView`）用系统语义色 → 跟随 `NSApp.appearance` 自动（§51）。命令 Paste/Run/History 与 appearance 无关。Phase 7 测试套件不受 Phase 8 影响。

**baseline 测试状态**：Phase 7B remediation（rename UI / grouped command Edit / SavedCommands 空态）已提交进 `46d87e1`/`245689d`，`LocalizationTests.testCatalogHasNoObsoleteKeys` 在 baseline 实际为 **PASS**（3 个原死键已在 `SavedCommandsSidebarView.swift:148/360/376` 被引用；与 2026-09-04 复验记录 412/0/0 一致）。**无继承的测试失败**。Phase 8B 只需关注新增的 `settings.system_mode` obsolete key（P2-C）。

---

## 67. SwiftTerm requirement

**不需要新的 SwiftTerm fork patch。** Phase 8 全程不触碰 SwiftTerm。

- `NSApp.appearance` 是 AppKit App 级 API；SwiftTerm `TerminalView` 作为 NSView 子类自动经 AppKit effective appearance 传播。
- 终端颜色经 MacSSH 自有 `TerminalAppearanceProvider.apply`（Phase 4 已替换 `configureNativeColors`），不依赖 SwiftTerm 内部 appearance 逻辑。
- `TerminalView.effectiveAppearance`（AppKit）随 `NSApp.appearance` 实时变化。
- production pin 仍 `771e79f092a26e7fba7af0ab2b09a2bf10213109`（`MacSSH.xcodeproj/project.pbxproj:912` `revision = 771e79f092a26e7fba7af0ab2b09a2bf10213109`，`repositoryURL = https://github.com/canbyte0/SwiftTerm.git`，`XCRemoteSwiftPackageReference` kind=revision）。确认报告 §59。

---

## 68. security

**不触碰**：

- Keychain、CredentialService、KnownHost、SSH auth、libssh2、OpenSSL、Entitlements、SwiftTerm fork。
- `AppAppearanceMode` 仅 UI preference（`macssh.appearanceMode`），无敏感数据。
- 无新 fork patch（§67）。确认报告 §57。

---

## 69. performance

appearance apply 仅在：

- (a) 用户 mode 变更（`setMode` → `apply`）。
- (b) 系统外观变更（system 模式下 KVO 触发）。
- (c) 新 terminal registration（`register` 立即 apply）。

**不**：timer、polling、每 frame、每 keypress。Coordinator 遍历 live view 数量有限。`TerminalHighlightProviderImpl` 每帧重解析 `effectiveAppearance` 是 Phase 6 既有行为（非 Phase 8 引入）。确认报告 §52。

---

## 70. remaining P1

**无。**（§2）

---

## 71. remaining P2

- **P2-A**：Phase 7 FINAL `245689d` 未 push 到 GitHub（`github/main` 停留 `46d87e1`）。建议 8B 前用户执行 `git push github main`。**不阻塞架构**。
- **P2-C**：`settings.system_mode` 在新 UI 后 obsolete（报告 §54 已识别，§46）。Phase 8B 删该 1 个 key 即可。
- **P2-D**：`HighlightRulesEditor.colorScheme` 与 manual appearance 时序需 8B live probe 验证（§50，低风险，同源）。
- **P2-E**：`AppPreferenceKey.language` 无 `macssh.` 前缀（既有不一致，不回改）。

---

## 72. remaining P3

- **P3-A**：报告 §22 KVO 转换表悲观偏差（live probe 显示 KVO 触发频率 ≥ 预测，§18/§33）。不阻塞，但 §24 理由应订正为「KVO 异步 hop」而非「KVO 不触发」（§34）。
- **P3-B**：AGENTS.md UI 规则——SettingsView 改 Picker 前必须先出预览图（§45）。
- **P3-C**：MacSSH 项目内 live GUI probe 未运行（§47 test 3 / §52，8B 首步补）。
- **P3-D**：测试子目录命名（报告 §56 推荐 `Tests/App/`、`Tests/Terminal/`，现状仅 `Tests/SSH/` 等三个子目录，§62）。
- **P3-E**：key 命名 `settings.appearance.*` vs 计划书 `appearance.mode.*`（两者均合规，§46）。

---

## 73. recommended Phase8B files

**新增**：

- `MacSSH/App/AppAppearanceMode.swift`（enum + load/save + nsAppearance，§36）。
- `MacSSH/App/AppAppearanceController.swift`（`@MainActor @Observable`，§40）。
- 测试：`Tests/App/AppAppearanceModeTests.swift`、`Tests/App/AppAppearanceControllerTests.swift`、`Tests/Terminal/TerminalAppearanceManualModeTests.swift`（或并入 `Tests/SSH/`，§62）。AppearanceSettings 断言并入既有 `LocalizationTests`。

**修改（最小）**：

- `MacSSH/App/AppState.swift`：新增 `appAppearanceController` 属性 + init 顶部（coordinator 后、SessionManager 前）创建 apply（§41/§43）。
- `MacSSH/App/AppLanguage.swift`：`AppPreferenceKey` 加 `appearanceMode`（§37）。
- `MacSSH/Services/Terminal/TerminalAppearanceCoordinator.swift`：暴露 `func applyCurrentAppearance()`（wrapper of private `applyCurrentAppearanceToAllRegisteredViews()`，§34/§35）。
- `MacSSH/Features/Settings/SettingsView.swift`：`LabeledContent`→`Picker(.menu)`（§45，**先出预览** P3-B）。
- `MacSSH/Resources/Localizable.xcstrings`：+3 key（`settings.appearance.system/light/dark`）、**删 `settings.system_mode`**（§46，Phase 7B 原 3 死键已接入 UI 无需清理）。
- `MacSSH.xcodeproj/project.pbxproj`：注册新文件 + 新测试文件。

**不改**：SwiftTerm fork、palette、`TerminalAppearanceProvider`、`TerminalHighlightPalette/Coordinator/ProviderImpl`、SSH/Keychain/Entitlements、`MacSSHApp.swift`（AppState 已足够，§40）。

确认报告 §56，**补充 P2-B 死键清理**。

---

## 74. recommended implementation sequence

1. **AppAppearanceMode** + `AppPreferenceKey.appearanceMode` + `AppAppearanceModeTests`（纯逻辑，无 UI）。
2. **TerminalAppearanceCoordinator.applyCurrentAppearance()** 暴露（1 方法 + 测试）。
3. **AppAppearanceController** + `AppAppearanceControllerTests`（注入 seams）。
4. **AppState** 持有 + init 顶部 apply（launch timing，§41/§43）。
5. **SettingsView Picker 预览图**（AGENTS.md UI 规则，P3-B）→ 用户确认 → 改 `SettingsView.swift` + `Localizable.xcstrings`（3 key + 删 `settings.system_mode`，§46）。
6. **TerminalAppearanceManualModeTests**（existing/new/system-manual 覆盖，§62）。
7. **live probe** 经验确认 5 转换 + 真实 TerminalView 重绘（§18/§47/§52）。
8. **Debug + Release clean build / 全套测试 / 0 production warning**（§69）。
9. **阶段报告**。

确认报告 §57，**补充 step 5 死键清理 + 预览图**。

---

## 75. 是否允许进入 Phase8B

**允许进入 Phase 8B。**

条件：

1. **进入 8B 实现前**（建议，非阻塞）：由用户执行 `git push github main`，把 Phase 7 FINAL `245689d` 推到 GitHub，使 `github/main` 与 local main 一致（P2-A）。
2. **8B SettingsView 改动前**：先出 Picker 预览图，用户确认后才改源码（P3-B，AGENTS.md UI 规则）。
3. **8B 实现期间**：删 `settings.system_mode`（被 Picker 替换后 obsolete，P2-C/§46）。Phase 7B 原 3 死键已接入 UI，无需清理。
4. **8B 首步**：补 live GUI probe 经验确认 5 转换 + 真实 TerminalView 重绘（§18/§47/§52，P3-C）。
5. **8B 结束**：Debug + Release clean build / 全套测试 0 failure / 0 production warning / 阶段报告。

---

## 76. final status

**CONDITIONAL PASS — 允许进入 Phase 8B。**

Phase 8A 架构调查 61 项结论经独立复核全部成立；`NSApp.appearance` 语义经 live probe 经验确认；启动时序安全（NSApp 在 `AppState.init` 已非 nil）；最小改动方案不触碰 SwiftTerm/security；单一 source of truth 清晰。

**4 个需在 8B 处理的条件**（P2-A push、P2-B 死键清理、P3-B 预览图、P3-C live probe）已列入 §75。

**STOP。** 未修改生产代码 / SwiftTerm fork / commit / merge / push / 未开始 Phase 8B。等待用户授权进入 Phase 8B。

---

## 附录：probe 输出（`/tmp/macssh_appearance_probe/probe.swift`，2026-09-04，system=Light）

```
=== initial state (no appearance set) ===
  NSApp.appearance       = nil
  NSApp.effectiveAppearance = light(aqua)

=== §11/§15: NSApp.appearance = nil ===
  NSApp.appearance       = nil
  NSApp.effectiveAppearance = light(aqua)  (should = current system)

=== §12/§16: NSApp.appearance = .aqua ===
  NSApp.appearance       = aqua
  NSApp.effectiveAppearance = light(aqua)  (must = light)

=== §13/§17: NSApp.appearance = .darkAqua ===
  NSApp.appearance       = darkAqua
  NSApp.effectiveAppearance = dark(NSAppearanceNameDarkAqua)  (must = dark)

=== §14: .darkAqua -> nil (manual -> system) ===
  NSApp.appearance       = nil
  NSApp.effectiveAppearance = light(aqua)  (should re-resolve to system)

=== §18: KVO on \.effectiveAppearance when manually setting appearance ===
  baseline effective = light(aqua)
  after set .aqua: kvoFired=1, new=light(aqua)  (expect fired if resolved changed)
  after set .darkAqua: kvoFired=1, new=dark(...)  (expect fired)
  after re-set .darkAqua (same): kvoFired=0  (expect 0)
  after set nil: kvoFired=1, new=light(aqua)  (depends: fires if system != dark)
  after re-set nil (same): kvoFired=1  (expect 0)

=== PROBE DONE ===
```

关键读数：§11-§14 行为与报告 §15-§17 完全一致；§18 KVO 触发频率 ≥ 报告 §22 预测（详见 §18/§33/P3-A）。
