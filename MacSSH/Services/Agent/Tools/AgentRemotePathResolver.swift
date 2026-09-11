import Foundation

/// Remote 路径解析器（任务书 §18–§26/§68/§69）。
///
/// 与 B1 已验收的本地 `AgentPathResolver` 分离：远端路径的 symlink /
/// 存在性语义只有服务端知道，本地 kernel walker 对远端路径无权威性
/// （§21：绝不使用 `FileManager` / `realpath()` /
/// `resolvingSymlinksInPath()` 解析远端路径）。
///
/// 判定顺序（每步失败立即返回结构化错误，绝不静默 fallback）：
/// 1. 空路径 → `invalidArguments`；
/// 2. `~` / `~/...` → `invalidArguments`（远端没有本地可验证的 HOME，
///    绝不猜测 sessionDefault 作为 home，§14/§18）；
/// 3. 相对路径仅当 cwd `confidence == authoritative` 才拼接（§18）；
///    approximate / unavailable 一律 `cwdUnavailable`——绝不 fallback 到
///    SFTP `.`、远端 HOME 或 sessionDefault；
/// 4. 纯词法规范化（`.` / `..` / 重复 `/`，§22）——只是**预处理**，
///    绝不作为安全判定依据；
/// 5. 服务端 canonicalization（`sftpRealpath` 语义，§23）；
/// 6. containment 只对 **canonical 结果**判定（§19/§24/§26）。
enum AgentRemotePathResolver {
    static func resolve(
        requestedPath: String,
        workingDirectory: AgentWorkingDirectory,
        readScope: AgentReadScope,
        client: any AgentRemoteReadOnlyFileClient
    ) async -> Result<String, AgentToolError> {
        guard !requestedPath.isEmpty else {
            return .failure(.invalidArguments)
        }
        // 远端 HOME 不可验证：tilde 一律拒绝（不 trim：尾随空格可能是
        // 真实远端文件名的一部分）。
        guard !requestedPath.hasPrefix("~") else {
            return .failure(.invalidArguments)
        }

        let candidate: String
        if requestedPath.hasPrefix("/") {
            candidate = requestedPath
        } else {
            guard workingDirectory.confidence == .authoritative,
                  let cwd = workingDirectory.path,
                  !cwd.isEmpty,
                  cwd.hasPrefix("/")
            else {
                return .failure(.cwdUnavailable)
            }
            candidate = cwd + "/" + requestedPath
        }

        guard let lexical = lexicalNormalize(candidate) else {
            return .failure(.internalFailure)
        }

        // §48：执行前已取消 → 立即失败，绝不触碰 SFTP 子系统。
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }

        let canonical: String
        do {
            canonical = try await client.canonicalPath(lexical)
        } catch let error as AgentRemoteFileError {
            return .failure(error.toolError)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.internalFailure)
        }

        // 服务端必须给出规范绝对路径：否则无法做 containment 判定。
        guard canonical.hasPrefix("/") else {
            return .failure(.internalFailure)
        }

        // §24/§26：词法上看在 root 内（`root/link-out/secret.txt`）绝不
        // 等于允许——只有 canonical target 才参与判定。
        guard readScope.contains(canonical) else {
            return .failure(.outsideAllowedReadScope)
        }
        return .success(canonical)
    }

    /// 这只是给服务端 canonicalization 的**预处理**，绝不作为安全边界：
    /// 远端 symlink 只有服务端能解析（§22/§24）。
    static func lexicalNormalize(_ absolutePath: String) -> String? {
        guard absolutePath.hasPrefix("/") else {
            return nil
        }
        var resolved: [String] = []
        for component in absolutePath.split(separator: "/").map(String.init) {
            switch component {
            case "", ".":
                continue
            case "..":
                if !resolved.isEmpty {
                    resolved.removeLast()
                }
            default:
                resolved.append(component)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }
}

extension AgentReadScope {
    /// Remote scope 创建（任务书 §16/§17）：只有 authoritative（OSC 7）
    /// cwd 才成为 allowedRoot，且 root 必须经**服务端** canonicalization
    /// （SFTP realpath 语义）后存储——本地 kernel canonicalization 对远端
    /// 路径无权威性（§21）。
    ///
    /// 与 B1 已冻结的同步 `AgentReadScope.make` 分离：远端 canonicalize
    /// 是异步的，B1 语义（local kernel / remote 词法）绝不被改动。
    ///
    /// - approximate（`sessionDefault`，即便 `realpath(".")` 给出同一
    ///   路径）与 unavailable 一律 `allowedRoots = []`（§17）：session
    ///   default 不是 interactive shell cwd；
    /// - canonicalize 失败（不存在 / 权限 / 断连 / 环）宁可返回空 roots，
    ///   绝不退回词法 root。
    static func makeRemote(
        sessionID: UUID,
        workingDirectory: AgentWorkingDirectory,
        client: any AgentRemoteReadOnlyFileClient
    ) async -> AgentReadScope {
        guard workingDirectory.confidence == .authoritative,
              let path = workingDirectory.path,
              !path.isEmpty,
              path.hasPrefix("/"),
              let lexical = AgentRemotePathResolver.lexicalNormalize(path)
        else {
            return AgentReadScope(sessionID: sessionID, allowedRoots: [])
        }

        do {
            let canonical = try await client.canonicalPath(lexical)
            guard canonical.hasPrefix("/") else {
                return AgentReadScope(sessionID: sessionID, allowedRoots: [])
            }
            return AgentReadScope(sessionID: sessionID, allowedRoots: [canonical])
        } catch {
            return AgentReadScope(sessionID: sessionID, allowedRoots: [])
        }
    }
}
