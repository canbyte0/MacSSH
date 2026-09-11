import Darwin
import Foundation

/// Agent 本地路径解析器（任务书 10D-B1 §12–§21）。
///
/// 只负责 normalize / canonicalize / containment 判定，绝不读取文件
/// 内容。输入 `requestedPath + workingDirectory + readScope`，输出
/// 允许的 canonical 绝对路径或结构化 `AgentToolError`。
///
/// ## 为什么不用 `NSString.resolvingSymlinksInPath`
///
/// 本机实证（Phase 10D-B1 调研，fixture：`root/link -> outside/`）：
///
/// ```text
/// root/link/secret.txt    → outside/secret.txt   （中间 symlink 解析 ✓）
/// root/link               → outside              （末位 symlink 解析 ✓）
/// root/link/missing.txt   → root/link/missing.txt（尾部不存在时中间
///                                                symlink 完全不解析 ✗）
/// ```
///
/// 最后一条是安全洞：词法 containment 判定「root 内 → 放行」，但随后
/// kernel open 沿 `link` 逃逸到 root 外（任务书 §18：不得因不存在
/// target 绕过 symlink containment）。因此本地路径必须走下面的
/// kernel 语义组件级 walker。
enum AgentPathResolver {
    /// 会话类型：决定 canonicalization 语义。
    enum SessionKind: Sendable, Equatable {
        /// 本地会话：本地文件系统权威，symlink 按 kernel 语义逐组件
        /// 解析（lstat / readlink，绝不读内容）。
        case local
        /// 远程会话：本地文件系统对远端路径无权威性（本机 `/srv` 的
        /// 状态与远端无关），只做词法规范化。远程 symlink 校验属于
        /// 未来 SFTP 层；本阶段远程只表达 policy（任务书 §23）。
        case remote
    }

    /// 解析请求路径为允许的 canonical 绝对路径。
    ///
    /// 判定顺序（每一步失败都立即返回结构化错误，绝不静默 fallback）：
    /// 1. 空路径 → `invalidArguments`（不 trim：尾随空格可能是真实
    ///    文件名的一部分，静默改写语义比拒绝更危险）；
    /// 2. `~` / `~/...` 仅本地会话展开真实 HOME（任务书 §14：展开成功
    ///    不等于允许，仍要过 containment）；`~user/...` 一律拒绝；
    ///    remote 会话没有本地可验证的远端 HOME → 拒绝；
    /// 3. 相对路径仅当 cwd confidence == authoritative 才拼接
    ///    （任务书 §13）；否则 `cwdUnavailable`——绝不 fallback HOME /
    ///    App 进程 cwd / FileManager 默认目录；
    /// 4. canonical 化（local：kernel-like walker；remote：词法）；
    /// 5. containment 对 canonical 结果判定（任务书 §16/§17/§21）。
    static func resolve(
        requestedPath: String,
        workingDirectory: AgentWorkingDirectory,
        readScope: AgentReadScope,
        homeDirectory: String?,
        kind: SessionKind
    ) -> Result<String, AgentToolError> {
        guard !requestedPath.isEmpty else {
            return .failure(.invalidArguments)
        }

        let candidate: String
        if requestedPath.hasPrefix("~") {
            // tilde 只在本地会话且提供 HOME 时可展开；`~user` 形式需要
            // 账户查询，超出本阶段，一律 invalidArguments。
            guard kind == .local,
                  let homeDirectory,
                  !homeDirectory.isEmpty
            else {
                return .failure(.invalidArguments)
            }
            if requestedPath == "~" {
                candidate = homeDirectory
            } else if requestedPath.hasPrefix("~/") {
                candidate = homeDirectory + "/" + requestedPath.dropFirst(2)
            } else {
                return .failure(.invalidArguments)
            }
        } else if requestedPath.hasPrefix("/") {
            candidate = requestedPath
        } else {
            guard workingDirectory.confidence == .authoritative,
                  let cwd = workingDirectory.path,
                  !cwd.isEmpty
            else {
                return .failure(.cwdUnavailable)
            }
            candidate = cwd + "/" + requestedPath
        }

        guard let canonical = canonicalize(candidate, kind: kind) else {
            return .failure(.internalFailure)
        }

        guard readScope.contains(canonical) else {
            return .failure(.outsideAllowedReadScope)
        }
        return .success(canonical)
    }

    // MARK: - Canonicalization

