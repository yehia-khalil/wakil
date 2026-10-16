import Foundation
import Testing

@testable import WakilKit

@Test func everySubjectRoundTripsThroughJSON() throws {
    let subjects: [PaneQuery] = [
        .sql(database: "main", raw: "SELECT * FROM events"),
        .sql(database: nil, raw: "SELECT 1"),
        .table(database: "main", name: "events"),
        .tables(database: "main"),
        .columns(database: "main", table: "events"),
    ]
    for subject in subjects {
        let fetch = PaneFetch(query: subject, offset: 500, pageSize: 250,
                              sort: [PaneSort(column: "id", direction: .descending)])
        let data = try JSONEncoder().encode(fetch)
        let back = try JSONDecoder().decode(PaneFetch.self, from: data)
        #expect(back == fetch)
    }
}

@Test func aFetchDefaultsToThePageSizeTheDriverAlreadyUses() {
    // 500 is clampReadLimit's "you did not usefully choose" answer, and
    // a pane that asked for something else would page in one size and be
    // capped at another.
    #expect(PaneFetch.defaultPageSize == 500)
    let fetch = PaneFetch(query: .tables(database: nil))
    #expect(fetch.offset == 0)
    #expect(fetch.pageSize == 500)
    #expect(fetch.sort == [])
}

@Test func everySubjectCarriesItsDatabase() {
    #expect(PaneQuery.sql(database: "a", raw: "SELECT 1").database == "a")
    #expect(PaneQuery.table(database: "b", name: "t").database == "b")
    #expect(PaneQuery.tables(database: "c").database == "c")
    #expect(PaneQuery.columns(database: "d", table: "t").database == "d")
    #expect(PaneQuery.sql(database: nil, raw: "SELECT 1").database == nil)
}

@Test func aNonSQLSubjectDescribesItselfRatherThanPretendingToBeSQL() {
    // What the query line shows at rest. A schema browse is not SQL and
    // showing invented SQL for it would be a lie the operator could then
    // edit.
    #expect(PaneQuery.tables(database: nil).describedForOperator == "tables")
    #expect(PaneQuery.columns(database: nil, table: "events").describedForOperator
            == "events · columns")
    #expect(PaneQuery.table(database: nil, name: "events").describedForOperator == "events")
    #expect(PaneQuery.sql(database: nil, raw: "SELECT 1").describedForOperator == "SELECT 1")
}

@Test func pagingMovesTheOffsetByWholePages() {
    let first = PaneFetch(query: .table(database: nil, name: "events"), pageSize: 500)
    #expect(first.page(to: .next).offset == 500)
    #expect(first.page(to: .next).page(to: .next).offset == 1000)
    #expect(first.page(to: .next).page(to: .previous).offset == 0)
    #expect(first.page(to: .first).offset == 0)
}

@Test func pagingBackFromTheFirstPageStaysOnIt() {
    // Not an error and not a negative offset: the control is simply
    // already at the start, and a negative offset would be clamped in Go
    // anyway — this keeps the two from disagreeing about where we are.
    let first = PaneFetch(query: .table(database: nil, name: "events"), pageSize: 500)
    #expect(first.page(to: .previous).offset == 0)
}

@Test func pagingToAnAbsolutePageMultipliesByThePageSize() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"), pageSize: 250)
    #expect(fetch.page(to: .number(3)).offset == 750)
    #expect(fetch.page(to: .number(0)).offset == 0)
    #expect(fetch.page(to: .number(-2)).offset == 0)
}

/// FINAL REVIEW, CRITICAL 2: `db_page(pane:, to: "20000000000000000")` took
/// the whole Wakil process down.
///
/// `page(to: .number(n))` multiplied an unbounded `n` by the page size, and
/// Swift's `*` TRAPS on overflow — SIGTRAP, exit 133, every unsaved layout
/// gone with it. `db_page` is `.read` and therefore on `agentAllowedTools`,
/// so one hallucinated page number was all it took.
///
/// The bound is enforced here, at the arithmetic, so that no caller — the
/// footer's `›`, an agent, a hand-edited layout file — can reach the trap
/// by any route, and not only at `db_page`'s own entrance.
@Test func pagingToAnAbsurdPageNumberIsBoundedRatherThanTrapping() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"), pageSize: 500)
    #expect(fetch.page(to: .number(20_000_000_000_000_000)).offset == PaneFetch.maxOffset)
    // The two other arithmetic branches cannot overflow once the offset
    // itself is bounded, and this pins that they stay bounded too.
    let far = PaneFetch(query: .tables(database: nil), offset: Int.max, pageSize: 1000)
    #expect(far.offset == PaneFetch.maxOffset)
    #expect(far.page(to: .next).offset == PaneFetch.maxOffset)
}

