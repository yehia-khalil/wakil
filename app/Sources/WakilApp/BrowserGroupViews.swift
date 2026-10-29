import AppKit
import SwiftUI
import WakilKit

// MARK: 3d-i — groups in the browser's tab list

/// The pieces of a browser pane's tab list that know about groups (3d-i): what the strip shows in
/// which order, the drag into and out of a group, the group's chip, its rename field, the tab and
/// group menus and the error rows. The horizontal strip (`BrowserTabList`) draws them now; the
/// vertical column draws the same ones. Every press is a `browser_*` action (Invariant 2).

extension BrowserGroupColour {
    /// The swatch (ruling 5).
    var colour: Color {
        Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255)
    }

    /// The swatch's name in the Colour menu.
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// What a pane's tab list shows, in drawn order — the rule is `BrowserSnapshot.stripEntries`; this
/// adds what the drawing needs (the raised entry, the colours, the pinned section, the drop).
struct BrowserStripEntries {
    let snapshot: BrowserSnapshot
    let entries: [BrowserStripEntry]
    /// The head drawn above the line: tiles, then pinned groups (`BrowserPinnedSection`).
    let section: BrowserPinnedSection

    init(_ snapshot: BrowserSnapshot) {
        self.snapshot = snapshot
        entries = snapshot.stripEntries
        section = snapshot.pinnedSection
    }

    var ids: [String] { entries.map(\.id) }

    /// The entry the strip raises: the active tab (a collapsed group's, shown under its header).
    var active: String? { snapshot.stripActive }

    /// Entry `index` is a pinned tab, drawn as a tile.
    func isTile(_ index: Int) -> Bool { index < section.tiles }

    /// The colour under a tab of an expanded group.
    func underline(_ index: Int) -> Color? {
        guard case .tab(let t) = entries[index], let gid = t.group, let g = snapshot.group(gid) else { return nil }
        return g.colour.colour
    }

    /// The entry a tab is drawn as: its own, or its collapsed group's chip when it is not shown.
    func index(ofTab id: String) -> Int? {
        if let i = entries.firstIndex(where: { $0.id == id }) { return i }
        guard let gid = snapshot.tabs.first(where: { $0.id == id })?.group else { return nil }
        return entries.firstIndex { $0.id == "group:\(gid)" }
    }

    /// What a drop of entry `from` in `gap` does (`BrowserSnapshot.drop`): a move, a pin on the
    /// tiles, an unpin below the line; nil draws no line.
    func drop(_ from: Int, gap: Int, inSection: Bool) -> BrowserTabDrop? {
        snapshot.drop(from, gap: gap, inSection: inSection)
    }
}

/// The one press rule of a browser pane's tab list (3d-i), the strip's and the column's. A click on
/// a tab selects it and takes ⌘R off the group header. A click on a chip collapses or expands it at
/// once (a double-click no longer renames: waiting for it delayed every click; 3d-i walk) and puts the pull-request
/// group's header under ⌘R (ruling 19). Every press is a `browser_*` action (Invariant 2); none takes
/// the keyboard (Rule 6).
@MainActor
struct BrowserEntryPresses {
    let dispatch: (String, [String: JSONValue]) -> Void
    /// The group whose name is being edited.
    @Binding var renaming: String?
    /// The group header ⌘R acts on in this pane; nil, none.
    let headerFocus: String?
    let setHeaderFocus: (String?) -> Void
    /// The tab whose name is being edited in place (names).
    var renamingTab: String? = nil

    /// The entry's accessibility name: a tab's label where its title is drawn; its tooltip where it
    /// is not (a pinned tile, a folded entry: names spec §4).
    static func label(_ entry: BrowserStripEntry, titled: Bool = true) -> String {
        switch entry {
        case .chip(let g): BrowserGroupChip.label(g)
        case .tab(let t): titled ? t.label : t.tooltip
        }
    }

    /// The entry's tooltip: a tab's keeps its page title in reach, `<name> — <page title>` (names §3).
    static func help(_ entry: BrowserStripEntry) -> String {
        switch entry {
        case .chip(let g): BrowserGroupChip.label(g)
        case .tab(let t): t.tooltip
        }
    }

    func tap(_ entry: BrowserStripEntry) {
        switch entry {
        case .tab(let t):
            // A click in the open name field is the field's.
            guard renamingTab != t.id else { return }
            if headerFocus != nil { setHeaderFocus(nil) }
            select(t)
        case .chip(let g):
            // A click in the open name field is the field's.
            guard renaming != g.id else { return }
            // Only the pull-request group's header is under ⌘R (ruling 19). Set unconditionally: the
            // mouse-down cleared it (`canvasMouseDown`), whatever this view last drew.
            setHeaderFocus(g.kind == .pullRequests ? g.id : nil)
            toggle(g)
        }
    }

