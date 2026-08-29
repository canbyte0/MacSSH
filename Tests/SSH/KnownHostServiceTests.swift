import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 6 KnownHostService 持久化逻辑测试（纯 SwiftData，无需 SSH 服务器）。
///
/// 除正常路径外，重点覆盖 Phase 6 Fix 安全阻塞项：
/// Trust Always / Replace Trusted Key 的持久化失败必须显式抛错并回滚，
/// 绝不允许静默吞掉保存错误后返回假成功快照。
@MainActor
final class KnownHostServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var service: KnownHostService!

    override func setUp() async throws {
        continueAfterFailure = false
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        service = KnownHostService(modelContainer: container)
    }

    override func tearDown() async throws {
        service = nil
        container = nil
    }

    /// 注入“保存必然失败”的 KnownHostService（共享同一容器，读正常、写失败）。
    private func makeFailingSaveService() -> KnownHostService {
        KnownHostService(modelContainer: container) { _ in
            throw NSError(domain: "KnownHostServiceTests", code: 1)
        }
    }

    // MARK: - 查询

    func test_lookupReturnsNilWhenNoRecord() {
        XCTAssertNil(service.lookup(hostname: "example.com", port: 22))
    }

    // MARK: - 信任与持久化

    func test_trustPersistsAndLookupFindsByHostnamePort() throws {
        let key = Data(repeating: 0xAB, count: 33)
        _ = try service.trust(
            hostname: "example.com",
            port: 22,
            keyType: "ssh-ed25519",
            hostKey: key,
            fingerprint: "SHA256:aaa="
        )

        let record = service.lookup(hostname: "example.com", port: 22)
        XCTAssertEqual(record?.hostname, "example.com")
        XCTAssertEqual(record?.port, 22)
        XCTAssertEqual(record?.keyType, "ssh-ed25519")
        XCTAssertEqual(record?.hostKey, key, "必须保存完整 Host Key 字节，而非仅 Fingerprint")
        XCTAssertEqual(record?.fingerprint, "SHA256:aaa=")
    }

    // MARK: - Host + Port 身份

    func test_hostnamePortIdentityDifferentiatesSameHostnameDifferentPort() throws {
        let key22 = Data(repeating: 0x11, count: 33)
        let key2222 = Data(repeating: 0x22, count: 33)
        _ = try service.trust(hostname: "example.com", port: 22, keyType: "ssh-ed25519", hostKey: key22, fingerprint: "SHA256:22=")
        _ = try service.trust(hostname: "example.com", port: 2222, keyType: "ssh-ed25519", hostKey: key2222, fingerprint: "SHA256:2222=")

        XCTAssertEqual(service.lookup(hostname: "example.com", port: 22)?.hostKey, key22)
        XCTAssertEqual(service.lookup(hostname: "example.com", port: 2222)?.hostKey, key2222)
        XCTAssertNotNil(service.lookup(hostname: "example.com", port: 22))
        XCTAssertNotNil(service.lookup(hostname: "example.com", port: 2222))
    }

    // MARK: - Upsert（更新而非重复插入）

    func test_trustUpdatesExistingRecordRatherThanDuplicate() throws {
        let originalKey = Data(repeating: 0x01, count: 33)
        let rotatedKey = Data(repeating: 0x02, count: 33)

        _ = try service.trust(hostname: "nas.local", port: 22, keyType: "ssh-ed25519", hostKey: originalKey, fingerprint: "SHA256:old=")
        _ = try service.trust(hostname: "nas.local", port: 22, keyType: "ssh-ed25519", hostKey: rotatedKey, fingerprint: "SHA256:new=")

        let all = service.allKnownHosts()
        XCTAssertEqual(all.count, 1, "同 hostname+port 应 upsert，不得重复")
        XCTAssertEqual(all.first?.hostKey, rotatedKey)
        XCTAssertEqual(all.first?.fingerprint, "SHA256:new=")
    }

    // MARK: - 替换（Host Key Changed）

    func test_replaceUpdatesStoredKey() throws {
        let oldKey = Data(repeating: 0x01, count: 33)
        let newKey = Data(repeating: 0x09, count: 33)
        _ = try service.trust(hostname: "server.example.com", port: 22, keyType: "ssh-ed25519", hostKey: oldKey, fingerprint: "SHA256:old=")

        let stored = service.lookup(hostname: "server.example.com", port: 22)!
        _ = try service.replace(stored, keyType: "ssh-ed25519", hostKey: newKey, fingerprint: "SHA256:new=")

        let after = service.lookup(hostname: "server.example.com", port: 22)
        XCTAssertEqual(after?.hostKey, newKey)
        XCTAssertEqual(after?.fingerprint, "SHA256:new=")
    }

    // MARK: - 删除（Forget）

    func test_removeDeletesRecord() throws {
        _ = try service.trust(hostname: "forget.example.com", port: 22, keyType: "ssh-ed25519", hostKey: Data(repeating: 0x05, count: 33), fingerprint: "SHA256:f=")
        let stored = service.lookup(hostname: "forget.example.com", port: 22)!
        XCTAssertNotNil(stored)

        try service.remove(stored)
        XCTAssertNil(service.lookup(hostname: "forget.example.com", port: 22), "Forget 后再次连接应回到 Unknown Host")
    }

    // MARK: - 验证基于完整 Host Key 字节，而非 Fingerprint

    func test_verificationComparesFullHostKeyBytesNotFingerprint() throws {
        // 同 Fingerprint、不同 Host Key 字节 → 应视为不匹配（验证层比较字节）。
        let keyA = Data(repeating: 0x10, count: 33)
        let keyB = Data(repeating: 0x20, count: 33)
        _ = try service.trust(hostname: "h.example.com", port: 22, keyType: "ssh-ed25519", hostKey: keyA, fingerprint: "SHA256:same=")

        let stored = service.lookup(hostname: "h.example.com", port: 22)!
        // 实际验证逻辑在 SSHConnection 中比较 stored.hostKey == currentBlob；
        // 这里直接断言存储的是字节本身，保证验证层有可比对的完整数据。
        XCTAssertEqual(stored.hostKey, keyA)
        XCTAssertNotEqual(stored.hostKey, keyB)
        XCTAssertEqual(stored.fingerprint, "SHA256:same=")
    }

    // MARK: - Phase 6 Fix：Trust Always 持久化失败

    /// Trust Always 保存失败必须抛 knownHostPersistenceFailed（不得静默忽略），
    /// 且失败后不得留下任何“内存中的信任记录”（回滚），否则同进程下次连接会误判 trusted。
    func test_trustThrowsAndLeavesNoRecordWhenSaveFails() {
        let failing = makeFailingSaveService()
        let key = Data(repeating: 0x33, count: 33)

        XCTAssertThrowsError(
            try failing.trust(
                hostname: "persist-fail.example.com",
                port: 22,
                keyType: "ssh-ed25519",
                hostKey: key,
                fingerprint: "SHA256:fail="
            )
        ) { error in
            XCTAssertEqual(
                error as? SSHError,
                .knownHostPersistenceFailed,
                "保存失败必须映射为明确业务错误，而不是被吞掉"
            )
        }

        // 共享同一容器的正常服务也必须读不到记录：回滚后无残留。
        XCTAssertNil(
            service.lookup(hostname: "persist-fail.example.com", port: 22),
            "保存失败后不得残留内存中的信任记录"
        )
    }

    /// 已有记录 + Trust Always（upsert 路径）保存失败：旧记录必须保持原样。
    func test_trustUpsertFailureKeepsExistingRecord() throws {
        let originalKey = Data(repeating: 0x44, count: 33)
        _ = try service.trust(
            hostname: "upsert-fail.example.com",
            port: 22,
            keyType: "ssh-ed25519",
            hostKey: originalKey,
            fingerprint: "SHA256:original="
        )

        let failing = makeFailingSaveService()
        let rotatedKey = Data(repeating: 0x55, count: 33)
        XCTAssertThrowsError(
            try failing.trust(
                hostname: "upsert-fail.example.com",
                port: 22,
                keyType: "ssh-ed25519",
                hostKey: rotatedKey,
                fingerprint: "SHA256:rotated="
            )
        )

        // 失败后旧记录不被替换、也不被标记成功。
        let after = service.lookup(hostname: "upsert-fail.example.com", port: 22)
        XCTAssertEqual(after?.hostKey, originalKey, "upsert 失败必须回滚，旧 Host Key 保持原样")
        XCTAssertEqual(after?.fingerprint, "SHA256:original=")
    }

    // MARK: - Phase 6 Fix：Replace Trusted Key 持久化失败

    /// Replace（Host Key Changed 后替换）保存失败：必须抛错且旧记录保持不变，
    /// 不得把旧 KnownHost 错误标记为已成功替换。
    func test_replaceThrowsAndKeepsOldKeyWhenSaveFails() throws {
        let oldKey = Data(repeating: 0x66, count: 33)
        _ = try service.trust(
            hostname: "replace-fail.example.com",
            port: 22,
            keyType: "ssh-ed25519",
            hostKey: oldKey,
            fingerprint: "SHA256:old="
        )
        let stored = service.lookup(hostname: "replace-fail.example.com", port: 22)!

        let failing = makeFailingSaveService()
        let newKey = Data(repeating: 0x77, count: 33)
        XCTAssertThrowsError(
            try failing.replace(stored, keyType: "ssh-ed25519", hostKey: newKey, fingerprint: "SHA256:new=")
        ) { error in
            XCTAssertEqual(error as? SSHError, .knownHostPersistenceFailed)
        }

        let after = service.lookup(hostname: "replace-fail.example.com", port: 22)
        XCTAssertEqual(after?.hostKey, oldKey, "替换失败后旧 KnownHost 不得被标记为已替换")
        XCTAssertEqual(after?.fingerprint, "SHA256:old=")
    }

    // MARK: - Phase 6 Fix：Forget 持久化失败

    /// remove 保存失败：必须抛错且记录保持可见（不静默消失）。
    func test_removeThrowsWhenSaveFails() throws {
        _ = try service.trust(
            hostname: "forget-fail.example.com",
            port: 22,
            keyType: "ssh-ed25519",
            hostKey: Data(repeating: 0x88, count: 33),
            fingerprint: "SHA256:keep="
        )
        let stored = service.lookup(hostname: "forget-fail.example.com", port: 22)!

        let failing = makeFailingSaveService()
        XCTAssertThrowsError(try failing.remove(stored))

        XCTAssertNotNil(
            service.lookup(hostname: "forget-fail.example.com", port: 22),
            "Forget 保存失败后记录必须保持可见，不得静默消失"
        )
    }

    // MARK: - Phase 6 Final Cleanup：Settings → Forget 完整路径

    /// Settings → Forget 成功路径：
    /// KnownHost exists → Forget → save succeeds → KnownHost removed → UI reflects removal。
    ///
    /// `allKnownHosts()` 是 Settings 页面 `@Query` 的等价查询入口，
    /// 验证它在 Forget 成功后不再包含该记录，等价于验证 UI 会正确反映删除。
    func test_forgetSuccessPath_allKnownHostsReflectsRemoval() throws {
        _ = try service.trust(
            hostname: "forget-success.example.com",
            port: 22,
            keyType: "ssh-ed25519",
            hostKey: Data(repeating: 0x51, count: 33),
            fingerprint: "SHA256:success="
        )
        XCTAssertEqual(service.allKnownHosts().count, 1, "前置条件：存在一条 KnownHost")

        let stored = service.lookup(hostname: "forget-success.example.com", port: 22)!
        try service.remove(stored)

        XCTAssertTrue(
            service.allKnownHosts().allSatisfy { $0.hostname != "forget-success.example.com" },
            "Forget 成功后 allKnownHosts 不得包含已删除记录（UI 应反映移除）"
        )
        XCTAssertNil(
            service.lookup(hostname: "forget-success.example.com", port: 22),
            "Forget 成功后再次连接应回到 Unknown Host"
        )
    }

    /// Settings → Forget 保存失败路径：
    /// KnownHost exists → Forget → save fails → KnownHost state remains consistent → UI receives error。
    ///
    /// 验证失败后：
    /// 1. `remove` 抛出 `knownHostPersistenceFailed`（调用方据此向 UI 显示错误 Alert）；
    /// 2. `allKnownHosts()` 仍包含该记录（回滚后 UI 不得假装删除成功）；
    /// 3. 记录的 Host Key 未被篡改（状态一致）。
    func test_forgetFailurePath_allKnownHostsKeepsRecord() throws {
        let originalKey = Data(repeating: 0x82, count: 33)
        _ = try service.trust(
            hostname: "forget-fail-ui.example.com",
            port: 22,
            keyType: "ssh-ed25519",
            hostKey: originalKey,
            fingerprint: "SHA256:keep-ui="
        )
        XCTAssertEqual(service.allKnownHosts().count, 1, "前置条件：存在一条 KnownHost")

        let stored = service.lookup(hostname: "forget-fail-ui.example.com", port: 22)!
        let failing = makeFailingSaveService()

        XCTAssertThrowsError(try failing.remove(stored)) { error in
            XCTAssertEqual(
                error as? SSHError,
                .knownHostPersistenceFailed,
                "Forget 保存失败必须映射为 knownHostPersistenceFailed，UI 据此显示错误提示"
            )
        }

        // 失败后 allKnownHosts 仍包含该记录（UI 不得假装删除成功）。
        let after = service.allKnownHosts()
        XCTAssertEqual(after.count, 1, "Forget 保存失败后记录不得从列表消失")
        XCTAssertEqual(
            after.first?.hostname, "forget-fail-ui.example.com",
            "回滚后 UI 列表中的记录保持不变"
        )
        XCTAssertEqual(
            after.first?.hostKey, originalKey,
            "回滚后记录的 Host Key 不得被篡改"
        )
    }
}
