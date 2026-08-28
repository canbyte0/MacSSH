import SwiftData
import SwiftUI

/// 使用原生 Form 创建或编辑 Host；只有点击 Save 后才修改 SwiftData。
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// nil 表示创建；非 nil 表示编辑现有持久化对象。
    private let host: Host?
    private let groups: [HostGroup]

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var authenticationType: AuthenticationType
    @State private var selectedGroupID: UUID?
    @State private var favorite: Bool
    @State private var notes: String
    @State private var validationMessage: String?
    @State private var saveErrorMessage: String?

    init(host: Host?, groups: [HostGroup]) {
        self.host = host
        self.groups = groups

        // 表单先编辑本地状态，Cancel 不会污染持久化对象。
        _name = State(initialValue: host?.name ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? 22))
        _username = State(initialValue: host?.username ?? "")
        _authenticationType = State(initialValue: host?.authenticationType ?? .password)
        _selectedGroupID = State(initialValue: host?.group?.id)
        _favorite = State(initialValue: host?.favorite ?? false)
        _notes = State(initialValue: host?.notes ?? "")
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack {
                Text(host == nil ? "Add Host" : "Edit Host")
                    .font(.title2.bold())

                Spacer()
            }
            .padding(AppTheme.Spacing.regular)

            Divider()

            Form {
                Section("Host") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("hostEditor.name")

                    TextField("Hostname", text: $hostname)
                        .textContentType(.URL)
                        .accessibilityIdentifier("hostEditor.hostname")

                    TextField("Port", text: $port)
                        .accessibilityIdentifier("hostEditor.port")

                    TextField("Username", text: $username)
                        .accessibilityIdentifier("hostEditor.username")
                }

                Section("Authentication") {
                    Picker("Authentication", selection: $authenticationType) {
                        ForEach(AuthenticationType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .accessibilityIdentifier("hostEditor.authentication")

                    Text("Credentials will be configured in Phase 4.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Organization") {
                    Picker("Group", selection: $selectedGroupID) {
                        Text("None").tag(UUID?.none)

                        ForEach(groups) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                    .accessibilityIdentifier("hostEditor.group")

                    Toggle("Favorite", isOn: $favorite)
                        .accessibilityIdentifier("hostEditor.favorite")
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(minHeight: 80)
                        .accessibilityIdentifier("hostEditor.notes")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("hostEditor.validation")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("hostEditor.save")
            }
            .padding(AppTheme.Spacing.regular)
        }
        .frame(width: 560, height: 620)
        .alert("Unable to Save Host", isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "The Host could not be saved.")
        }
    }

    /// 先验证普通字段，再一次性插入或更新并显式保存。
    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationMessage = "Name is required."
            return
        }

        guard !trimmedHostname.isEmpty else {
            validationMessage = "Hostname is required."
            return
        }

        guard !trimmedUsername.isEmpty else {
            validationMessage = "Username is required."
            return
        }

        guard let validatedPort = Int(port), (1...65_535).contains(validatedPort) else {
            validationMessage = "Port must be between 1 and 65535."
            return
        }

        validationMessage = nil
        let selectedGroup = groups.first { $0.id == selectedGroupID }

        if let host {
            host.name = trimmedName
            host.hostname = trimmedHostname
            host.port = validatedPort
            host.username = trimmedUsername
            host.authenticationType = authenticationType
            host.group = selectedGroup
            host.favorite = favorite
            host.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            host.updatedAt = .now
        } else {
            let newHost = Host(
                name: trimmedName,
                hostname: trimmedHostname,
                port: validatedPort,
                username: trimmedUsername,
                authenticationType: authenticationType,
                group: selectedGroup,
                favorite: favorite,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            modelContext.insert(newHost)
        }

        do {
            try modelContext.save()
            AppLogger.persistence.info("Host metadata saved")
            dismiss()
        } catch {
            // 回滚本次表单修改，不把错误中的潜在用户数据写入日志。
            modelContext.rollback()
            saveErrorMessage = "SwiftData could not save the Host. Please try again."
            AppLogger.persistence.error("Failed to save Host metadata")
        }
    }

    /// 将可空错误文本桥接成 SwiftUI Alert 的布尔绑定。
    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    saveErrorMessage = nil
                }
            }
        )
    }
}
