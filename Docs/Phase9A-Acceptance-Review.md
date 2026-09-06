# MacSSH 1.1 Phase 9A — Independent Architecture Acceptance Review
# Configurable Terminal Font Size

> 角色：Independent Architecture Reviewer（非 Phase 9A 原调查者）。
> 方法：源码逐文件独立复核 + SwiftTerm resolved revision 独立读取 + `/tmp` 最小 Swift/AppKit probe + 现有测试套件核查。
> **未修改 production code / SwiftTerm fork / commit / merge / push / 未开始 Phase 9B。**
> 验收日期：2026-09-04。

---

## 1. Acceptance result

**CONDITIONAL PASS — 允许进入 Phase 9B，附 3 项 P3 级别修正项。**

理由摘要：
- Git baseline / branch / 工作树状态全部符合
- 调查报告 76 节主体结论经独立源码复核成立
- SwiftTerm pin `771e79f` 不变，**不需要 fork change**
- runtime font mutation / cell geometry / PTY resize 全链路经源码 + probe 双重证实
- 无 P1 / 无 P2
- 3 项 P3：报告 §22 cellWidth 描述措辞不精确、§40 register 点计数应为 3 而非 4、§44 删除 `settings.font_size_value` 时需同步更新 `Scripts/gen_localizable.py:266`

详见 §83-§85。

---

## 2. P1

**无 P1。** 复核项：
- App crash：`TerminalFontSizeController.init` 只读 UserDefaults + 存 Int；`apply()` 对空 registry no-op；`view.font =` 经 SwiftTerm public API（已被 `FontResizeColumnsTests` 验证）。`MacTerminalView.swift:334-343` `font` public computed property，setter 仅调 `fontSet = FontSet(font:); resetFont(); selectNone()`——无可 fatalError 路径。
- PTY resize crash：`sizeChanged` → `setWinSize` / `resizeChannelPTY` 是已验证路径（Phase 2 / 7）；font change 只增加触发源，不改 resize 实现。
- font load failure：`TerminalFontProvider.font(weight:size:)` 三级 fallback（PostScript → family+face → `monospacedSystemFont`），size 参数只影响 pointSize 不影响 fallback 链。
- UserDefaults corruption：`load(from:)` `object(forKey:) as? Int` 安全回退 14，不 crash。
- TerminalView leak：`NSHashTable.weakObjects()`（Phase 4 / 6 已验证 50 次 create/close 后 live count = 0）。
- SwiftTerm fork dependency：production pin `771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `canbyte0/SwiftTerm.git`，pbxproj + Package.resolved 双重确认，**不需 fork change**。

---

## 3. P2

**无 P2。** 复核项：
- existing Terminal 不刷新：`apply()` 遍历全部 live view 执行 `view.font =`，与 `TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()`（`TerminalAppearanceCoordinator.swift:178-185`）同构。
- new Terminal 用旧字号：`register` 立即 apply 当前 size（与 Appearance/Highlight register 同模式）。
- requested/persisted 分歧：`size.didSet` 同步 persist + apply。
- launch flash：register 在 Service 创建后、SwiftUI 插入前同步调用（frame .zero → `resetFont` 跳过 resize 只更新 `cellDimension`，`setFrameSize` 时 `processSizeChange` 用正确 cellDimension）。无可见 flash。
- rapid click 乱序：全 MainActor 同步。
- Localization obsolete key：删 `settings.font_size_value` 需从 `Localizable.xcstrings` + `Scripts/gen_localizable.py` 同步移除（见 §44 / §53）。
- Local/Remote font 不一致：两者共用 `TerminalFontProvider.regularFont()`，已由源码独立复核（`LocalTerminalService.swift:42` + `RemoteTerminalService.swift:86`）。
- Bold/Italic identity 丢失：SwiftTerm `FontSet`（`MacTerminalView.swift:150-182`）经 `NSFontManager.convert(_:toHaveTrait:)` 派生 4 变体；probe 实证 4 变体 pointSize 一致；family/PostScript identity 经 Phase 2 `TerminalFontProviderTests.testBoldFontIdentityIsJetBrainsMono` / `testItalicFontIdentityIsJetBrainsMono` / `testBoldItalicFontIdentityIsJetBrainsMono` 已验证（default 14pt）。
- CJK/Emoji 字号比例错误：probe 实证 cascade fallback font 的 pointSize 确实跟随 base（base=18 → PingFang SC=18, Apple Color Emoji=18）。报告 §17 措辞不精确但结论成立（见 §25）。
- UserDefaults invalid：`object(forKey:) as? Int` 对非 Int 类型（Double / String / Bool / NaN）返回 nil → 14。
- Settings 与 runtime divergence：Settings 绑定 `$controller.size`，runtime 经 controller.size → `regularFont(size:)` → `view.font`，单一 source。

---

## 4. P3

3 项修正建议：

### P3-1. 报告 §22 cellWidth 描述措辞不精确
报告 §22 写道：
> `cellWidth = ceil(max(advanceWidth, boundingWidth))   // 取 ASCII advance 与 bounding box 的最大值`

实际源码 `AppleTerminalView.swift:428-429`：
```swift
let glyph = fontSet.normal.glyph(withName: "W")
let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width
```
**仅取 "W" glyph 的 advancement，非 max(advance, boundingBox)**。后续 `snappedWidth = (cellWidth * scale).rounded() / scale` 做像素网格对齐（`:435-436`）。Phase 9B 不需据此修改实现，但报告应修正措辞避免误导后续开发者。

### P3-2. 报告 §40 "4 处 register" 应为 "3 处"
独立 `search_content "\.register\(" + "register\("` 全 MacSSH 模块核查结果（per coordinator）：
- `SessionManager.swift:130` — `createLocalSession` 新建 Local（Appearance）
- `SessionManager.swift:132` — `createLocalSession` 新建 Local（Highlight）
- `SessionManager.swift:447` — `runConnectFlow` 新建 Remote（Appearance）
- `SessionManager.swift:450` — `runConnectFlow` 新建 Remote（Highlight）
- `AppState.swift:175` — AppState 装配末尾回填初始 Local（Appearance）
- `AppState.swift:178` — AppState 装配末尾回填初始 Local（Highlight）

Reconnect reattach（`SessionManager.swift:435-437`）**复用现有 TerminalView**，不需 register。

→ 每个 coordinator（包括 Phase 9B 拟新增的 `TerminalFontSizeController`）共 **3 个 register 点**：
1. `createLocalSession`
2. `runConnectFlow` 新建 Remote
3. `AppState` 回填初始 Local

报告 §40 与 §72 的 "4 处" 表述与所列 3 项不符。Phase 9B 实现时按 3 个 register 点添加即可，不影响正确性。

### P3-3. 报告 §44 删除 `settings.font_size_value` 时遗漏 `Scripts/gen_localizable.py`
独立核查 `settings.font_size_value` 全代码库引用点：
- `MacSSH/Features/Settings/SettingsView.swift:56` — 生产源码（Phase 9B 替换为 Stepper + 动态 Text 时移除）
- `MacSSH/Resources/Localizable.xcstrings:3693` — Catalog 条目
- `Scripts/gen_localizable.py:266` — **生成脚本中的 key 元组**

`LocalizationTests.testCatalogHasNoObsoleteKeys`（`LocalizationTests.swift:685-692`）扫描 `catalogKeys()` 与 `sourceReferencedKeys()` 的差集；若仅从 `SettingsView.swift` + `Localizable.xcstrings` 移除而遗留 `gen_localizable.py:266`，下次重新生成 Catalog 时会重新加入该 key，导致 obsolete-key test 失败。Phase 9B 实现时需**同步**从三处移除。

### 其他 P3（沿用报告 §71 已识别项）
- background tab font change 触发一次基于旧 frame 的 PTY resize（中间态，最终一致）
- selection 清除（font setter `selectNone()` + `processSizeChange` 在 cols/rows 变化时清 selection，属 SwiftTerm 既有行为，可接受）
- `terminal.softReset()` 副作用（`resize()` 内调用，与 sidebar resize 同路径，非 Phase 9 新增）

---

## 5. branch

`feature/macssh-1.1-terminal-font-size`（从 `main` `c6bf66c` 创建，clean working tree）。

`git branch --show-current` → `feature/macssh-1.1-terminal-font-size` ✓

---

## 6. baseline

`c6bf66c2b985530e6687fefe62cdf08246190e41`（main，含 Phase 8 FINAL PASS + 两轮 GUI remediation）。

`git rev-parse HEAD` → `c6bf66c2b985530e6687fefe62cdf08246190e41` ✓

---

## 7. production modifications

**无。** Phase 9A 纯调查，未修改任何生产代码 / SwiftTerm fork / 测试 / 本地化 / pbxproj。

`git status --short` 仅显示：
```
?? Docs/Phase9A-TerminalFontSize-Architecture-Investigation.md
```
`git diff --check` clean ✓。

---

## 8. Settings current UI

`SettingsView.swift:55-57`（独立复核）：
```swift
LabeledContent("settings.font_size") {
    Text("settings.font_size_value")
}
```
纯只读 `LabeledContent` + 静态本地化 `Text`。无交互、无绑定。与 `settings.font`（"JetBrains Mono" 只读）和 `settings.scrollback`（"10,000 行" 只读）并列于 `Section("settings.section.terminal")`。

Appearance mode 在另一 Section 用 `Picker(.menu)` 绑定 `$appearanceController.mode`（`SettingsView.swift:93-100`），是当前唯一交互式偏好。

---

## 9. static label

**纯静态 label。** `settings.font_size_value` 在 `Localizable.xcstrings:3693-3708` zh/en 均为字面 "14 pt"，不读取任何 runtime 值。改 SettingsView 的 label 不影响 runtime；改 runtime font size 也不更新该 label。

---

## 10. runtime source

**`TerminalFontProvider.defaultSize: CGFloat = 14.0`**（`TerminalFontProvider.swift:31-32`）。

