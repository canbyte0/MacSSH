import Darwin
import Foundation

// MARK: - Sanitized result

/// C2 的发布方式；`fallbackLink` 仍然保持 create-only/no-clobber 语义。
enum AgentLocalFileMutationPublicationMethod: String, Sendable, Equatable {
    case rename
    case fallbackLink
}

/// Local file mutation 的最小、无 payload 结果。
///
/// 结果只携带计数、发布状态和清理状态，不携带 content、path、basename、
/// errno 或 credentials。`published` 是物理 publication 的事实状态；即使
/// fallback source unlink 失败，也必须保持为 `true`。
struct AgentLocalFileMutationResult: Sendable, Equatable {
    let published: Bool
    let publicationMethod: AgentLocalFileMutationPublicationMethod?
    let payloadBytesRequested: Int
    let payloadBytesWrittenToTemp: Int
    let cleanupComplete: Bool
    let cleanupResidue: Bool
    let error: AgentFileMutationError?

    /// 与验收文字一致的别名，避免调用方把 temp prefix 误认为 destination bytes。
    var payloadBytesWritten: Int { payloadBytesWrittenToTemp }
}

extension AgentLocalFileMutationResult: CustomStringConvertible, CustomDebugStringConvertible {
    /// 诊断输出不包含 payload、目标路径、临时名称或底层 errno。
    var description: String {
        let method = publicationMethod?.rawValue ?? "none"
        let errorText = error.map(String.init(describing:)) ?? "none"
        return "AgentLocalFileMutationResult(published: \(published), "
            + "publicationMethod: \(method), "
            + "payloadBytesRequested: \(payloadBytesRequested), "
            + "payloadBytesWrittenToTemp: \(payloadBytesWrittenToTemp), "
            + "cleanupComplete: \(cleanupComplete), cleanupResidue: \(cleanupResidue), "
            + "error: \(errorText))"
    }

    var debugDescription: String { description }
}

// MARK: - Narrow Darwin test seam

/// Swift `Result` 的 Failure 必须符合 `Error`；raw errno 只留在这个内部
/// backend seam 中，永远不会进入 sanitized result。
struct AgentLocalFileMutationSystemFailure: Error, Equatable, Sendable {
    let code: Int32

    init(_ code: Int32) {
        self.code = code
    }
}

/// `stat(2)` 的 sanitized snapshot；生产 executor 不把 Darwin `stat` 结构
/// 或 raw errno 暴露给上层。
struct AgentLocalFileMutationFileMetadata: Sendable, Equatable {
    let deviceID: UInt64
    let inode: UInt64
    let ownerID: UInt32
    let groupID: UInt32
    let mode: UInt16
    let linkCount: UInt64

    var isDirectory: Bool {
        (mode & UInt16(S_IFMT)) == UInt16(S_IFDIR)
    }

    var isRegularFile: Bool {
        (mode & UInt16(S_IFMT)) == UInt16(S_IFREG)
    }

    var groupAndOtherPermissionBitsAreClear: Bool {
        (mode & UInt16(0o077)) == 0
    }
}

/// C2 所需的最窄 filesystem seam。
///
/// 生产实现只包装 Darwin `*at`/`renameatx_np` syscall；focused tests 可以
/// 注入 short write、EINTR、fsync failure、unsupported rename 和 cleanup
/// failure，而不改变 production backend 的 syscall 架构。
protocol AgentLocalFileMutationFileSystem: Sendable {
    func createDirectory(
        parentFileDescriptor: Int32,
        name: String,
        mode: UInt16
    ) -> Result<Void, AgentLocalFileMutationSystemFailure>

    func open(
        directoryFileDescriptor: Int32,
        name: String,
        flags: Int32,
        mode: UInt16
    ) -> Result<Int32, AgentLocalFileMutationSystemFailure>

    func metadata(fileDescriptor: Int32) -> Result<AgentLocalFileMutationFileMetadata, AgentLocalFileMutationSystemFailure>

    func metadataAt(
        directoryFileDescriptor: Int32,
        name: String,
        noFollow: Bool
    ) -> Result<AgentLocalFileMutationFileMetadata, AgentLocalFileMutationSystemFailure>

    func write(fileDescriptor: Int32, data: Data) -> Result<Int, AgentLocalFileMutationSystemFailure>

    func synchronize(fileDescriptor: Int32) -> Result<Void, AgentLocalFileMutationSystemFailure>

    func publishExclusively(
        sourceDirectoryFileDescriptor: Int32,
        sourceName: String,
        destinationDirectoryFileDescriptor: Int32,
        destinationName: String
    ) -> Result<Void, AgentLocalFileMutationSystemFailure>

    func linkWithoutClobber(
        sourceDirectoryFileDescriptor: Int32,
        sourceName: String,
        destinationDirectoryFileDescriptor: Int32,
        destinationName: String
    ) -> Result<Void, AgentLocalFileMutationSystemFailure>

    /// `removeDirectory == false` 映射到 `unlinkat(..., 0)`；true 映射到
    /// `unlinkat(..., AT_REMOVEDIR)`。
    func unlink(
        directoryFileDescriptor: Int32,
        name: String,
        removeDirectory: Bool
    ) -> Result<Void, AgentLocalFileMutationSystemFailure>

