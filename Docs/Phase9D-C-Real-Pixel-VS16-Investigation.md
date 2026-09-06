# Phase 9D-C — Real Rendered-Pixel VS16 Containment Investigation

**Task**：在 93abf601 production pin 下，以真实 renderer bitmap 像素（**非** helper fit bounds）
回答："为什么 automated glyph-fit 测试认为 ink 已收进 logical cell，但 MacSSH GUI 仍出现 ⚠️/❤️ 侵入相邻 logical cell"。

**结论（先于详情）**：
1. GUI failure **被 standalone probe 完全复现**——根因在 93abf601 的 fit 实现（
   `CTFontCreateCopyWithAttributes` 重选 bitmap strike），**不在** GUI 专属环境。
2. **真实像素证据 ≠ 理论 metrics**：`CTFontCreateCopyWithAttributes(ACE, size×scale)` 后，
   Apple Color Emoji 重选 sbix strike，其 declared ink **不再**与原始字号 ink 按 scale 线性成比例
   ——ACE 的 ink/size ratio 是**按 strike 分段常数**，不是按字号线性。
3. 实际 raster 与 copy 字体自身的 declared bounds **一致**（AA 差 ≤0.6pt）——
   CoreText rasterization 是诚实的，bug 在 fit math 的线性预测。
4. 候选方案 B（**原字体 + CGContext 统一 scale**）在每个字号 raster 都 ≤0.5pt @ cellW，
   是当前最安全 remediation。
5. Phase 9 FINAL PASS 仍 **BLOCKED**。

---

## 1. branch

`feature/macssh-1.1-terminal-font-size` @ MacSSH HEAD = `c6bf66c2b985530e6687fefe62cdf08246190e41`，
working tree 保留 Phase 9B + Phase 9D-C integration（pbxproj/Package.resolved pin → `93abf601...`），
**0 production .swift 改动**（本调查为 read-only + /tmp probe，已 `git status` 复核）。

## 2. SwiftTerm SHA

Fork HEAD = `93abf601469e572faffed65f75d548c58afa3058`（`git log` 第 1 行），
parent = `771e79f092a26e7fba7af0ab2b09a2bf10213109`（direct child，`merge-base = 771e79f`）。
Working tree clean（`git status` 空）。

## 3. MacSSH pin

`pbxproj:948` `revision = 93abf601469e572faffed65f75d548c58afa3058`（kind=revision）。
`Package.resolved:18` `"revision" : "93abf601..."`（remoteSourceControl / GitHub location）。
pbxproj + Package.resolved + 9D-C build log 三重确认 = 93abf601。
`DependencyIdentityTests.testPhase9DPatchParentIsPhase7Patch` PASS（9D-C 阶段）。

## 4. GUI failure（用户原始报告）

```
A⚠️B❤️C
|⚠️|❤️|⚠️|❤️|
```
字号 14/24/32（外加 10/18 实证），大字号下 ⚠️/❤️ 仍侵入相邻 logical cell。
用户截图已证明实际 GUI failure。

## 5. reproduction

**完全复现**。/tmp standalone probe（SwiftTerm 93abf601 working tree 作本地 SPM 依赖，
JetBrains Mono + PingFang SC + Apple Color Emoji cascade 与 `TerminalFontProvider` 同源，
`variationSelector16WidthPolicy = .preserveBaseWidth`，同一 `TerminalView` 类、同一字体、同一
bytes）将 `TerminalView.draw(view.bounds)` 直接渲染到 bitmap / PNG（`renderContent` →
`NSGraphicsContext(cgContext:flipped:false)` + `view.draw(view.bounds)` → 真实
`drawTerminalContents` CG 路径）。最终像素出现与 GUI 截图相同的 intrusion：
24pt ink 17.5pt in cell 14.5pt（+3pt 右溢出），32pt ink 21pt in cell 19pt（+2.5pt）。
详见 §12–§19 与 `generated-images/phase9dc-c/real-*-grid.png`。

## 6. actual renderer used

**CoreGraphics (CG) path**。证据链：
- MacSSH 源码全仓搜 `setUseMetal|useMetal|Metal` 仅 2 处注释
  （`TerminalAppearanceProvider.swift:132` + `TerminalScrollIndicatorController.swift:62`），
  **0 次 `setUseMetal(true)` 调用**。
- SwiftTerm fork 默认值：`MacTerminalView.swift:233` `private var useMetalRenderer = false`。
- Probe runtime 断言：每个 view `view.isUsingMetalRenderer == false`
  （`results.jsonl` `event=view` 全 13 条记录）。

## 7. CG result（实测）

