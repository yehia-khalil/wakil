# The e2e auditor

**An agent reads the branch and writes the checks:** derive what the work touched, cover
it, prove each check could fail, prove it now passes, and report — briefly — what could
not be covered and why. **The residue list is the only thing that reaches the operator.**
It turns the **Cover** rung of `docs/agents/workflow.md`.

## Before anything else, read what the harness already knows

| Question | Where it is answered |
|---|---|
| What can a check say? | `e2e/driver/check.go` — the four step kinds, and what each arm refuses |
| What does a check look like? | `e2e/checks/seeded/*.jsonl`, `e2e/checks/unseeded/*.jsonl`, `e2e/checks/agent/*.jsonl` |
| Which launch does a check want? | the directory it sits in — see step 3 below |
| What must be covered? | `make e2e-backlog`, and the rules in the `e2e-cover` comment in `Makefile` |
| What can no check reach? | `e2e/checks/uncoverable.tsv` — redirects, with reasons |
| Which checks were proved failable elsewhere? | `e2e/checks/backfill.tsv` |
| What did the last run do? | `.context/e2e/runs/`, `.context/e2e/new/latest.json` |
| Which checks does this branch reach? | `go run ./e2e/cmd/wakil-e2e-select`, `.context/e2e/select/latest.json` |

**Never invent a step kind.** `do`, `dispatch`, `expect` and `parity` are the
vocabulary; `ParseChecks` refuses anything else, and a file it refuses fails the whole
run, not the one line.

**A refusal you expect is `refuses` on a `dispatch`, not a fifth kind.**
`{"dispatch":{"action":…,"params":…,"refuses":"<text>"}}` passes only when the action is
refused with a message containing that text; it fails when the action runs or the
refusal says something else. It counts as an assertion.

**What the seeded fixture declares** (`e2e/driver/seed.go`). The active environment,
`staging`, has three api entries:

- `billing` carries an `authRef` that resolves to nothing, so a send is refused by Go.
- `catalog` has no ref, and its `.invalid` host fails at transport.
- `slow` points at a `StallListener` the session starts for each launch: it accepts and
  never answers, so a send stays in flight until cancelled or until Go's 10 s TLS
  handshake timeout. Its origin is a loopback port that changes every launch — never
  assert on it.

So `api_open {}` in `staging` opens an unpointed pane ("declares 3"). A second
environment, `qa`, declares only `catalog`, under `https://catalog-qa.e2e-fixture.invalid`.
Use `qa` for a round-trip environment switch.

## The three modes

### 1. Task audit — the default, and the one that turns the rung

Run it when the implementation is otherwise finished: `make test` and `make app-test`
green, the work committed.

1. **Read the diff against the merge-base**, never against `origin/main`'s tip:
   `git diff --name-status $(git merge-base origin/main HEAD)...HEAD`.
2. **Derive what it touched** — the actions registered or changed, the
   `.accessibilityIdentifier`s added, the panes and the flows. Cross-reference the live
   `tools/list` denominator (`.context/e2e/actions.json`, written by every `make e2e`
   launch) and the identifier harvest (`make controls`). **Neither denominator is read
   off the source** (the `e2e-cover` comment says why); do not grep the registrar files
   for a second answer.
