import Testing
@testable import WakilKit

/// **The database form's fields become one connection string, here and
/// nowhere else.** The pane used to take the string itself, and the
/// fixture's own `mysql://e2e:secret@localhost/ledger` is the proof of
/// what that costs: URL form, which `go-sql-driver`'s `ParseDSN` does not
/// accept. Each driver wants its own shape, so the form asks for the parts
/// and this builds the shape.
///
/// **The strings pinned here are the ones `internal/wakilcore/
/// connfields_test.go` feeds to the real parsers.** A change to one side
/// without the other is a test that stops meaning anything, so both files
/// carry the same literals.

private func fields(
    _ driver: String, host: String = "db.internal", port: String = "",
    user: String = "reader", password: String = "s3cret", database: String = "orders",
    path: String = ""
) -> DatabaseConnectionFields {
    DatabaseConnectionFields(
        driver: driver, host: host, port: port, user: user, password: password,
        database: database, path: path)
}

// MARK: - The three shapes

@Test func mysqlBuildsTheDriversOwnFormNotAURL() {
    #expect(databaseConnectionString(fields("mysql"))
            == .built("reader:s3cret@tcp(db.internal:3306)/orders"))
}

@Test func mongoBuildsAURI() {
    #expect(databaseConnectionString(fields("mongo"))
            == .built("mongodb://reader:s3cret@db.internal:27017/orders"))
}

@Test func sqliteIsItsPathAndNothingElse() {
    #expect(databaseConnectionString(fields("sqlite", path: "/data/orders.db"))
            == .built("/data/orders.db"))
}

// MARK: - The port

@Test func anExplicitPortIsUsed() {
    #expect(databaseConnectionString(fields("mysql", port: "3307"))
            == .built("reader:s3cret@tcp(db.internal:3307)/orders"))
}

@Test func aPortThatIsNotOneIsRefused() {
    for port in ["0", "65536", "33o6", "-1", " 3306"] {
        guard case .refused = databaseConnectionString(fields("mysql", port: port)) else {
            Issue.record("port \(port.debugDescription) was accepted"); continue
        }
    }
}

// MARK: - Passwords a person actually types

/// `@ : / ?` are the characters each format treats as structure. MySQL's
/// parser splits on the LAST `@` and the LAST `/`, so they are safe in a
/// password as they stand; a URI needs them percent-encoded.
@Test func mysqlCarriesAPasswordWithStructureInIt() {
    #expect(databaseConnectionString(fields("mysql", password: "p@ss:w/rd?1"))
            == .built("reader:p@ss:w/rd?1@tcp(db.internal:3306)/orders"))
}

@Test func mongoPercentEncodesTheUserAndPassword() {
    #expect(databaseConnectionString(fields("mongo", user: "app@ops", password: "p@ss:w/rd?1"))
            == .built("mongodb://app%40ops:p%40ss%3Aw%2Frd%3F1@db.internal:27017/orders"))
}

@Test func anEmptyPasswordIsAllowed() {
    #expect(databaseConnectionString(fields("mysql", password: ""))
            == .built("reader:@tcp(db.internal:3306)/orders"))
}

// MARK: - What cannot be built is refused, never guessed

@Test func theRequiredPartsAreRefusedWhenMissing() {
    for missing in [fields("mysql", host: ""), fields("mysql", user: ""),
                    fields("mysql", database: ""), fields("mongo", host: ""),
                    fields("sqlite", path: "")] {
        guard case .refused = databaseConnectionString(missing) else {
            Issue.record("\(missing) was accepted"); continue
        }
    }
}

/// MySQL's parser takes the FIRST `:` of the userinfo as the split, so a
/// user carrying one would silently become a shorter user and a longer
/// password. Refused rather than escaped: the format has no escape.
@Test func aMySQLUserWithAColonIsRefused() {
    guard case .refused(let reason) = databaseConnectionString(fields("mysql", user: "a:b")) else {
        Issue.record("a user with a colon was accepted"); return
    }
    #expect(reason.contains(":"))
}

@Test func aHostOrDatabaseThatWouldBreakTheShapeIsRefused() {
    for broken in [fields("mysql", host: "db)internal"), fields("mysql", host: "db/internal"),
                   fields("mysql", host: "db internal"), fields("mysql", database: "or/ders"),
                   fields("mysql", database: "orders?x=1"), fields("mongo", host: "db/internal")] {
        guard case .refused = databaseConnectionString(broken) else {
            Issue.record("\(broken) was accepted"); continue
        }
    }
}

@Test func anUnknownDriverIsRefused() {
    guard case .refused = databaseConnectionString(fields("postgres")) else {
        Issue.record("an unregistered driver was accepted"); return
    }
}

/// The refusal must never quote the password back — it is drawn on screen.
@Test func noRefusalRepeatsThePassword() {
    let reason: String
    switch databaseConnectionString(fields("mysql", host: "", password: "hunter2")) {
    case .refused(let text): reason = text
    case .built: Issue.record("expected a refusal"); return
    }
    #expect(!reason.contains("hunter2"))
}

// MARK: - The form's two credentials

/// The write credential is a second LOGIN to the same server: same host,
/// port and database, its own user and password.
@Test func theWriteCredentialSharesTheServerAndChangesTheLogin() {
    let result = databaseFormCredentials(
        fields("mysql"), grantWrite: true, writeUser: "writer", writePassword: "w!")
    #expect(result == .built(read: "reader:s3cret@tcp(db.internal:3306)/orders",
                             write: "writer:w!@tcp(db.internal:3306)/orders"))
}

@Test func noWriteCredentialIsBuiltUnlessWritesAreGranted() {
    let result = databaseFormCredentials(
        fields("mysql"), grantWrite: false, writeUser: "writer", writePassword: "w!")
    #expect(result == .built(read: "reader:s3cret@tcp(db.internal:3306)/orders", write: nil))
}

/// Granting writes with no write login is the one refusal `wakilcore`
/// also makes (`TestGrantingWriteAccessNeedsItsOwnCredential`); saying it
/// here says it before the confirmation, where it can be corrected.
@Test func grantingWritesWithNoWriteUserIsRefused() {
    guard case .refused = databaseFormCredentials(
        fields("mysql"), grantWrite: true, writeUser: "", writePassword: "") else {
        Issue.record("a grant with no write user was accepted"); return
    }
}

/// A SQLite file has no logins: writing it is opening the same path for
/// writing, so the write credential is the path again.
@Test func aSQLiteGrantWritesTheSameFile() {
    let result = databaseFormCredentials(
        fields("sqlite", path: "/data/orders.db"), grantWrite: true, writeUser: "", writePassword: "")
    #expect(result == .built(read: "/data/orders.db", write: "/data/orders.db"))
}

@Test func aRefusedReadCredentialRefusesTheForm() {
    guard case .refused = databaseFormCredentials(
        fields("mysql", host: ""), grantWrite: false, writeUser: "", writePassword: "") else {
        Issue.record("the form was accepted with no host"); return
    }
}
