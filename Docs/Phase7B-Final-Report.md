# MacSSH 1.1 Phase 7B — Terminal Right Sidebar / History & Saved Commands Final Report

Phase 7B 实现完成。未 commit MacSSH、未 merge、未 push MacSSH、未开始 Phase 8。等待 Independent Code Acceptance + 用户 GUI 验收。

---

## 1. branch
`feature/macssh-1.1-command-sidebar`

## 2. baseline
`9ab519ad39eba049805ce32f3ecfea75c7ca0bbe`（Phase 6 FINAL PASS）

## 3. files added (new)

**SwiftTerm fork（已 push 到 `canbyte0/SwiftTerm.git` 分支 `macssh-public-paste-api`）:**
- `Tests/SwiftTermTests/PasteTextTests.swift`（12 tests）

**MacSSH Models:**
- `MacSSH/Models/CommandGroup.swift`（SavedCommandGroup @Model）
- `MacSSH/Models/SavedCommand.swift`（@Model）
- `MacSSH/Models/CommandHistoryEntry.swift`（@Model）

**MacSSH Services:**
- `MacSSH/Services/Terminal/CommandValidation.swift`
- `MacSSH/Services/Terminal/SavedCommandStore.swift`
- `MacSSH/Services/Terminal/CommandHistoryStore.swift`
- `MacSSH/Services/Terminal/TerminalCommandDispatcher.swift`
- `MacSSH/Services/Terminal/CommandSidebarTab.swift`

**MacSSH Features:**
- `MacSSH/Features/Terminal/CommandRowActions.swift`
- `MacSSH/Features/Terminal/TerminalRightSidebarView.swift`
- `MacSSH/Features/Terminal/CommandHistorySidebarView.swift`
- `MacSSH/Features/Terminal/SavedCommandsSidebarView.swift`

**Tests:**
- `Tests/SSH/SwiftDataMigrationTests.swift`（on-disk 迁移，P2 gate）
- `Tests/SSH/TerminalCommandDispatcherTests.swift`
- `Tests/SSH/SavedCommandStoreTests.swift`
- `Tests/SSH/CommandHistoryStoreTests.swift`
- `Tests/SSH/TerminalRightSidebarStateTests.swift`

**Docs:**
- `Docs/Phase7A-CommandSidebar-Architecture-Investigation.md`
- `Docs/Phase7A-Acceptance-Review.md`
- `Docs/swiftterm-paste-patch.diff`

