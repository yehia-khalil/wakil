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
    public func browserRestore(paneId: String, tabs: [BrowserSavedTab], active: String?) {
        let chosen = tabs.contains { $0.id == active } ? active : tabs.first?.id
        var top = 0
        for t in tabs where t.id.hasPrefix("t") { top = max(top, Int(t.id.dropFirst()) ?? 0) }
        let highest = top
        updateBrowser(paneId: paneId, create: true) { s in
            s = .empty
            s.tabs = tabs.map { saved in
                BrowserTab(id: saved.id, url: saved.url, title: saved.title, loaded: false,
                           command: saved.id == chosen ? BrowserCommand(seq: 1, verb: .load(saved.url)) : nil,
                           fromSavedLayout: true)
            }
            s.active = chosen
            s.nextTab = highest + 1
        }
    }

    // MARK: - The seam: what a tab's web view reports. Never creates a pane; never issues a command.

    /// A tab's page state after a navigation event. A tab that is gone, or a pane that holds no
    /// browser, drops it. Marks the tab loaded; takes the zoom only when the report names one;
    /// leaves `command`, `active` and tab order alone.
    public func browserPageDidReport(paneId: String, tab: String, _ report: BrowserPageReport) {
        guard holds(BrowserPaneKind.self, paneId) else { return }
        updateBrowser(paneId: paneId) { s in
            guard let i = s.tabs.firstIndex(where: { $0.id == tab }) else { return }
            s.tabs[i].url = report.url
            s.tabs[i].title = report.title
            s.tabs[i].isLoading = report.isLoading
            s.tabs[i].progress = report.progress
            s.tabs[i].canGoBack = report.canGoBack
            s.tabs[i].canGoForward = report.canGoForward
            s.tabs[i].failure = report.failure
            if let zoom = report.zoom { s.tabs[i].zoom = zoom }
            s.tabs[i].loaded = true
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
    /// active. WebKit already made its web view, so it is loaded and carries no command. Returns
    /// the new id, or nil when the opener is gone.
    public func browserPageOpenedTab(paneId: String, opener: String, url: String) -> String? {
        guard holds(BrowserPaneKind.self, paneId) else { return nil }
        return updateBrowser(paneId: paneId) { s -> String? in
            guard let i = s.tabs.firstIndex(where: { $0.id == opener }) else { return nil }
            let id = "t\(s.nextTab)"
            s.nextTab += 1
            s.tabs.insert(BrowserTab(id: id, url: url, title: "", loaded: true), at: i + 1)
            s.active = id
            return id
        }
    }
}
