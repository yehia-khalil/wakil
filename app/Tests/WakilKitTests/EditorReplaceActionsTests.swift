import Foundation
import Testing
@testable import WakilKit

/// a.go and b.go under /p/api and c.ts under /p/web, each holding "foo"; the Search view on "foo".
private func replaceFixture() async throws -> EditorFixture {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "let foo = 1\n")
    await f.files.put("/p/api/b.go", "foo()\nfoo()\n")
    await f.files.put("/p/web/c.ts", "const foo = 3\n")
    await f.files.setSearch([("/p/api", "a.go", 1, 5, "let foo = 1"), ("/p/api", "b.go", 1, 1, "foo()"),
                             ("/p/api", "b.go", 2, 1, "foo()"), ("/p/web", "c.ts", 1, 7, "const foo = 3")])
    try await f.dispatch("editor_search", ["query": .string("foo")])
    return f
}

@Test func replaceWritesTheClosedFilesAndRecordsTheUndo() async throws {
    let f = try await replaceFixture()
    let reply = try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nbar()\n")
    #expect(await f.files.text(of: "/p/web/c.ts") == "const bar = 3\n")
    let s = await f.snapshot().search.replace
    let last = try #require(s.last)
    #expect(last.replaced == 4 && last.files == 3 && last.failures.isEmpty && last.undoable && !s.inFlight)
    #expect(last.undo.map(\.path) == ["/p/api/a.go", "/p/api/b.go", "/p/web/c.ts"])
    #expect(last.undo[1].original == "foo()\nfoo()\n")
    #expect(s.shown && s.text == "bar")                         // the field shows what was replaced with
    guard case .object(let o) = reply else { Issue.record("no reply"); return }
    #expect(o["replaced"] == .number(4) && o["files"] == .number(3))
}

@Test func aDirtyOpenTabGetsABufferEditAndItsFileIsUntouched() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "let foo = 1 // mine\n", basis: 0)
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")     // its disk is never written
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "let bar = 1 // mine\n" && t.dirty)
    #expect(t.lastAgentEdit?.range == EditorRange(start: EditorPosition(line: 1, column: 5), end: EditorPosition(line: 1, column: 8)))
    #expect(t.lastAgentEdit?.text == "bar")
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(!last.undo.contains { $0.path == "/p/api/a.go" })              // buffer edits are ⌘Z's
    #expect(last.files == 3 && last.replaced == 4)
}

// Pre-flight F2: the store keeps the editor panes of the project's other conversations in memory
// (`everyScope`), and a file open there is "open in a pane of the window" too (spec, Open tabs).
@Test func aDirtyTabInAScopeNotOnScreenIsEditedInItsBufferAndItsFileIsNeverWritten() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let subject = await f.snapshot().tabs[0].subject
    await f.panes.editorBufferDidChange(paneId: f.pane, subject: subject, text: "let foo = 1 // mine\n", basis: 0)
    let home = await f.panes.activeScope
    await f.panes.switchScope(to: LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2"))
    try await f.dispatch("editor_search", ["query": .string("foo")])          // the other conversation's Search view
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")        // the hidden tab's file is not written
    let hidden = await f.panes.editorSnapshot(in: home, paneId: f.pane).tabs[0]
    #expect(hidden.text == "let bar = 1 // mine\n" && hidden.dirty)
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(!last.undo.contains { $0.path == "/p/api/a.go" } && last.files == 3 && last.replaced == 4)
}

