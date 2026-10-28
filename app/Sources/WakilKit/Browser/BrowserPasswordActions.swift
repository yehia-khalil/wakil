import Foundation

/// 3d-iv: the five password actions, the scrub that hides a password a page has held from the agent's
/// reads, and the seam the window fills a page through.
///
/// **Reads are direct calls; writes are actions** (ruling 10). The key's list and Settings call
/// `BrowserPasswordStore` themselves. Every action here is `.control` and `.operatorOnly`, and every
/// reply is `{org, site, username, outcome}`: no action returns a password, so none reaches a journal
/// line or an MCP reply. `browser_password_save`'s `password` is a `secretParams` key, so the journal
/// writes `[redacted]` in its place. No error here is built from a password.

// MARK: - The page seam

public enum BrowserPasswordPageError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The tab is not live on the screen's canvas in a place of the organisation.
    case notShown
    /// The page's origin is not the asked site's any more (ruling 13: checked again in the page).
    case siteChanged(now: String)
    /// The page has no field to put it in.
    case noField
    case failed(String)

    public var description: String {
        switch self {
        case .notShown: "the tab is not on screen, so nothing was filled."
        case .siteChanged(let now): "the tab is on \(now) now."
        case .noField: "the page has no field to fill."
        case .failed(let why): why
        }
    }
}

/// The window's (Task 8): puts a value in the focused login form of a tab on the screen's canvas. It
/// is called only by `browser_password_fill` and `browser_password_suggest`; nothing fills on a load.
public protocol BrowserPasswordPage: Sendable {
    func fill(pane: String, tab: String, org: String, site: String, username: String, password: String) async throws
    func suggest(pane: String, tab: String, org: String, site: String, password: String) async throws
}

// MARK: - The scrub (ruling 15)

/// The passwords that have been in a page this run — filled, suggested, or saved from a page's bar —
/// in memory only, newest kept. A read is scrubbed of each: in an element's value at any length, and in
/// the page's text, title and labels from 6 characters up (a shorter one would hide ordinary words).
/// This covers a site's *show password*, which turns the field into text.
public actor BrowserPasswordScrub {
    public static let defaultCap = 64
    public static let mask = "••••••••"
    /// The shortest password hidden in text; any length is hidden in a value.
    static let textMinimum = 6

    private let cap: Int
    /// Oldest first.
    private var known: [String] = []

    public init(cap: Int = BrowserPasswordScrub.defaultCap) {
        self.cap = max(1, cap)
    }

    public func remember(_ password: String) {
        guard !password.isEmpty else { return }
        known.removeAll { $0 == password }
        known.append(password)
        if known.count > cap { known.removeFirst(known.count - cap) }
    }

    public func scrub(_ read: BrowserPageRead) -> BrowserPageRead {
        guard !known.isEmpty else { return read }
        let (any, long) = lists()
        var out = read
        out.title = Self.hide(read.title, long)
        out.text = Self.hide(read.text, long)
        out.elements = read.elements.map { Self.scrub($0, any: any, long: long) }
        return out
    }

    public func scrub(_ element: BrowserElement) -> BrowserElement {
        guard !known.isEmpty else { return element }
        let (any, long) = lists()
        return Self.scrub(element, any: any, long: long)
    }

    /// Longest first, so a password inside another is never left half shown.
    private func lists() -> (any: [String], long: [String]) {
        let any = known.sorted { $0.count > $1.count }
        return (any, any.filter { $0.count >= Self.textMinimum })
    }

    /// `type`, `autocomplete`, `name` and `id` are left: an act's `expect` is matched on them.
    private static func scrub(_ e: BrowserElement, any: [String], long: [String]) -> BrowserElement {
        var out = e
        out.value = e.value.map { hide($0, any) }
        out.label = hide(e.label, long)
        out.placeholder = hide(e.placeholder, long)
        out.options = e.options?.map { hide($0, long) }
        out.href = e.href.map { hide($0, long) }
        return out
    }

    private static func hide(_ s: String, _ passwords: [String]) -> String {
        var out = s
        for p in passwords where out.contains(p) { out = out.replacingOccurrences(of: p, with: mask) }
        return out
    }
}

