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

/// The browser pane's drawing (3c-i, Task 8b): `Browser.dc.html`'s numbers, each read from the
/// token another pane already draws with where one exists — the editor's colours, the rail's tick
/// and row lift, the settings form's micro-label and field — and named here only where the browser
/// is the first to need it.
enum BrowserPaneStyle {
    static let text = EditorPaneStyle.text
    static let amber = EditorPaneStyle.amber
    static let slab = EditorPaneStyle.slab
    static let tick = PaneStripStyle.tick

    // MARK: The tab list — the shared strip's (`PaneStripStyle`)

    /// The pane's two header rows, the tab strip and the address row: 32 pt each.
    static let rowHeight = PaneStripStyle.rowHeight
    /// Each header row's inset from the pane's edge, and the room above and below a row the
    /// downloads take.
    static let rowInset = PaneStripStyle.rowInset
    static let rowPadding: CGFloat = 4
    static let paneRadius = PaneStripStyle.paneRadius
    /// A whole entry's width, and a folded one's: 9 + tick 2 + 9 + favicon 12 + 9 + × 16 + 11.
    static let tabWidth = PaneStripStyle.tabWidth
    static let tabFoldedWidth: CGFloat = 68
    /// `.tab .ttl` at 12 px (`PaneStripStyle.tabTitleRest` at rest).
    static let tabTitleSize = SettingsScale.body
    /// The favicon or globe, 12 px; the globe's stroke at the micro-label's step.
    static let glyphSize: CGFloat = 12
    static let globeGlyph: CGFloat = 11
    static let closeGlyph = PaneStripStyle.closeGlyph
    static let closeHit = PaneStripStyle.closeHit
    static let hoverDuration = PaneStripStyle.hoverDuration

    // MARK: The header and the page

    /// The address field: the settings form's `.field` inset and radius, 24 pt high so the
    /// address row is 32, its fill the form field's 0.05, and while it is edited an edge in the
    /// tick's colour.
    static let fieldInsetX: CGFloat = 9
    static let fieldHeight: CGFloat = 24
    static let fieldRadius: CGFloat = 5
    static let fieldFill: Double = 0.05
    static let fieldEditingEdge: Double = 0.6
    /// The border token (`PaneStripStyle.edge`): the address field's 1 px edge.
    static let edge = PaneStripStyle.edge
    /// NOT SECURE: the micro label's mono line, `letter-spacing: 1.2px`.
    static let monoTracking: CGFloat = 1.2
    /// Between the padlock and NOT SECURE, and between them and the URL.
    static let lockGap: CGFloat = 5

    /// Between controls in a row.
    static let gap: CGFloat = 8
    /// ‹ › ↻ ×'s hit square and glyph (`ChangesIconButtonStyle` draws them).
    static let controlSize = PaneStripStyle.glyphBox
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
    /// A running download's bar: wide enough to read how far it is, narrow enough for its row.
    static let downloadBarWidth: CGFloat = 72
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
/// every tab, by group (3d-i) — loose and pinned tabs on their own, each group's under its name.
/// With the list hidden it carries the ⌄ itself. Tabular digits and no tracking, so 15 reads as one
/// number.
struct BrowserTabCount: View {
    let snapshot: BrowserSnapshot
    let listMode: BrowserTabListMode
    let dispatch: (String, [String: JSONValue]) -> Void

    /// Runs of tabs in drawn order, each a group's (by id) or loose (nil).
    private var runs: [(group: String?, tabs: [BrowserTab])] {
        var out: [(group: String?, tabs: [BrowserTab])] = []
        for tab in snapshot.tabs {
            let gid = tab.group.flatMap { snapshot.group($0)?.id }
            if let last = out.last, last.group == gid { out[out.count - 1].tabs.append(tab) } else { out.append((gid, [tab])) }
        }
        return out
    }

