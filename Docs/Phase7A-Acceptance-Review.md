# MacSSH 1.1 Phase 7A — Independent Architecture Acceptance Report

角色：Independent Architecture Reviewer（非 Phase 7A 原调查者）。

本验收**重新从源码确认**，不依赖调查报告摘要。所有源码主张均经独立读取核实。

---

## 1. Acceptance result

**有条件通过（CONDITIONAL PASS）**。

调查报告的核心技术事实（输入管道、Paste/Execute API、Return 字节、bracketed paste、active session routing、SwiftData schema、History 安全边界）经独立源码核实**全部成立**。报告可进入 Phase 7B，但须先修正下列验收意见（标注 MUST 的为进入 7B 前必须落实的设计/文档补强，非代码改动）。

调查报告本身未修改任何生产代码 / SwiftTerm fork / pbxproj / Package.resolved / Tests，仅新增 `Docs/Phase7A-...md`（untracked）。git baseline 干净。

## 2. P1（阻塞性安全问题）

**无 P1 阻塞**。报告对 history 自动 capture 的安全分析正确且充分（见 §30–§34）。具体确认：

- 键盘字节拦截无法区分 password prompt（sudo/ssh/mysql/su/psql）—— **源码确认**：SwiftTerm `send(data:)` 只拿到原始键码字节，无 prompt 上下文（`AppleTerminalView.swift:2885`；`TerminalViewDelegate.send` 只传 `ArraySlice<UInt8>`，`TerminalViewDelegate.swift:37`）。无法可靠判断当前在 shell prompt / sudo password / REPL / vim / tmux。**P1 风险成立**，报告禁止自动 capture 的结论正确。
- `Terminal.feed()` 伪造输入风险—— **源码确认**：`feed` 调 `terminal.feed(...)`（`AppleTerminalView.swift:2821/2829`），写屏幕缓冲，不进 `send` delegate、不写 PTY/SSH。报告「禁用 feed 做 Paste/Execute」正确。
- active session 发错 tab 风险—— **源码确认**：`SessionManager.activeSession`（`SessionManager.swift:69`）单一权威；Dispatcher 每次实时读、不缓存，可消除 stale target。

## 3. P2（必须修正的设计缺陷）

| # | 问题 | 验收意见 |
| --- | --- | --- |
| P2-1 | control-char 验证不完整（报告 §34 只覆盖 CR/LF） | MUST 明确 policy：拒绝 NUL(0x00)；CR/LF/CRLF 拒绝；**允许** ESC(0x1b)/TAB(0x09)/BEL(0x07)（`printf '\a'`、`echo -e '\e[31m'` 是合法命令）。理由见 §22。 |
| P2-2 | history append 时机未精确定义（报告 §14 模糊） | MUST 定义：Dispatcher 在 `displayState == .active` 预检通过 + 同步 `send(txt:)`+`send(data:[0x0d])` 调用完成后 append history；连接已断时预检即拒绝，不 append。见 §40。 |
| P2-3 | SwiftData 迁移测试缺失（报告 §86 仅称「自动迁移」） | MUST 在 Phase 7B 增加 on-disk 迁移测试（非 in-memory）。见 §51/§53。 |
| P2-4 | history replay 语义未定论（报告 §24 列为「可选」） | MUST 固定：History row Execute 也 append 新 history（统一语义）。见 §39。 |
| P2-5 | fork patch 必要性论证不充分 | 报告推荐 fork patch（Option A），但 Option B（用 public `getTerminal().bracketedPasteMode`+`send`+`bracketedPasteStart/End` 复刻）技术上可行。fork patch 的真正理由是 IME marked-text 处理（`insertText(_:isPaste:true)` 清 `markedTextStorage`，`:1674`），Option B 跳过此项。**有条件批准** fork patch，但须满足 §15 API 设计要求，且 Option B 须作为文档化 fallback。见 §14/§15。 |
| P2-6 | History UI 命名可能误导（"历史记录"暗示全量 shell history） | MUST 采用方案 A：保留「历史记录」名称（符合用户原始产品要求），但在 empty state / tooltip 明确「仅记录通过 MacSSH 执行的命令」。见 §38。 |

## 4. P3（建议改进，不阻塞）

- 报告未提及 `send(data:)` 内部还调 `terminal.registerUserInput(data)`（`:2902`），该调用喂 OSC 133 submission 启发式。程序化 Paste/Execute 同样触发，与键盘一致，正确——报告应补注。
- 报告 §28 history scope 选「全局默认」需在 Phase 7B 明确 UI 是否提供「当前会话/全部」筛选开关（可选，不强制）。
- 窗口过窄时展开 300pt 侧栏可能让 Terminal cols 过少；v1 可文档化限制。

## 5. branch

`feature/macssh-1.1-command-sidebar`（`git branch --show-current` 确认）。

## 6. baseline

`9ab519ad39eba049805ce32f3ecfea75c7ca0bbe`（`git rev-parse HEAD` 确认）。含 Phase 6 FINAL PASS。

## 7. production modifications

**无**。`git status --short` 仅显示 `?? Docs/Phase7A-CommandSidebar-Architecture-Investigation.md`（报告本身，untracked）。`git diff --check` 无输出。无 `MacSSH/*.swift` 改动、无 pbxproj 改动、无 Package.resolved 改动、无 Tests 改动、无 SwiftTerm fork 改动。

## 8. SwiftTerm identity

- production `Package.resolved`（`MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`）pin：`https://github.com/canbyte0/SwiftTerm.git` @ revision `6e56e32e16eba0c3a5f534136da272679085f44c`。
- 本地 `ThirdParty/SwiftTerm-fork` HEAD = `6e56e32e16eba0c3a5f534136da272679085f44c`（`git rev-parse HEAD` 确认），remote `github https://github.com/canbyte0/SwiftTerm.git`。
- **一致**。报告分析的源码版本与 production pinned revision 完全相同。fork 已含 Phase 5（VS16 `8a5187f`）+ Phase 6（highlight `6e56e32`）patch。

## 9. keyboard input pipeline

