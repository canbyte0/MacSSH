# MacSSH 1.1 Phase 7A — Terminal Right Sidebar / History & Saved Commands Architecture Investigation Report

Phase 7A 是**调查阶段**：只读源码，未修改生产代码 / SwiftTerm fork / commit / merge / push。等待独立架构验收后才进入 Phase 7B。

---

## 1. branch

| 项 | 值 |
| --- | --- |
| 当前 branch | `feature/macssh-1.1-command-sidebar` |
| working tree | clean（`git status --short` 无输出） |

## 2. baseline SHA

```
9ab519ad39eba049805ce32f3ecfea75c7ca0bbe
```

该 baseline 已包含 Phase 6 FINAL PASS（终端字符串高亮 + VS16 preserve-base-width 兼容策略）：
最近提交链 `9ab519a fix(terminal): 修复滚动条区域光标显示异常` → … → `6d610e8 feat(terminal): 添加终端字符串高亮功能` → `5d0c2df feat(terminal): 切换 SwiftTerm 依赖至 MacSSH fork 并启用 VS16 宽度策略`。

## 3. production modifications

**无**。Phase 7A 全程只读源码（`MacSSH/`、`ThirdParty/SwiftTerm-fork/`、`Tests/`、`Docs/`）。未修改任何生产代码、SwiftTerm fork、`Package.resolved`、`Tests/`。无 commit / merge / push。唯一写文件位置为本报告（`Docs/`）与工作记忆（`.codebuddy/memory/`）。

---

## 4. current Terminal input pipeline

SwiftTerm 的 Mac `TerminalView`（含其子类 `LocalProcessTerminalView`）以 AppKit `NSView` + `NSTextInputClient` 承担键盘处理。键盘事件经 `interpretKeyEvents` 路由到 `insertText` / `insertNewline` / `deleteBackward` 等选择子，再统一经 `send(data:)` 出口。

核心出口（`Sources/SwiftTerm/Apple/AppleTerminalView.swift`）：

```
NSEvent (keyboard)
  → MacTerminalView.keyDown(with:)                      [AppleTerminalView.swift:1365]
  → interpretKeyEvents([event])                         [NSTextInputClient]
  → insertNewline(_:) / insertText(_:) / deleteBackward(_:) …
  → send(EscapeSequences.cmdRet) / send(txt:) / send(data:)   ★ public 输入出口
```

`send(data:)` 在 `AppleTerminalView.swift:2885` 定义为 `public`，并 `assert(Thread.isMainThread)`，内部 `recordUserInput()` + `ensureCaretIsVisible()` 后调用 `terminalDelegate.send(source:data:)`。`send(txt:)`（`:2910`）把 String 转 UTF-8 再调 `send(data:)`；`send(_ bytes: [UInt8])`（`:2925`）同理。三者共用同一 delegate 出口，因此程序化发送与键盘输入走**完全相同**的字节路径。

## 5. Local input pipeline

`LocalProcessTerminalView`（`Sources/SwiftTerm/Mac/MacLocalTerminalView.swift`）继承自 `TerminalView` 并实现 `TerminalViewDelegate`，其 `send(source:data:)` 直接写 PTY：

```
NSEvent
  → MacTerminalView.keyDown
  → … → send(data:)                          [public, main-thread]
  → LocalProcessTerminalView.send(source:data:)   [MacLocalTerminalView.swift:152]
  → process.send(data:)                       [LocalProcess.swift:215]
  → DispatchIO.write(toFileDescriptor: childfd, …)   [PTY master fd]
  → Shell
```

`LocalProcess.send(data:)` 用 `DispatchIO` 写 `childfd`（PTY master）。DispatchIO 对同一 stream FD 的写操作由 GCD 串行化。`send(data:)` 要求主线程，故多次程序化发送在主线程顺序执行、不交错。

**关键**：Local **没有**独立的 `send` delegate 接缝——`LocalProcessTerminalView` 自身既是 `TerminalView` 又是 `TerminalViewDelegate`，在 `setup()` 里把 `terminalDelegate = self`。MacSSH 的 `LocalTerminalService` 只挂接 `processDelegate`（`LocalProcessTerminalViewDelegate`），用于回调 `sizeChanged` / `setTerminalTitle` / `processTerminated` / `hostCurrentDirectoryUpdate`，**不**参与输入发送。Local 输入由 SwiftTerm 内部直达 PTY。

## 6. Remote input pipeline

`RemoteTerminalService`（`MacSSH/Services/Terminal/RemoteTerminalService.swift`）持有 SwiftTerm `TerminalView`，实现 `TerminalViewDelegate`，把输入字节转发到 SSH Channel：

```
NSEvent
  → MacTerminalView.keyDown
  → … → send(data:)                          [public, main-thread]
  → RemoteTerminalService.send(source:data:)  [RemoteTerminalService.swift:431, nonisolated]
  → Task { @MainActor in connection.writeChannelInput(data) }
  → SSHConnection.writeChannelInput(_:)       [SSHChannel.swift:262, actor 方法]
  → libssh2_channel_write_ex (actor 隔离内, EAGAIN 重试, partial-write 循环)
  → SSH Channel → Remote Shell
```

`writeChannelInput` 是 `SSHConnection` actor 的方法（`SSHChannel.swift` extension）。Swift actor 隔离保证所有 libssh2 写调用串行，绝不并发进入同一 session/channel handle。写入会先等待在途 open/close 任务尘埃落定（字节不丢，仅顺延），再用 offset+remaining 循环处理 partial write 与 EAGAIN。因此多次程序化 `send` 在 Remote 侧也按入队顺序串行落盘、不交错。

## 7. SwiftTerm paste API

SwiftTerm fork 已具备 paste 基础设施，分布如下：

| 入口 | 可见性 | 位置 | 行为 |
| --- | --- | --- | --- |
| `paste(_:)` | public @objc | `Mac/MacTerminalView.swift:2521` | 读 `NSPasteboard.general`，调 `insertText(_:isPaste:true)` |
| `insertText(_:replacementRange:isPaste:)` | **internal** | `Mac/MacTerminalView.swift:1673` | 真正的 paste 入口：若 `terminal.bracketedPasteMode` 则包裹 start/end 标记，再 `send(txt:)` |
| `send(txt:)` | public | `AppleTerminalView.swift:2910` | String→UTF-8→`send(data:)` |
| `send(data:)` | public | `AppleTerminalView.swift:2885` | 主线程断言；调 delegate `send(source:data:)` |
| `send(_ bytes: [UInt8])` | public | `AppleTerminalView.swift:2925` | 等价 `send(data:)` |

