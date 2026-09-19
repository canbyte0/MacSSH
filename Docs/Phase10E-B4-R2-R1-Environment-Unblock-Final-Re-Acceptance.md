# Phase 10E-B4-R2-R1 — Environment Unblock + Final Re-Acceptance

日期：2026-09-13
仓库：`/Users/msl/msl_coding/MacSSH`
性质：VALIDATION ONLY（未修改任何 production / test / localization 源码）

## Repository
- path: `/Users/msl/msl_coding/MacSSH`
- branch: `feature/macssh-1.1-agent-command-execution`
- HEAD: `73038d61b9f2b22b027e3748d06600984186a29a`
- source changed: NO（validation-only；before/after diff 完全一致）
- staged: none
- commit: none
- push: none

## Tool Surface Reconciliation
- actual count: 5
- actual names: `get_terminal_context`, `get_current_directory`, `list_directory`, `read_file`, `run_command`
  - 证据：`AgentToolDefinition.swift` `AgentToolCatalog.definitions`（注释明确"恰好 5 个工具"）；
    `AgentToolModels.swift` `AgentToolName` 枚举 5 case；
    `AgentProviderToolGateTests.testCatalogContainsExactlyFourReadOnlyTools`（count=5 断言）；
    `AgentCommandSecurityGateTests` / `AgentRemoteCommandExecutorSecurityTests` 同名断言全绿。
- R2 report discrepancy: **REPORT TYPO**。
  R2 报告 §4 中的 `list_files` / `read_terminal_context` 为报告撰写错误；
  production registry 自 B4 起从未变更（静态枚举 + gate 测试锁死）。
  `R2 tool-surface naming was a reporting error. Production registry was unchanged.`
- production regression: none（未触发 STOP 条件）
- prohibited tools: `send_to_terminal` NOT REGISTERED；`write_file` NOT REGISTERED；`delete_file` NOT REGISTERED（均在 `prohibitedNames`，且 `AgentToolRegistry.lookup` 对未知名返回 nil → `unknownTool`）

## Provider Environment
- B4-R1 provider: DeepSeek `deepseek-v4-flash`（live E2E 已验证）
- current provider: DeepSeek `deepseek-v4-flash` / `https://api.deepseek.com`（UserDefaults `macssh.agent.*`）
- credential state: **A. Existing DeepSeek credential usable**
  - Keychain 条目 `com.macssh.MacSSH.agent`（account=`deepseek`）自 2026-09-08 存在；登录钥匙串已解锁（no-timeout）
- reason R2 could not use provider: R2 的新 ad-hoc 签名二进制不在该 Keychain 条目 ACL 内，
  securityd 弹出授权弹窗等待登录钥匙串密码，无人应答 → App 侧表现为"不可用"，
  测试侧表现为 `testDeleteRemovesKey` 无限等待。并非凭据缺失，也非 securityd 故障。
- secret exposed: NO（全程未打印 / 导出 / 记录 API key；仅查询条目元数据）

## Keychain Environment
- credential test: `security find-generic-password -s com.macssh.MacSSH.agent`（仅属性，不取密码）→ 存在
- DetachedSignatures: `/private/var/db/DetachedSignatures: No such file or directory` 为
  SQLite（logging-persist / os_unix.c）的良性日志噪音，**非环境损坏**：
  B4-R1 的 PASS full-suite 日志 `/tmp/macssh-b4r1-full-test.log` 同样含该行，
  且最终 `Executed 892 tests ... 0 failures`。
- root cause: 新 ad-hoc 二进制缺 Keychain ACL 授权 → securityd 弹窗等待用户输入
- environment fixed: 用户在弹窗输入登录钥匙串密码并"始终允许"后解除（正常用户流程，未修改系统 Keychain DB）
- product code changed: NO

## Running State Live
- provider: DeepSeek · deepseek-v4-flash（真实 live）
- command: `run_command("sleep 8")`
- awaitingApproval: YES（卡片 268×196，含 Approve/Deny）
- Approve: 真实 CGEvent 点击 `(2515,447)`（`axr.py clickxy`，非 AXPress 模拟）
- running: **MUST-GATE PASS** — 批准 1s 后卡片渲染"进行中"+ ProgressView（截图 `b4r2r1-gate6-running-card.png`）
- Approve during running: ABSENT（AX `find agent.command.approve` → NOTFOUND；截图无按钮）
- Deny during running: ABSENT（AX NOTFOUND；卡片高度 196→168 恰为按钮行移除）
- final state: `✓ 完成`，Agent 回复"命令已执行完成。"（截图 `b4r2r1-gate6-final-card.png`）
- evidence: `/tmp/b4r2r1-gate6-awaiting-card.png`、`b4r2r1-gate6-running-card.png`、
  `b4r2r1-gate6-final-card.png`、`b4r2r1-gate6-terminal-state.png`（终端无任何注入命令，仅 Last login 提示符）

