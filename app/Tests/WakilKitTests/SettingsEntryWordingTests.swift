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

/// The final review's finding: a key without the project let `staging` in one project open,
/// spin or refuse on `staging` in another. Must fail if any builder drops the project path.
@Test func theSameEnvironmentInAnotherProjectRepointsNothing() {
    #expect(SettingsRowKey.apiSection(project: "/a/project.json", environment: "staging", index: 0)
        != SettingsRowKey.apiSection(project: "/b/project.json", environment: "staging", index: 0))
    #expect(SettingsRowKey.databaseRemoval(project: "/a/project.json", environment: "staging", name: "core")
        != SettingsRowKey.databaseRemoval(project: "/b/project.json", environment: "staging", name: "core"))
    #expect(SettingsRowKey.databaseRevoke(project: "/a/project.json", environment: "staging", name: "core")
        != SettingsRowKey.databaseRevoke(project: "/b/project.json", environment: "staging", name: "core"))
    // Nor does a dot in a name let two places spell one key.
    #expect(SettingsRowKey.databaseRemoval(project: "/a", environment: "s.x", name: "y")
        != SettingsRowKey.databaseRemoval(project: "/a", environment: "s", name: "x.y"))
}

@Test func replaceConnectionFocusesTheFirstEmptyCredentialField() {
    #expect(DatabaseConnectionFields(driver: "mysql").firstEmptyCredentialField == .host)
    #expect(DatabaseConnectionFields(driver: "mysql", host: "db", database: "orders")
        .firstEmptyCredentialField == .user)
    #expect(DatabaseConnectionFields(driver: "mongo", host: "db", user: "u", database: "d")
        .firstEmptyCredentialField == .password)
    #expect(DatabaseConnectionFields(driver: "sqlite").firstEmptyCredentialField == .path)
    #expect(DatabaseConnectionFields(driver: "sqlite", path: "/x.db").firstEmptyCredentialField == nil)
}
