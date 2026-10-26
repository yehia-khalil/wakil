import AppKit
import SwiftUI
import WakilKit

/// How much of the tab strip a browser pane's width leaves room for (3c-i): whole entries from
/// 640 pt, entries shrunk to favicon and × from 420 pt, and below that none — the header's tab
/// count becomes the list, as a menu.
enum BrowserTabListMode: Equatable {
    case full, folded, hidden

    init(paneWidth: Double) {
        self = paneWidth < 420 ? .hidden : paneWidth < 640 ? .folded : .full
    }

    /// One entry's fixed width in the strip (`Browser.dc.html`'s `.tab`, 188–232 px wide; folded,
    /// the tick, the favicon and the × slot with the row's own padding and gaps).
    var entryWidth: CGFloat {
        switch self {
        case .full: BrowserPaneStyle.tabWidth
        case .folded: BrowserPaneStyle.tabFoldedWidth
        case .hidden: 0
        }
    }
}

/// What a tab is called in the list and the count menu: its title, else its host, else New Tab.
func browserTabLabel(_ tab: BrowserTab) -> String {
    if !tab.title.isEmpty { return tab.title }
    if let url = URL(string: tab.url), !tab.url.isEmpty { return BrowserAddress.displayHost(url) }
    return "New Tab"
}

/// The browser pane's drawing (3c-i, Task 8b): `Browser.dc.html`'s numbers, each read from the
/// token another pane already draws with where one exists — the editor's colours, the rail's tick
/// and row lift, the settings form's micro-label and field — and named here only where the browser
/// is the first to need it.
enum BrowserPaneStyle {
    static let text = EditorPaneStyle.text
    static let amber = EditorPaneStyle.amber
    static let slab = EditorPaneStyle.slab
    /// The rail's active tick, `#9e82ff` (`RailTreatment.activeTickColour`).
    static let tick = Color(RailTreatment.activeTickColour)

    // MARK: The tab list — `.tab`, drawn in the rail's language

    /// The pane's two header rows, the tab strip and the address row: 32 pt each (the compact
    /// chrome, 2026-10-26 — `Browser.dc.html`'s 30 px entries in their own 38 pt row, and a 48 pt
    /// address row, gave the page 230 pt less than the pane).
    static let rowHeight: CGFloat = 32
    /// Each header row's inset from the pane's edge, and the room above and below a row the
    /// downloads take.
    static let rowInset: CGFloat = 8
    static let rowPadding: CGFloat = 4
    /// The slab's corner (`Canvas.paneView`'s 10): the page's bottom corners, edge to edge.
    static let paneRadius: CGFloat = 10
    /// The pane's own glyph at the strip's left, in the label's place, and the room after it.
    static let paneGlyph: CGFloat = 12
    static let glyphTrailing: CGFloat = 4
    /// One entry, inside the 32 pt strip: `.tab { padding: 0 11px 0 9px; gap: 9px; border-radius: 5px }`.
    static let tabHeight: CGFloat = 26
    static let tabLeading: CGFloat = 9
    static let tabTrailing: CGFloat = 11
    static let tabGap: CGFloat = 9
    static let tabRadius: CGFloat = 5
    /// Between entries: a 1 px hairline (`hairline`) of `separatorHeight`, `separatorGap` either
    /// side — drawn only between two entries at rest, so the raised chip and a lifted entry
    /// carry no rule against them.
    static let separatorHeight: CGFloat = 14
    static let separatorGap: CGFloat = 2
    /// A whole entry's width (the mockup's 188–232 px, one width so entries do not jump), and a
    /// folded one's: 9 + tick 2 + 9 + favicon 12 + 9 + × 16 + 11.
    static let tabWidth: CGFloat = 200
    static let tabFoldedWidth: CGFloat = 68
    /// The ＋ entry, `.tab { padding: 0 10px }` round a 12 pt plus, pinned at the strip's right
    /// outside its scrolling: one fixed width, so the room left for the entries is known.
    static let newTabGlyph: CGFloat = 12
    static let newTabWidth: CGFloat = 32
    /// A separator's whole width: the 1 px rule and its gap either side.
    static var separatorWidth: CGFloat { 1 + 2 * separatorGap }
    /// Overflow (2026-10-26): each side's `‹ 3` / `8 ›` count takes a slot this wide beside the
    /// scrolling entries while they overflow, and the entries fade over this much of that edge.
    static let overflowSlot: CGFloat = 34
    static let overflowFade: CGFloat = 24
    static let overflowGlyph: CGFloat = 8
    /// The active entry is a raised chip: `.tab.on`'s lift stepped up to 0.08, and the border
    /// token's edge (`edge`) round it.
    static let tabOnFill: Double = 0.08
    /// `.tab:hover`: the rail's row lift (`Rail.dc.html` state 3).
    static let tabHoverFill = RailTreatment.rowHoverTint
    /// `.tab .ttl` at 12 px, 0.62 at rest and the full cool white on the active tab.
    static let tabTitleSize = SettingsScale.body
    static let tabTitleRest: Double = 0.62
    /// `.tab .tick { width: 2px; height: 15px }` and its `0 0 7px` glow.
    static let tickHeight: CGFloat = 15
    static let tickGlowRadius: CGFloat = 3.5
    /// The favicon or globe, 12 px; the globe's stroke at the micro-label's step.
    static let glyphSize: CGFloat = 12
    static let globeGlyph: CGFloat = 11
    /// `.tab .x`: the Changes view's row action (a 9 pt glyph in its 16 pt square).
    static let closeGlyph: CGFloat = 9
    static let closeHit: CGFloat = 16
    /// `.act`'s hover fade, the rail's row duration.
    static let hoverDuration = RailTreatment.rowHoverDuration

