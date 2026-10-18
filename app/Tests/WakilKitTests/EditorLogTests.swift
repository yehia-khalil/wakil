import Foundation
import Testing
@testable import WakilKit

private let log = "/p/api/storage/logs/laravel.log"

@Test func aLogMapsToTheLogLanguage() {
    #expect(editorLanguage(forPath: log) == "log")
    #expect(editorFileGlyph(forPath: log) == "\u{E023}")
}

@Test func aLargeFileOpensAsItsTailReadOnlyWithTheNotice() async throws {
    let f = try await editorFixture()
    await f.files.putTail(log, text: "b\nc\n", start: 299_999_996, size: 300_000_000)
    try await f.dispatch("editor_open", ["path": .string(log)])
    let t = await f.snapshot().tabs[0]
    #expect(t.readOnly && t.text == "b\nc\n" && t.tailStart == 299_999_996 && t.readTo == 300_000_000)
    #expect(t.notice == "Showing the last 2 MB of 300 MB")
    #expect(t.cursor.line == 3, "a log opens at its bottom")
}

@Test func aGrowingLogIsAppendedNotReloaded() async throws {
    let f = try await editorFixture()
    await f.files.put(log, "one\n")
    try await f.dispatch("editor_open", ["path": .string(log)])
    await f.files.put(log, "one\ntwo\nthr")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "one\ntwo\n" && t.readTo == 8 && !t.dirty)
    #expect(await f.files.calls.contains("files_read \(log) from 4"))
    await f.files.put(log, "one\ntwo\nthree\n")
    try await f.dispatch("editor_refresh", origin: .ui)
    #expect(await f.snapshot().tabs[0].text == "one\ntwo\nthree\n", "the partial line arrives once, whole")
}

@Test func aShrunkLogIsReadAfresh() async throws {
    let f = try await editorFixture()
    await f.files.put(log, "one\ntwo\n")
    try await f.dispatch("editor_open", ["path": .string(log)])
    await f.files.put(log, "new\n")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "new\n" && t.readTo == 4)
}

@Test func aDirtyLogIsNeverAppended() async throws {
    let f = try await editorFixture()
    await f.files.put(log, "one\n")
    try await f.dispatch("editor_open", ["path": .string(log)])
    await f.panes.editorBufferDidChange(paneId: f.pane, tab: 0, text: "mine\n", basis: 0)
    await f.files.put(log, "one\ntwo\n")
    try await f.dispatch("editor_refresh", origin: .ui)
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "mine\n" && t.diskState == .changedOnDisk)
}

@Test func aTailTabGrowsAndItsNoticeFollowsTheSize() {
    var tab = EditorTab.file(path: log, root: "/p/api", text: "a\n", mtime: 1, language: "log")
    tab.readOnly = true; tab.tailStart = 2_999_998; tab.readTo = 3_000_000
    let reply: [String: JSONValue] = ["exists": .bool(true), "text": .string("b\n"), "utf8": .bool(true),
                                      "end": .integer(3_000_002), "size": .integer(3_000_002), "mtime": .integer(2)]
    guard case .appended(let t) = editorAfterAppendRead(tab, reply: reply) else { Issue.record("not appended"); return }
    #expect(t.text == "a\nb\n" && t.readTo == 3_000_002 && t.notice == "Showing the last 2 MB of 3 MB")
}

@Test func aTailPastTwiceTheCapIsReadAfresh() {
    var tab = EditorTab.file(path: log, root: "/p/api", text: String(repeating: "x", count: 2 * (2 << 20) - 1),
                             mtime: 1, language: "log")
    tab.tailStart = 0; tab.readTo = 10
    let reply: [String: JSONValue] = ["exists": .bool(true), "text": .string("yy\n"), "utf8": .bool(true),
                                      "end": .integer(13), "size": .integer(13), "mtime": .integer(2)]
    #expect(editorAfterAppendRead(tab, reply: reply) == .reread)
}

@Test func aSmallLogPassingTheCapIsReadAfresh() {
    let tab = EditorTab.file(path: log, root: "/p/api", text: "a\n", mtime: 1, language: "log")
    let reply: [String: JSONValue] = ["exists": .bool(true), "text": .string("b\n"), "utf8": .bool(true),
                                      "end": .integer(4), "size": .integer(3_000_000), "mtime": .integer(2)]
    #expect(editorAfterAppendRead(tab, reply: reply) == .reread)
}

@Test func aBinaryChunkStopsFollowingAndSaysSo() {
    var tab = EditorTab.file(path: log, root: "/p/api", text: "a\n", mtime: 1, language: "log")
    tab.readTo = 2
    let reply: [String: JSONValue] = ["exists": .bool(true), "text": .string(""), "binary": .bool(true), "utf8": .bool(true),
                                      "end": .integer(2), "size": .integer(9), "mtime": .integer(2)]
    guard case .stopped(let t) = editorAfterAppendRead(tab, reply: reply) else { Issue.record("not stopped"); return }
    #expect(t.notice == "laravel.log now holds binary data; it stopped following" && t.readOnly)
    #expect(!editorAppends(t))
}

@Test func otherFilesNeverAppend() {
    #expect(!editorAppends(EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "", mtime: 1, language: "go")))
}

// Final review I2: an append lands on the tab as it is when the read returns, so a cursor the
// operator moved meanwhile stays where they put it (Rule 6).
@Test func anAppendKeepsACursorMovedWhileItsReadWasInFlight() async throws {
    let f = try await editorFixture()
    await f.files.put(log, "one\ntwo\n")
    try await f.dispatch("editor_open", ["path": .string(log)])
    await f.files.put(log, "one\ntwo\nthree\n")
    await f.files.setSlowRead(true)
    let refresh = Task { try await f.dispatch("editor_refresh", origin: .ui) }
    while await !f.files.calls.contains("files_read \(log) from 8") { await Task.yield() }
    await f.panes.editorViewDidReport(paneId: f.pane, tab: 0, cursor: EditorPosition(line: 1, column: 2),
                                      selection: nil, visibleRange: 1...3, scrollTop: 0)
    await f.files.releaseRead()
    _ = try await refresh.value
    let t = await f.snapshot().tabs[0]
    #expect(t.text == "one\ntwo\nthree\n")
    #expect(t.cursor == EditorPosition(line: 1, column: 2) && t.scrollTop == 0)
}
