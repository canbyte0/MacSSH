# MacSSH 1.1 Phase 9C — VS16 / Emoji Large Font Rendering Investigation

> 调查日期：2026-09-05（Asia/Shanghai）
>
> 环境：macOS 27.0（26A5425a）、arm64、Xcode 27.0（27A5252f）
>
> 范围：只读 production / resolved SwiftTerm 源码、现有测试、`/tmp` CoreText 与真实 `TerminalView` probe。
>
> **未修改 production code、SwiftTerm fork、TerminalFontSizeController、Package.resolved 或工程配置；未 commit / merge / push。**

## 结论先行

根因已证实：Local Terminal 的 `preserveBaseWidth` 正确地把 `⚠️` / `❤️` 保持为 **1 个逻辑 cell**，但 CoreText 将它们塑形成 **1 个 Apple Color Emoji glyph**，其自然 advance 与可见 ink 宽度约为 **1.58–2.24 个 JetBrains Mono cell**。SwiftTerm 虽然把后续字符与 cursor 严格放回固定 cell grid，却只对 `columnWidth >= 2` 的 glyph 执行 `glyphSlotFit`；1-cell VS16 glyph 因此按原尺寸绘制并覆盖后续 cell。

这不是 Phase 9B 新引入的 model/cursor regression。Phase 9B 让用户可选择 24/32 pt，放大了 Phase 5 以来已有的 presentation limitation。归一化宽度没有随字号持续增长，整体反而下降；用户感受到的大字号恶化主要来自绝对 overhang 从约 6.5–7 pt 增至 12–13 pt，并叠加 Apple Color Emoji 非严格线性的字号/strike 行为。

唯一建议：**选择 Phase 9B 关系方案 C——当前阻塞 FINAL PASS，先单独授权一个窄范围、presentation-only 的 SwiftTerm renderer remediation；不要改变 `preserveBaseWidth`。** 最安全方向是将现有 glyph-fit 机制扩展到“逻辑宽度为 1、实际 Apple Color Emoji ink 超出 slot 的 VS16 glyph”，按 logical cell fit、保持纵横比并居中。本文不实现该修复。

---

## 1–7. Repository 与 Phase 5 基线

### 1. branch

`feature/macssh-1.1-terminal-font-size`

### 2. HEAD

`c6bf66c2b985530e6687fefe62cdf08246190e41`

### 3. working tree before investigation

调查前已有 Phase 9B 未提交内容，完整保留：

- modified：`MacSSH.xcodeproj/project.pbxproj`、`MacSSH/App/AppLanguage.swift`、`MacSSH/App/AppState.swift`、`MacSSH/Features/Settings/SettingsView.swift`、`MacSSH/Resources/Localizable.xcstrings`、`MacSSH/Services/Terminal/SessionManager.swift`、`Scripts/gen_localizable.py`
- untracked：Phase 9A/9B reports、`MacSSH/App/TerminalFontSizeController.swift`、两份 font-size tests、`generated-images/`
- `git diff --check`：无输出。
- 初始 tracked diff stat：7 files changed，4773 insertions，4079 deletions。

### 4. production modifications

Phase 9C 对 production 的修改数：**0**。仓库唯一新增文件是本调查报告；所有 probe、binary、PNG、profraw 与 module cache 均在 `/tmp/macssh_phase9c_probe/`。

### 5. SwiftTerm SHA

三方一致：

- `Package.resolved`：`https://github.com/canbyte0/SwiftTerm.git` @ `771e79f092a26e7fba7af0ab2b09a2bf10213109`
- `ThirdParty/MANIFEST.txt`：同一 production revision
- 本轮 `xcodebuild` resolve：`SwiftTerm @ 771e79f`
- 实际 production checkout：`/private/tmp/MacSSH-P9B-ACC-DD/SourcePackages/checkouts/SwiftTerm`，HEAD 同为 `771e79f...`

备注：用户目录中另有一个旧 DerivedData checkout 停在 Phase 5 SHA `8a5187f...`，只是陈旧缓存；本调查的源码、link module、测试与结论均以 production `771e79f...` checkout 为准。

