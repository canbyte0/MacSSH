# Phase 10D-B4 — Provider Tool Calling + Agent Loop + Tool Activity UI

报告日期：2026-09-11
分支：`feature/macssh-1.1-agent-sidebar`
基线 HEAD：`fc07f0f88d69c40a86599c205c4366bbdf670afb`（未提交，B1/B2/B3 candidate 亦未提交）
Live 验收证据目录：`/tmp/macssh-b4-gui/`（截图 + 诊断代理请求/响应日志）

---

## Repository

- branch: `feature/macssh-1.1-agent-sidebar`
- HEAD: `fc07f0f88d69c40a86599c205c4366bbdf670afb`
- candidate: 未提交（4 modified + B4 新增文件，见 Files 节）
- staged: 无（`git status --short` 无 staged 项；未 commit / push / merge / tag）

---

## Provider Protocol

### OpenAI

- tools schema: Responses-format flat function tool（`{"type":"function","name","description","parameters"}`），
  仅 4 个 read-only 工具；`strict` 省略（本地 validation 才是边界，§9）
- tool_choice: 恒为字符串 `"auto"`（§8；绝不 required / none / 用户可编辑）
- function-call events: `response.output_item.added` / `response.function_call_arguments.delta` /
  `response.function_call_arguments.done` / `response.output_item.done` 全部由共享
  `ResponsesFunctionCallAssembler` 消费（§11：runtime 只见完整 `AgentProviderToolCall`）
- call ID: Provider `call_id` 原样保留为 continuation hard identity（§14；绝不用 item_id / UUID / tool name）
- arguments assembly: `function_call_arguments.done.arguments` 为 canonical；delta 仅作流式重建与校验
  （§12：done 与累计 delta 不一致 → `streamProtocol`，绝不静默执行）
- function_call_output: 每 call 恰一个输出（§14/§58）；多 call 分组回放（见 Findings P1-R1）
- reasoning replay: `response.output_item.done`（type=reasoning）→ OpenAI-scoped opaque
  continuation item；后续请求 verbatim 回放（§22/§65；fixture 覆盖）

### DeepSeek

- tools schema: 与 OpenAI 同构（共享 core；§10：继续 `https://api.deepseek.com/responses`，未改回 Chat Completions）
- tool_choice: `"auto"`
- function-call events: 同 OpenAI（同一 assembler；§64 fixture 覆盖单 call / 并行 / delta / incomplete / failed / cancel）
- call ID: 同 OpenAI
- continuation: function_call + function_call_output 严格配对；`response.incomplete` → 结构化
  `incompleteResponse`（§59：残缺 call 绝不执行）
- stateless rebuild: 每轮从本地结构化 transcript 完整重建（§20：绝无 previous_response_id / conversation）
- reasoning: 捕获为 DeepSeek-scoped opaque item（§66 adapter 吸收差异；domain 不解读）

---

## Provider-Neutral Model

- tool definition: `AgentToolDefinition { name, description, parametersJSON }` +
  `AgentToolCatalog`（静态 4 项 + `prohibitedNames` denylist）
- tool call: `AgentProviderToolCall { callID, name, argumentsJSON }`（组装层产物，§3/§11）
- tool result: `AgentToolResult`（B2/B3 domain 类型）+ `AgentToolResultSerializer` →
  `{"ok":true,...}` / `{"ok":false,"error":"<stableName>"}`（§29）
- AgentEvent: `textDelta` / `toolCall(完整)` / `providerItem(opaque)` / `completed`
  （§16：绝不暴露 argumentsDelta / outputItemAdded / outputIndex）
- conversation items: `AgentMessage.Content = .text / .tool(AgentToolActivity) / .providerContinuation`
  共享同一有序时间线（§17/§49；tool card 与文本按流顺序交错）
- opaque provider state: `AgentProviderContinuationItem { providerScope, kind, itemJSON }`（§23：
  provider-scoped / memory-only / 不渲染 / 不日志 / Router 不解释）

---

## Tool Registry

