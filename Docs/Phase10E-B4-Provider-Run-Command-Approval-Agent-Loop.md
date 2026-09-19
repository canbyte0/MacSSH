## Phase 10E-B4 — Provider run_command Wiring + Approval UI + Agent Loop Integration

### Repository

- path: `/Users/msl/msl_coding/MacSSH`
- branch: `feature/macssh-1.1-agent-command-execution`
- HEAD: `73038d61b9f2b22b027e3748d06600984186a29a`
- baseline: B4 开始前已保存 working-tree / diff snapshot；仓库本来就包含 Phase 10E-A/B1/B2/B3 的未提交变更
- B1/B2/B3 candidate: 保留在当前 working tree，未重写、未单独提交
- staged: none
- commit: none
- push: none

### Tool Registry

- count: 5
- names: `get_terminal_context`, `get_current_directory`, `list_directory`, `read_file`, `run_command`
- run_command prohibited before: 未登记，Provider 不可见，Router 不可派发
- run_command registered: 已登记为唯一命令工具，Provider-neutral registry 与 OpenAI/DeepSeek adapter 均使用同一静态定义
- other prohibited names preserved: `execute`, `exec`, `shell`, `terminal_send`, `send_to_terminal`, `pasteText`, `write_file`, `delete_file`, `rename_file`, `mkdir`, `move`, `copy`, `upload`, `chmod`, `chown`, `truncate`, `git_status`

### run_command Schema

- fields: 仅 `command: string`
- required: `command`
- additionalProperties: `false`
- model cwd: 不作为模型参数；绑定 generation 开始时 origin session 的 authoritative cwd 快照
- model shell: 不可指定；Local executor 使用账户 shell 的非 login、非 interactive `-c`
- model environment: 不可指定；App 生成固定 allowlist 环境
- model stdin: 不可用；Local stdin 接 `/dev/null`，Remote exec 不连接交互 Terminal stdin
- model timeout: 不可指定；App-owned production timeout 为 60s，内部 hard max 为 600s
- byte validation: UTF-8 最大 16 KiB；拒绝空白命令与 U+0000；允许多行并保留原始 command，不 trim、不重写

### Generation Binding

- generationID: 每次 Send 生成唯一 ID，并在整个 tool loop 中冻结
- sessionID: 绑定 origin session；不从 active session 指针重新解析
- providerSnapshotID: generation 开始时冻结，approval claim/redeem 校验同一 snapshot
- cwd snapshot: request factory 只接受 authoritative、绝对路径 cwd；不 fallback HOME、App cwd 或登录默认目录
- target: 从 origin session 的 backend 生成 `.local` 或 `.remote` request target
- active-session dependency: execution 不依赖当前 active tab；A/B session isolation 由 generation/session/backend/card identity guard 保护

### Approval Flow

- request creation: `parse → validate → cwd factory → provider binding → coordinator register`；非法参数、非法 command 或非 authoritative cwd 不创建 approval
- card visibility: `register` 后先写入 `awaitingApproval` tool card，再等待 approval
- approvalID: 每个登记请求拥有 opaque、一次性 approval ID
- Approve: UI 只调用 ViewModel façade，再由 coordinator 将 pending 状态转为 approved
- Deny: UI 只调用 ViewModel façade；等待中的 loop 收到 denied，并序列化为 `userDenied`
- one-time claim: generation 在 execution 前按 generation/session/provider snapshot 原子 claim
- executor redeem: Local/Remote executor 只能通过同一 coordinator redeem 一次性 authorization
- double approve: coordinator 并发/重复 approve 测试通过；不会产生第二次执行
- stale approval: generation、session、provider snapshot 任一不匹配时 claim 失败；旧卡片按钮为 no-op
- Stop pending: Stop 取消 generation 并取消 pending approval，executor 不被调用
- session close: `pruneConversations` 取消 generation，并调用 `cancelSession` 与 `purgeSession`，随后移除 conversation

### Approval UI

- Local/Remote: 卡片显示明确的 Local/Remote target badge
- host/session: target metadata 来源于 origin request；不重新读取 active session，不把凭据放入 approval model
- cwd: 显示冻结的 working directory
- exact command: 原始 command 使用 monospaced 文本展示，不编辑、不 trim
- multiline: 多行 command 使用有界滚动区域完整展示，不截断实际内容
- warning: 显示命令执行和 stdout/stderr 外发提示
- provider egress disclosure: 明确告知 stdout/stderr 可能作为 tool result 返回 Provider
- editing: 不提供编辑、改写、快捷键替换或 keyboard shortcut 批准路径
- Approve: 仅 `awaitingApproval` 状态显示显式 Approve button
- Deny: 仅 `awaitingApproval` 状态显示显式 Deny button
- accessibility: 使用 SwiftUI Button/Label 语义与稳定状态文案；专门 GUI/VoiceOver 点击证据留到 B4-R1

