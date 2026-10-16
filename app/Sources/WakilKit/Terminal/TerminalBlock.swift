import Foundation

/// Who submitted the command a block records.
///
/// **`proposed` is what earns this field.** Without it in the snapshot the
/// agent cannot tell whether its own proposal was accepted, discarded, or
/// still sitting there — the single thing it most needs to read a terminal
/// pane for. `agent` is a command Wakil ran in its OWN bare-environment
/// shell and is mirroring here; it never ran in this pane's PTY.
public enum TerminalBlockOrigin: String, Sendable, Equatable, Codable {
    /// Spelled `operator` on the wire; `operator` is a Swift keyword.
    case operatorTyped = "operator"
    case agent
    case proposed
}

/// Which surface the operator is actually looking at.
public enum TerminalScreen: String, Sendable, Equatable, Codable {
    case blocks
    case grid
}

/// One submitted command and everything it produced — the terminal pane's
/// unit of state, and the granularity of one terminal action (§9).
///
/// **Captured at its `D` mark into Wakil's own storage, never
/// reconstructed from the emulator's buffer.** OSC 133 marks survive
/// *scrolling*; they do not survive *scrollback eviction*, and a block
/// whose opening mark has been trimmed cannot be recovered from the buffer
/// at all — 6 of 200 were already gone in measurement, 207 of 400 (probe
/// §4.1). Wakil had to scan for the marks itself anyway to recover the
/// exit code, so this is the same work rather than extra work.
public struct TerminalBlock: Sendable, Equatable, Identifiable {
    /// **200 blocks.** The bound is a memory question with numbers: ~112
    /// bytes per held output row measured, so 200 × a 500-line cap is
    /// ~18 MB per pane and 1,000 × 1,000 would be ~86 MB (probe §6.6).
    /// Neither is a drawing problem at any size measured — a `LazyVStack`'s
    /// scroll step is flat at ~5 ms from 2,050 rows to 500,500 — so the
    /// choice is made on memory, and a canvas holds several panes.
    /// Bounded in **blocks, not lines**, because *"the last 200 commands"*
    /// means something to an operator where *"10,000 lines"* does not.
    public static let historyCap = 200
    /// **500 lines inside each block.** The pane reports both bounds on
    /// screen; a trimmed history must never be mistaken for a short one.
    public static let outputLineCap = 500

    /// **Bytes, not lines — the RUNNING block's own bound.** `outputLineCap`
    /// above is only ever applied at the `D` mark
    /// (`capped` below); until then, `TerminalSession`'s open block
    /// accumulates a command's raw pty bytes with nothing bounding it at
    /// all. That was fine for the seconds-long commands this type was
    /// designed around; it stopped being fine once the pane started
    /// hosting long-running interactive programs — a TUI redrawing its
    /// own interface at frame rate for an hour, with no `D` in sight,
    /// grows the open block without limit. This is the bound that closes
    /// that gap, trimmed to the tail on every chunk of output rather than
    /// once at the end (`TerminalSession.trimmedOpenBuffer`).
    ///
    /// **Sized off `outputLineCap` itself, in bytes-per-line, so the two
    /// cannot drift apart.** This type's own `historyCap` doc comment
    /// measured ~112 bytes per held row for a SEALED block's own STRIPPED
    /// plain text (probe §6.6). The open buffer holds the opposite of
    /// that: RAW, unstripped bytes, captured mid a full-screen program's
    /// own redraw — SGR colour and cursor-positioning escapes on every
    /// row, not the plain text `historyCap` was measured against. 2,048
    /// bytes/line is ~18× that measured average — generous enough that no
    /// realistic command whose sealed output would fit within
    /// `outputLineCap` lines ever loses any of it to THIS bound before it
    /// gets there — while still capping a hung TUI's own memory at
    /// `outputLineCap` × 2,048 = ~1,000 KB (0.98 MB) per pane, for as long
    /// as it keeps running, rather than leaving it to grow without limit.
    public static let openBufferByteCap = outputLineCap * 2_048

