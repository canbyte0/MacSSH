# MacSSH 1.1 Phase 9D-B — Independent SwiftTerm Fork Code Acceptance (First Round)

> 角色：Independent SwiftTerm Fork Reviewer（非实现者/非 9C 调查者），从源码 + git history 独立验证。
> 对象：candidate `ded302c9adf0e41185445560f3049e67fb180b6d`（branch `macssh-vs16-one-cell-render-fit`，parent `771e79f`）。
> 日期：2026-09-05。
> **结论：FAIL（0 P1 / 3 P2）— 不得推进 MacSSH SwiftTerm exact revision。**
> 本文件为历史记录（§26 honesty），保留首次 FAIL；修复见 `Docs/Phase9D-B-VS16-Renderer-Remediation-Report.md`（Phase 9D-B2，candidate `93abf60`）。

---

## 1. Acceptance result

**FAIL**

## 2. P1

**0**

## 3. P2

**3**：

### P2-1（核心，correctness 回归）— Bold/Italic/BoldItalic ASCII 被错误 fit

- 根因：`isBaseFont(font)` 仅 `glyphFitFontID(font) == glyphFitFontID(fontSet.normal as CTFont)`（ObjectIdentity）。`FontSet.init`（`MacTerminalView.swift:164-169`）经 `NSFontManager.shared.convert(baseFont, toHaveTrait:[.boldFontMask/.italicFontMask])` 派生 bold/italic/boldItalic —— **不同 NSFont 对象** → `isBaseFont` 对它们返回 **false**。
- 结果：call-site gate `columnWidth==1 && !isBaseFont(ctRunFont)` **不跳过** bold/italic 1-cell run → 它们进入 `glyphSlotFit`/`computeGlyphFit`。
- 探针实证（Menlo 24pt，临时测试 `_ProbeBoldItalicFitTests.swift`，用完即删，fork tree 恢复 clean）：
  - Bold 'A'/'W'/'1'/'|'/'!'/'@'：scale=1 但 **dx=0.025390625**（非零；bold advance≠regular advance → advance-centering 偏移）→ 非 identity。
  - Italic 'W'：**scale=0.956**, dx=0.34, dy=-0.36（italic 斜体 ink 溢出 cell → 被缩小）。
  - Italic '@'：scale=0.92, dy=2.26；BoldItalic 'W'：scale=0.931, dx=0.52, dy=-0.14。
- baseline `771e79f` gate `columnWidth>=2` 跳过**所有** 1-cell run（含 bold/italic）→ identity。candidate 使 bold/italic 1-cell ASCII 偏移/缩小 → **相对 baseline 回归**。
- 违反任务书 §8（"Regular/Bold/Italic/BoldItalic 全部 identity transform…否则 P1/P2"）+ §9（"是否会误伤 bundled JetBrains Mono Bold/Italic"）。
- 机制 font-family-agnostic：生产 JetBrains Mono 同样经 `NSFontManager.convert` 派生 bold/italic → 不同对象 → italic ASCII 同会被缩小。
- 分类：Italic ASCII 被缩小 = §66 "ASCII被错误scale"（P2）；Bold 被偏移 = "Bold/Italic被错误fit"（P2）。
- 修复方向：`isBaseFont` 改为识别全部四个 FontSet 成员（ObjectIdentity 比对四个成员，或 PostScript-name+size），而非仅 `normal`。

### P2-2（test gap）— 无 Bold/Italic/BoldItalic ASCII 覆盖

- 任务 §8 明确要求测试 A/W/1/|/!/@ 在 Regular/Bold/Italic/BoldItalic 全 identity。`asciiBaseFontGlyphIsIdentity` + `wideAsciiRunIsIdentityAcrossPunctuation` 仅测 Regular。Italic-W-scaling 回归因无测试而未被捕获。§66 "重要测试缺口"（P2）。

### P2-3（docs accuracy）— 报告 §33/§15 论断错误

- 报告 §33："base font (Regular/Bold/Italic/BoldItalic) → `isBaseFont` true → call-site gate 跳过" —— **事实错误**（`isBaseFont` 对 bold/italic 返回 false）。
- 报告 §15："即便 identity 比较 miss，`computeGlyphFit` 仍走 ink-overflow → ASCII ink ≤ cell → identity" —— **对 italic 不成立**（italic 斜体 ink 溢出 → scale<1）。
- 这两处掩盖真实 P2-1 缺陷。

## 4. PASS 项摘要（核心修复正确）

- Git identity：branch `macssh-vs16-one-cell-render-fit`，HEAD `ded302c`，HEAD~1 `771e79f`，merge-base `771e79f`，direct child ✓。
- Diff scope：4 files（AppleTerminalView.swift M / MetalTerminalRenderer.swift M / OneCellGlyphFitTests.swift A / GlyphFitCacheTests.swift A），+475/-24。`git diff --check` clean。TerminalOptions/Terminal/MacTerminalView/LocalProcess/Pty/Shaders.metal diff 全空。
- P1 RESOLVED：1-cell VS16 Apple Color Emoji 进 fit（glyphSlotFit guard `columnWidth>=2` 移除，CG `:2209` + Metal `:1316` gate 扩展）。
- P2 RESOLVED：CG/Metal 共享 `glyphSlotFit`→`computeGlyphFit` 单一 source + `glyphFitCache`（file-level, bounded 1024, key=fontID/glyph/columnWidth/cellW/cellH）。Metal 真实消费（basePos+=dx/dy, entry.size/bearing×scale）。
- Uniform fit：`scale=max(0.1,min(min(slotW/ink.w,cellH/ink.h),1))`，scaleX==scaleY，no upscale，metrics-driven（非 codepoint/size hardcode）。
- ASCII Regular identity；CJK wide path byte-for-byte 等价；⚠️/❤️ fit、⚠/❤ text identity、😀/🚀/✅ wide path 全对。
- preserveBaseWidth 1-cell hard gate（⚠️/❤️ width==1, cursor==5）。
- Cache：VS16 区分（glyph id）、字号失效（cellW/cellH in key）、bounded 1024。
- 线程：CG/Metal draw 均 main-thread；`cgColorCache`/`fallbackFontCache` 同 file-level bounded 模式 precedent；`@MainActor` 测试正确（production main-thread 契约）。SIGSEGV（`f662cad`）评估可信。
- 测试：全量 770/66 ×2（10.022s+10.040s）+ 定向 17×10，0 failures/crashes。0 candidate warning。
- MacSSH pin 仍 `771e79f`（Package.resolved + pbxproj）；9D-B 仅 fork commit，MacSSH production 未触。

## 5. 决策

0 P1 / 3 P2 → **FAIL，不得推进 MacSSH SwiftTerm exact revision**。核心 VS16 1-cell fit 正确，但 `isBaseFont` predicate 误伤 styled ASCII 必须修。

## 6. 推荐下一步

1. 实现者修复 `isBaseFont`：识别全部四个 FontSet 成员。
2. 新增 style×glyph 矩阵测试（4×6 全 identity）+ size 矩阵。
3. 修正报告 §33/§15。
4. amend candidate（保留 parent `771e79f`）后重做 Independent Fork Re-Acceptance。

---

*本报告为首次 Independent Acceptance 历史记录，保留 FAIL 结论不掩盖（§26）。修复后状态见主报告 `Docs/Phase9D-B-VS16-Renderer-Remediation-Report.md`（candidate `93abf60`）。*