## 4. files modified
- `MacSSH.xcodeproj/project.pbxproj`（SwiftTerm revision + 新文件注册）
- `MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `MacSSH/App/MacSSHApp.swift`（Schema +3 model）
- `MacSSH/App/AppState.swift`（stores + dispatcher + sidebar state）
- `MacSSH/App/AppLanguage.swift`（AppPreferenceKey +2）
- `MacSSH/Components/Common/AppTheme.swift`（rightSidebarWidth）
- `MacSSH/Components/Toolbar/AppToolbarContent.swift`（sidebar toggle）
- `MacSSH/Features/Terminal/TerminalWorkspaceView.swift`（HStack + 右侧栏）
- `MacSSH/Features/Settings/SettingsView.swift`（history toggle + clear）
- `MacSSH/Resources/Localizable.xcstrings`（+33 keys）
- `Tests/SSH/DependencyIdentityTests.swift`（Phase 7 identity）
- `ThirdParty/MANIFEST.txt`（Phase 7 section）
- `Docs/SwiftTermFork.md`（Phase 7 section + production revision）

## 5. SwiftTerm Phase 7 SHA
`771e79f092a26e7fba7af0ab2b09a2bf10213109`

## 6. parent SHA
`6e56e32e16eba0c3a5f534136da272679085f44c`（Phase 6 Highlight）

## 7. fork diff
`Docs/swiftterm-paste-patch.diff`（+22 production LOC）

## 8. pasteText API
`public func pasteText(_ text: String)` — 复用 internal `insertText(_:replacementRange:isPaste:)`（isPaste:true）。通用、无 MacSSH 名称、不自动执行 Return、复用 SwiftTerm bracketed paste 语义 + IME marked-text 清理。

## 9. bracketed paste
由 SwiftTerm `pasteText` 单点处理（DECSET 2004：start/text/end，不双重包裹）。

## 10. IME
`insertText(_:isPaste:true)` 入口清 `markedTextStorage`；`PasteTextTests.clearsMarkedText` 验证 `hasMarkedText` true→false。

## 11. Return path
`EscapeSequences.cmdRet = [13]`（0x0D CR）。Execute = `pasteText(command)` + `send(data: cmdRet[...])`。

## 12. dispatcher
`TerminalCommandDispatcher`（@MainActor）：`paste(command:)` 不发 Return 不记 history；`execute(command:source:)` = pasteText + Return + append history + restore focus。每次实时读 `SessionManager.activeSession`，不缓存 stale target。

## 13. stale-target prevention
Dispatcher `resolveActive()` 闭包每次调用读 `sessionManager.activeSession` + 校验 `displayState == .active`。

## 14. Local
`LocalProcessTerminalView`（继承 TerminalView）的 `pasteText`/`send(data:)` → `LocalProcess.send` → DispatchIO → PTY。

## 15. Remote
`RemoteTerminalService.terminalView.pasteText`/`send` → `connection.writeChannelInput`（actor 串行）→ SSH Channel。

## 16. disconnected state
`displayState != .active` → `canDispatch == false` → UI 按钮 disabled + Dispatcher no-op。

## 17. focus
`focusWhenAvailable()` 在 paste/execute 末端调用，恢复 Terminal firstResponder。

## 18. CommandGroup
`SavedCommandGroup`（@Model，类名避免与 SwiftUI CommandGroup 碰撞）：id/name/sortOrder/createdAt/updatedAt + `@Relationship(deleteRule: .nullify)`。

## 19. SavedCommand
`SavedCommand`（@Model）：id/command/group(nullable)/sortOrder/createdAt/updatedAt。无 title/tag/host/variables。

## 20. validation
`CommandValidation.isRejected`：拒绝空/NUL/CR/LF/U+2028/U+2029；允许 TAB/ESC/BEL。Store+UI 双重校验。

## 21. group delete
`.nullify` deleteRule → commands 移到 ungrouped（不级联删除）。`SavedCommandStoreTests.testDeleteGroupNullifiesCommands` 验证。

## 22. ungrouped
`group == nil` = 未分组。UI 查询 `allCommands.filter { $0.group == nil }`（避免 `#Predicate` 可选关系比较超时）。

## 23. History model
`CommandHistoryEntry`（@Model）：id/command/executedAt/sessionID/sessionKind/hostDisplayName?/source。

## 24. History scope
全局显示，row 标注来源（Local/Host 名）。

## 25. History disclosure
保留「历史记录」名 + empty state 明确 disclosure（双语）：「仅记录通过 MacSSH 执行的命令」。

## 26. History append timing
预检 `displayState == .active` 通过 + `pasteText` + `sendReturn` 同步完成后 append。断开/预检失败不 append。

## 27. replay
History row Execute → `source: .historyReplay` → 再 append 新 entry。`TerminalCommandDispatcherTests.testHistoryReplayAppendsNewEntry` 验证。

## 28. History setting
Settings → Terminal →「保存命令历史」Toggle（默认 On）+「清空历史」destructive confirmation。

## 29. retention
全局上限 1000 条，超限按 `executedAt` 最旧优先 prune。`CommandHistoryStoreTests.testRetentionPrunesOldest` 验证。

## 30. clear history
`CommandHistoryStore.clear()` 只删 `CommandHistoryEntry`，不删 SavedCommand/Groups/Hosts。`testClearOnlyDeletesHistory` 验证。

## 31. privacy
日志不记录 command 内容，只记 count/id/source。`AppLogger.app.error("... (persistence)")`。

## 32. SwiftData integration
`MacSSHApp` Schema 加入 `SavedCommandGroup/SavedCommand/CommandHistoryEntry`。无其他 container creation path。

## 33. on-disk migration
`SwiftDataMigrationTests`（P2 gate）：Phase 6 schema on-disk store → Phase 7 schema，验证 Host/HostGroup/KnownHost 全部保留 + 新 model 可插入。非 in-memory。

