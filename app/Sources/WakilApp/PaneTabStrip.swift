import AppKit
import SwiftUI
import WakilKit

/// **The compact chrome** (2026-10-26) — the browser's since 3c-i, then the editor's and the
/// terminal's: a pane whose content runs to the slab's border (`Pane.edgeToEdge`) names itself
/// with a glyph at the left of a 32 pt header row, a hairline under it. The numbers are
/// `Browser.dc.html`'s, each read from a token another surface already draws with — the rail's
/// tick and row lift, the settings form's micro-label and field edge, the editor's rule — and
/// named here once, for every pane that draws the strip. `design-language.md` §11, "The compact
/// chrome".
enum PaneStripStyle {
    static let text = EditorPaneStyle.text
    static let slab = EditorPaneStyle.slab
    /// The rail's active tick, `#9e82ff` (`RailTreatment.activeTickColour`).
    static let tick = Color(RailTreatment.activeTickColour)

    // MARK: The row

    /// A header row: 32 pt (`Browser.dc.html`'s 30 px entries in their own 38 pt row, and a 48 pt
    /// address row, gave the page 230 pt less than the pane).
    static let rowHeight: CGFloat = 32
    /// A row's inset from the pane's edge.
    static let rowInset: CGFloat = 8
    /// The slab's corner (`Canvas.paneView`'s 10): the content's bottom corners, edge to edge.
    static let paneRadius: CGFloat = 10
    /// The pane's own glyph at the row's left, in the label's place, its square and the room after it.
    static let paneGlyph: CGFloat = 12
    static let glyphBox: CGFloat = 22
    static let glyphTrailing: CGFloat = 4
    /// The terminal's inner gutter: its text never meets the border it runs to.
    static let gutter: CGFloat = 6
    /// The room `resize` takes in an edge-to-edge pane's bottom-right corner (`Canvas`'s
    /// `EdgeToEdgePane` draws it over the content): a row along the pane's foot ends this far in,
    /// so its last control is not under the handle.
    static let resizeCorner: CGFloat = 56

    // MARK: The tokens

    /// **The border token**: cool white at 0.14 — the settings form's field edge and the prompt
    /// card's. The active tab chip's edge and an edge-to-edge pane's own border.
    static let edge: Double = 0.14
    /// **The hairline**: cool white at 0.08, the editor's rule between the Changes view's roots and
    /// under its timeline. Between tabs at rest and under a header row.
    static let hairline: Double = 0.08

    // MARK: The entries — `.tab`, drawn in the rail's language

    /// One entry, inside the 32 pt row: `.tab { padding: 0 11px 0 9px; gap: 9px; border-radius: 5px }`.
    static let tabHeight: CGFloat = 26
    static let tabLeading: CGFloat = 9
    static let tabTrailing: CGFloat = 11
    static let tabGap: CGFloat = 9
    static let tabRadius: CGFloat = 5
    /// Between entries: a 1 px hairline of `separatorHeight`, `separatorGap` either side — drawn
    /// only between two entries at rest, so the raised chip and a lifted entry carry no rule
    /// against them.
    static let separatorHeight: CGFloat = 14
    static let separatorGap: CGFloat = 2
    static var separatorWidth: CGFloat { 1 + 2 * separatorGap }
    /// A whole entry's width while it may shrink (`TabStripLayout.fullWidth`, one width so entries
    /// do not jump).
    static let tabWidth = CGFloat(TabStripLayout.fullWidth)
    /// The ＋ entry, `.tab { padding: 0 10px }` round a 12 pt plus, pinned at the strip's right
    /// outside its scrolling: one fixed width, so the room left for the entries is known.
    static let newTabGlyph: CGFloat = 12
    static let newTabWidth: CGFloat = 32
    /// Overflow (2026-10-26): each side's `‹ 3` / `8 ›` count takes a slot this wide beside the
    /// scrolling entries while they overflow, and the entries fade over this much of that edge.
    static let overflowSlot: CGFloat = 34
    static let overflowFade: CGFloat = 24
    static let overflowGlyph: CGFloat = 8
    /// The active entry is a raised chip: `.tab.on`'s lift stepped up to 0.08, and the border
    /// token's edge round it.
    static let tabOnFill: Double = 0.08
    /// `.tab:hover`: the rail's row lift (`Rail.dc.html` state 3).
    static let tabHoverFill = RailTreatment.rowHoverTint
    /// `.tab .ttl` at 0.62 at rest and the full cool white on the active tab.
    static let tabTitleRest: Double = 0.62
    /// `.tab .tick { width: 2px; height: 15px }` and its `0 0 7px` glow.
    static let tickHeight: CGFloat = 15
    static let tickGlowRadius: CGFloat = 3.5
    /// `.tab .x`: the Changes view's row action (a 9 pt glyph in its 16 pt square).
    static let closeGlyph: CGFloat = 9
    static let closeHit: CGFloat = 16
    /// `.act`'s hover fade, the rail's row duration.
    static let hoverDuration = RailTreatment.rowHoverDuration
}

