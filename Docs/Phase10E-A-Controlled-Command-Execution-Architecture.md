# Phase 10E-A — Controlled Command Execution Architecture Investigation

调查报告。本阶段 source 0 修改、0 测试修改、0 pbxproj 修改、0 commit / push / merge / tag。
报告 untracked，不 stage。

---

## Repository

- path: `/Users/msl/msl_coding/MacSSH`
- branch: `main`
- HEAD: `73038d61b9f2b22b027e3748d06600984186a29a`
- tree: `53f3cd036c6ec476a47c04f50a49f76b658c4e68`
- tracked changes: 无（`git status --short` 仅 untracked）
- untracked docs: 6 × `Docs/Phase10D-*.md`（既有）；本报告完成后为 7
- source modified: NO（全程只读：read / grep / git 查询）

---

## Current Agent Runtime

### tool registry

`MacSSH/Services/Agent/Tools/AgentToolModels.swift` L9–48：
- `AgentToolName`：**静态枚举** 4 个 case（`get_terminal_context` / `get_current_directory` /
  `list_directory` / `read_file`）；`AgentToolRegistry.lookup(_:)` 只认这 4 个字符串，
  未知名字一律拒绝。禁止 reflection / 任意字符串派发。
- 每个名字带 `risk: AgentToolRisk`（当前全部 `.readOnly`）与
  `dataAccessPolicy`（`sessionContext` / `scopedFileRead`）。
- `AgentToolPolicy.swift` L4–20：**风险轴与披露轴正交**，两个独立 enum，
  这是 run_command 风险类别的扩展点（见 §77 分析）。

`MacSSH/Services/Agent/Tools/AgentToolDefinition.swift`：
- `AgentToolCatalog.definitions`（L26–58）：provider 可见的**静态 allowlist**，
  恰好 4 个 `AgentToolDefinition{name, description, parametersJSON}`。
- `AgentToolCatalog.prohibitedNames`（L65–69）：**显式禁止注册名单，当前字面包含
  `"run_command"`**（以及 `send_to_terminal` / `write_file` / `shell` 等）。
  这是 10E-B4 接入时的必须改动点：把 `run_command` 从禁止名单移除并加入
  allowlist（同一文件、同一 gate 语义不变）。
- `AgentToolCallParsing.parse`（L91–134）：raw JSON → typed arguments → validate。
  当前 typed 形态只有 `path: String?`（L93–95）；run_command 需要扩展为
  `command: String`（新增 typed struct + parse 分支，保持"本地验证是安全边界、
  不信任 provider strict"哲学）。

### Agent loop

`MacSSH/Services/Agent/AgentViewModel.swift`（@MainActor @Observable）：
- `maxToolRounds = 10`（L27）：一轮 provider response 内 ≥1 个 function call = 1 round；
  第 11 个 round 请求工具 → `failGeneration(.toolRoundLimit)` 终止（L342–353）。
- `runToolLoop`（L253–417）：每轮
  `provider.stream(transcript:tools:context:)` → 消费事件（textDelta / toolCall /
  providerItem / completed）→ tool call 以 `.running` 状态**先 append card**（L307–315，
  §37 privacy gate）→ 收集 `pending[(call, cardID)]` → **按 provider output order
  串行执行**（L357–381）→ 执行完所有 calls 才发起下一轮 continuation（L383–385 hard race gate）。
- `executeTool`（L420–487）：`AgentToolCallParsing.parse` → `toolRouter.execute` →
  `conversation.updateToolActivity`。结果分类：
  `.success` → success card；`.failure(.cancelled)` → **throw CancellationError**
  （取消绝不转普通失败，L458–466）；`.failure(.sessionUnavailable)` → fatal 收尾
  （绝不改去其它 session，L369–380）；其余 failure → 结构化 result（模型可解释）。
- 取消链：`stop()` → `conversation.cancelGeneration()` → `generationTask.cancel()`
  → loop 内 `Task.checkCancellation()`（轮首 L360、执行后 L385、流内 L302）→
  `cancelRunningToolCards`（L529–542：全部 running card 收敛 cancelled + 结构化
  `{"ok":false,"error":"cancelled"}` 输出，保证 call_id 配对恒成立）。

### generation binding

`AgentViewModel.startGeneration`（L166–246）每次 Send 冻结：
1. `generationID = UUID()`（L170）；
2. `sessionID = session.id`（origin session，非 active 指针，L171）；
3. `AgentTerminalSessionHandle`（cwd 快照 / buffer source，L174）；
4. `provider.snapshotForGeneration()`（L196–215：provider/model/baseURL/credential
   冻结，Settings 中途变更只影响下一次 Send）；
5. `readScope = freezeReadScope(...)`（L221–226 / L551–574：Local 用 OSC7 cwd
   canonical 化；Remote 经 SFTP realpath 服务端 canonical 化；失败 → 空 roots）。

identity guard：loop 每次迭代与流事件回调都校验
`conversation.generationID == generationID`（L269 / L303），late events 丢弃。

### session binding

- `AgentConversation`（`AgentConversation.swift`）：per-`sessionID` 持有；
  `sessionID` 是 `let`（L24）。conversation 创建/查找只按显式 sessionID。
- Remote 服务解析 `AgentRemoteServiceResolver.swift`
  `SessionManagerAgentRemoteServiceResolver`（L25–54）：`sessionID →
  SessionManager.session(withID:) → kind == .remoteSSH && !isClosed →
  connection != nil && phase == .connected → façade`。不可寻址返回 nil
  （调用方 `sessionUnavailable`），**绝不 fallback 其它 session / 本地文件系统 /
  自动重连**。
- Router hard gate（`AgentToolRouter.swift` L43–45）：`readScope.sessionID != sessionID`
  → `.scopeSessionMismatch`（P1 级防御）。

### cancellation

见上（Agent loop）。要点：Stop 的语义覆盖「流中 / call 已返回未执行 / 执行中 /
执行后 continuation 前」四个窗口（L302 / L360 / Router 前后 checkCancellation /
L385），且 executor 级取消（10E 新增）必须复用同一 Task 取消传播。

### Tool Card lifecycle

`AgentToolActivity.swift` L15–78：单条目 = callID（provider 配对身份）+ toolName +
argumentsJSON + displayTarget（用户可见展示，绝不进日志）+ status + resultJSON + isError。
`Status` 当前恰 4 个 case：`running / success / failure / cancelled`（L17–32）。
**没有 awaitingApproval 状态**——10E-B1 需要扩展 Status（approval 是执行前状态，
不是 provider transcript 形态）。transcript 重建时 tool 条目输出为
`function_call` + `function_call_output` 严格配对（`ResponsesProviderCore.swift`
L151–187；中断时以 cancelled 输出兜底配对）。

### Provider continuation sequencing

`ResponsesProviderCore.swift`：
- 请求体只含 `{model, input, stream, tools, tool_choice:"auto"}`（L32–47）；
- `inputItems`（L125–214）：system context 前置 → 文本消息 → tool turn
  （**先全部 function_call 再全部 function_call_output 分组**，DeepSeek thinking mode
  硬要求 + OpenAI parallel calls 标准形态）→ opaque provider item 按
  `providerScope` 过滤回放（reasoning 前移规则 L188–209）；
- transcript 由本地结构化消息每轮**全量重建**，Tool Result 只以
  `function_call_output` 形态出现，绝不伪装成 user/system message（§40 已有先例）。

**接入层结论**：command execution 应接入 **AgentViewModel tool loop 与 Router 之间
的新 approval-boundary 层**（详见 Recommended Implementation）：
- loop 负责：approval 状态机挂起/恢复、card 状态、transcript 配对（全部复用现有结构）；
- Router 保持 read-only dispatch 职责不变（§11 结论见下）；
- executor（Local/Remote）是新组件，不进入现有 4 工具的 dispatch 分支。

---

## Current Local Architecture

### terminal implementation

`MacSSH/Services/Terminal/LocalTerminalService.swift`：
- SwiftTerm `LocalProcessTerminalView`（fork）；`startProcess(executable:args:
  environment:execName:currentDirectory:)`（L173–179）内部 forkpty + execve，
  PTY master 归 SwiftTerm I/O 队列。