真实 renderer bitmap 像素（isolated emoji full-ink bbox，含黑色描边与 AA，backing 2x）。
**侵入方向判定**（2026-09-05 勘误）：`leftOv = minXpt - cellLeftPt`——**正值 = 左侧 margin，负值才是左侵**；
`rightOv = maxXpt - cellRightPt`——正值 = 右侵。据此复核全部数据：**所有侵入均为右侧单向**
（dx≈0 → ink 从 cell 左缘出发，过大 ink 向右溢出，与 GUI 截图 emoji 压右侧邻居一致）。

| size | cellW | ⚠️ inkW | ⚠️ 左侵 | ⚠️ 右侵 | ❤️ inkW | ❤️ 左侵 | ❤️ 右侵 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 | 6.0 | 5.5 | 0 | 0 | 5.5 | 0 | 0 |
| 14 | 8.5 | 8.0 | 0 | 0 | 8.0 | 0 | 0 |
| 18 | 11.0 | 11.5 | 0 | **+0.5** | 10.5 | 0 | 0 |
| 24 | 14.5 | **17.5** | 0 | **+3.0** | **17.5** | 0 | **+3.0** |
| 32 | 19.0 | **21.0** | 0 | **+2.5** | **20.0** | 0 | **+2.0** |

- 10/14pt：**contained**（0.5pt margin）——14pt 用户感知"较轻"即此。
- 18pt：⚠️ 右侵 +0.5pt，正好 @ gate；❤️ contained。
- 24pt：**FAIL**（右侵 +3.0pt，最严重 absolute）。
- 32pt：**FAIL**（右侵 +2.0 ~ +2.5pt）。
- （原始测量值 minXpt 相对 cellLeft 均 ≥ -0.0，即左侧从未越过 cell 左缘。）

## 8. Metal result（代码级分析，未实测）

`MetalTerminalRenderer.swift` glyph loop（`:1284-1358`）：

```swift
let scaledFont = scaledFontFor(font: glyphRun.font, scale: scale)  // scale = backingScale (2x)
let entry = glyphEntry(for: scaledFont, glyph: glyph)              // rasterize @ backing-scaled 原字体 → atlas
...
let pxX = basePos.x * scale + entry.bearing.x * fit.scale
let pxY = basePos.y * scale + entry.bearing.y * fit.scale
let x1 = pxX + entry.size.width * fit.scale
```

`fit.scale` **仅作用于 atlas quad 几何**；atlas 中的 glyph bitmap 是 **backing-scaled 原字体**
rasterize（`scaledFontFor` 只乘 backingScale，不乘 fit.scale）。数学上等价于方案 B
（原字体 + transform）——**预期 contained，不会复现 CG bug**。

未做 Metal 实测（MacSSH 不启用 Metal；MTKView 离屏渲染超出本阶段必要性——CG 是 MacSSH 实际
路径，已实测 FAIL）。如未来启用 Metal，需独立 GUI acceptance。

## 9. Retina scale

主用 2x（`NSScreen.main.backingScaleFactor = 2`）。附加 1x 跑 14/24/32。
bug **不是** Retina-specific：

| size | backing | cellW | inkW | overflow |
|---:|---:|---:|---:|---:|
| 14 | 1x | 8.0 | 8.0 | -1.0pt ✓ |
| 14 | 2x | 8.5 | 8.0 | -0.5pt ✓ |
| 24 | 1x | 14.0 | 17.0 | **+3.0pt ✗** |
| 24 | 2x | 14.5 | 17.5 | **+3.0pt ✗** |
| 32 | 1x | 19.0 | 20.0 | **+2.0pt ✗** |
| 32 | 2x | 19.0 | 21.0 | **+2.5pt ✗** |

## 10. computed fit（`AppleTerminalView.swift:539-585`）

```
slotWidth = columnWidth × cellWidth   (columnWidth = 1)
advance  = CTFontGetAdvancesForGlyphs(ACE@S)
ink      = CTFontGetBoundingRectsForGlyphs(ACE@S)
scale    = max(0.1, min(min(slotW/ink.w, cellH/ink.h), 1))
dx       = (slotW - advance × scale) / 2
dy       = (cellH/2 - baselineFromBottom) - (ink.origin.y + ink.h/2) × scale
```

draw path（`:2223-2253`）：

```swift
glyphPositions[i].x += fit.dx; glyphPositions[i].y += fit.dy
drawFont = CTFontCreateCopyWithAttributes(ctRunFont, S × fit.scale, nil, nil)
CTFontDrawGlyphs(drawFont, &g, &p, 1, ctx)
```

**核心假设（错误的）**：`ink(S × scale) = ink(S) × scale`（declared bounds 随 point size 线性）。
对纯矢量字体成立；对 Apple Color Emoji（sbix bitmap）不成立——见 §14/§22/§23。

