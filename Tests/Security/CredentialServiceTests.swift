import XCTest
@testable import MacSSH

/// 使用隔离的 service namespace 对真实 macOS Keychain 执行生命周期测试。
final class CredentialServiceTests: XCTestCase {
    private var credentialService: CredentialService!
    private var identifiers: Set<UUID> = []

    override func setUp() {
        super.setUp()
        let namespace = "com.macssh.MacSSH.tests.\(UUID().uuidString.lowercased())"
        credentialService = CredentialService(
            keychainService: KeychainService(queueLabel: "\(namespace).queue"),
            serviceNamespace: namespace
        )
    }

    override func tearDown() async throws {
        // 测试失败时也尽力清理隔离 namespace 下的临时 Keychain items。
        for identifier in identifiers {
            try? await credentialService.deletePassword(credentialID: identifier)
            try? await credentialService.deletePrivateKeyPassphrase(privateKeyID: identifier)
        }
        credentialService = nil
        identifiers.removeAll()
        try await super.tearDown()
    }

    func testPasswordSaveReadUpdateDeleteLifecycle() async throws {
        let identifier = trackedIdentifier()
        let initialSecret = "password-initial-\(UUID().uuidString)"
        let updatedSecret = "password-updated-\(UUID().uuidString)"

        try await credentialService.savePassword(initialSecret, credentialID: identifier)
        let savedPassword = try await credentialService.readPassword(credentialID: identifier)
        XCTAssertEqual(savedPassword, initialSecret)

        try await credentialService.updatePassword(updatedSecret, credentialID: identifier)
        let updatedPassword = try await credentialService.readPassword(credentialID: identifier)
        XCTAssertEqual(updatedPassword, updatedSecret)

        try await credentialService.deletePassword(credentialID: identifier)
        await assertItemNotFound {
            _ = try await self.credentialService.readPassword(credentialID: identifier)
        }
    }

    func testPrivateKeyPassphraseSaveReadUpdateDeleteLifecycle() async throws {
        let identifier = trackedIdentifier()
        let initialSecret = "passphrase-initial-\(UUID().uuidString)"
        let updatedSecret = "passphrase-updated-\(UUID().uuidString)"

        try await credentialService.savePrivateKeyPassphrase(
            initialSecret,
            privateKeyID: identifier
        )
        let savedPassphrase = try await credentialService.readPrivateKeyPassphrase(
            privateKeyID: identifier
        )
        XCTAssertEqual(savedPassphrase, initialSecret)

        try await credentialService.updatePrivateKeyPassphrase(
            updatedSecret,
            privateKeyID: identifier
        )
        let updatedPassphrase = try await credentialService.readPrivateKeyPassphrase(
            privateKeyID: identifier
        )
        XCTAssertEqual(updatedPassphrase, updatedSecret)

        try await credentialService.deletePrivateKeyPassphrase(privateKeyID: identifier)
        await assertItemNotFound {
            _ = try await self.credentialService.readPrivateKeyPassphrase(privateKeyID: identifier)
        }
    }

    func testPasswordAndPassphraseUseDistinctKeychainServices() async throws {
        let sharedIdentifier = trackedIdentifier()
        let password = "isolated-password-\(UUID().uuidString)"
        let passphrase = "isolated-passphrase-\(UUID().uuidString)"

        try await credentialService.savePassword(password, credentialID: sharedIdentifier)
        try await credentialService.savePrivateKeyPassphrase(
            passphrase,
            privateKeyID: sharedIdentifier
        )

        let storedPassword = try await credentialService.readPassword(
            credentialID: sharedIdentifier
        )
        let storedPassphrase = try await credentialService.readPrivateKeyPassphrase(
            privateKeyID: sharedIdentifier
        )
        XCTAssertEqual(storedPassword, password)
        XCTAssertEqual(storedPassphrase, passphrase)
    }

    func testDuplicateAndEmptyCredentialErrorsAreMapped() async throws {
        let identifier = trackedIdentifier()
        let secret = "duplicate-check-\(UUID().uuidString)"

        try await credentialService.savePassword(secret, credentialID: identifier)

        do {
            try await credentialService.savePassword(secret, credentialID: identifier)
            XCTFail("A duplicate Keychain item should not be accepted.")
        } catch let error as KeychainError {
            XCTAssertEqual(error, .duplicateItem)
        }

        do {
            try await credentialService.updatePassword("", credentialID: identifier)
            XCTFail("An empty credential should not be accepted.")
        } catch let error as KeychainError {
            XCTAssertEqual(error, .invalidSecret)
        }
    }

    /// 端到端验收时由环境变量提供 production namespace 的临时 credentialID 与期望状态。
    func testConfiguredProductionPasswordState() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let identifierText = environment["MACSSH_VERIFY_CREDENTIAL_ID"],
            let identifier = UUID(uuidString: identifierText),
            let expectation = environment["MACSSH_VERIFY_EXPECTATION"]
        else {
            throw XCTSkip("Production credential verification was not requested.")
        }

        let productionService = CredentialService()
        switch expectation {
        case "present":
            guard let expectedSecret = environment["MACSSH_VERIFY_SECRET"] else {
                XCTFail("A present credential check requires an expected test value.")
                return
            }
            let storedSecret = try await productionService.readPassword(credentialID: identifier)
            // 只报告是否匹配，失败信息也不回显任一 Secret。
            XCTAssertTrue(storedSecret == expectedSecret, "Stored credential did not match.")
        case "missing":
            await assertItemNotFound {
                _ = try await productionService.readPassword(credentialID: identifier)
            }
        default:
            XCTFail("Unsupported production credential expectation.")
        }
    }

    private func trackedIdentifier() -> UUID {
        let identifier = UUID()
        identifiers.insert(identifier)
        return identifier
    }

    private func assertItemNotFound(
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("The deleted Keychain item should not be readable.")
        } catch let error as KeychainError {
            XCTAssertEqual(error, .itemNotFound)
        } catch {
            XCTFail("Expected KeychainError.itemNotFound.")
        }
    }
}
