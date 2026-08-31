import Foundation
import Observation

/// Phase 9 SFTP 浏览业务层：SFTPBrowserView ← **SFTPService** ← SSHConnection。
///
/// 职责（任务书）：
/// - 持有当前路径、条目列表、加载 / 错误状态；UI 只观察本对象，
///   绝不触碰 libssh2；
/// - 导航原子性：`currentPath` 与 `entries` 只在列举成功后一起提交，
///   失败保持原状态 + 业务错误；
/// - 竞态防护：每个请求递增 `generation` 并取消上一个在途请求，
///   新请求先等旧任务完全退出（含收尾 closedir）才开始 SFTP 操作，
///   快速导航 / 连续刷新绝不产生过期结果覆盖新结果，
///   也绝不产生两个任务同时进入同一 `LIBSSH2_SFTP` 状态机；
/// - 生命周期：`stopBarrier()` 供关闭 / Reconnect 拆除；
///   `reattach(connection:)` 在 Reconnect 后绑定全新连接
///   （SFTP 子系统随旧连接释放，绝不复用；可选恢复原路径）。
///
/// 排序一次完成（目录优先、本地化自然序），UI 不再重排；
/// 隐藏文件默认展示，`.` / `..` 由底层过滤。
@MainActor
@Observable
final class SFTPService {
    /// 浏览状态。
    enum Phase: Equatable {
        /// 尚未启动（等待用户打开 Files 面板，或 Reconnect 后待重新启动）。
        case idle
        /// 正在初始化子系统 / 解析路径 / 列举目录。
        case loading
        /// 列表就绪。
        case loaded
        /// 最近一次操作失败；保留原路径与（如有）原列表。
        case failed(SFTPError)
    }

    private(set) var phase: Phase = .idle

    /// 当前目录绝对路径（只在列举成功后更新）。
    private(set) var currentPath = RemotePath.root

    /// 当前目录条目（已排序一次）。
    private(set) var entries: [SFTPFileEntry] = []

    /// 已认证连接（actor 引用）；全部 SFTP 调用经它串行执行。
    /// Reconnect 时通过 `reattach(connection:)` 替换；调用前旧连接
    /// 必须已完成拆除（SessionManager 保证顺序）。
    private var connection: SSHConnection

    /// 请求代次：每个导航 / 刷新递增；在途任务提交状态前必须匹配，
    /// 过期结果直接丢弃（快速导航 / 刷新竞态防护）。
    private var generation: UInt64 = 0

    /// stop() 已请求：所有延迟恢复的任务不再写入状态。
    private var hasStopped = false

    /// 在途加载任务（同一时刻最多一个；新请求取消并替换）。
    private var operationTask: Task<Void, Never>?

    /// 在途文件操作任务（同一时刻最多一个；原子服务器操作不可取消，
    /// 拆除屏障 await 其终值后才继续）。
    private var fileOperationTask: Task<Void, Never>?

    /// 文件操作进行中（UI 据此禁用入口，防重叠提交）。
    private(set) var isFileOperationRunning = false

    /// 最近一次文件操作的错误提示（UI 弹窗观察；置空即收起）。
    var fileOperationNotice: String?

    /// Reconnect 路径恢复：最近成功提交的路径（可选恢复，
    /// 不存在时自动回落 `realpath(".")`）。
    private var lastKnownPath: String?

    init(connection: SSHConnection) {
        self.connection = connection
    }

    /// 是否位于根目录（Parent 按钮禁用）。
    var isAtRoot: Bool {
        RemotePath.isRoot(currentPath)
    }

    // MARK: - 启动与导航

    /// 首次进入 Files 面板 / Reconnect 后重新启动（幂等）：
    /// 初始化子系统（如未初始化）→ 恢复路径或 `realpath(".")` → 列举。
    /// 已启动 / 进行中时直接返回——Terminal ↔ Files 切换不重建、不重复初始化。
    func startIfNeeded() {
        guard phase == .idle, !hasStopped else {
            return
        }
        if let restored = lastKnownPath {
            scheduleLoad(target: restored, fallbackToInitialDirectory: true)
        } else {
            scheduleLoad(target: nil, fallbackToInitialDirectory: false)
        }
    }

    /// 进入子目录（仅目录条目；单击选择、双击进入由 UI 决定）。
    func navigate(into entry: SFTPFileEntry) {
        guard phase == .loaded, entry.isDirectory else {
            return
        }
        scheduleLoad(
            target: RemotePath.join(currentPath, child: entry.name),
            fallbackToInitialDirectory: false
        )
    }

    /// 上级目录；根目录时由 UI 禁用，此处双重防御。
    func goParent() {
        guard phase == .loaded, !RemotePath.isRoot(currentPath) else {
            return
        }
        scheduleLoad(
            target: RemotePath.parent(of: currentPath),
            fallbackToInitialDirectory: false
        )
    }

