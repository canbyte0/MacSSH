# Phase 9D-D — Real-Pixel VS16 CG Renderer Remediation
# Original CTFont + CGContext Uniform Transform

**Scope**：只修复 CG renderer 中 1-cell overflowing fallback/color glyph 因
`CTFontCreateCopyWithAttributes(size × fit.scale)` 重选 Apple Color Emoji sbix strike
导致最终 raster ink 仍越界的问题（Phase 9D-C 实证根因）。
**策略**：保留原始 CTFont + CGContext presentation transform（Uniform Fit，保 aspect ratio）。

---

## 1. SwiftTerm branch

`macssh-vs16-one-cell-render-fit`（fork `canbyte0/SwiftTerm.git`）。
已 push：`git ls-remote … refs/heads/macssh-vs16-one-cell-render-fit` = `40d473b1…`。
未 push main / 未打 tag / 未 merge。

## 2. old SHA

`93abf601469e572faffed65f75d548c58afa3058`（Phase 9D-B2 accepted，Phase 9D-C integrated）。

## 3. new SHA

**`40d473b1fdb456d49cc04b7f253277fcb9ac3987`**
（commit message：`fix(renderer): scale fitted glyphs at draw time`）。

## 4. parent

`93abf601469e572faffed65f75d548c58afa3058`（`git log -1 --format='%H %P'` 实证）。
完整 lineage：`771e79f → 93abf601 → 40d473b`。**未 amend / 未 force-rewrite 93abf601**。

## 5. diff

```
git diff --stat 93abf601..HEAD
 Sources/SwiftTerm/Apple/AppleTerminalView.swift      | 43 +++++++++++++++--
 Tests/SwiftTermTests/RasterContainmentTests.swift    | 674 ++++++++++++++++++++++
 2 files changed, 712 insertions(+), 5 deletions(-)
```
`git diff --name-status`：`M AppleTerminalView.swift` + `A RasterContainmentTests.swift`。
**Diff narrow**：renderer 仅 scaledFits 分支一个 hunk；Metal / computeGlyphFit / cache /
isBaseFont / Terminal / TerminalOptions / paste / PTY / shaders **零改动**。

## 6. Phase 9D-C root cause（implementation baseline）

`Docs/Phase9D-C-Real-Pixel-VS16-Investigation.md` 实证：
- GUI failure 被 standalone `TerminalView.draw → bitmap` 完全复现（同 SwiftTerm、同字体栈、
  preserveBaseWidth、CG renderer、2x backing）。
- `CTFontCreateCopyWithAttributes(ACE, S × scale)` 重选 sbix strike →
  `actualInk(S × scale) ≠ actualInk(S) × scale`。
- `CTRunGetImageBounds ≡ CTFontGetBoundingRectsForGlyphs`（ACE byte-for-byte），无新 raster 信息。
- 真实 pixel raster 是唯一最终 correctness source。

## 7. sbix strike behavior

ACE（`/System/Library/Fonts/Apple Color Emoji.ttc`）declared ink/size ratio 分段常数：
orig 10/14/18/24/32pt = 1.250/1.250/1.167/1.000/1.000；
copy 4.8/6.8/9.43/14.5/19pt = 1.250/1.250/1.250/1.250/1.132。
`CTFontGetBoundingRectsForGlyphs` 按选中 strike 归一化；copy 重选 strike 时 ratio 跳升
（24pt: 1.000 → 1.250，+25%；32pt: 1.000 → 1.132，+13%）→ 线性 fit 预测系统性低估 raster ink。

## 8. old scaled-CTFont strategy（被替换）

```
fit → drawFont = CTFontCreateCopyWithAttributes(ctRunFont, S × s) → p = gridPos + (dx,dy) → draw
```
raster ink = copy strike ink ≈ copySize × copyRatio > predicted = cellW →
24pt 右侵 +3.0pt / 32pt 右侵 +2.0~2.5pt（全部侵入为右侧单向，§9D-C §7 勘误）。