    // MARK: The header and the page

    /// The address field: the settings form's `.field` inset and radius, 24 pt high so the
    /// address row is 32, its fill the form field's 0.05, and while it is edited an edge in the
    /// tick's colour.
    static let fieldInsetX: CGFloat = 9
    static let fieldHeight: CGFloat = 24
    static let fieldRadius: CGFloat = 5
    static let fieldFill: Double = 0.05
    static let fieldEditingEdge: Double = 0.6
    /// **The border token**: cool white at 0.14 — the settings form's field edge and the prompt
    /// card's (`promptEdge`). The address field's 1 px edge, the active tab chip's, and the
    /// browser pane's own border.
    static let edge: Double = 0.14
    /// **The hairline**: cool white at 0.08, the editor's rule between the Changes view's roots
    /// and under its timeline. Between tabs and under the header.
    static let hairline: Double = 0.08
    /// NOT SECURE: the micro label's mono line, `letter-spacing: 1.2px`.
    static let monoTracking: CGFloat = 1.2
    /// Between the padlock and NOT SECURE, and between them and the URL.
    static let lockGap: CGFloat = 5

    /// Between controls in a row.
    static let gap: CGFloat = 8
    /// ‹ › ↻ ×'s hit square and glyph (`ChangesIconButtonStyle` draws them).
    static let controlSize: CGFloat = 22
    static let controlGlyph: CGFloat = 11
    /// A control with nothing to do, as the Changes view dims its buttons while a write runs.
    static let disabledOpacity: Double = 0.4
    /// The address, `.mono` at 11.5 px, 0.86.
    static let addressSize: CGFloat = 11.5
    static let addressOpacity: Double = 0.86
    /// What Wakil draws in the page's place: its lines, and their inset.
    static let pageLineSpacing: CGFloat = 12
    static let pageLinePadding: CGFloat = 24
    /// The padlock beside the host.
    static let lockSize: CGFloat = 9

    // MARK: Lines, prompts and their buttons — `UnsavedPromptBar`'s

    /// A sentence or an error line (`SettingsScale.body`).
    static let lineSize = SettingsScale.body
    /// A second line: a host, a count, a size (`SettingsScale.meta`, monospaced).
    static let metaSize = SettingsScale.meta
    static let metaOpacity = RailTreatment.kindOpacity
    /// The in-place prompt's buttons: 11 pt, the answer at full white and semibold, the other 0.72.
    static let buttonSize: CGFloat = 11
    static let quietButtonOpacity: Double = 0.72
    /// `UnsavedPromptBar`'s surface: the slab, radius 6, a 0.14 hairline.
    static let promptRadius: CGFloat = 6
    static let promptEdge: Double = 0.14
    /// The prompt card's inset and width, and the room between its buttons.
    static let promptPadding: CGFloat = 16
    static let promptWidth: CGFloat = 360
    static let promptButtonGap: CGFloat = 14
    /// A download's entries, side by side.
    static let downloadSpacing: CGFloat = 14
    /// The certificate page's lock.
    static let pageGlyph: CGFloat = 22
    /// What the page under a prompt is dimmed by while it waits (it takes the page's clicks).
    static let promptScrim = Color.black.opacity(0.28)
}