// Review I1: a project or conversation switch while a replace runs. The run finishes in the scope it
// started in — its pane is not left in flight and keeps the undo — and the pane with the same id in
// the scope now on screen is untouched (no result, no re-search planted there).
@Test func aReplaceFinishesInTheScopeItStartedInAfterASwitch() async throws {
    let f = try await replaceFixture()
    await f.files.setSlowReplace(true)
    let home = await f.panes.activeScope
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace ")) { await Task.yield() }
    await f.panes.switchScope(to: LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2"))
    await f.files.releaseReplace()
    let reply = try await run.value
    let mine = await f.panes.editorSnapshot(in: home, paneId: f.pane).search.replace
    #expect(!mine.inFlight && !mine.cancelRequested)
    #expect(mine.last?.undo.map(\.path) == ["/p/api/a.go", "/p/api/b.go", "/p/web/c.ts"])
    let there = await f.snapshot().search
    #expect(there.query.isEmpty && there.replace.last == nil && !there.replace.inFlight)
    guard case .object(let o) = reply, case .object(let q)? = o["search"] else { Issue.record("no reply"); return }
    #expect(q["query"] == .string("foo") && o["replaced"] == .number(4))   // the home pane's state
}

@Test func anUndoFinishesInTheScopeItStartedInAfterASwitch() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    await f.files.setSlowRead(true)
    let home = await f.panes.activeScope
    let run = Task { try await f.dispatch("editor_replace_undo") }
    while !(await f.files.calls.contains { $0.hasPrefix("files_read") }) { await Task.yield() }
    await f.panes.switchScope(to: LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2"))
    await f.files.releaseRead()
    _ = try await run.value
    let mine = await f.panes.editorSnapshot(in: home, paneId: f.pane).search.replace
    #expect(!mine.inFlight && !mine.undoing && mine.last?.undone == true && mine.last?.restored == 3)
    #expect(await f.files.text(of: "/p/api/b.go") == "foo()\nfoo()\n")
    let there = await f.snapshot().search
    #expect(there.query.isEmpty && there.replace.last == nil && !there.replace.inFlight && !there.replace.undoing)
}

@Test func theStoreListsEveryEditorPaneOfEveryScopeWithItsPaths() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let home = await f.panes.activeScope
    let other = LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2")
    await f.panes.switchScope(to: other)
    try await f.dispatch("editor_open", ["path": .string("/p/web/c.ts")])
    var seen: [String: [String]] = [:]
    for ref in await f.panes.editorPanesInEveryScope() { seen["\(ref.scope.lineageRoot ?? "-")"] = ref.paths }
    #expect(seen == ["-": ["/p/api/a.go"], "conv-2": ["/p/web/c.ts"]])
}

// Pre-flight F7: a file open in two panes is one file with one count.
@Test func aFileOpenInTwoPanesIsCountedOnce() async throws {
    let f = try await replaceFixture()
    let other = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    try await f.dispatch("editor_open", ["pane": .string(other), "path": .string("/p/api/a.go")])
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.replaced == 4 && last.files == 3)              // a.go 1 once, not twice; b.go 2; c.ts 1
    #expect(await f.panes.editorSnapshot(paneId: other).tabs[0].text == "let bar = 1\n")
}

@Test func aTabOpenInAnotherEditorPaneIsEditedThere() async throws {
    let f = try await replaceFixture()
    let other = await f.layout.open(kind: "editor", title: "Editor").id
    try await f.dispatch("editor_open", ["pane": .string(other), "path": .string("/p/web/c.ts")])
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/web/c.ts") == "const foo = 3\n")
    #expect(await f.panes.editorSnapshot(paneId: other).tabs[0].text == "const bar = 3\n")
}

// Review Focus 1.
@Test func aBufferTypedInDuringTheReplaceIsReplacedAgainNotOverwritten() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.files.setSlowReplaceText(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace_text parked")) { await Task.yield() }
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "let foo = 1\nfoo typed\n", basis: 0)
    await f.files.releaseReplaceText()
    _ = try await run.value
    #expect(await f.snapshot().tabs[0].text == "let bar = 1\nbar typed\n")
}

