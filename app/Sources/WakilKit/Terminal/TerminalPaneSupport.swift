import Foundation

/// Everything the terminal pane's drawing code (`WakilApp/TerminalPane.swift`,
/// Task 16) needs computed, parsed or decided, kept here rather than in the
/// view because `WakilApp` has no test target and cannot have one — the same
/// reason `DBPane`'s column-width arithmetic lives in `Panes/PaneTable.swift`
/// rather than in `DBPane.swift`. Every function below is a pure value
/// transform: no `AppKit`, no `SwiftUI`, nothing a fabricated input in
/// `WakilKitTests` could not exercise exactly as the view will.

// MARK: - Grid metrics

/// How many columns and rows fit a pane's live grid, given the pixel size
/// the view measured and one monospaced glyph's own width and line height.
///
/// **Floored at 1×1, never 0×0.** A pane mid-resize, or one whose frame has
/// not laid out yet, can report a width or height of zero for a frame or
/// two; handing that straight to `TIOCSWINSZ` would tell the child process
/// its screen is zero cells wide, which is not a size any program expects
/// to recover from cleanly. `max(1, ...)` is the same floor
/// `Pane.minimumWidth`/`minimumHeight` apply to the pane's own rectangle,
/// one level down.
public func terminalGridSize(
    width: Double, height: Double, cellWidth: Double, cellHeight: Double
) -> (cols: Int, rows: Int) {
    guard cellWidth > 0, cellHeight > 0 else { return (1, 1) }
    return (max(1, Int(width / cellWidth)), max(1, Int(height / cellHeight)))
}

// MARK: - History grouping

/// One row of the block history as the view draws it: a single block, or a
/// run of consecutive mirrored ones collapsed into one expandable group.
public enum TerminalHistoryItem: Sendable, Equatable, Identifiable {
    case block(TerminalBlock)
    /// Always two or more blocks — `groupedTerminalHistory` never wraps a
    /// lone mirrored block in a group of one, so "collapsed" always means
    /// something was actually folded away.
    case mirroredGroup([TerminalBlock])

    public var id: String {
        switch self {
        case .block(let block): return block.id
        case .mirroredGroup(let blocks): return "group-\(blocks.first?.id ?? "")"
        }
    }
}

/// Folds consecutive `origin: .agent` blocks into one `mirroredGroup`, so a
/// turn where the agent ran six greps draws as one collapsible row rather
/// than burying the operator's own history under it.
///
/// **Rendering only — the input is never mutated and nothing is dropped.**
/// `TerminalSnapshot.blocks` still returns every block individually; this
/// is a second, view-facing shape built from it on every draw, the same
/// relationship `paneColumnWidth` has to a `DataSurfaceSnapshot`'s raw columns.
/// A caller that wants the underlying blocks of a group still has them —
/// `mirroredGroup`'s own array — so nothing here is a one-way translation.
///
/// **A run of exactly one mirrored block stays a plain `.block`.** Folding
/// a SINGLE agent command into a "group" the operator has to expand to
/// read is worse than just showing it; collapsing exists to save space
/// from six blocks, not to add a click to one.
public func groupedTerminalHistory(_ blocks: [TerminalBlock]) -> [TerminalHistoryItem] {
    var result: [TerminalHistoryItem] = []
    var run: [TerminalBlock] = []

    func flushRun() {
        if run.count > 1 {
            result.append(.mirroredGroup(run))
        } else if let only = run.first {
            result.append(.block(only))
        }
        run = []
    }

    for block in blocks {
        if block.origin == .agent {
            run.append(block)
        } else {
            flushRun()
            result.append(.block(block))
        }
    }
    flushRun()
    return result
}

// MARK: - Elapsed time

/// Whole seconds since `startedAt`, floored at 0. A mirrored block's
/// `durationMs` is `nil` while it runs — by design, not oversight
/// (`TerminalMirror.swift`'s ruling 4: the wire carries no elapsed time
/// for an in-flight tool call) — so the running chip's counter is computed
/// from `startedAt` rather than reading a duration that does not exist yet
/// and must not be treated as zero.
public func terminalElapsedSeconds(startedAt: Date, now: Date) -> Int {
    max(0, Int(now.timeIntervalSince(startedAt)))
}

// MARK: - The live region under the block history

