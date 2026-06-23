import Foundation

struct CodeMapArtifactStorePolicy: Equatable {
    static let `default` = CodeMapArtifactStorePolicy()

    let residentPositiveEntryLimit: Int
    let residentPositiveByteLimit: UInt64
    let residentNegativeEntryLimit: Int
    let residentNegativeByteLimit: UInt64
    let softQuotaBytes: UInt64
    let hardQuotaBytes: UInt64
    let unreferencedGraceSeconds: UInt64
    let quarantineDelaySeconds: UInt64
    let negativeQuotaBytes: UInt64
    let negativeMaximumAgeSeconds: UInt64
    let maximumCatalogRecordCount: Int
    let maximumCatalogScanByteCount: Int
    let maximumArtifactScanCount: Int
    let maximumArtifactReconciliationByteCount: UInt64
    let maximumMaintenanceWriteByteCount: UInt64
    let maximumQuarantineEpochCount: Int
    let maximumMetadataRecordByteCount: Int
    let maximumGCStepBudget: Int
    let containerPolicy: CodeMapArtifactContainerPolicy

    init(
        residentPositiveEntryLimit: Int = 512,
        residentPositiveByteLimit: UInt64 = 64 * 1024 * 1024,
        residentNegativeEntryLimit: Int = 1024,
        residentNegativeByteLimit: UInt64 = 4 * 1024 * 1024,
        softQuotaBytes: UInt64 = 2 * 1024 * 1024 * 1024,
        hardQuotaBytes: UInt64 = 3 * 1024 * 1024 * 1024,
        unreferencedGraceSeconds: UInt64 = 30 * 24 * 60 * 60,
        quarantineDelaySeconds: UInt64 = 24 * 60 * 60,
        negativeQuotaBytes: UInt64 = 64 * 1024 * 1024,
        negativeMaximumAgeSeconds: UInt64 = 30 * 24 * 60 * 60,
        maximumCatalogRecordCount: Int = 65536,
        maximumCatalogScanByteCount: Int = 64 * 1024 * 1024,
        maximumArtifactScanCount: Int = 65536,
        maximumArtifactReconciliationByteCount: UInt64 = 128 * 1024 * 1024,
        maximumMaintenanceWriteByteCount: UInt64 = 8 * 1024 * 1024,
        maximumQuarantineEpochCount: Int = 4096,
        maximumMetadataRecordByteCount: Int = 64 * 1024,
        maximumGCStepBudget: Int = 4096,
        containerPolicy: CodeMapArtifactContainerPolicy = .default
    ) {
        precondition(residentPositiveEntryLimit >= 0)
        precondition(residentNegativeEntryLimit >= 0)
        precondition(softQuotaBytes <= hardQuotaBytes)
        precondition(maximumCatalogRecordCount > 0)
        precondition(maximumCatalogScanByteCount > 0)
        precondition(maximumArtifactScanCount > 0)
        precondition(maximumArtifactReconciliationByteCount > 0)
        precondition(maximumMaintenanceWriteByteCount > 0)
        precondition(maximumQuarantineEpochCount > 0)
        precondition(maximumMetadataRecordByteCount > 0)
        precondition(maximumMaintenanceWriteByteCount >= UInt64(maximumMetadataRecordByteCount) * 2)
        precondition(maximumGCStepBudget > 0)
        self.residentPositiveEntryLimit = residentPositiveEntryLimit
        self.residentPositiveByteLimit = residentPositiveByteLimit
        self.residentNegativeEntryLimit = residentNegativeEntryLimit
        self.residentNegativeByteLimit = residentNegativeByteLimit
        self.softQuotaBytes = softQuotaBytes
        self.hardQuotaBytes = hardQuotaBytes
        self.unreferencedGraceSeconds = unreferencedGraceSeconds
        self.quarantineDelaySeconds = quarantineDelaySeconds
        self.negativeQuotaBytes = negativeQuotaBytes
        self.negativeMaximumAgeSeconds = negativeMaximumAgeSeconds
        self.maximumCatalogRecordCount = maximumCatalogRecordCount
        self.maximumCatalogScanByteCount = maximumCatalogScanByteCount
        self.maximumArtifactScanCount = maximumArtifactScanCount
        self.maximumArtifactReconciliationByteCount = maximumArtifactReconciliationByteCount
        self.maximumMaintenanceWriteByteCount = maximumMaintenanceWriteByteCount
        self.maximumQuarantineEpochCount = maximumQuarantineEpochCount
        self.maximumMetadataRecordByteCount = maximumMetadataRecordByteCount
        self.maximumGCStepBudget = maximumGCStepBudget
        self.containerPolicy = containerPolicy
    }
}

struct CodeMapArtifactStoreClock: @unchecked Sendable {
    private let nowProvider: @Sendable () -> UInt64

    static let system = CodeMapArtifactStoreClock {
        UInt64(max(0, Date().timeIntervalSince1970))
    }

    init(now: @escaping @Sendable () -> UInt64) {
        nowProvider = now
    }

    func nowEpochSeconds() -> UInt64 {
        nowProvider()
    }
}

enum CodeMapArtifactHitSource: Equatable {
    case memory
    case disk
}

final class CodeMapArtifactHandle: @unchecked Sendable {
    let key: CodeMapArtifactKey
    let outcome: CodeMapSyntaxArtifactOutcome
    let payloadByteCount: UInt64
    let containerByteCount: UInt64
    let estimatedResidentByteCount: UInt64

    fileprivate init(key: CodeMapArtifactKey, verified: CodeMapArtifactVerifiedFile) {
        self.key = key
        outcome = verified.outcome
        payloadByteCount = UInt64(verified.payloadByteCount)
        containerByteCount = UInt64(verified.containerByteCount)
        estimatedResidentByteCount = UInt64(verified.containerByteCount)
    }
}

enum CodeMapArtifactLookupResult: @unchecked Sendable {
    case miss
    case hit(source: CodeMapArtifactHitSource, handle: CodeMapArtifactHandle)
}

enum CodeMapArtifactInsertResult: Equatable {
    case inserted
    case alreadyPresent
}

struct CodeMapArtifactStoreAccounting: Equatable {
    let livePositiveCount: Int
    let livePositiveBytes: UInt64
    let liveNegativeCount: Int
    let liveNegativeBytes: UInt64
    let quarantinedCount: Int
    let quarantinedBytes: UInt64
    let residentPositiveCount: Int
    let residentPositiveBytes: UInt64
    let residentNegativeCount: Int
    let residentNegativeBytes: UInt64
    let activeLeaseCount: Int
    let pendingAccessTouchCount: Int
    let corruptMetadataCount: Int
    let corruptPayloadCount: Int
    let missingPayloadCount: Int
    let repairedOrphanArtifactCount: Int
    let observedOrphanArtifactCount: Int
    let ignoredTemporaryCount: Int
    let removedTemporaryCount: Int
    let retainedPrivateDeletionCount: Int
    let retainedPrivateDeletionBytes: UInt64
    let recoveredPrivateDeletionCount: Int
    let recoveredPrivateDeletionBytes: UInt64
    let quarantineOrphanCount: Int
    let liveReconciliationComplete: Bool
    let quarantineInventoryComplete: Bool
}

enum CodeMapArtifactGCPhase: String, Equatable {
    case flushTouches
    case reconcileCatalog
    case reconcileArtifacts
    case reconcileMissingMetadata
    case reconcileCleanup
    case select
    case quarantine
    case quarantineCatalog
    case selectSweep
    case quarantineArtifacts
    case repairQuarantine
    case sweep
}

struct CodeMapArtifactGCContinuation: Equatable {
    let cycle: UInt64
    let phase: CodeMapArtifactGCPhase
    let nextOffset: Int
}

struct CodeMapArtifactGCProgress: Equatable {
    let cycle: UInt64
    let examinedCount: Int
    let quarantinedCount: Int
    let quarantinedBytes: UInt64
    let sweptCount: Int
    let sweptBytes: UInt64
    let leasedSkipCount: Int
    let changedSkipCount: Int
    let visitedEntryCount: Int
    let readByteCount: UInt64
    let writtenByteCount: UInt64
    let selectionCount: Int
    let repairedCount: Int
    let tombstoneCount: Int
    let sweptDigests: [String]
    let continuation: CodeMapArtifactGCContinuation?

    var isComplete: Bool {
        continuation == nil
    }
}

struct CodeMapArtifactStoreMaintenanceIndexAccounting: Equatable {
    let recordOrderCount: Int
    let recordSetCount: Int
    let mutationGenerationCount: Int
}

struct CodeMapArtifactReconciliationProgress: Equatable {
    let accounting: CodeMapArtifactStoreAccounting
    let visitedEntryCount: Int
    let readByteCount: UInt64
    let writtenByteCount: UInt64
    let repairedCount: Int
    let continuation: CodeMapArtifactGCContinuation?

    var isComplete: Bool {
        continuation == nil
    }
}

final class CodeMapArtifactLease: @unchecked Sendable {
    private struct State {
        var diskLease: CodeMapArtifactDiskLease?
        var store: CodeMapArtifactStore?
        var token: UUID?
        var key: CodeMapArtifactKey?
    }

    let handle: CodeMapArtifactHandle
    private let lock = NSLock()
    private var state: State

    fileprivate init(
        handle: CodeMapArtifactHandle,
        diskLease: CodeMapArtifactDiskLease,
        store: CodeMapArtifactStore,
        token: UUID
    ) {
        self.handle = handle
        state = State(diskLease: diskLease, store: store, token: token, key: handle.key)
    }

