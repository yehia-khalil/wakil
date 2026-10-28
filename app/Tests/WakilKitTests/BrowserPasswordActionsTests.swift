import Foundation
import Testing
@testable import WakilKit

// 3d-iv Task 6: the five operator-only password actions, the scrub, and the page seam. Every store here
// is on a `TemporaryKeychain` made and removed by the test itself; nothing touches the login keychain.

private let paneId = "p1"
private let tabId = "t1"

/// The page seam, recording what it was asked. It keeps the values only to check them here.
private actor RecordingPasswordPage: BrowserPasswordPage {
    struct Fill: Equatable { var pane, tab, org, site, username, password: String }
    struct Suggestion: Equatable { var pane, tab, org, site, password: String }
    private(set) var fills: [Fill] = []
    private(set) var suggestions: [Suggestion] = []
    private var failure: BrowserPasswordPageError?

    func fail(with error: BrowserPasswordPageError?) { failure = error }

    func fill(pane: String, tab: String, org: String, site: String, username: String, password: String) async throws {
        if let failure { throw failure }
        fills.append(Fill(pane: pane, tab: tab, org: org, site: site, username: username, password: password))
    }

    func suggest(pane: String, tab: String, org: String, site: String, password: String) async throws {
        if let failure { throw failure }
        suggestions.append(Suggestion(pane: pane, tab: tab, org: org, site: site, password: password))
    }
}

private actor ActiveOrg {
    private var org = "initech"
    func set(_ new: String) { org = new }
    func get() -> String { org }
}

/// A page driver that answers one fixed page, so the decorator's scrub can be read.
private struct FixedPageDriver: BrowserPageDriver {
    var page: BrowserPageRead
    func read(scope: LayoutScope?, pane: String, tab: String, firstRef: Int) async throws -> BrowserPageRead { page }
    func describe(scope: LayoutScope?, pane: String, tab: String, ref: String) async throws -> BrowserElement {
        guard let e = page.elements.first(where: { $0.ref == ref }) else { throw BrowserPageDriverError.stale }
        return e
    }
    func act(scope: LayoutScope?, pane: String, tab: String, _ act: BrowserPageAct) async throws -> BrowserActResult {
        BrowserActResult(url: page.url, title: page.title, loading: false, navigated: false)
    }
}

private struct Fixture {
    let registry: ActionRegistry
    let panes: PaneStore
    let store: BrowserPasswordStore
    let scrub: BrowserPasswordScrub
    let page: RecordingPasswordPage
    let org: ActiveOrg
    let home: URL
    let journal: URL

    @discardableResult
    func dispatch(_ name: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await registry.dispatch(name: name, params: .object(params), origin: .ui,
                                    caller: .test("dev"), confirmation: nil)
    }

    func moveTab(to url: String) async {
        await panes.updateBrowser(paneId: paneId, create: true) { s in s.tabs[0].url = url }
    }
}

private func withFixture(url: String = "https://example.com/login",
                         _ body: (Fixture) async throws -> Void) async throws {
    let keychain = try TemporaryKeychain()
    defer { keychain.remove() }
    let store = BrowserPasswordStore(keychainFile: keychain.path)
    // The store is the test's own before anything is written through it.
    try #require(store.keychainFile == keychain.path)

    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let home = dir.appendingPathComponent("home")
    let journal = dir.appendingPathComponent("journal")
    for org in ["initech", "umbrella"] {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".wakil/orgs/\(org)"), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)

    let registry = ActionRegistry(journalDirectory: journal, sessionId: "passwords")
    let panes = PaneStore(kinds: PaneKinds.standard)
    let scrub = BrowserPasswordScrub()
    let page = RecordingPasswordPage()
    let org = ActiveOrg()
    await registerBrowserPasswordActions(into: registry, panes: panes, store: store, scrub: scrub, page: page,
                                         home: home, activeOrg: { await org.get() })
    await panes.updateBrowser(paneId: paneId, create: true) { s in
        s.tabs = [BrowserTab(id: tabId, url: url, title: "Log in", loaded: true)]
        s.active = tabId
        s.nextTab = 2
    }
    try await body(Fixture(registry: registry, panes: panes, store: store, scrub: scrub, page: page,
                           org: org, home: home, journal: journal))
}