## 9. new original-font strategy（本阶段实现）

```
fit → original CTFont → CGContext affine transform（局部，anchor = glyph origin）→ draw → restore
```
raster ink = original strike ink × s ≈ declared ink × s = predicted = cellW（±0.5pt AA）。
**不创建 scaled CTFont**（§11 hard gate 满足）。

## 10. CGContext transform architecture

仅 scaledFits 分支内、且 `prepared.segment.columnWidth == 1 && s != 1` 的 glyph 走新路径；
wide path（columnWidth ≥ 2）保持原 copy 机制不变（实测 contained，§30）；s == 1 或 bulk 路径
完全不变。ASCII/base-font fast path 不进入分支（性能不变）。

## 11. transform formula

对需要 fit 的 glyph（fit.scale = s < 1）：
```swift
// p = glyphPositions[i] = gridOrigin + (fit.dx, fit.dy)
context.saveGState()
context.translateBy(x: p.x, y: p.y)   // anchor → glyph origin
context.scaleBy(x: s, y: s)           // uniform，scaleX == scaleY
var local = CGPoint.zero
CTFontDrawGlyphs(ctRunFont, &g, &local, 1, context)  // ORIGINAL font
context.restoreGState()
```
glyph 局部坐标（相对自身 origin）统一缩放 s——与 fit math 的意图严格一致
（scaled advance box 居中、ink 垂直居中），**不缩放绝对 origin**（无拉向 view origin 问题）。

## 12. transform anchor

anchor = **最终 glyph origin p**（= logical grid origin + fit.dx/dy，`:2233-2234` 已先行写入
`glyphPositions`）。平移在 transform 之前以点坐标完成，缩放只作用于 glyph 局部坐标。
后续 cell / separator / cursor / background 的 origin 完全不受影响（§8 hard gate）。

## 13. save/restore isolation

每个 scaled glyph：`saveGState → translate → scale → draw → restoreGState`。
CTM 不泄漏到：下一 glyph、highlight、selection、cursor、后续 line、decorations
（`drawRunAttributes` 在 restore 之后用未变换的 `positions`）。
per-glyph 隔离（§9/§10）：run 内 s==1 的 glyph 不走 transform（draw 原字体 at p）。

## 14. original CTFont proof

修复后 CG fit 分支中**不存在** `CTFontCreateCopyWithAttributes(... size × fit.scale ...)`：
- `git diff 93abf601..HEAD` 中 scaledFits 分支仅新增 transform 代码；
  `CTFontCreateCopyWithAttributes` 现仅存在于 wide-path else 分支（`columnWidth >= 2`，保留）。
- 运行时实证：§18–§22 raster = original strike ink × s（≠ copy strike ink）。

## 15. scale

`fit.scale` 不变（`computeGlyphFit` 未改）：`max(0.1, min(min(slotW/inkW, cellH/inkH), 1))`，
uniform（scaleX == scaleY），≤ 1（no upscale，§31）。s == 1 时不做任何 context scaling。

## 16. dx

`fit.dx` 不变（advance-centering）：经 `glyphPositions[i].x += fit.dx`（`:2233`）进入
transform anchor p.x——先平移后局部缩放，dx 语义与旧实现逐点一致。
实测 24pt dx = -0.30pt，32pt dx ≈ 0。

## 17. dy

`fit.dy` 不变（ink 垂直居中，scale<1 时）：经 `glyphPositions[i].y += fit.dy` 进入 anchor。
实测 isolated inkH ≤ cellH 全字号（垂直始终 contained）。

## 18. 10pt raster

isolated ⚠️/❤️ ink 6.0 in cell 6.0，左/右均 -0.5pt margin（before: contained）。PASS。

## 19. 14pt raster

isolated ink 8.5 in cell 8.5，左/右 -0.5pt margin（before: contained）。PASS。

## 20. 18pt raster

