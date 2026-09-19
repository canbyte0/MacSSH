# Phase 10F-B4-S1-R2 Remote Approval GUI Harness Closure

**判定：PASS**（2026-09-17 09:06:56 +0800）

## Preflight 与边界

- branch：`feature/macssh-1.1-agent-terminal-mutation`
- HEAD：`e958750643aeb9992d4cb357e91dc084130224eb`
- staged：`0`；`git diff --check`：通过；未 commit、未 push。
- R2 夹具只在本地 Debug 临时运行，显式 launch argument 才激活；Remote endpoint、provider、transport 均为确定性内存实现，不访问网络、不执行 shell、不注册新 tool、不写 SwiftData 生产记录。
- UI 使用生产 `AgentMessageView`、`AgentToolCardView`、`AgentViewModel`、本地化文案与 AX modifiers；没有修改生产 UI 视图。证据采集后，所有夹具字节已移除。
- 恢复校验：以夹具前候选快照 `/private/tmp/macssh-b4-s1-r2-snapshot.xIKEK7/candidate.sha256` 为基准，排除本证据目录后的 `candidate_snapshot_diff=0`。

## Manual GUI matrix

目标均为：`远程 SSH · B4 Remote Fixture · fixture.invalid:2222`。

| 截图 | 捕获时间 | 场景 | Submit | 最终/当时状态 |
|---|---|---|---|---|
| `remote-pending-submit-false.png` | 2026-09-16 23:02:04 +0800 | `Remote fixture approve submit=false` | 否 | `awaiting_approval` |
| `remote-approved-submit-false.png` | 2026-09-16 23:08:54 +0800 | 同上，点击批准 | 否 | `success`；控件消失 |
| `remote-denied.png` | 2026-09-16 23:09:39 +0800 | `Remote fixture deny` | 否 | `denied`；控件消失 |
| `remote-pending-submit-true.png` | 2026-09-16 23:09:58 +0800 | `Remote fixture submit=true` | 是 | `awaiting_approval` |

Pending 卡片现场确认了 `发送到终端`、`远程 SSH`、目标 host/port、确切文本、Submit「否/是」以及“发送到现有交互终端、不捕获输出、Submit 追加回车”的披露文案。AX 树确认 `agent.tool_card`、`agent.terminal.approve`、`agent.terminal.deny`、`agent.terminal.text`；卡片容器没有 `AXPress`。`agent.terminal.target` 与 `agent.terminal.submit` 的稳定 identifier 保留在生产视图，且其值在现场卡片中正确呈现。

## Deterministic Remote transport

- `submit=false` 批准：1 transaction、3 writes、`requested=accepted=40` bytes（12 bytes bracket framing + 28 bytes payload）。
- Deny 后计数器稳定不变：仍为 1 transaction、3 writes、`accepted=40`；拒绝路径为 0 additional bytes。
- `submit=true` 批准：第二个 transaction 为 4 writes、`requested=accepted=48` bytes（12 framing + 35 payload + 1 Return）。
- 最终计数器：`transactionCount=2`、`writeCount=7`、`requestedBytes=acceptedBytes=88`、per-transaction `[40,48]`。
- endpoint 使用 production B3 capability 的一次性 claim/redeem、target identity、exclusive transaction 与 canonical bracketed-paste framing；UI 没有 active-tab shortcut，也没有 output capture。

## Replay 与 focused tests

恢复后的 7 个聚焦套件共 **118/118 passed，0 failed，0 skipped**：

| Suite | Passed |
|---|---:|
| `AgentProviderSendToTerminalTests` | 15/15 |
| `AgentToolLoopSendToTerminalTests` | 17/17 |
| `AgentLocalTerminalMutationTests` | 17/17 |
| `AgentRemoteTerminalMutationTests` | 19/19 |
| `AgentTerminalMutationSecurityGateTests` | 14/14 |
| `AgentProviderToolGateTests` | 11/11 |
| `LocalizationTests` | 25/25 |

`AgentRemoteTerminalMutationTests` 中的 `testSequentialReplayAddsNoRemoteTransactionOrBytes`、`testConcurrentReplayHasOneWinner`、`testConcurrentReplayStressFiftyRounds` 均通过；Remote replay 保持恰一次物理事务、无重复 bytes。

结果 JSON：`/tmp/macssh-b4-s1-r2-final-focused-escalated.json`。

## Tool/schema/build gates

- tool catalog：6 个；`send_to_terminal` 已注册；`write_file` 未注册。
- schema：精确为 `{text: string, submit: boolean}`，required 两项，`additionalProperties=false`，无 target 字段。
- SwiftTerm pin：`040d1271734694d046b77050b5bfc7aa483423ff`。
- 恢复后 Debug 与 Release：均 `BUILD SUCCEEDED`；app target build log 未发现 compiler `warning:` 或 `error:`。
- 聚焦测试编译日志包含既有其他测试文件的 Swift concurrency/unused-value warnings；这些文件不属于 R2，未被本轮修改，也未影响 118/118 结果。
- Release binary 未发现 `AgentRemoteApprovalGUIHarness`、`macssh-b4-s1-r2-remote-gui-fixture` 或 `fixture.invalid` 字符串。

## Evidence files

- [pending submit=false](remote-pending-submit-false.png)
- [approved submit=false](remote-approved-submit-false.png)
- [denied](remote-denied.png)
- [pending submit=true](remote-pending-submit-true.png)

本轮只保留 GUI 截图与本报告作为新证据；候选源码及既有文档/证据均按 pre-R2 状态保留。按 Phase 规则在此停止，不进入后续 Phase。