    /// The accessibility press: a tab selected, a group collapsed or expanded.
    func activate(_ entry: BrowserStripEntry) {
        switch entry {
        case .tab(let t): select(t)
        case .chip(let g): toggle(g)
        }
    }

    /// Collapse or expand: never the selected tab, never the keyboard (Rule 6).
    private func toggle(_ g: BrowserGroup) {
        dispatch("browser_group", ["action": .string(g.collapsed ? "expand" : "collapse"), "group": .string(g.id)])
    }

    private func select(_ tab: BrowserTab) {
        dispatch("browser_select_tab", ["tab": .string(tab.id)])
    }
}

/// A group's header (3d-i walk), one design in both modes: a soft pill tinted with the group's
/// colour, a solid dot in it, the name in medium weight and the member count in §6's meta style.
/// Collapsed, up to three of its members' favicons overlap before the count
/// (`BrowserSnapshot.preview`). In the column it fills the row and leads with a disclosure chevron
/// that turns 90° as it opens (§7's ease-out; still under Reduce Motion). No ×, no control of its
/// own: the whole pill is the entry. While renamed, the name is the field. The pull-request group
/// shows ↻ while a refresh runs; while ⌘R is on its header, the pill carries the editing edge.
struct BrowserGroupChip: View {
    let group: BrowserGroup
    /// A collapsed group's preview favicons, nil where a tab names none (a globe).
    var favicons: [NSImage?] = []
    /// The members, shown in meta style; nil, no count (the folded strip).
    var count: Int?
    /// The name drawn (false where the strip is folded: the dot and the count only).
    var showsName = true
    /// The column's header: the chevron, and the pill fills the row (its name truncating).
    var column = false
    var refreshing = false
    var renaming = false
    /// ⌘R acts on this header (the pull-request group's, ruling 19).
    var focused = false
    var commitName: (String) -> Void = { _ in }
    var endRename: (_ explicit: Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    static let dot: CGFloat = 8
    /// The tint: soft at rest, a step stronger under the pointer — still well under the text.
    static let fill: Double = 0.13
    static let hoverFill: Double = 0.19
    /// The pill in the strip's 26 pt entry and the column's 28 pt row.
    static let stripHeight: CGFloat = 22
    static let columnHeight: CGFloat = 24
    /// The leading inset; in the column the chevron's box follows it, then the dot (whose centre the
    /// members' line runs under — `BrowserTabColumn.lineX`).
    static let leading: CGFloat = 6
    static let chevronBox: CGFloat = 12
    static let spacing: CGFloat = 6
    /// The name over the tint: cool white, one step under full (§5's text rule).
    static let nameOpacity: Double = 0.92
    /// §7: eased out, never snappy; the value-materialising beat.
    static let turn: Double = 0.25

    var body: some View {
        let tint = group.colour.colour
        HStack(spacing: Self.spacing) {
            if column {
                Image(systemName: "chevron.right")
                    .font(.system(size: BrowserPaneStyle.closeGlyph - 1, weight: .bold))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .animation(reduceMotion ? nil : .easeOut(duration: Self.turn), value: group.collapsed)
                    .frame(width: Self.chevronBox)
                    .accessibilityHidden(true)
            }
            Circle().fill(tint)
                .frame(width: Self.dot, height: Self.dot)
                .accessibilityHidden(true)
            if renaming {
                BrowserGroupNameField(group: group, commit: commitName, end: endRename)
            } else if showsName {
                Text(group.name)
                    .font(.system(size: BrowserPaneStyle.tabTitleSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: !column, vertical: false)
                    .foregroundStyle(BrowserPaneStyle.text.opacity(Self.nameOpacity))
            }
            if column { Spacer(minLength: 0) }
            if group.collapsed, !favicons.isEmpty {
                BrowserFaviconStack(images: favicons, tint: tint.opacity(hovered ? Self.hoverFill : Self.fill))
            }
            if group.kind == .pullRequests, refreshing {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: BrowserPaneStyle.closeGlyph, weight: .semibold))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
                    .help("Refreshing the pull requests")
                    .accessibilityLabel("Refreshing")
                    .accessibilityIdentifier("browser.group.\(group.id).refreshing")
            }
            if let count {
                Text("\(count)")
                    .font(.system(size: BrowserPaneStyle.metaSize, design: .monospaced).monospacedDigit())
                    .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Self.leading)
        .padding(.trailing, Self.leading + 2)
        .frame(maxWidth: column ? .infinity : nil, alignment: .leading)
        .frame(height: column ? Self.columnHeight : Self.stripHeight)
        .background(Capsule(style: .continuous).fill(tint.opacity(hovered ? Self.hoverFill : Self.fill)))
        .overlay {
            if focused {
                Capsule(style: .continuous)
                    .strokeBorder(BrowserPaneStyle.tick.opacity(BrowserPaneStyle.fieldEditingEdge), lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: PaneStripStyle.hoverDuration), value: hovered)
        .onHover { hovered = $0 }
    }

    /// The chip's tooltip and spoken name.
    static func label(_ group: BrowserGroup) -> String {
        "\(group.name), group, \(group.collapsed ? "collapsed" : "expanded")"
    }
}

/// A collapsed group's members, up to three favicons overlapping, the first on top. Each sits on a
/// small square of the pill's own surface, so where they overlap the edge reads as a cut, not a smear.
struct BrowserFaviconStack: View {
    let images: [NSImage?]
    /// The pill's tint, laid over the slab under each favicon.
    let tint: Color

    static let overlap: CGFloat = 5

    var body: some View {
        HStack(spacing: -Self.overlap) {
            ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                BrowserFavicon(image: image)
                    .padding(1.5)
                    .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(PaneStripStyle.slab)
                        .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(tint)))
                    .zIndex(Double(images.count - i))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A group's name being edited (3d-i): it arrives focused with the name selected (Rule 3); focus
/// leaving keeps what was typed (Rule 2), Return keeps it too, and Esc puts the name back. An empty
/// name is not one: the old name stays (Rule 7, ignored rather than refused).
struct BrowserGroupNameField: View {
    let group: BrowserGroup
    let commit: (String) -> Void
    /// The field has gone; `explicit` when Return or Esc ended it, so the page may take the keyboard
    /// back — not when focus moved somewhere the operator chose.
    let end: (_ explicit: Bool) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var done = false

    static let width: CGFloat = 120

    var body: some View {
        TextField("Group name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: BrowserPaneStyle.tabTitleSize))
            .foregroundStyle(BrowserPaneStyle.text)
            .frame(width: Self.width)
            .focused($focused)
            .onSubmit { finish(keep: true, explicit: true) }
            .onExitCommand { finish(keep: false, explicit: true) }
            .onChange(of: focused) { _, now in
                if now { selectAll() } else { finish(keep: true, explicit: false) }
            }
            .onAppear {
                text = group.name
                // Asked as it appears, SwiftUI drops the request: once it is in the window. If the
                // window never gives it the keyboard, the chip goes back to the name.
                DispatchQueue.main.async {
                    focused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if !focused, !done { finish(keep: false, explicit: false) }
                    }
                }
            }
            .accessibilityLabel("Group name")
            .accessibilityIdentifier("browser.group.\(group.id).name")
    }

    private func finish(keep: Bool, explicit: Bool) {
        guard !done else { return }
        done = true
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if keep, !name.isEmpty, name != group.name { commit(name) }
        end(explicit)
    }

    /// The whole name selected in the field's own editor, so typing replaces it. The editor is the
    /// field's a turn or two after focus moves, so this asks again briefly.
    private func selectAll(tries: Int = 10) {
        guard focused else { return }
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.delegate is NSTextField,
              editor.string == text else {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { selectAll(tries: tries - 1) } }
            return
        }
        editor.selectAll(nil)
    }
}

/// A tab's name being edited in place (names spec §3), in a full strip entry or a column row: it
/// arrives focused with the shown label selected (Rule 3); Return or focus leaving keeps what was
/// typed through `RenameDraft` — the shown label unchanged does nothing, nothing left clears (Rule 2)
/// — and Esc puts the name back. It commits once (Rule 5). `BrowserGroupNameField`'s shape; it hands
/// the name to `commit`, which dispatches `browser_rename_tab` (Invariant 2), never sets it.
struct BrowserTabNameField: View {
    let tab: BrowserTab
    /// The name to dispatch; empty clears.
    let commit: (String) -> Void
    /// The field has gone; `explicit` when Return or Esc ended it.
    let end: (_ explicit: Bool) -> Void
    /// The window still shows the place (and organisation) this field was opened in. A tab id is the
    /// pane's and a pane id repeats from place to place, so after a switch the dispatch would land
    /// on another place's tab: then nothing is committed.
    let samePlace: () -> Bool

    @State private var text = ""
    /// The label as the field opened: what an unchanged line is compared with.
    @State private var shown = ""
    @FocusState private var focused: Bool
    @State private var done = false

    var body: some View {
        TextField("Tab name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: BrowserPaneStyle.tabTitleSize))
            .foregroundStyle(BrowserPaneStyle.text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focused)
            .onSubmit { finish(keep: true, explicit: true) }
            .onExitCommand { finish(keep: false, explicit: true) }
            .onChange(of: focused) { _, now in
                if now { selectAll() } else { finish(keep: true, explicit: false) }
            }
            .onAppear {
                text = tab.label
                shown = tab.label
                // As the group field: asked once it is in the window; never given the keyboard, the
                // entry goes back to its label.
                DispatchQueue.main.async {
                    focused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if !focused, !done { finish(keep: false, explicit: false) }
                    }
                }
            }
            // Gone without Return or Esc — the strip folded, the entry scrolled away: what was typed
            // is kept, as focus leaving keeps it (Rule 2).
            .onDisappear { finish(keep: true, explicit: false) }
            .accessibilityLabel("Tab name")
            .accessibilityIdentifier("browser.tab.\(tab.id).name")
    }

    private func finish(keep: Bool, explicit: Bool) {
        guard !done else { return }
        done = true
        if keep, samePlace(), let name = RenameDraft.decide(typed: text, shown: shown).name { commit(name) }
        end(explicit)
    }

    /// The whole label selected in the field's own editor, so typing replaces it (as the group field).
    private func selectAll(tries: Int = 10) {
        guard focused else { return }
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.delegate is NSTextField,
              editor.string == text else {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { selectAll(tries: tries - 1) } }
            return
        }
        editor.selectAll(nil)
    }
}

/// The mark after a renamed tab's name (names spec §3): a small pencil at the title's rest opacity,
/// saying the name is the operator's. The page title is in the entry's tooltip.
struct BrowserTabRenamedMark: View {
    let tab: String

    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: BrowserPaneStyle.tabTitleSize - 3))
            .foregroundStyle(BrowserPaneStyle.text.opacity(PaneStripStyle.tabTitleRest))
            .fixedSize()
            .accessibilityLabel("Renamed")
            .accessibilityIdentifier("browser.tab.\(tab).customMark")
    }
}

