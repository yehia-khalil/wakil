# Phase 2c-iii acceptance — the terminal pane

**Status:** Not yet walked. This runbook is written against the plan's own checks and
against the sub-phase's exit criterion; every **Result** cell below is left blank on
purpose. A runbook that pre-fills a result nobody has seen is worse than one that admits
it was never run, and only the operator walking the live app may fill one in — writing
this document is not walking it.

**Exit criterion, verbatim from the plan's Goal:** *"A real interactive shell runs on a
PTY inside a Wakil pane, the agent may read it and propose into it but never run in it,
`read_pane` returns both of the pane's surfaces as a union keyed by `kind`, and no shell
outlives the pane that opened it."*

## 0. The short walk — ten checks, and these are the walk

> **Walked 2026-09-18. All ten pass.**
>
> The walk found twenty-one defects, every one of them in `WakilApp` or its seam with
> `WakilKit` — none in the PTY, the mark scanner, the block model, the store or the mirror.
> Two of the twenty-one surfaced only on a **re-walk** of a build already declared fixed.
> `phase-log.md`'s 2026-09-18 entry records the shapes; `.superpowers/sdd/` holds the
> defect-by-defect catalogue.
>
> Check 10's write-confirmation Escape was, until this walk, the one defect that existed
> only as a *prediction* — inferred from the organisation plane's Escape and fixed at the
> root without ever being observed. It is now observed.

**Walk these ten. Everything below them is reference.**

This section exists because the long form did not get walked. Twenty-six checks were
written and the operator declined them on 2026-09-18 — correctly: an inventory is not a
plan for an afternoon, and a runbook nobody walks defends nothing. Ten is now the cap for
every runbook in this repo (`docs/agents/workflow.md`, the Runbook rung).

The ten are chosen on two grounds: what a test **cannot** see, and what broke **latest** in
the build. Four of them cover defects that were still live in the final week.

| # | Do | Pass | Stands for |
|---|---|---|---|
| 1 | **In the bundle** — `make app-bundle`, never a test run — open a pane, `echo $PATH`, `which brew` | Both find what they should | Check 3a |
| 2 | `ls` in a fresh pane | A block appears carrying its exit code and duration | Check 1 |
| 3 | Type a few characters **without** pressing Enter | You see them — echo, prompt, `PS1` | Checks 1, 6 |
| 4 | Ask the agent for a command; press `⏎` once, then again | First `⏎` puts it in your prompt **unrun**; the second runs it | Check 11 |
| 5 | `cat` with no argument, then `⌃C` | Returns to the prompt | Check 8 |
| 6 | `vim`, then `:q` | It takes the whole pane, and leaves a block behind carrying its duration | Check 7 |
| 7 | With `vim` still open, ask the agent what your last command printed | It answers — both surfaces readable at once | Check 15 |
| 8 | `tail -f` something, close the pane, then `ps` | No orphan process | Check 21 |
| 9 | Start a shell, switch organisation, then run a command in a new pane | The switch is not blocked, the old shell dies, **and the new run still appears in the journal** | Check 22, plus a clause added after the final review |
| 10 | Let the agent run a few `Bash` commands with a pane open | They appear recessed, marked *bare environment*, interleaved in time with yours rather than bunched | Check 16 |

**Why these ten and not others.** Items 3, 4, 7 and 9 each cover a defect that was live
until the final review: the pane had no live prompt at all, the two-Enter hand-off had no
keyboard path, `read_pane` returned an empty grid whenever the history was showing, and an
organisation switch silently stopped every later command being journalled. Item 1 is the
only check in this document that catches a class of defect no test can see, because a
bundled app inherits launchd's environment and a test run does not.

**What skipping the other sixteen leaves unestablished:** the visual rulings (violet
confined to the proposal, the mirror never lit, the hatch reading as texture), the
`⌘F`-counts-in-blocks distinction, resize cadence under a live drag, the stated scrollback
bound, `Propose rerun`, the backfill label, and the probe's drawing measurements re-run
against the shipped construction. None is a correctness claim the tests do not already
carry; all are things that surface in ordinary use.

## 1. Scope — what is under test, and what is not

Everything below is a consumer of **one mechanism**: a `terminal` pane owns one shell on
one PTY, opened at a path, carrying the active organisation's context and never the
agent's own reach. Checks 1–20 walk the shell itself, its four actions and `read_pane`'s
union; 21–24 walk the three teardown kill points and restore; 25 walks the six doc
comments the sub-phase's own exit clause names; 26 re-runs two of the probe's drawing
measurements against the shipped construction rather than the harness that predicted it;
27 records a known partial rather than a pass/fail question.

