# Wakil Phase 2b-i — Structure

**Status:** draft for review · **Created:** 2026-09-08 · Conforms to
`docs/wakil/north-star.md`

2b as chartered — *"the void, the Core (Metal), planes, magnetism, the rail, ⌘P/⌘K,
motion"* — is not one spec. It is a visual language, a GPU renderer, a layout engine, a
navigation model, and five correctness items 2a deferred. This spec covers **2b-i
only**: the structure that the design language is later applied *to*. It ships a window
that is still ugly, and that is deliberate for the same reason 2a's was.

## 0. Where 2b-i sits

| | Delivers | Exit |
|---|---|---|
| ~~2a~~ | Harness, action registry, agent bridge, write gate, context switcher, one crude pane | **Met 2026-09-08** |
| *probe* | Metal feasibility and frame cost | **Done** — `docs/wakil/phase-2b-probe.md` |
| **2b-i (this spec)** | Third action kind, pane model, magnetic canvas, the rail, ⌘P/⌘K | Several panes coexist, snap, and are reachable three ways; layout is dual-driven |
| 2b-ii | The void, planes, the Core, motion, the thought thread, production treatment | `design-language.md` §1–9 realised at budget |
| 2b-iii | The write-gate UI and first `.mutate`, session resume, the provider picker, signing | 2a's acceptance checks 5 and 6 finally run |
| 2c | DB pane in full (§8), API client pane, terminal pane, session browser | Each fully dual-driven |
| 2d | Push-to-talk, pluggable STT, live transcription | The charter's Phase 2 exit criterion |

**Why structure before surface.** §10's magnetism and §3's three planes are statements
about *several panes arranged against each other*. Neither means anything with one
pane. Styling a single-pane window and then rebuilding it for many is Decision 9's
finding — that a pane built before its architecture exists is a pane that gets rebuilt —
wearing a new hat. The colour, type and motion tokens are the only thing a surface-first
order would have delivered early, and those are cheap to define here and apply in 2b-ii.

**Why the carry-forwards are last.** 2b-iii is correctness work with no dependency on
any of this, and it is what unblocks 2a's unrun acceptance checks. It could equally run
first as its own small spec; it is placed last because 2b-i forces one of its questions
open anyway (§2), and answering that one in isolation is cheaper than answering all
five.

**Toolchain.** Xcode 26 and the separately-downloaded Metal Toolchain 17F109 are both
installed and verified (probe §1). 2b-i needs neither — it draws nothing — but the
`make shaders` step the probe designed is 2b-ii's first task and the dependency is
recorded in `operator-todo.md` now rather than then.

---

## 1. Scope

**In:**
- A third `ActionKind`, and an origin-aware write gate
- `Pane` and `LayoutStore`: pane identity, geometry, focus, and the snap graph
- Layout as dispatched actions, at commit granularity
- The magnetic canvas: free-floating drag, edge snapping, coordinated shared borders,
  maximize
- The rail, as a projection of `LayoutStore`
- ⌘K over the action registry, and ⌘P over panes, projects and sessions
- `session_list`, without which ⌘P's session source has no ids to offer (§6.2)
- `read_layout`, so the agent can see where things are
- Per-project layout persistence

**Out:** every element of `design-language.md`'s presentation — the void, the Core,
depth planes, parallax, the motion budget, the thought thread's real form, the
production treatment. Also: more than one pane *type* (§3), more than one window (§9),
the write-gate UI, session resume, the provider picker, signing, voice, and undo.

**One pane type, many instances.** 2b-i ships `db` and lets you open several of them.
The layout engine arranges rectangles that own state and dispatch actions; it does not
care what is inside them. Defining a pane-*type* protocol now would mean guessing at the
requirements of `terminal`, `api` and `editor` before any of them has been specified,
and 2c is where those requirements actually arrive. The slot is built here; 2c fills it.

---

## 2. The third action kind

### 2.1 The problem, precisely

`ActionKind` has two cases and `writeGate` asks one question of them: *could this damage
the world outside Wakil?* Reads cannot, so they run. Mutations can, so they are gated
everywhere and blocked in production.

Some actions change **Wakil itself** and nothing outside it. Neither case fits:

- Filed `.mutate`, `writeGate` blocks them in production — so you could not drag a pane
  while pointed at a production database. Absurd.
- Filed `.read`, they run unchecked from every origin, agent included.