@Test func sortingResetsTheOffsetToZero() {
    // Spec §7. Sorting page three and staying on page three would show
    // rows 1,001-1,500 of a DIFFERENT ordering, which is the same class
    // of lie the section exists against.
    let third = PaneFetch(query: .table(database: nil, name: "events"),
                          offset: 1000, pageSize: 500)
    let sorted = third.sorted(by: PaneSort(column: "id", direction: .ascending))
    #expect(sorted.offset == 0)
    #expect(sorted.sort == [PaneSort(column: "id", direction: .ascending)])
    // `nil` is `pane_sort`'s "the column was omitted" — it clears every
    // term rather than refining, which is why this stays `[]` and not
    // "the previous term untouched".
    #expect(sorted.sorted(by: nil).sort == [])
}

// MARK: - The sort is a list (D5)
//
// The walked failure: sorting by one column drew an arrow on that
// column's header and left the query line alone; sorting by a SECOND
// column made the agent fall back to writing `ORDER BY` into the SQL,
// which moved the sort from the headers into the query line and took the
// arrow away with it. Two individually defensible behaviours, and no rule
// an operator could learn. The cause was that the type held one term.

/// A second sort REFINES the first rather than replacing it — this is the
/// whole fix. Clicking a second column's header means "and then by this",
/// which a single optional term could never express.
@Test func aSecondSortRefinesTheFirstRatherThanReplacingIt() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"))
        .sorted(by: "kind", descending: false)
        .sorted(by: "id", descending: true)
    #expect(fetch.sort.map(\.column) == ["kind", "id"])
    #expect(fetch.sort.map { $0.direction == .descending } == [false, true])
}

/// A column appears at most once. Clicking a header that already sorts
/// flips it in place, rather than adding a second term for the same
/// column — which would be an `ORDER BY` whose later term can never
/// apply. Re-clicking `kind` here is a no-op on position because `kind`
/// is already primary (index 0) both before and after — this test alone
/// cannot distinguish "flip in place" from "promote to primary"; see
/// `reclickingASecondaryColumnFlipsItInPlaceRatherThanPromotingIt` for the
/// one that does.
@Test func sortingByAColumnTwiceFlipsItRatherThanDuplicatingIt() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"))
        .sorted(by: "kind", descending: false)
        .sorted(by: "id", descending: false)
        .sorted(by: "kind", descending: true)
    #expect(fetch.sort.map(\.column) == ["kind", "id"])
    #expect(fetch.sort[0].direction == .descending)
}

/// The test the one above cannot be: re-clicking a SECONDARY column must
/// flip it in place, not promote it to primary. The header draws `▼2` on
/// a secondary column's arrow (Task 15) — an ordinal that is a lie the
/// moment the click behind it reorders the list, because the badge would
/// have named a position the very next click abandons.
@Test func reclickingASecondaryColumnFlipsItInPlaceRatherThanPromotingIt() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"))
        .sorted(by: "kind", descending: false)
        .sorted(by: "id", descending: false)
        .sorted(by: "id", descending: true)
    #expect(fetch.sort.map(\.column) == ["kind", "id"])
    #expect(fetch.sort[1].direction == .descending)
}

// MARK: - Dropping one term, not the whole list (D5, fix round 2)
//
// The walked failure: before `removingSort(column:)` existed, the only way
// `pane_sort` could remove anything was "no column at all", which
// `sorted(by: nil)` answers by clearing the WHOLE list. That was invisible
// while a secondary column had no way to be clicked to removal on its own
// (fix round 1 was still promoting it to primary on every click), and
// became reachable the moment fix round 1 made a secondary column stay
// secondary across its own clicks: sort by `kind`, then `id`, click `id`
// twice — descending, then removed — and `kind` disappeared too, though
// its own header was never touched.

/// Dropping a secondary term leaves the primary in place — the whole
/// point of `removingSort(column:)` existing separately from
/// `sorted(by: nil)`.
@Test func droppingASecondaryTermLeavesThePrimaryIntact() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"))
        .sorted(by: "kind", descending: false)
        .sorted(by: "id", descending: true)
        .removingSort(column: "id")
    #expect(fetch.sort == [PaneSort(column: "kind", direction: .ascending)])
}

