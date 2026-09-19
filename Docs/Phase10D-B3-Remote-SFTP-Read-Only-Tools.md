# Phase 10D-B3 — Remote SFTP Read-Only Tools

日期：2026-09-11
分支：`feature/macssh-1.1-agent-sidebar`
HEAD：`fc07f0f88d69c40a86599c205c4366bbdf670afb`（未移动）

## Repository

- branch: `feature/macssh-1.1-agent-sidebar`
- HEAD: `fc07f0f88d69c40a86599c205c4366bbdf670afb`
- baseline working tree: B1+B2 已验收 candidate 全部未提交
  - 状态快照：`/tmp/macssh-phase10d-b3-status-before.txt`
  - tracked diff：`/tmp/macssh-phase10d-b3-before.patch`
- B3 changes: 见下文 Files
- staged: 无
- commit: 无
- push: 无

### 仓库门禁

`git branch --show-current` / `git rev-parse HEAD` 与任务书要求一致。
tracked modification 只有 4 个文件，全部可归因 B1/B2
（`project.pbxproj` / `.zshenv` / `LocalShellLauncher.swift` /
`LocalShellLauncherTests.swift`），无未知 tracked 修改。

## Architecture

- remote façade: `AgentRemoteReadOnlyFileClient`（6 个只读原语：
  `canonicalPath` / `stat` / `listDirectory` / `openFileForRead` /
  `readFileChunk` / `closeFile`）。无 mutation 方法（§4/§107）。
- existing connection reuse: 是。生产 resolver
  `SessionManagerAgentRemoteServiceResolver` 只从 origin
  `ManagedTerminalSession.connection` 取已认证 `SSHConnection`；
  Agent 目录内 `SSHConnection(` 构造点 = 0（§108）。
- new connection created: 无。
- SFTP subsystem: 复用既有 `openSFTPSubsystemIfNeeded()`（惰性 +
  幂等 + 与 Files 面板 / 传输共享生命周期），未建第二套
  `libssh2_sftp_init` 生命周期（§11）。
- operation gate: 每个只读原语都落在既有 `SSHConnection` 方法内，
  经同一个 `acquireSFTPOperationGate` FIFO 串行门（§12）；Agent 侧
  无任何绕过 gate 的 raw libssh2 循环。
- credential access: 0。`Agent/Tools` 内 `CredentialService` /
  `KeychainService` / `privateKey` / `passphrase` 命中均为 0（§6）。
- bottom-layer changes: **none**。`SSHConnection.swift` /
  `SFTPSession.swift` / `SFTPFileOperations.swift` 零改动
  （`git diff --name-status` 证实）。

## Session Binding

- sessionID: 所有调用显式携带，resolver 只按 `sessionID` 查找。
- active-session dependency: 无。生产与测试 resolver 均不读取
  `activeSession` / `selectedTab`；`Agent/ViewModel` 里的
  `activeSessionProvider` 是 10B 展示层既有代码，与 B3 文件工具无关。
- scope/session match: Router 保留 `readScope.sessionID == sessionID`
  hard gate；不匹配 → `scopeSessionMismatch`，且 resolver lookup = 0。
- A/B isolation: 两个 fake 远端分别绑定 A/B；`sessionID=A` 只触发 A
  client，B client 调用计数 = 0；切 "active" 到 B 不改变结果（§76）。
- closed session: resolver 返回 nil → `sessionUnavailable`；
  不 fallback 其它 session / 本地 FS，不自动重连（§9/§78）。
- reconnect behavior: 无。B3 代码不含任何 connect / authenticate /
  resolveHostTrust 调用（§109）。

## Remote CWD / Scope

- OSC7 authoritative: `source=osc7 / confidence=authoritative`。
- sessionDefault approximate: `source=sessionDefault /
  confidence=approximate`，`allowedRoots=[]`（§17）。
- root creation: `AgentReadScope.makeRemote`（新增异步工厂，B1 同步
  `make` 语义未改）。只有 authoritative 才建 root。
