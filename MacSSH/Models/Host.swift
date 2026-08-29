import Foundation
import SwiftData

/// 可由 Host Manager 管理并通过 SwiftData 持久化的普通主机信息。
///
/// 密码、Private Key Passphrase 和私钥内容不属于本模型；这里只保留
/// Phase 4 Keychain 凭据所需的可空稳定引用标识。
@Model
final class Host {
    /// 业务层稳定标识，不依赖 SwiftData 的内部 PersistentIdentifier。
    @Attribute(.unique) var id: UUID

    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authenticationType: AuthenticationType
    var favorite: Bool

    /// 删除分组时由 HostGroup 的 nullify 关系规则自动设为 nil。
    var group: HostGroup?

    /// 指向 Keychain Password 的稳定 UUID；不包含实际 Secret。
    var credentialID: UUID?

    /// 指向 Private Key Passphrase 的稳定 UUID；不包含私钥或 Passphrase。
    /// 仅当私钥需要 Passphrase 时非空；无 Passphrase 的私钥此字段为 nil。
    var privateKeyID: UUID?

    /// OpenSSH 私钥文件路径（文件本身，非 Secret）。
    ///
    /// 按计划书 Developer ID 站外分发路线实现：保存绝对路径即可。
    /// 架构上不假设该路径永远可访问（文件可能被移动/删除），
    /// 连接时按 `privateKeyFileNotFound`/`privateKeyFileUnreadable` 优雅失败。
    /// 未实现 Security-Scoped Bookmark，避免为未来 App Store 版本过度设计；
    /// 该设计边界记录于 Docs/DevelopmentStatus.md。
    var privateKeyPath: String?

    var createdAt: Date
    var updatedAt: Date
    var lastConnectedAt: Date?
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authenticationType: AuthenticationType = .password,
        group: HostGroup? = nil,
        favorite: Bool = false,
        credentialID: UUID? = nil,
        privateKeyID: UUID? = nil,
        privateKeyPath: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastConnectedAt: Date? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authenticationType = authenticationType
        self.group = group
        self.favorite = favorite
        self.credentialID = credentialID
        self.privateKeyID = privateKeyID
        self.privateKeyPath = privateKeyPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
        self.notes = notes
    }
}
