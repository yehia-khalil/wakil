# DB pane: copy, cancel and row detail

**Date:** 2026-10-13
**Status:** design approved by the operator 2026-10-13, section by section; built 2026-10-13, plan `docs/superpowers/plans/2026-10-13-db-pane-copy-cancel-detail.md`
**Sub-phase:** a follow-up to 2c-ii (the DB pane in full) and 2c-ii-b (editing records). Built in
parallel with 3b-ii; it touches no editor code. Waits on nothing.

---

## Problem

The DB pane owns its query, pages, sorts, browses the schema and edits a cell. What is missing is
everything *around* a result:

1. **Nothing can be copied out of the grid.** No cell, no row, no rows as a table.
2. **A slow read cannot be stopped.** It runs until it lands or `MCPClient.readReplyTimeout` (10 s)
   gives up. That breaks Interaction Rule 4, *"anything that waits can be cancelled"*.
3. **A long or JSON cell can only be read as one truncated grid line.** There is no way to see a
   whole row.

## What the operator gets

### Cancel

- **Covered:** every read in flight on an existing DB pane — a query from the query line or from
  the agent naming that pane, `db_page`, `pane_sort`'s re-query, `db_refetch`, `db_read_table`,
  `db_list_tables` and `db_describe_table` into that pane.
- **Not covered:** `db_run_mutation`. A cancelled write may still land; its wait keeps its own
  budget (`MCPClient.mutationReplyTimeout`) and is not touched here.
- **While a read runs:** the pane footer shows `running · N s`, counting, and a **Cancel** verb.
  Esc in the query line cancels too, only while a read is in flight — the plan checks
  what Esc does there today and keeps it otherwise. A second read on that pane is refused while one is running
  — from the query line (the run control is disabled) and from the agent (an error naming the
  pane) — per Rule 5.
- **After a cancel:** the rows that were on screen stay. The footer reads `cancelled after N s`
  until the next read lands. The query line keeps what was typed.
- **Agent:** a new action, `db_cancel(pane)`, `.control`, agent-reachable, never priced — the shape
  of `api_cancel` (`ApiActions.swift`). Refused when nothing is in flight. `read_pane` reports
  `running: true` while a read is in flight.

### Copy

- **⌘C** with one row selected copies the anchor cell's value as plain text. With several rows
  selected it copies them as **tab-separated text with a header row**, columns in result order —
  which Sheets, Numbers and Jira paste as a table.
- **The row context menu:** *Copy cell*, *Copy row* / *Copy N rows*, *Copy as JSON*. JSON is an array
  of objects keyed by column name — an array even for one row.
- **Values:** NULL is empty in TSV and `null` in JSON. A TSV field holding a tab, newline or `"` is
  quoted Excel-style (`"…"`, inner `"` doubled). JSON keeps each value's type — numbers stay
  numbers, a nested Mongo document stays an object.
- **Only what is loaded:** copy takes the rows on screen — the current page. It never re-runs the
  query to fetch the rest.
- **While a cell is being edited,** ⌘C belongs to the text field.

### Row detail strip

- **Open:** Space on a selected row, or the ⓘ that appears when a row is hovered. **Close:** Space,
  ⓘ or Esc. Double-click still edits the cell.
- **Shows** the anchor row: one block per column, the name above the whole value. With several rows
  selected it shows the anchor. It follows ↑↓ and clicks while open.
- **Values:** NULL drawn as the grid draws it. A JSON object or array — a Mongo nested document, or
  a text value that parses as one — is pretty-printed. Everything else is plain text. All text is
  selectable.
- **Big values scroll.** The strip scrolls vertically as a whole. A value taller than the strip
  gets **its own scroll region, capped at the strip's visible height**, so a 5,000-line JSON never
  pushes the other columns out of reach. Lines with no break points (base64, minified JSON) wrap at
  any character. Nothing scrolls sideways.
- **Layout:** inside the pane, on the right, about a third of the pane's width and never narrower
  than 220 pt. The grid keeps its own horizontal scroll.
- **Read-only.** Editing stays in the grid's double-click path, so there remains one cell editor and
  one confirmation plane per surface (2c-ii-b check 22).

## What it does not do

- **Cancel a query that opens a new pane.** `db_run_query` with no `pane` opens its pane only when
  the reply lands, so there is no pane to show `running` or carry a Cancel. The agent's own turn is
  interrupted the usual way. Opening the pane first is a routing change to `resolvePane` this
  sub-phase does not make.
