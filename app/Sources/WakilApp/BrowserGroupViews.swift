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
/// adds what the drawing needs (the raised entry, the colours, the drag).
struct BrowserStripEntries {
    let snapshot: BrowserSnapshot
    let entries: [BrowserStripEntry]

    init(_ snapshot: BrowserSnapshot) {
        self.snapshot = snapshot
        entries = snapshot.stripEntries
    }

    var ids: [String] { entries.map(\.id) }

    /// The entry the strip raises: the active tab (a collapsed group's, shown under its header).
    var active: String? { snapshot.stripActive }

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

    /// The `browser_move_tab` a drag of entry `from` to index `to` makes, or nil when it would change
    /// nothing — a chip, a drop into the pull-request group, a pinned tab dropped among the others:
    /// no line is drawn for a drop that would do nothing. The tab lands before the entry now at
    /// `to` (counted without it), in that entry's group (`dropGroup`); before a chip or at the end,
    /// loose.
    func move(from: Int, to: Int) -> [String: JSONValue]? {
        guard entries.indices.contains(from), case .tab(let moving) = entries[from] else { return nil }
        var others = entries
        others.remove(at: from)
        let rest = snapshot.tabs.filter { $0.id != moving.id }
        // Where it lands in `tabs` once taken out: before the next shown tab, or before the first
        // tab of the group whose chip is next.
        let at: Int = {
            for entry in others.dropFirst(to) {
                switch entry {
                case .tab(let t): if let i = rest.firstIndex(where: { $0.id == t.id }) { return i }
                case .chip(let g): if let i = rest.firstIndex(where: { $0.group == g.id }) { return i }
                }
            }
            return rest.count
        }()
        var group: String?
        if to < others.count, case .tab = others[to] { group = snapshot.dropGroup(moving: moving.id, before: at) }
        // Only a drop that changes something is offered.
        var after = snapshot
        after.moveTab(moving.id, into: group, at: at)
        guard after.tabs.map(\.id) != snapshot.tabs.map(\.id) || after.tabs.map(\.group) != snapshot.tabs.map(\.group)
        else { return nil }
        return ["tab": .string(moving.id), "to": .integer(Int64(at)), "group": .string(group ?? "")]
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

    /// The entry's tooltip and accessibility name.
    static func label(_ entry: BrowserStripEntry) -> String {
        switch entry {
        case .chip(let g): BrowserGroupChip.label(g)
        case .tab(let t): t.label
        }
    }

    func tap(_ entry: BrowserStripEntry) {
        switch entry {
        case .tab(let t):
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

/// A group's chip (3d-i): an 8 pt dot in its colour and its name at the tab title's size;
/// collapsed, the tab it shows (`lastOpen`)'s favicon after the name. No ×. While renamed, the
/// name is the field. The pull-request group shows ↻ while a refresh runs.
struct BrowserGroupChip: View {
    let group: BrowserGroup
    /// The tab a collapsed group shows, its favicon beside the name.
    let favicon: NSImage?
    /// The name drawn (false where the strip is folded: the dot and the favicon only).
    var showsName = true
    var on = false
    var refreshing = false
    var renaming = false
    var commitName: (String) -> Void = { _ in }
    var endRename: (_ explicit: Bool) -> Void = { _ in }

    static let dot: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(group.colour.colour)
                .frame(width: Self.dot, height: Self.dot)
                .accessibilityHidden(true)
            if renaming {
                BrowserGroupNameField(group: group, commit: commitName, end: endRename)
            } else if showsName {
                Text(group.name)
                    .font(.system(size: BrowserPaneStyle.tabTitleSize))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(BrowserPaneStyle.text.opacity(on ? 1 : PaneStripStyle.tabTitleRest))
            }
            if group.collapsed {
                BrowserFavicon(image: favicon)
            }
            if group.kind == .pullRequests, refreshing {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: BrowserPaneStyle.closeGlyph, weight: .semibold))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(RailTreatment.kindOpacity))
                    .help("Refreshing the pull requests")
                    .accessibilityLabel("Refreshing")
                    .accessibilityIdentifier("browser.group.\(group.id).refreshing")
            }
        }
    }

    /// The chip's tooltip and spoken name.
    static func label(_ group: BrowserGroup) -> String {
        "\(group.name), group, \(group.collapsed ? "collapsed" : "expanded")"
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

    var pinTitle: String { "Pin to \(project.isEmpty ? "Project" : project)" }
}

/// A tab's menu (Global Constraints' copy): New Group…, Add to Group, Remove from Group, Pin to
/// <project> or Unpin (Unpin Group on a member of a pinned group), Pin Current Page, Close Tab. Nothing here asks (Rule 1) and nothing selects
/// the tab or takes the keyboard (Rule 6) — but *New Group…*, whose name field arrives focused.
struct BrowserTabMenu: View {
    let tab: BrowserTab
    let context: BrowserGroupMenuContext

    var body: some View {
        let s = context.snapshot
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
