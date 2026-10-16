import Foundation

/// What one pane is currently showing, as a **discriminated union keyed by
/// `kind`** (Decision 24).
///
/// **`kind` is the caller's string verbatim, and it is always present** —
/// `nil` only for a pane id nothing on the canvas holds, which serialises
/// as an explicit `null`. It is normally a `Pane.kinds` member, and one
/// that is not gets no contents and a `failure` naming the kind (#181).
/// `contents` is the pane kind's own snapshot (`PaneKind.Snapshot`).
/// Every key *of the answered kind* is always
/// present, including when false, empty or null: the rule
/// `PaneStore.snapshot` has carried since 2a, unchanged in purpose and
/// narrowed in scope. This object is read by an LLM, and an absent key is
/// something a reader has to know how to interpret while an explicit value
/// is an answer.
///
/// **`failure` is the one kind-independent key**, because any pane can
/// fail to produce what it was asked for.
///
/// **Why this is typed rather than the `JSONValue` it used to be.** The
/// view drew the screen by re-parsing the agent-facing JSON, for every
/// pane on every change. A flat superset was the alternative and it
/// compounds: a terminal pane under one key set would assert
/// `columnTypesInferred: false`, `pageable: false`, `listsTables: false`
/// and eleven more — thirteen tabular facts true only by accident — and
/// every kind added would widen every pane's snapshot for every reader,
/// permanently. A typed union lets the compiler check the arms, and keeps
/// what the round trip was really buying: one sort, applied once, so the
/// agent's rows and the screen's rows are one sequence.
public struct PaneSnapshot: Sendable, Equatable {
    public let kind: String?
    public let failure: String?
    /// The pane kind's own snapshot; `nil` for no contents (no kind, settings, an unknown kind).
    public let contents: (any PaneKindSnapshot)?

    public init(kind: String?, failure: String?, contents: (any PaneKindSnapshot)?) {
        self.kind = kind
        self.failure = failure
        self.contents = contents
    }

    public static func == (a: PaneSnapshot, b: PaneSnapshot) -> Bool {
        guard a.kind == b.kind, a.failure == b.failure else { return false }
        switch (a.contents, b.contents) {
        case (nil, nil): return true
        case let (x?, y?): return x.isEqual(to: y)
        default: return false
        }
    }
}

extension PaneSnapshot {
    public var dataSurface: DataSurfaceSnapshot? { contents as? DataSurfaceSnapshot }
}

extension DataSurfaceSnapshot: PaneKindSnapshot {}

/// The **data surface**'s readable state — the database pane, named for
/// the surface `design-language.md` §8 and `DataSurface.swift` already
/// call by that name.
///
/// **It used to be `GridSnapshot`, and that was a collision with the
/// charter's own vocabulary** (two-axis review, Standards 3). §9 of the
/// north star gives *live grid* to the TERMINAL pane, and
/// `TerminalSnapshot.grid` and `TerminalScreen.grid` are that grid; a
/// second, unrelated `grid` meaning the db pane made one word name two
/// surfaces. `docs/agents/domain.md` forbids drifting from §9's
/// vocabulary, so the db-pane spellings moved and the terminal's stayed.
/// **Nothing renamed here reaches the wire**: `DataSurfacePaneKind.readPane` emits
/// this arm's fields flat (`columns`, `rows`, `rowCount`, …) and never the
/// word `grid`, so the published shape is byte-for-byte what it was.
///
/// Exactly the fields `read_pane` has served since 2c-i, with the same
/// meanings and the same order.
///
/// Every row index here — in `selection`, in `scrollTarget`, and in `rows`
/// itself — is an index into the order currently DISPLAYED, and `sort` is
/// what changes that order.
public struct DataSurfaceSnapshot: Sendable, Equatable {
    public let columns: [String]
    public let columnTypes: [String]
    public let columnTypesInferred: Bool
    public let rows: [[JSONValue]]
    public let rowCount: Int
    public let millis: Int64
    public let truncated: Bool
    public let pageable: Bool
    public let offset: Int
    public let selection: PaneSelection
    public let sort: [PaneSort]
    public let scrollTarget: Int?
    public let listsTables: Bool
    /// `table`, `keyColumns` and `columns` only — never `rowKeys`.
    /// `read_pane` feeds an LLM's context, and five hundred WHERE
    /// fragments buy nothing the key column does not already show.
    public let editable: PaneEditableSummary?
    public let runningSince: Date?
    public let cancelledAfterMs: Int?

    public static let empty = DataSurfaceSnapshot(
        columns: [], columnTypes: [], columnTypesInferred: false, rows: [], rowCount: 0,
        millis: 0, truncated: false, pageable: false, offset: 0, selection: .empty,
        sort: [], scrollTarget: nil, listsTables: false, editable: nil)

    public init(
        columns: [String], columnTypes: [String], columnTypesInferred: Bool,
        rows: [[JSONValue]], rowCount: Int, millis: Int64, truncated: Bool, pageable: Bool,
        offset: Int, selection: PaneSelection, sort: [PaneSort], scrollTarget: Int?,
        listsTables: Bool, editable: PaneEditableSummary?,
        runningSince: Date? = nil, cancelledAfterMs: Int? = nil
    ) {
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnTypesInferred = columnTypesInferred
        self.rows = rows
        self.rowCount = rowCount
        self.millis = millis
        self.truncated = truncated
        self.pageable = pageable
        self.offset = offset
        self.selection = selection
        self.sort = sort
        self.scrollTarget = scrollTarget
        self.listsTables = listsTables
        self.editable = editable
        self.runningSince = runningSince
        self.cancelledAfterMs = cancelledAfterMs
    }
}

/// What the agent is told about writing a pane back — the three facts
/// worth its context, without the per-row WHERE fragments.
public struct PaneEditableSummary: Sendable, Equatable {
    public let table: String
    public let keyColumns: [String]
    public let columns: [String]

    public init(table: String, keyColumns: [String], columns: [String]) {
        self.table = table
        self.keyColumns = keyColumns
        self.columns = columns
    }
}
