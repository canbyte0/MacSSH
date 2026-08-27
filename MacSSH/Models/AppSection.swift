import Foundation

/// Phase 1 Sidebar 支持的顶层页面。
enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case terminal
    case hosts
    case transfers
    case settings

    /// 让枚举值直接作为 SwiftUI List 的稳定标识。
    var id: Self { self }

    /// Sidebar 和状态栏展示的用户可读名称。
    var title: String {
        switch self {
        case .terminal:
            "Local Terminal"
        case .hosts:
            "Hosts"
        case .transfers:
            "Transfers"
        case .settings:
            "Settings"
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
