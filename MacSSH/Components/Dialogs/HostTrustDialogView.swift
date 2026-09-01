import SwiftUI

/// Phase 6 Host Trust 对话框（未知主机首次连接）。
///
/// Handshake 完成后显示服务器真实 Host Key 指纹，用户明确选择：
/// - Trust Once：仅本次连接信任，不写 KnownHost；
/// - Trust Always：写入 KnownHost 持久化，之后连接该 hostname+port 不再询问；
/// - Cancel：断开，绝不发送 Password 或私钥。
///
/// 已信任主机（Host Key 匹配）不进入此对话框，直接认证；
/// Host Key 变化由独立的 `HostKeyChangedDialogView` 处理。
struct HostTrustDialogView: View {
    /// 处于 awaitingHostTrust 阶段的连接镜像。
    let info: SSHConnectionInfo

    let onTrustOnce: () -> Void
    let onTrustAlways: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.regular) {
            HStack(spacing: AppTheme.Spacing.regular) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)

                Text("host_trust.title")
                    .font(.title2.bold())
            }
            .padding(.top, AppTheme.Spacing.regular)

            GroupBox {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.regular) {
                    fieldRow(label: "host.field.host", value: info.hostname)
                    fieldRow(label: "host.field.port", value: String(info.port))

                    if let hostKey = info.hostKey {
                        fieldRow(label: "host_trust.key_type", value: hostKey.keyTypeDisplayName)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("host_trust.fingerprint")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)

                            Text(hostKey.fingerprintSHA256)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(AppTheme.Spacing.compact)
            }

            Text("host_trust.message")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("host_trust.choice_explanation")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()

                Button("action.cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("hostTrust.cancel")

                Button("host_trust.trust_once") {
                    onTrustOnce()
                }
                .accessibilityIdentifier("hostTrust.trustOnce")

                Button("host_trust.trust_always") {
                    onTrustAlways()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("hostTrust.trustAlways")
            }
            .padding(.bottom, AppTheme.Spacing.regular)
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("accessibility.host_trust_dialog")
    }

    /// 字段名称来自 String Catalog；服务器值保持原样，不参与翻译。
    private func fieldRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}