`insertText(_:replacementRange:isPaste:)` 的非 kitty 路径（`:1723`）正是标准 bracketed paste 模式：

```swift
if isPaste, terminal.bracketedPasteMode {
    send(data: EscapeSequences.bracketedPasteStart[...])
}
send(txt: str as String)
if isPaste, terminal.bracketedPasteMode {
    send(data: EscapeSequences.bracketedPasteEnd[...])
}
```

iOS 端 `iOSTerminalView.swift:572` 的 `paste` 展示了同样的规范模式，可作为 MacSSH 复刻的参考。

## 8. bracketed paste behavior

- `Terminal.bracketedPasteMode`（`Terminal.swift:478`，`public private(set)`）：由 shell 经 DECSET 2004（`case 2004` at `:5588`）置位、DECRST 2004（`:5336`）复位。SwiftTerm 已正确跟踪该状态。
- `EscapeSequences.bracketedPasteStart = [0x1b,0x5b,0x32,0x30,0x30,0x7e]`（`ESC[200~`）与 `bracketedPasteEnd = [0x1b,0x5b,0x32,0x30,0x31,0x7e]`（`ESC[201~`）均为 `public static var`（`EscapeSequences.swift:132/136`）。
- SwiftTerm 的 paste 路径**已正确**在 `bracketedPasteMode` 为真时包裹标记；MacSSH 不应再二次包裹。
- `getTerminal()`（`AppleTerminalView.swift:378`，public）可取得 `Terminal` 实例以读取 `bracketedPasteMode`。

**结论**：SwiftTerm 已正确支持 bracketed paste。MacSSH 粘贴应复用 SwiftTerm 的 paste 路径（见 §11），不应自己手写 raw text + 手动 ESC 序列，以免重复包裹或错误插入。

## 9. Return input path

Return 键的字节路径（`Mac/MacTerminalView.swift:1610`）：

```swift
case #selector(insertNewline(_:)):
    send(EscapeSequences.cmdRet)
```

`EscapeSequences.cmdRet = [13]`（`EscapeSequences.swift:78`）= `\r`（0x0D, CR）。

因此用户按 Return → `send(data: [0x0d][...])` → delegate → PTY/SSH Channel → Shell。

（kitty keyboard 增强模式开启时走 `sendKittyFunctionalKey(.enter, …)` at `:1562`，但对普通 shell 仍等价为 CR；MacSSH 的 Execute 复用 `send(data: [0x0d][...])` 与真实 Return 字节完全一致。）

## 10. Terminal.feed role

`feed(byteArray:)` / `feed(text:)`（`AppleTerminalView.swift:2821/2829`，public）调 `terminal.feed(...)`，把字节推进**终端模拟器的屏幕缓冲**（shell→screen 输出路径），**不**经过 `send` delegate、**不**写入 PTY/SSH Channel。

- Local 输出：`LocalProcess.dataReceived(slice:)` → `feed(byteArray:)`（`MacLocalTerminalView.swift:207`）。
- Remote 输出：读取循环 `terminalView.feed(byteArray: output.bytes[...])`（`RemoteTerminalService.swift:322`）。

**确认**：`feed` 是 shell→terminal 的 display input，**不是** user→shell 的 keyboard input。Phase 7 的 Paste/Execute **绝对不能**使用 `feed`，否则只会伪造屏幕内容而没有真正发送到 Shell。符合任务书 §12。

## 11. recommended Paste API

**首选方案（Option A）**：在 SwiftTerm fork 暴露一个 public paste 入口，复用现有 internal `insertText(_:isPaste:true)` 逻辑。

理由：`insertText(_:replacementRange:isPaste:)` 是 internal，MacSSH（独立 module）无法调用。`paste(_:)` 只读系统剪贴板，不接受任意文本。复用 SwiftTerm 已正确实现的 bracketed-paste 逻辑最安全。

建议新增（fork patch，遵循现有 vs16/highlight patch 先例）：

```swift
// Mac/MacTerminalView.swift 或 AppleTerminalView.swift
public extension TerminalView {
    /// 把指定文本作为 paste 发送到终端输入流（user→shell 路径）。
    /// 自动按当前 bracketed paste 模式包裹标记；不附加 Return。
    func pasteText(_ text: String) {
        insertText(text as Any,
                   replacementRange: NSRange(location: 0, length: 0),
                   isPaste: true)
    }
}
```

这是一行级的 fork 扩展，不改动 SwiftTerm 既有逻辑，只在 MacSSH 侧增加一个 public 桥接。

**备选方案（Option B）**：若不希望再动 fork，MacSSH 自行复刻包裹逻辑：

```swift
func pasteText(_ text: String) {
    let tv = activeTerminalView
    if tv.getTerminal().bracketedPasteMode {
        tv.send(data: EscapeSequences.bracketedPasteStart[...])
    }
    tv.send(txt: text)
    if tv.getTerminal().bracketedPasteMode {
        tv.send(data: EscapeSequences.bracketedPasteEnd[...])
    }
}
```

风险：与 SwiftTerm 内部逻辑分叉（未来 SwiftTerm 改 paste 语义时 MacSSH 不跟随）。**Phase 7A 推荐 Option A**。

## 12. recommended Execute API

**Execute = 发送 command 文本 + 一次 Return**，走与键盘相同的 `send` 路径，**不**用 `feed`。

```swift
// 1. 发送命令文本（不带 bracketed paste 包裹——Execute 是单行直接执行，
//    bracketed paste 用于多行/大段粘贴安全，对 Execute 无益且可能干扰）
terminalView.send(txt: command)

// 2. 发送与真实 Return 相同的字节
terminalView.send(data: EscapeSequences.cmdRet[...])   // [0x0d] = \r
```

