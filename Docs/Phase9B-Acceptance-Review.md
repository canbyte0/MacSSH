# MacSSH 1.1 Phase 9B — Independent Code Acceptance Review
# Configurable Terminal Font Size

> 角色：Independent Code Reviewer（非 Phase 9A 调查者，非 Phase 9B 开发者）。
> 方法：源码逐文件独立复核 + git diff + resolved SwiftTerm 源码核查 + fresh DerivedData Debug + Release clean build + 全套测试 + UI preview 图片人工复核。
> **未修改 production code / SwiftTerm fork / commit / merge / push / 未开始下一 Phase。**
> 验收日期：2026-09-04。

---

## 1. Acceptance result

**CONDITIONAL PASS — 允许进入用户 GUI 验收，附 1 项 P2 + 多项 P3。**

理由摘要：
- Git baseline / branch / HEAD / 工作树状态全部符合
- TerminalFontProvider.swift **未被修改**（commit `80e98b7` = Phase 2 引入，working tree clean）
- Controller 通过 `TerminalFontProvider.regularFont(size:)` 现有 API 设置字号（不绕过 Provider）
- 单一 source of truth 链完整：UserDefaults → Controller.size → Provider.regularFont(size:) → TerminalView.font
- weak `NSHashTable<TerminalView>.weakObjects()` registry，3 处 register 点
- UserDefaults 类型处理：`object(forKey:) as? Int` + clamp，对 missing/非 Int/Double/NaN/Infinity/Bool 安全
- Debug + Release fresh DerivedData clean build：**BUILD SUCCEEDED，0 production warning**
- 全 MacSSH 测试：**485 executed / 114 skipped / 0 failures → TEST SUCCEEDED**
- Phase 2-8 regression 0 failure
- SwiftTerm pin `771e79f092a26e7fba7af0ab2b09a2bf10213109` 不变
- **1 项 P2**：Local/Remote PTY resize 证据链不完整（Phase 9A Acceptance §75/§76 显式要求 PTY 级证据，实际测试仅验证上游 SwiftTerm `terminalDelegate.sizeChanged` seam，未达 MacSSH 侧 `setWinSize` / `resizeChannelPTY`）。源码链完整、生产 baseline（sidebar resize）已验证同一链，**非功能缺陷**，仅为证据缺口。
- 多项 P3：报告测试计数 22 vs 实际 20、preview 描述误导、accessibility label 缺失、SwiftTerm 既有副作用。

详见 §67-§69。

---

## 2. P1

**无 P1。** 复核项：
- App crash：`TerminalFontSizeController.init` 只读 UserDefaults + 存 Int；`apply()` 对空 registry no-op；`view.font =` 经 SwiftTerm public API（已被 Phase 9B 测试 + Phase 2 测试验证）。无可 fatalError 路径。
- PTY resize crash：`sizeChanged` → `setWinSize` / `resizeChannelPTY` 是已验证路径（Phase 2 / 7）；font change 只增加触发源，不改 resize 实现。
- font load failure：`TerminalFontProvider.regularFont(size:)` 三级 fallback（PostScript → family+face → `monospacedSystemFont`），size 参数只影响 pointSize 不影响 fallback 链。
- UserDefaults corruption：`load(from:)` `object(forKey:) as? Int` 安全回退 14，不 crash。
- TerminalView leak：`NSHashTable.weakObjects()`（Phase 4 / 6 已验证 50 次 create/close 后 live count = 0）。
- SwiftTerm fork dependency：production pin `771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `canbyte0/SwiftTerm.git`，pbxproj + Package.resolved 双重确认，**未修改 fork**。

---

## 3. P2

**1 项 P2：Local/Remote PTY resize 证据链不完整。**

### P2-1. Phase 9A Acceptance §75 / §76 PTY 级证据未达

Phase 9A Acceptance §75 显式要求：
> "必须证明：font change → Local PTY `setWinSize` 被调用，而非只断言 `view.font.pointSize == 18`"
> "策略：构造 LocalProcessTerminalView（不需真实 shell，只验证 sizeChanged delegate 路径）"

Phase 9A Acceptance §76 显式要求：
> "必须证明：font change → `connection.resizeChannelPTY` 被请求"
> "策略：构造 RemoteTerminalService 用 mock SSHConnection（spy）... 断言 spy 收到 `resizeChannelPTY(columns:rows:)` 调用"

实际 Phase 9B 测试实现：
- `testFontChangeTriggersSizeChangedDelegate` / `testFontChangeSizeChangedColsRowsReflectNewFont`：用 **base `TerminalView`**（非 `LocalProcessTerminalView`，非 `RemoteTerminalService`）+ `SizeChangedSpyDelegate`（实现 SwiftTerm `TerminalViewDelegate`，**非** `LocalProcessTerminalViewDelegate`，**非** `RemoteTerminalService` spy）。捕获的是 SwiftTerm 内部 `terminalDelegate?.sizeChanged` —— 即 Local/Remote PTY resize 链的**上游 seam**。
- `testLocalProcessTerminalViewFontChangeUpdatesCellDimension`：用 `LocalProcessTerminalView`（SwiftTerm 类，**非** MacSSH `ScrollTrackingLocalProcessTerminalView` 子类），**未启动 process**。SwiftTerm `LocalProcessTerminalView.sizeChanged`（`MacLocalTerminalView.swift:104-112`）首行 `guard process.running else { return }` —— 无运行 process 时**短路返回，不调用 `setWinSize`**。本测试仅验证 cellDimension recompute，**未达 `setWinSize` ioctl TIOCSWINSZ**。
- 无 `RemoteTerminalService` + mock `SSHConnection` spy 测试 —— `connection.resizeChannelPTY` 调用**未独立验证**。

证据链状态：
| 链节 | 状态 |
|---|---|
| `view.font = newFont` | ✓ 测试执行 |
| SwiftTerm `font` setter → `resetFont` → `resize` → `sizeChanged(source:)` | ✓ 源码复核（Phase 9A §16） |
| `terminalDelegate?.sizeChanged(source:newCols:newRows:)` | ✓ 测试 spy 捕获（上游 seam） |
| Local: `LocalProcessTerminalView.sizeChanged` → `setWinSize` → `ioctl TIOCSWINSZ` | ✗ 未测试（需 running process + LocalProcessTerminalView 子类） |
| Remote: `RemoteTerminalService.sizeChanged` → `connection.resizeChannelPTY` → libssh2 | ✗ 未测试（需 mock SSHConnection + RemoteTerminalService） |

**减轻情节**（非缺陷，仅证据缺口）：
1. 源码链完整：`LocalTerminalService.swift:42` 用 `TerminalFontProvider.regularFont()`，`RemoteTerminalService.swift:86` 同；`RemoteTerminalService.sizeChanged`（`:446-468`）真实调用 `connection.resizeChannelPTY(columns:rows:)`。SwiftTerm `LocalProcessTerminalView.sizeChanged`（`MacLocalTerminalView.swift:104-112`）真实调用 `PseudoTerminalHelpers.setWinSize(masterPtyDescriptor:windowSize:)` → `ioctl TIOCSWINSZ`。
2. 同一链已被生产 baseline 验证：sidebar resize（Phase 4/7/8）经同一 `sizeChanged` delegate，production 工作正常。
3. 上游 seam **已验证**：测试 spy 捕获 `TerminalViewDelegate.sizeChanged`，证明 font change 触发 SwiftTerm 内部 resize 链。
4. 无实际 bug：源码复核无缺陷，全 MacSSH 测试 0 failure。

**结论**：Phase 9A Acceptance §75/§76 显式 PTY 级证据标准**未达**。但源码链完整 + 生产 baseline 验证 + 上游 seam 已测，**非功能缺陷**。归 P2（证据缺口），允许进入用户 GUI 验收，但应在后续 Phase 或 remediation 补一组真实 LocalProcessTerminalView + running process 的 `setWinSize` spy 测试 + RemoteTerminalService + mock SSHConnection 的 `resizeChannelPTY` spy 测试。

---

## 4. P3

多项 P3（不影响功能正确性）：

### P3-1. 报告测试计数错误（§50 / §51 / §86 / §12）

报告 `Docs/Phase9B-Final-Report.md` §6.1 / §12 称：
> "TerminalFontSizeControllerTests（22 tests，全过）"
> "Phase 9B 新增：35 tests（22 controller + 13 resize）"

**实际**：`grep -c "func test" Tests/SSH/TerminalFontSizeControllerTests.swift` = **20**（非 22）；xcodebuild 实跑 `TerminalFontSizeControllerTests` = **Executed 20 tests, with 0 failures**。

实际新增 = 20 controller + 13 resize = **33 tests**（非 35）。

差异 -2。源码与 xcodebuild 输出一致，报告计数虚高 2 项。

### P3-2. 报告 §1 / §11.2 preview 描述误导（§66 docs accuracy）

报告 §1 称：
> "按 AGENTS.md UI 规则，SettingsView 修改前先给用户 4 张预览图（方案 A 与方案 B × Light/Dark）"

**实际** `generated-images/phase9b-preview/` 4 文件全部以 `A_` 前缀命名：
- `A_pixel_perfect_macOS_native_S_2026-09-04T14-15-02.png` — 方案 A（−/+ 紧凑按钮）Dark
- `A_pixel_perfect_macOS_native_S_2026-09-04T14-15-07.png` — 方案 A Dark（变体）
- `A_pixel_perfect_macOS_native_S_2026-09-04T14-15-12.png` — 方案 B（native Stepper ∧∨）Light
- `A_pixel_perfect_macOS_native_S_2026-09-04T14-15-15.png` — 方案 B（native Stepper ∧∨）Dark

人工复核图片内容：确实包含 2 方案 × 2 模式 = 4 张预览，**UI Preview Gate 实际完成**。但所有文件名前缀 `A_` 与报告"方案 A 与方案 B"描述存在命名/描述不一致，易误导后续审核者以为只有方案 A。

### P3-3. SettingsView 字号按钮 accessibility 不完整（§14）

`SettingsView.swift:67-93` 字号 −/+ 按钮仅有 `.accessibilityIdentifier("settings.fontSizeDecrement" / "settings.fontSizeIncrement")`，**无 `.accessibilityLabel` / `.accessibilityHelp`**。

对比：项目其他按钮（如 `HostTrustDialogView.swift:90`、`AppToolbarContent.swift:38`、`TerminalTabBar.swift:43/51/88`）均提供 `.accessibilityLabel`，且 `TerminalWorkspaceView.swift:137` 提供 `.accessibilityValue`。

字号按钮依赖 SF Symbol `minus` / `plus` 的 auto-description，在非英文 locale 下 VoiceOver 可能读出符号名而非"减小字号" / "增大字号"。`Text("\(fontSizeController.size) pt").monospacedDigit()` 自然读出"14 pt"无问题。

功能不影响（按钮可点击、可定位），但 accessibility 体验低于项目其他控件标准。

### P3-4. 测试类 docstring 误导

`TerminalFontResizeTests.swift:14-15` 类 docstring：
> "本测试用 SwiftTerm 自带 TerminalView API + spy `TerminalViewDelegate` / `LocalProcessTerminalViewDelegate` 捕获 `sizeChanged` 回调"

**实际**：测试代码只实现 `SizeChangedSpyDelegate: TerminalViewDelegate`（`TerminalFontResizeTests.swift:309`），**未实现** `LocalProcessTerminalViewDelegate` spy。docstring 与实现不符，易误导审核者以为 Local PTY 链已被 spy 覆盖。

### P3-5. SwiftTerm 既有副作用（沿用 Phase 9A Acceptance §71）

- background tab font change 触发一次基于旧 frame 的 PTY resize（中间态，最终一致）
- selection 清除：font setter `selectNone()` + `processSizeChange` 在 cols/rows 变化时 `selection.active = false`（SwiftTerm 既有行为，sidebar resize 同路径，非 Phase 9B 新增）
- `terminal.softReset()` 副作用（resize 内调用，同 sidebar resize 路径）
- 不支持 direct typing / ⌘+/⌘-/⌘0 快捷键 / 非整数字号（v1 设计选择，留 future）

---

## 5. branch

`feature/macssh-1.1-terminal-font-size`（从 `main` `c6bf66c` 创建）。

`git branch --show-current` → `feature/macssh-1.1-terminal-font-size` ✓

---

## 6. baseline

`c6bf66c2b985530e6687fefe62cdf08246190e41`（main，含 Phase 8 FINAL PASS + 两轮 GUI remediation）。

`git rev-parse HEAD` → `c6bf66c2b985530e6687fefe62cdf08246190e41` ✓

---

## 7. git diff summary

```
 MacSSH.xcodeproj/project.pbxproj              | 16 +++++++++--
 MacSSH/App/AppLanguage.swift                  |  2 ++
 MacSSH/App/AppState.swift                     | 27 +++++++++++++++++++
 MacSSH/Features/Settings/SettingsView.swift   | 39 ++++++++++++++++++++++++++-
 MacSSH/Resources/Localizable.xcstrings        | 17 ------------
 MacSSH/Services/Terminal/SessionManager.swift | 16 +++++++++++
 Scripts/gen_localizable.py                    |  1 -
 7 files changed, 97 insertions(+), 21 deletions(-)
