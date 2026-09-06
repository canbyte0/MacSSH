# MacSSH 1.1 Phase 9C — Independent VS16 Large-Font Rendering Root-Cause Acceptance

> 角色：Independent Renderer Reviewer（非 Phase 9C 调查者，非 Phase 9B 开发者）。
> 方法：从 SwiftTerm resolved 源码、MacSSH 源码、Phase 5 测试、git 身份独立重新确认；不采信 Phase 9C 报告结论。
> 验收日期：2026-09-05（Asia/Shanghai）。
> **未修改 production code / SwiftTerm fork / MacSSH / commit / merge / push / 未创建 fork branch / 未开始 remediation。**

---

## 独立复核限制声明（必读）

Phase 9C 报告引用的全部 probe 产物位于 `/tmp/macssh_phase9c_probe/`（CoreTextMetrics / ModelProbe / TerminalViewProbe binaries、module cache、profraw、5 张 2x PNG）。**独立复核时该目录已不存在**（`/tmp` 在会话间被清理），production DerivedData checkout `/private/tmp/MacSSH-P9B-ACC-DD/SourcePackages/checkouts/SwiftTerm` 同样已清除。

因此本评审**无法独立重新执行 CoreText shaping probe、无法重新测量 glyph advance/bounds 的精确数值、无法重新扫描 2x PNG 像素**。Phase 9C 报告 §15–§24、§29–§39 的精确数值（advance=19pt@14pt、bounds=17.5pt、overhang 6.5–13pt 等）**来自调查者 probe，本评审无法逐数字复核**。

但是——**根因架构链不依赖任何精确 probe 数值**。本评审从 resolved SwiftTerm 源码独立确认了整条因果链：preserveBaseWidth 语义（`Terminal.swift:1518-1520`）→ cellWidth 算法（`AppleTerminalView.swift:428-437`）→ 1-cell 段进入 columnWidth=1（`buildAttributedString:1121-1126`）→ glyph origin 固定网格（`:2078`）→ `glyphSlotFit` guard 跳过 1-cell（`:450`）→ draw-time guard 跳过 1-cell fit（`:2122`）→ caret x = cellWidth×caretCol（`:2513`）。这条链**完全可从源码独立确立**，与 probe 数值无关。只要 Apple Color Emoji 的 ink 宽于 JetBrains Mono cell（这是一个由字体度量决定、不随 renderer 实现而变的事实），1-cell VS16 glyph 就会原尺寸绘制并覆盖相邻 cell。

基于此，本评审对**架构根因**给出独立判断；对**精确 probe 数值**标注"调查者 probe，未独立复核"，不作为独立结论的依据。

---

## 1. Acceptance result

**ARCHITECTURE / ROOT-CAUSE PASS — Phase 9 FINAL PASS remains BLOCKED pending authorized presentation-only remediation.**

根因架构链独立确认为真；推荐 remediation 方向（Option F+B，presentation-only glyph fit）在架构层正确且安全；但实现尚未做，且用户已能肉眼复现 32pt 下的相邻字符覆盖。因此 Phase 9B 的 FINAL PASS **保持阻塞**，直到一个窄范围、可缓存、CG/Metal 共用、metrics-driven 的 1-cell overflow glyph fit 完成并通过 §55–§57 验收 gate。

本评审不是 PASS（实现未做、缺陷用户可见），也不是 FAIL（根因与方向正确、无 P1 架构错误），而是 **ARCHITECTURE/ROOT-CAUSE PASS**：根因 + fix family 在架构层成立，阻塞仅因 remediation 未实现。

---

## 2. P1

**P1（架构层已确认，阻塞 FINAL PASS）：preserveBaseWidth 下的 1-cell VS16 Apple Color Emoji glyph 未进入 `glyphSlotFit`，原尺寸绘制导致相邻 cell ink 覆盖。**

独立源码证据链：

1. `Terminal.swift:1518-1520` — preserve 分支 `updateCharData(&cd, char: newCh, size: Int32(oldSize))`，`oldSize` = 基字符原宽 1，不插 width-0 续接，不额外移 `buffer.x`。→ ⚠️/❤️ logical width = 1。
2. `buildAttributedString:1121-1126` — `if builder.columnWidth != width` flush+新段；preserve 下 ⚠️ width=1 → 进入 `columnWidth: 1` 段。
3. `AppleTerminalView.swift:446-450` — `glyphSlotFit(font:glyph:columnWidth:)` 首行 `guard columnWidth >= 2, cellDimension != nil else { return .identity }`。columnWidth=1 直接返回 `.identity`（dx=0, dy=0, scale=1），**不做任何 fit/scale**。
4. `:2122` — draw path `if prepared.segment.columnWidth >= 2 { ... }`，columnWidth=1 段整块跳过，直接 `:2148 CTFontDrawGlyphs(runFont, runGlyphs, &glyphPositions, ...)` 原尺寸。
5. `:2078` — glyph origin = `lineOrigin.x + CGFloat(glyphColumn) * cellDimension.width`，固定网格；Apple Color Emoji natural advance **不推动后续 cell**，但 oversized ink 仍画进相邻 cell。

结论：1-cell VS16 Emoji glyph 按 natural Apple Color Emoji 尺寸（约 point size，远大于 JetBrains Mono cell ≈ 0.6×point size）绘制，ink 覆盖右侧相邻 cell。**P1 成立，阻塞 Phase 9B FINAL PASS。**

---

## 3. P2

**P2（remediation 设计 gate）：future fit 必须由单一 source 计算 transform，CG 与 Metal 共同消费，并带 (font, glyph, cellDimension) cache。**

独立证据：

- `glyphSlotFit` docstring（`:444-445`）声明"Shared by the CoreGraphics and Metal glyph renderers so they stay pixel-consistent"。
- 实际调用点：**仅在 CG draw path `:2126`**。Metal renderer（`:2406-2439`）走 `metalDirtyRange` + `requestMetalDisplay()` + GPU glyph atlas 路径，本评审**未发现 Metal path 调用 glyphSlotFit**。
- MacSSH 当前未显式启用 Metal（调查报告 §76），故 CG path 是用户可见路径；但 docstring 的"shared"是设计意图，未来若启用 Metal，fit 必须覆盖 Metal，否则两 renderer 会出现 ink 一致性差异。
- 每 glyph 调 `CTFontGetAdvancesForGlyphs` + `CTFontGetBoundingRectsForGlyphs`（`:458, :462`）有 hot-path 成本；若把 1-cell 也纳入 fit，Latin hot path 会退化，**必须 cache**。

**P2，不单独阻塞根因结论，但属于 remediation 实现的硬设计 gate。**

---

## 4. P3

**P3（不阻塞，记录为平台字体行为）：**

