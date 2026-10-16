import Testing
@testable import WakilKit

@Test func eachKindMapsToTheSpecsTable() {
    #expect(SQLStyle.style(for: .keyword) == SQLTokenStyle(opacity: 1.0, medium: true, italic: false))
    for kind: SQLTokenKind in [.identifier, .quotedIdentifier] {
        #expect(SQLStyle.style(for: kind) == SQLTokenStyle(opacity: 0.85, medium: false, italic: false))
    }
    for kind: SQLTokenKind in [.string, .number, .op, .punctuation] {
        #expect(SQLStyle.style(for: kind) == SQLTokenStyle(opacity: 0.6, medium: false, italic: false))
    }
    #expect(SQLStyle.style(for: .comment) == SQLTokenStyle(opacity: 0.4, medium: false, italic: true))
    #expect(SQLStyle.style(for: .whitespace).opacity == 1.0)
}