### 6. Phase 5 policy

`VariationSelector16WidthPolicy` 定义于 resolved SwiftTerm `Sources/SwiftTerm/TerminalOptions.swift:64-87`：

- `.widenToEmojiWidth`：历史默认，把窄 base + VS16 扩至 2 cells。
- `.preserveBaseWidth`：保留 base 原宽，VS16 仍留在 grapheme cluster。

MacSSH Local 在 `MacSSH/Services/Terminal/LocalTerminalService.swift:25-43` 显式使用 `.preserveBaseWidth`；Remote 保持 SwiftTerm 默认 `.widenToEmojiWidth`。

### 7. preserveBaseWidth semantics

resolved SwiftTerm `Terminal.swift:1494-1530` 实证：组合成功后，VS16 仍存入 `newCh`；preserve 分支用 `oldSize` 更新 `CharData`，不添加 width-0 continuation，也不额外移动 `buffer.x`。因此 Phase 5 修复的是 **logical terminal cell width / shell redraw compatibility**，不是 glyph 的视觉宽度。

---

## 8–14. 测试输入、字号与字体

### 8. test strings

全部覆盖：

- scalars：`A B C | X W`、`⚠`、`⚠️`、`❤`、`❤️`、`😀`、`🚀`、`✅`、`©`、`©️`、`™`、`™️`
- strings：`A⚠️B❤️C`、`|⚠️|❤️|⚠️|❤️|`、`A⚠B❤C`、`A😀B🚀C`、`111⚠️222❤️333`、`WW⚠️WW❤️WW`、`⚠️⚠️⚠️⚠️`、`❤️❤️❤️❤️`

### 9. tested sizes

`10 / 14 / 18 / 24 / 32 pt`。

### 10. primary font

所有字号均为仓库 TTF 运行时注册得到的 `JetBrainsMono-Regular`，family `JetBrains Mono`。probe 使用 `ThirdParty/JetBrainsMono/JetBrainsMono-Regular.ttf`，注册结果 `ok=true`。

### 11. terminal cell width algorithm

resolved SwiftTerm `AppleTerminalView.swift:409-438`：

1. 取 normal font 的 `"W"` glyph。
2. 使用 `fontSet.normal.advancement(forGlyph: glyph).width`。
3. 按 `backingScaleFactor` snap 到 pixel grid。
4. cell height 为 `ceil((ascent + descent + leading) * lineSpacing)` 后再 pixel snap。

### 12. cellWidth table

下表单位为 logical points；2x 列是 Retina 下 SwiftTerm 实际 snap 口径。

| size | W natural advance | cell width 1x | cell width 2x | cell height 1x | cell height 2x |
|---:|---:|---:|---:|---:|---:|
| 10 | 6.0 | 6.0 | 6.0 | 14.0 | 13.5 |
| 14 | 8.4 | 8.0 | 8.5 | 19.0 | 18.5 |
| 18 | 10.8 | 11.0 | 11.0 | 24.0 | 24.0 |
| 24 | 14.4 | 14.0 | 14.5 | 32.0 | 32.0 |
| 32 | 19.2 | 19.0 | 19.0 | 43.0 | 42.5 |

### 13. Apple Color Emoji fallback identity

CoreText 实际 CTLine run：

- `⚠️`、`❤️`、`😀`、`🚀`、`✅`、`©️`、`™️`：`AppleColorEmoji` / `Apple Color Emoji`。
- `⚠`：JetBrains Mono 自身 glyph。
- `❤` text presentation：实际 run 为 `Menlo-Regular`；不是彩色 Emoji。
- `©`、`™`：JetBrains Mono 自身 glyph。

VS16 Emoji **没有**落入 PingFang SC；PingFang 与本问题无关。

### 14. fallback size table

| requested base size | Apple Color Emoji CTFont size | follows base |
|---:|---:|:---:|
| 10 | 10 | yes |
| 14 | 14 | yes |
| 18 | 18 | yes |
| 24 | 24 | yes |
| 32 | 32 | yes |

