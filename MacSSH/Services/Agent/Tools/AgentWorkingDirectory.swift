import Foundation

/// cwd 的结构化来源（任务书 10D-B1 §9）。
enum AgentCWDSource: Sendable, Equatable {
    /// Shell 经 OSC 7 主动上报（每提示符一次），最可靠。
    case osc7
    /// 会话默认目录（SFTP session 启动目录等协议级默认值），
    /// 只是近似：用户可能早已 cd 离开。
    case sessionDefault
    /// 没有任何可靠来源。
    case unavailable
}

/// cwd 的可信度（任务书 §9）。
enum AgentCWDConfidence: Sendable, Equatable {
    /// 权威：来自结构化上报，可作为相对路径基准与 scope root。
    case authoritative
    /// 近似：不可作为相对路径基准，也不得自动加入 allowedRoots。
    case approximate
    /// 不可用。
    case unavailable
}

/// Agent 的会话工作目录模型（provider-neutral，任务书 §9）。
///
/// 安全语义绝不通过裸 `String?` 表达：`path` 必须与 `source` /
/// `confidence` 一起解读。合法组合只由工厂构造：
///
/// ```text
/// OSC 7 上报           → source: osc7     / confidence: authoritative
/// SFTP session default → source: sessionDefault / confidence: approximate
/// 无可靠来源           → source: unavailable  / confidence: unavailable
/// ```
///
/// 本阶段（10D-B1）该模型只被测试消费；AgentViewModel 仍走
/// Phase 10B 的 `AgentSessionContext`（展示级），接线属于后续阶段。
struct AgentWorkingDirectory: Sendable, Equatable {
    /// 解码后的绝对路径（不含 `file://` 前缀）；`unavailable` 时为 nil。
    let path: String?
    let source: AgentCWDSource
    let confidence: AgentCWDConfidence

    /// 无任何可靠来源。
    static let unavailable = AgentWorkingDirectory(
        path: nil,
        source: .unavailable,
        confidence: .unavailable
    )

    /// 从 SwiftTerm 存储的 OSC 7 原始 URL（`file://host/<percent-encoded>`）
    /// 构造权威 cwd。
    ///
    /// 解码链与 `AgentSessionContext.displayDirectory` 一致：`URL(string:)`
    /// → `.path`（Foundation 按 RFC 3986 解 percent-encoding，UTF-8 字节
    /// 还原为原路径）。非法输入（nil / 空串 / 非 file scheme / 空路径 /
    /// 无法解析的 URL）一律返回 `.unavailable`——绝不猜测、绝不伪造。
    ///
    /// host 字段不参与判定：本地 shell 与 App 属同一信任域（同一 uid），
    /// OSC 7 内容不可信的攻击面等同 shell 本身，超出场阶边界。
    static func fromOSC7URL(_ rawURL: String?) -> AgentWorkingDirectory {
        guard
            let rawURL,
            !rawURL.isEmpty,
            let url = URL(string: rawURL),
            url.scheme == "file",
            !url.path.isEmpty
        else {
            return .unavailable
        }
        return AgentWorkingDirectory(
            path: url.path,
            source: .osc7,
            confidence: .authoritative
        )
    }

    /// 从 SFTP 会话默认目录构造近似 cwd（本阶段仅 domain 表达，
    /// 不真正调用 SFTP）。近似 cwd 不得进入 allowedRoots（任务书 §23）。
    static func sessionDefault(path: String) -> AgentWorkingDirectory {
        guard !path.isEmpty else {
            return .unavailable
        }
        return AgentWorkingDirectory(
            path: path,
            source: .sessionDefault,
            confidence: .approximate
        )
    }
}
