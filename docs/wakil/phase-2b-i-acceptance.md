# Phase 2b-i acceptance run

The 2b-i design spec's §8 exit criteria, as a runbook. **You execute the standing checks**;
they need a mouse on a screen, and no agent has run any of them. Everything that could be
established without one has been, and §4 says exactly what that was.

Written 2026-09-08, at the end of Task 15 of
`docs/superpowers/plans/2026-09-08-phase-2b-i-structure.md`. A check with an empty result is
a check that was not run, and that is worth knowing later, so unrun items say so rather than
being quietly dropped.

**Status: MET 2026-09-15 — accepted without an acceptance run.** The three standing checks
were **never run** and now never will be: the operator accepted this runbook, along with the
whole outstanding backlog, on 2026-09-15 (`phase-log.md`, "The 2026-09-15 acceptance"). What
*was* established is the `--dispatch` proof of §3, which has been run and passes, and
everything in §4. What was not is everything below that says "look for" — the canvas, the
rail and the palettes have never been under a real mouse or a human eye. The checks are kept
below unchanged and each still reads UNRUN, because a check that was accepted is not a check
that passed, and the difference is the whole reason this document exists.

The reason they were never run in the first place is the session that wrote them — see the
box below.

> **Why the checks below were written but not walked.** The implementing session ran in an
> automated harness with no Accessibility and no Screen Recording grant. It could start
> `Wakil.app`, confirm the window existed and read its title and bounds through
> `CGWindowListCopyWindowInfo`, drive the running window's MCP socket, and quit it cleanly —
> all of which §4 records. It could not post a synthetic keystroke or click
> (`AXIsProcessTrusted()` returned `false`, so a `CGEvent` posted to the HID tap is
> discarded) and could not take a screenshot (`screencapture -x` failed with *could not
> create image from display*). So nothing below that says "look for" has been looked for.
> That is the honest state of the canvas, the rail and the palettes: they compile, they load
> a real arrangement without crashing, and no human eye has yet been on them.

Companion documents: `docs/wakil/phase-2a-acceptance.md` (whose §1 launch command this one
reuses, and whose checks 5 and 6 are still unrun — see §5),
`docs/wakil/phase-2b-probe.md` (the frame-cost measurements, and why 120fps cannot be
observed here), `docs/wakil/north-star.md` (the invariants these checks are evidence for),
and `docs/superpowers/specs/2026-09-08-phase-2b-i-structure-design.md` §8.

---

## 0. Why this list is short

Spec §8 splits verification by layer, the same way 2a's did. The snap solver, the snap
graph, `LayoutStore`, the gate table, the palette scorer, layout persistence and every one
of the nine new actions are headless assertions in `WakilKitTests`, run by `make app-test`.
The `--dispatch` hook drives `ActionRegistry.dispatch` from a file, which turns *"the agent
can rearrange the workspace"* into a script (§3).

What is left is what a machine cannot honestly check: **that a drag feels like a drag**,
that the snap line appears where a release would put the pane, that a coordinated border
moves both panes, and that the rail and ⌘K show what is actually there.

**`WakilKitTests` cannot import `WakilApp`** — a test target may not import an executable
target — so `WakilWindow.swift` is covered by this document and by nothing else. That is why
it is kept thin: every line of view code that is not drawing belongs in `WindowModel`, where
`WindowModelTests` can reach it.

---

## 1. Before you start

```bash
make app-build && make app-test && make app-bundle
```

**The launch command** is `phase-2a-acceptance.md` §1's, unchanged:

```bash
WAKIL_ORG=personal \
WAKIL_PROVIDER=<your claude-code provider id for that org> \
WAKIL_CLAUDE_PATH="$(command -v claude)" \
CLAUDE_CONFIG_DIR="$HOME/.claude-personal" \
CLAUDE_CODE_OAUTH_TOKEN='<the token for that account>' \
app/Wakil.app/Contents/MacOS/Wakil
```

Everything in 2a's §1 still applies: the three `claude` variables may be omitted to exercise
the window without spending a subscription (nothing in §2 below needs the agent); the window
may open behind Terminal; `Contents/Resources` is load-bearing.

### What the window is now

2a's half is unchanged — the org/project/environment line, the project and environment
fields, the query field, the database `Table`, the message field, the thought thread, the
status line and the note lines. 2b-i adds, between the query field and the table:

