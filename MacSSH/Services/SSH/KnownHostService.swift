import Foundation
import SwiftData

/// KnownHost 的持久化操作入口。
///
/// 只负责 SwiftData 读写；Host Key 字节比较由 `SSHConnection` 在 actor 内完成
/// （比较 `KnownHostRecord.hostKey` 与握手取得的 `hostKeyBlob`）。
/// 不创建复杂 Repository/Factory 层，目标结构为 `SSHConnection → KnownHostService → SwiftData`。
///
/// Host Key、Fingerprint、Hostname、Port 都不是 Secret，存 SwiftData 而非 Keychain。
@MainActor
final class KnownHostService {
    /// 持久化动作的注入点。
    ///
    /// 生产环境默认执行 `context.save()`；测试可注入失败以覆盖
    /// “信任决策落盘失败必须中止认证”的安全路径。
    /// 这是 Phase 6 安全修复要求的最小可测试设计，不引入 Repository 层。
    typealias SaveAction = (ModelContext) throws -> Void

    private let modelContainer: ModelContainer
    private let saveAction: SaveAction

    init(
        modelContainer: ModelContainer,
        saveAction: @escaping SaveAction = { try $0.save() }
    ) {
        self.modelContainer = modelContainer
        self.saveAction = saveAction
    }

    // MARK: - 查询

    /// 按 `hostname + port` 查找已保存的 KnownHost；返回 Sendable 快照。
    /// 没有匹配记录时返回 nil（对应“未知主机”）。
    func lookup(hostname: String, port: Int) -> KnownHostRecord? {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.hostname == hostname && $0.port == port }
        )
        guard let stored = try? context.fetch(descriptor).first else {
            return nil
        }
        return KnownHostRecord(from: stored)
    }

    /// 所有已信任主机（供 Settings → Known Hosts 管理）。
    func allKnownHosts() -> [KnownHostRecord] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<KnownHost>(
            sortBy: [SortDescriptor(\.hostname), SortDescriptor(\.port)]
        )
        guard let stored = try? context.fetch(descriptor) else {
            return []
        }
        return stored.map { KnownHostRecord(from: $0) }
    }

    // MARK: - 信任 / 替换 / 删除

    /// 始终信任：保存或更新某 `hostname + port` 的 KnownHost 为当前服务器 Host Key。
    ///
    /// 安全契约：只有 `save()` 真正成功才返回；持久化失败时回滚未保存修改并抛出
    /// `SSHError.knownHostPersistenceFailed`，调用方（SSHConnection）必须中止认证。
    /// 禁止吞掉保存错误后返回内存中的“假成功”快照。
    @discardableResult
    func trust(
        hostname: String,
        port: Int,
        keyType: String,
        hostKey: Data,
        fingerprint: String
    ) throws -> KnownHostRecord {
        let context = modelContainer.mainContext
        let existing = existingRecord(in: context, hostname: hostname, port: port)

        if let existing {
            existing.keyType = keyType
            existing.hostKey = hostKey
            existing.fingerprint = fingerprint
            existing.updatedAt = .now
        } else {
            let record = KnownHost(
                hostname: hostname,
                port: port,
                keyType: keyType,
                hostKey: hostKey,
                fingerprint: fingerprint
            )
            context.insert(record)
        }

        do {
            try saveAction(context)
        } catch {
            // 回滚未保存修改：失败后内存中不得残留新的 Host Key，
            // 否则同进程内下一次 lookup 会误判为 trusted。
            context.rollback()
            throw SSHError.knownHostPersistenceFailed
        }

        // 重新读取以获得稳定的持久化快照；save 成功后仍读不回视为持久化异常。
        guard let persisted = lookup(hostname: hostname, port: port) else {
            context.rollback()
            throw SSHError.knownHostPersistenceFailed
        }
        return persisted
    }

    /// 替换已保存的 KnownHost（Host Key Changed 后用户确认替换）。
    ///
    /// 与 `trust` 使用同一安全契约：替换保存失败必须抛错并保持旧记录不变，
    /// 绝不把旧 KnownHost 标记为已成功替换。
    @discardableResult
    func replace(
        _ record: KnownHostRecord,
        keyType: String,
        hostKey: Data,
        fingerprint: String
    ) throws -> KnownHostRecord {
        try trust(
            hostname: record.hostname,
            port: record.port,
            keyType: keyType,
            hostKey: hostKey,
            fingerprint: fingerprint
        )
    }

    /// 忘记某台主机的信任记录（Settings → Known Hosts → Forget）。
    ///
    /// 删除同样不允许静默失败：保存失败时回滚并抛错，记录保持可见。
    func remove(_ record: KnownHostRecord) throws {
        let context = modelContainer.mainContext
        guard let stored = existingRecord(in: context, hostname: record.hostname, port: record.port) else {
            return
        }
        context.delete(stored)
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            throw SSHError.knownHostPersistenceFailed
        }
    }

    // MARK: - 测试辅助

    /// 删除全部 KnownHost（仅测试使用，确保测试间隔离）。
    func removeAll() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<KnownHost>()
        guard let all = try? context.fetch(descriptor) else { return }
        for record in all {
            context.delete(record)
        }
        try? context.save()
    }

    // MARK: - 私有

    private func existingRecord(
        in context: ModelContext,
        hostname: String,
        port: Int
    ) -> KnownHost? {
        let descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.hostname == hostname && $0.port == port }
        )
        return try? context.fetch(descriptor).first
    }
}

/// KnownHost 的 Sendable 快照，用于跨 actor 边界（SSHConnection actor ↔ KnownHostService）。
///
/// 只携带非敏感数据（Host Key 是公钥，Fingerprint 是其摘要，均非 Secret）。
struct KnownHostRecord: Sendable, Equatable {
    let id: UUID
    let hostname: String
    let port: Int
    let keyType: String
    let hostKey: Data
    let fingerprint: String

    init(
        id: UUID,
        hostname: String,
        port: Int,
        keyType: String,
        hostKey: Data,
        fingerprint: String
    ) {
        self.id = id
        self.hostname = hostname
        self.port = port
        self.keyType = keyType
        self.hostKey = hostKey
        self.fingerprint = fingerprint
    }

    init(from knownHost: KnownHost) {
        self.id = knownHost.id
        self.hostname = knownHost.hostname
        self.port = knownHost.port
        self.keyType = knownHost.keyType
        self.hostKey = knownHost.hostKey
        self.fingerprint = knownHost.fingerprint
    }
}