```

`git diff --check` clean（无空白错误）✓

---

## 8. unrelated changes

**无 unrelated production changes。** 全部 7 modified + 5 untracked 均属 Phase 9B 范围：

Modified（7）：
- `MacSSH.xcodeproj/project.pbxproj` — 注册 3 新文件（Controller + 2 tests）
- `MacSSH/App/AppLanguage.swift` — +`AppPreferenceKey.terminalFontSize`
- `MacSSH/App/AppState.swift` — +`terminalFontSizeController` ownership + 装配 + 回填
- `MacSSH/Features/Settings/SettingsView.swift` — 替换静态 Text 为方案 A −/+ 按钮
- `MacSSH/Resources/Localizable.xcstrings` — 删 `settings.font_size_value`
- `MacSSH/Services/Terminal/SessionManager.swift` — +weak controller + 3 处 register
- `Scripts/gen_localizable.py` — 删 `:266` `settings.font_size_value` 元组

Untracked（5 + 1 dir）：
- `MacSSH/App/TerminalFontSizeController.swift`（生产）
- `Tests/SSH/TerminalFontSizeControllerTests.swift`
- `Tests/SSH/TerminalFontResizeTests.swift`
- `Docs/Phase9A-Acceptance-Review.md` / `Docs/Phase9A-TerminalFontSize-Architecture-Investigation.md` / `Docs/Phase9B-Final-Report.md`
- `generated-images/phase9b-preview/`（4 张 UI preview，不入 commit）

**卫生检查**：
- 无 DerivedData / build 入 commit ✓
- `default.profraw` 0 字节且 gitignored（`git check-ignore default.profraw` 返回该文件名），不在 git status ✓
- 无 /tmp probe 入 commit ✓
- 无 screenshot 入 commit（generated-images/ untracked）✓
- 无 secret / 密钥文件 ✓
- 无本地 SwiftTerm checkout（`ThirdParty/SwiftTerm-fork` 是开发参考，未在 pbxproj 引用，production pin 走 remote `canbyte0/SwiftTerm.git`）✓

---

## 9. UI preview gate

**完成。** 4 张 preview 图片存在于 `generated-images/phase9b-preview/`（untracked，不入 commit），人工复核内容：

| 文件 | 方案 | 模式 |
|---|---|---|
| `A_..._14-15-02.png` | A（−/+ 紧凑方块按钮 + "14 pt" 中间 Text） | Dark |
| `A_..._14-15-07.png` | A（同上，渲染变体） | Dark |
| `A_..._14-15-12.png` | B（native Stepper ∧∨ 按钮） | Light |
| `A_..._14-15-15.png` | B（native Stepper ∧∨ 按钮） | Dark |

实际包含 2 方案 × 2 模式 = 4 张预览，**UI Preview Gate 实际完成**。用户工作记忆记载"用户选择方案 A（−/+ 紧凑方块按钮）"。

⚠️ P3-2：所有文件名前缀 `A_`，与报告"方案 A 与方案 B"描述存在命名不一致，易误导。但实际内容包含两方案，Gate 实际完成。

---

## 10. files added

3 个新文件（生产 + 测试）：
- `MacSSH/App/TerminalFontSizeController.swift`（生产，@MainActor @Observable，207 行）
- `Tests/SSH/TerminalFontSizeControllerTests.swift`（20 tests）
- `Tests/SSH/TerminalFontResizeTests.swift`（13 tests）

另含 3 个 docs（Phase9A Acceptance + Phase9A Investigation + Phase9B Final Report）+ 1 个 untracked preview 目录（4 PNG）。

---

## 11. files modified

7 个修改文件（详见 §7 / §8）。

**特别确认：`TerminalFontProvider.swift` 未被修改**。
- `git status MacSSH/Services/Terminal/TerminalFontProvider.swift` → "nothing to commit, working tree clean"
- `git diff c6bf66c2..HEAD -- MacSSH/Services/Terminal/TerminalFontProvider.swift` → 空
- `git diff -- MacSSH/Services/Terminal/TerminalFontProvider.swift` → 空
- 最后修改 commit = `80e98b7`（Phase 2 字体方案引入）

---

## 12. Controller architecture

`TerminalFontSizeController.swift` 完整审查：

```swift
@MainActor
@Observable
final class TerminalFontSizeController {
    static let defaultSize: Int = 14
    static let minSize: Int = 10
    static let maxSize: Int = 32
    static let step: Int = 1

    private let userDefaults: UserDefaults
    @ObservationIgnored
    private var terminalViews: NSHashTable<TerminalView> = .weakObjects()

    var size: Int { didSet { ... clamp + persist + apply } }