**源码确认**（`Sources/SwiftTerm/Mac/MacTerminalView.swift` + `Apple/AppleTerminalView.swift`）：

```
NSEvent
 → MacTerminalView.keyDown(with:)           [MacTerminalView.swift:1365, public override]
 → interpretKeyEvents([event])             [:1372, NSTextInputClient]
 → insertNewline(_:)/insertText(_:)/deleteBackward(_:) …
 → send(EscapeSequences.cmdRet)/send(txt:)/send(data:)   [public 输入出口]
```

`send(data:)`（`AppleTerminalView.swift:2885`，`public`）含 `assert(Thread.isMainThread)`（`:2891`），调 `recordUserInput()`+`ensureCaretIsVisible()`+`terminal.registerUserInput(data)`（`:2902`）+ `terminalDelegate?.send(source:data:)`（`:2903`）。报告链路真实成立。

## 10. Local input pipeline

**源码确认**（`Mac/MacLocalTerminalView.swift` + `LocalProcess.swift`）：

```
send(data:) [public, main-thread]
 → LocalProcessTerminalView.send(source:data:)   [MacLocalTerminalView.swift:152, open func]
 → process.send(data:)                           [LocalProcess.swift:215, public func]
 → DispatchIO.write(toFileDescriptor: childfd)  [:229, PTY master fd]
 → Shell
```

`LocalProcessTerminalView` 继承 `TerminalView` 且自身实现 `TerminalViewDelegate`（`setup()` 里 `terminalDelegate = self`，`:92`）。MacSSH `LocalTerminalService` 只挂 `processDelegate`，不参与输入发送。**UI 无法绕过此路径**——任何经 SwiftTerm `TerminalView` 的程序化输入都走同一 delegate。

## 11. Remote input pipeline

**源码确认**（`MacSSH/Services/Terminal/RemoteTerminalService.swift` + `Services/SSH/SSHChannel.swift` + `SSHConnection.swift`）：

```
send(data:) [public, main-thread]
 → RemoteTerminalService.send(source:data:)            [RemoteTerminalService.swift:431, nonisolated]
 → Task { @MainActor in try await connection.writeChannelInput(data) }
 → SSHConnection.writeChannelInput(_:)                  [SSHChannel.swift:262, actor 方法]
 → libssh2_channel_write_ex (actor 隔离, EAGAIN 重试, partial-write 循环)
 → SSH Channel → Remote Shell
```

**actor 串行化确认**：`SSHConnection` 声明为 `actor`（`SSHConnection.swift:86`）。`writeChannelInput` 是 actor 方法，Swift actor 隔离保证所有写调用串行、绝不并发进入同一 session/channel handle。写入先等待在途 open/close（字节不丢仅顺延）。

**连续 command + Return 不交错确认**：`send(data:)` 要求主线程（`AppleTerminalView.swift:2891`），故 `send(txt: command)` 与 `send(data: [0x0d])` 在主线程顺序执行；Remote 侧两次 `send` 各派发一个 `Task`（`:432`），MainActor FIFO + SSH actor FIFO 保证字节按入队顺序落盘，不交错。Local 侧 DispatchIO 对同一 stream FD 串行化。

## 12. Terminal.feed conclusion

**源码确认**：`feed(byteArray:)`/`feed(text:)`（`AppleTerminalView.swift:2821/2829`，`public`）调 `terminal.feed(...)`，把字节推进终端模拟器屏幕缓冲（shell→screen 输出路径），**不**经 `send` delegate、**不**写 PTY/SSH Channel。

- Local 输出：`LocalProcess.dataReceived(slice:)` → `feed(byteArray:)`（`MacLocalTerminalView.swift:207`）。
- Remote 输出：读取循环 `terminalView.feed(byteArray: output.bytes[...])`（`RemoteTerminalService.swift:322`）。

**明确结论**：`feed` 是 shell→terminal display input，**不是** user→shell keyboard input。Phase 7 Paste/Execute **禁止**使用 `feed`。报告 §10 正确。

## 13. current public paste capability

SwiftTerm 6e56e32 当前真实 public API（独立核实 access level）：

| API | access | 位置 | 是否接受任意文本 | 是否做 bracketed paste |
| --- | --- | --- | --- | --- |
| `send(data:)` | public | `AppleTerminalView.swift:2885` | 是（bytes） | 否 |
| `send(txt:)` | public | `:2910` | 是（String→UTF8） | 否 |
| `send(_ bytes:)` | public | `:2925` | 是 | 否 |
| `paste(_:)` | open @objc | `MacTerminalView.swift:2521` | **否**（只读 `NSPasteboard.general`） | 是（调 internal `insertText(_:isPaste:true)`） |
| `insertText(_:replacementRange:)` | open | `MacTerminalView.swift:1669` | 是 | **否**（调 internal `isPaste:false`） |
| `insertText(_:replacementRange:isPaste:)` | **internal** | `:1673` | 是 | 是 |
| `feed(...)` | public | `:2821/2829` | — | —（输出路径） |
| `getTerminal()` | public | `:378` | — | —（返回 `Terminal`，可读 `bracketedPasteMode`） |

**MacSSH 当前能从 module 外调用的 paste 相关 public API**：`send(data:)`/`send(txt:)`/`send(_:)`/`paste(_:)`/`insertText(_:replacementRange:)`/`getTerminal()`。**无**任何 public API 能「接受任意文本 + 做 bracketed paste 语义」。

## 14. fork paste API necessity

独立评估 A/B/C（per 验收 §9）：

- **A. SwiftTerm 已有 public paste API 接受任意文本？** 否。`paste(_:)` 只读剪贴板（`:2523-2524`）。`send(txt:)` 不做 bracketed paste。**A 不可行**。
- **B. MacSSH 可安全调用其他现有 public API 复刻 bracketed paste？** **是**。所需构件全部 public：`tv.getTerminal().bracketedPasteMode`（`Terminal.swift:478` public private(set)）+ `EscapeSequences.bracketedPasteStart/End`（`EscapeSequences.swift:132/136` public static）+ `tv.send(data:)`/`send(txt:)`（public）。复刻 `insertText(_:isPaste:true)` 的 `:1723-1729` 逻辑：
  ```swift
  if tv.getTerminal().bracketedPasteMode { tv.send(data: EscapeSequences.bracketedPasteStart[...]) }
  tv.send(txt: text)
  if tv.getTerminal().bracketedPasteMode { tv.send(data: EscapeSequences.bracketedPasteEnd[...]) }
  ```
  这与 SwiftTerm 内部逻辑逐字节一致。

