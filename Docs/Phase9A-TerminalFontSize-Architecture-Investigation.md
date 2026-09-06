# MacSSH 1.1 Phase 9A — Architecture Investigation
# Configurable Terminal Font Size

> 角色：架构调查者（非 Phase 9B 开发者）。
> 方法：源码逐文件复核 + SwiftTerm fork API 逐方法验证 + Git baseline 独立确认。
> **未修改任何生产代码 / SwiftTerm fork / commit / merge / push / 未开始 Phase 9B。**
> 调查日期：2026-09-04。

---

## 0. Git baseline

| 项 | 值 |
|---|---|
| branch | `feature/macssh-1.1-terminal-font-size`（从 `main` 创建） |
| baseline SHA | `c6bf66c2b985530e6687fefe62cdf08246190e41` |
| working tree status | clean |

Phase 8 FINAL PASS 已确认：`Docs/Phase8B-Acceptance-Review.md` §1 = **PASS**。`main` HEAD `c6bf66c` 包含 Phase 8 全部实现与两轮 GUI remediation（`3d9b038 feat(appearance)` + `c6bf66c refactor(terminal)`）。Phase 9A 从此 baseline 创建分支，未 reset / clean。

---

## 67. Phase 9A 必须回答（21 问）

> 以下先回答 21 个核心问题，随后展开 76 节 Final Report。

1. **当前 14 pt 的真实 source of truth 在哪里？**
   `TerminalFontProvider.defaultSize: CGFloat = 14.0`（`TerminalFontProvider.swift:32`）。这是整个代码库中唯一一处实际字号定义。Settings 显示的 "14 pt" 是独立本地化字符串（`Localizable.xcstrings:3693`），与 runtime 无绑定关系。

2. **Settings 的 14 pt 是静态显示还是 runtime value？**
   **纯静态 label。** `SettingsView.swift:55-57`：`LabeledContent("settings.font_size") { Text("settings.font_size_value") }`。`settings.font_size_value` 在 zh/en 均为字面 "14 pt"（`Localizable.xcstrings:3699/3705`）。不绑定任何状态，改它不影响 runtime，runtime 变化也不更新它。

3. **Local font 从哪里设置？**
   `LocalTerminalService.init`（`LocalTerminalService.swift:40-44`）：`ScrollTrackingLocalProcessTerminalView(frame: .zero, font: TerminalFontProvider.regularFont(), options: options)`。`regularFont()` 默认参数 `size = defaultSize = 14.0`。

4. **Remote font 从哪里设置？**
   `RemoteTerminalService.init`（`RemoteTerminalService.swift:84-88`）：`TerminalView(frame: .zero, font: TerminalFontProvider.regularFont(), options: options)`。与 Local 同一入口。

5. **Local/Remote 是否共用 FontProvider？**
   **是。** 两者均调用 `TerminalFontProvider.regularFont()`（同一 enum、同一 `defaultSize`）。`TerminalFontProviderTests` 用例 I（"Local / Remote 共用同一 TerminalFontProvider 配置"）已验证。

6. **SwiftTerm runtime font API 是什么？**
   `TerminalView.font: NSFont`（`MacTerminalView.swift:339-348`）——**public computed property**，`get { fontSet.normal }`，`set { fontSet = FontSet(font: newValue); resetFont(); selectNone() }`。可从模块外直接赋值 `terminalView.font = newFont`。

7. **改 font 后是否自动重算 cell geometry？**
   **是。** `font` setter → `resetFont()`（`AppleTerminalView.swift:297`）→ `resetCaches()` + `cellDimension = computeFontDimensions()`（`:300-310`）。cell width/height 从新 font 的 CTFont 指标重算。

8. **是否自动触发 Terminal rows/cols resize？**
   **是（当 frame > 0 时）。** `resetFont()` 在 `frame.width > 0 && frame.height > 0` 时（`:301`）计算 `newCols`/`newRows` 并调用 `resize(cols:rows:)`（`:308`），后者调用 `terminal.resize()` + `sizeChanged(source:)`（`AppleTerminalView.swift:2839-2844`）→ `terminalDelegate?.sizeChanged(source:newCols:newRows:)`（`MacTerminalView.swift:3252`）。

9. **Local PTY resize 链是什么？**
   font setter → `resetFont` → `resize` → `sizeChanged(source: terminal)` → `MacTerminalView.sizeChanged` → `terminalDelegate?.sizeChanged` → **`LocalProcessTerminalView.sizeChanged`**（`MacLocalTerminalView.swift:104-112`）→ `getWindowSize()`（基于 `terminal.cols/rows` + `cellDimension` 像素）→ **`PseudoTerminalHelpers.setWinSize(masterPtyDescriptor:windowSize:)`**（`Pty.swift:117-122`，即 `ioctl(masterFd, TIOCSWINSZ, &winsize)`）→ `processDelegate?.sizeChanged`（`LocalTerminalService` 更新 `session.columns/rows` + scrollIndicator）。

10. **Remote PTY resize 链是什么？**
    font setter → `resetFont` → `resize` → `sizeChanged` → **`RemoteTerminalService.sizeChanged`**（`RemoteTerminalService.swift:446-468`）→ `connection.resizeChannelPTY(columns:newRows:)`（SSH Channel actor 内 `libssh2_channel_request_pty_size_ex`，经现有 Phase 7 实现）。

11. **如果 font setter 不触发 resize，最小显式方案是什么？**
    **font setter 已自动触发 resize（frame > 0 时），无需显式方案。** 唯一边界：frame == 0（view 未 layout）时 `resetFont` 跳过 `resize`，只更新 `cellDimension`。但此后 view 被 SwiftUI 插入并 `setFrameSize` 时，`processSizeChange`（`AppleTerminalView.swift:386`）用新 `cellDimension` 计算正确 cols/rows 并 resize。因此 frame == 0 不是缺陷，只是延迟到首次 layout。

12. **Existing sessions 如何统一更新？**
    新增 `TerminalFontSizeController`（`@MainActor @Observable`，weak `NSHashTable<TerminalView>` registry），`apply()` 遍历全部 live view 执行 `view.font = TerminalFontProvider.regularFont(size: CGFloat(size))`。模式与 `TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()`（`TerminalAppearanceCoordinator.swift:178-185`）完全同构。