    init(userDefaults: UserDefaults = .standard) { self.size = Self.load(from: userDefaults) }
    func register(_ terminalView: TerminalView) { terminalViews.add(terminalView); terminalView.font = ... }
    func setSize(_ newSize: Int) { size = newSize }
    func increment() { size += Self.step }
    func decrement() { size -= Self.step }
    func apply() { applyFontSizeToAllRegisteredViews() }
    static func load(from:) -> Int { object(forKey:) as? Int + clamp }
    static func clamp(_ value: Int) -> Int { min(max(value, minSize), maxSize) }
    private func applyFontSizeToAllRegisteredViews() { ... view.font = regularFont(size:) }
}
```

职责完整：load / normalize / persist / increase / decrease / register / broadcast。✓

**单一 requested size**：`var size: Int` 是唯一 mutable source。无 `currentFontSize` / `providerSize` / `localSize` / `remoteSize` 第二 mutable source。✓

---

## 13. MainActor

`@MainActor` 标注 ✓（`TerminalFontSizeController.swift:41`）。

- `size.didSet` → persist（`UserDefaults.set` thread-safe）+ apply（`view.font =` 必须 main thread）
- `register(view)` 在 MainActor 调用（SessionManager `@MainActor`）
- `applyFontSizeToAllRegisteredViews` 在 MainActor
- `TerminalView.font` setter 内部 `resetFont()` / `resize()` / `needsDisplay` 均 main thread（SwiftTerm macOS 约束）

全链路同步 MainActor，无 `Task { @MainActor in }` 异步 hop（Local PTY resize 同步，Remote PTY resize 经 actor 但 sizeChanged 回调同步）。✓

---

## 14. preference key

`macssh.terminalFontSize`（`AppLanguage.swift:54` `AppPreferenceKey.terminalFontSize`）。✓

集中在 `AppPreferenceKey` enum，与 `language` / `rightSidebarVisible` / `rightSidebarTab` / `appearanceMode` 同位置。✓

只有 controller 负责读写（详见 §21 单一 writer）。✓

---

## 15. storage type

**Int**（`TerminalFontSizeController.swift:71` `var size: Int`）。✓

API boundary 转 CGFloat：`TerminalFontProvider.regularFont(size: CGFloat(controller.size))`（Controller `:113` / `:199`）。Provider 现有 API 已用 `CGFloat`（`regularFont(size: CGFloat = defaultSize)`），无需改签名。✓

---

## 16. default / min / max / step

集中定义于 `TerminalFontSizeController` 静态常量（不分散到多文件）：
- `defaultSize: Int = 14`（`:46`，与 `TerminalFontProvider.defaultSize = 14.0` 一致）
- `minSize: Int = 10`（`:49`）
- `maxSize: Int = 32`（`:52`）
- `step: Int = 1`（`:55`）

SettingsView 通过 `TerminalFontSizeController.minSize` / `.maxSize` 引用（不重复硬编码）。✓

---

## 17. invalid persistence

`load(from:)`（`:156-161`）实现：

```swift
static func load(from defaults: UserDefaults) -> Int {
    guard let stored = defaults.object(forKey: AppPreferenceKey.terminalFontSize) as? Int else {
        return defaultSize  // 14
    }
    return clamp(stored)
}
```

`object(forKey:) as? Int` 类型校验 + clamp，对各种异常值行为：

| stored | 行为 |
|---|---|
| 缺失 key | `object(forKey:)` nil → fallback 14 |
| String "abc" | `as? Int` nil → 14 |
| Double 17.5 | NSNumber double subtype，`as? Int` nil → 14 |
| Double NaN | 同上 → 14 |
| Double Infinity | 同上 → 14 |
| Bool true | NSNumber bool subtype，Swift `as? Int` 返回 1 → clamp 10 |
| Bool false | 同上 返回 0 → clamp 10 |
| Int 8 | `as? Int` = 8 → clamp 10 |
| Int 40 | `as? Int` = 40 → clamp 32 |
| Int 14 | `as? Int` = 14 → 14 |
| Int.min / Int.max | clamp 10 / 32 |

`TerminalFontSizeControllerTests.testInvalidTypesFallBackToFourteen` / `testExtremeValuesClamp` / `testBelowMinClampsToTen` / `testAboveMaxClampsToThirtyTwo` 实跑通过。✓

未使用 `integer(forKey:)`（对缺失返回 0 无法区分）。✓

---

## 18. Bool handling

如 §17：Bool 通过 NSNumber bool subtype，Swift `as? Int` 返回 1（true）/ 0（false），经 clamp 落到 min 10。**非 invalid type 路径，是 clamp 路径**。

测试 `testInvalidTypesFallBackToFourteen` 显式覆盖：
- `defaults.set(true, ...)` → `controller.size == 10`（"Bool=true → 1 → clamp 10"）
- `defaults.set(false, ...)` → `controller.size == 10`（"Bool=false → 0 → clamp 10"）

✓

---

## 19. fractional numeric handling

如 §17：Double 17.5 / NaN / Infinity 通过 NSNumber double subtype，Swift `as? Int` 返回 nil → fallback 14。

测试 `testInvalidTypesFallBackToFourteen` 显式覆盖：
- `defaults.set(17.5, ...)` → `controller.size == 14`
- `defaults.set(Double.nan, ...)` → `controller.size == 14`
- `defaults.set(Double.infinity, ...)` → `controller.size == 14`

✓

---

## 20. normalization

**clamp-on-load deterministic**。`load(from:)` 返回 clamped 值，但不主动 rewrite UserDefaults。

例：stored 40 → load 返回 32（clamp）→ controller.size = 32，但 UserDefaults 仍存 40。

**rewrite 时机**：`size.didSet` 同步 persist clamped 值。当用户主动修改时触发：
- stored 40 → load 32 → 用户改 31 → didSet → persist 31（norm 完成）
- stored 40 → load 32 → 用户不改 → 下次 launch 仍 load 32（行为一致）

源码 `TerminalFontSizeController.swift:78-85`：
```swift
let clamped = Self.clamp(size)
if clamped != size {
    size = clamped
    return
}
userDefaults.set(size, forKey: AppPreferenceKey.terminalFontSize)
applyFontSizeToAllRegisteredViews()
```

`TerminalFontSizeControllerTests.testSetSizeClampsBeforePersist` 验证：
- `controller.setSize(50)` → `controller.size == 32` + `defaults.object(forKey:) as? Int == 32`（rewrite 32）✓
- `controller.setSize(1)` → `controller.size == 10` + `defaults == 10`（rewrite 10）✓

但 stored 40 不主动 rewrite（load 32 后未触发 didSet，因 init 内赋值不触发 didSet）—— 这与 Phase 9A Acceptance §55 推荐一致："不在 init 主动 rewrite"。deterministic 行为可接受。✓

---

## 21. single writer

**单一 writer**：所有 `macssh.terminalFontSize` 偏好读写只由 `TerminalFontSizeController` 进行。

源码核查：
- `TerminalFontSizeController.load(from:)` 唯一读取入口
- `TerminalFontSizeController.size.didSet` 唯一写入入口（`userDefaults.set(size, forKey: AppPreferenceKey.terminalFontSize)`）
- `SettingsView` 通过 `fontSizeController.decrement()` / `increment()` 调用 controller，**不直接** `UserDefaults.set`
- `AppState` / `SessionManager` / 其他 View 均不直接读写该 key

`grep -rn "macssh.terminalFontSize\|AppPreferenceKey.terminalFontSize" MacSSH/` 结果仅命中 `AppLanguage.swift:54`（定义）+ `TerminalFontSizeController.swift:83/157`（读写）。✓

无 `@AppStorage("macssh.terminalFontSize")` 第二 source。✓

---

## 22. Settings binding

`SettingsView.swift:30`：
```swift
@Bindable var fontSizeController = appState.terminalFontSizeController
```

绑定 shared controller（非 local `@State`，非 `activeTerminalView.font.pointSize`）。✓

按钮调用 `fontSizeController.decrement()` / `fontSizeController.increment()`（经 controller → `size` setter → `didSet` → persist + apply）。✓

`Text("\(fontSizeController.size) pt").monospacedDigit()` 读 `controller.size`（单一 source of truth）。✓

`.disabled(fontSizeController.size <= TerminalFontSizeController.minSize)` / `.disabled(fontSizeController.size >= TerminalFontSizeController.maxSize)` 边界 disable。✓

---

## 23. boundaries

10 时减号 `.disabled` ✓（`SettingsView.swift:75`）
32 时加号 `.disabled` ✓（`SettingsView.swift:91`）

Controller 自身 clamp 防御：
```swift
let clamped = Self.clamp(size)
if clamped != size {
    size = clamped
    return
}
```

测试：
- `testIncrementAtMaxClamps`：32 → increment → 仍 32 ✓
- `testDecrementAtMinClamps`：10 → decrement → 仍 10 ✓
- `testSetSizeClampsBeforePersist`：setSize(50) → 32, setSize(1) → 10 ✓

✓ 不仅 UI disabled，controller 自身也不会越界。

---

## 24. accessibility

**部分不完整**（P3-3）：

`SettingsView.swift:67-93` 字号按钮：
- `.accessibilityIdentifier("settings.fontSizeDecrement")` / `"settings.fontSizeIncrement"` / `"settings.fontSizeValue"` ✓（UI test 可定位）
- **无 `.accessibilityLabel` / `.accessibilityHelp`** ✗

对比项目其他控件：
- `HostTrustDialogView.swift:90` `.accessibilityLabel("accessibility.host_trust_dialog")`
- `AppToolbarContent.swift:38` `.accessibilityLabel(...)`
- `TerminalTabBar.swift:43/51/88` `.accessibilityLabel("terminal.new_local" / "accessibility.terminal_tabs" / ...)`
- `TerminalWorkspaceView.swift:137` `.accessibilityValue(Text(verbatim: "\(Int(sidebarWidth.rounded())) pt"))`

字号按钮依赖 SF Symbol `minus` / `plus` 的 auto-description，在非英文 locale 下 VoiceOver 可能读出符号名而非"减小字号" / "增大字号"。`Text("\(size) pt")` 自然读出"14 pt"无问题。

功能不影响，但 accessibility 体验低于项目其他控件标准。归 P3。

---

## 25. font_size_value cleanup

**3 处同步删除** ✓：

1. `MacSSH/Features/Settings/SettingsView.swift`：旧 `Text("settings.font_size_value")` 已被方案 A `HStack { Button + Text + Button }` 替换（diff `:55-57` 删，新代码 `:65-93` 加）✓
2. `MacSSH/Resources/Localizable.xcstrings:3693-3708`：`"settings.font_size_value"` 整个 catalog 条目已删除（diff 删 17 行）✓
3. `Scripts/gen_localizable.py:266`：`("settings.font_size_value", "14 pt", "14 pt"),` 行已删除（diff 删 1 行）✓

`grep -rn "font_size_value" MacSSH/ Scripts/ Tests/` 返回 0 匹配（exit code 1）✓

`LocalizationTests.testCatalogHasNoObsoleteKeys` 实跑通过（21 tests, 0 failures）✓

---

## 26. gen_localizable cleanup

如 §25 第 3 项：`Scripts/gen_localizable.py` 原 `:266` `("settings.font_size_value", "14 pt", "14 pt"),` 行已删除（diff `-1` 行）。✓

下次 regen Catalog 不会重新加入 obsolete key。✓

---

## 27. LocalizationTests

`xcodebuild test -only-testing:MacSSHTests/LocalizationTests` 实跑：
```
Test Suite 'LocalizationTests' passed at 2026-09-04 23:19:35.896.
    Executed 21 tests, with 0 failures (0 unexpected) in 0.059 (0.062) seconds
```

包含：
- `testCatalogHasNoObsoleteKeys` ✓ PASS
- `testCatalogKeysAllHaveCompleteTranslations` ✓ PASS

0 failures ✓

---

## 28. FontProvider usage

Controller **使用 `TerminalFontProvider.regularFont(size:)`** 现有 API（baseline 已存在）：

```swift
// TerminalFontSizeController.swift:113 (register)
terminalView.font = TerminalFontProvider.regularFont(size: CGFloat(size))

// TerminalFontSizeController.swift:199 (apply)
let font = TerminalFontProvider.regularFont(size: CGFloat(size))
```

**不绕过 FontProvider**。✓

不直接 `NSFont(...)` / `withSize(...)` / `font.withSize(...)`。✓

Phase 2 bundled JetBrains Mono identity + cascade fallback（PingFang SC + Apple Color Emoji）完整保留。✓

`TerminalFontProvider.swift` 未被修改（commit `80e98b7` = Phase 2 引入，working tree clean）✓

---

## 29. source-of-truth chain

```
UserDefaults(macssh.terminalFontSize)
  → TerminalFontSizeController.size (Int 10...32)
  → TerminalFontProvider.regularFont(size: CGFloat(size))
  → per-TerminalView.font (NSFont)