/// The rows of the live screen worth drawing **beneath** the block
/// history: the shell's prompt, whatever is being typed into it, and the
/// output of a command that has not finished yet.
///
/// **Why this exists at all** (final review, Critical 2). The blocks
/// surface is a history of things that have already happened, and for the
/// whole of this sub-phase it was the *only* thing drawn when
/// `screen == .blocks` — with a static grey "live prompt" label where the
/// prompt should be. So the operator typed blind: no echo, no `PS1`, no
/// sign of an `npm install` until it exited, and an accepted proposal
/// invisible in the prompt it had just been written into. The design
/// places a proposal "at the tail of the history directly above the live
/// prompt", which presumes a live prompt exists. This is it.
///
/// **A trim, not a second history.** `grid` is the visible screen and
/// nothing else (`TerminalSnapshot.grid`), and most of it on the block
/// surface is the blank space below a prompt sitting near the top. Drawing
/// all `rows` of it would put a tall empty gap under every pane's history.
/// So: trailing blank rows dropped, then the last `maxRows` kept, then
/// leading blank rows dropped — what is left is the live text and only it.
/// An all-blank screen yields `[]`, and the caller draws nothing rather
/// than an empty box.
///
/// **Never the scrollback.** Rows that scrolled off the top of the visible
/// screen are gone from `grid` by definition; the history of finished
/// commands is the blocks' job, and duplicating it here is exactly the
/// double-drawing the old empty-`grid` rule was trying to avoid.
///
/// **`promptRow` narrows this to what the walk-fix spec actually asked
/// for** (2c-iii walk defect C2): "the shell's current screen — the
/// prompt the operator types at", which is NOT the same thing as "the
/// tail of the whole visible screen". Taking the last `maxRows` of the
/// entire `grid` — the behaviour below when `promptRow` is `nil` — still
/// holds every command that has not scrolled off, so the operator saw
/// each one twice: once as a structured block, once raw underneath. When
/// `promptRow` names the row the current prompt actually started on
/// (`TerminalMarkScanner`'s own `promptStart`), the slice starts there
/// instead, so a completed command's rows are never drawn twice.
///
/// `promptRow` is threaded through from `TerminalSnapshot.promptRow` at
/// the one call site in `TerminalPane.swift` (`liveRegionRows`), which is
/// what `TerminalSession`'s own OSC 133;A scan actually decides.
///
/// **`isCommandRunning` is the other half — the live-region-running fix.**
/// Everything above describes the IDLE case: the prompt, and what has
/// been typed at it. That is wrong for the whole time a command is
/// running, full-screen or not — `promptRow` is latched to the last
/// prompt and does not move while the command's own output scrolls the
/// screen underneath it, so slicing from it and capping at `maxRows`
/// draws an 8-row tail of whatever the program most recently printed,
/// discarding everything above. A program that renders a full interface
/// without ever touching the alternate screen (`claude`, among others)
/// then shows only its last few lines, replaced wholesale on every
/// redraw — see `terminalLiveRegionSlice(gridStyles:)`'s own doc comment
/// for the mode split.
public func terminalLiveRegion(
    grid: [String], maxRows: Int = 8, promptRow: Int? = nil, isCommandRunning: Bool = false
) -> [String] {
    terminalLiveRegionSlice(
        grid: grid, maxRows: maxRows, promptRow: promptRow, isCommandRunning: isCommandRunning
    ).rows
}

/// One row's plain text, concatenating its runs in order.
///
/// **The one place either live-region slice decides what "this row's
/// text" means.** `terminalLiveRegionSlice(grid:)` builds its blank-row
/// and clamping decisions by calling into `terminalLiveRegionSlice
/// (gridStyles:)` and reading each surviving row back through this
/// function — so the plain rows it returns are a projection of the
/// exact same trimming the styled rows went through, never a second,
/// independently-trimmed copy that could disagree with it about which
/// rows are blank or where the region starts.
public func terminalRowPlainText(_ runs: [TerminalStyleRun]) -> String {
    runs.map(\.text).joined()
}

/// The live region AND the absolute `grid` row it begins at, styled.
///
/// **This is the real implementation.** `TerminalSnapshot.gridStyles` is
/// guaranteed the same length as `grid` and is never `nil` (its own doc
/// comment), so slicing it instead of `grid` loses nothing and is what
/// lets the plain-text overload below be a projection of this one rather
/// than a second trim that could drift from it — exactly the colour
/// defect this pair closes: before it, only `grid` (plain `[String]`) was
/// ever sliced, so the live region — the surface a full-screen-free TUI
/// draws its ENTIRE interface on — discarded every colour it emitted.
///
/// **The start row is not `promptRow`.** The trimming and clamping below
/// move it — a blank row above the prompt is dropped, and a region longer
/// than `maxRows` loses its head — so anything that has to place something
/// *into* these rows by absolute coordinate (the cursor, via
/// `terminalCursorLocation`) needs the row they actually start at, not the
/// row they were sliced from. Computing it here rather than in the view is
/// the same rule as everything else in this file: `WakilApp` has no test
/// target, so an off-by-one it owns is an off-by-one nobody can assert.
///
/// **Blankness is a property of the row's concatenated text, never of any
/// one run.** A row holding `[TerminalStyleRun(text: "  ", style: red),
/// TerminalStyleRun(text: "  ", style: .plain)]` is blank even though one
/// of its runs is coloured — colouring whitespace does not make it text —
/// so the trim below checks `terminalRowPlainText(row)`, not each run in
/// isolation.
///
/// **The live region means two different things, and `isCommandRunning`
/// is what tells them apart** (live-region-running fix, following walk
/// defect C2). At an idle prompt (`false`, the default — every existing
/// caller and test) it is the current prompt and what has been typed at
/// it: sliced from `promptRow`, capped at `maxRows`, exactly the
/// behaviour above and unchanged by this parameter's addition. While a
/// command is running (`true`) it is **the screen**: `promptRow` is
/// ignored (it is latched to a prompt the running command's own output
/// has long since scrolled past) and so is `maxRows` (the cap this
/// function otherwise enforces) — the whole of `gridStyles` is taken,
/// only trimmed of leading/trailing blank rows exactly as the idle case
/// is. This is what fixes the defect where a long-running full-screen-
/// free TUI (`claude`, running for minutes with no `commandEnd` to close
/// its block) was visible only as an 8-row tail of its own screen,
/// overwritten wholesale on every redraw.
///
/// **Still one trim, not two.** The mode decides which rows enter the
/// pipeline below and whether the `maxRows` clamp runs; the blank-row
/// trimming at both ends is the same code for both, so a running
/// command whose screen is mostly blank (a small prompt of its own)
/// trims down to its actual content instead of claiming the whole pane —
/// the cap is real content, not `gridStyles.count`, even though nothing
/// here imposes a row limit of its own.
///
/// **`gridStyles` is already bounded to the pane.** It is rebuilt every
/// dirty frame from the pty's own screen (`TerminalSession.screenLines`),
/// which is exactly `cols × rows` for whatever size the pane last
/// reported — so "take the whole grid" already means "take what fits the
/// pane", never an unbounded scrollback. There is no second cap to add.
public func terminalLiveRegionSlice(
    gridStyles: [[TerminalStyleRun]], maxRows: Int = 8, promptRow: Int? = nil,
    isCommandRunning: Bool = false
) -> (rows: [[TerminalStyleRun]], startRow: Int) {
    guard isCommandRunning || maxRows > 0 else { return ([], 0) }
    var rows: [[TerminalStyleRun]]
    var startRow: Int
    if isCommandRunning {
        // The screen, not a slice of it — see this function's own doc
        // comment. `promptRow` is deliberately not consulted: it names
        // where the LAST prompt began, which a running command's own
        // output has moved on from.
        rows = gridStyles
        startRow = 0
    } else if let promptRow, promptRow >= 0, promptRow < gridStyles.count {
        // The current prompt and everything after it — never the rows
        // above it, which are either scrollback (gone from `grid` by
        // definition) or a FINISHED command's own rows, which the block
        // history already draws. This is the whole fix: narrowing which
        // slice of `grid` counts as "live", not touching `grid` itself.
        rows = Array(gridStyles[promptRow...])
        startRow = promptRow
    } else {
        // No prompt row known yet — a snapshot published before this seam
        // is wired, or a build that predates it entirely. Falls back to
        // the old heuristic (the tail of the whole screen) rather than
        // drawing nothing, exactly as the walk-fix spec requires.
        rows = gridStyles
        startRow = 0
    }
    while let last = rows.last, terminalRowPlainText(last).trimmingCharacters(in: .whitespaces).isEmpty {
        rows.removeLast()
    }
    // The `maxRows` cap is an idle-mode rule only — while a command runs,
    // the pane's own height (already `gridStyles`'s bound) is the only
    // limit, per this function's own doc comment.
    if !isCommandRunning, rows.count > maxRows {
        let dropped = rows.count - maxRows
        rows.removeFirst(dropped)
        startRow += dropped
    }
    while let first = rows.first,
        terminalRowPlainText(first).trimmingCharacters(in: .whitespaces).isEmpty {
        rows.removeFirst()
        startRow += 1
    }
    return (rows, startRow)
}

