# MacSSH 1.1 Phase 9D-C — Integrate Accepted SwiftTerm Renderer Revision

> 角色：MacSSH Integration Engineer。将 Independent Fork Re-Acceptance PASS 的 SwiftTerm revision `93abf601` 集成进 MacSSH production exact revision pin；不改 SwiftTerm renderer 代码；不 commit MacSSH（等 GUI FINAL PASS）。
> MacSSH branch：`feature/macssh-1.1-terminal-font-size`。
> 日期：2026-09-05。
> **结论：AUTOMATED VALIDATION PASS（0 P1 / 0 P2）— 允许用户 GUI Re-Acceptance。不 commit MacSSH。**

---

## 1. MacSSH branch

`feature/macssh-1.1-terminal-font-size` ✓（`git branch --show-current`）

## 2. MacSSH HEAD baseline

`c6bf66c2b985530e6687fefe62cdf08246190e41`（Phase 8 commit；Phase 9A/B/C/D 工作树修改全部保留，未 reset/clean）✓

## 3. SwiftTerm remote

`https://github.com/canbyte0/SwiftTerm.git`（fork remote `github`，fetch+push）✓

## 4. SwiftTerm feature branch

`macssh-vs16-one-cell-render-fit`（push 到 `github` remote，未 push main，未 force push，未 tag）✓

## 5. accepted candidate

`93abf601469e572faffed65f75d548c58afa3058`（Re-Acceptance PASS，`Docs/Phase9D-B2-Independent-Fork-Re-Acceptance.md`）

## 6. accepted parent

`771e79f092a26e7fba7af0ab2b09a2bf10213109`（Phase 7 paste API；direct child，`HEAD^` = `771e79f`，merge-base 一致）✓

## 7. remote publication result

`git push github macssh-vs16-one-cell-render-fit` → `* [new branch] macssh-vs16-one-cell-render-fit -> macssh-vs16-one-cell-render-fit` ✓（未 merge main / 未 push main / 未 force push / 未 tag）

## 8. ls-remote result

`git ls-remote https://github.com/canbyte0/SwiftTerm.git refs/heads/macssh-vs16-one-cell-render-fit` → `93abf601469e572faffed65f75d548c58afa3058` ✓（与 candidate 一致）

## 9. old MacSSH revision

`771e79f092a26e7fba7af0ab2b09a2bf10213109`（Phase 7，pbxproj:948 + Package.resolved:18 before）

## 10. new MacSSH revision

`93abf601469e572faffed65f75d548c58afa3058`（Phase 9D）

## 11. project.pbxproj

`:948` `revision = 93abf601469e572faffed65f75d548c58afa3058;`（`kind = revision`，`repositoryURL = "https://github.com/canbyte0/SwiftTerm.git"`）✓

## 12. Package.resolved

`:18` `"revision" : "93abf601469e572faffed65f75d548c58afa3058"`（`kind = remoteSourceControl`，`location = https://github.com/canbyte0/SwiftTerm.git`，无 `localSourceControl` / 无 `file://`）✓

## 13. exact revision confirmation

三重确认：
1. `project.pbxproj:948` = `93abf601...` ✓
2. `Package.resolved:18` = `93abf601...` ✓
3. build log：`Checking out 93abf601469e572faffed65f75d548c58afa3058 of package 'SwiftTerm'` + `SwiftTerm: https://github.com/canbyte0/SwiftTerm.git @ 93abf60` ✓

## 14. no branch dependency

✓ `kind = revision`（pbxproj），非 branch / upToNextMajor / upToNextMinor / version range。生产 pin 不会跟 `macssh-vs16-one-cell-render-fit` branch head 漂移。

## 15. no local override

✓ pbxproj 无 `localSourceControl` / 无 `file://` / 无 `ThirdParty/SwiftTerm-fork` 路径引用（grep 全空）。Package.resolved location = GitHub URL。fresh DerivedData `/tmp/macssh-9dc-dd` 解析从 GitHub fetch（`Fetching from https://github.com/canbyte0/SwiftTerm.git`）。

## 16. DependencyIdentityTests

更新 `Tests/SSH/DependencyIdentityTests.swift`：
- 新增 Phase 9D patch 常量（revision `93abf601`，branch `macssh-vs16-one-cell-render-fit`）
- `swiftTermPatchRevision`（当前生产）改为 Phase 9D
- 新增 `testPhase9DPatchParentIsPhase7Patch`（git log 验证 `93abf601` parent = `771e79f`）— passed ✓
- 更新 `testPackageResolvedLocksSwiftTermToCurrentRemoteForkRevision`（断言 Package.resolved = Phase 9D）— passed ✓
- 更新 `testPrintSwiftTermForkIdentitySummary`（含 Phase 9D + 互不相同断言）— passed ✓
- 保留 Phase 5/6/7 身份断言（不删除 identity assertion）✓

