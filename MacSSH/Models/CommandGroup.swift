import Foundation
import SwiftData

/// MacSSH 1.1 Phase 7：常用命令分组（SwiftData 持久化）。
///
/// 类名使用 `SavedCommandGroup` 以避免与 SwiftUI 的 `CommandGroup`（菜单构建器）
/// 碰撞。设计参考 `HostGroup`（`Models/HostGroup.swift`）：
/// - `@Attribute(.unique) var id: UUID` 业务层稳定标识；
/// - `@Relationship(deleteRule: .nullify, inverse: \SavedCommand.group)`——
///   删除分组时把其中命令的 `group` 置空（移到「未分组」），**不**级联删除命令
///   （任务书 §21 / Phase 7A 验收 §52：nullify 是 safer default）。
///
/// v1 不强制 `name` 唯一（Phase 7A 验收 §54：允许同名，按 `sortOrder` 排序，
/// deterministic）。但 Store 层 trim 后拒绝空名（任务书 §24）。
@Model
final class SavedCommandGroup {
    /// 业务层稳定标识，不依赖 SwiftData 的内部 PersistentIdentifier。
    @Attribute(.unique) var id: UUID

    var name: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    /// 删除 SavedCommandGroup 时将 SavedCommand.group 置空，保留用户的命令数据。
    @Relationship(deleteRule: .nullify, inverse: \SavedCommand.group)
    var commands: [SavedCommand] = []

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
