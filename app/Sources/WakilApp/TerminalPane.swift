import AppKit
import WakilKit
import SwiftUI

/// A terminal pane: a real shell's block history with the live screen
/// drawn beneath it, that same screen taken full-pane when a full-screen
/// program claims it, the agent's own proposal waiting on the operator's
/// `⏎`, and a recessed mirror of the commands the agent ran in its own
/// bare-environment shell.
///
/// **Both surfaces are always live, and the pane draws both** — the block
/// history is everything that has finished, the live region is the prompt
/// being typed at and the command still running. `snapshot.screen` says
/// which one is *authoritative*: on `.grid` a program owns the screen and
/// the history is parked into a strip above it; on `.blocks` the history
/// is the pane and the live screen is the few rows at its foot.
///
/// **Every measurement below is the probe's, not a guess** — see
/// `docs/wakil/phase-2c-iii-probe.md` and this file's own doc comments at
/// each construction. **Every calculation is `WakilKit`'s** —
/// `TerminalPaneSupport.swift` — for the same reason `DBPane`'s
/// column-width arithmetic lives in `Panes/PaneTable.swift`: this target has
/// no test target and cannot have one, so nothing worth asserting is
/// decided here. What remains here is drawing, `GeometryReader`
/// measurement, `NSEvent`/`KeyPress` bridging and pasteboard calls — the
/// AppKit-touching half `Pane.swift`'s own doc comment says belongs at
/// the view layer, not one target down.
///
/// That sentence was aspirational until the two-axis review (Standards 2):
/// this file still decided a block's status glyph in three separate
/// copies, its plain-text rendering, a group's backfill label and the
/// parked strip's own length. All four moved down to
/// `TerminalPaneSupport.swift` and are asserted in
/// `TerminalPaneSupportTests.swift`; what is left here maps a computed
/// value to a `Color`, a `Text` or a frame, and nothing else.
struct TerminalPane: View {
    let snapshot: TerminalSnapshot
    let pane: Pane
    /// The window's own project root, read once per draw —
    /// `WindowModel.rootPath`. The mirror's provenance line names it: a
    /// mirrored block ran in Wakil's OWN shell, never this pane's pty, and
    /// the block itself deliberately carries no cwd of its own (see
    /// `TerminalMirror.swift`'s ruling 2) — this is the one place that
    /// fact is read from.
    let rootPath: String
    /// Every keystroke, straight to the pty — `WindowModel.sendToTerminal`.
    let send: ([UInt8]) -> Void
    /// The operator's `⏎` on the proposal — `WindowModel.acceptProposal`.
    let accept: () -> Void
    /// `⌫` on the proposal — `WindowModel.discardProposal`.
    let discard: () -> Void
    /// `term_propose` for `Propose rerun`, and the row action a table pane
    /// dispatches through the same seam — `WindowModel.dispatchFromSurface`.
    let dispatch: (String, JSONValue) -> Void
    /// A pane resize, in cells — `WindowModel.resizeTerminal`. The
    /// arithmetic that turns a measured pixel size into cols/rows is
    /// `terminalGridSize` (`WakilKit`); this view only measures and calls.
    let resize: (Int, Int) -> Void
    /// Opens a URL the operator ⌘-clicked in the pane's output: `(url, systemBrowser)`, where
    /// `systemBrowser` is ⌥ held too — `WakilLinks.open`, the closure the editor gets (3c-iii
    /// ruling 14).
    let openLink: (String, Bool) -> Void
    /// `Send to thread` on a block — `WindowModel.send`, the thought
    /// thread's own entry point, the same one the operator's compose field
    /// calls.
    ///
    /// **It reaches the thread now, and until the two-axis review it did
    /// not** (Spec 4). This action wrote a fenced quote to the PASTEBOARD,
    /// on the stated grounds that "`WindowModel` publishes no such hook" —
    /// which was false: `send(_:)` is public and is exactly that hook.
    /// Story 14 asks for *"Copy, Rerun and Send to thread on a block"*, and
    /// a Send that lands on the pasteboard beside Copy is Copy twice. The
    /// fenced formatting is kept (`terminalBlockQuote`); only the
    /// destination changed.
    let sendToThread: (String) -> Void
    /// One poll of the engine's dirty range — `WindowModel.refreshTerminal`.
    /// Driven from `.task` below at the display's frame rate, never from
    /// the feed: SwiftTerm has no content-change callback at all, so
    /// polling IS the coalescing (probe §4.2).
    let refresh: () async -> Void
    /// Whether nothing else in this window is presented over the canvas
    /// right now — fed from `Canvas.swift`, the same boolean shape
    /// `ConfirmationPlane.ownsEscape` is already fed from there
    /// (`model.showOrgPlane || model.organization.isEmpty`), widened to
    /// also cover `model.pending` and `model.paletteShowing`: the org plane,
    /// a pending write confirmation and the palette are the same-window
    /// overlays this pane can be drawn beneath, and all are `WindowModel`
    /// state already, not a second notion of "something is covering the
    /// canvas" invented here.
    ///
    /// **This is what `handleKeyPress` consults before anything else** —
    /// see its own doc comment and `terminalPaneKeyClaim`
    /// (`TerminalPaneSupport.swift`), the root fix for walk defects
    /// A1/A2/A3. Only a same-window overlay (a `ZStack` sibling that never
    /// takes the key window away) needs this kind of explicit arbitration,
    /// which is exactly what `OrgPlane`, `ConfirmationPlane` and the palette's
    /// plane are; a separate AppKit window would take first responder on its
    /// own.
    let isKeyboardOwner: Bool

    /// Whether the window says THIS pane is the focused one.
    ///
    /// **First responder has to follow it, or "focused" means two things.**
    /// The rail, `⌘K`, a canvas click and the agent's `pane_focus` all move
    /// `layoutSnapshot.focusedId`, and until 2026-09-24 nothing here watched
    /// it: the pane drew as focused, `read_layout` reported it focused, and
    /// the keystrokes went wherever first responder happened to be — the
    /// agent composer, most often, because typing to the agent is what takes
    /// it away. Watching this covers only the requests that MOVE focus;
    /// `keyboardFocusRequests` below is what covers the rest, and all four
    /// callers raise that one. That is the same split this view already refuses one level
    /// down, where closing search restores `focused` so the pane cannot look
    /// focused "while first responder is actually still the search field".
    ///
    /// Found by the e2e harness: after asking the agent to propose a command,
    /// no check could get the keyboard back to the pane to accept it, which
    /// is exactly what an operator doing the same thing would hit.
    let isFocusedPane: Bool

    /// `WindowModel.keyboardFocusRequests` — raised by every request for a
    /// pane to be focused, including the ones naming the pane that is already
    /// focused: the rail, `⌘K`, a canvas click, and the agent's own
    /// `pane_focus`. All four are counted in `LayoutStore`, which is the one
    /// place they meet.
    ///
    /// **`isFocusedPane` alone cannot carry this, and #284 is the proof.**
    /// It is state, so `onChange` on it fires only when focus *moves* — and
    /// the way the keyboard is usually lost does not move it: typing to the
    /// agent takes first responder to the composer while `focusedId` stays
    /// here. The rail click meant to bring it back was then a change of
    /// nothing, this pane never re-took first responder, and `⏎` on a
    /// pending proposal went to the composer for ever.
    let keyboardFocusRequests: Int

    /// `WindowModel.keyboardReturns` — raised when the palette closes over this pane with
    /// nothing run (Esc, a dimmer click). The pane holds the keyboard through `focused`, not
    /// through an `NSView`, so AppKit's first responder captured at the palette's open is only
    /// the hosting view and handing it back focuses nothing (spec 46); this is the pane's way
    /// back. Answered the same way as a focus request: by the focused pane, and no other.
    let keyboardReturns: Int

    /// 60 Hz — the same interval `TerminalStore.startPublishing()` polls
    /// the engine's own dirty range at. Polling faster would not see
    /// anything sooner, since nothing is published between the engine's
    /// own passes; polling slower would miss the frame budget the probe
    /// measured against.
    private static let pollIntervalNanoseconds: UInt64 = 16_666_666

    /// The pane's own selection over the live region (#365) — SwiftUI's
    /// `.textSelection` cannot be read back, so a selection the shell must
    /// act on has to be the pane's.
    @State private var selection: TerminalGridRange?
    @State private var searchOpen = false
    @State private var searchQuery = ""
    @State private var expandedGroups: Set<String> = []
    @State private var now = Date()
    /// The measured height of `parkedHistoryStrip`, or `0` when it is not
    /// drawn. Subtracted before the pty is told how many rows it has —
    /// see `reportSize`.
    @State private var parkedStripHeight: CGFloat = 0
    /// The measured width of the live region's own leading gutter — the
    /// `▸` marker and the `HStack` spacing ahead of its text — reported up
    /// by `BlockHistory.liveRegion()`, or `0` before that view has laid
    /// out once (`.blocks` never drawn yet, or a pane too new to have
    /// measured anything). Subtracted before the pty is told how many
    /// columns it has, on the blocks surface only — see `reportSize`.
    @State private var liveRegionGutterWidth: CGFloat = 0
    @FocusState private var focused: Bool
    /// The ⌘F field holds the keyboard. A click on it in a pane that was not focused makes it
    /// first responder before `pane_focus` lands (3b-v PR 8), and the pane must not then take
    /// the keyboard back for the shell.
    @FocusState private var searchFocused: Bool

