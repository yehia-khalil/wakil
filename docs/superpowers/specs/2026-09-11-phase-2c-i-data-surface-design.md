# Phase 2c-i — the data surface

**Written:** 2026-09-11 · **Probe:** `docs/wakil/phase-2c-i-probe.md` (same day) ·
**Depends on:** 2b-i's pane model and action registry, 2b-ii's `Grid` and its findings

---

## 0. What this sub-phase is not

2c's row in `north-star.md` §8 names four things — *DB pane in full, API client pane,
terminal pane, session browser* — and they are not one spec, for the reason 2b split on
2026-09-08 and 2b-iii split again on 2026-09-09. 2c is therefore split into five,
agreed 2026-09-11:

| | Delivers |
|---|---|
| **2c-i** | The data surface: the grid, the selection model, virtualization, §8's chrome, and the move of pane contents out of the window and into panes |
| **2c-ii** | DB pane in full — schema browser, query surface, results drawn on 2c-i |
| **2c-iii** | Terminal pane — PTY, per-root shells, and the write-gate boundary for a shell |
| **2c-iv** | API client pane — request/response, consuming values from other panes; `wakil-http` gains a gated write method |
| **2c-v** | Session browser pane |

This document is 2c-i only. It builds **no pane type**. It does not touch `wakil-http`,
does not add a terminal, does not build a schema browser, and adds no way to run a
query that does not already exist. What it builds is the surface all four of those
panes draw on, plus the structural move that makes "each pane fully dual-driven"
possible at all.

**2c-i is first, and not because it is the easiest.** Decision 9 records that dual-drive
cannot be retrofitted. A surface built inside the DB pane and extracted when the second
consumer appears is a surface whose API has one pane's assumptions in it, and 2c-ii
through 2c-v would each be built against a shape about to change underneath them.

## 1. The structural finding that reframed this sub-phase

The grid that ships today is **not in a pane**.

`WakilWindow.swift` draws it in the window's own `VStack`, between the canvas and the
message field, bound to `WindowModel.columns` and `WindowModel.rows` — one flattened
set of columns and rows, read out of `PaneStore` under a `paneId` that defaults to
`"db"` (`WindowModel.swift:738`) and is never anything else. `db_run_query`'s handler
writes results with `paneId: "db"` hardcoded (`StandardActions.swift:359`). Meanwhile
the panes *on* the canvas draw their title, their kind, and their frame numerals
(`Canvas.paneView`), and its own comment says why: the numerals are on screen "because
in 2b-i it is the only evidence a drag or a resize committed at all".

So `PaneStore` is keyed per pane, exactly one key is ever read, and it is read by the
window rather than by any pane. Nothing in 2b was wrong to do this — 2b-i built the
canvas and 2b-ii built the atmosphere, and neither owned pane contents. But it means
2c's exit criterion, *each fully dual-driven*, is unreachable in the current shape, and
inverting it is 2c-i's work rather than a preliminary to it.

## 2. The grid construction, and why it is SwiftUI

Two governing documents disagreed and the probe settled it.

`design-language.md` §13 says *"on very dense tabular data, prefer AppKit over SwiftUI
for the grid specifically — SwiftUI list perf is the known weak spot."* 2b-ii then
measured that `Table`'s backing `NSTableView` floors its row height at the platform
default of 24pt, which puts §8's 23pt dense row out of reach inside it — which is why
`Table` was replaced by a hand-built `Grid` in a `ScrollView`.

`phase-2c-i-probe.md` measured a third option, in release, on 50,000 rows:

- **Exact row height.** A `LazyVStack` of rows at `.frame(height: 23)` measures
  23.0000 pt/row, and 40.0000 at airy. Both of §8's densities, no floor near either.
- **Real virtualization.** 50,000 rows build **1,086** row bodies — a figure flat in
  the row count, tracking the scrolling rather than the data. `Grid` builds every row
  it is given.
- **Inside the frame budget.** Scrolling 10pt per step: median **0.574 ms**, p95
  1.713 ms, **1 step in 300** over the 8.33ms a 120fps frame allows. It does not
  degrade from 5,000 rows to 50,000.

And one thing that was not previously written down anywhere: **the pane that ships
today misses the frame budget on every single step at 5,000 rows** — median 26.667 ms,
three times over, with a 5.3-second first layout. The regression this sub-phase fixes
is live, not hypothetical.

So: **SwiftUI `LazyVStack`, fixed row heights.** §13's preference for AppKit is not
upheld by measurement in this case and is amended in §7 below rather than left standing
in contradiction with §8.

### 2.1 No `Section`

The obvious construction — rows in a `Section` with a pinned header, so the header
scrolls horizontally with its columns and stays put vertically — under-reports the
scroll view's document height by **2.8%** (111,779pt where 5,000 23pt rows are
115,000pt). The probe isolated it: pinned and unpinned are identically wrong, and a
header drawn **above** the `ScrollView` is exact to 0.00% at every size tested. It is
`Section`, and pinning has nothing to do with it.

