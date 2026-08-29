import Foundation
import SwiftData

/// SSH 连接的唯一业务入口。
///
/// View 只通过本服务发起连接和信任决策，绝不直接触碰 `SSHConnection`
/// 或 libssh2。连接由本服务持有，切换 Sidebar 页面不会销毁连接。
@MainActor
@Observable
final class SSHService {
    /// 每个 Host 当前（或最近一次）的连接状态镜像，供 UI 观察。
    private(set) var connections: [UUID: SSHConnectionInfo] = [:]

    /// 真正拥有 libssh2 session 的 actor。
    private var connectionActors: [UUID: SSHConnection] = [:]

    private let credentialService: CredentialService
    private let modelContainer: ModelContainer
    let knownHostService: KnownHostService

    init(
        credentialService: CredentialService = .shared,
        modelContainer: ModelContainer
    ) {
        self.credentialService = credentialService
        self.modelContainer = modelContainer
        self.knownHostService = KnownHostService(modelContainer: modelContainer)
    }

    // MARK: - 查询

    func connectionInfo(for hostID: UUID) -> SSHConnectionInfo? {
        connections[hostID]
    }

    /// 该 Host 是否处于连接中途（需要 UI 禁用重复 Connect）。
    func isConnectionActive(_ hostID: UUID) -> Bool {
        guard let info = connections[hostID] else { return false }
        switch info.phase {
        case .connecting, .handshaking, .awaitingHostTrust, .authenticating, .disconnecting:
            return true
        case .idle, .connected, .disconnected, .failed:
            return false
        }
    }

    // MARK: - 连接动作

    /// 对一个 Host 发起连接；前置校验失败会立即产生 failed 状态。
    ///
    /// Phase 6：同时支持 Password 与 Private Key 两种认证方式，由 Host 配置决定，
    /// 不互相回退。Private Key Host 需要已配置私钥路径；Passphrase 可选。
    func connect(to host: Host) {
        // 重复请求：连接进行中直接忽略。
        guard !isConnectionActive(host.id) else { return }

        guard !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty,
            !host.username.trimmingCharacters(in: .whitespaces).isEmpty,
            (1...65_535).contains(host.port)
        else {
            failFast(host: host, error: .invalidHost)
            return
        }

        // 按认证方式做前置凭据校验；不偷试其他认证方式。
        let credentialID: UUID?
        let privateKeyPath: String?
        let privateKeyID: UUID?

        switch host.authenticationType {
        case .password:
            guard let id = host.credentialID else {
                failFast(host: host, error: .credentialNotFound)
                return
            }
            credentialID = id
            privateKeyPath = nil
            privateKeyID = nil

        case .privateKey:
            // 与 Host Editor 相同标准：nil / 空 / 纯空白路径一律视为未配置。
            guard let path = host.privateKeyPath,
                !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                failFast(host: host, error: .privateKeyPathMissing)
                return
            }
            credentialID = nil
            privateKeyPath = path
            privateKeyID = host.privateKeyID // 无 Passphrase 私钥为 nil，合法
        }

        // 已结束的旧连接先彻底清理。
        if let previous = connectionActors[host.id] {
            Task { await previous.disconnect() }
            connectionActors[host.id] = nil
        }

        let info = SSHConnectionInfo(
            hostID: host.id,
            hostname: host.hostname,
            port: UInt16(host.port),
            username: host.username
        )
        connections[host.id] = info

        let configuration = SSHConnection.Configuration(
            hostID: host.id,
            hostname: host.hostname,
            port: UInt16(host.port),
            username: host.username,
            authenticationType: host.authenticationType,
            credentialID: credentialID,
            privateKeyPath: privateKeyPath,
            privateKeyID: privateKeyID
        )

        let connection = SSHConnection(
            configuration: configuration,
            info: info,
            credentialService: credentialService,
            knownHostService: knownHostService
        )
        connectionActors[host.id] = connection

        let connectedHost = host
        Task {
            await connection.connect()

            // 认证成功后更新最近连接时间（非敏感元数据）。
            if info.phase == .connected {
                connectedHost.lastConnectedAt = Date()
                connectedHost.updatedAt = Date()
                try? modelContainer.mainContext.save()
                AppLogger.ssh.info("Host last connected timestamp updated")
            }
        }
    }

    // MARK: - Host Trust 决策入口（Phase 6）

    /// Host Trust 对话框：仅本次信任（不持久化）。
    func trustOnce(hostID: UUID) {
        guard let connection = connectionActors[hostID] else { return }
        Task { await connection.resolveHostTrust(.trustOnce) }
    }

    /// Host Trust 对话框：始终信任（写入 KnownHost 持久化；仅未知主机）。
    func trustAlways(hostID: UUID) {
        guard let connection = connectionActors[hostID] else { return }
        Task { await connection.resolveHostTrust(.trustAlways) }
    }

    /// Host Key Changed 对话框：替换已信任的 Host Key（UI 已完成二次确认）。
    func replaceTrustedKey(hostID: UUID) {
        guard let connection = connectionActors[hostID] else { return }
        Task { await connection.resolveHostTrust(.replaceTrustedKey) }
    }

    /// Host Trust 对话框：取消并断开。
    func cancelHostTrust(hostID: UUID) {
        guard let connection = connectionActors[hostID] else { return }
        Task { await connection.resolveHostTrust(.cancel) }
    }

    /// 断开指定 Host 的连接（幂等）。
    func disconnect(hostID: UUID) {
        guard let connection = connectionActors[hostID] else { return }
        Task { await connection.disconnect() }
    }

    // MARK: - 前置失败

    /// 不创建 actor 的快速失败：直接进入 failed 状态。
    private func failFast(host: Host, error: SSHError) {
        let info = SSHConnectionInfo(
            hostID: host.id,
            hostname: host.hostname,
            port: UInt16(clamping: host.port),
            username: host.username
        )
        info.phase = .failed(error)
        info.failureMessage = error.errorDescription
        connections[host.id] = info
        AppLogger.ssh.error("SSH connection rejected before start: \(String(describing: error))")
    }
}