- `terminate()`（L201–253）：`terminalView.terminate()` 关 PTY master → SIGHUP/EIO
  使会话链退出；随后**后台轮询 waitpid**（WNOHANG，10s 上限）reap，防僵尸。
  注意：对 setuid `/usr/bin/login` 的 SIGTERM 因 EPERM 无效——这一事实说明
  **任何"只杀直接 child"的策略都不可靠**（§26 的现状证据）。
- cwd 来源：`hostCurrentDirectoryUpdate`（L314–318）← SwiftTerm fork 的 OSC 7
  解析 → `session.currentDirectory` → `AgentWorkingDirectory.fromOSC7URL`
  （`AgentWorkingDirectory.swift` L60–75：非法/非 file scheme → `.unavailable`，
  绝不猜测）。

### shell launcher

`LocalShellLauncher.swift`：
- 首选 `/usr/bin/login -p -f <user>`（setuid root，Terminal.app 同构登录链），
  回退 directShell（argv[0] 前缀 `-` 的账户 shell）。
- **环境策略先例（L150–213）**：不复制 GUI App 进程环境；只传最小集合
  `TERM/COLORTERM/HOME/USER/LOGNAME/LANG`（+ zsh ZDOTDIR / MACSSH_* 控制变量）。
  这是 10E environment allowlist 的项目内先例（§21）。

### process model

- Terminal PTY 进程：SwiftTerm fork 内部 forkpty；App 只持有 `shellPid` 与
  delegate 回调。
- **当前 App 内没有任何独立子进程执行基建**（无 Foundation Process 使用、无
  posix_spawn 调用；grep 全仓确认）。10E-B2 的 Local executor 是全新组件。

### current cwd source

`AgentViewModel.handleProvider(session)` → `AgentTerminalSessionHandle`
（`AgentTerminalContext.swift` L48–55：`id / sessionKind / displayName /
workingDirectory / bufferSource`）→ `AgentWorkingDirectory`
（path + source + confidence 三元组，`AgentWorkingDirectory.swift` L37–89）。
generation 开始时取一次快照后冻结（readScope 与工具的相对路径基准共用）。

### candidate independent execution APIs

| 方案 | 进程组 | 部分可行性 | 评价 |
|---|---|---|---|
| Foundation `Process` | ❌ 无 setpgid 暴露 | `terminate()` 仅 SIGTERM 直接 child；孙进程/后台 job 逃逸 | 不能满足 §26/§27 |
| `posix_spawn` + `POSIX_SPAWN_SETPGROUP`（spawnattr_setpgroup(g,0)） | ✅ 原子（spawn 时即成组，无 after-fork race） | `posix_spawn_file_actions_addchdir_np`（macOS 10.15+）设 cwd；两 pipe 手工管理 | **推荐** |
| fork + setpgid + exec | ✅ | Swift 下 fork 安全性差（ObjC runtime / Swift runtime 死锁风险），Darwin 不建议 | 否决 |
| ScriptingBridge / NSAppleScript | — | 向 Terminal.app 注入 = 禁止路径 | 否决 |

macOS 对 `posix_spawn` 支持 `POSIX_SPAWN_CLOEXEC_DEFAULT`（防 fd 泄漏，
与项目 `O_CLOEXEC` 先例 `PasteHighlightControlChannel` 同哲学）。

### environment behavior

GUI App 进程环境包含 IDE/调试变量（`__CF*`、potential tokens）。现有 Terminal 启动链
已确立"显式最小集合"惯例（LocalShellLauncher L180–213）；`ProcessInfo.processInfo.environment`
全量透传被项目既有规范排除。

---

## Current Remote Architecture

### SSHConnection ownership

`MacSSH/Services/SSH/SSHConnection.swift` L86：`actor SSHConnection` 是
`LIBSSH2_SESSION *` 的**唯一串行所有者**。每条 Remote Session 独立一条连接
（`SessionManager.swift` L15–19 注释、`createRemoteSession` 不共享）。
- 指针槽位：`session`（L155，internal 供同模块扩展）、`shellChannel`（L164）、
  `sftpSubsystem`（L205）。
- 在途任务槽位（防 use-after-free / double-free 的工程模式）：`disconnectTask`
  （L197）、`shellChannelOpenTask`（L190）、`shellChannelCloseTask`（L177）、
  `sftpInitTask`（L221）；SFTP 另有句柄登记令牌
  `openSFTPDirectoryHandles`（L213）/ `openSFTPFileHandles`（L239）+ 在途计数
  `inFlightSFTPListingCount` / `inFlightSFTPFileOperationCount` + 排空续体。
- EAGAIN 策略：全程 non-blocking（L690）+ `runWithRetry`（L1262–1278）+
  `waitForLibssh2Readiness`（L1297–1327：`libssh2_session_block_directions` →
  poll，0.25s 切片防"数据进内部队列后 poll 睡死"，L1280–1288）。
- `disconnect()`（L533–606）：共享单飞任务；断开标志从一开始置位（新 channel
  打开入口即拒）；teardown 顺序 目录句柄 → SFTP → Shell Channel → Session → socket。

### interactive PTY channel

`SSHChannel.swift`（extension SSHConnection）：
- `openInteractiveShell`（L86–119）：`libssh2_channel_open_ex("session")`
  （L515–523，窗口 2MB / packet 32768）→ `request_pty_ex`（xterm-256color +
  真实尺寸）→ `process_startup(channel, "shell", 5, nil, 0)`（L593）。
- 读取：`readChannelOutput`（L183–244）**只读 stream 0**；EOF 判定
  `libssh2_channel_eof`；空闲 poll 1s。
- 写入：`writeChannelInput`（L262–324，partial write 循环）。
- 关闭：`closeShellChannel`（L394–411）→ `performGracefulShellChannelClose`
  （L457–498：`send_eof` → `close` → `wait_closed` → `free`，各步尽力而为，
  free EAGAIN 重试）。
- **现状：无 exec、无 exit status 读取、无 stderr（stream 1）读取**（grep 确认
  `process_startup` 仅 "shell" 一处）。exec 能力是 10E-B3 全新 extension 方法，
  但底层 C API 在 vendored libssh2 1.11.2_DEV 中全部可用：
  `libssh2_channel_process_startup`（libssh2.h L884，"exec" request），
  `libssh2_channel_read_stderr`（L906，= read_ex(stream_id=SSH_EXTENDED_DATA_STDERR)），
  `libssh2_channel_get_exit_status`（L996），`libssh2_channel_get_exit_signal`
  （L998），`libssh2_channel_signal_ex`（L878，远端信号请求）。

### SFTP coexistence

`SFTPSession.swift`：`openSFTPSubsystemIfNeeded`（L97–121，幂等去重）；
`sftpRealpath`（L155–199）；**SFTP 操作串行门**
`acquireSFTPOperationGate`/`releaseSFTPOperationGate`（FIFO，L235–236 / 连接
状态 L263–266）：`LIBSSH2_SFTP` 携带子系统级共享状态（open_state / readdir_state /
request ID），EAGAIN 让出 actor 的重入窗口内第二个操作会串线，因此任一时刻至多
一个持门者。10D 已证明 PTY + SFTP 共存；**exec channel 是第三种 channel**，
libssh2 协议层允许多 channel 并存（每 channel 独立指针），不触碰 SFTP 共享状态，
不需要进入 SFTP 门，但应与 shell channel 一样登记/去重（见 Remote Executor）。

### available channel APIs

见上。exec 路径所需 API 全部在 vendored 头文件中（版本 `1.11.2_DEV`，libssh2.h L46）。

### exec support

当前源码无 `exec` 实现。10E-A 不实现；10E-B3 以
`SSHChannel.swift` 同一 extension 模式新增（actor 隔离不变）。

### EAGAIN / readiness

复用 `runWithRetry` / `waitForLibssh2Readiness` / `idleWait` 既有机制；
exec 读循环遵循 `readChannelOutput` 的"一次调用内有界等待、绝不内部无限轮询"模式。

### disconnect lifecycle

`SessionManager.teardown`（L312–335）：transfers 屏障 → `sftp.stopBarrier()` →
`remote.stopBarrier()` → `connection.disconnect()`。Reconnect（L346–389）同序。
command exec channel 的清理必须挂入同一拆除链（见 Cancellation Matrix
"Session close" 行），否则 channel 随 `libssh2_session_free` 隐式回收
（内存安全，但失去"主动 signal/close"机会）。

---

## Core Security Finding