## 34. sidebar hierarchy
`TerminalRightSidebarView`：固定顶部 icon tab + ScrollView 内容区。

## 35. icons
History: `clock.arrow.circlepath`；Saved Commands: `command.square`。

## 36. hover
Command row hover 显示 Paste/Run（`opacity` 控制，不 `accessibilityHidden`，keyboard/VoiceOver 可达）。

## 37. Paste action
`dispatcher.paste(command:)` → `pasteText(command)`，不附 Return，不记 history。

## 38. Run action
`dispatcher.execute(command:source:)` → `pasteText(command)` + `send(data: cmdRet)` + append history + restore focus。

## 39. accessibility
icon tab: `accessibilityLabel` + `help` + `.isSelected` trait。Paste/Run: `accessibilityLabel`。Group: `DisclosureGroup` keyboard 可操作。

## 40. Light/Dark
全 semantic colors（`Color(nsColor:)`/`.secondary`/`.accentColor`），不硬编码 white/black。

## 41. localization
+33 xcstrings keys（en + zh-Hans）。含 history disclosure、Paste/Run、group/command CRUD、clear history、sidebar toggle。

## 42. UserDefaults sidebar state
`isRightSidebarVisible`（默认 false）+ `selectedRightSidebarTab`（默认 .history）存 UserDefaults。不存 runtime session。

## 43. Local resize
右侧栏展开 → HStack 缩窄 Terminal → SwiftTerm `setFrameSize` → `processSizeChange` → `LocalProcessTerminalView.sizeChanged` → `PseudoTerminalHelpers.setWinSize`。

## 44. Remote resize
→ `RemoteTerminalService.sizeChanged` → `connection.resizeChannelPTY`（actor）→ `libssh2_channel_request_pty_size_ex`。

## 45. multi-tab
切 Tab 只改 `activeSessionID`；右侧栏保持；Saved Commands 全局共享；History 全局；Dispatcher 实时读 active。

## 46. UTF-8
`send(txt:)` 用 `txt.utf8` 原样。`testUTF8Preserved` 验证 `echo '中文 😀'`。

## 47. quotes
`testQuotesPreserved` 验证 `printf '%s\n' "$HOME test"` byte-for-byte。

## 48. SwiftTerm tests
753 tests / 64 suites 全过（含 12 PasteTextTests + Phase 5 VS16 + Phase 6 Highlight 回归）。

## 49. Phase 5 regression
`VariationSelector16WidthPolicyTests`：`vs16PreservePolicyColumnPainting` + `vs16WidenPolicyColumnPainting` 通过。

## 50. Phase 6 regression
`Suite TerminalHighlightProviderTests` 全过。

## 51. dispatcher tests
`TerminalCommandDispatcherTests`：12 tests 全过（paste/execute/Return/history/replay/UTF-8/quotes/no-target/rapid-ordering/focus）。

## 52. store tests
`SavedCommandStoreTests`：16 tests 全过（group/command CRUD + validation + delete nullify + whitespace）。

## 53. history tests
`CommandHistoryStoreTests`：10 tests 全过（enabled/disabled/append/replay/scope/retention/clear/privacy）。

## 54. migration tests
`SwiftDataMigrationTests`：2 tests 全过（on-disk Phase6→Phase7 + empty store）。P2 gate PASS。

## 55. sidebar state tests
`TerminalRightSidebarStateTests`：6 tests 全过（tab rawValue/image/roundtrip + preference keys + maxEntries）。

## 56. MacSSH tests

> **诚信修正（Independent Acceptance 复核）**：本节原写「405 tests 全过，0 failures」**不实**。
> Independent Acceptance 首次 fresh DerivedData 运行真实结果：
> **405 executed / 114 skipped / 1 failure** → `** TEST FAILED **`。
> 唯一失败：`MacSSHTests.LocalizationTests.testCatalogHasNoObsoleteKeys`
> （String Catalog 含 3 个源码未使用 key：`sidebar_right.group_actions` /
> `sidebar_right.rename` / `sidebar_right.saved_empty`）。
> 根因对应 3 个未接通功能：Group Rename UI 无调用路径、分组内 Command Edit 空操作、
> Saved Commands 无 empty state。详见 §67 Remediation。

