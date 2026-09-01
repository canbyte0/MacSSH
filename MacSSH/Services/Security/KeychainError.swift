import Foundation
import Security

/// 将 Security.framework 的 OSStatus 转换为业务层可理解、且不泄露 Secret 的错误。
enum KeychainError: Error, Equatable, LocalizedError, Sendable {
    case itemNotFound
    case duplicateItem
    case invalidSecret
    case encodingFailed
    case decodingFailed
    case accessDenied
    case interactionNotAllowed
    case keychainUnavailable
    case unexpectedStatus(OSStatus)

    /// UI 只展示安全的业务描述；底层状态码只保留在枚举关联值中供诊断使用。
    var errorDescription: String? {
        localizedDescription(locale: Locale(identifier: "en"))
    }

    /// UI 显式传入 App Locale；不改变错误类型或底层安全行为。
    func localizedDescription(locale: Locale) -> String {
        switch self {
        case .itemNotFound:
            L10n.string("error.keychain.item_not_found", defaultValue: "The credential was not found in macOS Keychain.", locale: locale)
        case .duplicateItem:
            L10n.string("error.keychain.duplicate", defaultValue: "A credential with this identifier already exists.", locale: locale)
        case .invalidSecret:
            L10n.string("error.keychain.empty", defaultValue: "The credential cannot be empty.", locale: locale)
        case .encodingFailed:
            L10n.string("error.keychain.encoding", defaultValue: "The credential could not be prepared for secure storage.", locale: locale)
        case .decodingFailed:
            L10n.string("error.keychain.decoding", defaultValue: "The stored credential could not be decoded.", locale: locale)
        case .accessDenied:
            L10n.string("error.keychain.access_denied", defaultValue: "macOS Keychain denied access to the credential.", locale: locale)
        case .interactionNotAllowed:
            L10n.string("error.keychain.interaction_not_allowed", defaultValue: "macOS Keychain interaction is not currently allowed.", locale: locale)
        case .keychainUnavailable:
            L10n.string("error.keychain.unavailable", defaultValue: "macOS Keychain is currently unavailable.", locale: locale)
        case .unexpectedStatus:
            L10n.string("error.keychain.unexpected", defaultValue: "The credential operation could not be completed.", locale: locale)
        }
    }

    /// 集中映射 Security.framework 状态，避免 UI 直接处理难以理解的数字错误码。
    static func from(status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound:
            .itemNotFound
        case errSecDuplicateItem:
            .duplicateItem
        case errSecAuthFailed, errSecUserCanceled:
            .accessDenied
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        case errSecNotAvailable, errSecNoDefaultKeychain:
            .keychainUnavailable
        default:
            .unexpectedStatus(status)
        }
    }
}