/// The live region AND the absolute `grid` row it begins at, as plain
/// text — a projection of `terminalLiveRegionSlice(gridStyles:)`, not a
/// second trim of its own.
///
/// **Derived, never independently computed.** A caller with only plain
/// text (every existing test in this file, and any future one) wraps each
/// row in a single `.plain`-styled run — the same shape
/// `TerminalSnapshot.gridStyles` falls back to for a caller that never
/// threads colour through at all (its own initialiser) — runs the one
/// real implementation above, then reads the surviving rows back out as
/// text. This is what guarantees the two overloads cannot drift: there is
/// only one trim, and this is a read of its result, not a rewrite of its
/// rule.
///
/// `terminalLiveRegion` above is this function's `rows` half, kept as its
/// own name because most callers want only the rows.
public func terminalLiveRegionSlice(
    grid: [String], maxRows: Int = 8, promptRow: Int? = nil, isCommandRunning: Bool = false
) -> (rows: [String], startRow: Int) {
    let styled = terminalLiveRegionSlice(
        gridStyles: grid.map { [TerminalStyleRun(text: $0, style: .plain)] },
        maxRows: maxRows, promptRow: promptRow, isCommandRunning: isCommandRunning)
    return (styled.rows.map(terminalRowPlainText), styled.startRow)
}

// MARK: - term_scroll's anchor

/// The id of the history ROW that holds `blockId` — what
/// `ScrollViewReader.scrollTo` has to be given, which is not always the
/// block id itself.
///
/// `groupedTerminalHistory` folds a run of consecutive mirrored blocks
/// into one `mirroredGroup` row, and a collapsed group draws none of its
/// members' own ids. `term_scroll` accepts any block id `read_pane`
/// reported, including one inside such a group, so asking the scroll view
/// for that id directly would silently do nothing. This maps it to the row
/// that is actually on screen.
///
/// `nil` when no row holds it — a block trimmed by the history cap between
/// the agent's read and its `term_scroll`, which the surface must treat as
/// "nothing to scroll to", not as an error to raise at the operator.
public func terminalScrollAnchor(items: [TerminalHistoryItem], blockId: String) -> String? {
    for item in items {
        switch item {
        case .block(let block):
            if block.id == blockId { return item.id }
        case .mirroredGroup(let blocks):
            if blocks.contains(where: { $0.id == blockId }) { return item.id }
        }
    }
    return nil
}

// MARK: - The backfill marker

/// Whether `block` was replayed from the transcript when the pane's mirror
/// was backfilled, rather than having streamed in live afterwards —
/// `TerminalSnapshot.backfilledAt`, classified against one block at a
/// time so the view can label it.
///
/// **A `nil` marker means nothing is backfilled**, not "everything is" —
/// a pane whose mirror has never been backfilled (no agent activity yet
/// retained when it opened) must not have every future live block read as
/// history the moment one arrives.
///
/// **`<=`, not `<`.** `backfilledAt` is captured once, in
/// `WindowModel.backfillMirror()`, at or after every block it is about to
/// mark — so a block whose `startedAt` exactly equals the marker is one
/// `backfillMirror()` itself just replayed, not a coincidence to exclude.
public func isBackfilledTerminalBlock(_ block: TerminalBlock, backfilledAt: Date?) -> Bool {
    guard let backfilledAt else { return false }
    return block.startedAt <= backfilledAt
}

// MARK: - ⌘F, counted in blocks