    func close(fileDescriptor: Int32)
    func effectiveUserID() -> UInt32
}

/// 应用控制的随机 basename 生成器；名称绝不来自 Provider path/content。
protocol AgentLocalFileMutationNameGenerator: Sendable {
    func makeStagingDirectoryName() -> String
    func makeTemporaryFileName() -> String
}

/// 生产名称生成器。UUID 不包含 `/`，也不从用户输入派生。
struct AgentLocalFileMutationUUIDNameGenerator: AgentLocalFileMutationNameGenerator {
    func makeStagingDirectoryName() -> String {
        ".macssh-agent-write-\(UUID().uuidString.lowercased())"
    }

    func makeTemporaryFileName() -> String {
        ".macssh-agent-temp-\(UUID().uuidString.lowercased())"
    }
}

/// 仅用于 deterministic focused tests 的执行时钩子。
///
/// 生产实例使用 `.none`；钩子不接受 payload/path，也不能改变 executor 的
/// target。`afterFsyncBeforePublication` 可用于构造 source-replacement 与
/// cancellation barrier 测试。
struct AgentLocalFileMutationExecutorHooks: Sendable {
    let beforeFirstMutation: (@Sendable () -> Void)?
    let afterFsyncBeforePublication: (@Sendable () -> Void)?
    let beforePublication: (@Sendable () -> Void)?

    static let none = AgentLocalFileMutationExecutorHooks(
        beforeFirstMutation: nil,
        afterFsyncBeforePublication: nil,
        beforePublication: nil
    )
}

// MARK: - Darwin backend

/// 唯一的 production filesystem backend。
///
/// 注意：这里没有 destination path open、`O_TRUNC`、高层写 API 或递归 mkdir；
/// 所有名字都相对于已借用的 directory FD 解析。
struct AgentLocalFileMutationDarwinFileSystem: AgentLocalFileMutationFileSystem {
    func createDirectory(
        parentFileDescriptor: Int32,
        name: String,
        mode: UInt16
    ) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        let result = name.withCString {
            Darwin.mkdirat(parentFileDescriptor, $0, mode_t(mode))
        }
        return result == 0 ? .success(()) : .failure(AgentLocalFileMutationSystemFailure(errno))
    }

    func open(
        directoryFileDescriptor: Int32,
        name: String,
        flags: Int32,
        mode: UInt16
    ) -> Result<Int32, AgentLocalFileMutationSystemFailure> {
        let descriptor = name.withCString {
            Darwin.openat(directoryFileDescriptor, $0, flags, mode_t(mode))
        }
        return descriptor >= 0 ? .success(descriptor) : .failure(AgentLocalFileMutationSystemFailure(errno))
    }

    func metadata(fileDescriptor: Int32) -> Result<AgentLocalFileMutationFileMetadata, AgentLocalFileMutationSystemFailure> {
        var value = stat()
        guard Darwin.fstat(fileDescriptor, &value) == 0 else {
            return .failure(AgentLocalFileMutationSystemFailure(errno))
        }
        return .success(Self.metadata(from: value))
    }

    func metadataAt(
        directoryFileDescriptor: Int32,
        name: String,
        noFollow: Bool
    ) -> Result<AgentLocalFileMutationFileMetadata, AgentLocalFileMutationSystemFailure> {
        var value = stat()
        let flags: Int32 = noFollow ? AT_SYMLINK_NOFOLLOW : 0
        let result = name.withCString {
            Darwin.fstatat(directoryFileDescriptor, $0, &value, flags)
        }
        guard result == 0 else {
            return .failure(AgentLocalFileMutationSystemFailure(errno))
        }
        return .success(Self.metadata(from: value))
    }

    func write(fileDescriptor: Int32, data: Data) -> Result<Int, AgentLocalFileMutationSystemFailure> {
        let result = data.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(fileDescriptor, baseAddress, rawBuffer.count)
        }
        return result >= 0 ? .success(result) : .failure(AgentLocalFileMutationSystemFailure(errno))
    }

    func synchronize(fileDescriptor: Int32) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        Darwin.fsync(fileDescriptor) == 0
            ? .success(())
            : .failure(AgentLocalFileMutationSystemFailure(errno))
    }

    func publishExclusively(
        sourceDirectoryFileDescriptor: Int32,
        sourceName: String,
        destinationDirectoryFileDescriptor: Int32,
        destinationName: String
    ) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        let flags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    sourceDirectoryFileDescriptor,
                    source,
                    destinationDirectoryFileDescriptor,
                    destination,
                    flags
                )
            }
        }
        return result == 0 ? .success(()) : .failure(AgentLocalFileMutationSystemFailure(errno))
    }

    func linkWithoutClobber(
        sourceDirectoryFileDescriptor: Int32,
        sourceName: String,
        destinationDirectoryFileDescriptor: Int32,
        destinationName: String
    ) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                Darwin.linkat(
                    sourceDirectoryFileDescriptor,
                    source,
                    destinationDirectoryFileDescriptor,
                    destination,
                    0
                )
            }
        }
        return result == 0 ? .success(()) : .failure(AgentLocalFileMutationSystemFailure(errno))
    }

    func unlink(
        directoryFileDescriptor: Int32,
        name: String,
        removeDirectory: Bool
    ) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        let flags: Int32 = removeDirectory ? AT_REMOVEDIR : 0
        let result = name.withCString {
            Darwin.unlinkat(directoryFileDescriptor, $0, flags)
        }
        return result == 0 ? .success(()) : .failure(AgentLocalFileMutationSystemFailure(errno))
    }

    func close(fileDescriptor: Int32) {
        _ = Darwin.close(fileDescriptor)
    }

    func effectiveUserID() -> UInt32 {
        UInt32(geteuid())
    }

    private static func metadata(from value: stat) -> AgentLocalFileMutationFileMetadata {
        AgentLocalFileMutationFileMetadata(
            deviceID: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            ownerID: UInt32(value.st_uid),
            groupID: UInt32(value.st_gid),
            // 保留 file type bits；permission 校验只在 metadata helper 中
            // mask `0o077`，否则 directory/regular-file identity 会丢失。
            mode: UInt16(value.st_mode),
            linkCount: UInt64(value.st_nlink)
        )
    }
}

