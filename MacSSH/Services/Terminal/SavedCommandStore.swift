import Foundation
import Observation
import SwiftData

/// MacSSH 1.1 Phase 7：常用命令分组与命令的持久化操作入口。
///
/// 职责（任务书 §38 / Phase 7A 验收）：
/// - Group CRUD（新增 / 重命名 / 删除）；
/// - Command CRUD（新增 / 编辑 / 删除）；
/// - validation（单行 / 非空 / control-char policy，`CommandValidation`）；
/// - sorting（`sortOrder` 升序）。
///
/// 不持有：TerminalView / Session / SSHConnection（任务书 §38）。
///
/// 删除 Group 使用 nullify 语义（`SavedCommandGroup` 的 `@Relationship(deleteRule: .nullify)`
/// 自动把其中命令的 `group` 置空，移到「未分组」），**不**级联删除命令
/// （任务书 §21 / Phase 7A 验收 §52）。
@MainActor
@Observable
final class SavedCommandStore {
    /// 持久化动作的注入点（与 `KnownHostService` 同模式：测试可注入失败）。
    typealias SaveAction = (ModelContext) throws -> Void

    private let modelContainer: ModelContainer
    private let saveAction: SaveAction

    init(
        modelContainer: ModelContainer,
        saveAction: @escaping SaveAction = { try $0.save() }
    ) {
        self.modelContainer = modelContainer
        self.saveAction = saveAction
    }

    // MARK: - Group CRUD

    /// 新增分组。`name` trim 后不能为空（任务书 §18）。
    /// v1 不强制 name 唯一（Phase 7A 验收 §54：允许同名）。
    @discardableResult
    func addGroup(name: String, sortOrder: Int? = nil) throws -> SavedCommandGroup {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SavedCommandError.emptyGroupName
        }
        let context = modelContainer.mainContext
        let order = sortOrder ?? nextGroupSortOrder(in: context)
        let group = SavedCommandGroup(name: trimmedName, sortOrder: order)
        context.insert(group)
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            throw SavedCommandError.persistenceFailed
        }
        return group
    }

    /// 重命名分组。name trim 后不能为空。
    func renameGroup(id: UUID, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SavedCommandError.emptyGroupName
        }
        let context = modelContainer.mainContext
        guard let group = fetchGroup(id: id, in: context) else {
            throw SavedCommandError.groupNotFound
        }
        group.name = trimmedName
        group.updatedAt = .now
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            throw SavedCommandError.persistenceFailed
        }
    }

    /// 删除分组。nullify 语义：其中命令的 `group` 被置空（移到未分组），
    /// **不**删除命令。删除前 UI 应弹确认告知「将把 N 条命令移到未分组」。
    func deleteGroup(id: UUID) throws {
        let context = modelContainer.mainContext
        guard let group = fetchGroup(id: id, in: context) else {
            return // 幂等：已不存在即 no-op。
        }
        context.delete(group)
        // SavedCommandGroup 的 @Relationship(deleteRule: .nullify) 会在删除时把
        // SavedCommand.group 置空，命令保留并移到未分组。
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            throw SavedCommandError.persistenceFailed
        }
    }

    // MARK: - Command CRUD

    /// 新增命令。`command` 保存原文（不 trim，任务书 §71），但经
    /// `CommandValidation` 校验（单行 / 非空 / 无 NUL/CR/LF/U+2028/U+2029）。
    /// `groupID` 为 nil 时命令进入「未分组」。
    @discardableResult
    func addCommand(command: String, groupID: UUID? = nil, sortOrder: Int? = nil) throws -> SavedCommand {
        guard !CommandValidation.isRejected(command) else {
            throw SavedCommandError.invalidCommand
        }
        let context = modelContainer.mainContext
        let group = groupID.flatMap { fetchGroup(id: $0, in: context) }
        let order = sortOrder ?? nextCommandSortOrder(in: context, groupID: groupID)
        let saved = SavedCommand(command: command, group: group, sortOrder: order)
        context.insert(saved)
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            throw SavedCommandError.persistenceFailed
        }
        return saved
    }

    /// 编辑命令文本。经 `CommandValidation` 校验。保存原文。
    func updateCommand(id: UUID, command: String) throws {
        guard !CommandValidation.isRejected(command) else {
            throw SavedCommandError.invalidCommand
        }
        let context = modelContainer.mainContext
        guard let saved = fetchCommand(id: id, in: context) else {
            throw SavedCommandError.commandNotFound
        }
        saved.command = command
        saved.updatedAt = .now
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            throw SavedCommandError.persistenceFailed
        }
    }

    /// 删除命令。幂等。
    func deleteCommand(id: UUID) throws {
        let context = modelContainer.mainContext
        guard let saved = fetchCommand(id: id, in: context) else {
            return
        }
        context.delete(saved)
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            throw SavedCommandError.persistenceFailed
        }
    }

    // MARK: - 查询（UI @Query 的补充，供 Dispatcher / 测试使用）

    /// 全部分组（按 sortOrder 升序）。
    func allGroups() -> [SavedCommandGroup] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<SavedCommandGroup>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 未分组命令（group == nil，按 sortOrder 升序）。
    func ungroupedCommands() -> [SavedCommand] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<SavedCommand>(
            predicate: #Predicate { $0.group == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 某分组下的命令（按 sortOrder 升序）。
    func commands(inGroup id: UUID) -> [SavedCommand] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<SavedCommand>(
            predicate: #Predicate { $0.group?.id == id },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 私有

    private func fetchGroup(id: UUID, in context: ModelContext) -> SavedCommandGroup? {
        let descriptor = FetchDescriptor<SavedCommandGroup>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func fetchCommand(id: UUID, in context: ModelContext) -> SavedCommand? {
        let descriptor = FetchDescriptor<SavedCommand>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func nextGroupSortOrder(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<SavedCommandGroup>(
            sortBy: [SortDescriptor(\.sortOrder, order: .reverse)]
        )
        let max = (try? context.fetch(descriptor).first?.sortOrder) ?? -1
        return max + 1
    }

    private func nextCommandSortOrder(in context: ModelContext, groupID: UUID?) -> Int {
        let descriptor: FetchDescriptor<SavedCommand>
        if let groupID {
            descriptor = FetchDescriptor<SavedCommand>(
                predicate: #Predicate { $0.group?.id == groupID },
                sortBy: [SortDescriptor(\.sortOrder, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<SavedCommand>(
                predicate: #Predicate { $0.group == nil },
                sortBy: [SortDescriptor(\.sortOrder, order: .reverse)]
            )
        }
        let max = (try? context.fetch(descriptor).first?.sortOrder) ?? -1
        return max + 1
    }
}

/// SavedCommand 业务错误（语言无关，UI 按 Locale 映射文案）。
enum SavedCommandError: Error, Equatable {
    case emptyGroupName
    case invalidCommand
    case groupNotFound
    case commandNotFound
    case persistenceFailed
}