### Agent Loop

- run_command handling: Router 返回 `commandRequiresApproval`，ViewModel 完成 request/register/await/claim/redeem/serialize 全链路
- Local dispatch: 通过注入的 `AgentLocalCommandExecutor`，不经过 TerminalCommandDispatcher
- Remote dispatch: 通过注入的 `AgentRemoteCommandExecutor`，不经过 interactive Terminal 或 SFTP
- multiple command calls: loop 对同一 Provider round 串行处理 tool calls；B4 未新增专门的多条 run_command live E2E，留到 B4-R1
- mixed tools: 保留 read-only tool 与 run_command 的 serial continuation 语义；已有 mixed/read-only loop regression 通过
- call order: 按 Provider call 顺序写入 tool card 与 tool result
- call_id: 原始 `call_id` 保留并绑定 approval/request/result
- round limit: tool loop hard cap 为 10 rounds，超出后安全终止
- provider continuation: 执行结果按稳定 JSON 作为 tool result 返回 Provider，继续同一冻结 generation

### Cancellation

- awaiting approval: Stop / generation replacement / session close 会取消等待；不执行命令
- Local running: B2 Local executor cancellation/timeout/process-group tests 通过；B4 loop 的 live running-stop 留到 B4-R1
- Remote running: B3 Remote executor cancellation/transport tests 通过；live SSH running-stop 留到 B4-R1
- provider stream: generation cancellation 与 identity guard 阻止 late provider event 写入新 generation
- late result: late result 不写入另一 session、另一 generation 或已关闭 conversation
- continuation after Stop: Stop 后不再进行 Provider continuation

### Tool Result

- executed: 稳定 JSON 包含 `ok`、`executed` 与执行状态
- non-zero: 保留 `exit_code`，命令非零退出不伪装成 Router/infrastructure error
- timeout: `timed_out` 与 `timedOut` 状态序列化；timeout 是结果状态，不是模型可控参数
- userDenied: 统一输出 `userDenied` 语义，并保留拒绝原因边界
- infrastructure error: shell/cwd/spawn/authorization 等错误映射为稳定、无敏感内容的 tool error
- stdout: 与 stderr 分离返回
- stderr: 与 stdout 分离返回
- truncation: stdout/stderr 各自 256 KiB 存储上限，继续 drain 并设置独立 truncation 标记
- sanitizer: 二进制/非 UTF-8 输出保留检测标记；`CustomStringConvertible`/debug 描述不输出 command、cwd 或输出内容
- partial output after cancel: executor 保留已收集的 bounded partial output，并标记 cancelled

### Provider

- OpenAI tool definition: Responses function tool 使用 registry 生成的 flat function schema
- DeepSeek tool definition: Responses function tool 使用同一 provider-neutral schema
- built-in shell: 无 Provider built-in shell/tool；只接受 allowlist 中的 `run_command`
- provider-neutral: Domain、approval、executor 不依赖 OpenAI/DeepSeek JSON 类型
- frozen provider continuation: provider snapshot 绑定与跨 round continuation 测试通过
- reasoning replay: 既有 reasoning/tool-call replay 行为未被 B4 改写；结果回填沿用现有 Provider adapter

### Security

- approval mandatory: 所有 `run_command` 都必须显式一次性批准；没有 auto-approve classifier
- auto classifier: 不存在；命令文本不能自我降低审批级别
- command sandbox claim: 使用冻结 cwd、固定 timeout/output 上限、独立 process/SSH exec；不声称这是 OS sandbox
- credential egress: approval binding 不含 API key、Authorization header 或 SSH credential；UI 明示 stdout/stderr Provider egress
- command logging: request/result 的自定义描述为 redacted，不记录 command 内容
- cwd logging: cwd 仅用于 bounded UI/request execution；redacted debug description 不泄漏 cwd
- output logging: result debug description 不泄漏 stdout/stderr
- send_to_terminal: 仍被 registry、Provider gate 与 source security tests 禁止；没有实际 Agent 调用路径
- modifying file tools: `write_file`、`delete_file` 等 standalone modifying file tools 仍未登记、未暴露

### UI States