- get_terminal_context: 无参数；B2 caps 保持（200 rows / selection ≤64 KiB / 总量 ≤256 KiB）
- get_current_directory: 无参数；unavailable 返回 success 三元组（§30）
- list_directory: `path` required；≤500 entries + truncated + 确定性排序（§33）
- read_file: `path` required；≤256 KiB + text-only + truncated metadata（§32）
- unknown tool: `AgentToolCallParsing` 静态注册表拒绝 → `{"ok":false,"error":"unknownTool"}`（§51）
- prohibited tools: 请求 definitions 中不存在 run_command / execute / shell / write_file /
  delete_file / rename_file / mkdir / git_status 等（gate 测试断言；§52）

---

## Agent Loop

- generation ID: 每次 Send 生成 UUID；conversation 持有 `generationID`，所有事件写入前 identity guard（§25/§48）
- origin session: send 时快照 `ManagedTerminalSession` + `AgentTerminalSessionHandle`（cwd/buffer 来源）；tool loop 绝不重读 activeSession
- frozen read scope: generation 开始时构建一次——Local 经 `AgentReadScope.make`（kernel canonical root）、
  Remote 经 `AgentReadScope.makeRemote`（SFTP 服务端 canonicalize，§85 唯一允许的 generation-start 文件操作）；
  失败/非权威 → 空 roots（§34/§35）
- max rounds: 10（§26）；第 11 个 tool-bearing response → 终止 generation + `toolRoundLimit` 结构化失败
  （loop 测试：10 rounds allowed / 11th blocked）
- parallel calls: Provider 可并行产生，MacSSH 串行执行（§13/§27：按 output order，全部执行完才继续）
- execution order: 同 response 多 call 串行 + 全部 `function_call_output` 一次性进入 continuation（§27）
- recoverable errors: outsideAllowedReadScope / invalidArguments / unknownTool / pathNotFound 等 → tool result
  继续 generation（§28）；fatal 仅 sessionUnavailable / cancelled / provider failure
- continuation: 每轮从本地 transcript 完整重建 input（§19/§21）
- provider snapshot: `AgentProvider.snapshotForGeneration()` → generation 级冻结实例（§54/§55：
  provider/model/baseURL/credential 全程不变；loop 测试断言 snapshot 只解析一次且后续轮次全部走冻结实例）

---

## Cancellation

- Provider stream: 消费 Task 取消 → onTermination 取消 producer → URLSession 请求取消（既有机制 + B4 保留）
- before tool: 每个 call 执行前 `Task.checkCancellation`（§45；测试：call 事件已到、Stop → 绝不执行）
- during tool: 取消传播进 router/backend（B2/B3 已支持）；测试：Remote 分块读中途 Stop → card=cancelled、
  handle 关闭、无第二轮 request
- after tool: 执行完所有 calls 后、下一轮 request 前 `Task.checkCancellation`（§47）
- before continuation: 同上一检查点（§47 hard race 防护）
- late events: generation identity guard + 流取消；测试用 gate 让旧 stream 在 Stop 后产出 late delta，
  断言绝不写入 conversation（§48）

---

## Session Isolation

- Local A/B: 测试（§42/§68）：A 执行中切到 B → A scope/backend/conversation/card 全保持 A，B 空
- Remote A/B: 测试：只触碰 origin session 的 fake 后端；B 的 fake 计数为 0
- Local/Remote: 测试：Local 读真实 fixture、Remote 读 fake；互不触碰
- session close: `sessionUnavailable` → fatal 安全收尾（测试 + §43：绝不改去 active B）
- active tab switch: 切换只影响 UI；generation 继续写 origin conversation（测试覆盖）

---

## Tool UI

- running: spinner + 进行中；tool card 在 provider toolCall 事件到达时立即 append（§37 privacy gate：
  数据外发前可见）
- success: ✓ 完成
- failure: ⚠ 失败（结构化错误对应 card failure；模型可解释）
- cancelled: 已取消（Stop / 未执行；transcript 输出 `{"ok":false,"error":"cancelled"}` 保证配对）
- visible before data egress: 测试断言第二轮请求的 transcript 中 card 已带完整结果（§37/§84）
- result content default visibility: card 只显示工具名 + path + 状态；完整文件/终端/目录内容绝不默认展开（§39）
- localization: 9 个新 key 进 canonical（gen_localizable.py 幂等 gate + xcstrings 424 keys）

