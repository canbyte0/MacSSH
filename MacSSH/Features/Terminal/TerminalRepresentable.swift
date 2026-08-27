import SwiftUI
import SwiftTerm

/// 将 SwiftTerm 的 AppKit LocalProcessTerminalView 包装为 SwiftUI View。
struct TerminalRepresentable: NSViewRepresentable {
    /// Service 由 AppState 持有，因此切换 Sidebar 不会意外销毁本地 Shell。
    let service: LocalTerminalService

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        service.startIfNeeded()
        service.focusWhenAvailable()
        return service.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // SwiftTerm 在 setFrameSize 中自动计算 cols/rows 并同步 PTY Resize。
        guard nsView.window != nil else {
            return
        }

        service.focusWhenAvailable()
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Void) {
        // 会话属于 AppState，而非临时 SwiftUI 页面；切换 Sidebar 时保持运行。
        nsView.window?.makeFirstResponder(nil)
    }
}