private func refusal(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch { return String(describing: error) }
}

private func reply(org: String, site: String, username: String, outcome: String) -> JSONValue {
    .object(["org": .string(org), "site": .string(site), "username": .string(username), "outcome": .string(outcome)])
}

private func text(_ value: JSONValue) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func fill(_ username: String, site: String = "example.com") -> [String: JSONValue] {
    ["pane": .string(paneId), "tab": .string(tabId), "site": .string(site), "username": .string(username)]
}

// MARK: - Fill

@Test func fillReadsTheActiveOrganisationsLoginOnly() async throws {
    try await withFixture { f in
        try f.store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
        try f.store.save(org: "umbrella", site: "example.com", username: "ann", password: "walk-test-pass-2")

        let answer = try await f.dispatch("browser_password_fill", fill("ann"))
        #expect(answer == reply(org: "initech", site: "example.com", username: "ann", outcome: "filled"))
        #expect(await f.page.fills == [.init(pane: paneId, tab: tabId, org: "initech", site: "example.com",
                                             username: "ann", password: "walk-test-pass-1")])

        await f.org.set("umbrella")
        try await f.dispatch("browser_password_fill", fill("ann"))
        #expect(await f.page.fills.last?.org == "umbrella")
        #expect(await f.page.fills.last?.password == "walk-test-pass-2")
    }
}

@Test func fillRefusesWhenTheTabHasMovedToAnotherSite() async throws {
    try await withFixture(url: "https://example.org/") { f in
        try f.store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
        let why = await refusal { try await f.dispatch("browser_password_fill", fill("ann")) }
        #expect(why == "browser_password_fill: the tab is on example.org now, so the password for example.com was not filled.")
        #expect(await f.page.fills.isEmpty)
        // Refused before the Keychain was read: nothing is remembered.
        let read = await f.scrub.scrub(BrowserPageRead(url: "", title: "", text: "walk-test-pass-1", elements: []))
        #expect(read.text == "walk-test-pass-1")

        // The page's own check, after the action's: a redirect between the two says the same.
        await f.moveTab(to: "https://example.com/login")
        await f.page.fail(with: .siteChanged(now: "example.net"))
        let late = await refusal { try await f.dispatch("browser_password_fill", fill("ann")) }
        #expect(late == "browser_password_fill: the tab is on example.net now, so the password for example.com was not filled.")
        #expect(await f.page.fills.isEmpty)
    }
}

@Test func anInsecurePageIsNeitherFilledNorSuggested() async throws {
    try await withFixture(url: "http://example.com/login") { f in
        try f.store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
        let why = await refusal { try await f.dispatch("browser_password_fill", fill("ann")) }
        #expect(why == "browser_password_fill: example.com is not a secure page (http), so the password was not filled.")
        #expect(await f.page.fills.isEmpty)
        // Refused before the Keychain was read: nothing is remembered.
        let read = await f.scrub.scrub(BrowserPageRead(url: "", title: "", text: "walk-test-pass-1", elements: []))
        #expect(read.text == "walk-test-pass-1")

        let suggest = await refusal {
            try await f.dispatch("browser_password_suggest", ["pane": .string(paneId), "tab": .string(tabId)])
        }
        #expect(suggest == "browser_password_suggest: example.com is not a secure page (http), so no password was suggested.")
        #expect(await f.page.suggestions.isEmpty)
    }
    // A local page on http is the operator's own server: it fills.
    try await withFixture(url: "http://127.0.0.1:8123/login.html") { f in
        try f.store.save(org: "initech", site: "127.0.0.1:8123", username: "ann", password: "walk-test-pass-1")
        try await f.dispatch("browser_password_fill", fill("ann", site: "127.0.0.1:8123"))
        #expect(await f.page.fills.count == 1)
    }
}