- Apple Color Emoji 在不同 point size 的 advance/ink 非严格线性（调查报告 §24、§43 的台阶行为），禁止用字号 magic number 修复。
- ⚠️ 与 ❤️ declared bounds 相同但实际非透明像素不同，造成肉眼接近度差异。
- `glyphSlotFit` docstring 声称"Shared by CoreGraphics and Metal"，但 Metal path 实际未调用它（设计意图 vs 实现现状的文档/代码偏差）。未来 remediation 须消除该偏差。
- probe 产物存放 `/tmp`，会话间易丢失，建议未来调查/probe 产物纳入可复现位置（不强制入仓库，但应可重新生成）。

---

## 5. MacSSH branch

`feature/macssh-1.1-terminal-font-size`（`git branch --show-current` 独立确认 ✓）

---

## 6. MacSSH baseline

`c6bf66c2b985530e6687fefe62cdf08246190e41`（`git rev-parse HEAD` 独立确认 ✓）

工作树保留 Phase 9B 未提交内容（7 modified + Phase 9A/9B/9C reports + TerminalFontSizeController + 2 测试文件 + generated-images/），与调查报告 §3 一致。

---

## 7. SwiftTerm SHA

`771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `https://github.com/canbyte0/SwiftTerm.git`

三方独立确认：
- `Package.resolved` revision = `771e79f...` ✓
- `ThirdParty/SwiftTerm-fork` HEAD = `771e79f...`（commit "Add public pasteText(_:) API"）✓
- fork `git status --short` = **空**（工作树干净）✓

---

## 8. production modifications

**Phase 9C 对 production 的修改数 = 0。**