    /// 刷新当前目录（⌘R / 刷新按钮 / 失败后 Retry 均走这里）。
    /// 失败态重试会重新确保子系统初始化（覆盖初始化失败场景）。
    func refresh() {
        guard !hasStopped else {
            return
        }
        switch phase {
        case .loaded, .failed:
            scheduleLoad(target: currentPath, fallbackToInitialDirectory: false)
        case .idle:
            startIfNeeded()
        case .loading:
            return
        }
    }

    /// 测试支持（internal，UI 不使用）：直接加载指定绝对路径。
    ///
    /// 生产导航只经条目双击 / Parent / Refresh；本钩子让真实测试
    /// 无需逐级双击即可把浏览器定位到夹具目录（与 Reconnect 路径
    /// 恢复共用同一 `scheduleLoad` 通道，竞态防护完全一致）。
    func loadAbsolute(path: String) {
        guard !hasStopped else {
            return
        }
        scheduleLoad(target: path, fallbackToInitialDirectory: false)
    }

    // MARK: - 文件操作（计划书 Phase 10：rename / delete / mkdir）

    /// 重命名当前目录内的条目：目标路径 = 当前目录 + 新名（同级重命名）；
    /// `flags = 0` 的 posix-rename 语义保证目标名已存在时失败，绝不覆盖。
    func renameEntry(_ entry: SFTPFileEntry, to newName: String) {
        guard let name = sanitizedEntryName(newName) else {
            fileOperationNotice = "名称无效：不能为空、包含 / 或为 . / ..。"
            return
        }
        guard entries.contains(where: { $0.id == entry.id }) else {
            fileOperationNotice = "目标已不在当前目录，请刷新后重试。"
            return
        }
        let source = RemotePath.join(currentPath, child: entry.name)
        let destination = RemotePath.join(currentPath, child: name)
        runFileOperation { [connection] in
            try await connection.sftpRenameFile(from: source, to: destination)
        }
    }

    /// 删除当前目录内的普通文件（协议层 `unlink`；目录删除不在
    /// Phase 10 范围——避免递归风险，业务层拦截）。
    func deleteEntry(_ entry: SFTPFileEntry) {
        guard entry.kind == .regularFile else {
            fileOperationNotice = "仅支持删除普通文件。"
            return
        }
        guard entries.contains(where: { $0.id == entry.id }) else {
            fileOperationNotice = "目标已不在当前目录，请刷新后重试。"
            return
        }
        let path = RemotePath.join(currentPath, child: entry.name)
        runFileOperation { [connection] in
            try await connection.sftpUnlinkFile(path)
        }
    }

    /// 在当前目录新建子目录（权限 0755；同名已存在由服务器拒绝）。
    func createDirectory(named rawName: String) {
        guard let name = sanitizedEntryName(rawName) else {
            fileOperationNotice = "名称无效：不能为空、包含 / 或为 . / ..。"
            return
        }
        let path = RemotePath.join(currentPath, child: name)
        runFileOperation { [connection] in
            try await connection.sftpCreateDirectory(at: path)
        }
    }

    // MARK: - 生命周期（关闭 / Reconnect）

    /// 可等待的拆除屏障：取消在途请求并等待其完全退出后才返回。
    /// 关闭与 Reconnect 必须经过本屏障——旧任务尘埃落定前，
    /// 绝不替换连接或释放旧连接（与 RemoteTerminalService 同模式）。
    func stopBarrier() async {
        guard !hasStopped else {
            await operationTask?.value
            await fileOperationTask?.value
            return
        }
        hasStopped = true
        generation &+= 1
        operationTask?.cancel()
        await operationTask?.value
        // 文件操作是原子服务器操作（不可取消）：等其终值后才继续，
        // 保证拆除不与在途 rename / unlink / mkdir 交错。
        await fileOperationTask?.value
    }

    /// Reconnect：绑定全新已认证连接并复位运行时。
    ///
    /// 旧连接上的 `LIBSSH2_SFTP *` 已随 disconnect 释放——绝不复用；
    /// 记录最近路径供可选恢复，状态回到 `.idle`，由 Files 面板重新触发启动。
    func reattach(connection newConnection: SSHConnection) async {
        await stopBarrier()
        generation &+= 1
        hasStopped = false
        connection = newConnection
        entries = []
        phase = .idle
    }

    // MARK: - 私有

