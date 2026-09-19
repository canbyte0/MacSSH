# Phase 10F-B2-S1-H — SwiftTerm Repository Integrity Recovery

Stage type: recovery only（不涉及功能扩展）。旧 corrupt checkout 仅作证据/源文件输入，未做任何对象修复。

## MacSSH
- branch: `feature/macssh-1.1-agent-terminal-mutation`
- HEAD: `e958750643aeb9992d4cb357e91dc084130224eb`
- B1 candidate changed: NO（6 文件 `MacSSH/Services/Agent/TerminalMutation/` + 6 测试文件均保持 untracked，status 行数 preflight/postflight 均为 27）
- Package.resolved: UNCHANGED（mtime 2026-09-06 20:38）
- staged: 0
- commit: NO
- push: NO（本 checkout 无 origin 远端，物理不可 push）

## Old SwiftTerm Checkout
- path: `/Users/msl/msl_coding/MacSSH/ThirdParty/SwiftTerm-fork`
- branch: `macssh-agent-local-input-transport`
- HEAD: `40d473b1fdb456d49cc04b7f253277fcb9ac3987`
- preserved: YES（未改名、未删除、未修改）
- object repair performed: NO（本阶段未执行 hash-object -w / gc / repack / prune / reset / commit-graph write / 对象复制 / alternates 编辑）
- known corruption: alternates 死路径告警仍复现（`/Users/msl/msl_code/Ter/build/DerivedData/...`，stderr 提示，仅 stderr、命令 exit 0）

## Candidate Export
- export path: `/tmp/macssh-swiftterm-b2-s1-r1.ZwVFJT`（不含 .git）
- files: `Sources/SwiftTerm/LocalProcess.swift`、`Sources/SwiftTerm/LocalProcessInputTransport.swift`、`Tests/SwiftTermTests/LocalProcessInputTransportTests.swift`
- LocalProcess SHA-256: `596e124e8ca5e52ac2c4d7305e461267b885bf2b743ea79477cb55037f72a7fd`
- Transport SHA-256: `eb4b42a103921bd55521e3811e252b70f26aaa75e99833dbd858cb155ef912b6`
- Tests SHA-256: `f8f7840156deb87375f690aea973f0527305ea8c2441519be787f28a108acdd2`

## Clean SwiftTerm Checkout
- path: `/Users/msl/msl_coding/MacSSH/ThirdParty/SwiftTerm-fork-clean`
- clone source: `https://github.com/canbyte0/SwiftTerm.git`（direct HTTPS，无 --reference / --shared / file:// / 复制对象）
- alternates: NONE
- baseline branch: `macssh-agent-local-input-transport`（Step 12 由 `git switch -c` 指向基线 commit 创建，无新 commit）
- baseline HEAD: `40d473b1fdb456d49cc04b7f253277fcb9ac3987`（parent `93abf601469e572faffed65f75d548c58afa3058`，tree `73724e99a9f9ad1a3d45315a41d0b0ce08c07d57`，subject `fix(renderer): scale fitted glyphs at draw time`）
- baseline fsck: exit 0（clean）
- candidate branch: `macssh-agent-local-input-transport`
- candidate HEAD: `40d473b1fdb456d49cc04b7f253277fcb9ac3987`（无 commit）
- staged: 0（`git diff --cached --name-only` 为空，未执行 git add）
- commit: NO
- push: NO

## Candidate Identity
- LocalProcess hash match: 3/3 内第 1 项 EXACT MATCH
- Transport hash match: 3/3 内第 2 项 EXACT MATCH
- Tests hash match: 3/3 内第 3 项 EXACT MATCH
- unexpected files: 无（candidate scope 恰为规则第 5 条 3 文件：1 M + 2 ??）
- diff check: `git diff --check` exit 0（无 whitespace 错误）

## Tests
### Focused Run 1
- executed: 27
- passed: 27
- skipped: 0
- failed: 0

### Focused Run 2
- executed: 27
- passed: 27
- skipped: 0
- failed: 0

### Focused Run 3
- executed: 27
- passed: 26
- skipped: 0
- failed: 1（`testPendingBeginPreservesHeldAdmissionOrder`，line 757 `XCTUnwrap` 失败：d3 结算回调未观察到）