**但** Option B 有一个 P2 级正确性缺口：`insertText(_:isPaste:true)` 在包裹前先清 IME 组合态（`markedTextStorage = nil; markedSelectedRange = …; updateMarkedTextOverlay()`，`:1674-1676`）。CJK 用户正在 IME 组合（marked text）时点 Paste，Option B 不清 marked text，可能留下悬挂组合态。Option A（调真 `insertText`）正确处理。此为正确性理由（非「方便」），符合验收 §9 的 C 批准门槛。

**结论**：**有条件批准 fork patch（Option C）**。理由是 IME marked-text 正确性（P2），不是方便。要求：
- API 须满足 §15 设计约束；
- Option B 须作为文档化 fallback（若 fork patch 未合入）；
- Phase 7B 须在 fork patch 与 Option B 间二选一并明确记录。

## 15. recommended fork API

若采用 fork patch，验收其设计（per §10）：

报告提议：
```swift
public extension TerminalView {
    func pasteText(_ text: String) {
        insertText(text as Any, replacementRange: NSRange(location: 0, length: 0), isPaste: true)
    }
}
```

**验收**：
- 通用 ✓（接受任意 String，不绑定 MacSSH 概念）。
- 无 MacSSH 名称 ✓（`pasteText` 是通用术语）。
- default behavior 不变 ✓（仅新增 public 桥接，不改 `insertText` 内部）。
- 不依赖 SavedCommand/UserDefaults/SwiftData ✓。
- 不自动执行 ✓（不附 Return）。
- 复用 SwiftTerm 原 bracketed paste 语义 ✓（调 internal `insertText(_:isPaste:true)`）。
- 职责「像用户 paste 一段字符串」✓。

**一处建议**：放在 `AppleTerminalView.swift`（跨 Mac/iOS base）而非 `MacTerminalView.swift`，使 iOS 端也可用（虽 MacSSH 仅 macOS，但通用性更好）。非强制。

## 16. bracketed paste

**源码确认**：
- `Terminal.bracketedPasteMode`（`Terminal.swift:478`，`public private(set) var`）：DECSET 2004 → `true`（`:5590`），DECRST 2004 → `false`（`:5337`），reset → `false`（`:966`）。
- `EscapeSequences.bracketedPasteStart = [0x1b,0x5b,0x32,0x30,0x30,0x7e]`（`EscapeSequences.swift:132`，`public static var`）= `ESC[200~`。
- `EscapeSequences.bracketedPasteEnd = [0x1b,0x5b,0x32,0x30,0x31,0x7e]`（`:136`，`public static var`）= `ESC[201~`。

**`insertText(_:isPaste:true)` 顺序确认**（`:1723-1729`，非 kitty 路径）：
```
start → text → end
```
顺序正确。kitty 增强路径（`:1679-1684`）同样 start→text→end 后 return。

## 17. Paste implementation

**Phase 7B 唯一推荐**：用 `pasteText(command)`（fork Option A）或等价 Option B 复刻。

- 只插入 command text，**不**发 Return/CR/LF。`pasteText` 内部只 `send(txt:)`，无 `[0x0d]`。✓
- 不清当前 Shell input、不移 cursor、不改 Terminal buffer。`send` 只把字节经 delegate 送出，shell line editor 自行处理。✓
- bracketed paste 由 SwiftTerm 单点处理（若用 Option A）或 MacSSH 复刻但**不双重包裹**（若用 Option B，MacSSH 只在 `bracketedPasteMode==true` 时发 start/end，与 SwiftTerm 一致；SwiftTerm 自身 paste 路径不会被触发，无双重包裹风险）。✓

## 18. Execute implementation

**Phase 7B 唯一推荐**：`send(txt: command)` + `send(data: EscapeSequences.cmdRet[...])`。

不使用 `pasteText`（即不走 bracketed paste）。理由见 §19。

- 发 command 文本 + 一次 Return（`[0x0d]`）。✓
- 不用 `feed`。✓
- 走与键盘相同的 `send` delegate 路径。✓

## 19. raw send vs pasteText decision

**Phase 7B Execute 用 raw `send(txt:)`+`send(data:[0x0d])`，不用 `pasteText(command)`+Return。**

独立分析两种方案：

**方案 A：raw send(command) + Return**
- shell 收到 `command` 原始字节 + CR，等同用户手输后按 Return。
- bracketed paste off：shell 正常解析 command + CR，执行。✓
- quote/special char：`send(txt:)` 用 `txt.utf8` 原样（`AppleTerminalView.swift:2917`），不 escape、不 normalize。`git commit -m "hello"`、`printf '%s\n' "$HOME test"` byte-for-byte 保持。✓
- zsh/bash/fish/remote shell：CR 是通用 Return，所有 shell 一致。✓

**方案 B：pasteText(command) + Return**
- 若 shell 开了 bracketed paste（zsh/bash 默认交互模式通常开），command 被 start/end 包裹。Return 在 end 之后（`pasteText` 同步返回后再发），shell 把 command 作字面粘贴插入，然后 CR 提交。
- 风险：bracketed paste 内 shell 不解释 control char；若 command 含需 shell 解释的内容（实际单行 command 无换行所以影响小），仍可能因 paste mode 行为差异（如 zsh 的 `bracketed-paste` magic-space 等）引入细微不一致。
- 多一层 wrapping 逻辑，Execute 场景无收益。

**结论**：Execute 是「单行命令 + 立即执行」，不需要 paste 安全保护。raw send 最简单、最可预测、跨 shell 一致。**唯一推荐方案 A**。