    var body: some View {
        // The compact chrome (2026-10-26): one 32 pt header row and a hairline, ⌘F's row under it
        // while it is open, then the shell's surface to the pane's border with a 6 pt gutter inside
        // it, so its text never meets the border (the canvas pads no terminal pane).
        VStack(alignment: .leading, spacing: 0) {
            header()
            PaneHairline()
            if searchOpen {
                searchBar()
                    .padding(.horizontal, PaneStripStyle.rowInset)
                    .frame(height: PaneStripStyle.rowHeight)
                PaneHairline()
            }
            content()
                .padding([.horizontal, .top], PaneStripStyle.gutter)
            footer()
        }
        .focusable()
        .focused($focused)
        // Walk defect C1: `.focusable()` + `.focused($focused)` alone
        // leaves AppKit drawing its own system focus ring in the
        // operator's accent colour — green, on the walk's machine — which
        // is a third hue in a pane whose one rule (`design-language.md`
        // §5) is that light here means exactly one thing: a block awaiting
        // `⏎`, in violet. `.focusEffectDisabled()` (macOS 14+) removes
        // only the ring; the pane still keeps and needs real first
        // responder for `handleKeyPress` below to run at all. Deliberately
        // NOT replaced with a substitute indicator of our own — a second
        // ring in a different colour would still be the third hue the
        // design refuses, just a quieter one.
        .focusEffectDisabled()
        // A link in the output (3c-iii ruling 14) opens only on ⌘-click. A plain click is
        // discarded, so it selects text as it always has.
        .environment(\.openURL, openLinkAction)
        .onAppear { focused = true }
        .onChange(of: isFocusedPane) { _, nowFocused in
            // Only ever takes focus, never gives it up: a pane that lost
            // `focusedId` has no business deciding who gets first responder
            // next, and the pane that gained it is about to ask for it.
            if nowFocused, !searchFocused { focused = true }
        }
        // The other half, for the case the line above structurally cannot
        // see: a focus request that changed no state because this pane was
        // already the focused one. `keyboardFocusRequests` is raised after
        // the dispatch that sets `focusedId`, so by the time this runs
        // `isFocusedPane` is current and the guard is the same one — the
        // request is answered by the pane it named, and by no other.
        .onChange(of: keyboardFocusRequests) { _, _ in
            if isFocusedPane { focused = true }
        }
        .onChange(of: keyboardReturns) { _, _ in
            if isFocusedPane { focused = true }
        }
        .onKeyPress(phases: .down, action: handleKeyPress)
        // New output that moves the prompt makes the selection's cells stale.
        // `promptRow` alone misses a full screen, where every new prompt
        // lands on the same row; any change to the input line does not.
        .onChange(of: snapshot.promptRow) { _, _ in selection = nil }
        .onChange(of: snapshot.inputLine) { _, _ in selection = nil }
        // Ticks the elapsed counter on a running mirrored block. A plain
        // `Timer`/`Task` loop rather than `TimelineView`: this pane
        // already runs one polling loop below, and a second, independent
        // per-frame driver for one small piece of text is the kind of
        // thing that is easy to lose track of. One second is plenty for
        // a counter nobody reads to the millisecond.
        .task(id: pane.id) {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // The redraw poll itself — see `refresh`'s own doc comment.
        // Cancelled automatically when this pane closes, because `.task`
        // ties the loop's lifetime to the view's.
        .task(id: pane.id) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    // MARK: - Header

    /// The live cwd, the shell, and the dimensions a program in this pane
    /// believes its screen is — nothing about project roots (Invariant 8
    /// is the environment banner's job, not this line's). `cwd` and
    /// `shell` are already plain values by the time they reach here:
    /// `TerminalSession.hostCurrentDirectoryUpdated` parses OSC 7's own
    /// `file://localhost/…` URL into a path before it is ever stored, so
    /// nothing here re-parses one.
    @ViewBuilder
    private func header() -> some View {
        // The terminal glyph in the label's place, the pane's own title beside it — a terminal pane
        // is named for where it opened — then the live line and the controls, all in one row.
        PaneStripRow(glyph: "terminal", name: "Terminal") {
            HStack(spacing: 8) {
                PaneTitle(title: pane.title)
                    .lineLimit(1)
                    .fixedSize()
                headerLine()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pane.\(pane.id).header")
        }
    }

    @ViewBuilder
    private func headerLine() -> some View {
        HStack(spacing: 8) {
            Text(headerCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Self.text.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.head)
            Text("·")
                .foregroundStyle(Self.text.opacity(0.25))
            // One line each, so a narrow pane truncates the row rather than stacking it.
            Text(headerShell)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Self.text.opacity(0.45))
                .lineLimit(1)
            Text("·")
                .foregroundStyle(Self.text.opacity(0.25))
            Text("\(snapshot.cols)×\(snapshot.rows)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Self.text.opacity(0.45))
                .lineLimit(1)
                .fixedSize()
            // Walk-defects B2: a pane restored after `clearForOrgSwitch`
            // comes back with `snapshot.shell.isEmpty` — the operator's
            // "dead pane" — and nothing before this let them start a new
            // shell without the agent. **Gated on `shell.isEmpty` alone,
            // never on the live region below being empty** — that other
            // empty state (`liveRegion()`'s "waiting for the shell",
            // `:717`) is a pane with a real shell that has not drawn its
            // first prompt yet, and must not grow this button.
            if snapshot.shell.isEmpty {
                Button("Reopen") {
                    // The same action the agent and "Open terminal" use —
                    // `terminalReopenParams` is `WakilKit`'s, not a second
                    // code path invented here. `dispatch` folds in `pane`
                    // itself (`Canvas.swift`), so this call names only
                    // what makes THIS reopen different from a bare
                    // `term_open`: the path this pane remembers.
                    dispatch("term_open", terminalReopenParams(path: pane.terminalPath))
                }
                .accessibilityIdentifier("pane.\(pane.id).reopen")
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Self.text.opacity(0.65))
            }
            Spacer()
            Button {
                // The pointer path to the same toggle `⌘F` and
                // `terminalPaneKeyClaim`'s `.toggleSearch` drive — closing
                // returns focus to the terminal exactly as the keyboard
                // path does, so a search closed by mouse does not leave
                // the pane looking focused while first responder is
                // actually still the search field.
                searchOpen.toggle()
                if !searchOpen {
                    searchQuery = ""
                    focused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Self.text.opacity(searchOpen ? 0.85 : 0.45))
                    .frame(width: PaneStripStyle.glyphBox, height: PaneStripStyle.glyphBox)
                    .contentShape(Rectangle())
            }
            // The glyph is the whole control, so without a spoken name this
            // button is unreachable by VoiceOver as well as by a check.
            .accessibilityLabel("Search this pane")
            .accessibilityIdentifier("pane.\(pane.id).searchToggle")
            .buttonStyle(.plain)
        }
    }

    private var headerCwd: String { snapshot.cwd.isEmpty ? "…" : snapshot.cwd }
    private var headerShell: String {
        snapshot.shell.isEmpty ? "no shell" : (snapshot.shell as NSString).lastPathComponent
    }

    // MARK: - ⌘F, in the pane

    /// **In the pane, not floating over it** — a plain row like the query
    /// line's, not a system find-bar. Counts in BLOCKS: "which command",
    /// never "which line".
    @ViewBuilder
    private func searchBar() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Self.text.opacity(0.35))
            TextField("search commands and output", text: $searchQuery)
                .accessibilityIdentifier("pane.\(pane.id).searchQuery")
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Self.text.opacity(0.85))
            let summary = terminalSearchSummary(
                totalBlocks: snapshot.blocks.count, matchingBlocks: matchingIds.count,
                hasQuery: !searchQuery.isEmpty)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Self.text.opacity(0.40))
            }
        }
    }

    private var matchingIds: Set<String> {
        matchingTerminalBlockIds(snapshot.blocks, query: searchQuery)
    }

    /// What a click on a link in the pane's output does: nothing without ⌘ (`.discarded`), else
    /// `openLink`, with ⌥ sending it to the system browser. The modifiers are the click's own,
    /// read from the event SwiftUI is handling as it calls this.
    private var openLinkAction: OpenURLAction {
        let openLink = openLink
        return OpenURLAction { url in
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            guard flags.contains(.command) else { return .discarded }
            openLink(url.absoluteString, flags.contains(.option))
            return .handled
        }
    }

    // MARK: - Content: the live grid, or the block history

    @ViewBuilder
    private func content() -> some View {
        GeometryReader { proxy in
            Group {
                if snapshot.screen == .grid {
                    VStack(alignment: .leading, spacing: 0) {
                        parkedHistoryStrip()
                            .background(
                                GeometryReader { strip in
                                    Color.clear.preference(
                                        key: ParkedStripHeightKey.self, value: strip.size.height)
                                })
                        LiveGrid(rows: gridRows)
                    }
                } else {
                    BlockHistory(
                        paneId: pane.id,
                        items: groupedTerminalHistory(snapshot.blocks), cwd: snapshot.cwd,
                        rootPath: rootPath, backfilledAt: snapshot.backfilledAt,
                        // The live screen, drawn beneath the history — see
                        // `liveRegionRows` and `terminalLiveRegion`.
                        liveRows: liveRegionRows,
                        // The cursor overlay's position, or `nil` to draw
                        // none — see `liveRegionCursor`'s own doc comment
                        // (walk defect D3, seam left for `TerminalSession`).
                        cursor: liveRegionCursor,
                        liveStartRow: liveRegionSlice.startRow,
                        inputLine: snapshot.inputLine,
                        selection: $selection,
                        scrollTarget: snapshot.scrollTarget,
                        clearScrollTarget: clearScrollTarget,
                        expandedGroups: $expandedGroups, visibleIds: visibleIdsForSearch, now: now,
                        send: sendAndFocus, accept: accept, discard: discard, dispatch: dispatch,
                        copy: copyBlock, sendToThread: sendBlockToThread)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pane.\(pane.id).screen")
            .onPreferenceChange(ParkedStripHeightKey.self) { height in
                parkedStripHeight = height
            }
            .onPreferenceChange(LiveRegionGutterWidthKey.self) { width in
                liveRegionGutterWidth = width
            }
            .onAppear { reportSize(proxy.size) }
            .onChange(of: proxy.size) { _, newSize in reportSize(newSize) }
            // The strip appears and disappears with the blocks behind it,
            // and every change moves the grid's ceiling.
            .onChange(of: parkedStripHeight) { _, _ in reportSize(proxy.size) }
            // The gutter is `0` until `BlockHistory.liveRegion()` has laid
            // out once, so the very first `reportSize` on a fresh blocks
            // pane runs with no subtraction — harmless, because the
            // resulting size only ever OVERSHOOTS by a gutter's width
            // (single digits of columns) for one frame, and this fires
            // the moment the real measurement arrives to correct it.
            .onChange(of: liveRegionGutterWidth) { _, _ in reportSize(proxy.size) }
            .onChange(of: snapshot.screen) { _, _ in reportSize(proxy.size) }
            // **A second shell in the same pane, otherwise stuck at the
            // pty's default 80×24.** `reportSize` now compares its own
            // computed size against the snapshot's own truth
            // (`snapshot.cols`/`rows`), not a `@State` cache of what this
            // view last sent — see `reportSize`'s own doc comment for why
            // the cache was the defect. But nothing in this view's own
            // geometry changes when a NEW session starts inside an
            // EXISTING pane (Reopen, or a second `term_open`): `proxy.size`
            // is the same, `parkedStripHeight` is the same, and `screen`
            // is usually still `.blocks`. The one thing that DOES change
            // is the truth itself — the fresh session's own 80×24 — so
            // that is what has to be watched.
            .onChange(of: snapshot.cols) { _, _ in reportSize(proxy.size) }
            .onChange(of: snapshot.rows) { _, _ in reportSize(proxy.size) }
        }
    }

    /// `nil` (every block visible) when the operator has not searched;
    /// otherwise the ids `matchingTerminalBlockIds` found, applied
    /// uniformly to every block including a pending proposal — clearing
    /// the search is what brings it back, and a search result that hid
    /// the very thing waiting on the operator's `⏎` without saying so
    /// would be worse than hiding it consistently with everything else.
    private var visibleIdsForSearch: Set<String>? {
        searchQuery.isEmpty ? nil : matchingIds
    }

    private var gridRows: [[TerminalStyleRun]] { snapshot.gridStyles }

    /// The live screen's own rows, trimmed to what is worth drawing under
    /// the block history — the prompt the operator is typing at, and a
    /// running command's output before it seals into a block. The trim is
    /// `WakilKit`'s (`terminalLiveRegionSlice`), for this file's standing
    /// reason: nothing worth asserting is decided in a target with no test
    /// target.
    ///
    /// **Sliced from `snapshot.gridStyles`, not `snapshot.grid`.** Before
    /// this, only the plain grid was ever sliced here, so the live region
    /// — the surface a full-screen-free TUI (Claude Code among them)
    /// draws its whole interface on while the pane stays on `.blocks` —
    /// discarded every colour it emitted, in flat white. `gridStyles` is
    /// guaranteed the same length as `grid` and never `nil`
    /// (`TerminalSnapshot.gridStyles`'s own doc comment), so slicing it
    /// instead loses nothing; `BlockHistory` draws the styled rows
    /// directly, and there is no separate plain-text slice to keep in
    /// step with it — `terminalLiveRegionSlice(gridStyles:)` is the one
    /// trim both would otherwise have needed.
    ///
    /// **Walk defect C2, and the seam that had to be joined by hand.**
    /// `terminalLiveRegionSlice` slices from the row the current prompt
    /// started on instead of taking the tail of the whole screen — the
    /// fix for "each command drawn twice, once as a block and once raw
    /// underneath". The two halves were written by different agents:
    /// `TerminalSession` scans the OSC 133 `promptStart` mark and
    /// publishes `promptRow`, and `terminalLiveRegionSlice` consumes it.
    /// Both landed; this line, which is the join, did not, and the defect
    /// reproduced verbatim on the next walk against a build where every
    /// test passed. If a seam is ever split across two changes again, the
    /// join belongs in whichever change lands second, not in a `TODO`.
    ///
    /// **`isCommandRunning: snapshot.commandRunning`** (live-region-
    /// running fix). The live region means two different things and this
    /// is the one line that tells `terminalLiveRegionSlice` which: idle,
    /// it is the prompt sliced from `promptRow`, capped at `maxRows` —
    /// unchanged. Running, it is the screen itself, uncapped — what a
    /// program like `claude` draws its whole interface on without ever
    /// touching the alternate screen, and what an 8-row `promptRow`-tail
    /// used to reduce to one line that kept getting overwritten.
    private var liveRegionSlice: (rows: [[TerminalStyleRun]], startRow: Int) {
        terminalLiveRegionSlice(
            gridStyles: snapshot.gridStyles, promptRow: snapshot.promptRow,
            isCommandRunning: snapshot.commandRunning)
    }

    /// The rows of `liveRegionSlice` — see its doc comment.
    private var liveRegionRows: [[TerminalStyleRun]] { liveRegionSlice.rows }

    /// Where to draw the cursor overlay inside `liveRegionRows`, or `nil`
    /// to draw none (walk defect D3: "there is no cursor, ever").
    ///
    /// The other half of the same seam `liveRegionSlice` documents, and it
    /// was unjoined for the same reason. `TerminalSession` tracks the
    /// pty's cursor — it has to, to draw the live grid at all — and
    /// publishes it as `cursorRow`/`cursorCol`; `terminalCursorLocation`
    /// turns that plus the region's own start row into a position inside
    /// the drawn rows, or `nil` when the cursor is outside them (during a
    /// command's output, say, or above the prompt).
    ///
    /// **`liveRegionSlice.startRow`, not `promptRow`** — the region trims
    /// blank rows and clamps to `maxRows`, so the row it begins at is not
    /// the row it was sliced from. Passing `0` here, as this did while the
    /// seam was open, puts the cursor `startRow` rows too low.
    private var liveRegionCursor: (row: Int, col: Int)? {
        let slice = liveRegionSlice
        return terminalCursorLocation(
            cursorRow: snapshot.cursorRow, cursorCol: snapshot.cursorCol,
            liveRegionStartRow: slice.startRow,
            liveRegionRowCount: slice.rows.count)
    }

    /// `term_scroll` with no `block`, which is how the action's own
    /// description says a pending target is cleared: *"the pane does that
    /// itself once it has scrolled, so the same block can be asked for
    /// again"*. The DB pane clears its own the same way
    /// (`pane_scroll_clear`, `DataSurface.swift`).
    private func clearScrollTarget() {
        // No `block` is what clears it; `pane` is folded in by the
        // dispatch closure itself (`Canvas.swift`).
        dispatch("term_scroll", .object([:]))
    }

    /// Turns the view's own measured pixel size into cols/rows and tells
    /// the store, but only when the answer actually disagrees with the
    /// pty's own current size — a `GeometryReader` reports on every
    /// layout pass a live pane drag produces, and re-issuing an identical
    /// `TIOCSWINSZ` on each of them buys nothing the child does not
    /// already have.
    ///
    /// **Compared against `snapshot.cols`/`rows` — the pty's own truth —
    /// never against a `@State` cache of what THIS VIEW last sent.** A
    /// cache is exactly the defect: a new session in the same pane
    /// (Reopen, or a second `term_open` onto one that already had a
    /// shell) starts at the pty's own default 80×24, but a `@State` cache
    /// survives that — the view is the same view, its `@State` does not
    /// reset — so the cache still held whatever size the PREVIOUS
    /// session was sent, the guard compared the new size against that
    /// stale memory instead of the new session's real one, found them
    /// equal by coincidence of the cache never having been told anything
    /// changed, and the resize never went out. `snapshot.cols`/`rows` is
    /// always the live truth (`TerminalSession.cols`/`rows`, published
    /// every dirty frame), so there is nothing for it to disagree with
    /// itself about, and nothing to reset when a session is replaced.
    private func reportSize(_ size: CGSize) {
        // **The strip is not the shell's to draw in.** Under a full-screen
        // program the parked history sits ABOVE the grid inside this same
        // space, so telling the pty it has the whole height makes the
        // program draw more rows than fit: the overflow runs off the
        // bottom of the pane and lands on the footer, which is how the
        // walk found it — vim's `:qa` line drawn over "last 200 commands".
        // Nothing was overlapping by z-order; the shell had simply been
        // given a screen taller than the one it was shown in.
        let availableHeight = max(0, size.height - (snapshot.screen == .grid ? parkedStripHeight : 0))
        // **The gutter is not the shell's to draw in either — the width
        // analogue of the same bug.** On the blocks surface, the live
        // region is an `HStack` whose leading `▸` marker and its spacing
        // consume width before any text is drawn, so a row that actually
        // fits `size.width` columns on screen is narrower than that in
        // practice: the pty is told it has the full pane width, wraps a
        // program's output for that many columns, and the tail of every
        // wrapped row is cut off where the marker's own space starts.
        // `liveRegionGutterWidth` is measured, not guessed at (see
        // `LiveRegionGutterWidthKey`), the same reason `parkedStripHeight`
        // is measured rather than computed from a font metric and a
        // padding constant that could drift from what is actually drawn.
        //
        // **Never subtracted in grid mode.** A full-screen program has no
        // `▸` marker at all — `LiveGrid` draws flush to the pane's own
        // edge — so subtracting the blocks surface's gutter here would
        // cost every full-screen program a few columns for a marker it
        // never draws.
        let availableWidth = max(0, size.width - (snapshot.screen == .grid ? 0 : liveRegionGutterWidth))
        let (cols, rows) = terminalGridSize(
            width: availableWidth, height: availableHeight,
            cellWidth: Self.cellSize.width, cellHeight: Self.cellSize.height)
        guard snapshot.cols != cols || snapshot.rows != rows else { return }
        resize(cols, rows)
    }

    /// The strip that keeps Wakil's own voice alive while a full-screen
    /// program owns the grid below — the last few blocks, compact, ABOVE
    /// the grid rather than over any cell of it, so nothing drawn here is
    /// mistaken by the program for a screen it owns.
    @ViewBuilder
    private func parkedHistoryStrip() -> some View {
        // Which blocks, and how many, is `parkedHistoryBlocks`' decision —
        // including that a MIRRORED block is not drawn here while a
        // program owns the screen, which is the whole of what "the mirror
        // pauses" now means (Spec 6). The snapshot still carries it.
        let recent = parkedHistoryBlocks(snapshot.blocks)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(recent) { block in
                    let status = terminalBlockStatus(block)
                    HStack(spacing: 6) {
                        Text(status.glyph)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(
                                status == .proposed ? Self.violet : Self.text.opacity(0.35))
                        Text(block.command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Self.text.opacity(status == .proposed ? 0.85 : 0.55))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            Divider().opacity(0.15)
        }
    }

    // MARK: - Footer: the stated bound

    /// *"the last 200 commands · 500 lines each"*, louder when trimmed —
    /// a trimmed history must never be mistaken for a short one.
    @ViewBuilder
    private func footer() -> some View {
        HStack {
            Text("last \(TerminalBlock.historyCap) commands · \(TerminalBlock.outputLineCap) lines each")
                .font(.system(size: 9))
                .foregroundStyle(Self.text.opacity(0.30))
            if snapshot.blocksTruncated {
                Text("· trimmed")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Self.amber.opacity(0.85))
            }
            Spacer()
        }
        // Its own row under the surface, inside the gutter; the resize handle sits over the corner
        // to its right.
        .padding(.horizontal, PaneStripStyle.gutter + 2)
        .frame(height: Self.footerHeight)
    }

    /// The footer's row: its 9 pt line with room above and below.
    private static let footerHeight: CGFloat = 20

    // MARK: - Keystrokes

    /// Every keystroke this pane's own focused container sees — forwarded
    /// to the pty unaltered when nothing above claims it, which is what
    /// makes `^C` reach the foreground process group. What is claimed
    /// first, and whether anything is claimed AT ALL, is
    /// `terminalPaneKeyClaim`'s decision (`TerminalPaneSupport.swift`),
    /// not this method's — this is the root fix for walk defects A1, A2
    /// and A3, and **a regression of a bug already fixed once**
    /// (`OrgPlane.swift:143-165`, `ConfirmationPlane.swift:22-37`): this
    /// pane became a third Escape claimant that never joined the
    /// `.cancelAction` arbitration those two already use, so with a
    /// terminal pane focused, Escape reached the pty as a literal `0x1B`
    /// and never reached `OrgPlane`'s or `ConfirmationPlane`'s dismiss
    /// button at all. `⌘F` typed into the search field leaking to the
    /// shell (A1) was the same root cause wearing a different key: this
    /// view claimed `⌘F` for itself but had no notion that a search field,
    /// a plane or a sheet could be in front of it.
    ///
    /// `isKeyboardOwner` is consulted first, ahead of even `⌘F` — see its
    /// own doc comment. With it `true` and no proposal pending, this is
    /// unchanged from before: `⌘F` toggles search, and everything else
    /// (Escape included) reaches the pty exactly as it always has, so vim
    /// and readline are untouched.
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        var modifiers = TerminalKeyModifiers()
        if press.modifiers.contains(.control) { modifiers.insert(.control) }
        if press.modifiers.contains(.command) { modifiers.insert(.command) }
        if press.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if press.modifiers.contains(.option) { modifiers.insert(.option) }
        let characters = literalCharacters(for: press)
        let special = specialKey(for: press)
        guard let claim = terminalPaneKeyClaim(
            isKeyboardOwner: isKeyboardOwner, searchOpen: searchOpen,
            hasPendingProposal: hasPendingProposal, characters: characters, special: special,
            modifiers: modifiers, selectionActive: selection != nil,
            lineEditEnabled: snapshot.inputLine != nil, selectionEditable: selectionEdit != nil)
        else { return .ignored }

        switch claim {
        case .notClaimed:
            return .ignored
        case .toggleSearch:
            searchOpen.toggle()
            if !searchOpen {
                searchQuery = ""
                focused = true
            }
        case .closeSearch:
            searchOpen = false
            searchQuery = ""
            focused = true
        case .acceptProposal:
            accept()
        case .discardProposal:
            discard()
        case .forwardToPty(let bytes):
            selection = nil
            send(bytes)
        case .paste:
            paste()
        case .copySelection:
            copySelection()
        case .replaceSelection(let text):
            replaceSelection(with: text)
        case .extendSelection(let step):
            if let line = snapshot.inputLine {
                selection = terminalExtendSelection(selection, by: step, line: line)
            }
        }
        return .handled
    }

    /// Whether this pane has a proposal waiting on the operator's `⏎`.
    ///
    /// Read off the snapshot rather than held as view state:
    /// `PaneStore.TerminalContents.snapshot` appends the pending proposal
    /// to the tail of `blocks` itself, so the pane already draws it from
    /// here — and a second copy of "is there a proposal" in `@State` would
    /// be a second thing to keep in step with the store that owns it.
    private var hasPendingProposal: Bool {
        snapshot.blocks.contains { $0.origin == .proposed }
    }

    private func specialKey(for press: KeyPress) -> TerminalSpecialKey? {
        switch press.key {
        case .upArrow: return .up
        case .downArrow: return .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .home: return .home
        case .end: return .end
        case .deleteForward: return .deleteForward
        default: return nil
        }
    }

    /// The literal bytes a named key writes, for the keys whose
    /// `press.characters` is not guaranteed to already be the terminal's
    /// own convention.
    private func literalCharacters(for press: KeyPress) -> String? {
        switch press.key {
        case .return: return "\r"
        case .tab: return "\t"
        case .delete: return "\u{7F}"
        case .escape: return "\u{1B}"
        case .space: return " "
        default: return press.characters.isEmpty ? nil : press.characters
        }
    }

    /// The edit the current selection asks for, when the line is editable.
    private var selectionEdit: TerminalLineEdit? {
        guard let selection, let line = snapshot.inputLine else { return nil }
        return terminalLineEdit(selection: selection, line: line)
    }

    private func replaceSelection(with text: String) {
        if let edit = selectionEdit { send(terminalReplaceBytes(edit: edit, replacement: text)) }
        selection = nil
    }

    /// ⌘V. An empty or non-text pasteboard does nothing.
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if selectionEdit != nil {
            replaceSelection(with: text.replacingOccurrences(of: "\r\n", with: "\n"))
        } else {
            selection = nil
            send(terminalPasteBytes(text, bracketed: snapshot.bracketedPaste))
        }
    }

    private func copySelection() {
        guard let selection else { return }
        let rows = liveRegionRows.map(terminalRowPlainText)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            terminalSelectedText(selection, rows: rows, startRow: liveRegionSlice.startRow), forType: .string)
    }

    /// `Rerun` on the operator's own block: the same pty write a hand
    /// typing it again would make, plus a trailing newline to run it —
    /// there is no separate "run" action (`acceptProposal`'s own doc
    /// comment on why typing is not one), only bytes to the pty.
    private func sendAndFocus(_ bytes: [UInt8]) {
        selection = nil
        send(bytes)
        focused = true
    }

    // MARK: - Copy / Send to thread

    /// `Copy`: the block as plain text, on the pasteboard. What that text
    /// is — the command, and its output beneath it when there is any — is
    /// `terminalBlockText`'s decision, shared with `Send to thread`, which
    /// differs only in where the text lands and in being fenced.
    private func copyBlock(_ block: TerminalBlock) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(terminalBlockText(block), forType: .string)
    }

    /// `Send to thread`: the block, fenced, as a turn to the agent. The
    /// fencing is `terminalBlockQuote`'s; the send is `WindowModel.send`'s,
    /// reached through this pane's `sendToThread` closure.
    private func sendBlockToThread(_ block: TerminalBlock) {
        sendToThread(terminalBlockQuote(block))
    }

    // MARK: - Palette

    static let text = Color(red: 0.910, green: 0.925, blue: 0.965)
    /// `#7c5cff` — design-language.md §5's luminance violet. Spent on the
    /// proposal alone: light in this pane tracks exactly one thing.
    static let violet = Color(red: 0.486, green: 0.361, blue: 1.0)
    /// `#e8b45a` — design-language.md §5's reserved amber, "pending ·
    /// caution". A running mirrored block reuses it for its chip rather
    /// than inventing a colour of its own, which is what keeps the
    /// mirror's own rule — no THIRD hue — true: every hue on screen here
    /// is one §5 already reserved.
    static let amber = Color(red: 0.910, green: 0.706, blue: 0.353)
    static let red = Color(red: 0.910, green: 0.361, blue: 0.361)
    /// The panel background Canvas.swift fills a pane with, one step
    /// darker — what "recessed" means for the mirror: never a hue, only
    /// less light than the blocks either side of it.
    static let mirrorBackground = Color(red: 0.035, green: 0.041, blue: 0.066)

    /// One monospaced glyph's own advance and the live grid's own row
    /// height (`LiveGrid`'s `.frame(height: 15, …)`) — measured once,
    /// lazily, rather than on every resize: `NSFont` metrics do not
    /// change between one pane resize and the next in the same process.
    static let cellSize: CGSize = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: width, height: 15)
    }()
}

