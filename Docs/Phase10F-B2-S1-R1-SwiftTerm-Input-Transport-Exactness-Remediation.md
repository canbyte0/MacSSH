# Phase 10F-B2-S1-R1 — SwiftTerm Local Input Transport Remediation

Narrow remediation stage for the two P2 findings of the independent acceptance of Phase 10F-B2-S1:

- **P2-1** `channelWillClose()` settled an in-flight write immediately from `lastRemaining` and ignored the late backend callback — the exact accepted prefix could not be proven.
- **P2-2** transaction admission had an unresolved pending-begin window — an ordinary send admitted after the begin marker but before activation could bypass/reorder the transaction.

Scope honored: only `Sources/SwiftTerm/LocalProcess.swift`, `Sources/SwiftTerm/LocalProcessInputTransport.swift`, `Tests/SwiftTermTests/LocalProcessInputTransportTests.swift` were touched. No MacSSH source/test change, no renderer/VS16/Metal change, no Package.resolved update, no commit, no push, no send_to_terminal integration, no Git object-database repair.

## MacSSH
- branch: `feature/macssh-1.1-agent-terminal-mutation`
- HEAD: `e958750643aeb9992d4cb357e91dc084130224eb`
- B1 candidate changed: NO（preflight 与 postflight 均为 1 modified `MacSSH.xcodeproj/project.pbxproj` + 24 untracked（15 Docs、`MacSSH/Services/Agent/TerminalMutation/`、6 `Tests/SSH/AgentTerminalMutation*` 文件），逐项与 preflight 一致）
- Package.resolved: UNCHANGED（`MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 不在 status 中）
- staged: 0
- commit: NO
- push: NO（远端经只读 `git ls-remote --heads origin` 验证：无 `agent-terminal-mutation` 匹配分支）

## SwiftTerm
- branch: `macssh-agent-local-input-transport`
- HEAD: `40d473b1fdb456d49cc04b7f253277fcb9ac3987`
- staged: 0
- commit: NO
- push: NO（origin 指向已删除的 MacSSH DerivedData 路径，`ls-remote` 不可用——已知 P3；本阶段未执行任何 push 动作）

## Exact Close Settlement
- previous behavior: `channelWillClose()` 置 `channelClosed` 后立即用 `op.requested - op.lastRemaining` 结算 in-flight 并标 `settled`，其后的 backend 终态回调被丢弃 —— P2-1（prefix 可能被低估，无法证明精确性）。
- new close barrier: `channelWillClose()` 进入显式 `closing` 状态（`closeRequested = true`）：
  1. 拒绝一切新 ordinary/transaction 写入（admission 层直接失败，accepted = 0）；
  2. 排队未启动单元（mainFIFO + heldFIFO，含 pending begin marker）立即以 `.channelClosed` 失败；
  3. 已启动的 in-flight 物理写**不结算、不释放**，保留于 `inFlight`；
  4. 后续 `io.close()` 强制该写产生终态 backend 回调（DispatchIO close 语义：未加 STOP 时等待/终结未决 I/O 并调用 handler）；
  5. 终态回调（`done || errno != 0`）携带最终 remaining/errno，恰好一次结算该 op；
  6. 迟到的重复回调被 `op.settled` 守卫忽略（无 double resume）。
- in-flight settlement: 仅由该写的终态 backend settlement 触发；close 本身对已启动写**不是**结算事件（测试断言 close 后 continuation 仍 pending）。
- accepted-prefix source: `accepted = requested - finalRemaining`，`finalRemaining` 只来自 backend 对该操作的终态结算；绝不由非终态 progress 回调或 close 推断。四种 case 全覆盖：0 accepted+error、正 prefix+error、full accepted+success（close 前写已完成则如实报成功，不降级）、full accepted+终态 error。
- queued operation settlement: 未启动写立即 `.channelClosed`/失败，accepted = 0（acknowledged 与 fire-and-forget ordinary 双路均测）。
- late callback: 迟到终态回调恰好一次结算；其后的重复回调被忽略（§11 seam：callback1 remaining=9 → close → callback2 remaining=4 → terminal remaining=2+EIO ⇒ accepted = requested−2，明确否决 requested−9 / requested−4）。
- double resume: 无。`op.settled` 单次守卫 + checked continuation 语义双保险；duplicate 回调后 `debugProgressHook` 计数不变（3）。
- deinit/lifetime: **设计 B 冻结** —— `_startWrite` 的 backend handler 由 `[weak self]` 改为强捕获 transport；in-flight 期间即使 LocalProcess（及 transport 最后外部引用）先释放，transport → channel → backend → DispatchIO 链与 handler 强引用保证 transport 存活至终态回调完成精确结算；`io.close()` 保证终态回调必然发生，故引用必然释放。LocalProcess `terminate()`/`deinit` 冻结顺序：`inputTransport.channelWillClose()`（进 closing）→ `io?.close()`（强制终态回调）。无 continuation 因 owner 释放而永久悬挂。

## Pending Transaction Admission
- pending state: 新增 `pendingTransaction: LocalProcessInputTransactionState?`，等价规范要求的 `transactionPending`。
- admission point: `_acquire` 在 authority queue 上准入 begin marker 的那一刻（`pendingTransaction = state` 与 `mainFIFO.append(.begin…)` 同一临界区内完成）。
- ordinary after begin: `enqueueOrdinarySend` 与 `write` 的 held 路由条件由 `activeTransaction != nil` 扩为 `activeTransaction != nil || pendingTransaction != nil` —— begin 准入后、激活前（前一物理写仍在飞行）准入的 ordinary 一律进 heldFIFO，不可能越过事务。
- held FIFO: 单一 heldFIFO（方案 A，更简正确模型）；事务终止时 `mainFIFO = heldFIFO + mainFIFO`，held 内部相对准入次序天然保持，不存在"新 held 插队旧 post-begin 项"的第二队列合并问题。
- multi-held ordering: pending 期 D1、D2 与 active 期 D3 均按准入序入同一 heldFIFO；实测物理序 A B C D1 D2 D3，无倒置。
- transaction failure: 事务写失败后 body 返回 → end marker 合并 heldFIFO，held ordinary 按原准入序恢复执行（实测 B U1 U2）；channel closing 时 held 发送以 accepted = 0 失败而非派发。
- cancellation: 既有冻结 repair 语义未动（取消不回滚 in-flight；`forceWhenCancelled` 仅显式 repair）；事务结束后 held ordinary 仍按准入序恢复；endpoint shutdown 时改为失败。
- interleaving: NONE —— 结构上（begin 准入后所有 ordinary 进 heldFIFO，直到事务终止才合并派发）+ 测试证明（含 begin 仅 pending 期准入的 ordinary），任何 ordinary 键盘/粘贴写字节都不可能物理插入同一事务两写之间。
- second transaction: pending 或 active 任一期间二次获取立即 `.transactionUnavailable`，绝不插入第二个 begin marker（新增 pending 期用例；原 active 期用例保留）。

## Tests
### Focused
- command: `swift test --filter LocalProcessInputTransportTests`
- executed: 27（原 19 全保留，其中 2 个 close 语义用例按新冻结契约修正断言——要求终态回调结算并断言 close 不结算，属加强非削弱；新增 8）
- passed: 27
- skipped: 0
- failed: 0

### Full
- command: `swift test`
- executed: 892（XCTest 107 + SwiftTesting 785 in 67 suites）
- passed: 889
- skipped: 3（KittyKeyboardAppKitReproductionTests 环境性，与 S1 基线一致：reportAlternates…/testKittySharedMemoryBoundsRejected/testKittySharedMemoryLoad）
- failed: 0
- Renderer/VS16 suites: unchanged / 全部 PASS。

### Real PTY
- result: PASS ×2 —— `testRealPtyByteOrderOrdinaryAndTransaction`（/bin/cat 真实 PTY，A（ordinary）→事务 B、C→D，回读序 ABCD，天然覆盖 pending-begin 窗口回归）；`testRealPtyTransactionWriteFailsAfterTerminate`（terminate 后事务写以通用 transport 错误失败）。无用户 shell 启动、无真实用户文件。

## Git Health
- git fsck command: `git fsck --full`（ThirdParty/SwiftTerm-fork，只读）
- exit: 27
- alternates: `error: unable to normalize alternate object path: /Users/msl/msl_code/Ter/build/DerivedData/SourcePackages/repositories/SwiftTerm-74b92343/objects`（已知 P3，未修）
- missing objects: 47 个 upstream tag ref invalid sha1 pointer；dangling 缺失 blob 248、missing tree 18、missing commit 1（历史对象位于死 alternate）；commit-graph 解析失败若干（"failed to parse commit … from object database for commit-graph"）
- commit graph: 引用缺失对象，仅告警，工作区 diff/status/test 不受影响
- object writes performed: NONE（未运行 `hash-object -w`/`replace`/`reset`/`gc`/`repack`/`commit-graph write` 等任何对象写维护）

## Files
### SwiftTerm Added
- 无新增文件（`LocalProcessInputTransport.swift` 与 `LocalProcessInputTransportTests.swift` 为 S1 候选 untracked 文件，R1 在其内修改）

### SwiftTerm Modified
- `Sources/SwiftTerm/LocalProcess.swift`（tracked diff 含 S1+R1 累计：41 insertions / 19 deletions；R1 部分为 terminate/deinit 冻结 close 顺序注释）
- `Sources/SwiftTerm/LocalProcessInputTransport.swift`（S1 候选文件，R1：close barrier + pendingTransaction + `_startWrite` 强捕获 + debug 观测器；生产源码 0 编译警告）
- `Tests/SwiftTermTests/LocalProcessInputTransportTests.swift`（S1 候选文件，R1：2 用例按新契约修正 + 8 新用例）

### MacSSH Changed by R1
- 无

### Unexpected
- 无（SwiftTerm 全量构建日志中仅测试文件 `.get()` deprecation 告警，为既有风格，未扩大）

## Findings
### P1
- count: 0
- items: —

### P2
- count: 0
- items: —

### P3
- count: 5
- items:
  1. SwiftTerm fork 仓库对象库不健康（alternates 死路径 / commit-graph 缺失对象 / 47 tag ref 失效），R1 仅只读取证，未修复 —— 需独立维护动作；
  2. in-flight 物理写不可回滚（冻结语义，保持）；
  3. real PTY 短写场景仍需 fake backend seam 方可确定性驱动；
  4. MacSSH 尚未消费该 transport API（send_to_terminal 仍 prohibited，属后续阶段）；
  5. 测试文件沿用 `.get()`（已 deprecate）风格产生编译告警 —— 表层、不阻塞，可随后续维护统一改 `.value`。

## Decision

PHASE 10F-B2-S1-R1 FINAL PASS

- Exact accepted-prefix close semantics: IMPLEMENTED（close barrier + 终态结算 + 设计 B 生命周期）
- Pending-begin ordering: IMPLEMENTED（pendingTransaction 准入点 + 单一 heldFIFO）
- Exclusive transaction isolation: PROVEN（pending/active 全程无 ordinary 物理穿插；held 序保持）
- focused tests: 27/27, 0 failed
- full SwiftTerm: 892 executed / 889 passed / 3 skipped / 0 failed
- real PTY: PASS
- MacSSH B1 candidate: UNCHANGED
- Package.resolved: UNCHANGED
- commit: NO
- push: NO

SwiftTerm Local transport candidate: READY FOR INDEPENDENT ACCEPTANCE

NO COMMIT.
NO PUSH.

STOP. 不自行授权下一阶段。
