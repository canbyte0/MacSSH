import CryptoKit
import Foundation

// MARK: - Stable domain failures

/// Local file-mutation domain 的稳定失败码。
///
/// 每个 case 都不携带路径、payload、凭据或 errno，避免错误传播成为内容
/// 泄漏通道；底层 errno 只在 capability 层用于映射此处的稳定语义。
enum AgentFileMutationError: Error, Equatable, Sendable {
    /// 用户路径结构不合法，且绝不进行静默改写。
    case invalidPath
    /// Provider 侧可见的文本超过冻结的 256 KiB UTF-8 上限。
    case payloadTooLarge
    /// 仅有权威 cwd 才能作为相对路径的 proposal-time 基准。
    case cwdUnavailable
    /// 解析后的父目录不在独立的 write scope 内。
    case outsideWriteScope
    /// 父目录不存在、不可搜索或无法读取其 metadata。
    case parentUnavailable
    /// 父路径不是目录。
    case parentNotDirectory
    /// 最终父目录组件是符号链接，不能作为 capability 的入口。
    case parentSymlinkRejected
    /// create-only 语义下，目标 basename 在 proposal 时已存在。
    case destinationAlreadyExists
    /// 授权携带的冻结绑定不再匹配 coordinator 中的记录。
    case targetStale
    /// 指定 approval 不存在。
    case approvalNotFound
    /// approval 尚未获得显式同意。
    case approvalRequired
    /// 用户显式拒绝了本次 proposal。
    case userDenied
    /// generation 或 logical session 已取消 proposal。
    case generationCancelled
    /// 同一 approval 已有一个成功的 claim。
    case approvalAlreadyClaimed
    /// 同一 permit 已被成功消费。
    case approvalAlreadyConsumed
    /// claim 所给 generation / call / session / provider / target 不匹配。
    case bindingMismatch
    /// C2 执行时 parent capability 已关闭或不再对应 proposal-time object。
    case parentCapabilityUnavailable
    /// C2 不能通过一个已验证的 parent capability 开始 side effect。
    case parentCapabilityStale
    /// staging directory 的 mkdirat 失败。
    case stagingDirectoryCreationFailed
    /// staging directory 无法以要求的 flags 打开。
    case stagingDirectoryOpenFailed
    /// staging directory 的立即 metadata 校验失败。
    case stagingDirectoryValidationFailed
    /// private temp file 的 O_EXCL 创建失败。
    case tempFileCreationFailed
    /// private temp file 的立即 metadata 校验失败。
    case tempFileValidationFailed
    /// payload 的短写入循环遇到不可恢复的 write failure。
    case payloadWriteFailed
    /// remaining payload 存在时底层 write 返回零字节。
    case zeroByteWrite
    /// temp FD 的 fsync 失败。
    case tempSyncFailed
    /// publication 前 source name 已不再指向预期 temp object。
    case sourceReplaced
    /// preferred/fallback publication 均未发布 destination 的一般失败。
    case publicationFailed
    /// fallback link publication 的一般失败。
    case fallbackPublicationFailed
    /// 已完成发布，但私有 residue 无法安全清理。
    case cleanupResidue
    /// 执行在下一次 filesystem side effect 前观察到取消。
    case cancelled
}

/// Phase 10F-C1-R1 冻结的 file-mutation payload 契约（canonical 定义）。
///
/// - content type：TEXT ONLY（Swift `String`，构造上即合法 UTF-8）。
/// - encoding：exact UTF-8；authority 是 `Data(content.utf8)` 的精确字节。
/// - allowed size：`0...262144` bytes（含两端；空 payload 合法，future C2
///   将据此创建空文件）。
/// - binary / base64：Phase 10F-C 不支持；binary file mutation DEFERRED。
/// - 字节语义：绝不 trim、不做换行归一化、不做 Unicode NFC/NFD 归一化、
///   不插入 BOM、不改写行尾、不做 locale 转换；上限按 UTF-8 字节而非
///   Swift 字符数计算。
/// - 校验点：proposal factory（审批之前）；超限即 `.payloadTooLarge` 整体
///   拒绝，绝不截断。
enum AgentFileMutationLimits: Sendable {
    /// 256 KiB = 262144 bytes。此常量是生产代码中唯一的 canonical 定义，
    /// 其余任何位置（含 future C2 executor）一律引用本常量，禁止散落
    /// magic number。
    static let maxPayloadBytes = 256 * 1024
}

