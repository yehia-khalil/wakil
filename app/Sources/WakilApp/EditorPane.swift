import AppKit
import Observation
import WakilKit
import SwiftUI
import WebKit

/// The editor pane (3b-i): a tab strip, the active tab's notice and disk lines, the scratch
/// save-as field, and Monaco — with, from 3b-ii, the left column (`EditorColumn`) beside them.
///
/// **It decides nothing.** What Monaco is told comes from `editorRenderSteps` (tested); every
/// click is an `editor_*` action through the window's dispatch, the same path the agent's calls
/// take. The operator's typing and view reports are the one non-action path
/// (`WindowModel.editorBufferDidChange` / `editorViewDidReport`). Its own state is the save-as
/// field's text and failure, and Compare's diff while it is open.
struct EditorPane: View {
    let snapshot: EditorSnapshot
    let viewOptions: EditorViewOptions
    let showIgnored: Bool
    let pane: Pane
    /// One `editor_*` action on THIS pane (Canvas folds `pane` in), awaited.
    let dispatch: (String, [String: JSONValue]) async -> Void
    /// The same call, its refusal thrown to the control that made it instead of the status line
    /// (3b-iv: the tree's name field shows it under itself, Rule 8).
    let dispatchThrowing: (String, [String: JSONValue]) async throws -> Void
    /// The operator's text for a tab — by its subject, never its position (final review I1) — with
    /// the agent-edit serial the page had applied.
    let bufferChanged: (EditorTabSubject, String, Int) async -> Void
    let viewReported: (EditorTabSubject, EditorPosition, EditorRange?, ClosedRange<Int>?, Double) async -> Void
    /// The path field's Save; `replace` is the inline "Replace <name>?" answered yes.
    let saveAs: (String, Bool) async -> EditorSaveAsResult
    let cancelSaveAs: () -> Void
    /// The saving tick's Cancel (Rule 4).
    let cancelSave: () -> Void
    /// The file's text on disk now, for Compare; nil when it could not be read.
    let diskText: (String) async -> String?
    let saveAsRequested: Bool
    /// The save-as fallback when no tree row is selected.
    let firstRoot: String
    /// The window's roots in order, for the tree (3b-ii).
    let roots: [String]
    /// The window's one file list per root (`WindowModel.editorFiles`).
    let files: EditorFileListsState
    /// The window's git status, as the Changes view and the tree's letters draw it (3b-iii).
    let gitRoots: [GitRootState]
    /// The column a pane that never set its own starts from.
    let columnDefault: EditorColumnState
    /// Monaco's find bar reporting its query, switches and count (the view-report path).
    let findReported: (EditorFindReport) async -> Void
    /// The operator's ⌘B / ⌘⇧F asking THIS pane's column for the keyboard, and its acknowledgement.
    let columnFocusRequest: EditorColumnFocusRequest?
    let columnFocusTaken: () -> Void
    /// The reveal button's action (3b-ii-b): `WindowModel.revealActiveFileInTree` for this pane.
    let revealInTree: () async -> Void
    /// The operator's reveal asking THIS pane's tree to select a row, and its acknowledgement.
    let revealRequest: EditorTreeRevealRequest?
    let revealTaken: () -> Void
    /// The org, project and conversation on screen: a switch drops a reveal still waiting for its row.
    let scope: String
    /// A middle-click's close of one tab, by subject: ⌘W's rule (a dirty tab asks).
    let closeTab: (EditorTabSubject) async -> Void
    let isFocusedPane: Bool
    /// No plane, palette or window prompt is in front of the canvas (the terminal pane's test).
    let isKeyboardOwner: Bool
    /// The composer keeps the keyboard just after a fast-path action (`composerHoldsKeyboard`).
    let keyboardHeld: () -> Bool
    /// The window's unsaved prompt, when it asks about one of THIS pane's tabs (`.closeTab`).
    let unsavedPrompt: UnsavedPrompt?
    /// Save / Don't Save / Cancel for that prompt.
    let resolveUnsaved: (UnsavedChoice) -> Void
    /// 3b-viii ghost-text, for THIS pane: whether it is on (the page asks nothing while it is
    /// off), the schema tables in scope with the quick-tasks generation they were read in, the
    /// suggestion for a request built in that generation (nil: nothing to draw), and the release
    /// of the pending one.
    let ghostTextEnabled: Bool
    /// 3a-v-a: inline blame on, the blame of (root, relative path, unsaved text or nil), and a
    /// commit's change opened for (root, the commit and the file's names there).
    var inlineBlame: Bool = false
    var blameFor: (String, String, String?) async -> [GitBlameInfo]? = { _, _, _ in nil }
    var openCommitDiff: (String, GitCommitRef) -> Void = { _, _ in }
    /// 3c-i: the hover's Open on GitHub, the commit's page, and whether ⌥ was held (`WakilLinks.open`).
    var openLink: (String, Bool) -> Void = { _, _ in }
    var timeline = EditorTimelineControls()
    let ghostSchema: () async -> GhostScope
    let ghostSuggest: (InfillRequest, Int) async -> String?
    let ghostCancel: () -> Void
    /// 3a-ii. The Changes view's commit box and write buttons, for every root (`EditorChangesControls`).
    let changes: EditorChangesControls
    /// The peek's Stage Change: `WindowModel.changesStageHunk`, the focused tab's peeked hunk.
    let stageHunk: () async -> Void
    /// 3a-ii-b: Stage / Unstage Selected Ranges in the active diff tab (`WindowModel.changesStageRanges`
    /// and `changesUnstageRanges`), with the lines of every selection the page held.
    let stageRanges: ([EditorLineSpan]) async -> Void
    let unstageRanges: ([EditorLineSpan]) async -> Void
    /// Ticket view: what the review boxes draw from (`WindowModel.editorReviews`).
    var reviews: EditorReviewsState = .empty
    /// `dispatch`, answering the action's reply (nil when it did not run): `review_step` names the
    /// thread it stepped to.
    var dispatchReply: (String, [String: JSONValue]) async -> JSONValue? = { _, _ in nil }
    /// Ticket view: what the column's Ticket view draws (`WindowModel.editorTicket`), and `dispatch`
    /// answering its reply or throwing its refusal, for a link's answer and a write's refusal.
    var ticket: EditorTicketViewState = .empty
    /// What waits on the operator (`ticketNeedsCount`, `ticketNeedsLabel`): the Ticket label's count.
    var ticketCount = 0
    var ticketCountLabel: String?
    var dispatchThrowingReply: (String, [String: JSONValue]) async throws -> JSONValue = { _, _ in .null }

    @State private var host = EditorHost()
    /// Compare, open: the path and the disk text it shows against the buffer.
    @State private var comparing: EditorComparing?
    /// Compare could not read the file: the reason, whole (Rule 8).
    @State private var compareFailure: String?
    @State private var saveAsPath = ""
    @State private var saveAsFailure: String?
    /// The path names a file that exists: the field asks "Replace <name>?" before writing (Rule 1).
    @State private var saveAsReplacing: String?
    @State private var saveAsInFlight = false
    @FocusState private var saveAsFocused: Bool
    /// The column's selected row and search result: the pane's, so they outlive the column (Rule 6).
    @State private var treeSelected: String?
    @State private var resultSelected: String?
    /// The column view the operator asked to type in, until it shows and takes the keyboard. Only the
    /// operator's own moves set it (⌘B / ⌘⇧F, the strip toggle, the column's header); an agent's
    /// `editor_tree` never moves the keyboard (Rule 6).
    @State private var columnFocusWanted: EditorColumnView?
    /// The column holds the keyboard: a focus change of the pane leaves it there (Rule 3).
    @State private var columnHasKeyboard = false
    /// The file the tree's single click brought forward (`EditorColumn.browsed`): its tab coming to
    /// the front is browsing, not arriving, whether or not it was already open and pinned.
    @State private var treeBrowsed: String?
    /// The revealed file's row, until the column has drawn and selected it.
    @State private var pendingReveal: String?
    /// The Hand to agent popover's field as typed, when it is anchored here.
    @State private var handOffDraft = TicketHandOffDraft()

    private var activeTab: EditorTab? {
        snapshot.active.flatMap { $0 < snapshot.tabs.count ? snapshot.tabs[$0] : nil }
    }

    private var column: EditorColumnState { snapshot.column ?? columnDefault }

    private var treeRows: [EditorTreeRow] {
        editorTreeRows(roots.compactMap { files.listings[$0] }, open: Set(column.open), dirs: files.dirs,
                       loading: files.loading, dirErrors: files.dirErrors, showIgnored: showIgnored)
    }

