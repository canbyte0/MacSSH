import SwiftUI

/// Phase 10 Transfers 页：传输任务列表（最新在上）。
///
/// 页面只观察 `TransferManager`（App 层稳定对象）：切换离开本页
/// 绝不取消传输；行内仅活跃任务提供 Cancel。
struct TransferListView: View {
    @Environment(AppState.self) private var appState

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
        .navigationTitle("Transfers")
        .accessibilityIdentifier("workspace.transfers")
    }

    // MARK: - 空状态

    private var emptyState: some View {
        PlaceholderContentView(
            systemImage: "arrow.up.arrow.down",
            title: "Transfers",
            message: "上传 / 下载开始后，进度会显示在这里"
        )
        .accessibilityIdentifier("transfers.empty")
    }

    // MARK: - 任务列表

    private var taskList: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            List {
                // 最新任务在上；任务集合本身保持创建顺序（拆除屏障遍历用）。
                ForEach(manager.tasks.reversed(), id: \.id) { task in
                    TransferRowView(task: task) {
                        manager.cancel(task.id)
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("transfers.list")

            Divider()

            HStack {
                Text("\(manager.tasks.count) 个任务")
                    .foregroundStyle(.secondary)

                Spacer()

                Button("清除已完成") {
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
}

/// 单条传输任务行：方向 + 文件名 + 会话、进度 / 字节 / 速度、
/// 状态与取消入口。字节数到达绝不提前显示"已完成"（终态由业务层
/// 在句柄关闭 + 发布 / 替换成功后写入）。
private struct TransferRowView: View {
    let task: TransferTask
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact / 2) {
            HStack(spacing: AppTheme.Spacing.compact) {
                Image(systemName: task.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                    .foregroundStyle(AppTheme.accentColor)

                Text(task.localName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(task.sessionTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if !task.state.isTerminal {
                    Button("取消") {
                        onCancel()
                    }
                    .controlSize(.small)
                    .disabled(task.state == .cancelling)
                    .accessibilityIdentifier("transfers.cancel.\(task.id)")
                }
            }

            switch task.state {
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
                Text(task.stateDisplay)
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

            if let message = task.failureMessage {
                Text(message)
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
        }
    }
}
