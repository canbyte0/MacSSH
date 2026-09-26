import Darwin
import Foundation
import XCTest
import SwiftTerm
@testable import MacSSH

final class LocalZLEEditSnapshotChannelTests: XCTestCase {
    private func frame(_ buffer: String = "git", generation: UInt64 = 1,
                       sequence: UInt64 = 1, left: String? = nil,
                       right: String = "", post: String = "") -> Data {
        func hex(_ string: String) -> String {
            string.utf8.map { String(format: "%02X", $0) }.joined()
        }
        return Data("E1\t\(generation)\t\(sequence)\t\(hex(buffer))\t\(hex(left ?? buffer))\t\(hex(right))\t\(hex(post))".utf8)
    }

    func testCodecPreservesExactUTF8AndRejectsMalformedFields() {
        for value in ["git", "中文", "😀", "e\u{301}", "⚠️", "a b\t;c"] {
            XCTAssertEqual(ZLEEditSnapshotCodec.decode(frame(value))?.buffer, value)
        }
        XCTAssertNil(ZLEEditSnapshotCodec.decode(Data("E1\t1\t1\tC3\t\t\t".utf8)))
        XCTAssertNil(ZLEEditSnapshotCodec.decode(Data("E1\t1\t1\tGG\t\t\t".utf8)))
        XCTAssertNil(ZLEEditSnapshotCodec.decode(Data("E1\t1\t1\t41\t41\t\t\textra".utf8)))
        XCTAssertNil(ZLEEditSnapshotCodec.decode(Data("E1\t0\t1\t41\t41\t\t".utf8)))
        XCTAssertNil(ZLEEditSnapshotCodec.decode(Data("E1\t1\t0\t41\t41\t\t".utf8)))
        XCTAssertNil(ZLEEditSnapshotCodec.decode(Data("E1\t01\t1\t41\t41\t\t".utf8)))
        XCTAssertNil(ZLEEditSnapshotCodec.decode(Data(repeating: 65, count: ZLEEditSnapshotCodec.maxFrameBytes + 1)))
        XCTAssertNil(ZLEEditSnapshotCodec.decode(frame(String(repeating: "a", count: 16 * 1024 + 1))))
    }

    func testSequenceRegressionAndCloseDiscardTransientContent() {
        let tracker = ZLEEditSnapshotTracker()
        tracker.ingest(frame() + Data([10]))
        XCTAssertEqual(tracker.snapshot()?.buffer, "git")
        tracker.ingest(frame(sequence: 1) + Data([10]))
        XCTAssertNil(tracker.snapshot())
        tracker.ingest(frame(sequence: 2) + Data([10]))
        XCTAssertNil(tracker.snapshot())
        tracker.close()
        XCTAssertNil(tracker.snapshot())
    }

