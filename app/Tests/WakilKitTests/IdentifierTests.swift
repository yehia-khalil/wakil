import Testing
@testable import WakilKit

@Test func foldKeepsOnlyLettersDigitsAndDots() {
    #expect(identifierFold("transaction read only") == "transactionreadonly")
    #expect(identifierFold("transaction_read_only") == "transactionreadonly")
    #expect(identifierFold("Describe-Editability") == "describeeditability")
    #expect(identifierFold("customer's") == "customers")
    #expect(identifierFold("internal/wakilcore") == "internalwakilcore")
    #expect(identifierFold("paths.go") == "paths.go")
}

@Test func vocabularyLooksUpByFoldedForm() {
    let a = Identifier(text: "edit_quote", kind: .table, origin: "staging · core db", source: .schema)
    let b = Identifier(text: "EditQuote", kind: .code, origin: "wakil/app", source: .code)
    let vocabulary = Vocabulary([a, b, a])
    #expect(vocabulary.count == 2)
    #expect(Set(vocabulary.names(folded: "editquote")) == [a, b])
    #expect(vocabulary.names(folded: "nothing").isEmpty)
    #expect(Vocabulary.empty.count == 0)
}
