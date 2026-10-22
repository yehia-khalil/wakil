import Testing
@testable import WakilKit

/// The words the Settings pane's API page and database rows say (2e-iii), pinned because the e2e
/// checks assert them verbatim.

@Test func theTokenRowNamesTheKeychainRefOrNone() {
    #expect(ApiEntryWording.token(authRef: "api:shop:staging:orders-api")
        == "in Keychain (api:shop:staging:orders-api)")
    #expect(ApiEntryWording.token(authRef: "") == "none")
}

@Test func onlyALaterEntryOfAClashingNameCarriesTheNote() {
    let names = ["orders-api", "billing", "orders-api"]
    #expect(ApiEntryWording.clash(names: names, at: 0) == nil)
    #expect(ApiEntryWording.clash(names: names, at: 1) == nil)
    #expect(ApiEntryWording.clash(names: names, at: 2)
        == "two API entries are named orders-api; edits act on the first")
    #expect(ApiEntryWording.clash(names: names, at: 3) == nil)
}

@Test func theCardSavesOnceNameAndBaseUrlAreFilled() {
    #expect(!ApiEntryWording.canSave(name: "", baseUrl: "https://api.example.com"))
    #expect(!ApiEntryWording.canSave(name: "orders-api", baseUrl: ""))
    #expect(!ApiEntryWording.canSave(name: "  ", baseUrl: "https://api.example.com"))
    #expect(ApiEntryWording.canSave(name: "orders-api", baseUrl: "https://api.example.com"))
}

@Test func theConfirmationsAreWordForWord() {
    #expect(ApiEntryWording.tokenConfirmation(name: "orders-api", environment: "staging")
        == "Store a token for orders-api in staging? It goes to your Keychain, not to the project file.")
    #expect(ApiEntryWording.removal(name: "orders-api", environment: "staging")
        == "Remove orders-api from staging? Its Keychain item is kept.")
    #expect(DatabaseWording.removal(name: "ledger", environment: "staging")
        == "Remove ledger from staging? Its Keychain entries are kept.")
}
