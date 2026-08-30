import SwiftUI
import SwiftTerm

/// 将 SwiftTerm 的 AppKit `TerminalView` 包装为 SwiftUI View（Remote SSH Terminal）。
///
/// 与 Phase 2 的 `TerminalRepresentable` 同构：Service 由 AppState 持有，
/// 切换 Sidebar / Tab 不会销毁远端 Shell。
struct RemoteTerminalRepresentable: NSViewRepresentable {
    let service: RemoteTerminalService

    func makeNSView(context: Context) -> TerminalView {
        service.startIfNeeded()
        service.focusWhenAvailable()
        return service.terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // SwiftTerm 在 setFrameSize 中自动计算 cols/rows；
        // sizeChanged 委托会把真实尺寸同步给 Remote PTY。
        guard nsView.window != nil else {
            return
        }

        service.focusWhenAvailable()
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Void) {
        // 会话属于 AppState，而非临时 SwiftUI 页面；切换 Sidebar 时保持运行。
        nsView.window?.makeFirstResponder(nil)
    }
}