    /// The Hand to agent popover, when it opened in THIS pane (`TicketHandOffState.pane`).
    private var handOff: TicketHandOffState? { ticket.handoff.flatMap { $0.pane == pane.id ? $0 : nil } }
    /// From the header with the Ticket view showing: anchored to its **Hand to agent**; else to the
    /// editor, under its top edge, where the box that opened it is.
    private var handOffInColumn: Bool { handOff?.source == .header && column.shown && column.view == .ticket }

    /// Save-as starts in the selected row's folder, else the first root.
    private var saveAsBase: String {
        treeSelected.flatMap { id in treeRows.first { $0.id == id } }.map(editorFolder(of:)) ?? firstRoot
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if column.shown {
                    EditorColumn(column: column, rows: treeRows, pendingRoots: roots.filter { files.listings[$0] == nil },
                                 gitRoots: gitRoots,
                                 search: snapshot.search, paneWidth: geo.size.width, dispatch: dispatch,
                                 dispatchThrowing: dispatchThrowing,
                                 canReveal: activeTab?.path != nil,
                                 reveal: { Task { await revealInTree() } },
                                 selected: $treeSelected, selectedResult: $resultSelected,
                                 focusWanted: $columnFocusWanted, hasKeyboard: $columnHasKeyboard,
                                 pendingReveal: $pendingReveal, browsed: $treeBrowsed,
                                 changes: changes, timeline: timeline, timelineTab: activeTab,
                                 ticket: ticket, reviews: reviews, dispatchReply: dispatchThrowingReply,
                                 ticketCount: ticketCount, ticketCountLabel: ticketCountLabel,
                                 handOffAnchored: handOffInColumn)
                }
                editorStack
            }
        }
        .onChange(of: viewOptions, initial: true) { _, o in
            host.setOptions(o)
        }
        .onChange(of: ghostTextEnabled, initial: true) { _, on in
            host.setGhostEnabled(on)
        }
        .onChange(of: inlineBlame, initial: true) { _, on in
            host.setBlameEnabled(on)
        }
        .onChange(of: gitRoots.map(editorBlameRefreshMark)) { _, _ in
            host.refreshBlame()
        }
        // 3a-v-b: which files are conflicted decides which tabs show their blocks.
        .onChange(of: gitRoots, initial: true) { _, roots in
            host.setConflictRoots(roots)
        }
        // Ticket view: the shown file's review boxes follow the reads, drafts, sends and head texts.
        .onChange(of: reviews, initial: true) { _, r in
            host.setReviews(r)
        }
        // The keys the page takes follow the pane's state (R13): the peek's, or Compare's Esc.
        .onChange(of: editorCapturedKeys(comparing: comparing != nil, peek: comparing == nil && activeTab.flatMap(editorPeekView) != nil), initial: true) { _, keys in
            host.renderer?.captureKeys(keys)
        }
        .task {
            // These closures live as long as the host, so they read `host.latest` (the newest snapshot
            // handed in), never `snapshot`, which is this struct's copy from first appearance.
            // A click anywhere in the gutter strip posts, marked or not: only a marked line opens a
            // peek, so a click on none never dispatches a refusal the operator did not cause.
            host.markClicked = { subject, line in
                guard let tab = host.latest?.tabs.first(where: { $0.subject == subject }),
                      editorPeekLineHasMark(tab, line: line) else { return }
                Task { await dispatch("editor_peek", ["line": .integer(Int64(line))]) }
            }
            host.peekPressed = { op in peekOp(op) }
            host.conflictPressed = { block, op in conflictOp(block, op) }
            host.reviewPressed = { thread, op, text, delta in reviewOp(thread, op, text, delta) }
            // A conflicted file opened at its top lands on its first block (spec): the page is moved at
            // once and held there (`conflictLanding`), and the store and the journal learn it as any
            // cursor move does.
            host.conflictReveal = { line in Task { await dispatch("editor_goto", ["line": .integer(Int64(line))]) } }
            host.rangesPressed = { op, selections in
                let spans = editorLineSpans(selections)
                Task { if op == "unstage" { await unstageRanges(spans) } else { await stageRanges(spans) } }
            }
            host.onKey = { key in
                if comparing != nil { if key == "escape" { closeCompare() }; return }
                peekOp(key == "escape" ? "close" : key)
            }
            host.bufferChanged = bufferChanged
            host.viewReported = viewReported
            host.findReported = findReported
            host.ghostPrepare = { text, caret, path, language in
                let scope = await ghostSchema()
                return (ghostRequest(text: text, caret: caret, path: path, language: language, schema: scope.tables),
                        scope.generation)
            }
            host.ghostSuggest = ghostSuggest
            host.blameFor = blameFor
            host.blameOpen = openCommitDiff
            host.openLink = openLink
            host.ghostCancel = ghostCancel
            host.keyboardHeld = keyboardHeld
            // Handed in first, so `start` applies the newest snapshot, never this one if a newer
            // one landed while the renderer was being made.
            host.apply(snapshot)
            await host.start()
            if isFocusedPane, !saveAsRequested, !columnOwnsKeyboard { host.focus() }
        }
        .onAppear { takeColumnFocusRequest(); takeRevealRequest() }
        .onChange(of: columnFocusRequest) { _, _ in takeColumnFocusRequest() }
        .onChange(of: revealRequest) { _, _ in takeRevealRequest() }
        // Final review T4r: a reveal whose row never appeared must not select a row later, in this
        // scope or the next one.
        .onChange(of: scope) { _, _ in pendingReveal = nil }
        .onChange(of: snapshot) { old, now in
            host.apply(now)
            // Compare shows one file's disk against its buffer; it closes when that tab goes.
            if let c = comparing, !now.tabs.contains(where: { $0.path == c.path }) { closeCompare() }
            // Rule 3: a tab that newly comes to the front of the focused pane (⌘T, ⌘P, a tab
            // click, New File) takes the keyboard, as a new pane does. A preview tab is browsing (the
            // tree's or Search's single click, ↑↓ and Return): the keyboard stays in the column. A tab
            // forward only because the front one went (⌘⌫, the agent's trash or close) did not
            // arrive: the keyboard stays where the operator was (Rule 6). `editorFrontTabArrived`.
            // A tree click on a file whose tab is already open and pinned brings that tab forward
            // too: browsing all the same, so the keyboard stays in the tree (`treeBrowsed`).
            let front = now.active.flatMap { now.tabs.indices.contains($0) ? now.tabs[$0].path : nil }
            let browsing = front != nil && front == treeBrowsed
            if front != old.active.flatMap({ old.tabs.indices.contains($0) ? old.tabs[$0].path : nil }) {
                treeBrowsed = nil
            }
            if !browsing, editorFrontTabArrived(old: old, now: now), isFocusedPane, !saveAsRequested,
               comparing == nil {
                host.focus()
            }
        }
        .onChange(of: column.shown) { _, shown in
            guard !shown else { return }
            columnFocusWanted = nil
            // The column held the keyboard, and it is gone: the editor has it back. Anywhere else
            // (Monaco's find field), the keyboard stays where it is.
            guard columnHasKeyboard else { return }
            columnHasKeyboard = false
            if isFocusedPane, !saveAsRequested, comparing == nil { host.focus() }
        }
        // A click into this pane's column, or ⌘B from another pane, already put the keyboard there:
        // the pane being focused after it leaves it there.
        .onChange(of: isFocusedPane) { _, now in
            guard now else {
                // 3b-v PR 8: focus moved to another pane, so the keyboard leaves Monaco (or
                // Compare's diff) with it — keys typed after a click on the Settings tree were
                // going into the file. Only when one of them still holds it: a field the click
                // landed on has it already, and a pane that takes it is not overruled.
                host.resignKeyboard(alsoFrom: nil)
                return
            }
            if !saveAsRequested, !columnOwnsKeyboard { host.focus() }
        }
        // The prompt took the keyboard; whatever it resolved to, the editor has it back.
        .onChange(of: unsavedPrompt == nil) { _, gone in
            if gone, isFocusedPane, !saveAsRequested { host.focus() }
        }
        .onKeyPress(.escape) {
            guard comparing != nil else { return .ignored }
            closeCompare()
            return .handled
        }
        // A container: without it the pane's identifier overrides its children's, and Compare's
        // Close reads as `editor.pane` (measured: axresolve not_found on editor.compare.close).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.pane")
    }

    /// The 3b-i pane beside the column: tab strip, lines, save-as and Monaco — edge to edge since
    /// the compact chrome (2026-10-26): the strip a 32 pt row, each line under it compact with a
    /// hairline beneath, and Monaco to the pane's border.
    private var editorStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let unsavedPrompt {
                UnsavedPromptBar(message: closeTabMessage(unsavedPrompt), compact: true, resolve: resolveUnsaved)
                PaneHairline()
            }
            // Drawn even with no tab: its toggle is how an empty pane shows the column without ⌘B.
            tabStrip
            PaneHairline()
            if let tab = activeTab {
                if let notice = tab.notice { noticeLine(notice) }
                if tab.diskState == .changedOnDisk, comparing == nil { compactRow { diskChangedLine(tab) } }
            }
            if let compareFailure {
                compactRow { lineText(compareFailure).accessibilityIdentifier("editor.compare.failure") }
            }
            if saveAsRequested { saveAsField; PaneHairline() }
            // One web view for the code editor, a diff tab and Compare: the page chooses what shows.
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if let comparing { compareHeader(comparing) }
                    if let tab = activeTab, let d = tab.diffState { diffLine(tab, d) }
                    GitDiffHostView(webView: host.renderer?.webView)
                        .accessibilityIdentifier(comparing != nil ? "editor.compare.diff" : "editor.monaco")
                }
                if snapshot.tabs.isEmpty, comparing == nil { emptyState }
                // Hand to agent from a review box (or the header, its Ticket view hidden).
                Color.clear.frame(width: 1, height: 1)
                    .popover(isPresented: Binding(get: { handOff != nil && !handOffInColumn }, set: { shown in
                        if !shown, handOff?.starting == false {
                            let p = handOffDraft.closeParams(handOff)
                            Task { await dispatch("ticket_hand_off_close", p) }
                        }
                    }), arrowEdge: .bottom) {
                        if let handOff {
                            TicketHandOffPopover(state: handOff, dispatch: dispatch, dispatchReply: dispatchThrowingReply,
                                                 draft: handOffDraft)
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The column holds the keyboard, or the operator asked for it and it is on its way.
    private var columnOwnsKeyboard: Bool { column.shown && (columnHasKeyboard || columnFocusWanted != nil) }

    private func takeColumnFocusRequest() {
        guard let r = columnFocusRequest else { return }
        columnFocusWanted = r.view
        columnFocusTaken()
    }

    /// The reveal asked this pane's tree to select a file's row; the column selects it once drawn. A
    /// newer reveal replaces one still waiting for its row (final review T4r).
    private func takeRevealRequest() {
        guard let r = revealRequest else { return }
        pendingReveal = r.path
        revealTaken()
    }

    private func closeTabMessage(_ prompt: UnsavedPrompt) -> String {
        "Save changes to \(prompt.files.first ?? "this tab")?"
    }

    // MARK: - Tab strip

    /// The first row (the compact chrome, 2026-10-26): the editor glyph in the pane label's place,
    /// the column's toggle, then the shared strip (`PaneTabStrip`) — file tabs at their own width
    /// (a name is never shrunk), the tick and the raised chip on the active one, hairlines between
    /// the rest, the faded `‹ n` / `n ›` counts once they overflow, and ＋ for ⌘T's scratch tab.
    private var tabStrip: some View {
        let tabs = snapshot.tabs
        let titles = editorTabTitles(tabs)
        return PaneStripRow(glyph: "chevron.left.forwardslash.chevron.right", name: "Editor") {
            // The column's toggle, leading, so the column can always be shown again.
            Button {
                if !column.shown { columnFocusWanted = column.view }   // the operator's own toggle (Rule 3)
                Task { await dispatch("editor_tree", ["shown": .bool(!column.shown), "view": .string(column.view.rawValue)]) }
            }
                label: {
                    Image(systemName: "sidebar.left").font(.system(size: 11))
                        .frame(width: PaneStripStyle.glyphBox, height: PaneStripStyle.glyphBox)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(EditorPaneStyle.text)
                .opacity(column.shown ? 0.9 : 0.5)
                .padding(.trailing, PaneStripStyle.glyphTrailing)
                .help("Files ⌘B · Search ⌘⇧F · Changes ⌘⇧G")
                .accessibilityIdentifier("editor.column.toggle")
            PaneTabStrip(
                ids: tabs.indices.map { "\($0)" },
                active: snapshot.active.map { "\($0)" },
                width: .natural,
                stripIds: PaneStripIds(
                    tabs: "editor.tabs",
                    moreLeft: "editor.tabs.moreLeft", moreLeftCount: "editor.tabs.moreLeft.count",
                    moreRight: "editor.tabs.moreRight", moreRightCount: "editor.tabs.moreRight.count",
                    newTab: "editor.newTab",
                    entry: { "editor.tab.\($0)" }),
                accessibility: .text,
                entry: { index, on in tabContent(tabs[index], title: titles[index], on: on) },
                label: { tabs[$0].path ?? titles[$0] },
                // A double-click keeps a preview tab (a file tab opened again without preview). One tap
                // reading the click count: a `count: 2` gesture beside it would hold every single click
                // for the double-click interval.
                tap: { index in
                    if NSApp.currentEvent?.clickCount ?? 1 >= 2, let path = tabs[index].path {
                        Task { await dispatch("editor_open", ["path": .string(path), "preview": .bool(false)]) }
                    } else {
                        focusTab(index)
                    }
                },
                activate: { focusTab($0) },
                // A drop anywhere over a tab moves to that tab's index (pre-flight F4); off the strip or
                // on its own place, nothing.
                move: { from, to in
                    Task { await dispatch("editor_move_tab", ["from": .integer(Int64(from)), "to": .integer(Int64(to))]) }
                },
                newTab: PaneStripNewTab(help: "New Scratch Tab ⌘T") {
                    Task { await dispatch("editor_new_scratch", [:]) }
                },
                // A middle-click on a tab: ⌘W's path for it — a clean tab closes, a dirty one asks (3b-i's
                // prompt).
                middleClick: { index in
                    guard snapshot.tabs.indices.contains(index) else { return }
                    let subject = snapshot.tabs[index].subject
                    Task { await closeTab(subject) }
                },
                middleClickEnabled: isKeyboardOwner)
        }
    }

    /// A tab's own content between the tick and its edge: the file's glyph, its name (italic while
    /// it is the preview), the dirty dot, the disk's word and the saving tick with its Cancel.
    @ViewBuilder
    private func tabContent(_ tab: EditorTab, title: String, on: Bool) -> some View {
        HStack(spacing: PaneStripStyle.tabGap) {
            EditorFileIcon(editorTabGlyph(tab))
                .foregroundStyle(on ? EditorPaneStyle.text : EditorPaneStyle.text.opacity(PaneStripStyle.tabTitleRest))
            Text(title)
                .font(.system(size: 11.5, design: .monospaced))
                .italic(tab.preview)
                .foregroundStyle(on ? EditorPaneStyle.text : EditorPaneStyle.text.opacity(PaneStripStyle.tabTitleRest))
                .lineLimit(1)
                .truncationMode(.middle)
            if tab.dirty {
                Circle().fill(EditorPaneStyle.text.opacity(0.52)).frame(width: 5, height: 5)
                    .accessibilityLabel("unsaved")
            }
            switch tab.diskState {
            case .changedOnDisk:
                Text("changed on disk").font(.system(size: 10)).foregroundStyle(EditorPaneStyle.amber)
            case .deleted:
                Text("deleted").font(.system(size: 10)).foregroundStyle(EditorPaneStyle.text.opacity(0.45))
            case .inSync:
                EmptyView()
            }
            if tab.saving {
                EditorBusyTick()
                Button("Cancel", action: cancelSave)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                    .accessibilityIdentifier("editor.saving.cancel")
            }
        }
    }

    private func focusTab(_ index: Int) {
        guard index != snapshot.active else { return }
        Task { await dispatch("editor_focus_tab", ["index": .integer(Int64(index))]) }
    }

    // MARK: - Lines

    /// Rule 8: whole, wrapping, never truncated. One line is 22 pt; a longer one wraps rather than
    /// being held to the row.
    private func lineText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, PaneStripStyle.rowInset)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A compact row under the strip (the compact chrome): its content, then a hairline across the pane.
    private func compactRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            PaneHairline()
        }
    }

    private func noticeLine(_ notice: String) -> some View {
        compactRow { lineText(notice).accessibilityIdentifier("editor.notice") }
    }

    private func diskChangedLine(_ tab: EditorTab) -> some View {
        let name = ((tab.path ?? "") as NSString).lastPathComponent
        return HStack(spacing: 12) {
            Text("\(name) changed on disk")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.amber)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reload") { Task { await dispatch("editor_reload", [:]) } }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EditorPaneStyle.text)
                .accessibilityIdentifier("editor.reload")
            Button("Compare") { openCompare(tab) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EditorPaneStyle.text)
                .accessibilityIdentifier("editor.compare")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PaneStripStyle.rowInset)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.diskChanged")
    }

    // MARK: - Diff tab line

    /// A diff tab's state: Loading (Rule 5), its error whole (Rule 8), the binary or truncated
    /// banner (3a-i), or "No longer changed".
    @ViewBuilder
    private func diffLine(_ tab: EditorTab, _ d: GitDiffState) -> some View {
        if d.loading {
            compactRow {
                HStack(spacing: 6) { EditorBusyTick(); lineText("Loading") }
                    .padding(.leading, PaneStripStyle.rowInset)
                    .accessibilityIdentifier("editor.diff.loading")
            }
        } else if let error = d.error {
            compactRow { lineText(error).accessibilityIdentifier("editor.diff.error") }
        } else if let banner = gitDiffBanner(d) {
            compactRow { lineText(banner).accessibilityIdentifier("editor.diff.banner") }
        }
        if d.noLongerChanged { compactRow { lineText("No longer changed").accessibilityIdentifier("editor.diff.gone") } }
        if case .diff(let root, _, let group, nil) = tab.subject, group != .untracked, !d.loading, d.error == nil,
           gitDiffBanner(d) == nil {
            compactRow { rangesLine(tab, d, root: root, group: group) }
        }
    }

    /// 3a-ii-b: Stage Selected Ranges on a Changes diff, Unstage on a Staged one. Enabled while the
    /// selection (or the caret's line) touches a change; a press reads every selection from the page
    /// (ruling R1). A write running in the root shows the spinner and takes no second press (Rule 5).
    private func rangesLine(_ tab: EditorTab, _ d: GitDiffState, root: String, group: GitGroup) -> some View {
        let unstage = group == .staged
        let shown = tab.selection ?? EditorRange(start: tab.cursor, end: tab.cursor)
        let touches = editorRangesTouchChange(base: d.original, text: d.modified, ranges: editorLineSpans([shown]))
        let busy = changes.inFlight.contains(root)
        return HStack(spacing: 8) {
            Button(unstage ? "Unstage Selected Ranges" : "Stage Selected Ranges") {
                Task {
                    var selections = await host.renderer?.diffSelections() ?? []
                    if selections.isEmpty { selections = [shown] }
                    let spans = editorLineSpans(selections)
                    if unstage { await unstageRanges(spans) } else { await stageRanges(spans) }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(EditorPaneStyle.text.opacity(touches && !busy ? 1 : 0.4))
            .disabled(!touches || busy)
            .accessibilityIdentifier(unstage ? "editor.diff.unstageRanges" : "editor.diff.stageRanges")
            if busy { EditorBusyTick() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PaneStripStyle.rowInset)
        .padding(.vertical, 4)
    }

    // MARK: - Peek

    /// A peek control or key (R13): step, close, Stage Change (3a-ii), or Revert — `editor_replace_range` with the hunk's
    /// old lines, which asks nothing (Rule 1) and is undone with ⌘Z.
    ///
    /// Revert passes `expect`, the hunk's new text as this snapshot has it, so the store refuses it
    /// when the buffer changed since (final review 3); a press while one is still in flight is
    /// dropped, so a double-click reverts one hunk, not the next one too.
    private func peekOp(_ op: String) {
        Task {
            switch op {
            case "up": await dispatch("editor_peek_step", ["delta": .integer(-1)])
            case "down": await dispatch("editor_peek_step", ["delta": .integer(1)])
            case "close": await dispatch("editor_peek_close", [:])
            // 3a-ii: that one hunk into the index. The peek exists only on a tracked file (its
            // baseline is the index text), so the button is never drawn where it has nothing to stage.
            case "stage": await stageHunk()
            case "revert":
                guard !host.reverting, let latest = host.latest, let r = editorPeekRevert(latest) else { return }
                host.reverting = true
                await dispatch("editor_replace_range", ["path": .string(r.path), "range": editorRangeParam(r.range),
                                                        "text": .string(r.text), "expect": .string(r.expect)])
                host.reverting = false
            default: break
            }
        }
    }

    // MARK: - Conflicts

    /// An actions-row press (R2): Accept through `editor_conflict_accept` — the store edits the buffer,
    /// one undo step, and the page puts the cursor back at the block (Rule 6) — or Compare Changes'
    /// tab. An Accept pressed while one is still in flight is dropped (Rule 5): a double-click takes
    /// one block, not the one that moved up into its place.
    private func conflictOp(_ block: Int, _ op: String) {
        Task {
            if op == "compare" { await dispatch("editor_conflict_compare", [:]); return }
            guard !host.accepting else { return }
            host.accepting = true
            await dispatch("editor_conflict_accept", ["block": .integer(Int64(block)), "take": .string(op)])
            host.accepting = false
        }
    }

    // MARK: - Review boxes

    /// A review box's control, as the registry action every caller uses (Invariant 2): the draft
    /// kept on blur and dropped by Discard (`review_reply_draft`), Restore yours
    /// (`review_reply_draft_restore`), Send (`review_reply_send`, gated:
    /// the plane shows the text and the thread's place), Hand to agent (`ticket_hand_off_open`, the
    /// popover only), Resolve and Unresolve (`review_resolve`), and
    /// ⌥↓ / ⌥↑ from the box (`review_step` from that thread). A Send is drawn as sending from the press
    /// until its dispatch — the plane included — is over, and is not pressed twice (Rule 5).
    private func reviewOp(_ thread: String, _ op: String, _ text: String?, _ delta: Int?) {
        Task {
            let t = host.reviews.thread(thread)
            switch op {
            case "draft":
                await dispatch("review_reply_draft", ["thread": .string(thread), "text": text.map { .string($0) } ?? .null])
            case "discard":
                await dispatch("review_reply_draft", ["thread": .string(thread), "text": .null])
            case "restore":
                // **Restore yours**: one click, no question (Rule 1) — the agent's draft it replaces was
                // the later value, and the operator's own words come back as theirs.
                await dispatch("review_reply_draft_restore", ["thread": .string(thread)])
            case "send":
                guard let t, let body = text, !body.isEmpty, host.beginReviewSend(thread) else { return }
                // The text as sent is the draft until the post succeeds (a failed or refused Send keeps it).
                // Unchanged text writes nothing (`EditorTicketStore.setDraft`): an agent's draft stays the
                // agent's, and the operator's replaced one restorable, until the post lands.
                await dispatch("review_reply_draft", ["thread": .string(thread), "text": .string(body)])
                await dispatch("review_reply_send", [
                    "root": .string(t.root), "repo": .string(t.repo), "pr": .integer(Int64(t.number)),
                    "thread": .string(thread), "body": .string(body), "path": .string(t.path),
                    "line": .integer(Int64(t.line))])
                host.endReviewSend(thread)
            case "handoff":
                // Hand to agent: the popover opens prefilled from this thread (`ticket_hand_off_open`);
                // only the operator's Start in it hands anything off.
                await dispatch("ticket_hand_off_open", ["thread": .string(thread)])
            case "resolve", "unresolve":
                guard let t else { return }
                await dispatch("review_resolve", ["root": .string(t.root), "thread": .string(thread),
                                                  "resolved": .bool(op == "resolve")])
                host.resendReviews()
            case "step":
                // The keyboard goes to the box of the thread stepped to, by its id, whenever that box is
                // drawn; a step that did not run gives it back (nil).
                let reply = await dispatchReply("review_step", ["delta": .integer(Int64(delta ?? 1)), "from": .string(thread)])
                var to: String?
                if case .object(let o)? = reply, case .string(let t)? = o["thread"] { to = t }
                let key = to.flatMap { host.reviews.thread($0) }
                    .map { editorTabKey(.file(path: $0.root + "/" + $0.path, root: $0.root)) }
                host.renderer?.focusReview(thread: to, key: key)
            default: break
            }
        }
    }

    // MARK: - Compare

    private func openCompare(_ tab: EditorTab) {
        guard let path = tab.path else { return }
        compareFailure = nil
        Task {
            guard let disk = await diskText(path) else {
                compareFailure = "\((path as NSString).lastPathComponent) could not be read from disk to compare"
                return
            }
            comparing = EditorComparing(path: path, disk: disk)
            showCompare()
        }
    }

    /// Disk on the original side, the buffer as it is now on the modified side.
    private func showCompare() {
        guard let c = comparing, let tab = snapshot.tabs.first(where: { $0.path == c.path }) else { return }
        host.showCompare(original: c.disk, modified: tab.text, language: tab.language)
    }

    private var ownsCompareEscape: Bool {
        isKeyboardOwner && isFocusedPane && unsavedPrompt == nil && !saveAsRequested
    }

    private func closeCompare() {
        comparing = nil
        host.endCompare()
        host.focus()
    }

    private func compareHeader(_ c: EditorComparing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("\((c.path as NSString).lastPathComponent) — on disk ↔ unsaved")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                // Esc is Close wherever the keyboard is in this window (a click on Compare leaves it
                // with the window, out of reach of the pane's onKeyPress and the page's own keys) —
                // but only while no plane, prompt or field claims Esc: a window holds one live
                // `.cancelAction` (`ConfirmationPlane.ownsEscape`).
                Button("Close", action: closeCompare)
                    .keyboardShortcut(ownsCompareEscape ? KeyboardShortcut.cancelAction : nil)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(EditorPaneStyle.text)
                    .accessibilityIdentifier("editor.compare.close")
            }
            .padding(.horizontal, PaneStripStyle.rowInset)
            .padding(.vertical, 4)
            PaneHairline()
        }
    }

    // MARK: - Save as

    private var saveAsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField("Save as (a path inside the project)", text: $saveAsPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text)
                    .focused($saveAsFocused)
                    .onSubmit { submitSaveAs() }
                    .onKeyPress(.escape) {
                        dismissSaveAs()
                        return .handled
                    }
                    .accessibilityIdentifier("editor.saveAs.field")
                if saveAsInFlight { EditorBusyTick() }
                Button("Save") { submitSaveAs() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(EditorPaneStyle.text)
                    .disabled(saveAsInFlight)
                    .accessibilityIdentifier("editor.saveAs.save")
                Button("Cancel", action: dismissSaveAs)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                    .accessibilityIdentifier("editor.saveAs.cancel")
            }
            // Rule 1: writing over an existing file destroys it, so the field asks first, inline.
            if let name = saveAsReplacing {
                HStack(spacing: 12) {
                    Text("Replace \(name)?")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Replace") { submitSaveAs(replace: true) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EditorPaneStyle.text)
                        .disabled(saveAsInFlight)
                        .accessibilityIdentifier("editor.saveAs.replace")
                    Button("Cancel") {
                        saveAsReplacing = nil
                        saveAsFocused = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                    .accessibilityIdentifier("editor.saveAs.replaceCancel")
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editor.saveAs.replacePrompt")
            }
            if let saveAsFailure {
                Text(saveAsFailure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("editor.saveAs.failure")
            }
        }
        .padding(.horizontal, PaneStripStyle.rowInset)
        .padding(.vertical, 4)
        .background(EditorPaneStyle.text.opacity(0.04))
        // Rule 3: the field takes the keyboard when it appears, prefilled with the selected tree row's
        // folder, else the first root (Rule 9: a suggestion, typed over freely).
        .onAppear {
            saveAsPath = saveAsBase.isEmpty ? "" : saveAsBase + "/"
            saveAsFailure = nil
            saveAsReplacing = nil
            saveAsFocused = true
        }
        // The roots can land after the field appears (just after a launch), and the selected row can
        // move: the prefill follows while the field still holds only the old prefill, never over what
        // was typed.
        .onChange(of: saveAsBase) { old, now in
            if saveAsPath == (old.isEmpty ? "" : old + "/") { saveAsPath = now.isEmpty ? "" : now + "/" }
        }
        // AppKit selects a field's whole text when it takes focus, so the first key typed would
        // replace the prefilled root (and a path being corrected): the caret goes to the end.
        .onChange(of: saveAsFocused) { _, now in if now { caretToEndOfFocusedField() } }
        // A different path is a different question: the Replace prompt was about the old one.
        .onChange(of: saveAsPath) { _, _ in saveAsReplacing = nil }
    }

    /// Once the field editor has the keyboard (the next turn), its caret goes after the text.
    private func caretToEndOfFocusedField() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private func submitSaveAs(replace: Bool = false) {
        guard !saveAsInFlight else { return }   // Rule 5: one save at a time
        saveAsInFlight = true
        let path = saveAsPath
        Task {
            let result = await saveAs(path, replace)
            saveAsInFlight = false
            saveAsReplacing = nil
            saveAsFailure = nil
            switch result {
            case .saved: host.focus()
            case .exists(let name): saveAsReplacing = name
            case .failed(let text): saveAsFailure = text
            }
        }
    }

    private func dismissSaveAs() {
        saveAsFailure = nil
        saveAsReplacing = nil
        cancelSaveAs()
        host.focus()
    }

    // MARK: - Empty

    private var emptyState: some View {
        ZStack {
            EditorPaneStyle.slab
            Text("⌘P to open a file · ⌘T for a scratch tab")
                .font(.system(size: 12))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.46))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.empty")
    }
}