证实链：
- `LocalTerminalService.swift:42` `TerminalFontProvider.regularFont()` →
- `TerminalFontProvider.swift:215` `regularFont(size: defaultSize)` →
- `TerminalFontProvider.swift:32` `defaultSize = 14.0`

Remote 同路径（`RemoteTerminalService.swift:86`）。

UI 显示 "14 pt" 与 runtime 14.0 巧合一致，但**无绑定关系**。

---

## 11. duplicate-size sources

独立 `search_content "defaultSize|fontSize|font_size|pointSize|regularFont\(|boldFont\(|italicFont\("` 全 `MacSSH/` 模块核查：

| 位置 | 性质 |
|---|---|
| `TerminalFontProvider.swift:32` | `defaultSize = 14.0`（**唯一实际字号定义**） |
| `TerminalFontProvider.swift:215/221/227/233` | `regularFont/boldFont/italicFont/boldItalicFont(size: defaultSize)` 默认参数 |
| `TerminalFontProvider.swift:311/321/326/331/336` | 验证 helper（PostScript name 探测） |
| `SettingsView.swift:55-56` | 静态 label |
| `Localizable.xcstrings:3676/3699/3705` | 本地化字符串 |

其他 `MacSSH/` 内 "14" 引用均为 UI 常量（Tab close button frame `width:14`、status indicator、`.font(.system(size: 14))` 等），**与 terminal font size 无关**。

`MacSSHApp.swift:76` `.defaultSize(width:height:)` 是 SwiftUI Scene API（窗口默认尺寸），与 font size 无关。

`boldFont()` / `italicFont()` / `boldItalicFont()`（`TerminalFontProvider.swift:221/227/233`）**生产代码无任何调用方**（独立 grep 实证：仅 `Tests/SSH/TerminalFontProviderTests.swift:77/85/93` 调用），仅供测试验证 PostScript identity。

→ **不存在 Local 14 / Remote 14 / SwiftTerm 14 第二隐藏 source**。

---

## 12. Local font path

```
SessionManager.createLocalSession()                       SessionManager.swift:116
  → LocalTerminalService(session:)                        LocalTerminalService.swift:20
    → TerminalFontProvider.regularFont()                  LocalTerminalService.swift:42
      → TerminalFontProvider.regularFont(size: defaultSize) TerminalFontProvider.swift:215
        → font(weight: .regular, size: 14.0)              TerminalFontProvider.swift:217 → 240
          → NSFont(name: "JetBrainsMono-Regular", size: 14.0)
          → applyCascade(to:)                             TerminalFontProvider.swift:279-289
    → ScrollTrackingLocalProcessTerminalView(              TerminalScrollIndicatorController.swift:290
        frame: .zero, font:, options:
      )                                                   LocalTerminalService.swift:40-44
    → TerminalAppearanceProvider.applyCurrentAppAppearance(to:)  LocalTerminalService.swift:60
  → ManagedTerminalSession(localService:, ...)             SessionManager.swift:120
  → terminalAppearanceCoordinator?.register(service.terminalView)  SessionManager.swift:130
  → terminalHighlightCoordinator?.register(service.terminalView)   SessionManager.swift:132
```

`ScrollTrackingLocalProcessTerminalView` 是 `LocalProcessTerminalView` 的子类，后者是 `TerminalView` 的子类——`font` public setter 可用。

---

## 13. Remote font path

```
SessionManager.runConnectFlow()                           SessionManager.swift:393
  → (认证成功后) RemoteTerminalService(connection:hostname:port:)  RemoteTerminalService.swift:65
    → TerminalFontProvider.regularFont()                   RemoteTerminalService.swift:86
    → TerminalView(frame: .zero, font:, options:)          RemoteTerminalService.swift:84-88
    → TerminalAppearanceProvider.applyCurrentAppAppearance(to:)  RemoteTerminalService.swift:99
  → session.attachRemoteService(service)                   SessionManager.swift:444
  → terminalAppearanceCoordinator?.register(service.terminalView)  SessionManager.swift:447
  → terminalHighlightCoordinator?.register(service.terminalView)   SessionManager.swift:450
  → service.startIfNeeded()                                SessionManager.swift:451
```

Local / Remote 在 font 构造与注册上**完全同源**（同一 `TerminalFontProvider.regularFont()`，同一注册模式）。

---

## 14. SwiftTerm SHA

`771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `canbyte0/SwiftTerm.git`。

独立复核：
- `MacSSH.xcodeproj/project.pbxproj:929-932`：
  ```
  repositoryURL = "https://github.com/canbyte0/SwiftTerm.git";
  revision = 771e79f092a26e7fba7af0ab2b09a2bf10213109;
  ```
- `MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:16-18`：
  ```
  "location" : "https://github.com/canbyte0/SwiftTerm.git",
  ...
  "revision" : "771e79f092a26e7fba7af0ab2b09a2bf10213109"
  ```

Resolved checkout 路径：`build/DerivedData/SourcePackages/checkouts/SwiftTerm/`（用于本次源码核查）。

---

## 15. TerminalView.font API

`MacTerminalView.swift:334-343`（独立复核行号；报告 §13 称 `:339-348` 存在 5 行偏移，非实质问题）：
```swift
public var font: NSFont {
    get {
        return fontSet.normal
    }
    set {
        fontSet = FontSet (font: newValue)
        resetFont()
        selectNone()
    }
}
```
- **public** get/set（可在 MacSSH 模块外直接 `terminalView.font = newFont`）
- getter 返回 `fontSet.normal`（regular）
- setter 三步：替换 `fontSet`、调用 `resetFont()`、调用 `selectNone()`

`fontSet` 字段（`MacTerminalView.swift:327`）：`var fontSet: FontSet`（internal storage，setter 通过 public `font` 间接赋值）。

---

## 16. font setter path

```
terminalView.font = newFont                              MacTerminalView.swift:338
  → fontSet = FontSet(font: newFont)                     MacTerminalView.swift:339
    → FontSet.init(font: fontSize:)                     MacTerminalView.swift:164-169
      → normal = baseFont
      → bold = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask])
      → italic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask])
      → boldItalic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask, .boldFontMask])
  → resetFont()                                          MacTerminalView.swift:340
    → resetCaches()                                       AppleTerminalView.swift:299
    → cellDimension = computeFontDimensions()             AppleTerminalView.swift:300
    → if frame.width > 0 && frame.height > 0:           AppleTerminalView.swift:301
        newCols = Int(getEffectiveWidth(size: frame.size) / cellDimension.width)  :306
        newRows = Int(frame.height / cellDimension.height)                          :307
        resize(cols: newCols, rows: newRows)              AppleTerminalView.swift:308
          → terminal.resize(cols:rows:)                  AppleTerminalView.swift:2819
            [buffer reflow，保留 scrollback]
          → sizeChanged(source: terminal)                AppleTerminalView.swift:2820
            → terminalDelegate?.sizeChanged(source:newCols:newRows:)  MacTerminalView.swift:3252
              → Local: LocalProcessTerminalView.sizeChanged / Remote: RemoteTerminalService.sizeChanged
          → terminal.softReset()                         AppleTerminalView.swift:2821
            [DEC mode 复位，不清 buffer]
    → updateCaretView()                                   AppleTerminalView.swift:310
    → needsDisplay = true                                 AppleTerminalView.swift:313
  → selectNone()                                          MacTerminalView.swift:341
