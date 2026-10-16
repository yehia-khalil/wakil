import Foundation
import Testing
@testable import WakilKit

private func git(_ root: URL, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root.path] + args
    try p.run(); p.waitUntilExit()
    try #require(p.terminationStatus == 0)
}

private let commitArgs = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm"]

private func makeRepo(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codesource-\(UUID().uuidString)")
    for (path, body) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
    try git(root, ["init", "-q"])
    try git(root, ["add", "-A"])
    try git(root, commitArgs + ["seed"])
    return root
}

private func context(_ roots: [URL]) -> ContextStore.ActiveContext {
    ContextStore.ActiveContext(org: "org", project: "proj", environment: "env", rootPaths: roots.map(\.path))
}

@Test func compoundNamesTakesJoinedWordsOnly() {
    let names = CodeSource.compoundNames(in: "let describeEditability = edit_quote + events; AssertSQLMutation(x) acc-staging-core-write")
    #expect(Set(names) == ["describeEditability", "edit_quote", "AssertSQLMutation", "acc-staging-core-write"])
}

@Test func scansTrackedFilesAndSkipsVendoredOnes() async throws {
    let root = try makeRepo([
        "Sources/Pane.swift": "func buildLaunch() { describeEditability() }",
        "vendor/lib.go": "func vendoredThing() {}",
    ])
    let source = CodeSource(cacheDirectory: root.appendingPathComponent(".cache"))
    let texts = Set(try await source.identifiers(for: context([root])).map(\.text))
    #expect(texts.isSuperset(of: ["buildLaunch", "describeEditability", "Pane.swift"]))
    #expect(!texts.contains("vendoredThing"))
}

@Test func capKeepsTheMostFrequentNames() async throws {
    let root = try makeRepo(["a.txt": "common_name common_name common_name rare_name"])
    let source = CodeSource(cacheDirectory: root.appendingPathComponent(".cache"), cap: 1)
    let texts = try await source.identifiers(for: context([root])).map(\.text)
    #expect(texts == ["common_name"])
}

/// Spec §The four sources: a root that is not a git repository
/// contributes nothing, and the other roots' names survive it. Its failure
/// comes back as a partial failure, so `VocabularyStore` journals it.
@Test func aRootThatIsNotAGitRepositoryKeepsTheOtherRootsNames() async throws {
    let good = try makeRepo(["a.swift": "good_name"])
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    let gathered = try await CodeSource(cacheDirectory: good.appendingPathComponent(".cache"))
        .gather(for: context([plain, good]))
    #expect(Set(gathered.names.map(\.text)).contains("good_name"))
    #expect(gathered.failures.count == 1)
    #expect(gathered.failures.first?.contains(plain.path) == true)
}

/// Every root failed: nothing answered, so the source throws whole.
@Test func everyRootFailingThrows() async throws {
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    await #expect(throws: CodeSourceError.self) {
        _ = try await CodeSource(cacheDirectory: plain.appendingPathComponent(".cache")).gather(for: context([plain]))
    }
}

@Test func theCacheIsReusedUntilHeadMoves() async throws {
    let root = try makeRepo(["a.swift": "first_name"])
    let cache = root.appendingPathComponent(".cache")
    let source = CodeSource(cacheDirectory: cache)
    _ = try await source.identifiers(for: context([root]))
    // Change the working tree without committing: HEAD is unchanged, so the cache answers.
    try "second_name".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
    #expect(Set(try await source.identifiers(for: context([root])).map(\.text)).contains("first_name"))
    // Commit: HEAD moves, so it rescans.
    try git(root, ["add", "-A"])
    try git(root, commitArgs + ["two"])
    #expect(Set(try await source.identifiers(for: context([root])).map(\.text)).contains("second_name"))
}

@Test func aFileOverHalfAMegabyteContributesNoNames() async throws {
    let big = "huge_name " + String(repeating: "x", count: 600 * 1024)
    let root = try makeRepo(["big.txt": big, "small.txt": "small_name"])
    let texts = Set(try await CodeSource(cacheDirectory: root.appendingPathComponent(".cache"))
        .identifiers(for: context([root])).map(\.text))
    #expect(texts.contains("small_name"))
    #expect(texts.contains("big.txt"))
    #expect(!texts.contains("huge_name"))
}

@Test func aNewCommitReplacesTheRootsOldCacheFile() async throws {
    let root = try makeRepo(["a.swift": "first_name"])
    let cache = root.appendingPathComponent(".cache")
    let source = CodeSource(cacheDirectory: cache)
    _ = try await source.identifiers(for: context([root]))
    try "second_name".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
    try git(root, ["add", "-A"])
    try git(root, commitArgs + ["two"])
    _ = try await source.identifiers(for: context([root]))
    let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
    #expect(files.filter { $0.hasPrefix("v1-") && $0.hasSuffix(".txt") }.count == 1)
}

@Test func aNameUnderNodeModulesIsSkipped() async throws {
    let root = try makeRepo(["node_modules/pkg/index.js": "hidden_name", "src/app.js": "shown_name"])
    let texts = Set(try await CodeSource(cacheDirectory: root.appendingPathComponent(".cache"))
        .identifiers(for: context([root])).map(\.text))
    #expect(texts.contains("shown_name"))
    #expect(!texts.contains("hidden_name"))
}

/// A tracked symlink is skipped: following it could read a file outside
/// the root, or one over the size cap that the link itself hides.
@Test func aTrackedSymlinkIsSkipped() async throws {
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).txt")
    try "linked_name".write(to: outside, atomically: true, encoding: .utf8)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codesource-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "real_name".write(to: root.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
    try git(root, ["init", "-q"])
    try git(root, ["add", "-A"])
    try git(root, commitArgs + ["seed"])
    let texts = Set(try await CodeSource(cacheDirectory: root.appendingPathComponent(".cache"))
        .identifiers(for: context([root])).map(\.text))
    #expect(texts.contains("real_name"))
    #expect(!texts.contains("linked_name"))
    #expect(!texts.contains("link.txt"))
}