## 11. final draw position

| emoji | size | cellW | fit.dx | fit.dy | fit.scale | p.x (cellCol 1) | drawFont size |
|---|---:|---:|---:|---:|---:|---:|---:|
| ⚠️ | 14 | 8.5 | -0.36 | 1.95 | 0.486 | 8.14 | 6.8 |
| ⚠️ | 24 | 14.5 | -0.30 | 2.56 | 0.604 | 14.20 | 14.5 |
| ⚠️ | 32 | 19.0 | 0.00 | 4.37 | 0.594 | 19.00 | 19.0 |
| ❤️ | 14 | 8.5 | -0.36 | 1.95 | 0.486 | 8.14 | 6.8 |
| ❤️ | 24 | 14.5 | -0.30 | 2.56 | 0.604 | 14.20 | 14.5 |
| ❤️ | 32 | 19.0 | 0.00 | 4.37 | 0.594 | 19.00 | 19.0 |

dx/dy/scale 由 `computeGlyphFit` 推导、`glyphSlotFit` 缓存（`:2231-2237`），经
`glyphPositions[i] += dx/dy`（`:2233-2234`）与 `CTFontCreateCopyWithAttributes(S×scale)`
（`:2247`）直接进入 `CTFontDrawGlyphs`（`:2250`）。**无二次收敛**（无 re-rasterize 校验），
fit 值确实进入最终 draw call（像素结果直接证实——非仅 helper 返回）。

## 12. theoretical glyph bounds

`CTFontGetBoundingRectsForGlyphs`（backing 2x 几何）：

| size | emoji | advance | inkW | inkH | ink origin | ink/size ratio |
|---:|:---|---:|---:|---:|---|---:|
| 10 | ⚠️/❤️ | 13 | 12.5 | 12.5 | (0.2875, -2.5) | **1.250** |
| 14 | ⚠️/❤️ | 19 | 17.5 | 17.5 | (0.4025, -3.5) | **1.250** |
| 18 | ⚠️/❤️ | 22 | 21.0 | 21.0 | (0.42, -3.75) | **1.167** |
| 24 | ⚠️/❤️ | 25 | 24.0001 | 24.0001 | (0.252, -3.0) | **1.000** |
| 32 | ⚠️/❤️ | 32 | 32.0001 | 32.0001 | (0.0, -4.0) | **1.000** |

⚠️ 与 ❤️ declared metrics 在所有字号**完全相同**（ACE 中为同形 glyph）。

## 13. CTRun image bounds

`CTRunGetImageBounds(run, ctx, range)`（真实 bitmap ctx，backing 2x）：

| size | emoji | CTRun imageBounds | vs CTFont ink |
|---:|:---|---|---|
| 10 | ⚠️/❤️ | (0.2875, -2.5, 12.5, 12.5) | **逐分量相等** |
| 14 | ⚠️/❤️ | (0.4025, -3.5, 17.5, 17.5) | **逐分量相等** |
| 18 | ⚠️/❤️ | (0.42, -3.75, 21.0, 21.0) | **逐分量相等** |
| 24 | ⚠️/❤️ | (0.252, -3.0, 24.0001, 24.0001) | **逐分量相等** |
| 32 | ⚠️/❤️ | (0.0, -4.0, 32.0001, 32.0001) | **逐分量相等** |

**关键负结果**：对 Apple Color Emoji，`CTRunGetImageBounds == CTFontGetBoundingRectsForGlyphs`
（byte-for-byte）。CTRun image bounds 不携带额外 ground truth——
**remediation family A（用 image bounds 替 theoretical bounds）无效**。

## 14. actual pixel bounds（三方对比：declared / image / raster）

Glyph-level（单 glyph 独立 rasterize 到 bitmap，chromatic bbox 测量，backing 2x）：

| size | emoji | theory ink (orig) | CTRun image | raster @ orig | **raster @ A (copy S×scale)** | **raster @ B (ctx transform)** | predicted (ink × scale) |
|---:|:---|---:|---:|---:|---:|---:|---:|
| 10 | ⚠️ | 12.5 | 12.5 | 12.0 | 5.5 | 5.5 | 6.0 |
| 10 | ❤️ | 12.5 | 12.5 | 11.0 | 5.5 | 5.5 | 6.0 |
| 14 | ⚠️ | 17.5 | 17.5 | 17.0 | 8.0 | 8.0 | 8.5 |
| 14 | ❤️ | 17.5 | 17.5 | 17.0 | 8.0 | 8.0 | 8.5 |
| 18 | ⚠️ | 21.0 | 21.0 | 20.5 | 11.5 | 10.5 | 11.0 |
| 18 | ❤️ | 21.0 | 21.0 | 19.5 | 10.5 | 9.5 | 11.0 |
| 24 | ⚠️ | 24.0 | 24.0 | 23.5 | **17.5** | 14.0 | 14.5 |
| 24 | ❤️ | 24.0 | 24.0 | 22.5 | **17.5** | 14.0 | 14.5 |
| 32 | ⚠️ | 32.0 | 32.0 | 31.5 | **21.0** | 18.5 | 19.0 |
| 32 | ❤️ | 32.0 | 32.0 | 29.5 | **20.0** | 18.5 | 19.0 |