/// Wraps the window's page driver: `read` and `describe` come back scrubbed, `act` passes through.
public struct BrowserScrubbingPageDriver: BrowserPageDriver {
    let base: any BrowserPageDriver
    let scrub: BrowserPasswordScrub

    public init(base: any BrowserPageDriver, scrub: BrowserPasswordScrub) {
        self.base = base
        self.scrub = scrub
    }

    public func read(scope: LayoutScope?, pane: String, tab: String, firstRef: Int) async throws -> BrowserPageRead {
        await scrub.scrub(try await base.read(scope: scope, pane: pane, tab: tab, firstRef: firstRef))
    }

    public func describe(scope: LayoutScope?, pane: String, tab: String, ref: String) async throws -> BrowserElement {
        await scrub.scrub(try await base.describe(scope: scope, pane: pane, tab: tab, ref: ref))
    }

    public func act(scope: LayoutScope?, pane: String, tab: String, _ act: BrowserPageAct) async throws -> BrowserActResult {
        try await base.act(scope: scope, pane: pane, tab: tab, act)
    }
}

// MARK: - The actions

public enum BrowserPasswordActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case noLogin(site: String, username: String, org: String)
    case moved(now: String, site: String)
    case suggestMoved(now: String, site: String)
    case unknownOrganisation(action: String, org: String)
    case notAWebPage(action: String, url: String)
    case notASite(action: String, site: String)
    case noPage(action: String)
    case page(action: String, BrowserPasswordPageError)
    case store(action: String, BrowserPasswordError)
    case neverUnreadable(String)

    public var description: String {
        switch self {
        case .noLogin(let site, let username, let org):
            let who = username.isEmpty ? "" : " for \(username)"
            return "browser_password_fill: \(site) has no saved password\(who) in \(org)."
        case .moved(let now, let site):
            return "browser_password_fill: the tab is on \(now) now, so the password for \(site) was not filled."
        case .suggestMoved(let now, let site):
            return "browser_password_suggest: the tab is on \(now) now, so no password was suggested for \(site)."
        case .unknownOrganisation(let action, let org):
            return "\(action): \"\(org)\" is not an organisation on this Mac."
        case .notAWebPage(let action, let url):
            return "\(action): \(url.isEmpty ? "a blank tab" : url) is not a web page, so it has no saved passwords."
        case .notASite(let action, let site):
            return "\(action): \"\(site)\" is not a site."
        case .noPage(let action):
            return "\(action): no page can be filled here — only the Wakil window fills one."
        case .page(let action, let error):
            return "\(action): \(error)"
        case .store(let action, let error):
            return "\(action): \(error)"
        case .neverUnreadable(let reason):
            return "browser_password_never: passwords-never.json can't be read (\(reason)) — fix or move it; "
                + "Wakil won't write over it."
        }
    }
}

/// Registers `browser_password_fill`, `_suggest`, `_save`, `_delete` and `_never`.
///
/// `pane` and `tab` are required where they appear: the key and the bar always know them, and a
/// default would let a fill land in a tab no one pressed in. `activeOrg` is the window's organisation,
/// read on every call: a fill reads that organisation's login only (Invariant 4). `home` is the HOME
/// whose `.wakil/orgs/<org>` names the organisations on this Mac.
public func registerBrowserPasswordActions(
    into registry: ActionRegistry,
    panes: PaneStore,
    store: BrowserPasswordStore,
    scrub: BrowserPasswordScrub,
    page: (any BrowserPasswordPage)?,
    home: URL,
    activeOrg: @escaping @Sendable () async -> String
) async {
    for action in browserPasswordActions(panes: panes, store: store, scrub: scrub, page: page,
                                         home: home, activeOrg: activeOrg) {
        await registry.register(action)
    }
}

