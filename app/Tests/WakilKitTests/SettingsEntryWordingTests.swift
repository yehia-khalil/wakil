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
    #expect(SettingsRowKey.apiSection(project: "/a/project.json", environment: "staging", index: 0, count: 1)
        != SettingsRowKey.apiSection(project: "/b/project.json", environment: "staging", index: 0, count: 1))
    #expect(SettingsRowKey.databaseRemoval(project: "/a/project.json", environment: "staging", name: "core")
        != SettingsRowKey.databaseRemoval(project: "/b/project.json", environment: "staging", name: "core"))
    #expect(SettingsRowKey.databaseRevoke(project: "/a/project.json", environment: "staging", name: "core")
        != SettingsRowKey.databaseRevoke(project: "/b/project.json", environment: "staging", name: "core"))
    // Nor does a dot in a name let two places spell one key.
    #expect(SettingsRowKey.databaseRemoval(project: "/a", environment: "s.x", name: "y")
        != SettingsRowKey.databaseRemoval(project: "/a", environment: "s", name: "x.y"))
}

/// The residual finding on 2e-iii: sections keyed by position alone let a refused Base URL draft,
/// an open Replace token or a removal's question pass to the entry that slid into a removed one's
/// place. Must fail if the key drops the count — and if a rename (same count) changes it, which
/// would tear down the field being typed in when the rename lands.
@Test func aRemovalRekeysEveryApiSectionButARenameKeepsThem() {
    let before = SettingsRowKey.apiSection(project: "/a/project.json", environment: "staging", index: 1, count: 3)
    let afterRemoval = SettingsRowKey.apiSection(project: "/a/project.json", environment: "staging", index: 1, count: 2)
    let afterAdd = SettingsRowKey.apiSection(project: "/a/project.json", environment: "staging", index: 1, count: 4)
    #expect(before != afterRemoval)
    #expect(before != afterAdd)
    #expect(before == SettingsRowKey.apiSection(project: "/a/project.json", environment: "staging", index: 1, count: 3))
    // Index and count are kept apart: 1·12 is not 11·2.
    #expect(SettingsRowKey.apiSection(project: "/a", environment: "s", index: 1, count: 12)
        != SettingsRowKey.apiSection(project: "/a", environment: "s", index: 11, count: 2))
}

// MARK: - 2e-iv: Edit fills the card with all but the password

private let split = SettingsDatabase(
    name: "ledger", driver: "mysql", ref: "db:p:staging:ledger",
    connection: SettingsDatabaseConnection(host: "db.internal", port: "3306", database: "ledger", user: "e2e"))
private let splitWritable = SettingsDatabase(
    name: "books", driver: "mongo", ref: "db:p:staging:books", writeRef: "db:p:staging:books:rw",
    writable: true,
    connection: SettingsDatabaseConnection(host: "mongo.internal", database: "books", user: "reader",
                                           writeUser: "writer"))
private let legacy = SettingsDatabase(name: "invoices", driver: "mysql", ref: "db:p:staging:invoices")
private let legacyWritable = SettingsDatabase(
    name: "orders", driver: "mysql", ref: "db:p:staging:orders", writeRef: "db:p:staging:orders:rw",
    writable: true)
private let sqlite = SettingsDatabase(
    name: "cache", driver: "sqlite", ref: "db:p:staging:cache",
    connection: SettingsDatabaseConnection(path: "/var/data/cache.db"))

@Test func theLocationLineSaysWhereADatabaseLives() {
    #expect(DatabaseWording.location(split) == "e2e@db.internal:3306/ledger")
    // No stored port reads as the driver's default, which is what connect uses.
    #expect(DatabaseWording.location(splitWritable) == "reader@mongo.internal:27017/books")
    #expect(DatabaseWording.location(sqlite) == "/var/data/cache.db")
    #expect(DatabaseWording.location(legacy) == "saved as one string")
}

