import SwiftUI

/// Phase 1 的 Transfers 空状态，不创建 TransferTask 或后台任务。
struct TransferListView: View {
    var body: some View {
        PlaceholderContentView(
            systemImage: "arrow.up.arrow.down",
            title: "Transfers",
            message: "Transfer activity will appear in a later phase"
        )
        .navigationTitle("Transfers")
        .accessibilityIdentifier("workspace.transfers")
    }
}
