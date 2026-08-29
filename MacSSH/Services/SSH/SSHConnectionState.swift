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
    ///
    /// Phase 6：该阶段同时覆盖“未知主机首次连接”与“Host Key 变化”两种情况，
    /// 具体由 `SSHConnectionInfo.hostKeyVerification` 区分；UI 据此显示不同对话框。
    /// 已信任主机（Host Key 匹配）不进入此阶段，直接跳到 authenticating。
    case awaitingHostTrust
    /// 服务器已信任/已验证，正在进行认证（Password 或 Private Key）。
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

    /// 握手返回的完整 Host Public Key 字节。
    ///
    /// Phase 6：持久化 KnownHost 与验证服务器身份时**比较该字节序列本身**，
    /// 而非 Fingerprint（Fingerprint 仅用于 UI 展示）。
    let hostKeyBlob: Data

    /// UI 展示用的短算法名，例如 "ED25519"。
    var keyTypeDisplayName: String {
        keyType.replacingOccurrences(of: "ssh-", with: "").uppercased()
    }
}

/// Handshake 后对服务器 Host Key 的持久化验证结果。
///
/// 由 `SSHConnection` 在握手取得真实 Host Key 后、对照 `KnownHostService` 计算得出，
/// 同步到 `SSHConnectionInfo` 供 UI 决定显示哪个对话框（或直接放行）。
enum HostKeyVerification: Equatable, Sendable {
    /// 没有已保存的 KnownHost：首次连接，应显示“未知主机”对话框
    /// （Trust Once / Trust Always / Cancel）。
    case unknown
    /// 已保存的 KnownHost 与当前服务器 Host Key 字节完全一致：
    /// 直接进入认证，无需任何对话框。
    case trusted
    /// 已保存的 KnownHost 与当前服务器 Host Key 不一致：
    /// 硬性阻断，显示“Host Key Changed”警告（Cancel / Replace Trusted Key 二次确认），
    /// 在用户明确替换前绝不发送 Password 或私钥。
    case changed(storedFingerprint: String, storedKeyType: String)
}

/// 用户在 Host Trust 对话框中的选择。
enum SSHHostTrustDecision: Sendable {
    /// 仅在当前 Connection 内信任该服务器身份（不持久化）。
    case trustOnce
    /// 始终信任：把当前服务器 Host Key 写入 KnownHost 持久化（仅用于未知主机）。
    case trustAlways
    /// 替换已保存的 KnownHost 为当前服务器 Host Key（仅用于 Host Key Changed）。
    /// 必须经过 UI 层的二次危险确认后才发送。
    case replaceTrustedKey
    /// 拒绝信任并断开连接。
    case cancel
}
