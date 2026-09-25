import Foundation
import XCTest
@testable import MacSSH

private actor AdmissionProbe {
    private var calls: [(Int, [UInt8])] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var firstGate: CheckedContinuation<Void, Never>?
    private let holdFirst: Bool
    private let failFirst: Bool

    init(holdFirst: Bool = false, failFirst: Bool = false) {
        self.holdFirst = holdFirst
        self.failFirst = failFirst
    }

    func deliver(target: Int, bytes: [UInt8]) async -> SSHInteractiveInputWriteResult {
        calls.append((target, bytes))
        let ready = countWaiters.filter { calls.count >= $0.0 }
        countWaiters.removeAll { calls.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if holdFirst && calls.count == 1 {
            await withCheckedContinuation { firstGate = $0 }
        }
        if failFirst && calls.count == 1 {
            return SSHInteractiveInputWriteResult(
                requestedBytes: bytes.count,
                acceptedBytes: min(1, bytes.count),
                error: .writeFailed
            )
        }
        return SSHInteractiveInputWriteResult(
            requestedBytes: bytes.count,
            acceptedBytes: bytes.count,
            error: nil
        )
    }

    func waitForCount(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func releaseFirst() {
        firstGate?.resume()
        firstGate = nil
    }

    func snapshot() -> [(Int, [UInt8])] { calls }
}

private actor AdmissionFailureSignal {
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func record() {
        count += 1
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if count > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

final class RemoteInputAdmissionQueueTests: XCTestCase {
    func testSuffixThenImmediateEnterPreservesExactBytesAndOrder() async {
        let probe = AdmissionProbe(holdFirst: true)
        let queue = RemoteTerminalInputAdmissionQueue<Int>(writer: {
            await probe.deliver(target: $0, bytes: $1)
        })
        queue.install(1)
        XCTAssertEqual(queue.enqueue(Array("好🙂".utf8)), 1)
        await probe.waitForCount(1)
        XCTAssertEqual(queue.enqueue([13]), 2)
        await probe.releaseFirst()
        await probe.waitForCount(2)
        let calls = await probe.snapshot()
        XCTAssertEqual(calls.map { $0.0 }, [1, 1])
        XCTAssertEqual(calls.map { $0.1 }, [Array("好🙂".utf8), [13]])
    }

    func testManyRapidChunksPreserveSynchronousAdmissionOrder() async {
        let probe = AdmissionProbe()
        let queue = RemoteTerminalInputAdmissionQueue<Int>(writer: {
            await probe.deliver(target: $0, bytes: $1)
        })
        queue.install(7)
        for value in 0..<100 {
            XCTAssertEqual(queue.enqueue([UInt8(value)]), UInt64(value + 1))
        }
        await probe.waitForCount(100)
        let calls = await probe.snapshot()
        XCTAssertEqual(calls.map { $0.1[0] }, Array(0..<100).map(UInt8.init))
    }

    func testReconnectDropsQueuedOldGenerationWithoutRetargeting() async {
        let probe = AdmissionProbe(holdFirst: true)
        let queue = RemoteTerminalInputAdmissionQueue<Int>(writer: {
            await probe.deliver(target: $0, bytes: $1)
        })
        queue.install(1)
        queue.enqueue([65])
        await probe.waitForCount(1)
        queue.enqueue([66])
        queue.clear()
        queue.install(2)
        queue.enqueue([67])
        await probe.waitForCount(2)
        await probe.releaseFirst()
        let calls = await probe.snapshot()
        XCTAssertEqual(calls.map { $0.0 }, [1, 2])
        XCTAssertEqual(calls.map { $0.1 }, [[65], [67]])
    }

    func testPartialFailureInvalidatesQueueWithoutReplayingLaterBytes() async {
        let probe = AdmissionProbe(holdFirst: true, failFirst: true)
        let failure = AdmissionFailureSignal()
        let queue = RemoteTerminalInputAdmissionQueue<Int>(
            writer: { await probe.deliver(target: $0, bytes: $1) },
            onFailure: { _, _ in Task { await failure.record() } }
        )
        let firstGeneration = queue.install(1)
        queue.enqueue([65, 66])
        await probe.waitForCount(1)
        queue.enqueue([67])
        await probe.releaseFirst()
        await failure.wait()
        XCTAssertTrue(queue.isFailedGeneration(firstGeneration))
        XCTAssertNil(queue.enqueue([68]))
        let calls = await probe.snapshot()
        XCTAssertEqual(calls.map { $0.1 }, [[65, 66]])
        queue.install(2)
        XCTAssertFalse(queue.isFailedGeneration(firstGeneration))
        queue.enqueue([69])
        await probe.waitForCount(2)
        let after = await probe.snapshot()
        XCTAssertEqual(after.map { $0.0 }, [1, 2])
    }

    func testBoundedQueueOverflowFailsClosedWithoutDeliveringQueuedSuffix() async {
        let probe = AdmissionProbe(holdFirst: true)
        let failure = AdmissionFailureSignal()
        let queue = RemoteTerminalInputAdmissionQueue<Int>(
            maxQueuedBytes: 1,
            writer: { await probe.deliver(target: $0, bytes: $1) },
            onFailure: { _, _ in Task { await failure.record() } }
        )
        let firstGeneration = queue.install(1)
        queue.enqueue([65])
        await probe.waitForCount(1)
        queue.enqueue([66])
        XCTAssertNil(queue.enqueue([67]))
        await failure.wait()
        XCTAssertTrue(queue.isFailedGeneration(firstGeneration))
        XCTAssertNil(queue.enqueue([70]))
        await probe.releaseFirst()
        queue.install(2)
        XCTAssertFalse(queue.isFailedGeneration(firstGeneration))
        queue.enqueue([68])
        await probe.waitForCount(2)
        let calls = await probe.snapshot()
        XCTAssertEqual(calls.map { $0.1 }, [[65], [68]])
        XCTAssertEqual(calls.map { $0.0 }, [1, 2])
    }

    func testDelegateNoLongerStartsTaskPerInputAndNoKeyInterceptionExists() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent(
            "MacSSH/Services/Terminal/RemoteTerminalService.swift"
        ), encoding: .utf8)
        let body = try XCTUnwrap(service.components(separatedBy: "nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>)").last)
            .components(separatedBy: "nonisolated func sizeChanged")[0]
        XCTAssertTrue(body.contains("inputAdmission.enqueue(Array(data))"))
        XCTAssertFalse(body.contains("Task {"))
        XCTAssertFalse(body.contains("keyDown"))
    }
}