2a chose `.read` for `ctx_set_project` and `ctx_set_environment`, for exactly the first
reason, and recorded the reasoning in `StandardActions`' own doc comment. The 2026-09-08
acceptance run then found what that reasoning had not weighed — the third party. Asked
only to *list* projects, the agent also **set** the active one:

```json
{"action":"ctx_list_projects","origin":"agent","outcome":"ok"}
{"action":"ctx_set_project","origin":"agent","outcome":"ok","params":{"name":"wakil-acceptance"}}
```

Harmless that day: it set the project already active. But the active
`(org, project, environment)` is what Invariant 5 says there is exactly one of, and what
every subsequent action from either driver resolves against. An agent that moves it
unasked silently redirects everything after it.

2b-i makes this unavoidable rather than a curiosity. Layout adds eight actions with the
same shape, and they are dispatched constantly.

### 2.2 The change

```swift
public enum ActionKind: String, Sendable {
    case read      // observes; changes nothing
    case control   // changes Wakil's own state; the world is untouched
    case mutate    // changes the world outside Wakil
}
```

`writeGate` gains `origin` and a target-environment argument:

```swift
public func writeGate(
    environment: String,
    kind: ActionKind,
    origin: ActionOrigin,
    targetEnvironment: String?
) -> GateDecision
```

| Kind | Origin | Decision |
|---|---|---|
| `.read` | any | `.allow` |
| `.control` | `.ui`, `.debug` | `.allow` |
| `.control` | `.agent`, `targetEnvironment` is production | **`.gate`** |
| `.control` | `.agent`, otherwise | `.allow` |
| `.mutate` | any | `.block` in production, `.gate` elsewhere |

`targetEnvironment` is the environment that will be active **after** the action, and it
is non-`nil` for exactly one action: **`ctx_set_environment`**, where it is the
environment named in its params. For every other action it is `nil` and the production
row cannot fire.

**`ctx_set_project` deliberately does not carry one**, and the reason is a Phase 1
guarantee rather than an oversight. `wakilcore.SetProjectChecked` keeps the current
environment name if the incoming project defines one by that name, and otherwise clears
it to `""`:

```go
active.Project = entry.Path
if _, ok := proj.Environments[active.Environment]; !ok {
    active.Environment = ""
}
```

There is no per-project "last active environment" anywhere on disk to restore from. So
switching project can only **preserve** the current environment or **drop to none** — it
can never elevate a staging session into a production one. An operator already in
production who switches project stays in production, but that is not *entering*
production: the badge already said so and nothing changed. Gating it would charge a
keystroke for a transition that cannot happen.

This is the only place the gate depends on Phase 1 behaviour, so it is the only place a
Phase 1 change could silently widen it. `StandardActionsTests` pins the guarantee
directly against the real `wakil-ctx` binary (§8), so that a future `SetProjectChecked`
which *did* restore a per-project environment would fail a test here rather than open a
hole quietly.

### 2.3 Why this shape and not the alternatives

Two other designs were considered and rejected.

**Visibility alone** — make context switching plain `.control` and rely on the
always-visible environment badge (§12) plus 2b-ii's 500 ms switch animation to make an
agent-originated switch impossible to miss. Cheapest, and it does answer the "silent"
half of the complaint. It does not answer *"nothing stopped it"*, and it makes an agent
walking into production a thing you notice afterwards rather than a thing you agreed to.

**A fourth kind `.context`, gated from the agent unconditionally.** Safest, and wrong
for the phase it serves: the Phase 2 exit criterion is *"open the booking project on
staging, fetch the latest reservation, then call the confirmation endpoint with that
ID"* — spoken, in one breath. Requiring a typed confirmation in the middle of it makes
the criterion's own example tedious to satisfy.

The chosen rule costs one extra argument over the first and puts the friction exactly
where the consequence is. Staying inside staging is frictionless; **entering production
always costs a human keystroke**, whoever asked.

### 2.4 The agent's reach

`agentAllowedTools` currently filters on `kind == .read`. It becomes `.read` **and**
`.control`, which is what makes "put the results next to the terminal" reachable at all.
The context setters remain on the list — the agent must be able to switch context for
the Phase 2 criterion to be satisfiable — and are now governed by §2.2's production row
rather than by their absence.

This does mean the allow list grows by eight names. `WindowModelTests` already asserts
that every entry names a server `--mcp-config` defines and that no `.mutate` action ever
appears; both assertions still hold and are extended to the new kind.

### 2.5 Reclassification