    public let id: String
    public let command: String
    public let origin: TerminalBlockOrigin
    /// `nil` for a block still running, for a proposal that has not run,
    /// and for one closed by teardown before its shell reported.
    public let exitCode: Int?
    public let durationMs: Int?
    /// **Plain text.** SGR colour codes and other CSI/OSC escapes are
    /// stripped at capture (`TerminalSession.stripEscapeSequences`) so
    /// this value matches its own declared type — a `[String]`, not
    /// attributed text — before it ever reaches the wire or an agent's
    /// context. The live grid the engine draws is built from the raw
    /// bytes regardless; this stripping never touches those.
    public let output: [String]
    /// True when this command REPAINTED its screen rather than PRINTING a
    /// transcript — either by taking the alternate screen (`vim`) or, on
    /// the ordinary screen, by moving its cursor up to redraw a row it had
    /// already left behind (a full TUI like Claude Code, which never
    /// touches the alternate screen at all). See
    /// `TerminalSession.OpenBlock.heldTheGrid` for the two ways in and why
    /// the rule was widened from the first alone. The block still exists,
    /// carrying its command, duration and exit code — four minutes in
    /// `vim`, or an hour in a redrawing TUI, is not silently dropped.
    public let heldTheGrid: Bool
    /// **Not published.** Ordering only: the mirror interleaves the
    /// agent's blocks with the operator's, and both arrive from different
    /// producers.
    public let startedAt: Date
    /// `output`'s own colour, one run-array per line, or `nil`.
    ///
    /// **`nil` for the overwhelmingly common case — a block whose captured
    /// bytes carried no SGR at all — not an empty array.** This is the
    /// representation decision colour for the block history turns on:
    /// runs are stored ALONGSIDE `output` rather than replacing it as the
    /// single source of truth, because (1) `output` stays the untouched
    /// thing `read_pane` and the journal already return — nothing
    /// derives plain text FROM runs, so there is no derivation to drift
    /// from what shipped before this — and (2) the 200-block/500-line cap
    /// was sized against ~112 bytes per held row (this type's own doc
    /// comment); doubling that for every block, including the vast
    /// majority that print no colour at all, would roughly double the
    /// budget the cap was measured against for a feature most commands
    /// never exercise. Bounded instead to blocks that actually used
    /// colour — exactly the ones the operator asked for this feature for.
    ///
    /// When present, `outputRuns.count == output.count` and
    /// `outputRuns[i].map(\.text).joined() == output[i]` for every line —
    /// asserted in `TerminalAnsiColorTests.swift`. Any reader that finds
    /// otherwise (a build with a stale value, or a future bug) should
    /// fall back to `output` rather than trust the mismatch; `TerminalPane`
    /// does exactly that.
    public let outputRuns: [[TerminalStyleRun]]?

    public init(
        id: String, command: String, origin: TerminalBlockOrigin, exitCode: Int?,
        durationMs: Int?, output: [String], heldTheGrid: Bool, startedAt: Date,
        outputRuns: [[TerminalStyleRun]]? = nil
    ) {
        self.id = id
        self.command = command
        self.origin = origin
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.output = output
        self.heldTheGrid = heldTheGrid
        self.startedAt = startedAt
        self.outputRuns = outputRuns
    }

    /// The same block with its output — and, when present, its runs —
    /// trimmed to `outputLineCap`.
    ///
    /// **The tail is kept, not the head.** The end of a build's output is
    /// where its error is; a head-truncated block keeps the part nobody is
    /// asking about.
    public static func capped(
        id: String, command: String, origin: TerminalBlockOrigin, exitCode: Int?,
        durationMs: Int?, output: [String], heldTheGrid: Bool, startedAt: Date,
        outputRuns: [[TerminalStyleRun]]? = nil
    ) -> TerminalBlock {
        TerminalBlock(
            id: id, command: command, origin: origin, exitCode: exitCode,
            durationMs: durationMs, output: Array(output.suffix(outputLineCap)),
            heldTheGrid: heldTheGrid, startedAt: startedAt,
            outputRuns: outputRuns.map { Array($0.suffix(outputLineCap)) })
    }
}