@Test func theCardsWordsAreWordForWord() {
    #expect(DatabaseWording.cardTitle == "ADD OR REPLACE A DATABASE")
    #expect(DatabaseWording.editTitle(name: "ledger") == "EDIT ledger")
    #expect(DatabaseWording.unchanged == "unchanged")
    #expect(DatabaseWording.legacyNote == "This connection was saved as one string, so it can't be shown. "
        + "Type it once and it will be editable from then on.")
    #expect(DatabaseWording.connectionConfirmation(name: "ledger", environment: "staging", becomesWritable: false)
        == "Store a connection for ledger in staging? The password goes to your Keychain, not to the project file.")
    #expect(DatabaseWording.connectionConfirmation(name: "ledger", environment: "staging", becomesWritable: true)
        == "Store a connection for ledger in staging? The password goes to your Keychain, not to the project file, "
        + "and this database becomes writable.")
}

@Test func editFillsEverythingButThePassword() {
    let edit = DatabaseCardEdit(editing: split)
    #expect(edit.name == "ledger")
    #expect(!edit.legacy)
    #expect(edit.fields == DatabaseConnectionFields(
        driver: "mysql", host: "db.internal", port: "3306", user: "e2e", password: "", database: "ledger"))
    #expect(!edit.grantWrite)
    #expect(edit.writeUser == "")
    #expect(edit.focus == .host)
}

@Test func editOnAWritableSplitRecordAllowsWritesAndKeepsTheWriteLogin() {
    let edit = DatabaseCardEdit(editing: splitWritable)
    #expect(edit.grantWrite)
    #expect(edit.writeUser == "writer")
    #expect(edit.fields.password == "")
    #expect(edit.passwordPrompt(name: "books", driver: "mongo", user: "reader") == "unchanged")
    #expect(edit.writePasswordPrompt(name: "books", driver: "mongo", writeUser: "writer") == "unchanged")
}

/// `unchanged` is a promise Go keeps only for the same driver and the same user. Must fail if a
/// prompt says it after either moved, which Save would then refuse.
@Test func unchangedIsSaidOnlyWhileEmptyKeepsTheStoredPassword() {
    let edit = DatabaseCardEdit(editing: splitWritable)
    #expect(edit.passwordPrompt(name: "books", driver: "mongo", user: "someone-else") == "")
    #expect(edit.passwordPrompt(name: "books", driver: "mysql", user: "reader") == "")
    #expect(edit.writePasswordPrompt(name: "books", driver: "mongo", writeUser: "another-writer") == "")
    // A split record that never wrote has no write password to keep.
    #expect(DatabaseCardEdit(editing: split).writePasswordPrompt(name: "ledger", driver: "mysql", writeUser: "writer") == "")
}

@Test func editOnALegacyRecordFillsNameAndDriverAndAsksForEveryLogin() {
    let edit = DatabaseCardEdit(editing: legacy)
    #expect(edit.legacy)
    #expect(edit.fields == DatabaseConnectionFields(driver: "mysql"))
    #expect(edit.passwordPrompt(name: "invoices", driver: "mysql", user: "") == "")
    #expect(edit.focus == .host)
    // Writable and legacy: writes start allowed (Go refuses the save without them) and the write
    // login is typed whole.
    let writable = DatabaseCardEdit(editing: legacyWritable)
    #expect(writable.grantWrite)
    #expect(writable.writeUser == "")
    #expect(writable.writePasswordPrompt(name: "orders", driver: "mysql", writeUser: "") == "")
}

@Test func editOnSQLiteFillsThePathAndFocusesIt() {
    let edit = DatabaseCardEdit(editing: sqlite)
    #expect(edit.fields == DatabaseConnectionFields(driver: "sqlite", path: "/var/data/cache.db"))
    #expect(edit.focus == .path)
    // An unknown driver is offered as the form's first, as Replace connection did.
    #expect(DatabaseCardEdit(editing: SettingsDatabase(name: "x", driver: "postgres")).fields.driver == "mysql")
}

