import Foundation
import Testing
@testable import WakilKit

private let twoBlocks = """
top
<<<<<<< HEAD
ours one
=======
theirs one
>>>>>>> feature/search
middle
<<<<<<< HEAD
ours two
=======
theirs two
>>>>>>> feature/search
end

"""

/// The tab's text after `take` on `b`, as the replace path writes it.
private func accepted(_ text: String, _ b: EditorConflictBlock, _ take: EditorConflictTake) -> String {
    let (r, t) = editorConflictAccept(text, b, take: take)
    return editorReplacing(text, r, with: t)
}

/// A fixture with `/p/api/a.txt` open holding `text`, listed in its root's conflicts group.
private func conflictFixture(_ text: String, conflicted: Bool = true) async throws -> EditorFixture {
    let f = try await editorFixture()
    await f.git.set(status: "/p/api", files: [("a.txt", conflicted ? "conflicts" : "changed", conflicted ? "U" : "M")])
    await f.status.refresh()
    await f.files.put("/p/api/a.txt", text)
    try await f.dispatch("editor_open", ["path": .string("/p/api/a.txt")])
    return f
}

@Suite struct EditorConflictsTests {
    @Test func blocksParseWithTheirLabels() {
        #expect(editorConflictBlocks(twoBlocks) == [
            EditorConflictBlock(start: 2, separator: 4, end: 6, currentLabel: "HEAD", incomingLabel: "feature/search"),
            EditorConflictBlock(start: 8, separator: 10, end: 12, currentLabel: "HEAD", incomingLabel: "feature/search"),
        ])
        // A marker with nothing after it has an empty label; eight angle brackets are no marker.
        #expect(editorConflictBlocks("<<<<<<<\na\n=======\nb\n>>>>>>>\n")
            == [EditorConflictBlock(start: 1, separator: 3, end: 5, currentLabel: "", incomingLabel: "")])
        #expect(editorConflictBlocks("<<<<<<<< x\na\n=======\nb\n>>>>>>> y\n") == [])
    }

    // Review Focus 2.
    @Test func aBlockAtTheFirstAndLastLine() {
        let text = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature/search"
        let b = try! #require(editorConflictBlocks(text).first)
        #expect(b == EditorConflictBlock(start: 1, separator: 3, end: 5, currentLabel: "HEAD", incomingLabel: "feature/search"))
        // No line ending is invented after the last line.
        #expect(accepted(text, b, .current) == "ours")
        #expect(accepted(text, b, .incoming) == "theirs")
        #expect(accepted(text, b, .both) == "ours\ntheirs")
        #expect(accepted(text + "\n", b, .current) == "ours\n")
    }

    // Review Focus 2.
    @Test func crlfIsKept() {
        let text = "top\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature/search\r\nend\r\n"
        let b = try! #require(editorConflictBlocks(text).first)
        #expect(b == EditorConflictBlock(start: 2, separator: 4, end: 6, currentLabel: "HEAD", incomingLabel: "feature/search"))
        #expect(accepted(text, b, .current) == "top\r\nours\r\nend\r\n")
        #expect(accepted(text, b, .incoming) == "top\r\ntheirs\r\nend\r\n")
        #expect(accepted(text, b, .both) == "top\r\nours\r\ntheirs\r\nend\r\n")
        let last = "<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature/search"
        let lb = try! #require(editorConflictBlocks(last).first)
        #expect(accepted(last, lb, .both) == "ours\r\ntheirs")
    }

    // Review Focus 2: `=======` outside a block, and a block never closed, are text.
    @Test func aLoneSeparatorIsNotABlock() {
        #expect(editorConflictBlocks("a\n=======\nb\n") == [])
        #expect(editorConflictBlocks("a\n>>>>>>> x\n=======\n") == [])
        #expect(editorConflictBlocks("<<<<<<< HEAD\nours\n=======\ntheirs\n") == [])
        let text = "=======\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\n=======\n"
        #expect(editorConflictBlocks(text)
            == [EditorConflictBlock(start: 2, separator: 4, end: 6, currentLabel: "HEAD", incomingLabel: "b")])
    }

    @Test func diff3BaseIsDropped() {
        let text = "<<<<<<< HEAD\nours\n||||||| base\nold\n=======\ntheirs\n>>>>>>> feature/search\n"
        let b = try! #require(editorConflictBlocks(text).first)
        #expect(b == EditorConflictBlock(start: 1, separator: 5, end: 7, currentLabel: "HEAD", incomingLabel: "feature/search"))
        #expect(accepted(text, b, .current) == "ours\n")
        #expect(accepted(text, b, .incoming) == "theirs\n")
        #expect(accepted(text, b, .both) == "ours\ntheirs\n")
    }

    @Test func eachTakeReplacesOnlyItsBlock() {
        let blocks = editorConflictBlocks(twoBlocks)
        #expect(accepted(twoBlocks, blocks[1], .current)
            == "top\n<<<<<<< HEAD\nours one\n=======\ntheirs one\n>>>>>>> feature/search\nmiddle\nours two\nend\n")
        #expect(accepted(twoBlocks, blocks[0], .incoming)
            == "top\ntheirs one\nmiddle\n<<<<<<< HEAD\nours two\n=======\ntheirs two\n>>>>>>> feature/search\nend\n")
        #expect(accepted(twoBlocks, blocks[0], .both).hasPrefix("top\nours one\ntheirs one\nmiddle\n<<<<<<< HEAD\n"))
    }

    @Test func acceptAppliesThroughTheReplacePath() async throws {
        let f = try await conflictFixture(twoBlocks)
        try await f.dispatch("editor_conflict_accept", ["block": .integer(8), "take": .string("incoming")])
        let t = await f.snapshot().tabs[0]
        #expect(t.text == "top\n<<<<<<< HEAD\nours one\n=======\ntheirs one\n>>>>>>> feature/search\nmiddle\ntheirs two\nend\n")
        // The page applies the store's edit as one undo step (R2), as it does editor_replace_range's.
        #expect(t.lastAgentEdit?.serial == 1 && t.lastAgentEdit?.text == "theirs two\n" && t.dirty)
        // The block is gone: pressing it again is refused, nothing replaced.
        await #expect(throws: EditorActionError.noConflict(action: "editor_conflict_accept", path: "/p/api/a.txt", line: 8)) {
            try await f.dispatch("editor_conflict_accept", ["block": .integer(8), "take": .string("current")])
        }
        #expect(await f.snapshot().tabs[0].text == t.text)
    }

    @Test func acceptIsRefusedOffAConflictedFile() async throws {
        let f = try await conflictFixture(twoBlocks, conflicted: false)
        for (name, params) in [("editor_conflict_accept", ["block": JSONValue.integer(2), "take": .string("current")]),
                               ("editor_conflict_next", [:]), ("editor_conflict_previous", [:]),
                               ("editor_conflict_compare", [:])] as [(String, [String: JSONValue])] {
            await #expect(throws: EditorActionError.noConflict(action: name, path: "/p/api/a.txt")) {
                try await f.dispatch(name, params)
            }
        }
        #expect(await f.snapshot().tabs[0].text == twoBlocks)
        // Conflicted but with every block accepted: Next and Previous say the same.
        let g = try await conflictFixture("resolved\n")
        await #expect(throws: EditorActionError.noConflict(action: "editor_conflict_next", path: "/p/api/a.txt")) {
            try await g.dispatch("editor_conflict_next")
        }
    }

    @Test func nextAndPreviousWrap() async throws {
        let f = try await conflictFixture(twoBlocks)
        func cursor() async -> Int { await f.snapshot().tabs[0].cursor.line }
        try await f.dispatch("editor_conflict_next")
        #expect(await cursor() == 2)
        try await f.dispatch("editor_conflict_next")
        #expect(await cursor() == 8)
        try await f.dispatch("editor_conflict_next")
        #expect(await cursor() == 2)
        try await f.dispatch("editor_conflict_previous")
        #expect(await cursor() == 8)
        try await f.dispatch("editor_conflict_previous")
        #expect(await cursor() == 2)
        try await f.dispatch("editor_goto", ["line": .integer(5)])
        try await f.dispatch("editor_conflict_previous")
        #expect(await cursor() == 2)
    }

    // Review Focus 3: a delete/modify conflict's absent side reads empty, not an error.
    @Test func compareOpensTheCurrentAndIncomingSides() async throws {
        let f = try await conflictFixture(twoBlocks)
        await f.git.set(show: "/p/api|a.txt|ours", "ours\n")
        await f.git.set(showAbsent: "/p/api|a.txt|theirs")
        try await f.dispatch("editor_conflict_compare")
        try await f.dispatch("editor_focus_tab", ["index": .integer(0)])
        try await f.dispatch("editor_conflict_compare")
        let s = await f.snapshot()
        #expect(s.tabs.count == 2 && s.active == 1)
        let t = s.tabs[1]
        #expect(t.subject == .diff(root: "/p/api", path: "a.txt", group: .conflicts, source: .conflict))
        #expect(editorTabTitles(s.tabs) == ["a.txt", "a.txt (Current ↔ Incoming)"])
        #expect(t.readOnly && t.diffState?.error == nil)
        #expect(t.diffState?.original == "ours\n" && t.diffState?.modified == "")
        // The tab's params name it back, and its key is its own.
        let params = editorTabParams(t.subject)
        if case .object(let d)? = params["diff"] { #expect(editorDiffSource(d) == .conflict) } else { Issue.record("no diff params") }
        #expect(editorTabKey(t) != editorTabKey(EditorTab.diff(root: "/p/api", path: "a.txt", group: .conflicts)))
    }

    @Test func theRefusalNamesTheFile() {
        #expect(EditorActionError.noConflict(action: "editor_conflict_next", path: "/p/api/a.txt").description
            == "editor_conflict_next: a.txt has no conflict")
        #expect(EditorActionError.noConflict(action: "editor_conflict_accept", path: "/p/api/a.txt", line: 8).description
            == "editor_conflict_accept: a.txt has no conflict at line 8")
    }

    @Test func aTabIsConflictedOnlyWhenItsRootListsIt() async throws {
        let f = try await conflictFixture(twoBlocks)
        let roots = await f.status.roots
        #expect(editorConflicted(await f.snapshot().tabs[0], roots: roots))
        #expect(!editorConflicted(EditorTab.file(path: "/p/api/b.txt", root: "/p/api", text: "", mtime: 0, language: "plaintext"),
                                  roots: roots))
        #expect(!editorConflicted(nil, roots: roots))
    }
}
