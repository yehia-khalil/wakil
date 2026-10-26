import Foundation

/// 3c-ii: which site a page is, the tag it wears, and what an act there costs. Pure rules; the
/// per-conversation allow-list lives in the pane store, not here.
public enum BrowserSite {
    /// The host (lowercased, no trailing dot, IPv6 bracketed) plus any non-default port; nil off
    /// http and https. `www.` is kept: consent is per exact host.
    public static func key(_ url: String) -> String? {
        guard let parts = URLComponents(string: url),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return nil }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        if let port = parts.port, port != (scheme == "https" ? 443 : 80) { return "\(host):\(port)" }
        return host
    }

    /// The key, else what the address row shows.
    public static func label(_ url: String) -> String {
        if let key = key(url) { return key }
        if let parsed = URL(string: url) { return BrowserAddress.displayHost(parsed) }
        return url
    }

    static func dropWWW(_ site: String) -> String {
        site.hasPrefix("www.") ? String(site.dropFirst(4)) : site
    }
}

public enum BrowserSiteTag: Sendable, Equatable { case environment(String), production }

public struct BrowserSites: Sendable, Equatable {
    /// site (www. dropped) → the active environment's name
    public var environment: [String: String]
    /// sites (www. dropped) of every project's production environments
    public var production: Set<String>
    /// false: never read; every site counts as production
    public var read: Bool

    public init(environment: [String: String], production: Set<String>, read: Bool) {
        self.environment = environment
        self.production = production
        self.read = read
    }

    public static let unread = BrowserSites(environment: [:], production: [], read: false)

    public static func from(tree: SettingsTree, project: String, environment active: String) -> BrowserSites {
        var tags: [String: String] = [:]
        var production: Set<String> = []
        for candidate in tree.projects {
            for env in candidate.environments {
                let isProd = isProductionEnvironment(env.name, declared: env.production)
                let isActive = candidate.name == project
                    && foldEnvironmentName(env.name) == foldEnvironmentName(active)
                for api in env.api {
                    guard let key = BrowserSite.key(api.baseUrl) else { continue }
                    let site = BrowserSite.dropWWW(key)
                    if isProd { production.insert(site) }
                    if isActive { tags[site] = env.name }
                }
            }
        }
        return BrowserSites(environment: tags, production: production, read: true)
    }

    public func isProduction(_ site: String) -> Bool {
        guard read else { return true }
        return production.contains(BrowserSite.dropWWW(site.lowercased()))
    }

    public func tag(_ url: String) -> BrowserSiteTag? {
        guard read, let key = BrowserSite.key(url) else { return nil }
        if isProduction(key) { return .production }
        return environment[BrowserSite.dropWWW(key)].map(BrowserSiteTag.environment)
    }
}

/// Production is always gated. Elsewhere only the agent is, and only on a site not yet allowed
/// for the conversation (exact host: `www.` is not forgiven here).
public func browserActPrice(site: String, sites: BrowserSites, allowed: Set<String>,
                            origin: ActionOrigin) -> GateDecision {
    if sites.isProduction(site) { return .gate }
    if allowed.contains(site) { return .allow }
    return origin == .agent ? .gate : .allow
}