// MARK: - The live grid

/// The live grid: the screen a foreground program draws on.
///
/// **One `Text` per row, never one per cell.** The literal reading of "a
/// custom grid renderer" — one addressable view per cell — was measured
/// and **disqualified**: at this pane's own 132×36 it draws 240.5 ms per
/// frame, 4 fps, thirty times slower than the 120fps the spec had in mind,
/// and it is the only construction measured that fails. A `Text` per row
/// is 4.82 ms, 207 fps — 3.4× the budget — and keeps the per-cell
/// selection, hit-testing and accessibility `design-language.md` wants.
///
/// **`Canvas` clears the budget by more and is still declined.** It draws
/// its own text and gives up exactly those three things, for headroom
/// row-wise already has; and its worst frame is 16–18 ms against a ~1 ms
/// median, a spike the other constructions do not have. Reserve it for the
/// case where rows stop holding under real per-cell SGR density — the
/// worse case §5 of the probe says was not measured.
///
/// **Colour is drawn, background is not.** `TerminalCellStyle.background`
/// is parsed and carried on every run (`terminalStyledOutputLines`, and
/// the live grid's own `Attribute.bg`), but `Text + Text` — the
/// concatenation this rule requires — has no per-run background of its
/// own to set: `.background()` returns `some View`, not `Text`, so it
/// cannot join a `+` chain that must stay `Text` end to end. Reproducing
/// one would mean either `AttributedString` (which drops the explicit
/// bold/dim/underline composition below) or a wrapper view per run —
/// which is the per-cell shape this file's own measurement disqualified,
/// just at run granularity instead of cell granularity. Foreground,
/// bold, dim and underline cover what §5's carve-out actually asks for:
/// a program's OWN colour, legible against the pane's own near-black
/// field; a coloured background is the rarer case and is left for the
/// day a real pane is measured needing it.
private struct LiveGrid: View {
    let rows: [[TerminalStyleRun]]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                terminalStyledRowText(
                    rows[index], dimmedDefault: TerminalPane.text.opacity(0.55), linkDefault: TerminalPane.text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 15, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }
}