private struct EditorComparing: Equatable {
    let path: String
    let disk: String
}

// MARK: - The Monaco host

/// The pane's one Monaco editor and what it was last told. A class held in `@State`, so it lives
/// exactly as long as the pane's view identity does.
@MainActor @Observable
final class EditorHost {
    private(set) var renderer: MonacoEditorRenderer?
    /// What the renderer holds, per tab key (`editorRenderedAfter`).
    @ObservationIgnored var rendered: [String: EditorRendered] = [:]
    /// The key the renderer shows.
    @ObservationIgnored var active: String?
    /// The pane's last opened find serial, beside `rendered` rather than on a tab's entry, so closing
    /// every tab never makes the next one replay the find. Nil until the first snapshot seeds it.
    @ObservationIgnored var findShown: Int?
    /// The pane's closures, handed in by the view.
    @ObservationIgnored var bufferChanged: ((EditorTabSubject, String, Int) async -> Void)?
    @ObservationIgnored var viewReported: ((EditorTabSubject, EditorPosition, EditorRange?, ClosedRange<Int>?, Double) async -> Void)?
    /// Monaco's find bar state, a view report like the cursor's (`PaneStore.editorFindDidReport`).
    @ObservationIgnored var findReported: ((EditorFindReport) async -> Void)?
    /// Whether something else holds the keyboard for now; `focus` leaves it there.
    @ObservationIgnored var keyboardHeld: () -> Bool = { false }
    /// 3b-viii ghost-text: the request for the text at a caret in the tab at a path in a language
    /// (built across the schema's await) with the quick-tasks generation it was built in, its
    /// suggestion (nil: draw nothing; also for a request built in an earlier generation), and the
    /// release of the pane's pending request.
    @ObservationIgnored var ghostPrepare: ((String, String.Index, String, String) async -> (InfillRequest, Int))?
    @ObservationIgnored var ghostSuggest: ((InfillRequest, Int) async -> String?)?
    @ObservationIgnored var ghostCancel: (() -> Void)?
    /// Which page requests may still be asked: a cancel can land while one is being built.
    @ObservationIgnored private var ghostOrder = GhostRequestOrder()
    @ObservationIgnored private var ghostEnabled = false
    @ObservationIgnored private var ghostEnabledSent: Bool?
    /// The last snapshot's tabs, subject by key: a post is addressed by the subject its key names,
    /// never by a position that a close or open may have moved (final review I1).
    @ObservationIgnored private var subjects: [String: EditorTabSubject] = [:]
    /// The operator's own text posts still on their way to the store, and the texts they carry:
    /// a snapshot behind them is held (`editorSnapshotToRender`). The write that lands last brings
    /// its own snapshot, which renders.
    @ObservationIgnored private var typingInFlight = 0
    @ObservationIgnored private var typed: [String: Set<String>] = [:]
    /// View reports in flight: they hold nothing back, but keep the rendered cursor.
    @ObservationIgnored private var viewsInFlight = 0
    /// The agent-edit serial last told to the page, per key.
    @ObservationIgnored private var basisSent: [String: Int] = [:]
    @ObservationIgnored private var starting = false
    /// The newest snapshot handed in. One that lands while the renderer is still being made
    /// (a new pane's first tab) is applied when it exists, not dropped.
    @ObservationIgnored private(set) var latest: EditorSnapshot?
    /// The pane's key handler for keys the page took (`captureKeys`), re-handed by the view.
    @ObservationIgnored var onKey: ((String) -> Void)?
    /// The marks last sent, per key: an unchanged set is not sent again.
    @ObservationIgnored private var marksSent: [String: [EditorGutterMark]] = [:]
    @ObservationIgnored private var marksTask: Task<Void, Never>?
    /// A mark clicked: (tab subject, line).
    @ObservationIgnored var peekPressed: ((String) -> Void)?
    /// 3a-ii-b: the diff's right-click Stage / Unstage Selected Ranges: ("stage" | "unstage", selections).
    @ObservationIgnored var rangesPressed: ((String, [EditorRange]) -> Void)?
    @ObservationIgnored var markClicked: ((EditorTabSubject, Int) -> Void)?
    /// 3a-v-a inline blame: the fetch for (root, relative path, unsaved text or nil), and the hover's
    /// Open Changes for (root, the commit and the file's names there). Fetched per tab text, never per
    /// cursor move (R1).
    @ObservationIgnored var blameFor: ((String, String, String?) async -> [GitBlameInfo]?)?
    @ObservationIgnored var blameOpen: ((String, GitCommitRef) -> Void)?
    @ObservationIgnored var openLink: ((String, Bool) -> Void)?
    @ObservationIgnored private var blameOn = false
    @ObservationIgnored private var blames = EditorBlameCache()
    @ObservationIgnored private var blameTask: Task<Void, Never>?
    /// What was last drawn per key ("line|text"); what was fetched, and for which text, is `blames`'.
    @ObservationIgnored private var blameShown: [String: String] = [:]
    /// A Revert is on its way to the store: another press is dropped until it lands.
    @ObservationIgnored var reverting = false
    /// 3a-v-b: an actions-row press — (the block's `<<<<<<<` line, "current" | "incoming" | "both" |
    /// "compare") — and the line of the first block, asked once when a conflicted tab first shows at
    /// its top. An Accept is on its way to the store while `accepting` holds.
    @ObservationIgnored var conflictPressed: ((Int, String) -> Void)?
    @ObservationIgnored var conflictReveal: ((Int) -> Void)?
    @ObservationIgnored var accepting = false
    /// Ticket view: what the review boxes draw from, the boxes last sent per key, the Sends this
    /// pane has pressed and not seen end (drawn as sending, plane included), a box's control pressed
    /// — (thread, op, text, delta) — and the re-placing after typing.
    @ObservationIgnored private(set) var reviews: EditorReviewsState = .empty
    @ObservationIgnored private var reviewsSent: [String: [ReviewBox]] = [:]
    @ObservationIgnored private var reviewSending: Set<String> = []
    @ObservationIgnored var reviewPressed: ((String, String, String?, Int?) -> Void)?
    @ObservationIgnored private var reviewsTask: Task<Void, Never>?
    /// The window's git roots, which say whether a tab's file is conflicted (`editorConflicted`).
    @ObservationIgnored private var conflictRoots: [GitRootState] = []
    /// Per key: the text last parsed ("" while the file is not conflicted), the blocks last sent, and
    /// whether its first block was revealed (once per tab).
    @ObservationIgnored private var conflictsParsed: [String: String] = [:]
    @ObservationIgnored private var conflictsSent: [String: [EditorConflictBlock]] = [:]
    @ObservationIgnored private var conflictsRevealed: Set<String> = []
    /// A first block being revealed, per key, until the page reports a cursor off 1:1: every snapshot
    /// renders it, so a 1:1 report the page made before the reveal cannot put the cursor back (3a-v-b
    /// cover, defect 1).
    @ObservationIgnored private var conflictLanding: [String: EditorPosition] = [:]
    /// Compare is on screen: snapshots are kept (`latest`) but not rendered, or the next one — a
    /// keystroke's echo, a view report — would put the active tab back over Compare.
    @ObservationIgnored private var comparing = false

