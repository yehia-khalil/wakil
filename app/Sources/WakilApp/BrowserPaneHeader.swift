import AppKit
import SwiftUI
import WakilKit

/// How much of the tab list a browser pane's width leaves room for (3c-i): the whole list from
/// 640 pt, its favicons alone from 420 pt, and below that none — the header's tab count becomes
/// the list, as a menu.
enum BrowserTabListMode: Equatable {
    case full, folded, hidden

    init(paneWidth: Double) {
        self = paneWidth < 420 ? .hidden : paneWidth < 640 ? .folded : .full
    }

    var width: CGFloat {
        switch self {
        case .full: 176
        case .folded: 34
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
    /// Whitespace between entries, never a rule: the rail's own 2 pt (`Browser.dc.html` rail).
    static let tabSpacing: CGFloat = 2
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

    // MARK: The header and the page

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

/// The vertical tab list (`Browser.dc.html`'s `.tab`, in the rail's language): no tab shapes and no
/// rules, whitespace between entries; favicon, title, × on hover; the active tab lifted and carrying
/// the rail's tick (`LuminousTick`).
struct BrowserTabList: View {
    let snapshot: BrowserSnapshot
    let mode: BrowserTabListMode
    let favicon: (String) -> NSImage?
    let dispatch: (String, [String: JSONValue]) -> Void
    @State private var hovered: String?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: BrowserPaneStyle.tabSpacing) {
                ForEach(snapshot.tabs, id: \.id) { tab in row(tab) }
            }
        }
        .scrollIndicators(.never)
        .frame(width: mode.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.tabs")
    }

    private func row(_ tab: BrowserTab) -> some View {
        let active = tab.id == snapshot.active
        let lifted = hovered == tab.id
        let tick = LuminousTick(
            colour: active ? BrowserPaneStyle.tick : nil, height: BrowserPaneStyle.tickHeight,
            glowRadius: BrowserPaneStyle.tickGlowRadius)
        return HStack(spacing: BrowserPaneStyle.tabGap) {
            if mode == .full {
                tick
                BrowserFavicon(image: favicon(tab.id))
                Text(browserTabLabel(tab))
                    .font(.system(size: BrowserPaneStyle.tabTitleSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(BrowserPaneStyle.text.opacity(active ? 1 : BrowserPaneStyle.tabTitleRest))
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
            } else {
                BrowserFavicon(image: favicon(tab.id))
            }
        }
        .padding(.leading, mode == .full ? BrowserPaneStyle.tabLeading : 0)
        .padding(.trailing, mode == .full ? BrowserPaneStyle.tabTrailing : 0)
        .frame(maxWidth: .infinity, minHeight: BrowserPaneStyle.tabHeight, alignment: mode == .full ? .leading : .center)
        // Folded to favicons, the tick keeps the row's leading edge, as the rail's does.
        .overlay(alignment: .leading) { if mode != .full { tick.padding(.leading, 2) } }
        .background(
            RoundedRectangle(cornerRadius: BrowserPaneStyle.tabRadius, style: .continuous)
                .fill(BrowserPaneStyle.text.opacity(
                    active ? BrowserPaneStyle.tabOnFill : (lifted ? BrowserPaneStyle.tabHoverFill : 0))))
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