- declared vs CTRun image：恒等（§13）。
- declared vs raster @ orig：Δ ≈ 0.5pt（AA threshold）——**同字号下 CoreText 诚实**。
- **raster @ A ≈ copy 自身 declared ink（18.125/21.5），≠ predicted（14.5/19.0）——bug 所在。**
- raster @ B ≈ predicted（Δ ≤ 0.5pt）——transform 保持线性。

完整视图测量见 §7。

## 15. ⚠️ data

⚠️（U+26A0 + U+FE0F，VS16 preserve → width 1）：
- run count：CTLine 单一 run，1 glyph（VS16 被 shaping 吸收）。
- resolved font：`AppleColorEmoji`（PostScript name，`results.jsonl` 每条 glyph event 均记录）。
- theoretical bounds / CTRun image bounds / actual pixel bounds：§12–§14。
- full-view 像素（§7）：14pt 收于 cell；24pt 右侵 +3.0pt；32pt 右侵 +2.5pt（左侧为 margin，非侵入）。
- 高度方向：isolated inkH 16.0 @24pt / 19.0 @32pt vs cellH 32/43——**垂直始终 contained**，
  overflow 只在水平右侧。

## 16. ❤️ data

❤️（U+2764 + U+FE0F）：与 ⚠️ declared metrics 逐分量相同（§12），行为几乎相同：
- full-view（§7）：24pt 右侵 +3.0pt（同 ⚠️）；32pt 右侵 +2.0pt（左侧为 +1.0pt margin，非侵入）。
- 32pt ❤️ 左侧 margin 比 ⚠️ 大 ~0.5pt：glyph-level raster @ A 显示 ❤️ ink 左端相对原点
  比 ⚠️ 偏右 ~0.5pt（rasterAMinX 151 vs 150.5 @32pt 2x），与 declared inkX 差异无关
  （两者 inkX 均 0.4085 @copy）——属 bitmap 具体像素分布差异，且为 margin 方向，无侵入含义。
- 总体 fail 模式与 ⚠️ 相同：copy strike declared ink > predicted。

## 17. 14pt data

- cellW 8.5 @2x / 8.0 @1x；theory ink 17.5；fitScale 0.486；copy size 6.8；**copy ink 8.5（ratio 1.25）**。
- original ratio 1.25 == copy ratio 1.25——线性假设**意外成立**（同 strike 段）。
- raster @ A = 8.0 vs predicted 8.5 → full-view 收于 cell（§7：-0.5pt margin）。
- 1x：cell 8.0，raster 8.0 → 0 overflow ✓。
- **用户感知"较轻"= 实际 contained**。GUI 若仍显示 14pt 溢出，需查 §附录 C 差异清单
  （大概率非 ACE 路径或旧 binary）。

## 18. 24pt data

- cellW 14.5 @2x / 14.0 @1x；theory ink 24.0001；fitScale 0.604；copy size 14.5；
  **copy ink 18.125（ratio 1.25）**。
- original ratio 1.000 → copy ratio 1.250（+0.25 跳升）。
- raster @ A = 17.5 vs predicted 14.5 → full-view 右溢出 **+3.0pt**（1x 同样 +3.0pt）。
- **本调查中最严重的 absolute overflow**（normalized 20.7% 同为最高，见 §22 尾注）。

## 19. 32pt data

- cellW 19.0；theory ink 32.0001；fitScale 0.594；copy size 19.0；**copy ink 21.5（ratio 1.132）**。
- original ratio 1.000 → copy ratio 1.132（+0.132 跳升）。
- raster @ A = 21.0 vs predicted 19.0 → full-view 右侵 +2.5pt（⚠️）/ +2.0pt（❤️），左侧均为 margin。
- normalized ratio 13.2%（低于 24pt 的 20.7%），但 absolute 像素量大——用户感知"明显"。

## 20. cursor/no-cursor comparison

