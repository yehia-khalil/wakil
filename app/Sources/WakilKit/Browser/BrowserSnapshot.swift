import Foundation

/// The browser pane's state (3c-i): its tabs, find bar, downloads and closed-tab stack. The store
/// owns it; each tab's web view applies its `command` and reports back through the seam
/// (`PaneStore.browserPageDidReport` and the methods beside it).
public struct BrowserSnapshot: Sendable, Equatable, Codable {
    public var tabs: [BrowserTab]
    public var active: String?
    /// `nil` when the find bar is closed.
    public var find: BrowserFind?
    public var downloads: [BrowserDownload]
    /// The ⌘⇧T stack, newest last, at most 20. Not persisted.
    public var closed: [BrowserSavedTab]
    /// The number in the next tab id; tab ids are `"t<n>"`.
    public var nextTab: Int
    /// The pane's groups (3d-i), in the order they were made. Saved with the layout.
    public var groups: [BrowserGroup]
    /// The number in the next group id; group ids are `"g<n>"` (and `"pr"`). Not saved: a restore
    /// sets it one past the highest `g<n>` it puts back.
    public var nextGroup: Int
    /// The vertical tab column is hidden in this pane (ruling 20). Saved with the layout.
    public var tabColumnHidden: Bool
    /// Why `pins/<project>.json` can't be read (ruling 13); nil when it can. Runtime only.
    public var pinsError: String?

    public static let empty = BrowserSnapshot(tabs: [], active: nil, find: nil, downloads: [], closed: [], nextTab: 1)

    public init(
        tabs: [BrowserTab], active: String?, find: BrowserFind?, downloads: [BrowserDownload],
        closed: [BrowserSavedTab], nextTab: Int, groups: [BrowserGroup] = [], nextGroup: Int = 1,
        tabColumnHidden: Bool = false, pinsError: String? = nil
    ) {
        self.groups = groups
        self.nextGroup = nextGroup
        self.tabColumnHidden = tabColumnHidden
        self.pinsError = pinsError
        self.tabs = tabs
        self.active = active
        self.find = find
        self.downloads = downloads
        self.closed = closed
        self.nextTab = nextTab
    }

    /// The selected tab, if `active` names one.
    public var activeTab: BrowserTab? { active.flatMap { id in tabs.first { $0.id == id } } }
}

/// What the agent last read in a tab (3c-ii): the page's address, its site key and the elements that
/// were given refs. Never the page's text. Dropped when a report names another address.
public struct BrowserReadStamp: Sendable, Equatable, Codable {
    public var url, site: String
    public var elements: [String: BrowserElement]

    public init(url: String, site: String, elements: [String: BrowserElement]) {
        self.url = url; self.site = site; self.elements = elements
    }
}

public struct BrowserTab: Sendable, Equatable, Codable {
    public var id: String
    public var url: String
    public var title: String
    public var isLoading: Bool
    public var progress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var failure: String?
    public var zoom: Double
    /// False until its web view has fetched once: a restored tab loads only when it is shown.
    public var loaded: Bool
    /// The latest request for the host to apply; a new `seq` is a new request.
    public var command: BrowserCommand?
    /// Put back from the saved layout (`browserRestore`): the one kind of tab whose web view may
    /// take a saved state (its ‹ › history) on its first build. A tab made this launch never does,
    /// so a reissued pane or tab id never shows an earlier pane's page (final review I2).
    public var fromSavedLayout: Bool
    /// The agent's last read of this tab; nil when none, or the page has moved since.
    public var lastRead: BrowserReadStamp?
    /// Refs `e1…e<refsIssued>` have been given out in this tab; a ref is never reused.
    public var refsIssued: Int
    /// The group it is in (3d-i), a `BrowserGroup.id`; nil when loose.
    public var group: String?
    /// The tab it was opened from, kept while it sits in that tab's group (ruling 8).
    public var opener: String?
    /// The entry in `pins/<project>.json` it is pinned as (ruling 3); nil when not pinned itself.
    public var pin: String?
    /// The operator took it out of a group: the site rule never groups it again (ruling 10).
    public var keptLoose: Bool
    /// The pull request this tab lists (ruling 18), its URL; such a tab is never saved.
    public var pullRequest: String?
    /// The site key the site rule last placed it by; nil until a finished load on a page with a site
    /// key first places it. Not saved: a tab in an automatic site group is placed on that group's key.
    public var placedSite: String?
    /// A grouped tab's finished load on a site other than its group's, waiting for a second one on
    /// the same site before the tab moves (a sign-in hop through another host comes back after one).
    public var pendingSite: String?
    /// This tab's video floats in the system's picture-in-picture window. Reported by the host
    /// (`BrowserPageReport`), never saved: it is not in `CodingKeys` or `BrowserSavedTab`.
    public var pictureInPicture: Bool = false