**为何 Execute 不用 bracketed paste**（回答 §18）：
- bracketed paste 的语义是「把粘贴内容作为字面文本插入，shell 不解释其中的换行/控制字符」。若把 `\r` 放进 bracketed paste 内部，shell 会把它当字面粘贴的 CR 而**不**执行命令——这正是 bracketed paste 要防止的行为。
- 因此 Execute 的 Return 必须在 bracketed paste **之外**。最简单可靠的做法：Execute 根本不启用 bracketed paste，直接 `send(txt:)` + `send(data: [0x0d])`，shell 收到「命令文本 + CR」等同用户手输后按 Return。
- 若 v1 希望统一用 `pasteText`（Option A）发命令文本再补 Return：由于 `pasteText` 在主线程同步完成整个 start+text+end 序列后才返回，随后的 `send(data:[0x0d])` 一定落在 end 标记之后，顺序正确。但为最小化复杂度与副作用，**Phase 7A 推荐 Execute 不走 bracketed paste**，直接 `send(txt:)` + `send(data:[0x0d])`。

对任务书 §16（当前已有 `git chec` 再 Execute `git status`）语义：在当前 cursor 位置发送 `git status` 再发 Return，shell line editor 把 `git chec` + `git status` 拼成 `git checgit status` 后按 Return 提交。MacSSH 不移动 cursor、不猜测 line editor 状态，完全符合 v1 明确语义。

## 13. current active session source

`AppState.sessionManager.activeSession`（`SessionManager.swift:69`）：

```swift
var activeSession: ManagedTerminalSession? {
    sessions.first { $0.id == activeSessionID }
}
```

`activeSessionID: UUID?`（`SessionManager.swift:29`）是单一权威来源。Tab 切换经 `activateSession(id:)`（`:163`）/ `activateTab(at:)`（`:175`）只改 `activeSessionID`，不重建 Shell/连接。关闭 Tab 时 `removeSession`（`:273`）修正 `activeSessionID`（优先左邻、否则右邻、全空为 nil）。

`ManagedTerminalSession`（`Models/ManagedTerminalSession.swift`）持有 `kind`（`.local`/`.remoteSSH`）、`localService`、`remoteService`、`connection`、`connectionInfo`、`displayState`、`activePane`、`hostID`/`hostDisplayName`/`hostname`/`port`。`displayState`（`:234`）统一映射 Local/Remote 的可展示状态（`.active`/`.disconnected`/`.failed`/…）。

## 14. routing architecture

推荐 `TerminalCommandDispatcher`（`@MainActor`，由 `AppState` 持有，任务书 §74）：

```
TerminalCommandDispatcher
  ├─ paste(command:):  resolve active session → 验证可写 → 取 terminalView → pasteText(command) → 恢复焦点
  └─ execute(command:): resolve active session → 验证可写 → 取 terminalView → send(txt: command) → send(data: [0x0d]) → 记录 history → 恢复焦点
```

- **active session 解析**：复用 `appState.sessionManager.activeSession`（§13），绝不缓存旧 `TerminalView`/`service`/`channel`。
- **统一 Local/Remote**：两种 session 的 `terminalView` 都是 SwiftTerm `TerminalView`（Local 是 `LocalProcessTerminalView` 子类，Remote 是 `TerminalView`）。`pasteText`/`send(txt:)`/`send(data:)` 都是 `TerminalView` 的 public 方法，对两者行为一致——SwiftTerm 内部再把字节路由到 PTY（Local）或 `send` delegate → SSH Channel（Remote）。**不需要**在 UI 分别写 Local/Remote 逻辑，天然满足任务书 §19。
- Dispatcher 不持有 UI / storage / history DB；只做「解析 active → 验证 → 调用 SwiftTerm input API → 恢复焦点」。

## 15. disconnected handling

`ManagedTerminalSession.displayState`（`:234`）已统一表达连接级失败/进行态/活跃。Dispatcher 在执行前校验 `displayState == .active`（Remote）或 Local `processState == .running`。

- Remote 非 `.active`（connecting/authenticating/opening/disconnected/failed/exited/closing）：**disable Paste/Execute 动作**（任务书 §22 推荐 disable 而非弹错）。UI 按钮置灰；点击不偷偷丢失 command。
- Local 非 running（exited/failedToStart）：同样 disable。
- 无 active session（`activeSession == nil`，或 `selectedSection != .terminal`）：disable。

不缓存旧 target：每次执行都重新读 `activeSession`，杜绝发错 tab（任务书 §66/§67）。Session 在执行前被关闭时 `activeSession` 已变或为 nil，Dispatcher 自然 no-op/disabled，不 crash。

## 16. focus restoration

现有 `LocalTerminalService.focusWhenAvailable()` / `RemoteTerminalService.focusWhenAvailable()`（均 `Task { @MainActor in window.makeFirstResponder(terminalView) }`）已提供焦点恢复能力，且 `TerminalRepresentable`/`RemoteTerminalRepresentable` 的 `updateNSView` 在 SwiftUI 刷新时调用它。

Phase 7B 建议：Dispatcher 在 `paste`/`execute` 发送字节后调用 active session 对应 service 的 `focusWhenAvailable()`，把 firstResponder 还给 Terminal。Group/command 编辑 sheet 关闭后由 SwiftUI 自然恢复（sheet dismiss 不改 Terminal 焦点所有权，必要时补一次 `focusWhenAvailable`）。

**侧边栏点击导致 Terminal 失焦**（任务书 §80）：SwiftUI Sidebar 的 Button/ScrollView 点击会让 AppKit TerminalView 失去 firstResponder。Phase 7B 需在 Paste/Execute 路径末端显式 `focusWhenAvailable()`；纯浏览（hover 看列表、不触发动作）可不强求回焦，但点击 Sidebar 内任意可执行动作后必须回焦。

## 17. History capture candidates

调查了任务书 §46 的全部候选方案：