## 17. preserveBaseWidth

✓ `MacSSH/Services/Terminal/LocalTerminalService.swift:38` 仍 `variationSelector16WidthPolicy: .preserveBaseWidth`。revision update 未改 policy。`TerminalOptions.swift`/`Terminal.swift` preserve 语义在 fork 93abf601 diff 中未改（B2 仅改 isBaseFont + 测试）。

## 18. TerminalFontSizeController unchanged

✓ `MacSSH/App/TerminalFontSizeController.swift` 未被 9D-C 触碰（fork diff 不含 MacSSH production；我的 9D-C 改动仅 pbxproj/Package.resolved/MANIFEST.txt/DependencyIdentityTests/TerminalFontResizeTests-smoke）。Phase 9B 字号特性（10–32pt / default 14 / step 1 / live update / persistence）由 `TerminalFontSizeControllerTests` + `TerminalFontResizeTests` 全绿保持。

## 19. Debug build

`xcodebuild build -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/macssh-9dc-dd` → `** BUILD SUCCEEDED **` ✓

## 20. Release build

`xcodebuild build -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/macssh-9dc-dd -skipPackagePluginValidation` → `** BUILD SUCCEEDED **` ✓

## 21. production warnings

✓ 0 MacSSH production warnings + 0 SwiftTerm candidate warnings（Debug + Release build log grep `warning:` 全空，排除 pre-existing bundle warning）。仅 `LLVM Profile Error: Failed to write "default.profraw": Operation not permitted`（sandbox profiling instrumentation，非 build warning/error）。

## 22. full tests

`xcodebuild test`（fresh DerivedData）→ **490 tests, 114 skipped, 0 failures** ✓（Phase 9B 为 489；+1 新 VS16 集成 smoke）。0 unexpected。95.4s。

## 23. executed

490

## 24. skipped

114（既有 skip：TransferQueueRealTests 5、TransferResourceTests 1、TransferManagerTests 1 等，非 Phase 9 新增 skip）

## 25. failed

0

## 26. Phase 2 font regression

✓ `TerminalFontResizeTests`：JetBrains Mono Regular/Bold/Italic/BoldItalic identity @ 14/18/24pt 全绿（`testRegularIdentityAtMultipleSizes` / `testBoldDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes` / `testItalicDerived...` / `testBoldItalicDerived...`，fontName 含 `JetBrainsMono` + Bold/Italic marker + Bundle 来源 + pointSize 跟随）。本次 fork 首轮 FAIL 曾发现 styled ASCII fit 问题；Re-Acceptance PASS 已修复（isBaseFont 四成员 guard），MacSSH 集成后 font identity 测试全绿。

## 27. Regular

✓ `JetBrainsMono` @ 14/18/24pt，Bundle 来源。

## 28. Bold

✓ `JetBrainsMono` + `Bold` marker @ 14/18/24pt。

## 29. Italic

✓ `JetBrainsMono` + `Italic` marker @ 14/18/24pt。

## 30. BoldItalic

✓ `JetBrainsMono` + `Bold` + `Italic` marker @ 14/18/24pt。

## 31. Phase 5 VS16

✓ `TerminalVS16WidthPolicyTests`（13 tests）passed。⚠️/❤️ typed/paste/bracketed paste/history/cursor redraw/preserveBaseWidth 全绿。`testVS16UniformFitRendererIntegrationSmoke`（新集集 smoke）feed `A⚠️B❤️C` + `|⚠️|❤️|⚠️|❤️|` + ANSI Bold/Italic/BoldItalic + CJK + emoji @ 14/24/32pt，断言 ⚠️/❤️ logical width==1 + 不 crash — passed。

## 32. bracketed paste

✓ `testBracketedPasteRedrawStaysCleanUnderPreservePolicy` + `testCopyLineExtractionMatchesVisibleTextUnderPreservePolicy` + `testNoResidualInverseAfterRedrawUnderPreservePolicy` 全绿（含在 TerminalVS16WidthPolicyTests）。

## 33. cursor/redraw

