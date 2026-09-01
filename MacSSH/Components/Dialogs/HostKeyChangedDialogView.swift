import SwiftUI

/// Phase 6 Host Key Changed 警告对话框。
///
/// 当已保存的 KnownHost 与当前服务器 Host Key 不一致时显示。
/// 这是硬性阻断：在用户明确替换之前，绝不发送 Password 或私钥。
///
/// 两步确认：
/// 1. 警告（Cancel / Replace Trusted Key）；
/// 2. 选择 Replace 后弹出二次危险确认（Cancel / Confirm Replace），
///    明确告知将删除旧 Host Key 并保存新身份。
///
/// 不提供模糊的 “Continue Anyway”。Cancel 由调用方转为 `.hostKeyChanged` 失败。
struct HostKeyChangedDialogView: View {
    /// 处于 awaitingHostTrust 阶段的连接镜像。
    let info: SSHConnectionInfo

    /// 旧（已保存）Host Key 指纹与算法，用于对比展示。
    let storedFingerprint: String
    let storedKeyType: String

    let onReplace: () -> Void
    let onCancel: () -> Void

    @State private var showingSecondConfirmation = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.regular) {
            HStack(spacing: AppTheme.Spacing.regular) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)

                Text("host_key_changed.title")
                    .font(.title2.bold())
            }
            .padding(.top, AppTheme.Spacing.regular)

            GroupBox {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.regular) {
                    fieldRow(label: "host.field.host", value: info.hostname)
                    fieldRow(label: "host.field.port", value: String(info.port))

                    if let hostKey = info.hostKey {
                        fingerprintRow(
                            label: "host_key_changed.old_fingerprint",
                            fingerprint: storedFingerprint,
                            keyType: storedKeyType
                        )
                        fingerprintRow(
                            label: "host_key_changed.new_fingerprint",
                            fingerprint: hostKey.fingerprintSHA256,
                            keyType: hostKey.keyTypeDisplayName
                        )
                    }
                }
                .padding(AppTheme.Spacing.compact)
            }

            Text("host_key_changed.message")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()

                Button("action.cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("hostKeyChanged.cancel")

                Button("host_key_changed.replace", role: .destructive) {
                    showingSecondConfirmation = true
                }
                .accessibilityIdentifier("hostKeyChanged.replace")
            }
            .padding(.bottom, AppTheme.Spacing.regular)
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("accessibility.host_key_changed_dialog")
        // 二次危险确认：不一次点击就静默替换。
        .alert("host_key_changed.confirm_title", isPresented: $showingSecondConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("host_key_changed.confirm_replace", role: .destructive) {
                onReplace()
            }
            .accessibilityIdentifier("hostKeyChanged.confirmReplace")
        } message: {
            Text("host_key_changed.confirm_message")
        }
    }

    /// 字段名称来自 String Catalog；服务器值保持原样，不参与翻译。
    private func fieldRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    /// 指纹字段使用本地化标签，算法名与指纹保持协议原值。
    private func fingerprintRow(
        label: LocalizedStringKey,
        fingerprint: String,
        keyType: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("(\(keyType))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(fingerprint)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
