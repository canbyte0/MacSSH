# SwiftTerm MacSSH Fork — VS16 Preserve-Base-Width Compatibility

MacSSH 1.1 Phase 5 引入一个 MacSSH 维护的 SwiftTerm fork，作为远端 SwiftPM
source-control 依赖。本文档记录 fork 身份、Local / Remote 宽度策略差异，以及
依赖的可复现性。

## 1. 身份

| 项 | 值 |
| --- | --- |
| Project | SwiftTerm |
| Upstream | `https://github.com/migueldeicaza/SwiftTerm` |
| Upstream base | `464df5207fc2432e16c9a23abe538187196daf5f`（tag `v1.19.0`，即 SwiftTerm 1.19.0） |
| MacSSH-maintained fork | `https://github.com/canbyte0/SwiftTerm` |
| Phase 5 patch branch | `macssh-vs16-preserve-base-width` |
| Phase 5 patch revision | `8a5187fe8182bac3a01f2b82d2621993de5886be`（parent = upstream base） |
| Phase 6 patch branch | `macssh-terminal-highlight-provider` |
| Phase 6 patch revision | `6e56e32e16eba0c3a5f534136da272679085f44c`（parent = Phase 5 patch） |
| **Production revision** | **`6e56e32e16eba0c3a5f534136da272679085f44c`**（Phase 6，当前生产） |
| Production dependency | 远端 SwiftPM `remoteSourceControl`（exact revision，不可变 SHA） |
| Phase 5 patch diff | `Docs/swiftterm-vs16-patch.diff` |
| Phase 6 patch diff | `Docs/swiftterm-highlight-patch.diff` |
| Package.resolved | `MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` |
| Local dev checkout | `ThirdParty/SwiftTerm-fork`（可选，仅本地 fork 开发用；**不是**生产依赖） |

Fork 基于 upstream base，之上**两个原子 patch commit**（Phase 5 → Phase 6），
不带入任何上游 unrelated commit。生产依赖通过不可变 commit SHA 锁定
（`kind = revision`），不依赖 branch / floating version / range。任意 fresh
clone 均可从 GitHub 自动获取同一 patch commit。

## 2. 背景（缺陷根因）

SwiftTerm 1.19.0 默认把 ⚠ (U+26A0)、❤ (U+2764) 等 emoji-VS16 基字符 + VS16
(U+FE0F) 扩展为 cell width 2。macOS zsh 使用系统 `wcwidth()`：基字符 = 1，
VS16 = 0。因此：

```
SwiftTerm visual/model width  >  zsh width
```

在 bracketed paste 重绘（`CSI n D` + command redraw）时，两侧光标列分叉，历史行
漂移成 `eecho ...` / `ececho ...`。PTY write 与 shell command 本身正确，错误发生在
Terminal cell model。Phase 3 baseline 同样可复现——这是既有 SwiftTerm Unicode
width compatibility 缺陷，不是 Phase 4 regression。

## 3. Phase 5 patch 内容（最小且范围窄）

只修改 VS16 width handling 的最小逻辑，新增一个 opt-in 配置，**不**实现完整
system wcwidth emulator / grapheme width engine / locale-dependent width database /
ZWJ 全面兼容层。

### 新 API

```swift
public enum VariationSelector16WidthPolicy: Sendable {
    case widenToEmojiWidth   // 默认：基字符 + VS16 → width 2（既有 SwiftTerm 行为）
    case preserveBaseWidth   // 兼容：基字符 + VS16 → 保留基字符 width
}
```

放入 `TerminalOptions`（`Sources/SwiftTerm/TerminalOptions.swift`）。默认
`.widenToEmojiWidth`，MacSSH Local Terminal 设为 `.preserveBaseWidth`。

### 修改点

`Sources/SwiftTerm/Terminal.swift` VS16 处理分支：当 policy 为
`.preserveBaseWidth` 时，不扩宽到 width 2、不插入 width-0 续接格，保留基字符
原 width。VS16 scalar **仍保留**在 grapheme cluster 中（emoji presentation 不变）。

