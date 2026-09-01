import Foundation
import SwiftUI

/// Phase 1 Sidebar 支持的顶层页面。
enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case terminal
    case hosts
    case transfers
    case settings

    /// 让枚举值直接作为 SwiftUI List 的稳定标识。
    var id: Self { self }

    /// Sidebar 使用的稳定 String Catalog key。
    var titleKey: LocalizedStringKey {
        switch self {
        case .terminal:
            "sidebar.local_terminal"
        case .hosts:
            "sidebar.hosts"
        case .transfers:
            "sidebar.transfers"
        case .settings:
            "sidebar.settings"
        }
    }

    /// 状态栏需要普通 String，按当前 App Locale 动态解析。
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .terminal:
            L10n.string("sidebar.local_terminal", defaultValue: "Local Terminal", locale: locale)
        case .hosts:
            L10n.string("sidebar.hosts", defaultValue: "Hosts", locale: locale)
        case .transfers:
            L10n.string("sidebar.transfers", defaultValue: "Transfers", locale: locale)
        case .settings:
            L10n.string("sidebar.settings", defaultValue: "Settings", locale: locale)
        }
    }

    /// 使用系统 SF Symbols，避免引入自定义图标资源。
    var systemImage: String {
        switch self {
        case .terminal:
            "terminal"
        case .hosts:
            "server.rack"
        case .transfers:
            "arrow.up.arrow.down"
        case .settings:
            "gearshape"
        }
    }
}