13. **New sessions 如何使用最新 size？**
    `register(view)` 时立即 apply 当前 size（与 Appearance/Highlight Coordinator 的 `register` 立即 apply 同模式）。由于 register 在 Service 创建后、SwiftUI 插入前同步调用（`SessionManager.createLocalSession:130` / `runConnectFlow:447`），首帧即为请求字号，无 14→18 闪烁。

14. **是否需要新的 TerminalFontCoordinator？**
    **不需要单独的 Coordinator 类；推荐 `TerminalFontSizeController` 合并 preference + registry + broadcast。** 理由见 §29-§31。font 无外部触发源（无 KVO / 无系统信号），单一 writer 即单一 broadcaster，不需拆分。

15. **UserDefaults 如何设计？**
    key：`macssh.terminalFontSize`（加入 `AppPreferenceKey`，`AppLanguage.swift:46`）。value：`Int`。与 `AppPreferenceKey.appearanceMode`（`macssh.appearanceMode`）同模式。

16. **非法值策略是什么？**
    - key 缺失 / 类型不匹配（非 Int）→ fallback 14（`object(forKey:) as? Int` 返回 nil）
    - 合法 Int 超范围（< 10 或 > 32）→ clamp 到 10 / 32
    - NaN / Infinity → 无法存入 Int；若外部写入 Double，`as? Int` → nil → 14
    - Int 存储天然排除 NaN/Infinity，策略简洁可证明。

17. **Int / CGFloat 如何设计？**
    **persisted = Int**（10...32，step 1，无小数）；API boundary 转 `CGFloat`：`TerminalFontProvider.regularFont(size: CGFloat(controller.size))`。`TerminalFontProvider` 现有 API 已接受 `CGFloat`（`regularFont(size: CGFloat = defaultSize)`），无需改签名。

18. **Settings UI 推荐 +/- 还是 Stepper？**
    **native `Stepper`**（`Stepper(value:in:)` 绑定 `$controller.size`，range `10...32`）。最符合 macOS Settings 原生风格；自动处理 boundary disable；不需自定义按钮。详见 §40。

19. **是否允许 direct typing？**
    **v1 不允许（Stepper only）。** 避免非法字符 / 小数 / 空值 / 越界输入扩大校验面。Stepper + 步进 1 足够。留 future。

20. **是否需要 SwiftTerm fork change？**
    **不需要。** `TerminalView.font` public setter + `resetFont()` + `resize()` 完整覆盖 runtime font mutation + geometry recompute + PTY resize。SwiftTerm pin `771e79f` 不变，fork 不改。

21. **Phase 5/6/7/8 regression 风险？**
    - Phase 5（VS16）：`variationSelector16WidthPolicy` 在 `TerminalOptions`（init 时设），font change 不触碰 options → 无影响。
    - Phase 6（Highlight）：highlight range 基于 `BufferLine` cell 位置；font change → `resize` 保留 buffer → `needsDisplay` 触发重绘 → highlight 正确重绘。已验证 Coordinator broadcast 路径独立。
    - Phase 7（Command Sidebar / paste）：与 font 无关。
    - Phase 8（Appearance）：font 与 appearance 独立（不同 Coordinator、不同属性），互不触碰。
    详见 §53-§56。

---

## 68. Phase 9A Final Report（76 节）

### 1. branch
`feature/macssh-1.1-terminal-font-size`（从 `main` `c6bf66c` 创建，clean working tree）。

### 2. baseline SHA
`c6bf66c2b985530e6687fefe62cdf08246190e41`（main，含 Phase 8 FINAL PASS + 两轮 GUI remediation）。

### 3. production modifications
**无。** Phase 9A 纯调查，未修改任何生产代码 / SwiftTerm fork / 测试 / 本地化 / pbxproj。未 commit / merge / push。

### 4. current Settings font-size UI
`SettingsView.swift:55-57`：
```swift
LabeledContent("settings.font_size") {
    Text("settings.font_size_value")
}
```
纯只读 `LabeledContent` + 静态本地化 Text。无交互、无绑定。与 `settings.font`（"JetBrains Mono"，同样只读）和 `settings.scrollback`（"10,000 行"，同样只读）并列于 `Section("settings.section.terminal")`。

### 5. current displayed size
Settings 显示 **"14 pt"**（`Localizable.xcstrings:3693-3708`，zh/en 均为字面 "14 pt"）。静态字符串，不从 runtime 读取。

### 6. actual runtime size
**14.0 pt。** 证实链：`LocalTerminalService.swift:42` `TerminalFontProvider.regularFont()` → `TerminalFontProvider.swift:215` `regularFont(size: defaultSize)` → `TerminalFontProvider.swift:32` `defaultSize = 14.0`。Remote 同路径（`RemoteTerminalService.swift:86`）。UI 显示与 runtime 一致（均为 14），但两者无绑定关系——UI 是巧合的静态字符串。

### 7. current source of truth
**`TerminalFontProvider.defaultSize: CGFloat = 14.0`**（`TerminalFontProvider.swift:31-32`）。

全代码库字号引用点（`search_content` "defaultSize|fontSize|font_size" 结果）：
- `TerminalFontProvider.swift:32` — `defaultSize = 14.0`（**唯一实际字号定义**）
- `TerminalFontProvider.swift:215/221/227/233` — `regularFont/boldFont/italicFont/boldItalicFont(size: defaultSize)` 默认参数
- `TerminalFontProvider.swift:311/321/326/331/336` — 验证 helper（用 `defaultSize` 创建验证用 NSFont）
- `SettingsView.swift:55-56` — 静态 label（无 runtime 绑定）
- `Localizable.xcstrings:3676/3693` — 本地化字符串

`boldFont` / `italicFont` / `boldItalicFont`（`TerminalFontProvider.swift:221/227/233`）在生产代码中**无任何调用方**（`search_content` 确认仅定义处出现）——它们仅供 `TerminalFontProviderTests` 验证 PostScript name 与 bundle source。runtime TerminalView 只接收 `regularFont()`。

### 8. TerminalFontProvider
`enum TerminalFontProvider`（`TerminalFontProvider.swift:30`）——无实例状态的纯工具 enum。

职责：
- 注册 App Bundle 内 4 个 JetBrains Mono TTF（`registerBundledFontsIfNeeded`，`MacSSHApp.swift:23` 调用）
- 构造 Regular/Bold/Italic/BoldItalic NSFont（PostScript name → family+face → 系统等宽 fallback 三级）
- 附加 CJK（PingFang SC）+ Emoji（Apple Color Emoji）cascade（`applyCascade`，`NSFontDescriptor.cascadeList`）
- 验证 font 来源在 Bundle 内（`isFontSourcedFromBundle`，`kCTFontURLAttribute` + symlink-resolved prefix match）

