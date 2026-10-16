import Foundation

/// What a pane is looking at.
///
/// **Four cases, not a SQL string, because a schema browse is a subject
/// too.** `db_list_tables` returns rows; so does `db_describe_table`; so
/// does reading a table whole. Modelling all four the same way is what
/// lets one re-fetch path serve paging, sort-as-re-query and relaunch
/// without a special case for "this pane is showing metadata".
///
/// **`.table` is not a convenience wrapper over `.sql` and cannot be
/// one.** "Everything in `events`" is `SELECT * FROM "events"` on SQLite,
/// backtick-quoted on MySQL, and on Mongo it is not SQL at all —
/// `validateMongoQuery` wants `{"op":"find","collection":"events"}`. The
/// driver renders it (`Conn.ReadTable`); Swift never composes SQL, here or
/// anywhere else in this phase.
public enum PaneQuery: Sendable, Equatable, Codable {
    /// A statement the operator or the agent wrote.
    case sql(database: String?, raw: String)
    /// Every row in one table, rendered by the driver.
    case table(database: String?, name: String)
    /// The database's tables, drawn as rows.
    case tables(database: String?)
    /// One table's columns, drawn as rows.
    case columns(database: String?, table: String)

    /// Which database this subject is against, or `nil` for "the
    /// environment's only one".
    public var database: String? {
        switch self {
        case .sql(let database, _): return database
        case .table(let database, _): return database
        case .tables(let database): return database
        case .columns(let database, _): return database
        }
    }

    /// What the query line shows at rest.
    ///
    /// **A non-SQL subject describes itself rather than rendering as
    /// invented SQL.** Showing `SELECT * FROM events` for a `.table` would
    /// be a statement the operator could then edit by one character and
    /// expect to behave like SQL — which on Mongo it would not. The
    /// description is prose; editing it is how a table pane *becomes* a
    /// `.sql` pane (`DBPane`, Task 14).
    public var describedForOperator: String {
        switch self {
        case .sql(_, let raw): return raw
        case .table(_, let name): return name
        case .tables: return "tables"
        case .columns(_, let table): return "\(table) · columns"
        }
    }
}

/// Whether a pane's rows may be opened into panes of their own — the walked
/// failure: asking the agent for the tables gave every row an `open`
/// button; typing `show tables` into the query line gave a result that was
/// visibly the same list and opened nothing, because the drill keyed on
/// the pane's SUBJECT and a typed statement is a `.sql` subject like any
/// other.
///
/// **Two sources, and neither is the shape of the rows (D2).** The subject
/// answers for `.tables` and `.columns` — the agent's `db_list_tables` and
/// `db_describe_table` paths, which go through `Conn.ListContainers` and
/// produce no `Rows` at all, so there is no `listsTables` to ask there.
/// `listsTables` answers for `.sql`, and is set by the driver from the
/// operator's raw text — `SQLReadListsTables`, beside the read-only gate,
/// which is the only place in Wakil that reads SQL.
///
/// Inferring "a one-column result of table-ish strings is a table list"
/// would be wrong the first time someone ran `SELECT name FROM tables`,
/// and a drill that opens the wrong table is a worse failure than one
/// that is absent — so the SHAPE of the rows never decides this, only
/// what the subject and the driver each declare.
public func offersDrill(subject: PaneQuery?, listsTables: Bool) -> Bool {
    if listsTables { return true }
    switch subject {
    case .tables, .columns: return true
    case .sql, .table, .none: return false
    }
}