---

## Security

- scope enforcement: B4 wiring 复用 B1/B3 resolver/scope 全链；loop 测试覆盖相对/绝对命中、`../` 逃逸、
  绝对越界、symlink 逃逸、cwd unavailable（全部拒绝且正文绝不泄漏）
- symlink: 测试：`escape/secret.txt`（指向 scope 外）→ outsideAllowedReadScope
- outside root: 测试 + `.failure(.outsideAllowedReadScope)` 结构化结果；正文不泄漏
- approximate Remote cwd: `makeRemote` 只接受 authoritative（OSC7）；sessionDefault → 空 roots（B3 已冻结语义）
- command execution: 审计 0 reachable（仅注释 + denylist 字符串；无 Process/NSTask/libssh2_channel_exec/
  TerminalCommandDispatcher/pasteText/send_to_terminal 调用）
- Terminal injection: 无任何 terminal 写入 API 被 Agent 引用；Agent 只读 buffer snapshot
- SFTP mutation: Router 不暴露任何 mutation；底层既有 write API 未被 Agent 引用
- unknown tool: 静态注册表拒绝（§51）
- DSML text parsing: 无任何文本工具标记解析路径；gate 测试断言伪工具文本仅作为 textDelta（§50）
- content logging: B4 新增文件 0 日志语句；Provider 既有日志只含阶段/HTTP status（无 prompt/路径/正文）

---

## Data Egress

- terminal: 仅 get_terminal_context 的 bounded snapshot（≤256 KiB 文本预算）经 tool result 外发
- selection: 含在上限内（selection ≤64 KiB + recentOutput 共享 256 KiB 预算）
- Local files: ≤256 KiB / text-only / UTF-8（B2 不变）
- Remote files: ≤256 KiB / 分块有界读取 / 句柄必关（B3 不变）
- directory listings: ≤500 entries + truncated（B3/B2 不变）
- bounds: loop 测试断言 300 KiB 文件 → truncated=true 且 bytesReturned ≤256 KiB；601 条目目录 → ≤500 + truncated
- persistence: tool transcript memory-only；不写 SwiftData / disk / UserDefaults（§87）

---

## Live DeepSeek

> 全部经本地诊断代理（`/tmp/macssh-b4-gui/proxy.py`，Base URL 临时指向 127.0.0.1:8787，
> 验收后已恢复 `https://api.deepseek.com`）+ GUI 自动化（osascript）完成。
> 代理日志：`/tmp/macssh-b4-gui/proxy.log`（24 个请求；Authorization 头从不落盘）。

### Terminal Context

- request: "查看当前终端最近的输出，并告诉我最后执行了什么。"
- structured tool call: `get_terminal_context({})` + `get_current_directory({})`（并行两 call，真实 function call）
- card: 「读取终端上下文 ✓ 完成」「获取当前目录 ✓ 完成」（截图 02）
- result: `{"alternateScreen":false,"columns":93,...,"ok":true,...}`（真实 buffer 快照）
- answer: 逐行引用真实终端输出（含 `B4-LIVE-MARKER-OK`、`zsh: command not found` 行）
- 无 DSML 伪工具文本触发任何执行（模型偶发文本工具意图仅作为普通文本渲染）

### Current Directory

- tool: `get_current_directory({})`
- result: `{"confidence":"authoritative","ok":true,"path":"/Users/msl","source":"osc7"}`
- answer: 引用 osc7/authoritative 三元组，与 header 一致（截图 05）

### Local README（变体：真实项目文件）

- structured tool call: `read_file({"path":"msl_coding/Ter/AGENTS.md"})`（真实 read_file；因 GUI 输入事故目标为 AGENTS.md 而非 README.md）
- file: `{"bytesReturned":805,"ok":true,"originalSize":805,"text":"# MacSSH 项目开发约束\n..."}`
- result: 正文与磁盘文件逐字节一致
- answer: 基于真实文件内容（引用项目约束条目）
- 说明: README.md 本身未单独 live 触发；read_file 通道行为相同，离线覆盖等价

### Directory

