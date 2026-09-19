# Phase 10F-B1 — Interactive Terminal Mutation Domain + Approval Model

## Repository
- path: `/Users/msl/msl_coding/MacSSH`
- starting branch: `main`
- starting HEAD: `e958750643aeb9992d4cb357e91dc084130224eb`
- ending branch: `feature/macssh-1.1-agent-terminal-mutation`（自 main `e9587506` 创建）
- ending HEAD: `e958750643aeb9992d4cb357e91dc084130224eb`（零 commit，候选全部 uncommitted）
- staged: 0
- commit: NO
- push: NO

## Scope
- Provider registration: NOT IMPLEMENTED（工具注册表仍恰 5 个；`send_to_terminal` 仍处 prohibitedNames）
- terminal I/O: NOT IMPLEMENTED（B1 止步 REDEEM；无任何终端字节注入路径）
- SwiftTerm modified: NO（fork HEAD 与 Package.resolved pin 均 `40d473b1fdb456d49cc04b7f253277fcb9ac3987`）
- file mutation: NOT IMPLEMENTED（Phase 10F-C 独立）
- Phase 10E refactor: NONE（`run_command` / `AgentCommandRequest` / `AgentCommandApprovalCoordinator` / 双 executor 零改动；`git diff` 仅 `project.pbxproj`）

## Domain
- request type: `AgentTerminalMutationRequest`（immutable value object，全 `let`，`fileprivate init`，唯一构造入口 `AgentTerminalMutationRequestFactory`）
- target identity type: `AgentTerminalInputTargetIdentity`（logicalSessionID + inputTargetEpoch + endpointToken 三元；10F-A-R1 §R1.6 冻结语义）
- epoch type: `AgentTerminalInputTargetEpoch = UInt64`（窄类型别名；单调替换语义由 B2/B3 endpoint 生命周期保证）
- endpoint token type: `AgentTerminalEndpointToken`（UUID 型 opaque 非 secret；`static generate()` 唯一入口，Provider 结构上不可提供；诊断仅 `shortDescription` 8 hex 前缀）
- authorization type: `AgentTerminalMutationExecutionAuthorization`（opaque capability：approvalID/generationID/callID/logicalSessionID/targetIdentity/immutable request/permit；identity+binding only，无 I/O、无解析闭包）
- immutable fields: generationID / callID / logicalSessionID / targetIdentity(epoch+token) / targetSnapshot(Local|remote hostDisplay) / text / submit / providerBinding（复用 10E `AgentCommandProviderBinding`，语义不变）/ createdAt

## Validation
- UTF-8 min: 1 byte
- UTF-8 max: 65,536 bytes（64 KiB；`AgentTerminalMutationLimits.maxPayloadBytes`）
- multiline: 允许（LF U+000A 唯一放行控制标量；10F-A 冻结）
- submit: `Bool` 逐次必填语义；`submit == false` 只承诺不追加 CR，**不承诺“不执行”**（10F-A-R1 §R1.5）
- rejected controls: NUL(U+0000)；C0 U+0001–U+001F 除 LF（含 TAB/VT/FF/ESC）；CR(U+000D)；DEL(U+007F)；C1(U+0080–U+009F)——合计 64 标量，逐一测试
- normalization: 无（不 trim / 不重写 / 不插删换行 / 不做 CR-LF 转换 / 不做 Unicode normalize；命中拒绝集即拒绝该表示）

