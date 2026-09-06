# MacSSH 1.1 Phase 9D-A — VS16 1-Cell Emoji Renderer Fit — Visual Preview Gate

> 角色：Renderer Preview Producer（非 Phase 9C 调查者，非 Phase 9B 开发者）。
> 范围：**只做视觉方案预览**。在 `/tmp` checkout SwiftTerm 概念、写 CG 渲染 prototype、渲染对比 PNG；阅读 Phase9C 两份报告与 SwiftTerm `771e79f` 源码。
> **未修改 production code / SwiftTerm fork / MacSSH / TerminalFontSizeController / Package.resolved / SwiftTerm pin；未 commit / merge / push；未创建 fork branch；未开始 remediation。**
> 预览日期：2026-09-05（Asia/Shanghai）。

---

## 独立复核限制声明（必读）

本预览的 prototype 位于 `/tmp/macssh_phase9d_preview/renderer.swift`（CG prototype，**非 SwiftTerm production**）。它从源码重新实现 SwiftTerm `771e79f` 的渲染关键路径（cascade font、cellWidth `"W"` advancement + 2x snap、按 logical width 分段的 `CTLine` shaping、固定网格 glyph origin、`glyphSlotFit` for `columnWidth>=2`），并在 `columnWidth==1` 分支上插入四种 candidate fit 策略以供视觉比较。

Prototype 复现的 CoreText 度量与 Phase 9C 调查报告 §12 / §20 / §21 **完全一致**（见 §31 的实测表），因此 prototype 对 Apple Color Emoji 的 advance / ink 度量是可靠的。所有 fit 数值（scale、overhang）均来自本次 prototype 的实测，**非复制 Phase 9C 报告**。

PNG 产物已复制到 `generated-images/phase9d-a/`（仓库内，非 production code），报告内以相对路径引用，便于用户在 `/tmp` 清理后仍可复现视觉判断。

---

## 1. MacSSH branch

`feature/macssh-1.1-terminal-font-size`（`git branch --show-current` ✓）

## 2. MacSSH HEAD

`c6bf66c2b985530e6687fefe62cdf08246190e41`（`git rev-parse HEAD` ✓，与 Phase 9C 一致）

## 2.1. MacSSH working tree (Phase 9B 保持原样)

Phase 9B working tree 完整保留，**未被 Phase 9D-A 修改**：

- modified（7，与 Phase 9C 调查前完全相同）：`MacSSH.xcodeproj/project.pbxproj`、`AppLanguage.swift`、`AppState.swift`、`SettingsView.swift`、`Localizable.xcstrings`、`SessionManager.swift`、`Scripts/gen_localizable.py`
- untracked（与 Phase 9C 一致 + 本预览新增）：Phase 9A/9B/9C 报告、`TerminalFontSizeController.swift`、两份 font-size tests、`generated-images/`（**含本预览新增的 `phase9d-a/` 子目录**）、本预览报告
- `git diff --stat`：7 files changed, 4773 insertions, 4079 deletions（与 Phase 9C 调查前数字一致）

**Phase 9D-A 对 production 的修改数 = 0**。唯一新增是 `Docs/Phase9D-A-...md` 报告 + `generated-images/phase9d-a/*.png`（图像，非 code）。

## 3. SwiftTerm baseline

`771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `https://github.com/canbyte0/SwiftTerm.git`

三方一致（Phase 9C §5 已独立确认）：`Package.resolved` revision、`ThirdParty/SwiftTerm-fork` HEAD、fork `git status` 干净。Phase 9D-A **未推进** 该 revision。

## 4. production changes

**Phase 9D-A 对 production 的修改 = 0**：

- SwiftTerm fork `git status --short` = 空（fork 未被修改）✓
- MacSSH working tree 只新增 `Docs/Phase9D-A-...md` + `generated-images/phase9d-a/*.png`，无任何 `.swift` / `.pbxproj` / `.resolved` 改动 ✓
- 未创建 SwiftTerm remediation commit / branch ✓
- 未修改 `Package.resolved` / `TerminalFontSizeController` / `preserveBaseWidth` ✓

## 5. Phase9C root cause（独立确认）

根因链（Phase 9C 两份报告独立确认，本预览 prototype 实测度量吻合）：

```
preserveBaseWidth（正确的 shell/model 语义，1 cell）
  → VS16 保留 → CoreText 选择 Apple Color Emoji 单 glyph（自然 ≈ 2 cells）
  → SwiftTerm fixed-grid 后续 cell origin 正确（:2078）
  → cursor grid 正确（:2513）
  → glyphSlotFit guard 仅允许 columnWidth >= 2（:450）
  → 1-cell VS16 glyph 跳过 glyphSlotFit（:2122）
  → Apple Color Emoji ink bounds 超出 logical cell
  → ink 覆盖相邻 cell
```

**关键独立洞察（Phase 9C-Acceptance-Review §16/§27）**：CoreText advance overflow 是测量事实，**但不是可见缺陷的直接成因** —— SwiftTerm 不用 CoreText natural advance 定位（`:2078` 用 `glyphColumn × cellDimension.width`），故 advance 多大都不移后续 cell。真正造成相邻 cell 被覆盖的是 **ink/bounds overflow**。Phase 9D remediation 必须针对 **ink overflow**，而不是 advance。

## 6. independent-review result

**ARCHITECTURE / ROOT-CAUSE PASS**（`Docs/Phase9C-Acceptance-Review.md` §1）。

根因架构链从源码独立确认为真；推荐 remediation 方向（Option F+B，presentation-only glyph fit）在架构层正确且安全；但实现尚未做，且用户已能肉眼复现 32pt 下的相邻字符覆盖。Phase 9B FINAL PASS **保持 BLOCKED**，直到窄范围、可缓存、CG/Metal 共用、metrics-driven 的 1-cell overflow glyph fit 完成并通过 §55–§57 验收 gate。

