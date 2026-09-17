import Darwin
import Foundation

/// proposal-time 捕获的 local parent directory capability。
///
/// actor 自己串行化 descriptor 的关闭状态；它不暴露 raw descriptor，因此
/// C1 没有任何调用方可借此产生 side effect。后续阶段如需借用 descriptor，
/// 必须在独立验收中增加 scoped API 与 identity revalidation。
actor AgentLocalFileMutationTargetCapability {
    /// 不依赖 fd number 的 immutable identity，供 request/approval 绑定。
    nonisolated let identity: AgentLocalFileMutationCapabilityIdentity
    /// proposal 时的 canonical display path，不是 security authority。
    nonisolated let displayPath: String
    /// 对 final basename 的 no-follow metadata snapshot；仅作早期 create-only disclosure。
    nonisolated let targetExistsAtProposal: Bool

    /// actor 隔离的 descriptor ownership；nil 表示已 deterministic close。
    private var directoryFileDescriptor: Int32?

    /// 用 read-only directory flags 捕获 final parent，绝不打开 final target。
    init(
        opening parentPath: String,
        displayPath: String,
        targetBasename: String
    ) throws {
        var linkStatus = stat()
        if lstat(parentPath, &linkStatus) == 0,
           (linkStatus.st_mode & S_IFMT) == S_IFLNK {
            throw AgentFileMutationError.parentSymlinkRejected
        }

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let descriptor = Darwin.open(parentPath, flags)
        guard descriptor >= 0 else {
            throw Self.mapParentErrno(errno)
        }

        var directoryStatus = stat()
        guard fstat(descriptor, &directoryStatus) == 0 else {
            Darwin.close(descriptor)
            throw AgentFileMutationError.parentUnavailable
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw AgentFileMutationError.parentNotDirectory
        }

        var targetStatus = stat()
        let targetResult = fstatat(descriptor, targetBasename, &targetStatus, AT_SYMLINK_NOFOLLOW)
        let exists: Bool
        if targetResult == 0 {
            // Regular file, directory, symlink, FIFO and socket all block create-only proposal.
            exists = true
        } else if errno == ENOENT {
            exists = false
        } else {
            Darwin.close(descriptor)
            throw Self.mapTargetErrno(errno)
        }

        self.identity = AgentLocalFileMutationCapabilityIdentity(
            capabilityToken: UUID(),
            deviceID: UInt64(directoryStatus.st_dev),
            inode: UInt64(directoryStatus.st_ino),
            ownerID: UInt32(directoryStatus.st_uid),
            groupID: UInt32(directoryStatus.st_gid),
            mode: UInt16(directoryStatus.st_mode & 0o7777)
        )
        self.displayPath = displayPath
        self.targetExistsAtProposal = exists
        self.directoryFileDescriptor = descriptor
    }

    deinit {
        // deinit 仅处理尚未走 invalidate 的 descriptor；赋 nil 前的所有 close
        // 均在 actor 隔离中发生，所以不会 double close。
        if let descriptor = directoryFileDescriptor {
            Darwin.close(descriptor)
        }
    }

    /// deny/cancel/purge 后关闭 capability；多次调用是幂等的。
    func invalidate() -> Bool {
        guard let descriptor = directoryFileDescriptor else {
            return false
        }
        directoryFileDescriptor = nil
        Darwin.close(descriptor)
        return true
    }

    /// C1 test-only/diagnostic introspection，不暴露 descriptor 数值。
    func isOpen() -> Bool {
        directoryFileDescriptor != nil
    }

    /// 父目录 rename 后仍可验证同一 directory object；pathname 绝非 authority。
    func stillMatchesCapturedDirectory() -> Bool {
        guard let descriptor = directoryFileDescriptor else {
            return false
        }
        var current = stat()
        guard fstat(descriptor, &current) == 0 else {
            return false
        }
        return UInt64(current.st_dev) == identity.deviceID && UInt64(current.st_ino) == identity.inode
    }

    /// 在 capability actor 内验证并短暂借用 exact parent FD。
    ///
    /// 闭包在 actor 隔离期间同步执行，因此 executor 不会拿到 actor 之外
    /// 的裸 FD；`invalidate()` 也不能在这段借用期间提前 close。C2 的所有
    /// mkdirat/openat/publication/cleanup 都必须通过这个入口完成，不能退回
    /// display path 或当前工作目录。
    func withValidatedDirectoryDescriptor<T: Sendable>(
        _ body: @Sendable (Int32) -> T
    ) -> Result<T, AgentFileMutationError> {
        guard let descriptor = directoryFileDescriptor else {
            return .failure(.parentCapabilityUnavailable)
        }

        var current = stat()
        guard fstat(descriptor, &current) == 0 else {
            return .failure(.parentCapabilityStale)
        }
        guard (current.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(.parentCapabilityStale)
        }
        guard
            UInt64(current.st_dev) == identity.deviceID,
            UInt64(current.st_ino) == identity.inode
        else {
            return .failure(.parentCapabilityStale)
        }

        return .success(body(descriptor))
    }

    /// 父目录 open 失败映射为 domain failure，errno 不穿透至 Provider/UI。
    private static func mapParentErrno(_ code: Int32) -> AgentFileMutationError {
        switch code {
        case ELOOP:
            return .parentSymlinkRejected
        case ENOTDIR:
            return .parentNotDirectory
        default:
            return .parentUnavailable
        }
    }

    /// final target metadata 无法读取也不放宽成“可创建”。
    private static func mapTargetErrno(_ code: Int32) -> AgentFileMutationError {
        switch code {
        case ENOTDIR:
            return .parentNotDirectory
        default:
            return .parentUnavailable
        }
    }
}