/// Whether a pane's query line should adopt `incoming` — the subject's
/// current `describedForOperator` — in place of whatever the line
/// currently shows.
///
/// **The rule is "no unsaved edits", not "no focus" (Task 14 fix round
/// 1).** `DBPane`'s original guard suppressed adopting a changed subject
/// whenever its `TextField` had focus, which means "this field is
/// focused", not "the operator is mid-keystroke" — nothing clears focus
/// after a plain `onSubmit`, so a line that stayed focused after Return
/// (the ordinary case: nothing else took focus) never adopted a LATER
/// change to its own pane's subject, such as the one `pane_sort`'s
/// re-query branch writes when a header click sorts a truncated result.
/// The line kept showing the pre-sort query while the pane ran a
/// different one — a pane misreporting what it is showing, the exact
/// failure the query line exists to prevent.
///
/// **`currentText == lastRendered` is "untouched".** `lastRendered` is
/// whatever the line most recently adopted, or the text as of the
/// operator's own last submit — both are points where the line and the
/// pane's subject are known to have agreed. If the line still reads
/// exactly that, nothing has been typed since, focused or not, and the
/// incoming subject may replace it safely. If it differs, the operator
/// has typed something not yet submitted, and overwriting that mid-edit
/// is 2c-i's original complaint in reverse — a lying title silently
/// rewritten to a different lie.
///
/// `incoming` does not change the decision — this is not a shortcut for
/// "already showing the right thing" — but is named so a call site reads
/// as what it is deciding: whether to adopt `incoming`, given what is on
/// screen and what was last known to agree with the subject.
///
/// **A refusal counts as an unsaved edit (D7).** The operator's text did
/// not become the pane's subject — it was rejected before it could — so
/// the line still holds the only copy of what they meant. Adopting over it
/// would make them retype a whole statement to fix two characters, at
/// exactly the moment they are least inclined to trust the pane.
///
/// A subsequent successful submit clears the refusal, which restores
/// adoption; no new clearing path is introduced.
public func shouldAdoptSubject(
    currentText: String, lastRendered: String, incoming: String, refused: Bool
) -> Bool {
    if refused { return false }
    return currentText == lastRendered
}

/// A database the operator picked on a pane's query line, and the database
/// that pane's subject named when they picked it.
///
/// **The second field is what keeps the choice from going stale** (spec
/// §5, built in the final fix wave). A choice is the operator's intent for
/// the NEXT run, and it holds while the pane is still against the database
/// it was against when they made it. The moment the pane's own subject
/// names a different one — their own run landed, or the agent re-pointed
/// the pane — the subject is the authority again, and a pane running one
/// database while its line advertises another is exactly the lying pane
/// this whole surface exists against.
public struct QueryLineDatabaseChoice: Sendable, Equatable {
    public let database: String
    /// The database the pane's subject named at the moment of the choice,
    /// `nil` for a pane with no subject yet — which is the case a fresh
    /// ⌘K pane presents, and the one acceptance check 3 walks.
    public let subjectDatabase: String?

    public init(database: String, subjectDatabase: String?) {
        self.database = database
        self.subjectDatabase = subjectDatabase
    }
}

/// The database a pane's next run goes against: the operator's own choice
/// while it is still current, and the pane's own subject otherwise.
///
/// A pure function rather than a branch in `DBPane`, for the reason
/// `shouldAdoptSubject` is one: `WakilApp` has no test target and cannot
/// have one, and this decides which database a statement is sent to.
public func queryLineDatabase(
    choice: QueryLineDatabaseChoice?, subject: PaneQuery?
) -> String? {
    guard let choice, choice.subjectDatabase == subject?.database else {
        return subject?.database
    }
    return choice.database
}

/// The database names in a `db_list_databases` result, in the order the
/// environment declares them.
///
/// **Order is preserved rather than sorted**: `project.json` lists an
/// environment's databases in an order somebody chose, and a chooser whose
/// rows are alphabetised is a chooser that puts `analytics` above the
/// `main` everything actually runs against.
///
/// Anything that is not the shape `wakilcore.DatabaseList` marshals —
/// including an error result — yields an empty list rather than a
/// throw: the chooser is one control on a line, and a window that cannot
/// list databases must still draw the pane.
public func databaseNames(fromListResult result: JSONValue?) -> [String] {
    guard case .object(let object)? = result,
          case .object(let structured)? = object["structuredContent"],
          case .array(let entries)? = structured["databases"]
    else { return [] }
    return entries.compactMap { entry in
        guard case .object(let fields) = entry, case .string(let name)? = fields["name"],
              !name.isEmpty
        else { return nil }
        return name
    }
}