@Test func aCancelStopsBetweenBatchesAndKeepsWhatWasWritten() async throws {
    let f = try await replaceFixture()
    await f.files.setReplaceBatch(1)
    await f.files.setSlowReplace(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace ")) { await Task.yield() }
    #expect(await f.snapshot().search.replace.inFlight)
    try await f.dispatch("editor_replace", ["cancel": .bool(true)])
    await f.files.releaseReplace()
    _ = try await run.value
    #expect(await f.files.text(of: "/p/api/a.go") == "let bar = 1\n")       // the batch in flight landed
    #expect(await f.files.text(of: "/p/api/b.go") == "foo()\nfoo()\n")
    let s = await f.snapshot().search.replace
    #expect(!s.inFlight && s.last?.cancelled == true && s.last?.undo.map(\.path) == ["/p/api/a.go"])
}

// Task 1 review, carried: the MCP client drops a cancelled call's reply, so a `files_replace` call in
// flight is never cancelled — even when the dispatch itself is. Its files reach the undo record, and
// the run stops before the next call.
@Test func cancellingTheDispatchMidCallStillRecordsThatCallsFilesForUndo() async throws {
    let f = try await replaceFixture()
    await f.files.setReplaceBatch(1)
    await f.files.setSlowReplace(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace ")) { await Task.yield() }
    run.cancel()
    await f.files.releaseReplace()
    _ = await run.result
    #expect(await f.files.text(of: "/p/api/a.go") == "let bar = 1\n")       // written by the call in flight
    #expect(await f.files.text(of: "/p/api/b.go") == "foo()\nfoo()\n")      // no call after it
    #expect(await f.files.calls.filter { $0 == "files_replace " }.count == 1)
    let s = await f.snapshot().search.replace
    #expect(!s.inFlight && s.last?.cancelled == true && s.last?.undo.map(\.path) == ["/p/api/a.go"])
}

@Test func undoShowsItsOwnStateAndItsCancelStopsItBetweenFiles() async throws {   // pre-flight F6
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    await f.files.setSlowRead(true)                                    // parks the undo's first files_read
    let run = Task { try await f.dispatch("editor_replace_undo") }
    while !(await f.files.calls.contains { $0.hasPrefix("files_read") }) { await Task.yield() }
    let during = await f.snapshot().search.replace
    #expect(during.inFlight && during.undoing)
    try await f.dispatch("editor_replace", ["cancel": .bool(true)])    // the same Cancel the view draws
    await f.files.releaseRead()
    _ = try await run.value
    let s = await f.snapshot().search.replace
    #expect(!s.inFlight && !s.undoing && !s.cancelRequested)
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")           // the file in hand was restored
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nbar()\n")          // later files were left, and listed
    let last = try #require(s.last)
    #expect(last.undone && last.restored == 1)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/b.go", error: EditorReplaceFailure.stopped),
                              EditorReplaceFailure(path: "/p/web/c.ts", error: EditorReplaceFailure.stopped)])
}

@Test func aSecondReplaceWhileOneRunsStartsNothing() async throws {
    let f = try await replaceFixture()
    await f.files.setSlowReplace(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace ")) { await Task.yield() }
    try await f.dispatch("editor_replace", ["replacement": .string("baz")])
    await f.files.releaseReplace()
    _ = try await run.value
    #expect(await f.files.calls.filter { $0 == "files_replace " }.count == 1)
    #expect(await f.files.text(of: "/p/web/c.ts") == "const bar = 3\n")
}

@Test func aFailedWriteIsListedWholeAndTheRestGoThrough() async throws {
    let f = try await replaceFixture()
    await f.files.setReplaceFailure("/p/api/b.go", "/p/api/b.go is not writable: permission denied")
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/b.go", error: "/p/api/b.go is not writable: permission denied")])
    #expect(await f.files.text(of: "/p/web/c.ts") == "const bar = 3\n")
}

@Test func anInvalidPatternIsGosErrorWholeAndRecordsNothing() async throws {
    let f = try await replaceFixture()
    await f.files.setReplaceError("error parsing regexp: missing closing ): `foo(`")
    do {
        try await f.dispatch("editor_replace", ["replacement": .string("bar")])
        Issue.record("expected Go's error")
    } catch { #expect(String(describing: error).contains("missing closing )")) }
    let s = await f.snapshot().search.replace
    #expect(s.last == nil && !s.inFlight)
}

@Test func fileLimitsTheReplaceToOneFileInsideTheRoots() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar"), "file": .string("/p/api/b.go")])
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nbar()\n")
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")
    #expect(await f.files.text(of: "/p/web/c.ts") == "const foo = 3\n")
    do {
        try await f.dispatch("editor_replace", ["replacement": .string("x"), "file": .string("/etc/hosts")])
        Issue.record("expected the refusal")
    } catch { #expect(String(describing: error).contains("Invariant 6")) }
}

@Test func aReplaceWithNoQueryChangesNothing() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "foo")
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/a.go") == "foo")
    #expect(await f.snapshot().search.replace.last == nil)
}