    var body: some View {
        let tabs = snapshot.tabs
        Menu {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                if let gid = run.group, let g = snapshot.group(gid) {
                    Section(g.name) { items(run.tabs) }
                } else {
                    Section { items(run.tabs) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                PaneStripNumber(value: tabs.count)
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

    private func items(_ tabs: [BrowserTab]) -> some View {
        ForEach(tabs, id: \.id) { t in
            Button(t.label) { dispatch("browser_select_tab", ["tab": .string(t.id)]) }
        }
    }
}

/// The tab strip (`PaneTabStrip`, the shared one): entries 200 pt wide shrinking to 96 before
/// the strip scrolls; tick, favicon, title, × on hover; folded, an entry is its favicon and ×.
/// Every press is a `browser_*` action (Invariant 2): select, close, `browser_move_tab` for a drag
/// (Safari's behaviours kept), ⌘T's `browser_new_tab` on the ＋.
///
/// **Groups (3d-i).** Each group's chip (`BrowserGroupChip`, its own width, no ×) leads its tabs,
/// which carry a 2 pt line in its colour; a collapsed group is its chip alone, but for the active tab when it is the group's, which stays beside it (`BrowserSnapshot.showsTab`). A click on a chip
/// collapses or expands it at once (rename is the group menu's) — and
/// puts the group's header under the keyboard's ⌘R (`browserHeaderFocus`); a click on a tab takes
/// it away. A drag into a group's run joins it, out of it leaves it (`BrowserStripEntries.move`).
/// The tab and group menus are on a right-click; a pinned tab armed by ⌘W shows its tip under it.
struct BrowserTabList: View {
    let snapshot: BrowserSnapshot
    let mode: BrowserTabListMode
    let favicon: (String) -> NSImage?
    /// Which sites are production and which the active environment's (3c-ii): each tagged entry's dot.
    let sites: BrowserSites
    let dispatch: (String, [String: JSONValue]) -> Void
    /// The menus' context (3d-i).
    let menus: BrowserGroupMenuContext
    /// The group whose name is being edited.
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


    private var presses: BrowserEntryPresses {
        BrowserEntryPresses(dispatch: dispatch, renaming: $renaming, headerFocus: headerFocus,
                            setHeaderFocus: setHeaderFocus)
    }

    var body: some View {
        let list = BrowserStripEntries(snapshot)
        let entries = list.entries
        PaneTabStrip(
            ids: list.ids, active: list.active,
            width: mode == .full ? .shrink : .fixed(mode.entryWidth),
            stripIds: PaneStripIds(
                tabs: "browser.tabs",
                moreLeft: "browser.tabs.moreLeft", moreLeftCount: "browser.tabs.moreLeft.count",
                moreRight: "browser.tabs.moreRight", moreRightCount: "browser.tabs.moreRight.count",
                newTab: "browser.newTab",
                entry: { entries[$0].identifier },
                close: { "\(entries[$0].identifier).close" }),
            entry: { index, active in
                switch entries[index] {
                case .chip(let g): chip(g, active: active)
                case .tab(let t): tabEntry(t, active: active)
                }
            },
            label: { BrowserEntryPresses.label(entries[$0]) },
            tap: { presses.tap(entries[$0]) },
            activate: { presses.activate(entries[$0]) },
            move: { from, to in
                if let params = list.move(from: from, to: to) { dispatch("browser_move_tab", params) }
            },
            close: { index in
                if case .tab(let t) = entries[index] { dispatch("browser_close_tab", ["tab": .string(t.id)]) }
            },
            newTab: PaneStripNewTab(help: "New Tab") { dispatch("browser_new_tab", [:]) },
            // A middle-click on a tab closes it, as its × does (a pinned one too, in one press); a
            // group's chip takes none.
            middleClick: { index in
                if let tab = entries[index].middleClickCloses { dispatch("browser_close_tab", ["tab": .string(tab)]) }
            },
            middleClickEnabled: middleClickEnabled,
            closable: { if case .tab = entries[$0] { true } else { false } },
            contextMenu: { index in
                switch entries[index] {
                case .chip(let g): AnyView(BrowserGroupMenu(group: g, context: menus))
                case .tab(let t): AnyView(BrowserTabMenu(tab: t, context: menus))
                }
            },
            canMove: { from, to in list.move(from: from, to: to) != nil },
            underline: { list.underline($0) },
            naturalWidth: { if case .chip = entries[$0] { true } else { false } },
            tip: closeArmed.flatMap { tab in
                list.index(ofTab: tab).map {
                    PaneStripTip(index: $0, text: BrowserPinnedClose.tip, identifier: "browser.tab.\(tab).closeTip")
                }
            })
    }

    @ViewBuilder private func tabEntry(_ tab: BrowserTab, active: Bool) -> some View {
        HStack(spacing: PaneStripStyle.tabGap) {
            BrowserFavicon(image: favicon(tab.id))
                // Ruling 4: every tagged tab carries its tag's dot, a background one too —
                // on the favicon's corner, so a folded entry keeps its width.
                .overlay(alignment: .topTrailing) {
                    if let tag = sites.tag(tab.url) {
                        BrowserSiteTagDot(tag: tag, tab: tab.id).offset(x: 3, y: -3)
                    }
                }
            if mode == .full {
                Text(tab.label)
                    .font(.system(size: BrowserPaneStyle.tabTitleSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(BrowserPaneStyle.text.opacity(active ? 1 : PaneStripStyle.tabTitleRest))
            }
        }
    }

    private func chip(_ g: BrowserGroup, active: Bool) -> some View {
        BrowserGroupChip(
            group: g, favicon: g.lastOpen.flatMap { favicon($0) }, showsName: mode == .full, on: active,
            refreshing: g.kind == .pullRequests && menus.refreshing, renaming: renaming == g.id,
            commitName: { name in
                dispatch("browser_group", ["action": .string("rename"), "group": .string(g.id), "name": .string(name)])
            },
            endRename: { explicit in
                if renaming == g.id { renaming = nil }
                renameEnded(explicit)
            })
            // The group header under ⌘R: the address field's editing edge, in the tick's colour.
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .overlay {
                if headerFocus == g.id, g.kind == .pullRequests {
                    RoundedRectangle(cornerRadius: PaneStripStyle.tabRadius - 1, style: .continuous)
                        .strokeBorder(BrowserPaneStyle.tick.opacity(BrowserPaneStyle.fieldEditingEdge), lineWidth: 1)
                }
            }
    }
}

// MARK: 3c-iii — the ★ menu

/// ★ at the address row's right, before the tag chip (ruling 12): one menu — Bookmark This Page or
/// Remove Bookmark, then the organisation's bookmarks, newest first, each opening in the active tab.
/// The glyph is filled in amber while the active tab's page is bookmarked. ⌘D is the menu bar's
/// `Add Bookmark` (ruling 13); it is not bound here too, so the key has one owner, which acts on the
/// focused browser pane and passes the key on anywhere else.
struct BrowserBookmarkMenu: View {
    let choices: BrowserBookmarkChoices
    let dispatch: (String, [String: JSONValue]) -> Void

    var body: some View {
        Menu {
            Button(choices.toggleTitle) { dispatch("browser_bookmark", ["on": .bool(!choices.bookmarked)]) }
                .disabled(!choices.canToggle)
                .accessibilityIdentifier("browser.bookmark.toggle")
            Divider()
            if choices.entries.isEmpty {
                Text(BrowserBookmarkChoices.none)
            } else {
                ForEach(choices.entries, id: \.url) { mark in
                    Button(mark.title.isEmpty ? BrowserSuggestions.bareURL(mark.url) : mark.title) {
                        dispatch("browser_navigate", ["input": .string(mark.url)])
                    }
                }
            }
        } label: {
            Image(systemName: choices.bookmarked ? "star.fill" : "star")
                .font(.system(size: BrowserPaneStyle.controlGlyph, weight: .medium))
                .foregroundStyle(choices.bookmarked
                                 ? BrowserPaneStyle.amber : BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                .frame(width: BrowserPaneStyle.controlSize, height: BrowserPaneStyle.controlSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(choices.bookmarked ? "Bookmarked — Remove Bookmark (⌘D)" : "Bookmarks — Bookmark This Page (⌘D)")
        .accessibilityLabel("Bookmarks")
        .accessibilityValue(choices.bookmarked ? "bookmarked" : "")
        .accessibilityIdentifier("browser.bookmarks")
    }
}

// MARK: 3c-ii — the site's tag and the agent's allowance

/// The tag's words and colour (ruling 4): `Production` in §5's red whichever environment is active,
/// else `In <environment>` — the environment's name as declared — in §5's green.
extension BrowserSiteTag {
    var words: String {
        switch self {
        case .production: "Production"
        case .environment(let name): "In \(name)"
        }
    }

    var colour: Color {
        switch self {
        case .production: Color(red: 0.910, green: 0.361, blue: 0.361)    // #e85c5c
        case .environment: Color(red: 0.545, green: 0.878, blue: 0.784)   // #8be0c8
        }
    }
}

/// The active tab's tag, a chip at the address row's right (`Browser.dc.html`'s `.chip`): the
/// micro label's size, its tint under it. The words are drawn as the copy states them, so what the
/// operator reads is what the tree carries.
struct BrowserSiteTagChip: View {
    let tag: BrowserSiteTag

    var body: some View {
        Text(tag.words)
            .font(.system(size: SettingsScale.micro, weight: .medium))
            .tracking(BrowserPaneStyle.monoTracking)
            .foregroundStyle(tag.colour)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tag.colour.opacity(0.12)))
            .fixedSize()
            .help(tag == .production
                  ? "A production site: every act the agent proposes here asks first."
                  : "A site of the active environment's API.")
            .accessibilityIdentifier("browser.siteTag")
    }
}

/// A tagged tab's 6 pt dot in the strip, in the tag's colour. No words of its own: the chip says
/// them for the active tab, and the tree should carry a tag's words once.
struct BrowserSiteTagDot: View {
    let tag: BrowserSiteTag
    let tab: String

    var body: some View {
        Circle()
            .fill(tag.colour)
            .frame(width: 6, height: 6)
            .accessibilityElement()
            .accessibilityIdentifier("browser.tab.\(tab).tag")
    }
}

/// `agent allowed`, beside the chip while the on-screen conversation may act on the active tab's
/// site (3c-ii), and its ×, which takes the site off that conversation's list
/// (`browser_revoke_site`, operator-only): its next act there asks again. The × asks nothing (Rule 1:
/// it ends a permission, it destroys nothing) and moves no focus (Rule 6).
struct BrowserAgentAllowedMark: View {
    let site: String
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text("agent allowed")
                .font(.system(size: SettingsScale.micro, weight: .medium))
                .tracking(BrowserPaneStyle.monoTracking)
                .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                .lineLimit(1)
            Button(action: revoke) {
                Image(systemName: "xmark")
                    .font(.system(size: BrowserPaneStyle.closeGlyph, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChangesIconButtonStyle())
            .help("Stop the agent acting on \(site) — its next act there asks first")
            .accessibilityLabel("Revoke for \(site)")
            .accessibilityIdentifier("browser.agentAllowed.revoke")
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .padding(.vertical, 1)
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(BrowserPaneStyle.text.opacity(BrowserPaneStyle.edge), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.agentAllowed")
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
