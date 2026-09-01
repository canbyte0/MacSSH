import Foundation
import SwiftData

/// SSH 连接的工厂与共享安全服务入口。
///
/// Phase 8 起 SSH 连接改为 **per-session 所有权**（任务书 41/42）：每个
/// Remote Terminal Session 拥有独立的 `SSHConnection` actor（独立的
/// `LIBSSH2_SESSION *` / socket / Channel），本服务不再按 HostID 登记
/// 单一连接。共享的只有无状态安全服务（`CredentialService` /
/// `KeychainService` / `KnownHostService`，任务书 43）。
///
/// View 仍只通过服务层发起连接准备，绝不直接触碰 `SSHConnection`
/// 或 libssh2；连接由 `SessionManager`（代表 Session）持有，切换
/// Sidebar / Tab 不会销毁连接。
@MainActor
@Observable
final class SSHService {
    /// 校验 Host 并准备一条独立连接；结果交给调用方（SessionManager）持有。
    enum ConnectionPreparation {
        /// 前置校验通过：返回未启动的连接（connect() 由 SessionManager 驱动）。
        case ready(SSHConnection, SSHConnectionInfo)
        /// 前置校验失败（Host 参数非法 / 缺少凭据等）：无 actor 可用，
        /// info 已携带 failed 状态与用户可读原因。
        case rejected(SSHConnectionInfo)
    }

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

    // MARK: - 连接准备

    /// 对一个 Host 准备独立连接；前置校验失败立即产生 rejected 状态。
    ///
    /// 与 Phase 6 相同的校验标准：认证方式由 Host 配置决定，不互相回退；
    /// Private Key Host 需要已配置私钥路径（nil / 空 / 纯空白视为未配置）。
    /// 同一 Host 可以并发准备多条连接（同 Host 多 Session，任务书 11/37）。
    func prepareConnection(for host: Host) -> ConnectionPreparation {
        let info = SSHConnectionInfo(
            hostID: host.id,
            hostname: host.hostname,
            port: UInt16(clamping: host.port),
            username: host.username
        )

        guard !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty,
            !host.username.trimmingCharacters(in: .whitespaces).isEmpty,
            (1...65_535).contains(host.port)
        else {
            return .rejected(rejected(info, error: .invalidHost))
        }

        // 按认证方式做前置凭据校验；不偷试其他认证方式。
        let credentialID: UUID?
        let privateKeyPath: String?
        let privateKeyID: UUID?

        switch host.authenticationType {
        case .password:
            guard let id = host.credentialID else {
                return .rejected(rejected(info, error: .credentialNotFound))
            }
            credentialID = id
            privateKeyPath = nil
            privateKeyID = nil

        case .privateKey:
            guard let path = host.privateKeyPath,
                !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .rejected(rejected(info, error: .privateKeyPathMissing))
            }
            credentialID = nil
            privateKeyPath = path
            privateKeyID = host.privateKeyID // 无 Passphrase 私钥为 nil，合法
        }

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
        return .ready(connection, info)
    }

    /// 认证成功后更新最近连接时间（非敏感元数据）。
    func recordSuccessfulConnection(for host: Host) {
        host.lastConnectedAt = Date()
        host.updatedAt = Date()
        try? modelContainer.mainContext.save()
        AppLogger.ssh.info("Host last connected timestamp updated")
    }

    /// 按 ID 读取 Host（Reconnect 复用 Host Profile 时使用）。
    func host(withID id: UUID) -> Host? {
        var descriptor = FetchDescriptor<Host>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContainer.mainContext.fetch(descriptor).first
    }

    // MARK: - 前置失败

    /// 不创建 actor 的快速失败：直接进入 failed 状态。
    /// MacSSH 1.1：缓存语言无关的 SSHError 枚举，UI 按 Locale 即时解析
    /// （不在连接准备阶段缓存英文文案，任务书七十三）。
    private func rejected(
        _ info: SSHConnectionInfo,
        error: SSHError
    ) -> SSHConnectionInfo {
        info.phase = .failed(error)
        info.setFailure(error: error)
        AppLogger.ssh.error("SSH connection rejected before start: \(String(describing: error))")
        return info
    }
}