### Full
- executed: 892（XCTest 107 + swift-testing 785）
- passed: 889
- skipped: 3（`reportAlternatesDoesNotConvertTextProducingKeysToCSIU`、`testKittySharedMemoryBoundsRejected`、`testKittySharedMemoryLoad`，Kitty/AppKit 环境类，与 R1 接受基线一致）
- failed: 0

### Real PTY
- ABCD: PASS（`testRealPtyByteOrderOrdinaryAndTransaction`，full suite 内执行）
- terminate: PASS（`testRealPtyTransactionWriteFailsAfterTerminate`，full suite 内执行）

## Repository Integrity
- baseline fsck exit: 0
- final fsck exit: 0（无 alternates 告警、无缺失对象、无 commit-graph 解析错误）
- missing objects: 0
- alternates warning: NONE（clean checkout）
- commit graph error: NONE（clean checkout）

## Remote Isolation
- accepted baseline remote: `refs/heads/macssh-vs16-one-cell-render-fit` → `40d473b1fdb456d49cc04b7f253277fcb9ac3987`（匹配）
- clean candidate remote branch: 空（`macssh-agent-local-input-transport` 不存在于 origin）
- MacSSH B1 remote branch: ABSENT（MacSSH checkout 无 origin 远端配置，push 物理不可能）

## Audits
- secrets: 0（唯一命中为测试文件头注释"声明不含真实凭据"）
- payload logging: NO（Transport 文件无 print/NSLog/os_log/Logger；`debugIO` 显式开关行为保持于 `LocalProcess.swift`）
- renderer/VS16 changes: 无（grep AppleTerminalView|Metal|RasterContainment|GlyphFit|VariationSelector 无命中）
- whitespace: clean（diff --check exit 0）
- staged: 0（两个仓库均未 git add）

## Findings

### P1
- count: 0
- items: 无

### P2
- count: 1
- items:
  1. **Focused 用例偶发 flaky（候选自带，非恢复引入）**：Focused Run 3 中 `testPendingBeginPreservesHeldAdmissionOrder` 于 `LocalProcessInputTransportTests.swift:757` 失败（`XCTUnwrap`：D3 的 settled 回调未在断言前观察到）。定性复跑：单独重复 8 轮该用例，第 6 轮再次失败（约 1/10 概率）。三个必跑轮次中第 1、2 轮通过。三文件 SHA-256 与 R1 接受候选逐字节一致，故该 flaky 为 R1 接受候选固有属性，不是 clean checkout 引入；R1 独立验收时的 27/27 属于未触发该竞态。本阶段为字节保全恢复，候选冻结，不得修改测试代码，故如实按规则记 P2。

### P3
- count: 4
- items:
  1. 3 个 Kitty/AppKit 环境类 skip（与接受基线一致）。
  2. 旧 checkout 保持 corrupt 但已保全（alternates 死路径 stderr 告警仍会在 git 命令时复现）。
  3. clean checkout 占用额外磁盘空间（两套 checkout 并存，等待独立验收裁决 canonical 归属）。
  4. MacSSH 尚未消费 clean checkout（Package.resolved / ThirdParty 引用均未改动）。

## Decision

P1 = 0，P2 = 1 → **不满足 FINAL PASS 条件（hard gate: focused tests 0 failed 未在全部三个必跑轮次成立）**。

除该 flaky 用例外，本阶段全部恢复目标达成：

- SwiftTerm clean repository: VERIFIED（self-contained、无 alternates、fsck 0/0/0）
- Accepted transport candidate: BYTE-PRESERVED（3/3 SHA-256 与旧 checkout、/tmp 导出三处一致）
- Baseline: 40d473b1fdb456d49cc04b7f253277fcb9ac3987（EXACT）
- Full SwiftTerm: 892 / 889 / 3 / 0（与 R1 接受参考完全一致）
- Real PTY: PASS ×2
- Old corrupt checkout: PRESERVED
- NO COMMIT. NO PUSH.（MacSSH 与 SwiftTerm 两侧）

后续建议（供独立验收参考，不自行授权）：
- 由独立验收裁决该 P2 flaky 的处置（例如下一 stage 以最小 diff 修复 `testPendingBeginPreservesHeldAdmissionOrder` 的时序依赖，或接受为已知 flaky 放行）。
- 在 flaky 修复或豁免决定之前，不建议将 clean checkout 提升为 canonical 或启动 B2 Local send_to_terminal / B3 Remote 集成。

STOP. 等待独立验收。