**冻结结论：`run_command` 无法使用 Phase 10D 的 `AgentReadScope` 作为安全沙箱。**

- `AgentReadScope` 的全部语义是**路径读取门**：`allowedRoots` canonical 根 +
  path-component aware containment（`AgentReadScope.swift` L52–62），唯一消费方是
  文件工具的路径解析（`AgentPathResolver.resolve` L94–97 containment 判定）。
  它不约束进程行为——shell command 一旦执行：
  - `cat /any/path`（读任意文件，含 `~/.ssh/id_rsa`、Keychain 之外的一切可读物）；
  - 写/删任意可写路径（cwd 在 root 内不构成任何限制）；
  - 发起任意网络请求（curl / ssh / nc）；
  - fork 任意子进程；执行任意程序；修改 Git 仓库；读取 App 无法控制的凭据文件。
- `cwd containment ≠ command sandbox`：cwd 只决定子进程的起始目录。
- 因此 **approval UI 是 run_command 的唯一安全边界**（§81），readScope 对
  run_command 仅保留一个非安全用途：**cwd 的权威性判定**
  （frozen cwd 必须来自 authoritative OSC7，见 Binding 一节）。
- 网络沙箱：不存在（Local/Remote command 均有完整网络能力，§79/§80）。
- 文件系统沙箱：不存在（App 无 Sandbox，见下）。

### macOS Sandbox 现状（§82 实证）

- `MacSSH.xcodeproj/project.pbxproj`：`ENABLE_APP_SANDBOX = NO`（Debug/Release
  两处，L1408/L1448）；`ENABLE_HARDENED_RUNTIME = YES`；`CODE_SIGN_ENTITLEMENTS =
  MacSSH/MacSSH.entitlements`（L1468）；`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`。
- `MacSSH/MacSSH.entitlements`：**空 dict**（Phase 12 注释：Non-Sandbox Developer ID）。
- 结论：子进程不受 App Sandbox 约束（无 seatbelt profile 继承）；Hardened Runtime
  不限制子进程 spawn（`com.apple.security.cs.allow-unsigned-executable-memory` 等
  例外不需要）。**不要假设 child process 有任何 filesystem sandbox**。

---

## Proposed run_command

### Schema

```json
{
  "type": "object",
  "properties": {
    "command": { "type": "string" }
  },
  "required": ["command"],
  "additionalProperties": false
}
```

| 字段 | 模型可控 | 决定 |
|---|---|---|
| `command` | YES（唯一字段） | YES |
| `cwd` | NO | 冻结自 generation 快照（§12–§16） |
| `shell` | NO | App 决定（Local：账户 shell `-c`；Remote：服务器 exec shell） |
| `environment` | NO | App allowlist（§21） |
| `stdin` | NO | closed/EOF，无参数形态 |
| `output limits` | NO | App 固定（§32） |
| `timeout` | NO（10E 不暴露给模型） | App 固定 default/hard max（§29/§126） |

`timeout` 参数调查结论：**不作为模型参数**。理由：模型可控 timeout 直接等比放大
任意等待型命令（`sleep`、长网络请求）的窗口，且审批 UI 需要多展示一个模型可篡改
的承诺值；App 固定值 + Stop 按钮已覆盖需求。若未来开放，必须 hard max + 审批卡
显式渲染（本阶段不开放）。

输入校验（10E-B1 `AgentToolCallParsing` 扩展）：
- 空 / whitespace-only command → `invalidArguments`（§86，不弹审批）；
- command 含 U+0000 → `invalidArguments`（§87，绝不进 Process/libssh2）；
- command UTF-8 字节 > 16 KiB → `invalidArguments`（§85）；
- 多行 command 允许（§88），审批卡完整显示全部内容。

### Binding

| 绑定项 | 值来源 | 冻结时机 |
|---|---|---|
| `generationID` | `startGeneration` | generation 开始 |
| `callID` | provider function_call item | 流式组装完成 |
| `sessionID` | origin session（非 active） | generation 开始 |
| `cwd`（display + canonical 二元组，见 §16） | `AgentTerminalSessionHandle.workingDirectory`（OSC7 authoritative）+ Local `AgentPathResolver.canonicalize` / Remote SFTP `realpath`（复用 `freezeReadScope` 同一解析结果） | generation 开始 |
| `provider snapshot` | `snapshotForGeneration()` | generation 开始 |

- **Frozen CWD（§14）：YES**。generation 中途用户交互 shell `cd` 不影响同 generation
  的后续 run_command 目标；与 frozen readScope 语义完全一致（delayed tool call
  target 不漂移）。
- **Authoritative CWD（§15）：必需**。cwd `confidence != .authoritative`（approximate
  / unavailable）→ 结构化 `cwdUnavailable` 错误（`AgentToolError.cwdUnavailable`
  已存在，AgentToolError.swift L20–22），**绝不 fallback** HOME /
  `FileManager.currentDirectory` / App cwd / SFTP `realpath(".")` / SSH login
  default。这一禁令与 10D `AgentPathResolver` 的既有语义逐字一致（§13）。
- **Canonical CWD（§16）：两个都保存**。
  - `displayCwd`：OSC7 解码后的 display 路径（审批卡显示）；
  - `canonicalCwd`：Local = kernel walker 结果（实际 process cwd，进程启动 chdir
    走 canonical，规避 symlink 显示/安全二义性）；Remote = SFTP realpath 服务端
    canonical 结果（wrapper 的 cd 目标）。
  - Local 执行用 canonical；UI 显示 display；两者不一致时（symlink cwd）审批卡
    显示 display + canonical（防"看到的目录 ≠ 实际执行目录"困惑）。
- **active tab 切换不改变 target**（§13/§61）：approval request 与 executor 只认
  `sessionID`，`AgentToolRouter` 的 `scopeSessionMismatch` 同款 hard gate 平移。

### Approval-required dispatch 与 read-only dispatch 的能力边界（§11）

推荐：**`AgentToolRouter` 继续只处理 4 个 read-only tools，不做统一 Tool Router**。
理由：
- Router 的现有 `execute` 契约是"同步 await Result"（AgentToolRouter.swift L32–94），
  而 command dispatch 需要「await 用户决策」的中途挂起态（continuation），把
  approval 状态机塞进 Router 会污染其无状态性并使 4 个只读工具承担审批复杂度；
- 未来 10F 的 write tools / risk framework 需要的是**分层**：Router（capability
  dispatch）+ CommandApprovalCoordinator（审批状态机）+ CommandExecutor（执行）。
  capability boundary 通过静态注册表字段表达：`AgentToolName` 新 case
  `runCommand` 时其执行路径**绝不经过** `AgentToolRouter.execute`，而经过
  新的 `AgentCommandExecutionGate`（10E-B1 命名），编译层保证两条 dispatch
  无交集；
- 无论命名如何，冻结不变式：**read-only dispatch（免审批）与 approval-required
  command dispatch 永远是两条代码路径，不存在共享"自动执行"分支**。

---

## Approval Model

- mandatory: **YES**。`run_command` ALWAYS requires explicit per-call approval
  （§7）。Agent loop 收到 run_command 后**绝不**直接执行（§91）：创建
  `AgentCommandApprovalRequest` → card 置 `awaitingApproval` → `withCheckedContinuation`
  等待用户决策 → approve 才执行。
- per-call: **YES**。每次独立审批。
- reusable / persistent: **NO**（§63）。不提供"以后都允许""允许整个目录"
  "自动批准 ls/git"。persistent policy 是 10F 范围。
- read-only-looking 自动执行: **NO**（§9）。字符串 classifier 只能做 UX hint
  （enhanced warning：`rm -rf` / `sudo` / `curl | sh` 等 best-effort 提示，
  §78），**绝不做 permission bypass**。shell grammar 可组合（command substitution /
  redirection / pipes / subshell / alias / function / 环境相关行为）使静态分类
  不可靠，这正是 §7/§9 的冻结理由。
- command visible: **YES，exact command 全文**（§65）。不能只显示"执行命令"。
  多行命令完整显示（§88），卡片可滚动/展开但执行前不可隐藏尾部（§89）。
- cwd visible: **YES**（display + canonical）。
- host visible: **YES**（Local 显示 "Local"；Remote 显示 host display name +
  session 标题）。**host 字符串不进入 shell 命令**（§84：进入 remote wrapper 的
  只有 canonical cwd + model command）。
