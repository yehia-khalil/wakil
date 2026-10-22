import AppKit
import WakilKit
import SwiftUI

/// The editor's left column (3b-ii): Files, Search or Changes (3b-iii). It decides nothing — rows, steps, selection and
/// width come from WakilKit's tested functions; every change is an `editor_*` action through `dispatch`.
/// Its own state is the query being typed, the type-ahead prefix and the live drag width. The selected
/// row and result are the pane's (`EditorPane`), so they outlive the column being hidden (Rule 6).
struct EditorColumn: View {
    let column: EditorColumnState
    /// The tree's rows, built once by `EditorPane` (`treeRows`), which also reads them for save-as.
    let rows: [EditorTreeRow]
    /// Roots whose list has not arrived yet: drawn as loading (Rule 5).
    let pendingRoots: [String]
    /// The window's git status (3b-iii): the Changes view's rows and the tree's status letters.
    let gitRoots: [GitRootState]
    let search: EditorSearchState
    let paneWidth: CGFloat
    let dispatch: (String, [String: JSONValue]) async -> Void
    /// `dispatch`, its refusal thrown here rather than put on the status line: the name field shows
    /// it under itself (3b-iv, Rule 8).
    let dispatchThrowing: (String, [String: JSONValue]) async throws -> Void
    /// A file tab is in front: the Files header's reveal button has something to reveal (3b-ii-b).
    let canReveal: Bool
    let reveal: () -> Void
    @Binding var selected: String?
    @Binding var selectedResult: String?
    /// The view the operator asked to type in (⌘B / ⌘⇧F, the strip toggle, the header): it takes the
    /// keyboard once it shows, then this clears. Nothing else moves the keyboard here — an agent's
    /// `editor_tree` shows the column and leaves the operator where they are (Rule 6).
    @Binding var focusWanted: EditorColumnView?
    /// Whether the tree, the query or the results hold the keyboard, for the pane's own focus moves.
    @Binding var hasKeyboard: Bool
    /// The operator's reveal: the file row to select once it is among `rows` (the folders above it open
    /// a turn after the action). Selecting it scrolls to it and leaves the keyboard where it is (Rule 6).
    @Binding var pendingReveal: String?
    /// The file a single click in the tree just brought forward: browsing, so the keyboard stays in
    /// the tree even when that file's tab is already open and pinned (Rule 6). The pane reads it once.
    @Binding var browsed: String?
    /// 3a-ii. The Changes view's commit box and write buttons, every root's, from the window.
    let changes: EditorChangesControls

    @State private var dragWidth: Double?
    @State private var query = ""
    @State private var debounce = EditorDebounce(delay: .milliseconds(250))
    @State private var typed = ""
    @State private var typedReset: Task<Void, Never>?
    /// The query this column last sent (or took from the store): the field searches only when it differs,
    /// and the store's echo of it never rewrites the field (Rule 2).
    @State private var sent: String?
    /// Result groups closed, by root and by root + "/" + path: view-local, like a list's disclosure.
    @State private var collapsed: Set<String> = []
    @FocusState private var queryFocused: Bool
    @FocusState private var treeFocused: Bool
    @FocusState private var resultsFocused: Bool
    @FocusState private var changesFocused: Bool
    @State private var replaceText = ""
    @State private var replaceDebounce = EditorDebounce(delay: .milliseconds(250))
    /// The field's text this column last sent (or took from the store), as `sent` is for the query.
    @State private var replaceSent: String?
    /// The file header under the pointer, which shows its *Replace in this file*.
    @State private var hoveredFile: String?
    @FocusState private var replaceFocused: Bool
    /// The operator's own ▸ asked for the Replace field: it takes the keyboard once drawn, then this
    /// clears. An agent's `editor_search {replace}` shows the field and moves nothing (Rule 6).
    @State private var wantReplaceFocus = false
    /// The tree's inline name field (3b-iv): creating under a folder, or renaming a row.
    private enum NameEdit: Equatable { case create(folder: String, kind: String), rename(path: String) }
    @State private var nameEdit: NameEdit?
    @State private var nameText = ""
    @State private var nameError: String?
    @State private var nameBusy = false
    @FocusState private var nameFocused: Bool
    /// The row under the pointer: a root shows its **+** while hovered or selected.
    @State private var hovered: String?
    /// 3a-ii-b: ✨ under the pointer, which shows ✕ while its draft runs.
    @State private var draftHovered: String?
    /// Bumped by every row the operator picks (`activate`): a commit in flight moves the selection
    /// to its new path only if no pick came after it started (Rule 6).
    @State private var picks = 0
    /// The Changes row or group header under the pointer (3a-ii): it shows its write buttons.
    @State private var hoveredChange: String?
    /// The root whose message box holds the keyboard (3a-ii).
    @FocusState private var messageFocused: String?
    /// ⌘⏎ and ↑/↓ for the message box holding the keyboard, ahead of the menu (⌘⏎ is Maximize Pane).
    @State private var messageKeys = ChangesMessageKeys()

    /// The name a row's root goes by in identifiers: `editor.tree.row:<root name>/<relative>`.
    private func rootName(_ row: EditorTreeRow) -> String { (row.root as NSString).lastPathComponent }