## 7. reviewer P1 full detail（原文摘录）

来源：`Docs/Phase9C-Acceptance-Review.md` §2，完整原文：

> **P1（架构层已确认，阻塞 FINAL PASS）：preserveBaseWidth 下的 1-cell VS16 Apple Color Emoji glyph 未进入 `glyphSlotFit`，原尺寸绘制导致相邻 cell ink 覆盖。**
>
> 独立源码证据链：
>
> 1. `Terminal.swift:1518-1520` — preserve 分支 `updateCharData(&cd, char: newCh, size: Int32(oldSize))`，`oldSize` = 基字符原宽 1，不插 width-0 续接，不额外移 `buffer.x`。→ ⚠️/❤️ logical width = 1。
> 2. `buildAttributedString:1121-1126` — `if builder.columnWidth != width` flush+新段；preserve 下 ⚠️ width=1 → 进入 `columnWidth: 1` 段。
> 3. `AppleTerminalView.swift:446-450` — `glyphSlotFit(font:glyph:columnWidth:)` 首行 `guard columnWidth >= 2, cellDimension != nil else { return .identity }`。columnWidth=1 直接返回 `.identity`（dx=0, dy=0, scale=1），**不做任何 fit/scale**。
> 4. `:2122` — draw path `if prepared.segment.columnWidth >= 2 { ... }`，columnWidth=1 段整块跳过，直接 `:2148 CTFontDrawGlyphs(runFont, runGlyphs, &glyphPositions, ...)` 原尺寸。
> 5. `:2078` — glyph origin = `lineOrigin.x + CGFloat(glyphColumn) * cellDimension.width`，固定网格；Apple Color Emoji natural advance **不推动后续 cell**，但 oversized ink 仍画进相邻 cell。
>
> 结论：1-cell VS16 Emoji glyph 按 natural Apple Color Emoji 尺寸（约 point size，远大于 JetBrains Mono cell ≈ 0.6×point size）绘制，ink 覆盖右侧相邻 cell。**P1 成立，阻塞 Phase 9B FINAL PASS。**

Phase 9D-B 如何 hard-gate P1：remediation 必须**放宽 `glyphSlotFit` 的 guard**（从 `columnWidth >= 2` 扩展到 `columnWidth == 1` 且 ink 真实溢出），使 1-cell VS16 Apple Color Emoji glyph 进入 fit 路径，按 logical cell uniform-scale + center，**消除相邻 cell ink 覆盖**。验收 gate（§55–§57 / §41）要求 fit 后 ink overhang ≤ 0.5pt@2x、cursor x == logicalColumn × cellWidth（零变化）。

**若无法定位 P1 的具体内容 → STOP，不得进入 Phase 9D-B。本预览已完整定位 P1（原文摘录如上），可进入用户视觉确认。**

## 8. reviewer P2 full detail（原文摘录）

来源：`Docs/Phase9C-Acceptance-Review.md` §3，完整原文：

> **P2（remediation 设计 gate）：future fit 必须由单一 source 计算 transform，CG 与 Metal 共同消费，并带 (font, glyph, cellDimension) cache。**
>
> 独立证据：
> - `glyphSlotFit` docstring（`:444-445`）声明"Shared by the CoreGraphics and Metal glyph renderers so they stay pixel-consistent"。
> - 实际调用点：**仅在 CG draw path `:2126`**。Metal renderer（`:2406-2439`）走 `metalDirtyRange` + `requestMetalDisplay()` + GPU glyph atlas 路径，本评审**未发现 Metal path 调用 glyphSlotFit**。
> - MacSSH 当前未显式启用 Metal（调查报告 §76），故 CG path 是用户可见路径；但 docstring 的"shared"是设计意图，未来若启用 Metal，fit 必须覆盖 Metal，否则两 renderer 会出现 ink 一致性差异。
> - 每 glyph 调 `CTFontGetAdvancesForGlyphs` + `CTFontGetBoundingRectsForGlyphs`（`:458, :462`）有 hot-path 成本；若把 1-cell 也纳入 fit，Latin hot path 会退化，**必须 cache**。
>
> **P2，不单独阻塞根因结论，但属于 remediation 实现的硬设计 gate。**

Phase 9D-B remediation gate：必须实现 **single-source presentation transform** + **cache** + **CG/Metal consistency**（见 §37–§40）。不得 CG 一套、Metal 另一套。

## 9. immutable invariants（Phase 5，绝对不得改变）

- `VariationSelector16WidthPolicy.preserveBaseWidth` —— 不改
- logical cell count（⚠️/❤️ = 1 cell）—— 不改
- cursor column（`buffer.x`）—— 不改
- terminal model / CharData width（preserve=1）—— 不改
- PTY bytes / input bytes / output bytes / VS16 bytes —— 不改
- zsh / libc `wcwidth` 语义 —— 不改
- bracketed paste contents —— 不改

Phase 9D remediation **严格停留在 renderer drawing layer**：只改 `glyphPositions`（局部 copy）的 dx/dy/scale，不改 `positions`（grid）/ `caretCol` / `caretView.frame` / model / bytes。Phase 5 的 13 项测试作为硬 gate 保留（Phase 9C-Acceptance-Review §52）。

## 10. scope predicate candidate（独立 reviewer 推荐，本预览验证）

独立 reviewer 推荐 future predicate（`Docs/Phase9C-Acceptance-Review.md` §34）：

