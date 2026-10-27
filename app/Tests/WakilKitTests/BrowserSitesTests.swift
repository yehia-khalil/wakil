import Testing
@testable import WakilKit

/// Which site a page is, the tag it wears, and what an act there costs (3c-ii, ruling 1).

private func tree(_ projects: [SettingsProject]) -> SettingsTree {
    SettingsTree(org: SettingsOrg(id: "initech"), projects: projects)
}

private func env(_ name: String, _ urls: [String], production: Bool? = nil) -> SettingsEnvironment {
    SettingsEnvironment(name: name, api: urls.map { SettingsAPI(baseUrl: $0) }, production: production)
}

@Test(arguments: [
    ("https://staging.initech.dev/docs", "staging.initech.dev" as String?),
    ("https://API.Initech.com:443/x", "api.initech.com"),
    ("http://localhost:3000", "localhost:3000"),
    ("http://127.0.0.1:80/", "127.0.0.1"),
    ("http://[::1]:8080", "[::1]:8080"),
    ("file:///tmp/a.html", nil),
    ("about:blank", nil),
    ("https://www.example.com", "www.example.com"),
])
func aSiteIsTheHostAndAnyNonDefaultPort(_ url: String, _ key: String?) {
    #expect(BrowserSite.key(url) == key)
}

@Test func aLabelFallsBackToTheDisplayHost() {
    #expect(BrowserSite.label("https://staging.initech.dev/docs") == "staging.initech.dev")
    #expect(BrowserSite.label("about:blank") == "about:blank")
}

@Test func productionComesFromEveryProjectsFlaggedEnvironments() {
    let a = SettingsProject(name: "a", environments: [env("staging", ["https://staging.initech.dev"])])
    let b = SettingsProject(name: "b", environments: [env("live", ["https://api.initech.com"], production: true)])
    let sites = BrowserSites.from(tree: tree([a, b]), project: "a", environment: "staging")
    #expect(sites.read)
    #expect(sites.isProduction("api.initech.com"))
    #expect(!sites.isProduction("staging.initech.dev"))
}

@Test func aMissingFlagFallsBackToTheName() {
    let p = SettingsProject(name: "a", environments: [
        env("production", ["https://initech.com"]),
        env("prod", ["https://prod.initech.com"]),
    ])
    let sites = BrowserSites.from(tree: tree([p]), project: "a", environment: "production")
    #expect(sites.isProduction("initech.com"))
    #expect(!sites.isProduction("prod.initech.com"))
}

@Test func theEnvironmentTagIsTheActiveEnvironmentsOnly() {
    let p = SettingsProject(name: "a", environments: [
        env("staging", ["https://staging.initech.dev"]), env("qa", ["https://qa.initech.dev"]),
    ])
    let staging = BrowserSites.from(tree: tree([p]), project: "a", environment: "staging")
    #expect(staging.tag("https://staging.initech.dev/x") == .environment("staging"))
    let qa = BrowserSites.from(tree: tree([p]), project: "a", environment: "qa")
    #expect(qa.tag("https://staging.initech.dev/x") == nil)
    #expect(qa.tag("https://qa.initech.dev/") == .environment("qa"))
}

@Test func productionWinsOverTheEnvironmentTag() {
    let p = SettingsProject(name: "a", environments: [env("live", ["https://api.initech.com"], production: true)])
    let sites = BrowserSites.from(tree: tree([p]), project: "a", environment: "live")
    #expect(sites.tag("https://api.initech.com/x") == .production)
}

@Test func wwwIsForgivenForProductionNotForConsent() {
    let p = SettingsProject(name: "a", environments: [env("production", ["https://initech.com"])])
    let sites = BrowserSites.from(tree: tree([p]), project: "a", environment: "production")
    #expect(sites.isProduction("www.initech.com"))
    #expect(sites.tag("https://www.initech.com/") == .production)
    let plain = BrowserSites(environment: [:], production: [], read: true)
    #expect(browserActPrice(site: "www.initech.dev", sites: plain, allowed: ["initech.dev"], origin: .agent) == .gate)
}

@Test func anUnreadOrganisationTreatsEverySiteAsProduction() {
    #expect(BrowserSites.unread.isProduction("example.com"))
    #expect(BrowserSites.unread.tag("https://example.com") == nil)
}

@Test func thePriceTable() {
    let prod = BrowserSites(environment: [:], production: ["initech.com"], read: true)
    for origin in [ActionOrigin.agent, .ui] {
        #expect(browserActPrice(site: "initech.com", sites: prod, allowed: ["initech.com"], origin: origin) == .gate)
        #expect(browserActPrice(site: "initech.com", sites: prod, allowed: [], origin: origin) == .gate)
    }
    #expect(browserActPrice(site: "a.dev", sites: prod, allowed: ["a.dev"], origin: .agent) == .allow)
    #expect(browserActPrice(site: "a.dev", sites: prod, allowed: [], origin: .agent) == .gate)
    #expect(browserActPrice(site: "a.dev", sites: prod, allowed: [], origin: .ui) == .allow)
    #expect(browserActPrice(site: "a.dev", sites: prod, allowed: [], origin: .debug) == .allow)
}
