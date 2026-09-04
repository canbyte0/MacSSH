import Foundation
import Observation
import SwiftTerm

/// MacSSH 1.1 Phase 7：命令执行来源（History source 字段）。
enum CommandSource: String {
    /// 用户从「常用命令」页点击 Run。
    case savedCommand
    /// 用户从「历史记录」页点击 Run（replay，任务书 §25 / 验收 §39：再新增一条 history）。
    case historyReplay
}

/// MacSSH 1.1 Phase 7：TerminalCommandDispatcher 解析到的当前可写 active terminal 输入目标。
///
/// 用闭包封装 `pasteText` / `sendReturn` / `restoreFocus`，使 Dispatcher 与具体
/// SwiftTerm `TerminalView` 类型解耦——测试可注入 mock 闭包记录调用
/// （Phase 7A 验收 §49：Dispatcher 须有 protocol/接缝供 mock）。
@MainActor
struct ActiveInputTarget {
    /// 以 SwiftTerm paste 语义粘贴文本（bracketed paste + IME 由 SwiftTerm 处理，不附 Return）。
    let pasteText: (String) -> Void
    /// 发送真实 Return 字节（`EscapeSequences.cmdRet = [13]`，与键盘 Return 相同）。
    let sendReturn: () -> Void
    /// 恢复 Terminal firstResponder（任务书 §46 / 验收 §29）。
    let restoreFocus: () -> Void
    /// runtime session UUID（history 快照）。
    let sessionID: UUID
    /// "local" / "remoteSSH"（history 区分来源，不依赖活着的 Session 对象）。
    let sessionKind: String
    /// Remote 时存 host 显示名快照（不含凭据）；Local 为 nil。
    let hostDisplayName: String?
}

/// MacSSH 1.1 Phase 7：统一 Paste / Execute 调度器（任务书 §40 / §45 / Phase 7A 验收 §14）。
///
/// 职责：
/// - 每次 `paste`/`execute` 重新读取 `SessionManager.activeSession`（**不缓存** stale target，
///   任务书 §40 / §42 / 验收 §26）；
/// - 预检 `displayState == .active`（disconnected/connecting/failed → disable，任务书 §44 / 验收 §28）；
/// - Paste：`pasteText(command)`（SwiftTerm paste 语义，不附 Return，不记 history，任务书 §10 / §26）；
/// - Execute：`pasteText(command)` + 真实 Return（任务书 §11 / §12，不走 raw send 绕过 paste semantics）；
/// - Execute 成功发送后 append history（任务书 §27 / 验收 §40），History replay 也 append（§25 / §39）；
/// - 末端 `restoreFocus()`（任务书 §46 / §71）。
///
/// 绝不：keyboard interception / `Terminal.feed()`（P1，任务书 §13 / §23）。
@MainActor
@Observable
final class TerminalCommandDispatcher {
    private let sessionManager: SessionManager
    let historyStore: CommandHistoryStore

    /// active terminal 解析器（生产从 SessionManager 解析；测试可注入 mock）。
    /// 返回 nil 表示当前无可用 active terminal。
    private let resolveActive: @MainActor () -> ActiveInputTarget?

    init(
        sessionManager: SessionManager,
        historyStore: CommandHistoryStore,
        resolveActive: (@MainActor () -> ActiveInputTarget?)? = nil
    ) {
        self.sessionManager = sessionManager
        self.historyStore = historyStore
        if let resolveActive {
            self.resolveActive = resolveActive
        } else {
            self.resolveActive = Self.makeDefaultResolver(sessionManager: sessionManager)
        }
    }

    // MARK: - 可执行性（UI 据此 disable Paste/Execute）

    /// 当前是否有可写的 active terminal session（任务书 §44 / 验收 §28）。
    var canDispatch: Bool {
        guard let session = sessionManager.activeSession else {
            return false
        }
        return session.displayState == .active
    }

    // MARK: - Paste（任务书 §10）

    /// 粘贴命令到当前 active terminal 的 shell 输入位置（不执行）。
    /// 只发送 command text；不附 Return；不记 history（任务书 §26 / §40）。
    func paste(command: String) {
        guard let target = resolveActive() else {
            return // 无可用 active terminal（UI 应已 disable，此处防御）。
        }
        target.pasteText(command)
        target.restoreFocus()
    }

    // MARK: - Execute（任务书 §11）

    /// 执行命令：`pasteText(command)` + 真实 Return，成功发送后 append history。
    ///
    /// append 时机（任务书 §27 / 验收 §40）：预检通过 + 同步发送完成后。
    /// "成功"指字节已交 SwiftTerm input pipeline，不等 shell command exit code
    /// （MacSSH 不等待 shell 结果，验收 §27）。
    func execute(command: String, source: CommandSource) {
        guard let target = resolveActive() else {
            return
        }
        // 1. SwiftTerm paste 语义发送 command text（bracketed paste + IME 由 SwiftTerm 处理）。
        target.pasteText(command)
        // 2. 真实 Return（EscapeSequences.cmdRet = [13] = \r，与键盘 Return 相同）。
        target.sendReturn()
        // 3. 成功发送后 append history（replay 也 append，任务书 §25 / 验收 §39）。
        historyStore.append(
            command: command,
            sessionID: target.sessionID,
            sessionKind: target.sessionKind,
            hostDisplayName: target.hostDisplayName,
            source: source.rawValue
        )
        // 4. 恢复 Terminal firstResponder（任务书 §46 / §71）。
        target.restoreFocus()
    }

    // MARK: - 默认 active 解析器

    /// 生产环境从 `SessionManager.activeSession` 解析当前可写 terminal 输入目标。
    /// 每次 action 实时读取，不缓存 stale target（任务书 §40 / 验收 §26）。
    static func makeDefaultResolver(sessionManager: SessionManager) -> @MainActor () -> ActiveInputTarget? {
        { [weak sessionManager] in
            guard let sessionManager,
                  let session = sessionManager.activeSession,
                  session.displayState == .active
            else {
                return nil
            }
            switch session.kind {
            case .local:
                guard let service = session.localService else { return nil }
                let terminalView = service.terminalView
                return ActiveInputTarget(
                    pasteText: { terminalView.pasteText($0) },
                    sendReturn: { terminalView.send(data: EscapeSequences.cmdRet[...]) },
                    restoreFocus: { service.focusWhenAvailable() },
                    sessionID: session.id,
                    sessionKind: "local",
                    hostDisplayName: nil
                )
            case .remoteSSH:
                guard let service = session.remoteService else { return nil }
                let terminalView = service.terminalView
                return ActiveInputTarget(
                    pasteText: { terminalView.pasteText($0) },
                    sendReturn: { terminalView.send(data: EscapeSequences.cmdRet[...]) },
                    restoreFocus: { service.focusWhenAvailable() },
                    sessionID: session.id,
                    sessionKind: "remoteSSH",
                    hostDisplayName: session.hostDisplayName
                )
            }
        }
    }
}
