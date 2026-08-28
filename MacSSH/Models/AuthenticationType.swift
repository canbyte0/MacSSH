import Foundation

/// Phase 3 只记录认证方式，不保存密码、Passphrase 或私钥内容。
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
