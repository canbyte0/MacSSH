import Foundation

/// SSH 连接的完整生命周期状态机。
///
/// 必须能够区分 TCP 连接中、SSH handshake 中、等待用户确认服务器身份、
/// 认证中和最终 connected，不允许退化为单个 `isConnected` 布尔值。
enum SSHConnectionPhase: Equatable, Sendable {
    /// 尚未开始连接。
    case idle
    /// 正在解析地址并建立 TCP 连接。
    case connecting
    /// TCP 已建立，正在进行 SSH handshake。
    case handshaking
    /// Handshake 完成，等待用户确认服务器 Host Key。
    case awaitingHostTrust
    /// 服务器已信任，正在进行 Password Authentication。
    case authenticating
    /// 认证成功，SSH Session 可用。
    case connected
    /// 正在正常断开连接。
    case disconnecting
    /// 已正常断开。
    case disconnected
    /// 失败终止；携带业务级错误。
    case failed(SSHError)

    /// 状态栏与 Host 行展示的简短文本。
    var statusText: String {
        switch self {
        case .idle:
            "Not Connected"
        case .connecting:
            "Connecting…"
        case .handshaking:
            "SSH Handshake…"
        case .awaitingHostTrust:
            "Waiting for host verification…"
        case .authenticating:
            "Authenticating…"
        case .connected:
            "Connected"
        case .disconnecting:
            "Disconnecting…"
        case .disconnected:
            "Disconnected"
        case .failed:
            "Failed"
        }
    }

    /// 是否处于任何需要清理资源的中途状态。
    var isBusy: Bool {
        switch self {
        case .connecting, .handshaking, .awaitingHostTrust, .authenticating, .disconnecting:
            true
        case .idle, .connected, .disconnected, .failed:
            false
        }
    }
}

/// Handshake 后从服务器 Host Key 计算出的身份信息。
///
/// 数据直接来自真实 SSH handshake 返回的 Host Key，禁止伪造。
struct SSHHostKeyInfo: Equatable, Sendable {
    /// Host Key 算法名，例如 "ssh-ed25519"。
    let keyType: String

    /// OpenSSH 格式的 SHA256 Fingerprint，例如 "SHA256:xxxxxxxx"。
    let fingerprintSHA256: String

    /// UI 展示用的短算法名，例如 "ED25519"。
    var keyTypeDisplayName: String {
        keyType.replacingOccurrences(of: "ssh-", with: "").uppercased()
    }
}

/// 用户在 Host Trust 对话框中的选择。
enum SSHHostTrustDecision: Sendable {
    /// 仅在当前 Connection 内信任该服务器身份。
    case trustOnce
    /// 拒绝信任并断开连接。
    case cancel
}
