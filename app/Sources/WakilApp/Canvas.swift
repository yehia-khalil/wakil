import WakilKit
import SwiftUI

extension WakilWindow {
    // MARK: - The canvas

    /// Every pane in the active project's arrangement, floating and
    /// overlapping, with the snap line the current drag would land on.
    ///
    /// `.clipped()` because a pane can sit outside the visible canvas —
    /// `LayoutStore`'s void is 1440×900 and this window is not — and
    /// `.offset` does not participate in layout, so an unclipped pane would
    /// draw over the rail rather than being cut off at the canvas edge. The
    /// rail is what makes a pane that has gone off the edge findable again,
    /// which is exactly §5's reason for it.
    ///
    /// **Not the thought thread**, any more — since 2b-iv Task 5 moved it
    /// into a `ZStack` overlay pinned above the canvas (`WakilWindow.swift`),
    /// the relationship inverted: the thread now draws over the canvas, not
    /// the other way around, clipped or not.
    func canvas(_ model: WindowModel) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.layoutSnapshot.panes) { pane in
                paneView(model, pane)
                    // The rendered size follows the live resize gesture;
                    // the store still only hears about it on release.
                    .frame(
                        width: max(1, pane.frame.width + (resizeOffsets[pane.id]?.width ?? 0)),
                        height: max(1, pane.frame.height + (resizeOffsets[pane.id]?.height ?? 0)))
                    .offset(
                        x: drawOrigin(pane).x,
                        y: drawOrigin(pane).y)
                    // The focused pane draws in front. Floating panes hide
                    // behind each other by construction (`open` cascades
                    // each new one 28pt down and right), so without this a
                    // pane focused from the rail would stay buried and
                    // there would be no way to drag it at all.
                    .zIndex(model.layoutSnapshot.focusedId == pane.id ? 1 : 0)
                    // Clicking a pane focuses it — the canvas being the
                    // third way to reach one, alongside the rail and ⌘K —
                    // and not from a gesture here any more: the window's
                    // `PaneClickWatcher` sees every mouse-down, including
                    // the ones an AppKit control takes before a SwiftUI
                    // tap could (3b-v PR 8, `canvasMouseDown`).
                    .gesture(dragGesture(model, pane))
                    // Covers a drag interrupted from outside the gesture:
                    // an agent's `pane_close` over MCP, or a
                    // project switch, removes this row from `ForEach`
                    // mid-drag, and `onEnded` never fires for a view that
                    // is gone. Without this, `dragOffsets`/`resizeOffsets`
                    // leak an entry for a pane id nothing will ever clear
                    // again.
                    //
                    // `endDrag` only runs when *this* pane's own
                    // `dragOffsets` entry was live — i.e. this pane, not
                    // some other one, was mid-drag. `dragCandidate` is a
                    // single shared field with no id of its own
                    // (`SnapCandidate` names the snap target, `toPaneId`,
                    // never the pane being dragged), so calling it
                    // unconditionally from every disappearing row would
                    // erase a *different* pane's live snap-line preview —
                    // e.g. an agent closing pane A while the operator is
                    // mid-drag on pane B would blank B's snap rule for no
                    // reason connected to A at all.
                    .onDisappear {
                        let wasDragging = dragOffsets[pane.id] != nil
                        dragOffsets[pane.id] = nil
                        dragFrom[pane.id] = nil
                        resizeOffsets[pane.id] = nil
                        if wasDragging {
                            Task { await model.endDrag(id: pane.id) }
                        }
                    }
            }
            if let candidate = model.dragCandidate {
                snapLine(for: candidate)
            }
        }
        .frame(
            minWidth: 700, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity,
            alignment: .topLeading)
        .clipped()
        // The confirmation plane (Invariant 7's typed-confirmation
        // surface), overlaid above every pane rather than inline in one of
        // them: a mutation can be proposed while any pane — or none — has
        // focus, and the plane is Wakil's answer to "may this run", not a
        // property of whichever pane asked. Centred over a dimming
        // backdrop so the statement reads as the one thing the window is
        // asking about right now.
        .overlay {
            // The `ZStack` itself is unconditional so `.onChange` below
            // stays attached across a pending proposal's whole lifetime —
            // only its *content* is conditional. An `.onChange` nested
            // inside the `if let` would be torn down the moment `pending`
            // goes back to `nil` and would never see that very transition.
            ZStack {
                if let pending = model.pending {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    ConfirmationPlane(
                        pending: pending,
                        environment: model.environmentLabel,
                        siteWantsTyping: model.siteQuestionWantsTyping(pending),
                        typed: $typedConfirmation,
                        confirm: {
                            Task {
                                await model.confirmPending(typed: typedConfirmation)
                            }
                        },
                        allow: { Task { await model.allowPendingSite() } },
                        cancel: {
                            Task { await model.cancelPending() }
                        },
                        // The org plane draws above this one and claims
                        // Escape for itself whenever it is on screen —
                        // which is `showOrgPlane`, plus the org-less case
                        // `WakilWindow` force-opens it for (§8.5). The
                        // same predicate `WakilWindow` mounts it with,
                        // read from the same model, so the two cannot
                        // disagree about which plane the operator is
                        // looking at.
                        // Close Conversation's question draws above this plane and takes Esc
                        // while it is up (`CloseConversationPrompt`).
                        ownsEscape: !(model.showOrgPlane || model.organization.isEmpty
                            || model.closeQuestion != nil))
                }
                // 3b-i Task 9: a pane, an organisation switch or a quit about to drop unsaved
                // editor tabs. A single tab's prompt is the editor pane's own, over its strip.
                if let prompt = model.unsavedPrompt, !prompt.isCloseTab {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    UnsavedPromptBar(
                        message: prompt.canSave
                            ? "Unsaved changes in \(prompt.files.joined(separator: ", "))"
                            : "Unsaved changes Save cannot reach from here: \(prompt.files.joined(separator: ", "))",
                        canSave: prompt.canSave,
                        resolve: { choice in Task { await model.resolveUnsaved(choice) } })
                        .frame(maxWidth: 560)
                        .padding(16)
                }
            }
            // A previous proposal's half-typed word must never carry into
            // the next one — including a literal "confirm", which would
            // leave Run enabled on a proposal the operator has not read.
            //
            // Compares ids, not "did it become nil": `pending` moves
            // A -> nil -> B across two separate main-actor turns (the
            // pump's own `self.pending = nil` write, then its next
            // `self.pending = parked`), and if no render pass falls
            // between those two writes, SwiftUI's `.onChange` observes
            // A -> B directly with `newValue != nil` — so a predicate
            // that only fired on "became nil" would miss that transition
            // and let A's typed text survive into B's plane.
            .onChange(of: model.pending) { oldValue, newValue in
                if newValue?.id != oldValue?.id { typedConfirmation = "" }
            }
        }
    }

    /// The drag that moves a pane.
    ///
    /// **`onChanged` writes `@State` and asks a question; the only thing it
    /// dispatches is focus.** `previewDrag` is a read — it asks
    /// `LayoutStore` what a release here *would* snap to and stores the
    /// answer in `dragCandidate` for `snapLine` to draw. `onEnded` is the
    /// only side that dispatches an *arrangement*, and it dispatches once.
    /// Spec §4.1: the gesture is not the action; its commit is.
    ///
    /// **Focus is not taken here, though it moves first.** §4.1 governs
    /// arrangement — where a pane ends up — and focus is not that.
    /// Deferring it to `onEnded` would mean dragging an unfocused pane
    /// slides it *underneath* the focused one for the whole gesture,
    /// because `zIndex` above keys off `focusedId`; the pane you are
    /// actively moving would be the one you cannot see. The drag's own
    /// mouse-down already focused it (`canvasMouseDown`), before the first
    /// movement; asking again here could race that request and dispatch
    /// `pane_focus` twice for one press.
    private func dragGesture(_ model: WindowModel, _ pane: Pane) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragOffsets[pane.id] == nil {
                    dragFrom[pane.id] = pane.frame
                }
                dragOffsets[pane.id] = value.translation
                schedulePreview(
                    model, id: pane.id,
                    x: pane.frame.x + value.translation.width,
                    y: pane.frame.y + value.translation.height)
            }
            .onEnded { value in
                let x = pane.frame.x + value.translation.width
                let y = pane.frame.y + value.translation.height
                Task {
                    // The release position is previewed once more and the
                    // loop drained *before* the commit. `commitDrag` reads
                    // `dragCandidate` to decide between `pane_snap` and
                    // `pane_move`, so committing while a preview was still
                    // in flight would decide on the answer to a question
                    // about where the pointer was an event ago.
                    schedulePreview(model, id: pane.id, x: x, y: y)
                    await drainPreview()
                    await model.commitDrag(id: pane.id, x: x, y: y)
                    // Unconditional, and after the commit, because
                    // `commitDrag` clears `dragCandidate` only on the
                    // branch that snapped. Leaving it set would keep a
                    // rule drawn on the canvas for a drag that is over.
                    await model.endDrag(id: pane.id)
                    // Cleared *after* the commit, not before it. Clearing
                    // first would draw one frame with the pane back at its
                    // old origin — the store has not been told yet — and
                    // the pane would visibly jump back and then forward.
                    // Clearing late cannot overshoot: once the new frame is
                    // published, `drawOrigin` stops adding the offset (#353).
                    dragOffsets[pane.id] = nil
                    dragFrom[pane.id] = nil
                }
            }
    }

    /// Where a pane is drawn: its frame, moved by its live drag only while it
    /// still has the frame the drag started from (#353, `paneDrawOrigin`).
    private func drawOrigin(_ pane: Pane) -> (x: Double, y: Double) {
        paneDrawOrigin(
            frame: pane.frame, dragFrom: dragFrom[pane.id],
            translation: dragOffsets[pane.id].map { (Double($0.width), Double($0.height)) })
    }

    /// A mouse-down on the canvas — or on the settings pane over the Landing, whose size is
    /// `overLanding` — at `point` in that surface's points (`PaneClickWatcher`): the pane it
    /// lands in is focused (3b-v PR 8).
    ///
    /// Nothing is asked while a plane covers the canvas (the org plane, the palette, a
    /// confirmation, a window-wide unsaved prompt): the click is that plane's. The panes are
    /// hit where they are DRAWN, a live drag or resize included, top-most first (`paneAt`).
    func canvasMouseDown(_ model: WindowModel, at point: CGPoint, landsOnInput: Bool, overLanding: CGSize? = nil) {
        let windowPrompt = (model.unsavedPrompt.map { !$0.isCloseTab } ?? false) || model.closeQuestion != nil
        guard !(model.showOrgPlane || model.paletteShowing || model.pending != nil || windowPrompt) else { return }
        // The canvas and the Landing overlap only while one fades for the other; the live one answers.
        guard model.sessionStarted == (overLanding == nil) else { return }
        let snapshot = model.layoutSnapshot
        let drawn = snapshot.panes.map { pane -> Pane in
            var drawn = pane
            if let overLanding {
                drawn.frame = PaneFrame(x: 0, y: 0, width: overLanding.width, height: overLanding.height)
            } else {
                let origin = drawOrigin(pane)
                drawn.frame = PaneFrame(
                    x: origin.x, y: origin.y,
                    width: max(1, pane.frame.width + (resizeOffsets[pane.id]?.width ?? 0)),
                    height: max(1, pane.frame.height + (resizeOffsets[pane.id]?.height ?? 0)))
            }
            return drawn
        }
        // A click anywhere — the page, the address field, another pane — takes the keyboard from a
        // browser group header, so ⌘R reloads the page again. A click on the `pr` chip sets it back
        // on its mouse-up (`BrowserTabList`), after this.
        if model.browserHeaderFocus != nil { model.browserHeaderFocus = nil }
        let landed = paneAt(
            x: point.x, y: point.y, panes: drawn, focusedId: snapshot.focusedId, overLanding: overLanding != nil)
        guard let id = paneClickFocusTarget(target: landed, focusedId: snapshot.focusedId, landsOnInput: landsOnInput)
        else { return }
        Task { await model.paneClicked(id: id) }
    }

    /// Asks `LayoutStore` what a release at `(x, y)` would snap to, from
    /// **one** task rather than one per pointer-moved event.
    ///
    /// A `Task` per event is what the plan's reference code did, and it has
    /// two faults that compound. Ordering: nothing sequences four hundred
    /// unstructured tasks, so a preview for an earlier position can resolve
    /// after a later one and leave `dragCandidate` describing somewhere the
    /// pointer has already left — which `commitDrag` then reads. And volume:
    /// it enqueues an actor hop for every event whether or not the previous
    /// one has answered.
    ///
    /// This keeps at most one hop in flight and one position waiting. A
    /// position that arrives while the loop is busy replaces the waiting one
    /// instead of queueing behind it, which is right for a preview — the
    /// only interesting answer is the one for where the pointer is *now*,
    /// and intermediate frames are worth dropping rather than catching up on.
    private func schedulePreview(_ model: WindowModel, id: String, x: Double, y: Double) {
        pendingPreview = (id: id, x: x, y: y)
        guard previewTask == nil else { return }
        previewTask = Task {
            while let next = pendingPreview {
                pendingPreview = nil
                await model.previewDrag(id: next.id, x: next.x, y: next.y)
            }
            previewTask = nil
        }
    }

    /// Waits until no preview is in flight and none is waiting. The loop
    /// re-reads `previewTask` because draining is itself a suspension: a
    /// pointer event landing during the await starts another one.
    private func drainPreview() async {
        while let task = previewTask {
            await task.value
        }
    }

    /// One pane: its title, and what it is showing.
    ///
    /// **The frame numerals are gone.** They were on screen because in 2b-i
    /// they were the only evidence a drag or a resize committed at all — a
    /// pane had no contents of its own. It has contents now, and a pane
    /// that moves while showing rows is evidence enough.
    ///
    /// §2's slab treatment is unchanged: a near-opaque rounded surface, a
    /// half-pixel luminous edge in place of a border, and a drop shadow.
    /// §1's second register — the atmosphere stops at the slab's edge,
    /// never bleeding through — matters more now than it did, because a
    /// data surface with the void showing through it is unreadable at
    /// exactly the moment it matters (§8).
    // Not `private`: the settings pane is also drawn over the Landing,
    // from `WakilWindow`, where there is no canvas to put a pane on. Same
    // slab, same title bar, one definition — see `settingsPaneOverlay`.
    func paneView(_ model: WindowModel, _ pane: Pane) -> some View {
        // The compact chrome (2026-10-26): the editor's, the terminal's and the browser's content
        // runs edge to edge — no inset round it, the kind's own 32 pt header in place of the title,
        // and the resize handle over its corner rather than a row under it (`PaneKind.edgeToEdge`).
        let edgeToEdge = pane.edgeToEdge
        return VStack(alignment: .leading, spacing: edgeToEdge ? 0 : 8) {
            // An edge-to-edge kind draws its label itself, as the glyph at the left of its header.
            if !edgeToEdge { PaneTitle(title: pane.title) }

            // **The first `switch pane.kind` in the codebase.** Since 2b-i
            // every pane has drawn the same thing and `kind` has been read
            // in only three places, none of them a view. 2c-iii, 2c-iv and
            // 2c-v each add an arm here, beside the view that can draw
            // their kind — which is why `Pane.kinds` is a set a phase adds
            // to rather than an enum written ahead of its requirements.
            switch pane.kind {
            case "db":
                DBPane(
                    table: model.table(pane.id), pane: pane,
                    dispatch: { name, params in
                        Task { await model.dispatchFromSurface(name, params) }
                    },
                    isFocusedPane: model.layoutSnapshot.focusedId == pane.id,
                    keyboardFocusRequests: model.keyboardFocusRequests,
                    run: { text in
                        Task { await model.runFromQueryLine(text, pane: pane) }
                    },
                    refusal: model.queryLineRefusal(pane: pane.id),
                    databases: model.databases,
                    database: model.databaseForQueryLine(pane: pane),
                    choose: { model.chooseDatabase($0, pane: pane) },
                    restore: model.queryLineRestore(pane: pane.id),
                    // Per pane id, not per window — `DBPane`'s `refusal`
                    // doc comment records the walked failure a
                    // window-scoped value causes here.
                    editable: model.editable(paneId: pane.id),
                    editing: { rowKey, column, columnType, value in
                        await model.commitCellEdit(
                            pane: pane, rowKey: rowKey, column: column, columnType: columnType,
                            value: value)
                    },
                    dialect: model.queryDialect(pane: pane),
                    // 3b-viii: ghost-text on the window's quick tasks, one session per pane.
                    ghostTextEnabled: model.ghostTextEnabled,
                    ghostSchema: { await model.ghostSchema() },
                    ghostSuggest: { request, generation in
                        await model.ghostSuggestion(pane: pane.id, request: request, generation: generation)
                    },
                    ghostCancel: { model.ghostCancel(pane: pane.id) })
            case "terminal":
                TerminalPane(
                    snapshot: model.terminal(pane.id) ?? .empty,
                    pane: pane,
                    rootPath: model.rootPath,
                    send: { bytes in Task { await model.sendToTerminal(pane: pane.id, bytes: bytes) } },
                    accept: { Task { await model.acceptProposal(pane: pane.id) } },
                    discard: { Task { await model.discardProposal(pane: pane.id) } },
                    dispatch: { name, params in
                        // `pane` folded in here, once, rather than at every
                        // call site inside `TerminalPane`. Two actions
                        // reach this: `term_propose` (`Propose rerun`) and
                        // `term_scroll` with no `block`, which is how the
                        // pane clears a scroll target it has just honoured.
                        // Both always mean THIS pane.
                        var withPane: [String: JSONValue] = [:]
                        if case .object(let fields) = params { withPane = fields }
                        withPane["pane"] = .string(pane.id)
                        Task { await model.dispatchFromSurface(name, .object(withPane)) }
                    },
                    resize: { cols, rows in
                        Task { await model.resizeTerminal(pane: pane.id, cols: cols, rows: rows) }
                    },
                    openLink: { url, alt in WakilLinks.open(url, systemBrowser: alt, model: model) },
                    // `Send to thread` on a block: straight into the
                    // thought thread, the same entry point the operator's
                    // own compose field calls. It used to stop at the
                    // pasteboard — see `TerminalPane.sendToThread`.
                    sendToThread: { text in Task { await model.send(text) } },
                    refresh: { await model.refreshTerminal(pane: pane.id) },
                    // Walk defects A1/A2/A3: fed the same shape
                    // `ConfirmationPlane.ownsEscape` already is, a few
                    // lines below in this same file (`.overlay` on this
                    // canvas) — `model.showOrgPlane || model.organization
                    // .isEmpty` — widened to also cover `model.pending`,
                    // because a pending write confirmation is the OTHER
                    // same-window overlay this pane can sit beneath. All
                    // three are `WindowModel` state already; nothing new
                    // is introduced to track "is something covering the
                    // canvas" here.
                    isKeyboardOwner: !(
                        model.showOrgPlane || model.organization.isEmpty || model.pending != nil
                        || model.paletteShowing || model.unsavedPrompt != nil || model.closeQuestion != nil),
                    folderTag: { model.folderTag(for: $0) },
                    isFocusedPane: model.layoutSnapshot.focusedId == pane.id,
                    keyboardFocusRequests: model.keyboardFocusRequests,
                    keyboardReturns: model.keyboardReturns)
            case "api":
                // It takes `dispatch` now: the Send control presses the
                // same registry the agent speaks to, which is what makes
                // 2c-iv's exit criterion — "a request built in the window
                // and a request built by the agent are the same action" —
                // true rather than aspirational.
                ApiPane(
                    snapshot: model.api(pane.id) ?? .empty, pane: pane,
                    // 9a: one ordered chain for every call the pane makes.
                    // Each batch is built at its turn (Task 9 fix round 4).
                    dispatchInOrder: { build, settled in
                        model.enqueueFromSurface(pane: pane.id, building: build, settled: settled)
                    },
                    entries: (model.api(pane.id) ?? .empty).entries,
                    // Decision 27 by focus: marked off the chain (an unstructured `Task`, so
                    // just after this returns), and set again on the chain behind any flush
                    // queued before it (preflight F6).
                    noteFocus: { fields in model.focusFromSurface(pane: pane.id, fields: fields) },
                    releaseFocus: { model.releaseFocusFromSurface(pane: pane.id) },
                    // The drop's two halves: `api_bind` through the window's own dispatch,
                    // and the source grid's rows as drawn, for `apiDropRow` to compare the
                    // row picked up against.
                    bind: { source, row in
                        await model.bindFromSurface(pane: pane.id, source: source, row: row)
                    },
                    // 11a: the path's `curl …` paste, and the fill line's Undo — the same
                    // `api_fill_from_curl` / `api_undo_fill` an agent calls, on this pane's chain.
                    fillFromCurl: { text in
                        await model.fillFromCurlSurface(pane: pane.id, text: text)
                    },
                    undoFill: { await model.undoFillFromSurface(pane: pane.id) },
                    sourceRows: { source in model.table(source).rows },
                    // ⌘K's Send: the pane presses its own Send when this token changes.
                    sendRequest: model.apiSendRequest(pane: pane.id))
            case "editor":
                // 3b-i. Clicks are `editor_*` actions through the window's dispatch; typing and view
                // reports take the one non-action path (`editorBufferDidChange`).
                EditorPane(
                    snapshot: model.editor(pane.id) ?? .empty,
                    viewOptions: model.editorSettings.viewOptions,
                    showIgnored: model.editorSettings.app.showIgnored, pane: pane,
                    dispatch: { name, params in
                        var withPane = params
                        withPane["pane"] = .string(pane.id)
                        await model.dispatchFromSurface(name, .object(withPane))
                    },
                    dispatchThrowing: { name, params in
                        var withPane = params
                        withPane["pane"] = .string(pane.id)
                        try await model.dispatchFromSurfaceThrowing(name, .object(withPane))
                    },
                    bufferChanged: { subject, text, basis in
                        await model.editorBufferDidChange(pane: pane.id, subject: subject, text: text, basis: basis)
                    },
                    viewReported: { subject, cursor, sel, visible, top in
                        await model.editorViewDidReport(pane: pane.id, subject: subject, cursor: cursor, selection: sel,
                                                        visibleRange: visible, scrollTop: top)
                    },
                    saveAs: { path, replace in await model.saveScratch(pane: pane.id, as: path, replace: replace) },
                    cancelSaveAs: { model.cancelSaveAs() },
                    cancelSave: { model.cancelSave(pane: pane.id) },
                    diskText: { path in await model.editorDiskText(pane: pane.id, path: path) },
                    saveAsRequested: model.editorSaveAsRequest == pane.id,
                    firstRoot: model.gitRootPaths.first ?? "",
                    roots: model.gitRootPaths,
                    files: model.editorFiles,
                    gitRoots: model.gitRoots,
                    columnDefault: model.editorColumnDefault,
                    findReported: { report in await model.editorFindDidReport(pane: pane.id, report: report) },
                    columnFocusRequest: model.editorColumnFocusRequest.flatMap { $0.pane == pane.id ? $0 : nil },
                    columnFocusTaken: { model.editorColumnFocusTaken() },
                    revealInTree: { await model.revealActiveFileInTree(pane: pane.id) },
                    revealRequest: model.editorTreeRevealRequest.flatMap { $0.pane == pane.id ? $0 : nil },
                    revealTaken: { model.editorTreeRevealTaken() },
                    scope: "\(model.organization)\u{1F}\(model.project)\u{1F}\(model.lineageRoot ?? "")",
                    closeTab: { subject in await model.closeEditorTab(pane: pane.id, subject: subject) },
                    isFocusedPane: model.layoutSnapshot.focusedId == pane.id,
                    isKeyboardOwner: !(
                        model.showOrgPlane || model.organization.isEmpty || model.pending != nil
                        || model.paletteShowing || model.unsavedPrompt != nil || model.closeQuestion != nil),
                    keyboardHeld: { model.composerHoldsKeyboard },
                    unsavedPrompt: model.unsavedPrompt.flatMap { prompt in
                        if case .closeTab(pane.id, _) = prompt.intent { prompt } else { nil }
                    },
                    resolveUnsaved: { choice in Task { await model.resolveUnsaved(choice) } },
                    // 3b-viii: ghost-text on the window's quick tasks, one session per pane.
                    ghostTextEnabled: model.ghostTextEnabled,
                    // 3a-v-a: inline blame, the app-tier setting.
                    inlineBlame: model.editorSettings.app.inlineBlame,
                    blameFor: { root, path, text in await model.editorBlame(root: root, path: path, text: text) },
                    folderTag: { model.folderTag(for: $0) },
                    openCommitDiff: { root, ref in
                        Task { await model.editorOpenCommitDiff(root: root, path: ref.path, commit: ref.id, parentPath: ref.parentPath) }
                    },
                    openLink: { url, alt in WakilLinks.open(url, systemBrowser: alt, model: model) },
                    openProjectSettings: { Task { await model.openProjectSettings() } },
                    timeline: EditorTimelineControls(
                        load: { root, path, skip in await model.editorTimeline(root: root, path: path, skip: skip) },
                        openCommit: { root, ref in
                            Task { await model.editorOpenCommitDiff(root: root, path: ref.path, commit: ref.id, parentPath: ref.parentPath) }
                        }),
                    ghostSchema: { await model.ghostSchema() },
                    ghostSuggest: { request, generation in
                        await model.ghostSuggestion(pane: pane.id, request: request, generation: generation)
                    },
                    ghostCancel: { model.ghostCancel(pane: pane.id) },
                    // 3a-ii: the Changes view's writes, per root, from the window's one state.
                    changes: EditorChangesControls(
                        messages: model.changesMessages, errors: model.changesErrors,
                        inFlight: model.changesInFlight,
                        placeholders: Dictionary(model.gitRoots.map { r in
                            (r.root, model.changesPlaceholder(root: r.root))
                        }, uniquingKeysWith: { first, _ in first }),
                        edit: { root, text in model.changesMessageEdited(root: root, text: text) },
                        historyStep: { root, delta in
                            let before = model.changesMessages[root]
                            model.changesHistoryStep(root: root, by: delta)
                            return model.changesMessages[root] != before
                        },
                        // 3a-v-b: mid-merge or mid-rebase the commit button (and ⌘⏎) is Commit Merge /
                        // Continue Rebase, read from the root's state at the press; with conflicts left —
                        // a stash clash's included — it does nothing, as the disabled button says.
                        commit: { root in
                            let state = model.gitRoots.first(where: { $0.root == root })
                            if let state, changesConflictsReason(state) != nil { return }
                            if state?.state != nil {
                                _ = await model.changesContinue(root: root)
                            } else {
                                await model.changesCommit(root: root)
                            }
                        },
                        amend: { root in await model.changesAmend(root: root) },
                        undo: { root in await model.changesUndoCommit(root: root) },
                        stage: { root, paths, group in await model.changesStage(root: root, paths: paths, group: group) },
                        unstage: { root, paths, group in
                            await model.changesUnstage(root: root, paths: paths, group: group)
                        },
                        discard: { root, paths, group in
                            await model.changesDiscard(root: root, paths: paths, group: group)
                        },
                        cancel: { root in model.changesCancel(root: root) },
                        refreshIdentity: { root in await model.refreshChangesIdentity(root: root) },
                        drafting: model.changesDrafting, draftsOn: model.commitDraftsEnabled,
                        draft: { root in await model.changesDraft(root: root) },
                        cancelDraft: { root in model.changesCancelDraft(root: root) },
                        remote: { root, button in await model.changesRemote(root: root, button) },
                        fetch: { root in await model.changesFetch(root: root) },
                        notes: model.changesRemoteNotes,
                        branches: BranchPickerActions(
                            load: { await model.changesBranches(root: $0) },
                            switchTo: { root, branch, carry, track in
                                await model.changesSwitch(root: root, branch: branch, carry: carry, track: track)
                            },
                            create: { root, name, from in await model.changesBranchCreate(root: root, name: name, from: from) },
                            fetch: { await model.changesFetch(root: $0) },
                            delete: { root, branch, force in await model.changesBranchDelete(root: root, branch: branch, force: force) },
                            merge: { root, branch in await model.changesMerge(root: root, branch: branch) },
                            rebase: { root, onto in await model.changesRebase(root: root, onto: onto) }),
                        branchStash: BranchStashControls(
                            stashes: { await model.changesStashes(root: $0) },
                            stash: { root, message, mode in await model.changesStash(root: root, message: message, mode: mode) },
                            apply: { root, stash, pop in await model.changesStashApply(root: root, stash: stash, pop: pop) },
                            drop: { root, stash in await model.changesStashDrop(root: root, stash: stash) },
                            dropAll: { root, shown in await model.changesStashDropAll(root: root, stashes: shown) },
                            rename: { root, to in await model.changesBranchRename(root: root, to: to) },
                            create: { root, name in await model.changesBranchCreate(root: root, name: name) }),
                        conflicts: ChangesConflictControls(
                            clashes: model.changesClashes,
                            skip: { await model.changesSkip(root: $0) },
                            abort: { await model.changesAbort(root: $0) },
                            take: { root, path, take in await model.changesTake(root: root, path: path, take: take) },
                            keepFile: { root, path in await model.changesKeepFile(root: root, path: path) },
                            undoApply: { await model.changesStashUndoApply(root: $0) })),
                    stageHunk: { await model.changesStageHunk() },
                    stageRanges: { spans in await model.changesStageRanges(pane: pane.id, spans) },
                    unstageRanges: { spans in await model.changesUnstageRanges(pane: pane.id, spans) },
                    // Ticket view: the review boxes in the file.
                    // …and the threads a live hand-off is at work on: their boxes say Agent on it.
                    reviews: { var r = model.editorReviews; r.handed = ticketHandedThreads(model.ticketLiveHandOffs); return r }(),
                    dispatchReply: { name, params in
                        var withPane = params
                        withPane["pane"] = .string(pane.id)
                        return await model.dispatchFromSurfaceReply(name, .object(withPane))
                    },
                    // Ticket view: the column's Ticket view.
                    ticket: {
                        var t = model.editorTicket
                        t.handOffLive = model.ticketHandOffLive
                        t.liveHandOffs = model.ticketLiveHandOffs
                        return t
                    }(),
                    ticketCount: ticketNeedsCount(model.ticketNeedsInProject, roots: model.gitRoots),
                    ticketCountLabel: ticketNeedsLabel(model.ticketNeedsInProject, roots: model.gitRoots),
                    dispatchThrowingReply: { name, params in
                        var withPane = params
                        withPane["pane"] = .string(pane.id)
                        return try await model.dispatchFromSurfaceThrowing(name, .object(withPane))
                    })
            case "browser":
                // 3c-i. Every control is a `browser_*` action with this pane folded in; the web views
                // are the window's (`BrowserTabHost`), so a rebuild here never reloads a page.
                if let browserHost, let scope = model.browserScope {
                    BrowserPane(
                        snapshot: model.browser(pane.id) ?? .empty, pane: pane,
                        width: pane.frame.width + (resizeOffsets[pane.id]?.width ?? 0),
                        scope: scope, host: browserHost,
                        dispatch: { name, params in
                            var withPane = params
                            withPane["pane"] = .string(pane.id)
                            await model.dispatchFromSurface(name, .object(withPane))
                        },
                        dispatchAnswer: { name, params in
                            var withPane = params
                            withPane["pane"] = .string(pane.id)
                            return await model.dispatchFromSurfaceAnswer(name, .object(withPane))
                        },
                        isFocusedPane: model.layoutSnapshot.focusedId == pane.id,
                        isKeyboardOwner: !(
                            model.showOrgPlane || model.organization.isEmpty || model.pending != nil
                            || model.paletteShowing || model.unsavedPrompt != nil || model.closeQuestion != nil),
                        keyboardHeld: { model.composerHoldsKeyboard },
                        // The same three, read when asked: a deferred page focus acts on the
                        // window as it is then, not as this view was built (Rule 6).
                        mayTakeKeyboard: {
                            model.layoutSnapshot.focusedId == pane.id && !model.composerHoldsKeyboard
                                && !(model.showOrgPlane || model.organization.isEmpty || model.pending != nil
                                     || model.paletteShowing || model.unsavedPrompt != nil || model.closeQuestion != nil)
                        },
                        liveActiveTab: { model.browser(pane.id)?.active },
                        keyboardFocusRequests: model.keyboardFocusRequests,
                        keyboardReturns: model.keyboardReturns,
                        // Closed, not switched away from: the same canvas drawn, and the pane gone from it.
                        isClosed: {
                            model.drawnScope == scope && !model.layoutSnapshot.panes.contains { $0.id == pane.id }
                        },
                        // Another pane maximised in front of this one (3d-iii ruling 1).
                        isCovered: model.layoutSnapshot.maximizedId.map { $0 != pane.id } ?? false,
                        sites: model.browserSites,
                        agentAllowed: model.browserAllowedOnScreen,
                        revokeSite: { site in Task { await model.revokeBrowserSite(site) } },
                        bookmarks: model.browserBookmarksOnScreen,
                        suggestions: { typed, search in
                            await model.browserSuggestions(typed: typed, pane: pane.id, search: search)
                        },
                        engineSuggestions: { typed in await model.browserEngineSuggestions(typed: typed) },
                        chooseTab: { tab, url in await model.browserChooseTab(tab, url: url, from: pane.id) },
                        project: model.project,
                        closeArm: model.browserCloseArm,
                        copiedTip: model.browserCopiedTip,
                        pullRequests: model.browserPullRequestsOnScreen,
                        headerFocus: model.browserHeaderFocus?.pane == pane.id ? model.browserHeaderFocus?.group : nil,
                        setHeaderFocus: { group in
                            model.browserHeaderFocus = group.map { BrowserHeaderFocus(pane: pane.id, group: $0) }
                        },
                        refreshPullRequests: { Task { await model.refreshBrowserPullRequests() } },
                        openRenameTabPalette: { tab in model.openRenameTabPalette(pane: pane.id, tab: tab) },
                        placeNow: { model.browserScope },
                        verticalTabs: model.browserSettings.tabs == "vertical")
                    // **One view per place and pane.** Pane ids repeat from place to place, so
                    // without this a switch from A's `browser-1` to B's would keep the view: no
                    // appearance (no re-report of B's pages) and A's snapshot as B's `old`.
                    .id(BrowserTabHost.Key(scope: scope, pane: pane.id, tab: ""))
                }
            case Pane.settingsKind:
                // 2e (#198). The third arm, beside the view that can draw
                // its kind — the rule `Pane.kinds` has always stated.
                //
                // Everything it draws comes from `model.settings`, which
                // `refreshSettings` re-reads from disk on open and after
                // every dispatch. The pane holds no configuration of its
                // own, which is what makes staleness structurally
                // impossible rather than merely unlikely (Decision 30).
                SettingsPane(
                    tree: model.settings,
                    failure: model.settingsFailure,
                    reload: { Task { await model.refreshSettings() } },
                    saveOrganisationField: { field, value, organisation in
                        await model.saveOrganisationField(
                            field, to: value, organisation: organisation)
                    },
                    saveEditorSettings: { fields in await model.saveEditorSettings(fields) },
                    saveBrowserSettings: { fields in await model.saveBrowserSettings(fields) },
                    clearBrowserData: { org in await model.clearBrowserData(org: org) },
                    browserPullRequestsAbsent: model.browserPullRequestsAbsent,
                    keymap: model.keymap,
                    keymapError: model.keymapError,
                    setKey: { id, change in await model.setKey(id, change) },
                    setKeys: { overrides in await model.setKeys(overrides) },
                    recordingKey: { model.isRecordingKey = $0 },
                    saveProjectEditorSettings: { path, fields in
                        await model.saveProjectEditorSettings(projectPath: path, fields)
                    },
                    saveProjectAgentInstructions: { path, general, commits, pullRequests in
                        await model.saveProjectAgentInstructions(
                            projectPath: path, general: general, commits: commits, pullRequests: pullRequests)
                    },
                    saveProjectPMKey: { path, key in await model.saveProjectPMKey(projectPath: path, key) },
                    runningDispatch: { action, params in await model.runningDispatch(action, params) },
                    runningEnvironment: model.environment,
                    runningTryProgress: { project, repo in model.runningTryProgress(project: project, repo: repo) },
                    runningDrafting: { project in
                        RunningDrafting(
                            draft: { model.recipeDraft(projectPath: project.path, repo: $0) },
                            start: { repo, root, detected, kind in
                                await model.startRecipeDraft(project: project, repo: repo, root: root, detected: detected, kind: kind)
                            },
                            fix: { repo, root, recipe, report in
                                await model.proposeRecipeFix(project: project, repo: repo, root: root, recipe: recipe, report: report)
                            },
                            settle: { model.settleRecipeDraft(projectPath: project.path, repo: $0) },
                            stop: { await model.stopRecipeDraft(projectPath: project.path, repo: $0) })
                    },
                    saveProjectBranchInstructions: { path, branches in
                        await model.saveProjectAgentInstructions(projectPath: path, branches: branches)
                    },
                    saveLocalProvider: { id, label, url in
                        await model.setLocalProvider(id: id, label: label, baseURL: url)
                    },
                    saveOrganisationSwitch: { key, on in await model.saveOrganisationSwitch(key, on: on) },
                    removeLocalProvider: { id in await model.removeLocalProvider(id: id) },
                    git: GitAccountActions(
                        suggestions: { await model.gitHostSuggestions() },
                        sshKeys: { await model.gitSSHKeys() },
                        add: { host, provider, method, keyPath, username in
                            await model.addGitAccount(host: host, provider: provider, method: method, keyPath: keyPath, username: username)
                        },
                        remove: { host in await model.removeGitAccount(host: host) },
                        generateKey: { host, comment in await model.generateGitKey(host: host, comment: comment) },
                        setToken: { host, token in await model.setGitToken(host: host, token: token) },
                        setPassphrase: { host, pass in await model.setGitKeyPassphrase(host: host, passphrase: pass) },
                        test: { host in await model.testGitAccount(host: host) },
                        deviceStart: { provider in await model.gitDeviceStart(provider: provider) },
                        devicePoll: { provider, host, code, apiAccess in
                            await model.gitDevicePoll(provider: provider, host: host, deviceCode: code, apiAccess: apiAccess) },
                        setAPIToken: { host, token in await model.setGitAPIAccessToken(host: host, token: token) },
                        removeAPIAccess: { host in await model.removeGitAPIAccess(host: host) },
                        testAPIAccess: { host in await model.testGitAPIAccess(host: host) },
                        ghLogins: { await model.gitGhLogins() },
                        ghImport: { host, user in await model.gitGhImport(host: host, user: user) }),
                    connections: ConnectionActions(
                        catalog: { await model.connectionCatalog() },
                        add: { org, kind, name, transport, url, command, args in
                            await model.addConnection(org: org, kind: kind, name: name, transport: transport,
                                                      url: url, command: command, args: args)
                        },
                        update: { org, name, newName, url, command, args, values in
                            await model.updateConnection(org: org, name: name, newName: newName, url: url,
                                                         command: command, args: args, values: values)
                        },
                        remove: { org, name in await model.removeConnection(org: org, name: name) },
                        setSecrets: { org, name, values in await model.setConnectionSecrets(org: org, name: name, values: values) },
                        setAllow: { org, name, tool, allow in
                            await model.setConnectionAllow(org: org, name: name, tool: tool, allow: allow)
                        },
                        allowReadOnly: { org, name in await model.allowReadOnlyTools(org: org, name: name) },
                        check: { org, name in await model.checkConnection(org: org, name: name) },
                        signIn: { org, name in await model.signIn(org: org, name: name) },
                        signOut: { org, name in await model.signOut(org: org, name: name) },
                        account: { org, name in model.connectionAccounts["\(org)/\(name)"] },
                        setJiraToken: { org, email, token in await model.setJiraToken(org: org, email: email, token: token) }),
                    quickTaskStatus: { await model.quickTaskStatus() },
                    accounts: model.accounts,
                    capacity: model.capacity.readings,
                    adopt: { account in await model.adoptAccount(account) },
                    login: model.providerLogin,
                    offerLogin: { id, claudePath in
                        model.claudePathOverride = claudePath
                        await model.offerProviderLogin(
                            id: id, kind: "claude-code")
                    },
                    resolvedClaudePath: model.resolvedClaudePath(),
                    startLogin: { await model.startProviderLogin() },
                    cancelLogin: { await model.cancelProviderLogin() },
                    dismissLogin: { await model.dismissProviderLogin() },
                    reauthenticate: { account in await model.reauthenticateAccount(account) },
                    signInAsSomeoneElse: { await model.signInAsSomeoneElse() },
                    unlink: { account in await model.unlinkAccount(account) },
                    stopWaitingForMint: { await model.stopWaitingForMint() },
                    // 2e (#270). The running account, and the way to
                    // change it — `setProvider` is exactly what ⌘P calls.
                    runningAccountId: model.providerId,
                    use: { account in await model.setProvider(account.accountId) },
                    setDatabaseConnection: { path, environment, name, driver, connection, password,
                                             grant, writePassword in
                        await model.setDatabaseConnection(
                            projectPath: path, environment: environment, name: name,
                            driver: driver, connection: connection, password: password,
                            grantWrite: grant, writePassword: writePassword)
                    },
                    removeDatabase: { path, environment, name in
                        await model.removeDatabase(
                            projectPath: path, environment: environment, name: name)
                    },
                    // 2e-iii. Each passes the settings tree's own `project.path`, which the window
                    // compares verbatim to decide whether open API panes re-point on a rename.
                    updateDatabase: { path, environment, name, newName, revokeWrite in
                        await model.updateDatabase(
                            projectPath: path, environment: environment, name: name,
                            newName: newName, revokeWrite: revokeWrite)
                    },
                    setApiEntry: { path, environment, name, baseUrl, authHeader, token in
                        await model.setApiEntry(
                            projectPath: path, environment: environment, name: name,
                            baseUrl: baseUrl, authHeader: authHeader, token: token)
                    },
                    updateApiEntry: { path, environment, name, newName, baseUrl, authHeader, clearToken in
                        await model.updateApiEntry(
                            projectPath: path, environment: environment, name: name,
                            newName: newName, baseUrl: baseUrl, authHeader: authHeader,
                            clearToken: clearToken)
                    },
                    removeApiEntry: { path, environment, name in
                        await model.removeApiEntry(
                            projectPath: path, environment: environment, name: name)
                    },
                    createProject: { folder in await model.createProject(folder: folder) },
                    cloneProject: { link, folder in await model.cloneProject(link: link, into: folder) },
                    renameProject: { old, new in await model.renameProject(old, to: new) },
                    removeProject: { name in await model.removeProject(name) },
                    createEnvironment: { project, path in
                        await model.createEnvironment(project: project, projectPath: path)
                    },
                    renameEnvironment: { project, path, old, new in
                        await model.renameEnvironment(project: project, projectPath: path, old, to: new)
                    },
                    removeEnvironment: { project, path, name in
                        await model.removeEnvironment(project: project, projectPath: path, name)
                    },
                    showUnseenRefusal: { text in model.showUnseenRefusal(text) },
                    selection: $settingsSelection,
                    expansion: $settingsExpansion,
                    activeProject: model.project,
                    activeEnvironment: model.environment)
            default:
                // Unreachable today: `Pane.kinds` is
                // `["db", "terminal", "api", "settings", "editor", "browser"]`, all six arms
                // above are drawn, and `pane_open` and
                // `layoutDroppingUnknownPaneKinds` check against the same
                // set. Here so that adding a kind to that set without
                // adding an arm here shows on screen instead of crashing.
                Text("no view for a \(pane.kind) pane")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30))
            }

            if !edgeToEdge {
                HStack {
                    Spacer()
                    Text("resize")
                        .gesture(resizeGesture(model, pane))
                }
            }
        }
        .padding(.all, edgeToEdge ? 0 : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(EdgeToEdgePane(on: edgeToEdge, resize: resizeGesture(model, pane)))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                // Near-opaque, never translucent. §1's second register: the
                // atmosphere stops at the slab's edge, and a data surface with
                // the void showing through it is unreadable at exactly the
                // moment it matters.
                .fill(Color(red: 0.055, green: 0.063, blue: 0.098))
        )
        .overlay(
            // The half-pixel luminous edge §2 asks for, in place of a
            // border. Brighter at the top, where a light from above would
            // catch it.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
    }

    /// The drag that resizes a pane, from a handle in its bottom-right
    /// corner. Same rule as `dragGesture`: `@State` while the pointer
    /// moves, one dispatch on release.
    ///
    /// **The clamp on the *named* pane is the view's, not the store's.**
    /// `LayoutStore.resize` takes whatever it is given for the pane the
    /// caller named, because a `--dispatch` script is entitled to state
    /// any rectangle; what a *pointer* must not be able to do is drag a
    /// pane to a negative size and leave it unclickable. (A snapped
    /// *neighbour* dragged along by this pane's border is a different
    /// story — nobody asked for it to shrink at all, so `LayoutStore`
    /// floors that one itself; see its doc comment.) `Pane.minimumWidth`
    /// / `minimumHeight` are the same floors used there, so the two
    /// clamps cannot drift apart.
    private func resizeGesture(_ model: WindowModel, _ pane: Pane) -> some Gesture {
        // **Global, not local.** The handle is laid out at the pane's
        // bottom-right, and the pane's `.frame` grows as this gesture
        // reports — so in the default `.local` space the handle is being
        // moved out from under the pointer by its own effect, the
        // reference frame shifts every layout pass, and `translation`
        // jitters instead of tracking. The pane *drag* has no such problem
        // because `.offset` is a render transform and leaves layout
        // geometry alone; `.frame` does not.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                resizeOffsets[pane.id] = value.translation
            }
            .onEnded { value in
                Task {
                    await model.commitResize(
                        id: pane.id,
                        width: max(Pane.minimumWidth, pane.frame.width + value.translation.width),
                        height: max(Pane.minimumHeight, pane.frame.height + value.translation.height))
                    resizeOffsets[pane.id] = nil
                }
            }
    }

    /// A one-point rule along the edge the release would snap to.
    /// `candidate.frame` is the rectangle the pane would take, so the line
    /// sits on whichever of its edges `candidate.edge` names.
    ///
    /// A `left` or `right` edge draws a *vertical* rule — `SnapEdge
    /// .isHorizontal` is true of the edges that move along the x axis, not
    /// of the lines they draw.
    private func snapLine(for candidate: SnapCandidate) -> some View {
        let frame = candidate.frame
        let isVerticalRule = candidate.edge.isHorizontal
        return Rectangle()
            .frame(
                width: isVerticalRule ? 1 : frame.width,
                height: isVerticalRule ? frame.height : 1)
            .offset(
                x: candidate.edge == .right ? frame.maxX : frame.minX,
                y: candidate.edge == .bottom ? frame.maxY : frame.minY)
    }
}

