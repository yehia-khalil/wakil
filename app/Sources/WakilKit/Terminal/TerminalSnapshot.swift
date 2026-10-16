import Foundation

/// The terminal pane's readable state — **both** surfaces, always.
///
/// **`screen` names the one the operator is actually looking at**, and the
/// other is still returned. Returning only the authoritative surface
/// breaks the rule this exists to defend: an agent that read `blocks` a
/// moment ago would find them gone because `vim` opened — exactly the
/// moment it is most likely to be asked *"what went wrong in that
/// build"*, a question about history asked while a pager holds the screen.
///
/// **`grid` is the visible screen only, never scrollback**, bounded by
/// `cols` and `rows`. `snapshot` is not `read_pane`'s path alone — the
/// window refreshes every pane on every change — so an unbounded grid here
/// would be paid for on every keystroke. History lives in `blocks`, where
/// the block cap already bounds it.
///
/// **And it is populated on both surfaces, not only under `.grid`.** For
/// the whole of 2c-iii `TerminalStore.publish` emitted `grid: []` whenever
/// `screen == .blocks`, on the argument that those rows are already in the
/// blocks — which is true of a row already IN a block and false of every
/// row that is not yet one: the prompt, the characters being typed into
/// it, and a running command's output. The operator typed blind and this
/// doc comment's own first sentence was false. Fixed in the final fix
/// wave; the pane draws the block history with those live rows beneath it
/// (`TerminalPane.swift`), and `screen` still names which surface is
/// authoritative.
///
/// **`blocksTruncated` carries the partiality** the way `Rows.Truncated`
/// does for rows: a short history and a trimmed one must never look alike,
/// and the surface that shows the blocks owes the operator that fact with
/// them.
public struct TerminalSnapshot: Sendable, Equatable {
    public let screen: TerminalScreen
    public let cwd: String
    public let shell: String
    public let cols: Int
    public let rows: Int
    public let blocks: [TerminalBlock]
    public let blocksTruncated: Bool
    public let grid: [String]
    /// `grid`'s own colour, one coalesced run-array per row, ALWAYS the
    /// same length as `grid` — never `nil`, unlike a block's `outputRuns`.
    /// A plain row still costs one run (`terminalCoalesceStyleRuns`
    /// answers `[TerminalStyleRun(text: row, style: .plain)]` for a row
    /// with no SGR at all), because this is rebuilt from the live screen
    /// on every dirty frame rather than stored across a 200-block cap —
    /// the memory argument `TerminalBlock.outputRuns` makes for skipping
    /// the trivial case does not apply to a value that never accumulates.
    ///
    /// **Deliberately absent from `TerminalPaneKind.readPane`.** `read_pane`'s wire
    /// shape keeps `grid` as plain text; this field exists only for
    /// `TerminalPane`'s own drawing and is never serialised.
    public let gridStyles: [[TerminalStyleRun]]
    /// The block the surface has been asked to bring into view, or `nil`.
    ///
    /// **A block id, not a row index**, because a terminal pane's unit of
    /// state is the block and its rows move under it as output arrives.
    ///
    /// **Declared with the rest of this type rather than with the action
    /// that sets it** (Task 13) — one inert field for a few tasks was
    /// cheaper than a wire shape that changes twice, once to add the key
    /// and again to fill it, for every reader in between. It is no longer
    /// inert: `term_scroll` writes it (`TerminalActions.swift`) and the
    /// pane consumes and clears it once it has scrolled
    /// (`TerminalPane.swift`'s `BlockHistory`), which is why the action's
    /// own description promises the same block can be asked for twice.
    public let scrollTarget: String?
    /// When this pane's mirror was last backfilled from the transcript —
    /// `term_open` reconstructing the agent's own history into a pane that
    /// predates it — or `nil` if it never has been. **A snapshot-level
    /// marker, not a per-block flag.** `TerminalBlock`'s seven published
    /// keys are the spec's own fixed shape for one command; "was this
    /// batch replayed from history or did it just happen" is a fact about
    /// the BACKFILL, one event, not a property every block would have to
    /// carry a redundant copy of. A block is classified against this
    /// marker by `isBackfilledTerminalBlock` (`TerminalPaneSupport.swift`):
    /// its own `startedAt` at or before this moment means it predates the
    /// pane and was filled in, not streamed live.
    public let backfilledAt: Date?
    /// The absolute row (same coordinate space as `grid` — index 0 is the
    /// top of the visible screen, never scrollback) the operator's
    /// current prompt began on, or `nil` before the first prompt.
    ///
    /// One of the two walk-fix seams (walk-defects list, "the screen row
    /// where the current prompt began"): `TerminalPaneSupport.terminalLiveRegion`
    /// takes this as a parameter already and has since before it existed
    /// here, narrowing the live region to the current prompt onward
    /// instead of redrawing the whole screen. `TerminalSession.promptRow`
    /// is where it is actually decided, off the OSC 133;A mark.
    public let promptRow: Int?
    /// The pty's cursor, in the same coordinates as `promptRow` and
    /// `grid`. `nil` before a window exists to read it from — mirrors
    /// `promptRow`'s own "before the first prompt" absence, though in
    /// practice a spawned session's cursor is always somewhere.
    ///
    /// The other walk-fix seam: `TerminalPaneSupport.terminalCursorLocation`
    /// takes this as two parameters already, and drew nothing because
    /// nothing published it. `TerminalSession.cursorPosition()` is where
    /// it is actually read, off SwiftTerm's own `buffer.x`/`buffer.y`.
    public let cursorRow: Int?
    public let cursorCol: Int?
    /// Whether a command is running **right now** — the third walk-fix
    /// seam, alongside `promptRow` and `cursorRow`/`cursorCol`.
    /// `TerminalSession.commandRunning` is where it is actually decided,
    /// off the same `openBlock` state that later becomes a sealed
    /// `TerminalBlock`.
    ///
    /// **What it changes.** `terminalLiveRegionSlice`
    /// (`TerminalPaneSupport.swift`) reads this to decide what the live
    /// region under the block history IS: while idle (`false`), it is the
    /// current prompt and what has been typed at it, sliced from
    /// `promptRow` and capped at `maxRows` — unchanged from before this
    /// field existed. While a command is running (`true`), it is the
    /// screen a program that never switches to the alternate buffer draws
    /// its whole interface on (`claude`, a small in-place spinner, …), so
    /// the region draws the visible rows themselves rather than an
    /// 8-row tail of them — the defect where a long TUI session was
    /// visible only one line at a time, always overwritten by the next.
    ///
    /// Defaults `false`: every pre-existing call site (a pane with no
    /// shell yet, or one built before this field existed) reads as idle,
    /// which is what they all were.
    public let commandRunning: Bool
    /// The input line when it can be edited by selection, else `nil` —
    /// `TerminalSession.inputLine()` (#365). Not published to `read_pane`.
    public let inputLine: TerminalInputLine?
    /// Whether the shell asked for bracketed paste (#365).
    public let bracketedPaste: Bool

