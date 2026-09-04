import SwiftData
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 7：SwiftData on-disk 迁移测试（P2 gate，任务书 §36 / Phase 7A 验收 §51/§53）。
///
/// 验证：Phase 6 schema（Host/HostGroup/KnownHost）的 on-disk persistent store
/// 在用 Phase 7 schema（新增 SavedCommandGroup/SavedCommand/CommandHistoryEntry）
/// 打开后，现有数据全部保留——不丢 Host/HostGroup/KnownHost、关系不坏、
/// 新 model 可正常插入/query。
///
/// **不**只用 `isStoredInMemoryOnly=true`（验收 §53 明确禁止）。
/// **不**通过删除数据库解决 migration failure（验收 §36）。
@MainActor
final class SwiftDataMigrationTests: XCTestCase {

    /// Phase 6 等价 schema（不含 Phase 7 model）。
    private let phase6Schema = Schema([
        Host.self,
        HostGroup.self,
        KnownHost.self
    ])

    /// Phase 7 schema（新增 3 个 model）。
    private let phase7Schema = Schema([
        Host.self,
        HostGroup.self,
        KnownHost.self,
        SavedCommandGroup.self,
        SavedCommand.self,
        CommandHistoryEntry.self
    ])

    /// 临时 on-disk store URL。
    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSSHMigrationTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MacSSH.store")
    }

    /// 清理临时 store。
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Migration

    /// Phase 6 store → Phase 7 schema：现有数据全部保留。
    func testPhase6ToPhase7MigrationPreservesExistingData() throws {
        let storeURL = tempStoreURL()
        defer { cleanup(storeURL) }

        // 1. 用 Phase 6 schema 创建 on-disk store，写入业务数据。
        let phase6Config = ModelConfiguration(
            "MigrationTest",
            schema: phase6Schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let phase6Container = try ModelContainer(for: phase6Schema, configurations: [phase6Config])
        let ctx6 = phase6Container.mainContext

        let group = HostGroup(name: "Production Servers")
        ctx6.insert(group)
        let host = Host(name: "web-01", hostname: "10.0.0.1", port: 22, username: "ubuntu", group: group)
        ctx6.insert(host)
        let knownHost = KnownHost(
            hostname: "10.0.0.1", port: 22, keyType: "ssh-ed25519",
            hostKey: Data([0x01, 0x02, 0x03]), fingerprint: "SHA256:abc"
        )
        ctx6.insert(knownHost)
        try ctx6.save()

        let originalHostID = host.id
        let originalGroupID = group.id
        let originalKnownHostID = knownHost.id
        let originalHostName = host.name

        // 释放 Phase 6 container（关闭 store）。
        // SwiftData ModelContainer 不显式 close，但释放引用后 store 可被新 container 重新打开。
        _ = phase6Container // 保持引用直到作用域结束

        // 2. 用 Phase 7 schema 打开同一 on-disk store。
        let phase7Config = ModelConfiguration(
            "MigrationTest",
            schema: phase7Schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let phase7Container = try ModelContainer(for: phase7Schema, configurations: [phase7Config])
        let ctx7 = phase7Container.mainContext

        // 3. 验证现有 Host 不丢。
        let hostDescriptor = FetchDescriptor<MacSSH.Host>(
            predicate: #Predicate { $0.id == originalHostID }
        )
        let migratedHost = try ctx7.fetch(hostDescriptor).first
        XCTAssertNotNil(migratedHost, "Host 丢失：迁移后找不到原有 Host")
        XCTAssertEqual(migratedHost?.name, originalHostName, "Host name 改变")
        XCTAssertEqual(migratedHost?.hostname, "10.0.0.1")

        // 4. 验证 HostGroup 不丢。
        let groupDescriptor = FetchDescriptor<HostGroup>(
            predicate: #Predicate { $0.id == originalGroupID }
        )
        let migratedGroup = try ctx7.fetch(groupDescriptor).first
        XCTAssertNotNil(migratedGroup, "HostGroup 丢失")
        XCTAssertEqual(migratedGroup?.name, "Production Servers")

        // 5. 验证 KnownHost 不丢。
        let knownHostDescriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.id == originalKnownHostID }
        )
        let migratedKnownHost = try ctx7.fetch(knownHostDescriptor).first
        XCTAssertNotNil(migratedKnownHost, "KnownHost 丢失")
        XCTAssertEqual(migratedKnownHost?.fingerprint, "SHA256:abc")

        // 6. 关系不坏：Host.group 仍指向 HostGroup。
        XCTAssertEqual(migratedHost?.group?.id, originalGroupID, "Host-HostGroup 关系断裂")

        // 7. 新 model 可正常插入/query。
        let cmdGroup = SavedCommandGroup(name: "Git", sortOrder: 0)
        ctx7.insert(cmdGroup)
        let cmd = SavedCommand(command: "git status", group: cmdGroup, sortOrder: 0)
        ctx7.insert(cmd)
        let history = CommandHistoryEntry(
            command: "ls", sessionID: UUID(), sessionKind: "local", source: "savedCommand"
        )
        ctx7.insert(history)
        try ctx7.save()

        let cmdDescriptor = FetchDescriptor<SavedCommand>(
            predicate: #Predicate { $0.command == "git status" }
        )
        let savedCmd = try ctx7.fetch(cmdDescriptor).first
        XCTAssertNotNil(savedCmd, "新 SavedCommand 无法插入/query")
        XCTAssertEqual(savedCmd?.group?.name, "Git")

        let historyDescriptor = FetchDescriptor<CommandHistoryEntry>()
        let savedHistory = try ctx7.fetch(historyDescriptor).first
        XCTAssertNotNil(savedHistory, "新 CommandHistoryEntry 无法插入/query")
    }

    /// 空 Phase 6 store → Phase 7 schema：不 crash，正常初始化（验收 §86）。
    func testEmptyPhase6StoreMigratesWithoutCrash() throws {
        let storeURL = tempStoreURL()
        defer { cleanup(storeURL) }

        // 创建空 Phase 6 store。
        let phase6Config = ModelConfiguration(
            "MigrationTest",
            schema: phase6Schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let phase6Container = try ModelContainer(for: phase6Schema, configurations: [phase6Config])
        try phase6Container.mainContext.save()
        _ = phase6Container

        // 用 Phase 7 schema 打开空 store——不 crash。
        let phase7Config = ModelConfiguration(
            "MigrationTest",
            schema: phase7Schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let phase7Container = try ModelContainer(for: phase7Schema, configurations: [phase7Config])
        let ctx7 = phase7Container.mainContext

        // 无数据但可正常插入新 model。
        let entry = CommandHistoryEntry(
            command: "pwd", sessionID: UUID(), sessionKind: "local", source: "savedCommand"
        )
        ctx7.insert(entry)
        try ctx7.save()

        let descriptor = FetchDescriptor<CommandHistoryEntry>()
        let fetched = try ctx7.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.command, "pwd")
    }
}
