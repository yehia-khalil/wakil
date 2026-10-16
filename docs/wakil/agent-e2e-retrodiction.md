# Retrodiction — can the e2e harness see the defects it was built for?

**Run 2026-09-23.** The acceptance criterion for the agent-run e2e harness
([#246](https://github.com/yehia-khalil/rafiq/issues/246) §"Acceptance criterion",
[#253](https://github.com/yehia-khalil/rafiq/issues/253)), answered before any effort
goes into the agent stub and beyond.

**Verdict: the harness catches all six of 2c-iii's defect shapes that can be put back,
and it caught a hole in its own vocabulary on the way.** Two of the seven checks cover
claims the walk found no defect in, so they have nothing to retrodict and say so.

Re-run it with `make e2e-retrodict`. The machine-readable record is
`.context/e2e/retrodiction/latest.json`.

## 1. The builds that carried the defects do not exist

2c-iii was **squash-merged** — `84de6f6`, one commit, parent `3bc0d1f` — so the branch's
own commits are gone from every ref in this repository. `git log -- TerminalPane.swift`
returns two commits, the squash and #250's identifier sweep, and no branch contains
anything between them. The twenty-one defects the walk found were fixed *inside* that
branch, and nothing on disk carries any of them.

So the criterion as written — *"each is run against the build that carried its defect"* —
cannot be met literally. Two things were tried instead.

### The cheap one, and why it proves nothing

Run all seven against `3bc0d1f`, the last build before the terminal pane existed. All
seven go red. The verdict record says why:

```
2c-iii-1-bundle-path.jsonl  -> step 2: axresolve: not_found: landing.row.open:terminal
2c-iii-2-block.jsonl        -> step 1: axresolve: not_found: landing.row.open:terminal
2c-iii-3-live-prompt.jsonl  -> step 1: axresolve: not_found: landing.row.open:terminal
…
```

Seven reds, one cause, and the cause is that `landing.row.open:terminal` was added by
[#250](https://github.com/yehia-khalil/rafiq/issues/250) three days ago. **This is
evidence about #250, not about 2c-iii.** It would read as a clean pass in any summary
that counted reds instead of reading them, which is the shape of silent success this
harness exists to refuse — so it is recorded here as a non-result rather than as the
answer.

It is kept as `make e2e-new E2E_NEW_ARGS='--base 3bc0d1f <checks>'` (the flag reaches the
binary only through that variable), because it does establish one thing: none of the seven
passes against a build with no terminal pane. §5 has the run for checks 2 and 4, which is
the only evidence those two have.

### The one that answers the question

**Put the defect back.** For each shape the repo records precisely enough to reconstruct,
a patch under `e2e/retrodiction/` removes one line whose absence is recorded *in the
repo's own words* as having caused it. The bundle is rebuilt with that line gone, and the
check that covers it must go red.

This is source mutation, which `make e2e-new` deliberately rejected, and the difference is
worth stating plainly: `e2e-new` is a standing gate on every branch, where a rebuild per
check is unaffordable. This runs once, when the harness itself is in question, and there is
no other instrument that can answer that question.

**What keeps it honest:** every case cites where the repo records the defect (a unit test
enforces that the citation is non-empty), and a patch that writes outside `app/Sources/`,
or writes nothing at all, is **refused before anything is built** — a reconstruction that
edited the harness would be measuring the harness against itself, and one that reconstructs
nothing would run its check against an unmodified build and report BLIND, sending a reader
to the check instead of to the patch. That refusal replaced a `git apply --include` filter,
which was measured to exit 0 and silently apply nothing instead of refusing.

## 2. The six, and what each check saw

| # | Defect put back | Recorded in | Check | Saw it |
|---|---|---|---|---|
| 1 | The pane's shell cannot find anything the operator's profile puts on `PATH` | `ShellIntegration.swift`: *"Without this, `which kubectl` fails in Wakil.app and succeeds in every test"* | 1 — bundle PATH | **yes**, on `blocks[-1].output` |
| 2 | The pane had no live prompt at all — the view kept passing `nil` | `phase-log.md` 2026-09-18, *"two correct halves and no join"* | 3 — live prompt | **yes**, after the fix in §3 |
| 3 | The operator typed blind: `grid` published `[]` whenever the history was showing | `TerminalStore.swift`, final review Critical 2 | 3 — live prompt | **yes**, on `grid` |
| 4 | A full-screen program does not take the pane | `TerminalSnapshot.screen`; runbook check 7 | 5 — full screen | **yes**, on `screen` |
| 5 | An organisation switch silently stopped every later command being journalled | `phase-log.md` 2026-09-18; runbook item 9's post-review clause | 7 — org switch | **yes**, `30 entries read`, none of them the run |
| 6 | A closed pane leaves its shell running | runbook check 21; `TerminalStore.close` | 6 — no orphan | **yes**, on the process table |

Cases 5 and 6 are marked `Reconstructed` in the table the runner reads: their **original
cause** did not survive the squash merge, so the patch reproduces the **observable** — the
journal stops receiving entries once a switch has happened; a pane closes without killing
its shell — rather than the cause. A check that sees the observable would have seen the
defect; it is a weaker claim than cases 1–4 and is carried as one.

**Case 5's first draft was weaker still, and the review caught it.** It returned early when
the org id ended `-two`, which is `SeedSpec.second()`'s own suffix — the mutation was written
against the fixture, so check 7's red was guaranteed by construction rather than earned. It
now sets a flag inside `switchOrg`, which is the event the walk actually found, and knows
nothing about the check that has to catch it.

## 3. What the retrodiction and the reviews found in the harness

**Four vacuous assertions, in the thing built to refuse them.** Three were found by review
after the retrodiction found the first, and every one had the same shape: an assertion that
could not fail, sitting in a green check.


**Case 2 failed the first time: check 3 passed with the live prompt removed.**

The defect put back was `promptRow: nil, cursorRow: nil, cursorCol: nil` — the shape the
phase-log records. Check 3 asserted `promptRow` was `present`, and `present` asked only
whether the path **resolved**. `PaneSnapshot`'s own rule is that every key of the answered
kind is always there, *"including when false, empty or null"* — so against this wire shape
the predicate could never fail. It was vacuous by construction, and the one thing it was
written to catch was exactly what it could not see.

`present: true` now refuses an explicit null, and says so in those words. A check that does
want *"the key is there holding null"* writes `equals: "null"`, which stays expressible.

**This is the return on running the retrodiction at all.** The check was green, the
vocabulary looked sound, and both were wrong in a way no amount of reading would have
surfaced. It is the same lesson as the walk that produced these seven: an instrument is not
proven by the things it reports, only by the things it is made to miss.

**The other three, found by review.**

- **`present: false` could not fail on a misspelled path.** It is satisfied by any path that
  does not resolve, and a typo does not resolve — so `blcoks[-1].exitCode` passed against
  every build, having looked at nothing. Parse-time grammar checking narrowed it and could
  never close it, because a typo is grammatically a perfectly good name. It now requires the
  path's **container** to resolve, which is the part a check author cannot get wrong without
  saying something false about the shape of the snapshot.
- **`present: false` certified an unverified act.** `Confirms` asked only whether a pane was
  named, so the negative predicate cleared a pending act exactly as a positive read would —
  the same vacuity the function's own doc comment rejects for `tree: absent`.
- **The first reconstruction of case 5 was written against the fixture.** It returned early
  when the org id ended `-two`, which is the seed's own suffix, so check 7's red was
  guaranteed by construction rather than earned.

**And one that was not vacuous but circular:** the backfill list redirected even checks named
explicitly on the command line, so the very command the list cites as where checks 2 and 4
were seen to fail redirected all seven and ran nothing. Those two entries pointed at evidence
the mechanism itself had made unreproducible.

## 4. What is not retrodicted, and why

**Checks 2 (`ls` → a block with its exit code and duration) and 4 (`cat`, then `⌃C`) have
no defect of their own to put back.** The phase-log is explicit that of the twenty-one
defects, **none** was in the PTY, the mark scanner, the block model, the store or the
mirror — *"the 954 tests were telling the truth about what they covered"*. There is no
recorded shape to reconstruct for either, and inventing a mutation for them would measure
the mutation.

Both are still worth having: they are the two checks that fail first and most cheaply when
the shell integration breaks at all, and both go red against `3bc0d1f`.

**Three of 2c-iii's ten remain outside this harness entirely**, unchanged from what #246
said at the start: the two that need a deterministic agent (the two-`⏎` hand-off, both
surfaces readable while `vim` is open) wait on the agent stub, and item 10 — agent runs
reading as *recessed* and *interleaved rather than bunched* — is half visual and stays the
operator's permanently.

## 5. The runs, as they printed

Recorded here because the machine-readable verdicts land under `.context/`, which is
gitignored — a claim with nothing committed behind it is the shape this document spends
its length refusing. **Abridged, not rewritten:** the per-launch chatter (seeding,
staging, pid, socket, evidence path) is elided; every line below is copied from the run.

### `make e2e-retrodict` — the six defects put back

```
wakil-e2e-retrodict: 1-profile-never-sourced — the pane's shell cannot find anything the operator's profile puts on PATH
wakil-e2e-retrodict:   recorded at ShellIntegration.swift: "Without this, `which kubectl` fails in Wakil.app and succeeds in every test"
wakil-e2e-retrodict:   SAW IT: 2c-iii-1-bundle-path.jsonl step 7: pane "terminal-1" field "blocks[-1].output" does not contain "profile-bin"; it holds ["/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/pkg/env/global/bin:/Library/Apple/usr/bin:/var/folders/0h/97h9cspn7vv3l2pl6g5r07h80000gn/T/wakil-e2e1712141575/bin","%                                                                               "," "] (still true after waiting 3s)
wakil-e2e-retrodict: 2-no-live-prompt — the pane had no live prompt at all — the view kept passing nil
wakil-e2e-retrodict:   recorded at phase-log.md 2026-09-18, "two correct halves and no join"; TerminalSnapshot.promptRow
wakil-e2e-retrodict:   SAW IT: 2c-iii-3-live-prompt.jsonl step 3: pane "terminal-1" field "promptRow" is null — the key is there and holds nothing, which is what a field nothing publishes looks like (still true after waiting 3s)
wakil-e2e-retrodict: 3-grid-empty-on-the-block-surface — the operator typed blind: grid published [] whenever the history was showing
wakil-e2e-retrodict:   recorded at TerminalStore.swift, final review Critical 2
wakil-e2e-retrodict:   SAW IT: 2c-iii-3-live-prompt.jsonl step 5: pane "terminal-1" field "grid" does not contain "% echo not-run-yet"; it holds [] (still true after waiting 3s)
wakil-e2e-retrodict: 4-full-screen-never-takes-the-pane — a full-screen program does not take the pane
wakil-e2e-retrodict:   recorded at TerminalSnapshot.screen; runbook check 7
wakil-e2e-retrodict:   SAW IT: 2c-iii-5-full-screen.jsonl step 6: pane "terminal-1" field "screen" is "blocks", want "grid" (still true after waiting 3s)
wakil-e2e-retrodict: 5-switch-stops-the-journal — an organisation switch silently stopped every later command being journalled
wakil-e2e-retrodict:   recorded at phase-log.md 2026-09-18; runbook item 9's clause added after the final review
wakil-e2e-retrodict:   SAW IT: 2c-iii-7-org-switch.jsonl step 15: no journal entry carries "echo after-the-switch" (30 entries read) (still true after waiting 3s)
wakil-e2e-retrodict: 6-pane-close-leaves-an-orphan — a closed pane leaves its shell running
wakil-e2e-retrodict:   recorded at runbook check 21; TerminalStore.close
wakil-e2e-retrodict:   SAW IT: 2c-iii-6-no-orphan.jsonl step 9: 1 process(es) matching "tail -f wakil-e2e-orphan-marker" survived: 19443 tail -f wakil-e2e-orphan-marker (still true after waiting 3s)
wakil-e2e-retrodict: recorded at .context/e2e/retrodiction/20260924-060307/verdict.json
wakil-e2e-retrodict: all 6 reconstructed defect(s) were caught
```

### `make e2e` — the green half, ten checks, one launch each

```
== e2e/checks/unseeded/org-plane.jsonl (organisation plane)
wakil-e2e: 1 check(s), 3 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/2c-iii-1-bundle-path.jsonl (seeded)
wakil-e2e: 1 check(s), 8 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/2c-iii-2-block.jsonl (seeded)
wakil-e2e: 1 check(s), 7 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/2c-iii-3-live-prompt.jsonl (seeded)
wakil-e2e: 1 check(s), 7 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/2c-iii-4-interrupt.jsonl (seeded)
wakil-e2e: 1 check(s), 8 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/2c-iii-5-full-screen.jsonl (seeded)
wakil-e2e: 1 check(s), 7 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/2c-iii-6-no-orphan.jsonl (seeded)
wakil-e2e: 1 check(s), 5 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/2c-iii-7-org-switch.jsonl (seeded)
wakil-e2e: 1 check(s), 8 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/landing.jsonl (seeded)
wakil-e2e: 1 check(s), 5 assertion(s)
wakil-e2e: all checks passed
== e2e/checks/seeded/vocabulary.jsonl (seeded)
wakil-e2e: 1 check(s), 6 assertion(s)
wakil-e2e: all checks passed
```

### `make e2e-new` — both halves of #252

Diff-derived, on this branch: all seven are backfill, so the merge-base cannot prove them
and each names where it was proved instead.

```
wakil-e2e-new: BACKFILL: e2e/checks/seeded/2c-iii-1-bundle-path.jsonl — seen to fail by make e2e-retrodict: 1-profile-never-sourced
wakil-e2e-new: BACKFILL: e2e/checks/seeded/2c-iii-2-block.jsonl — seen to fail by make e2e-new E2E_NEW_ARGS='--base 3bc0d1f': red, on a build with no terminal pane
wakil-e2e-new: BACKFILL: e2e/checks/seeded/2c-iii-3-live-prompt.jsonl — seen to fail by make e2e-retrodict: 2-no-live-prompt
wakil-e2e-new: BACKFILL: e2e/checks/seeded/2c-iii-4-interrupt.jsonl — seen to fail by make e2e-new E2E_NEW_ARGS='--base 3bc0d1f': red, on a build with no terminal pane
wakil-e2e-new: BACKFILL: e2e/checks/seeded/2c-iii-5-full-screen.jsonl — seen to fail by make e2e-retrodict: 4-full-screen-never-takes-the-pane
wakil-e2e-new: BACKFILL: e2e/checks/seeded/2c-iii-6-no-orphan.jsonl — seen to fail by make e2e-retrodict: 6-pane-close-leaves-an-orphan
wakil-e2e-new: BACKFILL: e2e/checks/seeded/2c-iii-7-org-switch.jsonl — seen to fail by make e2e-retrodict: 5-switch-stops-the-journal
wakil-e2e-new: all 7 new check(s) are backfill: they cover surface that already existed at 5776ac02632d, so the merge-base cannot prove them failable and each names where it was
```

And the explicit-base run that `backfill.tsv` cites for checks 2 and 4 — the one a review
found the backfill filter had made unreproducible, by redirecting even checks named on the
command line:

```
wakil-e2e-new: 2 check(s) to prove since 3bc0d1f, in 2 launch(es)
wakil-e2e-new:   2c-iii-2-block.jsonl                     red, as required
wakil-e2e-new:   2c-iii-4-interrupt.jsonl                 red, as required
wakil-e2e-new: all 2 new check(s) went red against 3bc0d1f, so each of them tests something that build did not have
```

**The AX grant went stale twice during these runs** (`orca computer permissions` reports
`granted` while every read returns `permission_denied`; it needs Orca Computer Use toggled
off and on in System Settings). Both times the harness reported it as a **run** failure and
not as a red — which is the guard working: with a defect deliberately back in the build,
everything going red because the harness could not reach the window is the easiest possible
false pass.

**And a race the first green runs got lucky on.** Keystrokes are refused outright unless the
fixture window is frontmost, and an app started with `open -n` does not reliably become so:
a later run refused twelve acts with `window_not_focused` in a check that had passed a dozen
times. Orca's own `--restore-window` was not enough on its own. The session now activates the
instance by pid through System Events before any check runs, and a keystroke refused for
focus is delivered once more after re-activating — which is **not** the retry this harness
forbids: that one re-runs a check until it goes green, while this re-runs an act whose
refusal says it was never delivered at all, so there is no observation to launder.

## 6. The verdict

**The harness is proven for the class it was built for.** Six defect shapes drawn from
2c-iii's twenty-one, each put back one line at a time, each caught by the check written for
it — one of them only after the retrodiction exposed a predicate that could not fail.

Against 2c-iii's ten: seven mechanized and green, six of those seven demonstrated against
their own defect, two awaiting the agent stub, one permanently the operator's.

Work on the agent stub ([#255](https://github.com/yehia-khalil/rafiq/issues/255)) and
beyond may proceed.
