# The e2e auditor

**An agent reads the branch and writes the checks.** That is the whole of this
skill: derive what the work touched, cover it, prove each check could fail,
prove it now passes, and report — briefly — what could not be covered and why.
**The residue list is the only thing that reaches the operator.**

It is §9 of the agent-e2e design (binding;
the design file itself left `main` when it merged) and it turns the **Cover** rung of `docs/agents/workflow.md`.

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
vocabulary, `ParseChecks` refuses anything else, and a file it refuses fails the
whole run rather than the one line.

**A refusal you expect is `refuses` on a `dispatch`, not a fifth kind.**
`{"dispatch":{"action":…,"params":…,"refuses":"<text>"}}` passes only when the
action is refused with a message containing that text. It fails when the action
runs, or when the refusal says something else. It counts as an assertion. Without
it, a refused dispatch can only fail its step, so outcomes such as Decision 27's
one-author refusal or a second send in flight could not be checked.

**What the seeded fixture declares** (`e2e/driver/seed.go`). The active
environment, `staging`, has three api entries:

- `billing` carries an `authRef` that resolves to nothing, so a send is refused
  by Go.
- `catalog` has no ref, and its `.invalid` host fails at transport.
- `slow` points at a `StallListener` the session starts for each launch. The
  listener accepts connections and never answers, so a send stays in flight
  until it is cancelled or until Go's 10 s TLS handshake timeout. Its origin is a
  loopback port that changes on every launch, so a check must not assert on it.

So `api_open {}` in `staging` opens an unpointed pane ("declares 3"). A second
environment, `qa`, declares only `catalog`, under its own origin
`https://catalog-qa.e2e-fixture.invalid`. Use `qa` for a round-trip environment
switch.

## The three modes

### 1. Task audit — the default, and the one that turns the rung

Run it when a ticket's implementation is otherwise finished: `make test` and
`make app-test` are green, and the work is committed.

1. **Read the diff against the merge-base**, never against `origin/main`'s tip:
   `git diff --name-status $(git merge-base origin/main HEAD)...HEAD`. A branch
   whose trunk has moved on must not be asked to cover somebody else's work.
2. **Derive what it touched** — the actions registered or changed, the
   `.accessibilityIdentifier`s added, the panes and the flows. Cross-reference
   the live `tools/list` denominator (`.context/e2e/actions.json`, written by
   every `make e2e` launch) and the identifier harvest (`make controls`).
   **Neither denominator is read off the source**, and the reasons are in the
   `e2e-cover` comment; do not grep six registrar files for a second answer.
