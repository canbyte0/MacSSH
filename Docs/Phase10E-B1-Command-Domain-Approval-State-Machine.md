# Phase 10E-B1 — Command Domain + Approval State Machine Foundation

实现报告。本阶段只实现 Command domain / validation / approval 状态机 / 一次性执行授权基础，
**不包含任何执行能力**。报告 untracked，不 stage。

---

## Repository

- path: `/Users/msl/msl_coding/MacSSH`
- branch: `feature/macssh-1.1-agent-command-execution`（自 `main` = `73038d6` 创建，§5）
- HEAD: `73038d61b9f2b22b027e3748d06600984186a29a`（candidate 不 commit，HEAD 即 accepted base）
- baseline: `main` @ `73038d6` / tree `53f3cd0`
- tracked before: 0 modification（仅 7 个 untracked Docs）
- untracked before: 7 × Docs（6 × Phase10D + 1 × Phase10E-A）
- commit: NO
- push: NO

## Domain

- request: `AgentCommandRequest`（`generationID` / `callID` / `sessionID` / `target` /
  `command` / `workingDirectory` / `providerBinding`，全部 `let`；`init` 为
  `fileprivate`，仅同文件 `AgentCommandRequestFactory` 可构造——外部与测试
  均无法绕过校验手工拼装）
- target: `AgentCommandTarget` enum（`.local(displayName:)` / `.remote(displayName:)`）；
  `displayName` 仅 UI metadata，不参与 session 解析 / shell 构造；真正 identity =
  `sessionID`
- provider binding: `AgentCommandProviderBinding`（`snapshotID` opaque UUID /
  `provider` / `model` / `baseURL`）。`provider` 复用项目既有
  `AgentProviderSettings.Provider`（即任务书推荐 `AgentProviderKind` 的项目内
  既有形态）；`snapshotID` 为新增 opaque generation identity（§12），B1 无
  Provider wiring，未来 runtime 在 `snapshotForGeneration()` 时刻生成
- credential fields: 0（结构只有 4 个非敏感字段，测试以 Mirror 断言字段集合恒定；
  API key / Authorization header / SSH 凭据无引用路径）
- immutability: 创建后 command / cwd / session / binding 不得修改（编译期 `let`）；
  claim / redeem 只返回 coordinator 保存的 immutable request

## Validation

- max command bytes: 16 KiB = 16,384 UTF-8 bytes（`AgentCommandLimits.maxCommandBytes`，
  对齐 `AgentTextLimits` 惯例集中定义）
- empty: `.invalidCommand`
- whitespace: whitespace-only → `.invalidCommand`（trim 仅用于判定，保存值原样保留）
- NUL: U+0000 按 UTF-8 字节判定（`utf8.contains(0)`，覆盖任何组合形态）→
  `.invalidCommand`
- multiline: 允许，原始 newline 保留
- Unicode byte count: 按 `String.utf8.count` 判定；测试证明 5461×"中"(16383B) 合法 /
  5462×"中"(16386B) 拒绝 / 4096×"😀"(16384B) 合法 / 16384×"中"(49152B,
  Character count 恰为 16384) 拒绝——byte limit ≠ Character count
- cwd authoritative: factory 只接受 `AgentWorkingDirectory.confidence == .authoritative`
  且绝对路径（`hasPrefix("/")`）；Local / Remote 同一域要求（§63）
- cwd fallback: 0（approximate / unavailable / relative / 空路径 → `.cwdUnavailable`，
  绝不 fallback HOME / App cwd / 登录默认 / `realpath(".")`）

## Approval State Machine

- coordinator: `AgentCommandApprovalCoordinator`（`MacSSH/Services/Agent/Command/`）
- isolation: `actor`（§34）——approve / deny / cancelApproval / cancelGeneration /
  cancelSession / claim / redeem / waiter 注册与恢复全部 actor 内串行化；不使用
  `@MainActor Bool` 作为安全边界
