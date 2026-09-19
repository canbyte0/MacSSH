# Phase 10F-B2-S1 — SwiftTerm Local Input Transport Foundation

## MacSSH Baseline
- path: /Users/msl/msl_coding/MacSSH
- branch: feature/macssh-1.1-agent-terminal-mutation
- HEAD: e958750643aeb9992d4cb357e91dc084130224eb
- B1 candidate changed: NO（preflight 与 postflight untracked 清单逐项一致：`MacSSH/Services/Agent/TerminalMutation/` 6 文件 + `Tests/SSH/AgentTerminalMutation*` 6 文件 + 16 个 Docs untracked；`M MacSSH.xcodeproj/project.pbxproj` 为会话开始前既有状态）
- Package.resolved: 40d473b1fdb456d49cc04b7f253277fcb9ac3987（UNCHANGED，`git diff HEAD` 对该文件为空）
- staged: 0
- commit: NONE
- push: NONE

## SwiftTerm
- path: /Users/msl/msl_coding/MacSSH/ThirdParty/SwiftTerm-fork
- starting branch: macssh-vs16-one-cell-render-fit
- starting revision: 40d473b1fdb456d49cc04b7f253277fcb9ac3987
- ending branch: macssh-agent-local-input-transport
- ending revision: 40d473b1fdb456d49cc04b7f253277fcb9ac3987（未 commit）
- staged: 0
- commit: NONE
- push: NONE

## Existing Transport
- old send primitive: `LocalProcess.send(data:)` → 静态便捷方法 `DispatchIO.write(toFileDescriptor: childfd, data:, runningHandlerOn: .global, handler:)`（LocalProcess.swift:229，原行号）
- existing channel: `io: DispatchIO?`，`DispatchIO(type: .stream, fileDescriptor: childfd, queue: dispatchQueue, cleanupHandler:)`，仅用于 read（`io.read(offset: 0, length: readSize, queue: readQueue, …)`）
- channel type: DispatchIO stream（forkpty 主端 PTY master fd；`#if false` 的 Subprocess 路径未编译）
- issue: send 走静态 write 与 `io` channel 互不相关；无 accepted-prefix（errno 时仅 print）；无跨源排序；无事务；handler 用裸 `childfd` 整数

## New Transport
- authority type: `LocalProcessInputTransport`（新增 `Sources/SwiftTerm/LocalProcessInputTransport.swift`）——单 FIFO 调度器 + 每 incarnation 一个 `LocalProcessInputChannel`（持 `DispatchIOLocalProcessInputWriteBackend` → 现有 `io: DispatchIO` 实例）。仅一条物理写路径：`io.write(offset: 0, data:, queue:, ioHandler:)`；静态 `DispatchIO.write(toFileDescriptor:)` 路径已移除
- serialization: 唯一串行 `authorityQueue`（label `SwiftTerm.LocalProcessInputTransport`）；全部可变状态（currentChannel/channelClosed/processAvailable/mainFIFO/heldFIFO/activeTransaction/inFlight）仅在该队列触碰；无其他锁；队列块从不同步等待自身（无死锁路径）
- ordinary send path: `send(data:)` → `enqueueOrdinarySend(data, onSettled:)` → FIFO（fire-and-forget 语义不变，无新必答错误；debugIO 前置，不默认记录 payload）
- acknowledged path: `write(_:completion:)` / `write(_:) async -> LocalProcessInputWriteResult`（result = requestedBytes/acceptedBytes/error；error 集 = processUnavailable / writeFailed(errno:) / cancelled / channelClosed / transactionUnavailable，均为通用 transport 语义）
- exclusive transaction: `withExclusiveInputTransaction { writer in … }`；writer.write(_ forceWhenCancelled:) 返回 result 不抛错，由调用方决定 repair；transport 不自造 repair 字节、不知 bracketed paste/submit/Agent；同时只允许一个事务（存在 active 或 pending begin 时第二次获取立即 `.transactionUnavailable`）
- process binding: 事务 begin marker 处理时绑定当时存在的 `LocalProcessInputChannel` 实例（强引用，含 backend 与 DispatchIO）； incarnation 更替 = 新 channel 对象 + 递增 generation
- fd-reuse protection: 身份 = channel 对象生存期，从不比较 Int32 fd；旧事务写在新化身下因 `state.channel !== currentChannel` 落 `.channelClosed`（有确定性测试）

