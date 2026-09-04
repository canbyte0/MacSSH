import Foundation
import SwiftData

/// MacSSH 1.1 Phase 7：命令历史条目（SwiftData 持久化）。
///
/// History v1 **只记录通过 MacSSH Execute action 明确执行的命令**
/// （任务书 §22 / Phase 7A 验收 §38）。不记录手动键盘输入、Paste、
/// password prompt、REPL、tmux raw input——禁止 keyboard interception
/// （P1 安全边界，任务书 §23 / Phase 7A 验收 §31）。
///
/// 不依赖活着的 Session 对象（任务书 §29 / Phase 7A 验收 §42）：
/// `sessionID` 是 runtime UUID 快照，session close 后 history 仍可显示
/// （靠 `sessionKind` + `hostDisplayName` 快照，不读已销毁的 Session）。
///
/// command 视为 private user content（任务书 §28 / Phase 7A 验收 §47）：
/// 日志绝不记录 command 内容，只记 count / id / source。
@Model
final class CommandHistoryEntry {
    /// 业务层稳定标识。
    @Attribute(.unique) var id: UUID

    /// 执行的命令文本（原文，单行）。
    var command: String

    /// 执行时刻（用于倒序排序与 retention pruning）。
    var executedAt: Date

    /// 关联的 runtime session UUID（内存对象，不持久化 session 本身）。
    /// session close 后此值仅作快照，不用于反查 Session 对象。
    var sessionID: UUID

    /// "local" / "remoteSSH"（区分来源，不依赖 Session 对象）。
    var sessionKind: String

    /// Remote 时存 host 显示名快照（不含凭据）；Local 为 nil。
    var hostDisplayName: String?

    /// "savedCommand" / "historyReplay"（命令来源；任务书 §25 / Phase 7A 验收 §39）。
    var source: String

    init(
        id: UUID = UUID(),
        command: String,
        executedAt: Date = .now,
        sessionID: UUID,
        sessionKind: String,
        hostDisplayName: String? = nil,
        source: String
    ) {
        self.id = id
        self.command = command
        self.executedAt = executedAt
        self.sessionID = sessionID
        self.sessionKind = sessionKind
        self.hostDisplayName = hostDisplayName
        self.source = source
    }
}