private extension UnsavedPrompt {
    /// One tab's prompt, which its editor pane draws over its own strip.
    var isCloseTab: Bool {
        if case .closeTab = intent { true } else { false }
    }
}

/// A pane whose content meets its border (the editor's, the terminal's, the browser's): the content
/// clipped to the slab's corners, the border token's 1 px edge over it so the pane's outline holds
/// against any page, and the resize handle on a chip in the bottom-right corner, over the content.
private struct EdgeToEdgePane<Resize: Gesture>: ViewModifier {
    let on: Bool
    let resize: Resize

    func body(content: Content) -> some View {
        if on {
            content
                .clipShape(RoundedRectangle(cornerRadius: PaneStripStyle.paneRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PaneStripStyle.paneRadius, style: .continuous)
                        .strokeBorder(PaneStripStyle.text.opacity(PaneStripStyle.edge), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("resize")
                        .font(.system(size: SettingsScale.micro))
                        .foregroundStyle(PaneStripStyle.text.opacity(RailTreatment.kindOpacity))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(PaneStripStyle.slab.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .gesture(resize)
                }
        } else {
            content
        }
    }
}

/// A pane's title as the canvas draws it over every inset slab: §6's micro-label, uppercase-tracked
/// 9 pt. An edge-to-edge pane names itself with its glyph instead; the terminal's header keeps
/// this label beside it.
struct PaneTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.7)
            .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
    }
}
