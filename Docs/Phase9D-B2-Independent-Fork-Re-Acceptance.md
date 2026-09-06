# MacSSH 1.1 Phase 9D-B2 — Independent SwiftTerm Fork Re-Acceptance

> 角色：Independent SwiftTerm Fork Re-Reviewer（非 9D-B/B2 实现者）。针对首轮 Independent Fork Acceptance FAIL 后的 remediation 做独立复验。
> 对象：candidate `93abf601469e572faffed65f75d548c58afa3058`（branch `macssh-vs16-one-cell-render-fit`，parent `771e79f`）。
> 旧失败 candidate：`ded302c9adf0e41185445560f3049e67fb180b6d`（首轮 FAIL，0 P1/3 P2）。
> 日期：2026-09-05。
> **结论：PASS（0 P1 / 0 P2）— 允许推进 MacSSH SwiftTerm exact revision `771e79f` → `93abf601`。**
> 本复验不改代码、不 amend、不 commit、不 merge、不 push、不改 MacSSH pin、不开始下一 Phase。

---

## 1. Acceptance result

**PASS**

## 2. P1

**0**

## 3. P2

**0**（首轮 3 个 P2 全部真实消除，见 §58/§59）

## 4. P3

- 测试 `cascadeFont` 用 Menlo（非生产 JetBrains Mono），但 fit 数学 font-independent + NSFontManager.convert 派生机制 font-family-agnostic，代表性成立（首轮已论证）。
- 2 个 pre-existing `withUnsafeBytes` warnings（`MetalTerminalRenderer.swift:1866/2090`）+ 1 SwiftPM bundle warning，均非 candidate 引入（baseline `771e79f` 已有，不在 candidate diff 范围）。
- advance-centering 在 14pt 留 ≤0.195pt 右 overhang（≤0.5pt@2x 容差，继承 B1，B2 未改）。
- `firstRunFontGlyph` 对无 glyph 字符 return nil（部分测试 `guard let` skip），非缺陷。

## 5. branch

`macssh-vs16-one-cell-render-fit` ✓（`git branch --show-current`）

## 6. old candidate

`ded302c9adf0e41185445560f3049e67fb180b6d`（首轮 FAIL）

## 7. new candidate

`93abf601469e572faffed65f75d548c58afa3058`

## 8. parent

`771e79f092a26e7fba7af0ab2b09a2bf10213109`

## 9. direct-parent confirmation

✓ `git rev-parse 'HEAD^'` = `771e79f...`；`git merge-base HEAD 771e79f...` = `771e79f...`；`git log`：`93abf60` → `771e79f` Add public pasteText → `6e56e32`。candidate 仍为 direct child，无其他 upstream commits 混入。working tree clean（`git status --short` 空）。

## 10. remediation diff