/// One command's worth of searchable text: itself and its captured output,
/// case-insensitively. A match on output and not the command text still
/// counts — "which command printed this" is exactly what the operator
/// reaches for ⌘F to answer.
private func terminalBlockMatches(_ block: TerminalBlock, query: String) -> Bool {
    guard !query.isEmpty else { return true }
    let needle = query.lowercased()
    if block.command.lowercased().contains(needle) { return true }
    return block.output.contains { $0.lowercased().contains(needle) }
}

/// The ids of every block `query` matches. Empty `query` matches
/// everything — nothing is hidden until the operator has actually typed a
/// search.
public func matchingTerminalBlockIds(_ blocks: [TerminalBlock], query: String) -> Set<String> {
    Set(blocks.filter { terminalBlockMatches($0, query: query) }.map(\.id))
}

/// *"3 blocks · 1 block hidden · no match"* — counted in BLOCKS, never in
/// lines, because a block is this pane's unit of state and "line 42 of
/// 900" tells the operator nothing about which command they are looking
/// at. Empty for no active search, so the footer has nothing extra to say
/// when ⌘F has not been used.
public func terminalSearchSummary(totalBlocks: Int, matchingBlocks: Int, hasQuery: Bool) -> String {
    guard hasQuery else { return "" }
    guard matchingBlocks > 0 else { return "no match" }
    let hidden = totalBlocks - matchingBlocks
    var text = "\(matchingBlocks) \(matchingBlocks == 1 ? "block" : "blocks")"
    if hidden > 0 {
        text += " · \(hidden) \(hidden == 1 ? "block" : "blocks") hidden"
    }
    return text
}

// MARK: - Structured output, a per-command allowlist

/// One recognised shape a command's plain-text output can be redrawn as,
/// instead of the character grid it actually printed.
///
/// **Shipped with one entry.** The allowlist mechanism is what this task
/// owes — degrading to plain text the instant a shape is not recognised —
/// not breadth of coverage; guessing at output this build has never seen
/// is how a terminal starts telling the operator a program printed
/// something it did not.
public enum TerminalStructuredOutput: Sendable, Equatable {
    /// A bare `ls`'s output, one entry per printed name — which is NOT
    /// one per printed LINE: on a tty `ls` columnates.
    case fileList([String])
}

/// Recognises `ls`, with no flags that would change its output shape, and
/// nothing else. Returns `nil` — plain text — for every other command, an
/// `ls` with flags this build has not modelled, and empty output (nothing
/// structured to gain over the one blank line plain text already draws).
///
/// **The allowlist keys on the command's first word only**, not on
/// guessing at the shape of `output` itself: a directory that happens to
/// contain a file named `42` must not be read as some other command's
/// numeric output, and the only honest way to avoid that is to know what
/// was actually run.
///
/// **`ls -l` is refused on purpose, not by accident** (walk defect D2's
/// second half: "`ls -l` in the same session draws no Open at all"). The
/// allowlist has exactly one shape modelled — bare `ls`'s one-name-per-line
/// output — and `ls -l` is a different shape (mode bits, link count,
/// owner, size, date ahead of the name on every line) that this function
/// has never parsed. Degrading to plain text for it is the allowlist
/// mechanism working as designed, the same as any other unmodelled flag;
/// it is not the bug. The bug was the miscount below.
public func structuredOutput(command: String, output: [String]) -> TerminalStructuredOutput? {
    let trimmed = command.trimmingCharacters(in: .whitespaces)
    guard trimmed == "ls" else { return nil }
    let entries = terminalLsFileNames(from: output)
    guard !entries.isEmpty else { return nil }
    return .fileList(entries)
}

/// The file names a captured bare `ls` actually printed — walk defect D2:
/// `events.db src` (two files) drew THREE `Open` buttons, because the old
/// filter (`!$0.isEmpty`) let through anything that merely had a
/// character in it, and two things captured alongside real output are not
/// file names at all:
///
/// - **A wholly blank row.** Already excluded before this fix, kept here
///   for the same reason: a trailing blank line the capture pads output
///   with is not a file, empty or otherwise.
/// - **The shell's own "no trailing newline" marker.** zsh draws a bare
///   `%` (reverse-video in a real terminal, plain text once captured)
///   when a command's output does not end in `\n` — `PROMPT_SP`. `ls`
///   itself never prints a lone `%`, so a captured row that trims to
///   exactly `%` is unambiguously that marker, not a file named `%`, and
///   dropping it is safe in a way a heuristic on ordinary output could not
///   be.
///
/// Both are why the count was off by one; neither is a file, so this
/// cannot UNDERcount a real `ls` — it only removes rows `ls` did not
/// itself put there. Each surviving entry is trimmed once, here, rather
/// than left to whatever incidental leading/trailing space the capture
/// added, which is also what anchors each `Open` button to its own name
/// instead of drifting by however much padding a raw row happened to
/// carry.
func terminalLsFileNames(from output: [String]) -> [String] {
    output.flatMap(terminalLsColumns(in:))
}

