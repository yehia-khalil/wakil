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
