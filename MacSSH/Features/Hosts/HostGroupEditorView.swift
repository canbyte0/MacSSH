import SwiftData
import SwiftUI

/// 创建或重命名 HostGroup 的最小原生 Sheet。
struct HostGroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    /// nil 表示新建分组；非 nil 表示重命名。
    private let group: HostGroup?

    @State private var name: String
    @State private var validationMessage: String?
    @State private var saveErrorMessage: String?

    init(group: HostGroup?) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack {
                Text(
                    group == nil
                        ? LocalizedStringKey("groups.new")
                        : LocalizedStringKey("groups.rename")
                )
                    .font(.title2.bold())

                Spacer()
            }
            .padding(AppTheme.Spacing.regular)

            Divider()

            Form {
                TextField("host_editor.name", text: $name)
                    .accessibilityIdentifier("groupEditor.name")

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
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

                Button("action.save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("groupEditor.save")
            }
            .padding(AppTheme.Spacing.regular)
        }
        .frame(width: 420, height: 240)
        .alert("groups.save_failed_title", isPresented: saveErrorBinding) {
            Button("action.ok", role: .cancel) {}
        } message: {
            Text(verbatim: saveErrorMessage ?? L10n.string(
                "groups.save_failed_message",
                defaultValue: "The Group could not be saved.",
                locale: locale
            ))
        }
    }

    /// 组名在保存前去除首尾空白，并依赖模型唯一约束阻止重复名称。
    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationMessage = L10n.string(
                "validation.name_required",
                defaultValue: "Name is required.",
                locale: locale
            )
            return
        }

        validationMessage = nil

        if let group {
            group.name = trimmedName
            group.updatedAt = .now
        } else {
            modelContext.insert(HostGroup(name: trimmedName))
        }

        do {
            try modelContext.save()
            AppLogger.persistence.info("Host group saved")
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = L10n.string(
                "groups.duplicate_name",
                defaultValue: "A Group with this name may already exist.",
                locale: locale
            )
            AppLogger.persistence.error("Failed to save Host group")
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
