import AppKit
import SwiftUI
import WakilKit

// MARK: 3d-i — vertical tabs

/// The vertical tab column (3d-i, ruling 20): with Settings → Browser → Tabs on *Vertical*, the
/// pane's tabs in a column at its left under the address row, full height; the tab count is its
/// footer's, beside ＋ *New Tab* (3d-i walk). Rows 28 pt: pinned tabs, then each group's header —
/// a pill tinted with its colour — and, expanded, its tabs indented under one line in that colour,
/// then loose tabs, and ＋ at the bottom. The order and the entries are the strip's (`BrowserStripEntries`), and so are the chip,
/// the rename field and the menus (`BrowserGroupViews.swift`). A 1 pt divider at its right edge
/// drags its width, app-wide, 160–360 pt (`BrowserTabColumnRules`).
///
/// Every press is a `browser_*` action (Invariant 2). Rows are tapped, not focused: nothing here
/// takes the keyboard from the page or the address field (Rule 6) — but *New Group…* and a rename,
/// whose name field arrives focused (Rule 3).
struct BrowserTabColumn: View {
    let snapshot: BrowserSnapshot
    let favicon: (String) -> NSImage?
    /// Which sites are production and which the active environment's (3c-ii): each tagged tab's dot.
    let sites: BrowserSites
    let dispatch: (String, [String: JSONValue]) -> Void
    let menus: BrowserGroupMenuContext
    @Binding var renaming: String?
    /// The group header ⌘R acts on in this pane; nil, none.
    let headerFocus: String?
    let setHeaderFocus: (String?) -> Void
    /// The pinned tab waiting for ⌘W's second press in this pane.
    let closeArmed: String?
    /// The rename field went; `explicit` when Return or Esc ended it.
    let renameEnded: (_ explicit: Bool) -> Void
    /// Nothing is drawn over the canvas: a middle-click on a tab closes it (3d-i walk).
    var middleClickEnabled = false
    /// The pane's tab count, at the footer's right beside *New Tab* (3d-i walk: the vertical mode has
    /// no strip row to carry it).
    var count: (() -> BrowserTabCount)?

    @AppStorage("browser.tabColumn.width") private var width = BrowserTabColumnRules.width
    /// The width as the divider's drag began.
    @State private var dragStart: Double?
    @State private var hovered: String?
    @State private var newTabHovered = false
    /// A drag of entry `from`, and the gap (0…count) it would land in.
    @State private var drag: (from: Int, gap: Int)?

    private var presses: BrowserEntryPresses {
        BrowserEntryPresses(dispatch: dispatch, renaming: $renaming, headerFocus: headerFocus,
                            setHeaderFocus: setHeaderFocus)
    }

    static let rowHeight: CGFloat = 28
    static let indent: CGFloat = 12
    /// Each row's inset from the column's edges.
    static let rowInset: CGFloat = 6

