import Foundation

/// 3d-i: which site a page belongs to, for grouping tabs. Ruling 6: a family, else a local
/// address as `host:port`, else the registrable domain from the bundled public-suffix snapshot.
public enum BrowserSiteKey {
    private struct Family { let id: String; let name: String; let hosts: [String] }

    private static let families: [Family] = [
        Family(id: "family:youtube", name: "YouTube", hosts: ["youtube.com", "youtu.be"]),
        Family(id: "family:atlassian", name: "Atlassian", hosts: ["atlassian.net", "atlassian.com"]),
        Family(id: "family:github", name: "GitHub", hosts: ["github.com", "githubusercontent.com"]),
        Family(id: "family:google-docs", name: "Google Docs",
               hosts: ["docs.google.com", "drive.google.com", "sheets.google.com", "slides.google.com"]),
    ]

    private struct Rules { var plain = Set<String>(), wildcard = Set<String>(), exception = Set<String>() }

    /// Parsed once, never per call.
    private static let rules: Rules = {
        var parsed = Rules()
        for line in browserPublicSuffixRules.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces).lowercased()
            if rule.isEmpty { continue }
            if rule.hasPrefix("!") { parsed.exception.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { parsed.wildcard.insert(String(rule.dropFirst(2))) }
            else { parsed.plain.insert(rule) }
        }
        return parsed
    }()

    /// nil off http and https.
    public static func of(_ url: String) -> String? {
        guard let site = BrowserSite.key(url) else { return nil }
        let host = hostOf(site)
        if let family = families.first(where: { $0.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }) {
            return family.id
        }
        if isLocal(host) { return site }
        return registrableDomain(host)
    }

    /// A family's name, else the key's first label capitalised, else the key itself for `host:port`.
    public static func name(_ key: String) -> String {
        if let family = families.first(where: { $0.id == key }) { return family.name }
        if isLocal(hostOf(key)) { return key }
        guard let label = key.split(separator: ".").first, let first = label.first else { return key }
        return first.uppercased() + label.dropFirst()
    }

    /// The registrable domain of a host; a host that is itself a suffix, or one label, is its own.
    public static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let n = labels.count
        if n < 2 { return host }
        func joined(_ i: Int) -> String { labels[i...].joined(separator: ".") }
        // An exception rule beats every other: its suffix is itself minus the first label.
        for i in 0..<(n - 1) where rules.exception.contains(joined(i)) { return joined(i) }
        // Otherwise the longest matching rule is the leftmost; the default rule is `*`.
        for i in 0..<n {
            let candidate = joined(i)
            let parent = i + 1 < n ? joined(i + 1) : nil
            if rules.plain.contains(candidate) || parent.map({ rules.wildcard.contains($0) }) == true {
                return i == 0 ? host : joined(i - 1)
            }
        }
        return joined(n - 2)
    }

    private static func hostOf(_ site: String) -> String {
        if site.hasPrefix("["), let end = site.firstIndex(of: "]") { return String(site[...end]) }
        if let colon = site.lastIndex(of: ":"), site.filter({ $0 == ":" }).count == 1 {
            return String(site[..<colon])
        }
        return site
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test") { return true }
        if host.hasPrefix("[") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && Int($0) != nil }
    }
}
