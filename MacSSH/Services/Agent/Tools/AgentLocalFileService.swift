import Darwin
import Foundation

/// Local-only 只读文件服务（任务书 §20–§29）。
///
/// 硬约束：
/// - 所有路径必须先过 B1 `AgentPathResolver` + `AgentReadScope`（§20/§24），
///   绝不自建第二套路由；
/// - 只使用 metadata / listing / bounded read 类 API，绝不调用任何修改
///   类 `FileManager` API（§50）；
/// - 非 MainActor：大文件读取与目录枚举绝不占用主线程（§7）；
/// - TOCTOU 缓解（§29）：resolve 之后立即 `open`，并且用 `fstat` 在
///   已打开的 fd 上复核最终类型，中间不插入无关 async 工作。
struct AgentLocalFileService: Sendable {
    /// 目录条目上限（§22）。
    static let maxEntries = 500

    // MARK: - list_directory（§20/§21/§22/§23）

    func listDirectory(
        requestedPath: String,
        workingDirectory: AgentWorkingDirectory,
        readScope: AgentReadScope,
        homeDirectory: String? = nil
    ) async -> Result<AgentDirectoryListing, AgentToolError> {
        do {
            try Task.checkCancellation()
            let canonical = try resolve(
                requestedPath,
                workingDirectory: workingDirectory,
                readScope: readScope,
                homeDirectory: homeDirectory
            )
            // 先 open 再 fstat 复核类型（§29 defense-in-depth）：不用
            // O_DIRECTORY，才能区分「路径不存在」与「存在但不是目录」。
            let fileDescriptor = open(canonical, O_RDONLY)
            guard fileDescriptor >= 0 else {
                return .failure(Self.mapOpenErrno(errno))
            }
            defer { close(fileDescriptor) }
            var status = stat()
            guard fstat(fileDescriptor, &status) == 0 else {
                return .failure(.internalFailure)
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                return .failure(.notADirectory)
            }

            let names = (try? FileManager.default.contentsOfDirectory(atPath: canonical)) ?? []
            var entries: [AgentDirectoryEntry] = []
            entries.reserveCapacity(min(names.count, Self.maxEntries))

            for (offset, name) in names.enumerated() {
                // 大目录枚举：每 64 项检查一次取消（§42）。
                if offset % 64 == 0 {
                    try Task.checkCancellation()
                }
                let entryPath = canonical + "/" + name
                var linkStatus = stat()
                // lstat：不跟随链接，保留 symbolicLink 类型信息（§21）。
                guard lstat(entryPath, &linkStatus) == 0 else {
                    // 枚举与 lstat 之间条目消失：跳过而非伪造。
                    continue
                }
                let kind: AgentDirectoryEntryKind
                let size: UInt64?
                switch linkStatus.st_mode & S_IFMT {
                case S_IFDIR:
                    kind = .directory
                    size = nil
                case S_IFREG:
                    kind = .file
                    size = UInt64(linkStatus.st_size)
                case S_IFLNK:
                    kind = .symbolicLink
                    size = nil
                default:
                    kind = .other
                    size = nil
                }
                entries.append(AgentDirectoryEntry(name: name, kind: kind, sizeBytes: size))
            }

            try Task.checkCancellation()
            entries.sort { lhs, rhs in
                if lhs.kind.sortRank != rhs.kind.sortRank {
                    return lhs.kind.sortRank < rhs.kind.sortRank
                }
                // 字节序比较：与 locale 无关（§22）。
                return Self.lexicographicLess(lhs.name, rhs.name)
            }

            let total = entries.count
            let truncated = total > Self.maxEntries
            let bounded = truncated ? Array(entries.prefix(Self.maxEntries)) : entries
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
        } catch let error as AgentToolError {
            return .failure(error)
        } catch {
            return .failure(.internalFailure)
        }
    }

    // MARK: - read_file（§24/§25/§26/§27/§28）