`ded302c..93abf60`（B2 增量）：
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`（M）：`isBaseFont` 从仅比对 `fontSet.normal` 改为比对全部四个成员；docstring 重写说明。
- `Tests/SwiftTermTests/OneCellGlyphFitTests.swift`（M）：新增 4 项 base-font guard 测试。
- +105/-4，2 files。

`771e79f..93abf60`（B1+B2 全量）：4 files / +576/-24（AppleTerminalView M / MetalTerminalRenderer M / GlyphFitCacheTests A / OneCellGlyphFitTests A）。

## 11. unrelated changes

✓ B2 增量仅 2 files（AppleTerminalView + OneCellGlyphFitTests）。未再次修改：MetalTerminalRenderer.swift、cache 架构、Terminal.swift、TerminalOptions.swift、MacTerminalView.swift、PTY、shader、parser、package 文件。TerminalOptions/Terminal/MacTerminalView/LocalProcess/Pty/Shaders.metal 在 `771e79f..93abf60` 中仅 MetalTerminalRenderer.swift（B1 gate 扩展，非 B2）与 AppleTerminalView.swift 变动。

## 12. old isBaseFont

`ded302c` 版本（首轮 FAIL 根因 P2-1）：
```swift
func isBaseFont (_ font: CTFont) -> Bool {
    return glyphFitFontID(font) == glyphFitFontID(fontSet.normal as CTFont)
}
```
仅比对 `fontSet.normal`。`FontSet`（`Mac/MacTerminalView.swift:164-169`）经 `NSFontManager.shared.convert(baseFont, toHaveTrait:[.boldFontMask/.italicFontMask])` 派生 bold/italic/boldItalic = **不同 NSFont 对象** → ObjectIdentifier 与 `normal` 不同 → `isBaseFont` 对 bold/italic/boldItalic 返回 **false** → call-site gate `!isBaseFont` 不跳过 → Bold/Italic ASCII 进入 `glyphSlotFit`/`computeGlyphFit`。

## 13. new isBaseFont

`93abf60` 版本（`:526-533`）：
```swift
func isBaseFont (_ font: CTFont) -> Bool {
    let id = glyphFitFontID(font)
    return id == glyphFitFontID(fontSet.normal as CTFont)
        || id == glyphFitFontID(fontSet.bold as CTFont)
        || id == glyphFitFontID(fontSet.italic as CTFont)
        || id == glyphFitFontID(fontSet.boldItalic as CTFont)
}
```
明确识别 `fontSet.normal` / `fontSet.bold` / `fontSet.italic` / `fontSet.boldItalic` 四个成员。任一匹配 → true。`glyphFitFontID` = `ObjectIdentifier(font as NSFont)`（toll-free bridge，`:204-210`）。

## 14. four FontSet members

✓ 四成员均被 `isBaseFont` 比对：normal、bold、italic、boldItalic（`Mac/MacTerminalView.swift:151-154`）。`baseFontFamilyGuardRecognizesAllFourMembers` 测试对 24pt Menlo cascade 逐成员断言 `isBaseFont(member)==true`，全绿。

## 15. ObjectIdentity architecture

✓ 安全。`glyphFitFontID` 用 `ObjectIdentifier(font as NSFont)`（toll-free bridge 后类实例，对象生命周期内 identity 恒定）。`FontSet` 在 `init` 时一次性 `NSFontManager.convert` 派生四成员并持有（`let`），生命周期内对象稳定。production run font 经 `PreparedRun.font`（`AppleTerminalView.swift:2032`，读 `CTRunGetAttributes` 的 font key）→ CG `:2159 runFont = preparedRun.font ?? fontSet.normal` → `:2223 ctRunFont = runFont as CTFont` → 传入 `isBaseFont`。即 production 传给 `isBaseFont` 的就是 `buildAttributedString` 放进 attributed string 的 fontSet 成员对象本身（ASCII 段），与测试 `firstRunFontGlyph` 读 `CTRunGetAttributes(run)[.font]` 同源。

关于 §6 担忧（"CoreText run 可能复制出等价但不同对象"）：`styledAsciiStaysIdentityAcrossFontSet` 测试用真实 `CTLineCreateWithAttributedString` + `CTRunGetAttributes(run)[.font]` 取 CTRun 解析的 font，对 Bold/Italic/BoldItalic ASCII 断言 `isBaseFont(runFont)==true`。若 CoreText 复制了等价但不同对象，`ObjectIdentifier` 会不同 → `isBaseFont` 返回 false → 测试 FAIL。测试全绿 → 实证确认 CoreText 对 base font 覆盖的 ASCII glyph 返回**同一对象**（不复制）。

## 16. real CTRun Regular

✓ `styledAsciiStaysIdentityAcrossFontSet` 中 normal 成员 × `["A","W","1","|","!","@"]`：`firstRunFontGlyph(ch, base: view.fontSet.normal)` 经真实 CTRun shaping → `isBaseFont(runFont)==true` → `fit.scale==1 && fit.dx==0 && fit.dy==0`。`asciiBaseFontGlyphIsIdentity` + `wideAsciiRunIsIdentityAcrossPunctuation`（含 `#`）同样验证 Regular identity。

## 17. real CTRun Bold