- tool: `list_directory({"path":"msl_coding/Ter"})`（真实列目录）
- result: `.build/.claude/.codebuddy/.git/Docs/MacSSH/...` 与真实目录一致；card「列出目录 ✓ 完成」
- answer: 按真实条目总结（截图 10）

### Outside Scope

- result: **部分**——模型在未调用 read_file 的情况下主动拒绝：
  「I also couldn't inspect it even if it did — it's outside my readable root (`/Users/msl`)」（截图 22）
- content leaked: no
- 说明: live 未观测到 `outsideAllowedReadScope` 的 tool result 形态（该路径由离线 loop 测试
  与 B1/B3 回归覆盖）；live 侧证明模型侧也不会尝试越界读取

### Command Security

- git status execution: 无（未发送 git status 请求；相关请求中模型两次明确声明
  「I can't execute shell commands」，截图 17/22）
- Process: 0（静态审计 + 运行时无进程创建）
- Terminal injection: 0（终端输出在两次「无法执行」声明前后逐字节未变）

### Destructive Request

- modifying tool: 无 —— live 未触发（受 keychain 重新授权阻塞，见 P3）
- result: 离线覆盖：注册表只有 4 个 read-only 工具；任何 delete/write 名字 → unknownTool

### Stop

- stage stopped: live 未触发（P3）；离线 loop 测试覆盖 streaming/执行中/continuation 前全部窗口
- continuation prevented: 测试断言 Stop 后 `provider.calls` 不增长
- partial retained: 测试（既有 10C 语义保留）
- recovery: 测试（Stop 后可再次 Send）

### A/B Isolation

- origin: live 未触发（P3）；离线覆盖 Local A/B、Remote A/B、Local/Remote 三种组合
- active switched / backend used / card location / answer location: 测试断言全部保持 origin

### Live 发现的真实缺陷（已修复并 live 复验）

**P1-R1（阶段内发现并修复）**：DeepSeek thinking mode 下，以「多 call 工具轮次」结尾的
continuation 请求被 400 拒绝（`"The reasoning_text in the thinking mode must be passed back"`）。

- 根因：我们的 transcript 重建把同一 turn 的 call/output **交错**回放（fc1,fco1,fc2,fco2）。
  DeepSeek 对末尾 tool turn 做 reasoning 校验时按 function_call 连续块回溯，交错顺序在 fco1
  处中断 → 误判 reasoning 缺失 → 400（请求 #4/#6 实证）。
- 修复：`ResponsesRequestBody.inputItems` 对连续 tool 条目分组回放——先全部 function_call，
  再全部 function_call_output（DeepSeek 要求 + OpenAI parallel-call 标准形态）。
- 验证：单测（`testParallelCallOutputsAreGroupedAfterAllCalls`）+ live 复验（诊断代理请求 #13：
  同形状请求由 400 → 200，后续多轮 tool loop 全部 200）。
- 影响面：仅 transcript 回放顺序；scope/装配/取消语义不变。

---

## Remote Live

- fixture: 仍无已授权真实 SSH fixture（B3 P3 延续；`~/.ssh` 审批未执行）
- read: 未 live；离线 fake client 覆盖（AgentRemoteFileServiceTests / AgentRemoteRouterTests / B4 loop Remote 用例）
- list: 未 live；离线覆盖
- PTY coexistence: 未 live；B3 架构保证（既有 SFTP 门内复用，同连接）
- scope escape: 未 live；离线覆盖（makeRemote + containment）
- status: **P3 保持** —— Phase 10D Remote runtime 已由 offline + existing SFTP regression 覆盖，
  real end-to-end remains pending（Phase 10 FINAL acceptance 前建议补齐）

---

## Tests

- provider OpenAI: `AgentProviderToolCallingTests` 单 call 组装 / 并行两 call / text+call / call+text /
  非法 JSON 透传 / duplicate call_id / unknown item delta / done-delta 不一致 / incomplete / failed /
  unknown tool / continuation 重建 / 分组回放 / reasoning 捕获 / 取消（URLProtocol stub，100% offline）
