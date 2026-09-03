# MacSSH 1.1 Phase 6A — Terminal String Highlighting Architecture Investigation Report

Phase 6A 是**调查阶段**：只读源码 + 独立 probe，未修改生产代码 / SwiftTerm fork / commit / merge / push。等待独立架构验收后才进入 Phase 6B。

---

## 1. 当前 branch / baseline

| 项 | 值 |
| --- | --- |
| 当前 branch | `main`（领先 `github/main` 3 commits，working tree clean） |
| SwiftTerm 依赖 | `https://github.com/canbyte0/SwiftTerm.git`，exact revision `8a5187fe8182bac3a01f2b82d2621993de5886be` |
| Upstream base | `464df5207fc2432e16c9a23abe538187196daf5f`（SwiftTerm 1.19.0） |
| Fork patch | Phase 5 `VariationSelector16WidthPolicy` opt-in（`macssh-vs16-preserve-base-width`） |
| 本地 checkout | `/Users/msl/Library/Developer/Xcode/DerivedData/MacSSH-glkebqnnqzgjtdfygweagkhwaxte/SourcePackages/checkouts/SwiftTerm-fork` |

## 2. Phase 6A 是否修改生产代码

**否**。所有调查只读取源码；唯一写文件位置是 `/tmp/highlight-probe/`（独立 SPM 实验包，不属 MacSSH 工程，不复用 MacSSH target）。MacSSH 工程树、SwiftTerm fork、`Package.resolved`、`Tests/` 均未改动。无 commit / push。

---

## 3. SwiftTerm 当前 highlight / search 能力

SwiftTerm 1.19.0 + Phase 5 patch 已具备**完整的搜索基础设施**（移植自 xterm.js search addon），全部以 internal 方式提供：

| 文件 | 行数 | 角色 |
| --- | ---: | --- |
| `SearchEngine.swift` | 380 | literal + regex + wholeWord 匹配；wrap-aware 单逻辑行搜索；string-offset ↔ cell-offset 双向映射 |
| `SearchService.swift` | 138 | 状态包装：`findNext` / `findPrevious` / `findAll`（`defaultHighlightLimit = 1000`）；含 `selectionRange(for:)` |
| `SearchLineCache.swift` | 105 | 单行翻译缓存（TTL 15s）；`translateBufferLineToStringWithWrap` 拼接 wrap 续行 |
| `SearchOptions.swift` | 25 | public struct：`caseSensitive` / `regex` / `wholeWord` |
| `SearchState.swift` | 34 | 上次 term / options 缓存 |
| `TerminalViewSearch.swift` | 127 | public API：`findNext` / `findPrevious` / `clearSearch` / `searchMatchSummary` |
| `Mac/MacFindBarView.swift` | 167 | AppKit Find Bar UI（NSSearchField + prev/next/close + Aa/.*/Word 开关） |
| `SelectionService.swift` | 682 | selection 状态、Position 几何、`getSelectedText()` |

**关键能力**：
- search **只改变 presentation**：`TerminalViewSearch.applySearchResult` 调 `selection.setSelection(start:end:)`，**不写 buffer / PTY / parser**。结果表示为 `SearchResult { term, col, row, size }` → `Position` 对（buffer 坐标）。
- `SearchService.findAll` 已支持「全部匹配 + 上限」——这是高亮的多匹配基础。
- string-offset → cell-offset 的精确算法（`stringLengthToBufferSize`）已存在并已处理 wide-char + width-0 续接格。

## 4. Search 实现位置

- 引擎：`Sources/SwiftTerm/SearchEngine.swift` `findInLine` —— 输入 = `terminal.displayBuffer.lines[row]`（**model 层**，非 byte stream、非渲染字符串），经 `SearchLineCache.translateBufferLineToStringWithWrap` 翻译成 String 后做 `range(of:options:range:)`，再用 `stringLengthToBufferSize` / `bufferColsToStringOffset` 双向映射回 cell 列。
- Service：`Sources/SwiftTerm/SearchService.swift`。
- 公共 API：`Sources/SwiftTerm/TerminalViewSearch.swift`（`TerminalView` extension）。
- MacSSH 当前**未集成** FindBar / `findNext`（grep `MacSSH/**/*.swift` 命中 0）——SwiftTerm 自带但 MacSSH 未启用。Phase 6 可独立复用引擎内部逻辑。

