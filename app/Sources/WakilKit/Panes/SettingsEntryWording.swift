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
    /// The card field **Replace connection** puts the keyboard in (Rule 3): the first empty one a
    /// connection needs, in the order the card draws them — host, database, user, password for a
    /// server (the port has its default), the file for SQLite. Nil when all are filled.
    public enum CredentialField: String, Sendable {
        case host, database, user, password, path
    }

    public var firstEmptyCredentialField: CredentialField? {
        guard databaseDriverHasServer(driver) else { return path.isEmpty ? .path : nil }
        let order: [(CredentialField, String)] = [
            (.host, host), (.database, database), (.user, user), (.password, password),
        ]
        return order.first { $0.1.isEmpty }?.0
    }
}