不存在 fallback size 固定不变的问题。

---

## 15–24. Glyph/run 与归一化度量

### 15. ⚠ glyph/run structure

1 run、1 glyph、JetBrains Mono、advance 约 1 cell；无 VS16，text glyph。

### 16. ⚠️ glyph/run structure

`U+26A0 + U+FE0F` 被 CoreText 合成为 1 grapheme、1 Apple Color Emoji run、1 glyph；没有独立 zero-advance VS16 glyph。

### 17. ❤ glyph/run structure

1 run、1 glyph；CTLine 实际选择 `Menlo-Regular` text glyph，advance 约 1 cell。

### 18. ❤️ glyph/run structure

`U+2764 + U+FE0F` 被 CoreText 合成为 1 grapheme、1 Apple Color Emoji run、1 glyph；没有独立 zero-advance VS16 glyph。

### 19. 😀 glyph/run structure

1 Apple Color Emoji run、1 glyph；SwiftTerm model 正常给 2 cells，现有 `glyphSlotFit` 会进入 wide-cell 路径。

### 20. glyph advance table

`⚠️` 与 `❤️` 的 Apple Color Emoji advance 在本系统相同：

| size | cell width | Emoji advance | advance / cell |
|---:|---:|---:|---:|
| 10 | 6.0 | 13.0 | 2.167 |
| 14 | 8.5 | 19.0 | 2.235 |
| 18 | 11.0 | 22.0 | 2.000 |
| 24 | 14.5 | 25.0 | 1.724 |
| 32 | 19.0 | 32.0 | 1.684 |

### 21. glyph bounds table

CoreText declared glyph bounds（`⚠️` / `❤️` 同一方形 metrics）：

| size | minX | maxX | bounds width | right overhang beyond 1 cell |
|---:|---:|---:|---:|---:|
| 10 | 0.288 | 12.788 | 12.5 | 6.788 |
| 14 | 0.403 | 17.903 | 17.5 | 9.403 |
| 18 | 0.420 | 21.420 | 21.0 | 10.420 |
| 24 | 0.252 | 24.252 | 24.0 | 9.752 |
| 32 | 0.000 | 32.000 | 32.0 | 13.000 |

### 22. advance/cell ratios

见 §20：范围 `1.684–2.235`。结论属于根因分类 **A：glyph advance > logical cell width**。

### 23. bounds/cell ratios

| size | declared bounds / cell | visible ⚠️ pixels / cell | visible ❤️ pixels / cell |
|---:|---:|---:|---:|
| 10 | 2.083 | 2.083 | 1.917 |
| 14 | 2.059 | 2.059 | 2.059 |
| 18 | 1.909 | 1.909 | 1.864 |
| 24 | 1.655 | 1.655 | 1.586 |
| 32 | 1.684 | 1.684 | 1.579 |

结论同时属于根因分类 **B：glyph visual bounds > cell width**；综合分类是 **C：both**。

### 24. normalized scaling behavior

不是“ratio 随字号持续增长”。归一化 ratio 整体下降，24→32 有小幅回升；advance/bounds 也不是严格线性缩放，存在明显台阶。可观测事实符合 Apple Color Emoji 的离散 rasterization/hinting 行为，但本报告不把未读取字体内部实现的推断当作额外根因。

---

## 25–35. String shaping、renderer、位置与 bitmap

### 25. string-level shaping

CoreText 若自然排版 `A⚠️B❤️C`，会用 Emoji natural advance 推动后续 ASCII：

| size | natural x: A / ⚠️ / B / ❤️ / C | natural total width |
|---:|---|---:|
| 10 | 0 / 6 / 19 / 25 / 38 | 44.0 |
| 14 | 0 / 8.4 / 27.4 / 35.8 / 54.8 | 63.2 |
| 18 | 0 / 10.8 / 32.8 / 43.6 / 65.6 | 76.4 |
| 24 | 0 / 14.4 / 39.4 / 53.8 / 78.8 | 93.2 |
| 32 | 0 / 19.2 / 51.2 / 70.4 / 102.4 | 121.6 |