    /// kernel 语义的 canonical 化（§15/§16/§18/§19）。
    ///
    /// 组件级 walker：
    /// - 逐组件 lstat；存在的组件若是 symlink，读取 target 并把
    ///   target 的组件拼接回组件流（绝对 target 重置到根，相对 target
    ///   附加在 link 所在目录——即 kernel 语义），循环解析 symlink 链，
    ///   超过 40 次按 ELOOP 处理返回 nil；
    /// - `.` 丢弃、`..` 弹出已解析栈（kernel 语义：`link/..` 先解
    ///   symlink 再弹——与纯词法结果不同，但因为我们返回 canonical
    ///   路径且下游只打开 canonical 结果，两种语义都安全，这里选择与
    ///   kernel 一致的更保守版本）；
    /// - 首个不存在的组件之后不可能再有任何可解析对象（不存在的东西
    ///   之下没有 symlink），剩余尾部退化为纯词法处理——这保证
    ///   `root/link/missing.txt` 会先解 `link` 再追加不存在的尾部，
    ///   不会落入 Foundation 的不解析洞；
    /// - remote 会话每个组件都走「不存在」分支 = 纯词法规范化。
    ///
    /// 返回 canonical 绝对路径（无 `.`/`..`/重复斜杠/已解析 symlink）；
    /// 输入非绝对路径或 symlink 环时返回 nil（调用方映射为
    /// `internalFailure`）。
    static func canonicalize(_ absolutePath: String, kind: SessionKind) -> String? {
        guard absolutePath.hasPrefix("/") else {
            return nil
        }

        var components = splitComponents(absolutePath)
        var resolved: [String] = []
        var symlinkResolutions = 0
        var index = 0

        while index < components.count {
            let component = components[index]
            switch component {
            case ".":
                index += 1
            case "..":
                if !resolved.isEmpty {
                    resolved.removeLast()
                }
                index += 1
            default:
                if kind == .local, let status = lstatStatus(of: "/" + (resolved + [component]).joined(separator: "/")) {
                    if status.isSymbolicLink {
                        // kernel SYMLOOP_MAX = 40：同一路径的 symlink 链
                        // 超过上限即环，拒绝而非挂死。
                        symlinkResolutions += 1
                        guard symlinkResolutions <= 40,
                              let target = readSymbolicLink(at: "/" + (resolved + [component]).joined(separator: "/"))
                        else {
                            return nil
                        }
                        let rest = Array(components[(index + 1)...])
                        if target.hasPrefix("/") {
                            resolved = []
                        }
                        components = splitComponents(target) + rest
                        index = 0
                    } else {
                        resolved.append(component)
                        index += 1
                    }
                } else {
                    // 组件不存在（或 remote 词法模式）：其后不可能有
                    // symlink，剩余全部词法处理。
                    resolved.append(component)
                    for trailing in components[(index + 1)...] {
                        switch trailing {
                        case ".":
                            continue
                        case "..":
                            if !resolved.isEmpty {
                                resolved.removeLast()
                            }
                        default:
                            resolved.append(trailing)
                        }
                    }
                    return "/" + resolved.joined(separator: "/")
                }
            }
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// 切分路径组件：丢弃空段（`//`、尾部 `/`）与 `.`，保留 `..`
    /// 交给 walker 处理。
    private static func splitComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    // MARK: - 文件系统探针（仅 lstat / readlink，绝不读内容）

    private struct PathStatus {
        let isSymbolicLink: Bool
    }

    /// lstat 语义（不跟随 symlink）。lstat 失败（不存在 / EACCES）
    /// 返回 nil，调用方按「组件不存在」处理：不可搜索目录下无法解析
    /// 也不允许解析，kernel 后续 open 会在同一边界失败，不构成逃逸。
    private static func lstatStatus(of path: String) -> PathStatus? {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            return nil
        }
        return PathStatus(isSymbolicLink: (status.st_mode & S_IFMT) == S_IFLNK)
    }

    /// readlink，缓冲区按需倍增（PATH_MAX 起步，覆盖超长 target）。
    private static func readSymbolicLink(at path: String) -> String? {
        var bufferSize = Int(PATH_MAX)
        for _ in 0..<8 {
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let length = readlink(path, &buffer, bufferSize)
            guard length >= 0 else {
                return nil
            }
            if length < bufferSize {
                return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            bufferSize *= 2
        }
        return nil
    }
}