    /// The offline rule list, compiled once per launch and shared by every editor pane.
    private static var networkBlock: WKContentRuleList?

    func start() async {
        guard renderer == nil, !starting else { return }
        starting = true
        defer { starting = false }
        let block: WKContentRuleList
        do {
            if let cached = Self.networkBlock {
                block = cached
            } else {
                block = try await MonacoEditorRenderer.compileNetworkBlock()
                Self.networkBlock = block
            }
        } catch {
            // No rule list, no renderer: Monaco never loads without its network block.
            FileHandle.standardError.write(Data("monaco: no network block, no editor: \(error)\n".utf8))
            return
        }
        let made = MonacoEditorRenderer(blockNetwork: block)
        made.onLog = { line in FileHandle.standardError.write(Data("monaco-editor: \(line)\n".utf8)) }
        // The operator's own text and view go into `rendered` BEFORE the store round-trip, so
        // the snapshot that brings them back renders as no step (Task 7's rule).
        made.onText = { [weak self] key, text, basis in
            guard let self else { return }
            let subject: EditorTabSubject
            switch editorTypingPost(key: key, basis: basis, subjects: self.subjects, rendered: self.rendered) {
            case .drop: return
            case .resync(let storeText, let serial):
                // Made before an agent edit reached the page: the store drops it, so the page goes
                // back to the store's text rather than keep text the store lacks (final review I2).
                self.renderer?.resetText(key: key, text: storeText, basis: serial)
                return
            case .send(let s): subject = s
            }
            self.rendered[key]?.text = text
            self.showConflicts()
            self.scheduleReviews()
            self.typed[key, default: []].insert(text)
            self.typingInFlight += 1
            let send = self.bufferChanged
            Task { @MainActor in
                await send?(subject, text, basis)
                self.typingInFlight -= 1
                if self.typingInFlight == 0 { self.typed = [:] }
            }
        }
        made.onView = { [weak self] key, cursor, selection, visible, top in
            guard let self, let subject = self.subjects[key] else { return }
            self.rendered[key]?.cursor = cursor
            self.rendered[key]?.selection = selection
            if cursor != EditorPosition(line: 1, column: 1) { self.conflictLanding[key] = nil }
            self.showBlame(key: key, line: cursor.line)
            self.viewsInFlight += 1
            let send = self.viewReported
            Task { @MainActor in
                await send?(subject, cursor, selection, visible, top)
                self.viewsInFlight -= 1
            }
        }
        made.onKey = { [weak self] key in self?.onKey?(key) }
        made.onPeek = { [weak self] _, op in self?.peekPressed?(op) }
        made.onRanges = { [weak self] _, op, selections in self?.rangesPressed?(op, selections) }
        made.onLink = { [weak self] url, alt in self?.openLink?(url, alt) }
        made.onBlame = { [weak self] key, op, id, alt in
            guard let self, case .file(let path, let root)? = self.subjects[key], path.hasPrefix(root + "/") else { return }
            if op == "copy" {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
            } else if op == "web" {
                // 3c-i: the commit's page, which editor_blame set only for a pushed commit on a known host.
                if let page = self.blames.commit(key: key, id: id)?.web { self.openLink?(page.url, alt) }
            } else {
                // Under the file's name at that commit, and the one before it across a rename (3a-v-a walk).
                let current = String(path.dropFirst(root.count + 1))
                let b = self.blames.commit(key: key, id: id)
                self.blameOpen?(root, b.map { editorBlameCommitRef($0, currentPath: current) } ?? GitCommitRef(id: id, path: current))
            }
        }
        made.onConflict = { [weak self] key, block, op in
            guard let self, key == self.active else { return }
            self.conflictPressed?(block, op)
        }
        // Addressed by thread, never by the shown key: a draft flushed as its file is left lands
        // after the next tab is shown.
        made.onReview = { [weak self] _, thread, op, text, delta in self?.reviewPressed?(thread, op, text, delta) }
        made.onMark = { [weak self] key, line in
            guard let self, let s = self.subjects[key] else { return }
            self.markClicked?(s, line)
        }
        // The page waits on every ghost request until it is resolved or it cancels it, so a request
        // that cannot be asked (a tab that never asks, a caret that splits a character) is resolved
        // empty at once. The page drops a resolve for a request it no longer waits on.
        // A request cancelled, or overtaken by a newer one, while it was being built is never asked
        // (`GhostRequestOrder`).
        made.onGhost = { [weak self] key, id, text, offset in
            guard let self else { return }
            guard self.ghostEnabled, let prepare = self.ghostPrepare, let suggest = self.ghostSuggest,
                  let subject = self.subjects[key],
                  let tab = self.latest?.tabs.first(where: { $0.subject == subject }),
                  let context = ghostTabContext(tab),
                  let caret = ghostCaret(text: text, utf16Offset: offset) else {
                self.renderer?.resolveGhost(id: id, text: nil)
                return
            }
            Task { @MainActor [weak self] in
                let (request, generation) = await prepare(text, caret, context.path, context.language)
                guard let self else { return }
                guard self.ghostOrder.admit(id) else {
                    self.renderer?.resolveGhost(id: id, text: nil)
                    return
                }
                let suggestion = await suggest(request, generation)
                self.renderer?.resolveGhost(id: id, text: suggestion)
            }
        }
        made.onGhostCancel = { [weak self] id in
            guard let self, self.ghostOrder.cancel(id) else { return }
            self.ghostCancel?()
        }
        made.onFind = { [weak self] report in
            guard let send = self?.findReported else { return }
            Task { @MainActor in await send(report) }
        }
        renderer = made
        applyOptions()
        applyGhostEnabled()
        if let latest { apply(latest) }
    }