/// A 1 px rule in the hairline token, across the pane: under a header row, and either side of a
/// row the browser's find bar or downloads take.
struct PaneHairline: View {
    var body: some View {
        Rectangle().fill(PaneStripStyle.text.opacity(PaneStripStyle.hairline))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The pane's glyph in the label's place: the kind's name as its help and its accessibility name.
struct PaneGlyph: View {
    let symbol: String
    let name: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: PaneStripStyle.paneGlyph))
            .foregroundStyle(PaneStripStyle.text.opacity(RailTreatment.kindOpacity))
            .frame(width: PaneStripStyle.glyphBox, height: PaneStripStyle.glyphBox)
            .padding(.trailing, PaneStripStyle.glyphTrailing)
            .help(name)
            .accessibilityLabel(name)
    }
}

/// A pane's first header row, 32 pt: its glyph, then what the kind puts there — the browser's and
/// the editor's tab strip, the terminal's title and controls.
struct PaneStripRow<Content: View>: View {
    let glyph: String
    let name: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            PaneGlyph(symbol: glyph, name: name)
            content()
        }
        .padding(.horizontal, PaneStripStyle.rowInset)
        .frame(height: PaneStripStyle.rowHeight)
    }
}

/// A count in the strip — the browser's tab count, a side's hidden count: the micro-label's size
/// and colour with tabular digits and none of its tracking, which spread 15 into "1 5".
struct PaneStripNumber: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.system(size: SettingsScale.micro, weight: .medium).monospacedDigit())
            .foregroundStyle(PaneStripStyle.text.opacity(RailTreatment.kindOpacity))
            .lineLimit(1)
            .fixedSize()
    }
}

/// How wide a strip's entries are.
enum PaneTabWidth: Equatable {
    /// 200 pt while they fit, then shrinking evenly (`TabStripLayout.widths`): the browser's.
    case shrink
    /// One fixed width: the browser's folded strip, favicon and ×.
    case fixed(CGFloat)
    /// Each entry its own width, never shrunk: the editor's, whose tabs are file names.
    case natural
}

/// How an entry reads in the accessibility tree.
enum PaneTabAccessibility: Equatable {
    /// A button named by `label`, its children kept (the browser's: its × is its own element).
    case button
    /// One static text, its children combined (the editor's: as a button its title never reached
    /// the tree, AXDescription only).
    case text
}

/// The identifiers a strip carries, each a literal at the call site so the control harvest
/// (`e2e/driver/identifiers.go`) sees it under its pane's surface.
struct PaneStripIds {
    /// The scrolling entries' container, and the coordinate space their spans are measured in.
    let tabs: String
    let moreLeft: String
    let moreLeftCount: String
    let moreRight: String
    let moreRightCount: String
    let newTab: String
    let entry: (Int) -> String
    var close: (Int) -> String = { _ in "" }
}

