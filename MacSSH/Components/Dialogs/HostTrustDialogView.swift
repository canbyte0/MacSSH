import SwiftUI

/// Phase 5 Host Trust 对话框。
///
/// Handshake 完成后显示服务器真实 Host Key 指纹，用户明确选择
/// “仅本次信任”后才允许发送 Password Authentication。
/// 信任只对当前连接有效；不写入 SwiftData（KnownHost 属于 Phase 6）。
struct HostTrustDialogView: View {
    /// 处于 awaitingHostTrust 阶段的连接镜像。
    let info: SSHConnectionInfo

    let onTrustOnce: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.regular) {
            HStack(spacing: AppTheme.Spacing.regular) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)

                Text("无法验证服务器身份")
                    .font(.title2.bold())
            }
            .padding(.top, AppTheme.Spacing.regular)

            GroupBox {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.regular) {
                    fieldRow(label: "Host", value: info.hostname)
                    fieldRow(label: "Port", value: String(info.port))

                    if let hostKey = info.hostKey {
                        fieldRow(label: "Key Type", value: hostKey.keyTypeDisplayName)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fingerprint")
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

            Text(
                "该服务器身份尚未被信任。请核对 Fingerprint 与服务器管理员提供的信息一致后继续。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("信任仅对本次连接有效，不会被保存。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("hostTrust.cancel")

                Button("Trust Once") {
                    onTrustOnce()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("hostTrust.trustOnce")
            }
            .padding(.bottom, AppTheme.Spacing.regular)
        }
        .padding(.horizontal, AppTheme.Spacing.regular)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Host Trust Dialog")
    }

    private func fieldRow(label: String, value: String) -> some View {
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