/// What the tab and group menus act through, and what they need to know.
struct BrowserGroupMenuContext {
    let snapshot: BrowserSnapshot
    /// The active project's name, for *Pin to <project>*; empty with none (the item is disabled).
    let project: String
    /// A refresh of the pull-request list runs: *Refresh* waits for it (Rule 5).
    let refreshing: Bool
    let dispatch: (String, [String: JSONValue]) -> Void
    /// *Refresh* on the pull-request group (`WindowModel.refreshBrowserPullRequests`).
    let refreshPullRequests: () -> Void
    /// Opens the rename field on a group (Rule 3).
    let rename: (String) -> Void
    /// *New Group…*: makes a group of the tab and opens its rename field.
    let newGroup: (String) -> Void
    /// *Rename Tab…* where the entry draws its title (a full strip entry, a column row): its name
    /// becomes the field, in place (Rule 3).
    let renameTab: (String) -> Void
    /// *Rename Tab…* where it does not (a pinned tile, a folded entry): ⌘P on the name step (names,
    /// Calls made 12).
    let renameTabInPalette: (String) -> Void
    /// The window still shows the place this pane was drawn in (`BrowserTabNameField.samePlace`).
    let samePlace: () -> Bool

    var pinTitle: String { "Pin to \(project.isEmpty ? "Project" : project)" }
}

