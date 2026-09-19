# Phase 10F-A — Mutation Tools Architecture Investigation

ARCHITECTURE / INVESTIGATION ONLY。本报告不修改任何 production / test 代码，不注册任何工具，不提交、不推送。

> **R1 修订（Phase 10F-A-R1）**：Independent Acceptance 判 BLOCKED（P1:0 / P2:4）。本文件已按 R1 任务书完成 4 项 architecture remediation（terminal framing / terminal incarnation / file TOCTOU / metadata contract），完整冻结内容见下方「Phase 10F-A-R1 — Mutation Architecture Remediation」章节；前文被取代之处均以 `[R1 修订]` 标注，冲突时以 R1 章节为准。HEAD 仍为 `e958750643aeb9992d4cb357e91dc084130224eb`，零代码修改。

> **R2 修订（Phase 10F-A-R2）**：Independent Acceptance 判 R1 BLOCKED（P1:0 / P2:4）。本文件已按 R2 任务书完成 Delivery Endpoint + Publication Contract Closure：真实 SwiftTerm framing 字节数（6B/6B/12，撤回 R1 的 7B/14）、Accepted 字节术语、TerminalMutationByteWriter acknowledged contract、partial-start 语义、immutable TerminalMutationEndpoint、reconnect 定序、dirfd-bound temp creation（撤回 mkstemp）、CREATE parent capability 语义、source-temp 威胁模型。完整内容见下方「Phase 10F-A-R2 — Delivery Endpoint + Publication Contract Closure」章节；冲突时以 R2 章节为准。HEAD 仍为 `e958750643aeb9992d4cb357e91dc084130224eb`，零代码修改。

> **R3 修订（Phase 10F-A-R3）**：Independent Acceptance 判 R2 BLOCKED（P1:0 / P2:2）。本文件已按 R3 任务书完成 Staging Creation + Durability Contract Closure：① 撤回 `openat(parentFD, stagingName, O_CREAT|…|O_DIRECTORY|…, 0700)` staging 创建原语（本地 man 2 open 实证：`O_CREAT` 只创建文件条目，`O_DIRECTORY` 仅要求被打开目标是目录——该原语建出 0700 普通文件，随后 `O_DIRECTORY` 打开必然 ENOTDIR 失败），冻结 **mkdirat → openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW) → fstat 验证** 的创建/绑定序列、mkdirat→openat 命名空间窗口的 validation 规则与 `StagingDirectoryCapability`；② 撤回 R2.17「dir fsync 后 → durable」表述（本地 man 2 fsync 实证：fsync 不保证 drive 落盘、掉电/OS 崩溃可丢数据；F_FULLFSYNC 才是更强原语），冻结 durability scope 政策 A（v1 不承诺 power-loss durability；fsync = persistence hardening）、pre-publication file sync 为 required gate、post-publication namespace/staging sync 为 best-effort、修订 crash matrix。完整内容见下方「Phase 10F-A-R3 — Staging Creation + Durability Contract Closure」章节；冲突时以 R3 章节为准。HEAD 仍为 `e958750643aeb9992d4cb357e91dc084130224eb`，零代码修改。

## Repository
- path: `/Users/msl/msl_coding/MacSSH`
- branch: `main`
- HEAD: `e958750643aeb9992d4cb357e91dc084130224eb`
- source changed: 0
- tests changed: 0
- staged: 0
- commit: NO
- push: NO
- baseline 证据：`/tmp/macssh-phase10f-a-status-before.txt`（833 B，14 × `?? Docs/*.md`）、`/tmp/macssh-phase10f-a-diff-before.patch`（0 B）、`/tmp/macssh-phase10f-a-cached-before.patch`（0 B）

---

## Current Tool Architecture

### 注册与派发（实测代码位置）

| 组件 | 文件 | 类型 | 职责 |
|---|---|---|---|
| `AgentToolName` | `MacSSH/Services/Agent/Tools/AgentToolModels.swift` | enum（静态注册表） | 5 个工具名的唯一 allowlist；`risk` / `dataAccessPolicy` / `supportsRemoteSession` 三个正交轴 |
| `AgentToolRegistry` | 同上 | enum | `lookup(_:)`：raw name → 枚举；未知名一律 `unknownTool`，禁止 reflection / 字符串派发 |
| `AgentToolDefinition` / `AgentToolCatalog` | `MacSSH/Services/Agent/Tools/AgentToolDefinition.swift` | struct / enum | provider-neutral 定义 + `parametersJSON`（JSON Schema 字符串）；`prohibitedNames` 硬 gate（含 `send_to_terminal`、`write_file` 等全部 mutation 名） |
| `AgentToolCallParsing` | 同上 | enum | raw JSON → typed args 本地验证；run_command 走严格字典校验（`Set(keys) == {"command"}`） |
| `AgentToolPolicy` | `MacSSH/Services/Agent/Tools/AgentToolPolicy.swift` | enum ×2 | `AgentToolRisk`（readOnly/modifying/destructive）与 `AgentDataAccessPolicy`（sessionContext/scopedFileRead/commandExecution）两轴独立，绝不合并 |
| `AgentToolRouter` | `MacSSH/Services/Agent/Tools/AgentToolRouter.swift` | `@MainActor final class` | 只派发 4 个 read-only 工具；`runCommand` 分支**永远**返回 `.failure(.commandRequiresApproval)`，绝不触碰 executor |
| `AgentToolActivity` | `MacSSH/Services/Agent/AgentToolActivity.swift` | struct | tool card 单一来源：`awaitingApproval` / `denied` / `running` / `cancelled` / `timedOut` 等状态 + `resultJSON` |
| `AgentViewModel` | `MacSSH/Services/Agent/AgentViewModel.swift` | `@MainActor @Observable` | `runToolLoop`（10 轮 hard cap、每轮按 provider output order **串行**执行）、`appendToolCardForProviderCall`（run_command 先 register 再发 card）、`executeRunCommand`（awaitDecision → claim → executor）、Stop / prune 取消全链 |
| Provider | `MacSSH/Services/Agent/Provider/ResponsesProviderCore.swift` 等 | protocol + 2 adapters | OpenAI / DeepSeek Responses；请求体硬 gate `{model,input,stream}` + tool definitions；`snapshotForGeneration()` 冻结凭据 |
| Approval UI | `MacSSH/Features/Agent/AgentToolCardView.swift` | SwiftUI | 只消费 coordinator snapshot；Approve/Deny 经 `AgentViewModel` façade；不可编辑 payload |
| Command domain | `MacSSH/Services/Agent/Command/`（5 文件）+ `Execution/`（本地 posix_spawn / 远程 exec） | actor + structs | 见下节 |

### 关键问题的实测回答

1. **五个 tool 在哪里注册？**
   唯一注册点：`AgentToolName` 枚举（静态）+ `AgentToolCatalog.definitions`（恰好 5 条，B4 phase boundary）。Provider 每轮请求只见这份定义列表（`AgentViewModel.runToolLoop` 传入 `AgentToolCatalog.definitions`）。

2. **read-only tools 与 run_command 如何区分？**
   三层区分：
   - 定义层：`AgentToolRisk` / `AgentDataAccessPolicy` 正交轴；
   - 解析层：`AgentToolCallParsing.parse` 对 run_command 走严格 `{"command"}` 字典校验，未知键即 `invalidArguments`；
   - 派发层：`AgentToolRouter.execute` 的 `.runCommand` 分支硬编码返回 `.commandRequiresApproval`——Router 永远不执行命令。

3. **run_command 在 Router 内执行还是 ViewModel 接管？**
   **ViewModel 接管**。完整链路（`AgentViewModel`）：
   ```
   Provider stream .toolCall
     → appendToolCardForProviderCall（仅 run_command）
         → AgentToolCallParsing.parse
         → AgentCommandRequestFactory.make（validation + authoritative cwd gate）
         → approvalCoordinator.register(request)   ← actor
         → append awaitingApproval card
   （本轮 streaming 结束后，按 output order 串行：）
   → executeTool → executeRunCommand
         → approvalCoordinator.awaitDecision(approvalID)
         → approved → claimExecution(expected: generation/session/providerSnapshot)
         → card 置 running（UI 先于 side effect 移除 Approve/Deny）
         → localCommandExecutor / remoteCommandExecutor.execute(authorization:)
             → executor 内 approvalCoordinator.redeem(authorization)（唯一消费点）
         → updateToolActivity(result)
   → function_call_output 回填 → provider continuation
   ```

4. **Provider function_call → Tool Loop → result 完整路径**
   `AgentProvider.stream(transcript:tools:context:)` → 事件 `.toolCall(AgentProviderToolCall{callID,name,argumentsJSON})` → 上述链 → `AgentToolActivity.resultJSON` → transcript 重建时按 `call_id` 严格配对输出 `function_call` / `function_call_output`（`AgentToolActivity` 文档 §14；resultJSON 为空时输出结构化 cancelled，保证配对恒成立）。

### 串行性（对 §22 的现成回答）
`runToolLoop` 已按 §27 冻结「本轮全部 calls 按 provider output order 串行执行，执行完才 continuation」。因此同一 round 出现两个 `send_to_terminal` 时天然是：A 卡片批准 → 注入 → result → B 卡片批准 → 注入 → result。**不存在多 approval 并行注入 PTY 的路径**；10F 只需禁止任何“并行执行优化”。

---

## Existing Command Approval

### 类型清单（10E-B1 已验收，当前 HEAD 实测）
| 类型 | 文件 | 语义 |
|---|---|---|
| `AgentCommandRequest` | `Command/AgentCommandRequest.swift` | immutable 六元组（generationID/callID/sessionID/target/command/workingDirectory）+ providerBinding；`fileprivate init`，唯一构造入口 `AgentCommandRequestFactory`；description 全 redacted |
| `AgentCommandApprovalState` / `Resolution` | `Command/AgentCommandApproval.swift` | 单向状态机 `awaitingApproval → approved/denied/cancelled；approved → executionClaimed`；denied 与 cancelled 严格区分（userDenied vs cancelled） |
| `AgentCommandApprovalCoordinator` | `Command/AgentCommandApprovalCoordinator.swift` | **actor**，审批唯一 authority：register（同 `(generationID,callID)` 幂等）/ approve/deny/cancelApproval / cancelGeneration / cancelSession / purge* / claimExecution（CAS：绑定三元校验 + 状态校验，生成一次性 permit）/ redeem（单次消费，permit 核对）/ awaitDecision（waiter resume exactly once，Task 取消只摘 waiter） |
| `AgentCommandExecutionAuthorization` | `Command/AgentCommandExecutionAuthorization.swift` | opaque capability：permit + immutable request；redacted description |

### 回答：命令专用还是可推广？

**结论：这些类型是“命令执行专用”，不适合直接复用；推荐 B（新建 mutation 专用 coordinator，复制已验收的状态机语义），并把“抽象公共 approval core”（选项 C）推迟为 10F-C 之后的非安全重构。**

强行复用会产生以下语义错误（实测推导）：

1. **`AgentCommandRequest.workingDirectory` 是 mandatory**（`AgentCommandRequestFactory` 对 `confidence == .authoritative` + 绝对路径有 hard gate，失败即 `cwdUnavailable`）。`send_to_terminal` 不需要也不能依赖 authoritative cwd（交互 shell 的 cwd 是会话自身状态）；`write_file` 需要的是 canonical root 而非 cwd。为复用而放宽 factory 校验 = 削弱 10E 已验收的 cwd gate。
2. **`command: String` 单字段语义**。terminal mutation 的 payload 是 `text + submit`（含 newline 的多行文本），file mutation 是 `path + content`；塞进 `command` 字段会导致 approval domain 的 validation（`AgentCommandValidation`）、结果序列化、日志 redaction 全部按“shell 命令”解释——类型系统在撒谎。
3. **target 语义漂移**：`AgentCommandTarget` 是 `{local,remote} + displayName`，但 mutation 还需携带 frozen payload 身份（路径 / 终端会话句柄）；硬塞会让「exact target binding」从结构性保证（`let` 字段）退化为约定。
4. **结果类型不同**：命令结果是 bounded stdout/stderr；terminal 是 byte accounting（partialDelivery）；file 是 created/overwritten + bytesWritten。coordinator 不该知道这些，但 request 类型携带的信息决定了 executor 能拿到什么。

但以下 10E 冻结的安全性质**必须逐条保留**（复用或重写都一样）：

- exact target binding（immutable request，executor 绝不重传）
- exact payload binding（approve 的 A 执行的就是 A）
- one-time claim（CAS `approved → executionClaimed`）
- one-time redeem（permit 单次消费）
- replay protection（permit 核对 + `approvalAlreadyClaimed`）
- generation binding（claim 期望三元：generation/session/providerSnapshot）
- provider snapshot binding
- denied ≠ cancelled 语义
- memory-only 记录、redacted 日志
- Stop / session close / generation 替换的批量失效路径

**推荐落地方式**：10F-B1 新建 `AgentMutationApprovalCoordinator`（或按域命名 `AgentTerminalSendApprovalCoordinator`），结构与 `AgentCommandApprovalCoordinator` 同构（actor + 单向状态机 + CAS claim + permit redeem + waiter exactly-once）。**不在 10F 内做泛型抽象**——在只有一个新消费者时抽 core 是为了复用而移动安全代码；待 10F-C（file mutation）落地、两个消费者稳定后，再以「行为等价 + 全测试矩阵并行」的方式抽取公共 core。在此之前，重复一份状态机是可接受且更安全的成本。

---

## send_to_terminal

### Semantics
`send_to_terminal` **不是 run_command 的另一种 executor**。正式语义表：

| 维度 | run_command（已实现） | send_to_terminal（10F 目标） |
|---|---|---|
| 执行体 | 独立进程（posix_spawn）/ 独立 SSH exec channel（无 PTY） | 现有 interactive PTY（Local）/ 现有 SSH shell channel（Remote） |
| shell state | 完全不影响 interactive shell：cwd / env / history / job table 不变 | **直接修改**：`cd`、`export`、`source`、`ssh other-host`、`vim`、`sudo` 等永久改变会话状态 |
| 生命周期 | 命令结束即收尾（timeout/grace/killpg） | 字节注入后不可撤回，无进程边界可清理 |
| 输出 | 捕获并 bounded 返回（256 KiB ×2） | 不捕获；观察走 `get_terminal_context` |
| stdin | 无 | 即是“往 stdin/PTY 写” |
| 失败语义 | exit code / timedOut / killed | byte accounting（delivered/partial/closed） |

`cd /tmp` 经 run_command 执行后，用户终端 cwd 不变；经 send_to_terminal 执行后，interactive shell cwd 永久改变。这是两类的根本分界，Approval UI 必须用不同文案。