3. **Write the missing checks.** A file per flow, one launch per file, so a file may
   assume nothing another file did.

   **The directory chooses the launch, and there are three.** Nothing inside a check file
   can change it.

   | Directory | Launch |
   |---|---|
   | `e2e/checks/unseeded/` | nothing on disk; asserts the organisation plane |
   | `e2e/checks/seeded/` | an organisation open, and no agent |
   | `e2e/checks/agent/` | seeded **and** carrying the scripted agent (`e2e/stub/`) |

   **A check in none of them fails the whole run** (`GroupChecks` refuses it rather than
   guessing). Any new directory must be added to the auditor's list too.

   **`agent/` is only for a check that needs the agent to answer.** It is the slowest
   launch, so a flow the operator drives belongs in `seeded/`. A check that wants the
   agent to *do* something wants a `dispatch` step in a seeded file — it drives the same
   MCP socket a real agent speaks, with no child process.

   **That socket is the on-screen place's** (`ScreenChannel`, re-chosen after every
   switch), so a dispatch acts *as that place's agent*: `ctx_set_project` or
   `ctx_set_environment` sent this way is refused (an agent cannot move its own place).
   Switch with a `do` step instead.

   **An operator-only action goes over the operator channel.** The agent socket refuses
   operator-only actions (`ActionError.operatorOnly`), so the staged fixture (bundle id
   `dev.wakil.e2e`, `startHarnessSocket`) opens `<dir>/<session id>-e2e.sock` beside each
   agent socket, serving only those actions with origin `debug`. The runner sends a
   `dispatch` there when the app lists the action on it (`channelFor`) — except a `refuses`
   the operator-only refusal would satisfy, which stays on the agent socket. A refusal on
   either is the step's failure, never retried on the other. A build without the socket
   (the merge-base under `make e2e-new`) uses the agent socket; a current build whose socket
   failed to start fails the run (`wakil/harnessFailure`), never falls back.

   **Cover the interaction rules as well as the actions.** For each rule in `PRODUCT.md`
   §Interaction Rules that a touched surface can break, write a check: for example, type
   into a field, move focus away and expect the value kept (rule 2). A rule no step kind
   can express goes in the residue as walk-only, naming the rule. Never skipped silently.

   **Cover focus and layout, which the walks found most often.** A change that moves
   keyboard focus — a click that should take it, a pane that should give it up, a field
   that should keep it — owes an `{"expect":{"focus":"<id>"}}` check. A change to a
   surface's layout owes an `{"expect":{"frame":"<id>", …}}` check at a narrow window
   (`{"do":{"resize":{"width":…,"height":…}}}`): `inside` its pane for a control that must
   stay reachable (never `inside: window` for a control in a pane: panes may run past the
   window's edge by design), `clear` for two that must not overlap, `minWidth` /
   `maxHeight` for a row that must not wrap into a column. Check a UI change against these
   walk findings: rows stacking one letter per line, controls pushed out of their pane,
   overlaps, focus not taken or not given back. Twitch, colour and speed are not
   expressible; they stay walk-only and are named in the residue. The window's minimum is
   1000 wide and 888 tall, frame included (`WakilWindow.swift` sets the content to
   1000×860); a resize below it fails and says what size it reached.
   `tree` text holds a button's title or value, never its `accessibilityLabel`, nor any
   identifier: a row that names itself with a label (palette, Landing, rail) is read with
   `{"expect":{"label":"<id>","contains":"…"}}`.
4. **Add the identifiers the checks need** when an actionable control has none. That is
   real accessibility work, not test scaffolding.
5. **Prove each new check red**: `make e2e-new`. A check that passes against the
   merge-base is not testing this work. **Commit the proofs it writes** under
   `e2e/checks/proofs/` with the checks: `.context/` is gitignored and per worktree, and
   without them a runbook re-rendered after the merge reads every check as "not new on
   this branch". A proof names the check's `git hash-object`, so a check edited since
   renders as not re-proved. **Read the reasons, never the count** — a check red because
   the harness could not reach the window proves nothing.
6. **Prove them green**: `make e2e`. It runs the checks the diff reaches — changed check
   files, checks that press an identifier a changed hunk declares, checks that dispatch an
   action a changed hunk spells — plus the org-plane check, then the coverage gate.
   **Read the UNMAPPED list it prints**: changed files no check reaches, which only the
   full run covers. A hand-picked set: `make e2e E2E_ONLY='e2e/checks/seeded/git-*.jsonl'`.
7. **Render the machine section**:
   `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-<sub-phase>-acceptance.md`.
   Everything in it is generated; write nothing into it by hand.
8. **Report the residue**, in the runbook's human section and in the ticket: what the
   work touched that no check covers, and why in each case.
9. **No `make e2e-full` before merge.** The night run (`e2e/cmd/wakil-e2e-night`) runs it
   on `main` between 23:00 and 07:00, fixes what it can on `e2e-night/<date>` (local
   commits, never pushed) and reports the rest; read it with `make e2e-night-status`.
   Never start e2e by hand while `pgrep -f '[w]akil-e2e-night run'` matches: that process
   holds the screen for the night.

### 2. Standing audit — the gate

`make e2e-cover`, which `make e2e` runs last on every invocation. **Newly added surface
without a check is red; pre-existing surface is not.** Nothing here is the auditor's to
decide: it is run, and its verdict is obeyed.

### 3. Discovery audit — the backlog

`make e2e-backlog`: every action and control no check touches at all, independent of any
diff. **A list of work, never a gate**, read when scheduling, not when finishing.

## What the auditor must never do

- **Never write the machine section by hand.** It is rendered by `make e2e-runbook` from
  the run records.
- **Never touch the human section of a runbook**, and never mark one of its checks. Only
  the operator walks.
- **Never retry a check into green.** An intermittent check is quarantined by name, on
  the command line, and reported on every run.
- **Never add a line to `uncoverable.tsv` to quiet the gate.** The bar is *no check can
  reach it* — a claim about the harness — not *no check reaches it yet*. An entry that
  excuses nothing fails the gate.
- **Never let a residue item disappear into a check that does not assert it.** A check
  whose assertions cannot fail is worse than no check.

## What stays the operator's, permanently

The visual rulings — violet confined to the proposal, the mirror never lit, the hatch
reading as texture, a room in motion reading as calm — and *did the right real account get
used*, against a live provider. `--capture` and `--capture-motion` serve the first four;
nothing serves the last but an operator. **Name this boundary in the residue**; never
imply the harness covered it.

## Before a run

- **Disk room.** A launch stages the whole bundle (127 MiB) first; with no room the agent
  is never spawned, which reads like an app defect. The harness refuses below 512 MiB and
  names the disk (`RefuseIfDiskIsTight`).
- **An unlocked screen.** Behind a lock AppKit presents no window to the accessibility
  API and every check fails identically. The harness refuses up front and names the lock;
  a long suite wants the screen kept awake.
- **No live Wakil.** The operator's app or a hand-opened branch build can take the
  foreground mid-act. The launch refuses while one runs and names its pid; quit it and
  retry.
- **No other e2e run.** Check before starting a long run, and say so (see *Reading a red
  run*).

## A green gate can still be wrong

- **The denominator can be blind.** `make controls` audits control *constructors* in the
  audited sources, so a helper wrapping one hides every call site: a helper whose
  identifier parameter defaulted to `""` shipped empty identifiers while the gate said
  "all named". Before trusting "all named", check the thing you care about is in the
  denominator at all. **Prefer the compiler**: an identifier parameter with no default
  cannot be called without a name; `LeakyHelpers` fails the gate on a defaulted one.
- **The numerator can be promised.** An obligation handed to a future ticket is not
  coverage. If a residue report says "#N adds the first editor", check that #N does.
- **A gate that has never been red about something has told you nothing about it.**

## Make sure a red run reached you as one

A shell can hand you `0` for a failed run:

```
$ (sh -c 'exit 3') | tail -1   ;  echo $?      # 0  — the status is tail's
$ (sh -c 'exit 3') ; grep x f  ;  echo $?      # 0  — the status is grep's
```

So `make e2e | tail -60` and `make e2e > log; grep …` both report success on a failed
run. `set -o pipefail` fixes the first; for the second, capture `make`'s own status
immediately:

```
make e2e > run.log 2>&1; rc=$?
grep -E 'all checks passed|failure' run.log
exit $rc
```

**Use `rc`, never `status`.** In zsh `status` is read-only (an alias for `?`), so
`status=$?` aborts with `read-only variable: status` and reports a passing run as failed.

## Reading a red run

Artefacts land in `.context/e2e/<run>/<check>/`: `failure.txt`, `screenshot.png`,
`tree.txt`, `panes.json` — and `acts.txt`, the one to read first.

`acts.txt` is every act the check made and what the window server believed before and
after each one. **An act can succeed and do nothing**: `AXPress` reports no outcome, and a
keystroke goes to whatever holds the foreground, so a press that vanished and one that
landed are the same `ok`.

The line to look for names something other than the fixture:

> `step 6: keys "vim" -> ok; frontmost NOT the fixture: com.stablyai.orca`

The runner brings the fixture forward before each act when it is not front; the line says
`brought forward` when it had to. **Read the bundle id, not just the pid:**

- **`dev.wakil.e2e`, a pid that is not the fixture's** → a concurrent run on the same
  machine. The launch refuses and names the pids; that is the guard working — wait for
  the other run.
- **anything else** → something on the machine took the screen.

**Before blaming the machine, check whether another session is running e2e.**

Two other readings:

- `THE FIXTURE HAS NO FOCUSED WINDOW` — the app is running and presenting nothing
  (every act, behind a locked screen).
- `keyboard focus on …` — what the keystroke was aimed at. After a `do.type` it should
  name the field typed into; anything else means focus moved between the two acts.

**Nothing in `acts.txt` decides anything.** An act whose reading looks wrong still passed
if the app did what the check asked.

## The residue report

Short, in the ticket as well as the runbook. One line per item:

> `org.plane.create` — no check. Creating an organisation writes a real
> credential boundary, and the fixture's seed cannot be re-entered mid-launch.

That is the only part of the output the operator is expected to read.
