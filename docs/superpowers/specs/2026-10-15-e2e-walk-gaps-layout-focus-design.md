# e2e: the walk findings no check covered, and layout and focus assertions

**Status:** design, approved in conversation 2026-10-15. Pieces 2 and 3 of the
e2e enhancement; piece 1 is PR #419 (`2026-10-15-e2e-selected-run-design.md`),
and this branch is stacked on it.

## 1. The problem

The operator's walks since the harness existed (2026-09-23) found 41 defects
no check caught. Sorted:

- **15 needed only a check that was never written.** 4 have been covered
  since. Of the other 11, 3 are covered by checks that exist now, 6 can be
  written with today's steps, 2 need fixture state the seed cannot produce,
  and 1 (#325) cannot be driven without risking a real browser sign-in.
- **18 needed something the harness cannot see.** The largest groups are
  geometry (about 9: rows stacking one letter per line in a narrow window,
  palette rows centred in empty space, the DB ⓘ overlapping, controls
  unreachable at the default pane size) and focus (3: a click on a pane body
  not taking focus, the Git diff keeping the keyboard).
- **8 are the operator's alone** (visual judgement, real accounts, real
  speech, the macOS permission prompt).

The harness already reads what geometry and focus need. `axresolve` returns
every named element's frame and the window frame (`Element`, `WindowFrame`)
through accessibility, which does not take the foreground, and
`Frontmost.FocusedIdentifier` names the element holding keyboard focus. Today
both are only logged.

## 2. What success is

- The six writable checks exist, each proved red against the commit before
  its defect's fix and green on this branch.
- Two fixture additions let the three blocked findings be checked, and those
  checks exist too.
- A check can assert which control holds focus, where a control sits relative
  to the window or another control, and its size, and can make the window
  narrow first.
- `docs/agents/e2e.md` and `CONTRIBUTING.md` say when a change owes a focus
  or frame check, so future work writes them by default.

Not goals: frame stability over time, pixel colour, latency. Each is its own
later piece.

## 3. Three new step arms

All three are arms of existing step kinds, never a fifth kind (`ParseChecks`
refuses anything else, by design).

### 3.1 `expect.focus`

```json
{"expect":{"focus":"editor.pane"}}
```

Passes when the named control holds keyboard focus or contains the element
that does. SwiftUI puts the identifier on a wrapper and the focus on the
`AXTextField` inside it, so the focused element itself usually carries no
identifier; `axresolve` reports the identifiers of the focused element and its
ancestors (`focusedWithin`), and the step looks for the name there. Names are
concrete, as every check's are. Read through `Resolver.Frontmost`, and settled
like every other `expect`.

**It fails when the app has no focused window** (`targetHasFocusedWindow`
false), with that reason. **It does not require the fixture to be
frontmost**: the app's own focused element is read from the app, not from the
system, and requiring the foreground would turn every Orca focus steal (#418)
into a red focus check.

### 3.2 `expect.frame`

```json
{"expect":{"frame":"api.recent","inside":"window"}}
{"expect":{"frame":"<id>","clear":"<other id>"}}
{"expect":{"frame":"<id>","minWidth":40,"maxHeight":28}}
```

The element is resolved by `Resolver.Resolve`, by its concrete identifier. Predicates, at least one required:

| Predicate | Passes when |
|---|---|
| `inside: "window"` or `inside: "<id>"` | the element's rectangle lies wholly within the window's, or the other element's |
| `clear: "<id>"` | the two rectangles do not overlap (touching edges is not overlap) |
| `minWidth`, `minHeight`, `maxWidth`, `maxHeight` | the element's size, in points, is within the bound |

An element that does not resolve fails the step, naming it; a frame predicate
over a missing element is never vacuously true. Several predicates on one
step must all hold.

### 3.3 `do.resize`

```json
{"do":{"resize":{"width":900,"height":700}}}
```

Sets the fixture window's size through accessibility (`AXSize` on the
window), via a new `axresolve --resize WxH`. It is an act: it is logged with
the frontmost reading like every act, and the next `expect` settles on the
new layout. Pane sizes already have `dispatch pane_resize`.

### 3.4 Coverage

`expect.focus` and `expect.frame` read a control; they do not press it, so
they do not count toward the coverage gate's *exercised* set. The gate's
question stays "does a check press this", unchanged.

## 4. The fixture additions

Both follow the rule `GitProject` set: added state is never the active state,
so every existing check opens exactly as it was written.