## Accepted Prefix
- source: accepted = requested − backend 每次回调报告的 remaining（DispatchIO write handler `(done, remaining, errno)`；Swift overlay 三参签名）；queued ≠ accepted
- progress: remaining 必须单调非增；违反按 last known-good 保守结算（`.writeFailed`）；`debugProgressHook`（internal，测试专用）逐次记录 (requested, acceptedSoFar)，测试断言 [4,4,7,10] 证明无重复计数
- positive-prefix error: `1-byte prefix + EIO` → accepted=1 + `.writeFailed(EIO)`（测试 testPositivePrefixPlusError）
- full success: remaining==0 && errno==0 && done → error=nil
- cancellation: Task 取消 → 后续 writer.write 返回 `.cancelled`（accepted 0）；已 in-flight 物理写不回滚，自然结算后报告精确 prefix；调用方可 `forceWhenCancelled: true` 显式请求 repair 写；transport 不发明 repair 字节

## Ordering
- ordinary vs ordinary: 单 FIFO 串行、一次一个 in-flight 写；两并发 write 均整单元落地、无部分交错（testTwoOrdinarySendsBothSettleFully）
- ordinary vs transaction: begin 为 FIFO marker——事务开始前排队的 ordinary 先写；事务期间 admitted 的 ordinary 进 heldFIFO，事务终止（正常 end / process exit / channel close）后按 admission 序释放；end marker 处理时 `mainFIFO = heldFIFO + mainFIFO` 保证先来先服务（A B C D 与 B1 B2 U 两个确定性测试）
- multi-write transaction: 事务写互为 FIFO 相邻单元，不被 ordinary 插入
- repair window: 事务保持至调用方结束；`.cancelled` 后 `forceWhenCancelled` 写入成功（"ONER" 测试）
- interleaving possible: NO（结构上：ordinary 在 active transaction 期间只能进 heldFIFO）

## Lifecycle
- process exit: `childStopped()` → `processStopped()`：processAvailable=false，排队与 held 单元按 `.processUnavailable` 结算，活动事务自动终止（failReason=.processUnavailable）；in-flight 写保留至经仍开启的 channel 自然结算（精确 prefix）——无饥饿、无泄漏
- terminate: `terminate()` → `channelWillClose()` 后再 `io?.close()`/`childfd=-1`/kill
- channel close: `channelWillClose()`（terminate/deinit）：channelClosed=true，活动事务自动终止，in-flight 写即刻以 `.channelClosed` + `requested − lastRemaining` 结算（settled 标记使 backend 迟到回调被忽略），全部排队/held 单元 `.channelClosed` 结算
- continuation settlement: 每路径恰好一次（op.settled / begin continuation 单 resume / enqueue 前失败短路）；`SWIFT TASK CONTINUATION MISUSE` 零出现；channel close 后 adopt 新 backend 即可恢复可用（测试验证）
- main-thread blocking: 无阻塞调用进入主线程；`send`/`write` 均 queue.async 入队；acknowledged API 为挂起等待（无 busy-wait）

## Tests
### Focused
- command: `swift test --filter LocalProcessInputTransportTests`（SwiftTerm-fork，macssh-agent-local-input-transport）
- executed: 19
- passed: 19
- skipped: 0
- failed: 0（连跑 3 次，全部 0 failed，无 flake）

### SwiftTerm Full
- command: `swift test`（SwiftTerm-fork）
- executed: 884（XCTest 99 + Swift Testing 785）
- passed: 881
- skipped: 3（Swift Testing `KittyKeyboardAppKitReproductionTests` 3 例，环境性 self-skip，与本阶段无关）
- failed: 0（`Test run with 785 tests in 67 suites passed after 10.034 seconds`；XCTest `All tests … 0 failures`）

### Real PTY
- fixture: `/bin/cat`（`LocalProcess.startProcess(executable: "/bin/cat")`，forkpty + 默认环境，不触用户 shell 配置/文件）
- result: PASS ×2 —— ① `testRealPtyByteOrderOrdinaryAndTransaction`：send("A") + 事务写 "B","C" + send("D") → 子进程观测流前 4 字节 == "ABCD"（发送序==接收序）；② `testRealPtyTransactionWriteFailsAfterTerminate`：terminate 后事务写返回 `.channelClosed/.processUnavailable` 通用失败，body 正常结束、无挂起