/// Each listed database's driver, by name — the query line's dialect source.
///
/// Named `databaseDriverMap` because `databaseDrivers` is already the list
/// of drivers a connection may name (`DatabaseConnection.swift`).
public func databaseDriverMap(fromListResult result: JSONValue?) -> [String: String] {
    guard case .object(let object)? = result,
          case .object(let structured)? = object["structuredContent"],
          case .array(let entries)? = structured["databases"]
    else { return [:] }
    var out: [String: String] = [:]
    for case .object(let fields) in entries {
        guard case .string(let name)? = fields["name"], !name.isEmpty,
              case .string(let driver)? = fields["driver"] else { continue }
        out[name] = driver
    }
    return out
}

/// What a run started from a pane's query line did to that pane's subject.
///
/// The two outcomes are the two halves of spec §9: a `read` BECOMES the
/// pane's subject, while a mutation and a refusal both leave the subject —
/// and the rows it produced — exactly where they were.
public enum QueryLineOutcome: Sendable, Equatable {
    /// A read. `Pane.fetch` now holds what was typed.
    case becameTheSubject
    /// A mutation, or a statement the gates refused. The pane still holds
    /// the query that produced the rows on screen.
    case leftTheSubjectAlone
}

/// The text a pane's query line must show once a run has finished, or
/// `nil` when the line keeps what the operator typed.
///
/// **A pane whose line says one thing while its rows say another is the
/// lying pane the query line exists to prevent** (final review, Important
/// 9). After a confirmed `UPDATE` the line read "UPDATE ..." while
/// `Pane.fetch` still held the `SELECT` that produced the rows on screen,
/// and `shouldAdoptSubject` could not correct it: there were no unsaved
/// edits — `currentText == lastRendered`, both being the UPDATE — so by
/// its own rule the line was untouched and agreed with the subject. It did
/// not. Pressing Return again then re-raised the confirmation plane
/// instead of re-fetching.
///
/// The decision lives here, on values, and not in `DBPane`, for the reason
/// `shouldAdoptSubject` and `PaneTable.offersDrill` live here: `WakilApp`
/// has no test target and cannot have one.
public func queryLineTextAfterRun(outcome: QueryLineOutcome, subject: PaneQuery?) -> String? {
    switch outcome {
    case .becameTheSubject:
        // The line is already showing the truth, and adopting the new
        // subject is `shouldAdoptSubject`'s job, not this one's.
        return nil
    case .leftTheSubjectAlone:
        // A pane with no subject at all goes back to an empty line rather
        // than keeping a statement it did not run — a fresh pane whose
        // first statement was an UPDATE is exactly that case.
        return subject?.describedForOperator ?? ""
    }
}

/// Whether a sort may be RECORDED on a pane's subject, given what that
/// pane's last result reported about being pageable.
///
/// **A recorded sort is a promise that a later re-fetch can keep** (final
/// review, Important 3). `refetchPane` pushes `fetch.sort` into the
/// `query` and `read_table` tools as `"sort": [{"column", "descending"}]`,
/// and `sqlConn.Read` refuses a pushed sort on a result that is not pageable —
/// "this result cannot be paged or re-sorted". So a sort written onto a
/// `SHOW VARIABLES` pane is a sort the pane can never satisfy: every later
/// `db_refetch` fails the same way, and on relaunch `restorePaneContents`
/// swallows the failure and the pane comes back permanently empty.
///
/// `.tables` and `.columns` are the exception, and not by special
/// pleading: `refetchPane` never pushes a sort for either of them — a
/// table list is complete by construction, so its sort is honoured
/// client-side by `setRows` — which is precisely why recording one there
/// is safe and is what makes a sorted schema pane survive relaunch.
///
/// It is a free function on values rather than a branch inside
/// `pane_sort`'s handler for the reason the drill predicate is:
/// a decision left inside a handler (or a view body) is one no test will
/// ever catch going wrong on its own.
public func sortCanBeRecorded(on query: PaneQuery, pageable: Bool) -> Bool {
    switch query {
    case .tables, .columns: return true
    case .sql, .table: return pageable
    }
}

