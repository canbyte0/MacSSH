import AppKit
import SwiftTerm

/// MacSSH 1.1 Phase 6：`TerminalHighlightProvider` 协议实现。
///
/// 职责：
/// - 每行查询时按当前 store 设置 + 当前 Terminal Appearance 解析颜色；
/// - 调用 `TerminalHighlightMatcher.matches(...)` 计算 cell range；
/// - **不做**跨帧 range 缓存——renderer 每帧请求当前 line，每行重算，
///   resize / reflow / 规则变更后天然无 stale range（Phase 6A P2 #1 决策）。
///
/// 生命周期：由 `TerminalHighlightCoordinator` 持有（强引用——Coordinator 自身
/// 由 AppState 强持有，view 与 provider 之间为弱引用：view 弱持有 provider）。
@MainActor
final class TerminalHighlightProviderImpl: TerminalHighlightProvider {

    private let store: TerminalHighlightStore

    init(store: TerminalHighlightStore) {
        self.store = store
    }

    func cellHighlights(in terminal: Terminal, row: Int) -> [SwiftTerm.TerminalCellHighlight]? {
        // 全局关闭或无启用规则：返回 nil（renderer 退化为 upstream 行为）。
        guard store.settings.isHighlightEnabled,
              !store.settings.enabledRules.isEmpty else {
            return nil
        }

        // `row` 是与 `buildAttributedString(row:)` 同坐标的 buffer row：
        // 通过 `terminal.getScrollInvariantLine` 取行（含 scrollback），
        // 越界返回 nil。
        guard let line = terminal.getScrollInvariantLine(row: row) else {
            return nil
        }

        let matches = TerminalHighlightMatcher.matches(
            inLine: line,
            terminal: terminal,
            rules: store.settings.enabledRules
        )
        guard !matches.isEmpty else { return nil }

        // 颜色按当前 view Appearance 解析（由 Coordinator 广播重绘带动）。
        let appearance = NSApp?.effectiveAppearance
        return matches.map { match in
            TerminalCellHighlight(startColumn: match.startColumn,
                                  endColumn: match.endColumn,
                                  color: TerminalHighlightPalette.nsColor(for: match.color,
                                                                           appearance: appearance))
        }
    }
}