extension View {
    /// §6's micro-label as the pane titles draw it: uppercase-tracked 9 pt, stepped down to the
    /// rail's legible floor.
    func browserMicro() -> some View {
        font(.system(size: SettingsScale.micro, weight: .medium))
            .tracking(SettingsScale.microTracking)
            .foregroundStyle(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
    }

    /// An in-place prompt's or error line's button, `UnsavedPromptBar`'s: plain text, the answer
    /// semibold at full white, the other quieter.
    func browserLineButton(primary: Bool) -> some View {
        buttonStyle(.plain)
            .font(.system(size: BrowserPaneStyle.buttonSize, weight: primary ? .semibold : .regular))
            .foregroundStyle(BrowserPaneStyle.text.opacity(primary ? 1 : BrowserPaneStyle.quietButtonOpacity))
    }
}

/// The address row, 32 pt: ‹ › ↻ (× while loading) and the address field.
struct BrowserHeader<Address: View>: View {
    let tab: BrowserTab?
    let dispatch: (String, [String: JSONValue]) -> Void
    @ViewBuilder let address: () -> Address

    var body: some View {
        HStack(spacing: BrowserPaneStyle.gap) {
            HStack(spacing: 2) {
                control("chevron.left", "browser.back", "Back", enabled: tab?.canGoBack == true) {
                    dispatch("browser_back", [:])
                }
                control("chevron.right", "browser.forward", "Forward", enabled: tab?.canGoForward == true) {
                    dispatch("browser_forward", [:])
                }
                if tab?.isLoading == true {
                    control("xmark", "browser.stop", "Stop", enabled: true) { dispatch("browser_stop", [:]) }
                } else {
                    control("arrow.clockwise", "browser.reload", "Reload", enabled: tab != nil) {
                        dispatch("browser_reload", [:])
                    }
                }
            }
            address()
        }
        .padding(.horizontal, BrowserPaneStyle.rowInset)
        .frame(height: BrowserPaneStyle.rowHeight)
    }

    /// Drawn as the editor column's row actions are (`ChangesIconButtonStyle`): a rounded fill under
    /// the glyph on hover, stronger while pressed.
    private func control(_ symbol: String, _ id: String, _ label: String, enabled: Bool,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: BrowserPaneStyle.controlGlyph, weight: .medium))
                .frame(width: BrowserPaneStyle.controlSize, height: BrowserPaneStyle.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChangesIconButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : BrowserPaneStyle.disabledOpacity)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The number of tabs at the strip's right, pinned outside its scrolling: pressed, the ⌄ menu of
/// every tab. With the list hidden it carries the ⌄ itself. Tabular digits and no tracking, so
/// 15 reads as one number.
struct BrowserTabCount: View {
    let tabs: [BrowserTab]
    let listMode: BrowserTabListMode
    let dispatch: (String, [String: JSONValue]) -> Void

