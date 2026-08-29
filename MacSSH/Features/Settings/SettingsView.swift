import SwiftData
import SwiftUI

/// Settings 页面。
///
/// Phase 6 起在 SSH 区新增可交互的 Known Hosts 管理：
/// 列出已持久化的服务器身份（hostname + port + Key Type + Fingerprint + 信任时间），
/// 支持 Forget（删除 KnownHost，下次连接重新出现未知主机对话框）。
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(
        sort: [SortDescriptor(\KnownHost.hostname), SortDescriptor(\KnownHost.port)]
    )
    private var knownHosts: [KnownHost]

    @State private var pendingForgetID: KnownHost.ID?

    /// Forget 持久化失败时携带的错误信息，驱动错误 Alert。
    @State private var forgetError: ForgetFailureInfo?

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Launch Behavior", value: "Open Main Window")
                LabeledContent("Confirm Before Closing SSH", value: "On")
            }

            Section("Terminal") {
                LabeledContent("Font", value: "System Monospaced")
                LabeledContent("Font Size", value: "13 pt")
                LabeledContent("Scrollback", value: "10,000 lines")
            }

            Section("Appearance") {
                LabeledContent("Mode", value: "System")
            }

            Section("SSH") {
                LabeledContent("Connection Timeout", value: "10 seconds")
                LabeledContent("KeepAlive", value: "On")
            }

            Section("Known Hosts") {
                if knownHosts.isEmpty {
                    Text("No trusted hosts yet. The first connection to a server will ask you to verify its host key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knownHosts) { knownHost in
                        KnownHostRow(knownHost: knownHost, onForget: { pendingForgetID = knownHost.id })
                    }
                }
            }

            Section {
                Text("General/Terminal/Appearance/SSH values are read-only mock data and are not persisted. Known Hosts are persisted in SwiftData.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .accessibilityIdentifier("workspace.settings")
        .alert("Forget Trusted Host?", isPresented: forgetBinding, presenting: pendingForgetID) { _ in
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                forget()
            }
        } message: { _ in
            Text("The next connection to this host will show the Unknown Host dialog again.")
        }
        .alert(
            "无法移除受信任的主机",
            isPresented: $forgetError.mappedToBool,
            presenting: forgetError
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { _ in
            Text("Known Host 更改未能保存，请稍后重试。")
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
    let onForget: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

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

                Button("Forget", role: .destructive) {
                    onForget()
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("knownHosts.forget")
            }

            Text(knownHost.fingerprint)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            Text("Trusted \(Self.dateFormatter.string(from: knownHost.updatedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
