# Phase 2c-ii — the DB pane in full

**Written:** 2026-09-12 · **Probe:** `docs/wakil/phase-2c-ii-probe.md`, run the same day ·
**Depends on:** 2c-i's data surface, 2b-iii's write gate, 2b-i's pane model and action registry

---

## 0. What this sub-phase is, and what it is not

`north-star.md` §8 splits 2c into five. 2c-i built the surface all four panes draw on and
is met by a walked runbook. This is the second row:

> **2c-ii** — DB pane in full: schema browser, query surface, results drawn on 2c-i, and
> **pagination**.

It builds **one pane type** and **no new pane kind** — `Pane.kinds` stays `["db"]`. It
does not touch `wakil-http`, adds no terminal, and changes nothing about how rows are
*drawn*: `DataSurface` is consumed as 2c-i shipped it, not extended.

**Two things were added to this row during brainstorming, 2026-09-12, and the row in
`north-star.md` is amended to say so** (§11):

1. **The query line runs mutations**, routed to 2b-iii's confirmation plane. The row
   named a "query surface" and a query surface that answers `UPDATE` with a flat refusal
   is a surface the operator will work around rather than through. The write path itself
   is not new — `db_run_mutation` and the gate both exist — only its reachability from a
   pointer.
2. **The routing default inverts.** 2c-i's rule was *focused pane receives, explicit pane
   overrides, no pane opens one*. It becomes *naming a pane refines it, omitting one
   opens a new pane*. §6 gives the reasoning; it is the operator's stated flow, and it is
   the only part of this spec that changes behaviour the 2c-i walk signed off on.

## 1. The one mechanism

Everything this sub-phase delivers is a consumer of one change: **a pane owns its query.**

Four independent-looking features and three items 2c-i left open all reduce to it. Written
out, so the spec is read as one change and not as seven:

| Wants it | Recorded at |
|---|---|
| Pagination — page 2 is the pane's own query at a new offset | `north-star.md` 2c-ii row |
| Sort honesty — "a pane that can re-query re-queries" | `design-language.md` §8; 2c-i spec §6 |
| Relaunch — a pane comes back showing something | `phase-2c-i-acceptance.md` check 2 |
| Routing — "re-running the pane's query updates it; a different question is a new pane" | `phase-2c-i-acceptance.md` check 10 |
| Resolve-on-return — which pane an in-flight query lands in | `phase-2c-i-acceptance.md` check 11 |
| `runQuery` cannot name a database | `phase-2c-i-acceptance.md` §6 |
| Select-by-key, later | `phase-2c-i-acceptance.md` check 4 |

2c-i's own conclusion was already this: *"A pane that re-runs its own query on relaunch is
a pane that owns a query, which is 2c-ii's DB pane — one more consumer of the same
mechanism as sort-as-re-query and pagination."* This spec takes that at its word and
builds the mechanism first.

## 2. The subject, and where it lives

```swift
public enum PaneQuery: Sendable, Equatable, Codable {
    case sql(database: String?, raw: String)
    case table(database: String?, name: String)      // everything in one table
    case tables(database: String?)                   // the database's tables
    case columns(database: String?, table: String)   // one table's columns
}

public struct PaneFetch: Sendable, Equatable, Codable {
    public var query: PaneQuery
    public var offset: Int          // rows skipped; 0 on page one
    public var pageSize: Int        // 1...1000, defaulting to 500
    public var sort: PaneSort?      // the pane's sort intent, §7
}
```

`Pane` gains `fetch: PaneFetch?`, **persisted**, decoded with `decodeIfPresent` exactly as
`density` and `columnWidths` already are, so a layout file written before this field
existed still loads. Everything that says *what to fetch* lives here. `PaneStore` keeps
only what came back — columns, types, rows, millis, truncated — plus view state:
selection, scroll target, and the cached `displayRows`.

**Four enum cases, not a string, because a schema browse is a subject too** (§4). One
`refetch` path then serves SQL, a table, a table list and a column list identically, and
paging and relaunch do not each need a special case for "this pane is showing metadata".

