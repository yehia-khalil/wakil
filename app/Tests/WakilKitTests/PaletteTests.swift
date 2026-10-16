import Testing
@testable import WakilKit

@Test func anEmptyQueryMatchesEverythingWithEqualScore() {
    #expect(fuzzyScore("", against: "pane_move") != nil)
    #expect(fuzzyScore("", against: "anything") == fuzzyScore("", against: "other"))
}

@Test func aNonSubsequenceDoesNotMatch() {
    #expect(fuzzyScore("zzz", against: "pane_move") == nil)
    // Right letters, wrong order.
    #expect(fuzzyScore("evom", against: "pane_move") == nil)
}

@Test func aSubsequenceMatchesEvenWhenScattered() {
    #expect(fuzzyScore("pm", against: "pane_move") != nil)
    #expect(fuzzyScore("pnmv", against: "pane_move") != nil)
}

@Test func matchingIsCaseInsensitive() {
    #expect(fuzzyScore("PM", against: "pane_move") != nil)
    #expect(fuzzyScore("pm", against: "PANE_MOVE") != nil)
}

@Test func aPrefixScoresHigherThanAScatteredMatch() {
    let prefix = try! #require(fuzzyScore("pane", against: "pane_move"))
    let scattered = try! #require(fuzzyScore("pane", against: "propagate_and_negate"))
    #expect(prefix > scattered)
}

@Test func aWordBoundaryScoresHigherThanMidWord() {
    // "pm" hits the start of both words in pane_move.
    let boundary = try! #require(fuzzyScore("pm", against: "pane_move"))
    // "pm" in "compamy" is mid-word twice.
    let midWord = try! #require(fuzzyScore("pm", against: "compamy"))
    #expect(boundary > midWord)
}
