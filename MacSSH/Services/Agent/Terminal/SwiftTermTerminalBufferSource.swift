import Foundation
import SwiftTerm

/// pinned SwiftTerm 的 buffer 适配实现（任务书 §10：不得修改 fork）。
///
/// 只使用 public API：
/// - `Terminal.rows` / `Terminal.cols`
/// - `Terminal.isCurrentBufferAlternate`
/// - `Terminal.getScrollInvariantLine(row:)`（活动 buffer，alt screen 时即 alt buffer，§16）
/// - `BufferLine.translateToString(trimRight:)`（纯文本，§15）
/// - `TerminalView.getSelection()`（§17）
@MainActor
struct SwiftTermTerminalBufferSource: AgentTerminalBufferSource {
    private let terminal: Terminal
    private let selectionProvider: (@MainActor () -> String?)?

    init(terminal: Terminal, selectionProvider: (@MainActor () -> String?)? = nil) {
        self.terminal = terminal
        self.selectionProvider = selectionProvider
    }

    var rows: Int { Int(terminal.rows) }

    var columns: Int { Int(terminal.cols) }

    var isAlternateScreen: Bool { terminal.isCurrentBufferAlternate }

    var selectedText: String? { selectionProvider?() }

    var firstValidRow: Int { Int(terminal.buffer.totalLinesTrimmed) }

    func line(atScrollInvariantRow row: Int) -> AgentTerminalLine? {
        guard let line = terminal.getScrollInvariantLine(row: row) else {
            return nil
        }
        // `skipNullCellsFollowingWide`：宽字符（CJK / Emoji）占 2 cell，
        // 后续 padding cell 是 NUL，必须跳过才能得到干净的纯文本。
        return AgentTerminalLine(
            text: line.translateToString(trimRight: true, skipNullCellsFollowingWide: true),
            isWrapped: line.isWrapped
        )
    }
}