- **No-cursor**：feed `\u{1b}[?25l` 隐藏 caret，`view.draw(view.bounds)` 仅画 terminal content。
- **Cursor-afterC**：feed `A⚠️B❤️C`，cursor 停 col 5：`caretFrame (5×cellW, rowY, cellW, cellH)`
  ——14pt `(42.5,95,8.5,19)` ✓；24pt `(72.5,160,14.5,32)` ✓；32pt `(95,215,19,43)` ✓
  （= `AppleTerminalView.swift:2618` `cellW × caretCol`，精确零容差）。
- **Cursor-onSeparator**：feed s1+s2 + CSI `2;3H`，cursor 停 row 1 col 2（`|`）：
  14pt `(17,76,8.5,19)` ✓；24pt `(29,128,14.5,32)` ✓；32pt `(38,172,19,43)` ✓。
- caret 与 emoji ink 是 **additive**（caret 后绘制于越界 ink 之上）：cursor block 覆盖 separator
  与 emoji ink 覆盖 separator 可经 caretFrame（精确对齐 logical cell）区分——
  caret 永远格点精确，emoji ink 偏移由 fit math 决定，**二者独立**。
- Probe cursor PNG composite 有 y-flip 伪影（caretView.draw 副作用，probe 工具限制，**非生产问题**），
  cursor PNG 不附报告；no-cursor render 路径完全可靠，作为主证据。

## 21. standalone vs MacSSH comparison

| 来源 | 14pt | 18pt | 24pt | 32pt | 现象 |
|---|---|---|---|---|---|
| MacSSH GUI 用户截图 | 较轻 | — | — | 明显 | ⚠️/❤️ 越界 |
| standalone probe（real renderer） | -0.5pt margin | +0.5pt @ gate | +3.0pt | +2.5pt | **完全复现** |

standalone 环境 = MacSSH 渲染配置的子集（同 SwiftTerm SHA、同字体栈、同 policy、同 CG path、
同 2x backing）。**GUI parity 通过**：GUI failure 根因在 shared renderer code，
非 GUI 专属环境差异。

## 22. root cause of test-vs-GUI mismatch

```
Phase 9D-B OneCellGlyphFitTests:
  断言 fit.scale/dx/dy 与 theoretical bounds（原字号）一致
  → ✅ 全部通过（数学正确预测 theoretical_ink(at_original_size) × scale）

Phase 9D-C real renderer:
  drawFont = CTFontCreateCopyWithAttributes(ctRunFont, original_size × scale)
  → CTFont 为 Apple Color Emoji RE-CHOOSES sbix bitmap strike
  → new strike 的 declared ink/size ratio ≠ original strike 的 ratio
     （实测：original 10/14/18/24/32pt ratio = 1.250/1.250/1.167/1.000/1.000；
            copy    4.8/6.8/9.43/14.5/19pt ratio = 1.250/1.250/1.250/1.250/1.132）
  → 当 copy_ratio > original_ratio（18/24/32pt 全部如此），
    raster ink = copy_ink ≈ copy_size × copy_ratio
              > original_ink × scale = predicted ink = cellW
  → OVERFLOW（24pt +3.0pt 为峰）
```

**机制**：ACE（`/System/Library/Fonts/Apple Color Emoji.ttc`，sbix bitmap）每个 strike 的
ink extents 与 strike pt 的 ratio 分段常数；`CTFontGetBoundingRectsForGlyphs` 按选中 strike
归一化。`CTFontCreateCopyWithAttributes` 换到新 strike 时 ratio 重置——
**declared bounds 与 point size 不成线性**。

**测试 vs GUI**：单元测试断言的数学对象（原字号 theoretical bounds × scale）≠ CoreText 绘制
raster 的物理对象（新 strike bitmap ink）。helper bounds 无法暴露此差异——
**只有真实 raster 像素可作为最终 gate**（task §22 要求）。

补充——overflow 随字号的变化（task §19）：

| size | overflow (pt) | normalized (÷cellW) | absolute (px @2x) |
|---:|---:|---:|---:|
| 18 | +0.5 | 4.5% | +2 |
| 24 | **+3.0** | **20.7%** | **+12** |
| 32 | +2.5 | 13.2% | +10 |

24pt 在 absolute 与 normalized 双维度最严重；32pt normalized 较低但 absolute 仍大——
两者用户都识别为"明显"，14pt 完全 contained（"较轻"）。

## 23. CTFont resize experiment（task §9 直接回应）

`CTFontCreateCopyWithAttributes(ACE@S, S×scale)` **不会**让最终 color glyph bitmap 按与理论
CTFont bounds 一致的比例缩放：