## Accessibility Live
- card hierarchy: `.accessibilityElement(children: .contain)`（`AgentToolCardView.swift:52`）
- Approve role: AXButton（live AX dump）
- Approve identifier: `agent.command.approve`（acts=[AXScrollToVisible, AXPress]）
- Deny role: AXButton
- Deny identifier: `agent.command.deny`（acts=[AXScrollToVisible, AXPress]）
- Card AXPress: **无** — `agent.tool_card`（AXGroup）acts=[AXScrollToVisible] 仅此一项，无决策 AXPress
- running controls: Approve/Deny 均 NOTFOUND（absent）
- VoiceOver smoke: NOT RUN（可选项；本机未启动 VoiceOver 会话。静态 + AX hierarchy 证据已覆盖 spec 要求）
- evidence: `/tmp/b4r2r1-actions.py` 输出（awaiting 态三元素 role/acts 实测）

## Disclosure
- old text: "不会执行任何命令" — `Localizable.xcstrings` 与 `gen_localizable.py` 中 0 命中；live AX 树 0 命中
- current text semantics: "随时提问——Agent 可读取终端上下文与当前目录中的文件。命令会在独立的非交互进程中执行，
  不会直接输入当前交互式 Terminal，并且每条命令都需要你的明确批准。"（AX 树实测 line 40；API Key help 同语义）
- sandbox overclaim: 无（xcstrings 中无 sandbox/沙盒/只能访问/无法联网/绝对安全 表述）

## Tests
- previous baseline: 1130 discovered / 1129 executed / 989 passed / 140 skipped / 0 failed / 1 external exclusion
- R2 tests added: +5（B4-R2 的 running/AX/disclosure 断言）
- discovered: 1134
- executed: 1134
- passed: 994
- skipped: 140
- failed: 0
- external exclusion: `SessionManagerTests.testO_CloseWhileConnectingCancelsConnection` — 本轮**实际运行并通过**（10.067s），exclusion 未被需要
- arithmetic: 1129 executed + 5 = 1134 ✓；989 passed + 5 = 994 ✓；skipped 140 不变 ✓
- log: `/tmp/macssh-b4r2r1-fullsuite.log`（EXIT=0，`All tests` passed，888s）

## Regression
- B4: AgentToolLoopTests 26 / AgentViewModelTests 19 / AgentProviderToolGateTests 11 / AgentProviderToolCallingTests 20 / AgentToolRouterTests 19 / DeepSeekResponsesProviderTests 16 / OpenAIResponsesProviderTests 20 / AgentCredentialServiceTests 9 — 全绿
- B3: AgentRemoteCommandBuilderTests 18 / ExecutorTests 20 / Cancellation 9 / Security 13 / SSHTransport 27 / AgentRemoteRealExecTests 15（15 条 live 全部 self-skip，fixture 不存在）— 全绿
- B2: AgentLocalCommandExecutorTests 24 / Cancellation 10 / Output 19 / Security 10 — 全绿
- B1: AgentCommandRequestTests 11 / Validation 13 / ApprovalCoordinatorTests 29 / SecurityGateTests 7 / ConcurrencyTests 8 — 全绿
- Localization: LocalizationTests 23 — 全绿

## Debug
- result: `** TEST BUILD SUCCEEDED **`（fresh DerivedData `/tmp/MacSSH-Phase10E-B4R2R1-Debug`，EXIT=0）
- test build: YES（full suite 使用同一 fresh DerivedData 执行）
- warnings: production 0（18 条全部位于 `Tests/SSH/*.swift`，属既有测试噪音，非本阶段引入）

## Release
- result: `** BUILD SUCCEEDED **`（fresh DerivedData `/tmp/MacSSH-Phase10E-B4R2R1-Release`，EXIT=0）
- warnings: 0（日志中 9 处 "warning" 命中均为命令行 flag 文本）

## Remote Live SSH
- fixture: `/tmp/macssh_phase6_ed25519` 不存在
- status: **NOT RUN — no authorized fixture**（15 条 AgentRemoteRealExecTests 全部 self-skip；未伪造、未生成 key）

## Files
### Modified
- 无（本阶段零修改）

### Added
- `Docs/Phase10E-B4-R2-R1-Environment-Unblock-Final-Re-Acceptance.md`（本报告，唯一新增）

### Docs
- 同上

### Unexpected
- 无

## Findings

### P1
- count: 0
- items: —

### P2
- count: 0
- items: —

### P3
- count: 3
- items:
  1. 每次新 ad-hoc 签名构建访问既有 Keychain 凭据都会触发 ACL 授权弹窗（等待用户输入登录钥匙串密码）；
     这是 full-suite 首跑挂起 700s+ 与 R2"provider 不可用"结论的共同根因。已通过用户正常授权解除；
     建议后续验收 SOP 把"弹窗授权"列为 fresh build 前置步骤。
  2. `DetachedSignatures: No such file or directory` 日志噪音（SQLite logging-persist），已在两个 PASS 运行中证实良性，无需处理。
  3. `Tests/SSH/*.swift` 存在 18 条既有测试文件编译 warning（非 production），与本阶段无关，留待后续清理。

## Decision

**PASS — 0 P1 / 0 P2**

PHASE 10E-B4-R2-R1 FINAL PASS

Approval running-state remediation:
LIVE VERIFIED

Approval accessibility remediation:
LIVE VERIFIED

Capability disclosure remediation:
VERIFIED

Full test universe:
PASS

Remote live SSH:
NOT RUN — no authorized fixture

AUTHORIZED NEXT:
Phase 10E-C — Commit Verification Preparation

DO NOT COMMIT YET.
DO NOT PUSH.
DO NOT MERGE.
DO NOT TAG.

STOP.