    /// The options last asked for, applied when the renderer exists and again whenever they change.
    private var wantedOptions: EditorViewOptions?
    private var appliedOptions: EditorViewOptions?

    /// Ghost-text on or off: the page asks nothing while it is off (3b-viii).
    func setGhostEnabled(_ on: Bool) {
        ghostEnabled = on
        applyGhostEnabled()
    }

    private func applyGhostEnabled() {
        guard let renderer, ghostEnabledSent != ghostEnabled else { return }
        renderer.setGhostEnabled(ghostEnabled)
        ghostEnabledSent = ghostEnabled
    }

    func setOptions(_ o: EditorViewOptions) {
        wantedOptions = o
        applyOptions()
    }

    private func applyOptions() {
        guard let renderer, let o = wantedOptions, o != appliedOptions else { return }
        renderer.setOptions(o)
        appliedOptions = o
    }

    /// Renders `snapshot` — unless it is behind the operator's own typing (`editorSnapshotToRender`).
    func apply(_ snapshot: EditorSnapshot) {
        latest = snapshot
        subjects = Dictionary(snapshot.tabs.map { (editorTabKey($0), $0.subject) }, uniquingKeysWith: { a, _ in a })
        guard !comparing, let renderer else { return }
        let activeKey = active
        var snapshot = snapshot
        for i in snapshot.tabs.indices {
            guard let at = conflictLanding[editorTabKey(snapshot.tabs[i])] else { continue }
            snapshot.tabs[i].cursor = at
            snapshot.tabs[i].selection = nil
        }
        guard let shown = editorSnapshotToRender(
            snapshot, rendered: rendered, active: activeKey, typed: activeKey.flatMap { typed[$0] } ?? [],
            typingInFlight: typingInFlight > 0, viewInFlight: viewsInFlight > 0) else { return }
        let found = findShown ?? editorFindShownSeed(shown)
        let steps = editorRenderSteps(rendered: rendered, active: activeKey, snapshot: shown, findShown: found)
        editorApply(steps, to: renderer)
        for case .dispose(let k) in steps {
            marksSent[k] = nil; blames.forget(key: k); blameShown[k] = nil
            conflictsParsed[k] = nil; conflictsSent[k] = nil; conflictsRevealed.remove(k); conflictLanding[k] = nil
            reviewsSent[k] = nil
        }
        // The page moves a renamed tab's blocks with its model; a rename is not a first show.
        for case .rekey(let from, let to) in steps {
            if conflictsRevealed.remove(from) != nil { conflictsRevealed.insert(to) }
            if let at = conflictLanding.removeValue(forKey: from) { conflictLanding[to] = at }
            if let sent = reviewsSent.removeValue(forKey: from) { reviewsSent[to] = sent }
        }
        rendered = editorRenderedAfter(steps, rendered: rendered, snapshot: shown)
        findShown = editorFindShownAfter(steps, findShown: found, snapshot: shown)
        active = shown.active.flatMap { $0 < shown.tabs.count ? editorTabKey(shown.tabs[$0]) : nil }
        // The page learns each serial after the steps that applied it, in call order.
        basisSent = basisSent.filter { rendered[$0.key] != nil }
        if let key = active, let serial = rendered[key]?.agentSerial, basisSent[key] != serial {
            basisSent[key] = serial
            renderer.setBasis(key: key, serial: serial)
        }
        scheduleMarks(shown)
        scheduleBlame(shown)
        showConflicts()
        showReviews()
    }