| size | orig ratio | copy size | copy ink | copy ratio | copy raster | predicted | Δ |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 | 1.250 | 4.8 | 6.0 | 1.250 | 5.5 | 6.0 | -0.5 |
| 14 | 1.250 | 6.8 | 8.5 | 1.250 | 8.0 | 8.5 | -0.5 |
| 18 | 1.167 | 9.43 | 11.786 | 1.250 | 11.5 | 11.0 | +0.5 |
| 24 | **1.000** | 14.5 | 18.125 | **1.250** | **17.5** | 14.5 | **+3.0** |
| 32 | **1.000** | 19.0 | 21.5 | **1.132** | **21.0** | 19.0 | **+2.0** |

→ **重要根因确认**：pointSize 变化对 Apple Color Emoji 不按理论线性缩放；
10/14pt 的"正确"只是 original 与 copy 碰巧同段 strike ratio（1.25）的巧合。

## 24. CGContext transform experiment（task §10 方案 B）

```
ctx.saveGState()
ctx.translateBy(x: originX, y: baseline + fit.dy)
ctx.scaleBy(x: fit.scale, y: fit.scale)
CTFontDrawGlyphs(original_font, &glyph, &zero, 1, ctx)
ctx.restoreGState()
```

不创建 copy CTFont——保留**原字号 strike**；缩放在 CTM。结果（§14 raster @ B 列）：

| size | predicted | raster @ B | margin |
|---:|---:|---:|---|
| 10 | 6.0 | 5.5 | ✓ |
| 14 | 8.5 | 8.0 | ✓ |
| 18 | 11.0 | 10.5 | ✓ |
| 24 | 14.5 | 14.0 | ✓ |
| 32 | 19.0 | 18.5 | ✓ |

**所有字号 ≤0.5pt @ cellW**。视觉对比：`generated-images/phase9dc-c/strategy-*.png`——
上行（B）⚠️/❤️ 始终收于红色 emoji cell 内；下行（A，production）明显越界。

## 25. pixel snapping

- cellW snap 于 backing scale（`AppleTerminalView.swift:467-471`）：
  14pt @2x = 8.5（"W" adv 8.4375 → (8.4375×2).round/2）；@1x = 8.0。
- fit dx @24pt = -0.30pt → 0.6 device px @2x（sub-pixel）。
- **snapping 不是根因**：主溢出 +3.0pt 是 6× gate（0.5pt）的 ink mismatch；
  若 fit 正确，±0.5pt snapping tolerance 结构正确。
- dx/dy 是否需 pixel-aligned snapping：B 方案 raster ≤0.5pt margin 证明当前 fractional
  positioning 在 2x 下不产生额外超标 overhang——**无需** 追加 pixel-snap 修正（可作 P3 打磨）。

## 26. safest remediation

**方案 B（原字体 + CGContext uniform affine transform）**：
- raster ≤0.5pt @ cellW 全字号（§24 实测）。
- 与 Metal path 数学同构（§8/§31）——修复后 CG/Metal 行为收敛。
- 不动 `computeGlyphFit` / `glyphFitCache` / `isBaseFont` / Metal / model / policy。
- 风险最小：仅替换 `:2240-2254` scaledFits 绘制分支。

备选：
- **A（CTRun image bounds）**：**排除**——§13 证明 image bounds ≡ theoretical bounds（ACE），无新信息。
- **C（pixel-space post-fit correction）**：有效但需 rasterize-then-measure 二次收敛，
  draw-time 成本高、缓存语义复杂（方案 D 即其缓存化变体）——不如 B 直接。
- **D（基于 actual raster bounds 的二次收敛 cache）**：可作 B 的后续打磨（先 B 修正确性，
  D 仅优化视觉 margin），不宜作为首选（引入测量路径依赖）。

## 27. preserveBaseWidth invariant

`LocalTerminalService.swift:38` `.preserveBaseWidth` **未改**；`TerminalOptions.swift:64-87`、
`Terminal.swift:1494-1530` preserve 分支**未改**；⚠️/❤️ logical width = 1 **未改**。
本调查全程 read-only + /tmp probe；方案 B 仅 presentation 层（CG draw）。

## 28. cursor invariant

`AppleTerminalView.swift:2618` caret x = `cellW × caretCol` **未改、精确零容差**。
probe 实测 caretFrame 全部分量 == cellW × col（§20）。方案 B 不触碰 caret 路径
（`:2474-2515` / `updateCursorPosition`）。

## 29. PTY invariant

PTY bytes / `LocalProcess` / `LocalShellLauncher` / zsh 行为 **未改、未触碰**。
probe 经 `Terminal.feed(text:)` 注入字节（与 PTY 输出等价路径），不涉及子进程。

## 30. Phase5 risk

Phase 5 = VS16 preserveBaseWidth policy。**风险 = 零**：
- 本次调查 0 production/SwiftTerm 修改。
- 方案 B 只改 CG draw path 字形绘制（`:2223-2254`），不触碰 policy 定义、
  `Terminal.swift` VS16 处理、`buildAttributedString` 分段、logical cell width 语义。