    func testPrivateFIFOAndCleanup() async throws {
        let channel = try XCTUnwrap(LocalZLEEditSnapshotChannel())
        let path = channel.fifoPath
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(0o777), mode_t(0o600))
        XCTAssertEqual(lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(0o777), mode_t(0o700))
        let descriptor = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let bytes = frame() + Data([10])
        XCTAssertEqual(bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }, bytes.count)
        let deadline = Date().addingTimeInterval(2)
        while channel.tracker.snapshot() == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(channel.tracker.snapshot()?.buffer, "git")
        Darwin.close(descriptor)
        channel.close()
        XCTAssertNil(channel.tracker.snapshot())
        while FileManager.default.fileExists(atPath: path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    @MainActor
    func testTrackerGatesAndInvalidations() {
        let tracker = TerminalEditableInputTracker()
        tracker.promptReady(1)
        tracker.observeInsertText("git")
        tracker.accept(ZLEEditSnapshotCodec.decode(frame())!)
        XCTAssertTrue(tracker.snapshotMatches)
        tracker.observeInsertText(" status")
        XCTAssertFalse(tracker.snapshotMatches)
        tracker.accept(ZLEEditSnapshotCodec.decode(frame("git status", sequence: 2))!)
        XCTAssertTrue(tracker.snapshotMatches)
        tracker.invalidate()
        XCTAssertFalse(tracker.snapshotMatches)
        tracker.promptReady(2)
        tracker.observeInsertText("中文😀e\u{301}⚠️")
        XCTAssertEqual(tracker.observedPrefix, "中文😀e\u{301}⚠️")
        tracker.accept(ZLEEditSnapshotCodec.decode(frame("mismatch", generation: 2))!)
        XCTAssertFalse(tracker.snapshotMatches)
        tracker.promptReady(3)
        tracker.observeInsertText("abc")
        tracker.accept(ZLEEditSnapshotCodec.decode(frame("abc", generation: 3, post: "ghost"))!)
        XCTAssertFalse(tracker.snapshotMatches)
    }

    @MainActor
    func testSnapshotDisagreementsLockCurrentPrompt() {
        let variants: [ZLEEditSnapshot] = [
            ZLEEditSnapshotCodec.decode(frame("abc", generation: 2))!,
            ZLEEditSnapshotCodec.decode(frame("ab"))!,
            ZLEEditSnapshotCodec.decode(frame("abc", left: "ab", right: "c"))!,
            ZLEEditSnapshotCodec.decode(frame("abc", post: "plugin"))!,
            ZLEEditSnapshotCodec.decode(frame("abc\ndef"))!,
        ]
        for variant in variants {
            let tracker = TerminalEditableInputTracker()
            tracker.promptReady(1)
            tracker.observeInsertText("abc")
            tracker.accept(variant)
            XCTAssertFalse(tracker.snapshotMatches)
            tracker.accept(ZLEEditSnapshotCodec.decode(frame("abc", sequence: 2))!)
            XCTAssertFalse(tracker.snapshotMatches)
        }
    }

    func testEditingKeysArePassThroughInvalidationsOnly() {
        for keyCode: UInt16 in [48, 51, 53, 36, 76, 117, 123, 124, 125, 126, 115, 119] {
            XCTAssertTrue(TerminalEditableKeyDecision.invalidates(
                keyCode: keyCode, modifiers: [], charactersIgnoringModifiers: nil))
        }
        XCTAssertTrue(TerminalEditableKeyDecision.invalidates(
            keyCode: 0, modifiers: [.control], charactersIgnoringModifiers: "a"))
        XCTAssertFalse(TerminalEditableKeyDecision.invalidates(
            keyCode: 0, modifiers: [], charactersIgnoringModifiers: "a"))
        XCTAssertEqual(TerminalEditableEventDecision.routeKey(
            localSession: false, sameWindow: true, exactResponder: true,
            keyCode: 48, modifiers: [], charactersIgnoringModifiers: nil), .passThrough)
        XCTAssertEqual(TerminalEditableEventDecision.routeKey(
            localSession: true, sameWindow: false, exactResponder: true,
            keyCode: 48, modifiers: [], charactersIgnoringModifiers: nil), .passThrough)
        XCTAssertEqual(TerminalEditableEventDecision.routeKey(
            localSession: true, sameWindow: true, exactResponder: false,
            keyCode: 48, modifiers: [], charactersIgnoringModifiers: nil), .passThrough)
        XCTAssertEqual(TerminalEditableEventDecision.routeKey(
            localSession: true, sameWindow: true, exactResponder: true,
            keyCode: 48, modifiers: [], charactersIgnoringModifiers: nil), .invalidateAndPassThrough)
    }

    func testRenderedValidatorRejectsMismatchRightCellsWrapAndWideText() {
        let delegate = NullTerminalDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 10))
        terminal.feed(text: "$ git")
        XCTAssertTrue(TerminalRenderedInputValidator.validate(terminal: terminal, prefix: "git"))
        XCTAssertFalse(TerminalRenderedInputValidator.validate(terminal: terminal, prefix: "gix"))
        XCTAssertFalse(TerminalRenderedInputValidator.validate(terminal: terminal, prefix: "中文"))
        terminal.feed(text: "X\u{1b}[D")
        XCTAssertFalse(TerminalRenderedInputValidator.validate(terminal: terminal, prefix: "git"))
        terminal.feed(text: "\u{1b}[?1049h")
        XCTAssertFalse(TerminalRenderedInputValidator.validate(terminal: terminal, prefix: "git"))
        let wrapped = Terminal(delegate: delegate,
                               options: TerminalOptions(cols: 5, rows: 4, scrollback: 10))
        wrapped.feed(text: "123456")
        XCTAssertFalse(TerminalRenderedInputValidator.validate(terminal: wrapped, prefix: "6"))
    }

    private final class NullTerminalDelegate: TerminalDelegate {
        func sizeChanged(source: Terminal, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: Terminal) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