- output sharing disclosure: **YES**（§66/§112）。审批卡固定文案（按 Locale）：
  "命令的输出（stdout/stderr）将发送给当前 AI 提供商用于继续回答。"
- reject: command **绝不执行**；输出 `{"ok":false,"error":"userDenied"}`
  的 `function_call_output`；generation 继续（§68）。
- Stop while waiting: pending approval 失效 + generation cancelled（§69）；
  旧卡上点击 Approve **不得执行**（hard race，见下 stale approval）。
- stale approval（§62/§69/§70/§71/§109）：
  - approval 绑定 `(generationID, callID, sessionID, command bytes, cwd, provider
    snapshot)`；决策恢复时校验：generation 已换 / conversation 已移除 /
    session 已关 → 决策丢弃，card 保持/收敛 cancelled，绝不执行、绝不 fallback
    active session（§70）；
  - continuation 使用冻结的 old provider snapshot（§71）；generation 已取消则
    整条链不继续（复用 10D Stop hard gate）；
  - duplicate `call_id`：10D assembler/loop 已防 duplicate；approval 创建前再做
    一次 `callID` 幂等检查（§109）。
- double approval（§108）：审批状态转移在 MainActor 同步段完成
  （`awaitingApproval → executing` 的 CAS：仅当当前状态是 awaitingApproval 才
  接受第一次决策；第二次点击因状态已变而 no-op）。Approve/Reject 按钮在状态
  变更后立即禁用。
- 用户编辑 command（§72）：**NO**。编辑改变 call identity / model intent /
  audit trail / result mapping。提供 copy command（未来），不提供编辑执行。
- Tool lifecycle（§67）：Provider call → visible approval card → user approves →
  execute → result → Provider continuation。**绝不先执行再问**。
- approval 不伪装成 provider transcript message（§100/§101）：provider transcript
  只有 `function_call` / `function_call_output`（denied 时 output =
  `userDenied`）；`approved/denied` 决策本身**不**作为 user message 发送。
- approval waiting 与 Stop 按钮（§99）：等待审批时 generation 仍 active、Stop
  可用；UI 状态显示独立 `awaitingApproval`（无 streaming spinner）。
- 顺序（§92/§93）：同一 response 多个 run_command → **serial**（现有
  `for item in pending` 已是串行，天然满足：approve/execute/finish A 之后才
  请求 B 决策）；mixed read + command → **保持 provider output order**
  （read_file 自动完成，run_command 暂停等待审批，后续 list_directory 在其
  完成后自动执行）——与 transcript 对应关系最直白，不需要额外重排逻辑。
- Tool round 计数（§98）：approval 等待不消耗 round；round 只在执行后发起
  continuation 时递增（现有计数点 L343 不移动）。
- 独立执行环境披露（§73）：system instruction + 审批卡说明
  `run_command` 在独立环境运行，`cd/export` 不影响当前 Terminal。
- 持久化（§102）：conversation 本身 memory-only（AgentConversation.swift L8–12
  hard gate），approval 决策与 command 内容**不新增任何磁盘记录**。
  日志边界见 Security 一节（§103/§104）。

**Approval request domain type（§61）**（10E-B1 实现，非本阶段）：

```swift
struct AgentCommandApprovalRequest: Equatable, Sendable {
    let generationID: UUID
    let callID: String
    let sessionID: UUID
    let targetKind: AgentTerminalSessionKind   // local / remoteSSH
    let targetDisplayName: String              // Local / host 显示名
    let displayCwd: String                     // OSC7 显示路径
    let canonicalCwd: String                   // 实际执行目录
    let command: String                        // exact bytes
}
```

Approval UI 不自行查询 active session；一切 target 信息来自 request。

---

## Local Executor

- API: **`posix_spawn`（Darwin）** + `POSIX_SPAWN_SETPGROUP`（`spawnattr_setpgroup(attr, 0)`
  —— spawn 原子成新进程组，无 after-fork setpgid race）+ `POSIX_SPAWN_CLOEXEC_DEFAULT`
  （防 fd 泄漏，与项目 `O_CLOEXEC` 先例同哲学）+
  `posix_spawn_file_actions_addchdir_np`（设 canonical cwd）+ 两根 pipe
  （stdout / stderr 分离）+ `waitpid`。**否决 Foundation Process**：无 process
  group 控制，`terminate()` 只 SIGTERM 直接 child（§26 现状已在
  `LocalTerminalService.terminate` 的 login/EPERM 事实中显现），无法满足
  SIGTERM-group → grace → SIGKILL-group 需求。
- shell: **账户 login shell（`LoginShellResolver.resolve()` = pw_shell，C 方案）
  以 `-c '<command>'` 执行**（非 login、非 interactive）。
- login shell: **NO**（不用 `-l`）。
- startup files（§20）: 非 login `-c` 模式下 zsh 仍读取 `/etc/zshenv` + `~/.zshenv`
  （bash 仅 `$BASH_ENV` 设置时）。**判定：接受**——命令本身经用户逐条审批、能力
  等同任意代码，startup files 未扩大权限边界；但要求：① 不使用 `-l`/`-i`（排除
  `.zprofile`/`.zshrc` 的 banner 输出污染 capture 与显著启动开销）；② 输出清洗层
  （§38）兜底控制字符。"与 Terminal 一致"不构成安全理由，本方案不依赖它。
  - 否决 B/D（`-lc`）：startup files 任意执行 + banner 污染 + 慢，唯一收益 PATH
    由显式 environment 取代（下）。
  - 否决 E（`/bin/sh -c`）：模型常产出 bash/zsh 语法，POSIX sh 兼容性差。
  - 否决 F（direct argv）：command 是 shell 字符串（管道/重定向/`&&`），必须 shell。
  - 否决 A（`/bin/zsh -c` 硬编码）：fish 等非 zsh 用户的语法语义与 Terminal 不一致。
- cwd: `posix_spawn_file_actions_addchdir_np(canonicalCwd)`；canonicalCwd 来自
  generation 冻结快照（§14/§16）。cwd 目录已不存在 → spawn 前置校验失败 →
  结构化错误（不 fallback）。
- environment（§21）: **显式 allowlist，绝不透传 `ProcessInfo.processInfo.environment`**：

  | 变量 | 值 | 理由 |
  |---|---|---|
  | `HOME` | generation 会话用户 HOME（`getpwuid_r`，复用 `LoginShellResolver.currentAccount()`） | `~` 展开、工具配置 |
  | `USER` / `LOGNAME` | 账户名 | 工具提示、脚本惯例 |
  | `SHELL` | 账户 shell 路径 | 子工具调用 `$SHELL` 时与 Terminal 一致 |
  | `PATH` | **App 固定值** `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` | 非 login shell 的 PATH 局限由显式值解决；**绝不继承 GUI App PATH**（IDE/调试变量不可进入子进程） |
  | `LANG` | `en_US.UTF-8` 固定值 | 确定性输出排序/解码；不透传 App locale |
  | `LC_*` | 不设置 | 与 Terminal 启动链一致（只设 LANG） |
  | `TMPDIR` | App 进程 darwin user temp dir（同用户同 boot 下与终端一致） | 脚本普遍需要 |
  | `TERM` | `dumb` | 明确非交互语义，抑制部分 pager/color |
  | 其他一切 | 不传递 | App/IDE 环境（含潜在 secret、CI/debug 变量）不得进入子进程 |
- stdin（§23）: **closed / EOF**——spawn 后立即关闭子进程侧 stdin（pipe 写端
  关闭 / `file_actions_addclose(0)`）。命令是 non-interactive；绝不复用 PTY stdin、
  绝不读取 terminal keystrokes。
- 等待输入的命令（§24）：stdin closed → `read` 立即 EOF；交互程序（vim/top/python
  REPL）因无 TTY 立即失败或退化；`sudo`/`ssh` 无密码来源 → 失败或 timeout 兜底。
  **timeout 是唯一兜底，不弹密码框**。
- sudo（§25）: 不特别支持。cached credential 时命令可能成功（自然行为）；否则
  `sudo: no tty present`（sudoers 默认 `requiretty` 可选）或 prompt 挂起 → timeout。
  Agent 绝不读取用户密码、不调用 Keychain、不模拟 Terminal 输入。