/// A small label under one entry (3d-i: the pinned tab's `Press ⌘W again to close`), drawn over the
/// row below the strip and taking no clicks.
struct PaneStripTip: Equatable {
    let index: Int
    let text: String
    let identifier: String
}

/// A tip's label: the slab, its edge and the meta-size words, taking no clicks. The strip hangs it
/// under its entry; the browser's vertical column under its row.
struct PaneStripTipLabel: View {
    let tip: PaneStripTip

    var body: some View {
        Text(tip.text)
            .font(.system(size: SettingsScale.meta))
            .foregroundStyle(PaneStripStyle.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: PaneStripStyle.tabRadius, style: .continuous)
                .fill(PaneStripStyle.slab))
            .overlay(RoundedRectangle(cornerRadius: PaneStripStyle.tabRadius, style: .continuous)
                .strokeBorder(PaneStripStyle.text.opacity(PaneStripStyle.edge), lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityIdentifier(tip.identifier)
    }
}

/// The ＋ pinned at a strip's right: what it opens, and its name.
struct PaneStripNewTab {
    let help: String
    let action: () -> Void
}

/// **A pane's tab strip** (`Browser.dc.html`'s `.tab`, in the rail's language), the browser's and
/// the editor's: a row of entries, a 1 px hairline between two at rest; the rail's tick, the
/// kind's own content, × on hover where the kind closes that way; the active entry a raised chip —
/// a lift and the border token's edge — carrying the tick (`LuminousTick`). Drag to reorder (4 pt
/// of movement first, so a click stays a selection), the drop a line in the tick's colour on the
/// side away from where the entry came from (`editorTabDropTarget`).
///
/// **Overflow** (2026-10-26, `TabStripLayout`): shrinking entries keep 200 pt while they fit, then
/// shrink evenly to 96 (the active one to no less than 140) before the strip scrolls; entries of
/// their own width scroll once their whole is wider than the strip. While it scrolls, a side with
/// entries out of sight fades and shows `‹ 3` / `8 ›`, a press paging toward them; the active
/// entry is scrolled into view whenever it changes, and only when some of it is out of sight
/// (Rule 6). The ＋ sits at the right, outside the scrolling.
///
/// It decides nothing about its pane: every press is a closure the pane hands in, which dispatches
/// the kind's own action.
struct PaneTabStrip<Entry: View>: View {
    /// The entries in order, by an id unique among them.
    let ids: [String]
    let active: String?
    let width: PaneTabWidth
    let stripIds: PaneStripIds
    var accessibility: PaneTabAccessibility = .button
    /// The kind's own content for entry `index`, between the tick and the × — `true` when it is
    /// the active one.
    @ViewBuilder let entry: (Int, Bool) -> Entry
    /// The entry's tooltip, and its accessibility name for `.button`.
    let label: (Int) -> String
    /// A click on entry `index` (the pane reads the click count where a double-click means more).
    let tap: (Int) -> Void
    /// VoiceOver's press on entry `index`.
    let activate: (Int) -> Void
    /// A drag that moves entry `from` to index `to`.
    let move: (Int, Int) -> Void
    /// The × an entry shows under the pointer; nil draws none.
    var close: ((Int) -> Void)?
    var newTab: PaneStripNewTab?
    /// A middle-click on entry `index`, while `middleClickEnabled`; nil watches for none.
    var middleClick: ((Int) -> Void)?
    var middleClickEnabled = false
    /// Whether entry `index` shows the × (3d-i: a group's chip has none); nil, every entry does.
    var closable: ((Int) -> Bool)?
    /// Entry `index`'s context menu (3d-i: the tab and group menus); nil, none.
    var contextMenu: ((Int) -> AnyView)?
    /// Whether a drag may move entry `from` to index `to` (3d-i: a chip does not drag, and nothing
    /// lands in the pull-request group); no line is drawn where it may not. Nil, every drag may.
    var canMove: ((Int, Int) -> Bool)?
    /// The 2 pt line under entry `index`, in this colour (3d-i: a group's tabs); nil, none.
    var underline: ((Int) -> Color?)?
    /// Whether entry `index` keeps its own width in a `.shrink` or `.fixed` strip (3d-i: a group's
    /// chip); the others share what is left. Nil, none does.
    var naturalWidth: ((Int) -> Bool)?
    /// A label drawn under one entry; nil, none.
    var tip: PaneStripTip?