/// The card checks only what is required, in Go's words and order; the rest is Go's refusal.
@Test func theCardChecksOnlyRequiredParts() {
    #expect(DatabaseWording.missingPart(DatabaseConnectionFields(driver: "mysql")) == "a host is needed")
    #expect(DatabaseWording.missingPart(DatabaseConnectionFields(driver: "mongo", host: "db"))
        == "a user is needed")
    #expect(DatabaseWording.missingPart(DatabaseConnectionFields(driver: "mysql", host: "db", user: "u"))
        == "a database name is needed")
    #expect(DatabaseWording.missingPart(DatabaseConnectionFields(driver: "sqlite"))
        == "a SQLite database needs the path to its file")
    #expect(DatabaseWording.missingPart(DatabaseConnectionFields(driver: "sqlite", path: "/x.db")) == nil)
    // A bad port, a password, a host breaker: not the card's to refuse.
    #expect(DatabaseWording.missingPart(DatabaseConnectionFields(
        driver: "mysql", host: "a/b", port: "0", user: "u", database: "d")) == nil)
}

@Test func onlyATypedPasswordAsksBeforeSaving() {
    #expect(!DatabaseWording.asksBeforeSaving(password: "", grantWrite: false, writePassword: "", becomesWritable: false))
    #expect(DatabaseWording.asksBeforeSaving(password: "hunter2", grantWrite: false, writePassword: "", becomesWritable: false))
    #expect(DatabaseWording.asksBeforeSaving(password: "", grantWrite: true, writePassword: "w", becomesWritable: false))
    // A write password with writes not allowed is not sent, so nothing is stored to ask about.
    #expect(!DatabaseWording.asksBeforeSaving(password: "", grantWrite: false, writePassword: "w", becomesWritable: false))
}

/// Ruling 9: making a database writable always asks, SQLite (no password at all) included.
@Test func aSaveThatMakesTheDatabaseWritableAlwaysAsks() {
    #expect(DatabaseWording.asksBeforeSaving(password: "", grantWrite: true, writePassword: "", becomesWritable: true))
}

/// Review round 1: a NAME changed in edit mode saves another database, for which nothing is
/// stored. Must fail if `unchanged` or the EDIT title outlives the name.
@Test func unchangedAndTheEditTitleHoldOnlyForTheDatabaseBeingEdited() {
    let edit = DatabaseCardEdit(editing: split)
    #expect(edit.passwordPrompt(name: "ledger", driver: "mysql", user: "e2e") == "unchanged")
    #expect(edit.passwordPrompt(name: "ledger2", driver: "mysql", user: "e2e") == "")
    let writable = DatabaseCardEdit(editing: splitWritable)
    #expect(writable.writePasswordPrompt(name: "books2", driver: "mongo", writeUser: "writer") == "")
    #expect(edit.title(name: "ledger") == "EDIT ledger")
    #expect(edit.title(name: "ledger2") == "ADD OR REPLACE A DATABASE")
}

/// Ruling 8: unchecking Allow writes on a writable database revokes nothing, so Edit hides it there.
@Test func allowWritesIsHiddenOnlyWhileEditingAWritableDatabase() {
    #expect(!DatabaseCardEdit(editing: splitWritable).showsAllowWrites(name: "books"))
    #expect(!DatabaseCardEdit(editing: legacyWritable).showsAllowWrites(name: "orders"))
    #expect(DatabaseCardEdit(editing: split).showsAllowWrites(name: "ledger"))
    // A new name is another database, which may be granted.
    #expect(DatabaseCardEdit(editing: splitWritable).showsAllowWrites(name: "books2"))
}

/// Ruling 10: a database renamed or removed from its row leaves the card with nothing to edit.
@Test func theEditTargetIsListedOnlyWhileItsNameIs() {
    let edit = DatabaseCardEdit(editing: split)
    #expect(edit.isListed(in: ["books", "ledger"]))
    #expect(!edit.isListed(in: ["books", "ledger-old"]))
}
