# Phase 2c-i acceptance — the data surface

**Status:** **Not yet run, as of 2026-09-12.** Checks 1–8 and 10–14 below have not been
walked by anyone — they are written for the operator, each with a blank result row.
Check 9 (`make bench-surface`) is the one exception: it needs no window and no human
judgement, so the implementer ran it and pasted its output into §3. **2c-i is not met
until every other check has been walked.** · **Spec:**
`docs/superpowers/specs/2026-09-11-phase-2c-i-data-surface-design.md` · **Probe:**
`docs/wakil/phase-2c-i-probe.md`

`north-star.md` §8 draws the line this document exists to hold, the same line
`phase-2b-vi-acceptance.md` draws: a sub-phase whose value is a human judgement gets
marked **implemented**, and only a walked runbook marks it **met**. 2c-i is implemented
— its plan's tasks are done, the tree is clean at `478e032`, and `make test`, `make
vet`, `make fmt` and `make app-test` are green (§4). **It is not met.** "The code is
written" and "the phase is done" are different claims, and only walking §2 closes the
second one.

## 0. What "implemented" already covers, so these checks do not re-argue it

The whole headless half is green: the typed projection surviving `PaneStore` →
`read_pane` including a driver that reports no types at all; `null` rendering as a cell
distinguishable from `""`; `pane_select_cell` and `pane_select_rows` producing the same
state and the same journal entry from `origin: .ui`, `.agent` and `.debug`; sort
honesty's two branches (an untruncated result says nothing, a truncated one says how
many); a column width surviving a `LayoutPersistence` round trip, including a layout
written before the field existed; and `read_pane` reporting selection and sort with
every key present, including when false or empty. That is the code being written. It is
not the sub-phase being done — whether a pane reads as *drawing rows*, whether a sort's
honesty is legible without reading the footer twice, whether a stale selection after a
sort reads as a bug, are judgements no test in this repository can make.

## 1. Prerequisites

Skipping one of these does not make a check fail cleanly — it makes it fail for the
wrong reason, which is worse than not running it.

1. **`make build`, first.** `bin/` is per-worktree and several Swift tests shell out to
   it; a worktree that never ran it fails those for want of a binary rather than for
   want of a feature.
2. **`make app-bundle`**, so the running app carries `wakil-ctx`/`wakil-db`/`wakil-http`
   into `Contents/Resources` the way every other 2b/2c runbook requires.
3. **An org, a project and at least one environment with a database registered**, per
   `operator-todo.md` §3 — any of the three drivers (`sqlite`, `mysql`, `postgres`) is
   enough for checks 1–3 and 5–12; check 13 specifically needs **both** a driver that
   has a real `BOOLEAN`/`bool` type (Postgres or SQLite) and MySQL, to see the
   TINYINT-gets-no-chip half.
4. **A table with a nullable column, holding both a `NULL` and an empty string in
   different rows** (check 3), and **a table large enough to truncate** — the footer's
   truncation line is what check 5's "within the N returned" is judged against, and
   the spec's own example uses a 500-row truncation of 50,000.
5. **A result set with more than 10,000 rows**, for check 7's scroll-to-row.
6. **A table with a declared `BOOLEAN` column, a `VARCHAR` column holding the literal
   text `"true"`, and — on MySQL specifically — a `TINYINT` column** (check 13).
7. **The launch command**, per `phase-2a-acceptance.md` §1:
   `WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil`.
8. **A way to ask the agent to act**, since checks 4, 10 and 11 are dual-drive checks —
   a running session under a registered provider, per `phase-2b-vi-acceptance.md` §1.
9. **The journal**, for check 8 — know where it lives (`~/.wakil`, per every prior
   runbook) and how to read `origin` off an entry before you start, not while hunting
   for it mid-check.

## 2. The standing checks

Nothing here is marked PASS. Each check below is written for the operator to walk at
the window; the **Result** row under each is left blank on purpose — a runbook that
pre-fills a result nobody has seen is worse than one that admits it was never run.

### Check 1 — a pane draws rows

Open a `db` pane, run a query, and look for the rows **in the pane** — not in a window-
level table, which no longer exists (`WakilWindow.swift`'s placeholder was removed in
`1c7cceb`).

**The Run query button does not work in an environment with more than one database, and
that is pre-existing, not 2c-i.** `WindowModel.runQuery` dispatches `db_run_query` with
`query` alone and no `database`, so `wakilcore` refuses with *"multiple databases in this
environment — name one of them"* (`internal/wakilcore/dbresolve.go:26`). `wakil-acceptance`
on `staging` defines three — `core`, `events`, `docs` — so the button cannot be used there
at all. `runMutation` already takes a `database` argument; `runQuery` never grew one.

Two ways to walk this check regardless, and the first is the better one because it also
exercises the agent-refresh pump added by the final review:

- Ask the agent, in the message field: *"run select * from customers on the core database
  and put it in the db pane"*.
- Or switch to an environment defining exactly one database — `production` here — and use
  the button.

Walking it the second way leaves the agent path untested, so prefer the first, or do both.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-12 | Verified repeatedly across the walk: MySQL row `42 / Ada` with declared INT/VARCHAR types, sqlite `events` at 6 and 500 rows, headers aligned over their columns after `4b45f8d`, one row drawing at the top of the pane. |

### Check 2 — both densities

⌘⇧D. Rows visibly change height. Quit and relaunch the app; the density chosen for that
pane is still in effect.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-12 | ⌘⇧D toggles; 40pt airy and 23pt dense both read correctly on a 6-row result. Relaunch walked: the pane survives (layout persists, density with it — pinned by `aLayoutFileWithoutPreMaximizeFrames`'s sibling test asserting `density == .dense` after a load) but comes back **empty**. That is by design and now recorded as such: contents are query results and live only in `PaneStore`, which persists nothing — redrawing yesterday's rows from a cache would show the operator a database state that may no longer exist, the exact dishonesty `truncated` and the sort footer exist to prevent. A pane that re-runs its own query on relaunch is a pane that *owns* a query, which is 2c-ii's DB pane — one more consumer of the same mechanism as sort-as-re-query and pagination. |

### Check 3 — types and `NULL`

A table with a nullable column shows the column's type in the header, and a `NULL`
cell renders dimmed and is visually distinguishable from an adjacent row's empty
string.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-12 | `SELECT id, '' AS empty_text, NULLIF(kind,'login') AS null_when_login` on sqlite: `NULL` renders dimmed and unmistakably distinct from the blank `empty_text` cells beside it. Declared columns carry their type in the header (`ID integer`); expression columns carry none, correctly — sqlite gives an expression no decltype, and the header only claims a type the driver actually declared. |

### Check 4 — selection, both ways

Click a cell: its row draws the luminous left edge. Then, from the agent, ask it to
*"select rows 3 through 8 in the db pane"*: the same treatment appears, with the
anchor's luminous edge on one row and a lifted (opaque, non-luminous) background on the
rest. `read_pane` reports both the same way regardless of which drove it.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-12 | Agent-driven `pane_select_rows` drew the anchor's luminous left edge on one row and the lifted background on the other two, exactly as §8 specifies. See the note below on what "rows 1,2,3" means. |

**Recorded, not a defect: an index is a position, not an id.** Asked to "select rows
1,2,3" on a result already sorted by `kind`, the agent sent `rows: [0,1,2]` and the pane
selected the first three *displayed* rows — ids 41, 42, 43. The operator read that as
wrong. It is the documented model: every row index in this phase indexes the **currently
displayed** order, which is what makes `read_pane` and `pane_select_rows` agree after a
sort, and it is the same fact check 12 records from the other direction. Told so, the
agent re-read the displayed order and selected indices 3, 4, 5 — ids 1, 3, 2 — without
needing anything explained about the API. Worth watching in 2c-ii, when the DB pane gains
a primary key it could select *by*: selection by id is a different action, not a
different reading of this one.

### Check 5 — sort, and its honesty

Sort a truncated result by clicking a header: the footer reads "sorted by X within the
N returned." Sort an untruncated one: the footer says nothing about the sort at all.

| Result | Date | Notes |
|---|---|---|
| PASS, both halves | 2026-09-12 | Untruncated: clicking `KIND` sorted asc/desc, header carries ▲/▼, footer correctly silent. Truncated: 500 of 1,006 rows sorted client-side, operator confirmed the behaviour and the footer's admission ("sorted by X within the 500 returned") — and that sort-as-re-query is what 2c-ii's DB pane owes, per spec §6 and the north-star 2c-ii row. |

**Recorded: the operator looked for the sort in the footer and did not find it** — "sort
is working but not written somewhere on the pane". That is §8 behaving as written: the
footer's "sorted by X within the N returned" is a *warning about a truncated result*, not
a status line, and printing it on a complete result would drain it of the meaning it
exists to carry. The only sort indicator on a complete result is the ▲/▼ in the header,
which is easy to miss at 9pt. Not changed here; recorded so 2c-ii decides deliberately
rather than by omission.

### Check 6 — column width

Drag a header edge to resize a column. Quit and relaunch the app; the width is still
there.

**Two things the final review asked you to look at while you are here**, both introduced
by the fix that added this drag and neither verifiable without a window:

- The handle is a 6pt strip on the header cell's trailing edge, with its own gesture, so
  a click in those last 6pt may not reach tap-to-sort. Try sorting by clicking near the
  right-hand end of a header and see whether it responds. The strip also offers no hover
  cursor, so there is nothing telling you it is draggable.
- While *dragging a pane* (not scrolling), the header may jitter a few points against its
  columns before settling. It settles correctly — the permanent misalignment that used to
  survive a pane move is fixed — but watch whether the transient reads as broken.

| Result | Date | Notes |
|---|---|---|
| FAIL, then fixed, re-walk PASS | 2026-09-12 | First walk: "i dont see the edge of the column so i cant drag and resize it" — the 6pt handle was transparent, unmarked, no hover cursor. Fixed in `37025f3` (resize cursor on the strip, 1pt hover-revealed rule on the cell's trailing edge). Re-walk: "is working." Neither sub-question below drew a complaint on the re-walk; neither was specifically exercised either, so they stay open as watch-items rather than passes. |

### Check 7 — scroll to row

Ask the agent to scroll to a row past 10,000 in a large result. Confirm it lands
*on* that row, not merely near it.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-12 | Agent-driven `pane_scroll_to_row` on a large result landed on the row asked for. |

### Check 8 — the journal

Every one of checks 4–7 has a corresponding journal entry, and `origin` is the only
field that differs between a pointer-driven and an agent-driven entry of the same
action.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-12 | Operator pasted the live tail: every walked action journalled (`pane_sort`, `pane_focus`, `pane_move`, `pane_open`, `db_run_query`…), uniform field set across origins. Verified mechanically on one session file holding both: a ui and an agent `pane_select_rows` have identical key sets and differ in nothing but `origin` beyond `id`/`ts`/`params`. One historical caveat, not a defect in this build: session files written before `environment` was journalled lack that key on their entries. |

### Check 9 — `make bench-surface`

Not a judgement call — run it and paste the output. Done below, by the implementer, in
§3, since it needs no window.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 10 — query lands in the focused pane (Task 11b)

Open two `db` panes. Focus the second, press Run query — rows appear in the **second**
pane only. Focus the first, run again — rows appear in the first. With no `db` pane
open, a query **opens one** and draws there — titled after the database, focused.
Also ask the agent to run a query without naming a pane and confirm it lands in the
focused `db` pane.

**Amended 2026-09-12, by operator ruling.** As shipped, no-pane-open drew nothing, by
design ("the query still runs; this is intended"), and the first fix on this walk kept
that and merely made the result *say* nothing was drawn (`drawn: false`, a note naming
`pane_open` as the remedy). The walk showed what report-only buys: an agent that relays
"no pane is open, here are the raw results" and stops, an operator looking at an empty
canvas — "it says nothing is open and still doesnt open them". So `db_run_query` now
opens the pane itself. This is not a `.read` violation for the same reason `setRows`
never was: the action has always written Wakil's own state as its documented point, the
journal records the dispatch as the cause, and the gate never blocks `.control`-class
state in any environment — what `.read` still promises is that nothing outside Wakil is
touched.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-12 | Auto-open verified (no pane → one opens, titled after the database, rows drawn — `3e5d092`'s amendment above). Focused-pane routing verified in use: with one pane open holding a result, a query against a different table landed in it and replaced the rows — which is the rule working, and which prompted the routing question below. |

**Recorded question, for 2c-ii (operator, this walk): should a query against a
*different table* open a new pane, and only a query against the *same table* update the
one that is open?** The instinct is right — a pane titled EVENTS showing customer rows
has a lying title, and comparing two tables side by side is what a canvas is for. The
implementation must not be "parse the SQL and guess the table": a join names two tables,
an aggregate names none usefully, and a routing rule built on a guess would misroute
exactly the queries that matter. The crisp identity is **the pane's own query**, which is
2c-ii's DB pane: re-running the pane's query updates it; a different question is a new
pane. Until then the rule stays "focused pane receives, an explicit pane overrides, no
pane opens one" — and the near-term remedy is already real: the agent can open a pane per
table on its own, and the operator can say "in a new pane".

### Check 11 — refocus during a slow query (Task 11b, open UX question)

Run a deliberately slow query, and refocus the **other** `db` pane before it returns.
Record which pane received the rows. Today the target is resolved when the query
**returns**, not when Run query was pressed. **This is a recorded question, not a
pass/fail** — the operator decides whether that is acceptable.

| Recorded | Date | Notes |
|---|---|---|
| Recorded | 2026-09-12 | Operator ran the check with two panes and rapid refocusing (the journal shows the focus flapping between `db-1`/`db-2` around the in-flight query): "landed on the selected pane" — the pane focused when the reply arrived, exactly the resolve-on-return behaviour this check documents. No objection raised; stands as-is, revisited when 2c-ii gives a pane its own query. |

### Check 12 — a stale selection after a sort (Task 12, accepted sharp edge)

Select a row, then sort. The luminous anchor edge stays on the same **index**, so it
now marks a different row. The spec accepts this ("after re-sorting, row 4 *is* a
different row"). **This is a recorded question, not a pass/fail** — record whether it
reads as a bug in practice.

| Recorded | Date | Notes |
|---|---|---|
| Recorded: holds | 2026-09-12 | Operator's word after using it: "holds." The anchor staying on a position through a sort did not read as a bug in practice. Stands as the spec accepted it; revisited if 2c-ii's select-by-key changes the operator's expectation. |

### Check 13 — chips only on declared booleans (Task 10)

On a SQLite or Postgres table with a `BOOLEAN` column, true/false values draw as chips.
On a `VARCHAR` column holding the text `"true"`, no chip. On MySQL, where a bool is
`TINYINT`, **no** chip either. That is intended: `TINYINT` is also how MySQL spells a
small integer, so a missing chip is the correct way to fail.

| Result | Date | Notes |
|---|---|---|
| PASS (negative half); positive half unexercisable here | 2026-09-12 | `SELECT id, 'true' AS looks_boolean FROM events LIMIT 3`: the text `true` drew as plain monospace text, no chip — the exact failure mode the rule exists against. The positive half cannot be walked in this environment: the agent tried ten plausible collection names against the mongo `docs` database (`$sample` aggregates; `count` is honestly refused as unimplemented) and every one came back empty — there is no boolean value anywhere on screen to draw a chip for. The chip-on-declared-boolean path is pinned by `WakilKitTests`' `isChip` tests; the eye-level confirmation waits for the first environment holding a real boolean column. |

### Check 14 — column-width drag shows no busy glow (Task 11, minor)

Expected, not a defect: the rail never marks the pane busy during a width change.
Record only if it reads as broken.

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-12 | Nothing read as broken during the width drag; the rail's silence is the intended behaviour and drew no comment until asked. |

## 3. Check 9's output — run on this tree, `478e032`

```
make bench-surface
```

```
xcrun metal -O2 -o app/Sources/WakilApp/default.metallib \
	    app/Shaders/Void.metal