## Approval
- coordinator: `AgentTerminalMutationApprovalCoordinator`（terminal-mutation 专属，不与 command coordinator 复用类型；结构与已验收 10E 状态机同构）
- concurrency primitive: `actor`（register/approve/deny/cancel/claim/redeem/waiter 全部串行化）
- states: `awaitingApproval → approved | denied | cancelled`；`approved → executionClaimed`；`executionClaimed → redeemed`（终态：denied/cancelled/redeemed）
- approve: 仅 `awaitingApproval → approved`，恰好一次 `performed`，败者 `alreadyResolved`
- deny: 终局；零授权；不可后续 approve/claim/redeem（userDenied 与 cancelled 严格区分）
- cancel: `cancelApproval` 取消 awaiting/approved；`cancelGeneration` / `cancelSession` 额外失效 **已 claim 未 redeem** 的授权（§39 冻结规则：permit 置空 → redeem `approvalStale`）；`redeemed` 终态不可取消
- claim: CAS `approved → executionClaimed`；逻辑绑定（generation/session/provider）不符 → `bindingMismatch`；incarnation 绑定（epoch/token）不符 → `targetReplaced`
- redeem: permit 单次消费；重复消费 → `approvalAlreadyConsumed`；返回冻结 immutable 原 request
- replay: 同 `(generationID, callID)` 重复 register 幂等返回原 approvalID，绝不产生第二审批；late approve/claim/redeem 全部拒绝
- generation replacement: `cancelGeneration` 确定性失效旧审批（late approve → `alreadyResolved(.cancelled)`、claim → `approvalCancelled`），不依赖 UI 消失

## Binding
- generationID: bound（claim 期望 + immutable request）
- callID: bound（register 幂等键 + immutable request；不同 callID = 不同 mutation，即使 text/submit 完全相同）
- logicalSessionID: bound（claim 期望 + immutable request）
- inputTargetEpoch: bound（claim 期望不符 → `targetReplaced`）
- endpointToken: bound（claim 期望不符 → `targetReplaced`；sessionID 相等绝不构成授权）
- text: bound（coordinator 保存 immutable request；redeem 原样返回，逐字节断言 ASCII/Chinese/Emoji/组合序列/多行）
- submit: bound（`{text,false}` ≠ `{text,true}` 为不同 request，授权不互换）
- provider snapshot: bound（复用 10E `providerSnapshotID` 期望校验；Provider B 快照身份不可消费 Provider A 审批）
- active-tab fallback: 结构性禁止（gate 测试扫描 `activeSession`/`SessionManager`/`selectedTab`/`firstTerminal`/`matchingHostname`/`ActiveInputTarget`/`CommandSource` = 0）

## Security Boundaries
- run_command separation: 类型级分离（独立 request/identity/approval/coordinator；gate 断言 mutation 域不引用 command coordinator 类型）
- TerminalCommandDispatcher dependency: 0（gate token 扫描）
- TerminalView.pasteText: 0（gate token 扫描）
- LocalProcess.send: 0（gate token 扫描）
- SSHConnection.writeChannelInput: 0（gate token 扫描；生产域无 `libssh2_` / `channel_write`）
- persistent approval: 无（gate 扫描 alwaysAllow / allowForSession / trustTerminal / trustHost / allowSimilar / autoApprove / safeMutation = 0）
- auto approval: 无（每次 mutation 逐次审批；无任何豁免分类器）

## Tool Gate
- count: 5
- names: get_terminal_context / get_current_directory / list_directory / read_file / run_command
- send_to_terminal registered: NO（names 不含且 prohibitedNames 含）
- write_file registered: NO（同上；create/delete/rename/mkdir/move/copy/chmod/chown 全部保持禁止）

## Tests
### Focused
- command: `xcodebuild test-without-building -project MacSSH.xcodeproj -scheme MacSSH -destination 'platform=macOS' -only-testing:…`（12 个类：B1 新 5 类 + 10E 命令审批/工具门 7 类）
- executed: 165
- passed: 165
- skipped: 0
- failed: 0

### Full
- command: `xcodebuild test-without-building -project MacSSH.xcodeproj -scheme MacSSH -configuration Debug -destination 'platform=macOS' -skip-testing:MacSSHTests/SessionManagerTests/testO_CloseWhileConnectingCancelsConnection`（既有用例级排除不变）
- executed: 1193
- passed: 1053
- skipped: 140（与基线同源：Remote live SSH fixture 缺失自跳等，未新增跳过类别）
- failed: 0
- Remote live: NOT RUN（fixture `/tmp/macssh_phase6_ed25519` 缺失；本阶段亦无 live 交付路径可测）

## Builds
### Debug
- result: TEST BUILD SUCCEEDED（test build）+ `Scripts/build-app.sh` Debug BUILD SUCCEEDED
- production warnings: 0

