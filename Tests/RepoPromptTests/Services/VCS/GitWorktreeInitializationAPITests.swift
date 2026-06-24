import Darwin
@testable import RepoPrompt
import XCTest

final class GitWorktreeInitializationAPITests: XCTestCase {
    func testBoundedAuthorityAPIsPreserveNULPathsAndExactRootPrefix() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let base = try await git.resolveTreeOID("HEAD", in: layout)

        let inventory = try await git.listTree(base, in: layout, prefix: prefix)
        XCTAssertEqual(inventory.prefixEntry?.repositoryRelativePath, "Root")
        XCTAssertEqual(inventory.entries.map(\.repositoryRelativePath), ["Root/old file.txt"])
        XCTAssertFalse(inventory.entries.contains { $0.repositoryRelativePath.hasPrefix("RootSibling/") })

        try fixture.rename("Root/old file.txt", to: "Root/new\nname.txt")
        try fixture.commitAll("rename")
        let target = try await git.resolveTreeOID("HEAD", in: layout)
        let delta = try await git.diffTrees(
            baseTreeOID: base,
            targetTreeOID: target,
            in: layout,
            prefix: prefix
        )
        XCTAssertEqual(delta.count, 1)
        XCTAssertEqual(delta[0].sourceRepositoryRelativePath, "Root/old file.txt")
        XCTAssertEqual(delta[0].repositoryRelativePath, "Root/new\nname.txt")
        guard case .renamed(score: 100) = delta[0].status else {
            return XCTFail("Expected an exact rename record")
        }

        let authority = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertEqual(authority.objectFormat, .sha1)
        XCTAssertEqual(authority.treeOID, target)
        XCTAssertEqual(authority.repositoryRelativeRootPrefix, prefix)
        XCTAssertFalse(authority.indexGeneration.isEmpty)
        XCTAssertFalse(authority.ignoreAuthorityGeneration.isEmpty)
        XCTAssertFalse(authority.attributeAuthorityGeneration.isEmpty)
        XCTAssertFalse(authority.sparsePolicyGeneration.isEmpty)

        try fixture.write("Root/staged\tname.txt", "staged\n")
        try fixture.git(["add", "--", "Root/staged\tname.txt"])
        try fixture.write("Root/untracked*name.txt", "untracked\n")
        let manifest = try await git.indexManifest(in: layout, prefix: prefix)
        XCTAssertTrue(manifest.entries.contains { $0.repositoryRelativePath == "Root/staged\tname.txt" })
        XCTAssertTrue(manifest.entries.contains { $0.repositoryRelativePath == "Root/new\nname.txt" })

