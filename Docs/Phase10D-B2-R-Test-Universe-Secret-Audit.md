# Phase 10D-B2-R — Test Universe + Secret Audit Re-Acceptance

日期：2026-09-11
分支：`feature/macssh-1.1-agent-sidebar`（HEAD `fc07f0f88d69c40a86599c205c4366bbdf670afb`，未移动）
R 阶段生产改动：**0**（`git status --short` 与 R 开始前逐字节一致）

---

## 1. 测试宇宙数量对账

### 1.1 三个数字的来源

| 数字 | 来源 | 值 |
|---|---|---|
| B1 baseline | `/tmp/macssh-10db1-test3.log`（`xcodebuild test`，**无任何 -skip-testing**） | 657 discovered / 114 skipped / 0 failed |
| B2 claimed full run | `/tmp/macssh-b2-full2.log`（`xcodebuild test-without-building` + **12 个 -skip-testing**） | 600 executed / 0 skipped / 0 failed |
| B2 新增 | B2 报告表格声明 | 98（实测 97，见 §1.3） |

### 1.2 差异原因（完整解释）

B2 的全量命令（已从日志 `Command line invocation` 逐字复原）外部排除了 12 个整 suite，
共 **154 个测试**从 test universe 消失：

```
754（B2 完整 universe）
- 154（12 个 suite 被 -skip-testing 整套件排除）
= 600（B2 报告值）
```

而 B1 的 657 是 **未做任何外部排除** 的完整 universe：

```
657（B1 universe，含 114 个 XCTest 自跳过）
+  97（B2 新增，实测）
= 754（B2 完整 universe）
```

**结论：B2 的 600 低于 B1 的 657，不是测试减少，而是 154 个测试被外部整套件排除
（其中 114 个本应由 XCTest 自身 skip 而被一并"消失"，另 40 个本可正常执行）。**

### 1.3 98 vs 97

B2 报告表格的分套件数字与实测不一致（三处各 ±1，净差 1）：

| 套件 | 报告声明 | 实测（日志 / 源码 `func test`） |
|---|---|---|
| `AgentUTF8TruncatorTests` | 16 | **15** |
| `AgentTerminalContextTests` | 29 | 29 |
| `AgentLocalFileServiceTests` | 27 | **28** |
| `AgentToolRouterTests` | 20 | **19** |
| `AgentProviderToolGateTests` | 6 | 6 |
| 合计 | 98 | **97** |

`TerminalRecentOutput*` 无独立套件：其覆盖在 `AgentTerminalContextTests` 内
（`TerminalRecentOutputSnapshotter.snapshot` 直接断言）。

---

## 2. B2 排除的 12 个 suite 逐项分类

计数取自 B1 全量日志（每个 suite 的实际 discovered 数）；
skip 数 = XCTest 自身 guard 触发数；executed = B1 中真正跑起来并通过的数量。

| # | Suite | 总数 | XCTest 自跳 | B1 实跑 | 分类 |
|---|---|---|---|---|---|
| 1 | `SSHConnectionTests` | 32 | 17 | 15 | **混合**：真实 SSH + 4 个纯单测 |
| 2 | `RemoteTerminalTests` | 24 | 23 | 1 | 真实 SSH 集成（未认证 shell 负路径） |
| 3 | `SessionManagerTests` | 28 | 11 | 17 | **混合**：17 个本地会话生命周期普通单测 |
| 4 | `SFTPSessionTests` | 16 | 16 | 0 | 真实 SSH/SFTP 集成 |
| 5 | `SFTPServiceTests` | 13 | 13 | 0 | 真实 SSH/SFTP 集成 |
| 6 | `SFTPFileOpsTests` | 8 | 8 | 0 | 真实 SSH/SFTP 集成 |
| 7 | `SFTPTransferTests` | 14 | 14 | 0 | 真实 SSH/SFTP 集成 |
| 8 | `SFTPLargeFileTests` | 4 | 4 | 0 | 真实 SSH/SFTP 集成 |
| 9 | `TransferManagerTests` | 4 | 1 | 3 | **混合**：3 个离线状态机单测 |
| 10 | `TransferQueueRealTests` | 5 | 5 | 0 | 真实 SSH 集成 |
| 11 | `TransferResourceTests` | 1 | 1 | 0 | 真实 SSH 集成 |
| 12 | `CredentialServiceTests` | 5 | 1 | 4 | Keychain 环境依赖 |
| | **合计** | **154** | **114** | **40** | |

被整套件排除遮蔽的 40 个可执行测试中，至少 **24 个是普通离线/单元测试**：

- `SessionManagerTests` 17 个：`testA_ManagerStartsWithActiveLocalSession` …
  `testM_RequestCloseWithoutConfirmationForFailedSession`、`testU_TwentyLocalSessionCreateCloseCyclesNoLeak`、
  `testV_FiveIdleLocalSessionsNoBusyLoop`、`testAA_TitleNumberingNeverDuplicatesAfterClosingMiddleTab`
  （纯本地会话生命周期 / 标签关闭 / 标题编号 / 泄漏循环，无需 SSH）