✓ preserveBaseWidth 下 cursor column 精确（`testVS16UniformFitRendererIntegrationSmoke` 断言 ⚠️/❤️ width==1；`preserveBaseWidthKeepsEmojiOneCellAndCursorColumn` fork 测试 cursor==5）。renderer fix 纯 presentation-only，不改 model/cursor/bytes。

## 34. Phase 6 Highlight

✓ `TerminalHighlightStoreTests`（12 tests）passed。renderer fix 只改 `glyphPositions`（局部），不改 grid `positions` → highlight background 仍按 logical cell geometry。

## 35. Phase 7 Sidebar

✓ `TerminalRightSidebarStateTests`（13 tests）passed。Right Sidebar resize 继续正常影响 cols/rows（font change → resize → sizeChanged 链由 `TerminalFontResizeTests` 覆盖）。

## 36. Phase 8 Appearance

✓ `AppAppearanceControllerTests` passed（Light/Dark/Follow System reapplies idempotent）。renderer fix 基于 font metrics + cell geometry，不读 appearance/color → Light/Dark 只颜色变化、geometry 不变。

## 37. Phase 9 font-size tests

✓ `TerminalFontSizeControllerTests` + `TerminalFontResizeTests` 全绿。cell geometry 随字号变化（`testCellDimensionScalesWithFontSize`）、cols/rows 随 font 变化（`testColsRowsChangeWithFontSizeAtFixedFrame`）、sizeChanged delegate 触发（`testFontChangeTriggersSizeChangedDelegate`）。

## 38. geometry

✓ cellWidth/cellHeight 随 10/14/18/24/32pt 变化（SwiftTerm `computeFontDimensions` 重算）。renderer fix 不改 cell geometry（只改 glyph ink dx/dy/scale）。

## 39. Local resize

✓ `testLocalProcessTerminalViewFontChangeUpdatesCellDimension`（LocalProcessTerminalView font change → cellW/cellH recompute）passed。真实 PTY `setWinSize` 留 GUI 验收（§52 #14 stty resize）。

## 40. Remote resize

✓ `testFontChangeTriggersSizeChangedDelegate` + `testFontChangeSizeChangedColsRowsReflectNewFont`（Remote TerminalView font change → sizeChanged delegate 报告 newCols/newRows）passed。真实 Remote SSH channel resize 留 GUI 验收（§52 #13/#14）。

## 41. A⚠️B❤️C integration

✓ `testVS16UniformFitRendererIntegrationSmoke`：feed `A⚠️B❤️C` @ 14/24/32pt → ⚠️/❤️ logical width==1 + 不 crash。resolved SwiftTerm 93abf601 renderer（含 glyphSlotFit + isBaseFont 四成员 guard + 1-cell ink-overflow fit）被 MacSSH 实际链接使用（编译期解析该 renderer path；771e79f 无 isBaseFont）。

## 42. separator integration

✓ `testVS16UniformFitRendererIntegrationSmoke`：feed `|⚠️|❤️|⚠️|❤️|` @ 14/24/32pt → ⚠️/❤️ logical width==1 + 不 crash。separator `|` 是 base font ASCII → gate 跳过 → identity → grid origin 保持 exact logical cell positions（renderer fix 不偏移 separator）。

## 43. 14pt

✓ 集成 smoke @ 14pt passed（⚠️/❤️ width==1，不 crash）。

## 44. 24pt

✓ 集成 smoke @ 24pt passed。

## 45. 32pt

✓ 集成 smoke @ 32pt passed。

## 46. CJK

✓ `testCJKFallbackFollowsBaseFontSize`（PingFang SC @ 14/18/24pt cascade resolved + pointSize 跟随）+ `testVS16UniformFitRendererIntegrationSmoke`（feed `ABC中文DEF`，不 crash）passed。CJK `columnWidth==2` 走既有 wide path，不被压成 1 cell、不异常缩小（fork `cjkWideCellIsBoundedAndUniform` 验证 scale≤1）。

## 47. normal emoji

✓ `testEmojiFallbackFollowsBaseFontSize`（Apple Color Emoji @ 14/18/24pt）+ 集成 smoke（feed `😀🚀✅`，不 crash）passed。non-VS16 width-2 emoji 走既有 wide path，行为不变。

## 48. git diff check

✓ `git diff --check` clean（无 whitespace 错误）。
⚠️ **pre-commit cleanup**：repo root 有 1 个 0 字节拋留空文件 `macssh-vs16-one-cell-render-fit`（push/resolve 期间产生，非 Phase 9 工作内容）。**commit 前必须删除**（`rm macssh-vs16-one-cell-render-fit`）。已尝试删除但审批超时；用户 commit 前手动删除即可。

