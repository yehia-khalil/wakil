import Foundation

/// 3d-iv: the pure rules for browser passwords kept in the Keychain — how an item is named, the org
/// check, the site a login belongs to, a strong password, and what a sent form is offered. No Security
/// framework here (that is `BrowserPasswordStore`), and no value ever reaches an error's text.
public struct BrowserLogin: Sendable, Equatable, Hashable {
    public let org: String
    public let site: String
    public let username: String
    public let modified: Date?

    public init(org: String, site: String, username: String, modified: Date?) {
        self.org = org
        self.site = site
        self.username = username
        self.modified = modified
    }
}

public enum BrowserPasswordOffer: Sendable, Equatable {
    case nothing, saveQuietly, askSave, askUpdate(username: String)
}

public enum BrowserPasswordError: Error, Sendable, Equatable, CustomStringConvertible {
    case badOrganisation(String)
    case badIdentity(String)
    case wrongOrganisation(expected: String)
    case noKeychainFile(String)
    case keychain(operation: String, status: Int32, message: String)
    case notFound(site: String, username: String, org: String)

    public var description: String {
        switch self {
        case .badOrganisation(let org): return "\"\(org)\" is not a usable organisation name."
        case .badIdentity(let id): return "\"\(id)\" is not a usable identity name."
        case .wrongOrganisation(let expected):
            return "A saved login did not belong to \(expected), so it was not used."
        case .noKeychainFile(let path): return "The keychain file \(path) does not exist."
        case .keychain(let operation, let status, let message):
            return "The Keychain refused to \(operation) (\(status)): \(message)"
        case .notFound(let site, let username, let org):
            let who = username.isEmpty ? "" : " for \(username)"
            return "\(site) has no saved password\(who) in \(org)."
        }
    }
}

public enum BrowserPasswords {
    public static let identity = "default"

    /// Go's `orgFileTokenPattern` (internal/wakilcore/paths.go). No `:`, so two orgs' names can't collide.
    static let tokenPattern = "^[A-Za-z0-9][A-Za-z0-9._-]*$"

    private static func isToken(_ s: String) -> Bool {
        s.range(of: tokenPattern, options: .regularExpression) != nil
    }

    public static func service(org: String, identity: String = identity) throws -> String {
        guard isToken(org) else { throw BrowserPasswordError.badOrganisation(org) }
        guard isToken(identity) else { throw BrowserPasswordError.badIdentity(identity) }
        return "wakil:\(org):browser-login:\(identity)"
    }

    /// A site key never holds a space; a username may, so the split is at the first one.
    public static func account(site: String, username: String) -> String { "\(site) \(username)" }

    public static func parseAccount(_ account: String) -> (site: String, username: String)? {
        guard let space = account.firstIndex(of: " ") else { return nil }
        let site = String(account[..<space])
        if site.isEmpty { return nil }
        return (site, String(account[account.index(after: space)...]))
    }

    /// Ruling 4: every item that comes back is checked again, never skipped quietly.
    public static func check(service: String, account: String, org: String, site: String?) throws {
        let wrong = BrowserPasswordError.wrongOrganisation(expected: org)
        guard let expected = try? self.service(org: org), service == expected else { throw wrong }
        guard let site else { return }
        guard let parsed = parseAccount(account), parsed.site == site else { throw wrong }
    }

    /// Ruling 5: the registrable domain, never a family. Nil off http and https.
    public static func siteKey(_ url: String) -> String? {
        guard let key = BrowserSite.key(url) else { return nil }
        let host = host(ofKey: key)
        return isLocal(host) ? key : BrowserSiteKey.registrableDomain(host)
    }

    /// Whether a password may be put in a page at `url`: https, or http on a local host (loopback,
    /// `localhost`, `*.localhost`, `*.test`, an IP literal — `siteKey`'s local rule). A site key drops
    /// the scheme, so without this a login saved on https would fill on the same site's http page.
    public static func fillsOn(_ url: String) -> Bool {
        guard let key = BrowserSite.key(url),
              let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "https" || isLocal(host(ofKey: key))
    }

    /// What a refusal names for the page at `url`: its site key, else a fixed phrase — never the
    /// address itself, which may be a `data:` page's content or a file's path, and reaches the journal.
    public static func siteLabel(_ url: String) -> String {
        siteKey(url) ?? (url.isEmpty ? "a blank tab" : "a page that is not a website")
    }

    /// `BrowserSite.key` without its port.
    private static func host(ofKey key: String) -> String {
        if key.hasPrefix("["), let end = key.firstIndex(of: "]") { return String(key[...end]) }
        if key.filter({ $0 == ":" }).count == 1, let colon = key.lastIndex(of: ":") { return String(key[..<colon]) }
        return key
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test") { return true }
        if host.hasPrefix("[") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && Int($0) != nil }
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// Four groups of five from `[A-Za-z0-9]` joined by `-`, with an upper case, a lower case and a digit.
    public static func strongPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return strongPassword(using: &generator)
    }

    public static func strongPassword<G: RandomNumberGenerator>(using generator: inout G) -> String {
        while true {
            let chars = (0..<20).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
            guard chars.contains(where: \.isUppercase), chars.contains(where: \.isLowercase),
                  chars.contains(where: \.isNumber) else { continue }
            return stride(from: 0, to: 20, by: 5).map { String(chars[$0..<$0 + 5]) }.joined(separator: "-")
        }
    }

    /// Ruling 7, in this order.
    public static func offer(password: String, username: String, site: String, savedUsernames: [String],
                             savedPassword: String?, never: Set<String>, suggested: String?)
        -> BrowserPasswordOffer {
        if password.isEmpty { return .nothing }
        if let suggested, !suggested.isEmpty, password == suggested { return .saveQuietly }
        if never.contains(site) { return .nothing }
        if savedUsernames.contains(username) {
            return savedPassword == password ? .nothing : .askUpdate(username: username)
        }
        if username.isEmpty, savedUsernames.count == 1, let only = savedUsernames.first {
            return savedPassword == password ? .nothing : .askUpdate(username: only)
        }
        return .askSave
    }

    /// The saved login whose password `offer` will compare, or nil when its answer needs none: an
    /// empty password, the suggested one, a never-saved site, or no matching login. A sent form reads
    /// the Keychain's value only for this one, so a page's submit can't make it ask for one otherwise.
    public static func savedPasswordToRead(password: String, username: String, site: String,
                                           savedUsernames: [String], never: Set<String>, suggested: String?)
        -> String? {
        if password.isEmpty { return nil }
        if let suggested, !suggested.isEmpty, password == suggested { return nil }
        if never.contains(site) { return nil }
        if savedUsernames.contains(username) { return username }
        if username.isEmpty, savedUsernames.count == 1 { return savedUsernames.first }
        return nil
    }

    public static func barQuestion(_ offer: BrowserPasswordOffer, username: String, site: String) -> String? {
        switch offer {
        case .nothing, .saveQuietly: return nil
        case .askSave:
            return username.isEmpty ? "Save the password on \(site)?"
                                    : "Save the password for \(username) on \(site)?"
        case .askUpdate(let saved):
            return "Update the password for \(saved) on \(site)?"
        }
    }
}
