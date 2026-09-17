import SwiftUI

/// B4 §37–§41：Tool Activity UI（read-only 工具自动执行，但每个 tool call
/// 必须有 UI 可见痕迹——privacy hard gate：绝不后台静默读文件并发给
/// Provider）。
///
/// 卡片只展示（§39）：
/// - 工具类型（本地化；未知 / prohibited 名字原样展示并标为"工具调用"）；
/// - 安全的目标信息（用户可理解的 path 或空，§40）；
/// - 状态：running / success / failure / cancelled（§38）。
///
/// 默认不展开完整文件内容 / 终端输出 / 目录列表（§39）。
struct AgentToolCardView: View {
    /// R2：稳定的 AX 标识供 UI/AX smoke 与 XCTest 复用，避免测试依赖
    /// 本地化按钮文字或 SwiftUI 生成的临时层级。
    static let cardAccessibilityIdentifier = "agent.tool_card"
    static let approveAccessibilityIdentifier = "agent.command.approve"
    static let denyAccessibilityIdentifier = "agent.command.deny"

    /// 10F-B4-S1 §23：terminal mutation 审批按钮独立标识。
    static let terminalApproveAccessibilityIdentifier = "agent.terminal.approve"
    static let terminalDenyAccessibilityIdentifier = "agent.terminal.deny"
    static let terminalTargetAccessibilityIdentifier = "agent.terminal.target"
    static let terminalSubmitAccessibilityIdentifier = "agent.terminal.submit"
    static let terminalTextAccessibilityIdentifier = "agent.terminal.text"

    /// 10F-C3：Local create-only file approval card 的稳定 AX 标识。
    static let fileApproveAccessibilityIdentifier = "agent.file.approve"
    static let fileDenyAccessibilityIdentifier = "agent.file.deny"
    static let fileTargetAccessibilityIdentifier = "agent.file.target"
    static let fileBytesAccessibilityIdentifier = "agent.file.bytes"
    static let fileContentAccessibilityIdentifier = "agent.file.content"
    static let filePolicyAccessibilityIdentifier = "agent.file.policy"
    static let fileStatusAccessibilityIdentifier = "agent.file.status"

    /// R2：审批动作只在等待审批时存在；运行中由 Composer Stop 负责取消。
    static func showsApprovalActions(for status: AgentToolActivity.Status) -> Bool {
        status == .awaitingApproval
    }

    let activity: AgentToolActivity
    /// B4：审批动作只由侧栏注入，实际状态转换仍由 AgentViewModel 的 actor façade 负责。
    let onApprove: () -> Void
    let onDeny: () -> Void

    @Environment(\.locale) private var locale

    init(
        activity: AgentToolActivity,
        onApprove: @escaping () -> Void = {},
        onDeny: @escaping () -> Void = {}
    ) {
        self.activity = activity
        self.onApprove = onApprove
        self.onDeny = onDeny
    }

    var body: some View {
        Group {
            if activity.toolName == AgentToolName.runCommand.rawValue {
                commandCard
            } else if activity.toolName == AgentToolName.sendToTerminal.rawValue {
                mutationCard
            } else if activity.toolName == AgentToolName.writeFile.rawValue {
                fileCard
            } else {
                standardCard
            }
        }
        // R2：卡片只能作为容器，不能把安全按钮合并成一个可 Press 的
        // AX 元素；Approve / Deny 必须继续作为独立 Button 暴露。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.cardAccessibilityIdentifier)
        .accessibilityValue(statusKey)
    }

    // MARK: - Read-only card

