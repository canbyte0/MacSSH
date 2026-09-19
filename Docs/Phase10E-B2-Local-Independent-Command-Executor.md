# Phase 10E-B2 — Local Independent Command Executor

实现报告。本阶段实现 **Local Independent Command Executor**：已审批的一次性
authorization → redeem → 独立 Local child process（`posix_spawn`）→ 账户 shell
`-c` → 双流 bounded 输出 → exit / timeout / cancellation result。

**只作为独立 executor foundation 存在**：不接入 Provider / Agent tool registry /
AgentViewModel production loop / 真实 Approval UI / Terminal PTY / Remote SSH。
报告 untracked，不 stage。

---

## Repository

- path: `/Users/msl/msl_coding/MacSSH`
- branch: `feature/macssh-1.1-agent-command-execution`（进入前已确认，§3）
- HEAD: `73038d61b9f2b22b027e3748d06600984186a29a`（未移动；B1 起即此 candidate base）
- baseline: `main` @ `73038d6` / tree `53f3cd0`；test-universe baseline
  `961 / 960 / 835 / 125 / 0 / 1`
- B1 candidate present: YES（5 production + 5 tests + `project.pbxproj` +
  4 tracked 修改 + 8 untracked Docs；**未 commit、未 stage**）
- status before: 19 行（5 ` M` + 14 `??`：8 Docs + `MacSSH/Services/Agent/Command/`
  + 5 B1 测试文件）→ 快照 `/tmp/macssh-phase10e-b2-status-before.txt`
- staged before: 0（`/tmp/macssh-phase10e-b2-cached-before.patch` = 0 行）
- diff before: `/tmp/macssh-phase10e-b2-diff-before.patch`（267 行 = B1 candidate）
- commit: NO
- push: NO
- 新增无法解释的用户修改: 无（§3 STOP 条件未触发）

## Authorization Boundary

- executor raw request API: **不存在**（唯一入口
  `execute(authorization:approvalCoordinator:)`；无任何以裸 request 为参数的形参）
- raw command API: **不存在**（无 `execute(command:)` / 以命令字符串为参数的入口；
  静态 gate 断言 Execution 层不含 `execute(command` / `execute(request` /
  `run(command` / `spawn(command` / `func run(_ command`）
- authorization required: YES——`AgentCommandExecutionAuthorization` 是唯一执行凭证
- coordinator redeem: **executor 内部完成**（caller 不能自行 redeem 后传入 request；
  redeem 返回 coordinator 保存的 immutable request，执行参数全部取自该值）
- redeem timing: 固定顺序（§9）——authorization → target validation →
  Task cancellation check → redeem → final cancellation check →
  shell/cwd 校验 → posix_spawn（spawn 恒在 redeem 之后）
- forged authorization: `.authorizationRejected(.approvalStale)`，**零 spawn**；
  §53 强 side-effect 证明（`touch <tmp>/should-not-exist` 未创建）
- replay: 同一 authorization 第二次执行 → `.authorizationRejected(.approvalAlreadyClaimed)`，
  第二次调用零 side effect（§104；即使 caller 保存/复制 struct）
- duplicate execution: 恰一次（§54：marker 文件只被创建一次）
- 跨 ledger（另一 coordinator 实例）→ `.authorizationRejected(.approvalStale)`，
  零 spawn（B1 冻结语义：redeem 不认识该 approvalID 时抛 `approvalStale`）
- pre-redeem 中止（Task 已取消）→ authorization **不消费**（仍
  `executionClaimed` / `redeemed == false`，测试断言）；post-redeem 中止即消费
  （单次消费语义，无重放窗口）

## Local Spawn

- implementation: `AgentLocalCommandProcess`（同步单线程 poll 事件循环核心）
- Process/NSTask: **0**（Execution 层静态 gate 含 token 断言）
- posix_spawn: YES（`posix_spawn(` 出现且仅出现在
  `AgentLocalCommandProcess.swift`；全生产代码无 `posix_spawnp`）
- spawn flags: `POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT |
  POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK`
  - 前两项 = 10E-A 冻结项；后两项为**支撑性补充**（见 Findings P3-1：实测
    GUI App 继承的 signal disposition/mask 进入子进程会让冻结的 SIGTERM 链失效）
