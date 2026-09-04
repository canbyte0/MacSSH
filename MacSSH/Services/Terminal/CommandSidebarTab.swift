import Foundation

/// MacSSH 1.1 Phase 7：右侧栏顶部图标 tab 选择（历史记录 / 常用命令）。
///
/// 状态持久化到 UserDefaults（任务书 §4 / §67 / Phase 7A 验收 §41），
/// 不保存 runtime active session。
enum CommandSidebarTab: String, CaseIterable, Sendable {
    case history
    case savedCommands

    /// 历史 / 常用命令 icon 的 SF Symbol。
    var systemImage: String {
        switch self {
        case .history:
            return "clock.arrow.circlepath"
        case .savedCommands:
            // 任务书 §2：常用命令优先 `terminal`；Phase 7A 验收 §58 选 `command.square`
            // （`terminal` 已被左侧栏 AppSection.terminal 占用且语义重叠）。
            return "command.square"
        }
    }
}
