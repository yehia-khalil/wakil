import Foundation
import Testing
@testable import WakilKit

@Test func findReturnsEveryMatchAndSetsTheFindRequest() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "x bookingId\nbookingId")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    let reply = try await f.dispatch("editor_find", ["query": .string("bookingId")])
    guard case .object(let o) = reply, case .array(let matches)? = o["matches"] else { Issue.record("no matches"); return }
    #expect(matches.count == 2)
    #expect(await f.snapshot().find == EditorFindRequest(query: "bookingId", caseSensitive: false, wholeWord: false, regex: false, serial: 1))
}

@Test func findWithNoTabOrABadRegexIsRefusedWhole() async throws {
    let f = try await editorFixture()
    await #expect(throws: (any Error).self) { try await f.dispatch("editor_find", ["query": .string("x")]) }
    await f.files.put("/p/api/a.go", "x")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    do {
        try await f.dispatch("editor_find", ["query": .string("book("), "regex": .bool(true)])
        Issue.record("expected the regex error")
    } catch { #expect(String(describing: error).contains("book(")) }
}

@Test func searchFillsThePaneAndFilesSearchDrawsNothing() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 2, 4, "  $bookingId = 1;"), ("/p/web", "r.ts", 1, 7, "const bookingId")])
    try await f.dispatch("editor_search", ["query": .string("bookingId")])
    let s = await f.snapshot().search
    #expect(s.query == "bookingId" && !s.inFlight && s.results.count == 2 && s.error == nil)
    let before = await f.snapshot()
    let reply = try await f.dispatch("files_search", ["query": .string("bookingId")])
    #expect(await f.snapshot() == before)
    guard case .object(let o) = reply, case .array(let m)? = o["matches"] else { Issue.record("no matches"); return }
    #expect(m.count == 2)
}

@Test func aSearchErrorIsShownWholeAndClearsTheResults() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    try await f.dispatch("editor_search", ["query": .string("x")])
    await f.files.setSearchError("error parsing regexp: missing closing ): `book(`")
    _ = try? await f.dispatch("editor_search", ["query": .string("book("), "regex": .bool(true)])
    let s = await f.snapshot().search
    #expect(s.error == "error parsing regexp: missing closing ): `book(`" && s.results.isEmpty && !s.inFlight)
}

// Review Focus 2.
@Test func aSupersededSearchNeverOverwritesTheNewerResults() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "old.php", 1, 1, "old")])
    await f.files.setSlowSearch(true)
    let first = Task { try await f.dispatch("editor_search", ["query": .string("old")]) }
    while await f.files.calls.filter({ $0.hasPrefix("files_search") }).isEmpty { await Task.yield() }
    await f.files.setSlowSearch(false)
    await f.files.setSearch([("/p/api", "new.php", 1, 1, "new")])
    try await f.dispatch("editor_search", ["query": .string("new")])
    await f.files.releaseSearch()
    _ = try? await first.value
    let s = await f.snapshot().search
    #expect(s.query == "new" && s.results.map(\.path) == ["new.php"] && !s.inFlight)
    #expect(await f.files.calls.contains("files_search cancelled"))   // the older tool call itself stopped
}

// Rule 4: Cancel stops the tool call, not only the pane's wait for it.
@Test func cancelStopsTheSearchInFlight() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    await f.files.setSlowSearch(true)
    let run = Task { try await f.dispatch("editor_search", ["query": .string("x")]) }
    while await f.files.calls.filter({ $0.hasPrefix("files_search") }).isEmpty { await Task.yield() }
    try await f.dispatch("editor_search", ["cancel": .bool(true)])
    await f.files.releaseSearch()
    _ = try? await run.value
    let s = await f.snapshot().search
    #expect(!s.inFlight && s.results.isEmpty)
    #expect(await f.files.calls.contains("files_search cancelled"))
}

@Test func aRefreshUnderARootWithResultsMarksThemChangedSince() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    try await f.dispatch("editor_search", ["query": .string("x")])
    try await f.dispatch("editor_refresh", ["root": .string("/p/web")])
    #expect(await f.snapshot().search.changedSince == false)
    try await f.dispatch("editor_refresh", ["root": .string("/p/api")])
    #expect(await f.snapshot().search.changedSince == true)
    try await f.dispatch("editor_search", ["query": .string("x")])
    #expect(await f.snapshot().search.changedSince == false)
}

// Controller ruling 1: a new find never reports the previous count against its query.
@Test func aNewFindClearsTheStaleFindReport() async throws {
    let f = try await editorFixture()
    await f.files.put("/p/api/a.go", "x y x")
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.go")])
    await f.panes.editorFindDidReport(paneId: f.pane, report: EditorFindReport(
        query: "x", caseSensitive: false, wholeWord: false, regex: false, count: 2, shown: true))
    try await f.dispatch("editor_find", ["query": .string("y")])
    #expect(await f.snapshot().findReport == nil)
}

// Controller ruling 3: files_search's files_truncated reaches the pane's Search view.
@Test func aSearchOverTheFileCapSaysSo() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    await f.files.setSearchFilesTruncated(true)
    try await f.dispatch("editor_search", ["query": .string("x")])
    #expect(await f.snapshot().search.filesTruncated == true)
    await f.files.setSearchFilesTruncated(false)
    try await f.dispatch("editor_search", ["query": .string("x")])
    #expect(await f.snapshot().search.filesTruncated == false)
}

