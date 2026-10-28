import Foundation

/// 3d-iv: the pure rules behind Settings → Browser → Passwords and the import sheet — the list by site,
/// how long one authentication holds, the sentences, and the order and outcome of an import. The views
/// (`BrowserPasswordsSettings.swift`, `BrowserPasswordImport.swift`) draw these and hold nothing else.
/// No value from the Keychain or a CSV ever reaches a sentence here: each is built from a site, a
/// username, an organisation or a count.

// MARK: - The authentication window (ruling 16)

/// Reveal and Copy need one `.deviceOwnerAuthentication`. It holds for the Passwords section until the
/// section closes or for five minutes, whichever comes first.
public struct BrowserPasswordUnlock: Sendable, Equatable {
    public static let duration: TimeInterval = 5 * 60

    /// When the operator last authenticated, or nil when the section is locked.
    public private(set) var since: Date?

    public init(since: Date? = nil) { self.since = since }

    /// Open from `since` up to, not including, `since + duration`. A clock that went back is locked.
    public func isOpen(at now: Date) -> Bool {
        guard let since else { return false }
        let elapsed = now.timeIntervalSince(since)
        return elapsed >= 0 && elapsed < Self.duration
    }

    /// When it locks again, or nil when it is locked.
    public var expires: Date? { since.map { $0.addingTimeInterval(Self.duration) } }

    public mutating func opened(at now: Date) { since = now }
    public mutating func lock() { since = nil }
}

// MARK: - The list by site

/// One site's logins, each with its place in the whole list: `settings.browser.passwords.row.<n>`.
public struct BrowserLoginGroup: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let index: Int
        public let login: BrowserLogin
    }

    public let site: String
    public let rows: [Row]
}

public enum BrowserPasswordSettings {
    /// Sites in order, usernames in order under each; `n` counts down the whole list.
    public static func bySite(_ logins: [BrowserLogin]) -> [BrowserLoginGroup] {
        let sorted = logins.sorted { ($0.site, $0.username) < ($1.site, $1.username) }
        var groups: [BrowserLoginGroup] = []
        var current: (site: String, rows: [BrowserLoginGroup.Row])?
        for (index, login) in sorted.enumerated() {
            if let open = current, open.site != login.site {
                groups.append(BrowserLoginGroup(site: open.site, rows: open.rows))
                current = nil
            }
            var open = current ?? (login.site, [])
            open.rows.append(BrowserLoginGroup.Row(index: index, login: login))
            current = open
        }
        if let open = current { groups.append(BrowserLoginGroup(site: open.site, rows: open.rows)) }
        return groups
    }

    // MARK: Which organisation a result is for (Invariant 4)

    /// A read or a reveal started for `asked` lands only if the section still shows `asked`. A result
    /// from before an organisation switch is dropped, never drawn on the new organisation's rows.
    public static func stillShown(asked: String, shown: String?) -> Bool { shown == asked }

    /// Only the shown organisation's logins are drawn, whatever reached the view.
    public static func visible(_ logins: [BrowserLogin], org: String) -> [BrowserLogin] {
        logins.filter { $0.org == org }
    }

    /// A row's key: organisation, site and username, so a value revealed in one organisation can never
    /// sit on another's row. An organisation name holds no space (`BrowserPasswords.service`).
    public static func rowKey(_ login: BrowserLogin) -> String {
        "\(login.org) " + BrowserPasswords.account(site: login.site, username: login.username)
    }

    // MARK: Copy

    public static let title = "Passwords"
    public static let hint = "Kept in the Keychain for this organisation. Wakil fills one only when you press "
        + "the key in a field, and the agent never sees them."
    public static let neverTitle = "Never saved for"
    public static let deleteLabel = "Delete"
    public static let keepLabel = "Keep it"
    public static let noUsername = "(no username)"

    public static func empty(org: String) -> String { "No passwords saved for \(org) yet." }

    /// What the row shows for a username: the name, or `(no username)` as the key's list does.
    public static func shown(_ username: String) -> String { username.isEmpty ? noUsername : username }

    /// The system's authentication sheet says *Wakil is trying to <reason>.*
    public static func revealReason(username: String, site: String) -> String {
        "reveal the password\(who(username)) on \(site)"
    }

    public static func copyReason(username: String, site: String) -> String {
        "copy the password\(who(username)) on \(site)"
    }

    public static func deleteQuestion(username: String, site: String) -> String {
        "Delete the password\(who(username)) on \(site)? It can't be brought back."
    }

    /// ` for <user>`, or nothing for a login with no username — as the save bar words it.
    private static func who(_ username: String) -> String { username.isEmpty ? "" : " for \(username)" }

    /// The edit's dispatches, in order: a rename first (keeping the password), then a new password under
    /// the name it has by then. Nothing when nothing changed; an empty new password keeps the old one.
    public static func editSaves(org: String, site: String, was: String, username: String, password: String)
        -> [[String: JSONValue]] {
        var saves: [[String: JSONValue]] = []
        if username != was {
            saves.append(["org": .string(org), "site": .string(site), "username": .string(username),
                          "previousUsername": .string(was)])
        }
        if !password.isEmpty {
            saves.append(["org": .string(org), "site": .string(site), "username": .string(username),
                          "password": .string(password)])
        }
        return saves
    }
}

// MARK: - The import (ruling 17)

public enum BrowserPasswordImportPlan {
    public static let title = "Import from the Passwords app"
    public static let hint = "In Passwords, choose File → Export All Passwords…, then pick the file here. "
        + "Wakil reads it and keeps no copy."
    public static let replaces = "replaces the saved password"
    public static let importLabel = "Import"
    public static let cancelLabel = "Cancel"
    public static let trashLabel = "Move to Trash"
    public static let keepLabel = "Keep it"

    /// By site (rows with none last), then username, then where they were in the file.
    public static func ordered(_ rows: [BrowserImportRow]) -> [BrowserImportRow] {
        rows.sorted { a, b in
            switch (a.site, b.site) {
            case (nil, .some): return false
            case (.some, nil): return true
            default: return (a.site ?? "", a.username, a.id) < (b.site ?? "", b.username, b.id)
            }
        }
    }

    /// The rows that are imported: every row the parser did not skip.
    public static func runnable(_ rows: [BrowserImportRow]) -> [BrowserImportRow] {
        rows.filter { $0.skipped == nil && $0.site != nil }
    }

    /// What a row says before it runs: its skip reason, or that it replaces a login already saved in the
    /// organisation it goes to (`saved` is that organisation's usernames on the row's site).
    public static func note(_ row: BrowserImportRow, saved: Set<String>) -> String? {
        if let skipped = row.skipped { return skipped }
        return saved.contains(row.username) ? replaces : nil
    }

    /// One `browser_password_save` per row (ruling 10). No `pane`: no page held it.
    public static func save(_ row: BrowserImportRow, org: String) -> [String: JSONValue]? {
        guard row.skipped == nil, let site = row.site else { return nil }
        return ["org": .string(org), "site": .string(site), "username": .string(row.username),
                "password": .string(row.password)]
    }

    public static func progress(_ n: Int, of total: Int) -> String { "Importing \(n) of \(total)…" }

    /// Every row is imported or skipped: a skip, a refusal, and a row a Cancel never reached all count
    /// as skipped.
    public static func receipt(imported: Int, rows: Int) -> String {
        "Imported \(imported) passwords. Skipped \(max(0, rows - imported))."
    }

    public static func trashQuestion(file: String) -> String {
        "Move \(file) to the Trash? It holds every password in plain text."
    }
}
