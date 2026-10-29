# Docs lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feature documents leave `main` with their feature, a check enforces it, and the files every session reads are trimmed.

**Architecture:** One `make merge-check` target holds the rule; the night run calls it on `main`. Everything else is document edits and deletions, in commits a reviewer can read one at a time.

**Tech Stack:** Make, Go (`e2e/night`), Markdown.

**Spec:** `docs/superpowers/specs/2026-10-29-docs-lifecycle-design.md`

## Global Constraints

- Gates do not change: Design, Plan, Build, Cover and Walk, `make e2e`/`make e2e-new`, the operator's walk before merge.
- The trim bar (operator, 2026-10-29): cut a sentence if an agent starting a new task would act no differently without it.
- `north-star.md` §4 Invariants and §9 Glossary keep their meaning exactly. `north-star.md` stays ≤ 4,000 words (`make docs-check`).
- `Decision N` numbers are permanent; every number cited anywhere in the repo still resolves to an entry or a tombstone.
- Code comments that cite a deleted path are not edited.
- `docs/wakil/*-probe.md` are out of scope.
- No `Co-Authored-By` trailers in commits.

## Review Focus

1. **A decision lost with its spec:** a ruling that still governs code is in neither `decisions.md` nor a code comment. Tasks 3 and 4 add the extraction and citation checks.
2. **A dangling link in a kept doc:** a remaining Markdown file links to a deleted file. Task 6 adds the link check.
3. **A trimmed doc that changes how an agent behaves:** Task 7 adds the quiz check.
4. **An unmerged feature's docs deleted:** the connections and ticket-view specs, plans and runbooks live on their own branches, not on `main`. Task 6 touches only what is on `main`.
5. **The night run broken by the new step:** a failing `merge-check` must be reported and must not stop the suite. Task 8's tests cover it.

