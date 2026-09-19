# Phase 10E-B3 — Remote SSH Independent Exec Executor

本文件为 Phase 10E-B3 的阶段报告（untracked，按 Phase 10 惯例不入产品 commit）。
代码 revision：`feature/macssh-1.1-agent-command-execution` @ `73038d6` + B1/B2/B3 working-tree candidate。

---

## 1. 目标与边界

唯一目标：建立 **Remote SSH Independent Exec Executor** 基础能力：

```text
valid one-time authorization → coordinator redeem → explicit sessionID
→ existing authenticated SSHConnection → new independent "session" channel
→ exec request（NO PTY, stdin EOF）→ bounded stdout/stderr
→ exit status / exit signal / timeout / cancellation → channel cleanup
```

本阶段**不**接线 Agent 执行：Provider 未注册 `run_command`、`AgentViewModel` 无执行
路径、无 Approve / Reject / Execute 按钮、结果绝不发往任何 Provider（OpenAI /
DeepSeek）。`send_to_terminal` 与全部 standalone 修改型文件工具继续禁止。

---

## 2. 现有 SSH 架构实查（进入实现前完成）

| 关注点 | 实际实现 |
| --- | --- |
| `SSHConnection` | `actor`，独占 `LIBSSH2_SESSION *`（`internal var session`）+ `socketFD`；全部 libssh2 调用只发生在 actor 隔离内 |
| actor ownership | `SSHChannel.swift`（PTY shell）/ `SFTPSession.swift`（SFTP 子系统）以 extension 形式挂载，均在同一 actor 内；调用方只持有不透明值 |
| socket readiness | `waitForLibssh2Readiness(session:deadline:)`（`libssh2_session_block_directions` → `poll`，≤0.25s 切片；零方向退避走 `Task.sleep`） |
| EAGAIN | 统一模式：`rc == LIBSSH2_ERROR_EAGAIN` → readiness 等待 → 重试；无 busy-loop |
| interactive PTY | `openInteractiveShell` / `readChannelOutput` / `writeChannelInput` / `resizeChannelPTY` / `closeShellChannel`（单 channel） |
| SFTP | `openSFTPSubsystemIfNeeded` + `sftpOperationGate`（子系统级共享状态串行门，FIFO）+ 在途句柄登记与拆除排空 |
| disconnect lifecycle | `disconnectTask` 单飞；顺序：SFTP 资源 → Shell Channel → **（本阶段新增）exec channel** → SSH session → socket |

结论：exec channel 只能以 **`SSHConnection` extension + 不透明 token** 形式实现，
绝不把 `LIBSSH2_CHANNEL *` 带出 actor，也绝不新建第二套 socket poller。

---

## 3. 交付物

### 3.1 SSH 层（transport/domain-neutral，新增 1 文件 + 1 文件最小扩展）

- `MacSSH/Services/SSH/SSHExecChannel.swift`（新）
  - 值类型：`SSHExecStream`（stdout/stderr，stream id 0 / `SSH_EXTENDED_DATA_STDERR`）、
    `SSHExecSignalName`（`TERM` / `KILL` 协议名）、`SSHExecChannelTermination`
    （`exitStatus` / `exitSignalName` / `exitSignalErrorMessage` 值快照）；
  - 错误：`SSHExecChannelError`（connectionLost / channelOpenFailed /
    execRequestRejected / channelClosed / channelReadFailed / channelWriteFailed /
    signalRequestRejected / timedOut）；
  - 可注入 libssh2 边界：`SSHExecChannelOperations`（`.live` = 真实 libssh2；
    测试可注入 fake —— 与 Phase 5 `SessionTeardownOperations` 同款接缝设计，
    **不是**第二套实现）；
  - `SSHConnection` 扩展方法：`openExecChannel(command:isCancelled:)`、
    `sendExecChannelEOF`、`readExecChannelOutput(_:stream:)`、
    `waitForExecChannelActivity`、`requestExecChannelSignal`、
    `finishExecChannel`、`closeExecChannel`、`closeAllExecChannelsForTeardown`、
    `openExecChannelCount`；
  - 测试接缝：`setTestExecChannelReadinessWait` / `setTestSessionPointer` /
    `setTestShellChannelIdentity` / `setTestSFTPSubsystemIdentity` /
    `isShellChannelIdentity` / `isSFTPSubsystemIdentity`（生产均不使用）。