/// Dropping the primary term leaves the secondary — which becomes the
/// list's only term, and therefore its first. The header's ordinal is
/// drawn straight off this array's index (`sortIndicator(for:)`), so this
/// IS the renumbering: `id` was drawn `▼2` a moment ago and is bare `▼`
/// now, correctly, because with one term left there is no precedence left
/// to state (Task 15).
@Test func droppingThePrimaryTermLeavesTheSecondaryAsTheOnlyTerm() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"))
        .sorted(by: "kind", descending: false)
        .sorted(by: "id", descending: true)
        .removingSort(column: "kind")
    #expect(fetch.sort == [PaneSort(column: "id", direction: .descending)])
}

/// The blunt instrument is still there, still blunt, and still correct
/// for what IT means: a bare `pane_sort` naming no column — `sorted(by:
/// nil)` — clears every term, not just one. `removingSort(column:)` is
/// the addition; this pins that the wholesale clear it sits beside is
/// unchanged.
@Test func clearingWithNoColumnNamedStillClearsEveryTerm() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"))
        .sorted(by: "kind", descending: false)
        .sorted(by: "id", descending: true)
        .sorted(by: nil)
    #expect(fetch.sort == [])
}

/// Offset still resets on any sort change — unchanged from 2c-ii, and the
/// reason check 5 passes: a sort is over the whole result, so page three
/// of the old ordering is meaningless in the new one.
@Test func aSortStillReturnsToTheFirstPage() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"))
        .page(to: .number(1000))
        .sorted(by: "id", descending: false)
    #expect(fetch.offset == 0)
}