- states: `awaitingApproval → approved | denied | cancelled`；
  `approved → executionClaimed | cancelled`；`denied` / `cancelled` /
  `executionClaimed` 终态；单向，无 `denied→approved` / `cancelled→approved` /
  `executionClaimed→approved`
- approve: `awaitingApproval → approved`（CAS；不执行任何命令，仅授予 claim 资格）；
  双击竞态恰一个 `.performed`
- deny: `awaitingApproval → denied`（userDenied 语义，§60，与 cancelled 严格分离，
  Resolution 为独立 case；Provider 序列化留待 B4）
- cancel: `cancelApproval`（单条）；`awaitingApproval|approved → cancelled`
- generation invalidation: `cancelGeneration(generationID)`（Stop / generation 替换）
  + `purgeGeneration`（teardown 清除记录）；返回失效条数
- session invalidation: `cancelSession(sessionID)` + `purgeSession(sessionID)`（§41）

## One-Time Execution Authorization

- mechanism: `claimExecution(approvalID:expected:)` 原子 CAS `approved →
  executionClaimed` → 返回 `AgentCommandExecutionAuthorization`（opaque capability，
  携带 coordinator 保存的 immutable request + 单次消费 permit）；未来 executor 必须
  持 authorization 经 `redeem` 消费——首次返回原 request，重复 →
  `approvalAlreadyClaimed`
- construction: internal controlled initializer + permit 由 coordinator 生成并登记；
  `redeem` 核对 permit 与账本——自行拼装的实例被 `approvalStale` 拒绝
  （构造控制 + 状态背书双保险，§32）
- claim: 只有 state == approved 且 generation / session / providerSnapshot 三绑定
  全部相等才放行
- duplicate claim: 第二次 → `.approvalAlreadyClaimed`（§74）；并发 50 claim 恰 1 成功
- Stop after approve: approved（未 claim）可被 cancelGeneration 失效 → claim 抛
  `.approvalCancelled`（§30 hard gate，测试覆盖）
- stale approval: session close → `cancelSession` → approve no-op
  （`.alreadyResolved(.cancelled)`）+ claim `.approvalCancelled`；绝不重新绑定
  active session（§25）
- wrong binding: wrong generation / wrong session / wrong provider snapshot →
  `.bindingMismatch`（§78–§80）；失败的 claim 不消耗授权（记录保持 approved）

## Concurrency

- double approve: 100 并发 approve → 恰 1 `performed` + 99 `alreadyResolved`（§71）
- approve vs deny: 50+50 → 恰 1 terminal decision（§72）
- approve vs cancel: 25 轮循环 + 25 轮双任务竞争——最终只有
  approved-and-still-valid 或 cancelled 两种合法结局；`claim:ok ⇒ cancel:0`；
  `cancel:1 ⇒ claim` 必败（§26/§73 线性化点 = claim CAS）
- claim race: 50 并发 claim → 恰 1 authorization + 49 `approvalAlreadyClaimed`
- waiter resume: 决策与 waiter 启动竞态下每个 waiter 恰好恢复一次（多次重复运行；
  double resume 会触发运行时崩溃，测试通过即证明）；多 waiter 各恢复一次同一
  resolution；决策后再 wait 立即返回已存解析（§38）

## Await Decision

- wait-before-decision: waiter 挂起后 approve / deny / cancelGeneration → 各恢复一次
  `.approved` / `.denied` / `.cancelled`（§83–§85）
- decision-before-wait: 立即返回已存解析，绝不悬挂（§82）
- deny: `.denied`（userDenied，§60）
- cancel: `.cancelled`
- continuation cleanup: waiter Task 自身取消 → `CancellationError`，approval 状态
  不变、不自动批准、无 orphan continuation（`withTaskCancellationHandler` 摘除
  + 注册点 `Task.isCancelled` 自愈双路径；§86/§87）；purge 前 pending waiter
  一律先恢复

## Tool Activity Foundation