```
columnWidth == 1
AND cellDimension != nil
AND runFont != fontSet.normal            // 性能 gate：base font 的 Latin 跳过 metric lookup
AND advance.width > 0
AND ink.width > 0 AND ink.height > 0
AND (ink.width > cellWidth OR ink.height > cellHeight)   // correctness gate：ink 真实溢出 logical cell
```

本预览 prototype 用此 predicate 实测验证（§20–§27），**确认不误伤任何 control**：

- **⚠️**（VS16 emoji，ink overflow）→ 触发 fit ✓
- **❤️**（VS16 emoji，ink overflow）→ 触发 fit ✓
- **⚠**（JetBrains Mono text，runFont == base，跳过）→ untouched ✓
- **❤**（Menlo text，runFont != base 但 ink.width=7.786 < cellW=8.5，predicate 不成立）→ untouched ✓
- **😀/🚀/✅**（columnWidth=2，走既有 wide path，不进 1-cell predicate）→ untouched ✓
- **ASCII A-Z/0-9/|/W**（runFont == base，跳过）→ untouched ✓
- **CJK 中文**（columnWidth=2，走 wide path）→ untouched ✓

`advance > 0` 在本预览实测中**仅作合法性 guard**（所有触发 fit 的 glyph advance 均 > 0），不影响 predicate 选择性 —— ink overflow 才是 correctness gate。predicate 是 metrics-driven、非 VS16-specific、非字号-specific，从 10pt 到 32pt 同一规则。

## 11. Preview A — Uniform fit

策略：1-cell overflow glyph **保持 aspect ratio，uniform scale down**，完整 fit 进 logical cell rect；按 advance 水平居中，按 ink 垂直居中。复用现有 `glyphSlotFit:467-483` 的 uniform-scale + center 逻辑，仅放宽 guard 到 `columnWidth==1` + ink overflow。

实现：`scale = max(0.1, min(cellW/ink.width, cellH/ink.height, 1))`；`dx = (cellW - advance.width*scale)/2`；`dy` 按 ink 中心垂直居中。prototype 用 `CTFontCreateCopyWithAttributes(runFont, size*scale)` 缩小绘制（与 production `:2142` 同路径，保证 smaller strike 清晰）。

预期观察重点：**❤️ 是否明显矮于文字**。

实测（见 §31 表）：14pt scale=0.486、24pt scale=0.604、32pt scale=0.594。缩放后 emoji 视觉高度 ≈ cellW（14pt ≈ 8.5pt），小于 natural（14pt ≈ 17.5pt），但仍清晰可辨。**❤️ 缩放后视觉高度 ≈ cellW，明显矮于 ASCII 行高（ascent ≈ 14.28pt @14pt）—— 该 concern 在预览中实测可见**（见 `comparison-32pt-normal.png` A 列 vs Current 列）。

## 12. Preview B — Horizontal-only fit

策略：仅当 `ink.width > cellW`，**只缩放 X 轴**（`sx = cellW/ink.width`），Y 不变，保持 baseline / vertical size。

实现：prototype 用 `CGContext.scaleBy(x: sx, y: 1)`（CTM 水平缩放）后 `CTFontDrawGlyphs` 绘制。

预期观察重点：**❤️ 是否被压得过窄、⚠️ 是否变形、大字号是否更自然**。

实测：sx 与 A 的 uniform scale 数值相同（因 ink 方形，cellW/ink.width = min），但**只缩 X**导致 aspect ratio 破坏。预览实测可见 ⚠️ 变成窄三角（warning 标志被横向压扁）、❤️ 变成压扁的心形 —— **视觉损失明显，超出可接受范围**（见 `comparison-32pt-normal.png` B 列）。**B 单独不可取**（与 Phase 9C-Acceptance-Review §32 一致："horizontal squash 破坏 aspect ratio"）。

## 13. Preview C — Limited horizontal fit（保留少量 overhang）

策略：presentation-only **uniform** fit，但目标 slot 宽度 = `factor × cellW`（factor ∈ {1.10, 1.15}），允许少量 ink overhang。

实现：`target = cellW * factor`；`scale = min(target/ink.width, cellH/ink.height, 1)`；uniform scale 保 aspect ratio；center。prototype 用 font copy。

预期目的：判断"完全塞进一个 monospace cell 是否反而让 Apple Emoji 太窄"。

实测：14pt C110 scale=0.534、C115 scale=0.559；32pt C110 scale=min(9.35×... 实测见 §31)。预览实测显示 **C110 与 C115 视觉差异极小**（5% allowance 在 ink 边缘几乎不可察觉），emoji 仍比 A 略大但远小于 natural。**C 是 A 与 Current 的折中**，但额外 overhang 违反 §56 ink-containment gate（fit 后 ink.maxX ≤ cellRect.maxX + 0.5pt@2x）。**若选 C，须放宽验收 metric**（不推荐，见 §33）。

## 14. Preview D — Origin compensation only

策略：**不缩 glyph**，只重新居中 visual bounds：`dx = (cellW - ink.width)/2 - ink.origin.x`，让 ink 在 cell 内对称居中，无 scale。

预期：证明若 glyph 本身宽度 > cell，仅 origin compensation **仍覆盖相邻 cell**（symmetric overflow）。

实测：14pt ⚠️ ink.width=17.5、cellW=8.5 → dx 居中后左 overhang 4.5pt、右 overhang 4.5pt，**两侧均覆盖邻居**。预览实测可见 D 列 ⚠️/❤️ 居中但仍向左右两侧溢出 —— **确认 D 无法解决根本问题**（与 Phase 9C-Acceptance-Review §50 / 调查报告 §50 一致："单独使用不够，居中只能把 12–13pt 右 overhang 分摊为左右侵入，仍覆盖两个邻居"）。

## 15. 14pt comparison