    @State private var hovered: String?
    @State private var newTabHovered = false
    /// The side whose hidden count is under the pointer.
    @State private var moreHovered: TabStripLayout.Side?
    /// Each entry's horizontal extent in the strip, by id: where a dragged entry would land.
    @State private var spans: [String: ClosedRange<Double>] = [:]
    /// A drag's current target (indexes into `ids`), drawn as a line; nil when none.
    @State private var drop: EditorTabDrop?
    /// How far the entries are scrolled, as the strip's own scroll view reports it.
    @State private var offset: Double = 0
    /// The strip's AppKit scroll view: read for the offset, and scrolled to an offset worked out
    /// from the entries' spans (`TabStripLayout`), so neither waits on SwiftUI's view ids.
    @State private var scroller = PaneStripScroller()
    /// The scrolling area's width as last laid out, for a look taken a turn later.
    @State private var viewportWidth: Double = 0
    /// Where the entries sit in the visible strip (they move as it scrolls), for the middle-click.
    @State private var entriesOrigin: CGPoint = .zero
    /// The entry to bring into view: set when the active entry changes (a click, a key, a menu,
    /// the agent, a new tab) and cleared only once it is seen in view — or after `maxRevealTries`
    /// looks, so a strip that cannot show it does not keep trying.
    @State private var pendingReveal: String?
    @State private var revealTries = 0
    private static var maxRevealTries: Int { 8 }

    var body: some View {
        GeometryReader { g in
            let available = Double(g.size.width - (newTab == nil ? 0 : PaneStripStyle.newTabWidth))
            strip(available: available)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) { tipLabel(available: available, height: g.size.height) }
        }
    }

    private var separator: Double { Double(PaneStripStyle.separatorWidth) }

    private func isNatural(_ index: Int) -> Bool { naturalWidth?(index) ?? false }

    /// The room the entries of their own width take, each with its separator, as last laid out.
    private var naturalRoom: Double {
        guard naturalWidth != nil else { return 0 }
        return ids.indices.filter(isNatural).reduce(0) { sum, i in
            sum + (spans[ids[i]].map { $0.upperBound - $0.lowerBound } ?? 0) + separator
        }
    }

    private var sizedCount: Int { ids.count - (naturalWidth == nil ? 0 : ids.indices.filter(isNatural).count) }

    private func widths(available: Double) -> TabStripLayout.Widths {
        TabStripLayout.widths(count: sizedCount, available: available - naturalRoom, separator: separator)
    }

    /// One entry's width under this layout; nil for an entry of its own width.
    private func entryWidth(_ index: Int, _ id: String, _ widths: TabStripLayout.Widths) -> CGFloat? {
        if isNatural(index) { return nil }
        switch width {
        case .shrink: return CGFloat(id == active ? widths.active : widths.other)
        case .fixed(let w): return w
        case .natural: return nil
        }
    }

    private func overflows(available: Double, _ widths: TabStripLayout.Widths) -> Bool {
        guard available > 0 else { return false }
        // Entries of their own width alone (every group collapsed) can fill the strip too.
        let laidOut = naturalWidth != nil
            && TabStripLayout.overflows(contentWidth: orderedSpans.last?.upperBound ?? 0, available: available)
        switch width {
        case .shrink: return widths.overflows || laidOut
        case .fixed(let w):
            return laidOut
                || TabStripLayout.overflows(count: sizedCount, width: Double(w), available: available - naturalRoom,
                                            separator: separator)
        case .natural:
            return TabStripLayout.overflows(contentWidth: orderedSpans.last?.upperBound ?? 0, available: available)
        }
    }

