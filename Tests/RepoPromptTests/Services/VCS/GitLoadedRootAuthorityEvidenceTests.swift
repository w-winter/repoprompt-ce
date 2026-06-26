import CoreServices
import Foundation
@testable import RepoPrompt
import XCTest

final class GitLoadedRootAuthorityEvidenceTests: XCTestCase {
    func testAutomaticAuthorityCapturesShareOnePhysicalPrefixScanAndWarmCaptureHits() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let scope = GitWorkspaceAuthorityScopeKey(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout),
            repositoryRelativeRootPrefix: prefix
        )

        let discovery = try await git.workspaceAuthoritySnapshot(in: fixture.layout, prefix: prefix)
        let captureToken = try await authority.beginCollection(scopeKey: scope).get()
        let captured = try await git.workspaceAuthoritySnapshot(in: fixture.layout, prefix: prefix)
        _ = try await authority.install(captured.snapshot, capturedUsing: captureToken).get()
        var counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.prefixControlCacheMissCount, 1)
        XCTAssertEqual(counters.prefixControlCacheHitCount, 1)
        XCTAssertEqual(counters.prefixControlCacheAdmissionCount, 1)
        XCTAssertEqual(discovery.snapshot, captured.snapshot)

        let warm = try await git.workspaceAuthoritySnapshot(in: fixture.layout, prefix: prefix)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.prefixControlCacheHitCount, 2)
        XCTAssertEqual(warm.snapshot, captured.snapshot)

        let bypassAuthority = GitWorkspaceStateAuthority()
        let bypassGit = GitService(workspaceStateAuthority: bypassAuthority)
        let bypassA = try await bypassGit.workspaceAuthoritySnapshot(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .bypassReadAndAdmission
        )
        let bypassB = try await bypassGit.workspaceAuthoritySnapshot(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .bypassReadAndAdmission
        )
        let bypassCounters = await bypassAuthority.snapshotForTesting()
        XCTAssertEqual(bypassCounters.prefixControlPhysicalScanCount, 2)
        XCTAssertEqual(bypassCounters.prefixControlCacheBypassCount, 2)
        XCTAssertEqual(bypassCounters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(bypassA.snapshot, bypassB.snapshot)
        XCTAssertEqual(bypassA.snapshot, captured.snapshot)
    }

    func testIdenticalPrefixCollectionCoalescesAndWaiterCancellationIsScoped() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let gate = PrefixControlCollectorGate(footer: prefixFooter())

        let first = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 1 }
        let second = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        try await waitUntil { await authority.snapshotForTesting().prefixControlCacheCoalescedWaiterCount == 1 }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected cancelled waiter")
        } catch is CancellationError {}
        await gate.release()
        let secondValue = try await second.value
        let collectionCount = await gate.collectionCount()
        XCTAssertEqual(secondValue, prefixFooter())
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(collectionCount, 1)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 0)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.pendingPrefixControlArtifactBytes, 0)
    }

    func testMonitorGapThenPrefixMissAndHitNeverRestoreRepositoryMetadataCoverage() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let key = GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout)
        let scope = GitWorkspaceAuthorityScopeKey(
            repositoryKey: key,
            repositoryRelativeRootPrefix: prefix
        )
        let counter = PrefixControlCollectorCounter(footer: prefixFooter())

        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        await authority.metadataDidChange(repositoryKey: key, kinds: [.monitorGap])

        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }

        let collectionCount = await counter.collectionCount()
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(collectionCount, 2)
        XCTAssertEqual(counters.prefixControlCacheMissCount, 2)
        XCTAssertEqual(counters.prefixControlCacheHitCount, 1)
        switch await authority.beginCollection(scopeKey: scope) {
        case .success:
            XCTFail("Narrow prefix-control coverage must not restore repository metadata coverage")
        case let .failure(reason):
            XCTAssertEqual(reason, .monitorCoverageUnavailable)
        }

        let fullObservation = try await authority.retainMetadataObservation(for: fixture.layout)
        switch await authority.beginCollection(scopeKey: scope) {
        case .success:
            break
        case let .failure(reason):
            XCTFail("Validated full metadata coverage must restore collection: \(reason)")
        }
        await authority.releaseMetadataObservation(fullObservation)
    }

    func testSaturatedAdmissionUsesOneBoundedUncachedFlightForIdenticalCalls() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority(prefixControlCacheLimits: .init(
            maximumEntryCount: 2,
            maximumEntriesPerRepository: 2,
            maximumResidentBytes: 1024,
            maximumArtifactBytes: 0,
            maximumPendingAdmissionCount: 1,
            maximumPendingResidentBytes: 512,
            maximumPendingArtifactBytes: 0
        ))
        let firstGate = PrefixControlCollectorGate(footer: prefixFooter())
        let saturatedGate = PrefixControlCollectorGate(footer: prefixFooter())

        let first = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                cacheMode: .automatic
            ) { try await firstGate.collect() }
        }
        await firstGate.waitUntilCollectionStarts()

        let saturatedA = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix("Sources"),
                cacheMode: .automatic
            ) { try await saturatedGate.collect() }
        }
        await saturatedGate.waitUntilCollectionStarts()
        let saturatedB = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix("Sources"),
                cacheMode: .automatic
            ) { try await saturatedGate.collect() }
        }
        try await waitUntil {
            await authority.snapshotForTesting().prefixControlCacheCoalescedWaiterCount == 1
        }

        var counters = await authority.snapshotForTesting()
        let saturatedCollectionCount = await saturatedGate.collectionCount()
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 2)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 1024)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)
        XCTAssertEqual(saturatedCollectionCount, 1)

        await saturatedGate.release()
        let saturatedAValue = try await saturatedA.value
        let saturatedBValue = try await saturatedB.value
        XCTAssertEqual(saturatedAValue, prefixFooter())
        XCTAssertEqual(saturatedBValue, prefixFooter())
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 512)

        await firstGate.release()
        _ = try await first.value
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 0 }
    }

    func testSoleWaiterCancellationRetainsFlightResourcesUntilSlowCollectorCompletes() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let gate = PrefixControlCollectorGate(footer: prefixFooter())

        let waiter = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        await gate.waitUntilCollectionStarts()
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected waiter cancellation")
        } catch is CancellationError {}

        var counters = await authority.snapshotForTesting()
        var monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 512)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 1)

        await gate.release()
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 0 }
        counters = await authority.snapshotForTesting()
        monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.pendingPrefixControlArtifactBytes, 0)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)
    }

    func testCancelledSameKeyFlightRemainsAuthoritativeUntilPhysicalCompletion() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let gate = PrefixControlCollectorGate(footer: prefixFooter())

        let first = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        await gate.waitUntilCollectionStarts()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected first waiter cancellation")
        } catch is CancellationError {}

        do {
            _ = try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
            XCTFail("Expected bounded rejection while cancelled physical flight remains active")
        } catch let error as GitPrefixControlEvidenceCacheError {
            XCTAssertEqual(error, .resourceAdmission)
        }

        var counters = await authority.snapshotForTesting()
        var monitorState = await monitor.snapshotForTesting()
        var collectionCount = await gate.collectionCount()
        XCTAssertEqual(collectionCount, 1)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 512)
        XCTAssertEqual(monitorState.retainTokenCount, 1)

        await gate.release()
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 0 }
        counters = await authority.snapshotForTesting()
        monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.pendingPrefixControlArtifactBytes, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)

        let retry = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { try await gate.collect() }
        XCTAssertEqual(retry, prefixFooter())
        counters = await authority.snapshotForTesting()
        collectionCount = await gate.collectionCount()
        XCTAssertEqual(collectionCount, 2)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)

        await authority.metadataDidChange(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout),
            kinds: [.monitorGap]
        )
        monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(monitorState.retainTokenCount, 0)
    }

    func testCancelledUncachedSameKeyFlightRemainsAuthoritativeUntilPhysicalCompletion() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(
            metadataMonitor: monitor,
            prefixControlCacheLimits: .init(
                maximumEntryCount: 1,
                maximumEntriesPerRepository: 1,
                maximumResidentBytes: 512,
                maximumArtifactBytes: 0,
                maximumPendingAdmissionCount: 1,
                maximumPendingResidentBytes: 1,
                maximumPendingArtifactBytes: 0
            )
        )
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let gate = PrefixControlCollectorGate(footer: prefixFooter())

        let first = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        await gate.waitUntilCollectionStarts()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected first uncached waiter cancellation")
        } catch is CancellationError {}

        do {
            _ = try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
            XCTFail("Expected bounded rejection while cancelled uncached flight remains active")
        } catch let error as GitPrefixControlEvidenceCacheError {
            XCTAssertEqual(error, .resourceAdmission)
        }

        var counters = await authority.snapshotForTesting()
        var monitorState = await monitor.snapshotForTesting()
        var collectionCount = await gate.collectionCount()
        XCTAssertEqual(collectionCount, 1)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 512)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)

        await gate.release()
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 0 }
        counters = await authority.snapshotForTesting()
        monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.pendingPrefixControlArtifactBytes, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)

        let retry = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { try await gate.collect() }
        XCTAssertEqual(retry, prefixFooter())
        counters = await authority.snapshotForTesting()
        monitorState = await monitor.snapshotForTesting()
        collectionCount = await gate.collectionCount()
        XCTAssertEqual(collectionCount, 2)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 0)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)
    }

    func testAcceptedWatermarkInvalidatesCachedFooterBeforeActorDelivery() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let counter = PrefixControlCollectorCounter(footer: prefixFooter())
        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        await monitor.acceptEventWithoutDeliveryForTesting(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout)
        )
        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        let collectionCount = await counter.collectionCount()
        XCTAssertEqual(collectionCount, 2)
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)
        XCTAssertGreaterThanOrEqual(counters.prefixControlCacheInvalidationCount, 1)
    }

    func testCorruptFooterAndResidentBudgetNeverRetainAdmissionOrArtifacts() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let corruptAuthority = GitWorkspaceStateAuthority()
        let corrupt = GitPrefixControlEvidenceManifestFooter(
            recordCount: 0,
            recordPayloadByteCount: 0,
            pathPayloadByteCount: 0,
            ignoreControlDigest: Data(),
            attributeControlDigest: Data(repeating: 1, count: 32),
            artifactDigest: Data(repeating: 2, count: 32)
        )
        do {
            _ = try await corruptAuthority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                cacheMode: .automatic
            ) { corrupt }
            XCTFail("Expected corrupt footer rejection")
        } catch let error as GitPrefixControlEvidenceCacheError {
            XCTAssertEqual(error, .corruptFooter)
        }
        var snapshot = await corruptAuthority.snapshotForTesting()
        XCTAssertEqual(snapshot.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(snapshot.pendingPrefixControlAdmissionCount, 0)
        XCTAssertEqual(snapshot.prefixControlCacheArtifactBytes, 0)

        let bounded = GitWorkspaceStateAuthority(prefixControlCacheLimits: .init(
            maximumEntryCount: 1,
            maximumEntriesPerRepository: 1,
            maximumResidentBytes: 1,
            maximumArtifactBytes: 0,
            maximumPendingAdmissionCount: 1,
            maximumPendingResidentBytes: 512,
            maximumPendingArtifactBytes: 0
        ))
        let counter = PrefixControlCollectorCounter(footer: prefixFooter())
        for _ in 0 ..< 2 {
            _ = try await bounded.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                cacheMode: .automatic
            ) { await counter.collect() }
        }
        snapshot = await bounded.snapshotForTesting()
        let boundedCollectionCount = await counter.collectionCount()
        XCTAssertEqual(boundedCollectionCount, 2)
        XCTAssertEqual(snapshot.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(snapshot.prefixControlCacheResidentBytes, 0)
        XCTAssertEqual(snapshot.prefixControlCacheArtifactBytes, 0)
        XCTAssertEqual(snapshot.pendingPrefixControlAdmissionCount, 0)
        XCTAssertEqual(snapshot.prefixControlCacheEvictionCount, 2)
    }

    func testMonitorUnavailableFallsBackWithoutAdmissionAndTypedMatcherFailsClosed() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor(maximumPathsPerRepository: 1)
        let key = GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout)
        let retained = try await monitor.retain(
            repositoryKey: key,
            paths: [fixture.layout.gitDir.appendingPathComponent("HEAD")]
        ) { _ in }
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let counter = PrefixControlCollectorCounter(footer: prefixFooter())
        for _ in 0 ..< 2 {
            _ = try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix("Sources"),
                cacheMode: .automatic
            ) { await counter.collect() }
        }
        let snapshot = await authority.snapshotForTesting()
        let collectionCount = await counter.collectionCount()
        XCTAssertEqual(collectionCount, 2)
        XCTAssertEqual(snapshot.prefixControlCacheEntryCount, 0)

        let prefix = try GitRepositoryRelativeRootPrefix("Sources/Nested")
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let directoryCreateFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated
        )
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent(".gitignore").path,
            flags: fileFlag
        ))
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent("Sources/Nested/NewDirectory").path,
            flags: directoryCreateFlags
        ))
        XCTAssertFalse(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent(".git/objects/.gitignore").path,
            flags: fileFlag
        ))
        XCTAssertFalse(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent("Sources/ordinary.swift").path,
            flags: fileFlag
        ))
        await monitor.release(retained)
    }

    func testLazyPrefixCollectorCrossesLegacyTenThousandBoundaryAndFindsLateControl() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let late = fixture.root.appendingPathComponent("late/.gitignore")
        try FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "late-control\n".write(to: late, atomically: true, encoding: .utf8)

        let beyondLimit = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: 10001, lateControl: late)
        let baseline = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: 0, lateControl: late)
        let streamed = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            candidateSource: beyondLimit
        )
        let expected = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            candidateSource: baseline
        )

        XCTAssertEqual(streamed.recordCount, 1)
        XCTAssertEqual(streamed.ignoreControlDigest, expected.ignoreControlDigest)
        XCTAssertEqual(streamed.attributeControlDigest, expected.attributeControlDigest)
        XCTAssertEqual(beyondLimit.emittedNoiseCount, 10001)
    }

    func testRepositoryUnderDotGitNamedAncestorStillEnumeratesDescendantControls() async throws {
        let fixture = try AuthorityEvidenceFixture(rootAncestorComponents: [".git", "ancestor"])
        defer { fixture.cleanup() }
        let control = fixture.root.appendingPathComponent("Sources/.gitignore")
        try FileManager.default.createDirectory(
            at: control.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "*.generated\n".write(to: control, atomically: true, encoding: .utf8)

        let evidence = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix("")
        )

        XCTAssertEqual(evidence.recordCount, 1)
        XCTAssertGreaterThan(evidence.pathPayloadByteCount, 0)
    }

    func testPrefixControlReaderSerializesConcurrentConsumers() async throws {
        let store = try GitPrefixControlEvidenceManifestStore()
        let writer = try store.makeWriter(rootPrefixBytes: Data())
        let recordCount = 64
        for index in 0 ..< recordCount {
            try await writer.append(GitPrefixControlEvidenceRecord(
                repositoryRelativePathBytes: Data(String(format: "controls/%03d/.gitignore", index).utf8),
                kind: .gitignore,
                content: GitWorkspaceAuthorityContentIdentity(
                    exists: true,
                    sha256: String(repeating: "a", count: 64),
                    byteCount: index
                )
            ))
        }
        var lease: GitPrefixControlEvidenceManifestLease? = try await writer.finish()
        let paths: [Data]
        let validationState: GitPrefixControlEvidenceReaderValidationState
        do {
            let reader = try XCTUnwrap(lease).makeReader()
            paths = try await withThrowingTaskGroup(of: Data?.self) { group in
                for _ in 0 ... recordCount {
                    group.addTask { try await reader.next()?.repositoryRelativePathBytes }
                }
                var values: [Data] = []
                for try await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            validationState = await reader.validationState
        }

        XCTAssertEqual(paths.count, recordCount)
        XCTAssertEqual(Set(paths).count, recordCount)
        XCTAssertEqual(validationState, .verified)
        lease = nil
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
    }

    func testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded() async throws {
        try await exerciseLargeLogicalStream(recordCount: 100_000)
    }

    func testMillionLogicalCandidatesAndTreeRecordsStayByteBoundedWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RPCE_RUN_MILLION_RECORD_GIT_AUTHORITY_TESTS"] == "1",
            "Set RPCE_RUN_MILLION_RECORD_GIT_AUTHORITY_TESTS=1 for the required slow lane"
        )
        try await exerciseLargeLogicalStream(recordCount: 1_000_000)
    }

    func testCorruptionCancellationAndResourceFailureCleanArtifacts() async throws {
        let header = try inventoryHeader()

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let writer = try store.makeWriter(header: header)
            try await writer.append(inventoryRecord(path: "A.swift"))
            var lease: WorkspaceRootReusableInventoryManifestLease? = try await writer.finish()
            let handle = try FileHandle(forWritingTo: XCTUnwrap(lease).fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x7F]))
            try handle.close()
            XCTAssertThrowsError(try lease?.makeReader())
            lease = nil
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        }

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let policy = WorkspaceRootReusableInventoryResourcePolicy(
                maximumBufferedRecordBytes: 512,
                maximumRecordsPerBatch: 2,
                maximumRecordByteCount: 1024,
                maximumOpenRuns: 2,
                minimumFreeDiskBytes: 0,
                maximumAggregateArtifactBytes: 64 * 1024 * 1024
            )
            let writer = try store.makeWriter(header: header, resourcePolicy: policy)
            for index in 0 ..< 8 {
                try await writer.append(inventoryRecord(path: String(format: "cancel-%07d.swift", index)))
            }
            XCTAssertTrue(containsSpillRun(in: store.directoryURL), "cancellation must begin after a spill run exists")
            let task = Task {
                for index in 8 ..< 1_000_000 {
                    try await writer.append(self.inventoryRecord(path: String(format: "cancel-%07d.swift", index)))
                    await Task.yield()
                }
            }
            await Task.yield()
            task.cancel()
            do {
                try await task.value
                XCTFail("Expected deterministic cancellation")
            } catch is CancellationError {}
            await writer.cancel()
            try store.cleanup()
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
        }

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let policy = WorkspaceRootReusableInventoryResourcePolicy(
                maximumBufferedRecordBytes: 256,
                maximumRecordsPerBatch: 2,
                maximumRecordByteCount: 1024,
                maximumOpenRuns: 2,
                minimumFreeDiskBytes: 0,
                maximumAggregateArtifactBytes: 512
            )
            let writer = try store.makeWriter(header: header, resourcePolicy: policy)
            do {
                for index in 0 ..< 32 {
                    try await writer.append(inventoryRecord(path: "resource-\(index).swift"))
                }
                _ = try await writer.finish()
                XCTFail("Expected aggregate byte admission failure")
            } catch let error as WorkspaceRootReusableInventoryManifestError {
                XCTAssertEqual(error, .resourceAdmission)
            }
            await writer.cancel()
            try store.cleanup()
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        }
    }

    func testArtifactBudgetIncludesPendingReservationsAndFailsClosed() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let sourceAuthority = GitWorkspaceStateAuthority()
        let sourceCoordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: sourceAuthority),
            authority: sourceAuthority
        )
        guard case .admitted = await sourceCoordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: ["A.swift"]
        ) else { return XCTFail("Expected source snapshot admission") }
        let sourceLease: GitWorkspaceAuthorityLease
        switch try await sourceAuthority.currentLease(
            for: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout),
            prefix: GitRepositoryRelativeRootPrefix("")
        ) {
        case let .success(value): sourceLease = value
        case let .failure(reason): return XCTFail("Missing source authority: \(reason)")
        }
        let currentReusable = await sourceAuthority.currentReusableSnapshot(capturedUsing: sourceLease)
        let reusable = try XCTUnwrap(currentReusable)
        let artifactBytes = reusable.artifactByteCount
        XCTAssertGreaterThan(artifactBytes, 0)

        let authority = GitWorkspaceStateAuthority(
            reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits(
                maximumSnapshotCount: 4,
                maximumSnapshotsPerRepository: 4,
                maximumEstimatedBytes: 8 * 1024 * 1024,
                maximumArtifactBytes: artifactBytes
            )
        )
        let lease = try await authority.install(sourceLease.snapshot)
        let firstObservation = try await authority.retainMetadataObservation(for: fixture.layout)
        let preparedFirst = await authority.prepareReusableSnapshotAdmission(
            reusable,
            capturedUsing: lease,
            observationToken: firstObservation
        )
        let first = try XCTUnwrap(preparedFirst)
        var counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 1)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, 0)
        XCTAssertEqual(counters.reusableSnapshotArtifactBudgetRejectionCount, 0)

        let rejectedObservation = try await authority.retainMetadataObservation(for: fixture.layout)
        let rejected = await authority.prepareReusableSnapshotAdmission(
            reusable,
            capturedUsing: lease,
            observationToken: rejectedObservation
        )
        XCTAssertNil(rejected)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 1)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertEqual(counters.reusableSnapshotArtifactBudgetRejectionCount, 1)

        let admittedReceipt = await authority.admitPreparedReusableSnapshot(first)
        let receipt = try XCTUnwrap(admittedReceipt)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 0)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, 0)
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertLessThanOrEqual(counters.reusableSnapshotArtifactBytes, artifactBytes)
        await authority.revokeReusableSnapshotAdmission(receipt)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, 0)
    }

    private func prefixFooter() -> GitPrefixControlEvidenceManifestFooter {
        GitPrefixControlEvidenceManifestFooter(
            recordCount: 1,
            recordPayloadByteCount: 32,
            pathPayloadByteCount: 10,
            ignoreControlDigest: Data(repeating: 1, count: 32),
            attributeControlDigest: Data(repeating: 2, count: 32),
            artifactDigest: Data(repeating: 3, count: 32)
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () async -> Bool
    ) async throws {
        for _ in 0 ..< 1000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic cache state", file: file, line: line)
    }

    func testStaleCatalogBatchFailsClosedAndLeavesNoReusableAdmission() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let result = await coordinator.observeStreamedAuthoritativeFullLoad(
            rootURL: fixture.root,
            catalogBatchEvidenceProvider: { _ in .stale(.loadedRootWatcherStale) }
        )
        XCTAssertEqual(
            result,
            .failed(.init(stage: .catalogClassification, cause: .loadedRootWatcherStale))
        )
        let snapshot = await authority.snapshotForTesting()
        XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
        XCTAssertEqual(snapshot.reusableSnapshotAliasCount, 0)
        XCTAssertEqual(snapshot.reusableSnapshotEstimatedBytes, 0)
        XCTAssertEqual(snapshot.reusableSnapshotArtifactBytes, 0)
    }

    private func exerciseLargeLogicalStream(recordCount: Int) async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let late = fixture.root.appendingPathComponent("late/.gitattributes")
        try FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "*.swift text\n".write(to: late, atomically: true, encoding: .utf8)
        let source = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: recordCount, lateControl: late)
        let controls = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            candidateSource: source
        )
        XCTAssertEqual(source.emittedNoiseCount, recordCount)
        XCTAssertEqual(controls.recordCount, 1)

        let store = try WorkspaceRootReusableInventoryManifestStore()
        let policy = WorkspaceRootReusableInventoryResourcePolicy(
            maximumBufferedRecordBytes: 1024 * 1024,
            maximumRecordsPerBatch: 4096,
            maximumRecordByteCount: 1024 * 1024,
            maximumOpenRuns: 4,
            minimumFreeDiskBytes: 0,
            maximumAggregateArtifactBytes: 4 * 1024 * 1024 * 1024
        )
        let writer = try store.makeWriter(header: inventoryHeader(), resourcePolicy: policy)
        let oid = String(repeating: "1", count: 40)
        var parser = try GitLoadedRootTreeInventoryStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("")
        ) { record in
            guard let mode = String(data: record.modeBytes, encoding: .utf8),
                  let oidString = String(data: record.objectIDBytes, encoding: .utf8)
            else { throw GitWorktreeInitializationError.malformedOutput("test metadata") }
            try await writer.append(WorkspaceRootReusableInventoryManifestRecord(
                rootRelativePathBytes: record.repositoryRelativePathBytes,
                mode: mode,
                kind: record.kind,
                objectID: GitObjectID(objectFormat: .sha1, lowercaseHex: oidString),
                catalogProjection: .searchableRegularFile
            ))
        }
        for index in 0 ..< recordCount {
            let path = String(format: "f%07d.swift", index)
            let frame = Data("100644 blob \(oid)\t\(path)\0".utf8)
            if index == 0 {
                for byte in frame {
                    try await parser.consume(Data([byte]))
                }
            } else {
                try await parser.consume(frame)
            }
        }
        try await parser.finish()
        var lease: WorkspaceRootReusableInventoryManifestLease? = try await writer.finish()
        var observed = 0
        do {
            let completed = try XCTUnwrap(lease)
            XCTAssertEqual(completed.footer.totalRecordCount, UInt64(recordCount))
            XCTAssertEqual(completed.footer.searchableRegularFileCount, UInt64(recordCount))
            XCTAssertGreaterThan(completed.statistics.initialRunCount, policy.maximumOpenRuns)
            XCTAssertGreaterThan(completed.statistics.mergePassCount, 1)
            XCTAssertLessThanOrEqual(completed.statistics.peakBufferedRecordBytes, policy.maximumBufferedRecordBytes)
            XCTAssertLessThanOrEqual(completed.statistics.peakResidentScheduledRunCount, policy.maximumOpenRuns)
            XCTAssertLessThanOrEqual(completed.artifactByteCount, policy.maximumAggregateArtifactBytes ?? .max)
            XCTAssertGreaterThanOrEqual(completed.statistics.peakWorkspaceByteCount, completed.artifactByteCount)
            XCTAssertGreaterThanOrEqual(
                completed.statistics.peakAggregateArtifactByteCount,
                completed.statistics.peakWorkspaceByteCount
            )
            XCTAssertLessThanOrEqual(
                completed.statistics.peakWorkspaceByteCount,
                policy.maximumAggregateArtifactBytes ?? .max
            )
            XCTAssertLessThanOrEqual(
                completed.statistics.peakAggregateArtifactByteCount,
                policy.maximumAggregateArtifactBytes ?? .max
            )
            let reader = try completed.makeReader()
            while try reader.next() != nil {
                observed += 1
            }
            XCTAssertEqual(reader.validationState, .verified)
        }
        XCTAssertEqual(observed, recordCount)
        lease = nil
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
    }

    private func containsSpillRun(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix("run.") { return true }
        }
        return false
    }

    private func inventoryHeader() throws -> WorkspaceRootReusableInventoryManifestHeader {
        let oid = try GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "2", count: 40))
        return try WorkspaceRootReusableInventoryManifestHeader(
            compatibilityDomain: WorkspaceRootReusableSnapshot.manifestCompatibilityDomain,
            compatibilityDigest: Data(repeating: 3, count: 32),
            treeOID: oid,
            objectFormat: .sha1,
            repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""),
            commandFormat: GitLoadedRootTreeInventorySpool.commandFormat,
            rawStandardOutputDigest: Data(repeating: 4, count: 32),
            catalogPolicyDigest: Data(repeating: 5, count: 32)
        )
    }

    private func inventoryRecord(path: String) throws -> WorkspaceRootReusableInventoryManifestRecord {
        try WorkspaceRootReusableInventoryManifestRecord(
            rootRelativePath: path,
            mode: "100644",
            kind: .blob,
            objectID: GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "1", count: 40)),
            catalogProjection: .searchableRegularFile
        )
    }
}