## 20. Return byte/path

**源码确认**：`MacTerminalView.swift:1610-1611`：
```swift
case #selector(insertNewline(_:)):
    send(EscapeSequences.cmdRet)
```
`EscapeSequences.cmdRet = [13]`（`EscapeSequences.swift:78`，`public static let`）= `0x0D` = `\r`（CR）。

最终 Return 字节 = **`0x0d`（CR）**，不是 `0x0a`(LF) 也不是 `0d0a`(CRLF)。

kitty 增强模式走 `sendKittyFunctionalKey(.enter, …)`（`:1562`），对普通 shell 仍等价 CR。MacSSH Execute 复用 `send(data: EscapeSequences.cmdRet[...])` 与真实 Return 字节完全一致，不凭经验硬编码——`cmdRet` 是 SwiftTerm public stable contract（`public static let`）。

## 21. existing-input semantics

**架构支持确认**：当前 terminal 有 `git chec█`，点 Execute `git status`：
- Dispatcher 在当前 cursor 位置 `send(txt: "git status")` + `send(data: [0x0d])`。
- shell line editor 把 `git chec` + `git status` 拼成 `git checgit status` 后 CR 提交。
- MacSSH 不发 Ctrl+U/Ctrl+C、不清行、不移 cursor、不猜 line editor 状态。✓ 符合任务书 §16 v1 语义。

## 22. control-character validation

**报告缺口**：§34 只覆盖 CR/LF。独立给出完整 policy：

| 字符 | 拒绝/允许 | 理由 |
| --- | --- | --- |
| `\n`(0x0a) LF | 拒绝 | 多行 |
| `\r`(0x0d) CR | 拒绝 | 多行/Return |
| `\r\n` CRLF | 拒绝 | 含 CR+LF |
| NUL(0x00) | **拒绝** | 永非合法命令字符；可截断字符串/破坏 shell |
| ESC(0x1b) | **允许** | `printf '\e[31mred\e[0m'`、`echo -e '\033[...'` 是合法 ANSI 命令 |
| TAB(0x09) | **允许** | 合法（completion 风格、对齐） |
| BEL(0x07) | **允许** | `printf '\a'` 合法 |
| 其他 C0(0x01-0x1f 除上述) | 建议允许但记录 | 罕见但不违法；v1 不过度限制 |
| U+2028/U+2029 | **拒绝** | Unicode 行/段分隔符，视作 multiline |

**Phase 7B validation**：Store+UI 双重校验：trim 判空 + 拒绝含 `\n`/`\r`/`\0`/U+2028/U+2029 的 command。允许 ESC/TAB/BEL。

## 23. UTF-8/quotes

**源码确认**：`send(txt:)` 用 `[UInt8](txt.utf8)`（`AppleTerminalView.swift:2917`），原样 UTF-8 字节，不 escaping/normalize/quote-reconstruct。

- `echo '中文 😀'` → UTF-8 bytes 原样。✓
- `printf '%s\n' "$HOME test"` → 原样（`$HOME` 由 shell 解释，MacSSH 不动）。✓
- `git commit -m "hello world"` → 原样双引号。✓
- `echo '$PATH'` → 原样单引号。✓

MacSSH 不做 shell quote transform。`send(txt:)` 天然满足。

## 24. whitespace policy

**唯一结论**：validation 用 trim 判空，storage 保存用户原文。

理由：leading spaces 在 zsh/bash 有 `HIST_IGNORE_SPACE` 等 history semantics（` ` 前缀命令不入 history），属有意义 shell spacing。trim storage 会丢失语义。Store 层：`command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` → 拒绝；通过则存原文。

## 25. active session source

**源码确认**：`SessionManager.activeSession`（`SessionManager.swift:69`）= `sessions.first { $0.id == activeSessionID }`。`activeSessionID: UUID?`（`:29`）是**唯一权威来源**。无 `selectedSession`。`activateSession(id:)`（`:163`）/`activateTab(at:)`（`:175`）只改 `activeSessionID`。

## 26. stale-target prevention

**可实现确认**：Dispatcher 每次 `paste`/`execute` 重新读 `appState.sessionManager.activeSession`（瞬时快照），不缓存 `TerminalView`/`SSHConnection`/`LocalProcess`。`@MainActor` 串行，读 activeSession 与调 `send` 之间无 await（`send` 同步），无 TOCTOU 窗口。

## 27. tab-close race

**@MainActor + SessionManager 语义足够确认**：

- Dispatcher 标 `@MainActor`；`send(data:)` 亦要求主线程（`:2891`）。
- 用户点 Execute（主线程）→ 读 `activeSession`（主线程，瞬时）→ `send(txt:)`+`send(data:)`（主线程同步）。全程无 await，Tab 切换/关闭（也在主线程）无法插入其间。
- 若 Execute 前刚好 closeSession（主线程先处理关闭）：`activeSession` 已变或 nil，Dispatcher 读到新 active 或 nil，no-op/disabled。不 crash、不发错 session。
- Remote 侧 `send` delegate 派发 `Task`（`:432`），该 Task 内 `await connection.writeChannelInput`；若 session 在此期间关闭，`connection` 可能已 disconnect，`writeChannelInput` 抛 `connectionLost`/`channelClosed`（`SSHChannel.swift:278-282`），delegate catch 记录（`:438-440`），不 crash。字节可能丢（已断开），但预检 `displayState==.active` 应在前置 UI 已 disable。

## 28. disconnected handling

**源码确认**：`ManagedTerminalSession.displayState`（`:234`）统一状态：

| displayState | Paste/Execute | 说明 |
| --- | --- | --- |
| `.active` | **enabled** | Local running / Remote shell active |
| `.starting`/`.connecting`/`.authenticating`/`.awaitingHostTrust`/`.opening` | disabled | 未就绪 |
| `.disconnected`/`.failed`/`.exited`/`.closing` | disabled | 不可写 |

Dispatcher 前置校验 `displayState == .active`。UI 按钮按同条件置灰。不 silent drop（disabled 即不可点）。✓

## 29. focus restoration