**`.table` is not a convenience wrapper over `.sql` and cannot be one.** "Show me
everything in `events`" is `SELECT * FROM "events"` on sqlite, backtick-quoted on MySQL,
and on Mongo it is not SQL at all — `validateMongoQuery` wants
`{"op":"find","collection":"events"}`. A subject that renders itself per driver is the only
way §4's drill works on all three, and it puts the rendering where `sqlConn.Describe`
already puts its quoting: behind `quoteIdent`, in the driver.

**`PaneSort` moves out of `PaneStore` and into `PaneFetch`.** This is the one piece of
churn on a surface 2c-i just pinned with tests, and it is deliberate: a pane that owns its
query but not its sort is incoherent the moment the sort becomes an `ORDER BY` *inside*
that query, which §7 makes it. There is precedent for the destination —
`pane_set_column_width` already writes to `LayoutStore` rather than `PaneStore`, and for
the same reason, that a column width describes the pane rather than the result.

Consequences, all small and all owed tests:

- `PaneStore.setSort` is deleted. `setRows` and a new `reorder(paneId:sort:)` take the
  sort as an argument, and `PaneStore` retains the value it last ordered by only as part
  of the `displayRows` cache. The authority is `Pane.fetch.sort` and there is exactly one.
- `pane_sort` writes through `LayoutStore` and then asks for a re-fetch or a re-order (§7).
- **`read_pane` and `PaneStore.snapshot` are untouched.** An earlier draft had `readPane`
  merging the sort out of `layout.snapshot()`. That is unnecessary churn on a surface
  2c-i pinned three weeks ago: the cached copy in `PaneStore` is written *only* from the
  authority, which is the same relationship `displayRows` already has to `rows`. What
  keeps the two from drifting is the convention `setRows` already establishes — **no
  parameter has a default** — so a `sort:` argument with no default makes every caller
  state it rather than making the silent path the easy one.
- A sort survives relaunch, which it could not when it lived only in an unpersisted store.

## 3. Pagination — offset in the driver

Keyset paging is not available and it is worth recording why rather than rediscovering it.
The query surface is raw SQL. A join names two tables, an aggregate names none usefully,
and an arbitrary projection may not carry a key at all, so there is nothing to seek on.
The operator's own note on 2c-i check 10 already refused the neighbouring temptation —
*"the implementation must not be parse the SQL and guess the table"* — and guessing a
sort key is the same mistake wearing a different hat.

So: **offset paging, applied by the driver, in Go, where `clampReadLimit` already lives.**

`QuerySpec` gains `Offset int`. In `sqlConn.Read` the order is load-bearing and is the
same order `Write` already establishes:

1. `c.gate(spec.Raw)` — the operator's own text is what the read-only gate judges, before
   anything is wrapped around it. `readonly.go` is 817 lines with five documented bypass
   fixtures and it is not asked to reason about a statement Wakil composed.
2. `clampReadLimit(limit)`, unchanged. The 1,000 ceiling stays. It was never the wrong
   number — the missing thing was a second page, not a bigger first one.
3. Wrap, **only if `Offset > 0` or a server-side sort is being pushed**:
   `SELECT * FROM (<raw>) AS wakil_page ORDER BY <quoted> <dir> LIMIT ? OFFSET ?`
4. `collectRows(rows, limit)` unchanged — it already reads `limit+1` and sets `Truncated`
   from the overshoot, which now reads as **"more rows remain after this page"** at every
   offset rather than only at the first.

**Wrapping is conditional because not every read survives being a subquery, and the probe
says which.** Plain `SELECT`, a `SELECT` carrying its own `LIMIT` or `OFFSET`,
`WITH … SELECT`, a `GROUP BY` aggregate, a `UNION`, and a query with its own `ORDER BY` all
wrap correctly at both offsets on sqlite and MySQL — **and the declared column types survive
the subquery unchanged**, `INT VARCHAR TINYINT DATETIME` through a wrap, which is what keeps
§8's chip rule failing the way it is meant to. `EXPLAIN` fails wrapped on both engines and
`SHOW TABLES` fails on MySQL, and the gate **permits both**: its own refusal message is
*"only SELECT/EXPLAIN/SHOW queries are allowed"*. `PRAGMA` is not a case — the gate refuses
it before paging is reached.

