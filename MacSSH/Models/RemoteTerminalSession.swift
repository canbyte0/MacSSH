import Foundation
import Observation

/// Remote Terminal（Phase 7）的可观察运行状态。
///
/// 与 Phase 2 的 `TerminalSession` 对称：View 只观察该状态对象；
/// Shell / Channel / PTY 的真实生命周期由 `RemoteTerminalService`
/// 持有（独立于 SwiftUI View 生命周期，切换 Sidebar 不销毁远端 Shell）。
@MainActor
@Observable
final class RemoteTerminalSession {
    /// 目标主机地址（非敏感展示信息）。
    let hostname: String

    /// 目标端口（非敏感展示信息）。
    let port: Int

    /// Remote Terminal 当前阶段。
    var phase: RemoteTerminalPhase = .opening

    /// SwiftTerm 当前报告的列数。
    var columns = 80

    /// SwiftTerm 当前报告的行数。
    var rows = 24

    /// 远端 Shell 通过 OSC 序列报告的窗口标题。
    var terminalTitle: String?

    /// 远端 Shell 通过 OSC 7 报告的当前目录 URL。
    var currentDirectory: String?

    init(hostname: String, port: Int) {
        self.hostname = hostname
        self.port = port
    }

    /// 状态栏左侧展示的简洁会话状态。
    var statusText: String {
        let host = hostname
        switch phase {
        case .opening:
            return "SSH · \(host) · Opening…"
        case .active:
            return "SSH ● \(host)"
        case .exited:
            return "SSH · \(host) · Exited"
        case .connectionLost:
            return "SSH · \(host) · Connection Lost"
        case .failed:
            return "SSH · \(host) · Failed"
        }
    }

    /// 状态栏右侧展示的 PTY 字符网格尺寸。
    var sizeText: String {
        "\(columns) × \(rows)"
    }
}

/// Remote Terminal 的生命周期阶段。
enum RemoteTerminalPhase: Equatable, Sendable {
    /// 正在打开 Channel / PTY / Shell。
    case opening
    /// 远端 Shell 运行中，可交互。
    case active
    /// 远端 Shell 已退出（用户 `exit` 或远端关闭 Channel）。
    case exited
    /// 底层 SSH Connection 丢失（网络断开 / 服务器关闭）。
    case connectionLost
    /// 打开阶段失败（Channel / PTY / Shell 请求被拒绝等）。
    case failed(RemoteTerminalError)
}