/// The names in ONE captured `ls` row.
///
/// **A row is not a name.** `ls` prints one name per line only when its
/// output is not a tty; on a pty — which is the only kind this pane has —
/// it columnates, so `events.db\tsrc` is a single row holding two files.
/// Treating the row as the name was walk defect D2's second life: the
/// first fix removed the phantom THIRD `Open`, and left one `Open`
/// standing for two files, pointing at a path named `events.db     src`
/// that does not exist.
///
/// **Split on the tab first, because that is what `ls` actually emits**
/// (`ls -C | od -c` → `e v e n t s . d b \t s r c \n`), and a block keeps
/// the pty's raw bytes, so the tab is still there when this runs. That
/// split is exact: a tab cannot occur inside a file name `ls` prints
/// unquoted.
///
/// **Then split on two spaces or more**, for a row whose tabs were
/// expanded against tab stops before reaching here. Two, not one, so
/// `Screen Shot.png` survives as one name. The bounded miss this leaves,
/// stated rather than hidden: a file whose name contains a run of two or
/// more spaces, in a row that reached here already expanded, splits in
/// two. The plain text under it is unchanged and still correct.
func terminalLsColumns(in row: String) -> [String] {
    var names: [String] = []
    var current = ""
    var pendingSpaces = 0

    func endName() {
        let name = current.trimmingCharacters(in: .whitespaces)
        // zsh's `PROMPT_SP` marker, never a file — see `structuredOutput`.
        if !name.isEmpty, name != "%" { names.append(name) }
        current = ""
    }

    for character in row {
        if character == "\t" {
            pendingSpaces = 0
            endName()
        } else if character == " " {
            pendingSpaces += 1
            if pendingSpaces == 2 {
                // Two spaces: the one already written was a separator too.
                current.removeLast()
                endName()
            } else if pendingSpaces == 1 {
                current.append(character)
            }
        } else {
            pendingSpaces = 0
            current.append(character)
        }
    }
    endName()
    return names
}

// MARK: - Keystrokes

/// The modifier keys the pane's key handler cares about, as a plain
/// `OptionSet` rather than `NSEvent.ModifierFlags`/`EventModifiers` — so
/// `terminalKeyBytes` below has no `AppKit`/`SwiftUI` import and is
/// callable from a test with a fabricated combination, the same reason
/// `PaneFrame` (`Pane.swift`) stays free of `CoreGraphics`. The view does
/// the one-line translation from whichever framework type it is holding.
public struct TerminalKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// ⌃. Combined with a plain ASCII letter this is a control character
    /// — `^C`, `^R`, `^D` — which is the one modifier combination this
    /// pane must forward rather than treat as a shortcut.
    public static let control = TerminalKeyModifiers(rawValue: 1 << 0)
    /// ⌘. Never forwarded: every ⌘-combination this window recognises is
    /// a menu shortcut, and one it does not recognise is still not pty
    /// input — a real terminal's own window chrome claims ⌘ too.
    public static let command = TerminalKeyModifiers(rawValue: 1 << 1)
    /// ⇧ — read only for ⇧← / ⇧→ on an editable input line (#365);
    /// `terminalKeyBytes` ignores it, so every other key is unchanged.
    public static let shift = TerminalKeyModifiers(rawValue: 1 << 2)
    /// ⌥ — read only for ⌥←, ⌥→ and ⌥⌫ (`terminalKeyBytes`). A character
    /// typed with ⌥ arrives already composed (é), so it passes through.
    public static let option = TerminalKeyModifiers(rawValue: 1 << 3)
}

/// A keystroke with no printable `characters` of its own — an arrow, a
/// navigation key — translated to its ANSI CSI sequence rather than
/// passed through, because there is no "unaltered" byte for these: the
/// view's UI framework hands back a named key, not a character, and
/// something has to decide what byte a pty expects for "up arrow".
public enum TerminalSpecialKey: Sendable {
    case up, down, left, right, home, end, deleteForward
}

/// What one keystroke writes to the pty, or `nil` for a keystroke this
/// pane does not forward at all.
///
/// **⌘-anything is refused first, unconditionally.** A `⌘`-combination is
/// this window's own shortcut table (⌘K, ⌘P, ⌘F, ⌘↩ and the rest) before
/// it is ever a keystroke a shell could want, and letting one fall through
/// to the pty on a miss would mean a mistyped shortcut runs a stray
/// control character in the operator's shell instead of doing nothing.
///
/// **A `special` key is translated, never passed through as `characters`**
/// — see `TerminalSpecialKey`'s own doc comment.
///
/// **`characters` is passed through unaltered EXCEPT for the one
/// translation a UI framework is not guaranteed to have already done:**
/// ⌃ held with a plain ASCII letter or punctuation mark becomes the
/// standard terminal control byte (`asciiValue & 0x1F` — clearing bits 6
/// and 7, which is what turns `C` into `^C`). This is written defensively
/// rather than assumed necessary: if the caller's `characters` already IS
/// the translated control byte (as `NSEvent.characters` is documented to
/// hand back), its scalar value is already below `0x40` and the `>= 0x40`
/// guard below leaves it untouched — so this is safe whether or not the
/// caller pre-translated it, and is what makes `^C` reach the foreground
/// process group (`TerminalSession.spawn`'s own doc comment on why
/// `forkpty` is what makes that signal land at all).
public func terminalKeyBytes(
    characters: String?, special: TerminalSpecialKey?, modifiers: TerminalKeyModifiers
) -> [UInt8]? {
    guard !modifiers.contains(.command) else { return nil }
    // ⌥← / ⌥→ / ⌥⌫: what Terminal.app ("Use Option as Meta") and iTerm
    // send — zsh and readline bind them to backward-word, forward-word and
    // backward-kill-word (#365 walk).
    if modifiers.contains(.option) {
        if special == .left { return Array("\u{1B}b".utf8) }
        if special == .right { return Array("\u{1B}f".utf8) }
        if special == nil, characters == "\u{7F}" { return [0x1B, 0x7F] }
    }
    if let special {
        switch special {
        case .up: return Array("\u{1B}[A".utf8)
        case .down: return Array("\u{1B}[B".utf8)
        case .right: return Array("\u{1B}[C".utf8)
        case .left: return Array("\u{1B}[D".utf8)
        case .home: return Array("\u{1B}[H".utf8)
        case .end: return Array("\u{1B}[F".utf8)
        case .deleteForward: return Array("\u{1B}[3~".utf8)
        }
    }
    guard let characters, let scalar = characters.unicodeScalars.first else { return nil }
    if modifiers.contains(.control), scalar.isASCII, scalar.value >= 0x40, scalar.value < 0x7F {
        return [UInt8(scalar.value & 0x1F)]
    }
    return Array(characters.utf8)
}

