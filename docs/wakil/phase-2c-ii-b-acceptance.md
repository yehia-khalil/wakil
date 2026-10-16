# Phase 2c-ii-b acceptance — editing records from the DB pane

**Status: MET 2026-09-15.** Walked 2026-09-14 — twenty of twenty-three checks pass.
Checks 12 (the MySQL half), 14 and 17 are recorded as **PARTIAL**, **PASS (operator,
no surviving evidence)** and **NOT ESTABLISHED** — all three for one reason, that
staging's MySQL database has no write credential, so no MySQL pane was editable at any
point in the walk. **Those three were accepted on 2026-09-15 rather than re-walked**, as
part of the operator's blanket acceptance of the outstanding backlog (`phase-log.md`,
"The 2026-09-15 acceptance"). §5's instruction that this sub-phase stay unmarked until
they are re-walked is **overridden, not satisfied** — it is kept below as written. What
that leaves unestablished is one thing, and it is named here so it is impossible to
miss: **the MySQL write path has never been exercised at the window.** If a MySQL write
credential is ever added to staging, checks 12, 14 and 17 are the ones to run. Six defects were found
and are recorded in §4; **all six are fixed on this branch**, and the three whose fixes
live in the untestable `WakilApp` target were confirmed at the window by the operator on
2026-09-14. **Two follow-on items are carried, not fixed** — they are named at the end of
§4 and neither is a defect of its own: the project/environment scaffolding row, and the
now-true-but-redundant pane title.

2c-i's walk found six defects and forced two rulings after 500+ tests were green;
2c-ii's walk found thirteen more, the last of them on the walk that finally called the
phase met. This walk found six against 709 green tests — **two of them in the
verification this very document claimed as its floor**, which is the lesson stated
again and more sharply: the floor was not merely insufficient, it was untrue. See §3.

The tests behind this sub-phase (`PaneEditableTests`, `updatestmt_test.go`, the
`WindowModelTests` cell-edit suite) prove the rules Go and `WakilKit` enforce; they
prove nothing about the view.

