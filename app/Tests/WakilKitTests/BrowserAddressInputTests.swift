import Foundation
import Testing
@testable import WakilKit

/// **The address field's keys, rows and inline completion** (3c-iii, rulings 8, 9 and 12). Pure.
@Suite struct BrowserAddressInputTests {
    private func row(_ kind: BrowserSuggestion.Kind, _ url: String, tab: String? = nil) -> BrowserSuggestion {
        BrowserSuggestion(kind: kind, title: "", url: url, tab: tab)
    }

    private let rows = [
        BrowserSuggestion(kind: .tab, title: "GitHub", url: "https://github.com/", tab: "t2"),
        BrowserSuggestion(kind: .history, title: "", url: "https://gitlab.com/x", tab: nil),
        BrowserSuggestion(kind: .search, title: "git rebase", url: "git rebase", tab: nil),
    ]

    /// A field that opened on `opened` and had `typed` typed at its end, with `rows` answered.
    private func typing(_ typed: String, opened: String = "") -> BrowserAddressInput {
        var input = BrowserAddressInput(opened)
        input.fieldChanged(to: typed, caretAtEnd: true)
        input.rowsArrived(rows, for: typed)
        return input
    }

    @Test func theFieldOpeningAsksForNothing() {
        let input = BrowserAddressInput("https://example.com/")
        #expect(input.query == nil && input.shown == "https://example.com/")
    }

    @Test func anInsertionAtTheEndCompletesToTheEndOfTheHostSelected() {
        let input = typing("git")
        #expect(input.completion == "hub.com")
        #expect(input.shown == "github.com")
        #expect(input.completionRange == NSRange(location: 3, length: 7))
    }

    @Test func theFirstKeystrokeOverTheSelectedURLCompletes() {
        let input = typing("g", opened: "https://example.com/")
        #expect(input.completion == "ithub.com" && input.query == "g")
    }

    @Test func backspaceAtTheEndOffersNoCompletion() {
        var input = typing("gith")
        input.fieldChanged(to: "git", caretAtEnd: true)
        input.rowsArrived(rows, for: "git")
        #expect(input.completion == nil && input.shown == "git")
    }

    @Test func theCompletionsOwnTextComingBackIsNotAnEdit() {
        var input = typing("git")
        input.fieldChanged(to: "github.com", caretAtEnd: true)
        #expect(input.typed == "git" && input.completion == "hub.com")
    }

    @Test func typingOverTheCompletionCompletesAgainFromTheRowsShown() {
        var input = typing("git")
        input.fieldChanged(to: "gith", caretAtEnd: true)
        #expect(input.typed == "gith" && input.completion == "ub.com")
        #expect(input.query == "gith")
    }

    @Test func aDeletionDropsTheCompletion() {
        var input = typing("git")
        input.fieldChanged(to: "git", caretAtEnd: true)   // Backspace took the selected part
        #expect(input.completion == nil && input.shown == "git")
        input.rowsArrived(rows, for: "git")
        #expect(input.completion == nil, "rows for a deletion offer none")
    }

    @Test func anEditAwayFromTheEndOffersNoCompletion() {
        var input = typing("gt")
        input.fieldChanged(to: "git", caretAtEnd: false)
        input.rowsArrived(rows, for: "git")
        #expect(input.completion == nil)
    }

    @Test func theCaretLeavingTheEndKeepsWhatShowsAsTyped() {
        var input = typing("git")
        input.caretLeftEnd()
        #expect(input.typed == "github.com" && input.completion == nil && input.shown == "github.com")
    }

    @Test func backspaceAfterTheCompletionIsAcceptedDeletesOneCharacterAndOffersNoCompletion() {
        var input = typing("git")
        #expect(input.completion == "hub.com" && input.shown == "github.com")
        // → (or a click at the end): the caret collapses at the end of what shows.
        input.selectionChanged(NSRange(location: 10, length: 0), in: "github.com")
        #expect(input.completion == nil && input.typed == "github.com")
        // ⌫ deletes the last character of the accepted text.
        input.fieldChanged(to: "github.co", caretAtEnd: true)
        #expect(input.completion == nil && input.shown == "github.co")
        input.rowsArrived(rows, for: "github.co")
        #expect(input.completion == nil && input.shown == "github.co", "a deletion is offered no completion")
    }

    @Test func theCompletionsOwnSelectionAndTextNotYetPlacedKeepIt() {
        var input = typing("git")
        input.selectionChanged(NSRange(location: 3, length: 7), in: "github.com")
        input.selectionChanged(NSRange(location: 3, length: 0), in: "git")
        #expect(input.completion == "hub.com" && input.typed == "git")
        input.selectionChanged(NSRange(location: 2, length: 0), in: "github.com")
        #expect(input.completion == nil && input.typed == "github.com", "a caret moved left ends it too")
    }

