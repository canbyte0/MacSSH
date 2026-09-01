import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 使用原生 Form 创建或编辑 Host；只有点击 Save 后才修改 SwiftData。
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

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
    @State private var privateKeyPath: String?
    @State private var passphrase = ""
    @State private var removeStoredPassphrase = false
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
        _privateKeyPath = State(initialValue: host?.privateKeyPath)
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack {
                Text(
                    host == nil
                        ? LocalizedStringKey("hosts.add")
                        : LocalizedStringKey("hosts.edit")
                )
                    .font(.title2.bold())

                Spacer()
            }
            .padding(AppTheme.Spacing.regular)

            Divider()

            Form {
                Section("host_editor.section.host") {
                    TextField("host_editor.name", text: $name)
                        .accessibilityIdentifier("hostEditor.name")

                    TextField("host_editor.hostname", text: $hostname)
                        .textContentType(.URL)
                        .accessibilityIdentifier("hostEditor.hostname")

                    TextField("host_editor.port", text: $port)
                        .accessibilityIdentifier("hostEditor.port")

                    TextField("host_editor.username", text: $username)
                        .accessibilityIdentifier("hostEditor.username")
                }

                Section("host_editor.section.authentication") {
                    Picker("host_editor.authentication", selection: $authenticationType) {
                        ForEach(AuthenticationType.allCases) { type in
                            Text(type.titleKey).tag(type)
                        }
                    }
                    .accessibilityIdentifier("hostEditor.authentication")

                    if authenticationType == .password {
                        passwordSection
                    } else {
                        privateKeySection
                    }
                }

                Section("host_editor.section.organization") {
                    Picker("host_editor.group", selection: $selectedGroupID) {
                        Text("common.none").tag(UUID?.none)

                        ForEach(groups) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                    .accessibilityIdentifier("hostEditor.group")

                    Toggle("hosts.favorite", isOn: $favorite)
                        .accessibilityIdentifier("hostEditor.favorite")
                }

                Section("host_editor.notes") {
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

                Button("action.cancel", role: .cancel) {
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
                        Text("action.save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .accessibilityIdentifier("hostEditor.save")
            }
            .padding(AppTheme.Spacing.regular)
        }
        .frame(width: 560, height: 660)
        .alert("host_editor.save_failed_title", isPresented: saveErrorBinding) {
            Button("action.ok", role: .cancel) {}
        } message: {
            Text(verbatim: saveErrorMessage ?? L10n.string(
                "host_editor.save_failed_message",
                defaultValue: "The Host could not be saved.",
                locale: locale
            ))
        }
    }

    // MARK: - Password 认证区

    @ViewBuilder
    private var passwordSection: some View {
        SecureField(
            host == nil
                ? L10n.string(
                    "host_editor.password",
                    defaultValue: "Password",
                    locale: locale
                )
                : L10n.string(
                    "host_editor.new_password",
                    defaultValue: "New Password",
                    locale: locale
                ),
            text: $password
        )
            .textContentType(.password)
            .accessibilityIdentifier("hostEditor.password")
            .onChange(of: password) { _, newValue in
                if !newValue.isEmpty {
                    removeStoredPassword = false
                }
            }

        if host?.credentialID != nil {
            if removeStoredPassword {
                Label("host_editor.password_remove_on_save", systemImage: "trash")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Label(
                    "host_editor.password_stored",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.green)

                Text("host_editor.password_keep_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("host_editor.remove_saved_password", role: .destructive) {
                    password = ""
                    removeStoredPassword = true
                }
                .accessibilityIdentifier("hostEditor.removePassword")
            }
        } else {
            Text("host_editor.password_storage_hint")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Private Key 认证区（Phase 6）

    /// Private Key Host 的保存前置校验：必须已选择真实私钥文件路径。
    ///
    /// `nil`（未选择）、空字符串、纯空白路径都无效；
    /// 与 SSH 连接层的存在性校验（`privateKeyFileNotFound`）分层，这里不做密钥格式解析。
    static func hasValidPrivateKeyPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var privateKeySection: some View {
        // Private Key File（文件本身，非 Secret）。
        HStack {
            Text(Self.hasValidPrivateKeyPath(privateKeyPath)
                ? (privateKeyPath ?? "")
                : L10n.string(
                    "host_editor.no_file_chosen",
                    defaultValue: "No file chosen",
                    locale: locale
                ))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Self.hasValidPrivateKeyPath(privateKeyPath) ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("action.choose") {
                choosePrivateKeyFile()
            }
            .accessibilityIdentifier("hostEditor.choosePrivateKey")

            if Self.hasValidPrivateKeyPath(privateKeyPath) {
                Button("action.clear") {
                    privateKeyPath = nil
                }
                .accessibilityIdentifier("hostEditor.clearPrivateKey")
            }
        }

        Text("host_editor.private_key_hint")
            .font(.footnote)
            .foregroundStyle(.secondary)

        // Passphrase（Secret；与 Password 使用不同 Keychain service）。
        SecureField(
            host?.privateKeyID == nil
                ? L10n.string(
                    "host_editor.passphrase",
                    defaultValue: "Passphrase",
                    locale: locale
                )
                : L10n.string(
                    "host_editor.new_passphrase",
                    defaultValue: "New Passphrase",
                    locale: locale
                ),
            text: $passphrase
        )
            .textContentType(.password)
            .accessibilityIdentifier("hostEditor.passphrase")
            .onChange(of: passphrase) { _, newValue in
                if !newValue.isEmpty {
                    removeStoredPassphrase = false
                }
            }

        if host?.privateKeyID != nil {
            if removeStoredPassphrase {
                Label("host_editor.passphrase_remove_on_save", systemImage: "trash")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Label(
                    "host_editor.passphrase_stored",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.green)

                Text("host_editor.passphrase_keep_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("host_editor.remove_saved_passphrase", role: .destructive) {
                    passphrase = ""
                    removeStoredPassphrase = true
                }
                .accessibilityIdentifier("hostEditor.removePassphrase")
            }
        } else {
            Text("host_editor.passphrase_optional_hint")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 原生 NSOpenPanel 选择私钥文件（仅文件；不使用 Web 文件选择器）。
    private func choosePrivateKeyFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.string(
            "host_editor.choose_private_key_title",
            defaultValue: "Choose Private Key File",
            locale: locale
        )
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        privateKeyPath = url.path
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
            validationMessage = L10n.string(
                "validation.name_required",
                defaultValue: "Name is required.",
                locale: locale
            )
            return
        }

        guard !trimmedHostname.isEmpty else {
            validationMessage = L10n.string(
                "validation.hostname_required",
                defaultValue: "Hostname is required.",
                locale: locale
            )
            return
        }

        guard !trimmedUsername.isEmpty else {
            validationMessage = L10n.string(
                "validation.username_required",
                defaultValue: "Username is required.",
                locale: locale
            )
            return
        }

        guard let validatedPort = Int(port), (1...65_535).contains(validatedPort) else {
            validationMessage = L10n.string(
                "validation.port_range",
                defaultValue: "Port must be between 1 and 65535.",
                locale: locale
            )
            return
        }

        // Private Key Host 必须已选择私钥文件：nil / 空 / 纯空白路径都阻止保存，
        // 不生成已知无法连接的 Host（连接时仍会再次校验文件存在性与可读性）。
        if authenticationType == .privateKey,
           !Self.hasValidPrivateKeyPath(privateKeyPath)
        {
            validationMessage = L10n.string(
                "validation.private_key_required",
                defaultValue: "Choose a private key file.",
                locale: locale
            )
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
        var passwordRollback: CredentialRollback = .none
        var passphraseRollback: CredentialRollback = .none

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

            // 私钥文件路径（文件，非 Secret）始终随表单写入。
            targetHost.privateKeyPath = privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines)

            // 仅处理当前认证类型对应的 Secret；另一类凭据保持不动（切换不立即删除）。
            passwordRollback = try await applyPasswordMutation(to: targetHost)
            passphraseRollback = try await applyPassphraseMutation(to: targetHost)

            if host == nil {
                modelContext.insert(targetHost)
            }

            do {
                try modelContext.save()
            } catch {
                throw HostEditorSaveError.persistenceFailed
            }

            password = ""
            passphrase = ""
            AppLogger.persistence.info("Host metadata saved")
            dismiss()
        } catch {
            // 回滚 Host 字段，并尽力恢复 Keychain 在本次 Save 前的状态。
            modelContext.rollback()
            let passwordRestored = await rollbackCredentialMutation(passwordRollback)
            let passphraseRestored = await rollbackCredentialMutation(passphraseRollback)
            let rollbackSucceeded = passwordRestored && passphraseRestored
            saveErrorMessage = rollbackSucceeded
                ? userFacingMessage(for: error)
                : L10n.string(
                    "host_editor.keychain_cleanup_failed",
                    defaultValue: "The Host was not saved and macOS Keychain cleanup also failed. Please retry.",
                    locale: locale
                )
            AppLogger.persistence.error("Failed to save Host metadata")
        }

        isSaving = false
    }

    // MARK: - Password 变更

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
            return previousPassword.map { .restore(credentialID, $0, kind: .password) } ?? .none
        }

        guard !password.isEmpty else {
            return .none
        }

        if let credentialID = targetHost.credentialID {
            let previousPassword = try await readPasswordIfPresent(credentialID: credentialID)
            guard let previousPassword else {
                try await credentialService.savePassword(password, credentialID: credentialID)
                return .deleteCreated(credentialID, kind: .password)
            }

            try await credentialService.updatePassword(password, credentialID: credentialID)
            return .restore(credentialID, previousPassword, kind: .password)
        }

        let credentialID = UUID()
        try await credentialService.savePassword(password, credentialID: credentialID)
        targetHost.credentialID = credentialID
        return .deleteCreated(credentialID, kind: .password)
    }

    // MARK: - Private Key Passphrase 变更（Phase 6）

    /// 与 Password 变更同构；空 Passphrase 且未点击移除表示“未修改”。
    /// 无 Passphrase 私钥：privateKeyID 为 nil 且不输入 Passphrase 即合法。
    private func applyPassphraseMutation(to targetHost: Host) async throws -> CredentialRollback {
        guard authenticationType == .privateKey else {
            return .none
        }

        if removeStoredPassphrase, let privateKeyID = targetHost.privateKeyID {
            let previous = try await readPassphraseIfPresent(privateKeyID: privateKeyID)
            if previous != nil {
                try await credentialService.deletePrivateKeyPassphrase(privateKeyID: privateKeyID)
            }
            targetHost.privateKeyID = nil
            return previous.map { .restore(privateKeyID, $0, kind: .passphrase) } ?? .none
        }

        guard !passphrase.isEmpty else {
            return .none
        }

        if let privateKeyID = targetHost.privateKeyID {
            let previous = try await readPassphraseIfPresent(privateKeyID: privateKeyID)
            guard let previous else {
                try await credentialService.savePrivateKeyPassphrase(passphrase, privateKeyID: privateKeyID)
                return .deleteCreated(privateKeyID, kind: .passphrase)
            }

            try await credentialService.updatePrivateKeyPassphrase(passphrase, privateKeyID: privateKeyID)
            return .restore(privateKeyID, previous, kind: .passphrase)
        }

        let privateKeyID = UUID()
        try await credentialService.savePrivateKeyPassphrase(passphrase, privateKeyID: privateKeyID)
        targetHost.privateKeyID = privateKeyID
        return .deleteCreated(privateKeyID, kind: .passphrase)
    }

    /// itemNotFound 表示引用尚无 Secret，可安全按新凭据处理；其他错误必须上抛。
    private func readPasswordIfPresent(credentialID: UUID) async throws -> String? {
        do {
            return try await credentialService.readPassword(credentialID: credentialID)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    private func readPassphraseIfPresent(privateKeyID: UUID) async throws -> String? {
        do {
            return try await credentialService.readPrivateKeyPassphrase(privateKeyID: privateKeyID)
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
            case let .deleteCreated(id, kind):
                switch kind {
                case .password:
                    do {
                        try await credentialService.deletePassword(credentialID: id)
                    } catch KeychainError.itemNotFound {
                        return true
                    }
                case .passphrase:
                    do {
                        try await credentialService.deletePrivateKeyPassphrase(privateKeyID: id)
                    } catch KeychainError.itemNotFound {
                        return true
                    }
                }
                return true
            case let .restore(id, previous, kind):
                switch kind {
                case .password:
                    try await credentialService.upsertPassword(previous, credentialID: id)
                case .passphrase:
                    try await credentialService.upsertPrivateKeyPassphrase(previous, privateKeyID: id)
                }
                return true
            }
        } catch {
            AppLogger.security.error("Credential rollback failed")
            return false
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let keychainError = error as? KeychainError {
            return keychainError.localizedDescription(locale: locale)
        }
        return L10n.string(
            "host_editor.swiftdata_save_failed",
            defaultValue: "SwiftData could not save the Host. Please try again.",
            locale: locale
        )
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
    case deleteCreated(UUID, kind: Kind)
    case restore(UUID, String, kind: Kind)

    enum Kind {
        case password
        case passphrase
    }
}

private enum HostEditorSaveError: Error {
    case persistenceFailed
}