A 2.8% error in reported content height is a scrollbar thumb of the wrong size and a
scroll-to-row that lands in the wrong place. `pane_scroll_to_row` (§4) is a dual-drive
action — "show me the row you selected" is the agent's half of selection being
visible — so landing near the row is not good enough.

**Therefore:** header outside the vertical `ScrollView`, bare `LazyVStack` inside it.
What this costs is the free horizontal synchronisation the pinned header gave: header
and rows are now in different scroll contexts and their horizontal offset must be
shared by hand. That is known work, recorded here rather than discovered mid-build.

## 3. Data model

### 3.1 Cell types come from the database, not from inference

§8 asks for column type annotations and explicit `null` rendering. Today neither is
possible honestly: `db_run_query` hands back untyped JSON, and `paneCellText` renders
JSON `null` as the empty string — so a real `NULL` and an empty string are already
indistinguishable on screen, which is the exact confusion §8's "explicit null
rendering" exists to prevent.

Inferring a column's type from the values on screen was considered and rejected: it is
wrong for an empty result set, wrong for an all-`NULL` column, and wrong for a column
whose first 500 rows happen to be integers.

`wakilcore.Rows` therefore gains a field beside the three it has:

```go
type Rows struct {
    Columns     []string `json:"columns"`
    ColumnTypes []string `json:"columnTypes"`   // new
    Rows        [][]any  `json:"rows"`
    Millis      int64    `json:"millis"`
    Truncated   bool     `json:"truncated,omitempty"`
}
```

Populated per driver from what the driver already reports (`sql.ColumnType` for the SQL
drivers; inferred per field for Mongo, where there is no schema to ask — and reported
as inferred rather than as declared, since claiming otherwise would be the same lie in
a smaller place). A driver that cannot say leaves the entry empty, and an empty entry
draws no annotation rather than a guessed one.

`Millis` is already there, and §8's footer wants it — so the timing half of the footer
costs nothing new.

### 3.2 `PaneStore` carries them, and is read per pane

`setRows` gains `columnTypes` and `millis`. Its existing discipline is kept exactly:
`truncated` has no default value because every producer knows whether it handed over
everything, and the same rule applies to the new parameters.

`PaneStore` also gains selection and sort state per pane (§4), which is the first
per-pane state it holds that no query wrote.

`read_pane`'s snapshot gains `columnTypes`, `millis`, the current selection, and the
current sort. The existing rule that made `truncated` always present, including when
false — *"an absent key is a thing a reader has to know to interpret, whereas
`"truncated": false` is an answer"* — applies to every one of them.

### 3.3 `null` renders as `NULL`

`paneCellText`'s `.null` case stops returning `""`. A JSON `null` draws a dimmed `NULL`
in the cell; an empty string draws nothing. This is a behaviour change visible to
anyone reading a pane, and it is the point.

## 4. The selection model

§8 permits exactly one luminous element inside a data surface: the active row's left
edge. §11 says the API client pane "consumes values from other panes", which needs a
specific cell rather than a row. And copying a block of rows is the everyday operation
a grid exists for.

The model is therefore **an anchor cell plus a selected row set**:

- The **anchor** is a (row, column) pair. Its row draws §8's luminous left edge. It is
  what 2c-iv will consume as *a value*.
- The **selected rows** are a set containing the anchor's row. Shift-click extends from
  the anchor, ⌘-click toggles. This is what copy — and, in 2c-ii, "delete these" —
  operates on.

Multi-row selection is in 2c-i rather than deferred **because selection shape is a
published contract**, not because anything in 2c-i needs it. It is in `read_pane`'s
payload and in the schemas of the actions below, both of which an agent reads;
widening it later changes a contract rather than a data structure.

**This requires a §8 amendment.** Non-anchor selected rows need a treatment, and §8 as
written permits no second luminous element. They get a lifted background — opaque,
non-luminous — and §8 is amended in §7 to say so, rather than the rule being quietly
broken.

## 5. Dual-drive: the actions