## 5. Selection 实现位置

`Sources/SwiftTerm/SelectionService.swift`：
- 状态：`start` / `end` / `pivot`（`Position` = buffer col/row）；`active` / `hasSelectionRange`。
- 几何：buffer 坐标，天然跨 wrap 行、跨 scrollback（buffer 行号 = `yDisp + screen row`）。
- 渲染接入：`AppleTerminalView.selectedColumnsRange(row:cols:)` → `isColumnSelected(_:column:width:)` → 在 `buildAttributedString` 里把选中 cell 的 attribute 切到 `selectedTextBackgroundColor` + `selectedTextForegroundColor`（见 §7）。
- 复制：`getSelectedText()` → `terminal.getDisplayText(start:end:)` → `getText(start:end:buffer:)` —— **直接读 buffer 文本，不读 attribute**，因此 selection 染色不影响复制（probe 已验证：复制 "ERROR" 行返回纯 "ERROR"）。
- `SelectionService` 不修改 `Buffer` / `BufferLine` / `CharData`。

## 6. Renderer pipeline（完整调用链）

```
Terminal (model)
  │  buffer: Buffer  (private(set) public)
  │   └─ lines: CircularBufferLineList  (internal)  ← 行数组
  │        └─ BufferLine  (public final class)
  │             └─ data: [CharData]  (internal storage)
  │                  ├─ code: Int32      (internal) ← scalar
  │                  ├─ width: Int8      (public private(set))
  │                  └─ attribute: Attribute (public)
  ▼
TerminalView / AppleTerminalView / MacTerminalView (NSView)
  │  draw(_:)  →  drawTerminalContents(dirtyRect:context:bufferOffset:)
  │   ├─ for row in firstRow...lastRow (viewport 相对 yDisp):
  │   │    1. line = displayBuffer.lines[row]
  │   │    2. lineInfo = buildAttributedString(row:line:cols:)   ← ★ hook point A
  │   │    3. preparedSegments: CTLine + CTRun 提取
  │   │    4. Background fill loop（CG context.fill）             ← ★ hook point B
  │   │         优先级：selectionBackgroundColor  >  backgroundColor(ANSI)
  │   │    5. Kitty/Block/Box/Powerline 装饰
  │   │    6. Glyph drawing loop（CTFontDrawGlyphs）            ← ★ hook point C
  │   │    7. drawRunAttributes（underline / strikethrough）
  │   └─ end-for
  ▼
Pixels
```

**两条渲染路径共用 `buildAttributedString`**：
- CoreGraphics 路径（默认）：`MacTerminalView.draw(_:)` → `drawTerminalContents`。
- Metal 路径（opt-in，MacSSH **未启用** `setUseMetal`）：`MetalTerminalRenderer` 同样调 `terminalView.buildAttributedString(row:line:cols:)`（`MetalTerminalRenderer.swift:923`），背景填充优先级逻辑相同（`selectionBackgroundColor ?? backgroundColor`，line 1144）。

因此 **fork patch 只需改 `buildAttributedString` 一处**即可同时覆盖两条渲染路径。

## 7. 最佳 hook point

**`AppleTerminalView.buildAttributedString(row:line:cols:)`**（AppleTerminalView.swift:1041）——这是 cell → NSAttributedString 的统一构建点，已经：
1. 逐 cell 遍历 `line[col]`；
2. 计算每个 cell 的 `isSelected = isColumnSelected(selectionColumns, column:col, width:width)`；
3. 当 `isSelected != lastIsSelected` 时 flush 当前 batch 并切换 attribute：`batchAttributes[.selectionBackgroundColor] = selectedTextBackgroundColor`、`batchAttributes[.foregroundColor] = selectedTextForegroundColor`。

**Phase 6B 的最小改动**：在同一个 `isSelected` 判定旁加 `isHighlighted` 判定，按下方优先级组合 background。一行代码量级 = 数十行，不动 cell 文本、不动 `CharData`、不动 `Buffer`、不动 PTY。

## 8. 是否需要 SwiftTerm fork patch

**需要 —— 方案 C**（fork patch）。

理由（与方案 A/B 比较）：

