import SwiftData
import SwiftUI

/// MacSSH 1.1 Phase 7：历史记录侧边栏视图。
///
/// History v1 只记录通过 MacSSH Execute 执行的命令（任务书 §22 / §24 / Phase 7A 验收 §38）。
/// 页面顶部明确 disclosure（任务书 §24 / Phase 7A 验收 §38：保留「历史记录」名，
/// 但说明限制）。History row 也支持 Paste / Run（replay 会再新增 history，§25 / §39）。
struct CommandHistorySidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @Query(
        sort: [SortDescriptor(\CommandHistoryEntry.executedAt, order: .reverse)]
    )
    private var entries: [CommandHistoryEntry]

    @State private var pendingClear = false

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
                            HistoryRow(entry: entry, canDispatch: appState.commandDispatcher.canDispatch)
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.compact / 2)
                }
            }
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
                .buttonStyle(.borderless)
                .help(L10n.string("sidebar_right.clear_history", defaultValue: "Clear History", locale: locale))
                .accessibilityLabel(L10n.string("sidebar_right.clear_history", defaultValue: "Clear History", locale: locale))
                .accessibilityIdentifier("sidebar_right.clearHistory")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
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
    /// 复用 `sidebar_right.history_disclosure` 双语文案，footnote + secondary。
    private var disclosureBanner: some View {
        Text(verbatim: L10n.string(
            "sidebar_right.history_disclosure",
            defaultValue: "This version records commands run through MacSSH.\nCommands entered manually in the terminal are not recorded.",
            locale: locale
        ))
        .font(.caption2)
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

// MARK: - History row

private struct HistoryRow: View {
    let entry: CommandHistoryEntry
    let canDispatch: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.compact) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.command)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text(verbatim: sourceLabel)
                    .font(.caption2)
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