| 方案 | Local 可行 | Remote 可靠 | 安全（密码） | 兼容（tmux/REPL） | 结论 |
| --- | --- | --- | --- | --- | --- |
| A. 监听键盘重建 line | 否 | 否 | **否**（无法区分 password prompt） | 否 | ❌ P1 blocker |
| B. 拦截 `send` delegate bytes | 部分 | 部分 | **否**（见 §21） | 否 | ❌ 不安全 |
| C. 读 shell history 文件（`~/.zsh_history`） | 是 | **否**（远端文件需额外协议/权限） | 部分 | 受 tmux/REPL 污染 | ❌ Remote 不可靠 |
| D. shell integration hooks（注入 .zshrc） | 是 | 是（但需改远端配置） | 是 | 是 | ⚠️ 违反 §49，future option |
| E. OSC 133 / FinalTerm semantic prompts | 是 | 是（需 shell 支持） | 是 | 是 | ⚠️ 需 shell 主动发，default zsh/bash 不发 |
| F. 仅记录 MacSSH Saved Command Execute | 是 | 是 | **是** | 是 | ✅ v1 推荐 |
| G. 其他（OSC 1337 / iTerm hooks） | 同 E | 同 E | 是 | 是 | ⚠️ 同 D/E |

## 18. keyboard interception feasibility

**不可行且不安全**。

- SwiftTerm 的键盘处理在 `MacTerminalView.keyDown` → `interpretKeyEvents` → `insertText`/`insertNewline` 等选择子，最终经 `send(data:)`。即使 MacSSH 在 `send` delegate（Remote）或 `LocalProcess.send`（Local）层拦截字节流，拿到的也只是**原始键码字节**，不是「完整 shell command」。
- 用户会用到方向键、Option+Left、Backspace、Ctrl+A/E/U、History Up/Down 等 line-editing 操作。MacSSH 自行重建 input buffer 极易与 shell line editor 不一致（任务书 §10）。
- 更致命：无法区分「用户在 password prompt（sudo/ssh/mysql）后输入的秘密」与「普通命令」（见 §21/§52）。把 password 当命令存进 History 是 P1 安全事故。

**结论**：Phase 7 v1 **禁止**键盘字节拦截作为 history 来源。

## 19. shell history file feasibility

- Local：可读 `~/.zsh_history` / `~/.bash_history`，但：① 需识别 shell 类型与 `HISTFILE` 配置；② 文件只在 shell 退出或按 `history -a` 时落盘，实时性差；③ tmux/REPL 内的命令不进该文件或污染它；④ 无法关联到具体 MacSSH session。
- Remote：需在远端读文件（额外 SFTP/SSH exec 请求、跨 shell 差异、权限问题），**不可靠**，且违反 §49（不要求改远端配置，但被动读远端 shell 文件同样脆弱）。

**结论**：不作为 v1 history 来源。

## 20. shell integration / OSC feasibility

SwiftTerm fork **已完整实现** OSC 133 semantic prompt 解析（`Sources/SwiftTerm/SemanticPrompt.swift`）：
- `SemanticContent`（`.none`/`.prompt(kind)`/`.input`/`.output`）——shell 经 OSC 133 `A`/`B`/`C`/`D` 标记 prompt/input/output 区段。
- `SemanticInputState`（`.idle`/`.prompt`/`.armed`/`.submitted`）——`B`/`I` arm 输入区，`C`/`D`/换行提交。理论上可据此精确捕获「shell 认定的 command input 文本」。
- `Terminal.swift:2001` 已在 paste scan 中识别 `\r`/`\n` 作为 submission。

**但**：OSC 133 需要 shell **主动**发送这些标记。macOS 默认 zsh、远端默认 bash/zsh **不发** OSC 133（需用户在 `.zshrc`/`.bashrc` 安装 integration 脚本，或用支持它的现代 shell 如 fish/最新 zsh 主题）。任务书 §49 明确：**不能要求用户改远端 `.bashrc`/`.zshrc`/`.fish` 作为 v1 基础**。

**结论**：OSC 133 是**理想的远期方案**（一旦 shell 支持，可安全、精确、区分 password prompt 的 capture），但 v1 不依赖它。Phase 7A 标记为 **future option**：未来可提供「启用 Shell Integration（本地/可信远端）」选项，注入 OSC 133 脚本后开启精确 history。v1 不实现。

## 21. password prompt risk

若采用方案 B（拦截 `send` bytes）或 A（重建 line），**无法可靠区分**：
- `sudo` / `su` / `ssh` / `mysql -p` / `psql` 的 password prompt 后输入；
- `mysql -pPASSWORD` / `curl -H "Authorization: Bearer …"` / `export API_KEY=…` 这类用户主动在命令里带 secret 的输入；
- REPL（python `>>>` 后输入）。

regex scrub（如匹配 `password=`/`token=`）是脆弱的（任务书 §41 明确禁止以脆弱 regex 作为安全保证）。因此**任何**基于键盘字节拦截的 history 都存在把 secret 存库的 P1 风险。

**Phase 7A 结论**：禁止自动 keyboard capture 进入 Phase 7B（任务书 §98 的安全测试无法通过）。

## 22. REPL risk

进入 `python`/`node`/`mysql`/`psql` 后，Return 提交的是**该 REPL 的表达式/语句**，不是 shell command。键盘字节拦截或 OSC 133（REPL 通常不发 OSC 133）都无法可靠判断「当前在 shell prompt 还是 REPL prompt」。把 `print("hi")` 误标为 shell history 是错误。

v1 只记录 MacSSH 明确发起的 Execute，天然规避：用户点 Execute 时 MacSSH 知道发送的是「用户保存的 SavedCommand」，无论当前在 shell 还是 REPL，这条记录都是「用户通过 MacSSH 执行的命令」而非「shell 自动认定的命令」。语义清晰、无歧义。

## 23. tmux risk

tmux/screen 内，键盘字节先送给 tmux 而非远端 shell，line editor 状态在 tmux 内部，MacSSH 无法可靠重建。读 history 文件也拿不到 tmux 内命令。v1 不为 tmux 做 hack，明确 limitation（任务书 §50）。

## 24. recommended History v1 scope

**v1 History 只记录 MacSSH 能明确知道属于「命令执行」的动作**（任务书 §47/§53）：

1. **Saved Command → Execute**（用户在常用命令页点 Run）：记录该 command + executedAt + active session 标识。
2. **（可选）History row → Execute**（若 §55 采纳，历史命令复用执行也记录）。

**不记录**：手输键盘命令、粘贴后用户自己按 Return 的命令、REPL 输入。

