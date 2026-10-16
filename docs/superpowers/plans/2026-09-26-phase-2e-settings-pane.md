# Phase 2e — the settings pane: Cover, Walk and the residue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn 2e's last three rungs — land the two PRs still out, run Cover now that it is finally possible, and get the runbook walked — so `Met` can be filled in `north-star.md` §8.

**Architecture:** **2e is built and merged.** [PR #297](https://github.com/yehia-khalil/rafiq/pull/297) landed the whole nineteen-branch stack on `main` on 2026-09-26 — 17,843 insertions across 109 files, including `SettingsPane.swift` (1,819 lines), `ProviderLoginSession.swift`, `ProviderMint.swift`, `PseudoTerminal.swift`, `AccountTable.swift`, and the Go halves in `internal/wakilcore/{accounts,adopt,configdir,configtree,credpresence,liveness,mint,orgupdate,projectwrite,pty,unlink}.go`. **This plan builds almost nothing.** It lands what is still out, turns the Cover rung, and gets the document walked.

**Tech Stack:** Swift 6 (`WakilKit` testable, `WakilApp` not), Go, swift-testing, `make test` / `make app-test` / `make e2e`.

**Spec:** [#89](https://github.com/yehia-khalil/rafiq/issues/89), as corrected by `docs/wakil/provider-login-probe.md` (§9 the live login, §10 the expiry, §11 the mint) and `docs/wakil/phase-2e-probe.md`. **Where the spec and a probe disagree, the probe governs.**

**Runbook:** `docs/wakil/phase-2e-acceptance.md` — human half written, **provisional**, **not walked**, and its own header records why it never went through Cover: *"the e2e harness lives on `main` and this stack is not yet rebased onto it."* **That sentence is now false** — the stack merged, so Cover is unblocked for the first time.

**Absorbs:** [#236](https://github.com/yehia-khalil/rafiq/issues/236), [#238](https://github.com/yehia-khalil/rafiq/issues/238), [#240](https://github.com/yehia-khalil/rafiq/issues/240), [#244](https://github.com/yehia-khalil/rafiq/issues/244), [#259](https://github.com/yehia-khalil/rafiq/issues/259), [#269](https://github.com/yehia-khalil/rafiq/issues/269), [#270](https://github.com/yehia-khalil/rafiq/issues/270), [#271](https://github.com/yehia-khalil/rafiq/issues/271) — all **shipped in #297**, closed as completed. Their one unmet criterion is carried into Task 4 below.

## Global Constraints

- **Invariant 4.** An organisation reads only its own bindings. #271 found `loginBinary()` reading the agent executable **across the organisation boundary** — *"they all name the same CLI on this machine"* is exactly the probable-but-unenforced claim the invariant exists to refuse. Nothing in this plan may reintroduce a cross-org read.
- **The operator never sees or types a token.** The mint runs in Go, the token never reaches Swift, is never journalled, and is never shown. The phase's second exit clause is *"every binding the pane draws has a credential the operator did not paste."*
- **Three runbook checks create a real one-year credential at Anthropic** (checks 3, 4, 7). They are marked in the document and each states the cleanup it owes. Do not run them casually.
- **`make app-test` does not build Go.** Run `make build` first or a stale `bin/` pin passes.
- **e2e fixture root must be `/tmp`, not `/private/tmp`**, or the isolation guard blames the app for children that are running fine.
- **Never approve the keychain dialog** during #301 work — that is the defect, not a step.
- **Suite flakes under load are not app defects.** Load, a locked screen, and Orca stealing its own keystrokes all read as app defects; read `acts.txt` before blaming anything.

---

## Phase 1 — Land what is still out

### Task 1: Merge #304 — the e2e fixture names the keychain

**Files:** branch `yehia-khalil/2e-301-keychain-selector` → `main`. Three commits: the fixture, the corrected probe, and the runbook note on why §3b stays as it is.

**Interfaces:**
- Consumes: the e2e harness on `main`.
- Produces: an e2e fixture that names its keychain, unblocking the agent checks that currently hang.

**Why this is first.** [#301](https://github.com/yehia-khalil/rafiq/issues/301) is *the e2e fixture's keychain shim cannot reach the shipped binary, and the agent checks hang on a login-keychain prompt*. **Cover cannot run while that hangs**, so this gates Task 3. #301 is a **decision record about keychain selection, not a patch** — read the PR body before touching the diff.

- [x] **Step 1: Read the PR and confirm it still applies to the merged build**

```bash
gh pr view 304 --comments
gh pr diff 304 --name-only
```

- [x] **Step 2: Check it out and run the suite against it**

```bash
git fetch origin && git checkout yehia-khalil/2e-301-keychain-selector
git rebase origin/main
make build && make test && make app-test
```
Expected: green. If red, the rebase surfaced drift — fix it here, not by skipping the PR.

- [x] **Step 3: Confirm the agent checks no longer hang**

```bash
make e2e 2>&1 | tail -40
```
Expected: no login-keychain prompt, no hang. **Do not approve the dialog if one appears** — that is the defect reproducing.

- [x] **Step 4: Merge**

```bash
gh pr merge 304 --squash --delete-branch
```

- [x] **Step 5: Close #301**

```bash
gh issue close 301 -c "Landed in #304 — the fixture names the keychain. The decision record is the PR body."
```

---

### Task 2: Merge #303 — 2e's machine walk, re-rendered against the merged build

**Files:** branch `yehia-khalil/2e-runbook-on-main` → `main`; target document `docs/wakil/phase-2e-acceptance.md`.

**Interfaces:**
- Consumes: the records `make e2e` left on the merged build.
- Produces: the runbook's machine half, between the two markers, replaced from real records.

**The machine half is rendered, and nothing writes it by hand.** `make e2e-runbook E2E_RUNBOOK=<the document>` replaces everything between the two markers from the records the runs left — which check ran, against which build, with what exit status and how many assertions, which were seen to fail against the merge-base, and what the coverage gate said.

```
<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
```

A runbook without those two lines is **refused** rather than guessed at.

- [x] **Step 1: Rebase onto main (which now has #304)**

```bash
git checkout yehia-khalil/2e-runbook-on-main && git rebase origin/main
```

- [x] **Step 2: Re-render against the merged build**

```bash
make build && make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2e-acceptance.md
git diff docs/wakil/phase-2e-acceptance.md
```
Expected: the machine half changes. **A red run renders too**, with the harness's own words — a generator that wrote nothing until everything was green would leave the document describing the last build that was.

- [x] **Step 3: Confirm no Result cell was pre-filled**

```bash
grep -n 'Result' docs/wakil/phase-2e-acceptance.md | head -20
```
Expected: every human-half **Result** cell still blank. *Only the operator walking the live app may fill one in — writing this document is not walking it.*

- [x] **Step 4: Merge**

```bash
gh pr merge 303 --squash --delete-branch
```

---

### Task 3: Close the seventeen stale stacked PRs

**Files:** none. This is tracker surgery.

**Why.** Every one of #209, #210, #218, #219, #220, #221, #223, #226, #227, #228, #229, #237, #239, #241, #245, #260, #272 has its head **already contained in `origin/main`** — verified with `git merge-base --is-ancestor`. They are the stack #297 collapsed and merged. Left open they are seventeen drafts that look like pending work and are not, which is a large part of what made the board unreadable. #218 additionally reports `CONFLICTING` against a base branch that no longer matters.

- [x] **Step 1: Re-verify containment before closing anything**

```bash
for b in 2e-196-action-classification 2e-197-journal-redaction 2e-198-settings-pane \
         2e-199-org-strings 2e-200-account-table 2e-201-adopt-copies-credential \
         2e-202-first-browser-trip 2e-204-the-mint 2e-205-repair-and-cancels \
         2e-206-unlink 2e-207-database-dsn 2e-236-providers-this-org \
         2e-238-sign-in-and-confirmations 2e-240-mint-on-a-terminal \
         2e-244-right-directory 2e-259-record-the-executable 2e-271-review-findings; do
  printf "%-38s " "$b"
  git merge-base --is-ancestor origin/yehia-khalil/$b origin/main \
    && echo "contained" || echo "NOT CONTAINED — STOP"
done
```
Expected: seventeen `contained`. **If any line says NOT CONTAINED, stop and do not close that PR.**

- [x] **Step 2: Close them, each saying where its content went**

```bash
for pr in 209 210 218 219 220 221 223 226 227 228 229 237 239 241 245 260 272; do
  gh pr close $pr -c "Closing stale: this branch's head is already contained in \`main\` via #297, which merged the whole 2e stack on 2026-09-26. Nothing here is unmerged — the PR is a duplicate view of work that landed. Reopen with \`gh pr reopen $pr\` if that turns out to be wrong."
done
```

- [x] **Step 3: Confirm the PR list is down to what is genuinely open**

```bash
gh pr list --state open
```
Expected: empty, or only PRs opened after this plan started.

---

## Phase 2 — Cover

### Task 4: Turn the Cover rung, for the first time

**Files:**
- Modify: `e2e/checks/seeded/2e-settings-*.jsonl` (five files already exist on main)
- Modify: `e2e/checks/uncoverable.tsv`
- Test: `make e2e-new`, `make e2e`

**Interfaces:**
- Consumes: the merged build, and #304's keychain fixture from Task 1.
- Produces: a Cover report naming only what it **could not** cover, which becomes the human half's input.

**This is the first time Cover is possible for 2e.** The runbook's own header records the blocker — *"2e has not been through Cover, because the e2e harness lives on `main` and this stack is not yet rebased onto it"* — and Tasks 1–2 removed it.

- [x] **Step 1: Run the auditor per `docs/agents/e2e.md`.** It reads the branch, writes the checks that cover what it touched, proves each one could fail, and reports only what it could not cover. The identifiers it must reach: the settings pane's doors, the account table, the organisation editor, the database form, the login band, the unlink report, `ctx_add_provider`, `ctx_adopt_provider`, `ctx_unlink_provider`, and the mint.

- [x] **Step 2: Prove failability**

```bash
make e2e-new
```
Expected: **red against the merge-base.** A check that cannot be seen to fail proves nothing.

- [x] **Step 3: Prove it passes**

```bash
make e2e
```
Expected: green.

- [x] **Step 4: Fold #269's one unmet criterion into the human half.** Seven of the eight absorbed tickets closed every criterion. #269's last one — *"Visually confirmed against the artboard by the operator"* — is unmet **and uncoverable by construction**: it is a visual ruling against `Settings.dc.html`, and its own ticket records why the agent could not do it (*"window-level accessibility stopped responding on the machine partway through"*). It is a **Walk** check, not a Cover one. Confirm the runbook's ten already carry it; add it if not.

Note for the walk: the artboard needs `support.js`, which is uncommitted — resolve the templating by hand and render with Playwright's headless Chromium. `.dc.html` is redrawn constantly, so fetch before citing a line.

- [x] **Step 5: Record what Cover could not reach** in `e2e/checks/uncoverable.tsv`, and commit.

```bash
git add e2e/ docs/wakil/phase-2e-acceptance.md
git commit -m "2e: the Cover rung, finally runnable now the stack is on main"
```

---

## Phase 3 — Walk and Record

### Task 5: The operator walks the ten

**The operator walks it. Never an agent.** This task is an agent handing over, and nothing else.

- [x] **Step 1: Re-render the machine half one last time against the final build**

```bash
make build && make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2e-acceptance.md
```

- [x] **Step 2: Confirm the human half is ten checks at most.** *Of everything this sub-phase claims, which ten would I most regret not having looked at?* If the document holds more, the **walk** is still the ten, and the rest is reference below a `## 0. The short walk` heading — which this document already has.

- [x] **Step 3: Hand over.** Name the three checks that create a real one-year credential at Anthropic (**3**, **4**, **7**) and the cleanup each owes, so the operator chooses a moment rather than discovering the cost halfway through — the same courtesy the pane itself owes its operator in story 4 of #89.

- [x] **Step 4: The operator walks it and marks each Result, dated.**

### Task 6: Record

- [x] **Step 1: Write the `phase-log.md` entry** — what the walk found, what it left unestablished, and **the shape of any mistake it caught**, not only the repair.

- [x] **Step 2: Fill `Met` in `north-star.md` §8.** The row is currently:

```
| **2e** | The settings pane — an account added from Wakil with no credential in the operator's hands; unlink; the DSN write; the residue named | — | the rest of 2c; **built before 2d** |
```

`Met` says **walked** or **accepted**, and the difference is the whole point of the column.

- [x] **Step 3: Close #89** — 2e's spec, and the second of the last two issues-as-spec.

- [x] **Step 4: Commit and push.**

---

## The residue #271 named, and where it goes

#271's *"Not addressed here"* is the honest tail of this sub-phase. **None of it blocks `Met`**, and all of it is now recorded here rather than in a closed ticket nobody re-reads:

| Residue | Disposition |
|---|---|
| The stripping contract is transcribed verbatim in Go and Swift with **no shared fixture** — a judgement call, left as a note for the next measurement | Spec input for whichever sub-phase next touches the mint. Not a ticket. |
| `SettingsPane.swift` is **1,819 lines** with ~10 injected closures | Real, and the largest view file in the repo after `TerminalPane.swift`. Split it when a change needs to, not before — and note that **WindowModel injectables default to `nil` and go unpassed**, which is the family #238 caught for the third time: tests inject fakes, so only running the app finds it. |
| **Editing a saved database** (operator, 2026-09-29): #327's form builds one connection string and stores it whole in the Keychain, so a saved database can be replaced but not edited, and nothing prefills. The operator chose **approach B, after 2e is walked**: host, port, user and database in plain text in `project.json`, only the password in the Keychain, and Go builds each driver's string at connect time, so EDIT prefills everything but the password | **The next spec to write** (`superpowers:brainstorming`), after 2e is `Met`. It changes `project.json`'s schema, `db_set_dsn`'s parameters and every driver's connect path. Not a ticket. |
| **The canvas on an account switch** (operator, 2026-09-29): a provider switch mints a new lineage, and layouts are filed per `(organisation, project, lineage)`, so the canvas swaps to the new conversation's arrangement. #335 carries only the settings pane across. The operator's ruling: **switching account keeps the whole canvas**; only which account runs changes | **A design pass after 2e** (`superpowers:brainstorming`). It amends the per-conversation layout rule (`LayoutScope`): what a new lineage inherits, and what the old one keeps on disk. `LayoutStore.carry` is the mechanism already in place. Not a ticket. |
| `credentialShaped` is a **byte-matching scrubber** on text that reaches the journal, which sits in tension with Decision 29's positional rule | A charter-level question. It belongs in a spec, not a bug. |

## Exit criterion

Two clauses, verbatim from [#89](https://github.com/yehia-khalil/rafiq/issues/89): the first is the pane itself; the second is

> every binding the pane draws has a credential the operator did not paste.