// MARK: - The two-Enter hand-off, decided before the pty ever sees the key

/// What a pending proposal claims from one keystroke, or `nil` for a
/// keystroke it does not claim.
public enum TerminalProposalKeyAction: Sendable, Equatable {
    /// `⏎`. The command goes into the operator's own prompt **unrun**
    /// (`WindowModel.acceptProposal`); a second `⏎` on a prompt with no
    /// proposal pending is what runs it.
    case accept
    /// `⌫`. The proposal is dropped and nothing is written to the shell.
    case discard
}

/// Whether a pending proposal claims this keystroke, ahead of the pty.
///
/// **This is story 23's whole mechanism** — *"`⏎` on a proposal puts the
/// command in my prompt unrun and `⌫` discards it, so that accepting and
/// running stay two separate acts"* — and until the two-axis review it had
/// no keyboard path at all: `TerminalPane.handleKeyPress` claimed `⌘F` and
/// forwarded everything else to the pty, so with a proposal on screen `⏎`
/// submitted whatever the prompt already held and `⌫` sent `0x7F`. The
/// only way to accept was a right-click. The pane's own doc comment
/// claimed otherwise, which made it the worse kind of wrong.
///
/// **Claimed only when a proposal is actually pending.** With none, this
/// answers `nil` for every key including these two, and `terminalKeyBytes`
/// forwards them unchanged — a shell whose `⏎` and `⌫` stopped working
/// because an agent once proposed something would be a far larger defect
/// than the one this closes.
///
/// **Never with `⌃` or `⌘` held.** `^D` and `^H` are the shell's, not this
/// pane's: a modifier combination is a different keystroke, and claiming
/// it here would take readline's own editing keys away from the operator
/// at exactly the moment a proposal is on screen.
///
/// The `characters`/`special` pair is the same one `terminalKeyBytes`
/// takes, so the view translates its framework's key event once and asks
/// both functions in order.
public func terminalProposalKeyAction(
    hasPendingProposal: Bool, characters: String?, special: TerminalSpecialKey?,
    modifiers: TerminalKeyModifiers
) -> TerminalProposalKeyAction? {
    guard hasPendingProposal else { return nil }
    guard !modifiers.contains(.command), !modifiers.contains(.control) else { return nil }
    // A named navigation key is never one of these two. `deleteForward`
    // (fn-⌫) is the one that could be mistaken for `⌫` and is deliberately
    // not: the proposal's own label says `⌫`, and `deleteForward` deletes
    // ahead of the cursor in readline.
    guard special == nil else { return nil }
    switch characters {
    case "\r", "\n": return .accept
    case "\u{7F}", "\u{8}": return .discard
    default: return nil
    }
}

// MARK: - Keyboard ownership (walk defects A1/A2/A3)

/// What the pane's own key handler does with one keystroke, decided
/// **before** the two-Enter hand-off and before the pty — ownership comes
/// first, because a pane that does not hold the keyboard has no business
/// answering `terminalProposalKeyAction` or `terminalKeyBytes` at all.
public enum TerminalPaneKeyClaim: Sendable, Equatable {
    /// ⌘F: toggle the search bar open or closed.
    case toggleSearch
    /// Escape, with search open: close it, clear the query, and return
    /// focus to the terminal.
    case closeSearch
    /// This key is not the pane's — either search is open and it belongs
    /// to the search field, or nothing here claims it. The view returns
    /// `.ignored` either way; which one it was does not change what the
    /// view does with it.
    case notClaimed
    case acceptProposal
    case discardProposal
    case forwardToPty([UInt8])
    /// ⌘V: read the pasteboard; replace the selection with it when the line
    /// is editable and one is active, else paste it (#365).
    case paste
    /// ⌘C over the pane's own input-line selection.
    case copySelection
    /// A printable character (the character), or Backspace / Delete (the
    /// empty string), typed over the selection.
    case replaceSelection(String)
    /// ⇧← (-1) / ⇧→ (+1).
    case extendSelection(Int)
}

