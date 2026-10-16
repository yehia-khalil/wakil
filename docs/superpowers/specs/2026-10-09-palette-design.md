# The palette: ⌘P opens, ⌘K does — one plane, a curated catalog, input steps, and resources

**Date:** 2026-10-09
**Status:** design approved by the operator 2026-10-09, section by section
**Sub-phase:** a cross-cutting fix, not a phase row — like *conversation layouts*. **Waits on 3a-i**
(`yehia-khalil/3a-i-git-pane`): the Git pane kind, its actions and its changed-files source are
consumed here, so implementation starts after 3a-i merges.
**Visual reference:** `docs/wakil/screens/Palette.dc.html` (the #70 restyle artboard)

---

## Problem

Found on the 3a-i walk, 2026-10-09:

1. **⌘K lists the agent's vocabulary.** It is `registry.all()` by wire name — `git_fold`,
   `api_bind`, `db_render_update` — which the operator never calls by hand.
2. **⌘K cannot take an input.** It dispatches with no params (`WindowModel.runPaletteItem`), so
   `pane_open` fails ("missing required param kind"). Spec §6.1's param-collecting step was never
   built (2b-i).
3. **The top buttons are a 2b-i stopgap.** `Open…`, `Actions…`, `Open pane` (hard-coded `db`) and
   `Open terminal`. Nothing opens an API or Git pane except the empty-canvas Landing.
4. **Both palettes are a system `.sheet` with a Cancel button**, which §1 ("no window chrome") and
   the #70 artboard already ruled out.

## What the operator gets

1. **One palette, two front doors.** ⌘P opens it in *open* mode, ⌘K in *commands* mode. In open
   mode, `>` as the first character switches to commands; deleting it switches back. Pressing ⌘P or
   ⌘K while it is open switches mode rather than stacking a second palette.
2. **⌘P — open or switch to:** grouped, empty groups hidden, in this order:
   1. **Open panes** — focus a pane already on the canvas.
   2. **New pane** — Database, Terminal, API client, Git: built from `Pane.kinds`, so a future kind
      appears without palette changes (`pane_open {kind}`).
   3. **Resources** — things with a pane to land in:
      - **database tables** `bookings · table · core db · staging` → a Database pane reading it
        (`db_read_table`); a database row (`core db · staging`) drills into its tables;
      - **API entries** `catalog · api · staging` → an API pane pointed at it (`api_open {entry}`);
      - **changed files** `booking-controller.ts · Changes · walk-a` → the Git pane on that diff
        (`git_select`, opening a Git pane first if none is open).
      All files in a root join when the editor ships, through the same source seam.
   4. **Projects** — the **current organisation's only** (Invariant 4). Another organisation's
      projects never appear; switching organisation stays its own flow.
   5. **Sessions** — the current project's.
   6. **Providers.**
3. **⌘K — a curated catalog of operator verbs**, each a label → a registry action, focused pane's
   commands first, then global. Commands that cannot run now are **hidden, not disabled** (Cancel
   only while a send is in flight). Raw registry actions never appear. Starting catalog:

   | Scope | Commands |
   |---|---|
   | Git pane | Refresh · Unfold list · Close pane |
   | Database pane | Run query · Next page · Previous page · Format query · Close pane |
   | API pane | Send · Cancel · Fill from cURL… · Close pane |
   | Terminal pane | Close pane |
   | Global | Switch environment… · Switch project… · Switch provider… · Open settings · New pane… |

   A test pins every entry to a registered action, so a renamed action fails the build rather than
   leaving a dead row. The exact entries are the plan's to finalise against the live registry.
4. **Input steps.** A command marked `…` pushes a step into the same plane:
   - **choice** — a list of existing values (environments, projects, providers, panes, databases,
     files), filtered by typing; you cannot pick something that does not exist;
   - **text** — only where the value is genuinely open (a cURL command, a SQL query); recent
     entries for this window are shown above the line as suggestions (rule 9: they suggest, never
     restrict).
   The query line's placeholder names the input ("Environment"). Esc pops one step and restores
   that step's query (rule 6); at the root it closes.
5. **Search is words, not syntax.** Every space-separated word must match somewhere in the row —
   title, subtitle or kind label — in any order. Kind labels carry aliases: `db`/`database`/`table`,
   `api`, `git`, `term`/`terminal`, `pane`, `project`, `session`, `provider`. Ranking: title hits
   before subtitle hits before kind hits; exact and prefix before scattered letters (the 2d-i fuzzy
   scorer). `catalog api` → the API entry; `catalog db` → the table; `catalog catalog` → both. The
   only special character is a leading `>`.
6. **The look** follows `Palette.dc.html`: a dark plane over a dimmed canvas (OrgPlane's geometry),
   no sheet, no Cancel button; query line with a result count; rows with the matched letters bright
   and the rest dim, a subtitle, and the group as a small right-aligned label; footer
   `↑↓ move · ⏎ <verb> · esc to dismiss` where the verb follows the selection (*open*, *switch to*,
   *run*, *choose*). Production is red wherever it is a choice (§5).
7. **After a run**, the palette closes and focus goes to the pane acted on or opened. A failure
   shows **whole** in the palette, which stays open with the input intact (rule 8). A gated command
   raises the confirmation plane. (Amended: environment switches from the palette are not gated; see the amendments.)
8. **No match:** one row, *"No results for 'foo'"*; Return does nothing.
9. **The top buttons are deleted.** The composer bar's existing `⌘P open · ⌘K actions` hint is
   the discoverability; the Landing keeps its own pane choices.

## What it does not do

- Another organisation's projects (operator ruling 2026-10-09).
- Inline-argument syntax (`env staging`), `api:`-style prefixes.
- Opening arbitrary files (waits on the editor).
- Persisting recent free-text entries across launches.
- Any change to the agent's tools or the registry.

## Design

### Units (all logic in WakilKit, tested; WakilApp draws)

- **`CommandCatalog`** — a declarative list. Each entry: `id`, `label`, `scope` (`.pane(kind)` or
  `.global`), `action` (registry name), `params` (fixed values, values from the focused pane, or the
  input step's value), `available` (a predicate over a `PaletteContext` snapshot of window state),
  `input` (`nil`, `.choice(ChoiceSource)`, `.text(placeholder:, recentKey:)`).
- **`PaletteModel`** — a pure state machine: `mode` (`.open` / `.commands`), `query`, `steps`
  (stack, each with its own query), ranked `results`, `selection`. Inputs are events (`typed`,
  `moved(±1)`, `confirmed`, `escaped`, `modeKey(.p/.k)`); outputs are a new state plus at most one
  `PaletteEffect` (`.run(action, params)`, `.focus(pane)`, `.close`, `.pushStep`).
- **`PaletteSearch`** — word splitting, kind aliases, per-row match across title/subtitle/kind,
  ranking on top of the existing fuzzy scorer.
- **`PaletteSources`** — the ⌘P groups and choice lists: open panes (layout), pane kinds
  (`Pane.kinds`), tables (`db_list_tables` per database, cached per environment for the window,
  refreshed in the background), API entries (`list_apis`), changed files (Git snapshot), projects,
  sessions, providers, environments (existing reads). Each source answers independently; a source
  that fails contributes one error row and never hides the others (rule 8).
- **`PaletteView`** (WakilApp) replaces `Palettes.swift`'s view and both `.sheet`s in
  `WakilWindow.swift`. Accessibility identifiers: `palette.query`, `palette.row:<id>`,
  `palette.step` (the step title).

### Dispatch

Everything runs through `ActionRegistry` with origin `ui`: journal, write gate and confirmation
plane unchanged. A command whose action is operator-only stays operator-only; nothing the palette
adds is agent-reachable that was not before.

## Errors and edges — against PRODUCT.md §Interaction Rules

| Rule | How the palette meets it |
|---|---|
| 1 Confirm only what destroys or is gated | No palette confirmation; gated actions keep their plane |
| 2 Enter never required to keep input | An input step keeps its typed query when Esc pops back and when the palette is reopened in the same step within the window session |
| 3 New input focused | The query line is focused on open and on every step push/pop |
| 4 Anything that waits can be cancelled | A slow source (tables) never blocks typing; Esc closes regardless; a run in flight shows on the row and Esc leaves it to the pane |
| 5 Work in flight shows it, no double fire | Return on a row whose run is in flight does nothing; the row shows the load mark |
| 6 Stay where the operator was | Esc pops one step with its query; after a run, focus lands on the acted-on pane |
| 7 Override or ignore; don't refuse | A query with only spaces is empty; unknown words just narrow to no results |
| 8 Errors whole, blocking only what they must | A failed run shows its whole error in the palette; a failed source shows one row |
| 9 Defaults suggest | Recents are suggestions above a free-text line, never the only options |

## Testing — as many cases as the units allow

### `PaletteSearch` (unit)
1. Single word matches title; matches subtitle; matches kind label; matches nothing.
2. Multi-word AND: `catalog api` → API only; `catalog db`, `catalog table`, `catalog database` →
   table only; `catalog staging` → both when both in staging, one when not; `catalog catalog` →
   both.
3. Order-free: `api catalog` ≡ `catalog api`.
4. Every alias resolves: `db`, `database`, `table`, `api`, `git`, `term`, `terminal`, `pane`,
   `project`, `session`, `provider`.
5. Case-insensitive; diacritics folded the way 2d-i folds (`é` ~ `e`); leading/trailing/multiple
   spaces collapse; an all-space query is empty.
6. Ranking: title-prefix > title-substring > subtitle > kind > scattered letters; ties broken by
   group order, then title, stable across runs.
7. 2d-i compatibility: `pane move` still ranks `pane_move`-backed commands' labels first where they
   exist; the folded-prefix rule still holds.
8. Very long query (500 chars), query of only `>`, query `>>`, unicode/emoji, a word longer than
   any title.
9. 10,000 rows rank in under a bound (performance test; bound chosen from a measurement with margin).

### `PaletteModel` (unit)
10. ⌘P opens in open mode, ⌘K in commands; ⌘P while open in commands switches to open and keeps
    the query minus `>`; ⌘K while open in open mode switches to commands.
11. `>` typed first switches to commands; deleting it switches back; `>` typed mid-query is a
    literal character; pasting `>run` switches and searches `run`.
12. ↑/↓ wrap or clamp (decide in the plan; test whichever) and skip group headers; selection resets
    to the first result on every query change; selection survives a results refresh when the same
    row still exists (rule 6).
13. Return on a no-input command → exactly one `.run` effect with the right action and params.
14. Return on a `…` command → `.pushStep`; the step's query starts empty; placeholder set.
15. Esc in a step pops and restores the parent query and selection; Esc at the root closes; Esc
    twice from a two-level step closes only after two pops.
16. Choice step: Return on a choice → `.run` with that value; typing filters choices; no match →
    "No results" row and Return does nothing.
17. Text step: Return with text → `.run` with the text; Return on an empty text step does nothing;
    recents appear above, filtered by what is typed; choosing a recent fills the line, Return runs.
18. A run that fails → the palette stays open in the same step with the whole error shown and the
    input intact; typing clears the error.
19. A run in flight → Return again does nothing (no second effect); the row shows in-flight.
20. Availability: a command whose predicate is false is absent; it appears when the context changes
    while the palette is open (e.g. a send starts → Cancel appears).
21. Focused-pane commands sort before global ones; no focused pane → only global.
22. Empty states: no panes, no projects, no sessions, no providers → those groups hidden; nothing at
    all → only "New pane" rows.
23. Closing and reopening ⌘K resets to the root (no stale step), unless reopened within the same
    window session on a step that was escaped mid-typing (rule 2 — decide and pin in the plan).

### `CommandCatalog` (unit)
24. Every entry's `action` is registered (`registry.all()` names) — the build-breaking guard.
25. Every entry's params satisfy the action's schema `required` list given its input.
26. No entry's action is `.mutate` without the entry going through the existing gate (assert the
    dispatch path, not a special case).
27. Labels are unique within a scope; ids unique overall.
28. No catalog entry targets an agent-only internal (`read_pane`, `read_layout`, `approve_tool_use`).

### `PaletteSources` (unit, with fakes)
29. Pane kinds from `Pane.kinds` — adding a kind adds a "New … pane" row.
30. Tables: listed per database with `table · <db> · <env>` subtitles; a database that errors
    contributes one whole-error row and the others still list; cache hit on reopen; background
    refresh replaces rows without moving the selection.
31. Two databases with the same table name → two rows distinguished by subtitle.
32. API entries from `list_apis`; an environment with none → group hidden.
33. Changed files from the Git snapshot; no Git pane open → selecting one opens a Git pane first,
    then selects; a file in two groups (partly staged) → two rows.
34. Projects: only the current organisation's; another org's never appear even when the query
    matches exactly.
35. Production environment rows carry the production flag (drawn red).
36. Sources answer independently — a slow tables source does not delay panes/projects.

### Integration (WakilKit, real registry, fake clients)
37. ⌘P → "New Git pane" → a git pane opens and is focused.
38. ⌘K → Switch environment… → `qa` → `ctx_set_environment` dispatched with `qa`, journal origin
    `ui`; → `production` → switches the same way, no confirmation plane (amended, P8).
39. ⌘P → `catalog api` → `api_open {entry: catalog}`.
40. ⌘P → table row → `db_read_table` with database, table.
41. The agent's tool list is byte-identical before and after (no registry change).

### e2e (seeded fixture; Cover rung writes and proves them)
42. ⌘P opens each pane kind (db, terminal, api, git).
43. ⌘K → Switch environment… → `qa`, and back.
44. `catalog api` opens the API pane pointed at `catalog`.
45. A table row opens a Database pane.
46. Esc steps back one level, then closes; focus returns to the canvas.
47. Rule 3: the query line is focused on open (type immediately, no click).
48. Rule 8: a failing command shows its whole error and the palette stays open.
49. The top buttons are gone (`window.openPane`, `window.openTerminal`, `window.actionsPalette`,
    `window.openPalette` absent); every existing check that pressed them is migrated to the palette.
50. Parity: `palette.row:<pane_open:git>` click vs `pane_open {kind: git}` dispatch agree.

## Charter changes this makes

- design-language §10: ⌘P opens or switches to panes, new panes, resources (tables, API entries,
  changed files; files when the editor ships), projects, sessions, providers; ⌘K is a curated
  catalog with input steps; `>` in ⌘P switches to commands.
- `Palette.dc.html`: group labels on rows, an input step state, the "No results" row.
- The stopgap comment and buttons in `WakilWindow.swift` go.

## Open questions

None blocking. ↑/↓ wrap vs clamp and whether an escaped mid-typing step is restored on reopen are
the plan's to decide and pin with tests (cases 12 and 23).

## Amendments after review (2026-10-09)

- **P8 — no plane for the palette's environment switch.** It behaves exactly like the operator's
  existing context switch. Why: the gate (`writeGate`, D10) prices a production target only for the
  agent's origin, and the operator's own chooser has never raised a plane; making the palette do so
  would change the gate or add a confirmation the spec forbids. Production is drawn red in the
  choice list. This amends §7's gated-switch sentence and case 38.
- **P9 — clicking the dimmer outside the plane closes the palette.**
- **P10 — where the 2d-i fold is proved.** `PaletteSearchTests` proves the fold; the e2e check is
  `e2e/checks/seeded/palette-command-step.jsonl` (⌘K → New pane… → Terminal).
- **Plan rulings.** ↑/↓ wrap. Reopening always starts at the root. Identifiers: `palette.plane`,
  `palette.query`, `palette.step`, `palette.row.<id>`.
- **As built.** The catalog has 17 commands. *Format query* is omitted (no registry action; the
  query line formats locally). *Run query* is *Run query again* (`db_refetch`). *Send* goes through
  the API pane's own Send path, not the registry. Close pane is `pane_close {id}`.