3. **Write the missing checks.** A file per flow. One launch per file is the
   rule, so a file may assume nothing another file did.

   **The directory chooses the launch, and there are three.** Nothing inside a
   check file can say which it wants — an instance either has an organisation
   on disk and the scripted agent on its provider record before it starts, or
   it does not, and no line of JSONL can change that afterwards.

   | Directory | Launch |
   |---|---|
   | `e2e/checks/unseeded/` | nothing on disk; asserts the organisation plane |
   | `e2e/checks/seeded/` | an organisation open, and no agent |
   | `e2e/checks/agent/` | seeded **and** carrying the scripted agent (`e2e/stub/`) |

   **A check in none of them fails the whole run**, not the one file:
   `GroupChecks` refuses it rather than guessing, because running an
   organisation-plane check against a seeded instance produces a red that says
   nothing about the check — and under `make e2e-new`, which requires red, that
   red would be read as proof. #255 added `agent/` and did not add it to the
   auditor's list; every branch that touched a check in it afterwards failed
   `make e2e-new` outright.

   **`agent/` is for a check that needs the agent to answer**, and nothing
   else. It costs the slowest launch, so a flow the operator drives belongs in
   `seeded/`. A check that wants the agent to *do* something, rather than to
   answer, wants a `dispatch` step in a seeded file — that drives the same MCP
   socket a real agent speaks, with no child process.

   **That socket is the on-screen place's.** The window opens one socket per
   place it shows, pinned to that place, and the harness dispatches on the one
   whose place is the screen's, chosen again after every switch
   (`ScreenChannel`). So a dispatch acts *as that place's agent*: an
   `ctx_set_project` or `ctx_set_environment` sent this way is refused (an agent
   cannot move its own place). Switch with a `do` step instead.

   **Cover the interaction rules as well as the actions.** For each rule in
   `PRODUCT.md` §Interaction Rules that a touched surface can break, write a
   check: for example, type into a field, move focus away and expect the value
   kept, which covers rule 2. A rule no step kind can express goes in the
   residue as walk-only and names the rule. It is never skipped silently.

   **Cover focus and layout, which the walks found most often.** A change
   that moves keyboard focus — a click that should take it, a pane that
   should give it up, a field that should keep it — owes an
   `{"expect":{"focus":"<id>"}}` check. A change to a surface's layout owes an
   `{"expect":{"frame":"<id>", …}}` check at a narrow window
   (`{"do":{"resize":{"width":…,"height":…}}}`): `inside` its pane for a control that
   must stay reachable (never `inside: window` for a control in a pane:
   panes may run past the window's edge by design), `clear` for two that must not overlap, `minWidth` /
   `maxHeight` for a row that must not wrap into a column. The walk findings
   these catch — rows stacking one letter per line, controls pushed out of
   their pane, overlaps, focus not taken or not given back — are the list to
   check a UI change against. Twitch, colour and speed are not expressible
   yet; they stay walk-only and are named in the residue. The window's
   minimum is 1000 wide and 888 tall, frame included (`WakilWindow.swift` sets the content to 1000×860); a resize below it fails and
   says what size it reached.
4. **Add the identifiers the checks need**, when an actionable control has
   none. That is real accessibility work and not test scaffolding — thirteen
   anonymous buttons is a VoiceOver defect with or without this harness.
5. **Prove each new check red**: `make e2e-new`. A check that passes against
   the merge-base is not testing this work. **Commit the proofs it writes**
   under `e2e/checks/proofs/` with the checks (#305): `.context/` is
   gitignored and per worktree, and without them a runbook re-rendered after
   the merge reads every check this branch proved as "not new on this
   branch". A proof names the check's `git hash-object`, so a check edited
   since renders as not re-proved. **Read the reasons, never the
   count** — a check that went red because the harness could not reach the
   window is red against anything and proves nothing.
6. **Prove them green**: `make e2e`. It runs the checks the diff reaches — the
   changed check files, the checks that press an identifier a changed hunk
   declares, the checks that dispatch an action a changed hunk spells — plus
   the org-plane check, then the coverage gate. **Read the UNMAPPED list it
   prints**: changed files no check reaches, which only the full run covers.
   To run a hand-picked set instead:
   `make e2e E2E_ONLY='e2e/checks/seeded/git-*.jsonl'`.
7. **Render the machine section**:
   `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-<sub-phase>-acceptance.md`.
   Everything in it is generated; write nothing into it by hand.
8. **Report the residue**, in the runbook's human section and in the ticket:
   what the ticket touched that no check covers, and why in each case.
9. **No `make e2e-full` before merge.** The night run
   (`e2e/cmd/wakil-e2e-night`) runs it on `main` between 23:00 and 07:00 after
   the merge, fixes what it can on `e2e-night/<date>` (local commits, never
   pushed) and reports the rest; read it with `make e2e-night-status`. Never
   start e2e by hand while `pgrep -f '[w]akil-e2e-night run'` matches: that
   process holds the screen for the night.

### 2. Standing audit — the gate

`make e2e-cover`, which `make e2e` runs last on every invocation. **Newly added
surface without a check is red; pre-existing surface is not.** A gate demanding
the whole registry on day one would be switched off within a week.

Nothing about this mode is the auditor's to decide. It is run, and its verdict
is obeyed.

### 3. Discovery audit — the backlog

`make e2e-backlog`: every action and control no check touches at all,
independent of any diff. **It is a list of work and never a gate**, and it is
read when scheduling, not when finishing a ticket.

## What the auditor must never do

- **Never write the machine section by hand.** It is rendered by
  `make e2e-runbook` from the run records. A section an agent composed about a
  run the agent made is exactly what the Walk rung's *"Never an agent"*
  refuses; a section computed from the records is not, because `make e2e-new`
  proved the records mean something.
- **Never touch the human section of a runbook**, and never mark one of its
  checks. Writing a runbook is not walking it, and only the operator walks.
- **Never retry a check into green.** A check retried until it passes has
  stopped being evidence. An intermittent one is quarantined by name, on the
  command line, and reported on every run.
- **Never add a line to `uncoverable.tsv` to quiet the gate.** The bar there is
  *no check can reach it* — a claim about the harness — not *no check reaches
  it yet*, which is ordinary work the gate is asking for. An entry that excuses
  nothing fails the gate, so a line written to buy silence fails it later
  instead.
- **Never let a residue item disappear into a check that does not assert it.**
  A check whose assertions cannot fail is worse than no check: it occupies the
  coverage the missing one would have owed.

## What stays the operator's, permanently

The visual rulings — violet confined to the proposal, the mirror never lit, the
hatch reading as texture, a room in motion reading as calm — and *did the right
real account get used*, against a live provider. `--capture` and
`--capture-motion` serve the first four; nothing serves the last but an
operator.

**Naming this boundary is part of the job.** A report implying the harness
covered these would be worse than one that admits it does not, and the residue
list is where the admission goes.

**And keeping room on the disk.** A launch stages the whole bundle — 127 MiB
— before it starts anything, and a volume with no room for it produces a run
where the agent was never spawned: a symptom that reads exactly like a defect
in the window that was meant to spawn it. Measured 2026-09-24: twenty-odd green
runs, then 6 of 6 failures at 97% full, with the app and the harness stashed.
The harness refuses below 512 MiB and names the disk (`RefuseIfDiskIsTight`),
which is what let the agent checks join `make e2e` — a run that refuses up
front is not red for the branch's reason, and a gate that goes red for reasons
that are not the branch's is a gate somebody switches off.

**And unlocking the screen.** AppKit presents no window to the accessibility
API behind a lock, so every check on a locked Mac fails identically and for a
reason that has nothing to do with what it asserts. The harness refuses such a
run up front and names the lock (#284, after three runs spent thirty seconds
each blaming the app instead) — but nothing in a headless run can clear it, so
a suite long enough to reach the idle timer wants the screen kept awake.

**And quitting Wakil.** A live Wakil — the operator's app, or a branch build
opened by hand for a walk — can take the foreground mid-act, and a scripted
agent check then reads as a window that never launched its agent (#332). The
launch refuses while one runs and names its pid; quit it and retry.

## The gate is only as honest as its denominator

**Both halves of a coverage claim can be wrong while the gate is green**, and
two agents hit one each on 2026-09-25 — neither found by running the gate.

The **denominator** can be blind. `make controls` audits control CONSTRUCTORS
in the audited sources, so a helper that wraps one is named once at its
definition and every call site is invisible to it. `SettingsPane`'s
`confirmButton` and `plainField` defaulted their identifier parameter to `""`;
four call sites took the default and shipped `.accessibilityIdentifier("")`,
and the gate reported *"54 actionable control(s), all named"* throughout.

The **numerator** can be promised. 2c-iv's one-author rule is keyed on an
operator's unsaved draft edit that no shipped surface can produce — the pane is
`Text` end to end — while the obligation to build that surface had been handed
forward to a ticket that does not discharge it. The gate reported a true "0 new
controls".

**Only the first lies.** A blind denominator makes a positive claim about
surface that is not there; a promised numerator is merely silent about surface
that should be. Both come out green, and the green means less than it looks.

What follows from it:

- **A gate that has never been red about something has told you nothing about
  it.** Before trusting "all named", check that the thing you care about is in
  the denominator at all — for a control, that means a constructor in an
  audited source, not a call to a helper.
- **Prefer the compiler where it can hold the rule.** A helper whose identifier
  parameter has no default cannot be called without a name, which is stronger
  than any audit and needs no maintenance. `LeakyHelpers` now fails the gate on
  a defaulted one rather than trying to follow call sites, because removing the
  default is the fix and following call sites is a workaround for not having
  removed it.
- **An obligation handed to a future ticket is not coverage.** If a residue
  report says "#N adds the first editor", check that #N does.

## First, make sure a red run reached you as one

**A shell can hand you `0` for a run that failed, and both ways of losing it
are ordinary things to type.** Measured:

```
$ (sh -c 'exit 3') | tail -1   ;  echo $?      # 0  — the status is tail's
$ (sh -c 'exit 3') ; grep x f  ;  echo $?      # 0  — the status is grep's
```

So `make e2e | tail -60` and `make e2e > log; grep …` both report success
while the output plainly says `make: *** [e2e] Error 1`. This has already been
read as a green run twice, by two different agents on the same day — once for
a run refused up front for a locked screen, and once for a run that was killed
part way through.

`set -o pipefail` fixes the first. Nothing fixes the second but not writing it:
capture `make`'s own status immediately, before anything else runs.

```
make e2e > run.log 2>&1; status=$?
grep -E 'all checks passed|failure' run.log
exit $status
```

**And in zsh, the capture itself can abort — after the command has already
succeeded.** `status` is read-only in zsh, an alias for `?`, so
`make e2e > log 2>&1; status=$?` runs `make`, then dies on the assignment:

```
(eval):1: read-only variable: status
```

The shell exits non-zero and the run is reported as **failed when every check
passed**. That is the opposite direction from the two above and worth holding
separately: the first two hide a red, this one invents one. Someone who has
learned "the status might be another command's" will still be caught by "the
assignment can abort". Use `rc=$?`.

`status` is the name everyone reaches for, and it is harmless inside this
Makefile's own `sh` recipes — which is exactly why it looks safe here. Two
agents reached for it within an hour of each other on 2026-09-25, in different
worktrees, and both were told their passing run had failed.

**Why this is in a document about reading failures.** All three are the same
class: the run told the truth and the instrument reported something else. A
harness whose whole argument is that an act can succeed and do nothing should
not be driven by a command that can fail and report nothing — or succeed and
report a failure.

## Reading a red run

Four artefacts land in `.context/e2e/<run>/<check>/`: `failure.txt`,
`screenshot.png`, `tree.txt`, `panes.json` — and `acts.txt`, which is the one
worth learning to read first.

`acts.txt` is every act the check made and what the window server believed
before and after each one. **It exists because an act can succeed and do
nothing.** `AXPress` reports no outcome, and a keystroke goes to whatever holds
the foreground — so a press that ran and a press that vanished are the same
`ok`, and a keystroke typed into the wrong process is the same `ok` as one that
landed. The screenshot shows a window that looks fine and the tree shows a
control that is there and enabled. Only the state around the act differs.

The line to look for names something other than the fixture:

> `step 6: keys "vim" -> ok; frontmost NOT the fixture: com.stablyai.orca`

That is a real finding, measured under load on 2026-09-25: **the harness's own
actuation tool had the screen and received its own keystrokes.** Five acts in
that run went that way, vim never opened, and every act reported success.
Activate-on-refusal cannot catch it — that fires when Orca DECLINES to deliver,
and this is Orca delivering, to itself. The runner now brings the fixture
forward before each act when the reading says it is not front; the line says
`brought forward` when it had to.

**Read the bundle id, not just the pid.** The same line has a second cause
that looks identical until you do:

> `after: frontmost NOT the fixture: dev.wakil.e2e (pid 6809)`

`dev.wakil.e2e` *is* the fixture's bundle id — but 6809 was not this run's
fixture. It was **another e2e run on the same machine**, launched by another
agent. Every run stages its own copy under that one identifier and calls
`Activate` to pull its own fixture forward, so two runs take the screen from
each other and the loser's keystrokes are delivered into the winner's window.
No guard could see it: `runningPIDs` is scoped to the bundle PATH and every run
stages under a fresh temp root, so the other instance matches nothing.

So the discriminator is the identifier:

- **`dev.wakil.e2e`, a pid that is not the fixture's** → a concurrent run
  (#299). The launch now refuses rather than running, and names the pids. That
  refusal is the guard working, not a new defect — wait for the other run.
- **anything else** → something on the machine took the screen (#292).

This cost most of a day, diagnosed as "the build machine's accessibility is
unreliable". **Before blaming the machine, check whether a colleague is running
e2e**, and say so before starting a long run of your own.

Two other readings carry their weight:

- `THE FIXTURE HAS NO FOCUSED WINDOW` — the app is running and presenting
  nothing. Behind a locked screen this is every act (see above).
- `keyboard focus on …` — what the keystroke arms were actually aimed at. After
  a `do.type` this should name the field that was typed into; anything else
  means focus moved between the two acts.

**Nothing in `acts.txt` decides anything.** An act whose reading looks wrong
still passed if the app did what the check asked, and no line in that file has
ever made a run red.

## The residue report

Short, and in the ticket as well as the runbook. One line per item:

> `org.plane.create` — no check. Creating an organisation writes a real
> credential boundary, and the fixture's seed cannot be re-entered mid-launch.

That is the only part of this skill's output the operator is expected to read.
Everything else is in the records.