**So some gate-approved reads are unpageable, and the gate already knows which.** It
necessarily distinguishes the three verbs it accepts, so `Rows` gains `Pageable bool`, set
from that verb: `SELECT` and `WITH` yes, `EXPLAIN` and `SHOW` no. That is a fact the gate
computed rather than a new guess about SQL, and it costs one field. An unpageable result is
never wrapped, and its footer says so instead of offering a control that returns
`Error 1064 … near 'SHOW TABLES) AS wakil_page LIMIT 3 OFFSET 0'`.

Page one is therefore byte-for-byte the statement 2c-i ran, and only a request that
genuinely needs an offset or a pushed sort pays the wrapping risk at all.

`.table` and the two schema subjects page through the same offset, but they never need
wrapping: Wakil composed those statements and can compose them with `LIMIT`/`OFFSET`
already in place.

Mongo pages the same way through its own path: `find` gains `SetSkip(offset)`, `aggregate`
gains a `$skip` stage appended **before** the existing `$limit` stage. While there,
`driver_mongo.go`'s inline `if limit <= 0 || limit > 1000 { limit = 500 }` is replaced by a
call to `clampReadLimit` — it is a copy of that function, and a cap that has to be changed
in two places is a cap that will one day be changed in one.

**The footer does not report a total.** It reads `rows 501–1,000 · more remain`, and on the
last page `rows 1,001–1,006 · end`. A total needs `SELECT count(*) FROM (<raw>)` — a second
full scan, which on a large table is the expensive half of the operation, and which can
honestly disagree with the page beside it because the two ran at different instants. §8's
whole argument is that a data surface must not claim more than it knows; "more remain" is
exactly what `Truncated` knows.

## 4. Schema browsing is the data surface

There is no schema browser widget, no tree, and no sidebar. `design-language.md` §1 forbids
sidebars and §11 lists Database as a single non-tabbed pane; both stand unamended, because
the schema is already tabular:

| Subject | Rows |
|---|---|
| `.tables(database:)` | one row per table — name, kind |
| `.columns(database:table:)` | one row per column — name, type, key |

Both are served by Go tools that **already exist** — `list_tables` and `describe_table` on
`cmd/wakil-db` — and which today are reachable only as raw `mcp__wakil-db__*` passthrough,
with no Swift action wrapping them and so no pointer path and no journal entry. Two new
actions fix that (§10) and write rows into a pane through `PaneStore.setRows`, the same
call `db_run_query` makes. **No new view code.**

**The drill affordance.** §8 permits "hover-revealed row actions" and has never had one. On
a pane whose subject is `.tables`, hovering a row reveals a single action that opens a new
pane on **`.table(database:, name:)`** — the subject, not a statement. On a `.columns` pane,
the same action on the pane's own table.

Swift never composes SQL for this. The drill dispatches `db_read_table` with a table name,
and the driver renders it: `sqlConn` as `SELECT * FROM <quoteIdent(name)>`, `mongoConn` as a
`find` with an empty filter. That needs a third method on the `Conn` interface beside
`Describe` and `Read`, and it is the right place for it — `Describe` already establishes
that "given a table name, do the dialect-correct thing" is the driver's job, and that
`quoteIdent` is the sole guard on that path.

## 5. The query line

`Canvas.paneView` acquires its first `switch pane.kind`. It is worth naming that as a
structural moment: since 2b-i every pane has drawn the same thing, and `pane.kind` has been
read in only three places, none of them a view. 2c-iii, 2c-iv and 2c-v each add an arm.

A `DBPane` view composes three bands:

```
┌─ database ▸ SELECT * FROM events WHERE kind = 'login'      ──┐   query line
│                                                              │
│  ID    KIND     CREATED_AT                                   │   DataSurface, unchanged
│  …                                                           │
│                                                              │
└─ ‹ ›  rows 501–1,000 · more remain · 41 ms · read-only   ────┘   footer + page controls
```

- **Monospace, plain, single line, no syntax highlighting and no autocomplete.** §11's
  editor is Monaco-based and is its own pane; a second half-built code editor inside the DB
  pane is the duplication that section exists to prevent.