isolated ⚠️ ink 11.0 in cell 11.0（-0.5 margin）；❤️ ink 10.0 in cell 11.0（左 0 / 右 -1.0）。
before：⚠️ 右侵 +0.5 @ gate → after：contained。PASS。

## 21. 24pt raster（重点档，before 最严重 +3.0pt / 20.7%）

isolated ⚠️/❤️ ink 14.5 in cell 14.5，左/右 -0.5pt margin。
s1/s2 全 emoji chromatic cluster contained（`results-after.jsonl`）。
**before 右侵 +3.0pt → after -0.5pt margin。进入 containment gate。**PASS。

## 22. 32pt raster

isolated ⚠️/❤️ ink 18.5 in cell 19.0，左 0 / 右 -0.5pt margin。
before 右侵 +2.0~2.5pt → after contained。PASS。

## 23. ⚠️ containment

全字号（10/14/18/24/32）×（s1 col 1 / s2 cols 1,3,5,7 / isolated col 2）：
左侵 = 0，右侵 ≤ 0（margin 0.5–1.0pt），远优于 ≤0.5pt gate。
`RasterContainmentTests.singleCellEmojiRasterContained` ×5 sizes PASS。

## 24. ❤️ containment

同 ⚠️ 全部 PASS（32pt before 左侧 +1.0 margin 自然保留，非侵入）。

## 25. separators

`|⚠️|❤️|⚠️|❤️|` 全部 5 个 separator cell：emoji chromatic ink 侵入深度 ≤ 0.5pt@2x
（fringe 排除法），且 `|` glyph ink 存在。`separatorsNotCoveredByEmojiInk` ×5 sizes PASS。
separator logical origin 精确 grid 位置（renderer 不触碰 background/origin 计算）。

## 26. cursor

`term.buffer.x == 5`（s1）/ `== 9`（s2）（model 层精确）；
`view.updateCursorPosition()` 后 `caretFrame.origin.x == 5×cellW / 9×cellW`（|Δ| < 0.01pt），
`caretFrame.width == cellW`。renderer transform 不移动 caret。`cursorStaysOnLogicalGrid` ×3 PASS。

## 27. 1x

1x bitmap render smoke：14/24/32pt 左/右侵 ≤ 1.0pt（1 device px @1x）。
非 Retina-specific。`oneXRenderSmoke` ×3 PASS。

## 28. 2x

主 gate 环境（用户 Retina）。全部 containment 测试于 2x 通过（≤0.5pt）。

## 29. base-font styles

Phase 9D-B2 四成员 guard 未触碰（`isBaseFont` 比对 normal/bold/italic/boldItalic 对象）。
`styledAsciiRunsKeepContainment`（ANSI Bold A + ⚠️ + Italic B + ❤️ + BoldItalic C ×14/24/32）
PASS；既有 `styledAsciiStaysIdentityAcrossFontSet` / `styledAsciiIdentityAcrossSizeMatrix`
（4 styles × A/W/1/|/!/@ 全 identity）继续 PASS（full suite 内）。

## 30. CJK

existing 2-cell path **逐字节未改**（copy 机制保留）。BEFORE 实测 isolated 中
全字号 contained（ink 7.5–25.5pt in slot 12–76pt，margin 双侧）。CJK 为矢量字体
（PingFang SC），线性缩放成立，不受 strike 问题影响。视觉保持。

## 31. normal emoji

😀（width-2）isolated 2-cell slot 全字号 contained（before/after 一致，
`normalWideEmojiBaselineContained` ×5 PASS）——wide path 未改动的回归证明。
§28 调查结论：wide path 无同类 strike failure（ink < slot 时恒 identity；
需缩放的字号段 original 与 copy strike ratio 恰好一致），不扩大 Phase 9D-D scope。

## 32. text presentation