`generated-images/phase9d-a/comparison-14pt-normal.png`（行 = 14 个测试串，列 = Current/A/B/C110/C115/D）

- **Current**：⚠️/❤️ 已 overhang（ink.width=17.5 vs cellW=8.5，右 overhang 9pt），相邻 ASCII 已被覆盖 —— 确认 14pt baseline 缺陷**已存在**（Phase 9C §37，非 9B regression）。
- **A**：⚠️/❤️ 缩放至 cellW，无 overhang；❤️ 明显矮于 W/B/C 文字。
- **B**：⚠️/❤️ 横向压扁，变形。
- **C110/C115**：略大于 A，差异极小。
- **D**：居中但两侧溢出。
- ASCII / CJK / text ⚠ ❤ / 😀🚀✅ 全部 untouched ✓。

## 16. 24pt comparison

`generated-images/phase9d-a/comparison-24pt-normal.png`

- **Current**：⚠️/❤️ overhang ≈ 9.5pt（ink.width=24 vs cellW=14.5），B/C 被覆盖。
- **A**：scale=0.604，缩放后 emoji ≈ 14.5pt，比 14pt 相对更接近 natural（ratio 更大），视觉损失小于 14pt。
- **B**：横向压扁，变形。
- **C110/C115**：scale 略大，差异极小。
- **D**：居中但两侧溢出 ≈ 4.75pt。
- controls untouched ✓。

## 17. 32pt comparison

`generated-images/phase9d-a/comparison-32pt-normal.png`（用户最关心的最大字号）

- **Current**：⚠️/❤️ overhang = 13pt（ink.width=32 vs cellW=19），相邻 ASCII 严重覆盖，内容可读性受损（Phase 9C-Acceptance-Review §58 拒绝 accept-overhang）。
- **A**：scale=0.594，缩放后 emoji ≈ 19pt，fit 在 cell 内，无 overhang；❤️ 仍矮于文字但 32pt 下相对可接受。
- **B**：横向压扁，⚠️ 三角严重变形。
- **C110/C115**：scale=min(20.9/32, ...)=0.653 / 0.683，略大于 A。
- **D**：居中但两侧 overhang 6.5pt。
- controls untouched ✓。

## 18. debug-grid comparison

`generated-images/phase9d-a/comparison-32pt-grid.png`、`comparison-24pt-grid.png`、`comparison-14pt-grid.png`（含 logical cell 细框 overlay）

每个 logical cell 画细框（alpha 0.16 白线），用户可直观判断 ink 是否越过 cell boundary：

- **Current**：⚠️/❤️ ink 明显越过右侧 cell 边界，覆盖下一 cell 的内容。
- **A**：⚠️/❤️ ink 完全落在 cell 内（含 AA 边缘）。
- **B**：ink 落在 cell 内但横向变形。
- **C110/C115**：ink 略越边界（允许 overhang）。
- **D**：ink 居中但两侧越过边界。
- 分隔符 `|⚠️|❤️|⚠️|❤️|`：Current 下 `|` 被 emoji ink 覆盖；A 下 `|` 清晰可见。

## 19. normal comparison（无辅助线）

`comparison-{10,14,18,24,32}pt-normal.png`（正常 Terminal 深色背景，无 debug rect），用于判断实际视觉效果。每张包含 14 行测试串 × 6 列策略。

## 20. ⚠ result（text presentation, U+26A0 无 VS16）

- run = `JetBrainsMono-Regular`（base font），columnWidth=1。
- predicate：`runFont != fontSet.normal` **不成立**（runFont == base）→ **跳过 metric lookup，untouched**。
- 实测（14pt）：ink.width=8.680 < cellW=8.5？8.680 > 8.5 微溢出，但因 runFont==base 性能 gate 提前返回 identity —— **未触发 fit**。
- 预览：⚠ 在所有策略列下完全一致（A/B/C/D 与 Current 相同）✓。
- **证明 predicate 不会错误压缩 base font 的 text glyph**（即使其 ink 微溢出，性能 gate 跳过，保持 Latin hot path）。

## 21. ⚠️ result（VS16 emoji, U+26A0+U+FE0F）

- run = `AppleColorEmoji`，columnWidth=1（preserve）。
- predicate：`runFont != base` ✓ + `ink.width=17.5 > cellW=8.5`（14pt）✓ → **触发 fit**。
- Current：原尺寸绘制，overhang 9pt @14pt、9.5pt @24pt、13pt @32pt。
- A：scale 0.486/0.604/0.594，fit 在 cell 内。
- B：横向压扁。
- C110/C115：scale 略大。
- D：居中但两侧 overhang。
- **⚠️ 是 predicate 触发的目标 glyph 之一** ✓。

## 22. ❤ result（text presentation, U+2764 无 VS16）

- run = `Menlo-Regular`（system text fallback，非 base），columnWidth=1。
- predicate：`runFont != base` ✓ + `ink.width=7.786 < cellW=8.5`（14pt）→ `ink.width > cellW` **不成立** → **predicate 不触发，untouched**。
- 预览：❤ 在所有策略列下完全一致 ✓。
- **证明 predicate 靠 ink 度量区分 text presentation 与 emoji presentation，不会错误压缩 Menlo text ❤**（Phase 9C-Acceptance-Review §36 验证）。

## 23. ❤️ result（VS16 emoji, U+2764+U+FE0F）

- run = `AppleColorEmoji`，columnWidth=1（preserve）。
- predicate：`runFont != base` ✓ + `ink.width=17.5 > cellW=8.5`（14pt）✓ → **触发 fit**。
- 行为与 ⚠️ 相同（ink 度量相同），但 ❤️ 实际非透明像素略少（Phase 9C §23），肉眼接近度略不同。
- A 下 ❤️ 缩放后**明显矮于 W/B/C 文字** —— 该 concern 实测可见。