- root canonicalization: 经**服务端** `sftpRealpath`（§16/§21），
  不使用 `FileManager` / `realpath()` / `resolvingSymlinksInPath()`。
- relative authoritative: 允许，先 join 再服务端 canonicalize 再
  containment。
- relative approximate: `cwdUnavailable`，绝不 fallback SFTP `.` /
  远端 HOME / sessionDefault（§18）。
- absolute inside: canonical target 在 root 内 → 允许。
- absolute outside: `outsideAllowedReadScope`（§19）。

## Remote Path Security

- canonicalizer: `AgentRemotePathResolver` + 服务端 `sftpRealpath`。
- lexical normalization: `lexicalNormalize`（`.` / `..` / 重复 `/`）
  只作预处理，绝不作为安全边界（§22）。
- realpath: 既有 `sftpRealpath` 语义；不存在 → `pathNotFound`，
  broken symlink → `pathNotFound`，权限 → `permissionDenied`
  （§23：本阶段只处理已存在 target，无本地 nonexistent-tail walker）。
- dot-dot: 词法折叠后仍由服务端 canonicalize，最终按 canonical 判定。
- symlink inside: canonical target 在 root 内 → 允许（§25）。
- symlink escape: canonical target 越界 → `outsideAllowedReadScope`，
  词法前缀绝不放行（§24）。
- directory symlink escape: `list_directory("link-out")` 同样拒绝（§26）。
- nonexistent: `pathNotFound`。
- permission: `permissionDenied`。

## list_directory

- backend: `AgentRemoteReadOnlyFileService.listDirectory`。
- SFTP APIs: `sftpRealpath` → `sftpStatFile` → `sftpListDirectory`。
- max entries: 500。
- truncated: `totalEntryCount > 500` → `truncated = true`。
- ordering: directory(0) → symbolicLink(1) → file(2) → other(3)，
  同类型按 UTF-8 字节序（复用 B2 `lexicographicLess`），与 locale 无关。
- hidden files: 不过滤（`.hidden` / `.env.example` 正常返回）。
- file type: `.file` + `sizeBytes`。
- directory type: `.directory`，`sizeBytes = nil`。
- symlink metadata: lstat 语义，`kind = .symbolicLink`（§21/§30）。
- outside scope: `outsideAllowedReadScope`。
- 非目录: `notADirectory`（先 stat 判定，不等 list 失败后退化，§44）。

## read_file

- backend: `AgentRemoteReadOnlyFileService.readFile`。
- SFTP APIs: `sftpRealpath` → `sftpStatFile` → `sftpOpenFileForRead`
  → `sftpReadFileChunk` × N → `sftpCloseFileHandle`。
- open mode: 既有 `sftpOpenFileForRead`（`SSH_FXF_READ`）；façade 不暴露
  write / create / truncate / append 标志（§35）。
- bounded read: 64 KiB 分块，`wanted = 256 KiB + 8` 即止，累计有界
  （§37/§73）。
- max bytes: 256 KiB（UTF-8 bytes）。
- original size: `sftpStatFile` 的 `sizeBytes`。
- bytes returned: 截断后文本的实际 UTF-8 字节数。
- truncated: `bytesReturned < originalSize`。
- UTF-8: 复用 B2 `AgentUTF8Truncator`（`utf8PrefixBoundary` +
  `decodeStrictUTF8`）。
- split-codepoint chunks: 只在**累计**载荷上判定，逐块不校验；
  chunkSize=3 时 `F0 9F 98` / `98 80` 仍正确解码 😀（§40/§72）。
- binary: NUL → `binaryUnsupported`；非法 UTF-8 → `binaryUnsupported`
  （§42，绝不 base64 / hex）。
- regular-file requirement: 非普通文件 → `notAFile`（含目录）。
- symlink behavior: canonical target 在 root 内且为普通文件 → 允许。
- handle cleanup: open 成功后所有退出路径（成功 / binary / 非法 UTF-8 /
  取消 / 断连 / 权限）都执行 `closeFile`；测试断言
  `closeCount == openCount`（§39/§75）。