- `MacSSH/Services/SSH/SSHConnection.swift`（B3 扩展，+33 行）
  - 新增 `execChannelOperations`（init 默认 `.live`）、`execChannels: [UUID: SSHExecChannelRecord]`、
    `execChannelOpenCount` / `execChannelFreeCount`（测试仪表）、`testExecChannelReadinessWait`；
  - `performTrackedDisconnect()` 增加 `closeAllExecChannelsForTeardown()`。

### 3.2 Agent 层（新增 3 文件，位于 `Execution/Remote/`）

- `AgentRemoteCommandBuilder.swift`：cwd wrapper + 单引号引用（App 唯一生成的
  shell 片段）；payload 上界守卫。
- `AgentRemoteCommandSessionResolver.swift`：显式 `sessionID` → 已认证
  `SSHConnection`；`.live(sessionManager:)` 为 B4 唯一接线点（本阶段无调用方）。
- `AgentRemoteCommandExecutor.swift`：唯一执行入口 `execute(authorization:approvalCoordinator:)`；
  错误分类 / 终止表示 / 结果模型 / 取消标志通道 / drain 与终止主循环。

---

## 4. 关键语义

### 4.1 授权边界（与 B2 同根）

唯一合法链（§8 冻结顺序）：

```text
authorization → target validation（.remote only）
→ cancel check → coordinator.redeem → final cancel check
→ session 解析（显式 immutable sessionID）→ open 前最后一道取消门 → open exec channel
```

- 不存在 `execute(command:)` / `execute(request:)` / `execute(sessionID:command:)`
  形态的 production entry point（静态门测试断言）；
- forged / 跨 ledger / 重复 redeem：在任何 SSH side effect 之前被 coordinator 账本
  拒绝（`fake.openCallCount == 0`、`fake.execRequestCallCount == 0` 强证据）；
- 同一 authorization 第二次执行 → `authorizationRejected(.approvalAlreadyClaimed)`，
  零新增 channel open。

### 4.2 Session 绑定与凭据隔离

- target identity = `AgentCommandRequest.sessionID`（UUID），`displayName` 仅 UI metadata；
- 解析路径只查询 approved sessionID（测试记录 resolver 收到的全部 ID，断言 == [origin]）；
- 不 fallback `activeSession` / 选中 tab / hostname；找不到 → `sessionUnavailable`；
- **绝不**新建 TCP / SSH 认证；executor 与 SSH exec 层不触碰 Keychain / 凭据服务
  （静态 token 扫描 + 运行期 fake 凭据不进入 payload 测试）；
- A/B 隔离：session A 的授权只使用 Connection A（open=1），Connection B 零 open。

### 4.3 exec channel

- channel 类型：新的独立 `session` channel（`libssh2_channel_open_ex("session")`）；
- **无 PTY**：不调用 `request_pty` / `shell`，只发 `exec`（`process_startup("exec")`）；
- `stdin = EOF`：exec 请求成功后立即 `send_eof`（EAGAIN 走 readiness）；无任何
  stdin 数据 API / 键盘转发；
- 单 channel 所有者：`execChannels[token]` 登记，`closeTask` 是**唯一释放者**
  （exactly-once free，double-free 防御）；teardown 与 executor 关闭并发时等待
  同一任务；
- PTY / SFTP 完全不受影响：exec 生命周期绝不触碰 `shellChannel` / `sftpSubsystem`
  （fake 句柄身份断言 + live PTY/SFTP 共存测试，后者本机 fixture 缺失而 self-skip）。

### 4.4 CWD（SSH exec 无 App 可控 cwd 参数）

- 唯一来源：approved immutable `request.workingDirectory`（B1 factory 已限定
  authoritative + 绝对路径；approximate / unavailable / 相对一律拒绝）；
- **禁止** SFTP `realpath(".")` 回退（它是 login/session 近似，非交互 shell cwd）；
- **禁止** login 目录 / HOME / `/` 回退；
- wrapper（§38 冻结语义）：

```bash
cd '<escaped-cwd>' || exit $?
<original-command>
```