## 49. files modified

Phase 9D-C 新增/修改：
- `M MacSSH.xcodeproj/project.pbxproj`（pin 771e79f → 93abf601）
- `M MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`（pin）
- `M ThirdParty/MANIFEST.txt`（Phase 9D patch section + 生产 revision）
- `M Tests/SSH/DependencyIdentityTests.swift`（Phase 9D 常量 + 父子测试 + summary）
- `?? Tests/SSH/TerminalFontResizeTests.swift`（Phase 9B 新文件，+1 VS16 集成 smoke；整体仍 untracked）

## 50. unrelated changes

✓ 未修改：Terminal parser、SwiftTerm source（renderer 代码）、MacSSH renderer、TerminalFontSizeController、TerminalFontProvider、SessionManager（Phase 9B 改动保留但非 9D-C 新增）、preserveBaseWidth policy。其余 working tree 改动均为 Phase 9A/B 既有产物（AppLanguage/AppState/AppTheme/SettingsView/Sidebar/TabBar/Localizable/LocalShellLauncher/SessionManager/gen_localizable 等）。

## 51. phase history preserved

✓ 真实历史保留：
- `ded302c`（首轮 candidate）→ Independent Fork Acceptance **FAIL**（0 P1/3 P2，`Docs/Phase9D-B-Independent-Fork-Acceptance.md`）
- → `93abf601` remediation（Phase 9D-B2，`Docs/Phase9D-B-VS16-Renderer-Remediation-Report.md` 勘误 §15/§33）
- → Independent Fork **Re-Acceptance PASS**（`Docs/Phase9D-B2-Independent-Fork-Re-Acceptance.md`）
- → MacSSH pin update（本报告）
失败历史未抹掉。

## 52. GUI re-acceptance checklist

用户 GUI Re-Acceptance 须确认（Local + Remote，14/24/32pt）：
1. `A⚠️B❤️C`（⚠️/❤️ 缩进 cell、不覆盖邻居；14pt 最明显）
2. 14pt `A⚠️B❤️C`
3. 24pt `A⚠️B❤️C`
4. 32pt `A⚠️B❤️C`
5. `|⚠️|❤️|⚠️|❤️|`（separator `|` 在 grid、emoji 缩进 cell、不偏移 separator）
6. Bold ASCII（`ABCDE` bold，不偏移/不缩小）
7. Italic ASCII（`WWWWW` italic，不缩小；首轮 FAIL 曾回归）
8. BoldItalic ASCII
9. Chinese（`ABC中文DEF`，CJK 2-cell、不压扁）
10. `😀🚀✅`（normal emoji，wide path 正常）
11. cursor（`A⚠️B❤️C` 后 cursor 在 col 5，不 drift）
12. Highlight（背景按 logical cell、glyph ink 缩但 background 不缩）
13. Local（stty size 14→18→24，rows/cols 方向正确）
14. Remote（stty size 14→18→24，SSH channel resize）
15. Light（geometry 不变，只颜色）
16. Dark（geometry 不变）
17. persistence（重启后字号保持；新 session 用当前字号）

## 53. P1

**0**。无 production crash、无 thread race、无 logical width regression、无 cursor/model corruption、无 Phase 5 严重回归、无 CG/Metal 严重不一致。

## 54. P2

**0**。无 branch dependency（exact revision pin）、无 local override、preserveBaseWidth 保持、DependencyIdentity 全绿、TerminalFontSizeController 未被重写、full tests 0 failure。

## 55. P3

- repo root 1 个 0 字节拋留空文件 `macssh-vs16-one-cell-render-fit`（push/resolve 副产物，**commit 前删除**）。
- `LLVM Profile Error: default.profraw Operation not permitted`（sandbox profiling instrumentation，非 build warning/error）。
- test log `com.apple.linkd.autoShortcut` connection noise（macOS 系统服务，非 test failure）。
- MacSSH-level styled ASCII fit identity（scale/dx/dy）未直接断言（fork OneCellGlyphFitTests 4×6 + 45-case size matrix 充分覆盖；MacSSH smoke = 不 crash + font identity + model cursor；符合 §15 "至少 smoke"）。
- 真实 PTY `setWinSize` / Remote SSH channel resize 留 GUI 验收（单测用 spy delegate 捕获 sizeChanged，未接真实 shell）。

## 56. 是否允许用户 GUI Re-Acceptance

**是**。0 P1 / 0 P2 → 允许用户 GUI Re-Acceptance（§52 checklist）。

## 57. final status

