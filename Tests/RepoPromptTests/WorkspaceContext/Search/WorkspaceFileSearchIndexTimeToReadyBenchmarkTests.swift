import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorkspaceFileSearchIndexTimeToReadyBenchmarkTests: XCTestCase {
        private struct BenchmarkInvariantError: Error {
            let message: String
        }

        private struct CodemapConvergenceMilestones {
            let firstMilliseconds: Double?
            let quarterMilliseconds: Double?
            let halfMilliseconds: Double?
            let threeQuarterMilliseconds: Double?
            let allMilliseconds: Double?
        }

        private actor CodemapConvergenceRecorder {
            private let supportedFileCount: Int
            private var readyFileIDs: Set<UUID> = []
            private var firstMilliseconds: Double?
            private var quarterMilliseconds: Double?
            private var halfMilliseconds: Double?
            private var threeQuarterMilliseconds: Double?
            private var allMilliseconds: Double?

            init(supportedFileCount: Int) {
                self.supportedFileCount = supportedFileCount
            }

            func record(fileIDs: [UUID], elapsedMilliseconds: Double) -> Bool {
                readyFileIDs.formUnion(fileIDs)
                if firstMilliseconds == nil, readyFileIDs.count >= 1 {
                    firstMilliseconds = elapsedMilliseconds
                }
                if quarterMilliseconds == nil, readyFileIDs.count >= supportedFileCount / 4 {
                    quarterMilliseconds = elapsedMilliseconds
                }
                if halfMilliseconds == nil, readyFileIDs.count >= supportedFileCount / 2 {
                    halfMilliseconds = elapsedMilliseconds
                }
                if threeQuarterMilliseconds == nil, readyFileIDs.count >= supportedFileCount * 3 / 4 {
                    threeQuarterMilliseconds = elapsedMilliseconds
                }
                if allMilliseconds == nil, readyFileIDs.count >= supportedFileCount {
                    allMilliseconds = elapsedMilliseconds
                }
                return allMilliseconds != nil
            }

            func snapshot() -> CodemapConvergenceMilestones {
                CodemapConvergenceMilestones(
                    firstMilliseconds: firstMilliseconds,
                    quarterMilliseconds: quarterMilliseconds,
                    halfMilliseconds: halfMilliseconds,
                    threeQuarterMilliseconds: threeQuarterMilliseconds,
                    allMilliseconds: allMilliseconds
                )
            }
        }

        private struct CodemapQuiescenceWait {
            let snapshot: WorkspaceFileContextStore.CodemapQuiescenceSnapshot
            let timedOut: Bool
        }

        private struct Phase2SynchronousMeasurement<Value> {
            let value: Value
            let wallMilliseconds: Double
            let threadCPUMilliseconds: Double?
        }

        func testFallbackReasonDeltaRenderingIsDeterministic() throws {
            let rootID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
            let lifetimeID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
            let counters = WorkspaceFileSearchIndexBenchmarkCounters(
                rootID: rootID,
                lifetimeID: lifetimeID,
                topologyGeneration: 42,
                crawl: 1,
                appliedGeneration: 1,
                shardBuild: 4,
                patch: 1,
                authoritative: 3,
                pathIndexBuild: 2,
                overlayPathIndexBuild: 1,
                fallback: 4,
                fallbackReasonDeltas: [
                    .shadowValidationMismatch: 1,
                    .fullResync: 0,
                    .patchApplicationBackstop: 1,
                    .generationGap: 2
                ],
                catalogRebuild: 3,
                catalogInvalidation: 2
            )

            XCTAssertEqual(
                WorkspaceFileContextStore.RootCatalogShardFallbackReason.allCases.map(\.rawValue),
                [
                    "missingReusableShard",
                    "generationGap",
                    "fullResync",
                    "unsafeOrAmbiguousBatch",
                    "retentionBoundary",
                    "patchThresholdExceeded",
                    "patchApplicationBackstop",
                    "shadowValidationMismatch"
                ]
            )
            XCTAssertTrue(counters.fallbackReasonDeltasAreNonnegative)
            XCTAssertEqual(counters.fallbackReasonDeltaSum, counters.fallback)
            XCTAssertEqual(
                counters.fallbackDiagnosticDescription(),
                "rootID=11111111-2222-3333-4444-555555555555, "
                    + "lifetimeID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, topology generation=42; "
                    + "fallback Δ=4; reasons=[generationGap=2, patchApplicationBackstop=1, shadowValidationMismatch=1]; "
                    + "crawl=1 shard=4 patch=1 authoritative=3 full=2 overlay=1"
            )
        }

        func testLargeRepositoryTimeToReadyBenchmark() async throws {
            let metricsEnabled = WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration.isEnabled(
                environmentKey: "RP_RUN_FILE_SEARCH_INDEX_METRICS",
                configurationKey: "metricsEnabled"
            )
            let sortDiagnosticsEnabled = WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration.isEnabled(
                environmentKey: "RP_RUN_FILE_SEARCH_INDEX_SORT_DIAGNOSTICS",
                configurationKey: "sortDiagnosticsEnabled"
            )
            try XCTSkipUnless(
                metricsEnabled
                    || WorkspaceFileSearchIndexBenchmarkRun.reportURLFromEnvironment != nil
                    || FileManager.default.fileExists(atPath: "/tmp/RepoPromptCE-file-search-index-opt-in"),
                "CE file-search index benchmark is opt-in. Set RP_RUN_FILE_SEARCH_INDEX_METRICS=1, RP_CE_FILE_SEARCH_INDEX_REPORT_PATH, or create /tmp/RepoPromptCE-file-search-index-opt-in."
            )
            if let reportURL = WorkspaceFileSearchIndexBenchmarkRun.reportURLFromEnvironment {
                try require(
                    !FileManager.default.fileExists(atPath: reportURL.path),
                    "Benchmark report path already exists; raw reports are exclusive and non-overwriting"
                )
            }

            let fixture = try WorkspaceFileSearchIndexBenchmarkFixture.make()
            defer { fixture.remove() }
            let environment = WorkspaceFileSearchIndexBenchmarkEnvironment.capture()
            let coldWorktree = try await runColdWorktreeScenario(fixture: fixture)
            let productionEquivalent = try await runProductionEquivalentScenario()
            let incrementalRebuild = try await runIncrementalRebuildScenario(fixture: fixture)
            let sortDiagnostic: WorkspaceFileSearchIndexSortDiagnostic? = if metricsEnabled, sortDiagnosticsEnabled {
                try await runSortAttributionProbe()
            } else {
                nil
            }
            let legacyCodemap = try await runLegacyCodemapScenarios()
            let phase2Model = try await runPhase2ModelScenario()
            let phase3Storage = try await runPhase3StorageScenario()
            let phase4GitIdentityLocator = try await runPhase4GitIdentityLocatorScenario()
            let phase5Coordinator = try await runPhase5CoordinatorScenario()
            let run = WorkspaceFileSearchIndexBenchmarkRun(
                environment: environment,
                coldWorktree: coldWorktree,
                productionEquivalent: productionEquivalent,
                incrementalRebuild: incrementalRebuild,
                legacyCodemap: legacyCodemap,
                phase2Model: phase2Model,
                phase3Storage: phase3Storage,
                phase4GitIdentityLocator: phase4GitIdentityLocator,
                phase5Coordinator: phase5Coordinator,
                sortDiagnostic: sortDiagnostic
            )
            try print(run.consoleReport())
            if let reportURL = WorkspaceFileSearchIndexBenchmarkRun.reportURLFromEnvironment {
                try run.writeMarkdownExclusively(to: reportURL)
            }
        }

        private func runColdWorktreeScenario(
            fixture: WorkspaceFileSearchIndexBenchmarkFixture
        ) async throws -> WorkspaceFileSearchIndexBenchmarkAggregate {
            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            addTeardownBlock { await self.unloadAllRoots(in: store) }
            let visibleRoot = try await store.loadRoot(path: fixture.visibleRootURL.path)
            await store.stopWatchingRoot(id: visibleRoot.id)
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)

            var warmup: WorkspaceFileSearchIndexBenchmarkSample?
            var measured: [WorkspaceFileSearchIndexBenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = try await runColdWorktreeSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured",
                    fixture: fixture,
                    visibleRoot: visibleRoot,
                    store: store,
                    materializer: materializer
                )
                if isWarmup {
                    warmup = sample
                } else {
                    measured.append(sample)
                }
            }
            await unloadAllRoots(in: store)
            return try WorkspaceFileSearchIndexBenchmarkAggregate(
                scenario: "cold-worktree-first-scoped-search",
                warmup: XCTUnwrap(warmup),
                measured: measured
            )
        }

        private func runColdWorktreeSample(
            ordinal: Int,
            phase: String,
            fixture: WorkspaceFileSearchIndexBenchmarkFixture,
            visibleRoot: WorkspaceRootRecord,
            store: WorkspaceFileContextStore,
            materializer: WorkspaceRootBindingProjectionMaterializer
        ) async throws -> WorkspaceFileSearchIndexBenchmarkSample {
            let worktreePath = fixture.worktreeRootURL.standardizedFileURL.path
            let rootsBefore = await store.roots()
            try require(!rootsBefore.contains { $0.standardizedFullPath == worktreePath }, "Worktree must be unloaded before a cold sample")
            let ownershipBefore = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            try require(ownershipBefore.installedOwnerCount == 0, "Cold sample must begin without installed ownership")
            try require(ownershipBefore.provisionalOwnerCount == 0, "Cold sample must begin without provisional ownership")
            try require(ownershipBefore.rootClaimCount == 0, "Cold sample must begin without worktree claims")

            let sessionID = UUID()
            let binding = AgentSessionWorktreeBinding(
                id: "file-search-benchmark-\(sessionID.uuidString)",
                repositoryID: "file-search-benchmark-repository",
                repoKey: "file-search-benchmark",
                logicalRootPath: visibleRoot.standardizedFullPath,
                logicalRootName: visibleRoot.name,
                worktreeID: "file-search-benchmark-\(ordinal)-\(sessionID.uuidString)",
                worktreeRootPath: worktreePath,
                worktreeName: fixture.worktreeRootURL.lastPathComponent,
                source: "file_search_index_benchmark"
            )
            let before = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(store: store)
            let started = DispatchTime.now()
            let preparation = try await materializer.prepare(sessionID: sessionID, bindings: [binding])

            do {
                let committedProjection = try await materializer.commit(preparation)
                let projection = try XCTUnwrap(committedProjection)
                let materialized = DispatchTime.now()
                let phaseCollector = WorkspaceFileSearchPhaseCollector()
                let result = try await WorkspaceFileSearchDebugContext.$collector.withValue(phaseCollector) {
                    try await StoreBackedWorkspaceSearch.search(
                        pattern: "FirstScopedNeedle",
                        mode: .path,
                        maxPaths: 1,
                        rootScope: projection.lookupRootScope,
                        store: store,
                        workspaceManager: nil
                    )
                }
                let finished = DispatchTime.now()
                let phases = phaseCollector.snapshot(
                    readySearchNanoseconds: finished.uptimeNanoseconds - materialized.uptimeNanoseconds
                )
                let physicalRootID = try XCTUnwrap(projection.physicalRootRefs.first?.id)
                let snapshot = await store.searchCatalogSnapshot(
                    rootScope: projection.lookupRootScope,
                    requirement: .recordsOnly
                )
                let after = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(
                    store: store,
                    rootID: physicalRootID
                )
                let counters = after.delta(from: before)

                try require(projection.isFullyMaterialized, "Cold projection must be fully materialized")
                try require(phases.status == .completed, "Cold phase collector must complete")
                try require(result.paths == [fixture.firstScopedNeedleURL.path], "Cold search must return the worktree needle")
                try require(!(result.paths?.contains { $0.hasPrefix(fixture.visibleRootURL.path) } ?? false), "Cold search must not substitute the visible root")
                try require(snapshot.diagnostics.fileCount == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount, "Cold snapshot file count must match the fixture")
                try require(snapshot.diagnostics.folderCount == WorkspaceFileSearchIndexBenchmarkFixture.folderCount, "Cold snapshot folder count must match the fixture")
                try require(counters.crawl == 1, "Cold sample must perform one crawl")
                try require(counters.shardBuild == 1, "Cold sample must build one shard")
                try require(counters.patch == 0, "Cold sample must not patch a shard")
                try require(counters.authoritative == 1, "Cold sample must perform one authoritative shard build")
                try require(counters.pathIndexBuild == 0, "Cold sample must not build a full path index")
                try require(counters.overlayPathIndexBuild == 0, "Cold sample must not build an overlay")
                try require(phases.catalog.pathIndexKeyMicroseconds == 0, "Cold path-index key phase must be zero")
                try require(
                    phases.catalog.pathIndexConstructionMicroseconds == 0,
                    "Cold path-index construction phase must be zero"
                )
                try require(
                    coldCounterVectorIsValid(counters, pathIndexBuild: 0),
                    "Cold counter vector must match the records-only contract with at most one watcher-applied generation",
                    diagnostics: "actual=\(counterVector(counters))"
                )
                let fallbackDiagnostics = counters.fallbackDiagnosticDescription()
                try require(
                    counters.fallbackReasonDeltasAreNonnegative,
                    "Cold fallback reason deltas must not be negative; \(fallbackDiagnostics)"
                )
                try require(
                    counters.fallback == counters.fallbackReasonDeltaSum,
                    "Cold aggregate fallback delta must equal the reason delta sum; \(fallbackDiagnostics)"
                )
                try require(
                    counters.fallback == 0,
                    "Cold sample must not fall back",
                    diagnostics: fallbackDiagnostics
                )

                await materializer.release(sessionID: sessionID)
                let rootsAfter = await store.roots()
                try require(!rootsAfter.contains { $0.id == physicalRootID }, "Released worktree must unload before the next sample")
                let ownershipAfter = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
                try require(ownershipAfter.installedOwnerCount == 0, "Released sample must clear installed ownership")
                try require(ownershipAfter.rootClaimCount == 0, "Released sample must clear worktree claims")

                return WorkspaceFileSearchIndexBenchmarkSample(
                    ordinal: ordinal,
                    phase: phase,
                    totalWallMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: finished),
                    preSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: materialized),
                    searchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: materialized, to: finished),
                    cumulativeSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: finished),
                    readMilliseconds: 0,
                    counters: counters,
                    phases: phases,
                    coldStart: nil
                )
            } catch {
                await materializer.abort(preparation)
                await materializer.release(sessionID: sessionID)
                throw error
            }
        }

        private func runProductionEquivalentScenario() async throws -> WorkspaceFileSearchIndexBenchmarkAggregate {
            var warmup: WorkspaceFileSearchIndexBenchmarkSample?
            var measured: [WorkspaceFileSearchIndexBenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = try await runProductionEquivalentSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured"
                )
                if isWarmup {
                    warmup = sample
                } else {
                    measured.append(sample)
                }
            }
            return try WorkspaceFileSearchIndexBenchmarkAggregate(
                scenario: "materialize-first-scoped-content-search-first-read",
                warmup: XCTUnwrap(warmup),
                measured: measured
            )
        }

        private func runProductionEquivalentSample(
            ordinal: Int,
            phase: String
        ) async throws -> WorkspaceFileSearchIndexBenchmarkSample {
            let fixture = try WorkspaceFileSearchIndexBenchmarkFixture.make()
            defer { fixture.remove() }
            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            addTeardownBlock { await self.unloadAllRoots(in: store) }
            let visibleRoot = try await store.loadRoot(path: fixture.visibleRootURL.path)
            await store.stopWatchingRoot(id: visibleRoot.id)
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            let worktreePath = fixture.worktreeRootURL.standardizedFileURL.path
            let rootsBefore = await store.roots()
            try require(
                !rootsBefore.contains { $0.standardizedFullPath == worktreePath },
                "Production-equivalent sample must start with the worktree unloaded"
            )
            let ownershipBefore = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            try require(ownershipBefore.installedOwnerCount == 0, "Sample must begin without installed ownership")
            try require(ownershipBefore.provisionalOwnerCount == 0, "Sample must begin without provisional ownership")
            try require(ownershipBefore.rootClaimCount == 0, "Sample must begin without worktree claims")

            let sessionID = UUID()
            let binding = AgentSessionWorktreeBinding(
                id: "file-tools-benchmark-\(sessionID.uuidString)",
                repositoryID: "file-tools-benchmark-repository",
                repoKey: "file-tools-benchmark",
                logicalRootPath: visibleRoot.standardizedFullPath,
                logicalRootName: visibleRoot.name,
                worktreeID: "file-tools-benchmark-\(ordinal)-\(sessionID.uuidString)",
                worktreeRootPath: worktreePath,
                worktreeName: fixture.worktreeRootURL.lastPathComponent,
                source: "file_tools_benchmark"
            )
            let before = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(store: store)
            let limiterBefore = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            let coldStartCollector = WorkspaceFileSearchColdStartCollector()
            let searchPhaseCollector = WorkspaceFileSearchPhaseCollector()
            let started = DispatchTime.now()

            do {
                let workload = try await WorkspaceFileSearchDebugContext.$coldStartCollector.withValue(coldStartCollector) {
                    let maybeProjection = await materializer.materialize(sessionID: sessionID, bindings: [binding])
                    let projection = try XCTUnwrap(maybeProjection)
                    let materialized = DispatchTime.now()
                    let searchResult = try await WorkspaceFileSearchDebugContext.$collector.withValue(searchPhaseCollector) {
                        try await StoreBackedWorkspaceSearch.search(
                            pattern: WorkspaceFileSearchIndexBenchmarkFixture.firstScopedContentNeedle,
                            mode: .content,
                            maxPaths: 1,
                            rootScope: projection.lookupRootScope,
                            store: store,
                            workspaceManager: nil
                        )
                    }
                    let searchFinished = DispatchTime.now()

                    let logicalNeedlePath = fixture.visibleRootURL
                        .appendingPathComponent(WorkspaceFileSearchIndexBenchmarkFixture.firstScopedNeedleRelativePath)
                        .path
                    let physicalReadPath = projection.translateInputPath(logicalNeedlePath)
                    let readableService = WorkspaceReadableFileService(store: store)
                    let roots = await store.rootRefs(scope: projection.lookupRootScope)
                    try await readableService.awaitFreshnessForExplicitRequest(physicalReadPath, rootRefs: roots)
                    let resolution = await readableService.resolveReadFileRequest(
                        physicalReadPath,
                        profile: .mcpRead,
                        rootScope: projection.lookupRootScope,
                        rootRefs: roots
                    )
                    guard case let .readable(.workspace(file)) = resolution else {
                        throw BenchmarkInvariantError(message: "Production-equivalent read must resolve the scoped worktree file")
                    }
                    guard let readSnapshot = try await store.interactiveReadSnapshot(for: file) else {
                        throw BenchmarkInvariantError(message: "Production-equivalent read content must be available")
                    }
                    let readFinished = DispatchTime.now()
                    let coldStartAtReadCompletion = coldStartCollector.snapshot()
                    return (
                        projection: projection,
                        materialized: materialized,
                        searchResult: searchResult,
                        searchFinished: searchFinished,
                        readFile: file,
                        readContent: readSnapshot.preparedContent.linesWithEndings.joined(),
                        readFinished: readFinished,
                        coldStart: coldStartAtReadCompletion
                    )
                }

                let searchPhases = searchPhaseCollector.snapshot(
                    readySearchNanoseconds: workload.searchFinished.uptimeNanoseconds - workload.materialized.uptimeNanoseconds
                )
                let physicalRootID = try XCTUnwrap(workload.projection.physicalRootRefs.first?.id)
                let after = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(
                    store: store,
                    rootID: physicalRootID
                )
                let counters = after.delta(from: before)
                let limiterAfter = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
                let catalogSnapshot = await store.searchCatalogSnapshot(
                    rootScope: workload.projection.lookupRootScope,
                    requirement: .recordsOnly
                )

                try require(workload.projection.isFullyMaterialized, "Production materializer must produce a fully materialized projection")
                try require(
                    limiterAfter.codemapGrantWhileForegroundCount == limiterBefore.codemapGrantWhileForegroundCount,
                    "Production-equivalent foreground boundaries must not grant codemap permits"
                )
                try require(limiterAfter.foregroundActivityCount == 0, "Foreground activity tokens must be balanced at first-read completion")
                try require(searchPhases.status == .completed, "Content-search phase collector must complete")
                try require(
                    workload.searchResult.matches?.map(\.filePath) == [fixture.firstScopedNeedleURL.path],
                    "Scoped content search must return only the physical worktree needle"
                )
                try require(
                    !(workload.searchResult.matches?.contains { $0.filePath.hasPrefix(fixture.visibleRootURL.path) } ?? false),
                    "Scoped content search must not fall back to the canonical visible root"
                )
                try require(
                    workload.projection.logicalDisplayPath(forPhysicalPath: workload.readFile.standardizedFullPath, display: .full)
                        == fixture.visibleRootURL
                        .appendingPathComponent(WorkspaceFileSearchIndexBenchmarkFixture.firstScopedNeedleRelativePath)
                        .path,
                    "Physical worktree reads must retain the logical display projection"
                )
                try require(
                    workload.readContent == WorkspaceFileSearchIndexBenchmarkFixture.firstScopedNeedleContents,
                    "First read must return the exact worktree-only content"
                )
                try require(catalogSnapshot.diagnostics.fileCount == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount, "Scoped catalog file count must match the fixture")
                try require(counters.crawl == 1, "Production-equivalent sample must perform one crawl")
                try require(counters.shardBuild == 1, "Production-equivalent sample must build one shard")
                try require(counters.patch == 0, "Production-equivalent sample must not patch a shard")
                try require(counters.authoritative == 1, "Production-equivalent sample must perform one authoritative shard build")
                try require(counters.pathIndexBuild == 1, "Current content search must build one full path index")
                try require(counters.overlayPathIndexBuild == 0, "Cold content search must not build an overlay")
                try require(
                    coldCounterVectorIsValid(counters, pathIndexBuild: 1),
                    "Production-equivalent counter vector must match current content-search behavior with at most one watcher-applied generation"
                )
                try require(counters.fallback == 0, "Production-equivalent sample must not fall back", diagnostics: counters.fallbackDiagnosticDescription())

                await materializer.release(sessionID: sessionID)
                let rootsAfter = await store.roots()
                try require(!rootsAfter.contains { $0.id == physicalRootID }, "Released production-equivalent worktree must unload")
                let ownershipAfter = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
                try require(ownershipAfter.installedOwnerCount == 0, "Released sample must clear installed ownership")
                try require(ownershipAfter.provisionalOwnerCount == 0, "Released sample must clear provisional ownership")
                try require(ownershipAfter.rootClaimCount == 0, "Released sample must clear worktree claims")
                await unloadAllRoots(in: store)

                let coldStart = workload.coldStart
                try require(coldStart.rootCrawl.count == 1, "Cold-start attribution must contain exactly one root crawl")
                try require(
                    coldStart.rootCrawl.filesDiscovered == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount,
                    "Cold-start crawl attribution must count every fixture file"
                )
                for workloadName in [ContentReadWorkloadClass.contentSearch.rawValue, ContentReadWorkloadClass.interactiveRead.rawValue] {
                    let scheduler = try XCTUnwrap(coldStart.schedulerByWorkload[workloadName])
                    try require(scheduler.requestCount > 0, "Foreground scheduler attribution must include \(workloadName)")
                    try require(scheduler.requestCount == scheduler.grantCount, "Foreground scheduler grants must match requests for \(workloadName)")
                    try require(scheduler.requestCount == scheduler.completionCount, "Foreground scheduler completions must match requests for \(workloadName)")
                    try require(scheduler.cancellationCount == 0, "Foreground scheduler work must not be cancelled for \(workloadName)")
                    try require(scheduler.failureCount == 0, "Foreground scheduler work must not fail for \(workloadName)")
                }

                return WorkspaceFileSearchIndexBenchmarkSample(
                    ordinal: ordinal,
                    phase: phase,
                    totalWallMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: workload.readFinished),
                    preSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: workload.materialized),
                    searchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: workload.materialized, to: workload.searchFinished),
                    cumulativeSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: workload.searchFinished),
                    readMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: workload.searchFinished, to: workload.readFinished),
                    counters: counters,
                    phases: searchPhases,
                    coldStart: coldStart
                )
            } catch {
                await materializer.release(sessionID: sessionID)
                await unloadAllRoots(in: store)
                throw error
            }
        }

        private func runIncrementalRebuildScenario(
            fixture: WorkspaceFileSearchIndexBenchmarkFixture
        ) async throws -> WorkspaceFileSearchIndexBenchmarkAggregate {
            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            addTeardownBlock { await self.unloadAllRoots(in: store) }
            let visibleRoot = try await store.loadRoot(path: fixture.visibleRootURL.path)
            await store.stopWatchingRoot(id: visibleRoot.id)
            let worktreeRoot = try await store.loadRoot(path: fixture.worktreeRootURL.path, kind: .sessionWorktree)
            try await store.startWatchingRoot(id: worktreeRoot.id)
            let loadedService = await store.fileSystemServiceForTesting(rootID: worktreeRoot.id)
            let service = try XCTUnwrap(loadedService)
            await service.stopWatchingForChanges()
            _ = await store.awaitAppliedIngressForAllRoots()
            let watcherIsActive = try await store.rootWatcherIsActiveForTesting(rootID: worktreeRoot.id)
            try require(!watcherIsActive, "Incremental scenario must exclude live FSEvents")

            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [fixture.worktreeRootURL.standardizedFileURL.path]
            )
            _ = await store.searchCatalogSnapshot(rootScope: scope, requirement: .recordsOnly)
            let initialResult = try await StoreBackedWorkspaceSearch.search(
                pattern: "FirstScopedNeedle",
                mode: .path,
                maxPaths: 1,
                rootScope: scope,
                store: store,
                workspaceManager: nil
            )
            try require(initialResult.paths == [fixture.firstScopedNeedleURL.path], "Incremental scenario warm search must find the seed needle")

            var warmup: WorkspaceFileSearchIndexBenchmarkSample?
            var measured: [WorkspaceFileSearchIndexBenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let relativePath = isWarmup
                    ? "IncrementalNeedle-Warmup.swift"
                    : String(format: "IncrementalNeedle-%02d.swift", sampleIndex - 1)
                let sample = try await runIncrementalRebuildSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured",
                    relativePath: relativePath,
                    fixture: fixture,
                    rootID: worktreeRoot.id,
                    scope: scope,
                    store: store
                )
                if isWarmup {
                    warmup = sample
                } else {
                    measured.append(sample)
                }
            }
            await unloadAllRoots(in: store)
            return try WorkspaceFileSearchIndexBenchmarkAggregate(
                scenario: "incremental-one-file-ready-search",
                warmup: XCTUnwrap(warmup),
                measured: measured
            )
        }

        private func runIncrementalRebuildSample(
            ordinal: Int,
            phase: String,
            relativePath: String,
            fixture: WorkspaceFileSearchIndexBenchmarkFixture,
            rootID: UUID,
            scope: WorkspaceLookupRootScope,
            store: WorkspaceFileContextStore
        ) async throws -> WorkspaceFileSearchIndexBenchmarkSample {
            let fileURL = try fixture.writeMutationFile(relativePath: relativePath)
            let before = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(store: store, rootID: rootID)
            let started = DispatchTime.now()
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootID,
                deltas: [.fileAdded(relativePath)]
            )
            let published = DispatchTime.now()
            let phaseCollector = WorkspaceFileSearchPhaseCollector()
            let result = try await WorkspaceFileSearchDebugContext.$collector.withValue(phaseCollector) {
                try await StoreBackedWorkspaceSearch.search(
                    pattern: relativePath,
                    mode: .path,
                    maxPaths: 1,
                    rootScope: scope,
                    store: store,
                    workspaceManager: nil
                )
            }
            let finished = DispatchTime.now()
            let phases = phaseCollector.snapshot(
                readySearchNanoseconds: finished.uptimeNanoseconds - published.uptimeNanoseconds
            )
            let after = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(store: store, rootID: rootID)
            let counters = after.delta(from: before)
            let snapshot = await store.searchCatalogSnapshot(rootScope: scope, requirement: .recordsOnly)
            let workDiagnostics = await store.storeWorkDiagnosticsSnapshot()
            let shardDiagnostics = try XCTUnwrap(
                workDiagnostics.rootCatalogShards.roots.first { $0.rootID == rootID }
            )

            try require(phases.status == .completed, "Incremental phase collector must complete")
            try require(result.paths == [fileURL.path], "Incremental search must return the added path")
            try require(snapshot.files.contains { $0.standardizedFullPath == fileURL.path }, "Fresh scoped snapshot must contain the added path")
            try require(counters.appliedGeneration == 1, "Incremental sample must advance one applied generation")
            try require(counters.crawl == 0, "Incremental sample must not crawl")
            try require(counters.shardBuild == 1, "Incremental sample must build one shard")
            try require(counters.patch == 1, "Incremental sample must apply one shard patch")
            try require(counters.authoritative == 0, "Incremental sample must not rebuild authoritatively")
            try require(counters.pathIndexBuild == 0, "Incremental sample must not build a full path index")
            try require(counters.overlayPathIndexBuild == 0, "Incremental sample must not build an overlay")
            try require(
                counterVector(counters) == [0, 1, 1, 1, 0, 0, 0, 0, 1, 1],
                "Incremental counter vector must match the records-only contract"
            )
            let fallbackDiagnostics = counters.fallbackDiagnosticDescription()
            try require(
                counters.fallbackReasonDeltasAreNonnegative,
                "Incremental fallback reason deltas must not be negative; \(fallbackDiagnostics)"
            )
            try require(
                counters.fallback == counters.fallbackReasonDeltaSum,
                "Incremental aggregate fallback delta must equal the reason delta sum; \(fallbackDiagnostics)"
            )
            try require(
                counters.fallback == 0,
                "Incremental sample must not fall back",
                diagnostics: fallbackDiagnostics
            )
            try require(shardDiagnostics.lastAppliedIndexGeneration == after.appliedGeneration, "Fresh shard generation must match the applied generation")
            try require(!shardDiagnostics.deltaStateDirty, "Fresh shard delta state must remain clean")
            let watcherIsStillActive = try await store.rootWatcherIsActiveForTesting(rootID: rootID)
            try require(!watcherIsStillActive, "Live FSEvents must remain stopped during incremental samples")

            return WorkspaceFileSearchIndexBenchmarkSample(
                ordinal: ordinal,
                phase: phase,
                totalWallMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: finished),
                preSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: published),
                searchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: published, to: finished),
                cumulativeSearchMilliseconds: workspaceFileSearchIndexElapsedMilliseconds(from: started, to: finished),
                readMilliseconds: 0,
                counters: counters,
                phases: phases,
                coldStart: nil
            )
        }

        private func runLegacyCodemapScenarios() async throws -> WorkspaceLegacyCodemapBenchmarkAggregate {
            var warmup: WorkspaceLegacyCodemapBenchmarkSample?
            var measured: [WorkspaceLegacyCodemapBenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = try await runLegacyReuseAndDemandSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured"
                )
                if isWarmup {
                    warmup = sample
                } else {
                    measured.append(sample)
                }
            }

            var convergenceWarmup: WorkspaceLegacyCodemapConvergenceSample?
            var convergenceMeasured: [WorkspaceLegacyCodemapConvergenceSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = try await runLegacyEagerConvergenceSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured"
                )
                if isWarmup {
                    convergenceWarmup = sample
                } else {
                    convergenceMeasured.append(sample)
                }
            }

            return try WorkspaceLegacyCodemapBenchmarkAggregate(
                warmup: XCTUnwrap(warmup),
                measured: measured,
                convergenceWarmup: XCTUnwrap(convergenceWarmup),
                convergenceMeasured: convergenceMeasured
            )
        }

        private func runPhase2ModelScenario() async throws -> WorkspaceCodeMapPhase2BenchmarkAggregate {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPromptCEPhase2CodemapBenchmark", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let relativePath = "Phase2Benchmark.swift"
            let sourceData = Data(phase2BenchmarkSource().utf8)
            try sourceData.write(to: root.appendingPathComponent(relativePath), options: .atomic)
            let service = try await FileSystemService(
                path: root.path,
                respectGitignore: false,
                respectRepoIgnore: false,
                respectCursorignore: false,
                skipSymlinks: true
            )
            let fingerprint = try await service.contentFingerprint(ofRelativePath: relativePath)
            let language = try XCTUnwrap(
                SyntaxManager.shared.language(forFileExtension: "swift"),
                "Phase 2 benchmark requires the Swift language registry entry."
            )

            var warmup: WorkspaceCodeMapPhase2BenchmarkSample?
            var measured: [WorkspaceCodeMapPhase2BenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = await runPhase2ModelSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured",
                    service: service,
                    relativePath: relativePath,
                    sourceData: sourceData,
                    expectedFingerprint: fingerprint,
                    language: language,
                    fullPath: root.appendingPathComponent(relativePath).path
                )
                if isWarmup {
                    warmup = sample
                } else {
                    measured.append(sample)
                }
            }
            return try WorkspaceCodeMapPhase2BenchmarkAggregate(
                warmup: XCTUnwrap(warmup),
                measured: measured
            )
        }

        private func runPhase2ModelSample(
            ordinal: Int,
            phase: String,
            service: FileSystemService,
            relativePath: String,
            sourceData: Data,
            expectedFingerprint: FileContentFingerprint,
            language: LanguageType,
            fullPath: String
        ) async -> WorkspaceCodeMapPhase2BenchmarkSample {
            var wallValues: [WorkspaceCodeMapPhase2BenchmarkMetric: Double] = [:]
            var threadCPUValues: [WorkspaceCodeMapPhase2BenchmarkMetric: Double] = [:]
            var serializedArtifactBytes: Int?
            var correctnessChecks: [String: Bool] = [:]
            var issues: [WorkspaceBenchmarkValidityIssue] = []

            func store<Value>(
                _ measurement: Phase2SynchronousMeasurement<Value>,
                metric: WorkspaceCodeMapPhase2BenchmarkMetric
            ) -> Value {
                wallValues[metric] = measurement.wallMilliseconds
                if let threadCPU = measurement.threadCPUMilliseconds {
                    threadCPUValues[metric] = threadCPU
                }
                return measurement.value
            }

            func recordCheck(_ name: String, _ passed: Bool, _ detail: String) {
                correctnessChecks[name] = passed
                if !passed {
                    issues.append(.init(code: "phase2-\(name)", detail: detail))
                }
            }

            do {
                let rawStart = DispatchTime.now()
                let validatedContent = try await service.loadValidatedRawContent(
                    ofRelativePath: relativePath,
                    expectedFingerprint: expectedFingerprint
                )
                wallValues[.validatedRawRead] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: rawStart,
                    to: DispatchTime.now()
                )

                let source = store(
                    measurePhase2Synchronous {
                        CodeMapSourceSnapshot(validatedContent: validatedContent)
                    },
                    metric: .envelopeHashAndDecode
                )
                guard case let .decoded(decodedSource) = source.decodeResult else {
                    throw BenchmarkInvariantError(message: "Phase 2 source did not decode.")
                }

                let explicitQuery = try store(
                    measurePhase2Synchronous {
                        try SyntaxManager.shared.codeMap(content: decodedSource.text, language: language)
                    },
                    metric: .explicitLanguageQueryParse
                )
                guard case let .captures(captures) = explicitQuery, !captures.isEmpty else {
                    throw BenchmarkInvariantError(message: "Phase 2 explicit query did not return captures.")
                }

                let legacyCaptures = try store(
                    measurePhase2Synchronous {
                        try SyntaxManager.shared.codeMap(content: decodedSource.text, fileExtension: "swift")
                    },
                    metric: .legacyExtensionQueryParse
                )

                func modernTerminalMeasurement() -> Phase2SynchronousMeasurement<CodeMapSyntaxArtifact?> {
                    measurePhase2Synchronous {
                        CodeMapGenerator.generateSyntaxArtifact(
                            from: captures,
                            content: decodedSource.text,
                            language: language
                        )
                    }
                }

                func legacyTerminalMeasurement() -> Phase2SynchronousMeasurement<FileAPI?> {
                    measurePhase2Synchronous {
                        CodeMapGenerator.generateCodeMap(
                            from: captures,
                            content: decodedSource.text,
                            fullPath: fullPath
                        )
                    }
                }

                let modernArtifact: CodeMapSyntaxArtifact
                let legacyFileAPI: FileAPI
                if ordinal.isMultiple(of: 2) {
                    legacyFileAPI = try XCTUnwrap(
                        store(legacyTerminalMeasurement(), metric: .legacyFileAPIGeneration),
                        "Phase 2 legacy terminal did not produce a FileAPI."
                    )
                    modernArtifact = try XCTUnwrap(
                        store(modernTerminalMeasurement(), metric: .pathFreeArtifactGeneration),
                        "Phase 2 modern terminal did not produce an artifact."
                    )
                } else {
                    modernArtifact = try XCTUnwrap(
                        store(modernTerminalMeasurement(), metric: .pathFreeArtifactGeneration),
                        "Phase 2 modern terminal did not produce an artifact."
                    )
                    legacyFileAPI = try XCTUnwrap(
                        store(legacyTerminalMeasurement(), metric: .legacyFileAPIGeneration),
                        "Phase 2 legacy terminal did not produce a FileAPI."
                    )
                }

                func modernTotalMeasurement() throws
                    -> Phase2SynchronousMeasurement<(CodeMapSourceSnapshot, CodeMapSyntaxArtifactOutcome)>
                {
                    try measurePhase2Synchronous {
                        let totalSource = CodeMapSourceSnapshot(validatedContent: validatedContent)
                        let outcome = try CodeMapSyntaxArtifactBuilder.build(
                            source: totalSource,
                            language: language
                        )
                        return (totalSource, outcome)
                    }
                }

                func legacyTotalMeasurement() throws -> Phase2SynchronousMeasurement<FileAPI?> {
                    try measurePhase2Synchronous {
                        let totalCaptures = try SyntaxManager.shared.codeMap(
                            content: decodedSource.text,
                            fileExtension: "swift"
                        )
                        return CodeMapGenerator.generateCodeMap(
                            from: totalCaptures,
                            content: decodedSource.text,
                            fullPath: fullPath
                        )
                    }
                }

                let modernTotal: (CodeMapSourceSnapshot, CodeMapSyntaxArtifactOutcome)
                let legacyTotalFileAPI: FileAPI
                if ordinal.isMultiple(of: 2) {
                    legacyTotalFileAPI = try XCTUnwrap(
                        try store(legacyTotalMeasurement(), metric: .legacyParseAndFileAPITotal),
                        "Phase 2 total legacy control did not produce a FileAPI."
                    )
                    modernTotal = try store(
                        modernTotalMeasurement(),
                        metric: .modernEnvelopeToReadyArtifact
                    )
                } else {
                    modernTotal = try store(
                        modernTotalMeasurement(),
                        metric: .modernEnvelopeToReadyArtifact
                    )
                    legacyTotalFileAPI = try XCTUnwrap(
                        try store(legacyTotalMeasurement(), metric: .legacyParseAndFileAPITotal),
                        "Phase 2 total legacy control did not produce a FileAPI."
                    )
                }
                guard case let .ready(totalArtifact) = modernTotal.1 else {
                    throw BenchmarkInvariantError(message: "Phase 2 total modern pipeline was not ready.")
                }

                let modernTerminal = wallValues[.pathFreeArtifactGeneration]!
                let legacyTerminal = wallValues[.legacyFileAPIGeneration]!
                let modernTotalWall = wallValues[.modernEnvelopeToReadyArtifact]!
                let legacyTotalWall = wallValues[.legacyParseAndFileAPITotal]!
                wallValues[.modernTerminalDelta] = modernTerminal - legacyTerminal
                wallValues[.modernTotalDelta] = modernTotalWall - legacyTotalWall
                if legacyTerminal > 0 {
                    wallValues[.modernTerminalRatio] = modernTerminal / legacyTerminal
                }
                if legacyTotalWall > 0 {
                    wallValues[.modernTotalRatio] = modernTotalWall / legacyTotalWall
                }

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let artifactData = try encoder.encode(modernArtifact)
                serializedArtifactBytes = artifactData.count
                let artifactJSON = String(decoding: artifactData, as: UTF8.self)
                let decodedArtifact = try JSONDecoder().decode(CodeMapSyntaxArtifact.self, from: artifactData)

                let rootID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
                let lifetimeID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
                let fileID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
                let rootPath = String(fullPath.dropLast(relativePath.count + 1))
                let identity = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
                    rootID: rootID,
                    rootLifetimeID: lifetimeID,
                    fileID: fileID,
                    standardizedRootPath: rootPath,
                    standardizedRelativePath: relativePath,
                    standardizedFullPath: fullPath
                ))
                let pipelineIdentity = try SyntaxManager.shared.pipelineIdentity(
                    for: language,
                    decoderPolicy: source.decoderPolicy
                )
                let artifactKey = try CodeMapArtifactKey(source: source, pipelineIdentity: pipelineIdentity)
                let capabilityService = WorkspaceCodemapGitCapabilityService(
                    namespaceSalt: Data(
                        repeating: 0xAB,
                        count: GitBlobRepositoryNamespace.saltByteCount
                    )
                )
                let capabilityState = await capabilityService.resolve(
                    root: WorkspaceCodemapGitCapabilityRequest(
                        rootID: rootID,
                        rootLifetimeID: lifetimeID,
                        loadedRootURL: URL(fileURLWithPath: rootPath, isDirectory: true)
                    )
                )
                guard case let .eligible(capability) = capabilityState else {
                    throw BenchmarkInvariantError(message: "Binding capability unavailable.")
                }
                let repositoryRelativePath = capability.repositoryRelativeLoadedRootPrefix.isEmpty
                    ? relativePath
                    : capability.repositoryRelativeLoadedRootPrefix + "/" + relativePath
                let issuedSourceAuthority = await capabilityService.makeSourceAuthority(
                    capability: capability,
                    observedRootEpoch: capability.rootEpoch,
                    observedRepositoryAuthority: capability.repositoryAuthority,
                    candidateRepositoryRelativePath: repositoryRelativePath,
                    observedPathGeneration: 1,
                    currentPathGeneration: 1,
                    observedIngressGeneration: 1,
                    currentIngressGeneration: 1
                )
                let sourceAuthority = try XCTUnwrap(issuedSourceAuthority)
                let sourceExpectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.validatedWorktree(
                    bindingIdentity: identity,
                    source: source,
                    expectedArtifactKey: artifactKey,
                    classificationReason: .dirty,
                    sourceAuthority: sourceAuthority
                ))
                let token = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
                    identity: identity,
                    requestGeneration: 7,
                    catalogGeneration: 11,
                    sourceExpectation: sourceExpectation
                ))
                let completion = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
                    token: token,
                    language: language,
                    outcome: .ready(modernArtifact)
                ))
                var binding = try XCTUnwrap(WorkspaceCodemapArtifactBinding(pending: token))
                let accepted = binding.apply(completion)
                let resolvedBinding = binding
                let duplicate = binding.apply(completion)
                let staleToken = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
                    identity: identity,
                    requestGeneration: token.requestGeneration + 1,
                    catalogGeneration: token.catalogGeneration,
                    sourceExpectation: token.sourceExpectation
                ))
                let staleCompletion = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
                    token: staleToken,
                    language: language,
                    outcome: .ready(modernArtifact)
                ))
                var staleBinding = try XCTUnwrap(WorkspaceCodemapArtifactBinding(pending: token))
                let staleBefore = staleBinding
                let staleDisposition = staleBinding.apply(staleCompletion)
                let rendered = WorkspaceCodemapArtifactPresentation(
                    identity: identity,
                    displayPath: fullPath,
                    completion: completion
                ).renderedCodemap()

                recordCheck(
                    "raw-bytes-and-count",
                    validatedContent.data == sourceData && source.rawByteCount == sourceData.count,
                    "Validated raw bytes or envelope byte count changed."
                )
                recordCheck(
                    "digest-stability",
                    source.rawSHA256 == modernTotal.0.rawSHA256,
                    "Repeated envelope construction did not preserve the raw digest."
                )
                recordCheck(
                    "ready-and-expected-symbol",
                    modernArtifact == totalArtifact && modernArtifact.definedTypeNames.contains("Phase2Type127"),
                    "Modern runs differed or the expected fixture symbol was absent."
                )
                let forbiddenSerializationValues = [
                    relativePath,
                    StandardizedPath.absolute(fullPath),
                    rootID.uuidString,
                    lifetimeID.uuidString,
                    fileID.uuidString,
                    source.rawSHA256.lowercaseHex
                ]
                recordCheck(
                    "serialization-path-free",
                    forbiddenSerializationValues.allSatisfy { !artifactJSON.contains($0) },
                    "Serialized artifact leaked path, binding, or source identity."
                )
                recordCheck(
                    "serialization-round-trip",
                    decodedArtifact == modernArtifact,
                    "Serialized artifact did not round-trip with equal derived values."
                )
                recordCheck(
                    "rendering-parity",
                    legacyCaptures == captures
                        && rendered?.text == legacyFileAPI.getFullAPIDescription(displayPath: fullPath)
                        && rendered?.text == legacyTotalFileAPI.getFullAPIDescription(displayPath: fullPath),
                    "Modern presentation did not match both matched legacy controls."
                )
                recordCheck(
                    "binding-fencing",
                    accepted == .accepted
                        && duplicate == .exactDuplicate
                        && binding == resolvedBinding
                        && staleDisposition == .requestGenerationMismatch
                        && staleBinding == staleBefore,
                    "Binding acceptance, duplicate replay, or stale generation fencing failed."
                )
            } catch {
                issues.append(.init(
                    code: "phase2-sample-error",
                    detail: "Phase 2 sample failed: \(error)"
                ))
            }

            for metric in WorkspaceCodeMapPhase2BenchmarkMetric.allCases {
                guard let value = wallValues[metric] else {
                    issues.append(.init(
                        code: "phase2-missing-timing",
                        detail: "\(metric.rawValue) is missing."
                    ))
                    continue
                }
                if !value.isFinite {
                    issues.append(.init(
                        code: "phase2-nonfinite-timing",
                        detail: "\(metric.rawValue) is nonfinite."
                    ))
                }
            }
            if serializedArtifactBytes == nil {
                issues.append(.init(
                    code: "phase2-missing-serialized-size",
                    detail: "Serialized artifact byte size is missing."
                ))
            }
            for check in WorkspaceCodeMapPhase2BenchmarkSample.requiredCorrectnessChecks
                where correctnessChecks[check] != true
            {
                if correctnessChecks[check] == nil {
                    issues.append(.init(
                        code: "phase2-missing-correctness-check",
                        detail: "\(check) did not execute."
                    ))
                }
            }

            return WorkspaceCodeMapPhase2BenchmarkSample(
                ordinal: ordinal,
                phase: phase,
                wallValues: wallValues,
                threadCPUValues: threadCPUValues,
                serializedArtifactBytes: serializedArtifactBytes,
                correctnessChecks: correctnessChecks,
                validityIssues: issues
            )
        }

        private func measurePhase2Synchronous<Value>(
            _ operation: () throws -> Value
        ) rethrows -> Phase2SynchronousMeasurement<Value> {
            let started = LegacyCodeMapTelemetryTiming.start()
            let value = try operation()
            let elapsed = LegacyCodeMapTelemetryTiming.elapsed(since: started)
            return Phase2SynchronousMeasurement(
                value: value,
                wallMilliseconds: Double(elapsed.wallNanoseconds) / 1_000_000,
                threadCPUMilliseconds: elapsed.threadCPUNanoseconds.map { Double($0) / 1_000_000 }
            )
        }

        private func phase2BenchmarkSource() -> String {
            var lines = [
                "import Foundation",
                "protocol Phase2BenchmarkProtocol { func value() -> Int }"
            ]
            for index in 0 ..< 256 {
                let suffix = String(format: "%03d", index)
                lines.append(contentsOf: [
                    "struct Phase2Type\(suffix): Phase2BenchmarkProtocol {",
                    "    let stored: Int",
                    "    func value() -> Int { stored + \(index) }",
                    "    func transformed(_ input: Int) -> Int { input + stored + \(index) }",
                    "}"
                ])
            }
            return lines.joined(separator: "\n") + "\n"
        }

        private func runLegacyReuseAndDemandSample(
            ordinal: Int,
            phase: String
        ) async throws -> WorkspaceLegacyCodemapBenchmarkSample {
            let fixture = try ReviewGitRepositoryFixture(name: "LegacyCodemapBenchmark")
            let identity = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let cleanPath = "Sources/Clean.swift"
            let dirtyPath = "Sources/Dirty.swift"
            let untrackedPath = "Sources/Untracked.swift"
            let nonGitPath = "Sources/NonGit.swift"
            let cleanContents = "struct Clean_\(identity) { func clean() {} }\n"
            let dirtyOriginalContents = "struct DirtyOriginal_\(identity) {}\n"
            let dirtyContents = "struct Dirty_\(identity) { func changed() {} }\n"
            let untrackedContents = "struct Untracked_\(identity) { func local() {} }\n"
            let nonGitContents = "struct NonGit_\(identity) { func local() {} }\n"
            let canonical = try fixture.makeRepository(
                named: "Canonical",
                files: [cleanPath: cleanContents, dirtyPath: dirtyOriginalContents]
            )
            let linked = try fixture.makeLinkedWorktree(
                from: canonical,
                named: "Linked",
                branch: "benchmark-linked"
            )
            try fixture.write(dirtyContents, to: dirtyPath, at: linked)
            _ = try fixture.createUntrackedFile(untrackedContents, at: untrackedPath, root: linked)
            let nonGit = fixture.sandbox.appendingPathComponent("NonGit", isDirectory: true)
            try FileManager.default.createDirectory(at: nonGit, withIntermediateDirectories: true)
            try fixture.write(nonGitContents, to: nonGitPath, at: nonGit)

            let firstStore = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            let secondStore = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            let linkedStore = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            let nonGitStore = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            let stores = [firstStore, secondStore, linkedStore, nonGitStore]
            let cacheRootPaths = [canonical.path, linked.path, nonGit.path]
            addTeardownBlock {
                for store in stores {
                    await store.cancelAllCodemapScans()
                    await store.clearAllCodemapCaches(rootFolders: cacheRootPaths)
                    await self.unloadAllRoots(in: store)
                }
            }

            var sampleIssues: [WorkspaceBenchmarkValidityIssue] = []
            func recordIssue(_ condition: @autoclosure () -> Bool, code: String, detail: String) {
                if !condition() {
                    sampleIssues.append(.init(code: code, detail: detail))
                }
            }

            let canonicalHead = try fixture.head(at: canonical)
            let linkedHead = try fixture.head(at: linked)
            let canonicalOID = try fixture.headBlobOID(for: cleanPath, at: canonical)
            let linkedOID = try fixture.headBlobOID(for: cleanPath, at: linked)
            let canonicalCleanStatus = try fixture.porcelainStatus(for: cleanPath, at: canonical)
            let linkedCleanStatus = try fixture.porcelainStatus(for: cleanPath, at: linked)
            let dirtyStatus = try fixture.porcelainStatus(for: dirtyPath, at: linked)
            let untrackedStatus = try fixture.porcelainStatus(for: untrackedPath, at: linked)
            let cleanIsTracked = try fixture.isTracked(cleanPath, at: canonical)
            let dirtyIsTracked = try fixture.isTracked(dirtyPath, at: linked)
            let untrackedIsTracked = try fixture.isTracked(untrackedPath, at: linked)
            recordIssue(canonicalHead == linkedHead, code: "git-head-mismatch", detail: "Canonical and linked roots must share HEAD.")
            recordIssue(canonicalOID == linkedOID, code: "git-blob-mismatch", detail: "Clean canonical and linked files must share a HEAD blob OID.")
            recordIssue(canonicalCleanStatus.isEmpty && linkedCleanStatus.isEmpty, code: "clean-classification", detail: "Clean tracked files must have empty porcelain status.")
            recordIssue(cleanIsTracked, code: "clean-untracked", detail: "Clean canonical file must be tracked.")
            recordIssue(dirtyIsTracked, code: "dirty-untracked", detail: "Dirty linked file must remain tracked.")
            recordIssue(dirtyStatus.hasPrefix(" M"), code: "dirty-classification", detail: "Dirty tracked file must have an unstaged porcelain modification.")
            recordIssue(!untrackedIsTracked, code: "untracked-classification", detail: "Untracked control must not be in the index.")
            recordIssue(untrackedStatus.hasPrefix("??"), code: "untracked-status", detail: "Untracked control must have porcelain ?? status.")

            let collector = LegacyCodeMapTelemetryCollector()
            let sampleID = UUID()
            let firstStoreID = UUID()
            let secondStoreID = UUID()
            let linkedStoreID = UUID()
            let nonGitStoreID = UUID()

            let firstRoot = try await firstStore.loadRoot(path: canonical.path)
            await firstStore.stopWatchingRoot(id: firstRoot.id)
            let loadedFirstFile = await firstStore.file(rootID: firstRoot.id, relativePath: cleanPath)
            let firstFile = try XCTUnwrap(loadedFirstFile)
            let freshContext = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: sampleID,
                cohort: .canonicalExplicitMiss,
                storeID: firstStoreID,
                rootRole: .canonical
            )
            let freshStart = DispatchTime.now()
            let freshRepair = try await LegacyCodeMapTelemetryContext.$current.withValue(freshContext) {
                try await firstStore.repairMissingCodemapSnapshots(for: [firstFile], timeout: .seconds(10))
            }
            let freshReady = DispatchTime.now()
            let firstQuiescence = await waitForCodemapQuiescence(store: firstStore)
            let freshIssues = codemapDemandIssues(
                repair: freshRepair,
                file: firstFile,
                quiescence: firstQuiescence,
                expectedContents: cleanContents
            )

            let secondRoot = try await secondStore.loadRoot(path: canonical.path)
            await secondStore.stopWatchingRoot(id: secondRoot.id)
            let loadedSecondFile = await secondStore.file(rootID: secondRoot.id, relativePath: cleanPath)
            let secondFile = try XCTUnwrap(loadedSecondFile)
            let diskContext = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: sampleID,
                cohort: .sameRootSecondStore,
                storeID: secondStoreID,
                rootRole: .canonical
            )
            let diskStart = DispatchTime.now()
            let diskRepair = try await LegacyCodeMapTelemetryContext.$current.withValue(diskContext) {
                try await secondStore.repairMissingCodemapSnapshots(for: [secondFile], timeout: .seconds(10))
            }
            let diskReady = DispatchTime.now()
            let secondQuiescence = await waitForCodemapQuiescence(store: secondStore)
            let diskIssues = codemapDemandIssues(
                repair: diskRepair,
                file: secondFile,
                quiescence: secondQuiescence,
                expectedContents: cleanContents
            )

            let setupContext = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: sampleID,
                cohort: .setup,
                storeID: secondStoreID,
                rootRole: .canonical
            )
            let pin = try await LegacyCodeMapTelemetryContext.$current.withValue(setupContext) {
                try await secondStore.pinCodemapRootCacheForTesting(rootID: secondRoot.id)
            }
            let pinnedState = await secondStore.codemapQuiescenceSnapshotForTesting()
            var setupIssues: [WorkspaceBenchmarkValidityIssue] = []
            if pinnedState.counters.rootCachePinCount != 1 {
                setupIssues.append(.init(code: "pin-count", detail: "Setup must hold exactly one root-cache pin."))
            }

            let memoryContext = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: sampleID,
                cohort: .forcedResidentMemoryHit,
                storeID: secondStoreID,
                rootRole: .canonical
            )
            let memoryStart = DispatchTime.now()
            try await LegacyCodeMapTelemetryContext.$current.withValue(memoryContext) {
                try await secondStore.requestCodemapCacheClassificationForTesting(fileID: secondFile.id)
            }
            let memoryPublished = await waitForLegacyPublication(
                collector: collector,
                cohort: .forcedResidentMemoryHit,
                storeID: secondStoreID
            )
            let memoryReady = DispatchTime.now()
            await secondStore.releaseCodemapRootCachePinForTesting(pin)
            let memoryQuiescence = await waitForCodemapQuiescence(store: secondStore)
            var memoryIssues: [WorkspaceBenchmarkValidityIssue] = []
            if !memoryPublished {
                memoryIssues.append(.init(code: "memory-publication-timeout", detail: "Forced-resident classification did not publish ready before the deadline."))
            }
            if memoryQuiescence.timedOut {
                memoryIssues.append(.init(code: "memory-quiescence-timeout", detail: "Forced-resident classification did not quiesce after pin release."))
            }

            let linkedRoot = try await linkedStore.loadRoot(path: linked.path)
            await linkedStore.stopWatchingRoot(id: linkedRoot.id)
            let loadedLinkedCleanFile = await linkedStore.file(rootID: linkedRoot.id, relativePath: cleanPath)
            let linkedCleanFile = try XCTUnwrap(loadedLinkedCleanFile)
            let linkedContext = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: sampleID,
                cohort: .equivalentLinkedWorktree,
                storeID: linkedStoreID,
                rootRole: .linkedWorktree
            )
            let linkedStart = DispatchTime.now()
            let linkedRepair = try await LegacyCodeMapTelemetryContext.$current.withValue(linkedContext) {
                try await linkedStore.repairMissingCodemapSnapshots(for: [linkedCleanFile], timeout: .seconds(10))
            }
            let linkedReady = DispatchTime.now()
            let linkedQuiescence = await waitForCodemapQuiescence(store: linkedStore)
            var linkedIssues = codemapDemandIssues(
                repair: linkedRepair,
                file: linkedCleanFile,
                quiescence: linkedQuiescence,
                expectedContents: cleanContents
            )
            if canonicalOID != linkedOID {
                linkedIssues.append(.init(code: "association-identity", detail: "Same-blob opportunity requires matching HEAD blob OIDs."))
            }

            let loadedDirtyFile = await linkedStore.file(rootID: linkedRoot.id, relativePath: dirtyPath)
            let dirtyFile = try XCTUnwrap(loadedDirtyFile)
            let dirtyContext = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: sampleID,
                cohort: .dirtyTracked,
                storeID: linkedStoreID,
                rootRole: .linkedWorktree
            )
            let dirtyStart = DispatchTime.now()
            let dirtyRepair = try await LegacyCodeMapTelemetryContext.$current.withValue(dirtyContext) {
                try await linkedStore.repairMissingCodemapSnapshots(for: [dirtyFile], timeout: .seconds(10))
            }
            let dirtyReady = DispatchTime.now()
            let dirtyQuiescence = await waitForCodemapQuiescence(store: linkedStore)
            let dirtyIssues = codemapDemandIssues(
                repair: dirtyRepair,
                file: dirtyFile,
                quiescence: dirtyQuiescence,
                expectedContents: dirtyContents
            )

            let loadedUntrackedFile = await linkedStore.file(rootID: linkedRoot.id, relativePath: untrackedPath)
            let untrackedFile = try XCTUnwrap(loadedUntrackedFile)
            let untrackedContext = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: sampleID,
                cohort: .untracked,
                storeID: linkedStoreID,
                rootRole: .linkedWorktree
            )
            let untrackedStart = DispatchTime.now()
            let untrackedRepair = try await LegacyCodeMapTelemetryContext.$current.withValue(untrackedContext) {
                try await linkedStore.repairMissingCodemapSnapshots(for: [untrackedFile], timeout: .seconds(10))
            }
            let untrackedReady = DispatchTime.now()
            let untrackedQuiescence = await waitForCodemapQuiescence(store: linkedStore)
            let untrackedIssues = codemapDemandIssues(
                repair: untrackedRepair,
                file: untrackedFile,
                quiescence: untrackedQuiescence,
                expectedContents: untrackedContents
            )

            let nonGitRoot = try await nonGitStore.loadRoot(path: nonGit.path)
            await nonGitStore.stopWatchingRoot(id: nonGitRoot.id)
            let loadedNonGitFile = await nonGitStore.file(rootID: nonGitRoot.id, relativePath: nonGitPath)
            let nonGitFile = try XCTUnwrap(loadedNonGitFile)
            let nonGitContext = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: sampleID,
                cohort: .nonGit,
                storeID: nonGitStoreID,
                rootRole: .nonGit
            )
            let nonGitStart = DispatchTime.now()
            let nonGitRepair = try await LegacyCodeMapTelemetryContext.$current.withValue(nonGitContext) {
                try await nonGitStore.repairMissingCodemapSnapshots(for: [nonGitFile], timeout: .seconds(10))
            }
            let nonGitReady = DispatchTime.now()
            let nonGitQuiescence = await waitForCodemapQuiescence(store: nonGitStore)
            let nonGitIssues = codemapDemandIssues(
                repair: nonGitRepair,
                file: nonGitFile,
                quiescence: nonGitQuiescence,
                expectedContents: nonGitContents
            )

            let snapshot = collector.snapshot()
            let cohorts = [
                legacyCohortSample(
                    snapshot: snapshot,
                    cohort: .canonicalExplicitMiss,
                    semantic: "canonical explicit parse miss",
                    storeID: firstStoreID,
                    rootRole: .canonical,
                    latency: workspaceFileSearchIndexElapsedMilliseconds(from: freshStart, to: freshReady),
                    expectedCacheResult: .absentMiss,
                    expectedParseCount: 1,
                    issues: freshIssues
                ),
                legacyCohortSample(
                    snapshot: snapshot,
                    cohort: .sameRootSecondStore,
                    semantic: "same physical root second-store disk hit; actual cross-store parse avoidance",
                    storeID: secondStoreID,
                    rootRole: .canonical,
                    latency: workspaceFileSearchIndexElapsedMilliseconds(from: diskStart, to: diskReady),
                    expectedCacheResult: .diskHit,
                    expectedParseCount: 0,
                    actualCrossStoreAvoidance: 1,
                    issues: diskIssues
                ),
                legacyCohortSample(
                    snapshot: snapshot,
                    cohort: .setup,
                    semantic: "excluded cache-pin preload/setup",
                    storeID: secondStoreID,
                    rootRole: .canonical,
                    latency: nil,
                    expectedCacheResult: nil,
                    expectedParseCount: nil,
                    requirePublication: false,
                    issues: setupIssues
                ),
                legacyCohortSample(
                    snapshot: snapshot,
                    cohort: .forcedResidentMemoryHit,
                    semantic: "DEBUG-only forced-residency memory-hit classification",
                    storeID: secondStoreID,
                    rootRole: .canonical,
                    latency: workspaceFileSearchIndexElapsedMilliseconds(from: memoryStart, to: memoryReady),
                    expectedCacheResult: .memoryHit,
                    expectedParseCount: 0,
                    issues: memoryIssues
                ),
                legacyCohortSample(
                    snapshot: snapshot,
                    cohort: .equivalentLinkedWorktree,
                    semantic: "same HEAD blob; legacy physical-root miss and duplicate parse; prospective association only",
                    storeID: linkedStoreID,
                    rootRole: .linkedWorktree,
                    latency: workspaceFileSearchIndexElapsedMilliseconds(from: linkedStart, to: linkedReady),
                    expectedCacheResult: .absentMiss,
                    expectedParseCount: 1,
                    sameBlobOpportunity: 1,
                    issues: linkedIssues
                ),
                legacyCohortSample(
                    snapshot: snapshot,
                    cohort: .dirtyTracked,
                    semantic: "dirty tracked worktree parse miss",
                    storeID: linkedStoreID,
                    rootRole: .linkedWorktree,
                    latency: workspaceFileSearchIndexElapsedMilliseconds(from: dirtyStart, to: dirtyReady),
                    expectedCacheResult: .absentMiss,
                    expectedParseCount: 1,
                    issues: dirtyIssues
                ),
                legacyCohortSample(
                    snapshot: snapshot,
                    cohort: .untracked,
                    semantic: "untracked worktree parse miss",
                    storeID: linkedStoreID,
                    rootRole: .linkedWorktree,
                    latency: workspaceFileSearchIndexElapsedMilliseconds(from: untrackedStart, to: untrackedReady),
                    expectedCacheResult: .absentMiss,
                    expectedParseCount: 1,
                    issues: untrackedIssues
                ),
                legacyCohortSample(
                    snapshot: snapshot,
                    cohort: .nonGit,
                    semantic: "non-Git filesystem parse miss",
                    storeID: nonGitStoreID,
                    rootRole: .nonGit,
                    latency: workspaceFileSearchIndexElapsedMilliseconds(from: nonGitStart, to: nonGitReady),
                    expectedCacheResult: .absentMiss,
                    expectedParseCount: 1,
                    issues: nonGitIssues
                )
            ]
            let overallConservation = snapshot.conservation(
                requireReadyPublications: true,
                expectedFreshMisses: 5
            )
            if !overallConservation.isValid {
                sampleIssues.append(.init(
                    code: "sample-conservation",
                    detail: overallConservation.issues.joined(separator: "; ")
                ))
            }

            for store in stores {
                await store.cancelAllCodemapScans()
                await store.clearAllCodemapCaches(rootFolders: cacheRootPaths)
                await unloadAllRoots(in: store)
            }
            return WorkspaceLegacyCodemapBenchmarkSample(
                ordinal: ordinal,
                phase: phase,
                cohorts: cohorts,
                validityIssues: sampleIssues
            )
        }

        private func runLegacyEagerConvergenceSample(
            ordinal: Int,
            phase: String
        ) async throws -> WorkspaceLegacyCodemapConvergenceSample {
            let fixture = try ReviewGitRepositoryFixture(name: "LegacyCodemapConvergence")
            let identity = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let supportedFileCount = 64
            let files = Dictionary(uniqueKeysWithValues: (0 ..< supportedFileCount).map { index in
                let path = String(format: "Sources/Convergence-%03d.swift", index)
                let contents = "struct Convergence_\(identity)_\(index) { func value() -> Int { \(index) } }\n"
                return (path, contents)
            })
            let canonical = try fixture.makeRepository(named: "Canonical", files: files)
            let linked = try fixture.makeLinkedWorktree(
                from: canonical,
                named: "Linked",
                branch: "benchmark-convergence"
            )
            let firstPath = "Sources/Convergence-000.swift"
            let canonicalOID = try fixture.headBlobOID(for: firstPath, at: canonical)
            let linkedOID = try fixture.headBlobOID(for: firstPath, at: linked)

            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            addTeardownBlock {
                await store.cancelAllCodemapScans()
                await store.clearAllCodemapCaches(rootFolders: [linked.path])
                await self.unloadAllRoots(in: store)
            }
            let visibleRoot = try await store.loadRoot(path: canonical.path)
            await store.stopWatchingRoot(id: visibleRoot.id)
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            let sessionID = UUID()
            let binding = AgentSessionWorktreeBinding(
                id: "legacy-codemap-convergence-\(sessionID.uuidString)",
                repositoryID: "legacy-codemap-benchmark-repository",
                repoKey: "legacy-codemap-benchmark",
                logicalRootPath: visibleRoot.standardizedFullPath,
                logicalRootName: visibleRoot.name,
                worktreeID: "legacy-codemap-convergence-\(ordinal)-\(sessionID.uuidString)",
                worktreeRootPath: linked.standardizedFileURL.path,
                worktreeName: linked.lastPathComponent,
                source: "legacy_codemap_benchmark"
            )

            let collector = LegacyCodeMapTelemetryCollector()
            let storeID = UUID()
            let context = LegacyCodeMapTelemetryContext(
                collector: collector,
                sampleID: UUID(),
                cohort: .eagerBackgroundConvergence,
                storeID: storeID,
                rootRole: .linkedWorktree
            )
            let updates = await store.codemapUpdates()
            let started = DispatchTime.now()
            let milestoneRecorder = CodemapConvergenceRecorder(supportedFileCount: supportedFileCount)
            let milestoneTask = Task { () -> CodemapConvergenceMilestones? in
                for await event in updates {
                    if Task.isCancelled { return nil }
                    guard StandardizedPath.absolute(event.rootPath) == linked.standardizedFileURL.path else {
                        continue
                    }
                    let readyFileIDs = event.snapshots.compactMap { snapshot in
                        snapshot.fileAPI == nil ? nil : snapshot.fileID
                    }
                    let elapsed = workspaceFileSearchIndexElapsedMilliseconds(from: started, to: .now())
                    if await milestoneRecorder.record(
                        fileIDs: readyFileIDs,
                        elapsedMilliseconds: elapsed
                    ) {
                        return await milestoneRecorder.snapshot()
                    }
                }
                return nil
            }

            let projection = await LegacyCodeMapTelemetryContext.$current.withValue(context) {
                await materializer.materialize(sessionID: sessionID, bindings: [binding])
            }
            let observedMilestones: CodemapConvergenceMilestones?
            if projection == nil {
                milestoneTask.cancel()
                observedMilestones = await milestoneRecorder.snapshot()
            } else {
                observedMilestones = await waitForConvergenceMilestones(
                    milestoneTask,
                    recorder: milestoneRecorder
                )
            }
            let milestones: CodemapConvergenceMilestones = if let observedMilestones {
                observedMilestones
            } else {
                await milestoneRecorder.snapshot()
            }
            let quiescence = await waitForCodemapQuiescence(store: store, timeoutSeconds: 30)
            let quiescentAt = DispatchTime.now()

            var issues: [WorkspaceBenchmarkValidityIssue] = []
            if canonicalOID != linkedOID {
                issues.append(.init(code: "convergence-git-identity", detail: "Canonical and linked convergence fixtures must share the same HEAD blob."))
            }
            if projection == nil {
                issues.append(.init(code: "convergence-materialization", detail: "Production materializer did not return a projection."))
            }
            if milestones.allMilliseconds == nil {
                issues.append(.init(code: "convergence-ready-timeout", detail: "All 64 renderable codemaps did not publish before the deadline."))
            }
            if quiescence.timedOut {
                issues.append(.init(code: "convergence-quiescence-timeout", detail: "Eager convergence did not reach codemap quiescence."))
            }
            if let projection {
                if !projection.isFullyMaterialized {
                    issues.append(.init(code: "convergence-projection", detail: "Convergence projection was not fully materialized."))
                }
                if let physicalRootID = projection.physicalRootRefs.first?.id,
                   let physicalFile = await store.file(rootID: physicalRootID, relativePath: firstPath)
                {
                    let expectedLogicalPath = canonical.appendingPathComponent(firstPath).standardizedFileURL.path
                    let logicalPath = projection.logicalDisplayPath(
                        forPhysicalPath: physicalFile.standardizedFullPath,
                        display: .full
                    )
                    if logicalPath != expectedLogicalPath {
                        issues.append(.init(code: "convergence-logical-projection", detail: "Linked codemap file did not preserve canonical logical display."))
                    }
                } else {
                    issues.append(.init(code: "convergence-physical-file", detail: "Materialized convergence root did not contain the expected physical file."))
                }
            }
            let linkedSource = try String(contentsOf: linked.appendingPathComponent(firstPath), encoding: .utf8)
            if linkedSource != files[firstPath] {
                issues.append(.init(code: "convergence-source-content", detail: "Linked convergence source did not match fixture content."))
            }

            let snapshot = collector.snapshot()
            let metrics = snapshot.metrics(
                for: .eagerBackgroundConvergence,
                storeID: storeID,
                rootRole: .linkedWorktree
            )
            let conservation = snapshot.conservation(
                requireReadyPublications: true,
                expectedFreshMisses: supportedFileCount
            )
            if let metrics,
               metrics.requestedFileCount != supportedFileCount
               || metrics.supportedFileCount != supportedFileCount
               || metrics.cacheMissCount != supportedFileCount
               || metrics.parseAttemptCount != supportedFileCount
               || metrics.acceptedReadyPublicationCount != supportedFileCount
               || metrics.droppedPublicationCount != 0
            {
                issues.append(.init(
                    code: "convergence-work-conservation",
                    detail: "Expected 64 requested/supported/miss/parse/accepted publications and zero drops."
                ))
            } else if metrics == nil {
                issues.append(.init(
                    code: "convergence-telemetry-missing",
                    detail: "Eager convergence produced no matching telemetry scope."
                ))
            }
            if !conservation.isValid {
                issues.append(.init(code: "convergence-telemetry-conservation", detail: conservation.issues.joined(separator: "; ")))
            }

            await materializer.release(sessionID: sessionID)
            if let physicalRootID = projection?.physicalRootRefs.first?.id,
               await store.roots().contains(where: { $0.id == physicalRootID })
            {
                issues.append(.init(code: "convergence-release", detail: "Released convergence worktree remained loaded."))
            }
            await store.cancelAllCodemapScans()
            await store.clearAllCodemapCaches(rootFolders: [linked.path])
            await unloadAllRoots(in: store)

            return WorkspaceLegacyCodemapConvergenceSample(
                ordinal: ordinal,
                phase: phase,
                supportedFileCount: supportedFileCount,
                firstReadyMilliseconds: milestones.firstMilliseconds,
                quarterReadyMilliseconds: milestones.quarterMilliseconds,
                halfReadyMilliseconds: milestones.halfMilliseconds,
                threeQuarterReadyMilliseconds: milestones.threeQuarterMilliseconds,
                allReadyMilliseconds: milestones.allMilliseconds,
                quiescentMilliseconds: quiescence.timedOut
                    ? nil
                    : workspaceFileSearchIndexElapsedMilliseconds(from: started, to: quiescentAt),
                metrics: metrics,
                conservation: conservation,
                validityIssues: issues
            )
        }

        private func legacyCohortSample(
            snapshot: LegacyCodeMapTelemetrySnapshot,
            cohort: LegacyCodeMapTelemetryCohort,
            semantic: String,
            storeID: UUID,
            rootRole: LegacyCodeMapTelemetryRootRole,
            latency: Double?,
            expectedCacheResult: LegacyCodeMapCacheResult?,
            expectedParseCount: Int?,
            requirePublication: Bool = true,
            actualCrossStoreAvoidance: Int = 0,
            actualCrossWorktreeAvoidance: Int = 0,
            sameBlobOpportunity: Int = 0,
            issues suppliedIssues: [WorkspaceBenchmarkValidityIssue]
        ) -> WorkspaceLegacyCodemapCohortSample {
            let matchingScopes = snapshot.scopes.filter {
                $0.scope.cohort == cohort
                    && $0.scope.storeID == storeID
                    && $0.scope.rootRole == rootRole
            }
            let scopedSnapshot = LegacyCodeMapTelemetrySnapshot(scopes: matchingScopes)
            let metrics = scopedSnapshot.metrics(
                for: cohort,
                storeID: storeID,
                rootRole: rootRole
            )
            let expectedMisses: Int? = expectedCacheResult.map { result in
                result == .absentMiss || result == .unusableMiss ? 1 : 0
            }
            let conservation = scopedSnapshot.conservation(
                requireReadyPublications: requirePublication,
                expectedFreshMisses: expectedMisses
            )
            var issues = suppliedIssues
            if metrics == nil {
                issues.append(.init(
                    code: "cohort-telemetry-missing",
                    detail: "\(cohort.rawValue) produced no matching telemetry scope."
                ))
            }
            if let metrics, let expectedCacheResult {
                if metrics.cacheResults[expectedCacheResult, default: 0] != 1
                    || metrics.cacheClassificationCount != 1
                {
                    issues.append(.init(
                        code: "unexpected-cache-result",
                        detail: "\(cohort.rawValue) expected one \(expectedCacheResult.rawValue) classification."
                    ))
                }
                if metrics.requestedFileCount != 1
                    || metrics.supportedFileCount != 1
                    || metrics.sourceRequestCount != 1
                    || metrics.successfulOpenCount != 1
                    || metrics.decodedFileCount != 1
                {
                    issues.append(.init(
                        code: "unexpected-source-work",
                        detail: "\(cohort.rawValue) expected one supported source request/open/decode."
                    ))
                }
            }
            if let metrics, let expectedParseCount, metrics.parseAttemptCount != expectedParseCount {
                issues.append(.init(
                    code: "unexpected-parse-count",
                    detail: "\(cohort.rawValue) expected \(expectedParseCount) parse attempts; found \(metrics.parseAttemptCount)."
                ))
            }
            if let metrics,
               requirePublication,
               metrics.acceptedReadyPublicationCount != 1 || metrics.droppedPublicationCount != 0
            {
                issues.append(.init(
                    code: "publication-conservation",
                    detail: "\(cohort.rawValue) expected one accepted publication and zero dropped publications."
                ))
            }
            if let metrics,
               cohort == .forcedResidentMemoryHit,
               metrics.rootCacheLoadAttemptCount != 0
            {
                issues.append(.init(
                    code: "memory-hit-root-load",
                    detail: "Forced-resident classification must not load the root cache during the measured interval."
                ))
            }
            if let metrics,
               cohort == .equivalentLinkedWorktree,
               metrics.duplicateParseCount != 1
            {
                issues.append(.init(
                    code: "linked-duplicate-parse",
                    detail: "Equivalent linked content must register one duplicate legacy parse."
                ))
            }
            return WorkspaceLegacyCodemapCohortSample(
                cohort: cohort,
                semantic: semantic,
                rootRole: rootRole,
                demandToReadyMilliseconds: latency,
                metrics: metrics,
                conservation: conservation,
                actualCrossStoreParseAvoidanceCount: actualCrossStoreAvoidance,
                actualCrossWorktreeParseAvoidanceCount: actualCrossWorktreeAvoidance,
                sameBlobAssociationOpportunityCount: sameBlobOpportunity,
                actualGitLocatorHitCount: 0,
                gitBlobByteCount: 0,
                validityIssues: issues
            )
        }

        private func codemapDemandIssues(
            repair: WorkspaceCodemapRepairResult,
            file: WorkspaceFileRecord,
            quiescence: CodemapQuiescenceWait,
            expectedContents: String
        ) -> [WorkspaceBenchmarkValidityIssue] {
            var issues: [WorkspaceBenchmarkValidityIssue] = []
            if repair.pendingFileIDs.contains(file.id) {
                issues.append(.init(code: "demand-ready-timeout", detail: "Requested file remained pending after explicit repair."))
            }
            if let snapshot = repair.snapshotsByFileID[file.id] {
                if snapshot.fileAPI == nil
                    || snapshot.rootID != file.rootID
                    || StandardizedPath.absolute(snapshot.fullPath) != file.standardizedFullPath
                {
                    issues.append(.init(code: "incorrect-ready-snapshot", detail: "Ready snapshot identity or renderable FileAPI was incorrect."))
                }
            } else {
                issues.append(.init(code: "missing-ready-snapshot", detail: "Explicit demand did not return the requested snapshot."))
            }
            let source = try? String(contentsOf: URL(fileURLWithPath: file.standardizedFullPath), encoding: .utf8)
            if source != expectedContents {
                issues.append(.init(code: "source-content-mismatch", detail: "Demanded source content did not match the fixture."))
            }
            if quiescence.timedOut {
                issues.append(.init(code: "codemap-quiescence-timeout", detail: "Demand cohort did not reach codemap quiescence."))
            }
            return issues
        }

        private func waitForLegacyPublication(
            collector: LegacyCodeMapTelemetryCollector,
            cohort: LegacyCodeMapTelemetryCohort,
            storeID: UUID,
            timeoutSeconds: Double = 10
        ) async -> Bool {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if collector.snapshot().metrics(for: cohort, storeID: storeID)?.acceptedReadyPublicationCount == 1 {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }

        private func waitForCodemapQuiescence(
            store: WorkspaceFileContextStore,
            timeoutSeconds: Double = 10
        ) async -> CodemapQuiescenceWait {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let snapshot = await store.codemapQuiescenceSnapshotForTesting()
                if snapshot.isQuiescent {
                    return CodemapQuiescenceWait(snapshot: snapshot, timedOut: false)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await CodemapQuiescenceWait(
                snapshot: store.codemapQuiescenceSnapshotForTesting(),
                timedOut: true
            )
        }

        private func waitForConvergenceMilestones(
            _ task: Task<CodemapConvergenceMilestones?, Never>,
            recorder: CodemapConvergenceRecorder,
            timeoutSeconds: Double = 30
        ) async -> CodemapConvergenceMilestones? {
            await withTaskGroup(of: CodemapConvergenceMilestones?.self) { group in
                group.addTask { await task.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                task.cancel()
                if let result {
                    return result
                }
                return await recorder.snapshot()
            }
        }

        private func runSortAttributionProbe() async throws -> WorkspaceFileSearchIndexSortDiagnostic {
            let fixture = try WorkspaceFileSearchIndexBenchmarkFixture.make()
            defer { fixture.remove() }

            let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            let worktreeRoot = try await store.loadRoot(
                path: fixture.worktreeRootURL.path,
                kind: .sessionWorktree
            )
            let scope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [fixture.worktreeRootURL.standardizedFileURL.path]
            )
            let before = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(
                store: store,
                rootID: worktreeRoot.id
            )
            let workBefore = await store.storeWorkDiagnosticsSnapshot()
            let catalogCacheBefore = await store.searchCatalogSnapshotCacheCountForTesting()
            let staticCacheBefore = await store.staticPathMatchSnapshotCacheCountForTesting()
            let sessionGenerationBefore = await store.sessionCatalogGenerationForTesting(scope: scope)
            let rootsBefore = await store.roots().map(\.id)

            let probe = await store.debugAuthoritativeCatalogSortProbe(rootScope: scope)

            let after = await WorkspaceFileSearchIndexBenchmarkCounterMark.capture(
                store: store,
                rootID: worktreeRoot.id
            )
            let workAfter = await store.storeWorkDiagnosticsSnapshot()
            let catalogCacheAfter = await store.searchCatalogSnapshotCacheCountForTesting()
            let staticCacheAfter = await store.staticPathMatchSnapshotCacheCountForTesting()
            let sessionGenerationAfter = await store.sessionCatalogGenerationForTesting(scope: scope)
            let rootsAfter = await store.roots().map(\.id)
            let counters = after.delta(from: before)
            let storeStateUnchanged = counterVector(counters).allSatisfy { $0 == 0 }
                && workAfter == workBefore
                && catalogCacheAfter == catalogCacheBefore
                && staticCacheAfter == staticCacheBefore
                && sessionGenerationAfter == sessionGenerationBefore
                && rootsAfter == rootsBefore

            try require(probe.status == .completed, "Sort attribution probe must complete")
            try require(
                probe.sourceFileCount == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount,
                "Sort attribution probe file count must match the fresh fixture"
            )
            try require(
                probe.sourceFolderCount == WorkspaceFileSearchIndexBenchmarkFixture.folderCount,
                "Sort attribution probe folder count must match the fresh fixture"
            )
            try require(probe.samples.count == 3, "Sort attribution probe must retain three samples")
            try require(
                probe.directAndProjectedOrdersMatch,
                "Sort attribution probe direct/projected ordering must match"
            )
            try require(storeStateUnchanged, "Sort attribution probe must not mutate store state")
            await unloadAllRoots(in: store)
            return WorkspaceFileSearchIndexSortDiagnostic(
                probe: probe,
                storeStateUnchanged: storeStateUnchanged
            )
        }

        private func coldCounterVectorIsValid(
            _ counters: WorkspaceFileSearchIndexBenchmarkCounters,
            pathIndexBuild: Int
        ) -> Bool {
            let vector = counterVector(counters)
            return vector == [1, 0, 1, 0, 1, pathIndexBuild, 0, 0, 1, 1]
                || vector == [1, 1, 1, 0, 1, pathIndexBuild, 0, 0, 1, 1]
        }

        private func counterVector(_ counters: WorkspaceFileSearchIndexBenchmarkCounters) -> [Int] {
            [
                counters.crawl,
                counters.appliedGeneration,
                counters.shardBuild,
                counters.patch,
                counters.authoritative,
                counters.pathIndexBuild,
                counters.overlayPathIndexBuild,
                counters.fallback,
                counters.catalogRebuild,
                counters.catalogInvalidation
            ]
        }

        private func require(
            _ condition: @autoclosure () -> Bool,
            _ message: String,
            diagnostics: String? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            guard condition() else {
                let failureMessage = diagnostics.map { "\(message); \($0)" } ?? message
                XCTFail(failureMessage, file: file, line: line)
                throw BenchmarkInvariantError(message: failureMessage)
            }
        }

        private func unloadAllRoots(in store: WorkspaceFileContextStore) async {
            let rootIDs = await store.roots().map(\.id)
            await store.unloadRoots(ids: rootIDs)
        }
    }
#endif