    public static let empty = TerminalSnapshot(
        screen: .blocks, cwd: "", shell: "", cols: 0, rows: 0,
        blocks: [], blocksTruncated: false, grid: [], scrollTarget: nil, backfilledAt: nil,
        promptRow: nil, cursorRow: nil, cursorCol: nil, commandRunning: false)

    public init(
        screen: TerminalScreen, cwd: String, shell: String, cols: Int, rows: Int,
        blocks: [TerminalBlock], blocksTruncated: Bool, grid: [String], scrollTarget: String?,
        backfilledAt: Date? = nil, promptRow: Int? = nil, cursorRow: Int? = nil,
        cursorCol: Int? = nil, commandRunning: Bool = false,
        gridStyles: [[TerminalStyleRun]]? = nil,
        inputLine: TerminalInputLine? = nil, bracketedPaste: Bool = false
    ) {
        self.screen = screen
        self.cwd = cwd
        self.shell = shell
        self.cols = cols
        self.rows = rows
        self.blocks = blocks
        self.blocksTruncated = blocksTruncated
        self.grid = grid
        self.scrollTarget = scrollTarget
        self.backfilledAt = backfilledAt
        self.promptRow = promptRow
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.commandRunning = commandRunning
        self.inputLine = inputLine
        self.bracketedPaste = bracketedPaste
        // `nil` (the default every pre-existing call site still passes)
        // means "no styled form was computed" — one plain run per row,
        // built from `grid` itself, so a caller that never threads colour
        // through still gets a `gridStyles` whose text matches `grid`
        // exactly, not an empty array that would draw nothing.
        self.gridStyles = gridStyles ?? grid.map { [TerminalStyleRun(text: $0, style: .plain)] }
    }
}