- **A rootless project** (`SeedSpec.RootlessProject`, `e2e-rootless`): a
  second project in the first org whose `project.json` declares no roots. A
  check switches to it with `ctx_set_project` and back. It unlocks the
  "no project root note stays" finding (80c97d7).
- **A second credentialed account in the agent launch**: a provider in the
  first org, with a stored token and a claude path, beside `e2e-provider`.
  It unlocks #331 (USE closes Settings) and the account-switch half of
  "switching leaves api panes at no origin" (2c-iv W1). `2e-settings-doors`
  lines 17–18, which pass whether or not #331 is fixed, are fixed or moved
  into the new check.

If a check written against either addition does not go red against the
commit before its fix, the finding is reported as residue, never forced.

## 5. The checks

| Finding | Check |
|---|---|
| #324 ACCOUNT names an unlinked account | `seeded/2e-settings-unlink-indicator.jsonl` |
| Terminal ⌥⌫ ⌥← ⌥→ do nothing word-wise | `seeded/365-terminal-option-word.jsonl` |
| First agent turn wipes the api draft (e51e847) | `agent/api-draft-survives-first-turn.jsonl` |
| Recent root path reads as a double space (d7549158) | `seeded/api-recent-root.jsonl` |
| Search drops the first file's header (948aeac8) | `seeded/3b-ii-search-file-headers.jsonl` |
| `www.` host refused on cURL paste, paste route | a `www.` case in `seeded/api-paste-curl-hotkey.jsonl` |
| "no project root" note stays (80c97d7) | `seeded/project-root-note.jsonl` |
| #331 USE closes Settings | `agent/2e-settings-use-keeps-pane.jsonl` |
| Account switch leaves api panes at no origin | `agent/api-origin-after-account-switch.jsonl` |

And, with the new arms, checks for the layout and focus findings the seeded
fixture can reach, at least:

| Finding | Check |
|---|---|
| Row verbs stack one letter per line in a narrow window (#326) | `seeded/2e-settings-narrow-rows.jsonl` (`do.resize`, `expect.frame` minWidth) |
| A click on a pane's body does not take focus (3b-v) | `expect.focus` added to `seeded/3b-v-click-focuses-pane.jsonl` |
| Recent unreachable at the default pane size (44d0305) | `seeded/api-recent-reachable.jsonl` (`expect.frame` inside window) |

Each new or changed check is proved red with `make e2e-new` (with `--base`
at the commit before the fix, when the fix predates the merge-base) and green
with `make e2e`. A layout finding whose red proof cannot be produced is
residue, named in the report.

**Residue by design, for now.** Palette rows centred in an empty plane
(ea340628) needs an offset predicate ("directly under"), which §3.2 does not
have. The DB ⓘ overlap (0e087c5e) landed on main after this stack's base; its
`clear` check follows a rebase.

**#325 stays uncoverable.** Its `uncoverable.tsv` entries are re-reasoned:
#254 is closed, but driving Sign in with a made-up claude path still risks a
real browser trip if the override were ever ignored.

## 6. The guidelines

- `docs/agents/e2e.md` step 3 gains: *a change that moves keyboard focus owes
  an `expect.focus` check; a change to a surface's layout owes an
  `expect.frame` check at a narrow window size (`do.resize`)*, with the
  walk-finding categories (stacked rows, clipped or unreachable controls,
  overlap, focus not taken or not released) as the list to check against.
- `CONTRIBUTING.md`'s tests-each-change-needs section names the same two.
- `e2e/driver/check.go`'s comment on the step vocabulary documents the three
  arms.

## 7. The screen

Writing all of this needs no screen. `expect.focus` and `expect.frame` are
reads that never take the foreground, and the unit tests run headless. The
red and green proofs do take it, once, at the end, after asking the operator:
with selection, a few minutes.

## 8. Testing

Unit tests in `e2e/driver`, no GUI:

- `ParseChecks` accepts the three arms and refuses: a frame step with no
  predicate, an unknown `inside`/`clear` target form, a non-positive size
  bound, a resize with a non-positive dimension, a focus step with an empty
  name.
- The frame predicates over fixed rectangles: inside, partly outside,
  overlapping, touching, size bounds.
- The focus predicate: the control focused, an ancestor of the focused
  element, another control focused, no focused window.
- The runner with a fake resolver: a missing element fails the frame step.
- The seed: the rootless project loads and is not active; the second account
  is listed with its credential stored only in the agent launch.