独立确认：
- SwiftTerm fork `git status --short` 空输出 → fork 未被修改 ✓
- MacSSH working tree 只有 Phase 9B 既有内容（`TerminalFontSizeController`、SettingsView、SessionManager 等），无 Phase 9C 新增的 production 改动 ✓
- 唯一新增文件为本评审报告 + Phase 9C 调查报告（Docs/*.md）

---

## 9. Phase5 policy

独立确认 `TerminalOptions.swift:64-87` 定义 `VariationSelector16WidthPolicy`：
- `.widenToEmojiWidth`（默认）：width-1 base + VS16 → 2 cells。
- `.preserveBaseWidth`：保留 base 原宽，VS16 留在 grapheme cluster（emoji presentation 不变），只不改 cell 列宽。

`LocalTerminalService.swift:33-39` 显式 `variationSelector16WidthPolicy: .preserveBaseWidth` ✓。Remote 保持默认（`TerminalVS16WidthPolicyTests.testRemoteTerminalUsesSwiftTermDefaultPolicy` 验证 `.widenToEmojiWidth`）。

**为什么 ⚠️ / ❤️ 保持 1 logical cell**（docstring `:64-78` 独立确认）：

macOS zsh 使用系统 `wcwidth()`，把 ⚠ (U+26A0)、❤ (U+2764) 等 emoji-VS16 基字符按 **width 1** 处理、VS16 (U+FE0F) 按 **width 0** 处理；SwiftTerm 默认 widen 到 2。两侧 width 不一致导致：
- **bracketed paste 重绘时光标列分叉**（shell 按 width 1 回退，terminal 按 width 2 重印，列错位）；
- **history 行漂移**成 `eecho ...` / `ececho ...`（回退列数与重印列数不匹配，命令前缀被重复）；
- **cursor-left drift**（← 键移动列数与 shell model 不一致）。

preserve 使 Local SwiftTerm width = 1 = macOS zsh width，消除上述 drift。Phase 5 测试 `testBracketedPasteRedrawStaysCleanUnderPreservePolicy`（preserve 下 redraw 干净）vs `testBracketedPasteRedrawDivergesUnderDefaultPolicy`（默认下 redraw 漂移）实证该根因。

**结论：任何 renderer fix 不得改变 logical width policy，除非有全新端到端证据推翻上述 drift。本评审无任何此类证据。**

---

## 10. logical widths

独立从源码 + Phase 5 测试确认 preserveBaseWidth 下的 logical cell count：

| 输入 | logical cells | 证据 |
|---|---|---|
| ⚠ (U+26A0, 无 VS16) | 1 | text glyph，JetBrains Mono 自身 |
| ⚠️ (U+26A0 + U+FE0F) | **1** | `Terminal.swift:1518-1520` preserve 用 oldSize=1；`testPreserveBaseWidthKeepsWarningSignNarrow` width==1 ✓ |
| ❤ (U+2764, 无 VS16) | 1 | text presentation（调查报告 §17 称 Menlo fallback） |
| ❤️ (U+2764 + U+FE0F) | **1** | `testPreserveBaseWidthKeepsHeartNarrow` width==1 ✓ |
| 😀 / 🚀 / 👍 | 2 | `testPlainEmojiKeepWidthTwoUnderPreservePolicy` width==2 ✓（non-VS16 emoji 不受 policy 影响） |
| CJK (中文) | 2 | `testCJKUnaffectedByPolicy` 两种 policy 下均 width==2 ✓ |

**VS16 本身不额外增加 logical cell。** preserve 下 VS16 留在 cluster（`testVS16ScalarPreservedInClusterUnderPreservePolicy` 确认 0xFE0F 仍在 `getCharacter`），但 width 不变。✓

---

## 11. cellWidth source

独立从 `AppleTerminalView.swift:409-438` 确认（非复制报告）：

```swift
// :412-415 height
let lineAscent = CTFontGetAscent(fontSet.normal)
let lineDescent = CTFontGetDescent(fontSet.normal)
let lineLeading = CTFontGetLeading(fontSet.normal)
let cellHeight = ceil((lineAscent + lineDescent + lineLeading) * _lineSpacing)
// :428-429 width (macOS path)
let glyph = fontSet.normal.glyph(withName: "W")
let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width
// :434-437 snap
let scale = backingScaleFactor()
let snappedWidth = (cellWidth * scale).rounded() / scale
let snappedHeight = ceil(cellHeight * scale) / scale
return CellDimension(width: max(1, snappedWidth), height: max(min(snippedHeight, 8192), 1))
```

cellWidth = **normal font 的 "W" glyph `advancement(forGlyph:).width`**，按 `backingScaleFactor` snap 到 pixel grid。`:432` 有 iOS fallback（`"W".size(...)`）。注释 `:417-427` 说明曾有"取 32..127 最大 width"的更稳健方案，因性能放弃。

JetBrains Mono "W" advance ≈ 0.6×pointSize（10pt≈6.0、14pt≈8.5、32pt≈19.0，与调查报告 §12 一致且符合 JetBrains Mono 字体度量）。✓

---

## 12. fallback font

调查报告 §13 称：⚠️/❤️/😀/🚀/✅/©️/™️ 的 CTLine run 为 `AppleColorEmoji`；⚠ 为 JetBrains Mono；❤ text 为 `Menlo-Regular`；©/™ 为 JetBrains Mono。PingFang SC 不参与 VS16 Emoji。

**本评审无法独立复核**（probe 已清除）。但从架构层：SwiftTerm 的 attributed string 经 CoreText cascade，Apple Color Emoji 是 macOS 对 VS16 emoji presentation 的系统 fallback，这是 CoreText 标准行为，**可信**。fallback size 跟随 base pointSize（调查报告 §14），无固定 size 问题。

---

## 13. shaping results

调查报告 §15–§18 称：⚠️ = 1 Apple Color Emoji run / 1 glyph（VS16 被合成）；❤️ 同；⚠ = JetBrains Mono 1 glyph；❤ = Menlo 1 glyph。

**本评审无法独立复核**（probe 已清除）。架构层可信：CoreText 对 base+VS16 emoji presentation 合成为单 color glyph 是标准行为。这对根因结论**非必要**——无论 1 glyph 还是 base+VS16 双 glyph，只要最终 ink 宽于 cell 且 columnWidth=1 跳过 fit，缺陷即成立。

---

## 14. glyph advances

调查报告 §20（⚠️/❤️ Apple Color Emoji advance）：10pt=13.0、14pt=19.0、18pt=22.0、24pt=25.0、32pt=32.0 pt。

**本评审无法独立复核精确值**（probe 已清除）。架构层合理性：Apple Color Emoji advance ≈ pointSize（方形 advance），与 JetBrains Mono cell ≈ 0.6×pointSize 比，ratio ≈ 1.67–2.24，**超过 1 cell**。这与"advance overflow"一致。

---

## 15. glyph bounds

调查报告 §21（⚠️/❤️ declared bounds）：10pt=12.5、14pt=17.5、18pt=21.0、24pt=24.0、32pt=32.0 pt；right overhang beyond 1 cell：6.788–13.0 pt。

**本评审无法独立复核精确值**（probe 已清除）。架构层合理性：Apple Color Emoji bounds ≈ pointSize（方形 ink），同样超 cell。**bounds overflow 是可见缺陷的直接原因**（见 §16、§27）。

---

## 16. advance/cell ratio

调查报告 §20（advance/cell）：10pt=2.167、14pt=2.235、18pt=2.000、24pt=1.724、32pt=1.684。

**本评审无法独立复核**（probe 已清除）。架构层：ratio > 1 在所有字号成立（Apple Color Emoji 方形 advance > JetBrains Mono cell），故 advance overflow 存在。

**独立关键洞察**：advance overflow 对**可见缺陷无因果作用**——SwiftTerm 不用 CoreText natural advance 定位（`:2078` 用 `glyphColumn × cellDimension.width`），故 advance 多大都不影响后续 cell origin。advance overflow 仅是"测量事实"，不是"缺陷成因"。真正造成相邻 cell 被覆盖的是 **ink/bounds overflow**（见 §17、§27）。

---

## 17. bounds/cell ratio

调查报告 §23（bounds/cell）：10pt=2.083、14pt=2.059、18pt=1.909、24pt=1.655–1.586、32pt=1.684–1.579。

**本评审无法独立复核**（probe 已清除）。架构层：bounds > cell 在所有字号成立，**这是可见缺陷的直接成因**——glyph ink 物理覆盖相邻 cell。

---

## 18. 14pt baseline

独立架构确认：`glyphSlotFit` guard `:450` `columnWidth >= 2` **不依赖字号**。只要 columnWidth=1（preserve 下 ⚠️/❤️）且 Apple Color Emoji ink > cell（在 14pt 同样成立，Apple Color Emoji 14pt ≈ 14pt 方形 vs cell 8.5pt），**14pt 下 overhang 必然已存在**。

调查报告 §37 称 14pt advance=19pt、cell=8.5pt、right overhang≈9.5pt，bitmap 已显示相邻字符被覆盖。**本评审无法独立复核该 bitmap**（PNG 已清除），但架构层 14pt overhang 必然存在——guard 是 size-agnostic 的。✓

---

## 19. 24pt behavior

架构层：24pt cell ≈ 14.5pt，Apple Color Emoji ≈ 24pt 方形，overhang ≈ 9.5–10pt（调查报告 §38）。绝对侵入仍接近 10pt，明显进入下一 cell。**本评审无法独立复核精确值**，但 24pt overhang > 0 由架构保证。

---

## 20. 32pt behavior

架构层：32pt cell ≈ 19pt，Apple Color Emoji ≈ 32pt 方形，overhang ≈ 12–13pt（调查报告 §39）。绝对侵入达矩阵最大。**本评审无法独立复核精确值**，但 32pt overhang > 0 由架构保证，且为矩阵最大绝对值。

---

## 21. absolute vs normalized overhang

调查报告 §40–§41：归一化 ratio **不**持续增长（10pt≈2.08 → 32pt≈1.58–1.68，24→32 小幅回升）；绝对 overhang **总体增长但非严格单调**（⚠️ 7→9.5→10.5→10.0→13pt，24pt 回落）。

**本评审无法独立复核**（probe 已清除）。架构层合理性：
- 归一化下降：cell width 与 pointSize 近似线性，Apple Color Emoji 方形也近线性，但两者斜率/离散 hinting 不同，ratio 非恒定。
- 24pt 回落：Apple Color Emoji 的离散 rasterization/hinting 造成台阶，非严格单调。这**证明不能用 `fontSize × 常数` 或字号 magic number 修复**。✓

---

## 22. fixed-grid verification

独立从源码确认 SwiftTerm **后续 cell origin 始终 = logicalColumn × cellDimension.width**，不被 Apple Color Emoji natural advance 推动：

`AppleTerminalView.swift:2074-2078`（UTF-16-is-cell-identity 路径）：
```swift
let startColumn = prepared.segment.column + (processedGlyphs * prepared.segment.columnWidth)
for i in 0..<runGlyphsCount {
    let glyphColumn = startColumn + (i * prepared.segment.columnWidth)
    positions[i] = CGPoint(
        x: lineOrigin.x + CGFloat(glyphColumn) * cellDimension.width,
        y: ...)
}
```

`:2104-2107`（utf16ToCellOrdinal 路径）：
```swift
let glyphColumn = prepared.segment.column + (ordinal * prepared.segment.columnWidth)
positions[i] = CGPoint(
    x: lineOrigin.x + CGFloat(glyphColumn) * cellDimension.width + intraCluster,
    y: ...)
```

`intraCluster` 是同一 cluster 内 combining mark 的相对 offset（来自 CoreText position），**不跨 cell**。

`A⚠️B❤️C`：A=col0、⚠️=col1、B=col2、❤️=col3、C=col4（preserve 下每个 1 cell）。rendered origins = col×cellWidth，与调查报告 §29 一致。Apple Color Emoji natural advance（≈2 cell）**不推动** B/C origin。✓

---

## 23. separator positions

调查报告 §30 称 `|⚠️|❤️|⚠️|❤️|` 中 `|` 应在 cell 0/2/4/6/8，bitmap 实测相对误差 ≤0.5pt@2x（2x 半点 raster choice），源码 origin 精确 = `cellIndex × cellWidth`。

**本评审无法独立复核 bitmap**（PNG 已清除）。源码层：separator `|` 是 JetBrains Mono width-1 glyph，其 origin 由 `:2078` 固定网格计算，**精确** = cellIndex × cellWidth，无累计 drift。✓ separator origin 正确但 Emoji ink 覆盖它——这与"grid 正确、ink overhang"的根因一致。

---

## 24. cursor positions

独立从 `AppleTerminalView.swift:2504-2515` 确认：

```swift
var caretCol = buffer.x   // model cursor column
// ... bidi remap ...
caretView.frame.origin = CGPoint(
    x: lineOrigin.x + (cellDimension.width * doublePosition * CGFloat(caretCol)),
    y: lineOrigin.y)
caretView.frame.size.width = cellDimension.width * doublePosition * CGFloat(cursorColumnWidth)
```

caret x = `cellDimension.width × caretCol`（normal cell doublePosition=1）。**不同字号 10/14/18/24/32 均 = logicalColumn × cellWidth，model cursor column 零变化**。`A⚠️B❤️C` cursor 恒 col5；separator string cursor 恒 col9；四个 ⚠️ cursor 恒 col4。**无 cursor drift**。✓

cursor 正确进一步证明：问题是 **ink overhang，不是 terminal layout drift**。✓

---

## 25. root guard verification

独立确认 `AppleTerminalView.swift:446-450`：

```swift
func glyphSlotFit (font: CTFont, glyph: CGGlyph, columnWidth: Int) -> GlyphSlotFit {
    // Only wide cells need adjusting: a single-width glyph in a monospace
    // font already fills its cell, so we skip the metric lookups entirely.
    guard columnWidth >= 2, cellDimension != nil else { return .identity }
    ...
}
```

**这是真实的 fit/transform guard**。`GlyphSlotFit` 结构体（`:224-232`）：`dx/dy/scale`，`.identity` = 全 0/1（no transform）。columnWidth < 2 → `.identity` → 不 fit、不 scale、不 offset。✓

注释"single-width glyph in a monospace font already fills its cell"是**假设**：它假设 width-1 glyph 的 ink ≤ cell。该假设对 JetBrains Mono Latin 成立，对 Apple Color Emoji VS16 glyph **不成立**（ink ≈ 2 cell）。这正是根因。✓

---

## 26. draw guard verification

独立确认 `AppleTerminalView.swift:2122-2133`：

```swift
if prepared.segment.columnWidth >= 2 {
    var computed = [GlyphSlotFit](repeating: .identity, count: runGlyphsCount)
    var anyScaled = false
    for i in 0..<runGlyphsCount {
        let fit = glyphSlotFit(font: ctRunFont, glyph: runGlyphs[i],
                               columnWidth: prepared.segment.columnWidth)
        computed[i] = fit
        glyphPositions[i].x += fit.dx
        glyphPositions[i].y += fit.dy
        if fit.scale != 1 { anyScaled = true }
    }
    if anyScaled { scaledFits = computed }
}
```

columnWidth=1 段整块跳过，`glyphPositions` = `positions`（grid origin），`:2148 CTFontDrawGlyphs(runFont, runGlyphs, &glyphPositions, ...)` 原尺寸绘制。**1-cell VS16 glyph 确实绕过 wide-cell presentation fitting path**。✓

---

## 27. root-cause classification

独立判断：**同意 Classification C（glyph advance > cell AND glyph visual bounds > cell），同时 logical fixed grid 本身正确（非 D）。**

理由：
- Apple Color Emoji advance ≈ pointSize（方形），JetBrains Mono cell ≈ 0.6×pointSize → advance > cell ✓（测量事实）。
- Apple Color Emoji bounds/ink ≈ pointSize → bounds > cell ✓（测量事实，**这是可见缺陷的直接成因**）。
- SwiftTerm glyph origin = grid（`:2078`），不是自然 layout → **非 D（renderer ignores logical cell origin）** ✓。

**独立补充洞察（报告未明确）**：在 advance 与 bounds 两项 overflow 中，**只有 bounds/ink overflow 对可见缺陷有因果作用**。advance overflow 无因果——SwiftTerm 不用 CoreText advance 定位（grid override），故 advance 多大都不移后续 cell。分类 C 作为"测量事实"正确；但 remediation 应**以 ink/bounds overflow 为触发条件**，advance 可忽略（grid 已固定后续 origin）。

---

## 28. whether Phase9 introduced bug

**否。** Phase 9B 只调 `view.font = TerminalFontProvider.regularFont(size:)`（`TerminalFontSizeController.swift:113, :199, :203`），经 SwiftTerm public `font` setter → 内置 `resetFont()` → 重算 cellDimension + resize。**未改 SwiftTerm parser/model/renderer/policy**。SwiftTerm fork `git status` 空 ✓。font setter 让用户可选 24/32pt，**放大**既有 limitation，不引入新 bug。✓

---

## 29. whether Phase9 exposed old limitation

**是。** `glyphSlotFit` guard `:450` size-agnostic，14pt baseline 下 ⚠️/❤️ 同样跳过 fit、同样 overhang。Phase 9B 让大字号可用，把绝对 overhang 从 14pt 的 ~9.5pt 放大到 32pt 的 ~12–13pt，用户更易察觉。**非新 bug，是既有 presentation limitation 被大字号暴露。** ✓

---

## 30. existing fit architecture

`glyphSlotFit`（`:446-486`）现有逻辑：

1. `:450` guard columnWidth >= 2（1-cell 直接 .identity）。
2. `:458` `CTFontGetAdvancesForGlyphs` 取 advance。
3. `:462` `CTFontGetBoundingRectsForGlyphs` 取 ink bounds。
4. `:467-469` **仅当 ink.width > slotWidth 或 ink.height > cellHeight** 时 `scale = min(slotWidth/ink.width, cellHeight/ink.height, 1)`（**uniform scale，保 aspect ratio，只缩不放**）。
5. `:474` `dx = (slotWidth - advance.width * scale) / 2`（按 advance 居中）。
6. `:479-483` 若 scale<1，按 ink 中心做 vertical centering。
7. 返回 `GlyphSlotFit(dx, dy, scale)`。

**它解决什么**：CJK/wide glyph 在 multi-cell slot 内的居中 + oversized substitute glyph 的 downscale 安全网。注释 `:211-219`：避免 full-width glyph 钉在 slot 左缘造成 phantom right gap；匹配 Terminal.app/Ghostty 的 wide-glyph centering。

**为什么只对 columnWidth >= 2**：注释 `:448-449` 假设"single-width glyph in a monospace font already fills its cell"——对 Latin monospace 成立，对 Apple Color Emoji VS16 fallback glyph **不成立**。

**能否安全复用思想处理 logical 1-cell + oversized VS16 glyph**：**是**。现有 `:467-469` 的 ink-overflow + uniform-scale + center 逻辑对 columnWidth=1 同样适用，只需把 guard 从 `>= 2` 放宽到"columnWidth==1 且 ink overflow"（见 §34 predicate）。CJK（columnWidth=2）路径不受影响。✓

---

## 31. Option F assessment

**Option F（presentation-only glyph fit）独立评估：架构正确，是首选族。**

要求：仅改 drawing transform，不改 Terminal model / logical cell count / cursor column / PTY bytes / input/output / VS16 string / shell。

独立确认可行性：
- `GlyphSlotFit` 只产出 `(dx, dy, scale)`，draw path `:2128-2129` 把它加到 `glyphPositions`（局部 copy），`positions`（grid-aligned）不变 → decorations/highlight/cursor 仍用 grid origin。
- scale 经 `CTFontCreateCopyWithAttributes`（`:2142`）创建缩小 font，`CTFontDrawGlyphs` 绘制——**纯 drawing**，不改 model/bytes。
- 对 1-cell overflow glyph 复用此路径，model/cursor/PTY 完全不变。✓

---

## 32. Option B assessment

**Option B（drawing-only horizontal scale）独立评估：可行但单独不够。**

水平 only scale 会**压扁** emoji（❤️ 变宽扁、⚠️ 变形），视觉损失大。Apple Color Emoji 是方形彩色 glyph，水平 squash 破坏 aspect ratio。应与 F 合并，用 **uniform scale 保 aspect ratio**（见 §23）。

---

## 33. combined F+B assessment

**Option F+B 独立评估：最安全的具体实现方向。**

合并语义：对 1-cell overflow glyph，在 logical cell 内 **uniform scale（保 aspect ratio）down to fit**，按 advance/ink 居中，必要时 vertical center。复用现有 `glyphSlotFit` 的 `:467-483` 逻辑（已实现 uniform scale + center），只放宽 guard。

- uniform scale 保 aspect ratio：emoji 保持方形，不变形。代价：缩放后 emoji 视觉高度 = cellWidth（如 14pt 8.5pt），小于 natural（14pt），但远好于覆盖相邻字符。cell height（14pt 18.5pt）远大于缩放后高度，vertical 充足。**无"emoji 视觉高度过小"问题**（缩放后 emoji ≈ cellWidth × cellWidth，在 cellHeight 内 vertical center，仍清晰可辨）。✓
- 仅改 drawing transform：model/cursor/PTY/bytes/policy 不变。✓
- 复用现有 CG/Metal 共用 `GlyphSlotFit` 入口（docstring `:444-445`）。✓

---

## 34. exact scope predicate

**唯一推荐 predicate（metrics-driven，非 VS16-specific）：**

未来 `glyphSlotFit` 应对 1-cell glyph 计算 fit，当且仅当：

```
columnWidth == 1
AND cellDimension != nil
AND runFont != fontSet.normal            // 性能 gate：base font 的 Latin 跳过 metric lookup，保 hot path
AND advance.width > 0
AND ink.width > 0 AND ink.height > 0
AND (ink.width > cellWidth OR ink.height > cellHeight)   // correctness gate：ink 真实溢出 logical cell
```

理由：
- **ink-overflow 为唯一 correctness gate**：只在 glyph ink 真实溢出 cell 时 fit。ASCII/Latin（ink ≤ cell）→ 不触发 → 完全 untouched（§38）。
- **runFont != fontSet.normal 为性能 gate**：base monospace font 的 glyph 永不 overflow（字体设计保证 ink ≤ em），跳过其 `CTFontGetBoundingRectsForGlyphs` 调用，保 Latin hot path 不退化。fallback font（Apple Color Emoji / Menlo 等）才进 metric lookup。
- **非 VS16-specific**：predicate 不检查 `0xFE0F` 或 Unicode 属性。任何 1-cell fallback glyph 只要 ink overflow 就 fit。这自动处理：
  - ⚠️/❤️（VS16 emoji，ink overflow）→ fit ✓
  - ⚠（JetBrains Mono text，ink ≤ cell，且 runFont == base → 跳过）→ untouched ✓
  - ❤（Menlo text，ink ≤ cell，runFont != base 但 ink 不 overflow → 跳过）→ untouched ✓（§35、§36）
  - 😀/🚀（columnWidth=2，走既有 wide path）→ 不受影响 ✓
- **不依赖字号**：predicate 无 pointSize 条件，从 10pt 到 32pt 同一规则，避免 magic number。✓

---

## 35. ⚠ vs ⚠️

- ⚠ (U+26A0)：JetBrains Mono 自身 text glyph，columnWidth=1，runFont=base，ink ≤ cell → **predicate 跳过，untouched**。✓
- ⚠️ (U+26A0+VS16)：Apple Color Emoji，columnWidth=1（preserve），ink ≈ 2 cell → **predicate 触发 fit**。✓

predicate 自然区分二者：不靠检查 VS16，靠 ink 度量。⚠ 的 text glyph ink ≤ cell 故不 fit；⚠️ 的 emoji ink > cell 故 fit。**不会错误压缩正常 text glyph。** ✓

---

## 36. ❤ vs ❤️

- ❤ (U+2764)：text presentation，Menlo fallback（调查报告 §17），ink ≈ 1 cell → predicate `ink.width > cellWidth` 不成立 → **跳过，untouched**。✓
- ❤️ (U+2764+VS16)：Apple Color Emoji，ink ≈ 2 cell → **fit**。✓

同理靠 ink 度量区分。✓

---

## 37. non-VS16 emoji

调查报告 §19 称 😀/🚀/✅ logical width=2（`testPlainEmojiKeepWidthTwoUnderPreservePolicy` 验证）。它们**已进入既有 wide-cell fit path**（columnWidth=2），不受 1-cell predicate 影响。

**未来 fix 应作用于"所有 1-cell overflow color glyph"，非"仅 VS16 sequences"。** 理由：
- VS16 只是触发 emoji presentation 的途径之一。限定 VS16 会耦合 renderer 到 Unicode width policy 内部，脆弱。
- metrics predicate（ink overflow）自校正：任何 1-cell overflow glyph 都 fit，任何 fitting glyph 都 untouched。这是最稳健、最少 surprise 的设计。
- 目前已知的 1-cell overflow color glyph 主要是 VS16 emoji presentation（⚠️/❤️/©️/™️），但 predicate 不排除未来其他 1-cell fallback color glyph。

---

## 38. ASCII risk

**零风险。** predicate 的 `runFont != fontSet.normal` + `ink.width > cellWidth` 双 gate 保证：
- A-Z / a-z / 0-9 / punctuation：JetBrains Mono 自身 glyph，runFont == base → 跳过 metric lookup，`.identity`。完全 untouched。✓
- 即便假设某 base-font glyph ink 微 overflow（字体 bug），现有 `:467` scale 只 down 不 up，且 scale 后仍居中——不会放大，最坏情况是轻微 downscale，非破坏性。

---

## 39. CJK risk

**零风险。** CJK columnWidth=2（`testCJKUnaffectedByPolicy` 验证），走既有 wide-cell path（`:2122` guard `>= 2` 通过），1-cell predicate 不介入。CJK 的 centering/scale 行为完全不变。✓

未来若放宽 `glyphSlotFit` guard，**必须保持 columnWidth >= 2 的既有逻辑分支不变**，只新增 columnWidth == 1 的 ink-overflow 分支。两分支互不干扰。✓

---

## 40. vertical risk

**低。** 现有 `glyphSlotFit` 的 vertical 逻辑（`:479-483`）仅在 scale<1 时按 ink 中心 vertical center。Apple Color Emoji 声明 vertical bounds 略超 baseline（调查报告 §34：10pt -2.5…10、32pt -4…28），但 cellHeight（14pt 18.5pt）远大于缩放后 emoji 高度（≈ cellWidth 8.5pt），vertical 充足。

remediation **不应无必要改 baseline / vertical scale / cell height**，除非有 ink.height > cellHeight 的证据（Apple Color Emoji ink height ≈ pointSize < cellHeight 在多数字号成立）。若个别字号 ink.height > cellHeight，现有 `:467` 的 `min(slotWidth/ink.width, cellHeight/ink.height)` 已处理。✓

---

## 41. CG renderer

CG draw path（`:2051-2149`）：
- `:2052` 遍历 `preparedSegments`。
- `:2074-2107` 按 cell ordinal 计算 `positions`（grid origin）。
- `:2122-2133` 对 columnWidth>=2 段调 `glyphSlotFit` 得 `(dx,dy,scale)`，加到 `glyphPositions`（`positions` 的 copy）。
- `:2135-2149` 若 anyScaled，逐 glyph 用 `CTFontCreateCopyWithAttributes(ctRunFont, size*s, ...)` 缩小绘制；否则整 run `CTFontDrawGlyphs`。
- `:2151+` decorations（underline/strikethrough）用 `positions`（grid），不用 `glyphPositions`。

future fix 扩展 `glyphSlotFit` 到 1-cell overflow → CG path 自动消费（`computed[i]` 非 identity → anyScaled → 缩小绘制）。✓

---

## 42. Metal renderer

Metal renderer 存在：`Sources/SwiftTerm/Apple/Metal/Shaders.metal` + `AppleTerminalView.swift` 的 `metalView` 路径（`:2331-2348, :2406-2448, :2553-2573`）。Metal 用 `metalDirtyRange` + `requestMetalDisplay()` + GPU glyph atlas，**非逐 glyph `CTFontDrawGlyphs`**。

本评审**未发现 Metal path 调用 `glyphSlotFit`**（搜索仅 `:2126` CG path 一处）。docstring `:444-445`"Shared by CoreGraphics and Metal"是**设计意图，实现现状 Metal 未接入**。MacSSH 当前未启用 Metal（调查报告 §76），故 CG 是用户可见路径。

---

## 43. shared transform feasibility

**可行但需显式接线。** `GlyphSlotFit(dx,dy,scale)` 是值类型 struct，CG 与 Metal 可共用同一计算函数。现状 Metal 未调它。future remediation 应：
1. 扩展 `glyphSlotFit` guard/predicate（§34）—— CG path 立即受益。
2. 若 Metal path 有自己的 glyph positioning，须同步接入同一 `glyphSlotFit` 计算，或确认 Metal 的 atlas blit 也应用同一 scale。
3. 优先 **single source of transform**：`glyphSlotFit` 作为唯一 fit 计算入口，CG/Metal 都消费其结果，避免两套实现。

若 MacSSH 不启用 Metal，Metal parity 可作为 P2/future gate 不阻塞 CG fix；但 docstring 已承诺 shared，长期应兑现。✓

---

## 44. cache requirement

**需要 minimal cache。** 扩展到 1-cell 后，每个 fallback 1-cell glyph 都调 `CTFontGetAdvancesForGlyphs` + `CTFontGetBoundingRectsForGlyphs`，hot-path 成本上升。cache 必要。

---

## 45. cache key

**最小 cache key：**

```
(fontIdentity, glyph, cellWidth, cellHeight)
```

- `fontIdentity`：CTFont 的 PostScript name + size（或 ObjectIdentifier，但 size 变化时 font 对象变，ObjectIdentifier 隐含 size）。推荐 `PostScriptName + pointSize` 字符串 key，size 变化天然隔离。
- `glyph`：CGGlyph（UInt16）。
- `cellWidth` / `cellHeight`：CGFloat（snapped 后值，size 变化时变）。

value = `GlyphSlotFit(dx, dy, scale)`。

复用现有 `FallbackFontKey`（`:145`）模式的 cache 上限/LRU，不新增第二套 cache 基础设施。✓

---

## 46. cache invalidation

**font size 10→32 切换时 cellDimension 变 → cellWidth/cellHeight 变 → key 变 → 不会错误复用旧 fit。** ✓

key 含 `cellWidth` + `cellHeight`，两者随 `computeFontDimensions()` 重算而变。旧 size 的 cache entry（cellWidth=8.5）与新 size（cellWidth=19.0）key 不同，自动隔离。无需显式 invalidation。✓

若担心 cache 无限增长，复用现有 fallback cache 的 LRU 上限。✓

---

## 47. Highlight impact

**零影响。** Phase 6 highlight 只走 `.selectionBackgroundColor` channel（调查报告 §36）。highlight rect 由 grid origin 计算（`:1685-1687` element.column × cellDimension.width），`glyphSlotFit` 只改 `glyphPositions`（局部），不改 `positions`（grid）。highlight background 仍覆盖完整 logical cell。✓

future fix 仍须 GUI A/B 验证 highlight background 不被缩放 glyph 遮挡边缘。✓

---

## 48. Selection impact

**零影响。** `buildAttributedString:1129-1169` 只替换 foreground/background attributes，cell ordinal 与 glyph position 构造不读 selection（调查报告 §35）。selection rect 按 logical cell。复制仍保留原 VS16 scalar（fit 是 drawing-only，不改 stored grapheme）。✓

future fix 须验证 selection rect 仍按 logical cell、缩放不影响选区 fg/bg。✓

---

## 49. Cursor impact

**零影响。** caret x = `cellDimension.width × caretCol`（`:2513`），caret width = `cellDimension.width × cursorColumnWidth`（`:2514`）。`glyphSlotFit` 不改 `caretCol` / `caretView.frame`。future fix 前后 cursor **严格 = logicalColumn × cellWidth**，**不为视觉居中移动 cursor**。✓ 硬 gate（§57）。

---

## 50. PTY impact

**零影响。** future fix 停留 renderer drawing layer：
- stty size / TIOCSWINSZ / resizeChannelPTY：由 SwiftTerm `font` setter → `resetFont()` → `resize(cols:rows:)` 驱动，font size 变化已触发，glyph fit 不介入。
- PTY bytes：fit 不改 input/output bytes。✓

---

## 51. shell impact

**零影响。** future fix 不改：
- `buffer.x`（model cursor column）
- CharData width（preserve=1）
- CSI 序列
- paste bytes
- zsh / libc wcwidth

model 仍为 1 cell，shell 不可见 presentation scale。Phase 5 typed/pasted/history 测试作为硬 gate 保留。✓

---

## 52. Phase5 regression risk

**低，但必须保留 Phase 5 测试作为硬 gate。** Option F 严格 renderer-only，不改 policy/bytes。主要风险是缩放质量/baseline/性能，非 shell semantics。Phase 5 的 13 项测试（policy 配置、逻辑宽度、bracketed paste redraw、copy、CJK、non-VS16 emoji）须全绿。✓

---

## 53. future tests

future remediation 必须至少覆盖：

- `⚠️` / `❤️` typed、pasted、programmatic paste（`pasteText`）
- `A⚠️B❤️C`、separator `|⚠️|❤️|⚠️|❤️|`、四个连续 `⚠️⚠️⚠️⚠️` / `❤️❤️❤️❤️`
- `A⚠B❤C`（text presentation，须 untouched）
- left/right cursor、backspace、delete
- history up/down、Home/End
- wrapped long command、bracketed paste
- Local（preserve）+ Remote（widen，2-cell emoji 既有 path 须不回归）
- `😀` / `🚀` / `✅` 2-cell regression
- ASCII、CJK、combining marks、italic/bold
- selection、highlight、copy、cursor、inverse/ANSI background

---

## 54. font-size matrix

future tests 覆盖 **10 / 14 / 18 / 24 / 32 pt** 全部，每个 × Local/Remote × CG（+ Metal 若启用）× 1x/2x。✓

---

## 55. separator metric

调查报告建议 separator glyph origin 相对 grid error ≤ 0.5pt@2x。

**独立评价：应进一步收紧。** 源码 `:2078` separator origin = `cellIndex × cellDimension.width`，**逻辑上是精确的**（无浮点累计，每 cell 独立 `CGFloat(glyphColumn) * cellDimension.width`）。2x 下 0.5pt = 1px 的 raster 误差来自 backing store pixel alignment，非 origin 计算误差。

**最终 threshold：separator glyph origin 逻辑误差 = 0 pt**（源码精确）。允许的 2x raster 半像素抖动 ≤ 0.5pt 仅作为 bitmap 测量容差，不作为 origin 正确性标准。renderer architecture 能直接测 exact grid origin 时，应要求逻辑误差 = 0。✓

---

## 56. ink metric

调查报告建议 fit 后 1-cell VS16 ink 完全落入 logical cell，允许抗锯齿边缘 ≤ 0.5pt。

**独立评价：合理。** fit 后 ink.maxX ≤ cellRect.maxX + 0.5pt（2x 一像素 AA 边缘）。这是 ink-containment 的合理容差。**最终验收 metric：**

```
rightOverhang = renderedNonTransparentBounds.maxX - logicalCellRect.maxX
rightOverhang ≤ 0.5 pt (2x)
leftOverhang = logicalCellRect.minX - renderedNonTransparentBounds.minX
leftOverhang ≤ 0.5 pt (2x)
```

（左右均须满足，因 fit 后居中可能有左 ink 边缘。）✓

---

## 57. cursor metric

**Hard gate：**

```
cursorX == logicalColumn × cellWidth   (精确，零容差)
model cursor column (buffer.x) == fix 前值 (零变化)
caretWidth == cellWidth × cursorColumnWidth (零变化)
```

不为视觉居中移动 cursor。✓

---

## 58. accept-overhang option

**不可让 Phase 9 FINAL PASS。** 32pt visible overhang 12–13pt 覆盖相邻 ASCII（架构保证 overhang > 0，调查报告 bitmap 已显示内容可读性受损）。用户已明确认为视觉异常。Option A 拒绝。✓

---

## 59. clip option

**拒绝。** 硬切 ❤️/⚠️ 右侧丢失图形信息，保留错误尺寸且截断视觉，质量不可接受。✓

---

## 60. widen option

**拒绝。** 改回 widen 会重新使 Local SwiftTerm width=2、macOS zsh width=1，恢复 bracketed-paste redraw drift、history 漂移（`eecho`）、cursor-left drift。Phase 5 测试 `testBracketedPasteRedrawDivergesUnderDefaultPolicy` 实证默认模式 redraw 漂移。**除非有极强新端到端证据，预期拒绝。本评审无任何此类证据。** ✓

---

## 61. reduce-max option

**不作为首选。** 32→24/28 只隐藏问题：24pt 仍有 ~9.5–10pt overhang，14pt baseline 也已存在。只在 renderer remediation 长期阻塞时作为临时产品降级。本评审不优先推荐。✓

---

## 62. safest remediation

**Option F+B（presentation-only glyph fit，uniform scale 保 aspect ratio，metrics-driven predicate，CG/Metal 共用，带 cache）。**

- 复用现有 `glyphSlotFit` 的 ink-overflow + uniform-scale + center 逻辑
- 放宽 guard 到 columnWidth==1 + ink overflow（§34 predicate）
- CG path 自动消费；Metal 须显式接线（§43）
- cache key (fontIdentity, glyph, cellWidth, cellHeight)（§45）
- 不改 model/cursor/PTY/bytes/policy
- 验收 gate §55–§57

---

## 63. rejected approaches

拒绝：strip VS16、改 PTY/input/output bytes、插空格、改 zsh/libc wcwidth、按字号加 spacing magic number、Option C clip、Option G widen、仅 Option D 平移、重复实现 Option E（fixed grid 已是现状）。✓

---

## 64. whether SwiftTerm fork change required

**是，修复必须进入 SwiftTerm fork。** 根因位于 `AppleTerminalView.swift` renderer（`glyphSlotFit:446-486` + draw path `:2122-2149` + Metal path）。现有 public host API **无**安全的 per-glyph presentation transform hook。MacSSH 外部无法安全 hook renderer 的 glyph positioning。✓

---

## 65. suggested future fork branch

若进入 remediation，从 `771e79f092a26e7fba7af0ab2b09a2bf10213109` 新建专用 branch：

**`macssh-vs16-one-cell-render-fit`**

本阶段不创建。✓

---

## 66. exact-revision strategy

future fix 验收后生成新的 immutable SwiftTerm commit SHA。MacSSH production dependency（`Package.resolved` + `ThirdParty/MANIFEST.txt`）**只在 independent fork acceptance 后推进 exact revision**。验收前不改 pin。✓

---

## 67. whether Phase9 FINAL PASS remains blocked

**是，Phase 9B FINAL PASS 保持 BLOCKED，直到 renderer remediation 完成。**

理由：
1. P1（§2）成立——1-cell VS16 overflow 覆盖相邻字符，架构链独立确认。
2. 用户已能肉眼复现 32pt 缺陷。
3. remediation 未实现，fix 方向虽正确但无代码。
4. 唯一分类选择为任务书 §48 的 **C**：需小 Phase 9C rendering remediation 后才能 FINAL PASS。

---

## 68. whether remediation is authorized from architecture perspective

**从架构视角，remediation 方向（Option F+B）已通过独立评审，可授权实现。** 但：
- 须先提交预览/对比 bitmap + 数学 fit 规则供用户 UI 视觉确认（AGENTS.md UI 规则）。
- 确认后才改 SwiftTerm renderer。
- 本评审不授权立即改代码，只确认架构方向正确。

---

## 69. remaining P1

**1 项 P1（§2）：1-cell VS16 Apple Color Emoji 未进 `glyphSlotFit`，相邻字符可读性受损。阻塞 FINAL PASS。**

---

## 70. remaining P2

**1 项 P2（§3）：future fit 须 CG/Metal 同源 + cache。** Metal path 当前未调 `glyphSlotFit`（docstring 声称 shared 但实现未接线），remediation 须消除该偏差。属 remediation 设计 gate。

---

## 71. remaining P3

多项 P3（§4）：
- Apple Color Emoji 非线性 scaling，禁止字号 magic number。
- ⚠️/❤️ 非透明像素差异。
- `glyphSlotFit` docstring "Shared by CG and Metal" 与 Metal 实现现状偏差。
- probe 产物存 `/tmp` 易丢失，建议可复现位置。

---

## 72. recommended next step

**STOP，等待用户授权 remediation。** 授权后：
1. 从 `771e79f...` 新建 branch `macssh-vs16-one-cell-render-fit`（本阶段不创建）。
2. 先产出预览 bitmap（fit 前/后对比）+ 数学 fit 规则（§34 predicate + §62）供用户 UI 确认。
3. 确认后改 `glyphSlotFit` guard/predicate + Metal 接线 + cache。
4. 按 §53/§54 测试矩阵 + §55–§57 验收 gate 验收。
5. 独立 fork acceptance 后推进 production exact revision。

---

## 73. final status

**ARCHITECTURE / ROOT-CAUSE PASS — ROOT CAUSE INDEPENDENTLY VERIFIED FROM SOURCE — REMEDIATION DIRECTION (Option F+B) APPROVED AT ARCHITECTURE LEVEL — PHASE 9B FINAL PASS REMAINS BLOCKED PENDING AUTHORIZED PRESENTATION-ONLY REMEDIATION — STOP.**

---

## 验证记录

### 独立源码复核

- `ThirdParty/SwiftTerm-fork` HEAD = `771e79f092a26e7fba7af0ab2b09a2bf10213109`，`git status --short` 空（fork 未被 Phase 9C 修改）✓
- `TerminalOptions.swift:64-87` VS16 policy ✓
- `LocalTerminalService.swift:33-39` preserve ✓
- `Terminal.swift:1495-1539` preserveBaseWidth 语义（oldSize=1，不 widen，不插续接，不移 buffer.x）✓
- `AppleTerminalView.swift:409-438` cellWidth = "W" advancement + snap ✓
- `:446-486` glyphSlotFit（guard :450、advance :458、bounds :462、uniform scale :467、center :474、vertical :479）✓
- `:2122-2149` draw path（columnWidth>=2 guard、glyphPositions copy、CTFontDrawGlyphs）✓
- `:2074-2107` glyph origin = glyphColumn × cellDimension.width（fixed grid）✓
- `:2504-2515` caret x = cellDimension.width × caretCol ✓
- `:224-232` GlyphSlotFit struct ✓
- `:2406-2448` Metal path（metalDirtyRange + requestMetalDisplay，未调 glyphSlotFit）✓
- `:62-88` ViewLineSegment（utf16ToCellOrdinal map）✓
- `:1121-1126` buildAttributedString 按 width 分段 ✓

### 独立测试复核

- `Tests/SSH/TerminalVS16WidthPolicyTests.swift`（13 项）：Local preserve ✓、Remote widen ✓、⚠️/❤️ width=1 ✓、VS16 留 cluster ✓、😀/🚀 width=2 ✓、CJK width=2 ✓、bracketed paste preserve 干净 ✓、默认漂移 ✓、copy/long command/ASCII+CJK ✓。

### 独立 git 复核

- branch = `feature/macssh-1.1-terminal-font-size` ✓
- HEAD = `c6bf66c2b985530e6687fefe62cdf08246190e41` ✓
- SwiftTerm pin = `771e79f...` @ canbyte0/SwiftTerm.git ✓
- fork clean ✓
- working tree = Phase 9B 既有内容 ✓

### 不可独立复核项（probe 已清除）

- `/tmp/macssh_phase9c_probe/` CoreTextMetrics/ModelProbe/TerminalViewProbe binaries + 5 PNG + profraw：**已不存在**。
- 精确 advance/bounds/overhang 数值、CTLine run count、2x PNG 像素扫描：**无法重新测量**。
- 根因架构链不依赖这些数值，已从源码独立确立。

## STOP

未修改 production code / SwiftTerm fork / MacSSH；未创建 fork branch；未 commit / merge / push；未开始 remediation。等待用户授权。