@Test func theSearchRunsAgainAfterAReplace() async throws {
    let f = try await replaceFixture()
    await f.files.setSearch([("/p/api", "a.go", 1, 5, "let foo = 1")])     // what is left
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let calls = await f.files.calls
    let replaced = try #require(calls.lastIndex(of: "files_replace "))
    #expect(calls[replaced...].contains { $0.hasPrefix("files_search") })
    #expect(await f.snapshot().search.results.map(\.path) == ["a.go"])
}

@Test func undoRestoresUnchangedFilesAndLeavesThoseChangedOrDeletedSince() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    await f.files.put("/p/api/b.go", "bar()\nmine\n")          // changed since: a new mtime
    await f.files.remove("/p/web/c.ts")                        // deleted since
    let reply = try await f.dispatch("editor_replace_undo")
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nmine\n")
    #expect(await f.files.text(of: "/p/web/c.ts") == nil)
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.undone && !last.undoable && last.restored == 1)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/b.go", error: EditorReplaceFailure.changedSince),
                              EditorReplaceFailure(path: "/p/web/c.ts", error: EditorReplaceFailure.changedSince)])
    guard case .object(let o) = reply else { Issue.record("no reply"); return }
    #expect(o["restored"] == .number(1))
}

@Test func undoWithNothingToUndoIsRefused() async throws {
    let f = try await replaceFixture()
    await #expect(throws: EditorActionError.nothingToUndo) { try await f.dispatch("editor_replace_undo") }
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    try await f.dispatch("editor_replace_undo")
    await #expect(throws: EditorActionError.nothingToUndo) { try await f.dispatch("editor_replace_undo") }
}

@Test func theReplaceFieldPreviewsEveryShownLineInOneCallAndKeepsItsText() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_search", ["replace": .string("bar")])
    let s = await f.snapshot().search
    #expect(s.replace.shown && s.replace.text == "bar" && s.query == "foo")
    #expect(s.replace.preview["foo()"] == [EditorReplaceEdit(start: 0, end: 3, text: "bar")])
    #expect(s.replace.preview.count == 3)
    #expect(await f.files.calls.filter { $0.hasPrefix("files_replace_text") }.count == 1)
    try await f.dispatch("editor_search", ["replace": .null])
    let closed = await f.snapshot().search.replace
    #expect(!closed.shown && closed.text == "bar" && closed.preview.isEmpty)   // Rule 2
}

// Pre-flight F1: `replace` with `query` sets the field and searches; it is not dropped.
@Test func searchWithBothAQueryAndAReplaceSetsTheFieldAndSearches() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/b.go", "foo()\n")
    await f.files.setSearch([("/p/api", "b.go", 1, 1, "foo()")])
    try await f.dispatch("editor_search", ["query": .string("foo"), "replace": .string("bar")])
    let s = await f.snapshot().search
    #expect(s.query == "foo" && s.results.map(\.path) == ["b.go"])
    #expect(s.replace.shown && s.replace.text == "bar")
    #expect(s.replace.preview["foo()"] == [EditorReplaceEdit(start: 0, end: 3, text: "bar")])
    try await f.dispatch("editor_search", ["query": .string("foo"), "replace": .null])
    #expect(await f.snapshot().search.replace.shown == false)
}

@Test func anEmptyReplaceFieldPreviewsDeletingTheMatches() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_search", ["replace": .string("")])
    #expect(await f.snapshot().search.replace.preview["foo()"] == [EditorReplaceEdit(start: 0, end: 3, text: "")])
}