/// One row, built by concatenating its runs with `+` — still exactly
/// one `Text` value however many runs the row holds, because `Text`'s
/// own `+` operator returns another `Text`, not a second view. A row
/// of one style (`terminalCoalesceStyleRuns`' common case) is one
/// run, so this returns the same single, unstyled `Text` the old
/// `Text(AttributedString(rawString))` did — no visible change for
/// the row this pane already drew correctly.
///
/// **Shared by `LiveGrid` and the block history's live region.** Both
/// surfaces draw `[[TerminalStyleRun]]` rows one `Text` per row, and
/// before the live region carried colour at all this was `LiveGrid`'s
/// own private method — pulled out to the top level rather than
/// duplicated, so the two surfaces cannot draw the same run two
/// different ways. `dimmedDefault` stays a parameter: each surface's own
/// existing default (`terminalRunText`'s own doc comment) differs, and
/// nothing here should have to guess which one a caller wants.
///
/// **Links (3c-iii ruling 14).** The row goes through `TerminalLinks.split` first, so a URL is its
/// own piece carrying `.link`, still concatenated into the row's one `Text`. `linkDefault` is the
/// colour a link with no colour of its own is drawn in: the surface's own text colour, so a link
/// keeps the colour the text around it has rather than taking the system's link blue.
private func terminalStyledRowText(_ runs: [TerminalStyleRun], dimmedDefault: Color, linkDefault: Color) -> Text {
    TerminalLinks.split(runs).reduce(Text("")) { partial, piece in
        partial + terminalRunText(
            piece.run, link: piece.link, dimmedDefault: dimmedDefault, linkDefault: linkDefault)
    }
}