```

不维护 `terminalFontSizeRuntime` / `swiftUIFontSize` / `terminalViewPointSize` 等第二套 mutable state。`TerminalFontProvider` 保持 stateless，只接收 size 参数。✓

baseline `TerminalFontProvider.defaultSize = 14.0` 仍只作为 **default**（无偏好时 fallback），不是 runtime hard-coded source。✓

---

## 30. registry

`TerminalFontSizeController.terminalViews` = `NSHashTable<TerminalView>.weakObjects()`（`:65-66`）。✓

与 `TerminalAppearanceCoordinator.terminalViews` / `TerminalHighlightCoordinator.terminalViews` 同模式。Session 关闭 → Service 释放 → TerminalView 释放 → NSHashTable 槽位自动 nil；`allObjects` 访问时自动回收。✓

---

## 31. weak lifecycle

`NSHashTable<TerminalView>.weakObjects()` 是 weak 引用。✓

无强持有 session view，无 TerminalView leak。`TerminalAppearanceTests` / `TerminalHighlightCoordinatorTests` 已验证 50 次 create/close 后 live count = 0（同一 weak 表实现，语义等价）。✓

`TerminalFontSizeControllerTests` 未重复 unstable 的 weak-zeroing 单测（注释说明：TerminalView 自身 Timer/subviews/closures 可能造成 self 暂时强引用，单测无 window 难可靠触发 dealloc；与 Appearance/Highlight Coordinator 共用同一 weak 表实现，语义等价）。

---

## 32. registration points

**3 处实际 registration 点** ✓（Phase 9A Acceptance §44 / P3-2 修正）：

| # | 文件:行 | 时机 |
|---|---|---|
| 1 | `SessionManager.swift:142`（diff `:139+4`） | `createLocalSession` 新建 Local |
| 2 | `SessionManager.swift:464`（diff `:461+3`） | `runConnectFlow` 新建 Remote（reconnectingService=nil 分支）|
| 3 | `AppState.swift:205`（diff `:198+5`） | AppState 装配末尾回填初始 Local Session |

Reconnect reattach（`SessionManager.swift` 复用现有 TerminalView 路径）**不 register**（与 Appearance / Highlight 同模式）。✓

---

## 33. duplicate registration

`NSHashTable.add(_:)` 对同一 object 多次 add **幂等**（NSHashTable 文档：same object won't create duplicate entries）。✓

`register(view)` 实现：
```swift
func register(_ terminalView: TerminalView) {
    terminalViews.add(terminalView)
    terminalView.font = TerminalFontProvider.regularFont(size: CGFloat(size))
}
```

重复 register 同一 view：
- `add` no-op（无 registry 增长）✓
- `view.font =` 重设（idempotent，因 font 是 computed property setter，每次重新走 resetFont）✓

无多次 apply 问题，无 registry duplicate growth，无生命周期问题。✓

`AppState.swift:201-204` 注释明确说明："实际 SessionManager.createLocalSession 内已通过 weak controller 注册过，此处的 register 是冗余但幂等的——与 Appearance / Highlight 同模式，保留对称"。✓

---

## 34. AppState ownership

`AppState.swift:61` `let terminalFontSizeController: TerminalFontSizeController`（strong own，单一 controller）。✓

装配顺序（`AppState.swift:139-150`）：
1. `let terminalFontSizeController = TerminalFontSizeController(userDefaults: userDefaults)`（`:139`，在 SessionManager 之前创建）
2. `self.terminalFontSizeController = terminalFontSizeController`（`:140`）
3. `let sessionManager = SessionManager(sshService: sshService)`（`:142`，**SessionManager 之后创建**）
4. `sessionManager.terminalFontSizeController = terminalFontSizeController`（`:150`，weak 注入）

SessionManager 使用同一实例（`sessionManager.terminalFontSizeController` weak 引用）。✓
SettingsView 使用同一实例（`@Bindable var fontSizeController = appState.terminalFontSizeController`，`SettingsView.swift:30`）。✓

---

## 35. no-active-session

0 session 时 `terminalViews` registry 为空。✓

用户 14 → 18 → `size.didSet` → persist `macssh.terminalFontSize = 18` + `apply()` no-op（`liveViewCount = 0`，无 live view）。✓

之后 `createLocalSession` → register 时 `view.font = regularFont(size: 18)` → 首帧 18。✓

`TerminalFontSizeControllerTests.testZeroTerminalChangeSizePersistsAndApplyIsNoOp` 实跑通过：
```
[Terminal] Terminal font size applied to 0 view(s) (size=20)
```
✓

---

## 36. existing sessions

`applyFontSizeToAllRegisteredViews()` 遍历全部 live view 执行 `view.font =`，与 `TerminalAppearanceCoordinator.applyCurrentAppearanceToAllRegisteredViews()` 同构。✓

`TerminalFontSizeControllerTests.testSizeChangeBroadcastsToAllRegisteredViews`：
- 注册 Local + RemoteA + RemoteB（3 view）
- `controller.setSize(20)`
- 断言 3 view `font.pointSize` 全变 20 ✓

```
[Terminal] Terminal font size applied to 3 view(s) (size=20)
```

不只 active session，全部 registered view 都广播。✓

---

## 37. new Local

`SessionManager.createLocalSession` 创建 service 后立即 register（`SessionManager.swift:142`），此时 SwiftUI 尚未插入 view（view 持有于 service 内）。

`register` 立即 `view.font = regularFont(size: controller.size)`，在 `setFrameSize` 触发 `processSizeChange` 前 cellDimension 已对齐 controller.size。首帧即请求字号。✓

`TerminalFontSizeControllerTests.testNewlyRegisteredViewGetsCurrentSizeImmediately`：
- `controller.setSize(24)`
- 创建 new LocalProcessTerminalView
- `controller.register(newView)`
- 断言 `newView.font.pointSize == 24`（非 defaultSize 14）✓

---

## 38. new Remote

`SessionManager.runConnectFlow` 在认证成功后创建 service（`SessionManager.swift:439-443`）并立即 register（`SessionManager.swift:464`），与 Local 同模式。✓

注释（`SessionManager.swift:462-463`）："Remote 同样应用当前字号——Local / Remote 在 font 构造与注册上完全同源"。✓

`RemoteTerminalService.swift:86` 用 `TerminalFontProvider.regularFont()`（默认 14）构造初始 view，register 时 controller 覆盖为当前 size。✓

---

## 39. frame-zero

`AppleTerminalView.swift:301` `resetFont` 内：
```swift
if (frame.width > 0) && (frame.height > 0) {
    // 计算 newCols/newRows 并 resize
}
```

frame == 0（view 未 layout）时：
- `resetCaches()` 仍执行 ✓
- `cellDimension = computeFontDimensions()` 仍执行 ✓
- `resize` **跳过** ✓
- `updateCaretView` 仍执行 ✓
- `needsDisplay = true` 仍设 ✓

后续 SwiftUI `setFrameSize` → `processSizeChange` 用新 cellDimension 计算 cols/rows → resize → sizeChanged → PTY resize。**无永久错误 geometry**。✓

`TerminalFontResizeTests.testFontChangeAtZeroFrameDoesNotTriggerResize` 实跑通过：
- `view = TerminalView(frame: .zero, ...)`
- `view.font = regularFont(size: 18)`
- `spy.sizeChangedCallCount == 0`（resize 跳过）✓
- `view.caretFrame.size.width > 0`（cellDimension 已更新）✓

---

## 40. SwiftTerm SHA

`771e79f092a26e7fba7af0ab2b09a2bf10213109` @ `canbyte0/SwiftTerm.git`。

独立复核：
- `MacSSH.xcodeproj/project.pbxproj`：`repositoryURL = "https://github.com/canbyte0/SwiftTerm.git"` + `kind = revision`（git log 无变更）
- `MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`：`"revision" : "771e79f092a26e7fba7af0ab2b09a2bf10213109"` ✓
- `xcodebuild -list` 输出："SwiftTerm: https://github.com/canbyte0/SwiftTerm.git @ 771e79f" ✓

Phase 9 未改 fork。✓

---

## 41. TerminalView.font API

resolved SwiftTerm `MacTerminalView.swift:334-343`（独立行号复核）：

```swift
public var font: NSFont {
    get {
        return fontSet.normal
    }
    set {
        fontSet = FontSet (font: newValue)
        resetFont()
        selectNone()
    }
}
```

- **public** get/set（可在 MacSSH 模块外直接 `terminalView.font = newFont`）✓
- getter 返回 `fontSet.normal`（regular）
- setter 三步：替换 `fontSet`、调用 `resetFont()`、调用 `selectNone()`

`fontSet` 字段：`var fontSet: FontSet`（internal storage，setter 通过 public `font` 间接赋值）。

---

## 42. resetFont path

```
terminalView.font = newFont                              MacTerminalView.swift:338
  → fontSet = FontSet(font: newFont)                     MacTerminalView.swift:339
    → FontSet.init(font: fontSize:)                     MacTerminalView.swift:164-169
      → normal = baseFont
      → bold = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask])
      → italic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask])
      → boldItalic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask, .boldFontMask])
  → resetFont()                                          MacTerminalView.swift:340
    → resetCaches()                                       AppleTerminalView.swift:299
    → cellDimension = computeFontDimensions()             AppleTerminalView.swift:300
    → if frame.width > 0 && frame.height > 0:           AppleTerminalView.swift:301
        newCols = Int(getEffectiveWidth(size: frame.size) / cellDimension.width)  :306
        newRows = Int(frame.height / cellDimension.height)                          :307
        resize(cols: newCols, rows: newRows)              AppleTerminalView.swift:308
          → terminal.resize(cols:rows:)                  AppleTerminalView.swift:2819
            [buffer reflow，保留 scrollback]
          → sizeChanged(source: terminal)                AppleTerminalView.swift:2820
            → terminalDelegate?.sizeChanged(source:newCols:newRows:)  MacTerminalView.swift:3252
              → Local: LocalProcessTerminalView.sizeChanged / Remote: RemoteTerminalService.sizeChanged
          → terminal.softReset()                         AppleTerminalView.swift:2821
            [DEC mode 复位，不清 buffer]
    → updateCaretView()                                   AppleTerminalView.swift:310
    → needsDisplay = true                                 AppleTerminalView.swift:313
  → selectNone()                                          MacTerminalView.swift:341