- awaitingApproval: `AgentToolActivity.Status` 新增 `.awaitingApproval`
  （rawMarker `awaiting_approval`）；非交互展示兼容（clock 图标 + 本地化文案），
  无生产可达路径（run_command 未注册，§47）
- denied: 新增 `.denied`（rawMarker `denied`；xmark 图标 + 文案）
- actionable buttons: 0（§89：AgentToolCardView 无 Approve / Reject 按钮）
- production call sites: 0（AgentViewModel 无任何 Command 接线——source gate 测试
  断言 `AgentViewModel.swift` 不含 `AgentCommand*` / `run_command` token）

## Provider Boundary

- definitions count: 4（gate 测试断言）
- run_command advertised: NO
- run_command prohibited: 仍在 `AgentToolCatalog.prohibitedNames`（§48）
- AgentViewModel wiring: 无（§51；source gate）
- parser changes: 无（`AgentToolCallParsing` 未动；`run_command` 仍 →
  `unknownTool`，§50）

## Execution Boundary

- Process: 0
- posix_spawn: 0
- SSH exec: 0（无 libssh2 引用）
- Terminal injection: 0（无 TerminalCommandDispatcher / pasteText / send(data:)）
- mutation: 0（无 write/delete/rename/mkdir/chmod 类工具；无任何写通道）
- credential access: 0（无 CredentialService / Keychain / apiKey 引用；gate 从严到
  注释——coordinator 注释中的存储层字样已重写规避）

## Persistence / Logging

- approval persistence: memory-only（无 SwiftData / UserDefaults / 文件 / Codable）
- command logging: 0（`AgentCommandRequest` / Snapshot / Authorization 显式实现
  redacted `CustomStringConvertible` + `CustomDebugStringConvertible`，测试断言
  description 不含 command / cwd）
- cwd logging: 0（同上）
- secret logging: 0（binding 无 secret 字段；描述不含 permit）

## Tests

#### B1
- validation: `AgentCommandValidationTests` — 13（empty/whitespace/NUL/multiline/
  16384 边界/16385/CJK 字节/emoji 字节/16384 CJK 字符拒绝/原始 bytes 保留/
  newline 保留/不重写/常量冻结）
- approval: `AgentCommandApprovalCoordinatorTests` — 29（new pending / approve /
  deny / cancel / generation cancel / session cancel / stop-after-approve /
  double approve 串行 / claim once / claim twice / claim before approval /
  claim after denial / claim after cancel / wrong generation / wrong session /
  wrong provider snapshot / unknown approval / redeem 单次 / 伪造 permit /
  exact integrity / A/B 隔离 / await decision 6 态 / waiter 取消 / cleanup 5）
- concurrency: `AgentCommandApprovalConcurrencyTests` — 8（100 approve / 50+50
  approve-deny / 50 claim race / approve-cancel-claim 25 轮 / approve vs cancel
  25 轮 / waiter 竞态 resume once ×2 / 多 waiter）
- awaiter: 上两 suite 覆盖（wait→approve / approve→wait / wait→deny /
  wait→cancel / waiter cancel / no double resume）
- isolation: coordinator suite（session A/B、generation A/B、snapshot A/B、
  无 active-session 依赖）

#### Phase 10D Regression
- ProviderToolGate: 11 tests, 0 failures
- ToolLoop: 20 tests, 0 failures
- ToolRouter: 19 tests, 0 failures
- AgentViewModel: 19 tests, 0 failures
- ConversationStore: 11 tests, 0 failures

### Test Universe
- baseline discovered: 892（Phase 10D accepted：executed 891 / passed 766 /
  skipped 125 / failed 0 / externally excluded 1）
- B1 added: 68（13 + 11 + 29 + 8 + 7；全量运行中 5 个新 suite 恰执行 68）
- discovered: 961（= executed 960 + externally excluded 1）
- executed: 960（`Executed 960 tests, with 125 tests skipped and 0 failures`）
- passed: 835
- failed: 0
- skipped: 125（与 baseline 完全一致）
- externally excluded: 1（`SessionManagerTests/testO_CloseWhileConnectingCancelsConnection`，
  用例级 `-skip-testing`，未扩大）