cd app && swift build
[0/1] Planning build
Building for debugging...
[0/4] Copying default.metallib
[1/4] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.18s)
cd app && swift run -c release WakilApp --bench-surface 50000
[0/1] Planning build
Building for production...
[0/2] Copying default.metallib
[1/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'WakilApp' complete! (0.13s)
  rows              50000 at 23pt
  first layout      15.271 ms
  document height   1150000 pt (exact would be 1150000, +0.00%)
  scroll step       median 0.507 ms   p95 2.002 ms   worst 9.905 ms
  over 8.33ms       1 / 300   ok
  deep scroll (worst case, scrollbar dragged length of pane)   median 25.538 ms   p95 29.363 ms   worst 29.645 ms   (probe: ~48ms worst at 50,000 rows)
```

Machine: this worktree's build environment, 2026-09-12. Document height is exact
(+0.00%), confirming the header-outside-the-`ScrollView` construction the probe
recommended holds in the shipped code, not only in the throwaway spike. First layout at
50,000 rows (15.271 ms) and the scroll step's 1-in-300-over-budget figure are both
consistent in shape with the probe's own numbers at 50,000 rows (§3 of
`phase-2c-i-probe.md`), though not identical — different machine state, not a different
construction. The deep-scroll worst case (29.645 ms) is comfortably under the probe's
own ~48ms worst-case ceiling at this row count, which the probe itself named as "the
honest ceiling to record, but not the case the budget is about."

## 4. Headless checks — confirmed green on this tree

```
make test
make vet
make fmt
make app-test
```

Run on `478e032`, 2026-09-12: every Go package `ok`; `go vet ./...` silent; `gofmt`
clean; `make app-test` reports **478 tests in 1 suite**, then the second, isolated
`swift test` invocation with **1 test in 1 suite**
(`stopDeliversTheTailOfTheStreamRatherThanDiscardingIt`, run alone on purpose —
`phase-2b-v-acceptance.md` §3 explains why). None of this is what the sub-phase is
*for* — it is the floor checks 1–8 and 10–14 stand on, restated from §0.

## 5. What the build found

Thirteen things, only twelve of them fixed by a commit — the first predates any code
and was found by the probe, not by a defect. None of the twelve code defects would have
been caught by the headless suite alone; every one of them was found by reading the code
against what it claimed to do, or (the sixth, and the last six) from a screenshot of the
running app.

1. **The grid that shipped in 2b-ii missed the 120fps budget on every frame at 5,000
   rows.** Found by the probe, before any 2c-i code existed —
   `docs/wakil/phase-2c-i-probe.md` §3. No fixing commit: this is the finding that
   justified building a new construction rather than extending the old one.
2. **Mongo array columns would have been annotated `bson.A`.** The v2 driver decodes a
   BSON array into `bson.A`, a named type a `case []any:` switch arm does not match, so
   every array column fell through to `default` and reported `"bson.A"` instead of
   `"array"`. Fixed in `12fba30`.
3. **`paneTable(from:)`, documented as total, trapped on a NaN or out-of-range
   number.** `millis`/`anchorRow`/`scrollTarget`/`selection.rows` conversions now share
   the same finite-and-range check `PaneCell` already used, falling back to the
   documented default instead of trapping. Fixed in `03fe687`.
4. **Command-click could never deselect.** The view sent the removed row back in as
   the anchor, and `PaneSelection.init` unions the anchor back into the selected set —
   so a deselect always re-added the row it had just removed. Fixed in `6f3e253`
   (Finding 1), which moved the selection arithmetic into `WakilKit` as
   `PaneSelectionAfterClick`, testable on its own.
5. **Chips keyed on cell text, so a `VARCHAR` reading `"true"` got one.** `isChip` now
   requires the column's *declared* type to be `bool`/`boolean`, never inferred from
   the cell's own text. Fixed in the same commit, `6f3e253` (Finding 2).
6. **Query results never reached any pane on the canvas.** Panes are minted `db-N`
   (`db-1`, `db-2`, …) by `LayoutStore.open`; `"db"` is never the id of a pane actually
   on the canvas. `db_run_query`'s pane parameter defaulted to `"db"` when omitted, and
   the Run query button never sent a pane at all — so every query's rows landed under
   a dead key and the canvas read "no rows" forever, for the button and for an agent
   alike. **Found from a launch screenshot, not a test**: the suite stayed green
   throughout because its own fixtures used `"db"` on both the write and the read
   side. Fixed in `9a0a13c`, which adds `queryTargetPane(explicit:layout:)`: an
   explicit pane wins, else the focused `db` pane, else the first `db` pane in layout
   order, else `"db"` when none is open at all.
7. **The sort comparator broke strict weak ordering on cell text `"nan"`.** `Double`
   parses the string `"nan"` successfully, and IEEE 754 makes every comparison against
   NaN false in both directions — which made a text column literally containing
   `"nan"` compare as "equivalent" to values that are not equivalent to each other, a
   guarantee `Array.sorted` does not promise defined behaviour under once broken.
   Fixed in `5340812`, which guards the numeric branch on `isFinite` as well as on
   `ln != rn`, verified with a brute-force irreflexivity/antisymmetry/transitivity
   check against mixed numeric/text input before and after.

8. **The column header drew one pane-padding to the left of its columns, always.**
   `HorizontalOffsetKey` defaulted to a non-optional `0` and reduced with
   `value = nextValue()`, so every view in the row `ScrollView`'s subtree that does not
   set the key still contributed that default, and the last such contribution
   overwrote the one measurement that meant anything. The key reported `0` while the
   rows' leading edge was at `16`, so `paneHeaderOffset` returned `0 - 16 = -16`: the
   first column's name drew off the leading edge and `.clipped()` removed it, and every
   other column name sat 16pt left of the values beneath it — 76pt for a pane at
   `x = 60`. Values under the wrong column name is exactly the failure final review
   Finding 4 was about; it re-entered through the *reduction* rather than through the
   latch that fix removed. The key is now optional and `reduce` keeps the last real
   value. Fixed in `4b45f8d`.
9. **A result shorter than the pane drew halfway down it.** A two-axis `ScrollView`
   centres content that is smaller than its viewport, so a one-row result floated in
   the middle of an empty grid with its header stranded at the top —
   `.defaultScrollAnchor(.topLeading)` pins it, and is also the initial scroll position
   the view was already using. Fixed in the same commit.

   **Both were found by looking at a screenshot the user sent of a query that had just
   succeeded**, and both were then reproduced deterministically offscreen — an
   `NSHostingView` over `DataSurface` with one row, inside the same chrome
   `Canvas.paneView` wraps it in, dumping the geometry each measurement reported. That
   harness is not in the tree: it was written to answer one question and deleted. What
   it established is that neither defect is visible from `WakilKit`, because neither is
   in `WakilKit` — `paneHeaderOffset` and `paneColumnLayout` both returned the right
   answer for the numbers they were given, and the numbers were wrong before they
   arrived. `WakilApp` has no test target, which is the standing reason a defect of
   this shape has to be caught by an eye.

10. **No action's return value ever reached the agent.**
    `ActionRegistry.dispatch` returns the handler's bare payload and
    `handleToolsCall` put it straight into the JSON-RPC `result` — with no `content`
    key, so not a `CallToolResult`, so a conforming client renders it as *"completed
    with no output"*. This was true of every journalled action; only the two
    hand-written reads (`read_pane`, `read_layout`) built the envelope, by hand.
    `pane_open`'s description has promised "Returns the new pane's id" since 2b, and
    its handler has returned `{"id": "db-1"}` faithfully the whole time. Fixed in
    `4bd3c45` with `toolResultEnvelope`, applied at both dispatch sites.
11. **`db_run_query` accepted a pane id that named nothing.** `queryTargetPane` returns
    an explicit id unchanged, so rows went into `PaneStore` under whatever key was
    given — and a key no pane holds is a pane nothing draws. The action now refuses an
    id that is not open, before running the query, and the error names every id that
    is. Fixed in the same commit. This is DEFECT X (item 6) reached through the
    explicit parameter: that fix settled the *default* pane and left this path open.

    **The two are one failure, and the screenshot that showed it is worth keeping.**
    An agent asked to open a pane per table opened three, could read back none of
    their ids, and invented three from the titles it had chosen — `core.customers`,
    `events.customers`, `events.events`. It ran three queries naming those, and all
    three were accepted. The result on screen was three panes reading "no rows" beside
    three tool results listing the rows in full, and an agent reporting success in
    good faith. Item 10 is why it had to guess; item 11 is why guessing looked like it
    worked. Fixing either alone would have left the other able to produce a quieter
    version of the same thing.

12. **A pane of a kind nothing draws was routed to by nothing.** `Pane.kind` was a
    free string that nothing validated, so `pane_open` minted panes of any kind at all
    — and a kind nothing recognises silently opts out of every route keyed on kind.
    `queryTargetPane` matches `kind == "db"` exactly, so an agent that had opened three
    panes as `"database"` left it finding none among them and falling through to the
    `"db"` key no pane holds. Asked to "select all from events" with no pane named, it
    ran the query, got the rows back, and drew nothing. Fixed in `80d93e7`:
    `Pane.kinds` is the set this build draws, `pane_open` refuses anything else and its
    schema carries the list, and `LayoutPersistence.load` drops a saved pane of an
    unknown kind with a note — spec §4.3's clause, which 2b-i's runbook deferred to 2c
    with an explicit trigger and which waited only on a validity set to check against.
13. **The column-resize handle was invisible, so the drag did not exist.** A 6pt
    transparent strip with no cursor and no mark is a control only someone who has read
    the source can use — "i dont see the edge of the column so i cant drag and resize
    it". The final review had already filed the missing cursor as a thing to look at;
    the walk settled it as the thing that made §8's "drag a header edge" unreachable.
    Fixed in `37025f3`: the strip sets `NSCursor.resizeLeftRight`, and a 1pt rule
    appears on the trailing edge while the pointer is anywhere in that header cell.

    **Three separate causes produced one symptom** — panes on the canvas, rows in the
    tool result, "no rows" on screen. Item 6 was the default pane id, item 11 the
    explicit one, item 12 the pane's kind. Each was found the same way: by looking at
    the running app, after the suite was green. The suite could not see any of them,
    and a fourth of the same shape should be assumed to exist until 2c-ii's own walk
    says otherwise.

## 6. What the final review left open, for 2c-ii

None of these block this phase. They were found by the whole-branch review after the last
task landed, judged out of its scope, and are recorded here so they are not rediscovered
from scratch.

- **A selection can still be set out of range.** `pane_select_cell` and `pane_select_rows`
  accept a row index beyond the pane's row count, so `read_pane` can report an anchor on a
  row that does not exist. The clamp added in this phase covers the case where a *new
  result* shrinks the row count, not the case where the index was never valid.
- **`pane_move`, `pane_resize` and `pane_set_column_width` accept NaN and infinity.**
  Nothing traps, but the store mutates and then the journal's encode fails — so that
  dispatch is absent from the audit log *and* skips the refresh publish, leaving the screen
  stale until the next action. The journal is supposed to hold every state change; this is
  pre-existing, and it now interacts with the refresh pump added in this phase.
- **`LayoutStore.setColumnWidth` does not enforce a minimum.** The pointer path floors at
  `paneColumnMinimumWidth`; an agent calling the action directly can still set a width of 5.
- **`runQuery` cannot name a database**, so the Run query button is unusable in any
  environment defining more than one. See Check 1. `runMutation` takes a `database`
  argument and `runQuery` does not; giving it one is small and belongs with the DB pane's
  own query surface in 2c-ii.
- **The refresh pump subscribes asynchronously after `init`**, so a dispatch racing window
  construction is missed with no catch-up. Same shape as the pre-existing confirmation pump.

## 7. Result

**Walked in full, 2026-09-12, by the operator — and 2c-i is met.** Every check in §2
was run against the live app over MySQL, sqlite and Mongo, most of them several times as
the walk itself forced fixes. The tally:

- **PASS:** checks 1 (rows draw, headers aligned, declared types), 2 (densities; the
  pane and its density persist across relaunch, contents deliberately do not — see the
  row), 3 (dimmed `NULL` distinct from empty string), 4 (selection from pointer and
  agent, one treatment), 5 (sort with both honesty halves — silent footer on a complete
  result, "sorted by X within the N returned" on a truncated one), 6 (column width,
  after `37025f3` made the edge discoverable), 7 (agent scroll-to-row lands on the
  row), 8 (journal: same action from pointer and agent differs in nothing but
  `origin`), 9 (bench, §3), 10 (query routing, as amended: focused pane receives,
  explicit pane overrides, no pane opens one), 14 (no busy glow on width drag).
- **PASS on the half that exists:** check 13 — a VARCHAR reading "true" gets no chip;
  the positive half is unexercisable in an environment whose Mongo database is empty,
  and is pinned at the unit level.
- **Recorded, accepted:** check 11 (rows land in the pane focused at reply time) and
  check 12 (the anchor survives a sort by position — "holds"). Both stand, both are
  revisited when 2c-ii gives a pane its own query.

**What the walk was worth: six defects and two rulings no test or review had found.**
§5 items 8–13 — the header offset that hid the first column name, the centred short
result, the tool-result envelope that made every action silent to the agent, the
unchecked explicit pane id, the free-string pane kind, the invisible resize handle —
were all found by the operator looking at the running app, after 500+ tests were green
and two review rounds had passed. The two rulings (`db_run_query` opens a pane when
none exists; a query result replaces the pane and the tools must say so) reshaped the
action surface. Four causes of one symptom — rows returned, nothing on screen — is the
walk's real lesson, and 2c-ii should assume a fifth exists.

**`north-star.md` marks 2c-i met as of this walk**, on the strength of a runbook that
was actually walked — the first phase since 2b-iv for which that is true.