    /// Ticket view: the reads, drafts, sends or head texts moved.
    func setReviews(_ r: EditorReviewsState) {
        guard r != reviews else { return }
        reviews = r
        showReviews()
    }

    /// Claims `thread` for a Send pressed here; false while one is already on its way (Rule 5).
    func beginReviewSend(_ thread: String) -> Bool {
        guard reviewSending.insert(thread).inserted else { return false }
        showReviews()
        return true
    }

    func endReviewSend(_ thread: String) {
        reviewSending.remove(thread)
        resendReviews()
    }

    /// Sends the shown tab's boxes again even when unchanged: a control the page drew as pressed
    /// (Resolve, Send) is drawn from the boxes again once its dispatch is over, whatever it did.
    func resendReviews() {
        if let key = active { reviewsSent[key] = nil }
        showReviews()
    }

    /// The shown file tab's review boxes, placed against the text the page holds (`editorShowReviews`
    /// decides; a diff or scratch tab gets none). Unchanged, nothing is sent.
    private func showReviews() {
        guard let renderer, !comparing, let key = active, let latest,
              let i = latest.active, i < latest.tabs.count, editorTabKey(latest.tabs[i]) == key else { return }
        var r = reviews
        r.reads.sending.formUnion(reviewSending)
        editorShowReviews(latest, buffer: rendered[key]?.text, reviews: r, sent: &reviewsSent, to: renderer)
    }

