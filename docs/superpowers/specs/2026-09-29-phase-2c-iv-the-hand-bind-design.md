# 2c-iv: the hand bind

**Date:** 2026-09-29
**Status:** design approved by the operator 2026-09-29, section by section
**Sub-phase:** 2c-iv — the third and last build of it, after
[`2026-09-26-phase-2c-iv-api-client-pane.md`](../plans/2026-09-26-phase-2c-iv-api-client-pane.md)
and [`2026-09-27-phase-2c-iv-api-pane-surface.md`](../plans/2026-09-27-phase-2c-iv-api-pane-surface.md)
**Binding spec:** [#179](https://github.com/yehia-khalil/rafiq/issues/179). This file adds
surface, and rules nothing #179 already rules.
**Closes:** [#308](https://github.com/yehia-khalil/rafiq/issues/308)

---

## Problem

**The operator cannot bind a value.** `api_bind` and `api_unbind` are registered, tested and
reachable by the agent. Nothing in the window reaches them. The runbook says so in its own
words: the exit criterion's second clause — *"a value bound from another pane resolves in the
URL before the send"* — is *"true for the agent and unreachable for the operator"*.

It is worse than a missing drop. G4 is *"name the hole, drop the row"*, and **both halves are
agent-only**:

- **No gesture makes a hole.** #112 and #150 rule that a hole is *"made by a gesture rather than
  by typed characters"*, and `apiFieldWrite` writes every typed field as one literal. No ruling
  ever said which gesture, so none was built. Today only `api_set_request` makes a slot.
- **No gesture drops a row.** There is no drag or drop anywhere in the app.
- **No gesture unbinds.** A chip is `Text`, and no control dispatches `api_unbind`.

That is three writes the agent can make and the operator cannot, against Invariant 2 (*UI
controls and the agent dispatch the same actions*) and #179's story 81 (*"nothing in this pane
operator-only"*). Stories 31, 33, 34 and 35 are the operator's, and none can be walked.

**And #308 means no check can reach any of it.** The e2e fixture declares no databases, so no
pane holds a row and there is nothing to drop.

### A defect found while designing this

**The path and body fields silently destroy a binding.** Both are always typable, and both are
drawn from `apiRenderedPath`, which renders a slot or a bound value as `<name>`. Commit that
field — one keystroke and Return — and `apiFieldWrite` writes `<name>` back as **literal text**.
The binding is gone and nothing says so. That is the silent overwrite #112 exists to stop.
Query and header rows are already guarded by `apiRowIsTypable`; the path and body never were.
It is fixed here, by Section 1's locking rule, because the split field replaces the code that
has the defect.

---

## Scope

**In:** a gesture that makes a named hole; the drop of a grid row onto an api pane; a control
that unbinds a chip and one that removes an unbound hole; the locking rule that fixes the defect;
#308's fixture; the checks all of that makes possible; the runbook amended to walk it.

**Out:**

- **Anything about how binding works.** Matching by exact column name, re-binding a dead value,
  live against captured, the key-column re-read, the one-author rule — all `api_bind`'s, all
  ruled by #179, none touched.
- **Turning the middle of typed text into a hole.** See *Approaches*.
- **Fill-first binding from the window.** A hole made by hand is always named, so a drop from
  the window always fills a named hole. The fill-first case stays the agent's.
- **A new action.** Every gesture here dispatches one that exists.

---

## Approaches

Three were weighed for making a hole.

- **A. Split fields, and `+ hole`. Chosen.** A field of parts draws as its parts, each literal
  its own text box; a control at the end appends a named hole. Holes and literals are both
  writable by `api_set_request`, so the registry is untouched. Its cost: a hole goes at the end
  of what is typed, so `/v1/bookings/{id}/confirm` is built left to right, and a hole in the
  middle of existing text means retyping the tail.
- **B. Select text, then "Make hole".** The better gesture for a pasted URL. Declined: the
  deployment target is macOS 14.4, which has no `TextSelection` for a SwiftUI `TextField`, so it
  needs a wrapped `NSTextView`; and a context-menu item is not in the accessibility tree until
  the menu is open, so its check is worse. More code for one convenience.
- **C. Make the whole field one hole.** Declined: it cannot express `/bookings/{id}/confirm`,
  which is the demo request.

---

## Section 1 — Split fields and `+ hole`

**Where.** The four places that hold parts: the path, the body, and the value of every query
row and every header row. The content type admits no parts (#116) and is unchanged.

**How a field draws.** Its parts, in order: each literal run is its own text box, each unbound
hole an amber chip, each bound value a filled chip. The body's text boxes are multi-line; the
rest are single-line. An empty field is one empty text box followed by `+ hole`.

**Typing.** Committing a text box — Return for a single-line box, ⌘Return for the body, and
never losing focus *(corrected 2026-10-01: Ruling 6 found the shipped rule was Return only, and
Amendment 8c made the body an editor)*, with the existing one-author mark — writes the field's **whole** part list through `api_set_request`, carrying
its neighbouring holes as `{"slot": name}`, so nothing a gesture made is lost. This replaces
`apiFieldWrite`'s single-literal write with a pure function in WakilKit:

```swift
apiPartsWrite(field: ApiDraftField, parts: [ApiPart], editing: Int, text: String, pane: String) -> JSONValue
```

A text box committed empty writes the field without that literal rather than an empty one.

**`+ hole`.** A pressable control, `api.<field>.hole`, opens a small name box,
`api.<field>.hole.name`. Return appends `slot(name)` and an empty literal after it, so typing
carries on. Escape cancels. A blank name is refused on screen and nothing is dispatched. The
name is taken **exactly as typed** — no trimming, no case folding — because matching is by exact
column name and a normalised name would match a column the operator did not type.

**Removing an unbound hole.** Its chip carries `×`, `api.<field>.part.<i>.remove`, which writes
the field without that part. No `api_unbind`: an unbound hole is only a part.

**The locking rule.** A field holding a **bound** value draws **read-only**: its text boxes
become plain text and `+ hole` is not drawn. This is `apiRowIsTypable`'s rule, extended to the
path and the body, and it is the defect's fix. The whole field locks, not only the chip, because
a write is the whole field and `api_set_request` refuses to write a bound value. **The query and
header regions lock whole** when any of their rows holds a bound value, for the same reason one
level out: a row write carries the whole region. *(Added 2026-09-29 — see Amendments, 2.)*

**Identifiers.** The field's **last** literal box keeps the field's own identifier —
`api.path`, `api.body`, `api.query.<name>`, `api.header.<name>` — so typing carries on where
every shipped check already types; earlier literal boxes are `<field>.part.<i>`. Then
`<field>.hole`, `<field>.hole.name`, `<field>.part.<i>.remove` and `<field>.part.<i>.unbind`.
`<i>` counts from zero within the field's parts, which is `api_unbind`'s `index`. *(Corrected
2026-09-29 — see Amendments, 3.)*

---

## Section 2 — The drop

**The drag starts at a grip, not the row.** A grid row already uses a click to select, shift and
command to extend, and a double-click to edit; a drag on the whole row would contend with every
one. Each row carries a grip, `db.row.<i>.grip`: **one vertical ellipsis `⋮`, dimmed, in a leading
gutter of its own** — the columns start after the gutter, so the grip never overlaps a cell. It
is drawn on every row, dimmed, and brightens on hover. *(Revised 2026-09-29 by the operator —
see Amendments, 5.)* The grip starts a SwiftUI `.draggable`, not the canvas's `DragGesture`.

**The pane's own drag is the risk.** `Canvas` attaches a `DragGesture` to the **whole** pane, so
the grip must win against it. A child's gesture normally takes priority over a parent's
`.gesture`, but nothing here has measured it. **The plan's first task measures it**; if the grip
loses, it takes `.highPriorityGesture`.

**The payload is the row's position, and what the row held.** `PaneRow.id` *is* the on-screen
position (`WindowModel.swift`), so the view holds no identity for a row that survives a re-sort,
and inventing one is out of scope. The payload is therefore `{source pane id, on-screen index,
cells}` at the moment of pickup, where `cells` is each `PaneCell` as `String?` (`nil` for a
null) — a `Codable` `Transferable` type. At the drop the view compares the row **now** at that
index with the payload's cells: the same, it dispatches `api_bind {pane, source, row: index}`;
different — the source re-fetched or was re-sorted mid-drag, and the index now names another
row — it **refuses on screen** and dispatches nothing, because a guess is what `api_bind`'s
description forbids. The refusal reads *"the grid changed while the row was being dragged —
drop it again"*. The comparison is a pure function in WakilKit:

```swift
apiDropRow(_ picked: ApiDragPayload, current: [PaneRow]) -> Int?
```

*(Corrected 2026-09-29 — see Amendments, 4. The design first compared a generation and a sort;
the snapshot carries no generation, and publishing one would change `read_pane`.)*

**The drop target is the whole api pane,** because `api_bind` fills every matching hole and
there is no single hole to aim at. While a DB pane's row is over it, the pane draws a drop
outline at the focus ring's weight — not a second luminous element, which §8 forbids. Nothing
else dragged over the pane draws an outline or is accepted.

**The result line.** One line, drawn from the action's result, cleared by the operator's next
edit or send *(Corrected 2026-09-29 — see Amendments, 6.)*:

| Result | Line |
|---|---|
| `filled > 0`, nothing else | `Filled 2` |
| with `rebound > 0` | `Filled 2 · re-bound 1` |
| with `unmatched` | `Filled 1 · no column for booking_ref` — every miss named once, together (story 35) |
| `filled == 0`, `rebound == 0` | `No hole matches a column of this row`, amber: nothing has gone wrong |

A refusal from the action draws on the same line, in its own words. The text is a pure function,
`apiBindSummary(_ result: JSONValue) -> String`.

**What does not change.** The operator's drop is operator-origin, so Decision 27 lets it land
mid-edit — already ruled, and already `api_bind`'s.

---

## Section 3 — Unbind and remove

**Two different `×`, because they are two different acts.**

- **On a bound chip:** `api.<field>.part.<i>.unbind` dispatches `api_unbind {pane, region,
  index}`. A hole made by hand is always named, so this always returns it to an amber hole. When
  no bound value is left in the field, the locking rule releases it and it is typable again.
- **On an unbound hole:** `api.<field>.part.<i>.remove`, Section 1's write. Nothing is bound, so
  nothing is unbound.

---

## Section 4 — The fixture, the checks, the runbook

### The fixture (#308)

*(Corrected 2026-09-29 — see Amendments, 1.)*

1. **The seed writes a SQLite file**, `bookings.db` at the fixture root, holding one table,
   `bookings(id INTEGER PRIMARY KEY, booking_id TEXT, status TEXT)`, with two rows. One is the
   phase log's demo row, `8842 / BK-2026-8842`: it is the case that proves a hole named `id`
   never takes `booking_id`.
2. **The check stores its DSN** by dispatching `db_set_dsn` with `{fixtureRoot}/bookings.db`,
   which also records the database in `project.json`. Not the seed: the fixture keychain is
   recreated at launch, after the seed has run.

The file is seeded rather than written by the one check that wants it, on
`fixtureAPIEntries`'s own principle: *"the pane's whole surface is behind this."*

### WakilKit tests, test-first

- **`apiPartsWrite`** — a table: editing one literal between two holes, appending a hole,
  removing a hole, a literal committed empty, a blank hole name refused, neighbours carried
  as slots.
- **`apiDropRow`** — the index when the row is unchanged; `nil` when a re-sort or re-fetch put a
  different row there; `nil` when the index is past the end; a null cell and an empty string
  never compare equal.
- **`apiBindSummary`** — the four lines, and a refusal passed through.
- **The locking rule** — a path or a body holding a bound value is not typable; one holding only
  literals and slots is.

### The e2e checks

Each is seen red against the merge-base by `make e2e-new`, then green under `make e2e`.

| Check | What it drives | What it clears |
|---|---|---|
| `api-hole.jsonl` | `+ hole` in the path by hand; parity against `api_set_request` writing a slot; `×` removes it; a blank name refused | the new hole controls |
| `api-bind.jsonl` | open a DB pane, run the query, drag a grip onto the api pane, read the bound value back through `read_pane`; the same bind by dispatch; `id` binds `8842` and not `BK-2026-8842`; a miss named once | `api_bind` off the coverage gate; the grip and the result line |
| `api-unbind.jsonl` | `×` on a bound chip returns a hole; parity against dispatch | `api_unbind` off the coverage gate |
| `api-bound-locks.jsonl` | a path holding a bound value offers no text box | the defect's regression |

The drag is a new `axresolve` mode, `--drag-to`, and a `drag` arm on both `do` and `parity`
*(corrected 2026-09-29 — see Amendments)*. Both endpoints' frames are read immediately before
the drag, because a point from an older tree can land on whatever has since moved under it.

### The runbook

`docs/wakil/phase-2c-iv-acceptance.md`:

- **The paragraph *"The drop gesture does not exist"* goes.** It stops being true.
- **The ten-check cap holds.** Check 4 absorbs the new gestures rather than a check 11 being
  added: *"a request built entirely by hand — including a hole in the path, filled by dropping a
  row from a DB pane — reaches a real server."*
- **The machine half is re-rendered** by `make e2e-runbook`, and nothing in it is written by
  hand.

---

## Done when

- The operator can make a hole, drop a row onto it, unbind it and remove it without the agent.
- The operator can add and remove query and header rows, edit the query from the path box and
  the Query region alike, and write a multi-line body. *(Added 2026-10-01 — see Amendments, 8.)*
- The path and body cannot be typed over a binding.
- `make test` and `make app-test` are green; `make e2e` is green; `make e2e-new` saw every new
  check red against the merge-base; the coverage gate names no `api_bind`, and names `api_unbind`
  only as excused *(Corrected 2026-09-29 — see Amendments, 7.)*.
- #308 is closed by the PR.
- The runbook is re-rendered and ready to walk. **Walking it is the operator's**, and 2c-iv is
  not `Met` until they have.

---

## Amendments

### 2026-09-29 — three corrections from writing the plan

Found by reading the code the plan has to name, before any was written. The body above is
edited to match; this section is the record of what changed and why.

**1. The fixture stores no DSN, and the check does.** The design had the seed write the DSN
into the fixture's Keychain through a `wakil secrets set` path. **There is no such path**:
the fixture has never stored a secret — `billing`'s `authRef` resolves to nothing on purpose
(`fixtureAPIEntries`). And a seed-time write could not survive anyway: `Seed` runs **before**
the launch, and `Launch.makeKeychain` **deletes and recreates** the fixture keychain at launch.
[#316](https://github.com/yehia-khalil/rafiq/pull/316) is what makes the replacement possible:
`db_set_dsn` returns now, so a check stores the DSN by dispatching it, with the path spelled
`{fixtureRoot}` (`e2e/driver/expand.go`) — the path `2e-settings-databases.jsonl` already
proves. **The seed writes only the SQLite file**, and `db_set_dsn` records the database in
`project.json` itself, so the seeded `Databases` stays empty.

**2. A region holding a bound row locks whole, not only that row.** `apiRowWrite` writes a
query or header region **entire**, carrying its neighbours through `apiPartJSON` — which
encodes a bound value as `name`/`binding`/`source`, and `api_set_request` refuses that with
`boundValueIsAGesture`. So **today**, once one query row is bound, typing into any OTHER query
row is refused whole. This is the same defect class as the path's, one level out, and the fix
is the same rule: `apiRegionIsTypable(rows)` is false when any row holds a bound value, and
every row of that region draws read-only until the binding is unbound.

**3. The typing box keeps the field's identifier.** Every shipped check types into `api.path`,
`api.body`, `api.query.<name>` and `api.header.<name>`. So the **last literal box of a field —
the one typing continues in — keeps the field's own identifier**, and only the earlier literal
boxes take `.part.<i>`. The chips' `.part.<i>.remove` and `.part.<i>.unbind` are unchanged. No
shipped check changes identifier.

**And the drag is driven by `axresolve`, not Orca.** The design named `orca computer drag`.
The harness's own notes record that **Orca refuses to click the fixture at all**
(`window_not_focused`), which is why `axresolve` exists, and `Orca.ClickAt` has no caller. A
drag is therefore a new `axresolve` mode posting CGEvent mouse-down, dragged and up between two
elements' frames, and it is the plan's first measurement.

**4. The drop compares cells, not a generation.** The design had the payload carry the source's
generation and sort. `DataSurfaceSnapshot` carries `sort` but **no generation**, and adding one
changes what `read_pane` publishes — the struct's own comment holds it to *"exactly the fields
`read_pane` has served since 2c-i"*. Comparing the row's **cells** needs no plumbing and is the
question actually being asked: is the row at this index still the row the operator picked up?
A re-fetch that returned identical values at the same index passes, and binds against the new
generation — which is what the operator is looking at.

**5. The grip is a dimmed `⋮` in its own gutter.** Revised by the operator on seeing the
spike's probe grip — a solid bar laid over the first column: *"it looks ugly the drag thing,
cant we have it as the three dots above eachother and slightly dimmed? and its overlapping with
the id column"*. So: one U+22EE `⋮` glyph, at `ink.opacity(0.30)`, rising to `0.55` on hover;
in a reserved leading gutter the row's columns are laid out after, never an overlay on a cell;
drawn on every row rather than only on hover, so it can be found without hunting and a row
does not change width when the pointer arrives. The anchor row's luminous left edge (§8's one
luminous element) stays at the very edge, outside the grip.
**Over the grip the pointer is an open hand** — also the operator's (*"might change the cursor
to show hand instead to hint that it is draggable?"*). `NSCursor.openHand`, pushed on hover and
popped on exit, because `.pointerStyle(.grabIdle)` is macOS 15 and the target is 14.4. While
the row is being dragged the drag session owns the cursor.

**6. The result line carries no identifier.** Every identifier this pane carries sits on an
element with an accessibility action behind it, and the result line — a `Text` with no action —
would be the exception. The identifier was removed for that reason, and checks read the line by
its text instead.

**7. The gate names `api_unbind` as excused, not owed.** The Done-when line above read as though
the gate still owed a parity check for it; it excuses it instead, because after the `×` unbind
leaves the position holding a hole, and `api_unbind` refuses one — the same reason
`uncoverable.tsv` §1 carries it. The gate names no `api_bind`, and `api_unbind` there is a
permanent excuse, not a gap this branch left open.

### 2026-09-29 — the measurements (Task 1)

Measured on a throwaway branch (`spike/hand-bind-drag`, never merged) against a fixture
instance launched the way the harness launches one (`Seed`, `StageBundle`, `Launch.Start`, the
MCP socket). The DB pane held **real rows**: a scratch SQLite file stored with `db_set_dsn`
(driver `sqlite`, the DSN a bare path) and read with `db_run_query` into `db-1`, three rows;
`api_open billing` gave `api-2`, moved beside it with `pane_move` (the cascade had laid it
over `db-1`'s rows). The probe grip was a 12pt × row-height `Rectangle` in an
`.overlay(alignment: .leading)` applied **after** the row's `.accessibilityElement(children:
.ignore)`, carrying `.contentShape(Rectangle())`, `.draggable("probe")` and
`db.row.<i>.grip`. `ApiPane`'s root carried `.dropDestination(for: String.self)`, which
appended each drop to a log file (an `open -n` app's stdout is not readable). No drag was done
by hand; Step 1 was measured with Step 3's synthetic drag, and the pane's position read back
through `read_layout` after every run.

**1. The grip wins against the pane's drag. No fallback.** Across 43 clean synthetic drags from a
grip, the pane **never moved** (`db-1` stayed at `(60, 60)` in every `read_layout`), and every
run that completed a session printed `DROP ["probe"]`. A drag from the grip to empty canvas
dropped nothing and did not move the pane either. **The control:** the same 20-step drag
started on a row *cell* instead moved `db-1` by exactly its translation, `(60, 60)` →
`(160, 100)` — so the canvas's `DragGesture` is live over the rows, and the grip wins against
it rather than there being nothing to win against. Step 1b (narrowing the canvas's gesture to
the header) is **not needed**, and Section 2's *"if the grip loses, it takes
`.highPriorityGesture`"* does not arise — which is as well, since a `DragGesture` there would
swallow the session. **Later tasks use a plain `.draggable` on the grip and leave `Canvas`
alone.**

**2. The grip is in the accessibility tree.** `e2e/bin/axresolve --pid <pid> --identifier
db.row.0.grip --press` resolved: `ok: true`, role `AXUnknown`, enabled, 12 × 40; the press
came back `accessibility_action_unasserted`, as expected for a view with no `AXPress`.
`db.row.1.grip` and `db.row.2.grip` are listed by a full read. The row's own element keeps
`.accessibilityElement(children: .ignore)` and its label. **No fallback** (`.contain` on the
row) is needed.

**3. A synthetic drag starts a real SwiftUI drag session — but ten steps is not reliable.**
From the grip's centre to the api pane's interior (~985pt across), `leftMouseDown`, N ×
`leftMouseDragged` 10 ms apart along the line, `leftMouseUp` at the target, each
`CGEvent(mouseEventSource: nil, mouseType:, mouseCursorPosition:, mouseButton: .left)`
posted `.cghidEventTap`, preceded by one `mouseMoved` to the start point and 50 ms, the app
made frontmost first. Clean runs (a first batch overlapped another session's `make e2e`
fixture and is discarded):

| Sequence | Dropped |
|---|---|
| 10 steps, no hold | 11 / 15 |
| 10 steps, 150 ms hold after mouse-down | 6 / 9 |
| **20 steps, no hold** | **9 / 9** |
| 20 steps, 150 ms hold | 9 / 9 |

A failed run is a session that never reached the target — no drop, and the pane unmoved —
never a pane drag. The hold does not help; the step size does (≈98pt jumps fail about a
third of the time, ≈49pt ones never did). **The sequence Tasks 7 and 8 build `axresolve`'s
drag mode from:** `mouseMoved` to the grip's centre, 50 ms, `leftMouseDown`, **20**
`leftMouseDragged` at 10 ms intervals along the straight line to the api pane's centre,
`leftMouseUp` at the target, no hold — the smallest sequence that held, nine in a row. For a
much longer drag, keep the step at or under ~50pt rather than the count at 20.

**Does Amendment 5's gutter change any of this?** Not the gesture: a leading-gutter grip is
still a descendant of the pane view carrying `Canvas`'s `DragGesture`, which is the only
relation measured, and it is further from the row's `.onTapGesture` than the overlay was.
**It changes the accessibility tree only if it is put in the wrong place.** The probe
resolved because it sat *outside* the view `.accessibilityElement(children: .ignore)` is
applied to; a gutter placed inside `rowView`'s `HStack` ahead of that modifier would be
swallowed into the row's element and `db.row.<i>.grip` would not resolve. So the gutter's
grip must be a sibling of the row's ignored element, or be applied after it, as the probe was.
Two things it does change and the probe did not measure: the grip's **hit area** — a `⋮` glyph
is a few points wide, so it needs a `.contentShape` over the whole gutter cell (the probe's
was 12pt × row height) — and the grip's **frame**, which moves the columns right by the
gutter's width. Drawing it on every row, as Amendment 5 says, is also what keeps it resolvable:
a grip drawn only on hover would be absent from the tree for every row the pointer is not over.
The open-hand cursor was not measured; it plays no part in whether a session starts.

**2026-09-29 — the 9/9 was marginal (Task 8, Ruling 12).** Run as e2e checks, the sequence
above sometimes failed to drop: the api pane drew its drop outline and the drop was never
performed, because the mouse-up followed the last drag event at once and the drag session had
not yet seen the pointer resting over the destination. Ten runs of each drag check (a run
passes only if every drag in it dropped):

| End of the drag | api-bind | api-unbind | api-bound-locks |
|---|---|---|---|
| mouse-up at once (the sequence above) | 9 / 10 | 9 / 10 | 8 / 10 |
| 10 ms, then mouse-up | 10 / 10 | 10 / 10 | 10 / 10 |
| **one more drag event at the target, 10 ms, mouse-up** | **10 / 10** | **10 / 10** | **10 / 10** |
| three more drag events at the target, 10 ms, mouse-up | 10 / 10 | 10 / 10 | 10 / 10 |

`axresolve` now ends every drag with the bold row: 20 ms at rest on the target.

### 2026-10-01 — the walk's first findings

**8. The pane gets the three things the walk could not do without.** Found by the operator on the
first attempt at the runbook, at checks 3 and 4, before any check could pass: *"how to add query
params?"*, *"how can i add more headers? custom headers for example?"*, and *"i cant have multi
lines in request body of a json format? this needs to change"*. Designed section by section and
approved by the operator on 2026-10-01. No new action; every gesture writes through
`api_set_request`.

**8a. Path ↔ query, both ways.** *(The operator chose full two-way sync over lifting `?…` into rows
on commit.)* The draft keeps path parts and query rows **apart**, as today; the wire, `read_pane`
and every action are unchanged. The **path box becomes a view of both**: the path parts, then
`?`, then the rows as `name=value` joined by `&`, a hole or bound value in a query value drawn as
its chip in place. A query row edited in its region redraws the view, because the view is
derived. A commit in the path box parses the whole view back with a pure WakilKit function: split
at the first literal `?`; before it, the path parts; after it, rows split on `&`, each at its first
`=`, splitting only inside literal text, so a chip stays inside the value it sits in. Path and
query are written in **one** `api_set_request`. The rules:

- A chip before a row's `=`, in a query **name**, is refused on screen: *"a hole can sit only in a
  query value"*. Names stay text (#179's parts table).
- A query name may not contain `=`, `&`, `?` or `#`, because the view could not round-trip it;
  enforced at the view's parse and at `+ query`.
- The view shows names and values **unencoded**, and what is typed is what is meant: `%20` is three
  characters, and Go encodes the wire as it does today.
- Row order and duplicate names are kept; a trailing `?` with nothing after it is no rows.
- A bound query value locks the Query region (Amendment 2) **and therefore the path box**, which
  now shows it; unbinding the chip unlocks both.
- A keystroke in the path view marks **both** `.path` and `.query` for Decision 27, so an agent
  cannot write either under the operator's hand.

#179 story 20 (*"so that I never have to type a `?`"*) is **amended, not withdrawn**: the Query
region remains, and typing `?` in the path becomes an optional second way in, never the only one.

**8b. Adding and removing rows.** `+ query` and `+ header` sit on their regions' heading lines.
Each opens a name box (`api.query.add.name`, `api.header.add.name`); Return adds the row with an
empty value and moves focus into its value box; Escape cancels. A blank name is refused on screen.
Header names: any name, taken exactly as typed and compared case-insensitively; a duplicate is
admitted at the gesture and refused at Send through the existing aggregated duplicate refusal,
as #179 rules. **`content-type` is not refused**: naming it moves focus to Wakil's own
content-type row, which is the one content-type there is. **`authorization` is refused**, because
caller-set `Authorization` is on wakil-http's deny list (#179, *what stays refused, unchanged*)
and a typed credential would land in `read_pane`, the journal, the Recent strip and every cURL
line; the refusal teaches the honest route, *"authorization comes from the API entry's credential
(`wakil secrets set-api`), not from a typed header"*. The rest of that deny list — `Cookie`, `Host`
and any `Proxy-*` — is refused at the gesture too, naming the list, so no header is admitted on
screen only to be refused at Send; so is the entry's own `authHeader` when it names another
header (story 90) *(corrected — see 8d: the window cannot know it, so Go refuses it at Send)*. Query names follow 8a's rule. Each of the
operator's rows draws a `×` (`api.query.<name>.remove`, `api.header.<name>.remove`, the `[row]` form
for a duplicate); Wakil's own rows never draw one, and a row holding a bound value draws none until
its chip is unbound. Adding and removing write the region whole, as a row edit already does; the
rulings are `apiRowAddWrite` and `apiRowRemoveWrite` in WakilKit.

**8c. The body is an editor.** *(The operator chose ⌘Return plus Format.)* Each literal box in the
body is a `TextEditor`: Return inserts a newline, Tab two spaces, and the box grows to about sixteen
lines before scrolling. **⌘Return commits.** **Send commits a pending body first** and then sends,
as one awaited sequence on `WindowModel`, so the two writes cannot race and nothing typed is left
behind. The single-line boxes — path, query and header values — still commit on Return. Ruling 16's
drop refusal names the body's own gesture: *"press ⌘Return in the body first, then drop"*.
**`Format`** (`api.body.format`) re-indents only: a WakilKit tokenizer rewrites the whitespace
between JSON tokens at two spaces, never reorders a key and never rewrites a number or a string, so
key order and an integer above 2^53 survive — a round trip through `JSONSerialization` would lose
both. A chip is one opaque value token, so a body with holes formats around them. A body that does
not tokenize as JSON is refused in amber, *"not JSON — nothing formatted"*, and is unchanged.
Format is a write, committed like ⌘Return. This supersedes Ruling 6 for the body only.

**What this changes elsewhere.** `api-surface.jsonl` commits its body with Return; that step becomes
`hotkey cmd+Return` — a changed gesture, **no changed identifier**. New checks: `api-query-sync.jsonl`,
`api-rows.jsonl`, `api-body-editor.jsonl`, each seen red against the merge-base. The runbook's
check 4 is rewritten to add a query param both ways, a custom header, and a multi-line body, and
the walk restarts from check 1.

**8d. Two corrections from writing its plan (2026-10-01).** *The entry's own `authHeader` is
not refused at the gesture*, as 8b said: `list_apis` deliberately publishes neither `authRef` nor
`authHeader` (#179, *Keychain entry names are no business of an agent*), so the window cannot
know it. Go's existing dynamic deny list refuses it at Send, inside the one aggregated refusal.
*A query value holding `&`* — set from the Query region or by the agent — cannot be shown in the
path view and parsed back unchanged, so while one exists **the path box draws read-only** with
the note *"a query value holds & — edit it in the Query region"*; the Query region stays editable.
A query name is already barred from `& = ? #`, so only a value can cause it.

**Out, and next.** An API entry form in Settings — add or edit an entry, store its token in the
Keychain as the Databases form stores a DSN — is the honest UI for a credential, and the reason it
was ruled read-only in 2e (*"a form built on today's shape is one rebuilt on someone else's
schedule"*) is discharged now that 2c-iv has settled the shape. It is a design of its own, after
2c-iv, built on `SettingsForm.swift` (design-language §14).

### 2026-10-03 — the walk's second findings

**9. The pane, made to send what it shows.** Found by the operator walking all ten checks on
2026-10-03, against `ed1af70` and then `bd5ab8b`. Checks 1, 2, 3, 5, 7, 8 and 9 passed; 4, 6 and 10
did not. Five defects and twenty changes, designed section by section and approved by the
operator the same day. The walk's record is the phase log's; this section is the design.

**Already fixed, recorded here.** *B4:* `wakil-http`'s `send` refuses every mutation unless
`WAKIL_IN_WINDOW=1`, and the window never set it — decisions.md's *"the setter is still owed"*
(#187) had no owner, so no POST, PUT, PATCH or DELETE had ever left a pane. No check could see it:
every check sends at an `.invalid` host. `childProcessEnvironment` now sets it (`bd5ab8b`, test
first). It reaches only the window's own three children, which is the decision's scope.

#### 9a. Saved as typed *(the operator chose "write on a pause" over every keystroke and over on-blur)*

**A typed change is written ~300 ms after the last keystroke**, as one `api_set_request` through
`operate`, and **at once** on Return, on focus leaving the field, and before any gesture that
reads or rewrites the draft: Send, a drop, `+ query`, `+ header`, `+ hole`, `×`, Backspace on a
chip, Format, a method press, an entry pick. The path view and the Query region follow each other
within that pause, both ways (8a, unchanged in substance). **Nothing is ever uncommitted.**

What that ends: *B5* — Send committed a typed body (8c) but not a typed path, so the walk's box
showed `/test` while the request went to the bare origin and the production plane read *"Send POST
https://httpbin.org"*; Ruling 8's cross-field refusal (*"press Return in the path first, or Escape
there to discard it"*); and Ruling 16's drop refusal while a box holds typed text. Return in a
single-line box still writes at once; in the body Return is a newline and ⌘Return sends (8c's
⌘Return commit becomes redundant and is kept as a send).

**Decision 27 is restated, not weakened.** *An agent's write to a draft request is refused whole
while the operator's cursor is in a field it names.* The mark becomes **focus**: set on focus in,
cleared on focus out, and the path box marks both `.path` and `.query` as 8a's keystroke did. The
refusal, its aggregation and its wording are unchanged. Leaving the field releases it, so the
agent's retry lands. `edits` (`currentText`/`lastRendered`) is replaced by the focused field;
`read_pane` still publishes no keystroke state.

**Escape** writes the field back to what it held when it took focus — one write — and leaves it.
⌘Z within a field undoes keystrokes as the text system does. 8d's read-only path box (a query
value holding `&`) and Ruling 23's note are unchanged.

**The journal** records one entry per pause, not per keystroke.

#### 9b. Sending

**B1. GET and HEAD send no body.** The body stays in the draft (a method press back to POST
restores it to the wire) and its box dims; no line is drawn. `request` is never handed `body` or
`contentType`, so `wakil-http`'s schema refusal (*"unexpected additional properties"*) cannot
reach the operator.

**B2. A content type beside an empty body is not refused.** The send omits it, as
`apiWireArguments` already does; the content-type row dims. No line is drawn.

**B3. A refusal or error line wraps in full** — under Send, under a table, in the response. A line
names a region only when the refusal is that region's; a tool or transport error carries no
region (the walk saw *"Path · validating…"*).

**W14. A send in flight, and cancelling it.** While a send is in flight, Send becomes **Cancel ·
1.2 s** (`api.send` keeps its identifier; its action becomes `api_cancel`), the seconds counting.
A second `api_send`/`api_request` on that pane, from either channel, is refused: *"a send is
already in flight on this pane"*. **`api_cancel {pane}` is a new action**, so the agent can cancel
as the operator does (Invariant 2); with nothing in flight it is refused. Cancelling sends MCP
`notifications/cancelled` for the call's request id — `MCPClient` gains that; today it can only
stop waiting — and `wakil-http` aborts the HTTP request through the call's context. The plan's
first task proves the abort against a slow local server; if Go does not carry the context into
the request, threading it is the fix. The outcome:

- a read method: *"cancelled after 4.2 s"*, grey; Recent records it as cancelled.
- a mutation: *"cancelled after 4.2 s — the server may already have it"*, the existing
  fate-unknown state in amber, because a cancelled write may have landed; Recent records it so.

The 30-second timeout stays the backstop.

**W13. The production plane names the whole request.** *"Send POST
https://httpbin.org/test?page=2 with a JSON body {test, customer_id}"*: the URL that will leave,
path and query, a hole drawn by its name; the body by shape — a JSON object's top-level keys, *"a
JSON array of 3"*, or *"14 bytes of text"*. No part counts.

**W12. Switching to the environment already active is a no-op** and raises no plane.

**W1. Every api pane re-resolves its entry when the environment changes** — on a switch, and at
launch for panes restored from the layout. One `list_apis`, then per pane: an entry of that name
in the new environment gives the pane that environment's origin and credential flag (the walk:
switching staging → production → staging left *"no origin"* on an entry both declare); no such
entry keeps the name, and the URL line reads *"production declares no entry named unset — pick
one"*. The chooser always offers the active environment's entries. **`api_open` with no entry in
an environment of several opens the pane unpointed**, from ⌘K and from an agent alike, with the
whole list in the chooser and in its result's `entries`; Send from an unpointed pane is refused,
*"pick an entry first"*. Nothing is guessed, so #183's reason for refusing (*a guess would send one
backend's credential to another backend's host*) still holds — by a later refusal instead of an
earlier one.

**W17. A binary column is refused at the drop**, not at Send: *"k is a VARBINARY column — binary
values arrive corrupted, so they can't be bound"*. The garbled origin the walk saw (*"“k” reads ·
no key · k"*) goes with it.

#### 9c. Layout and editing

**W10, W11. The pane splits.** The request (method, URL, tables, body, Send) above, the response
below, each scrolling on its own; the request half takes 55% by default. The response's head
(status chip, URL, timing, size) stays pinned and only its body scrolls. **Recent** is a strip at
the foot of the response half, at most four rows tall unfolded, scrolling within. With nothing
sent the response half shrinks to its one line. Nothing draws outside the pane or under the
window's toolbar (the walk: a 200 KB HTML reply pushed the request under `Open…` / `Actions…`).

**W4. Backspace removes a chip.** Backspace just after a chip — Delete just before — acts as its
`×`: an unfilled hole is removed; a bound value is unbound back to its hole, and a second press
removes that. The `×` moves **inside** the chip, at its right edge.

**W7. Body `+ HOLE` inserts at the cursor** — at the end only if the body has never had focus. The
walk's hole landed after the closing `}` and made the body not JSON.

**W16. A bound value locks only itself** — Amendment 2's region lock is superseded. Text and holes
beside a bound chip stay editable; a write carries the bound part unchanged, and `api_set_request`
admits a bound part identical to one the region already holds (same name, same source), wherever
the text around it moved it; a bound part it does not already hold is still refused, so a write
can keep a binding but never make one. Its `×` and Backspace are the only ways
to change it. (The walk could not remove an unfilled `id` while `v` beside it was bound.)

**The rest.** *W5:* `+ query` and `+ header` focus their name box. *W6:* a refusal under a table
spans the pane's width rather than the heading row's last cell. *W2:* the body heading reads
`BODY · JSON` from the content type, `BODY · TEXT` otherwise. *W8:* the pane's title follows its
entry. *W19:* the content-type value's placeholder is `application/json`. *W18:* a Recent row shows
the values sent — `GET /customers/<id:3>/confirm`, a value over 24 characters shortened with `…` —
and the Bound list each hole's current value, `id = 3 · live · events.customers`; a credential was
never in the draft and is in neither. *W15:* Recent is one list per **project and environment**,
shared by every api pane in it; Reopen loads into the pane it is pressed in. It stays in memory,
capped at 200; persisting it is a decision of its own.

**W20. The response's headers are shown.** Asked on the walk: *"is there a way to see the response
headers returned?"* `ApiResponseSnapshot` already holds them and `read_pane` publishes them; the
pane never drew them. The pinned response head gains a two-way choice, **Body · Headers**
(`api.response.body`, `api.response.headers`, the settings vocabulary's `SegmentedChoice`),
default Body. Headers draws a `HEADER | VALUE` table in the request tables' style, names in
byte order of the name, wrapping, uncoloured (§5: the status chip alone carries hue). A refusal or a
transport failure has no headers and draws no choice. *(The order is byte order, not the server's:
the wire carries a Go map, and its JSON encoder sorts the keys.)*

#### 9d. What this changes elsewhere

- **decisions.md**: Decision 27 gains a dated amendment restating the mark as focus (9a), and
  #183's ambiguity refusal one moving it to Send (W1).
- **Checks**: `api-query-sync`, `api-rows`, `api-body-editor`, `api-hole`, `api-bind` and
  `api-set-request` lose their Return/Escape/uncommitted steps for 9a's model. New checks, each
  seen red against `ed1af70`: saved-as-typed (a typed path is what Send sends), the one-author
  rule by focus, `api_cancel` down both channels against a slow local server, the GET body left
  off, W1's re-resolve across a round-trip switch, W16's per-part lock, Backspace on a chip.
- **The runbook**: check 4 drops *"press Return"* throughout and adds Cancel; check 8 is walked by
  leaving the cursor in the path; check 10 adds the round-trip switch. **The re-walk is checks
  4, 6 and 10**, plus a look at the split layout.

**Out.** Persisting Recent; a drag handle between the halves; an API entry form in Settings (8,
*Out, and next*).

### 2026-10-04 — one editor per field

**10. A field is one text editor, and a hole is a token inside it.** Found on the third walk
(2026-10-04): a body with holes is drawn as literal boxes and chips laid side by side, so a
multi-line JSON body around a chip misaligns — a chip sits at the top of a two-line box, not
after its text. The same box-and-chip layout carried the single-line fields' key catcher and
caret return, which cost plan B four fix rounds and two live-debug windows. Designed section by
section and approved by the operator on 2026-10-04 (approach A over styled `{{name}}` text and
over fixing the box layout). **The draft, the wire, `read_pane`, every action and Decision 27's
wording are unchanged**: only how the pane draws and edits a field changes.

#### 10a. The editor and the model

**`ApiFieldEditor`** — an `NSTextView` on TextKit 2, wrapped for SwiftUI — replaces the boxes in
every field that can hold a hole: the path box (the path↔query view, 8a), each query value,
each header value, and the body. The content type's value holds no hole and stays a `TextField`.

**Inside the text**, a literal is characters and a hole or bound value is **one attachment
character** carrying which part it is (the slot's name, or the bound value's identity). It is
drawn by **`ApiTokenView`**, an attachment *view* (TextKit 2's `NSTextAttachmentViewProvider`), so
the chip is a real view: amber for a hole, ink for a bound value, with its `×` a real button
carrying the shipped identifiers `api.<key>.part.<i>.remove` / `….unbind`, `i` the part's index
in the field. An identifier is set only when it changes (the AXError -25200 rule).

**`ApiEditorText`** (WakilKit, pure) maps a field's parts to the editor's text and back,
exactly: adjacent literals merge, empty literals drop, a token keeps its identity. The editor
holds no rule of its own.

**Saved as typed (9a) is simplified, not replaced.** Each field is **one box** holding its
parts, and a flush writes the field whole in one `api_set_request`. Focus marks, `queued`,
`takenOver`, Escape's focus-in baseline, the 300 ms pause and the surface chain stay, one box per
field.

#### 10b. Behaviour

- **Typing, the caret, selection, arrows, undo/redo, input methods and wrapping are AppKit's**,
  in every field. Nothing custom moves the caret.
- **A token is one atomic character.** Backspace just after it, Delete just before it, or its
  `×`: a hole is removed; a bound value is unbound to its hole first, then a second press removes
  it (W4, W16). This is the editor's one custom key rule, one text-change check.
- **A selection** deletes or replaces holes in it as text. A selection containing a **bound**
  value is refused on that field's line — a write can neither drop nor make a binding (W16),
  except through the token's own Backspace/`×`.
- **`+ hole` inserts at the caret in every field** (the path's no longer appends), and at the end
  in a field the caret has not been in.
- **Moving holes.** A hole can be **copied, cut, pasted and dragged** within a field and between
  fields — a hole is a name. A **bound value can move only by dragging it within its own field** (operator, 2026-10-04: narrower than *region*, because a move between two rows is two writes and the first would drop the binding) —
  one write carries it, so the binding is never dropped. Copying it pastes its **hole**; cutting a
  selection that contains one is refused, as any delete of it is; dragging it to another region
  drops its **hole** there and leaves the binding where it was (W16: a write can carry a binding,
  never make or silently drop one). Copying to another app gives `<name>`. **Text pasted from
  outside stays literal** — `<id>` is not parsed into a hole; only `+ hole`, a drop, the agent and
  a hole moved between Wakil's own fields make tokens (a private pasteboard type carries them).
- **Return**: single-line fields save; the body inserts a newline and ⌘Return sends.
- Unchanged: the drop, Format (a token is an opaque value), the path↔query split and 8d's `&`
  note, Wakil's own rows.

**Deleted:** `ApiChipKeyCatcher`, most of `ApiChipKeys`, `ApiFieldItems`, `ApiBodyCaret`, the P9
cursor return (`chipFocus`, `lineCaretOwed`, `takeChipFocus`), the per-box `ForEach`, and
`ApiPaneFlow`'s flow layout where wrapping becomes the text view's. `ApiBodyTextView` becomes
`ApiFieldEditor`.

#### 10c. Checks, and a retired identifier

**One shipped identifier family is retired, deliberately:** the per-box `api.<key>.part.<i>` of a
literal box. A field now has one identifier — `api.path`, `api.body`, `api.query.<name>`,
`api.header.<name>` — and checks reach a position by focusing the field and moving the caret, as
the operator does. The token buttons' `….part.<i>.remove` / `….unbind` are kept. Checks that
address a box are rewritten (`api-hole`, `api-chip-keys`, `api-chip-keys-second-chip`,
`api-bound-locks`, `api-body-hole-cursor` and any other `part.<i>` box reader). New: a multi-line
JSON body with two holes, formatted, tokens in place; (a hole dragged between fields is
covered by unit tests and the walk — the harness cannot drag from inside a text view, measured
by the spike); a bound
value copied into another region pastes its hole. Each new or changed check is seen red against
`ed1af70`.

**The plan starts with a spike and a hard stop:** a minimal TextKit 2 text view with one
attachment view whose `×` is in the accessibility tree with its identifier and is pressable by the
harness. If that fails, the operator decides before anything is built on it.

**Out, and next.** **Pasting a cURL command** into the pane, filling the method, path, query,
headers and body — the URL must match one of the environment's entries (Wakil sends to no other
host), and a pasted `Authorization`, cookie, `Host` or `Proxy-*` header is dropped with a note.
Its own amendment, after this one.

### 2026-10-05 — a cURL command pasted into the path

**11. Paste a cURL command into the path, and the pane is that request.** Amendment 10's *Out,
and next*. The operator copies a request out of a browser's devtools, an API's docs or a
colleague's message and wants to send it from Wakil without retyping it. Designed in chat and
approved by the operator on 2026-10-05, question by question. **The wire, `read_pane`'s shape,
every existing action and Decision 27's wording are unchanged**; one read-only Go tool and one
Swift action are added.

#### 11a. Where it happens, and what it replaces

**The trigger is a paste into the path editor.** When the pasteboard's plain text, after leading
whitespace, starts with `curl ` or `curl\` (a line continuation), the path editor's paste
(`readSelection`) calls `api_fill_from_curl` instead of inserting the text. A paste anywhere
else — a query value, a header, the body — stays text, and so does any paste into the path that
does not start that way. No new control is drawn.

**It replaces the whole draft** — method, path, query, headers and body — in one write. There is
no confirmation (Rule 1). The line under the request says what happened, whole (Rule 8):
*"Filled from cURL · billing · dropped: Authorization, -k"*, and carries **Undo**. The pane keeps
the draft it replaced, once; **Undo** puts it back in one write. The kept draft is forgotten at
the next edit, the next Send, or the next fill. After the fill the caret sits at the end of the
path (Rule 3), and the pane stays where it is (Rule 6).

**Placeholders are text.** `{{id}}`, `{id}`, `<id>` and `:id` arrive as literal characters; a
hole is made by hand, as everywhere else (operator, 2026-10-05).

#### 11b. Which entry it goes to

The URL is matched against the active environment's API entries by `baseUrl`: **the same origin
(scheme, host, port), and the URL's path starting with the entry's base path.** The longest
matching base path wins. What follows the base path is the draft's path; the query is split off
by the existing path↔query rules (8a).

- **The pane's own entry matches:** filled in place.
- **Another entry in this environment matches:** the pane switches to it, exactly as if the
  operator had picked it in the chooser, and the line names it (Rule 7: the paste already says
  which API is meant).
- **An entry matches only in another environment:** refused — *"this cURL is for billing in
  production; switch environment first"*. Switching environment is a bigger act than a paste
  should make silently.
- **Nothing matches:** refused — *"this cURL is for api.other.com; no entry in staging has that
  host"*, naming the entries it could have matched. This is the invariant: Wakil sends to no
  other host.

A refusal leaves the draft untouched.

#### 11c. What of the command is kept

| The command carries | Wakil |
|---|---|
| `-X` / `--request` | sets the method |
| `-d`, `--data`, `--data-raw`, `--data-ascii`, `--data-urlencode`, `--json` | sets the body; with no `-X`, the method is POST, as curl does. Repeated data flags join with `&`. `--json` also sets `content-type: application/json` |
| `-G` / `--get` | moves the data into the query, method GET |
| `-H` / `--header` | a header row, in order; `content-type` goes to Wakil's own content-type row |
| `-H 'Authorization: …'`, `Cookie`, `Host`, `Proxy-*` | **dropped and named** — the deny list (8b); the line points at `wakil secrets set-api` for a credential |
| `-u` / `--user`, `-b` / `--cookie` | **dropped and named** — credentials |
| `-F` / `--form`, `--data @file`, `--data-binary @file`, `-T` | **dropped and named** — Wakil reads no file on a paste and sends no multipart body |
| `-k` / `--insecure` | **dropped and named** — Wakil always verifies TLS |
| `-s`, `-S`, `-v`, `-i`, `-L`, `--compressed`, `-o`, `-O`, `--max-time`, `--connect-timeout`, `-w`, `--http1.1`, `--http2` | ignored without a word — they change curl, not the request |
| any other flag | **dropped and named**, never refused (Rule 7) |
| a body on a GET or HEAD | dropped and named (Rule 7) |
| a `#fragment` | dropped and named |

**What is read:** POSIX shell quoting — single quotes, double quotes with `\` escapes, `$'…'`,
and `\`-newline continuations — which covers Chrome's and Firefox's *Copy as cURL (bash)*,
Postman's export and API docs. Windows `cmd` quoting (`^"`) is not read: *"not a cURL command
Wakil can read"*. So is a text holding more than one command (`&&`, `;`, `|`).

#### 11d. The parts

**`parse_curl {text}`** — a new **read-only** tool on `wakil-http`. Pure: no network, no
configuration, no file read. It returns `method`, `url`, `headers` (ordered name/value pairs),
`body`, `dropped` (each with its flag or header **name** and a reason) and `ignored` (flag names).
A dropped header or flag is named, **never carried with its value**, so a credential in the
pasted text does not leave the tool. Swift parses no shell and no cURL (the 2c-ii-b precedent:
Go classifies, Swift decides).

**`api_fill_from_curl {pane, text}`** — a new Swift action, registered beside `api_set_request`
and reached through the surface doors like every write. It asks `parse_curl`, matches the entry
(11b), drops the deny-listed headers, moves `content-type`, splits path and query, and writes the
whole draft, switching the entry where 11b says to. It answers the line. The agent can call it;
Decision 27's one-author refusal applies to the agent as to any write (*"the operator is editing
Path"*); the operator's own paste is their edit and never meets it.

**The journal records the result, not the paste:** the entry, whether it switched, the
`dropped` names and the line. The draft is in the pane store and `read_pane`, as any draft is.
The pasted text is never journalled, never in `read_pane`, never in Recent.

**Every ruling is WakilKit's, with a test that fails first:** the entry match, the header drop,
the content-type move, the GET-body drop, the line's wording, the kept draft and its forgetting.
The path editor's paste only asks `apiPasteIsCurl(_:)` and calls the action.

`curlEmitsAndNeverParses` keeps its meaning — Copy as cURL is still quoted for a shell and never
read back by Wakil — and its comment says that the paste is read by Go, not by the emitter.

#### 11e. Checks and the walk

- **Go:** table tests for `parse_curl` from real copies — Chrome and Firefox *Copy as cURL (bash)*,
  a Postman export, httpbin's documented examples — and every row of 11c. One test asserts that
  no dropped value (an `Authorization` token, a `-u` password, a cookie) appears anywhere in the
  result.
- **WakilKit:** the entry match (own entry, another entry, another environment, no match,
  longest base path), the header and flag drops, the split, the whole-draft write, Undo and its
  forgetting, and that the journal line holds no pasted text.
- **e2e:** `api-paste-curl.jsonl` dispatches `api_fill_from_curl` on a fixture pane — the
  pasteboard is not visible to the harness — and asserts the draft, the switched entry and the
  line; then presses **Undo** and asserts the previous draft. A second check asserts the
  no-match refusal leaves the draft untouched.
- **The walk:** a new runbook check 11 — copy a request from a browser's devtools, paste it into
  the path, send it; Undo; paste a cURL for another entry; paste one for a host with no entry.
  The paste trigger itself is walked, not checked.

**Corrected while writing the plan (2026-10-05).** 11b's match cannot stay in Swift: the api actions
read the active environment's entries only (`list_apis`), and 11b's *"an entry matches only in
another environment"* needs every environment's. The match is a second read-only `wakil-http`
tool, `locate_api_url {url}`, which reads the project configuration and nothing else. Swift still
decides what the match means (switch, refuse, fill). And `parse_curl` returns
`content-type: application/x-www-form-urlencoded` for `-d` data with no content type, because that
is the request curl would send.

**Found on the walk (2026-10-06).** A host differing from an entry's only by a leading `www.` matches that entry (an exact match wins); the line names it — *host www.httpbin.org taken as httpbin.org*. The request still goes to the entry's base URL. Any other subdomain is a different host. An exact host in any environment wins over a `www.` match: a paste naming another environment's entry exactly is refused with its switch-environment line.