// MARK: - Separate write scope

/// 仅用于 future local file mutation 的独立范围模型。
///
/// 该类型刻意不复用 `AgentReadScope`：两者虽同样从权威 CWD 取得
/// canonical root，却具有不同的安全语义。此类型不持有任何文件描述符，
/// 也不构成最终授权；最终 authority 是 proposal 时捕获的 parent capability。
struct AgentWriteScope: Sendable, Equatable {
    /// 此 scope 绑定的 logical session。
    let logicalSessionID: UUID
    /// proposal 时由组件级 canonicalization 得到的 CWD/root 快照。
    let canonicalRoot: String

    /// scope 只能由权威 CWD 工厂创建，禁止调用方直接伪造 canonical root。
    private init(logicalSessionID: UUID, canonicalRoot: String) {
        self.logicalSessionID = logicalSessionID
        self.canonicalRoot = canonicalRoot
    }

    /// 只接受本地、权威且绝对的 CWD；不存在 fallback。
    static func make(
        logicalSessionID: UUID,
        workingDirectory: AgentWorkingDirectory
    ) -> Result<AgentWriteScope, AgentFileMutationError> {
        guard
            workingDirectory.confidence == .authoritative,
            let cwd = workingDirectory.path,
            !cwd.isEmpty,
            cwd.hasPrefix("/"),
            let canonicalRoot = AgentPathResolver.canonicalize(cwd, kind: .local)
        else {
            return .failure(.cwdUnavailable)
        }
        return .success(AgentWriteScope(
            logicalSessionID: logicalSessionID,
            canonicalRoot: canonicalRoot
        ))
    }

    /// 组件边界 containment，避免 `/root` 误匹配 `/root-elsewhere`。
    func contains(_ canonicalPath: String) -> Bool {
        if canonicalRoot == "/" {
            return canonicalPath.hasPrefix("/")
        }
        return canonicalPath == canonicalRoot || canonicalPath.hasPrefix(canonicalRoot + "/")
    }
}

// MARK: - Immutable identities

/// directory object 的不可变记录身份；绝不以可复用的 raw FD number 定义。
struct AgentLocalFileMutationCapabilityIdentity: Sendable, Equatable, Hashable {
    /// 应用为每次 capture 生成的生命周期 token。
    let capabilityToken: UUID
    /// 父目录对象的 filesystem identity。
    let deviceID: UInt64
    let inode: UInt64
    /// proposal 时仅供诊断/测试的目录 metadata snapshot。
    let ownerID: UInt32
    let groupID: UInt32
    let mode: UInt16
}

/// 文件 basename 与 frozen parent capability 的不可变目标绑定。
struct AgentFileMutationTargetIdentity: Sendable, Equatable, Hashable {
    /// 原始 session identity；不从 active tab 回查。
    let logicalSessionID: UUID
    /// proposal-time canonical CWD/root snapshot。
    let proposalWorkingDirectory: String
    /// 父目录 capability 的对象身份。
    let parentCapabilityIdentity: AgentLocalFileMutationCapabilityIdentity
    /// 不含 `/` 的最终名称。
    let basename: String
    /// 应用生成、不可由 path/content/callID 推导的 approval binding token。
    let targetToken: UUID

    /// 仅 request factory 能把 capability identity 组装成目标绑定。
    fileprivate init(
        logicalSessionID: UUID,
        proposalWorkingDirectory: String,
        parentCapabilityIdentity: AgentLocalFileMutationCapabilityIdentity,
        basename: String,
        targetToken: UUID
    ) {
        self.logicalSessionID = logicalSessionID
        self.proposalWorkingDirectory = proposalWorkingDirectory
        self.parentCapabilityIdentity = parentCapabilityIdentity
        self.basename = basename
        self.targetToken = targetToken
    }
}

/// 精确 UTF-8 payload 的不可变 identity；digest 仅用于等价校验，不用于日志。
struct AgentFileMutationPayloadIdentity: Sendable, Equatable {
    let byteCount: Int
    let sha256: Data