/// A block's output as one multi-line `Text`: each line's runs when `runs` is present and
/// matches `output` line for line, else each line as one default-style run, so links are found
/// either way. Lines are joined with a literal `"\n"`, as the plain `Text(output.joined(…))` was.
private func terminalLinkedOutputText(
    _ output: [String], runs: [[TerminalStyleRun]]?, dimmedDefault: Color, linkDefault: Color
) -> Text {
    let lines: [[TerminalStyleRun]]
    if let runs, runs.count == output.count {
        lines = runs
    } else {
        lines = output.map { [TerminalStyleRun(text: $0, style: .plain)] }
    }
    var result = Text("")
    for (index, line) in lines.enumerated() {
        if index > 0 { result = result + Text("\n") }
        result = result + terminalStyledRowText(line, dimmedDefault: dimmedDefault, linkDefault: linkDefault)
    }
    return result
}

/// One style run as SwiftUI `Text` — the one place `TerminalCellStyle`
/// becomes a `Color`, shared by `LiveGrid` and `OperatorRow` so the two
/// surfaces cannot draw the same run two different ways.
///
/// `dimmedDefault` is what a `dim` run with no colour of its own (ANSI
/// black, or SGR 2 alone) falls back to — the live grid's full-opacity
/// text stepped down, or the block history's already-dimmed output
/// stepped down again, each surface's own existing default rather than
/// one hard-coded value that would disagree with either.
///
/// **A link** (`link` non-nil, 3c-iii ruling 14) is `Text(AttributedString)` whose `.link` is the
/// URL, drawn in the run's own colour (`linkDefault` when the run has none) with an underline at
/// 0.35 of that colour. Colour and underline are attributes of the link run itself, so the link
/// does not fall back to the view's tint. Opening it is the pane's `openURL` handler's call
/// (`TerminalPane.openLinkAction`).
private func terminalRunText(
    _ run: TerminalStyleRun, link: URL? = nil, dimmedDefault: Color, linkDefault: Color
) -> Text {
    let (foreground, _) = run.style.resolvedColors
    var color: Color?
    if let foreground {
        color = Color(red: foreground.r, green: foreground.g, blue: foreground.b)
        if run.style.dim { color = color?.opacity(0.7) }
    } else if run.style.dim {
        // ANSI black and SGR 2 (faint) alike land here with no colour of
        // their own — design-language.md §5's own rule for dimming:
        // stepped down by opacity, never by a different hue.
        color = dimmedDefault
    }
    if let link {
        let linkColor = color ?? linkDefault
        var attributed = AttributedString(run.text)
        attributed.link = link
        attributed.swiftUI.foregroundColor = linkColor
        attributed.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: linkColor.opacity(0.35))
        var text = Text(attributed)
        if run.style.bold { text = text.bold() }
        return text
    }
    var text = Text(run.text)
    if let color { text = text.foregroundColor(color) }
    if run.style.bold { text = text.bold() }
    if run.style.underline { text = text.underline() }
    return text
}

