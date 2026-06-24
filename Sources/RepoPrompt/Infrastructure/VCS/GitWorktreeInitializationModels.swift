import Darwin
import Foundation

struct GitWorkspaceAuthorityRepositoryKey: Hashable {
    let standardizedCommonDirectoryPath: String
    let standardizedGitDirectoryPath: String
    let commonDirectoryDevice: UInt64?
    let commonDirectoryInode: UInt64?

    init(layout: GitRepositoryLayout) {
        standardizedCommonDirectoryPath = layout.commonDir.standardizedFileURL.path
        standardizedGitDirectoryPath = layout.gitDir.standardizedFileURL.path
        var value = stat()
        if lstat(layout.commonDir.path, &value) == 0 {
            commonDirectoryDevice = UInt64(value.st_dev)
            commonDirectoryInode = UInt64(value.st_ino)
        } else {
            commonDirectoryDevice = nil
            commonDirectoryInode = nil
        }
    }
}

struct GitWorkspaceSearchABIIdentity: Hashable {
    let matcherSchemaVersion: Int
    let projectedKeySchemaVersion: Int
    let comparatorSchemaVersion: Int
    let pathNormalizationSchemaVersion: Int

    static let current = GitWorkspaceSearchABIIdentity(
        matcherSchemaVersion: 1,
        projectedKeySchemaVersion: 1,
        comparatorSchemaVersion: 1,
        pathNormalizationSchemaVersion: 1
    )
}

struct GitWorkspacePolicyIdentity: Hashable {
    let mandatoryIgnorePolicyIdentity: String
    let committedIgnoreControlDigest: String
    let configuredIgnoreAuthorityDigest: String
    let attributePolicyDigest: String
    let sparsePolicyDigest: String
    let searchABI: GitWorkspaceSearchABIIdentity
    let resolvedExcludesFileIdentity: GitWorkspaceAuthorityContentIdentity?
    let resolvedAttributesFileIdentity: GitWorkspaceAuthorityContentIdentity?
    let prefixControlIdentities: [GitWorkspacePrefixControlIdentity]
}

struct GitWorkspaceAuthorityContentIdentity: Hashable {
    let exists: Bool
    let sha256: String
    let byteCount: Int
}

enum GitWorkspacePrefixControlKind: String, Hashable {
    case gitignore
    case repoIgnore
    case cursorIgnore
    case gitAttributes
}

struct GitWorkspacePrefixControlIdentity: Hashable {
    let repositoryRelativePath: String
    let kind: GitWorkspacePrefixControlKind
    let content: GitWorkspaceAuthorityContentIdentity
}

struct GitWorkspaceAuthorityMetadata {
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let objectFormat: GitObjectFormat
    let headCommitOID: GitObjectID
    let treeOID: GitObjectID
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let indexGeneration: String
    let checkoutConfigurationGeneration: String
    let ignoreAuthorityGeneration: String
    let attributeAuthorityGeneration: String
    let sparsePolicyGeneration: String
    let metadataGeneration: String
    let policyIdentity: GitWorkspacePolicyIdentity
    let resolvedExternalAuthorityPaths: [URL]
}

struct GitWorkspaceAuthorityScopeKey: Hashable {
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
}

struct GitWorkspaceAuthorityCaptureToken: Hashable {
    let scopeKey: GitWorkspaceAuthorityScopeKey
    let invalidationGeneration: UInt64
    let scopePublicationGeneration: UInt64
    let acceptedMetadataWatermark: UInt64
}

/// Immutable identity required before a later content-addressed root/search
/// snapshot may be considered compatible. Target-local generations, records,
/// caches, and watcher state are intentionally excluded.
struct GitWorkspaceAuthoritySnapshot: Hashable {
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let repositoryNamespace: GitBlobRepositoryNamespace
    let objectFormat: GitObjectFormat
    let headCommitOID: GitObjectID
    let treeOID: GitObjectID
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let repositoryBindingEpoch: String
    let worktreeBindingEpoch: String
    let layoutGeneration: String
    let indexGeneration: String
    let checkoutConfigurationGeneration: String
    let metadataGeneration: String
    let policyIdentity: GitWorkspacePolicyIdentity
}

struct GitWorkspaceAuthorityLease: Hashable {
    let scopeKey: GitWorkspaceAuthorityScopeKey
    let authorityGeneration: UInt64
    let invalidationGeneration: UInt64
    let acceptedMetadataWatermark: UInt64
    let snapshot: GitWorkspaceAuthoritySnapshot

    var repositoryKey: GitWorkspaceAuthorityRepositoryKey {
        scopeKey.repositoryKey
    }
}

enum GitWorkspaceMutationKind: String, Hashable {
    case worktreeCreate
    case branchSwitch
    case fetch
    case mergeApply
    case mergeCommit
    case mergeContinue
    case mergeAbort
    case other
}

enum GitWorkspaceMutationOutcome: String, Hashable {
    case succeeded
    case failed
    case cancelled
}

struct GitWorkspaceMutationToken: Hashable {
    let id: UUID
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let affectedRepositoryKeys: Set<GitWorkspaceAuthorityRepositoryKey>
    let kind: GitWorkspaceMutationKind
    let correlationID: UUID?
}

enum GitWorkspaceMetadataEventKind: String, CaseIterable, Hashable {
    case dotGit
    case head
    case index
    case symbolicReference
    case packedReferences
    case references
    case configuration
    case ignoreAuthority
    case attributeAuthority
    case sparseCheckout
    case monitorGap
}

enum GitWorkspaceAuthorityUnavailableReason: String, Error, Equatable {
    case noSnapshot
    case mutationInProgress
    case metadataEventPending
    case monitorCoverageUnavailable
    case superseded
    case invalidatedDuringCollection
    case collectionScopeMismatch
}