每个 VS16 cluster 都是单 glyph；run sequence 为 JetBrains Mono / Apple Color Emoji / JetBrains Mono / Apple Color Emoji / JetBrains Mono。

### 26. SwiftTerm renderer architecture

答案为 **D（其他，cell-aware segmented CTLine + per-glyph fixed-grid draw）**：

- `buildAttributedString` 将 row 构造成按 cell width 分段的 attributed strings，并保留 UTF-16 → cell ordinal map（`AppleTerminalView.swift:62-88, 994-1035, 1041-1306`）。
- 每段由 CoreText 产生 runs/glyphs。
- renderer 不直接 `CTLineDraw` 整行；它取 glyph 后，用 cell ordinal 重算 x，最后调用 `CTFontDrawGlyphs`（`:2051-2149`）。

### 27. attributed-string behavior

Attributed string 负责 shaping 与 fallback；CoreText natural positions 只保留同一 cluster 内的相对 offset。SwiftTerm 把每个 cluster anchor 重新放回 terminal grid。因此 Apple Color Emoji natural advance **不推动后续 cell**，但 oversized glyph ink 仍能画进后续 cell。

### 28. logical cell positions

`preserveBaseWidth` model probe：

- `A⚠️B❤️C`：A=0、⚠️=1、B=2、❤️=3、C=4，cursor=5。
- `|⚠️|❤️|⚠️|❤️|`：每个字符依次位于 cell 0…8，cursor=9。
- `A⚠B❤C`：5 cells。
- `A😀B🚀C`：7 cells。
- `111⚠️222❤️333`：11 cells。
- `WW⚠️WW❤️WW`：8 cells。
- 四个 `⚠️` / 四个 `❤️`：各 4 cells。

默认 widen 对照：`⚠️` / `❤️` / `©️` / `™️` 各 2 cells；`A⚠️B❤️C`=7 cells；separator string=13 cells。

### 29. rendered positions

SwiftTerm fixed-grid `A⚠️B❤️C` glyph origins与 cursor：

| size | A | ⚠️ | B | ❤️ | C | cursor x (col 5) |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 0 | 6 | 12 | 18 | 24 | 30 |
| 14 | 0 | 8.5 | 17 | 25.5 | 34 | 42.5 |
| 18 | 0 | 11 | 22 | 33 | 44 | 55 |
| 24 | 0 | 14.5 | 29 | 43.5 | 58 | 72.5 |
| 32 | 0 | 19 | 38 | 57 | 76 | 95 |

后续 ASCII origin 正确，但前一 Emoji ink 会覆盖它。

### 30. separator probe

真实 production `TerminalView`、preserve policy、2x bitmap 中，`|` 应位于 cells `0/2/4/6/8`。以第一个 `|` 的白色主笔画为相对基准，后续笔画相对预期误差：

| size | cell 2 | cell 4 | cell 6 | cell 8 | max absolute error |
|---:|---:|---:|---:|---:|---:|
| 10 | +0.5 | +0.5 | -0.5 | -0.5 | 0.5 pt |
| 14 | -0.5 | -0.5 | -0.5 | -0.5 | 0.5 pt |
| 18 | +0.5 | +0.5 | -0.5 | -0.5 | 0.5 pt |
| 24 | -0.5 | -0.5 | -0.5 | -0.5 | 0.5 pt |
| 32 | 0 | 0 | -0.5 | -0.5 | 0.5 pt |

误差上限就是 2x 下的半点 raster choice；源码 glyph origin 是精确的 `cellIndex × cellWidth`。separator 没有累计 drift。

### 31. cursor positions

model probe 的 `buffer.x` 与 `AppleTerminalView.swift:2474-2515` 一致：caret x = `cellDimension.width × caretCol`。`A⚠️B❤️C` 在所有字号 cursor column 恒为 5，pixel x 见 §29；separator string 恒为 column 9；四个 VS16 Emoji 恒为 column 4。没有 cursor drift。

### 32. frame/bitmap probe