### Schema（冻结）
```json
{
  "type": "object",
  "properties": {
    "text":   { "type": "string", "description": "Exact UTF-8 text to inject into the interactive terminal. Newlines are delivered literally inside bracketed paste; control characters other than LF are rejected." },
    "submit": { "type": "boolean", "description": "When true, one carriage return is appended after the text (submits the current shell line)." }
  },
  "required": ["text", "submit"],
  "additionalProperties": false
}
```

候选比较（§10）：
- **Option A `{command}` 自动追加 Enter**：与 `run_command` 的 `command` 字段同名同型——模型（与用户）会把两者混为一谈，且“自动 Enter”不可控（无法只粘贴不执行）。**拒绝**。
- **Option B `{text, submit}`**：submit 显式化，卡片可显示“是否自动按 Enter”；单字段 `text` 与 `run_command.command` 名字分离，降低语义混淆；支持“只粘贴长命令让用户检查，再由第二次调用 submit=true 提交”的安全工作流。**采纳**。
- **Option C `{text}` 永不 Enter**：安全但模型可控性差——提交换行变成“发送 `\r` 文本”绕回 control-char 问题；且模型经常需要立即执行。**拒绝**。

- required: `text`, `submit`（两者都必填，杜绝“缺省即执行”歧义）
- additionalProperties: false（与既有 5 工具一致；`AgentToolCallParsing` 对新工具走严格字典校验：`Set(keys) == {"text","submit"}`，缺键/多键/类型错 → `invalidArguments`）

### Payload（冻结）

| 项 | 决定 |
|---|---|
| 编码 | UTF-8；解码失败 → `encodingInvalid` |
| max bytes | **64 KiB**（UTF-8 编码后字节数，硬上限，常量冻结；模型无法经 schema 提高） |
| 多行 | `text` 内允许 LF（U+000A）作为行分隔；经 SwiftTerm `pasteText` 的 bracketed paste（DECSET 2004）语义交付——支持 bracketed paste 的 shell（zsh/bash 默认）不会在粘贴中途执行 |
| newline 处理 | `submit == true` 时由 delivery 层追加**恰好一个** CR（`EscapeSequences.cmdRet = [13]`，与键盘 Return 同字节）；`text` 自身不以 CR 结尾的需求被显式拒绝而非静默重写 |
| CR/LF normalization | **拒绝 CR（U+000D）**：出现即 `encodingInvalid`（不静默转 LF/删除——遵循项目「静默改写语义比拒绝更危险」原则）。LF 原样保留，不做 CRLF 转换 |
| 允许字符集 | 所有合法 UTF-8 scalar，**除**下述拒绝集；唯一例外：LF (U+000A) 允许 |
| 拒绝字符集 | NUL (U+0000)；C0 控制 (U+0001–U+001F，含 TAB/VT/FF——首版一并拒绝，避免 tab-completion 注入)；CR (U+000D)；DEL (U+007F)；C1 控制 (U+0080–U+009F)。即：**ESC / CSI / OSC / BEL 序列在字节层面不可能出现**——模型无法生成任意 PTY control bytes |
| Ctrl-C / Ctrl-D / Ctrl-Z | 首版不可能：对应字节 0x03/0x04/0x1A 全在拒绝集。向 interactive 程序发送信号级按键不是本工具目标 |
| 多行 + 无 bracketed paste 的残余风险 | 若远端程序未启用 DECSET 2004，嵌入 LF 会立即执行该行。缓解：Approval Card 逐行显示 payload（换行可见），用户批准的是完整文本；该风险写入 tool description（“newlines are delivered literally; shells without bracketed paste may execute each line”）。**[R1 修订]** 由此确立 `submit=false` 的正式保证（见 R1.5）：只承诺不追加 CR，不承诺“不执行” |

### Binding（冻结）
- generation：request 含 generationID；claim 期望校验。
- callID：同 10E，register 幂等键 `(generationID, callID)`。
- sessionID：generation 开始时冻结的 **origin sessionID**（`AgentViewModel.startGeneration` 的既有语义）；**[R1 修订]** sessionID 只是 logical identity，delivery 不按 sessionID 重查——按冻结的 `TerminalInputTargetIdentity`（sessionID + inputTargetEpoch + endpointToken，R1.6）直接寻址具体 endpoint 对象。
- provider snapshot：同 10E（`providerSnapshotID` 在 generation 创建时生成，贯穿全部 request）。
- active-tab fallback：**禁止**。绝不读 `SessionManager.activeSession`；找不到 sessionID → `sessionUnavailable`，绝不 fallback 第一个终端 / hostname 匹配。用户批准后切换 tab：批准仍作用于冻结的 session A。
- payload：immutable request 持有 exact `text` + `submit`；executor 只从 coordinator `redeem` 获得的 request 读 payload，绝不重读卡片/参数。

### Local Path（§15 实测）
- 键盘输入链：SwiftTerm `TerminalView` 键盘/IME → `insertText` → `send(source:data:)` delegate。Local 场景 delegate 即 SwiftTerm 自身：`LocalProcessTerminalView.send` → `LocalProcess.send` → DispatchIO → **PTY master fd**（`Docs/Phase7B-Final-Report.md` §8 已实证）。
- `TerminalCommandDispatcher` 做什么：Phase 7 的 UI 粘贴/执行调度器——每次实时读 `SessionManager.activeSession` 解析 active tab、预检 `displayState == .active`、`pasteText(command)` + `sendReturn`、append CommandHistory、restoreFocus。
- **Phase 7 `execute(command:)` 不可复用**，理由：
  1. 按 **active tab** 解析目标（`sessionManager.activeSession`）——直接违反 exact session binding；
  2. 无 approval、无 coordinator、无 identity binding——独立 side effect 路径；
  3. 副作用耦合：append CommandHistory + restoreFocus（focus 抢夺会打断用户）；
  4. `pasteText + sendReturn` 的组合无法承载 per-call submit 绑定（两步之间可被用户输入穿插）；
  5. 无 byte accounting（fire-and-forget）。
- **PTY writer（10F-B2 冻结方案）**：不新增平行进程、不重开 fd；在 **SwiftTerm fork 内**新增一个带字节计数返回的发送入口（fork 归本项目所有，pin 管理，`Docs/SwiftTermFork.md` 既有先例），由 `AgentTerminalSendService`（新，10F-B2）持有 session 绑定的 view/service 引用调用。动机：`LocalProcess.send` 走 DispatchIO，对调用方不返回 written-byte 数，无法支撑 partial delivery 语义——这是 §49 明确禁止的“已有 pasteText 就很简单”捷径的反面：**必须先补齐 byte-accounting 能力再做工具**。
- partial write：delivery 层循环按 offset 推进，记录 `bytesDelivered`；中断/取消时如实返回 partial。
- cancellation：首字节前 cancel → 零字节；部分交付后 cancel → `partialDelivery`（不可谎报零副作用）。

### Remote Path（§16 实测）
- 键盘输入链：SwiftTerm `TerminalView.send(source:data:)` delegate → `RemoteTerminalService.send`（`RemoteTerminalService.swift:431`）→ `connection.writeChannelInput(data)`。
- 底层 API：`SSHChannel.writeChannelInput`（`SSHChannel.swift:262`）→ `libssh2_channel_write_ex(channel, 0, …)`，non-blocking。
- EAGAIN：`waitForLibssh2Readiness`（poll + `libssh2_session_block_directions`），有界 deadline（`ChannelTimeouts.write`）。
- partial write：**已正确处理**——`offset + remaining` 循环直到全部写完（`SSHChannel.swift:291–323`）；`CHANNEL_CLOSED` → `channelClosed`，其它错误码 → `channelWriteFailed`。
- 断开：`validateChannelOperation` 每轮校验 session/channel；`connectionLost` / `channelClosed` 抛出，读取循环统一收敛 UI 状态。
- session 绑定：delivery 只经 origin sessionID 解析出的 `SSHConnection`（既有已认证会话），绝不新建连接（§43）。
- **10F-B3 冻结改造点**：`writeChannelInput` 失败时只抛错误、不报 `offset`。需新增（或扩展为）返回 `bytesDelivered` 的变体（成功 = 全量；失败 = 已写字节数），供 delivery 层 partial delivery 上报。原方法保持不动（键盘路径零回归）。

### Approval UI（冻结）
- 字段：Target（Local / Remote）、frozen session 身份（displayName + sessionKind + 内部 sessionID 短码）、exact payload（多行逐行显示，换行符号可见）、`submit` 标志（“将自动按 Enter”）、字节计数。
- 警示文案（不可省略）：“将直接输入当前交互终端：可能改变 cwd、环境变量、shell 状态，也可能启动程序或执行命令。”——与 run_command 的“独立执行，不影响交互终端”形成对照。
- editable：**否**。payload read-only；用户要改 → Deny → 重新向 Agent 提要求（§18 延续 10E 规则）。
- 状态复用 `AgentToolActivity.Status` 现有集合（awaitingApproval/denied/running/success/failure/cancelled），卡片渲染复用 10E R2 修好的 AX/containment 形态。

### Result（**[R1 修订]** 字段语义冻结，取代笼统 bytesRequested/bytesDelivered；见 R1.4）
```json
{
  "status": "delivered | partialDelivery | userDenied | cancelled | approvalStale | targetReplaced | sessionUnavailable | payloadRejected | writeFailed",
  "payloadBytesRequested": 1234,
  "payloadBytesAccepted": 1234,
  "framingBytesRequested": 12,
  "framingBytesAccepted": 12,
  "submitRequested": true,
  "submitAccepted": true,
  "bracketedFramingUsed": true,
  "terminalState": "confirmed | uncertain",
  "sessionID": "…"
}
```
- **不捕获终端输出**：`send_to_terminal` 不是 command capture executor；把交互终端 scrollback 自动当作 tool result 会引入无界数据与注入边界。
- 模型需要输出 → 下一步调用 `get_terminal_context`（现有 observation 通道）。

### Races（冻结）
| race | 语义 |
|---|---|
| pending → session close | `cancelSession(sessionID)`（与 10E 相同的 prune 路径：`AgentViewModel.pruneConversations`）→ approval cancelled；late Approve → `alreadyResolved`，**零字节写入** |
| pending → A 重连为新 SSH session | **[R1 修订]** Reconnect **必然**使 `inputTargetEpoch` 改变（reconnect 路径强制契约；ManagedTerminalSession.id 不变）：旧 approval 在 side effect 前 deterministic stale → `targetReplaced`，零字节。**不得**再以“write 自然失败”作为安全保证；绝不静默重连（§42） |
| pending → 用户切 tab | 无影响：binding 是 sessionID 非 active 指针 |
| approved → session close before send | claim 可成功但 delivery 寻址失败 → `sessionUnavailable`，零字节 |
| 断连发生在 write 中途 | `bytesDelivered < bytesRequested` → `partialDelivery` |
| awaiting → Stop | generation task 取消 + `cancelGeneration` 失效 → 零写入 |
| awaiting → generation 替换 | 新 Send 前 `endGeneration`/identity guard → 旧 approval cancelled；late Approve 零写入（§41） |
| pending → Settings 换 Provider | claim 期望含 `providerSnapshotID` → `bindingMismatch`；continuation 用 generation 开始时冻结的 provider A（§40，10E 语义原样） |
| double approve | 状态机 `alreadyResolved`；double claim → `approvalAlreadyClaimed`；double redeem → 同 |

---

## File Mutation

### First Tool（冻结）
- **name：`write_file`**（Option A，仅此一个）。
- why：最小 mutation surface。`create_file` 与 write_file 的 create 模式重叠（用 `created/overwritten` 区分即可）；`apply_patch` 引入 diff 语义/锚点失败等新失败面；`mkdir` 扩大目录树副作用（首版要求 parent 已存在，`parentDirectoryMissing` 拒绝）；delete/rename/chmod/move/copy/upload 全部留在 prohibitedNames。
- 一次引入两个工具（10F-B + 10F-C 同时）没有验收收益，只有两套新审批 UI 并行验收的成本。

### Schema（冻结）
```json
{
  "type": "object",
  "properties": {
    "path":    { "type": "string", "description": "Absolute or relative target path under the terminal session's allowed root." },
    "content": { "type": "string", "description": "Full UTF-8 text content to write. The entire file is replaced on overwrite." }
  },
  "required": ["path", "content"],
  "additionalProperties": false
}
```
- required: 两者；严格字典校验同 run_command 模式。
- 无 “mode/append/base64” 参数——杜绝模型提权面。

### Scope（冻结）
- root：复用 generation 冻结的 **canonical allowed root**（`AgentReadScope.allowedRoots[0]`，authoritative OSC7 cwd 来源不变），但新建独立 domain 类型 **`AgentWriteScope`**（10F-C1）：sessionID + canonical root + 自己的 containment/验证方法。
- absolute path：允许（经 canonicalize + containment 后判定；与 read_file 同规则）。
- traversal：`..` 在 kernel-walker canonicalize 中正确处理（`AgentPathResolver.canonicalize` 已验收）。
- parent canonicalization：**parent 全链逐组件解析**（kernel-like walker），parent 中任一 symlink target 逃出 root → `outsideWriteScope`。
- final symlink：**拒绝**（`symlinkRejected`）：approval 时 `lstat` final 组件，`S_IFLNK` 即拒——绝不“写入 symlink 指向的文件”，因为用户批准的是路径字符串，不是 link 目标。
- hard link：不探测（macOS 无用户级 hard-link 防护原语）；约束声明：write_file 语义只对 path 身份负责；hard-link 场景写入已有 inode 属于 OS 语义，记录为已知边界。
- **`AgentReadScope` 不得被当作 `AgentWriteSandbox`**（§26）：read scope 的判定对象是“canonical 路径落点”，写场景还必须处理——TOCTOU（read 校验与 open 之间状态可变）、已存在文件的替换语义（read 无此概念）、目录替换、final-symlink 穿透（read 走 canonicalize 跟随 link；写必须**拒绝** link）、原子性与 partial failure。两套 scope 必须是两个类型。

### TOCTOU（冻结策略）
批准时刻与写入时刻之间，攻击者可替换 final target 或 parent 组件。策略（Local）：
1. **approval 时**：canonicalize parent；`lstat` final：
   - ENOENT → operation = `CREATE`；
   - regular file → operation = `OVERWRITE`，记录 identity `(st_dev, st_ino, st_size)`；
   - symlink / directory / 其它 → `symlinkRejected` / `targetNotRegularFile`。
