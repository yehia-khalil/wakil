import Foundation

/// One entry of a browser pane's tab list: a group's chip, or a tab.
public enum BrowserStripEntry: Equatable, Sendable {
    case chip(BrowserGroup)
    case tab(BrowserTab)

    /// Unique in the list: a tab is its id (`t<n>`), a chip `group:<id>`.
    public var id: String {
        switch self {
        case .chip(let g): "group:\(g.id)"
        case .tab(let t): t.id
        }
    }

    /// `browser.group.<id>` for a chip, `browser.tab.<id>` for a tab.
    public var identifier: String {
        switch self {
        case .chip(let g): "browser.group.\(g.id)"
        case .tab(let t): "browser.tab.\(t.id)"
        }
    }
}

extension BrowserSnapshot {
    /// Whether the tab list draws this tab: a loose tab and an expanded group's tabs always; a
    /// collapsed group's only while it is the pane's active tab (3d-i walk: it shows under the
    /// header as a member row would, so the page you are on is never hidden). The rest are left out.
    public func showsTab(_ tab: BrowserTab) -> Bool {
        guard let gid = tab.group, let g = group(gid), g.collapsed else { return true }
        return tab.id == active
    }

    /// What a pane's tab list shows, in drawn order (`tabs` is kept so by `arrange()`, ruling 4):
    /// each group's chip before its first tab, a collapsed group's tabs left out but for the active
    /// one (`showsTab`), and the pull-request group's chip in its place even while it holds no tab.
    public var stripEntries: [BrowserStripEntry] {
        var out: [BrowserStripEntry] = []
        var shown = Set<String>()
        for tab in tabs {
            if let gid = tab.group, let g = group(gid) {
                if !shown.contains(gid) {
                    shown.insert(gid)
                    out.append(.chip(g))
                }
                if showsTab(tab) { out.append(.tab(tab)) }
            } else {
                out.append(.tab(tab))
            }
        }
        // An empty pull-request group: after the pinned section, before every other group and the
        // loose tabs.
        if let pr = groups.first(where: { $0.kind == .pullRequests }), !shown.contains(pr.id) {
            let at = out.firstIndex { entry in
                switch entry {
                case .chip(let g): g.pin == nil
                case .tab(let t): t.group == nil && t.pin == nil
                }
            } ?? out.count
            out.insert(.chip(pr), at: at)
        }
        return out
    }

    /// The entry the strip raises: the active tab. It is always drawn (`showsTab`), a collapsed
    /// group's under its header; the header itself is never the raised one.
    public var stripActive: String? { activeTab?.id }
}