- Phase 5 13 项测试（`TerminalVS16WidthPolicyTests`）全部断言 model 层
  （cell width / buffer.x / paste bytes / CJK / non-VS16 emoji），不依赖 renderer——
  renderer-only 修复不可能影响它们。
- 唯一交互点：`columnWidth == 1 && !isBaseFont` gate——由 policy 输出决定，与 policy 本身正交。

## 31. CG/Metal implications

- **CG（当前 MacSSH 路径）**：bug 生效（§7）。
- **Metal（未启用）**：`fit.scale` 只缩 quad，glyph rasterize 于 backing-scaled 原字体
  （§8）——数学同方案 B，**预期 contained**。
- **修复后 CG/Metal 收敛**：CG 改为 transform 后，两路径都是 "原 strike + 变换缩放"，
  Phase 9D-B 设计的 "CG/Metal shared single source（`glyphSlotFit`）" 语义恢复真正一致。
- 若未来启用 Metal：仍需独立 GUI acceptance（quad 缩放的 AA 质量与 CG 不同，需视觉验收）。

## 32. cache implications

`glyphFitCache`（file-level，key = fontID/glyph/columnWidth/cellW/cellH，limit 1024，
main-thread-only）：方案 B **cache 语义不变**——输入仍是 (font, glyph, cell)，输出仍是
(scale, dx, dy)；绘制方式从 copy-font 改 CTM scale 不影响 cache key/value。
`cgColorCache` / `fallbackFontCache` / Metal `glyphCache` / `scaledFontCache` 均不受影响。
cache 若未来采用方案 D（raster-bounds 二次收敛）才需扩展 value——本阶段不推荐。

## 33. future pixel-level tests

**当前 `OneCellGlyphFitTests` 仅断言 fit math 输出（theoretical），不断言 raster
containment**——这正是 test-vs-GUI gap 的制度性根因。

建议新增 `RasterContainmentTests`（任务 §22 gate）：

```swift
@Test @MainActor func rasterContainment() async throws {
    // 真实 TerminalView（无 Metal）+ 真实 cascade 字体 + preserveBaseWidth
    // 渲染到 NSBitmapImageRep @2x，测 chromatic emoji ink bbox vs logical cell rect
    // 14/24/32pt × A⚠️B❤️C / |⚠️|❤️|⚠️|❤️| × {no-cursor, cursor}
    // 断言：leftOverflow ≤ 0.5pt && rightOverflow ≤ 0.5pt（以最终 bitmap 为准）
}
```

- 12 core 用例 + cursor 变体 + ASCII/Bold/Italic/CJK control ≈ 30 测试，< 5s（headless AppKit）。
- **未来 fix 不再以 helper fit bounds 作为最终 gate**——helper 只作 fast predicate；
  raster bitmap 为 hard gate。

## 34. P1

**P1（1 项）**：真实像素下 24pt/32pt ⚠️/❤️ 仍侵入相邻 logical cell（+2 ~ +3.0pt），
违反 Phase 9D-B acceptance 的 ink-containment gate（≤0.5pt@2x）。
根因：`CTFontCreateCopyWithAttributes` 重选 ACE sbix strike，declared ink 非线性缩放，
`computeGlyphFit` 线性预测系统性低估（0.083 ~ 0.25 ratio 差）。
**自动化 0 P1/0 P2 成立（对 helper bounds 而言）但 GUI FAIL 成立（对真实像素而言）——
P1 在真实像素 gate 下未解决。**

## 35. P2

**0 项新增 P2**（CG/Metal 同源语义因 Metal 本已正确而自动满足，见 §31）。

## 36. P3

- 18pt 恰 @ gate（+0.5pt）——方案 B 提供 < 0.25pt margin 后自然消除。
- probe cursor PNG composite y-flip 伪影——**probe 工具限制，非生产问题**；
  no-cursor render 路径完全可靠（orientation selftest 通过）。
- ❤️ 32pt 左侧 +1.0pt 属 bitmap 像素分布细节，方案 B 下按 declared 线性缩放，
  预计 ≤0.5pt（glyph-level rasterBMinX=150 vs ⚠️ 150.5 已验证同源收敛）。

## 37. recommended next step

1. 用户授权后开启 **Phase 9D-D remediation**（SwiftTerm fork 新 candidate）：
   - 修改 CG scaledFits 分支（`:2240-2254`）：删除 `CTFontCreateCopyWithAttributes(S×scale)`，
     改为 saveGState + translate + scale + draw 原字体 + restore。
   - Metal / computeGlyphFit / cache / isBaseFont **不变**。
