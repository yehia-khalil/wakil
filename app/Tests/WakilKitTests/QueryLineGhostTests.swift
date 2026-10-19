import Testing
@testable import WakilKit

// 3b-viii ghost-text in the DB pane's query line: what Tab, Esc and Return do while a ghost shows,
// and where the line asks for one (Ruling R2: only at the end of a line).

@Suite struct QueryLineGhostTests {
    @Test func tabAcceptsOnlyWhileAGhostShows() {
        #expect(queryLineGhostKey(.tab, ghostShowing: true, readRunning: false) == .accept)
        #expect(queryLineGhostKey(.tab, ghostShowing: true, readRunning: true) == .accept)
    }

    @Test func tabWithoutSuggestionLeavesLine() {
        #expect(queryLineGhostKey(.tab, ghostShowing: false, readRunning: false) == .leaveLine)
        #expect(queryLineGhostKey(.tab, ghostShowing: false, readRunning: true) == .leaveLine)
    }

    @Test func escapeDismissesThenCancelsThenLeaves() {
        #expect(queryLineGhostKey(.escape, ghostShowing: true, readRunning: true) == .dismiss)
        #expect(queryLineGhostKey(.escape, ghostShowing: true, readRunning: false) == .dismiss)
        #expect(queryLineGhostKey(.escape, ghostShowing: false, readRunning: true) == .cancelRead)
        #expect(queryLineGhostKey(.escape, ghostShowing: false, readRunning: false) == .leaveLine)
    }

    @Test func returnNeverAccepts() {
        #expect(queryLineGhostKey(.returnKey, ghostShowing: true, readRunning: false) == .passThrough)
        #expect(queryLineGhostKey(.returnKey, ghostShowing: false, readRunning: true) == .passThrough)
    }

    @Test func asksOnlyAtTheEndOfALine() {
        let t = "SELECT * FROM bookings WHERE \nLIMIT 10"
        #expect(queryLineAsksForGhost(text: t, caret: t.index(t.startIndex, offsetBy: 29)))
        #expect(!queryLineAsksForGhost(text: t, caret: t.index(t.startIndex, offsetBy: 7)))
        #expect(queryLineAsksForGhost(text: "SELECT ", caret: "SELECT ".endIndex))
    }

    @Test func trailingWhitespaceOnTheLineStillAsks() {
        let t = "SELECT *   \t\nFROM x"
        #expect(queryLineAsksForGhost(text: t, caret: t.index(t.startIndex, offsetBy: 8)))
        #expect(queryLineAsksForGhost(text: t, caret: t.endIndex))
        // Mid-word on the last line: text follows the caret.
        #expect(!queryLineAsksForGhost(text: t, caret: t.index(t.startIndex, offsetBy: 15)))
    }

    @Test func anEmptyLineDoesNotAsk() {
        #expect(!queryLineAsksForGhost(text: "", caret: "".endIndex))
        #expect(!queryLineAsksForGhost(text: "   ", caret: "   ".endIndex))
    }
}