字号通过 `defaultSize` 常量 + 各方法 `size: CGFloat = defaultSize` 默认参数传入。Phase 9B 只需在调用 `regularFont(size:)` 时传入 controller 的 Int→CGFloat，**不需修改 TerminalFontProvider 本身**。

### 9. bundled font family
JetBrains Mono（`TerminalFontProvider.swift:35` `baseFamily = "JetBrains Mono"`）。4 个 TTF 在 `Contents/Resources/`：
- `JetBrainsMono-Regular.ttf`
- `JetBrainsMono-Bold.ttf`
- `JetBrainsMono-Italic.ttf`
- `JetBrainsMono-BoldItalic.ttf`

Phase 2 已实现并验收。Phase 9A/9B **不重新注册、不修改 family、不修改 TTF 文件**。

### 10. fallback chain
`applyCascade`（`TerminalFontProvider.swift:279-289`）：
```swift
let cascadeList: [NSFontDescriptor] = [
    NSFontDescriptor(fontAttributes: [.family: cjkFallbackFamily]),   // PingFang SC
    NSFontDescriptor(fontAttributes: [.family: emojiFallbackFamily])  // Apple Color Emoji
]
let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: cascadeList])
return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
```
cascade descriptor **不指定 size**——CoreText 在渲染时按主 font 的 pointSize 自动缩放 cascade font。因此字号变化后 fallback 自动跟随。**不需额外处理 fallback size。**

### 11. Local creation path
```
SessionManager.createLocalSession() (SessionManager.swift:116)
  → LocalTerminalService(session:) (LocalTerminalService.swift:20)
    → TerminalFontProvider.regularFont() (size=14.0)          [font 构造]
    → ScrollTrackingLocalProcessTerminalView(frame:.zero, font:, options:)  [SwiftTerm init]
    → TerminalAppearanceProvider.applyCurrentAppAppearance(to:) [初始外观]
  → ManagedTerminalSession(localService:, ...)
  → terminalAppearanceCoordinator?.register(service.terminalView)  [Appearance 注册]
  → terminalHighlightCoordinator?.register(service.terminalView)    [Highlight 注册]
```
`ScrollTrackingLocalProcessTerminalView`（`TerminalScrollIndicatorController.swift:290`）是 `LocalProcessTerminalView` 的子类，后者是 `TerminalView` 的子类——`font` public setter 可用。

### 12. Remote creation path
```
SessionManager.runConnectFlow() (SessionManager.swift:393)
  → (认证成功后) RemoteTerminalService(connection:hostname:port:) (RemoteTerminalService.swift:65)
    → TerminalFontProvider.regularFont() (size=14.0)          [font 构造]
    → TerminalView(frame:.zero, font:, options:)               [SwiftTerm init]
    → TerminalAppearanceProvider.applyCurrentAppAppearance(to:) [初始外观]
  → session.attachRemoteService(service)
  → terminalAppearanceCoordinator?.register(service.terminalView)  [Appearance 注册]
  → terminalHighlightCoordinator?.register(service.terminalView)    [Highlight 注册]
  → service.startIfNeeded()
```
Local / Remote 在 font 构造与注册上**完全同源**（同一 `TerminalFontProvider.regularFont()`，同一注册模式）。

### 13. SwiftTerm font API
| API | 可见性 | 签名 | 位置 |
|-----|--------|------|------|
| `font` | **public** get/set | `public var font: NSFont { get { fontSet.normal } set { fontSet = FontSet(font:); resetFont(); selectNone() } }` | `MacTerminalView.swift:339-348` |
| `resize(cols:rows:)` | **public** | `public func resize(cols: Int, rows: Int)` | `AppleTerminalView.swift:2839` |
| `resetFontSize()` | **public** | `public func resetFontSize()` | `MacTerminalView.swift:3094` |
| `resetFont()` | internal | `func resetFont()` | `AppleTerminalView.swift:297` |
| `computeFontDimensions()` | internal | `func computeFontDimensions() -> CellDimension` | `AppleTerminalView.swift:410` |
| `processSizeChange(newSize:)` | internal | `func processSizeChange(newSize: CGSize) -> Bool` | `AppleTerminalView.swift:386` |

`nativeFont` 属性在 fork 中**不存在**（全目录 0 匹配）。

### 14. public/private status
`font` setter **public**——可从 MacSSH 模块外直接 `terminalView.font = newFont`。`resetFont()` / `computeFontDimensions()` / `processSizeChange()` 为 internal，但**不需直接调用**——font setter 已内部调用 `resetFont()`，后者在 frame > 0 时自动调用 `resize()`（public）。

### 15. runtime font mutation capability
**完全支持，纯 public API。** `terminalView.font = TerminalFontProvider.regularFont(size: 16.0)` 即可在运行时改变字号，自动触发完整重算链。SwiftTerm 自带测试验证此行为：
- `Tests/SwiftTermTests/FontResizeColumnsTests.swift:21-49` — font 变化后列数正确
- `Tests/SwiftTermTests/ProfileSupportTests.swift:265-272` — `view.font =` 改变 cellDimension

### 16. Regular/Bold/Italic/BoldItalic behavior
`FontSet`（`MacTerminalView.swift:150-182`）从单个 regular font 派生 4 变体：
```swift
public init(font baseFont: NSFont, fontSize: CGFloat? = nil) {
    self.normal = baseFont
    self.bold = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask])
    self.italic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask])
    self.boldItalic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask, .boldFontMask])
}
```
- 4 变体**同 pointSize**（`NSFontManager.convert(_:toHaveTrait:)` 保留输入 font 的 size）。
- 当前 MacSSH 只传 `regularFont()`，FontSet 自动派生 bold/italic/boldItalic——bundled Bold/Italic TTF 实际未被 TerminalView 直接使用（可能被 NSFontManager 找到 family member，或被合成；均不影响 Phase 9）。
- **Phase 9 含义**：一次 `view.font = regularFont(size: 16)` 赋值即可让 Regular/Bold/Italic/BoldItalic 全部变为 16 pt。不需分别设置 4 个 font。