/// Whether the pane's key handler claims one keystroke at all, and what it
/// does with it — the root fix for walk defects A1 (⌘F search typing
/// leaked to the shell), A2 (Escape never reached `OrgPlane`) and A3
/// (the same bug, predicted for `ConfirmationPlane`).
///
/// **This is a regression of a bug already fixed once**, and the fix is
/// the same shape as the one it regressed. `OrgPlane.swift:143-165`
/// records the first fix: `.onExitCommand` never received Escape because
/// the org plane took no focus, so `OrgPlane` moved to
/// `.keyboardShortcut(.cancelAction)`, AppKit's window-level key-equivalent
/// search — which does not depend on any view holding first responder.
/// `ConfirmationPlane.ownsEscape` (`ConfirmationPlane.swift:22-37`) then
/// generalised that into an explicit rule: *"a window may hold exactly one
/// live `.cancelAction` at a time"*, arbitrated so that whichever plane
/// draws in FRONT wins Escape and the other stands down. `TerminalPane`
/// never joined that arbitration — it is an ordinary focused view that
/// claims Escape (and only Escape, via `literalCharacters`) unconditionally
/// the moment it holds first responder, which a floating pane inside the
/// same window does whether or not a plane is drawn on top of it. So with
/// a terminal pane focused, Escape reached the pty (as `0x1B`, a real
/// keystroke a shell legitimately wants) and never reached
/// `.keyboardShortcut(.cancelAction)`'s search at all.
///
/// **The fix is about ownership, not about exempting Escape.** Carving out
/// "Escape, unless a plane is up" would have left the exact same class of
/// bug for the next key someone gives a plane — ⌘F was already proof the
/// pane has no notion of a search field either (A1). So: while
/// `isKeyboardOwner` is `false` — a plane or sheet is in front of the
/// canvas — this claims **nothing at all**, not even ⌘F, and returns
/// `nil` so the view answers `.ignored` and AppKit's own key-equivalent
/// search (where `OrgPlane`'s and `ConfirmationPlane`'s buttons live)
/// keeps looking. `isKeyboardOwner` is fed from the same state those two
/// planes are driven by (`WindowModel.showOrgPlane`, `.organization`,
/// `.pending`) — see `TerminalPane.isKeyboardOwner`'s own doc comment —
/// rather than a second, parallel notion of "is something covering the
/// canvas" invented here.
///
/// **With the pane holding the keyboard, ⌘F and search still come first**,
/// exactly as they did before this fix, plus one addition the walk asked
/// for: while `searchOpen`, Escape now closes the search bar instead of
/// reaching the pty (matching the field's own affordance), and **search
/// wins over a pending proposal** — `⏎` goes to the search field, not to
/// `terminalProposalKeyAction`, because a proposal cannot be sitting in
/// front of an open search bar the operator is actively typing into.
public func terminalPaneKeyClaim(
    isKeyboardOwner: Bool, searchOpen: Bool, hasPendingProposal: Bool, characters: String?,
    special: TerminalSpecialKey?, modifiers: TerminalKeyModifiers,
    selectionActive: Bool = false, lineEditEnabled: Bool = false, selectionEditable: Bool = false
) -> TerminalPaneKeyClaim? {
    // Something else — a plane or a sheet — is in front of the canvas.
    // Claim nothing: not ⌘F, not Escape, nothing. `nil` (not `.notClaimed`)
    // because this is a different reason than "search wants this key" —
    // both map to `.ignored` in the view, but keeping them distinct is
    // what makes this function's own tests legible about which rule fired.
    guard isKeyboardOwner else { return nil }

    if modifiers.contains(.command), characters?.lowercased() == "f" {
        return .toggleSearch
    }

    if searchOpen {
        // Escape still belongs to the pane while search is open — it is
        // the search field's own dismissal, never a pty keystroke while
        // the bar is up. Every other key, ⏎ included, is the field's:
        // search wins over a pending proposal.
        if special == nil, characters == "\u{1B}" { return .closeSearch }
        return .notClaimed
    }

    if let claimed = terminalProposalKeyAction(
        hasPendingProposal: hasPendingProposal, characters: characters, special: special,
        modifiers: modifiers) {
        switch claimed {
        case .accept: return .acceptProposal
        case .discard: return .discardProposal
        }
    }

    // #365. After the proposal, so ⏎ and ⌫ still accept and discard one.
    if modifiers.contains(.command) {
        switch characters?.lowercased() {
        case "v": return .paste
        case "c" where selectionActive: return .copySelection
        default: break
        }
    }
    let plain = !modifiers.contains(.command) && !modifiers.contains(.control)
    if lineEditEnabled, plain, modifiers.contains(.shift) {
        if special == .left { return .extendSelection(-1) }
        if special == .right { return .extendSelection(1) }
    }
    // `selectionEditable`: the selection maps to cells of the input line
    // (`terminalLineEdit` is non-nil). A selection that doesn't — the first
    // line of a two-line prompt, a stale one — must not swallow the key.
    if selectionEditable, plain {
        if special == .deleteForward { return .replaceSelection("") }
        if special == nil, let characters {
            if characters == "\u{7F}" || characters == "\u{8}" { return .replaceSelection("") }
            // Printable only: ⏎, ⇥, ⎋ and every C0 byte are below 0x20 and
            // reach zsh, which clears the selection in the pane.
            if let scalar = characters.unicodeScalars.first, scalar.value >= 0x20 {
                return .replaceSelection(characters)
            }
        }
    }

    guard let bytes = terminalKeyBytes(characters: characters, special: special, modifiers: modifiers)
    else { return .notClaimed }
    return .forwardToPty(bytes)
}

// MARK: - The cursor (walk defect D3)

/// Where a cursor overlay belongs inside the live region's own rows, given
/// the pty's cursor position in absolute grid coordinates.
///
/// **`TODO(walk-fix): needs cursor position from TerminalSession.`**
/// `TerminalSession` tracks the cursor already (it has to, to draw the
/// live grid correctly) but publishes neither its row nor its column on
/// `TerminalSnapshot`, and `TerminalSession`/`TerminalStore` are owned by
/// another agent's concurrent edit — this file cannot add the field. What
/// is here is the other half: given a cursor position IF one is ever
/// published, and the absolute grid row the live region's first drawn row
/// corresponds to (`liveRegionStartRow` — the same row `terminalLiveRegion`
/// settled on internally, so this must be handed the identical value
/// rather than recomputed from scratch and risk disagreeing with it),
/// where in the drawn rows the cursor lands.
///
/// `nil` for "draw no cursor" — fed with no cursor position (the seam is
/// not wired yet, so the call site in `TerminalPane.swift` passes `nil`
/// today and draws nothing extra, which is exactly today's behaviour) or
/// with one outside the rows actually being drawn.
public func terminalCursorLocation(
    cursorRow: Int?, cursorCol: Int?, liveRegionStartRow: Int, liveRegionRowCount: Int
) -> (row: Int, col: Int)? {
    guard let cursorRow, let cursorCol, cursorCol >= 0 else { return nil }
    let relativeRow = cursorRow - liveRegionStartRow
    guard relativeRow >= 0, relativeRow < liveRegionRowCount else { return nil }
    return (relativeRow, cursorCol)
}