```

源码证据完整，非"SwiftTerm 会自动 resize" 模糊描述。

---

## 17. resetFont behavior

`AppleTerminalView.swift:297-317` 独立复核：

| 项 | 是否更新 | 证据 |
|---|---|---|
| normal font | ✓（间接：`font` setter 替换 `fontSet`，`fontSet.normal` 即新 base） | `MacTerminalView.swift:339` |
| bold font | ✓（间接：`FontSet.init` 派生新 bold） | `MacTerminalView.swift:166` |
| italic font | ✓（同上） | `MacTerminalView.swift:167` |
| boldItalic font | ✓（同上） | `MacTerminalView.swift:168` |
| font dimensions | ✓ `cellDimension = computeFontDimensions()` | `AppleTerminalView.swift:300` |
| glyph cache | ✓ `resetCaches()`（清空 `attributes` / `urlAttributes` / `colors` / `trueColors`） | `AppleTerminalView.swift:288-294 / 299` |
| renderer state | ✓ `needsDisplay = true` | `AppleTerminalView.swift:313` |
| **scrollback buffer** | **不清** `resetCaches` 不调 `terminal.clearScrollback` / `terminal.reset` | `AppleTerminalView.swift:288-294` |

---

## 18. Regular

runtime 14 → 16 后 Regular `pointSize = 16`。

probe 实证（`/tmp/macssh_phase9a_probe/probe.swift`，使用 `NSFont.monospacedSystemFont`，JetBrains Mono 同 CTFont 行为）：
```
size= 14.0 regular.pointSize=14.0 cellW=8.6543 cellH=17.0000 cols=115 rows=35
size= 16.0 regular.pointSize=16.0 cellW=9.8906 cellH=19.0000 cols=101 rows=31
size= 18.0 regular.pointSize=18.0 cellW=11.1270 cellH=22.0000 cols=89 rows=27
size= 24.0 regular.pointSize=24.0 cellW=14.8359 cellH=29.0000 cols=67 rows=20
```
Regular pointSize 严格跟随传入 size；cellW/cellH 随 size 线性增长；cols/rows 合理减少。✓

---

## 19. Bold

**SwiftTerm 自带 FontSet 派生 Bold，MacSSH 不需手动提供。**

`MacTerminalView.swift:166`：
```swift
self.bold = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask])
```

probe 实证（同一 regular 经 NSFontManager 派生）：
```
size= 14.0 bold=14.0 italic=14.0 boldItalic=14.0
size= 16.0 bold=16.0 italic=16.0 boldItalic=16.0
size= 18.0 bold=18.0 italic=18.0 boldItalic=18.0
size= 24.0 bold=24.0 italic=24.0 boldItalic=24.0
```
4 变体 pointSize 完全一致。`NSFontManager.convert(_:toHaveTrait:)` 保留输入 font 的 size。✓

⚠️ 注意：`TerminalFontProvider.boldFont()`（`TerminalFontProvider.swift:221`）**生产代码无调用方**，仅供 `TerminalFontProviderTests` 验证 bundled Bold TTF PostScript identity。runtime SwiftTerm `FontSet` 经 NSFontManager 派生 Bold——因 MacSSH 已 register 全部 4 个 bundled TTF，NSFontManager 会找到 family 内的 bundled Bold face（而非合成或系统替代）。

---

## 20. Italic

同 §19。`MacTerminalView.swift:167`：
```swift
self.italic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask])
```

probe 实证 4 size 下 italic pointSize 与 regular 一致。✓

---

## 21. BoldItalic

同 §19。`MacTerminalView.swift:168`：
```swift
self.boldItalic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask, .boldFontMask])
```

probe 实证 4 size 下 boldItalic pointSize 与 regular 一致。✓

**Phase 9 含义**：一次 `view.font = regularFont(size: 16)` 赋值即可让 Regular/Bold/Italic/BoldItalic 全部变为 16 pt。不需分别设置 4 个 font。

---

## 22. NSFontManager decision

**推荐方案 B（regular 16pt + NSFontManager convert traits）**，**且这正是 SwiftTerm `FontSet` 现有实现**。Phase 9B 无需重新设计——MacSSH 只传 1 个 base regular font，SwiftTerm FontSet 内部派生 3 变体。

为什么不用方案 A（直接创建 4 个 bundled faces at 16pt）？
1. SwiftTerm `font` setter API 只接受 1 个 NSFont，无法分别注入 4 变体（除非 fork 改 API）。
2. SwiftTerm `FontSet.init`（`:164-169`）已固定走 NSFontManager 路径，方案 A 需 fork。
3. NSFontManager `convert(_:toHaveTrait:)` 在 family 内寻找匹配 face——因 MacSSH 已 register 全部 4 bundled TTF（`TerminalFontProvider.swift:44-49 / 129-210`），Bold trait 会找到 bundled `JetBrainsMono-Bold`，Italic 找到 bundled `JetBrainsMono-Italic`，BoldItalic 找到 bundled `JetBrainsMono-BoldItalic`。
4. Phase 2 `TerminalFontProviderTests.testBoldFontIdentityIsJetBrainsMono` / `testItalicFontIdentityIsJetBrainsMono` / `testBoldItalicFontIdentityIsJetBrainsMono` 已在 default 14pt 验证 4 face 均解析到 JetBrainsMono 家族（fontName 含 "JetBrainsMono" + "Bold"/"Italic"）。

Phase 9B 需补一组同 identity 测试在 size=18 / size=24 下确认（§75）。

唯一推荐：**沿用 SwiftTerm 现有 NSFontManager FontSet 派生路径，不创建额外 FontSet**。

---

## 23. bundled font identity

Phase 2 已实现并验收：bundled JetBrains Mono Regular/Bold/Italic/BoldItalic 4 TTF 位于 `Contents/Resources/`（`TerminalFontProvider.swift:44-49`）。

Phase 9 不能因 dynamic sizing 让 Bold/Italic fallback 为 Menlo / SF Mono。

设计 identity test：
```swift
// Phase 9B 拟新增（§75）
func testBoldIdentityAtSize18() {
    let regular = TerminalFontProvider.regularFont(size: 18)
    let bold = NSFontManager.shared.convert(regular, toHaveTrait: [.boldFontMask])
    XCTAssertTrue(bold.fontName.contains("JetBrainsMono"))
    XCTAssertTrue(bold.fontName.contains("Bold"))
    XCTAssertEqual(bold.pointSize, 18)
    XCTAssertTrue(TerminalFontProvider.isFontSourcedFromBundle(bold))
}
// 同理 italic / boldItalic / size=14/18/24
```

---

## 24. fallback architecture

`applyCascade`（`TerminalFontProvider.swift:279-289`）独立复核：
```swift
let cascadeList: [NSFontDescriptor] = [
    NSFontDescriptor(fontAttributes: [.family: cjkFallbackFamily]),   // PingFang SC
    NSFontDescriptor(fontAttributes: [.family: emojiFallbackFamily])  // Apple Color Emoji
]
let attributes: [NSFontDescriptor.AttributeName: Any] = [
    .cascadeList: cascadeList
]
let descriptor = font.fontDescriptor.addingAttributes(attributes)
return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
```

- 通过 `NSFontDescriptor.cascadeList` attribute
- CoreText 在渲染主 font 不覆盖的 Unicode 时按 cascade list family 匹配
- 不做手工按字符切分文本

---

## 25. fallback size

**报告 §17 / §10 措辞"fallback cascade 无 size 自动跟随"需修正为"cascade descriptor 不指定 size，但 resolved fallback font 的 pointSize 确实跟随 base font"。**

probe 实证（`/tmp/macssh_phase9a_probe/probe.swift`，base 18pt + cascade PingFang SC + Apple Color Emoji，渲染 "你好" 与 "😀"）：
```
base.pointSize=18.0 baseWithCascade.pointSize=18.0
  run 0: font=PingFangSC-Regular family=PingFang SC pointSize=18.0
  emoji run 0: font=AppleColorEmoji family=Apple Color Emoji pointSize=18.0
```

CTFont cascade 机制：渲染主 font 不覆盖的 Unicode 时，从 cascade list 按 family 匹配，并**按主 font 的 pointSize 解析 cascade font**（CoreText 行为）。因此 14→18 后，PingFang SC 与 Apple Color Emoji fallback 自动以 18pt 渲染。

→ **不需额外处理 fallback size。CJK/Emoji 视觉比例保持。**

---

## 26. CJK behavior

probe 实证 PingFang SC fallback 在 base=14/16/18/24 下分别以对应 pointSize 渲染。

CJK 字符在终端 cell 渲染策略：
- JetBrains Mono 不覆盖 CJK → CoreText 从 cascade list 找 PingFang SC
- PingFang SC glyph 通常 width=2（CJK 全角）
- SwiftTerm `BufferLine` cell-width policy 不变（CJK 仍是 2 cell）
- 视觉比例：CJK cell 高度跟随 base font height（18pt base → 22pt cellH → CJK 字符高度匹配）

✓ 无比例错误风险。

---

## 27. Emoji behavior

probe 实证 Apple Color Emoji fallback 在 base=14/16/18/24 下分别以对应 pointSize 渲染。

Emoji 字符（如 😀 U+1F600）渲染策略：
- JetBrains Mono 不覆盖 Emoji → CoreText 从 cascade list 找 Apple Color Emoji
- Apple Color Emoji 是 color font，glyph 默认 width=2
- SwiftTerm `BufferLine` 把 emoji 标 width=2（与 CJK 一致）
- 视觉比例：emoji cell 占 2 cell width × 1 cell height，与 18pt base cell geometry 匹配

✓ 无比例错误风险。

---

## 28. cell width

`AppleTerminalView.swift:428-429` 独立复核：
```swift
let glyph = fontSet.normal.glyph(withName: "W")
let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width
```

**取 "W" glyph 的 advancement（不是 max(advance, bounding)，报告 §22 措辞不精确 — 见 P3-1）**。

随后（`AppleTerminalView.swift:435-438`）做像素网格对齐：
```swift
let scale = backingScaleFactor()
let snappedWidth = (cellWidth * scale).rounded() / scale
let snappedHeight = ceil(cellHeight * scale) / scale
return CellDimension(width: max(1, snappedWidth), height: max(min(snappedHeight, 8192), 1))
```

cellWidth 随 font size 线性增长（probe 实证 14→8.65, 16→9.89, 18→11.13, 24→14.84）。

---

## 29. cell height

`AppleTerminalView.swift:412-415` 独立复核：
```swift
let lineAscent = CTFontGetAscent(fontSet.normal)
let lineDescent = CTFontGetDescent(fontSet.normal)
let lineLeading = CTFontGetLeading(fontSet.normal)
let cellHeight = ceil((lineAscent + lineDescent + lineLeading) * _lineSpacing)
```

`_lineSpacing = 1.0`（默认，不改）。cellHeight 随 font size 线性增长（probe 实证 14→17, 16→19, 18→22, 24→29）。

---

## 30. geometry probe

probe 已运行（`/tmp/macssh_phase9a_probe/probe.swift`，使用 `NSFont.monospacedSystemFont`，CTFont 行为与 JetBrains Mono 同质）：

| size | cellWidth | cellHeight | cols (1000×600) | rows |
|---|---|---|---|---|
| 14 | 8.6543 | 17.0 | 115 | 35 |
| 16 | 9.8906 | 19.0 | 101 | 31 |
| 18 | 11.1270 | 22.0 | 89 | 27 |
| 24 | 14.8359 | 29.0 | 67 | 20 |

- cell dimensions 随 size 增大 ✓
- cols/rows 随 size 增大而合理减少 ✓
- Bold/Italic/BoldItalic pointSize 与 Regular 完全一致 ✓

---

## 31. cols/rows

probe 实证 1000×600 frame 下 14→18 cols 从 115 减到 89，rows 从 35 减到 27。

SwiftTerm `processSizeChange`（`AppleTerminalView.swift:386-407`）与 `resetFont`（`:301-308`）使用相同公式：
```swift
newCols = Int(getEffectiveWidth(size: frame.size) / cellDimension.width)
newRows = Int(frame.height / cellDimension.height)
```

font change 与 sidebar resize 经同一 resize 路径，cols/rows 最终一致。

---

## 32. frame-zero behavior

`resetFont`（`AppleTerminalView.swift:301`）：
```swift
if (frame.width > 0) && (frame.height > 0) {
    // 计算 newCols/newRows 并 resize
}
```

frame == 0（view 未 layout）时：
- `resetCaches()` 仍执行
- `cellDimension = computeFontDimensions()` 仍执行
- `resize` **跳过**
- `updateCaretView` 仍执行
- `needsDisplay = true` 仍设

→ font setter 在 zero frame 时只更新 `cellDimension`，**不触发 PTY resize**。

---

## 33. new-view first render

新 Terminal 创建顺序（独立复核）：
1. `LocalTerminalService.init` 创建 `ScrollTrackingLocalProcessTerminalView(frame: .zero, font: regularFont(), options:)` — view 创建时 frame=.zero，font=14（默认）
2. （Phase 9B 新增）`register(view)` 立即 `view.font = regularFont(size: controller.size)` — 在 SwiftUI 插入 view 前同步调用
3. SwiftUI 把 view 插入视图层级 → `setFrameSize` → `processSizeChange` 用新 cellDimension 计算 cols/rows → resize → sizeChanged → PTY resize

由于 step 2 在 SwiftUI 看到 view 前同步设置 font=size，step 3 setFrameSize 时 cellDimension 已是 size 对应值。

→ **首帧即请求字号，无 14→18 闪烁。**

---

## 34. Local resize path

独立复核（源码追踪）：
```
font setter → resetFont → resize(cols:rows:)                       AppleTerminalView.swift:308
  → terminal.resize(cols:rows:)                                    AppleTerminalView.swift:2819
    [buffer reflow，保留 scrollback]
  → sizeChanged(source: terminal)                                  AppleTerminalView.swift:2820
    → MacTerminalView.sizeChanged(source:)                          MacTerminalView.swift:3251
      → terminalDelegate?.sizeChanged(source:newCols:newRows:)      MacTerminalView.swift:3252
        → LocalProcessTerminalView.sizeChanged(source:newCols:newRows:)  MacLocalTerminalView.swift:104
          → getWindowSize()                                        [基于 terminal.cols/rows + cellDimension 像素]
          → PseudoTerminalHelpers.setWinSize(masterPtyDescriptor:windowSize:)  Pty.swift:117-124
            → ioctl(masterFd, TIOCSWINSZ, &winsize)                  Pty.swift:120
          → processDelegate?.sizeChanged(source:newCols:newRows:)    MacLocalTerminalView.swift:111
            → LocalTerminalService.sizeChanged                       LocalTerminalService.swift:185-195
              → session.columns = newCols
              → session.rows = newRows
              → scrollIndicatorController.update()