    private func rowPath(_ row: EditorTreeRow) -> String {
        "\(rootName(row))\(row.relative.isEmpty ? "" : "/" + row.relative)"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                switch column.view {
                case .files: tree
                case .search: searchView
                case .changes: changesView
                }
            }
            .frame(width: dragWidth ?? editorColumnWidth(column.width, paneWidth: paneWidth))
            edge
        }
        .background(EditorPaneStyle.slab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.column")
        // Rule 3: the view the operator asked for takes the keyboard when it shows. A request for a
        // view that is not the one showing is dropped, never kept for later.
        .onAppear { takeWantedKeyboard(dropOther: true); takeReveal(rows) }
        .onChange(of: column.view) { _, _ in takeWantedKeyboard(dropOther: true) }
        .onChange(of: focusWanted) { _, _ in takeWantedKeyboard(dropOther: false) }
        .onChange(of: queryFocused || treeFocused || resultsFocused || changesFocused || messageFocused != nil) { _, now in
            hasKeyboard = now
        }
        .onChange(of: messageFocused) { _, root in watchMessageKeys(root) }
        .onDisappear { messageKeys.stop() }
        .onChange(of: rows) { old, now in
            selected = editorTreeSelection(after: selected, previous: old, now: now)
            takeReveal(now)
            dropOrphanedNameEdit(now)
        }
        .onChange(of: pendingReveal) { _, _ in takeReveal(rows) }
    }

    /// The revealed row, once drawn: selected (the tree's `.onChange(of: selected)` scrolls to it),
    /// never taking the keyboard (Rule 6).
    private func takeReveal(_ now: [EditorTreeRow]) {
        guard let p = pendingReveal, now.contains(where: { $0.id == p }) else { return }
        pendingReveal = nil
        selected = p
    }

    private func takeWantedKeyboard(dropOther: Bool) {
        guard let wanted = focusWanted else { return }
        guard wanted == column.view else {
            if dropOther { focusWanted = nil }
            return
        }
        focusWanted = nil
        // A turn later: the view that just switched in is in the window by then.
        Task { @MainActor in
            switch wanted {
            case .search: queryFocused = true
            case .changes: changesFocused = true
            case .files: treeFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Files") {
                focusWanted = .files
                Task { await dispatch("editor_tree", ["view": .string("files"), "shown": .bool(true)]) }
            }
                .buttonStyle(.plain).opacity(column.view == .files ? 1 : 0.5)
                .accessibilityIdentifier("editor.column.files")
            Button("Search") {
                focusWanted = .search
                Task { await dispatch("editor_tree", ["view": .string("search"), "shown": .bool(true)]) }
            }
                .buttonStyle(.plain).opacity(column.view == .search ? 1 : 0.5)
                .accessibilityIdentifier("editor.column.search")
            Button("Changes") {
                focusWanted = .changes
                Task { await dispatch("editor_tree", ["view": .string("changes"), "shown": .bool(true)]) }
            }
                .buttonStyle(.plain).opacity(column.view == .changes ? 1 : 0.5)
                .accessibilityIdentifier("editor.column.changes")
            Spacer()
            if column.view == .files {
                Button(action: reveal) { Image(systemName: "scope").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .disabled(!canReveal)
                    .opacity(canReveal ? 0.9 : 0.35)
                    .help(canReveal ? "Reveal Active File in Tree" : "No file tab in front: nothing to reveal")
                    .accessibilityIdentifier("editor.tree.reveal")
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(EditorPaneStyle.text)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var edge: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            .padding(.horizontal, 2).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in dragWidth = editorColumnWidth(column.width + g.translation.width, paneWidth: paneWidth) }
                .onEnded { _ in
                    guard let w = dragWidth else { return }
                    Task { await dispatch("editor_tree", ["width": .number(w)]); dragWidth = nil }
                })
            .accessibilityIdentifier("editor.column.edge")
    }

    // MARK: - Files

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if nameEdit == .rename(path: row.id) {
                            nameField(.rename(path: row.id), depth: row.depth, placeholder: row.name).id(row.id)
                        } else {
                            treeRow(row).id(row.id)
                        }
                        if case .create(row.id, let kind) = nameEdit {
                            nameField(.create(folder: row.id, kind: kind), depth: row.depth + 1,
                                      placeholder: kind == "dir" ? "folder name" : "file name")
                        }
                    }
                    ForEach(pendingRoots, id: \.self) { root in
                        HStack(spacing: 6) {
                            EditorBusyTick(label: "listing", identifier: "editor.tree.loading")
                            Text((root as NSString).lastPathComponent)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: selected) { _, now in if let now { proxy.scrollTo(now) } }
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($treeFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: treeKey)
    }

    @ViewBuilder
    private func treeRow(_ row: EditorTreeRow) -> some View {
        // Hoisted, not interpolated as calls: the identifier harvest reads `\(name)` only
        // (`interpolation` in e2e/driver/identifiers.go), so a call inside one would harvest a family
        // no click can match.
        let path = rowPath(row), root = rootName(row)
        if row.kind == .note {
            // Not a row the selection rests on (ruling 6): nothing to tap, nothing to step to.
            Text(row.name)
                .font(.system(size: 11, design: .monospaced))
                .italic()
                .foregroundStyle(EditorPaneStyle.text.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10 + CGFloat(row.depth * 12))
                .padding(.vertical, 3)
                .accessibilityIdentifier("editor.tree.note:\(root)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                rowLabel(row)
                    .padding(.leading, 6 + CGFloat(row.depth * 12))
                    .padding(.trailing, 6)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        if row.id == selected {
                            RoundedRectangle(cornerRadius: 4).stroke(EditorPaneStyle.violet, lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    // One tap gesture reading the click count: a `count: 2` gesture beside it would hold
                    // every single click for the double-click interval. The second click of a
                    // double-click keeps a file's preview tab; on a folder it does nothing, so the
                    // first click's expand or collapse stands.
                    .onTapGesture {
                        if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                            if row.kind == .file { activate(row, keep: true) }
                        } else {
                            activate(row)
                        }
                    }
                    // A container, not a combined button: the tree reads a button's text as nothing, and
                    // the row's name is what the operator reads (as a search result row does).
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("editor.tree.row:\(path)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(row.id == selected ? .isSelected : [])
                    .accessibilityAction { activate(row) }
                    .onHover { inside in
                        if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
                    }
                    // 3b-iv: a root makes; a file renames and trashes; a folder or repo does all four.
                    .contextMenu {
                        if row.kind != .file {
                            Button("New File") { startCreate(in: row.id, kind: "file") }
                            Button("New Folder") { startCreate(in: row.id, kind: "dir") }
                        }
                        if row.kind != .root {
                            if row.kind != .file { Divider() }
                            Button("Rename") { startRename(row) }
                            Button("Move to Trash") { trash(row) }
                        }
                    }
                if let error = row.error {
                    // Rule 8, in the Git pane's root-error style: whole, wrapping, selectable.
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.leading, 14 + CGFloat(row.depth * 12))
                        .padding(.trailing, 6)
                        .accessibilityIdentifier("editor.tree.error:\(path)")
                }
            }
            // A root's gap sits above its row, outside the selection outline, so the name stays
            // centred in it.
            .padding(.top, row.kind == .root ? 6 : 0)
        }
    }

    private func rowLabel(_ row: EditorTreeRow) -> some View {
        // Hoisted for the identifier harvest, as in `treeRow`.
        let path = rowPath(row), root = rootName(row)
        return HStack(spacing: 5) {
            if row.loading { EditorBusyTick(label: "loading", identifier: "editor.tree.loading") }
            switch row.kind {
            case .root, .repo, .folder:
                Image(systemName: row.open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 10)
            case .file:
                EditorFileIcon(editorFileGlyph(forPath: row.id))
            case .note:
                Spacer().frame(width: 10)
            }
            if row.kind == .repo {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
            }
            Text(row.name)
                .font(row.kind == .root
                      ? .system(size: 11, weight: .medium, design: .monospaced)
                      : .system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if row.kind == .file,
               let letter = editorTreeStatus(root: row.root, relative: row.relative, roots: gitRoots) {
                Spacer(minLength: 6)
                Text(letter)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.tone(gitStatusTone(letter)))
                    // The row's git status letter (3b-iii), named so it can be found per row: the
                    // tree reads it as a bare "M" or "?" beside the name.
                    .accessibilityIdentifier("editor.tree.status:\(path)")
            }
            if row.kind == .root, hovered == row.id || selected == row.id {
                Spacer(minLength: 6)
                Menu {
                    Button("New File") { startCreate(in: row.id, kind: "file") }
                    Button("New Folder") { startCreate(in: row.id, kind: "dir") }
                } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New File or Folder")
                    .accessibilityIdentifier("editor.tree.add:\(root)")
            }
        }
        .foregroundStyle(EditorPaneStyle.text.opacity(row.kind == .root ? 0.62 : 0.86))
        .opacity(row.dimmed ? 0.45 : 1)
        .frame(height: row.kind == .root ? 20 : 18)
    }

    // MARK: - Changes (3b-iii)

    private var changesRows: [EditorChangesRow] {
        editorChangesRows(gitRoots, closed: column.changesClosed, closedGroups: column.changesClosedGroups)
    }
    private var changesHighlight: EditorChangesRow? { editorChangesResolve(column.changesHighlight, roots: gitRoots) }

    /// The view's one spacing scale: 4, 8, 12.
    private enum ChangesSpace {
        static let s: CGFloat = 4, m: CGFloat = 8, l: CGFloat = 12
        /// Every row and header line, so the list keeps one rhythm.
        static let row: CGFloat = 22
    }

    /// Dimmed read text — a branch, a folder, a count, the placeholder: §3's 0.55, which clears the
    /// 4.5:1 floor on the slab and on the lifted box (0.46 does on neither). Chevrons keep 0.46.
    private static let dimmed = RailTreatment.kindOpacity

    /// Whether the operator closed this group (3a-ii): the pane's column, through an action.
    private func groupOpen(_ root: String, _ group: GitGroup) -> Bool {
        !column.changesClosedGroups.contains(EditorChangesGroup(root: root, group: group.rawValue))
    }

    private var changesView: some View {
        // A root that is not a git repository has nothing to change or commit: it is not drawn.
        let shown = gitRoots.filter(gitRootIsRepository)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if gitRoots.isEmpty || shown.isEmpty {
                        Text(gitRoots.isEmpty ? "No project roots to read" : "No git repositories in this project")
                            .font(.system(size: 12)).foregroundStyle(EditorPaneStyle.text.opacity(Self.dimmed))
                            .padding(.horizontal, ChangesSpace.m)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.root) { i, root in
                        if i > 0 {
                            // One hairline between roots, in the column edge's tone.
                            Rectangle().fill(EditorPaneStyle.text.opacity(0.08)).frame(height: 0.5)
                                .padding(.vertical, ChangesSpace.l)
                        }
                        changesRoot(root)
                    }
                }
                .padding(.vertical, ChangesSpace.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focused($changesFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in changesKey(press) }
            .onChange(of: changesHighlight) { _, now in
                guard let now else { return }
                // A closed group stays closed (Rule 6): a step skips it, and nothing here opens it.
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(now) }
            }
        }
    }

    /// One root's block: its header, then — only while it has changes — the message box and Commit,
    /// then its groups. A clean root is its header line alone.
    @ViewBuilder
    private func changesRoot(_ root: GitRootState) -> some View {
        let closed = column.changesClosed.contains(root.root)
        let boxed = !closed && root.error == nil && !root.files.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            changesHeader(root, closed: closed, boxed: boxed)
            if let detail = gitRootErrorDetail(root) {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("editor.changes.rootError:\(root.name)")
            }
            if boxed {
                commitBox(root)
            } else {
                changesError(root)
            }
            if !closed {
                ForEach(gitListSections(root), id: \.group) { section in
                    changesGroupLabel(section.group, root: root, count: section.rows.count)
                    if groupOpen(root.root, section.group) {
                        ForEach(section.rows, id: \.self) { changesRow($0, root: root) }
                    }
                }
            }
        }
        .padding(.horizontal, ChangesSpace.m)
    }

    @ViewBuilder
    private func changesHeader(_ root: GitRootState, closed: Bool, boxed: Bool) -> some View {
        let detail = gitRootDetail(root)
        let clean = root.error == nil && !root.loading && root.files.isEmpty && !detail.isEmpty
        HStack(spacing: ChangesSpace.m) {
            HStack(spacing: ChangesSpace.s) {
                if root.loading { EditorBusyTick(label: "loading", identifier: "editor.changes.loading") }
                (Text(root.name).foregroundStyle(EditorPaneStyle.text.opacity(0.86))
                    + Text(detail.isEmpty ? "" : "  " + detail).foregroundStyle(EditorPaneStyle.text.opacity(Self.dimmed)))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: ChangesSpace.m)
                remoteButton(root)
                if !root.files.isEmpty {
                    Image(systemName: closed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.46))
                }
            }
            .frame(height: ChangesSpace.row)
            .contentShape(Rectangle())
            .onTapGesture { if !root.files.isEmpty { toggleRoot(root.root, closed: closed) } }
            // One line for the tree, `api · main · clean`: the name and its dimmed rest read as one.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(gitRootLine(root))
            .accessibilityIdentifier("editor.changes.root:\(root.name)")
            .accessibilityAction { if !root.files.isEmpty { toggleRoot(root.root, closed: closed) } }
            // 3a-ii: who a commit here is authored as, for the box's placeholder; read again with each
            // root shown.
            .task(id: root.root) { await changes.refreshIdentity(root.root) }
            // Text, as a row is: as a button its line never reached the tree (AXDescription only).
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isStaticText)
            // A clean root has no box, but its last commit can still be undone from here.
            if clean {
                cleanRootActions(root)
            } else if !boxed {
                // A collapsed root has no commit bar: its write in flight shows here (Rules 4, 5).
                rootBusyActions(root)
            }
        }
    }

    /// 3a-iii-a: Publish, Push, Pull or Sync as the branch needs (`changesRemoteButton`); nothing when
    /// even. Disabled while the root has a write in flight (Rule 5), which shows its spinner and Cancel.
    @ViewBuilder
    private func remoteButton(_ root: GitRootState) -> some View {
        let button = changesRemoteButton(root)
        if button != .none, root.error == nil {
            Button(button.title) { Task { await changes.remote(root.root, button) } }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).stroke(EditorPaneStyle.text.opacity(0.18), lineWidth: 0.5))
                .disabled(changes.inFlight.contains(root.root))
                .help(button == .sync ? "Pull, then push" : button.title)
                .accessibilityIdentifier("editor.changes.\(root.name).remote")
        }
    }

    /// A root line's spinner and Cancel while its write runs: a clean root's, or a collapsed one's.
    @ViewBuilder
    private func rootBusyActions(_ root: GitRootState) -> some View {
        let key = root.root
        if changes.inFlight.contains(key) {
            ProgressView().controlSize(.mini)
            Button("Cancel") { changes.cancel(key) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.75))
                .accessibilityIdentifier("editor.changes.\(root.name).cancel")
        }
    }

    /// A clean root's line end: the spinner and Cancel while a write runs, and ⋯ with Undo Last Commit.
    @ViewBuilder
    private func cleanRootActions(_ root: GitRootState) -> some View {
        let key = root.root
        let busy = changes.inFlight.contains(key)
        rootBusyActions(root)
        Menu {
            Button("Undo Last Commit") { Task { await changes.undo(key) } }
                .accessibilityIdentifier("editor.changes.\(root.name).undo")
            Button("Fetch") { Task { await changes.fetch(key) } }
                .accessibilityIdentifier("editor.changes.\(root.name).fetch")
        } label: { Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(EditorPaneStyle.text.opacity(0.62))
            .disabled(busy)
            .help("More Commit Actions")
            .accessibilityIdentifier("editor.changes.\(root.name).menu")
    }

    private func toggleRoot(_ root: String, closed: Bool) {
        Task { await dispatch(closed ? "editor_changes_expand" : "editor_changes_collapse", ["root": .string(root)]) }
    }

    private func toggleGroup(_ root: String, _ group: GitGroup) {
        let action = groupOpen(root, group) ? "editor_changes_group_collapse" : "editor_changes_group_expand"
        Task { await dispatch(action, ["root": .string(root), "group": .string(group.rawValue)]) }
    }

    private func changesRow(_ row: GitFileRow, root: GitRootState) -> some View {
        let ref = EditorChangesRow(root: root.root, path: row.path, group: row.group.rawValue)
        let on = ref == changesHighlight
        let id = "editor.changes.row:\(root.name)/\(row.path):\(row.group.rawValue)"
        // Spelled out whole, not built from `id`, so the identifier harvest counts each button.
        let ids = ChangesWriteIds(
            stage: "editor.changes.row:\(root.name)/\(row.path):\(row.group.rawValue).stage",
            unstage: "editor.changes.row:\(root.name)/\(row.path):\(row.group.rawValue).unstage",
            discard: "editor.changes.row:\(root.name)/\(row.path):\(row.group.rawValue).discard")
        let fill = on ? EditorPaneStyle.lifted : EditorPaneStyle.slab
        // The buttons lie over the row's end, left of its letter, not inside its tap gesture: a press
        // never selects the row.
        return changesRowLine(row, ref: ref, on: on, id: id)
            .padding(.leading, ChangesSpace.l).padding(.trailing, ChangesSpace.s)
            .frame(height: ChangesSpace.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) { if on { Rectangle().fill(EditorPaneStyle.violet).frame(width: 2) } }
            .overlay(alignment: .trailing) {
                if hoveredChange == id || on {
                    changesWriteButtons(row.group, root: root, paths: [row.path], ids: ids)
                        .padding(.horizontal, ChangesSpace.s)
                        .frame(height: ChangesSpace.row)
                        .background(fill)
                        .padding(.trailing, ChangesSpace.s + ChangesSpace.l + ChangesSpace.s)
                }
            }
            .onHover { inside in
                if inside { hoveredChange = id } else if hoveredChange == id { hoveredChange = nil }
            }
            .id(ref)
    }

    private func changesRowLine(_ row: GitFileRow, ref: EditorChangesRow, on: Bool, id: String) -> some View {
        let folder = gitRowFolder(row)
        return HStack(spacing: ChangesSpace.s) {
            EditorFileIcon(editorFileGlyph(forPath: row.path))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
            (Text(gitRowName(row)).foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                + Text(folder.isEmpty ? "" : "  " + folder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text.opacity(Self.dimmed)))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: ChangesSpace.s)
            Text(row.status)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.tone(gitStatusTone(row.status)))
                .frame(width: ChangesSpace.l, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // One tap gesture reading the click count, as the tree's and the tabs': a `count: 2` gesture
        // beside it held every single click for the double-click interval (3b-iii walk).
        .onTapGesture { selectChange(ref, pin: NSApp.currentEvent?.clickCount ?? 1 >= 2) }
        // The tree reads `M, app.txt` (letter, then the path or `old → new`) whatever the drawn order.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.status), \(gitRowLabel(row))")
        .accessibilityIdentifier(id)
        .accessibilityAction { selectChange(ref, pin: false) }
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(on ? [.isStaticText, .isSelected] : .isStaticText)
    }

    // MARK: - Changes writes (3a-ii)

    /// A group's header — its chevron, name and dimmed count, which collapse it — and, on hover (or
    /// while its highlighted row is in it), the group's buttons at its right.
    private func changesGroupLabel(_ group: GitGroup, root: GitRootState, count: Int) -> some View {
        let key = "group:\(root.root):\(group.rawValue)"
        let open = groupOpen(root.root, group)
        // A closed group's buttons show on hover only: its highlighted row is not drawn.
        let current = open && (changesHighlight.map { $0.root == root.root && $0.group == group.rawValue } ?? false)
        return HStack(spacing: ChangesSpace.s) {
            HStack(spacing: ChangesSpace.s) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.46))
                    .frame(width: ChangesSpace.m)
                Text(gitGroupLabel(group))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                Text("\(count)")
                    .foregroundStyle(EditorPaneStyle.text.opacity(Self.dimmed))
                Spacer(minLength: ChangesSpace.m)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleGroup(root.root, group) }
            // Text, as a row is, reading `Staged, 2`; the press is its accessibility action.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("editor.changes.group:\(root.name)/\(group.rawValue)")
            .accessibilityAction { toggleGroup(root.root, group) }
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isStaticText)
            if hoveredChange == key || current {
                // Spelled out whole, as the row's, for the identifier harvest.
                changesWriteButtons(group, root: root, paths: nil, ids: ChangesWriteIds(
                    stage: "editor.changes.\(root.name).\(group.rawValue).stageAll",
                    unstage: "editor.changes.\(root.name).\(group.rawValue).unstageAll",
                    discard: "editor.changes.\(root.name).\(group.rawValue).discardAll"))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.trailing, ChangesSpace.s + ChangesSpace.l + ChangesSpace.s)
        .frame(height: ChangesSpace.row)
        .padding(.top, ChangesSpace.m)
        .onHover { inside in
            if inside { hoveredChange = key } else if hoveredChange == key { hoveredChange = nil }
        }
    }

    /// **+** stage and **↺** discard under Changes and Untracked, **−** unstage under Staged: one row's
    /// (`paths`) or the whole group's (`paths` nil, the `…All` identifiers). Nothing asks (Rule 1:
    /// a discard goes to the Trash); disabled while the root's write runs (Rule 5).
    @ViewBuilder
    private func changesWriteButtons(_ group: GitGroup, root: GitRootState, paths: [String]?, ids: ChangesWriteIds) -> some View {
        let all = paths == nil ? "All" : ""
        let target: GitGroup? = paths == nil ? group : nil
        let busy = changes.inFlight.contains(root.root)
        HStack(spacing: ChangesSpace.m) {
            if group == .staged {
                changesWriteButton("minus", help: "Unstage\(all.isEmpty ? "" : " All")", id: ids.unstage) {
                    await changes.unstage(root.root, paths, target)
                }
            } else {
                changesWriteButton("arrow.uturn.backward", help: "Discard\(all.isEmpty ? "" : " All")",
                                   id: ids.discard) {
                    await changes.discard(root.root, paths, target)
                }
                changesWriteButton("plus", help: "Stage\(all.isEmpty ? "" : " All")", id: ids.stage) {
                    await changes.stage(root.root, paths, target)
                }
            }
        }
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
    }

    private func changesWriteButton(_ symbol: String, help: String, id: String,
                                    _ act: @escaping () async -> Void) -> some View {
        Button { Task { await act() } } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(ChangesIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }

    /// The root's last write error, whole (Rule 8), in the caution colour.
    @ViewBuilder
    private func changesError(_ root: GitRootState) -> some View {
        if let error = changes.errors[root.root] {
            Text(error)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.amber)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, ChangesSpace.s)
                .accessibilityIdentifier("editor.changes.\(root.name).error")
        }
        // 3a-iii-a: the background fetch's failure, quiet — a note, never an error (call 9).
        if changes.errors[root.root] == nil, let note = changes.notes[root.root] {
            Text(note)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text.opacity(Self.dimmed))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, ChangesSpace.s)
                .accessibilityIdentifier("editor.changes.\(root.name).note")
        }
    }

    /// The root's message box — its placeholder naming who commits and ⌘⏎ — then one Commit bar the
    /// box's width with the ▾ menu at its right edge, the spinner and Cancel while a write runs, and
    /// the last write's error, whole (Rule 8).
    @ViewBuilder
    private func commitBox(_ root: GitRootState) -> some View {
        let key = root.root
        let draft = changes.messages[key] ?? ""
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let busy = changes.inFlight.contains(key)
        // Rule 9: with nothing staged the default is everything, and the button says so.
        let staged = root.files.contains { $0.group == .staged }
        let title = staged ? "Commit" : "Commit All"
        let hint = changes.placeholders[key] ?? "Message (⌘⏎ to commit)"
        VStack(alignment: .leading, spacing: ChangesSpace.m) {
            // The box's height: the draft as it wraps at the box's width, at most six lines, or the
            // placeholder's wrapped lines when it is drawn. Measured by a hidden copy in the editor's font
            // and inset; the editor and the placeholder lie over it, so the editor covers every line the
            // box draws and a click anywhere in it reaches the text view (3a-ii walk: a wrapped placeholder
            // had made the box three lines tall over a one-line editor; 3a-ii-b walk: a wrapped draft was
            // counted by its newlines and scrolled in a one-line box). Past six lines the editor scrolls.
            ZStack(alignment: .topLeading) {
                commitHint(draft.isEmpty ? " " : draft + (draft.hasSuffix("\n") ? " " : ""))
                    .lineLimit(6)
                    .padding(.trailing, 5)          // the text view's line-fragment padding, right side
                    .padding(.vertical, 2)
                    .hidden()
                if draft.isEmpty { commitHint(hint).hidden() }
            }
            .padding(.trailing, Self.draftButtonRoom)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(get: { changes.messages[key] ?? "" }, set: { changes.edit(key, $0) }))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.text)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.automatic)
                        .focused($messageFocused, equals: key)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Commit message")
                        .accessibilityIdentifier("editor.changes.\(root.name).message")
                    if draft.isEmpty {
                        // Read by the tree as the box's hint: who a commit here is authored as.
                        commitHint(hint)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("editor.changes.\(root.name).hint")
                    }
                }
                // The text and its placeholder stop short of ✨ in the box's corner, as the measuring copy does.
                .padding(.trailing, Self.draftButtonRoom)
            }
            .padding(ChangesSpace.s)
            // The padding ring is the box too: a click there focuses the editor, caret at the end. A
            // sibling under the editor, not a gesture on its parent, so the text view keeps its clicks.
            .background {
                RoundedRectangle(cornerRadius: 4).fill(EditorPaneStyle.lifted)
                    .onTapGesture { focusMessage(key) }
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(messageFocused == key ? EditorPaneStyle.violet : EditorPaneStyle.text.opacity(0.12),
                        lineWidth: 1)
                .allowsHitTesting(false))
            .overlay(alignment: .topTrailing) { draftButton(root) }
            HStack(spacing: 0) {
                if busy {
                    HStack(spacing: ChangesSpace.m) {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { changes.cancel(key) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                            .accessibilityIdentifier("editor.changes.\(root.name).cancel")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Button { Task { await changes.commit(key) } } label: {
                        HStack(spacing: ChangesSpace.s) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                            Text(title)
                        }
                        .frame(maxWidth: .infinity, minHeight: ChangesSpace.row)
                        .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                        .disabled(empty)
                        .opacity(empty ? 0.45 : 1)
                        .accessibilityLabel(title)
                        .accessibilityIdentifier("editor.changes.\(root.name).commit")
                }
                Rectangle().fill(EditorPaneStyle.text.opacity(0.18)).frame(width: 0.5, height: ChangesSpace.l)
                Menu {
                    Button(title) { Task { await changes.commit(key) } }
                        .disabled(empty)
                        .accessibilityIdentifier("editor.changes.\(root.name).menuCommit")
                    Divider()
                    Button("Amend Last Commit") { Task { await changes.amend(key) } }
                        .accessibilityIdentifier("editor.changes.\(root.name).amend")
                    Button("Undo Last Commit") { Task { await changes.undo(key) } }
                        .accessibilityIdentifier("editor.changes.\(root.name).undo")
                    Divider()
                    Button("Fetch") { Task { await changes.fetch(key) } }
                        .accessibilityIdentifier("editor.changes.\(root.name).fetch")
                } label: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                    .frame(width: ChangesSpace.row + ChangesSpace.s, height: ChangesSpace.row)
                    .disabled(busy)
                    .help("More Commit Actions")
                    .accessibilityIdentifier("editor.changes.\(root.name).menu")
            }
            .frame(height: ChangesSpace.row)
            .background(EditorPaneStyle.violet.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            changesError(root)
        }
        .padding(.top, ChangesSpace.s)
    }

    /// The message box's placeholder, onto the editor's first line, where its caret stands.
    /// The width ✨ takes in the message box's top-right corner: the text wraps before it.
    static let draftButtonRoom: CGFloat = 20

    private func commitHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(EditorPaneStyle.text.opacity(Self.dimmed))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 5)
    }

    /// Focuses the root's message box from a click on its padding, the caret at the end of the draft.
    /// 3a-ii-b: ✨ in the box's corner — the quick model drafts what Commit would commit into the box.
    /// While it runs: a spinner, ✕ under the pointer to cancel (Rules 4, 5). A draft that replaced
    /// text is one ⌘Z away (R3); the keyboard stays in the box (Rule 6). Hidden when the organisation
    /// switched commit drafts off.
    @ViewBuilder
    private func draftButton(_ root: GitRootState) -> some View {
        let key = root.root
        if changes.draftsOn {
            let drafting = changes.drafting.contains(key)
            Button {
                if drafting { changes.cancelDraft(key); return }
                // The keyboard comes back to the box only if it was there at the press: a draft that
                // lands while the operator types elsewhere must not take their keys (final review I3).
                let hadKeyboard = messageFocused == key
                Task {
                    // The window registers the draft's ⌘Z (`changesLastDraft`), whoever asked for it.
                    guard await changes.draft(key) != nil, hadKeyboard, messageFocused == key else { return }
                    focusMessage(key)
                }
            } label: {
                Group {
                    if drafting && draftHovered != key {
                        ProgressView().controlSize(.mini)
                    } else {
                        // A symbol in the pane's own ink, not the emoji's yellow (3a-ii-b walk).
                        Image(systemName: drafting ? "xmark" : "sparkles").font(.system(size: 10, weight: .medium))
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(EditorPaneStyle.text.opacity(Self.dimmed))
            .onHover { inside in draftHovered = inside ? key : (draftHovered == key ? nil : draftHovered) }
            .help(drafting ? "Cancel Draft" : "Draft Message")
            .accessibilityLabel(drafting ? "Cancel Draft" : "Draft Message")
            .accessibilityIdentifier("editor.changes.\(root.name).draft")
            .padding(2)
        }
    }

    private func focusMessage(_ key: String) {
        messageFocused = key
        Task { @MainActor in
            guard messageFocused == key, let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        }
    }

    /// The box that took the keyboard gets ⌘⏎ and ↑/↓ (`ChangesMessageKeys`); none, nothing is watched.
    private func watchMessageKeys(_ root: String?) {
        guard let root else { messageKeys.stop(); return }
        let changes = self.changes
        messageKeys.start(window: NSApp.keyWindow,
                          commit: { Task { await changes.commit(root) } },
                          step: { delta in changes.historyStep(root, delta) })
    }

    private func selectChange(_ ref: EditorChangesRow, pin: Bool) {
        changesFocused = true
        var p: [String: JSONValue] = ["root": .string(ref.root), "path": .string(ref.path), "group": .string(ref.group)]
        if pin { p["pin"] = .bool(true) }
        Task { await dispatch("editor_changes_select", p) }
    }

    /// ↑↓ step (and open, from Task 3); Return opens the highlighted row. Chords and other keys pass.
    private func changesKey(_ press: KeyPress) -> KeyPress.Result {
        // The message box's keys are its own: ↑ moves its caret, Return breaks its line (3a-ii).
        guard !isChord(press), messageFocused == nil else { return .ignored }
        switch press.key {
        case .upArrow: Task { await dispatch("editor_changes_step", ["delta": .integer(-1)]) }
        case .downArrow: Task { await dispatch("editor_changes_step", ["delta": .integer(1)]) }
        case .return:
            guard let h = changesHighlight else { return .ignored }
            selectChange(h, pin: false)
        default: return .ignored
        }
        return .handled
    }

    private func activate(_ row: EditorTreeRow, keep: Bool = false) {
        guard row.kind != .note else { return }
        selected = row.id
        picks += 1
        treeFocused = true
        switch row.kind {
        case .file:
            if !keep { browsed = row.id }
            Task { await dispatch("editor_open", ["path": .string(row.id), "preview": .bool(!keep)]) }
        case .root, .repo, .folder:
            Task { await dispatch(row.open ? "editor_tree_collapse" : "editor_tree_expand", ["path": .string(row.id)]) }
        case .note: break
        }
    }

    /// A chord (⌘, ⌃, ⌥) is never the tree's: it belongs to the menu or the system.
    private func isChord(_ press: KeyPress) -> Bool {
        !press.modifiers.intersection([.command, .control, .option]).isEmpty
    }

    private func treeKey(_ press: KeyPress) -> KeyPress.Result {
        // The name field has the keyboard: arrows and type-ahead do not move the selection under it.
        // A refused edit left open after a click away does not: the tree keeps its keys meanwhile.
        guard !nameFocused else { return .ignored }
        // ⌘⌫ and F2 (3b-iv), matched by character (`editorTreeKeyCommand`): the Delete key sends
        // U+007F, which `KeyEquivalent.delete` (U+0008) never matched, and F2 has no `KeyEquivalent`.
        let chord = press.modifiers.intersection([.command, .control, .option, .shift])
        let characters = press.characters.isEmpty ? String(press.key.character) : press.characters
        if let command = editorTreeKeyCommand(characters: characters, command: chord.contains(.command),
                                              otherChord: !chord.subtracting(.command).isEmpty),
           let row = rows.first(where: { $0.id == selected }) {
            switch command {
            case .trash: trash(row)
            case .rename: startRename(row)
            }
            return .handled
        }
        guard !isChord(press) else { return .ignored }
        switch press.key {
        case .upArrow:
            selected = editorTreeStep(rows, selected: selected, .up)
        case .downArrow:
            selected = editorTreeStep(rows, selected: selected, .down)
        case .rightArrow:
            if let row = rows.first(where: { $0.id == selected }), row.kind != .file, row.kind != .note, !row.open {
                Task { await dispatch("editor_tree_expand", ["path": .string(row.id)]) }
            }
        case .leftArrow:
            guard let s = selected else { return .handled }
            let move = editorTreeLeft(rows, selected: s)
            if let collapse = move.collapse {
                Task { await dispatch("editor_tree_collapse", ["path": .string(collapse)]) }
            } else if let to = move.select, rows.contains(where: { $0.id == to }) {
                selected = to
            }
        case .return:
            if let row = rows.first(where: { $0.id == selected }) { activate(row) }
        default:
            let letters = CharacterSet.alphanumerics.union(.punctuationCharacters)
            guard !press.characters.isEmpty,
                  press.characters.unicodeScalars.allSatisfy({ letters.contains($0) }) else { return .ignored }
            typed += press.characters
            typedReset?.cancel()
            typedReset = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                if !Task.isCancelled { typed = "" }
            }
            if let hit = editorTreeTypeAhead(rows, selected: selected, prefix: typed) { selected = hit }
        }
        return .handled
    }

    // MARK: - File operations (3b-iv)

    // The tree's create, rename and Move to Trash. The view only wires: the target path is
    // `editorRenameTarget`'s, the selection after a trash is `editorTreeSelection`'s (the column's
    // `.onChange(of: rows)`), and every change is one `editor_*` action.

    /// Starting an edit while one is open (the menus stay live, and a right-click does not move the
    /// keyboard) commits the open one first, so its text is never dropped (Rule 2); while one is in
    /// flight the new start is ignored (Rule 5).
    private func mayStartEdit() -> Bool {
        guard !nameBusy else { return false }
        if nameEdit != nil { commitName() }
        return true
    }

    private func startCreate(in folder: String, kind: String) {
        guard mayStartEdit() else { return }
        nameText = ""; nameError = nil
        nameEdit = .create(folder: folder, kind: kind)
        // The field sits among the folder's children, so a closed folder opens first.
        if let row = rows.first(where: { $0.id == folder }), !row.open {
            Task { await dispatch("editor_tree_expand", ["path": .string(folder)]) }
        }
    }

    private func startRename(_ row: EditorTreeRow) {
        guard row.kind == .file || row.kind == .folder || row.kind == .repo else { return }
        guard mayStartEdit() else { return }
        nameText = row.name; nameError = nil
        nameEdit = .rename(path: row.id)
    }

    /// Only the action: the trashed row leaves `rows`, and the column's `.onChange(of: rows)` moves
    /// the selection to the next survivor, else the previous (ruling F1).
    private func trash(_ row: EditorTreeRow) {
        guard row.kind == .file || row.kind == .folder || row.kind == .repo else { return }
        Task { await dispatch("editor_trash", ["path": .string(row.id)]) }
    }

    /// Rule 2: focus leaving commits, Enter is a shortcut (`refocus`: Enter gives the tree the keyboard
    /// back, as Esc does, and on a refusal keeps it in the field). Rule 5: a second commit while one is
    /// in flight is dropped. Rule 8: a refusal stays under the field, whole, with the text kept.
    /// Rule 6: a commit from focus loss never takes the keyboard back, and the selection follows the
    /// new path only if it was on the edited row (the folder, for a create) and the operator has
    /// picked no row since.
    private func commitName(refocus: Bool = false) {
        guard let edit = nameEdit, !nameBusy else { return }
        let typed = nameText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { cancelName(refocus: refocus); return }
        let picksAtStart = picks
        nameBusy = true
        Task {
            do {
                let moveTo: String?
                var madeFile = false
                switch edit {
                case .create(let folder, let kind):
                    // The placeholder name is dropped: the target resolves against `folder` itself.
                    let path = editorRenameTarget(of: folder + "/_", typed: typed)
                    let onFolder = selected == folder
                    try await dispatchThrowing("editor_create", ["path": .string(path), "kind": .string(kind)])
                    moveTo = kind == "dir" && onFolder ? path : nil
                    madeFile = kind != "dir"
                case .rename(let path):
                    let to = editorRenameTarget(of: path, typed: typed)
                    let onRow = selected == path
                    try await dispatchThrowing("editor_rename", ["path": .string(path), "to": .string(to)])
                    moveTo = onRow ? to : nil
                }
                // The column's `.onChange(of: rows)` may have moved the selection off the old path
                // meanwhile; only a pick by the operator keeps the new path from taking it.
                if let moveTo, picks == picksAtStart { selected = moveTo }
                nameBusy = false
                if nameEdit == edit {
                    nameEdit = nil; nameError = nil
                    // A new file's pinned tab takes the cursor (spec; Rule 3): the tree never pulls
                    // the keyboard back from it.
                    if refocus, !madeFile { treeFocused = true }
                } else if nameEdit != nil {
                    // An edit started while this one landed: its field was disabled when it appeared.
                    focusNameField()
                }
            } catch {
                nameBusy = false
                if nameEdit != edit {
                    // Superseded by an edit started from a menu (which typed nothing yet: the field
                    // was disabled): the refused one comes back with its text and its error.
                    nameEdit = edit
                    nameText = typed
                }
                nameError = String(describing: error)
                // Enabled again first: a disabled field cannot take the keyboard.
                if refocus { nameFocused = true }
            }
        }
    }

    /// Esc: clears `nameEdit` first, so the blur that follows finds nothing to commit.
    private func cancelName(refocus: Bool = true) {
        nameEdit = nil; nameError = nil; nameText = ""
        if refocus { treeFocused = true }
    }

    /// The row a field edits, or creates under, has left the tree (an agent moved it): the field
    /// goes with it, or the tree's keys would stay ignored with no field to type in.
    private func dropOrphanedNameEdit(_ now: [EditorTreeRow]) {
        guard let edit = nameEdit, !nameBusy else { return }
        let id: String
        switch edit {
        case .create(let folder, _): id = folder
        case .rename(let path): id = path
        }
        if !now.contains(where: { $0.id == id }) { cancelName(refocus: false) }
    }

    /// `edit` is the edit this field was drawn for: its blur commits that edit only, never one started
    /// from a menu as it went (Rule 2).
    private func nameField(_ edit: NameEdit, depth: Int, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $nameText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text)
                .focused($nameFocused)
                .disabled(nameBusy)
                .onSubmit { commitName(refocus: true) }
                .onKeyPress(.escape) { cancelName(); return .handled }
                .onChange(of: nameFocused) { _, now in
                    if !now, nameEdit == edit { commitName() }
                    // Rule 9, once the field holds the keyboard: from F2 the tree gives it up later
                    // than from the menu, so `onAppear` alone found the tree still first responder.
                    if now, case .rename = edit, nameEdit == edit { selectStem() }
                }
                // Rule 3: the field arrives focused. Rule 9: a rename preselects the stem only.
                .onAppear(perform: focusNameField)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(EditorPaneStyle.lifted, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(EditorPaneStyle.violet, lineWidth: 1))
                .accessibilityIdentifier("editor.tree.name")
            if let nameError {
                Text(editorTreeShortError(nameError, roots: rows.filter { $0.kind == .root }.map(\.id)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("editor.tree.name.error")
            }
        }
        // Lined up with a row's name: past the row's inset and its chevron column (`rowLabel`), less
        // the field's own inset.
        .padding(.leading, 17 + CGFloat(depth * 12)).padding(.trailing, 6).padding(.vertical, 2)
    }

    /// A turn later, as the replace field takes it (`takeReplaceFocus`): set while F2's key press is
    /// still being handled, the tree kept the keyboard and the field never got it.
    private func focusNameField() {
        Task { @MainActor in nameFocused = true }
    }

    /// Selects the name before its last `.` in the field editor (the whole name when there is no
    /// `.`, or when its only `.` leads it), once the field editor holds the keyboard: it is tried a
    /// turn later and, while the window's first responder is not yet a text view, for a few more.
    private func selectStem(tries: Int = 5) {
        let name = nameText as NSString
        let dot = name.range(of: ".", options: .backwards).location
        let stemLength = dot == NSNotFound || dot == 0 ? name.length : dot
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                if tries > 1 { selectStem(tries: tries - 1) }
                return
            }
            editor.setSelectedRange(NSRange(location: 0, length: stemLength))
        }
    }

    // MARK: - Search

    private var searchView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    let opening = !search.replace.shown
                    wantReplaceFocus = opening          // Rule 3, once the field is drawn
                    Task { await dispatch("editor_search", ["replace": opening ? .string(replaceText) : .null]) }
                } label: {
                    Image(systemName: search.replace.shown ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(EditorPaneStyle.text.opacity(0.7))
                .help("Replace")
                .accessibilityIdentifier("editor.search.replaceToggle")
                TextField("Search files", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text)
                    .focused($queryFocused)
                    // Rule 2: the search runs on a pause; Return only runs it sooner.
                    .onChange(of: query) { _, q in
                        // Back to what was last searched (a backspace within the pause): the pending
                        // search for the deleted text must not run, nor its echo rewrite the field.
                        guard q != sent else { debounce.cancel(); return }
                        debounce.schedule { await runSearch(q) }
                    }
                    .onSubmit { debounce.cancel(); Task { await runSearch(query) } }
                    .onKeyPress(.downArrow) {
                        guard let first = resultIds.first else { return .ignored }
                        if selectedResult == nil || !resultIds.contains(selectedResult!) { selectedResult = first }
                        resultsFocused = true
                        return .handled
                    }
                    .accessibilityIdentifier("editor.search.query")
                switchToggle("Aa", on: search.caseSensitive, id: "editor.search.case", help: "Match case") {
                    dispatchSearch(caseSensitive: !search.caseSensitive)
                }
                switchToggle("ab", on: search.wholeWord, id: "editor.search.word", help: "Match whole word", underline: true) {
                    dispatchSearch(wholeWord: !search.wholeWord)
                }
                switchToggle(".*", on: search.regex, id: "editor.search.regex", help: "Use regular expression") {
                    dispatchSearch(regex: !search.regex)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(EditorPaneStyle.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 6)
            if search.replace.shown {
                HStack(spacing: 6) {
                    TextField("Replace", text: $replaceText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.text)
                        .focused($replaceFocused)
                        // Rule 2: the preview follows the field after a pause; no Enter needed.
                        .onChange(of: replaceText) { _, t in
                            guard t != replaceSent else { replaceDebounce.cancel(); return }
                            replaceDebounce.schedule {
                                replaceSent = t
                                await dispatch("editor_search", ["replace": .string(t)])
                            }
                        }
                        .accessibilityIdentifier("editor.search.replace")
                        .onAppear { takeReplaceFocus() }
                    // Rule 1: neither button asks; the replace is undoable.
                    Button("Replace All") { replaceAll(file: nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(EditorPaneStyle.text)
                        .disabled(!editorReplaceAvailable(search))
                        .opacity(editorReplaceAvailable(search) ? 1 : 0.4)
                        .accessibilityIdentifier("editor.search.replaceAll")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(EditorPaneStyle.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 6)
            }
            if search.replace.inFlight {
                HStack(spacing: 8) {
                    // Pre-flight F6: an undo says "undoing", and its Cancel stops it between files.
                    let doing = search.replace.undoing ? "undoing" : "replacing"
                    EditorBusyTick(label: doing, identifier: "editor.replace.busy")
                    Text(doing).font(.system(size: 10.5)).foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                    // Rule 4: a replace in flight can be stopped (what was written stays and can be undone),
                    // and so can an undo (the files it has not reached stay as the replace left them).
                    Button("Cancel") { Task { await dispatch("editor_replace", ["cancel": .bool(true)]) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                        .accessibilityIdentifier("editor.replace.cancel")
                }
                .padding(.horizontal, 12)
            } else if let last = search.replace.last {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text(editorReplaceSummary(last))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                        if last.undoable {
                            Button("Undo replace") { Task { await dispatch("editor_replace_undo", [:]) } }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(EditorPaneStyle.text)
                                .accessibilityIdentifier("editor.replace.undo")
                        }
                    }
                    .padding(.horizontal, 12)
                    // Rule 8: each file that failed, with its error whole; a run-wide failure has no path.
                    ForEach(Array(last.failures.enumerated()), id: \.offset) { _, f in
                        searchLine(f.path.isEmpty ? f.error : "\(f.path): \(f.error)", opacity: 0.85).accessibilityIdentifier("editor.replace.failure")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editor.replace.result")
            }
            if search.inFlight {
                HStack(spacing: 8) {
                    EditorBusyTick(label: "searching", identifier: "editor.search.busy")
                    Text("searching").font(.system(size: 10.5)).foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                    // Rule 4: a search in flight can be stopped.
                    Button("Cancel") { Task { await dispatch("editor_search", ["cancel": .bool(true)]) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                        .accessibilityIdentifier("editor.search.cancel")
                }
                .padding(.horizontal, 12)
            }
            if let error = search.error {
                searchLine(error, opacity: 0.85).accessibilityIdentifier("editor.search.error")
            }
            // A stopped search and one that found nothing each say so: an empty column never stands
            // for either (3b-ii walk).
            if search.cancelled {
                HStack(spacing: 10) {
                    Text("search cancelled")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.55))
                    Button("Re-run") { debounce.cancel(); let q = search.query; Task { await runSearch(q) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(EditorPaneStyle.text)
                        .accessibilityIdentifier("editor.search.rerunCancelled")
                }
                .padding(.horizontal, 12)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editor.search.cancelled")
            } else if !search.inFlight, search.error == nil, !search.query.isEmpty, search.results.isEmpty {
                searchLine("no matches", opacity: 0.55).accessibilityIdentifier("editor.search.noMatches")
            }
            if search.truncated {
                searchLine(EditorSearchState.truncatedNote, opacity: 0.55).accessibilityIdentifier("editor.search.note")
            }
            if search.filesTruncated {
                searchLine(EditorSearchState.filesTruncatedNote, opacity: 0.55)
                    .accessibilityIdentifier("editor.search.filesNote")
            }
            if let note = editorSkippedLargeNote(search.skippedLarge) {
                searchLine(note, opacity: 0.55).accessibilityIdentifier("editor.search.largeNote")
            }
            if search.changedSince {
                HStack(spacing: 10) {
                    Text("files changed since this search")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Re-run") { debounce.cancel(); let q = search.query; Task { await runSearch(q) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(EditorPaneStyle.text)
                        .accessibilityIdentifier("editor.search.rerun")
                }
                .padding(.horizontal, 12)
            }
            results
        }
        .padding(.top, 2)
        .onAppear {
            sent = search.query; query = search.query
            replaceSent = search.replace.text; replaceText = search.replace.text
        }
        // The agent's search shows its query; never over what is being typed (the field follows only
        // while it still holds the store's last query), and never this column's own query coming back.
        .onChange(of: search.query) { old, now in
            guard now != sent, query == old else { return }
            sent = now
            query = now
        }
        .onChange(of: search.replace.shown) { _, shown in if shown { takeReplaceFocus() } else { wantReplaceFocus = false } }
        // The agent's replace text shows in the field, by the query field's rule: never over typing.
        .onChange(of: search.replace.text) { old, now in
            guard now != replaceSent, replaceText == old else { return }
            replaceSent = now
            replaceText = now
        }
    }

    /// The field the operator's ▸ opened takes the keyboard a turn later: it is in the window by then.
    private func takeReplaceFocus() {
        guard wantReplaceFocus, search.replace.shown else { return }
        wantReplaceFocus = false
        Task { @MainActor in replaceFocused = true }
    }

    /// Replace All, or Replace in this file (`file` absolute). The pending preview is not waited for:
    /// the replace sends the field's text itself. A query typed within the search's pause is searched
    /// first, so the replace uses what the field shows, never the query before it (final review M3).
    private func replaceAll(file: String?) {
        replaceDebounce.cancel()
        replaceSent = replaceText
        let pending: String? = query != sent ? query : nil
        debounce.cancel()
        var params: [String: JSONValue] = ["replacement": .string(replaceText)]
        if let file { params["file"] = .string(file) }
        Task {
            if let pending { await runSearch(pending) }
            await dispatch("editor_replace", params)
        }
    }

    private func switchToggle(_ label: String, on: Bool, id: String, help: String, underline: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .underline(underline)
                .foregroundStyle(EditorPaneStyle.text.opacity(on ? 1 : 0.5))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(on ? EditorPaneStyle.violet.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? EditorPaneStyle.violet : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Rule 8: whole and wrapping.
    private func searchLine(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(EditorPaneStyle.text.opacity(opacity))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
    }

    private func resultId(_ m: EditorSearchMatch) -> String {
        "\((m.root as NSString).lastPathComponent)/\(m.path):\(m.line)"
    }

    /// The selection's key: two matches on one line are two rows.
    private func resultKey(_ m: EditorSearchMatch) -> String { "\(resultId(m)):\(m.column)" }

    private func fileKey(_ root: String, _ path: String) -> String { "\(root)/\(path)" }

    /// The results ↑↓ and Return move through: those under no closed group.
    private var visibleResults: [EditorSearchMatch] {
        search.results.filter { !collapsed.contains($0.root) && !collapsed.contains(fileKey($0.root, $0.path)) }
    }

    private var resultIds: [String] { visibleResults.map(resultKey) }

    private struct ResultLine: Identifiable {
        enum Kind { case root(String, String), file(String, String, String), match(EditorSearchMatch) }
        let id: String
        let kind: Kind
    }

    /// The Search view's rows in order: each root's header, its files' headers, and the matches under
    /// any group left open.
    private var resultLines: [ResultLine] {
        var lines: [ResultLine] = []
        for group in editorSearchGroups(search.results) {
            let rootName = (group.root as NSString).lastPathComponent
            lines.append(ResultLine(id: "root:\(group.root)", kind: .root(group.root, rootName)))
            guard !collapsed.contains(group.root) else { continue }
            for file in group.files {
                let key = fileKey(group.root, file.path)
                lines.append(ResultLine(id: "file:\(key)", kind: .file(key, file.path, "\(rootName)/\(file.path)")))
                guard !collapsed.contains(key) else { continue }
                lines += file.matches.map { ResultLine(id: resultKey($0), kind: .match($0)) }
            }
        }
        return lines
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One flat list, each row by its own id (a match's is its selection key, so scrollTo
                    // finds it). Nested ForEach by offset with an .id on the match rows left the lazy
                    // stack dropping the first file's header (3b-ii walk).
                    ForEach(resultLines) { line in
                        switch line.kind {
                        case .root(let root, let name):
                            groupHeader(name, key: root, id: name, root: true)
                        case .file(let key, let path, let address):
                            groupHeader(path, key: key, id: address, root: false)
                        case .match(let m):
                            resultRow(m)
                        }
                    }
                }
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: selectedResult) { _, now in if let now { proxy.scrollTo(now) } }
            .onAppear { if let selectedResult { proxy.scrollTo(selectedResult, anchor: .center) } }
        }
        .focusable()
        .focused($resultsFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: resultsKey)
    }

    /// A root or file header: a click opens or closes what is under it, as a tree folder does.
    private func groupHeader(_ title: String, key: String, id: String, root: Bool) -> some View {
        let open = !collapsed.contains(key)
        let fileSelected = !root && selectedResult.map { $0.hasPrefix(id + ":") } == true
        let showReplace = !root && search.replace.shown
        let shown = hoveredFile == key || fileSelected
        let available = editorReplaceAvailable(search)
        return HStack(spacing: 5) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 10)
            Text(title)
                .font(root ? .system(size: 11, weight: .medium, design: .monospaced) : .system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            if showReplace {
                Spacer(minLength: 4)
                // Drawn, pressable and reachable by AX only while shown: on hover, or while the selected
                // result is in this file (an e2e press selects a result first). Rule 1: it does not ask;
                // the replace is undoable.
                Button("Replace in this file") { replaceAll(file: key) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(EditorPaneStyle.text)
                    .disabled(!available)
                    .opacity(shown ? (available ? 1 : 0.4) : 0)
                    .allowsHitTesting(shown)
                    .accessibilityIdentifier("editor.search.replaceFile:\(id)")
            }
        }
        .foregroundStyle(EditorPaneStyle.text.opacity(root ? 0.62 : 0.86))
        .padding(.top, root ? 8 : 4).padding(.leading, root ? 6 : 14).padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { toggleGroup(key) }
        .onHover { inside in hoveredFile = inside ? key : (hoveredFile == key ? nil : hoveredFile) }
        // Pre-flight F5: a file header holds a button that keeps its own identifier, so it contains;
        // a root header has none and stays combined, where its accessibilityAction answers AXPress.
        .accessibilityElement(children: root ? .combine : .contain)
        .accessibilityIdentifier("editor.search.group:\(id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleGroup(key) }
    }

    private func toggleGroup(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    /// `line  preview`, every match of the search in the preview marked (`editorSearchMarks`).
    private func resultText(_ m: EditorSearchMatch) -> AttributedString {
        var line = AttributedString("\(m.line)  ")
        line.foregroundColor = EditorPaneStyle.text.opacity(0.45)
        // The Replace field open: the pane's preview, the match struck through, the replacement violet.
        if search.replace.shown, let edits = search.replace.preview[m.preview] {
            var out = line
            for span in editorReplacePreviewSpans(m.preview, edits: edits) {
                switch span {
                case .kept(let s):
                    var a = AttributedString(s)
                    a.foregroundColor = EditorPaneStyle.text.opacity(0.72)
                    out += a
                case .removed(let s):
                    var a = AttributedString(s)
                    a.foregroundColor = EditorPaneStyle.text.opacity(0.55)
                    a.strikethroughStyle = .single
                    out += a
                case .inserted(let s):
                    var a = AttributedString(s)
                    a.foregroundColor = EditorPaneStyle.violet
                    a.backgroundColor = EditorPaneStyle.violet.opacity(0.18)
                    out += a
                }
            }
            return out
        }
        var text = AttributedString(m.preview)
        text.foregroundColor = EditorPaneStyle.text.opacity(0.72)
        let utf16 = m.preview.utf16
        for r in editorSearchMarks(preview: m.preview, search: search) {
            guard r.upperBound <= utf16.count else { continue }
            let lo = String.Index(utf16Offset: r.lowerBound, in: m.preview)
            let hi = String.Index(utf16Offset: r.upperBound, in: m.preview)
            guard let a = AttributedString.Index(lo, within: text), let b = AttributedString.Index(hi, within: text) else { continue }
            text[a..<b].foregroundColor = EditorPaneStyle.text
            text[a..<b].backgroundColor = EditorPaneStyle.violet.opacity(0.33)
        }
        return line + text
    }

    private func resultRow(_ m: EditorSearchMatch) -> some View {
        let id = resultKey(m), address = resultId(m)   // hoisted for the identifier harvest, as in treeRow
        return Text(resultText(m))
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 22).padding(.trailing, 6).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if id == selectedResult { RoundedRectangle(cornerRadius: 4).stroke(EditorPaneStyle.violet, lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedResult = id; resultsFocused = true; open(m) }
            // A container, not a combined button: the tree reads a button's text as nothing, and the
            // row's line and preview are what the operator reads (as the ACCOUNT indicator does).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.search.result:\(address)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selectedResult = id; open(m) }
    }

    private func resultsKey(_ press: KeyPress) -> KeyPress.Result {
        guard !isChord(press) else { return .ignored }
        let ids = resultIds
        let at = selectedResult.flatMap { ids.firstIndex(of: $0) }
        switch press.key {
        case .upArrow:
            guard let at, at > 0 else { queryFocused = true; return .handled }   // above the first: the query
            selectedResult = ids[at - 1]
        case .downArrow:
            guard !ids.isEmpty else { return .handled }
            selectedResult = ids[min(ids.count - 1, (at ?? -1) + 1)]
        case .return:
            if let at { open(visibleResults[at]) }
        default:
            return .ignored
        }
        return .handled
    }

    /// Opens the result's file with its match selected; the find bar stays shut (the Search view
    /// already holds the query). A preview cut around a long line no longer starts at column 1, so
    /// its mark does not land on the match's column, and the cursor alone goes there.
    private func open(_ m: EditorSearchMatch) {
        var params: [String: JSONValue] = ["path": .string("\(m.root)/\(m.path)"), "line": .integer(Int64(m.line)),
                                           "column": .integer(Int64(m.column)), "preview": .bool(true)]
        if let mark = editorSearchMarks(preview: m.preview, search: search).first(where: { $0.lowerBound == m.column - 1 }) {
            params["end_column"] = .integer(Int64(mark.upperBound + 1))
        }
        Task { await dispatch("editor_open", params) }
    }

    /// An empty query is sent too: a search for nothing finds nothing, as a switch flipped on an empty
    /// field does (ruling 4).
    private func runSearch(_ q: String) async {
        sent = q
        await dispatch("editor_search", ["query": .string(q), "case": .bool(search.caseSensitive),
                                         "word": .bool(search.wholeWord), "regex": .bool(search.regex)])
    }

    /// A switch flipped: the search re-runs at once with it, the others as they are. With the field
    /// empty it still goes to the pane, which keeps it for the next query (ruling 4, Rules 2 and 7).
    private func dispatchSearch(caseSensitive: Bool? = nil, wholeWord: Bool? = nil, regex: Bool? = nil) {
        debounce.cancel()
        let q = query
        sent = q
        let c = caseSensitive ?? search.caseSensitive, w = wholeWord ?? search.wholeWord, r = regex ?? search.regex
        Task {
            await dispatch("editor_search", ["query": .string(q), "case": .bool(c), "word": .bool(w), "regex": .bool(r)])
        }
    }
}

/// The Changes view's **+**, **−** and **↺** (3a-ii walk): a rounded fill under the glyph on hover and a
/// stronger one while pressed, the glyph brightened (`IconButtonTreatment`). The hit area is the
/// label's own 16pt square, as before.
struct ChangesIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Lit(configuration: configuration) }

    private struct Lit: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(EditorPaneStyle.text.opacity(
                    IconButtonTreatment.glyph(hovered: hovered, pressed: pressed, enabled: enabled)))
                .background(RoundedRectangle(cornerRadius: 3).fill(EditorPaneStyle.text.opacity(
                    IconButtonTreatment.fill(hovered: hovered, pressed: pressed, enabled: enabled))))
                .animation(.easeOut(duration: IconButtonTreatment.hoverDuration(reduceMotion: reduceMotion)),
                           value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// 3a-ii. What the Changes view's writes draw from and press, every root's, handed in by `Canvas`
/// from the window's state (`WindowModel+ChangesWrites`). Keyed by the root's absolute path.
/// The undo target a draft's step is registered against: `registerUndo` needs an object, and the
/// step itself only calls `edit`.
@MainActor
final class ChangesDraftUndo {
    static let shared = ChangesDraftUndo()
}

struct EditorChangesControls {
    var messages: [String: String]
    var errors: [String: String]
    var inFlight: Set<String>
    /// `WindowModel.changesPlaceholder`, per root: the box's placeholder, naming who commits.
    var placeholders: [String: String]
    let edit: (String, String) -> Void
    /// ↑ (`-1`) or ↓ (`1`) through the root's history; true when the box changed.
    let historyStep: (String, Int) -> Bool
    let commit: (String) async -> Void
    let amend: (String) async -> Void
    let undo: (String) async -> Void
    let stage: (String, [String]?, GitGroup?) async -> Void
    let unstage: (String, [String]?, GitGroup?) async -> Void
    let discard: (String, [String]?, GitGroup?) async -> Void
    let cancel: (String) -> Void
    let refreshIdentity: (String) async -> Void
    /// 3a-ii-b: roots with a ✨ draft running; whether the organisation has commit drafts on; the
    /// draft (the text it replaced, nil when nothing landed); and its cancel.
    var drafting: Set<String>
    var draftsOn: Bool
    let draft: (String) async -> String?
    let cancelDraft: (String) -> Void
    /// 3a-iii-a: the remote button's action for a root, ▾ Fetch, and the background fetch's quiet notes.
    let remote: (String, ChangesRemoteButton) async -> Void
    let fetch: (String) async -> Void
    var notes: [String: String]
}

/// The message box's keys (3a-ii), taken ahead of SwiftUI and the menu while a box holds the keyboard:
/// ⌘⏎ belongs to *Maximize Pane* as a key equivalent, so the box never saw it as a key press, and the
/// list's ↑/↓ above the box would take its arrows. ⌘⏎ commits. ↑ on the caret's first line and ↓ on its
/// last step the history; anywhere else, or when the history has nothing to show, the arrow moves the
/// caret as usual.
@MainActor
final class ChangesMessageKeys {
    /// `nonisolated(unsafe)`: read once more by `deinit`, which removes the monitor; every other
    /// access is on the main actor.
    nonisolated(unsafe) private var monitor: Any?
    /// The box's own text view, taken once the box holds the keyboard. Only its keys are handled: a
    /// focus state gone stale must never let ⌘⏎ in another text view (the composer, a query line)
    /// commit a repository.
    private weak var owner: NSTextView?
    /// Bumped by every start and stop, so a capture still waiting for its turn knows it is stale.
    private var generation = 0

    func start(window: NSWindow?, commit: @escaping () -> Void, step: @escaping (Int) -> Bool) {
        stop()
        guard let window else { return }
        let mine = generation
        capture(window, generation: mine, tries: 5)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            let swallowed: Bool = MainActor.assumeIsolated {
                guard let self, let window, let owner = self.owner, event.window === window, window.isKeyWindow,
                      window.firstResponder === owner, !owner.hasMarkedText() else { return false }
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                switch event.keyCode {
                case 36, 76:   // Return, Enter
                    guard mods == .command else { return false }
                    commit()
                    return true
                case 126, 125: // ↑, ↓
                    guard mods.isEmpty, owner.selectedRange().length == 0 else { return false }
                    let all = owner.string as NSString
                    let caret = min(owner.selectedRange().location, all.length)
                    let up = event.keyCode == 126
                    let rest = up ? all.substring(to: caret) : all.substring(from: caret)
                    guard !rest.contains("\n") else { return false }
                    return step(up ? -1 : 1)
                default: return false
                }
            }
            return swallowed ? nil : event
        }
    }

    /// A turn after the box took focus its text view is the window's first responder; a few more
    /// turns are allowed for a focus move AppKit finishes late. Nothing is captured otherwise, and the
    /// monitor then handles nothing.
    private func capture(_ window: NSWindow, generation mine: Int, tries: Int) {
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.generation == mine else { return }
            if let text = window.firstResponder as? NSTextView {
                self.owner = text
            } else if tries > 1 {
                self.capture(window, generation: mine, tries: tries - 1)
            }
        }
    }

    func stop() {
        generation += 1
        owner = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// One row's or group's three write-button identifiers, each spelled whole at its call site.
private struct ChangesWriteIds {
    let stage: String
    let unstage: String
    let discard: String
}