这保证：① 安全（不碰 password prompt 输入）；② 精确（每条都是 MacSSH 主动发起）；③ Local/Remote 一致；④ 不受 tmux/REPL/shell 类型影响。

**必须向用户明确这一限制**：History 页面标题/说明应注明「仅记录通过本侧边栏执行的命令；手动键入的命令不在记录范围」。不伪装为「完整 shell history」。

## 25. History privacy policy

- command 内容**绝不**进入 OSLog / telemetry / analytics（任务书 §39/§85）。日志最多记 `executed saved command id` / `history count` / `sidebar state`。
- 即使 command 非密钥，仍视为 private user content。
- 不做脆弱 secret scrub；不做 password prompt 检测并据此跳过保存（因为检测不可靠，反而误导）。
- History 数据库本地存储，不云同步、不上传。

## 26. History default

**推荐默认 On**（任务书 §40），理由：
- v1 history 只记录 MacSSH Execute 动作，本身不含 password prompt 输入，隐私风险低；
- 默认 On 让「常用命令 → 执行 → 历史复用」闭环立即成立，体现侧边栏价值；
- 同时提供 Settings 开关与「清空历史」，用户可随时关闭/清除。

若架构验收认为默认 On 仍有顾虑，可改默认 Off（首次展开 History 页时提示开启）。Phase 7A 倾向 **On + 可关 + 可清空**。

## 27. History retention

推荐**全局上限 + 按 session 不单独限**：
- 全局最多保留 **1000 条**（概念值，Phase 7B 可微调）。超出按 `executedAt` 最旧优先删除。
- 不按 session 设独立上限（session 关闭后其历史仍保留，§43）。
- 不做时间 retention（避免复杂定时清理）。
- 超限时一次删除最旧的差额数量，保证顺序正确（任务书 §99）。

1000 条对单机 SQLite/SwiftData 毫无压力；如未来需要更大可调。

## 28. History session scope

**推荐：History 页面默认显示全局所有 session 的记录**，但每条携带 session 标识（sessionType + hostDisplayName）供 UI 区分。

理由：v1 history 来源只有 MacSSH Execute，总量小（不像 shell 全量 history）。用户在 Remote C 执行的命令，切到 Local A 后想复用是很常见场景；若只显示当前 session，跨 host 复用体验差。每条 row 展示 `command` + 可选 `timestamp` + `session/host indicator`（任务书 §54），用户可一眼区分来源。

若架构验收倾向「当前 session」，可作为 UI filter 开关（默认全局，可切当前）。Phase 7A 倾向**默认全局 + row 标注来源**。

## 29. History persistence

**推荐 SwiftData**（任务书 §38）。

- History 可能数量较多（最多 1000 条）、需按 `executedAt` 倒序、按 session 过滤、删除/清空——结构化查询，SwiftData `@Query(sort:)` + `@Model` 天然适合。
- UserDefaults + Codable 的 JSON array 不适合（任务书 §38 明确禁止无限增长 JSON array；1000 条虽不算无限但单 key 大 JSON 读写效率差）。
- 复用现有 `MacSSHApp` 的 `ModelContainer`（§30），新增 `CommandHistoryEntry` model。

`CommandHistoryEntry` 概念字段：
```
id: UUID (@Attribute(.unique))
command: String
executedAt: Date
sessionID: UUID        // 关联 ManagedTerminalSession.id（内存对象，不持久化 session 本身）
sessionKind: String    // "local" / "remoteSSH"
hostDisplayName: String?  // Remote 时存快照（host 显示名，不含凭据）
```

## 30. Saved Command persistence

**推荐 SwiftData**（任务书 §37）。

- 结构化用户数据（groups + commands + sortOrder + CRUD），数量可能较多，未来扩展（host binding/标签/快捷键）。
- SwiftData `@Query(sort:)` + `@Model` + relationship 天然支持 group↔command 关联与排序。
- 与 Host/HostGroup/KnownHost 同容器，复用 `ModelContainer`，一处管理迁移。

不选 UserDefaults：groups+commands 是关系型结构，JSON array 难维护排序与关系、读写效率差。

## 31. Group model

`CommandGroup`（`@Model`）：

```
id: UUID (@Attribute(.unique))
name: String          // 非空（UI/Store 双重校验）
sortOrder: Int
createdAt: Date
updatedAt: Date
@Relationship(deleteRule: .nullify, inverse: \SavedCommand.group)
var commands: [SavedCommand] = []
```

复用 `HostGroup` 的成熟模式（`Models/HostGroup.swift`）：`@Attribute(.unique) var name`、`@Relationship(deleteRule: .nullify, inverse: \Host.group)`。`name` 唯一性可选（HostGroup 强制唯一；CommandGroup v1 可不强制唯一以降低约束复杂度，但推荐唯一）。

## 32. Command model

`SavedCommand`（`@Model`）：

```
id: UUID (@Attribute(.unique))
command: String       // 单行（不含 \n \r，Store+UI 双重校验）
group: CommandGroup?  // nil = 未分组（Ungrouped）
sortOrder: Int
createdAt: Date
updatedAt: Date
```

v1 不加 title/参数模板/变量/host binding/标签/快捷键/脚本语言/AI（任务书 §25）。

关于 §26「是否需要 title」：调查现有 UI 后，命令列表直接显示 `command` 文本即可识别（`git status` 本身就是好标签）。v1 **不加 title**，保持简单；未来若命令含复杂参数导致难辨，再加 title 字段。

## 33. group delete semantics

**推荐：删除 group 时把其中 commands 移到 Ungrouped（group = nil），不级联删除命令**。

复用 `HostGroup` 的 `.nullify` deleteRule 先例（删除主机分组不删主机）。这符合用户预期——删分组是组织操作，不是销毁命令。删除前 UI 弹确认对话框明确告知「将把 N 条命令移到未分组」。

（备选「确认删除全部 commands」更激进，但易误删；v1 选安全的 nullify。）

## 34. single-line validation

`SavedCommand.command` v1 必须拒绝 `\n` / `\r`（含 CRLF）。Store 层与 UI 层**双重校验**：
- UI：表单提交前 `command.contains("\n") || command.contains("\r")` 拒绝；
- Store：`add`/`update` 入口再校验一次，防御绕过 UI 的路径。

