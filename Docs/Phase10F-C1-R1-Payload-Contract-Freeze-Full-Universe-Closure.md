# Phase 10F-C1-R1 — Payload Contract Freeze + Full-Universe Accounting Closure

Date: 2026-09-17
Branch: `feature/macssh-1.1-agent-file-mutation`
Scope: FileMutation domain/validation/tests only（R1 关闭 C1 验收 P2-1 payload 契约溯源 与 P2-2 全量算术对账）

---

## 1. Repository

- repo: `/Users/msl/msl_coding/MacSSH`
- branch: `feature/macssh-1.1-agent-file-mutation`
- HEAD: `57f85c9556bd9cb1b06117d2d5be2b9db9c14b5c`（与 C1 交付一致，未移动）
- staged: 0
- tracked diff: 仅 `MacSSH.xcodeproj/project.pbxproj`（44 insertions = C1 40 + R1 4 行测试注册）
- `git diff --check`: clean
- commit: NO；push: NO；merge/tag/release: NO

## 2. Prior Payload Provenance（P2-1 溯源审计）

对已验收 Phase 10F 文档逐项检索 `256 KiB / 262144 / payload size / text-only / UTF-8 / binary / base64 / write_file schema`，命中先验决策（全部出自已验收的 `Docs/Phase10F-A-Mutation-Tools-Architecture.md`，10F-A-R3 ARCHITECTURE PASS）：

| 出处（精确位置） | 先验决策内容 |
|---|---|
| §Limits（冻结），第 309–313 行 | content type：**UTF-8 text only**；binary / base64：**首版排除**；maximum size：**256 KiB**（与 read_file 上限对称；「常量冻结，模型不可协商」） |
| R1 保留清单，第 596 行 | 「64 KiB / 256 KiB 上限 … write_file 概念、**UTF-8 only、binary/base64 排除** …」全部保留不变 |
| R2.18 保留清单，第 810 行 | 「content **256 KiB**；**UTF-8 text only**」逐项确认不变 |
| R3.13 保留清单，第 1052 行 | 「**UTF-8 text only；256 KiB 上限；binary/base64 排除**」全部维持 |
| Architecture Decisions #7，第 1152 行 | `write_file` schema `{"path","content"}`，required both，additionalProperties false |
| Architecture Decisions #13，第 1158 行 | 「file size limit：**256 KiB；UTF-8 text only；binary/base64 排除**」 |

**结论**：256 KiB 上限、UTF-8 text only、binary/base64 排除的先验已验收 provenance **存在**（10F-A §Limits 及 R1/R2/R3 三次保留清单确认）。未被先验显式覆盖的两点——**空 payload（0 bytes）合法性**与 **domain 层文件内容 NUL 语义**——由 C1-R1 作为显式独立架构决策冻结（见下节）。

另注：10F-A 第 312 行「写入前校验 content 为合法 UTF-8 且不含 NUL」属于 `write_file` **工具注册面**（C2+ 才注册）的校验要求；C1 域层契约按 R1 任务书 §10 冻结为「文件内容 NUL 合法且精确保留，不继承终端输入的 C0 限制」。该工具面/域面区分记录在案，工具面 NUL 校验问题顺延至 C2 注册验收裁决。

## 3. Frozen Payload Contract（R1 显式独立架构决策）

自本报告起，Phase 10F-C 全阶段 payload 契约冻结为：

- **content type**：TEXT ONLY
- **encoding**：exact UTF-8；authority 是 `Data(content.utf8)` 的精确字节
- **allowed size**：`0...262144` bytes（含两端）
- **empty payload**：ALLOWED（空 String 合法；future C2 据此创建空文件）
- **max**：256 KiB exactly
- **binary / base64**：NOT SUPPORTED in Phase 10F-C；binary file mutation DEFERRED
- **字节语义（零归一化）**：无 trim、无换行归一化、无 Unicode NFC/NFD 归一化、无 BOM 插入、无行尾改写、无 locale 转换
- **校验点**：proposal factory（审批之前）按 `utf8.count` 校验；超限 `.payloadTooLarge` 整体拒绝，**绝不截断**
- **NUL 语义**：文件内容中的 NUL 合法且精确保留（不继承 terminal 输入控制字符限制）；**路径**中的 NUL 仍然非法（`invalidPath`）
- **central limit**：`AgentFileMutationLimits.maxPayloadBytes`（256 * 1024）是生产代码中唯一 canonical 定义；源扫描测试 `testPayloadLimitLiteralHasSingleCanonicalProductionDefinition` 持久禁止其余 FileMutation 生产文件携带同值字面量

