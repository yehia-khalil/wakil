import CryptoKit
import Foundation

/// Why an organisation's browser files cannot be addressed.
public enum BrowserOrgFilesError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The organisation is not a single directory name (`/`, `.`, `..` or empty): Go's `OrgDirFor`
    /// refuses the same, and flattening it would let two organisations share one profile.
    case badOrganisation(String)

    public var description: String {
        switch self {
        case .badOrganisation(let org): "\"\(org)\" is not a usable organisation name."
        }
    }
}

/// A bookmark: matched by its exact URL string; `bookmarks.json` keeps them in the order they were added.
public struct BrowserBookmark: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var added: Date
    public init(url: String, title: String, added: Date) {
        self.url = url; self.title = title; self.added = added
    }
}

/// `bookmarks.json` exists but cannot be read; it is never written over (Ruling 4).
public struct BrowserBookmarksUnreadable: Error, Sendable, Equatable {
    public let reason: String
}

/// The copy of the clear-data question (global constraints), for the view that asks it.
public enum BrowserClearDataQuestion {
    public static func text(org: String) -> String {
        "Delete \(org)'s browsing data? Every site signs you out, in every project, and its history is deleted. Bookmarks stay."
    }
    /// The receipt after Delete: the organisation the question named (`asked`), else the current one.
    public static func receipt(asked: String?, current: String) -> String {
        "Deleted \(asked ?? current)'s browsing data."
    }
    public static let keepLabel = "Keep it"
    public static let deleteLabel = "Delete"
}

/// One organisation's browser files, `~/.wakil/orgs/<org>/browser/` (Invariant 4: an organisation
/// is a credential boundary, so its logins live in a web-view store no other organisation is given).
///
/// - `profile.json`: `{"identifier":"<UUID>"}`, the id of the organisation's
///   `WKWebsiteDataStore(forIdentifier:)`. WebKit keeps the store itself under `~/Library/WebKit/`,
///   outside Wakil's reach; this id is the only handle on it.
/// - `zoom.json`: `{"<host>": <factor>}`, the page zoom per host.
/// - `history.sqlite` (with `-wal`, `-shm`): the browsing history, 90 days (`BrowserHistory`).
/// - `bookmarks.json`: the bookmarks; clearing browsing data keeps them.
/// - `tabs/`: per-tab state, `tabs/<tab-id>.state`.
/// - `pins/`: each project's pins, `pins/<project>.json` (3d-i, ruling 13); clearing browsing data keeps them.
public struct BrowserOrgFiles: Sendable, Equatable {
    public let home: URL
    public let org: String

    /// Refuses an organisation that is not one directory name, never flattening it.
    public init(home: URL, org: String) throws {
        guard !org.isEmpty, org != ".", org != "..", !org.contains("/") else {
            throw BrowserOrgFilesError.badOrganisation(org)
        }
        self.home = home
        self.org = org
    }

    /// `<home>/.wakil/orgs/<org>/browser`.
    public var directory: URL {
        home.appendingPathComponent(".wakil", isDirectory: true)
            .appendingPathComponent("orgs", isDirectory: true)
            .appendingPathComponent(org, isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
    }

    private var profileURL: URL { directory.appendingPathComponent("profile.json") }
    private var zoomURL: URL { directory.appendingPathComponent("zoom.json") }
    private var bookmarksURL: URL { directory.appendingPathComponent("bookmarks.json") }
    private var historyURL: URL { directory.appendingPathComponent("history.sqlite") }
    private var tabsDirectory: URL { directory.appendingPathComponent("tabs", isDirectory: true) }
    private var pinsDirectory: URL { directory.appendingPathComponent("pins", isDirectory: true) }

    /// `pins/<project>.json`, the project's registry key encoded (`encoded`'s rule), so a key with a
    /// slash is one file name.
    public func pinsURL(project: String) -> URL {
        pinsDirectory.appendingPathComponent("\(Self.encoded(project)).json")
    }

    /// The file name `pinsURL(project:)` uses, `pins/<encoded project>.json`, as refusals name it.
    public static func pinsName(project: String) -> String { "pins/\(encoded(project)).json" }

    /// The organisation's history, at `history.sqlite`.
    public var history: BrowserHistory { BrowserHistory(url: historyURL) }

    private struct Profile: Codable { var identifier: UUID }

    /// The organisation's store id. Created on first use. A `profile.json` that does not parse is
    /// replaced with a new id: the old store is unreachable without its id, so starting fresh is
    /// the only outcome. Any other read failure (permissions, say) is thrown and the file is left
    /// alone: overwriting a readable-later id would orphan the organisation's logins.
    public func identifier() throws -> UUID {
        do {
            let data = try Data(contentsOf: profileURL)
            if let profile = try? JSONDecoder().decode(Profile.self, from: data) { return profile.identifier }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // missing: created below
        }
        let profile = Profile(identifier: UUID())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: profileURL, options: .atomic)
        return profile.identifier
    }

    private func zooms() -> [String: Double] {
        guard let data = try? Data(contentsOf: zoomURL),
              let zooms = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return zooms
    }

    /// The host a page's zoom is kept under: the URL's host, lowercased; nil for a page with none
    /// (`about:blank`, a `data:` page), whose zoom is not kept. `browser_zoom` writes under it and
    /// the web view reads under it.
    public static func zoomHost(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// The remembered zoom for `host`; 1.0 when none, or when the file cannot be read.
    public func zoom(host: String) -> Double { zooms()[host] ?? 1.0 }

    public func setZoom(_ factor: Double, host: String) throws {
        var all = zooms()
        all[host] = factor
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: zoomURL, options: .atomic)
    }