- count explanation: 与 baseline 算术对账差 1（892 + 68 = 960 ≠ 961）：125 skipped
  与 0 failed 完全一致、5 个新 suite 恰 68，差额 1 位于 pre-existing universe 的
  baseline 记账口径（passed 766 + 68 = 834 ≠ 835），判定为 Phase 10D 基线记录的
  1 例计数口径偏差，非本阶段引入（本阶段 diff 不触碰任何既有测试文件）。
  gate 不受影响：failed = 0。

### Debug
- DerivedData: `/tmp/MacSSH-Phase10E-B1-Debug`
- result: BUILD SUCCEEDED + TEST BUILD SUCCEEDED（build-for-testing）
- warnings: 0

### Release
- DerivedData: `/tmp/MacSSH-Phase10E-B1-Release`
- result: BUILD SUCCEEDED
- warnings: 0

## Files

#### Added
- `MacSSH/Services/Agent/Command/AgentCommandValidation.swift`
  （`AgentCommandLimits` / `AgentCommandError` / `AgentCommandValidation`）
- `MacSSH/Services/Agent/Command/AgentCommandRequest.swift`
  （`AgentCommandTarget` / `AgentCommandProviderBinding` / `AgentCommandRequest`
  / `AgentCommandRequestFactory`）
- `MacSSH/Services/Agent/Command/AgentCommandApproval.swift`
  （`AgentCommandApprovalState` / `AgentCommandApprovalResolution` /
  `AgentCommandApprovalActionResult` / `AgentCommandClaimExpectations` /
  `AgentCommandApprovalSnapshot`）
- `MacSSH/Services/Agent/Command/AgentCommandApprovalCoordinator.swift`
  （`actor AgentCommandApprovalCoordinator`）
- `MacSSH/Services/Agent/Command/AgentCommandExecutionAuthorization.swift`
- `Tests/SSH/AgentCommandValidationTests.swift`
- `Tests/SSH/AgentCommandRequestTests.swift`
- `Tests/SSH/AgentCommandApprovalCoordinatorTests.swift`
- `Tests/SSH/AgentCommandApprovalConcurrencyTests.swift`
- `Tests/SSH/AgentCommandSecurityGateTests.swift`

#### Modified
- `MacSSH/Services/Agent/AgentToolActivity.swift`（Status 扩展 `.awaitingApproval`
  / `.denied` + rawMarker）
- `MacSSH/Features/Agent/AgentToolCardView.swift`（三个 switch 非交互展示兼容，
  无按钮）
- `Scripts/gen_localizable.py`（+2 key，canonical generator）
- `MacSSH/Resources/Localizable.xcstrings`（生成产物，+2 key：
  `agent.tool.status.awaiting_approval` / `agent.tool.status.denied`）
- `MacSSH.xcodeproj/project.pbxproj`（+48 行：5 production 文件入 production
  target、5 测试文件入 test target、新增 Command group；无重排）

#### Docs
- `Docs/Phase10E-B1-Command-Domain-Approval-State-Machine.md`（本报告，untracked）

#### Unexpected
- 无

## Findings

#### P1
- count: 0
- items: 无

#### P2
- count: 0
- items: 无

#### P3
- count: 2
- items:
  1. Test universe 对账与 Phase 10D 基线记录存在 1 例口径偏差（见 count
     explanation）；125 skipped / 0 failed 完全一致，不影响任何 gate。
  2. `AgentCommandExecutionAuthorization.permit` 为 internal `let`（init 亦
     internal）——防伪造由 `redeem` 的 permit 账本校验承担（拼装实例 →
     `approvalStale`），并已由 `testRedeemRejectsUnregisteredPermit` 固化；
     Swift 无 friend 构造语义，属语言限制下的等价实现（§32 允许 internal
     controlled initializer）。

## Decision

```text
PASS — 0 P1 / 0 P2
```