- **Change `readReplyTimeout`.** A read still gives up at 10 s; Cancel ends one sooner.
- **Copy CSV, or copy beyond the loaded page.**
- **Edit from the strip, open it from the agent, or restore it on relaunch.**
- **D1** (a table subject shows the table name, not SQL) and **open question 16** stay as they are.

## Design

### Go: `wakil-db` and `internal/wakilcore`

Every `wakil-db` tool handler already passes the request's `ctx` to the driver, and every driver
read already calls `QueryContext` / the Mongo driver with it. The go-sdk cancels a request's
context when `notifications/cancelled` arrives for it. So cancel needs **no new Go surface** —
only proof:

- **A Go test per driver** (SQLite always; MySQL and Mongo under the existing integration tags)
  that starts a read which blocks, cancels its context, and asserts the call returns
  `context.Canceled` well inside the block's duration.
- **A server-level test** in `cmd/wakil-db`, the shape of `cmd/wakil-http/cancel_test.go`: a go-sdk
  client calls `query`, cancels `CallTool`'s context, and the handler's context is observed done.
- **Measured 2026-10-13, before planning: MySQL does NOT stop the statement; Mongo does.**
  Against `wakil-acc-mysql` (mysql:8), a `sqlConn.Read` of `SELECT SLEEP(20)` under a 1 s
  context returned at 1.0 s with `context deadline exceeded`, and the statement was still in
  `information_schema.PROCESSLIST` 3 s later. Against `wakil-acc-mongo` (mongo:7), a `Find` with
  a `$where` sleep under a 1 s context returned at 1.0 s and `currentOp` showed no operation 3 s
  later. So:
  - **MySQL reads run on a pinned connection whose id is read first**, and when the context ends
    `sqlConn` issues `KILL QUERY <id>` on a second pooled connection. It applies to `Read` and
    `ReadTable` on MySQL only (a `killsOnCancel` flag set by the MySQL driver). The kill is waited
    for before the pinned connection returns to the pool, so it can never land on a later
    statement that reuses that connection.
  - **Mongo and SQLite need no change**, only the tests that prove it.

### WakilKit

- **`DBFlight` on `PaneStore`**, mirroring `ApiFlight` (`PaneStore+Api.swift`): `startDBRead(paneId:)`
  returns a token or refuses when one is in flight; `cancelDBRead(paneId:) -> Bool`;
  `finishDBRead(paneId:token:outcome:)`. It carries `startedAt`, `cancelRequested` and the
  `cancel` closure. The rows a finished read brings replace the pane's only for a read that was
  not cancelled; a cancelled one records `cancelledAfter` and leaves the rows.
- **The read actions** (`db_run_query` naming a pane, `db_page`, `db_refetch`, `db_read_table`,
  `db_list_tables`, `db_describe_table` into a pane, and `refetchPane`, which `pane_sort` reaches)
  open a flight before `callChecked` and finish it after, inside a task whose cancellation
  `MCPClient` already turns into `notifications/cancelled` (W14, `cancelPending`).
- **`db_cancel`** registered beside the other `db_` actions; `read_pane` gains `running` and,
  after a cancel, `cancelledAfterSeconds`.
