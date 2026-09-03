# MacSSH 1.1 Phase 6B — 第一 STOP 报告（任务 73）

本报告对应任务书第 73 节的 STOP 点：SwiftTerm fork 第二个 atomic patch 已完成本地 commit 与 fork 测试，MacSSH 本地实现已就绪，请求用户授权 push 到 GitHub 后继续 remote dependency integration。

---

## 1. fork patch SHA

**`6e56e32e16eba0c3a5f534136da272679085f44c`**

## 2. parent SHA

**`8a5187fe8182bac3a01f2b82d2621993de5886be`**（Phase 5 patch，保持不变）

## 3. diff files

```
 Sources/SwiftTerm/Apple/AppleTerminalView.swift            |  26 +-
 Sources/SwiftTerm/Apple/TerminalHighlightProvider.swift    |  58 ++++
 Sources/SwiftTerm/Mac/MacTerminalView.swift                 |   5 +-
 Sources/SwiftTerm/iOS/iOSTerminalView.swift                |   5 +-
 Tests/SwiftTermTests/TerminalHighlightProviderTests.swift  | 358 +++++++++++++
 5 files changed, 450 insertions(+), 2 deletions(-)
```

`git rev-list --count 8a5187fe..6e56e32 = 1`（单 atomic commit，无 squash Phase 5+6，无夹带 unrelated 改动）。

## 4. patch LOC

+450 / -2（其中 358 行为测试，92 行为生产代码）。

## 5. API

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

设计要点：

- 通用命名，无 MacSSH 名称 / UserDefaults / Rule 模型依赖；
- `@MainActor` 标注（与 `buildAttributedString` 调用线程一致，修正 Phase 6A P2 线程语义缺失）；
- weak 存储（无 retain cycle，已测 `viewDoesNotRetainProvider`）；
- `TTColor` typealias 升为 public（与已有 public `TTImage` 一致），使颜色类型可出现在 public API。

Hook 实现：`buildAttributedString` 行首一次 `cellHighlights(in:row:)` 查询 → cell 循环内 `!isSelected` 时注入 `.selectionBackgroundColor` attribute（不改 `.foregroundColor`）。复用既有 selection 背景通道（`SwiftTerm_selectionBackgroundColor` key），CG/Metal 两路 renderer 的优先级链（`selectionBackground ?? background`）天然生效，**零 Metal 改动**。

## 6. default parity

`highlightProvider == nil` 时：

- `cellHighlights` 不被调用（`?.` 短路），`lastHighlightColor` 恒 nil；
- flush 边界条件 `highlightColor != lastHighlightColor` 永不触发额外 flush；
- attribute 字典与 upstream 完全一致（无 `.selectionBackgroundColor` 注入）。

fork 测试 `nilProviderLeavesPlainCellsUndecorated` + `nilProviderKeepsSelectionWorking` 通过——selection 路径不受影响。

## 7. fork tests

**13/13 通过**（`TerminalHighlightProviderTests`）：

1. `nilProviderLeavesPlainCellsUndecorated`
2. `nilProviderKeepsSelectionWorking`
3. `providerAppliesBackgroundToExactRange`
4. `decorationRidesSharedSelectionBackgroundKey`（验证 Metal 共用通道）
5. `selectionOverridesHighlight`
6. `ansiForegroundPreservedUnderHighlight`
7. `highlightSitsAboveAnsiBackground`
8. `modelAndCopyUnchangedWithProvider`
9. `providerReleasedRestoresDefaultRendering`（weak 生命周期）
10. `viewDoesNotRetainProvider`（CFGetRetainCount 不变）
11. `wideCharacterColumnsBothPainted`
12. `vs16WidenPolicyColumnPainting`
13. `vs16PreservePolicyColumnPainting`

**SwiftTerm 完整套件 741 tests / 63 suites 全部通过**（含 Phase 5 `VariationSelector16WidthPolicyTests` 回归 + 全部 upstream 测试，0 failure）。

## 8. MacSSH 当前实现状态

分支 `feature/macssh-1.1-terminal-highlighting` @ `34852a4`（baseline，**未 commit MacSSH 改动**）。

### 改动清单（lint 0 error / 0 warning）

**新增 7 文件：**

