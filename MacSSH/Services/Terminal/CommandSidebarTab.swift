import Foundation

/// MacSSH 1.1 Phase 7：右侧栏顶部图标 tab 选择（历史记录 / 常用命令）。
/// MacSSH 1.1 Phase 10B：新增 `agent`（AI Agent Sidebar UI Shell）。
///
/// 状态持久化到 UserDefaults（任务书 §4 / §67 / Phase 7A 验收 §41），
/// 不保存 runtime active session。
enum CommandSidebarTab: String, CaseIterable, Sendable {
    case history
    case savedCommands
    case agent

    /// 历史 / 常用命令 / Agent icon 的 SF Symbol。
    var systemImage: String {
        switch self {
        case .history:
            return "clock.arrow.circlepath"
        case .savedCommands:
            // 任务书 §2：常用命令优先 `terminal`；Phase 7A 验收 §58 选 `command.square`
            // （`terminal` 已被左侧栏 AppSection.terminal 占用且语义重叠）。
            return "command.square"
        case .agent:
            // Phase 10B 任务书 §3：Agent icon 优先 `sparkles`，不引入自定义图片资产。
            return "sparkles"
        }
    }

    /// Tab 的 tooltip / accessibility 标题（按当前 Locale 即时解析，不缓存）。
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .history:
            return L10n.string(
                "sidebar_right.history",
                defaultValue: "History",
                locale: locale
            )
        case .savedCommands:
            return L10n.string(
                "sidebar_right.saved_commands",
                defaultValue: "Saved Commands",
                locale: locale
            )
        case .agent:
            return L10n.string(
                "agent.title",
                defaultValue: "Agent",
                locale: locale
            )
        }
    }
}
