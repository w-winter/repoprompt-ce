import XCTest

final class PromptResourceMirrorRemovalTests: XCTestCase {
    func testBundledPromptMirrorBoundaryPreservesCanonicalSourcesWithoutStaleReferences() throws {
        let repoRoot = try RepoRoot.url(filePath: #filePath)
        let bundledPromptMirror = repoRoot.appendingPathComponent(resourcePromptMirrorPath, isDirectory: true)
        let canonicalLegacyPrompts = repoRoot.appendingPathComponent(canonicalPromptSourcePath, isDirectory: true)
            .appendingPathComponent("Legacy", isDirectory: true)

        var isDirectory: ObjCBool = false
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundledPromptMirror.path, isDirectory: &isDirectory),
            "Prompt Swift sources must live under \(canonicalPromptSourcePath), not bundled AppResources."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: canonicalLegacyPrompts.path, isDirectory: &isDirectory) && isDirectory.boolValue,
            "Legacy compiled prompt sources are intentionally preserved."
        )

        let scannedRoots = ["Sources", "Tests"].map { repoRoot.appendingPathComponent($0, isDirectory: true) }
        let forbiddenFragments = [resourcePromptMirrorPath, resourcePromptMirrorPathWithoutAppResources]

        for file in try swiftFiles(under: scannedRoots) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let displayPath = RepoRoot.relativePath(for: file, relativeTo: repoRoot)

            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    contents.contains(fragment),
                    "\(displayPath) must not reference bundled prompt mirror path fragment \(fragment)."
                )
            }
        }
    }
}

private let appResourcesComponent = "AppResources"
private let servicesComponent = "Services"
private let aiComponent = "AI"
private let promptsComponent = "Prompts"
private let canonicalPromptSourcePath = ["Sources", "RepoPrompt", "Infrastructure", aiComponent, promptsComponent].joined(separator: "/")
private let resourcePromptMirrorPathWithoutAppResources = [servicesComponent, aiComponent, promptsComponent].joined(separator: "/")
private let resourcePromptMirrorPath = [appResourcesComponent, resourcePromptMirrorPathWithoutAppResources].joined(separator: "/")

private func swiftFiles(under roots: [URL], fileManager: FileManager = .default) throws -> [URL] {
    var files: [URL] = []

    for root in roots {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }

        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(file)
            }
        }
    }

    return files
}