允许 `cd /tmp && ls`（单行多命令）。拒绝 `a\nb`、`a\rb`、`a\r\nb`。

## 35. command whitespace policy

**validation 用 trim 判断空，但保存 command 原文**（任务书 §71）。

- 校验：`command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` → 拒绝（空/纯空白）。
- 保存：存用户原文（保留有意义的 shell spacing，如 `  echo hi` 的前导空在某些 shell 有语义）。
- §71 与 §72 协调：先 trim 判空，再校验无换行，最后存原文。

## 36. Sidebar UI hierarchy

```
TerminalWorkspaceView  (现有, Features/Terminal/)
  └─ HStack  (新增：把现有 VStack 内容与右侧栏并排)
      ├─ VStack { TerminalTabBar; Divider; paneSelector; workspaceContent }  (现有, 缩为左部)
      └─ TerminalRightSidebarView  (新增, 右部, 可展开/收起)
           ├─ 顶部固定区: HStack { HistoryIconButton; SavedCommandsIconButton }  (不随滚动)
           └─ 内容区: ScrollView { HistoryView | SavedCommandsView }  (按选中 tab)
```

- 顶部图标切换区**固定**，下方内容区独立 `ScrollView`，滚动时顶部图标不跟随（任务书 §5）。
- 收起时右侧栏宽度为 0（`if expanded`），Terminal 占满；展开时右侧栏占 ~300pt，Terminal 实际 frame 缩小 → SwiftTerm `setFrameSize` 自动重算 cols/rows → PTY/SSH resize（§42）。

## 37. icon selection

顶部两个图标按钮（任务书 §3/§4）：

| 功能 | SF Symbol | 备注 |
| --- | --- | --- |
| 历史记录 | `clock.arrow.circlepath` | 任务书指定 |
| 常用命令 | `command.square` | 任务书备选；`terminal` 已被左侧栏 AppSection.terminal 占用且语义重叠，`command.square` 更贴合「命令集合」语义，避开图标重复。 |

`command.square` 在 macOS 14+ 可用（与项目 deployment target 一致）。不使用自定义图片资源（任务书 §3）。

## 38. selected/hover state

- **选中态**：当前 tab 的图标按钮明显高亮（如 `Color.accentColor` 前景 + 半透明背景胶囊，复用 `AppInteractiveButtonStyle` + `compactBackgroundDiameter`）。
- **未选中**：普通 `.secondary` 前景。
- **hover**：复用 `AppButtonInteractionModifier` 的 `onHover` native 反馈（缩放/底色，受 Reduce Motion 尊重）。
- **一次只选一个**：单一 `@State var selectedTab: SidebarTab`（`.history`/`.savedCommands`）。
- **Tooltip**：`help("历史记录")` + 英文（经 String Catalog，§47）。
- **Accessibility label**：`.accessibilityLabel("历史记录")` / `"常用命令"`，English `"History"` / `"Saved Commands"`。
- 不用 `Picker(.segmented)`（任务书 §79：若出现文字或过宽则改 icon button）。用两个 icon-only `Button` + selected 背景表现 tab selector。

## 39. sidebar width

**第一版固定 ~300pt**（任务书 §6，范围 280–320）。复用 `AppTheme.Layout` 风格，建议在 `AppTheme.Layout` 新增 `rightSidebarWidth: CGFloat = 300`。

v1 不支持用户拖动改宽度，不做 width persistence（任务书 §6）。

## 40. sidebar toggle location

**推荐放在 `AppToolbarContent`（`Components/Toolbar/AppToolbarContent.swift`）**，与现有 `+`（new session）按钮同处 `.primaryAction` 区。

- `AppToolbarContent` 已按 `appState.selectedSection` 条件显示内容，可加：当 `selectedSection == .terminal` 时显示一个 sidebar toggle 按钮（SF Symbol `sidebar.right` 或 `leadingpanel.and.trailingpanel`，按 macOS 原生 sidebar 图标惯例）。
- 不做悬浮自定义按钮覆盖 Terminal（任务书 §7）。
- 该 toggle 绑定 `AppState` 的新 `@State`/`@Observable` 属性 `isRightSidebarVisible: Bool`。

## 41. sidebar state persistence

**推荐 UserDefaults**（任务书 §8，属 UI preference）。

- `isRightSidebarVisible: Bool`（默认 false，首次不自动展开）+ `selectedSidebarTab`（history/savedCommands）存 UserDefaults，复用 `AppLanguage`/`AppPreferenceKey` 模式（`App/AppLanguage.swift`）。
- 在 `AppState` 新增 `private let userDefaults` 已有，新增两个 persisted 属性 + `didSet` 落盘。
- 不进 SwiftData（不是结构化业务数据）。

## 42. Terminal resize implications

展开/收起右侧栏 → `TerminalWorkspaceView` 的 HStack 给 Terminal 部分的新宽度 → SwiftTerm `TerminalView.setFrameSize` 触发 `processSizeChange`（`AppleTerminalView.swift:386`）重算 cols/rows → `sizeChanged` delegate：
- Local：`LocalProcessTerminalView.sizeChanged` → `PseudoTerminalHelpers.setWinSize`（`MacLocalTerminalView.swift:104`）→ PTY resize。
- Remote：`RemoteTerminalService.sizeChanged`（`RemoteTerminalService.swift:446`）→ `connection.resizeChannelPTY`（`SSHChannel.swift:327`，actor）→ `libssh2_channel_request_pty_size_ex`。

该链路 Phase 3/4/5 已验证可用。右侧栏展开/收起只是又一帧 size 变化，**不引入新机制**。Phase 7B 需回归测试：scrollback、selection、cursor、VS16 宽度策略、高亮（Phase 6）在 resize 后不错位（任务书 §82）。

## 43. Local/Remote parity

Paste / Execute 经统一 `TerminalCommandDispatcher` → `TerminalView.pasteText` / `send(txt:)` / `send(data:)`。Local 与 Remote 共用 SwiftTerm `TerminalView` 的 public input API，底层差异（PTY vs SSH Channel）由 SwiftTerm delegate 内部消化。**不在 UI 分别写 Local/Remote 逻辑**（任务书 §19）。

