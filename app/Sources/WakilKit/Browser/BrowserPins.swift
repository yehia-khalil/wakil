import Foundation

/// 3d-i: a project's pins, `pins/<project>.json` in the organisation's browser folder (ruling 13), and
/// how a pane is brought in line with them (ruling 14). The file is a static list: read when a pane
/// opens or is restored, written when a pin changes; there is no live sync between panes' pages.
public struct BrowserPin: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case tab, group, pullRequests }

    /// `p` + the first 8 hex of a UUID (`BrowserPin.newId()`); the tab or group pinned names it.
    public var id: String
    public var kind: Kind
    /// A tab's address and title, as it was pinned (or last *Pin Current Page*).
    public var url: String?
    public var title: String?
    /// A group's name, colour and tabs, as it was pinned (or last *Update Pin*). On a tab pin, the
    /// tab's name (names call 15): written when the tab is pinned and at once when it is renamed; nil
    /// when it has none, and absent from a 3d-i file.
    public var name: String?
    public var colour: BrowserGroupColour?
    public var tabs: [BrowserPinTab]?

    public init(id: String, kind: Kind, url: String? = nil, title: String? = nil, name: String? = nil,
                colour: BrowserGroupColour? = nil, tabs: [BrowserPinTab]? = nil) {
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title
        self.name = name
        self.colour = colour
        self.tabs = tabs
    }

    /// A new pin id, `p` + the first 8 hex of a UUID, lower-cased.
    public static func newId() -> String {
        "p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}

/// One tab of a pinned group.
public struct BrowserPinTab: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    /// The tab's name (names call 15), as it was pinned or last *Update Pin*; nil when it had none, and
    /// absent from a 3d-i file (the synthesised decoder reads an optional with `decodeIfPresent`).
    public var name: String?
    public init(url: String, title: String, name: String? = nil) {
        self.url = url
        self.title = title
        self.name = name
    }
}

/// `pins/<project>.json` exists but cannot be read; it is never written over (ruling 13).
public struct BrowserPinsUnreadable: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// The file's shape: `{"items":[…]}`.
struct BrowserPinsFile: Codable {
    var items: [BrowserPin]
}

extension BrowserSnapshot {
    /// Full reconcile (ruling 14): every pin the pane lacks is added — unloaded, never selected — and
    /// every tab or group whose pin id `pins` no longer holds is removed, the active one replaced as
    /// `browser_close_tab` does. A pull-request group whose pin went stays, unpinned (ruling 18).
    /// Ends in `arrange()`.
    mutating func reconcilePins(_ pins: [BrowserPin]) {
        let held = Set(pins.map(\.id))
        removePins { !held.contains($0) }
        for pin in pins { addPin(pin) }
        arrange()
    }

    /// Delta reconcile (ruling 14): only `remove` is taken out and only `add` put in, when the pane
    /// lacks it. A pin the pane already has keeps its live page (ruling 16); a tab pin's name is taken
    /// (names call 15).
    mutating func applyPin(add: BrowserPin?, remove: String?) {
        if let remove { removePins { $0 == remove } }
        if let add { addPin(add) }
        arrange()
    }

    /// Removes the tabs and groups whose pin `gone` matches, each group's tabs with it. A
    /// pull-request group only loses its pin.
    private mutating func removePins(_ gone: (String) -> Bool) {
        var removedGroups = Set<String>()
        for i in groups.indices {
            guard let pin = groups[i].pin, gone(pin) else { continue }
            if groups[i].kind == .pullRequests { groups[i].pin = nil } else { removedGroups.insert(groups[i].id) }
        }
        let ids = Set(tabs.filter { tab in
            if let pin = tab.pin, gone(pin) { return true }
            return tab.group.map { removedGroups.contains($0) } ?? false
        }.map(\.id))
        groups.removeAll { removedGroups.contains($0.id) }
        removeTabs(ids)
    }

    /// Puts `pin` in the pane when it lacks it: a tab at the end of the pinned tabs, a group of new
    /// tabs, or the pin on the pull-request group (made, empty and collapsed, when the pane has none).
    /// What it adds is unloaded and never becomes active (Rule 6). A tab pin the pane already shows
    /// only takes the pin's name (names call 15: a rename is deliberate, so it does not wait); its
    /// page is left alone (ruling 16).
    private mutating func addPin(_ pin: BrowserPin) {
        if let i = tabs.firstIndex(where: { $0.pin == pin.id }) {
            if pin.kind == .tab { tabs[i].name = pin.name }
            return
        }
        if groups.contains(where: { $0.pin == pin.id }) { return }
        switch pin.kind {
        case .tab:
            var tab = BrowserTab(id: takeTabId(), url: pin.url ?? "", title: pin.title ?? "", name: pin.name)
            tab.pin = pin.id
            tabs.append(tab)
        case .group:
            var members: [String] = []
            for t in pin.tabs ?? [] {
                let tab = BrowserTab(id: takeTabId(), url: t.url, title: t.title, name: t.name)
                tabs.append(tab)
                members.append(tab.id)
            }
            let id = newGroup(tabs: members, name: pin.name ?? "New Group", kind: .own, siteKey: nil)
            if let g = groups.firstIndex(where: { $0.id == id }) {
                groups[g].pin = pin.id
                groups[g].named = true
                if let colour = pin.colour { groups[g].colour = colour }
            }
        case .pullRequests:
            if let g = groups.firstIndex(where: { $0.kind == .pullRequests }) {
                groups[g].pin = pin.id
            } else {
                groups.append(BrowserGroup(id: "pr", name: "Pull Requests", colour: nextColour(), collapsed: true,
                                           kind: .pullRequests, pin: pin.id))
            }
        }
    }

    /// Removes the tabs `ids` names without keeping them for ⌘⇧T; when the selection was among them
    /// the tab now where the first of them was is selected, else the last (`browser_close_tab`'s rule).
    mutating func removeTabs(_ ids: Set<String>) {
        guard let first = tabs.firstIndex(where: { ids.contains($0.id) }) else { return }
        tabs.removeAll { ids.contains($0.id) }
        if let active, ids.contains(active) {
            self.active = nil
            if !tabs.isEmpty { select(min(first, tabs.count - 1)) }
        }
    }
}

extension PaneStore {
    /// Full reconcile of pane `paneId` with its project's pins (ruling 14). An unreadable file
    /// removes nothing and adds nothing: its reason goes on the pane whole (`pinsError`); a readable
    /// one clears it. Answers how many tabs the pane has after.
    @discardableResult
    public func browserReconcilePins(paneId: String, pins: Result<[BrowserPin], BrowserPinsUnreadable>) -> Int {
        updateBrowser(paneId: paneId, create: true) { s -> Int in
            switch pins {
            case .failure(let error):
                s.pinsError = error.reason
            case .success(let pins):
                s.pinsError = nil
                s.reconcilePins(pins)
            }
            return s.tabs.count
        }
    }

    /// Delta reconcile of pane `paneId` after a pin, unpin or *Update Pin* elsewhere (ruling 14). A
    /// pane this store holds nothing for is left for its own full reconcile. Answers how many tabs
    /// the pane has after; nil when it holds nothing.
    @discardableResult
    public func browserApplyPin(paneId: String, add: BrowserPin?, remove: String?) -> Int? {
        guard holds(BrowserPaneKind.self, paneId) else { return nil }
        return updateBrowser(paneId: paneId) { s -> Int in
            s.applyPin(add: add, remove: remove)
            return s.tabs.count
        }
    }
}
