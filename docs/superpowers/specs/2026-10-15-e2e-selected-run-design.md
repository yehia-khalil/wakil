# e2e: run the checks a branch touched, and the whole suite once before merge

**Status:** design, approved in conversation 2026-10-15. Piece 1 of three
(see §7).

## 1. The problem

`make e2e` launches the app once per check file: 127 files (114 seeded, 12
agent, 1 unseeded) at a measured ~9 s per launch, about 22 minutes. Every
check actuates through real clicks and keystrokes (223 `click`, 175 `press`,
152 `hotkey`), which macOS delivers only to the frontmost window, so the run
holds the screen for all 22 minutes. The Cover rung runs it on every branch,
whatever the branch touched.

`make e2e-new` is already selective — only the checks the branch added or
changed, against the merge-base — and is not changed here.

## 2. What success is

- The Cover rung's green run takes the screen for the checks the diff reaches:
  a few minutes on a typical branch, not 22.
- The whole suite still runs green once per branch, on the head that merges,
  unattended at a time the operator chooses.
- No record claims more than was run. A runbook rendered after a selected run
  says the full run is owed; only a full run on the certified head renders it
  green.

Not a goal: freeing the screen entirely. That needs the app in a VM and is a
separate decision (§7).

## 3. Targets

| Target | Runs | When |
|---|---|---|
| `make e2e` | the selected checks, then `e2e-cover` | Cover rung, step 6 of the task audit |
| `make e2e-full` | every check (today's `make e2e`), then `e2e-cover` | once before merge, on the head that merges |
| `make e2e E2E_ONLY='<glob>'` | the named checks only, no selection | by hand |

All three print their file list through one selector, which also writes the
selection record, and run it through one shared loop. The launch is chosen
from each file's directory as today (`unseeded/` → `--no-seed`, `agent/` →
`--agent on`), in launch order: unseeded, seeded, agent.

## 4. Selection

A new pure `driver.SelectChecks(changes, corpus) Selection`, its git reader `driver.ChangedFiles(repo, base)`, and a
command `e2e/cmd/wakil-e2e-select` that prints the selected files for the
Makefile and writes the record.

1. **The diff is against the merge-base** with `E2E_TRUNK` (default
   `origin/main`), by the same `driver.MergeBase` `e2e-new` uses. A trunk that
   moved on must not select checks for somebody else's work.
2. **A changed check file selects itself.**
3. **A Swift file selects through its changed lines, not the whole file.**
   Rules 3 and 4 read each changed file's hunks — the changed lines plus 3
   lines of context, on both sides. Measured on 3b-v part 2: whole files
   selected 95 of 127 checks, because hub files (`WindowModel.swift`,
   `PermissionPrompt.swift`, `StandardActions.swift`, `PaletteSources.swift`)
   spell nearly every action; hunks with 3 lines of context selected 10 (0
   lines: 7; 10 lines: 32). A change whose hunks spell nothing is unmapped,
   and the full run owes it.
   **Identifiers:** The identifiers
   harvested from it (`HarvestIdentifiers`; each `Identifier` carries `File`)
   select every check whose coverage exercises them
   (`CoverageOf(check).Exercises`, which already matches a dynamic family such
   as `pane.<…>.reopen` to the concrete ids checks use).
4. **A changed Swift file selects through the actions it spells.** An action
   some check dispatches (or holds parity on) whose name the changed file
   spells as a quoted literal in code — `Sources.Mentions`, the rule
   `NewActions` already uses — selects every check that dispatches it. The
   candidate names come from the checks, not from the live denominator: the
   denominator is written only by a launch on the current head, so after any
   new commit it is stale until a run, and selection must work before one.
   An action no check dispatches selects nothing, and is the coverage gate's
   question.
5. **A changed file that reaches no check through 2–4 is unmapped.** It is
   listed and owed to the full run, never escalated to one: a model, a shared
   view or the Go core touches every check, and escalating would put the
   22-minute run back on most branches. A file that declares identifiers no
   check exercises is listed separately as *mapped, no check* — that is the
   coverage gate's question, which `e2e-cover` still answers.
6. **The record.** `.context/e2e/select/latest.json`: mode (selected,
   named, full), base and head commits, each selected check with its reasons
   (which file, which identifier or action), the unmapped files, the
   mapped-no-check files, the ignored files. Printed in full on every run,
   the rule backfill and quarantine already hold to. Selection reads the
   committed diff (`base...HEAD`); a dirty tree is recorded and warned about.
7. **The org-plane check always runs.** `e2e/checks/unseeded/org-plane.jsonl`
   is selected on every run, reason *always*: it is the cheapest launch,
   proves the bundle starts, and refreshes the action denominator that
   `e2e-cover` refuses to read stale.
8. **Files that cannot change what a check sees are ignored, by name:**
   anything under `docs/`, `e2e/checks/proofs/` or `app/Tests/`, any
   `*_test.go`, and any `*.md`. They are
   listed in the record, not as unmapped.
9. **Nothing selected beyond the org-plane check is a pass that proved nothing**, said in those words, as
   `e2e-new` already does for a branch with no new checks.
10. **A full run writes the record too**, mode *full*, every check picked, so a
    runbook after a full run that stopped at its first red reads *never run*,
    not *owed*.

## 5. The runbook

`MachineWalk` reads the selection record as well as the run records. Per
check, one of:

- **green on this build** — a run record on the certified head, exit 0;
- **red on this build** — as today;
- **owed to the full run** — no record on this head, and the selection
  record names this head and did not pick it. A selection record for another
  head is ignored, and every unrun check is a fault as today.

The section's headline:

- **green** only when every check in the corpus is green on the certified head
  (today's rule, which `make e2e-full` satisfies);
- **"selected checks green against `<head>`; full run owed"** when every
  selected check is green and the rest are owed, followed by the unmapped
  files;
- **red** when any check that ran is red.

`MachineWalk.Err` — the Cover rung's verdict — passes on the second headline
too. The pre-merge gate is a full-run headline on the merging head.

## 6. Docs

- `docs/agents/e2e.md`: step 6 runs `make e2e` and reads the selection's
  unmapped list; a new step names `make e2e-full` before merge.
- `docs/agents/workflow.md`: the Cover row's done-when says the selected
  checks are green; the merge step names `make e2e-full`.
- `Makefile`: the `e2e` comment block explains selection and points at
  `e2e-full`.

## 7. Out of scope, in order

1. **This spec.**
2. **The eleven missing checks** the walk-feedback review found (class A):
   ordinary check-writing, no harness change. Own spec.
3. **Geometry and focus assertions** (class B, 12 of 18 findings): resize and
   assert bounds; assert focus owner after a real pointer click. Own spec.

Not planned: running the app in a VM to free the screen.

## 8. Testing

Unit tests in `e2e/driver`, no GUI:

- `SelectChecks` over in-memory changes with one case each: a changed check,
  a changed identifier file (static and dynamic identifier), an identifier
  only in the base version (removed), a changed file spelling an action, an
  action named only in a comment (not selected), an unmapped file, an ignored
  file, a deleted check (not selected), an empty diff (org-plane only).
- `MachineWalk` renders each of the three headlines and the *owed* state.

Proof of the outcome: one real `make e2e` on this branch, its time and the
selection record reported; one `make e2e-full` to show the full path still
renders the runbook green.