/// Where a pane is in its subject: which page, how big, ordered how.
///
/// **This lives on `Pane` and persists with the layout; the rows it
/// produced live in `PaneStore` and do not.** That split is 2c-i's
/// persistence boundary kept exactly: a pane the operator arranged is a
/// setting, and a result set is a photograph of a database at an instant
/// that may already have passed.
public struct PaneFetch: Sendable, Equatable, Codable {
    /// Which page to move to. Spelled as intent rather than as an offset
    /// so the arithmetic has one home (`page(to:)`) and the footer's ‹ ›
    /// and an agent's `db_page` cannot disagree about what "next" means.
    public enum Page: Sendable, Equatable {
        case first
        case previous
        case next
        /// A zero-based page index.
        case number(Int)
    }

    /// The page size a pane uses unless told otherwise.
    ///
    /// 500 is `clampReadLimit`'s own "you did not usefully choose" answer.
    /// Picking anything else here would make a pane page in one size and
    /// be capped at another, so the last page of every table would be a
    /// surprise.
    public static let defaultPageSize = 500

    /// The furthest a pane may be paged, in rows skipped.
    ///
    /// **It exists to bound arithmetic, not to express a policy about how
    /// deep a table can be read** (final review, Critical 2). `page(to:)`
    /// multiplies a page NUMBER by a page size, and Swift's `*` traps on
    /// overflow rather than wrapping — `db_page(pane:, to:
    /// "20000000000000000")` was 2e16 * 500, SIGTRAP, exit 133, the whole
    /// process gone and every unsaved layout with it. `db_page` is
    /// `.read`, so it is on `agentAllowedTools` and one hallucinated page
    /// number was enough.
    ///
    /// A billion rows skipped is far past any offset a human will page to
    /// and far below `Int.max / 1000`, so `maxOffset * pageSize` cannot
    /// overflow for any page size this type permits. Every offset this
    /// type produces is clamped to it, so no caller can reach the trap by
    /// any route — which is the property that matters, rather than the
    /// particular number.
    public static let maxOffset = 1_000_000_000

    public var query: PaneQuery
    /// Rows skipped before the first one on screen. Never negative.
    ///
    /// **`private(set)`, so the only writers are inside this type** and
    /// every one of them routes through `clampedOffset(_:)` — an
    /// unclamped negative offset must not be reachable by mutating a
    /// `PaneFetch` after construction, which a plain `public var` would
    /// have allowed.
    public private(set) var offset: Int
    /// Rows asked for per page. Always a number `clampReadLimit` would
    /// return unchanged: 1...1,000, and 500 for anything outside that,
    /// because that is what the driver will actually honour.
    ///
    /// **`private(set)`, for the same reason `offset` is.**
    public private(set) var pageSize: Int
    /// The pane's sort intent, in precedence order: index 0 is the primary
    /// key and later terms break its ties. Honoured client-side on a
    /// complete result and pushed into the statement on an incomplete one
    /// — see `pane_sort`'s handler in `StandardActions.swift`, which is
    /// what actually makes the complete-vs-incomplete decision.
    ///
    /// **An array rather than one optional term (D5).** A second header
    /// click means "and then by this", and a single term could not
    /// express it — so the agent fell back to writing `ORDER BY` into the
    /// SQL, which moved the sort from the headers into the query line and
    /// took the arrow away with it. Empty is "no sort".
    public var sort: [PaneSort]

    public init(
        query: PaneQuery, offset: Int = 0,
        pageSize: Int = PaneFetch.defaultPageSize, sort: [PaneSort] = []
    ) {
        self.query = query
        self.offset = Self.clampedOffset(offset)
        self.pageSize = Self.clampedPageSize(pageSize)
        self.sort = sort
    }

    /// Never negative and never past `maxOffset`. The one place that rule
    /// is enforced — `init`, `init(from:)`, `page(to:)` and `sorted(by:)`
    /// all route through this rather than repeating `max(0, ...)` at each
    /// call site. Fix round 1: the synthesized `Decodable` used to assign
    /// `offset` directly, so a layout file carrying a negative offset —
    /// hand-edited, or written by a future build with a different cap —
    /// decoded unclamped. A pane cannot mutate its way around this either,
    /// because `offset` is `private(set)`.
    ///
    /// **The high bound is the fix for Critical 2** — see `maxOffset`.
    /// Bounding only the low end left the multiplication in `page(to:)`
    /// free to overflow, and Swift's `*` traps rather than wrapping.
    private static func clampedOffset(_ offset: Int) -> Int {
        min(maxOffset, max(0, offset))
    }