## 4. Implementation

R1 对生产代码的改动**仅有文档注释**（零行为变更）：

- `AgentFileMutationModels.swift`：`AgentFileMutationLimits` 文档注释升级为完整冻结契约声明（含唯一 canonical 定义声明）。C1 已有行为已正确实现该契约（`Data(content.utf8)` 精确字节、`payloadUTF8.count <= maxPayloadBytes` 守卫在 factory/审批前、拒绝不截断、零归一化、String 构造上即合法 UTF-8）。
- 新增 `Tests/SSH/AgentFileMutationPayloadContractTests.swift`（10 个 focused 测试）。
- `project.pbxproj`：+4 行（新测试文件的 build file / file ref / group child / sources phase 注册）。

C1 候选保全（R1 改动前基线 SHA256）：

```
9314afa6d546cba21a7a5b79bbfc652523985873716b027a0ea93580ba314ebf  AgentFileMutationApproval.swift
d3675047a0d8d6ec894c3cf5a6ca2cf19fd969193844ff12067e73e74db283d7  AgentFileMutationApprovalCoordinator.swift
e688857f78be41d078bc7ca03ca0d6935599c1a205814ea466c0578e5f34df88  AgentFileMutationModels.swift
d84bfa596a8e7eeaec89ccd86917c4e36295c1f51554285151c5d98520e4fa61  AgentLocalFileMutationTargetCapability.swift
0c8e9bca48610088bf1b8b5a4e27374e4ca2cc430c9f951ff4b110d9b35077d5  AgentFileMutationApprovalTests.swift
f544bb3cca6b77d88c099383413507d5306fe73dc9714f1441ca5174c0308129  AgentFileMutationRequestTests.swift
140975d49b760c784457ed471b1bcbf9f198fac3f948f6ae347cff73692a8548  AgentFileMutationSecurityGateTests.swift
b9a8e921673160878713fe8ba011d7798fa23bc5387cb9f3ac794157c159ed93  AgentFileMutationTestSupport.swift
8ff78215b1520cb9c04e272823fbc6df3651067c8fd9cae4f19aec5a5f92d071  project.pbxproj（C1 后）
```

R1 完成后哈希（delta 可审计）：`AgentFileMutationModels.swift` → `17cc34b6140cba7e7bfaee18d56b35b0b18144150d059193b80cad0c1f0f0ce7`（仅注释）；新增 `AgentFileMutationPayloadContractTests.swift` = `eb5c3d1c0df4d27f24a9668e8c669dfc58613d230f7241d82ebbbafbed612ab4`；`project.pbxproj` → `e15e87477150c0630cac80e5a5c452a5f81254b341e69942091a436df43456ce`。其余 3 个生产文件与 4 个 C1 测试文件哈希**逐字节不变**。

## 5. Path / Capability Preservation（未触碰，哈希证明）

- proposal-time CWD 绑定：PRESERVED（`testRelativePathFreezesProposalTimeCWDAndExactUTF8Payload`、`testApprovalRedeemPreservesProposalWorkingDirectoryAfterCWDChanges`）
- 独立 `AgentWriteScope`（logicalSessionID + canonical root + 组件级 containment）：PRESERVED
- parent FD capability：`O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW`，绝不打开 final target：PRESERVED
- dev/inode/token 绑定（`capabilityToken` + `st_dev` + `st_ino`，非 raw FD number）：PRESERVED（`testCapabilityIdentityUsesLifetimeTokenInsteadOfRawDescriptorNumber`）
- create-only / existing-target rejection（file、directory、symlink 均 `destinationAlreadyExists`）/ no overwrite：PRESERVED
- 路径结构拒绝（空、`/` 结尾、`.`、`..`、路径 NUL）不经静默改写：PRESERVED

## 6. Approval / Replay Preservation（未触碰，哈希证明）

- deny：无 redeem，capability 关闭；cancel：无 redeem；claim：单赢家；redeem：单赢家
- sequential replay：第二次 redeem `approvalAlreadyConsumed`
- copy replay（authorization 值复制）：无第二 permit
- concurrent replay（50 并发 redeem）：恰好 1 赢家 + 49 `approvalAlreadyConsumed`
- multiple consumers（异 coordinator）：`targetStale`
- capability lifetime：无 FD-integer 身份、无 pathname retarget、无 double-close（actor 隔离 invalidate 幂等）、无 FD leak

## 7. C1 Focused + Boundary Tests

