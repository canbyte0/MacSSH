import SwiftUI

/// Phase 1 的原生 Toolbar 内容；新建 Session 操作在后续阶段启用。
struct AppToolbarContent: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("MacSSH")
                .font(.headline)
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: {}) {
                Label("New Session", systemImage: "plus")
            }
            .disabled(true)
            .help("New sessions are introduced in a later phase")
            .accessibilityIdentifier("toolbar.newSession")
        }
    }
}