### 17. fallback size behavior
`applyCascade` 的 cascade descriptor 无 size 字段（`NSFontDescriptor(fontAttributes: [.family:])`）。CoreText cascade 机制：渲染主 font 不覆盖的 Unicode 时，从 cascade list 按 family 匹配，并**自动缩放到主 font 的 pointSize**。因此字号 14→16 后，中文/Emoji fallback 自动以 16 pt 渲染，比例不变。**不需额外处理。**

### 18. cell width calculation
`computeFontDimensions()`（`AppleTerminalView.swift:410`）从 `fontSet.normal`（即 Regular）的 CTFont 指标计算：
```swift
let cellWidth = ceil(max(advanceWidth, boundingWidth))   // 取 ASCII advance 与 bounding box 的最大值
```
cellWidth 随 font size 线性增长（14→16 时 cellWidth 增大）。

### 19. cell height calculation
同 `computeFontDimensions()`：
```swift
let cellHeight = ceil((lineAscent + lineDescent + lineLeading) * _lineSpacing)
```
`lineAscent`/`lineDescent`/`lineLeading` 来自 `CTFontGetAscent/GetDescent/GetLeading(fontSet.normal)`，随 size 线性增长。`_lineSpacing = 1.0`（默认，不改）。

### 20. font-change geometry recompute
`resetFont()`（`AppleTerminalView.swift:297-317`）：
1. `resetCaches()` — 清空 color/attribute 缓存（**不**清 buffer/scrollback）
2. `cellDimension = computeFontDimensions()` — 重算 cellWidth/cellHeight
3. 若 `frame.width > 0 && frame.height > 0`：计算 newCols/newRows → `resize(cols:rows:)`
4. `updateCaretView()` — cursor frame 同步到新 cellDimension
5. `needsDisplay = true` — 重绘

### 21. cols/rows recompute
同 §20 第 3 步。`resize(cols:rows:)`（`AppleTerminalView.swift:2839-2844`）：
```swift
public func resize(cols: Int, rows: Int) {
    terminal.resize(cols: cols, rows: rows)  // buffer reflow（保留 scrollback）
    sizeChanged(source: terminal)            // → delegate.sizeChanged → PTY resize
    terminal.softReset()                     // DEC 模式复位（不清 buffer）
}
```
font 变大 → cellDimension 变大 → 同 frame 下 newCols/newRows 减小 → `terminal.resize` reflow + PTY 同步。

### 22. Local resize path
```
font setter → resetFont → resize(cols:rows:)
  → terminal.resize(cols:rows:)                     [buffer reflow]
  → sizeChanged(source: terminal)                   [AppleTerminalView.swift:2842]
    → MacTerminalView.sizeChanged(source:)           [MacTerminalView.swift:3251]
      → terminalDelegate?.sizeChanged(source:newCols:newRows:)  [:3252]
        → LocalProcessTerminalView.sizeChanged      [MacLocalTerminalView.swift:104]
          → getWindowSize()                         [基于 terminal.cols/rows + cellDimension 像素]
          → PseudoTerminalHelpers.setWinSize(...)   [Pty.swift:117, ioctl TIOCSWINSZ]
          → processDelegate?.sizeChanged(...)        [LocalTerminalService 更新 session.columns/rows]
```
**全自动**——font change 经 SwiftTerm 内部链路触发 `ioctl(TIOCSWINSZ)`，shell 立即收到新窗口尺寸。

### 23. Remote resize path
```
font setter → resetFont → resize(cols:rows:)
  → terminal.resize + sizeChanged(source:)
    → terminalDelegate?.sizeChanged(source:newCols:newRows:)
      → RemoteTerminalService.sizeChanged            [RemoteTerminalService.swift:446]
        → session.columns/rows = newCols/newRows
        → connection.resizeChannelPTY(columns:rows:) [SSHChannel actor, libssh2_channel_request_pty_size_ex]
```
**全自动**——font change 经 `sizeChanged` delegate 触发 `resizeChannelPTY`，远端 PTY window-change 立即同步。

### 24. resize trigger
font setter **自动触发** resize（frame > 0 时）。两条独立路径共享同一 `sizeChanged` delegate：
- 路径 A（font）：`font setter → resetFont → resize → sizeChanged`
- 路径 B（view resize）：`setFrameSize → processSizeChange → terminal.resize → sizeChanged`

两者都最终调用 `terminalDelegate?.sizeChanged`，由 Local/Remote Service 各自处理 PTY。font change 与 sidebar resize 组合时各自独立触发，最终状态一致。

### 25. need for explicit resize
**不需要显式 resize trigger。** font setter 已内置完整链路。唯一边界（frame == 0）由后续 `setFrameSize` 自动补偿。Phase 9B **不需**模拟 window resize / 改 frame ±1 / DispatchQueue 延迟 hack。

### 26. existing-session architecture
推荐 `TerminalFontSizeController`（`@MainActor @Observable`）持有 weak `NSHashTable<TerminalView>` registry，`apply()` 遍历全部 live view 执行 `view.font = TerminalFontProvider.regularFont(size: CGFloat(size))`。与 `TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()`（`TerminalAppearanceCoordinator.swift:178-185`）完全同构：
```swift
private func applyFontSizeToAllRegisteredViews() {
    let font = TerminalFontProvider.regularFont(size: CGFloat(size))
    for view in terminalViews.allObjects {
        view.font = font
    }
}
```
`font` setter 内部的 `resetFont()` 负责后续 geometry + PTY resize——controller 只管赋值，不重复 resize 逻辑。

### 27. new-session backfill
`register(view)` 在 Service 创建后同步调用（与 Appearance/Highlight 同注册点），立即 apply 当前 size：
```swift
func register(_ view: TerminalView) {
    terminalViews.add(view)
    view.font = TerminalFontProvider.regularFont(size: CGFloat(size))
}
```
此时 view frame 通常为 `.zero`（SwiftUI 尚未插入）→ `resetFont` 跳过 `resize`（frame 0），只更新 `cellDimension`。之后 SwiftUI `setFrameSize` → `processSizeChange` 用正确 `cellDimension` 计算 cols/rows。**首帧即请求字号，无 14→18 闪烁。**

### 28. registry options
现有两个独立 registry（均 `NSHashTable<TerminalView>.weakObjects()`）：
- `TerminalAppearanceCoordinator.terminalViews`（`TerminalAppearanceCoordinator.swift:43`）— color apply
- `TerminalHighlightCoordinator.terminalViews`（`TerminalHighlightCoordinator.swift:23`）— redraw broadcast

