import Darwin
import Foundation
import XCTest
@testable import MacSSH

final class LocalShellStateChannelTests: XCTestCase {
    func testPromptReadyDuplicateAndPreexecTransitions() {
        let tracker = LocalShellStateTracker()
        XCTAssertEqual(tracker.snapshot(now: 100), .unavailable)
        tracker.ingest(Data("P\t1\n".utf8), now: 100)
        XCTAssertEqual(tracker.snapshot(now: 101), .ready(1))
        tracker.ingest(Data("X\t1\n".utf8), now: 104)
        XCTAssertEqual(tracker.snapshot(now: 105), .executing(1))
        tracker.ingest(Data("P\t2\n".utf8), now: 106)
        XCTAssertEqual(tracker.snapshot(now: 107), .ready(2))
    }

    func testMalformedUnexpectedStaleAndCloseFailClosed() {
        let malformed = LocalShellStateTracker()
        malformed.ingest(Data("X\t1\n".utf8), now: 100)
        XCTAssertEqual(malformed.snapshot(now: 100), .unavailable)
        malformed.ingest(Data("P\t1\n".utf8), now: 101)
        XCTAssertEqual(malformed.snapshot(now: 101), .unavailable)

        let stale = LocalShellStateTracker()
        stale.ingest(Data("P\t1\n".utf8), now: 100)
        XCTAssertEqual(stale.snapshot(now: 401), .stale)
        stale.ingest(Data("unexpected\n".utf8), now: 402)
        XCTAssertEqual(stale.snapshot(now: 402), .unavailable)
        stale.close()
        stale.ingest(Data("P\t2\n".utf8), now: 403)
        XCTAssertEqual(stale.snapshot(now: 403), .closed)
    }

    func testUnversionedDuplicateAndWrongGenerationFramesFailClosed() {
        for frame in ["P\n", "P\t0\n", "P\t01\n", "P\t18446744073709551616\n"] {
            let tracker = LocalShellStateTracker()
            tracker.ingest(Data(frame.utf8), now: 100)
            XCTAssertEqual(tracker.snapshot(now: 100), .unavailable, frame)
        }
        let duplicate = LocalShellStateTracker()
        duplicate.ingest(Data("P\t1\nP\t1\n".utf8), now: 100)
        XCTAssertEqual(duplicate.snapshot(now: 100), .unavailable)
        let mismatch = LocalShellStateTracker()
        mismatch.ingest(Data("P\t1\nX\t2\n".utf8), now: 100)
        XCTAssertEqual(mismatch.snapshot(now: 100), .unavailable)
    }

    func testPrivateFIFOReceivesFramesAndCleansOwnDirectory() async throws {
        let channel = try XCTUnwrap(LocalShellStateChannel())
        let path = channel.fifoPath
        var statValue = stat()
        XCTAssertEqual(lstat(path, &statValue), 0)
        XCTAssertEqual(statValue.st_mode & mode_t(0o777), mode_t(0o600))
        XCTAssertEqual(lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &statValue), 0)
        XCTAssertEqual(statValue.st_mode & mode_t(0o777), mode_t(0o700))

        let descriptor = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let bytes = Array("P\t1\nX\t1\n".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }, bytes.count)
        let deadline = Date().addingTimeInterval(2)
        while channel.tracker.snapshot() != .executing(1) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(channel.tracker.snapshot(), .executing(1))
        Darwin.close(descriptor)
        channel.close()
        XCTAssertEqual(channel.tracker.snapshot(), .closed)
        // cancel handler 异步删除目录；只检查本通道的随机路径。
        let cleanupDeadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: path) && Date() < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testControlledZshHooksEmitReadyAndExecutingWithoutUserStartupFiles() async throws {
        let channel = try XCTUnwrap(LocalShellStateChannel())
        let temporaryHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacSSH-shell-state-test-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: false)
        defer {
            channel.close()
            try? FileManager.default.removeItem(at: temporaryHome)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let integration = root.appendingPathComponent("MacSSH/Resources/ShellIntegration")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i"]
        process.environment = [
            "HOME": temporaryHome.path,
            "ZDOTDIR": integration.path,
            "MACSSH_SHELL_STATE_FIFO": channel.fifoPath,
            "TERM": "xterm-256color",
            "PATH": "/usr/bin:/bin",
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
        ]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let deadline = Date().addingTimeInterval(5)
        while channel.tracker.snapshot() != .ready(1) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(channel.tracker.snapshot(), .ready(1))

        try input.fileHandleForWriting.write(contentsOf: Data("sleep 1\n".utf8))
        while channel.tracker.snapshot() != .executing(1) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(channel.tracker.snapshot(), .executing(1))
        while channel.tracker.snapshot() != .ready(2) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(channel.tracker.snapshot(), .ready(2))
        try input.fileHandleForWriting.write(contentsOf: Data("exit\n".utf8))
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(process.isRunning)
    }
}