    var body: some View {
        Menu {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { _, t in
                Button(browserTabLabel(t)) { dispatch("browser_select_tab", ["tab": .string(t.id)]) }
            }
        } label: {
            HStack(spacing: 3) {
                BrowserStripNumber(value: tabs.count)
                if listMode == .hidden {
                    Image(systemName: "chevron.down")
                        .font(.system(size: BrowserPaneStyle.closeGlyph, weight: .semibold))
                        .foregroundStyle(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
                }
            }
            .frame(minWidth: 18, minHeight: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tabs")
        .accessibilityLabel("\(tabs.count) tabs")
        .accessibilityIdentifier(listMode == .hidden ? "browser.tabMenu" : "browser.tabCount")
    }
}

/// A count in the strip — the tab count, a side's hidden count: the micro-label's size and
/// colour with tabular digits and none of its tracking, which spread 15 into "1 5".
struct BrowserStripNumber: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.system(size: SettingsScale.micro, weight: .medium).monospacedDigit())
            .foregroundStyle(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A 1 px rule in the hairline token, across the pane: under the header, and either side of a
/// row the find bar or the downloads take.
struct BrowserHairline: View {
    var body: some View {
        Rectangle().fill(BrowserPaneStyle.text.opacity(BrowserPaneStyle.hairline))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The tab strip (`Browser.dc.html`'s `.tab`, in the rail's language): a row of entries, a 1 px
/// hairline between two at rest; tick, favicon, title, × on hover; the active entry a raised
/// chip — a lift and the border token's edge — carrying the rail's tick (`LuminousTick`). Folded,
/// an entry is its favicon and ×.
///
/// **Overflow** (2026-10-26, `BrowserTabStrip`): entries keep 200 pt while they fit, then shrink
/// evenly to 96 (the active one to no less than 140) before the strip scrolls. While it scrolls,
/// a side with entries out of sight fades and shows `‹ 3` / `8 ›`, a press paging toward them;
/// the active entry is scrolled into view whenever it changes. The ＋ sits at the right, outside
/// the scrolling, as the count does after it.
struct BrowserTabList: View {
    let snapshot: BrowserSnapshot
    let mode: BrowserTabListMode
    let favicon: (String) -> NSImage?
    let dispatch: (String, [String: JSONValue]) -> Void
    @State private var hovered: String?
    @State private var newTabHovered = false
    /// The side whose hidden count is under the pointer.
    @State private var moreHovered: BrowserTabStrip.Side?
    /// Each entry's horizontal extent in the strip, by tab id: where a dragged tab would land.
    @State private var spans: [String: ClosedRange<Double>] = [:]
    /// A drag's current target (indexes into `snapshot.tabs`), drawn as a line; nil when none.
    @State private var drop: EditorTabDrop?
    /// How far the entries are scrolled, as the strip's own scroll view reports it.
    @State private var offset: Double = 0
    /// The strip's AppKit scroll view: read for the offset, and scrolled to an offset worked out
    /// from the entries' spans (`BrowserTabStrip`), so neither waits on SwiftUI's view ids.
    @State private var scroller = BrowserStripScroller()
    /// The scrolling area's width as last laid out, for a look taken a turn later.
    @State private var viewportWidth: Double = 0
    /// The tab to bring into view: set when the active tab changes (a click, ⌘1–9, the menu, the
    /// agent, a new tab) and cleared only once it is seen in view — or after `revealTries` looks,
    /// so a strip that cannot show it does not keep trying.
    @State private var pendingReveal: String?
    @State private var revealTries = 0
    private static let maxRevealTries = 8

    var body: some View {
        GeometryReader { g in
            strip(available: Double(g.size.width - BrowserPaneStyle.newTabWidth))
                .frame(maxHeight: .infinity)
        }
    }

    /// One entry's width under this layout.
    private func entryWidth(_ tab: BrowserTab, _ widths: BrowserTabStrip.Widths) -> CGFloat {
        guard mode == .full else { return mode.entryWidth }
        return CGFloat(tab.id == snapshot.active ? widths.active : widths.other)
    }

    private func strip(available: Double) -> some View {
        let count = snapshot.tabs.count
        let separator = Double(BrowserPaneStyle.separatorWidth)
        let widths = BrowserTabStrip.widths(count: count, available: available, separator: separator)
        let overflows = available > 0 && (mode == .full
            ? widths.overflows
            : BrowserTabStrip.overflows(count: count, width: Double(mode.entryWidth), available: available,
                                        separator: separator))
        let viewport = overflows ? available - 2 * Double(BrowserPaneStyle.overflowSlot) : available
        let hidden = overflows
            ? BrowserTabStrip.hidden(spans: orderedSpans, offset: offset, viewport: viewport) : .none
        return HStack(spacing: 0) {
            if overflows {
                more(.left, hidden.left)
            }
            ScrollView(.horizontal) {
                entries(widths)
                    // Fewer entries than the strip holds sit at its left, not centred.
                    .frame(minWidth: CGFloat(max(0, viewport)), alignment: .leading)
                    .background(BrowserStripScrollProbe(scroller: scroller))
            }
            .scrollIndicators(.never)
            .mask(fade(left: hidden.left > 0, right: hidden.right > 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("browser.tabs")
            if overflows {
                more(.right, hidden.right)
            }
            newTab
        }
        .onAppear {
            scroller.onScroll = { offset = $0 }
            requestReveal(snapshot.active)
        }
        .onChange(of: viewport, initial: true) { _, now in viewportWidth = now }
        .onChange(of: snapshot.active) { _, now in requestReveal(now) }
        .onChange(of: available) { _, _ in requestReveal(snapshot.active) }
        .onChange(of: pendingReveal) { _, _ in reveal() }
        .onChange(of: spans) { _, _ in reveal() }
        .onChange(of: viewportWidth) { _, _ in reveal() }
    }

    private var contentWidth: Double { max(viewportWidth, orderedSpans.last?.upperBound ?? 0) }

    private func requestReveal(_ id: String?) {
        revealTries = 0
        pendingReveal = id
        reveal()
    }

    /// Brings the pending tab into view, centred, if any of it is out of sight — a click on an
    /// entry already shown leaves the strip where it was (Rule 6). A new tab's entry is not laid
    /// out when it becomes active, and the scroll view's content grows a turn after its span is
    /// known, so a scroll asked too early lands short: this looks again a moment later, and only
    /// a look that finds the tab in view (or the last try) lets the request go.
    private func reveal() {
        guard let id = pendingReveal, let span = spans[id], viewportWidth > 0 else { return }
        let now = scroller.offset ?? offset
        guard BrowserTabStrip.needsReveal(span, offset: now, viewport: viewportWidth,
                                          margin: Double(BrowserPaneStyle.overflowFade),
                                          contentWidth: contentWidth) else {
            pendingReveal = nil
            return
        }
        guard revealTries < Self.maxRevealTries else {
            pendingReveal = nil
            return
        }
        revealTries += 1
        scroller.scroll(to: BrowserTabStrip.revealOffset(span, viewport: viewportWidth, contentWidth: contentWidth))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reveal() }
    }

    /// The entries in a row: the scrolling content, in the drag's coordinate space.
    private func entries(_ widths: BrowserTabStrip.Widths) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(snapshot.tabs.enumerated()), id: \.element.id) { index, tab in
                row(tab, index: index, width: entryWidth(tab, widths))
                    .id(tab.id)
                if index + 1 < snapshot.tabs.count { separator(after: index) }
            }
        }
        .coordinateSpace(name: "browser.tabs")
        .onPreferenceChange(BrowserTabSpansKey.self) { spans = $0 }
        // Where the dragged tab would land: the tick's colour, on the side away from where it came from.
        .overlay(alignment: .topLeading) {
            if let drop {
                Rectangle().fill(BrowserPaneStyle.tick)
                    .frame(width: 2, height: BrowserPaneStyle.tabHeight - 8)
                    .offset(x: editorTabDropX(drop, spans: orderedSpans) - 1, y: 4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The strip's edge fading where entries are out of sight on that side.
    private func fade(left: Bool, right: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: left ? BrowserPaneStyle.overflowFade : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: right ? BrowserPaneStyle.overflowFade : 0)
        }
    }

    /// `‹ 3` or `8 ›` in its slot: how many entries are out of sight that way; a press pages the
    /// strip toward them. The slot stays while the strip overflows, empty when nothing is hidden
    /// on its side, so the entries do not move as it comes and goes.
    @ViewBuilder
    private func more(_ side: BrowserTabStrip.Side, _ count: Int) -> some View {
        let name = side == .left ? "moreLeft" : "moreRight"
        let words = side == .left ? "to the left" : "to the right"
        ZStack {
            if count > 0 {
                HStack(spacing: 2) {
                    if side == .left { chevron("chevron.left") }
                    BrowserStripNumber(value: count)
                        .accessibilityIdentifier("browser.tabs.\(name).count")
                    if side == .right { chevron("chevron.right") }
                }
                .frame(width: BrowserPaneStyle.overflowSlot - 4, height: BrowserPaneStyle.tabHeight)
                .background(entryFill(moreHovered == side ? BrowserPaneStyle.tabHoverFill : 0))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: BrowserPaneStyle.hoverDuration), value: moreHovered)
                .onTapGesture { page(side) }
                .onHover { inside in moreHovered = inside ? side : (moreHovered == side ? nil : moreHovered) }
                .help("\(count) more \(count == 1 ? "tab" : "tabs") \(words)")
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(count) more \(count == 1 ? "tab" : "tabs") \(words)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { page(side) }
                .accessibilityIdentifier("browser.tabs.\(name)")
            }
        }
        .frame(width: BrowserPaneStyle.overflowSlot)
    }

    private func chevron(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: BrowserPaneStyle.overflowGlyph, weight: .semibold))
            .foregroundStyle(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
    }

    /// A page toward `side`'s hidden entries: the first one not wholly shown brought to the far
    /// edge, clear of its fade (`BrowserTabStrip.pageOffset`).
    private func page(_ side: BrowserTabStrip.Side) {
        guard let x = BrowserTabStrip.pageOffset(side, spans: orderedSpans, offset: scroller.offset ?? offset,
                                                 viewport: viewportWidth,
                                                 margin: Double(BrowserPaneStyle.overflowFade)) else { return }
        scroller.scroll(to: x, animated: true)
    }

    private var orderedSpans: [ClosedRange<Double>] { snapshot.tabs.map { spans[$0.id] ?? 0...0 } }

    /// The hairline between entry `index` and the next, clear where either side is the raised
    /// chip or lifted under the pointer.
    private func separator(after index: Int) -> some View {
        let tabs = snapshot.tabs
        let left = tabs[index].id
        let right = tabs[index + 1].id
        let quiet = [left, right].contains { $0 == snapshot.active || $0 == hovered }
        return Rectangle()
            .fill(BrowserPaneStyle.text.opacity(quiet ? 0 : BrowserPaneStyle.hairline))
            .frame(width: 1, height: BrowserPaneStyle.separatorHeight)
            .padding(.horizontal, BrowserPaneStyle.separatorGap)
            .animation(.easeOut(duration: BrowserPaneStyle.hoverDuration), value: quiet)
            .accessibilityHidden(true)
    }

    /// Where a drag from tab `index` that is now at `location` would move it — the editor strip's
    /// rule (`editorTabDropTarget`): onto a tab takes its place, between two goes between them.
    private func dropTarget(from index: Int, at location: CGPoint) -> Int? {
        editorTabDropTarget(from: index, x: location.x, y: location.y, spans: orderedSpans,
                            height: BrowserPaneStyle.tabHeight)
    }

    private func row(_ tab: BrowserTab, index: Int, width: CGFloat) -> some View {
        let active = tab.id == snapshot.active
        let lifted = hovered == tab.id
        return HStack(spacing: BrowserPaneStyle.tabGap) {
            LuminousTick(
                colour: active ? BrowserPaneStyle.tick : nil, height: BrowserPaneStyle.tickHeight,
                glowRadius: BrowserPaneStyle.tickGlowRadius)
            BrowserFavicon(image: favicon(tab.id))
            if mode == .full {
                Text(browserTabLabel(tab))
                    .font(.system(size: BrowserPaneStyle.tabTitleSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(BrowserPaneStyle.text.opacity(active ? 1 : BrowserPaneStyle.tabTitleRest))
            }
            Spacer(minLength: 0)
            if lifted {
                Button { dispatch("browser_close_tab", ["tab": .string(tab.id)]) } label: {
                    Image(systemName: "xmark").font(.system(size: BrowserPaneStyle.closeGlyph, weight: .semibold))
                        .frame(width: BrowserPaneStyle.closeHit, height: BrowserPaneStyle.closeHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChangesIconButtonStyle())
                .transition(.opacity)
                .accessibilityLabel("Close \(browserTabLabel(tab))")
                .accessibilityIdentifier("browser.tab.\(tab.id).close")
            }
        }
        .padding(.leading, BrowserPaneStyle.tabLeading)
        .padding(.trailing, BrowserPaneStyle.tabTrailing)
        .frame(width: width, height: BrowserPaneStyle.tabHeight, alignment: .leading)
        .background(entryFill(active ? BrowserPaneStyle.tabOnFill : (lifted ? BrowserPaneStyle.tabHoverFill : 0)))
        .overlay {
            if active {
                RoundedRectangle(cornerRadius: BrowserPaneStyle.tabRadius, style: .continuous)
                    .strokeBorder(BrowserPaneStyle.text.opacity(BrowserPaneStyle.edge), lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: BrowserPaneStyle.hoverDuration), value: lifted)
        .background(GeometryReader { g in
            let f = g.frame(in: .named("browser.tabs"))
            Color.clear.preference(key: BrowserTabSpansKey.self, value: [tab.id: Double(f.minX)...Double(f.maxX)])
        })
        .contentShape(Rectangle())
        // Drag to reorder (spec: Safari's behaviours kept): 4 pt of movement first, so a click stays
        // a selection; the drop is `browser_move_tab`, the agent's action (Invariant 2).
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("browser.tabs"))
            .onChanged { g in drop = dropTarget(from: index, at: g.location).map { EditorTabDrop(from: index, to: $0) } }
            .onEnded { g in
                defer { drop = nil }
                guard let to = dropTarget(from: index, at: g.location) else { return }
                dispatch("browser_move_tab", ["tab": .string(tab.id), "to": .integer(Int64(to))])
            })
        .onTapGesture { dispatch("browser_select_tab", ["tab": .string(tab.id)]) }
        .onHover { inside in hovered = inside ? tab.id : (hovered == tab.id ? nil : hovered) }
        .help(browserTabLabel(tab))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(browserTabLabel(tab))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { dispatch("browser_select_tab", ["tab": .string(tab.id)]) }
        .accessibilityIdentifier("browser.tab.\(tab.id)")
    }

    /// The ＋ at the strip's right, outside the scrolling: ⌘T's `browser_new_tab`, drawn as a
    /// narrow entry.
    private var newTab: some View {
        Button { dispatch("browser_new_tab", [:]) } label: {
            Image(systemName: "plus")
                .font(.system(size: BrowserPaneStyle.newTabGlyph))
                .foregroundStyle(BrowserPaneStyle.text.opacity(newTabHovered ? 1 : BrowserPaneStyle.tabTitleRest))
                .frame(width: BrowserPaneStyle.newTabWidth, height: BrowserPaneStyle.tabHeight)
                .background(entryFill(newTabHovered ? BrowserPaneStyle.tabHoverFill : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: BrowserPaneStyle.hoverDuration), value: newTabHovered)
        .onHover { newTabHovered = $0 }
        .help("New Tab")
        .accessibilityLabel("New Tab")
        .accessibilityIdentifier("browser.newTab")
    }

    private func entryFill(_ opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: BrowserPaneStyle.tabRadius, style: .continuous)
            .fill(BrowserPaneStyle.text.opacity(opacity))
    }
}

/// The page's own icon when it names one as a `data:` URL (decoded by the host, never fetched),
/// else a globe, drawn at the micro-label's step as `Browser.dc.html` strokes it.
struct BrowserFavicon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: BrowserPaneStyle.globeGlyph))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
            }
        }
        .frame(width: BrowserPaneStyle.glyphSize, height: BrowserPaneStyle.glyphSize)
    }
}

