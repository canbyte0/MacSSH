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
