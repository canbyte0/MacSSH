import SwiftUI

/// 为尚未接入真实业务能力的 Phase 1 Workspace 提供统一空状态。
struct PlaceholderContentView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
