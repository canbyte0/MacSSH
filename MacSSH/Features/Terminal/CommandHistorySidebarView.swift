import SwiftData
import SwiftUI

/// MacSSH 1.1 Phase 7：历史记录侧边栏视图。
///
/// History 记录 MacSSH Execute 与本地 zsh Shell Integration 确认开始执行的命令。
/// 页面顶部常显安全边界：不拦截密码提示、REPL 或 tmux 原始输入。
/// History row 支持 Paste / Run，右键可添加到常用命令或只删除当前记录。
struct CommandHistorySidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @Query(
        sort: [SortDescriptor(\CommandHistoryEntry.executedAt, order: .reverse)]
    )
    private var entries: [CommandHistoryEntry]

    @Query(
        sort: [SortDescriptor(\SavedCommandGroup.sortOrder), SortDescriptor(\SavedCommandGroup.createdAt)]
    )
    private var savedCommandGroups: [SavedCommandGroup]

    @State private var pendingClear = false
    @State private var savedCommandDraft: SavedCommandDraft?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            historyHeader

            Divider()

            // 顶部固定 disclosure（任务书 §24 / Phase 7A 验收 §38 / 修复 P3）：
            // 无论 History 是否为空都常显，避免有记录后用户误以为「完整 shell history」。
            disclosureBanner

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                        ForEach(entries) { entry in
                            HistoryRow(
                                entry: entry,
                                canDispatch: appState.commandDispatcher.canDispatch,
                                onAddToSavedCommands: {
                                    savedCommandDraft = SavedCommandDraft(command: entry.command)
                                },
                                onDelete: {
                                    appState.commandHistoryStore.delete(id: entry.id)
                                }
                            )
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.compact / 2)
                }
            }
        }
        .sheet(item: $savedCommandDraft) { draft in
            // 复用常用命令的原生编辑器：命令预填，标题由用户补充，
            // 默认保存到「未分组」，也可选择现有分组；不隐式创建新分组。
            CommandEditorSheet(
                mode: .createPrefilled(command: draft.command),
                groupOptions: savedCommandGroups.map {
                    CommandEditorGroupOption(id: $0.id, name: $0.name)
                }
            ) { title, command, groupID in
                do {
                    _ = try appState.savedCommandStore.addCommand(
                        title: title,
                        command: command,
                        groupID: groupID
                    )
                } catch {
                    AppLogger.app.error("History command add to saved commands failed")
                }
            }
            .environment(\.locale, appState.language.locale)
        }
        .accessibilityIdentifier("sidebar_right.history_content")
    }

    // MARK: - Header

    private var historyHeader: some View {
        HStack {
            Text("sidebar_right.history")
                .font(.headline)
            Spacer()
            if !entries.isEmpty {
                Button(role: .destructive) {
                    pendingClear = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(AppInteractiveButtonStyle(
                    baseStyle: BorderlessButtonStyle(),
                    compactBackgroundDiameter: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
                ))
                .help(L10n.string("sidebar_right.clear_history", defaultValue: "Clear History", locale: locale))
                .accessibilityLabel(L10n.string("sidebar_right.clear_history", defaultValue: "Clear History", locale: locale))
                .accessibilityIdentifier("sidebar_right.clearHistory")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        // 普通图标按钮的原生高度小于 Menu；固定为与主面板 Pane 选择器相同的高度，
        // 避免历史记录标题下方的 Divider 上移。
        .frame(height: AppTheme.Layout.terminalSecondaryBarHeight)
        .alert(
            L10n.string("sidebar_right.clear_history_confirm", defaultValue: "Clear all command history?", locale: locale),
            isPresented: $pendingClear
        ) {
            Button("action.cancel", role: .cancel) {}
            Button("sidebar_right.clear_history", role: .destructive) {
                appState.commandHistoryStore.clear()
            }
        } message: {
            Text(verbatim: L10n.string(
                "sidebar_right.clear_history_message",
                defaultValue: "This only removes command history. Saved commands and groups are not affected.",
                locale: locale
            ))
        }
    }

    // MARK: - Fixed disclosure banner (always visible)

    /// 顶部常显的简短 disclosure（修复 P3：原仅在 empty state 显示）。
    /// 复用双语文案，使用 11 pt 系统常规字体提高辅助文字可读性。
    private var disclosureBanner: some View {
        Text(verbatim: L10n.string(
            "sidebar_right.history_disclosure",
            defaultValue: "Records commands run through MacSSH and commands executed in local zsh.\nPasswords and input inside REPL or tmux are not recorded.",
            locale: locale
        ))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .accessibilityIdentifier("sidebar_right.history_disclosure")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // 顶部 disclosure 已常显，empty state 仅显示 icon + label，避免文案重复。
        ContentUnavailableView {
            Label("sidebar_right.history_empty", systemImage: "clock.arrow.circlepath")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 用于驱动「历史命令 → 常用命令」Sheet 的短生命周期数据。
private struct SavedCommandDraft: Identifiable {
    let id = UUID()
    let command: String
}

// MARK: - History row

private struct HistoryRow: View {
    let entry: CommandHistoryEntry
    let canDispatch: Bool
    let onAddToSavedCommands: () -> Void
    let onDelete: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.compact) {
            VStack(alignment: .leading, spacing: 2) {
                // 不启用文本选择，避免右键时显示系统“字体/格式”等文本编辑菜单。
                Text(verbatim: entry.command)
                    // 历史与常用命令统一使用 13 pt 终端字体（JetBrains Mono 级联，
                    // 中文回落 PingFang SC、Emoji 回落 Apple Color Emoji）。
                    .font(Font(TerminalFontProvider.regularFont(size: 13)))
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text(verbatim: sourceLabel)
                    // 来源属于辅助文字，统一使用 11 pt 常规字重。
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            CommandRowActions(
                onPaste: { appState.commandDispatcher.paste(command: entry.command) },
                onExecute: { appState.commandDispatcher.execute(command: entry.command, source: .historyReplay) },
                enabled: canDispatch
            )
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .contextMenu {
            // 整行都是右键目标；不恢复文本选择，避免系统「字体/格式」菜单。
            Button(action: onAddToSavedCommands) {
                Text(verbatim: L10n.string(
                    "sidebar_right.add_to_saved_commands",
                    defaultValue: "Add to Saved Commands",
                    locale: locale
                ))
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Text(verbatim: L10n.string(
                    "sidebar_right.delete_history_entry",
                    defaultValue: "Delete This History Entry",
                    locale: locale
                ))
            }
        }
        // 背景与 Paste / Run 按钮使用同一 hover transaction 平滑出现、消失。
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
            value: isHovering
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    /// row 来源标注（session kind + host + 相对时间）。
    private var sourceLabel: String {
        let host = entry.hostDisplayName ?? L10n.string(
            "sidebar_right.local",
            defaultValue: "Local",
            locale: locale
        )
        return host
    }
}