```

`MacLocalTerminalView.swift:104-112` 完整源码已复核。PTY 实际维度（cols/rows/pixel）经 `getWindowSize()` 基于 `terminal.cols/rows + cellDimension`，与新 font geometry 一致。

---

## 35. Remote resize path

独立复核：
```
font setter → resetFont → resize(cols:rows:)                       AppleTerminalView.swift:308
  → terminal.resize + sizeChanged(source:)
    → terminalDelegate?.sizeChanged(source:newCols:newRows:)       MacTerminalView.swift:3252
      → RemoteTerminalService.sizeChanged(source:newCols:newRows:)  RemoteTerminalService.swift:446-468
        → session.columns = newCols                                 RemoteTerminalService.swift:453
        → session.rows = newRows                                    RemoteTerminalService.swift:454
        → scrollIndicatorController.update()                        RemoteTerminalService.swift:455
        → guard sizeChanged (cols/rows 变化)                        RemoteTerminalService.swift:457
        → try await connection.resizeChannelPTY(columns:rows:)     RemoteTerminalService.swift:462
          → SSHChannel actor 内 libssh2_channel_request_pty_size_ex  [Phase 7 实现]
```

`RemoteTerminalService.swift:446-468` 完整源码已复核。`connection.resizeChannelPTY` 真实方法名（非猜测）。

---

## 36. remote serialization

`connection.resizeChannelPTY(columns:rows:)` 是 `SSHConnection` actor 的方法（Phase 7 实现）。所有调用经 actor 串行边界，**不会并发乱序**。

快速 14→15→16→17→18：
- 每次 `sizeChanged` 在 `RemoteTerminalService` 内 `Task { @MainActor in ... }` 提交
- 每次进入 `connection.resizeChannelPTY` 在 actor 队列顺序执行
- 最终 remote PTY 收到 18（最后一次值）
- 中间 14→15→16→17 各自发起 libssh2_channel_request_pty_size，远端 shell 收到连续 window-change，最终 18

✓ 最终不会 stale。

---

## 37. explicit resize necessity

**不需要显式 resize。** font setter 已内置完整链路（§16）。

唯一边界（frame == 0）由后续 `setFrameSize` 自动补偿（§32）。

Phase 9B **不需**模拟 window resize / 改 frame ±1 / DispatchQueue 延迟 hack。SwiftTerm `FontResizeColumnsTests.testFontChangeColumnsMatchResizePath` 已验证 font-change 与 live-resize 路径产生相同 cols，无 drift。

---

## 38. existing-session update

`TerminalFontSizeController`（`@MainActor @Observable`，weak `NSHashTable<TerminalView>` registry），`apply()` 遍历全部 live view 执行 `view.font = TerminalFontProvider.regularFont(size: CGFloat(size))`。与 `TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()`（`TerminalAppearanceCoordinator.swift:178-185`）完全同构。

---

## 39. registry recommendation

**A. 新增 font controller 自己 weak registry**（最小合理方案）。

理由：
1. 现有 `TerminalAppearanceCoordinator.terminalViews`（`TerminalAppearanceCoordinator.swift:43`）apply color palette
2. 现有 `TerminalHighlightCoordinator.terminalViews`（`TerminalHighlightCoordinator.swift:23`）apply redraw signal
3. 两者 apply 不同属性（color vs redraw），**不互相调用**
4. font 是第三种属性（NSFont），与前两者正交

→ **不推荐 B（通用 registry shared service）**：3 个属性 apply 时机、apply 内容、broadcast 触发源完全不同，强行合并反而增加耦合。
→ **不推荐 C（复用某现有 registry）**：font 与 color / redraw 正交，复用会污染现有 Coordinator 职责。

---

## 40. controller/coordinator decision

**推荐合并：`TerminalFontSizeController` 同时负责 preference + registry + broadcast（不分 Coordinator）。**

理由：
1. font **无外部触发源**（无 KVO、无系统信号、无 `effectiveAppearance` 等价物）——不像 Appearance 需 KVO 安全网独立成 Coordinator。font 只在用户操作时变化。
2. 单一 writer 即单一 broadcaster——`size` didSet → persist + apply，全部 MainActor 同步，无异步 hop。
3. Appearance 的 Controller/Coordinator 拆分是因为 Coordinator（Phase 4）先于 Controller（Phase 8）存在；font 两者均新建，合并更简。
4. apply 逻辑极简（一行 `view.font =`），不需独立 Coordinator 承载复杂 palette 映射。
5. 与 `TerminalFontProvider`（无状态 enum，只生成 NSFont）职责严格分离：Provider 不知 preference，Controller 不知 font family/cascade。

Phase 9 范围下最小且合理。

---

## 41. weak lifecycle

controller 持有 `NSHashTable<TerminalView>.weakObjects()`（与 `TerminalAppearanceCoordinator.swift:43` / `TerminalHighlightCoordinator.swift:23` 同模式）。

- Session 关闭 → Service 释放 → TerminalView 释放 → NSHashTable 槽位自动 nil
- `allObjects` 访问时自动回收已 nil 槽位
- 无强持有 session view，无 TerminalView leak

`TerminalHighlightCoordinatorTests` 已验证 50 次 create/close 后 `registeredViewCountForTesting == 0`。

---

## 42. duplicate register

`NSHashTable.add(_:)` 对同一 object 多次 add **幂等**（NSHashTable 文档明确：same object won't create duplicate entries）。

`register(view)` 实现：
```swift
func register(_ view: TerminalView) {
    terminalViews.add(view)
    view.font = TerminalFontProvider.regularFont(size: CGFloat(size))
}
```

重复 register 同一 view：
- `add` no-op（无 registry 增长）
- `view.font =` 重设（idempotent，因 font 是 computed property）

→ 无多次 apply 问题，无 registry duplicate growth，无生命周期问题。

Phase 9B 实现时无需 contains check（NSHashTable 已幂等）。

---

## 43. AppState ownership

`AppState` strong owns `TerminalFontSizeController`（`let terminalFontSizeController`，在 `SessionManager` 之前创建）。

证据：现有 Appearance / Highlight 同模式：
- `AppState.swift:35` `let terminalAppearanceCoordinator: TerminalAppearanceCoordinator`
- `AppState.swift:43` `let appearanceController: AppAppearanceController`
- `AppState.swift:50` `let terminalHighlightCoordinator: TerminalHighlightCoordinator`
- 装配顺序（`AppState.swift:99-128`）：coordinator → controller → SessionManager

Phase 9B 应在 `terminalHighlightCoordinator` 之后、`sessionManager` 之前创建 `terminalFontSizeController`，与现有 pattern 一致。

---

## 44. registration points

独立核查：每 coordinator **3 个 register 点**（非报告 §40 所述 4 个 — 见 P3-2）：

| # | 文件:行 | 时机 |
|---|---|---|
| 1 | `SessionManager.swift:130` | `createLocalSession` 新建 Local |
| 2 | `SessionManager.swift:447` | `runConnectFlow` 新建 Remote（reconnectingService=nil 分支）|
| 3 | `AppState.swift:175` | AppState 装配末尾回填初始 Local Session |

Reconnect reattach（`SessionManager.swift:435-437`）**复用现有 TerminalView**，不需 register（Phase 4 / 6 / 8 Appearance/Highlight 同样不在 reattach 路径 register）。

Phase 9B 应在上述 3 个点添加 `terminalFontSizeController?.register(service.terminalView)`。

---

## 45. Local new-view registration

新 Local：`SessionManager.createLocalSession` 创建 service 后立即 register（`SessionManager.swift:130`），此时 SwiftUI 尚未插入 view（view 持有于 service 内）。

Phase 9B `register` 立即 `view.font = regularFont(size: controller.size)`，在 `setFrameSize` 触发 `processSizeChange` 前 cellDimension 已对齐 controller.size。首帧即请求字号。

---

## 46. Remote new-view registration

新 Remote：`SessionManager.runConnectFlow` 在认证成功后创建 service（`SessionManager.swift:439-443`）并立即 register（`SessionManager.swift:447`），与 Local 同模式。

---

## 47. backfill

`AppState.init`（`AppState.swift:99-180`）装配顺序：
1. 创建 coordinator / controller（先于 SessionManager，因为 SessionManager.init 会创建首个 Local Session，需先就位）
2. 创建 `SessionManager`（`SessionManager.init` 内 `createLocalSession()` 立即创建首个 Local Session）
3. 装配末尾（`AppState.swift:168-180`）回填：
   - `session.localeProvider = sessionManager.localeProvider`
   - `terminalAppearanceCoordinator.register(terminalView)`
   - `terminalHighlightCoordinator.register(terminalView)`

回填必要性：`SessionManager.init` 创建首个 Local Session 时，`terminalAppearanceCoordinator` / `terminalHighlightCoordinator` 已通过 `sessionManager.terminalAppearanceCoordinator =` 等弱引用注入（`AppState.swift:127-128`），但**回填是为了 localeProvider**——coordinator 的 register 在 SessionManager.createLocalSession 内已通过 weak coordinator 调用（`SessionManager.swift:130`）。

Phase 9B 应在 AppState 装配末尾的同一回填循环（`AppState.swift:174-179` 块内）添加 `terminalFontSizeController.register(terminalView)`，与 Appearance/Highlight 同位置。

⚠️ 报告 §31 提到"backfill"必要性的疑问：实际上 Phase 9B controller 在 SessionManager 之前创建并已通过 `sessionManager.terminalFontSizeController =` 弱引用注入，**首个 Local Session 已在 SessionManager.createLocalSession 内 register**。AppState.swift:175 处的 register 是冗余的（重复 register 是幂等的，无副作用）。但为保持与 Appearance/Highlight 同模式，仍建议保留。

---

## 48. Settings source

Settings 字体大小必须绑定 `controller.size`，而不是 `activeTerminalView.font.pointSize`。

理由：
1. `controller.size` 是单一 source of truth
2. 无 active terminal 时 `activeTerminalView` 为 nil，无法读 pointSize
3. `view.font.pointSize` 是 derived 值，不应作为 source

Phase 9B SettingsView 实现：
```swift
LabeledContent("settings.font_size") {
    Stepper(value: $controller.size, in: 10...32) {
        Text("\(controller.size) pt")
    }
}
```

---

## 49. no-active-terminal

验证：
- 0 terminal 时 `terminalViews` registry 为空
- 用户 14 → 18 → `size.didSet` → persist `macssh.terminalFontSize = 18` + `apply()` no-op（无 live view）
- 之后 `createLocalSession` → register 时 `view.font = regularFont(size: 18)` → 首帧 18

✓ 无 active terminal 时仍可修改并持久化。

---

## 50. UserDefaults key

`macssh.terminalFontSize`（`AppPreferenceKey.terminalFontSize`）。

需在 `AppLanguage.swift:46-54` `enum AppPreferenceKey` 新增：
```swift
static let terminalFontSize = "macssh.terminalFontSize"
```

与现有 `macssh.appearanceMode` / `macssh.rightSidebarVisible` / `macssh.rightSidebarTab` 同命名规范。

---

## 51. storage type

**Int**。

理由：
- 10...32 范围，step 1，无小数需求
- Int 天然排除 NaN / Infinity
- `Stepper(value:in:)` 原生支持 `Int` range
- 校验面最小

API boundary 转 CGFloat：`TerminalFontProvider.regularFont(size: CGFloat(controller.size))`。`TerminalFontProvider` 现有 API 已用 `CGFloat`（`regularFont(size: CGFloat = defaultSize)`），无需改签名。

---

## 52. default/min/max/step

- default = **14**（与 `TerminalFontProvider.defaultSize` 一致；老用户无该 key 时返回 14，行为与现状完全相同）
- min = **10**（足够小但不致极小化失真）
- max = **32**（足够大但不致溢出常见窗口）
- step = **1**（`Stepper` 默认步进）

技术评估：
- 10pt 时 cellW≈6.2，cellH≈12（仍可读）
- 32pt 时 cellW≈19.8，cellH≈39（在 1000×600 frame 下 cols≈50，rows≈15，仍可用）
- 不会触发 SwiftTerm 任何边界（`CellDimension.height` 上限 8192，远超 32pt）

✓ 无技术问题。

---

## 53. invalid numeric values

| stored | 行为 |
|---|---|
| 缺失 key | `object(forKey:)` 返回 nil → `as? Int` 返回 nil → fallback 14 |
| String "abc" | `as? Int` 返回 nil → 14 |
| Bool true | `as? Int` 返回 nil → 14 |
| Double 17.5 | `as? Int` 返回 nil（NSNumber bridge 不自动转） → 14 |
| Double NaN | 同上 → 14 |
| Double Infinity | 同上 → 14 |
| Int 8 | `as? Int` = 8 → clamp(8) = 10 |
| Int 40 | `as? Int` = 40 → clamp(40) = 32 |
| Int 14 | `as? Int` = 14 → 14 |

```swift
static func load(from defaults: UserDefaults) -> Int {
    guard let stored = defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int else {
        return defaultSize
    }
    return clamp(stored)
}