### 不做的事

- 不删除 VS16 / 不修改 UTF-8 bytes / 不修改 Unicode scalar sequence / 不替换字符
  / 不降级成 text presentation；
- 不拦截 / 重写 / 过滤 PTY data；
- 不检测并改写 CSI（如把 `CSI 22 D` 改成 `CSI 24 D`）；
- 不按字符硬编码（`if char == "⚠️"`）；
- 不在 SwiftTerm 中出现产品名判断 / `#if MACSSH`；
- 不在 parser 热路径每字符调用系统 `wcwidth()` / libc locale lookup；
- 不升级到 1.20.0 / main / 2.0（dependency upgrade 与 VS16 bug fix 严格分离）。

## 4. Local / Remote 宽度策略差异（有意产品决策）

| 终端 | `variationSelector16WidthPolicy` | 说明 |
| --- | --- | --- |
| Local (`LocalTerminalService`) | `.preserveBaseWidth` | macOS 系统.shell 兼容模式：与 zsh 系统 wcwidth 一致 |
| Remote (`RemoteTerminalService`) | `.widenToEmojiWidth`（SwiftTerm 默认） | 远端 Linux / BSD / macOS 的 wcwidth / glibc / musl / libc / locale / Unicode tables 可能不同，Remote 的正确宽度策略不能由本机 macOS wcwidth 决定 |

这是有意产品决策，不是配置遗漏。Remote Terminal **不**启用 Local 的兼容策略。

## 5. Phase 6 patch 内容（generic presentation decoration hook）

Phase 6 在 Phase 5 patch 之上新增第二个原子 patch，为 SwiftTerm 增加通用的、
presentation-only 的 cell background decoration hook，供 MacSSH 终端字符串高亮
（Phase 6B）使用。SwiftTerm **不**知道 MacSSH 的规则模型 / 存储 / 匹配逻辑。

### 新 API

```swift
@MainActor
public protocol TerminalHighlightProvider: AnyObject {
    func cellHighlights(in terminal: Terminal, row: Int) -> [TerminalCellHighlight]?
}

public struct TerminalCellHighlight {
    public let startColumn: Int
    public let endColumn: Int
    public let color: TTColor
}

// TerminalView (macOS + iOS):
public weak var highlightProvider: TerminalHighlightProvider?  // default nil = no-op
```

### 修改点

- `Sources/SwiftTerm/Apple/TerminalHighlightProvider.swift`（新文件）：协议 + 值类型。
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`：
  - `TTColor` typealias 升为 public（与已有 public `TTImage` 一致）；
  - `buildAttributedString`（CG/Metal 共用路径）行首查询 provider，cell 循环内
    `!isSelected` 时注入 `.selectionBackgroundColor` attribute（不改 `.foregroundColor`）。
- `Sources/SwiftTerm/Mac/MacTerminalView.swift` + `iOS/iOSTerminalView.swift`：
  各加 `public weak var highlightProvider`。

### 设计要点

- **default nil = no-op**：`highlightProvider == nil` 时 `cellHighlights` 不被调用，
  attribute 字典与 upstream 完全一致（default parity 测试验证）。
- **presentation-only**：只改 `.selectionBackgroundColor`（renderer 既有背景通道），
  不改 buffer / parser / PTY / copy / foreground。
- **selection > highlight**：`!isSelected` 守卫使选中 cell 不染高亮色。
- **CG/Metal 共用**：复用既有 `SwiftTerm_selectionBackgroundColor` attribute key，
  两路 renderer 的优先级链（`selectionBackground ?? background`）天然生效，零 Metal 改动。
- **weak storage**：无 retain cycle（测试验证 `CFGetRetainCount` 不变）。
- **@MainActor**：与 `buildAttributedString` 调用线程一致。
- **无 MacSSH 名称**：SwiftTerm 中不出现 MacSSH / TerminalHighlightRule / UserDefaults。

### 不做的事

- 不在 SwiftTerm 中实现 literal matcher / rule order / case sensitivity / Settings；
- 不硬编码 MacSSH rule model / 颜色 enum；
- 不修改 buffer / parser / PTY / copy；
- 不修改 cursor / selection 的既有行为；
- 不改 Metal renderer 业务逻辑（仅复用既有背景通道）。

## 6. 依赖可复现性（远端 fork）

生产依赖已发布到 GitHub，SwiftPM 以 `remoteSourceControl` + exact revision
方式引用。任意机器 `git clone` MacSSH 后，Xcode/SwiftPM 会自动从
`https://github.com/canbyte0/SwiftTerm.git` 获取 commit
`6e56e32e16eba0c3a5f534136da272679085f44c`，无需本地 fork 目录。