修复后 fresh DerivedData 重测结果（见 §67）：
**412 executed / 114 skipped / 0 failures** → `** TEST SUCCEEDED **`。
新增 7 测试（SavedCommandStoreTests +2、SavedCommandsSidebarContentTests +5），
总 405 → 412。Phase 7 全部新测试 0 skip。

## 57. Debug build
`xcodebuild -configuration Debug -skipPackagePluginValidation`：**BUILD SUCCEEDED**，0 MacSSH-side warnings。

## 58. Release build
`xcodebuild -configuration Release -skipPackagePluginValidation`：**BUILD SUCCEEDED**。

## 59. warnings
0 MacSSH production-side warnings（Debug app target + Release app target）。Test target（MacSSHTests）
存在 32 个既有 harness warning（`@MainActor` 隔离的 setUpWithError 访问 @MainActor store/container 等，
Phase 7 之前既有模式，非本次引入；remediation 新增 1 个 `try` on non-throwing 已修复）。
SwiftTerm 上游 MetalTerminalRenderer `withUnsafeBytes` warning 既有（非 Phase 7 引入）。

## 60. security baseline
- 无 keyboard recording / password capture / command logging / telemetry。
- 不修改 KnownHost / Keychain / CredentialService / SSH auth / libssh2 / OpenSSL / Entitlements / Hardened Runtime。
- History 只记 MacSSH Execute，禁止 keyboard interception（P1 边界）。

## 61. runtime dependencies
SwiftTerm `771e79f`（remote SwiftPM，exact immutable SHA）+ libssh2 `be93774` + OpenSSL `3.5.8`（不变）。

## 62. performance smoke
SwiftData `@Query` 惰性 fetch，不每 keypress 触发。History retention 1000 条。Dispatcher 同步 send 主线程微秒级。

## 63. git diff check
`git diff --check`：无 whitespace 问题。`.vscode/` untracked（IDE 产物，非 Phase 7）。

## 64. known limitations
- History 不捕获手输/REPL/tmux 命令（disclosure 已说明）。
- 不做搜索/拖拽排序/host-specific commands/参数模板。
- 不做 shell integration / OSC 133 自动 history（future）。
- 右侧栏固定 300pt 不可拖动。
- Saved Command 仅单行。
- 不判断危险命令。

## 65. manual acceptance items
- Sidebar 展开/收起 + PTY resize
- History/Saved Commands icon tab + selected/hover/tooltip
- 新增/rename/delete group（nullify）
- 新增/edit/delete command
- hover Paste/Run
- Local/Remote Paste/Execute
- 切 Tab target 切换
- Paste 不执行 / Execute 执行一次
- 中文/Emoji command
- Light/Dark
- Settings history toggle + clear

## 66. final status

> **诚信修正**：原「实现完成」表述遮蔽了首次 Independent Acceptance 的 1 failure。真实状态如下。

Phase 7B 实现 + Remediation 完成（含首次验收发现 P2 修复）。Debug + Release 构建
0 error、0 MacSSH production warning。SwiftTerm 753 tests 全过；MacSSH fresh
DerivedData 全套 **412 executed / 114 skipped / 0 failures**（含 on-disk 迁移 P2 gate、
含 Localization `testCatalogHasNoObsoleteKeys` 修复后通过）。未 commit MacSSH /
未 merge / 未 push MacSSH / 未开始 Phase 8。

等待第二次 Independent Code Acceptance + 用户 GUI 验收。

## 67. Remediation（Independent Acceptance P2 修复）

Independent Code Acceptance 首次运行发现 3 个 P2 + 若干 P3，本轮全部修复：

### P2-1 Localization obsolete keys
首次 `testCatalogHasNoObsoleteKeys` 失败，3 个 key 未使用。
**修复方式**：不为通过测试而删 key，而是为每个 key 接通真实 UI 使用点：
- `sidebar_right.group_actions` → `GroupSection.groupMenu` 的 accessibilityLabel
- `sidebar_right.rename` → `groupMenu` Rename 按钮 Label
- `sidebar_right.rename_group` → `GroupEditorSheet.Mode.edit` 标题（原有）
- `sidebar_right.saved_empty` → SavedCommands empty state `ContentUnavailableView`
修复后 0 obsolete key，`testCatalogHasNoObsoleteKeys` PASS。