- a row of three controls — **Open…** (⌘P), **Actions…** (⌘K) and **Open pane**;
- **the canvas**, on the left: every pane in the active project's arrangement, floating,
  overlapping, each drawn as a bordered box carrying its title, its kind and its current
  `x y w h` as text, with a *resize* handle in its bottom-right corner;
- **the rail**, on the right: one row per pane — a leading `|` on the focused one, then
  title, kind, and the word `working` while a dispatch naming that pane is in flight.

It is still deliberately unstyled: no colours, no motion, no custom fonts, no void, no Core,
no planes. A pane's border is an unfilled rectangle in the default foreground and its fill is
the window's own background, because "two panes are flush" is not observable between two runs
of unbordered text. All of `design-language.md` is 2b-ii's.

**The frame text inside each pane is the point, not decoration.** A 2b-i pane has no contents
of its own — those live in `PaneStore`, and 2c builds the real data surface — so the numbers
are the only evidence on screen that a drag or a resize committed.

### Three things about the keyboard

- **⌘N is still absent**, for 2a's reason (one window, one session) restated in spec §9.
  There is consequently no *new pane* shortcut either; the **Open pane** button is it.
- **⌘W closes the focused pane, not the window.** The two pane commands live in the
  **Window** menu — *Maximize Pane* (⌘⏎) and *Close Pane* (⌘W). They were put there rather
  than in File because, with *New Window* removed, this app has no File menu at all; adding
  one would have brought *Close* and *Close All* (⇧⌘W) with it, either of which shuts the
  only window and leaves the app running with nothing on screen. Verified by dumping
  `NSApp.mainMenu` from a throwaway app with the identical `.commands` block: ⌘W resolves to
  *Close Pane* and to nothing else.
- **Escape closes a palette.** Both sheets carry a *Cancel* button bound to the cancel
  action; without it the palette would be a trap.

### Why there is an "Open pane" button

⌘K dispatches the chosen action with **no parameters** (`WindowModel.runPaletteItem`), and
`pane_open` requires `kind`. Running it from the palette therefore fails with
`pane_open: missing required param "kind"` in the status line. Spec §6.1's second step — the
one that collects an action's required params before dispatching — **is not built in 2b-i**,
and until it is, ⌘K can only successfully run the parameterless actions (`pane_restore`,
`ctx_list_projects`, `db_list_databases`, `session_list`). The button dispatches `pane_open`
through the registry like everything else; `"db"` is 2b-i's only pane kind.

---

## 2. The three standing checks

Run all three after any change to the canvas, the rail, the palettes or `WindowModel`'s
layout API. Record the result and the date; a re-run replaces the row rather than appending
to it.

### Standing check 1 — panes drag and snap by hand

*Spec §3.4, §3.5, §4.1, §7: magnetism is real, and a 400-frame drag journals one entry.*

**Setup.** Launch (§1). Press **Open pane** twice. Two panes appear on the canvas, the second
cascaded 28pt down and right of the first, both `640×420`, and the rail lists both.

**Look for:**

1. **Dragging follows the pointer.** Press inside the second pane and drag. It moves with the
   pointer with no lag and no stepping, and its `x y w h` line updates only when you *let
   go* — the text is read from `LayoutStore`, which is told once, on release.
2. **A snap line appears before you release.** Drag the second pane so its left edge comes
   within 8pt of the first pane's right edge. A one-point rule appears along the edge the
   release would land on. Move away by more than 8pt and it disappears.
3. **Releasing on the line snaps flush and matches extent.** Let go. The two panes are
   exactly flush — no gap, no overlap — and the dragged pane's height now equals its
   neighbour's. Its `y` and `h` in the frame text prove it.
4. **A coordinated border moves both panes.** Drag the *resize* handle of the left pane to the
   right. The right pane's left edge follows and its width shrinks by the same amount, so the
   pair stays flush and its far edge does not move.
5. **Pulling a pane away unsticks it.** Drag the right pane off somewhere else and release.
   It is free-floating again; `read_layout` (§3) would now show no snap between them.

**The journal is the second half of this check**, and it is what proves the drag path does
not dispatch per frame:

```bash
JOURNAL=$(ls -t ~/.wakil/journal/*.jsonl | head -1)
grep -c '"origin":"ui"' "$JOURNAL"
python3 -c "
import json
for line in open('$JOURNAL'):
    if not line.strip(): continue
    d = json.loads(line)
    print(d['action'], d['origin'], d['outcome'])
"
```

