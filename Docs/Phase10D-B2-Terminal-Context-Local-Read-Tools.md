# Phase 10D-B2 — Terminal Context + Local Read-Only Tools

日期：2026-09-10
分支：`feature/macssh-1.1-agent-sidebar`（HEAD `fc07f0f`，未移动）
SwiftTerm pin：`40d473b1fdb456d49cc04b7f253277fcb9ac3987`（未改动 fork）

---

## 1. 本阶段实现

| 组件 | 文件 |
|---|---|
| UTF-8 截断 helper + 硬上限 | `MacSSH/Services/Agent/Tools/AgentUTF8Truncator.swift` |
| Terminal context 值模型 | `MacSSH/Services/Agent/Terminal/AgentTerminalContext.swift` |
| buffer 适配协议 | `MacSSH/Services/Agent/Terminal/AgentTerminalBufferSource.swift` |
| 有界 recent output 提取 | `MacSSH/Services/Agent/Terminal/TerminalRecentOutputSnapshotter.swift` |
| pinned SwiftTerm 适配器 | `MacSSH/Services/Agent/Terminal/SwiftTermTerminalBufferSource.swift` |
| context provider（sessionID 绑定） | `MacSSH/Services/Agent/Terminal/TerminalAgentContextProvider.swift` |
| Local 只读文件服务 | `MacSSH/Services/Agent/Tools/AgentLocalFileService.swift` |
| 工具模型 + 静态注册表 | `MacSSH/Services/Agent/Tools/AgentToolModels.swift` |
| Local-capable router foundation | `MacSSH/Services/Agent/Tools/AgentToolRouter.swift` |
| 错误分类补全 | `AgentToolError`（`unknownTool` / `unsupportedForSession` / `scopeSessionMismatch`） |

未接线：`AgentToolRouter` / `TerminalAgentContextProvider` 在生产代码中零调用点（仅测试使用），
`AgentViewModel` / `AgentSidebarView` / `ResponsesProviderCore` / 两个 Provider 均未修改。

---

## 2. 关键语义

### 2.1 字节预算（§4/§5）
- recent output：≤ 200 physical rows；selection：≤ 64 KiB UTF-8；
  两者合计 ≤ 256 KiB UTF-8（recent output 只使用扣除 selection 后的剩余预算）。
- 截断一律按 UTF-8 bytes，按 Character（grapheme cluster）边界回退：
  放不下的整个字符（含组合序列、Emoji）都不返回。

### 2.2 recent output 提取（§10–§14）
- 只用 `Terminal.getScrollInvariantLine(row:)`，绝不 `getBufferAsData()`。
- 行数未知 → 指数探测 + 二分，**probe 上限 32**（10,000 行 scrollback 实测 29 次探测）。
- `isWrapped` 续行直接拼接，不插入换行；hard cap 仍按 physical rows。
- 只裁尾部纯空白行；前导/内部空格保留。
- `translateToString(trimRight: true, skipNullCellsFollowingWide: true)`：
  宽字符（CJK / Emoji）的 NUL padding cell 必须跳过，否则 context 会带 NUL。

### 2.3 session 绑定（§6/§33/§34）
- `TerminalAgentContextProvider.snapshot(for: sessionID)` 只按显式 sessionID 查找，
  不使用 `activeSession` / selectedTab / 可见会话；session 不存在返回 nil → `sessionUnavailable`。
- `AgentToolRouter.execute(call:sessionID:readScope:)`：
  scope 的 sessionID 与请求的不一致 → `scopeSessionMismatch`；
  readScope 由调用方在 generation 开始时生成并显式传入，router 绝不内部重算。

### 2.4 cwd（§9/§19）
- Local / Remote 都只接受 OSC 7 结构化上报作为 authoritative；无上报 → `unavailable`。
- `get_current_directory`：path 不存在 → success + `unavailable` 三元组；
  只有 session 不存在才 `sessionUnavailable`。

### 2.5 Local 文件工具（§20–§29）
- 全部经 B1 `AgentPathResolver` + `AgentReadScope`，无第二套路由。
- `open` → `fstat` 复核类型（defense-in-depth，resolve 与 open 之间无无关 async 工作）。
- read_file：bounded read（256 KiB + 8 字节探测），NUL / 非法 UTF-8 → `binaryUnsupported`；
  跨边界多字节字符先回退到 code point 边界再解码，绝不误判为 binary。
- list_directory：500 条上限 + `truncated`；排序 = 目录 → 链接 → 文件 → 其它，
  同类内按 UTF-8 字节序（locale 无关）；`lstat` 保留 symbolicLink 类型；隐藏文件不过滤。

