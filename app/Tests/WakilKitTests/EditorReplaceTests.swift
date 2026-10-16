import Foundation
import Testing
@testable import WakilKit

@Test func aReplaceChangeIsTheSmallestSpanThatDiffers() throws {
    let c = try #require(editorReplaceChange(old: "let foo = 1\nfoo()\n", new: "let bar = 1\nfoo()\n"))
    #expect(c.range == EditorRange(start: EditorPosition(line: 1, column: 5), end: EditorPosition(line: 1, column: 8)))
    #expect(c.text == "bar")
    #expect(editorReplaceChange(old: "same", new: "same") == nil)
    let two = try #require(editorReplaceChange(old: "foo\nx\nfoo", new: "bar\nx\nbar"))
    #expect(two.range == EditorRange(start: EditorPosition(line: 1, column: 1), end: EditorPosition(line: 3, column: 4)))
    #expect(two.text == "bar\nx\nbar")
}

@Test func aReplaceChangeNeverSplitsASurrogatePair() throws {
    // 😀 and 😃 share their lead surrogate: the span must start at the pair, not inside it.
    let c = try #require(editorReplaceChange(old: "a😀b", new: "a😃b"))
    #expect(c.range == EditorRange(start: EditorPosition(line: 1, column: 2), end: EditorPosition(line: 1, column: 4)))
    #expect(c.text == "😃")
}

@Test func previewSpansStrikeTheMatchAndInsertTheReplacement() {
    let spans = editorReplacePreviewSpans("let foo = foo", edits: [EditorReplaceEdit(start: 4, end: 7, text: "bar"),
                                                                    EditorReplaceEdit(start: 10, end: 13, text: "")])
    #expect(spans == [.kept("let "), .removed("foo"), .inserted("bar"), .kept(" = "), .removed("foo")])
    #expect(editorReplacePreviewSpans("abc", edits: [EditorReplaceEdit(start: 2, end: 9, text: "x")]) == [.kept("abc")])
}

@Test func previewTextsAreEachShownLineOnce() {
    let m = { (p: String, l: Int, line: String) in EditorSearchMatch(root: "/p/api", path: p, line: l, column: 1, preview: line) }
    #expect(editorReplacePreviewTexts([m("a.go", 1, "foo()"), m("a.go", 1, "foo()"), m("b.go", 3, "x foo")]) == ["foo()", "x foo"])
}

@Test func theResultLineSaysWhatHappened() {
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 37, files: 12)) == "Replaced 37 in 12 files")
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 1, files: 1)) == "Replaced 1 in 1 file")
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 3, files: 2, cancelled: true)) == "Replace cancelled · replaced 3 in 2 files")
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 3, files: 2, undone: true, restored: 1)) == "Undid the replace in 1 file")
    // Final review M6: the file cap, in the search's files-note wording.
    #expect(editorReplaceSummary(EditorReplaceResult(replaced: 3, files: 2, filesTruncated: true))
            == "Replaced 3 in 2 files · only the first 50,000 files were replaced")
}

@Test func replaceIsAvailableOnlyOverResultsWithNoErrorAndNoReplaceOrSearchInFlight() {
    var s = EditorSearchState.empty
    s.query = "foo"
    s.results = [EditorSearchMatch(root: "/p/api", path: "a.go", line: 1, column: 1, preview: "foo")]
    #expect(editorReplaceAvailable(s))
    var e = s; e.error = "error parsing regexp"; #expect(!editorReplaceAvailable(e))
    var f = s; f.replace.inFlight = true; #expect(!editorReplaceAvailable(f))
    var g = s; g.results = []; #expect(!editorReplaceAvailable(g))
    var h = s; h.query = ""; #expect(!editorReplaceAvailable(h))
    var i = s; i.inFlight = true; #expect(!editorReplaceAvailable(i))      // final review M3: a search running
}

@Test func anUndoableResultHasRecordsAndIsNotUndone() {
    let r = EditorReplaceUndoRecord(path: "/p/api/a.go", count: 1, original: "foo", mtime: 7)
    #expect(EditorReplaceResult(replaced: 1, files: 1, undo: [r]).undoable)
    #expect(!EditorReplaceResult(replaced: 1, files: 1, undo: [r], undone: true).undoable)
    #expect(!EditorReplaceResult(replaced: 1, files: 1).undoable)          // a buffer-only replace
}