Five new actions, all `.control` (they change Wakil's own state and nothing outside it,
so the environment never blocks them — `ActionKind`'s own reasoning), all registered in
the registry and therefore reachable identically from the rail, a keystroke, ⌘K, the
agent, and `--dispatch`:

| Action | Params | Does |
|---|---|---|
| `pane_select_cell` | `pane`, `row`, `column` | Sets the anchor; collapses the selected set to that row |
| `pane_select_rows` | `pane`, `rows`, `anchor` | Sets the selected set and the anchor within it |
| `pane_sort` | `pane`, `column`, `direction` | Records sort intent (§6) |
| `pane_set_column_width` | `pane`, `column`, `width` | Sets one column's width; persisted with the layout |
| `pane_scroll_to_row` | `pane`, `row` | Brings a row into view — exact, per §2.1 |

`read_pane` stays the hand-written read it is, and reports the new state.

**`row` is an index into the order currently displayed, not into the underlying
result.** A sort reorders what is on screen, so the two diverge the moment one is
applied, and only one of them can be what `read_pane` reports and what
`pane_scroll_to_row` acts on without the agent and the operator meaning different rows
by the same number. Invariant 3 settles which: the surface reflects what is actually on
screen, so `read_pane` returns rows in displayed order and every `row` parameter indexes
that. A sort therefore invalidates a previously-held index, which is correct — after
re-sorting, row 4 *is* a different row, for the operator's eyes as much as for the
agent's.

Column widths persist with the pane the way `density` does and `busy` does not —
`Pane`'s `CodingKeys` comment already draws that line: runtime state is dropped on
save, settings are kept. A width an operator dragged is a setting.

## 6. Sort, and who owns the answer

A click on a header of a 500-row result truncated from 50,000 that sorts client-side
orders the 500 you have and *looks* like it ordered the table. That is the same class
of dishonesty `truncated` exists to prevent, one layer up.

So the grid does not sort. It **dispatches intent** — `pane_sort` — and the pane's
owner answers it:

- A pane that can re-query (2c-ii's DB pane) re-queries with an `ORDER BY` and replaces
  its rows. The result is correct over the whole table.
- A pane that cannot re-query sorts the rows it holds, and the footer says so:
  *"sorted within the 500 returned"*, beside the existing truncation line.
- On a result that is **not** truncated, client-side is correct and is what happens.

2c-i has no re-querying owner yet, so what ships here is the second and third branches
plus the hook the first plugs into. That is deliberate and is not a stub: the sort
intent, its recording in `PaneStore`, its appearance in `read_pane` and the footer's
honesty are all complete and testable without a DB pane existing.

## 7. What this changes in existing documents

- **`design-language.md` §13** — the line *"prefer AppKit over SwiftUI for the grid
  specifically"* is amended. It is advice that predates 2b-ii's row-height measurement
  and `phase-2c-i-probe.md`'s frame timings, and as written it contradicts §8's 23pt
  row. Replaced with the measured position: a virtualizing SwiftUI `LazyVStack` of
  fixed-height rows, with the numbers and a pointer to the probe.
- **`design-language.md` §8** — gains the non-anchor selected row's treatment (§4), so
  that "the only luminous element permitted inside a data surface is the active row's
  left edge" stays literally true rather than being contradicted by the code.
- **`design-language.md` §8** — gains the sort rule from §6, which is a statement about
  honesty on a data surface and belongs beside `truncated` rather than only in a spec.
- **`north-star.md` §8** — 2c's row gains the five-way split table from §0, in the form
  2b and 2b-iii's splits are already recorded there.

## 8. Testing

In `WakilKitTests`, which needs no display:

1. The typed projection: `columnTypes` survives `PaneStore` → `read_pane` intact,
   including a driver that reported none.
2. `null` is not `""`: a row with both renders two distinguishable cells.
3. Selection: `pane_select_cell` and `pane_select_rows` produce the same state and the
   same journal entry from `origin: .ui`, `.agent` and `.debug` — 2a's acceptance check
   in its 2c form.
4. Sort honesty: an untruncated result sorts client-side and the footer says nothing; a
   truncated one sorts and the footer says within how many.
5. Column width persistence: a width survives a `LayoutPersistence` round trip, and a
   layout written before this field existed still decodes — the tolerance `Pane
   .init(from:)` already establishes for `density`.
6. `read_pane` reports selection and sort, with every key present including when false
   or empty.

And one measurement, in the probe's shape, run as a `make` target rather than a test —
the same reasoning the 2b-ii spec §11 gives for the captures not being a pixel-diff
gate. It hosts the surface offscreen with 50,000 rows and prints row-body count and
per-step timings against the 8.33ms budget. **This is the thing that would have caught
the 5,000-row regression 2b-ii shipped**, and it is worth more than any assertion about
a number that will drift with the toolchain.

## 9. Exit criterion

> A data surface is drawn **inside a pane on the canvas**, showing real rows at both
> densities. An anchor cell and a multi-row selection are set identically by clicking
> and by the agent, and journal identically. Sort dispatches intent and the footer is
> honest about what it sorted. 50,000 rows scroll within the frame budget. The
> window-level table in `WakilWindow.swift` is gone.

## 10. Open items this sub-phase surfaces but does not own

- **Richer cells cost more per row.** The probe measured short monospace strings. §8's
  status chips and type annotations are more expensive, and the measurement is a floor
  for the construction rather than for the finished surface. The `make` target in §8 is
  what will say by how much, once there is something to measure.
- **Several surfaces at once.** 2c-i draws one pane's surface. Two scrolling grids over
  a Metal layer that is itself animating is a 2c-ii-or-later measurement, and nothing
  here speaks to it.
- **Accessibility parity with `NSTableView` is still not restored.** 2b-ii's per-row
  collapse ports forward unchanged, and so does its recorded gap: no per-cell row and
  column position announced, no column-by-column navigation within a row. A selection
  model arguably makes that gap worse, since there is now state a VoiceOver user cannot
  perceive. Recorded, not closed.
