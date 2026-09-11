import Foundation

/// Agent 文件读取的安全边界（任务书 10D-B1 §10）。
///
/// scope 与单个终端会话绑定：只有权威（OSC 7）cwd 才成为 allowedRoot，
/// 且创建时立即 canonical 化（任务书 §19：root 自身经 symlink 时必须
/// 存最终 canonical root，避免「root = /project、target =
/// /private/.../real-project/file」的假越界）。
///
/// 近似（sessionDefault）与不可用 cwd 一律得到空 roots——绝不因为有
/// `sessionDefault = /home/user` 就自动加入 allowedRoots（任务书 §23）。
///
/// 本阶段 scope 只是 domain/policy：不真正读取文件，远程也只表达策略。
struct AgentReadScope: Sendable, Equatable {
    /// scope 绑定的终端会话；工具执行层必须校验 session 配对，
    /// 错误 session 的 scope 是 P1（任务书 §33）。
    let sessionID: UUID

    /// canonical 化后的允许根。空数组 = 拒绝一切文件访问。
    let allowedRoots: [String]

    /// 按会话 cwd 建 scope。
    ///
    /// - local：root 经 `AgentPathResolver.canonicalize` 解 symlink；
    /// - remote：本地文件系统对远端路径无权威性，root 只做词法规范化
    ///   （远程 symlink 校验属于未来 SFTP 层，本阶段不实现）；
    /// - cwd 非权威或 canonical 化失败（symlink 环等）：roots = []，
    ///   宁可拒绝读取也不放宽。
    static func make(
        sessionID: UUID,
        workingDirectory: AgentWorkingDirectory,
        kind: AgentPathResolver.SessionKind
    ) -> AgentReadScope {
        guard
            workingDirectory.confidence == .authoritative,
            let path = workingDirectory.path,
            !path.isEmpty,
            path.hasPrefix("/"),
            let canonicalRoot = AgentPathResolver.canonicalize(path, kind: kind)
        else {
            return AgentReadScope(sessionID: sessionID, allowedRoots: [])
        }
        return AgentReadScope(sessionID: sessionID, allowedRoots: [canonicalRoot])
    }

    /// path-component aware containment（任务书 §17）。
    ///
    /// 禁止裸 `hasPrefix(root)`：`/project` 会误吞 `/project-evil`。
    /// 等价于 `target == root || target.hasPrefix(root + "/")`，
    /// 并显式处理 `/` root 特例（`/` 包含一切绝对路径；调用方保证
    /// target 已是 canonical 绝对路径）。
    static func isPath(_ target: String, containedInRoot root: String) -> Bool {
        if root == "/" {
            return true
        }
        return target == root || target.hasPrefix(root + "/")
    }

    /// canonical target 是否落在任一允许根内。
    func contains(_ target: String) -> Bool {
        allowedRoots.contains { Self.isPath(target, containedInRoot: $0) }
    }
}