```

源码证据完整（非"SwiftTerm 会自动 resize"模糊描述）。✓

---

## 43. cell-width algorithm

`AppleTerminalView.swift:428-429` 独立复核：
```swift
let glyph = fontSet.normal.glyph(withName: "W")
let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width
```

**仅取 "W" glyph 的 advancement**（非 max(advance, bounding)）。

Phase 9B 报告 §6.1 措辞已修正："cellDimension（caretFrame.size）随 size 线性"，未再写 max(advance, bounding)。P3-1 已修正。✓

`TerminalFontResizeTests.testCellDimensionScalesWithFontSize` 通过 `view.caretFrame.size` 实测 cellWidth/cellHeight 随 size 线性，证明 cellWidth algorithm 行为正确。✓

---

## 44. geometry probe

Phase 9A Acceptance §30 已运行 `/tmp/macssh_phase9a_probe/probe.swift`（base 14/16/18/24 + NSFont.monospacedSystemFont + cascade PingFang SC + Apple Color Emoji），实证：

| size | cellWidth | cellHeight | cols (1000×600) | rows |
|---|---|---|---|---|
| 14 | 8.6543 | 17.0 | 115 | 35 |
| 16 | 9.8906 | 19.0 | 101 | 31 |
| 18 | 11.1270 | 22.0 | 89 | 27 |
| 24 | 14.8359 | 29.0 | 67 | 20 |

- cell dimensions 随 size 增大 ✓
- cols/rows 随 size 增大而合理减少 ✓
- Bold/Italic/BoldItalic pointSize 与 Regular 完全一致 ✓

Phase 9B `TerminalFontResizeTests.testCellDimensionScalesWithFontSize` + `testColsRowsChangeWithFontSizeAtFixedFrame` 在 800×400 frame + JetBrains Mono 实证相对关系（cellW18>cellW14, cellH18>cellH14, cols18<cols14, rows18<rows14）。✓

---

## 45. Local PTY resize

**P2 Gate — 证据不完整**（详见 §3 P2-1）。

源码链完整：
```
font setter → resetFont → resize(cols:rows:)                       AppleTerminalView.swift:308
  → terminal.resize + sizeChanged(source:)
    → terminalDelegate?.sizeChanged(source:newCols:newRows:)       MacTerminalView.swift:3252
      → LocalProcessTerminalView.sizeChanged(source:newCols:newRows:)  MacLocalTerminalView.swift:104
        → guard process.running else { return }                     MacLocalTerminalView.swift:105
        → getWindowSize()                                           MacLocalTerminalView.swift:108
        → PseudoTerminalHelpers.setWinSize(masterPtyDescriptor:windowSize:)  MacLocalTerminalView.swift:109 / Pty.swift:117-124
          → ioctl(masterFd, TIOCSWINSZ, &winsize)                   Pty.swift:120
        → processDelegate?.sizeChanged(source:newCols:newRows:)     MacLocalTerminalView.swift:111
          → LocalTerminalService.sizeChanged                       LocalTerminalService.swift:185
            → session.columns = newCols
            → session.rows = newRows
            → scrollIndicatorController.update()
```

**测试证据**：
- ✓ `testFontChangeTriggersSizeChangedDelegate`（base `TerminalView` + `TerminalViewDelegate` spy）：证明 SwiftTerm 内部 `terminalDelegate.sizeChanged` 触发（上游 seam）
- ✓ `testFontChangeSizeChangedColsRowsReflectNewFont`：sizeChanged 报告的 newCols/newRows 反映新 font geometry
- ✓ `testLocalProcessTerminalViewFontChangeUpdatesCellDimension`（`LocalProcessTerminalView` 无 running process）：cellDimension recompute 验证
- ✗ **未测**：`LocalProcessTerminalView` + running process + `processDelegate` spy 验证 `setWinSize` 实际触发
- ✗ **未测**：`PseudoTerminalHelpers.setWinSize` mock / spy 验证 `ioctl TIOCSWINSZ` 实际调用

Phase 9A Acceptance §75 显式要求 PTY 级证据（"必须证明 font change → Local PTY `setWinSize` 被调用"），实际未达。**P2**（证据缺口，源码链完整，生产 baseline 已验证同一链）。

---

## 46. Remote PTY resize

**P2 Gate — 证据不完整**（详见 §3 P2-1）。

源码链完整：
```
font setter → resetFont → resize(cols:rows:)                       AppleTerminalView.swift:308
  → terminal.resize + sizeChanged(source:)
    → terminalDelegate?.sizeChanged(source:newCols:newRows:)       MacTerminalView.swift:3252
      → RemoteTerminalService.sizeChanged(source:newCols:newRows:)  RemoteTerminalService.swift:446-468
        → session.columns = newCols                                 RemoteTerminalService.swift:453
        → session.rows = newRows                                    RemoteTerminalService.swift:454
        → scrollIndicatorController.update()                        RemoteTerminalService.swift:455
        → guard sizeChanged (cols/rows 变化)                        RemoteTerminalService.swift:457
        → try await connection.resizeChannelPTY(columns:rows:)     RemoteTerminalService.swift:462
          → SSHConnection actor 内 libssh2_channel_request_pty_size_ex  [Phase 7 实现]