    /// After typing, the boxes are placed again once it pauses: Monaco carries each zone with its
    /// line meanwhile.
    private func scheduleReviews() {
        reviewsTask?.cancel()
        reviewsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.showReviews()
        }
    }

    /// 3a-v-b: the git roots moved; every tab's conflicted state is read again, the active one now.
    func setConflictRoots(_ roots: [GitRootState]) {
        guard roots != conflictRoots else { return }
        conflictRoots = roots
        conflictsParsed = [:]
        showConflicts()
    }

    /// The active file tab's conflict blocks, parsed from the text the page holds (the operator's
    /// typing included) whenever it changes, while its root lists the file as conflicted; none
    /// otherwise, so markers git did not write draw no row. Unchanged, nothing is sent. Synchronous, so
    /// an Accept's edit and the blocks it leaves reach the page in one go and a row never posts a line
    /// from before it.
    private func showConflicts() {
        guard let renderer, let key = active, let r = rendered[key], let subject = subjects[key],
              let tab = latest?.tabs.first(where: { $0.subject == subject }), tab.diffState == nil else { return }
        let on = editorConflicted(tab, roots: conflictRoots)
        let text = on ? r.text : ""
        guard conflictsParsed[key] != text else { return }
        conflictsParsed[key] = text
        let blocks = on ? editorConflictBlocks(text) : []
        if (conflictsSent[key] ?? []) != blocks {
            conflictsSent[key] = blocks
            renderer.setConflicts(key: key, blocks: blocks)
        }
        // Once per tab, and only one opened at its top: a tab opened at a search hit stays there (Rule 6).
        if let first = blocks.first, conflictsRevealed.insert(key).inserted,
           r.cursor == EditorPosition(line: 1, column: 1), first.start > 1 {
            let at = EditorPosition(line: first.start, column: 1)
            conflictLanding[key] = at
            rendered[key]?.cursor = at
            rendered[key]?.selection = nil
            renderer.reveal(key: key, cursor: at, selection: nil)
            conflictReveal?(first.start)
        }
    }

    /// 3a-v-a: turns inline blame on or off; off clears every annotation drawn.
    func setBlameEnabled(_ on: Bool) {
        guard blameOn != on else { return }
        blameOn = on
        blameTask?.cancel()
        if !on, let renderer {
            for key in blameShown.keys { renderer.setBlame(key: key, line: 0, text: "", hover: nil, id: "") }
        }
        blameShown = [:]
        blames = EditorBlameCache()
        if on, let latest { scheduleBlame(latest) }
    }

    /// A root's status moved (a commit, a checkout): the active tab's blame is fetched again; what it
    /// showed stays until the new one lands (final review I4).
    func refreshBlame() {
        blames.invalidate()
        if let latest { scheduleBlame(latest) }
    }

    /// The active tab's blame, fetched at once for a tab not yet blamed and 500 ms after its text last
    /// changed otherwise (R1). Only a writable file tab under a root: never diff, read-only or scratch tabs.
    private func scheduleBlame(_ snapshot: EditorSnapshot) {
        guard blameOn, let i = snapshot.active, i < snapshot.tabs.count else { return }
        let t = snapshot.tabs[i], key = editorTabKey(t)
        // A fetch in flight for this text is never restarted by the next snapshot (final review I3).
        guard t.diffState == nil, !t.readOnly, case .file(let path, let root) = t.subject, path.hasPrefix(root + "/"),
              blames.needsFetch(key: key, text: t.text), let fetch = blameFor else { return }
        let rel = String(path.dropFirst(root.count + 1)), unsaved = t.dirty ? t.text : nil
        let first = !blames.fetched(key: key)
        blameTask?.cancel()
        let gen = blames.begin(key: key, text: t.text)
        blameTask = Task { @MainActor [weak self] in
            if !first { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { self?.blames.abandon(key: key, gen: gen); return }
            let lines = await fetch(root, rel, unsaved) ?? []
            guard let self else { return }
            guard !Task.isCancelled else { self.blames.abandon(key: key, gen: gen); return }
            guard self.blames.land(key: key, gen: gen, lines: lines) else { return }
            self.blameShown[key] = nil
            if let line = self.rendered[key]?.cursor.line { self.showBlame(key: key, line: line) }
        }
    }

    /// Draws `key`'s blame for `line`, or clears it when there is none; unchanged, nothing is sent.
    private func showBlame(key: String, line: Int) {
        guard blameOn, let renderer else { return }
        let b = blames.line(key: key, line)
        let text = b.map { editorBlameText($0) } ?? ""
        let mark = "\(line)|\(text)"
        guard blameShown[key] != mark else { return }
        blameShown[key] = mark
        renderer.setBlame(key: key, line: line, text: text, hover: b.flatMap { editorBlameHover($0) }, id: b?.id ?? "")
    }

    /// The active file tab's marks, 150 ms after its text or baseline last changed. No baseline, no marks.
    private func scheduleMarks(_ snapshot: EditorSnapshot) {
        marksTask?.cancel()
        guard let i = snapshot.active, i < snapshot.tabs.count, snapshot.tabs[i].diffState == nil else { return }
        let t = snapshot.tabs[i], key = editorTabKey(t)
        let base = t.readOnly ? nil : t.baseline, text = t.text
        marksTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            // The diff runs off the main actor (it is capped, but still not free).
            let marks = await Task.detached(priority: .userInitiated) {
                base.map { editorGutterMarks(editorHunks(base: $0, text: text)) } ?? []
            }.value
            guard !Task.isCancelled, let self, let renderer = self.renderer else { return }
            guard self.marksSent[key] != marks else { return }
            self.marksSent[key] = marks
            renderer.setMarks(key: key, marks: marks)
        }
    }

    /// Shows `original` ↔ `modified` in the diff editor as Compare (R2), outside the tab render.
    func showCompare(original: String, modified: String, language: String) {
        comparing = true
        renderer?.showDiff(key: "compare", original: original, modified: modified, language: language,
                           cursor: EditorPosition(line: 1, column: 1), scrollTop: 0)
        active = nil   // when Compare ends, the active tab is shown again, as a switch would show it
    }

    /// Back from Compare: the active tab is shown again.
    func endCompare() {
        comparing = false
        active = nil
        if let latest { apply(latest) }
    }

    /// The editor takes the keyboard: the web view first responder, then Monaco.
    ///
    /// A pane's first focus can arrive before SwiftUI has put the new web view in the window
    /// (the renderer was made this same turn), when there is no window to make it first
    /// responder of. It waits for one, briefly: twenty tries a frame apart, then gives up.
    func focus(tries: Int = 20) {
        guard let renderer else { return }
        guard let window = renderer.webView.window else {
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focus(tries: tries - 1) }
            return
        }
        guard !keyboardHeld() else { return }
        window.makeFirstResponder(renderer.webView)
        renderer.focus()
    }

    /// The editor gives the keyboard up, when its web view — or `other`, Compare's — holds
    /// it: the window's first responder becomes nil, as a field does on Escape
    /// (`ApiFieldEditor`), and no pane owns the keys until one takes them. Anything else
    /// holding the keyboard keeps it.
    func resignKeyboard(alsoFrom other: NSView?) {
        // Either may be out of the window: Compare takes Monaco's place in the pane, and the
        // view hosting Monaco is dismantled while it is open (`GitDiffHostView`).
        let owners = [renderer?.webView, other].compactMap { $0 }
        guard let window = owners.lazy.compactMap(\.window).first,
              let responder = window.firstResponder as? NSView else { return }
        for owner in owners where responder === owner || responder.isDescendant(of: owner) {
            window.makeFirstResponder(nil)
            return
        }
    }
}