**Look for:** one `pane_move` **or** one `pane_snap` per release — never a run of them. A drag
that produced dozens of `pane_move` entries means `commitDrag` is being called from
`onChanged`, which is the specific failure the whole commit-granularity rule exists to
prevent (spec §4.1, §7). Note that a release which was previewing a snap journals
`pane_snap`, not `pane_move`: the snap is what you were aiming at, and recording the move you
happened to let go on would journal the wrong intent.

| Result | Date | Notes |
|---|---|---|
| **PARTIAL PASS** | 2026-09-08 | Operator-run, and **only after two defects found by running it** — see below. Steps 1, 2, 3 and the journal half: pass. Step 4: the resize tracks smoothly and the panes stay coupled, but the operator's description was not specific enough to call the *coordinated border* rule confirmed. Step 5 (pulling a pane away unsticks it): not walked. |

**What this check found on its first run, which is the reason it exists.** Two defects, both
invisible to the 239 tests passing at the time:

1. **A snap landed somewhere the preview never showed.** The snap line drew correctly against
   the target edge, but on release the pane jumped to the edge at the position it had *before*
   the drag. Root cause: `commitDrag` dispatched `pane_snap` with only `id`/`edge`/`toPaneId`,
   and `LayoutStore.snap` flushed from `panes[index].frame` — the stored, pre-drag frame,
   because a drag never moves the store until release. `candidate(forDragging:to:)` builds its
   proposal from the *released* origin, so preview and commit disagreed by exactly the drag
   distance. Fixed by sending the released origin with the action. No test caught it because
   `LayoutStoreTests` called `snap()` on panes sitting at their stored position, where the two
   frames coincide, and `WindowModelTests` asserted the action was *journalled*, not where the
   pane *landed*. It is a seam between the solver and the commit, and no task-scoped review
   saw both sides.
2. **The resize handle jittered instead of tracking.** `DragGesture` defaults to the `.local`
   coordinate space, and the handle is laid out at the pane's bottom-right while the pane's
   `.frame` grows as the gesture reports — so the handle was re-laid-out under the pointer by
   its own effect and `translation` fed back on itself. Fixed with
   `DragGesture(coordinateSpace: .global)`. The pane *drag* never had this problem because
   `.offset` is a render transform and leaves layout geometry alone; `.frame` does not.

**The journal half, run against the operator's own session** (11 entries, every one
`origin: ui`, every one `ok`):

```
pane_open · pane_snap · pane_move · pane_resize · pane_move · pane_resize
pane_move · pane_snap · pane_snap · pane_snap · pane_move
```

One entry per gesture and no run of `pane_move` anywhere — commit granularity holds under a
real hand on a real mouse, which is the thing the automated test can only approximate.

### Standing check 2 — the rail reflects what is open

*Spec §5: the rail holds no state; it is a projection of `LayoutStore`.*

**Look for:**

1. Every pane you have opened has exactly one row, in open order, showing its title and
   `db`.
2. The focused pane's row — and only that row — carries a leading `|`. Click a different
   row: the `|` moves to it, and that pane comes to the front of the canvas.
3. Close the focused pane with ⌘W. Its row disappears and the `|` moves to the pane that is
   now focused.
4. Press ⌘⏎. The focused pane fills the canvas; press ⌘⏎ again and it returns to exactly the
   rectangle it had, which its frame text confirms.
5. **Drag a pane off the right-hand edge of the canvas** until it is no longer visible. Its
   rail row is still there, and clicking it still focuses it. This is §5's entire reason for
   existing: floating panes can hide, including off the edge.

**About `working`.** `Pane.busy` is set by `WindowModel` around any dispatch naming a pane
and is what the rail's `working` column reads. **You will almost certainly never see it**, and
that is not a fault: every layout action is an in-memory actor call, so the flag is true for
microseconds. It becomes visible in 2c, when a pane's dispatch does I/O. There is no spinner
and none is wanted.

Be precise about what is proved and what is not. `LayoutStoreTests
.busyIsSetAndClearedWithoutTouchingAnythingElse` pins the flag itself, `LayoutPersistence
Tests.aBusyPaneIsSavedAndRestoredIdle` pins that it never reaches disk, and
`WindowModelTests.aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy` pins that it
cannot trigger a spurious save. **What nothing covers is the publishing order** — that
`dispatchLayout` sets the flag and refreshes the snapshot *before* awaiting the dispatch, so
the rail has an instant in which to observe it true. That ordering is a comment in
`WindowModel.dispatchLayout` and an eye that cannot see a microsecond; it is recorded in §6
as a gap rather than claimed here.