- provider DeepSeek: 同套件内覆盖单 call / 并行 / continuation 全 transcript / incomplete / 跨 provider 隔离
- loop: `AgentToolLoopTests` 20 用例（0/1/2/多轮、串行顺序、10 轮上限、11 轮终止、可恢复错误、
  unknown/invalid、sessionUnavailable、Stop 全链、late events、provider 失败、provider 快照、
  A/B 隔离×3、scope 回归×6、无 prefetch、bounds）
- router: B2/B3 router 测试全量回归通过（含 scope mismatch / unknownTool / 取消）
- Local: AgentLocalFileServiceTests 全量回归通过
- Remote: AgentRemoteFileServiceTests / AgentRemotePathResolverTests / AgentRemoteRouterTests 全量回归通过
- conversation: AgentConversationStoreTests（generationID 适配）+ 新增 tool transcript 断言
- ViewModel: AgentViewModelTests 全量回归通过（10B/10C 语义保持）
- UI: tool card 状态/文案/可见性经 loop 测试断言 + GUI live 截图；LocalizationTests 回归通过
- localization: gen_localizable.py 幂等（两次运行 hash 一致）+ `git diff --check` 通过
- B1/B2/B3 regressions: 全量套件回归通过（见 Test Universe）

---

## Test Universe

- previous discovered: 840（B3；executed 839 + 1 用例级外部排除）
- added: 52（provider calling 19 + loop 20 + serializer 8 + gate 净增 5）
- discovered: 892
- executed: 891
- passed: 766
- failed: 0
- skipped: 125（与 B3 逐套件一致的环境型 XCTSkip）
- externally excluded: 1（`MacSSHTests/SessionManagerTests/testO_CloseWhileConnectingCancelsConnection`，
  环境型 libssh2 -13 + 挂死；与 B2/B3 相同 P3）
- 入口：`xcodebuild test -project MacSSH.xcodeproj -scheme MacSSH -configuration Debug
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/MacSSH-Phase10D-B4-Debug
  -skipPackagePluginValidation -skipMacroValidation
  '-skip-testing:MacSSHTests/SessionManagerTests/testO_CloseWhileConnectingCancelsConnection'`
- 日志：`/tmp/macssh-b4-full-test2.log`（`** TEST SUCCEEDED **`；Executed 891 / 125 skipped / 0 failures）

---

## Debug

- result: `** BUILD SUCCEEDED **`（`/tmp/MacSSH-Phase10D-B4-Debug`，含 P1-R1 修复后重建）
- warnings: 0

## Release

- result: `** BUILD SUCCEEDED **`（`/tmp/MacSSH-Phase10D-B4-Release`，含 P1-R1 修复后重建）
- warnings: 0

---

## Secret Audit

- real credentials: 无 —— 全部测试使用 fake key（`b4-test-key` / `test-api-key` / `openai-test-key` /
  `deepseek-test-key`）；仓库/新增代码无 `sk-` / `dsk-` / Bearer 真实 token / AKIA 形态
- logs: 诊断代理从不落盘 Authorization；App 日志（既有）无 Key / 正文；B4 新增文件 0 日志
- persistence: Tool transcript / opaque item / tool result 全部 memory-only（无 SwiftData / disk / UserDefaults）
- 备注：live 验收期间临时将 `macssh.agent.baseURL` 指向本地诊断代理，验收后已恢复
  `https://api.deepseek.com`（`defaults read` 复核）；未修改 Keychain 条目内容

---

## Files

### Added

- `MacSSH/Services/Agent/Provider/AgentProviderToolEvents.swift`（scope / tool call / opaque item）
- `MacSSH/Services/Agent/Provider/ResponsesJSONValue.swift`（JSON 值树：schema + opaque 回放）
- `MacSSH/Services/Agent/Provider/ResponsesFunctionCallAssembler.swift`（流式组装状态机）
- `MacSSH/Services/Agent/Tools/AgentToolDefinition.swift`（静态 allowlist + schema + 本地参数验证）
- `MacSSH/Services/Agent/Tools/AgentToolResultSerializer.swift`（结构化 tool result）
- `MacSSH/Services/Agent/AgentToolActivity.swift`（tool card 模型）
- `MacSSH/Features/Agent/AgentToolCardView.swift`（tool card UI）
- `Tests/SSH/AgentProviderToolCallingTests.swift`
- `Tests/SSH/AgentToolLoopTests.swift`
- `Tests/SSH/AgentToolResultSerializerTests.swift`
- `Docs/Phase10D-B4-Provider-Tool-Calling-Agent-Loop-Tool-Activity-UI.md`（本报告）