**A real limit, stated plainly: `app/Sources/WakilApp` has no test target and cannot
have one.** The editor `TextField`, the hover treatment, the hit areas a click or a
double-click actually lands in, and the footer's label are drawn entirely in that
target. Every one of them is exercised by **zero** automated tests — not "thin
coverage", none. That is not an oversight this runbook is here to note in passing; it
is the entire reason this runbook exists. `WakilKit`'s tests establish the floor
(`editableCell`, `paneEditable(from:)`, `commitCellEdit`, `RenderUpdate`'s Go rules);
this walk is the only thing that can establish anything above it.

> Double-click a cell, it becomes an input, Enter commits.

That is spec §1's whole feature, and every check below exists to keep it from being a
lie. The edit composes one `UPDATE` in Go and dispatches `db_run_mutation` — the same
and only `.mutate` action the query line already uses — through the same
`ActionRegistry`, the same `writeGate`, the same confirmation plane and the same
production block 2c-ii's runbook walked at check 10. Nothing here writes to a database
by any other route. A cell is editable only where Go can name the single table the
rows came from and every primary-key column is present in the result under its own
name — Decision 20's provenance rule, measured against nineteen SQL shapes in
`docs/wakil/phase-2c-ii-b-probe.md` §5.

## 1. Scope — what is under test, and what is not

Everything below is the second entrance to a `.mutate` path 2c-ii already opened and
already walked. **Not one of the gate, the plane, the production block or `origin` is
touched by this sub-phase** (spec §10) — none of those mechanisms is re-walked here;
only the new entrance to them is.

**Not under test here, because 2c-ii's runbook already walked it and nothing here
changes it:**

- Paging, sorting on its own, the schema browse, the drill, relaunch, the journal, and
  the query line's own routing — `docs/wakil/phase-2c-ii-acceptance.md` checks 1–9 and
  11–14.
- The confirmation plane's mechanics, the gate's own refusal sentences for statement
  shapes it already rejected, and the production block as a mechanism — 2c-ii check 10.

**Under test here, because this sub-phase built it:**

- The double-click editor: seeding, commit, cancel, escape, and everything that
  decides whether a cell offers one at all.
- `db_render_update`'s rules as the operator can observe them: quoting, escaping,
  validation, the leading-`=` escape hatch, and the recogniser's refusals.
- The one new interaction between editing and 2c-ii's own mechanisms: a sort followed
  by an edit, and a production cell edit.
- Two questions nothing in the spec or the code decided (checks 22 and 23) — they are
  not judgement calls this runbook can make for the operator, and asking them is why
  it exists as a document rather than a checklist of green commands.

**Not attempted, by the spec's own design, not by an oversight of this runbook:**

- INSERT and DELETE — no cell to double-click for either (spec §10).
- Multi-cell or multi-row edit — one cell, one statement, one confirmation.
- Editing a Mongo document — the driver's write path is honestly unimplemented; check
  11 below confirms the surface says so rather than offering an editor it cannot honour.
- A copy affordance on the grid — not this sub-phase's to add.

### 1.1 Prerequisites

1. **`make build` and `make app-bundle`**, per every prior 2b/2c runbook — `bin/` is
   per-worktree and the running app carries the CLI binaries into
   `Contents/Resources`.

   *On a clean worktree this used to fail* — `app-bundle` runs `swift build`, and
   `default.metallib` is a `.copy` resource SwiftPM cannot load the package graph
   without, but `app-bundle` alone among the three `swift build` paths did not depend
   on `shaders`. Walk defect D6, fixed: `app-bundle: build shaders`. Nothing is owed
   the operator here any more; the step is listed unchanged because it now works.
2. **An org, a project, and a `staging`-or-equivalent environment defining at least one
   MySQL database and one sqlite database** — the same `core` / `events` pair 2c-ii's
   own prerequisites name. Check 12 specifically needs **both engines**, live: MySQL
   through `docker start wakil-acc-mysql wakil-acc-mongo` or the environment's own
   registered connection, and sqlite through `events`.

   **Both engines must be WRITABLE, and this prerequisite did not say so — which is
   what cost the walk three checks.** Invariant 6's rule is that writability comes
   from possessing a second credential the server granted, so a database with no
   `writeRef` is not a database this sub-phase can be walked against at all:
   `describeEditability` returns at its first line and every column comes back
   uneditable for a reason that has nothing to do with what checks 12, 14 and 17
   measure. On this machine `staging` gave `writeRef` to the sqlite `events` and not
   to the MySQL `core`, and the walk read three correct-looking outcomes off a pane
   that could never have been editable. To close them:

   ```
   printf '<password>' | WAKIL_ORG=<org> ./bin/wakil secrets set-db acc-staging-core-write \
     --driver mysql --host 127.0.0.1 --port 13306 --db wakilacc --user root
   ```

   then add `"writeRef": "acc-staging-core-write"` to the `core` entry under
   `environments.staging.databases`. The credential is the operator's to enter — see
   `operator-todo.md`.
3. **A `production` environment**, for check 21. **Read this before walking it**: 2c-ii's
   own runbook (§7, "one check could not be run") found that *this project's*
   `production` defines one database with no `writeRef`, so a mutation there is refused
   by the connection being read-only before `writeGate` is ever consulted — the block
   still holds, just one layer earlier than the plane. If that is still true, check 21
   will find the same thing, and the honest record is "blocked, but by the outer
   defence, not by the gate" — not a failed check.
4. **A Mongo database holding at least one collection with at least one document**, for
   check 11 — the same fixture 2c-i's and 2c-ii's runbooks required.
5. **A table with an ordinary primary key, at least one text column, and at least one
   numeric column, reachable on both the MySQL and the sqlite database** — `events` on
   both satisfies this in the existing acceptance fixtures.
6. **A row the operator does not mind mutating**, on each engine, for checks 12, 13, 14
   and 15 — those checks confirm a cell, run, and inspect what actually got stored, not
   just what the plane showed.
7. **Optional: a MySQL table with a `BIT` column**, for check 17. If none exists in the
   acceptance fixtures, say so in that check's Notes and accept it on the strength of
   `RenderUpdate`'s own tests (`updatestmt_test.go`) rather than inventing a fixture to
   walk a narrow exclusion — the same trade 2c-ii's runbook made for its own check 8.
8. **The launch command**, per `phase-2a-acceptance.md` §1:
   `WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil`.

   **A plain `open app/Wakil.app` does not work, and fails in a way worth knowing.**
   `open` goes through LaunchServices, which does not inherit the shell's environment,
   so `WAKIL_ORG` arrives unset and every child server answers *"WAKIL_ORG is not set —
   every Wakil process runs for exactly one org"* in the agent thread. Nothing in the
   window says the cause. `open --env WAKIL_ORG=<org> app/Wakil.app` works and was
   verified on macOS 26.6.2 by reading the launched process's own environment; the
   direct-binary form above needs no flag because it inherits the shell.

   There is deliberately **no in-app way to set or change the org** — it is a
   launcher-declared value (Invariant 4, and `CurrentOrg`'s own doc comment). Whether an
   operator should be able to CHANGE it without quitting is open question 13, raised by
   this walk.

## 2. The checks

Nothing here is marked PASS. Each check is written for the operator to walk at the
window; the **Result** row under each is left blank on purpose.

### Check 1 — double-click seeds the editor

Open a `db_read_table` pane (or run a plain `SELECT * FROM events`). Double-click an
ordinary text or numeric cell, not the key column.

| Do this | Expect |
|---|---|
| Double-click a writable cell | It becomes a text field, seeded with exactly the value that was drawn there — NULL seeds as empty text, not the word `NULL` |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Walked on `events.id = 1`, not 3. Editor opened seeded with the drawn value. The NULL half is attested by the fixture rather than by the screenshot: row 1's `kind` was NULL before the walk and the editor accepted a fresh value into it without the word `NULL` having to be cleared first. |

### Check 2 — Enter raises the plane, confirm runs, the pane re-reads

| Do this | Expect |
|---|---|
| Type a new value into an edited cell and press Enter, then type `confirm` in the plane and run it | The confirmation plane rises showing one composed `UPDATE` statement. After `confirm`, the cell leaves edit mode and the pane re-fetches its own subject — the new value is on screen because it was re-read, not because the edit painted it directly |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Plane rose showing exactly `UPDATE "events" SET "kind" = 'login2' WHERE "id" = 1`, one statement. After `confirm`, the pane re-fetched and drew `login2`. Confirmed in the database afterwards: `1\|42\|login2\|text`. |

### Check 3 — cancelling the plane keeps the edit open

| Do this | Expect |
|---|---|
| Edit a cell, press Enter, then click Cancel in the plane instead of confirming | The plane dismisses. The cell **stays in edit mode**, holding exactly what was typed — nothing was run, and the operator has not lost their draft |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Cancel dismissed the plane, the agent thread read `db_run_mutation: cancelled — nothing ran`, and the cell stayed in edit mode holding the typed `ddddd`. Nothing reached the database — the stored value was still `login2`. |

### Check 4 — Escape abandons

| Do this | Expect |
|---|---|
| Double-click a cell, type something different, press Escape before pressing Enter | The editor closes and the cell shows its original, unedited value. Nothing was dispatched |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Escape closed the editor and the cell redrew `login2`, the last committed value. Nothing dispatched. |

### Check 5 — Escape right after a cancelled plane, no click in between

This is a fix-round regression: the confirmation plane used to take first responder
and never hand it back, so Escape silently did nothing until the operator clicked the
field by hand.

| Do this | Expect |
|---|---|
| Edit a cell, press Enter, click Cancel in the plane, and **without clicking anywhere first**, press Escape immediately | The edit abandons — same as check 4. If Escape does nothing until a click lands in the field first, that is the regression, live again |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Escape reached the editor with no intervening click. The first-responder regression is not live. |

### Check 6 — a key column offers no editor

| Do this | Expect |
|---|---|
| Double-click the primary-key cell of an otherwise editable row | Nothing happens — no text field appears, no hover brightening either (compare against check 20) |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Double-clicking `id` opened nothing and brightened nothing. **This is where defect D2 was found** — see §4: a double-click that opens no editor hands key focus to the `project` field at the top of the window. |

### Check 7 — one named table is editable, a join is not

| Do this | Expect |
|---|---|
| In a pane's query line, run `SELECT * FROM events`, then double-click a cell. In another pane, run `SELECT * FROM events JOIN <other table> ON …`, then try the same | The first is editable and the footer's trailing label reads `editable`. The second offers no editor anywhere in the grid and the footer reads `read-only` |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | `SELECT * FROM events` → footer `editable`; `SELECT * FROM events JOIN customers ON events.customer_id = customers.id` → footer `read-only`, and no cell in the seven-column result opened an editor. |

### Check 8 — the derived-column trap

The probe's "quiet" hazard: a computed column that happens to share a real column's
name.

| Do this | Expect |
|---|---|
| Run `SELECT id, kind \|\| '!' AS kind FROM events` (or the equivalent for whatever text column exists) | Not editable — the footer reads `read-only`. If a double-click on the `kind` cell opens an editor, that editor would compose `SET kind = …` against the table's real `kind` column while showing the operator a derived value they never saw the source of — this is the failure the recogniser exists to prevent |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | `SELECT id, kind \|\| '!' AS kind FROM events` → `read-only`. The derived `KIND` column also drew with no type annotation, correctly — there is no declared type to name. |

### Check 9 — the CTE trap

The probe's "dangerous" hazard: `events` inside a `WITH` shadows the real table of the
same name.

| Do this | Expect |
|---|---|
| Run `WITH events AS (SELECT 1 AS id, 'z' AS kind) SELECT * FROM events` | Not editable — the footer reads `read-only`. A recogniser that read only the last `FROM events` would call this editable and compose an `UPDATE` against the **real** `events` table for a row that was never on screen; refusing any statement containing `WITH` is what this check confirms holds in the running app |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | `WITH events AS (SELECT 1 AS id, 'z' AS kind) SELECT * FROM events` → `read-only`. **Defect D4 was found here** — the footer read `1 rows`. |

### Check 10 — the recogniser's other refusals, in one sweep

Three more shapes the probe measured must refuse, walked together rather than as three
separate checks.

| Do this | Expect |
|---|---|
| Run each in turn: `SELECT id AS ident, kind FROM events` (aliased column); `SELECT id, id, kind FROM events` (duplicate result name); a qualified name if the environment has one, e.g. `SELECT * FROM <schema>.events` | All three: not editable, footer reads `read-only` |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | All three refused: `SELECT id AS ident, kind FROM events`, `SELECT id, id, kind FROM events`, and `SELECT * FROM main.events`. Each drew `read-only`. |

### Check 11 — a Mongo pane offers no editor

Decision 20's corollary — "everything else stays read-only and says so" — applied to
the one driver whose write path is honestly unimplemented.

| Do this | Expect |
|---|---|
| Open or drill into a Mongo collection (the fixture from prerequisite 4) | The footer reads `read-only`. No cell in the grid responds to a double-click with an editor |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | `probe_events` on `docs`: footer `read-only`, no editor on any cell, `_ID` drawn as `bson.objectid`. **Defect D3 was found here** — switching this pane to `select * from events` left the title reading `DOCS` over SQL rows. |

### Check 12 — a quote and a backslash both store exactly, on both engines

The probe's single most important measurement: a naive `''`-only escaper silently
corrupts a Windows-style path on MySQL, with no error, against a confirmed statement
whose text contained the right value.

| Do this | Expect |
|---|---|
| On the sqlite table, edit a text cell to `O'Brien`, confirm, and read the re-fetched value back. Repeat with `C:\path\n` (type it as literal backslash-p-a-t-h-backslash-n, not an actual newline). Then repeat both edits on the **MySQL** table | All four store byte-for-byte what was typed. The MySQL backslash case is the one to look at hardest — `C:path` with the backslashes silently dropped, or a truncated value, means the fix regressed |

| Result | Date | Notes |
|---|---|---|
| **PARTIAL** | 2026-09-14 | **The sqlite half passes and was verified byte-for-byte.** `O'Brien` and `C:\path\n` both stored exactly; read back from the shell, `hex(kind)` for row 41 is `433A5C706174685C6E` — nine bytes, both backslashes present. **The MySQL half was not run**, because staging's `core` database has no `writeRef` and no `wakil:personal:acc-staging-core-write` credential, so no MySQL pane was ever editable. That is the half this check calls the one to look at hardest, and sqlite passing says nothing about it: a dialect-blind escaper is correct on sqlite by construction. Re-walk once the credential exists. |

### Check 13 — a bare word after `=` is a column reference, and it is silent

Spec §7.4 and the probe §3.1: this is not hypothetical, it is the brainstormed rule the
probe overturned.

| Do this | Expect |
|---|---|
| On a row with at least two text or numeric columns, edit one cell to `=<name of another column in the same row>` (e.g. `=id` or `=kind`), and confirm it | The plane shows `SET <column> = <othercolumn>` — a bare identifier, not a quoted string. After it runs, the edited cell now holds **that other column's current value**, with no error and no warning anywhere. This is worth seeing once: it is the exact mechanism a mistyped `=status` would trigger by accident, and the operator should come away able to recognise a bare word after `=` in the plane's own text before confirming one |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | `=customer_id` on row 3 composed `UPDATE "events" SET "kind" = customer_id WHERE "id" = 3` — a bare identifier, unquoted, exactly as spec §7.4 says. After running, `kind` held `7`, that row's `customer_id`, with no error and no warning anywhere. |

### Check 14 — `=NOW()` and `=NULL`

| Do this | Expect |
|---|---|
| Edit a datetime-capable cell to `=NOW()` and confirm. Edit a nullable cell to `=NULL` and confirm | The first stores a real timestamp, not the four characters `NOW()`. The second stores SQL `NULL`, and the cell then draws as `NULL` in the dimmed style the grid already uses for null — not an empty string |

| Result | Date | Notes |
|---|---|---|
| PASS (operator) | 2026-09-14 | Recorded on the operator's word. **No evidence survives in the fixture**: `events` now holds no NULL and no timestamp, so neither half can be re-checked after the fact. `NOW()` is also not a sqlite function — the expression half, if it ran on sqlite, ran as something else. Re-walk the `=NOW()` half on MySQL once check 12's credential exists; it is the same expression path, and `edit_quote.v` (VARCHAR(20)) will hold a 19-character timestamp. |

### Check 15 — `abc` into an integer column is refused, readably, and nothing runs

| Do this | Expect |
|---|---|
| Edit a numeric column's cell to `abc` and press Enter | No confirmation plane rises. The cell stays in edit mode holding `abc`, and a readable sentence appears (something like `"abc" is not a number, and <column> is a <type> column`) — never a raw engine error, never a silent no-op |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | `abc` into `customer_id`: no plane rose, the cell stayed open holding `abc`, and the surface drew `db_render_update: "abc" is not a number, and customer_id is a INTEGER column`. A readable sentence, not an engine error. (`is a INTEGER` reads awkwardly; not raised as a defect.) |

### Check 16 — a semicolon in a value is refused, and says why

The gate's multi-statement check (`AssertSQLMutation`'s `;` scan) is literal-blind — it
cannot tell a `;` sitting inside a quoted value from one splitting two statements — so
`db_render_update` refuses it before the statement is ever composed.

| Do this | Expect |
|---|---|
| Edit any text cell to a value containing `;`, e.g. `a;b`, and press Enter | Refused before any plane appears, with a sentence that says a semicolon cannot be told apart from two statements and directs the operator to the query line for this edit. The cell stays open with the typed text |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | `a;b` refused before any plane, with `db_render_update: a value containing ";" cannot be edited in the grid, because the safety check that blocks multiple statements cannot tell a semicolon in your text from one splitting two statements; use the query line for this edit`. The cell stayed open with the typed text. |

### Check 17 — a `BIT` column is not editable (optional, needs the fixture)

| Do this | Expect |
|---|---|
| If prerequisite 7's fixture exists: double-click a `BIT` column's cell | No editor opens — `BIT` is excluded from the writable-column list because a quoted literal cannot express it (measured `Error 1406` in the probe). If the fixture does not exist, record that this was accepted on the strength of `updatestmt_test.go` rather than walked |

| Result | Date | Notes |
|---|---|---|
| **NOT ESTABLISHED** | 2026-09-14 | Recorded as passing at the window, but it cannot have passed for the reason this check tests. `edit_bit` lives on the MySQL `core` database, which has no write credential — so `describeEditability` returns at its first line (`if !c.writable`) and **every** column comes back uneditable, `BIT` and `VARCHAR` alike. The observation is real and the outcome is correct; it does not distinguish "BIT is excluded" from "this database cannot be written at all", which is the only thing the check is for. Prerequisite 7's fixture does exist (`edit_bit`, `id INT PRIMARY KEY, flag BIT(1), name VARCHAR(20)`), so this is walkable as written once check 12's credential exists — the `name` column beside `flag` must open an editor and `flag` must not. |

### Check 18 — sort a pane, then edit the top row: the row that changes is the one on screen

The reason `sortedRows` had to become a permutation rather than reordered rows (spec
§4.1): a parallel key array left unpermuted would pair every key with the wrong row —
the single worst failure this whole feature exists to prevent.

| Do this | Expect |
|---|---|
| Click a column header to sort a pane, note which row is now first, edit a cell on that first row, confirm | The row that actually changes — checked by re-reading it, e.g. from a second pane or by scrolling — is the one that was on screen at the top, not whichever row happened to be first before the sort |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Sorted, then edited the row that was first after the sort. The row that changed is the one that was on screen. The permutation holds. |

### Check 19 — clicking the gap selects the row, not nothing

Fix-round regression: framing a cell's hit area by its text's own bounds, rather than
by the column's full width, left the empty part of a wide column and the inter-column
gap dead to the pointer.

| Do this | Expect |
|---|---|
| Click in the empty space of a wide column, past where its text ends. Click in the 16pt gap between two column headers' worth of row content | Both select the row — the selection's left edge (the anchor bar) appears against that row, exactly as a click directly on a cell's text would |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Both the empty part of a wide column and the inter-column gap select the row. |

### Check 20 — hover highlights, and a selected-and-hovered row is legible as both

| Do this | Expect |
|---|---|
| Move the pointer over an unselected row, then over the selected row | An unselected, hovered row lifts faintly. The selected row (anchor bar on its left edge) stays visibly selected when the pointer is also over it — not indistinguishable from a plain hover, and not losing its hover lift either. Separately: hover a row in an editable pane and watch which cells brighten further — the key column's cell should not, everything else should |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Hover and selection are distinguishable, and a row that is both reads as both. The key column does not brighten on hover; the others do. |

### Check 21 — production blocks the edit outright, no plane

| Do this | Expect |
|---|---|
| On the `production` environment, double-click a cell and press Enter | Blocked before any plane rises. Per prerequisite 3, this may be the connection itself refusing to write (this project's `production` defines no writable database) rather than `writeGate`'s own production check — record whichever actually happens; both are a correct block, and the distinction is worth writing down rather than glossing over |

| Result | Date | Notes |
|---|---|---|
| PASS | 2026-09-14 | Blocked, **by the outer defence rather than by `writeGate`** — exactly as prerequisite 3 predicted. `production` defines one database (`core`) with no `writeRef`, so the pane is `read-only` before a cell can be double-clicked at all; there is no editor to press Enter in. Correct, and one layer earlier than this check's wording assumes. The gate's own production branch remains walked only by 2c-ii's check 10. |

### Check 22 — open question 12, asked explicitly

> Is `confirm`-then-Run the right price for changing one cell the operator never wrote
> a statement for? (`north-star.md`, open question 12)

Nothing in the spec or the code decided this, and nothing may — `writeGate` gates
`.mutate` at every origin on purpose, and the operator already paid this cost once on
the typed route without complaint (2c-ii check 10). What was never tested is whether
it holds up when the statement was composed by a double-click rather than typed — the
one case where the plane is the operator's *first* sight of what they are about to
run.

| Do this | Expect / record |
|---|---|
| Edit and confirm several cells in a row — at least four or five, back to back, typing `confirm` each time | Record the operator's own answer, as evidence, not preference: did typing `confirm` every time stay bearable across several edits? Did it start to feel like friction the typed route did not have, because the operator never wrote the statement being confirmed? Write down what was actually felt, not what seems like the "right" design answer |

| Result | Date | Notes |
|---|---|---|
| ANSWERED | 2026-09-14 | **`confirm`-then-Run held up across repeated edits.** The operator ran several back-to-back and raised no complaint about the price itself, which is the question open question 12 actually asks. One friction was reported, and it is not the gate: **editing a second cell discards the first cell's uncommitted draft.** That is implemented behaviour, not a defect — `DataSurface` keeps one editor per surface because there is one confirmation plane — but it was surprising in the back-to-back flow this check creates, which is the one flow that makes it visible. Recorded here rather than in §4, and left unchanged: a second live editor would mean a second statement waiting on one plane. |

### Check 23 — can the operator tell WHY a result is read-only?

Spec §9.3 sketched four per-reason labels (`· more than one table`, `· no primary key`,
`· key not in result`, `· derived column`); they were **deliberately not built**,
because `wakilcore.Editable` carries no reason — it is `nil` or it is not, and
inventing wording here would be guessing at an explanation the code does not have. The
footer today says only `editable` or `read-only`.

| Do this | Expect / record |
|---|---|
| Run a handful of the refused shapes above (a join, the CTE, an aliased column) and read only the footer, as an operator would in the moment, without already knowing which check produced which refusal | Record whether the plain `read-only` label is enough to act on, or whether not knowing *why* — wrong table, missing key, derived column, more than one table — left the operator staring at a cell wondering if something was broken. If the answer is "I could not tell why," that is a defect for this walk to raise, and the fix is a `reason` field carried on the Go side beside the recogniser, not four sentences composed in Swift |

| Result | Date | Notes |
|---|---|---|
| ANSWERED — no defect | 2026-09-14 | **`read-only` alone is enough to act on.** The operator ran the join, the CTE and the aliased column, read only the footer, and reported the bare label sufficient. Spec §9.3's four per-reason labels (`· more than one table`, `· no primary key`, `· key not in result`, `· derived column`) stay unbuilt, now on evidence rather than on the absence of a `reason` field being convenient. |

## 3. Verification — commands confirmed green on this tree

Not a substitute for §2 — the rules these commands prove are not the surface this
runbook exists to walk. Run by the implementer, pasted here so the floor these checks
stand on is visible.

> **This section was wrong when it was written, and that is worth more than the
> commands underneath it.** Re-run on the morning of the walk, `make test-live` was
> **not** exit 0: `TestMySQLEditabilityRowKeysMatchExactlyOneRow` and
> `TestMySQLEditableColumnsExcludeBIT` both failed, and both had failed since the
> commit that introduced them. `make test` cannot reach a live MySQL, so neither
> failure was reachable by anything that ran routinely — the claim below was
> transcribed rather than re-run, and nothing existed to contradict it. Walk defect
> D5, fixed. The numbers recorded here now are from the re-run.
>
> This is the third time on this project that a green claim decided nothing. It is
> the first time the claim itself was false.

```
$ go vet ./...
```
Exit 0, silent — no findings.

```
$ go clean -testcache && go test ./...
ok  	github.com/yehia-khalil/wakil/cmd/wakil	1.258s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-ctx	1.962s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-db	10.670s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-http	2.711s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-pm	11.042s
ok  	github.com/yehia-khalil/wakil/cmd/wakil-recall	3.891s
ok  	github.com/yehia-khalil/wakil/internal/mcpx	5.170s
?   	github.com/yehia-khalil/wakil/internal/mcpx/mcpxtest	[no test files]
ok  	github.com/yehia-khalil/wakil/internal/wakilcore	39.833s
ok  	github.com/yehia-khalil/wakil/scripts	36.731s
```
Exit 0.

```
$ docker start wakil-acc-mysql wakil-acc-mongo
$ make test-live
...
--- FAIL: TestMySQLEditabilityRowKeysMatchExactlyOneRow (0.77s)
    driver_mysql_test.go:707: edit_comp: not editable: (*wakilcore.Editable)(nil)
--- FAIL: TestMySQLEditableColumnsExcludeBIT (0.21s)
    driver_mysql_test.go:766: not editable: (*wakilcore.Editable)(nil)
FAIL	github.com/yehia-khalil/wakil/internal/wakilcore	71.267s
```
**Exit 1** — walk defect D5, on re-running the claim above. Both tests opened their
connection as `Connection{URL: dsn}` and never set `Writable: true`, so
`describeEditability` returned at its first line and `Editable` came back nil for a
reason neither test was measuring. Fixed by setting it; both pass live:

```
$ WAKIL_MYSQL_DSN='…' go test ./internal/wakilcore \
    -run 'TestMySQLEditabilityRowKeysMatchExactlyOneRow|TestMySQLEditableColumnsExcludeBIT'
ok  	github.com/yehia-khalil/wakil/internal/wakilcore	6.765s
```

**The whole `make test-live` run is still owed.** The fixture engines were taken down
before it could be re-run end to end, so the claim that every live test passes together
— including `TestMySQLReadsItsBackslashMode`, `TestMySQLQuoteLiteral`,
`TestMySQLCharsetInjectionCannotReviveBackslashUnsafety` and
`TestMySQLLiteralRoundTrip`, the probe's escaping rules red-verified against a live
MySQL rather than sqlite — is **not** made here. Re-run it with the engines up; that is
the same discipline this section just failed at.

```
$ make app-test
...
✔ Test run with 714 tests in 2 suites passed after 87.472 seconds.
```
714 Swift tests green, up from 708 before the fixes — six added for D1, D3 and D4.
**None of them touch `WakilApp`**, which is the limit stated at the top of this
document and the reason three of the four fixed defects are marked below as awaiting
the operator's eye rather than as proven.

The second, isolated suite (`StopDeliversTheTailOfTheStreamSuite`) failed on that run
and passes on its own:

```
$ swift test --filter StopDeliversTheTailOfTheStreamSuite
✔ Test run with 1 test in 1 suite passed after 13.948 seconds.
```

That is the load sensitivity its own doc comment already records — *"under full-suite
load it lost that race and failed 3/3 runs"* — and is why `swift-test.sh` runs it
apart. Not a walk finding, recorded so the failing line above is not read as one.

Machine: this worktree's build environment, 2026-09-14.

## 4. Defects found during the walk

Six, walked 2026-09-14 against 709 green tests. **All six are fixed on this branch.**
The numbering is this walk's own (D1…D6) and does not continue
`phase-2c-ii-acceptance.md`'s.

*(Corrected 2026-09-14 by the branch review. This paragraph, and the summary at the head
of the document, read "four are fixed; two are carried" while all six D-headings said
FIXED — a count nothing in the document supported. The two carried things are **items
inside** D2 and D3, not defects of their own, and they are named at the end of this
section so the count and the list agree.)*

Three of the six fixes live in `WakilApp` or are only observable there, so they could
not be proven by any test this project can write. They were carried back to the window
and **confirmed by the operator on 2026-09-14** — the scrollbar gone, the focus staying
in the pane, the title following the query. That second pass is what this document's own
stated limit demands of its own repairs, and it is the only instrument that reaches
them.

---

### D1 — a pane scrolls sideways with room to spare · check 1, seen throughout · FIXED, confirmed at the window 2026-09-14

Three columns in a 700pt pane, all of them fitting, and a horizontal scrollbar under
them. The walk caught what no test could have: the *same two columns* drew with a
horizontal scrollbar at 500 rows (check 8) and with none at all at one row (check 9).
Nothing about the columns changed between those two panes — only whether the **vertical**
scrollbar existed.

`DataSurface` measured itself with a `GeometryReader` and handed that width to
`paneColumnLayout`, which divides it so the columns plus spacing sum to *exactly* it;
the rows were then pinned to the same number by `.frame(minWidth:)`. Correct arithmetic
against the wrong number. Under macOS's **legacy** scroller style the vertical scroller
is not an overlay — `NSScrollView` insets the document view by its width — so the
content came out exactly one scroller wider than the space it had, every time the
scroller appeared. On a trackpad-only machine (overlay scrollers) the defect does not
exist, which is why it survived: `AppleShowScrollBars` is `Automatic`, and *Automatic*
becomes *Always* the moment a mouse is attached.

**Fix.** `paneContentWidth(surfaceWidth:verticalScrollerAllowance:)` in `WakilKit`,
subtracting the allowance `DataSurface` reads from `NSScroller` per render — the real
number for the style this machine is set to, not a hardcoded 15. Reserved whether or
not the scroller is currently showing: predicting its visibility means knowing the
rows' total height against a viewport height the function cannot see, and being wrong
the other way re-opens the defect. A short result loses the allowance in invisible dead
space to the right of its last column, and the layout does not jump when a result
crosses the height at which the scroller appears. Three tests in
`PaneColumnLayoutTests`.

### D2 — a double-click that opens no editor hands focus to the `project` field · check 6 · FIXED, confirmed at the window 2026-09-14

Double-click a key column, or any cell in a read-only result, and key focus went to
`TextField("project")` at the top of the window — so the next keystroke edited the
project name. That field is 2b-i scaffolding (`WakilWindow.swift`), still present
because ⌘P covers panes, projects, sessions and providers but **not environments**, and
check 21 needs a way to reach `production`. It is the first focusable control in the
window, and a click that takes no focus leaves the window free to hand focus to it.

**Fix.** `DataSurface` gains one focus anchor per surface — `.focusable()` bound to a
`@FocusState` — and the double-click asserts it on the branch where no editor opens.
Only that branch: asserting it on the editable branch would fight the cell's own
`TextField` for first responder, and asserting it on the plain tap would steal
`Return`/`Escape` from an editor already open one cell over, which is exactly the
regression check 5 exists to catch. One anchor on the container rather than
`.focusable()` per cell, which would put 500 rows' worth of them in the window's
key-view loop.

**The scaffolding row itself is not removed**, and should be: it is chrome
`design-language.md` §1 forbids outright. It cannot go until ⌘P can set an environment.
Carried, not fixed.

### D3 — the pane title lies, and it is 2c-i's complaint still standing · check 11 · FIXED, confirmed at the window 2026-09-14

A pane opened on the Mongo `docs` database and then pointed at `select * from events`
kept drawing `DOCS` over SQL rows. Reproducible on any pane and any table: `CORE` and
`EDIT_BIN` appear over `events` rows elsewhere in this walk's own screenshots. The rail
listed the pane under the stale name too.

`Pane.title` was written once, by `LayoutStore.open`, and never again — `resolvePane`
retitled nothing when it resolved an existing pane. **2c-i's walk raised this exact
complaint** and `DBPane`'s doc comment still records it — *"a pane titled EVENTS showing
customer rows has a lying title"* — with the ruling that the fix for a lying title is to
show the query rather than to guess a better title. The query line was added underneath.
The title above it was left lying. The fix was half-applied and the half that was
skipped is the half the operator was complaining about.

**Fix.** `LayoutStore.retitle(id:to:)`, called by `resolvePane` when the caller has a
name for the new subject. Not a guess — it is the same value the pane would have been
born with had that subject opened it, and Wakil still never parses SQL to infer a table
(`queryTargetPane`'s comment refuses that in the operator's own words: a join names two
and an aggregate names none usefully). `title` became optional so that a
`db_run_query` carrying no `database` — which a one-database environment permits —
leaves the existing name alone rather than replacing a stale-but-real name with the
literal `"db"`. Two integration tests in `StandardActionsTests`.

**What this leaves open, for the operator and not for this document.** The title is now
true, and it is also redundant: `EVENTS` drawn above `events · select * from events`
says nothing the line below does not. §1's "futurism through absence" argues for
deleting the title from the pane chrome and keeping `Pane.title` for the rail alone.
That is a design call, not a defect fix, and it is not made here.

### D4 — `1 rows` · check 9 · FIXED

The CTE check's single row. Nothing was broken; it just does not read like the rest of
the surface. `paneRowCountLabel` in `WakilKit`, with a test. Zero stays plural.

### D5 — `make test-live` was not green, and §3 said it was · pre-walk · FIXED

`TestMySQLEditabilityRowKeysMatchExactlyOneRow` and `TestMySQLEditableColumnsExcludeBIT`
both failed, and had failed since `4eb85f1`, the commit that introduced them alongside
the check that breaks them. Both opened `Connection{URL: dsn}` without `Writable: true`,
so `describeEditability` returned at its first line — *a database with no write
credential must not advertise an editor it can never honour* — and `Editable` came back
nil for a reason neither test measures. A test bug, not a product bug: the product
behaviour under test is correct and unchanged.

It survived because `make test` cannot reach a live MySQL, so nothing that runs
routinely could see it, and §3's claim was transcribed rather than re-run. See the note
at the head of §3: the defect worth recording is not the two red tests, it is that a
document certifying a phase asserted a verification it had not performed.

### D6 — `make app-bundle` fails on a clean worktree · pre-walk · FIXED

```
error: couldn't build .../default.metallib because of missing inputs:
       app/Sources/WakilApp/default.metallib
```

`app-bundle` runs `swift build`, and `default.metallib` is a `.copy` resource SwiftPM
cannot load the package graph without. `app-build` and `app-test` both already declared
`shaders` as a dependency for exactly this reason, with a comment saying so;
`app-bundle` was the only path into `swift build` that did not. It survived because
anyone who had run the tests first had already built the shader. `app-bundle: build
shaders`, verified from a tree with the `.metallib` deleted.

---

### Carried, not fixed — the two items, in one place

Neither is a defect this walk found; each is a follow-on a fix above left standing, and
each is recorded in its own defect's text as well.

1. **The project/environment scaffolding row** (D2). Chrome `design-language.md` §1
   forbids outright, and it cannot go until ⌘P can set an environment.
2. **The pane title, now true and now redundant** (D3). `EVENTS` drawn above
   `events · select * from events` says nothing the line below does not. Deleting it from
   the pane chrome and keeping `Pane.title` for the rail alone is a design call, and it
   is not made here.

### Not a defect, recorded so it is not re-found

**Editing a second cell discards the first cell's uncommitted draft** (check 22). This
is implemented behaviour — `DataSurface` keeps one editor per surface because there is
one confirmation plane, and its own comment says so. It was reported as friction in
check 22's back-to-back flow, which is the only flow that makes it visible, and it is
left unchanged: a second live editor would mean a second statement waiting on one plane.

## 5. Result

**Not met. Twenty of twenty-three checks pass; three do not close, and all three fail
for one reason.**

Staging's MySQL database carries no `writeRef` and no write credential, so no MySQL pane
was editable at any point in this walk. That leaves:

- **Check 12 PARTIAL** — the sqlite half passes and was verified byte-for-byte
  (`hex(kind)` = `433A5C706174685C6E`). The MySQL half, which this check's own text calls
  the one to look at hardest, was not run. sqlite passing says nothing about it: a
  dialect-blind escaper is correct on sqlite by construction, and the probe measured
  that the same escaper stores `C:\path\n` as `C:path` plus a newline on MySQL, with no
  error, against a statement whose text contained the right value.
- **Check 14 PASS on the operator's word, with no surviving evidence** — `events` now
  holds neither a NULL nor a timestamp, and `NOW()` is not a sqlite function.
- **Check 17 NOT ESTABLISHED** — the outcome is correct and does not distinguish "BIT is
  excluded from the writable columns" from "this database cannot be written at all",
  which is the only thing the check is for. Prerequisite 7's fixture does exist
  (`edit_bit`), so it is walkable as written once the credential does.

Prerequisite 2 now carries the commands. Three checks, one credential.

The other twenty pass, including every one that decides whether the feature is safe: the
recogniser refuses the join, the CTE, the aliased column, the duplicate name, the
qualified name and the derived-column trap; the key column offers no editor; Mongo
offers none; a bare word after `=` is visibly a column reference in the plane before it
runs; `abc` into an integer and `;` in a value are both refused readably with nothing
dispatched; a sort followed by an edit changes the row that was on screen; and
production is blocked outright. Checks 22 and 23 are answered as evidence — the
`confirm`-then-Run price held across repeated edits, and the bare `read-only` label is
enough to act on, which is why spec §9.3's four per-reason labels stay unbuilt.

Six defects were found against 709 green tests, two of them in this document's own §3.
All six are fixed. D1, D2 and D3 are the three whose fixes
live in `WakilApp`, where there is no test target and `WakilKit`'s green tests prove only
the rules underneath them; the operator walked all three at the window on 2026-09-14 and
confirmed each — the horizontal scrollbar gone, a double-click on a key column leaving
focus in the pane, and a pane retitling itself when its query changes database. **No
defect in §4 is outstanding; two follow-on items are carried and remain so** — the
scaffolding row and the redundant pane title, both listed together at the end of §4.
Neither is a defect, and neither blocks this sub-phase.

**One thing and one thing only stands between this walk and met: a MySQL write
credential on staging.** Checks 12, 14 and 17 are re-walkable as written the moment it
exists — prerequisite 2 carries the commands and check 17's fixture (`edit_bit`) is
already in place. Until they are re-walked, the `2c-ii-b` row in `north-star.md` stays
unmarked.