static func clamp(_ value: Int) -> Int {
    min(max(value, 10), 32)
}
```

⚠️ 注意 `defaults.integer(forKey:)` 对缺失/错误类型返回 0，因此**必须用 `object(forKey:) as? Int`**。

---

## 54. UserDefaults NSNumber behavior

`object(forKey:)` 返回 `Any?`：
- 存 Int → 返回 `NSNumber(int:)` → `as? Int` 成功
- 存 Double → 返回 `NSNumber(double:)` → `as? Int` **失败**（Swift bridge 不自动转换 NSNumber 类型）
- 存 Bool → 返回 `NSNumber(bool:)` → `as? Int` 失败
- 缺失 → 返回 nil

**推荐：先 `object(forKey:)` 验证类型存在性 + `as? Int` 类型校验**，而非 `integer(forKey:)`（后者对缺失返回 0 无法区分）。

报告 §37 / §50 推荐方案正确。

---

## 55. normalization

如果 persisted = 40，load → size = 32（clamp）。是否同时 rewrite UserDefaults → 32？

报告 §52 提出"deterministic"。建议：
- **不在 `init` 主动 rewrite**：clamp-on-load 已 deterministic，每次 load 行为一致
- **在 `size.didSet` 时 rewrite**：用户主动修改时同步 persist clamped 值

```swift
init(...) {
    self.size = Self.load(from: userDefaults)
}