## Regression
- output path changed: NO（read 循环/backpressure/pendingChunks/process 监控/window resize/UTF-8 feed 未触碰）
- renderer changed: NO（AppleTerminalView/Metal/renderer 文件零改动）
- VS16 changed: NO（one-cell glyph fit / RasterContainmentTests 原样通过）
- MacSSH candidate changed: NO

## Files
### SwiftTerm Added
- `Sources/SwiftTerm/LocalProcessInputTransport.swift`（新：transport authority、backend seam、channel incarnation、事务模型、公共 result/error）
- `Tests/SwiftTermTests/LocalProcessInputTransportTests.swift`（新：19 个确定性用例 + FakeInputBackend seam + real PTY）

### SwiftTerm Modified
- `Sources/SwiftTerm/LocalProcess.swift`（+29/−19：①新增 `public let inputTransport`；②`send(data:)` 改路由共享 authority（对外语义不变）；③`childStopped()` 通知 `processStopped()`；④`deinit`/`terminate()` 先 `channelWillClose()`；⑤`startProcessWithForkpty` 创建 io 后 `adopt(io:)`。移除静态 `DispatchIO.write(toFileDescriptor:)` 并行写路径）

### MacSSH Added/Modified by B2-S1
- NONE

### Unexpected
- NONE（代码范围之外仅：对象库修复条目见 P3-4）

## Audits
- secrets: PASS（测试仅 "ABCD"/"B1B2U" 等无害本地字节 fixture；无凭证/主机/私钥/API key）
- payload logging: PASS（默认无输入字节日志；`data` 内容打印仅存于既有 debugIO 显式开关内；错误仅输出 errno）
- whitespace: PASS（`git diff --check` clean）
- staged: 0（两仓库）

## Findings

### P1
- count: 0
- items: —（无键盘字节可插入事务、无化身重定向、无 reused-fd 穿透、无默认 payload 日志、无 Agent 语义入 SwiftTerm、send_to_terminal 未接线）

### P2
- count: 0
- items: —（prefix 由 remaining 推导；正 prefix 错误如实报告；共享排序确定性；旧 send 并行路径已消除；无死锁/双 resume/泄漏/主线程阻塞/busy loop；SwiftTerm 全量 0 failed；renderer/VS16 未动；Package.resolved 未动；B1 候选未动）

### P3
- count: 4
- items:
  1. 已在途 DispatchIO 物理写不可回滚——取消/终止语义为其结算后报告精确 prefix（冻结的保守语义，测试覆盖）
  2. 真实 PTY 无法确定性复现 0/N-byte 短写与延迟完成——由 `FakeInputBackend` seam 覆盖（§24 允许）
  3. MacSSH 尚未消费新 API（本阶段不 pin、不接线、不实现 send_to_terminal）
  4. 环境预置：SwiftTerm 仓库 `.git/objects/info/alternates` 指向已删除路径（`/Users/msl/msl_code/Ter/build/DerivedData/...`），origin 同样失效，且 `.git/objects/info/commit-graphs` 缓存引用缺失对象（`git fetch` 修复因 delta 基对象缺失不可行，均未改动）。`git diff/status` 所需缺失 blob `b65b1b1`（LocalProcess.swift 原内容）已按字节精确重建（`git hash-object` == `b65b1b1…`，哈希验证）写回对象库后 diff 审计恢复；stderr 仍残留 alternates 告警（git 退出码 0，不影响 status/diff 结果）。建议独立维护动作：清 alternates/commit-graph 并从 github remote 重克隆或全量 fetch

## Decision

PHASE 10F-B2-S1 FINAL PASS

- SwiftTerm Local acknowledged input transport: IMPLEMENTED
- Shared keyboard/mutation ordering: IMPLEMENTED
- Exclusive input transaction: IMPLEMENTED
- Exact accepted-prefix accounting: IMPLEMENTED
- One-incarnation binding: IMPLEMENTED
- MacSSH integration: NOT YET PERFORMED

NO COMMIT.
NO PUSH.

READY FOR INDEPENDENT ACCEPTANCE.

STOP.
