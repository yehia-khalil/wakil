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

/// The copy of the clear-data question (global constraints), for the view that asks it.
public enum BrowserClearDataQuestion {
    public static func text(org: String) -> String {
        "Delete \(org)'s browsing data? Every site signs you out, in every project."
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
/// - `tabs/`: per-tab state, `tabs/<tab-id>.state`.
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
    private var tabsDirectory: URL { directory.appendingPathComponent("tabs", isDirectory: true) }

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

    /// The remembered zoom for `host`; 1.0 when none, or when the file cannot be read.
    public func zoom(host: String) -> Double { zooms()[host] ?? 1.0 }

    public func setZoom(_ factor: Double, host: String) throws {
        var all = zooms()
        all[host] = factor
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: zoomURL, options: .atomic)
    }

    /// Where tab `tab`'s state is kept (`tabs/<tab-id>.state`); the id is encoded, so it stays a name.
    public func stateURL(tab: String) -> URL {
        let name = tab.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "tab"
        return tabsDirectory.appendingPathComponent("\(name).state")
    }

    public func removeState(tab: String) {
        try? FileManager.default.removeItem(at: stateURL(tab: tab))
    }

    /// Deletes `tabs/` and `zoom.json`; `profile.json` stays, so the organisation keeps its id.
    func removeEverythingButTheProfile() throws {
        for url in [tabsDirectory, zoomURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