- process group（§27）: **YES，独立进程组**（spawn attr）。Stop/timeout 路径：
  `killpg(pgid, SIGTERM)` → **grace 5s** → 残留则 `killpg(pgid, SIGKILL)` →
  `waitpid` reap。比较结论：Foundation Process 无此能力；`setpgid` after fork 有
  race；`posix_spawnattr` 是 macOS-safe 唯一原子方案。
- child cleanup（§28）: 同组后台 job（`sleep 1000 &`）随 group SIGTERM/KILL 一并
  终止（**组内 guaranteed**）。**逃逸路径明确记录为 not guaranteed**：`nohup`/
  `setsid`/`disown` + 双重 fork 可使后代离开组（setsid 创建新会话）。无法在
  用户态完全封堵（进程可自我 escape）。**控制策略（冻结）**：① result/UX 不声称
  "所有进程已停止"；② threat model 列为残余风险；③ 不做 P2 blocker——因为
  该能力等价于用户在 Terminal 手动执行同样命令的后果，且整条 command 已被
  显式审批；④ Tool Card 完成文案为"命令已结束"，不做进程树存活承诺。
- cancellation（§94）: Stop → CancellationToken（复用 Swift Task 取消）→
  `killpg SIGTERM` → 5s grace → `killpg SIGKILL` → drain 双 pipe 至 EOF（防 pipe
  满阻塞子进程死前写入）→ close pipes → waitpid → result 标记 `cancelled: true`
  → **不继续 Provider continuation**（§110）。取消前已产生的部分 stdout/stderr
  保留在 Tool Card 详情（"partial output captured"），默认不外发（§111）。
- timeout（§29）: App 固定 default **60s**；hard max **600s**；模型不可指定。
  timeout 触发 = 同 cancellation（TERM→grace→KILL），result `timedOut: true`。

---

## Remote Executor

- existing SSHConnection: **YES**——origin session 现有已认证连接
  （`SessionManagerAgentRemoteServiceResolver` 同款寻址：`sessionID →
  connection != nil && phase == .connected`）。
- new connection / new login / new authentication: **NO**（禁止）。
- channel type: **第二 SSH session channel**（`libssh2_channel_open_ex("session")`，
  与 shell channel 相同打开原语、独立 channel 指针）+
  `libssh2_channel_process_startup(channel, "exec", 4, command, len)`。
  10E-B3 以 `SSHChannel.swift` 同一 extension 模式新增 actor 方法。
- PTY: **NO**（§44 确认）——不 requestPty、不 shell()。理由：non-interactive、
  确定性 capture（无 \r\n 转换 / 无回显）、不触碰当前 terminal state。
- actor serialization / channel ownership / gate：
  - 所有 libssh2 调用在 `SSHConnection` actor 内（既有不变式）；
  - exec channel 指针**独立登记**（不占用 `shellChannel` 槽位）：新增
    `commandExecChannel: OpaquePointer?` + `commandExecCloseTask` 在途关闭槽位
    （镜像 shellChannelCloseTask 模式），在途打开用局部去重（单 generation
    串行语义下并发打开不存在，但登记防 disconnect 交错）；
  - **不进入** `acquireSFTPOperationGate`（SFTP 门保护 `LIBSSH2_SFTP` 子系统共享
    状态，exec channel 无该状态；协议层多 channel 并存由 libssh2/session 保证，
    PTY+SFTP+exec 三并存成立，§60）；
  - 与 shell channel 读循环的穿插：exec 读写等待期间 actor 挂起，terminal
    读循环可安全穿插（EAGAIN poll 模式既有保证）；exec 打开窗口期与 shell channel
    打开窗口期互不约束（不同 channel）；
  - disconnect 交互：`disconnect()` 增加对 exec channel 的关闭循环（镜像
    `closeAllShellChannelsForTeardown`），保证 teardown 返回 = 全 channel 释放。
- cwd wrapper（§46/§47）: SSH exec 协议无 cwd 参数；服务器在登录默认目录启动
  exec。wrapper 冻结：

  ```text
  cd '<quoted-canonical-cwd>' && <model-command>
  ```

  - cwd 唯一来源 = generation 冻结 canonical remote cwd（SFTP realpath 结果），
    **绝不由模型提供**；
  - `&&` 保证 cd 失败（目录不存在/权限）时命令**不在错误目录执行**，exit code
    为 cd 的非零值、stderr 含 shell 诊断——模型可解释，不特殊分类；
  - wrapper 是内部实现：**UI 审批卡显示原始 model command**（§49），不把 wrapper
    冒充模型命令；displayCwd 单独显示。
- quoting（§48）: **POSIX single-quote escaping**（唯一算法，冻结）：
  `'` → `'\''`，整体包 `'...'`。该算法对 space / `"` / `$` / `` ` `` / `\` /
  Unicode / `?` / `#` / `%` / newline 全部安全（单引号内除 `'` 外无特殊字符）。
  cwd 可能含 `'`（理论）→ 算法覆盖。仅 App 拼接的 cwd 需要 escape（§83）：
  **用户/模型 command 本身就是要执行的 payload，绝不 escape**——区别
  "intentional shell interpretation"（模型命令）与 "cwd/path wrapper injection"
  （App 拼接部分必须安全）。
- No host string in command（§84）: wrapper 只含 canonical cwd + model command；
  host/display label 绝不进入 shell 字符串。
- stdin（§45）: **EOF**——exec channel 打开后不写任何数据，
  `libssh2_channel_send_eof(channel)` 显式关闭写侧。绝不转发用户 Terminal
  keyboard 输入。
- stdout: `libssh2_channel_read_ex(channel, 0, ...)`（stream 0）。
- stderr（§52）: `libssh2_channel_read_stderr`（stream 1 = SSH_EXTENDED_DATA_STDERR，
  vendored libssh2.h L906–908）。**双流并发 drain**（同一 actor 内交替读两流，
  EAGAIN 时 `waitForLibssh2Readiness`）——无 PTY exec 模式下服务器不合并 stderr，
  单读 stream 0 会在 stderr 大量输出时撑满 channel 窗口造成 stall（§31 同款
  deadlock 概念的远程形态）。
- exit status（§51）: EOF + close 后 `libssh2_channel_get_exit_status(channel)`
  （32-bit exit code）；`libssh2_channel_get_exit_signal` 取 exit signal（可选，
  失败容忍）。Result 字段与 Local 统一：`stdout/stderr/exitCode/terminationSignal/
  timedOut/cancelled/...`。
- cancellation（§54/§55/§95）:
  1. 停止读循环；
  2. **best-effort 远端终止**：`libssh2_channel_signal_ex(channel, "TERM")`
     （vendored 1.11.2_DEV 支持 API；**注意**：无 PTY exec channel 的 signal
     request 需要 OpenSSH ≥7.9 的 sigreq 扩展，非 OpenSSH / 旧服务器不支持——
     因此只能承诺 best-effort）；
  3. `closeShellChannel` 同款优雅链：`send_eof` → `close` → `wait_closed` →
     `free`（各自 budget）；
  4. **明确冻结事实：关闭 exec channel 不保证杀死远端进程**。channel 关闭后
     sshd 关闭其管道，前台 command 通常因 stdout/stderr 写入 EIO/SIGPIPE 退出，
     但 detached 后代与忽略信号者可存活。Stop ≠ 远端所有进程已停止（§56）——
     UX 文案与文档如实表达；测试策略含"PTY 与 SFTP 在 exec 关闭后仍可用"
     （§106）。
- process kill guarantee: **best-effort（signal_ex 有服务器支持前提）/ channel
  清理 guaranteed / 远端后代清理 not guaranteed**（§56/§57 记录在 result 语义与
  UX 中）。
- channel cleanup: guaranteed（`free` EAGAIN 重试 + disconnect 关闭循环 +
  `libssh2_session_free` 最终兜底回收，内存安全）。
- PTY coexistence: YES——独立 channel，shell channel 状态不受影响
  （`closeShellChannel` 语义边界不触碰 exec channel；exec close 也不触碰
  shellChannel，§59）。
- SFTP coexistence: YES（§60，不进 SFTP 门）。
- executor 错误隔离（§58）: exec channel 打开失败 / 读写失败 →
  结构化 command error（`executorUnavailable` / `sessionUnavailable`），**绝不**
  调用 `disconnect()`、绝不关闭 shell channel / SFTP / 整条连接；只有底层
  `libssh2_session_last_errno` 指示连接级失效（如 SOCKET_NONE /
  connectionLost）才如实上报连接状态（由既有读取循环路径处理）。command channel
  failure 正常情况与交互会话隔离。