## 44. multi-tab behavior

- 切 Tab（`activateSession`）只改 `activeSessionID`，右侧栏展开状态保持（任务书 §64）。
- History 页（若 §28 选全局）切 Tab 不切数据；若选当前 session 则切 Tab 后 History 列表刷新为 active session 数据。
- Saved Commands 全局共享，切 Tab 不变。
- Paste/Execute 切 Tab 后立即 target 新 active session（Dispatcher 每次实时读 `activeSession`，不缓存旧 target，任务书 §66）。

## 45. UTF-8

`send(txt:)` 经 `[UInt8](txt.utf8)` 编码（`AppleTerminalView.swift:2917`），UTF-8 正确。`echo '中文'`、`echo '😀'` 字节正确。SavedCommand 支持 ASCII/中文/Emoji（任务书 §69）。

## 46. security/logging

- 禁止 `Logger.debug("execute \(command)")` / `Logger.info(command)`（任务书 §85）。
- 日志最多记 `executed saved command id`、`history count`、`sidebar state`。
- command 视作 private user content，不进 OSLog/telemetry/analytics。
- 复用现有 `AppLogger`（`terminal`/`app`/`persistence` 分类），不新增带 command 内容的日志点。

## 47. localization

全部新增 UI 文案走 String Catalog（`MacSSH/Resources/Localizable.xcstrings`），简体中文 + English。复用 `L10n.string/format`（`App/AppLanguage.swift`）。新增 key 至少：

```
sidebar_right.history / 历史记录 / History
sidebar_right.saved_commands / 常用命令 / Saved Commands
sidebar_right.paste / 粘贴到终端 / Paste into Terminal
sidebar_right.execute / 执行命令 / Run Command
sidebar_right.add_group / 新增分组 / New Group
sidebar_right.add_command / 新增命令 / New Command
sidebar_right.edit / 编辑 / Edit
sidebar_right.delete / 删除 / Delete
sidebar_right.rename / 重命名 / Rename
sidebar_right.history_empty / 暂无历史记录 / No command history
sidebar_right.saved_empty / 暂无常用命令 / No saved commands
settings.save_command_history / 保存命令历史 / Save command history
settings.clear_history / 清空历史 / Clear History
common.confirm_delete / 确认删除 / Confirm Delete
common.cancel / 取消 / Cancel
common.save / 保存 / Save
```

## 48. accessibility

- 顶部 icon tab：`help` tooltip + `accessibilityLabel`。
- Paste/Execute：即使 hover 未显示，keyboard/VoiceOver 必须能访问（任务书 §34/§84）。SwiftUI `Button` 天然可键盘聚焦；hover 显示用 `.onHover` 控制可见性但不设 `.focusable(false)`/`.accessibilityHidden(true)`。
- 列表 row 用 `accessibilityElement(children: .contain)` + 子动作按钮独立 label。

## 49. test architecture

Phase 7B 预规划（任务书 §88–§99）：

| 测试 target | 覆盖 |
| --- | --- |
| `TerminalCommandDispatcherTests` | active session routing、disabled states、disconnect safety、UTF-8、quote preservation |
| `SavedCommandStoreTests` | groups CRUD、commands CRUD、single-line validation、whitespace policy、group delete nullify、sorting |
| `CommandHistoryStoreTests` | append、query、clear、retention(1000 上限)、session filter |
| `TerminalRightSidebarStateTests` | expand/collapse、tab select、persistence |
| `TerminalInputTargetTests`（若引入 input abstraction） | paste 不发 Return、execute 发 command+\r、byte-for-byte |

复用现有 `Tests/` 结构（`Tests/Hosts`、`Tests/Security`、`Tests/SSH`）。建议新增 `Tests/CommandSidebar/`。

关键断言：
- `paste("git status")` 仅发送 `git status` 字节，不含 `0x0d`（§89）。
- `execute("git status")` 发送 `git status` + `[0x0d]`（§90）。
- Local A + Remote B，active=B，Execute 只 B 收到（§91）。
- active A → Execute A；切 B → Execute B，不发给 stale A（§92）。
- Remote disconnected：Paste/Execute disabled，不 crash（§93）。
- `echo '中文 😀'` 字节正确（§94）。
- `printf '%s\n' "$HOME test"` byte-for-byte（§95）。
- 拒绝 `""`/`"   "`/`"a\nb"`/`"a\rb"`，允许 `"echo a && echo b"`（§96）。

Dispatcher 测试需可注入「假的 active session + 假 terminalView」以断言字节。可在 `TerminalCommandDispatcher` 设协议接缝（`protocol TerminalInputTarget`），测试注入 mock 记录 `send` 调用。

## 50. P1 risks

1. **History 自动 capture 的安全风险**：若 Phase 7B 偏离 v1 scope 去自动捕获键盘命令，会把 password prompt 输入误存——P1 blocker。**缓解**：v1 严格只记 MacSSH Execute，禁止键盘拦截（§24）。
2. **Execute 字节顺序（bracketed paste + Return）**：若误把 Return 放进 bracketed paste 内部，shell 不执行。**缓解**：Execute 不走 bracketed paste，直接 `send(txt:)`+`send(data:[0x0d])`（§12/§18）。
3. **active session stale target**：切 Tab/关闭 session 后 Dispatcher 用旧 target 发错 tab。**缓解**：每次实时读 `activeSession`，不缓存（§14/§66/§67）。
4. **Terminal resize 后 VS16/highlight 错位**：右侧栏开合触发 resize，Phase 6 的 VS16 宽度策略与高亮重绘需回归。**缓解**：Phase 7B 回归测试（§42/§82）。
5. **`send(data:)` 主线程断言**：Dispatcher 必须在 `@MainActor` 调用，否则 SwiftTerm `assert` 触发。**缓解**：Dispatcher 标 `@MainActor`（§14）。

## 51. P2 risks