@Test func newResultsArePreviewedAgain() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_search", ["replace": .string("bar")])
    await f.files.setSearch([("/p/api", "d.go", 1, 1, "foo baz")])
    try await f.dispatch("editor_search", ["query": .string("foo")])
    #expect(await f.snapshot().search.replace.preview.keys.sorted() == ["foo baz"])
}

@Test func readPaneReportsTheFieldTheFlightAndTheLastReplace() async throws {
    let f = try await replaceFixture()
    func search() async -> [String: JSONValue] {
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor"),
              case .object(let s)? = o["search"] else { return [:] }
        return s
    }
    let before = await search()
    #expect(before["replace"] == .null && before["last_replace"] == .null)
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let s = await search()
    #expect(s["replace"] == .string("bar") && s["replace_in_flight"] == .bool(false))
    #expect(s["last_replace"] == .object([
        "replaced": .number(4), "files": .number(3), "failures": .array([]), "undoable": .bool(true),
        "undone": .bool(false), "restored": .number(0), "cancelled": .bool(false),
        "files_truncated": .bool(false)]))
}

@Test func replaceAndUndoDeclareAllowEverywhere() async throws {
    let f = try await editorFixture()
    for name in ["editor_replace", "editor_replace_undo"] {
        let a = try #require(await f.registry.all().first { $0.name == name })
        #expect(a.kind == .mutate && a.audience == .agentReachable)
    }
    await f.files.put("/p/api/a.go", "foo")
    await f.files.setSearch([("/p/api", "a.go", 1, 1, "foo")])
    try await f.dispatch("editor_search", ["query": .string("foo")])
    try await f.dispatch("editor_replace", ["replacement": .string("bar")], origin: .agent, environment: "production")
    #expect(await f.files.text(of: "/p/api/a.go") == "bar")
}

// Final review C1: a project switch between batches. The run keeps the roots it claimed, so the next
// batch is refused (Go confines to the active project) rather than walking the new project's roots
// with the old cursor: no file of the second project is written, the refusal is listed, and the
// home pane keeps the undo of what the first batch wrote.
@Test func aProjectSwitchBetweenBatchesNeverWritesTheNewProjectsFiles() async throws {
    let f = try await replaceFixture()
    await f.files.put("/q/app/d.go", "foo\n")
    await f.files.setReplaceBatch(1)
    await f.files.setSlowReplace(true)
    let home = await f.panes.activeScope
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace ")) { await Task.yield() }
    await f.files.setActiveRoots(["/q/app"])
    await f.panes.switchScope(to: LayoutScope(organization: home.organization, project: "q", lineageRoot: nil))
    await f.files.releaseReplace()
    _ = await run.result
    #expect(await f.files.text(of: "/q/app/d.go") == "foo\n")              // never searched, never written
    #expect(await f.files.text(of: "/p/api/b.go") == "foo()\nfoo()\n")
    let mine = await f.panes.editorSnapshot(in: home, paneId: f.pane).search.replace
    #expect(!mine.inFlight)
    #expect(mine.last?.undo.map(\.path) == ["/p/api/a.go"])
    #expect(mine.last?.failures.count == 1)
    #expect(mine.last?.failures.first?.error.contains("outside the active project's roots") == true)
}

// Final review I2: a replace that changed nothing — no file written, no buffer edited, nothing
// listed — leaves the previous, still-undoable replace and its Undo as they were.
@Test func aSecondReplaceThatChangesNothingKeepsTheFirstOnesUndo() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let first = try #require(await f.snapshot().search.replace.last)
    try await f.dispatch("editor_search", ["query": .string("foo")])
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])     // nothing left to replace
    let s = await f.snapshot().search.replace
    #expect(s.last == first && s.last?.undoable == true)
}

@Test func aCancelBeforeTheFirstBatchKeepsTheFirstReplacesUndo() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let first = try #require(await f.snapshot().search.replace.last)
    await f.files.setSlowRoots(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("baz")]) }
    while !(await f.files.calls.contains("roots parked")) { await Task.yield() }
    try await f.dispatch("editor_replace", ["cancel": .bool(true)])
    await f.files.releaseRoots()
    _ = try await run.value
    let s = await f.snapshot().search.replace
    #expect(!s.inFlight && s.last == first && s.last?.undoable == true)
}