`ctx_set_project` and `ctx_set_environment` move `.read` → `.control`. No other 2a
action changes. `db_*` and `session_*` stay `.read`; there are still zero `.mutate`
actions (§8).

---

## 3. The pane model

### 3.1 Two stores, deliberately

`PaneStore` holds what is *in* a pane — columns, rows, `truncated` — and is read by the
agent through `read_pane`. It is not touched by this spec. Geometry goes in a new
`LayoutStore`.

Keeping them apart is not tidiness. `PaneStore`'s contract is that its snapshot is
honest to an LLM (its doc comment argues the case at length), and 2c rewrites its
contents model when the real data surface lands. Geometry has a different lifetime, a
different writer, and different persistence. Merging them would put 2c's churn on top of
2b-i's layout invariants.

### 3.2 `Pane`

```swift
public struct Pane: Sendable, Equatable, Identifiable {
    public let id: String            // "db-1"; stable for the pane's life
    public let kind: String          // "db" — one type in 2b-i (§1)
    public var title: String
    public var frame: PaneFrame      // origin + size, canvas points
    public var busy: Bool            // an action naming this pane is in flight
}
```

`PaneFrame` is a plain value type rather than `CGRect`, so `LayoutStore` and the snap
solver stay free of AppKit and remain testable in `WakilKitTests`.

### 3.3 `LayoutStore`

An actor, for the same reason `PaneStore` is one: a drag commit and an agent's
`pane_snap` can arrive from different tasks.

It holds, per project: the pane list, the focused pane id, the maximized pane id (or
none), and the snap graph. Switching project swaps the whole set; the previous set is
kept in memory rather than discarded, which is what §13's *"state is kept warm; panes
are never torn down and rebuilt on switch"* requires.

### 3.4 The snap graph

An undirected graph whose edges record *"pane A's right edge is coordinated with pane
B's left edge"*.

**Stored, not derived.** Two panes that happen to be flush are not the same as two panes
that were snapped: snapping matches their heights once, and a later independent resize
may leave them flush-but-unrelated or related-but-not-flush. Re-deriving adjacency from
geometry every frame would silently re-couple panes the user pulled apart.

Three operations:

- **Snap** — on release, if a candidate exists, set the frame flush, match the extent
  along the shared axis, and add the edge.
- **Border drag** — dragging a coordinated edge resizes *both* panes, so snapped panes
  never gap or overlap.
- **Unlink** — dragging a pane away from a snapped edge deletes every edge it holds on
  that side, returning it to free-floating.

### 3.5 The snap solver

Pure geometry, no state, no framework: given a dragged pane's proposed frame, every
other pane's frame, and the void bounds, return the best snap candidate within the
threshold (8pt, one constant) or none.

This is the one piece of 2b-i with real algorithmic content and it is exhaustively
unit-testable, which is why it is a free function in `WakilKit` rather than a method on
a view.

---

## 4. Layout as actions

### 4.1 Commit granularity

Eight new `.control` actions:

| Action | Params |
|---|---|
| `pane_open` | `kind` → returns the new id |
| `pane_close` | `id` |
| `pane_focus` | `id` |
| `pane_move` | `id`, `x`, `y` |
| `pane_resize` | `id`, `width`, `height` |
| `pane_snap` | `id`, `toPaneId` (optional — void edge if absent), `edge` |
| `pane_maximize` | `id` |
| `pane_restore` | — |

**A drag is a gesture; its commit is an action.** While the pointer is down, the view
updates local state at frame rate and dispatches nothing. On release, exactly one
`pane_move` or `pane_resize` carries the final rect. A 400-frame drag therefore produces
one journal entry reading *"pane moved here"*, not four hundred reading *"pane moved
1pt"*.

This is the rule that makes Invariant 2 affordable for layout. Without it, either the
journal is useless or the actor round-trip is on the frame path — and §13's 8.33 ms
budget does not survive an `await` per frame.

### 4.2 `read_layout`

Hand-written alongside `read_pane`, not a registered action, for the same reason
`read_pane` is not one: it is a pure read of UI state that journals nothing.

It returns each pane's id, kind, title, frame, busy flag; the focused and maximized ids;
and the snap edges. With `read_pane` it completes Invariant 3 — `read_pane` answers
*what is in that pane*, `read_layout` answers *what is on screen and where*. Neither
alone lets an agent resolve "the pane next to the terminal".

### 4.3 Persistence

