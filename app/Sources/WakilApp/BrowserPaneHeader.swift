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

    /// `.tab { height: 30px; padding: 0 11px 0 9px; gap: 9px; border-radius: 5px }`.
    static let tabHeight: CGFloat = 30
    static let tabLeading: CGFloat = 9
    static let tabTrailing: CGFloat = 11
    static let tabGap: CGFloat = 9
    static let tabRadius: CGFloat = 5
    /// Whitespace between entries, never a rule: the strip's `gap: 4px`.
    static let tabSpacing: CGFloat = 4
    /// A whole entry's width (the mockup's 188–232 px, one width so entries do not jump), and a
    /// folded one's: 9 + tick 2 + 9 + favicon 12 + 9 + × 16 + 11.
    static let tabWidth: CGFloat = 200
    static let tabFoldedWidth: CGFloat = 68
    /// The trailing ＋ entry, `.tab { padding: 0 10px }` round a 13 px plus.
    static let newTabPadding: CGFloat = 10
    static let newTabGlyph: CGFloat = 12
    /// `.tab.on { background: rgba(232,236,246,0.06) }` — the editor strip's active tab's lift.
    static let tabOnFill: Double = 0.06
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

    /// The pane's label inline at the strip's left: `.micro { padding: 0 10px 0 4px }`.
    static let labelLeading: CGFloat = 4
    static let labelTrailing: CGFloat = 10

    // MARK: The header and the page

    /// The address line's inset: the settings form's `.field` padding, so the URL does not move
    /// when the field's box appears round it.
    static let fieldInsetX: CGFloat = 9
    static let fieldInsetY: CGFloat = 6
    /// The footer's micro labels: `gap: 16px`, and the mono line's `letter-spacing: 1.2px`.
    static let footerSpacing: CGFloat = 16
    static let footerTracking: CGFloat = 1.2

    /// Between the header row, the find bar, the list, the page and the downloads: whitespace.
    static let gap: CGFloat = 8
    /// `.page { border-radius: 6px }`: the page's container. The page itself is never styled.
    static let pageRadius: CGFloat = 6
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

/// The header row: ‹ › ↻ (× while loading), the address field, and the tab count.
struct BrowserHeader<Address: View>: View {
    let tab: BrowserTab?
    let tabs: [BrowserTab]
    let listMode: BrowserTabListMode
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
            count
        }
        .padding(.bottom, BrowserPaneStyle.gap)
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

    /// The number of tabs, as a micro-label; with the list hidden, the list itself, as a menu.
    @ViewBuilder private var count: some View {
        let text = Text("\(tabs.count)")
            .monospacedDigit()
            .browserMicro()
            .frame(minWidth: 18, minHeight: 18)
        if listMode == .hidden {
            Menu {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { _, t in
                    Button(browserTabLabel(t)) { dispatch("browser_select_tab", ["tab": .string(t.id)]) }
                }
            } label: { text }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("browser.tabMenu")
        } else {
            text
                .accessibilityLabel("\(tabs.count) tabs")
                .accessibilityIdentifier("browser.tabCount")
        }
    }
}

/// The tab strip (`Browser.dc.html`'s `.tab`, in the rail's language): a row of fixed-width
/// entries, no tab shapes and no rules, whitespace between them; tick, favicon, title, × on hover;
/// the active entry lifted and carrying the rail's tick (`LuminousTick`); a trailing ＋ (⌘T's
/// `browser_new_tab`). Folded, an entry is its favicon and ×; more entries than fit scroll sideways.
struct BrowserTabList: View {
    let snapshot: BrowserSnapshot
    let mode: BrowserTabListMode
    let favicon: (String) -> NSImage?
    let dispatch: (String, [String: JSONValue]) -> Void
    @State private var hovered: String?
    @State private var newTabHovered = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BrowserPaneStyle.tabSpacing) {
                ForEach(snapshot.tabs, id: \.id) { tab in row(tab) }
                newTab
            }
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.tabs")
    }

    private func row(_ tab: BrowserTab) -> some View {
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
        .frame(width: mode.entryWidth, height: BrowserPaneStyle.tabHeight, alignment: .leading)
        .background(entryFill(active ? BrowserPaneStyle.tabOnFill : (lifted ? BrowserPaneStyle.tabHoverFill : 0)))
        .animation(.easeOut(duration: BrowserPaneStyle.hoverDuration), value: lifted)
        .contentShape(Rectangle())
        .onTapGesture { dispatch("browser_select_tab", ["tab": .string(tab.id)]) }
        .onHover { inside in hovered = inside ? tab.id : (hovered == tab.id ? nil : hovered) }
        .help(browserTabLabel(tab))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(browserTabLabel(tab))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { dispatch("browser_select_tab", ["tab": .string(tab.id)]) }
        .accessibilityIdentifier("browser.tab.\(tab.id)")
    }

    /// The strip's trailing ＋: ⌘T's `browser_new_tab`, drawn as a narrow entry.
    private var newTab: some View {
        Button { dispatch("browser_new_tab", [:]) } label: {
            Image(systemName: "plus")
                .font(.system(size: BrowserPaneStyle.newTabGlyph))
                .foregroundStyle(BrowserPaneStyle.text.opacity(newTabHovered ? 1 : BrowserPaneStyle.tabTitleRest))
                .padding(.horizontal, BrowserPaneStyle.newTabPadding)
                .frame(height: BrowserPaneStyle.tabHeight)
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

/// The row under the page (`Browser.dc.html`'s last line), in micro labels: the page's host,
/// uppercase, and how it arrived — `TLS` for https (WebKit's `serverTrust` names no protocol
/// version, so none is shown), `NOT SECURE` in amber where the address row says Not Secure. A
/// loopback `http` page — which the padlock calls secure — has its host alone. Nil for a page with
/// no host (blank, `about:`, `file:`, `data:`).
struct BrowserFooter: View {
    let host: String
    let transport: BrowserFooterLine.Transport?

    /// The rule is WakilKit's (`BrowserAddress.footer`); the view only sets it in capitals.
    init?(url: URL) {
        guard let line = BrowserAddress.footer(url) else { return nil }
        host = line.host.uppercased()
        transport = line.transport
    }

    var body: some View {
        HStack(spacing: BrowserPaneStyle.footerSpacing) {
            Text(host).browserFooterMicro(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
                .accessibilityIdentifier("browser.footer.host")
            switch transport {
            case .tls: Text("TLS").browserFooterMicro(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
            case .notSecure: Text("NOT SECURE").browserFooterMicro(BrowserPaneStyle.amber)
            case nil: EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BrowserPaneStyle.fieldInsetX)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.footer")
    }
}

extension Text {
    /// `.mono.micro { letter-spacing: 1.2px }`: the footer's host and transport.
    func browserFooterMicro(_ colour: Color) -> some View {
        font(.system(size: SettingsScale.micro, weight: .medium, design: .monospaced))
            .tracking(BrowserPaneStyle.footerTracking)
            .foregroundStyle(colour)
            .lineLimit(1)
    }
}
