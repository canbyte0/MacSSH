import Foundation
import SwiftData

/// Host Manager 的持久化分组；分组删除不会级联删除其中的 Host。
@Model
final class HostGroup {
    /// 业务层稳定标识。
    @Attribute(.unique) var id: UUID

    /// 分组名称在当前数据容器中保持唯一，避免出现无法区分的同名分组。
    @Attribute(.unique) var name: String

    var createdAt: Date
    var updatedAt: Date

    /// 删除 HostGroup 时将 Host.group 置空，保留用户的 Host 数据。
    @Relationship(deleteRule: .nullify, inverse: \Host.group)
    var hosts: [Host] = []

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