---

## Limits

| 项 | 冻结值 | 理由 |
|---|---|---|
| max command UTF-8 bytes | **16 KiB（16,384）** | 远超合理 shell 命令（模型典型 <1 KiB）；防巨型 tool arguments / UI freeze / SSH exec request 过大 / Provider abuse；64 KiB 过宽。超限 → `invalidArguments` |
| default timeout | **60 s** | 覆盖构建/查询类命令常态；Stop 仍是主取消手段 |
| max timeout | **600 s**（hard max，模型不可指定；App 内部上限） | 防无限运行；无 UI 调节则固定 60s 也可，600s 是内部硬顶 |
| stdout cap | **256 KiB** | 与 `AgentTextLimits.fileReadMaxBytes` / `terminalTextualPayloadMaxBytes`（AgentUTF8Truncator.swift L22/L24）一致 |
| stderr cap | **256 KiB** | 同上 |
| total Provider result | ≤ **512 KiB** + JSON 包装（`ok/exit_code/...` 结构 ~1 KiB 级） | 单流 256 KiB 先例 × 2；不引入第三档量级 |
| termination grace period | **5 s**（SIGTERM → SIGKILL） | shell 与常规子进程退出余量；不长到拖垮 Stop 响应 |

Cap 语义（§32/§33）：达到 cap 后**继续 drain、停止保存**（字节计数继续累加用于
truncated 标记），**绝不停止读取 pipe**（否则 child 因 pipe 满阻塞）。
stdout 与 stderr 各自独立计数，互不挤占。

---

## Output Model

- stdout / stderr: 分离捕获、分离 cap、分离 truncated 标记（§30——不合并为一段
  不可区分文本）。
- UTF-8（§37）: **lossy-decode-on-boundary + 严格校验混合策略**（10D 既有先例
  组合）：字节层取 ≤ cap 的最大合法 UTF-8 前缀（`AgentUTF8Truncator.utf8PrefixBoundary`），
  严格解码（`decodeStrictUTF8`）；**非法 UTF-8 不再走 `binaryUnsupported` 硬失败**
  （与 read_file 不同：命令输出天然可能混入局部二进制/非 UTF-8 locale 字节，
  硬失败会让模型无法理解命令结果）→ 非法字节以 U+FFFD 替换 + `nonUTF8Detected`
  元数据标记。locale-aware decoding 不做（App 无法得知远端/子进程 locale 语义）。
- binary / NUL（§39）: 检测到 NUL 字节（\0）→ 输出标记 `binaryOutput: true`，
  文本内容截断到首个 NUL 前的安全前缀（替换标注），**绝不 Base64 / hex dump
  整个二进制**（10D `binaryUnsupported` 精神：不给模型二进制载荷）。
- ANSI / control（§38）: Command Result 不是 Terminal emulator。发送 Provider /
  展示 UI 前执行 **ANSI/CSI/OSC/DCS strip + C0/C1 控制字符过滤**（保留 `\n`）。
  理由：OSC title / cursor control 可污染 Tool Card 渲染语义；strip 是确定性
  字节过滤（开源常见状态机，10E-B2 实现并测试），不做 escape 重解释。
  ⚠️ strip 不能恢复"被 ANSI 包裹的语义"，属于 UX 卫生而非安全边界（安全边界
  是审批）。
- exit code（§35）: `exit 0` → `ok:true, executed`；非零 → **commandFailed**
  （仍是 valid command result，`ok:true` + `exit_code` 语义分层见 §75/§36，
  绝不与 infrastructure failure 混淆）。
- signal: `terminationSignal`（SIGKILL/SIGTERM 被信号杀死时）。
- timeout / cancelled / truncated / duration: 显式字段（§34）。
- command result model（§34，10E-B1 实现，命名随项目风格）：

```swift
struct AgentCommandResult: Sendable, Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32?
    let terminationSignal: Int32?
    let timedOut: Bool
    let cancelled: Bool
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let binaryOutputDetected: Bool
    let nonUTF8Detected: Bool
    let duration: Duration
}
```

- Provider 序列化（§75）：

```json
{
  "ok": true,
  "executed": true,
  "exit_code": 0,
  "stdout": "...",
  "stderr": "...",
  "stdout_truncated": false,
  "stderr_truncated": false,
  "timed_out": false
}
```

  Infrastructure failure 独立形态：`{"ok": false, "error": "userDenied" /
  "executorUnavailable" / "sessionUnavailable" / "cwdUnavailable" /
  "invalidArguments" / "cancelled"}`（复用 `AgentToolResultSerializer` 语义；
  **不暴露 raw NSError / libssh2 码 / 指针 / fd / PID / Keychain 错误 / stack
  trace**——§76，Serializer 既有规范）。

---

## State Semantics

- interactive cwd changed: **NO**（§4/§73/§74——独立环境）。
- interactive env changed: **NO**。
- aliases/functions persist: **NO**。
- sequential command state: **每条 run_command 全新执行上下文 + 同一 frozen
  generation cwd**（§74）；`cd subdir && make` 必须在同一次 command 中表达，
  并由用户整体审批。
- Local/Remote parity: 尽量对齐（字段/limits/清洗/serializer 共享），但**不虚假
  承诺跨端 shell 一致**（§50）：Local = 账户 shell `-c`（zsh 等）；Remote =
  服务器 login shell 执行 exec request（通常 `$SHELL -c`，由 sshd 决定）。
  语法差异（如服务器是 dash/bash 而 Local 是 zsh）是现实，system instruction
  与文档如实说明。

---

## Security

- credential exposure（§22）: **Hard invariant——provider API key / SSH password /
  passphrase 绝不进入 command environment / stdin / arguments / working files**。
  - Local executor 的 environment 是封闭 allowlist（构造函数不接触
    `AgentCredentialService`）；provider snapshot 停留在 AgentViewModel/provider
    层，executor 无引用路径；
  - SSH 凭据仅在 `SSHConnection` 认证瞬间使用并清零（SSHConnection.swift
    L821–824/L930–932 zeroSecretBytes），exec executor 不触碰；
  - Remote exec 不携带任何 secret（认证由既有连接承载）。
- environment secrets（§21）: allowlist 逐项已述；`ProcessInfo.processInfo.environment`
  全量透传禁止。
- arbitrary filesystem: 存在（§81）——approval 是唯一边界；报告不虚假声称
  readScope containment。
- arbitrary network（§79/§80）: 存在；审批模型按 "arbitrary command capability"
  对待。
- prompt injection（§40）: command output 是 untrusted external content；只以
  `function_call_output` 进入 transcript（10D `inputItems` 既有形态），
  绝不升格为 system/developer message。
- command injection（§83）: 模型 command = intentional payload，不 escape；
  App 拼接部分（remote cwd wrapper）用 single-quote 算法 escape（算法冻结）。
- cwd injection: cwd 只来自冻结 authoritative 快照（模型无法提供 cwd 字段，
  schema 无此参数）。
- logging（§103）: 内部日志允许 `tool=run_command, status, duration, exitCode,
  output byte counts`；**禁止默认记录 full command / stdout / stderr / cwd 绝对
  路径 / 任何凭据**（AppLogger 既有 privacy 分级惯例）。
- persistence（§102/§104）: 无磁盘 command history / analytics。Tool Card 是
  用户审计面，显示 exact command；与"不进系统日志"不矛盾。
- sensitive output（§113）: `cat ~/.ssh/id_rsa` 在架构上**允许发生**（用户批准
  arbitrary command 的后果）——这正是 per-call approval 是核心边界的原因。
  **不依赖字符串 denylist 作为安全机制**（与 §9 同理）；可选 UX 提示（10F）
  不改变信任模型。
- system instruction（§114/§115，10E-B4 实施）: 告知模型 run_command isolated /
  不改变交互终端状态 / 需要审批 / stdin 不可用 / Remote 使用独立 exec channel，
  防止 `cd/export` 持久化幻觉。
- send_to_terminal（§116/§118）: **继续禁止**；需要 TTY 的命令不自动转
  send_to_terminal；未来可显示"该命令需要交互式终端；请在 Terminal 中手动运行"。

---

## Cancellation Matrix

