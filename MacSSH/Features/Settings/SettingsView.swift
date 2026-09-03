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

    var body: some View {
        @Bindable var appState = appState

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
                LabeledContent("settings.font_size") {
                    Text("settings.font_size_value")
                }
                LabeledContent("settings.scrollback") {
                    Text("settings.scrollback_value")
                }
            }

            Section("settings.section.appearance") {
                LabeledContent("settings.mode") {
                    Text("settings.system_mode")
                }
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