// MARK: - Executor

/// C2 Local file mutation staging/publication executor。
///
/// 初始化必须同时持有：
/// - C1 coordinator 签发的 exact authorization；
/// - authorization 内对应的 exact immutable parent capability；
/// - 同一个 C1 approval coordinator。
///
/// 没有接受 path、裸 request 或 Boolean approval 的入口。executor 只消费
/// coordinator redeem 返回的 immutable request，不重新读取 Provider/UI 值。
struct AgentLocalFileMutationExecutor: Sendable {
    private let authorization: AgentFileMutationExecutionAuthorization
    private let targetCapability: AgentLocalFileMutationTargetCapability
    private let approvalCoordinator: AgentFileMutationApprovalCoordinator
    private let fileSystem: any AgentLocalFileMutationFileSystem
    private let nameGenerator: any AgentLocalFileMutationNameGenerator
    private let hooks: AgentLocalFileMutationExecutorHooks

    init(
        authorization: AgentFileMutationExecutionAuthorization,
        targetCapability: AgentLocalFileMutationTargetCapability,
        approvalCoordinator: AgentFileMutationApprovalCoordinator,
        fileSystem: any AgentLocalFileMutationFileSystem = AgentLocalFileMutationDarwinFileSystem(),
        nameGenerator: any AgentLocalFileMutationNameGenerator = AgentLocalFileMutationUUIDNameGenerator(),
        hooks: AgentLocalFileMutationExecutorHooks = .none
    ) {
        self.authorization = authorization
        self.targetCapability = targetCapability
        self.approvalCoordinator = approvalCoordinator
        self.fileSystem = fileSystem
        self.nameGenerator = nameGenerator
        self.hooks = hooks
    }

    /// 执行一次物理 side effect；所有失败均返回 sanitized result。
    ///
    /// 顺序固定为：auth↔target 校验 → parent capability 校验 → redeem →
    /// 取消观察 → `mkdirat`。同一个 authorization 的第二次调用在 redeem
    /// 处失败，因此不会进入任何 mutation syscall。
    func execute() async -> AgentLocalFileMutationResult {
        let requestedBytes = authorization.request.payloadIdentity.byteCount

        guard Self.authorizationMatchesTarget(
            authorization,
            targetCapability: targetCapability
        ) else {
            return Self.result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                error: .targetStale
            )
        }

