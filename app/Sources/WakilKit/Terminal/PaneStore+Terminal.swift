import Foundation

// The terminal kind's store methods (pluggable pane kinds): same actor, same names as before.
extension PaneStore {
    /// The terminal contents for `paneId`, or a fresh empty set — the
    /// mirror image of `dataSurface(_:)`, including its rule that a pane of the
    /// other kind answers empty and has its write discarded rather than
    /// its contents silently corrupted.
    func terminal(_ paneId: String) -> TerminalContents { contents(TerminalPaneKind.self, paneId) }

    func setTerminal(_ paneId: String, _ contents: TerminalContents) {
        setContents(TerminalPaneKind.self, paneId, contents)
    }

    /// Appends a finished block, trimming the oldest past the cap and
    /// recording that it did.
    ///
    /// **Ordered by `startedAt`, not by arrival.** The operator's blocks
    /// come off the drain thread and the mirror's come off the harness
    /// stream; two producers that both append would interleave by
    /// scheduling accident.
    ///
    /// **Inserted at its place rather than appended-and-sorted.** Swift's
    /// `sort` is not stable, and mirrored blocks routinely share a
    /// `startedAt` to the resolution `Date()` gives them, so re-sorting on
    /// every append was free to permute equal-timestamped blocks between
    /// one snapshot and the next — a change an agent diffing two reads
    /// would see that is only the tie-break. The same reason `paneIds()`
    /// sorts at all.
    public func recordTerminal(paneId: String, block: TerminalBlock) {
        var contents = terminal(paneId)
        if let index = contents.blocks.firstIndex(where: { $0.id == block.id }) {
            contents.blocks[index] = block  // a running block filling in
        } else {
            let insertion = contents.blocks.firstIndex { $0.startedAt > block.startedAt }
                ?? contents.blocks.count
            contents.blocks.insert(block, at: insertion)
        }
        if contents.blocks.count > TerminalBlock.historyCap {
            contents.blocks.removeFirst(contents.blocks.count - TerminalBlock.historyCap)
            contents.blocksTruncated = true
        }
        setTerminal(paneId, contents)
    }

    /// What the pane's live shell currently is: where it is, what it is,
    /// how big it is, which surface is in front, and — when a full-screen
    /// program holds the screen — the visible rows of it.
    ///
    /// Written from `TerminalStore`'s frame-rate poll, never from the
    /// feed: SwiftTerm has no content-change callback at all, so the dirty
    /// range is polled, and polling *is* the coalescing.
    public func setTerminalLiveState(
        paneId: String, cwd: String, shell: String, cols: Int, rows: Int,
        screen: TerminalScreen, grid: [String], promptRow: Int? = nil,
        cursorRow: Int? = nil, cursorCol: Int? = nil, gridStyles: [[TerminalStyleRun]]? = nil,
        commandRunning: Bool = false,
        inputLine: TerminalInputLine? = nil, bracketedPaste: Bool = false
    ) {
        var contents = terminal(paneId)
        contents.cwd = cwd
        contents.shell = shell
        contents.cols = cols
        contents.rows = rows
        contents.screen = screen
        contents.grid = grid
        contents.gridStyles = gridStyles
        contents.promptRow = promptRow
        contents.cursorRow = cursorRow
        contents.cursorCol = cursorCol
        contents.commandRunning = commandRunning
        contents.inputLine = inputLine
        contents.bracketedPaste = bracketedPaste
        setTerminal(paneId, contents)
    }

    /// At most one pending proposal per pane — a property of the storage,
    /// not a rule a handler has to remember. A replacement is journalled
    /// by the action, so an agent cannot silently swap the command under a
    /// hand already moving to Enter.
    public func setTerminalProposal(paneId: String, _ proposal: TerminalBlock?) {
        var contents = terminal(paneId)
        contents.proposal = proposal
        setTerminal(paneId, contents)
    }

    public func terminalProposal(paneId: String) -> TerminalBlock? { terminal(paneId).proposal }

    /// The block the surface should bring into view, by id. Task 13's
    /// action is the only writer; this pair exists now so the snapshot's
    /// shape is settled once.
    public func setTerminalScrollTarget(paneId: String, blockId: String?) {
        var contents = terminal(paneId)
        contents.scrollTarget = blockId
        setTerminal(paneId, contents)
    }

    public func terminalScrollTarget(paneId: String) -> String? { terminal(paneId).scrollTarget }