Layout persists per project, written on commit and read at project switch, under
`~/.wakil/`. It is machine-local state about window arrangement, so it does not go near
`project.json` (committable) and carries nothing secret.

A layout naming a pane kind that no longer exists is dropped with a note, on the same
principle as 2a's launch notes: visible degradation over silent failure.

---

## 5. The rail

§10: *"a chrome-less floating list of open panes … it exists because floating panes can
hide behind each other."*

The rail holds **no state**. It is a projection of `LayoutStore`: one row per pane,
ordered by open time, showing kind glyph, title, and the pane's ⌘-number shortcut.
Clicking a row dispatches `pane_focus`. The active pane's tick and the working pane's
green come from `focusedId` and `Pane.busy`.

`busy` is set by `WindowModel` around any dispatch naming a pane, and cleared when it
returns or throws. That is the whole mechanism — §9's *"a working pane glows green in
the periphery"* needs nothing more, and a spinner is explicitly not wanted.

Appearance is 2b-ii's. 2b-i's rail is an unstyled `List`.

---

## 6. ⌘P and ⌘K

§10 fixes the split on VS Code's convention: **⌘P opens, ⌘K does.**

### 6.1 ⌘K is the registry

⌘K's contents are `await registry.all()`, filtered by a fuzzy match over name and
description. Selecting an entry dispatches it with `origin: .ui`. An action whose schema
declares required params gets a second step that collects them before dispatching.

This is the dual-drive bet made literally visible: the command palette is not a
hand-maintained menu that happens to resemble the agent's tool list, it *is* the agent's
tool list, because both read `all()`. An action registered in `StandardActions` appears
in ⌘K without anyone editing a view, and one that does not appear is one that is not
registered.

### 6.2 ⌘P is three sources

Open panes (`LayoutStore`), projects (`ctx_list_projects`), and sessions. Selecting
dispatches `pane_focus`, `ctx_set_project`, or — since resume is 2b-iii's — reveals the
session's metadata as 2a's `session_resume` already does.

**The session source needs one new action.** `wakil-ctx` has served a `list_sessions`
tool since Phase 1, but no Wakil action wraps it: 2a registered `session_resume` over
`get_session` and nothing over the listing. So ⌘P has no way to *find* the id that
`session_resume` requires, and 2b-i registers `session_list` (`.read`) to close that. It
is a ninth new action, not one of §4.1's eight, and it is the only non-layout addition
this spec makes to the registry.

Files are the fourth source and arrive with the editor in Phase 3. The source list is
built to be extended; nothing else about ⌘P changes when they land.

### 6.3 One component

Both are the same view over a `[PaletteItem]` and a scorer. The fuzzy match is a
subsequence scorer favouring prefix and word-boundary hits — twenty lines, no
dependency, and unit-testable on its own.

---

## 7. Performance

The probe settled the Core at ~1.1 ms of GPU per frame (probe §3), so the risk in 2b is
not Metal. 2b-i's own budget items are two:

**The drag path never awaits.** §4.1's commit granularity is the mechanism. The test for
it is not a benchmark but a code property: no `await` on the pointer-moved path.

**Project switch under 400 ms.** `LayoutStore` keeps every visited project's panes in
memory (§3.3), so a switch is a swap rather than a rebuild. 2b-i measures the swap alone
— 2b-ii adds the motion that §13 says covers the remaining latency, and the reconnect
underneath it is `wakil-ctx`'s, not the layout's.

**120fps is not verifiable on the build machine** (probe §4): both attached displays are
60 Hz. No 2b acceptance document may claim the target was observed. They record CPU and
GPU cost against the 8.33 ms budget and name the display that could not test it.

---

## 8. Verification

**Headless, in `WakilKitTests`:**

- The snap solver, exhaustively: candidate selection at, inside and outside the
  threshold; pane-to-pane and pane-to-void; ties; no candidate.
- The snap graph: snap matches extent and adds an edge; border drag resizes both; unlink
  deletes only the dragged side's edges; closing a pane removes its edges.
- `LayoutStore`: open/close/focus/maximize/restore; per-project isolation; a swap
  preserves the outgoing project's arrangement.
- The gate table of §2.2, every row, including the two agent rows that differ only in
  `targetEnvironment`.
- **The Phase 1 guarantee §2.2 leans on**, against the real `wakil-ctx`: dispatching
  `ctx_set_project` while an environment is active leaves that environment name in place
  when the incoming project defines it, and clears it to `""` when it does not — never
  substituting some other environment. This is the assertion that keeps
  `ctx_set_project`'s missing `targetEnvironment` honest.
