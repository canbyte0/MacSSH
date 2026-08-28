import Foundation
import SwiftData

/// 可由 Host Manager 管理并通过 SwiftData 持久化的普通主机信息。
///
/// 密码、Private Key Passphrase 和私钥内容不属于本模型；Phase 3 仅保留
/// 后续 Keychain 阶段可使用的可空引用标识。
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

    /// Phase 4 可关联 Keychain credential；Phase 3 始终保持 nil。
    var credentialID: UUID?

    /// 后续私钥管理阶段可关联私钥记录；Phase 3 始终保持 nil。
    var privateKeyID: UUID?

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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
        self.notes = notes
    }
}