| 方案 | 可行性 | 原因 |
| --- | --- | --- |
| A. 完全 MacSSH 层实现 | **否决** | 高亮的 background 必须在 `buildAttributedString` 内决定 batch boundary（何时 flush pending text、何时切换 attribute dict）。该方法是 `AppleTerminalView` 的 internal 方法，MacSSH 无法从外部拦截。任何外部叠加（overlay NSView / 截图 OCR / 重新绘制）都违反 §39/§40 并破坏 font metrics / scroll / selection / mouse。 |
| B. 利用 SwiftTerm 已有公共 API | **否决** | 已有 public API（`findNext` / `selectedTextBackgroundColor`）只能驱动**单一 selection**，无法表达「N 条规则 × M 行 × 多个 range」的高亮集合。`SelectionService` 是单 active range；复用它做高亮会抢用户 selection。 |
| C. fork patch 增加通用 decoration API | **采纳** | 在 `buildAttributedString` 内插入「向 provider 查询 cell 高亮 background」的钩子，default = no-op；不影响 upstream / 不写 buffer。API 通用、无 MacSSH 名称（详见 §38）。 |

Phase 5 已建立 fork patch 工作流（`Docs/SwiftTermFork.md` + `Docs/swiftterm-vs16-patch.diff`），Phase 6B 沿用同一 fork 工作流，**不引入第二个 fork 仓库、不切换 dependency**。

## 9. 推荐组件架构

