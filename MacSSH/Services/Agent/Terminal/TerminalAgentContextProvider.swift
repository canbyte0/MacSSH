import Foundation
import SwiftTerm

/// 按 `sessionID` 提供会话句柄（任务书 §6）。
///
/// 实现必须只按显式 sessionID 查找，绝不使用 `activeSession` /
/// selectedTab / 当前可见会话推断目标。
@MainActor
protocol AgentTerminalSessionProviding {
    func session(for sessionID: UUID) -> AgentTerminalSessionHandle?
    /// 提取 bounded context snapshot；session 不存在返回 nil（§6）。
    func snapshot(for sessionID: UUID) -> AgentTerminalContext?
}

/// Terminal context provider（任务书 §6/§7/§8/§9/§16/§17）。
///
/// - 目标会话只由显式 `sessionID` 决定，关闭/不存在 → 调用方得到 nil
///   （router 映射为 `sessionUnavailable`），绝不 fallback 到其他会话；
/// - 所有 SwiftTerm 访问发生在 MainActor，返回后只剩 value snapshot；
/// - Local 与 Remote 共用同一提取路径（§8），Remote 只读取 view 已存在
///   的 buffer / selection / cwd 状态，绝不触发 SFTP / SSH exec / 新 channel。
@MainActor
final class TerminalAgentContextProvider: AgentTerminalSessionProviding {
    private let handleLookup: (UUID) -> AgentTerminalSessionHandle?

    init(handleLookup: @escaping @MainActor (UUID) -> AgentTerminalSessionHandle?) {
        self.handleLookup = handleLookup
    }

    /// 生产装配：直接绑定 `SessionManager` 的按 id 查找（§6）。
    convenience init(sessionManager: SessionManager) {
        self.init { sessionID in
            guard let session = sessionManager.session(withID: sessionID) else {
                return nil
            }
            return AgentTerminalSessionHandle(session: session)
        }
    }

    func session(for sessionID: UUID) -> AgentTerminalSessionHandle? {
        handleLookup(sessionID)
    }

    /// 提取 bounded context snapshot。
    ///
    /// 返回 nil 只表示 session 不存在（§6）。
    func snapshot(for sessionID: UUID) -> AgentTerminalContext? {
        guard let handle = handleLookup(sessionID) else {
            return nil
        }

        var rows = 0
        var columns = 0
        var alternateScreen = false
        var selectedText: String?
        var selectionTruncated = false
        var recent = AgentBoundedText.empty

        if let source = handle.bufferSource {
            rows = source.rows
            columns = source.columns
            alternateScreen = source.isAlternateScreen

            if let selection = source.selectedText, !selection.isEmpty {
                let bounded = AgentUTF8Truncator.truncate(
                    selection,
                    byteLimit: AgentTextLimits.selectionMaxBytes
                )
                selectedText = bounded.text
                selectionTruncated = bounded.truncated
            }

            // §4：recent output 只能使用总预算扣除 selection 后的剩余部分。
            let budget = AgentTextLimits.terminalTextualPayloadMaxBytes - boundedBytes(of: selectedText)
            recent = TerminalRecentOutputSnapshotter.snapshot(source: source, byteBudget: budget)
        }

        return AgentTerminalContext(
            sessionID: handle.id,
            sessionKind: handle.sessionKind,
            targetDisplayName: handle.displayName,
            workingDirectory: handle.workingDirectory,
            rows: rows,
            columns: columns,
            selectedText: selectedText,
            recentOutput: recent.text,
            alternateScreen: alternateScreen,
            selectionTruncated: selectionTruncated,
            outputTruncated: recent.truncated
        )
    }

    /// 只取 cwd 元信息，绝不触碰 terminal buffer（§19）。
    func currentDirectory(for sessionID: UUID) -> AgentCurrentDirectoryResult? {
        guard let handle = handleLookup(sessionID) else {
            return nil
        }
        return AgentCurrentDirectoryResult(
            sessionID: handle.id,
            workingDirectory: handle.workingDirectory
        )
    }

    private func boundedBytes(of text: String?) -> Int {
        guard let text else { return 0 }
        return AgentUTF8Truncator.byteCount(of: text)
    }
}

extension AgentTerminalSessionHandle {
    /// 从 `ManagedTerminalSession` 构造句柄（§9：Local / Remote 同一语义）。
    ///
    /// cwd 只来自结构化上报：OSC 7 → authoritative；无上报 → unavailable。
    /// 绝不 fallback HOME / App 进程 cwd / SFTP session default。
    @MainActor
    init(session: ManagedTerminalSession) {
        id = session.id
        switch session.kind {
        case .local:
            sessionKind = .local
            // 与 Phase 10B 展示层一致：Local 技术名不本地化。
            displayName = "Local"
            workingDirectory = AgentWorkingDirectory.fromOSC7URL(
                session.localService?.session.currentDirectory
            )
            if let view = session.localService?.terminalView {
                bufferSource = SwiftTermTerminalBufferSource(terminal: view.terminal) {
                    view.getSelection()
                }
            } else {
                bufferSource = nil
            }
        case .remoteSSH:
            sessionKind = .remoteSSH
            displayName = session.hostDisplayName ?? session.hostname ?? "SSH"
            workingDirectory = AgentWorkingDirectory.fromOSC7URL(
                session.remoteService?.session.currentDirectory
            )
            if let view = session.remoteService?.terminalView {
                bufferSource = SwiftTermTerminalBufferSource(terminal: view.terminal) {
                    view.getSelection()
                }
            } else {
                bufferSource = nil
            }
        }
    }
}