@Test func aMovedRefusalNamesNoAddress() async throws {
    try await withFixture(url: "data:text/html,secret-page") { f in
        let why = await refusal { try await f.dispatch("browser_password_fill", fill("ann")) }
        #expect(why == "browser_password_fill: the tab is on a page that is not a website now, so the password for example.com was not filled.")
    }
}

@Test func fillRefusesAMissingLoginNamingTheOrg() async throws {
    try await withFixture { f in
        // Only another organisation has it.
        try f.store.save(org: "umbrella", site: "example.com", username: "ann", password: "walk-test-pass-1")
        let why = await refusal { try await f.dispatch("browser_password_fill", fill("ann")) }
        #expect(why == "browser_password_fill: example.com has no saved password for ann in initech.")
        #expect(await f.page.fills.isEmpty)
    }
}

// MARK: - Suggest

@Test func suggestFillsAStrongPasswordAndRepliesWithoutIt() async throws {
    try await withFixture { f in
        let answer = try await f.dispatch("browser_password_suggest", ["pane": .string(paneId), "tab": .string(tabId)])
        #expect(answer == reply(org: "initech", site: "example.com", username: "", outcome: "suggested"))
        let suggestions = await f.page.suggestions
        #expect(suggestions.count == 1)
        let suggested = try #require(suggestions.first)
        #expect(suggested.org == "initech" && suggested.site == "example.com")
        #expect(suggested.pane == paneId && suggested.tab == tabId)
        #expect(suggested.password.range(of: "^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){3}$", options: .regularExpression) != nil)
        #expect(!(try text(answer)).contains(suggested.password))
        let read = await f.scrub.scrub(BrowserPageRead(url: "", title: "", text: "new: \(suggested.password)", elements: []))
        #expect(read.text == "new: ••••••••")
    }
}

// MARK: - Save, delete, never

@Test func saveAddsUpdatesAndRenames() async throws {
    try await withFixture { f in
        func save(_ params: [String: JSONValue]) async throws -> JSONValue {
            var p = params
            p["org"] = .string("initech"); p["site"] = .string("example.com")
            return try await f.dispatch("browser_password_save", p)
        }
        #expect(try await save(["username": .string("ann"), "password": .string("walk-test-pass-1")])
                == reply(org: "initech", site: "example.com", username: "ann", outcome: "added"))
        #expect(try await save(["username": .string("ann"), "password": .string("walk-test-pass-1")])
                == reply(org: "initech", site: "example.com", username: "ann", outcome: "unchanged"))
        #expect(try await save(["username": .string("ann"), "password": .string("walk-test-pass-2")])
                == reply(org: "initech", site: "example.com", username: "ann", outcome: "updated"))
        #expect(try f.store.password(org: "initech", site: "example.com", username: "ann") == "walk-test-pass-2")

        // A rename with no password keeps the value; the old item goes.
        #expect(try await save(["username": .string("ann b"), "previousUsername": .string("ann")])
                == reply(org: "initech", site: "example.com", username: "ann b", outcome: "renamed"))
        #expect(try f.store.logins(org: "initech", site: nil).map(\.username) == ["ann b"])
        #expect(try f.store.password(org: "initech", site: "example.com", username: "ann b") == "walk-test-pass-2")

        // A rename with a password moves and changes it.
        try await save(["username": .string("cy"), "previousUsername": .string("ann b"),
                        "password": .string("walk-test-pass-3")])
        #expect(try f.store.logins(org: "initech", site: nil).map(\.username) == ["cy"])
        #expect(try f.store.password(org: "initech", site: "example.com", username: "cy") == "walk-test-pass-3")

        // Saved from a page's bar: that page's reads hide it from now on.
        try await save(["username": .string("dee"), "password": .string("walk-test-pass-4"),
                        "pane": .string(paneId), "tab": .string(tabId)])
        let read = await f.scrub.scrub(BrowserPageRead(url: "", title: "", text: "walk-test-pass-4", elements: []))
        #expect(read.text == "••••••••")
        // From Settings (no pane): nothing in a page, nothing to remember.
        let settings = await f.scrub.scrub(BrowserPageRead(url: "", title: "", text: "walk-test-pass-3", elements: []))
        #expect(settings.text == "walk-test-pass-3")
    }
}

