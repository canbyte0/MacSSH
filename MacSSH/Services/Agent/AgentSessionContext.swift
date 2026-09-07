import Foundation

/// MacSSH 1.1 Phase 10B：Agent 展示级 session 上下文快照（任务书 §12）。
///
/// 只包含 context header 展示所需的最小字段；scrollback / selection /
/// shell / rows / cols / host credentials 属于 Phase 10D。
///
/// cwd 只在有结构化来源（SwiftTerm OSC 7 → session.currentDirectory）时
/// 提供，未知为 nil——绝不伪造。
struct AgentSessionContext: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case local
        case remoteSSH
    }

    let sessionID: UUID
    let kind: Kind

    /// Local 为技术名 "Local"（View 层按 Locale 本地化展示）；
    /// Remote 为 hostDisplayName ?? hostname（用户数据不翻译）。
    let displayName: String

    /// OSC 7 上报的当前目录 URL（`file://host/path`）；未知为 nil。
    let currentDirectory: String?

    /// OSC 7 file URL → 展示路径（本机 HOME 缩略为 `~`）。
    /// 解析失败或为空时返回 nil——绝不推测目录。
    var displayDirectory: String? {
        guard
            let currentDirectory,
            let url = URL(string: currentDirectory),
            url.scheme == "file"
        else { return nil }
        let path = url.path
        guard !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