/// The cursor overlay itself: one narrow bar at a given column, drawn as a
/// single `Rectangle` — never a per-cell view (walk defect D3, see the
/// overlay's own call site). Sized to `TerminalPane.cellSize`, the same
/// measured glyph metrics `LiveGrid` and `reportSize` already use, so a
/// column offset lines up with the monospaced text underneath it.
/// The input-line selection on one row (#365): one rectangle per row, like
/// `CursorMark` — never a view per cell.
private struct SelectionMark: View {
    let columns: Range<Int>

    var body: some View {
        Rectangle()
            .fill(TerminalPane.text.opacity(0.22))
            .frame(width: TerminalPane.cellSize.width * CGFloat(columns.count), height: 15)
            .offset(x: TerminalPane.cellSize.width * CGFloat(columns.lowerBound))
            .allowsHitTesting(false)
    }
}

private struct CursorMark: View {
    let column: Int

    var body: some View {
        Rectangle()
            .fill(TerminalPane.text.opacity(0.55))
            .frame(width: max(1, TerminalPane.cellSize.width * 0.18), height: 15)
            .offset(x: TerminalPane.cellSize.width * CGFloat(column))
            .allowsHitTesting(false)
    }
}

// MARK: - The block history

/// The block history: a `LazyVStack`, measured flat at ~5 ms per scroll
/// step from 2,050 rows to 500,500 — genuinely lazy, not a rendering
/// problem at any size this pane's own 200-block cap will ever reach.
private struct BlockHistory: View {
    /// The owning pane's id, threaded down purely so the rows below can
    /// NAME themselves. Two terminal panes each hold a block `3`, and
    /// `TerminalBlock.id` is unique only within its own session — so an
    /// identifier built from the block id alone resolves to two elements
    /// the moment a second pane is open, which is a check failure rather
    /// than a wrong click, but a needless one.
    let paneId: String
    let items: [TerminalHistoryItem]
    /// The pane's own live cwd — where an operator block's structured
    /// output (Task 16 Step 6) resolves a relative name like `ls` prints,
    /// as opposed to `rootPath`, which is where a MIRRORED block ran.
    let cwd: String
    let rootPath: String
    /// `TerminalSnapshot.backfilledAt` — `isBackfilledTerminalBlock`
    /// classifies a mirrored block against this to label it.
    let backfilledAt: Date?
    /// The live screen beneath the history: the prompt, what is being
    /// typed into it, and a running command's output. Empty only when the
    /// screen genuinely has nothing on it — a shell that has not drawn its
    /// first prompt yet.
    ///
    /// **Styled, not plain — the colour defect this pair closes.**
    /// `TerminalPane.liveRegionRows` slices `snapshot.gridStyles`, never
    /// `snapshot.grid`, so a full-screen-free program's own colour (a TUI
    /// that never switches to the alternate screen, and so keeps drawing
    /// on the surface `screen == .blocks` puts here) reaches this row
    /// instead of being flattened to plain text before it ever does.
    let liveRows: [[TerminalStyleRun]]
    /// The cursor overlay's `(row, col)` inside `liveRows`, or `nil` to
    /// draw none — which is the honest answer whenever the pty's cursor
    /// is outside the live region, as it is while a command's output is
    /// still arriving. `TerminalPane.liveRegionCursor` computes it.
    let cursor: (row: Int, col: Int)?
    let liveStartRow: Int
    let inputLine: TerminalInputLine?
    @Binding var selection: TerminalGridRange?
    /// `TerminalSnapshot.scrollTarget` — the block `term_scroll` asked to
    /// be brought into view, or `nil`.
    let scrollTarget: String?
    /// Called once the scroll has happened, so the same block can be asked
    /// for again. Nothing else clears the target.
    let clearScrollTarget: () -> Void
    @Binding var expandedGroups: Set<String>
    /// `nil` when the operator has not searched — every item shows.
    let visibleIds: Set<String>?
    let now: Date
    let send: ([UInt8]) -> Void
    let accept: () -> Void
    let discard: () -> Void
    let dispatch: (String, JSONValue) -> Void
    let copy: (TerminalBlock) -> Void
    let sendToThread: (TerminalBlock) -> Void