        // 初始取消在 redeem 之前被观察，既不消费 permit，也不产生 mutation。
        guard !Task.isCancelled else {
            return Self.result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                error: .cancelled
            )
        }

        // 这是 redeem 前的 read-only parent validation；它不创建目录、不打开
        // temp、不改变 approval ledger。
        let parentPreflight = await targetCapability.withValidatedDirectoryDescriptor { _ in () }
        guard case let .failure(parentError) = parentPreflight else {
            // 继续到紧邻 redeem 的 cancellation check。
            if Task.isCancelled {
                return Self.result(
                    requestedBytes: requestedBytes,
                    writtenBytes: 0,
                    error: .cancelled
                )
            }

            let request: AgentFileMutationRequest
            do {
                // C1 actor 是唯一 replay ledger；没有其它路径可以获得 redeem。
                request = try await approvalCoordinator.redeem(authorization)
            } catch let error as AgentFileMutationError {
                return Self.result(
                    requestedBytes: requestedBytes,
                    writtenBytes: 0,
                    error: error
                )
            } catch {
                return Self.result(
                    requestedBytes: requestedBytes,
                    writtenBytes: 0,
                    error: .targetStale
                )
            }

            // redeem 返回的 request 仍需与 exact capability 做 defense-in-depth
            // 校验；redeem 后 capability 取消只会导致无 mutation 的失败。
            guard Self.requestMatchesTarget(
                request,
                targetCapability: targetCapability
            ) else {
                return Self.result(
                    requestedBytes: requestedBytes,
                    writtenBytes: 0,
                    error: .targetStale
                )
            }

            // authorization 已消费；取消在此处被观察时，结果明确为未发布，
            // 且不会调用 mkdirat。
            guard !Task.isCancelled else {
                return Self.result(
                    requestedBytes: request.payloadIdentity.byteCount,
                    writtenBytes: 0,
                    error: .cancelled
                )
            }

            let execution = await targetCapability.withValidatedDirectoryDescriptor { parentFD in
                Self.executeFilesystem(
                    request: request,
                    parentFileDescriptor: parentFD,
                    fileSystem: fileSystem,
                    nameGenerator: nameGenerator,
                    hooks: hooks
                )
            }
            switch execution {
            case let .success(filesystemResult):
                switch filesystemResult {
                case let .success(outcome):
                    return outcome.result
                case let .failure(error):
                    return Self.result(
                        requestedBytes: request.payloadIdentity.byteCount,
                        writtenBytes: 0,
                        error: error
                    )
                }
            case let .failure(error):
                return Self.result(
                    requestedBytes: request.payloadIdentity.byteCount,
                    writtenBytes: 0,
                    error: error
                )
            }
        }

        return Self.result(
            requestedBytes: requestedBytes,
            writtenBytes: 0,
            error: parentError
        )
    }

    // MARK: Authorization and request validation

    private static func authorizationMatchesTarget(
        _ authorization: AgentFileMutationExecutionAuthorization,
        targetCapability: AgentLocalFileMutationTargetCapability
    ) -> Bool {
        authorization.targetIdentity == authorization.request.targetIdentity
            && authorization.logicalSessionID == authorization.request.logicalSessionID
            && authorization.generationID == authorization.request.generationID
            && authorization.callID == authorization.request.callID
            && authorization.request.parentCapability === targetCapability
            && authorization.request.targetIdentity.parentCapabilityIdentity == targetCapability.identity
            && authorization.targetIdentity.parentCapabilityIdentity == targetCapability.identity
            && authorization.request.payloadIdentity.byteCount == authorization.request.payloadUTF8.count
            && authorization.request.payloadUTF8 == Data(authorization.request.content.utf8)
    }

    private static func requestMatchesTarget(
        _ request: AgentFileMutationRequest,
        targetCapability: AgentLocalFileMutationTargetCapability
    ) -> Bool {
        request.parentCapability === targetCapability
            && request.targetIdentity.parentCapabilityIdentity == targetCapability.identity
            && request.targetIdentity.logicalSessionID == request.logicalSessionID
            && request.payloadIdentity.byteCount == request.payloadUTF8.count
            && request.payloadUTF8 == Data(request.content.utf8)
    }

    // MARK: Filesystem execution

    private struct FilesystemOutcome: Sendable {
        let result: AgentLocalFileMutationResult
    }

    private static func executeFilesystem(
        request: AgentFileMutationRequest,
        parentFileDescriptor: Int32,
        fileSystem: any AgentLocalFileMutationFileSystem,
        nameGenerator: any AgentLocalFileMutationNameGenerator,
        hooks: AgentLocalFileMutationExecutorHooks
    ) -> Result<FilesystemOutcome, AgentFileMutationError> {
        let requestedBytes = request.payloadUTF8.count
        let stagingName = nameGenerator.makeStagingDirectoryName()
        guard isSafeGeneratedBasename(stagingName) else {
            return .failure(.stagingDirectoryCreationFailed)
        }

        // 钩子只用于让测试在第一 mutation 前请求取消；production 为 nil。
        hooks.beforeFirstMutation?()
        guard !Task.isCancelled else {
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                error: .cancelled
            )))
        }

        // 这是整个执行流程的第一个 mutation syscall。
        guard case .success = fileSystem.createDirectory(
            parentFileDescriptor: parentFileDescriptor,
            name: stagingName,
            mode: 0o700
        ) else {
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                error: .stagingDirectoryCreationFailed
            )))
        }

        var stagingFileDescriptor: Int32?
        var temporaryFileDescriptor: Int32?
        var temporaryMetadata: AgentLocalFileMutationFileMetadata?
        var temporaryCreated = false
        defer {
            close(&temporaryFileDescriptor, fileSystem: fileSystem)
            close(&stagingFileDescriptor, fileSystem: fileSystem)
        }

        guard case let .success(openedStaging) = fileSystem.open(
            directoryFileDescriptor: parentFileDescriptor,
            name: stagingName,
            flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            mode: 0
        ) else {
            // open 失败时没有可信的 dev/ino pair，安全结果是报告 residue，
            // 而不是冒险删除可能已经被替换的 name。
            let cleanup = cleanupStagingWithoutIdentity(
                parentFileDescriptor: parentFileDescriptor,
                stagingName: stagingName,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                cleanupResidue: !cleanup,
                error: .stagingDirectoryOpenFailed
            )))
        }
        stagingFileDescriptor = openedStaging

        guard case let .success(capturedStagingMetadata) = fileSystem.metadata(
            fileDescriptor: openedStaging
        ) else {
            close(&stagingFileDescriptor, fileSystem: fileSystem)
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                cleanupResidue: true,
                error: .stagingDirectoryValidationFailed
            )))
        }
        guard capturedStagingMetadata.isDirectory,
              capturedStagingMetadata.ownerID == fileSystem.effectiveUserID(),
              capturedStagingMetadata.groupAndOtherPermissionBitsAreClear
        else {
            close(&stagingFileDescriptor, fileSystem: fileSystem)
            let cleanup = cleanupStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingName: stagingName,
                expected: capturedStagingMetadata,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                cleanupResidue: !cleanup,
                error: .stagingDirectoryValidationFailed
            )))
        }

        let temporaryName = nameGenerator.makeTemporaryFileName()
        guard isSafeGeneratedBasename(temporaryName) else {
            close(&stagingFileDescriptor, fileSystem: fileSystem)
            let cleanup = cleanupStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingName: stagingName,
                expected: capturedStagingMetadata,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                cleanupResidue: !cleanup,
                error: .tempFileCreationFailed
            )))
        }

        guard let openedStaging = stagingFileDescriptor,
              case let .success(openedTemporary) = fileSystem.open(
                  directoryFileDescriptor: openedStaging,
                  name: temporaryName,
                  flags: O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                  mode: 0o600
              )
        else {
            close(&stagingFileDescriptor, fileSystem: fileSystem)
            let cleanup = cleanupStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingName: stagingName,
                expected: capturedStagingMetadata,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                cleanupResidue: !cleanup,
                error: .tempFileCreationFailed
            )))
        }
        temporaryFileDescriptor = openedTemporary
        temporaryCreated = true

        guard case let .success(capturedTemporaryMetadata) = fileSystem.metadata(
            fileDescriptor: openedTemporary
        ) else {
            close(&temporaryFileDescriptor, fileSystem: fileSystem)
            let cleanup = cleanupTemporaryAndStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingFileDescriptor: &stagingFileDescriptor,
                stagingName: stagingName,
                stagingMetadata: capturedStagingMetadata,
                temporaryName: temporaryName,
                temporaryMetadata: nil,
                temporaryCreated: temporaryCreated,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                cleanupResidue: !cleanup,
                error: .tempFileValidationFailed
            )))
        }
        temporaryMetadata = capturedTemporaryMetadata

        guard capturedTemporaryMetadata.isRegularFile,
              capturedTemporaryMetadata.ownerID == fileSystem.effectiveUserID(),
              capturedTemporaryMetadata.groupAndOtherPermissionBitsAreClear,
              capturedTemporaryMetadata.linkCount == 1
        else {
            close(&temporaryFileDescriptor, fileSystem: fileSystem)
            let cleanup = cleanupTemporaryAndStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingFileDescriptor: &stagingFileDescriptor,
                stagingName: stagingName,
                stagingMetadata: capturedStagingMetadata,
                temporaryName: temporaryName,
                temporaryMetadata: capturedTemporaryMetadata,
                temporaryCreated: temporaryCreated,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                cleanupResidue: !cleanup,
                error: .tempFileValidationFailed
            )))
        }

        guard let openedTemporary = temporaryFileDescriptor else {
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: 0,
                cleanupResidue: true,
                error: .tempFileValidationFailed
            )))
        }

        var payloadBytesWritten = 0
        while payloadBytesWritten < requestedBytes {
            guard !Task.isCancelled else {
                let cleanup = cleanupTemporaryAndStaging(
                    parentFileDescriptor: parentFileDescriptor,
                    stagingFileDescriptor: &stagingFileDescriptor,
                    stagingName: stagingName,
                    stagingMetadata: capturedStagingMetadata,
                    temporaryName: temporaryName,
                    temporaryMetadata: temporaryMetadata,
                    temporaryCreated: temporaryCreated,
                    fileSystem: fileSystem
                )
                return .success(FilesystemOutcome(result: result(
                    requestedBytes: requestedBytes,
                    writtenBytes: payloadBytesWritten,
                    cleanupResidue: !cleanup,
                    error: .cancelled
                )))
            }

            let remaining = request.payloadUTF8.subdata(in: payloadBytesWritten..<requestedBytes)
            switch fileSystem.write(fileDescriptor: openedTemporary, data: remaining) {
            case let .success(count) where count > 0 && count <= remaining.count:
                payloadBytesWritten += count
            case .success(0):
                let cleanup = cleanupTemporaryAndStaging(
                    parentFileDescriptor: parentFileDescriptor,
                    stagingFileDescriptor: &stagingFileDescriptor,
                    stagingName: stagingName,
                    stagingMetadata: capturedStagingMetadata,
                    temporaryName: temporaryName,
                    temporaryMetadata: temporaryMetadata,
                    temporaryCreated: temporaryCreated,
                    fileSystem: fileSystem
                )
                return .success(FilesystemOutcome(result: result(
                    requestedBytes: requestedBytes,
                    writtenBytes: payloadBytesWritten,
                    cleanupResidue: !cleanup,
                    error: .zeroByteWrite
                )))
            case .success:
                let cleanup = cleanupTemporaryAndStaging(
                    parentFileDescriptor: parentFileDescriptor,
                    stagingFileDescriptor: &stagingFileDescriptor,
                    stagingName: stagingName,
                    stagingMetadata: capturedStagingMetadata,
                    temporaryName: temporaryName,
                    temporaryMetadata: temporaryMetadata,
                    temporaryCreated: temporaryCreated,
                    fileSystem: fileSystem
                )
                return .success(FilesystemOutcome(result: result(
                    requestedBytes: requestedBytes,
                    writtenBytes: payloadBytesWritten,
                    cleanupResidue: !cleanup,
                    error: .payloadWriteFailed
                )))
            case let .failure(failure) where failure.code == EINTR:
                // EINTR 只重试同一个 remaining slice；不增加 byte count。
                continue
            case .failure:
                let cleanup = cleanupTemporaryAndStaging(
                    parentFileDescriptor: parentFileDescriptor,
                    stagingFileDescriptor: &stagingFileDescriptor,
                    stagingName: stagingName,
                    stagingMetadata: capturedStagingMetadata,
                    temporaryName: temporaryName,
                    temporaryMetadata: temporaryMetadata,
                    temporaryCreated: temporaryCreated,
                    fileSystem: fileSystem
                )
                return .success(FilesystemOutcome(result: result(
                    requestedBytes: requestedBytes,
                    writtenBytes: payloadBytesWritten,
                    cleanupResidue: !cleanup,
                    error: .payloadWriteFailed
                )))
            }
        }

        // 空 payload 不进入上面的 write loop；仍然必须 fsync temp FD。
        guard !Task.isCancelled else {
            let cleanup = cleanupTemporaryAndStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingFileDescriptor: &stagingFileDescriptor,
                stagingName: stagingName,
                stagingMetadata: capturedStagingMetadata,
                temporaryName: temporaryName,
                temporaryMetadata: temporaryMetadata,
                temporaryCreated: temporaryCreated,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: payloadBytesWritten,
                cleanupResidue: !cleanup,
                error: .cancelled
            )))
        }

        guard case .success = fileSystem.synchronize(fileDescriptor: openedTemporary) else {
            let cleanup = cleanupTemporaryAndStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingFileDescriptor: &stagingFileDescriptor,
                stagingName: stagingName,
                stagingMetadata: capturedStagingMetadata,
                temporaryName: temporaryName,
                temporaryMetadata: temporaryMetadata,
                temporaryCreated: temporaryCreated,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: payloadBytesWritten,
                cleanupResidue: !cleanup,
                error: .tempSyncFailed
            )))
        }

        // temp FD 已 fsync；publication 前不再需要持有它。source identity
        // recheck 仍通过 staging FD+name 执行，并使用 no-follow metadata。
        close(&temporaryFileDescriptor, fileSystem: fileSystem)
        hooks.afterFsyncBeforePublication?()
        guard !Task.isCancelled else {
            let cleanup = cleanupTemporaryAndStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingFileDescriptor: &stagingFileDescriptor,
                stagingName: stagingName,
                stagingMetadata: capturedStagingMetadata,
                temporaryName: temporaryName,
                temporaryMetadata: temporaryMetadata,
                temporaryCreated: temporaryCreated,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: payloadBytesWritten,
                cleanupResidue: !cleanup,
                error: .cancelled
            )))
        }

        guard let openedStaging = stagingFileDescriptor else {
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: payloadBytesWritten,
                cleanupResidue: true,
                error: .parentCapabilityStale
            )))
        }

        // 测试可在这里替换 source；production 没有钩子副作用。
        hooks.beforePublication?()
        guard !Task.isCancelled,
              sourceStillMatches(
                  stagingFileDescriptor: openedStaging,
                  temporaryName: temporaryName,
                  expected: capturedTemporaryMetadata,
                  fileSystem: fileSystem
              )
        else {
            let cleanup = cleanupTemporaryAndStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingFileDescriptor: &stagingFileDescriptor,
                stagingName: stagingName,
                stagingMetadata: capturedStagingMetadata,
                temporaryName: temporaryName,
                temporaryMetadata: capturedTemporaryMetadata,
                temporaryCreated: temporaryCreated,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: payloadBytesWritten,
                cleanupResidue: !cleanup,
                error: Task.isCancelled ? .cancelled : .sourceReplaced
            )))
        }

        let preferredPublication = fileSystem.publishExclusively(
            sourceDirectoryFileDescriptor: openedStaging,
            sourceName: temporaryName,
            destinationDirectoryFileDescriptor: parentFileDescriptor,
            destinationName: request.targetIdentity.basename
        )

        switch preferredPublication {
        case .success:
            close(&stagingFileDescriptor, fileSystem: fileSystem)
            let cleanup = cleanupStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingName: stagingName,
                expected: capturedStagingMetadata,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                published: true,
                publicationMethod: .rename,
                requestedBytes: requestedBytes,
                writtenBytes: payloadBytesWritten,
                cleanupResidue: !cleanup,
                error: cleanup ? nil : .cleanupResidue
            )))

        case let .failure(failure) where isExplicitlyUnsupportedRename(failure.code):
            // 只有明确的 unsupported/unavailable 才允许进入 linkat fallback。
            guard !Task.isCancelled,
                  sourceStillMatches(
                      stagingFileDescriptor: openedStaging,
                      temporaryName: temporaryName,
                      expected: capturedTemporaryMetadata,
                      fileSystem: fileSystem
                  )
            else {
                let cleanup = cleanupTemporaryAndStaging(
                    parentFileDescriptor: parentFileDescriptor,
                    stagingFileDescriptor: &stagingFileDescriptor,
                    stagingName: stagingName,
                    stagingMetadata: capturedStagingMetadata,
                    temporaryName: temporaryName,
                    temporaryMetadata: capturedTemporaryMetadata,
                    temporaryCreated: temporaryCreated,
                    fileSystem: fileSystem
                )
                return .success(FilesystemOutcome(result: result(
                    requestedBytes: requestedBytes,
                    writtenBytes: payloadBytesWritten,
                    cleanupResidue: !cleanup,
                    error: Task.isCancelled ? .cancelled : .sourceReplaced
                )))
            }

            let fallbackPublication = fileSystem.linkWithoutClobber(
                sourceDirectoryFileDescriptor: openedStaging,
                sourceName: temporaryName,
                destinationDirectoryFileDescriptor: parentFileDescriptor,
                destinationName: request.targetIdentity.basename
            )
            switch fallbackPublication {
            case .success:
                // link 成功后 destination 已经发布；source unlink 失败不能
                // 把结果改写成 unpublished，也不能删除 destination。
                let sourceCleanup = unlinkExpectedTemporary(
                    stagingFileDescriptor: openedStaging,
                    temporaryName: temporaryName,
                    expected: capturedTemporaryMetadata,
                    fileSystem: fileSystem
                )
                close(&stagingFileDescriptor, fileSystem: fileSystem)
                let stagingCleanup = cleanupStaging(
                    parentFileDescriptor: parentFileDescriptor,
                    stagingName: stagingName,
                    expected: capturedStagingMetadata,
                    fileSystem: fileSystem
                )
                let residue = !sourceCleanup || !stagingCleanup
                return .success(FilesystemOutcome(result: result(
                    published: true,
                    publicationMethod: .fallbackLink,
                    requestedBytes: requestedBytes,
                    writtenBytes: payloadBytesWritten,
                    cleanupResidue: residue,
                    error: residue ? .cleanupResidue : nil
                )))

            case let .failure(failure) where failure.code == EEXIST:
                let cleanup = cleanupTemporaryAndStaging(
                    parentFileDescriptor: parentFileDescriptor,
                    stagingFileDescriptor: &stagingFileDescriptor,
                    stagingName: stagingName,
                    stagingMetadata: capturedStagingMetadata,
                    temporaryName: temporaryName,
                    temporaryMetadata: capturedTemporaryMetadata,
                    temporaryCreated: temporaryCreated,
                    fileSystem: fileSystem
                )
                return .success(FilesystemOutcome(result: result(
                    requestedBytes: requestedBytes,
                    writtenBytes: payloadBytesWritten,
                    cleanupResidue: !cleanup,
                    error: .destinationAlreadyExists
                )))

            case .failure:
                let cleanup = cleanupTemporaryAndStaging(
                    parentFileDescriptor: parentFileDescriptor,
                    stagingFileDescriptor: &stagingFileDescriptor,
                    stagingName: stagingName,
                    stagingMetadata: capturedStagingMetadata,
                    temporaryName: temporaryName,
                    temporaryMetadata: capturedTemporaryMetadata,
                    temporaryCreated: temporaryCreated,
                    fileSystem: fileSystem
                )
                return .success(FilesystemOutcome(result: result(
                    requestedBytes: requestedBytes,
                    writtenBytes: payloadBytesWritten,
                    cleanupResidue: !cleanup,
                    error: .fallbackPublicationFailed
                )))
            }

        case let .failure(failure) where failure.code == EEXIST:
            let cleanup = cleanupTemporaryAndStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingFileDescriptor: &stagingFileDescriptor,
                stagingName: stagingName,
                stagingMetadata: capturedStagingMetadata,
                temporaryName: temporaryName,
                temporaryMetadata: capturedTemporaryMetadata,
                temporaryCreated: temporaryCreated,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: payloadBytesWritten,
                cleanupResidue: !cleanup,
                error: .destinationAlreadyExists
            )))

        case .failure:
            // EACCES/EPERM/ENOSPC/EROFS 等普通失败不得误判为 unsupported，
            // 也不得 fallback 到 linkat。
            let cleanup = cleanupTemporaryAndStaging(
                parentFileDescriptor: parentFileDescriptor,
                stagingFileDescriptor: &stagingFileDescriptor,
                stagingName: stagingName,
                stagingMetadata: capturedStagingMetadata,
                temporaryName: temporaryName,
                temporaryMetadata: capturedTemporaryMetadata,
                temporaryCreated: temporaryCreated,
                fileSystem: fileSystem
            )
            return .success(FilesystemOutcome(result: result(
                requestedBytes: requestedBytes,
                writtenBytes: payloadBytesWritten,
                cleanupResidue: !cleanup,
                error: .publicationFailed
            )))
        }
    }

    // MARK: Cleanup and metadata guards

    private static func cleanupTemporaryAndStaging(
        parentFileDescriptor: Int32,
        stagingFileDescriptor: inout Int32?,
        stagingName: String,
        stagingMetadata: AgentLocalFileMutationFileMetadata,
        temporaryName: String,
        temporaryMetadata: AgentLocalFileMutationFileMetadata?,
        temporaryCreated: Bool,
        fileSystem: any AgentLocalFileMutationFileSystem
    ) -> Bool {
        var residue = false

        if let stagingFD = stagingFileDescriptor, temporaryCreated {
            if let temporaryMetadata {
                if !unlinkExpectedTemporary(
                    stagingFileDescriptor: stagingFD,
                    temporaryName: temporaryName,
                    expected: temporaryMetadata,
                    fileSystem: fileSystem
                ) {
                    residue = true
                }
            } else {
                residue = true
            }
        }

        close(&stagingFileDescriptor, fileSystem: fileSystem)
        if !cleanupStaging(
            parentFileDescriptor: parentFileDescriptor,
            stagingName: stagingName,
            expected: stagingMetadata,
            fileSystem: fileSystem
        ) {
            residue = true
        }
        return !residue
    }

    private static func cleanupStagingWithoutIdentity(
        parentFileDescriptor: Int32,
        stagingName: String,
        fileSystem: any AgentLocalFileMutationFileSystem
    ) -> Bool {
        // 没有 mkdirat 返回对象的 dev/ino，就不能安全地删除同名对象。
        // 这里明确保守报告 residue；不会触碰 replacement。
        _ = parentFileDescriptor
        _ = stagingName
        _ = fileSystem
        return false
    }

    private static func cleanupStaging(
        parentFileDescriptor: Int32,
        stagingName: String,
        expected: AgentLocalFileMutationFileMetadata,
        fileSystem: any AgentLocalFileMutationFileSystem
    ) -> Bool {
        switch fileSystem.metadataAt(
            directoryFileDescriptor: parentFileDescriptor,
            name: stagingName,
            noFollow: true
        ) {
        case let .failure(failure) where failure.code == ENOENT:
            return true
        case .failure:
            return false
        case let .success(current):
            guard current.isDirectory,
                  current.deviceID == expected.deviceID,
                  current.inode == expected.inode
            else {
                // name 已被替换；绝不 unlink replacement。
                return false
            }

            // 这是有意记录的 residual check→unlink race：同 UID attacker
            // 仍可在两次 syscall 之间替换 name，C2 不宣称消除该 accepted gap。
            switch fileSystem.unlink(
                directoryFileDescriptor: parentFileDescriptor,
                name: stagingName,
                removeDirectory: true
            ) {
            case .success:
                return true
            case .failure:
                return false
            }
        }
    }

    private static func sourceStillMatches(
        stagingFileDescriptor: Int32,
        temporaryName: String,
        expected: AgentLocalFileMutationFileMetadata,
        fileSystem: any AgentLocalFileMutationFileSystem
    ) -> Bool {
        guard case let .success(current) = fileSystem.metadataAt(
            directoryFileDescriptor: stagingFileDescriptor,
            name: temporaryName,
            noFollow: true
        ) else {
            return false
        }
        return current.isRegularFile
            && current.deviceID == expected.deviceID
            && current.inode == expected.inode
    }

    private static func unlinkExpectedTemporary(
        stagingFileDescriptor: Int32,
        temporaryName: String,
        expected: AgentLocalFileMutationFileMetadata,
        fileSystem: any AgentLocalFileMutationFileSystem
    ) -> Bool {
        switch fileSystem.metadataAt(
            directoryFileDescriptor: stagingFileDescriptor,
            name: temporaryName,
            noFollow: true
        ) {
        case let .failure(failure) where failure.code == ENOENT:
            return true
        case .failure:
            return false
        case let .success(current):
            guard current.isRegularFile,
                  current.deviceID == expected.deviceID,
                  current.inode == expected.inode
            else {
                // temp name 已被替换；绝不 unlink replacement。
                return false
            }
            // 同样保留 check→unlink 的 accepted residual race 说明。
            switch fileSystem.unlink(
                directoryFileDescriptor: stagingFileDescriptor,
                name: temporaryName,
                removeDirectory: false
            ) {
            case .success:
                return true
            case .failure:
                return false
            }
        }
    }

    private static func close(
        _ descriptor: inout Int32?,
        fileSystem: any AgentLocalFileMutationFileSystem
    ) {
        guard let value = descriptor else { return }
        fileSystem.close(fileDescriptor: value)
        descriptor = nil
    }

    // MARK: Stable helpers

    private static func result(
        published: Bool = false,
        publicationMethod: AgentLocalFileMutationPublicationMethod? = nil,
        requestedBytes: Int,
        writtenBytes: Int,
        cleanupResidue: Bool = false,
        error: AgentFileMutationError?
    ) -> AgentLocalFileMutationResult {
        AgentLocalFileMutationResult(
            published: published,
            publicationMethod: publicationMethod,
            payloadBytesRequested: requestedBytes,
            payloadBytesWrittenToTemp: writtenBytes,
            cleanupComplete: !cleanupResidue,
            cleanupResidue: cleanupResidue,
            error: error
        )
    }

    private static func isSafeGeneratedBasename(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }

    /// Fallback 只接受明确的 unavailable/unsupported errno；普通错误（包括
    /// EEXIST、EACCES、EPERM、ENOSPC、EROFS）绝不进入 linkat。
    private static func isExplicitlyUnsupportedRename(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS
    }
}
