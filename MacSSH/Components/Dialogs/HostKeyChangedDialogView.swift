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

                Text("SSH 主机密钥已变更")
                    .font(.title2.bold())
            }
            .padding(.top, AppTheme.Spacing.regular)

            GroupBox {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.regular) {
                    fieldRow(label: "Host", value: info.hostname)
                    fieldRow(label: "Port", value: String(info.port))

                    if let hostKey = info.hostKey {
                        fingerprintRow(
                            label: "旧 Fingerprint",
                            fingerprint: storedFingerprint,
                            keyType: storedKeyType
                        )
                        fingerprintRow(
                            label: "新 Fingerprint",
                            fingerprint: hostKey.fingerprintSHA256,
                            keyType: hostKey.keyTypeDisplayName
                        )
                    }
                }
                .padding(AppTheme.Spacing.compact)
            }

            Text(
                "服务器身份信息与之前保存的信息不同。这可能是服务器重新安装，也可能表示存在中间人攻击。在您决定之前，认证已被阻断。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("hostKeyChanged.cancel")

                Button("Replace Trusted Key", role: .destructive) {
                    showingSecondConfirmation = true
                }
                .accessibilityIdentifier("hostKeyChanged.replace")
            }
            .padding(.bottom, AppTheme.Spacing.regular)
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Host Key Changed Dialog")
        // 二次危险确认：不一次点击就静默替换。
        .alert("Replace Trusted Host Key?", isPresented: $showingSecondConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Confirm Replace", role: .destructive) {
                onReplace()
            }
            .accessibilityIdentifier("hostKeyChanged.confirmReplace")
        } message: {
            Text("确认后将删除之前信任的 SSH Host Key，并将当前服务器密钥作为新的可信身份保存。仅在确信变更为合法时执行。")
        }
    }

    private func fieldRow(label: String, value: String) -> some View {
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

    private func fingerprintRow(label: String, fingerprint: String, keyType: String) -> some View {
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
