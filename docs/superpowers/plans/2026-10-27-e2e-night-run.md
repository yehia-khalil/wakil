# The e2e night run — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A launchd job that, between 23:00 and 07:00, runs `make e2e-full` once on the latest `origin/main` when it has moved since the last green night, fixes red checks with a headless Claude session on one branch for the night, re-runs them, and leaves a result any session can read.

**Architecture:** A new Go package `e2e/night` holds the night's sequence as one function over injected steps (so every branch of the night is unit-tested with fakes), plus a `Store` for state under the git common dir and the real steps (git, make, pgrep, claude). A thin command `e2e/cmd/wakil-e2e-night` exposes `run`, `status` and `install`. The only harness change is an opt-in keep-going in the Makefile's shared `e2e-run` loop.

**Tech Stack:** Go 1.27 (stdlib only, `embed`, `os/exec`, `syscall` for process groups), GNU Make 3.81, launchd (`launchctl bootstrap`), `claude -p`.

**Spec:** `docs/superpowers/specs/2026-10-27-e2e-night-run-design.md`

## Global Constraints

- Window: **23:00 to 07:00 local**. Nothing starts outside it; a run still going at 07:00 is stopped and reported `cut short`.
- One run per night, on `origin/main`, only when it differs from the last green night's commit.
- Fixes: one branch per night, `e2e-night/<YYYY-MM-DD>` (the date the night started), cut from the commit run; local commits only. **Never push, never open or comment on a PR or issue.** The PR text is a draft inside the result.
- Fixer rules (spec §"The fixer's rules") go into its prompt verbatim; one fix round and one re-run per night.
- `make e2e`, `make e2e-new` and `make e2e-full` behave exactly as today unless `E2E_KEEP_GOING=1` is set.
- State lives at `<git common dir>/wakil-e2e-night/` (today `/Users/yehia/Desktop/scripts/wakil-public/.git/wakil-e2e-night/`); the night worktree at `filepath.Dir(<common dir>) + "-night"` (today `/Users/yehia/Desktop/scripts/wakil-public-night`). Neither is committed.
- Commits: no `Co-Authored-By` or "Generated with" lines (operator's global rule).
- The repo's commit style: `<area>: <what changed>`, lower case, as in `git log`.

## Review Focus

1. **Mac asleep at 23:00, launchd fires the missed job on wake at 08:30.** Expected: no run, a `did not start` result saying it woke outside the window. → test in Task 3.
2. **A daytime session's e2e is between two check files when 23:00 arrives** (no Wakil process for a few seconds). Expected: the night waits for 2 minutes of quiet, not one empty `pgrep`. → test in Task 4.
3. **The fixer commits nothing, or its `make test` is red and it gives up.** Expected: no re-run, result `red` naming the branch as empty; no empty branch left behind. → test in Task 3.
4. **The night worktree was left dirty or on yesterday's fix branch.** Expected: it is reset to the new `origin/main` commit, ignored files (`.context/`) kept. → test in Task 4.
5. **The suite is killed at the deadline with a Wakil fixture still open.** Expected: process group killed, the fixture torn down, result `cut short`, never `red` from the partial records. → test in Task 3 (outcome) and Task 4 (process-group kill).

---

### Task 1: Keep-going opt-in in the shared e2e loop

**Files:**
- Modify: `Makefile` (the `e2e-run` recipe, lines ~363–391, and its comment block)
- Test: `scripts/makefile_test.go`

**Interfaces:**
- Produces: `make e2e-full E2E_KEEP_GOING=1` and `make e2e E2E_ONLY='<files>' E2E_KEEP_GOING=1` run every file and exit non-zero if any was red. New variable `E2E_RUNNER ?= go run ./e2e/cmd/wakil-e2e` replaces the literal in the loop (the test seam).

- [ ] **Step 1: Write the failing tests** in `scripts/makefile_test.go`:
  - `TestE2ERunStopsAtTheFirstRedFileByDefault`: `make -C <root> e2e-run E2E_BUNDLE=<tempdir> E2E_FILES="a.jsonl b.jsonl" E2E_RUNNER=<script>` where `<script>` is a temp shell script that appends its last argument to a log file and exits 1. Assert the log holds only `a.jsonl` and make exits non-zero.
  - `TestE2ERunKeepsGoingWhenAsked`: same with `E2E_KEEP_GOING=1`; assert the log holds `a.jsonl` then `b.jsonl` and make exits non-zero.
  Both runs end in the real `e2e-cover`; its outcome is irrelevant to the assertions.
- [ ] **Step 2: Run** `go test ./scripts -run 'TestE2ERun' -v`. Expected: FAIL (both: `E2E_RUNNER` is ignored, the real driver is invoked).
- [ ] **Step 3: Implement** `E2E_RUNNER ?= go run ./e2e/cmd/wakil-e2e` and `E2E_KEEP_GOING ?=`; in the loop `|| { status=1; [ -n "$(E2E_KEEP_GOING)" ] || break; }`. Add two lines to the comment above `e2e-run` saying the night run is the caller of keep-going.
- [ ] **Step 4: Run** `go test ./scripts -v`. Expected: PASS, existing Makefile tests included.
- [ ] **Step 5: Commit** `e2e: the shared loop can keep going past a red file when asked`.

### Task 2: The night's vocabulary — window, result, store

**Files:**
- Create: `e2e/night/window.go`, `e2e/night/result.go`, `e2e/night/store.go`
- Test: `e2e/night/window_test.go`, `e2e/night/result_test.go`, `e2e/night/store_test.go`

**Interfaces:**
- Produces:
  - `func InWindow(now time.Time) bool`: hour ≥ 23 or hour < 7, local.
  - `func Deadline(now time.Time) time.Time`: the next 07:00 local after `now`.
  - `func NightOf(now time.Time) time.Time`: midnight of the date the night started (a time before 07:00 belongs to the previous date).
  - `type Outcome string` with `NotPending = "not pending"`, `DidNotStart = "did not start"`, `Green = "green"`, `Red = "red"`, `CutShort = "cut short"`.
  - `type RedFile struct { File, Note string; Fatal []string; Evidence string }`
  - `type SuiteRun struct { Red []RedFile; CoverRed string; TimedOut bool }`, with `func (s SuiteRun) Outcome() Outcome` (TimedOut → `CutShort`; any Red or CoverRed → `Red`; else `Green`).
  - `type Result struct { Night time.Time; Outcome Outcome; Reason, Main string; First SuiteRun; Branch string; FixCommits []string; Fixer string; Rerun *SuiteRun; Skipped []string }` and `func (r Result) Markdown() string`.
  - `func RedFilesSince(evidenceRoot string, since time.Time) ([]RedFile, error)`: `driver.ReadRunRecords` filtered to `RanAt ≥ since` and `!Green()`, sorted by `File`.
  - `type Store struct { Dir string }`, `func OpenStore(repo string) (Store, error)` (dir = `<git rev-parse --git-common-dir>/wakil-e2e-night`, created), `LastGreen() (string, error)` (empty when absent), `SetLastGreen(commit string) error`, `WriteResult(r Result) (string, error)` → `results/<YYYY-MM-DD>.md`, `Latest() (night time.Time, body string, err error)`.

- [ ] **Step 1: Write the failing tests:**
  - window: `InWindow` true at 23:00, 02:00, 06:59; false at 07:00, 22:59. `Deadline(23:00 Oct 27) == 07:00 Oct 28`; `Deadline(02:00 Oct 28) == 07:00 Oct 28`. `NightOf(02:00 Oct 28) == Oct 27`.
  - result: `SuiteRun{TimedOut: true, Red: [...]}.Outcome() == CutShort` (a cut-short run is never red); `Markdown()` of a red result with a rerun contains the commit, each red file with its note, the branch, each fix commit, and the heading `Draft PR description`; a green-after-fix rerun is written `green after a night fix (<commit>)`; `Markdown()` never contains the word `green` for a `DidNotStart` result's outcome line.
  - store: in a `git init` temp repo, `LastGreen()` is `""`, then `SetLastGreen("abc")` round-trips; `WriteResult` for night Oct 27 writes `results/2026-10-27.md` and `Latest()` returns it; with two results, `Latest()` returns the later night. `RedFilesSince` over a temp evidence root holding three records written with `driver.WriteRunRecord` (one green, one red before `since`, one red after) returns only the last.
- [ ] **Step 2: Run** `go test ./e2e/night -v`. Expected: FAIL (package does not exist).
- [ ] **Step 3: Implement** the three files to the interfaces above.
- [ ] **Step 4: Run** `go test ./e2e/night -v`. Expected: PASS.
- [ ] **Step 5: Commit** `e2e night: the window, the result and where the night keeps its state`.

### Task 3: The night's sequence

**Files:**
- Create: `e2e/night/run.go`
- Test: `e2e/night/run_test.go`

**Interfaces:**
- Consumes: everything Task 2 produces.
- Produces:
  ```go
  type FixInput struct {
      Branch, Main  string
      Red           []RedFile
      CoverRed      string
      Unmerged      []string // earlier e2e-night/* branches not merged into Main
      SummaryPath   string   // where the fixer writes its summary and PR draft
      Deadline      time.Time
  }
  type Steps struct {
      Now        func() time.Time
      ScreenQuiet func(until time.Time) (bool, error) // false: still busy at until
      Fetch      func() (main string, err error)      // git fetch origin; rev-parse origin/main
      Prepare    func(commit string) error            // night worktree, detached, clean
      Suite      func(deadline time.Time) (SuiteRun, error)               // make e2e-full keep-going
      Branch     func(name, at string) error
      Unmerged   func(main string) ([]string, error)
      Fix        func(in FixInput) error
      Commits    func(since string) ([]string, error)
      DropBranch func(name string) error
      Rerun      func(files []string, deadline time.Time) (SuiteRun, error)
  }
  func Run(steps Steps, store Store) Result
  ```
  `Run` writes the result through `store.WriteResult` and returns it; every error becomes a `DidNotStart` or a `Skipped` line, never a panic or a silent green.
- Pinned values: `RerunEstimate(n int) = 15*time.Minute + time.Duration(n)*5*time.Minute`; the fixer's `Deadline` is `Deadline(now) - RerunEstimate(len(red))`; a rerun starts only if `now + RerunEstimate(len(red)) ≤ Deadline(now)`, else `Skipped` gets `re-run skipped: it could not finish by 07:00`. `SummaryPath = <store.Dir>/results/<YYYY-MM-DD>-fixer.md`; `Result.Fixer` is that file's contents.

- [ ] **Step 1: Write the failing tests**, one per path, with fake `Steps` recording calls and a fixed `Now`:
  - `TestOutsideTheWindowNothingRuns` (Now 08:30): `DidNotStart`, reason mentions 07:00, `Fetch` never called.
  - `TestABusyScreenUntilTheDeadlineDoesNotStart`: `ScreenQuiet` returns false → `DidNotStart`, `Suite` never called.
  - `TestMainNotMovedIsNotPending`: `Fetch` returns the stored last green → `NotPending`, `Prepare` never called.
  - `TestAGreenNightMovesLastGreen`: `Suite` green → `Green`, `store.LastGreen()` is the fetched commit, `Fix` never called.
  - `TestARedNightFixesOnOneBranchAndRerunsOnlyTheRed`: two red files → `Branch("e2e-night/2026-10-27", main)`, `Fix` receives both files and the unmerged list, `Rerun` receives exactly those two files, result `Red` with `Rerun` set, `LastGreen` unchanged.
  - `TestAFixerThatCommitsNothingIsNotRerun`: `Commits` empty → no `Rerun`, `DropBranch` called, result `Red`, Skipped says the fixer committed nothing.
  - `TestARerunThatCannotFinishBy7IsSkipped`: Now 06:40 at rerun time, one red → no `Rerun`, Skipped line as pinned.
  - `TestACutShortSuiteIsNeitherGreenNorRedAndIsNotFixed`: `Suite` returns `TimedOut` with red files → `CutShort`, `Fix` never called, `LastGreen` unchanged.
  - `TestACoverageRedIsReportedNotFixed`: `Suite` returns only `CoverRed` → `Red`, `Fix` never called, the cover output is in `Markdown()`.
  - Every test asserts a result file was written.
- [ ] **Step 2: Run** `go test ./e2e/night -run 'Test' -v`. Expected: FAIL (`Run` undefined).
- [ ] **Step 3: Implement `Run`** in that order: window → screen quiet until `Deadline` → fetch → pending → prepare → suite → (green: set last green) → (red files and not cut short: branch, fix, commits, rerun or skip) → write result.
- [ ] **Step 4: Run** `go test ./e2e/night -v`. Expected: PASS.
- [ ] **Step 5: Commit** `e2e night: the night's sequence, from the window to the result`.

### Task 4: The real steps

**Files:**
- Create: `e2e/night/steps.go`, `e2e/night/fixer-prompt.md` (embedded with `//go:embed`)
- Test: `e2e/night/steps_test.go`

**Interfaces:**
- Consumes: `Steps`, `FixInput`, `SuiteRun`, `RedFilesSince` (Tasks 2–3).
- Produces: `func RealSteps(repo string, store Store) Steps`, plus these, exported for the tests:
  - `func NightWorktree(commonDir string) string` → `filepath.Dir(commonDir) + "-night"`.
  - `func PrepareWorktree(repo, path, commit string) error`: `git worktree add --detach <path> <commit>` when absent; otherwise `git -C <path> checkout --detach --force <commit>` then `git -C <path> clean -fd` (no `-x`, so `.context/` survives).
  - `func UnmergedNightBranches(repo, main string) ([]string, error)`: `git branch --list 'e2e-night/*' --no-merged <main>`.
  - `func ScreenBusy() (bool, error)`: `pgrep -f '[W]akilE2E.app/Contents/MacOS/'` or `pgrep -f '[e]2e/cmd/wakil-e2e( |$)'` matches anything.
  - `func WaitQuiet(busy func() (bool, error), now func() time.Time, sleep func(time.Duration), until time.Time) (bool, error)`: true once `busy` has been false continuously for **2 minutes**, polling every **30 s**; false at `until`.
  - `func runUntil(dir string, deadline time.Time, name string, args ...string) (timedOut bool, err error)`: starts the command in its own process group (`SysProcAttr{Setpgid: true}`), kills the group at `deadline`, then runs `pkill -f 'WakilE2E.app/Contents/MacOS/'` to tear down a stray fixture.
  - `Suite` = `runUntil(worktree, deadline, "make", "e2e-full", "E2E_KEEP_GOING=1")`, then `RedFilesSince(<worktree>/.context/e2e, start)`, then `make e2e-cover` (output kept as `CoverRed` when it exits non-zero). `Rerun` = the same with `make e2e E2E_ONLY='<files>' E2E_KEEP_GOING=1`.
  - `Fix` = `runUntil(worktree, in.Deadline, "/Users/yehia/.local/bin/claude", "-p", <prompt>, "--permission-mode", "bypassPermissions")`, with the prompt rendered from `fixer-prompt.md` by `text/template` over `FixInput`.
- `fixer-prompt.md` carries the spec's fixer rules word for word, the red files with their notes and evidence paths, the unmerged night branches ("if one already fixes a failure, say so and do not fix it again"), the instruction to commit on the current branch only with the repo's commit style and no attribution lines, and to write a summary plus a drafted PR description to `{{.SummaryPath}}`.

- [ ] **Step 1: Write the failing tests:**
  - `PrepareWorktree` in a temp repo with two commits: first call creates the worktree at commit 1; then dirty a tracked file, add an untracked file and a file under `.context/`, call again with commit 2 → HEAD is commit 2, tracked change and untracked file gone, `.context/` file still there.
  - `UnmergedNightBranches`: a temp repo with `e2e-night/2026-10-26` merged into main and `e2e-night/2026-10-25` not → returns only the latter.
  - `WaitQuiet` with a fake clock: busy pattern `[true, false, true, false, false, false, false, false]` at 30 s steps → returns true only after four consecutive quiet polls (2 min); a busy-forever fake returns false at `until`.
  - `runUntil` with `sh -c 'sleep 30 & sleep 30'` and a deadline 1 s away → `timedOut` true, returns within 5 s, and `pgrep -g <pgid>` finds nothing.
  - The rendered prompt for a sample `FixInput` contains every red file, `{{.SummaryPath}}`'s value, "Never retries a check into green" and "never pushes".
- [ ] **Step 2: Run** `go test ./e2e/night -v`. Expected: FAIL (undefined).
- [ ] **Step 3: Implement** `steps.go` and `fixer-prompt.md`.
- [ ] **Step 4: Run** `go test ./e2e/night -v`. Expected: PASS.
- [ ] **Step 5: Commit** `e2e night: the real steps — worktree, quiet screen, suite, fixer`.

### Task 5: The command, the launchd job, the make targets

**Files:**
- Create: `e2e/cmd/wakil-e2e-night/main.go`, `e2e/night/launchd.go`
- Modify: `Makefile` (new targets `e2e-night-install`, `e2e-night-status`; add both to `.PHONY`)
- Test: `e2e/night/launchd_test.go`

**Interfaces:**
- Consumes: `OpenStore`, `RealSteps`, `Run`, `Store.Latest`, `NightOf`.
- Produces:
  - `wakil-e2e-night run`: `Run(RealSteps(repo, store), store)`; exit 0 unless the result could not be written.
  - `wakil-e2e-night status`: prints `Store.Latest()`; when the latest night is older than the last night that should have run (`NightOf(now)` when now ≥ 07:00 or in the window, else the night before), prints `no result for the night of <date>: the job did not run` first and exits 1.
  - `wakil-e2e-night install`: builds itself to `<store.Dir>/bin/wakil-e2e-night` (`go build`), writes the plist, `launchctl bootout gui/<uid>/<label>` (ignore failure), `launchctl bootstrap gui/<uid> <plist>`.
  - `const Label = "com.yehia-khalil.wakil.e2e-night"`; `func Plist(binary, repo, logPath, path string) string`: `ProgramArguments` `[binary, "run", "--repo", repo]`, `StartCalendarInterval` Hour 23 Minute 0, `EnvironmentVariables` PATH = the installer's `$PATH`, `StandardOutPath`/`StandardErrorPath` = `<store.Dir>/night.log`. Written to `~/Library/LaunchAgents/<Label>.plist`.
  - `make e2e-night-install` → `go run ./e2e/cmd/wakil-e2e-night install`; `make e2e-night-status` → `go run ./e2e/cmd/wakil-e2e-night status`.

- [ ] **Step 1: Write the failing test** `TestPlistRunsTheNightAt23WithThePathItWasInstalledWith`: `Plist(...)` parses with `plutil -lint -` (skip if `plutil` missing) and contains `<integer>23</integer>`, `<integer>0</integer>`, the label, the binary and `run`, and the PATH passed in.
- [ ] **Step 2: Run** `go test ./e2e/night -run TestPlist -v`. Expected: FAIL.
- [ ] **Step 3: Implement** `launchd.go`, `main.go` (subcommand dispatch with `flag.NewFlagSet`, `--repo` default `.`), and the make targets.
- [ ] **Step 4: Verify:** `go test ./... ` PASS; `go vet ./e2e/...` clean; `go run ./e2e/cmd/wakil-e2e-night status` in this worktree prints `no result for the night of …` and exits 1 (no night has run yet).
- [ ] **Step 5: Commit** `e2e night: the command, its launchd job and the make targets`.

### Task 6: The docs and the copy say the night run replaces pre-merge e2e-full

**Files:**
- Modify: `e2e/driver/runbook.go:159-163`, `e2e/driver/runbook_test.go` (the owed-check test)
- Modify: `docs/agents/e2e.md` (step 9; the collision note), `docs/agents/workflow.md:40` (Walk row), `CONTRIBUTING.md:128`, `docs/architecture/testing.md` (`## e2e` and the make-targets table)
- Modify (outside the repo, not committed): memories `wakil-e2e-full-overnight.md` and `e2e-screen-sharing.md` in `/Users/yehia/Library/Application Support/orca/claude-profiles/fc5946b4-74f6-4771-a66a-a7da5d58881e/home/projects/-Users-yehia-Desktop-scripts-wakil-public/memory/`

**Interfaces:**
- Produces the copy: runbook owed sentence ends "…**%d check(s) are owed to `make e2e-full`**, which the night run covers on `main` after the merge (`make e2e-night-status`)."

- [ ] **Step 1: Update the test** `TestAnUnpickedCheckIsOwedToTheFullRunAndIsNotAFault` to also want `"the night run covers on `main` after the merge"`.
- [ ] **Step 2: Run** `go test ./e2e/driver -run TestAnUnpickedCheck -v`. Expected: FAIL.
- [ ] **Step 3: Change** the sentence in `runbook.go`.
- [ ] **Step 4: Run** `go test ./e2e/driver -v`. Expected: PASS.
- [ ] **Step 5: Docs:** e2e.md step 9 becomes "No `make e2e-full` before merge: the night run (`make e2e-night-status`) runs it on `main` after the merge, fixes what it can on `e2e-night/<date>`, and reports the rest"; add to the screen-collision guidance "and wait while `pgrep -f '[w]akil-e2e-night run'` matches". workflow.md Walk row drops "and before merge `make e2e-full` green on the merging head with the runbook re-rendered". CONTRIBUTING.md:128 ends "`make e2e-full` runs nightly on `main` (the night run), not before merge." testing.md gains `make e2e-night-install` / `make e2e-night-status` rows and one line under `## e2e`. Then `make docs-check` PASS and `go test ./scripts -v` PASS (architecture docs test).
- [ ] **Step 6: Memories:** rewrite `wakil-e2e-full-overnight` to "no pre-merge e2e-full; the night run covers main; read `make e2e-night-status` for last night", and add the night-process wait to `e2e-screen-sharing`. Update both `MEMORY.md` lines.
- [ ] **Step 7: Commit** `e2e night: the docs and the runbook say the night run covers what merges`.

### Task 7: Install, after this branch merges

The night runs `main`'s Makefile, so `E2E_KEEP_GOING` only exists for it once Task 1 is on `main`. Installing earlier would make the first nights stop at the first red file.

- [ ] **Step 1:** After the merge, `make e2e-night-install` from a checkout of the merged `main`.
- [ ] **Step 1b (operator):** grant the binary it prints Accessibility, Screen Recording and Files and Folders › Desktop in System Settings › Privacy & Security. Added after the final review: under launchd no terminal lends its grants, and a night without them reports `did not start`. Expected: `launchctl print gui/$(id -u)/com.yehia-khalil.wakil.e2e-night` shows the job with a calendar trigger at 23:00.
- [ ] **Step 2:** Tell the operator the first night is tonight and what to run in the morning (`make e2e-night-status`). Do not trigger a run in the day.
