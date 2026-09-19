# Phase 10F-B3-S2-R2 — Manual Plugin Trust + Final Re-Acceptance

- 日期：2026-09-15
- 阶段：Phase 10F-B3-S2-R2（Manual SwiftPM Plugin Trust + Final Re-Acceptance）
- 性质：**纯验证 / 信任流程**。production changed: **NO**；tests changed: **NO**；repository changed: **NO**。
- 结论：**PHASE 10F-B3-S2-R2 FINAL PASS**（P1 = 0，P2 = 0），NO COMMIT / NO PUSH，等待独立验收。

---

## 1. Repository

| 项 | 值 |
|---|---|
| 路径 | `/Users/msl/msl_coding/MacSSH` |
| branch | `feature/macssh-1.1-agent-terminal-mutation` |
| HEAD | `e958750643aeb9992d4cb357e91dc084130224eb`（未变） |
| staged | `0`（`git diff --cached --name-only` 空） |
| `git diff --check` | clean（0 行） |
| tracked modified | 11（与 R1 §2.1 完全一致） |
| commit / push | NO / NO |
| 工具链 | Xcode 27.0 (27A5252f)、`/Applications/Xcode-beta.app` |

## 2. Trust Restoration（§4–§8）

| 项 | 值 |
|---|---|
| R1 前原始备份存在性 | ✔ `/private/tmp/macssh-b3s2-r1-plugins.json.original` |
| 原始备份 SHA-256 | `08ee313251006eb00de2c7c4b869076238a5bc929da6a3312abc58d65341f398`（与期望值逐字节匹配） |
| R2 开始时（程序化态）SHA-256 | `cbd1fe5c7aec268bb5b7ed7ee73c60f77d7250156cdc1d5a60bbf38df3fa4269`（swiftterm/SwiftTermBuildInfoPlugin @ `040d1271…`，R1 刷新产物） |
| 程序化态备份 | ✔ `/private/tmp/macssh-b3s2-r2-plugins.json.programmatic`（sha256 `cbd1fe5c…`；仅作证据保全，不作最终信任权威） |
| 恢复动作 | `cp -p` 原始备份 → `/Users/msl/Library/org.swift.swiftpm/security/plugins.json`（权限 `-rw-r--r--`，158 bytes） |
| 恢复后 SHA-256 | `08ee313251006eb00de2c7c4b869076238a5bc929da6a3312abc58d65341f398`（精确匹配） |
| 恢复后条目 | `packageIdentity: swiftterm`，`targetName: SwiftTermBuildInfoPlugin`，`fingerprint: 40d473b1fdb456d49cc04b7f253277fcb9ac3987` ✔（§8，此后未手工编辑） |

## 3. Manual Xcode Trust（§10–§12）

| 项 | 值 |
|---|---|
| Xcode | 27.0 (27A5252f) GUI（`open -a Xcode-beta MacSSH.xcodeproj`） |
| 触发方式 | 工程打开 + 常规 package 解析 + 构建，使用工作区 pin 的 SwiftTerm `040d1271734694d046b77050b5bfc7aa483423ff` |
| bypass 开关 | 未使用任何 `-skipPackagePluginValidation` / `-skipMacroValidation` / defaults 注入 / security-store 脚本 |
| 弹窗 | Xcode 显示 SwiftTerm 插件信任/启用对话框（SwiftTermBuildInfoPlugin / package SwiftTerm） |
| 批准者 | **用户本人**（代理未代点任何按钮；见下强制字段） |
| 无弹窗 STOP 情形 | 未发生 |

```
USER MANUAL TRUST ACTION: YES
  （用户在 Xcode 27.0 UI 中亲眼看到 SwiftTermBuildInfoPlugin 的信任/启用弹窗，
   并本人点击了 Trust & Enable / Enable；
   代理以交互问答形式取得用户显式确认，未代替用户点击。）
```

### 3.1 Post-UI Trust Record（§13）

| 项 | 值 |
|---|---|
| 批准后 SHA-256 | `b97b3a6f559faa781dc03e789dbcc33b7681491dccae4c65e3233ac096c03d06` |
| SwiftTerm 条目 | `packageIdentity: swiftterm`，`targetName: SwiftTermBuildInfoPlugin`，**`fingerprint: 040d1271734694d046b77050b5bfc7aa483423ff`** ✔（与要求精确匹配） |
| 批准后是否被 agent/script 编辑 | **NO**（§13/§14 仅只读 inspection/diff） |