**源码确认**：`LocalTerminalService.focusWhenAvailable()`/`RemoteTerminalService.focusWhenAvailable()`（均 `Task { @MainActor in window.makeFirstResponder(terminalView) }`）已提供能力。Dispatcher 在 paste/execute 末端调 active session 对应 service 的 `focusWhenAvailable()`。不重新创建 TerminalView。✓

## 30. History capture candidates

独立重比较（不照抄报告）：

| 方案 | 结论 | 独立依据 |
| --- | --- | --- |
| A 键盘重建 line | ❌ P1 | `send` 只拿键码字节，无 prompt 上下文；line-editing 操作致重建不一致 |
| B 拦截 send bytes | ❌ P1 | 同上，且无法区分 password prompt |
| C shell history 文件 | ❌ | Remote 需额外协议/权限；落盘延迟；tmux/REPL 污染；`HIST_IGNORE_SPACE` |
| D shell integration 注入 | ⚠️ future | 违反 §49（不改远端配置） |
| E OSC 133 | ⚠️ future | fork 已实现 parser（`SemanticPrompt.swift`）但需 shell 主动发 |
| F MacSSH Execute only | ✅ v1 | 安全、精确、Local/Remote 一致 |
| G OSC 1337/iTerm | ⚠️ future | 同 D/E |

报告结论与独立判断一致。

## 31. keyboard interception

**确认无法可靠判断**：`TerminalViewDelegate.send(source:data:)`（`TerminalViewDelegate.swift:37`）只传 `ArraySlice<UInt8>`，无 prompt/state 上下文。无法区分 shell prompt / sudo password / ssh password / REPL / vim / tmux / mysql。**自动保存这些 bytes 是 P1 风险**。

## 32. password risk

sudo/su/ssh/mysql/psql password input 无法排除。**禁止自动 keyboard history capture**。报告结论正确。

## 33. REPL/TUI risk

python/node/mysql/psql/vim/nano/less/top/htop 内 Return 不是 shell command；vim 内键盘是编辑指令。input-byte interception 无法判断当前 mode。v1 只记 MacSSH Execute 天然规避。报告正确。

## 34. tmux/screen

tmux 内键盘先送 tmux，line editor 在 tmux 内，MacSSH 无法重建。v1 明确 limitation。报告正确。

## 35. shell history

Local zsh/bash history 文件：落盘延迟（shell 退出/`history -a`）、`HISTFILE` 配置差异、共享 history、`HIST_IGNORE_SPACE`、tmux 污染。Remote 需 SFTP/exec 读远端文件，权限/shell 差异。不适合实时 sidebar。报告正确。

## 36. OSC133

**SwiftTerm 6e56e32 真实支持确认**（`SemanticPrompt.swift`）：
- `SemanticContent`（`.none`/`.prompt(kind)`/`.input`/`.output`）——可识别 prompt start（`A`）、command start（`B`/`I`）、command executed（`C`）、command finished（`D`）。
- `SemanticInputState`（`.idle`/`.prompt`/`.armed`/`.submitted`）——`B`/`I` arm，`C`/`D`/换行 submit。
- `Terminal.swift:2001` 识别 `\r`/`\n` 为 submission。

**但**：能否直接得到原始 command text？parser 标记 cell 的 `SemanticContent`，理论上可从 `.input` 区段读 buffer 文本。但需 shell 主动发 OSC 133。**不作为 v1 默认依赖**（见 §37）。

## 37. OSC133 deployment feasibility

macOS 默认 zsh、远端默认 bash/zsh **不主动发** OSC 133。需 shell integration 脚本（改 `.zshrc`/`.bashrc`）。违反任务书 §49。**v1 不依赖**，标 future option。报告正确。

## 38. History v1 scope

**安全、准确确认**：只记 MacSSH Execute。

**产品语义方案**（per 验收 §38）：采用 **方案 A**——保留「历史记录」名称（符合用户原始产品要求，不擅自改名），但在 History 页面 empty state + tooltip 明确标注：
> 「仅记录通过 MacSSH 执行的命令；手动键入的命令不在记录范围。」

不伪装为全量 shell history。Phase 7B 须落实此 disclosure 文案（双语）。

## 39. History replay

**固定**：History row → Execute **也 append 新 history entry**。统一语义：「History = MacSSH Dispatcher 明确执行过的命令，无论来源（Saved Command / History replay）」。避免特殊 case。报告「可选」须改为「固定」。

## 40. History append timing

**明确**：Dispatcher.execute 顺序：
1. 预检 `displayState == .active`（不通过 → 不 append，UI disabled）。
2. `send(txt: command)`（同步，主线程，字节交 SwiftTerm）。
3. `send(data: [0x0d])`（同步，主线程）。
4. **append history**（command + executedAt + active session 快照）。
5. `focusWhenAvailable()`。

append 发生在同步 send 完成（字节已交 SwiftTerm delegate）后。若 Remote 连接在步骤 2/3 的 delegate Task 内失败（`writeChannelInput` 抛错），字节未真正送达——但预检已挡掉绝大多数断开场景；极端竞态（预检通过后瞬间断开）下可能 append 一条未真正送达的记录，可接受（用户可见断开状态，且该记录仍是「用户意图执行的命令」）。**不**在 action request 时 append（避免断开时记成功）。

## 41. History model

报告提议 `CommandHistoryEntry` 字段合理，验收确认并补充 `source`：

```
id: UUID (@Attribute(.unique))
command: String
executedAt: Date
sessionID: UUID           // runtime-only，不持久化 session 对象本身
sessionKind: String       // "local" / "remoteSSH"
hostDisplayName: String?  // Remote 快照（不含凭据）
source: String            // "savedCommand" / "historyReplay"
```

不过度收集（不加 hostID 强引用、不加 command 参数等）。✓

## 42. closed-session history

`sessionID` 是 runtime UUID（`ManagedTerminalSession.id`，内存对象）。session close 后对象销毁，但 history entry 已存 `hostDisplayName` 快照——History row 可显示「Local」或「Remote Host 名」**不依赖**已销毁的 Session 对象。✓