- process group: `posix_spawnattr_setpgroup(&attr, 0)` → 实测 **child PGID == child PID**
  （子进程内 `ps -o pgid= -p $$` 证据：`PID=93508 PGID=93508`、`PID=87001 PGID=87001`；
  测试 `testChildRunsInItsOwnProcessGroup` 断言）
- CLOEXEC: `POSIX_SPAWN_CLOEXEC_DEFAULT` + 显式 `addclose` 四个父进程侧 fd
  （stdout/stderr 的 read+write 端）→ 子进程只保留 0/1/2；
  canary 高位 fd（≥30）测试证明父进程 fd **不泄漏**
- cwd mechanism: `posix_spawn_file_actions_addchdir_np`（macOS 14 部署目标可用；
  输入 = kernel 语义 canonical 后的 approved cwd，绝不重读 session cwd）
- shell: `LoginShellResolver.resolve()`（本机 = `/bin/zsh`，即 pw_shell）
- argv: `[/bin/zsh, "-c", <approved command 原文>]`（`$0` 探针实测 `/bin/zsh`；
  `ps -o args=` 首个 token = shell path，第二 token = `-c`）
- login: **无**（argv token 断言无 `-l` / `--login`；zsh 探针 `login=no`）
- interactive: **无**（argv 无 `-i`；zsh 探针 `interactive=no`）
- PTY: **无**（`forkpty` / `openpty` / PTY API = 0；fd 0/1/2 `test -t` 全 false）

## Environment

- allowlist（键集合恒定，其余一律不存在）:
  `HOME` / `USER` / `LOGNAME` / `SHELL`（`getpwuid_r` 账户信息）、
  `PATH`（App 固定值 `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`）、
  `LANG`（`en_US.UTF-8` 固定）、`TERM`（`dumb` 固定）、
  `TMPDIR`（`confstr(_CS_DARWIN_USER_TEMP_DIR)`，不读继承环境）
- full environment inherited: **NO**（不读取 `ProcessInfo.processInfo.environment`）
- HOME: 账户 pw_dir（`getpwuid_r`）
- USER / LOGNAME: 账户 pw_name
- SHELL: 账户 pw_shell
- PATH: 固定值（绝不继承 GUI App PATH）
- locale: 仅 `LANG=en_US.UTF-8`；未设置任何 `LC_*`
- SSH_AUTH_SOCK: **未透传**（不在 allowlist，capability 不扩大）
- provider credentials: **不进入** child env / argv / stdin / 临时文件 / 日志
- test secret leakage: 0——5 个 fake 变量（FAKE_OPENAI_API_KEY /
  FAKE_DEEPSEEK_SECRET / GITHUB_TOKEN / MACSSH_B2_CUSTOM_SECRET / SAFE_ALLOWED_VAR）
  与 4 个 provider 风格凭据（OPENAI_API_KEY / DEEPSEEK_API_KEY /
  AWS_SECRET_ACCESS_KEY / GITHUB_TOKEN）在 `env` + `ps -ww -o args=` 输出中
  键与值均不出现

## stdin

- source: `/dev/null`（`posix_spawn_file_actions_addopen(0, "/dev/null", O_RDONLY)`）
- EOF: 立即可得（`cat` 测试：`cat; echo "cat-exit=$?"` → `cat-exit=0`，无等待）
- terminal input dependency: **无**（绝不连接 Terminal stdin / 键盘 / PTY）
- tty: `isatty(0/1/2)` 全 false（shell 探针 `notty=0/notty=1/notty=2`）

## stdout / stderr

- separate: YES（两根独立 pipe，底层**绝不合并**；分离测试 stdout/stderr 各自保真）
- concurrent drain: 单一 poll 事件循环同时服务两流（任一 pipe 有数据即读，另一
  pipe 绝不以阻塞等待拖住本流）；§64 hard test（两流同时 400 KB）× 通过
- stdout cap: 256 KiB（`AgentCommandExecutionLimits.stdoutMaxBytes`）
- stderr cap: 256 KiB（独立计数，互不挤占）
- drain after cap: YES（drain-not-store：400 KB 输出仍 exit 0，绝不因 cap 停止读取）
- stdout truncated: 400 KB → `stdoutTruncated == true`，存储 = 262144 bytes
- stderr truncated: 400 KB → `stderrTruncated == true`
- encoding: cap 边界先移除不完整 UTF-8 尾部序列 → 严格 UTF-8 解码；
  非法字节 → U+FFFD 替换 + `nonUTF8Detected`（绝不 decode 失败即整体失败）