    /// A point in the live region's rows to a screen cell. Cells are
    /// monospaced, so this is division — `reportSize`'s own arithmetic.
    private func gridPoint(_ location: CGPoint) -> TerminalGridPoint {
        TerminalGridPoint(
            row: liveStartRow + max(0, Int(location.y / TerminalPane.cellSize.height)),
            col: max(0, Int(location.x / TerminalPane.cellSize.width)))
    }



    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        row(for: item)
                    }
                    // The live region: the shell's own screen, directly
                    // beneath the history and directly beneath the
                    // proposal — which `groupedTerminalHistory` already
                    // hands back as the last block
                    // (`PaneStore.TerminalContents.snapshot` appends it to
                    // the tail itself). That ordering is the design's:
                    // the proposal sits "at the tail of the history
                    // directly above the live prompt", and until final
                    // review's Critical 2 the thing below it was a static
                    // grey label rather than a prompt.
                }
                .padding(.vertical, 4)
            }
            // **The surface half of `term_scroll`** (final review,
            // Important 2). The action set `scrollTarget` in the store and
            // nothing read it, so `term_scroll` did nothing an operator
            // could see. The DB pane already had this shape
            // (`DataSurface.swift`); this is it for blocks, with the id
            // mapped through `terminalScrollAnchor` because a block inside
            // a collapsed mirrored group is not itself on screen.
            // **Stick to the newest block.** `defaultScrollAnchor(.bottom)`
            // is what keeps a growing scroll view pinned to its end, and
            // it is the whole mechanism: the first draw opens at the
            // newest block, and every appended one stays in view.
            //
            // It replaced a sentinel row whose own visibility was read as
            // "the operator is at the bottom" — wrong in principle, and
            // the walk caught it: appending content is itself what pushes
            // a tail sentinel off screen, so growth looked exactly like
            // scrolling away and switched following off permanently after
            // the very first block.
            .defaultScrollAnchor(.bottom)
            .onChange(of: scrollTarget) { _, target in
                guard let target,
                      let anchor = terminalScrollAnchor(items: items, blockId: target)
                else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(anchor, anchor: .center) }
                // Cleared here, by the pane, exactly as `term_scroll`'s own
                // description promises — so the same block can be asked
                // for a second time and still move the view.
                clearScrollTarget()
            }

            // **The live region, docked.** It used to sit at the tail of
            // the scrolling stack, where the blocks surface's reading
            // order put it: the prompt follows the last block because
            // that is where it happened. Walking 2c-iii, the operator
            // asked for it pinned instead, and pinned is what a prompt
            // you type into wants to be — scrolling back through output
            // no longer takes the thing you are typing into off screen
            // with it.
            //
            // The cost, accepted knowingly: this surface is the shell's
            // SCREEN, not a text field, so it is up to `maxRows` tall and
            // its height changes as a command prints. The history above
            // gives way when it grows. Capping the live region is what
            // keeps that bounded.
            Divider().opacity(0.15)
            liveRegion()
                .padding(.top, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }


    /// The named coordinate space `liveRegion()` measures its own gutter
    /// in — see the `GeometryReader` inside it and `LiveRegionGutterWidthKey`.
    private static let gutterCoordinateSpace = "TerminalPane.liveRegionGutter"

    /// One `Text` per row — the same rule `LiveGrid` states and for the
    /// same measured reason (a `Text` per cell draws at 4 fps and is
    /// disqualified; a `Canvas` gives up per-cell selection, hit-testing
    /// and accessibility). Coloured exactly as `LiveGrid` colours the
    /// full-screen grid — `terminalStyledRowText`, the one function both
    /// surfaces draw a `[TerminalStyleRun]` row through — which is the
    /// fix for the defect this pane shipped colour without: this was the
    /// surface a program that never claims the alternate screen draws its
    /// whole interface on, and until now it drew in flat white no matter
    /// what the program emitted.
    @ViewBuilder
    private func liveRegion() -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("▸")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TerminalPane.text.opacity(0.35))
            Group {
                if liveRows.isEmpty {
                    // A shell that has not drawn its first prompt yet.
                    // Still a row, so the marker does not jump into place
                    // when the prompt arrives.
                    Text("waiting for the shell")
                        .font(.system(size: 9))
                        .foregroundStyle(TerminalPane.text.opacity(0.25))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(liveRows.indices, id: \.self) { index in
                            terminalStyledRowText(
                                liveRows[index], dimmedDefault: TerminalPane.text.opacity(0.90),
                                linkDefault: TerminalPane.text.opacity(0.90))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(TerminalPane.text.opacity(0.90))
                                .frame(height: 15, alignment: .leading)
                                // Walk defect D3: "there is no cursor,
                                // ever". One `Rectangle` overlay on the
                                // one row that holds it — never a
                                // per-cell view, which `LiveGrid`'s own
                                // doc comment already measured and
                                // disqualified at 4 fps. `cursor` is
                                // `nil` whenever the pty's cursor is
                                // outside the live region — during a
                                // command's output, say — and this draws
                                // nothing then.
                                .overlay(alignment: .leading) {
                                    if let cursor, cursor.row == index {
                                        CursorMark(column: cursor.col)
                                    }
                                }
                                .overlay(alignment: .leading) {
                                    if let selection, let columns = terminalSelectionColumns(
                                        selection, row: liveStartRow + index,
                                        columnCount: terminalRowPlainText(liveRows[index]).count) {
                                        SelectionMark(columns: columns)
                                    }
                                }
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { drag in
                                selection = TerminalGridRange(
                                    anchor: gridPoint(drag.startLocation), head: gridPoint(drag.location))
                            })
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { tap in
                                selection = inputLine.flatMap {
                                    terminalWordSelection(at: gridPoint(tap.location), line: $0)
                                }
                            }
                            .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in selection = nil }))
                }
            }
            // **Defect 2: the gutter this pane's own `reportSize` has to
            // subtract before telling the pty how many columns it has.**
            // Measured, not computed from the marker's own text width
            // plus the `HStack`'s `spacing: 4` — the same reason
            // `ParkedStripHeightKey` measures `parkedHistoryStrip`'s real
            // height instead of summing font metrics and paddings that
            // could drift from what is actually drawn. `.named(Self.
            // gutterCoordinateSpace)` is anchored on this `HStack`
            // itself, so `minX` here is exactly the space this leading
            // marker and its spacing consume before the text area
            // begins — nothing hardcoded, and nothing to update if the
            // marker or the spacing ever changes.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: LiveRegionGutterWidthKey.self,
                        value: proxy.frame(in: .named(Self.gutterCoordinateSpace)).minX)
                })
            Spacer(minLength: 0)
        }
        .coordinateSpace(name: Self.gutterCoordinateSpace)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func row(for item: TerminalHistoryItem) -> some View {
        switch item {
        case .block(let block):
            if visibleIds == nil || visibleIds!.contains(block.id) {
                if block.origin == .proposed {
                    ProposalRow(block: block, accept: accept, discard: discard)
                } else if block.origin == .agent {
                    MirroredRow(
                        paneId: paneId,
                        block: block, rootPath: rootPath, now: now, backfilledAt: backfilledAt,
                        dispatch: dispatch, copy: copy, sendToThread: sendToThread)
                } else {
                    OperatorRow(
                        paneId: paneId,
                        block: block, cwd: cwd, send: send, copy: copy, sendToThread: sendToThread)
                }
            }
        case .mirroredGroup(let blocks):
            let visible = visibleIds == nil ? blocks : blocks.filter { visibleIds!.contains($0.id) }
            if !visible.isEmpty {
                MirroredGroupRow(
                    paneId: paneId,
                    blocks: visible, rootPath: rootPath, now: now, backfilledAt: backfilledAt,
                    expanded: expandedGroups.contains(item.id),
                    toggle: { toggleGroup(item.id) },
                    dispatch: dispatch, copy: copy, sendToThread: sendToThread)
            }
        }
    }

    private func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
    }
}

/// Command, exit code, duration, and Copy / Rerun / Send to thread — an
/// operator-typed or operator-accepted block, the plain case every other
/// row is drawn as a variation of.
private struct OperatorRow: View {
    let paneId: String
    let block: TerminalBlock
    /// Where an `ls`'s bare names resolve to a real path — the pane's own
    /// live cwd at draw time, not necessarily the cwd this particular
    /// block ran in (`TerminalBlock` carries no cwd of its own; a `cd`
    /// between two blocks is the one case this can be stale for, and it
    /// is stale in the same direction the header already is between an
    /// OSC 7 report and the next one).
    let cwd: String
    let send: ([UInt8]) -> Void
    let copy: (TerminalBlock) -> Void
    let sendToThread: (TerminalBlock) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(statusGlyph)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(statusColor)
                Text(block.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TerminalPane.text.opacity(0.90))
                    .textSelection(.enabled)
                Spacer()
                if let ms = block.durationMs {
                    Text("\(ms) ms")
                        .font(.system(size: 9))
                        .foregroundStyle(TerminalPane.text.opacity(0.35))
                }
            }
            if let structured = structuredOutput(command: block.command, output: block.output) {
                StructuredOutputView(
                    paneId: paneId, blockId: block.id, structured: structured, basePath: cwd)
            } else if !block.output.isEmpty {
                outputText
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TerminalPane.text.opacity(0.55))
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
            actions()
        }
        .padding(.horizontal, 2)
    }

    /// Both read from the one decision (`terminalBlockStatus`), so a glyph
    /// and its colour can never disagree about the same exit code.
    private var status: TerminalBlockStatus { terminalBlockStatus(block) }
    private var statusGlyph: String { status.glyph }
    private var statusColor: Color {
        status == .failed ? TerminalPane.red.opacity(0.85) : TerminalPane.text.opacity(0.35)
    }

    /// `block.output`, coloured when `block.outputRuns` is present and
    /// trustworthy — one `Text` for the whole block, exactly as the plain
    /// path already was, built by joining each line's runs with `+` and a
    /// literal `"\n"` between lines rather than switching to one `Text`
    /// per LINE: this block already draws as a single multi-line `Text`
    /// today, and widening that to a `Text` per line would be a second,
    /// unmeasured drawing shape this task was not asked to introduce.
    ///
    /// **Falls back to the plain join whenever `outputRuns` cannot be
    /// trusted** — absent (the common, uncoloured case;
    /// `TerminalBlock.outputRuns`'s own doc comment on why that is `nil`
    /// rather than a trivial array) or, defensively, misaligned with
    /// `block.output` (a line count that disagrees is treated as "no
    /// runs" rather than zipped against the wrong line). Either way this
    /// produces the exact same `Text` the pane drew before this pane knew
    /// about colour.
    ///
    /// **Links (3c-iii ruling 14):** the plain fallback is one default-style run per line, so both
    /// paths go through `terminalStyledRowText` and a URL links whichever one drew it.
    private var outputText: Text {
        terminalLinkedOutputText(
            block.output, runs: block.outputRuns, dimmedDefault: TerminalPane.text.opacity(0.55),
            linkDefault: TerminalPane.text.opacity(0.55))
    }

    @ViewBuilder
    private func actions() -> some View {
        HStack(spacing: 10) {
            Button("Rerun") { send(Array((block.command + "\n").utf8)) }
                .accessibilityIdentifier("pane.\(paneId).block.\(block.id).rerun")
            Button("Copy") { copy(block) }
                .accessibilityIdentifier("pane.\(paneId).block.\(block.id).copy")
            Button("Send to thread") { sendToThread(block) }
                .accessibilityIdentifier("pane.\(paneId).block.\(block.id).sendToThread")
        }
        .buttonStyle(.plain)
        .font(.system(size: 9))
        .foregroundStyle(TerminalPane.text.opacity(0.40))
    }
}

/// The dashed proposal: violet, the pane's only luminous treatment — light
/// here tracks exactly one thing, whether a block is asking for the
/// operator's own `⏎`.
private struct ProposalRow: View {
    let block: TerminalBlock
    let accept: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("◇")
                    .foregroundStyle(TerminalPane.violet)
                Text(block.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TerminalPane.violet.opacity(0.95))
                Spacer()
                Text("⏎ to run · ⌫ to discard")
                    .font(.system(size: 9))
                    .foregroundStyle(TerminalPane.violet.opacity(0.65))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(TerminalPane.violet.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .background(TerminalPane.violet.opacity(0.06))
        // `⏎`/`⌫` reach the proposal through the pane's own keystroke
        // handler — `handleKeyPress` asks `terminalProposalKeyAction`
        // before anything reaches the pty — and these buttons are the
        // pointer path to the exact same two calls, not a second
        // mechanism. Until the two-axis review's Spec 1 this comment was
        // false: there was no keyboard path at all and the context menu
        // was the only way to accept, which made a mouse gesture out of
        // the interaction the whole design turns on.
        .contextMenu {
            Button("Accept (⏎)", action: accept)
            Button("Discard (⌫)", action: discard)
        }
    }
}