```

**测试证据**：
- ✓ `testFontChangeTriggersSizeChangedDelegate`（base `TerminalView` + `TerminalViewDelegate` spy）：证明 SwiftTerm 内部 `terminalDelegate.sizeChanged` 触发（上游 seam，RemoteTerminalService.sizeChanged 的入口）
- ✗ **未测**：`RemoteTerminalService` + mock `SSHConnection` spy 验证 `resizeChannelPTY(columns:rows:)` 实际调用

Phase 9A Acceptance §76 显式要求（"必须证明 font change → `connection.resizeChannelPTY` 被请求"），实际未达。**P2**（证据缺口，源码链完整，生产 baseline 已验证同一链）。

---

## 47. explicit resize absence

Phase 9B **未额外手工调用** `resizePTY` / `sizeChanged` / `resizeChannelPTY` 来重复 SwiftTerm resize。✓

`grep -rn "resizePTY\|sizeChanged\|resizeChannelPTY" MacSSH/App/TerminalFontSizeController.swift`：
- 无 `resizePTY` 调用 ✓
- 无 `sizeChanged` 调用 ✓
- 无 `resizeChannelPTY` 调用 ✓

Controller 只更新 `TerminalView.font`（`view.font = regularFont(size:)`），SwiftTerm `font` setter 内置完整 resize 链。✓

---

## 48. rapid changes

`TerminalFontSizeControllerTests.testRapidChangesProduceFinalState`：
- 14 → increment × 4（15 → 16 → 17 → 18）
- `controller.size == 18` ✓
- `view.font.pointSize == 18`（"全 MainActor 同步：最终 view.font 必须 18"）✓
- `defaults.object(forKey:) as? Int == 18` ✓

全 MainActor 同步：
- 每次 `size.didSet` 同步 persist + apply
- 每次 apply 同步 `view.font =` → `resetFont()` → `resize()` → `sizeChanged` → PTY resize
- Local PTY resize 同步（`ioctl` 直接返回）
- Remote PTY resize 经 actor 串行队列，按 14→15→16→17→18 顺序执行
- 最终 terminal 停在 18，PTY 也是 18

无异步队列、无 reordering 风险。✓

（注：测试用 base `TerminalView` 无 running process / 无 SSHConnection，所以 PTY resize 实际未触发；但 controller.size + UserDefaults + view.font.pointSize 三者一致性已验证。）

---

## 49. Regular identity

`TerminalFontResizeTests.testRegularIdentityAtMultipleSizes`：14 / 18 / 24 下：
- `font.fontName.contains("JetBrainsMono")` ✓
- `font.pointSize == size` ✓
- `TerminalFontProvider.isFontSourcedFromBundle(font)` ✓

Phase 2 `TerminalFontProviderTests.testRegularFontIdentityIsJetBrainsMono`（default 14）已验证 baseline identity。Phase 9B 扩到 18 / 24。✓

Regular 仍为 bundled JetBrains Mono，未变 Menlo / SF Mono。✓

---

## 50. Bold identity

`TerminalFontResizeTests.testBoldDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`：14 / 18 / 24 下：
- 模拟 SwiftTerm FontSet 派生：`NSFontManager.shared.convert(regular, toHaveTrait: [.boldFontMask])`
- `bold.fontName.contains("JetBrainsMono")` ✓
- `bold.fontName.contains("Bold")` ✓
- `bold.pointSize == size` ✓

Phase 2 `TerminalFontProviderTests.testBoldFontIdentityIsJetBrainsMono`（default 14）已验证。Phase 9B 扩到 18 / 24。✓

Bold 仍为 bundled JetBrainsMono-Bold（经 NSFontManager convert traits 派生，因 MacSSH 已 register 全部 4 bundled TTF）。✓

---

## 51. Italic identity

`TerminalFontResizeTests.testItalicDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`：14 / 18 / 24 下：
- `italic.fontName.contains("JetBrainsMono")` ✓
- `italic.fontName.contains("Italic")` ✓
- `italic.pointSize == size` ✓

Phase 2 `TerminalFontProviderTests.testItalicFontIdentityIsJetBrainsMono` 已验证。Phase 9B 扩到 18 / 24。✓

Italic 仍为 bundled JetBrainsMono-Italic。✓

---

## 52. BoldItalic identity

`TerminalFontResizeTests.testBoldItalicDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`：14 / 18 / 24 下：
- `bi.fontName.contains("JetBrainsMono")` ✓
- `bi.fontName.contains("Bold")` ✓
- `bi.fontName.contains("Italic")` ✓
- `bi.pointSize == size` ✓

Phase 2 `TerminalFontProviderTests.testBoldItalicFontIdentityIsJetBrainsMono` 已验证。Phase 9B 扩到 18 / 24。✓

BoldItalic 仍为 bundled JetBrainsMono-BoldItalic。✓

---

## 53. point-size parity

18pt 下（其他 size 同理）：
- Regular `pointSize == 18` ✓
- Bold `pointSize == 18` ✓（NSFontManager convert 保留输入 font 的 size）
- Italic `pointSize == 18` ✓
- BoldItalic `pointSize == 18` ✓

4 变体 pointSize 完全一致。✓

`NSFontManager.convert(_:toHaveTrait:)` 保留输入 font 的 size。✓

---

## 54. CJK fallback

`TerminalFontResizeTests.testCJKFallbackFollowsBaseFontSize`：14 / 18 / 24 下：
- 构造 attributed string "你好" + base font
- `CTLineCreateWithAttributedString` + `CTLineGetGlyphRuns`
- 遍历 runs，断言找到 `f.familyName.contains("PingFang") && f.pointSize == size`

✓ PingFang SC fallback pointSize 跟随 base。

机制：CoreText cascade，渲染主 font 不覆盖的 Unicode 时按 cascade list family 匹配，并按主 font 的 pointSize 解析 cascade font。不需额外处理 fallback size。✓

---

## 55. Emoji fallback

`TerminalFontResizeTests.testEmojiFallbackFollowsBaseFontSize`：14 / 18 / 24 下：
- 构造 attributed string "😀" + base font
- 同 CJK 流程
- 断言找到 `f.familyName.contains("Apple Color Emoji") && f.pointSize == size`

✓ Apple Color Emoji fallback pointSize 跟随 base。

---

## 56. Unicode

`TerminalFontResizeTests.testUnicodeRenderingDoesNotCrash`：14 / 18 / 24 下：
- `view.feed(text: "Hello 世界\n")`（ASCII + 中文）
- `view.feed(text: "Emoji: 😀🎉❤\n")`（Emoji）
- `view.feed(text: "VS16: ⚠\u{FE0F}\n")`（VS16）

无 crash。✓

---

## 57. VS16

`TerminalOptions.variationSelector16WidthPolicy` 在 `TerminalView.init(frame:font:options:)` 时设入 `Terminal`（`MacTerminalView.swift:354-360`）。font change → `resetFont` → `resize` → `terminal.resize` **不修改 `options`**。

Local: `.preserveBaseWidth`（`LocalTerminalService.swift:38`）。Remote: 默认 `.widenToEmojiWidth`（不显式设置）。

Phase 5 `TerminalVS16WidthPolicyTests` 实跑通过（在 485 executed 内）。✓

VS16 width policy 不变，⚠❤ 等 emoji cell width policy 保持。✓

---

## 58. Highlight

`TerminalHighlightCoordinator.broadcastRedrawToAllRegisteredViews`（`TerminalHighlightCoordinator.swift:87-94`）独立注册同一批 view，apply redraw signal（不 apply font）。

font change 的 `resetFont` 也设 `needsDisplay = true`（`AppleTerminalView.swift:313`）。highlight rule range 基于 `BufferLine` cell 位置——`terminal.resize` reflow 后 buffer 内容保留，highlight 在重绘时重新匹配，位置正确。

两个 Coordinator 独立注册同一批 view，font apply 与 highlight redraw 不冲突。✓

Phase 6 `TerminalHighlightCoordinatorTests` / `TerminalHighlightMatcherTests` / `TerminalHighlightStoreTests` 实跑通过（在 485 executed 内）。✓

---

## 59. Scrollback

`resetFont()`（`AppleTerminalView.swift:297-317`）：
- `resetCaches()` — 清空 color/attribute 缓存，**不清 buffer** ✓
- `computeFontDimensions()` — 重算 cellDimension
- `resize(cols:rows:)` → `terminal.resize(cols:rows:)` reflow buffer（**保留 scrollback**，只重新排列行列）✓
- `terminal.softReset()` 复位 DEC 模式，**不清 buffer** ✓

现有 scrollback 内容保留。font change 是 presentation-only + geometry reflow，不丢失 terminal text model。✓

---

## 60. Cursor

`resetFont()` → `updateCaretView()`（`AppleTerminalView.swift:310` / `:319-324`）：
```swift
caretView.frame.size = CGSize(width: cellDimension.width, height: cellDimension.height)
caretView.updateCursorStyle()
```

cursor frame 同步到新 cellDimension，不会停在旧字号 geometry。✓

---

## 61. Selection

`processSizeChange`（`AppleTerminalView.swift:394`）在 cols/rows 变化时 `selection.active = false`。

font setter 的 `selectNone()`（`MacTerminalView.swift:341`）**无条件清除选区**，无论 cols/rows 是否变化。

属合理行为（cell geometry 变化后选区位置无意义），不是缺陷。SwiftTerm 既有行为（sidebar resize 也走同路径）。**P3 可接受**。

---

## 62. Right Sidebar

sidebar open/close → `setFrameSize` → `processSizeChange` → `sizeChanged` → PTY resize。
font change → `resetFont` → `resize` → `sizeChanged` → PTY resize。

两者经同一 `sizeChanged` delegate，互不干扰：
- Sidebar open + 14→18：font change 触发 resize（基于当前 frame）；Sidebar 已 open，frame 不变；PTY 收到最终 cols/rows（更少，因 font 更大）。
- Sidebar close + font change：close 触发 setFrameSize（frame 变宽）→ recompute → PTY resize；font change 独立触发 resize。最终一致。

无组合 bug 风险。✓

`TerminalRightSidebarStateTests` 实跑通过（在 485 executed 内）。✓

---

## 63. Appearance

font preference 与 appearance preference 完全独立：
- 不同 controller（`TerminalFontSizeController` vs `AppAppearanceController`）
- 不同 Coordinator（拟新建 vs `TerminalAppearanceCoordinator`）
- 不同 UserDefaults key（`macssh.terminalFontSize` vs `macssh.appearanceMode`）

切 Light/Dark：`AppAppearanceController.apply()` → `NSApp.appearance` + `TerminalAppearanceCoordinator.applyCurrentAppearance()`（只 apply color palette）——**不触碰 font**。
切 font size：`TerminalFontSizeController.apply()` 只 `view.font =`——**不触碰 color**。
重启：appearance 从 `macssh.appearanceMode` load，font 从 `macssh.terminalFontSize` load，各自保持。
两个 Coordinator 的 `register` 在同一注册点调用，对同一批 view 各自 apply 正交属性。

✓ Phase 8 不受影响。

`AppAppearanceControllerTests` / `AppAppearanceModeTests` / `TerminalAppearanceTests` / `TerminalAppearanceManualModeTests` 实跑通过（在 485 executed 内）。✓

---

## 64. restart persistence

设置 18 → 重启：
- `AppState.init` → `TerminalFontSizeController.init` → `load(from:)` 读 `macssh.terminalFontSize = 18` → `controller.size = 18`
- Settings 显示 18（`Text("\(fontSizeController.size) pt")` 读 controller.size）
- 新建 Local → `register` → `view.font = regularFont(size: 18)` → 首帧 18
- 新建 Remote → `register` → `view.font = regularFont(size: 18)` → 首帧 18

`TerminalFontSizeControllerTests.testSetSizePersistsAndReloads` 验证 10/14/18/24/32 5 个 size 的 persist + reload 一致性。✓

---

## 65. Controller tests

`xcodebuild test -only-testing:MacSSHTests/TerminalFontSizeControllerTests` 实跑：
```
Test Suite 'TerminalFontSizeControllerTests' passed
    Executed 20 tests, with 0 failures (0 unexpected) in 0.043 (0.045) seconds
```

- 20 实际执行（**报告称 22 — P3-1 计数错误**）
- 0 skip ✓
- 0 failure ✓

测试质量审查：
- ✓ default 14（无偏好）：`testDefaultSizeIsFourteenWhenNoKey`
- ✓ persist/reload 10/14/18/24/32：`testSetSizePersistsAndReloads`
- ✓ invalid types → 14（Double / String / NaN / Infinity）；Bool → 1/0 → clamp 10：`testInvalidTypesFallBackToFourteen`
- ✓ 越界 clamp（9→10, 33→32, Int.min/max）：`testBelowMinClampsToTen` / `testAboveMaxClampsToThirtyTwo` / `testExtremeValuesClamp`
- ✓ setSize/increment/decrement 经 didSet 持久化：`testSetSizePersists` / `testIncrementPersists` / `testDecrementPersists`
- ✓ 边界 clamp：`testIncrementAtMaxClamps` / `testDecrementAtMinClamps` / `testSetSizeClampsBeforePersist`
- ✓ load 不污染其他 key：`testLoadDoesNotTouchOtherKeys`
- ✓ register 立即应用当前 size：`testRegisterAppliesCurrentSizeImmediately`
- ✓ size change 广播全部已注册 view：`testSizeChangeBroadcastsToAllRegisteredViews`
- ✓ 重复同 size 仍 apply 全部 view：`testRepeatingSameSizeStillAppliesToAllViews`
- ✓ new view after size change 立即得当前 size：`testNewlyRegisteredViewGetsCurrentSizeImmediately`
- ✓ 0 terminal：change size 仍 persist + apply no-op：`testZeroTerminalChangeSizePersistsAndApplyIsNoOp`
- ✓ 字体身份 size=18 JetBrains Mono + Bundle：`testRegisteredViewFontIdentityPreservedAtSize18`
- ✓ rapid click 14→15→16→17→18 同步顺序：`testRapidChangesProduceFinalState`

真实 broadcast 已覆盖（testSizeChangeBroadcastsToAllRegisteredViews 注册 3 view 验证全变 20）。非只测 helper。✓

**未覆盖**：weak registry view 释放后自动 nil（注释说明：TerminalView 自身 Timer/subviews/closures 可能造成 self 暂时强引用，单测无 window 难可靠触发 dealloc；与 Appearance/Highlight Coordinator 共用同一 weak 表实现，语义等价）。

---

## 66. Resize tests

`xcodebuild test -only-testing:MacSSHTests/TerminalFontResizeTests` 实跑（与 Controller 一起 52 tests）：
```
Test Suite 'MacSSHTests.xctest' passed
    Executed 52 tests, with 0 failures (0 unexpected) in 0.591 (0.599) seconds