两者 apply 不同属性（颜色 vs 重绘信号），**不互相调用**。font 是第三种属性（NSFont），与前两者正交。

### 29. coordinator recommendation
**推荐新建 `TerminalFontSizeController`，合并 preference + registry + broadcast（不分 Coordinator）。**

理由：
1. font **无外部触发源**（无 KVO、无系统信号、无 `effectiveAppearance` 等价物）——不像 Appearance 需 KVO 安全网独立成 Coordinator。font 只在用户操作时变化。
2. 单一 writer 即单一 broadcaster——`size` didSet → persist + apply，全部 MainActor 同步，无异步 hop。
3. Appearance 的 Controller/Coordinator 拆分是因为 Coordinator（Phase 4）先于 Controller（Phase 8）存在；font 两者均新建，合并更简。
4. apply 逻辑极简（一行 `view.font =`），不需独立 Coordinator 承载复杂 palette 映射。
5. 与 `TerminalFontProvider`（无状态 enum，只生成 NSFont）职责严格分离：Provider 不知 preference，Controller 不知 font family/cascade。

### 30. controller recommendation
`TerminalFontSizeController`（`@MainActor @Observable`，仿 `AppAppearanceController`）：

```swift
@MainActor
@Observable
final class TerminalFontSizeController {
    private let userDefaults: UserDefaults
    private var terminalViews: NSHashTable<TerminalView> = .weakObjects()

    var size: Int {
        didSet {
            size = Self.clamp(size)          // 防越界（Stepper 已限制，防御性）
            userDefaults.set(size, forKey: AppPreferenceKey.terminalFontSize)
            applyFontSizeToAllRegisteredViews()
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.size = Self.load(from: userDefaults)
    }

    func register(_ view: TerminalView) {
        terminalViews.add(view)
        view.font = TerminalFontProvider.regularFont(size: CGFloat(size))
    }

    func setSize(_ newSize: Int) { size = newSize }
    func increase() { size += 1 }
    func decrease() { size -= 1 }

    private func applyFontSizeToAllRegisteredViews() {
        let font = TerminalFontProvider.regularFont(size: CGFloat(size))
        for view in terminalViews.allObjects { view.font = font }
    }

    // 测试 seam
    var registeredViewCountForTesting: Int { terminalViews.allObjects.count }
    func compactRegistryForTesting() { /* 同 HighlightCoordinator */ }
}
```

### 31. ownership
- **AppState strong owns** `TerminalFontSizeController`（`let terminalFontSizeController`，在 SessionManager 之前创建——SessionManager.init 创建首个 Local Session，AppState 末尾回填注册其 terminalView，与 Appearance/Highlight 同模式）。
- **TerminalView weak registered**（`NSHashTable.weakObjects()`，Session 关闭 / Service 释放后自动 nil）。
- SettingsView 经 `@Environment(AppState.self)` + `@Bindable` 绑定 `$controller.size`——不 strong retain TerminalView。

### 32. preference architecture
集中 key 定义于 `AppPreferenceKey`（`AppLanguage.swift:46-54`）：
```swift
enum AppPreferenceKey {
    static let language = "appLanguage"
    static let rightSidebarVisible = "macssh.rightSidebarVisible"
    static let rightSidebarTab = "macssh.rightSidebarTab"
    static let appearanceMode = "macssh.appearanceMode"
    static let terminalFontSize = "macssh.terminalFontSize"   // Phase 9 新增
}
```
与 `AppAppearanceMode.load/save` 同模式：`TerminalFontSizeController.init` 调 `Self.load(from:)`，`size.didSet` 调 `userDefaults.set(size, forKey:)`。无裸字符串散落。

### 33. UserDefaults key
`macssh.terminalFontSize`（`AppPreferenceKey.terminalFontSize`）。

### 34. default
**14**（`TerminalFontSize.defaultSize = 14`，与 `TerminalFontProvider.defaultSize` 一致）。老用户无该 key 时返回 14，行为与现状完全相同。

### 35. min/max
- min = **10**
- max = **32**

### 36. step
**1**（`Stepper` 默认步进；`increase()`/`decrease()` ±1）。

### 37. invalid-value handling
```swift
static func load(from defaults: UserDefaults) -> Int {
    guard let stored = defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int else {
        return defaultSize      // 缺失 / 非 Int → 14
    }
    return clamp(stored)         // 合法 Int 越界 → clamp 10...32
}

static func clamp(_ value: Int) -> Int {
    min(max(value, 10), 32)
}
```
- 缺失 key → 14
- 非 Int 类型（Double / String / Bool / NaN-via-Double）→ `as? Int` = nil → 14
- 合法 Int < 10 → 10（clamp）
- 合法 Int > 32 → 32（clamp）
- NaN / Infinity → 无法存为 Int；若外部写入 Double.nan → `as? Int` = nil → 14

满足 §8 策略 A（超范围 clamp）+ B（无效 fallback 14）。

### 38. Int/CGFloat
- **persisted = Int**：10...32 step 1，无小数需求；Int 天然排除 NaN/Infinity，校验面最小。
- **API boundary = CGFloat**：`TerminalFontProvider.regularFont(size: CGFloat(controller.size))`。`TerminalFontProvider` 现有 API 已用 `CGFloat`，不需改。
- Stepper 绑定 `Int`——SwiftUI `Stepper(value:in:)` 对 `Int` range 原生支持，boundary 自动 disable。

### 39. settings binding
SettingsView 经 `@Bindable var appState` 访问 `appState.terminalFontSizeController`，Stepper 绑定 `$controller.size`：
```swift
LabeledContent("settings.font_size") {
    Stepper(value: $controller.size, in: 10...32) {
        Text("\(controller.size) pt")
    }
}
```
**不是 local `@State`**——绑定 shared controller，单一 source of truth。无 terminal session 时仍可修改（registry 空 → apply no-op → persist 生效）。

### 40. UI recommendation
**native `Stepper(value:in:10...32)` + `Text("\(size) pt")`**。

理由：
- 最符合 macOS Settings 原生风格（与 Appearance `Picker(.menu)` 同级）。
- Stepper 自动在 boundary disable +/−（10 时 minus disabled，32 时 plus disabled）。
- 步进 1，无需自定义按钮逻辑。
- VoiceOver 读出 "14" + "pt"（`Text` 自动组合 accessibility value）。

