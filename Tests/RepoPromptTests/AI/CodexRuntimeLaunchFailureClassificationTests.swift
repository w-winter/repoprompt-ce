import Foundation
@testable import RepoPromptApp
import XCTest

/// Regression coverage for the Sentry PR #612 finding: post-resolution Codex runtime
/// launch failures (spawn errno 2 / errno 13) must produce the sentinel-prefixed
/// `RepoPrompt could not start Codex:` message so `codexFailurePhase` classifies them
/// as `.executableUnavailable` instead of the generic `.failed` phase.
final class CodexRuntimeLaunchFailureClassificationTests: XCTestCase {
    func testSpawnErrnoTwoDetailsProduceClassifiedExecutableUnavailableMessage() throws {
        let details = [
            "spawnFailed(errno: 2)",
            "ProcessLauncherError.spawnFailed(errno: 2)",
            "Failed to launch codex: No such file or directory",
            "zsh: command not found: codex"
        ]
        for detail in details {
            let message = try XCTUnwrap(
                CodexProviderHelpers.runtimeLaunchFailureMessage(fromFailureDetail: detail),
                "Expected launch-failure classification for detail: \(detail)"
            )
            XCTAssertTrue(
                CodexProviderHelpers.isCodexExecutableUnavailableMessage(message),
                "Classified message must satisfy the sentinel classifier for detail: \(detail)"
            )
            XCTAssertTrue(
                message.hasPrefix("RepoPrompt could not start Codex:"),
                "Classified message must carry the sentinel prefix for detail: \(detail)"
            )
        }
    }

    func testSpawnErrnoThirteenDetailsProduceClassifiedPermissionMessage() throws {
        let details = [
            "spawnFailed(errno: 13)",
            "ProcessLauncherError.spawnFailed(errno: 13)",
            "Failed to launch codex: Permission denied"
        ]
        for detail in details {
            let message = try XCTUnwrap(
                CodexProviderHelpers.runtimeLaunchFailureMessage(fromFailureDetail: detail),
                "Expected launch-failure classification for detail: \(detail)"
            )
            XCTAssertTrue(
                CodexProviderHelpers.isCodexExecutableUnavailableMessage(message),
                "Classified message must satisfy the sentinel classifier for detail: \(detail)"
            )
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("permission"),
                "Permission launch failures must keep permission-specific guidance for detail: \(detail)"
            )
        }
    }

    func testUnrelatedFailureDetailsAreNotClassifiedAsLaunchFailures() {
        let details = [
            "",
            "stream disconnected before completion",
            "429 Too Many Requests",
            "unauthorized",
            "Codex app-server request timed out after 30 seconds",
            "MCP client for `datadog` failed to start"
        ]
        for detail in details {
            XCTAssertNil(
                CodexProviderHelpers.runtimeLaunchFailureMessage(fromFailureDetail: detail),
                "Detail must not be classified as a runtime launch failure: \(detail)"
            )
        }
    }

    func testSentinelClassifierAcceptsPrefixedMessagesAndRejectsRewrittenGuidance() {
        XCTAssertTrue(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "RepoPrompt could not start Codex: the bundled package is missing. Reinstall RepoPrompt CE."
            )
        )
        XCTAssertTrue(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "\n  RepoPrompt could not start Codex: leading whitespace is tolerated."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "The selected Codex runtime could not be started. Reinstall RepoPrompt CE or configure a valid explicit override."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Permission denied. Ensure the 'codex' executable is accessible."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Codex is unavailable because RepoPrompt could not start Codex: (prefix must lead the message)"
            )
        )
    }
}