✓ **核心 hard gate**。`styledAsciiStaysIdentityAcrossFontSet`：`firstRunFontGlyph(ch, base: view.fontSet.bold)` 经真实 `CTLineCreateWithAttributedString` shaping → `CTRunGetAttributes` 取 run font → 对 `A/W/1/|/!/@` 全部 `isBaseFont(runFont)==true` 且 `scale==1 && dx==0 && dy==0`。修复前（首轮探针 Menlo 24pt）Bold 'A' dx=0.0254（非零）；修复后全 identity。

## 18. real CTRun Italic

✓ `styledAsciiStaysIdentityAcrossFontSet` italic 成员 × `A/W/1/|/!/@`：真实 CTRun → `isBaseFont(runFont)==true` → 全 `scale==1 && dx==0 && dy==0`。重点 `W`、`@`：修复前 Italic 'W' scale=0.956/dx=0.34/dy=-0.36、'@' scale=0.92/dy=2.26；修复后 identity。

## 19. real CTRun BoldItalic

✓ `styledAsciiStaysIdentityAcrossFontSet` boldItalic 成员 × `A/W/1/|/!/@`：真实 CTRun → identity。修复前 BoldItalic 'W' scale=0.931；修复后 identity。

## 20. 4×6 matrix

✓ `styledAsciiStaysIdentityAcrossFontSet`：4 styles（normal/bold/italic/boldItalic）× 6 glyphs（A/W/1/|/!/@）= 24 cases，全部 identity transform（scale==1, dx==0, dy==0）。每 case 先断言 `isBaseFont(runFont)==true` 再断言 fit identity。

## 21. size matrix

✓ `styledAsciiIdentityAcrossSizeMatrix`：Bold/Italic/BoldItalic × `A/W/|` × `[10,14,18,24,32]` = 45 cases，全部 `scale==1 && dx==0 && dy==0`。重点 `W`/`|` italic ink 会溢出 cell 的字号全覆盖。`warningSignEmojiFitsAcrossSizeMatrix` 另覆盖 ⚠️ × 5 字号 scale<1。

## 22. Apple Color Emoji exclusion

✓ `fallbackFontsAreNotBaseFamilyAndStillFit`：`firstRunFontGlyph("\u{26A0}\u{FE0F}", base: cascade)` 与 `firstRunFontGlyph("\u{2764}\u{FE0F}", base: cascade)` 经真实 CTRun（cascade 含 Apple Color Emoji）→ run font 为 Apple Color Emoji → `isBaseFont==false` → 仍进 1-cell ink-overflow fit → `scale<1`。`warningSignEmojiIsFittedIntoOneCell`/`heartEmojiIsFittedIntoOneCell` 同样断言 `!isBaseFont(font)` 且 `scale<1`。

## 23. PingFang exclusion

✓ CJK（PingFang SC 等）是不同对象 → `isBaseFont==false`，但 `columnWidth==2` → 走既有 wide-cell 分支（`computeGlyphFit` 对 `columnWidth>=2` 无 `isBaseFont` gate，仅 ink-overflow gate），与修订前 byte-for-byte 等价。`cjkWideCellIsBoundedAndUniform` 断言 `scale<=1`。CJK 不被 `isBaseFont` 误判（对象不同），但也不需要——它走 wide path。

## 24. ⚠

✓ `warningSignTextPresentationIsIdentity`：⚠（U+26A0 无 VS16）text glyph，ink ≤ cell。若落 base font → call-site gate 跳过 identity；若落 text fallback → `computeGlyphFit` ink-overflow 检查 → ink 不溢出 → `scale==1` identity。不 fit。metrics-driven（非 codepoint）。

## 25. ⚠️

✓ `warningSignEmojiIsFittedIntoOneCell` + `warningSignEmojiFitsAcrossSizeMatrix`：⚠️（U+26A0+VS16）Apple Color Emoji，ink > cell → `isBaseFont==false` → 进 fit → `scale = min(cellW/ink.w, cellH/ink.h, 1) < 1` → uniform 缩放 fit 进 cell。logical width 仍 1（`preserveBaseWidthKeepsEmojiOneCellAndCursorColumn` 断言 `width==1`）。无改回 baseline overhang。

