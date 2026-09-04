import SwiftData
import SwiftUI

/// MacSSH 1.1 Phase 7：常用命令侧边栏视图（分组 + hover Paste/Run + CRUD）。
///
/// 任务书 §50 / §55 / §56 / Phase 7A 验收：
/// - Group 用 DisclosureGroup（native macOS，可 keyboard 操作）；
/// - 未分组（group == nil）单独 section，不创建假「Ungrouped」SavedCommandGroup（§20 / §55）；
/// - 命令 row hover 显示 Paste / Run（§51 / §52）；
/// - 点击 row 本身不执行（§53）；
/// - 新增/编辑/删除用 native sheet/Form（§56）。
struct SavedCommandsSidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @Query(
        sort: [SortDescriptor(\SavedCommandGroup.sortOrder), SortDescriptor(\SavedCommandGroup.createdAt)]
    )
    private var groups: [SavedCommandGroup]

    @Query(
        sort: [SortDescriptor(\SavedCommand.sortOrder), SortDescriptor(\SavedCommand.createdAt)]
    )
    private var allCommands: [SavedCommand]

    /// 未分组命令（group == nil），从 allCommands 内存过滤，避免 #Predicate
    /// 可选关系比较（`$0.group == nil`）导致的类型检查超时。
    private var ungrouped: [SavedCommand] {
        allCommands.filter { $0.group == nil }
    }

    @State private var sheet: Sheet?

    init() {}

    private enum Sheet: Identifiable {
        case addCommand
        case addGroup
        case editCommand(SavedCommand)
        case renameGroup(SavedCommandGroup)
        /// 在指定分组内新增命令（GUI Acceptance Round 1 FAIL #2：分组内无法新增命令）。
        case addCommandInGroup(SavedCommandGroup)
        var id: String {
            switch self {
            case .addCommand: return "addCommand"
            case .addGroup: return "addGroup"
            case .editCommand(let c): return "edit-\(c.id.uuidString)"
            case .renameGroup(let g): return "rename-\(g.id.uuidString)"
            case .addCommandInGroup(let g): return "addInGroup-\(g.id.uuidString)"
            }
        }
    }

    var body: some View {
        AnyView(
            VStack(spacing: AppTheme.Spacing.none) {
                headerView
                Divider()
                listView
            }
        )
        .sheet(item: $sheet) { item in sheetContent(for: item) }
        .accessibilityIdentifier("sidebar_right.saved_commands_content")
    }

    private func sheetContent(for item: Sheet) -> AnyView {
        switch item {
        case .addCommand:
            return AnyView(commandCreateSheet)
        case .addGroup:
            return AnyView(groupCreateSheet)
        case .editCommand(let cmd):
            return AnyView(commandEditSheet(cmd))
        case .renameGroup(let group):
            return AnyView(groupRenameSheet(group))
        case .addCommandInGroup(let group):
            return AnyView(commandCreateInGroupSheet(group))
        }
    }

    // MARK: - Header

    private var headerView: AnyView {
        AnyView(
            HStack {
                Text("sidebar_right.saved_commands")
                    .font(.headline)
                Spacer()
                addButton
            }
            .padding(.horizontal, AppTheme.Spacing.regular)
            .padding(.vertical, AppTheme.Spacing.compact / 2)
        )
    }

    private var addButton: AnyView {
        AnyView(
            Menu {
                Button {
                    sheet = .addGroup
                } label: {
                    Label("sidebar_right.add_group", systemImage: "folder.badge.plus")
                }
                Button {
                    sheet = .addCommand
                } label: {
                    Label("sidebar_right.add_command", systemImage: "plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13))
            }
            .buttonStyle(AppInteractiveButtonStyle(
                baseStyle: BorderlessButtonStyle(),
                compactBackgroundDiameter: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
            ))
            .accessibilityLabel(L10n.string("sidebar_right.add", defaultValue: "Add", locale: locale))
            .accessibilityIdentifier("sidebar_right.addMenu")
        )
    }

    // MARK: - List

    private var listView: AnyView {
        AnyView(ScrollView { listContent })
    }

    private var listContent: AnyView {
        // Global empty state 判定（GUI Acceptance Round 1 FAIL #1 修复）：
        // 只有 groups 与 commands 均为空时才显示「暂无常用命令」。
        // 存在空 group（即使 0 command）必须显示该 group，不得被 global empty 隐藏。
        if SavedCommandsSidebarContent.shouldShowGlobalEmpty(groups: groups, commands: allCommands) {
            return AnyView(emptyState)
        }
        return AnyView(
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                groupList
                ungroupedSection
            }
            .padding(.vertical, AppTheme.Spacing.compact / 2)
        )
    }

    private var emptyState: AnyView {
        AnyView(
            ContentUnavailableView {
                Label("sidebar_right.saved_empty", systemImage: "command.square")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, AppTheme.Spacing.spacious)
        )
    }

    private var groupList: AnyView {
        AnyView(
            ForEach(groups) { group in
                GroupSection(
                    group: group,
                    canDispatch: appState.commandDispatcher.canDispatch,
                    onEditCommand: { sheet = .editCommand($0) },
                    onRenameGroup: { sheet = .renameGroup($0) },
                    onAddCommand: { sheet = .addCommandInGroup($0) }
                )
            }
        )
    }

    private var ungroupedSection: AnyView {
        AnyView(
            Group {
                if !ungrouped.isEmpty {
                    Text("sidebar_right.ungrouped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppTheme.Spacing.regular)
                        .padding(.vertical, AppTheme.Spacing.compact / 2)
                }
                ForEach(ungrouped) { command in
                    SavedCommandRow(
                        command: command,
                        canDispatch: appState.commandDispatcher.canDispatch,
                        onEdit: { sheet = .editCommand(command) }
                    )
                }
            }
        )
    }

    // MARK: - Editor sheets (native Form)

    private var commandCreateSheet: some View {
        CommandEditorSheet(mode: .create, onSave: { text in
            do {
                _ = try appState.savedCommandStore.addCommand(command: text)
            } catch {
                AppLogger.app.error("Saved command add failed")
            }
        })
    }

    private func commandEditSheet(_ command: SavedCommand) -> some View {
        CommandEditorSheet(mode: .edit(command.command), onSave: { text in
            do {
                try appState.savedCommandStore.updateCommand(id: command.id, command: text)
            } catch {
                AppLogger.app.error("Saved command update failed")
            }
            sheet = nil
        })
    }

    private var groupCreateSheet: some View {
        GroupEditorSheet(mode: .create, onSave: { name in
            do {
                _ = try appState.savedCommandStore.addGroup(name: name)
            } catch {
                AppLogger.app.error("Group add failed")
            }
        })
    }

    /// 分组重命名 sheet（任务书 §18 / 验收 §31：Rename 必须可测）。
    /// 复用现有 `GroupEditorSheet.Mode.edit` + `SavedCommandStore.renameGroup(id:name:)`，
    /// 真正 rename 原对象（不破坏 relationship），validation 复用 GroupEditorSheet 内的空/whitespace 校验。
    private func groupRenameSheet(_ group: SavedCommandGroup) -> some View {
        GroupEditorSheet(mode: .edit(group.name), onSave: { newName in
            do {
                try appState.savedCommandStore.renameGroup(id: group.id, name: newName)
            } catch {
                AppLogger.app.error("Group rename failed")
            }
            sheet = nil
        })
    }

    /// 分组内新增命令 sheet（GUI Acceptance Round 1 FAIL #2 修复）。
    /// 复用 `CommandEditorSheet(mode: .create)`；Sheet 只编辑 command text（第一版不显示 Group Picker，
    /// 调用者已明确 target group）。保存时直接绑定 target groupID（不先建 ungrouped 再 move）。
    private func commandCreateInGroupSheet(_ group: SavedCommandGroup) -> some View {
        CommandEditorSheet(mode: .create, onSave: { text in
            do {
                _ = try appState.savedCommandStore.addCommand(command: text, groupID: group.id)
            } catch {
                AppLogger.app.error("Saved command add to group failed")
            }
            sheet = nil
        })
    }
}

/// Saved Commands 页面 global empty-state 判定逻辑（GUI Acceptance Round 1 FAIL #1 修复）。
///
/// 纯函数、可测。Global empty 只有在 groups 与 commands 均为空时才为 true：
/// - 0 groups + 0 commands → global empty（显示 saved_empty）
/// - 1+ empty group + 0 commands → **非** global empty（必须显示空分组，不得隐藏）
/// - 1+ ungrouped command → 非 global empty
/// - 1+ grouped command → 非 global empty
enum SavedCommandsSidebarContent {
    /// Saved Commands 页面是否应显示 global empty state。
    static func shouldShowGlobalEmpty(groups: [SavedCommandGroup], commands: [SavedCommand]) -> Bool {
        groups.isEmpty && commands.isEmpty
    }
}

// MARK: - Group section (DisclosureGroup)

private struct GroupSection: View {
    let group: SavedCommandGroup
    let canDispatch: Bool
    /// 分组内命令 Edit 入口（修复 P2-3：原为空操作）。
    let onEditCommand: (SavedCommand) -> Void
    /// 分组 Rename 入口（修复 P2-2：原 UI 无调用路径）。
    let onRenameGroup: (SavedCommandGroup) -> Void
    /// 分组内新增命令入口（GUI Acceptance Round 1 FAIL #2：分组内无法新增命令）。
    let onAddCommand: (SavedCommandGroup) -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    @State private var pendingDelete = false

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            let sortedCommands = group.commands.sorted(by: { $0.sortOrder < $1.sortOrder })
            if sortedCommands.isEmpty {
                // 空分组仍可见，显示简洁「暂无命令」占位（GUI Acceptance FAIL #1）。
                Text("sidebar_right.group_empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppTheme.Spacing.regular)
                    .padding(.vertical, AppTheme.Spacing.compact / 2)
            } else {
                ForEach(sortedCommands) { command in
                    SavedCommandRow(
                        command: command,
                        canDispatch: canDispatch,
                        onEdit: { onEditCommand(command) }
                    )
                }
            }
        } label: {
            HStack {
                Text(verbatim: group.name)
                    .font(.callout.weight(.medium))
                Spacer()
                groupMenu
            }
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .alert(
            L10n.string("sidebar_right.delete_group_confirm", defaultValue: "Delete this group?", locale: appState.language.locale),
            isPresented: $pendingDelete
        ) {
            Button("action.cancel", role: .cancel) {}
            Button("sidebar_right.delete_group", role: .destructive) {
                do {
                    try appState.savedCommandStore.deleteGroup(id: group.id)
                } catch {
                    AppLogger.app.error("Group delete failed")
                }
            }
        } message: {
            Text(verbatim: L10n.format(
                "sidebar_right.delete_group_message",
                defaultValue: "Commands in this group will move to Ungrouped (%lld command(s)).",
                locale: appState.language.locale,
                arguments: Int64(group.commands.count)
            ))
        }
    }

    /// DisclosureGroup 与键盘操作共用同一 Binding，确保展开和收起都进入
    /// 显式动画 transaction；Reduce Motion 开启时直接更新状态。
    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { isExpanded },
            set: { expanded in
                withAnimation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: AppTheme.SidebarMotion.groupDuration)
                ) {
                    isExpanded = expanded
                }
            }
        )
    }

    private var groupMenu: some View {
        Menu {
            Button {
                onAddCommand(group)
            } label: {
                Label("sidebar_right.add_command", systemImage: "plus")
            }
            Divider()
            Button {
                onRenameGroup(group)
            } label: {
                Label("sidebar_right.rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = true
            } label: {
                Label("sidebar_right.delete_group", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(AppInteractiveButtonStyle(
            baseStyle: BorderlessButtonStyle(),
            compactBackgroundDiameter: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
        ))
        .accessibilityLabel(L10n.string("sidebar_right.group_actions", defaultValue: "Group actions", locale: appState.language.locale))
    }
}

// MARK: - Saved command row (hover Paste/Run)

private struct SavedCommandRow: View {
    let command: SavedCommand
    let canDispatch: Bool
    let onEdit: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.compact) {
            Text(verbatim: command.command)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            CommandRowActions(
                onPaste: { appState.commandDispatcher.paste(command: command.command) },
                onExecute: { appState.commandDispatcher.execute(command: command.command, source: .savedCommand) },
                enabled: canDispatch
            )
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .background(rowBackground)
        .contentShape(Rectangle())
        // 行底色与操作按钮淡入淡出，避免 hover 时瞬间闪现。
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
            value: isHovering
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("sidebar_right.edit") { onEdit() }
            Button(role: .destructive) {
                try? appState.savedCommandStore.deleteCommand(id: command.id)
            } label: {
                Label("sidebar_right.delete_command", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
    }
}

// MARK: - Editor sheets (native Form)

private struct CommandEditorSheet: View {
    enum Mode {
        case create
        case edit(String)
    }
    let mode: Mode
    let onSave: (String) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(mode: Mode, onSave: @escaping (String) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create: _text = State(initialValue: "")
        case .edit(let existing): _text = State(initialValue: existing)
        }
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.regular) {
            Text(modeTitle)
                .font(.headline)
            TextField(L10n.string("sidebar_right.command_placeholder", defaultValue: "Command", locale: locale), text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let err = validationError {
                Text(verbatim: err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("action.cancel", role: .cancel) { dismiss() }
                Button("common.save") {
                    onSave(text)
                    dismiss()
                }
                .disabled(validationError != nil)
            }
        }
        .padding(AppTheme.Spacing.spacious)
        .frame(width: 360)
    }

    private var modeTitle: String {
        switch mode {
        case .create:
            return L10n.string("sidebar_right.add_command", defaultValue: "New Command", locale: locale)
        case .edit:
            return L10n.string("sidebar_right.edit_command", defaultValue: "Edit Command", locale: locale)
        }
    }

    private var validationError: String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.string("sidebar_right.command_empty", defaultValue: "Command cannot be empty.", locale: locale)
        }
        if CommandValidation.isRejected(text) {
            return L10n.string("sidebar_right.command_single_line", defaultValue: "Command must be a single line.", locale: locale)
        }
        return nil
    }
}

private struct GroupEditorSheet: View {
    enum Mode {
        case create
        case edit(String)
    }
    let mode: Mode
    let onSave: (String) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(mode: Mode, onSave: @escaping (String) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create: _name = State(initialValue: "")
        case .edit(let existing): _name = State(initialValue: existing)
        }
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.regular) {
            Text(modeTitle).font(.headline)
            TextField(L10n.string("sidebar_right.group_name", defaultValue: "Group name", locale: locale), text: $name)
                .textFieldStyle(.roundedBorder)
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: L10n.string("sidebar_right.group_name_empty", defaultValue: "Group name cannot be empty.", locale: locale))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("action.cancel", role: .cancel) { dismiss() }
                Button("common.save") {
                    onSave(name)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.spacious)
        .frame(width: 320)
    }

    private var modeTitle: String {
        switch mode {
        case .create:
            return L10n.string("sidebar_right.add_group", defaultValue: "New Group", locale: locale)
        case .edit:
            return L10n.string("sidebar_right.rename_group", defaultValue: "Rename Group", locale: locale)
        }
    }
}
