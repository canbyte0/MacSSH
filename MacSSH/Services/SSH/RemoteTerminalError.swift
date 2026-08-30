import Foundation

/// Remote Terminal（Phase 7）的业务级错误。
///
/// 覆盖 SSH Channel / PTY / Shell 生命周期与 I/O 失败；libssh2 原始错误码
/// 仅写入安全日志用于诊断，不直接展示给用户，任何情况下都不包含
/// Password、Passphrase、私钥内容或终端输入输出。
enum RemoteTerminalError: Error, Equatable, Sendable {
    /// Session Channel 打开失败。
    case channelOpenFailed
    /// PTY 请求被服务器拒绝。
    case ptyRequestFailed
    /// Shell 请求被服务器拒绝。
    case shellRequestFailed
    /// Channel 读取失败（非 EOF 的传输错误）。
    case channelReadFailed
    /// Channel 写入失败。
    case channelWriteFailed
    /// Channel 已关闭（远端退出或本地清理后继续操作）。
    case channelClosed
    /// 底层 SSH Connection 已不可用。
    case connectionLost
    /// PTY 尺寸同步失败。
    case resizeFailed

    /// 底层 libssh2 错误码，仅用于安全日志诊断，不进入用户可见信息。
    var diagnosticsCode: Int32? {
        switch self {
        case .channelOpenFailed, .ptyRequestFailed, .shellRequestFailed,
             .channelReadFailed, .channelWriteFailed, .resizeFailed:
            // 具体码由抛出点附带记录；这里只保留业务枚举。
            nil
        case .channelClosed, .connectionLost:
            nil
        }
    }
}

extension RemoteTerminalError: LocalizedError {
    /// UI 展示的用户可读信息；不回显任何 Secret 或原始状态码。
    var errorDescription: String? {
        switch self {
        case .channelOpenFailed:
            "The server refused to open a terminal channel."
        case .ptyRequestFailed:
            "The server refused to allocate a pseudo-terminal."
        case .shellRequestFailed:
            "The server refused to start a remote shell."
        case .channelReadFailed:
            "The terminal connection was interrupted while receiving output."
        case .channelWriteFailed:
            "Input could not be delivered to the remote terminal."
        case .channelClosed:
            "The remote terminal channel is closed."
        case .connectionLost:
            "The SSH connection was lost."
        case .resizeFailed:
            "The remote terminal could not be resized."
        }
    }
}
