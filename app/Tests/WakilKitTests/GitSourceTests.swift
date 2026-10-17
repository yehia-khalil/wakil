import Testing
@testable import WakilKit

private let ctx = ContextStore.ActiveContext(org: "o", project: "p", environment: "local")

/// A `GitSource` over a `GitStatus` that has read `files` for `/p/api` (3b-iii: the window's status).
private func source(_ files: [(String, String, String)], read: Bool = true) async -> GitSource {
    let git = FakeGit()
    await git.set(status: "/p/api", files: files)
    let status = GitStatus(git: git, roots: { ["/p/api"] })
    if read { await status.refresh() }
    return GitSource(status: status)
}

@Test func changedFilesAreIdentifiersByPathAndBaseName() async throws {
    let names = try await source([("app/Http/BookingController.php", "changed", "M")]).identifiers(for: ctx)
    #expect(names.contains { $0.text == "app/Http/BookingController.php" && $0.kind == .file })
    #expect(names.contains { $0.text == "BookingController" && $0.origin == "git · api" && $0.source == .panes })
}

@Test func aFileInTwoGroupsIsOneName() async throws {
    let names = try await source([("a/Foo.php", "staged", "M"), ("a/Foo.php", "changed", "M")]).identifiers(for: ctx)
    #expect(names.filter { $0.text == "a/Foo.php" }.count == 1)
    #expect(names.filter { $0.text == "Foo" }.count == 1)
}

@Test func nothingBeforeTheStatusIsRead() async throws {
    let names = try await source([("a/Foo.php", "changed", "M")], read: false).identifiers(for: ctx)
    #expect(names.isEmpty)
}

@Test func spokenBookingControllerResolvesToThePath() async throws {
    let names = try await source([("api/app/Http/BookingController.php", "changed", "M")]).identifiers(for: ctx)
    let r = IdentifierResolver.resolve("show me booking controller", in: Vocabulary(names))
    #expect(r.map(\.phrase) == ["booking controller"])
    #expect(r.first?.candidates.map(\.text) == ["BookingController"])
}