/// A tab's menu (Global Constraints' copy): Rename Tab… and Clear Name when it has one (names), New
/// Group…, Add to Group, Remove from Group, Pin to <project> or Unpin (Unpin Group on a member of a
/// pinned group), Pin Current Page, Close Tab. Nothing here asks (Rule 1) and nothing selects the tab
/// or takes the keyboard (Rule 6) — but *New Group…* and *Rename Tab…*, whose fields arrive focused.
/// A pull-request row is not renamed (3d-i ruling 18: a listing, never saved): neither item is there.
struct BrowserTabMenu: View {
    let tab: BrowserTab
    let context: BrowserGroupMenuContext
    /// The entry draws its title, so *Rename Tab…* edits it in place; else it opens the palette.
    var inPlace = true

    var body: some View {
        let s = context.snapshot
        if tab.pullRequest == nil {
            Button("Rename Tab…") { inPlace ? context.renameTab(tab.id) : context.renameTabInPalette(tab.id) }
            if tab.name != nil {
                Button("Clear Name") {
                    context.dispatch("browser_rename_tab", ["tab": .string(tab.id), "name": .string("")])
                }
            }
            Divider()
        }
        let pinned = s.isPinned(tab)
        // A tab pinned itself stays out of groups; a tab of a pinned group may leave it.
        let targets = s.groups.filter { $0.kind != .pullRequests && $0.id != tab.group }
        Button("New Group…") { context.newGroup(tab.id) }
            .disabled(tab.pin != nil)
        Menu("Add to Group") {
            ForEach(targets, id: \.id) { g in
                Button(g.name) { context.dispatch("browser_move_tab", ["tab": .string(tab.id), "group": .string(g.id)]) }
            }
        }
        .disabled(tab.pin != nil || targets.isEmpty)
        if tab.group != nil {
            Button("Remove from Group") {
                context.dispatch("browser_move_tab", ["tab": .string(tab.id), "group": .string("")])
            }
        }
        Divider()
        if pinned {
            // A member of a pinned group unpins the whole group: the label says so.
            Button(tab.pin == nil ? "Unpin Group" : "Unpin") {
                context.dispatch("browser_unpin", ["tab": .string(tab.id)])
            }
        } else {
            Button(context.pinTitle) { context.dispatch("browser_pin", ["tab": .string(tab.id)]) }
                .disabled(context.project.isEmpty)
        }
        if tab.pin != nil {
            Button("Pin Current Page") {
                context.dispatch("browser_pin", ["tab": .string(tab.id), "update": .bool(true)])
            }
        }
        Divider()
        Button("Close Tab") { context.dispatch("browser_close_tab", ["tab": .string(tab.id)]) }
    }
}

