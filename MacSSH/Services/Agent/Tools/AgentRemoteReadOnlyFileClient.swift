import Foundation

// MARK: - Remote 只读 façade（任务书 §4/§12/§35）

/// Phase 10D-B3：Remote 只读文件能力的**最小 façade**。
///
/// Agent 层唯一可见的 Remote 文件能力面，只有六个原语：
///
/// ```text
/// canonicalize → stat → list → open-for-read → read chunk → close
/// ```
///
/// 硬约束：
/// - 绝不暴露 write / upload / rename / unlink / mkdir / rmdir / chmod /
///   chown / truncate / create / exec / shell（§4/§64/§106/§107）。
///   新增任何 mutation 方法都是 P1；
/// - 实现只允许复用 origin session 上**已认证**的 existing
///   `SSHConnection` 与既有 SFTP 子系统（§5/§11/§12）：本 façade 既不
///   创建连接，也不触碰任何凭据（§6/§109）；
/// - Remote 路径语义由服务端 canonicalization 决定（§21），本地
///   `FileManager` / `realpath()` 对远端路径无权威性。
protocol AgentRemoteReadOnlyFileClient: Sendable {
    /// 服务端 canonicalization（SFTP realpath 语义），返回规范绝对路径。
    func canonicalPath(_ path: String) async throws -> String

    /// 目标属性（跟随 symlink：canonical 路径上的最终对象）。
    func stat(_ path: String) async throws -> AgentRemoteFileMetadata

    /// 目录条目列举（只读）。
    func listDirectory(_ path: String) async throws -> [AgentRemoteDirectoryEntry]

    /// 只读打开（§35：绝不暴露 write / create / truncate / append 标志）。
    func openFileForRead(_ path: String) async throws -> AgentRemoteReadHandle

    /// 分块读取；空 `Data` = EOF。
    func readFileChunk(_ handle: AgentRemoteReadHandle, maxBytes: Int) async throws -> Data

    /// 关闭句柄（幂等；收尾路径绝不检查取消，保证不泄漏）。
    func closeFile(_ handle: AgentRemoteReadHandle) async
}

// MARK: - 值模型

/// 远端文件属性（只取 Agent 判定所需字段）。
struct AgentRemoteFileMetadata: Sendable, Equatable {
    let sizeBytes: UInt64?
    let isRegularFile: Bool
    let isDirectory: Bool
    let isSymlink: Bool
}

/// 远端目录条目类型（§30：与既有 `SFTPFileEntry.Kind` 单一 mapper 对应，
/// 绝不为 Agent 重新实现一套 mode bits → kind 解析）。
enum AgentRemoteDirectoryEntryKind: Sendable, Equatable {
    case file
    case directory
    case symbolicLink
    case other

    /// 固定排序 rank（§32）：与 locale 无关，测试锁定。
    var sortRank: Int {
        switch self {
        case .directory: return 0
        case .symbolicLink: return 1
        case .file: return 2
        case .other: return 3
        }
    }
}

struct AgentRemoteDirectoryEntry: Sendable, Equatable {
    let name: String
    let kind: AgentRemoteDirectoryEntryKind
    /// 普通文件字节大小；目录 / 链接 / 其它为 nil。
    let sizeBytes: UInt64?
}

/// 远端只读句柄（跨 actor 的身份令牌）。
struct AgentRemoteReadHandle: Sendable, Equatable {
    let identifier: UInt64
    /// 生产实现持有的底层 SFTP 句柄；fake 实现为 nil。
    let remoteHandle: SFTPFileHandle?

    init(identifier: UInt64, remoteHandle: SFTPFileHandle? = nil) {
        self.identifier = identifier
        self.remoteHandle = remoteHandle
    }
}

// MARK: - 错误分类（任务书 §45/§46/§111）

/// vendor-neutral 的远端错误分类。
///
/// 绝不携带 libssh2 原始数值码、指针、内部 channel 状态或任何凭据：
/// 底层细节只留在既有 SSH/SFTP 层，Agent 领域层只保留可判等的语义分类。
enum AgentRemoteFileError: Error, Equatable, Sendable {
    case noSuchPath
    case permissionDenied
    case connectionLost
    case protocolFailure
    case cancelled

    /// 映射到 Agent 工具错误（§45：绝不把 libssh2 raw code 送进结果）。
    var toolError: AgentToolError {
        switch self {
        case .noSuchPath:
            return .pathNotFound
        case .permissionDenied:
            return .permissionDenied
        case .connectionLost:
            return .sessionUnavailable
        case .protocolFailure:
            return .internalFailure
        case .cancelled:
            return .cancelled
        }
    }
}