`xcodebuild test`（-only-testing 4 类）→ `/tmp/macssh-c1r1-focused.xcresult`：**32 passed / 0 failed / 0 skipped**

| Suite | 数量 |
|---|---|
| AgentFileMutationRequestTests | 11 |
| AgentFileMutationApprovalTests | 7 |
| AgentFileMutationSecurityGateTests | 4 |
| AgentFileMutationPayloadContractTests（R1 新增） | 10 |

R1 新增测试逐项覆盖冻结契约：

- 边界：**0 bytes 合法**（空 payload，sha256 of empty data）；**1 byte 合法**；**262144 bytes 合法**（多字节构成：87381×「中」+「a」）；**262145 bytes 拒绝**（`.payloadTooLarge`，绝不截断成成功 request，无文件副作用）
- 字节 vs 字符：87382 字符（< 262144 字符）但 262146 bytes → 按字节拒绝
- Unicode/内容矩阵（13 项逐字节精确冻结 + sha256 校验）：ASCII / 中文 / Emoji（含 ZWJ 序列）/ combining（e+U+0301）/ LF / CRLF / LF+CRLF 混合 / 尾随换行 / 无尾随换行 / **empty** / **embedded NUL** / 显式 BOM / tab
- 零归一化：首尾空白+换行不 trim；NFC「é」与 NFD「e+◌́」两种字节序列各自保留、互不归一；无 BOM 注入（无 BOM payload 不得以 EF BB BF 开头）
- NUL 语义：文件内容 `"a\0b\0"` 合法且逐字节保留（`61 00 62 00`），不继承终端输入 C0 限制；对照路径 `"bad\0name.txt"` → `invalidPath`
- central limit：常量恒等 262144 = 256*1024；源扫描断言其余 FileMutation 生产文件零 magic number

## 8. Stress（C1 候选文件，R1 全量复跑通过）

- **approval concurrency 50/50**：`testFiftyConcurrentClaimsHaveExactlyOneWinner`（50 并发 claim → 1 赢家 + 49 `approvalAlreadyClaimed`）与 `testReplayProtectionHasExactlyOneRedeemWinnerAcrossConsumers`（50 并发 redeem → 1 赢家 + 49 `approvalAlreadyConsumed`）PASS
- **capability lifecycle 100/100**：`testCapabilityLifecycleStressHasNoFDGrowth`（100 次 capture/invalidate，/dev/fd 计数无增长）PASS
- **parent replacement non-retarget 50/50**：`testParentRenameAndReplacementCannotRetargetCapability`（50 次 rename+替换目录，capability 恒指原 directory object）PASS

## 9. Regressions（-only-testing 28 套件）

`/tmp/macssh-c1r1-regression.xcresult`：**422 passed / 0 failed / 0 skipped**

- Terminal mutation（9 suites，132）：Request 7 / Validation 13 / ApprovalCoordinator 22 / ApprovalConcurrency 8 / SecurityGate 14 / Local 17 / Remote 19 / ProviderSendToTerminal 15 / ToolLoopSendToTerminal 17
- Phase 10E command（15 suites，229）：CommandValidation 13 / CommandRequest 11 / CommandApprovalCoordinator 29 / CommandApprovalConcurrency 8 / CommandSecurityGate 7 / LocalCommandExecutor 24+10+19+10 / RemoteCommandBuilder 18 / SSHTransport 27 / RemoteCommandExecutor 20+9+13 / RemoteRouter 11
- **Provider gate（3 suites，50）**：AgentProviderToolCallingTests 20 + AgentProviderToolGateTests 11 + AgentToolRouterTests 19——**tool count = 6**（get_terminal_context / get_current_directory / list_directory / read_file / run_command / send_to_terminal），**write_file NOT REGISTERED**（仅存在于 prohibitedNames），0 failed
- DependencyIdentityTests 11：Package.resolved 锁定 swiftterm `040d1271734694d046b77050b5bfc7aa483423ff`（remote fork canbyte0/SwiftTerm），0 failed

## 10. Full Universe + Blackhole + Arithmetic + xcresult（P2-2 关闭）

**Enumeration**（`xcodebuild test-without-building -enumerate-tests`，`/tmp/macssh-c1r1-enumeration.txt`）：
- **discovered = 1313**（90 个测试类；含 `SessionManagerTests/testO_CloseWhileConnectingCancelsConnection` 与 5 个 AgentFileMutation* 类）