## 26. ❤

✓ `heartTextPresentationIsIdentity`：❤（U+2764 无 VS16）text presentation，ink ≤ cell → identity。

## 27. ❤️

✓ `heartEmojiIsFittedIntoOneCell`：❤️（U+2764+VS16）Apple Color Emoji，ink > cell → fit（`scale<1`）。logical width 仍 1。

## 28. 😀

✓ `plainEmojiUsesWidePathAndStaysBounded`：😀（non-VS16，logical width=2）走既有 wide path，1-cell predicate 不介入。`scale<=1`。行为与 93abf60 前相同。

## 29. 🚀

✓ 同 §28，non-VS16 width-2 emoji 走 wide path。1-cell predicate 不介入。

## 30. ✅

✓ 同 §28/§29，non-VS16 width-2 emoji 走 wide path。行为不变。

## 31. preserveBaseWidth

✓ `preserveBaseWidthKeepsEmojiOneCellAndCursorColumn`：feed `A⚠️B❤️C` → ⚠️/❤️ `CharData.width==1`，cursor `buffer.x==5`，VS16 scalar 保留在 cluster。`Sources/SwiftTerm/TerminalOptions.swift:64-87`（`VariationSelector16WidthPolicy`）+ `Terminal.swift` preserve 语义 **B2 未改**（diff 中无 TerminalOptions/Terminal）。`preserveBaseWidth` policy 硬门保持。

## 32. logical width

✓ ⚠️/❤️ logical width == 1（§31 测试）。fix 纯 presentation-only：只改 `glyphPositions`（局部 copy）的 dx/dy/scale，不改 `positions`（grid）/`caretCol`/`caretView.frame`/model/bytes。

## 33. uniform fit

✓ B2 未改 scale formula：`scale = max(0.1, min(min(slotWidth/ink.width, cellHeight/ink.height), 1))`（`computeGlyphFit:562-565`）。`scaleX == scaleY`（单一 `scale` 字段，`GlyphSlotFit` struct）。dx=advance-centering（`:573`），dy=ink 垂直居中（scale<1 时，`:578-582`）。ink-overflow predicate（`:563`）：`ink.width > slotWidth || ink.height > cellHeight`。no upscale（`min(..., 1)`）。

## 34. no upscale

✓ `scale = min(..., 1)` 硬上限 1。`smallGlyphIsNeverUpscaled`（`.` ink ≤ cell → `scale==1`）+ `warningSignTextPresentationIsIdentity`/`heartTextPresentationIsIdentity`（text ⚠/❤ → identity）+ `fitScaleIsUniformAndNeverUpscales`（`scale<=1`）。

## 35. CG path

✓ CG draw path gate（`:2226-2227`）：`if prepared.segment.columnWidth >= 2 || (prepared.segment.columnWidth == 1 && !isBaseFont(ctRunFont))`。`ctRunFont = runFont as CTFont`（`:2223`），`runFont = preparedRun.font ?? fontSet.normal`（`:2159`）。base-font 1-cell run（含 styled ASCII）跳过 → identity（`CTFontDrawGlyphs` 原尺寸，`:2253`）；fallback 1-cell run 进 fit（`:2228-2237`）。非-identity 经 `CTFontCreateCopyWithAttributes(size*scale)` 缩小绘制（`:2247`）。

## 36. Metal path

✓ Metal 主 glyph loop gate（`MetalTerminalRenderer.swift:1316-1318`）：`needsFit = shaped.segment.columnWidth >= 2 || (shaped.segment.columnWidth == 1 && !terminalView.isBaseFont(glyphRun.font as CTFont))`。fit 通过 `basePos += fit.dx/dy`（`:1324-1325`）+ `entry.size.width/bearing × fit.scale`（`:1326-1327, :1331-1332`）应用。cursor 路径（`:2454`）无条件调用 `glyphSlotFit`，自动获得 1-cell fit。B2 未改 Metal 文件（仅在 B1）。

