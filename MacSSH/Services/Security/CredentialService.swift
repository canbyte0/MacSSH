import Foundation

/// 业务层唯一的 Secret 入口，负责 UTF-8 转换、凭据类型隔离和安全日志。
struct CredentialService: Sendable {
    static let shared = CredentialService()

    private enum CredentialKind: String, Sendable {
        case password = "ssh-password"
        case privateKeyPassphrase = "private-key-passphrase"
    }

    private let keychainService: KeychainService
    private let serviceNamespace: String

    init(
        keychainService: KeychainService = KeychainService(),
        serviceNamespace: String = "com.macssh.MacSSH.credentials"
    ) {
        self.keychainService = keychainService
        self.serviceNamespace = serviceNamespace
    }

    func savePassword(_ password: String, credentialID: UUID) async throws {
        try await save(password, id: credentialID, kind: .password)
        AppLogger.security.info("Password credential saved")
    }

    func readPassword(credentialID: UUID) async throws -> String {
        do {
            return try await read(id: credentialID, kind: .password)
        } catch {
            AppLogger.security.error("Password credential lookup failed")
            throw error
        }
    }

    func updatePassword(_ password: String, credentialID: UUID) async throws {
        try await update(password, id: credentialID, kind: .password)
        AppLogger.security.info("Password credential updated")
    }

    func upsertPassword(_ password: String, credentialID: UUID) async throws {
        try await upsert(password, id: credentialID, kind: .password)
        AppLogger.security.info("Password credential upserted")
    }

    func deletePassword(credentialID: UUID) async throws {
        try await delete(id: credentialID, kind: .password)
        AppLogger.security.info("Password credential deleted")
    }

    func savePrivateKeyPassphrase(_ passphrase: String, privateKeyID: UUID) async throws {
        try await save(passphrase, id: privateKeyID, kind: .privateKeyPassphrase)
        AppLogger.security.info("Private key passphrase saved")
    }

    func readPrivateKeyPassphrase(privateKeyID: UUID) async throws -> String {
        do {
            return try await read(id: privateKeyID, kind: .privateKeyPassphrase)
        } catch {
            AppLogger.security.error("Private key passphrase lookup failed")
            throw error
        }
    }

    func updatePrivateKeyPassphrase(_ passphrase: String, privateKeyID: UUID) async throws {
        try await update(passphrase, id: privateKeyID, kind: .privateKeyPassphrase)
        AppLogger.security.info("Private key passphrase updated")
    }

    func upsertPrivateKeyPassphrase(_ passphrase: String, privateKeyID: UUID) async throws {
        try await upsert(passphrase, id: privateKeyID, kind: .privateKeyPassphrase)
        AppLogger.security.info("Private key passphrase upserted")
    }

    func deletePrivateKeyPassphrase(privateKeyID: UUID) async throws {
        try await delete(id: privateKeyID, kind: .privateKeyPassphrase)
        AppLogger.security.info("Private key passphrase deleted")
    }

    /// String 仅在调用期间转换为 Data；任何日志都不包含 Secret 或 Data。
    private func save(_ secret: String, id: UUID, kind: CredentialKind) async throws {
        let data = try encoded(secret)
        try await keychainService.save(data, service: service(for: kind), account: account(for: id))
    }

    private func read(id: UUID, kind: CredentialKind) async throws -> String {
        let data = try await keychainService.read(service: service(for: kind), account: account(for: id))
        guard let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return secret
    }

    private func update(_ secret: String, id: UUID, kind: CredentialKind) async throws {
        let data = try encoded(secret)
        try await keychainService.update(data, service: service(for: kind), account: account(for: id))
    }

    private func upsert(_ secret: String, id: UUID, kind: CredentialKind) async throws {
        let data = try encoded(secret)
        try await keychainService.upsert(data, service: service(for: kind), account: account(for: id))
    }

    private func delete(id: UUID, kind: CredentialKind) async throws {
        try await keychainService.delete(service: service(for: kind), account: account(for: id))
    }

    private func encoded(_ secret: String) throws -> Data {
        guard !secret.isEmpty else {
            throw KeychainError.invalidSecret
        }
        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        return data
    }

    private func service(for kind: CredentialKind) -> String {
        "\(serviceNamespace).\(kind.rawValue)"
    }

    private func account(for id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