    /// payload identity 只能从 factory 捕获的 exact UTF-8 bytes 派生。
    fileprivate init(byteCount: Int, sha256: Data) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

// MARK: - Immutable proposal request

/// C1 的 provider-independent local file mutation proposal。
///
/// 所有字段均为 `let`。该值持有 exact UTF-8 bytes、proposal-time target
/// identity 与 directory capability；approval 后不得从 Provider、UI 或当前
/// terminal session 重取任何可变值。C1 不消费该 request 做 filesystem side effect。
struct AgentFileMutationRequest: Sendable {
    let generationID: UUID
    let callID: String
    let logicalSessionID: UUID
    let providerBinding: AgentCommandProviderBinding
    let proposalWorkingDirectory: String
    let userSuppliedPath: String
    let displayPath: String
    let targetIdentity: AgentFileMutationTargetIdentity
    let parentCapability: AgentLocalFileMutationTargetCapability
    /// 原始 String 保留供未来 UI 展示；绝不做 trim、newline 或 Unicode 重写。
    let content: String
    /// future C2 将消费的精确 UTF-8 byte snapshot。
    let payloadUTF8: Data
    let payloadIdentity: AgentFileMutationPayloadIdentity
    let createdAt: Date

    /// request 不提供成员逐项注入入口，防止调用方重组 identity/capability binding。
    fileprivate init(
        generationID: UUID,
        callID: String,
        logicalSessionID: UUID,
        providerBinding: AgentCommandProviderBinding,
        proposalWorkingDirectory: String,
        userSuppliedPath: String,
        displayPath: String,
        targetIdentity: AgentFileMutationTargetIdentity,
        parentCapability: AgentLocalFileMutationTargetCapability,
        content: String,
        payloadUTF8: Data,
        payloadIdentity: AgentFileMutationPayloadIdentity,
        createdAt: Date
    ) {
        self.generationID = generationID
        self.callID = callID
        self.logicalSessionID = logicalSessionID
        self.providerBinding = providerBinding
        self.proposalWorkingDirectory = proposalWorkingDirectory
        self.userSuppliedPath = userSuppliedPath
        self.displayPath = displayPath
        self.targetIdentity = targetIdentity
        self.parentCapability = parentCapability
        self.content = content
        self.payloadUTF8 = payloadUTF8
        self.payloadIdentity = payloadIdentity
        self.createdAt = createdAt
    }
}

extension AgentFileMutationRequest: Equatable {
    /// 值相等只比较 immutable proposal binding；capability 的 raw descriptor
    /// 不参与比较，target identity 中的 application token + dev/ino 才是
    /// 该 capability 的安全身份。
    static func == (lhs: AgentFileMutationRequest, rhs: AgentFileMutationRequest) -> Bool {
        lhs.generationID == rhs.generationID
            && lhs.callID == rhs.callID
            && lhs.logicalSessionID == rhs.logicalSessionID
            && lhs.providerBinding == rhs.providerBinding
            && lhs.proposalWorkingDirectory == rhs.proposalWorkingDirectory
            && lhs.userSuppliedPath == rhs.userSuppliedPath
            && lhs.displayPath == rhs.displayPath
            && lhs.targetIdentity == rhs.targetIdentity
            && lhs.content == rhs.content
            && lhs.payloadUTF8 == rhs.payloadUTF8
            && lhs.payloadIdentity == rhs.payloadIdentity
            && lhs.createdAt == rhs.createdAt
    }
}

extension AgentFileMutationRequest: CustomStringConvertible, CustomDebugStringConvertible {
    /// 默认反射会泄漏 content/path；诊断只保留非敏感 identity 与字节计数。
    var description: String {
        "AgentFileMutationRequest(generationID: \(generationID.uuidString), "
            + "callID: \(callID), logicalSessionID: \(logicalSessionID.uuidString), "
            + "payloadBytes: \(payloadIdentity.byteCount), content: <redacted>)"
    }