## 43. History scope/accessibility

**独立判断**：v1 History 默认显示**全局所有 session 记录**，row 标注来源（Local/Host 名）。理由：
- 来源仅 MacSSH Execute，总量小（不像全量 shell history）。
- 跨 host 复用（Remote C 执行后切 Local A 想复用）是常见场景。
- 只显示当前 session 会导致关闭 tab 后持久化数据无法查看（验收 §45 关注点）。

可选（非强制）：Phase 7B 可加「当前会话/全部」轻量筛选开关。报告 §28 结论成立。

## 44. retention

**确认**：全局上限 1000 条（SwiftData 成本极低），超限按 `executedAt` 最旧优先删除，deterministic。不按 session 单独限、不做时间 retention。报告 §27 合理。

## 45. default

**独立确定：默认 On。** 理由：v1 只记 MacSSH Execute，不含 password prompt 输入，隐私风险低；默认 On 让「常用命令→执行→历史复用」闭环立即成立。同时 Settings 提供开关 + 清空。command 本身可能含 token，但这是用户主动保存/执行的命令，非被动捕获，用户预期内。

## 46. clear-history behavior

**确认**：Settings → Terminal → 「清空历史」+ History 页面动作。destructive confirmation（alert）。清空 = 删除全部 `CommandHistoryEntry`。报告 §48 提及，验收确认须有 confirmation。

## 47. privacy/logging

**确认**：command 内容不进 OSLog/analytics/crash breadcrumb。日志最多 `history count`/`entry id`/`source enum`。复用 `AppLogger`，不新增带 command 内容的日志点。报告 §46 正确。

## 48. persistence choice

**独立确认 SwiftData 更合理**：
- group↔command 关系：SwiftData `@Relationship` 天然；UserDefaults JSON 需手维护外键。
- sorting：SwiftData `@Query(sort:)` 原生；JSON 需内存排序。
- history retention/query：SwiftData 按字段查询/删除；JSON 全量读写。
- CRUD 频繁：SwiftData 增量；JSON 全量重写。

报告 §29/§30 结论成立。

## 49. current SwiftData schema

**源码确认**（`MacSSHApp.swift:32-36`）：
```swift
let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
```
`TransferTask` 是纯内存 `@Observable`（`TransferTask.swift:62`），**不**在 schema。`ModelConfiguration("MacSSH", schema:, cloudKitDatabase: .none)`（`:37-41`）。

添加 `CommandGroup`/`SavedCommand`/`CommandHistoryEntry` 须加入此 `Schema` 数组。**无其他 container initialization path**（grep 确认仅 `MacSSHApp.swift:44` 一处 `ModelContainer(`）。

## 50. migration safety

**独立判断**：新增 3 个 `@Model` 类、不改现有 `Host`/`HostGroup`/`KnownHost` 字段，属 SwiftData **lightweight migration（additive entity）** 可安全处理范围。无 `VersionedSchema`/`SchemaMigrationPlan`（grep 确认项目未用），隐式迁移即支持 additive entity。

但「自动迁移」**不足以替代测试**（见 §51）。

## 51. required migration test

**Phase 7B MUST 增加 on-disk 迁移测试**（per 验收 §53）：

1. 用 Phase 6 schema（`[Host, HostGroup, KnownHost]`）创建 on-disk store（`isStoredInMemoryOnly=false`，临时目录）。
2. 插入 sample Host/HostGroup/KnownHost 数据，`save()`，释放 container。
3. 用 Phase 7 schema（加入 `CommandGroup/SavedCommand/CommandHistoryEntry`）打开**同一** store。
4. 断言 Host/HostGroup/KnownHost 数据全部保留（count + 字段值）。
5. 插入新 model 数据，`save()`，重开，断言新数据存在。

**不可**只用 `isStoredInMemoryOnly=true` 证明迁移。此测试未过 = P2 blocker。

## 52. group delete semantics

**独立确认**：`.nullify` deleteRule（删 group → `SavedCommand.group = nil` → 移到 Ungrouped），比级联删除命令更安全。复用 `HostGroup` 先例（`HostGroup.swift:17`）。删除前 UI 弹确认告知「将把 N 条命令移到未分组」。**唯一方案**：nullify。

## 53. ungrouped

**确认**：`group == nil` = 未分组。UI 始终能 `@Query` 查询 `group == nil` 的 commands 显示为「未分组」section。**不**创建假 SwiftData「Ungrouped」group。

## 54. group naming

**策略**：v1 **不强制** name 唯一（降低约束复杂度；HostGroup 强制唯一，但 CommandGroup 数量预期少，用户可接受同名）。但推荐 UI 提示同名。**deterministic**：允许同名，按 `sortOrder` 排序。Phase 7B 可选加唯一约束，非强制。

## 55. command model

**确认**：`id`/`command`/`group` relation/`sortOrder` 足够。v1 不加 title/tag/host/variables。命令列表直接显示 `command` 文本。✓ 报告 §32 正确。

## 56. validation

完整 policy（见 §22）：
- 拒绝：空、纯 whitespace（trim 判空）、`\n`/`\r`/CRLF、NUL(0x00)、U+2028/U+2029。
- 允许：ESC(0x1b)/TAB(0x09)/BEL(0x07)/其他 C0（合法命令字符）。
- `cd /tmp && ls` 允许（单行多命令）。
- Store+UI 双重校验。

## 57. sidebar hierarchy

**确认**（报告 §36）：
```
TerminalWorkspaceView
 └ HStack
     ├ VStack { TabBar; Divider; paneSelector; workspaceContent }  (现有)
     └ TerminalRightSidebarView (新增, 可展开/收起)
          ├ 顶部固定区: HStack { HistoryIconButton; SavedCommandsIconButton }
          └ ScrollView { HistoryView | SavedCommandsView }
```
顶部图标区固定，下方独立 ScrollView 滚动，顶部不跟随。✓

## 58. icons

- History：`clock.arrow.circlepath`（任务书指定）。
- Saved Commands：`command.square`（报告选此，因 `terminal` 已被左侧栏占用且语义重叠；`command.square` 贴合「命令集合」）。