    private var standardCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact / 2) {
            Image(systemName: toolIconName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(verbatim: toolLabel)
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            if let target = activity.displayTarget {
                Text(verbatim: target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppTheme.Spacing.compact / 2)
            statusView
        }
        .padding(.horizontal, AppTheme.Spacing.compact)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .background(cardBackground)
    }

    // MARK: - Command approval card

    /// Approval Card 的信息顺序固定为 target / cwd / provider / exact command /
    /// egress disclosure / explicit actions，避免把执行风险藏在按钮之后。
    private var commandCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact / 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)

                Text(verbatim: toolLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if let request = activity.commandRequest {
                    targetBadge(for: request)
                }

                Spacer(minLength: AppTheme.Spacing.compact / 2)
                statusView
            }

            if let request = activity.commandRequest {
                commandDetails(request)
            } else if let target = activity.displayTarget {
                Text(verbatim: target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if Self.showsApprovalActions(for: activity.status) {
                approvalActions
            }
        }
        .padding(AppTheme.Spacing.compact)
        .background(commandCardBackground)
    }

    /// 显示 immutable request 的冻结信息，不从 active session 或 Settings 重读。
    @ViewBuilder
    private func commandDetails(_ request: AgentCommandRequest) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact / 2) {
            detailRow(
                label: L10n.string("agent.command.target", defaultValue: "Target", locale: locale),
                value: commandTargetName(for: request)
            )
            detailRow(
                label: L10n.string(
                    "agent.command.working_directory",
                    defaultValue: "Working directory",
                    locale: locale
                ),
                value: request.workingDirectory,
                monospaced: true
            )
            detailRow(
                label: L10n.string("agent.command.provider", defaultValue: "AI service", locale: locale),
                value: providerLabel(for: request)
            )

            Text(L10n.string("agent.command.command", defaultValue: "Exact command", locale: locale))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            // 16 KiB 的上限仍允许很长命令；滚动只限制卡片高度，不截断内容。
            ScrollView(.vertical) {
                Text(verbatim: request.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Spacing.compact / 2)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )

            Text(
                L10n.format(
                    "agent.command.disclosure",
                    defaultValue: "If approved, bounded stdout and stderr will be returned to %@.",
                    locale: locale,
                    arguments: providerLabel(for: request)
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact / 2) {
            Text(verbatim: label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Terminal mutation approval card（10F-B4-S1 §18–§24）

    /// send_to_terminal 卡片：展示冻结的 exact text / submit / target，
    /// 并披露 §21 警告文案。所有数据来自 activity.mutationRequest 的
    /// immutable 值——绝不从 active session / Settings 重读。
    private var mutationCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact / 2) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)

                Text(verbatim: toolLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if let request = activity.mutationRequest {
                    mutationTargetBadge(for: request)
                }

                Spacer(minLength: AppTheme.Spacing.compact / 2)
                statusView
            }

            if let request = activity.mutationRequest {
                mutationDetails(request)
            } else if let target = activity.displayTarget {
                Text(verbatim: target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if Self.showsApprovalActions(for: activity.status) {
                mutationApprovalActions
            }
        }
        .padding(AppTheme.Spacing.compact)
        .background(commandCardBackground)
    }

    // MARK: - Local file approval card（10F-C3）

    /// write_file 卡片只展示 proposal-time immutable request：resolved target、
    /// 精确 UTF-8 字节数、可滚动的原文预览与 create-only disclosure。卡片本身
    /// 没有任何 tap action，只有明确独立的 Approve / Deny 按钮可以改变 approval。
    private var fileCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact / 2) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)

                Text(verbatim: toolLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if let request = activity.fileMutationRequest {
                    fileTargetBadge(for: request)
                }

                Spacer(minLength: AppTheme.Spacing.compact / 2)
                statusView
                    .accessibilityIdentifier(Self.fileStatusAccessibilityIdentifier)
            }

            if let request = activity.fileMutationRequest {
                fileDetails(request)
            } else if let target = activity.displayTarget {
                Text(verbatim: target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if Self.showsApprovalActions(for: activity.status) {
                fileApprovalActions
            }
        }
        .padding(AppTheme.Spacing.compact)
        .background(commandCardBackground)
    }

    /// immutable file proposal 的全部用户可审阅信息；实际执行仍消费
    /// request 内冻结的 exact bytes，不从当前 active session 重新取值。
    @ViewBuilder
    private func fileDetails(_ request: AgentFileMutationRequest) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact / 2) {
            fileDetailRow(
                label: L10n.string("agent.file.target", defaultValue: "Target", locale: locale),
                value: request.displayPath,
                monospaced: true
            )
            .accessibilityIdentifier(Self.fileTargetAccessibilityIdentifier)

            fileDetailRow(
                label: L10n.string(
                    "agent.file.bytes",
                    defaultValue: "UTF-8 bytes",
                    locale: locale
                ),
                value: "\(request.payloadIdentity.byteCount)",
                monospaced: true
            )
            .accessibilityIdentifier(Self.fileBytesAccessibilityIdentifier)

            Text(L10n.string("agent.file.content", defaultValue: "Exact UTF-8 text", locale: locale))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            // 内容最多 256 KiB；ScrollView 只限制展示窗口高度，不截断或改写
            // 实际 payload。空内容显示明确占位，仍保留 0-byte 语义。
            ScrollView(.vertical) {
                if request.content.isEmpty {
                    Text(
                        L10n.string(
                            "agent.file.empty_content",
                            defaultValue: "〈empty text〉",
                            locale: locale
                        )
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: request.content)
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .accessibilityIdentifier(Self.fileContentAccessibilityIdentifier)

            fileDetailRow(
                label: L10n.string("agent.file.policy", defaultValue: "Policy", locale: locale),
                value: L10n.string(
                    "agent.file.policy.value",
                    defaultValue: "Create only · existing destinations are not overwritten",
                    locale: locale
                )
            )
            .accessibilityIdentifier(Self.filePolicyAccessibilityIdentifier)

            Text(
                L10n.string(
                    "agent.file.disclosure",
                    defaultValue: "MacSSH will create a new local text file at the shown target. Existing files are not overwritten. The exact approved UTF-8 text will be written if publication succeeds. Remote files are not modified.",
                    locale: locale
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if fileHasCleanupResidue {
                Text(
                    L10n.string(
                        "agent.file.cleanup_warning",
                        defaultValue: "File created; private staging cleanup is still pending.",
                        locale: locale
                    )
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 文件目标需要完整可读；与 command/terminal 的单行 detail row 分开，
    /// 允许长的 resolved path 换行而不改变冻结值。
    private func fileDetailRow(
        label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact / 2) {
            Text(verbatim: label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func fileTargetBadge(for _: AgentFileMutationRequest) -> some View {
        Text(L10n.string("agent.command.target.local", defaultValue: "Local", locale: locale))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.14))
            )
            .accessibilityHidden(true)
    }

    private var fileApprovalActions: some View {
        HStack(spacing: AppTheme.Spacing.compact / 2) {
            Spacer(minLength: 0)

            Button(role: .cancel, action: onDeny) {
                Text(L10n.string("agent.file.deny", defaultValue: "Deny", locale: locale))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .accessibilityLabel(
                L10n.string("agent.file.deny", defaultValue: "Deny", locale: locale)
            )
            .accessibilityHint(
                L10n.string(
                    "agent.file.deny.hint",
                    defaultValue: "Reject this file creation before anything is written.",
                    locale: locale
                )
            )
            .accessibilityIdentifier(Self.fileDenyAccessibilityIdentifier)

            Button(action: onApprove) {
                Text(L10n.string("agent.file.approve", defaultValue: "Approve", locale: locale))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityLabel(
                L10n.string("agent.file.approve", defaultValue: "Approve", locale: locale)
            )
            .accessibilityHint(
                L10n.string(
                    "agent.file.approve.hint",
                    defaultValue: "Create this new local text file with the exact approved UTF-8 text.",
                    locale: locale
                )
            )
            .accessibilityIdentifier(Self.fileApproveAccessibilityIdentifier)
        }
    }

    /// cleanupResidue 是 published success 的 warning，不是失败或可重试状态。
    private var fileHasCleanupResidue: Bool {
        guard
            activity.status == .success,
            let resultJSON = activity.resultJSON,
            let data = resultJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["published"] as? Bool == true,
            object["cleanupResidue"] as? Bool == true
        else {
            return false
        }
        return true
    }

    /// immutable request 的冻结信息：target / submit / exact text /
    /// §21 disclosure。payload 绝不 trim / rewrite（§19）。
    @ViewBuilder
    private func mutationDetails(_ request: AgentTerminalMutationRequest) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact / 2) {
            detailRow(
                label: L10n.string("agent.terminal.target", defaultValue: "Target", locale: locale),
                value: mutationTargetName(for: request)
            )
            .accessibilityIdentifier(Self.terminalTargetAccessibilityIdentifier)

            detailRow(
                label: L10n.string(
                    "agent.terminal.submit",
                    defaultValue: "Submit (append Return)",
                    locale: locale
                ),
                value: mutationSubmitText(for: request)
            )
            .accessibilityIdentifier(Self.terminalSubmitAccessibilityIdentifier)

            Text(L10n.string("agent.terminal.text", defaultValue: "Exact text", locale: locale))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            // 64 KiB 上限允许长 payload；滚动只限制卡片高度，绝不截断 /
            // 改写实际交付的字节（§19/§20）。
            ScrollView(.vertical) {
                Text(verbatim: request.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Spacing.compact / 2)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .accessibilityIdentifier(Self.terminalTextAccessibilityIdentifier)

            Text(
                L10n.string(
                    "agent.terminal.disclosure",
                    defaultValue: """
                        This sends input to the existing interactive terminal. \
                        The terminal or a running application may act on it immediately. \
                        If Submit is enabled, MacSSH appends Return after the text. \
                        Terminal output is not captured by this action.
                        """,
                    locale: locale
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mutationTargetBadge(
        for request: AgentTerminalMutationRequest
    ) -> some View {
        Text(verbatim: mutationTargetKind(for: request))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.14))
            )
    }

    private var mutationApprovalActions: some View {
        HStack(spacing: AppTheme.Spacing.compact / 2) {
            Spacer(minLength: 0)

            Button(role: .cancel, action: onDeny) {
                Text(L10n.string("agent.terminal.deny", defaultValue: "Deny", locale: locale))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .accessibilityLabel(
                L10n.string("agent.terminal.deny", defaultValue: "Deny", locale: locale)
            )
            .accessibilityHint(
                L10n.string(
                    "agent.terminal.deny.hint",
                    defaultValue: "Reject this terminal input before anything is sent.",
                    locale: locale
                )
            )
            .accessibilityIdentifier(Self.terminalDenyAccessibilityIdentifier)

            Button(action: onApprove) {
                Text(L10n.string("agent.terminal.approve", defaultValue: "Approve", locale: locale))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityLabel(
                L10n.string("agent.terminal.approve", defaultValue: "Approve", locale: locale)
            )
            .accessibilityHint(
                L10n.string(
                    "agent.terminal.approve.hint",
                    defaultValue: "Send this text to the interactive terminal.",
                    locale: locale
                )
            )
            .accessibilityIdentifier(Self.terminalApproveAccessibilityIdentifier)
        }
    }

    private func mutationTargetKind(for request: AgentTerminalMutationRequest) -> String {
        switch request.targetSnapshot {
        case .local:
            return L10n.string("agent.command.target.local", defaultValue: "Local", locale: locale)
        case .remote:
            return L10n.string(
                "agent.command.target.remote",
                defaultValue: "Remote SSH",
                locale: locale
            )
        }
    }

    private func mutationTargetName(for request: AgentTerminalMutationRequest) -> String {
        switch request.targetSnapshot {
        case .local:
            return L10n.string("agent.command.target.local", defaultValue: "Local", locale: locale)
        case .remote(let hostDisplay):
            return L10n.string(
                "agent.command.target.remote",
                defaultValue: "Remote SSH",
                locale: locale
            ) + " · " + hostDisplay
        }
    }

    private func mutationSubmitText(for request: AgentTerminalMutationRequest) -> String {
        request.submit
            ? L10n.string("agent.terminal.submit.yes", defaultValue: "Yes", locale: locale)
            : L10n.string("agent.terminal.submit.no", defaultValue: "No", locale: locale)
    }

    private func targetBadge(for request: AgentCommandRequest) -> some View {
        Text(verbatim: commandTargetKind(for: request))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.14))
            )
    }

    private var approvalActions: some View {
        HStack(spacing: AppTheme.Spacing.compact / 2) {
            Spacer(minLength: 0)

            Button(role: .cancel, action: onDeny) {
                Text(L10n.string("agent.command.deny", defaultValue: "Deny", locale: locale))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .accessibilityLabel(
                L10n.string("agent.command.deny", defaultValue: "Deny", locale: locale)
            )
            .accessibilityHint(
                L10n.string(
                    "agent.command.deny.hint",
                    defaultValue: "Reject this command before it starts.",
                    locale: locale
                )
            )
            .accessibilityIdentifier(Self.denyAccessibilityIdentifier)

            Button(action: onApprove) {
                Text(L10n.string("agent.command.approve", defaultValue: "Approve", locale: locale))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityLabel(
                L10n.string("agent.command.approve", defaultValue: "Approve", locale: locale)
            )
            .accessibilityHint(
                L10n.string(
                    "agent.command.approve.hint",
                    defaultValue: "Approve this command to start execution.",
                    locale: locale
                )
            )
            .accessibilityIdentifier(Self.approveAccessibilityIdentifier)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    private var commandCardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.orange.opacity(activity.status == .awaitingApproval ? 0.08 : 0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.orange.opacity(activity.status == .awaitingApproval ? 0.32 : 0.12),
                        lineWidth: 0.75
                    )
            )
    }

    // MARK: - 状态（§38）

    @ViewBuilder
    private var statusView: some View {
        switch activity.status {
        case .running:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(verbatim: statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .awaitingApproval:
            HStack(spacing: 4) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                statusTextView
            }
        case .success:
            statusIconText(icon: "checkmark", color: .secondary)
        case .failure:
            statusIconText(icon: "exclamationmark.triangle", color: .secondary)
        case .denied:
            statusIconText(icon: "xmark", color: .secondary)
        case .cancelled:
            statusTextView.foregroundStyle(.tertiary)
        case .timedOut:
            statusIconText(icon: "clock.badge.exclamationmark", color: .secondary)
        case .partial:
            statusIconText(icon: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func statusIconText(icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            statusTextView
        }
    }

    private var statusTextView: some View {
        Text(verbatim: statusText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private var statusKey: String {
        activity.status.rawMarker
    }

    private var statusText: String {
        // write_file 的成功语义是“文件已创建”，而不是泛化的“Done”；清理残留
        // 仍然保持 published success，只在同一张卡片上追加可见 warning。
        if activity.toolName == AgentToolName.writeFile.rawValue {
            switch activity.status {
            case .success:
                return fileHasCleanupResidue
                    ? L10n.string(
                        "agent.file.status.cleanup_warning",
                        defaultValue: "Created · cleanup pending",
                        locale: locale
                    )
                    : L10n.string(
                        "agent.file.status.published",
                        defaultValue: "File created",
                        locale: locale
                    )
            default:
                break
            }
        }

        switch activity.status {
        case .running:
            return L10n.string("agent.tool.status.running", defaultValue: "Running", locale: locale)
        case .awaitingApproval:
            return L10n.string(
                "agent.tool.status.awaiting_approval",
                defaultValue: "Approval required",
                locale: locale
            )
        case .success:
            return L10n.string("agent.tool.status.success", defaultValue: "Done", locale: locale)
        case .failure:
            return L10n.string("agent.tool.status.failure", defaultValue: "Failed", locale: locale)
        case .denied:
            return L10n.string("agent.tool.status.denied", defaultValue: "Denied", locale: locale)
        case .cancelled:
            return L10n.string("agent.tool.status.cancelled", defaultValue: "Cancelled", locale: locale)
        case .timedOut:
            return L10n.string(
                "agent.tool.status.timed_out",
                defaultValue: "Timed out",
                locale: locale
            )
        case .partial:
            return L10n.string(
                "agent.tool.status.partial",
                defaultValue: "Partially delivered",
                locale: locale
            )
        }
    }

    // MARK: - 工具名与图标（§39）

    /// 已知 7 工具 → 本地化名称；未知 / prohibited 名字原样展示原始
    /// 名字（绝不隐藏模型实际请求了什么）。
    private var toolLabel: String {
        switch activity.toolName {
        case AgentToolName.getTerminalContext.rawValue:
            return L10n.string(
                "agent.tool.get_terminal_context",
                defaultValue: "Read terminal context",
                locale: locale
            )
        case AgentToolName.getCurrentDirectory.rawValue:
            return L10n.string(
                "agent.tool.get_current_directory",
                defaultValue: "Get current directory",
                locale: locale
            )
        case AgentToolName.listDirectory.rawValue:
            return L10n.string(
                "agent.tool.list_directory",
                defaultValue: "List directory",
                locale: locale
            )
        case AgentToolName.readFile.rawValue:
            return L10n.string(
                "agent.tool.read_file",
                defaultValue: "Read file",
                locale: locale
            )
        case AgentToolName.runCommand.rawValue:
            return L10n.string(
                "agent.tool.run_command",
                defaultValue: "Run command",
                locale: locale
            )
        case AgentToolName.sendToTerminal.rawValue:
            return L10n.string(
                "agent.tool.send_to_terminal",
                defaultValue: "Send to terminal",
                locale: locale
            )
        case AgentToolName.writeFile.rawValue:
            return L10n.string(
                "agent.tool.write_file",
                defaultValue: "Create local file",
                locale: locale
            )
        default:
            return L10n.string("agent.tool.unknown", defaultValue: "Tool call", locale: locale)
                + " · " + activity.toolName
        }
    }

    private var toolIconName: String {
        switch activity.toolName {
        case AgentToolName.getTerminalContext.rawValue:
            return "terminal"
        case AgentToolName.getCurrentDirectory.rawValue:
            return "folder"
        case AgentToolName.listDirectory.rawValue:
            return "list.bullet"
        case AgentToolName.readFile.rawValue:
            return "doc.text"
        case AgentToolName.runCommand.rawValue:
            return "terminal"
        case AgentToolName.sendToTerminal.rawValue:
            return "text.cursor"
        case AgentToolName.writeFile.rawValue:
            return "doc.badge.plus"
        default:
            return "wrench.and.screwdriver"
        }
    }

    private func commandTargetKind(for request: AgentCommandRequest) -> String {
        switch request.target {
        case .local:
            return L10n.string("agent.command.target.local", defaultValue: "Local", locale: locale)
        case .remote:
            return L10n.string(
                "agent.command.target.remote",
                defaultValue: "Remote SSH",
                locale: locale
            )
        }
    }

    private func commandTargetName(for request: AgentCommandRequest) -> String {
        switch request.target {
        case .local(let displayName), .remote(let displayName):
            return "\(commandTargetKind(for: request)) · \(displayName)"
        }
    }

    private func providerLabel(for request: AgentCommandRequest) -> String {
        let providerName = L10n.string(
            request.providerBinding.provider.localizedNameKey,
            defaultValue: "Provider",
            locale: locale
        )
        return "\(providerName) · \(request.providerBinding.model)"
    }
}