- **The flight is announced on the existing flight stream.** `PaneStore.publishFlight` (today
  only the API pane's) is what makes `WindowModel`'s flight pump redraw a pane between
  dispatches; a DB flight publishes on it too, so `running · N s` appears without a second pump.
- **Cancel ends the flight at once**, rather than waiting for the call to unwind: the flight is
  cleared and `cancelledAfterMs` recorded in the same step, and a reply that still arrives is
  dropped because its token is no longer the pane's. That is what lets an environment switch,
  which re-runs every pane's subject, cancel the reads in flight and start its own straight
  away — `restorePaneContents` and the org switch both call `cancelAllDBReads` first.
- **`PaneCell` keeps its source value**: `public let value: JSONValue` beside `text` and `isNull`,
  so JSON copy and the strip keep types. `text` is unchanged.
- **`GridCopy.swift`** — two pure functions: `gridCopyText(columns:rows:) -> String` (TSV, header,
  quoting) and `gridCopyJSON(columns:rows:) -> String`. The single-cell case is the cell's `text`
  (empty for NULL).
- **`RowDetail.swift`** — `rowDetailFields(columns:row:) -> [RowDetailField]`, each with `name`,
  `display` (pretty-printed when JSON), `isNull` and `isJSON`. A string parses as JSON only when it
  is an object or array after trimming whitespace — `"42"` and `"true"` stay text.

### WakilApp

- **The grid has no keyboard handling today** — no ↑↓, Space or ⌘C (`DataSurface` reads keys
  nowhere but the cell editor's Esc). This sub-phase adds ↑↓ (moving the anchor row through the
  existing `pane_select_cell`, so no new action), Space, Esc and ⌘C, by `.onKeyPress` on the
  already-focusable surface. `DBPane`'s rule stands: **no `.keyboardShortcut`** in a pane view.
  Which key does what is a pure function in WakilKit, `dataSurfaceKeyClaim`, so it is tested.
- **`DataSurface`**: ⌘C and the context menu read the selection and write `NSPasteboard.general`
  with the formatters' output — the same view-only pattern as the terminal's `copyBlock`. Space
  and ⓘ toggle a view-local `showsDetail`.
- **`RowDetailStrip.swift`** (new): the strip. Each value renders through a read-only,
  selectable, wrapping `NSTextView` (TextKit 2 lays out lazily — the query line's
  `QueryLineEditor` is the precedent), inside a frame capped at the strip's height, so a 1 MB
  value neither freezes the pane nor hides the fields below it.
- **`DBPane`**: the footer's `running · N s` / `cancelled after N s` and the Cancel verb, read from
  the flight; Esc in `QueryLineEditor` dispatches `db_cancel` when a read is in flight.

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How it is met |
|---|---|
| 1 Confirm only what destroys | Cancel and copy confirm nothing. |
| 2 Enter is never required | Nothing here takes typed input; the query line's draft survives a cancel. |
| 3 A new input arrives focused | No new input. Closing the strip returns focus to the grid. |
| 4 Anything that waits can be cancelled | The point of the Cancel half. The one excluded wait (a new-pane query) is named above. |
| 5 Work in flight shows it | `running · N s`; a second read on the pane refused, run control disabled. |
| 6 Stay where the operator was | Cancel keeps the rows and the page; the strip opens beside the grid and closes onto the same row. |
| 7 Override or ignore | `db_cancel` with nothing in flight is refused — a no-op success would tell the agent it stopped something. Recorded as the one refusal, as `api_cancel` records it. |
| 8 Errors shown whole | A cancel is a state, not an error. A read failing mid-flight reports as today. Strip values are never truncated. |
| 9 Defaults suggest | Nothing defaulted. |

**Edges:**
- A read finishing in the same instant Cancel is pressed: whichever reaches `finishDBRead` first
  wins; a reply arriving after `cancelRequested` is dropped.
- An org, project or environment switch mid-read must cancel it. The plan reads the switch's
  teardown and adds the cancel there if it is not already reached.
- A selection change while the strip is open on a row that a re-query removed: the strip shows the
  new anchor, or closes when there is none.

## Testing

- **Go:** the per-driver cancel tests and the `cmd/wakil-db` server cancel test above; a live MySQL test
  (`make test-live`) that a cancelled `SELECT SLEEP` is gone from `PROCESSLIST` within 2 s, and a
  live Mongo test that a cancelled `$where` sleep is gone from `currentOp`.
- **WakilKit (`swift test`):**
  - `DBFlight`: start, refuse a second, cancel keeps the rows, a late reply after cancel is
    dropped, finish clears it.
  - `db_cancel`: refused with nothing in flight; cancels a stubbed slow read; `read_pane` shows
    `running`.
  - `gridCopyText`: header and order, NULL empty, tab/newline/quote quoting, unicode, an Int64 past
    2^53.
  - `gridCopyJSON`: array for one row, `null`, numbers as numbers, nested objects kept.
  - `rowDetailFields`: NULL, a nested object, JSON in a string, `"42"` stays text, unicode.
  - `PaneCell.value` round-trips every `JSONValue` case.
- **e2e auditor:** Cancel clicked mid-read keeps the rows and shows `cancelled after`; ⌘C on one
  and several rows lands the right pasteboard text; the strip opens, follows ↑↓, closes with Esc
  onto the same row; **a 1 MB cell and a 5,000-line JSON cell** — the strip opens, scrolls to the
  end, ↑↓ still moves rows, and the window stays responsive.

## Charter changes this sub-phase makes

- `north-star.md` §8 gains this sub-phase's row once met.
- No invariant changes. No new write: cancel and copy mutate nothing outside Wakil.

## Open questions

- **Its label.** Settled 2026-10-15: `2c-ii-c`, continuing 2c-ii-b's letter; its row is in `north-star.md` §8.
