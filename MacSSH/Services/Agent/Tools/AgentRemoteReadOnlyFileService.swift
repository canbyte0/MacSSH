import Foundation

/// Remote 只读文件服务（任务书 §27–§34/§36–§44）。
///
/// 职责只有两个：Remote `list_directory` 与 Remote `read_file`。
///
/// 硬约束：
/// - 所有路径先过 `AgentRemotePathResolver` + `AgentReadScope`（§19/§24），
///   绝不自建第二套路由；
/// - 只调用 façade 的只读原语（§34/§35/§64），绝不触碰任何 mutation
///   SFTP 能力；
/// - 非 MainActor、纯 `Sendable`：远端 I/O 绝不占用主线程（§7）；
/// - 一次读取的累计字节严格有界（§36/§37/§73）：绝不先整文件读入
///   内存再截断；
/// - 只要句柄已打开，任何路径（成功 / binary / 非法 UTF-8 / 取消 /
///   断连 / 权限失败）最终都必须关闭（§39/§75）。
struct AgentRemoteReadOnlyFileService: Sendable {
    /// 目录条目上限（§31）。
    static let maxEntries = 500

    /// 单次 SFTP read 分块大小（§37）。
    static let readChunkBytes = 64 * 1024

    let client: any AgentRemoteReadOnlyFileClient

    init(client: any AgentRemoteReadOnlyFileClient) {
        self.client = client
    }

    // MARK: - list_directory（§28–§33/§44）

    func listDirectory(
        requestedPath: String,
        workingDirectory: AgentWorkingDirectory,
        readScope: AgentReadScope
    ) async -> Result<AgentDirectoryListing, AgentToolError> {
        let canonical: String
        switch await AgentRemotePathResolver.resolve(
            requestedPath: requestedPath,
            workingDirectory: workingDirectory,
            readScope: readScope,
            client: client
        ) {
        case .success(let value):
            canonical = value
        case .failure(let error):
            return .failure(error)
        }

        do {
            try Task.checkCancellation()
            // §44：类型先用 stat 判定——绝不等到 SFTP list 自己失败后
            // 统一退化成 internalFailure。
            let metadata = try await client.stat(canonical)
            guard metadata.isDirectory else {
                return .failure(.notADirectory)
            }

            try Task.checkCancellation()
            let entries = try await client.listDirectory(canonical)
            try Task.checkCancellation()

            var mapped: [AgentDirectoryEntry] = []
            mapped.reserveCapacity(min(entries.count, Self.maxEntries))
            for entry in entries {
                mapped.append(
                    AgentDirectoryEntry(
                        name: entry.name,
                        kind: Self.mapKind(entry.kind),
                        sizeBytes: entry.sizeBytes
                    )
                )
            }

            // §32：固定顺序（directory → symbolicLink → file → other，
            // 同类型内按 UTF-8 字节序），与 locale 无关。
            mapped.sort { lhs, rhs in
                if lhs.kind.sortRank != rhs.kind.sortRank {
                    return lhs.kind.sortRank < rhs.kind.sortRank
                }
                return AgentLocalFileService.lexicographicLess(lhs.name, rhs.name)
            }

            // §33：隐藏文件不默认过滤——scope containment 才是安全边界。
            let total = mapped.count
            let truncated = total > Self.maxEntries
            let bounded = truncated ? Array(mapped.prefix(Self.maxEntries)) : mapped
            return .success(
                AgentDirectoryListing(
                    canonicalPath: canonical,
                    entries: bounded,
                    truncated: truncated,
                    totalEntryCount: total
                )
            )
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as AgentRemoteFileError {
            return .failure(error.toolError)
        } catch {
            return .failure(.internalFailure)
        }
    }

    // MARK: - read_file（§34–§43）

    func readFile(
        requestedPath: String,
        workingDirectory: AgentWorkingDirectory,
        readScope: AgentReadScope
    ) async -> Result<AgentFileContent, AgentToolError> {
        let canonical: String
        switch await AgentRemotePathResolver.resolve(
            requestedPath: requestedPath,
            workingDirectory: workingDirectory,
            readScope: readScope,
            client: client
        ) {
        case .success(let value):
            canonical = value
        case .failure(let error):
            return .failure(error)
        }

        let originalSize: UInt64?
        let handle: AgentRemoteReadHandle
        do {
            try Task.checkCancellation()
            let metadata = try await client.stat(canonical)
            // §43：只有最终 canonical target 是普通文件才允许读取。
            guard metadata.isRegularFile else {
                return .failure(.notAFile)
            }
            originalSize = metadata.sizeBytes

            try Task.checkCancellation()
            handle = try await client.openFileForRead(canonical)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as AgentRemoteFileError {
            return .failure(error.toolError)
        } catch {
            return .failure(.internalFailure)
        }

        // §39/§75：句柄已打开——无论下面走哪条路径都必须关闭。
        let outcome = await readBoundedContent(handle: handle, originalSize: originalSize)
        await client.closeFile(handle)
        return outcome
    }

    // MARK: - 内部

    private func readBoundedContent(
        handle: AgentRemoteReadHandle,
        originalSize: UInt64?
    ) async -> Result<AgentFileContent, AgentToolError> {
        let limit = AgentTextLimits.fileReadMaxBytes
        let wanted = limit + AgentTextLimits.fileUTF8ProbeBytes
        var buffer = Data()
        buffer.reserveCapacity(min(wanted, Self.readChunkBytes * 2))

        do {
            // §37/§50：分块读取 + 每块前后检查取消；累计严格有界。
            while buffer.count < wanted {
                try Task.checkCancellation()
                let remaining = wanted - buffer.count
                let chunk = try await client.readFileChunk(
                    handle,
                    maxBytes: min(Self.readChunkBytes, remaining)
                )
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as AgentRemoteFileError {
            return .failure(error.toolError)
        } catch {
            return .failure(.internalFailure)
        }

        // §42/§74：NUL → binaryUnsupported（绝不 base64 / hex dump）。
        if buffer.contains(0) {
            return .failure(.binaryUnsupported)
        }

        // §40/§41：分块不保证 UTF-8 边界——只校验**累计**后的有界载荷，
        // 并且回退到 ≤ limit 的最大合法 UTF-8 前缀。
        let boundary = AgentUTF8Truncator.utf8PrefixBoundary(in: buffer, byteLimit: limit)
        guard let text = AgentUTF8Truncator.decodeStrictUTF8(buffer.prefix(boundary)) else {
            return .failure(.binaryUnsupported)
        }

        let bytesReturned = AgentUTF8Truncator.byteCount(of: text)
        return .success(
            AgentFileContent(
                text: text,
                truncated: originalSize.map { bytesReturned < $0 } ?? false,
                bytesReturned: bytesReturned,
                originalSize: originalSize
            )
        )
    }

    /// §30：单一 mapper（远端条目类型 → Agent 条目类型）。
    private static func mapKind(
        _ kind: AgentRemoteDirectoryEntryKind
    ) -> AgentDirectoryEntryKind {
        switch kind {
        case .file:
            return .file
        case .directory:
            return .directory
        case .symbolicLink:
            return .symbolicLink
        case .other:
            return .other
        }
    }
}
