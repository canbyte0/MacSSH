import Foundation
import Observation
import SwiftData

/// MacSSH 1.1 Phase 7：命令历史存储（SwiftData 持久化）。
///
/// History v1 **只记录通过 MacSSH Execute action 明确执行的命令**
/// （任务书 §22 / Phase 7A 验收 §38）。不记录手动键盘输入、Paste、
/// password prompt、REPL、tmux raw input——禁止 keyboard interception
/// （P1 安全边界，任务书 §23）。
///
/// 职责（任务书 §39 / Phase 7A 验收）：
/// - append（仅在 historyEnabled 且 Execute 成功发送后调用）；
/// - dedupe（2026-09-05 用户授权行为变更）：相同 command 文本只保留一条，
///   再次执行时刷新该行时间戳与快照，按 executedAt 倒序自然置顶；
/// - query（按 executedAt 倒序）；
/// - scope（全局 / 按 session，Phase 7A 默认全局）；
/// - retention（全局上限 1000，超限 prune 最旧，deterministic）；
/// - clear（只删 History，不删 SavedCommand/Groups/Hosts/KnownHosts）；
/// - historyEnabled（UserDefaults 偏好，Settings 开关）。
///
/// 不监听 keyboard、不处理 Terminal bytes（任务书 §39）。
@MainActor
@Observable
final class CommandHistoryStore {
    /// 全局上限（Phase 7A 验收 §44：1000 条，deterministic pruning）。
    static let maxEntries = 1000

    /// 保存命令历史的 UserDefaults key（与 `AppLanguage` 同类偏好）。
    static let historyEnabledKey = "macssh.commandHistoryEnabled"

    private let modelContainer: ModelContainer
    private let userDefaults: UserDefaults
    private let saveAction: SaveAction

    /// 是否记录命令历史（用户可关闭，任务书 §32 / Phase 7A 验收 §45）。
    /// 默认 On（v1 只记 MacSSH Execute，隐私风险低；Phase 7A 验收 §45）。
    var historyEnabled: Bool {
        didSet {
            userDefaults.set(historyEnabled, forKey: Self.historyEnabledKey)
        }
    }

    typealias SaveAction = (ModelContext) throws -> Void

    init(
        modelContainer: ModelContainer,
        userDefaults: UserDefaults = .standard,
        saveAction: @escaping SaveAction = { try $0.save() }
    ) {
        self.modelContainer = modelContainer
        self.userDefaults = userDefaults
        self.saveAction = saveAction
        // 默认 On：无存储值时 true（Phase 7A 验收 §45）。
        if userDefaults.object(forKey: Self.historyEnabledKey) == nil {
            self.historyEnabled = true
        } else {
            self.historyEnabled = userDefaults.bool(forKey: Self.historyEnabledKey)
        }
        dedupeExistingEntries()
    }

    // MARK: - append

