import Foundation

/// 3d-i: the grouping rules, pure. How tabs form, join, leave and dissolve automatic groups by site
/// and by opener (rulings 8 and 9), how a group becomes the operator's own (ruling 11), the drawn
/// order (ruling 4), colours (ruling 5) and the collapsed group's tab (ruling 21). Every mutating
/// rule ends with `arrange()`. None of them changes `active` (Rule 6).
extension BrowserSnapshot {
    /// The group with this id, if the pane has it.
    public func group(_ id: String) -> BrowserGroup? { groups.first { $0.id == id } }

    /// Ruling 3: pinned itself, or in a pinned group.
    public func isPinned(_ tab: BrowserTab) -> Bool {
        if tab.pin != nil { return true }
        return tab.group.flatMap { group($0) }?.pin != nil
    }

    /// Ruling 8, run when `tab` is made from `opener`: it joins the opener's group (not the
    /// pull-request group, nor a pinned group: a pinned group is closed to pop-ups, as a pinned
    /// opener is); or a loose, unpinned, not-kept-loose opener of another site forms an automatic
    /// chain group with it; otherwise it gets no opener and waits for the site rule.
    public mutating func placeOpened(tab: String, opener: String) {
        defer { arrange() }
        guard let t = tabIndex(tab), let o = tabIndex(opener), t != o, tabs[t].pullRequest == nil else { return }
        let openerTab = tabs[o]
        if let gid = openerTab.group, let g = group(gid) {
            if g.kind != .pullRequests, g.pin == nil {
                tabs[t].group = gid
                tabs[t].opener = opener
                tabs[t].keptLoose = false
                return
            }
        } else if !isPinned(openerTab), !openerTab.keptLoose, openerTab.pullRequest == nil,
                  BrowserSiteKey.of(tabs[t].url) != BrowserSiteKey.of(openerTab.url) {
            let name = Self.threeWords(openerTab.title)
                ?? Self.fallbackName(siteKey: BrowserSiteKey.of(openerTab.url), openerTitle: nil)
            newGroup(tabs: [opener, tab], name: name, kind: .automatic, siteKey: nil)
            if let t = tabIndex(tab) { tabs[t].opener = opener }
            return
        }
        tabs[t].opener = nil
    }

    /// Ruling 9, run when `tab`'s load finishes. A pinned, kept-loose or pull-request tab never moves.
    ///
    /// Review Focus 1: a tab already placed moves only after **two** consecutive finished loads on a
    /// site other than the one it was placed on, so a sign-in page that finishes loading on its way
    /// back (an SSO page, a SAML auto-submit) neither takes it out of its group nor starts one. A
    /// finished load back on its site clears the wait. A tab never placed is placed at once.
    public mutating func placeLoaded(tab: String) {
        defer { arrange() }
        guard let t = tabIndex(tab) else { return }
        let current = tabs[t]
        guard !isPinned(current), !current.keptLoose, current.pullRequest == nil else { return }
        let key = BrowserSiteKey.of(current.url)
        let site = key ?? ""
        var siteGroup: String?
        if let gid = current.group, let g = group(gid) {
            switch g.kind {
            case .own, .pullRequests: return
            case .automatic:
                // A tab that came by opener stays; so does any tab of an opener chain (no site key).
                if current.opener != nil || g.siteKey == nil { return }
                siteGroup = g.siteKey
            }
        }
        if let placed = current.placedSite ?? siteGroup, placed != site, current.pendingSite == nil {
            tabs[t].pendingSite = site
            return
        }
        tabs[t].pendingSite = nil
        tabs[t].placedSite = site
        if let siteGroup {
            if siteGroup == key { return }
            tabs[t].group = nil
            tabs[t].opener = nil
        }
        guard let key else { return }
        if let g = groups.first(where: { $0.kind == .automatic && $0.siteKey == key }) {
            tabs[t].group = g.id
            return
        }
        let mates = tabs.filter {
            $0.id != tab && $0.group == nil && !isPinned($0) && !$0.keptLoose && $0.pullRequest == nil
                && BrowserSiteKey.of($0.url) == key
        }
        guard !mates.isEmpty else { return }
        let members = tabs.filter { $0.id == tab || mates.map(\.id).contains($0.id) }.map(\.id)
        newGroup(tabs: members, name: Self.fallbackName(siteKey: key, openerTitle: nil),
                 kind: .automatic, siteKey: key)
    }

    /// A new group of these tabs, id `g<nextGroup>`, coloured `nextColour()`, appended to `groups`.
    /// An own group is the operator's act: its tabs lose `keptLoose`, and an automatic group they
    /// leave becomes own (ruling 11).
    @discardableResult
    public mutating func newGroup(tabs members: [String], name: String, kind: BrowserGroupKind,
                                  siteKey: String?) -> String {
        let id = "g\(nextGroup)"
        nextGroup += 1
        groups.append(BrowserGroup(id: id, name: name, colour: nextColour(), kind: kind, siteKey: siteKey))
        for member in members {
            guard let i = tabIndex(member), tabs[i].pin == nil else { continue }
            if kind == .own {
                if let old = tabs[i].group { makeOwnOnly(old) }
                tabs[i].keptLoose = false
            }
            leavePullRequests(i)
            tabs[i].group = id
            tabs[i].opener = nil
        }
        arrange()
        return id
    }

    /// A tab taken out of the pull-request group by hand is a plain tab: it stops being a listed
    /// pull request, so a refresh neither duplicates it nor leaves it out of the saved layout.
    private mutating func leavePullRequests(_ i: Int) {
        if let g = tabs[i].group, group(g)?.kind == .pullRequests { tabs[i].pullRequest = nil }
    }

