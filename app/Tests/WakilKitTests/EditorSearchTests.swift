import Foundation
import Testing
@testable import WakilKit

private func m(_ root: String, _ path: String, _ line: Int) -> EditorSearchMatch {
    EditorSearchMatch(root: root, path: path, line: line, column: 1, preview: "x")
}

@Test func resultsGroupByRootThenFileInTheOrderTheyCame() {
    let g = editorSearchGroups([m("/p/api", "a.php", 1), m("/p/api", "a.php", 9), m("/p/api", "b.php", 2), m("/p/web", "r.ts", 1)])
    #expect(g.map(\.root) == ["/p/api", "/p/web"])
    #expect(g[0].files.map(\.path) == ["a.php", "b.php"])
    #expect(g[0].files[0].matches.map(\.line) == [1, 9])
}

@Test func findIsLiteralAndCaseInsensitiveByDefault() throws {
    let r = try editorFindMatches("Booking\nbooking(\nBOOKINGS", query: "booking(", caseSensitive: false, wholeWord: false, regex: false)
    #expect(r == [EditorRange(start: EditorPosition(line: 2, column: 1), end: EditorPosition(line: 2, column: 9))])
}

@Test func findSwitches() throws {
    let text = "bookingId bookingIdx BookingId"
    #expect(try editorFindMatches(text, query: "bookingId", caseSensitive: true, wholeWord: false, regex: false).count == 2)
    #expect(try editorFindMatches(text, query: "bookingId", caseSensitive: false, wholeWord: true, regex: false).count == 2)
    #expect(try editorFindMatches(text, query: "book\\w+x", caseSensitive: false, wholeWord: false, regex: true).count == 1)
}

@Test func anInvalidFindRegexThrowsItsMessageWhole() {
    #expect(throws: EditorFindError.self) {
        _ = try editorFindMatches("x", query: "book(", caseSensitive: false, wholeWord: false, regex: true)
    }
}

// Review Focus 3.
@Test func findColumnsAreUTF16() throws {
    let r = try editorFindMatches("حجز 😀 bookingId", query: "bookingId", caseSensitive: false, wholeWord: false, regex: false)
    #expect(r.first?.start.column == 8 && r.first?.end.column == 17)
}

@Test func anEmptyFindQueryMatchesNothing() throws {
    #expect(try editorFindMatches("abc", query: "", caseSensitive: false, wholeWord: false, regex: false).isEmpty)
}

@Test func theEmptySearchHasNoResultsAndNoTruncation() {
    #expect(EditorSearchState.empty.results.isEmpty)
    #expect(!EditorSearchState.empty.truncated && !EditorSearchState.empty.filesTruncated)
}

@MainActor @Test func theDebounceRunsOnlyTheLastScheduledBodyAfterThePause() async throws {
    let d = EditorDebounce(delay: .milliseconds(30))
    var ran: [Int] = []
    d.schedule { ran.append(1) }
    d.schedule { ran.append(2) }
    try await Task.sleep(for: .milliseconds(120))
    #expect(ran == [2])
    d.schedule { ran.append(3) }
    d.cancel()
    try await Task.sleep(for: .milliseconds(80))
    #expect(ran == [2])
}

// Task 8 review I4a: a result line marks its match — the find matcher run over the preview, UTF-16.
@Test func aResultPreviewMarksEveryMatchOfTheSearch() {
    var s = EditorSearchState.empty
    s.query = "booking"
    #expect(editorSearchMarks(preview: "  $Booking = booking;", search: s) == [3..<10, 13..<20])
    s.caseSensitive = true
    #expect(editorSearchMarks(preview: "  $Booking = booking;", search: s) == [13..<20])
    s.query = "b.+g"; s.caseSensitive = false; s.regex = true
    #expect(editorSearchMarks(preview: "é bing", search: s) == [2..<6])     // é is one UTF-16 unit
    s.query = "("                                                           // an invalid pattern marks nothing
    #expect(editorSearchMarks(preview: "(x)", search: s).isEmpty)
}

@Test func theSkippedLargeNoteNamesUpToThreeFiles() {
    #expect(editorSkippedLargeNote([]) == nil)
    #expect(editorSkippedLargeNote(["storage/logs/laravel.log"]) == "1 file over 2 MB not searched: storage/logs/laravel.log")
    #expect(editorSkippedLargeNote(["a", "b", "c"]) == "3 files over 2 MB not searched: a, b, c")
    #expect(editorSkippedLargeNote(["a", "b", "c", "d", "e"]) == "5 files over 2 MB not searched: a, b, c, …and 2 more")
}