**One PR, not two** (a change from the spec's "separate PR"). The cleanup can't land after a rules PR that still carries its own spec. Commits are grouped so the rules (Tasks 1–2) can be reviewed apart from the deletions.

**No runbook or e2e:** there is no UI change, so Cover and Walk have nothing to reach. The operator reviews the PR diff instead.

---

### Task 1: `make merge-check`

**Files:**
- Modify: `Makefile`: add `merge-check` to `.PHONY` (line 59), and the target after `docs-check` (around line 92) with a two-line comment.

- [ ] **Step 1:** Implement `merge-check`. It lists `git ls-files docs/superpowers/plans docs/superpowers/specs 'docs/wakil/*-acceptance.md'`. If any are listed, it prints them under `Feature documents must leave with their feature (docs/agents/workflow.md):` and exits 1. Otherwise it prints `  merge-check: no feature documents` and exits 0.
- [ ] **Step 2:** Run `make merge-check` here. Expected: exit 1, listing the spec, this plan, and the 54 runbooks.
- [ ] **Step 3:** Run `git worktree add --detach .scratch/mc HEAD && cd .scratch/mc && git rm -rq docs/superpowers docs/wakil/*-acceptance.md && make merge-check; cd - && git worktree remove --force .scratch/mc`. Expected: exit 0.
- [ ] **Step 4:** Commit: `docs lifecycle: make merge-check — feature documents never reach main`.

### Task 2: The rules in the agent docs

**Files:**
- Modify: `docs/agents/workflow.md`, `docs/agents/domain.md`, `docs/architecture/README.md` (lines 78–81), `docs/architecture/testing.md` (line 71), `PRODUCT.md` (line 176), `docs/wakil/decisions.md` (header only), `docs/wakil/phase-log.md` (header only), `CLAUDE.md` (Workflow paragraph).

- [ ] **Step 1: `workflow.md`.**
  - The ladder: Design, Plan and Walk say their files live on the branch. Walk's "an entry in `phase-log.md`" means an entry for an unmerged sub-phase.
  - Replace "The historical artefacts stay where they are" with a short section **Feature documents leave with the feature**, covering spec rules 1, 2, 5 and 6, plus the timing calls: delete after the walk passes, each stacked PR deletes its own, `merge-check` gates merging.
  - The "Where a spec and the shipped code disagree" rule says "on the branch".
- [ ] **Step 2: `domain.md`.** Specs, plans and runbooks are on a feature's branch while it is built. Add the one line: a cited path that no longer exists is found with `git log --all -- <path>`.
- [ ] **Step 3: The other files.**
  - Architecture README, `testing.md` and `PRODUCT.md`: update the lines that describe where these files live.
  - `decisions.md` header: short form, tombstones, and numbers permanent (spec rule 3). This replaces "never deleted — the history is the point".
  - `phase-log.md` header: unmerged sub-phases only, and owed items go to `parked.md` (spec rule 4).
  - `CLAUDE.md`: one sentence that feature docs leave with the feature.
- [ ] **Step 4:** Run `make docs-check`. Expected: green.
- [ ] **Step 5:** Commit: `docs lifecycle: the agent docs say feature documents leave with the feature`.

### Task 3: Extract standing decisions from the specs on `main`

**Files:**
- Create: `.scratch/docs-lifecycle/extracted.md` (not committed): candidate decisions, each with its source spec and the code or check it governs.

- [ ] **Step 1:** Split the 60 specs (all except this feature's) into batches of about 8 and give each batch to a fresh subagent. A ruling qualifies when reversing it would change code or a check. Each candidate comes back as: the call, one line of why, one line of what would reverse it, the code path or check it governs, and the commit that landed it (`git log --diff-filter=A --format=%h -1 -- <spec>`). Drop candidates already in `decisions.md`.
- [ ] **Step 2:** Merge the batches and drop duplicates. Expected: one list, every entry naming a real path (`git ls-files` or `git grep` finds it).
- [ ] **Step 3:** Nothing to commit. Task 4 consumes the list.

### Task 4: `decisions.md` in short form

**Files:**
- Modify: `docs/wakil/decisions.md`, and `docs/wakil/north-star.md` §6 (the index) if a title changes.

- [ ] **Step 1:** Rewrite every standing entry to the short form: the call, why, reverse if, commit. Drop amendment history.
- [ ] **Step 2:** Make every replaced entry a one-line tombstone: `N. *Replaced by Decision M (<sha>).*`
- [ ] **Step 3:** Append Task 3's entries with new numbers.
- [ ] **Step 4:** Keep the "Invariant 6" appendix, tightened to the trim bar; `north-star.md` §4 still points to it.
- [ ] **Step 5:** Citation check. Every number in `git grep -ohE 'Decision [0-9]+' | sort -u` has an entry: `for n in $(git grep -ohE 'Decision [0-9]+' | grep -oE '[0-9]+' | sort -un); do grep -qE "^$n\. " docs/wakil/decisions.md || echo "missing $n"; done`. Expected: no output.
- [ ] **Step 6:** Run `make docs-check`, and record the word count before and after in the commit message.
- [ ] **Step 7:** Commit: `docs lifecycle: decisions.md — standing decisions in short form, replaced ones tombstoned`.

### Task 5: `phase-log.md` holds unmerged sub-phases only

**Files:**
- Modify: `docs/wakil/phase-log.md`, `docs/wakil/parked.md`.

- [ ] **Step 1:** Delete every entry for a sub-phase that is merged (its §8 row has a `Met` date). Move each item still owed to `parked.md`, one line each, with the sub-phase and commit. Delete the non-record sections ("The 2026-09-15 split", "What the status table points at") except the few lines the header needs.
- [ ] **Step 2:** Run `make docs-check`. Expected: green. Check that `grep -c '^## ' docs/wakil/phase-log.md` equals the number of §8 rows without a `Met` date.
- [ ] **Step 3:** Commit: `docs lifecycle: phase-log keeps unmerged sub-phases; owed items to parked.md`.

### Task 6: Delete the feature documents on `main`

**Files:**
- Delete: `docs/superpowers/plans/*` and `docs/superpowers/specs/*` (except this feature's two files), and `docs/wakil/*-acceptance.md`.
- Modify: any kept Markdown that links to a deleted file.

- [ ] **Step 1:** `git rm` the files above.
- [ ] **Step 2:** Run the link check: `git grep -nE 'docs/superpowers/(plans|specs)/[^ )]+|docs/wakil/[a-z0-9-]+-acceptance\.md' -- '*.md' ':!docs/superpowers'`. Rewrite each hit as the decision or fact it stood for, or drop it. Generic patterns like `docs/wakil/*-acceptance.md` in the rules text stay. Expected: only those generic hits remain.
- [ ] **Step 3:** Commit: `docs lifecycle: delete merged plans, specs and runbooks (git keeps them)`.

### Task 7: Trim the always-read files

**Files:**
- Modify: `docs/wakil/north-star.md`, `docs/wakil/design-language.md`, `PRODUCT.md`, `docs/agents/*.md`, `CLAUDE.md`.

- [ ] **Step 1:** Before editing, have a fresh subagent write a quiz from the current files: 20 questions an agent on a new task would need answered (rules, invariants, where code goes, interaction rules, e2e auditor steps), each with its answer. Save it to `.scratch/docs-lifecycle/quiz.md`.
- [ ] **Step 2:** Trim each file to the trim bar. §4 and §9 keep their meaning.
- [ ] **Step 3:** Give a second fresh subagent the quiz questions only (no answers) and the trimmed files only. Expected: all 20 answers match. A miss means restoring the cut that held the answer.
- [ ] **Step 4:** Run `make docs-check`. Expected: green. Record per-file word counts before and after in the commit message.
- [ ] **Step 5:** Commit: `docs lifecycle: trim the files every session reads`.

### Task 8: The night run reports feature documents on `main`

**Files:**
- Modify: `e2e/night/run.go` (`Steps`, `Run`), `e2e/night/result.go` (`Result`, and wherever the result is rendered), `e2e/night/steps.go` (`RealSteps`), `e2e/night/run_test.go`.

**Interfaces:**
- Produces: `Steps.MergeCheck func() error`, and `Result.MergeCheck string` (empty when clean, otherwise the error text).

- [ ] **Step 1:** Write failing tests in `run_test.go`, using the existing fake (`newFake`):
  - `TestFeatureDocsOnMainAreReportedAndTheSuiteStillRuns`: `MergeCheck` returns an error. Expect `r.MergeCheck` to contain the error text, and `f.called("suite")`.
  - `TestCleanMainReportsNoFeatureDocs`: `MergeCheck` returns nil. Expect `r.MergeCheck == ""`.
- [ ] **Step 2:** Run `go test ./e2e/night/ -run 'FeatureDocs|NoFeatureDocs'`. Expected: FAIL, because `MergeCheck` doesn't exist yet.
- [ ] **Step 3:** In `Run`, call `steps.MergeCheck()` after `Prepare` and before `Preflight`, store the result, and continue either way. `RealSteps` runs `make merge-check` in the night worktree. Render a non-empty `Result.MergeCheck` as one line next to `Skipped`.
- [ ] **Step 4:** Run `go test ./e2e/night/`. Expected: PASS.
- [ ] **Step 5:** Commit: `night: report feature documents left on main`.

### Task 9: Leave with the feature

- [ ] **Step 1:** `git rm docs/superpowers/specs/2026-10-29-docs-lifecycle-design.md docs/superpowers/plans/2026-10-29-docs-lifecycle.md`. This spec states no lasting decision that Task 2 hasn't already put into `workflow.md` and `decisions.md`; check that before deleting.
- [ ] **Step 2:** Run `make merge-check && make test`. Expected: both green.
- [ ] **Step 3:** Commit: `docs lifecycle: the design and plan leave with the feature`.
- [ ] **Step 4:** Draft the PR text to `.scratch/docs-lifecycle/pr.md`, with word counts before and after, for the operator to sign off. Do not push.
