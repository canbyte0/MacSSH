import Foundation

/// B2：Local-capable 工具分发基础（任务书 §31–§34/§42/§51）。
///
/// 硬约束：
/// - 未接 UI、未接 Provider（§35/§36）——只有测试与未来 B4 wiring 使用；
/// - 目标会话只由显式 `sessionID` 决定，readScope 由调用方在 generation
///   开始时生成并显式传入（§34：绝不内部重算当前 scope）；
/// - Remote 会话的文件工具走 B3 `AgentRemoteReadOnlyFileService`
///   （origin session 的现有已认证 SSHConnection + 既有 SFTP 子系统），
///   绝不用本地 FileManager 读取 Mac 上同名路径（§32/§52）；
/// - Remote 解析器返回的服务只能按 **origin sessionID** 取得；不可寻址
///   （已关闭 / 断开 / 连接不可用）一律 `.sessionUnavailable`，绝不
///   fallback 其它 session 或本地文件系统，绝不自动重连（§9/§78）；
/// - 取消 → `.cancelled`，绝不转成 `.internalFailure`（§42）。
@MainActor
final class AgentToolRouter {
    private let sessionProvider: any AgentTerminalSessionProviding
    private let fileService: AgentLocalFileService
    private let remoteServiceResolver: (any AgentRemoteReadOnlyServiceResolving)?

    init(
        sessionProvider: any AgentTerminalSessionProviding,
        fileService: AgentLocalFileService = AgentLocalFileService(),
        remoteServiceResolver: (any AgentRemoteReadOnlyServiceResolving)? = nil
    ) {
        self.sessionProvider = sessionProvider
        self.fileService = fileService
        self.remoteServiceResolver = remoteServiceResolver
    }

    func execute(
        call: AgentToolCall,
        sessionID: UUID,
        readScope: AgentReadScope
    ) async -> Result<AgentToolResult, AgentToolError> {
        // 1. 静态注册表（§31）。
        guard let tool = AgentToolRegistry.lookup(call.name) else {
            return .failure(.unknownTool)
        }

        // 2. scope 与 session 绑定（§33/§34 hard gate）。
        guard readScope.sessionID == sessionID else {
            return .failure(.scopeSessionMismatch)
        }

        // 3. session 存在性。
        guard let session = sessionProvider.session(for: sessionID) else {
            return .failure(.sessionUnavailable)
        }

        // 4. Remote 文件工具硬 gate（§32/§52）：未显式声明支持 Remote 的
        //    工具一律拒绝，绝不默认放行。
        if session.sessionKind == .remoteSSH, !tool.supportsRemoteSession {
            return .failure(.unsupportedForSession)
        }

        do {
            try Task.checkCancellation()
        } catch {
            return .failure(.cancelled)
        }

        let result: Result<AgentToolResult, AgentToolError>
        switch tool {
        case .getTerminalContext:
            result = await terminalContext(sessionID: sessionID)
        case .getCurrentDirectory:
            result = currentDirectory(session: session)
        case .listDirectory:
            result = await listDirectory(
                requestedPath: call.path ?? ".",
                session: session,
                readScope: readScope
            )
        case .readFile:
            guard let path = call.path else {
                result = .failure(.invalidArguments)
                break
            }
            result = await readFile(
                requestedPath: path,
                session: session,
                readScope: readScope
            )
        }

        do {
            try Task.checkCancellation()
        } catch {
            return .failure(.cancelled)
        }
        return result
    }

    // MARK: - 内部派发

    /// Local / Remote 分流（§52）：Local 行为与 B2 完全一致。
    private func listDirectory(
        requestedPath: String,
        session: AgentTerminalSessionHandle,
        readScope: AgentReadScope
    ) async -> Result<AgentToolResult, AgentToolError> {
        switch session.sessionKind {
        case .local:
            return await fileService.listDirectory(
                requestedPath: requestedPath,
                workingDirectory: session.workingDirectory,
                readScope: readScope
            ).map { AgentToolResult.directoryListing($0) }
        case .remoteSSH:
            guard let service = remoteServiceResolver?.remoteFileService(for: session.id) else {
                return .failure(.sessionUnavailable)
            }
            return await service.listDirectory(
                requestedPath: requestedPath,
                workingDirectory: session.workingDirectory,
                readScope: readScope
            ).map { AgentToolResult.directoryListing($0) }
        }
    }

    /// Local / Remote 分流（§52）：Local 行为与 B2 完全一致。
    private func readFile(
        requestedPath: String,
        session: AgentTerminalSessionHandle,
        readScope: AgentReadScope
    ) async -> Result<AgentToolResult, AgentToolError> {
        switch session.sessionKind {
        case .local:
            return await fileService.readFile(
                requestedPath: requestedPath,
                workingDirectory: session.workingDirectory,
                readScope: readScope
            ).map { AgentToolResult.fileContent($0) }
        case .remoteSSH:
            guard let service = remoteServiceResolver?.remoteFileService(for: session.id) else {
                return .failure(.sessionUnavailable)
            }
            return await service.readFile(
                requestedPath: requestedPath,
                workingDirectory: session.workingDirectory,
                readScope: readScope
            ).map { AgentToolResult.fileContent($0) }
        }
    }

    private func terminalContext(sessionID: UUID) async -> Result<AgentToolResult, AgentToolError> {
        guard let context = sessionProvider.snapshot(for: sessionID) else {
            return .failure(.sessionUnavailable)
        }
        return .success(.terminalContext(context))
    }

    private func currentDirectory(
        session: AgentTerminalSessionHandle
    ) -> Result<AgentToolResult, AgentToolError> {
        // §19：path 不存在 → success + unavailable 三元组（模型可区分
        // 「未知」与「工具故障」）；只有 session 不存在才 sessionUnavailable。
        .success(
            .currentDirectory(
                AgentCurrentDirectoryResult(
                    sessionID: session.id,
                    workingDirectory: session.workingDirectory
                )
            )
        )
    }
}