    /// 名称校验（业务层防线；服务器另有自己的路径规则）：
    /// 去首尾空白后非空、不含 `/` 与 NUL、不是 `.` / `..`。
    private func sanitizedEntryName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0")
        else {
            return nil
        }
        return name
    }

    /// 登记一次文件操作：防重叠（进行中拒绝）；成功后刷新当前目录，
    /// 失败写用户可见提示（连接 / 业务错误不断开、不崩溃）。
    /// 拆除期间的操作结果一律丢弃（`hasStopped` 校验）。
    private func runFileOperation(_ operation: @escaping @Sendable () async throws -> Void) {
        guard phase == .loaded, !isFileOperationRunning, !hasStopped else {
            return
        }
        isFileOperationRunning = true
        fileOperationTask = Task { @MainActor [weak self] in
            do {
                try await operation()
                if let self, !self.hasStopped {
                    self.refresh()
                }
            } catch {
                if let self, !self.hasStopped,
                   !(error is CancellationError),
                   (error as? SFTPError) != .operationCancelled
                {
                    self.fileOperationNotice = Self.fileOperationMessage(for: error)
                }
            }
            // 无论成败 / 是否已拆除，忙碌标志都在任务末尾复位——
            // 复位本身属于任务终值，被拆除屏障完整等待。
            self?.isFileOperationRunning = false
        }
    }

    /// 文件操作错误的用户可见中文文案（不回显原始协议码）。
    private static func fileOperationMessage(for error: Error) -> String {
        let sftp = (error as? SFTPError) ?? .connectionLost
        switch sftp {
        case .permissionDenied:
            return "权限不足，无法完成操作。"
        case .noSuchPath:
            return "目标不存在，请刷新后重试。"
        case .connectionLost:
            return "SSH 连接已断开。"
        case .operationCancelled:
            return "操作已取消。"
        case .protocolFailure:
            return "操作失败：目标名称可能已存在，或服务器拒绝。"
        case .subsystemInitFailed:
            return "SFTP 会话不可用。"
        }
    }

    /// 登记一次新的加载请求：递增代次、取消并替换上一个在途任务。
    ///
    /// 新任务先**等待旧任务完全退出**（含其收尾 closedir）才开始自己的
    /// SFTP 操作（第二轮整改）：取消只是置标志，旧任务可能仍因 EAGAIN
    /// 挂在 `SSHConnection` 内——只有 await 其终值才能保证同一时刻没有
    /// 两个任务进入同一个 `LIBSSH2_SFTP` 状态机。连接层另有串行门兜底。
    ///
    /// - Parameter target: 目标路径；nil 表示初始目录（`realpath(".")`）。
    /// - Parameter fallbackToInitialDirectory: 目标不存在时回落初始目录
    ///   （仅 Reconnect 路径恢复使用）。
    private func scheduleLoad(target: String?, fallbackToInitialDirectory: Bool) {
        generation &+= 1
        let superseded = operationTask
        superseded?.cancel()

        let generation = self.generation
        let connection = self.connection
        phase = .loading

        operationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await superseded?.value
            guard self.generation == generation, !self.hasStopped else {
                return
            }
            await self.performLoad(
                target: target,
                fallbackToInitialDirectory: fallbackToInitialDirectory,
                generation: generation,
                connection: connection
            )
        }
    }

    /// 加载主体：确保子系统 → 解析路径 → 列举 → 原子提交。
    ///
    /// 每个 await 恢复后都重新校验代次与停止标志：过期请求
    /// 绝不写入状态（导航原子性与竞态防护的核心）。
    private func performLoad(
        target: String?,
        fallbackToInitialDirectory: Bool,
        generation: UInt64,
        connection: SSHConnection
    ) async {
        do {
            // 幂等：已初始化时只是标志检查，不重复握手。
            try await connection.openSFTPSubsystemIfNeeded()
            guard self.generation == generation, !self.hasStopped else {
                return
            }

            let path: String
            if let target {
                path = target
            } else {
                path = try await connection.sftpRealpath(".")
                guard self.generation == generation, !self.hasStopped else {
                    return
                }
            }

            let listed = try await connection.sftpListDirectory(path)
            guard self.generation == generation, !self.hasStopped else {
                return
            }

            // 原子提交：路径与列表一起更新。
            entries = Self.sortedEntries(listed)
            currentPath = path
            lastKnownPath = path
            phase = .loaded
        } catch let error as SFTPError where error == .noSuchPath
            && fallbackToInitialDirectory && target != nil
        {
            // 恢复路径已不存在：清除记忆，回落初始目录。
            guard self.generation == generation, !self.hasStopped else {
                return
            }
            lastKnownPath = nil
            await performLoad(
                target: nil,
                fallbackToInitialDirectory: false,
                generation: generation,
                connection: connection
            )
        } catch {
            guard self.generation == generation, !self.hasStopped else {
                return
            }
            // 被新请求取代 / 被停止：不展示错误。
            if error is CancellationError || (error as? SFTPError) == .operationCancelled {
                return
            }
            phase = .failed((error as? SFTPError) ?? .connectionLost)
        }
    }

    /// 目录优先、本地化自然序；排序只在这里发生一次。
    private static func sortedEntries(_ entries: [SFTPFileEntry]) -> [SFTPFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
