import Foundation

/// What a terminal pane holds. **The rendered value only** — the pty
/// master, the child pid and the drain thread are `TerminalStore`'s.
struct TerminalContents {
    var screen: TerminalScreen = .blocks
    var cwd = ""
    var shell = ""
    var cols = 0
    var rows = 0
    var blocks: [TerminalBlock] = []
    var blocksTruncated = false
    var grid: [String] = []
    /// `grid`'s own colour — see `TerminalSnapshot.gridStyles`'s doc
    /// comment for why this is never `nil` once a snapshot is built,
    /// even though it starts `nil` here (no session has published
    /// anything yet).
    var gridStyles: [[TerminalStyleRun]]?
    var failure: String?
    /// The block the surface has been asked to bring into view.
    /// Runtime state, and — like the data surface's row-index twin —
    /// never persisted: a saved one would scroll a pane on launch for
    /// a request nobody made. Written by Task 13's action; declared
    /// here so the wire shape does not change twice.
    var scrollTarget: String?
    /// The one pending proposal, or `nil`. Kept out of `blocks` until
    /// the snapshot is built so that "at most one" is a property of
    /// the storage rather than a rule someone has to remember.
    var proposal: TerminalBlock?
    /// When `WindowModel.backfillMirror()` last replayed the agent's
    /// history into this pane, or `nil` if it never has. Task 16:
    /// carried at this level, once per backfill, rather than as an
    /// eighth key on every `TerminalBlock` — see that type's own "seven
    /// published keys" framing, which this deliberately does not widen.
    var backfilledAt: Date?
    /// The two walk-fix seams — see `TerminalSnapshot`'s own doc
    /// comments on these same three names for what each is and who
    /// actually decides it (`TerminalSession`, via `TerminalStore`).
    var promptRow: Int?
    var cursorRow: Int?
    var cursorCol: Int?
    /// The third — see `TerminalSnapshot.commandRunning`'s own doc
    /// comment. Defaults `false`, matching a pane with no shell yet.
    var commandRunning = false
    var inputLine: TerminalInputLine?
    var bracketedPaste = false

    func snapshot() -> TerminalSnapshot {
        var all = blocks
        if let proposal { all.append(proposal) }
        return TerminalSnapshot(
            screen: screen, cwd: cwd, shell: shell, cols: cols, rows: rows,
            blocks: all, blocksTruncated: blocksTruncated, grid: grid,
            scrollTarget: scrollTarget, backfilledAt: backfilledAt,
            promptRow: promptRow, cursorRow: cursorRow, cursorCol: cursorCol,
            commandRunning: commandRunning,
            gridStyles: gridStyles,
            inputLine: inputLine, bracketedPaste: bracketedPaste)
    }
}

/// The terminal pane: a live shell's blocks, screen and input line (2c-iii).
enum TerminalPaneKind: PaneKind {
    static let names = ["terminal"]
    static var emptyContents: TerminalContents { TerminalContents() }
    static var emptySnapshot: TerminalSnapshot? { .empty }
    // `rerunsSubjectOnRestore` stays false: a terminal's scrollback is session state with nothing to re-run.
    static func snapshot(of contents: TerminalContents, in store: isolated PaneStore) -> TerminalSnapshot {
        contents.snapshot()
    }
    static func failure(of contents: TerminalContents) -> String? { contents.failure }
    static func readPane(_ snapshot: TerminalSnapshot, in store: isolated PaneStore) -> [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        object["screen"] = .string(snapshot.screen.rawValue)
        object["cwd"] = .string(snapshot.cwd)
        object["shell"] = .string(snapshot.shell)
        object["cols"] = .number(Double(snapshot.cols))
        object["rows"] = .number(Double(snapshot.rows))
        object["blocksTruncated"] = .bool(snapshot.blocksTruncated)
        object["grid"] = .array(snapshot.grid.map { .string($0) })
        object["scrollTarget"] = snapshot.scrollTarget.map { .string($0) } ?? .null
        // The two walk-fix seams (walk-defects list): the row `grid`'s
        // current prompt began on, and the pty's own cursor, in that same
        // coordinate space. `null` before a shell has published either —
        // `--dispatch`, a pane with no shell yet, or a build that
        // predates this seam.
        object["promptRow"] = snapshot.promptRow.map { .number(Double($0)) } ?? .null
        object["cursorRow"] = snapshot.cursorRow.map { .number(Double($0)) } ?? .null
        object["cursorCol"] = snapshot.cursorCol.map { .number(Double($0)) } ?? .null
        // The third walk-fix seam alongside the two above: whether a
        // command is running right now, off `TerminalSession
        // .commandRunning`. Never `null` — unlike the row/column fields,
        // it has no "before the first prompt" absence, only `true`/`false`.
        object["commandRunning"] = .bool(snapshot.commandRunning)
        // **The union's own always-present rule** (final review,
        // Important 3): this key was declared on `TerminalSnapshot` and
        // never emitted, so an agent could not tell a replayed mirror
        // batch from a live one — the very distinction the backfill exists
        // to declare. ISO 8601 with fractional seconds, because the
        // classification (`isBackfilledTerminalBlock`) is a comparison
        // against block start times that can land inside the same second.
        object["backfilledAt"] = snapshot.backfilledAt.map {
            .string(terminalTimestamp($0))
        } ?? .null
        object["blocks"] = .array(snapshot.blocks.map { block in
            // `startedAt` is deliberately absent: it exists to order two
            // producers' blocks into one sequence, which this array
            // already is by the time it is read.
            .object([
                "id": .string(block.id),
                "command": .string(block.command),
                "origin": .string(block.origin.rawValue),
                "exitCode": block.exitCode.map { .number(Double($0)) } ?? .null,
                "durationMs": block.durationMs.map { .number(Double($0)) } ?? .null,
                "output": .array(block.output.map { .string($0) }),
                "heldTheGrid": .bool(block.heldTheGrid),
            ])
        })
        return object
    }
}

extension PaneSnapshot {
    public var terminal: TerminalSnapshot? { contents as? TerminalSnapshot }
}

extension TerminalSnapshot: PaneKindSnapshot {}

/// The one date format the terminal's `read_pane` emits — ISO 8601, UTC, with fractional
/// seconds.
///
/// **A formatted string, not an epoch number.** The only consumer is an
/// LLM reading `read_pane`'s answer, and `2026-09-18T11:04:07.412Z` is a
/// value it can reason about against the rest of the pane's prose;
/// `1789628647.412` is one it has to be told how to read.
///
/// `Date.ISO8601FormatStyle` rather than an `ISO8601DateFormatter` held in
/// a global: the formatter class is not `Sendable`, and one shared
/// instance reachable from every connection is exactly the shared mutable
/// state Swift 6 refuses. The style is a value.
func terminalTimestamp(_ date: Date) -> String {
    date.ISO8601Format(.init(includingFractionalSeconds: true))
}