    /// The tip under its entry, where the entry shows now (the strip scrolls), over the row below.
    @ViewBuilder
    private func tipLabel(available: Double, height: CGFloat) -> some View {
        if let tip, ids.indices.contains(tip.index), let span = spans[ids[tip.index]] {
            let slot = overflows(available: available, widths(available: available)) ? Double(PaneStripStyle.overflowSlot) : 0
            PaneStripTipLabel(tip: tip)
                .offset(x: CGFloat(max(0, span.lowerBound - offset + slot)), y: height - 2)
        }
    }

    private func strip(available: Double) -> some View {
        let widths = widths(available: available)
        let overflows = overflows(available: available, widths)
        let viewport = overflows ? available - 2 * Double(PaneStripStyle.overflowSlot) : available
        let hidden = overflows
            ? TabStripLayout.hidden(spans: orderedSpans, offset: offset, viewport: viewport) : .none
        return HStack(spacing: 0) {
            if overflows {
                more(.left, hidden.left)
            }
            ScrollView(.horizontal) {
                entries(widths)
                    // Fewer entries than the strip holds sit at its left, not centred.
                    .frame(minWidth: CGFloat(max(0, viewport)), alignment: .leading)
                    .background(PaneStripScrollProbe(scroller: scroller))
            }
            .scrollIndicators(.never)
            .coordinateSpace(name: visibleSpace)
            // A middle-click on an entry: one monitor for the strip, never a view over each entry.
            .background {
                if let middleClick {
                    EditorTabStripMiddleClick(
                        spans: orderedSpans, contentOrigin: entriesOrigin, height: Double(PaneStripStyle.tabHeight),
                        enabled: middleClickEnabled, onMiddleClick: middleClick)
                }
            }
            .mask(fade(left: hidden.left > 0, right: hidden.right > 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(stripIds.tabs)
            if overflows {
                more(.right, hidden.right)
            }
            if let newTab { newTabButton(newTab) }
        }
        .onAppear {
            scroller.onScroll = { offset = $0 }
            requestReveal(active)
        }
        .onChange(of: viewport, initial: true) { _, now in viewportWidth = now }
        .onChange(of: active) { _, now in requestReveal(now) }
        .onChange(of: available) { _, _ in requestReveal(active) }
        .onChange(of: pendingReveal) { _, _ in reveal() }
        .onChange(of: spans) { _, _ in reveal() }
        .onChange(of: viewportWidth) { _, _ in reveal() }
    }

    /// The visible strip's own space, which the entries' origin is read in for the middle-click.
    private var visibleSpace: String { "\(stripIds.tabs)#visible" }

    private var contentWidth: Double { max(viewportWidth, orderedSpans.last?.upperBound ?? 0) }

    private func requestReveal(_ id: String?) {
        revealTries = 0
        pendingReveal = id
        reveal()
    }

    /// Brings the pending entry into view, centred, if any of it is out of sight — a click on an
    /// entry already shown leaves the strip where it was (Rule 6). A new entry is not laid out
    /// when it becomes active, and the scroll view's content grows a turn after its span is known,
    /// so a scroll asked too early lands short: this looks again a moment later, and only a look
    /// that finds the entry in view (or the last try) lets the request go.
    private func reveal() {
        guard let id = pendingReveal, let span = spans[id], viewportWidth > 0 else { return }
        let now = scroller.offset ?? offset
        guard TabStripLayout.needsReveal(span, offset: now, viewport: viewportWidth,
                                         margin: Double(PaneStripStyle.overflowFade),
                                         contentWidth: contentWidth) else {
            pendingReveal = nil
            return
        }
        guard revealTries < Self.maxRevealTries else {
            pendingReveal = nil
            return
        }
        revealTries += 1
        scroller.scroll(to: TabStripLayout.revealOffset(span, viewport: viewportWidth, contentWidth: contentWidth))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reveal() }
    }

    /// The entries in a row: the scrolling content, in the drag's coordinate space.
    private func entries(_ widths: TabStripLayout.Widths) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                row(id, index: index, width: entryWidth(index, id, widths))
                    .id(id)
                if index + 1 < ids.count { separatorView(after: index) }
            }
        }
        .coordinateSpace(name: stripIds.tabs)
        .onPreferenceChange(PaneTabSpansKey.self) { spans = $0 }
        .background(GeometryReader { g in
            Color.clear.preference(key: PaneStripOriginKey.self, value: g.frame(in: .named(visibleSpace)).origin)
        })
        .onPreferenceChange(PaneStripOriginKey.self) { entriesOrigin = $0 }
        // Where the dragged entry would land: the tick's colour, on the side away from where it came from.
        .overlay(alignment: .topLeading) {
            if let drop {
                Rectangle().fill(PaneStripStyle.tick)
                    .frame(width: 2, height: PaneStripStyle.tabHeight - 8)
                    .offset(x: editorTabDropX(drop, spans: orderedSpans) - 1, y: 4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The strip's edge fading where entries are out of sight on that side.
    private func fade(left: Bool, right: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: left ? PaneStripStyle.overflowFade : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: right ? PaneStripStyle.overflowFade : 0)
        }
    }

    /// `‹ 3` or `8 ›` in its slot: how many entries are out of sight that way; a press pages the
    /// strip toward them. The slot stays while the strip overflows, empty when nothing is hidden
    /// on its side, so the entries do not move as it comes and goes.
    @ViewBuilder
    private func more(_ side: TabStripLayout.Side, _ count: Int) -> some View {
        let words = side == .left ? "to the left" : "to the right"
        ZStack {
            if count > 0 {
                HStack(spacing: 2) {
                    if side == .left { chevron("chevron.left") }
                    PaneStripNumber(value: count)
                        .accessibilityIdentifier(side == .left ? stripIds.moreLeftCount : stripIds.moreRightCount)
                    if side == .right { chevron("chevron.right") }
                }
                .frame(width: PaneStripStyle.overflowSlot - 4, height: PaneStripStyle.tabHeight)
                .background(entryFill(moreHovered == side ? PaneStripStyle.tabHoverFill : 0))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: PaneStripStyle.hoverDuration), value: moreHovered)
                .onTapGesture { page(side) }
                .onHover { inside in moreHovered = inside ? side : (moreHovered == side ? nil : moreHovered) }
                .help("\(count) more \(count == 1 ? "tab" : "tabs") \(words)")
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(count) more \(count == 1 ? "tab" : "tabs") \(words)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { page(side) }
                .accessibilityIdentifier(side == .left ? stripIds.moreLeft : stripIds.moreRight)
            }
        }
        .frame(width: PaneStripStyle.overflowSlot)
    }

    private func chevron(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: PaneStripStyle.overflowGlyph, weight: .semibold))
            .foregroundStyle(PaneStripStyle.text.opacity(RailTreatment.kindOpacity))
    }

    /// A page toward `side`'s hidden entries: the first one not wholly shown brought to the far
    /// edge, clear of its fade (`TabStripLayout.pageOffset`).
    private func page(_ side: TabStripLayout.Side) {
        guard let x = TabStripLayout.pageOffset(side, spans: orderedSpans, offset: scroller.offset ?? offset,
                                                viewport: viewportWidth,
                                                margin: Double(PaneStripStyle.overflowFade)) else { return }
        scroller.scroll(to: x, animated: true)
    }

    private var orderedSpans: [ClosedRange<Double>] { ids.map { spans[$0] ?? 0...0 } }

    /// The hairline between entry `index` and the next, clear where either side is the raised
    /// chip or lifted under the pointer.
    private func separatorView(after index: Int) -> some View {
        let quiet = [ids[index], ids[index + 1]].contains { $0 == active || $0 == hovered }
        return Rectangle()
            .fill(PaneStripStyle.text.opacity(quiet ? 0 : PaneStripStyle.hairline))
            .frame(width: 1, height: PaneStripStyle.separatorHeight)
            .padding(.horizontal, PaneStripStyle.separatorGap)
            .animation(.easeOut(duration: PaneStripStyle.hoverDuration), value: quiet)
            .accessibilityHidden(true)
    }

    /// Where a drag from entry `index` that is now at `location` would move it: onto an entry takes
    /// its place, between two goes between them (`editorTabDropTarget`).
    private func dropTarget(from index: Int, at location: CGPoint) -> Int? {
        guard let to = editorTabDropTarget(from: index, x: location.x, y: location.y, spans: orderedSpans,
                                           height: Double(PaneStripStyle.tabHeight)) else { return nil }
        return canMove?(index, to) ?? true ? to : nil
    }

    private func row(_ id: String, index: Int, width: CGFloat?) -> some View {
        let on = id == active
        let lifted = hovered == id
        return HStack(spacing: PaneStripStyle.tabGap) {
            LuminousTick(
                colour: on ? PaneStripStyle.tick : nil, height: PaneStripStyle.tickHeight,
                glowRadius: PaneStripStyle.tickGlowRadius)
            entry(index, on)
            if width != nil { Spacer(minLength: 0) }
            if lifted, let close, closable?(index) ?? true {
                Button { close(index) } label: {
                    Image(systemName: "xmark").font(.system(size: PaneStripStyle.closeGlyph, weight: .semibold))
                        .frame(width: PaneStripStyle.closeHit, height: PaneStripStyle.closeHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChangesIconButtonStyle())
                .transition(.opacity)
                .accessibilityLabel("Close \(label(index))")
                .accessibilityIdentifier(stripIds.close(index))
            }
        }
        .padding(.leading, PaneStripStyle.tabLeading)
        .padding(.trailing, PaneStripStyle.tabTrailing)
        .frame(width: width, height: PaneStripStyle.tabHeight, alignment: .leading)
        .background(entryFill(on ? PaneStripStyle.tabOnFill : (lifted ? PaneStripStyle.tabHoverFill : 0)))
        .overlay {
            if on {
                RoundedRectangle(cornerRadius: PaneStripStyle.tabRadius, style: .continuous)
                    .strokeBorder(PaneStripStyle.text.opacity(PaneStripStyle.edge), lineWidth: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if let colour = underline?(index) {
                Rectangle().fill(colour)
                    .frame(height: 2)
                    .padding(.horizontal, PaneStripStyle.tabRadius)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: PaneStripStyle.hoverDuration), value: lifted)
        .background(GeometryReader { g in
            let f = g.frame(in: .named(stripIds.tabs))
            Color.clear.preference(key: PaneTabSpansKey.self, value: [id: Double(f.minX)...Double(f.maxX)])
        })
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(stripIds.tabs))
            .onChanged { g in drop = dropTarget(from: index, at: g.location).map { EditorTabDrop(from: index, to: $0) } }
            .onEnded { g in
                defer { drop = nil }
                guard let to = dropTarget(from: index, at: g.location) else { return }
                move(index, to)
            })
        .onTapGesture { tap(index) }
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .modifier(PaneTabMenu(menu: contextMenu.map { menu in { menu(index) } }))
        .help(label(index))
        .modifier(PaneTabAccess(kind: accessibility, label: label(index), on: on, identifier: stripIds.entry(index),
                                activate: { activate(index) }))
    }

    /// The ＋ at the strip's right, outside the scrolling, drawn as a narrow entry.
    private func newTabButton(_ newTab: PaneStripNewTab) -> some View {
        Button(action: newTab.action) {
            Image(systemName: "plus")
                .font(.system(size: PaneStripStyle.newTabGlyph))
                .foregroundStyle(PaneStripStyle.text.opacity(newTabHovered ? 1 : PaneStripStyle.tabTitleRest))
                .frame(width: PaneStripStyle.newTabWidth, height: PaneStripStyle.tabHeight)
                .background(entryFill(newTabHovered ? PaneStripStyle.tabHoverFill : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: PaneStripStyle.hoverDuration), value: newTabHovered)
        .onHover { newTabHovered = $0 }
        .help(newTab.help)
        .accessibilityLabel(newTab.help)
        .accessibilityIdentifier(stripIds.newTab)
    }

    private func entryFill(_ opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: PaneStripStyle.tabRadius, style: .continuous)
            .fill(PaneStripStyle.text.opacity(opacity))
    }
}

