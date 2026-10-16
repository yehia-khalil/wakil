# Phase 2b-viii acceptance — the org switch

**Status:** **WALKED AND MET, 2026-09-15.** All fifteen checks driven against the live
app by the operator, every one passing on the bundle built from `fa06406`.

Getting there took three passes and turned up **nine defects the test suite could not
see**, which is the entire argument for walking a runbook rather than writing one:

- **Pass 1 — five presentation rulings** that did not survive contact (§8.1.1 display
  names, §8.4.1 the editable adopt id, §8.6.1 a row's primary action), all of them mine
  rather than the operator's misreading.
- **Pass 2 — two correctness bugs in `WakilKit`** that fifteen task reviews and a
  whole-branch review had all passed over (§6.3, a launch into an org with no active
  project opening org-less; §5.4, a restored canvas never re-running its subjects), plus
  §8.4.2, adoption never naming the credential step.
- **Pass 3 — two regressions introduced by pass 2's own fixes** (§8.5's Escape collision,
  where the org plane and the confirmation plane both claimed `.cancelAction`; and error
  wording, where five error types were showing the operator their Swift case names).

The last of those is worth recording as a class rather than an incident: it was found
three separate times, in three different surfaces, because nothing tested what an error
*reads like*. `noOperatorFacingErrorPrintsItsSwiftCaseName` now does. · **Spec:**
`docs/superpowers/specs/2026-09-15-phase-2b-viii-org-switch-design.md` (§12 is the source
of the fifteen checks below, reproduced here verbatim in substance, each with the exact
commands and the disk/journal evidence to check — the `permission-prompt-acceptance.md`
set) · **Probe:** `docs/wakil/org-switch-probe.md`

Every check here needs a running `Wakil.app` and, for the switch itself, real Keychain
credentials for at least two providers. None of it can be run headlessly in the sense
that matters — a `--dispatch` invocation can drive the four new `ctx_*` actions (they are
ordinary `.control`/`.read` registry actions, exactly like `ctx_set_provider` in
`phase-2b-vi-acceptance.md` §3), but the switch itself (`setOrganization`,
`requestOrganizationSwitch`, the queue, the plane) is driven from a live `WindowModel`
with no `--dispatch` equivalent, for the identical reason `session_set_provider` has
none: `runDispatchFile` never constructs a `WindowModel`, so nothing ever subscribes to
receive the request. **Walk this in a real window or record it as unwalked; a headless
step here would certify a false result** — the same warning `phase-2b-vi-acceptance.md`
§4 gives for `session_set_provider`.

## Before you start

1. **`make build`, then `make app-test`, in that order.** `bin/wakil-ctx` is what the
   window's org switch restarts; a worktree that never ran `make build` fails for want of
   a binary, not for want of a feature.
2. **`make app-bundle`.** The bundle carries `wakil-ctx`/`wakil-db`, and
   `WakilWiring.binaryURL` has no fallback once running from one.
3. **Record the CLI version:** `claude --version`. Recorded so a later failure has a
   baseline, per the same discipline `permission-prompt-acceptance.md` and
   `phase-2b-vi-acceptance.md` both use.
4. **At least two organisations, each with at least one fully configured provider.**
   Checks 1–9 and 12 are switches, which need somewhere to switch *to*. Per
   `operator-todo.md` §2–3:
   ```bash
   ./bin/wakil org create <org-a> --jira-base https://<site>.atlassian.net
   ./bin/wakil org create <org-b>
   ./bin/wakil provider add main --kind claude-code --config-dir <dir-a> \
       --claude-path "$(command -v claude)" --org <org-a>
   ./bin/wakil provider add main --kind claude-code --config-dir <dir-b> \
       --claude-path "$(command -v claude)" --org <org-b>
   ./bin/wakil secrets set provider:main --org <org-a>   # paste from `claude setup-token`
   ./bin/wakil secrets set provider:main --org <org-b>
   ```
   Note `<org-b>` above with no `--jira-base` — that fixture is also check 10's
   evidence if you create it in-window instead; either origin is fine as long as one org
   in your set genuinely has no Jira site.
5. **An active provider set for each org**, same as `phase-2b-vi-acceptance.md` §1.4 —
   a fresh org has none, and several checks below (8, 9, 14, 15) depend on that state
   being reachable deliberately rather than by accident:
   ```bash
   printf '%s\n' '{"action":"ctx_set_provider","params":{"name":"main"}}' \
       > /tmp/wakil-pick-provider.jsonl
   WAKIL_ORG=<org-a> app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-pick-provider.jsonl
   ```
