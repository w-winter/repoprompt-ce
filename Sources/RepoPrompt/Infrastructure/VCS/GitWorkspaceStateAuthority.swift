import Foundation

/// Owns currentness and metadata observation for worktree bootstrap. Collection
/// is always bracketed by a scope-bound capture token and conditional install;
/// reusable snapshot storage/eviction remains a later slice.
actor GitWorkspaceStateAuthority {
    static let shared = GitWorkspaceStateAuthority()

    #if DEBUG
        struct Snapshot: Equatable {
            let recordCount: Int
            let publishedScopeCount: Int
            let activeMutationCount: Int
            let metadataEventCount: Int
            let authorityGenerations: [GitWorkspaceAuthorityRepositoryKey: UInt64]
        }
    #endif

    private struct Record {
        var invalidationGeneration: UInt64 = 0
        var mutationDepth: Int = 0
        var metadataEventCount: Int = 0
        var monitorCoverageUnavailable = false
        var snapshotsByScope: [GitWorkspaceAuthorityScopeKey: GitWorkspaceAuthoritySnapshot] = [:]
        var publicationGenerationByScope: [GitWorkspaceAuthorityScopeKey: UInt64] = [:]
        var acceptedWatermarkByScope: [GitWorkspaceAuthorityScopeKey: UInt64] = [:]
    }

    private let metadataMonitor: GitWorkspaceMetadataMonitor
    private var records: [GitWorkspaceAuthorityRepositoryKey: Record] = [:]
    private var activeMutations: [UUID: GitWorkspaceMutationToken] = [:]

    init(metadataMonitor: GitWorkspaceMetadataMonitor = GitWorkspaceMetadataMonitor()) {
        self.metadataMonitor = metadataMonitor
    }

    func beginCollection(
        scopeKey: GitWorkspaceAuthorityScopeKey
    ) -> Result<GitWorkspaceAuthorityCaptureToken, GitWorkspaceAuthorityUnavailableReason> {
        let record = records[scopeKey.repositoryKey] ?? Record()
        guard record.mutationDepth == 0 else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        records[scopeKey.repositoryKey] = record
        return .success(GitWorkspaceAuthorityCaptureToken(
            scopeKey: scopeKey,
            invalidationGeneration: record.invalidationGeneration,
            scopePublicationGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            acceptedMetadataWatermark: metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey)
        ))
    }

    func collectAndInstall(
        scopeKey: GitWorkspaceAuthorityScopeKey,
        collector: @Sendable () async throws -> GitWorkspaceAuthoritySnapshot
    ) async throws -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let token: GitWorkspaceAuthorityCaptureToken
        switch beginCollection(scopeKey: scopeKey) {
        case let .success(value): token = value
        case let .failure(reason): return .failure(reason)
        }
        let snapshot = try await collector()
        return install(snapshot, capturedUsing: token)
    }

    @discardableResult
    func install(
        _ snapshot: GitWorkspaceAuthoritySnapshot,
        capturedUsing token: GitWorkspaceAuthorityCaptureToken
    ) -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: snapshot.repositoryKey,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix
        )
        guard scopeKey == token.scopeKey else { return .failure(.collectionScopeMismatch) }
        guard var record = records[scopeKey.repositoryKey] else {
            return .failure(.invalidatedDuringCollection)
        }
        guard record.mutationDepth == 0 else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        guard record.invalidationGeneration == token.invalidationGeneration,
              (record.publicationGenerationByScope[scopeKey] ?? 0) == token.scopePublicationGeneration,
              metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey) == token.acceptedMetadataWatermark
        else {
            return .failure(.invalidatedDuringCollection)
        }

        let lease = metadataMonitor.withCurrentAcceptedWatermark(
            for: scopeKey.repositoryKey,
            expected: token.acceptedMetadataWatermark
        ) {
            let publicationGeneration = token.scopePublicationGeneration &+ 1
            record.publicationGenerationByScope[scopeKey] = publicationGeneration
            record.snapshotsByScope[scopeKey] = snapshot
            record.acceptedWatermarkByScope[scopeKey] = token.acceptedMetadataWatermark
            records[scopeKey.repositoryKey] = record
            return GitWorkspaceAuthorityLease(
                scopeKey: scopeKey,
                authorityGeneration: publicationGeneration,
                invalidationGeneration: record.invalidationGeneration,
                acceptedMetadataWatermark: token.acceptedMetadataWatermark,
                snapshot: snapshot
            )
        }
        guard let lease else { return .failure(.invalidatedDuringCollection) }
        return .success(lease)
    }

    /// Test/support convenience for an already collected immutable value. There
    /// is no suspension between token issue and conditional installation.
    @discardableResult
    func install(_ snapshot: GitWorkspaceAuthoritySnapshot) throws -> GitWorkspaceAuthorityLease {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: snapshot.repositoryKey,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix
        )
        let token: GitWorkspaceAuthorityCaptureToken
        switch beginCollection(scopeKey: scopeKey) {
        case let .success(value): token = value
        case let .failure(reason): throw reason
        }
        switch install(snapshot, capturedUsing: token) {
        case let .success(lease): return lease
        case let .failure(reason): throw reason
        }
    }

    func currentLease(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: repositoryKey,
            repositoryRelativeRootPrefix: prefix
        )
        guard let record = records[repositoryKey] else { return .failure(.noSnapshot) }
        guard record.mutationDepth == 0 else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        guard let snapshot = record.snapshotsByScope[scopeKey] else { return .failure(.metadataEventPending) }
        let watermark = metadataMonitor.acceptedWatermark(for: repositoryKey)
        guard record.acceptedWatermarkByScope[scopeKey] == watermark else {
            return .failure(.invalidatedDuringCollection)
        }
        return .success(GitWorkspaceAuthorityLease(
            scopeKey: scopeKey,
            authorityGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            invalidationGeneration: record.invalidationGeneration,
            acceptedMetadataWatermark: watermark,
            snapshot: snapshot
        ))
    }

    func isCurrent(_ lease: GitWorkspaceAuthorityLease) -> Bool {
        guard let record = records[lease.repositoryKey] else { return false }
        return record.mutationDepth == 0
            && !record.monitorCoverageUnavailable
            && record.invalidationGeneration == lease.invalidationGeneration
            && record.publicationGenerationByScope[lease.scopeKey] == lease.authorityGeneration
            && record.snapshotsByScope[lease.scopeKey] == lease.snapshot
            && record.acceptedWatermarkByScope[lease.scopeKey] == lease.acceptedMetadataWatermark
            && metadataMonitor.acceptedWatermark(for: lease.repositoryKey) == lease.acceptedMetadataWatermark
    }

    func beginMutation(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kind: GitWorkspaceMutationKind,
        correlationID: UUID? = nil
    ) -> GitWorkspaceMutationToken {
        let affectedKeys = Set(records.keys.filter { Self.sameCommonDirectory($0, repositoryKey) })
            .union([repositoryKey])
        let token = GitWorkspaceMutationToken(
            id: UUID(),
            repositoryKey: repositoryKey,
            affectedRepositoryKeys: affectedKeys,
            kind: kind,
            correlationID: correlationID
        )
        for key in affectedKeys {
            var record = records[key] ?? Record()
            record.mutationDepth += 1
            record.invalidationGeneration &+= 1
            record.snapshotsByScope.removeAll(keepingCapacity: true)
            records[key] = record
        }
        activeMutations[token.id] = token
        return token
    }

    /// Completion balances mutation state exactly once. Invalidation occurs at
    /// begin, so a collection spanning even a failed/cancelled mutation cannot
    /// reinstall stale evidence.
    func finishMutation(
        _ token: GitWorkspaceMutationToken,
        outcome _: GitWorkspaceMutationOutcome
    ) {
        guard activeMutations.removeValue(forKey: token.id) != nil else { return }
        for key in token.affectedRepositoryKeys {
            var record = records[key] ?? Record()
            record.mutationDepth = max(0, record.mutationDepth - 1)
            records[key] = record
        }
    }

    func metadataDidChange(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kinds: Set<GitWorkspaceMetadataEventKind>
    ) {
        var record = records[repositoryKey] ?? Record()
        record.metadataEventCount &+= 1
        record.invalidationGeneration &+= 1
        record.snapshotsByScope.removeAll(keepingCapacity: true)
        if kinds.contains(.monitorGap) {
            record.monitorCoverageUnavailable = true
        }
        records[repositoryKey] = record
    }

    func retainMetadataObservation(
        for layout: GitRepositoryLayout,
        additionalAuthorityPaths: [URL] = []
    ) async throws -> GitWorkspaceMetadataMonitor.RetainToken {
        let key = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        let paths = Self.metadataPaths(for: layout) + additionalAuthorityPaths
        let token = try await metadataMonitor.retain(repositoryKey: key, paths: paths) { [weak self] kinds in
            Task { await self?.metadataDidChange(repositoryKey: key, kinds: kinds) }
        }
        var record = records[key] ?? Record()
        if record.monitorCoverageUnavailable {
            record.monitorCoverageUnavailable = false
            record.invalidationGeneration &+= 1
            record.snapshotsByScope.removeAll(keepingCapacity: true)
        }
        records[key] = record
        return token
    }

    func releaseMetadataObservation(_ token: GitWorkspaceMetadataMonitor.RetainToken) async {
        await metadataMonitor.release(token)
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            Snapshot(
                recordCount: records.count,
                publishedScopeCount: records.values.reduce(0) { $0 + $1.snapshotsByScope.count },
                activeMutationCount: activeMutations.count,
                metadataEventCount: records.values.reduce(0) { $0 + $1.metadataEventCount },
                authorityGenerations: records.mapValues(\.invalidationGeneration)
            )
        }

        func metadataMonitorForTesting() -> GitWorkspaceMetadataMonitor {
            metadataMonitor
        }
    #endif

    private nonisolated static func sameCommonDirectory(
        _ lhs: GitWorkspaceAuthorityRepositoryKey,
        _ rhs: GitWorkspaceAuthorityRepositoryKey
    ) -> Bool {
        lhs.standardizedCommonDirectoryPath == rhs.standardizedCommonDirectoryPath
            && lhs.commonDirectoryDevice == rhs.commonDirectoryDevice
            && lhs.commonDirectoryInode == rhs.commonDirectoryInode
    }

    private nonisolated static func metadataPaths(for layout: GitRepositoryLayout) -> [URL] {
        [
            layout.dotGitPath,
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.gitDir.appendingPathComponent("index"),
            layout.gitDir.appendingPathComponent("config.worktree"),
            layout.gitDir.appendingPathComponent("info/sparse-checkout"),
            layout.commonDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("packed-refs"),
            layout.commonDir.appendingPathComponent("refs", isDirectory: true),
            layout.commonDir.appendingPathComponent("config"),
            layout.commonDir.appendingPathComponent("info/exclude"),
            layout.commonDir.appendingPathComponent("info/attributes")
        ]
    }
}
