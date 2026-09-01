import Foundation
import SwiftUI

/// 只记录认证方式；Password 与 Passphrase 始终由 Keychain 独立保存。
enum AuthenticationType: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    /// 让认证方式可直接用于 SwiftUI Picker。
    var id: Self { self }

    /// Host 编辑表单展示的稳定 String Catalog key。
    var titleKey: LocalizedStringKey {
        switch self {
        case .password:
            "authentication.password"
        case .privateKey:
            "authentication.private_key"
        }
    }
}