备选方案（`－ 14 pt ＋` 自定义按钮）可行但增加无谓复杂度，不推荐。

### 41. UI preview requirement
按 `AGENTS.md` UI 规则，Phase 9B 修改 `SettingsView` 前必须先给用户 preview，至少展示：
- 方案 A：`Stepper(value:in:)` + `Text`（推荐）
- 方案 B：`－ / ＋` 自定义 `Button`

用户确认后才改 SettingsView production code。

### 42. boundary behavior
`Stepper(value: $controller.size, in: 10...32)`：
- 10 时 **minus disabled**（SwiftUI 原生 `in:` range 语义）
- 32 时 **plus disabled**
- 不越界

`controller.size.didSet` 内 `Self.clamp(size)` 作防御性二次保障（Stepper 已限制，但 `setSize(_:)` / 外部调用方可能越界）。

### 43. direct edit decision
**v1 不允许 direct typing（Stepper only）。** 无 TextField、无数字输入框。避免非法字符 / 小数 / 空值 / 越界扩大校验面。留 future。

### 44. localization
现有 key：
- `settings.font_size`（label）→ "Font size" / "字体大小"（已存在，`Localizable.xcstrings:3676`）——**复用**
- `settings.font_size_value`（静态 "14 pt"）→ **删除**（被 Stepper + 动态 Text 替代，不再需要静态值字符串）

Phase 9B 需新增 accessibility tooltip key（若使用 Stepper 则 VoiceOver 自动读出数字 + "pt"；不需额外 tooltip key）。`LocalizationTests.testCatalogHasNoObsoleteKeys` 会检测删除的 `settings.font_size_value`——需确保从 xcstrings 移除且源码不再引用。

### 45. accessibility
- Stepper label = "字体大小" / "Font size"（复用 `settings.font_size`）
- Stepper value text = `"\(size) pt"`——VoiceOver 读出 "14 point"（macOS VoiceOver 把 "pt" 读作 "point" 或字母 P-T，均可接受）
- 若需显式 accessibility label for +/- buttons，SwiftUI Stepper 原生提供 `.accessibilityLabel`；可加 `Text` 隐式 label
- 不需额外 "Decrease/Increase Terminal Font Size" tooltip——native Stepper 已自带

### 46. MainActor/threading
- `TerminalFontSizeController` 标注 `@MainActor`（仿 `AppAppearanceController`）
- `size.didSet` → persist（`UserDefaults.set` thread-safe）+ apply（`view.font =` 必须 main thread）
- `register(view)` 在 MainActor 调用（SessionManager `@MainActor`）
- `applyFontSizeToAllRegisteredViews` 在 MainActor
- `TerminalView.font` setter 内部 `resetFont()` / `resize()` / `needsDisplay` 均 main thread（SwiftTerm macOS 约束）
- 全链路同步 MainActor，无 `Task { @MainActor in }` 异步 hop

### 47. rapid-click ordering
- 全 MainActor 同步：用户快速 14→15→16→17→18 每次 `size.didSet` 同步 persist + apply
- 每次 apply 同步 `view.font =` → `resetFont()` → `resize()` → `sizeChanged` → PTY resize
- 无异步队列、无 reordering 风险
- 最终 terminal 停在最后一次值（18），与用户最后操作一致

### 48. persistence/restart
- quit 前：`size = 18` → `didSet` 已 persist `macssh.terminalFontSize = 18`
- relaunch：`AppState.init` → `TerminalFontSizeController.init` → `load(from:)` → 18
- Settings Stepper 显示 18
- 新建 Local/Remote Terminal：register 时 `view.font = regularFont(size: 18)` → 首帧 18
- **无 flash**：register 在 SwiftUI 插入 view 前同步调用（frame .zero → resetFont 跳过 resize，只更新 cellDimension；setFrameSize 时用正确 cellDimension）

### 49. launch timing
不需像 Appearance 那样在 Window launch 前 apply：
- Appearance 需 `NSApp.appearance` 在窗口可见前设置（否则首帧颜色错误 + launch flash）
- Font 只在 TerminalView 创建时才需要——`TerminalFontSizeController` 在 SessionManager 前创建即可（load preference），register 在 Service 创建后调用
- AppState.init 顺序：coordinator → controller → SessionManager（与 Appearance 同模式），controller init 时 registry 空、apply no-op

不存在 flash（§48 已证）。

### 50. scrollback impact
- `resetFont()` → `resetCaches()` 清空 color/attribute 缓存，**不**清 buffer
- `resize(cols:rows:)` → `terminal.resize()` reflow buffer（保留 scrollback，只重新排列行列）
- `terminal.softReset()` 复位 DEC 模式，**不清 buffer**
- 现有 scrollback 内容保留——font change 是 presentation-only + geometry reflow，不丢失 terminal text model
- Phase 9B 须测试验证（§57）

### 51. cursor impact
`resetFont()` → `updateCaretView()`（`AppleTerminalView.swift:310` / `:319-324`）：
```swift
caretView.frame.size = CGSize(width: cellDimension.width, height: cellDimension.height)
caretView.updateCursorStyle()
```
cursor frame 同步到新 cellDimension，不会停在旧字号 geometry。

### 52. selection impact
`processSizeChange`（`AppleTerminalView.swift:394`）在 cols/rows 变化时 `selection.active = false`——已有选区在 font change 后被清除。这是合理行为（cell geometry 变化后选区位置无意义），不是缺陷。font setter 的 `selectNone()`（`MacTerminalView.swift:346`）也清除选区。

### 53. VS16 impact
`variationSelector16WidthPolicy` 存于 `TerminalOptions`（`LocalTerminalService.swift:38` `.preserveBaseWidth` / Remote 默认 `.widenToEmojiWidth`），在 init 时设入 `Terminal`。font change → `resetFont` → `resize` → `terminal.resize` 不修改 `options`。VS16 width policy 不变。⚠️❤️ 等 emoji cell width policy 保持。

### 54. Highlight impact
`TerminalHighlightCoordinator.broadcastRedrawToAllRegisteredViews`（`TerminalHighlightCoordinator.swift:87-94`）调用 `terminal.updateFullScreen()` + `needsDisplay`。font change 的 `resetFont` 也设 `needsDisplay = true`。highlight rule range 基于 `BufferLine` cell 位置——`terminal.resize` reflow 后 buffer 内容保留，highlight 在重绘时重新匹配，位置正确。两个 Coordinator 独立注册同一批 view，font apply 与 highlight redraw 不冲突。

