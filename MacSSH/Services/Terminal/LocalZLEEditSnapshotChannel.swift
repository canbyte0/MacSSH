import Darwin
import Foundation

struct ZLEEditSnapshot: Equatable, Sendable {
    let promptGeneration: UInt64
    let sequence: UInt64
    let buffer: String
    let leftBuffer: String
    let rightBuffer: String
    let postDisplay: String
}

enum ZLEEditSnapshotCodec {
    static let maxFieldBytes = 16 * 1024
    static let maxFrameBytes = 4 * maxFieldBytes * 2 + 128

    static func decode(_ frame: Data) -> ZLEEditSnapshot? {
        guard frame.count <= maxFrameBytes,
              let ascii = String(data: frame, encoding: .ascii) else { return nil }
        let parts = ascii.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[0] == "E1",
              let generation = decimal(parts[1]),
              let sequence = decimal(parts[2]),
              let buffer = hex(parts[3]),
              let left = hex(parts[4]),
              let right = hex(parts[5]),
              let post = hex(parts[6]) else { return nil }
        return ZLEEditSnapshot(promptGeneration: generation, sequence: sequence,
                               buffer: buffer, leftBuffer: left, rightBuffer: right,
                               postDisplay: post)
    }

    private static func decimal(_ text: Substring) -> UInt64? {
        guard !text.isEmpty, text.count <= 20, text.first != "0" else { return nil }
        var value: UInt64 = 0
        for byte in text.utf8 {
            guard (48...57).contains(byte) else { return nil }
            let (product, overflow) = value.multipliedReportingOverflow(by: 10)
            let (sum, additionOverflow) = product.addingReportingOverflow(UInt64(byte - 48))
            guard !overflow, !additionOverflow else { return nil }
            value = sum
        }
        return value > 0 ? value : nil
    }

    private static func hex(_ text: Substring) -> String? {
        guard text.utf8.count <= maxFieldBytes * 2,
              text.utf8.count.isMultiple(of: 2) else { return nil }
        let bytes = Array(text.utf8)
        var decoded = [UInt8]()
        decoded.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            decoded.append((high << 4) | low)
        }
        return String(bytes: decoded, encoding: .utf8)
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 65 + 10
        default: return nil
        }
    }
}

/// 损坏或过大帧锁定本会话；不把当前编辑内容写入磁盘或日志。
final class ZLEEditSnapshotTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var latest: ZLEEditSnapshot?
    private var lastGeneration: UInt64 = 0
    private var lastSequence: UInt64 = 0
    private var invalid = false
    private var closed = false
    private var discardingPartialFrame = false
    var onSnapshot: (@Sendable (ZLEEditSnapshot?) -> Void)?

    func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalid, !closed else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0a) {
            let frame = pending[..<newline]
            pending.removeSubrange(...newline)
            if discardingPartialFrame {
                discardingPartialFrame = false
                continue
            }
            guard let snapshot = ZLEEditSnapshotCodec.decode(Data(frame)),
                  snapshot.promptGeneration >= lastGeneration,
                  snapshot.sequence > lastSequence else {
                invalidateLocked()
                return
            }
            lastGeneration = snapshot.promptGeneration
            lastSequence = snapshot.sequence
            latest = snapshot
            onSnapshot?(snapshot)
        }
        if pending.count > ZLEEditSnapshotCodec.maxFrameBytes { invalidateLocked() }
    }

    func snapshot() -> ZLEEditSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return invalid || closed ? nil : latest
    }

    func discard() {
        lock.lock()
        latest = nil
        discardingPartialFrame = !pending.isEmpty
        pending.removeAll()
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        latest = nil
        pending.removeAll()
        lock.unlock()
    }

    private func invalidateLocked() {
        invalid = true
        pending.removeAll()
        latest = nil
        onSnapshot?(nil)
    }
}

final class LocalZLEEditSnapshotChannel: @unchecked Sendable {
    let fifoPath: String
    let tracker = ZLEEditSnapshotTracker()
    private let directoryURL: URL
    private let lifecycleLock = NSLock()
    private var readSource: DispatchSourceRead?

    init?(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
          fileManager: FileManager = .default) {
        directoryURL = temporaryDirectory.appendingPathComponent(
            "MacSSH-zle-edit-\(UUID().uuidString)", isDirectory: true)
        fifoPath = directoryURL.appendingPathComponent("edit.fifo").path
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        guard mkfifo(fifoPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            try? fileManager.removeItem(at: directoryURL)
            return nil
        }
        let descriptor = open(fifoPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? fileManager.removeItem(at: directoryURL)
            return nil
        }
        let snapshotTracker = tracker
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                                   queue: DispatchQueue(label: "com.macssh.zle-edit"))
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    snapshotTracker.ingest(Data(bytes.prefix(count)))
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