⚠/❤（无 VS16）：Menlo base font 解析（isBaseFont → identity fast path，永不 transform/clip）。
raster-vs-raster 验证：renderer ink 宽高 vs 直接 CTFontDrawGlyphs 参考渲染差 ≤ 1.5pt
@24pt（实测 14.0 == 14.0）。`textPresentationBaselineUntouched` PASS。

## 33. CG

CG 路径行为 = 原字体 + 局部 uniform transform（本阶段修复对象）。
最终 raster 全字号 contained（§18–§22）。

## 34. Metal

**未改**（`git diff` 无 MetalTerminalRenderer.swift）。Metal 语义本已等价
（`fit.scale` 只缩 quad，glyph 按 backing-scaled 原字体 rasterize 入 atlas）——
修复后 CG/Metal 数学收敛，shared single source（`glyphSlotFit`/`computeGlyphFit`/
`glyphFitCache`）保持不变（§14 任务约束满足）。

## 35. cache

`GlyphFitKey` / limit 1024 / main-thread contract **未改**（`git diff` 无相关 hunk）。
cache 输入（font/glyph/columnWidth/cellW/cellH）与输出（dx/dy/scale）语义不变。

## 36. threading

CG drawing 保持 main-thread。RasterContainmentTests 全部 `@MainActor`
（与 AlternateScrollModeTests/MouseTrackingTests 同模式，避免 Swift Testing 并发访问
file-level cache 的既有教训）。测试运行 0 crash（§50）。

## 37. performance

probe（24×80 帧 @2x，CFAbsoluteTime，30 帧平均，3 次重复取范围）：
- ASCII-only：before 2.58ms → after 2.50 / 2.75 / 2.77 / 2.82ms（run-to-run 噪声 ±10%；
  ASCII 路径代码逐字节相同——不进入 scaledFits 分支——**无可测明显退化**）。
- emoji-mixed（每 8 字符 1 个 ⚠️）：before 3.41ms → after 2.87 / 3.03 / 3.08 / 3.09 / 3.13ms
  （**约 -9%**：旧路径每 glyph 每帧创建 `CTFontCreateCopyWithAttributes`，新路径零字体创建）。

## 38. Phase5

`preserveBaseWidth` 未改（`TerminalOptions.swift` / `Terminal.swift:1494-1530` 零 diff）；
⚠️/❤️ width = 1 不变（model 层由既有 `preserveBaseWidthKeepsEmojiOneCellAndCursorColumn`
继续断言，full suite PASS）。

## 39. paste

`MacTerminalView.pasteText(_:)` 未触碰（`git diff` 无）；bracketed paste bytes 完全一致。
Phase 7 测试继续 PASS（full suite 内）。

## 40. redraw

Phase 5 redraw 相关测试（history / cursor / wrapped command / backspace-delete 所在套件）
在 full suite ×2 中全部 PASS——renderer 改动不改变任何 model/buffer/redraw 语义。

## 41. Highlight

highlight background 仍按 logical cell rect 填充（background pass 用未变换的 grid 位置）。
`highlightRectStaysCellAligned`：高亮 col 4（"C" cell）红色 rect 边缘 == cell 边界 ±0.5pt，
且同行 ⚠️/❤️ transform 不泄漏进 background pass。PASS。

## 42. Selection

`selectionRectStaysCellAligned`：`selectedTextBackgroundColor` 蓝色 rect（col 3，❤️ cell）
边缘 == cell 边界 ±0.5pt。PASS。

## 43. Appearance

`lightDarkGeometryConsistent`：white-on-black vs black-on-white cellDimension 完全一致，
dark 下 containment 同样满足。几何与外观无关。PASS。

## 44. RasterContainmentTests

