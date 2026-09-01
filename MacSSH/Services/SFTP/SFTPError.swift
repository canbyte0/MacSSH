import Foundation

/// Phase 9 SFTP Browser 的业务级错误。
///
/// 覆盖 SFTP 子系统初始化、目录列举与路径解析失败；权限不足 / 路径不存在
/// 是**业务错误**——保持连接与 Terminal 不变，不崩溃、不自动断开。
/// libssh2 / SFTP 协议原始码仅写入安全日志诊断，不直接进入用户可见信息。
enum SFTPError: Error, Equatable, Sendable {
    /// SFTP 子系统初始化失败（服务器不支持或握手后协商失败）。
    /// 不影响既有 Terminal：初始化失败不断开健康连接。
    case subsystemInitFailed
    /// 路径在服务器上不存在。
    case noSuchPath
    /// 权限不足（无法列举该目录）。
    case permissionDenied
    /// 底层 SSH 连接已不可用。
    case connectionLost
    /// 其他 SFTP 协议错误；携带 `libssh2_sftp_last_error()` 的 FX 状态码。
    case protocolFailure(code: UInt32)
    /// 操作被本地取消（导航被新请求取代 / Session 拆除）；不展示给用户。
    case operationCancelled

    /// SSH 服务器返回的 SFTP 状态码（FX_*，RFC 4419 草案编号）。
    /// 2 = NO_SUCH_FILE，3 = PERMISSION_DENIED；其余归为协议错误。
    init(sftpStatusCode code: UInt32) {
        switch code {
        case 2:
            self = .noSuchPath
        case 3:
            self = .permissionDenied
        default:
            self = .protocolFailure(code: code)
        }
    }
}

extension SFTPError: LocalizedError {
    /// UI 展示的用户可读信息；不回显任何 Secret 或原始状态码。
    var errorDescription: String? {
        localizedDescription(locale: Locale(identifier: "en"))
    }

    /// 用户界面按当前 App Locale 解析，底层 FX 状态码仍只进入日志。
    func localizedDescription(locale: Locale) -> String {
        switch self {
        case .subsystemInitFailed:
            L10n.string("error.sftp.subsystem", defaultValue: "The server could not open an SFTP session.", locale: locale)
        case .noSuchPath:
            L10n.string("error.sftp.no_such_path", defaultValue: "This folder no longer exists on the server.", locale: locale)
        case .permissionDenied:
            L10n.string("error.sftp.permission_denied", defaultValue: "You do not have permission to view this folder.", locale: locale)
        case .connectionLost:
            L10n.string("error.ssh.connection_lost", defaultValue: "The SSH connection was lost.", locale: locale)
        case .protocolFailure:
            L10n.string("error.sftp.protocol", defaultValue: "The SFTP server reported an error.", locale: locale)
        case .operationCancelled:
            L10n.string("error.operation_cancelled", defaultValue: "The operation was cancelled.", locale: locale)
        }
    }
}