| Scenario | Local | Remote | Guarantee |
|---|---|---|---|
| Stop before execution（approval 前后、spawn 前） | 不 spawn；card → cancelled；structured cancelled output | 不打开 channel；同左 | **guaranteed** |
| Stop during command | killpg SIGTERM → 5s grace → killpg SIGKILL → waitpid → drain pipes → cancelled；不续 provider | stop 读循环 → best-effort signal_ex("TERM") → 优雅链关闭 channel → cancelled；不续 provider | Local 进程组 **guaranteed**；Remote channel 清理 **guaranteed**，远端进程终止 **best-effort** |
| Timeout | 同 Stop during（`timedOut: true`） | 同左 | 同上 |
| Session close（origin tab 关闭） | `pruneConversations` 已取消 generation → 同 Stop during；conversation 移除 | exec channel 随 disconnect 链清理（teardown 顺序：transfers → sftp → remote → connection，新增 exec 清理步）；绝不 fallback active session | **guaranteed**（App 层）；远端进程存活同上 |
| App quit（graceful） | 退出路径 best-effort：对在途 command 进程组 SIGTERM（不等待） | TCP 关闭 → sshd 向 command 发 SIGHUP / pipe EOF → 前台命令通常退出 | Local **best-effort**（强杀/崩溃 not guaranteed）；Remote **best-effort** |
| App quit（force kill / crash） | 子进程被 launchd 收养，**存活**（无 watchdog 机制；记为已知限制） | 连接断开，同上 | **not guaranteed**（如实披露） |
| Background child（`sleep 1000 &`） | 同进程组 → 随 group kill 终止；**setsid/nohup 双重 fork 逃逸组 → not guaranteed**（控制策略见 Local Executor §28） | channel 关闭后**存活**（not guaranteed） | Local 组内 guaranteed / 逃逸 not guaranteed；Remote **not guaranteed** |
| Connection loss（Remote） | N/A | 读/写错误 → 结构化 `connectionLost/sessionUnavailable`；channel cleanup guaranteed；远端进程 best-effort；不自动断开交互会话 | channel **guaranteed**；进程 **not guaranteed** |

---

## Threat Model

- malicious model command: per-call 审批 + exact command 可见 + 无持久授权 =
  主要缓解；残余风险 = 用户批准恶意命令（与手动执行等价，产品的信任模型如此）。
- prompt injection causing command: 输出为 untrusted content，只经
  `function_call_output` 回放；审批 UI 显示触发该命令的上下文卡片，用户是
  最后一道闸。
- command reads secrets: 技术上可行（§113）；approval + 输出外发披露文案缓解
  （用户知道输出会发给 provider）；无 denylist 依赖。
- command deletes data: 同上（审批模型）；`rm` 类 UX warning 属 10F best-effort。
- command makes network request: 无网络沙箱；审批卡固定披露 "arbitrary command"。
- command forks background child: Local 组内可清；逃逸与 Remote 后代为
  documented residual risk（Cancellation Matrix）。
- command emits huge output: 256 KiB × 2 cap + drain-not-store + truncated 标记。
- command outputs terminal escape codes: ANSI/control strip（UX 卫生）。
- command waits for stdin: stdin closed + timeout 60s 兜底；不弹密码框。
- command targets wrong session: sessionID 全链 hard gate（Router 同款
  mismatch 检查平移到 approval/executor）；绝不 fallback active。
- stale approval: 六元组绑定校验（generationID/callID/sessionID/command/cwd/
  provider snapshot）；Stop/session close/provider switch 场景全部失效。
- double approval: MainActor 同步段状态 CAS + 按钮禁用。
- cancel race（Stop 与 spawn 竞态）: spawn 前最后 checkCancellation；
  spawn 与 kill 竞态由 waitpid/killpg 对已死 pid 的 ESRCH 容忍覆盖。
- Remote channel leak: 登记槽位 + disconnect 关闭循环 + session free 兜底
  （镜像 shell channel 三层模式）。
- Remote process survives disconnect: documented not-guaranteed（§56）。

---

## Testing Strategy

### Local

`echo` / `pwd`（cwd 冻结与 canonical） / stdout / stderr / non-zero exit /
large stdout（>256 KiB，drain 不死锁 + truncated 标记）/ large stderr（同）/
stdout+stderr simultaneous（无 deadlock）/ timeout（60s 缩短为测试注入值）/
cancel（Stop 窗口：spawn 前/执行中/grace 中）/ child process（shell 派生子进程随
group kill）/ background child（组内清除；setsid 逃逸行为记录断言不误报）/
Unicode 输出与 Unicode cwd / ANSI 输出（strip 断言）/ invalid UTF-8（replacement
+ 标记）/ empty command / NUL in command / long command（>16 KiB → invalidArguments）/
cwd spaces / cwd Unicode / session A/B isolation（A 的 generation 不受 B cd 影响）/
environment allowlist（断言 IDE 注入变量不出现）/ stdin closed（`read` 立即 EOF）。

### Remote

stdout / stderr（双流并发）/ exit 0 / exit non-zero / cwd wrapper（frozen cwd
生效；cd 失败 → 非零 + stderr 诊断）/ Unicode cwd（quoting 算法 property 测试：
含 `'`/空格/`$`/换行）/ large output / timeout / cancel（channel 关闭 + cancelled
result）/ disconnect during exec（连接丢失隔离，不断开交互会话）/ channel cleanup
（无泄漏：open/close 计数模式复用 SSHConnection 测试仪表）/ **PTY remains
responsive（exec 生命周期内交互 shell 输入输出不受阻）** / **SFTP remains usable** /
A/B Remote isolation / no new authentication（断言无第二 handshake/认证调用）。
真实 SSH 聚焦用例遵循 10D-B3 先例（缺已授权密钥环境时 skip，不挂死）。

### Approval

approve executes once / deny executes zero times（`userDenied` output）/ Stop
before approve（pending 失效）/ Stop after approve before spawn（不执行）/
session close while waiting / generation replaced（旧决策丢弃）/ double-click
approve（单次执行）/ late approve（旧卡不可执行）/ provider switch during
awaiting（old snapshot 续）/ A/B tab switch（target 不漂移）/ multiple command
calls in one response（serial）/ mixed read + command calls（output order）/
dup call_id（第二次不产生审批/执行）/ output disclosure 文案存在性。

### Provider / Agent Loop

run_command 作为第 5 工具的请求体门（catalog 恰 5 项；prohibitedNames 调整后
gate 仍完整）/ transcript 回放：`function_call`（name=run_command, arguments=
`{"command":...}`）+ `function_call_output`（bounded JSON）/ userDenied 与
infrastructure error 形态 / 10-round cap 与 approval 等待不计数 / Stop hard gate
四窗口不回归 / DeepSeek reasoning 前移规则不受新工具影响 / no raw internal errors
（serializer 断言）。

---

## Phase Breakdown

#### 10E-B1 — Command Domain + Approval State Machine Foundation
（无任何执行）
- `AgentCommandRequest` / `AgentCommandResult` / `AgentCommandApprovalRequest`
  domain 类型；`AgentToolName.runCommand` case + `AgentToolRisk.commandExecution`
  独立风险类别 + `AgentToolCatalog` 第 5 定义（**尚未**接 provider——保持
  definitions 仍 4 项或以编译门隔离，B4 才接通）；`AgentToolCallParsing` 扩展
  `command` typed 参数与三条输入校验（empty/NUL/长度）；`AgentToolActivity.Status`
  扩展 `awaitingApproval`；审批状态机（CAS 转移 + 六元组绑定校验）+ 单元测试。
- limiter 常量集中（对齐 `AgentTextLimits` 惯例）。

#### 10E-B2 — Local Independent Executor
- posix_spawn（setpgroup/cloexec/addchdir_np）+ allowlist environment + 双 pipe
  concurrent drain + cap/drain-not-store + timeout/cancel（killpg 链）+ waitpid
  + 输出清洗（ANSI strip / NUL / UTF-8 边界）+ `AgentCommandResult` 组装；
  全部 Local 测试项。

#### 10E-B3 — Remote SSH Exec Executor
- `SSHConnection` extension：exec channel 打开（无 PTY）/ stdin EOF / 双流
  drain / exit status / signal_ex best-effort / 优雅关闭与登记槽位 /
  disconnect 关闭循环接入 / cwd wrapper + quoting / 与 SFTP 门及 shell channel
  的隔离测试。