2. 新增 `RasterContainmentTests`（§33）作为 future hard gate。
3. 重跑 `OneCellGlyphFitTests`（预期继续 PASS，math 不变）+ `GlyphFitCacheTests` +
   `RasterContainmentTests`（必须 PASS）+ Phase 2/5/6/7/8/9B 回归。
4. Independent Fork Re-Acceptance（新 candidate）→ MacSSH pin 推进 → GUI Re-Acceptance
   （17 项 checklist + 24pt 新增用例）。
5. 本阶段未获授权前：不实现 fix / 不 commit / 不 merge / 不 push / 不推进 pin。

## 38. whether Phase 9 remains blocked

**YES — Phase 9 FINAL PASS remains BLOCKED**：
- 自动化 validation PASS（对 helper bounds）但真实像素 gate FAIL（P1 未解决）。
- GUI 验收 FAIL（用户截图 + standalone 像素复现）。
- 任务 §3/§23 明确要求不得宣告 Phase 9 FINAL PASS。

## 39. final status

**PHASE 9D-C INVESTIGATION COMPLETE**。

根因已锁定：Apple Color Emoji sbix strike 在不同 point size 下的 declared ink/size ratio
分段不连续（1.250 / 1.250 / 1.167 / 1.000 / 1.000 vs copy 恒 1.250/1.132），
`computeGlyphFit` 的线性缩放预测系统性低估实际 raster ink（24pt 峰 +3.0pt）。
方案 B（原字体 + CGContext transform）作为 safest remediation 已实证
（10/14/18/24/32pt raster 全部 ≤0.5pt margin）；方案 A 被三方对比排除。

未实现 production fix；未修改 SwiftTerm fork / MacSSH production code；
未 commit / merge / push；未推进 pin；未开始下一 Phase；未宣告 Phase 9 FINAL PASS。

**STOP**，等用户授权 Phase 9D-D remediation。

---

## 附录 A：probe 工件

- `/tmp/macssh_phase9dc_probe/`（独立 SPM，依赖本地 SwiftTerm-fork working tree = 93abf601）
- `/tmp/macssh_phase9dc_probe/out/results.jsonl`（120+ 行 JSONL，全部原始测量）
- `/tmp/macssh_phase9dc_probe/out/real-*-grid.png`（真实 renderer + grid overlay）
- `/tmp/macssh_phase9dc_probe/out/strategy-*.png`（方案 A vs B 对比）
- orientation selftest 通过（context 坐标系验证，results.jsonl 含 env 记录：
  macOS 27.0 Build 26A5425a，mainScreenScale 2，ACE = `/System/Library/Fonts/Apple Color Emoji.ttc`）

## 附录 B：可视化产物（workspace）

`generated-images/phase9dc-c/`：
- `real-14pt-1x-grid.png` / `real-14pt-2x-grid.png`（contained）
- `real-18pt-2x-grid.png`（gate 边界）
- `real-24pt-1x-grid.png` / `real-24pt-2x-grid.png`（右侵 +3.0pt）
- `real-32pt-1x-grid.png` / `real-32pt-2x-grid.png`（右侵 +2 ~ +2.5pt）
- `strategy-14pt-2x.png`（A/B 均 contained）
- `strategy-24pt-2x.png` / `strategy-32pt-2x.png`（B contained，A 越界）

**PNG 方向勘误（2026-09-05）**：probe 早期版本的 PNG 白底合成步骤多了一次垂直翻转
（CGContextDrawImage 方向处理错误），导致此前生成的 `real-*` / `strategy-*` PNG 上下颠倒
（s1 行显示在底部、字母倒悬）。**水平方向的全部测量与溢出证据不受影响**
（测量均来自 `results.jsonl` 的像素坐标，非 PNG 视觉；侵入方向为右侧单向——见 §7 勘误）。
已于 Phase 9D-D 期间用 `sips -f vertical` 将本目录全部 PNG 翻正（确定性像素操作，
与修正后的合成路径输出一致），并修正 probe 合成代码。strategy PNG 翻正后：
**上行 = 方案 B（contained），下行 = 方案 A / production（越界）**，与 §24 描述一致。

## 附录 C：若未来 GUI FAIL 而 standalone PASS 的排查清单

（本阶段 standalone 已复现 GUI，无需启用；留存备用）
1. 运行中 binary 是否真链接 93abf601（lldb 符号断点 `glyphSlotFit`）。
2. Metal 是否被意外启用（`isUsingMetalRenderer` / `MTLDevice` 分配）。
3. 运行环境 backing scale（外接 1x 显示器窗口）。
4. app 缓存旧 binary。
5. ACE 解析失败 → cascade 落到 PingFang SC monochrome（完全不同的字形/ink）。