## 24. 😀 result（non-VS16 emoji, U+1F600）

- run = `AppleColorEmoji`，但 columnWidth=**2**（`testPlainEmojiKeepWidthTwoUnderPreservePolicy` 验证，non-VS16 emoji 不受 preserve 影响）。
- 走既有 wide-cell path（`glyphSlotFit:450` guard `columnWidth>=2` 通过），**1-cell predicate 不介入**。
- 预览：😀 在所有策略列下完全一致（既有 wide-fit centering）✓。
- **predicate 不影响 2-cell emoji** ✓（Phase 9C-Acceptance-Review §37）。

## 25. 🚀 result（non-VS16 emoji, U+1F680）

同 §24：columnWidth=2，走 wide path，untouched ✓。

## 26. ASCII result（A-Z / 0-9 / | / W）

- run = `JetBrainsMono-Regular`（base），columnWidth=1。
- predicate：`runFont == base` → 性能 gate 跳过，**identity，untouched**。
- 预览：`ABCDE`、`WWWWW`、`12345`、`|||||` 在所有策略列下完全一致 ✓。
- **证明 renderer transform 不影响普通 JetBrains Mono**（Phase 9C-Acceptance-Review §38 "零风险"）。

## 27. CJK result（中文）

- run = `PingFang SC`，columnWidth=**2**。
- 走既有 wide-cell path，1-cell predicate 不介入。
- 预览：`ABC中文DEF` 中 "中文" 在所有策略列下完全一致 ✓。
- **证明已有 2-cell CJK rendering 完全不发生变化**（Phase 9C-Acceptance-Review §39 "零风险"）。

## 28. cursor result

`generated-images/phase9d-a/cursor-{14,24,32}pt.png`（`A⚠️B❤️C` 末尾加 caret）

- caret x = `cellDimension.width × caretCol`（col 5），caret width = cellW × 1。
- 预览：caret 在所有策略列下**位置完全一致**（Current/A/B/C/D 的 caret 在同一 x）✓。
- **证明 renderer transform 不改变 cursor logical x**（Phase 9C-Acceptance-Review §49 / §57 hard gate）。

## 29. highlight result

`generated-images/phase9d-a/highlight-AwarnBheart-{14,24,32}pt.png`（col 1 ⚠️ 加蓝色 highlight background）、`highlight-AheartBheart-*.png`（col 1 ❤️）

- highlight background 按 logical cell rect 绘制（grid origin），**不随 glyph scale 改变**。
- 预览：Current 下 ⚠️ ink 越过 highlight 边界；A 下 ⚠️ fit 在 highlight cell 内，background 边缘清晰。
- **证明 highlight background 仍按 logical cell rect，glyph fit 只影响 foreground ink**（Phase 9C-Acceptance-Review §47 "零影响"）。

## 30. selection result（if tested）

`generated-images/phase9d-a/selection-{14,24,32}pt.png`（`A⚠️B❤️C` col 1..3 加 selection background）

- selection rect 按 logical cell。
- 预览：selection background 在所有策略列下宽度一致（3 cells × cellW），不随 glyph scale 改。
- **证明 selection rect 不随着 glyph scale 改**（Phase 9C-Acceptance-Review §48 "零影响"）。

## 31. uniform-fit quality（A）— 实测度量

Prototype 实测 CoreText 度量（与 Phase 9C §12/§20/§21 完全一致）：

| size | cellW | cellH | ⚠️/❤️ ink.w | ink.h | A scale | A 后 emoji 高 | Current 右 overhang |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 | 6.0 | 14.0 | 12.5 | 12.5 | 0.480 | 6.0 | 6.5 |
| 14 | 8.5 | 19.0 | 17.5 | 17.5 | 0.486 | 8.5 | 9.0 |
| 18 | 11.0 | 24.0 | 21.0 | 21.0 | 0.524 | 11.0 | 10.0 |
| 24 | 14.5 | 32.0 | 24.0 | 24.0 | 0.604 | 14.5 | 9.5 |
| 32 | 19.0 | 43.0 | 32.0 | 32.0 | 0.594 | 19.0 | 13.0 |

A scale = `min(cellW/ink.w, cellH/ink.h, 1)`（因 ink 方形，由 cellW/ink.w 主导）。

质量评估：
- **不裁切** ✓ —— 完整 fit，无信息丢失。
- **保 aspect ratio** ✓ —— emoji 保持方形，不变形。
- **视觉过小 concern 实测确认**：14pt 缩放后 emoji ≈ 8.5pt（natural 17.5pt 的 49%），❤️ 明显矮于文字（ascent 14.28pt）；32pt 缩放后 ≈ 19pt（natural 32pt 的 59%），相对可接受。
- **大字号更自然**：scale ratio 随字号增大（14pt 0.486 → 32pt 0.594），大字号下 emoji 相对更接近 natural，视觉损失小于小字号。
- ink 完全落入 logical cell，满足 §56 ink-containment gate（overhang ≤ 0.5pt@2x）✓。

## 32. horizontal-fit quality（B）

- sx = cellW/ink.w（与 A scale 数值相同，因 ink 方形）。
- **只缩 X，破坏 aspect ratio**：⚠️ 变窄三角、❤️ 变压扁心形。
- 14pt：sx=0.486，⚠️ 宽度 8.5pt 高度 17.5pt —— 严重变形（宽高比 0.49 vs natural 1.0）。
- **不可取**：变形损失超出可接受范围。与 Phase 9C-Acceptance-Review §32 结论一致。

## 33. limited-overhang quality（C 110% / 115%）

