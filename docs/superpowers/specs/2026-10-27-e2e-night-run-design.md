# The e2e night run

Brainstormed with the operator on 2026-10-27.

## Why

Every e2e check drives the real Wakil window on the operator's Mac, and mouse
input during a run makes it unsound. The operator uses the Mac all day and a full
run takes about an hour, so `make e2e-full` before each merge either waits on the
screen or gets skipped. By evening, feature branches have often merged already,
so testing them one by one at night would test work that is gone.

The Mac is free **from 23:00** and **stays unlocked** overnight (the operator).

## What it is

Every night at 23:00, a macOS scheduled job:

1. **Checks whether `main` has pending e2e**: it does when `origin/main` has moved
   since the last night run that came out green. If not, the night ends there and
   says so.
2. **Runs `make e2e-full` once, on the latest `origin/main`**, in a worktree kept for
   the night run. That covers everything merged since the last green night.
3. **If anything is red, fixes it** with a headless Claude session, on **one fix branch
   for the night** cut from that `main` commit (for example `e2e-night/2026-10-27`).
   All the night's fixes go on that branch together, as local commits.
4. **Re-runs the failed checks on the fix branch** the same night.
5. **Leaves a morning result**: what ran against which commit, the outcome with
   reasons, the fix branch and its commits, and a **drafted** PR description for the
   operator to sign off. Nothing is pushed or posted.

During the day nothing changes: sessions still run only new and affected checks
(`make e2e-new`, `make e2e`) at Cover, as now. The night run catches the rest.

## Decided

**By the operator:**
- Night window is **23:00 to 07:00**; the Mac stays unlocked and awake. The screen must
  be free by 07:00: a step that cannot finish by then is not started (a re-run is skipped,
  a waiting start gives up), and a run still going at 07:00 is stopped and reported as
  cut short, never as green or red.
- On the Mac. The Pi is out because the checks drive this Mac's window.
- One run per night, on `main`, and only when `main` has pending e2e.
- Failed checks are fixed overnight, all fixes together on one branch, shipped as one PR.
- **The pre-merge `make e2e-full` is dropped.** A branch merges once its new and
  affected checks are green (`make e2e-new`, `make e2e`); the night run on `main` is
  the full run. `docs/agents/e2e.md` step 9, the Walk row of `docs/agents/workflow.md`
  and the *e2e-full overnight* memory change to say so.
- Fixes are local commits; the PR text is a draft (operator's global rule: nothing
  others read is posted before sign-off).

**My calls, accepted by the operator in chat:**
- "Pending" means `origin/main` has moved since the last green night run. A red
  night leaves `main` pending, so the next night runs it again.
- A full run, not an affected-only one, because a night has room for it and it is the
  run that turns "owed to `make e2e-full`" green.
- `git fetch origin` before the run, because merges land on GitHub. Read-only.
- One stuck run cannot eat the night: past its time limit it is stopped, its Wakil
  instance torn down, and the result says so.
- **The night run carries on past a red file.** Today `e2e-run` stops at the first red
  file (`|| { status=1; break; }`), so one night would find one failure. The shared loop
  gets an opt-in to keep going and report every red; the default for `make e2e` and
  `make e2e-full` is unchanged. The re-run then covers every file that was red.
- **A red coverage gate (`make e2e-cover`) is reported, not fixed.** It means a merged
  branch skipped Cover; writing checks is the auditor's job with the screen, not the
  night fixer's. The morning result names the uncovered surface.
- **Runbooks are not re-rendered by the night run** (amended while planning). A runbook's
  machine section is a claim about *its* branch against *its* merge-base; rendering it
  again on `main` would rewrite it as a claim about a different branch. Instead the
  runbook copy for owed checks changes from "runs once, on the head that merges" to
  "covered by the night run on `main` after the merge", and the night's result is the
  record that they ran.
- **A lock keeps daytime runs off the screen during the night run.** The lock is the
  night run's own process (`wakil-e2e-night run`), alive for the whole night, so a crash
  leaves no stale lock. `docs/agents/e2e.md` and the *e2e screen sharing* memory say a
  session waits on that process as well as on the Wakil `pgrep`.

## The fixer's rules

Binding. They come from `docs/agents/e2e.md` §"What the auditor must never do".

- Starts only after the run is red, works in the night worktree on the fix branch,
  headless (`claude -p`), and never touches the screen.
- Reads the failure reasons, not the count. A red that says the harness could not
  reach the window is not a code failure, and nothing is fixed for it.
- Fixes the **code**, not the check. If it concludes the check itself is wrong, it may
  fix the check and must say so in the result.
- Never retries a check into green, never adds to `uncoverable.tsv`, never quarantines.
- Proves each change with `make test` and `make app-test` before committing, following
  the repo's commit conventions.
- **One fix round and one re-run per night.** Still red after the re-run means stop
  and write down what was found.
- If an earlier night's fix branch is still unmerged and already fixes a failure, it
  says so and points at it rather than fixing it a second time.
- A check that goes green on the re-run is reported as *green after a night fix*,
  naming the commit, so the operator reviews the fix before trusting it.
- Never pushes, never opens or comments on a PR or issue.

## Results

One result per night that the operator, or any session in any worktree, can read with
one command and without the operator relaying it. It says: whether `main` was pending,
the commit run, the outcome and failure reasons, the fix branch and commits, the
re-run's outcome, anything skipped and why, and the drafted PR text. A night that did
not run (Mac asleep, job failed to start) must be visible as such and must never look
like a quiet green.

## Non-goals

- The Pi or any second machine.
- Running feature branches at night.
- Changing the checks, the harness (`e2e/driver`, `wakil-e2e`) or what `make e2e`,
  `make e2e-new` and `make e2e-full` do by default. The only change is the opt-in
  keep-going in the shared loop.
- Pushing, PRs or notifications.

## Anti-goals (failure even if it works)

- A check made green by retrying, quarantining or weakening it.
- Two runs on the screen at once, or a run outside 23:00–07:00.
- A morning where "green", "red" and "never ran" can be confused.
- Fix commits the operator cannot easily see and drop.

## Constraints

- All worktrees share one git common dir
  (`/Users/yehia/Desktop/scripts/wakil-public/.git`). The night run's state (last green
  commit, results) lives outside any feature worktree and is never committed.
- The job must run with no Claude session open: a launchd job, not a Claude Code cron
  (those are session-only).
- `claude` is at `/Users/yehia/.local/bin/claude`.
- A daytime session still running e2e by hand must not collide with the night run
  (memory *e2e screen sharing*: wait on `pgrep -f "[W]akilE2E.app/Contents/MacOS/Wakil"`).
  The night run waits the same way before it starts.
- Building and testing while checks run may slow the Mac. The fixer works between the
  full run and the re-run, so the screen run never shares the machine with a build.

## Left to the builder

- Where the night worktree, the state and the results live, and their format.
- The command that shows the latest result, and how `docs/agents/e2e.md` and the
  *e2e-full overnight* memory change to point at the night run.
- Time limits, how a stuck run is detected, the launchd plist and how it is installed.
- The fixer's prompt and permission mode.
