import Testing
@testable import WakilKit

private func name(_ text: String, _ kind: IdentifierKind = .column, _ origin: String = "staging · core db",
                  _ source: IdentifierSourceKind = .schema) -> Identifier {
    Identifier(text: text, kind: kind, origin: origin, source: source)
}

@Test func joinsWordsIntoTheIdentifierTheyFold() {
    let v = Vocabulary([name("transaction_read_only")])
    let r = IdentifierResolver.resolve("Set transaction read only to one.", in: v)
    #expect(r == [Resolution(phrase: "transaction read only", candidates: [name("transaction_read_only")], more: 0)])
}

@Test func longestRunWinsAndRunsDoNotOverlap() {
    let v = Vocabulary([name("read_only"), name("transaction_read_only")])
    let r = IdentifierResolver.resolve("transaction read only", in: v)
    #expect(r.map(\.phrase) == ["transaction read only"])
}

@Test func aRunThatAlreadyIsTheNameResolvesNothing() {
    let v = Vocabulary([name("wakil", .project, "initech", .wakil), name("staging", .environment, "initech", .wakil)])
    #expect(IdentifierResolver.resolve("List the databases on Wakil, then staging.", in: v).isEmpty)
}

/// A name that itself starts or ends with punctuation is compared with its
/// edges stripped the same way the typed word's are, so typing it exactly
/// offers nothing back.
@Test func aPathTypedExactlyResolvesNothing() {
    let v = Vocabulary([name("/v1/orders", .endpoint, "pane · api", .panes)])
    #expect(IdentifierResolver.resolve("call /v1/orders now", in: v).isEmpty)
}

@Test func aLeadingUnderscoreNameTypedExactlyResolvesNothing() {
    let v = Vocabulary([name("_private", .code, "wakil/app", .code)])
    #expect(IdentifierResolver.resolve("where is _private set", in: v).isEmpty)
}

@Test func surroundingPunctuationIsStrippedButInnerDotsKept() {
    let v = Vocabulary([name("ContextStore.swift", .file, "wakil/app", .code)])
    let r = IdentifierResolver.resolve("Open context store.swift.", in: v)
    #expect(r.map(\.phrase) == ["context store.swift"])
}

@Test func candidatesRankBySourceThenOriginThenTextAndCapAtThree() {
    let v = Vocabulary([
        name("status", .code, "wakil/app", .code),
        name("Status", .column, "staging · jobs db", .schema),
        name("STATUS", .column, "staging · core db", .schema),
        name("status_", .column, "pane", .panes),
        name("s_tatus", .code, "a", .code),
    ])
    let r = IdentifierResolver.resolve("what is the S tatus", in: v)
    #expect(r.count == 1)
    #expect(r[0].candidates.map(\.text) == ["status_", "STATUS", "Status"])
    #expect(r[0].more == 2)
}

@Test func moreThanEightResolutionsMeansNone() {
    let names = (1...9).map { name("word\($0)_x") }
    let text = (1...9).map { "word\($0) x" }.joined(separator: " and ")
    #expect(IdentifierResolver.resolve(text, in: Vocabulary(names)).isEmpty)
    let eight = (1...8).map { "word\($0) x" }.joined(separator: " and ")
    #expect(IdentifierResolver.resolve(eight, in: Vocabulary(names)).count == 8)
}

@Test func anEmptyVocabularyOrTextResolvesNothing() {
    #expect(IdentifierResolver.resolve("transaction read only", in: .empty).isEmpty)
    #expect(IdentifierResolver.resolve("", in: Vocabulary([name("x_y")])).isEmpty)
}