    @Test func noCompletionWithWhitespace() {
        let input = typing("git re")
        #expect(input.completion == nil)
    }

    @Test func downAndUpMoveTheHighlightAndTheFieldShowsTheRow() {
        var input = typing("git")
        let moved = input.move(down: true)
        #expect(moved && input.highlight == 0 && input.shown == "https://github.com/")
        #expect(input.completion == nil)
        _ = input.move(down: true)
        _ = input.move(down: true)
        #expect(input.shown == "git rebase", "a search row shows its words")
        _ = input.move(down: true)
        #expect(input.highlight == 2, "stays on the last row")
        _ = input.move(down: false)
        _ = input.move(down: false)
        _ = input.move(down: false)
        #expect(input.highlight == nil && input.shown == "git", "↑ above the first row brings back what was typed")
    }

    @Test func keysWithNoRowsKeepTheirMeaning() {
        var input = BrowserAddressInput("https://example.com/")
        let moved = input.move(down: true), escaped = input.escape()
        #expect(!moved && !escaped)
    }

    @Test func escHidesTheRowsAndRestoresWhatWasTypedUntilTheNextEdit() {
        var input = typing("git")
        _ = input.move(down: true)
        let escaped = input.escape()
        #expect(escaped)
        #expect(input.rows.isEmpty && input.shown == "git" && input.query == nil)
        input.rowsArrived(rows, for: "git")
        #expect(input.rows.isEmpty, "a late answer does not bring them back")
        input.fieldChanged(to: "gi", caretAtEnd: true)
        #expect(input.query == "gi")
    }

    @Test func rowsForAnOlderTextAreDropped() {
        var input = typing("git")
        input.fieldChanged(to: "gitx", caretAtEnd: true)
        input.rowsArrived([row(.history, "https://other.test/")], for: "git")
        #expect(input.rows == rows)
    }

    @Test func theHighlightFollowsItsRowWhenTheEnginesRowsArrive() {
        var input = typing("git")
        _ = input.move(down: true)
        _ = input.move(down: true)
        input.rowsArrived(rows + [row(.search, "git log")], for: "git")
        #expect(input.highlight == 1 && input.shown == "https://gitlab.com/x")
    }

    @Test func typingOnAHighlightedRowEditsItsText() {
        var input = typing("git")
        _ = input.move(down: true)
        input.fieldChanged(to: "https://github.com/a", caretAtEnd: true)
        #expect(input.highlight == nil && input.typed == "https://github.com/a")
    }

    @Test func returnOpensTheHighlightedRowElseWhatShows() {
        var input = typing("git")
        #expect(input.choice == .navigate("github.com"))
        _ = input.move(down: true)
        #expect(input.choice == .tab(id: "t2", url: "https://github.com/"))
        _ = input.move(down: true)
        #expect(input.choice == .navigate("https://gitlab.com/x"))
        _ = input.move(down: true)
        #expect(input.choice == .navigate("git rebase"))
    }

    // MARK: The ★ menu

    private func mark(_ url: String, _ age: TimeInterval) -> BrowserBookmark {
        BrowserBookmark(url: url, title: "", added: Date(timeIntervalSince1970: 1_000_000 + age))
    }

    @Test func theStarReadsTheActiveTabsBookmarkAndListsNewestFirst() {
        let marks = [mark("https://a.test/", 0), mark("https://b.test/", 10)]
        let on = BrowserBookmarkChoices(url: "https://a.test/", bookmarks: marks)
        #expect(on.bookmarked && on.canToggle && on.toggleTitle == "Remove Bookmark")
        #expect(on.entries.map(\.url) == ["https://b.test/", "https://a.test/"])
        let off = BrowserBookmarkChoices(url: "https://a.test", bookmarks: marks)
        #expect(!off.bookmarked && off.toggleTitle == "Bookmark This Page", "matched by exact URL")
    }

    @Test func onlyAWebPageCanBeBookmarked() {
        #expect(!BrowserBookmarkChoices(url: "", bookmarks: []).canToggle)
        #expect(!BrowserBookmarkChoices(url: "about:blank", bookmarks: []).canToggle)
        #expect(!BrowserBookmarkChoices(url: nil, bookmarks: []).canToggle)
        #expect(BrowserBookmarkChoices(url: "file:///tmp/a.html", bookmarks: []).canToggle)
        #expect(BrowserBookmarkChoices(url: "http://example.com/", bookmarks: []).canToggle)
    }
}
