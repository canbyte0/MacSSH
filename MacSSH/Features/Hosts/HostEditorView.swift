import SwiftData
import SwiftUI

/// 使用原生 Form 创建或编辑 Host；只有点击 Save 后才修改 SwiftData。
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// nil 表示创建；非 nil 表示编辑现有持久化对象。
    private let host: Host?
    private let groups: [HostGroup]
    private let credentialService: CredentialService

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var authenticationType: AuthenticationType
    @State private var selectedGroupID: UUID?
    @State private var favorite: Bool
    @State private var notes: String
    @State private var password = ""
    @State private var removeStoredPassword = false
    @State private var isSaving = false
    @State private var validationMessage: String?
    @State private var saveErrorMessage: String?

    init(
        host: Host?,
        groups: [HostGroup],
        credentialService: CredentialService = .shared
    ) {
        self.host = host
        self.groups = groups
        self.credentialService = credentialService

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

                    if authenticationType == .password {
                        SecureField(host == nil ? "Password" : "New Password", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("hostEditor.password")
                            .onChange(of: password) { _, newValue in
                                // 输入新密码代表更新操作，应覆盖尚未保存的移除意图。
                                if !newValue.isEmpty {
                                    removeStoredPassword = false
                                }
                            }

                        if host?.credentialID != nil {
                            if removeStoredPassword {
                                Label("Password will be removed when you save.", systemImage: "trash")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            } else {
                                Label(
                                    "Password stored securely in macOS Keychain",
                                    systemImage: "checkmark.circle.fill"
                                )
                                .font(.footnote)
                                .foregroundStyle(.green)

                                Text("Leave blank to keep the saved password.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                Button("Remove Saved Password", role: .destructive) {
                                    password = ""
                                    removeStoredPassword = true
                                }
                                .accessibilityIdentifier("hostEditor.removePassword")
                            }
                        } else {
                            Text("Password will be stored securely in macOS Keychain.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Private Key selection and authentication are introduced in a later phase.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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

                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
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

    /// 先验证普通字段，再异步处理 Keychain 和 SwiftData 的协调保存。
    private func save() {
        guard !isSaving else {
            return
        }

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

        isSaving = true
        Task { @MainActor in
            await persist(
                name: trimmedName,
                hostname: trimmedHostname,
                port: validatedPort,
                username: trimmedUsername,
                group: selectedGroup,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Keychain 先完成，再保存引用；SwiftData 失败时用补偿操作恢复原 Secret 状态。
    @MainActor
    private func persist(
        name: String,
        hostname: String,
        port: Int,
        username: String,
        group: HostGroup?,
        notes: String
    ) async {
        var credentialRollback = CredentialRollback.none

        do {
            let targetHost = host ?? Host(
                name: name,
                hostname: hostname,
                port: port,
                username: username,
                authenticationType: authenticationType,
                group: group,
                favorite: favorite,
                notes: notes
            )

            if host != nil {
                targetHost.name = name
                targetHost.hostname = hostname
                targetHost.port = port
                targetHost.username = username
                targetHost.authenticationType = authenticationType
                targetHost.group = group
                targetHost.favorite = favorite
                targetHost.notes = notes
                targetHost.updatedAt = .now
            }

            credentialRollback = try await applyPasswordMutation(to: targetHost)

            if host == nil {
                modelContext.insert(targetHost)
            }

            do {
                try modelContext.save()
            } catch {
                throw HostEditorSaveError.persistenceFailed
            }

            password = ""
            AppLogger.persistence.info("Host metadata saved")
            dismiss()
        } catch {
            // 回滚 Host 字段，并尽力恢复 Keychain 在本次 Save 前的状态。
            modelContext.rollback()
            let rollbackSucceeded = await rollbackCredentialMutation(credentialRollback)
            saveErrorMessage = rollbackSucceeded
                ? userFacingMessage(for: error)
                : "The Host was not saved and macOS Keychain cleanup also failed. Please retry."
            AppLogger.persistence.error("Failed to save Host metadata")
        }

        isSaving = false
    }

    /// 空密码且未点击移除表示“未修改”；绝不因只编辑普通字段而覆盖已有 Password。
    private func applyPasswordMutation(to targetHost: Host) async throws -> CredentialRollback {
        guard authenticationType == .password else {
            return .none
        }

        if removeStoredPassword, let credentialID = targetHost.credentialID {
            let previousPassword = try await readPasswordIfPresent(credentialID: credentialID)
            if previousPassword != nil {
                try await credentialService.deletePassword(credentialID: credentialID)
            }
            targetHost.credentialID = nil
            return previousPassword.map { .restore(credentialID, $0) } ?? .none
        }

        guard !password.isEmpty else {
            return .none
        }

        if let credentialID = targetHost.credentialID {
            let previousPassword = try await readPasswordIfPresent(credentialID: credentialID)
            guard let previousPassword else {
                try await credentialService.savePassword(password, credentialID: credentialID)
                return .deleteCreated(credentialID)
            }

            try await credentialService.updatePassword(password, credentialID: credentialID)
            return .restore(credentialID, previousPassword)
        }

        let credentialID = UUID()
        try await credentialService.savePassword(password, credentialID: credentialID)
        targetHost.credentialID = credentialID
        return .deleteCreated(credentialID)
    }

    /// itemNotFound 表示引用尚无 Secret，可安全按新凭据处理；其他错误必须上抛。
    private func readPasswordIfPresent(credentialID: UUID) async throws -> String? {
        do {
            return try await credentialService.readPassword(credentialID: credentialID)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    /// SwiftData 保存失败后执行 Keychain 补偿，避免产生孤立或意外覆盖的 Secret。
    private func rollbackCredentialMutation(_ rollback: CredentialRollback) async -> Bool {
        do {
            switch rollback {
            case .none:
                return true
            case let .deleteCreated(credentialID):
                do {
                    try await credentialService.deletePassword(credentialID: credentialID)
                } catch KeychainError.itemNotFound {
                    return true
                }
            case let .restore(credentialID, previousPassword):
                try await credentialService.upsertPassword(
                    previousPassword,
                    credentialID: credentialID
                )
            }
            return true
        } catch {
            AppLogger.security.error("Credential rollback failed")
            return false
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let keychainError = error as? KeychainError {
            return keychainError.localizedDescription
        }
        return "SwiftData could not save the Host. Please try again."
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

/// 仅在一次保存事务内短暂保留补偿信息，不写入 SwiftData 或日志。
private enum CredentialRollback {
    case none
    case deleteCreated(UUID)
    case restore(UUID, String)
}

private enum HostEditorSaveError: Error {
    case persistenceFailed
}
