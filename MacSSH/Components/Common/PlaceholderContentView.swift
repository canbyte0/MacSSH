import SwiftUI

/// 为尚未接入真实业务能力的 Phase 1 Workspace 提供统一空状态。
/// `title` / `message` 为 String Catalog key，由 SwiftUI 自动按当前
/// 注入的 `.environment(\.locale, ...)` 解析。
struct PlaceholderContentView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

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