11 个 @Test（29 个参数化 case），全部真实 TerminalView draw path → bitmap → 像素断言：
1. `singleCellEmojiRasterContained` ×5（§17–§24）
2. `separatorsNotCoveredByEmojiInk` ×5（§25）
3. `cursorStaysOnLogicalGrid` ×3（§26）
4. `textPresentationBaselineUntouched`（§32）
5. `normalWideEmojiBaselineContained` ×5（§31）
6. `styledAsciiRunsKeepContainment` ×3（§29）
7. `oneXRenderSmoke` ×3（§27）
8. `highlightRectStaysCellAligned`（§41）
9. `selectionRectStaysCellAligned`（§42）
10. `lightDarkGeometryConsistent`（§43）
11. `appleColorEmojiScaledCopyDoesNotScaleInkLinearly`（§45 documentation guard）

## 45. theoretical vs raster gate

本阶段确立制度：**helper/theoretical bounds 仅作 fast predicate，真实 raster 像素为最终
correctness gate**。documentation test（§44-11）以可执行形式记录 ACE strike ratio 非线性
（orig 1.000 vs copy 1.250 @24pt），防止未来有人把 CGContext transform "优化"回
`CTFontCreateCopyWithAttributes(size × scale)`——若未来 macOS 使 ACE 线性化，该测试会
失败并提示可重审 guard。

## 46. full test #1

`xcrun swift test`：**785 tests / 67 suites passed**（10.018s），0 failures / 0 crashes。
（baseline 774 + 11 新 RasterContainmentTests。）

## 47. full test #2

`xcrun swift test`：**785 / 67 passed**（10.051s），0 / 0。连续 2 次稳定。

## 48. targeted ×10

`--filter "OneCellGlyphFitTests|GlyphFitCacheTests|RasterContainmentTests"` 连续 10 次：
**32 tests / 3 suites passed** 每次（3.13–3.37s），0 crash / 0 flaky。
（Raster 真实 bitmap 测试包含在这 10 次内，§47 任务约束满足。）

## 49. failures

0（修复过程中曾有 19 个测试侧断言失败——separator fringe 像素边界、weak provider 生命周期、
窗口扫描混入邻居 ink、text-presentation gate 语义——全部为测试 harness 问题，
逐一诊断修正；renderer 修复本身未变）。最终状态 0 failures。

## 50. crashes

0。

## 51. warnings

clean build（`--scratch-path /tmp/macssh-9dd-scratch`）：
`AppleTerminalView.swift` / `RasterContainmentTests.swift` **0 warning**。
（`SynchronizedOutputTests.swift` main-actor 警告为 pre-existing 未触碰文件，非 candidate。）

## 52. git diff check

`git diff --check 93abf601..HEAD`：clean（0 whitespace error）。
`--stat` / `--name-status`：见 §5——narrow（renderer 1 hunk + 1 测试文件）。

## 53. MacSSH pin unchanged

`pbxproj` `revision = 93abf601…`（kind=revision）+ `Package.resolved` `"revision" : "93abf601…"`
——**未推进到 40d473b**。须先 Independent SwiftTerm Fork Acceptance。

## 54. P1

**0 P1（待独立验收确认）**：Phase 9D-C P1（真实像素下 24/32pt 右侵 +2~+3.0pt）在本 candidate
的真实像素 gate 下消除——全字号左侵 0 / 右侵 ≤ 0（margin），RasterContainmentTests 硬门通过，
24pt 重点档（before +3.0pt / 20.7% normalized）收于 -0.5pt margin。

## 55. P2

**0 P2**：CG/Metal shared single source 保持；cache/thread 契约未动；base-font 四成员 guard
未动；wide path 未动且实测 contained；性能 emoji-mixed 改善 ~9%、ASCII 无退化。

## 56. P3

- probe cursor PNG 合成路径（caretView.draw）仍有 y 伪影——probe 工具限制，非生产问题；
  cursor 正确性由 `cursorStaysOnLogicalGrid`（同步 `updateCursorPosition` + `caretFrame`）证明。
- probe 早期 PNG 合成方向 bug（垂直翻转）已修正；9D-C 证据 PNG 已翻正并加勘误
  （`Docs/Phase9D-C-Real-Pixel-VS16-Investigation.md` 附录 B）。