已创建真实 `TerminalView(frame: 1200×500)`，使用 production SwiftTerm module/object、JetBrains Mono cascade 与 `.preserveBaseWidth`；分别输出 2400×1000 2x PNG：

- `/tmp/macssh_phase9c_probe/terminal-10pt-2x.png`
- `/tmp/macssh_phase9c_probe/terminal-14pt-2x.png`
- `/tmp/macssh_phase9c_probe/terminal-18pt-2x.png`
- `/tmp/macssh_phase9c_probe/terminal-24pt-2x.png`
- `/tmp/macssh_phase9c_probe/terminal-32pt-2x.png`

PNG 直接显示 Emoji 覆盖相邻 ASCII / separator；未使用 OCR。probe 与产物不复制进仓库。

### 33. Retina consideration

报告所有字体、advance、bounds、overhang 均以 logical points 记录；bitmap 明确为 2x pixels。2x 下 1 px = 0.5 pt，未把 Retina 像素翻倍误判为 glyph 增长。

### 34. baseline alignment

Emoji 与 ASCII 共用 SwiftTerm row baseline anchor；Apple Color Emoji 的声明 vertical bounds 约为：10pt `-2.5…10`、14pt `-3.5…14`、18pt `-3.75…17.25`、24pt `-3…21`、32pt `-4…28`。存在 Apple glyph 自身的上下留白/strike变化，但没有逐字符 baseline x/y 漂移；它是次要视觉差异，不是横向根因。

### 35. selection interference

排除。baseline bitmap 无 selection。源码 `buildAttributedString:1129-1169` 只替换 foreground/background attributes，后续 cell ordinal 与 glyph position 构造不读取 selection 状态；selection 不会改变 advance、cell、origin 或 fit 条件。

---

## 36–46. 字号行为与根因判定

### 36. highlight interference

排除。Phase 6 highlight 只走 `.selectionBackgroundColor` channel，且同样不参与 positions / glyph fit。它可改变背景对比度，让边缘更醒目，但不能制造或修正 overhang。

### 37. 14pt baseline behavior

已存在，并非 0：Apple glyph advance=19 pt，cell=8.5 pt；visible right overhang 约 9.5 pt。真实 bitmap 已显示相邻字符被覆盖。过去“还能接受”只是绝对尺寸与观察距离使问题不如 32pt 醒目，不代表 renderer 在 14pt 正确 fit。

### 38. 24pt behavior

cell=14.5 pt；visible ⚠️/❤️ right overhang 分别约 10.0/9.5 pt。归一化侵入比 14pt 小，但绝对侵入仍接近 10 pt，明显进入下一 cell。

### 39. 32pt behavior

cell=19 pt；visible ⚠️/❤️ right overhang 分别约 13/12 pt。绝对侵入达到本矩阵最大值，足以明显贴近或覆盖下一 ASCII；用户截图现象被独立 TerminalView bitmap 复现。

### 40. whether ratio grows with font size

**否。** ratio 不持续增长，整体从约 2.08（10pt）降到约 1.58–1.68（32pt），24→32 小幅回升。

### 41. whether absolute overhang grows

**总体是，但非严格单调。** visible right overhang：

- ⚠️：7.0 → 9.5 → 10.5 → 10.0 → 13.0 pt
- ❤️：6.5 → 9.5 → 10.0 → 9.5 → 12.0 pt

24pt 的回落证明不能用简单 `fontSize × 常数` 或字号 magic number 修复。

### 42. root cause

根因链：

`preserveBaseWidth`（正确的 shell/model 语义，1 cell） → VS16 保留 → CoreText 选择 Apple Color Emoji 单 glyph（自然约 2 cells） → SwiftTerm fixed-grid 后续 cell origin 正确 → `glyphSlotFit` guard 仅允许 `columnWidth >= 2`（`AppleTerminalView.swift:441-485, 2122-2133`） → 1-cell VS16 glyph 原尺寸绘制 → ink 覆盖相邻 cells。

类别：**C（advance 与 bounds 都大于 cell）**；不是 D（renderer ignores logical cell origin）。

### 43. secondary causes