    /// Records that `WindowModel.backfillMirror()` just replayed the
    /// agent's history into this pane, so the view can tell a block that
    /// predates the pane from one that streamed in live afterwards
    /// (`isBackfilledTerminalBlock`, `TerminalPaneSupport.swift`).
    public func setTerminalBackfilledAt(paneId: String, _ date: Date?) {
        var contents = terminal(paneId)
        contents.backfilledAt = date
        setTerminal(paneId, contents)
    }

    public func terminalBackfilledAt(paneId: String) -> Date? { terminal(paneId).backfilledAt }

    /// The finished blocks only, for the window and for tests — the
    /// pending proposal is deliberately not among them, because it names a
    /// command that has not run.
    public func terminalBlocks(paneId: String) -> [TerminalBlock] { terminal(paneId).blocks }

    /// Empties a terminal pane's block history without touching its live
    /// shell — walk-defects D1. `clear` (and `^L`, and any script that
    /// clears the screen the same way — `TerminalSession` triggers this
    /// off the raw escape sequence, never off a command's name) wipes
    /// what the OPERATOR sees; everything else about the pane — `cwd`,
    /// `shell`, `cols`/`rows`, `grid`, the pending proposal, the scroll
    /// target, the backfill marker — is a fact about the still-running
    /// shell and none of it is a block, so none of it is touched.
    ///
    /// **No marker block, and that is deliberate, not an omission.** The
    /// operator asked for a clear screen; a block recording that the
    /// clear happened is the very thing they were clearing (the decision
    /// recorded against D1 in `walk-defects.md`). The journal still has
    /// the durable record — `TerminalStore.yieldRun` fires for `clear`
    /// exactly like any other command — only the pane's own display
    /// clears.
    public func clearTerminalBlocks(paneId: String) {
        var contents = terminal(paneId)
        contents.blocks = []
        contents.blocksTruncated = false
        setTerminal(paneId, contents)
    }

    /// Clears everything a terminal pane holds without closing the pane.
    ///
    /// A new shell is a new history: the old one belonged to a process
    /// that no longer exists, so `term_open` on a pane that already had a
    /// shell starts again. The pane's dimensions are kept, because the
    /// pane did not change size.
    public func clearTerminal(paneId: String) {
        var contents = terminal(paneId)
        contents.blocks = []
        contents.blocksTruncated = false
        contents.grid = []
        contents.screen = .blocks
        contents.proposal = nil
        contents.scrollTarget = nil
        contents.failure = nil
        contents.backfilledAt = nil
        contents.promptRow = nil
        contents.cursorRow = nil
        contents.cursorCol = nil
        contents.commandRunning = false
        setTerminal(paneId, contents)
    }

    /// The mirror's own append. Task 15's `mirroredBlocks` is its caller.
    ///
    /// **It records immediately, whatever is on the screen** — including
    /// while a full-screen program holds it. Until the two-axis review's
    /// Spec 6 this deferred the block into a `pausedMirror` staging array
    /// while `screen == .grid` and flushed it when the program exited, on
    /// the stated grounds that *"foreign rows cannot be spliced into a
    /// live emulator buffer without lying to the shell about where its
    /// cursor is"*. That is true and it is not this method's problem: the
    /// block/grid split already guarantees it, because a block is not a
    /// grid row and nothing here ever reaches the emulator's buffer. What
    /// the deferral actually did was withhold the block from
    /// `read_pane` — so during a `vim` session the agent could not read
    /// back its own commands, which is precisely what story 46 forbids:
    /// *"mirrored blocks present individually in the snapshot even when
    /// the screen groups them, so that a rendering choice never changes
    /// what I can read."*
    ///
    /// **The pause survives where it belongs — in the drawing.**
    /// `parkedHistoryBlocks` (`TerminalPaneSupport.swift`) is what keeps a
    /// mirrored block out of the compact strip above a program's screen,
    /// and the moment the program lets go the whole history draws, mirror
    /// included. A rendering decision now lives in the renderer.
    ///
    /// **Replacement by id is `recordTerminal`'s own**, which is what lets
    /// a mirrored block arrive open (no exit code) and be replaced by its
    /// sealed self when the tool call returns.
    public func appendMirrored(paneId: String, block: TerminalBlock) {
        recordTerminal(paneId: paneId, block: block)
    }
}
