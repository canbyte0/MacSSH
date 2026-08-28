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
        switch self {
        case .itemNotFound:
            "The credential was not found in macOS Keychain."
        case .duplicateItem:
            "A credential with this identifier already exists."
        case .invalidSecret:
            "The credential cannot be empty."
        case .encodingFailed:
            "The credential could not be prepared for secure storage."
        case .decodingFailed:
            "The stored credential could not be decoded."
        case .accessDenied:
            "macOS Keychain denied access to the credential."
        case .interactionNotAllowed:
            "macOS Keychain interaction is not currently allowed."
        case .keychainUnavailable:
            "macOS Keychain is currently unavailable."
        case .unexpectedStatus:
            "The credential operation could not be completed."
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