    /// The bookmarks in the order they were added; `[]` when the file is missing. A file that is
    /// there but cannot be read or parsed throws `BrowserBookmarksUnreadable`.
    public func bookmarks() throws -> [BrowserBookmark] {
        let data: Data
        do {
            data = try Data(contentsOf: bookmarksURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw BrowserBookmarksUnreadable(reason: error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode([BrowserBookmark].self, from: data) }
        catch { throw BrowserBookmarksUnreadable(reason: error.localizedDescription) }
    }

    /// Adds (`on` true), removes (`on` false) or toggles (`on` nil) the bookmark for `url`; the
    /// result is whether it is bookmarked afterwards. Nothing is written when nothing changes.
    @discardableResult
    public func setBookmark(url: String, title: String, on: Bool?, now: Date) throws -> Bool {
        var all = try bookmarks()
        let exists = all.contains { $0.url == url }
        let wanted = on ?? !exists
        guard wanted != exists else { return exists }
        if wanted { all.append(BrowserBookmark(url: url, title: title, added: now)) }
        else { all.removeAll { $0.url == url } }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(all).write(to: bookmarksURL, options: .atomic)
        return wanted
    }

    /// The project's pins in the file's order; `[]` when the file is missing. A file that is there but
    /// cannot be read or parsed throws `BrowserPinsUnreadable`.
    public func pins(project: String) throws -> [BrowserPin] {
        let data: Data
        do {
            data = try Data(contentsOf: pinsURL(project: project))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw BrowserPinsUnreadable(reason: error.localizedDescription)
        }
        do { return try JSONDecoder().decode(BrowserPinsFile.self, from: data).items }
        catch { throw BrowserPinsUnreadable(reason: error.localizedDescription) }
    }

    /// Writes the project's pins whole and atomically, making `pins/` on first write. Refuses, writing
    /// nothing, when the file there cannot be read (ruling 13: never written over).
    public func setPins(_ pins: [BrowserPin], project: String) throws {
        _ = try self.pins(project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: pinsDirectory, withIntermediateDirectories: true)
        try encoder.encode(BrowserPinsFile(items: pins)).write(to: pinsURL(project: project), options: .atomic)
    }

    /// The name a tab's state is kept under (`stateURL(tab:)`): `<scopeKey>.<pane>.<tab>`. Pane and
    /// tab ids repeat from place to place, and one organisation's directory holds every project's,
    /// so the place is in the name. `scopeKey` is a stable digest of the project, environment and
    /// conversation (the organisation is the directory already): the same place always names the
    /// same file, across launches, and the name stays short whatever the project key is.
    public static func stateKey(scope: LayoutScope, pane: String, tab: String) -> String {
        "\(placeDigest(scope)).\(pane).\(tab)"
    }

    private static func placeDigest(_ scope: LayoutScope) -> String {
        let place = [scope.project, scope.environment, scope.lineageRoot ?? ""].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(place.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func encoded(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "tab"
    }

    /// Where tab `tab`'s state is kept (`tabs/<tab-id>.state`); the id is encoded, so it stays a name.
    public func stateURL(tab: String) -> URL {
        tabsDirectory.appendingPathComponent("\(Self.encoded(tab)).state")
    }

    /// The state files whose (encoded) name starts with `prefix`, an encoded `stateKey` head.
    private func stateFiles(prefixed prefix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tabsDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".state") }
            .map { tabsDirectory.appendingPathComponent($0) }
    }

    /// A place took a new name — a conversation adopted its canvas, or its project or environment
    /// was renamed: every tab state kept under the old place's name moves to the new one, so the
    /// tab's page comes back with its ‹ › history. Best effort: a file that cannot move stays.
    public func moveStates(from old: LayoutScope, to new: LayoutScope) {
        let from = Self.encoded("\(Self.placeDigest(old)).")
        let to = Self.encoded("\(Self.placeDigest(new)).")
        guard from != to else { return }
        for url in stateFiles(prefixed: from) {
            let target = tabsDirectory.appendingPathComponent(to + url.lastPathComponent.dropFirst(from.count))
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: url, to: target)
        }
    }

    /// A closed pane: every one of its tabs' states, the ones never shown this launch too, so a
    /// later pane given the same id never inherits a page.
    public func removeStates(scope: LayoutScope, pane: String) {
        for url in stateFiles(prefixed: Self.encoded("\(Self.placeDigest(scope)).\(pane).")) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func removeState(tab: String) {
        try? FileManager.default.removeItem(at: stateURL(tab: tab))
    }

    /// Deletes `tabs/`, `zoom.json` and the history (`history.sqlite`, `-wal`, `-shm`); `profile.json`
    /// stays, so the organisation keeps its id, and `bookmarks.json` and `pins/` stay, as Safari's Clear
    /// History keeps bookmarks.
    func removeEverythingButTheProfile() throws {
        // -wal and -shm go before the database: a writer opening between the removals could otherwise replay a stale WAL.
        let historyFiles = ["-wal", "-shm", ""].map { URL(fileURLWithPath: historyURL.path + $0) }
        for url in [tabsDirectory, zoomURL] + historyFiles where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
