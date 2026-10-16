import Testing
@testable import WakilKit

private let column = Identifier(text: "transaction_read_only", kind: .column, origin: "staging · core db", source: .schema)
private let code = Identifier(text: "describeEditability", kind: .code, origin: "wakil/app", source: .code)
private let two = [
    Resolution(phrase: "transaction read only", candidates: [column], more: 0),
    Resolution(phrase: "describe editability", candidates: [code], more: 0),
]

@Test func renderWritesTheHeaderAndOneLinePerPhrase() {
    #expect(TurnNote.render(two) == """
    [Wakil: identifiers in scope that match words in this turn — a hint, not a correction]
    - "transaction read only" → transaction_read_only (column · staging · core db)
    - "describe editability" → describeEditability (code · wakil/app)
    """)
}

@Test func renderListsSeveralCandidatesAndHowManyMore() {
    let a = Identifier(text: "orders.status", kind: .column, origin: "staging · core db", source: .schema)
    let b = Identifier(text: "users.status", kind: .column, origin: "staging · core db", source: .schema)
    let note = TurnNote.render([Resolution(phrase: "status", candidates: [a, b], more: 2)])
    #expect(note?.hasSuffix(#"- "status" → orders.status (column · staging · core db), users.status (column · staging · core db) and 2 more"#) == true)
}

@Test func noResolutionsMeansNoNote() {
    #expect(TurnNote.render([]) == nil)
}

@Test func theRowNamesEachPhraseAndItsFirstCandidate() {
    #expect(TurnNote.row(two) == "transaction read only → transaction_read_only · describe editability → describeEditability")
}

@Test func splitUndoesWhatSendJoined() {
    let sent = "what is this\n\n" + TurnNote.render(two)!
    let parts = TurnNote.split(sent)
    #expect(parts.typed == "what is this")
    #expect(parts.row == TurnNote.row(two))
}

@Test func splitLeavesATurnWithNoNoteAlone() {
    let parts = TurnNote.split("just text\n\n[not ours]")
    #expect(parts.typed == "just text\n\n[not ours]")
    #expect(parts.row == nil)
}

@Test func splitRoundTripsIdentifiersWithSpacesInTheirText() {
    let actionId = Identifier(text: "make app-test", kind: .action, origin: "wakil", source: .wakil)
    let resolutions = [Resolution(phrase: "build test", candidates: [actionId], more: 0)]
    let rendered = TurnNote.render(resolutions)!
    let sent = "how do I\n\n" + rendered
    let parts = TurnNote.split(sent)
    #expect(parts.typed == "how do I")
    #expect(parts.row == TurnNote.row(resolutions))
}