- binary: 命中 NUL → `binaryOutputDetected = true`，文本截断到首个 NUL 前安全前缀
  （绝不 Base64 / hex dump 整段二进制）
- ANSI/control handling: CSI / OSC / DCS / SOS / PM / APC 状态机 strip +
  C0（保留 `\n`）/ C1 / DEL 过滤；结果**绝不**喂给 SwiftTerm 或任何终端模拟器

## Result Model

- stdout / stderr: 独立 String
- exitCode: `Int32?`（`WIFEXITED` 语义；Darwin 位编码手工展开，C 宏在 Swift 不可见）
- signal: `terminationSignal: Int32?`（`WIFSIGNALED` / `WTERMSIG`）
- timeout: `timedOut: Bool`（result 状态，不是错误）
- cancellation: `cancelled: Bool`（result 状态，不是错误）
- duration: `Duration`，**单调时钟** `clock_gettime_nsec_np(CLOCK_MONOTONIC)`
  （spawn → reap + 收口）
- infrastructure error: `AgentCommandExecutionError`
  （`remoteExecutionUnsupported` / `authorizationRejected(AgentCommandError)` /
  `shellUnavailable` / `workingDirectoryUnavailable` / `spawnFailed(errno)`）
- non-zero exit semantics: **valid command result**——`exit 7` → `exitCode = 7`；
  命令不存在 → shell 127 + stderr 提示（与 `spawnFailed` 严格分离：后者在
  shell/cwd 预检通过后仍失败时抛出并携带 errno）
- 字段集合显式冻结（Mirror 断言 11 字段；无 PID / fd / 凭据字段）

## Working Directory

- source: redeem 返回的 immutable `request.workingDirectory`（唯一来源）
- frozen: YES——spawn 前经 `AgentPathResolver.canonicalize(kind: .local)`（kernel
  语义 symlink walker），chdir 只接受该 canonical 值
- actual cwd: `pwd -P` 实测 == canonical approved cwd（含空格 / 中文 / emoji 目录）
- active-session dependency: **0**（不读 active session / OSC7 / `currentDirectoryPath`）
- spaces: 通过（`dir with spaces`）
- Unicode: 通过（`中文目录-😀`）
- missing cwd: `.workingDirectoryUnavailable` + 零 side effect
- fallback: **0**（不存在目录 / 非目录（普通文件）/ `chmod 000` 不可进入 三种情形
  均结构化拒绝，绝不 fallback HOME / App cwd / 登录默认目录）
- 双请求交叉：A/B 两个 approved cwd 各自生效、互不漂移（§58）

## Timeout

- production default: **60 s**（`AgentCommandExecutionLimits.defaultTimeout`）
- hard max: **600 s**（clamp：700 s 请求 → 600 s，测试断言）
- model controlled: **NO**（Provider / 模型无任何参数路径；policy 为 App-owned 内部类型）
- test override: `AgentLocalCommandExecutionPolicy(timeout:terminationGracePeriod:)`
  （internal 构造，测试注入 120–300 ms）
- behavior: SIGTERM 进程组 → grace（production 5 s）→ 仍存活则 SIGKILL 进程组 →
  waitpid reap → `timedOut = true`；组清空后立即收口（不白等 grace）

## Cancellation

- Task cancellation: `withTaskCancellationHandler` 的 `onCancel`（同步、任意线程）→
  置位 + 若已 spawn 立即 `killpg(SIGTERM)`；**不是**只停止等待结果
- SIGTERM: 进程组（`killpg`）
- grace: production 5 s（测试注入 50–300 ms）
- SIGKILL: 宽限到期且**进程组非空**才发（组判据而非直接 child——直接 child 先退出
  也不跳过升级，§48）
- kill target: `killpg(childPID, …)`（child PGID == child PID）
- waitpid: 唯一 reap 路径（`waitpid(WNOHANG)`，锁内与信号发送互斥；`ECHILD` 容忍）
- zombie: 无——正常 / timeout / cancel 三条路径后 `kill(pid, 0)` 均 == ESRCH
  （zombie 仍会响应信号，故 ESRCH 是完整回收证明）
