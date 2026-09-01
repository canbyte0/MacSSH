import Foundation
import SwiftData
import XCTest

@testable import MacSSH

/// Phase 11 Transfer Queue 纯模型测试（无网络）：
/// - 入队拒绝与冲突预检（同远端目标上传 / 同本地目标下载）；
/// - 调度器防御路径（会话关闭安全失败，绝不 fatalError）；
/// - 断开会话的任务保持等待连接（绝不启动、绝不失败）；
/// - Cancel Pending（直接终态，绝不触碰连接 / 文件）；
/// - Remove / clearFinished 的终态守卫；
/// - queueSummary / transferCount 会话隔离统计。
///
/// 直连场景不装配 SessionManager：任务经入队弱引用解析会话；
/// 会话持有未连接的真实 SSHConnection 实例（仅供 SFTPService 装配，
/// 全程不发起连接）。
@MainActor
final class TransferQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var knownHostService: KnownHostService!

    override func setUp() async throws {
        continueAfterFailure = false
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        knownHostService = KnownHostService(modelContainer: container)
    }

    override func tearDown() async throws {
        knownHostService.removeAll()
        knownHostService = nil
        container = nil
    }

    private func makeSession() -> ManagedTerminalSession {
        ManagedTerminalSession(
            remoteHostID: UUID(),
            hostDisplayName: "QueueHost",
            hostname: "127.0.0.1",
            port: 22,
            baseTitle: "QueueHost",
            titleCounter: 1
        )
    }

    private func makeLocalFile(name: String = "q.bin", content: Data = Data("x".utf8)) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p11-queue-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? content.write(to: url)
        return url
    }

    /// 未连接的真实 SSHConnection（仅供装配，全程不发起连接）。
    private func makeUnconnectedConnection() -> SSHConnection {
        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: "127.0.0.1",
            port: 22,
            username: NSUserName()
        )
        let configuration = SSHConnection.Configuration(
            hostID: info.hostID,
            hostname: info.hostname,
            port: info.port,
            username: info.username,
            authenticationType: .privateKey,
            credentialID: nil,
            privateKeyPath: "/tmp/macssh-p11-never-read",
            privateKeyID: nil
        )
        return SSHConnection(
            configuration: configuration,
            info: info,
            knownHostService: knownHostService,
            sessionTeardownOperations: .live
        )
    }

    /// 装配一个带未连接连接与 SFTPService 的会话（纯模型：全程不发起连接，
    /// 调度器判定断连 → 任务保持等待，正是要验证的队列行为）。
    private func makeDisconnectedSession() -> ManagedTerminalSession {
        let session = makeSession()
        let connection = makeUnconnectedConnection()
        let info = SSHConnectionInfo(
            hostID: UUID(),
            hostname: "127.0.0.1",
            port: 22,
            username: NSUserName()
        )
        session.attach(connection: connection, info: info)
        session.attachSFTPService(SFTPService(connection: connection))
        return session
    }

    // MARK: - 入口拒绝与冲突预检

    /// 上传冲突：同会话已有未终态上传指向同一远端目标 → 拒绝入队。
    func testUploadConflictOnSameRemoteTarget() async {
        let manager = TransferManager()
        let session = makeDisconnectedSession()

        // 会话未连接：任务保持 pending（等待连接），正是冲突预检要覆盖的状态。
        let url1 = makeLocalFile(name: "dup.bin")
        let first = manager.requestUpload(session: session, localURL: url1)
        XCTAssertNil(first.rejection)
        XCTAssertNotNil(first.task)
        XCTAssertEqual(first.task?.state, .pending)

        // 同名本地文件（同远端目标）再次上传：绝不双发到同一目标。
        let url2 = makeLocalFile(name: "dup.bin", content: Data("other".utf8))
        let second = manager.requestUpload(session: session, localURL: url2)
        XCTAssertNil(second.task)
        XCTAssertEqual(second.rejection, "队列中已有相同远端目标的上传任务。")
        XCTAssertEqual(manager.tasks.count, 1)

        // 取消首任务后冲突解除。
        manager.cancel(first.task!.id)
        let third = manager.requestUpload(session: session, localURL: url2)
        XCTAssertNil(third.rejection, "终态任务绝不构成冲突")
        XCTAssertNotNil(third.task)
    }

    /// 下载冲突：任意会话已有未终态下载指向同一本地目标 → 拒绝入队。
    func testDownloadConflictOnSameLocalDestination() async {
        let manager = TransferManager()
        let session = makeSession()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p11-queue-tests/conflict-target.bin")

        let entry = SFTPFileEntry(
            name: "remote.bin", kind: .regularFile, sizeBytes: 10,
            modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
        )
        let first = manager.requestDownload(session: session, entry: entry, destinationURL: destination)
        XCTAssertNil(first.rejection)
        XCTAssertNotNil(first.task)

        let second = manager.requestDownload(session: session, entry: entry, destinationURL: destination)
        XCTAssertNil(second.task)
        XCTAssertEqual(second.rejection, "队列中已有相同本地目标文件的传输任务。")

        // 终态后冲突解除：取消首任务再入队必须成功。
        manager.cancel(first.task!.id)
        XCTAssertEqual(first.task?.state, .cancelled)
        let third = manager.requestDownload(session: session, entry: entry, destinationURL: destination)
        XCTAssertNil(third.rejection, "终态任务绝不构成冲突")
        XCTAssertNotNil(third.task)
    }

    /// 本地目录上传拒绝（请求层防御）。
    func testUploadDirectoryRejected() async {
        let manager = TransferManager()
        let session = makeDisconnectedSession()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p11-queue-tests/dir", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = manager.requestUpload(session: session, localURL: directory)
        XCTAssertNil(result.task)
        XCTAssertEqual(result.rejection, "只能上传普通文件。")
    }

    // MARK: - 调度器防御路径

    /// 会话已关闭（调度器判定缺失）：安全失败，绝不崩溃。
    func testSchedulerFailsOrphanTaskSafely() async {
        let manager = TransferManager()
        let session = makeDisconnectedSession()
        let result = manager.requestUpload(session: session, localURL: makeLocalFile(name: "ghost.bin"))
        guard let task = result.task else {
            XCTFail("入队必须成功")
            return
        }
        XCTAssertEqual(task.state, .pending)

        // 关闭会话后再调度：防御路径安全到失败终态，绝不 fatalError。
        session.markClosed()
        manager.scheduleNext()
        XCTAssertEqual(task.state, .failed, "孤儿任务必须安全到达失败终态")
        // 失败原因以语言无关枚举缓存（任务书七十三），文案按 Locale 即时解析。
        XCTAssertEqual(task.failureError, .sessionMissing)
        XCTAssertEqual(task.failureMessage(locale: AppLanguage.defaultLanguage.locale), "会话不存在。")
    }

    /// 任务书七十三（P1 回归）：调度器写入的失败同样是语言无关枚举。
    ///
    /// 任务到达 failed 终态**之后**再切换语言（zh→en→zh），失败文案必须跟着
    /// 变——若仍相等，说明任务里缓存的是失败瞬间的 String，该状态不可恢复。
    func testSchedulerFailureMessageSwitchesWithLocaleAfterFailure() async {
        let manager = TransferManager()
        let session = makeDisconnectedSession()
        let result = manager.requestUpload(
            session: session,
            localURL: makeLocalFile(name: "ghost-l10n.bin")
        )
        guard let task = result.task else {
            XCTFail("入队必须成功")
            return
        }

        session.markClosed()
        manager.scheduleNext()
        XCTAssertEqual(task.state, .failed, "孤儿任务必须安全到达失败终态")
        XCTAssertEqual(task.failureError, .sessionMissing)

        // 失败后切换语言：文案必须跟随当前 Locale。
        let zh = task.failureMessage(locale: AppLanguage.simplifiedChinese.locale)
        let en = task.failureMessage(locale: AppLanguage.english.locale)
        XCTAssertNotNil(zh)
        XCTAssertNotNil(en)
        XCTAssertNotEqual(zh, en, "失败后切换语言文案必须跟随——仍相等说明在缓存 String")
        XCTAssertTrue(zh?.contains("会话") == true, "zh-Hans 必须为中文: \(zh ?? "")")
        XCTAssertTrue(en?.lowercased().contains("session") == true, "en 必须含 'session': \(en ?? "")")

        // 切回 zh-Hans 必须回到同一文案，且任务状态 / 原因绝不因语言切换改变。
        XCTAssertEqual(task.failureMessage(locale: AppLanguage.simplifiedChinese.locale), zh)
        XCTAssertEqual(task.state, .failed)
        XCTAssertEqual(task.failureError, .sessionMissing)
    }

    /// 会话未连接：任务保持 pending + 等待连接，绝不启动、绝不失败。
    func testSchedulerKeepsTaskPendingWhenDisconnected() async {
        let manager = TransferManager()
        let session = makeDisconnectedSession()
        let result = manager.requestUpload(session: session, localURL: makeLocalFile(name: "wait.bin"))
        guard let task = result.task else {
            XCTFail("入队必须成功")
            return
        }
        XCTAssertEqual(task.state, .pending, "断开会话的任务必须保持等待")
        XCTAssertTrue(task.awaitingConnection, "必须标记等待连接")
        XCTAssertNil(task.executionTask, "等待中的任务绝不启动")
        XCTAssertEqual(task.stateDisplay(locale: AppLanguage.defaultLanguage.locale), "等待连接")
    }

    // MARK: - Cancel Pending

    /// 取消 pending：直接终态，无执行任务、无中间态。
    func testCancelPendingIsImmediateTerminal() async {
        let manager = TransferManager()
        let session = makeSession()
        let entry = SFTPFileEntry(
            name: "p.bin", kind: .regularFile, sizeBytes: 1,
            modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p11-queue-tests/pending-cancel.bin")
        let (task, _) = manager.requestDownload(session: session, entry: entry, destinationURL: destination)
        guard let pending = task else {
            XCTFail("入队必须成功")
            return
        }
        XCTAssertEqual(pending.state, .pending)

        manager.cancel(pending.id)
        XCTAssertEqual(pending.state, .cancelled, "pending 取消必须立即终态")
        XCTAssertNil(pending.executionTask, "pending 取消绝不创建执行任务")
    }

    // MARK: - Remove / clearFinished 终态守卫

    /// Remove 只移除终态任务；活跃 / 排队任务绝不移除。
    func testRemoveOnlyTerminalTasks() async {
        let manager = TransferManager()
        let session = makeSession()
        let entry = SFTPFileEntry(
            name: "rm.bin", kind: .regularFile, sizeBytes: 1,
            modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("macssh-p11-queue-tests/remove.bin")
        let (task, _) = manager.requestDownload(session: session, entry: entry, destinationURL: destination)
        guard let pending = task else {
            XCTFail("入队必须成功")
            return
        }
        XCTAssertEqual(pending.state, .pending)

        manager.remove(pending.id)
        XCTAssertTrue(manager.tasks.contains { $0.id == pending.id }, "pending 任务绝不可移除")

        manager.cancel(pending.id)
        manager.remove(pending.id)
        XCTAssertFalse(manager.tasks.contains { $0.id == pending.id }, "终态任务可移除")
    }

    /// clearFinished 只清终态；排队任务保持。
    func testClearFinishedKeepsPending() async {
        let manager = TransferManager()
        let session = makeSession()
        let entry = SFTPFileEntry(
            name: "c.bin", kind: .regularFile, sizeBytes: 1,
            modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
        )
        let d1 = FileManager.default.temporaryDirectory.appendingPathComponent("macssh-p11-clear-1.bin")
        let d2 = FileManager.default.temporaryDirectory.appendingPathComponent("macssh-p11-clear-2.bin")
        let (t1, _) = manager.requestDownload(session: session, entry: entry, destinationURL: d1)
        let (t2, _) = manager.requestDownload(
            session: session,
            entry: SFTPFileEntry(
                name: "c2.bin", kind: .regularFile, sizeBytes: 1,
                modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
            ),
            destinationURL: d2
        )
        guard let a = t1, let b = t2 else {
            XCTFail("入队必须成功")
            return
        }
        manager.cancel(a.id)
        manager.clearFinished()
        XCTAssertFalse(manager.tasks.contains { $0.id == a.id })
        XCTAssertTrue(manager.tasks.contains { $0.id == b.id }, "排队任务绝不被清掉")
        XCTAssertEqual(b.state, .pending)
    }

    // MARK: - 统计与隔离

    /// transferCount / hasActiveTransfer 按会话隔离；queueSummary 汇总。
    func testSessionScopedCountersAndSummary() async {
        let manager = TransferManager()
        let sessionA = makeSession()
        let sessionB = makeSession()
        let entry = SFTPFileEntry(
            name: "s.bin", kind: .regularFile, sizeBytes: 1,
            modifiedAt: nil, permissions: 0o600, ownerUID: nil, ownerGID: nil
        )
        _ = manager.requestDownload(
            session: sessionA,
            entry: entry,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("macssh-p11-s-a.bin")
        )
        _ = manager.requestDownload(
            session: sessionB,
            entry: entry,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("macssh-p11-s-b.bin")
        )

        XCTAssertEqual(manager.transferCount(forSession: sessionA.id), 1)
        XCTAssertEqual(manager.transferCount(forSession: sessionB.id), 1)
        XCTAssertEqual(manager.transferCount(forSession: UUID()), 0)
        XCTAssertFalse(manager.hasActiveTransfer, "pending 绝不占用活跃槽位")
        XCTAssertFalse(manager.hasActiveTransfer(forSession: sessionA.id))
        XCTAssertEqual(manager.queueSummary(locale: AppLanguage.defaultLanguage.locale), "2 个等待中")
    }
}