**Full run**（`xcodebuild test`，无任何 `-skip-testing`/排除，无 bypass 旗标，`/tmp/macssh-c1r1-full.log`）：
- result = **Passed**
- **passed = 1173 / failed = 0 / self-skipped = 140**
- executed（selected）= 1313（log 中 1313 条 "Test Case … started"）

**Historical blackhole accounting（§19 无歧义声明）**：

> `SessionManagerTests/testO_CloseWhileConnectingCancelsConnection` = **B. executed and passed**
> （独立探针：单测运行 20s rc=0 TEST SUCCEEDED；全量宇宙内：`Passed 10秒`，xcresult 逐叶核验）

按 §20 规则（现通过则 0 排除）：**external exclusions = 0**，全量运行未使用任何 `-skip-testing`。

**Full arithmetic reconciliation**：

| 量 | 值 | 校验 |
|---|---|---|
| discovered | 1313 | 枚举文件实测 |
| selected/executed | 1313 | = started 计数 |
| passed | 1173 | xcresult summary |
| self-skipped | 140 | xcresult summary（14 个 live SSH/SFTP fixture 套件自跳过：RemoteTerminalTests 23 / SSHConnectionTests 17 / SFTPSessionTests 16 / AgentRemoteRealExecTests 15 / SFTPTransferTests 14 / SFTPServiceTests 13 / SessionManagerTests 11 / AgentRemoteRealSFTPTests 11 / SFTPFileOpsTests 8 / TransferQueueRealTests 5 / SFTPLargeFileTests 4 / TransferResourceTests 1 / TransferManagerTests 1 / CredentialServiceTests 1） |
| failed | 0 | xcresult summary |
| external exclusions | 0 | 黑洞已通过，未使用排除 |

- selected = passed + self-skipped + failed → **1313 = 1173 + 140 + 0** ✓
- discovered = selected + external exclusions → **1313 = 1313 + 0** ✓
- 历史对账：B4-S1 1281 disc / 1280 exec（1 黑洞排除）→ C1 +22 = 1303 disc / 1302 exec / 1163 pass / 140 skip → **C1-R1 +10 = 1313 disc / 1313 exec / 1173 pass / 140 skip / 0 fail / 0 排除**（C1 交付摘要 1303/1163/140/0 与本对账自洽；R1 将其显式化并消灭排除项）

**xcresult**：`/tmp/macssh-c1r1-full.xcresult` 存在、可读（xcresulttool summary + tests 逐叶解析成功）、result = Passed、summary 完整（devicesAndConfigurations / testFailures=空 / runtimeWarnings=空）。

## 11. Debug / Release

| 配置 | 命令特征 | 结果 | 告警 |
|---|---|---|---|
| Debug（clean，`/tmp/macssh-c1r1-dd-build`） | 无 `-skipPackagePluginValidation` / `-skipMacroValidation` | **BUILD SUCCEEDED** | total 0 / production 0 |
| Release（clean，`/tmp/macssh-c1r1-dd-rel`） | 无 bypass 旗标 | **BUILD SUCCEEDED** | total 0 / production 0 |

插件校验经已验收的 GUI 信任指纹（B3-S2-R2 用户手动 Trust & Enable，fingerprint 040d1271…）自然通过；新测试文件与 FileMutation 域编译告警 0。

## 12. Audits

- 禁用 mutation syscall/API（O_CREAT / write / pwrite / ftruncate / mkdir(at) / rename(at/x_np) / link(at) / unlink(at) / remove / fsync / chmod / chown / openat / creat / FileManager.createFile / Data.write / String.write，作用于 4 个 C1 生产文件）：**0 命中**（capability 仅 read-only directory open/fstat/close + lstat/fstatat(AT_SYMLINK_NOFOLLOW) 探测）；`AgentFileMutationSecurityGateTests` 源扫描 gate 同步 PASS
- payload 日志通道（print/NSLog/os_log/Logger/fputs/FileHandle/os_signpost 于 C1 生产源）：**0**；request/authorization/snapshot description 全部 `<redacted>`（`testDescriptionsDoNotLogPayloadOrTargetPath` PASS）
- 硬编码机密（sk-/ghp_/AKIA/PRIVATE KEY/api_key/password 字面量，C1 生产+测试源）：**0**
- magic number 散布：file-mutation payload 上限生产定义恰 1 处（`AgentFileMutationLimits.maxPayloadBytes`）；生产源中其余 `256 * 1024` / `262_144` 常量（AgentUTF8Truncator 终端读取截断、read_file 上限、AgentCommandResult stdout/stderr 捕获上限、SFTPSession readdir 缓冲）均为**其它已验收域的独立限额**，非 payload 契约重复
- `git diff --check`：clean；staged：0

