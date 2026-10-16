import Testing
@testable import WakilKit

private let ctx = ContextStore.ActiveContext(org: "o", project: "p", environment: "local")

private func row(_ path: String, _ group: GitGroup = .changed) -> GitFileRow {
    GitFileRow(path: path, origPath: nil, group: group, status: "M")
}

private func root(_ name: String, _ files: [GitFileRow]) -> GitRootState {
    GitRootState(root: "/p/\(name)", name: name, branch: "main", detached: "", ahead: 0, behind: 0,
                 files: files, error: nil, loading: false)
}

private func snapshot(_ roots: [GitRootState]) -> GitSnapshot {
    GitSnapshot(roots: roots, selection: nil, folded: false, diff: nil)
}

@Test func gitPaneFilesAreIdentifiersByPathAndBaseName() async throws {
    let (layout, panes, id) = await openGitPane()
    await panes.setGit(paneId: id, snapshot([root("api", [row("app/Http/BookingController.php")])]))
    let names = try await GitSource(layout: layout, panes: panes).identifiers(for: ctx)
    #expect(names.contains { $0.text == "app/Http/BookingController.php" && $0.kind == .file })
    #expect(names.contains { $0.text == "BookingController" && $0.origin == "git · api" && $0.source == .panes })
}

@Test func aFileInTwoGroupsIsOneName() async throws {
    let (layout, panes, id) = await openGitPane()
    await panes.setGit(paneId: id, snapshot([root("api", [row("a/Foo.php", .staged), row("a/Foo.php", .changed)])]))
    let names = try await GitSource(layout: layout, panes: panes).identifiers(for: ctx)
    #expect(names.filter { $0.text == "a/Foo.php" }.count == 1)
    #expect(names.filter { $0.text == "Foo" }.count == 1)
}

@Test func onlyGitPanesContribute() async throws {
    let (layout, panes, _) = await openGitPane()
    _ = await layout.open(kind: "terminal", title: "t")
    let names = try await GitSource(layout: layout, panes: panes).identifiers(for: ctx)
    #expect(names.isEmpty)
}

@Test func spokenBookingControllerResolvesToThePath() async throws {
    let (layout, panes, id) = await openGitPane()
    await panes.setGit(paneId: id, snapshot([root("api", [row("api/app/Http/BookingController.php")])]))
    let names = try await GitSource(layout: layout, panes: panes).identifiers(for: ctx)
    let r = IdentifierResolver.resolve("show me booking controller", in: Vocabulary(names))
    #expect(r.map(\.phrase) == ["booking controller"])
    #expect(r.first?.candidates.map(\.text) == ["BookingController"])
}