```
┌─ MacSSH App 层 ─────────────────────────────────────────────┐
│                                                              │
│  AppState  (@Observable, 已有)                                │
│   ├─ sessionManager: SessionManager                           │
│   ├─ terminalAppearanceCoordinator: TerminalAppearanceCoordinator
│   └─ terminalHighlightCoordinator: TerminalHighlightCoordinator ★ 新增
│        ├─ store: TerminalHighlightStore  (规则 + 全局开关)     │
│        ├─ NSHashTable<TerminalView>.weakObjects()  (与外观协调器同模式)
│        └─ 规则变更 → 通知全部已注册 view 重绘                  │
│                                                              │
│  SettingsView                                                │
│   └─ Section("settings.section.terminal")                    │
│        └─ HighlightRulesEditor (新增子页)                     │
│                                                              │
│  LocalTerminalService / RemoteTerminalService                │
│   └─ init 后 terminalHighlightCoordinator.register(terminalView)
│                                                              │
└──────────────────────────────────────────────────────────────┘
          │  (TerminalView 提供的 fork-patch hook)
          ▼
┌─ SwiftTerm fork patch ──────────────────────────────────────┐
│                                                              │
│  protocol TerminalHighlightProvider: AnyObject {             │ ★ 通用、无 MacSSH 名
│      func highlightBackground(forRow row: Int,                │
│                              column: Int, width: Int,        │
│                              in terminalView: TerminalView)   │
│          -> TTColor?                                         │
│  }                                                           │
│                                                              │
│  TerminalView {                                              │
│      public var highlightProvider: TerminalHighlightProvider?  // default nil = no-op
│  }                                                           │
│                                                              │
│  buildAttributedString 内：                                   │
│      let highlightBg = highlightProvider?.highlightBackground(...)
│      if let highlightBg, !isSelected {                       │  ★ 不抢 selection
│          batchAttributes[.selectionBackgroundColor] = highlightBg
│          // 不改 foreground，保留 ANSI 原前景                  │
│      }                                                       │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**职责边界**：
- `TerminalHighlightStore`：规则集合 + 全局 enable + 持久化读写。
- `TerminalHighlightMatcher`：纯函数，输入 `(lineString, rules)` → `[Match]`；与 SwiftTerm 无 UI 耦合，可单测。
- `TerminalHighlightCoordinator`：持有 store、注册 view、监听规则变更、触发 `terminal.updateFullScreen() + queuePendingDisplay()`（复用外观协调器模式）。
- `TerminalHighlightProvider` 实现：缓存 per-row `[Match]`，按 `(row, column, width)` 查询；缓存 key 用 `BufferLine.generation`（详见 §30）。

## 10. TerminalHighlightRule 数据模型

```swift
struct TerminalHighlightRule: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String                 // 非空（matcher / UI 双重防御）
    var color: HighlightColor        // red/orange/yellow/green/blue/purple/gray
    var isCaseSensitive: Bool
    var isEnabled: Bool
    var sortOrder: Int               // 升序；冲突时先到先赢（§18）
}
struct HighlightColor: Codable, Equatable {
    let red, green, blue: UInt8      // sRGB；Light/Dark 各一套（§27）
}
struct TerminalHighlightSettings: Codable, Equatable {
    var isHighlightEnabled: Bool     // 全局开关
    var rules: [TerminalHighlightRule]
}
```

## 11. 存储方案

**UserDefaults + Codable JSON**（不选 SwiftData）。

| 选项 | 判定 | 原因 |
| --- | --- | --- |
| SwiftData | 不选 | 当前 SwiftData 仅存 `Host` / `HostGroup` / `KnownHost` / `TransferTask`——都是有 id 的「业务实体」并参与 `@Query` 列表。高亮规则是**纯偏好设置**（数量小、结构稳定、不需关系、不需查询），与现有 `AppState.language`（UserDefaults）同类。引入 SwiftData 表会过度设计，且需要 ModelContainer 注入到 Settings 子页。 |
| **UserDefaults + Codable JSON** | **采纳** | 与 `AppLanguage` 一致：`AppState` 已持有 `userDefaults`，规则全集编码为单个 JSON Data 存一个 key（`macssh.terminalHighlightSettings`），原子写、读取一次到内存、协调器广播变更。规则不是业务实体、不需要 `@Query`。 |
| Keychain | 不选 | 规则非 secret（§52）。 |

**迁移**：首次启动检测 key 不存在 → 写默认值 `{ isHighlightEnabled: true, rules: [] }`（详见 §37）。

## 12. Settings UI hierarchy

现有 `SettingsView` 用 `Form` + `Section`，已有 `settings.section.terminal`（font/scrollback 只读占位）。**在 Terminal Section 内新增子区块**：

```
设置
├─ General
├─ Terminal
│   ├─ Font / Font Size / Scrollback  (现有只读占位)
│   └─ 高亮                          ★ 新增子区块
│        ├─ 自动高亮总开关
│        └─ 规则列表
│             ├─ [rule] text / color / Aa / 启用 / 删除
│             └─ + 添加规则
├─ Appearance
├─ SSH
└─ Known Hosts
```

**不**新建独立顶层「高亮」页——与计划书第 45 节「Terminal 设置归属终端相关项」一致，与现有 `settings.section.terminal` 分组对齐。本阶段不实现 UI。

## 13. Matcher layer

**方案 B：Terminal model BufferLine text matching**（已由源码与 probe 证明）。

| 方案 | 判定 | 原因 |
| --- | --- | --- |
| A. byte stream matching | 否决 | 会匹配 escape bytes（ESC[31m...）；无法支持 scrollback（已滚出 viewport 的 bytes 不可重读）；违反 §25。 |
| **B. BufferLine text matching** | **采纳** | matcher 看到的 String 是 `translateToString(skipNullCellsFollowingWide:)` 产出的——**ANSI escape 已被 parser 消化、只留可见字符**（probe 验证：`\e[31mERROR\e[0m` 行的 String 是 `"ERROR"`，matcher 只见 ERROR）。天然支持 scrollback（buffer 行 0..<lines.count 含全部历史）。resize/reflow 后只需重算（§22）。 |
| C. renderer final string | 否决 | 渲染字符串经过 BiDi visual reorder，列号映射复杂且与 cell 不稳定对齐；不必要。 |

## 14. substring matching 算法

**第一版：literal substring, case-sensitive / insensitive, 多匹配, 物理行独立**。

- API：`String.range(of:options:range:)`，`options = caseSensitive ? [] : [.caseInsensitive]`。
- 不用 `localizedStandardContains` / `localizedCaseInsensitiveContains`——避免 locale-dependent folding 把 `I`/`ı` 等做奇怪转换（§17）。
- 重复匹配：从上次 `range.upperBound` 继续搜索，避免死循环（probe 验证 ERROR ERROR ERROR 全部命中）。
- 跨行：**不支持跨物理行匹配**（每行独立翻译后搜索）——wrap 行是否拼接见 §20。

## 15. case-insensitive 方案

`String.CompareOptions.caseInsensitive`（确定性，不依赖 user locale）。`SearchOptions.caseSensitive` 已采用同一策略，行为一致。

## 16. Unicode index → cell mapping

**复用 `SearchEngine.stringLengthToBufferSize` 的算法**（probe 已镜像验证全部通过）：

```
for each cell i in line:
    if cell.width == 2 and next cell.width == 0:   # wide + null continuation
        i += 2; strIdx += 1
    else:
        i += 1; strIdx += 1
return i  (= cell column)
```

`CharData.code` 是 internal → MacSSH 层用 public 的 `width` 判定（与 `SearchEngine` 源码完全等价，它也只用 width）。

## 17. CJK / Emoji / VS16 方案

probe A 全部通过：
- ASCII `ERROR` → `[0,5)`
- `中文 ERROR 测试` → `[5,10)`（中=2 cells, 文=2 cells, space=1）
- `😀 ERROR ❤️` → `[3,8)`（😀=2 cells, space=1）
- CJK 规则 `错误` in `中文错误测试` → `[4,8)`（中=2, 文=2, 错=2, 误=2）

probe A2 验证 VS16 策略对映射的影响：
- `preserveBaseWidth`（Local）：⚠️=1 cell → `⚠️ ERROR ❤️` 的 ERROR 落 `[2,7)` ✓
- `widenToEmojiWidth`（Remote 默认）：⚠️=2 cells + width-0 续接 → ERROR 落 `[3,8)` ✓

matcher 对两种策略都正确（width==0 续接格被跳过）。**不修改 Phase 5 VS16 patch**（§46）。

## 18. wrapped line 方案

**第一版：物理行独立匹配**（不拼接 wrap 续行）。

probe B 验证：`XXXX ERROR YYYY ZZZZ` 在 10-col 终端 wrap 到 row0=`XXXX ERROR` + row1=` YYYY ZZZZ`。matcher 在 row0 命中 ERROR `[5,10)`，row1 无命中。物理行匹配天然正确。

理由：
- `SearchEngine.findInLine` 虽支持 wrap 拼接（拼接后跨物理行 range 经 `lineOffsets` 映射回），但拼接匹配对「substring 高亮」价值有限——跨 wrap 的字符串极少见，且拼接会让 cell 映射复杂化。
- 物理行匹配 + 缓存最简单、最快、resize 后天然重算。
- 未来如需「逻辑行匹配」可作为 P2 增强复用 `SearchLineCache.translateBufferLineToStringWithWrap`。

## 19. scrollback 方案

**第一版：每帧只扫描 visible rows**（`yDisp ..< yDisp + rows`），不做全量 scrollback 预扫描。

理由（probe C 性能数据支撑）：
- visible 40 行 × 100 rules = **5.9 ms / frame**（release）——60fps 预算 16.6ms 内。
- 全量 10,040 行 × 100 rules 一次性 = 1.47 s（不可接受，只能用于设置变更后的「按需刷新」）。
- visible 方案天然支持 scrollback：用户向上滚时，新进入 viewport 的行立即扫描，历史高亮立即出现，无需预计算。
- 行文本翻译占 visible 帧成本 ~12%（187µs / 1538µs），剩余 88% 是规则匹配 —— 缓存见 §30。

## 20. resize / reflow 方案

**每帧基于当前 line text 重算**（不缓存 stale range）。

理由：
- SwiftTerm reflow（`Buffer.reflowWider` / `reflowNarrower`）会重建 `BufferLine` 内容与 `isWrapped`，**任何缓存的 `(row, col)` 都会失效**。
- 重算天然避免 stale ranges；visible-only 方案下 resize 只影响 viewport，成本可控。
- `BufferLine.generation`（public private(set) UInt64，所有 mutation 路径 `bump()`）可作为 per-row 缓存 key（§30）——reflow 后 generation 变化 → 缓存自动失效。

## 21. ANSI 方案

probe 验证：`\e[31mERROR\e[0m` 行的 lineString = `"ERROR"`（escape sequence 不进入 buffer 字符，已被 parser 消化为 `Attribute.fg = .ansi(1)`）。matcher 只见 ERROR。

**渲染叠加**：高亮 background 经 `.selectionBackgroundColor` attribute 注入，**不改 `.foregroundColor`**——保留 ANSI 原 foreground。原 ANSI background 与高亮 background 的优先级见 §10/§23。

## 22. copy 方案

probe 验证：`terminal.getText(start:end:buffer:)` 返回纯 `"ERROR"`，无 color metadata、无 ANSI、无额外字符。

`MacTerminalView.copy(_:)` → `selection.getSelectedText()` → `terminal.getDisplayText` → `getText` —— **直接读 buffer `CharData` 文本，不读 attribute**。高亮染色只改 attributedString 的 `.selectionBackgroundColor`，**不进 buffer**，因此复制路径天然不受影响。

## 23. selection / cursor / ANSI 优先级

渲染层级（fork patch 实现时的判定顺序，与 §10 一致）：

```
Cursor (caretView 子视图，独立绘制，最顶层)
  >
Selection (.selectionBackgroundColor = selectedTextBackgroundColor)
  >
User Highlight (.selectionBackgroundColor = rule color)   ★ 新增，只在 !isSelected 时生效
  >
ANSI background (.backgroundColor)
  >
Terminal default background (layer)
```

- **Selection > Highlight**：fork patch 在 `buildAttributedString` 内 `if let highlightBg, !isSelected`——选中 cell 不染高亮色，selection 始终可见（§27）。
- **Cursor > all**：`caretView` 是独立 NSView 子视图（CG 路径）/ Metal 独立绘制，绘制顺序在背景填充之后、glyph 之后，cursor 始终覆盖高亮 background（§28）。
- **Highlight > ANSI bg**：复用 selection 的 attribute 注入路径，`.selectionBackgroundColor` 在 `PreparedRun.backgroundColor` 解析中优先于 `.backgroundColor`（CG line 1908-1914、Metal line 1144-1146 已实现）。原 ANSI foreground 不变 → 高亮背景与 ANSI 前景自然叠加。

## 24. Light / Dark palette

**NSColor dynamic color**（`NSColor(name:)` 动态解析）或**双 RGBA 预设**。

复用 Phase 4 `TerminalAppearanceProvider` 模式：每个预设色提供 `light` / `dark` 两套 sRGB，由 `TerminalAppearanceCoordinator` 在 appearance 变化时统一广播。

推荐预设（半透明，避免完全遮蔽 ANSI background）：

| 名称 | Light RGBA | Dark RGBA |
| --- | --- | --- |
| red | (255, 80, 80, 0.35) | (255, 99, 99, 0.30) |
| orange | (255, 149, 0, 0.35) | (255, 159, 10, 0.30) |
| yellow | (255, 204, 0, 0.35) | (255, 214, 10, 0.30) |
| green | (52, 199, 89, 0.35) | (48, 209, 88, 0.30) |
| blue | (10, 132, 255, 0.35) | (10, 132, 255, 0.30) |
| purple | (175, 82, 222, 0.35) | (191, 90, 242, 0.30) |
| gray | (142, 142, 147, 0.35) | (142, 142, 147, 0.30) |

半透明理由：让 ANSI background 透出，减少对原终端着色的破坏；与 `selectedTextBackgroundColor`（SwiftTerm 默认也是半透明感）视觉一致。

## 25. Local / Remote 共享方案

**单一 provider，同一协调器注册全部 view**——与 Phase 4 `TerminalAppearanceCoordinator` 完全同构。

- `TerminalHighlightCoordinator` 持有 `NSHashTable<TerminalView>.weakObjects()`，`register(_:)` 在 `SessionManager.createLocalSession` / `createRemoteSession` / `runConnectFlow(reattach)` 调用（与 `terminalAppearanceCoordinator?.register` 同位置）。
- provider 实现按 `(row, column, width)` 查询缓存 `[Match]`，**与 Local/Remote 无关**——matcher 只看 buffer line text。
- VS16 策略差异（Local=preserve / Remote=widen）已被 matcher 的 width==0 跳过逻辑正确处理（probe A2），不需分叉 provider。

## 26. live settings update 方案

规则变更 → `TerminalHighlightCoordinator` 的 `@Observable` 属性变更 → 触发：

```swift
for view in terminalViews.allObjects {
    view.terminal.updateFullScreen()        // public
    view.needsDisplay = true                // public NSView API, 触发 draw(_:) 全量重绘
}
```

**不重建 TerminalView**、不重启 Shell / SSH / PTY。复用 `TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews` 的广播模式。

`terminal.updateFullScreen()` 是 public（`Terminal.swift:6283`），`needsDisplay` 是 NSView public —— 无需 fork patch 即可触发重绘。

## 27. cache / invalidation 方案

**per-row `[Match]` 缓存，key = `(bufferRow, BufferLine.generation)`**。

- `BufferLine.generation`（public private(set) UInt64）在所有 mutation（cell set、wrap、reflow、fill、insertCells、deleteCells...）路径 `bump()`。
- provider 维护 `[Int: (generation: UInt64, matches: [Match])]`，查询时若 generation 不匹配则重算。
- 规则集合变更 → 清空全部缓存。
- 全局开关关闭 → 清空缓存并返回 nil（高亮立即消失）。

## 28. 20 / 50 / 100 rules 性能预估

probe C（release, M-series, 10,040 行 scrollback, 40-row viewport）：

| rules | visible/frame | 全量一次 |
| ---:|---:|---:|
| 20 | 1.5 ms | 333 ms |
| 50 | 3.0 ms | 754 ms |
| 100 | 5.9 ms | 1.47 s |

**结论**：
- visible 方案下 100 rules 仍在 60fps 预算内（5.9ms < 16.6ms）——**第一版不限制 rule 数量**（§36）。
- 全量扫描不可接受 → 只在设置变更后让 visible 重算（即下一帧），不预扫描 scrollback。

## 29. 性能 probe

`/tmp/highlight-probe/`（独立 SPM 包，依赖 SwiftTerm fork 本地 checkout，**不进 MacSSH 工程**）：
- `Package.swift` + `Sources/probe/main.swift`。
- 探针 A：正确性（ASCII/CJK/Emoji/ANSI/case-sensitive/跨行/copy）——全部 PASS。
- 探针 A2：VS16 策略对 cell 映射的影响——全部 PASS。
- 探针 B：wrapped line 物理行匹配——通过。
- 探针 C：性能（20/50/100 rules × visible / full）——数据见 §28。

## 30. 测试架构

Phase 6B 至少：

| 测试文件 | 范围 |
| --- | --- |
| `Tests/SSH/TerminalHighlightMatcherTests.swift` | 纯函数：ASCII/CJK/Emoji/VS16/case/overlap/empty rule/重复匹配 |
| `Tests/SSH/TerminalHighlightStoreTests.swift` | Codable 编解码、默认值、规则 CRUD、全局开关 |
| `Tests/SSH/TerminalHighlightCoordinatorTests.swift` | register/广播/不重建 view（镜像 `TerminalAppearanceTests`） |
| `Tests/SSH/TerminalHighlightSettingsUITests.swift` | UI 验收（可选，XCTest UI） |

**deterministic renderer test**（§43）：因 `buildAttributedString` 是 internal、`Terminal.buffer.lines` 是 internal，**renderer 层测试需在 fork 仓内**（SwiftTerm Tests），不在 MacSSH `@testable import MacSSH`。MacSSH 侧只测 matcher 纯函数 + store + coordinator。

## 31. 是否需要 dependency change

**否**。`Package.resolved` 不变（仍 `8a5187f`）。Phase 6B 的 fork patch 是在 **同一 fork 仓** `canbyte0/SwiftTerm` 上新增第二个 patch commit（与 Phase 5 patch 并列），生产依赖升级到新 SHA。不引入新 package、不切 upstream。

## 32. security impact

- 高亮规则可能含 hostname / IP / 用户文本 —— **不写入 OSLog**（§52）。
- coordinator / matcher 只记录规则数量、命中数量（聚合），不记录 rule.text / matched text。
- 规则存 UserDefaults（非 secret，不需 Keychain）。
- 不读写 PTY / SSH / Keychain / 私钥。

## 33. localization impact

当前 `Localizable.xcstrings` 315 keys。预计新增（中英双语）：

```
settings.terminal.highlight.title            高亮 / Highlight
settings.terminal.highlight.enable           自动高亮 / Auto Highlight
settings.terminal.highlight.rules            规则 / Rules
settings.terminal.highlight.add              添加规则 / Add Rule
settings.terminal.highlight.text             文本 / Text
settings.terminal.highlight.color           颜色 / Color
settings.terminal.highlight.case_sensitive  区分大小写 / Case Sensitive
settings.terminal.highlight.enabled         启用 / Enabled
settings.terminal.highlight.empty           暂无高亮规则 / No highlight rules
settings.terminal.highlight.delete          删除 / Delete
validation.highlight_text_required         请输入高亮文本 / Highlight text is required
```

## 34. migration / default behavior

**默认 `isHighlightEnabled = true, rules = []`**。

- 老用户启动：key 不存在 → 写默认值（启用但规则空）→ 无任何高亮出现，行为与升级前完全一致。
- 不 crash（rules 空时 matcher 返回空数组）。
- 选 `true` 而非 `false`：用户在 Settings 添加第一条规则后立即生效，无需先找总开关。

## 35. P1 / P2 / P3 风险

| 级别 | 风险 | 缓解 |
| --- | --- | --- |
| P1 | fork patch 的 `highlightProvider` 钩子在 `buildAttributedString` 热路径每 cell 调用，default nil 时不能有性能损失 | 钩子用 `if let provider = highlightProvider` 守卫，nil 时零成本；probe C 已含 100 rules 数据。 |
| P1 | Metal 路径与 CG 路径共用 `buildAttributedString`，patch 必须同时验证两条路径 | MacSSH 未启 Metal，但 fork patch 必须 unit-test Metal 路径（fork 仓内）。 |
| P2 | per-row 缓存 generation key 在 reflow 后失效 | generation 在 reflow 路径 bump（已验证），缓存自动失效。 |
| P2 | 规则冲突（ERROR / ERR / ERROR_CODE） | first-rule-wins（按 sortOrder），简单确定（§18）。 |
| P3 | empty rule 防御 | UI + matcher 双重 `guard !rule.text.isEmpty`。 |
| P3 | rule 数量限制 | 不加软限制，100 rules 性能可接受。 |

## 36. 推荐 Phase 6B 实现步骤

1. **fork patch**（`canbyte0/SwiftTerm` 新 patch commit，不 merge upstream PR）：
   - 新增 `protocol TerminalHighlightProvider` + `TerminalView.highlightProvider`。
   - `buildAttributedString` 内 `if let provider, !isSelected` 注入 `.selectionBackgroundColor`。
   - fork 仓内新增 unit test（deterministic renderer test，§43）。
   - 更新 `Docs/SwiftTermFork.md` + 新增 `Docs/swiftterm-highlight-patch.diff`。
   - 升级 `Package.resolved` 到新 SHA。
2. **MacSSH 层**：
   - `Models/TerminalHighlightRule.swift` + `TerminalHighlightSettings.swift`（Codable）。
   - `Services/Terminal/TerminalHighlightMatcher.swift`（纯函数，镜像 probe）。
   - `Services/Terminal/TerminalHighlightStore.swift`（UserDefaults 读写）。
   - `Services/Terminal/TerminalHighlightCoordinator.swift`（NSHashTable + 广播，镜像外观协调器）。
   - `TerminalHighlightProviderImpl`（实现 fork protocol，per-row 缓存）。
   - `AppState` 装配 coordinator；`SessionManager` 在 create/reattach 处 `register`。
   - `Features/Settings/HighlightRulesEditor.swift` + `SettingsView` 新增 Section。
3. **测试**：§30 全部测试文件。
4. **UI 预览**（AGENTS.md UI 规则）：实现前先出预览图获用户确认。
5. **编译 / warning / 运行 / 阶段报告**。

## 37. 是否建议进入 Phase 6B

**是**。

- 调查结论明确：方案 C（fork patch）+ MacSSH 层 coordinator + UserDefaults + visible-only 物理行匹配。
- 性能数据支撑 100 rules 可行。
- 安全边界清晰（只改 presentation，不写 buffer / PTY / SSH / Keychain）。
- 复用 Phase 4/5 已建立的 fork 工作流与 coordinator 模式，无新依赖、无新架构范式。
- probe 全部 PASS。

**等待独立架构验收 + 用户明确授权后开始 Phase 6B。本阶段 STOP。**