- Apple Color Emoji 在不同 point size 的 advance/ink 非严格线性，造成 spacing 的台阶感。
- ⚠️ 与 ❤️ 的 declared square bounds 相同，但实际非透明像素不同（例如 32pt 可见宽 32 vs 30 pt），所以肉眼与相邻字符的接近程度不同。
- left origin 基本非负，overhang 主要向右，故“❤️ 与后续 ASCII 尤其接近”更明显。
- draw order 会让后画的 ASCII / separator 与前一 Emoji 发生视觉叠加，但不会改变各自 grid origin。

### 44. whether Phase 9 introduced regression

**否。** Phase 9B 没有改 SwiftTerm parser/model/renderer，font setter 只重算既有 geometry。

### 45. whether Phase 9 exposes old limitation

**是。** 14pt baseline 已有同一 overhang；可选大字号只是把绝对侵入放大到用户更容易察觉的范围。

### 46. native Terminal reference if tested

未测试。Terminal.app 只能作为视觉参考，不能作为 correctness source；现有 production SwiftTerm source + CoreText +真实 TerminalView bitmap 已足以确定根因，避免引入不同 width policy 的干扰。

---

## 47–63. Fix family 评估（只评估，不实现）

### 47. Option A — Accept known visual overhang

不推荐。32pt 的 12–13 pt visible overhang 会覆盖相邻字符；实际 bitmap 已达到内容可读性缺陷，而非轻微审美差异。

### 48. Option B — Drawing-only horizontal scale

**可行且属于首选族。** 只在 renderer 内对 1-cell VS16 Apple Color Emoji overflow glyph 计算 scale，保持 model/cursor/PTY 不变。风险是压缩后的 Emoji 可能显得偏小；需与垂直 fit、baseline、Retina、CoreGraphics/Metal 共用实现一起验证。

### 49. Option C — Clip to logical cell

拒绝。会硬切掉 heart/warning 右侧，保留错误尺寸而丢失图形信息，视觉质量不可接受。

### 50. Option D — Drawing origin compensation

单独使用不够。居中只能把 12–13 pt 右 overhang 分摊为左右侵入，仍会覆盖两个邻居；可作为 fit 后的对齐步骤，不能作为主修复。

### 51. Option E — Renderer fixed cell placement

当前 production **已经这样做**；separator/cursor 无累计误差。继续重写整行 placement 没有收益，也不能缩小 glyph ink。

### 52. Option F — Presentation-only glyph fit

**最安全的具体实现方向。** 与 Option B 合并：在 logical slot 内保持 aspect ratio 缩小，按 advance/ink 居中，必要时做 vertical centering；复用现有 `GlyphSlotFit` 与 CG/Metal 共用路径，而不是增加第二套 renderer。

### 53. Option G — Change VS16 width policy

拒绝。改回 widen 会重新使 Local SwiftTerm width=2、macOS zsh width=1，恢复 bracketed-paste redraw、history、cursor-left 与 cursor drift 风险；46/46 回归测试再次验证 preserve 是必要基线。

### 54. safest fix family

Option **F（包含 B 的 drawing-only scale）**：仅 presentation、仅 overflow glyph、从 glyph/cell metrics 推导，无字号 magic number；在 fit 后做 D 的居中。未来 patch 必须让同一计算同时用于 CoreGraphics 与 Metal。

### 55. rejected fix families

拒绝：strip VS16、改 PTY/input/output bytes、插空格、改 zsh/libc wcwidth、按字号加 spacing、C clip、G widen、仅 D 平移、重复实现 E。

### 56. shell-width compatibility risk

Option F 若严格停留在 renderer，风险低；model 仍为 1 cell，shell 不可见 presentation scale。任何触碰 policy/bytes 的方案风险高且禁止。

### 57. zsh redraw risk

Option F 不改变 `buffer.x`、CharData width、CSI 或 paste bytes，理论上无新增 redraw 风险；仍必须保留 Phase 5 typed/pasted/history 测试作为硬 gate。

### 58. cursor risk