- **Return runs it into this pane** — not ⌘↩, and the probe is why. A
  `Button(…).keyboardShortcut(.return, modifiers: .command)` per pane is **window-scoped and
  not even focus-biased**: with focus in `db-2`'s field it fired `db-1`'s button, as it did
  with focus in the window's own message field. Typing in one pane would silently run
  another pane's query. `.onSubmit` on the focused field routed correctly in all three
  positions, message field included. ⌘↩ was chosen to keep Return free for newlines, and a
  single-line field has none — the constraint never existed. **No per-pane
  `.keyboardShortcut` anywhere in this pane;** if ⌘↩ is added later it is *one*
  window-level shortcut dispatching to the focused pane id. The pointer path always names
  its own pane, so hand editing can never spray panes (§6).
- **The database is part of the line**, chosen from `db_list_databases`. This closes 2c-i
  §6's open item that `runQuery` takes no database and is therefore unusable in any
  environment defining more than one. `WindowModel.runQuery(_:)` gains a `database` and a
  `pane`, matching `runMutation`, which has had one all along.
- **On a non-SQL subject the line shows the subject, not SQL** — `database ▸ events`,
  `database ▸ tables`, `database ▸ events · columns`. Editing it into SQL is how a table
  pane or a schema pane becomes a query pane, which is the same object it always was, and
  it is also the only way to say "this table, but filtered" — which is the first move in
  the operator's flow in §6.

The query line is what makes the pane's identity visible, and that visibility is load-
bearing for §6: 2c-i's complaint was *"a pane titled EVENTS showing customer rows has a
lying title"*, and the fix for a lying title is to show the query rather than to guess a
better title.

## 6. Routing — naming a pane means "this belongs in that pane"

The operator's flow, stated 2026-09-12: *query table A, add a filter on id, add a filter on
name, sort by timestamp* — all one pane, because it is one subject being refined. Then
*query table B* — a new pane, because it is a different subject.

**Wakil does not decide which of those it is. The agent declares it, and it declares it by
naming a pane or not.**

| Call | Lands |
|---|---|
| `db_run_query(pane: "db-1", …)` | replaces `db-1`'s rows and becomes `db-1`'s subject |
| `db_run_query(…)`, no `pane` | opens a new pane |
| `db_refetch(pane: "db-1")` | re-runs `db-1`'s own subject |

This inverts 2c-i's default, and the inversion is the point. Both defaults fail an agent
that forgets, so the choice is between which failure is cheaper: a stray pane is closable
and costs nothing, while a clobbered pane destroys the filter chain the operator built —
the subject as well as the rows. The asymmetry runs the same way in likelihood: when
refining, the agent has just read `pane: db-1` off the previous result and has the id in
hand; when starting a new subject it has no pane in mind, and omitting is the natural
thing to do.

No new parameter is added, because naming a pane already means what the new parameter would
have meant. What is added is that **`db_run_query`'s description states the rule**, and its
result already returns the pane id — so an agent asked to "be smart about this" is told the
rule and handed the identifier the rule needs, which is the same remedy the 2c-i walk found
sufficient when the agent misread row indices and adapted the moment it was told.

Two consequences, both improvements:

- **Resolve-on-return dissolves** (2c-i check 11). A query with an explicit pane targets
  that pane whether or not focus moved; a query without one opens a pane that did not exist
  when the query was sent, so there is nothing for a refocus to race.
- **`queryTargetPane`'s focused-pane fallback is deleted.** Its remaining job is validating
  an explicit id, which `db_run_query` already does against `layout.snapshot()`.

## 7. Sort — who owns the answer now

`design-language.md` §8: *"A pane that can re-query re-queries; one that cannot sorts what
it holds and the footer reads sorted by X within the N returned."* This is the pane that
can. The rule:

| The result is | Sorting it | Footer |
|---|---|---|
| complete (`!truncated`, `offset == 0`) | client-side, `sortedRows` unchanged | silent about the sort |
| incomplete (truncated, or `offset > 0`) | re-fetch at offset 0 with a pushed `ORDER BY` | silent **if** that re-fetch came back complete; otherwise "sorted by X within the N returned" |

**Client-sorting a complete result is not a shortcut, it is the correct answer.** When every
row that matches is already in hand, ordering them locally produces exactly what the engine
would return, without a round trip. The dishonesty §8 names only exists when the rows on
screen are a subset.

