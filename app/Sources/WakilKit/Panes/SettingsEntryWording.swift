import Foundation

/// What the Settings pane says about an environment's API entries and databases (2e-iii): the
/// token line, the clash note, the card's readiness and the two confirmations, word for word.
///
/// Here rather than in the view so the copy the e2e checks assert is pinned by a unit test, and
/// so the view only lays it out.
public enum ApiEntryWording {
    /// The Token row's value: the Keychain ref the token lives under — the NAME, never the
    /// secret — or `none`.
    public static func token(authRef: String) -> String {
        authRef.isEmpty ? "none" : "in Keychain (\(authRef))"
    }

    /// The caution note on an entry whose name an earlier entry already has (a hand edit). Only
    /// the later ones carry it: an edit or a removal by name acts on the first, which is the one
    /// the page draws first and the one the note is not needed on.
    public static func clash(names: [String], at index: Int) -> String? {
        guard names.indices.contains(index) else { return nil }
        let name = names[index]
        guard names[..<index].contains(name) else { return nil }
        return "two API entries are named \(name); edits act on the first"
    }

    /// The add card's **Save** is live once NAME and BASE URL hold something other than blanks.
    /// The token and the auth header are optional (Rule 9).
    public static func canSave(name: String, baseUrl: String) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseUrl.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Asked before a token is stored, from the card or from **Replace token**. It names no part
    /// of the token.
    public static func tokenConfirmation(name: String, environment: String) -> String {
        "Store a token for \(name) in \(environment)? It goes to your Keychain, not to the project file."
    }

    /// Asked before an entry is removed. Says what is NOT destroyed.
    public static func removal(name: String, environment: String) -> String {
        "Remove \(name) from \(environment)? Its Keychain item is kept."
    }
}

public enum DatabaseWording {
    /// Asked before a database is removed (2e-iii; until then it asked nothing). Says what is
    /// NOT destroyed.
    public static func removal(name: String, environment: String) -> String {
        "Remove \(name) from \(environment)? Its Keychain entries are kept."
    }

    /// The card's title, and in edit mode (2e-iv) the database it is filled from.
    public static let cardTitle = "ADD OR REPLACE A DATABASE"
    public static func editTitle(name: String) -> String { "EDIT \(name)" }

    /// A password field left empty on Edit keeps the stored password (Rule 9).
    public static let unchanged = "unchanged"

    /// Above the card's fields when Edit opened a legacy record: its Keychain item is the whole
    /// string, and splitting it would mean parsing a secret.
    public static let legacyNote = "This connection was saved as one string, so it can't be shown. "
        + "Type it once and it will be editable from then on."

    /// A database row's location line, under its chips: `user@host:port/database` for a server
    /// (the driver's default port when none is stored), the file for SQLite, and for a legacy
    /// record the fact that there is nothing to show. Never a password — the tree has none.
    public static func location(_ database: SettingsDatabase) -> String {
        guard let connection = database.connection else { return "saved as one string" }
        guard databaseDriverHasServer(database.driver) else { return connection.path }
        let port = connection.port.isEmpty
            ? (defaultDatabasePort(for: database.driver) ?? "") : connection.port
        return "\(connection.user)@\(connection.host):\(port)/\(connection.database)"
    }

    /// The one check the card makes before Go does: a required part left empty, in Go's own
    /// words and order. Everything else — the port's range, characters a driver reads as
    /// structure, a MySQL user's colon — is Go's refusal, shown whole under the card.
    public static func missingPart(_ fields: DatabaseConnectionFields) -> String? {
        switch fields.driver {
        case "sqlite":
            return fields.path.isEmpty ? "a SQLite database needs the path to its file" : nil
        case let driver where databaseDriverHasServer(driver):
            if fields.host.isEmpty { return "a host is needed" }
            if fields.user.isEmpty { return "a user is needed" }
            if fields.database.isEmpty { return "a database name is needed" }
            return nil
        default:
            return nil
        }
    }

    /// Whether Save asks first (Rule 1): when a password goes to the Keychain, or when the save
    /// makes the database writable (SQLite included). A save of host, port, database, user or path
    /// alone is an ordinary edit.
    public static func asksBeforeSaving(
        password: String, grantWrite: Bool, writePassword: String, becomesWritable: Bool
    ) -> Bool {
        becomesWritable || !password.isEmpty || (grantWrite && !writePassword.isEmpty)
    }

    /// Asked before a password is stored. It names no part of the connection. A save that makes
    /// the database writable says so: that is the other thing a Store it grants.
    public static func connectionConfirmation(name: String, environment: String, becomesWritable: Bool) -> String {
        "Store a connection for \(name) in \(environment)? The password goes to your Keychain, "
            + "not to the project file" + (becomesWritable ? ", and this database becomes writable." : ".")
    }
}

/// The keys an API entry's and a database's in-place writes, refusals and confirmations are held
/// under (2e-iii). **Each names the project by its path**: two projects can each have a `staging`,
/// and a key without the project would let a removal confirmed on one page open, spin or refuse
/// on the other's.
public enum SettingsRowKey {
    /// One API entry, by position: a hand-edited file can hold two of one name. **And by how many
    /// entries there are**: a rename keeps the key (a focused field is not torn down when it
    /// lands), while an add or a removal changes every key, so nothing held by position — a
    /// refused draft, an open token field, a removal's question — passes to another entry.
    public static func apiSection(project: String, environment: String, index: Int, count: Int) -> String {
        "api.\(project)\u{1F}\(environment)\u{1F}\(index)\u{1F}\(count)"
    }

    /// A database's removal.
    public static func databaseRemoval(project: String, environment: String, name: String) -> String {
        "remove.db.\(project)\u{1F}\(environment)\u{1F}\(name)"
    }

    /// A database's write access revoked.
    public static func databaseRevoke(project: String, environment: String, name: String) -> String {
        "revokeWrite.db.\(project)\u{1F}\(environment)\u{1F}\(name)"
    }
}

extension DatabaseConnectionFields {
    /// The card's fields the keyboard can be put in (Rule 3), by focus key.
    public enum CredentialField: String, Sendable {
        case host, database, user, password, path
    }
}
