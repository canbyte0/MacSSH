import Foundation

/// 只记录认证方式；Password 与 Passphrase 始终由 Keychain 独立保存。
enum AuthenticationType: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    /// 让认证方式可直接用于 SwiftUI Picker。
    var id: Self { self }

    /// Host 编辑表单展示的用户可读名称。
    var title: String {
        switch self {
        case .password:
            "Password"
        case .privateKey:
            "Private Key"
        }
    }
}