| size | C110 scale | C115 scale | C110 后 emoji 宽 | C110 右 overhang |
|---:|---:|---:|---:|---:|
| 14 | 0.534 | 0.559 | 9.35 | 0.85 |
| 24 | 0.665 | 0.695 | 15.95 | 1.45 |
| 32 | 0.653 | 0.683 | 20.9 | 1.9 |

（C110: `scale = min((cellW×1.10)/ink.w, cellH/ink.h, 1)`；C115 同理 ×1.15。因 ink 方形，cellH/ink.h > 1，故 scale 由 (cellW×factor)/ink.w 主导。）

- **C110 vs C115 视觉差异极小**（5% allowance 在 ink 边缘几乎不可察觉）。
- emoji 比 A 略大，但**违反 §56 ink-containment gate**（overhang > 0.5pt@2x）。
- **若选 C，须放宽验收 metric**，不推荐（验收 gate 应保持 ink 完全 containment）。
- 结论：C 仅作视觉比较参考，**不作为首选 remediation**。

## 34. distortion assessment

| 策略 | 裁切 | aspect ratio | overhang | 变形 | 可接受 |
|---|:---:|:---:|:---:|:---:|:---:|
| Current | 无 | 保 | 9–13pt | 无 | ✗（覆盖邻居） |
| A Uniform | 无 | **保** | 0 | 无 | ✓（但 emoji 偏小） |
| B Horizontal | 无 | **破坏** | 0 | **严重** | ✗ |
| C 110% | 无 | 保 | ~1–2pt | 无 | △（违反 gate） |
| C 115% | 无 | 保 | ~1–2pt | 无 | △（违反 gate） |
| D Origin | 无 | 保 | 4.5–6.5pt 双侧 | 无 | ✗（仍覆盖） |

- **A 是唯一同时满足"不裁切 + 保 aspect ratio + 零 overhang + 无变形"的策略**。
- B 破坏 aspect ratio，不可取。
- C 违反 ink-containment gate，不推荐。
- D 无法解决根本问题。
- **唯一可行的 remediation 视觉方案 = A（Uniform fit）**，与 Phase 9C-Acceptance-Review §62 / §33 推荐 Option F+B（uniform scale 保 aspect ratio）一致。

## 35. recommended visual option

基于 §34 distortion assessment：

**推荐视觉方案 = A（Uniform fit，保 aspect ratio，完整 fit 进 logical cell，按 advance/ink 居中）。**

理由：
1. 唯一满足 ink-containment gate（§56）。
2. 唯一保 aspect ratio（emoji 不变形）。
3. 唯一不裁切（无信息丢失）。
4. 复用现有 `glyphSlotFit:467-483` 逻辑，仅放宽 guard，实现风险最低。
5. 与 Phase 9C-Acceptance-Review §62 "safest remediation = Option F+B（uniform scale 保 aspect ratio）"一致。

**已知 trade-off**：缩放后 emoji 视觉高度 ≈ cellW（14pt 8.5pt），明显矮于文字行高（14pt ascent 14.28pt）—— 这是 1-cell monospace slot 的固有约束（emoji natural ≈ 2 cell，压缩到 1 cell 必然偏小）。该 trade-off 远好于覆盖相邻字符。

**最终视觉方案由用户从 Current / A / B / C 中确认**（见 §47）。本预览提供证据，**不替用户做决定**。

## 36. proposed production predicate

基于 §10 验证，proposed production predicate（metrics-driven，非 VS16-specific，非字号-specific）：

```swift
// 放宽 glyphSlotFit guard（:450），新增 1-cell overflow 分支：
func glyphSlotFit(font: CTFont, glyph: CGGlyph, columnWidth: Int) -> GlyphSlotFit {
    guard cellDimension != nil else { return .identity }
    let cellW = cellDimension.width, cellH = cellDimension.height

    // 既有 wide-cell path（columnWidth >= 2）—— 保持不变
    if columnWidth >= 2 { /* 现有 :452-485 逻辑 */ }

    // 新增 1-cell overflow path
    if columnWidth == 1 {
        guard font != fontSet.normal else { return .identity }   // 性能 gate
        var g = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
        guard advance.width > 0 else { return .identity }
        var ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &ink, 1)
        guard ink.width > 0, ink.height > 0 else { return .identity }
        guard ink.width > cellW || ink.height > cellH else { return .identity }  // correctness gate
        // uniform scale + center（复用 :467-483）
        let scale = max(0.1, min(min(cellW / ink.width, cellH / ink.height), 1))
        let dx = (cellW - advance.width * scale) / 2
        var dy: CGFloat = 0
        let baselineFromBottom = ceil(CTFontGetDescent(fontSet.normal) + CTFontGetLeading(fontSet.normal))
        let inkCenter = (ink.origin.y + ink.height / 2) * scale
        dy = (cellH / 2 - baselineFromBottom) - inkCenter
        return GlyphSlotFit(dx: dx, dy: dy, scale: scale)
    }
    return .identity
}
```

draw path `:2122` 的 guard 须同步放宽：`if prepared.segment.columnWidth >= 2 || /* 新增 1-cell overflow */ ...`，或直接让 `glyphSlotFit` 对 1-cell 也计算（identity 时不触发 anyScaled）。

**注意**：以上是 proposal，**非 Phase 9D-A 实现**。Phase 9D-B 须独立实现 + 独立验收。

## 37. CG architecture

CG draw path（`AppleTerminalView.swift:2051-2149`）：