## Cancellation / Disconnect

- before start: service 首个 `Task.checkCancellation()` 在 resolve 之前；
  取消 → `cancelled`，canonical 调用数 = 0（§48，已断言）。
- waiting gate: fake 的 canonicalize 闸门支持取消唤醒；唤醒后立刻
  `checkCancellation` → `cancelled`，句柄计数 0（§49）。
  生产侧：既有 SFTP 操作在持门后第一个 `validateSFTPOperation` 即
  `Task.checkCancellation()`，不会无限排队。
- during read: 分块循环每块前后 `checkCancellation` → `cancelled`
  + 关闭句柄（§50，已断言 `open == close == 1`）。
- late cancellation: Router 在派发返回后再次 `checkCancellation`（§51）。
- disconnect: `SFTPError.connectionLost` → `AgentRemoteFileError
  .connectionLost` → `sessionUnavailable`；读中途断连同样
  `sessionUnavailable` 且句柄关闭（§47）。
- handle cleanup: 已断言；无泄漏。
- deadlock: 无。全量 247 s 完成，无新 hang（§131）。

## PTY Coexistence

- same SSHConnection: 是（Agent SFTP 与 interactive shell 共用同一
  `SSHConnection` actor）。
- SFTP gate: 同一 FIFO 串行门，Agent 与 Files/Transfer 同一边界。
- shell responsiveness: 真实用例 `AgentRemoteRealSFTPTests
  .testRealPTYCoexistenceAndNoCWDMutation`（本轮因缺少已授权测试密钥
  自跳过，见 Findings P3）。
- shell channel: Agent 代码不含任何 channel 操作（不 open / 不 write /
  不 close / 不 resize），`hasOpenShellChannel` 在真实用例中断言。
- command injection: 无。`TerminalCommandDispatcher` / `pasteText` /
  `send(data:)` / `send_to_terminal` 在 `Services/Agent` 命中 0
  （唯一命中是 AgentViewModel 的文档注释）。
- cwd mutation: 无；真实用例对比 Agent read 前后 `pwd` 输出。

## Router

- Local behavior: 未改变（`AgentToolRouter` Local 分支与 B2 同路径）。
- Remote behavior: `listDirectory` / `readFile` 的 `.remoteSSH` 分支
  走 `remoteServiceResolver?.remoteFileService(for: session.id)`，
  不可用 → `sessionUnavailable`。
- resolver: `AgentRemoteReadOnlyServiceResolving`（协议）+ 生产
  `SessionManagerAgentRemoteServiceResolver`；测试注入 fake。
- session mismatch: `scopeSessionMismatch`（hard reject）。
- unknown tool: `unknownTool`。
- cancellation: 派发前后各一次 `checkCancellation`。

## Provider Boundary

- request body: 仍只有 `model` / `input` / `stream`
  （`AgentProviderToolGateTests` 三条断言全绿）。
- tools: 无。
- tool_choice: 无。
- function_call parsing: 无（`Agent/Provider` 内
  `function_call` / `tool_call` 命中 0）。
- AgentViewModel router wiring: 无（`AgentViewModel` 中
  `AgentToolRouter` / `AgentRemoteReadOnly` 命中 0）。
- Tool UI: 无新增；`AgentSidebarView` / `AgentToolCardView` 未改动。
- Provider Tool Calling enabled: 否。

## Security Audit

- Process: 0（§63）
- NSTask: 0
- SSH exec: 0（`libssh2_channel_exec` / `requestExec` /
  `runRemoteCommand` / `run_command` 全 0）
- Terminal injection: 0
- SFTP writes: 0（B3 生产文件对 `sftpWrite*` / `sftpRename*` /
  `sftpUnlink*` / `sftpCreateDirectory` / `openTemporaryFileForWrite`
  命中 0）
- upload / rename / unlink / mkdir / chmod / truncate: 全部 0
  （仅注释中出现禁止清单说明）