1. **Sidebar 点击致 Terminal 失焦**：用户点 Paste 后继续打字进不了 Terminal。**缓解**：Paste/Execute 末端 `focusWhenAvailable()`（§16/§80/§81）。
2. **Saved Command 含 shell 特殊字符的双引号**：`git commit -m "hello"` 必须原样发送，不得 escape。`send(txt:)` 用 `txt.utf8` 原样，天然满足（§70）。
3. **History retention 删除顺序**：超 1000 条时删最旧，需保证 `executedAt` 单调与删除事务正确。**缓解**：SwiftData 删除 + `@Query(sort: executedAt)` 顺序测试（§27/§99）。
4. **SwiftData schema 迁移**：新增 `CommandGroup`/`SavedCommand`/`CommandHistoryEntry` 到现有 `ModelContainer`，不能破坏现有 Host/HostGroup/KnownHost 数据。**缓解**：只新增 model 不改旧 model 字段，SwiftData 轻量迁移天然支持（§86/§87）。
5. **`command.square` 图标可用性**：需确认 macOS 14+ deployment target 下可用。**缓解**：Phase 7B 构建期验证；不可用回退 `terminal` 或其他。

## 52. P3 risks

1. **多 Session 并发 Execute 交错**：用户快速连点 Execute，字节须按序写入。**缓解**：`send(data:)` 主线程串行 + SSH actor FIFO（§68）；Local DispatchIO 串行。
2. **Sidebar 宽度 vs Terminal 最小可见 cols**：窗口较小时展开 300pt 侧栏可能让 Terminal cols 过少。**缓解**：可在窗口宽度不足时 disable 展开或自动收起（v1 可不处理，文档化）。
3. **拖拽排序**（任务书 §58）：v1 不做，用 `sortOrder` 稳定排序即可。
4. **搜索**（任务书 §59）：v1 不做。

## 53. recommended Phase 7B components

| 组件 | 职责 | 位置 |
| --- | --- | --- |
| `TerminalCommandDispatcher` | 解析 active session、验证可写、调 SwiftTerm input API、恢复焦点 | `MacSSH/Services/Terminal/` |
| `SavedCommandStore` | groups/commands CRUD、validation、sorting、SwiftData 持久化 | `MacSSH/Services/Terminal/` 或 `MacSSH/Services/CommandSidebar/` |
| `CommandHistoryStore` | append/query/clear/retention、SwiftData 持久化 | 同上 |
| `TerminalRightSidebarView` | 顶部图标 tab + ScrollView 内容区 | `MacSSH/Features/Terminal/` |
| `HistoryView` | 历史列表 + hover Paste/Execute | 同上 |
| `SavedCommandsView` | 分组折叠列表 + hover Paste/Execute + CRUD | 同上 |
| `CommandGroup`（@Model） | 分组持久化 | `MacSSH/Models/` |
| `SavedCommand`（@Model） | 命令持久化 | `MacSSH/Models/` |
| `CommandHistoryEntry`（@Model） | 历史持久化 | `MacSSH/Models/` |
| SwiftTerm fork patch | `public func pasteText(_:)`（§11 Option A） | `ThirdParty/SwiftTerm-fork/` |

Dispatcher 与 Store 分离：Dispatcher 不持有 UI/Store/History DB；Store 不持有 TerminalView（任务书 §74/§76/§77）。

## 54. recommended implementation sequence

1. **SwiftTerm fork patch**：加 `public func pasteText(_:)`（§11），更新 fork patch diff。
2. **Models**：`CommandGroup`、`SavedCommand`、`CommandHistoryEntry` 加入 `MacSSHApp` 的 `Schema`（§86）。
3. **Stores**：`SavedCommandStore`（SwiftData CRUD + validation）、`CommandHistoryStore`（append/query/retention）。
4. **Dispatcher**：`TerminalCommandDispatcher`（active routing + paste/execute + focus restore + history append on execute）。
5. **Sidebar UI**：`TerminalRightSidebarView` + 顶部图标 tab + `HistoryView` + `SavedCommandsView`，接入 `TerminalWorkspaceView`（HStack）。
6. **Toolbar toggle**：`AppToolbarContent` 加 sidebar 展开按钮，`AppState` 加 `isRightSidebarVisible` + UserDefaults 持久化。
7. **Settings**：`SettingsView` Terminal section 加「保存命令历史」开关 + 「清空历史」按钮。
8. **Localization**：String Catalog 新增全部 key（§47）。
9. **Tests**：§49 全部测试 target。
10. **回归**：Terminal resize / VS16 / highlight / scrollback / selection / cursor / 多 Tab。

## 55. known limitations

- v1 History **不**捕获手动键盘命令、粘贴后用户自按 Return 的命令、REPL 输入、tmux 内命令（§24）。History 页面须明确标注此限制。
- v1 **不**做命令搜索（§59）、拖拽排序（§58）、host-specific commands（§65）、参数模板/变量（§25）。
- v1 **不**做 shell integration / OSC 133 自动 history（§20，future option）。
- v1 右侧栏宽度固定 ~300pt，不可拖动（§39）。
- v1 Saved Command 仅单行（§27/§34）。
- v1 不判断危险命令（§36），Execute 是用户明确动作。
- v1 History 默认全局显示，row 标注来源（§28）。

## 56. 是否建议进入 Phase 7B

**建议进入 Phase 7B**，前提是遵守以下边界：

1. History v1 **只记录 MacSSH Saved Command Execute**（及可选的 History row Execute 复用），**禁止**键盘字节拦截/自动 capture（§17/§18/§21/§24/§47）。
2. Paste 用 SwiftTerm fork 的 `public func pasteText(_:)`（或等价复刻），Execute 用 `send(txt:)`+`send(data:[0x0d])`，**绝不**用 `feed`（§11/§12/§10）。
3. `TerminalCommandDispatcher` 每次实时读 `activeSession`，不缓存 stale target（§14/§66）。
4. 持久化用 SwiftData，新增 model 不破坏现有 Host/HostGroup/KnownHost（§29/§30/§86/§87）。
5. 全部新 UI 双语 + 语义色 + accessibility；日志不含 command 内容（§46/§47/§48）。
6. 右侧栏展开/收起真正缩小 Terminal frame 触发 PTY/SSH resize，不 overlay（§42）。
7. Phase 7B 结束须完成编译、warning 检查、§49 测试、§100 GUI 验收与阶段报告。

Phase 7A 调查完成。**STOP**——等待独立架构验收后才进入 Phase 7B。