    var body: some View {
        let list = BrowserStripEntries(snapshot)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, index: index, list: list)
                        }
                    }
                    .overlay(alignment: .topLeading) { groupLines(list) }
                    .overlay(alignment: .topLeading) { dropLine(list) }
                    .coordinateSpace(name: Self.space)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                // The pinned tab's tip hangs over the row below — outside the scroll view, so the
                // last row's is not clipped; shown while its row is in view.
                .overlayPreferenceValue(BrowserTabColumnTipAnchor.self) { anchor in
                    GeometryReader { proxy in
                        if let anchor, let tip = tip(list) {
                            let row = proxy[anchor]
                            if row.maxY > 0, row.minY < proxy.size.height {
                                PaneStripTipLabel(tip: tip)
                                    .offset(x: row.minX + Self.rowInset + Self.indent, y: row.maxY - 2)
                            }
                        }
                    }
                }
                footer
            }
            .frame(width: CGFloat(BrowserTabColumnRules.clamp(width)))
            divider
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .accessibilityIdentifier("browser.tabColumn")
    }

    private static let space = "browser.tabColumn.rows"

    // MARK: Rows

    /// Where a group's line runs, from the column's left: under the header's dot, so the colour
    /// flows from the dot down its members (`BrowserGroupChip`'s leading, chevron and spacing).
    static let lineX: CGFloat = rowInset + BrowserGroupChip.leading + BrowserGroupChip.chevronBox
        + BrowserGroupChip.spacing + BrowserGroupChip.dot / 2
    /// A member row's chip starts just right of the line, and its favicon in it lines up with the
    /// group's name in the header.
    static let memberLead: CGFloat = lineX + 6 - rowInset
    static let memberInner: CGFloat = BrowserGroupChip.dot / 2 + BrowserGroupChip.spacing - 6
    /// The line stops this short of a run's ends, and of the active row's tick.
    static let lineInset: CGFloat = 3

    @ViewBuilder
    private func row(_ entry: BrowserStripEntry, index: Int, list: BrowserStripEntries) -> some View {
        switch entry {
        case .chip(let g): interactive(header(g), entry: entry, index: index, list: list)
        case .tab(let t):
            interactive(tabRow(t, member: t.group.flatMap { snapshot.group($0) } != nil,
                               on: list.active == entry.id, lifted: hovered == entry.id),
                        entry: entry, index: index, list: list)
        }
    }

    /// A tab's row. A loose or pinned tab carries the rail's tick inside its chip; a group's member
    /// is indented past the group's line and carries none — on the active member the tick stands
    /// in the line's place (`groupLines`), so the two never sit side by side.
    private func tabRow(_ t: BrowserTab, member: Bool, on: Bool, lifted: Bool) -> some View {
        HStack(spacing: PaneStripStyle.tabGap) {
            if !member {
                LuminousTick(
                    colour: on ? PaneStripStyle.tick : nil, height: PaneStripStyle.tickHeight,
                    glowRadius: PaneStripStyle.tickGlowRadius)
            }
            tabContent(t, on: on, lifted: lifted)
        }
        .padding(.leading, member ? Self.memberInner : PaneStripStyle.tabLeading - 7)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PaneStripStyle.tabRadius, style: .continuous)
                .fill(BrowserPaneStyle.text.opacity(on ? PaneStripStyle.tabOnFill : (lifted ? PaneStripStyle.tabHoverFill : 0))))
        .overlay {
            if on {
                RoundedRectangle(cornerRadius: PaneStripStyle.tabRadius, style: .continuous)
                    .strokeBorder(BrowserPaneStyle.text.opacity(PaneStripStyle.edge), lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: PaneStripStyle.hoverDuration), value: lifted)
        .padding(.leading, member ? Self.memberLead : 0)
    }

    /// What every row shares: its inset, the drag, the press, the middle-click, the hover, the menu,
    /// the tooltip and how it reads in the accessibility tree.
    private func interactive(_ content: some View, entry: BrowserStripEntry, index: Int,
                             list: BrowserStripEntries) -> some View {
        let on = list.active == entry.id
        return content
        .padding(.horizontal, Self.rowInset)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { g in
                let gap = self.gap(at: g.location.y, count: list.entries.count)
                drag = target(list, from: index, gap: gap) != nil ? (index, gap) : nil
            }
            .onEnded { g in
                defer { drag = nil }
                let gap = self.gap(at: g.location.y, count: list.entries.count)
                if let params = target(list, from: index, gap: gap) { dispatch("browser_move_tab", params) }
            })
        .onTapGesture { presses.tap(entry) }
        // A middle-click on a tab closes it, as its × does (a pinned one too, in one press); a group's
        // header takes none.
        .background {
            if let tab = entry.middleClickCloses {
                BrowserRowMiddleClick(enabled: middleClickEnabled) {
                    dispatch("browser_close_tab", ["tab": .string(tab)])
                }
            }
        }
        .onHover { inside in hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered) }
        .contextMenu {
            switch entry {
            case .chip(let g): BrowserGroupMenu(group: g, context: menus)
            case .tab(let t): BrowserTabMenu(tab: t, context: menus)
            }
        }
        .help(BrowserEntryPresses.label(entry))
        .anchorPreference(key: BrowserTabColumnTipAnchor.self, value: .bounds) { bounds in
            tip(list)?.index == index ? bounds : nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrowserEntryPresses.label(entry))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { presses.activate(entry) }
        .accessibilityIdentifier(entry.identifier)
    }

    /// Each group's ONE line in its colour down its member rows (`BrowserSnapshot.memberRuns`), 2 pt,
    /// broken at the active member, where the rail's violet tick stands in its place.
    @ViewBuilder private func groupLines(_ list: BrowserStripEntries) -> some View {
        let active = list.entries.firstIndex { $0.id == list.active }
        let runs = snapshot.memberRuns
        ZStack(alignment: .topLeading) {
            ForEach(runs, id: \.group) { run in
                let colour = snapshot.group(run.group)?.colour.colour ?? .clear
                ForEach(run.segments(skipping: active), id: \.lowerBound) { rows in
                    RoundedRectangle(cornerRadius: 1).fill(colour)
                        .frame(width: 2, height: CGFloat(rows.count) * Self.rowHeight - 2 * Self.lineInset)
                        .offset(x: Self.lineX - 1, y: CGFloat(rows.lowerBound) * Self.rowHeight + Self.lineInset)
                }
            }
            if let active, runs.contains(where: { $0.rows.contains(active) }) {
                LuminousTick(colour: PaneStripStyle.tick, height: PaneStripStyle.tickHeight,
                             glowRadius: PaneStripStyle.tickGlowRadius)
                    .offset(x: Self.lineX - 1,
                            y: CGFloat(active) * Self.rowHeight + (Self.rowHeight - PaneStripStyle.tickHeight) / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func tabContent(_ tab: BrowserTab, on: Bool, lifted: Bool) -> some View {
        BrowserFavicon(image: favicon(tab.id))
            .overlay(alignment: .topTrailing) {
                if let tag = sites.tag(tab.url) {
                    BrowserSiteTagDot(tag: tag, tab: tab.id).offset(x: 3, y: -3)
                }
            }
        Text(tab.label)
            .font(.system(size: BrowserPaneStyle.tabTitleSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(BrowserPaneStyle.text.opacity(on ? 1 : PaneStripStyle.tabTitleRest))
        Spacer(minLength: 0)
        if lifted {
            Button { dispatch("browser_close_tab", ["tab": .string(tab.id)]) } label: {
                Image(systemName: "xmark").font(.system(size: PaneStripStyle.closeGlyph, weight: .semibold))
                    .frame(width: PaneStripStyle.closeHit, height: PaneStripStyle.closeHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChangesIconButtonStyle())
            .focusable(false)
            .transition(.opacity)
            .accessibilityLabel("Close \(tab.label)")
            .accessibilityIdentifier("browser.tab.\(tab.id).close")
        }
    }

    /// A group's header: the tinted pill (`BrowserGroupChip`) across the row, its chevron at the
    /// left, the member count at the right and, collapsed, its members' favicons before it.
    private func header(_ g: BrowserGroup) -> some View {
        BrowserGroupChip(
            group: g, favicons: snapshot.preview(of: g.id).map { favicon($0) },
            count: snapshot.members(of: g.id).count, column: true,
            refreshing: g.kind == .pullRequests && menus.refreshing, renaming: renaming == g.id,
            focused: headerFocus == g.id && g.kind == .pullRequests,
            commitName: { name in
                dispatch("browser_group", ["action": .string("rename"), "group": .string(g.id), "name": .string(name)])
            },
            endRename: { explicit in
                if renaming == g.id { renaming = nil }
                renameEnded(explicit)
            })
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight)
    }

    /// The pinned tab armed by ⌘W, as the strip names its tip.
    private func tip(_ list: BrowserStripEntries) -> PaneStripTip? {
        closeArmed.flatMap { tab in
            list.index(ofTab: tab).map {
                PaneStripTip(index: $0, text: BrowserPinnedClose.tip, identifier: "browser.tab.\(tab).closeTip")
            }
        }
    }

    /// The column's foot: ＋ *New Tab* (⌘T's `browser_new_tab`), and the tab count at its right.
    private var footer: some View {
        HStack(spacing: 0) {
            newTabRow
            if let count {
                count()
                    .padding(.horizontal, 6)
                    .frame(height: Self.rowHeight)
            }
        }
        .padding(.horizontal, Self.rowInset)
        .padding(.bottom, 4)
    }

    private var newTabRow: some View {
        Button { dispatch("browser_new_tab", [:]) } label: {
            HStack(spacing: PaneStripStyle.tabGap) {
                Image(systemName: "plus")
                    .font(.system(size: PaneStripStyle.newTabGlyph))
                    .frame(width: BrowserPaneStyle.glyphSize)
                Text("New Tab")
                    .font(.system(size: BrowserPaneStyle.tabTitleSize))
                Spacer(minLength: 0)
            }
            .foregroundStyle(BrowserPaneStyle.text.opacity(newTabHovered ? 1 : PaneStripStyle.tabTitleRest))
            .padding(.leading, PaneStripStyle.tabLeading - 7 + 2 + PaneStripStyle.tabGap)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PaneStripStyle.tabRadius, style: .continuous)
                .fill(BrowserPaneStyle.text.opacity(newTabHovered ? PaneStripStyle.tabHoverFill : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .animation(.easeOut(duration: PaneStripStyle.hoverDuration), value: newTabHovered)
        .onHover { newTabHovered = $0 }
        .help("New Tab (⌘T)")
        .accessibilityLabel("New Tab")
        .accessibilityIdentifier("browser.newTab")
    }

    /// The 1 pt edge at the column's right; dragged, the column's width, clamped 160–360.
    private var divider: some View {
        Rectangle().fill(BrowserPaneStyle.text.opacity(PaneStripStyle.hairline)).frame(width: 1)
            .padding(.horizontal, 2).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            // Global: the divider moves as the width follows it (DataSurface's column edge too).
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let start = dragStart ?? BrowserTabColumnRules.clamp(width)
                    dragStart = start
                    width = BrowserTabColumnRules.clamp(start + Double(g.translation.width))
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityHidden(true)
    }

    // MARK: Drag

    /// The gap a drag at `y` (in the rows' space, whose origin is the first row's top — the space is
    /// named inside the vertical padding) is nearest: 0 before the first row, `count` after the last.
    private func gap(at y: CGFloat, count: Int) -> Int {
        max(0, min(count, Int((y / Self.rowHeight).rounded())))
    }

    /// The move a drop of entry `from` in `gap` makes, counted without it (`BrowserStripEntries.move`).
    private func target(_ list: BrowserStripEntries, from: Int, gap: Int) -> [String: JSONValue]? {
        let to = gap > from ? gap - 1 : gap
        guard to != from else { return nil }
        return list.move(from: from, to: to)
    }

    @ViewBuilder private func dropLine(_ list: BrowserStripEntries) -> some View {
        if let drag {
            Rectangle().fill(BrowserPaneStyle.tick)
                .frame(height: 2)
                .padding(.horizontal, Self.rowInset)
                .offset(y: CGFloat(drag.gap) * Self.rowHeight - 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Where the pinned tab armed by ⌘W is drawn in the column, so its tip hangs outside the scroll view.
struct BrowserTabColumnTipAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The hidden column's edge (3d-i): a 6 pt zone at the pane's left. The pointer resting there 150 ms
/// slides the column out over the page; leaving it slides it back. Reduce Motion makes both a fade.
/// One view is both the zone and the peeked column, so the pointer that brought the column out is
/// inside it from the start. Nothing here moves the keyboard (Rule 6).
struct BrowserTabColumnPeek<Column: View>: View {
    /// While a group's name is being edited in the peeked column, it stays out.
    let holding: Bool
    @ViewBuilder let column: () -> Column

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var peeking = false
    @State private var inside = false
    @State private var wait: Task<Void, Never>?

    /// The slide's ease (design-language §7: eased, never snappy).
    static var duration: Double { 0.22 }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: CGFloat(BrowserTabColumnRules.edge))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel("Tab column edge")
                .accessibilityHint("Rest the pointer here to show the tabs")
                .accessibilityIdentifier("browser.tabColumn.edge")
            if peeking {
                column()
                    .background(PaneStripStyle.slab)
                    // The pane's bottom-left corner is the column's while it is out.
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: BrowserPaneStyle.paneRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 4)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
            }
        }
        // Out, the column's own width (its divider included); in, the zone's.
        .frame(width: peeking ? nil : CGFloat(BrowserTabColumnRules.edge), alignment: .leading)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { now in
            inside = now
            wait?.cancel()
            if now {
                guard !peeking else { return }
                wait = Task { @MainActor in
                    try? await Task.sleep(for: BrowserTabColumnRules.peekDelay)
                    guard !Task.isCancelled, inside else { return }
                    show(true)
                }
            } else if !holding {
                show(false)
            }
        }
        .onChange(of: holding) { _, now in if !now, !inside { show(false) } }
        .onDisappear { wait?.cancel() }
    }

    private func show(_ on: Bool) {
        guard peeking != on else { return }
        withAnimation(.easeOut(duration: Self.duration)) { peeking = on }
    }
}