6. **A project in each org, and, for check 4 specifically, a project of the SAME NAME
   in two different orgs** — see check 4's own setup below.
7. **The launch command** is unchanged from 2b-vi: `WAKIL_ORG=<org> app/Wakil.app/Contents/MacOS/Wakil`.
   For checks 1 and 2, launch with `WAKIL_ORG` **unset** or naming an org that does not
   exist — that is the point of those two checks.
8. **Have something worth saying to the first org's agent before you switch away from
   it**, for check 9's cross-provider negative and for judging check 8's lineage —
   the same discipline `phase-2b-vi-acceptance.md` §1.6 records for the provider seam.

**Warning, on every `--dispatch` and every window-driven step below.** This writes to
your real `~/.wakil` and your real journal at `~/.wakil/journal/<sessionId>.jsonl`, per
`permission-prompt-acceptance.md`'s own warning. Use throwaway org ids where a check
does not require a persistent fixture.

## The checks

| # | Check | Result |
|---|---|---|
| 1 | Launch with no `WAKIL_ORG` set. The plane opens; the window is not inert. | **PASS** |
| 2 | Launch with `WAKIL_ORG` naming an org that does not exist. The plane opens with the reason named. | **PASS** |
| 3 | Switch with panes open. Panes clear, the new org's canvas is restored from disk, each `db` pane's subject re-runs live. · Failed on the first pass (every `db` pane read *no rows* — §5.4). **Re-walked after the fix: panes restored and filled.** | **PASS** |
| 4 | **Two orgs each holding a project of the same name**, switched between. Pins §5.1's collision directly — this check exists because the defect is otherwise invisible: both orgs draw *something*, and only the rows say which. · The one that could only fail silently. `personal` drew 500 rows, `acceptance-b` drew 2 `ORG-B-MARKER` rows. §5.1 holds. | **PASS** |
| 5 | A turn in flight. The switch queues, and fires when the turn completes. · The queue passed on the first pass; the panes it restored were empty (§5.4). Re-walked after the fix: both halves correct. | **PASS** |
| 6 | The same, with "stop the turn and switch now". The turn is cut and the seam says so. | **PASS** |
| 7 | A mutation parked. The switch is refused. **And, parked while a switch is queued:** the switch is held, not cancelled, and fires when the confirmation is resolved — walked both ways, confirm and cancel. · Part one: *"switch org orgb: a mutation is waiting for confirmation — confirm or cancel it first"*, Cancel/Retry, footer reading **the window is still in personal**. It also found §8.5's Escape collision. Part two walked both ways: the queued switch is held, not cancelled, and fires whether the mutation is confirmed or cancelled. | **PASS** |
| 8 | Auto-resume rebuilds the thread and records lineage. · Lineage confirmed in `~/.wakil/orgs/personal/sessions.json` — the child→parent chain is intact across four switches. | **PASS** |
| 9 | Auto-resume after an account switch. No cross-provider resume; a fresh session with a note. · `autoResumeAfterSwitch` filters on the provider; the journal shows the resume following the provider, not crossing it. *(Corrected 2026-09-16 by [#53](https://github.com/yehia-khalil/rafiq/issues/53): this evidence originally quoted the filter as `provider == providerId && cwd == rootPath`. The `cwd` half is a defect — see the note below — and is being removed. The check's claim is about the **provider** half and passed on its own terms; nothing here was re-walked.)* | **PASS** |
| 10 | An org created in-window, **with no Jira base**, verified in `~/.wakil/orgs/<id>/org.json`, and reading "no Jira site" in its row. · Failed on the first pass (account **unset** — §6.3; adopted provider could not start a session — §8.4.2). Re-walked after the fixes: name with a space slugged, no `jiraBase` on disk, row reads *no Jira site*, and the plane now names the credential step. | **PASS** |
| 11 | An account adopted. `providers/<id>.json` carries `shared: true`, and the homing org's pin is untouched. · Adopted as `umbrella-initech` under a chosen id; `shared: true`; the homing org's pin untouched. | **PASS** |
| 12 | `production` survives the round trip: the badge alarming, the gate blocking. · The badge alarms and the gate **blocks** — `outcome: "blocked"` in the journal, never `"gated"`, with no row changed. Survives a second round trip. This pass also caught the third error-wording leak, now fixed. | **PASS** |
| 13 | **Switch, quit, relaunch.** The window opens in the launcher's org, not the switched-to one. Pins §7.1's ruling as observed behaviour, not an assumption — the check that would catch it if someone later makes the switch persist without saying so. · Mis-walked on the first pass with `WAKIL_ORG` unset, which is how §6.3 was found. Re-walked as written: the window opens in the launcher's org, not the switched-to one. §7.1's ruling holds as observed behaviour. | **PASS** |
| 14 | **Switch into an org with no active project.** §6's motivating case, and the first org a new operator meets. The bottom edge must read the org switched *to*; project and environment must be empty rather than the previous org's; the window must say what it needs. · Failed on the first pass (account read **unset** though `active.json` names `main` — §6.3). **Re-walked after the fix:** `org: initech`, project and environment `unknown`, `ACCOUNT main`, and the window says what it needs. | **PASS** |
| 15 | **Switch into an org with no providers registered at all.** No agent, the reason on screen, ⌘P offered — and, per §5.3, no crash and no silent empty `providerId`. · `orga`, 0 providers: no crash, the reason on screen, ⌘P offered showing an empty list, no silent empty `providerId`. Re-walked after §6.3; this pass also caught the status line leaking a Swift type, now fixed. | **PASS** |

## What each check is really asking, the exact commands, and the evidence

### Check 1 — the org-less launch is not an inert window

**Setup.** `env -u WAKIL_ORG app/Wakil.app/Contents/MacOS/Wakil`, or `open app/Wakil.app`
from a shell with nothing exported. This is the exact failure that raised open question
13: *"WAKIL_ORG is not set"*, with no in-app answer.

**What to look at.** The org plane (`OrgPlane`'s Choosing state) must be on screen, not a
blank or crashed-looking window, and — per §8.5 — it must be **undismissable**: there is
no Esc affordance and no background canvas behind it, because there is no active project,
therefore no environment, therefore no colour for `VoidPalette` to draw. `OrgPlane.
canDismiss` is `!model.organization.isEmpty`; with no org open it is `false`. Confirm Esc
does nothing and the micro-label under the list reads *"No organisation is open · nothing
behind this plane"*, not *"Esc to dismiss"*.

**Evidence.** No journal entry is expected — nothing has been dispatched yet. The visual
claim is the whole check: a room with no field colour, no vignette bleed, just the plane.

### Check 2 — a launch naming a bad org names the reason

**Setup.** `WAKIL_ORG=does-not-exist-yet app/Wakil.app/Contents/MacOS/Wakil`.

**What to look at.** The plane opens in the same Choosing state as check 1, but this time
`OrgPlane.launchReason` is non-nil (it checks `WAKIL_ORG` against the orgs actually
listed by `ctx_list_orgs`), and the primary sentence reads *"Wakil could not open the
organisation it was launched with. Choose one, or create it,"* with an additional amber
warning box naming `does-not-exist-yet` specifically. This is the check that tells the
two failure modes apart: check 1's plain *"Wakil holds one organisation at a time"* vs.
check 2's *"could not open ... it was launched with"*. If both launches show identical
text, the reason is not actually being carried and this check has found that.

**Evidence.** Same as check 1 — no journal entry yet, the claim is what is on screen.

### Check 3 — panes clear, the new org's canvas restores, subjects re-run live

**Setup.** Two orgs, each with at least one `db` pane open on a real table, laid out and
saved (close and reopen the layout once so `LayoutPersistence` has a copy on disk under
`(org, project)`). Launch into org A with those panes visible.

**What to walk.** ⌘⇧O, pick org B, confirm the switch. Watch the canvas *during* the
switch — the spec's step 1 marks the window switching and the canvas behind the plane
should read as visibly inert (dimmed/blurred, `WakilWindow`'s `.opacity`/`.blur`
modifiers keyed off `showOrgPlane`) while `AppWiring.switchOrg` restarts `wakil-ctx`/
`wakil-db` under the new org's environment. Once it resolves, org B's own saved panes
should reappear, and each `db` pane's row count/contents should reflect a **live** query
against org B's database, not org A's stale rows left on screen.

**Why this is the ordering check.** §4.3 puts `invalidateForOrgChange()` (which clears
`tables`, `editables`, `databases` and both `panes`/`layout` stores wholesale) *before*
the client restart in step 4, specifically so that a pane whose fetch is in flight when
its client dies does not draw a result that arrived from the wrong org's server. Probe §6
says this ordering was never measured against a fetch actually in flight — start a query
on a large-enough table that you can switch orgs before it returns, and confirm the pane
either shows org B's result or an honest failure, never org A's rows under org B's name.

**Evidence.** `~/.wakil/journal/<sessionId>.jsonl` — the `db_refetch` (or equivalent
fetch action) entries around the switch should show `origin: .ui`... entries with
`outcome: "ok"` reading org B's database, not org A's. On disk, confirm
`~/.wakil/orgs/<org-b>/... ` (whichever project layout file `LayoutPersistence` wrote)
still names org B's own saved arrangement — the switch must not have overwritten it with
org A's.

### Check 4 — two orgs, one project name, switched between (uncompressed — the defect is otherwise invisible)

**This is the check the spec's §5.1 exists to force**, and it is deliberately not
merged with check 3 even though both are "switch with panes open": check 3 tests the
*restart*, this one tests a specific in-memory collision that produces **no error of any
kind** if it is wrong.

**Why it is invisible without this exact setup.** `LayoutStore.switchProject` and
`PaneStore.switchProject` both key their in-memory `byProject` dictionary by **project
name alone**, and both deliberately *keep* the outgoing project's contents in memory so
"coming back to a project finds it as it was left" — a real feature, working as
designed, for the single-org case. `LayoutPersistence` on disk, by contrast, keys by
`(org, project)`. So two orgs each holding a project named `core` — an ordinary,
likely setup, not a contrived one — would let the *in-memory* store answer org B's
`core` with org A's `core`'s rows, drawn under org B's own credential boundary, from a
different database, **with nothing anywhere failing or logging an error**. This is
`phase-2c-ii-b-acceptance.md`'s D3 one level up, generalised from project to org.

**Setup.** Create (or point) two different orgs so each has a project literally named
`core` (or any identical name), with visibly different data in each — e.g. a `db` pane
on a table that holds an org-identifying string, or simply two databases with
different row counts on the same table name.

**What to walk.**
1. Launch into org A, open `core`, open a `db` pane, note exactly what it shows.
2. Switch (⌘⇧O) to org B. Confirm `core` opens automatically (or open it) and open a
   `db` pane on the same table name.
3. **The row values must be org B's, not org A's carried over.** If the second pane's
   contents match what step 1 showed, the collision the spec's §5.1 predicts has
   reproduced.
4. Switch back to org A's `core` and confirm its own contents are still intact —
   `clearAllProjects()` wipes memory on every org switch, so this also proves the
   "coming back finds it as it was left" property survives an intervening org switch
   rather than only surviving a same-org project switch.

**Evidence.** `WindowModel.invalidateForOrgChange()` calls `await layout.
clearAllProjects()` and `await panes.clearAllProjects()` unconditionally on every org
switch (`WindowModel.swift` — the method's own body). Confirm in the journal that the
`db` pane's fetch after each switch is a genuinely fresh dispatch (`outcome: "ok"`,
timestamped after the switch's seam row) rather than a cache hit with no corresponding
entry. `InvalidationContractTests`' tripwire (§5.2) is what pins that both stores are
*classified* as org-derived in the property list; it proves nothing about whether the
reset is actually honoured at runtime — that is what this check, and only this check,
establishes.

### Check 5 — a turn in flight queues rather than blocking

**Setup.** Start a turn that will take a few seconds (ask the agent something that
requires a couple of tool calls). While `turnInFlight` is true, press ⌘⇧O and pick a
different org.

**What to look at.** The plane should show the Queued state: *"switching to *X* when
this turn finishes,"* with Cancel and "stop the turn and switch now" both offered. The
turn keeps running — it is not refused and not silently cancelled. Dismiss the plane
(Esc) and confirm the queue survives: the status line still carries "switching to *X*"
and the switch still fires once the turn's `.result` arrives.

**What else to confirm, since it is easy to miss.** While the switch is queued, try to
send a second message. It must be **refused**, naming the queued switch ("switching to
*X* — cancel the switch, or wait for it") — §4.2's rule that a queued switch cannot be
starved by an operator who keeps typing.

**Evidence.** The seam row appended once the switch actually fires (`"session"` label,
detail `<org A> → <org B>`) should be timestamped after the turn's `.result` entry in
the journal/thought thread, never before it. No `blocked`/refused journal entry is
expected for the switch itself, since it is window state rather than a registry
dispatch.

### Check 6 — "stop the turn and switch now" cuts the turn and the seam says so

**Setup.** Same as check 5, but this time choose "stop the turn and switch now" instead
of waiting.

**What to look at.** The running turn stops immediately (no further tokens appear), a
seam row reading `"turn cut short"` appears (`stopTurnAndSwitchNow`'s own
`appendSeam("turn cut short")` call), and the org switch itself proceeds right behind
it — a second seam row naming both orgs follows. Confirm the ordering matches
`setProvider`'s recorded pattern: `eventPumpGeneration` bumps before `harness.stop()`,
so no buffered event from the cut turn leaks in after the seam.

**Evidence.** The thought thread shows two consecutive `session`-labelled rows: `"turn
cut short"` then `"<org A> → <org B>"`. No `.result` entry for the cut turn should
appear after the cut seam.

### Check 7 — a parked mutation refuses the switch; queued-then-parked holds rather than cancels

**Part one — the guard.** With a mutation parked on the confirmation plane (type a
`DELETE`/`UPDATE`/`INSERT` in a `db` pane's query line, do not confirm), press ⌘⇧O and
try to switch. **Refused**, with `status` reading *"a mutation is waiting for
confirmation — confirm or cancel it first"* — guard 2 of §4.1, mirroring `setProvider`'s
wording shape exactly.

**Part two — held, not cancelled (§4.2 state 2), walked both ways.** This is the subtler
half and the reason the check is not just "the guard refuses":
1. Start a turn, queue a switch (as in check 5) while it runs.
2. Before the turn ends, have the agent (or the operator, from the query line) propose a
   mutation that parks on the confirmation plane. The queued switch must **not** be
   dropped — the plane's Queued message should still be showing or recoverable, and
   `queuedOrgSwitch` must still hold the target.
3. **Walk A — confirm the mutation.** Type `confirm`. The mutation runs, and the queued
   switch fires immediately after (once the turn also ends).
4. **Walk B — cancel the mutation instead**, on a fresh run of the same setup. The
   parked mutation is discarded, and the queued switch **still fires** — cancelling the
   confirmation must not cancel the switch, because they are independent operator
   intents. Only the explicit Cancel on the switch itself (`cancelQueuedSwitch()`) may
   discard the switch.

**Evidence.** For part one: no journal entry for the switch attempt itself (it never
reached the registry); `status` carries the refusal. For part two: the journal shows the
mutation's `gated` → `ok` pair (walk A) or `gated` with no `ok` (walk B), and in both
cases a seam row for the org switch appears afterward, proving the switch fired in
either outcome.

### Check 8 — auto-resume rebuilds the thread and records lineage

**Setup.** Have a real conversation in org A (a few turns, something specific enough to
recognise). Switch to org B and back to org A.

**What to look at.** Returning to org A should auto-resume its most recent session — the
thought thread rebuilds from the prior transcript rather than starting empty (§7's q5
amendment). Ask the agent something only the earlier conversation would know; it should
know it, unlike the provider-switch seam in `phase-2b-vi-acceptance.md` check 2, where
the new account deliberately does *not* know prior context. This is the opposite
judgement on purpose — an org switch and back is "coming back", not a new account.

**Evidence.** `~/.wakil/journal/<sessionId>.jsonl` — a `session_record_parent` entry
(`origin: .ui`) pairing the fresh Wakil-minted session id (`child`) with the resumed
session's id (`parent`). Confirm `sessionId` after the return visit is **new**, not the
original session id — resume is a fork, never a continue-in-place, so a chain of
switches produces a chain of short sessions with readable lineage rather than one long
session. `resumedParentForTesting`-style evidence is test-only; in the window, the
journal's `session_record_parent` row is the durable proof.

### Check 9 — auto-resume after an account switch: no cross-provider resume, fresh session with a note

**Setup.** In org A, switch the *provider* (⌘P) to a second account registered under
org A, if one exists — or, simpler, switch to an org B whose active provider differs
from org A's. Then switch org A → org B (whose account differs) → back to org A.

**What to look at.** `autoResumeAfterSwitch()` filters candidates by
`provider == providerId` — a session belonging to a different provider's config dir
cannot be read by this window's `claude` process (`resume(sessionId:)`'s own refusal),
so the newest session under the account now active is what gets offered, never a
session that belongs to an account no longer running. If no session exists for the
*current* provider, the status line reads *"no previous session in \<org\> — starting a
fresh session"* and the thread stays empty rather than attempting (and failing) a
cross-provider resume.

**Evidence.** No `session_record_parent` entry when the fallback fires — its absence
is the evidence, alongside the status-line note. If a resume *is* found (same provider,
different org visit), confirm the resumed session's `provider` field
(`session_list`'s structured rows) matches `providerId` exactly.

### Check 10 — org created in-window with no Jira base

**Setup.** ⌘⇧O → the "new organisation" affordance (always present in the Choosing
state, per §8.1) → Creating state. Enter only an id; leave the Jira base field empty —
it is marked **Optional** in the form (`OrgPlane.swift` renders `Text("Optional")`
beside the field).

**What to look at.** Submission calls `ctx_create_org` with no `jiraBase` argument at
all (not an empty string — `WindowModel`'s handler only adds `jiraBase` to the call's
arguments when the field is non-empty). The plane chains into the Adopting state for the
org just created (§8.6's edge table), skippable.

**Evidence, on disk — do not trust the plane alone:**
```bash
cat ~/.wakil/orgs/<id>/org.json
```
Expect no `jiraBase` key at all (it is `omitempty` in `Org`'s JSON tag), or an absent
field — never an empty string masquerading as "set". Then, back in the Choosing state
(⌘⇧O again), confirm that org's row reads **"no Jira site"** rather than a blank —
`operator-todo.md`'s own correction: *"a flag cannot show you what you did not type; a
form can."*

**Headless equivalent, for the create call itself (the plane's chrome still needs the
window walk above):**
```bash
printf '%s\n' '{"action":"ctx_create_org","params":{"id":"<scratch-org>"}}' \
    > /tmp/wakil-create-org.jsonl
app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-create-org.jsonl
```

### Check 11 — an account adopted: `shared: true`, homing org's pin untouched

**Setup.** An account already registered under org A (its **homing** org — the one
`register-provider.sh`/`wakil provider add` without `--share` pinned into the config
dir). In org B's org plane, reach the "add an account" edge (§8.6: "Adoption is also
reachable per-org... adding a second account to an org that already exists"), and adopt
that same config dir into org B.

**What to look at.** The plane shows the same warning the CLI's `--share` prints (§8.4):
that a plain `claude` session in that config dir still runs as the homing org, and only
*inside Wakil* does it run as org B.

**Evidence, on disk:**
```bash
cat ~/.wakil/orgs/<org-b>/providers/<id>.json      # expect "shared": true
cat ~/.wakil/orgs/<org-a>/providers/<id>.json      # the homing record — untouched
./bin/wakil provider home <id> --org <org-b>       # must still print <org-a>
```
The homing org's own record must show no `shared` key (or `shared: false`) and no
change to its `configDir` — adoption binds a *second* org to the same config dir, it
does not move or duplicate the credential.

**Headless equivalent for the adopt call:**
```bash
printf '%s\n' \
  '{"action":"ctx_adopt_provider","params":{"org":"<org-b>","id":"<id>","configDir":"<dir>","kind":"claude-code"}}' \
  > /tmp/wakil-adopt.jsonl
app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-adopt.jsonl
```

### Check 12 — `production` survives the round trip

**Setup.** An org/project/environment set where `environment` resolves to `production`
for at least one side of the switch.

**What to walk.** Switch into the org whose active project has a `production`
environment. Confirm: the environment badge reads alarming (Invariant 8 — red room,
white-or-red badge), and a mutation attempt against it is refused at the gate
(`outcome: "blocked"`, never `"gated"`), exactly as `permission-prompt-acceptance.md`
check 3 established for the provider-picker case. Switch away and back once more to
confirm the badge and the gate both survive a second round trip, not merely the first.

**Evidence.** `~/.wakil/journal/<sessionId>.jsonl` — a `blocked` outcome on the mutation
attempt, never `gated`. No row in the database should show any change from the attempt.

### Check 13 — switch, quit, relaunch: the launcher's org wins, not the switched-to org (uncompressed — pins §7.1's ruling)

**Why this check exists, stated plainly so a later reader does not read it as
redundant with check 12 or check 3.** §7.1 is a *ruling*, not a measurement someone
already made: the switch is session-scoped, `WAKIL_ORG` remains the launch seed, and an
operator who lives in two orgs re-picks on every launch, or exports `WAKIL_ORG` in
their launcher as they do today. Nothing else in this document, and nothing in the
automated suite, observes that the switch does *not* survive a process boundary — this
is the one check that would catch it if a later change quietly made the switch persist
without saying so, which is exactly the failure mode §14's charter edit exists to keep
visible.

**Setup.** `WAKIL_ORG=<org-a> app/Wakil.app/Contents/MacOS/Wakil`.

**What to walk.**
1. Switch (⌘⇧O) to `<org-b>` and confirm the window is genuinely running as `<org-b>`
   (context bar, ⌘P's account row, a query against `<org-b>`'s own database).
2. Quit the app fully (⌘Q, or confirm the process actually exits — not merely the
   window closing).
3. Relaunch with the **same** `WAKIL_ORG=<org-a>` in the shell (do not change it).
4. **The window must open in `<org-a>`, not `<org-b>`.** No mechanism in this sub-phase
   writes a machine-level "last org" record — `active.json` lives *under* `OrgDir()`
   (`internal/wakilcore/active.go`), which is per-org by construction and cannot record
   which org is active across all of them.

**Evidence.** No file should exist recording "last active org" outside any org's own
directory — confirm there is nothing new under `~/.wakil/` at the top level (only
`orgs/` and `journal/` should be there, as before). The relaunched window's context bar
and ⌘P account row must both read `<org-a>`, and a query run immediately after relaunch
must hit `<org-a>`'s database, not `<org-b>`'s.

### Check 14 — switch into an org with no active project (uncompressed — the motivating case, otherwise invisible)

**Why this is not covered by checks 1 and 2.** Those two cover launching *without* an
org (unset, or a bad name). Neither covers the case that motivated §6's whole Go
amendment: arriving in a **good, real, already-open** org that simply has nothing
selected inside it yet — a fresh org, and the first org a genuinely new operator meets.
Before §6's fix, `get_context`'s error on a project-less org returned `"Org":""`, and
the window's `catch` left `organization`, `project` and `environment` all untouched —
so the bottom edge would go on reading the *previous* org's name while every child
process, every Keychain lookup and the write gate itself were already running under the
new one. That is Invariant 4's own subject: the window would be **drawing the wrong
credential boundary**, silently, with nothing failing anywhere. This check is the only
place that defect would ever surface, because it requires the exact combination of "a
real org" and "no project chosen in it" — anything else either fails loudly (check 2)
or has a project to fall back on (checks 3–9).

**Setup.** An org with **no** project ever selected in it (a freshly created org from
check 10 works, provided you skip picking a project) — or `wakil org create` a scratch
org and register a provider for it, but never run `ctx_set_project` against it.

**What to walk.** From a window already open in another org, switch (⌘⇧O) to this
project-less org.

**What must be true, checked in this order:**
1. The bottom edge (context bar) must read the org **switched to**, immediately —
   `organization` is assigned from the id switched to (§6 item 2, `setOrganization`'s
   `organization = org` line) *before* `refreshContext()` runs, so this does not depend
   on `get_context` succeeding.
2. `project` and `environment` must both be **empty**, not the outgoing org's stale
   values. `refreshContext`'s `catch` must clear both rather than leave them holding
   whatever the previous org had.
3. The window must say what it needs — a visible note pointing at project selection,
   not a silent blank canvas.
4. **No crash**, and nothing anywhere reads as though the switch simply failed.

**Evidence.** Run the headless half directly against the Go layer to see the exact
payload the window is defending against. **Not via `--dispatch`:** `get_context` is
deliberately not a registered action (§9.2, pinned by `getContextIsNotOperatorOnly`), so
`{"action":"ctx_get_context"}` returns `{"error":"unknown(\"ctx_get_context\")"}` — an
earlier draft of this check said otherwise and was wrong. Speak to `wakil-ctx` over
stdio instead, keeping stdin open past the call so the server does not exit first:
```bash
{ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_context","arguments":{}}}'
  sleep 2; } | WAKIL_ORG=<project-less-org> ./bin/wakil-ctx 2>/dev/null | grep '"id":2'
```
Expect the `structuredContent` to carry a non-empty `"Org"` (and, per §5.3/§6,
`"ActiveProvider"` if one is set for that org) even though `isError: true` and
`"Project": null`. If `"Org"` comes back empty here, §6's Go amendment has regressed and
check 14 cannot pass regardless of what the window does with it. In the journal, no
`blocked` or `gated` entries are expected — nothing mutating was attempted; the check is
entirely about what the context bar and `status` show.

### Check 15 — switch into an org with no providers registered at all (uncompressed — reachable for the first time without a relaunch)

**Why this is not the same as check 14.** Check 14 is a real org with a real provider
but no project chosen. This is an org with **zero** providers registered — the state
`WindowSession.swift:110-140` was rewritten for in 2b-vi (a fresh install, or an org
that has never had an account chosen for it), but before this sub-phase the only way to
reach it was a fresh *launch* of the whole process. This check reaches it for the first
time **without a relaunch**, by switching into it from a window that is already running.

**Setup.** An org with `wakil org create` run but **no** `wakil provider add ... --org
<this-org>` ever run against it — genuinely zero providers, not merely none active.

**What to walk.** Switch (⌘⇧O) into this org from a window already running elsewhere.

**What must be true.**
1. No agent runs — no harness starts, no session id is assigned.
2. The reason is on screen: `WindowModel.noActiveProviderNote` — *"no active provider is
   set for this org yet — pick one in ⌘P, or bootstrap headlessly with `--dispatch
   ctx_set_provider`..."* — must be visible, not merely logged.
3. ⌘P is offered and, when opened, shows no provider rows for this org (or shows the
   picker with nothing to select), rather than being disabled or crashing.
4. **Per §5.3, specifically:** no crash, and `providerId` must be the empty string
   (`""`) rather than some other placeholder that a later `startHarness`/`resume` call
   could misinterpret as a real, if wrong, provider id — `startHarness` refuses an
   empty `providerId` outright, and that refusal must be reachable cleanly rather than
   the window attempting a launch with a garbage value.

**Evidence.** No journal entry for a harness start. `~/.wakil/orgs/<org>/providers/`
should not exist, or should be empty, confirming the fixture is genuinely providerless:
```bash
ls ~/.wakil/orgs/<org>/providers/ 2>&1   # expect "No such file or directory" or empty
```

## Things to watch for in the field, recorded here rather than assumed away

**`autoResumeAfterSwitch()` matched a session's `cwd` against `rootPath` by exact
string — a defect, not a fragility. Ruled on and being removed.** This note originally
warned that the exact match had no normalisation, and guessed that trailing slashes or a
symlinked project directory would one day break it. It named the symptom exactly right —
a **spurious** *"no previous session in \<org\> — starting a fresh session"* on a switch
that should have resumed something — and the wrong cause. Neither guess has ever arisen.

What actually triggers it is ordinary use. `session_list` already returns only sessions
belonging to the active project, because `ListSessions` keeps a transcript only if
`cwdMatchesAnyRoot` accepts it (`internal/wakilcore/sessions.go:419`), and that is a
**prefix** match. So every session started in a *subdirectory* of a root, and every
session in any root but the first, is listed by the capability layer and then discarded
by the window — in a **single-root** project as readily as a multi-root one.

[#53](https://github.com/yehia-khalil/rafiq/issues/53) ruled the `cwd` clause deleted
rather than widened: Go has already answered the question the clause is re-asking
badly. If check 8 or check 9 is re-walked before that lands, this is the note to read
when the resume does not happen.

**`ActionRegistry.dispatch` and `MCPServer`'s `tools/call` handler never consult
`operatorOnlyActions`.** The entire agent-unreachability guarantee for all six
operator-only actions — the four this sub-phase added
(`ctx_list_orgs`/`ctx_create_org`/`ctx_list_machine_providers`/`ctx_adopt_provider`)
plus the two from 2b-vi (`session_set_provider`/`ctx_set_provider`) — rests on the CLI
itself honouring `--allowedTools` (which already filters `.mutate` and everything in
`operatorOnlyActions` off `agentAllowedTools`) and on `approve_tool_use` denying the
tool by name if an agent asks for it anyway (`permissionDecision` in
`PermissionPrompt.swift`). This is **pre-existing architecture**, not a gap this
sub-phase introduced — `WindowModel.agentAllowedTools`'s own doc comment names the same
two-halves shape for the provider actions already, and `permissionDecision`'s doc
comment states plainly that "whether the call then executes is decided where it is
decided today: `ActionRegistry.dispatch`, then `writeGate`, then a human at the
confirmation plane" — `operatorOnlyActions` is consulted at neither of those two
places. Hardening `dispatch` itself to consult `operatorOnlyActions` directly would be
a genuine defense-in-depth improvement to a gate every operator-only action shares, but
it was out of scope for this sub-phase: it touches a shared chokepoint used by every
action kind, not only the org actions this sub-phase added, and changing it here would
have widened the diff well past "the org switch". **Recorded as a known hardening
opportunity** rather than a defect — today's guarantee is real (probe §7's widening
argument and the permission-prompt runbook's check 6 both establish that a bare tool
call reaching `ActionRegistry` at all requires either the CLI's allow-list to have
already let it through as a named tool, or an explicit approval at the plane) but it is
one layer thinner than "the registry itself refuses it," and a future reviewer should
not be surprised to find that gap unfixed.

## Result

**WALKED AND MET, 2026-09-15.** All fifteen checks pass against the bundle built from
`fa06406`, walked by the operator over three passes that found nine defects between them.
This document establishes what
an operator needs to run and what evidence closes each check; none of the fifteen has
been executed against a live window. `phase-log.md`'s 2b-viii row is corrected by this
same task (§14 of the spec) to reflect what the sub-phase actually delivers, but is
**not** marked met — per the spec's own §12 and this task's brief, the row stays un-met
until this runbook is walked.