2. **write 时**（**[R1 修订]** v1 仅 CREATE，见 R1.7）：
   - parent 以 **directory fd** 打开（`open` + `O_DIRECTORY`），后续全部 `openat`/`renameat` 相对该 fd——parent 路径组件中途被换不影响已持 fd 的目录；
   - parent 身份复核：`fstatat(dirfd, ".", AT_SYMLINK_NOFOLLOW)` 与 approval 时 parent `(st_dev, st_ino)` 比对——在**同一 fd** 上校验后，全部后续操作都相对该 fd（fd 钉住目录对象），不存在 check-then-use；不符 → `targetChanged`；
   - `CREATE`：同目录 `mkstemp`（`O_CLOEXEC`）→ 写全量 → `fsync(file)` → **`renameatx_np(dirfd, tmp, dirfd, P, RENAME_EXCL | RENAME_NOFOLLOW_ANY)`** 原子 no-replace 发布 → `fsync(dirfd)`。`EEXIST` → `targetChanged`（approval 与发布之间 P 出现，绝不静默转 overwrite）；symlink 在发布点同样 `EEXIST` 拒绝。卷不支持旗标（EOPNOTSUPP/EINVAL）→ 备选 `linkat`（同样 no-replace）→ unlink tmp。直写 `O_CREAT|O_EXCL` 方案（目标 pathname 写入期间可见）**废弃**，改为原子发布；
   - `OVERWRITE`：**v1 不支持**——approval 时 target 已存在 → `targetExists` 拒绝。原「openat → fstat identity 复核 → renameat」设计**撤回**：fstat 校验的是已打开 fd 的身份，而 renameat 替换的是 pathname，check 与 renameat 之间攻击者 rename 到 P 的对象会被 clobber——**该路径不关闭 TOCTOU**，详见 R1.7。
3. **不使用** `path.hasPrefix(root)` 式判定（项目已有 path-component aware containment，10D-B1 已验收）；canonical 判定 + fd-relative 原语 + identity 复核三层叠加。
4. 所需原语（`openat` / `O_NOFOLLOW` / `renameat` / `fstat`）Darwin 全部可用，无需额外依赖。**[R1 修订]** 发布原语升级调研结论见 R1.7：renameatx_np(10.12+) 提供 RENAME_EXCL / RENAME_SWAP / RENAME_NOFOLLOW_ANY / RENAME_RESOLVE_BENEATH（SDK `sys/stdio.h` 实测）；**不存在** "replace destination only if still inode X" 的原子 CAS 原语（明确 NO）。

### Existing File（**[R1 修订]** v1 仅 CREATE）
- approval card 一级字段：`CREATE`（v1 唯一操作）；target 已存在 → `targetExists` 拒绝，卡片明示“本版本不支持覆盖已有文件”。
- approval 时收集：是否 regular file、byte size（OVERWRITE 显示 existing size）、symlink（拒）、权限位（卡片显示，供用户判断）。不自动读取旧文件内容，也绝不发送给 Provider——除非模型此前已通过 `read_file` 获得该信息。

### Local Write（冻结）
- open strategy：见 TOCTOU 节（fd-relative + O_NOFOLLOW + identity 复核）。
- temp strategy（**[R1 修订]** CREATE 唯一路径，见 R1.7）：同目录 `mkstemp`（`O_CLOEXEC`）→ write → `fsync(file)` → **`renameatx_np(dirfd, tmp, dirfd, name, RENAME_EXCL|RENAME_NOFOLLOW_ANY)`** 原子 no-replace 发布（备选 `linkat`）→ parent dir `fsync`。OVERWRITE DEFERRED TO SPIKE。
- atomicity：OVERWRITE 观察者要么看到旧文件要么看到完整新文件；进程崩溃 / disk full 只影响 tmp（孤儿 tmp 在 cleanup 中移除），目标文件不会半新半旧。
- cleanup：所有失败路径关闭 fd + unlink tmp；`AgentLocalFileService` 既有结构上加 mutation 层（10F-C2 新类型，不复用 read-only service 的写通道——read service 保持 read-only 性质可被静态断言）。
- partial failure：
  - tmp write 中途失败 → unlink tmp → `writeFailed`（磁盘满 / EACCES 等），目标文件未动；
  - rename 失败 → unlink tmp → `writeFailed`；
  - 写入字节数不足（partial write on regular file：write loop 直到完成或错误，disk full → `partialWrite`）→ unlink tmp。
- 权限：新文件 `0o600`（umask 收敛后）；**[R1 修订]** v1 无 OVERWRITE ⇒ “0755 script 悄悄变 0600” 场景结构上不存在；future OVERWRITE 的 metadata contract 逐项冻结见 R1.8（mode PRESERVE 强制，ACL/xattr/uid/gid RESET 强制披露）。

### Remote Write（冻结：**DEFERRED**）
现状实测（`SFTPSession.swift` / `SFTPFileOperations.swift` / `SSHConnection.swift`）：
- 已具备：`sftpRealpath`（`libssh2_sftp_symlink_ex` + REALPATH 模式）、`sftpStatFile`（`LIBSSH2_SFTP_STAT`，**跟随** link；LSTAT 旗标未使用）、open-for-read / open-temp-for-write / write-chunk（EAGAIN 安全）/ close、`sftpRenameFile`（`libssh2_sftp_rename_ex`）、`sftpUnlinkFile`、`sftpCreateDirectory`。
- 无法保证的事项：
  1. **fsync**：libssh2 无公开 fsync（OpenSSH `fsync@openssh.com` 需要 FXP_EXTENDED，libssh2 未封装）→ crash-consistency 无法承诺；
  2. **rename 语义**：`rename_ex` 的 overwrite/noreplace 旗标行为依赖服务器 SFTP 版本；
  3. **TOCTOU**：realpath/stat 是 client 视角的快照，server 侧竞态（parent/final 被换）**无法从 client 消除**——`O_NOFOLLOW`/directory-fd 无 SFTP 等价物；
  4. readlink 能力存在（`symlink_ex` READLINK/LINK 模式）但 LSTAT/readlink 校验链仍未构成 Local 级强保证。
- **recommendation：Phase 10F 首实现仅 Local write；Remote write 明确 defer**。若未来实现，前置条件是：LSTAT+readlink 逐组件校验链 + rename 旗标行为 + fsync 可行性的确定性 spike，且文档明示 server-side TOCTOU 残余风险（不得夸大 guarantee）。这比把弱保证的 Remote write 塞进首版更安全（§32 允许并推荐此选项）。

### Limits（冻结）
- content type：UTF-8 text only。
- UTF-8 验证：`String(decoding:as:)` 可容忍无效序列——必须用 `String.validUTF8`/严格转换校验原始 bytes；无效 → `encodingInvalid`。
- binary / base64：**首版排除**（无 base64 参数位，schema 层面即不可能）；写入前校验 content 为合法 UTF-8 且不含 NUL。
- maximum size：**256 KiB**（与 `read_file` 上限对称；覆盖 Provider request 体量、Swift 内存、Approval UI preview、日志截断的全部考量；常量冻结，模型不可协商）。

### Approval UI（冻结）
- operation：`CREATE`（**[R1 修订]** v1 唯一操作；OVERWRITE 不出现于卡片）。
- path：normalized canonical absolute target + frozen root 标注。
- host/session：Local / Remote + session 身份。
- size：content byte count；OVERWRITE 另显示 existing size。
- preview：collapsed preview（首 N 行 / 首 N 字节）+ 截断指示器（“预览已截断，共 X 字节”）。
- full content：**架构预留**「collapsed preview + 显式展开查看完整内容」能力（大 payload 不允许只显示“写入 200 KB”）；展开 UI 本体在 10F-C4 实现，10F-A 只冻结信息架构与数据通道（card 已持有 full content——payload 本来就在本地，无需新增传输）。

### Result（冻结）
```json
{
  "operation": "created",
  "path": "/canonical/target/path",
  "bytesWritten": 1234,
  "ok": true
}
```
- 失败：`{"ok": false, "error": "<frozen error code>"}`（见下）。
- **不 echo content**：Provider 本来就知道它提交的 content，回显只浪费 request 体量并制造泄漏面。

### Failure Semantics（冻结，§38 全集）
`userDenied` / `approvalStale` / `targetReplaced`（**[R1 新增]** incarnation/identity 不符，归入 approvalStale 家族）/ `targetUnavailable`（父目录缺失、session 不可寻址）/ `scopeViolation` / `symlinkRejected` / `unsupportedFileType`（含 targetNotRegularFile）/ `fileTooLarge` / `targetExists`（**[R1 新增]** v1 覆盖请求拒绝）/ `writeFailed` / `partialWrite` / `sessionUnavailable` / `cancelled` / `targetChanged`（TOCTOU：发布时 P 已存在 / parent 身份不符，归入 approvalStale 家族）/ `parentDirectoryMissing`。`encodingInvalid` **移出** tool-level taxonomy（见 R1.9）。
系统原始 errno **不暴露**给模型：executor 内部映射为上述稳定码；诊断细节只进本地日志（无内容）。

---

## Risk Taxonomy（冻结，§44）

| 分类 | 工具 | UI disclosure |
|---|---|---|
| `readOnly` | get_terminal_context / get_current_directory / list_directory / read_file | 无审批；卡片无警示 |
| `commandExecution` | run_command | “独立非交互执行，不影响当前终端状态” |
| `interactiveTerminalMutation` | send_to_terminal（10F-B） | “直接输入当前交互终端，永久改变 shell 状态” |
| `fileMutation` | write_file（10F-C） | “创建/覆盖文件（路径、大小、CREATE/OVERWRITE 明示）” |

实现：不得把四类压成 `readOnly/modifying` 二元后共用文案。落点：保留 `AgentToolRisk` 两轴不动（它们已被测试锚定），新增工具级 mutation 分类（`AgentToolName` 新 case 的 `risk`/`dataAccessPolicy` + 卡片按工具名选择 disclosure 文案）；是否合并 enum 属实现细节，**性质上**必须四类可区分。

## Agent Loop（冻结，§21/§22）
- serial ordering：沿用 `runToolLoop` 既有逐轮串行；同轮多个 mutation call 逐个 approval→deliver→result，禁止并行 approval / 并行注入。
- approval：卡片永远先于任何 side effect（run_command 模式复制：validate → request → register → awaitingApproval card）。
- result：delivery result only。
- observation：输出观察只走 `get_terminal_context`；send 工具绝不内置 “sleep + scrape”。

## Logging / Secrets（§39）
现状定位：
- Agent 域日志：`AppLogger.agent`（Provider 层：HTTP 状态码、事件码、无 request body/response body）；`AppLogger.terminal`（连接生命周期，无内容）。
- 10E 冻结模式：`AgentCommandRequest` / `AgentCommandApprovalSnapshot` / `AgentCommandExecutionAuthorization` 的 `description`/`debugDescription` 显式 redacted（`content: <redacted>`），防 Swift 合成 reflection 泄漏。
- 凭据：仅 `AgentCredentialService`（Keychain）+ `AppLogger.security` 只记事件（"upserted"/"deleted"）。
- 10F 约束（冻结）：mutation payload（terminal text / file content）**绝不**进入 OSLog、debugDescription、analytics、crash metadata；10F 新类型照抄 redacted-description 模式；card 的 `resultJSON` 不含 payload。

---

## Phase 10F-A-R1 — Mutation Architecture Remediation

Independent Acceptance 判 BLOCKED（P1:0 / P2:4）。本章节按 R1 任务书完成 4 项 architecture remediation；本阶段零 production/test 代码修改、零 commit/push，仅更新本文件（untracked, not staged）。前文与之冲突处以本章节为准。

R1 preflight 实测：branch `main`；HEAD `e958750643aeb9992d4cb357e91dc084130224eb`；staged 0；production/test tracked diff 0；仅 untracked Docs。

---

### R1.1 Logical Payload 与 Physical Wire Frame（Remediation 1）

两个概念正式分离：

- **payloadBytes** := `UTF-8(text)` 编码后的字节数，`1 ≤ payloadBytes ≤ 65536`（64 KiB 上限不变）。
- **wireBytes** := 实际进入 PTY master fd / SSH shell channel 的物理字节序列：

```
wire = [bracketedPasteStart (6B: ESC [ 2 0 0 ~)]   // [R2 修订] 实测 6 字节，R1 原文 7B 有误
      + payloadBytes
      + [bracketedPasteEnd   (6B: ESC [ 2 0 1 ~)]   // [R2 修订] 实测 6 字节
      + [submit CR           (1B: 0x0D)]
```

- **bracketed framing 决策**：delivery admission 时刻读取终端 emulator 的 DECSET 2004 状态**一次**（唯一事实来源 = SwiftTerm Terminal mode 状态；本 frame 期间不重读）。enabled ⇒ frame planned（`framingBytesRequested = 12`，**[R2 修订]** 原文 14 有误）；disabled ⇒ 原始 payload 直写（`framingBytesRequested = 0`，wire = payload [+ CR]）。
- **model-controlled vs trusted delivery framing**：模型 payload 拒绝集不变（NUL / C0 除 LF / CR / DEL / C1）。**修正表述**：~~ESC 在 wire 层绝不可能出现~~ → **模型无法直接提供任何 ESC / control bytes；delivery subsystem 可以生成固定、受代码控制的 bracketed-paste framing（自身含 ESC）与 submit CR**。framing 字节为编译期常量序列，不存在模型可控通道。

### R1.2 Frame State Machine 与逐阶段失败语义（Remediation 1）

语义状态集（实现不强制 enum 名称，语义等价即可）：

```
notStarted → frameStarted → payloadDelivering → payloadDelivered → frameClosed → submitDelivered
```

| 失败点 | 处理 | 结果语义 |
|---|---|---|
| **start marker 发送失败**（notStarted） | **[R2 修订]** 本行原「零字节 ⇒ 一律 confirmed 干净失败」表述**撤回**，按 accepted 前缀细分：0 = 干净失败（confirmed）；1…5 = partial escape sequence 已进入 transport ⇒ `terminalInputStateUncertain` + chain halt；6 = frameStarted 继续。禁止 partial START 后自动补发 end marker | 详见 R2.4 |
| **payload 失败**（frameStarted/payloadDelivering，已交付部分 payload） | **best-effort 单次**尝试发送 end marker：成功 → frame 闭合，shell 粘贴缓冲定型为 partial 文本且（bracketed paste 生效时）未执行；失败 → frame 开放不可确认 | `partialDelivery`；闭合成功 → confirmed；闭合失败 → **terminalInputStateUncertain** |
| **end marker 失败**（payloadDelivered，payload 完整） | best-effort 单次重发 end marker；仍失败 ⇒ frame 开放、内容已全部进入 | `partialDelivery`（framingBytesDelivered < requested）；**terminalInputStateUncertain** |
| **submit CR 失败**（frameClosed） | **不重试**（1 字节交付失败与实际已落盘不可区分，重试可能双执行）；frame 已闭合，内容在粘贴缓冲 | `partialDelivery`；submitDelivered=false；terminalState=**confirmed**（漏 Enter 是良性态，模型经 result 得知） |
| 完成（submitDelivered） | — | `delivered` |

**用户 Stop 逐阶段**：