### Release
- result: BUILD SUCCEEDED（`Scripts/build-app.sh`）
- production warnings: 0

## SwiftTerm
- expected revision: `40d473b1fdb456d49cc04b7f253277fcb9ac3987`
- actual revision: `40d473b1fdb456d49cc04b7f253277fcb9ac3987`（`git -C ThirdParty/SwiftTerm-fork rev-parse HEAD`；Package.resolved pin 一致）
- source modified: NO

## Files
### Added
- `MacSSH/Services/Agent/TerminalMutation/AgentTerminalInputTargetIdentity.swift`
- `MacSSH/Services/Agent/TerminalMutation/AgentTerminalMutationValidation.swift`
- `MacSSH/Services/Agent/TerminalMutation/AgentTerminalMutationRequest.swift`
- `MacSSH/Services/Agent/TerminalMutation/AgentTerminalMutationApproval.swift`
- `MacSSH/Services/Agent/TerminalMutation/AgentTerminalMutationApprovalCoordinator.swift`
- `MacSSH/Services/Agent/TerminalMutation/AgentTerminalMutationExecutionAuthorization.swift`
- `Tests/SSH/AgentTerminalMutationTestSupport.swift`
- `Tests/SSH/AgentTerminalMutationRequestTests.swift`
- `Tests/SSH/AgentTerminalMutationValidationTests.swift`
- `Tests/SSH/AgentTerminalMutationApprovalCoordinatorTests.swift`
- `Tests/SSH/AgentTerminalMutationApprovalConcurrencyTests.swift`
- `Tests/SSH/AgentTerminalMutationSecurityGateTests.swift`

### Modified
- `MacSSH.xcodeproj/project.pbxproj`（+58/−2：6 生产文件 + 6 测试文件的 build/file/group/Sources 登记；objectVersion 56 经典组必须显式登记才能编译；2 行“删除”为被重写重插的相邻行，内容无损失）

### Deleted
- 无

### Renamed
- 无

### Existing Untracked Docs
- count: 15（含 `Docs/Phase10F-A-Mutation-Tools-Architecture.md`；未触碰、未 stage）

### Unexpected
- 无

## Audits
- secrets: 0（diff 与新文件仅含类型标识符（`…ExecutionAuthorization`）与测试 gate token 清单字符串；fixture 使用 `example.invalid` 假域与占位文本，无真实凭据）
- payload logging: 新生产代码无任何 `print` / `os_log` / `Logger` 调用；`description`/`debugDescription` 全部显式 redacted（payload 只出字节计数，token 只出 8 hex 前缀）
- whitespace: `git diff --check` 0 错误
- staged files: 0

## Findings

### P1
- count: 0
- items: —

### P2
- count: 0
- items: —

### P3
- count: 4
- items:
  1. Remote live SSH fixture 仍缺失（既有 P3；B1 无 live 交付路径，不适用）。
  2. 本项目使用 objectVersion 56 经典 pbxproj，新文件必须显式登记——`project.pbxproj` 是 B1 唯一 tracked 变更（最小构建系统理由）。
  3. `inputTargetEpoch` 单调替换 / endpoint 对象捕获语义属 B2/B3 endpoint 生命周期，B1 仅冻结 immutable identity 契约与 `targetReplaced` 确定性拒绝（任务书 §10 预期形态）。
  4. 既有 15 个验收/架构 Docs 保持 untracked 未 stage；transport writer（Local acknowledged PTY / Remote delivered-byte 变体）按计划属 B2/B3，未实现。

## Decision

PHASE 10F-B1 FINAL PASS

Interactive terminal mutation domain:
IMPLEMENTED

Per-call approval state machine:
IMPLEMENTED

Immutable terminal target binding:
IMPLEMENTED

Exactly-once approval claim/redeem:
IMPLEMENTED

Transport execution:
NOT IMPLEMENTED

Provider registration:
NOT IMPLEMENTED

NO COMMIT.
NO PUSH.

READY FOR INDEPENDENT ACCEPTANCE.

STOP.