## 37. CG/Metal parity

✓ CG（`:2231`）与 Metal（`:1320`）调用**同一** `TerminalView.glyphSlotFit` 方法 → 同一 `computeGlyphFit` → 同一 file-level `glyphFitCache`。`glyphSlotFitIsDeterministicSharedSource` 测试断言重复调用结果稳定。架构 single-source 保证 parity（不存在 CG 一套、Metal 另一套）。`isBaseFont` 是 `TerminalView` 实例方法，CG/Metal 调同一实现。

## 38. cache

✓ B2 未改 cache：`GlyphFitKey(fontID, glyph, columnWidth, cellWidth, cellHeight)`（`:215-221`）。`glyphFitCache: [GlyphFitKey: GlyphSlotFit]`（`:227`），`glyphFitCacheLimit = 1024`（`:228`）。`fontID = ObjectIdentifier(font as NSFont)`（`:204-210`）。overflow 时 `removeAll(keepingCapacity: true)`（`:503-505`）。B2 未改 cache key/limit/thread（diff 中 AppleTerminalView 改动仅 `isBaseFont` + docstring）。

## 39. thread model

✓ B2 未引入并发变化。`glyphFitCache` main-thread only（与 draw path 同线程；`cgColorCache`/`fallbackFontCache` 同模式）。两个测试类 `@MainActor`（`OneCellGlyphFitTests:24` / `GlyphFitCacheTests`），使 Swift Testing 在 main thread 串行执行，尊重 cache main-thread 契约。生产代码线程模型未改。10× 定向运行 0 crash 0 flaky。

## 40. cursor

✓ caret x = `cellDimension.width × caretCol`（`:2513`，未改）。renderer transform 只改 `glyphPositions`（局部 copy，`:2224`），不改 `caretView.frame`/`caretCol`/model。`preserveBaseWidthKeepsEmojiOneCellAndCursorColumn` 断言 `buffer.x==5`（A⚠️B❤️C = 5 cells）。logical cursor column 保持。

## 41. separator grid

✓ `|⚠️|❤️|⚠️|❤️|`：每个 `|` origin = `cellIndex × cellDimension.width`（`:2078` fixed grid，未改，逻辑误差 = 0pt）。fit 只偏移 emoji glyph（`glyphPositions[i].x += fit.dx`），不偏移 separator（separator 是 base font ASCII → gate 跳过 → identity）。grid origins 保持 exact logical cell positions。

## 42. Highlight

✓ 不受 B2 影响。highlight rect 由 grid origin 计算（element.column × cellDimension.width）。`glyphSlotFit` 只改 `glyphPositions`（局部），不改 `positions`（grid）→ highlight background 仍覆盖完整 logical cell。

## 43. Selection

✓ 不受 B2 影响。selection rect 按 logical cell（`buildAttributedString` 不读 selection 改 positions）。fix 不改 selection model/range。复制保留原 VS16 scalar（fit 是 drawing-only）。

## 44. bracketed paste

✓ candidate diff 未修改 paste path。`testBracketedPasteRedrawStaysCleanUnderPreservePolicy` + `testCopyLineExtractionMatchesVisibleTextUnderPreservePolicy` + `testNoResidualInverseAfterRedrawUnderPreservePolicy` 全绿（含在 774 full run）。Phase 5 相关 tests 继续通过。

## 45. redraw

✓ `testBracketedPasteRedrawStaysCleanUnderPreservePolicy`（preserve 下 redraw 干净）+ `testBracketedPasteRedrawDivergesUnderDefaultPolicy`（对照）全绿。B2 未改 `buffer.x`/CharData width/CSI/paste bytes → zsh redraw 语义不变。无 cursor drift / history residue / redraw artifact。

## 46. new tests