| Stop 时刻 | 行为 | 结果 |
|---|---|---|
| frame 开始前 | 零字节 | `cancelled`，confirmed，干净 |
| start 后、payload 中 | 立即停止 payload 推进 + best-effort end marker | `cancelled`（含 byte accounting）；闭合未确认 ⇒ uncertain |
| payload 后、end 前 | best-effort end marker | 同上 |
| end 后、submit 前 | **不发 CR**（Stop 即不执行） | `cancelled`，submitted=false，confirmed，干净 |
| submit 后 | 已完成，无 cancel | `delivered` |

### R1.3 terminalInputStateUncertain 语义（采纳推荐，安全优先）

定义：frame 已开始但无法确认正常闭合（end marker 交付失败/不可确认）⇒ `result.terminalState = "uncertain"`。

强制行为（语义冻结）：

1. uncertain result 是 **chain-halting failure**：当前 generation 的 tool loop 回填 function_call_output 后**必须终止**，不继续执行本 generation 内任何后续 mutation（send_to_terminal / write_file / run_command 全部停止），也不自动发起观察。
2. **不做 whole-payload retry**：已交付字节不可撤回，重试必然重复内容。
3. 后续 mutation 只能由用户显式重新发起（新 approval = 用户重新确认）；架构不自动继续。
4. uncertain 事件写入 card result 与日志（无 payload 内容）。

### R1.4 Byte Accounting（Result 字段冻结）

字段语义（取代旧 `bytesRequested` / `bytesDelivered`）：

| 字段 | 语义 |
|---|---|
| `payloadBytesRequested` | UTF-8(text) 字节数（模型 payload） |
| `payloadBytesAccepted` | 被 PTY/channel transport write API 接受的 payload 字节数（**[R2 修订]** 由 Delivered 改名 Accepted，语义见 R2.2） |
| `framingBytesRequested` | 0（未启用 DECSET 2004）或 **12**（计划 6B start + 6B end；**[R2 修订]** 原文 14/7B 有误，fork `40d473b1` 实测，R2.1） |
| `framingBytesAccepted` | transport write API 实际接受的 framing 字节数（**[R2 修订]** 由 Delivered 改名 Accepted） |
| `submitRequested` / `submitAccepted` | 是否计划 / 是否被 transport 实际接受 submit CR（1B；**[R2 修订]** 由 Delivered 改名 Accepted） |
| `bracketedFramingUsed` | 本 frame 是否采用 bracketed paste |
| `terminalState` | `confirmed \| uncertain` |

用户三个核心问题的直接映射：**AI payload 被 transport 接受** = payloadBytesAccepted/Requested（**[R2 修订]** 原文「进入 shell」为过度宣称，已按 R2.2 收窄）；**bracket frame 是否完成** = bracketedFramingUsed && framingBytesAccepted == framingBytesRequested；**是否按下 Enter** = submitAccepted。完整 result schema 见前文 Result 节（已更新）。

### R1.5 submit=false 的真实保证（选 Option B）

**冻结：`submit=false` 只承诺“不追加额外 CR”，不承诺 payload 不触发执行。**

理由：`text` 允许 LF（schema 冻结不变）+ 目标未启用 bracketed paste 时，部分 shell/程序会立即处理 LF。不做无法保证的“不执行”承诺。

- 拒绝 Option A（首版禁 LF）：多行粘贴是核心场景；禁 LF 会迫使模型以多次 `submit=true` 调用逐行拼接，增加执行次数与审批面，安全性反而更差。
- 采纳 Option B，强制 disclosure 两处：① tool description："submit=false only omits the trailing carriage return; it does not guarantee the text is not executed (newlines may be acted upon by programs without bracketed paste)"；② Approval Card 在 payload 含 LF 时显示该风险行。

### R1.6 Terminal Incarnation Binding（Remediation 2）

- `ManagedTerminalSession.id` **只能作为 logical session identity**（UI 寻址、历史归属、approval 卡片展示），**不得**作为唯一 side-effect endpoint identity。
- 新概念 **`TerminalInputTargetIdentity`**：
  - `sessionID`（logical）；
  - `inputTargetEpoch`：opaque 单调递增 epoch——endpoint 实例每替换一次 +1；
  - `endpointToken`：opaque endpoint handle（capability 内部持有**具体 endpoint 对象**的强引用；不暴露 raw unsafe pointer；description redacted）。
- **Local epoch**：绑定 PTY / `LocalProcess` incarnation。首次 shell 启动 = epoch A；shell restart / terminal runtime replacement = epoch B（新 PTY master fd，旧 fd 失效）。epoch 注册表由 10F-B2 terminal service 层维护。旧 approval `(sessionID X, epoch A)` 不能写入 `(sessionID X, epoch B)`。
- **Remote epoch**：绑定 SSHConnection incarnation + interactive shell channel incarnation 的**组合**，单一 `inputTargetEpoch` 代表两者。任一变化（手动 Reconnect / 断线后重连 / channel 重建）⇒ epoch 必变。
- **Freeze point**：构造 mutation request、注册 approval **之前** capture epoch；Approval Card 展示冻结 target（含 epoch 短码）。
- **Claim validation**：claim CAS（generation/session/providerSnapshot，10E 语义）时校验 `current epoch == approved epoch`；不等 → `targetReplaced`，零字节。
- **Redeem / 首字节 validation 与 check-then-use 的消除（结构性）**：approval capability 最终持有/解析到 capture 时冻结的**具体 endpoint 对象**（LocalProcess incarnation / SSHChannel 实例）；delivery 直接向该对象写。**不做“check 完再按 sessionID 重查”**。目标被 replace 后产生的是**另一个对象**，旧 capability 结构上不可能触达；对已死对象写入（fd 失效 / channel closed）→ `targetReplaced`，零字节。epoch 比较发生在 delivery admission、针对 capability 自己持有的对象，首字节 side effect 前无第二次按名寻址。
- **Reconnect / late approval**：即使 `ManagedTerminalSession.id` 相同，旧 approval 在 side effect 前 deterministic stale（epoch 比较）。**取代**前文“write 自然失败”保证。
- active-tab fallback：继续禁止（不变）。

### R1.7 File Publication Contract（Remediation 3）

**根问题**：用户批准 `write_file("/root/a.txt")` 批准的是什么？

**冻结：Option C — 10F 第一版 write_file 仅支持 CREATE，不支持覆盖 existing file。** 正式 contract：

> “在 pathname P **原子创建**内容恰好为 C 的新文件；前提条件：**发布时刻 P 不存在**。”（create pathname P with exactly content C, if and only if P does not exist at publication moment）

- approval 时 target 已存在（regular file / symlink / 任何类型）→ `targetExists` 拒绝，卡片明示“本版本不支持覆盖已有文件”。
- approval 与发布之间 P 出现 → 发布原语失败 `EEXIST` → `targetChanged`，P 零改动，tmp 清理。

**Darwin 原语调研**（architecture-only spike，读 SDK headers / 文档，不改代码）：

| 原语 | 结论 |
|---|---|
| `renameat` | 可用（10.10+），无 identity 条件 |
| `renameatx_np` / `renamex_np` | 可用（10.12+，SDK `sys/stdio.h` 实测），旗标 `RENAME_SECLUDE` / `RENAME_SWAP` / `RENAME_EXCL` / `RENAME_NOFOLLOW_ANY` / `RENAME_RESOLVE_BENEATH` |
| `RENAME_EXCL` | 原子 **no-replace** 发布（destination 存在即 EEXIST，含 symlink）——本架构发布原语 |
| `RENAME_SWAP` | 无条件交换两 pathname；**不能**作为 identity-conditional CAS（见下） |
| `openat` + `O_EXCL`/`O_NOFOLLOW`/`O_CLOEXEC`/`O_DIRECTORY` | 可用 |
| `fstatat` + `AT_SYMLINK_NOFOLLOW` | 可用 |
| `linkat` | 可用；no-replace 发布备选原语（`EEXIST` 失败） |

**问题：是否存在 “replace destination only if it is still inode X” 的真原子 CAS 原语？**

**答案：NO。** Darwin 没有任何原语以 destination inode identity 为 rename 条件。`RENAME_SWAP` 是无条件交换；“swap → fstat 交换出的旧文件 → 不符再 swap back” 是 **detect-and-rollback 补偿事务，不是 CAS**：回滚完成前观察者可短暂看到错误内容、回滚自身可失败、两个并发 mutator 可交错交换。明确**不以两步 check 模拟 atomic compare-and-swap**，也明确不宣称其为原子。

**撤回前文断言**：原 OVERWRITE 设计（`openat → fstat identity 复核 → temp + renameat`）**不关闭 TOCTOU**——fstat 校验的是已打开 fd 的身份，renameat 替换的是 pathname；两者之间攻击者可将 P rename 为新对象，我们的 renameat 会 clobber 该对象。前文「fstat 复核 + renameat 三层叠加已冻结」对该 pathname race 不构成保证，此点在此明确承认并撤回。

**CREATE 策略（v1 唯一路径）**：

1. parent 以 dir fd 打开（`O_DIRECTORY`）；
2. **[R2 修订]** parent 语义冻结为 **directory-inode capability semantic**（R2.14）：approved target =（`parentDirectoryIdentity` = approval 时 parent `(st_dev, st_ino)`、`basename`、`displayedPathSnapshot` 人类可读快照）。`fstatat(dirfd, ".", AT_SYMLINK_NOFOLLOW)` 与 `(st_dev, st_ino)` 的比对降级为**一致性断言**（capability 自持 fd，正常恒等；不等即程序性错误 → `targetChanged`）。parent 目录在 approval 后被 rename、同一 fd 仍存活 ⇒ **继续授权**在该原目录内创建。不采用 strict current pathname semantic；
3. **[R2 修订]** 临时文件创建撤回 path-based `mkstemp`（与 dirfd-relative 保证矛盾），冻结 **dirfd-relative + protected staging**（R2.13/R2.15）：`openat(parentFD, stagingName, O_CREAT|O_EXCL|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW, 0700)` 建 0700 staging 目录（stagingName 密码学随机，EEXIST 重生成，持 `stagingFD`）**[R3 修订] 此创建原语已撤回**——`openat(O_CREAT)` 只创建文件条目、`O_DIRECTORY` 不创建目录（本地 man 2 open 实证）；staging 创建/绑定冻结序列改为 `mkdirat → openat → fstat 验证`，见 R3.1–R3.3→ `openat(stagingFD, tmpName, O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC|O_NOFOLLOW, 0600)`（tmpName 随机，EEXIST 重生成）→ write 全量 → `fsync(file)`；
4. **[R2 修订]** `renameatx_np(stagingFD, tmpName, parentFD, P, RENAME_EXCL | RENAME_NOFOLLOW_ANY)` 原子 no-replace 发布（全部 fd-relative）→ `fsync(parentFD)` → best-effort `unlinkat(parentFD, stagingName, AT_REMOVEDIR)` 清理（孤儿 staging 可容忍）；
5. 失败清理：unlink tmp + rmdir staging + close fd。旗标不被卷支持（EOPNOTSUPP/EINVAL；`VOL_CAP_INT_RENAME_*` 为卷能力，APFS 支持）→ 备选 `linkat(stagingFD, tmpName, parentFD, P)`（同样 no-replace；source identity 与 cleanup 语义见 R2.15/R2.16）→ unlink tmp + rmdir staging。

**CREATE visibility guarantee**：观察者要么看不到 P，要么一次 rename 后看到**完整内容**——绝不出现半新半旧；进程崩溃于 rename 前只留孤儿 tmp（cleanup 移除），P 不存在；rename 后、dir fsync 前崩溃的 durability 边界如实披露（内容完整，目录项持久性依 fsync）。该 guarantee 建立在 `RENAME_EXCL` / `linkat` 两个已实证原语上，非模拟。

**残余 TOCTOU / 已知边界**（如实披露）：content publication 对 P 无残余竞态（no-replace 原语 + fd 钉定 + symlink 于发布点 EEXIST 拒绝）；hard-link 别名不可检测（OS 语义，维持前文已知边界）；崩溃 durability 边界如上。

**OVERWRITE：DEFERRED TO SPIKE**（10F-C3 槽位扩展为「Publication & Remote Write spike」）。研究内容：`RENAME_SWAP` 补偿回滚是否在“发布可能短暂误指向 + 回滚失败路径”强制披露可接受的前提下成立；future contract 候选 = Option A（path semantic + 显式 precondition），Option B（inode semantic）因无 CAS 原语不可实现、排除。未过 spike 独立验收前 write_file 不提供 OVERWRITE。这是显式 trade-off：**identity safety（冻结的 no-replace contract）优先于 pathname 覆盖能力**——比错误承诺 TOCTOU 已关闭更可接受。

### R1.8 Metadata Contract（Remediation 4）

v1 仅 CREATE；future OVERWRITE（若 spike 解除 defer）逐项冻结：

| 项 | CREATE（v1） | OVERWRITE（future，spike 后） |
|---|---|---|
| POSIX mode | `0o600 & ~umask`（新文件） | **PRESERVE**：`fchmod(temp, approval 时 st_mode)`；fchmod 失败 → abort，**绝不发布** |
| uid | app euid（**UNSUPPORTED**：不承诺保留） | RESET 为 euid（chown 不承诺）→ 披露 |
| gid | app egid（**UNSUPPORTED**） | RESET 为 egid → 披露 |
| ACL | 无（新文件） | **RESET**（不保留）→ 披露 |
| xattr（含 `com.apple.FinderInfo` / resource fork） | 无 | **RESET** → 披露 |
| timestamps | birthtime/mtime = 写入时刻（预期） | **RESET**（新 inode）；mtime 因内容写入自然更新（**预期**，属正常行为非异常） |

- **Executable file case**（0755 script）：v1 无 OVERWRITE ⇒ “普通内容编辑悄悄变 0600” 场景结构上不存在。future OVERWRITE：mode PRESERVE 为**强制**项；Approval Card 必须显示 existing mode 与 "permissions will be preserved"；任何无法 preserve 的路径 → 拒绝执行（`writeFailed`）而非静默降级。
- **Approval disclosure 规则**（future OVERWRITE 强制，不可省略）：卡片逐项列出将被 replace/reset 的 metadata classes：`Replacing this file may replace/reset: ACLs, extended attributes, Finder metadata/resource fork, timestamps; owner becomes your user account.`

### R1.9 Error Model Cleanup（Remediation，非新 P2）

- Provider JSON 的 `content`/`text` 经 JSON decode 进入 Swift 必为合法 `String`；decode 失败在 parsing 层（`AgentToolCallParsing`）即 `invalidArguments`。**tool-level 公开路径不存在 invalid UTF-8 raw bytes**。
- `encodingInvalid` 从 tool-level failure taxonomy **移除**；仅保留于 lower-level internal API（delivery/file 层 raw `Data` → `String` 边界）。
- NUL / 控制字符拒绝集不变（terminal payload）；file content 的 NUL 拒绝不变。

### R1.10 Revised Architecture Decision Table