    /// 记录一条执行历史。仅在 `historyEnabled == true` 时实际写入。
    ///
    /// append 时机（任务书 §27 / Phase 7A 验收 §40）：Dispatcher 在预检通过
    /// （`displayState == .active`）+ 同步 `pasteText`+Return 发送完成后调用。
    /// 连接已断 / 预检失败时 Dispatcher 不调用本方法。
    ///
    /// - Parameters:
    ///   - command: 执行的命令文本（原文）。
    ///   - sessionID: runtime session UUID（快照，不依赖活着的 Session 对象）。
    ///   - sessionKind: "local" / "remoteSSH"。
    ///   - hostDisplayName: Remote 时存 host 显示名快照（不含凭据）；Local 为 nil。
    ///   - source: "savedCommand" / "historyReplay"（任务书 §25 / 验收 §39）。
    func append(
        command: String,
        sessionID: UUID,
        sessionKind: String,
        hostDisplayName: String?,
        source: String
    ) {
        guard historyEnabled else {
            return // 用户关闭历史记录：不写。
        }
        let context = modelContainer.mainContext
        // 去重语义（2026-09-05 用户授权行为变更）：相同 command 文本（精确匹配，
        // 不做 trim/规范化）只保留一条。再次执行时刷新该行时间戳与快照，
        // 视图按 executedAt 倒序自然置顶，不产生重复行。
        let duplicateDescriptor = FetchDescriptor<CommandHistoryEntry>(
            predicate: #Predicate { $0.command == command }
        )
        let duplicates = (try? context.fetch(duplicateDescriptor)) ?? []
        if let kept = Self.newestEntry(of: duplicates) {
            kept.executedAt = .now
            kept.sessionID = sessionID
            kept.sessionKind = sessionKind
            kept.hostDisplayName = hostDisplayName
            kept.source = source
            // 防御：理论上经 init 合并后不会有多条；若存在则合并为一条。
            for extra in duplicates where extra !== kept {
                context.delete(extra)
            }
        } else {
            let entry = CommandHistoryEntry(
                command: command,
                executedAt: .now,
                sessionID: sessionID,
                sessionKind: sessionKind,
                hostDisplayName: hostDisplayName,
                source: source
            )
            context.insert(entry)
        }
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            // 不抛错：历史写入失败不应阻塞 Execute（命令已发送）。
            // 只记录不含 command 内容的安全日志。
            AppLogger.app.error("Command history append failed (persistence)")
            return
        }
        pruneIfNeeded()
    }

    // MARK: - query

    /// 最近的历史条目（按 executedAt 倒序，最新在前）。
    /// `limit` 默认取全部（受 retention 上限约束）。
    func recentEntries(limit: Int? = nil) -> [CommandHistoryEntry] {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<CommandHistoryEntry>(
            sortBy: [SortDescriptor(\.executedAt, order: .reverse)]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 某 session 的历史（按 executedAt 倒序）。
    func entries(forSession sessionID: UUID) -> [CommandHistoryEntry] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<CommandHistoryEntry>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.executedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - clear

    /// 清空全部历史（任务书 §33 / Phase 7A 验收 §46）。
    /// **只删 CommandHistoryEntry**，绝不删 SavedCommand/Groups/Hosts/KnownHosts。
    func clear() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<CommandHistoryEntry>()
        guard let all = try? context.fetch(descriptor) else {
            return
        }
        for entry in all {
            context.delete(entry)
        }
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            AppLogger.app.error("Command history clear failed (persistence)")
        }
    }

    // MARK: - dedupe

    /// deterministic「保留哪条」规则：executedAt 最新；并列时 id.uuidString 最小。
    static func newestEntry(of entries: [CommandHistoryEntry]) -> CommandHistoryEntry? {
        entries.max { lhs, rhs in
            if lhs.executedAt != rhs.executedAt {
                return lhs.executedAt < rhs.executedAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    /// 一次性合并去重语义引入（2026-09-05）之前已存在的存量重复行。
    /// 每条 command 只保留最新一条；store 每次初始化时执行（上限 1000 行，开销可忽略），
    /// upsert 保证之后不再产生重复，因此本方法通常是无操作的。
    private func dedupeExistingEntries() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<CommandHistoryEntry>()
        guard let all = try? context.fetch(descriptor) else {
            return
        }
        var byCommand: [String: [CommandHistoryEntry]] = [:]
        for entry in all {
            byCommand[entry.command, default: []].append(entry)
        }
        var didDelete = false
        for (_, group) in byCommand where group.count > 1 {
            guard let kept = Self.newestEntry(of: group) else { continue }
            for extra in group where extra !== kept {
                context.delete(extra)
                didDelete = true
            }
        }
        guard didDelete else { return }
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            AppLogger.app.error("Command history dedupe migration failed (persistence)")
        }
    }

    // MARK: - retention

    /// 全局超过 `maxEntries` 时删除最旧的差额数量，保证 deterministic pruning
    /// （Phase 7A 验收 §44 / 任务书 §31）。
    private func pruneIfNeeded() {
        let context = modelContainer.mainContext
        let countDescriptor = FetchDescriptor<CommandHistoryEntry>()
        let total = (try? context.fetchCount(countDescriptor)) ?? 0
        guard total > Self.maxEntries else {
            return
        }
        let excess = total - Self.maxEntries
        // 按 executedAt 升序取最旧的 excess 条，删除。
        var descriptor = FetchDescriptor<CommandHistoryEntry>(
            sortBy: [SortDescriptor(\.executedAt, order: .forward)]
        )
        descriptor.fetchLimit = excess
        guard let oldest = try? context.fetch(descriptor) else {
            return
        }
        for entry in oldest {
            context.delete(entry)
        }
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            AppLogger.app.error("Command history prune failed (persistence)")
        }
    }
}
