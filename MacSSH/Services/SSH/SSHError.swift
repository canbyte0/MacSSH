import Foundation

/// SSH 连接的业务级错误。
///
/// 只携带用户可以理解的信息；libssh2 原始错误码仅作为开发诊断保留，
/// 任何情况下都不包含 Password、Passphrase 或其他 Secret。
enum SSHError: Error, Equatable, Sendable {
    /// Host 记录缺少有效的主机名或用户名。
    case invalidHost
    /// DNS 解析失败或主机名不存在。
    case dnsResolutionFailed
    /// 连接超时（TCP / Handshake / Authentication 任一阶段）。
    case connectionTimeout
    /// 目标端口没有服务监听，连接被拒绝。
    case connectionRefused
    /// 底层 socket 错误（errno 仅作诊断）。
    case socketError(errno: Int32)
    /// libssh2 session 创建失败。
    case sessionInitializationFailed
    /// SSH handshake 失败（协议不兼容或传输错误）。
    case handshakeFailed(libssh2Code: Int)
    /// Handshake 后无法取得服务器 Host Key。
    case hostKeyUnavailable
    /// 用户在身份确认对话框选择了 Cancel。
    case hostTrustRejected
    /// 服务器 Host Key 与已信任的记录不一致（中间人攻击或服务器重装）。
    /// 这是硬性阻断：在用户明确替换之前，绝不发送任何 Password 或私钥。
    case hostKeyChanged
    /// 信任决策（Trust Always / Replace Trusted Key）的 KnownHost 持久化失败。
    /// 安全决策必须成功落盘才允许继续认证；此错误表示连接已在认证前中止，
    /// 未发送任何 Password 或私钥。
    case knownHostPersistenceFailed
    /// Keychain 中找不到该 Host 保存的 Password。
    case credentialNotFound
    /// 服务器不支持 Password Authentication。
    case passwordAuthenticationUnsupported
    /// 用户名或密码被服务器拒绝。
    case authenticationFailed
    /// Private Key Host 未配置私钥文件路径。
    case privateKeyPathMissing
    /// 配置的私钥文件不存在。
    case privateKeyFileNotFound
    /// 配置的私钥文件存在但无法读取（权限不足等）。
    case privateKeyFileUnreadable
    /// 私钥需要 Passphrase 但未配置，或 Keychain 中找不到对应 Passphrase。
    case privateKeyPassphraseRequired
    /// Passphrase 错误，无法解密私钥。
    case privateKeyPassphraseIncorrect
    /// 服务器不支持 publickey 认证方式。
    case publicKeyAuthenticationUnsupported
    /// 私钥认证被服务器拒绝（密钥不在 authorized_keys）或认证失败。
    case privateKeyAuthenticationFailed
    /// 已建立的连接意外中断。
    case connectionLost
    /// 用户在连接过程中主动取消。
    case cancelled
    /// 断开清理阶段失败。
    case disconnectFailed
}

extension SSHError: LocalizedError {
    /// UI 展示的用户可读信息；不回显任何 Secret 或内部状态码。
    var errorDescription: String? {
        localizedDescription(locale: Locale(identifier: "en"))
    }

    /// 按当前 App Locale 生成安全、业务级错误文案。
    func localizedDescription(locale: Locale) -> String {
        switch self {
        case .invalidHost:
            L10n.string("error.ssh.invalid_host", defaultValue: "Please check the host name and username before connecting.", locale: locale)
        case .dnsResolutionFailed:
            L10n.string("error.ssh.dns", defaultValue: "The server address could not be resolved. Check the hostname and your network.", locale: locale)
        case .connectionTimeout:
            L10n.string("error.ssh.timeout", defaultValue: "The connection timed out. The server or network may be unreachable.", locale: locale)
        case .connectionRefused:
            L10n.string("error.ssh.refused", defaultValue: "The connection was refused. No SSH server is listening on this port.", locale: locale)
        case .socketError:
            L10n.string("error.ssh.network", defaultValue: "A network error occurred while connecting to the server.", locale: locale)
        case .sessionInitializationFailed:
            L10n.string("error.ssh.session_init", defaultValue: "The SSH session could not be created.", locale: locale)
        case .handshakeFailed:
            L10n.string("error.ssh.handshake", defaultValue: "The SSH handshake failed. The server may not be a compatible SSH server.", locale: locale)
        case .hostKeyUnavailable:
            L10n.string("error.ssh.host_key_unavailable", defaultValue: "The server identity could not be read after the handshake.", locale: locale)
        case .hostTrustRejected:
            L10n.string("error.ssh.trust_rejected", defaultValue: "The connection was cancelled because the server identity was not trusted.", locale: locale)
        case .hostKeyChanged:
            L10n.string("error.ssh.host_key_changed", defaultValue: "The server's host key has changed. The connection was blocked to protect against a possible man-in-the-middle attack.", locale: locale)
        case .knownHostPersistenceFailed:
            L10n.string("error.ssh.known_host_save", defaultValue: "The trusted host key could not be saved, so the connection was closed before signing in. Please try again.", locale: locale)
        case .credentialNotFound:
            L10n.string("error.ssh.credential_missing", defaultValue: "No saved password was found for this host. Save a password before connecting.", locale: locale)
        case .passwordAuthenticationUnsupported:
            L10n.string("error.ssh.password_unsupported", defaultValue: "This server does not support password authentication.", locale: locale)
        case .authenticationFailed:
            L10n.string("error.ssh.authentication", defaultValue: "Authentication failed. Check your username and password.", locale: locale)
        case .privateKeyPathMissing:
            L10n.string("error.ssh.private_key_missing", defaultValue: "No private key file is configured for this host. Choose a private key before connecting.", locale: locale)
        case .privateKeyFileNotFound:
            L10n.string("error.ssh.private_key_not_found", defaultValue: "The configured private key file could not be found. It may have been moved or deleted.", locale: locale)
        case .privateKeyFileUnreadable:
            L10n.string("error.ssh.private_key_unreadable", defaultValue: "The private key file exists but could not be read. Check its file permissions.", locale: locale)
        case .privateKeyPassphraseRequired:
            L10n.string("error.ssh.passphrase_required", defaultValue: "This private key requires a passphrase, but none is saved. Save a passphrase before connecting.", locale: locale)
        case .privateKeyPassphraseIncorrect:
            L10n.string("error.ssh.passphrase_incorrect", defaultValue: "The saved passphrase is incorrect and could not decrypt the private key.", locale: locale)
        case .publicKeyAuthenticationUnsupported:
            L10n.string("error.ssh.public_key_unsupported", defaultValue: "This server does not support public key authentication.", locale: locale)
        case .privateKeyAuthenticationFailed:
            L10n.string("error.ssh.private_key_authentication", defaultValue: "Private key authentication was rejected by the server. Check that the key is authorized.", locale: locale)
        case .connectionLost:
            L10n.string("error.ssh.connection_lost", defaultValue: "The SSH connection was lost.", locale: locale)
        case .cancelled:
            L10n.string("error.ssh.cancelled", defaultValue: "The connection was cancelled.", locale: locale)
        case .disconnectFailed:
            L10n.string("error.ssh.disconnect_cleanup", defaultValue: "The connection closed, but the SSH session could not be cleaned up cleanly.", locale: locale)
        }
    }
}