### 2.6 Remote 硬 gate（§32/§51）
- Remote：terminal context 与 cwd 元信息允许；
  `read_file` / `list_directory` → `unsupportedForSession`（P1：绝不用本地 FileManager 读同名路径）。

---

## 3. 测试

新增套件（全部 temporary fixture）：

| 套件 | 用例数 | 覆盖 |
|---|---|---|
| `AgentUTF8TruncatorTests` | 16 | 字节预算、中文/Emoji/组合字符不切半、数据层前缀边界、严格 UTF-8 |
| `AgentTerminalContextTests` | 29 | 0/1/24/200/201/10,000 行、probe 有界、wrapped、尾部空行、预算分配、selection 64 KiB、alt screen、A/B 绑定、真实 SwiftTerm 集成（纯文本/无 ANSI/wrapped/alt/宽字符）、真实 Local session 生产装配 |
| `AgentLocalFileServiceTests` | 27 | 相对/绝对/`..` 归一/../逃逸/symlink 逃逸/symlink 在内、missing、目录、非法 UTF-8、NUL、大文件截断、Emoji/中文跨 256 KiB 边界、特殊文件名、权限、空目录/500/501/确定性排序/隐藏文件 |
| `AgentToolRouterTests` | 20 | 四工具注册表、unknownTool、scope mismatch、sessionUnavailable、Local context、Remote context、Local read/list、Remote read/list 拒绝、A/B 隔离、取消 |
| `AgentProviderToolGateTests` | 6 | 请求体只有 model/input/stream、无 tool 关键字、function_call SSE 被忽略 |

### 运行结果

- B2 新增 + B1 回归（AgentCWD / AgentReadScope / AgentPathResolver / LocalShellOSC7）：
  **147 tests, 0 failures**
- §46/§47 回归（LocalShellLauncher / AgentProviderSettings / OpenAI / DeepSeek / AgentViewModel / SSE / ConversationStore / AgentCredentialService）：
  **131 tests, 0 failures**
- 全量（跳过 12 个需要真实 SSH 私钥 + Keychain 凭据的套件）：
  **600 executed / 600 passed / 0 failed / 0 skipped，`** TEST EXECUTE SUCCEEDED **`**

---

## 4. 构建

| 配置 | DerivedData | 结果 | candidate 告警 |
|---|---|---|---|
| Debug（build-for-testing） | `/tmp/MacSSH-Phase10D-B2-Debug` | **TEST BUILD SUCCEEDED** | 0 |
| Release | `/tmp/MacSSH-Phase10D-B2-Release` | **BUILD SUCCEEDED** | 0 |

Debug 全量告警 36 条，全部为既有 test 代码告警（SavedCommandStore / CommandHistoryStore /
TerminalAppearance / LocalShellOSC7 / TerminalCommandDispatcher 等），与 B2 无关。

---

## 5. 范围审计（§50/§51）

- Agent 生产代码中 **0 处** `Process(` / `NSTask` / `libssh2_channel_exec` /
  `TerminalCommandDispatcher.execute` / `pasteText` / `send_to_terminal` / `run_command` /
  `write_file` / `unlink` / `rename` / `mkdir` / `chmod` / `copyItem` / `moveItem` / `removeItem`。
- `FileManager` 仅 `contentsOfDirectory`（listing），无任何修改类 API。
- Agent 代码中无 `SSHConnection` / `SFTPService` / `sftpOpenFileForRead` / `sftpListDirectory`
  引用（仅注释中作为禁用类型出现）。
- 新代码零日志输出（不记录 terminal output / selection / 文件内容 / 完整路径）。

---

## 6. 已知观察（非阻塞）

1. **pinned SwiftTerm 对 astral Emoji 的渲染**：`HeadlessTerminal` 实测 U+1F600 在 buffer 中
   被写成「宽占位 + padding」，context 得到占位间距而非 emoji 本身。这是 upstream 渲染行为
   （与 App 真实 terminal 同一代码路径），不是本层提取缺陷；emoji 的字节级完整性由 fixture
   用例覆盖。
2. **probe 上限 32 的边界**（§12 硬约束）：≤ 10,000 行 scrollback 精确定位尾部；
   更大 scrollback（10 万行级）会退化到「已确认的上界」，仍保证有界、绝不 O(n) 扫描。
3. **B1 已披露的 TOCTOU P3**：本阶段未扩大窗口（resolve → 立即 open → fstat），未消除。
4. `~` / `~user`：本阶段工具调用不传 HOME，`~/x` → `invalidArguments`（不引入 HOME fallback）。
5. **任务书 §52 未收到正文**（消息在 `# 52. Secret` 处截断）。本阶段按最保守默认实现：
   工具结果不落地日志、不记录路径、不新增任何凭据/密钥访问路径。如需 secret 扫描或脱敏，
   待补发后单独实现。