### 3.2 Trust Delta Audit（§14）

与恢复态（原始备份）逐行 diff：

```
3c3
<     "fingerprint" : "40d473b1fdb456d49cc04b7f253277fcb9ac3987",
---
>     "fingerprint" : "040d1271734694d046b77050b5bfc7aa483423ff",
```

- 语义 delta：**仅** SwiftTermBuildInfoPlugin fingerprint 一条 `40d473b1… → 040d1271…` ✔
- 无关插件信任条目变化：**0**（未触发 STOP）

## 4. Validation（§15 / §18）

- 全新目录（mktemp，未复用 R1 的任何 package/DerivedData）：
  `PKG_DIR=/tmp/macssh-b3s2-r2-packages.QTxPvD`、`DD_DIR=/tmp/macssh-b3s2-r2-derived.ZI6iuh`
- `xcodebuild -resolvePackageDependencies`（无 bypass）→ `Resolve Package Graph` / `Resolved source packages: SwiftTerm @ 040d127, swift-argument-parser @ 1.8.2` ✔
- 插件执行证据（等价三要素，无 validation bypass）：
  1. **Validate/编译**：activity log（gunzip 后 `/private/tmp/macssh-b3s2-r2-debug-activity.log`）显示从 checkout 的 `Plugins/SwiftTermBuildInfoPlugin/plugin.swift` 真实编译为插件可执行体（`PluginExecutables/SwiftTermBuildInfoPlugin`）；
  2. **Apply**：`Apply build tool plug-in “SwiftTermBuildInfoPlugin” to target “SwiftTerm” in package “swiftterm”`（Debug 日志 L22）；
  3. **Generated**：`…/BuildToolPluginIntermediates/swiftterm.output/SwiftTerm/SwiftTermBuildInfoPlugin/Generated/SwiftTermBuildInfo.swift` 存在。
- **所有最终命令 bypass grep 计数 = 0**（resolve / build-debug / build-for-testing / focused / regression / router / full / build-release 逐一审计）。

## 5. Dependency（§16–§17）

| 项 | 期望 | 实测 |
|---|---|---|
| 隔离 checkout URL | `https://github.com/canbyte0/SwiftTerm.git` | ✔（`Package.resolved` location / `project.pbxproj` repositoryURL；checkout origin 为本地 mirror，上游即该 URL，与 R1 相同机制） |
| HEAD | `040d1271734694d046b77050b5bfc7aa483423ff` | ✔ |
| parent | `40d473b1fdb456d49cc04b7f253277fcb9ac3987` | ✔ |
| tree | `973bdd4a1c4fc1879b0b2d9e3dc3f3f5f087fc8c` | ✔ |
| 本地 path 依赖 | 无 | ✔（`kind = revision`，remoteSourceControl；`pbxproj` L1496 `revision = 040d1271…`、`Package.resolved` `"revision" : "040d1271…"`） |

## 6. B3-S2 Focused（§19）

`AgentRemoteTerminalMutationTests`（fresh DD，test-without-building，无 bypass）：

**`Executed 19 tests, with 0 failures` → `** TEST EXECUTE SUCCEEDED **`**
xcresult：`/private/tmp/macssh-b3s2-r2-focused.xcresult` — **READABLE**，`result=Passed passed=19 skipped=0 failed=0 total=19`。19/19 全部 PASS。

## 7. Replay（§20）

- `testConcurrentReplayStressFiftyRounds`：50 轮 **PASS**（每轮恰一次物理投递，无重复字节）。
- 佐证变体：`testSequentialReplayAddsNoRemoteTransactionOrBytes`、`testConcurrentReplayHasOneWinner`、`testMultipleRemoteExecutorsShareCoordinatorLedger` 全 PASS。
- **Remote authorization replay stress = 50/50 PASS**（exactly-once Remote side effect 保持成立）。

## 8. Reconnect（§21）

