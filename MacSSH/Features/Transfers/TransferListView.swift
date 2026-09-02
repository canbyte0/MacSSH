import SwiftUI

/// Phase 10 Transfers 页：传输任务列表（最新在上）。
///
/// 页面只观察 `TransferManager`（App 层稳定对象）：切换离开本页
/// 绝不取消传输；行内仅活跃任务提供 Cancel。
struct TransferListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale

    private var manager: TransferManager {
        appState.transferManager
    }

    var body: some View {
        Group {
            if manager.tasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // 显式按当前 Locale 解析标题，避免 NavigationSplitView 缓存旧语言。
        .navigationTitle(
            L10n.string("transfers.title", defaultValue: "Transfers", locale: locale)
        )
        .accessibilityIdentifier("workspace.transfers")
    }

    // MARK: - 空状态

    private var emptyState: some View {
        PlaceholderContentView(
            systemImage: "arrow.up.arrow.down",
            title: "transfers.title",
            message: "transfers.empty_message"
        )
        .accessibilityIdentifier("transfers.empty")
    }

    // MARK: - 任务列表

    private var taskList: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            List {
                // 最新任务在上；任务集合本身保持创建顺序（拆除屏障遍历用）。
                ForEach(manager.tasks.reversed(), id: \.id) { task in
                    TransferRowView(task: task, locale: locale) {
                        manager.cancel(task.id)
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("transfers.list")

            Divider()

            HStack {
                Text(verbatim: itemCountText(manager.tasks.count))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("transfers.clear_finished") {
                    manager.clearFinished()
                }
                .disabled(!manager.tasks.contains(where: { $0.state.isTerminal }))
                .accessibilityIdentifier("transfers.clear")
            }
            .font(.caption)
            .padding(.horizontal, AppTheme.Spacing.regular)
            .padding(.vertical, AppTheme.Spacing.compact / 2)
            .accessibilityIdentifier("transfers.footer")
        }
    }

    /// 英文按单复数选择资源；中文共用"个任务"的自然表达。
    private func itemCountText(_ count: Int) -> String {
        let key: StaticString = count == 1 ? "transfers.count.one" : "transfers.count.other"
        let fallback: String.LocalizationValue = count == 1 ? "%lld task" : "%lld tasks"
        return L10n.format(key, defaultValue: fallback, locale: locale, arguments: Int64(count))
    }
}

/// 单条传输任务行：方向 + 文件名 + 会话、进度 / 字节 / 速度、
/// 状态与取消入口。字节数到达绝不提前显示"已完成"（终态由业务层
/// 在句柄关闭 + 发布 / 替换成功后写入）。
private struct TransferRowView: View {
    let task: TransferTask
    let locale: Locale
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact / 2) {
            HStack(spacing: AppTheme.Spacing.compact) {
                Image(systemName: task.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                    .foregroundStyle(AppTheme.accentColor)

                Text(task.localName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(verbatim: sessionDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if !task.state.isTerminal {
                    Button("action.cancel") {
                        onCancel()
                    }
                    .controlSize(.small)
                    .disabled(task.state == .cancelling)
                    .accessibilityIdentifier("transfers.cancel.\(task.id)")
                }
            }

            switch task.state {
            case .pending:
                // 排队中：不显示进度条，绝不伪造 0% / 0 B/s（任务书三十）。
                EmptyView()
            case .preparing:
                ProgressView()
                    .controlSize(.small)
            case .transferring, .cancelling:
                if let fraction = task.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    // 未知大小：indeterminate，绝不伪造 100%。
                    ProgressView()
                        .controlSize(.small)
                }
            case .completed, .failed, .cancelled:
                EmptyView()
            }

            HStack(spacing: AppTheme.Spacing.compact) {
                Text(verbatim: task.stateDisplay(locale: locale))
                    .foregroundStyle(stateColor)

                Text(task.progressDisplay)
                    .foregroundStyle(.secondary)

                if let speed = task.speedDisplay {
                    Text(speed)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .font(.caption)
            .monospacedDigit()

            // 按**当前** Locale 即时解析（任务书七十三）：失败文案绝不读取
            // 失败时刻缓存的字符串，语言切换后列表立即显示新语言。
            // `verbatim:` —— 文案已本地化完成，不再做第二次 key 查找。
            if let message = task.failureMessage(locale: locale) {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfers.row.\(task.id)")
    }

    private var stateColor: Color {
        switch task.state {
        case .completed:
            return Color.green
        case .failed:
            return Color.red
        case .cancelled:
            return Color.secondary
        case .preparing, .transferring, .cancelling:
            return AppTheme.accentColor
        case .pending:
            return Color.orange
        }
    }

    /// 会话显示名：所属 Session 仍在时按当前 Locale 动态本地化
    /// （语言切换立即生效）；Session 已关闭（任务终态保留展示）时
    /// 回退创建时冻结的技术名。传输任务本身绝不因语言切换重建。
    private var sessionDisplayName: String {
        task.sessionRef?.displayTitle(locale: locale) ?? task.sessionTitle
    }
}