✓ B2 新增 4 测试（均在 `OneCellGlyphFitTests.swift`，`@MainActor`）：
1. `baseFontFamilyGuardRecognizesAllFourMembers` — 四成员直接断言 `isBaseFont==true`。
2. `styledAsciiStaysIdentityAcrossFontSet` — 4 styles × 6 glyphs = 24 cases，真实 CTRun + identity。
3. `fallbackFontsAreNotBaseFamilyAndStillFit` — ⚠️/❤️ 真实 CTRun + `isBaseFont==false` + `scale<1`。
4. `styledAsciiIdentityAcrossSizeMatrix` — Bold/Italic/BoldItalic × A/W/| × 10/14/18/24/32 = 45 cases identity。

## 47. test quality

✓ 高质量。`styledAsciiStaysIdentityAcrossFontSet` / `styledAsciiIdentityAcrossSizeMatrix` / `fallbackFontsAreNotBaseFamilyAndStillFit` 均通过 `firstRunFontGlyph` helper 做真实 CoreText shaping（`CTLineCreateWithAttributedString` + `CTRunGetGlyphs` + `CTRunGetAttributes(run)[.font]`），取 CTRun 实际解析的 font，**不是**直接把 FontSet 成员传给 helper。`baseFontFamilyGuardRecognizesAllFourMembers` 是直接断言（sanity check），但其余 3 项提供真实 CTRun 路径证据。无 P2 test gap。

## 48. real CTRun coverage

✓ 充分。`firstRunFontGlyph` 用 production 同源 cascade font（Menlo + Apple Color Emoji cascade，`cascadeFont` helper）+ 真实 `CTLineCreateWithAttributedString` shaping + `CTRunGetAttributes` 取 run font。覆盖 Regular/Bold/Italic/BoldItalic × A/W/1/|/!/@（24 cases）+ size matrix 45 cases + ⚠️/❤️ fallback。production run font 同源（`PreparedRun.font` 读 CTRun attribute）。若 CoreText 复制对象 → `isBaseFont` 返回 false → 测试 FAIL；测试全绿 → 实证确认无复制。

## 49. full run #1

✓ `xcrun swift test`：**Test run with 774 tests in 66 suites passed after 10.013 seconds**（EXIT=0）。0 failures, 0 crashes。

## 50. full run #2

✓ 再次 `xcrun swift test`：**Test run with 774 tests in 66 suites passed after 10.017 seconds**（EXIT=0）。0 failures, 0 crashes。非 flaky。

## 51. targeted ×10

✓ `xcrun swift test --filter "OneCellGlyphFitTests|GlyphFitCacheTests"` 连续 10 次：每次 **21 tests in 2 suites passed**（0.063–0.088s），0 failures, 0 flaky, 0 crashes。

## 52. warnings

✓ 0 candidate-related compiler warning。clean build 后仅 2 个 pre-existing `withUnsafeBytes` warnings（`MetalTerminalRenderer.swift:1866/2090`，baseline `771e79f` 已有，不在 candidate diff 范围）+ 1 SwiftPM bundle warning（`missing creator for mutated node`，非 candidate）。candidate 改动的 `AppleTerminalView.swift` `isBaseFont` + `OneCellGlyphFitTests.swift` 4 新测试 0 warning。

## 53. git diff check

✓ `git diff --check 771e79f..93abf60`：clean（无 whitespace 错误输出）。

## 54. docs accuracy

✓ `Docs/Phase9D-B-VS16-Renderer-Remediation-Report.md`：
- §5（candidate SHA）：`93abf60`，附 remediation + 首次 FAIL 披露 ✓
- §15（runFont handling）：明确 `isBaseFont` 比对全部四成员 + §15 勘误纠正"ink-overflow 兜底 ASCII identity"对 italic 不成立 ✓
- §33（JetBrains Mono regression）：纠正"Bold/Italic→isBaseFont true"事实错误 + §33 勘误 ✓
- §62（new tests）：17 OneCellGlyphFit + 4 GlyphFitCache = 21，含 4 新 base-font guard 测试 ✓
- §63（full tests）：774/66 ✓
- §64/§66：774 executed / 0 failures ✓
- §74/§76：Re-Acceptance 针对 `93abf60` ✓
不再包含"即使 font identity miss，Italic ink也不会 overflow"错误描述（§15 勘误明确否定）。