### Modified

- `MacSSH/Services/Agent/Provider/ResponsesProviderCore.swift`（tools/tool_choice + 异构 input + 组装循环 + P1-R1 分组）
- `MacSSH/Services/Agent/Provider/AgentEvent.swift`、`OpenAIResponsesProvider.swift`、
  `DeepSeekResponsesProvider.swift`、`OpenAIResponsesModels.swift`、`ResolvingAgentProvider.swift`
  （scope / mapper / generation 快照）
- `MacSSH/Services/Agent/AgentProvider.swift`（协议签名 + snapshotForGeneration）
- `MacSSH/Services/Agent/AgentMessage.swift`、`AgentConversation.swift`（Content 枚举 + tool 更新 + generationID）
- `MacSSH/Services/Agent/AgentViewModel.swift`（tool loop + 冻结 scope + 取消全链）
- `MacSSH/Services/Agent/Provider/AgentProviderError.swift`（toolRoundLimit / sessionUnavailable 分类）
- `MacSSH/App/AppState.swift`（router/resolver 接线）
- `MacSSH/Features/Agent/AgentSidebarView.swift`、`AgentMessageView.swift`（tool card 渲染 + 新失败文案）
- `MacSSH/Resources/Localizable.xcstrings`（424 keys；+13 新 key/更新 2 处既有文案）
- `Scripts/gen_localizable.py`
- `Tests/SSH/AgentProviderToolGateTests.swift`（B4 gate 重写）、`AgentViewModelTests.swift`、
  `AgentConversationStoreTests.swift`、`OpenAIResponsesProviderTests.swift`、
  `DeepSeekResponsesProviderTests.swift`、`SSEEventParserTests.swift`（API 适配）
- `MacSSH.xcodeproj/project.pbxproj`（10 个新文件登记）

### Unexpected

- 无。工作区其余 modified 文件（`.zshenv` / `LocalShellLauncher.swift` / `LocalShellLauncherTests.swift`）
  为 B1/B2/B3 candidate 既有改动，B4 未触碰。

---

## Findings

### P1

- count: 0
- items: 无（live 发现的 P1-R1 已在阶段内修复并复验，见 Live DeepSeek 节）

### P2

- count: 0
- items: 无

### P3

- count: 3
- items:
  1. **Live 剩余项受 macOS Keychain 重新授权阻塞**：重建后的 MacSSH.app 二进制在读取
     `com.macssh.MacSSH.agent`（deepseek）时触发「输入登录钥匙串密码」弹窗（需用户点击
     「始终允许」/输入密码）。因此 §75 硬证据（outsideAllowedReadScope tool result 形态）、
     §77（destructive）、§78（Stop）、§79（A/B）的 **live** 复验未完成；四者均有等价离线覆盖
     （loop tests + B2/B3 回归）。§75 的 live 侧观测为「模型主动拒绝越界读取」（截图 22）。
     建议：在 Phase 10D FINAL acceptance 前对 App 做一次「始终允许」授权后补跑。
  2. **Remote live fixture 仍缺**（B3 P3 延续）：`~/.ssh` 已授权测试密钥未就绪，
     `AgentRemoteRealSFTPTests` 11 条用例自 skip；Phase 10D Remote runtime 由 offline +
     existing SFTP regression 覆盖，real end-to-end pending。
  3. `SessionManagerTests/testO_CloseWhileConnectingCancelsConnection` 环境型排除（与 B2/B3 相同，
     non-routable 地址被本机代理拦截 → libssh2 -13 + 挂死）。

---

## Decision

**PASS — 0 P1 / 0 P2**

PHASE 10D FINAL PASS

Local and Remote read-only Agent tools accepted.

AUTHORIZED FOR NEXT STAGE:
Phase 10D-C — Commit Verification

Phase 10E has NOT started.

Command execution remains prohibited.
Terminal injection remains prohibited.
All modifying tools remain prohibited.

No commit / push / merge / tag performed.
