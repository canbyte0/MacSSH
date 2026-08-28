import Foundation
import Security

/// 统一封装 SecItem API；所有阻塞 Keychain 调用都在专用串行队列执行。
final class KeychainService: @unchecked Sendable {
    private let queue: DispatchQueue

    init(queueLabel: String = "com.macssh.MacSSH.keychain") {
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    /// 新增 Generic Password 类型的 Keychain item。
    func save(_ data: Data, service: String, account: String) async throws {
        try await perform {
            var attributes = Self.baseQuery(service: service, account: account)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.from(status: status)
            }
        }
    }

    /// 读取唯一匹配 item 的加密数据。
    func read(service: String, account: String) async throws -> Data {
        try await perform {
            var query = Self.baseQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                throw KeychainError.from(status: status)
            }
            guard let data = result as? Data else {
                throw KeychainError.decodingFailed
            }
            return data
        }
    }

    /// 更新已有 item 的 Secret 数据，不改变其稳定 service/account 标识。
    func update(_ data: Data, service: String, account: String) async throws {
        try await perform {
            let query = Self.baseQuery(service: service, account: account)
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]

            let status = SecItemUpdate(
                query as CFDictionary,
                attributesToUpdate as CFDictionary
            )
            guard status == errSecSuccess else {
                throw KeychainError.from(status: status)
            }
        }
    }

    /// 删除唯一匹配的 item；不存在时明确返回 itemNotFound。
    func delete(service: String, account: String) async throws {
        try await perform {
            let query = Self.baseQuery(service: service, account: account)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError.from(status: status)
            }
        }
    }

    /// 供需要幂等写入的调用方使用；优先更新，不存在时再新增。
    func upsert(_ data: Data, service: String, account: String) async throws {
        do {
            try await update(data, service: service, account: account)
        } catch KeychainError.itemNotFound {
            do {
                try await save(data, service: service, account: account)
            } catch KeychainError.duplicateItem {
                // 处理查询与新增之间极短窗口内出现的同标识 item。
                try await update(data, service: service, account: account)
            }
        }
    }

    /// Password 与 Passphrase 都使用 Generic Password；service/account 共同形成稳定唯一键。
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    /// Apple 的 SecItem API 会阻塞；使用 continuation 将结果安全返回 async 调用方。
    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