```
Xcode project reference:
  repositoryURL = "https://github.com/canbyte0/SwiftTerm.git"
  requirement   = { kind = revision; revision = 6e56e32e... }

Package.resolved:
  kind     = remoteSourceControl
  location = https://github.com/canbyte0/SwiftTerm.git
  revision = 6e56e32e16eba0c3a5f534136da272679085f44c
```

不使用 branch tracking 作为生产依赖 requirement——branch 仅用于 fork 上的
开发导航，生产锁定值为 immutable SHA。

### 本地 fork 开发 checkout（可选）

`ThirdParty/SwiftTerm-fork` 是可选的本地 fork 开发 checkout，用于直接修改
patch。它被 `.gitignore` 忽略，不进入 MacSSH repo，也不被生产依赖引用。如需
本地开发：

```sh
git clone https://github.com/canbyte0/SwiftTerm.git ThirdParty/SwiftTerm-fork
cd ThirdParty/SwiftTerm-fork
git checkout 6e56e32e16eba0c3a5f534136da272679085f44c
```

## 7. 测试覆盖

### SwiftTerm fork 内

- Phase 5（`Tests/SwiftTermTests/VariationSelector16WidthPolicyTests.swift`）：
  - 默认模式 ⚠️ → 2、❤️ → 2；兼容模式 ⚠️ → 1、❤️ → 1；
  - VS15 不受影响；普通 Emoji（😀/🚀/👍）保持 width 2；CJK 保持 width 2；
  - Regional indicator 不受影响；Keycap 默认 2 / 兼容 1；
  - Skin tone modifier 不受影响；ZWJ 序列不受直接影响；
  - VS16 scalar 在 cluster 中保留；bracketed paste 重绘干净 / 默认漂移；
  - copy/历史行抽取与视觉文本一致；SGR 7/27 重绘后命令起点无残留 inverse。
- Phase 6（`Tests/SwiftTermTests/TerminalHighlightProviderTests.swift`，13 tests）：
  - nil provider default parity（plain cells undecorated / selection 仍工作）；
  - provider range 精确应用；decoration 经共用 selection background key（Metal 共用）；
  - selection 覆盖 highlight；ANSI foreground 保留；ANSI background 在 highlight 之下；
  - model/copy 不变；weak 生命周期（释放即恢复 default）；retain count 不变；
  - 宽字符双 cell 涂色；VS16 widen / preserve 双策略列涂色。
- SwiftTerm 完整套件：741 tests / 63 suites 全过（含 Phase 5 + Phase 6 + upstream）。

### MacSSH 侧（`Tests/SSH/`）

- `TerminalVS16WidthPolicyTests.swift`：Local/Remote VS16 端到端宽度行为；
- `DependencyIdentityTests.swift`：Package.resolved 锁定当前生产 revision
  （Phase 6 `6e56e32...`）；不引用本地路径 / 上游；Phase 6 parent = Phase 5。
- Phase 6B 新增（待 push 后集成运行）：`TerminalHighlightMatcherTests` /
  `TerminalHighlightStoreTests` / `TerminalHighlightCoordinatorTests`。