## 13. Files

- **R1 新增**：`Tests/SSH/AgentFileMutationPayloadContractTests.swift`（10 tests）
- **R1 修改（注释级）**：`MacSSH/Services/Agent/FileMutation/AgentFileMutationModels.swift`
- **R1 修改（注册）**：`MacSSH.xcodeproj/project.pbxproj`（+4 行）
- **未触碰（哈希逐字节一致）**：`AgentFileMutationApproval.swift`、`AgentFileMutationApprovalCoordinator.swift`、`AgentLocalFileMutationTargetCapability.swift`、`AgentFileMutationRequestTests.swift`、`AgentFileMutationApprovalTests.swift`、`AgentFileMutationSecurityGateTests.swift`、`AgentFileMutationTestSupport.swift`
- C2 staging directory / temp-file / payload write / fsync / rename/link/unlink / write_file 注册 / file approval UI / Remote file mutation：**均未实现、未触碰**（Hard Scope 遵守）

## 14. Remote Verification

- `github/main` = `e958750643aeb9992d4cb357e91dc084130224eb` ✓
- `github/feature/macssh-1.1-agent-terminal-mutation` = **ABSENT** ✓
- `github/feature/macssh-1.1-agent-file-mutation` = **ABSENT** ✓
- SwiftTerm：`Package.resolved` pin = `040d1271734694d046b77050b5bfc7aa483423ff`（DependencyIdentityTests 断言通过）；构建实际 checkout（SourcePackages/checkouts/swiftterm）= `040d1271…`；`ThirdParty/SwiftTerm-fork-clean` = `040d1271…`（clean）；历史 `ThirdParty/SwiftTerm-fork` @ `40d473b1…` 原样保全（P3）
- push：NO（全程零网络写操作，仅 `git ls-remote` 只读探测）

## 15. P1 / P2 / P3

**P1 = 0**：无用户文件写入/创建/截断/删除；write_file 未注册；parent capability 无 retarget；无多重 redeem permit；无 payload/凭据日志；无 overwrite；无 Remote file mutation。

**P2 = 0**：契约恰为 TEXT ONLY exact UTF-8 `0...262144`（含两端）；零归一化；262144 接受 / 262145 拒绝 / 空 payload 接受；文件内容 NUL 合法（不继承终端输入限制）；全量算术无歧义（1313=1173+140+0；1313=1313+0）；黑洞状态显式（B executed and passed）；xcresult 可读；mutation syscall 0；tool count 6；write_file 未注册；全部回归/全量/构建通过；SwiftTerm 未变；无新增外部排除。

**P3（允许项）**：
1. Remote live fixture 自跳过（140 个 live SSH/SFTP 用例，14 套件）
2. `write_file` Provider 注册 + file approval UI DEFERRED（C2/C4 槽位）
3. 文件副作用引擎（staging/temp/fsync/rename 原子发布）NOT IMPLEMENTED（C1 设计边界）；OVERWRITE DEFERRED；binary file mutation DEFERRED；Remote file mutation DEFERRED；crash/power-loss durability 不在 C1 承诺范围
4. 历史 SwiftTerm 旧检出（ThirdParty/SwiftTerm-fork @ 40d473b1）保全未动

## 16. Decision — PASS Rule Check

P1=0 ✓；P2=0 ✓；payload=TEXT ONLY UTF-8 ✓；bytes=0...262144 ✓；empty=ALLOWED ✓；binary=DEFERRED ✓；normalization=NONE ✓；proposal-time target=PRESERVED ✓；parent capability=PRESERVED ✓；file side effects=NONE ✓；approval/redeem=ONE-TIME ✓；full universe=RECONCILED / 0 failed ✓；historical blackhole=EXECUTED AND PASSED（B）✓；xcresult=READABLE ✓；tool count=6 ✓；write_file=NOT REGISTERED ✓；Debug=PASS ✓；Release=PASS ✓；commit=NO ✓；push=NO ✓。

# PHASE 10F-C1-R1 FINAL PASS

Local file mutation domain: ACCEPTED
Payload contract: FROZEN
Text UTF-8 0...256 KiB: ACCEPTED
Immutable target capability: ACCEPTED
One-time approval/redeem: ACCEPTED
Full test universe: CLOSED
File side-effect engine: NOT IMPLEMENTED
write_file: NOT REGISTERED
Remote file mutation: NOT IMPLEMENTED

NO COMMIT.
NO PUSH.
READY FOR INDEPENDENT ACCEPTANCE.
STOP.