    var debugDescription: String { description }
}

// MARK: - Proposal factory

/// 唯一 proposal 构造入口：在显式审批前冻结 cwd、path、payload 与 capability。
enum AgentFileMutationRequestFactory: Sendable {
    /// 构造 local create-only proposal；该函数只捕获/read/fstat directory metadata。
    static func make(
        generationID: UUID,
        callID: String,
        logicalSessionID: UUID,
        writeScope: AgentWriteScope,
        userSuppliedPath: String,
        content: String,
        providerBinding: AgentCommandProviderBinding,
        createdAt: Date = Date()
    ) async -> Result<AgentFileMutationRequest, AgentFileMutationError> {
        guard logicalSessionID == writeScope.logicalSessionID else {
            return .failure(.bindingMismatch)
        }
        guard isStructurallyValidPath(userSuppliedPath) else {
            return .failure(.invalidPath)
        }

        let payloadUTF8 = Data(content.utf8)
        guard payloadUTF8.count <= AgentFileMutationLimits.maxPayloadBytes else {
            return .failure(.payloadTooLarge)
        }

        let candidate = userSuppliedPath.hasPrefix("/")
            ? userSuppliedPath
            : writeScope.canonicalRoot + "/" + userSuppliedPath
        guard let split = splitTarget(candidate) else {
            return .failure(.invalidPath)
        }

        // 只 canonicalize parent：final basename 不跟随 symlink，最终存在性
        // 由 fd-relative `fstatat(..., AT_SYMLINK_NOFOLLOW)` 决定。
        guard let canonicalParent = AgentPathResolver.canonicalize(split.parent, kind: .local) else {
            return .failure(.parentUnavailable)
        }
        guard writeScope.contains(canonicalParent) else {
            return .failure(.outsideWriteScope)
        }

        do {
            let capability = try AgentLocalFileMutationTargetCapability(
                opening: split.parent,
                displayPath: canonicalParent,
                targetBasename: split.basename
            )
            if capability.targetExistsAtProposal {
                _ = await capability.invalidate()
                return .failure(.destinationAlreadyExists)
            }

            let displayPath = canonicalParent == "/"
                ? "/" + split.basename
                : canonicalParent + "/" + split.basename
            let payloadIdentity = AgentFileMutationPayloadIdentity(
                byteCount: payloadUTF8.count,
                sha256: Data(SHA256.hash(data: payloadUTF8))
            )
            let targetIdentity = AgentFileMutationTargetIdentity(
                logicalSessionID: logicalSessionID,
                proposalWorkingDirectory: writeScope.canonicalRoot,
                parentCapabilityIdentity: capability.identity,
                basename: split.basename,
                targetToken: UUID()
            )
            return .success(AgentFileMutationRequest(
                generationID: generationID,
                callID: callID,
                logicalSessionID: logicalSessionID,
                providerBinding: providerBinding,
                proposalWorkingDirectory: writeScope.canonicalRoot,
                userSuppliedPath: userSuppliedPath,
                displayPath: displayPath,
                targetIdentity: targetIdentity,
                parentCapability: capability,
                content: content,
                payloadUTF8: payloadUTF8,
                payloadIdentity: payloadIdentity,
                createdAt: createdAt
            ))
        } catch let error as AgentFileMutationError {
            return .failure(error)
        } catch {
            return .failure(.parentUnavailable)
        }
    }

    /// C1 只接受绝对或相对 POSIX path；`~` 不在这条尚未注册的内部 surface。
    /// Provider boundary 与 internal factory 共用的 path 结构校验；不做
    /// canonicalization，也不改写用户输入，避免出现第二套 parser。
    static func isStructurallyValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.utf8.contains(0), !path.hasSuffix("/") else {
            return false
        }
        guard let final = path.split(separator: "/", omittingEmptySubsequences: false).last else {
            return false
        }
        return !final.isEmpty && final != "." && final != ".."
    }

    /// 将绝对 candidate 分解为用于 no-follow parent capture 的 raw parent 与 basename。
    private static func splitTarget(_ absoluteCandidate: String) -> (parent: String, basename: String)? {
        guard absoluteCandidate.hasPrefix("/"),
              let slash = absoluteCandidate.lastIndex(of: "/")
        else {
            return nil
        }
        let basename = String(absoluteCandidate[absoluteCandidate.index(after: slash)...])
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("/") else {
            return nil
        }
        let parent = slash == absoluteCandidate.startIndex
            ? "/"
            : String(absoluteCandidate[..<slash])
        return (parent, basename)
    }
}