    /// Ruling 11: an automatic group becomes the operator's, in the same place.
    public mutating func makeOwn(_ group: String) {
        makeOwnOnly(group)
        arrange()
    }

    /// The operator moves a tab: `nil` takes it out (loose, `keptLoose`); into a group clears
    /// `keptLoose`. An automatic group it enters or leaves becomes own. `index` is where it lands in
    /// `tabs` once taken out (as `browser_move_tab`'s `to`, clamped); nil keeps its place, or puts it
    /// after the group's last tab. Never into the pull-request group.
    public mutating func moveTab(_ tab: String, into target: String?, at index: Int?) {
        defer { arrange() }
        guard let i = tabIndex(tab) else { return }
        if let target {
            guard let g = group(target), g.kind != .pullRequests, tabs[i].pin == nil else { return }
        }
        let old = tabs[i].group
        if old != target {
            if let old { makeOwnOnly(old) }
            if let target { makeOwnOnly(target) }
        }
        leavePullRequests(i)
        var moved = tabs.remove(at: i)
        moved.group = target
        moved.opener = nil
        // Ruling 10: out of a group marks it; a loose tab reordered keeps what it had.
        moved.keptLoose = target == nil && (old != nil || moved.keptLoose)
        let at: Int
        if let index {
            at = max(0, min(index, tabs.count))
        } else if let target, old != target, let last = tabs.lastIndex(where: { $0.group == target }) {
            at = last + 1
        } else {
            at = i
        }
        tabs.insert(moved, at: at)
    }

    /// The strip's drag: the group of the tab `tab` lands before, `index` counted in `tabs` with
    /// `tab` taken out (as `moveTab`'s); at the end, loose (nil).
    public func dropGroup(moving tab: String, before index: Int) -> String? {
        let others = tabs.filter { $0.id != tab }
        guard index >= 0, index < others.count else { return nil }
        return others[index].group
    }

    /// Ruling 5: the first swatch no group in the pane uses, else swatch `groups.count % 6`.
    public func nextColour() -> BrowserGroupColour {
        let all = BrowserGroupColour.allCases
        let used = Set(groups.map(\.colour))
        return all.first { !used.contains($0) } ?? all[groups.count % all.count]
    }

    /// Ruling 4's order — pinned tabs, pinned groups, the pull-request group, every other group in
    /// the order it was made, loose tabs — stable within a section. An automatic group of one
    /// dissolves; an empty own group is removed; a tab naming no group is loose and loses its
    /// opener. Sets each group's `lastOpen` (ruling 21). `groups` keeps the order they were made.
    public mutating func arrange() {
        // Tabs naming a group the pane lacks are loose.
        for i in tabs.indices {
            if let gid = tabs[i].group, group(gid) == nil { tabs[i].group = nil }
        }
        // Dissolve automatic groups of one; drop empty own groups. The pull-request group stays.
        var dissolved = Set<String>()
        groups.removeAll { g in
            let members = tabs.indices.filter { tabs[$0].group == g.id }
            switch g.kind {
            case .automatic:
                guard members.count <= 1 else { return false }
                for i in members { tabs[i].group = nil; dissolved.insert(tabs[i].id) }
                return true
            case .own: return members.isEmpty
            case .pullRequests: return false
            }
        }
        for i in tabs.indices where tabs[i].group == nil { tabs[i].opener = nil }

        let order = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        func rank(_ tab: BrowserTab) -> (Int, Int) {
            guard let gid = tab.group, let g = group(gid), let n = order[gid] else {
                // A dissolved group's last tab leads the loose tabs.
                return (tab.pin != nil ? 0 : 4, dissolved.contains(tab.id) ? -1 : 0)
            }
            if g.pin != nil { return (1, n) }
            if g.kind == .pullRequests { return (2, n) }
            return (3, n)
        }
        tabs = tabs.enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                if ra != rb { return ra < rb }
                return a.offset < b.offset
            }
            .map(\.element)

        for gi in groups.indices {
            let id = groups[gi].id
            let members = tabs.filter { $0.group == id }.map(\.id)
            if let active, members.contains(active) {
                groups[gi].lastOpen = active
            } else if !(groups[gi].lastOpen.map { members.contains($0) } ?? false) {
                groups[gi].lastOpen = members.first
            }
        }
    }

    /// A group's name before (or without) the model's: the site's name, else the opener's title cut
    /// to three words, else `New Group`.
    public static func fallbackName(siteKey: String?, openerTitle: String?) -> String {
        if let siteKey { return BrowserSiteKey.name(siteKey) }
        return openerTitle.flatMap(threeWords) ?? "New Group"
    }

    // MARK: Helpers

    private func tabIndex(_ id: String) -> Int? { tabs.firstIndex { $0.id == id } }

    private mutating func makeOwnOnly(_ id: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }), groups[i].kind == .automatic else { return }
        groups[i].kind = .own
    }

    /// The first three whitespace-separated words, joined by single spaces; nil when there are none.
    private static func threeWords(_ title: String) -> String? {
        let words = title.split(whereSeparator: \.isWhitespace).prefix(3)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}

/// The vertical tab column's numbers (ruling 20): 220 pt wide by default, a drag of its edge keeps it
/// within 160–360 pt; hidden, a 6 pt zone at the pane's left shows it after the pointer rests 150 ms.
public enum BrowserTabColumnRules {
    public static let width: Double = 220
    public static let minWidth: Double = 160
    public static let maxWidth: Double = 360
    /// The hover zone at the pane's left edge while the column is hidden.
    public static let edge: Double = 6
    /// How long the pointer rests in the zone before the column slides out.
    public static let peekDelay: Duration = .milliseconds(150)

    /// A width within 160–360.
    public static func clamp(_ width: Double) -> Double { min(maxWidth, max(minWidth, width)) }
}