private actor PrefixControlCollectorGate {
    private let footer: GitPrefixControlEvidenceManifestFooter
    private var continuation: CheckedContinuation<Void, Never>?
    private var collectionStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var count = 0

    init(footer: GitPrefixControlEvidenceManifestFooter) {
        self.footer = footer
    }

    func collect() async throws -> GitPrefixControlEvidenceManifestFooter {
        count += 1
        let waiters = collectionStartWaiters
        collectionStartWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        try Task.checkCancellation()
        return footer
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func collectionCount() -> Int {
        count
    }

    func waitUntilCollectionStarts() async {
        if count > 0 { return }
        await withCheckedContinuation { collectionStartWaiters.append($0) }
    }
}

private actor PrefixControlCollectorCounter {
    private let footer: GitPrefixControlEvidenceManifestFooter
    private var count = 0

    init(footer: GitPrefixControlEvidenceManifestFooter) {
        self.footer = footer
    }

    func collect() -> GitPrefixControlEvidenceManifestFooter {
        count += 1
        return footer
    }

    func collectionCount() -> Int {
        count
    }
}

private final class LazyPrefixCandidateSource: GitPrefixControlCandidateSource {
    private let root: URL
    private let logicalNoiseCount: Int
    private let lateControl: URL
    private var index = 0
    private(set) var emittedNoiseCount = 0

    init(root: URL, logicalNoiseCount: Int, lateControl: URL) {
        self.root = root
        self.logicalNoiseCount = logicalNoiseCount
        self.lateControl = lateControl
    }

    func nextCandidate() throws -> URL? {
        if index < logicalNoiseCount {
            defer { index += 1
                emittedNoiseCount += 1
            }
            return root.appendingPathComponent("logical-noise-\(index)")
        }
        if index == logicalNoiseCount {
            index += 1
            return lateControl
        }
        return nil
    }

    func skipDescendants() {}
}

private final class AuthorityEvidenceFixture {
    let root: URL
    let layout: GitRepositoryLayout
    private let cleanupRoot: URL

    init(makeCommit: Bool = false, rootAncestorComponents: [String] = []) throws {
        let cleanupRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rpce-loaded-root-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        self.cleanupRoot = cleanupRoot
        root = rootAncestorComponents.reduce(cleanupRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.git(["init", "-q"], at: root)
        try Self.git(["config", "user.email", "tests@example.invalid"], at: root)
        try Self.git(["config", "user.name", "RepoPrompt Tests"], at: root)
        if makeCommit {
            try "let value = 1\n".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            try Self.git(["add", "A.swift"], at: root)
            try Self.git(["commit", "-q", "-m", "fixture"], at: root)
        }
        layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: root))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: cleanupRoot)
    }

    private static func git(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitLoadedRootAuthorityEvidenceTests", code: Int(process.terminationStatus))
        }
    }
}