## 55. first FAIL disclosure

✓ 首轮 FAIL 完整保留。`Docs/Phase9D-B-Independent-Fork-Acceptance.md`（75 行）记录 `ded302c` = FAIL（0 P1/3 P2），未删除。remediation report §5/§63 也披露首次 FAIL。§26 honesty 保持。

## 56. MacSSH pin

✓ MacSSH SwiftTerm pin 仍 `771e79f092a26e7fba7af0ab2b09a2bf10213109`：
- `MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:18`：`"revision" : "771e79f..."` ✓
- `MacSSH.xcodeproj/project.pbxproj:944`：`revision = 771e79f...;` ✓
未推进到 `93abf60`。

## 57. MacSSH production

✓ B2 未修改 MacSSH production。candidate 在 SwiftTerm fork 独立 git repo（`ThirdParty/SwiftTerm-fork`），diff 仅含 4 files（Sources/SwiftTerm/ + Tests/SwiftTermTests/）。`TerminalFontSizeController`/`TerminalFontProvider`/`SettingsView`/`SessionManager`/`AppState` 均在 MacSSH 项目（`MacSSH/` 路径），不在 fork diff 中。MacSSH working tree 改动均为 Phase 9B 产物。

## 58. remaining P1

**0**。首轮即 0 P1。核心 P1（1-cell VS16 Apple Color Emoji 未进 `glyphSlotFit`）在 B1 已 RESOLVED（guard 放宽 + CG/Metal gate 扩展），B2 未回退。

## 59. remaining P2

**0**。首轮 3 P2 全部真实消除：
- P2-1（Bold/Italic/BoldItalic ASCII 被错误 fit）：`isBaseFont` 改比对四成员 → gate 跳过 → identity（§13/§17-§21 实证）✓
- P2-2（缺 styled ASCII identity tests）：新增 4 测试（§46），含 24-case 矩阵 + 45-case size 矩阵 ✓
- P2-3（报告 §15/§33 描述错误）：勘误完成（§54）✓

## 60. remaining P3

见 §4。均非阻塞：pre-existing warnings（baseline 已有）、advance-centering sub-pixel overhang（容差内）、测试 font 选择（代表性成立）。

## 61. 是否允许推进 MacSSH exact revision

**是**。0 P1 / 0 P2 → 允许推进 MacSSH SwiftTerm exact revision `771e79f` → `93abf601469e572faffed65f75d548c58afa3058`。

## 62. recommended next step

1. 推进 MacSSH production pin：改 `Package.resolved` + `project.pbxproj` SwiftTerm revision `771e79f` → `93abf60`（+ `ThirdParty/MANIFEST.txt` 若有）。
2. MacSSH GUI 验收 Local/Remote（§40）：14/24/32pt × A⚠️B❤️C/separators/typed/pasted/history/cursor/highlight/selection/Light/Dark（含 Bold/Italic styled ASCII）。
3. 通过后 Phase 9 FINAL PASS。
4. 若需 push SwiftTerm fork，仅 push `macssh-vs16-one-cell-render-fit` feature branch，不动 main/tag。

## 63. final status