- `agentAllowedTools` admits `.read` and `.control` and still never admits `.mutate`.
- Every new action dispatches, journals with the right origin, and appears in `all()`.
- The palette scorer.

**Headless, through `--dispatch`:** a script that opens three panes, snaps two, focuses
the third, and reads `read_layout` back. This is how *"the agent can rearrange the
workspace"* is proven without a display, and it is the reason §4.1's actions carry
absolute rects rather than deltas — a script must be able to state an outcome.

**Operator runbook, because no machine can check them:** that a drag feels like dragging,
that the snap line appears where expected, that a coordinated border moves both panes,
that the rail shows what is open, and that ⌘K lists every registered action.

### What 2b-i cannot verify, and why

**The write gate's UI, and with it 2a's acceptance checks 5 and 6.** Those checks need a
`.mutate` action and 2b-i registers none — `wakil-db` is read-only by design, so there
is no natural candidate. Inventing a mutating action to exercise the gate would be
testing the test. The gate UI is 2b-iii's, checks 5 and 6 stay unrun until then, and
this paragraph exists so a PASS on everything above is not read as more than it is.

---

## 9. What 2b-i does not change

**One window.** ⌘N stays absent. §10 describes one void, one rail, one Core; a second
window means a second Core, which contradicts §1's *"one bright object"* before it
contradicts anything technical. It also re-opens the session-lifecycle leak 2a removed
⌘N to avoid — a second `WindowSession` with its own `wakil-ctx`, socket and harness, of
which only the last started is torn down on ⌘Q. Multi-pane is what §10 actually asks
for, and 2b-i delivers it.

**The harness, the shim, the MCP transport, `PaneStore`, `read_pane`.** Untouched.

---

## 10. File structure

New, in `WakilKit`:

    Layout/Pane.swift            Pane, PaneFrame, SnapEdge
    Layout/LayoutStore.swift     the actor; per-project sets; the snap graph
    Layout/SnapSolver.swift      pure geometry (§3.5)
    Layout/LayoutActions.swift   registers the eight actions of §4.1
    Layout/LayoutPersistence.swift
    Command/PaletteItem.swift    item model and the scorer

Changed:

    Registry/Action.swift        the third kind
    Gate/WriteGate.swift         origin and targetEnvironment
    Registry/ActionRegistry.swift passes origin to the gate
    Registry/StandardActions.swift ctx setters → .control; adds session_list
    App/WindowModel.swift        agentAllowedTools; busy tracking
    MCP/MCPServer.swift          read_layout
    App/AppWiring.swift          builds and wires LayoutStore

Changed, in `WakilApp` (unstyled, covered by the runbook alone):

    WakilWindow.swift            canvas, drag and border gestures, rail, palettes

---

## 11. Risks

**The snap graph is the one place a subtle bug hides.** Coordinated borders are shared
mutable geometry, and the failure mode — panes that gap, overlap, or drag each other
after being pulled apart — is the kind that shows up as "feels wrong" rather than as a
crash. Mitigation: the graph is stored rather than derived (§3.4), it is pure data, and
§8 tests it directly instead of through a view.

**⌘K exposes every registered action to one keystroke.** That is the intent, but it
means a future `.mutate` action is one fuzzy match away from being run by accident. The
gate is the answer and it already exists; 2b-iii's UI is what makes the answer visible.
Until then ⌘K has nothing dangerous to offer, because there is nothing dangerous
registered.

**Layout persistence is new on-disk state.** A corrupt or stale file must not stop the
app opening. It degrades to a default arrangement with a launch note (§4.3), on the same
principle as 2a's other notes.

---

## 12. Open questions

1. **Grid snapping in addition to pane-to-pane magnetism** — carried over from
   `design-language.md` §15, still unresolved. 2b-i ships pane-to-pane and void-edge
   only; adding a grid later does not change the snap graph, only the solver.
2. **Does the rail need a keyboard path of its own**, or is ⌘P sufficient? §10 promises
   three equivalent routes and ⌘P plus ⌘-number already gives two; a focused rail may be
   a fourth nobody uses.
3. **What `pane_open` does when the canvas is full.** Cascade, replace the focused pane,
   or refuse. 2b-i cascades from the last-opened pane's origin; whether that survives
   real use is a §15 density question and belongs to the same full-working-day test.