- credential reads: 0（`Agent/Tools` 无 `CredentialService` /
  `KeychainService` / `privateKey` / `passphrase`）
- Keychain: 0
- logs: B3 新文件 0 处 `Logger` / `AppLogger` / `print` / `NSLog` /
  `os_log`；底层既有 SFTP 日志未新增内容日志
- persistence: 0（无 `UserDefaults` / SwiftData / 文件 / 剪贴板写入）
- Provider egress: 0（结果只在 `AgentToolResult` 内存生命周期）
- real secrets: 0（B3 文件与测试无 key / token / Bearer / 私钥字面量）

## Tests

### B3（新增 86）

- remote path resolver: `AgentRemotePathResolverTests` 26
- remote file service: `AgentRemoteFileServiceTests` 38
- remote router: `AgentRemoteRouterTests` 11
- real SSH focused: `AgentRemoteRealSFTPTests` 11（本轮全部自跳过）

覆盖：路径解析（§68）、symlink（§69）、list（§70）、read（§71）、
UTF-8 跨块（§72）、大文件有界（§73）、二进制（§74）、句柄清理（§75）、
A/B 隔离（§76）、scope session 不匹配（§77）、关闭会话（§78）、
取消（§48–§51）、断连（§47）、scope 冻结（§55）。

### B2 Regression

`AgentTerminalContextTests` / `AgentLocalFileServiceTests` /
`AgentToolRouterTests` / `AgentUTF8TruncatorTests` /
`AgentPathResolverTests` / `AgentReadScopeTests` 全绿。

说明：B2 的 `testRemoteReadFileIsUnsupported` /
`testRemoteListDirectoryIsUnsupported` 两条按 §52 更新为
「无可用 Remote 服务 → `sessionUnavailable`」，P1 语义（绝不用本地
FileManager 读同名路径）保持不变。

### B1 Regression

`AgentCWDTests` / `LocalShellOSC7Tests` / `LocalShellLauncherTests`
全绿。

### SFTP Regression

`SFTPSessionTests` / `SFTPFileOpsTests` / `SFTPServiceTests` /
`TransferManagerTests` / `SFTPTransferTests` / `SFTPLargeFileTests` /
`TransferQueueTests` / `TransferQueueRealTests` /
`TransferResourceTests` / `RemotePathTests` 全绿。

### Provider Regression

`SSEEventParserTests` / `OpenAIResponsesProviderTests` /
`DeepSeekResponsesProviderTests` / `AgentProviderSettingsTests` /
`AgentViewModelTests` / `AgentConversationStoreTests` 全绿。

### Real SSH Focused

本轮 **未执行**（见 Findings P3）：11 条用例全部由 XCTest 自身
`XCTSkip` 跳过，不影响失败计数。

## Test Universe

- B2 baseline discovered: 754
- B3 added: 86（75 离线 + 11 真实）
- discovered: 840
- executed: 839
- passed: 714（839 − 125 skipped）
- failed: 0
- skipped: 125（B2 114 + B3 真实 11）
- externally excluded: 1
  （`SessionManagerTests/testO_CloseWhileConnectingCancelsConnection`，
  既有 P3，行为未变化）
- count explanation:
  `754 + 86 = 840`；`840 − 1 排除 = 839 executed`；
  `839 − 125 skipped = 714 passed`；
  B2 639 passed + B3 75 离线 = 714 ✓；B2 114 skipped + B3 11 = 125 ✓

## Debug

- DerivedData: `/tmp/MacSSH-Phase10D-B3-Debug`
- result: `** TEST BUILD SUCCEEDED **` + 全量
  `Executed 839 tests, with 125 tests skipped and 0 failures`
  （日志 `/tmp/macssh-b3-full3.log`）
- production warnings: 0（B3 新增生产文件 0 warning）
- test warnings: 仅既有（B2 前已存在）
  `TerminalCommandDispatcherTests` / `SavedCommandStoreTests` /
  `CommandHistoryStoreTests` / `TerminalAppearanceTests` /
  `AgentProviderSettingsTests`