- 18pt ❤️ ink 10.0 in cell 11.0（margin -1.0）——bitmap strike 在该字号的自然结果，非缺陷。

## 57. independent acceptance required

**需要 Independent SwiftTerm Fork Acceptance（针对 `40d473b1`）**，验收点建议：
- git identity（branch/SHA/parent `93abf601` direct child / 未 rewrite 93abf601）
- diff scope（仅 AppleTerminalView scaledFits hunk + RasterContainmentTests）
- §11 hard gate（CG fit 分支无 scaled CTFont）
- §14 shared single source 未分裂
- RasterContainmentTests 独立重跑 + 抽验像素断言
- full ×2 / targeted ×10 复验
- Phase 2/5/6/7/8/9B 回归

## 58. recommended next step

1. Independent SwiftTerm Fork Acceptance（`40d473b1`）。
2. PASS 后：MacSSH pin `93abf601` → `40d473b`（pbxproj kind=revision + Package.resolved +
   MANIFEST.txt + DependencyIdentityTests 新增 Phase 9D-D 常量/parent 断言）。
3. MacSSH clean build（Debug+Release，0 warning）+ full tests + 新 VS16 集成 smoke。
4. 用户 GUI Re-Acceptance（17 项 checklist + **24pt 重点档** + 方案 B 视觉复核）。
5. GUI PASS 后方可考虑 Phase 9 FINAL PASS 评估。

## 59. final status

**PHASE 9D-D IMPLEMENTATION COMPLETE**。

- candidate `40d473b1fdb456d49cc04b7f253277fcb9ac3987`（parent `93abf601`，feature branch
  已 push；未 push main/tag/merge）。
- CG 1-cell fit 改为 original CTFont + CGContext uniform transform；wide path / Metal /
  fit math / cache / policy / model / cursor / PTY / paste / Controller 全部未改。
- 真实像素 gate：10/14/18/24/32pt × A⚠️B❤️C / |⚠️|❤️|⚠️|❤️| / isolated 全 contained
  （左侵 0 / 右侵 ≤ 0）。
- full ×2（785/67）+ targeted ×10（32/3）全绿；0 failure / 0 crash / 0 candidate warning；
  git diff --check clean；MacSSH pin 未推进。
- **Phase 9 FINAL PASS 仍 BLOCKED**（待 Independent Fork Acceptance + GUI Re-Acceptance）。

未修改 MacSSH pin；未 merge；未 push main；未 commit MacSSH；未开始下一 Phase；
未宣告 Phase 9 FINAL PASS。

**STOP**，等 Independent SwiftTerm Fork Acceptance（针对 `40d473b1`）。

---

## 附录 A：before / after 真实像素对照

| size | before（93abf601，右侵） | after（40d473b，右侵） |
|---:|---:|---:|
| 10 | 0 | 0（-0.5 margin） |
| 14 | 0 | 0（-0.5 margin） |
| 18 | +0.5 @gate | 0（-0.5 margin） |
| 24 | **+3.0 FAIL** | **0（-0.5 margin）PASS** |
| 32 | **+2.0~2.5 FAIL** | **0（-0.5 margin）PASS** |

PNG（正向 upright）：
- before：`generated-images/phase9dc-c/real-{14,18,24,32}pt-{1x,2x}-grid.png`
  （93abf601 渲染；PNG 方向已勘误翻正，见 9D-C 报告附录 B）
- after：`generated-images/phase9d-d/after-{14,24,32}pt-{1x,2x}[-grid].png`
  + `after-wide-24pt-2x.png`（40d473b 渲染，probe 合成路径已修正）

## 附录 B：数据工件

- `/tmp/macssh_phase9dc_probe/out/results-before.jsonl`（93abf601 全部原始测量）
- `/tmp/macssh_phase9dc_probe/out/results-after.jsonl`（40d473b 全部原始测量）
- probe 经本地 path 依赖 fork working tree（before 运行时为 93abf601，after 运行时为 40d473b）。
