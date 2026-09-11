import Foundation

// MARK: - Resolver（任务书 §52–§56/§78/§110/§125）

/// 按 **origin sessionID** 解析 Remote 只读文件服务（§53）。
///
/// 契约：
/// - 只按显式 `sessionID` 查找；绝不依赖 `activeSession` / selectedTab /
///   当前可见会话（§7/§56）；
/// - Remote 会话不可寻址（已关闭 / 断开中 / 连接不可用）时返回 `nil`，
///   调用方映射为 `sessionUnavailable`——绝不 fallback 到其它 Remote
///   session，也绝不 fallback 本地文件系统，更不自动重连（§9）；
/// - 生产实现只取 **existing authenticated** `SSHConnection`，
///   绝不创建连接、绝不访问任何凭据（§5/§6/§108/§109）。
@MainActor
protocol AgentRemoteReadOnlyServiceResolving {
    func remoteFileService(for sessionID: UUID) -> AgentRemoteReadOnlyFileService?
}

/// 生产 resolver：`sessionID → SessionManager → ManagedTerminalSession
/// → Remote session → existing SSHConnection`（§110）。
///
/// 绝不按 host 名 / selected host 猜测连接：连接只能由会话自身持有。
@MainActor
final class SessionManagerAgentRemoteServiceResolver: AgentRemoteReadOnlyServiceResolving {
    private let sessionLookup: (UUID) -> ManagedTerminalSession?

    init(sessionLookup: @escaping @MainActor (UUID) -> ManagedTerminalSession?) {
        self.sessionLookup = sessionLookup
    }

    convenience init(sessionManager: SessionManager) {
        self.init { sessionID in
            sessionManager.session(withID: sessionID)
        }
    }

    func remoteFileService(for sessionID: UUID) -> AgentRemoteReadOnlyFileService? {
        guard let session = sessionLookup(sessionID) else {
            return nil
        }
        guard session.kind == .remoteSSH, !session.isClosed else {
            return nil
        }
        guard let connection = session.connection,
              session.connectionInfo?.phase == .connected
        else {
            return nil
        }
        return AgentRemoteReadOnlyFileService(
            client: SSHConnectionAgentRemoteFileClient(connection: connection)
        )
    }
}

// MARK: - SSHConnection 支撑的 façade 实现（任务书 §5/§11/§12）

/// 既有 `SSHConnection` actor 上的只读 façade 实现。
///
/// 硬约束：
/// - 只复用 **已认证** session 上既有的 SFTP 子系统：
///   `openSFTPSubsystemIfNeeded()`（惰性 + 幂等 + 与 Files 面板 / 传输
///   共享同一生命周期，§11）——绝不为 Agent 新建第二套
///   `libssh2_sftp_init` 生命周期；
/// - 每个操作都经既有 `acquireSFTPOperationGate` FIFO 串行门（§12），
///   与 Files sidebar / SFTP browser / transfer 共用同一协调边界，
///   绝不绕过 gate 直接循环调 raw libssh2 SFTP；
/// - 只调用只读原语：realpath / stat / opendir / open-for-read / read /
///   close；绝不出现任何 mutation 调用（§35/§64/§106）；
/// - 绝不触发 shell / exec（§14），也绝不触碰 PTY（§13）。
struct SSHConnectionAgentRemoteFileClient: AgentRemoteReadOnlyFileClient {
    let connection: SSHConnection

    func canonicalPath(_ path: String) async throws -> String {
        try await openSubsystemIfNeeded()
        do {
            return try await connection.sftpRealpath(path)
        } catch {
            throw Self.map(error)
        }
    }

    func stat(_ path: String) async throws -> AgentRemoteFileMetadata {
        try await openSubsystemIfNeeded()
        do {
            let result = try await connection.sftpStatFile(path)
            return AgentRemoteFileMetadata(
                sizeBytes: result.sizeBytes.map { UInt64(clamping: $0) },
                isRegularFile: result.isRegularFile,
                isDirectory: result.isDirectory,
                isSymlink: result.isSymlink
            )
        } catch {
            throw Self.map(error)
        }
    }

    func listDirectory(_ path: String) async throws -> [AgentRemoteDirectoryEntry] {
        try await openSubsystemIfNeeded()
        do {
            let entries = try await connection.sftpListDirectory(path)
            return entries.map { entry in
                AgentRemoteDirectoryEntry(
                    name: entry.name,
                    kind: Self.mapKind(entry.kind),
                    sizeBytes: entry.kind == .regularFile ? entry.sizeBytes : nil
                )
            }
        } catch {
            throw Self.map(error)
        }
    }

    func openFileForRead(_ path: String) async throws -> AgentRemoteReadHandle {
        try await openSubsystemIfNeeded()
        do {
            let handle = try await connection.sftpOpenFileForRead(path)
            return AgentRemoteReadHandle(
                identifier: UInt64(bitPattern: Int64(Int(bitPattern: handle.raw))),
                remoteHandle: handle
            )
        } catch {
            throw Self.map(error)
        }
    }

    func readFileChunk(
        _ handle: AgentRemoteReadHandle,
        maxBytes: Int
    ) async throws -> Data {
        guard let remote = handle.remoteHandle else {
            throw AgentRemoteFileError.protocolFailure
        }
        do {
            var buffer: [UInt8] = []
            let count = try await connection.sftpReadFileChunk(
                remote,
                into: &buffer,
                maxLength: maxBytes
            )
            guard count > 0 else {
                return Data()
            }
            return Data(buffer.prefix(count))
        } catch {
            throw Self.map(error)
        }
    }

    func closeFile(_ handle: AgentRemoteReadHandle) async {
        guard let remote = handle.remoteHandle else {
            return
        }
        // 收尾路径：幂等，绝不检查取消——保证句柄在任何退出路径都被关闭。
        await connection.sftpCloseFileHandle(remote)
    }

    // MARK: - 内部

    private func openSubsystemIfNeeded() async throws {
        do {
            try await connection.openSFTPSubsystemIfNeeded()
        } catch {
            throw Self.map(error)
        }
    }

    /// §30/§45：既有 `SFTPFileEntry.Kind` → Agent 条目类型（单一 mapper），
    /// 并把底层 `SFTPError` 收敛为 vendor-neutral 分类（绝不外泄
    /// libssh2 原始码）。
    private static func mapKind(_ kind: SFTPFileEntry.Kind) -> AgentRemoteDirectoryEntryKind {
        switch kind {
        case .regularFile:
            return .file
        case .directory:
            return .directory
        case .symlink:
            return .symbolicLink
        case .other:
            return .other
        }
    }

    private static func map(_ error: Error) -> AgentRemoteFileError {
        if error is CancellationError {
            return .cancelled
        }
        guard let sftpError = error as? SFTPError else {
            return .protocolFailure
        }
        switch sftpError {
        case .noSuchPath:
            return .noSuchPath
        case .permissionDenied:
            return .permissionDenied
        case .connectionLost:
            return .connectionLost
        case .operationCancelled:
            return .cancelled
        case .subsystemInitFailed, .protocolFailure:
            return .protocolFailure
        }
    }
}
