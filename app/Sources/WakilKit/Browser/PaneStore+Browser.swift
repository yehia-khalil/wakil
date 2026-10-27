import Foundation

// The browser kind's store methods (3c-i), and the seam its web views report through.
extension PaneStore {
    public func browserSnapshot(paneId: String) -> BrowserSnapshot { contents(BrowserPaneKind.self, paneId) }

    /// Reads, changes and writes a browser pane's snapshot in one actor turn, as `updateEditor`: a
    /// pane this store holds nothing for gets an entry only when `create` says so.
    @discardableResult
    public func updateBrowser<T: Sendable>(
        paneId: String, create: Bool = false, _ change: @Sendable (inout BrowserSnapshot) -> T
    ) -> T {
        var s = browserSnapshot(paneId: paneId)
        let result = change(&s)
        if holdsContents(paneId: paneId) || create { setContents(BrowserPaneKind.self, paneId, s) }
        return result
    }

    /// Puts back a pane's saved tabs (`browser_restore`). Ids are kept; **only the active tab — or the
    /// first, when `active` names none — gets a load**, so a restored window does not fetch every
    /// page at once. Every tab starts unloaded; the rest load when shown.
    ///
    /// Groups come back in their saved order (3d-i), and `nextGroup` one past the highest `g<n>`. A
    /// tab naming a group that did not come back is loose, and a group's `lastOpen` naming a tab that
    /// did not (a pull-request tab is never saved) is cleared.
    public func browserRestore(
        paneId: String, tabs: [BrowserSavedTab], active: String?, groups: [BrowserGroup], columnHidden: Bool
    ) {
        let chosen = tabs.contains { $0.id == active } ? active : tabs.first?.id
        let highestTab = Self.highestNumber(tabs.map(\.id), prefix: "t")
        let highestGroup = Self.highestNumber(groups.map(\.id), prefix: "g")
        let groupIds = Set(groups.map(\.id))
        let tabIds = Set(tabs.map(\.id))
        updateBrowser(paneId: paneId, create: true) { s in
            s = .empty
            s.tabs = tabs.map { saved in
                BrowserTab(id: saved.id, url: saved.url, title: saved.title, loaded: false,
                           command: saved.id == chosen ? BrowserCommand(seq: 1, verb: .load(saved.url)) : nil,
                           fromSavedLayout: true,
                           group: saved.group.flatMap { groupIds.contains($0) ? $0 : nil }, opener: saved.opener,
                           pin: saved.pin, keptLoose: saved.keptLoose)
            }
            s.active = chosen
            s.nextTab = highestTab + 1
            s.groups = groups.map { g in
                var g = g
                if let open = g.lastOpen, !tabIds.contains(open) { g.lastOpen = nil }
                return g
            }
            s.nextGroup = highestGroup + 1
            s.tabColumnHidden = columnHidden
        }
    }

    /// The highest `n` among ids of the form `<prefix><n>`; 0 when none.
    private static func highestNumber(_ ids: [String], prefix: String) -> Int {
        ids.filter { $0.hasPrefix(prefix) }.compactMap { Int($0.dropFirst(prefix.count)) }.max() ?? 0
    }

    // MARK: - The seam: what a tab's web view reports. Never creates a pane; never issues a command.

    /// A tab's page state after a navigation event. A tab that is gone, or a pane that holds no
    /// browser, drops it. Marks the tab loaded; takes the zoom only when the report names one;
    /// leaves `command` and `active` alone.
    ///
    /// A report that **ends a load** (loading before, not now, no failure) runs the site rule on the
    /// tab's address then (ruling 7), which may group it; no other report moves a tab, so a redirect
    /// through a sign-in host never regroups one.
    public func browserPageDidReport(paneId: String, tab: String, _ report: BrowserPageReport) {
        guard holds(BrowserPaneKind.self, paneId) else { return }
        updateBrowser(paneId: paneId) { s in
            guard let i = s.tabs.firstIndex(where: { $0.id == tab }) else { return }
            let endsALoad = s.tabs[i].isLoading && !report.isLoading && report.failure == nil
            // A new address is a new page: the agent's read of the old one no longer applies.
            if s.tabs[i].url != report.url { s.tabs[i].lastRead = nil }
            s.tabs[i].url = report.url
            s.tabs[i].title = report.title
            s.tabs[i].isLoading = report.isLoading
            s.tabs[i].progress = report.progress
            s.tabs[i].canGoBack = report.canGoBack
            s.tabs[i].canGoForward = report.canGoForward
            s.tabs[i].failure = report.failure
            if let zoom = report.zoom { s.tabs[i].zoom = zoom }
            s.tabs[i].loaded = true
            if endsALoad { s.placeLoaded(tab: tab) }
        }
    }

    /// The find bar's match count. Dropped when the bar is closed.
    public func browserFindDidReport(paneId: String, current: Int, total: Int) {
        guard holds(BrowserPaneKind.self, paneId) else { return }
        updateBrowser(paneId: paneId) { s in
            guard s.find != nil else { return }
            s.find?.current = current
            s.find?.total = total
        }
    }

    /// A download started or changed: replaced in place by id, so the list keeps the order downloads
    /// began in; a new one is appended. A pending cancel ask is kept while the download still runs;
    /// a final state clears it.
    public func browserDownloadDidChange(paneId: String, _ download: BrowserDownload) {
        guard holds(BrowserPaneKind.self, paneId) else { return }
        updateBrowser(paneId: paneId) { s in
            if let i = s.downloads.firstIndex(where: { $0.id == download.id }) {
                var d = download
                if d.state == .running { d.cancelRequested = d.cancelRequested || s.downloads[i].cancelRequested }
                s.downloads[i] = d
            }
            else { s.downloads.append(download) }
        }
    }

