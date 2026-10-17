import Foundation
import Testing
@testable import WakilKit

private func listing(_ root: String, files: [String] = [], ignored: [String] = [], heavy: [String] = [],
                     repos: [String] = [], truncated: Bool = false, error: String? = nil) -> EditorRootListing {
    EditorRootListing(root: root, files: files, ignored: ignored, heavy: heavy, repos: repos,
                      truncated: truncated, error: error)
}

private func names(_ rows: [EditorTreeRow]) -> [String] {
    rows.map { String(repeating: " ", count: $0.depth) + $0.name + ($0.dimmed ? "~" : "") }
}

@Test func aClosedRootIsOneRow() {
    let rows = editorTreeRows([listing("/p/api", files: ["a.go"])], open: [], dirs: [:], loading: [], dirErrors: [:])
    #expect(names(rows) == ["api"])
    #expect(rows[0].kind == .root && !rows[0].open)
}

@Test func anOpenRootListsFoldersFirstThenFilesEachSorted() {
    let l = listing("/p/api", files: ["z.go", "app/b.php", "a.go", "app/a.php"], ignored: [".env"], heavy: [".git", "vendor"])
    let rows = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(names(rows) == ["api", " .git~", " app", " vendor~", " .env~", " a.go", " z.go"])
    #expect(rows.first { $0.name == "vendor" }?.heavy == true)
}

