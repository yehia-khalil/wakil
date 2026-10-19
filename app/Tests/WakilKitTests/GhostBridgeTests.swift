import Testing
@testable import WakilKit

/// 3b-viii: the page's ghost request reaches Swift as a UTF-16 offset into the model's text.
@Suite struct GhostBridgeTests {
    private let text = "a = \"🙂\"\nb."

    @Test func theEndOfTheTextIsItsEndIndex() {
        // a, space, =, space, quote, the emoji's two units, quote, newline, b, dot: 11 units.
        #expect(ghostCaret(text: text, utf16Offset: 11) == text.endIndex)
    }

    @Test func anOffsetInsideASurrogatePairIsNoCaret() {
        #expect(ghostCaret(text: text, utf16Offset: 6) == nil)
    }

    @Test func anOffsetPastTheEndIsNoCaret() {
        #expect(ghostCaret(text: text, utf16Offset: 12) == nil)
        #expect(ghostCaret(text: text, utf16Offset: -1) == nil)
    }

    @Test func theStartOfAnEmptyTextIsItsStartIndex() {
        #expect(ghostCaret(text: "", utf16Offset: 0) == "".startIndex)
    }

    @Test func anOffsetAfterTheEmojiLandsOnItsClosingQuote() throws {
        let caret = try #require(ghostCaret(text: text, utf16Offset: 7))
        #expect(text[caret...] == "\"\nb.")
    }

    @Test func aFileTabAsksWithItsPathAndLanguage() {
        let tab = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "", mtime: 0, language: "go")
        #expect(ghostTabContext(tab).map { [$0.path, $0.language] } == ["/p/api/a.go", "go"])
    }

    @Test func aScratchTabAsksWithNoPath() {
        let tab = EditorTab.scratch(number: 1, language: "sql")
        #expect(ghostTabContext(tab).map { [$0.path, $0.language] } == ["", "sql"])
    }

    @Test func aReadOnlyTabNeverAsks() {
        var tail = EditorTab.file(path: "/p/api/big.log", root: "/p/api", text: "", mtime: 0, language: "log")
        tail.readOnly = true
        tail.tailStart = 10
        #expect(ghostTabContext(tail) == nil)
        #expect(ghostTabContext(EditorTab.diff(root: "/p/api", path: "a.go", group: .changed)) == nil)
    }

    /// A request the page cancelled while Swift was still building it never reaches the model.
    @Test func aRequestCancelledBeforeItIsAskedIsNeverAsked() {
        var order = GhostRequestOrder()
        let steps = [order.cancel(4), order.admit(4), order.admit(5)]
        #expect(steps == [true, false, true])
    }

    /// An older request that finishes building after a newer one was asked never supersedes it.
    @Test func anOlderRequestNeverOvertakesANewerOne() {
        var order = GhostRequestOrder()
        let steps = [order.admit(6), order.admit(5)]
        #expect(steps == [true, false])
    }

    /// Cancelling the request now asked releases the pane's session; a late cancel of an older
    /// one does not, or it would drop the newer request.
    @Test func onlyACancelOfTheLiveRequestReleasesTheSession() {
        var order = GhostRequestOrder()
        let steps = [order.admit(7), order.cancel(6), order.cancel(7), order.admit(7)]
        #expect(steps == [true, false, true, false])
    }
}