/// An entry's context menu, when the strip has one.
private struct PaneTabMenu: ViewModifier {
    let menu: (() -> AnyView)?

    func body(content: Content) -> some View {
        if let menu {
            content.contextMenu { menu() }
        } else {
            content
        }
    }
}

/// An entry's accessibility (`PaneTabAccessibility`).
private struct PaneTabAccess: ViewModifier {
    let kind: PaneTabAccessibility
    let label: String
    let on: Bool
    let identifier: String
    let activate: () -> Void

    func body(content: Content) -> some View {
        switch kind {
        case .button:
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { activate() }
                .accessibilityIdentifier(identifier)
        case .text:
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
                .accessibilityAction { activate() }
                .accessibilityRemoveTraits(.isButton)
                .accessibilityAddTraits(on ? [.isStaticText, .isSelected] : .isStaticText)
        }
    }
}

private struct PaneTabSpansKey: PreferenceKey {
    static let defaultValue: [String: ClosedRange<Double>] = [:]
    static func reduce(value: inout [String: ClosedRange<Double>], nextValue: () -> [String: ClosedRange<Double>]) {
        value.merge(nextValue()) { _, b in b }
    }
}

private struct PaneStripOriginKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// The strip's scroll view, as AppKit has it: SwiftUI's horizontal `ScrollView` is an
/// `NSScrollView`, and its clip view's bounds are the one offset that is current on every scroll
/// — wheel, trackpad or our own — and the one that takes an exact x.
@MainActor final class PaneStripScroller: NSObject {
    private weak var scrollView: NSScrollView?
    /// Told the offset whenever the clip view moves.
    var onScroll: ((Double) -> Void)?