- ordinary child cleanup: `sleep 30` 后台同组 descendant 在 timeout / cancel 后
  **不残留**（实测 + 测试断言）
- escaped child guarantee: **不声称** killpg 能杀死主动 setsid / detach 的后代
  （10E-A 已接受 P3，见 Findings）

## Terminal Isolation

- SwiftTerm: 0 引用（无 `feed` / `send` / TerminalView）
- TerminalCommandDispatcher: 0 引用
- pasteText / send_to_terminal: 0 引用
- PTY mutation: 无（无 PTY 分配、无 fd 修改）
- interactive cwd changed: NO（子进程 `cd /tmp` 后 App 进程 cwd 不变，测试断言）
- interactive env changed: NO（子进程 `export` 不进入 App 进程环境，测试断言）

## Provider Boundary

- definitions count: 4（gate 断言）
- run_command advertised: **NO**
- run_command prohibited: YES（仍在 `AgentToolCatalog.prohibitedNames`；
  `AgentToolCallParsing.parse("run_command")` → `.unknownTool`）
- AgentViewModel command wiring: **无**（source gate：`AgentViewModel.swift` 不含
  `AgentLocalCommandExecutor` / `AgentLocalCommandProcess` / `run_command`）
- function_call_output wiring: **无**（result 只存在于 executor domain 与测试；
  Provider wiring 属 10E-B4）

## Remote Boundary

- SSHConnection changes: **无**（本阶段未触碰任何 SSH 文件；tracked 修改仅
  `project.pbxproj` + B1 的 4 个文件）
- libssh2 exec: **0**（无 `libssh2_channel_exec` / `channel_exec` /
  `libssh2_` 引用）
- second channel: NO
- Remote command support: NOT IMPLEMENTED——`.remote` target 进入 Local executor
  → `.remoteExecutionUnsupported`，**零 spawn**、零 side effect（绝不静默
  remote→local fallback）

## UI Boundary

- actionable Approve: 无
- actionable Reject: 无
- command execution UI: 无（B1 的 `awaitingApproval` / `denied` 非交互展示兼容保持）
- localization: 0 变更（B2 无新用户可见字符串；`Localizable.xcstrings` 的修改
  全部来自 B1）

## Security

- credential access: 0（Execution 层无 Keychain / CredentialService / apiKey /
  password / passphrase 引用）
- command logging: 0（无 `print(` / `NSLog` / `os_log` / `OSLog` / `Logger(`）
- stdout/stderr logging: 0（result 的 `description` redacted，测试断言不含内容）
- cwd logging: 0（同上）
- authorization bypass: 0（唯一入口强制 redeem；无 callable 可跳过 ledger gate）
- authorization replay: rejected（第二次调用 spawn 前失败，零 side effect）
- secret environment leakage: 0（见 Environment）

## B2 Tests

新增 4 个 suite，共 **63** tests（`0 failures`）：

- basic execution / cwd / environment / stdin / TTY（`AgentLocalCommandExecutorTests`
  — 24）：echo stdout / stderr only / stdout+stderr 分离 / exit 0 / exit 7 /
  command-not-found 127 / multiline / Unicode / command 原文不改写 /
  账户 shell `-c` 且无 login-interactive flag / frozen cwd / 空格 cwd /
  Unicode cwd / 双请求各自 cwd / cwd 不存在 / cwd 非目录 / cwd 不可进入 /
  parent cwd 不变 / parent env 不变 / allowlist 环境（fake secret 不继承）/
  stdin EOF / 无 TTY / CLOEXEC canary / **production policy（60 s / 5 s）真实执行** /
  policy 冻结值 + 600 s clamp
- output cap / drain / 清洗（`AgentLocalCommandExecutorOutputTests` — 19）：
  stdout 400 KB 截断且 drain 完整 / stderr 同 / **双流同时 400 KB 无死锁** /
  小输出不标记 / CSI / OSC（BEL 与 ST 两种终止）/ DCS / C0 过滤保留 `\n` /
  C1 CSI / escape 后续文本不受影响 / valid UTF-8 / invalid UTF-8 替换 + 标记 /
  NUL 二进制标记 + 首 NUL 截断 / 空输出 / 清洗器边界（cap 处不完整序列、
  完整序列保留、尾部不完整 escape、TAB 冻结行为）
