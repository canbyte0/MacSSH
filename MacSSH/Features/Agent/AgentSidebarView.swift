import SwiftUI

/// MacSSH 1.1 Phase 10B：Agent tab 内容（任务书 §4）：
/// context header + 聊天区（auto-scroll / empty state）+ composer。
///
/// 焦点（任务书 §25）：打开 Agent tab 不抢 Terminal 焦点；
/// 点击 composer 才获得输入焦点；发送后焦点留在 composer。
struct AgentSidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale

    private var viewModel: AgentViewModel {
        appState.agentViewModel
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            AgentContextHeaderView(context: viewModel.activeContext)

            Divider()

            // Provider 未配置提示（任务书 §15）：Send 已禁用，引导用户到 Settings
            // 配置 API Key；配置后返回本页时 onAppear 会刷新 providerState。
            if viewModel.providerState == .notConfigured {
                notConfiguredNotice
            }

            // 无 session 时发送被阻止的 non-fatal 提示（任务书 §14）。
            if viewModel.showsNoSessionNotice && viewModel.activeContext == nil {
                Text("agent.error.no_session")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.Spacing.regular)
                    .padding(.vertical, AppTheme.Spacing.compact / 2)
            }

            if let conversation = viewModel.activeConversation, !conversation.isEmpty {
                messageList(conversation)
            } else {
                emptyState
            }

            Divider()

            composerArea
        }
        .accessibilityIdentifier("sidebar_right.agent_content")
        .onAppear {
            // 打开 Agent tab / sidebar 切回 Agent：确保当前 session 有 conversation，
            // 清理已关闭 session 的残留会话，并刷新 Provider 配置就绪状态
            // （任务书 §15：Settings 中保存 / 删除 Key 后返回本页立即生效）。
            viewModel.ensureConversationForActiveSession()
            viewModel.pruneConversations()
            Task {
                await viewModel.refreshProviderConfiguration()
            }
        }
        .onChange(of: appState.sessionManager.activeSessionID) { _, _ in
            // 切 tab：新 session 的 conversation 按需创建 + 清理失效会话
            // （任务书 §17：Local A ↔ Local B ↔ Remote C 互不串线）。
            viewModel.ensureConversationForActiveSession()
            viewModel.pruneConversations()
        }
        .onChange(of: appState.sessionManager.sessions.count) { _, _ in
            // 任意 session 创建 / 关闭（含关闭非 active tab）：清理已关闭
            // session 的 conversation 并取消其生成任务（任务书 §18）。
            viewModel.pruneConversations()
        }
    }

    /// 未配置 AI 服务提示（任务书 §15）：明确区分于 generic network error。
    private var notConfiguredNotice: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.compact / 2) {
            Image(systemName: "key")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("agent.provider.not_configured")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.regular)
        .padding(.vertical, AppTheme.Spacing.compact / 2)
        .accessibilityIdentifier("agent.provider.not_configured_notice")
    }

    // MARK: - 消息列表（任务书 §19）

    private func messageList(_ conversation: AgentConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                    ForEach(conversation.messages) { message in
                        AgentMessageView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, AppTheme.Spacing.compact / 2)
            }
            // 新消息 / streaming chunk 到来时滚到底部；用户主动上翻暂不锁定
            // （任务书 §19 第一版策略）。trigger 含最后一条消息 id + 内容长度，
            // chunk 追加与消息增删都会触发。
            .onChange(of: scrollTrigger(conversation)) { _, _ in
                if let last = conversation.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func scrollTrigger(_ conversation: AgentConversation) -> String {
        guard let last = conversation.messages.last else { return "empty" }
        return "\(last.id):\(last.content.count)"
    }

    // MARK: - Empty state（任务书 §21）

    private var emptyState: some View {
        ContentUnavailableView {
            Label("agent.empty.title", systemImage: "sparkles")
        } description: {
            Text("agent.empty.subtitle")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("agent.empty_state")
    }

    // MARK: - Composer（任务书 §13 / §14 / §15）

    @ViewBuilder
    private var composerArea: some View {
        if let conversation = viewModel.activeConversation {
            @Bindable var conversation = conversation
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.compact) {
                composerInput(conversation: conversation)
                actionButton(conversation: conversation)
            }
            .padding(.horizontal, AppTheme.Spacing.regular)
            .padding(.vertical, AppTheme.Spacing.compact)
        } else {
            // 无可用 session：禁用态 composer（不提供可输入的假象，任务书 §5）。
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.compact) {
                Text("agent.context.unavailable")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                actionButton(conversation: nil)
            }
            .padding(.horizontal, AppTheme.Spacing.regular)
            .padding(.vertical, AppTheme.Spacing.compact)
        }
    }

    /// 多行输入：Return = Send，Shift+Return = 换行（任务书 §13 建议）。
    /// 高度 1~4 行（min 24 / max 88），超出内部滚动，避免固定高度过大。
    private func composerInput(conversation: AgentConversation) -> some View {
        @Bindable var conversation = conversation
        return ZStack(alignment: .topLeading) {
            TextEditor(text: $conversation.draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 24, maxHeight: 88)
                .onKeyPress(.return, phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        // Shift+Return：交给 TextEditor 插入换行。
                        return .ignored
                    }
                    viewModel.send()
                    return .handled
                }
                .accessibilityIdentifier("agent.composer.input")

            // TextEditor 无原生 placeholder，空草稿时叠加展示。
            if conversation.draft.isEmpty {
                Text("agent.input.placeholder")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Send / Stop 按钮（任务书 §13 / §15）

    @ViewBuilder
    private func actionButton(conversation: AgentConversation?) -> some View {
        let isGenerating = conversation?.isGenerating ?? false
        let enabled = isGenerating || viewModel.canSend

        Button {
            if isGenerating {
                viewModel.stop()
            } else {
                viewModel.send()
            }
        } label: {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                .frame(
                    width: AppTheme.ButtonInteraction.compactIconBackgroundDiameter,
                    height: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
                )
                .background(
                    Circle()
                        .fill(enabled ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(AppInteractiveButtonStyle(
            baseStyle: PlainButtonStyle(),
            compactBackgroundDiameter: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
        ))
        .disabled(!enabled)
        .help(isGenerating
              ? L10n.string("agent.stop", defaultValue: "Stop", locale: locale)
              : L10n.string("agent.send", defaultValue: "Send", locale: locale))
        .accessibilityLabel(isGenerating
                            ? L10n.string("agent.stop", defaultValue: "Stop", locale: locale)
                            : L10n.string("agent.send", defaultValue: "Send", locale: locale))
        .accessibilityIdentifier(
            isGenerating ? "agent.composer.stop" : "agent.composer.send"
        )
    }
}