@Test func aChildRepositoryIsItsOwnNode() {
    let l = listing("/code", files: ["api/main.go", "notes.md"], heavy: ["api/.git"], repos: ["api"])
    let rows = editorTreeRows([l], open: ["/code", "/code/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(rows.first { $0.name == "api" }?.kind == .repo)
    #expect(names(rows) == ["code", " api", "  .git~", "  main.go", " notes.md"])
}

// Final review I3: a repository nested in a repository root is a child-repo node, never a file
// row, even when it lists nothing (an empty repository) or a listing still names it "nested/".
@Test func aRepoNestedInARepoRootIsARepoNodeNeverAFile() {
    let l = listing("/p/app", files: ["app.php", "packages/deep/x.go", "stray/"], repos: ["packages/deep", "empty"])
    let rows = editorTreeRows([l], open: ["/p/app", "/p/app/packages"], dirs: [:], loading: [], dirErrors: [:])
    #expect(rows.first { $0.name == "deep" }?.kind == .repo)
    #expect(rows.first { $0.name == "empty" }?.kind == .repo)
    #expect(rows.first { $0.name == "stray" }?.kind == .folder)
    #expect(names(rows) == ["app", " empty", " packages", "  deep", " stray", " app.php"])
}

@Test func anOpenHeavyFolderShowsWhatWasLoadedAndALoadingOneSaysSo() {
    let l = listing("/p/api", files: ["a.go"], heavy: ["vendor"])
    let rows = editorTreeRows([l], open: ["/p/api", "/p/api/vendor"],
                              dirs: ["/p/api/vendor": [EditorDirEntry(name: "laravel", isDir: true), EditorDirEntry(name: "autoload.php", isDir: false)]],
                              loading: [], dirErrors: [:])
    #expect(names(rows) == ["api", " vendor~", "  laravel~", "  autoload.php~", " a.go"])
    let loading = editorTreeRows([l], open: ["/p/api", "/p/api/vendor"], dirs: [:], loading: ["/p/api/vendor"], dirErrors: [:])
    #expect(loading.first { $0.name == "vendor" }?.loading == true)
}

@Test func aFolderInsideAHeavyFolderListsWhatWasLoadedForIt() {
    let l = listing("/p/api", files: ["a.go"], heavy: ["vendor"])
    let rows = editorTreeRows([l], open: ["/p/api", "/p/api/vendor", "/p/api/vendor/laravel"],
                              dirs: ["/p/api/vendor": [EditorDirEntry(name: "laravel", isDir: true)],
                                     "/p/api/vendor/laravel": [EditorDirEntry(name: "framework", isDir: true),
                                                               EditorDirEntry(name: "x.php", isDir: false)]],
                              loading: [], dirErrors: [:])
    #expect(names(rows) == ["api", " vendor~", "  laravel~", "   framework~", "   x.php~", " a.go"])
}

@Test func aTruncatedRootSaysSoAtItsTop() {
    let rows = editorTreeRows([listing("/p/api", files: ["a.go"], truncated: true)], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(rows[1].kind == .note && rows[1].name == "only the first 50,000 files are listed")
}

@Test func aRootThatFailedCarriesItsErrorWholeAndTheOthersStillList() {
    let rows = editorTreeRows([listing("/p/api", error: "root /p/api is not readable: permission denied"),
                               listing("/p/web", files: ["i.ts"])],
                              open: ["/p/api", "/p/web"], dirs: [:], loading: [], dirErrors: [:])
    #expect(rows[0].error == "root /p/api is not readable: permission denied")
    #expect(names(rows) == ["api", "web", " i.ts"])
}

@Test func theSelectionStaysWhenItsRowSurvivesAndFallsToTheNearestWhenItDoesNot() {
    let before = editorTreeRows([listing("/p/api", files: ["a.go", "b.go", "c.go"])], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    let after = editorTreeRows([listing("/p/api", files: ["a.go", "c.go"])], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeSelection(after: "/p/api/a.go", previous: before, now: after) == "/p/api/a.go")
    #expect(editorTreeSelection(after: "/p/api/b.go", previous: before, now: after) == "/p/api/c.go")
    let empty = editorTreeRows([listing("/p/api")], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeSelection(after: "/p/api/c.go", previous: after, now: empty) == "/p/api")
}

@Test func arrowsStepAndTypingJumpsToTheNextNameWithThatPrefix() {
    let rows = editorTreeRows([listing("/p/api", files: ["alpha.go", "beta.go", "bravo.go"])], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeStep(rows, selected: nil, .down) == "/p/api")
    #expect(editorTreeStep(rows, selected: "/p/api/alpha.go", .down) == "/p/api/beta.go")
    #expect(editorTreeStep(rows, selected: "/p/api", .up) == "/p/api")
    #expect(editorTreeTypeAhead(rows, selected: "/p/api/beta.go", prefix: "b") == "/p/api/bravo.go")
    #expect(editorTreeTypeAhead(rows, selected: nil, prefix: "BR") == "/p/api/bravo.go")
}

@Test func leftClosesAnOpenFolderOrGoesToTheParent() {
    let rows = editorTreeRows([listing("/p/api", files: ["app/a.php"])], open: ["/p/api", "/p/api/app"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeLeft(rows, selected: "/p/api/app") == (collapse: "/p/api/app", select: nil))
    #expect(editorTreeLeft(rows, selected: "/p/api/app/a.php") == (collapse: nil, select: "/p/api/app"))
}

@Test func theWidthIsClampedBetween160AndHalfThePane() {
    #expect(editorColumnWidth(100, paneWidth: 1000) == 160)
    #expect(editorColumnWidth(700, paneWidth: 1000) == 500)
    #expect(editorColumnWidth(300, paneWidth: 1000) == 300)
    #expect(editorColumnWidth(240, paneWidth: 300) == 160)   // a narrow pane: the floor wins
}

// Review Focus 5.
@Test func pruneDropsOpenPathsThatNoLongerExist() {
    let l = listing("/p/api", files: ["app/a.php"], heavy: ["vendor"])
    #expect(editorPruneOpen(["/p/api", "/p/api/app", "/p/api/gone", "/p/api/vendor", "/p/old"], listings: [l])
            == ["/p/api", "/p/api/app", "/p/api/vendor"])
}

@Test func pruneKeepsAFolderThatHoldsOnlyAHeavyFolder() {
    let l = listing("/p/api", files: ["a.go"], heavy: ["web/node_modules"])
    #expect(editorPruneOpen(["/p/api/web", "/p/api/web/node_modules"], listings: [l])
            == ["/p/api/web", "/p/api/web/node_modules"])
}

@Test func aListingIsReadFromFilesListsReply() {
    let l = EditorRootListing(root: "/p/api", content: [
        "files": .array([.string("a.go")]), "ignored": .array([.string(".env")]),
        "heavy": .array([.string(".git")]), "repos": .array([]), "truncated": .bool(false)])
    #expect(l == listing("/p/api", files: ["a.go"], ignored: [".env"], heavy: [".git"]))
}

// Task 8 ruling 6: the "only the first 50,000 files are listed" note is not a row the selection rests on.
@Test func theTruncationNoteIsNeverSelected() {
    let rows = editorTreeRows([listing("/p/api", files: ["a.go", "b.go"], truncated: true)], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(rows[1].id == "note:/p/api")
    #expect(editorTreeStep(rows, selected: "/p/api", .down) == "/p/api/a.go")
    #expect(editorTreeStep(rows, selected: "/p/api/a.go", .up) == "/p/api")
    // ← from the note (however it got there) goes to its root, never to a row that does not exist.
    #expect(editorTreeLeft(rows, selected: "note:/p/api") == (collapse: nil, select: "/p/api"))
    // A selection whose row went falls past the note, to the root.
    let gone = editorTreeRows([listing("/p/api", truncated: true)], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    #expect(editorTreeSelection(after: "/p/api/a.go", previous: rows, now: gone) == "/p/api")
}

// 3b-v part 2: show ignored files off drops them from the tree; heavy folders stay.
@Test func hidingIgnoredFilesDropsThemAndKeepsTheHeavyFolders() {
    let l = listing("/p/api", files: ["a.go"], ignored: [".env", "storage/l.log"], heavy: [".git", "vendor"])
    let rows = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:], showIgnored: false)
    #expect(names(rows) == ["api", " .git~", " vendor~", " a.go"])
}

// Review Focus 4.
@Test func hidingIgnoredFilesMovesTheSelectionOffAHiddenRow() {
    let l = listing("/p/api", files: ["a.go", "b.go"], ignored: [".env"])
    let before = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    let after = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:], showIgnored: false)
    #expect(editorTreeSelection(after: "/p/api/.env", previous: before, now: after) == "/p/api/a.go")
}

@Test func anEmptyFolderIsAFolderRow() {
    var l = EditorRootListing(root: "/p/api", files: ["a.go"], ignored: [], heavy: [], repos: [], truncated: false, error: nil)
    l.empty = ["made"]
    let rows = editorTreeRows([l], open: ["/p/api"], dirs: [:], loading: [], dirErrors: [:])
    let made = rows.first { $0.id == "/p/api/made" }
    #expect(made?.kind == .folder && made?.open == false)
    #expect(rows.firstIndex { $0.id == "/p/api/made" }! < rows.firstIndex { $0.id == "/p/api/a.go" }!)   // folders first
}