### P2-2 Group Rename UI
原 `SavedCommandStore.renameGroup` + `GroupEditorSheet.Mode.edit` 存在但无 UI 调用点。
**修复**：`GroupSection.groupMenu` 增加 Rename 项 → `onRenameGroup` → 父 `Sheet.renameGroup`
→ `groupRenameSheet` 复用 `GroupEditorSheet.Mode.edit(group.name)` → 保存调
`SavedCommandStore.renameGroup(id:name:)`。真正 rename 原对象，不破坏 relationship
（`testRenameGroupPreservesCommandsRelationship` 验证同 id + commands 关系不变）。
validation 复用 GroupEditorSheet 的空/whitespace 校验。

### P2-3 分组内 Command Edit 空操作
原 `GroupSection` 中 `SavedCommandRow(... onEdit: { })`。**修复**：`onEdit: { onEditCommand(command) }`
→ 父 `Sheet.editCommand` → `commandEditSheet` → `SavedCommandStore.updateCommand`。
分组内命令 Edit 行为与未分组一致；编辑不改 group（`testUpdateGroupedCommandPreservesGroup`
验证 group id 保持、不移到未分组）。未扩展 Move Group / 拖拽（保持 v1 scope）。

### P3 顺便修正
- **History disclosure**：原仅 empty state 显示。修复为 History 页顶部常显
  `disclosureBanner`（`sidebar_right.history_disclosure`，caption2/secondary），
  无论是否为空；empty state 简化为仅 icon+label（避免与顶部重复）。
- **SwiftTermFork.md**：修复重复的 `## 7` 章节编号（`## 7. 测试覆盖` → `## 8. 测试覆盖`），
  不改 dependency 内容。
- **Toolbar icon / AnyView**：按指示本轮不改（保持现状，无功能/identity bug）。

### Remediation 新增测试
- `SavedCommandStoreTests.testRenameGroupPreservesCommandsRelationship`（同 id + relationship 不变）
- `SavedCommandStoreTests.testUpdateGroupedCommandPreservesGroup`（编辑分组命令不改 group）
- `SavedCommandsSidebarContentTests`（5 tests：0/empty-group/1-ungrouped/1-grouped/multi 的 empty 判定）

### Remediation fresh rerun（fresh DerivedData `/tmp/macssh-7b-remed-test`）
- MacSSH 全套：**412 executed / 114 skipped / 0 failures** → `** TEST SUCCEEDED **`
- Phase 7 类全 0 failure 0 skip：TerminalCommandDispatcherTests(12) /
  SavedCommandStoreTests(19) / CommandHistoryStoreTests(10) /
  TerminalRightSidebarStateTests(6) / SwiftDataMigrationTests(2, on-disk) /
  SavedCommandsSidebarContentTests(5) / DependencyIdentityTests(10) /
  LocalizationTests(21, 含 `testCatalogHasNoObsoleteKeys` + `testCatalogKeysAllHaveCompleteTranslations`)
- Debug build（test 运行）：BUILD SUCCEEDED，0 MacSSH production warning。
- Release clean build（fresh `/tmp/macssh-7b-remed-release`）：BUILD SUCCEEDED，0 MacSSH production warning。
- `otool -L`：仅系统框架 + Swift runtime dylib；无 homebrew/动态 libssh2/ssl/crypto。
- SwiftTerm production SHA `771e79f092a26e7fba7af0ab2b09a2bf10213109` 未变（remediation 未改 SwiftTerm）。
- 安全基线：无新增 keyboard capture / `Terminal.feed` / command 日志 / SSH auth / Keychain 改动。
- `git diff --check` OK；无 DerivedData/profraw/临时 DB/secret 混入。

## 68. GUI Acceptance Round 1（用户 GUI 验收，FAIL → Remediation 2）

> **诚信记录**：第二次 Independent Code Re-Acceptance PASS 后进入用户 GUI 验收，
> 首轮 GUI 验收 **2 项 FAIL**，必须保留失败历史，不得改写为「一次通过」。