    public init(
        id: String, url: String, title: String, isLoading: Bool = false, progress: Double = 0,
        canGoBack: Bool = false, canGoForward: Bool = false, failure: String? = nil, zoom: Double = 1,
        loaded: Bool = false, command: BrowserCommand? = nil, fromSavedLayout: Bool = false,
        lastRead: BrowserReadStamp? = nil, refsIssued: Int = 0, group: String? = nil, opener: String? = nil,
        pin: String? = nil, keptLoose: Bool = false, pullRequest: String? = nil,
        placedSite: String? = nil, pendingSite: String? = nil
    ) {
        self.placedSite = placedSite
        self.pendingSite = pendingSite
        self.group = group
        self.opener = opener
        self.pin = pin
        self.keptLoose = keptLoose
        self.pullRequest = pullRequest
        self.lastRead = lastRead
        self.refsIssued = refsIssued
        self.fromSavedLayout = fromSavedLayout
        self.id = id
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.progress = progress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.failure = failure
        self.zoom = zoom
        self.loaded = loaded
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, title, isLoading, progress, canGoBack, canGoForward, failure, zoom, loaded
        case command, fromSavedLayout, lastRead, refsIssued, group, opener, pin, keptLoose, pullRequest
        case placedSite, pendingSite
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        isLoading = try c.decode(Bool.self, forKey: .isLoading)
        progress = try c.decode(Double.self, forKey: .progress)
        canGoBack = try c.decode(Bool.self, forKey: .canGoBack)
        canGoForward = try c.decode(Bool.self, forKey: .canGoForward)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        zoom = try c.decode(Double.self, forKey: .zoom)
        loaded = try c.decode(Bool.self, forKey: .loaded)
        command = try c.decodeIfPresent(BrowserCommand.self, forKey: .command)
        fromSavedLayout = try c.decode(Bool.self, forKey: .fromSavedLayout)
        lastRead = try c.decodeIfPresent(BrowserReadStamp.self, forKey: .lastRead)
        refsIssued = try c.decodeIfPresent(Int.self, forKey: .refsIssued) ?? 0
        group = try c.decodeIfPresent(String.self, forKey: .group)
        opener = try c.decodeIfPresent(String.self, forKey: .opener)
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
        keptLoose = try c.decodeIfPresent(Bool.self, forKey: .keptLoose) ?? false
        pullRequest = try c.decodeIfPresent(String.self, forKey: .pullRequest)
        placedSite = try c.decodeIfPresent(String.self, forKey: .placedSite)
        pendingSite = try c.decodeIfPresent(String.self, forKey: .pendingSite)
    }
}

public struct BrowserCommand: Sendable, Equatable, Codable {
    public var seq: Int
    public var verb: Verb

    public enum Verb: Sendable, Equatable, Codable {
        case load(String), back, forward, reload, stop, zoom(Double), focusAddress
        /// The page printed, through the system's print panel (⌘K → Print page).
        case print
    }

    public init(seq: Int, verb: Verb) {
        self.seq = seq
        self.verb = verb
    }
}

public struct BrowserFind: Sendable, Equatable, Codable {
    public var query: String
    public var current: Int
    public var total: Int
    public var seq: Int
    public var forward: Bool

    public init(query: String, current: Int, total: Int, seq: Int, forward: Bool) {
        self.query = query
        self.current = current
        self.total = total
        self.seq = seq
        self.forward = forward
    }
}

public struct BrowserDownload: Sendable, Equatable, Codable {
    public var id: String
    public var filename: String
    public var received: Int64
    public var expected: Int64
    public var state: State
    public var path: String?
    public var failure: String?
    /// Cancel was asked (`browser_download_cancel`); the host cancels and reports `.cancelled`.
    /// The state never changes on the ask alone.
    public var cancelRequested: Bool

    public enum State: String, Sendable, Codable { case running, finished, failed, cancelled }

    public init(
        id: String, filename: String, received: Int64, expected: Int64, state: State,
        path: String? = nil, failure: String? = nil, cancelRequested: Bool = false
    ) {
        self.cancelRequested = cancelRequested
        self.id = id
        self.filename = filename
        self.received = received
        self.expected = expected
        self.state = state
        self.path = path
        self.failure = failure
    }
}

/// What a tab's web view reports after a navigation event — the seam's one input. Never page text.
public struct BrowserPageReport: Sendable, Equatable {
    public var url: String
    public var title: String
    public var isLoading: Bool
    public var progress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var failure: String?
    /// The page zoom the web view took on arriving at a host (its remembered `zoom.json` factor);
    /// nil leaves the tab's zoom as it is. Only a host change names one, so a report read before a
    /// `browser_zoom` applied never undoes it.
    public var zoom: Double?
    /// This tab's video floats in picture-in-picture. Always carried, so a re-sent report keeps it.
    public var pictureInPicture: Bool

    public init(
        url: String, title: String, isLoading: Bool, progress: Double, canGoBack: Bool,
        canGoForward: Bool, failure: String?, zoom: Double? = nil, pictureInPicture: Bool = false
    ) {
        self.zoom = zoom
        self.pictureInPicture = pictureInPicture
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.progress = progress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.failure = failure
    }
}

extension BrowserTab {
    /// What a tab is called in lists: its title, else its host, else New Tab.
    public var label: String {
        if !title.isEmpty { return title }
        if let parsed = URL(string: url), !url.isEmpty { return BrowserAddress.displayHost(parsed) }
        return "New Tab"
    }
}