- 引用算法：POSIX 单引号（`'` → `'\''`），cwd 中 `$` / 反引号 / 双引号 / 反斜杠 /
  空白 / Unicode / emoji / `#` `%` `?` / 换行全部字面化；
- 原 command **逐字节保留**（不 trim、不规范化空白、不改引号、不加任何东西），
  多行 / 注释首行 / here-doc 语义不变；
- cwd 失败 ⇒ `|| exit $?` 使原 command **零执行**（真实 `/bin/sh` 验证）；
- payload 上界：cwd ≤ 8 KiB、payload ≤ 16 KiB + 8 KiB + 64，越界返回
  `execPayloadTooLarge`（绝不 silent truncate）。

### 4.5 输出与结果

- stdout / stderr 分离读取（stream 0 / 1），双流公平 drain（每轮两流各最多 16 块，
  有数据即 `Task.yield()`）；cap（256 KiB × 2）命中后继续 drain、停止保存；
- 清洗复用 B2 `AgentLocalCommandOutputSanitizer`（UTF-8 边界 / NUL→binary /
  严格解码 U+FFFD / ANSI CSI-OSC-DCS strip / C0-C1 过滤）；
- 结果复用 B2 `AgentCommandResult`（stdout/stderr/exitCode/truncation/timeout/
  cancelled/duration 语义一致）；Remote 特有终止信息放
  `AgentRemoteCommandTermination`（`exitStatus` / `exitSignal(name:errorMessage:)` /
  `unknown`），**绝不**伪造本地 numeric signal（`result.terminationSignal` 恒 nil）；
- Remote 输出绝不 feed SwiftTerm、绝不进入 PTY、绝不发往 Provider。

### 4.6 timeout / 取消

- 策略复用 B2 冻结的同一类型（`typealias AgentRemoteCommandExecutionPolicy =
  AgentLocalCommandExecutionPolicy`；60s 默认 / 600s hard max / 5s grace，
  模型不可指定）；
- timeout 起点：execution attempt 开始（open 之前）；drain 循环每个活动等待切片
  （100ms）后重估；
- 取消：`onCancel`（同步、任意线程）只置位标志；drain 循环在 ≤100ms 切片内观察到
  取消 → TERM → grace → KILL → 有界收口；open 前的取消门使 channel **零 open**；
  请求类步骤（open / exec / EOF）带取消谓词，切片内以 `CancellationError` 退出；
- 语义边界（绝不夸大）：

```text
local channel cleanup        = GUARANTEED（exactly-once free）
signal request               = BEST-EFFORT（服务器可忽略 / 不支持：signalRequestRejected，仍完成 cleanup）
remote process death         = NOT GUARANTEED
remote descendants           = NOT GUARANTEED
```

- 绝不因 command timeout / cancel 断开整个 SSH 连接（测试断言 session 仍存活）；
  绝不偷偷执行 `kill` / `pkill` 第二命令；绝不关闭 PTY / SFTP 子系统。

---

## 5. 测试

### 5.1 新增测试文件（7 个）

| 文件 | 方法数 | 覆盖 |
| --- | --- | --- |
| `Tests/SSH/AgentRemoteCommandTestSupport.swift` | 0（装置） | fake libssh2 边界（open/exec/EOF/双流读/EAGAIN/exit status/exit signal/signal/close/free/连接丢失）+ 计数 + 装配 |
| `Tests/SSH/AgentRemoteCommandBuilderTests.swift` | 18 | wrapper 形状、原 command 逐字节保留、多行/注释/here-doc、cwd 注入面（含真实 `/bin/sh` 验证）、payload 上界 |
| `Tests/SSH/AgentRemoteCommandSSHTransportTests.swift` | 27 | open/exec/EOF/EAGAIN 恢复、双流分离、EOF 语义、signal 协议名与拒绝、exit status/exit signal 在 free 之前、幂等 close、并发 close、teardown、句柄隔离 |
| `Tests/SSH/AgentRemoteCommandExecutorTests.swift` | 20 | 成功 / exit 7 / 127 / exit signal / unknown、caps 与双流、binary/nonUTF8/ANSI、session 不可用、session 竞态、A/B 隔离、resolver 查询记录、连接丢失、exec 拒绝、日志 redaction |
| `Tests/SSH/AgentRemoteCommandExecutorCancellationTests.swift` | 9 | timeout（TERM→EOF 与 TERM 被忽略→KILL 有界收口）、取消（有界响应断言）、open 前/后取消门、signal 不支持、6 轮取消压测、失败后复用 |
| `Tests/SSH/AgentRemoteCommandExecutorSecurityTests.swift` | 13 | forged / replay / 跨 ledger / local target / 错 session、provider 凭据不入 payload、Remote 层与 SSH exec 层的静态 token 门、AgentViewModel 零接线、Provider 边界、禁止名单 |
| `Tests/SSH/AgentRemoteRealExecTests.swift` | 15 | 真实 sshd：pwd/权威 cwd、空间+单引号 cwd、双流、exit 7/127、stdin EOF、多行+注释+here-doc、大输出 cap、timeout、取消、PTY 共存、SFTP 共存、泄漏审计、未知 sessionID、双 session 隔离 |