@Test func aFetchDecodedWithANegativeOffsetClampsToZero() throws {
    // Fix round 1: the synthesized decoder used to assign stored
    // properties directly, bypassing the clamp the memberwise init
    // enforces. A hand-edited or future-build layout file carrying a
    // negative offset must not survive decoding unclamped.
    let json = #"""
    {"query":{"tables":{}},"offset":-5,"pageSize":500}
    """#
    let fetch = try JSONDecoder().decode(PaneFetch.self, from: Data(json.utf8))
    #expect(fetch.offset == 0)
}

/// FINAL REVIEW, IMPORTANT 4: an out-of-range page size collapses to 500,
/// which is what `clampReadLimit` does in Go — it does NOT clamp to the
/// nearest bound.
///
/// The two used to disagree outside 1...1000, and the disagreement skipped
/// rows: `limit: 2000` made Go return 500 rows while Swift recorded a page
/// size of 1000, so the next page started at offset 1000 and rows 501-1,000
/// were never shown (spec §13.9, acceptance check 4 — "no row seen twice
/// and none skipped"). `limit: 0` produced the mirror image, a page size of
/// one.
///
/// The intent, not merely the bounds, is what these pin: 1001 yields 500
/// and not 1000, because 500 is `clampReadLimit`'s "you did not usefully
/// choose" answer, and a caller that really wants 1,000 rows asks for
/// exactly 1,000 and gets them.
@Test func aPageSizeOutsideTheDriversRangeCollapsesToFiveHundredExactlyAsGoDoes() {
    let subject = PaneQuery.tables(database: nil)
    #expect(PaneFetch(query: subject, pageSize: 2000).pageSize == 500)
    #expect(PaneFetch(query: subject, pageSize: 1001).pageSize == 500)
    #expect(PaneFetch(query: subject, pageSize: 0).pageSize == 500)
    #expect(PaneFetch(query: subject, pageSize: -1).pageSize == 500)
    // In range, passed through UNCHANGED — clamping everything to 500
    // would silently cap legitimate smaller and larger requests alike,
    // which is the case `TestClampReadLimit` pins on the Go side.
    #expect(PaneFetch(query: subject, pageSize: 1).pageSize == 1)
    #expect(PaneFetch(query: subject, pageSize: 250).pageSize == 250)
    #expect(PaneFetch(query: subject, pageSize: 1000).pageSize == 1000)
}

@Test func aFetchDecodedWithAPageSizeAboveTheCapCollapsesToFiveHundred() throws {
    let json = #"""
    {"query":{"tables":{}},"offset":0,"pageSize":99999}
    """#
    let fetch = try JSONDecoder().decode(PaneFetch.self, from: Data(json.utf8))
    #expect(fetch.pageSize == 500)
}

@Test func aFetchDecodedWithAZeroPageSizeCollapsesToFiveHundred() throws {
    let json = #"""
    {"query":{"tables":{}},"offset":0,"pageSize":0}
    """#
    let fetch = try JSONDecoder().decode(PaneFetch.self, from: Data(json.utf8))
    #expect(fetch.pageSize == 500)
}

/// The offset half of the same rule: a layout file carrying an absurd
/// offset must not decode into one, for the reason Critical 2 records —
/// `page(to:)`'s arithmetic runs on whatever decoding produced.
@Test func aFetchDecodedWithAnAbsurdOffsetIsBounded() throws {
    let json = #"""
    {"query":{"tables":{}},"offset":9007199254740991,"pageSize":500}
    """#
    let fetch = try JSONDecoder().decode(PaneFetch.self, from: Data(json.utf8))
    #expect(fetch.offset == PaneFetch.maxOffset)
}

@Test func aPaneWithAnOutOfRangeOffsetDecodesToAClampedFetch() throws {
    // The tolerance composes with Pane.init(from:)'s try? — an unclamped
    // value on disk must not survive through both decoders. Lives here
    // rather than in PaneTests.swift because it needs no change to
    // Pane.swift itself, only to PaneFetch's own decoding.
    let json = #"""
    {"id":"db-1","kind":"db","title":"main",
     "frame":{"x":0,"y":0,"width":640,"height":420},
     "fetch":{"query":{"tables":{}},"offset":-5,"pageSize":500}}
    """#
    let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    #expect(pane.fetch?.offset == 0)
}

// MARK: - the query line's database chooser (spec §5; final review,
// Important 8)

@Test func aChosenDatabaseWinsUntilThePanesOwnSubjectNamesAnother() {
    // A fresh pane: no subject at all, which is the case acceptance
    // check 3 walks and the one the chooser exists for.
    let fresh = QueryLineDatabaseChoice(database: "warehouse", subjectDatabase: nil)
    #expect(queryLineDatabase(choice: fresh, subject: nil) == "warehouse")
    // Still the operator's, while the pane is still against what it was
    // against when they chose — a page or a sort does not revoke it.
    let onMain = QueryLineDatabaseChoice(database: "warehouse", subjectDatabase: "main")
    #expect(queryLineDatabase(choice: onMain, subject: .sql(database: "main", raw: "SELECT 2"))
            == "warehouse")
    // And dropped the moment the pane's subject names a different one —
    // their own run landing, or an agent re-pointing the pane. The subject
    // is the authority again, so the line cannot advertise a database the
    // pane is not against.
    #expect(queryLineDatabase(choice: onMain, subject: .sql(database: "analytics", raw: "SELECT 2"))
            == "analytics")
    #expect(queryLineDatabase(choice: fresh, subject: .tables(database: "warehouse"))
            == "warehouse")
    // No choice at all is the behaviour that shipped: the subject decides.
    #expect(queryLineDatabase(choice: nil, subject: .sql(database: "main", raw: "SELECT 1")) == "main")
    #expect(queryLineDatabase(choice: nil, subject: nil) == nil)
}

@Test func theChooserReadsTheDatabaseListAndSurvivesAnythingElse() {
    let listed = JSONValue.object([
        "structuredContent": .object([
            "databases": .array([
                .object(["name": .string("main"), "driver": .string("sqlite"),
                         "writable": .bool(false)]),
                .object(["name": .string("warehouse"), "driver": .string("mysql"),
                         "writable": .bool(true)]),
            ]),
        ]),
    ])
    // Declaration order, not alphabetical: `project.json` lists them in an
    // order somebody chose.
    #expect(databaseNames(fromListResult: listed) == ["main", "warehouse"])
    // An environment defining none is an ordinary state, not a failure.
    #expect(databaseNames(fromListResult: .object([
        "structuredContent": .object(["databases": .array([])])])) == [])
    // And nothing else is: a failed dispatch, an error result, a shape
    // this does not recognise — the chooser has nothing to offer and the
    // pane still draws.
    #expect(databaseNames(fromListResult: nil) == [])
    #expect(databaseNames(fromListResult: .object(["isError": .bool(true)])) == [])
    #expect(databaseNames(fromListResult: .string("no")) == [])
    #expect(databaseNames(fromListResult: .object([
        "structuredContent": .object([
            "databases": .array([.object(["driver": .string("sqlite")]),
                                 .object(["name": .string("")])])])])) == [])
}

// MARK: - `queryLineTextAfterRun` (final review, Important 9)

@Test func aRunThatDidNotBecomeTheSubjectPutsTheSubjectBackOnTheLine() {
    // A mutation or a refusal: the pane still holds the query that
    // produced the rows on screen, so that is what the line must show.
    #expect(queryLineTextAfterRun(
        outcome: .leftTheSubjectAlone,
        subject: .sql(database: nil, raw: "SELECT * FROM events")) == "SELECT * FROM events")
    #expect(queryLineTextAfterRun(
        outcome: .leftTheSubjectAlone, subject: .tables(database: nil)) == "tables")
    // A fresh pane whose first statement was an UPDATE has no subject to
    // go back to, and an empty line is honest where the UPDATE is not.
    #expect(queryLineTextAfterRun(outcome: .leftTheSubjectAlone, subject: nil) == "")
    // A read BECAME the subject, so the line is already right and
    // `shouldAdoptSubject` carries it from here.
    #expect(queryLineTextAfterRun(
        outcome: .becameTheSubject,
        subject: .sql(database: nil, raw: "SELECT 1")) == nil)
}

// MARK: - `sortCanBeRecorded` (final review, Important 3)

@Test func aSortIsRecordedOnlyWhereALaterRefetchCouldHonourIt() {
    // A statement whose result can be paged can also carry a pushed
    // ORDER BY — that is the same fact, computed by the gate from the
    // verb it accepted.
    #expect(sortCanBeRecorded(on: .sql(database: nil, raw: "SELECT 1"), pageable: true))
    #expect(sortCanBeRecorded(on: .table(database: nil, name: "events"), pageable: true))
    // An EXPLAIN or a SHOW cannot, so a sort recorded on one is a promise
    // no re-fetch could keep.
    #expect(!sortCanBeRecorded(on: .sql(database: nil, raw: "SHOW VARIABLES"), pageable: false))
    #expect(!sortCanBeRecorded(on: .table(database: nil, name: "events"), pageable: false))
    // The two schema subjects are never pageable and never push a sort
    // either: `refetchPane` hands their sort to `setRows`, client-side.
    #expect(sortCanBeRecorded(on: .tables(database: nil), pageable: false))
    #expect(sortCanBeRecorded(on: .columns(database: nil, table: "events"), pageable: false))
}

// MARK: - `offersDrill` (D2, walked defect: a typed `show tables` opened
// nothing)
//
// The walked failure: asking the agent for the tables gave every row an
// `open` button; typing `show tables` gave a result that was visibly the
// same list and opened nothing.
//
// Wakil still refuses to infer a table list from the SHAPE of the rows —
// the first `SELECT name FROM …` would prove that wrong. The driver
// declares it instead, where the read-only gate already reads the verb.
@Test func aDeclaredListingOffersTheDrill() {
    #expect(offersDrill(subject: .sql(database: "core", raw: "show tables"),
                        listsTables: true) == true)
}

@Test func anOrdinarySelectOffersNoDrill() {
    #expect(offersDrill(subject: .sql(database: "core", raw: "SELECT name FROM tables"),
                        listsTables: false) == false)
}

/// The subject alone must be enough to offer the drill for `.tables`,
/// because `offersDrill` checks `listsTables` FIRST and returns early when
/// it is true — so a call with `listsTables: true` would prove nothing
/// about whether the subject branch beneath it still works.
///
/// **`listsTables: false` here is a combination production never actually
/// produces (final review, Minor 5).** `db_list_tables` and
/// `refetchPane`'s `.tables` case both pass `listsTables: true` explicitly
/// — see `PaneTable.listsTables`'s own doc comment — so in practice the
/// first branch always answers for a `.tables` pane and this test's own
/// `.tables`/`false` pairing never occurs on the walked path. It is kept
/// anyway, deliberately pinning that unreached combination, because it is
/// the only thing guarding the subject branch itself against being deleted
/// as "dead code" — which it is, today, but must keep working the day
/// some caller stops setting the flag.
@Test func theTablesSubjectStillOffersTheDrillWithoutTheFlag() {
    #expect(offersDrill(subject: .tables(database: "core"), listsTables: false) == true)
}

// MARK: - `shouldAdoptSubject` (Task 14 fix round 1)
//
// `DBPane`'s query line used to suppress adopting a changed subject
// whenever its field had focus — "focused" is not "has unsaved edits", and
// nothing clears focus after a plain `onSubmit`, so a line left focused
// after Return never adopted a later change to its own pane's subject (a
// header-click sort's re-query, in particular) and showed a query the pane
// was no longer running. This pure function is the decision `DBPane` now
// calls instead, extracted so a test — not a runbook — catches it going
// wrong.

@Test func anUnsavedEditIsProtectedFromBeingOverwritten() {
    // `text` differs from what was last known to agree with the subject:
    // the operator has typed something not yet submitted.
    #expect(!shouldAdoptSubject(
        currentText: "SELECT 1 WHE", lastRendered: "SELECT 1", incoming: "SELECT 2", refused: false))
}

@Test func anUntouchedLineFollowsTheSubject() {
    // `text` still reads exactly what was last rendered: nothing has been
    // typed since, so the incoming subject may replace it.
    #expect(shouldAdoptSubject(
        currentText: "SELECT 1", lastRendered: "SELECT 1",
        incoming: "SELECT 1 ORDER BY id DESC", refused: false))
}

@Test func anUntouchedLineFollowsTheSubjectEvenWhenNothingChangedAtAll() {
    // Not just the not-equal case above: an untouched line where the
    // incoming description happens to equal what is already shown must
    // still be judged "adopt" — this is a decision about whether edits
    // exist, not a diff against `incoming`.
    #expect(shouldAdoptSubject(
        currentText: "tables", lastRendered: "tables", incoming: "tables", refused: false))
}

@Test func focusPlaysNoPartInTheDecision() {
    // The whole point of the fix: this function takes no focus bit at
    // all, so "the field still has focus after Return" cannot suppress an
    // adopt the way `DBPane`'s original `@FocusState` guard did. An
    // untouched line adopts whether or not anything below it would call it
    // "focused" — there is no parameter here that could even ask.
    #expect(shouldAdoptSubject(
        currentText: "SELECT 1", lastRendered: "SELECT 1",
        incoming: "SELECT 1 ORDER BY id DESC", refused: false))
}

/// The scenario the fix exists for, at the level a test can reach it:
/// `DBPane` lives in `WakilApp`, which has no test target, so this drives
/// `shouldAdoptSubject` over two REAL `PaneFetch` values rather than
/// mounting the view — the same two states a header-click sort's re-query
/// (or an agent's own refinement) puts on either side of `pane.fetch`.
@Test func anUntouchedLineAdoptsAReQueriedPanesNewDescription() {
    let old = PaneFetch(query: .sql(database: nil, raw: "SELECT id FROM events"))
    let new = PaneFetch(query: .sql(database: nil, raw: "SELECT id FROM events ORDER BY id DESC"))
    let lineText = old.query.describedForOperator
    // The line last agreed with `old`'s description and nothing has been
    // typed since — `currentText == lastRendered` — so it must adopt
    // `new`'s description rather than keep showing `old`'s.
    #expect(shouldAdoptSubject(
        currentText: lineText, lastRendered: lineText,
        incoming: new.query.describedForOperator, refused: false))
}

// MARK: - `refused:` (D7 — a refusal leaves the statement to be corrected)

/// The walked failure: typing `upadte events set customer_id = 42 where
/// id = 3` produced the right refusal and then erased the statement,
/// leaving the operator to retype all of it to fix two characters.
///
/// A refused line is an unsaved edit by another name: the text did not
/// become the pane's subject, and it is the only copy of what they meant.
@Test func aRefusedLineIsNotOverwritten() {
    #expect(shouldAdoptSubject(
        currentText: "upadte events set customer_id = 42 where id = 3",
        lastRendered: "upadte events set customer_id = 42 where id = 3",
        incoming: "events",
        refused: true) == false)
}

/// Without a refusal the existing rule is unchanged: an untouched line
/// follows its pane's subject.
@Test func anUntouchedLineStillFollowsItsSubject() {
    #expect(shouldAdoptSubject(
        currentText: "events", lastRendered: "events",
        incoming: "SELECT * FROM events ORDER BY id", refused: false) == true)
}

/// And an edited line is still protected, refusal or not.
@Test func anEditedLineIsStillProtected() {
    #expect(shouldAdoptSubject(
        currentText: "SELECT * FROM ev", lastRendered: "events",
        incoming: "events", refused: false) == false)
}