    /// A page opened a window (`window.open`, `target=_blank`): a new tab right of its opener, made
    /// active. WebKit already made its web view, so it is loaded and carries no command. The opener
    /// rule places it (ruling 8). Returns the new id, or nil when the opener is gone.
    public func browserPageOpenedTab(paneId: String, opener: String, url: String) -> String? {
        guard holds(BrowserPaneKind.self, paneId) else { return nil }
        return updateBrowser(paneId: paneId) { s -> String? in
            guard let i = s.tabs.firstIndex(where: { $0.id == opener }) else { return nil }
            let id = "t\(s.nextTab)"
            s.nextTab += 1
            s.tabs.insert(BrowserTab(id: id, url: url, title: "", loaded: true), at: i + 1)
            s.active = id
            s.placeOpenedKnowingTheSite(tab: id, opener: opener)
            return id
        }
    }

    /// Ruling 12's guard: the model's name lands only on a group that still exists, is still
    /// automatic and is not yet named; it then is. False, and nothing changes, otherwise.
    @discardableResult
    public func browserNameGroup(paneId: String, group: String, name: String) -> Bool {
        guard holds(BrowserPaneKind.self, paneId) else { return false }
        return updateBrowser(paneId: paneId) { s -> Bool in
            guard let i = s.groups.firstIndex(where: { $0.id == group }),
                  s.groups[i].kind == .automatic, !s.groups[i].named else { return false }
            s.groups[i].name = name
            s.groups[i].named = true
            return true
        }
    }

    // MARK: - 3c-ii: the organisation's sites, each tab's read and the per-conversation allow-list

    public func browserSetSites(org: String, _ sites: BrowserSites) {
        var shared = kindState(BrowserPaneKind.self)
        shared.sites[org] = sites
        setKindState(BrowserPaneKind.self, shared)
    }

    public func browserSetBookmarks(org: String, _ b: [BrowserBookmark]) {
        var shared = kindState(BrowserPaneKind.self)
        shared.bookmarks[org] = b
        setKindState(BrowserPaneKind.self, shared)
    }

    /// `[]` when never set.
    public func browserBookmarks(org: String) -> [BrowserBookmark] {
        kindState(BrowserPaneKind.self).bookmarks[org] ?? []
    }

    /// `.unread` when never set: every site then counts as production.
    public func browserSites(org: String) -> BrowserSites {
        kindState(BrowserPaneKind.self).sites[org] ?? .unread
    }

    /// Site keys (`BrowserSite.key`) the conversation allowed. Callers never pass a raw host.
    public func browserAllowed(conversation: String) -> Set<String> {
        kindState(BrowserPaneKind.self).allowed[conversation] ?? []
    }

    public func browserAllow(site: String, conversation: String) {
        var shared = kindState(BrowserPaneKind.self)
        shared.allowed[conversation, default: []].insert(site)
        setKindState(BrowserPaneKind.self, shared)
    }

    public func browserRevoke(site: String, conversation: String) {
        var shared = kindState(BrowserPaneKind.self)
        guard shared.allowed[conversation]?.contains(site) == true else { return }
        shared.allowed[conversation]?.remove(site)
        if shared.allowed[conversation]?.isEmpty == true { shared.allowed[conversation] = nil }
        setKindState(BrowserPaneKind.self, shared)
    }

    /// The conversation ended: forgets its sites and no other's.
    public func browserForget(conversation: String) {
        var shared = kindState(BrowserPaneKind.self)
        guard shared.allowed[conversation] != nil else { return }
        shared.allowed[conversation] = nil
        setKindState(BrowserPaneKind.self, shared)
    }

    /// Keeps the elements the agent was given refs for. False when the tab is gone, or when the read
    /// began at `firstRef` and another read of the tab has since issued that ref (two reads overlapped:
    /// a ref must pin one element). Raises `refsIssued` past the highest `e<n>` given, and past
    /// `highestRef` — refs the script issued that the cap left out — so a ref is never reused in a tab.
    @discardableResult
    public func browserRecordRead(paneId: String, tab: String, url: String, site: String,
                                  elements: [BrowserElement], firstRef: Int? = nil,
                                  highestRef: Int? = nil) -> Bool {
        guard holds(BrowserPaneKind.self, paneId) else { return false }
        return updateBrowser(paneId: paneId) { s -> Bool in
            guard let i = s.tabs.firstIndex(where: { $0.id == tab }) else { return false }
            if let firstRef, firstRef <= s.tabs[i].refsIssued { return false }
            var byRef: [String: BrowserElement] = [:]
            var highest = max(s.tabs[i].refsIssued, highestRef ?? 0)
            for e in elements {
                byRef[e.ref] = e
                if e.ref.hasPrefix("e"), let n = Int(e.ref.dropFirst()) { highest = max(highest, n) }
            }
            s.tabs[i].lastRead = BrowserReadStamp(url: url, site: site, elements: byRef)
            s.tabs[i].refsIssued = highest
            return true
        }
    }

    public func browserDropRead(paneId: String, tab: String) {
        guard holds(BrowserPaneKind.self, paneId) else { return }
        updateBrowser(paneId: paneId) { s in
            guard let i = s.tabs.firstIndex(where: { $0.id == tab }) else { return }
            s.tabs[i].lastRead = nil
        }
    }
}
