import Foundation
import SwiftData

/// 持久化的 SSH 服务器身份（Host Key Verification）。
///
/// 与 Phase 5 的“仅本次信任”不同，Phase 6 把服务器 Host Key 持久化到 SwiftData，
/// 使第二次连接同一台服务器时无需再次询问信任。
///
/// 身份键是**真实** `hostname` + `port`（不是用户可修改的 `Host.name` 显示名），
/// 因此 `example.com:22` 与 `example.com:2222` 是两个不同的 KnownHost。
///
/// `hostKey` 保存握手返回的完整 Host Public Key 字节，验证时直接比较该字节序列；
/// `fingerprint` 仅用于 UI 展示，不参与匹配判断。
///
/// Host Key、Fingerprint、Hostname、Port 都不是 Secret，因此可以存 SwiftData，
/// 不进入 Keychain（Keychain 继续只保存 Password 与 Private Key Passphrase）。
@Model
final class KnownHost {
    /// 业务层稳定标识。
    @Attribute(.unique) var id: UUID

    /// 真实目标主机地址（与 Host.hostname 对应，非显示名）。
    var hostname: String

    /// 真实目标端口（与 Host.port 对应）。
    var port: Int

    /// Host Key 算法名，例如 "ssh-ed25519"。
    var keyType: String

    /// 握手返回的完整 Host Public Key 字节；验证时按字节比较该字段。
    var hostKey: Data

    /// OpenSSH 格式 SHA256 Fingerprint，例如 "SHA256:xxxx"（仅 UI 展示）。
    var fingerprint: String

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        hostname: String,
        port: Int,
        keyType: String,
        hostKey: Data,
        fingerprint: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.hostname = hostname
        self.port = port
        self.keyType = keyType
        self.hostKey = hostKey
        self.fingerprint = fingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