**AUTOMATED VALIDATION PASS — Phase 9D-C MacSSH SwiftTerm integration complete — SwiftTerm fork branch `macssh-vs16-one-cell-render-fit` pushed to github remote (ls-remote = 93abf601) — MacSSH production exact revision pin updated 771e79f → 93abf601469e572faffed65f75d548c58afa3058 (pbxproj kind=revision + Package.resolved remoteSourceControl, no branch/local override) — package resolved from GitHub (checked out 93abf601) — triple-confirm identity (pbxproj + Package.resolved + build log) — DependencyIdentityTests updated to Phase 9D + new parent test (passed) — Debug + Release clean build SUCCEEDED, 0 production/candidate warnings — full MacSSH tests 490/114/0 (+1 VS16 integration smoke) — Phase 2/5/6/7/8/9 regressions all green — preserveBaseWidth unchanged — TerminalFontSizeController unchanged — VS16 integration smoke (A⚠️B❤️C + separators + ANSI Bold/Italic/BoldItalic + CJK + emoji @ 14/24/32pt) passed with resolved 93abf601 renderer — git diff --check clean — 0 P1 / 0 P2 — phase history preserved (ded302c FAIL → 93abf601 remediation → Re-Acceptance PASS → pin update) — NOT committed / NOT merged / NOT pushed MacSSH main — 1 pre-commit cleanup (stray 0-byte file) — awaiting user GUI Re-Acceptance → Phase 9 FINAL PASS — STOP.**

---

## 验证执行记录

### SwiftTerm remote publication gate（§0-1）
- `git branch --show-current` = `macssh-vs16-one-cell-render-fit` ✓
- `git rev-parse HEAD` = `93abf601469e572faffed65f75d548c58afa3058` ✓
- `git rev-parse 'HEAD^'` = `771e79f092a26e7fba7af0ab2b09a2bf10213109` ✓
- `git status --short` = 空 ✓
- `git push github macssh-vs16-one-cell-render-fit` → new branch created ✓
- `git ls-remote https://github.com/canbyte0/SwiftTerm.git refs/heads/macssh-vs16-one-cell-render-fit` = `93abf601...` ✓

### MacSSH baseline（§2）
- `git branch --show-current` = `feature/macssh-1.1-terminal-font-size` ✓
- `git rev-parse HEAD` = `c6bf66c2...` ✓
- Phase 9A/B/C/D working tree 全部保留 ✓

### Dependency resolution（§6-7）
- `xcodebuild -resolvePackageDependencies -derivedDataPath /tmp/macssh-9dc-dd`：
  - `Fetching from https://github.com/canbyte0/SwiftTerm.git (cached)`
  - `Checking out 93abf601469e572faffed65f75d548c58afa3058 of package 'SwiftTerm'`
  - `SwiftTerm: https://github.com/canbyte0/SwiftTerm.git @ 93abf60` ✓

### Builds（§11-12）
- Debug：`** BUILD SUCCEEDED **`，0 warnings ✓
- Release：`** BUILD SUCCEEDED **`，0 warnings ✓

### Tests（§13）
- full：490 executed / 114 skipped / 0 failures ✓
- DependencyIdentityTests passed（含 testPhase9DPatchParentIsPhase7Patch）✓
- TerminalVS16WidthPolicyTests（Phase 5）passed ✓
- TerminalHighlightStoreTests（Phase 6）passed ✓
- TerminalRightSidebarStateTests（Phase 7）passed ✓
- AppAppearanceControllerTests（Phase 8）passed ✓
- TerminalFontSizeControllerTests + TerminalFontResizeTests（Phase 9B）passed ✓
- testVS16UniformFitRendererIntegrationSmoke（新集成 smoke）passed ✓

### Invariants（§9-10, 17-18）
- `LocalTerminalService.swift:38` = `.preserveBaseWidth` ✓
- TerminalFontSizeController 未被 9D-C 触碰 ✓
- pbxproj 无 localSourceControl/file:// ✓

### Git（§31, 48-50）
- `git diff --check` clean ✓
- Phase 9D-C 改动：pbxproj + Package.resolved + MANIFEST.txt + DependencyIdentityTests + TerminalFontResizeTests-smoke ✓
- ⚠️ repo root 0-byte `macssh-vs16-one-cell-render-fit` 拋留文件（commit 前删除）

## STOP

未 commit MacSSH；未 merge；未 push MacSSH main；未删除 Phase branch；未开始下一 Phase；未宣告 Phase 9 FINAL PASS。等待用户 GUI Re-Acceptance。