| Decision | Frozen Result |
|---|---|
| Terminal logical identity | `ManagedTerminalSession.id`（UI/历史寻址与卡片展示） |
| Terminal incarnation identity | `TerminalInputTargetIdentity` = sessionID + `inputTargetEpoch`（opaque 单调）+ `endpointToken`（opaque handle，持具体 endpoint 对象强引用） |
| Bracketed framing | delivery admission 读 DECSET 2004 **一次**；enabled ⇒ `[ESC[200~] + payload + [ESC[201~]`（**6B×2** 常量，framing 合计 **12B**；**[R2 修订]** 原文 7B×2 有误）；disabled ⇒ 直写 payload |
| Payload byte accounting | `payloadBytesRequested` / `payloadBytesDelivered`（UTF-8(text)，≤ 64 KiB） |
| Wire byte accounting | `framingBytesRequested/Accepted`（0 或 **12**）+ `submitRequested/submitAccepted`（CR 1B）+ `bracketedFramingUsed`；无笼统 `bytes*` 字段（**[R2 修订]** 改名 Accepted，语义 R2.2） |
| Partial frame recovery | **[R2 修订]** start 失败按 accepted 前缀细分（0 = clean confirmed；1…5 = uncertain + chain halt；6 = continue；禁止自动补 end，R2.4）；payload/end 失败 = best-effort 单次 end marker；闭合不可确认 ⇒ `terminalInputStateUncertain` ⇒ 当前 generation 链停，不做 whole-payload retry |
| submit=false guarantee | 只承诺不追加 CR；**不承诺“不执行”**；LF + 无 bracketed paste 风险在 tool description 与 Approval Card 强制披露 |
| File CREATE publication | **[R2 修订]** frozen parentFD 内 protected staging（0700，openat O_EXCL）→ openat(O_EXCL) temp → fsync(file) → `renameatx_np(stagingFD,tmp,parentFD,P,RENAME_EXCL|RENAME_NOFOLLOW_ANY)`（备选 linkat）→ fsync(parentFD)（详见 R2.13–R2.17） |
| File OVERWRITE semantic | v1 不支持（`targetExists` 拒绝）；future contract **DEFERRED TO 10F-C3 spike**（候选 Option A + RENAME_SWAP 回滚 + 强制披露，须过独立验收） |
| File overwrite TOCTOU guarantee | v1 无 OVERWRITE ⇒ 无 pathname 覆盖竞态；“fstat+renameat 关闭 TOCTOU” 断言**已撤回**；无 inode-conditional CAS 原语（**明确 NO**，不以两步 check 模拟） |
| POSIX mode | CREATE：`0o600 & ~umask`；future OVERWRITE：PRESERVE（强制，fchmod 失败即 abort） |
| uid/gid | 不承诺保留；future OVERWRITE RESET 为 euid/egid，强制披露 |
| ACL | CREATE：无；future OVERWRITE：RESET，强制披露 |
| xattr | 同 ACL（含 FinderInfo / resource fork），强制披露 |
| Remote write | **DEFERRED**（不变）；10F-C3 = Publication & Remote Write spike |

### R1.11 Revised Testing Strategy（设计追加，仍不在本阶段实现）

**Terminal（在原 deterministic 集合上追加）**：

1. bracket start delivered / payload zero（payload 层注入故障 → partialDelivery + best-effort end 断言）
2. payload partial（中途断开）→ framing/bytes accounting 断言
3. payload full / end missing → `terminalState=uncertain` + generation 终止断言
4. end delivered / submit missing → `submitted=false` + confirmed
5. cancel after bracket start（Stop 注入逐阶段 ×5）
6. framing-close failure（end marker 写失败注入）→ uncertain + 后续 mutation 全停
7. DECSET 2004 off → `framingBytesRequested=0` 且 wire 无 ESC 字节断言
8. incarnation changes before approval → claim 拒绝 `targetReplaced`
9. incarnation changes after approval / after claim before first byte → `targetReplaced` 零字节
10. remote reconnect same logical sessionID → 旧 approval deterministic stale（epoch 断言）
11. Local shell restart（epoch A capability 写入 epoch B）→ `targetReplaced`
12. endpointToken 无 raw pointer 泄漏 / redacted description 断言
13. submit CR 失败不重试（双执行防护断言）

**File（追加）**：

1. target replaced after approval（P 出现新文件）→ RENAME_EXCL `EEXIST` → `targetChanged`，tmp 清理
2. target replaced after identity check（发布竞态注入）→ no-replace 原语兜底，P 不被 clobber
3. target replaced immediately before publication（最窄时序窗口）
4. CREATE competitor creates same pathname → `EEXIST` → `targetChanged`
5. CREATE crash during temp write → 孤儿 tmp、P 不存在
6. publication 原子可见性（读者轮询 P：不存在或完整内容，绝不半新半旧）
7. RENAME_EXCL 不支持卷路径 → linkat fallback 等价断言
8. `targetExists`（v1 覆盖请求拒绝）
9. parent (dev,ino) 不符（dir 被换）→ `targetChanged`（fstatat on held fd）
10. executable mode preservation/disclosure、ACL/xattr 语义（future OVERWRITE，spike 后）

### R1.12 对既有冻结决定的修订清单（§24 义务）

| 原决定 | R1 处置 |
|---|---|
| #3 terminal target binding（sessionID 寻址） | 升级为 `TerminalInputTargetIdentity`（R1.6）；active-tab 禁止不变 |
| #5 result model（bytesRequested/Delivered） | 被 R1.4 六字段 accounting 取代 |
| #6 partial-delivery semantics | terminal 部分由 R1.2/R1.3 精化（frame 状态机 + uncertain 链停）；file 部分由 R1.7 重建 |
| #10 TOCTOU strategy | 撤回 OVERWRITE 路径（fstat+renameat 不关闭 pathname 竞态）；v1 CREATE-only（R1.7） |
| #11 atomic local write strategy | CREATE 改原子发布；OVERWRITE DEFERRED（R1.7/R1.8） |
| #13 encodingInvalid | 移出 tool-level taxonomy（R1.9） |
| #14 file approval UI | v1 卡片仅 CREATE；OVERWRITE 风险文案随 defer 移除（R1.8 保留 future disclosure 规则） |
| 其余（schema `{text,submit}`、64 KiB / 256 KiB 上限、per-call approval、no Always Allow、no active-tab fallback、no TerminalCommandDispatcher 复用、no 终端输出捕获、get_terminal_context 观察、write_file 概念、UTF-8 only、binary/base64 排除、Remote write deferred、10F staged sequence） | **全部保留不变**（R1 未迫使变化） |

---

## Phase 10F-A-R2 — Delivery Endpoint + Publication Contract Closure

Independent Acceptance 判 R1 BLOCKED（P1:0 / P2:4）。本章节按 R2 任务书完成 remediation；零 production/test 代码修改、零 commit/push，仅更新本文件（untracked, not staged）。前文与之冲突处以本章节为准。

R2 preflight 实测：branch `main`；HEAD `e958750643aeb9992d4cb357e91dc084130224eb`；staged 0；production/test tracked diff 0；仅 untracked Docs（既有 14 个验收 Docs 未触碰）。

### R2.1 Bracketed Paste Constants（真实 SwiftTerm 常量闭环）

实证：fork 工作区 `ThirdParty/SwiftTerm-fork`，`git rev-parse HEAD` = **`40d473b1fdb456d49cc04b7f253277fcb9ac3987`**；`Sources/SwiftTerm/EscapeSequences.swift:132/136/78` 实测：