**The probe corrected this section.** An earlier draft had the admission disappearing from
this pane entirely, on the reasoning that the pane either sorts everything or re-queries.
It does not, because **a re-query can come back truncated too.** An outer `ORDER BY` cannot
see past an inner bound: `SELECT id, kind FROM events LIMIT 4` wrapped with
`ORDER BY 1 DESC` returns the reverse of *rows 1–4*, not the last four of the table. So a
statement the operator bounded at 5,000 rows, capped by `clampReadLimit` to 500 and then
re-fetched with a pushed sort, is a sort over 5,000 rows showing 500 of them — still a
subset, still owed the warning.

The rule that covers both causes without having to tell them apart: **a sorted result that
is still `truncated` admits it.** One condition, computed from what came back, and it does
not care whether the bound was Wakil's or the operator's.

Two more things follow. First, `sortedRows` is not deleted — its doc comment says 2c-ii
"replaces this call for the DB pane", and the more precise statement is that 2c-ii adds the
other branch. The comment is corrected. Second, the ▲/▼ in the header remains the only
sort indicator on a complete result — which 2c-i's walk recorded as easy
to miss at 9pt and asked 2c-ii to decide deliberately. It is decided deliberately and left
alone: the footer line is a warning, and a pane that has no warning to give should not
manufacture one. §13's runbook asks the operator to look at it again with a re-query in
play and say whether that still holds.

A re-fetch resets the offset to zero. Sorting page three of an unsorted result and staying
on page three would show rows 1,001–1,500 of a *different* ordering, which is the same
class of lie the whole section exists against.

## 8. Relaunch — the pane re-runs

Operator's ruling, 2026-09-12: a restored pane **re-runs its query automatically** and
comes back showing rows.

`Pane.fetch` persists through `LayoutPersistence`, so the subject, the offset, the page
size and the sort survive. On window construction, each `db` pane with a fetch dispatches
`db_refetch` through the registry — through the registry, not around it, so the journal
records the relaunch fetch with an origin like every other state change.

**The risk this carries, recorded rather than designed around.** Launching Wakil now issues
queries on its own, and if the restored environment is `production` and eight panes wake at
once, that is eight unasked-for reads against production the instant the app opens. Every
one of them passes the read-only gate, so nothing is written and nothing is destroyed;
what is spent is load and time. The operator chose this with the alternative (restore the
query, wait for ⌘↩) in front of them. §13's runbook walks it on `production` with several
panes open, and §15 keeps it as an open item so that a later decision to gate it by
environment is a change of mind and not a discovery.

## 9. Mutations from the query line

Typing `UPDATE events SET kind = 'x' WHERE id = 1` into the query line and being told
"read-only" is a surface the operator works around. So the line routes it, and it routes it
**without classifying the statement itself**.

1. The line **asks first**: a new `.read` action `db_classify_statement`, over a new
   `classify_statement` tool on `cmd/wakil-db`, answers `read` / `mutation` / `neither`.
   The answer comes from `AssertSQLReadOnly` and `AssertSQLMutation` — the same two
   functions that will judge the statement for real — and it needs no database connection,
   only the driver kind, so it costs a local call rather than a round trip to an engine.
   A Mongo database routes to `AssertMongoReadOnly`, and a Mongo write answers `neither`
   because `mongoConn.Write` is honestly unimplemented.
2. `read` dispatches `db_run_query`; `mutation` dispatches `db_run_mutation`; `neither`
   shows the gate's own sentence and runs nothing.
3. `db_run_mutation` is `.mutate`, so `ActionRegistry.dispatch` parks it in
   `ConfirmationBroker` and 2b-iii's confirmation plane rises. Nothing about the gate, the
   broker, the plane or the journal changes.

**This replaces an earlier draft that ran the query, caught the refusal, and offered to
re-run it as a mutation.** Two reasons it changed. It showed the operator a refusal that
was never news — they typed `UPDATE`, they know — and then asked them to dismiss it. And
it required the refusal to become machine-readable on the wire: `UserError` carries a
message and nothing else, `callChecked` collapses every `isError: true` into
`.serverError(message)`, and the only way to tell "this is a write" from "this table does
not exist" would have been to match on the message text, which is the heuristic this
section exists to refuse. Asking before running needs none of that plumbing and puts the
answer in the same two functions that enforce it.

**No regex, no SQL parsing in Swift, no "looks like a write" heuristic.** The 817-line gate
with its documented bypass fixtures stays the only thing in Wakil that decides what a
mutation is, and it decides it once. A Swift-side classifier would be a second answer to
that question, and the first time the two disagreed, the disagreement would be a
security-relevant one.

