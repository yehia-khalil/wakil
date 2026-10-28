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

    /// The tab a middle-click on this entry closes, as its × does — a pinned one too, in one press;
    /// a group's chip takes none (3d-i walk).
    public var middleClickCloses: String? {
        if case .tab(let t) = self { return t.id }
        return nil
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

/// A group's member rows in the tab list (3d-i walk): the entries a group's shown tabs take, one
/// after another under its header. The vertical column draws ONE line in the group's colour down
/// them, not a mark per row.
public struct BrowserMemberRun: Equatable, Sendable {
    public let group: String
    /// Indexes into `stripEntries`.
    public let rows: ClosedRange<Int>

    public init(group: String, rows: ClosedRange<Int>) {
        self.group = group
        self.rows = rows
    }

    /// Where the line is drawn: the run, broken at the active row, whose tick takes the line's place
    /// there so the two never stand side by side as a double bar.
    public func segments(skipping active: Int?) -> [ClosedRange<Int>] {
        guard let active, rows.contains(active) else { return [rows] }
        var out: [ClosedRange<Int>] = []
        if active > rows.lowerBound { out.append(rows.lowerBound...(active - 1)) }
        if active < rows.upperBound { out.append((active + 1)...rows.upperBound) }
        return out
    }
}

extension BrowserSnapshot {
    /// Every tab of the group, shown or not, in order: the count its header shows.
    public func members(of group: String) -> [BrowserTab] {
        tabs.filter { $0.group == group }
    }

    /// The tabs whose favicons a collapsed group's header shows, overlapping: up to `limit`, the one
    /// last open first (the tab the group stands for), then the rest in order.
    public func preview(of group: String, limit: Int = 3) -> [String] {
        let ids = members(of: group).map(\.id)
        guard let last = self.group(group)?.lastOpen, ids.contains(last) else { return Array(ids.prefix(limit)) }
        return Array(([last] + ids.filter { $0 != last }).prefix(limit))
    }

    /// Each group's member rows in `stripEntries`, in drawn order; a group showing none has no run.
    public var memberRuns: [BrowserMemberRun] {
        var out: [BrowserMemberRun] = []
        for (i, entry) in stripEntries.enumerated() {
            guard case .tab(let t) = entry, let gid = t.group, group(gid) != nil else { continue }
            if let last = out.last, last.group == gid, last.rows.upperBound == i - 1 {
                out[out.count - 1] = BrowserMemberRun(group: gid, rows: last.rows.lowerBound...i)
            } else {
                out.append(BrowserMemberRun(group: gid, rows: i...i))
            }
        }
        return out
    }
}
