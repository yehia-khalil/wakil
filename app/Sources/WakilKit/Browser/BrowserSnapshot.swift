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

    public static let empty = BrowserSnapshot(tabs: [], active: nil, find: nil, downloads: [], closed: [], nextTab: 1)

    public init(
        tabs: [BrowserTab], active: String?, find: BrowserFind?, downloads: [BrowserDownload],
        closed: [BrowserSavedTab], nextTab: Int
    ) {
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

    public init(
        id: String, url: String, title: String, isLoading: Bool = false, progress: Double = 0,
        canGoBack: Bool = false, canGoForward: Bool = false, failure: String? = nil, zoom: Double = 1,
        loaded: Bool = false, command: BrowserCommand? = nil, fromSavedLayout: Bool = false
    ) {
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

    public init(
        url: String, title: String, isLoading: Bool, progress: Double, canGoBack: Bool,
        canGoForward: Bool, failure: String?, zoom: Double? = nil
    ) {
        self.zoom = zoom
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.progress = progress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.failure = failure
    }
}