    func close() async {
        let claimed = claim()
        guard let claimed else { return }
        await claimed.store.releaseLease(token: claimed.token, key: claimed.key)
        claimed.diskLease.close()
    }

    deinit {
        guard let claimed = claim() else { return }
        claimed.diskLease.close()
        Task { await claimed.store.releaseLease(token: claimed.token, key: claimed.key) }
    }

    private func claim() -> (
        diskLease: CodeMapArtifactDiskLease,
        store: CodeMapArtifactStore,
        token: UUID,
        key: CodeMapArtifactKey
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard let diskLease = state.diskLease,
              let store = state.store,
              let token = state.token,
              let key = state.key
        else { return nil }
        state = State()
        return (diskLease, store, token, key)
    }
}

actor CodeMapArtifactStore {
    private struct ResidentEntry {
        let handle: CodeMapArtifactHandle
        var accessSequence: UInt64
    }

    private struct ReconciliationDiagnostics {
        var scan = CodeMapArtifactCatalogScanDiagnostics()
        var missingPayloadCount = 0
        var corruptPayloadCount = 0
        var repairedOrphanArtifactCount = 0
    }

    private struct ReconciliationState {
        var catalogScan: CodeMapArtifactCatalogScanSession?
        var artifactScan: CodeMapArtifactCatalogScanSession?
        var candidates: [String: CodeMapArtifactCatalogRecord] = [:]
        var candidateOrder: [String] = []
        var unmatchedOffset = 0
        var cleanupOffset = 0
        var cleanupLimit = 0
        var seenDigests: Set<String> = []
        var selectionOrder: [String] = []
        var compactedOrder: [String] = []
        var compactedSet: Set<String> = []
        var compactedMutationGenerations: [String: UInt64] = [:]
        let startMutationGeneration: UInt64
    }

    private struct RecordHeap {
        var values: [CodeMapArtifactCatalogRecord] = []

        var minimum: CodeMapArtifactCatalogRecord? {
            values.first
        }

        mutating func insert(_ record: CodeMapArtifactCatalogRecord) {
            values.append(record)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard CodeMapArtifactStore.gcOrder(values[index], values[parent]) else { break }
                values.swapAt(index, parent)
                index = parent
            }
        }

        mutating func popMinimum() -> CodeMapArtifactCatalogRecord? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let result = values[0]
            values[0] = values.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < values.count else { break }
                let right = left + 1
                var child = left
                if right < values.count, CodeMapArtifactStore.gcOrder(values[right], values[left]) {
                    child = right
                }
                guard CodeMapArtifactStore.gcOrder(values[child], values[index]) else { break }
                values.swapAt(child, index)
                index = child
            }
            return result
        }
    }

    private struct PendingSweep {
        let candidate: CodeMapArtifactQuarantineCandidate
        let metadataByteCount: UInt64
    }

    private struct PendingQuarantineRepair {
        let epochSeconds: UInt64
        let shard: String
        let artifactName: String
        let byteCount: UInt64
    }

    private struct SweepHeap {
        var values: [PendingSweep] = []

        var minimum: PendingSweep? {
            values.first
        }

        mutating func insert(_ value: PendingSweep) {
            values.append(value)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard Self.less(values[index], values[parent]) else { break }
                values.swapAt(index, parent)
                index = parent
            }
        }

        mutating func popMinimum() -> PendingSweep? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let result = values[0]
            values[0] = values.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < values.count else { break }
                let right = left + 1
                var child = left
                if right < values.count, Self.less(values[right], values[left]) { child = right }
                guard Self.less(values[child], values[index]) else { break }
                values.swapAt(child, index)
                index = child
            }
            return result
        }

        private static func less(_ lhs: PendingSweep, _ rhs: PendingSweep) -> Bool {
            let left = lhs.candidate.tombstone
            let right = rhs.candidate.tombstone
            return (left.epochSeconds, left.digest, left.token) <
                (right.epochSeconds, right.digest, right.token)
        }
    }

    private struct MaintenanceCycle {
        let id: UInt64
        let now: UInt64
        var collect: Bool
        var phase: CodeMapArtifactGCPhase = .flushTouches
        var reconciliation: ReconciliationState
        var selectionOffset = 0
        var selectionLimit = 0
        var heap = RecordHeap()
        var quarantineCatalogScan: CodeMapArtifactCatalogScanSession?
        var quarantineArtifactScan: CodeMapArtifactCatalogScanSession?
        var expectedQuarantineArtifacts: Set<String> = []
        var quarantineCount = 0
        var quarantineBytes: UInt64 = 0
        var recoveredQuarantineOrphanCount = 0
        var pendingSweepSelection: PendingSweep?
        var sweepHeap = SweepHeap()
        var presentQuarantineArtifacts: Set<String> = []
        var quarantineArtifactBytes: [String: UInt64] = [:]
        var pendingRepair: PendingQuarantineRepair?
        var retainedLivePrivateDeletionCount = 0
        var retainedLivePrivateDeletionBytes: UInt64 = 0
        var retainedQuarantinePrivateDeletionCount = 0
        var retainedQuarantinePrivateDeletionBytes: UInt64 = 0
        var workSequence = 0
    }

    private struct CallProgress {
        var examined = 0
        var quarantined = 0
        var quarantinedBytes: UInt64 = 0
        var swept = 0
        var sweptBytes: UInt64 = 0
        var leased = 0
        var changed = 0
        var visited = 0
        var readBytes: UInt64 = 0
        var writtenBytes: UInt64 = 0
        var selected = 0
        var repaired = 0
        var tombstones = 0
        var sweptDigests: [String] = []
    }

    private struct MaintenanceIOMetrics {
        var additionalReadByteCount: UInt64 = 0
        var metadataReadByteCount: UInt64 = 0
        var writtenByteCount: UInt64 = 0
        var failed = false
    }

    private let policy: CodeMapArtifactStorePolicy
    private let clock: CodeMapArtifactStoreClock
    private let fileStore: CodeMapArtifactFileStore
    private let catalog: CodeMapArtifactCatalog
    private var records: [String: CodeMapArtifactCatalogRecord] = [:]
    private var recordOrder: [String] = []
    private var recordOrderSet: Set<String> = []
    private var residentPositive: [String: ResidentEntry] = [:]
    private var residentNegative: [String: ResidentEntry] = [:]
    private var pendingTouchSet: Set<String> = []
    private var pendingTouchOrder: [String] = []
    private var pendingTouchOffset = 0
    private var activeLeaseTokens: [UUID: String] = [:]
    private var leaseCountByDigest: [String: Int] = [:]
    private var nextAccessSequence: UInt64 = 1
    private var nextMaintenanceCycle: UInt64 = 1
    private var maintenanceCycle: MaintenanceCycle?
    private var reconciliation = ReconciliationDiagnostics()
    private var mutationGeneration: UInt64 = 1
    private var mutationGenerationByDigest: [String: UInt64] = [:]
    private var livePositiveCount = 0
    private var livePositiveBytes: UInt64 = 0
    private var liveNegativeCount = 0
    private var liveNegativeBytes: UInt64 = 0
    private var liveReconciliationComplete = false
    private var quarantineInventoryComplete = false
    private var retainedLivePrivateDeletionCount = 0
    private var retainedLivePrivateDeletionBytes: UInt64 = 0
    private var retainedQuarantinePrivateDeletionCount = 0
    private var retainedQuarantinePrivateDeletionBytes: UInt64 = 0

    private var compoundMetadataWriteReservation: UInt64 {
        UInt64(policy.maximumMetadataRecordByteCount) * 2
    }

    private var compoundMetadataReadReservation: UInt64 {
        UInt64(policy.maximumMetadataRecordByteCount) * 2
    }

    init(
        rootURL: URL,
        policy: CodeMapArtifactStorePolicy = .default,
        clock: CodeMapArtifactStoreClock = .system,
        removalHooks: CodeMapSecureFileRemovalHooks? = nil
    ) throws {
        self.policy = policy
        self.clock = clock
        fileStore = try CodeMapArtifactFileStore(
            rootURL: rootURL,
            containerPolicy: policy.containerPolicy,
            removalHooks: removalHooks
        )
        catalog = try CodeMapArtifactCatalog(rootURL: rootURL, policy: policy, removalHooks: removalHooks)
    }

    func lookup(key: CodeMapArtifactKey) throws -> CodeMapArtifactLookupResult {
        let digest = key.storageDigestHex
        if var entry = residentPositive[digest] {
            touch(digest: digest)
            entry.accessSequence = currentSequence(for: digest)
            residentPositive[digest] = entry
            return .hit(source: .memory, handle: entry.handle)
        }
        if var entry = residentNegative[digest] {
            touch(digest: digest)
            entry.accessSequence = currentSequence(for: digest)
            residentNegative[digest] = entry
            return .hit(source: .memory, handle: entry.handle)
        }

        let now = clock.nowEpochSeconds()
        switch try fileStore.readVerified(key: key, quarantineCorruption: false) {
        case .corrupt:
            switch try catalog.liveRecord(key: key, quarantineCorruptionAt: now) {
            case let .record(record):
                if try catalog.quarantineCorruptPayload(
                    expectedRecord: record,
                    fileStore: fileStore,
                    epochSeconds: now
                ) == .completed {
                    reconciliation.corruptPayloadCount += 1
                }
            case .missing, .corrupt:
                if try catalog.quarantineOrphanArtifact(
                    CodeMapArtifactOrphanCandidate(shard: key.shard, digest: digest),
                    fileStore: fileStore,
                    epochSeconds: now
                ) == .completed {
                    reconciliation.corruptPayloadCount += 1
                }
            }
            removeRecord(digest: digest, localMutation: true)
            quarantineInventoryComplete = false
            return .miss

        case .miss:
            if case let .record(record) = try catalog.liveRecord(key: key, quarantineCorruptionAt: now) {
                if try catalog.quarantineMissingPayload(expectedRecord: record, epochSeconds: now) == .completed {
                    reconciliation.missingPayloadCount += 1
                }
            }
            removeRecord(digest: digest, localMutation: true)
            quarantineInventoryComplete = false
            return .miss

        case let .hit(verified):
            let recordResult = try catalog.liveRecord(key: key, quarantineCorruptionAt: now)
            let record: CodeMapArtifactCatalogRecord
            if case let .record(existing) = recordResult,
               recordMatches(existing, key: key, verified: verified)
            {
                record = existing
            } else {
                if case let .record(existing) = recordResult {
                    _ = try catalog.quarantineMissingPayload(expectedRecord: existing, epochSeconds: now)
                }
                let repaired = makeRecord(key: key, verified: verified, now: now)
                record = try catalog.writeLiveRecord(repaired)
                reconciliation.repairedOrphanArtifactCount += 1
                quarantineInventoryComplete = false
            }
            setRecord(record, localMutation: true)
            let handle = CodeMapArtifactHandle(key: key, verified: verified)
            cache(handle)
            touch(digest: digest)
            return .hit(source: .disk, handle: handle)
        }
    }

    func insert(
        key: CodeMapArtifactKey,
        deterministicOutcome outcome: CodeMapSyntaxArtifactOutcome
    ) throws -> CodeMapArtifactInsertResult {
        let encodedContainer = try CodeMapArtifactContainer.encode(
            key: key,
            outcome: outcome,
            policy: policy.containerPolicy
        )
        let now = clock.nowEpochSeconds()
        let digest = key.storageDigestHex
        guard records[digest] != nil || records.count < policy.maximumCatalogRecordCount else {
            throw CodeMapArtifactCatalogError.boundedScanExceeded
        }
        if case .corrupt = try fileStore.readVerified(key: key, quarantineCorruption: false) {
            switch try catalog.liveRecord(key: key, quarantineCorruptionAt: now) {
            case let .record(record):
                _ = try catalog.quarantineCorruptPayload(
                    expectedRecord: record,
                    fileStore: fileStore,
                    epochSeconds: now
                )
            case .missing, .corrupt:
                _ = try catalog.quarantineOrphanArtifact(
                    CodeMapArtifactOrphanCandidate(shard: key.shard, digest: digest),
                    fileStore: fileStore,
                    epochSeconds: now
                )
            }
            removeRecord(digest: digest, localMutation: true)
            reconciliation.corruptPayloadCount += 1
            quarantineInventoryComplete = false
        }

        let result: (CodeMapArtifactFileWriteResult, CodeMapArtifactVerifiedFile, CodeMapArtifactCatalogRecord) =
            try catalog.withInsertLocks(key: key) {
                let writeResult = try fileStore.writeAssumingMaintenanceLock(
                    key: key,
                    encodedContainer: encodedContainer,
                    quarantineEpochSeconds: now
                )
                guard case let .hit(verified) = try fileStore.readVerified(
                    key: key,
                    quarantineCorruption: false
                ) else { throw CodeMapArtifactCatalogError.invalidMetadata }
                let existing = records[digest]
                let incoming = CodeMapArtifactCatalogRecord(
                    key: key,
                    containerByteCount: UInt64(verified.containerByteCount),
                    payloadByteCount: UInt64(verified.payloadByteCount),
                    outcomeClass: CodeMapArtifactCatalogOutcomeClass(outcome: verified.outcome),
                    creationEpochSeconds: existing?.creationEpochSeconds ?? now,
                    lastAccessEpochSeconds: max(existing?.lastAccessEpochSeconds ?? now, now),
                    lastAccessSequence: takeSequence(),
                    state: .live
                )
                let merged = try catalog.writeLiveRecordAssumingMaintenanceLock(incoming)
                return (writeResult, verified, merged)
            }
        setRecord(result.2, localMutation: true)
        pendingTouchSet.remove(digest)
        cache(CodeMapArtifactHandle(key: key, verified: result.1))
        return result.0 == .inserted ? .inserted : .alreadyPresent
    }

    func lease(handle: CodeMapArtifactHandle) throws -> CodeMapArtifactLease {
        let diskLease = try catalog.acquireSharedLease(key: handle.key)
        let token = UUID()
        let digest = handle.key.storageDigestHex
        activeLeaseTokens[token] = digest
        leaseCountByDigest[digest, default: 0] += 1
        return CodeMapArtifactLease(handle: handle, diskLease: diskLease, store: self, token: token)
    }

    @discardableResult
    func flushAccessMetadata(stepBudget: Int) throws -> Int {
        guard stepBudget > 0, stepBudget <= policy.maximumGCStepBudget else {
            throw CodeMapArtifactCatalogError.boundedScanExceeded
        }
        var completed = 0
        var remainingWriteBytes = policy.maximumMaintenanceWriteByteCount
        var remainingReadBytes = UInt64(policy.maximumCatalogScanByteCount)
        while completed < stepBudget, let digest = dequeueTouch() {
            guard remainingWriteBytes >= UInt64(policy.maximumMetadataRecordByteCount),
                  remainingReadBytes >= UInt64(policy.maximumMetadataRecordByteCount)
            else {
                if pendingTouchSet.insert(digest).inserted { pendingTouchOrder.append(digest) }
                break
            }
            let metrics = flushTouch(digest)
            remainingWriteBytes = subtractingFloor(remainingWriteBytes, metrics.writtenByteCount)
            remainingReadBytes = subtractingFloor(remainingReadBytes, metrics.metadataReadByteCount)
            completed += 1
            if metrics.failed { break }
        }
        return completed
    }

    func accounting() -> CodeMapArtifactStoreAccounting {
        CodeMapArtifactStoreAccounting(
            livePositiveCount: livePositiveCount,
            livePositiveBytes: livePositiveBytes,
            liveNegativeCount: liveNegativeCount,
            liveNegativeBytes: liveNegativeBytes,
            quarantinedCount: reconciliation.scan.quarantineRecordCount,
            quarantinedBytes: reconciliation.scan.quarantineContainerBytes,
            residentPositiveCount: residentPositive.count,
            residentPositiveBytes: residentPositive.values.reduce(0) { $0 + $1.handle.estimatedResidentByteCount },
            residentNegativeCount: residentNegative.count,
            residentNegativeBytes: residentNegative.values.reduce(0) { $0 + $1.handle.estimatedResidentByteCount },
            activeLeaseCount: activeLeaseTokens.count,
            pendingAccessTouchCount: pendingTouchSet.count,
            corruptMetadataCount: reconciliation.scan.corruptMetadataCount,
            corruptPayloadCount: reconciliation.corruptPayloadCount,
            missingPayloadCount: reconciliation.missingPayloadCount,
            repairedOrphanArtifactCount: reconciliation.repairedOrphanArtifactCount,
            observedOrphanArtifactCount: reconciliation.scan.orphanArtifactCount,
            ignoredTemporaryCount: reconciliation.scan.ignoredTemporaryCount,
            removedTemporaryCount: reconciliation.scan.removedTemporaryCount,
            retainedPrivateDeletionCount: retainedLivePrivateDeletionCount +
                retainedQuarantinePrivateDeletionCount,
            retainedPrivateDeletionBytes: addingSaturating(
                retainedLivePrivateDeletionBytes,
                retainedQuarantinePrivateDeletionBytes
            ),
            recoveredPrivateDeletionCount: reconciliation.scan.recoveredPrivateDeletionCount,
            recoveredPrivateDeletionBytes: reconciliation.scan.recoveredPrivateDeletionBytes,
            quarantineOrphanCount: reconciliation.scan.quarantineOrphanCount,
            liveReconciliationComplete: liveReconciliationComplete,
            quarantineInventoryComplete: quarantineInventoryComplete
        )
    }

    func maintenanceIndexAccounting() -> CodeMapArtifactStoreMaintenanceIndexAccounting {
        CodeMapArtifactStoreMaintenanceIndexAccounting(
            recordOrderCount: recordOrder.count,
            recordSetCount: recordOrderSet.count,
            mutationGenerationCount: mutationGenerationByDigest.count
        )
    }

    func refreshAccounting(stepBudget: Int) throws -> CodeMapArtifactReconciliationProgress {
        let progress = try advanceMaintenance(stepBudget: stepBudget, collect: false)
        return CodeMapArtifactReconciliationProgress(
            accounting: accounting(),
            visitedEntryCount: progress.visitedEntryCount,
            readByteCount: progress.readByteCount,
            writtenByteCount: progress.writtenByteCount,
            repairedCount: progress.repairedCount,
            continuation: progress.continuation
        )
    }

    func runGC(stepBudget: Int) throws -> CodeMapArtifactGCProgress {
        try advanceMaintenance(stepBudget: stepBudget, collect: true)
    }

    fileprivate func releaseLease(token: UUID, key: CodeMapArtifactKey) {
        let digest = key.storageDigestHex
        guard activeLeaseTokens.removeValue(forKey: token) == digest else { return }
        let next = leaseCountByDigest[digest, default: 0] - 1
        if next > 0 { leaseCountByDigest[digest] = next }
        else { leaseCountByDigest.removeValue(forKey: digest) }
    }

    private func advanceMaintenance(stepBudget: Int, collect: Bool) throws -> CodeMapArtifactGCProgress {
        guard stepBudget > 0, stepBudget <= policy.maximumGCStepBudget else {
            throw CodeMapArtifactCatalogError.boundedScanExceeded
        }
        if maintenanceCycle == nil { maintenanceCycle = makeMaintenanceCycle(collect: collect) }
        if collect { maintenanceCycle?.collect = true }
        guard var cycle = maintenanceCycle else { throw CodeMapArtifactCatalogError.invalidMetadata }
        var remaining = stepBudget
        var metadataBytesRemaining = UInt64(policy.maximumCatalogScanByteCount)
        var artifactBytesRemaining = policy.maximumArtifactReconciliationByteCount
        var writeBytesRemaining = policy.maximumMaintenanceWriteByteCount
        var progress = CallProgress()

        maintenanceLoop: while remaining > 0 {
            switch cycle.phase {
            case .flushTouches:
                guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount),
                      metadataBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount)
                else {
                    break maintenanceLoop
                }
                guard let digest = dequeueTouch() else {
                    cycle.phase = .reconcileCatalog
                    continue
                }
                let metrics = flushTouch(digest)
                writeBytesRemaining = subtractingFloor(writeBytesRemaining, metrics.writtenByteCount)
                metadataBytesRemaining = subtractingFloor(
                    metadataBytesRemaining,
                    metrics.metadataReadByteCount
                )
                progress.writtenBytes = addingSaturating(
                    progress.writtenBytes,
                    metrics.writtenByteCount
                )
                progress.readBytes = addingSaturating(
                    progress.readBytes,
                    metrics.metadataReadByteCount
                )
                charge(&cycle, &remaining, &progress)
                if metrics.failed { break maintenanceLoop }

            case .reconcileCatalog:
                guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount) else {
                    break maintenanceLoop
                }
                if cycle.reconciliation.catalogScan == nil {
                    cycle.reconciliation.catalogScan = try catalog.beginScan(.liveCatalog)
                }
                guard let scan = cycle.reconciliation.catalogScan else { continue }
                switch try catalog.nextScanStep(
                    scan,
                    maximumReadByteCount: metadataBytesRemaining,
                    epochSeconds: cycle.now
                ) {
                case .complete:
                    cycle.phase = .reconcileArtifacts
                case let .needsMoreBytes(required, chargeEntry):
                    if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
                    guard required <= UInt64(policy.maximumCatalogScanByteCount) else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    break maintenanceLoop
                case let .visit(visit, chargeEntry):
                    chargeVisit(
                        visit,
                        chargeEntry: chargeEntry,
                        cycle: &cycle,
                        remaining: &remaining,
                        progress: &progress
                    )
                    metadataBytesRemaining -= min(metadataBytesRemaining, visit.readByteCount)
                    switch visit {
                    case let .liveRecord(record, _):
                        cycle.reconciliation.candidates[record.digest] = record
                        cycle.reconciliation.candidateOrder.append(record.digest)
                        nextAccessSequence = max(nextAccessSequence, successor(record.lastAccessSequence))
                    case let .corruptLiveMetadata(_, _, _, writtenBytes):
                        reconciliation.scan.corruptMetadataCount += 1
                        quarantineInventoryComplete = false
                        progress.tombstones += 1
                        writeBytesRemaining = subtractingFloor(writeBytesRemaining, writtenBytes)
                        progress.writtenBytes = addingSaturating(progress.writtenBytes, writtenBytes)
                    case let .temporary(removed):
                        reconciliation.scan.ignoredTemporaryCount += 1
                        if removed { reconciliation.scan.removedTemporaryCount += 1 }
                    case let .privateDeletion(removed, storedByteCount):
                        recordPrivateDeletion(
                            removed: removed,
                            storedByteCount: storedByteCount,
                            quarantine: false,
                            cycle: &cycle
                        )
                    case .boundary, .junk:
                        break
                    default:
                        break
                    }
                }

            case .reconcileArtifacts:
                guard writeBytesRemaining >= compoundMetadataWriteReservation,
                      metadataBytesRemaining >= compoundMetadataReadReservation
                else {
                    break maintenanceLoop
                }
                if cycle.reconciliation.artifactScan == nil {
                    cycle.reconciliation.artifactScan = try catalog.beginScan(.liveArtifacts)
                }
                guard let scan = cycle.reconciliation.artifactScan else { continue }
                switch try catalog.nextScanStep(
                    scan,
                    maximumReadByteCount: artifactBytesRemaining,
                    epochSeconds: cycle.now
                ) {
                case .complete:
                    cycle.phase = .reconcileMissingMetadata
                case let .needsMoreBytes(required, chargeEntry):
                    if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
                    guard required <= policy.maximumArtifactReconciliationByteCount else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    break maintenanceLoop
                case let .visit(visit, chargeEntry):
                    chargeVisit(
                        visit,
                        chargeEntry: chargeEntry,
                        cycle: &cycle,
                        remaining: &remaining,
                        progress: &progress
                    )
                    artifactBytesRemaining -= min(artifactBytesRemaining, visit.readByteCount)
                    switch visit {
                    case let .liveArtifact(candidate, containerBytes, _):
                        let metrics = try reconcileArtifact(
                            candidate,
                            containerByteCount: containerBytes,
                            cycle: &cycle,
                            progress: &progress
                        )
                        artifactBytesRemaining = subtractingFloor(
                            artifactBytesRemaining,
                            metrics.additionalReadByteCount
                        )
                        progress.readBytes = addingSaturating(
                            progress.readBytes,
                            metrics.additionalReadByteCount
                        )
                        metadataBytesRemaining = subtractingFloor(
                            metadataBytesRemaining,
                            metrics.metadataReadByteCount
                        )
                        progress.readBytes = addingSaturating(
                            progress.readBytes,
                            metrics.metadataReadByteCount
                        )
                        writeBytesRemaining = subtractingFloor(writeBytesRemaining, metrics.writtenByteCount)
                        progress.writtenBytes = addingSaturating(
                            progress.writtenBytes,
                            metrics.writtenByteCount
                        )
                    case let .temporary(removed):
                        reconciliation.scan.ignoredTemporaryCount += 1
                        if removed { reconciliation.scan.removedTemporaryCount += 1 }
                    case let .privateDeletion(removed, storedByteCount):
                        recordPrivateDeletion(
                            removed: removed,
                            storedByteCount: storedByteCount,
                            quarantine: false,
                            cycle: &cycle
                        )
                    case .boundary, .junk:
                        break
                    default:
                        break
                    }
                }

            case .reconcileMissingMetadata:
                guard cycle.reconciliation.unmatchedOffset < cycle.reconciliation.candidateOrder.count else {
                    cycle.reconciliation.cleanupLimit = recordOrder.count
                    cycle.phase = .reconcileCleanup
                    continue
                }
                let digest = cycle.reconciliation.candidateOrder[cycle.reconciliation.unmatchedOffset]
                var verificationReadBytes: UInt64 = 0
                guard writeBytesRemaining >= compoundMetadataWriteReservation,
                      metadataBytesRemaining >= compoundMetadataReadReservation
                else {
                    break maintenanceLoop
                }
                if let record = cycle.reconciliation.candidates[digest] {
                    verificationReadBytes = try fileStore.maintenanceVerificationReadByteCount(key: record.key) ?? 0
                    let (worstCaseRead, overflow) = verificationReadBytes.multipliedReportingOverflow(by: 2)
                    let requiredRead = overflow ? UInt64.max : worstCaseRead
                    guard requiredRead <= policy.maximumArtifactReconciliationByteCount else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    guard requiredRead <= artifactBytesRemaining else { break maintenanceLoop }
                    artifactBytesRemaining -= verificationReadBytes
                    progress.readBytes = addingSaturating(progress.readBytes, verificationReadBytes)
                }
                cycle.reconciliation.unmatchedOffset += 1
                if let record = cycle.reconciliation.candidates.removeValue(forKey: digest) {
                    let metrics = try reconcileUnmatched(
                        record,
                        verificationReadByteCount: verificationReadBytes,
                        cycle: &cycle,
                        progress: &progress
                    )
                    artifactBytesRemaining = subtractingFloor(
                        artifactBytesRemaining,
                        metrics.additionalReadByteCount
                    )
                    progress.readBytes = addingSaturating(
                        progress.readBytes,
                        metrics.additionalReadByteCount
                    )
                    metadataBytesRemaining = subtractingFloor(
                        metadataBytesRemaining,
                        metrics.metadataReadByteCount
                    )
                    progress.readBytes = addingSaturating(
                        progress.readBytes,
                        metrics.metadataReadByteCount
                    )
                    writeBytesRemaining = subtractingFloor(writeBytesRemaining, metrics.writtenByteCount)
                    progress.writtenBytes = addingSaturating(
                        progress.writtenBytes,
                        metrics.writtenByteCount
                    )
                }
                charge(&cycle, &remaining, &progress)

            case .reconcileCleanup:
                if cycle.reconciliation.cleanupLimit < recordOrder.count {
                    cycle.reconciliation.cleanupLimit = recordOrder.count
                }
                guard cycle.reconciliation.cleanupOffset < cycle.reconciliation.cleanupLimit else {
                    recordOrder = cycle.reconciliation.compactedOrder
                    recordOrderSet = cycle.reconciliation.compactedSet
                    mutationGenerationByDigest = cycle.reconciliation.compactedMutationGenerations
                    liveReconciliationComplete = true
                    cycle.reconciliation.selectionOrder = recordOrder
                    cycle.selectionLimit = cycle.reconciliation.selectionOrder.count
                    cycle.phase = cycle.collect ? .select : .quarantineCatalog
                    continue
                }
                let digest = recordOrder[cycle.reconciliation.cleanupOffset]
                cycle.reconciliation.cleanupOffset += 1
                if !cycle.reconciliation.seenDigests.contains(digest),
                   mutationGenerationByDigest[digest, default: 0] <= cycle.reconciliation.startMutationGeneration
                {
                    removeRecord(digest: digest, localMutation: false)
                }
                if records[digest] != nil, cycle.reconciliation.compactedSet.insert(digest).inserted {
                    cycle.reconciliation.compactedOrder.append(digest)
                    if let generation = mutationGenerationByDigest[digest] {
                        cycle.reconciliation.compactedMutationGenerations[digest] = generation
                    }
                }
                charge(&cycle, &remaining, &progress)

            case .select:
                guard cycle.selectionOffset < cycle.selectionLimit else {
                    cycle.phase = .quarantine
                    continue
                }
                let digest = cycle.reconciliation.selectionOrder[cycle.selectionOffset]
                cycle.selectionOffset += 1
                if let record = records[digest] { cycle.heap.insert(record) }
                progress.selected += 1
                charge(&cycle, &remaining, &progress)

            case .quarantine:
                var quarantineVerificationBytes: UInt64 = 0
                var quarantineMetadataBytes: UInt64 = 0
                let privateDeletionBytes = addingSaturating(
                    cycle.retainedLivePrivateDeletionBytes,
                    retainedQuarantinePrivateDeletionBytes
                )
                if let next = cycle.heap.minimum,
                   records[next.digest] == next,
                   shouldCollect(
                       record: next,
                       now: cycle.now,
                       privateDeletionBytes: privateDeletionBytes
                   ),
                   leaseCountByDigest[next.digest, default: 0] == 0
                {
                    guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount) else {
                        break maintenanceLoop
                    }
                    guard metadataBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount) else {
                        break maintenanceLoop
                    }
                    quarantineMetadataBytes = try UInt64(CodeMapArtifactCatalog.encodeRecord(next).count)
                    quarantineVerificationBytes = try fileStore.maintenanceVerificationReadByteCount(key: next.key) ?? 0
                    guard quarantineVerificationBytes <= policy.maximumArtifactReconciliationByteCount else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    guard quarantineVerificationBytes <= artifactBytesRemaining else { break maintenanceLoop }
                    artifactBytesRemaining -= quarantineVerificationBytes
                    progress.readBytes = addingSaturating(progress.readBytes, quarantineVerificationBytes)
                }
                guard let expected = cycle.heap.popMinimum() else {
                    cycle.phase = .quarantineCatalog
                    continue
                }
                let digest = expected.digest
                defer { charge(&cycle, &remaining, &progress) }
                guard records[digest] == expected,
                      shouldCollect(
                          record: expected,
                          now: cycle.now,
                          privateDeletionBytes: privateDeletionBytes
                      )
                else { continue }
                guard leaseCountByDigest[digest, default: 0] == 0 else {
                    progress.leased += 1
                    continue
                }
                let reason = collectionReason(
                    record: expected,
                    now: cycle.now,
                    privateDeletionBytes: privateDeletionBytes
                )
                switch try catalog.quarantine(
                    expectedRecord: expected,
                    fileStore: fileStore,
                    epochSeconds: cycle.now,
                    reason: reason
                ) {
                case .completed:
                    metadataBytesRemaining = subtractingFloor(
                        metadataBytesRemaining,
                        quarantineMetadataBytes
                    )
                    progress.readBytes = addingSaturating(progress.readBytes, quarantineMetadataBytes)
                    progress.quarantined += 1
                    progress.quarantinedBytes += expected.containerByteCount
                    progress.tombstones += 1
                    let written = try CodeMapArtifactCatalog.tombstoneByteCount(
                        epochSeconds: cycle.now,
                        record: expected,
                        digest: expected.digest,
                        reason: reason,
                        containerByteCount: expected.containerByteCount,
                        hasArtifact: true
                    )
                    writeBytesRemaining = subtractingFloor(writeBytesRemaining, written)
                    progress.writtenBytes = addingSaturating(progress.writtenBytes, written)
                    removeRecord(digest: digest, localMutation: false)
                    residentPositive.removeValue(forKey: digest)
                    residentNegative.removeValue(forKey: digest)
                    pendingTouchSet.remove(digest)
                    quarantineInventoryComplete = false
                case .leased:
                    artifactBytesRemaining = addingSaturating(
                        artifactBytesRemaining,
                        quarantineVerificationBytes
                    )
                    progress.readBytes = subtractingFloor(
                        progress.readBytes,
                        quarantineVerificationBytes
                    )
                    progress.leased += 1
                case .missingOrChanged:
                    metadataBytesRemaining = subtractingFloor(
                        metadataBytesRemaining,
                        quarantineMetadataBytes
                    )
                    progress.readBytes = addingSaturating(progress.readBytes, quarantineMetadataBytes)
                    progress.changed += 1
                }

            case .quarantineCatalog:
                guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount) else {
                    break maintenanceLoop
                }
                if cycle.quarantineCatalogScan == nil {
                    cycle.quarantineCatalogScan = try catalog.beginScan(.quarantineCatalog)
                    cycle.quarantineCount = 0
                    cycle.quarantineBytes = 0
                    cycle.expectedQuarantineArtifacts.removeAll(keepingCapacity: true)
                    quarantineInventoryComplete = false
                }
                guard let scan = cycle.quarantineCatalogScan else { continue }
                switch try catalog.nextScanStep(
                    scan,
                    maximumReadByteCount: metadataBytesRemaining,
                    epochSeconds: cycle.now
                ) {
                case .complete:
                    cycle.phase = .quarantineArtifacts
                case let .needsMoreBytes(required, chargeEntry):
                    if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
                    guard required <= UInt64(policy.maximumCatalogScanByteCount) else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    break maintenanceLoop
                case let .visit(visit, chargeEntry):
                    chargeVisit(
                        visit,
                        chargeEntry: chargeEntry,
                        cycle: &cycle,
                        remaining: &remaining,
                        progress: &progress
                    )
                    metadataBytesRemaining -= min(metadataBytesRemaining, visit.readByteCount)
                    switch visit {
                    case let .quarantineTombstone(candidate, metadataBytes, _, writtenBytes):
                        writeBytesRemaining = subtractingFloor(writeBytesRemaining, writtenBytes)
                        progress.writtenBytes = addingSaturating(progress.writtenBytes, writtenBytes)
                        cycle.quarantineCount += 1
                        cycle.quarantineBytes = addingSaturating(cycle.quarantineBytes, metadataBytes)
                        if let artifactName = candidate.artifactName {
                            cycle.expectedQuarantineArtifacts.insert(quarantineIdentity(
                                epoch: candidate.epochSeconds,
                                shard: candidate.shard,
                                name: artifactName
                            ))
                        }
                        if cycle.collect, isSweepEligible(candidate, now: cycle.now) {
                            cycle.pendingSweepSelection = PendingSweep(
                                candidate: candidate,
                                metadataByteCount: metadataBytes
                            )
                            cycle.phase = .selectSweep
                        }
                    case .corruptQuarantineMetadata:
                        reconciliation.scan.quarantineOrphanCount += 1
                    case let .temporary(removed):
                        reconciliation.scan.ignoredTemporaryCount += 1
                        if removed { reconciliation.scan.removedTemporaryCount += 1 }
                    case let .privateDeletion(removed, storedByteCount):
                        recordPrivateDeletion(
                            removed: removed,
                            storedByteCount: storedByteCount,
                            quarantine: true,
                            cycle: &cycle
                        )
                    case .boundary, .junk:
                        break
                    default:
                        break
                    }
                }

            case .selectSweep:
                guard let pending = cycle.pendingSweepSelection else {
                    cycle.phase = .quarantineCatalog
                    continue
                }
                cycle.pendingSweepSelection = nil
                cycle.sweepHeap.insert(pending)
                progress.selected += 1
                charge(&cycle, &remaining, &progress)
                cycle.phase = .quarantineCatalog

            case .sweep:
                if let next = cycle.sweepHeap.minimum {
                    guard next.metadataByteCount <= UInt64(policy.maximumCatalogScanByteCount) else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    guard next.metadataByteCount <= metadataBytesRemaining else { break maintenanceLoop }
                }
                guard let pending = cycle.sweepHeap.popMinimum() else {
                    reconciliation.scan.quarantineRecordCount = cycle.quarantineCount
                    reconciliation.scan.quarantineContainerBytes = cycle.quarantineBytes
                    reconciliation.scan.quarantineOrphanCount =
                        cycle.recoveredQuarantineOrphanCount + cycle.expectedQuarantineArtifacts.count
                    quarantineInventoryComplete = true
                    finishPrivateDeletionAccounting(cycle)
                    maintenanceCycle = nil
                    return makeProgress(cycle: cycle, progress: progress, continuation: nil)
                }
                metadataBytesRemaining -= pending.metadataByteCount
                progress.readBytes = addingSaturating(progress.readBytes, pending.metadataByteCount)
                switch try catalog.sweep(pending.candidate) {
                case .completed:
                    progress.swept += 1
                    progress.sweptDigests.append(pending.candidate.tombstone.digest)
                    progress.sweptBytes += pending.candidate.tombstone.containerByteCount
                    cycle.quarantineCount = max(0, cycle.quarantineCount - 1)
                    var removedBytes = pending.metadataByteCount
                    if let artifactName = pending.candidate.artifactName {
                        let identity = quarantineIdentity(
                            epoch: pending.candidate.epochSeconds,
                            shard: pending.candidate.shard,
                            name: artifactName
                        )
                        cycle.expectedQuarantineArtifacts.remove(identity)
                        if cycle.presentQuarantineArtifacts.remove(identity) != nil {
                            removedBytes = addingSaturating(
                                removedBytes,
                                cycle.quarantineArtifactBytes.removeValue(forKey: identity) ?? 0
                            )
                        }
                    }
                    cycle.quarantineBytes = subtractingFloor(cycle.quarantineBytes, removedBytes)
                case .leased:
                    metadataBytesRemaining = addingSaturating(metadataBytesRemaining, pending.metadataByteCount)
                    progress.readBytes = subtractingFloor(progress.readBytes, pending.metadataByteCount)
                    progress.leased += 1
                case .missingOrChanged:
                    progress.changed += 1
                }
                charge(&cycle, &remaining, &progress)

            case .quarantineArtifacts:
                if cycle.quarantineArtifactScan == nil {
                    cycle.quarantineArtifactScan = try catalog.beginScan(.quarantineArtifacts)
                }
                guard let scan = cycle.quarantineArtifactScan else { continue }
                switch try catalog.nextScanStep(
                    scan,
                    maximumReadByteCount: 0,
                    epochSeconds: cycle.now
                ) {
                case .complete:
                    if cycle.collect, !cycle.sweepHeap.values.isEmpty {
                        cycle.phase = .sweep
                        continue
                    }
                    reconciliation.scan.quarantineRecordCount = cycle.quarantineCount
                    reconciliation.scan.quarantineContainerBytes = cycle.quarantineBytes
                    reconciliation.scan.quarantineOrphanCount =
                        cycle.recoveredQuarantineOrphanCount + cycle.expectedQuarantineArtifacts.count
                    quarantineInventoryComplete = true
                    finishPrivateDeletionAccounting(cycle)
                    maintenanceCycle = nil
                    return makeProgress(cycle: cycle, progress: progress, continuation: nil)
                case let .needsMoreBytes(_, chargeEntry):
                    if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
                    throw CodeMapArtifactCatalogError.boundedScanExceeded
                case let .visit(visit, chargeEntry):
                    chargeVisit(
                        visit,
                        chargeEntry: chargeEntry,
                        cycle: &cycle,
                        remaining: &remaining,
                        progress: &progress
                    )
                    switch visit {
                    case let .quarantineArtifact(epoch, shard, name, storedBytes):
                        cycle.quarantineBytes = addingSaturating(cycle.quarantineBytes, storedBytes)
                        let identity = quarantineIdentity(epoch: epoch, shard: shard, name: name)
                        cycle.quarantineArtifactBytes[identity] = storedBytes
                        if cycle.expectedQuarantineArtifacts.remove(identity) != nil {
                            cycle.presentQuarantineArtifacts.insert(identity)
                        } else {
                            cycle.pendingRepair = PendingQuarantineRepair(
                                epochSeconds: epoch,
                                shard: shard,
                                artifactName: name,
                                byteCount: storedBytes
                            )
                            cycle.phase = .repairQuarantine
                        }
                    case let .temporary(removed):
                        reconciliation.scan.ignoredTemporaryCount += 1
                        if removed { reconciliation.scan.removedTemporaryCount += 1 }
                    case let .privateDeletion(removed, storedByteCount):
                        recordPrivateDeletion(
                            removed: removed,
                            storedByteCount: storedByteCount,
                            quarantine: true,
                            cycle: &cycle
                        )
                    case .boundary, .junk:
                        break
                    default:
                        break
                    }
                }

            case .repairQuarantine:
                guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount),
                      metadataBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount)
                else {
                    break maintenanceLoop
                }
                guard let pending = cycle.pendingRepair else {
                    cycle.phase = .quarantineArtifacts
                    continue
                }
                cycle.pendingRepair = nil
                switch try catalog.recoverArtifactOnlyTombstone(
                    epochSeconds: pending.epochSeconds,
                    shard: pending.shard,
                    artifactName: pending.artifactName,
                    byteCount: pending.byteCount
                ) {
                case let .written(metadataByteCount, writtenByteCount, readByteCount):
                    let metadataBytes = UInt64(metadataByteCount)
                    let writtenBytes = UInt64(writtenByteCount)
                    let readBytes = UInt64(readByteCount)
                    writeBytesRemaining = subtractingFloor(writeBytesRemaining, writtenBytes)
                    metadataBytesRemaining = subtractingFloor(metadataBytesRemaining, readBytes)
                    progress.writtenBytes = addingSaturating(progress.writtenBytes, writtenBytes)
                    progress.readBytes = addingSaturating(progress.readBytes, readBytes)
                    cycle.quarantineCount += 1
                    cycle.quarantineBytes = addingSaturating(cycle.quarantineBytes, metadataBytes)
                    progress.tombstones += 1
                    cycle.recoveredQuarantineOrphanCount += 1
                case let .existing(metadataByteCount):
                    metadataBytesRemaining = subtractingFloor(
                        metadataBytesRemaining,
                        UInt64(metadataByteCount)
                    )
                    progress.readBytes = addingSaturating(
                        progress.readBytes,
                        UInt64(metadataByteCount)
                    )
                    cycle.quarantineCount += 1
                    cycle.quarantineBytes = addingSaturating(
                        cycle.quarantineBytes,
                        UInt64(metadataByteCount)
                    )
                case .leased:
                    progress.leased += 1
                    cycle.recoveredQuarantineOrphanCount += 1
                case .missingOrChanged:
                    let identity = quarantineIdentity(
                        epoch: pending.epochSeconds,
                        shard: pending.shard,
                        name: pending.artifactName
                    )
                    cycle.quarantineBytes = subtractingFloor(cycle.quarantineBytes, pending.byteCount)
                    cycle.quarantineArtifactBytes.removeValue(forKey: identity)
                    cycle.presentQuarantineArtifacts.remove(identity)
                    progress.changed += 1
                }
                charge(&cycle, &remaining, &progress)
                cycle.phase = .quarantineArtifacts
            }
        }

        maintenanceCycle = cycle
        let continuation = CodeMapArtifactGCContinuation(
            cycle: cycle.id,
            phase: cycle.phase,
            nextOffset: cycle.workSequence
        )
        return makeProgress(cycle: cycle, progress: progress, continuation: continuation)
    }

    private func makeMaintenanceCycle(collect: Bool) -> MaintenanceCycle {
        let id = nextMaintenanceCycle
        nextMaintenanceCycle = successor(nextMaintenanceCycle)
        liveReconciliationComplete = false
        quarantineInventoryComplete = false
        return MaintenanceCycle(
            id: id,
            now: clock.nowEpochSeconds(),
            collect: collect,
            reconciliation: ReconciliationState(startMutationGeneration: mutationGeneration)
        )
    }

    private func reconcileArtifact(
        _ candidate: CodeMapArtifactOrphanCandidate,
        containerByteCount: UInt64,
        cycle: inout MaintenanceCycle,
        progress: inout CallProgress
    ) throws -> MaintenanceIOMetrics {
        var metrics = MaintenanceIOMetrics()
        let expected = cycle.reconciliation.candidates[candidate.digest]
        if mutationGenerationByDigest[candidate.digest, default: 0] >
            cycle.reconciliation.startMutationGeneration
        {
            cycle.reconciliation.seenDigests.insert(candidate.digest)
            cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
            return metrics
        }
        switch try fileStore.reconcileOrphan(candidate, quarantineCorruption: false, epochSeconds: cycle.now) {
        case .miss:
            return metrics

        case .corrupt:
            if let expected {
                metrics.additionalReadByteCount = CodeMapArtifactFileStore.maintenanceVerificationReadByteCount(
                    containerByteCount: containerByteCount
                )
                metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(expected).count)
                let mutation = try catalog.quarantineCorruptPayload(
                    expectedRecord: expected,
                    fileStore: fileStore,
                    epochSeconds: cycle.now
                )
                if mutation == .completed {
                    reconciliation.corruptPayloadCount += 1
                    progress.tombstones += 1
                    metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                        epochSeconds: cycle.now,
                        record: expected,
                        digest: expected.digest,
                        reason: .corruptPayload,
                        containerByteCount: expected.containerByteCount,
                        hasArtifact: true
                    )
                }
                if mutation == .completed { removeRecord(digest: candidate.digest, localMutation: false) }
            } else if try catalog.quarantineOrphanArtifact(
                candidate,
                fileStore: fileStore,
                epochSeconds: cycle.now
            ) == .completed {
                reconciliation.corruptPayloadCount += 1
                progress.tombstones += 1
                metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                    epochSeconds: cycle.now,
                    record: nil,
                    digest: candidate.digest,
                    reason: .orphanArtifact,
                    containerByteCount: containerByteCount,
                    hasArtifact: true
                )
                removeRecord(digest: candidate.digest, localMutation: false)
            }
            cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
            quarantineInventoryComplete = false

        case let .verified(key, file):
            if let expected, recordMatches(expected, key: key, verified: file) {
                installReconciled(expected, cycle: &cycle)
                cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
            } else {
                if let expected {
                    metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(expected).count)
                    let mutation = try catalog.quarantineMissingPayload(
                        expectedRecord: expected,
                        epochSeconds: cycle.now
                    )
                    if mutation == .completed {
                        progress.tombstones += 1
                        metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                            epochSeconds: cycle.now,
                            record: expected,
                            digest: expected.digest,
                            reason: .missingPayload,
                            containerByteCount: 0,
                            hasArtifact: false
                        )
                    } else {
                        cycle.reconciliation.seenDigests.insert(candidate.digest)
                        cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
                        return metrics
                    }
                } else {
                    reconciliation.scan.orphanArtifactCount += 1
                }
                let repaired = try catalog.writeLiveRecord(makeRecord(key: key, verified: file, now: cycle.now))
                metrics.metadataReadByteCount = addingSaturating(
                    metrics.metadataReadByteCount,
                    UInt64(policy.maximumMetadataRecordByteCount)
                )
                metrics.writtenByteCount = try addingSaturating(
                    metrics.writtenByteCount,
                    UInt64(CodeMapArtifactCatalog.encodeRecord(repaired).count)
                )
                installReconciled(repaired, cycle: &cycle)
                cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
                reconciliation.repairedOrphanArtifactCount += 1
                progress.repaired += 1
                quarantineInventoryComplete = false
            }
        }
        return metrics
    }

    private func reconcileUnmatched(
        _ record: CodeMapArtifactCatalogRecord,
        verificationReadByteCount: UInt64,
        cycle: inout MaintenanceCycle,
        progress: inout CallProgress
    ) throws -> MaintenanceIOMetrics {
        var metrics = MaintenanceIOMetrics()
        if mutationGenerationByDigest[record.digest, default: 0] >
            cycle.reconciliation.startMutationGeneration
        {
            cycle.reconciliation.seenDigests.insert(record.digest)
            return metrics
        }
        switch try fileStore.readVerified(key: record.key, quarantineCorruption: false) {
        case .miss:
            metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(record).count)
            let mutation = try catalog.quarantineMissingPayload(expectedRecord: record, epochSeconds: cycle.now)
            if mutation == .completed {
                reconciliation.missingPayloadCount += 1
                progress.tombstones += 1
                metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                    epochSeconds: cycle.now,
                    record: record,
                    digest: record.digest,
                    reason: .missingPayload,
                    containerByteCount: 0,
                    hasArtifact: false
                )
                removeRecord(digest: record.digest, localMutation: false)
            } else {
                cycle.reconciliation.seenDigests.insert(record.digest)
            }
            quarantineInventoryComplete = false
        case .corrupt:
            metrics.additionalReadByteCount = verificationReadByteCount
            metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(record).count)
            let mutation = try catalog.quarantineCorruptPayload(
                expectedRecord: record,
                fileStore: fileStore,
                epochSeconds: cycle.now
            )
            if mutation == .completed {
                reconciliation.corruptPayloadCount += 1
                progress.tombstones += 1
                metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                    epochSeconds: cycle.now,
                    record: record,
                    digest: record.digest,
                    reason: .corruptPayload,
                    containerByteCount: record.containerByteCount,
                    hasArtifact: true
                )
                removeRecord(digest: record.digest, localMutation: false)
            } else {
                cycle.reconciliation.seenDigests.insert(record.digest)
            }
            quarantineInventoryComplete = false
        case let .hit(file):
            if recordMatches(record, key: record.key, verified: file) {
                installReconciled(record, cycle: &cycle)
            } else {
                metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(record).count)
                let mutation = try catalog.quarantineMissingPayload(
                    expectedRecord: record,
                    epochSeconds: cycle.now
                )
                if mutation == .completed {
                    metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                        epochSeconds: cycle.now,
                        record: record,
                        digest: record.digest,
                        reason: .missingPayload,
                        containerByteCount: 0,
                        hasArtifact: false
                    )
                } else {
                    cycle.reconciliation.seenDigests.insert(record.digest)
                    return metrics
                }
                let repaired = try catalog.writeLiveRecord(makeRecord(key: record.key, verified: file, now: cycle.now))
                metrics.metadataReadByteCount = addingSaturating(
                    metrics.metadataReadByteCount,
                    UInt64(policy.maximumMetadataRecordByteCount)
                )
                metrics.writtenByteCount = try addingSaturating(
                    metrics.writtenByteCount,
                    UInt64(CodeMapArtifactCatalog.encodeRecord(repaired).count)
                )
                installReconciled(repaired, cycle: &cycle)
                reconciliation.repairedOrphanArtifactCount += 1
                progress.repaired += 1
                progress.tombstones += 1
                quarantineInventoryComplete = false
            }
        }
        return metrics
    }

    private func installReconciled(
        _ record: CodeMapArtifactCatalogRecord,
        cycle: inout MaintenanceCycle
    ) {
        cycle.reconciliation.seenDigests.insert(record.digest)
        guard mutationGenerationByDigest[record.digest, default: 0] <=
            cycle.reconciliation.startMutationGeneration
        else { return }
        setRecord(record, localMutation: false)
    }

    private func makeRecord(
        key: CodeMapArtifactKey,
        verified: CodeMapArtifactVerifiedFile,
        now: UInt64
    ) -> CodeMapArtifactCatalogRecord {
        CodeMapArtifactCatalogRecord(
            key: key,
            containerByteCount: UInt64(verified.containerByteCount),
            payloadByteCount: UInt64(verified.payloadByteCount),
            outcomeClass: CodeMapArtifactCatalogOutcomeClass(outcome: verified.outcome),
            creationEpochSeconds: now,
            lastAccessEpochSeconds: now,
            lastAccessSequence: takeSequence(),
            state: .live
        )
    }

    private func recordMatches(
        _ record: CodeMapArtifactCatalogRecord,
        key: CodeMapArtifactKey,
        verified: CodeMapArtifactVerifiedFile
    ) -> Bool {
        record.key == key &&
            record.containerByteCount == UInt64(verified.containerByteCount) &&
            record.payloadByteCount == UInt64(verified.payloadByteCount) &&
            record.outcomeClass == CodeMapArtifactCatalogOutcomeClass(outcome: verified.outcome)
    }

    private func setRecord(_ record: CodeMapArtifactCatalogRecord, localMutation: Bool) {
        let digest = record.digest
        guard records[digest] != nil || records.count < policy.maximumCatalogRecordCount else { return }
        if let old = records[digest] { removeAccounting(old) }
        records[digest] = record
        addAccounting(record)
        if recordOrderSet.insert(digest).inserted {
            compactMaintenanceIndexesIfNeeded()
            recordOrder.append(digest)
        }
        if localMutation { markMutation(digest) }
    }

    private func removeRecord(digest: String, localMutation: Bool) {
        let removed = records.removeValue(forKey: digest)
        if let removed { removeAccounting(removed) }
        recordOrderSet.remove(digest)
        if localMutation, removed != nil { markMutation(digest) }
        compactMaintenanceIndexesIfNeeded()
    }

    private func addAccounting(_ record: CodeMapArtifactCatalogRecord) {
        if record.outcomeClass == .positive {
            livePositiveCount += 1
            livePositiveBytes = addingSaturating(livePositiveBytes, record.containerByteCount)
        } else {
            liveNegativeCount += 1
            liveNegativeBytes = addingSaturating(liveNegativeBytes, record.containerByteCount)
        }
    }

    private func removeAccounting(_ record: CodeMapArtifactCatalogRecord) {
        if record.outcomeClass == .positive {
            livePositiveCount = max(0, livePositiveCount - 1)
            livePositiveBytes = subtractingFloor(livePositiveBytes, record.containerByteCount)
        } else {
            liveNegativeCount = max(0, liveNegativeCount - 1)
            liveNegativeBytes = subtractingFloor(liveNegativeBytes, record.containerByteCount)
        }
    }

    private func markMutation(_ digest: String) {
        if mutationGenerationByDigest[digest] == nil,
           mutationGenerationByDigest.count >= policy.maximumCatalogRecordCount
        {
            abortMaintenanceAndCompactIndexes()
        }
        mutationGeneration = successor(mutationGeneration)
        mutationGenerationByDigest[digest] = mutationGeneration
    }

    private func compactMaintenanceIndexesIfNeeded() {
        let limit = policy.maximumCatalogRecordCount > Int.max / 2
            ? Int.max
            : policy.maximumCatalogRecordCount * 2
        guard recordOrder.count >= limit else { return }
        abortMaintenanceAndCompactIndexes()
    }

    private func abortMaintenanceAndCompactIndexes() {
        maintenanceCycle = nil
        recordOrder = recordOrder.filter { recordOrderSet.contains($0) }
        if recordOrder.count != recordOrderSet.count {
            recordOrder = records.keys.sorted()
            recordOrderSet = Set(recordOrder)
        }
        mutationGenerationByDigest = mutationGenerationByDigest.filter { records[$0.key] != nil }
        if mutationGenerationByDigest.count >= policy.maximumCatalogRecordCount {
            mutationGenerationByDigest.removeAll(keepingCapacity: true)
        }
        liveReconciliationComplete = false
        quarantineInventoryComplete = false
    }

    private func recordPrivateDeletion(
        removed: Bool,
        storedByteCount: UInt64?,
        quarantine: Bool,
        cycle: inout MaintenanceCycle
    ) {
        reconciliation.scan.ignoredTemporaryCount += 1
        guard let storedByteCount else { return }
        if removed {
            reconciliation.scan.removedTemporaryCount += 1
            reconciliation.scan.recoveredPrivateDeletionCount += 1
            reconciliation.scan.recoveredPrivateDeletionBytes = addingSaturating(
                reconciliation.scan.recoveredPrivateDeletionBytes,
                storedByteCount
            )
        } else if quarantine {
            cycle.retainedQuarantinePrivateDeletionCount += 1
            cycle.retainedQuarantinePrivateDeletionBytes = addingSaturating(
                cycle.retainedQuarantinePrivateDeletionBytes,
                storedByteCount
            )
        } else {
            cycle.retainedLivePrivateDeletionCount += 1
            cycle.retainedLivePrivateDeletionBytes = addingSaturating(
                cycle.retainedLivePrivateDeletionBytes,
                storedByteCount
            )
        }
    }

    private func finishPrivateDeletionAccounting(_ cycle: MaintenanceCycle) {
        retainedLivePrivateDeletionCount = cycle.retainedLivePrivateDeletionCount
        retainedLivePrivateDeletionBytes = cycle.retainedLivePrivateDeletionBytes
        retainedQuarantinePrivateDeletionCount = cycle.retainedQuarantinePrivateDeletionCount
        retainedQuarantinePrivateDeletionBytes = cycle.retainedQuarantinePrivateDeletionBytes
    }

    private func shouldCollect(
        record: CodeMapArtifactCatalogRecord,
        now: UInt64,
        privateDeletionBytes: UInt64
    ) -> Bool {
        if record.outcomeClass == .positive {
            let quotaBytes = addingSaturating(livePositiveBytes, privateDeletionBytes)
            if quotaBytes >= policy.hardQuotaBytes { return true }
            guard quotaBytes > policy.softQuotaBytes,
                  now >= policy.unreferencedGraceSeconds
            else { return false }
            return record.lastAccessEpochSeconds <= now - policy.unreferencedGraceSeconds
        }
        if liveNegativeBytes > policy.negativeQuotaBytes { return true }
        guard now >= policy.negativeMaximumAgeSeconds else { return false }
        return record.lastAccessEpochSeconds <= now - policy.negativeMaximumAgeSeconds
    }

    private func collectionReason(
        record: CodeMapArtifactCatalogRecord,
        now: UInt64,
        privateDeletionBytes: UInt64
    ) -> CodeMapArtifactQuarantineReason {
        if record.outcomeClass == .positive {
            return addingSaturating(livePositiveBytes, privateDeletionBytes) >= policy.hardQuotaBytes
                ? .quota
                : .age
        }
        return liveNegativeBytes > policy.negativeQuotaBytes ? .quota : .age
    }

    private func isSweepEligible(_ candidate: CodeMapArtifactQuarantineCandidate, now: UInt64) -> Bool {
        now >= policy.quarantineDelaySeconds &&
            candidate.epochSeconds <= now - policy.quarantineDelaySeconds
    }

    private static func gcOrder(
        _ lhs: CodeMapArtifactCatalogRecord,
        _ rhs: CodeMapArtifactCatalogRecord
    ) -> Bool {
        (lhs.lastAccessEpochSeconds, lhs.lastAccessSequence, lhs.creationEpochSeconds, lhs.digest) <
            (rhs.lastAccessEpochSeconds, rhs.lastAccessSequence, rhs.creationEpochSeconds, rhs.digest)
    }

    private func cache(_ handle: CodeMapArtifactHandle) {
        let digest = handle.key.storageDigestHex
        let entry = ResidentEntry(handle: handle, accessSequence: takeSequence())
        if CodeMapArtifactCatalogOutcomeClass(outcome: handle.outcome) == .positive {
            residentPositive[digest] = entry
            residentNegative.removeValue(forKey: digest)
            enforceResidentLimit(
                entries: &residentPositive,
                countLimit: policy.residentPositiveEntryLimit,
                byteLimit: policy.residentPositiveByteLimit
            )
        } else {
            residentNegative[digest] = entry
            residentPositive.removeValue(forKey: digest)
            enforceResidentLimit(
                entries: &residentNegative,
                countLimit: policy.residentNegativeEntryLimit,
                byteLimit: policy.residentNegativeByteLimit
            )
        }
    }

    private func enforceResidentLimit(
        entries: inout [String: ResidentEntry],
        countLimit: Int,
        byteLimit: UInt64
    ) {
        while entries.count > countLimit ||
            entries.values.reduce(UInt64(0), { $0 + $1.handle.estimatedResidentByteCount }) > byteLimit
        {
            guard let victim = entries.min(by: {
                ($0.value.accessSequence, $0.key) < ($1.value.accessSequence, $1.key)
            }) else { return }
            entries.removeValue(forKey: victim.key)
        }
    }

    private func touch(digest: String) {
        guard var record = records[digest] else { return }
        record.lastAccessEpochSeconds = max(record.creationEpochSeconds, clock.nowEpochSeconds())
        record.lastAccessSequence = takeSequence()
        setRecord(record, localMutation: true)
        if pendingTouchSet.insert(digest).inserted { pendingTouchOrder.append(digest) }
    }

    private func dequeueTouch() -> String? {
        while pendingTouchOffset < pendingTouchOrder.count {
            let digest = pendingTouchOrder[pendingTouchOffset]
            pendingTouchOffset += 1
            guard pendingTouchSet.remove(digest) != nil else { continue }
            if pendingTouchOffset > 1024, pendingTouchOffset * 2 > pendingTouchOrder.count {
                pendingTouchOrder.removeFirst(pendingTouchOffset)
                pendingTouchOffset = 0
            }
            return digest
        }
        pendingTouchOrder.removeAll(keepingCapacity: true)
        pendingTouchOffset = 0
        return nil
    }

    private func flushTouch(_ digest: String) -> MaintenanceIOMetrics {
        guard let record = records[digest] else { return MaintenanceIOMetrics() }
        var metrics = MaintenanceIOMetrics()
        do {
            if let merged = try catalog.updateLiveRecordIfPresent(record) {
                setRecord(merged, localMutation: false)
                let bytes = try UInt64(CodeMapArtifactCatalog.encodeRecord(merged).count)
                metrics.metadataReadByteCount = bytes
                metrics.writtenByteCount = bytes
                return metrics
            } else {
                removeRecord(digest: digest, localMutation: false)
                residentPositive.removeValue(forKey: digest)
                residentNegative.removeValue(forKey: digest)
            }
        } catch {
            metrics.metadataReadByteCount = UInt64(policy.maximumMetadataRecordByteCount)
            metrics.writtenByteCount = UInt64(policy.maximumMetadataRecordByteCount)
            metrics.failed = true
            if pendingTouchSet.insert(digest).inserted { pendingTouchOrder.append(digest) }
        }
        return metrics
    }

    private func currentSequence(for digest: String) -> UInt64 {
        records[digest]?.lastAccessSequence ?? 0
    }

    private func takeSequence() -> UInt64 {
        let result = nextAccessSequence
        nextAccessSequence = successor(nextAccessSequence)
        return result
    }

    private func successor(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }

    private func charge(
        _ cycle: inout MaintenanceCycle,
        _ remaining: inout Int,
        _ progress: inout CallProgress
    ) {
        remaining -= 1
        cycle.workSequence += 1
        progress.examined += 1
    }

    private func chargeVisit(
        _ visit: CodeMapArtifactCatalogScanVisit,
        chargeEntry: Bool,
        cycle: inout MaintenanceCycle,
        remaining: inout Int,
        progress: inout CallProgress
    ) {
        if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
        progress.readBytes = addingSaturating(progress.readBytes, visit.readByteCount)
    }

    private func chargeDeferredVisit(
        cycle: inout MaintenanceCycle,
        remaining: inout Int,
        progress: inout CallProgress
    ) {
        charge(&cycle, &remaining, &progress)
        progress.visited += 1
    }

    private func makeProgress(
        cycle: MaintenanceCycle,
        progress: CallProgress,
        continuation: CodeMapArtifactGCContinuation?
    ) -> CodeMapArtifactGCProgress {
        CodeMapArtifactGCProgress(
            cycle: cycle.id,
            examinedCount: progress.examined,
            quarantinedCount: progress.quarantined,
            quarantinedBytes: progress.quarantinedBytes,
            sweptCount: progress.swept,
            sweptBytes: progress.sweptBytes,
            leasedSkipCount: progress.leased,
            changedSkipCount: progress.changed,
            visitedEntryCount: progress.visited,
            readByteCount: progress.readBytes,
            writtenByteCount: progress.writtenBytes,
            selectionCount: progress.selected,
            repairedCount: progress.repaired,
            tombstoneCount: progress.tombstones,
            sweptDigests: progress.sweptDigests,
            continuation: continuation
        )
    }

    private func quarantineIdentity(epoch: UInt64, shard: String, name: String) -> String {
        "\(epoch)/\(shard)/\(name)"
    }

    private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }

    private func subtractingFloor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }
}