| 文件 | 职责 |
| --- | --- |
| `MacSSH/Models/TerminalHighlightRule.swift` | Rule + Color enum + Settings，Codable 向前兼容解码 |
| `MacSSH/Services/Terminal/TerminalHighlightMatcher.swift` | 纯函数，literal substring + first-rule-wins + Unicode cell 映射镜像 SearchEngine |
| `MacSSH/Services/Terminal/TerminalHighlightPalette.swift` | Light/Dark 双模式半透明 sRGB，7 色 |
| `MacSSH/Services/Terminal/TerminalHighlightProviderImpl.swift` | 实现 fork 协议，**无缓存**每行重算（P2 #1 决策） |
| `MacSSH/Services/Terminal/TerminalHighlightStore.swift` | UserDefaults 单 key 原子写、CRUD 空文本双重防御、变更回调 |
| `MacSSH/Services/Terminal/TerminalHighlightCoordinator.swift` | weak NSHashTable、register 即 apply、无条件广播、无 lastApplied race |
| `MacSSH/Features/Settings/HighlightRulesEditor.swift` | 原生 Form + sheet 编辑 + 色点 + 启用开关 |

**修改 5 文件：**

| 文件 | 改动 |
| --- | --- |
| `MacSSH/App/AppState.swift` | +coordinator 字段 + 初始 session backfill 注册 |
| `MacSSH/Services/Terminal/SessionManager.swift` | Local create + Remote reattach 两处 register |
| `MacSSH/Features/Settings/SettingsView.swift` | Terminal Section 嵌入 HighlightRulesEditor |
| `MacSSH/Resources/Localizable.xcstrings` | +18 keys，315→333，中英双语 |
| `MacSSH.xcodeproj/project.pbxproj` | 6 新文件全 section 注册（H6 前缀） |

### Phase 6A P2 修正落实情况

| 修正项 | 状态 | 说明 |
| --- | --- | --- |
| #1 Cache | ✅ 已落实 | v1 **NO CACHE**，ProviderImpl 无任何缓存字段，每帧重算 |
| #2 Performance | ⏳ 待 benchmark | 措辞已修正；待 push 后 benchmark 产出 matcher-only 数据 |
| #3 Dependency identity | ⏳ 待 push 后 | DependencyIdentityTests + Package.resolved + pbxproj + SwiftTermFork.md |
| #4 wrap limitation | ✅ 已落实 | Matcher 注释明确记录"物理行独立匹配，wrap 拆词不命中 = v1 limitation" |

## 9. 是否需要用户授权 push

**是。**

MacSSH 生产依赖是 `remoteSourceControl` + exact immutable SHA（`canbyte0/SwiftTerm.git`）。当前 fork patch `6e56e32` 仅存在于本地 `ThirdParty/SwiftTerm-fork`（gitignored）。要完成 MacSSH 完整集成，必须先把 `6e56e32` push 到 GitHub。

### 请求授权

push `6e56e32e16eba0c3a5f534136da272679085f44c` 到 `https://github.com/canbyte0/SwiftTerm.git` 的 `macssh-terminal-highlight-provider` 分支。

### 授权后将继续

1. 更新 `Package.resolved` revision 到 `6e56e32...`（保持 remoteSourceControl + exact immutable SHA）
2. 更新 `MacSSH.xcodeproj/project.pbxproj` package reference 回 remote + 新 SHA
3. 更新 `Tests/SSH/DependencyIdentityTests.swift`（`swiftTermPatchRevision` / branch / summary）
4. 更新 `Docs/SwiftTermFork.md` + 新增 Phase 6 patch diff
5. Debug / Release clean build + warnings 检查
6. MacSSH 测试套件（Rule / Matcher / Store / Coordinator）
7. 性能 benchmark（20 / 50 / 100 rules）+ 渲染 smoke
8. 全量回归（Phase 1-5 + DependencyIdentity）
9. 最终 Phase 6B 报告（62 项）

---

## 严格遵守

- 未 push fork
- 未 commit MacSSH
- 未改 Package.resolved / pbxproj 切 localSourceControl（避免破坏 immutable SHA 约束）
- 未开始 Phase 7
- 未 merge

**STOP。等待用户授权。**