- `testOldAuthorizationCannotTargetReplacementEpochOrToken` **PASS**（旧 epoch+token 对替换 shell 无法重定向；replacement shell 0 bytes）。
- `testExactB3CapabilityWinsWhenConnectionsShareNumericGeneration` / `testInvalidatedRemoteEndpointNeverStartsDelivery` PASS。
- **Reconnect retarget stress = 50/50 PASS（stress 三类交错之一为 replacement during partial write × 50）；0 bytes to replacement shell**。

## 9. Partial Matrix（§22）

| 维度 | 用例 | 结果 |
|---|---|---|
| START 0…6 | `testPartialStartMatrixNeverSendsPayloadOrRepair` | PASS |
| payload partial/full | `testPartialPayloadRecordsPrefixAndUsesOnlyOneRepairEnd` | PASS |
| repair END 恰一次 | 同上 + `testPartialEndMatrixNeverRetriesOrSubmits`（END 0…6） | PASS |
| CR 0/1 | `testCarriageReturnIsNeverRetried` | PASS |
| mode ON/OFF | `testModeOnUsesCanonicalFrameAndOptionalCR` / `testModeOffOmitsFramingAndKeepsSubmitIndependent` | PASS |
| cancellation | `testCancellationBeforePhysicalWriteProducesZeroBytes` | PASS |
| connection loss | `testConnectionLossPreservesPrefixWithoutReconnectOrRetry` | PASS |
| target replacement | `testOldAuthorizationCannotTargetReplacementEpochOrToken` | PASS |

**0 failed。**

## 10. B3-S1 Regression（§23）

`RemoteTerminalTests`（24 用例：1 passed + 23 live SSH self-skip）+ `RemoteInteractiveInputTransportTests`（13 用例，含 **`testStressB3OrderingReattachAndReplacementAtLeast50Iterations` = 50 轮 × {pending ordering, late-delegate reattach, replacement during partial write} = 150/150 PASS**）。

**0 failed；150/150 high-risk stress PASS。**

## 11. Local Regression（§24）

`AgentLocalTerminalMutationTests`（17 用例）：**0 failed**。✔ Local S3/S3-R1。

## 12. B1（§25）

`AgentTerminalMutationRequestTests`(7) + `ValidationTests`(13) + `ApprovalCoordinatorTests`(22) + `ApprovalConcurrencyTests`(8) + `SecurityGateTests`(11)：**0 failed**。

## 13. Phase 10E（§26）

`AgentCommand{Request,Validation,ApprovalCoordinator,ApprovalConcurrency,SecurityGate}Tests`(68) + `AgentLocalCommandExecutor{,Output,Security,Cancellation}Tests`(63) + `AgentRemoteCommand{Builder,SSHTransport,Executor}Tests`(65) + `AgentRemoteCommandExecutor{Cancellation,Security}Tests`(22) + `AgentToolLoopTests`(26) + `AgentRemoteRouterTests`(11)：**0 failed**。

## 14. DependencyIdentity（§27）

`DependencyIdentityTests`(11)：**0 failed**。

## 15. Provider Gate（§28）

- `AgentToolName` 恰 5 case：`get_terminal_context` / `get_current_directory` / `list_directory` / `read_file` / `run_command`（`AgentProviderToolGateTests` 11 用例全 PASS，含 `testCatalogStillHasExactlyFiveToolsAndNoMutationTool`）。
- **tool count = 5 ✔；`send_to_terminal` = NOT REGISTERED ✔；`write_file` = NOT REGISTERED ✔**（`AgentProviderToolCallingTests` 20 用例全 PASS，prohibitedNames/parser 拒绝集合用例保持 PASS）。

## 16. Full Universe（§29–§32）

命令要点：fresh `DD_FULL=/tmp/macssh-b3s2-r2-derived-full.wVrjTP`（mktemp）+ `PKG_DIR=…QTxPvD`、无 bypass、显式 `-resultBundlePath /private/tmp/macssh-b3s2-r2-full.xcresult`、持久日志 `/private/tmp/macssh-b3s2-r2-full.log`、仅历史 blackhole 排除。

```
** TEST SUCCEEDED **
Executed 1243 tests, with 140 tests skipped and 0 failures (0 unexpected) in 168.365 seconds
```

Result bundle gate：