| Result | Date | Notes |
|---|---|---|
| _not yet run_ | | |

### Standing check 3 — ⌘K is the registry, and running from it journals `origin: ui`

*Spec §6.1 and Invariant 2: the command palette is not a menu that resembles the agent's
tool list, it **is** that list.*

**Command:** press ⌘K.

**Look for:**

1. **Every registered action, and nothing else.** Today that is fifteen rows — the eight
   layout actions (`pane_open`, `pane_close`, `pane_focus`, `pane_move`, `pane_resize`,
   `pane_snap`, `pane_maximize`, `pane_restore`) plus `ctx_list_projects`,
   `ctx_set_project`, `ctx_set_environment`, `db_list_databases`, `db_run_query`,
   `session_list` and `session_resume` — each with the action's own `description` as its
   subtitle.

   **Compare it against the list the agent is given**, which is the point of the whole
   arrangement. Ask the running window's own MCP socket:

   ```bash
   SOCK="$(getconf DARWIN_USER_TEMP_DIR)$(ls "$(getconf DARWIN_USER_TEMP_DIR)" | grep '^wakil-.*\.sock$' | tail -1)"
   printf '%s\n' \
     '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"runbook","version":"0"}}}' \
     '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
   | app/Wakil.app/Contents/MacOS/Wakil --mcp-shim --socket "$SOCK" \
   | python3 -c "import sys,json;[print(sorted(t['name'] for t in json.loads(l)['result']['tools'])) for l in sys.stdin if json.loads(l).get('id')==2]"
   ```

   **Look for** the same fifteen names, plus exactly two more — `read_pane` and
   `read_layout`, which are hand-written reads on `MCPSurface` rather than dispatched
   actions and so are correctly absent from ⌘K. Anything else that is in one list and not
   the other is a bug in the registry, not in this view, because both read
   `ActionRegistry.all()`.