### 55. Right Sidebar impact
Sidebar open/close → `setFrameSize` → `processSizeChange` → `sizeChanged` → PTY resize。font change → `resetFont` → `resize` → `sizeChanged` → PTY resize。两者经同一 `sizeChanged` delegate，互不干扰：
- Sidebar open + 14→18：font change 触发 resize（基于当前 frame）；Sidebar 已 open，frame 不变；PTY 收到最终 cols/rows（更少，因 font 更大）。正确。
- Sidebar close + font change：close 触发 setFrameSize（frame 变宽）→ recompute → PTY resize；font change 独立触发 resize。最终一致。
无组合 bug 风险——两者都走 SwiftTerm 内部 resize 机制。

### 56. Appearance impact
- font preference 与 appearance preference 完全独立（不同 controller、不同 Coordinator、不同 UserDefaults key）
- 切 Light/Dark：`AppAppearanceController.apply()` → `NSApp.appearance` + `TerminalAppearanceCoordinator.applyCurrentAppearance()`（只 apply color palette）——**不触碰 font**
- 切 font size：`TerminalFontSizeController.apply()` 只 `view.font =` ——**不触碰 color**
- 重启：appearance 从 `macssh.appearanceMode` load，font 从 `macssh.terminalFontSize` load，各自保持
- 两个 Coordinator 的 `register` 在同一注册点调用（SessionManager / AppState），对同一批 view 各自 apply 正交属性

### 57. test plan
Phase 9B 至少规划：

| 测试类 | 覆盖 |
|--------|------|
| `TerminalFontSizeControllerTests` | preference load/clamp/persist/apply/register/broadcast |
| `TerminalFontResizeTests` | font change → cellDimension 变化 → cols/rows 变化 → sizeChanged 触发 |
| `TerminalFontSizeCoordinatorRegressionTests` | existing/new view 更新 + scrollback/cursor/selection 回归 |
| `SettingsView` 状态测试 | Stepper 绑定 + boundary disable |

### 58. preference tests
覆盖：
- default 14（无 key）
- save 10 / save 14 / save 32 → reload 一致
- below min：9 → clamp 10
- above max：33 → clamp 32
- invalid type（Double 17.5 / String / Bool）→ 14
- NaN-via-Double → 14
- `load(from:)` 不 crash、不删除其他 key

### 59. existing-view tests
- 注册 Local A + Local B + Remote C（3 view）
- size 14→16
- 断言 3 view 全部 `view.font.pointSize == 16`
- 断言 `sizeChanged` delegate 被调用（PTY resize 发生）

### 60. new-view tests
- 当前 size = 18
- register new view
- 断言 `view.font.pointSize == 18`（立即，不需二次 apply）

### 61. geometry tests
- 14→18：`cellDimension.width` / `cellDimension.height` 应增大
- 18→14：应减小
- 断言 `cellDimension` 与 `computeFontDimensions()` 一致

### 62. Local resize tests
- 固定 viewport，14→18
- 断言 `session.columns` 减小、`session.rows` 减小
- 断言 `PseudoTerminalHelpers.setWinSize` 被调用（或 `processDelegate.sizeChanged` 收到新值）
- 不只测 `view.font` property

### 63. Remote resize tests
- 固定 viewport，14→18
- 断言 `connection.resizeChannelPTY` 被调用（可用 mock connection / spy）
- 断言 `session.columns/rows` 更新

### 64. regression tests
- **Scrollback**：写入多行 → font change → scrollback 内容仍存在（feed → change → read buffer）
- **Cursor**：font change → `caretView.frame.size` == 新 cellDimension
- **Selection**：有选区 → font change → `selection.active == false`（预期清除）
- **VS16**：⚠️❤️ font change 前后 cell width policy 不变（options 未改）
- **Highlight**：有 rule → font change → rule range 不变、视觉重绘

### 65. performance
font update 仅发生：用户改字号（低频）/ new Terminal register（一次性）/ launch load（一次）。**不**每 frame / 每 keypress / Timer polling 重新创建 font。`regularFont(size:)` 内 `registerBundledFontsIfNeeded()` 幂等（`didAttemptRegistration` guard）。acceptable。

### 66. security
Phase 9 不修改：Keychain / CredentialService / KnownHost / SSH auth / SFTP / libssh2 / OpenSSL / Entitlements / Hardened Runtime / SwiftTerm fork。git diff 仅含 font preference 相关文件（Controller / SettingsView / AppState / SessionManager / Localizable.xcstrings / AppLanguage / pbxproj + Docs + Tests）。安全基线不触碰。

### 67. SwiftTerm SHA
`771e79f092a26e7fba7af0ab2b09a2bf10213109`（`macssh-public-paste-api` 分支，`canbyte0/SwiftTerm.git`，pbxproj `XCRemoteSwiftPackageReference kind=revision`）。**不变。**

### 68. need for SwiftTerm fork
**不需要 fork change。** `TerminalView.font` public setter + `resetFont()` + `resize()` + `sizeChanged` delegate 完整覆盖：
- runtime font mutation（public `font` setter）
- cell geometry recompute（`resetFont` → `computeFontDimensions`）
- cols/rows recompute（`resetFont` → `resize`，frame > 0 时）
- Local PTY resize（`sizeChanged` → `LocalProcessTerminalView.sizeChanged` → `setWinSize` ioctl TIOCSWINSZ）
- Remote PTY resize（`sizeChanged` → `RemoteTerminalService.sizeChanged` → `resizeChannelPTY`）
- cursor realign（`resetFont` → `updateCaretView`）
- redraw（`resetFont` → `needsDisplay`）

纯 public API 即可实现全部需求。无 blocker。

### 69. P1 risks
**无 P1。** 逐项核查：
- **App crash**：`TerminalFontSizeController.init` 只读 UserDefaults + 存 Int；`apply()` 对空 registry no-op；`view.font =` 经 SwiftTerm public API（已有测试）。无 fatalError / 无网络 / 无 SwiftData。
- **PTY resize crash**：`sizeChanged` → `setWinSize` / `resizeChannelPTY` 是现有已验证路径（Phase 2/7）；font change 只增加一个触发源，不改 resize 实现。
- **font load failure**：`TerminalFontProvider` 已有三级 fallback（PostScript → family+face → 系统等宽），size 参数只影响 pointSize 不影响 fallback 链。
- **UserDefaults corruption**：`load(from:)` 对非 Int / 缺失安全回退 14，不 crash。
- **TerminalView leak**：`NSHashTable.weakObjects()`，Session 关闭后自动 nil。