@Test func saveRefusesAnUnknownOrganisation() async throws {
    try await withFixture { f in
        for org in ["globex", "a:b", ".."] {
            let why = await refusal {
                try await f.dispatch("browser_password_save", ["org": .string(org), "site": .string("example.com"),
                                                               "username": .string("ann"),
                                                               "password": .string("walk-test-pass-1")])
            }
            #expect(why == "browser_password_save: \"\(org)\" is not an organisation on this Mac.")
        }
        let globex = try f.store.logins(org: "globex", site: nil)
        #expect(globex.isEmpty)
    }
}

@Test func deleteAndNeverWork() async throws {
    try await withFixture { f in
        try f.store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
        try f.store.save(org: "initech", site: "example.com", username: "bob", password: "walk-test-pass-1")
        let deleted = try await f.dispatch("browser_password_delete", ["org": .string("initech"),
                                                                       "site": .string("example.com"),
                                                                       "username": .string("ann")])
        #expect(deleted == reply(org: "initech", site: "example.com", username: "ann", outcome: "deleted"))
        #expect(try f.store.logins(org: "initech", site: nil).map(\.username) == ["bob"])

        let files = try BrowserOrgFiles(home: f.home, org: "initech")
        let never = try await f.dispatch("browser_password_never", ["org": .string("initech"),
                                                                    "site": .string("example.com"), "on": .bool(true)])
        #expect(never == reply(org: "initech", site: "example.com", username: "", outcome: "never"))
        #expect(try files.neverSave() == ["example.com"])
        let offered = try await f.dispatch("browser_password_never", ["org": .string("initech"),
                                                                      "site": .string("example.com"), "on": .bool(false)])
        #expect(offered == reply(org: "initech", site: "example.com", username: "", outcome: "offered"))
        #expect(try files.neverSave() == [])

        // An organisation that isn't on this Mac gets no folder made for it.
        let why = await refusal {
            try await f.dispatch("browser_password_never", ["org": .string("globex"), "site": .string("example.com"),
                                                            "on": .bool(true)])
        }
        #expect(why == "browser_password_never: \"globex\" is not an organisation on this Mac.")
        #expect(!FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".wakil/orgs/globex").path))
    }
}

// MARK: - The agent

private let passwordActions = ["browser_password_delete", "browser_password_fill", "browser_password_never",
                               "browser_password_save", "browser_password_suggest"]

@Test func everyPasswordActionIsOperatorOnly() async throws {
    try await withFixture { f in
        let all = await f.registry.all()
        let mine = all.filter { $0.name.hasPrefix("browser_password_") }
        #expect(mine.map(\.name).sorted() == passwordActions)
        for d in mine {
            #expect(d.kind == .control, "\(d.name)")
            #expect(d.audience == .operatorOnly, "\(d.name)")
            #expect(operatorOnlyActions.contains(d.name), "\(d.name)")
            let tool = "mcp__wakil__\(d.name)"
            #expect(permissionDecision(toolName: tool, knownActions: all.map(\.name)) == .deny(
                "\(tool): only the operator fills, saves or deletes a saved password, by pressing the key in a field "
                    + "or in Settings → Browser → Passwords. You never see a password and never fill one."))
        }
        let allowed = agentAllowedTools(actions: all)
        #expect(!allowed.contains { tool in passwordActions.contains { tool.hasSuffix($0) } })
    }
}

