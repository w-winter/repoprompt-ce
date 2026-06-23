import Foundation

#if DEBUG || CODEMAP_PERF
    #if canImport(Darwin)
        import Darwin
    #endif

    enum LegacyCodeMapTelemetryCohort: String, CaseIterable {
        case unspecified
        case setup
        case canonicalExplicitMiss
        case sameRootSecondStore
        case forcedResidentMemoryHit
        case equivalentLinkedWorktree
        case dirtyTracked
        case untracked
        case nonGit
        case eagerBackgroundConvergence
    }

    enum LegacyCodeMapTelemetryRootRole: String, CaseIterable {
        case unspecified
        case canonical
        case linkedWorktree
        case nonGit
    }

    enum LegacyCodeMapSourceTerminalOutcome: String, CaseIterable {
        case loaded
        case unavailable
        case failed
        case cancelled
    }

    enum LegacyCodeMapCacheResult: String, CaseIterable {
        case memoryHit
        case diskHit
        case absentMiss
        case unusableMiss
    }

    enum LegacyCodeMapCacheUnusableReason: String, CaseIterable {
        case modificationDate
        case fingerprint
        case containment
        case relativePathOwnership
        case cachedAPIPath
    }

    enum LegacyCodeMapRootCacheLoadOutcome: String, CaseIterable {
        case loaded
        case missing
        case versionMismatch
        case decodeFailure
    }

    enum LegacyCodeMapParseTerminalOutcome: String, CaseIterable {
        case completed
        case nilResult
        case failed
        case cancelled
    }

    enum LegacyCodeMapHashKind {
        case lookup
        case persistence
    }

    struct LegacyCodeMapTelemetryScope: Hashable {
        let sampleID: UUID
        let cohort: LegacyCodeMapTelemetryCohort
        let storeID: UUID
        let rootRole: LegacyCodeMapTelemetryRootRole
    }

    struct LegacyCodeMapTelemetryMetrics: Equatable {
        let requestedFileCount: Int
        let supportedFileCount: Int

        let sourceRequestCount: Int
        let sourceTerminalOutcomes: [LegacyCodeMapSourceTerminalOutcome: Int]
        let successfulOpenCount: Int
        let nominalOpenedByteCount: UInt64
        let actualReadByteCount: UInt64
        let decodedFileCount: Int
        let decodeWallNanoseconds: UInt64
        let decodedUTF8ByteCount: UInt64

        let uniqueHashedFileCount: Int
        let lookupHashOperationCount: Int
        let persistenceHashOperationCount: Int
        let hashedUTF8ByteCount: UInt64

        let cacheResults: [LegacyCodeMapCacheResult: Int]
        let unusableCacheReasons: [LegacyCodeMapCacheUnusableReason: Int]
        let rootCacheLoadOutcomes: [LegacyCodeMapRootCacheLoadOutcome: Int]
        let rootCacheLoadEncodedByteCount: UInt64
        let rootCacheLoadWallNanoseconds: UInt64
        let rootCacheSaveAttemptCount: Int
        let rootCacheSaveSuccessCount: Int
        let rootCacheSaveFailureCount: Int
        let rootCacheSaveEncodedByteCount: UInt64
        let rootCacheSaveEntryCount: Int
        let rootCacheSaveWallNanoseconds: UInt64

        let parseAttemptCount: Int
        let parseTerminalOutcomes: [LegacyCodeMapParseTerminalOutcome: Int]
        let parseWallNanoseconds: UInt64
        let parseThreadCPUNanoseconds: UInt64?
        let parseThreadCPUUnavailableCount: Int
        let generatorWallNanoseconds: UInt64
        let generatorThreadCPUNanoseconds: UInt64?
        let generatorThreadCPUUnavailableCount: Int
        let duplicateParseCount: Int

        let acceptedReadyPublicationCount: Int
        let droppedPublicationCount: Int

        var sourceTerminalCount: Int {
            sourceTerminalOutcomes.values.reduce(0, +)
        }

        var cacheClassificationCount: Int {
            cacheResults.values.reduce(0, +)
        }

        var rootCacheLoadAttemptCount: Int {
            rootCacheLoadOutcomes.values.reduce(0, +)
        }

        var parseTerminalCount: Int {
            parseTerminalOutcomes.values.reduce(0, +)
        }

        var publicationTerminalCount: Int {
            acceptedReadyPublicationCount + droppedPublicationCount
        }

        var cacheHitCount: Int {
            cacheResults[.memoryHit, default: 0] + cacheResults[.diskHit, default: 0]
        }

        var cacheMissCount: Int {
            cacheResults[.absentMiss, default: 0] + cacheResults[.unusableMiss, default: 0]
        }
    }

    struct LegacyCodeMapTelemetryScopeSnapshot: Equatable {
        let scope: LegacyCodeMapTelemetryScope
        let metrics: LegacyCodeMapTelemetryMetrics
    }

    struct LegacyCodeMapTelemetryConservation: Equatable {
        let issues: [String]
        var isValid: Bool {
            issues.isEmpty
        }
    }

    struct LegacyCodeMapTelemetrySnapshot: Equatable {
        let scopes: [LegacyCodeMapTelemetryScopeSnapshot]

        func metrics(
            for cohort: LegacyCodeMapTelemetryCohort,
            storeID: UUID? = nil,
            rootRole: LegacyCodeMapTelemetryRootRole? = nil
        ) -> LegacyCodeMapTelemetryMetrics? {
            let matching = scopes.filter {
                $0.scope.cohort == cohort
                    && (storeID == nil || $0.scope.storeID == storeID)
                    && (rootRole == nil || $0.scope.rootRole == rootRole)
            }
            guard matching.count == 1 else { return nil }
            return matching[0].metrics
        }

        func conservation(
            requireReadyPublications: Bool = false,
            expectedFreshMisses: Int? = nil
        ) -> LegacyCodeMapTelemetryConservation {
            var issues: [String] = []
            for snapshot in scopes {
                let scope = snapshot.scope
                let metrics = snapshot.metrics
                let prefix = "\(scope.cohort.rawValue)/\(scope.storeID.uuidString)"
                if metrics.sourceRequestCount != metrics.sourceTerminalCount {
                    issues.append("\(prefix): source requests do not balance terminals")
                }
                if metrics.parseAttemptCount != metrics.parseTerminalCount {
                    issues.append("\(prefix): parse attempts do not balance terminals")
                }
                if metrics.rootCacheSaveAttemptCount
                    != metrics.rootCacheSaveSuccessCount + metrics.rootCacheSaveFailureCount
                {
                    issues.append("\(prefix): root-cache saves do not balance outcomes")
                }
                if metrics.cacheClassificationCount > 0,
                   metrics.cacheClassificationCount == metrics.cacheHitCount,
                   metrics.parseAttemptCount != 0
                {
                    issues.append("\(prefix): all-hit cohort parsed source")
                }
                if metrics.uniqueHashedFileCount > metrics.requestedFileCount {
                    issues.append("\(prefix): unique hashed files exceed requests")
                }
                if metrics.lookupHashOperationCount != metrics.cacheClassificationCount {
                    issues.append("\(prefix): lookup hashes do not match cache classifications")
                }
                if metrics.publicationTerminalCount != metrics.cacheClassificationCount {
                    issues.append("\(prefix): publications do not match cache classifications")
                }
                if requireReadyPublications,
                   metrics.acceptedReadyPublicationCount != metrics.publicationTerminalCount
                {
                    issues.append("\(prefix): not every publication was accepted")
                }
            }
            if let expectedFreshMisses {
                let cacheMissCount = scopes.reduce(0) { $0 + $1.metrics.cacheMissCount }
                let parseAttemptCount = scopes.reduce(0) { $0 + $1.metrics.parseAttemptCount }
                if cacheMissCount != expectedFreshMisses {
                    issues.append("snapshot: fresh miss count does not match expectation")
                }
                if parseAttemptCount != expectedFreshMisses {
                    issues.append("snapshot: fresh misses do not match parse attempts")
                }
            }
            return LegacyCodeMapTelemetryConservation(issues: issues)
        }
    }

    struct LegacyCodeMapTelemetryContext {
        @TaskLocal static var current: LegacyCodeMapTelemetryContext?
        @TaskLocal static var currentOperation: LegacyCodeMapTelemetryOperation?

        let collector: LegacyCodeMapTelemetryCollector
        let sampleID: UUID
        let cohort: LegacyCodeMapTelemetryCohort
        let storeID: UUID
        let rootRole: LegacyCodeMapTelemetryRootRole

        init(
            collector: LegacyCodeMapTelemetryCollector,
            sampleID: UUID,
            cohort: LegacyCodeMapTelemetryCohort,
            storeID: UUID,
            rootRole: LegacyCodeMapTelemetryRootRole
        ) {
            self.collector = collector
            self.sampleID = sampleID
            self.cohort = cohort
            self.storeID = storeID
            self.rootRole = rootRole
        }

        func operation(fileID: UUID? = nil) -> LegacyCodeMapTelemetryOperation {
            LegacyCodeMapTelemetryOperation(
                collector: collector,
                scope: LegacyCodeMapTelemetryScope(
                    sampleID: sampleID,
                    cohort: cohort,
                    storeID: storeID,
                    rootRole: rootRole
                ),
                fileID: fileID,
                operationID: UUID()
            )
        }
    }

    struct LegacyCodeMapTelemetryOperation: @unchecked Sendable {
        fileprivate let collector: LegacyCodeMapTelemetryCollector
        let scope: LegacyCodeMapTelemetryScope
        let fileID: UUID?
        let operationID: UUID

        func recordRequested(supported: Bool) {
            collector.recordRequested(self, supported: supported)
        }

        func recordSourceRequest() {
            collector.recordSourceRequest(self)
        }

        func recordSourceOpen(nominalBytes: Int64) {
            collector.recordSourceOpen(self, nominalBytes: nominalBytes)
        }

        func recordSourceRead(bytes: Int) {
            collector.recordSourceRead(self, bytes: bytes)
        }

        func recordDecode(wallNanoseconds: UInt64, decodedUTF8Bytes: Int) {
            collector.recordDecode(self, wallNanoseconds: wallNanoseconds, decodedUTF8Bytes: decodedUTF8Bytes)
        }

        func recordSourceTerminal(_ outcome: LegacyCodeMapSourceTerminalOutcome) {
            collector.recordSourceTerminal(self, outcome: outcome)
        }

        func recordHash(kind: LegacyCodeMapHashKind, fingerprint: CodeMapContentFingerprint) {
            collector.recordHash(self, kind: kind, fingerprint: fingerprint)
        }

        func recordCacheResult(
            _ result: LegacyCodeMapCacheResult,
            unusableReason: LegacyCodeMapCacheUnusableReason? = nil
        ) {
            collector.recordCacheResult(self, result: result, unusableReason: unusableReason)
        }

        func recordRootCacheLoad(_ result: CodeMapRootCacheLoadDiagnosticResult) {
            collector.recordRootCacheLoad(self, result: result)
        }

        func recordRootCacheSave(_ result: CodeMapRootCacheSaveDiagnosticResult) {
            collector.recordRootCacheSave(self, result: result)
        }

        func recordParseAttempt(fingerprint: CodeMapContentFingerprint?) {
            collector.recordParseAttempt(self, fingerprint: fingerprint)
        }

        func recordParseTerminal(_ outcome: LegacyCodeMapParseTerminalOutcome) {
            collector.recordParseTerminal(self, outcome: outcome)
        }

        func recordParseTiming(_ timing: LegacyCodeMapTelemetryTiming.Elapsed) {
            collector.recordParseTiming(self, timing: timing)
        }

        func recordGeneratorTiming(_ timing: LegacyCodeMapTelemetryTiming.Elapsed) {
            collector.recordGeneratorTiming(self, timing: timing)
        }

        func recordPublication(accepted: Bool) {
            collector.recordPublication(self, accepted: accepted)
        }
    }

    final class LegacyCodeMapTelemetryCollector: @unchecked Sendable {
        private struct Counters {
            var requestedFileCount = 0
            var supportedFileCount = 0
            var sourceRequestCount = 0
            var sourceTerminalOutcomes: [LegacyCodeMapSourceTerminalOutcome: Int] = [:]
            var successfulOpenCount = 0
            var nominalOpenedByteCount: UInt64 = 0
            var actualReadByteCount: UInt64 = 0
            var decodedFileCount = 0
            var decodeWallNanoseconds: UInt64 = 0
            var decodedUTF8ByteCount: UInt64 = 0
            var hashedFileIDs = Set<UUID>()
            var lookupHashOperationCount = 0
            var persistenceHashOperationCount = 0
            var hashedUTF8ByteCount: UInt64 = 0
            var cacheResults: [LegacyCodeMapCacheResult: Int] = [:]
            var unusableCacheReasons: [LegacyCodeMapCacheUnusableReason: Int] = [:]
            var rootCacheLoadOutcomes: [LegacyCodeMapRootCacheLoadOutcome: Int] = [:]
            var rootCacheLoadEncodedByteCount: UInt64 = 0
            var rootCacheLoadWallNanoseconds: UInt64 = 0
            var rootCacheSaveAttemptCount = 0
            var rootCacheSaveSuccessCount = 0
            var rootCacheSaveFailureCount = 0
            var rootCacheSaveEncodedByteCount: UInt64 = 0
            var rootCacheSaveEntryCount = 0
            var rootCacheSaveWallNanoseconds: UInt64 = 0
            var parseAttemptCount = 0
            var parseTerminalOutcomes: [LegacyCodeMapParseTerminalOutcome: Int] = [:]
            var parseWallNanoseconds: UInt64 = 0
            var parseThreadCPUNanoseconds: UInt64 = 0
            var parseThreadCPUUnavailableCount = 0
            var generatorWallNanoseconds: UInt64 = 0
            var generatorThreadCPUNanoseconds: UInt64 = 0
            var generatorThreadCPUUnavailableCount = 0
            var duplicateParseCount = 0
            var acceptedReadyPublicationCount = 0
            var droppedPublicationCount = 0
        }

        private let lock = NSLock()
        private var countersByScope: [LegacyCodeMapTelemetryScope: Counters] = [:]
        private var sourceRequestOperationIDs = Set<UUID>()
        private var sourceTerminalOperationIDs = Set<UUID>()
        private var parseAttemptOperationIDs = Set<UUID>()
        private var parseTerminalOperationIDs = Set<UUID>()
        private var parsedFingerprintsBySampleID: [UUID: Set<String>] = [:]

        func snapshot() -> LegacyCodeMapTelemetrySnapshot {
            withLock {
                LegacyCodeMapTelemetrySnapshot(scopes: countersByScope.map { scope, counters in
                    LegacyCodeMapTelemetryScopeSnapshot(scope: scope, metrics: makeMetrics(counters))
                }.sorted {
                    ($0.scope.cohort.rawValue, $0.scope.storeID.uuidString, $0.scope.rootRole.rawValue)
                        < ($1.scope.cohort.rawValue, $1.scope.storeID.uuidString, $1.scope.rootRole.rawValue)
                })
            }
        }

        fileprivate func recordRequested(_ operation: LegacyCodeMapTelemetryOperation, supported: Bool) {
            update(operation) {
                $0.requestedFileCount += 1
                if supported { $0.supportedFileCount += 1 }
            }
        }

        fileprivate func recordSourceRequest(_ operation: LegacyCodeMapTelemetryOperation) {
            withLock {
                guard sourceRequestOperationIDs.insert(operation.operationID).inserted else { return }
                countersByScope[operation.scope, default: Counters()].sourceRequestCount += 1
            }
        }

        fileprivate func recordSourceOpen(_ operation: LegacyCodeMapTelemetryOperation, nominalBytes: Int64) {
            update(operation) {
                $0.successfulOpenCount += 1
                $0.nominalOpenedByteCount &+= UInt64(max(0, nominalBytes))
            }
        }

        fileprivate func recordSourceRead(_ operation: LegacyCodeMapTelemetryOperation, bytes: Int) {
            update(operation) { $0.actualReadByteCount &+= UInt64(max(0, bytes)) }
        }

        fileprivate func recordDecode(
            _ operation: LegacyCodeMapTelemetryOperation,
            wallNanoseconds: UInt64,
            decodedUTF8Bytes: Int
        ) {
            update(operation) {
                $0.decodedFileCount += 1
                $0.decodeWallNanoseconds &+= wallNanoseconds
                $0.decodedUTF8ByteCount &+= UInt64(max(0, decodedUTF8Bytes))
            }
        }

        fileprivate func recordSourceTerminal(
            _ operation: LegacyCodeMapTelemetryOperation,
            outcome: LegacyCodeMapSourceTerminalOutcome
        ) {
            withLock {
                guard sourceTerminalOperationIDs.insert(operation.operationID).inserted else { return }
                countersByScope[operation.scope, default: Counters()].sourceTerminalOutcomes[outcome, default: 0] += 1
            }
        }

        fileprivate func recordHash(
            _ operation: LegacyCodeMapTelemetryOperation,
            kind: LegacyCodeMapHashKind,
            fingerprint: CodeMapContentFingerprint
        ) {
            update(operation) {
                if let fileID = operation.fileID { $0.hashedFileIDs.insert(fileID) }
                switch kind {
                case .lookup: $0.lookupHashOperationCount += 1
                case .persistence: $0.persistenceHashOperationCount += 1
                }
                $0.hashedUTF8ByteCount &+= UInt64(max(0, fingerprint.byteCount))
            }
        }

        fileprivate func recordCacheResult(
            _ operation: LegacyCodeMapTelemetryOperation,
            result: LegacyCodeMapCacheResult,
            unusableReason: LegacyCodeMapCacheUnusableReason?
        ) {
            update(operation) {
                $0.cacheResults[result, default: 0] += 1
                if let unusableReason { $0.unusableCacheReasons[unusableReason, default: 0] += 1 }
            }
        }

        fileprivate func recordRootCacheLoad(
            _ operation: LegacyCodeMapTelemetryOperation,
            result: CodeMapRootCacheLoadDiagnosticResult
        ) {
            update(operation) {
                $0.rootCacheLoadOutcomes[result.outcome, default: 0] += 1
                $0.rootCacheLoadEncodedByteCount &+= UInt64(max(0, result.encodedByteCount))
                $0.rootCacheLoadWallNanoseconds &+= result.durationNanoseconds
            }
        }

        fileprivate func recordRootCacheSave(
            _ operation: LegacyCodeMapTelemetryOperation,
            result: CodeMapRootCacheSaveDiagnosticResult
        ) {
            update(operation) {
                $0.rootCacheSaveAttemptCount += 1
                if result.success { $0.rootCacheSaveSuccessCount += 1 } else { $0.rootCacheSaveFailureCount += 1 }
                $0.rootCacheSaveEncodedByteCount &+= UInt64(max(0, result.encodedByteCount))
                $0.rootCacheSaveEntryCount += result.entryCount
                $0.rootCacheSaveWallNanoseconds &+= result.durationNanoseconds
            }
        }

        fileprivate func recordParseAttempt(
            _ operation: LegacyCodeMapTelemetryOperation,
            fingerprint: CodeMapContentFingerprint?
        ) {
            withLock {
                guard parseAttemptOperationIDs.insert(operation.operationID).inserted else { return }
                var counters = countersByScope[operation.scope, default: Counters()]
                counters.parseAttemptCount += 1
                if let fingerprint,
                   !parsedFingerprintsBySampleID[operation.scope.sampleID, default: []]
                   .insert(fingerprint.contentHash).inserted
                {
                    counters.duplicateParseCount += 1
                }
                countersByScope[operation.scope] = counters
            }
        }

        fileprivate func recordParseTerminal(
            _ operation: LegacyCodeMapTelemetryOperation,
            outcome: LegacyCodeMapParseTerminalOutcome
        ) {
            withLock {
                guard parseTerminalOperationIDs.insert(operation.operationID).inserted else { return }
                countersByScope[operation.scope, default: Counters()].parseTerminalOutcomes[outcome, default: 0] += 1
            }
        }

        fileprivate func recordParseTiming(
            _ operation: LegacyCodeMapTelemetryOperation,
            timing: LegacyCodeMapTelemetryTiming.Elapsed
        ) {
            update(operation) {
                $0.parseWallNanoseconds &+= timing.wallNanoseconds
                if let cpu = timing.threadCPUNanoseconds {
                    $0.parseThreadCPUNanoseconds &+= cpu
                } else {
                    $0.parseThreadCPUUnavailableCount += 1
                }
            }
        }

        fileprivate func recordGeneratorTiming(
            _ operation: LegacyCodeMapTelemetryOperation,
            timing: LegacyCodeMapTelemetryTiming.Elapsed
        ) {
            update(operation) {
                $0.generatorWallNanoseconds &+= timing.wallNanoseconds
                if let cpu = timing.threadCPUNanoseconds {
                    $0.generatorThreadCPUNanoseconds &+= cpu
                } else {
                    $0.generatorThreadCPUUnavailableCount += 1
                }
            }
        }

        fileprivate func recordPublication(_ operation: LegacyCodeMapTelemetryOperation, accepted: Bool) {
            update(operation) {
                if accepted { $0.acceptedReadyPublicationCount += 1 } else { $0.droppedPublicationCount += 1 }
            }
        }

        private func update(_ operation: LegacyCodeMapTelemetryOperation, _ body: (inout Counters) -> Void) {
            withLock { body(&countersByScope[operation.scope, default: Counters()]) }
        }

        private func makeMetrics(_ counters: Counters) -> LegacyCodeMapTelemetryMetrics {
            LegacyCodeMapTelemetryMetrics(
                requestedFileCount: counters.requestedFileCount,
                supportedFileCount: counters.supportedFileCount,
                sourceRequestCount: counters.sourceRequestCount,
                sourceTerminalOutcomes: counters.sourceTerminalOutcomes,
                successfulOpenCount: counters.successfulOpenCount,
                nominalOpenedByteCount: counters.nominalOpenedByteCount,
                actualReadByteCount: counters.actualReadByteCount,
                decodedFileCount: counters.decodedFileCount,
                decodeWallNanoseconds: counters.decodeWallNanoseconds,
                decodedUTF8ByteCount: counters.decodedUTF8ByteCount,
                uniqueHashedFileCount: counters.hashedFileIDs.count,
                lookupHashOperationCount: counters.lookupHashOperationCount,
                persistenceHashOperationCount: counters.persistenceHashOperationCount,
                hashedUTF8ByteCount: counters.hashedUTF8ByteCount,
                cacheResults: counters.cacheResults,
                unusableCacheReasons: counters.unusableCacheReasons,
                rootCacheLoadOutcomes: counters.rootCacheLoadOutcomes,
                rootCacheLoadEncodedByteCount: counters.rootCacheLoadEncodedByteCount,
                rootCacheLoadWallNanoseconds: counters.rootCacheLoadWallNanoseconds,
                rootCacheSaveAttemptCount: counters.rootCacheSaveAttemptCount,
                rootCacheSaveSuccessCount: counters.rootCacheSaveSuccessCount,
                rootCacheSaveFailureCount: counters.rootCacheSaveFailureCount,
                rootCacheSaveEncodedByteCount: counters.rootCacheSaveEncodedByteCount,
                rootCacheSaveEntryCount: counters.rootCacheSaveEntryCount,
                rootCacheSaveWallNanoseconds: counters.rootCacheSaveWallNanoseconds,
                parseAttemptCount: counters.parseAttemptCount,
                parseTerminalOutcomes: counters.parseTerminalOutcomes,
                parseWallNanoseconds: counters.parseWallNanoseconds,
                parseThreadCPUNanoseconds: counters.parseThreadCPUUnavailableCount == 0 ? counters.parseThreadCPUNanoseconds : nil,
                parseThreadCPUUnavailableCount: counters.parseThreadCPUUnavailableCount,
                generatorWallNanoseconds: counters.generatorWallNanoseconds,
                generatorThreadCPUNanoseconds: counters.generatorThreadCPUUnavailableCount == 0 ? counters.generatorThreadCPUNanoseconds : nil,
                generatorThreadCPUUnavailableCount: counters.generatorThreadCPUUnavailableCount,
                duplicateParseCount: counters.duplicateParseCount,
                acceptedReadyPublicationCount: counters.acceptedReadyPublicationCount,
                droppedPublicationCount: counters.droppedPublicationCount
            )
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    enum LegacyCodeMapTelemetryTiming {
        struct Start {
            let wallNanoseconds: UInt64
            let threadCPUNanoseconds: UInt64?
        }

        struct Elapsed {
            let wallNanoseconds: UInt64
            let threadCPUNanoseconds: UInt64?
        }

        static func start() -> Start {
            Start(
                wallNanoseconds: DispatchTime.now().uptimeNanoseconds,
                threadCPUNanoseconds: currentThreadCPUNanoseconds()
            )
        }

        static func elapsed(since start: Start) -> Elapsed {
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            let cpuEnd = currentThreadCPUNanoseconds()
            return Elapsed(
                wallNanoseconds: wallEnd >= start.wallNanoseconds ? wallEnd - start.wallNanoseconds : 0,
                threadCPUNanoseconds: start.threadCPUNanoseconds.flatMap { cpuStart in
                    cpuEnd.map { $0 >= cpuStart ? $0 - cpuStart : 0 }
                }
            )
        }

        private static func currentThreadCPUNanoseconds() -> UInt64? {
            #if canImport(Darwin)
                var info = thread_basic_info_data_t()
                var count = mach_msg_type_number_t(
                    MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
                )
                let thread = mach_thread_self()
                defer { mach_port_deallocate(mach_task_self_, thread) }
                let result = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                    }
                }
                guard result == KERN_SUCCESS else { return nil }
                let user = UInt64(info.user_time.seconds) * 1_000_000_000 + UInt64(info.user_time.microseconds) * 1000
                let system = UInt64(info.system_time.seconds) * 1_000_000_000 + UInt64(info.system_time.microseconds) * 1000
                return user &+ system
            #else
                return nil
            #endif
        }
    }
#endif