#### 10E-B4 — Provider run_command Wiring + Approval UI + Live Acceptance
- `AgentToolCatalog.definitions` 接入第 5 工具 + `prohibitedNames` 移除
  `"run_command"`（gate 语义不变）+ system instruction（§114/§115 文案）+
  `AgentViewModel` loop 的 approval 挂起/恢复接线 + `AgentToolCardView` 的
  `awaitingApproval` UI（exact command / target / cwd / 披露文案 / Approve/Reject/
  防双击）+ live acceptance（真实 provider 全链）。

#### 10E-C — Commit Verification
#### 10E-P — Feature/main Integration
- 与 10D-C/P/M/I/I-P 同款 gate 序列（本报告不预支细节）。

顺序调整说明：无调整——与任务书 §119 建议一致；唯一补充是 B1 内需先落
`prohibitedNames` 与 Catalog 的**编译期隔离策略**（避免 B1 阶段 provider 意外
看到第 5 工具）。

---

## Branch Recommendation

- branch: `feature/macssh-1.1-agent-command-execution`（从 `main` = `73038d6` 创建）
- create now: **NO**（等待本架构验收后由用户授权）。

---

## Frozen Decisions

1. `run_command` ≠ `send_to_terminal`：永远是两条不同能力；10E 不实现
   send_to_terminal，不合并路径。
2. 不使用当前 Terminal PTY 作为 executor（Local 独立子进程；Remote 第二 exec
   channel）。
3. `AgentReadScope` 对 run_command 不是沙箱：cwd containment ≠ command sandbox；
   approval 是唯一安全边界；scope 仅用于 cwd 权威性判定。
4. run_command ALWAYS requires explicit per-call approval；无持久授权；无
   read-only 自动执行；字符串 classifier 永远只是 UX hint，绝不 permission bypass。
5. Provider 不可绕过审批：loop 收到 run_command 必须 suspend 等待决策。
6. Schema 最小化：唯一模型参数 `command`；cwd/shell/environment/stdin/timeout/
   output limits 全部 App 决定。
7. cwd = generation 冻结 authoritative（OSC7）快照；approximate/unavailable →
   `cwdUnavailable`，绝不 fallback HOME/login default/App cwd/`realpath(".")`；
   Local 用 canonical cwd 执行、display cwd 展示（两者都保存）。
8. Local executor = posix_spawn + POSIX_SPAWN_SETPGROUP（独立进程组）+
   CLOEXEC_DEFAULT + addchdir_np + 双 pipe 并发 drain + waitpid；否决
   Foundation Process（无进程组）。
9. Local shell = 账户 shell（pw_shell）`-c`（非 login 非 interactive）；显式
   environment allowlist（HOME/USER/LOGNAME/SHELL/固定 PATH/LANG/TMPDIR/TERM=dumb）；
   绝不透传 GUI App 环境。
10. Local stdin closed；无交互支持；sudo 无特殊处理；timeout（60s default /
    600s hard max）+ Stop 为兜底，不弹密码框。
11. Output：stdout/stderr 分离各 256 KiB cap（继续 drain 停止保存）；UTF-8 边界
    前缀 + 非法字节替换标记；NUL → binaryOutput 标记不 Base64；ANSI/C0/C1 strip；
    exit 非零 = commandFailed（valid result）；infrastructure 错误结构化分离；
    绝不外泄 raw NSError/libssh2/PID/fd/凭据。
12. command 长度上限 16 KiB UTF-8 bytes；empty/whitespace/NUL → invalidArguments；
    多行允许但审批卡完整显示。
13. Remote exec 复用同一已认证 SSHConnection 的第二 session channel（无 PTY、
    stdin EOF、双流 drain、`get_exit_status`）；绝不新登录/新认证/新 TCP。
14. Remote cwd wrapper = `cd '<single-quoted canonical cwd>' && <model command>`；
    cwd 只来自冻结 authoritative 快照；host 字符串绝不进入 shell；
    审批显示原始 model command。
15. Remote 取消 = best-effort `signal_ex("TERM")` + 优雅 channel 关闭链；
    **channel 清理 guaranteed、远端进程终止 best-effort、后代存活 not
    guaranteed**——如实披露，不假装 Stop = 远端全停。
16. Command exec failure 隔离：绝不自动断开交互 SSH 会话 / 不关闭 PTY / 不关闭
    SFTP；只在上报真实连接级失效时收敛。
17. Approval 绑定（generationID, callID, sessionID, command bytes, cwd, provider
    snapshot）六元组；Stop/session close/generation replace/provider switch 使
    stale approval 失效；决策不进入自然语言 transcript，仅
    `function_call_output`（denied → `userDenied`）。
18. 多命令 serial（provider output order）；mixed read+command 保持 output
    order；approval 等待不消耗 tool round（维持 10 上限）。
19. AgentToolRouter 保持 read-only dispatch；command dispatch 走独立
    approval-boundary + executor 层；capability boundary 以编译期路径分离。
20. `AgentToolRisk.commandExecution` 独立风险类别（不并入 modifying）。
21. `prohibitedNames` 现含 `"run_command"`——B4 接入时移除该字面并加入 allowlist
    （gate 本身保留）。
22. 无磁盘 command history / 无命令内容进默认日志；Tool Card 是用户审计面。
23. Limits 冻结：command ≤ 16 KiB；timeout 60s/600s；stdout/stderr 各 256 KiB；
    provider result ≤ 512 KiB；termination grace 5s。
24. App 无 Sandbox（entitlements 空、ENABLE_APP_SANDBOX=NO）——不假设子进程有
    文件系统沙箱；Hardened Runtime 不构成命令执行限制。
25. 现有 SSHChannel 无 exec/exit-status/stderr 实现；libssh2 1.11.2_DEV 提供
    全部所需 C API——10E-B3 为全新 extension 代码。

---

## Open Questions

- Remote `libssh2_channel_signal_ex` 的服务器支持率（OpenSSH ≥7.9 sigreq）：
  B3 live 阶段对目标服务器实测并记录；不影响架构（best-effort 已冻结）。
- Local executor 的 drain I/O 实现选型（DispatchIO vs 专用线程 vs kqueue）：
  B2 实现细节，要求仅有"双流并发 drain + 取消后 drain 至 EOF"。
- ANSI strip 状态机的精确字符集（C1 0x80–0x9F 在 UTF-8 解码后的处理）：
  B2 实现时随测试冻结。
- Approval UI 的视觉稿：按 AGENTS.md 规则，改 UI 前需先出预览图征求确认
  （B4 前置步骤）。
- 未来是否向模型开放 bounded timeout 参数：10F permission framework 议题，
  本阶段明确不开放。

---

## Files

- modified: 无
- added: 无（本报告除外）
- report: `Docs/Phase10E-A-Controlled-Command-Execution-Architecture.md`（untracked，不 stage）

---

## Findings

#### P1
- count: 0
- items: 无

#### P2
- count: 0
- items: 无

#### P3
- count: 3
- items:
  1. Local 后台进程经 setsid/nohup 逃逸进程组、Remote exec channel 关闭后远端
     后代进程可存活——平台现实限制，已通过 Cancellation Matrix "not guaranteed"
     行、UX 文案要求与测试断言明确披露/围栏（任务书 §129 归类 P3：清楚披露的
     平台限制）。
  2. Remote `signal_ex("TERM")` 依赖服务器 sigreq 扩展（OpenSSH ≥7.9），
     支持率待 B3 live 实测（已列为 best-effort + Open Question）。
  3. Approval UI 视觉细节（折叠/滚动布局、披露文案排版）留待 B4 前预览图确认
     （AGENTS.md UI 规则），非架构问题。

---

## Decision

```text
PASS — ARCHITECTURE FROZEN — 0 P1 / 0 P2
```

PHASE 10E-A ARCHITECTURE PASS

Controlled Command Execution architecture is frozen.

Command execution is STILL NOT IMPLEMENTED.

AUTHORIZED NEXT:
Phase 10E-B1 — Command Domain + Approval State Machine Foundation

DO NOT IMPLEMENT Local Process execution yet.
DO NOT IMPLEMENT Remote SSH exec yet.
DO NOT REGISTER run_command with Provider yet.

send_to_terminal remains prohibited.
All file mutation tools remain prohibited.

No commit / push / merge / tag.

STOP.
