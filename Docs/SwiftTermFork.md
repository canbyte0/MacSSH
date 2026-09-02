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
| Patch branch | `macssh-vs16-preserve-base-width` |
| Production revision | `8a5187fe8182bac3a01f2b82d2621993de5886be` |
| Production dependency | 远端 SwiftPM `remoteSourceControl`（exact revision，不可变 SHA） |
| Patch diff | `Docs/swiftterm-vs16-patch.diff` |
| Package.resolved | `MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` |
| Local dev checkout | `ThirdParty/SwiftTerm-fork`（可选，仅本地 fork 开发用；**不是**生产依赖） |

Fork 基于 upstream base，之上**仅**一个原子 patch commit；不带入任何上游
unrelated commit。生产依赖通过不可变 commit SHA 锁定（`kind = revision`），
不依赖 branch / floating version / range。任意 fresh clone 均可从 GitHub
自动获取同一 patch commit。

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

## 3. Patch 内容（最小且范围窄）

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

## 5. 依赖可复现性（远端 fork）

生产依赖已发布到 GitHub，SwiftPM 以 `remoteSourceControl` + exact revision
方式引用。任意机器 `git clone` MacSSH 后，Xcode/SwiftPM 会自动从
`https://github.com/canbyte0/SwiftTerm.git` 获取 commit
`8a5187fe8182bac3a01f2b82d2621993de5886be`，无需本地 fork 目录。

```
Xcode project reference:
  repositoryURL = "https://github.com/canbyte0/SwiftTerm.git"
  requirement   = { kind = revision; revision = 8a5187fe... }

Package.resolved:
  kind     = remoteSourceControl
  location = https://github.com/canbyte0/SwiftTerm.git
  revision = 8a5187fe8182bac3a01f2b82d2621993de5886be
```

不使用 branch tracking（`macssh-vs16-preserve-base-width`）作为生产依赖
requirement——该 branch 仅用于 fork 上的开发导航，生产锁定值为 immutable SHA。

### 本地 fork 开发 checkout（可选）

`ThirdParty/SwiftTerm-fork` 是可选的本地 fork 开发 checkout，用于直接修改
patch。它被 `.gitignore` 忽略，不进入 MacSSH repo，也不被生产依赖引用。如需
本地开发：

```sh
git clone https://github.com/canbyte0/SwiftTerm.git ThirdParty/SwiftTerm-fork
cd ThirdParty/SwiftTerm-fork
git checkout 8a5187fe8182bac3a01f2b82d2621993de5886be
```

## 6. 测试覆盖

### SwiftTerm fork 内（`Tests/SwiftTermTests/VariationSelector16WidthPolicyTests.swift`）

- 默认模式 ⚠️ → 2、❤️ → 2；兼容模式 ⚠️ → 1、❤️ → 1；
- VS15 不受影响；
- 普通 Emoji（😀/🚀/👍）保持 width 2；
- CJK 保持 width 2；
- Regional indicator（`.wide` 默认）不受影响；
- Keycap：默认 width 2；兼容模式 width 1（与 zsh wcwidth 一致，记录为预期兼容行为）；
- Skin tone modifier 不受影响；
- ZWJ 序列不受直接影响；
- VS16 scalar 在 cluster 中保留（未剥离）；
- bracketed paste 重绘在兼容模式保持干净、默认模式漂移（证明缺陷真实 + 针对性修复）；
- copy/历史行抽取与视觉文本一致；
- SGR 7/27 重绘后命令起点无残留 inverse。

### MacSSH 侧（`Tests/SSH/TerminalVS16WidthPolicyTests.swift`）

- Local Terminal 启用 `.preserveBaseWidth`；
- Remote Terminal 保持 SwiftTerm 默认 `.widenToEmojiWidth`；
- 链接进来的 fork 端到端宽度行为（⚠️/❤️ 默认 2 / 兼容 1、scalar 保留、普通 Emoji、CJK）；
- bracketed paste 重绘 / copy / 长 Emoji / ASCII / 中文 回归。

### MacSSH 依赖身份（`Tests/SSH/DependencyIdentityTests.swift`）

- `Package.resolved` 锁定 SwiftTerm 到 Phase 5 远端 fork patch revision；
- 依赖来源为 `remoteSourceControl`（`https://github.com/canbyte0/SwiftTerm.git`）；
- 不引用本地路径 / `localSourceControl` / 上游 `migueldeicaza/SwiftTerm`。
