import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 拖动载荷只携带稳定业务 ID；普通文本无法解码为此结构，真正的数据与目标分组
/// 均由 Store 重新解析。使用系统 `data` 类型可避免额外注册仅限应用内部的自定义 UTI。
private struct SavedCommandDragPayload: Codable, Sendable, Transferable {
    let commandID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// 常用命令列表的局部布局参数。
private enum SavedCommandsSidebarLayout {
    /// 分组标题与命令行共用的水平内容留白。
    static let rowHorizontalPadding = AppTheme.Spacing.regular
    /// 分组标题与命令行共用的上下留白。
    static let rowVerticalPadding = AppTheme.Spacing.compact / 2
    /// 抹平 14 pt 粗体与 13 pt 等宽字体的行高差，确保单行背景总高度完全一致。
    static let singleLineMinimumContentHeight: CGFloat = 18
    /// 分组标题与命令行共用的悬停背景圆角。
    static let rowCornerRadius: CGFloat = 4
    /// 原生 DisclosureGroup 的标题从展开箭头之后开始；向左补齐 11.5 pt 后，
    /// 分组悬停背景与下方命令行背景共享同一左边界。
    static let groupHeaderLeadingExpansion: CGFloat = 11.5
    /// 原生 DisclosureGroup 的标题尾部保留 4 pt；向右补齐后，分组悬停背景
    /// 与下方命令行背景共享同一右边界。
    static let groupHeaderTrailingExpansion: CGFloat = 4
}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var isUngroupedExpanded = true
    @State private var isUngroupedHovering = false
    @State private var isUngroupedDropTargeted = false

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
        .sheet(item: $sheet) { item in
            sheetContent(for: item)
                // Sheet 显式使用应用语言，使动态标题、输入提示和校验文案与主界面一致。
                .environment(\.locale, appState.language.locale)
        }
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
            // 与主面板 Pane 选择器、历史记录标题使用同一个二级栏高度。
            .frame(height: AppTheme.Layout.terminalSecondaryBarHeight)
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
            // 只保留加号；隐藏系统下拉箭头，仍使用原生 Menu 交互。
            .menuIndicator(.hidden)
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
                    onAddCommand: { sheet = .addCommandInGroup($0) },
                    onMoveCommand: moveCommand
                )
            }
        )
    }

    private var ungroupedSection: AnyView {
        AnyView(
            DisclosureGroup(isExpanded: ungroupedExpansionBinding) {
                ForEach(ungrouped) { command in
                    SavedCommandRow(
                        command: command,
                        canDispatch: appState.commandDispatcher.canDispatch,
                        onEdit: { sheet = .editCommand(command) }
                    )
                }
            } label: {
                HStack {
                    Text("sidebar_right.ungrouped")
                        // 与真实分组标题保持相同的 14 pt 粗体层级。
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                }
                // 先补回标题内容缩进；外层负 padding 只扩展背景与命中区域，不移动文字。
                .padding(.leading, SavedCommandsSidebarLayout.groupHeaderLeadingExpansion)
                // 未分组标题整行都可展开/收起，也继续作为移出分组的拖放目标。
                .frame(minHeight: SavedCommandsSidebarLayout.singleLineMinimumContentHeight)
                .padding(.vertical, SavedCommandsSidebarLayout.rowVerticalPadding)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: SavedCommandsSidebarLayout.rowCornerRadius)
                        .fill(ungroupedHeaderBackground)
                )
                // 抵消 DisclosureGroup 的箭头缩进和尾部保留空间，使悬停矩形与命令行等宽。
                .padding(.leading, -SavedCommandsSidebarLayout.groupHeaderLeadingExpansion)
                .padding(.trailing, -SavedCommandsSidebarLayout.groupHeaderTrailingExpansion)
                // 悬停反馈与普通分组一致；拖放进入时由蓝色目标高亮覆盖。
                .animation(
                    reduceMotion
                        ? nil
                        : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
                    value: isUngroupedHovering
                )
                .onHover { isUngroupedHovering = $0 }
                .onTapGesture {
                    ungroupedExpansionBinding.wrappedValue.toggle()
                }
                .dropDestination(for: SavedCommandDragPayload.self) { payloads, _ in
                    guard let payload = payloads.first else {
                        return false
                    }
                    return moveCommand(payload.commandID, nil)
                } isTargeted: {
                    isUngroupedDropTargeted = $0
                }
                .accessibilityIdentifier("sidebar_right.ungroupedDropTarget")
            }
            .padding(.horizontal, SavedCommandsSidebarLayout.rowHorizontalPadding)
        )
    }

    /// 未分组标题的视觉状态：拖放目标优先，其次是普通鼠标悬停。
    private var ungroupedHeaderBackground: Color {
        if isUngroupedDropTargeted {
            return Color.accentColor.opacity(0.16)
        }
        return isUngroupedHovering ? Color.primary.opacity(0.04) : Color.clear
    }

    /// 未分组与普通分组共用相同的展开动画策略；Reduce Motion 开启时直接更新。
    private var ungroupedExpansionBinding: Binding<Bool> {
        Binding(
            get: { isUngroupedExpanded },
            set: { expanded in
                withAnimation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: AppTheme.SidebarMotion.groupDuration)
                ) {
                    isUngroupedExpanded = expanded
                }
            }
        )
    }

    /// 执行一次命令分组移动；Drop Destination 仅在持久化成功时接受拖放。
    private func moveCommand(_ commandID: UUID, _ groupID: UUID?) -> Bool {
        do {
            try appState.savedCommandStore.moveCommand(id: commandID, toGroupID: groupID)
            return true
        } catch {
            AppLogger.app.error("Saved command move between groups failed")
            return false
        }
    }

    // MARK: - Editor sheets (native Form)

    private var commandCreateSheet: some View {
        CommandEditorSheet(mode: .create, onSave: { title, text in
            do {
                _ = try appState.savedCommandStore.addCommand(title: title, command: text)
            } catch {
                AppLogger.app.error("Saved command add failed")
            }
        })
    }

    private func commandEditSheet(_ command: SavedCommand) -> some View {
        CommandEditorSheet(
            mode: .edit(title: command.title, command: command.command),
            onSave: { title, text in
            do {
                try appState.savedCommandStore.updateCommand(
                    id: command.id,
                    title: title,
                    command: text
                )
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
    /// 复用 `CommandEditorSheet(mode: .create)`；Sheet 编辑 title + command，不显示 Group Picker，
    /// 调用者已明确 target group。保存时直接绑定 target groupID（不先建 ungrouped 再 move）。
    private func commandCreateInGroupSheet(_ group: SavedCommandGroup) -> some View {
        CommandEditorSheet(mode: .create, onSave: { title, text in
            do {
                _ = try appState.savedCommandStore.addCommand(
                    title: title,
                    command: text,
                    groupID: group.id
                )
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
    /// 把命令拖入此分组；返回值表示目标是否接受本次拖放。
    let onMoveCommand: (UUID, UUID?) -> Bool
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    @State private var pendingDelete = false
    @State private var isHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            let sortedCommands = group.commands.sorted(by: { $0.sortOrder < $1.sortOrder })
            if sortedCommands.isEmpty {
                // 空分组仍可见，显示简洁「暂无命令」占位（GUI Acceptance FAIL #1）。
                Text("sidebar_right.group_empty")
                    .font(.system(size: 11))
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
                    // 分组标题在原生 callout（约 13 pt）基础上放大 1 pt，并使用粗体强化层级。
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
            // 先补回标题内容缩进；外层负 padding 只扩展背景与命中区域，不移动文字。
            .padding(.leading, SavedCommandsSidebarLayout.groupHeaderLeadingExpansion)
            // 让分组标题右侧空白区域同时参与左右键命中，整行都可切换或打开菜单。
            .frame(minHeight: SavedCommandsSidebarLayout.singleLineMinimumContentHeight)
            .padding(.vertical, SavedCommandsSidebarLayout.rowVerticalPadding)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: SavedCommandsSidebarLayout.rowCornerRadius)
                    .fill(headerBackground)
            )
            // 抵消 DisclosureGroup 的箭头缩进和尾部保留空间，使悬停矩形与命令行等宽。
            .padding(.leading, -SavedCommandsSidebarLayout.groupHeaderLeadingExpansion)
            .padding(.trailing, -SavedCommandsSidebarLayout.groupHeaderTrailingExpansion)
            // 标题整行悬停时显示浅灰背景；拖放进入时改用蓝色目标高亮。
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
                value: isHovering
            )
            .onHover { isHovering = $0 }
            .onTapGesture {
                expansionBinding.wrappedValue.toggle()
            }
            .contextMenu {
                groupContextMenu
            }
            .dropDestination(for: SavedCommandDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else {
                    return false
                }
                return onMoveCommand(payload.commandID, group.id)
            } isTargeted: {
                isDropTargeted = $0
            }
        }
        .padding(.horizontal, SavedCommandsSidebarLayout.rowHorizontalPadding)
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

    /// 普通分组标题的视觉状态：拖放目标优先，其次是鼠标悬停。
    private var headerBackground: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.16)
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
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

    /// 分组标题整行的右键操作；替代原先标题右侧的省略号菜单按钮。
    @ViewBuilder
    private var groupContextMenu: some View {
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
            // 不启用文本选择，避免系统“字体/格式”菜单覆盖命令项自身的右键菜单。
            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact / 2) {
                if let displayTitle {
                    Text(verbatim: displayTitle)
                        // 标题优先表达命令用途；不使用额外图标，保持窄侧栏简洁。
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(verbatim: command.command)
                        // 原始命令作为次级信息，使用较小等宽字体便于辨认路径和符号。
                        .font(Font(TerminalFontProvider.regularFont(size: 12)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    // 兼容迁移前的旧记录：没有标题时维持原来的单行命令展示。
                    Text(verbatim: command.command)
                        .font(Font(TerminalFontProvider.regularFont(size: 13)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            CommandRowActions(
                onPaste: { appState.commandDispatcher.paste(command: command.command) },
                onExecute: { appState.commandDispatcher.execute(command: command.command, source: .savedCommand) },
                enabled: canDispatch
            )
            .opacity(isHovering ? 1 : 0)
        }
        .frame(minHeight: SavedCommandsSidebarLayout.singleLineMinimumContentHeight)
        .padding(.horizontal, SavedCommandsSidebarLayout.rowHorizontalPadding)
        .padding(.vertical, SavedCommandsSidebarLayout.rowVerticalPadding)
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
        // 整行可拖动；载荷只包含命令 ID，目标分组由 Drop Destination 决定。
        .draggable(SavedCommandDragPayload(commandID: command.id))
        .accessibilityElement(children: .contain)
    }

    /// 防御旧数据或外部写入的空标题；空白标题回退到单行命令样式。
    private var displayTitle: String? {
        guard let title = command.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: SavedCommandsSidebarLayout.rowCornerRadius)
            .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
    }
}

// MARK: - Editor sheets (native Form)

/// 命令编辑器可选择的现有分组快照。
///
/// 仅传递编辑器展示与保存所需的稳定字段，避免 Sheet 直接持有 SwiftData 模型对象。
struct CommandEditorGroupOption: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// 常用命令的共用编辑器。History 右键「添加到常用命令」也复用此 Sheet，
/// 确保标题、命令校验与普通新增入口完全一致。
struct CommandEditorSheet: View {
    enum Mode {
        case create
        /// 从历史记录新增：仅预填命令，标题仍由用户填写。
        case createPrefilled(command: String)
        case edit(title: String?, command: String)
    }
    let mode: Mode
    private let groupOptions: [CommandEditorGroupOption]
    private let showsGroupPicker: Bool
    private let onSave: (String, String, UUID?) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var selectedGroupID: UUID?

    /// 普通新增、分组内新增和编辑命令沿用原界面，不显示分组选择器。
    init(mode: Mode, onSave: @escaping (String, String) -> Void) {
        self.mode = mode
        groupOptions = []
        showsGroupPicker = false
        self.onSave = { title, command, _ in onSave(title, command) }
        let initialValues = Self.initialValues(for: mode)
        _title = State(initialValue: initialValues.title)
        _text = State(initialValue: initialValues.command)
        _selectedGroupID = State(initialValue: nil)
    }

    /// 从历史记录添加时显示现有分组；`nil` 代表未分组，也是默认选择。
    init(
        mode: Mode,
        groupOptions: [CommandEditorGroupOption],
        selectedGroupID: UUID? = nil,
        onSave: @escaping (String, String, UUID?) -> Void
    ) {
        self.mode = mode
        self.groupOptions = groupOptions
        showsGroupPicker = true
        self.onSave = onSave
        let initialValues = Self.initialValues(for: mode)
        _title = State(initialValue: initialValues.title)
        _text = State(initialValue: initialValues.command)
        _selectedGroupID = State(initialValue: selectedGroupID)
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.regular) {
            Text(modeTitle)
                .font(.headline)
            TextField(
                L10n.string("sidebar_right.command_title_placeholder", defaultValue: "Title", locale: locale),
                text: $title
            )
                .textFieldStyle(.roundedBorder)
            TextField(L10n.string("sidebar_right.command_placeholder", defaultValue: "Command", locale: locale), text: $text)
                .textFieldStyle(.roundedBorder)
                // 命令编辑框与侧栏命令文本统一为 13 pt 终端字体（JetBrains Mono 级联）。
                .font(Font(TerminalFontProvider.regularFont(size: 13)))
            if showsGroupPicker {
                Picker(
                    L10n.string("sidebar_right.command_group", defaultValue: "Group", locale: locale),
                    selection: $selectedGroupID
                ) {
                    // SwiftData 中 `group == nil` 就是未分组，不创建虚拟分组模型。
                    Text(verbatim: L10n.string(
                        "sidebar_right.ungrouped",
                        defaultValue: "Ungrouped",
                        locale: locale
                    ))
                    .tag(nil as UUID?)

                    ForEach(groupOptions) { option in
                        Text(verbatim: option.name)
                            .tag(option.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sidebar_right.commandGroupPicker")
            }
            if let err = validationError {
                Text(verbatim: err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                // 与标题使用相同的显式 Locale，避免原生按钮保留系统语言文案。
                Button(role: .cancel) { dismiss() } label: {
                    Text(verbatim: L10n.string("action.cancel", defaultValue: "Cancel", locale: locale))
                }
                Button {
                    onSave(title, text, selectedGroupID)
                    dismiss()
                } label: {
                    Text(verbatim: L10n.string("common.save", defaultValue: "Save", locale: locale))
                }
                .disabled(validationError != nil)
            }
        }
        .padding(AppTheme.Spacing.spacious)
        .frame(width: 360)
    }

    /// 集中计算三种模式的初始值，确保两个初始化入口保持完全一致。
    private static func initialValues(for mode: Mode) -> (title: String, command: String) {
        switch mode {
        case .create:
            return ("", "")
        case .createPrefilled(let existingCommand):
            return ("", existingCommand)
        case .edit(let existingTitle, let existingCommand):
            return (existingTitle ?? "", existingCommand)
        }
    }

    private var modeTitle: String {
        switch mode {
        case .create, .createPrefilled:
            return L10n.string("sidebar_right.add_command", defaultValue: "New Command", locale: locale)
        case .edit:
            return L10n.string("sidebar_right.edit_command", defaultValue: "Edit Command", locale: locale)
        }
    }

    private var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.string("sidebar_right.command_title_empty", defaultValue: "Title cannot be empty.", locale: locale)
        }
        if CommandValidation.isRejected(title) {
            return L10n.string("sidebar_right.command_title_single_line", defaultValue: "Title must be a single line.", locale: locale)
        }
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
                // 分组创建与重命名共用此处，按钮文案始终跟随应用语言。
                Button(role: .cancel) { dismiss() } label: {
                    Text(verbatim: L10n.string("action.cancel", defaultValue: "Cancel", locale: locale))
                }
                Button {
                    onSave(name)
                    dismiss()
                } label: {
                    Text(verbatim: L10n.string("common.save", defaultValue: "Save", locale: locale))
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