- `TransferManagerTests` 3 个：`testA_TaskProgressMonotonicAndSafeSpeed`、`testB_RequestEntryRejection`、
  `testC_ClearFinishedKeepsActiveTasks`（纯状态机）
- `SSHConnectionTests` 4 个：`test_EAGAINBlockDirectionsMapToPollEvents`、
  `test_EAGAINZeroDirectionsUsesBoundedBackoff`、`test_zeroSecretBytesOverwritesArray`、
  `test_zeroSecretBytesOverwritesManualBuffer`（EAGAIN 映射 / 密钥清零，纯单测）

→ 按任务书 §2「禁止整 suite 跳过混合套件」，`SessionManagerTests` / `TransferManagerTests` /
`SSHConnectionTests` 的整套件排除不合规；R 阶段已全部改为纳入。

---

## 3. R 阶段全量运行（preferred full-suite policy）

入口与 B1 baseline 完全一致（同一 project / 同一 scheme `MacSSH` / 同一 Debug 配置 /
`-derivedDataPath` 复用 B2 产物），**零整套件排除**：

```
xcodebuild test -project MacSSH.xcodeproj -scheme MacSSH -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/MacSSH-Phase10D-B2-Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  '-skip-testing:MacSSHTests/SessionManagerTests/testO_CloseWhileConnectingCancelsConnection'
```

- 日志：`/tmp/macssh-b2r-full2.log`
- 结果：**`Executed 753 tests, with 114 tests skipped and 0 failures (0 unexpected) in 123.665 s`**
- `** TEST EXECUTE SUCCEEDED **`
- 逐条计数：passed = 639，skipped = 114，failed = 0（639 + 114 = 753 ✓）
- 114 个自跳过的分布与 B1 baseline **逐套件完全一致**
  （RemoteTerminal 23 / SSHConnection 17 / SFTPSession 16 / SFTPTransfer 14 /
  SFTPService 13 / SessionManager 11 / SFTPFileOps 8 / TransferQueueReal 5 /
  SFTPLargeFile 4 / TransferResource 1 / TransferManager 1 / CredentialService 1）

### 3.1 唯一外部排除项（用例级，非套件级）

`MacSSHTests/SessionManagerTests/testO_CloseWhileConnectingCancelsConnection`

- 复现 1（`/tmp/macssh-b2r-full.log`）：断言失败后**挂死 > 8.5 分钟**无输出
- 复现 2（`/tmp/macssh-b2r-testO.log`，单独 `-only-testing`）：同样断言失败 + 挂死 > 2 分钟
- 失败原因：`TestKeys.nonRoutableHost:12345` 本应停在 `connecting`；当前环境该地址
  被拦截 → `TCP connection established` → `handshakeFailed(libssh2Code: -13)`，
  5 秒内观察不到 `.connecting`
- 性质：**Phase 8 遗留的真实 SSH/blackhole 环境型集成测试**，与 B2 无关；
  B2 未触碰 `SessionManager` / `SSHConnection`；该用例无环境 guard 因而不会自 skip
- 覆盖影响：0 B2 相关覆盖（本地会话 / 文件工具 / Provider 全不受影响）

### 3.2 另一个慢点（未排除）

`AgentCredentialServiceTests.testDeleteRemovesKey`：首次运行触发 Keychain 授权
（B2 记录 700.550 s，本次约 4.5 min），最终 **passed**，不属挂死，故未排除。
`AgentViewModelTests.testSessionADeltasStayInAAfterSwitchToB`（B2 298.6 s）本次正常通过。

---

## 4. 目标回归（全部 0 失败）

| 组 | 套件 | passed |
|---|---|---|
| B2 | `AgentTerminalContextTests` | 29 |
| B2 | `AgentLocalFileServiceTests` | 28 |
| B2 | `AgentToolRouterTests` | 19 |
| B2 | `AgentUTF8TruncatorTests` | 15 |
| B1 | `AgentPathResolverTests` | 28 |
| B1 | `AgentReadScopeTests` | 12 |
| B1 | `AgentCWDTests` | 7 |
| B1 | `LocalShellOSC7Tests` | 4 |
| 10C Provider | `SSEEventParserTests` | 23 |
| 10C Provider | `DeepSeekResponsesProviderTests` | 16 |
| 10C Provider | `AgentViewModelTests` | 19 |
| 10C Provider | `AgentProviderSettingsTests` | 15 |
| 10C Provider | `OpenAIResponsesProviderTests` | 14 |

其余全量套件（含 `TerminalAppearanceTests` 28、`LocalShellLauncherTests` 24、
`AgentCredentialServiceTests` 9、`AgentConversationStoreTests` 11 等）同样 0 失败。

---

## 5. Secret 审计

扫描范围：`git diff fc07f0f`（已跟踪改动）+ 全部 26 个未跟踪 candidate 文件
（`git ls-files --others --exclude-standard`）。
模式：`sk-` / `Bearer` / `Authorization` / `BEGIN … PRIVATE KEY` / `api_key` / `password` / `token` / `secret`。

