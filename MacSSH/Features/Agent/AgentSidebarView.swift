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
                    // B4 §37–§41：tool card 与会话文本共享同一有序时间线；
                    // provider opaque item 不渲染（renderableMessages 过滤）。
                    ForEach(conversation.renderableMessages) { message in
                        if let activity = message.toolActivity {
                            AgentToolCardView(
                                activity: activity,
                                onApprove: {
                                    viewModel.approveCommand(
                                        cardID: message.id,
                                        sessionID: conversation.sessionID
                                    )
                                },
                                onDeny: {
                                    viewModel.denyCommand(
                                        cardID: message.id,
                                        sessionID: conversation.sessionID
                                    )
                                }
                            )
                                .id(message.id)
                                .padding(.horizontal, AppTheme.Spacing.regular)
                                .padding(.vertical, AppTheme.Spacing.compact / 4)
                        } else {
                            AgentMessageView(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.vertical, AppTheme.Spacing.compact / 2)
            }
            // 新消息 / streaming chunk 到来时滚到底部；用户主动上翻暂不锁定
            // （任务书 §19 第一版策略）。trigger 含最后一条消息 id + 内容长度，
            // chunk 追加与消息增删都会触发。
            .onChange(of: scrollTrigger(conversation)) { _, _ in
                if let last = conversation.renderableMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func scrollTrigger(_ conversation: AgentConversation) -> String {
        guard let last = conversation.renderableMessages.last else { return "empty" }
        let contentMarker: String
        if let activity = last.toolActivity {
            contentMarker = activity.status.rawMarker
        } else {
            contentMarker = "\(last.text.count)"
        }
        return "\(last.id):\(contentMarker)"
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
            composerInput(conversation: conversation)
                .padding(.horizontal, AppTheme.Spacing.regular)
                .padding(.vertical, AppTheme.Spacing.compact)
        } else {
            // 无可用 session：禁用态 composer（不提供可输入的假象，任务书 §5）。
            composerSurface {
                Text("agent.context.unavailable")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(EdgeInsets(top: 12, leading: 12, bottom: 44, trailing: 12))
            } action: {
                actionButton(conversation: nil)
            }
            .padding(.horizontal, AppTheme.Spacing.regular)
            .padding(.vertical, AppTheme.Spacing.compact)
        }
    }

    /// 多行输入：Return = Send，Shift+Return = 换行（任务书 §13 建议）。
    /// 使用原生 prompt 与真实插入光标共享排版基线，避免叠加 placeholder 产生错位。
    private func composerInput(conversation: AgentConversation) -> some View {
        @Bindable var conversation = conversation
        return composerSurface {
            // 文字区固定显示约 4 行；超出后由外层 ScrollView 提供原生滚动条。
            ScrollView(.vertical) {
                TextField(
                    "agent.input.placeholder",
                    text: $conversation.draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                // 允许文本自身继续增长，让 ScrollView 能准确感知溢出高度。
                .lineLimit(1...)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .onKeyPress(.return, phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        // Shift+Return：交给多行 TextField 插入换行。
                        return .ignored
                    }
                    viewModel.send()
                    return .handled
                }
                .accessibilityIdentifier("agent.composer.input")
            }
            // 系统滚动条只在内容溢出时出现，并局限在发送按钮上方的文字区。
            .scrollIndicators(.visible)
            .frame(height: 68)
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 44, trailing: 8))
        } action: {
            actionButton(conversation: conversation)
        }
    }

    /// 统一可输入与禁用态的圆角容器，发送 / 停止按钮固定在容器右下角。
    private func composerSurface<Content: View, Action: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder action: () -> Action
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
            )
            .overlay {
                // 轻量边框在浅色与深色模式中都保持可辨识，但不抢输入内容层级。
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                action()
                    .padding(AppTheme.Spacing.compact)
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
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .frame(
                    width: AppTheme.ButtonInteraction.compactIconBackgroundDiameter,
                    height: AppTheme.ButtonInteraction.compactIconBackgroundDiameter
                )
                .background(
                    Circle()
                        .fill(enabled ? Color.accentColor : Color.secondary.opacity(0.14))
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