/// One mirrored block, recessed and never lit — a report of something
/// that already happened in Wakil's own bare-environment shell, never in
/// this pane's pty.
private struct MirroredRow: View {
    let paneId: String
    let block: TerminalBlock
    let rootPath: String
    let now: Date
    /// `TerminalSnapshot.backfilledAt` — classified per block by
    /// `isBackfilledTerminalBlock`, so a block replayed from the
    /// transcript when the pane opened is never mistaken for one that
    /// just ran.
    let backfilledAt: Date?
    let dispatch: (String, JSONValue) -> Void
    let copy: (TerminalBlock) -> Void
    let sendToThread: (TerminalBlock) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if block.exitCode == nil {
                    Text("running")
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(TerminalPane.amber.opacity(0.22)))
                        .foregroundStyle(TerminalPane.amber)
                    Text("\(terminalElapsedSeconds(startedAt: block.startedAt, now: now))s")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(TerminalPane.text.opacity(0.40))
                } else {
                    Text(terminalBlockStatus(block).glyph)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(TerminalPane.text.opacity(0.35))
                }
                Text(block.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TerminalPane.text.opacity(0.75))
                Spacer()
            }
            if let structured = structuredOutput(command: block.command, output: block.output) {
                // `rootPath`, not the pane's own `cwd`: this block ran in
                // Wakil's own bare-environment shell, never in this
                // pane's pty, and `rootPath` is where that shell runs.
                StructuredOutputView(
                    paneId: paneId, blockId: block.id, structured: structured, basePath: rootPath)
            } else if !block.output.isEmpty {
                // Plain lines, one default-style run each, so a URL in an agent's output links
                // as one in the operator's does (3c-iii ruling 14).
                terminalLinkedOutputText(
                    block.output, runs: nil, dimmedDefault: TerminalPane.text.opacity(0.45),
                    linkDefault: TerminalPane.text.opacity(0.45))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TerminalPane.text.opacity(0.45))
                    .lineLimit(10)
            }
            if block.exitCode == nil {
                Text("Wakil was told this started. Its output arrives whole when it "
                    + "finishes — nothing scrolls here.")
                    .font(.system(size: 9))
                    .foregroundStyle(TerminalPane.text.opacity(0.30))
            }
            HStack(spacing: 4) {
                Text("ran in Wakil's shell · \(rootPath) · bare environment")
                if isBackfilled {
                    Text("· backfilled")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(TerminalPane.text.opacity(0.30))
            actions()
        }
        .padding(8)
        .background(MirroredBackground())
    }

    private var isBackfilled: Bool {
        isBackfilledTerminalBlock(block, backfilledAt: backfilledAt)
    }

    @ViewBuilder
    private func actions() -> some View {
        HStack(spacing: 10) {
            // **Never plain `Rerun`.** Running it directly would execute
            // an agent-chosen command with the operator's own credentials
            // in the operator's own environment — the propose path
            // wearing a disguise (`TerminalMirror.swift`'s own "`Rerun`
            // becomes `Propose rerun`" paragraph).
            Button("Propose rerun") {
                dispatch("term_propose", .object(["command": .string(block.command)]))
            }
            .accessibilityIdentifier("pane.\(paneId).block.\(block.id).proposeRerun")
            Button("Copy") { copy(block) }
                .accessibilityIdentifier("pane.\(paneId).block.\(block.id).copy")
            Button("Send to thread") { sendToThread(block) }
                .accessibilityIdentifier("pane.\(paneId).block.\(block.id).sendToThread")
        }
        .buttonStyle(.plain)
        .font(.system(size: 9))
        .foregroundStyle(TerminalPane.text.opacity(0.40))
    }
}

/// Consecutive mirrored blocks, collapsed into one expandable row — a turn
/// of six greps draws as one line the operator can open, not six that bury
/// their own history under it. **Rendering only**: `blocks` is the exact
/// slice `groupedTerminalHistory` folded, and nothing about the snapshot
/// changed to make this possible.
private struct MirroredGroupRow: View {
    let paneId: String
    let blocks: [TerminalBlock]
    let rootPath: String
    let now: Date
    let backfilledAt: Date?
    let expanded: Bool
    let toggle: () -> Void
    let dispatch: (String, JSONValue) -> Void
    let copy: (TerminalBlock) -> Void
    let sendToThread: (TerminalBlock) -> Void

    var body: some View {
        // Hoisted out of the identifier below rather than interpolated into
        // it: the harvester reads string literals, and a `??` inside a
        // `\(...)` closes the interpolation early on its own parenthesis.
        // A name a tool cannot read is a name nothing can be measured
        // against, so the expression moves here and the literal stays plain.
        let groupId = blocks.first?.id ?? "empty"
        return VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text(expanded ? "▾" : "▸")
                        .font(.system(size: 9))
                    Text("\(blocks.count) commands from the agent"
                        + (allBackfilled ? " · backfilled" : ""))
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(TerminalPane.text.opacity(0.55))
                .contentShape(Rectangle())
            }
            // Named by the group's FIRST block, which is what
            // `TerminalHistoryItem.id` already uses for the same fold — the
            // count in the visible text changes as blocks arrive, and a name
            // that moved with it would address a different row each time.
            .accessibilityIdentifier("pane.\(paneId).group.\(groupId).toggle")
            .buttonStyle(.plain)
            if expanded {
                ForEach(blocks) { block in
                    MirroredRow(
                        paneId: paneId,
                        block: block, rootPath: rootPath, now: now, backfilledAt: backfilledAt,
                        dispatch: dispatch, copy: copy, sendToThread: sendToThread)
                }
            }
        }
        .padding(8)
        .background(MirroredBackground())
    }

    private var allBackfilled: Bool {
        allBackfilledTerminalBlocks(blocks, backfilledAt: backfilledAt)
    }
}

/// The recessed inset with a hatched edge — never lit, and the only
/// treatment on screen with no hue of its own at all. A `Canvas` here is
/// a single, static decorative border drawn once per block, not the
/// per-frame 132×36 grid §4 of the probe declined `Canvas` for; the two
/// are unrelated uses of the same API.
private struct MirroredBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(TerminalPane.mirrorBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Canvas { context, size in
                    let spacing: CGFloat = 5
                    var x: CGFloat = -size.height
                    while x < size.width {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        context.stroke(path, with: .color(Color.white.opacity(0.05)), lineWidth: 1)
                        x += spacing
                    }
                }
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .allowsHitTesting(false)
            }
    }
}

/// The structured-output allowlist's one shipped entry: a bare `ls`,
/// drawn as a list rather than a character grid. Every other command
/// degrades to the plain-text branch beside this one, the instant its
/// shape is not recognised.
private struct StructuredOutputView: View {
    /// Only ever used to name the rows below — see `BlockHistory.paneId`.
    let paneId: String
    let blockId: String
    let structured: TerminalStructuredOutput
    /// The directory `ls`'s bare names are relative to — `URL(fileURLWithPath:)`
    /// alone resolves a relative string against WAKIL'S OWN process cwd,
    /// not the shell's, which is a real terminal drawing a real button
    /// that opens the wrong file entirely.
    let basePath: String

    var body: some View {
        switch structured {
        case .fileList(let names):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TerminalPane.text.opacity(0.65))
                        Spacer()
                        Button("Open") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: name, relativeTo:
                                URL(fileURLWithPath: basePath, isDirectory: true)))
                        }
                        // Every row says the same word, so the file name is
                        // the only thing that tells two of them apart — for a
                        // check and for VoiceOver alike.
                        .accessibilityLabel("Open \(name)")
                        .accessibilityIdentifier("pane.\(paneId).block.\(blockId).file.\(name).open")
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(TerminalPane.text.opacity(0.35))
                    }
                }
            }
        }
    }
}

/// The measured height of the parked history strip, reported up from
/// inside the grid branch so `TerminalPane.reportSize` can subtract it
/// before telling the pty how many rows it has.
///
/// A preference rather than `onGeometryChange`, which is macOS 15 while
/// this app targets 14.4.
private struct ParkedStripHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The measured width of the live region's own leading gutter — the `▸`
/// marker plus the `HStack` spacing ahead of its text, reported up from
/// `BlockHistory.liveRegion()` so `TerminalPane.reportSize` can subtract
/// it before telling the pty how many columns it has (defect 2: rows
/// wrapped for the pane's full width were truncated at the right edge,
/// because the live region actually draws narrower than that).
///
/// A preference for the same reason `ParkedStripHeightKey` is one rather
/// than `onGeometryChange`: that API is macOS 15, and this app targets
/// 14.4.
private struct LiveRegionGutterWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