- `:2052` 遍历 `preparedSegments`。
- `:2074-2107` 按 cell ordinal 计算 `positions`（grid origin）。
- `:2122-2133` 对 columnWidth>=2 段调 `glyphSlotFit` 得 `(dx,dy,scale)`，加到 `glyphPositions`（`positions` 的 copy）。
- `:2135-2149` 若 anyScaled，逐 glyph 用 `CTFontCreateCopyWithAttributes(ctRunFont, size*s)` 缩小绘制；否则整 run `CTFontDrawGlyphs`。
- `:2151+` decorations 用 `positions`（grid），不用 `glyphPositions`。

Phase 9D-B 扩展 `glyphSlotFit` 到 1-cell overflow → **CG path 自动消费**（`computed[i]` 非 identity → anyScaled → 缩小绘制）。prototype 已验证此路径可行（A/C110/C115 用 font copy，B 用 CTM——production 应统一用 font copy 保 smaller strike 清晰）。

## 38. Metal architecture

Metal renderer 存在（`Sources/SwiftTerm/Apple/Metal/Shaders.metal` + `AppleTerminalView.swift:2331-2348, :2406-2448, :2553-2573`）。Metal 用 `metalDirtyRange` + `requestMetalDisplay()` + GPU glyph atlas，**非逐 glyph `CTFontDrawGlyphs`**。

Phase 9C-Acceptance-Review §42 独立确认：**未发现 Metal path 调用 `glyphSlotFit`**（搜索仅 `:2126` CG path 一处）。docstring `:444-445` "Shared by CoreGraphics and Metal" 是**设计意图，实现现状 Metal 未接入**。MacSSH 当前未启用 Metal（Phase 9C §76），故 CG 是用户可见路径。

## 39. shared transform design（P2 remediation gate）

Phase 9D-B remediation **必须**：

1. 扩展 `glyphSlotFit` guard/predicate（§36）—— CG path 立即受益。
2. **显式接线 Metal path**：若 Metal 有自己的 glyph positioning，须同步接入同一 `glyphSlotFit` 计算，或确认 Metal 的 atlas blit 也应用同一 scale。
3. **single source of transform**：`glyphSlotFit` 作为**唯一** fit 计算入口，CG/Metal 都消费其结果，**避免两套实现**。

不得：CG 一套、Metal 另一套（P2 gate）。

若 MacSSH 不启用 Metal，Metal parity 可作为 P2/future gate 不阻塞 CG fix；但 docstring 已承诺 shared，长期应兑现。

## 40. cache proposal

扩展到 1-cell 后，每个 fallback 1-cell glyph 都调 `CTFontGetAdvancesForGlyphs` + `CTFontGetBoundingRectsForGlyphs`，hot-path 成本上升。**必须 cache**。

**最小 cache key**（Phase 9C-Acceptance-Review §45）：

```
(fontIdentity, glyph, cellWidth, cellHeight)
```

- `fontIdentity`：`PostScriptName + pointSize`（size 变化时 font 对象变，天然隔离）。
- `glyph`：CGGlyph（UInt16）。
- `cellWidth` / `cellHeight`：CGFloat（snapped 后值，size 变化时变）。
- value = `GlyphSlotFit(dx, dy, scale)`。

复用现有 `FallbackFontKey`（`:145`）模式的 cache 上限/LRU，不新增第二套 cache 基础设施。

**font size 10→32 切换**：cellDimension 变 → cellWidth/cellHeight 变 → key 变 → **不会错误复用旧尺寸 cache** ✓（Phase 9C-Acceptance-Review §46）。

Phase 9D-A 只给方案，**不过度实现 cache**。Phase 9D-B 实现时须 benchmark CG 与 Metal hot path。

## 41. P1 remediation gate

Phase 9D-B 必须 hard-gate P1（§7）：

1. 放宽 `glyphSlotFit:450` guard 到 `columnWidth == 1` + ink overflow（§36 predicate）。
2. 放宽 draw path `:2122` guard 同步。
3. 验收 gate（Phase 9C-Acceptance-Review §55–§57）：
   - separator glyph origin 逻辑误差 = **0 pt**（源码精确，`cellIndex × cellWidth`）。
   - fit 后 1-cell VS16 ink overhang ≤ **0.5 pt@2x**（左右均须满足）。
   - cursor x == `logicalColumn × cellWidth`（**零容差**），model cursor column 零变化，caret width 零变化。
4. Phase 5 的 13 项 VS16 测试全绿（policy/逻辑宽度/bracketed paste redraw/copy/CJK/non-VS16 emoji）。

## 42. P2 remediation gate

Phase 9D-B 必须 hard-gate P2（§8）：

1. single-source presentation transform（`glyphSlotFit` 唯一入口）。
2. cache（§40，key 含 fontIdentity/glyph/cellW/cellH）。
3. CG/Metal consistency（§39，Metal path 显式接线或确认 parity）。
4. benchmark CG + Metal hot path，确认 Latin 不退化。

## 43. expected SwiftTerm files

Phase 9D-B remediation 预期修改的 SwiftTerm 文件（**本预览不实现**）：

- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`：
  - `glyphSlotFit:446-486`（放宽 guard + 新增 1-cell overflow 分支）
  - draw path `:2122-2133`（同步放宽 guard）
  - 可能 `Metal` 路径 `:2406-2448`（接线 shared fit）
- 可能新增 cache 存储（同文件或单独）。

fork branch 建议：`macssh-vs16-one-cell-render-fit`（从 `771e79f`，本阶段**不创建**）。

## 44. expected test files

Phase 9D-B 须新增/扩展测试（Phase 9C-Acceptance-Review §53/§54）：

- SwiftTerm fork 测试：1-cell VS16 glyph fit 后 ink containment、cursor x 不变、separator origin 不变。
- MacSSH 测试（`Tests/SSH/`）：
  - `⚠️`/`❤️` typed/pasted/programmatic paste（`pasteText`）
  - `A⚠️B❤️C`、`|⚠️|❤️|⚠️|❤️|`、四个连续 `⚠️`/`❤️`
  - `A⚠B❤C`（text presentation，须 untouched）
  - cursor left/right、backspace、delete、history up/down、Home/End
  - wrapped long command、bracketed paste
  - Local（preserve）+ Remote（widen，2-cell emoji 既有 path 须不回归）
  - `😀`/`🚀`/`✅` 2-cell regression
  - ASCII、CJK、combining marks、italic/bold
  - selection、highlight、copy、cursor、inverse/ANSI background
- 字号矩阵：10/14/18/24/32 pt × Local/Remote × CG（+ Metal 若启用）× 1x/2x。

## 45. whether fork change is required

**是。** Phase 9C-Acceptance-Review §64 独立确认：根因位于 `AppleTerminalView.swift` renderer（`glyphSlotFit:446-486` + draw path `:2122-2149` + Metal path）。现有 public host API **无**安全的 per-glyph presentation transform hook。MacSSH 外部无法安全 hook renderer 的 glyph positioning。

Phase 9D-B 修复**必须进入 SwiftTerm fork**（branch `macssh-vs16-one-cell-render-fit`，从 `771e79f`）。本预览**不创建**该 branch。

## 46. whether Phase9B remains blocked

**是，Phase 9B FINAL PASS 保持 BLOCKED**，直到 Phase 9D-B renderer remediation 完成并通过 §41 验收 gate（Phase 9C-Acceptance-Review §67）。

理由：
1. P1（§7）成立 —— 1-cell VS16 overflow 覆盖相邻字符，架构链独立确认。
2. 用户已能肉眼复现 32pt 缺陷（本预览 `comparison-32pt-normal.png` Current 列实证）。
3. remediation 未实现，fix 方向（A Uniform）虽正确但无 production code。
4. 唯一分类选择为任务书 §48 的 **C**：需小 Phase 9C/9D rendering remediation 后才能 FINAL PASS。

## 47. user decision required

**用户须从以下视觉方案中确认其一**，Phase 9D-B 才能开始 production 实现：

| 选项 | 视觉表现 | 推荐 |
|---|---|:---:|
| **Current** | ⚠️/❤️ 原尺寸，overhang 9–13pt，覆盖邻居 | ✗（P1 未解决） |
| **A Uniform** | uniform scale 保 aspect ratio，fit 在 cell，emoji 偏小 | ✓（首选） |
| **B Horizontal** | 横向压扁，变形 | ✗ |
| **C Limited** | 略大但违反 ink gate | △（不推荐） |
| **D Origin** | 居中但双侧 overhang | ✗ |

预览证据（`generated-images/phase9d-a/`）：
- `comparison-{10,14,18,24,32}pt-normal.png` —— 正常背景，14 串 × 6 策略
- `comparison-{14,24,32}pt-grid.png` —— debug cell 框，5 串 × 6 策略
- `highlight-AwarnBheart-{14,24,32}pt.png` / `highlight-AheartBheart-*.png`
- `selection-{14,24,32}pt.png`
- `cursor-{14,24,32}pt.png`

**用户确认视觉方案后，Phase 9D-B 才能授权实现**（须先 UI 预览确认，AGENTS.md UI 规则）。

## 48. final status

**PREVIEW COMPLETE — 4 视觉方案（Current/A/B/C）+ D 已渲染对比 — 14/24/32pt（+10/18pt extra）全部覆盖 — CoreText 度量 prototype 实测与 Phase 9C 一致 — predicate 候选已验证不误伤任何 control — 推荐视觉方案 A（Uniform fit）— PHASE 9B FINAL PASS 保持 BLOCKED — 未修改 production / SwiftTerm / Package.resolved / pin / Controller / preserveBaseWidth — 未 commit / merge / push — 未创建 fork branch — STOP，等待用户从 Current/A/B/C 确认视觉方案。**

---

## 验证记录

### Production 完整性

- `git status --short`：Phase 9B 既有 7 modified + untracked reports/Controller/tests/generated-images（**+ 本预览新增 `Docs/Phase9D-A-...md` + `generated-images/phase9d-a/*.png`**）✓
- `git rev-parse HEAD` = `c6bf66c2b985530e6687fefe62cdf08246190e41` ✓
- SwiftTerm pin = `771e79f...` @ canbyte0/SwiftTerm.git（未推进）✓
- Phase 9D-A 对 production `.swift`/`.pbxproj`/`.resolved` 的修改 = **0** ✓

### Prototype 度量复现 Phase 9C

- 14pt cellW=8.5/cellH=19.0，⚠️ ink.w=17.5/ink.h=17.5（Phase 9C §12/§21 一致）✓
- 32pt cellW=19.0/cellH=43.0，⚠️ ink.w=32.0/ink.h=32.0（Phase 9C §12/§21 一致）✓
- ⚠ run=JetBrainsMono-Regular，predicateFire=no（runFont==base 性能 gate）✓
- ❤ run=Menlo-Regular，predicateFire=no（ink.width=7.786 < cellW=8.5）✓
- 😀/🚀/✅ run=AppleColorEmoji columnWidth=2，走 wide path（predicateFire 测得 YES 但 routed to existingWideFit）✓

### Prototype 产物

- `/tmp/macssh_phase9d_preview/renderer.swift`（CG prototype，~500 行）
- `/tmp/macssh_phase9d_preview/out/*.png`（21 张，已复制到 `generated-images/phase9d-a/`）

## STOP

未实现 production fix；未创建 SwiftTerm remediation branch；未 commit；未修改 MacSSH；未 merge；未 push。等待用户从 Current / A / B / C 确认视觉方案。