/// A group's menu (Global Constraints' copy): Rename…, Colour, Collapse or Expand, Pin to <project>
/// or Unpin and Update Pin, Ungroup, Close Group. The pull-request group's: Refresh, Collapse or
/// Expand, Pin to <project> or Unpin. Nothing asks (Rule 1); closing a group is undone tab by tab
/// with ⌘⇧T.
struct BrowserGroupMenu: View {
    let group: BrowserGroup
    let context: BrowserGroupMenuContext

    var body: some View {
        let id: JSONValue = .string(group.id)
        if group.kind == .pullRequests {
            Button("Refresh") { context.refreshPullRequests() }
                .disabled(context.refreshing)
            collapse(id)
            pin(id, update: false)
        } else {
            Button("Rename…") { context.rename(group.id) }
            Menu("Colour") {
                ForEach(BrowserGroupColour.allCases, id: \.self) { c in
                    Toggle(c.title, isOn: Binding(
                        get: { group.colour == c },
                        set: { _ in context.dispatch("browser_group", ["action": .string("recolour"), "group": id,
                                                                      "colour": .string(c.rawValue)]) }))
                }
            }
            collapse(id)
            Divider()
            pin(id, update: true)
            Divider()
            Button("Ungroup") { context.dispatch("browser_group", ["action": .string("ungroup"), "group": id]) }
            Button("Close Group") { context.dispatch("browser_group", ["action": .string("close"), "group": id]) }
        }
    }

    @ViewBuilder private func collapse(_ id: JSONValue) -> some View {
        Button(group.collapsed ? "Expand" : "Collapse") {
            context.dispatch("browser_group", ["action": .string(group.collapsed ? "expand" : "collapse"), "group": id])
        }
    }

    @ViewBuilder private func pin(_ id: JSONValue, update: Bool) -> some View {
        if group.pin != nil {
            Button("Unpin") { context.dispatch("browser_unpin", ["group": id]) }
            if update {
                Button("Update Pin") { context.dispatch("browser_pin", ["group": id, "update": .bool(true)]) }
            }
        } else {
            Button(context.pinTitle) { context.dispatch("browser_pin", ["group": id]) }
                .disabled(context.project.isEmpty)
        }
    }
}

/// An error under the tab list, whole and wrapping (Rule 8): the pins file that can't be read, the
/// pull-request refresh that failed. Selectable, in the caution amber; it blocks nothing.
struct BrowserStripErrorRow: View {
    let text: String
    let identifier: String

    var body: some View {
        Text(text)
            .font(.system(size: BrowserPaneStyle.lineSize))
            .foregroundStyle(BrowserPaneStyle.amber)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BrowserPaneStyle.rowInset)
            .padding(.vertical, 6)
            .accessibilityIdentifier(identifier)
    }
}