extension Text {
    /// `.mono.micro { letter-spacing: 1.2px }`: NOT SECURE in the address field.
    func browserMonoMicro(_ colour: Color) -> some View {
        font(.system(size: SettingsScale.micro, weight: .medium, design: .monospaced))
            .tracking(BrowserPaneStyle.monoTracking)
            .foregroundStyle(colour)
            .lineLimit(1)
    }
}

private struct BrowserTabSpansKey: PreferenceKey {
    static let defaultValue: [String: ClosedRange<Double>] = [:]
    static func reduce(value: inout [String: ClosedRange<Double>], nextValue: () -> [String: ClosedRange<Double>]) {
        value.merge(nextValue()) { _, b in b }
    }
}

/// The tab strip's scroll view, as AppKit has it: SwiftUI's horizontal `ScrollView` is an
/// `NSScrollView`, and its clip view's bounds are the one offset that is current on every scroll
/// — wheel, trackpad or our own — and the one that takes an exact x.
@MainActor final class BrowserStripScroller: NSObject {
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
                context.duration = BrowserPaneStyle.hoverDuration
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
private struct BrowserStripScrollProbe: NSViewRepresentable {
    let scroller: BrowserStripScroller

    func makeNSView(context: Context) -> ProbeView { ProbeView(scroller: scroller) }
    func updateNSView(_ view: ProbeView, context: Context) { view.attach() }

    final class ProbeView: NSView {
        let scroller: BrowserStripScroller
        init(scroller: BrowserStripScroller) {
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