### 70. P2 risks
**无 P2。** 候选核查：
- **existing Terminal 不刷新**：`apply()` 遍历全部 live view `view.font =`——与 Appearance `applyCurrentAppearance()` 同构（已验证 3 view 全刷新）。
- **new Terminal 用旧字号**：`register` 立即 apply 当前 size——与 Appearance `register` 同模式（已验证新建 view 立即正确）。
- **requested/persisted 分歧**：`size.didSet` 同时 persist + apply，requested 与 persisted 始终一致。
- **launch flash**：register 在 Service 创建后、SwiftUI 插入前同步调用（frame .zero → resetFont 跳过 resize → 首次 setFrameSize 用正确 cellDimension）。无可见 flash。
- **rapid click 乱序**：全 MainActor 同步，天然顺序。
- **Localization obsolete key**：删 `settings.font_size_value` 需同步从 xcstrings 移除 + 源码不再引用 → `testCatalogHasNoObsoleteKeys` PASS。

### 71. P3 risks
- **background tab frame > 0**：非激活 Tab 的 TerminalView 保留上次 frame（非 .zero），font change 时 `resetFont` 会 `resize`（基于旧 frame + 新 cellDimension）。当用户切回该 Tab，SwiftUI `setFrameSize` 重新 `processSizeChange` → 最终 cols/rows 正确。中间可能有一次额外 PTY resize（旧 frame 算出的 cols/rows），但最终一致。harmless。
- **selection 清除**：font change 清除已有选区（§52）。属合理行为，但用户可能意外。可在 Settings 无明确提示。留 GUI 验收。
- **`softReset()` 副作用**：`resize()` 调 `terminal.softReset()` 复位部分 DEC 模式。若 shell 依赖某些模式（如 alternate screen），font change 后需重新设置。属 SwiftTerm 既有行为（sidebar resize 也走同路径），非 Phase 9 新增风险。

### 72. recommended Phase 9B files
| 文件 | 操作 | 内容 |
|------|------|------|
| `App/TerminalFontSizeController.swift` | **新建** | `@MainActor @Observable` controller + registry + load/clamp/persist/apply |
| `App/AppLanguage.swift` | 编辑 | `AppPreferenceKey` +`terminalFontSize` |
| `App/AppState.swift` | 编辑 | +`let terminalFontSizeController`（SessionManager 前创建）+ 回填注册初始 local session |
| `Services/Terminal/SessionManager.swift` | 编辑 | +`weak terminalFontSizeController` + 4 处 `register`（createLocal + runConnectFlow remote + AppState 回填已有） |
| `Features/Settings/SettingsView.swift` | 编辑 | 替换静态 `Text` 为 `Stepper(value:in:)` + 动态 `Text("\(size) pt")` |
| `Resources/Localizable.xcstrings` | 编辑 | 删 `settings.font_size_value`（保留 `settings.font_size`）|
| `MacSSH.xcodeproj/project.pbxproj` | 编辑 | +`TerminalFontSizeController.swift` file ref |
| `Tests/SSH/TerminalFontSizeControllerTests.swift` | **新建** | preference + register + broadcast 测试 |
| `Tests/SSH/TerminalFontResizeTests.swift` | **新建** | geometry + PTY resize 测试 |
| `Docs/Phase9B-Final-Report.md` | **新建** | 实现报告 |

### 73. recommended implementation sequence
1. `AppPreferenceKey.terminalFontSize` + `TerminalFontSizeController`（含 load/clamp/persist/apply/register + 测试 seam）
2. `TerminalFontSizeControllerTests`（preference tests，§58）——先验证 preference 层
3. `AppState` 装配（SessionManager 前创建 controller + 回填注册初始 local）
4. `SessionManager` 4 处 register（createLocal + runConnectFlow remote new）+ `weak` 引用
5. `TerminalFontResizeTests`（geometry + PTY resize，§61-63）——验证 resize 链
6. `TerminalFontSizeCoordinatorRegressionTests`（existing/new view + scrollback/cursor/selection，§59/60/64）
7. **UI preview gate**：出 Stepper + Text 预览，用户确认
8. `SettingsView` 替换静态行为 Stepper（用户确认后）
9. `Localizable.xcstrings` 删 `settings.font_size_value`
10. `LocalizationTests` 回归（obsolete key gate）
11. fresh DerivedData Debug+Release clean build + 全 MacSSH 测试
12. `Phase9B-Final-Report.md`

### 74. known limitations
- v1 不支持 direct typing（Stepper only）——留 future
- v1 不支持 ⌘+/⌘-/⌘0 快捷键——留 future
- v1 不支持非整数字号（如 14.5）——Int only
- font change 清除已有选区（SwiftTerm 既有行为，非 Phase 9 新增，但用户可感知）
- background tab font change 触发一次基于旧 frame 的 PTY resize（中间态，最终一致）

### 75. 是否建议进入 Phase 9B
**建议进入 Phase 9B。**

理由：
- source of truth 单一（`TerminalFontProvider.defaultSize`），迁移路径清晰
- SwiftTerm public `font` setter 完整覆盖 runtime mutation + geometry recompute + PTY resize（Local + Remote）——**无 fork change、无 blocker**
- 现有 registry pattern（Appearance/Highlight Coordinator）可直接复用
- 现有 preference pattern（`AppAppearanceController`/`AppAppearanceMode`/`AppPreferenceKey`）可直接复用
- 无 P1/P2 风险
- Phase 5/6/7/8 regression 风险可控（均已分析，有对应测试规划）
- 与计划书 §46 无冲突（不重新打包字体、不改 family、不改 fallback）

### 76. final status

**PHASE 9A ARCHITECTURE INVESTIGATION COMPLETE — 建议进入 Phase 9B。**

- branch `feature/macssh-1.1-terminal-font-size` 已创建（baseline `c6bf66c`）
- 未修改生产代码 / SwiftTerm fork / commit / merge / push
- 76 节调查结论明确，21 问全部回答
- SwiftTerm pin `771e79f` 不变，fork 不改
- 无 P1/P2 阻断项

**STOP。等待独立架构验收。**