A mutation's result is a `Written`, not a `Rows`. It does not replace the pane's subject and
does not clear its rows. The pane reports the outcome — rows affected, or honestly that the
count is unknown — and leaves what was on screen alone, which is also what makes the obvious
next move (re-run the query to see the change) a `db_refetch` on a pane that still knows
what it was showing.

## 10. Dual-drive: the actions

Invariant 2, and 2a's acceptance check that the same action from the pointer and from the
agent differs in nothing but `origin`.

**New:**

| Action | Kind | Params | Does |
|---|---|---|---|
| `db_list_tables` | `.read` | `database`, `pane` | sets the pane's subject to `.tables` and draws the table list |
| `db_describe_table` | `.read` | `database`, `table`*, `pane` | sets the subject to `.columns` and draws the column list |
| `db_read_table` | `.read` | `database`, `table`*, `pane` | sets the subject to `.table` and draws its rows |
| `db_classify_statement` | `.read` | `database`, `statement`* | `read` / `mutation` / `neither`, from the gates themselves (§9) |
| `db_refetch` | `.read` | `pane`* | re-runs the pane's own subject at its current offset and sort |
| `db_page` | `.read` | `pane`*, `to`* (`next`/`prev`/`first`/an integer) | moves the offset and re-fetches |

All six are `.read` rather than `.control`: each reaches a database. `.control` is for
state that never leaves Wakil, which is why 2c-i's six pane-content actions are `.control`
and these are not. `db_page` is named for the db group rather than as `pane_page` because
paging is a re-query; when 2c-iii or 2c-iv wants paging it will want it over a different
transport, not this one.

**Changed:**

- `db_run_query` — routing per §6; records the pane's subject; description states the
  routing rule and the page size.
- `pane_sort` — writes the sort through `LayoutStore`; re-orders or re-fetches per §7.
- `pane_select_cell` / `pane_select_rows` — unchanged. **Selection stays by index**, and
  2c-i's recorded note stands: an index is a position, not an id. Select-by-key is not
  merely unbuilt, it is unreachable: `Column.Key` is declared in `dbdriver.go` and **no
  driver populates it** — `sqlConn.Describe` reads `rows.ColumnTypes()`, which does not
  report keyness, and `mongoConn.Describe` reads one document. §15 keeps it.
- `cmd/wakil-db` gains `queryArg.Offset`, and **one new tool, `read_table`**
  `{database, name, limit, offset, sort}`, backed by a new `Conn.ReadTable`; and
  `classify_statement` `{database, statement}` (§9). Two tools rather than one `query`
  tool with mutually exclusive modes. `cmd/wakil-db/schema_test.go`'s tool list gains both
  — that list is a live `ListTools` round trip and will fail until it does.

**Pointer paths, each reaching the same action:** Return in the query line → `db_run_query`
with this pane; ‹ › in the footer → `db_page`; a header click → `pane_sort`; the hover
action on a table-list row → `db_read_table` with no pane; the refusal affordance →
`db_run_mutation`.

## 11. What this changes in existing documents

- **`north-star.md` §8, the 2c-ii row** — gains the two scope amendments from §0: the
  query line routes mutations to the confirmation plane, and the routing default inverts.
  Both were agreed during brainstorming on 2026-09-12 and both widen the row as written.
- **`design-language.md` §8** — gains the pagination footer form (`rows 501–1,000 · more
  remain`) and the ruling that a data surface reports no total it would have to spend a
  second scan to learn. Its sort paragraph is left exactly as written: this is the pane it
  was written in anticipation of, and it turns out to be right.
- **`design-language.md` §11** — the Database row gains the query line, and the note that
  the DB pane is still not multi-tabbed: a second query is a second pane, which is what
  §10's canvas is for.
- **`design-language.md` §1** — unamended, and worth saying so in the spec rather than
  silently: the schema browser was built as §8's own surface (§4) precisely so that "no
  sidebars" did not have to be renegotiated for it.
- **`PaneContents.swift`'s `sortedRows` doc comment** — corrected per §7. It says 2c-ii
  replaces this call for the DB pane; 2c-ii adds the other branch and keeps this one.

## 12. The probe — run, and it changed three sections