测试策略说明：executor / SSH 层测试全部跑在**真实 `SSHConnection` actor** 上，
只有 libssh2 调用边界被 fake 占用（`.live` 之外没有任何第二套生产实现）；
live 测试只使用项目既有 fixture（`127.0.0.1:22` + `/tmp/macssh_phase6_ed25519`），
fixture 缺失即 self-skip。

### 5.2 全量套件（最终 revision）

见 §7 测试宇宙。

---

## 6. 静态安全审计（§145）

对 B3 新增生产文件（`SSHExecChannel.swift` + `Execution/Remote/*`）逐一 grep：

```text
SSHConnection( → 0        libssh2_userauth → 0      password / passphrase → 0
Keychain → 0              CredentialService → 0     TerminalCommandDispatcher → 0
pasteText → 0             send_to_terminal → 0      run_command → 0
URLSession → 0            FileManager → 0           ToolCard / approvalID / generationID → 0
```

`run_command` 全项目仅出现在：`AgentToolDefinition.prohibitedNames`（禁止名单）、
`AgentToolActivity` 注释、`AgentCommandValidation` 注释 —— 无任何注册路径。

---

## 7. 测试宇宙与算术

命令：

```bash
xcodebuild -project MacSSH.xcodeproj -scheme MacSSH \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug -derivedDataPath /tmp/MacSSH-Phase10E-B3-Debug \
  -skip-testing:MacSSHTests/SessionManagerTests/testO_CloseWhileConnectingCancelsConnection \
  test-without-building
```

结果（`/tmp/macssh-b3-fullsuite-final.log`）：

```text
Executed 1125 tests, with 140 tests skipped and 0 failures
** TEST EXECUTE SUCCEEDED **
```

| 项 | 数值 |
| --- | --- |
| baseline discovered | 1024 |
| baseline executed | 1023 |
| baseline passed / skipped | 898 / 125 |
| B3 added（方法数） | 102（87 executed + 15 live self-skip） |
| current discovered | 1126 |
| current executed | 1125 |
| current passed | 985 |
| current skipped | 140（= 125 baseline + 15 live self-skip） |
| current failed | 0 |
| external exclusion | 1（`SessionManagerTests.testO_CloseWhileConnectingCancelsConnection`，未扩大） |
| arithmetic | 985 + 140 = 1125 ✓；1125 + 1 = 1126 ✓ |

逐套件（最终 revision，0 failures）：

```text
B3:  Builder 18 | SSHTransport 27 | Executor 20 | Cancellation 9 | Security 13 | RealExec(live) 15 skipped
B1:  Validation 13 | Request 11 | ApprovalCoordinator 29 | ApprovalConcurrency 8 | SecurityGate 7  (=68)
B2:  LocalExecutor 24 | Cancellation 10 | Output 19 | Security 10  (=63)
10D: ProviderToolGate 11 | ToolLoop 20 | ToolRouter 19 | AgentViewModel 19 | ConversationStore 11 | ProviderToolCalling 20
```

## 7.1 构建证据（最终 revision）