    func readFile(
        requestedPath: String,
        workingDirectory: AgentWorkingDirectory,
        readScope: AgentReadScope,
        homeDirectory: String? = nil
    ) async -> Result<AgentFileContent, AgentToolError> {
        do {
            try Task.checkCancellation()
            let canonical = try resolve(
                requestedPath,
                workingDirectory: workingDirectory,
                readScope: readScope,
                homeDirectory: homeDirectory
            )
            let fileDescriptor = open(canonical, O_RDONLY)
            guard fileDescriptor >= 0 else {
                return .failure(Self.mapOpenErrno(errno))
            }
            defer { close(fileDescriptor) }
            var status = stat()
            guard fstat(fileDescriptor, &status) == 0 else {
                return .failure(.internalFailure)
            }
            let mode = status.st_mode & S_IFMT
            // §28：目录 → notAFile；非普通文件（fifo / socket / dev）同样 notAFile。
            guard mode == S_IFREG else {
                return .failure(.notAFile)
            }

            let limit = AgentTextLimits.fileReadMaxBytes
            let probe = AgentTextLimits.fileUTF8ProbeBytes
            let wanted = limit + probe
            var buffer = Data()
            buffer.reserveCapacity(wanted)
            let chunkSize = 64 * 1024
            var scratch = [UInt8](repeating: 0, count: chunkSize)

            while buffer.count < wanted {
                try Task.checkCancellation()
                let remain = wanted - buffer.count
                let toRead = min(chunkSize, remain)
                let readCount = scratch.withUnsafeMutableBytes { raw in
                    read(fileDescriptor, raw.baseAddress, toRead)
                }
                if readCount < 0 {
                    if errno == EINTR { continue }
                    return .failure(.permissionDenied)
                }
                if readCount == 0 { break }
                buffer.append(scratch, count: readCount)
            }

            try Task.checkCancellation()

            // §27：NUL 字节 → binaryUnsupported（绝不 base64 / hex dump）。
            if buffer.contains(0) {
                return .failure(.binaryUnsupported)
            }

            // §26：先在字节层找 ≤ limit 的最大合法 UTF-8 前缀，再解码。
            let boundary = AgentUTF8Truncator.utf8PrefixBoundary(in: buffer, byteLimit: limit)
            guard let text = AgentUTF8Truncator.decodeStrictUTF8(buffer.prefix(boundary)) else {
                return .failure(.binaryUnsupported)
            }

            let bytesReturned = AgentUTF8Truncator.byteCount(of: text)
            let originalSize = UInt64(status.st_size)
            return .success(
                AgentFileContent(
                    text: text,
                    truncated: bytesReturned < originalSize,
                    bytesReturned: bytesReturned,
                    originalSize: originalSize
                )
            )
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as AgentToolError {
            return .failure(error)
        } catch {
            return .failure(.internalFailure)
        }
    }

    // MARK: - 内部

    private func resolve(
        _ requestedPath: String,
        workingDirectory: AgentWorkingDirectory,
        readScope: AgentReadScope,
        homeDirectory: String?
    ) throws -> String {
        switch AgentPathResolver.resolve(
            requestedPath: requestedPath,
            workingDirectory: workingDirectory,
            readScope: readScope,
            homeDirectory: homeDirectory,
            kind: .local
        ) {
        case .success(let canonical):
            return canonical
        case .failure(let error):
            throw error
        }
    }

    private static func mapOpenErrno(_ code: Int32) -> AgentToolError {
        switch code {
        case ENOENT, ENOTDIR:
            return .pathNotFound
        case EACCES, EPERM:
            return .permissionDenied
        case ELOOP:
            return .internalFailure
        default:
            return .internalFailure
        }
    }

    /// 与 locale 无关的字典序（按 UTF-8 字节比较，§22）。
    static func lexicographicLess(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.utf8.makeIterator()
        var right = rhs.utf8.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil):
                return false
            case (nil, _):
                return true
            case (_, nil):
                return false
            case let (leftByte?, rightByte?):
                if leftByte != rightByte {
                    return leftByte < rightByte
                }
            }
        }
    }
}