**Not under test here:**

- 2c-iv (API client pane) and the cut 2c-v (session browser) — different sub-phases.
- **`term_rerun` of an enumerated block, and an operator-marked rerunnable block.**
  Deferred by the plan, not refused — the friction of "propose, then run" was left
  unmeasured against a pane that did not yet exist.
- **Tabs, a session selector, per-pane shell multiplexing, roots in any form, cross-pane
  value binding.** Out of scope by the plan's own self-review.
- **Persisting the block history across a relaunch.** Check 24 exists precisely because
  this is *not* built — a restored pane comes back with no shell and no history.
- **Shells other than zsh and bash.** Check 5 covers the refusal of anything else, not
  support for it.
- **Window-close teardown** ([#56](https://github.com/yehia-khalil/rafiq/issues/56)) —
  a separate, still-open item; only pane close, org switch and app quit are this
  sub-phase's three kill points.
- **Signing and notarisation of a hardened app spawning a PTY** (2b-vii) — externally
  blocked, unrelated to this pane's own correctness.
- **An agent-reachable run, in any form.** Check 14 walks the *refusal*; a `term_run` the
  agent can dispatch itself is not a partial version of this sub-phase, it is the thing
  Invariant 6's terminal refusal exists to prevent.

### 1.1 Prerequisites

Skipping one of these does not make a check fail cleanly — it makes it fail for the
wrong reason, which is worse than not running it.

1. **`make build` and `make app-bundle`, both**, in that order, on a worktree that has
   never run them — `bin/` and `default.metallib` are per-worktree. `make app-bundle` is
   not optional here the way it has been for prior DB-pane runbooks: **check 3a can only
   be walked against the bundle**, never against a `swift test` run or an Xcode debug
   launch, both of which inherit a terminal's already-correct `PATH`.
2. **An org, a project, and an environment**, launched with
   `WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil` per `phase-2a-acceptance.md` §1.
3. **A project with at least one root outside `/tmp`**, for check 4's "outside every
   project root" to mean something — `/usr/lib` is a safe, always-present path for it.
4. **`kubectl` and `brew` installed under the operator's own login shell**, specifically
   for check 3a — a machine with neither cannot fail that check informatively; substitute
   any two binaries the operator's shell profile puts on `PATH` but a bare `-i` shell
   would not.
5. **A way to ask the agent to act**, for checks 11–19 and 26's mirror-adjacent checks —
   spoken or typed, not driven by hand and described as if it had been.
6. **The journal**, for reading a `term_run` entry's `accepted` field during checks 11
   and 12 — know where it lives (`~/.wakil`) before starting.
7. **`ps -ax`, and the sweep command below**, read before opening a single pane — see
   §1.2. A run interrupted partway through this walk leaves orphaned shells behind in
   exactly the way it does for `make app-test`.

### 1.2 Note for whoever runs the terminal tests, or this walk

**An interrupted run — of `make app-test`, or of this walk itself — orphans every shell
it had open.** Teardown for a terminal pane's shell runs when the owning process exits
*normally*; a killed test runner or a force-quit `Wakil.app` never reaches it. Each
orphan reparents to `init` (ppid 1) and holds its pty open indefinitely — this sub-phase's
own build hit 70 of them across roughly three interrupted runs during Task 7's fix round,
which independently wedged a later gate run (see `phase-log.md`'s entry for this build).

The sweep, run whenever a walk or a test run was interrupted rather than exited cleanly:

```
ps -ax -o pid=,ppid=,command= | awk '$2==1' | grep -E "wakil-terminal-|/bin/zsh -il$" | awk '{print $1}' | xargs -r kill -9
```

It matches by `ppid==1` together with either the per-session `wakil-terminal-<UUID>` rc
path or a bare `/bin/zsh -il`, so it will not touch the operator's own ordinary shells,
which have real parents. Run it, then confirm with a bare `ps -ax | grep wakil-terminal`
that nothing remains, before starting or resuming a walk.

## 2. The checks

Nothing here is marked **Pass**. Each check is written for the operator to walk at the
window; the **Result** row is left blank — see the Status line above for why.

### Check 1 — a real shell runs in the pane

**Do:** ⌘K → `term_open` at a path. **Pass looks like:** the shell's own prompt appears
in the **live region** at the foot of the pane, the characters you type echo into it as
you type them, and pressing `⏎` on `ls` produces a block above it carrying an exit code
and a duration. **Leaves unestablished:** whether the same holds for a path the operator
did not choose — check 4 covers that.

**Note added by the final fix wave.** Until it, this check was not walkable as written:
the blocks surface drew the history alone under a static grey "live prompt" label and
published `grid: []`, so there was no prompt, no echo, and nothing at all on screen while
a command ran. The live region — the visible screen, trimmed to its live rows, drawn
beneath the history — is what makes "the shell's prompt appears" a thing an operator can
actually see.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 2 — the header carries the live cwd

**Do:** in the open shell, `cd /usr/lib`. **Pass looks like:** the pane's header follows
the shell's own idea of its directory, parsed from the raw `file://` URL `hostCurrentDirectory`
returns rather than shown as one. **Leaves unestablished:** whether a `cd` issued by a
full-screen program (rather than typed at the prompt) is tracked the same way — not
attempted here.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 3 — the shell carries the context

**Do:** `echo $WAKIL_ORG $WAKIL_PROJECT $WAKIL_ENVIRONMENT`. **Pass looks like:** all
three match the window's active context. **Leaves unestablished:** whether they follow a
later context switch without closing and reopening the pane — they do not, and cannot: an
environment is handed to a process once, at `execve`. A pane opened AFTER a switch
carries the new context (the window is asked on every `term_open`); a pane opened before
it keeps what its shell was launched with.

**Note added by the final fix wave.** None of the three was exported at all until it —
`terminalActions`' `activeContext:` defaulted to always-empty and no call site overrode
it. **`WAKIL_ORG` was still inherited from Wakil's own process environment**, so a walk
done before the fix could have seen the org apparently correct with the other two empty,
and gone looking in the wrong place. If this check fails now, all three fail together.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 3a — a usable `PATH`, walked in the bundle only

**Do:** in the **bundled** app (`make app-bundle`, never a `swift test` run or a debug
launch from Xcode), open a terminal pane and run `echo $PATH`, `which kubectl`, `which
brew`. **Pass looks like:** `PATH` includes the operator's usual login-shell entries
(typically `/opt/homebrew/bin` or `/usr/local/bin` among them), and both `which` calls
resolve to a real path rather than printing nothing. **Why this check exists and the
others do not substitute for it:** a bundled app inherits `launchd`'s environment, not a
terminal's, so a shell spawned `-i` instead of `-il` — or a login-shell flag that is
present but whose rc silently fails to source the operator's profile chain — produces a
shell that cannot find `kubectl` or `brew` while every one of this sub-phase's ~890 unit
tests keeps passing, because `swift test` itself runs from a shell whose `PATH` is
already correct. This is the one check in this runbook that a green test suite cannot
stand in for. **Leaves unestablished:** correctness on a machine whose login shell is
neither bash nor zsh, or whose profile chain is unusually shaped — walked here only
against the operator's own machine.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 4 — a path outside every project root is accepted silently

**Do:** `term_open` at `/usr/lib`. **Pass looks like:** no refusal, no chip, no banner —
the shell simply opens there. **Leaves unestablished:** nothing further; this is the
whole claim.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 5 — an unsupported shell is refused with a reason

**Do:** `term_open` naming `/bin/fish`. **Pass looks like:** the refusal message names
both the shell it was asked for and the reason (only zsh and bash are supported). **Leaves
unestablished:** whether every shell binary that exists but is not zsh or bash produces
the same wording — only `/bin/fish` is walked.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 6 — readline, tab completion and `⌃R` work

**Do:** type a partial path and press Tab; separately, press `⌃R` and search reverse
history. **Pass looks like:** completion offers or fills a real path; `⌃R` enters
incremental search and finds a prior command. **Leaves unestablished:** behaviour under a
shell configuration other than the operator's own (a custom completion framework, a
non-default `bindkey` table).

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 7 — a full-screen program takes the whole pane

**Do:** run `vim`, then `:q`. **Pass looks like:** while `vim` runs the pane shows the
live grid, not a growing block history; on `:q` the block `vim` produced carries its
command, its duration and its exit code. **Leaves unestablished:** whether every
full-screen program's alternate-screen mode is recognised — only modes 47/1047/1049 are
detected (vim, less, tmux, htop, `mc`, `man`), which the build recorded as the complete
practical set but not a proven-complete one.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 8 — `^C` reaches the foreground program

**Do:** run `cat` with no argument, then press `⌃C`. **Pass looks like:** `cat` exits
rather than the pane hanging or the keystroke being swallowed. **Leaves unestablished:**
job-control signals beyond `^C` — `^Z`, `^\` — which this check does not exercise.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 9 — resizing the pane resizes the shell

**Do:** with `vim` open, drag the pane wider. **Pass looks like:** `vim` redraws at the
new width and the header's reported dimensions follow. **Leaves unestablished:** a resize
so extreme it changes wrapping mid-command in a way that could desynchronise the block
scanner — not attempted.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 10 — `⌘F` counts in blocks

**Do:** search the pane's history with `⌘F`. **Pass looks like:** the match count reads
in blocks, not lines — a term appearing three times inside one block's output counts as
one match, matching what the runbook's own building blocks assert at the unit level.
**Leaves unestablished:** search across a truncated (200-block-capped) history — whether
the operator is told the search did not reach further back.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 11 — the agent proposes and only your Enter runs it

**Do:** ask the agent for a command. **Pass looks like:** a dashed block appears at the
tail of the history, directly above the live region; the first `⏎` places its text in the
shell's own prompt **unrun** — the bytes are visible in the live region, no newline was
sent, no block yet — and the dashed block disappears; a second `⏎` runs it, and the
journal's `term_run` entry for it reads `accepted: "proposed"`. **Leaves unestablished:**
nothing large — this is the two-Enter design's central claim and the one this runbook is
least willing to accept without a walk.

**Note added by the final fix wave.** "Bytes visible" was not observable before it, for
the reason Check 1 records: an accepted proposal was written into a prompt nothing drew.
The step is now walkable exactly as written.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 12 — a replacement proposal cannot swap under your hand

**Do:** ask the agent for a second command while the first proposal is still pending.
**Pass looks like:** exactly one proposal is visible at any time, and the journal shows
two separate `term_propose` lines rather than one overwritten silently. **Leaves
unestablished:** the operator's felt experience of which proposal "won" — only the
journal and the visible state are checked here.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 13 — `⌫` discards

**Do:** with a proposal pending, press `⌫`. **Pass looks like:** the dashed block is
gone and nothing was written to the shell — the prompt is exactly as it was. **Leaves
unestablished:** nothing further.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 14 — the agent cannot run

**Do:** ask the agent to run something in an open terminal pane. **Pass looks like:** the
denial names *this* refusal specifically and points at `term_propose` as the reachable
alternative — not a generic permission-denied message, and not wording that would equally
satisfy a different refusal family (the credential-boundary refusal says "credential
boundary" singular; this one says "credentials" plural — the two must not be
interchangeable in the operator's reading either). **Leaves unestablished:** nothing
further; this is Invariant 6's terminal refusal in full.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 15 — `read_pane` returns both surfaces

**Do:** with `vim` open, ask the agent what the last build printed. **Pass looks like:**
the agent answers from `blocks` (the sealed history from before `vim` took the screen)
while a `screen` field separately reports `grid` for the live surface — a union keyed by
`kind`, not one flattened shape. **Leaves unestablished:** whether the agent's own
synthesis of the two surfaces is *useful*, which is a model-behaviour question outside
this runbook's scope; only the shape of what it was given is checked here.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 16 — the mirror

**Do:** give the agent a task that runs `Bash`. **Pass looks like:** the commands appear
recessed in **every** open terminal pane, each labelled with where it ran and *bare
environment* — never drawn lit, the way an operator's own block is. A still-running one
shows a chip and an elapsed counter, never a progress bar (there is nothing to bar: the
result arrives whole, not streamed). **Leaves unestablished:** whether the mirror reaches
a pane opened *after* the agent's command already started — check 17 is the backfill case
for that.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 17 — the mirror is backfilled

**Do:** let the agent work, unobserved, then open a terminal pane. **Pass looks like:**
its commands are already there, explicitly marked backfilled rather than presented as if
they had streamed in live. **Leaves unestablished:** the marker's exact wording is not
prescribed here — only that one exists and is visibly distinct from a live mirrored
block.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 18 — the mirror pauses under a full-screen program

**Do:** open `vim` in a pane while the agent works. **Pass looks like:** no foreign rows
appear in the live grid while `vim` holds the screen, and every one of the agent's
commands from that window is present, in order, once `vim` exits. **Leaves
unestablished:** the precise moment a very long-running agent command surfaces relative
to `vim`'s exit — only presence and order are checked, not latency.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 19 — `Propose rerun`

**Do:** use a mirrored block's rerun affordance. **Pass looks like:** it proposes the
command (a dashed block, per check 11's shape) rather than running it directly — the
mirror gets no privilege the operator's own typing does not have. **Leaves
unestablished:** nothing further.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 20 — the bound is stated

**Do:** fill a pane's history past its cap. **Pass looks like:** the footer names both
the block cap and the line-per-block cap, and says once the history has actually been
trimmed — not merely that a cap exists. **Leaves unestablished:** the exact cap numbers
are a memory-budget decision recorded in the plan (200 blocks × 500 lines, ~18 MB) and
are not re-derived here; this check only confirms the footer is honest about them.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 21 — teardown, pane close

**Do:** start `tail -f` in a pane, then close the pane. **Pass looks like:** `ps` shows
no process still running the killed shell or its children — no orphan. **Leaves
unestablished:** a shell that has backgrounded a job into its own process group under
heavy load; the build's own regression coverage for the process-group sweep is the
stronger evidence for that case, this check is the operator-visible confirmation of the
same property.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 22 — teardown, org switch

**Do:** start `tail -f`, then switch organisation. **Pass looks like:** the pane vanishes
along with every other pane on the canvas, the switch itself is not blocked or visibly
delayed by it, and `ps` shows no orphan afterward. **Leaves unestablished:** timing under
a shell that is slow to die (the build bounded this at a 2-second drain deadline
internally; what this check confirms is the operator-visible outcome, not the internal
budget).

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 23 — teardown, quit

**Do:** open two panes, each with a live shell, then quit the app. **Pass looks like:**
`ps` shows no orphans from either shell after the app has fully exited. **Leaves
unestablished:** nothing further; this is the third and last of the three kill points.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 24 — a restored pane comes back empty

**Do:** relaunch the app after quitting with a terminal pane on the canvas. **Pass looks
like:** the pane itself is restored (its position, its kind) but with no shell and no
block history — it is genuinely awaiting a fresh `term_open`, not silently reconnecting
to a resurrected process. **Leaves unestablished:** nothing further; persisting block
history across a relaunch is explicitly out of scope (§1).

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 25 — the six doc comments

**Do:** read each of the six symbols this sub-phase's exit criterion names, against the
code beside it: `ActionKind.mutate`, `PaneStore.swift:368`, `MCPServer.swift:233`,
`MCPServer.swift:687`, `autoResumeAfterSwitch`, and `WriteGate.swift`'s table. **Pass
looks like:** each one, read today, describes what the code beside it actually does — no
self-contradiction, no falsified justification. **Leaves unestablished:** whether a
*future* change to the code re-falsifies one of them; this check is a point-in-time
confirmation, not a standing guarantee. `autoResumeAfterSwitch`'s comment was rewritten
as part of this same task (Task 17) — the paragraph that used to say the palette's
collapse hides what the method wants, then refuted itself by naming the newest member of
a chain (exactly what the collapse keeps) as what a return visit should continue. It now
says the raw rows are read for their *fields* (`PaletteItem` carries no `provider`, no
`cwd`), and that the collapse and the method actually agree.

| Result | Date | Notes |
|---|---|---|
| | | |

### Check 26 — the probe's drawing measurements, re-run against the real pane

**Do:** re-run measurements 5 (the live grid, construction B — one `Text` per row) and 6
(the block history list) from `docs/wakil/phase-2c-iii-probe.md` against the *shipped*
pane, not the offscreen-window harness `scripts/probe/termspike` used to predict it —
which is why that harness was kept in the tree rather than deleted once the pane shipped.
**Pass looks like:** the real pane holds 120fps on the live grid at its own window size,
and the block history's first layout and scroll step stay in the range the probe
predicted (first layout in the tens of milliseconds, scroll step around 5 ms, flat as the
history grows) — not merely that the app feels responsive. **Leaves unestablished:**
several scrolling grids at once over the animating Metal layer, which neither the probe
nor this check measures (recorded as unmeasured on purpose in `phase-2c-ii-acceptance.md`
§1 and true again here).

| Result | Date | Notes |
|---|---|---|
| | | |

## 3. Known partials

Stated here as partials, not omitted and not silently discovered mid-walk.

**"Send to thread" on a block copies a fenced quote to the pasteboard rather than
reaching a compose field.** No compose hook exists yet for the thought thread to receive
a routed value — Decision 20's bound-values mechanism is a DB-pane feature today, not a
terminal one. An operator using this affordance gets a pasteboard-ready fenced quote of
the block's command and output, which they can paste themselves; they do not get it
inserted into a running conversation automatically. This is not a defect to be found on
the walk — it is recorded here so the walk does not spend a check rediscovering it.

## 4. Verification

**Not run as part of writing this document.** Per this task's own constraints, no build
or test command was run to produce this runbook — `make app-test`, `make test` and
`make app-build` are the controller's to run, per the plan's own Step 4. This section is
deliberately left without pasted output; filling it in is part of walking this runbook,
not writing it.
