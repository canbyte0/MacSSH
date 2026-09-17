import Darwin
import Foundation
import XCTest

@testable import MacSSH

/// Phase 10F-C2 的 focused filesystem tests。
///
/// 这些测试只通过 C1 request/approval/coordinator 与 C2 executor 进入；
/// 不调用 Provider，也不直接替代 production executor 写目标文件。
final class AgentFileMutationExecutorTests: XCTestCase {
    func testPreferredPublicationWritesExactUTF8BytesAndLeavesNoPrivateResidue() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let content = "中文🙂e\u{301}\n末尾无改写\u{0}"
        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "exact.txt",
            content: content,
            callID: "c2-success"
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )

        let result = await AgentLocalFileMutationExecutor(
            authorization: authorization,
            targetCapability: request.parentCapability,
            approvalCoordinator: coordinator
        ).execute()

        XCTAssertTrue(result.published)
        XCTAssertEqual(result.publicationMethod, .rename)
        XCTAssertEqual(result.payloadBytesRequested, Data(content.utf8).count)
        XCTAssertEqual(result.payloadBytesWrittenToTemp, Data(content.utf8).count)
        XCTAssertTrue(result.cleanupComplete)
        XCTAssertFalse(result.cleanupResidue)
        XCTAssertNil(result.error)

        let destination = root.appendingPathComponent("exact.txt")
        XCTAssertEqual(try Data(contentsOf: destination), Data(content.utf8))
        var status = stat()
        XCTAssertEqual(lstat(destination.path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)

        await coordinator.purgeGeneration(request.generationID)
    }

    func testEmptyPayloadPerformsFsyncAndPublishesZeroByteFile() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let prepared = try await makeAuthorization(
            root: root,
            path: "empty.txt",
            content: "",
            callID: "c2-empty"
        )
        let fake = AgentFileMutationInjectingFileSystem()
        let result = await makeExecutor(prepared, fake: fake).execute()

        XCTAssertTrue(result.published)
        XCTAssertEqual(result.payloadBytesRequested, 0)
        XCTAssertEqual(result.payloadBytesWrittenToTemp, 0)
        XCTAssertEqual(fake.observedCounts().writes, 0)
        XCTAssertEqual(fake.observedCounts().synchronize, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("empty.txt")), Data())
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testReplayAndConcurrentReplayHaveExactlyOnePhysicalWinner() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "replay.txt",
            content: "one approved payload",
            callID: "c2-replay"
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )

        let results = await withTaskGroup(of: AgentLocalFileMutationResult.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await AgentLocalFileMutationExecutor(
                        authorization: authorization,
                        targetCapability: request.parentCapability,
                        approvalCoordinator: coordinator
                    ).execute()
                }
            }
            var values: [AgentLocalFileMutationResult] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.filter(\.published).count, 1)
        XCTAssertEqual(
            results.filter { !$0.published && $0.error == .approvalAlreadyConsumed }.count,
            49
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("replay.txt")),
            Data("one approved payload".utf8)
        )
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await coordinator.purgeGeneration(request.generationID)
    }

    func testDestinationRaceIsNoClobberAndPreservesExistingObject() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "race.txt",
            content: "approved",
            callID: "c2-destination-race"
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )

        let existing = Data("pre-existing".utf8)
        try existing.write(to: root.appendingPathComponent("race.txt"), options: .withoutOverwriting)
        let result = await AgentLocalFileMutationExecutor(
            authorization: authorization,
            targetCapability: request.parentCapability,
            approvalCoordinator: coordinator
        ).execute()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.error, .destinationAlreadyExists)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("race.txt")), existing)
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await coordinator.purgeGeneration(request.generationID)
    }

    func testParentPathReplacementCannotRetargetMutationToReplacementDirectory() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        let movedParent = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-moved", isDirectory: true)
        defer {
            AgentFileMutationTestSupport.removeTemporaryRoot(root)
            AgentFileMutationTestSupport.removeTemporaryRoot(movedParent)
        }

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "parent-bound.txt",
            content: "must land in original inode",
            callID: "c2-parent-replacement"
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )

        try FileManager.default.moveItem(at: root, to: movedParent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let result = await AgentLocalFileMutationExecutor(
            authorization: authorization,
            targetCapability: request.parentCapability,
            approvalCoordinator: coordinator
        ).execute()

        XCTAssertTrue(result.published)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: movedParent.appendingPathComponent("parent-bound.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("parent-bound.txt").path
        ))
        await coordinator.purgeGeneration(request.generationID)
    }

    func testCancellationBeforeRedeemConsumesNothingAndMutatesNothing() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "cancel-before-redeem.txt",
            content: "not written",
            callID: "c2-cancel-before-redeem"
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )

        let executor = AgentLocalFileMutationExecutor(
            authorization: authorization,
            targetCapability: request.parentCapability,
            approvalCoordinator: coordinator
        )
        let task = Task {
            await executor.execute()
        }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.error, .cancelled)
        XCTAssertFalse(result.published)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("cancel-before-redeem.txt").path
        ))
        await coordinator.purgeGeneration(request.generationID)
    }

    func testCancellationAtFirstMutationBarrierLeavesDestinationAbsent() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: "cancel-at-boundary.txt",
            content: "not written",
            callID: "c2-cancel-at-boundary"
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )

        let reachedFirstMutationBarrier = DispatchSemaphore(value: 0)
        let releaseFirstMutationBarrier = DispatchSemaphore(value: 0)
        let executor = AgentLocalFileMutationExecutor(
            authorization: authorization,
            targetCapability: request.parentCapability,
            approvalCoordinator: coordinator,
            hooks: AgentLocalFileMutationExecutorHooks(
                beforeFirstMutation: {
                    reachedFirstMutationBarrier.signal()
                    releaseFirstMutationBarrier.wait()
                },
                afterFsyncBeforePublication: nil,
                beforePublication: nil
            )
        )
        let task = Task { await executor.execute() }
        XCTAssertEqual(reachedFirstMutationBarrier.wait(timeout: .now() + 5), .success)
        task.cancel()
        releaseFirstMutationBarrier.signal()
        let result = await task.value

        XCTAssertEqual(result.error, .cancelled)
        XCTAssertFalse(result.published)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("cancel-at-boundary.txt").path
        ))
        await coordinator.purgeGeneration(request.generationID)
    }

    func testCancellationMidWriteStopsBeforePublicationAndCleansPrivateObjects() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let prepared = try await makeAuthorization(
            root: root,
            path: "cancel-mid-write.txt",
            content: "abcdef",
            callID: "c2-cancel-mid-write"
        )
        let reachedWrite = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let fake = AgentFileMutationInjectingFileSystem(plans: [.partial(3)])
        fake.afterWrite = {
            reachedWrite.signal()
            releaseWrite.wait()
        }

        let executor = makeExecutor(prepared, fake: fake)
        let task = Task { await executor.execute() }
        XCTAssertEqual(reachedWrite.wait(timeout: .now() + 5), .success)
        task.cancel()
        releaseWrite.signal()
        let result = await task.value

        XCTAssertEqual(result.error, .cancelled)
        XCTAssertEqual(result.payloadBytesWrittenToTemp, 3)
        XCTAssertFalse(result.published)
        XCTAssertTrue(result.cleanupComplete)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("cancel-mid-write.txt").path
        ))
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testCancellationAfterFsyncBeforePublicationLeavesDestinationAbsent() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let prepared = try await makeAuthorization(
            root: root,
            path: "cancel-after-fsync.txt",
            content: "not published",
            callID: "c2-cancel-after-fsync"
        )
        let reachedFsyncBarrier = DispatchSemaphore(value: 0)
        let releaseFsyncBarrier = DispatchSemaphore(value: 0)
        let executor = makeExecutor(
            prepared,
            hooks: AgentLocalFileMutationExecutorHooks(
                beforeFirstMutation: nil,
                afterFsyncBeforePublication: {
                    reachedFsyncBarrier.signal()
                    releaseFsyncBarrier.wait()
                },
                beforePublication: nil
            )
        )
        let task = Task { await executor.execute() }
        XCTAssertEqual(reachedFsyncBarrier.wait(timeout: .now() + 5), .success)
        task.cancel()
        releaseFsyncBarrier.signal()
        let result = await task.value

        XCTAssertEqual(result.error, .cancelled)
        XCTAssertFalse(result.published)
        XCTAssertTrue(result.cleanupComplete)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("cancel-after-fsync.txt").path
        ))
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testCancellationAtPublicationBarrierStopsBeforePublication() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let prepared = try await makeAuthorization(
            root: root,
            path: "cancel-publication-barrier.txt",
            content: "not published",
            callID: "c2-cancel-publication-barrier"
        )
        let reachedPublicationBarrier = DispatchSemaphore(value: 0)
        let releasePublicationBarrier = DispatchSemaphore(value: 0)
        let executor = makeExecutor(
            prepared,
            hooks: AgentLocalFileMutationExecutorHooks(
                beforeFirstMutation: nil,
                afterFsyncBeforePublication: nil,
                beforePublication: {
                    reachedPublicationBarrier.signal()
                    releasePublicationBarrier.wait()
                }
            )
        )
        let task = Task { await executor.execute() }
        XCTAssertEqual(reachedPublicationBarrier.wait(timeout: .now() + 5), .success)
        task.cancel()
        releasePublicationBarrier.signal()
        let result = await task.value

        XCTAssertEqual(result.error, .cancelled)
        XCTAssertFalse(result.published)
        XCTAssertTrue(result.cleanupComplete)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("cancel-publication-barrier.txt").path
        ))
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testCancellationDuringPublicationStillReportsPublished() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let prepared = try await makeAuthorization(
            root: root,
            path: "cancel-during-publication.txt",
            content: "published despite cancellation",
            callID: "c2-cancel-during-publication"
        )
        let reachedPublication = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let fake = AgentFileMutationInjectingFileSystem()
        fake.afterPreferredPublication = {
            reachedPublication.signal()
            releasePublication.wait()
        }
        let executor = makeExecutor(prepared, fake: fake)
        let task = Task { await executor.execute() }
        XCTAssertEqual(reachedPublication.wait(timeout: .now() + 5), .success)
        task.cancel()
        releasePublication.signal()
        let result = await task.value

        XCTAssertTrue(result.published)
        XCTAssertEqual(result.publicationMethod, .rename)
        XCTAssertNil(result.error)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("cancel-during-publication.txt")),
            Data("published despite cancellation".utf8)
        )
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testShortWritesRetryEINTRAndPreserveExactAccounting() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "short-write.txt",
            content: "abcdef",
            callID: "c2-short-write"
        )
        let fake = AgentFileMutationInjectingFileSystem(plans: [
            .partial(2), .eintr, .partial(1), .partial(3)
        ])
        let result = await makeExecutor(prepared, fake: fake).execute()

        XCTAssertTrue(result.published)
        XCTAssertEqual(result.payloadBytesRequested, 6)
        XCTAssertEqual(result.payloadBytesWrittenToTemp, 6)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("short-write.txt")), Data("abcdef".utf8))
        XCTAssertEqual(fake.observedCounts().writes, 4)
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testZeroWriteAndFatalPartialWriteNeverPublish() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }

        let zero = try await makeAuthorization(
            root: root,
            path: "zero-write.txt",
            content: "payload",
            callID: "c2-zero-write"
        )
        let zeroResult = await makeExecutor(
            zero,
            fake: AgentFileMutationInjectingFileSystem(plans: [.zero])
        ).execute()
        XCTAssertFalse(zeroResult.published)
        XCTAssertEqual(zeroResult.error, .zeroByteWrite)
        XCTAssertEqual(zeroResult.payloadBytesWrittenToTemp, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("zero-write.txt").path))
        await zero.coordinator.purgeGeneration(zero.request.generationID)

        let fatal = try await makeAuthorization(
            root: root,
            path: "fatal-write.txt",
            content: "payload",
            callID: "c2-fatal-write"
        )
        let fatalFake = AgentFileMutationInjectingFileSystem(plans: [.partial(3), .fatal(EIO)])
        let fatalResult = await makeExecutor(fatal, fake: fatalFake).execute()
        XCTAssertFalse(fatalResult.published)
        XCTAssertEqual(fatalResult.error, .payloadWriteFailed)
        XCTAssertEqual(fatalResult.payloadBytesWrittenToTemp, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fatal-write.txt").path))
        await fatal.coordinator.purgeGeneration(fatal.request.generationID)
    }

    func testFsyncFailureLeavesDestinationAbsentAndConsumesAuthorization() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "fsync-failure.txt",
            content: "private temp",
            callID: "c2-fsync-failure"
        )
        let result = await makeExecutor(
            prepared,
            fake: AgentFileMutationInjectingFileSystem(synchronizeFailure: EIO)
        ).execute()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.error, .tempSyncFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fsync-failure.txt").path))
        let replay = await makeExecutor(
            prepared,
            fake: AgentFileMutationInjectingFileSystem()
        ).execute()
        XCTAssertEqual(replay.error, .approvalAlreadyConsumed)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testUnsupportedRenameUsesNoClobberLinkFallback() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "fallback.txt",
            content: "fallback payload",
            callID: "c2-fallback-success"
        )
        let fake = AgentFileMutationInjectingFileSystem(preferredPublicationFailure: ENOTSUP)
        let result = await makeExecutor(prepared, fake: fake).execute()

        XCTAssertTrue(result.published)
        XCTAssertEqual(result.publicationMethod, .fallbackLink)
        XCTAssertEqual(fake.observedCounts().publish, 1)
        XCTAssertEqual(fake.observedCounts().link, 1)
        XCTAssertTrue(result.cleanupComplete)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("fallback.txt")), Data("fallback payload".utf8))
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testFallbackLinkFailureDoesNotFallbackAgainOrPublish() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "fallback-failure.txt",
            content: "fallback payload",
            callID: "c2-fallback-failure"
        )
        let fake = AgentFileMutationInjectingFileSystem(
            preferredPublicationFailure: ENOTSUP,
            fallbackLinkFailure: EACCES
        )
        let result = await makeExecutor(prepared, fake: fake).execute()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.error, .fallbackPublicationFailed)
        XCTAssertEqual(fake.observedCounts().publish, 1)
        XCTAssertEqual(fake.observedCounts().link, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fallback-failure.txt").path))
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testFallbackLinkEEXISTPreservesDestinationAndDoesNotRetry() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "fallback-eexist.txt",
            content: "must not clobber",
            callID: "c2-fallback-eexist"
        )
        let existing = Data("existing fallback winner".utf8)
        try existing.write(
            to: root.appendingPathComponent("fallback-eexist.txt"),
            options: .withoutOverwriting
        )
        let fake = AgentFileMutationInjectingFileSystem(preferredPublicationFailure: ENOTSUP)
        let result = await makeExecutor(prepared, fake: fake).execute()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.error, .destinationAlreadyExists)
        XCTAssertEqual(fake.observedCounts().publish, 1)
        XCTAssertEqual(fake.observedCounts().link, 1)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("fallback-eexist.txt")),
            existing
        )
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testFallbackSourceUnlinkFailureReportsPublishedWithResidue() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "fallback-residue.txt",
            content: "published once",
            callID: "c2-fallback-residue"
        )
        let fake = AgentFileMutationInjectingFileSystem(
            preferredPublicationFailure: ENOTSUP,
            unlinkFailureCall: 1
        )
        let result = await makeExecutor(prepared, fake: fake).execute()

        XCTAssertTrue(result.published)
        XCTAssertEqual(result.publicationMethod, .fallbackLink)
        XCTAssertTrue(result.cleanupResidue)
        XCTAssertEqual(result.error, .cleanupResidue)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("fallback-residue.txt")), Data("published once".utf8))
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testSourceReplacementIsDetectedAndReplacementIsPreserved() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "source-replaced.txt",
            content: "original",
            callID: "c2-source-replaced"
        )
        let fake = AgentFileMutationInjectingFileSystem()
        let names = AgentFileMutationFixedNameGenerator(
            stagingName: ".macssh-agent-write-source",
            temporaryName: ".macssh-agent-temp-source"
        )
        let replacement = Data("replacement object".utf8)
        let executor = AgentLocalFileMutationExecutor(
            authorization: prepared.authorization,
            targetCapability: prepared.request.parentCapability,
            approvalCoordinator: prepared.coordinator,
            fileSystem: fake,
            nameGenerator: names,
            hooks: AgentLocalFileMutationExecutorHooks(
                beforeFirstMutation: nil,
                afterFsyncBeforePublication: nil,
                beforePublication: {
                    let temp = root
                        .appendingPathComponent(names.stagingName, isDirectory: true)
                        .appendingPathComponent(names.temporaryName)
                    try? FileManager.default.removeItem(at: temp)
                    try? replacement.write(to: temp, options: .withoutOverwriting)
                }
            )
        )
        let result = await executor.execute()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.error, .sourceReplaced)
        XCTAssertTrue(result.cleanupResidue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("source-replaced.txt").path))
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(names.stagingName).appendingPathComponent(names.temporaryName)),
            replacement
        )
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testCleanupGuardsRefuseReplacedTempAndStagingNames() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "cleanup-guards.txt",
            content: "original",
            callID: "c2-cleanup-guards"
        )
        let fake = AgentFileMutationInjectingFileSystem()
        let names = AgentFileMutationFixedNameGenerator(
            stagingName: ".macssh-agent-write-cleanup",
            temporaryName: ".macssh-agent-temp-cleanup"
        )
        fake.afterSynchronize = {
            let staging = root.appendingPathComponent(names.stagingName, isDirectory: true)
            let temp = staging.appendingPathComponent(names.temporaryName)
            try? FileManager.default.removeItem(at: temp)
            try? Data("replacement temp".utf8).write(to: temp, options: .withoutOverwriting)
        }
        let result = await makeExecutor(prepared, fake: fake, names: names).execute()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.error, .sourceReplaced)
        XCTAssertTrue(result.cleanupResidue)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(names.stagingName).appendingPathComponent(names.temporaryName)),
            Data("replacement temp".utf8)
        )
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testDestinationSymlinkAndDanglingSymlinkAreNeverClobbered() async throws {
        for (index, dangling) in [false, true].enumerated() {
            let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
            let target = root.appendingPathComponent("symlink-\(index).txt")
            let linkTarget = dangling ? "/definitely/missing" : root.appendingPathComponent("safe.txt").path
            defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
            let prepared = try await makeAuthorization(
                root: root,
                path: target.lastPathComponent,
                content: "must not replace link",
                callID: "c2-symlink-\(index)"
            )
            XCTAssertEqual(symlink(linkTarget, target.path), 0)
            let result = await makeExecutor(prepared).execute()
            XCTAssertFalse(result.published)
            XCTAssertEqual(result.error, .destinationAlreadyExists)
            var linkStatus = stat()
            XCTAssertEqual(lstat(target.path, &linkStatus), 0)
            XCTAssertEqual(linkStatus.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
            await prepared.coordinator.purgeGeneration(prepared.request.generationID)
        }
    }

    func testDestinationDirectoryRaceIsNoClobber() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "directory-race",
            content: "must not replace directory",
            callID: "c2-directory-race"
        )
        let destination = root.appendingPathComponent("directory-race", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        let result = await makeExecutor(prepared).execute()
        XCTAssertFalse(result.published)
        XCTAssertEqual(result.error, .destinationAlreadyExists)
        var status = stat()
        XCTAssertEqual(lstat(destination.path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFDIR))
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testPreferredOrdinaryFailureDoesNotEnterLinkFallback() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let prepared = try await makeAuthorization(
            root: root,
            path: "preferred-error.txt",
            content: "not published",
            callID: "c2-preferred-error"
        )
        let fake = AgentFileMutationInjectingFileSystem(preferredPublicationFailure: EACCES)
        let result = await makeExecutor(prepared, fake: fake).execute()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.error, .publicationFailed)
        XCTAssertEqual(fake.observedCounts().publish, 1)
        XCTAssertEqual(fake.observedCounts().link, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("preferred-error.txt").path
        ))
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
        await prepared.coordinator.purgeGeneration(prepared.request.generationID)
    }

    func testTwoIndependentApprovedRequestsSameDestinationHaveOneWinner() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        let first = try await makeAuthorization(
            root: root,
            path: "same-destination.txt",
            content: "first complete payload",
            callID: "c2-independent-a"
        )
        let second = try await makeAuthorization(
            root: root,
            path: "same-destination.txt",
            content: "second complete payload",
            callID: "c2-independent-b"
        )

        let firstExecutor = makeExecutor(first)
        let secondExecutor = makeExecutor(second)
        let results = await withTaskGroup(of: AgentLocalFileMutationResult.self) { group in
            group.addTask { await firstExecutor.execute() }
            group.addTask { await secondExecutor.execute() }
            var values: [AgentLocalFileMutationResult] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter(\.published).count, 1)
        XCTAssertEqual(results.filter { $0.error == .destinationAlreadyExists }.count, 1)
        let final = try Data(contentsOf: root.appendingPathComponent("same-destination.txt"))
        XCTAssertTrue(final == Data("first complete payload".utf8) || final == Data("second complete payload".utf8))
        await first.coordinator.purgeGeneration(first.request.generationID)
        await second.coordinator.purgeGeneration(second.request.generationID)
    }

    func testParentReplacementStress50NeverMutatesReplacementDirectory() async throws {
        for index in 0..<50 {
            let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
            let movedParent = root.deletingLastPathComponent()
                .appendingPathComponent(root.lastPathComponent + "-moved", isDirectory: true)
            defer {
                AgentFileMutationTestSupport.removeTemporaryRoot(root)
                AgentFileMutationTestSupport.removeTemporaryRoot(movedParent)
            }

            let prepared = try await makeAuthorization(
                root: root,
                path: "parent-stress-(index).txt",
                content: "original parent (index)",
                callID: "c2-parent-stress-(index)"
            )
            try FileManager.default.moveItem(at: root, to: movedParent)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

            let result = await makeExecutor(prepared).execute()
            XCTAssertTrue(result.published, "parent replacement iteration \(index) must publish")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: movedParent.appendingPathComponent("parent-stress-(index).txt").path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("parent-stress-(index).txt").path
            ))
            await prepared.coordinator.purgeGeneration(prepared.request.generationID)
        }
    }

    func testPreferredPublicationStress100LeavesNoPrivateArtifacts() async throws {
        let root = try AgentFileMutationTestSupport.makeTemporaryRoot()
        defer { AgentFileMutationTestSupport.removeTemporaryRoot(root) }
        for index in 0..<100 {
            let result = try await execute(
                root: root,
                path: "stress-\(index).txt",
                content: "stress payload \(index)",
                callID: "c2-stress-\(index)"
            )
            XCTAssertTrue(result.published, "stress iteration \(index) must publish")
            XCTAssertEqual(result.publicationMethod, .rename)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("stress-") }.count,
            100
        )
        XCTAssertTrue(try privateArtifacts(in: root).isEmpty)
    }

    // MARK: Helpers

    private func execute(
        root: URL,
        path: String,
        content: String,
        callID: String
    ) async throws -> AgentLocalFileMutationResult {
        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: path,
            content: content,
            callID: callID
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )
        let result = await AgentLocalFileMutationExecutor(
            authorization: authorization,
            targetCapability: request.parentCapability,
            approvalCoordinator: coordinator
        ).execute()
        await coordinator.purgeGeneration(request.generationID)
        return result
    }

    private func makeAuthorization(
        root: URL,
        path: String,
        content: String,
        callID: String
    ) async throws -> (
        request: AgentFileMutationRequest,
        coordinator: AgentFileMutationApprovalCoordinator,
        authorization: AgentFileMutationExecutionAuthorization
    ) {
        let request = try await AgentFileMutationTestSupport.makeRequest(
            root: root,
            path: path,
            content: content,
            callID: callID
        )
        let coordinator = AgentFileMutationApprovalCoordinator()
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        let authorization = try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentFileMutationTestSupport.expectations(for: request)
        )
        return (request, coordinator, authorization)
    }

    private func makeExecutor(
        _ prepared: (
            request: AgentFileMutationRequest,
            coordinator: AgentFileMutationApprovalCoordinator,
            authorization: AgentFileMutationExecutionAuthorization
        ),
        fake: AgentFileMutationInjectingFileSystem? = nil,
        names: AgentFileMutationFixedNameGenerator? = nil,
        hooks: AgentLocalFileMutationExecutorHooks = .none
    ) -> AgentLocalFileMutationExecutor {
        AgentLocalFileMutationExecutor(
            authorization: prepared.authorization,
            targetCapability: prepared.request.parentCapability,
            approvalCoordinator: prepared.coordinator,
            fileSystem: fake ?? AgentLocalFileMutationDarwinFileSystem(),
            nameGenerator: names ?? AgentLocalFileMutationUUIDNameGenerator(),
            hooks: hooks
        )
    }

    private func privateArtifacts(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".macssh-agent-write-")
                || $0.lastPathComponent.hasPrefix(".macssh-agent-temp-")
        }
    }
}