- awaitingApproval: 显示 target/cwd/provider/exact command/disclosure 与 Approve/Deny
- running: 卡片进入执行中状态，按钮消失
- success: 显示成功与 bounded output metadata
- failure: 显示稳定的 tool/executor failure
- denied: 显示 user denied
- cancelled: 显示 cancelled，不再 continuation
- timedOut: 显示 timed out

### B4 Tests

- schema: `AgentProviderToolGateTests` 通过，5-tool registry、schema 与 prohibited names gate 通过
- Provider requests: `AgentProviderToolCallingTests`、OpenAI/DeepSeek provider tests 通过
- parser: `AgentToolRouterTests` 与 Provider calling/parser assertions 通过；run_command 严格拒绝缺字段、额外字段、错误类型
- Agent loop: `AgentToolLoopTests` 24/24 通过
- Approve: `testRunCommandWaitsForApprovalThenExecutesAndContinues` 通过
- Deny: `testRunCommandDenyProducesUserDeniedWithoutExecution` 通过
- Stop pending: `testStopWhileAwaitingCommandApprovalCancelsWithoutExecution` 通过
- Stop running: executor cancellation 与既有 loop stop regression 通过；B4 live running-stop 留到 B4-R1
- double approve: `AgentCommandApprovalConcurrencyTests` 与 coordinator tests 通过
- A/B isolation: `AgentToolLoopTests` A/B local/remote isolation tests 通过
- provider switching: frozen provider snapshot test 通过
- mixed tools: 既有 mixed/read-only loop tests 通过
- multiple commands: 既有 serial tool-call order test 通过；专门多条 run_command approval E2E 留到 B4-R1
- Local real integration: 未执行，留到 B4-R1
- Remote fake integration: B3 builder/executor/transport/security fake tests 通过；B4 live remote 留到 B4-R1
- Tool Card: preview 已生成并获用户确认后修改；源码编译/static state coverage 通过，GUI click evidence 留到 B4-R1

### B3 Regression

- Remote builder: `AgentRemoteCommandBuilderTests` 通过
- Transport: `AgentRemoteCommandSSHTransportTests` 通过
- Executor: Remote executor tests 通过
- Cancellation: Remote cancellation tests 通过
- Security: Remote security tests 通过
- live SSH skipped: 未使用授权 live SSH fixture；真实 Remote execution 留到 B4-R1，未伪造证据

### B2 Regression

- Local executor: Local executor tests 通过
- Output: output cap/drain/UTF-8 tests 通过
- Timeout: timeout/process-group tests 通过
- Cancellation: cancellation tests 通过
- Security: Local executor security tests 通过

### B1 Regression

- Validation: command validation/request tests 通过
- Approval: approval coordinator tests 29/29 通过
- Concurrency: approval concurrency tests 通过
- SecurityGate: command security gate tests 通过

### Phase 10D Regression

- ProviderToolGate: 通过
- ProviderToolCalling: 通过
- ToolLoop: 通过
- ToolRouter: 通过
- AgentViewModel: 通过
- ConversationStore: 通过

### Test Universe

- baseline discovered: 1126
- baseline executed: 1125
- B4 added: 4 dedicated Agent loop tests
- current discovered: 1130
- current executed: 1129
- passed: 989
- skipped: 140
- failed: 0
- external exclusion: 1：`SessionManagerTests.testO_CloseWhileConnectingCancelsConnection`，blackhole 环境无法稳定观察 connecting 状态；未计入 selected run
- arithmetic: `989 + 140 + 1 = 1130`；selected run 为 `989 + 140 = 1129`。首次 unfiltered run 只因该环境依赖测试失败并中断，随后使用精确 `-skip-testing` 重跑成功

### Debug

- DerivedData: `/tmp/macssh-dd`
- result: `MacSSH.app` arm64，Designated Requirement 通过；`/tmp/macssh-b4-full-tests-excluded` test build `TEST SUCCEEDED`
- test build: targeted final `/tmp/macssh-b4-targeted-final` 为 53/53；full selected run 为 1129 executed、140 skipped、0 failures
- warnings: project code Debug 0；`git diff --check` clean

### Release

- DerivedData: `/tmp/macssh-dd-rel`
- result: `BUILD SUCCEEDED`，MacSSH.app arm64，Designated Requirement 通过
- warnings: project code Release 0

### Live State

- Provider live test: 未执行
- Local Agent live test: 未执行
- Remote Agent live test: 未执行
- Remote SSH fixture: 当前没有授权的 live SSH fixture
- deferred to B4-R1: real Provider function call、真实 Local approve/execute/result continuation、Stop awaiting/running、Deny、A/B session isolation、command-output continuation、no terminal injection、可用 fixture 时的 Remote live execution