// Fix round 1, I1: a cancel dispatched while the search has taken its serial but may not yet have
// started its tool call still stops it: no files_search runs to completion.
@Test func aCancelRightAfterASearchStartsStillStopsItsToolCall() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    await f.files.setSlowSearch(true)
    let run = Task { try await f.dispatch("editor_search", ["query": .string("x")]) }
    while await !f.snapshot().search.inFlight { await Task.yield() }
    try await f.dispatch("editor_search", ["cancel": .bool(true)])
    await f.files.releaseSearch()
    _ = try? await run.value
    #expect(await !f.files.calls.contains("files_search returned"))
    let s = await f.snapshot().search
    #expect(!s.inFlight && s.results.isEmpty)
}

// Fix round 1, I1: runs are ordered by serial, not by which call reaches the runs first.
@Test func anOlderSearchRegisteringLateNeverCancelsTheNewerOne() async throws {
    let runs = EditorSearchRuns<Int>()
    let newer = await runs.start("p", serial: 2) { try await Task.sleep(for: .milliseconds(50)); return 2 }
    let older = await runs.start("p", serial: 1) { 1 }
    #expect(try await newer.value == 2)
    await #expect(throws: CancellationError.self) { try await older.value }
}

@Test func aCancelRegisteredBeforeTheSearchStartsItCancelled() async throws {
    let runs = EditorSearchRuns<Int>()
    await runs.cancel("p", serial: 2)
    let ran = Flag()
    let late = await runs.start("p", serial: 1) { await ran.set(); return 1 }
    await #expect(throws: CancellationError.self) { try await late.value }
    #expect(await !ran.value)                     // the tool call was never made
    // An older cancel arriving after a newer search never cancels it.
    let newer = await runs.start("p", serial: 3) { try await Task.sleep(for: .milliseconds(20)); return 3 }
    await runs.cancel("p", serial: 2)
    #expect(try await newer.value == 3)
}

private actor Flag {
    var value = false
    func set() { value = true }
}

// Review minor 1: a search with no query and no cancel is refused, not run for "".
@Test func aSearchWithNoQueryIsRefused() async throws {
    let f = try await editorFixture()
    await #expect(throws: (any Error).self) { try await f.dispatch("editor_search") }
    #expect(await f.files.calls.isEmpty)
}

// Task 8 ruling 4: a switch flipped while the query is empty is kept, and the next search uses it.
@Test func aSwitchFlippedWithAnEmptyQueryIsKeptAndSearchesNothing() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    try await f.dispatch("editor_search", ["query": .string("x")])
    let calls = await f.files.calls.count
    try await f.dispatch("editor_search", ["query": .string(""), "case": .bool(true)])
    let s = await f.snapshot().search
    #expect(s.query == "" && s.caseSensitive && !s.inFlight && s.results.isEmpty && s.error == nil)
    #expect(await f.files.calls.count == calls)   // nothing was searched for ""
}

// Final review I4 (spec: a watcher event "on a path in the results"): a refresh that names the
// burst's paths marks the results changed since only when one is a result's file — or a folder
// holding one, FSEvents' "rescan this folder". A log under the same root changes nothing.
@Test func aRefreshNamingPathsMarksChangedSinceOnlyForAResultsFile() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x"), ("/p/api", "sub/b.php", 1, 1, "x")])
    try await f.dispatch("editor_search", ["query": .string("x")])
    try await f.dispatch("editor_refresh", ["root": .string("/p/api"),
                                            "paths": .array([.string("/p/api/storage/logs/l.log"), .string("/p/api/a.php.bak")])])
    #expect(await f.snapshot().search.changedSince == false, "a change beside the results")
    try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "paths": .array([.string("/p/api/sub/b.php")])])
    #expect(await f.snapshot().search.changedSince == true, "a result's own file")
    try await f.dispatch("editor_search", ["query": .string("x")])
    try await f.dispatch("editor_refresh", ["root": .string("/p/api"), "paths": .array([.string("/p/api/sub")])])
    #expect(await f.snapshot().search.changedSince == true, "a folder holding a result")
}

// 3b-ii walk: a cancelled search says so, and the next search clears it; a cancel with nothing in
// flight cancels nothing. read_pane carries it, as the column draws it.
@Test func aCancelledSearchSaysSoUntilTheNextOne() async throws {
    let f = try await editorFixture()
    await f.files.setSearch([("/p/api", "a.php", 1, 1, "x")])
    try await f.dispatch("editor_search", ["cancel": .bool(true)])
    #expect(await f.snapshot().search.cancelled == false)
    await f.files.setSlowSearch(true)
    let run = Task { try await f.dispatch("editor_search", ["query": .string("x")]) }
    while await !f.snapshot().search.inFlight { await Task.yield() }
    let reply = try await f.dispatch("editor_search", ["cancel": .bool(true)])
    await f.files.releaseSearch()
    _ = try? await run.value
    #expect(await f.snapshot().search.cancelled == true)
    guard case .object(let o) = reply, case .object(let search)? = o["search"] else { Issue.record("no search"); return }
    #expect(search["cancelled"] == .bool(true))
    await f.files.setSlowSearch(false)
    try await f.dispatch("editor_search", ["query": .string("x")])
    #expect(await f.snapshot().search.cancelled == false)
    try await f.dispatch("editor_search", ["query": .string("")])
    #expect(await f.snapshot().search.cancelled == false)
}