    /// The current offset, or nil before the scroll view is found.
    var offset: Double? { scrollView.map { Double($0.contentView.bounds.origin.x) } }

    func attach(_ view: NSScrollView) {
        guard view !== scrollView else { return }
        // A selector observer: the centre drops it when this goes, so no deinit is needed.
        if let old = scrollView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.contentView)
        }
        scrollView = view
        view.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: view.contentView)
        report()
    }

    @objc private func clipMoved(_ note: Notification) { report() }

    private func report() { if let offset { onScroll?(offset) } }

    /// Scrolls to `x`, held inside the content by the clip view.
    func scroll(to x: Double, animated: Bool = false) {
        guard let view = scrollView else { return }
        let clip = view.contentView
        var bounds = clip.bounds
        bounds.origin.x = CGFloat(x)
        let origin = clip.constrainBoundsRect(bounds).origin
        guard origin.x != clip.bounds.origin.x else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PaneStripStyle.hoverDuration
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak view] in
                MainActor.assumeIsolated { if let view { view.reflectScrolledClipView(view.contentView) } }
            }
        } else {
            clip.setBoundsOrigin(origin)
            view.reflectScrolledClipView(clip)
        }
    }
}

/// A zero-size view in the strip's content that hands its enclosing scroll view to the scroller.
private struct PaneStripScrollProbe: NSViewRepresentable {
    let scroller: PaneStripScroller

    func makeNSView(context: Context) -> ProbeView { ProbeView(scroller: scroller) }
    func updateNSView(_ view: ProbeView, context: Context) { view.attach() }

    final class ProbeView: NSView {
        let scroller: PaneStripScroller
        init(scroller: PaneStripScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }
        func attach() {
            if let scrollView = enclosingScrollView { scroller.attach(scrollView) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