var size: Int {
    didSet {
        let clamped = Self.clamp(size)
        if clamped != size { size = clamped }  // Stepper 已限制，但防御
        userDefaults.set(size, forKey: AppPreferenceKey.terminalFontSize)
        applyFontSizeToAllRegisteredViews()
    }
}
```

- 存 40 → load 32 → 用户改 31 → didSet → persist 31（norm 完成）
- 存 40 → load 32 → 用户不改 → 下次 launch 仍 load 32（行为一致）

✓ deterministic 无歧义。

---

## 56. persistence

`controller.size` 改变时 persist：

| 触发源 | persist 时机 |
|---|---|
| 用户 Stepper +/- | `size.didSet` 同步 persist |
| `setSize(_:)`（如键盘快捷键 future） | `size.didSet` 同步 persist |
| `increase()` / `decrease()` | 经 `size += 1` 触发 `didSet` persist |

**单一 writer**：所有修改经 `size` property，全部走 `didSet` → persist。

无 `Task` / `DispatchQueue.async` 延迟 persist，无丢失风险。

---

## 57. Stepper recommendation

**native `Stepper(value: $controller.size, in: 10...32)` + `Text("\(controller.size) pt")`**。

理由：
1. 最符合 macOS Settings 原生风格（与 Appearance `Picker(.menu)` 同级）
2. Stepper 自动在 boundary disable +/−（10 时 minus disabled，32 时 plus disabled）
3. 步进 1，无需自定义按钮逻辑
4. VoiceOver 读出 "14" + "pt"（`Text` 自动组合 accessibility value）
5. 与 Settings 现有 row 风格一致（LabeledContent 内嵌控件）

备选方案 `－ 14 pt ＋` 自定义 Button 可行但增加无谓复杂度，不推荐。

---

## 58. preview gate

按 `AGENTS.md` UI 规则，Phase 9B 修改 SettingsView 前必须先给用户 preview。

建议 preview 同时展示：
- 方案 A：`Stepper(value:in:)` + `Text("\(size) pt")`（推荐）
- 方案 B：`－` Button + `Text("\(size) pt")` + `＋` Button

用户确认后才改 SettingsView production code。

---

## 59. direct input decision

**v1 不允许 direct typing（Stepper only）。**

- 无 TextField、无数字输入框
- 避免非法字符 / 小数 / 空值 / 越界扩大校验面
- Stepper + 步进 1 足够

留 future（如需支持精确输入 14.5pt 等场景）。

---

## 60. boundary behavior

`Stepper(value: $controller.size, in: 10...32)`：
- 10 时 **minus disabled**（SwiftUI 原生 `in:` range 语义）
- 32 时 **plus disabled**
- 不越界

`controller.size.didSet` 内 `Self.clamp(size)` 作防御性二次保障（Stepper 已限制，但 `setSize(_:)` / 外部调用方可能越界）。

测试边界：
- save 10 → reload → 10 ✓
- save 32 → reload → 32 ✓
- save 9 → clamp 10 ✓
- save 33 → clamp 32 ✓

---

## 61. live update order

14 → 15 流程：
1. 用户点击 Stepper +
2. SwiftUI 更新 `controller.size = 15`（MainActor 同步）
3. `size.didSet` 触发：
   - `Self.clamp(15)` = 15（无变化）
   - `userDefaults.set(15, forKey: ...)`（thread-safe）
   - `applyFontSizeToAllRegisteredViews()`（MainActor 同步）：
     - `let font = TerminalFontProvider.regularFont(size: 15)` （构造 1 个 NSFont + cascade）
     - `for view in terminalViews.allObjects { view.font = font }`
4. 每个 `view.font = font` 触发 SwiftTerm `font` setter：
   - `fontSet = FontSet(font: font)` — 构造 3 个 derived NSFont（bold/italic/boldItalic）
   - `resetFont()` — 重算 cellDimension + resize（frame > 0 时）+ updateCaretView + needsDisplay
   - `selectNone()` — 清 selection
5. `resize(cols:rows:)` → `terminal.resize` + `sizeChanged(source:)` + `terminal.softReset()`
6. `sizeChanged` → `terminalDelegate?.sizeChanged` →
   - Local: `LocalProcessTerminalView.sizeChanged` → `setWinSize` ioctl TIOCSWINSZ → `processDelegate?.sizeChanged` → `LocalTerminalService` 更新 session.columns/rows
   - Remote: `RemoteTerminalService.sizeChanged` → `connection.resizeChannelPTY`（actor 串行）→ libssh2_channel_request_pty_size_ex

**全 MainActor 同步**（除 Remote PTY resize 经 actor 异步但顺序保证）。

---

## 62. MainActor

- `TerminalFontSizeController` 标注 `@MainActor`（仿 `AppAppearanceController` / `TerminalAppearanceCoordinator` / `TerminalHighlightCoordinator`）
- `size.didSet` → persist（`UserDefaults.set` thread-safe）+ apply（`view.font =` 必须 main thread）
- `register(view)` 在 MainActor 调用（SessionManager `@MainActor`）
- `applyFontSizeToAllRegisteredViews` 在 MainActor
- `TerminalView.font` setter 内部 `resetFont()` / `resize()` / `needsDisplay` 均 main thread（SwiftTerm macOS 约束）

✓ 全链路同步 MainActor，无 `Task { @MainActor in }` 异步 hop（Local PTY resize 同步，Remote PTY resize 经 actor 但 sizeChanged 回调同步）。

---

## 63. rapid-click ordering

快速 14→15→16→17→18：
- 全 MainActor 同步：每次 `size.didSet` 同步 persist + apply
- 每次 apply 同步 `view.font =` → `resetFont()` → `resize()` → `sizeChanged` → PTY resize
- Local PTY resize 同步（`ioctl` 直接返回）
- Remote PTY resize 经 actor 串行队列，按 14→15→16→17→18 顺序执行
- 最终 terminal 停在 18，PTY 也是 18

✓ 无异步队列、无 reordering 风险。

---

## 64. font object creation

每次 size change：
- MacSSH 调用 `TerminalFontProvider.regularFont(size:)` 1 次 → 构造 **1 个 regular NSFont**（含 cascade descriptor）
- SwiftTerm `FontSet.init` 内部经 `NSFontManager.convert` 派生 **3 个 NSFont**（bold / italic / boldItalic）

**总计 4 个 NSFont 对象 per size change per view**。

无需手工创建 4 个 font——SwiftTerm FontSet API 只接受 1 个 base font。

---

## 65. provider API

**推荐 `regularFont(size:)` 保持现有签名**（已支持 size 参数）：
```swift
static func regularFont(size: CGFloat = defaultSize) -> NSFont
```

Phase 9B 调用方：`TerminalFontProvider.regularFont(size: CGFloat(controller.size))`。

**不推荐改为 `fontSet(size:)`** 或 **`provider.size` state**：
- 增加复杂度
- FontSet 由 SwiftTerm 内部管理，MacSSH 不需关心
- `provider.size` 会成为第二 source of truth（与 controller.size 分歧）

---

## 66. source-of-truth architecture

**UserDefaults → TerminalFontSizeController.size → TerminalFontProvider.regularFont(size:) → TerminalView.font**

而非：
- `Controller.size` + `Provider.currentSize`（两份 mutable state，会分歧）
- `Provider` singleton mutable（破坏现有 stateless enum 设计）

✓ 单一 source of truth：`TerminalFontSizeController.size`。`TerminalFontProvider` 保持 stateless，只接收 size 参数生成 NSFont。

---

## 67. scrollback

`resetFont()`（`AppleTerminalView.swift:297-317`）：
- `resetCaches()` — 清空 color/attribute 缓存，**不清 buffer**
- `computeFontDimensions()` — 重算 cellDimension
- `resize(cols:rows:)` → `terminal.resize(cols:rows:)` reflow buffer（**保留 scrollback**，只重新排列行列）
- `terminal.softReset()` 复位 DEC 模式，**不清 buffer**

✓ 现有 scrollback 内容保留。font change 是 presentation-only + geometry reflow，不丢失 terminal text model。

Phase 9B 测试需验证（§64）：写入多行 → font change → scrollback 内容仍存在。

---

## 68. selection

`processSizeChange`（`AppleTerminalView.swift:394`）在 cols/rows 变化时 `selection.active = false`。

font setter 的 `selectNone()`（`MacTerminalView.swift:341`）**无条件清除选区**，无论 cols/rows 是否变化。

属合理行为（cell geometry 变化后选区位置无意义），不是缺陷。SwiftTerm 既有行为（sidebar resize 也走同路径）。

**用户感知**：font change 后已有选区被清除。可在 Settings 无明确提示。属 P3 可接受。

---

## 69. cursor

`resetFont()` → `updateCaretView()`（`AppleTerminalView.swift:310` / `:319-324`）：
```swift
caretView.frame.size = CGSize(width: cellDimension.width, height: cellDimension.height)
caretView.updateCursorStyle()
```

cursor frame 同步到新 cellDimension，不会停在旧字号 geometry。

✓ cursor 渲染使用新 cell geometry。

---

## 70. VS16

`variationSelector16WidthPolicy` 存于 `TerminalOptions`：
- Local: `.preserveBaseWidth`（`LocalTerminalService.swift:38`）
- Remote: 默认 `.widenToEmojiWidth`（不显式设置）

`TerminalOptions` 在 `TerminalView.init(frame:font:options:)` 时设入 `Terminal`（`MacTerminalView.swift:354-360`）。font change → `resetFont` → `resize` → `terminal.resize` **不修改 `options`**。

VS16 width policy 不变。⚠️❤️ 等 emoji cell width policy 保持。

✓ Phase 5 不受影响。`TerminalVS16WidthPolicyTests` 应通过。

---

## 71. Highlight

`TerminalHighlightCoordinator.broadcastRedrawToAllRegisteredViews`（`TerminalHighlightCoordinator.swift:87-94`）：
```swift
let liveViews = terminalViews.allObjects
for view in liveViews {
    view.terminal.updateFullScreen()
    view.needsDisplay = true
}
```

font change 的 `resetFont` 也设 `needsDisplay = true`（`AppleTerminalView.swift:313`）。highlight rule range 基于 `BufferLine` cell 位置——`terminal.resize` reflow 后 buffer 内容保留，highlight 在重绘时重新匹配，位置正确。

两个 Coordinator 独立注册同一批 view，font apply 与 highlight redraw 不冲突。

✓ Phase 6 不受影响。`TerminalHighlightCoordinatorTests` / `TerminalHighlightMatcherTests` 应通过。

---

## 72. Right Sidebar

Sidebar open/close → `setFrameSize` → `processSizeChange` → `sizeChanged` → PTY resize。
font change → `resetFont` → `resize` → `sizeChanged` → PTY resize。

两者经同一 `sizeChanged` delegate：
- Sidebar open + 14→18：font change 触发 resize（基于当前 frame）；Sidebar 已 open，frame 不变；PTY 收到最终 cols/rows（更少，因 font 更大）。
- Sidebar close + font change：close 触发 setFrameSize（frame 变宽）→ recompute → PTY resize；font change 独立触发 resize。最终一致。

无组合 bug 风险——两者都走 SwiftTerm 内部 resize 机制。

`TerminalRightSidebarStateTests` 应通过。

---

## 73. Appearance

font preference 与 appearance preference 完全独立：
- 不同 controller（`TerminalFontSizeController` vs `AppAppearanceController`）
- 不同 Coordinator（拟新建 vs `TerminalAppearanceCoordinator`）
- 不同 UserDefaults key（`macssh.terminalFontSize` vs `macssh.appearanceMode`）

- 切 Light/Dark：`AppAppearanceController.apply()` → `NSApp.appearance` + `TerminalAppearanceCoordinator.applyCurrentAppearance()`（只 apply color palette）——**不触碰 font**
- 切 font size：`TerminalFontSizeController.apply()` 只 `view.font =`——**不触碰 color**
- 重启：appearance 从 `macssh.appearanceMode` load，font 从 `macssh.terminalFontSize` load，各自保持
- 两个 Coordinator 的 `register` 在同一注册点调用，对同一批 view 各自 apply 正交属性

✓ Phase 8 不受影响。`AppAppearanceControllerTests` / `AppAppearanceModeTests` / `TerminalAppearanceTests` / `TerminalAppearanceManualModeTests` 应通过。

---

## 74. tests

Phase 9B 至少规划（沿用报告 §57-64）：

| 测试类 | 覆盖 |
|---|---|
| `TerminalFontSizeControllerTests` | preference load / clamp / persist / apply / register / broadcast / 0 terminal 场景 |
| `TerminalFontResizeTests` | font change → cellDimension 变化 → cols/rows 变化 → sizeChanged 触发 |
| `TerminalFontSizeRegistrationTests` | existing/new view 更新 + 3 register 点 |
| `TerminalFontGeometryTests` | 14→18 cellWidth/cellHeight 增大、cols/rows 减少 |
| Local resize test | `LocalProcessTerminalView.sizeChanged` / `setWinSize` 被调用 |
| Remote resize test | `connection.resizeChannelPTY` 被请求 |
| font identity tests | 14/18/24 下 Regular/Bold/Italic/BoldItalic 均为 JetBrainsMono bundled |
| Unicode tests | ASCII / 中文 / Emoji / VS16 在 14/18/24 不 crash + cell policy 合理 |
| scrollback/cursor/selection regression | font change 后 scrollback 保留、cursor 同步、selection 清除 |

---

## 75. Local resize test

必须证明 font change → Local PTY `setWinSize` 被调用，而非只断言 `view.font.pointSize == 18`。

策略：
- 构造 `LocalProcessTerminalView`（不需真实 shell，只验证 sizeChanged delegate 路径）
- 用 spy `LocalProcessTerminalViewDelegate` 捕获 `sizeChanged(source:newCols:newRows:)`
- `view.font = regularFont(size: 18)`（frame > 0）
- 断言 spy 收到 `sizeChanged` 且 `newCols`/`newRows` 与新 cellDimension 一致
- 进一步用 mock `PseudoTerminalHelpers`（如可行）断言 `setWinSize` 被调用

SwiftTerm `FontResizeColumnsTests` 已证明 font change 触发 cols/rows recompute，可作 reference。

---

## 76. Remote resize test

必须证明 font change → `connection.resizeChannelPTY` 被请求。

策略：
- 构造 `RemoteTerminalService` 用 mock `SSHConnection`（spy）
- `view.font = regularFont(size: 18)`（frame > 0）
- 断言 spy 收到 `resizeChannelPTY(columns:rows:)` 调用，参数与新 cols/rows 一致
- 进一步断言 `session.columns` / `session.rows` 更新

`RemoteTerminalTests.swift` 已存在 mock SSHConnection 模式可复用。

---

## 77. font identity tests

至少验证 14/18/24 三种 size 下：
- Regular `fontName` 含 "JetBrainsMono"
- Bold `fontName` 含 "JetBrainsMono" + "Bold"
- Italic `fontName` 含 "JetBrainsMono" + "Italic"
- BoldItalic `fontName` 含 "JetBrainsMono" + "Bold" + "Italic"
- 4 变体 `pointSize` 与传入 size 一致
- `TerminalFontProvider.isFontSourcedFromBundle` 返回 true（不 fallback 为系统字体）

现有 `TerminalFontProviderTests` 已覆盖 size=14；Phase 9B 需扩到 18/24。

---

## 78. Unicode tests

至少覆盖：
- ASCII（"Hello"）
- 中文（"你好"）
- Emoji（"😀"）
- VS16（"⚠\u{FE0F}" / "❤\u{FE0F}"）

在 size=14 / 18 / 24 下：
- 不 crash
- CJK / Emoji cell width 与 size 无关（policy 由 `TerminalOptions.variationSelector16WidthPolicy` 决定）
- ASCII cell width 跟随 size

`TerminalVS16WidthPolicyTests` 已存在 VS16 policy 测试，Phase 9B 应运行回归。

---

## 79. regressions

Phase 9B 最终必须：
- Phase 2 font tests（`TerminalFontProviderTests`）
- Phase 3 login shell（`LocalShellLauncherTests`）
- Phase 4 appearance（`TerminalAppearanceTests`）
- Phase 5 VS16（`TerminalVS16WidthPolicyTests`）
- Phase 6 highlight（`TerminalHighlightCoordinatorTests` / `TerminalHighlightMatcherTests` / `TerminalHighlightStoreTests`）
- Phase 7 sidebar / paste（`TerminalCommandDispatcherTests` / `SavedCommandStoreTests` / `CommandHistoryStoreTests` / `SavedCommandsSidebarContentTests` / `TerminalRightSidebarStateTests`）
- Phase 8 manual appearance（`TerminalAppearanceManualModeTests` / `AppAppearanceControllerTests` / `AppAppearanceModeTests`）
- Localization（`LocalizationTests`，含 `testCatalogHasNoObsoleteKeys`）

全部 0 failure。上述测试文件经 `ls Tests/SSH/` 独立核查存在。

---

## 80. SwiftTerm fork

**不需要 fork change。**

`TerminalView.font` public setter + `resetFont()` + `resize()` + `sizeChanged` delegate 完整覆盖：
- runtime font mutation（public `font` setter）
- cell geometry recompute（`resetFont` → `computeFontDimensions`）
- cols/rows recompute（`resetFont` → `resize`，frame > 0 时）
- Local PTY resize（`sizeChanged` → `LocalProcessTerminalView.sizeChanged` → `setWinSize` ioctl TIOCSWINSZ）
- Remote PTY resize（`sizeChanged` → `RemoteTerminalService.sizeChanged` → `resizeChannelPTY`）
- cursor realign（`resetFont` → `updateCaretView`）
- redraw（`resetFont` → `needsDisplay`）
- selection clear（`selectNone()` + `processSizeChange` 在 cols/rows 变化时 `selection.active = false`）

纯 public API 即可实现全部需求。SwiftTerm pin `771e79f092a26e7fba7af0ab2b09a2bf10213109` 不变。

`FontResizeColumnsTests`（SwiftTerm 自带）已验证 font change 触发 cols recompute 与 live-resize 路径一致。

---

## 81. security

Phase 9 不修改：
- Keychain / CredentialService
- KnownHost / SSH auth / SFTP / libssh2 / OpenSSL
- Entitlements / Hardened Runtime
- SwiftTerm fork

预期 git diff 仅含 font preference 相关文件：
- 新建 `App/TerminalFontSizeController.swift`
- 编辑 `App/AppLanguage.swift`（+`AppPreferenceKey.terminalFontSize`）
- 编辑 `App/AppState.swift`（+`terminalFontSizeController` ownership + 回填）
- 编辑 `Services/Terminal/SessionManager.swift`（+`weak terminalFontSizeController` + 3 处 register）
- 编辑 `Features/Settings/SettingsView.swift`（替换静态 Text 为 Stepper）
- 编辑 `Resources/Localizable.xcstrings`（删 `settings.font_size_value`）
- 编辑 `Scripts/gen_localizable.py`（删 `:266` 对应行 — **P3-3**）
- 编辑 `MacSSH.xcodeproj/project.pbxproj`（+`TerminalFontSizeController.swift` file ref）
- 新建 `Tests/SSH/TerminalFontSizeControllerTests.swift`
- 新建 `Tests/SSH/TerminalFontResizeTests.swift`
- 新建 `Docs/Phase9B-Final-Report.md`

安全基线不触碰。

---

## 82. performance

font update 仅发生：
- 用户改字号（低频，< 1 Hz）
- new Terminal register（一次性）
- launch load（一次）

**不**每 frame / 每 keypress / Timer polling 重新创建 font。

`regularFont(size:)` 内 `registerBundledFontsIfNeeded()` 幂等（`didAttemptRegistration` guard，`TerminalFontProvider.swift:130`），不会重复注册。

每次 size change 创建 4 个 NSFont（1 regular + 3 derived），单次开销 ms 级，acceptable。

`applyFontSizeToAllRegisteredViews` 遍历 `terminalViews.allObjects`，Terminal 数量有限（通常 < 10），开销可忽略。

✓ acceptable performance。

---

## 83. remaining P1

**无 P1。**

---

## 84. remaining P2

**无 P2。**

---

## 85. remaining P3

**3 项 P3**（详见 §4）：

### P3-1. 报告 §22 cellWidth 描述措辞不精确
报告称 `cellWidth = ceil(max(advanceWidth, boundingWidth))`，实际源码用 `"W"` glyph advancement（`AppleTerminalView.swift:428-429`）。

**修复**：Phase 9B 实现不受影响（不需据此改实现）；报告可在 Phase 9B Final Report 中修正措辞。

### P3-2. 报告 §40 / §72 "4 处 register" 应为 "3 处"
实际核查：每 coordinator **3 个 register 点**（createLocal / runConnectFlow 新 Remote / AppState 回填）。

**修复**：Phase 9B 实现按 3 个 register 点添加 `terminalFontSizeController?.register(...)`，无需找第 4 个不存在的点。

### P3-3. 删 `settings.font_size_value` 时需同步更新 `Scripts/gen_localizable.py:266`
报告 §44 只提 `Localizable.xcstrings` + SettingsView 源码，遗漏 `Scripts/gen_localizable.py:266`（key 元组定义）。

**修复**：Phase 9B 实现时**同步**从 3 处移除 `settings.font_size_value`：
1. `MacSSH/Features/Settings/SettingsView.swift:56`
2. `MacSSH/Resources/Localizable.xcstrings:3693-3708`
3. `Scripts/gen_localizable.py:266`

否则下次重新生成 Catalog 时会重新加入该 key，导致 `testCatalogHasNoObsoleteKeys` 失败。

### 其他 P3（沿用报告 §71 已识别项）
- background tab font change 触发一次基于旧 frame 的 PTY resize（中间态，最终一致）
- selection 清除（font setter `selectNone()` + `processSizeChange` 在 cols/rows 变化时清 selection，属 SwiftTerm 既有行为，可接受）
- `terminal.softReset()` 副作用（`resize()` 内调用，与 sidebar resize 同路径，非 Phase 9 新增）
- 不支持 direct typing（v1 设计选择，留 future）
- 不支持 ⌘+/⌘-/⌘0 快捷键（留 future）
- 不支持非整数字号（如 14.5）（Int only）

---

## 86. recommended Phase9B files

| 文件 | 操作 | 内容 |
|---|---|---|
| `MacSSH/App/TerminalFontSizeController.swift` | **新建** | `@MainActor @Observable` controller + weak `NSHashTable<TerminalView>` registry + load/clamp/persist/apply/register + 测试 seam |
| `MacSSH/App/AppLanguage.swift` | 编辑 | `AppPreferenceKey` +`static let terminalFontSize = "macssh.terminalFontSize"` |
| `MacSSH/App/AppState.swift` | 编辑 | +`let terminalFontSizeController: TerminalFontSizeController`（SessionManager 前创建）+ 装配末尾回填注册初始 Local Session |
| `MacSSH/Services/Terminal/SessionManager.swift` | 编辑 | +`@ObservationIgnored weak var terminalFontSizeController: TerminalFontSizeController?` + 3 处 `terminalFontSizeController?.register(service.terminalView)` |
| `MacSSH/Features/Settings/SettingsView.swift` | 编辑 | 替换 `Text("settings.font_size_value")` 为 `Stepper(value: $controller.size, in: 10...32) { Text("\(controller.size) pt") }` |
| `MacSSH/Resources/Localizable.xcstrings` | 编辑 | 删 `settings.font_size_value`（保留 `settings.font_size`） |
| `Scripts/gen_localizable.py` | 编辑 | 删 `:266` `("settings.font_size_value", "14 pt", "14 pt"),` 行（**P3-3**） |
| `MacSSH.xcodeproj/project.pbxproj` | 编辑 | +`TerminalFontSizeController.swift` file ref |
| `Tests/SSH/TerminalFontSizeControllerTests.swift` | **新建** | preference load/clamp/persist/apply/register/broadcast/0-terminal 测试 |
| `Tests/SSH/TerminalFontResizeTests.swift` | **新建** | geometry + Local/Remote PTY resize + scrollback/cursor/selection regression |
| `Tests/SSH/TerminalFontProviderTests.swift` | 编辑 | 扩 font identity 测试到 size=18/24（§77） |
| `Docs/Phase9B-Final-Report.md` | **新建** | 实现报告 |

---

## 87. recommended implementation sequence

1. `AppPreferenceKey.terminalFontSize` + `TerminalFontSizeController`（含 load/clamp/persist/apply/register + 测试 seam）
2. `TerminalFontSizeControllerTests`（preference tests，§53-§55）——先验证 preference 层
3. `AppState` 装配（SessionManager 前创建 controller + 回填注册初始 Local）
4. `SessionManager` 3 处 register（createLocal + runConnectFlow remote new）+ `weak` 引用
5. `TerminalFontResizeTests`（geometry + Local/Remote PTY resize，§75-§76）——验证 resize 链
6. `TerminalFontSizeRegistrationTests`（existing/new view + scrollback/cursor/selection regression，§64/§67-§69）
7. 扩 `TerminalFontProviderTests` 到 size=18/24（§77）
8. **UI preview gate**：出 Stepper + Text 预览，用户确认
9. `SettingsView` 替换静态行为 Stepper（用户确认后）
10. `Localizable.xcstrings` + `Scripts/gen_localizable.py` 同步删 `settings.font_size_value`（**P3-3**）
11. `LocalizationTests` 回归（obsolete key gate）
12. fresh DerivedData Debug+Release clean build + 全 MacSSH 测试（Phase 2-8 regression 全 0 failure，§79）
13. `Phase9B-Final-Report.md`

---

## 88. 是否允许进入 Phase9B

**允许进入 Phase 9B。**

理由：
- Git baseline / branch / 工作树状态符合
- source of truth 单一（`TerminalFontProvider.defaultSize`），迁移路径清晰
- SwiftTerm public `font` setter 完整覆盖 runtime mutation + geometry recompute + PTY resize（Local + Remote）——**无 fork change、无 blocker**
- 现有 registry pattern（Appearance/Highlight Coordinator）可直接复用
- 现有 preference pattern（`AppAppearanceController` / `AppAppearanceMode` / `AppPreferenceKey`）可直接复用
- 无 P1 / 无 P2 阻断项
- Phase 5/6/7/8 regression 风险可控（均已分析，有对应测试规划）
- 3 项 P3 修正项均为措辞 / 计数 / 清理遗漏，**不影响 Phase 9B 实现正确性**
- 与计划书 §46 无冲突（不重新打包字体、不改 family、不改 fallback）
- probe 实证 cell geometry 随 size 线性 + cascade fallback pointSize 自动跟随 + Bold/Italic/BoldItalic pointSize 一致

---

## 89. final status

**PHASE 9A INDEPENDENT ARCHITECTURE ACCEPTANCE — CONDITIONAL PASS.**

- branch `feature/macssh-1.1-terminal-font-size` ✓
- baseline `c6bf66c2b985530e6687fefe62cdf08246190e41` ✓
- production modifications：无 ✓
- Settings current UI：静态 "14 pt" label（`SettingsView.swift:55-57`）✓
- runtime source：`TerminalFontProvider.defaultSize = 14.0`（`TerminalFontProvider.swift:32`）✓
- duplicate-size sources：无 ✓
- Local font path：`LocalTerminalService.swift:42` → `TerminalFontProvider.regularFont()` ✓
- Remote font path：`RemoteTerminalService.swift:86` → 同上 ✓
- SwiftTerm SHA：`771e79f092a26e7fba7af0ab2b09a2bf10213109` ✓
- TerminalView.font API：public get/set（`MacTerminalView.swift:334-343`）✓
- font setter path：`font → FontSet → resetFont → computeFontDimensions → resize → sizeChanged` ✓
- resetFont behavior：清 caches + 重算 cellDimension + resize（frame > 0）+ updateCaretView + needsDisplay，**不清 buffer** ✓
- Regular/Bold/Italic/BoldItalic pointSize 一致（probe 实证）✓
- NSFontManager decision：方案 B（regular + NSFontManager traits，SwiftTerm FontSet 现有实现）✓
- bundled font identity：Phase 2 已验证 + Phase 9B 需扩 size=18/24 ✓
- fallback architecture：`NSFontDescriptor.cascadeList` PingFang SC + Apple Color Emoji ✓
- fallback size：probe 实证 cascade fallback font pointSize 跟随 base ✓
- CJK / Emoji behavior：比例保持，无 P2 风险 ✓
- cell width：`"W"` glyph advancement（probe 实证随 size 线性）✓
- cell height：`ascent + descent + leading`（probe 实证随 size 线性）✓
- geometry probe：14/16/18/24 cellW/cellH/cols/rows 合理 ✓
- frame-zero behavior：resetFont 跳过 resize，cellDimension 仍更新 ✓
- new-view first render：register 在 SwiftUI 插入前同步设置 font，首帧即请求字号 ✓
- Local resize path：`sizeChanged → LocalProcessTerminalView.sizeChanged → setWinSize ioctl TIOCSWINSZ` ✓
- Remote resize path：`sizeChanged → RemoteTerminalService.sizeChanged → resizeChannelPTY` ✓
- remote serialization：经 SSHConnection actor 串行 ✓
- explicit resize necessity：不需要（font setter 已内置）✓
- existing-session update：weak registry + apply 同构 Appearance ✓
- registry recommendation：A（新建 weak registry，不合并 / 不复用）✓
- controller/coordinator decision：合并（无外部触发源）✓
- weak lifecycle：`NSHashTable.weakObjects()` ✓
- duplicate register：NSHashTable 幂等 + apply 幂等 ✓
- AppState ownership：strong owns controller ✓
- registration points：3 处（非 4 处，P3-2）✓
- Local new-view registration：createLocalSession 内 register ✓
- Remote new-view registration：runConnectFlow 内 register ✓
- backfill：AppState 装配末尾回填（与 Appearance/Highlight 同位置）✓
- Settings source：`$controller.size`，非 `view.font.pointSize` ✓
- no-active-terminal：registry 空 → apply no-op → persist 生效 ✓
- UserDefaults key：`macssh.terminalFontSize` ✓
- storage type：Int ✓
- default/min/max/step：14 / 10 / 32 / 1 ✓
- invalid numeric values：`object(forKey:) as? Int` 安全回退 14 ✓
- UserDefaults NSNumber behavior：方案正确 ✓
- normalization：clamp-on-load deterministic ✓
- persistence：`size.didSet` 同步 persist，单一 writer ✓
- Stepper recommendation：native `Stepper(value:in:10...32)` + Text ✓
- preview gate：AGENTS.md UI 规则要求 ✓
- direct input decision：v1 不允许 ✓
- boundary behavior：Stepper range 自动 disable + clamp 防御 ✓
- live update order：MainActor 同步链 ✓
- MainActor：controller + 全链路 ✓
- rapid-click ordering：MainActor 同步 + actor 串行 ✓
- font object creation：1 regular + 3 derived = 4 per change per view ✓
- provider API：保持 `regularFont(size:)` 不变 ✓
- source-of-truth architecture：单一 source ✓
- scrollback：`resetCaches` 不清 buffer，`terminal.resize` reflow 保留 ✓
- selection：font change 清除（SwiftTerm 既有行为，P3 可接受）✓
- cursor：`updateCaretView` 同步新 cellDimension ✓
- VS16：`TerminalOptions` 不变 ✓
- Highlight：rule range 基于 BufferLine，reflow 后重绘正确 ✓
- Right Sidebar：与 font change 经同一 sizeChanged，互不干扰 ✓
- Appearance：完全独立（不同 controller / key / Coordinator）✓
- tests：4 类核心 + Local/Remote resize + identity + Unicode + regression ✓
- Local resize test：spy sizeChanged delegate + setWinSize ✓
- Remote resize test：spy SSHConnection resizeChannelPTY ✓
- font identity tests：14/18/24 下 4 face 均为 JetBrainsMono ✓
- Unicode tests：ASCII / 中文 / Emoji / VS16 / 14/18/24 不 crash ✓
- regressions：Phase 2-8 全部 0 failure ✓
- SwiftTerm fork：不需要 ✓
- security：不触碰安全基线 ✓
- performance：低频触发 + 幂等 register ✓
- remaining P1：无 ✓
- remaining P2：无 ✓
- remaining P3：3 项（措辞 / 计数 / 清理遗漏）✓
- recommended Phase9B files：11 项 ✓
- recommended implementation sequence：13 步 ✓
- 是否允许进入 Phase9B：**允许** ✓
- final status：**CONDITIONAL PASS — STOP，等用户授权进入 Phase 9B 实现**

---

**STOP。等待用户授权进入 Phase 9B 实现。**

**未修改 production code / SwiftTerm fork / commit / merge / push / 未开始 Phase 9B。**
