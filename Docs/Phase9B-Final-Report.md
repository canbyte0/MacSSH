# MacSSH 1.1 Phase 9B — Final Report
# Configurable Terminal Font Size 实现 + 验收

> 角色：Phase 9B 实现者（基于 Phase 9A Acceptance Review CONDITIONAL PASS 授权）。
> 范围：UI Preview Gate（方案 A 选定）→ 完整实现 → Debug + Release clean build → 全套测试 → Final Report。
> **未修改 SwiftTerm fork / commit / merge / push。** SwiftTerm pin `771e79f092a26e7fba7af0ab2b09a2bf10213109` 不变。
> 实现日期：2026-09-04。

---

## 1. UI Preview Gate（§54）

按 AGENTS.md UI 规则，SettingsView 修改前先给用户 4 张预览图（方案 A 与方案 B × Light/Dark）。预览生成于 `generated-images/phase9b-preview/`（untracked，不入 commit）。

**用户选择：方案 A**（`− 14 pt +` 紧凑方块按钮设计）。

方案 A 设计要求：
- 减号、当前字号、加号横向排列在右侧
- 14 pt 为当前值
- 10 pt 时减号 disabled
- 32 pt 时加号 disabled
- 不允许直接编辑文字
- 控件保持紧凑，不做胶囊大按钮
- 风格与现有 Settings 页面一致

方案 B（native Stepper）作为备选（Acceptance Review §57 推荐），但用户选 A。

---

## 2. 实现摘要（§86）

### 2.1 新建文件

| 文件 | 用途 |
|---|---|
| `MacSSH/App/TerminalFontSizeController.swift` | `@MainActor @Observable` 字号控制器（preference + weak `NSHashTable<TerminalView>` registry + apply 广播，合并不分 Coordinator） |
| `Tests/SSH/TerminalFontSizeControllerTests.swift` | preference load/clamp/persist + register/broadcast + 0-terminal + 字体身份 + rapid click（22 tests） |
| `Tests/SSH/TerminalFontResizeTests.swift` | cell geometry recompute + cols/rows 变化 + sizeChanged delegate 触发 + frame==0 行为 + Local/Remote font identity 14/18/24 + CJK/Emoji fallback pointSize 跟随 + Unicode 不 crash（13 tests） |

### 2.2 修改文件

| 文件 | 修改 |
|---|---|
| `MacSSH/App/AppLanguage.swift` | `AppPreferenceKey` +`static let terminalFontSize = "macssh.terminalFontSize"` |
| `MacSSH/App/AppState.swift` | +`let terminalFontSizeController: TerminalFontSizeController`（SessionManager 前创建）+ 装配末尾回填注册初始 Local Session terminalView |
| `MacSSH/Services/Terminal/SessionManager.swift` | +`@ObservationIgnored weak var terminalFontSizeController: TerminalFontSizeController?` + 3 处 register：createLocalSession (`:130` 区域) + runConnectFlow 新 Remote (`:447` 区域) + AppState 回填（共享模式，AppState.swift:175 区域） |
| `MacSSH/Features/Settings/SettingsView.swift` | 替换 `LabeledContent("settings.font_size") { Text("settings.font_size_value") }` 为方案 A：`HStack { Button(−) + Text("\(size) pt").monospacedDigit() + Button(+) }` + `.disabled(size <= minSize/maxSize)` 边界 disable |
| `MacSSH/Resources/Localizable.xcstrings` | 删 `settings.font_size_value`（保留 `settings.font_size`），避免 obsolete-key 测试失败 |
| `Scripts/gen_localizable.py` | 删 `:266` `("settings.font_size_value", "14 pt", "14 pt"),` 行（P3-3 fix：避免重新生成 Catalog 时回归 obsolete key） |
| `MacSSH.xcodeproj/project.pbxproj` | 注册 3 新文件（F8 前缀 ID pattern）：build file / file ref / group entry / sources build phase entry × 2 |

### 2.3 SwiftTerm fork