### Round 1 FAIL
- **FAIL #1**：新增分组后分组不立即显示；只有新增第一条命令后分组才出现。
  - 根因：`SavedCommandsSidebarContent.shouldShowEmpty(allCommands:)` 只按 command 数量判定，
    当 `allCommands.isEmpty`（即使存在空 group）就显示 global empty `saved_empty`，
    把刚创建的空 group 整个隐藏。
- **FAIL #2**：分组内无法新增命令。
  - 根因：`GroupSection.groupMenu` 仅有 Rename + Delete，无 Add Command 入口；
    `CommandEditorSheet` 无 target group 绑定路径。

### Remediation 2 修复
- **FAIL #1**：`SavedCommandsSidebarContent` 改为 `shouldShowGlobalEmpty(groups:, commands:)`，
  只有 `groups.isEmpty && commands.isEmpty` 才显示 global empty。存在空 group（即使 0 command）
  必须显示该 group。`GroupSection` 空分组时 DisclosureGroup 内显示 `sidebar_right.group_empty`
  （zh「暂无命令」/ en「No commands」）占位。新增 localizable key。
- **FAIL #2**：`Sheet` 枚举加 `addCommandInGroup(SavedCommandGroup)`；`GroupSection.groupMenu`
  增加 Add Command（复用 `sidebar_right.add_command`）→ `onAddCommand(group)` → 父
  `commandCreateInGroupSheet(group)` → 复用 `CommandEditorSheet(mode: .create)` → Save 直接
  `SavedCommandStore.addCommand(command: text, groupID: group.id)`（不先建 ungrouped 再 move）。
  groupMenu 最终顺序：Add Command / 分隔 / Rename / Delete。

### Remediation 2 新增/更新测试
- `SavedCommandsSidebarContentTests` 重写为 6 tests（A–E + immediate visibility）：
  A 0+0→empty、B 1 empty group+0→非 empty、C 0+1 ungrouped→非 empty、D 1+1 grouped→非 empty、
  E multiple empty groups+0→非 empty、+ `testImmediateGroupVisibilityWhenNoCommands`。
- `SavedCommandStoreTests.testAddCommandToGroupBindsTargetGroup`：
  分组内新增命令直接绑定 target group（`cmd.group?.id == group.id`、`commands(inGroup:).count == 1`、
  `ungroupedCommands().count == 0`）。

### Remediation 2 fresh rerun（fresh DerivedData `/tmp/macssh-7b-remed2-test`）
- MacSSH 全套：**414 executed / 114 skipped / 0 failures** → `** TEST SUCCEEDED **`
  （412 → 414，+2 新测试：SavedCommandStoreTests +1、SavedCommandsSidebarContentTests +1）。
- Phase 7 类全 0 failure 0 skip：Dispatcher(12) / SavedCommandStore(20) / HistoryStore(10) /
  SidebarState(6) / Migration(2, 真实 on-disk P2 gate) / SidebarContent(6) / DependencyIdentity(10) /
  Localization(21，含 `testCatalogHasNoObsoleteKeys` + `testCatalogKeysAllHaveCompleteTranslations`，
  `group_empty` key en+zh 完整且 production 使用)。
- Debug build（test 运行）：BUILD SUCCEEDED，0 MacSSH production warning（32 warning 全在 Tests/ 既有 harness）。
- Release clean build（fresh `/tmp/macssh-7b-remed2-release`）：BUILD SUCCEEDED，0 production warning。
- `otool -L`：仅系统框架 + Swift runtime dylib；无 homebrew/动态 libssh2/ssl/crypto。
- SwiftTerm production SHA `771e79f092a26e7fba7af0ab2b09a2bf10213109` 未变（remediation 2 未改 SwiftTerm）。
- 安全基线：未触碰 dispatcher/pasteText/history/keychain/SSH；无 keyboard capture / `Terminal.feed`。
- `git diff --check` OK；无 DerivedData/profraw/临时 DB/secret。`.vscode/` 仍未跟踪（不入 commit）。

等待用户 GUI Re-Acceptance。