| 类别 | 命中 | 判定 |
|---|---|---|
| OpenAI API key（`sk-…`） | 0 | 无 |
| DeepSeek API key | 0 | 无 |
| Bearer / Authorization | 1（`ResponsesProviderCore.swift:292`：`"Bearer \(configuration.apiKey)"`） | 运行时请求头拼接，无字面量 |
| 私钥材料 | 0 | 无 |
| password / token 字面量 | 0 | 无 |
| `api_key` 类 | `SettingsView.swift` 本地化键 / `AgentCredentialService` Keychain API 名 / `ResolvingAgentProvider` 运行时读取 / `AgentProviderRequest.swift:9` 警示注释 | 合法 |
| 测试 fixture | `Tests/SSH/AgentLocalFileServiceTests.swift:31`、`AgentPathResolverTests`、`AgentReadScopeTests` 中 `secret.txt` / `"secret"` | 明显 fake（临时目录夹具文件名与内容） |
| 文档 | `Docs/Phase10D-B2-*.md:128` | 文档说明 |

**real secret present：否。**

---

## 6. 数据出境 / 只读 / 远程 / Provider 边界

- Terminal context：`TerminalAgentContextProvider` / `AgentTerminalContext` /
  `TerminalRecentOutputSnapshotter` / `SwiftTermTerminalBufferSource` 的引用仅出现在
  自身目录、测试与 pbxproj；`ResponsesProviderCore` / `AgentViewModel` /
  `AgentSidebarView` **零调用点**（hard gate ✓）
- 日志：`MacSSH/Services/Agent/Terminal/*` 与 `Tools/*` 中
  `Logger` / `AppLogger` / `print(` / `debugPrint(` / `NSLog` / `os_log` **全部 0 命中**（zero logging ✓）
- 持久化：上述文件中 `UserDefaults` / `ModelContext` / `modelContext` 0 命中；
  `FileManager` 仅 `contentsOfDirectory`（listing）
- 只读：`open()` 两处均为 `O_RDONLY`；无 `O_WRONLY` / `O_RDWR` / `O_CREAT` / `O_TRUNC`；
  无 `removeItem` / `moveItem` / `copyItem` / `createDirectory` / `createFile` / `chmod` /
  `rename` / `unlink` / `mkdir`（security hard gate ✓）
- 远程边界：`Agent/Terminal` + `Agent/Tools` 中 `SSHConnection` / `SFTP` / `libssh2` /
  `sftpOpen` / `sftpList` **仅出现在注释**，运行时引用 0 ✓；
  `AgentToolRouter` 对 `.remoteSSH` 且 `!tool.supportsRemoteSession` → `unsupportedForSession` ✓
- Provider 边界：`ResponsesRequestBody` = `model` + `input` + `stream`（三字段，
  `ResponsesProviderCore.swift:31-45`）；Provider 目录内 `tools` / `tool_choice` /
  `function` / `functions` / `function_call` 仅出现在注释，运行时 0 ✓；
  `AgentViewModel` / `AgentSidebarView` 对 `AgentToolRouter` 等 0 引用 ✓

---

## 7. 构建

生产代码自 B2 Debug 构建（2026-09-10 22:50）以来 0 变更
（`find MacSSH -name "*.swift" -newermt "2026-09-10 22:51"` 为空），
因此不重复 fresh Debug / Release：

- Debug = PASS（`/tmp/MacSSH-Phase10D-B2-Debug`，candidate 告警 0）
- Release = PASS（`/tmp/MacSSH-Phase10D-B2-Release`，candidate 告警 0）
- 本轮 `xcodebuild test` 的增量 build 亦 `TEST BUILD SUCCEEDED`

---

## 8. Findings

### P1 — 0

### P2 — 0

（B2 原始证据中「12 个整套件外部排除遮蔽 ≥24 个普通离线单测、且 universe 无法解释」
属 P2 级证据缺陷，**已在本 R 阶段完全消除**：本轮全量 0 整套件排除、数量完全对账。）

### P3 — 3

1. `SessionManagerTests.testO_CloseWhileConnectingCancelsConnection`：环境型（non-routable
   地址被拦截 → libssh2 -13）确定性失败 + 断言失败后挂死。Phase 8 遗留，非 B2 引入；
   已按任务书 §4 用例级排除并单独复现证明。建议后续为 blackhole 类用例补
   `XCTSkip` 环境 guard，并排查断言失败后 `closeSession` 的挂起路径。
2. B2 报告新增测试数声明 98，实测 97；三处分套件数字与源码/日志不一致（±1）。
   建议报告定稿前以日志 discovered 数为准。
3. `AgentCredentialServiceTests.testDeleteRemovesKey` 依赖 Keychain 授权，冷环境耗时
   可达 700 s（B2 实测）/ 4.5 min（本轮），会显著拉长全量时间；本次未排除。