**未修改**。SwiftTerm production pin `771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `canbyte0/SwiftTerm.git` 不变（pbxproj + Package.resolved 双重确认）。

`TerminalView.font` public setter + `resetFont()` + `resize()` + `sizeChanged` delegate 完整覆盖 runtime font mutation + geometry recompute + Local/Remote PTY resize。纯 public API。

---

## 3. Git baseline

- branch：`feature/macssh-1.1-terminal-font-size`
- baseline HEAD（实现前）：`c6bf66c2b985530e6687fefe62cdf08246190e41`（含 Phase 8 FINAL PASS + 两轮 GUI remediation）
- working tree：7 modified + 5 untracked（含 3 docs / 2 生产 / 3 测试；不含 `/tmp` probe / DerivedData / generated-images 入 commit）

---

## 4. 架构合规（§64-§66）

### 4.1 Source of truth 单一链

```
UserDefaults(macssh.terminalFontSize)
  → TerminalFontSizeController.size (Int 10...32)
  → TerminalFontProvider.regularFont(size: CGFloat(size))
  → per-TerminalView.font (NSFont)
```

不维护 `terminalFontSizeRuntime` / `swiftUIFontSize` / `terminalViewPointSize` 等第二套 mutable state。`TerminalFontProvider` 保持 stateless，只接收 size 参数。

### 4.2 Controller + Coordinator 决策（§36 / §40）

合并：`TerminalFontSizeController` 同时负责 preference + weak registry + broadcast，不分 Coordinator。理由：
1. font **无外部触发源**（无 KVO / 系统信号 / `effectiveAppearance` 等价物）——不像 Appearance 需 KVO 安全网独立成 Coordinator。
2. 单一 writer 即单一 broadcaster——`size` didSet → persist + apply，全部 MainActor 同步。
3. Appearance 的 Controller/Coordinator 拆分是因 Coordinator（Phase 4）先于 Controller（Phase 8）存在；font 两者均新建，合并更简。
4. apply 逻辑极简（一行 `view.font =`），不需独立 Coordinator 承载复杂 palette 映射。

### 4.3 Registry 决策（§38-§39）

A. 新建 font controller 自己 weak registry（最小合理方案）。font 与 color/redraw 正交：
- `TerminalAppearanceCoordinator.terminalViews`（apply color palette）
- `TerminalHighlightCoordinator.terminalViews`（apply redraw signal）
- `TerminalFontSizeController.terminalViews`（apply NSFont）

三者独立注册同一批 view，apply 不同属性，互不调用。

### 4.4 Register 点（§44 实际 3 处）

每 coordinator **3 个 register 点**（P3-2 修正：报告 §40/§72 所称 "4 处" 实际为 3 处）：
1. `SessionManager.swift:130` `createLocalSession` 新建 Local
2. `SessionManager.swift:447` `runConnectFlow` 新建 Remote（reconnectingService=nil 分支）
3. `AppState.swift:175` 装配末尾回填初始 Local Session

Reconnect reattach（`SessionManager.swift:435-437`）复用现有 TerminalView，不需 register（Phase 4/6/8 Appearance/Highlight 同样不在 reattach 路径 register）。

### 4.5 Preference 设计

- key：`macssh.terminalFontSize`（与 `macssh.appearanceMode` / `macssh.rightSidebarVisible` 同命名规范）
- type：Int（10...32 step 1，无小数需求，Int 天然排除 NaN/Infinity）
- default：14（与 `TerminalFontProvider.defaultSize` 一致，老用户无 key 时行为不变）
- min/max：10 / 32
- load：`object(forKey:) as? Int` + clamp，对缺失/非Int/Double/NaN 安全回退 14
- Bool → NSNumber bool subtype → `as? Int` 返回 1 / 0 → clamp 10（非 invalid type 路径，是 clamp 路径）
- `size.didSet` 同步 persist + apply，单一 writer
- normalization：clamp-on-load deterministic；user 主动修改时同步 persist clamped 值

---

## 5. UI 实现（方案 A）

```swift
LabeledContent("settings.font_size") {
    HStack(spacing: 6) {
        Button {
            fontSizeController.decrement()
        } label: {
            Image(systemName: "minus")
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(fontSizeController.size <= TerminalFontSizeController.minSize)
        .accessibilityIdentifier("settings.fontSizeDecrement")

        Text("\(fontSizeController.size) pt")
            .monospacedDigit()
            .frame(minWidth: 50, alignment: .center)
            .accessibilityIdentifier("settings.fontSizeValue")

        Button {
            fontSizeController.increment()
        } label: {
            Image(systemName: "plus")
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(fontSizeController.size >= TerminalFontSizeController.maxSize)
        .accessibilityIdentifier("settings.fontSizeIncrement")
    }
}
```

特点：
- `.bordered` + `.controlSize(.small)`：紧凑方块按钮（非胶囊大按钮）
- `Image(systemName: "minus")` / `"plus"`：SF Symbols 系统图标
- `.disabled(size <= minSize)` / `.disabled(size >= maxSize)`：边界自动 disable
- `.monospacedDigit()`：数字等宽，避免 10→11→12 切换时 layout 抖动
- `frame(minWidth: 50)`：当前值文本固定宽度
- `accessibilityIdentifier`：UI test 可定位
- 不允许直接编辑文字（v1 设计选择，留 future）

---

## 6. 测试结果

### 6.1 Phase 9B 新增测试（35 tests）

- `TerminalFontSizeControllerTests`（22 tests，全过）
  - default 14（无偏好）
  - persist/reload 10/14/18/24/32
  - invalid types → 14（Double / String / NaN / Infinity）；Bool → 1/0 → clamp 10
  - 越界 clamp（9→10, 33→32, Int.min/max）
  - setSize/increment/decrement 经 didSet 持久化 + apply
  - 边界 disabled-equivalent（clamp）
  - load 不污染其他 key
  - register 立即应用当前 size（首帧无 14→18 闪烁）
  - size change 广播全部已注册 view
  - 重复同 size 仍 apply 全部 view（无 dedup）
  - new view after size change 立即得当前 size
  - 0 terminal：change size 仍 persist + apply no-op
  - 字体身份在 size=18 下保持 JetBrains Mono + Bundle 来源
  - rapid click 14→15→16→17→18 同步顺序

- `TerminalFontResizeTests`（13 tests，全过）
  - cellDimension（caretFrame.size）随 size 线性 + 减小恢复
  - cols/rows 在 fixed frame 下随 size 增大而减少
  - font change triggers sizeChanged delegate（经 spy TerminalViewDelegate）
  - sizeChanged 报告 newCols/newRows 反映新 font geometry
  - frame == 0 时 resetFont 跳过 resize，但 cellDimension 已更新
  - LocalProcessTerminalView font change 不 crash + cell geometry 更新
  - 字体身份 14/18/24（Regular/Bold/Italic/BoldItalic）保持 JetBrainsMono + Bundle
  - Bold/Italic/BoldItalic 经 NSFontManager.convert(_:toHaveTrait:) pointSize 跟随 regular
  - CJK fallback（PingFang SC）pointSize 跟随 base 14/18/24
  - Emoji fallback（Apple Color Emoji）pointSize 跟随 base 14/18/24
  - Unicode（ASCII / 中文 / Emoji / VS16）在 14/18/24 不 crash

### 6.2 Phase 2-8 regression（0 failure）

- 全 MacSSH fresh DerivedData `/tmp/MacSSH-P9B-DD`：
  **485 executed / 114 skipped / 0 failures → TEST SUCCEEDED**
  （Phase 8B 是 450，Phase 9B +35 = 485，全部通过）
- Phase 2 字体：`TerminalFontProviderTests`（19/0）
- Phase 3 login shell：`LocalShellLauncherTests`
- Phase 4 appearance：`TerminalAppearanceTests`
- Phase 5 VS16：`TerminalVS16WidthPolicyTests`
- Phase 6 highlight：`TerminalHighlightCoordinatorTests` / `TerminalHighlightMatcherTests` / `TerminalHighlightStoreTests`
- Phase 7 sidebar / paste：`TerminalCommandDispatcherTests` / `SavedCommandStoreTests` / `CommandHistoryStoreTests` / `SavedCommandsSidebarContentTests` / `TerminalRightSidebarStateTests`
- Phase 8 manual appearance：`TerminalAppearanceManualModeTests` / `AppAppearanceControllerTests` / `AppAppearanceModeTests`
- Localization：`LocalizationTests`（21/0，含 `testCatalogHasNoObsoleteKeys` 通过——`settings.font_size_value` 已从 xcstrings + gen_localizable.py 同步删除）

### 6.3 Build 结果

- Debug fresh DerivedData `/tmp/MacSSH-P9B-DD`：**BUILD SUCCEEDED**，0 production warning。
- Release fresh DerivedData `/tmp/MacSSH-P9B-Rel`：**BUILD SUCCEEDED**，0 production warning。

---

## 7. P1 / P2 / P3（Phase 9A Acceptance §83-§85 验证）

### 7.1 P1：无

无 App crash / PTY resize crash / font load failure / UserDefaults corruption / TerminalView leak / SwiftTerm fork dependency。

### 7.2 P2：无

无 existing Terminal 不刷新 / new Terminal 用旧字号 / requested-persisted 分歧 / launch flash / rapid click 乱序 / Localization obsolete key / Local-Remote 不一致 / Bold-Italic identity 丢失 / CJK-Emoji 比例错误 / UserDefaults invalid / Settings-runtime divergence。

### 7.3 P3

3 项 P3（Phase 9A Acceptance 已识别，Phase 9B 已修正或保留）：

- **P3-1**：报告 §22 cellWidth 描述措辞不精确——实际仅取 "W" glyph advancement。**Phase 9B 已修正**：`TerminalFontResizeTests.testCellDimensionScalesWithFontSize` 通过 `caretFrame.size` 实测 cellWidth/cellHeight 随 size 线性，证明报告结论成立（不需据此改实现，仅措辞）。
- **P3-2**：报告 §40/§72 "4 处 register" 实际为 3 处。**Phase 9B 已修正**：实际实现按 3 处添加 register（`SessionManager.swift:130` + `:447` + `AppState.swift:175`），reattach 路径不 register。
- **P3-3**：删 `settings.font_size_value` 时遗漏 `Scripts/gen_localizable.py:266`。**Phase 9B 已修正**：同步从 3 处移除（`SettingsView.swift:56` + `Localizable.xcstrings:3693-3708` + `Scripts/gen_localizable.py:266`），`testCatalogHasNoObsoleteKeys` PASS。

其他 P3（沿用 Phase 9A Acceptance §71）：
- background tab font change 一次基于旧 frame 的 PTY resize（中间态，最终一致）
- selection 清除（SwiftTerm `selectNone()` + `processSizeChange` 在 cols/rows 变化时 `selection.active=false`，既有行为，可接受）
- `terminal.softReset()` 副作用（同 sidebar resize 路径，非 Phase 9 新增）
- 不支持 direct typing / ⌘+/⌘-/⌘0 快捷键 / 非整数字号（v1 设计选择，留 future）

---

## 8. Side effects / Regression（§65-§73）

### 8.1 Scrollback（§67）

`resetCaches` 不清 buffer；`terminal.resize` reflow 保留 scrollback；`softReset` 不清 buffer。Phase 9B 不丢失 terminal text model。

### 8.2 Selection（§68）

font setter `selectNone()` + `processSizeChange` 在 cols/rows 变化时清 selection。SwiftTerm 既有行为，sidebar resize 同路径。P3 可接受。

### 8.3 Cursor（§69）

`updateCaretView` 同步新 cellDimension（`AppleTerminalView.swift:310/319-324`）。

### 8.4 VS16（§70）

`variationSelector16WidthPolicy` 在 `TerminalOptions` init 时设，font change 不触碰 options。Phase 5 `TerminalVS16WidthPolicyTests` 通过。

### 8.5 Highlight（§71）

rule range 基于 `BufferLine` cell 位置；`terminal.resize` reflow 后 buffer 内容保留，highlight 在重绘时重新匹配。两个 Coordinator 独立注册，不冲突。Phase 6 `TerminalHighlightCoordinatorTests` 通过。

### 8.6 Right Sidebar（§72）

sidebar open/close 与 font change 经同一 `sizeChanged` delegate，互不干扰。

### 8.7 Appearance（§73）

完全独立（不同 controller / key / Coordinator）。Phase 8 `TerminalAppearanceManualModeTests` / `AppAppearanceControllerTests` / `AppAppearanceModeTests` 通过。

---

## 9. 安全 / 性能（§81-§82）

### 9.1 安全

Phase 9B 未触碰 Keychain / CredentialService / KnownHost / SSH auth / SFTP / libssh2 / OpenSSL / Entitlements / Hardened Runtime / SwiftTerm fork。

git diff 仅含 font preference 相关 11 文件（7 modified + 4 新建；另含 1 doc + 1 untracked generated-images 目录）。

### 9.2 性能

font update 仅发生：
- 用户改字号（低频，< 1 Hz）
- new Terminal register（一次性）
- launch load（一次）

**不**每 frame / 每 keypress / Timer polling 重新创建 font。`regularFont(size:)` 内 `registerBundledFontsIfNeeded()` 幂等（`didAttemptRegistration` guard）。每次 size change 创建 4 NSFont + 遍历 live view（< 10），开销 ms 级。Acceptable。

---

## 10. 已知限制（§74）

- v1 不支持 direct typing（Stepper only / 自定义按钮 only）——留 future
- v1 不支持 ⌘+/⌘-/⌘0 快捷键——留 future
- v1 不支持非整数字号（如 14.5）——Int only
- font change 清除已有选区（SwiftTerm 既有行为，非 Phase 9 新增，但用户可感知）
- background tab font change 触发一次基于旧 frame 的 PTY resize（中间态，最终一致）

---

## 11. 文件清单

### Modified（7）
- `MacSSH.xcodeproj/project.pbxproj`
- `MacSSH/App/AppLanguage.swift`
- `MacSSH/App/AppState.swift`
- `MacSSH/Features/Settings/SettingsView.swift`
- `MacSSH/Resources/Localizable.xcstrings`
- `MacSSH/Services/Terminal/SessionManager.swift`
- `Scripts/gen_localizable.py`

### Created（5）
- `MacSSH/App/TerminalFontSizeController.swift`（生产）
- `Tests/SSH/TerminalFontSizeControllerTests.swift`（测试）
- `Tests/SSH/TerminalFontResizeTests.swift`（测试）
- `Docs/Phase9A-Acceptance-Review.md`（Phase 9A 独立验收）
- `Docs/Phase9B-Final-Report.md`（本报告）

### Untracked（不入 commit）
- `generated-images/phase9b-preview/`（4 张预览图，UI Preview Gate 产物）
- `Docs/Phase9A-TerminalFontSize-Architecture-Investigation.md`（Phase 9A 调查报告，未跟踪）

---

## 12. 测试统计

- Phase 9B 新增：35 tests（22 controller + 13 resize）
- Phase 2-8 回归：450 tests
- 总计：485 executed / 114 skipped / 0 failures

---

## 13. 最终状态

**PHASE 9B IMPLEMENTATION COMPLETE.**

- Phase 9A Acceptance CONDITIONAL PASS 已授权进入 Phase 9B
- UI Preview Gate 完成，用户选择方案 A（−/+ 紧凑方块按钮）
- 完整实现：controller + preference + AppState ownership + SessionManager 3 register + SettingsView 替换 + Localizable + gen_localizable + pbxproj
- Debug + Release fresh DerivedData clean build：0 production warning
- 全 MacSSH 测试 485/114/0 → TEST SUCCEEDED
- Phase 2-8 regression 0 failure
- 3 项 P3 全部修正或保留
- SwiftTerm pin `771e79f092a26e7fba7af0ab2b09a2bf10213109` 不变（不需 fork change）

**STOP。Phase 9B 实现完成。等待用户 GUI 验收 + Independent Code Acceptance + 最终授权 commit。**

未修改 SwiftTerm fork / commit / merge / push。未开始下一 Phase。
