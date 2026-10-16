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
        .onChange(of: queryFocused || treeFocused || resultsFocused || changesFocused) { _, now in hasKeyboard = now }
        .onChange(of: rows) { old, now in
            selected = editorTreeSelection(after: selected, previous: old, now: now)
            takeReveal(now)
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
                    ForEach(rows) { row in treeRow(row).id(row.id) }
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
                    .padding(.vertical, row.kind == .root ? 0 : 2)
                    .padding(.top, row.kind == .root ? 8 : 0)
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
        }
    }

    private func rowLabel(_ row: EditorTreeRow) -> some View {
        // Hoisted for the identifier harvest, as in `treeRow`.
        let path = rowPath(row)
        return HStack(spacing: 5) {
            if row.loading { EditorBusyTick(label: "loading", identifier: "editor.tree.loading") }
            switch row.kind {
            case .root, .repo, .folder:
                Image(systemName: row.open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 10)
            case .file, .note:
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
        }
        .foregroundStyle(EditorPaneStyle.text.opacity(row.kind == .root ? 0.62 : 0.86))
        .opacity(row.dimmed ? 0.45 : 1)
        .frame(height: row.kind == .root ? 20 : 18)
    }

    // MARK: - Changes (3b-iii)

    private var changesRows: [EditorChangesRow] { editorChangesRows(gitRoots, closed: column.changesClosed) }
    private var changesHighlight: EditorChangesRow? { editorChangesResolve(column.changesHighlight, roots: gitRoots) }

    private var changesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if gitRoots.isEmpty {
                        Text("No project roots to read")
                            .font(.system(size: 12)).foregroundStyle(EditorPaneStyle.text.opacity(0.46))
                    }
                    ForEach(gitRoots, id: \.root) { root in
                        changesHeader(root)
                        if !column.changesClosed.contains(root.root) {
                            ForEach(gitListSections(root), id: \.group) { section in
                                Text(gitGroupLabel(section.group))
                                    .font(.system(size: 9, weight: .medium)).tracking(1.7)
                                    .foregroundStyle(EditorPaneStyle.text.opacity(0.45))
                                    .padding(.top, 6).padding(.leading, 6)
                                ForEach(section.rows, id: \.self) { changesRow($0, root: root) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focused($changesFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in changesKey(press) }
            .onChange(of: changesHighlight) { _, now in
                if let now { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(now) } }
            }
        }
    }

    @ViewBuilder
    private func changesHeader(_ root: GitRootState) -> some View {
        let closed = column.changesClosed.contains(root.root)
        HStack(spacing: 6) {
            Image(systemName: closed ? "chevron.right" : "chevron.down").font(.system(size: 9))
            if root.loading { EditorBusyTick(label: "loading", identifier: "editor.changes.loading") }
            Text(gitRootLine(root))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.top, 10).padding(.leading, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggleRoot(root.root, closed: closed) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.changes.root:\(root.name)")
        .accessibilityAction { toggleRoot(root.root, closed: closed) }
        // Text, as a row is: as a button its line never reached the tree (AXDescription only).
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isStaticText)
        if let detail = gitRootErrorDetail(root) {
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.leading, 8)
                .accessibilityIdentifier("editor.changes.rootError:\(root.name)")
        }
    }

    private func toggleRoot(_ root: String, closed: Bool) {
        Task { await dispatch(closed ? "editor_changes_expand" : "editor_changes_collapse", ["root": .string(root)]) }
    }

    private func changesRow(_ row: GitFileRow, root: GitRootState) -> some View {
        let ref = EditorChangesRow(root: root.root, path: row.path, group: row.group.rawValue)
        let on = ref == changesHighlight
        return HStack(spacing: 0) {
            Text(row.status)
                .foregroundStyle(EditorPaneStyle.tone(gitStatusTone(row.status)))
                .frame(width: 18, alignment: .leading)
            Text(gitRowLabel(row))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 2).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? EditorPaneStyle.lifted : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) { if on { Rectangle().fill(EditorPaneStyle.violet).frame(width: 2) } }
        .contentShape(Rectangle())
        // One tap gesture reading the click count, as the tree's and the tabs': a `count: 2` gesture
        // beside it held every single click for the double-click interval (3b-iii walk).
        .onTapGesture { selectChange(ref, pin: NSApp.currentEvent?.clickCount ?? 1 >= 2) }
        .id(ref)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.changes.row:\(root.name)/\(row.path):\(row.group.rawValue)")
        .accessibilityAction { selectChange(ref, pin: false) }
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(on ? [.isStaticText, .isSelected] : .isStaticText)
    }

    private func selectChange(_ ref: EditorChangesRow, pin: Bool) {
        changesFocused = true
        var p: [String: JSONValue] = ["root": .string(ref.root), "path": .string(ref.path), "group": .string(ref.group)]
        if pin { p["pin"] = .bool(true) }
        Task { await dispatch("editor_changes_select", p) }
    }

    /// ↑↓ step (and open, from Task 3); Return opens the highlighted row. Chords and other keys pass.
    private func changesKey(_ press: KeyPress) -> KeyPress.Result {
        guard !isChord(press) else { return .ignored }
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
        treeFocused = true
        switch row.kind {
        case .file:
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