**RE-ACCEPTANCE PASS — Independent SwiftTerm Fork Re-Acceptance（candidate `93abf601469e572faffed65f75d548c58afa3058`，branch `macssh-vs16-one-cell-render-fit`，parent `771e79f` direct child）— 首轮 3 P2 全部真实消除（`isBaseFont` 改比对全部四个 FontSet 成员 normal/bold/italic/boldItalic ObjectIdentity → Bold/Italic/BoldItalic ASCII call-site gate 跳过 → identity；4 新测试含真实 CTRun 24-case style×glyph 矩阵 + 45-case size 矩阵 + fallback 排除；报告 §15/§33 勘误）— remediation scope 窄（仅 AppleTerminalView.swift isBaseFont + OneCellGlyphFitTests.swift 4 测试，+105/-4）— 核心 VS16 1-cell uniform-fit + CG/Metal 共享 glyphSlotFit + glyphFitCache + cache/thread 模型未改 — full 774/66 ×2 + targeted 21/2 ×10 全绿，0 crash，0 candidate warning，git diff --check clean — MacSSH pin/policy/production UNCHANGED（仍 771e79f）— 首轮 FAIL 历史保留 — 0 P1 / 0 P2 — 允许推进 MacSSH SwiftTerm exact revision 771e79f → 93abf601 — STOP（不改代码/不 amend/不 commit/不 merge/不 push/不改 pin/不开始 MacSSH integration）。**

---

## 验证执行记录

### Git identity（§1-9）
- `git branch --show-current` = `macssh-vs16-one-cell-render-fit` ✓
- `git status --short` = 空（working tree clean）✓
- `git rev-parse HEAD` = `93abf601469e572faffed65f75d548c58afa3058` ✓
- `git rev-parse 'HEAD^'` = `771e79f092a26e7fba7af0ab2b09a2bf10213109` ✓
- `git log -3 --oneline`：`93abf60` → `771e79f` → `6e56e32` ✓
- `git merge-base HEAD 771e79f...` = `771e79f...` ✓（direct child）

### Remediation diff scope（§10-11）
- `git diff --stat ded302c..93abf60`：2 files（AppleTerminalView M / OneCellGlyphFitTests M），+105/-4 ✓
- `git diff --name-status ded302c..93abf60`：仅 AppleTerminalView.swift(M) + OneCellGlyphFitTests.swift(M) ✓
- `git diff --stat 771e79f..93abf60`：4 files，+576/-24 ✓
- `git diff --check 771e79f..93abf60`：clean ✓

### 源码独立确认（§12-15, 35-38）
- `isBaseFont`（`AppleTerminalView.swift:526-533`）：比对四成员 ObjectIdentity ✓
- `glyphFitFontID`（`:204-210`）：`ObjectIdentifier(font as NSFont)` ✓
- `computeGlyphFit` fast path（`:547`）：`if columnWidth == 1, isBaseFont(font) { return .identity }` ✓
- CG gate（`:2226-2227`）：`columnWidth >= 2 || (columnWidth == 1 && !isBaseFont(ctRunFont))` ✓
- Metal gate（`MetalTerminalRenderer.swift:1316-1318`）：同源 `needsFit` ✓
- Metal cursor（`:2454`）：无条件 `glyphSlotFit` ✓
- `FontSet`（`Mac/MacTerminalView.swift:164-169`）：`NSFontManager.shared.convert` 派生四成员 ✓
- cache（`:215-228`）：GlyphFitKey + glyphFitCache(limit 1024) + main-thread ✓
- uniform scale（`:562-565`）：`max(0.1, min(min(slotW/ink.w, cellH/ink.h), 1))` ✓

### 测试（§49-51）
- full #1：774/66 passed（10.013s, EXIT=0）✓
- full #2：774/66 passed（10.017s, EXIT=0）✓
- targeted ×10：21/2 passed every run（0.063–0.088s），0 flaky/crash ✓

### Warnings（§52）
- clean `swift build`：仅 2 pre-existing `withUnsafeBytes`（MetalTerminalRenderer:1866/2090）+ 1 SwiftPM bundle warning，0 candidate warning ✓

### MacSSH pin（§56-57）
- `Package.resolved:18` = `771e79f...` ✓
- `project.pbxproj:944` = `771e79f...` ✓
- fork diff 仅 4 files（Sources/SwiftTerm/ + Tests/），无 MacSSH production 文件 ✓

## STOP

未修改代码；未 amend；未 commit；未 merge；未 push；未修改 MacSSH pin；未开始 MacSSH integration；未开始下一 Phase。Re-Acceptance 完成。