| 常量 | 字节序列 | 长度 |
|---|---|---|
| `EscapeSequences.bracketedPasteStart` | `[0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]`（ESC [ 2 0 0 ~） | **6** |
| `EscapeSequences.bracketedPasteEnd` | `[0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]`（ESC [ 2 0 1 ~） | **6** |
| `EscapeSequences.cmdRet`（submit CR） | `[0x0d]` | **1** |

**[R2 修订]** R1 时期全部 7B/14 表述**作废**。冻结：

- start marker：6 字节；end marker：6 字节；bracketed framing 合计 **12 字节**；CR：1 字节。
- `bracketedPaste == true`：`wire = start[6] + UTF8(payload) + end[6] + optional CR[1]`；`framingBytesRequested = 12`。
- `bracketedPaste == false`：`wire = UTF8(payload) + optional CR[1]`；`framingBytesRequested = 0`。
- **常量唯一来源规则**：实现规划与代码不得重复字面数值（6/12/1 只从 canonical 常量推导一次）；生产代码引用 SwiftTerm canonical 常量，或使用一个带「与 SwiftTerm 常量等价」单元测试的 verified shared definition。注意两常量在 SwiftTerm 中声明为 `public static var`（可变静态）：MacSSH 承诺绝不写它们；单元测试钉死 canonical 字节序列，SwiftTerm 侧任何漂移即测试失败。

### R2.2 Byte Semantics：「Accepted」术语冻结（取代 Delivered）

一个成功的 POSIX / PTY / libssh2 write 只能证明相关 transport write API **接受了一个前缀**；不能证明 shell 进程已消费、执行或渲染。冻结：

- 字段更名：`payloadBytesDelivered → payloadBytesAccepted`；`framingBytesDelivered → framingBytesAccepted`；`submitDelivered → submitAccepted`。
- **Accepted 唯一定义**：被已批准的 PTY / SSH shell-channel transport write API 成功接受（API 返回的字节数）。
- **Accepted 不代表**：confirmed consumed by shell process；confirmed executed；confirmed rendered。
- result `status = "delivered"` 同步收窄定义：= 全部请求字节被 transport 接受。**Approval / result UI 不得把 transport acknowledgement 表述为「已执行 / 已进入 shell」**（10F-B4 卡片文案实现约束）。

### R2.3 TerminalMutationByteWriter（acknowledged writer contract，冻结）

现有 SwiftTerm `LocalProcess.send(data:)` 走 DispatchIO、不向调用方返回写入字节数，**不满足**本 contract——从 R1 的 P3 升级为 P2 级架构要求并在此冻结（不得降级 P3）。

冻结抽象（语义 contract；Phase A 不冻结 Swift 签名）：

```
TerminalMutationByteWriter
  write(bytes) → 精确 accepted prefix count + 显式 completion / failure
```

硬性要求：

1. 不存在以 fire-and-forget API 作为 authority 的路径；
2. 无隐藏的异步 delegate retargeting（writer 绝不在 frame 中途换目标）；
3. 每个返回的 accepted count 精确；
4. short write 可观察；
5. cancellation 可观察（含正前缀后取消）；
6. 正前缀后 transport error 保留该前缀计数；
7. accepted == 0 与 positive partial acceptance 可区分；
8. 单个 mutation frame 的写入在 writer 内串行（frame 字节不与其它写交错）。

实现落位：Local 由 10F-B2（acknowledged PTY writer 入口，fork/API 增量可能需要）交付；Remote 由 10F-B3（accepted-count 变体绑定 captured incarnation）交付。本阶段只冻结需求，不实现。

### R2.4 Start Marker Partial Semantics（撤回 R1「零字节干净失败」一刀切）

对 6 字节 `bracketedPasteStart` 的逐前缀语义：

| accepted | 语义 | 处置 |
|---|---|---|
| **0** | 无 framing 字节进入 transport；terminal input state 保持 **confirmed** | 干净 write failure（`writeFailed`）；**不自动重试**整个 mutation |
| **1…5** | partial escape/control sequence 已进入 transport；**terminal input state uncertain** | `terminalInputStateUncertain`；**chain halt**；不做 whole-payload retry；不假设 end marker 可修复状态 |
| **6** | frameStarted | 继续 payload 阶段 |

**禁止**在 partial START 后自动发送 `bracketedPasteEnd`：部分开启 marker 不是合法 bracketed-paste 开启序列，盲目追加 end marker 会向未知 parser 状态注入额外控制序列。保守失败规则冻结。

### R2.5 Remaining Frame：Payload Partial / End / CR

COMPLETE start 被接受（accepted = 6）之后：

- **payload partial**：保留精确 payload 前缀计数；best-effort 尝试**一次** close marker；payload 绝不重试。
- **end marker**：accepted 0…5 → `terminalInputStateUncertain`、chain halt；accepted 6 → framing complete。
- **close marker 自身 partial**：terminalState = **uncertain**。无第二次任意重试循环；无 whole-frame retry。
- **submit CR（1 字节）**：冻结 `submitRequested: Bool` / `submitAccepted: Bool`。accepted = 0 → not submitted，不自动重试；accepted = 1 → submitted at transport level。API 已 ack 字节之后再报 error **绝不再发第二个 CR**。`submitAccepted == true` ≠ command completed——仅表示 CR 被 exact terminal transport 接受。

### R2.6 Exact Remote Endpoint Problem（生产代码实测证据）

`MacSSH/Services/Terminal/RemoteTerminalService.swift` 实测：

- `private var connection: SSHConnection`（:34）——**可变属性**；
- `reattach(connection:)`（:252）在 Reconnect 时替换 `connection`，同时**复用同一 `TerminalView`**（保留终端历史）；
- `TerminalViewDelegate.send`（:431）`nonisolated func send` → **`Task { @MainActor … self.connection.writeChannelInput(data) }`（:432–437）**——Task 在**执行时**读取 `self.connection`，不是捕获时绑定。

因此：**`TerminalView` 与 `RemoteTerminalService` 不是 immutable incarnation endpoint**。冻结禁令：10F mutation 链禁止使用

```
TerminalView.pasteText() → 普通 shared TerminalViewDelegate.send() → 可变 RemoteTerminalService.connection
```

作为 security-authoritative Agent mutation path，除非未来变更证明 exact per-call binding。

### R2.7 TerminalMutationEndpoint（冻结概念）

专用概念（= R1.6 `TerminalInputTargetIdentity` 升级为能力对象）：

- 属性：`logicalSessionID` / `inputTargetEpoch` / `endpointToken`；
- 语义：endpoint 代表**一个具体 terminal incarnation**；
- Local 绑定：一个 PTY/process incarnation；
- Remote 绑定：一个 exact SSHConnection incarnation + 一个 exact interactive shell channel incarnation；
- approval 之后**绝不**动态重解析：`SessionManager.activeSession`、`ManagedTerminalSession.remoteService.connection`、current TerminalView delegate target。

### R2.8 Remote Endpoint Writer（冻结架构：generation-bound writer capability）

冻结首选形态（语义示例，实现类型可异）：

```
RemoteTerminalMutationEndpoint {
    sessionID
    epoch
    capturedConnection              // 构造时捕获的 SSHConnection 实例
    capturedShellChannelGeneration  // 精确 interactive shell channel incarnation
}
```

不变量：start / payload / end / CR 全部字节写入**同一 captured remote shell incarnation**；Reconnect 绝不让 in-flight mutation frame retarget。

### R2.9 Remote Reconnect vs Mutation Delivery（生命周期定序）

冻结确定性规则：

1. mutation endpoint 获得 incarnation delivery lease；
2. reconnect 使**未来**的 acquisition 失效；
3. reconnect 等待当前 frame finish / cancel，**或**使 writer 对 OLD endpoint 失败；
4. reconnect 绝不让剩余字节迁移到 NEW endpoint。

硬不变量：**一个 mutation frame 至多影响一个 terminal incarnation**。绝不出现 start@A / payload@A / end·CR@B。

### R2.10 Local Endpoint Writer

`LocalProcess.send` 不足以做精确记账（R2.3）。冻结：Local mutation 最终使用 acknowledged PTY writer（exact accepted prefix / short-write handling / error-after-prefix / cancellation），并绑定**一个 Local process/PTY incarnation**。approval 后**不**重解析新 childfd；不允许 fd number 复用把旧 approval 重定向到新进程。实现必须持有正确的 lifetime/identity token，而不是裸 `Int32` fd number。

### R2.11 SwiftTerm Paste Semantics（framing 来源：冻结 Direction B）

冻结 **Direction B**：MacSSH mutation framing 层——

1. delivery admission 读取 SwiftTerm `Terminal.bracketedPasteMode` 一次（`public private(set) var`，`Terminal.swift:478`，安全读）；
2. 使用 canonical `EscapeSequences.bracketedPasteStart/End` 常量（R2.1 唯一来源规则）；
3. 生成精确 frame；
4. 经 `TerminalMutationEndpoint`（R2.7/R2.8/R2.10）写入。

不选 Direction A（SwiftTerm「编码不投递」窄 API）：其收益只是把 12 字节拼接移进 fork，仍需 fork API 变更，且 Direction B 无重复常量问题；若 10F-B2 实现中发现 Direction A 必要，须回到架构验收。

**IME / marked text**：mutation writer 直接向 transport 写原始字节，完全绕开 `NSTextInputClient` / marked-text 路径——IME 行为不参与、也不被干扰。**不宣称**与 `pasteText(_:)` 的完整行为 parity（`MacTerminalView.pasteText`（:2543）走 `insertText(isPaste:true)` → 三次独立 `send` delegate 回调（:1679–1684 / :1723–1729）），除非被证明；framing 字节等价性由单元测试钉死。

### R2.12 DECSET 2004 Snapshot（维持 R1 政策）

`modeSnapshot = on | off`，delivery admission 读取**一次**，单个 mutation 期间不重读。admission 后 host 模式变化是**残余协议竞态**：它不能 retarget endpoint（字节已绑定 captured incarnation），如实披露。

### R2.13 File CREATE：Temp Creation dirfd-relative（撤回 mkstemp）

**[R3 修订]** 本节所述 staging 目录的**创建原语**已由 R3.1 的 `mkdirat → openat → fstat` 序列取代（`openat(O_CREAT|O_DIRECTORY)` 不能创建目录）；temp 文件本身的 `openat(O_CREAT|O_EXCL|…)` 语义不变，落点改为已验证的 `stagingFD`（R3.4）。

R1 的 `mkstemp` 是 path-based，与「全部 dirfd-relative」矛盾——撤回。冻结 v1：

1. `parentFD` 已 frozen / verified（R1.7 step 1 不变）；
2. 生成密码学随机 temp basename；
3. `openat(parentFD, tmpBasename, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600)`；EEXIST → 重生成 basename 再试；
4. temp 创建严格相对 approved parent directory fd。

结合 R2.15：temp 实际创建于 protected staging 目录内（staging 本身创建于 parentFD 之下）；两层全部 openat / O_EXCL。

### R2.14 CREATE Parent Semantic（冻结：directory-inode capability semantic）

**二选一冻结：capability semantic**（不采用 strict current pathname semantic）：

- approved target =（`parentDirectoryIdentity` = frozen parent 的 `(dev, ino)`，`basename`，`displayedPathSnapshot` 人类可读快照）；
- parent 在 approval 后被 rename、同一 directory fd 仍存活 ⇒ **授权**在该原目录内创建（fd 钉住目录对象）；
- 绝不同时宣称 strict pathname 语义与 frozen inode capability 语义。若未来需要 strict pathname 语义，须先证明 ancestor rename race 处理方式（另立架构验收）。

### R2.15 Temporary Source Integrity（威胁模型冻结）

**对手问题**：拥有 parent 目录写权限的另一进程，能否在 temp write/fsync 与 publication 之间 `unlink` / `replace` / `rename` tmpName？——直接在 parent 内放 tmp 时**能**：unlink 后换成同名普通文件，rename 发布的是替代者内容，违背「published content is exactly C」。macOS 无 fd-based publication 原语（无 `linkat(AT_EMPTY_PATH)` 等价物；rename 只接受 pathname）→ Option B 不可得。

冻结 **Option A：protected staging directory fd**：

1. `openat(parentFD, stagingName, O_CREAT | O_EXCL | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW, 0700)`（stagingName 密码学随机；EEXIST 重生成）；持 `stagingFD`；**[R3 修订] 创建原语已撤回**——替换为 R3.1 `mkdirat → openat → fstat 验证` 序列，stagingFD 的 identity/security 校验规则见 R3.2
2. temp 文件创建于 staging 内（R2.13 openat / O_EXCL / 0600）；write / fsync 全部相对 `stagingFD`；
3. publication：`renameatx_np(stagingFD, tmpName, parentFD, P, RENAME_EXCL | RENAME_NOFOLLOW_ANY)` → `fsync(parentFD)`；
4. 清理：best-effort `unlinkat(parentFD, stagingName, AT_REMOVEDIR)`；孤儿 staging 可容忍（cleanup 移除）。

**安全论证（对手 = 持 parent 写权限的其它 uid 进程）**：对手无法在 staging 内 create/unlink/rename tmp（0700 非 owner 无 w 位）；`rmdir(staging)` 失败（temp 存在 ⇒ 非空）；对手 rename staging 目录本身不影响——全部操作 fd-relative（stagingFD 钉住 inode），publication 仍从原 inode 读；parent 侧 P 竞态由 RENAME_EXCL 兜底（R2.16）。

**明确 scoping（不夸大）**：root、同 uid 进程、已攻破本进程的对手**超出**本保证；对这类对手**不宣称** absolute exact-content publication。卷能力差异见 R1.7 step 5 fallback 与 P3 记录。

### R2.16 RENAME_EXCL（保留 + 语义区分）

保留 `RENAME_EXCL` 为 destination no-clobber 机制（卷支持时）。语义区分冻结：

- RENAME_EXCL **证明**：原子发布点 destination 不存在；
- RENAME_EXCL **不证明**：source pathname 仍指涉最初创建的 temp inode（该保证由 R2.15 staging + fd-relative 承担）。

`linkat` fallback 仅在其 source identity 与 cleanup 语义同样文档化时保留（source 也走 `(stagingFD, tmpName)`，与 RENAME_EXCL 同一 fd-relative 前提；失败清理链一致）。

### R2.17 Crash Semantics（分点冻结；区分 atomic visibility 与 crash durability）

**[R3 修订]** 本表「dir fsync 后 → durable」行被 **R3.12 修订 crash matrix 取代**：macOS `fsync()` 不承诺 power-loss / device-cache persistence（本地 man 2 fsync 实证：drive 可能长期不物理落盘且可能乱序；`F_FULLFSYNC` 才提供更强保证）。v1 durability scope 冻结为政策 A（R3.11），全文禁止无 failure model 定义的 "durable"。

| 崩溃点 | target 可见？ | target 完整？ | temp/staging 孤儿？ | durability |
|---|---|---|---|---|
| temp fsync 前 | 否 | — | 可能（staging + tmp） | 无 |
| temp fsync 后 | 否 | —（不可见） | 可能 | temp **内容** durable；目录项不 durable |
| publication 后、dir fsync 前 | 是 | 是（RENAME_EXCL 原子可见） | 否 | **不保证**：崩溃可致目录项回退（P 消失） |
| dir fsync 后 | 是 | 是 | 否 | durable |

atomic visibility（观察者只见 P 不存在或完整内容）与 crash durability（崩溃后仍存在）是两个保证，绝不混同；fsync 边界如实披露。

### R2.18 既有冻结决定（保留清单确认）

逐项确认不变：`send_to_terminal` schema `{text, submit}`；payload 64 KiB；write_file v1 CREATE-only；content 256 KiB；UTF-8 text only；per-call approval；no Always Allow；no active-tab fallback；no TerminalCommandDispatcher 复用；no 终端输出捕获；观察走 get_terminal_context；Remote write deferred；OVERWRITE deferred；R1 metadata contract；`encodingInvalid` 已移出 tool-level taxonomy。R2 仅在 framing 常量、Accepted 术语、partial-start、endpoint/writer、CREATE temp/parent/来源完整性处收紧，其余不动。

### R2.19 Planned Test Architecture（追加矩阵，仍不在本阶段实现）

**Terminal constants**：start count == 6；end count == 6；total framing == 12；CR == 1（含与 SwiftTerm canonical 常量等价断言）。

**Exact writer**：accepted 0；accepted 1…5 of start；accepted full start；partial payload；partial end 1…5；CR 0；CR 1；error after positive prefix；cancellation after positive prefix。

**Remote incarnation**：send schedules before reconnect / executes after reconnect；start before reconnect / payload after reconnect；end before reconnect / CR after reconnect；same TerminalView reused；same ManagedTerminalSession.id reused；all old approval bytes stay on old endpoint or fail；zero bytes reach new connection。

**Local incarnation**：exact PTY writer count；old endpoint after shell replacement；fd-number reuse simulation；cancellation during short write。

**File**：temp creation remains relative to frozen parentFD；parent pathname replaced before temp creation；parent renamed after approval；tmp source removed before publication；tmp source replaced before publication；competing target CREATE；unsupported RENAME_EXCL volume fallback；crash before/after fsync boundaries。

### R2.20 Revised Architecture Decision Table（R2 增量）

| Decision | Frozen Result |
|---|---|
| Framing bytes | start 6 / end 6 / total 12 / CR 1（fork `40d473b1` 实证；唯一来源规则 R2.1） |
| Byte 术语 | Accepted（transport 接受前缀）；非 executed / consumed / rendered（R2.2） |
| Writer | `TerminalMutationByteWriter`：exact prefix + explicit completion（R2.3）；`LocalProcess.send` 不合格（P2 级，不降 P3） |
| Start partial | 0 = clean；1…5 = uncertain + chain halt；6 = continue；禁止自动补 end（R2.4） |
| Endpoint | `TerminalMutationEndpoint`（sessionID + epoch + token），禁动态重解析（R2.7） |
| Remote writer | generation-bound capability：captured connection + shell channel（R2.8）；reconnect lease 定序（R2.9） |
| Local writer | acknowledged PTY writer + identity token，非裸 fd（R2.10） |
| Framing 来源 | Direction B（R2.11）；无 pasteText parity 宣称；IME 路径旁路说明 |
| CREATE temp | openat O_EXCL dirfd-relative + protected staging（撤回 mkstemp；R2.13/R2.15）；**[R3 修订]** staging 创建 = `mkdirat → openat(O_DIRECTORY) → fstat 验证`（R3.1–R3.3），durability scope = 政策 A（R3.11） |
| CREATE parent 语义 | directory-inode capability（R2.14） |
| 来源完整性 | Option A staging 威胁模型；同 uid / root 超范围（R2.15） |
| RENAME_EXCL | 保留；destination-nonexistence 与 source-identity 语义区分（R2.16） |

---

## Phase 10F-A-R3 — Staging Creation + Durability Contract Closure

Independent Acceptance 判 R2 BLOCKED（P1:0 / P2:2）。本章节按 R3 任务书完成 2 项 architecture remediation（staging creation primitive 无效 + fsync durability 过度宣称）；零 production/test 代码修改、零 commit/push，仅更新本文件（untracked, not staged）。前文与之冲突处以本章节为准。

R3 preflight 实测：branch `main`；HEAD `e958750643aeb9992d4cb357e91dc084130224eb`；staged 0；production/test tracked diff 0；仅 untracked Docs。

本地取证（architecture-only，未改代码）：

- **man 2 open**：`O_DIRECTORY` — "restrict open to a directory"；"If O_DIRECTORY is used in the mask and the target file passed to open() is not a directory then the open() will fail."（`ENOTDIR`）。`O_CREAT` 语义为创建**文件条目**，不含目录创建。→ R2 冻结的 `openat(parentFD, stagingName, O_CREAT|O_EXCL|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW, 0700)` 实际创建 0700 **普通文件**，随后同一 `O_DIRECTORY` 打开必然 `ENOTDIR` 失败——**原语无效，撤回**。
- **man 2 mkdir**：`mkdir/mkdirat — make a directory file`；owner = 进程 effective UID；group = parent 目录的 gid；mode 受调用进程 umask 收敛。
- **man 2 fsync**：明示 "the drive itself may not physically write the data to the platters for quite some time and it may be written in an out-of-order sequence"；"if the drive loses power or the OS crashes, the application may find that only some or none of their data was written"。macOS 提供更强机制 `F_FULLFSYNC`（man 2 fcntl：请求 drive flush 全部缓冲；HFS/FAT/UDF/APFS 实现；某些 FireWire drive 已知忽略 flush 请求）。→ R2.17「dir fsync 后 → durable」为过度宣称，撤回。

### R3.1 Staging Creation Primitive 撤回与冻结创建序列（R2 Finding 1）

**撤回**：`openat(parentFD, stagingName, O_CREAT | O_EXCL | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW, 0700)` 作为 staging 目录创建原语（理由见上文取证；R2.13/R2.15/R1.7 step 3 处已加 `[R3 修订]` 标注）。

**冻结创建/绑定序列**（POSIX 语义冻结；Swift wrapper 名称 Phase A 不冻结）：

1. 生成**高熵 staging basename**（密码学随机；单一 basename；无 `/`；非 `.` / `..`）；EEXIST 冲突 → 重新生成重试；
2. `mkdirat(parentFD, stagingName, 0700)` —— 真正的目录创建原语（mode 经 umask 收敛，见 R3.2）；
3. 打开新建 staging 目录：`openat(parentFD, stagingName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)`；
4. `fstat(stagingFD)`；
5. 按冻结的 staging identity/security 政策验证打开的目录（R3.2）；
6. `stagingFD` 验证通过后，**全部**临时文件操作（create / write / fsync / publish / unlink）一律经 `stagingFD`，绝不使用 parent pathname 下的 staging 路径。

### R3.2 mkdirat→openat Race 与 opened-FD Validation（冻结）

**明确不假装两步是原子 create-and-open**。命名空间窗口客观存在：

```
mkdirat(parentFD, stagingName, 0700)
   ↓  [另一个 parent-directory writer 可能在此窗口内作用于 stagingName]
openat(parentFD, stagingName, O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
```

当前威胁模型排除：root、同 uid 敌意进程、已攻破的 MacSSH 进程；**不自动排除**每一个能变更 parent 目录的不同 uid 进程。该窗口由 opened-FD validation 在此威胁模型内关闭：

**冻结验证规则**（对 `openat` 返回的 `stagingFD` 执行 `fstat` 后逐项判定）：

| 项 | 判定 |
|---|---|
| file type | 必须为 directory（`S_IFDIR`） |
| `st_uid` | 必须 == effective uid（owner == euid） |
| `st_gid` | 记录入 capability；**不作**安全判据（mkdirat 语义中 gid 继承自 parent，不用于授权判定） |
| `st_mode` 权限位 | **0700-or-stricter**：group 位与 other 位必须全为 0（owner 位可被 umask 进一步收敛为更严） |
| `st_dev` / `st_ino` | 记录入 capability（R3.3），用于后续一致性断言 |

**明确宣称**：本架构对 staging 的安全性依赖以下三者**联合**：`owner == euid` + `0700-or-stricter permissions` + `O_NOFOLLOW`。

**窗口内替换的处置（不静默接受）**：若不同 uid 的 parent writer 在 mkdirat 与 openat 之间替换了 `stagingName`：

- 替换为 symlink → `openat` 的 `O_NOFOLLOW` 使 open 失败（`ELOOP`）；
- 替换为其它 uid 拥有的目录/文件 → `st_uid` 校验失败；
- 替换为权限宽松（group/other 位非 0）的目录 → mode 校验失败；
- 替换为普通文件等非目录 → `O_DIRECTORY` 使 open 失败（`ENOTDIR`）。

任何 **open 失败**或 **identity/ownership 校验失败** → **abort** → **零 target publication**，清理 best-effort，绝不静默接受替换对象。

论证基础：不同 uid 进程无法创建 owner 为 euid 的目录条目（chown 受限，且 mkdirat owner 恒为创建者 euid）；因此「替换物必非 euid-owned 0700 目录」在威胁模型内成立。**残余边界如实披露**：root 与同 uid 对手可创建满足全部判据的对象或直接作用于 staging 内部——对这类对手**不设防**（与 R2.15 scoping 一致）。

### R3.3 Frozen Staging Identity（`StagingDirectoryCapability`）

冻结 staging identity contract（概念冻结；生产类型名可异）：

```
StagingDirectoryCapability {
    parentDirectoryIdentity   // approved parent 的 (st_dev, st_ino)（R2.14 语义）
    stagingFD                 // 已通过 R3.2 验证的 staging 目录 fd
    stagingDev                // staging 的 st_dev
    stagingIno                // staging 的 st_ino
    ownerUID                  // staging 的 st_uid（== euid）
}
```

**必需不变量**：`stagingFD` 验证通过后，source temp 的创建/发布一律经该 capability 持有的 `stagingFD`，**绝不**将 `stagingName` 重新解析为 source authority。人类可读的 staging pathname 仅作诊断用途（本地日志；不含内容），不参与任何安全判定。

### R3.4 Temp File Creation 与 Source Temp Identity（冻结）

temp 创建（R2.13 的 openat 语义不变，落点明确为已验证 stagingFD）：

```
openat(stagingFD, tmpName, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600)
```

- `EEXIST` → 生成新的随机 `tmpName` 重试；
- `tmpName` 约束：单一 basename；无 `/`；非 `.` / `..`；高熵随机；
- 全部写入经该调用返回的 **temp file descriptor**；**无 path-based mkstemp**。

**Source identity 冻结**：temp 创建后立即 `fstat(tempFD)`，至少记录 `st_dev`、`st_ino`、regular-file 类型（`S_IFREG`），纳入 capability 记录。

**「tmpName inside stagingFD 在发布时刻仍指涉预期 source 对象」的证明构成**（精确表述，不夸大）：

1. temp fd 与发布原语（`renameatx_np(stagingFD, tmpName, …)`，R3.6）都相对**同一个已验证 `stagingFD`**；发布路径不含任何 parent 侧按名重解析；
2. staging 目录已验证 `owner == euid` 且 `0700-or-stricter`（R3.2）；威胁模型内**无**其它 uid 进程能在 staging 内 create / unlink / rename `tmpName`；
3. `stagingFD` 钉住目录 inode，外部 rename staging 目录本身不影响 fd-relative 操作（R3.8）。

**明确 scoping**：该保证依赖冻结威胁模型（已验证 0700 staging 目录 + 同 uid / root / 已攻破本进程的对手出范围）。对排除的对手类别不宣称保护。

### R3.5 Parent Rename Semantics（维持 R2.14，确认）

维持 R2 的 **directory-inode capability semantic**：

- approved target =（`parentDirectoryIdentity`, `basename`, `displayedPathSnapshot`）；
- approved parent 在 approval 后被 rename：live frozen `parentFD` 仍是 authority——fd 钉住目录 inode，**create 可继续在同一目录 inode 内进行**；
- **不得**称此为 strict-current-pathname 语义；
- Approval UI 使用 displayed path 作为 **snapshot**，不作为安全 identity。

### R3.6 Destination Publication（维持 R2.16 + 语义区分确认）

v1 语义不变：**write_file = CREATE ONLY**。Approved operation = 在 frozen parent directory 内创建 basename `P`，**仅当发布时刻 `P` 不存在**。

首选发布原语（卷支持时）：

```
renameatx_np(stagingFD, tmpName, parentFD, targetBasename, RENAME_EXCL | RENAME_NOFOLLOW_ANY)
```

语义区分（冻结）：

- `RENAME_EXCL` ⇒ **destination 必须在原子发布点不存在**（已存在即 `EEXIST`，no clobber，含 symlink）；
- `RENAME_NOFOLLOW_ANY` ⇒ 解析过程中遇到 symlink 即拒绝（拒绝 symlink traversal）；
- **不得把 source-identity 保证归因于 `RENAME_EXCL`**：source integrity 由 R3.3/R3.4 的 staging capability 承担；destination no-clobber 与 source integrity 是**两个独立 contract**。

### R3.7 linkat Fallback（冻结补充语义）

fallback 原语保留，但**仅当**以下全部冻结：

```
linkat(stagingFD, tmpName, parentFD, targetBasename, 0)
```

- destination 已存在 → `EEXIST` / **no clobber**；
- target publication = **一次原子 hard-link 创建**；
- source temp 在 link 之前**已完全写入并已通过 R3.9 的 file sync gate**；
- cleanup：成功发布后 `unlinkat(stagingFD, tmpName, 0)` 移除 source temp。

**文档化声明**：linkat 发布在 source cleanup 完成前，同一 inode 短暂存在两个名字（`tmpName` 与 `P`）。此为已声明、可接受的瞬态（staging 0700 使窗口内不可被威胁模型内对手触达）。

### R3.8 Cleanup Contract（冻结）

best-effort cleanup 覆盖对象：temp file（`unlinkat(stagingFD, tmpName, 0)`）与 staging directory（`unlinkat(parentFD, stagingName, AT_REMOVEDIR)`，或经 capability 内等价引用）。

| 场景 | 清理行为 |
|---|---|
| normal success（renameatx_np 路径） | temp 已随 rename 移入 parent → `rmdir` staging（best-effort） |
| normal success（linkat 路径） | unlink source temp → `rmdir` staging（best-effort） |
| write failure | close fd + unlink temp + rmdir staging（best-effort）；P 零改动 |
| publication failure | 同上；P 零改动 |
| cancel before publication | 同上；P 零改动 |
| crash | **不宣称** cleanup 得到保证：进程/OS 崩溃后可能残留孤儿 tmp/staging 目录（如实披露） |
| staging 目录被外部 parent writer rename | 已打开的 `stagingFD` 对**当前操作仍然安全**（fd 钉住 inode，temp 操作与发布全部 fd-relative）；但按 pathname 的 staging 清理可能失败 → **残留孤儿 staging 目录**。分类为**文档化残余效应**（P3，威胁模型内不同 uid 对手无法进入该孤儿目录） |

### R3.9 File Sync Before Publication（冻结）

temp file 内容完全写入后的冻结序列：

1. exact full content write 成功（write loop 持续至完成或错误；不足即 `partialWrite`）；
2. `fsync(tempFD)`（v1 选定原语，见 R3.11 政策 A）**成功**；
3. **仅此后**才尝试 publication。

sync 失败 → **不发布**；best-effort cleanup（R3.8）；返回稳定错误码 **`syncFailed`**（新增，纳入 tool-level failure taxonomy；语义 = 内容已写入 temp 但 sync 失败，绝不发布；errno 不外泄，既有规则不变）。

### R3.10 Directory / Metadata Sync After Publication（冻结）

明确区分两类 namespace sync，**不假设只 sync 一个目录即证明全部 namespace 变更持久**（rename / link+unlink 改动两个目录）：

- **destination parent namespace sync**：发布后对 `parentFD` 的 fsync；
- **source staging cleanup sync**：staging 清理后对相关目录的 best-effort fsync。

v1 保守政策（冻结）+ 精确失败语义：

- publication 成功 + **best-effort** parent namespace sync + **best-effort** staging cleanup sync；
- **失败语义**：publication 原子成功后，parent/staging sync 失败**不**翻转 tool result（target 已完整可见；sync 失败仅意味着 persistence hardening 未完成，记入本地日志）；tool result 恒以 **publication 结果**为准。

### R3.11 Durability Scope 与 F_FULLFSYNC 决策（R2 Finding 2 remediation，冻结）

**撤回** R2.17「dir fsync 后 → durable」表述。

四层区分（冻结术语）：

| 层 | 提供者 | v1 状态 |
|---|---|---|
| atomic namespace visibility | `renameatx_np(RENAME_EXCL)` / `linkat` | **保证**（观察者只见 P 不存在或完整内容） |
| filesystem sync request completion | `fsync()` 调用成功返回 | 保证「请求已完成」；不保证物理落盘时序 |
| OS-crash persistence | 普通 `fsync()` **不承诺** | **不承诺** |
| device-cache / power-loss persistence | 需 `F_FULLFSYNC` 级原语 | **不承诺**（政策 A） |

**F_FULLFSYNC 决策：选 A** —— v1 不承诺 power-loss durability；使用普通 fsync 式 persistence hardening。**不**冻结 F_FULLFSYNC 调用、fallback 与错误策略（若未来需要更强保证，另立架构验收冻结确切原语与错误行为）。

冻结语言：

> write_file v1 保证 **atomic no-clobber visibility**，不保证 **power-loss durability**。pre-publication file sync 为 **required gate**（失败即不发布，R3.9）；post-publication namespace/staging sync 为 **best-effort persistence hardening**（R3.10），而非 transactional durability guarantee。在任何报告 / 日志 / UI 中，未经 failure model 定义不得使用 "durable" 一词。

### R3.12 Revised Crash Matrix（取代 R2.17 表）

| 崩溃点 | target 可见？ | 可见则内容完整？ | temp/staging 孤儿可能？ | sync request completed？ | power-loss survival |
|---|---|---|---|---|---|
| temp content 完成前 | 否 | — | 可能（staging + partial tmp） | 否 | **NO GUARANTEE** |
| content 完成、file sync 前 | 否 | —（不可见） | 可能（staging + tmp） | 否 | **NO GUARANTEE** |
| file sync 完成、publication 前 | 否 | —（不可见） | 可能（staging + tmp） | file sync 成功返回 | **NO GUARANTEE**（persistence hardening 已请求；power-loss 不承诺） |
| publication 完成、namespace sync 前 | 是 | 是（原子 no-clobber 发布） | 否（temp 已移走 / 待 unlink） | file sync 成功；namespace sync 未完成 | **NO GUARANTEE**（P 目录项可回退消失） |
| namespace sync 完成 | 是 | 是 | 否 | parent fsync 成功返回 | **NO GUARANTEE**（政策 A：不承诺 power-loss；persistence hardening 已完成） |

每行 power-loss 列一律 **NO GUARANTEE**（政策 A）；本矩阵全文不出现未定义的 "durable"。atomic visibility（第 4、5 行的「可见且完整」）与 power-loss survival 是两个独立保证，绝不混同。

### R3.13 既有冻结决定保留清单（R3 确认，未重开）

**Terminal（全部维持）**：bracket start = 6 字节 / end = 6 字节 / framing 合计 12 字节 / CR = 1 字节；`payloadBytesAccepted` / `framingBytesAccepted` 的 Accepted = transport-acknowledged prefix（非 consumed / executed / rendered）；`TerminalMutationByteWriter` required；`LocalProcess.send` 不适合作 authority；普通 `RemoteTerminalService` delegate path 不适合作 authority；partial START 1…5 字节 → `terminalInputStateUncertain` → chain halt；immutable `TerminalMutationEndpoint`；`inputTargetEpoch`；Local exact PTY/process incarnation；Remote exact SSHConnection + shell-channel incarnation；一个 frame 不跨 incarnation；no active-tab fallback。

**File（全部维持）**：v1 `write_file` = CREATE ONLY；OVERWRITE = DEFERRED；Remote write = DEFERRED；directory-inode capability semantic；`displayedPathSnapshot` 非 authority；UTF-8 text only；256 KiB 上限；binary/base64 排除。

**仅修复两项**：staging directory creation/binding（R3.1–R3.4）；durability wording/primitive（R3.9–R3.12）。未发现任何与已接受 terminal 架构的具体矛盾，不重开 terminal 架构。

### R3.14 Planned Test Architecture（R3 追加矩阵，仍不在本阶段实现）

**Staging**：
1. `mkdirat` success；
2. `mkdirat` EEXIST collision → 重生成重试；
3. stagingName 在 openat 前被替换（注入 hook）→ abort 路径；
4. 替换物 owner 为不同 uid → ownership validation failure → abort，零发布；
5. 替换物为 symlink → `O_NOFOLLOW` 拒绝（ELOOP）→ abort；
6. `openat` `O_NOFOLLOW` 拒绝路径；
7. 打开的 staging ownership mismatch → abort；
8. 打开的 staging mode mismatch（group/other 位非 0）→ abort；
9. staging 目录于 FD 获取后被外部 rename → 全部 temp 操作继续经 frozen `stagingFD` 成功。

**Publication**：
10. `RENAME_EXCL` no-clobber（P 已存在 → EEXIST → `targetChanged`）；
11. `linkat` no-clobber（同上，fallback 路径）；
12. source temp full-content verification（发布内容 == 批准内容 C）；
13. source cleanup（linkat 路径发布后 tmpName 消失）；
14. cleanup failure leaves documented orphan（注入 unlink 失败 → 孤儿如实披露，不影响 result 语义）。

**Sync / crash semantics**：
15. temp sync failure prevents publication（`syncFailed`，P 零改动）；
16. publication 成功 / namespace sync 失败 → result 仍为 published（不翻转）；
17. staging cleanup sync 失败 → result 仍为 published；
18. 无 false "durable" 结果断言（result/日志词汇审计）；
19. 普通 fsync 政策下，任何代码路径不断言 power-loss durability。

### R3.15 Revised Architecture Decision Table（R3 增量）

| Decision | Frozen Result |
|---|---|
| Staging creation | `mkdirat(parentFD, stagingName, 0700)`（EEXIST 重生成）；`openat(O_CREAT\|O_DIRECTORY)` 创建原语**撤回**（R3.1） |
| Staging open/bind | `openat(parentFD, stagingName, O_RDONLY\|O_DIRECTORY\|O_CLOEXEC\|O_NOFOLLOW)` → `fstat` → R3.2 验证规则 |
| mkdirat→openat race | 非原子，明示；owner==euid + 0700-or-stricter + O_NOFOLLOW 联合验证；替换 → abort 零发布（R3.2） |
| Staging identity | `StagingDirectoryCapability{parentDirectoryIdentity, stagingFD, stagingDev, stagingIno, ownerUID}`；验证后绝不按 stagingName 重解析（R3.3） |
| Temp creation | `openat(stagingFD, tmpName, O_CREAT\|O_EXCL\|O_RDWR\|O_CLOEXEC\|O_NOFOLLOW, 0600)`；EEXIST 重生成；全 fd-relative，无 path-based mkstemp（R3.4） |
| Source identity | temp 创建即 `fstat`（dev/ino/S_IFREG）；保证 = 已验证 0700 staging + fd-relative 发布 + 威胁模型 scoping（R3.4） |
| Parent semantics | 维持 directory-inode capability（R2.14/R3.5）；displayed path = snapshot |
| Publication | `renameatx_np(stagingFD,tmp,parentFD,P,RENAME_EXCL\|RENAME_NOFOLLOW_ANY)`；RENAME_EXCL = destination no-clobber，不承担 source identity（R3.6） |
| linkat fallback | EEXIST no clobber + 原子 hard-link + pre-written source + unlink source cleanup + 双名字瞬态声明（R3.7） |
| Cleanup | best-effort temp + staging；crash 后不保证；外部 rename → fd 仍安全、pathname 清理可留孤儿（文档化残余）（R3.8） |
| File sync gate | fsync(tempFD) 为 **required** pre-publication gate；失败 → `syncFailed` 不发布（R3.9） |
| Namespace sync | publication 成功 + best-effort parent sync + best-effort staging sync；sync 失败不翻转 result（R3.10） |
| F_FULLFSYNC | **政策 A**：v1 不承诺 power-loss durability；普通 fsync = persistence hardening；不冻结 F_FULLFSYNC 策略（R3.11） |
| Durability 术语 | 四层区分（visibility / sync-request / OS-crash / power-loss）；未定义 failure model 禁用 "durable"（R3.11） |
| Crash matrix | R3.12 取代 R2.17；power-loss 列全 NO GUARANTEE |

---

## Testing Strategy（设计，不在本阶段实现；**[R1 修订]** 追加矩阵见 R1.11；**[R2 修订]** 追加矩阵见 R2.19；**[R3 修订]** 追加矩阵见 R3.14）

### terminal deterministic（10F-B）
Approve exactly once（双击/双 claim/双 redeem）、Deny 零字节、Stop pending 零字节、wrong-session scope 拒绝、session switch 无影响、session close → cancelled、late approve 零写入、stale approval、partial write（fork 字节计数注入 mock）、EAGAIN 路径、多行 LF、unicode（CJK/emoji/VS16 与 P7 策略回归）、control char 拒绝全集（NUL/ESC/CSI/OSC/BEL/TAB/CR/DEL/C1）、Local 与 Remote 各一、submit true/false 的 CR 字节断言、terminal state mutation 观察（ZLE buffer / cwd 变化断言经 mock shell）、tool result schema、provider continuation 配对。

### terminal live（10F-B-R）
真实 Provider + 真实 Approval Card + 真实 Local Terminal：`send "cd /tmp" submit=true` → Approve → 用户/Agent 经 `get_terminal_context` 确认 interactive cwd **确实**变为 /tmp；对照组：`run_command "cd /tmp"` 不得改变 interactive cwd。Remote live：沿用 fixture 规则（§54），无 fixture 即 NOT RUN。

### file deterministic（10F-C）
create/overwrite、deny 零变更、cancel 零变更、outside scope、`..`、final symlink 拒绝、parent symlink 拒绝、TOCTOU（approval 后替换 target/parent 的注入 hook，复用 `SFTPFileOperations` 的 test-hook 模式）、非 regular file、UTF-8 invalid、256 KiB 边界（±1）、写失败注入、partial write、原子性（crash/失败后目标文件完整性）、Local 全套、session close、double approve、replay、provider switch。

### file live（10F-C-R）
仅 `/tmp/macssh-agent-10f-*` 临时路径；不触碰用户真实项目文件（除非该阶段任务书显式授权）。Remote live：见 Remote live 规则。

### Remote live 规则（沿用）
无已授权 SSH fixture → `REMOTE LIVE: NOT RUN`；禁止 ssh-keygen / authorized_keys / Remote Login / 网络扫描 / 读取未知凭据。

---

## Proposed Phase Split（冻结，§46）

| 阶段 | 内容 |
|---|---|
| 10F-A | 本架构调查（本报告） |
| 10F-B1 | Terminal Mutation domain：request/状态机 coordinator（复制 10E 语义）+ schema/payload 校验 + 测试基座；不接 UI/Provider |
| 10F-B2 | Local send：SwiftTerm fork byte-accounting send 入口 + `AgentTerminalSendService`（Local 分支）+ partial delivery 语义确定性测试 |
| 10F-B3 | Remote send：`writeChannelInput` delivered-byte 变体 + Remote delivery 分支 + session close/disconnect 竞态测试 |
| 10F-B4 | Provider tool definition + AgentViewModel 接线（mutation 链复制 run_command 模式）+ Approval Card UI + Stop/prune 全链 |
| 10F-B-R | Live E2E re-acceptance（§52 对照组含 run_command 语义反证） |
| 10F-C1 | File Mutation domain：`AgentWriteScope` + write-safe containment + TOCTOU 策略类型 + failure codes |
| 10F-C2 | Local `write_file`（**[R1 修订]** 仅 CREATE：dir fd + mkstemp + RENAME_EXCL 原子发布）+ 确定性测试 |
| 10F-C3 | **[R1 修订]** 「Publication & Remote Write spike」：① OVERWRITE 契约（RENAME_SWAP 补偿回滚可行性 + metadata contract 落地验证）；② Remote SFTP 写能力（LSTAT/readlink 链、rename 旗标、fsync 可行性）。产出是否解除各自 defer 的建议；默认均维持 defer |
| 10F-C4 | Provider + AgentViewModel + File Approval Card（含展开查看）集成 |
| 10F-C-R | Live File Mutation acceptance（/tmp 隔离路径） |

依据：send 与 write 是两套审批 UI / 两套失败语义，分批验收与 10E（B1→B4→R）节奏一致；先 terminal 后 file 因为 terminal 的交付层改造点（fork、SSHChannel）更小且已有 run_command 的 approval 集成先例可整体复制。替代拆分（先 file 后 terminal）无明显安全收益且失去 10F-B-R 对 fork 改动的独立验收点。

---

## Architecture Decisions（冻结清单，§55；**[R1 修订]** 被取代项以 `[R1 修订]` 标注，详见 R1.12）

1. **send_to_terminal schema**：`{"text": string, "submit": boolean}`，两者 required，additionalProperties false。
2. **terminal control-character policy**：UTF-8 only；拒绝全部 C0（除 LF）/ CR / DEL / C1；submit 由 delivery 层追加恰好一个 CR；64 KiB 上限。
3. **terminal target binding**：origin sessionID（generation 冻结）+ callID + generationID + providerSnapshotID + exact payload；active-tab fallback 禁止。**[R1 修订]** target 增加 incarnation 维度：`TerminalInputTargetIdentity` = sessionID + inputTargetEpoch + endpointToken（R1.6）。
4. **terminal approval model**：新建 mutation 专用 coordinator（复制 10E 状态机语义：actor、CAS claim、permit redeem、waiter exactly-once、denied≠cancelled）；泛型 core 抽象推迟到 10F-C 之后。
5. **terminal result model**：**[R1 修订]** status + payloadBytesRequested/Delivered + framingBytesRequested/Delivered + submitRequested/Delivered + bracketedFramingUsed + terminalState（R1.4）；不捕获终端输出；观察走 get_terminal_context。
6. **partial-delivery semantics**：byte accounting 贯穿 Local（fork 扩展）与 Remote（writeChannelInput 变体）；partial → `partialDelivery`，绝不 whole-payload retry，绝不谎报 cancelled 零副作用。**[R1 精化]** frame 逐阶段失败语义与 `terminalInputStateUncertain` 链停语义见 R1.2/R1.3。
7. **first file mutation tool**：`write_file`，schema `{"path","content"}`，required both，additionalProperties false。
8. **write scope model**：新建 `AgentWriteScope`（独立类型，复用同一 canonical root 来源）；Read Scope ≠ Write Sandbox。
9. **symlink policy**：parent 组件 symlink 逃逸 → 拒绝；final symlink → `symlinkRejected`；Remote 同规则（deferred 阶段）。
10. **TOCTOU strategy**：approval 时 lstat identity（dev,ino）→ write 时 directory fd + `openat O_NOFOLLOW` + fstat identity 复核 + `renameat`；CREATE 用 `O_EXCL|O_NOFOLLOW`；identity 不符 → `targetChanged`。**[R1 修订]** v1 CREATE-only：dir fd + `fstatat(dirfd,".")` 身份比对 + 同目录 mkstemp → `renameatx_np RENAME_EXCL|RENAME_NOFOLLOW_ANY`（备选 linkat）；OVERWRITE 路径**撤回**（fstat+renameat 不关闭 pathname 竞态，R1.7）。
11. **atomic local write strategy**：OVERWRITE = 同目录 mkstemp → fsync → renameat → dir fsync；CREATE = O_EXCL 直写 + fsync；失败清理 tmp。**[R1 修订]** CREATE 改为 mkstemp → fsync → RENAME_EXCL no-replace **原子发布** → dir fsync（目标 pathname 写入期间不可见）；OVERWRITE **DEFERRED TO SPIKE**（R1.7/R1.8）；失败清理 tmp。
12. **Remote write decision**：**DEFERRED**（fsync 不可得、rename 旗标服务器相关、server-side TOCTOU 无法从 client 消除）；10F-C3 为 spike 槽位。
13. **file size limit**：256 KiB；UTF-8 text only；binary/base64 排除；invalid UTF-8 → `encodingInvalid`。**[R1 修订]** `encodingInvalid` 移出 tool-level taxonomy，仅保留于 lower-level internal API（R1.9）。
14. **file approval UI**：CREATE/OVERWRITE + target + frozen root + canonical path + content size + existing size（overwrite）+ collapsed preview + 截断指示 + 架构预留展开全文；不可编辑 payload。
15. **risk taxonomy**：readOnly / commandExecution / interactiveTerminalMutation / fileMutation 四类独立 disclosure。
16. **recommended implementation sequence**：10F-B1→B2→B3→B4→B-R → 10F-C1→C2→C3(spike/defer)→C4→C-R。
17. **tool count**：10F-B 结束 = 6（+send_to_terminal）；10F-C 结束 = 7（+write_file）；其余 mutation 名维持 prohibitedNames。
18. **per-call approval 基线**：每次 mutation 单独批准；Always Allow / session 级信任 / auto-approve 一律不在 10F 设计范围。

无 BLOCKED 项。

---

## Files
### Added Docs
- `Docs/Phase10F-A-Mutation-Tools-Architecture.md`（本文件，untracked）

### Production Modified
- 0

### Tests Modified
- 0

### Unexpected
- 0

---

## Findings

### P1
- count: 0
- items: —

### P2
- count: 0
- items: —（R1 验收 4 项 P2 已由 R1/R2 章节 remediation 关闭：framing 计数（R2.1，fork `40d473b1` 实测 6B/6B/12）；physical accepted-byte accounting 不可观察（R2.3 `TerminalMutationByteWriter` contract）；partial start 语义（R2.4）；mutable delegate path / reconnect retarget（R2.6–R2.10）。R2 验收 2 项 P2 已由 R3 章节 remediation 关闭：① staging 创建原语 `openat(O_CREAT|O_DIRECTORY)` 无效（本地 man 2 open 实证 O_CREAT 只建文件条目、O_DIRECTORY 不创建目录）→ 撤回并冻结 `mkdirat → openat → fstat 验证` 序列、opened-FD validation 规则与 `StagingDirectoryCapability`（R3.1–R3.4，关闭 P2「staging creation primitive 无效 / mkdirat→openat race 被忽略 / staging identity 未验证 / source authority 落回 path 重解析」四项子问题）；② fsync durability 过度宣称（本地 man 2 fsync 实证 drive 可不物理落盘）→ 撤回 R2.17 "durable" 表述，冻结政策 A durability scope、pre-publication required sync gate（`syncFailed`）、post-publication best-effort namespace/staging sync、修订 crash matrix（R3.9–R3.12）。R3 preflight 未发现新 P1/P2）

### P3
- count: 4
- items:
  1. Remote write 维持 DEFERRED（fsync 不可得 / rename 旗标服务器相关 / server-side TOCTOU 无法从 client 消除；10F-C3 spike）。
  2. `RENAME_EXCL`/`RENAME_NOFOLLOW_ANY` 为卷能力（`VOL_CAP_INT_RENAME_*`，APFS 支持；非 APFS 卷可能 EOPNOTSUPP/EINVAL）——10F-C2 实现需 linkat fallback + 对应确定性测试（R1.7 step 5 / R2.16 / R3.7 已冻结 fallback 路径与语义）。
  3. staging 威胁模型对 root / 同 uid 进程 / 已攻破本进程的对手不设防（R2.15 / R3.2 scoping 如实披露）——文档级已知边界；多行 payload 无 bracketed paste 时逐行执行的残余风险维持 R1.5 冻结（披露缓解）。
  4. 【R3 新增】staging 目录被外部 parent writer rename 时，pathname 清理可能失败并残留孤儿 staging 目录（stagingFD 对当前操作仍安全；孤儿目录 0700 威胁模型内不可触达）——文档化残余效应（R3.8）；OVERWRITE 与 Remote write 维持 DEFERRED 不变。

---

## Decision

PHASE 10F-A-R3 ARCHITECTURE PASS

Terminal architecture:
FROZEN

Staging directory capability:
FROZEN

File CREATE publication:
FROZEN

Durability scope:
FROZEN

OVERWRITE:
DEFERRED

Remote write:
DEFERRED

NO PRODUCTION CODE CHANGED.
NO TEST CODE CHANGED.
NO COMMIT.
NO PUSH.

READY FOR INDEPENDENT ACCEPTANCE.

STOP.