```

52 = 20 Controller + 13 Resize + 19 Provider（Phase 2）。

Resize tests 13 实际执行，0 skip，0 failure ✓。

测试质量审查：
- ✓ cellDimension 随 size 线性 + 减小恢复：`testCellDimensionScalesWithFontSize`
- ✓ cols/rows 在 fixed frame 下随 size 增大而减少：`testColsRowsChangeWithFontSizeAtFixedFrame`
- ✓ font change triggers sizeChanged delegate：`testFontChangeTriggersSizeChangedDelegate`（用 base TerminalView + TerminalViewDelegate spy）
- ✓ sizeChanged 报告 newCols/newRows 反映新 font geometry：`testFontChangeSizeChangedColsRowsReflectNewFont`
- ✓ frame == 0 时 resetFont 跳过 resize，但 cellDimension 已更新：`testFontChangeAtZeroFrameDoesNotTriggerResize`
- ✓ LocalProcessTerminalView font change 不 crash + cell geometry 更新：`testLocalProcessTerminalViewFontChangeUpdatesCellDimension`（无 running process，未达 setWinSize）
- ✓ Regular identity 14/18/24 JetBrains Mono + Bundle：`testRegularIdentityAtMultipleSizes`
- ✓ Bold identity 14/18/24：`testBoldDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`
- ✓ Italic identity 14/18/24：`testItalicDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`
- ✓ BoldItalic identity 14/18/24：`testBoldItalicDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`
- ✓ CJK fallback（PingFang SC）pointSize 跟随 base 14/18/24：`testCJKFallbackFollowsBaseFontSize`
- ✓ Emoji fallback（Apple Color Emoji）pointSize 跟随 base 14/18/24：`testEmojiFallbackFollowsBaseFontSize`
- ✓ Unicode（ASCII / 中文 / Emoji / VS16）在 14/18/24 不 crash：`testUnicodeRenderingDoesNotCrash`

**重点判断**：
- Local PTY resize：**未真实覆盖** `setWinSize` 调用（testLocalProcessTerminalViewFontChangeUpdatesCellDimension 无 running process，guard process.running 短路）—— P2-1
- Remote PTY resize：**未真实覆盖** `resizeChannelPTY` 调用（testFontChangeTriggersSizeChangedDelegate 用 base TerminalView + TerminalViewDelegate spy，未达 RemoteTerminalService / SSHConnection）—— P2-1

测试名看似覆盖 PTY resize，但实际只到上游 seam（SwiftTerm 内部 sizeChanged delegate）。**P2**。

---

## 67. Provider-test coverage

Phase 9B 原计划（Phase 9A Acceptance §77）要求扩 `TerminalFontProviderTests` 到 size=18/24 验证 identity / traits / fallback。

**实际**：Phase 9B **未编辑** `Tests/SSH/TerminalFontProviderTests.swift`（baseline 19 tests 不变，仍只测 default 14）。

但 Phase 9B **新建** `TerminalFontResizeTests` 已覆盖：
- ✓ Regular identity 14/18/24：`testRegularIdentityAtMultipleSizes`
- ✓ Bold identity 14/18/24：`testBoldDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`
- ✓ Italic identity 14/18/24：`testItalicDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`
- ✓ BoldItalic identity 14/18/24：`testBoldItalicDerivedViaNSFontManagerPreservesIdentityAtMultipleSizes`
- ✓ CJK fallback（PingFang SC）14/18/24：`testCJKFallbackFollowsBaseFontSize`
- ✓ Emoji fallback（Apple Color Emoji）14/18/24：`testEmojiFallbackFollowsBaseFontSize`
- ✓ Unicode 不 crash 14/18/24：`testUnicodeRenderingDoesNotCrash`

Phase 2 `TerminalFontProviderTests`（19 tests）已验证 default 14 下：
- 4 face PostScript identity（JetBrainsMono-Regular/Bold/Italic/BoldItalic）
- Bundle 来源（`isFontSourcedFromBundle`）
- cascade list 含 PingFang SC + Apple Color Emoji
- Chinese / Emoji character resolves via cascade
- Local / Remote share unified font provider
- corrupted font fails registration

→ Phase 9A Acceptance §77 要求（14/18/24 下 4 face + CJK/Emoji fallback）**已由 TerminalFontResizeTests 覆盖**，**非 P2**。Phase 2 font identity 充分证明。✓

---

## 68. full MacSSH tests

fresh DerivedData `/tmp/MacSSH-P9B-ACC-DD`：
```
Test Suite 'All tests' passed
    Executed 485 tests, with 114 tests skipped and 0 failures (0 unexpected) in 96.405 (96.587) seconds