- timeout / cancellation / process group（`AgentLocalCommandExecutorCancellationTests`
  — 10）：PGID==PID / 正常退出 reap 无 zombie / timeout 终止组 + reap /
  timeout 清同组后台 descendant / SIGTERM 抵抗 → SIGKILL / Task 取消终止 + reap +
  部分输出保留 / 预先取消零 spawn 且不消费 authorization / 6 轮取消竞态压力
  （0 crash、0 残留）/ timeout 后 executor 仍可用 / 后台 descendant 与前台
  双进程组清理
- security / 静态 gate（`AgentLocalCommandExecutorSecurityTests` — 10）：
  Execution 层文件集合冻结 + 执行/终端/SSH/凭据/持久化/日志 token = 0 /
  无 raw command API + `execute` 形参断言 / result 模型字段冻结 + redacted /
  forged authorization 强 side-effect / replay 恰一次 / 跨 ledger /
  remote target 拒绝且不消费授权 / Provider 边界 4 tools + run_command 禁止 +
  parser unknownTool / AgentViewModel 零接线 / fake provider credentials
  不进入 child env 与 argv

## B1 Regression

- Validation: `AgentCommandValidationTests` 13 / 0 failures
- Request: `AgentCommandRequestTests` 11 / 0 failures
- ApprovalCoordinator: `AgentCommandApprovalCoordinatorTests` 29 / 0 failures
- ApprovalConcurrency: `AgentCommandApprovalConcurrencyTests` 8 / 0 failures
- SecurityGate: `AgentCommandSecurityGateTests` 7 / 0 failures
  （含 `Command/` 顶层恰 5 文件、无执行 token——B2 executor 位于
  `Command/Execution/` 子目录，B1 gate **原文未改**、仍 0 failure）
- one-time authorization / forgery resistance: 全部保持（B2 新增 forged / replay /
  跨 ledger / 预取消四类，均 spawn 前拒绝）

## Phase 10D Regression

- ProviderToolGate: 11 / 0 failures
- ToolLoop: 20 / 0 failures
- ToolRouter: 19 / 0 failures
- AgentViewModel: 19 / 0 failures
- ConversationStore: 11 / 0 failures

## Test Universe

- B1 baseline discovered: 961
- B1 baseline executed: 960（passed 835 / skipped 125 / failed 0 / excluded 1）
- B2 tests added: 63（24 + 19 + 10 + 10）
- current discovered: **1024**
- current executed: **1023**
- passed: **898**
- skipped: **125**（与 baseline 逐套件一致）
- failed: **0**
- externally excluded: **1**（`SessionManagerTests/testO_CloseWhileConnectingCancelsConnection`
  用例级 `-skip-testing`，**未扩大**）
- arithmetic: `executed = passed + skipped` → 898 + 125 = 1023 ✓；
  `discovered = executed + excluded` → 1023 + 1 = 1024 ✓；
  `current executed = baseline executed + added` → 960 + 63 = 1023 ✓
- 入口：`xcodebuild test-without-building -project MacSSH.xcodeproj -scheme MacSSH
  -configuration Debug -destination 'platform=macOS,arch=arm64'
  -derivedDataPath /tmp/MacSSH-Phase10E-B2-Debug -skipPackagePluginValidation
  -skipMacroValidation
  '-skip-testing:MacSSHTests/SessionManagerTests/testO_CloseWhileConnectingCancelsConnection'`
- 日志：`/tmp/macssh-b2-full2.log`（`Executed 1023 tests, with 125 tests skipped and
  0 failures`；`** TEST EXECUTE SUCCEEDED **`）；最终源码修订前的同构全量
  `/tmp/macssh-b2-full.log` 为 1022 / 125 / 0（差值恰为后补的 production-policy 用例）
