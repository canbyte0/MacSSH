import SwiftData
import SwiftUI

/// Settings 页面。
///
/// Phase 6 起在 SSH 区新增可交互的 Known Hosts 管理：
/// 列出已持久化的服务器身份（hostname + port + Key Type + Fingerprint + 信任时间），
/// 支持 Forget（删除 KnownHost，下次连接重新出现未知主机对话框）。
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @Query(
        sort: [SortDescriptor(\KnownHost.hostname), SortDescriptor(\KnownHost.port)]
    )
    private var knownHosts: [KnownHost]

    @State private var pendingForgetID: KnownHost.ID?

    /// Forget 持久化失败时携带的错误信息，驱动错误 Alert。
    @State private var forgetError: ForgetFailureInfo?

    /// MacSSH 1.1 Phase 7：清空命令历史确认。
    @State private var pendingClearHistory = false

    // MacSSH 1.1 Phase 10C：AI Agent 设置区（任务书 §12）。
    /// Provider 草稿（Phase 10C-D：OpenAI / DeepSeek；切换即原子持久化，
    /// 防止 provider 与 baseURL 错配把 Key 发往另一服务商服务器）。
    @State private var agentProviderDraft: AgentProviderSettings.Provider = .openAI
    /// Model 草稿（非敏感，UserDefaults 持久化经 AgentProviderSettings.save）。
    @State private var agentModelDraft = ""
    /// Base URL 草稿（保存侧校验 scheme http/https + host，任务书 §10）。
    @State private var agentBaseURLDraft = ""
    /// API Key 草稿（仅存在于本 @State；Save 后立即清空，绝不回填 Keychain
    /// 内容——任务书 §12 / §13 hard gate）。
    @State private var agentAPIKeyDraft = ""
    /// Keychain 中是否已配置 API Key（只读状态，不持有 Key 本体）。
    @State private var agentKeyConfigured = false
    /// Base URL 非法提示（保存侧拦截，不写入 UserDefaults）。
    @State private var agentBaseURLInvalid = false
    /// Keychain 保存 / 删除失败提示（不静默失败）。
    @State private var agentKeyActionFailed = false

    var body: some View {
        @Bindable var appState = appState
        @Bindable var appearanceController = appState.appearanceController
        @Bindable var fontSizeController = appState.terminalFontSizeController

        Form {
            Section("settings.section.general") {
                Picker("settings.language", selection: $appState.language) {
                    ForEach(AppLanguage.allCases) { language in
                        // 语言名称固定使用自身语言，避免误切后找不到返回入口。
                        Text(verbatim: language.displayName)
                            .tag(language)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.language")

                LabeledContent("settings.launch_behavior") {
                    Text("settings.open_main_window")
                }
                LabeledContent("settings.confirm_before_closing_ssh") {
                    Text("common.on")
                }
            }

            Section("settings.section.terminal") {
                LabeledContent("settings.font") {
                    Text(verbatim: "JetBrains Mono")
                }
                // MacSSH 1.1 Phase 9：终端字号可配置（任务书 §46）。
                // 采用紧凑 −/+ 方块按钮 + 中间当前字号（用户在 Phase 9B UI
                // Preview Gate 选定方案 A）。10 pt 时减号 disabled，32 pt 时
                // 加号 disabled，避免越界；不允许直接编辑文字。绑定
                // `$fontSizeController.size`（单一 source of truth），
                // 写入经 `size.didSet` 同步 persist + apply（广播全部已注册
                // TerminalView，SwiftTerm font setter 内置 resetFont → resize
                // → sizeChanged → Local setWinSize / Remote resizeChannelPTY，
                // 不重建任何 Runtime Session）。
                LabeledContent("settings.font_size") {
                    HStack(spacing: 6) {
                        Button {
                            fontSizeController.decrement()
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(fontSizeController.size <= TerminalFontSizeController.minSize)
                        .accessibilityIdentifier("settings.fontSizeDecrement")

                        Text("\(fontSizeController.size) pt")
                            .monospacedDigit()
                            .frame(minWidth: 50, alignment: .center)
                            .accessibilityIdentifier("settings.fontSizeValue")

                        Button {
                            fontSizeController.increment()
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(fontSizeController.size >= TerminalFontSizeController.maxSize)
                        .accessibilityIdentifier("settings.fontSizeIncrement")
                    }
                }
                LabeledContent("settings.scrollback") {
                    Text("settings.scrollback_value")
                }
                // 原生开关：经每个 Local Session 的控制 FIFO 立即同步到 zsh ZLE，
                // 不向当前命令行注入命令，也不影响 Remote Session。
                Toggle("settings.paste_highlight", isOn: $appState.pasteHighlightEnabled)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.pasteHighlight")
                Text("settings.paste_highlight_help")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // MacSSH 1.1 Phase 6：终端字符串高亮子区块（与现有只读占位
                // 共存于同一 Section；规则 CRUD 经 Store 触发 Coordinator
                // 广播重绘，不重建任何 Runtime Session）。
                HighlightRulesEditor(store: appState.terminalHighlightCoordinator.highlightStore)
                    .padding(.top, 4)

                // MacSSH 1.1 Phase 7：命令历史设置（任务书 §32 / §33 / §40）。
                Divider()
                Toggle("sidebar_right.save_history", isOn: historyEnabledBinding)
                    .accessibilityIdentifier("settings.saveCommandHistory")
                Text(verbatim: L10n.string(
                    "sidebar_right.history_disclosure",
                    defaultValue: "This version records commands run through MacSSH.\nCommands entered manually in the terminal are not recorded.",
                    locale: locale
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    pendingClearHistory = true
                } label: {
                    Text("sidebar_right.clear_history")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.clearHistory")
            }

            Section("settings.section.appearance") {
                // MacSSH 1.1 Phase 8：外观模式 Picker（任务书 §29）。风格与上方
                // 「语言」Picker 完全一致：LabeledContent 行 + native menu Picker。
                // 行内值反映 requested mode（controller.mode），非 resolved
                // effectiveAppearance（任务书 §31：system + 系统深色 → 显示
                // 「跟随系统」而非「深色」）。选择即生效，无 Save / Apply / 重启。
                Picker("settings.mode", selection: $appearanceController.mode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.localizedOptionKey))
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.appearanceMode")
            }

            Section("settings.section.agent") {
                // MacSSH 1.1 Phase 10C-D：Provider Picker（任务书 §10）。
                // API Key 状态行只反映当前所选 provider 自己的凭据；
                // 切换经 switchAgentProvider 智能联动 model / baseURL 草稿
                // 并原子持久化。
                LabeledContent("agent.settings.provider") {
                    Picker("agent.settings.provider", selection: $agentProviderDraft) {
                        ForEach(
                            AgentProviderSettings.Provider.allCases,
                            id: \.self
                        ) { provider in
                            Text(LocalizedStringKey(provider.localizedNameKey))
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: agentProviderDraft) { _, newProvider in
                        switchAgentProvider(to: newProvider)
                    }
                    .accessibilityIdentifier("settings.agent.provider")
                }
                // Model：用户可输入账户可用的任意 model ID；空值保存时回退
                // provider defaults 集中默认值（任务书 §9：默认值不得散落 View）。
                LabeledContent("agent.settings.model") {
                    TextField(
                        "agent.settings.model.placeholder",
                        text: $agentModelDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("settings.agent.model")
                }
                // Base URL：默认 https://api.openai.com/v1，可改（仍为
                // OpenAI Responses endpoint 语义，任务书 §10）。
                LabeledContent("agent.settings.base_url") {
                    TextField(
                        "agent.settings.base_url.placeholder",
                        text: $agentBaseURLDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("settings.agent.baseURL")
                }
                if agentBaseURLInvalid {
                    Text("agent.settings.base_url_invalid")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.agent.baseURLInvalidHint")
                }
                Divider()
                // API Key：SecureField 草稿——保存后立即清空，绝不把 Keychain
                // 内容回填显示；状态行只区分「已配置 / 未配置」（任务书 §12：
                // 不显示 sk-… 任何形式的部分 Key）。
                LabeledContent("agent.settings.api_key") {
                    SecureField(
                        "agent.settings.api_key.placeholder",
                        text: $agentAPIKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("settings.agent.apiKey")
                }
                LabeledContent("agent.settings.api_key.status") {
                    if agentKeyConfigured {
                        Text("agent.settings.api_key.configured")
                    } else {
                        Text("agent.settings.api_key.not_configured")
                    }
                }
                HStack {
                    Button {
                        Task { await saveAgentConfiguration() }
                    } label: {
                        Text("agent.settings.api_key.save")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.agent.save")

                    Button(role: .destructive) {
                        Task { await deleteAgentAPIKey() }
                    } label: {
                        Text("agent.settings.api_key.delete")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!agentKeyConfigured)
                    .accessibilityIdentifier("settings.agent.deleteAPIKey")
                }
                Text("agent.settings.api_key.help")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("SSH") {
                LabeledContent("settings.connection_timeout") {
                    Text("settings.connection_timeout_value")
                }
                LabeledContent("KeepAlive") {
                    Text("common.on")
                }
            }

            Section("known_hosts.title") {
                if knownHosts.isEmpty {
                    Text("known_hosts.empty_message")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knownHosts) { knownHost in
                        KnownHostRow(
                            knownHost: knownHost,
                            locale: locale,
                            onForget: { pendingForgetID = knownHost.id }
                        )
                    }
                }
            }

            Section {
                Text("settings.read_only_note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // SwiftUI 的 LabeledContent 会缓存聚合后的 Accessibility Value。
        // 语言变化时只重建 Settings 展示子树，确保 VoiceOver 与可见文案同步；
        // AppState 持有的 Session / Transfer / Shell Runtime 不会因此重建。
        .id(appState.language)
        // NavigationSplitView 会缓存 LocalizedStringKey 形式的页面标题；显式使用
        // 当前 Locale 解析成 String，确保可见标题与 VoiceOver 在切换语言时同步刷新。
        .navigationTitle(
            L10n.string("settings.title", defaultValue: "Settings", locale: locale)
        )
        .accessibilityIdentifier("workspace.settings")
        .onAppear {
            // MacSSH 1.1 Phase 10C：载入非敏感配置草稿 + 刷新 Key 配置状态
            // （每次进入 Settings 页刷新；语言切换经 .id(language) 重建同样触发）。
            loadAgentSettingsDrafts()
            Task {
                await refreshAgentKeyConfigured()
            }
        }
        .alert("known_hosts.forget_title", isPresented: forgetBinding, presenting: pendingForgetID) { _ in
            Button("action.cancel", role: .cancel) {}
            Button("known_hosts.forget", role: .destructive) {
                forget()
            }
        } message: { _ in
            Text("known_hosts.forget_message")
        }
        .alert(
            "known_hosts.forget_failed_title",
            isPresented: $forgetError.mappedToBool,
            presenting: forgetError
        ) { _ in
            Button("action.ok", role: .cancel) {}
        } message: { _ in
            Text("known_hosts.forget_failed_message")
        }
        // MacSSH 1.1 Phase 7：清空命令历史确认。
        .alert(
            L10n.string("sidebar_right.clear_history_confirm",
                        defaultValue: "Clear all command history?",
                        locale: locale),
            isPresented: clearHistoryAlertBinding
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
        // MacSSH 1.1 Phase 10C：API Key 保存 / 删除失败提示（不静默失败）。
        .alert(
            L10n.string(
                "agent.settings.api_key.action_failed_title",
                defaultValue: "Keychain Error",
                locale: locale
            ),
            isPresented: $agentKeyActionFailed
        ) {
            Button("action.ok", role: .cancel) {}
        } message: {
            Text("agent.settings.api_key.action_failed_message")
        }
    }

    // MARK: - MacSSH 1.1 Phase 10C / 10C-D：AI Agent 设置（任务书 §12 / §13 / §10）

    /// 载入非敏感配置草稿（Provider / Model / Base URL；API Key 草稿
    /// 始终为空，绝不从 Keychain 回填，任务书 §12）。
    private func loadAgentSettingsDrafts() {
        let settings = AgentProviderSettings.load()
        agentProviderDraft = settings.provider
        agentModelDraft = settings.model
        agentBaseURLDraft = settings.baseURL.absoluteString
        agentBaseURLInvalid = false
    }

    /// 刷新 Key 配置状态：只读「当前所选 provider 是否已配置」，
    /// 不持有 Key 本体（Phase 10C-D 任务书 §10 / §11：状态随 provider
    /// 切换——各 provider 凭据相互独立）。
    private func refreshAgentKeyConfigured() async {
        do {
            let key = try await appState.agentCredentialService.readAPIKey(
                for: agentProviderDraft
            )
            agentKeyConfigured = !(key ?? "").isEmpty
        } catch {
            // Keychain 读取失败：保守视为未配置（与 provider 行为一致）。
            agentKeyConfigured = false
        }
    }

    /// Provider 切换（Phase 10C-D 任务书 §6 / §10）：
    /// 1. 智能切换草稿：model / baseURL 仍为旧 provider 默认值 → 跟随
    ///    新 provider 默认值；已自定义 → 保留（不得静默覆盖）；
    /// 2. 原子持久化 provider + 草稿（防止「provider 已切、baseURL 仍
    ///    指向另一服务商」把 Key 发往错误服务器——任务书 §7 P1 gate）；
    /// 3. 刷新该 provider 自己的 Key 状态并同步 Agent sidebar
    ///    （下一次 Send 生效；进行中的请求继续使用启动时快照）。
    private func switchAgentProvider(to newProvider: AgentProviderSettings.Provider) {
        let oldProvider = AgentProviderSettings.load().provider
        guard oldProvider != newProvider else { return }

        let baseURL = AgentProviderSettings.validatedBaseURL(from: agentBaseURLDraft)
            ?? oldProvider.defaultBaseURL
        let switched = AgentProviderSettings.switchingDefaults(
            from: oldProvider,
            to: newProvider,
            model: agentModelDraft,
            baseURL: baseURL
        )
        agentModelDraft = switched.model
        agentBaseURLDraft = switched.baseURL.absoluteString
        agentBaseURLInvalid = false
        AgentProviderSettings(
            provider: newProvider,
            model: switched.model,
            baseURL: switched.baseURL
        ).save()

        Task {
            await refreshAgentKeyConfigured()
            await appState.agentViewModel.refreshProviderConfiguration()
        }
    }

    /// 保存 Provider 配置（任务书 §13 生命周期）：
    /// 1. 校验 Base URL（非法 → 提示并中止，不写入）；
    /// 2. 非敏感配置持久化（UserDefaults，经 AgentProviderSettings.save）；
    /// 3. API Key 草稿非空时 upsert 进当前所选 provider 的 Keychain
    ///    account，成功后立即清空草稿；
    /// 4. 刷新 Key 状态与 AgentViewModel 的 providerState（下一次 Send 生效）。
    private func saveAgentConfiguration() async {
        let trimmedModel = agentModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = trimmedModel.isEmpty ? agentProviderDraft.defaultModel : trimmedModel
        let trimmedBaseURL = agentBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = AgentProviderSettings.validatedBaseURL(from: trimmedBaseURL) else {
            agentBaseURLInvalid = true
            return
        }
        agentBaseURLInvalid = false
        AgentProviderSettings(
            provider: agentProviderDraft,
            model: model,
            baseURL: baseURL
        ).save()

        let trimmedKey = agentAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            do {
                try await appState.agentCredentialService.upsertAPIKey(
                    trimmedKey,
                    for: agentProviderDraft
                )
            } catch {
                agentKeyActionFailed = true
                return
            }
            agentAPIKeyDraft = ""
        }
        agentModelDraft = model
        agentBaseURLDraft = baseURL.absoluteString
        await refreshAgentKeyConfigured()
        await appState.agentViewModel.refreshProviderConfiguration()
    }

    /// 删除当前所选 provider 的 API Key（任务书 §13：删除后 provider
    /// 进入未配置状态，Agent UI 显示需要配置；只删该 provider 自己的
    /// account，绝不波及其他 provider 凭据——Phase 10C-D 任务书 §11）。
    private func deleteAgentAPIKey() async {
        do {
            try await appState.agentCredentialService.deleteAPIKey(
                for: agentProviderDraft
            )
        } catch {
            agentKeyActionFailed = true
            return
        }
        await refreshAgentKeyConfigured()
        await appState.agentViewModel.refreshProviderConfiguration()
    }

    private func forget() {
        guard let id = pendingForgetID,
              let knownHost = knownHosts.first(where: { $0.id == id })
        else { return }
        modelContext.delete(knownHost)
        do {
            try modelContext.save()
            AppLogger.persistence.info("KnownHost forgotten via Settings")
        } catch {
            // 持久化失败：回滚以保持 KnownHost 状态一致，不得假装 Forget 成功。
            modelContext.rollback()
            AppLogger.persistence.error("Failed to forget KnownHost: \(String(describing: error))")
            forgetError = ForgetFailureInfo()
        }
        pendingForgetID = nil
    }

    private var forgetBinding: Binding<Bool> {
        Binding(
            get: { pendingForgetID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingForgetID = nil
                }
            }
        )
    }

    // MARK: - MacSSH 1.1 Phase 7：命令历史设置

    /// 「保存命令历史」开关绑定（任务书 §32）。关闭后 Execute 不写 history。
    private var historyEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.commandHistoryStore.historyEnabled },
            set: { enabled in
                appState.commandHistoryStore.historyEnabled = enabled
            }
        )
    }

    /// 清空历史确认 alert（任务书 §33 / Phase 7A 验收 §46：destructive confirmation）。
    private var clearHistoryAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingClearHistory },
            set: { isPresented in
                if !isPresented {
                    pendingClearHistory = false
                }
            }
        )
    }
}

/// Forget 持久化失败的 UI 提示载体（不携带底层技术错误，避免向用户暴露 SwiftData 内部错误）。
private struct ForgetFailureInfo: Identifiable {
    let id = UUID()
}

private extension Optional where Wrapped == ForgetFailureInfo {
    /// 用于驱动 `.alert(isPresented:)` 的 Bool 绑定。
    var mappedToBool: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}

/// 单条 KnownHost 展示行。
private struct KnownHostRow: View {
    let knownHost: KnownHost
    let locale: Locale
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(knownHost.hostname):\(knownHost.port)")
                        .font(.callout.weight(.semibold))
                    Text(knownHost.keyType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("known_hosts.forget", role: .destructive) {
                    onForget()
                }
                .buttonStyle(AppInteractiveButtonStyle(baseStyle: BorderlessButtonStyle()))
                .accessibilityIdentifier("knownHosts.forget")
            }

            Text(knownHost.fingerprint)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            Text(verbatim: L10n.format(
                "known_hosts.trusted_at",
                defaultValue: "Trusted %@",
                locale: locale,
                arguments: formattedDate
            ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// 日期格式显式采用当前 App Locale，语言切换后立即更新。
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: knownHost.updatedAt)
    }
}