// Final review M4: the search that follows a replace never undoes the operator's newer search.
@Test func theSearchAfterAReplaceLeavesANewerSearchAsItIs() async throws {
    let f = try await replaceFixture()
    await f.files.setSlowReplace(true)
    let run = Task { try await f.dispatch("editor_replace", ["replacement": .string("bar")]) }
    while !(await f.files.calls.contains("files_replace ")) { await Task.yield() }
    await f.files.setSearch([("/p/api", "b.go", 1, 1, "foo()")])
    try await f.dispatch("editor_search", ["query": .string("foo("), "case": .bool(true)])
    let searches = await f.files.calls.filter { $0.hasPrefix("files_search") }.count
    await f.files.releaseReplace()
    _ = try await run.value
    let s = await f.snapshot().search
    #expect(s.query == "foo(" && s.caseSensitive)
    #expect(await f.files.calls.filter { $0.hasPrefix("files_search") }.count == searches)
}

// Final review M5 (Decision 39): the undo never writes a file open in a tab — one opened after the
// replace, in any editor pane of any scope — it leaves it and lists it.
@Test func undoLeavesAFileOpenedInATabSinceAndListsIt() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let home = await f.panes.activeScope
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    await f.panes.switchScope(to: LayoutScope(organization: home.organization, project: home.project, lineageRoot: "conv-2"))
    try await f.dispatch("editor_open", ["path": .string("/p/web/c.ts")])
    await f.panes.switchScope(to: home)
    try await f.dispatch("editor_replace_undo")
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")
    #expect(await f.files.text(of: "/p/api/b.go") == "bar()\nbar()\n")
    #expect(await f.files.text(of: "/p/web/c.ts") == "const bar = 3\n")
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.undone && last.restored == 1)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/b.go", error: EditorReplaceFailure.openInTab),
                              EditorReplaceFailure(path: "/p/web/c.ts", error: EditorReplaceFailure.openInTab)])
}

// Final review M6: files_replace's truncated_files reaches the record and the reply.
@Test func aReplacePastTheFileCapSaysSo() async throws {
    let f = try await replaceFixture()
    await f.files.setReplaceFilesTruncated(true)
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.filesTruncated)
    #expect(editorReplaceSummary(last).hasSuffix("only the first 50,000 files were replaced"))
}

// Final review M8 (Rule 8): a read-only tab whose file the search found is neither written (it is
// open) nor edited (it is read-only) — it is listed.
@Test func aReadOnlyTabWhoseFileMatchesIsListed() async throws {
    let f = try await replaceFixture()
    await f.files.putOverCap("/p/api/a.go", size: 3_000_000)
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    #expect(await f.snapshot().tabs[0].readOnly)
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.files.text(of: "/p/api/a.go") == "let foo = 1\n")
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/a.go", error: EditorReplaceFailure.readOnlyTab)])
    #expect(last.files == 2 && last.replaced == 3)
}

// Final review M8: a tab typed in during each of the three tries is left as the operator has it,
// and listed.
@Test func aTabStillTypedInAfterThreeTriesIsListed() async throws {
    let f = try await replaceFixture()
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let panes = f.panes, pane = f.pane
    await f.files.setOnReplaceText {                  // the operator types during every buffer try
        let s = await panes.editorSnapshot(paneId: pane)
        guard s.search.replace.inFlight else { return }  // not the preview after it
        await panes.editorBufferDidChange(paneId: pane, tab: 0, text: s.tabs[0].text + "foo\n", basis: 0)
    }
    try await f.dispatch("editor_replace", ["replacement": .string("bar")])
    #expect(await f.snapshot().tabs[0].text == "let foo = 1\nfoo\nfoo\nfoo\n")
    let last = try #require(await f.snapshot().search.replace.last)
    #expect(last.failures == [EditorReplaceFailure(path: "/p/api/a.go", error: EditorReplaceFailure.typedDuring)])
}