`docs/wakil/phase-2c-ii-probe.md`, 2026-09-12, against sqlite, MySQL 8 and Mongo 7 plus a
hosted window. Both questions are answered and all three findings landed in the spec above:

1. **Wrapping is safe and type-preserving on every read that matters** — but `EXPLAIN` and
   `SHOW` are gate-approved reads that cannot be wrapped, so §3 gains `Rows.Pageable`, set
   from the verb the gate already distinguishes.
2. **A per-pane `.keyboardShortcut` sends ⌘↩ to the wrong pane** — first-registered wins,
   regardless of focus — so §5 submits on Return via `.onSubmit`.
3. **A partial sort still has to be admitted**, because an operator's own `LIMIT` recreates
   the condition `clampReadLimit` used to be the only cause of — §7 corrected.

None of the three was visible to a test, and the second was invisible to any test that
could exist: `WakilApp` has no test target and cannot have one. Same shape as 2c-i's four
causes of one symptom, found the same way, before a line of 2c-ii was written.

**One thing the probe left unsettled, and the runbook inherits it.** Its window was
offscreen and never became key, so ⌘↩ arrived through an explicit
`performKeyEquivalent(with:)` rather than through `NSApplication.sendEvent`. That is the
same chain AppKit runs and first-registered-wins is its documented behaviour, but §13's
walk should press ⌘↩ on a real key window with two panes open and confirm it.

The questions as they were asked, for the record:

1. **What survives being wrapped?** Against sqlite, MySQL and Mongo: a plain `SELECT`; a
   `SELECT` carrying its own `LIMIT`; a `WITH … SELECT`; an aggregate with `GROUP BY`; a
   `UNION`; `SHOW TABLES` and `EXPLAIN`; a Mongo `find` and an `aggregate` that already
   ends in `$limit`; and `ReadTable` at an offset on all three. For each: does `SELECT * FROM (<raw>) AS wakil_page LIMIT ? OFFSET ?`
   return the right rows, the right column types, and a usable error when it cannot. The
   answer decides whether §3's conditional wrapping is enough or whether some reads must be
   marked unpageable and say so in the footer.
2. **Does ⌘↩ inside a pane-hosted text field reach the pane?** A canvas of panes over a
   Metal layer, with the window's own message field also wanting the return key. Pane focus
   has been wrong once already — `583cc1d` fixed focus on the canvas during 2b-iv — and a
   query line that steals typing from the message field, or never receives it, is the kind
   of defect that is invisible to a test target that cannot import `WakilApp`.

## 13. Testing

In `WakilKitTests`, which needs no display:

1. `PaneFetch` round-trips through `LayoutPersistence`, all four subject cases, **and a
   layout file written before the field existed still decodes** — the tolerance
   `Pane.init(from:)` already establishes for `density`.
2. The sort decision: a complete result sorts client-side and issues no fetch; a truncated
   one and an offset one each produce a re-fetch at offset 0 with the sort pushed — and a
   re-fetch that comes back still truncated reports "within the N returned" (§7), which is
   the case an operator's own `LIMIT` creates.
3. Page arithmetic: `next`/`prev`/`first`/absolute against a page size, clamped at zero,
   and `prev` from page one is a no-op rather than a negative offset.
4. Routing: `db_run_query` with a pane refines it; without one, a pane is opened; an
   explicit unknown pane still throws `unknownPane` as 2c-i established.
5. `read_pane` reports the sort after it moved stores, with every key present including
   when null — the shape 2c-i pinned, assembled from two stores.
6. The four new actions dispatch identically from `.ui`, `.agent` and `.debug` and journal
   identically — 2a's acceptance check in its 2c-ii form.
7. The mutation route: `db_classify_statement` answers `read` for a `SELECT`, `mutation`
   for an `UPDATE`, `neither` for a `DROP`; a `mutation` answer dispatches
   `db_run_mutation` and parks a proposal in the broker, and the pane's rows and subject
   are untouched by either outcome.

In Go, `internal/wakilcore`:

8. Gate-before-wrap: a statement the read-only gate refuses is refused on its own text, and
   the wrapped form is never built — asserted by the gate seeing the raw string.
9. Offset and truncation across page boundaries on sqlite: 1,006 rows at page size 500
   yields `more remain`, `more remain`, `end`, with no row seen twice and none skipped, and
   paging past the end returns zero rows with the columns intact rather than an error —
   which is what the probe recorded both engines doing.