// MARK: - A block's status, decided once

/// What one block's status glyph is drawn from — the exit-code decision
/// the view used to make in three separate copies (`TerminalPane`'s own
/// `statusGlyph(for:)`, `OperatorRow.statusGlyph`/`statusColor`, and
/// `MirroredRow`'s inline ternary), each free to drift from the others.
public enum TerminalBlockStatus: Sendable, Equatable {
    /// A proposal: it has not run, and it is waiting on the operator's `⏎`.
    case proposed
    /// Open — no exit code yet. A mirrored block is `nil` here for its
    /// whole life until the tool call returns (`TerminalMirror.swift`'s
    /// ruling 4), and an operator block is `nil` between its `C` and `D`
    /// marks.
    case running
    case succeeded
    case failed

    /// The one glyph per status. `…` for running rather than a spinner:
    /// this is drawn in a strip beside a full-screen program's own screen
    /// and in a history that does not animate.
    public var glyph: String {
        switch self {
        case .proposed: return "⏎"
        case .running: return "…"
        case .succeeded: return "✓"
        case .failed: return "✗"
        }
    }
}

/// One block's status. **`origin` is read before `exitCode`**, because a
/// proposal's `exitCode` is `nil` for the same reason a running block's is
/// and the two are not the same state at all.
public func terminalBlockStatus(_ block: TerminalBlock) -> TerminalBlockStatus {
    if block.origin == .proposed { return .proposed }
    guard let code = block.exitCode else { return .running }
    return code == 0 ? .succeeded : .failed
}

// MARK: - The parked history strip

/// The blocks the pane draws in the strip above a full-screen program's
/// screen — the last few, so Wakil's own voice stays alive while `vim`
/// owns the grid below.
///
/// **Mirrored blocks are withheld from THIS STRIP, and from nothing
/// else** (Spec 6 of the two-axis review). Until that review
/// `PaneStore.appendMirrored` deferred the block itself while
/// `screen == .grid`, which kept it out of `read_pane` too — so during a
/// `vim` session the agent could not read back its own commands, and a
/// rendering choice changed what was readable. Story 46 says the opposite:
/// *"mirrored blocks present individually in the snapshot even when the
/// screen groups them, so that a rendering choice never changes what I can
/// read."* The block now reaches `blocks` immediately; what pauses is only
/// its drawing, here, for the few rows above a program that owns the
/// screen. The moment the program lets go, `screen` is `.blocks` again and
/// the full history — mirror included — is what the pane draws.
///
/// **Three, and the operator's own.** The strip is the operator's thread
/// of work kept visible, not a second history; a mirrored block's own
/// recessed treatment (`MirroredBackground`) has no room to survive in a
/// one-line row, and drawing it without that treatment would read as
/// though the agent's command had run in this pane's shell.
public func parkedHistoryBlocks(_ blocks: [TerminalBlock], limit: Int = 3) -> [TerminalBlock] {
    guard limit > 0 else { return [] }
    return Array(blocks.filter { $0.origin != .agent }.suffix(limit))
}

// MARK: - A mirrored group's backfill label

/// Whether **every** block in a collapsed mirrored group was replayed from
/// the transcript, which is what the group row's `· backfilled` label
/// claims.
///
/// **All, not any.** A group holding one replayed block and five live ones
/// labelled `backfilled` would say the agent's last five commands happened
/// before this pane existed, which is false. An empty group is not
/// backfilled — `allSatisfy` on nothing is vacuously true, and a label
/// that appears on a row with nothing in it is a bug, not a vacuous truth.
public func allBackfilledTerminalBlocks(_ blocks: [TerminalBlock], backfilledAt: Date?) -> Bool {
    guard !blocks.isEmpty else { return false }
    return blocks.allSatisfy { isBackfilledTerminalBlock($0, backfilledAt: backfilledAt) }
}

// MARK: - Copy, and Send to thread

/// One block as plain text: the command, and its output beneath it when
/// there is any. `Copy` puts exactly this on the pasteboard.
public func terminalBlockText(_ block: TerminalBlock) -> String {
    var lines = [block.command]
    if !block.output.isEmpty { lines.append(contentsOf: block.output) }
    return lines.joined(separator: "\n")
}

/// The same text, fenced — what `Send to thread` sends to the agent
/// (`WindowModel.send`). The fence is what keeps a block of terminal
/// output from being read as prose by the model on the other end.
public func terminalBlockQuote(_ block: TerminalBlock) -> String {
    "```\n\(terminalBlockText(block))\n```"
}

// MARK: - Reopen (walk-defects B2)

/// The params a dead terminal pane's Reopen control dispatches through
/// `term_open` — the same action the agent and the mouse's own "Open
/// terminal" button use, never a second code path to the shell.
///
/// `path` is `Pane.terminalPath`: the pane's remembered path when it has
/// one. `nil` — a layout saved before that field existed, or a terminal
/// pane that has never been given a path at all — omits `path` entirely
/// rather than guessing, which is what lets `term_open`'s OWN default (the
/// active project's root, else home) apply exactly as it already does for
/// a bare ⌘K dispatch, instead of this call inventing a second fallback
/// that could drift from that one.
public func terminalReopenParams(path: String?) -> JSONValue {
    guard let path else { return .object([:]) }
    return .object(["path": .string(path)])
}
