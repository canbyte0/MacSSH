import Darwin
import Foundation

@testable import MacSSH

/// C1 测试的统一 fixture：所有临时对象均位于 XCTest 临时目录并由各测试清理。
enum AgentFileMutationTestSupport {
    static let generationID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    static let sessionID = UUID(uuidString: "22222222-0000-0000-0000-000000000001")!
    static let providerSnapshotID = UUID(uuidString: "33333333-0000-0000-0000-000000000001")!
    static let createdAt = Date(timeIntervalSince1970: 1_760_100_000)

    /// 生成唯一的 isolated root，避免测试互相看到路径状态。
    static func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-c1-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// 以 libc realpath 验证真实 inode 路径，规避 macOS `/var` 与
    /// `/private/var` 的兼容表示差异；这不参与生产 C1 的路径解析。
    static func canonicalPathForAssertion(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else {
            throw POSIXError(.ENOENT)
        }
        guard let terminator = buffer.firstIndex(of: 0) else {
            throw POSIXError(.EINVAL)
        }
        return String(
            decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    /// 构造冻结的 provider identity；它不含 credential。
    static var providerBinding: AgentCommandProviderBinding {
        AgentCommandProviderBinding(
            snapshotID: providerSnapshotID,
            provider: .openAI,
            model: "c1-test-model",
            baseURL: URL(string: "https://example.invalid/v1")!
        )
    }

    /// 从临时 root 构造权威 cwd 对应的独立 write scope。
    static func makeScope(
        root: URL,
        sessionID: UUID = AgentFileMutationTestSupport.sessionID
    ) throws -> AgentWriteScope {
        try AgentWriteScope.make(
            logicalSessionID: sessionID,
            workingDirectory: AgentWorkingDirectory(
                path: root.path,
                source: .osc7,
                confidence: .authoritative
            )
        ).get()
    }

    /// 构造一个合法、尚未注册 Provider tool 的 internal proposal。
    static func makeRequest(
        root: URL,
        path: String = "new-file.txt",
        content: String = "中文🙂e\u{301}\n",
        generationID: UUID = AgentFileMutationTestSupport.generationID,
        callID: String = "call-c1-1",
        sessionID: UUID = AgentFileMutationTestSupport.sessionID,
        scope: AgentWriteScope? = nil
    ) async throws -> AgentFileMutationRequest {
        let actualScope = try scope ?? makeScope(root: root, sessionID: sessionID)
        let result = await AgentFileMutationRequestFactory.make(
            generationID: generationID,
            callID: callID,
            logicalSessionID: sessionID,
            writeScope: actualScope,
            userSuppliedPath: path,
            content: content,
            providerBinding: providerBinding,
            createdAt: createdAt
        )
        return try result.get()
    }

    /// 从 request 自身生成完整 claim expectations，避免测试重算 security binding。
    static func expectations(
        for request: AgentFileMutationRequest
    ) -> AgentFileMutationClaimExpectations {
        AgentFileMutationClaimExpectations(
            generationID: request.generationID,
            callID: request.callID,
            logicalSessionID: request.logicalSessionID,
            providerSnapshotID: request.providerBinding.snapshotID,
            targetIdentity: request.targetIdentity
        )
    }

    /// 每个测试结束时删除自己的临时树，忽略清理错误以保留原始断言失败。
    static func removeTemporaryRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - C2 deterministic filesystem seam

/// 固定名称生成器让测试可以在 publication barrier 上精确定位私有对象。
struct AgentFileMutationFixedNameGenerator: AgentLocalFileMutationNameGenerator {
    let stagingName: String
    let temporaryName: String

    func makeStagingDirectoryName() -> String { stagingName }
    func makeTemporaryFileName() -> String { temporaryName }
}

/// 注入 C2 低层 syscall 结果的最小 fake。
///
/// 正常路径仍委托给 Darwin backend；只有明确指定的 write/fsync/rename/
/// link/unlink 调用被替换，因此测试不会把高层 FileManager 当成 production
/// 实现，也能验证 short write、EINTR 与 fallback 分类。
final class AgentFileMutationInjectingFileSystem: @unchecked Sendable, AgentLocalFileMutationFileSystem {
    enum WritePlan: Sendable {
        case passthrough
        case partial(Int)
        case eintr
        case zero
        case fatal(Int32)
    }

    private let base = AgentLocalFileMutationDarwinFileSystem()
    private let lock = NSLock()
    private var plans: [WritePlan]
    private var stagingName: String?
    private var temporaryName: String?
    private var writeCallCount = 0
    private var synchronizeCallCount = 0
    private var mkdirCallCount = 0
    private var publishCallCount = 0
    private var linkCallCount = 0
    private var unlinkCallCount = 0

    let synchronizeFailure: Int32?
    let preferredPublicationFailure: Int32?
    let fallbackLinkFailure: Int32?
    let unlinkFailureCall: Int?
    var afterSynchronize: (() -> Void)?
    var afterWrite: (() -> Void)?
    var beforePreferredPublication: (() -> Void)?
    var afterPreferredPublication: (() -> Void)?

    init(
        plans: [WritePlan] = [],
        synchronizeFailure: Int32? = nil,
        preferredPublicationFailure: Int32? = nil,
        fallbackLinkFailure: Int32? = nil,
        unlinkFailureCall: Int? = nil
    ) {
        self.plans = plans
        self.synchronizeFailure = synchronizeFailure
        self.preferredPublicationFailure = preferredPublicationFailure
        self.fallbackLinkFailure = fallbackLinkFailure
        self.unlinkFailureCall = unlinkFailureCall
    }

    func observedNames() -> (staging: String?, temporary: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (stagingName, temporaryName)
    }

    func observedCounts() -> (
        mkdir: Int,
        writes: Int,
        synchronize: Int,
        publish: Int,
        link: Int,
        unlink: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            mkdirCallCount,
            writeCallCount,
            synchronizeCallCount,
            publishCallCount,
            linkCallCount,
            unlinkCallCount
        )
    }

    func createDirectory(
        parentFileDescriptor: Int32,
        name: String,
        mode: UInt16
    ) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        lock.lock()
        mkdirCallCount += 1
        stagingName = name
        lock.unlock()
        return base.createDirectory(parentFileDescriptor: parentFileDescriptor, name: name, mode: mode)
    }

    func open(
        directoryFileDescriptor: Int32,
        name: String,
        flags: Int32,
        mode: UInt16
    ) -> Result<Int32, AgentLocalFileMutationSystemFailure> {
        lock.lock()
        if temporaryName == nil, name != stagingName {
            temporaryName = name
        }
        lock.unlock()
        return base.open(
            directoryFileDescriptor: directoryFileDescriptor,
            name: name,
            flags: flags,
            mode: mode
        )
    }

    func metadata(fileDescriptor: Int32) -> Result<AgentLocalFileMutationFileMetadata, AgentLocalFileMutationSystemFailure> {
        base.metadata(fileDescriptor: fileDescriptor)
    }

    func metadataAt(
        directoryFileDescriptor: Int32,
        name: String,
        noFollow: Bool
    ) -> Result<AgentLocalFileMutationFileMetadata, AgentLocalFileMutationSystemFailure> {
        base.metadataAt(
            directoryFileDescriptor: directoryFileDescriptor,
            name: name,
            noFollow: noFollow
        )
    }

    func write(fileDescriptor: Int32, data: Data) -> Result<Int, AgentLocalFileMutationSystemFailure> {
        lock.lock()
        writeCallCount += 1
        let plan = plans.isEmpty ? .passthrough : plans.removeFirst()
        lock.unlock()

        let result: Result<Int, AgentLocalFileMutationSystemFailure>
        switch plan {
        case .passthrough:
            result = base.write(fileDescriptor: fileDescriptor, data: data)
        case let .partial(count):
            let boundedCount = min(max(count, 0), data.count)
            result = base.write(
                fileDescriptor: fileDescriptor,
                data: Data(data.prefix(boundedCount))
            )
        case .eintr:
            result = .failure(AgentLocalFileMutationSystemFailure(EINTR))
        case .zero:
            result = .success(0)
        case let .fatal(code):
            result = .failure(AgentLocalFileMutationSystemFailure(code))
        }
        afterWrite?()
        return result
    }

    func synchronize(fileDescriptor: Int32) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        lock.lock()
        synchronizeCallCount += 1
        lock.unlock()
        let result: Result<Void, AgentLocalFileMutationSystemFailure>
        if let synchronizeFailure {
            result = .failure(AgentLocalFileMutationSystemFailure(synchronizeFailure))
        } else {
            result = base.synchronize(fileDescriptor: fileDescriptor)
        }
        afterSynchronize?()
        return result
    }

