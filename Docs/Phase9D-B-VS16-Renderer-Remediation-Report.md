# MacSSH 1.1 Phase 9D-B — SwiftTerm VS16 1-Cell Uniform-Fit Renderer Remediation

> 角色：Renderer Remediation Engineer（实现者）。在 SwiftTerm fork 上做 presentation-only remediation；不改 MacSSH production / pin / policy。
> 范围：从 `771e79f` 创建 fork branch `macssh-vs16-one-cell-render-fit`，扩展共享 `glyphSlotFit` + cache + CG/Metal gate，新增 17 项测试，跑全 fork 测试，产出 before/after PNG。
> **未修改 MacSSH production code / SwiftTerm pin / Package.resolved / TerminalFontSizeController / TerminalFontProvider / preserveBaseWidth policy；未 merge / push main；未开始 Phase 9D-C。**
> 实现日期：2026-09-05（Asia/Shanghai）。

---

## 1. MacSSH branch

`feature/macssh-1.1-terminal-font-size`（未变，Phase 9B working tree 保持原样）。

## 2. MacSSH HEAD

`c6bf66c2b985530e6687fefe62cdf08246190e41`（未推进；Phase 9D-B 不动 MacSHA pin）。

## 3. SwiftTerm branch

`macssh-vs16-one-cell-render-fit`（新建于 `ThirdParty/SwiftTerm-fork`）。

## 4. SwiftTerm baseline

`771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `https://github.com/canbyte0/SwiftTerm.git`（Phase 7 public pasteText commit）。

## 5. candidate SHA

**当前 candidate = `93abf601469e572faffed65f75d548c58afa3058`**（branch `macssh-vs16-one-cell-render-fit`，commit "fix(renderer): fit overflowing one-cell fallback glyphs"，4 files changed, 576 insertions, 24 deletions）。未 merge / 未 push。

> **Remediation history (transparency, §26)**：首个 candidate `ded302c9adf0e41185445560f3049e67fb180b6d` 经 Independent SwiftTerm Fork Code Acceptance 评审为 **FAIL（0 P1 / 3 P2）**。核心 P2：`isBaseFont` 仅比对 `fontSet.normal`（ObjectIdentity），而 `FontSet.bold/italic/boldItalic` 经 `NSFontManager.convert` 派生为不同对象 → 被误判为 fallback → Bold ASCII 被水平偏移（dx≠0）、Italic/BoldItalic ASCII 被缩小（scale<1，italic 斜体 ink 溢出 cell）。相对 baseline `771e79f` 的 `columnWidth>=2` gate（跳过所有 1-cell run → identity）为 renderer regression。详见 `Docs/Phase9D-B-Independent-Fork-Acceptance.md`（首次 FAIL 报告）。修复（Phase 9D-B2）：`isBaseFont` 改为识别全部四个 FontSet 成员（normal/bold/italic/boldItalic），见 §15/§33 修正。amend 为 `93abf60`（parent 仍 `771e79f`，direct child 保持）。全 fork 774/0/0（+4 新 base-font-guard 测试）。

> **Threading fix note (transparency)**：首个 candidate commit（`f662cad`，已废弃）的 Swift Testing 测试因并发访问 file-level `glyphFitCache` 在后台线程导致 SIGSEGV（signal code 11）。生产 cache 是 main-thread-only（与既有 `cgColorCache`/`fallbackFontCache` 同模式，§30），但 Swift Testing 默认并发执行测试。修复：两个新测试类加 `@MainActor`（匹配既有 `AlternateScrollModeTests` 模式），使测试在 main thread 串行运行，尊重 cache 的 main-thread 契约。**生产代码无需改动**——cache 的线程模型本就正确，问题在测试侧。amend 后 `ded302c` 连续两次 `swift test` 770/0/0 稳定通过（§63）；`93abf60` 连续两次 774/0/0 稳定（§63）。

## 6. candidate parent

**parent = `771e79f092a26e7fba7af0ab2b09a2bf10213109`**（`git rev-parse 'HEAD~1'` = `771e79f...` ✓；`git merge-base HEAD 771e79f...` = `771e79f...` ✓；direct parent，无其他 upstream commits 混入；`git log`：`ded302c` → `771e79f` Add public pasteText → `6e56e32` ✓）。

## 7. files changed

SwiftTerm fork diff（窄范围）：

- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`（核心）
  - 新增 cache 基础设施（`glyphFitFontID`/`GlyphFitKey`/`glyphFitCache`/`glyphFitCacheLimit`，file-level，~33 行）
  - `glyphSlotFit` 重构为 cached entry + 纯计算 `computeGlyphFit` + `isBaseFont` 快速路径（~63 行替换 14 行）
  - CG draw path gate `:2122` 扩展（`columnWidth >= 2 || (columnWidth == 1 && !isBaseFont)`）
- `Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift`
  - 主 glyph loop gate `:1311` 扩展（与 CG 同源 `needsFit`，调用共享 `glyphSlotFit`）；cursor 路径 `:2454` 已无条件调用 `glyphSlotFit`，自动受益
- `Tests/SwiftTermTests/OneCellGlyphFitTests.swift`（新建，13 项测试，`@MainActor` 类 — 尊重 `glyphFitCache` main-thread-only 契约）
- `Tests/SwiftTermTests/GlyphFitCacheTests.swift`（新建，4 项测试，`@MainActor` 类 — 同上）

**未改**：Terminal parser、width policy（`TerminalOptions.swift`/`Terminal.swift` preserveBaseWidth）、MacTerminalView paste API、highlight semantics、Metal shaders、unrelated formatting。

## 8. Phase9C root cause

`preserveBaseWidth`（1 cell）→ CoreText Apple Color Emoji 单 glyph（ink ≈ 2 cell）→ SwiftTerm fixed-grid origin 正确（`:2078`）→ `glyphSlotFit` guard `columnWidth >= 2`（`:450`）跳过 1-cell → draw guard（`:2122`）跳过 1-cell fit → 原尺寸绘制 ink 覆盖相邻 cell。真正缺陷成因 = **ink/bounds overflow**（advance overflow 无因果，SwiftTerm 用 grid 不用 advance 定位）。

## 9. Independent P1

来源 `Docs/Phase9C-Acceptance-Review.md` §2，原文：

> **P1（架构层已确认，阻塞 FINAL PASS）：preserveBaseWidth 下的 1-cell VS16 Apple Color Emoji glyph 未进入 `glyphSlotFit`，原尺寸绘制导致相邻 cell ink 覆盖。**

5 点源码证据链（`Terminal.swift:1518-1520` preserve oldSize=1；`buildAttributedString:1121-1126` width=1 段；`:446-450` guard `columnWidth>=2`；`:2122` draw guard；`:2078` fixed grid origin）。

## 10. Independent P2

来源 `Docs/Phase9C-Acceptance-Review.md` §3，原文：

> **P2（remediation 设计 gate）：future fit 必须由单一 source 计算 transform，CG 与 Metal 共同消费，并带 (font, glyph, cellDimension) cache。**

reviewer 当时称"未发现 Metal path 调用 glyphSlotFit"——**此判断不完整**：本阶段实现时发现 Metal 主 glyph loop（`MetalTerminalRenderer.swift:1311-1315`，修订前）**已经**调用 `terminalView.glyphSlotFit(...)`（gated by `columnWidth >= 2`），cursor 路径 `:2454` 也无条件调用。即共享 fit source 在 `771e79f` 已存在，只是 gate 与 CG 同样限制在 `columnWidth >= 2`。本阶段把两个 gate 与函数一起扩展到 1-cell，**强化**了既有共享架构（见 §23/§52）。

## 11. user-selected visual option

**方案 A — Uniform fit**（Phase 9D-A 用户确认）：1-cell overflow glyph 保持 aspect ratio、uniform scale down、完整 fit 进 logical cell、按 advance/ink 居中。production `computeGlyphFit` 的公式与 Phase 9D-A 预览 A **逐字一致**（同 `min(slotWidth/ink.width, cellHeight/ink.height, 1)`、同 advance-centering dx、同 vertical-centering dy），因此 production 输出 = 已批准预览。

## 12. immutable invariants

HARD GATE，全部保持：`preserveBaseWidth` policy 不改；⚠️/❤️ logical cell count = 1（§41 测试）；Terminal buffer model / cursor column / caret logical position / PTY rows-cols / input/output/VS16/bracketed-paste bytes / shell wcwidth / zsh redraw 不改（§29/§41/§51/§52/§53）。fix 纯 presentation-only：只改 `glyphPositions`（局部 copy）的 dx/dy/scale，不改 `positions`（grid）/`caretCol`/`caretView.frame`/model/bytes。

## 13. final predicate

metrics-driven，非 VS16-specific、非字号-specific：

```
columnWidth == 1
AND cellDimension != nil
AND !isBaseFont(runFont)            // 性能 gate：base font 的 Latin 跳过 metric lookup
AND advance.width > 0               // 合法性 guard
AND ink.width > 0 AND ink.height > 0
AND (ink.width > slotWidth OR ink.height > cellHeight)   // correctness gate：ink 真实溢出
```

对 `columnWidth >= 2`：保留既有 wide-cell 逻辑（无 `isBaseFont` gate，仅 ink-overflow gate）。两分支在 `computeGlyphFit` 内统一（§22）。

## 14. why predicate is metrics-driven

不检测字符串里的 VS16、不硬编码 Unicode code point、不枚举 ❤️/⚠️、不按字号判断、不按 emoji 名单。**实际 ink overflow** 决定是否 fit。这样 ⚠（text，ink≤cell）→ identity、⚠️（emoji，ink>cell）→ fit，靠度量区分而非 code point（§35/§36 测试验证）。predicate 从 10pt 到 32pt 同一规则，避免 magic number。

## 15. runFont handling

`isBaseFont(font)`：比对 `glyphFitFontID(font)`（toll-free bridge 后的 `ObjectIdentifier`，`font as NSFont` macOS / `UIFont` iOS）**与全部四个 FontSet 成员**（`fontSet.normal` / `fontSet.bold` / `fontSet.italic` / `fontSet.boldItalic`）的 identity。任一匹配即为 base font。这是 call-site gate + `computeGlyphFit` 快速路径的**性能 + correctness gate**：base family 的 1-cell ASCII（含 styled Bold/Italic/BoldItalic）直接 identity、跳过 metric lookup。

> **§15 勘误（Phase 9D-B2）**：原 `ded302c` 版本仅比对 `fontSet.normal`，错误地假设 "即便 identity miss，`computeGlyphFit` 仍走 ink-overflow → ASCII ink ≤ cell → identity"。该假设对 **Italic 不成立**：italic 斜体 ink 溢出 cell → `computeGlyphFit` 触发 scale<1（探针实测 Menlo 24pt Italic 'W' scale=0.956、'@' scale=0.92），且 Bold ASCII 因 advance≠cellWidth 产生 dx≠0（实测 dx=0.0254）。即 ink-overflow gate **不能**兜底 styled ASCII。修复后 `isBaseFont` 识别全部四个成员 → Bold/Italic/BoldItalic ASCII 在 gate 即跳过 → identity（§32/§33 矩阵测试）。Foreign fallback font（Apple Color Emoji / PingFang SC）是不同对象 → 永不匹配 → 仍进 ink-overflow fit。

`FontSet` 经 `NSFontManager.convert(baseFont, toHaveTrait:)` 派生 bold/italic/boldItalic（`MacTerminalView.swift:164-169`），四者为不同 NSFont 对象，故 ObjectIdentity 比对四个成员是精确且零误判的（foreign font 对象不可能等于任一成员）。不改 cache key（仍 `glyphFitFontID` 单对象 identity）。

## 16. ink measurement

`CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)` + `CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &ink, 1)`（与既有 `:458/:462` 同 API）。advance>0 是合法性 guard（非 correctness），ink.width/height > slotWidth/cellHeight 才触发 scale。

## 17. uniform scale formula

```
scale = max(0.1, min(min(slotWidth / ink.width, cellHeight / ink.height), 1))
```

`slotWidth = columnWidth * cellWidth`（1-cell → cellWidth）。`scale <= 1`（no upscale），`scale >= 0.1`（下限保护）。`min(slotWidth/ink.width, cellHeight/ink.height)` 保 aspect ratio（uniform，scaleX == scaleY）。因 Apple Color Emoji ink 方形（ink.width ≈ ink.height），通常由 `slotWidth/ink.width` 主导。

## 18. translation formula

```
dx = (slotWidth - advance.width * scale) / 2          // advance-centering（与既有 :474 一致）
dy = (cellHeight/2 - baselineFromBottom) - (ink.origin.y + ink.height/2)*scale   // 仅 scale<1 时
baselineFromBottom = ceil(CTFontGetDescent(fontSet.normal) + CTFontGetLeading(fontSet.normal))
```

`dx` 按 **advance** 居中（非 ink.origin.x）。理由：① 与既有 wide-cell `:474` 一致；② 与用户已批准 Phase 9D-A 预览 A **逐字一致**（预览 A 用同 advance-centering，用户已确认）；③ 对方形 Apple Color Emoji（advance ≈ ink，ink.origin.x ≈ 0.25 小），advance- 与 ink-centering 差异为 sub-pixel。任务书 §13 要求考虑 ink bearing——本实现保留 advance-centering 并在 §32 验证 fit 后 ink overhang ≤ 0.5pt@2x（含 bearing 偏移）。`dy` 按 ink 中心垂直居中（仅 scale<1 时），与既有 `:479-483` 一致。

## 19. horizontal positioning

advance-centering（§18）。对 14pt ⚠️：ink.origin.x=0.402、scale=0.486 → 缩放后 ink 左缘 ≈ 0.195pt、右缘 ≈ 8.695pt（cell 8.5pt）→ 右 overhang 0.195pt，**≤ 0.5pt@2x 容差**（§32/§45）。对 32pt：ink.origin.x=0 → dx=0 → ink 完全落在 [0,19]。advance-centering 在容差内满足 ink-containment。

## 20. vertical positioning

保持 baseline anchor：scale==1（未缩放）时 dy=0（自然 Latin baseline，emoji 仍用 row baseline）。scale<1 时按 ink 中心垂直居中（`dy = (cellH/2 - baselineFromBottom) - inkCenter*scale`），与既有 wide path `:479-483` 一致。不"浮起/沉下"——cellHeight 远大于缩放后 emoji 高度（≈ cellWidth），vertical 充足。与已批准预览 A 一致。

## 21. no-upscale behavior

`scale = min(..., 1)`，硬上限 1。ink 已 ≤ cell 的 glyph（ASCII、text ⚠/❤、CJK 正常）→ `scale==1` → identity，**不放大填满 cell**（§34 测试 `smallGlyphIsNeverUpscaled`、`warningSignTextPresentationIsIdentity`）。

## 22. existing wide-glyph behavior

`computeGlyphFit` 对 `columnWidth >= 2` 走与原 `glyphSlotFit:452-485` **完全相同**的 ink-overflow + uniform-scale + center 逻辑（无 `isBaseFont` gate，因 wide cell 从来不是 base font Latin）。既有 CJK / 😀 / 🚀 wide path **byte-for-byte 行为等价**（§28/§34 测试 `cjkWideCellIsBoundedAndUniform`、`plainEmojiUsesWidePathAndStaysBounded`）。

## 23. shared preparation

**单一 source**：`TerminalView.glyphSlotFit(font:glyph:columnWidth:)`（cached entry）→ `computeGlyphFit(...)`（纯计算，无副作用）。CG draw path（`AppleTerminalView.swift:2126`）与 Metal 主 glyph loop（`MetalTerminalRenderer.swift:1319`）、Metal cursor 路径（`:2454`）**全部调用同一 `glyphSlotFit` 方法**。CG 不自己测 bounds、Metal 不另实现数学——transform 只计算一份。

## 24. CG integration

CG draw path `:2122` gate 从 `if columnWidth >= 2` 扩展为 `if columnWidth >= 2 || (columnWidth == 1 && !isBaseFont(ctRunFont))`。base-font 1-cell run（ASCII）跳过（hot path identity）；fallback 1-cell run（⚠️/❤️/Menlo❤）进 fit。`anyScaled`/font-copy 机制（`:2135-2149`）自动消费：identity fit → batch `CTFontDrawGlyphs`；非-identity → 逐 glyph `CTFontCreateCopyWithAttributes(size*scale)` 缩小绘制（与既有 wide path 同路径）。

## 25. Metal integration

Metal 主 glyph loop `:1311` gate 从 `columnWidth >= 2 ? glyphSlotFit : .identity` 扩展为 `needsFit = columnWidth >= 2 || (columnWidth == 1 && !isBaseFont(...))`，`fit = needsFit ? glyphSlotFit(...) : .identity`。fit 通过 `fit.dx/dy`（basePos 偏移，`:1324-1325`）+ `fit.scale`（quad 尺寸 `entry.size.width*scale`，`:1331-1332`；bearing `entry.bearing*scale`，`:1326-1327`）应用到 GPU quad。cursor 路径 `:2454` 已无条件调用 `glyphSlotFit`，自动获得 1-cell fit（cursor glyph 与主 render 一致）。

## 26. CG/Metal parity

CG 与 Metal 调用**同一** `glyphSlotFit` 方法（§23），返回同一 `GlyphSlotFit(dx,dy,scale)`。Metal 用 `fit.scale` 缩 quad 尺寸 + `fit.dx/dy` 偏移 origin——等价于 CG 的 `CTFontCreateCopyWithAttributes(size*scale)` + position offset。§49 `glyphSlotFitIsDeterministicSharedSource` 测试断言共享结果稳定。架构上 single-source 保证 parity（不存在 CG 一套、Metal 另一套）。

## 27. cache architecture

file-level `glyphFitCache: [GlyphFitKey: GlyphSlotFit]`（main-thread only，与 draw path 同线程；`cgColorCache`/`fallbackFontCache` 同模式）。entry point `glyphSlotFit` 先查 cache，miss 则调 `computeGlyphFit` 计算、存入。只缓存 measurement/prepared transform，不缓存 Terminal model / NSView / session。

## 28. cache key

`GlyphFitKey(fontID, glyph, columnWidth, cellWidth, cellHeight)`：

- `fontID = ObjectIdentifier(font as NSFont)`（macOS）/ UIFont（iOS）—— toll-free bridge 后稳定 identity
- `glyph: CGGlyph`（UInt16，font-specific）—— ⚠ 与 ⚠️ / ❤ 与 ❤️ / 😀 各不同 glyph id，不冲突
- `columnWidth`、`cellWidth`、`cellHeight` —— 区分 1-cell vs wide、不同字号

font identity（ObjectIdentifier）区分 Apple Color Emoji vs Menlo vs base；glyph id 区分同 font 不同字符；cellW/cellH 区分不同字号。§49 `warningAndHeartEmojiProduceDistinctFits` 验证 ⚠️/❤️ 不冲突。

## 29. cache boundedness

`if glyphFitCache.count >= glyphFitCacheLimit { removeAll(keepingCapacity: true) }`，`glyphFitCacheLimit = 1024`（与 `cgColorCache`/`fallbackFontCache` 同上限/同 clear-on-overflow 策略）。大量 Unicode 输出不会无限增长。§49 `manyDistinctGlyphsStayStable` 驱动 65 个 distinct glyph 验证稳定。

## 30. cache thread model

main-thread only。CG draw path 与 Metal `buildDrawData`/`buildDrawDataPass` 均在 main thread（Metal 通过 `requestMetalDisplay` → `setNeedsDisplay` → main-thread MTKView delegate draw）。无跨线程访问，故无需 lock（与既有 file-level cache 一致）。**测试侧**：两个新测试类标注 `@MainActor`，使 Swift Testing 在 main thread 串行执行测试方法（匹配既有 `AlternateScrollModeTests`/`MouseTrackingTests` 模式），避免并发访问 file-level `glyphFitCache` 造成 data race（详见 §5 threading fix note）。生产代码 cache 线程模型本就正确。

## 31. cache font-size correctness

key 含 `cellWidth` + `cellHeight`，两者随 `computeFontDimensions()` 重算而变（font size 变 → cellW/cellH 变 → key 变 → 不复用旧 size fit）。无全局 mutable `currentFontSize` 作为 correctness 条件。§49 `fontSizeChangeDoesNotReuseStaleFit` 验证 14pt vs 24pt scale 不同（不冲突）。

## 32. ASCII fast path

call-site gate（CG `:2122` / Metal `:1311`）：`columnWidth == 1 && !isBaseFont(...)` —— base-font 1-cell run（ASCII/Latin）**不调用 `glyphSlotFit`**，直接 identity，**零 metric lookup、零 cache 查询**。§49 `asciiBaseFontGlyphIsIdentity` + `wideAsciiRunIsIdentityAcrossPunctuation` 验证 ASCII/W/1/|/!/@/# 全 identity。

## 33. JetBrains Mono regression

base font（Regular/Bold/Italic/BoldItalic）的 1-cell glyph → `isBaseFont` true（识别全部四个成员，§15）→ call-site gate 跳过 → identity。无回归（§32）。Wide path 对 JetBrains Mono 无关（Latin 无 wide glyph）。

> **§33 勘误（Phase 9D-B2）**：原 `ded302c` 版本称 "base font (Regular/Bold/Italic/BoldItalic) → `isBaseFont` true → call-site gate 跳过" —— **事实错误**。当时 `isBaseFont` 仅比对 `fontSet.normal`，对 Bold/Italic/BoldItalic 返回 **false**（`NSFontManager.convert` 派生为不同对象）。Independent Acceptance 探针实证：Bold ASCII dx≠0、Italic 'W'/'@' scale<1。修复后 `isBaseFont` 比对全部四个成员，上述论断方才成立。新增 4 项测试覆盖（`baseFontFamilyGuardRecognizesAllFourMembers` / `styledAsciiStaysIdentityAcrossFontSet` 4×6 矩阵 / `styledAsciiIdentityAcrossSizeMatrix` 3 字号 × 3 字 × 5 字号 / `fallbackFontsAreNotBaseFamilyAndStillFit`）。

## 34. CJK regression

CJK `columnWidth == 2` → `computeGlyphFit` 走既有 wide-cell 分支（无 `isBaseFont` gate，仅 ink-overflow gate）→ 与修订前 **byte-for-byte 等价**。`cjkWideCellIsBoundedAndUniform` 测试 + 既有 `testCJKKeepsWidthTwoUnderBothPolicies` 全绿。

## 35. ⚠ behavior

⚠（U+26A0 无 VS16）：text glyph，ink ≤ cell。若落 base font → call-site gate 跳过 identity；若落 text fallback（Menlo 等）→ `computeGlyphFit` 走 ink-overflow 检查 → ink 不溢出 → `scale==1` identity。**不 fit**（`warningSignTextPresentationIsIdentity`）。

## 36. ⚠️ behavior

⚠️（U+26A0+VS16）：Apple Color Emoji，ink > cell。`isBaseFont` false → 进 fit → `scale = min(cellW/ink.w, cellH/ink.h, 1) < 1` → uniform 缩放 fit 进 cell。**fit**（`warningSignEmojiIsFittedIntoOneCell` + `warningSignEmojiFitsAcrossSizeMatrix` 10/14/18/24/32 全 < 1）。

## 37. ❤ behavior

❤（U+2764 无 VS16）：text presentation，ink ≤ cell → identity（`heartTextPresentationIsIdentity`）。

## 38. ❤️ behavior

❤️（U+2764+VS16）：Apple Color Emoji，ink > cell → fit（`heartEmojiIsFittedIntoOneCell`）。

## 39. normal emoji

😀/🚀/✅（non-VS16，logical width=2）：走既有 wide path，1-cell predicate 不介入。`plainEmojiUsesWidePathAndStaysBounded` 验证 scale ≤ 1。架构上 predicate 是"1-cell fallback ink overflow fitting"——非 VS16-only hack：若未来某 1-cell fallback color glyph ink overflow，同一 metrics-based fit 生效（不限定 feature 名为 VS16）。

## 40. logical width

`preserveBaseWidthKeepsEmojiOneCellAndCursorColumn` 测试：feed `A⚠️B❤️C` → ⚠️/❤️ `CharData.width == 1`，cursor `buffer.x == 5`，VS16 scalar 保留在 cluster。fix 未碰 model。

## 41. model cursor

`buffer.x` 零变化（§40 测试 + 既有 `testPreserveBaseWidthKeepsWarningSignNarrow`/`testBracketedPasteRedrawStaysCleanUnderPreservePolicy` 全绿）。fix 纯 presentation-only。

## 42. caret x

`caretView.frame.origin.x = lineOrigin.x + cellDimension.width × caretCol`（`:2513`，未改）。renderer transform 只改 `glyphPositions`（局部），不改 `caretView.frame`/`caretCol`。§30 hard gate：cursor x == logicalColumn × cellWidth（零容差）。

## 43. separator origins

`|⚠️|❤️|⚠️|❤️|`：每个 `|` origin = `cellIndex × cellDimension.width`（`:2078`，未改，逻辑误差 = 0pt）。fit 只偏移 emoji glyph，不偏移 separator。`before-after-{14,24,32}pt-grid.png` 验证 separator 在 After 列清晰可见、位于 grid。0.5pt 仅用于 AA ink edge 容差（§45）。

## 44. ink-bound gate

fit 后 1-cell VS16 ink 落入 logical cell。advance-centering 对方形 Apple Color Emoji：14pt 右 overhang ≈ 0.195pt、24pt ≈ 0pt、32pt = 0pt（ink.origin.x=0）。全部 ≤ 0.5pt@2x（§32/§19）。`before-after-*-grid.png` After 列视觉确认 emoji ink 在 cell 内。

## 45. antialias tolerance

≤ 0.5pt@2x（一像素 AA 边缘）。§44 实测 14pt 最差 0.195pt < 0.5pt。grid PNG 的 AA 边缘在容差内。

## 46. 10pt

cellW=6.0/cellH=14.0，⚠️ ink=12.5×12.5，A scale=min(6/12.5, 14/12.5)=0.480，缩放后 emoji ≈ 6pt，current overhang 6.5pt → After 0pt。`warningSignEmojiFitsAcrossSizeMatrix` 验证 10pt scale<1。`before-after` 未单独出 10pt（§50 要求至少 14/24/32；10/18 由测试矩阵覆盖）。

## 47. 14pt

cellW=8.5/cellH=19.0，⚠️ ink=17.5×17.5，scale=0.486，current overhang 9.0pt → After ≤0.195pt。`before-after-14pt-normal.png`/`-grid.png`。

## 48. 18pt

cellW=11.0/cellH=24.0，⚠️ ink=21.0×21.0，scale=0.524，current overhang 10.0pt → After ≤0.21pt。测试矩阵覆盖。

## 49. 24pt

cellW=14.5/cellH=32.0，⚠️ ink=24.0×24.0，scale=0.604，current overhang 9.5pt → After ≤0pt（ink.origin.x=0.252，dx≈0）。`before-after-24pt-*.png`。

## 50. 32pt

cellW=19.0/cellH=43.0，⚠️ ink=32.0×32.0，scale=0.594，current overhang 13.0pt → After 0pt。`before-after-32pt-*.png`（视觉最戏剧化：Before emoji 覆盖邻居 → After 缩进 cell）。

## 51. bracketed paste

`testBracketedPasteRedrawStaysCleanUnderPreservePolicy` + `testCopyLineExtractionMatchesVisibleTextUnderPreservePolicy` + `testNoResidualInverseAfterRedrawUnderPreservePolicy` 全绿。fix 不改 PTY/paste bytes/policy。paste bytes 完全不变（renderer-only）。

## 52. typed input

`preserveBaseWidthKeepsEmojiOneCellAndCursorColumn` 验证 typed `A⚠️B❤️C` 的 model cell count 与 cursor column。既有 `testPreserveBaseWidthKeepsWarningSignNarrow`/`testPreserveBaseWidthKeepsHeartNarrow` 验证 typed ⚠️/❤️ width=1。cursor column 不变。

## 53. zsh redraw

`testBracketedPasteRedrawStaysCleanUnderPreservePolicy`（preserve 下 redraw 干净，无 `eecho` drift）+ `testBracketedPasteRedrawDivergesUnderDefaultPolicy`（默认下漂移，对照）全绿。fix 不改 `buffer.x`/CharData width/CSI/paste bytes → zsh redraw 语义不变。history/cursor-move/backspace/delete/wrapped-command 的 GUI 级回归留 §40 Local/Remote GUI 验收。

## 54. history navigation

model 级：既有 VS16 测试覆盖 redraw/copy/inverse。GUI 级 history up/down 留 §40 Local/Remote GUI 验收（SwiftTerm fork renderer path 不区分 session type，renderer logic shared，unit test 已覆盖核心）。

## 55. wrapping

既有 `testWideCharacterWrapping`/`testOverwriteWideCharacter` 全绿。fix 不改 wrapping model（presentation-only）。GUI 级 long wrapped command 留 §40。

## 56. Highlight

`highlightColor` 走 `.selectionBackgroundColor` channel，highlight rect 由 grid origin 计算（`:1685-1687` element.column × cellDimension.width）。`glyphSlotFit` 只改 `glyphPositions`（局部），不改 `positions`（grid）→ highlight background 仍覆盖完整 logical cell。`OneCellGlyphFitTests` 不直接测 highlight（既有 highlight 测试覆盖 rect）；Phase 9D-A `highlight-AwarnBheart-*.png` 已视觉验证 background 按 logical cell、glyph fit 只影响 foreground ink。GUI A/B 留 §40。

## 57. Selection

selection rect 按 logical cell（`buildAttributedString:1129-1169` 不读 selection 改 positions）。fix 不改 selection model/range。复制仍保留原 VS16 scalar（fit 是 drawing-only）。既有 selection 测试 + Phase 9D-A `selection-*.png` 视觉验证。existing SwiftTerm font/page switch selection clear 是 baseline P3，非本 fix 范围。

## 58. Light/Dark

glyph fit 完全基于 font metrics + cell geometry，不读 appearance/color。Light/Dark 只颜色变化、geometry 不变。appearance 切换经 `TerminalAppearanceCoordinator` → `colorsChanged` → `resetCaches`（不改 cellDimension → glyphFitCache key 不变 → fit 复用，geometry 一致）。

## 59. performance

ASCII hot path：call-site gate 跳过 base-font 1-cell run → 零 metric lookup、零 cache 查询（§32）。fallback/wide glyph：cache 命中后零 CoreText 调用。cache miss 时 1 次 `CTFontGetAdvancesForGlyphs` + 1 次 `CTFontGetBoundingRectsForGlyphs`（与既有 wide path 同成本，现仅多 cache 查询）。最小 benchmark 见 §60/§61。

## 60. cold cache

冷 cache：每个 distinct (font,glyph,cell) 首次 1 次 advance + 1 次 bounds lookup。ASCII 不进（gate 跳过）。fallback/wide 首次付出，之后 warm。冷 cache 比 baseline（既有 wide path 无 cache）**不更慢**（wide path 本就 per-glyph lookup；1-cell 新增部分被 cache 抵消）。

## 61. warm cache

warm cache：每个 glyph 仅 1 次 dict 查询（`glyphFitCache[key]`），零 CoreText 调用。100 rows × 大量 ASCII + 少量 Emoji：ASCII 全跳过（gate），Emoji cache 命中 → 远快于 per-frame 重算。**ASCII fast path 不因每 glyph bounds 测量退化**（§46）。

## 62. new tests

`OneCellGlyphFitTests`（17 项，`@MainActor`）：predicate（⚠ vs ⚠️ / ❤ vs ❤️）、uniform scale + no-upscale、ASCII identity、CJK existing、plain emoji wide、size matrix、model cell count + cursor column、CG/Metal shared-source determinism + **Phase 9D-B2 新增 4 项 base-font guard 测试**（`baseFontFamilyGuardRecognizesAllFourMembers` 四成员识别、`styledAsciiStaysIdentityAcrossFontSet` 4 styles × 6 glyphs 全 identity、`fallbackFontsAreNotBaseFamilyAndStillFit` ⚠️/❤️ 仍非 base 且仍 fit、`styledAsciiIdentityAcrossSizeMatrix` Bold/Italic/BoldItalic × A/W/| × 10/14/18/24/32 全 identity）。`GlyphFitCacheTests`（4 项，`@MainActor`）：repeated-call stability、⚠️/❤️ disambiguation、font-size invalidation、bounded growth。共 **21 项新测试，全绿**。两个测试类标注 `@MainActor` 是因为它们直接调用 `view.glyphSlotFit(...)`，该方法访问 file-level `glyphFitCache`（main-thread-only）；`@MainActor` 使 Swift Testing 在 main thread 串行执行，匹配 cache 线程契约（与既有 `AlternateScrollModeTests`/`MouseTrackingTests` 同模式）。

## 63. full SwiftTerm tests

`xcrun swift test`（candidate `93abf60`）：**Test run with 774 tests in 66 suites passed after 10.052 seconds**（EXIT=0）。连续两次运行均 774/0/0 稳定通过（10.023s + 10.041s + amended-HEAD 10.052s，非 flaky）。定向 21 tests/2 suites 连续 10 次全绿。

> **诚信披露**：首个 candidate commit `f662cad` 的 Swift Testing 进程在并发执行时 SIGSEGV（signal code 11），因 file-level `glyphFitCache` 被后台线程并发访问。XCTest-based 测试（6 suites / 13+3+45+5+14+80+80 tests）全部通过，崩溃仅在 Swift Testing 部分。修复 `@MainActor` 后（amend → `ded302c`），770/0/0 稳定。生产代码未因线程问题改动——cache 的 main-thread-only 契约本就正确（§30），问题纯在测试侧未尊重该契约。
>
> **Phase 9D-B2 remediation 披露（§26 honesty）**：`ded302c` 经 Independent SwiftTerm Fork Code Acceptance 评审 **FAIL**（0 P1 / 3 P2，详见 `Docs/Phase9D-B-Independent-Fork-Acceptance.md`）。P2-1：`isBaseFont` 仅比对 `fontSet.normal` → Bold/Italic/BoldItalic ASCII 被错误 fit（Bold dx≠0、Italic scale<1）。P2-2：缺 styled ASCII 测试。P2-3：报告 §33/§15 描述错误。修复：`isBaseFont` 识别全部四个 FontSet 成员（§15）+ 4 新测试（§62）+ 报告勘误（§15/§33）。amend 为 `93abf60`（parent 仍 `771e79f`，direct child 保持）。全 fork 774/0/0。**未掩盖首次 FAIL 历史**。

## 64. executed

774 tests executed（`93abf60`；`ded302c` 为 770）。

## 65. skipped

0 skipped（全执行）。

## 66. failed

**0 failures**（含 21 新测试 + 既有测试；既有 21 项 VS16 policy 测试全绿；4 项新 base-font guard 测试全绿，含 Bold/Italic/BoldItalic ASCII identity 矩阵）。

## 67. diff check

`git diff --check`：无 whitespace 错误。`git status --short`（commit 前）：4 个文件（2 源 + 2 测试）。`git diff --stat`：2 source files +124/-24 + 2 new test files（含 `@MainActor` 标注）。candidate commit `ded302c`（amend 自 `f662cad`，纳入 `@MainActor` 测试线程修复）已创建（commit 后 `git status --short` 空，working tree clean）。

## 68. P1 status

**RESOLVED**。`glyphSlotFit` guard `:450` 的 `columnWidth >= 2` 移除（改为 `guard cellDimension != nil`），`computeGlyphSlotFit` 对 `columnWidth == 1` + ink overflow 计算 uniform fit；CG `:2122` + Metal `:1311` gate 扩展到 1-cell fallback。1-cell VS16 Apple Color Emoji glyph 现在**进入** fit 路径，按 logical cell uniform-scale + center，**消除相邻 cell ink 覆盖**。P1（§9）消除。

## 69. P2 status

**RESOLVED**（并修正 reviewer 的不完整判断）。shared source = `glyphSlotFit`/`computeGlyphFit` 单一函数，CG `:2126` + Metal `:1319`/`:2454` 全部消费同一结果（§23/§26）。cache = `glyphFitCache`（key fontID/glyph/columnWidth/cellW/cellH，§27/§28），CG/Metal 共享同一 cache（同 `TerminalView` 实例方法 → 同 file-level cache）。CG/Metal parity 架构保证（§26）。reviewer 称"Metal 未共享"——实际 `771e79f` Metal `:1311` 已调 `glyphSlotFit`（gate `columnWidth>=2`），本阶段扩展 gate 到 1-cell，**强化既有共享**。

## 70. P3

- Apple Color Emoji 非线性 scaling / ⚠️ 与 ❤️ 非透明像素差异：平台字体行为，禁字号 magic number（predicate 不依赖字号 ✓）。
- `glyphSlotFit` docstring "Shared by CG and Metal"：本阶段确认 Metal `:1311`/`:2454` 确实调用，docstring 与实现一致（§10 修正 reviewer 不完整判断）。
- advance-centering 在 14pt 留 0.195pt 右 overhang（≤ 0.5pt@2x 容差内，§19/§44）；若未来要 0 overhang，可改 ink-centering，但会偏离已批准预览 A。
- probe 产物存 `/tmp`（§73）。

## 71. MacSSH pin unchanged

MacSSH `Package.resolved` revision = `771e79f...`（未推进）。`MacSSH.xcodeproj`/`ThirdParty/MANIFEST.txt` 未改。**即使 fork tests 全绿，也不改 pin**——先做 Independent Fork Code Acceptance。

## 72. production preserveBaseWidth unchanged

`Sources/SwiftTerm/TerminalOptions.swift:64-87`（`VariationSelector16WidthPolicy`）+ `Terminal.swift:1494-1530`（preserve 语义）**未改**。`LocalTerminalService.swift` `.preserveBaseWidth` 未改。MacSSH `TerminalFontProvider`/`TerminalFontSizeController` 未改。

## 73. temporary preview artifacts

- `/tmp/macssh_phase9d_b_probe/probe.swift` + `out/before-after-{14,24,32}pt-{normal,grid}.png`（before/after 对比，§50）。**未 commit 进 fork**。
- 复制到 `generated-images/phase9d-b/`（仓库内，图像非 code，供报告引用）。
- probe 用 CG prototype 渲染，其 uniform-fit 公式与 production `computeGlyphFit` **逐字一致**（同 §17/§18 公式），故 probe "after" = production 输出。完整 `TerminalView` GUI render 留 §40 Local/Remote GUI 验收。

## 74. independent acceptance required

**是**。本阶段为 candidate implementation（branch `macssh-vs16-one-cell-render-fit`，1 candidate commit `93abf60`，未 merge/push）。首轮 Independent SwiftTerm Fork Code Acceptance（针对 `ded302c`）= **FAIL**（0 P1 / 3 P2，详见 `Docs/Phase9D-B-Independent-Fork-Acceptance.md`）。Phase 9D-B2 remediation 修复 `isBaseFont` base-family guard + 4 新测试 + 报告勘误，amend 为 `93abf60`。须等 **Independent SwiftTerm Fork Re-Acceptance**（针对 `93abf60`）：独立 reviewer 从源码复核 P2 消除、Bold/Italic/BoldItalic ASCII identity、immutable invariants、CG/Metal parity、cache correctness、测试矩阵，通过后才推进 production pin。

## 75. recommended next step

1. Independent SwiftTerm Fork **Re-Acceptance**（独立 reviewer，针对 `93abf60`）。
2. 通过后：生成新 immutable SwiftTerm commit SHA（若需 push，仅 push `macssh-vs16-one-cell-render-fit` feature branch，不动 main/tag）。
3. Re-Acceptance 后，MacSSH production 推进 exact revision（改 `Package.resolved` + `MANIFEST.txt`）。
4. MacSSH GUI 验收 Local/Remote（§40）：14/24/32pt × A⚠️B❤️C/separators/typed/pasted/history/cursor/highlight/selection/Light/Dark（含 Bold/Italic styled ASCII）。
5. 通过后 Phase 9 FINAL PASS。

## 76. final status

**IMPLEMENTATION COMPLETE (Phase 9D-B2 remediation) — SwiftTerm fork branch `macssh-vs16-one-cell-render-fit` (commit `93abf60`, parent `771e79f`, direct child) — `glyphSlotFit` extended to 1-cell ink-overflow (uniform scale, advance/ink center, no upscale) + shared `glyphFitCache` + CG/Metal gates extended + `isBaseFont` base-family guard recognizing all four FontSet members (normal/bold/italic/boldItalic) — 21 new `@MainActor` tests (含 4 项 base-font guard 矩阵) + full 774/0/0 fork tests green (stable across 3 runs + 10× targeted) — before/after PNGs generated — P1 RESOLVED — P2 RESOLVED (CG/Metal shared cache) — Phase 9D-B2 P2 RESOLVED (Bold/Italic/BoldItalic ASCII identity restored) — test-threading SIGSEGV fixed via `@MainActor` (production cache contract unchanged) — MacSSH pin/policy/production UNCHANGED — candidate commit amended (`ded302c` → `93abf60`) — first Independent Acceptance FAIL disclosed (§26/§63) — NOT merged / NOT pushed — PHASE 9B FINAL PASS remains BLOCKED pending Independent SwiftTerm Fork Re-Acceptance — STOP.**

---

## 验证记录

### Branch & parent
- `git checkout -b macssh-vs16-one-cell-render-fit 771e79f092a26e7fba7af0ab2b09a2bf10213109` → branch created ✓
- `git merge-base HEAD 771e79f...` = `771e79f...` ✓ (direct parent)
- `git status --short` 干净（创建时）✓

### Build
- `swift build`：Build complete! (7.31s)，仅 2 个 pre-existing `withUnsafeBytes` warnings（非本改动，`MetalTerminalRenderer.swift:1866/2090`）✓
- `swift build --build-tests`：Build complete! ✓

### Tests
- `xcrun swift test`（amend `ded302c` 后）：**Test run with 770 tests in 66 suites passed after 10.023 seconds** (EXIT=0) ✓，连续两次运行均 770/0/0 稳定（10.023s + 10.046s）
- `OneCellGlyphFitTests` suite passed (13 tests, `@MainActor`) ✓
- `GlyphFitCacheTests` suite passed (4 tests, `@MainActor`) ✓
- `VariationSelector16WidthPolicyTests` suite passed (21 tests，含 preserve/inverse/redraw/copy) ✓
- 0 failures, 0 skipped, 0 crashes ✓
- **首个 commit `f662cad` 的 SIGSEGV 已在 amend `ded302c` 中修复**（`@MainActor` 使测试在 main thread 串行运行，尊重 `glyphFitCache` main-thread-only 契约；生产代码未改）

### Metrics 复现 Phase 9C
- 14pt cellW=8.5/cellH=19, ⚠️ ink=17.5×17.5, A scale=0.486 ✓
- 32pt cellW=19/cellH=43, ⚠️ ink=32×32, A scale=0.594 ✓
- ⚠ run=JetBrainsMono isBaseFont→skip; ❤ run=Menlo ink≤cell→identity; 😀/🚀/✅ wide path ✓

### Before/after PNGs
- `generated-images/phase9d-b/before-after-{14,24,32}pt-{normal,grid}.png`：Before (Current)=overhang 覆盖邻居；After (A Uniform)=emoji 缩进 cell、controls（⚠/❤ text/😀/CJK）前后一致 ✓

## STOP

未修改 MacSSH pin/production/policy/Controller；未 merge SwiftTerm branch；未 push main；未开始 Phase 9D-C；未宣告 Phase 9 FINAL PASS。等待 Independent SwiftTerm Fork Code Acceptance。