2. **The fuzzy match works on the description as well as the name.** Type `extent`. Only
   `pane_snap` survives — the word appears nowhere in its name, only in its description
   ("...matching its extent..."). **Do not use `flush` for this**: it also appears, as a
   subsequence, inside `session_list`'s (much longer) description, and `session_list` —
   which was measured directly against `rank`/`fuzzyScore` outside the app — outscores
   `pane_snap` for that query (21 against 17) and lists *above* it, so `flush` demonstrates
   the opposite of "only `pane_snap` survives."
   Type `pmov`: `pane_move` ranks first, clearly (score 28 against the next entry's 12) —
   **not** `pm`, which most operators would reach for first but which does not disambiguate:
   `pane_maximize` and `pane_move` both score 18 off their names, `ctx_list_projects` also
   scores 18 off its description ("...**p**rojects...**m**isfiled..."), and the tie-break on
   equal score keeps the palette's pre-sorted (alphabetical) order — so `ctx_list_projects`
   is what `pm` actually puts first, not `pane_move`.
3. **Running one journals `origin: ui`.** Select `pane_restore` (it takes no params, so it is
   the one that will actually run — see §1's *Why there is an "Open pane" button*). Then:

   ```bash
   JOURNAL=$(ls -t ~/.wakil/journal/*.jsonl | head -1)
   grep '"action":"pane_restore"' "$JOURNAL" | tail -1
   ```

   **Look for** `"origin":"ui"` and `"outcome":"ok"`. That single line is the whole of
   Invariant 2 for the palette: the same action name, through the same `dispatch`, with the
   only difference being who asked.
4. **An action that needs params fails honestly.** Select `pane_open`. The status line reads
   `pane_open: missing required param "kind"` and the journal records
   `"outcome":"error"` — it does not silently do nothing. When 2b-iii or 2c builds §6.1's
   parameter step, this sub-check is what it replaces.

**Then ⌘P**, which is three sources rather than one: open panes first, then every project in
the org (`ctx_list_projects`), then recent sessions (`session_list`). Selecting a pane row
focuses it; selecting a project row switches to it **and the canvas follows**, because a
project's arrangement belongs to that project (`WindowModel.activateLayout`). Switch away and
back: the panes are where you left them.

If ⌘P shows panes but no projects and no sessions, read the status line — both sources report
their failure there rather than contributing an empty list in silence.

| Result | Date | Notes |
|---|---|---|
| _not yet run_ | | |

---

## 3. The headless proof: `--dispatch` drives the same layout

This is spec §8's *"a script that opens three panes, snaps two, focuses the third"* — the
headless equivalent of everything in §2, and the reason §4.1's actions carry absolute rects
rather than deltas. A script must be able to state an outcome.

```bash
make app-bundle
app/Wakil.app/Contents/MacOS/Wakil --dispatch scripts/checks/layout-dual-drive.jsonl \
  --environment staging
echo "exit=$?"
```

**Expect:** exit `0`, nine output lines, none carrying an `"error"` key, the first three
being `{"id":"db-1"}`, `{"id":"db-2"}` and `{"id":"db-3"}` and the remaining six `{}`.

Then read the journal back:

```bash
JOURNAL=$(ls -t ~/.wakil/journal/*.jsonl | head -1)
grep -c '"origin":"debug"' "$JOURNAL"      # expect 9
grep -c '"outcome":"ok"' "$JOURNAL"        # expect 9
```

**Use `ls -t`, not a glob.** `--dispatch` opens a fresh journal file per run, named for that
run's session UUID; `grep -c ... ~/.wakil/journal/*.jsonl | tail -1` counts whichever file
sorts *alphabetically* last, which is some earlier run and has nothing to do with the one you
just did. Measured on 2026-09-08: the glob form reported `3` for a run that had just written
`9`.

| Result | Date | Notes |
|---|---|---|
| **PASS** | 2026-09-08 | Exit `0`; nine lines, no `"error"` key, `db-1`/`db-2`/`db-3` then six `{}`. Journal for that run: nine entries, every one `"origin":"debug"` and `"outcome":"ok"` — `pane_open ×3, pane_move, pane_resize, pane_snap, pane_focus, pane_maximize, pane_restore`. |

**What this script cannot do, and what covers it instead.** `read_layout` is not a registry
action — it is hand-written on `MCPSurface`, because reading is not dispatching — so
`--dispatch` cannot end the script by reading the arrangement back. The equivalent is to ask
the *running window* through its own MCP socket, which is what §4 row 4 records.

---

## 4. What has been verified headlessly

None of this needed a display session, a mouse or a Claude turn. All observed 2026-09-08 on
the machine described in `phase-2b-probe.md`.

| # | Observation |
|---|---|
| 1 | `make app-build`, `make app-test` (**237 tests, all passing**) and `make app-bundle` are clean with the canvas, the rail and both palettes in the build. |
| 2 | **The window opens and stays.** `Wakil.app/Contents/MacOS/Wakil` launched with `WAKIL_ORG=personal` produced a window whose owner and title `CGWindowListCopyWindowInfo` reports as `Wakil`/`Wakil`, at the full usable size of the display it opened on. Nothing on stdout or stderr. |
| 3 | **The canvas draws a real multi-pane arrangement without crashing.** A two-pane layout with one snap link was written to `~/.wakil/layouts/personal/<project>.json` by hand and the app relaunched; it restored it (confirmed by `read_layout`, row 4) and stayed up. A SwiftUI failure on the canvas path would have taken the process down, and did not. |
| 4 | **The running window's layout is reachable over its own MCP socket.** A real `--mcp-shim` subprocess against the live session's socket listed all seventeen tools including the eight layout ones and `read_layout`; `pane_open` twice returned `db-1` and `db-2` and journalled `"origin":"agent","outcome":"ok"`; `read_layout` returned both panes with their frames, `focusedId`, and the restored snap link. |
| 5 | **Teardown is still clean with the new commands in the menu.** After a quit, `pgrep -fl 'MacOS/Wakil\|wakil-ctx\|wakil-db'` printed nothing and the socket directory was byte-identical to its pre-launch listing. |
| 6 | **⌘W resolves to *Close Pane* and to nothing else.** A throwaway app carrying the identical `.commands` block was run and its `NSApp.mainMenu` dumped: with the pane commands in the Window menu there is no File menu at all, *Maximize Pane* holds ⌘⏎ and *Close Pane* holds ⌘W uniquely. With them in the File menu instead, SwiftUI materialises that menu complete with *Close* and *Close All* (⇧⌘W) — which is why they are not there. |
| 7 | **Both attached displays report 60 Hz.** `NSScreen.screens` read live: `Built-in Retina Display 1470×956 @ 60Hz`, `LF22T35 1920×1080 @ 60Hz`, `NSScreen.main.maximumFramesPerSecond == 60`. See §5. |

---

## 5. What 2b-i cannot verify, and why

Stated so that a PASS on everything above is not read as more than it is.

### 120fps was not observed, and no 2b document may claim it was

`NSScreen.main.maximumFramesPerSecond` reports **60** (§4 row 7). The build machine is a
MacBook Air M3 — Liquid Retina, no ProMotion — with a 60 Hz Samsung LF22T35 attached. Neither
display can show a 120fps frame, so the north-star's *"120fps shell on ProMotion"* is
unfalsifiable here.

**The honest proxy is frame cost against the 8.33 ms budget**, which is what
`docs/wakil/phase-2b-probe.md` §3–4 records: the Core costs **1.090 ms p50 / 1.165 ms max** of
GPU per frame — about 13% of the budget — and the CPU interval sat exactly on the 60 Hz vsync
period with no dropped frames, which says the pacing was display-bound rather than work-bound.
2b-i itself draws nothing on the GPU, so it adds nothing to that figure; what it adds is
SwiftUI layout, which probe §3 already names as where the 2b frame budget will actually be
spent. Verifying the target itself needs ProMotion hardware and is deferred to whoever has
some.

### Project switch under 400 ms is not measured here

Spec §7 asks for it and no task in 2b-i measures it, deliberately. `LayoutStore`'s swap is an
in-memory dictionary lookup — timing it would produce a number in the microseconds that
measures nothing anyone cares about. The latency that criterion is really about is
`wakil-ctx`'s reconnect plus the covering animation `design-language.md` §13 asks for, and
neither exists yet. **Deferred to 2b-ii**, which is where the animation lands and where the
measurement will have both halves of its subject.

### Stale pane kinds are not validated

Spec §4.3 says a saved layout naming a pane kind that no longer exists is dropped with a note.
**2b-i does no such check.** `Pane.kind` is a bare `String` with exactly one legal value
(`"db"`), so nothing can be stale, and inventing a valid-kinds list now would be a decision
made before its requirements exist — the same reason `Pane.kind` is not an enum.
`LayoutPersistence.load`'s `(snapshot:note:)` return exists for this and its doc comment says
so.

**The trigger is explicit: the check must land in 2c, before 2c adds its second pane kind.**
Not "someday" — the moment there are two kinds, a layout saved under a version that had a
third becomes loadable, and a pane the app cannot draw goes on the canvas.

### Agent-driven layout changes are persisted only incidentally — a departure from §4.3, not a neutral gap

Spec §4.3 is unconditional: layout "persists per project, written on commit." A `pane_open`
dispatched over the MCP socket **is** a commit — §4 row 4 of this runbook proves `LayoutStore`
takes it. **Verified against the code, not assumed:** `WindowModel.dispatchLayout`'s `before`
(`WindowModel.swift:755`) is the model's *cached* `layoutSnapshot` — refreshed only by the
model's own prior dispatches, per the section below — and it is compared against an `after`
that is freshly re-read from `LayoutStore` at the end of the same call
(`WindowModel.swift:780`). A pane the agent opened over MCP exists in that fresh read and not
in the stale `before`, so the comparison sees a change and calls `persistLayout()`, which
writes the *whole current arrangement* — the agent's pane included.

**So the actual behaviour is not "silently gone on relaunch."** It is: an agent's layout
change is persisted only incidentally, by the operator's very next layout dispatch of any
kind — including a `pane_focus` that arranges nothing, since that dispatch still diffs a
stale `before` against a fresh `after` and trips the same write. If no such dispatch happens
before the app quits, the change is lost; if one does, it survives. Nondeterministic, not
uniformly lost, and which of the two happens depends on operator behaviour the agent cannot
see. This is still not the same kind of thing as "maximize fills the void" or the other
cosmetic items in §6 below — those are things §4.3 and its neighbours never promised. This is
a shipped departure from what §4.3 promises today, and an operator reading only §6's bullet
list would not learn that.

**Neither 2b-ii nor 2b-iii's charter (spec §0) contains "persist an agent's own writes,"** and
that deferral stands — the fix is not an actor→model subscription and not a second write path
that the agent drives itself. 2b-ii is the void, planes, the Core, motion, the thought thread,
production treatment; 2b-iii is the write-gate UI, the first `.mutate`, session resume, the
provider picker, signing. Filing this under either would be the same mistake as filing it
under 2b-i — a phase name standing in for an owner, when no phase has actually claimed it.

**The trigger is explicit: this must be fixed before any workflow relies on an agent's layout
surviving a relaunch.** Not "whichever phase happens to touch persistence next," and **not**
"build agent-side persistence" — that is what this trigger would read as if left pointed at
the old ("silently gone") claim, and it names the wrong failure. The measured failure is
nondeterministic persistence-by-coincidence, not a uniform gap, so the fix that actually
closes it is making the write incidental to the operator's dispatches deliberate instead of
accidental (or removing the dependency on operator timing some other way) — not adding a path
for the agent to write its own layout to disk. The moment an acceptance script, or a real
session, dispatches `pane_open` (or any layout `.control` action) over MCP and then expects
that arrangement's survival to not depend on what the operator happens to do next, the gap
stops being theoretical.

### `setVoid` had no caller, and it governed more than maximize

**Fixed 2026-09-08, recorded because the miss is instructive.** `LayoutStore.setVoid` shipped
with a doc comment saying "called by the window on resize" and nothing calling it, so the void
stayed at its `1440×900` default while the real canvas was roughly `740×400`. §6 below
originally recorded this as a maximize problem, and the branch review recorded the `read_layout`
consequence — the agent being told a size that is not on screen.

**Both understated it.** The void is what `SnapSolver` measures every canvas-edge snap against.
With it fixed at 1440×900 the right and bottom edges sat outside the visible canvas, so two of
the four magnetic edges were reachable by a `--dispatch` script and by nothing a pointer could
do — and two panes opening at `640×420` could not be brought edge to edge inside ~740pt of
canvas at all. The operator's first hands-on run reported "the magnetic edges are buggy" and
was right.

The canvas now reports its size through a `GeometryReader` to `WindowModel.setCanvasSize`,
which is a direct store call rather than a dispatched action, for the reason `switchProject`
and `load` are: the window stating a fact about itself is not an intent to journal, and a
`pane_*` action per resize frame would fill the journal with noise.

### The window is not live for changes it did not make

`WindowModel.layoutSnapshot` is a cached copy, refreshed by `refreshLayout()` only after the
*model's own* dispatches and on project switch. An agent that opens or moves a pane over MCP
changes `LayoutStore` — §4 row 4 proves it — but the canvas and the rail show nothing until
the window itself next dispatches. Measured, not inferred: two agent-opened panes sat live in
the store of a running window neither its canvas nor its rail knew about. Making this live
needs a subscription from the actor to the model, which is real architecture rather than a
patch, and — unlike the persistence gap above — this one is correctly deferred rather than
built now: nothing in 2b-i's charter asks the window to observe an agent's changes it did not
request itself.

**It is not, however, "2b-ii's motion work," and no bullet here should say so** — an
actor→model subscription is not itself the void, a plane, the Core, motion, the thought
thread, or production treatment, so pointing at 2b-ii's name is not the same as pointing at
its owner.

**The trigger is explicit: this must be fixed before any workflow shows the operator an agent
working live rather than its finished result.** Not "sometime once 2b-ii exists" — the moment
something narrates or animates an agent's actions as they happen (the thought thread is the
obvious first candidate, but not the only possible one), a canvas that still only updates on
the window's own dispatches will show that narration disagreeing with what is actually on
screen, which is worse than the canvas staying silent.

### 2a's acceptance checks 5 and 6 remain unrun

The write gate and *production blocked*. Both need a `.mutate` action and **2b-i registers
none** — the eight layout actions are all `.control` (moving a pane changes Wakil and nothing
else; being pointed at a production database is no reason to be unable to drag a window), and
`wakil-db` is read-only by design, so there is no natural candidate. Inventing a mutating
action to exercise the gate would be testing the test.

They belong to **2b-iii**, which is where the write-gate UI and the first `.mutate` action
land. The scripts to run on that day are already written down in `phase-2a-acceptance.md`
§§ *Check 5* and *Check 6*; do not re-derive them.

**Updated 2026-09-09.** 2b-iii landed and registered `db_run_mutation`, so both scripts
are now concrete in `phase-2a-acceptance.md` and both are **runnable and still unrun**.
The result goes in `docs/wakil/phase-2b-iii-acceptance.md` §2, checks 1 and 2. This
document's own status is unchanged: they remain unrun *here* because nobody has walked
them anywhere.

### The agent-into-production gate has not been exercised live

2b-i added a row to `writeGate`: a `.control` action dispatched with `origin: .agent` whose
`targetEnvironment` is production is **gated**, where the same action from the operator is
allowed. That is the answer to the hole the 2a acceptance run found by accident — an agent
silently re-pointing the active context — and `WriteGateTests` covers the full
environment × kind × origin matrix, including the two agent rows that differ only in
`targetEnvironment`.

**No `claude` turn has ever tried it, and today it could not be satisfied even if one did:**
`MCPServer.handle` reads `confirmation` as a sibling of `name`/`arguments` in `tools/call`
params (`MCPServer.swift:313-316`), a field no conforming MCP client sends, so a real agent
hitting this row gets a hard refusal rather than a confirmable gate — recording it as "not
exercised live" would undersell that it is not yet satisfiable from the agent side at all.
Nothing in the Swift suite runs `claude`, and asking a real agent to switch the active
environment to production spends the operator's subscription on a check whose mechanism is
already pinned headlessly. It is recorded here rather than run so that "the gate works" is
not read as "the gate has been seen working against a real agent". The natural moment to
spend that turn is 2b-iii's acceptance run, once the typed-confirmation surface exists,
alongside checks 5 and 6, when there is a `.mutate` action for the same turn to be refused
on.

**Updated 2026-09-09, and the answer is half of what this section expected.** 2b-iii built
the surface — a `ConfirmationBroker` parks the refused proposal, a red plane shows it, and
the same call is re-dispatched once a human types the word. The sibling field was *not*
widened, deliberately: Invariant 7 is a statement about who confirms, and an agent emitting
the string `"confirm"` is not a human typing it. So the gate is now satisfiable from the
agent side without the agent ever satisfying it itself.

The half that is not fixed: **`db_run_mutation` is `.mutate`, so it is not on
`agentAllowedTools` and a live `claude -p` turn is denied by the CLI before the request
reaches Wakil's socket** — `--permission-prompt-tool` was still not built. The `.control`
row this section is actually about (an agent switching into production) *is* live-
reachable, because `.control` is on the list. So the turn this section has been owed since
2026-09-08 is walkable at last, and it is check 3a of
`docs/wakil/phase-2b-iii-acceptance.md` §2. **It has not been walked.**

**Closed 2026-09-10.** `--permission-prompt-tool` is now built
(`docs/superpowers/specs/2026-09-10-permission-prompt-bridge-design.md`), against ten
measured scenarios in `docs/wakil/permission-prompt-probe.md`. `agentAllowedTools` is
unchanged — `db_run_mutation` is still absent from it — and that absence is exactly what
now routes the live `claude -p` turn to the bridge instead of a CLI-level denial: the
request reaches Wakil's socket, and what refuses or parks it from there is `dispatch` and
`writeGate`, not this list. Check 3a, the `.control` row, was already live-reachable and
remains so; what changed is that check 3b — the `.mutate` half — is now walkable too. The
paragraph above is kept as the record of what was true between 2026-09-09 and 2026-09-10.

---

## 6. Known gaps in 2b-i, none of them checkable above

- **The window is not live for agent-driven changes, and agent-driven changes are persisted
  only incidentally, not deterministically.** Both promoted to §5 rather than left as neutral
  bullets here — the second is a departure from spec §4.3, not a gap of the same kind as the
  others below, and both carry an explicit trigger rather than a phase-name assignment. See
  §5, *"Agent-driven layout changes are persisted only incidentally"* and *"The window is not
  live for changes it did not make."*
- ~~**Maximize fills the void, not the window.**~~ **Fixed 2026-09-08** — this was filed
  here as a maximize and `read_layout` problem and was in fact governing every canvas-edge
  snap. See §5, "`setVoid` had no caller, and it governed more than maximize". The canvas
  now reports its geometry to the store.
- **`Pane.busy`'s publishing order is uncovered.** The flag, its exclusion from persistence
  and its exclusion from the save gate are all tested; that `WindowModel.dispatchLayout`
  publishes it *before* awaiting the dispatch — which is the only reason the rail could ever
  observe it true — is not, because the window is not reachable from a test target and the
  window it is true for is microseconds wide. Standing check 2 says the same.
- **No parameter step in ⌘K**, so most actions cannot be run from it. §1 above, spec §6.1.
- **Session resume is still not implemented.** ⌘P's session rows reveal a session's metadata
  through `session_resume`, exactly as 2a did. Real resume is 2b-iii's.
- **Only one pane kind exists**, so nothing about the canvas has been exercised against panes
  that differ. 2c.
- **"Production looks alarming" is still unmet** — plain text, no treatment. 2b-ii.
- **The app is still unsigned and hand-assembled.** 2b-iii.
