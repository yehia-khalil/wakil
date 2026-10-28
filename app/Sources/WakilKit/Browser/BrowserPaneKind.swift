import Foundation

/// What the browser kind keeps for the whole store (3c-ii), across scope switches: each
/// organisation's sites, and each conversation's allowed site keys (`BrowserSite.key`).
public struct BrowserShared: Sendable, Equatable {
    public var sites: [String: BrowserSites] = [:]
    public var bookmarks: [String: [BrowserBookmark]] = [:]
    public var allowed: [String: Set<String>] = [:]
    /// 3d-i: each organisation's pull-request list (ruling 18), by organisation; absent until read.
    public var pullRequests: [String: BrowserPullRequests] = [:]
    public init() {}
}

/// One open pull request from `ctx_github_pull_requests` (ruling 17): its `reason` is `author` or
/// `review-requested`.
public struct BrowserPullRequest: Codable, Sendable, Equatable {
    public var number: Int
    public var title, url, repository, reason: String

    public init(number: Int, title: String, url: String, repository: String, reason: String) {
        self.number = number
        self.title = title
        self.url = url
        self.repository = repository
        self.reason = reason
    }

    /// A pull-request tab's title until its page loads (ruling 18): `<title> · <repository>#<number>`.
    public var tabTitle: String { "\(title) · \(repository)#\(number)" }
}

/// An organisation's pull-request list (ruling 18): the last list read, why there is none
/// (`absent`, a state), the last refresh's failure shown whole (`error`; the list before it is
/// kept), and whether a refresh is running (Rule 5: a second one is not started).
public struct BrowserPullRequests: Sendable, Equatable {
    public var items: [BrowserPullRequest]
    public var absent: String?
    public var error: String?
    public var refreshing: Bool

    public init(items: [BrowserPullRequest] = [], absent: String? = nil, error: String? = nil, refreshing: Bool = false) {
        self.items = items
        self.absent = absent
        self.error = error
        self.refreshing = refreshing
    }
}

/// The browser pane (3c-i): tabs of web pages. Its contents are its snapshot. The store owns each
/// tab's address, title and state; a WebKit view per tab applies the tab's `command` and reports
/// back through `PaneStore.browserPageDidReport`.
enum BrowserPaneKind: PaneKind {
    static let names = ["browser"]
    /// Edge to edge: the page runs to the slab's border (3c-i, the compact chrome of 2026-10-26).
    static let edgeToEdge = true
    static var emptyContents: BrowserSnapshot { .empty }
    static var emptyShared: BrowserShared { BrowserShared() }
    static var emptySnapshot: BrowserSnapshot? { .empty }
    static func snapshot(of contents: BrowserSnapshot, in store: isolated PaneStore) -> BrowserSnapshot { contents }
    static func failure(of contents: BrowserSnapshot) -> String? { contents.activeTab?.failure }

    /// Every key always present. **Never page text**: the agent reads what the operator sees by
    /// address and title, not the page's contents. No key may be `kind` or `failure` (the envelope's).
    static func readPane(_ s: BrowserSnapshot, in store: isolated PaneStore) -> [String: JSONValue] {
        let tab = s.activeTab
        let sites = store.browserSites(org: store.activeScope.organization)
        let bookmarked = tab.map { t in
            store.browserBookmarks(org: store.activeScope.organization).contains { $0.url == t.url }
        } ?? false
        return [
            "tabs": .array(s.tabs.map { t in
                let site = BrowserSite.key(t.url)
                // `production` is the price the agent will pay (true for every web tab while the
                // organisation is unread); `environment` is the tag, never page text.
                var environment: JSONValue = .null
                if case .environment(let name)? = sites.tag(t.url) { environment = .string(name) }
                return .object([
                    "id": .string(t.id), "url": .string(t.url), "title": .string(t.title),
                    "loading": .bool(t.isLoading), "active": .bool(t.id == s.active),
                    "site": site.map { .string($0) } ?? .null, "environment": environment,
                    "production": .bool(site.map { sites.isProduction($0) } ?? false),
                    "group": t.group.map { .string($0) } ?? .null, "pinned": .bool(s.isPinned(t)),
                ])
            }),
            // 3d-i: the pane's groups in the order they were made, each with its tabs in drawn order.
            // The pull-request group also carries its list's `error` and whether a refresh runs.
            "groups": .array(s.groups.map { g in
                var o: [String: JSONValue] = [
                    "id": .string(g.id), "name": .string(g.name), "colour": .string(g.colour.rawValue),
                    "collapsed": .bool(g.collapsed), "kind": .string(g.kind.rawValue), "pinned": .bool(g.pin != nil),
                    "tabs": .array(s.tabs.filter { $0.group == g.id }.map { .string($0.id) }),
                ]
                if g.kind == .pullRequests {
                    let list = store.browserPullRequests(org: store.activeScope.organization)
                    o["error"] = list?.error.map { .string($0) } ?? .null
                    o["refreshing"] = .bool(list?.refreshing ?? false)
                }
                return .object(o)
            }),
            "tabColumnHidden": .bool(s.tabColumnHidden),
            "pinsError": s.pinsError.map { .string($0) } ?? .null,
            "active": tab.map { .string($0.id) } ?? .null,
            "url": tab.map { .string($0.url) } ?? .null,
            "title": tab.map { .string($0.title) } ?? .null,
            "loading": tab.map { .bool($0.isLoading) } ?? .null,
            "canGoBack": tab.map { .bool($0.canGoBack) } ?? .null,
            "canGoForward": tab.map { .bool($0.canGoForward) } ?? .null,
            "bookmarked": .bool(bookmarked),
            "zoom": tab.map { .number($0.zoom) } ?? .null,
            "pictureInPicture": s.tabs.first { $0.pictureInPicture }.map { .string($0.id) } ?? .null,
            "find": s.find.map { f in .object([
                "query": .string(f.query), "current": .number(Double(f.current)), "total": .number(Double(f.total)),
            ]) } ?? .null,
            "downloads": .array(s.downloads.map { d in .object([
                "id": .string(d.id), "filename": .string(d.filename), "state": .string(d.state.rawValue),
                "received": .number(Double(d.received)), "expected": .number(Double(d.expected)),
            ]) }),
        ]
    }
}

extension PaneSnapshot {
    public var browser: BrowserSnapshot? { contents as? BrowserSnapshot }
}

extension BrowserSnapshot: PaneKindSnapshot {}

extension BrowserPaneKind: PaneRestorable {
    /// A browser's subject is its saved tabs, reopened by its own action (only the active one
    /// fetches). Nothing to restore when the layout saved no tabs and no group — a pane whose only
    /// tabs were pull requests saved its `pr` group alone, and is restored for it (the list refills it).
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        guard !(pane.browserTabs ?? []).isEmpty || !(pane.browserGroups ?? []).isEmpty else { return nil }
        return PaneRestoreStep(action: "browser_restore", params: .object(["pane": .string(pane.id)]), recordsFailure: false)
    }
}