- historical +1 identified: **YES —— 已定位并定案（不再是 P3）**：
  `AgentProviderToolCallingTests.testReasoningPrecedesAssistantTextInContinuationReplay`。
  证据链：
  1. 该用例由 Phase 10D 最终提交 `73038d6` 引入（`git log -S` 命中该提交），
     当前工作树与 HEAD 一致（`git diff HEAD -- Tests/SSH/AgentProviderToolCallingTests.swift`
     为空；B1/B2 均未修改该文件）；
  2. B1 全量日志（`/tmp/macssh-b1-full.log`）该 suite 执行 **20** 个（含该用例，
     passed），B4 全量日志（`/tmp/macssh-b4-full-test2.log`）仅执行 **19** 个；
     两日志逐套件计数差**仅此 1 项**（其余 60 个 suite 完全一致）；
  3. ⇒ B4 记录的 "892 discovered / 891 executed / passed 766" 来自**未包含该用例
     的构建快照**；Phase 10D accepted universe 实际为 **893 discovered /
     892 executed / 767 passed + 125 skipped + 1 excluded**；
  4. ⇒ 961 = 893 + 68、960 = 892 + 68、835 = 767 + 68 —— **全部数学自洽**，
     B1 与 B2 记账不再存在任何口径偏差。

## Debug

- DerivedData: `/tmp/MacSSH-Phase10E-B2-Debug`（B2 起始为空目录，fresh）
- result: `** BUILD SUCCEEDED **` + `** TEST BUILD SUCCEEDED **`
- test build: `** TEST BUILD SUCCEEDED **`（日志 `/tmp/macssh-b2-debug5.log`）
- warnings: **生产代码 0**（Execution 层 5 文件 0；增量重建与 Release 均 0）。
  首次 fresh 全量编译暴露 19 处 warning 站点，逐文件核对后：18 处位于
  **B2/B1 未修改的既有测试文件**（`CommandHistoryStoreTests` 7、
  `TerminalAppearanceTests` 4、`SavedCommandStoreTests` 4、
  `TerminalCommandDispatcherTests` 1、`LocalShellOSC7Tests` 1、
  `AgentProviderSettingsTests` 1——Swift 6 并发/未用值类），1 处位于 B2 新文件
  （`AgentLocalCommandEnvironment.swift` 的 deprecated `String(cString:)`）
  **已在本阶段修复**（改用 `String(decoding:as:)`），修复后增量重建 0 warning。
  B1 报告中的 "warnings: 0" 来自未编译测试 target 的构建日志，属记账口径差异
  （P3-4）。

## Release

- DerivedData: `/tmp/MacSSH-Phase10E-B2-Release`
- result: `** BUILD SUCCEEDED **`
- warnings: **0**（日志 `/tmp/macssh-b2-release.log`）

## Files

#### B1 Existing

- `MacSSH/Services/Agent/Command/AgentCommandValidation.swift`
- `MacSSH/Services/Agent/Command/AgentCommandRequest.swift`
- `MacSSH/Services/Agent/Command/AgentCommandApproval.swift`
- `MacSSH/Services/Agent/Command/AgentCommandApprovalCoordinator.swift`
- `MacSSH/Services/Agent/Command/AgentCommandExecutionAuthorization.swift`
- `Tests/SSH/AgentCommandValidationTests.swift`
- `Tests/SSH/AgentCommandRequestTests.swift`
- `Tests/SSH/AgentCommandApprovalCoordinatorTests.swift`
- `Tests/SSH/AgentCommandApprovalConcurrencyTests.swift`
- `Tests/SSH/AgentCommandSecurityGateTests.swift`
- （tracked 修改，B1 遗留）`project.pbxproj` / `AgentToolCardView.swift` /
  `Localizable.xcstrings` / `AgentToolActivity.swift` / `gen_localizable.py`

#### B2 Added

- `MacSSH/Services/Agent/Command/Execution/AgentCommandResult.swift`（112 行；
  `AgentCommandExecutionLimits` / `AgentLocalCommandExecutionPolicy` /
  `AgentCommandExecutionError` / `AgentCommandResult`）
- `MacSSH/Services/Agent/Command/Execution/AgentLocalCommandExecutor.swift`（172 行；
  唯一执行入口 + redeem 顺序 + 专用执行线程桥 + 纯 POSIX cwd 探针）
- `MacSSH/Services/Agent/Command/Execution/AgentLocalCommandProcess.swift`（502 行；
  `AgentLocalCommandProcessControl` + posix_spawn 核心 + poll 事件循环 + 组清理）