10. `clampReadLimit` is now the only cap: `driver_mongo.go` calls it, pinned by a test that
    fails if the inline copy comes back.
11. Mongo `$skip` precedes `$limit` in a composed pipeline, including one that already
    ended in `$limit`.
12. `ReadTable` renders per driver: `quoteIdent` is the sole guard on the sqlite and MySQL
    paths — the injection fixture `sqlconn_test.go` already aims at `Describe`, pointed at
    the new method — and the Mongo path composes a `find` with an empty filter.
13. `classify_statement` answers from the real gates: `read` for `SELECT`/`WITH`/`SHOW`,
    `mutation` for `INSERT`/`UPDATE`/`DELETE`, `neither` for `DROP` and for a Mongo write —
    and it opens no connection, pinned by running it against a database whose credential
    does not exist.
14. `Rows.Pageable` is false for `SHOW TABLES` and for an `EXPLAIN`, true for a `SELECT`
    and a `WITH … SELECT`, and an unpageable result is never wrapped — the three statements
    the probe recorded as failing are pinned as the cases.

And a runbook, `docs/wakil/phase-2c-ii-acceptance.md`, **walked**. 2c-i's walk found six
defects and forced two rulings after 500+ tests were green and two review rounds had
passed, and left this instruction: *"a fourth of the same shape should be assumed to exist
until 2c-ii's own walk says otherwise."* The runbook carries, at minimum: paging through
1,006 rows in both directions; a sort on page three; the schema subject and the drill into
it; relaunch with several panes on `production` (§8); a mutation typed into the line and
confirmed, and one cancelled; the routing flow in the operator's own words — *query A,
filter, filter, sort, then query B* — driven by voice or by the agent rather than by hand;
the footer's silence on a complete sorted result, looked at once more (§7); a `SHOW TABLES`
from the query line, to see the page controls absent rather than broken; and ⌘↩ pressed on a
real key window with two panes open, which the probe could not reach (§12).

## 14. Exit criterion

> A `db` pane shows its own query and its own database, editable in place. Return re-runs it;
> ‹ › page through a result larger than the cap without a round trip through the agent, and
> the footer says which rows are on screen and whether more remain. A sort on a paged result
> re-queries and the footer stops apologising. The schema is browsed as rows on the same
> surface, and a table drills into a query in a new pane. An agent refining a query names
> the pane and the pane updates; an agent asking a different question names none and a pane
> opens. A restored pane comes back showing rows. An `UPDATE` typed into the query line
> reaches the confirmation plane. Every one of those is reachable by pointer and by action,
> and journals identically.

## 15. Open items this sub-phase surfaces but does not own

- **Relaunch queries production unasked** (§8). Chosen deliberately; recorded so that
  gating it by environment later is a change of mind rather than a discovery.
- **No total row count** (§3). "More remain" is what the engine tells us for free; a count
  is a second scan that can disagree with the page beside it. If the operator finds "of
  1,006" worth its cost, it is an added action, not a changed one.
- **Keyset paging remains impossible** over a raw-SQL surface (§3). It becomes possible
  only for a subject Wakil composed itself — `.table`, `.tables`, `.columns` — and even
  there only once `Column.Key` is populated, per the item above. Not worth two paging
  models today.
- **Select by key** (§10), and the field it would need. `Column.Key` is declared and no
  driver has ever set it, so before `pane_select_by_key` can exist at all, `Describe` has to
  learn keyness per dialect — `PRAGMA table_info` on sqlite, `information_schema` on MySQL,
  `_id` on Mongo. Two changes, not one. 2c-i's recorded note asks only that when it arrives
  it be a different action from `pane_select_rows` rather than a different reading of it.
- **Several surfaces at once** — inherited unresolved from 2c-i §10, and now more likely:
  §6 opens a pane per question by default, so two or three scrolling grids over an
  animating Metal layer is the ordinary case rather than the unusual one. Still unmeasured.
  `make bench-surface` measures one.
- **Accessibility parity** — inherited from 2c-i §10 and 2b-ii before it, unchanged and not
  closed. The query line adds a text field, which is at least a natively accessible control;
  the grid's gaps are where they were.
