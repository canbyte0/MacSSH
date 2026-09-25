import Darwin
import Foundation

enum LocalShellEditState: Equatable, Sendable {
    case unavailable
    case ready
    case executing
    case stale
    case closed
}

/// 只接收 P(预备编辑) / X(开始执行) 两种无 payload 帧。
/// 任意损坏帧都会锁定 unavailable，直到创建新会话，不能被后续 P 恢复。
final class LocalShellStateTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var state: LocalShellEditState = .unavailable
    private var lastSignalTime: TimeInterval?
    private var invalid = false

    func ingest(_ data: Data, now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalid, state != .closed else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0a) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if line.elementsEqual([0x50]) {
                state = .ready
                lastSignalTime = now
            } else if line.elementsEqual([0x58]), state == .ready || state == .executing {
                state = .executing
                lastSignalTime = now
            } else {
                failClosed()
                return
            }
        }
        if pending.count > 32 { failClosed() }
    }

    /// 过期状态不是可信编辑证明。前台输入路径以后必须查询此快照。
    func snapshot(
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = 300
    ) -> LocalShellEditState {
        lock.lock()
        defer { lock.unlock() }
        guard state == .ready, let lastSignalTime else { return state }
        let age = now - lastSignalTime
        return age >= 0 && age <= maxAge ? .ready : .stale
    }

    func close() {
        lock.lock()
        state = .closed
        pending.removeAll()
        lock.unlock()
    }

    private func failClosed() {
        invalid = true
        state = .unavailable
        pending.removeAll()
        lastSignalTime = nil
    }
}

/// 每个 Local zsh 会话独有的 App-owned FIFO。目录 0700、FIFO 0600；
/// shell 打开后删除路径，关闭时清理残留。事件不包含命令或凭据。
final class LocalShellStateChannel: @unchecked Sendable {
    let fifoPath: String
    let tracker = LocalShellStateTracker()

    private let directoryURL: URL
    private let lifecycleLock = NSLock()
    private var readSource: DispatchSourceRead?

    init?(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        directoryURL = temporaryDirectory.appendingPathComponent(
            "MacSSH-shell-state-\(UUID().uuidString)",
            isDirectory: true
        )
        fifoPath = directoryURL.appendingPathComponent("state.fifo").path
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch { return nil }
        guard mkfifo(fifoPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            try? fileManager.removeItem(at: directoryURL)
            return nil
        }
        // 读写打开避免 Shell 尚未连接时 FIFO 的 EOF 自旋；Shell 结束时
        // LocalTerminalService 的 processTerminated/terminate 会明确 close。
        let descriptor = open(fifoPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? fileManager.removeItem(at: directoryURL)
            return nil
        }

        let stateTracker = tracker
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "com.macssh.shell-state")
        )
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 64)
            while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    stateTracker.ingest(Data(bytes.prefix(count)))
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
        }
        let cleanupURL = directoryURL
        source.setCancelHandler {
            Darwin.close(descriptor)
            try? fileManager.removeItem(at: cleanupURL)
        }
        readSource = source
        source.resume()
    }

    deinit { close() }

    func close() {
        lifecycleLock.lock()
        let source = readSource
        readSource = nil
        lifecycleLock.unlock()
        tracker.close()
        source?.cancel()
    }
}