func browserPasswordActions(
    panes: PaneStore,
    store: BrowserPasswordStore,
    scrub: BrowserPasswordScrub,
    page: (any BrowserPasswordPage)?,
    home: URL,
    activeOrg: @escaping @Sendable () async -> String
) -> [Action] {
    let string: JSONValue = .object(["type": .string("string")])
    func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) })])
    }

    @Sendable func reply(org: String, site: String, username: String, outcome: String) -> JSONValue {
        .object(["org": .string(org), "site": .string(site), "username": .string(username),
                 "outcome": .string(outcome)])
    }

    @Sendable func active() async throws -> String {
        let org = await activeOrg()
        guard !org.isEmpty else { throw BrowserActionError.noOrganisation }
        return org
    }

    /// A name Go would accept, with a folder under `~/.wakil/orgs`. Nothing is made for one that isn't.
    @Sendable func requireOrganisation(_ org: String, action: String) throws {
        let folder = home.appendingPathComponent(".wakil", isDirectory: true)
            .appendingPathComponent("orgs", isDirectory: true)
            .appendingPathComponent(org, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard (try? BrowserPasswords.service(org: org)) != nil,
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw BrowserPasswordActionError.unknownOrganisation(action: action, org: org) }
    }

    /// A site key never holds a space: the account splits at the first one.
    @Sendable func requireSite(_ params: JSONValue, action: String) throws -> String {
        let site = try requireString(params, "site", action: action)
        guard !site.isEmpty, !site.contains(where: \.isWhitespace) else {
            throw BrowserPasswordActionError.notASite(action: action, site: site)
        }
        return site
    }

    /// The named tab of the named pane: its URL now.
    @Sendable func tabURL(_ params: JSONValue, action: String) async throws -> (pane: String, tab: String, url: String) {
        let pane = try requireString(params, "pane", action: action)
        let tab = try requireString(params, "tab", action: action)
        guard let t = await panes.browserSnapshot(paneId: pane).tabs.first(where: { $0.id == tab }) else {
            throw BrowserActionError.noTab(action: action, tab: tab)
        }
        return (pane, tab, t.url)
    }

    @Sendable func storeCall<T>(_ action: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as BrowserPasswordError {
            throw BrowserPasswordActionError.store(action: action, error)
        }
    }

    var actions: [Action] = []

    actions.append(Action(
        name: "browser_password_fill",
        description: "Fill the saved password for username on site into the focused login form of a tab. "
            + "Operator only: pressing the key in a field. Refused when the tab is no longer on site.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["pane": string, "tab": string, "site": string, "username": string],
                       required: ["pane", "tab", "site", "username"]),
        handler: { params in
            let action = "browser_password_fill"
            let (pane, tab, url) = try await tabURL(params, action: action)
            let site = try requireSite(params, action: action)
            let username = try requireString(params, "username", action: action)
            let org = try await active()
            guard let page else { throw BrowserPasswordActionError.noPage(action: action) }
            // Ruling 13: the login's site, and nowhere else. The page checks its origin again.
            let now = BrowserPasswords.siteKey(url)
            guard now == site else { throw BrowserPasswordActionError.moved(now: now ?? url, site: site) }
            let password: String
            do {
                password = try store.password(org: org, site: site, username: username)
            } catch BrowserPasswordError.notFound {
                throw BrowserPasswordActionError.noLogin(site: site, username: username, org: org)
            } catch let error as BrowserPasswordError {
                throw BrowserPasswordActionError.store(action: action, error)
            }
            // Remembered before the page holds it, so no read between the two can show it.
            await scrub.remember(password)
            do {
                try await page.fill(pane: pane, tab: tab, org: org, site: site, username: username, password: password)
            } catch BrowserPasswordPageError.siteChanged(let moved) {
                throw BrowserPasswordActionError.moved(now: moved, site: site)
            } catch let error as BrowserPasswordPageError {
                throw BrowserPasswordActionError.page(action: action, error)
            }
            return reply(org: org, site: site, username: username, outcome: "filled")
        }))

    actions.append(Action(
        name: "browser_password_suggest",
        description: "Fill a new strong password into a tab's new-password fields. Operator only: the key's "
            + "Suggest Strong Password. The reply never carries the password.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["pane": string, "tab": string], required: ["pane", "tab"]),
        handler: { params in
            let action = "browser_password_suggest"
            let (pane, tab, url) = try await tabURL(params, action: action)
            let org = try await active()
            guard let page else { throw BrowserPasswordActionError.noPage(action: action) }
            guard let site = BrowserPasswords.siteKey(url) else {
                throw BrowserPasswordActionError.notAWebPage(action: action, url: url)
            }
            let password = BrowserPasswords.strongPassword()
            await scrub.remember(password)
            do {
                try await page.suggest(pane: pane, tab: tab, org: org, site: site, password: password)
            } catch BrowserPasswordPageError.siteChanged(let moved) {
                throw BrowserPasswordActionError.suggestMoved(now: moved, site: site)
            } catch let error as BrowserPasswordPageError {
                throw BrowserPasswordActionError.page(action: action, error)
            }
            return reply(org: org, site: site, username: "", outcome: "suggested")
        }))

    actions.append(Action(
        name: "browser_password_save",
        description: "Save, update or rename a password for username on site in org. previousUsername "
            + "renames that login (its password is kept when none is given). pane and tab name the page it "
            + "was sent from. Operator only: the save bar, Settings and the import.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["org": string, "site": string, "username": string, "password": string,
                        "previousUsername": string, "pane": string, "tab": string],
                       required: ["org", "site", "username"]),
        handler: { params in
            let action = "browser_password_save"
            let org = try requireString(params, "org", action: action)
            try requireOrganisation(org, action: action)
            let site = try requireSite(params, action: action)
            let username = try requireString(params, "username", action: action)
            let password = optionalString(params, "password")
            let previous = optionalString(params, "previousUsername")
            // It was in a page, so that page's reads hide it from now on.
            if optionalString(params, "pane") != nil, let password { await scrub.remember(password) }
            if let previous, previous != username {
                try storeCall(action) {
                    try store.rename(org: org, site: site, from: previous, to: username, password: password)
                }
                return reply(org: org, site: site, username: username, outcome: "renamed")
            }
            guard let password else { throw StandardActionError.missingParam(action: action, param: "password") }
            let outcome = try storeCall(action) {
                try store.save(org: org, site: site, username: username, password: password)
            }
            let word = switch outcome { case .added: "added"; case .updated: "updated"; case .unchanged: "unchanged" }
            return reply(org: org, site: site, username: username, outcome: word)
        },
        secretParams: ["password"]))

    actions.append(Action(
        name: "browser_password_delete",
        description: "Delete the saved password for username on site in org. Operator only: Settings.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["org": string, "site": string, "username": string], required: ["org", "site", "username"]),
        handler: { params in
            let action = "browser_password_delete"
            let org = try requireString(params, "org", action: action)
            try requireOrganisation(org, action: action)
            let site = try requireSite(params, action: action)
            let username = try requireString(params, "username", action: action)
            try storeCall(action) { try store.delete(org: org, site: site, username: username) }
            return reply(org: org, site: site, username: username, outcome: "deleted")
        }))

    actions.append(Action(
        name: "browser_password_never",
        description: "Never offer to save a password on site in org (on true), or offer again (on false). "
            + "Operator only: the save bar's Never for This Site, and Settings.",
        kind: .control, audience: .operatorOnly,
        schema: schema(["org": string, "site": string, "on": .object(["type": .string("boolean")])],
                       required: ["org", "site", "on"]),
        handler: { params in
            let action = "browser_password_never"
            let org = try requireString(params, "org", action: action)
            try requireOrganisation(org, action: action)
            let site = try requireSite(params, action: action)
            guard case .object(let o) = params, case .bool(let on)? = o["on"] else {
                throw StandardActionError.missingParam(action: action, param: "on")
            }
            do {
                try BrowserOrgFiles(home: home, org: org).setNeverSave(site: site, on: on)
            } catch let error as BrowserNeverSaveUnreadable {
                throw BrowserPasswordActionError.neverUnreadable(error.reason)
            }
            return reply(org: org, site: site, username: "", outcome: on ? "never" : "offered")
        }))

    return actions
}