```text
Debug   (/tmp/MacSSH-Phase10E-B3-Debug):         BUILD SUCCEEDED，0 warning
        /tmp/macssh-b3-debug-final.log
Test    (/tmp/MacSSH-Phase10E-B3-Debug):         TEST BUILD SUCCEEDED，0 warning
        /tmp/macssh-b3-testbuild-final3.log
Release (/tmp/MacSSH-Phase10E-B3-Release):       BUILD SUCCEEDED，0 warning
        /tmp/macssh-b3-release-final.log
```

测试 target 的既有 warning（存在于 Phase ≤10D 的测试文件，**与 B3 无关**；B3 新增 8 个
文件在任何一次编译中 0 warning）：

```text
Tests/SSH/CommandHistoryStoreTests.swift      (7)
Tests/SSH/TerminalAppearanceTests.swift       (4)
Tests/SSH/SavedCommandStoreTests.swift        (4)
Tests/SSH/AgentProviderSettingsTests.swift    (1)
Tests/SSH/LocalShellOSC7Tests.swift           (1)
Tests/SSH/TerminalCommandDispatcherTests.swift(1)
```

## 7.2 Git 复核

```text
git diff --check        → 空
git diff --cached       → 空（0 staged）
git status --short      → 6 modified（B1 4 个 + pbxproj + SSHConnection）+ 7 untracked 测试 + 2 untracked 源码 + 10 untracked Docs
commit / push / merge / tag / rebase → 无
```

B3 在生产 diff 中的位置：
- `MacSSH.xcodeproj/project.pbxproj`：B3 新增 4 个 app 文件 + 7 个测试文件条目 + `Remote` group（叠加在 B1/B2 条目之上）；
- `MacSSH/Services/SSH/SSHConnection.swift`：+33 行（exec 登记 / 计数 / 测试接缝 / init 参数 / teardown 调用）；
- 其余 B3 产物全部为**新增文件**（含 3 个 `Execution/Remote/` 与 1 个 `SSHExecChannel.swift`）。

---

## 8. Findings

### P1
- count: 0

### P2
- count: 0

### P3（真实限制，全部如实披露）
1. **live SSH fixture 不可用**：本机 Remote Login 处于开启状态（127.0.0.1:22 可连），
   但项目既有测试私钥 `/tmp/macssh_phase6_ed25519` 不存在（`/tmp` 已清空），
   且 §120 禁止本阶段生成新 key / 修改 `authorized_keys`。因此 15 条 live 测试
   **全部 self-skip**，进入 `skipped`（不扩大 external exclusion）。
   **本阶段不声称 live Remote execution validated**。恢复方式（需用户明确授权）：
   运行 `Scripts/run-phase10-focus.sh` 重建测试 key 后重跑
   `AgentRemoteRealExecTests`。
2. 服务器可能不支持 / 忽略 SSH signal request：远端终止只能 best-effort；
   远端进程与其后代是否死亡 **不保证**（绝不宣称「已杀死远端进程」）。
3. 显式 detached / background 命令（`nohup` / `setsid` / `&`）可能存活到 exec
   channel 关闭之后 —— 这是 arbitrary command semantics 的已接受限制，
   executor 不实现 sandbox / 进程枚举 / 隐藏 kill 命令。
4. timeout 起点与超界：timeout 自 execution attempt 开始计时并在 drain 循环中精确
   执行；open / exec / EOF 三个请求步骤各自有 10s / 10s / 5s 步骤预算，因此在
   「请求步骤本身 hang 死」的极端场景下，timeout 判定最多被推迟该步骤预算
   （生产默认 60s 超时下不会发生；测试用短策略 + fake 即时返回）。
5. payload App 侧上界（16 KiB command + 8 KiB cwd + wrapper）：libssh2 本身没有这么
   低的 hard limit；该上界是 App 侧确定性防御，越界返回结构化错误而非截断。
6. Remote shell 语义 = 服务器端 SSH exec 的 shell 语义（通常为账户 login shell
   `-c command`），与 Local 的「App 解析账户 shell + `-c`」**不保证完全一致**；
   App / Provider 绝不指定远端 shell。
7. `AgentRemoteCommandExecutionPolicy` 是 B2 `AgentLocalCommandExecutionPolicy` 的
   typealias（同一冻结配置，非第二套时间表）——命名见 B3 报告 §4.6。

---

## 9. 结论

见回复正文的最终 Decision。