- `MacSSH/Services/Agent/Command/Execution/AgentLocalCommandEnvironment.swift`（54 行；
  冻结 allowlist 环境）
- `MacSSH/Services/Agent/Command/Execution/AgentLocalCommandOutputSanitizer.swift`
  （170 行；cap 边界 UTF-8 / NUL / ANSI-strip 策略）
- `Tests/SSH/AgentLocalCommandExecutorTests.swift`（468 行，24 tests）
- `Tests/SSH/AgentLocalCommandExecutorOutputTests.swift`（189 行，19 tests）
- `Tests/SSH/AgentLocalCommandExecutorCancellationTests.swift`（298 行，10 tests）
- `Tests/SSH/AgentLocalCommandExecutorSecurityTests.swift`（339 行，10 tests）
- 分层说明：B2 executor 置于 `Command/Execution/`（子目录）——B1 的
  §52/§53 execution-capability gate 以 `Command/` **顶层**文件为扫描域并断言
  恰 5 文件；executor 与 domain 分层后 B1 gate 原文不动（0 修改）、仍 0 failure，
  B2 另立 Execution 层静态 gate。

#### B2 Modified

- `MacSSH.xcodeproj/project.pbxproj`（B2 增量 +44 行：5 production 文件入
  production target + 4 测试文件入 test target + 新增 `Execution` group；
  无重排，`plutil -lint` 通过）
- 其余 tracked 文件：**0**（B2 不修改任何既有源码 / 测试 / 本地化）

#### Docs

- `Docs/Phase10E-B2-Local-Independent-Command-Executor.md`（本报告，untracked）
- 当前 untracked Docs = **9**（8 既有 + 本报告）

#### Unexpected

- 无（`git status --short` 与 before 快照逐项一致 + B2 新增项）

## Findings

#### P1

- count: 0
- items: 无

#### P2

- count: 0
- items: 无

#### P3

- count: 5
- items:
  1. **spawnattr 追加 SETSIGDEF / SETSIGMASK（超出 10E-A 冻结 flag 集）**：
     实现中发现 GUI App 进程继承的 signal disposition / mask 会进入 command
     子进程——实测后台 job 收不到组 SIGTERM（`TRACE=[BG_STARTED]` 无
     `TERM_RECEIVED`），冻结的「SIGTERM → grace → SIGKILL」链退化为纯 SIGKILL
     等待，并放大 §48 descendant 残留窗口。故追加 `POSIX_SPAWN_SETSIGDEF`（全信号
     默认）+ `POSIX_SPAWN_SETSIGMASK`（空屏蔽字），使子进程以 Terminal 等价信号
     状态起步。属对冻结**语义**的支撑性补充、非架构变更（机制仍是 posix_spawn +
     SETPGROUP + CLOEXEC_DEFAULT + addchdir_np），并已在自己的 gate 中固化。
  2. **组级 SIGKILL 升级判据**：升级依据是「进程组是否非空」（`killpg(pgid, 0)`
     探测）而非「直接 child 是否存活」。直接 child 先于 descendant 退出时同样
     完成升级（否则 `sleep 30 &` 类后台 job 会残留）。SIGKILL 后设 1 s 有界确认
     窗口；若成员处于不可中断态，窗口到期即收口（理论边界，未观测到）。
  3. **逃逸后代不保证**：主动 `setsid` / detach 的后代可逃离进程组，killpg 无法
     保证覆盖——10E-A 已接受，B2 不声称更强保证，不实现 sandbox/container。
  4. **B1 记录 "warnings: 0" 的口径差异**：fresh 全量 `build-for-testing` 暴露
     18 处既有测试文件 warning（未修改文件）；B1 的日志未编译测试 target，故记录
     为 0。B2 生产代码 0 warning；既有测试 warning 属基线噪音，未在 B2 修复
     （不扩大本阶段范围）。
  5. **正常退出路径不清理组内后台 job**：`sleep 1000 &` 类后台 job 在命令**正常
     退出**后仍存活（与交互式 shell 语义一致：只有 timeout / cancellation 才
     killpg）。drain 以「child reap + EOF 或 150 ms 收口窗口」为界，绝不无限等待
     后代持有的 pipe。

## Decision

```text
PASS — 0 P1 / 0 P2
```