        let status = try await git.worktreeStatus(in: layout, prefix: prefix)
        XCTAssertTrue(status.pathRecords.contains { $0.path == "Root/staged\tname.txt" })
        XCTAssertTrue(status.pathRecords.contains { $0.path == "Root/untracked*name.txt" })
        XCTAssertFalse(status.pathRecords.contains { $0.path.hasPrefix("RootSibling/") })
    }

    func testTreeInventoryCapsTimeoutAndCancellationReturnTypedReasonsWithoutPermitLeaks() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let tree = try await git.resolveTreeOID("HEAD", in: layout)
        let prefix = try GitRepositoryRelativeRootPrefix("Root")

        let recordLimited = GitWorktreeInitializationLimits(
            maximumRecordCount: 1,
            maximumOutputBytes: 1024 * 1024,
            commandTimeout: .seconds(5)
        )
        do {
            _ = try await git.listTree(tree, in: layout, prefix: prefix, limits: recordLimited)
            XCTFail("Expected the tree record cap to reject the inventory")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .recordLimitExceeded)
        }

        let byteLimited = GitWorktreeInitializationLimits(
            maximumRecordCount: 100,
            maximumOutputBytes: 8,
            commandTimeout: .seconds(5)
        )
        do {
            _ = try await git.listTree(tree, in: layout, prefix: prefix, limits: byteLimited)
            XCTFail("Expected the tree byte cap to reject the inventory")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .cappedOutput)
        }

        let sleepingExecutable = try fixture.makeSleepingGitExecutable()
        let admission = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
        let slowGit = GitService(
            gitExecutableURL: sleepingExecutable,
            processAdmissionController: admission,
            processTerminationGrace: .milliseconds(10)
        )
        let timeoutLimits = GitWorktreeInitializationLimits(
            maximumRecordCount: 100,
            maximumOutputBytes: 1024,
            commandTimeout: .milliseconds(20)
        )
        do {
            _ = try await slowGit.listTree(tree, in: layout, prefix: prefix, limits: timeoutLimits)
            XCTFail("Expected the bounded command timeout")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .timeout)
        }

        let cancellable = Task {
            try await slowGit.listTree(tree, in: layout, prefix: prefix)
        }
        for _ in 0 ..< 1000 {
            if await admission.snapshot().activeLeaseCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        cancellable.cancel()
        do {
            _ = try await cancellable.value
            XCTFail("Expected in-flight Git authority cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let finalAdmission = await admission.snapshot()
        XCTAssertEqual(finalAdmission.activeLeaseCount, 0)
    }

    func testAuthorityPolicyIdentityUsesResolvedExternalContentsAndHierarchicalPrefixControls() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root/Nested")
        let excludes = fixture.sandbox.appendingPathComponent("global excludes one")
        let equivalentExcludes = fixture.sandbox.appendingPathComponent("global excludes two")
        let attributes = fixture.sandbox.appendingPathComponent("global attributes")
        try "*.temporary\n".write(to: excludes, atomically: true, encoding: .utf8)
        try "*.temporary\n".write(to: equivalentExcludes, atomically: true, encoding: .utf8)
        try "*.binary binary\n".write(to: attributes, atomically: true, encoding: .utf8)
        try fixture.git(["config", "core.excludesFile", excludes.path])
        try fixture.git(["config", "core.attributesFile", attributes.path])

        try fixture.write(".gitignore", "root-control\n")
        try fixture.write("Root/.repo_ignore", "ancestor-control\n")
        try fixture.write("Root/Nested/.cursorignore", "prefix-control\n")
        try fixture.write("Root/Nested/Deep/.gitattributes", "*.json text\n")
        try fixture.write("Root/Outside/.gitignore", "outside-prefix\n")
        try fixture.write("RootSibling/.cursorignore", "sibling-prefix\n")

        let baseline = try await git.authorityMetadata(in: layout, prefix: prefix)
        let policy = baseline.policyIdentity
        XCTAssertEqual(policy.mandatoryIgnorePolicyIdentity, "git-ignore-policy-v1")
        XCTAssertEqual(policy.resolvedExcludesFileIdentity?.exists, true)
        XCTAssertEqual(policy.resolvedExcludesFileIdentity?.byteCount, "*.temporary\n".utf8.count)
        XCTAssertEqual(policy.resolvedAttributesFileIdentity?.exists, true)
        XCTAssertEqual(Set(baseline.resolvedExternalAuthorityPaths), Set([excludes, attributes]))
        XCTAssertEqual(
            policy.prefixControlIdentities.map(\.repositoryRelativePath),
            [
                ".gitignore",
                "Root/.repo_ignore",
                "Root/Nested/.cursorignore",
                "Root/Nested/Deep/.gitattributes"
            ]
        )

        try fixture.git(["config", "core.excludesFile", equivalentExcludes.path])
        let equivalentLocation = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertEqual(equivalentLocation.policyIdentity, baseline.policyIdentity)
        XCTAssertNotEqual(equivalentLocation.checkoutConfigurationGeneration, baseline.checkoutConfigurationGeneration)

        try fixture.write("RootSibling/.cursorignore", "changed but still sibling\n")
        let siblingMutation = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertEqual(siblingMutation.policyIdentity, equivalentLocation.policyIdentity)

        try "*.changed\n".write(to: equivalentExcludes, atomically: true, encoding: .utf8)
        let externalMutation = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertNotEqual(
            externalMutation.policyIdentity.resolvedExcludesFileIdentity,
            siblingMutation.policyIdentity.resolvedExcludesFileIdentity
        )
        XCTAssertNotEqual(
            externalMutation.policyIdentity.configuredIgnoreAuthorityDigest,
            siblingMutation.policyIdentity.configuredIgnoreAuthorityDigest
        )

        try fixture.write("Root/Nested/.cursorignore", "changed-prefix-control\n")
        let hierarchicalMutation = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertNotEqual(
            hierarchicalMutation.policyIdentity.prefixControlIdentities,
            externalMutation.policyIdentity.prefixControlIdentities
        )
        XCTAssertNotEqual(
            hierarchicalMutation.policyIdentity.committedIgnoreControlDigest,
            externalMutation.policyIdentity.committedIgnoreControlDigest
        )
    }

    func testParsersRejectSiblingPrefixesInvalidUTF8AndMissingNULTermination() throws {
        XCTAssertThrowsError(try GitRepositoryRelativeRootPrefix("Root/../escape"))
        let oid = try GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "1", count: 40))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let siblingRecord = Data("100644 blob \(oid.lowercaseHex)\tRootSibling/file\0".utf8)
        XCTAssertThrowsError(try GitTreeInventoryParser.parseTreeInventory(
            siblingRecord,
            treeOID: oid,
            rootPrefix: prefix,
            limits: .treeInventory
        ))

        var invalidUTF8 = Data("100644 blob \(oid.lowercaseHex)\tRoot/".utf8)
        invalidUTF8.append(0xFF)
        invalidUTF8.append(0)
        XCTAssertThrowsError(try GitTreeInventoryParser.parseTreeInventory(
            invalidUTF8,
            treeOID: oid,
            rootPrefix: prefix,
            limits: .treeInventory
        ))

        let unterminated = Data("100644 blob \(oid.lowercaseHex)\tRoot/file".utf8)
        XCTAssertThrowsError(try GitTreeInventoryParser.parseTreeInventory(
            unterminated,
            treeOID: oid,
            rootPrefix: prefix,
            limits: .treeInventory
        ))
    }
}

private struct GitInitializationFixture {
    let sandbox: URL
    let root: URL

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeInitializationAPITests-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init"])
        try git(["config", "user.name", "RepoPrompt Test"])
        try git(["config", "user.email", "repoprompt@example.test"])
        try git(["config", "commit.gpgSign", "false"])
        try write("Root/old file.txt", "base\n")
        try write("RootSibling/outside.txt", "outside\n")
        try commitAll("base")
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func rename(_ source: String, to destination: String) throws {
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(source),
            to: root.appendingPathComponent(destination)
        )
    }

    func commitAll(_ message: String) throws {
        try git(["add", "-A"])
        try git(["commit", "-m", message])
    }

    func makeSleepingGitExecutable() throws -> URL {
        let url = sandbox.appendingPathComponent("sleeping-git")
        try "#!/bin/sh\nsleep 10\n".write(to: url, atomically: true, encoding: .utf8)
        guard chmod(url.path, 0o755) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitWorktreeInitializationAPITests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}