**可用性**：需 Phase 7B 构建期确认 macOS 14+ 下两个 SF Symbol 可用（`command.square` 为 macOS 14 symbol）。不可用回退。不使用自定义图片。✓

## 59. selected/hover behavior

- 一次只选一个（单一 `selectedTab` state）。
- 选中：明显高亮（accent 前景 + 半透明背景胶囊，复用 `AppInteractiveButtonStyle` + `compactBackgroundDiameter`）。
- 未选中：`.secondary` 前景。
- hover：native `onHover` 反馈（受 Reduce Motion 尊重）。
- tooltip：`help(...)`（双语 String Catalog）。
- accessibilityLabel：双语。
- 不用 `Picker(.segmented)`，用两个 icon-only Button + selected 背景。✓

## 60. fixed header

**确认**：SwiftUI `VStack { 固定顶部 HStack; ScrollView { 内容 } }` 天然做到顶部固定 + 内容独立滚动。视图层级可行。✓

## 61. width

~300pt（范围 280–320），固定，不可拖动，不持久化 width。建议 `AppTheme.Layout.rightSidebarWidth = 300`。✓

## 62. toggle

**源码确认**：放 `AppToolbarContent`（`Components/Toolbar/AppToolbarContent.swift`），与现有 `+`（new session）同处 `.primaryAction`。`AppToolbarContent` 已按 `selectedSection` 条件显示，可加 `selectedSection == .terminal` 时显示 sidebar toggle（native SF Symbol `sidebar.right`）。不浮在 Terminal 上。✓

## 63. resize chain

**源码确认**（报告 §42）：
- 展开 → HStack 给 Terminal 新宽度 → SwiftTerm `TerminalView.setFrameSize` → `processSizeChange`（`AppleTerminalView.swift:386`）重算 cols/rows → `sizeChanged` delegate。
- Local：`LocalProcessTerminalView.sizeChanged`（`MacLocalTerminalView.swift:104`）→ `PseudoTerminalHelpers.setWinSize` → PTY resize。
- Remote：`RemoteTerminalService.sizeChanged`（`RemoteTerminalService.swift:446`）→ `connection.resizeChannelPTY`（`SSHChannel.swift:327`，actor）→ `libssh2_channel_request_pty_size_ex`。

**真实调用链确认**（非推断「SwiftUI 自动处理」）：SwiftTerm `setFrameSize` 是 NSView 标准生命周期，`processSizeChange` 在 `AppleTerminalView.swift:386`（`func`，非 public，内部由 `setFrameSize` 触发）。Phase 3/4/5 已验证。右侧栏开合是又一帧 size 变化，不引入新机制。✓

## 64. state persistence

- `isRightSidebarVisible`（默认 false）+ `selectedSidebarTab`（history/savedCommands）存 UserDefaults（UI preference），复用 `AppLanguage`/`AppPreferenceKey` 模式。
- 不存 runtime active session。
- 收起后 sidebar state 保留（`selectedSidebarTab` 不因收起丢失）。✓

## 65. multi-tab

- 切 Tab 只改 `activeSessionID`，sidebar 展开状态保持。
- Saved Commands 全局共享，切 Tab 不变。
- History（全局 scope）切 Tab 不切数据；row 标注来源。
- Dispatcher 切 Tab 后立即 target 新 active（每次实时读）。✓

## 66. hover accessibility

**实现策略**：SavedCommand/History row 默认隐藏 Paste/Run icon，hover 显示。但：
- 用 `.opacity(hovering ? 1 : 0)` **而非** `.accessibilityHidden`——`opacity(0)` 的 Button 仍可 keyboard focus/VoiceOver 访问（SwiftUI `Button` 默认 `focusable`）。
- 不设 `.focusable(false)`。
- VoiceOver 导航到 row 时，row 用 `accessibilityElement(children: .contain)` 暴露子动作按钮。
✓ 不让 hover 成为唯一访问路径。

## 67. History row actions

**确认**：History row 也提供 Paste/Run（复用同一 `CommandRowActions` component）。点击 row 本身不执行（防误操作）。✓

## 68. focus

**Phase 7B 验收要求**：点 Sidebar 内 Paste/Run 后，`focusWhenAvailable()` 恢复 Terminal firstResponder，用户键盘输入立即进入 Terminal。✓（见 §29）

## 69. Light/Dark

**确认**：Sidebar 用 SwiftUI semantic colors（`Color(nsColor: .textBackgroundColor)`/`.secondary`/`.accentColor` 等），不硬编码 white/black。Phase 4 regression 覆盖。✓

## 70. localization

全部新 UI 双语（简体中文 + English），走 String Catalog + `L10n`。含：icon tooltip、History scope 说明、v1 History limitation disclosure、Paste/Run、Group actions、Clear History、confirmation。不 hard-code。✓

## 71. accessibility

- icon tabs：`accessibilityLabel` + tooltip + selected value（`accessibilityValue`/`accessibilityAddTraits(.isSelected)`）。
- Paste/Run：`accessibilityLabel`，keyboard 可达（§66）。
- Group disclosure：`DisclosureGroup`（原生 keyboard 可操作）。✓

## 72. tests

Phase 7B 至少：`TerminalCommandDispatcherTests`/`SavedCommandStoreTests`/`CommandHistoryStoreTests`/`TerminalRightSidebarStateTests`/`SwiftDataMigrationTests`。若 fork patch：`SwiftTermPasteTextTests`。复用 `Tests/SSH/` 现有模式。新增 `Tests/CommandSidebar/`。✓

## 73. fork tests

若 fork patch 获批（§15），至少：
- normal mode paste sends exact UTF-8 text（无 start/end）。
- bracketed mode adds start/text/end exactly once（不双重）。
- paste 不发 Return。
- empty text 行为定义。
- Chinese/Emoji 字节正确。
- quotes 原样。
- provider/highlight/VS16 测试不受影响。✓

## 74. dispatcher tests