** TEST SUCCEEDED **
```

485 executed / 114 skipped / 0 failures ✓

---

## 69. executed

**485** ✓（报告称 485，一致）

---

## 70. skipped

**114** ✓（报告称 114，一致；主要为缺少 ed25519 测试私钥的 SSH/SFTP 集成测试 + live SSHD 测试）

---

## 71. failed

**0** ✓

---

## 72. Phase 2 regression

Bundled JetBrains Mono identity tests：
- `TerminalFontProviderTests`（19 tests，0 failure）✓
- 含 `testBundledJetBrainsMonoResourcesExist` / `testRegularFontIdentityIsJetBrainsMono` / `testBoldFontIdentityIsJetBrainsMono` / `testItalicFontIdentityIsJetBrainsMono` / `testBoldItalicFontIdentityIsJetBrainsMono` / `testCascadeContainsPingFangSC` / `testCascadeContainsAppleColorEmoji` / `testLocalAndRemoteShareUnifiedFontProvider` / `testFontSourceVerificationDistinguishesBundleAndSystem` 等

PASS ✓

---

## 73. Phase 3 regression

Local login shell：
- `LocalShellLauncherTests` PASS ✓（在 485 executed 内）

---

## 74. Phase 4 regression

Terminal Appearance：
- `TerminalAppearanceTests` PASS ✓
- 含 auto appearance 跟随系统逻辑

---

## 75. Phase 5 regression

VS16：
- `TerminalVS16WidthPolicyTests` PASS ✓
- 含 `.preserveBaseWidth` policy

---

## 76. Phase 6 regression

Highlight：
- `TerminalHighlightCoordinatorTests` PASS ✓
- `TerminalHighlightMatcherTests` PASS ✓
- `TerminalHighlightStoreTests` PASS ✓

---

## 77. Phase 7 regression

Right Sidebar / History / Saved Commands / Dispatcher：
- `TerminalCommandDispatcherTests` PASS ✓
- `SavedCommandStoreTests` PASS ✓
- `CommandHistoryStoreTests` PASS ✓
- `SavedCommandsSidebarContentTests` PASS ✓
- `TerminalRightSidebarStateTests` PASS ✓

---

## 78. Phase 8 regression

Manual Appearance：
- `TerminalAppearanceManualModeTests` PASS ✓
- `AppAppearanceControllerTests` PASS ✓
- `AppAppearanceModeTests` PASS ✓

---

## 79. Debug build

fresh DerivedData `/tmp/MacSSH-P9B-ACC-DD`：
```
** BUILD SUCCEEDED **
```

Debug / arm64 / clean build。✓

---

## 80. Release build

fresh DerivedData `/tmp/MacSSH-P9B-ACC-Rel`：
```
** BUILD SUCCEEDED **
```

Release / arm64 / clean build，`-skipPackagePluginValidation`。✓

---

## 81. production warnings

**0 MacSSH production warnings** ✓

Debug build grep `warning:|error:`（排除 SwiftTerm fork 路径）返回空。
Release build 同样 0 warning。

---

## 82. performance

font update 仅发生：
- 用户改字号（低频，< 1 Hz）
- new Terminal register（一次性）
- launch load（一次）

**不**每 frame / 每 keypress / Timer polling 重新创建 font。✓

无 Timer / polling / per-frame font recreation / per-keypress broadcast。✓

`regularFont(size:)` 内 `registerBundledFontsIfNeeded()` 幂等（`didAttemptRegistration` guard）。每次 size change 创建 4 NSFont（1 regular + 3 derived），单次开销 ms 级。`applyFontSizeToAllRegisteredViews` 遍历 live view（< 10），开销可忽略。✓

---

## 83. security

Phase 9B 未修改：
- Keychain / CredentialService ✓
- KnownHost / SSH auth / SFTP / libssh2 / OpenSSL ✓
- Entitlements / Hardened Runtime ✓
- SwiftTerm fork ✓

git diff 仅含 font preference 相关 7 modified + 3 untracked production/test/docs + 1 untracked preview 目录。安全基线不触碰。✓

---

## 84. git diff check

`git diff --check` → clean（无空白错误）✓

`git status --short`：
- 7 modified（pbxproj, AppLanguage, AppState, SettingsView, Localizable.xcstrings, SessionManager, gen_localizable.py）
- 5 untracked（3 docs + Controller + 2 tests）+ 1 untracked dir（generated-images/phase9b-preview/）

无 DerivedData / build / profraw（`default.profraw` 0 字节且 gitignored，不在 git status） / /tmp probe / screenshot / secret / 本地 SwiftTerm checkout 入 commit。✓

---

## 85. docs accuracy

`Docs/Phase9B-Final-Report.md` 与真实实现**主体一致**，但有以下偏差：

✓ 准确：
- register = 3 points（§4.4 / §11.2）
- cellWidth = "W" advancement（§6.1 措辞已修正 P3-1）
- settings.font_size_value 3-place cleanup（§11.2 + §6.2）
- Controller 架构（§2.1 / §4）
- UserDefaults 类型处理（§4.5）
- default/min/max/step（§4.5）
- weak registry（§4.3）
- AppState ownership（§4.4）
- 单一 source of truth（§4.1）

⚠ 偏差：
- **P3-1 测试计数**：报告 §6.1 / §12 称 "22 controller + 13 resize = 35 tests"，**实际 20 + 13 = 33**（-2）
- **P3-2 preview 描述**：报告 §1 / §11.2 称 "4 张预览图（方案 A 与方案 B × Light/Dark）"，**实际 4 文件全部 `A_` 前缀**，但人工复核内容确实包含 2 方案 × 2 模式，命名/描述不一致
- **P3-4 测试 docstring**：`TerminalFontResizeTests.swift:14-15` 类 docstring 称 "spy `TerminalViewDelegate` / `LocalProcessTerminalViewDelegate`"，实际只实现 `TerminalViewDelegate` spy
- **UI Preview Gate**：报告 §1 称 "用户选择方案 A"，工作记忆有相同记载，4 张 preview 图存在 — **Gate 实际完成**，无虚构

---

## 86. remaining P1

**无 P1。**

---

## 87. remaining P2

**1 项 P2**：

### P2-1. Local/Remote PTY resize 证据链不完整（详见 §3 / §45 / §46）

Phase 9A Acceptance §75 / §76 显式要求 PTY 级证据（"必须证明 font change → Local PTY `setWinSize` 被调用" / "必须证明 font change → `connection.resizeChannelPTY` 被请求"）。

实际 Phase 9B 测试仅验证上游 SwiftTerm `terminalDelegate.sizeChanged` seam（用 base `TerminalView` + `TerminalViewDelegate` spy），**未达** MacSSH 侧 `LocalProcessTerminalView.sizeChanged` → `setWinSize` / `RemoteTerminalService.sizeChanged` → `resizeChannelPTY`。

减轻情节：
1. 源码链完整（`LocalTerminalService.swift:42` + `RemoteTerminalService.swift:86` 用 `TerminalFontProvider.regularFont()`，`RemoteTerminalService.sizeChanged:446-468` 真实调用 `connection.resizeChannelPTY`，SwiftTerm `LocalProcessTerminalView.sizeChanged:104-112` 真实调用 `setWinSize` → `ioctl TIOCSWINSZ`）
2. 生产 baseline 已验证同一链（sidebar resize 经同一 `sizeChanged` delegate，Phase 4/7/8 production 工作正常）
3. 上游 seam 已验证（测试 spy 捕获 `TerminalViewDelegate.sizeChanged`）
4. 无实际 bug（源码复核无缺陷，全 MacSSH 测试 0 failure）

**非功能缺陷**，仅为证据缺口。归 P2。建议后续 remediation 补：
- `LocalProcessTerminalView` + running process + `processDelegate` spy 验证 `setWinSize` 触发
- `RemoteTerminalService` + mock `SSHConnection` spy 验证 `resizeChannelPTY(columns:rows:)` 调用

---

## 88. remaining P3

多项 P3（详见 §4）：

- **P3-1**：报告测试计数错误（22 vs 实际 20，差异 -2）
- **P3-2**：报告 preview 描述误导（"方案 A 与方案 B × Light/Dark" vs 实际 4 文件全 `A_` 前缀但内容含 2 方案）
- **P3-3**：SettingsView 字号按钮 accessibility 不完整（无 `.accessibilityLabel` / `.accessibilityHelp`，仅有 `.accessibilityIdentifier`）
- **P3-4**：`TerminalFontResizeTests.swift` 类 docstring 误导（声称 `LocalProcessTerminalViewDelegate` spy 实际未实现）
- **P3-5（沿用 Phase 9A Acceptance §71）**：
  - background tab font change 触发一次基于旧 frame 的 PTY resize（中间态，最终一致）
  - selection 清除（SwiftTerm `selectNone()` + `processSizeChange` 既有行为）
  - `terminal.softReset()` 副作用（resize 内调用，同 sidebar resize 路径）
  - 不支持 direct typing / ⌘+/⌘-/⌘0 快捷键 / 非整数字号（v1 设计选择）

---

## 89. 是否允许进入用户 GUI 验收

**允许进入用户 GUI 验收。**

理由：
- Git baseline / branch / HEAD / 工作树状态全部符合
- TerminalFontProvider.swift 未被修改，Controller 通过现有 API 设置字号
- 单一 source of truth 链完整
- Controller 架构合规（@MainActor @Observable，单一 size，weak registry，3 处 register）
- UserDefaults 类型处理安全（missing/非 Int/Double/NaN/Infinity/Bool 全覆盖）
- Debug + Release fresh DerivedData clean build：0 production warning
- 全 MacSSH 测试 485/114/0 → TEST SUCCEEDED
- Phase 2-8 regression 0 failure
- SwiftTerm pin `771e79f` 不变
- 字体 identity（Regular/Bold/Italic/BoldItalic）14/18/24 全 JetBrainsMono + Bundle
- CJK / Emoji fallback pointSize 跟随 base
- Unicode 不 crash
- UI Preview Gate 完成（4 张 preview 含 2 方案 × 2 模式）
- 安全 / 性能 / git hygiene 全部合规
- **1 项 P2**（PTY resize 证据缺口，源码链完整 + 生产 baseline 验证 + 无实际 bug，非功能缺陷）
- 多项 P3（docs 计数 / preview 命名 / accessibility / SwiftTerm 既有副作用）

P2 为证据缺口而非功能缺陷，源码链完整且生产 baseline 已验证同一链，不阻断用户 GUI 验收。用户 GUI 验收可进一步发现运行时问题（如有），现可进入。

---

## 90. final status

**PHASE 9B INDEPENDENT CODE ACCEPTANCE — CONDITIONAL PASS.**

- branch `feature/macssh-1.1-terminal-font-size` ✓
- baseline `c6bf66c2b985530e6687fefe62cdf08246190e41` ✓
- git diff summary：7 modified + 5 untracked（+ 1 untracked preview 目录），97 insertions / 21 deletions ✓
- unrelated changes：无 ✓
- UI preview gate：完成（4 张 preview 含 2 方案 × 2 模式，命名 `A_` 前缀但内容覆盖两方案）✓
- files added：3（Controller + 2 tests）✓
- files modified：7（pbxproj, AppLanguage, AppState, SettingsView, Localizable.xcstrings, SessionManager, gen_localizable.py）✓
- TerminalFontProvider.swift：**未被修改** ✓
- Controller architecture：@MainActor @Observable，单一 size Int，weak NSHashTable registry，3 处 register ✓
- MainActor：Controller + 全链路同步 ✓
- preference key：`macssh.terminalFontSize`（AppPreferenceKey）✓
- storage type：Int ✓
- default/min/max/step：14 / 10 / 32 / 1（集中定义，不分散）✓
- invalid persistence：`object(forKey:) as? Int` + clamp，全类型安全 ✓
- Bool handling：→ 1/0 → clamp 10 ✓
- fractional numeric handling：Double/NaN/Infinity → nil → 14 ✓
- normalization：clamp-on-load deterministic + size.didSet re-persist ✓
- single writer：仅 Controller 读写 `macssh.terminalFontSize` ✓
- Settings binding：`@Bindable var fontSizeController`，按钮调 controller.decrement/increment ✓
- boundaries：UI disabled + controller clamp 防御 ✓
- accessibility：仅 `.accessibilityIdentifier`，缺 `.accessibilityLabel` / `.accessibilityHelp`（P3-3）⚠
- font_size_value cleanup：3 处同步删除（SettingsView + xcstrings + gen_localizable.py）✓
- gen_localizable cleanup：`:266` 已删除 ✓
- LocalizationTests：21 tests, 0 failures, 含 testCatalogHasNoObsoleteKeys ✓
- FontProvider usage：`regularFont(size:)` 现有 API，不绕过 ✓
- source-of-truth chain：UserDefaults → Controller.size → Provider.regularFont(size:) → TerminalView.font ✓
- registry：`NSHashTable<TerminalView>.weakObjects()` ✓
- weak lifecycle：与 Appearance/Highlight 同模式 ✓
- registration points：3 处（SessionManager createLocal + runConnectFlow new Remote + AppState backfill）✓
- duplicate registration：NSHashTable.add 幂等 + view.font= 幂等 ✓
- AppState ownership：strong `let terminalFontSizeController`，SessionManager 之前创建 ✓
- no-active-session：0 terminal → apply no-op + persist ✓
- existing sessions：apply 广播全部 live view ✓
- new Local：register 立即应用当前 size，首帧即请求字号 ✓
- new Remote：同 Local ✓
- frame-zero：resetFont 跳过 resize，cellDimension 更新 ✓
- SwiftTerm SHA：`771e79f092a26e7fba7af0ab2b09a2bf10213109` ✓
- TerminalView.font API：public get/set ✓
- resetFont path：fontSet → resetFont → resetCaches → computeFontDimensions → resize → sizeChanged → softReset → updateCaretView → needsDisplay ✓
- cell-width algorithm："W" glyph advancement（P3-1 措辞已修正）✓
- geometry probe：14/16/18/24 cellW/cellH/cols/rows 合理 ✓
- Local PTY resize：源码链完整，测试仅到上游 seam（**P2-1 证据缺口**）⚠
- Remote PTY resize：源码链完整，测试仅到上游 seam（**P2-1 证据缺口**）⚠
- explicit resize absence：Controller 只设 view.font，不重复 resize ✓
- rapid changes：MainActor 同步，最终 controller=18/UserDefaults=18/view=18 ✓
- Regular identity：14/18/24 JetBrainsMono + Bundle ✓
- Bold identity：14/18/24 JetBrainsMono-Bold via NSFontManager ✓
- Italic identity：14/18/24 JetBrainsMono-Italic ✓
- BoldItalic identity：14/18/24 JetBrainsMono-BoldItalic ✓
- point-size parity：4 face pointSize 一致 ✓
- CJK fallback：PingFang SC pointSize 跟随 base ✓
- Emoji fallback：Apple Color Emoji pointSize 跟随 base ✓
- Unicode：ASCII/中文/Emoji/VS16 14/18/24 不 crash ✓
- VS16：TerminalOptions 不变 ✓
- Highlight：独立 Coordinator，不冲突 ✓
- Scrollback：resetCaches 不清 buffer，resize reflow 保留 ✓
- Cursor：updateCaretView 同步新 cellDimension ✓
- Selection：SwiftTerm 既有行为清除（P3-5 可接受）✓
- Right Sidebar：同一 sizeChanged 路径，互不干扰 ✓
- Appearance：完全独立 ✓
- restart persistence：load 持久化，新 Terminal 首帧即请求字号 ✓
- Controller tests：20 executed（报告称 22 — **P3-1**）/ 0 skip / 0 failure ⚠
- Resize tests：13 executed / 0 skip / 0 failure ✓
- Provider-test coverage：Phase 9A §77 要求已由 TerminalFontResizeTests 覆盖（非 P2）✓
- full MacSSH tests：485/114/0 ✓
- executed：485 ✓
- skipped：114 ✓
- failed：0 ✓
- Phase 2 regression：PASS ✓
- Phase 3 regression：PASS ✓
- Phase 4 regression：PASS ✓
- Phase 5 regression：PASS ✓
- Phase 6 regression：PASS ✓
- Phase 7 regression：PASS ✓
- Phase 8 regression：PASS ✓
- Debug build：SUCCEEDED, 0 warning ✓
- Release build：SUCCEEDED, 0 warning ✓
- production warnings：0 ✓
- performance：低频触发 + 幂等 register ✓
- security：不触碰安全基线 ✓
- git diff check：clean ✓
- docs accuracy：主体一致，3 项偏差（测试计数 / preview 描述 / test docstring）⚠
- remaining P1：无 ✓
- remaining P2：1 项（PTY resize 证据缺口）⚠
- remaining P3：多项（docs 计数 / preview 命名 / accessibility / SwiftTerm 既有副作用）⚠
- 是否允许进入用户 GUI 验收：**允许** ✓
- final status：**CONDITIONAL PASS — STOP，等用户 GUI 验收 + 最终授权 commit**

---

**STOP。Phase 9B Independent Code Acceptance 完成。**

**未修改 production code / SwiftTerm fork / commit / merge / push / 未开始下一 Phase。**

等待用户 GUI 验收 + 最终授权 commit。
