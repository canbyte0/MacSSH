import Observation

/// 本地 Terminal 子进程的生命周期状态。
enum TerminalProcessState: Equatable, Sendable {
    case starting
    case running
    case exited(Int32?)
    case failedToStart
}

/// Phase 2 单一本地 Terminal 会话的可观察运行状态。
@MainActor
@Observable
final class TerminalSession {
    /// 当前阶段只有一个固定的 Local Terminal。
    let title = "Local"

    /// 从当前 macOS 账户配置解析得到的 login shell 路径。
    let shellPath: String

    /// PTY 子进程当前状态。
    var processState: TerminalProcessState = .starting

    /// SwiftTerm 当前报告的列数。
    var columns = 80

    /// SwiftTerm 当前报告的行数。
    var rows = 24

    /// Shell 通过 OSC 序列报告的窗口标题。
    var terminalTitle: String?

    /// Shell 通过 OSC 7 报告的当前目录 URL。
    var currentDirectory: String?

    init(shellPath: String) {
        self.shellPath = shellPath
    }

    /// 状态栏左侧显示的简洁会话状态。
    var statusText: String {
        switch processState {
        case .starting:
            "Local Terminal · Starting"
        case .running:
            "Local Terminal"
        case let .exited(exitCode):
            if let exitCode {
                "Local Terminal · Exited (\(exitCode))"
            } else {
                "Local Terminal · Exited"
            }
        case .failedToStart:
            "Local Terminal · Failed to Start"
        }
    }

    /// 状态栏右侧显示的 PTY 字符网格尺寸。
    var sizeText: String {
        "\(columns) × \(rows)"
    }
}