### Files

#### B1 Existing

- `MacSSH/Services/Agent/Command/AgentCommandApproval.swift`
- `MacSSH/Services/Agent/Command/AgentCommandApprovalCoordinator.swift`
- `MacSSH/Services/Agent/Command/AgentCommandExecutionAuthorization.swift`
- `MacSSH/Services/Agent/Command/AgentCommandRequest.swift`
- `MacSSH/Services/Agent/Command/AgentCommandValidation.swift`
- B1 approval/request/security tests under `Tests/SSH/`

#### B2 Existing

- `MacSSH/Services/Agent/Command/Execution/AgentLocalCommandExecutor.swift`
- `MacSSH/Services/Agent/Command/Execution/AgentLocalCommandProcess.swift`
- `MacSSH/Services/Agent/Command/Execution/AgentLocalCommandEnvironment.swift`
- `MacSSH/Services/Agent/Command/Execution/AgentCommandResult.swift`
- B2 Local output/cancellation/security tests under `Tests/SSH/`

#### B3 Existing

- `MacSSH/Services/Agent/Command/Execution/Remote/AgentRemoteCommandExecutor.swift`
- `MacSSH/Services/Agent/Command/Execution/Remote/AgentRemoteCommandBuilder.swift`
- `MacSSH/Services/SSH/SSHExecChannel.swift`
- B3 Remote builder/transport/executor/security tests under `Tests/SSH/`

#### B4 Added

- Four dedicated test methods added to existing `Tests/SSH/AgentToolLoopTests.swift`
- B4 localization keys generated into `MacSSH/Resources/Localizable.xcstrings`
- This report

#### B4 Modified

- `MacSSH/Services/Agent/AgentProvider.swift`
- `MacSSH/Services/Agent/Provider/OpenAIResponsesProvider.swift`
- `MacSSH/Services/Agent/Provider/OpenAIResponsesModels.swift`
- `MacSSH/Services/Agent/Provider/DeepSeekResponsesProvider.swift`
- `MacSSH/Services/Agent/Tools/AgentToolDefinition.swift`
- `MacSSH/Services/Agent/Tools/AgentToolModels.swift`
- `MacSSH/Services/Agent/Tools/AgentToolPolicy.swift`
- `MacSSH/Services/Agent/Tools/AgentToolError.swift`
- `MacSSH/Services/Agent/Tools/AgentToolResultSerializer.swift`
- `MacSSH/Services/Agent/Tools/AgentToolRouter.swift`
- `MacSSH/Services/Agent/AgentToolActivity.swift`
- `MacSSH/Services/Agent/AgentViewModel.swift`
- `MacSSH/Features/Agent/AgentSidebarView.swift`
- `MacSSH/Features/Agent/AgentToolCardView.swift`
- `MacSSH/App/AppState.swift`
- `Scripts/gen_localizable.py`
- related Provider/Router/loop tests and Xcode project membership

#### Docs

- Added: `Docs/Phase10E-B4-Provider-Run-Command-Approval-Agent-Loop.md`
- Existing untracked Phase 10D/B1/B2/B3/B4-R1/B4-A docs were preserved and not rewritten as part of this phase

#### Unexpected

- No unexpected B4 implementation files found. Pre-existing modified/untracked files, including `MacSSH/Services/SSH/SSHConnection.swift`, were preserved without scope expansion.

### Findings

#### P1

- count: 0
- items: none

#### P2

- count: 0
- items: none

#### P3

- count: 0
- items: live Provider/GUI/SSH evidence is an explicitly deferred B4-R1 gate, not a B4 implementation defect

### Decision

Decision：

PASS — 0 P1 / 0 P2

PHASE 10E-B4 IMPLEMENTATION PASS

Provider run_command wiring,
mandatory Approval UI,
and Agent Loop integration are accepted.

Local and Remote command execution are now reachable
only through explicit one-time user approval.

send_to_terminal remains prohibited.
All standalone modifying file tools remain prohibited.

NO COMMIT.
NO PUSH.

AUTHORIZED NEXT:
Phase 10E-B4-R1 — Live Command E2E + GUI + Safety Re-Acceptance

B4-R1 must validate:
- real Provider function call
- real Local approval/execution/result continuation
- Stop while awaiting approval
- Stop while running
- Deny
- A/B session isolation
- command-output Provider continuation
- no terminal injection
- Remote live execution when an authorized SSH fixture is available

If Remote fixture remains unavailable,
report it honestly and do not fabricate evidence.

STOP.