@Test func aSavedPasswordNeverReachesTheJournal() async throws {
    try await withFixture { f in
        try await f.dispatch("browser_password_save", ["org": .string("initech"), "site": .string("example.com"),
                                                       "username": .string("ann"), "password": .string("walk-test-pass-1"),
                                                       "pane": .string(paneId), "tab": .string(tabId)])
        try await f.dispatch("browser_password_fill", fill("ann"))
        // A refused save is journalled too, with its reason.
        _ = await refusal {
            try await f.dispatch("browser_password_save", ["org": .string("globex"), "site": .string("example.com"),
                                                           "username": .string("ann"),
                                                           "password": .string("walk-test-pass-1")])
        }
        let files = FileManager.default.enumerator(at: f.journal, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        #expect(!files.isEmpty, "the journal was written somewhere else, so this proves nothing")
        var lines = 0
        for file in files {
            let body = try String(contentsOf: file, encoding: .utf8)
            lines += body.split(separator: "\n").count
            #expect(!body.contains("walk-test-pass-1"), "\(file.lastPathComponent) holds the password")
        }
        #expect(lines >= 3)
    }
}

@Test func readPaneCarriesNoPasswordAfterAFill() async throws {
    try await withFixture { f in
        try f.store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
        try await f.dispatch("browser_password_fill", fill("ann"))
        #expect(await f.page.fills.count == 1)
        let pane = try text(await f.panes.readPane(paneId: paneId, kind: "browser"))
        #expect(pane.contains("example.com"))
        #expect(!pane.contains("walk-test-pass-1"))
        let snapshot = String(decoding: try JSONEncoder().encode(await f.panes.browserSnapshot(paneId: paneId)), as: UTF8.self)
        #expect(!snapshot.contains("walk-test-pass-1"))
    }
}

// MARK: - The scrub

@Test func aReadHidesAFilledPasswordInTextAndValues() async throws {
    try await withFixture { f in
        try f.store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
        try f.store.save(org: "initech", site: "example.com", username: "bob", password: "abc")
        try await f.dispatch("browser_password_fill", fill("ann"))

        // A site's "show password" turned the field into text.
        let page = BrowserPageRead(
            url: "https://example.com/login", title: "Log in",
            text: "Your password is walk-test-pass-1. abc news",
            elements: [
                BrowserElement(ref: "e1", role: "textbox", label: "Password walk-test-pass-1", type: "text",
                               value: "walk-test-pass-1"),
                BrowserElement(ref: "e2", role: "textbox", label: "abc", type: "text", value: "abc"),
            ])
        let driver = BrowserScrubbingPageDriver(base: FixedPageDriver(page: page), scrub: f.scrub)
        var read = try await driver.read(scope: nil, pane: paneId, tab: tabId, firstRef: 1)
        #expect(read.text == "Your password is ••••••••. abc news")
        #expect(read.elements[0].value == "••••••••")
        #expect(read.elements[0].label == "Password ••••••••")
        // Not filled yet, so not known.
        #expect(read.elements[1].value == "abc")
        let described = try await driver.describe(scope: nil, pane: paneId, tab: tabId, ref: "e1")
        #expect(described.value == "••••••••")

        // A 3-character password is hidden in values only: in text it would hide every "abc".
        try await f.dispatch("browser_password_fill", fill("bob"))
        read = try await driver.read(scope: nil, pane: paneId, tab: tabId, firstRef: 1)
        #expect(read.text == "Your password is ••••••••. abc news")
        #expect(read.elements[1].value == "••••••••")
        #expect(read.elements[1].label == "abc")

        // An act passes through.
        let acted = try await driver.act(scope: nil, pane: paneId, tab: tabId, .click(ref: "e1"))
        #expect(acted.url == "https://example.com/login")
    }
}

@Test func theScrubKeepsTheNewestSixtyFour() async {
    let scrub = BrowserPasswordScrub(cap: 2)
    await scrub.remember("walk-test-pass-1")
    await scrub.remember("walk-test-pass-2")
    await scrub.remember("walk-test-pass-1")   // seen again: newest, not a second copy
    await scrub.remember("walk-test-pass-3")
    let read = await scrub.scrub(BrowserPageRead(
        url: "", title: "", text: "walk-test-pass-1 walk-test-pass-2 walk-test-pass-3", elements: []))
    #expect(read.text == "•••••••• walk-test-pass-2 ••••••••")
    #expect(BrowserPasswordScrub.defaultCap == 64)
}