只调整 `glyphPositions` 而不改 `positions` / `caretCol` 时风险低；禁止让 visual fit 反向改变 cursor column/width。

### 59. Local risk

Local 是唯一使用 preserve 的环境，也是修复目标。风险主要是缩放质量、baseline 与性能，不是 shell semantics。

### 60. Remote risk

Remote 默认 VS16 width=2，已进入现有 wide-cell fit。未来 patch 应以“1-cell overflow”或明确 presentation metadata 限定，避免改变 Remote 的 2-cell 行为；Local/Remote 都需回归。

### 61. Highlight risk

低，但必须验证 highlight background 仍覆盖完整 logical cell，glyph fit 不改变 highlight range 或颜色优先级。

### 62. Selection risk

低，但必须验证 selection rect 仍按 logical cell，复制仍保留原 VS16 scalar，缩放不影响选区 foreground/background。

### 63. performance risk

中低。直接在每帧/每 glyph 重复求 bounds 会增加 hot-path 成本；应缓存 `(font identity, glyph, slot width)` 的 fit，沿用现有 fallback/CTLine cache 上限，并分别 benchmark CoreGraphics 与 Metal。

---

## 64–78. 验收指标、优先级与最终建议

### 64. future test matrix

至少覆盖 `10/14/18/24/32 pt`，Local + Remote、CoreGraphics + Metal（若启用）、1x + 2x：

- `⚠️` / `❤️` typed、pasted、programmatic paste
- `A⚠️B❤️C`、separator string、四个连续 Emoji
- zsh redraw、history up/down、left/right、backspace、delete、Home/End
- long wrapped command、bracketed paste
- `⚠` / `❤` text presentation、`😀` / `🚀` / `✅` 2-cell regression
- ASCII、CJK、combining marks、italic/bold
- selection、highlight、copy、cursor、inverse/ANSI background

### 65. visual metric recommendation

未来 renderer acceptance：

1. separator glyph origin 的相对 grid error ≤ **0.5 pt at 2x**（本轮 baseline 已满足）。
2. fit 后 1-cell VS16 actual nontransparent ink 必须完全落入 logical cell，允许抗锯齿边缘最多 **0.5 pt**。
3. cursor x 必须严格等于 `logicalColumn × cellWidth`，model cursor column 零变化。

### 66. overhang metric

定义：

`rightOverhang = renderedNonTransparentBounds.maxX - logicalCellRect.maxX`

并同时记录 points 与百分比：

`rightOverhangPercent = rightOverhang / cellWidth × 100%`

当前 32pt：⚠️ `13 pt / 68.4%`，❤️ `12 pt / 63.2%`。推荐修复后上限为 0.5 pt（2x 一像素）。

### 67. user-visible threshold

数据与 bitmap 不支持把问题限定为 18+ 或 24+：10/14pt 已有超过 1 个 cell 的 declared/visible 宽度。**技术阈值从 10pt 即存在**；主观明显度随绝对 overhang 增大，32pt 最突出。不能拍脑袋设置一个字号条件。

### 68. max 32pt assessment

32pt 当前不可接受，但把最大值降到 24/28 不是有效主修复：24pt 仍有约 9.5–10 pt overhang，14pt baseline 也已存在。只有在 renderer remediation 被长期阻塞时，降低 max 才能作为临时产品降级；本报告不优先推荐。

### 69. whether SwiftTerm fork change would be required

**稳妥修复需要。** glyph selection、slot fit、CG/Metal draw 都在 SwiftTerm renderer 内；现有 public host API 没有安全的 per-glyph presentation transform hook。

### 70. whether MacSSH-only fix possible

不建议把字体大小、字符串、空格或 bytes 在 MacSSH 层改写。MacSSH-only 可做的只有“降低 max / 接受 limitation”这类产品降级；真正安全的 glyph fit 应是小型、通用、presentation-only SwiftTerm fork patch。

### 71. whether Phase 9 FINAL PASS should be blocked

**是，当前阻塞。** 唯一分类选择为任务书 §48 的 **C：需要一个小的 Phase 9C rendering remediation 后才能 FINAL PASS**。