    func publishExclusively(
        sourceDirectoryFileDescriptor: Int32,
        sourceName: String,
        destinationDirectoryFileDescriptor: Int32,
        destinationName: String
    ) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        lock.lock()
        publishCallCount += 1
        lock.unlock()
        beforePreferredPublication?()
        if let preferredPublicationFailure {
            return .failure(AgentLocalFileMutationSystemFailure(preferredPublicationFailure))
        }
        let result = base.publishExclusively(
            sourceDirectoryFileDescriptor: sourceDirectoryFileDescriptor,
            sourceName: sourceName,
            destinationDirectoryFileDescriptor: destinationDirectoryFileDescriptor,
            destinationName: destinationName
        )
        if case .success = result {
            afterPreferredPublication?()
        }
        return result
    }

    func linkWithoutClobber(
        sourceDirectoryFileDescriptor: Int32,
        sourceName: String,
        destinationDirectoryFileDescriptor: Int32,
        destinationName: String
    ) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        lock.lock()
        linkCallCount += 1
        lock.unlock()
        if let fallbackLinkFailure {
            return .failure(AgentLocalFileMutationSystemFailure(fallbackLinkFailure))
        }
        return base.linkWithoutClobber(
            sourceDirectoryFileDescriptor: sourceDirectoryFileDescriptor,
            sourceName: sourceName,
            destinationDirectoryFileDescriptor: destinationDirectoryFileDescriptor,
            destinationName: destinationName
        )
    }

    func unlink(
        directoryFileDescriptor: Int32,
        name: String,
        removeDirectory: Bool
    ) -> Result<Void, AgentLocalFileMutationSystemFailure> {
        lock.lock()
        unlinkCallCount += 1
        let call = unlinkCallCount
        lock.unlock()
        if let unlinkFailureCall, unlinkFailureCall == call {
            return .failure(AgentLocalFileMutationSystemFailure(EIO))
        }
        return base.unlink(
            directoryFileDescriptor: directoryFileDescriptor,
            name: name,
            removeDirectory: removeDirectory
        )
    }

    func close(fileDescriptor: Int32) {
        base.close(fileDescriptor: fileDescriptor)
    }

    func effectiveUserID() -> UInt32 {
        base.effectiveUserID()
    }
}