    /// The page size `clampReadLimit` would answer with, computed the same
    /// way it computes it.
    ///
    /// **Anything outside 1...1,000 collapses to 500, and that is an
    /// intent rather than a bound** (final review, Important 4). Go's
    /// `clampReadLimit` reads "you did not usefully choose" and answers
    /// 500 — it does not clamp to the nearest bound, which is why 1,001
    /// yields 500 and not 1,000 and why 0 yields 500 and not 1.
    ///
    /// This used to be `min(1000, max(1, pageSize))`, and the
    /// disagreement SKIPPED ROWS: `limit: 2000` made Go return 500 rows
    /// while the pane recorded a page size of 1,000, so the next control
    /// asked for offset 1,000 and rows 501-1,000 were never shown. One
    /// rule, stated in two languages, and the two now state the same one.
    private static func clampedPageSize(_ pageSize: Int) -> Int {
        (pageSize <= 0 || pageSize > 1000) ? defaultPageSize : pageSize
    }

    private enum CodingKeys: String, CodingKey {
        case query, offset, pageSize, sort
    }

    /// Decodes through the same clamps `init` enforces, rather than
    /// letting the synthesized decoder assign `offset`/`pageSize`
    /// directly. See `clampedOffset(_:)`'s doc comment for why this
    /// matters: an out-of-range value on disk must not survive decoding.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(PaneQuery.self, forKey: .query)
        offset = Self.clampedOffset(try container.decode(Int.self, forKey: .offset))
        pageSize = Self.clampedPageSize(try container.decode(Int.self, forKey: .pageSize))
        // A layout written before D5's fix holds one sort object where an
        // array now lives. Decode either, because the alternative is a
        // pane silently losing its subject at the first relaunch after an
        // upgrade — the failure `Pane.init(from:)` already guards against
        // for an unknown subject, applied one level down.
        if let terms = try? container.decodeIfPresent([PaneSort].self, forKey: .sort) {
            sort = terms
        } else if let single = try? container.decodeIfPresent(PaneSort.self, forKey: .sort) {
            sort = [single]
        } else {
            sort = []
        }
    }

    /// This fetch moved to another page. Clamped at zero: paging back from
    /// the first page is not an error and not a negative offset, it is a
    /// control that is already at the start.
    ///
    /// Every branch routes through `clampedOffset(_:)` rather than
    /// assigning raw arithmetic, so the invariant has exactly one
    /// enforcement point and a future edit here cannot quietly reopen it.
    ///
    /// **`.number` clamps the page number BEFORE multiplying, and that
    /// order is the whole fix for Critical 2.** `clampedOffset(n) *
    /// pageSize` with the clamp bounding only the low end still overflowed
    /// — and Swift's `*` traps. Bounding `n` to `maxOffset` first makes the
    /// product at most `maxOffset * 1000`, which is four orders of
    /// magnitude below `Int.max`, and the outer clamp then brings the
    /// product itself back inside the bound.
    public func page(to page: Page) -> PaneFetch {
        var next = self
        switch page {
        case .first:
            next.offset = Self.clampedOffset(0)
        case .previous:
            next.offset = Self.clampedOffset(offset - pageSize)
        case .next:
            next.offset = Self.clampedOffset(offset + pageSize)
        case .number(let n):
            next.offset = Self.clampedOffset(Self.clampedOffset(n) * pageSize)
        }
        return next
    }

    /// Applies a click on `column`'s header: a column with no term yet
    /// joins as a new tie-breaker AFTER whatever is already there; a
    /// column that already has one KEEPS ITS POSITION and only has its
    /// direction changed to what was asked. Either way returns to the
    /// first page.
    ///
    /// **The walked failure (D5): sorting by one column drew an arrow and
    /// changed nothing in the query line; sorting by a SECOND column made
    /// the agent fall back to writing `ORDER BY` into the SQL**, which put
    /// the sort in the line as text and made the arrow vanish. Two
    /// defensible behaviours, and no rule an operator could learn. What
    /// was too small was the type: a single optional term cannot express
    /// "and then by this", only "instead sort by this".
    ///
    /// **A brand-new column is APPENDED, not made primary — this is what
    /// lets a first sort survive a second.** Clicking `kind` and then `id`
    /// must leave `kind` primary and `id` breaking its ties, which is
    /// exactly what "and then by this" means; putting the newest click at
    /// the front would demote `kind` on every later click and make the
    /// column that has been sorted longest the one that matters least.
    ///
    /// **Re-clicking a column already in the sort flips it IN PLACE and
    /// keeps each column at most once** — a repeated term would be an
    /// `ORDER BY` whose later mention can never apply. This used to
    /// promote the re-clicked column to primary instead, which was
    /// invisible while a sort held one term (re-clicking the only column
    /// is a no-op on its position either way) and became a live defect
    /// the moment a second term existed: the header draws `▼2` on a
    /// secondary column, precedence order, and precedence is exactly what
    /// promoting on click would silently discard — the badge would name a
    /// position the next click abandons. Position now means "when you
    /// added this term", which is what the ordinal promises the operator;
    /// only a removal — dropping one term (`removingSort(column:)`) or
    /// clearing all of them (`sorted(by: nil)`) — changes how many terms
    /// there are.
    ///
    /// Spec §7: sorting page three and staying on page three would show
    /// rows 1,001–1,500 of a different ordering, which is the same class
    /// of lie the whole section exists against — unchanged by D5, and why
    /// this still resets `offset`.
    public func sorted(by column: String, descending: Bool) -> PaneFetch {
        let newTerm = PaneSort(column: column, direction: descending ? .descending : .ascending)
        var terms = sort
        if let index = terms.firstIndex(where: { $0.column == column }) {
            terms[index] = newTerm
        } else {
            terms.append(newTerm)
        }
        var copy = self
        copy.sort = terms
        copy.offset = Self.clampedOffset(0)
        return copy
    }

    /// Removes just `column`'s own term, leaving every other term in
    /// place and in its own position — the third thing a header click can
    /// ask for, beside "sort by this" and "clear every term".
    ///
    /// **Fix round 2 (Task 15): before this existed, a secondary column
    /// had no way to be cycled off on its own.** The only removal
    /// `pane_sort` could express was "no column at all", which
    /// `sorted(by: nil)` answers by clearing the WHOLE list — correct for
    /// that request, wrong for this one. A secondary column's own cycle
    /// used to bottom out there anyway, because before fix round 1
    /// re-clicking a secondary column promoted it to primary first — so
    /// "drop the term I'm looking at" and "drop the only term there is"
    /// were, once promotion happened, the same request. Fix round 1 made
    /// a secondary column stay a secondary column across its own clicks;
    /// this is what its click needed once that was true: sort by `kind`,
    /// then `id`, click `id` twice — descending, then removed — and
    /// `kind` must still be there, still primary, because the click never
    /// touched it.
    ///
    /// A column not present in `sort` at all is left untouched — dropping
    /// a term that was never there is a no-op, not an error, the same
    /// tolerance `sorted(by:descending:)` extends to a first click.
    public func removingSort(column: String) -> PaneFetch {
        var copy = self
        copy.sort = sort.filter { $0.column != column }
        copy.offset = Self.clampedOffset(0)
        return copy
    }

    /// `pane_sort`'s handler builds a single new term this way, or `nil`
    /// to mean "the column was omitted — remove every term". `nil` clears
    /// the whole list rather than refining, because "remove" is not "add a
    /// term for no column"; a real term is handed straight to
    /// `sorted(by:descending:)`, which is where the refine-in-place logic
    /// actually lives. Dropping a single named term without clearing the
    /// rest is `removingSort(column:)`'s job, not this one's.
    public func sorted(by sort: PaneSort?) -> PaneFetch {
        guard let sort else {
            var copy = self
            copy.sort = []
            copy.offset = Self.clampedOffset(0)
            return copy
        }
        return sorted(by: sort.column, descending: sort.direction == .descending)
    }
}