至少：Paste sends text only（无 `[0x0d]`）；Execute sends text+`[0x0d]`；active Local target；active Remote target；tab switch 不发 stale；closed target 不 crash；disconnected Remote disabled；rapid Execute ordering（主线程串行）；UTF-8；quotes byte-for-byte；no History on Paste；History on successful Execute；History replay append。Dispatcher 须有 protocol 接缝（`TerminalInputTarget`）注入 mock 记录 `send` 调用。✓

## 75. migration tests

**MUST**（§51）：on-disk pre-Phase7 store 升级到 Phase7 schema，检查 Host/HostGroup/KnownHost 未丢。未过 = P2 blocker。✓

## 76. performance

- Sidebar command list 100/500/1000 saved commands：SwiftData `@Query` 惰性 fetch，不每 keypress 触发（fetch 在 view appear / store change 时）。
- History retention 1000：SwiftData 查询/删除成本低。
- 不明显阻塞 Terminal typing（Dispatcher 同步 send 在主线程，微秒级）。✓

## 77. known limitations

- v1 History 不捕获手输/粘贴后自按 Return/REPL/tmux 内命令（§38 disclosure）。
- v1 不做搜索/拖拽排序/host-specific commands/参数模板。
- v1 不做 shell integration / OSC 133 自动 history（future）。
- v1 右侧栏固定 ~300pt 不可拖动。
- v1 Saved Command 仅单行（拒绝 CR/LF/NUL/U+2028/U+2029）。
- v1 不判断危险命令。
- v1 History 默认全局 + row 标注来源。

## 78. P1 risks

1. History 自动 capture 误存 password——**缓解**：v1 只记 MacSSH Execute，禁键盘拦截。
2. Execute 字节顺序（bracketed paste + Return 错位）——**缓解**：Execute 不走 bracketed paste，raw send + `[0x0d]`。
3. active session stale target——**缓解**：每次实时读，不缓存。
4. `Terminal.feed` 伪造输入——**缓解**：禁用 feed 做 Paste/Execute。
5. 迁移丢 Host/KnownHost——**缓解**：additive entity + on-disk 迁移测试（§51）。
6. command 进日志——**缓解**：日志只记 count/id/source。

## 79. P2 risks

1. Sidebar 点击致 Terminal 失焦——`focusWhenAvailable()` 末端恢复。
2. Saved Command shell 特殊字符/双引号——`send(txt:)` 原样 UTF-8，不 escape。
3. History retention 删除顺序——SwiftData + `@Query(sort: executedAt)` 测试。
4. SwiftData schema 迁移——additive + on-disk 迁移测试。
5. IME marked-text 与 Option B paste——优先 fork Option A；Option B 须文档化 IME 边界。
6. `command.square` 可用性——构建期验证，回退。
7. control-char 验证不全——§22 完整 policy。
8. history append 时机——§40 明确。
9. history replay 语义——§39 固定 append。

## 80. P3 risks

1. 多 Session 并发 Execute 交错——主线程串行 + SSH actor FIFO。
2. 窗口过窄 sidebar 让 Terminal cols 过少——v1 文档化。
3. 拖拽排序/搜索——v1 不做。

## 81. recommended Phase 7B scope

按报告 §53 组件 + 本验收修正：
- `TerminalCommandDispatcher`（@MainActor，protocol 接缝 `TerminalInputTarget` 供测试）
- `SavedCommandStore` / `CommandHistoryStore`（SwiftData）
- `TerminalRightSidebarView` + `HistoryView` + `SavedCommandsView`
- `CommandGroup`/`SavedCommand`/`CommandHistoryEntry`（@Model）
- SwiftTerm fork patch `pasteText(_:)`（满足 §15）**或** Option B 文档化复刻（二选一）
- Settings 开关 + 清空历史
- 全部双语 + accessibility
- Tests（§72-§75）

## 82. recommended implementation sequence

1. SwiftTerm fork patch（`pasteText`）**或** 确定 Option B（先决）。
2. Models 加入 Schema + on-disk 迁移测试。
3. Stores（CRUD + validation + retention）。
4. Dispatcher（routing + paste/execute + focus + history append per §40）。
5. Sidebar UI + History/SavedCommands views。
6. Toolbar toggle + AppState persistence。
7. Settings 开关 + 清空。
8. Localization（含 §38 disclosure）。
9. Tests。
10. 回归（resize/VS16/highlight/scrollback/selection/cursor/多 Tab）。

## 83. 是否允许进入 Phase 7B

**允许进入 Phase 7B**，条件：

1. 落实 §22 control-char 完整 validation policy。
2. 落实 §40 history append timing（send 成功后、预检失败不 append）。
3. 落实 §39 history replay append（固定，非可选）。
4. 落实 §38 History UI disclosure（保留「历史记录」名 + 明确限制说明）。
5. Phase 7B 须含 §51 on-disk SwiftData 迁移测试。
6. fork patch（若采用）须满足 §15 通用 API 设计；Option B 须作文档化 fallback。
7. 严守 v1 只记 MacSSH Execute、禁键盘拦截、禁 `feed`、Dispatcher 不缓存 stale target、双语 + 语义色 + accessibility、日志不含 command、右侧栏不 overlay。
8. Phase 7B 结束须完成编译、warning 检查、测试、GUI 验收与阶段报告。

以上 1–6 为**文档/设计补强**（不涉及生产代码改动），可在 Phase 7B 实现时一并落实。

## 84. final status

**CONDITIONAL PASS — 允许进入 Phase 7B**。

调查报告核心技术事实经独立源码核实全部成立。发现的 P2 设计补强（control-char validation、history append timing、history replay 语义、UI disclosure、迁移测试、fork 必要性论证）为设计明确化要求，不否定报告架构。SwiftTerm 身份、输入管道、Paste/Execute API、Return 字节、bracketed paste、active session routing、SwiftData schema、History 安全边界均经独立确认。

Phase 7A 架构调查**验收通过**，等待 Phase 7B 实现授权。

---

**STOP** — 独立验收完成。未修改生产代码 / SwiftTerm fork / commit / merge / push。未开始 Phase 7B。