| 要求 | 实测 |
|---|---|
| exists | ✔（12 MB） |
| readable | ✔ `xcrun xcresulttool get test-results summary` exit 0 |
| Passed | ✔ `result=Passed` |
| summary available | ✔ `passed=1103 skipped=140 failed=0 total=1243`，`testFailures` 空 |

Test arithmetic（`-enumerate-tests` → `/private/tmp/macssh-b3s2-r2-enum.txt`）：

| 项 | 值 |
|---|---|
| discovered | **1244** |
| 外部排除 | **1**（`SessionManagerTests/testO_CloseWhileConnectingCancelsConnection`，历史 blackhole，未扩大） |
| selected / executed | **1243** |
| passed | **1103** |
| self-skipped | **140**（全为夹具/凭据不可用，类别与 R1 基线一致，无新增） |
| failed | **0** |

对账：`1244 = 1243 + 1` ✔；`1243 = 1103 + 140` ✔ — 无未解释用例，与 R1 完全一致。

Regression 合并（Section 10–15 两次串行 invocation）：`401 + 11(AgentRemoteRouterTests) = 412 executed / 389 passed / 23 skipped / 0 failed` — 与 R1 的 412 精确一致（R1 报告中 `AgentRemoteCommandRouterTests` 实为 `AgentRemoteRouterTests`，11 用例；`RemoteTerminalTests` 类含 24 方法，R1 §9 的「37 用例」为笔误，实际 24 executed = 1 passed + 23 self-skip）。

## 17. Debug / Release（§33–§34）

| 构建 | 结果 | warning | bypass |
|---|---|---|---|
| Debug（fresh `DD_DIR`） | **BUILD SUCCEEDED** | `warning:` = **0**（生产源码 0） | 0 |
| build-for-testing（同 DD） | **TEST BUILD SUCCEEDED** | 38 行（全部位于 `Tests/SSH/*`，与 R1 同集） | 0 |
| Release（fresh `DD_REL=/tmp/macssh-b3s2-r2-derived-rel.RJojab`） | **BUILD SUCCEEDED** | `warning:` = **0** | 0 |

## 18. Candidate Preservation（§35）

- 开始快照：`/private/tmp/macssh-b3s2-r2-candidate-hashes.txt`（450 tracked 文件）
- 结束快照：`/private/tmp/macssh-b3s2-r2-candidate-hashes-after.txt`
- diff：`/private/tmp/macssh-b3s2-r2-hash-diff.txt` = **0 行** → **0 candidate byte changes** ✔
- 仓库唯一状态变化（在仓库之外）：SwiftPM 用户级信任记录由**显式 Xcode 用户批准**更新（§3）。
- staged 0、HEAD 未变、无 commit、无 push。

## 19. Remote Verification（§36）

| 项 | 期望 | 实测 |
|---|---|---|
| MacSSH `main` | `e958750643aeb9992d4cb357e91dc084130224eb` | ✔（`git rev-parse main`；`github/main` 同值） |
| 远端 `feature/macssh-1.1-agent-terminal-mutation` | ABSENT | ✔（`git ls-remote` 无输出） |
| SwiftTerm `macssh-agent-local-input-transport` | `040d1271734694d046b77050b5bfc7aa483423ff` | ✔（隔离 checkout branch tip） |
| push | NO | ✔ |

## 20. P1 / P2 / P3

### P1 — 0

Remote mutation 安全边界无回归；同 authorization 未二次注入（replay 50/50）；无 reconnect retarget；无 payload logging。

### P2 — 0

| 判据 | 结论 |
|---|---|
| user manual trust action did not occur | **NO**（用户显式批准，见 §3） |
| agent/script 直接编辑最终 trust fingerprint | **NO**（批准后仅只读；最终态由 Xcode UI 写入） |
| Xcode trust prompt 被绕过 | **NO** |
| validation bypass flag 使用 | **NO**（8 份日志逐一 grep = 0） |
| post-approval fingerprint 错误 | **NO**（`040d1271…` 精确匹配） |
| 无关 trust 条目变化 | **NO**（delta 恰一行） |
| full universe 失败/不完整 | **NO**（1243/1103/140/0，算术闭合） |
| xcresult 不可读 | **NO**（READABLE，`result=Passed`） |
| Debug/Release 失败 | **NO**（均 SUCCEEDED，0 生产 warning） |
| candidate bytes 意外变化 | **NO**（diff 0 行） |
| 新增外部排除 | **NO**（仅历史 1 条） |