### 72. recommended next action

STOP 后等待独立评审与用户授权。若授权 remediation，先提交预览/对比 bitmap 与数学 fit 规则供 UI 视觉确认；确认后才改 SwiftTerm renderer。不得在本调查阶段实现。

### 73. P1

`preserveBaseWidth` 的 1-cell VS16 Apple Color Emoji 未进入 `glyphSlotFit`，导致相邻字符实际可读性受损。**P1，阻塞 Phase 9B FINAL PASS。**

### 74. P2

未来 fit 必须 CG/Metal 同源并带 cache；否则可能出现 renderer 差异或性能退化。**P2，属于 remediation 设计 gate。**

### 75. P3

Apple Color Emoji strike 的非线性 scaling、⚠️/❤️ 内部透明像素差异需记录为平台字体行为。**P3，不单独阻塞，但禁止用字号 magic number。**

### 76. known limitations

- 本轮未重做用户正在进行的完整 MacSSH GUI footer cols×rows 手工矩阵，避免修改其持久设置；使用的是相同 production SwiftTerm binary + 相同 font cascade 的真实离屏 TerminalView。
- bitmap baseline 无 selection/highlight；两者的无位置影响由 production source dataflow 证明，未来 fix 仍需 GUI A/B。
- 未测试 Terminal.app reference；它不影响 root-cause correctness。
- bitmap 为默认 CoreGraphics path；production 当前没有显式启用 Metal，但未来 patch 仍必须跑 Metal parity。
- `CTFontGetBoundingRectsForGlyphs` 对彩色 glyph 给出统一方形 metrics，因此另加 2x alpha pixel scan 区分 ⚠️ 与 ❤️；像素阈值为 alpha > 8。

### 77. final recommendation

保持 Phase 5 `preserveBaseWidth` 与所有 PTY/shell/cursor semantics 不变；不要 strip VS16、插空格、改 wcwidth、改 policy 或降低 max 作为首选。下一步只在获得明确授权和 UI 预览确认后，做一个可缓存、CG/Metal 共用、metrics-driven 的 1-cell VS16 overflow glyph fit，并用 §64–66 gate 验收。

### 78. final status

**INVESTIGATION COMPLETE — ROOT CAUSE VERIFIED — PHASE 9B FINAL PASS BLOCKED PENDING AUTHORIZED PRESENTATION-ONLY REMEDIATION — STOP.**

---

## 验证记录

### 现有测试

`xcodebuild test-without-building`：

- `TerminalFontResizeTests`：13/13 pass
- `TerminalFontSizeControllerTests`：20/20 pass
- `TerminalVS16WidthPolicyTests`：13/13 pass
- 合计：**46/46 pass，0 failure**
- xcresult：`/tmp/MacSSH-P9B-ACC-DD/Logs/Test/Test-MacSSH-2026.09.05_00-22-39-+0800.xcresult`

### 编译、运行与 warning

- Debug arm64：独立 DerivedData `/tmp/macssh-phase9c-debug-dd`，exit 0，`xcodebuild -quiet` 无 warning/error 输出。
- Release arm64：独立 DerivedData `/tmp/macssh-phase9c-release-dd`，exit 0，`xcodebuild -quiet` 无 warning/error 输出。
- 两个 App binary 均为 Mach-O arm64；`codesign --verify --strict` 均 valid on disk / satisfies Designated Requirement。
- Release App 短暂启动成功，随后在同一 PTY 发送 Ctrl-C，精确路径进程复核为空；启动日志只有既有 `NSFontManager` 信息与临时 saved-state 路径。

### Probe 清单

- `/tmp/macssh_phase9c_probe/CoreTextMetrics.swift`
- `/tmp/macssh_phase9c_probe/ModelProbe.swift`
- `/tmp/macssh_phase9c_probe/TerminalViewProbe.swift`
- 对应 binaries、module cache、profraw 与 5 张 PNG 全部留在 `/tmp`。

## STOP

未实现 fix；未修改 SwiftTerm；未 commit / merge / push；未进入下一 Phase。等待独立评审与用户决定。
