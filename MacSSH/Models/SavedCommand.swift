import Foundation
import SwiftData

/// MacSSH 1.1 Phase 7：用户保存的常用命令（SwiftData 持久化）。
///
/// v1 字段（任务书 §25 / Phase 7A 验收 §55）：
/// - `id` / `command` / `group`（nullable）/ `sortOrder`；
/// - **不**加 title / tag / host binding / variable template / shortcut / AI。
///
/// `command` 第一版只支持单行（任务书 §27 / Phase 7A 验收 §56）：
/// Store + UI 双重校验拒绝 `\n` / `\r` / NUL / U+2028 / U+2029；
/// 允许 TAB / ESC / BEL（合法命令字符）；保存用户原文（不自动 trim，任务书 §71）。
///
/// `group == nil` 代表「未分组」（任务书 §30 / Phase 7A 验收 §53）——
/// UI 始终能查询 `group == nil` 的命令显示为「未分组」section，**不**创建
/// 假的「Ungrouped」SavedCommandGroup。
@Model
final class SavedCommand {
    /// 业务层稳定标识。
    @Attribute(.unique) var id: UUID

    /// 单行命令文本（原文，不 trim；Store 层校验单行 + 非空）。
    var command: String

    /// 所属分组；nil = 未分组。删除分组时由 `.nullify` 规则置空。
    var group: SavedCommandGroup?

    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        command: String,
        group: SavedCommandGroup? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.command = command
        self.group = group
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