## Release

- DerivedData: `/tmp/MacSSH-Phase10D-B3-Release`
- result: `** BUILD SUCCEEDED **`
- warnings: 0

## Files

### Added（生产）

- `MacSSH/Services/Agent/Tools/AgentRemoteReadOnlyFileClient.swift`
- `MacSSH/Services/Agent/Tools/AgentRemotePathResolver.swift`
- `MacSSH/Services/Agent/Tools/AgentRemoteReadOnlyFileService.swift`
- `MacSSH/Services/Agent/Tools/AgentRemoteServiceResolver.swift`

### Added（测试）

- `Tests/SSH/AgentRemotePathResolverTests.swift`
- `Tests/SSH/AgentRemoteFileServiceTests.swift`
- `Tests/SSH/AgentRemoteRouterTests.swift`
- `Tests/SSH/AgentRemoteRealSFTPTests.swift`

### Modified

- `MacSSH/Services/Agent/Tools/AgentToolRouter.swift`（Remote 分流）
- `MacSSH/Services/Agent/Tools/AgentToolModels.swift`
  （`supportsRemoteSession` 四工具全 true + 文档）
- `MacSSH.xcodeproj/project.pbxproj`（新文件登记）
- `Tests/SSH/AgentToolRouterTests.swift`（两条 Remote 断言按 §52 更新）

### Bottom-Layer SSH/SFTP Modifications

- 无。既有只读 API（`sftpRealpath` / `sftpStatFile` /
  `sftpListDirectory` / `sftpOpenFileForRead` / `sftpReadFileChunk` /
  `sftpCloseFileHandle` / `openSFTPSubsystemIfNeeded`）已满足全部需求，
  无需任何窄扩展。

### Known Untracked Docs

- `Docs/Phase10D-B1-R-Final-GUI-Evidence.md`
- `Docs/Phase10D-B2-Terminal-Context-Local-Read-Tools.md`
- `Docs/Phase10D-B2-R-Test-Universe-Secret-Audit.md`
- `Docs/Phase10D-B3-Remote-SFTP-Read-Only-Tools.md`（本文件，未 stage）

### Unexpected

- 无。
- 注：`git diff --check` 报 `project.pbxproj:1530: new blank line at
  EOF`，经与 `/tmp/macssh-phase10d-b3-before.patch` 比对，该空行由
  **B1/B2** 引入（基线 patch 同一 hunk 已含），非 B3。

## Findings

### P1

- count: 0

### P2

- count: 0

### P3

- count: 2
- 1. **Real SSH focused acceptance 未执行（环境/审批阻断）**：
     本机 127.0.0.1:22 可达，但测试私钥 `/tmp/macssh_phase6_ed25519`
     不存在；生成新密钥需写入 `~/.ssh/authorized_keys`、复用既有已授权
     临时密钥需读取 `~/.ssh`，两次请求均未获用户审批（提示超时），
     故 11 条真实用例全部由 XCTest 自跳过。
     **这不是代码缺陷**：B3 真实路径（realpath / stat / open / read /
     list / PTY 共存 / 断连）已实现并有断言，待拿到测试密钥重跑
     `-only-testing:MacSSHTests/AgentRemoteRealSFTPTests` 即可取证。
- 2. `SessionManagerTests/testO_CloseWhileConnectingCancelsConnection`
     （既有 P3，行为未变化，继续外部排除）。
     附带观察：本轮一次全量运行中
     `AgentCredentialServiceTests/testDeleteRemovesKey` 因 Keychain
     授权等待卡住 >880 s（B2-R 与最终重跑均正常通过，属环境抖动）。

## Decision

PASS — 0 P1 / 0 P2

补记：Real SSH 聚焦取证为 outstanding item（P3，非阻断），
建议在可取得临时测试密钥的环境下补跑
`AgentRemoteRealSFTPTests` 后再进入 B4。