// MARK: - The unsaved prompt

/// Save / Don't Save / Cancel before unsaved edits are dropped (3b-i Task 9) — over an editor's tab
/// strip for one tab, centred on the canvas for a pane, an organisation switch or a quit.
///
/// It takes the keyboard when it appears (Rule 3), so Monaco does not keep Return and Esc:
/// **Return is Save, Esc is Cancel.** The buttons also carry the default and cancel shortcuts.
/// Rule 1: dropping unsaved work destroys it, so this is a confirmation the rules allow.
///
/// **Save is left out when it could write nothing** (`UnsavedPrompt.canSave`): dirty scratch tabs or
/// other projects' files in a scope not on screen. Rule 6 forbids jumping there to save them, so the
/// prompt lists them with Don't Save and Cancel only, and Return is then Cancel's.
struct UnsavedPromptBar: View {
    let message: String
    var canSave = true
    /// Over an editor pane's own strip (the compact chrome): a row across the pane, no card — at
    /// least the strip's 32 pt, more only while the message wraps (Rule 8).
    var compact = false
    let resolve: (UnsavedChoice) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("editor.unsaved.message")
            Spacer(minLength: 0)
            if canSave {
                Button("Save") { resolve(.save) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EditorPaneStyle.text)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("editor.unsaved.save")
            }
            Button("Don't Save") { resolve(.dontSave) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(EditorPaneStyle.amber)
                .accessibilityIdentifier("editor.unsaved.dontSave")
            Button("Cancel") { resolve(.cancel) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("editor.unsaved.cancel")
        }
        .padding(.horizontal, compact ? PaneStripStyle.rowInset : 12)
        .padding(.vertical, compact ? 4 : 8)
        .frame(minHeight: compact ? PaneStripStyle.rowHeight : nil)
        .background(EditorPaneStyle.slab, in: RoundedRectangle(cornerRadius: compact ? 0 : 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorPaneStyle.text.opacity(compact ? 0 : 0.14)))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.return) {
            resolve(canSave ? .save : .cancel)
            return .handled
        }
        .onKeyPress(.escape) {
            resolve(.cancel)
            return .handled
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.unsaved")
    }
}

// MARK: - Treatment

/// Rule 5's load mark, the rail's busy treatment (`Rail.tick`): a 2 pt tick in §5's green with its
/// glow — no spinner (§9).
struct EditorBusyTick: View {
    var label = "saving"
    var identifier = "editor.saving"

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(RailTreatment.workingTickColour))
            .frame(width: 2, height: 12)
            .shadow(color: Color(RailTreatment.workingTickColour).opacity(0.85), radius: 5)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}

enum EditorPaneStyle {
    static let text = Color(RailTreatment.textColour)
    static let slab = Color(EditorSurface.slab)
    /// The artboard's active-tab tick, `#9e82ff`.
    static let tick = Color(red: 0x9e / 255, green: 0x82 / 255, blue: 0xff / 255)
    static let amber = Color(TerminalPalette.amber)
    /// §5's violet `#7c5cff`: the column's selected row and a search switch that is on.
    static let violet = Color(VoidPalette.violet)
    static let lifted = Color(EditorSurface.lifted)

    /// §5: amber for a change, green for an addition, a deletion muted — never red (3a-i's tones).
    static func tone(_ t: GitStatusTone) -> Color {
        switch t {
        case .modified: amber
        case .added: Color(TerminalPalette.green)
        case .muted: text.opacity(0.45)
        }
    }
}

/// Hosts the pane's Monaco web view in a container the pane owns (3a-i's, moved here with the Git
/// pane in 3b-iii). The web view outlives this view — a SwiftUI rebuild removes it and puts the same
/// one back — so dismantling detaches it and nothing more.
struct GitDiffHostView: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(EditorPaneStyle.slab).cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { attach(to: container) }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        guard let webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
