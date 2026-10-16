import Foundation
import Testing
@testable import WakilKit

/// b.go: base "a\nb\nc\nd\ne\n", text with line 2 changed and line 4 deleted: two hunks.
private func peekFixture() async throws -> EditorFixture {
    let f = try await changesFixture()
    await f.files.put("/p/api/b.go", "a\nB\nc\ne\n")
    await f.git.set(show: "/p/api|b.go|index", "a\nb\nc\nd\ne\n")
    try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
    return f
}

@Suite struct EditorPeekTests {
    @Test func aMarksLineOpensThePeekOnItsHunkAndMovesTheCursorThere() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(3)])     // the deletion's triangle, under line 3
        let t = await f.snapshot().tabs[0]
        #expect(t.peek == 1 && t.cursor.line == 3)
        let v = try #require(editorPeekView(t))
        #expect(v.title == "2 of 2 changes" && v.old == ["d"] && v.new.isEmpty && v.afterLine == 3)
    }

    @Test func stepClampsAtEitherEnd() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        try await f.dispatch("editor_peek_step", ["delta": .integer(5)])
        #expect(await f.snapshot().tabs[0].peek == 1)
        try await f.dispatch("editor_peek_step", ["delta": .integer(-5)])
        #expect(await f.snapshot().tabs[0].peek == 0)
    }

    @Test func closeLeavesTheCursorWhereItWas() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        let cursor = await f.snapshot().tabs[0].cursor
        try await f.dispatch("editor_peek_close")
        let t = await f.snapshot().tabs[0]
        #expect(t.peek == nil && t.cursor == cursor)
    }

    @Test func typingClosesThePeekAndKeepsTheMarks() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        let subject = await f.snapshot().tabs[0].subject
        await f.panes.editorBufferDidChange(paneId: f.pane, subject: subject, text: "a\nB\nc\ne\nf\n", basis: 0)
        let t = await f.snapshot().tabs[0]
        #expect(t.peek == nil && t.baseline != nil)
    }

    // Rule 1: Revert is a buffer edit — dirty, unsaved, undoable — and asks nothing. R12: the peek moves on.
    @Test func revertDispatchesTheHunksOldLinesAndThePeekMovesToTheNextHunk() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        let r = try #require(editorPeekRevert(await f.snapshot()))
        #expect(r.path == "/p/api/b.go" && r.text == "b")
        try await f.dispatch("editor_replace_range", ["path": .string(r.path), "range": editorRangeParam(r.range),
                                                      "text": .string(r.text)])
        let t = await f.snapshot().tabs[0]
        #expect(t.text == "a\nb\nc\ne\n" && t.dirty)
        #expect(await f.files.text(of: "/p/api/b.go") == "a\nB\nc\ne\n", "nothing is saved until ⌘S")
        #expect(t.peek == 0, "the deletion, the next hunk, now holds index 0")
        #expect(editorPeekView(t)?.old == ["d"])
    }

    @Test func revertingTheLastHunkClosesThePeek() async throws {
        let f = try await changesFixture()
        await f.files.put("/p/api/b.go", "X\n")
        await f.git.set(show: "/p/api|b.go|index", "x\n")
        try await f.dispatch("editor_open", ["path": .string("/p/api/b.go")])
        try await f.dispatch("editor_peek", ["line": .integer(1)])
        let r = try #require(editorPeekRevert(await f.snapshot()))
        try await f.dispatch("editor_replace_range", ["path": .string(r.path), "range": editorRangeParam(r.range),
                                                      "text": .string(r.text)])
        #expect(await f.snapshot().tabs[0].peek == nil)
    }

    @Test func aLineWithNoMarkIsRefusedNamingIt() async throws {
        let f = try await peekFixture()
        await #expect(throws: EditorActionError.noChange(line: 1)) { try await f.dispatch("editor_peek", ["line": .integer(1)]) }
    }

    @Test func aTabWithNoMarksIsRefused() async throws {
        let f = try await changesFixture()
        try await f.dispatch("editor_new_scratch")
        await #expect(throws: EditorActionError.noMarks(action: "editor_peek")) {
            try await f.dispatch("editor_peek", ["line": .integer(1)])
        }
    }

    @Test func stepWithNoPeekOpenIsRefused() async throws {
        let f = try await peekFixture()
        await #expect(throws: EditorActionError.noPeek(action: "editor_peek_step")) {
            try await f.dispatch("editor_peek_step", ["delta": .integer(1)])
        }
    }

    @Test func readPaneSaysWhichChangeThePeekShows() async throws {
        let f = try await peekFixture()
        try await f.dispatch("editor_peek", ["line": .integer(2)])
        guard case .object(let o) = await f.panes.readPane(paneId: f.pane, kind: "editor") else { return }
        #expect(o["peek"] == .object(["index": .number(0), "count": .number(2), "line": .number(2)]))
    }

    // The gutter strip posts a click even where there is no mark; the view asks first.
    @Test func theViewAsksWhetherALineHasAMarkBeforeDispatching() async throws {
        let f = try await peekFixture()
        let t = await f.snapshot().tabs[0]
        #expect(editorPeekLineHasMark(t, line: 2) && editorPeekLineHasMark(t, line: 3))
        #expect(!editorPeekLineHasMark(t, line: 1) && !editorPeekLineHasMark(t, line: 4))
        var bare = t; bare.baseline = nil
        #expect(!editorPeekLineHasMark(bare, line: 2))
        var ro = t; ro.readOnly = true
        #expect(!editorPeekLineHasMark(ro, line: 2))
    }

    @Test func aPeekIsClampedWhenTheTextChangesUnderIt() {
        #expect(editorPeekClamped(1, baseline: "a\nb\n", text: "a\nB\n") == 0)
        #expect(editorPeekClamped(0, baseline: "a\nb\n", text: "a\nb\n") == nil)
        #expect(editorPeekClamped(nil, baseline: "a\n", text: "b\n") == nil)
    }
}