### P3 — 4（均为任务书 §41 允许项）

1. 历史 blackhole 外部排除（`testO_CloseWhileConnectingCancelsConnection`，环境型，未扩大）。
2. Remote live 夹具 self-skip（`/tmp/macssh_phase6_ed25519` 缺失 → 140 条 self-skip，类别未新增）。
3. 旧损坏 SwiftTerm checkout（`ThirdParty/SwiftTerm-fork*`）保全未动。
4. Xcode 用户级插件信任记录有意记下已接受的 pinned revision（`040d1271…`，本阶段经真实 GUI 用户批准）。

## 21. Evidence Index

| 用途 | 路径 |
|---|---|
| 信任原件备份（R1 前原始态） | `/private/tmp/macssh-b3s2-r1-plugins.json.original`（`08ee3132…`） |
| 程序化态备份（R2 开始） | `/private/tmp/macssh-b3s2-r2-plugins.json.programmatic`（`cbd1fe5c…`） |
| 恢复后/批准后实况 | `/Users/msl/Library/org.swift.swiftpm/security/plugins.json`（`b97b3a6f…`，fingerprint `040d1271…`） |
| 解析日志 | `/private/tmp/macssh-b3s2-r2-resolve.log` |
| Debug 构建 + activity log | `/private/tmp/macssh-b3s2-r2-build-debug.log`、`…-debug-activity.log` |
| build-for-testing | `/private/tmp/macssh-b3s2-r2-build-for-testing.log` |
| focused | `/private/tmp/macssh-b3s2-r2-focused.{log,xcresult}` |
| regression（27 套件） | `/private/tmp/macssh-b3s2-r2-regression.{log,xcresult}` |
| Router 补充 | `/private/tmp/macssh-b3s2-r2-router.{log,xcresult}` |
| 全量宇宙 | `/private/tmp/macssh-b3s2-r2-full.{log,xcresult}` |
| 枚举（discovered） | `/private/tmp/macssh-b3s2-r2-enum.txt` |
| Release 构建 | `/private/tmp/macssh-b3s2-r2-build-release.log` |
| 候选哈希（前/后/diff） | `/private/tmp/macssh-b3s2-r2-candidate-hashes{,-after}.txt`、`…-hash-diff.txt`（0 行） |
| 隔离目录 | `PKG_DIR=…-packages.QTxPvD`、`DD_DIR=…-derived.ZI6iuh`、`DD_FULL=…-derived-full.wVrjTP`、`DD_REL=…-derived-rel.RJojab`（清单 `/private/tmp/macssh-b3s2-r2-dirs.txt`） |

## 22. Decision

```
USER MANUAL TRUST ACTION:      YES（用户在 Xcode 27.0 GUI 中本人点击 Trust & Enable）
agent/script final trust edit:  NO（最终信任态由 Xcode UI 写入，代理批准后仅只读）
post-approval fingerprint:      040d1271734694d046b77050b5bfc7aa483423ff
validation bypass flags:        NONE（8 份运行日志逐一 grep = 0）
full xcresult readable:         YES（result=Passed passed=1103 skipped=140 failed=0）
```

PASS Rule 核对：P1=0 ✔；P2=0 ✔；USER MANUAL TRUST ACTION: YES ✔；final trust fingerprint `040d1271…` ✔；programmatic final trust edit: NO ✔；validation bypass: NO ✔；full universe 0 failed ✔；xcresult READABLE ✔；Debug PASS ✔；Release PASS ✔；candidate repository bytes UNCHANGED ✔；tool count 5 ✔；`send_to_terminal` NOT REGISTERED ✔；commit NO ✔；push NO ✔。

```
PHASE 10F-B3-S2-R2 FINAL PASS

SwiftPM plugin trust:
EXPLICITLY USER-APPROVED

Remote Agent mutation:
ACCEPTED

Full universe:
CLOSED

Provider registration:
NOT IMPLEMENTED

NO COMMIT.
NO PUSH.

READY FOR INDEPENDENT ACCEPTANCE.
STOP.
```
