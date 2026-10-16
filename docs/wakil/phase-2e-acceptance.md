# Phase 2e acceptance — the settings pane, and a provider added from the browser

**Status: walked, 2026-09-29 to 2026-09-30, by the operator. All ten pass.** The walk
found eleven defects, each fixed and re-walked before its check was marked; the Result
cells name them. The operator gave the results; they are recorded here in the order walked.

**Status of this document:** the **human half only, and provisional.** The Runbook rung
now has two halves (`docs/agents/workflow.md`): the machine half is rendered by
`make e2e-runbook E2E_RUNBOOK=<this document>` and the human half is written from what
**Cover** could not reach. The ten checks below are the ones no harness can reach *by
construction* — a browser, a real Keychain, a credential at Anthropic, and a window an
agent cannot see.

**Cover, 2026-09-29 — turned, for the first time.** Measured against `18f9762`, the last
merge before 2e, because 2e is already on `main` and a merge-base with today's trunk
would call none of it new. `make e2e-new` needs a base that names its keychain, and no
commit before 2e has #304, so the failability base is `1244bfa`: `18f9762` plus #304's
keychain scoping and nothing else. It is local and never merged, and the harness refused
the plain base for exactly the reason #304 exists. Against it, all nine checks new since
`18f9762` went red on 2e's surface being absent, not on the harness. Cover found one
defect and fixed it on this branch: **an agent's settings write never reached an open
settings pane** until Reload, because only the operator's wrappers re-read. The
observation pump now does it for both channels.

**Exit criterion, two clauses, verbatim from [#89](https://github.com/yehia-khalil/rafiq/issues/89):**
the first is the pane itself; the second is *"every binding the pane draws has a
credential the operator did not paste."*

---

## 0. The ten checks

**Walk these ten.** Everything below them is reference.

Each check names what it proves and what a failure would mean. Three of them
(**3**, **4**, **7**) create a real one-year credential at Anthropic; they are marked,
and the cleanup each owes is stated with it.

| # | Check | Result |
|---|-------|--------|
| 1 | **⌘, opens the pane over an empty Landing.** Open an organisation with no session and press ⌘,. The pane draws over the Landing, not behind it. | ✅ 2026-09-29. Walked by the operator on Acceptance B. |
| 2 | **The table draws this organisation's bindings, and names what is broken elsewhere.** Every row's ACCOUNT cell shows a config dir, not just an id. Bindings in *other* organisations with no credential are named beneath the table. | ✅ 2026-09-29. Rows and the elsewhere-banner correct; verbs stacked a letter per line in a narrower window (#326, fixed). |
| 3 | **Register a new account.** ⚠️ *Creates a credential.* `＋ Register a new account`, type an id, `Add`. One or two browser trips, no token shown, and the row lands `present · signed in`. | ✅ 2026-09-29, on the third attempt. Failed twice: an org with no accounts found no `claude` (#322) and the Swift action dropped `claudePath` (#330); both fixed, then passed. |
| 4 | **Re-authenticate a red row.** ⚠️ *Creates a credential.* Press it on a `signed out` row. It goes **straight to the browser** — no confirmation step — and the row goes green. | ✅ 2026-09-30. Walked by the operator. |
| 5 | **Which account is running, and switching it.** Exactly one row reads `RUNNING`; it matches the ACCOUNT indicator at the window's bottom edge. `USE` on another row moves it. | ✅ 2026-09-29. USE moved RUNNING; USE also closed the pane (#331), then twitched on reopen (#335); both fixed. |
| 6 | **Unlink says what it cannot destroy.** `UNLINK` → the confirmation draws as *buttons*. Confirm: the row goes, and the report says the credential at Anthropic survives and the config dir is untouched. | ✅ 2026-09-29. Report correct; the ACCOUNT indicator kept naming the unlinked account (#324) and the doors hid under an error banner (#325); both fixed. |
| 7 | **Adopt an account from another organisation.** ⚠️ *Copies a credential.* `＋ Adopt an account from this machine` offers only accounts not already bound here. Adopt one: no browser opens. | ✅ 2026-09-29. No browser opened. |
| 8 | **The database form asks for parts, and the journal redacts them.** In a project's Databases node, store one real database: pick its driver, and give host, port, database, user and password in their own fields — the password masked, no connection string anywhere. Leave the host empty once first: Save says so and no confirmation opens. Then, after 3–7 as well, read the session's journal file. `db_set_dsn`'s `dsn` reads `[redacted]` while its parameter name survives; `provider_mint` carries an outcome and no token. | ✅ 2026-09-30. Walked on the reworked form (separate fields, #319; redesigned, #327); refusal before confirmation; journal redaction confirmed by the operator. |
| 9 | **The pane reads as one surface with the organisation plane.** Rows are 44pt with a 22pt gutter; column labels sit over their own columns; row verbs are uppercase; warnings draw as tinted slabs, not grey text. Judge it side by side with the artboard, `docs/wakil/screens/Settings.dc.html` — this is [#269](https://github.com/yehia-khalil/rafiq/issues/269)'s one unmet criterion, and no check can take it. | ✅ 2026-09-30. Judged good by the operator after #327's redesign. |
| 10 | **The exit criterion's second clause.** Every row the pane draws, in every organisation, shows `present` — and each credential was minted, never pasted. | ✅ 2026-09-30. Validated by the operator. |

---

## 1. What the walk must not skip

**Check 4 is the one that has failed most.** Its flow crossed five separate defects
before it worked once end to end: the minter was never wired ([#204](https://github.com/yehia-khalil/rafiq/issues/204)),
the login binary was never wired ([#238](https://github.com/yehia-khalil/rafiq/issues/238)),
`claude setup-token` is silent on a pipe ([#240](https://github.com/yehia-khalil/rafiq/issues/240)),
every trip ran in a directory derived from the id rather than taken from the record
([#244](https://github.com/yehia-khalil/rafiq/issues/244)), and the token is printed
*inside a sentence* so a line-based scan discarded every successful mint
([#244](https://github.com/yehia-khalil/rafiq/issues/244)). **Walk it twice**, on two
different accounts.

**Check 9 has never been seen by an agent.** Window-level accessibility stopped
responding on the build machine while the scale sweep was in flight, so the pane was
re-measured against `Settings.dc.html` and `OrgPlane.swift` and never looked at. The
header-gutter defect ([#271](https://github.com/yehia-khalil/rafiq/issues/271)) was
found by review, not by sight. Nothing but this check establishes it.

**Check 10 is the clause, and it is not free.** It is satisfied by *doing* checks 3, 4
and 7 across every organisation that holds a binding — not by reading the table.

## 2. What the walk cannot establish

- **That a credential is valid.** Wakil reads a Keychain item's *presence* and its
  modification date, never its value. A `present` cell means an item exists.
- **That a token was revoked.** `claude auth logout` reports success when it revoked
  nothing — measured. The unlink offer says so; the walk cannot check it.
- **Liveness as anything but a sign-in.** A red row means *sign in again*, never *this
  account is broken*. A lapsed sign-in still launches sessions.

## 3. Cleanup the walk owes

Checks 3, 4 and 7 each leave a real one-year credential at Anthropic, revocable only in
your Anthropic account. Note the account and the date for each, and revoke the ones you
did not mean to keep. Wakil cannot do this for you, and says so in the unlink report.

Any scratch organisation created for the walk: `wakil org rm <org> --force`. It never
touches the Keychain, so a credential outlives its organisation deliberately.

## 3a. The residue — what Cover could not reach, and why

**Cover is turned for everything but the agent checks.** Five checks are
written; `make e2e-new` saw every one go red against the merge-base
`753b6ff7a8ab` — for substantive reasons, not because the harness could not
look: the identifiers did not exist and `ctx_list_accounts` was an *Unknown
action* on that build. `make e2e E2E_AGENT=` then exits 0 with 16 checks green
and the coverage gate passing, every remaining gap excused by name.

**The one thing outstanding was
[#301](https://github.com/yehia-khalil/rafiq/issues/301)**, and it is why §3b
below renders red. The two checks under `e2e/checks/agent/` could not run
against this build: seeding the fixture credential invoked `/usr/bin/security`
with no keychain argument and blocked on an authorization prompt aimed at the
operator's real login keychain. `E2E_AGENT=` skips them, which is how the rest
of the run completes — but a walk recorded from another build certifies another
build, and the renderer refuses to pretend otherwise. **That refusal was correct
and was not worked around**: killing the blocked `security` process leaves the
provider record unset, so the agent checks would then go red for a reason that
is not this branch's, and an unattended run invites somebody to click the
dialog, which is the one outcome that must not happen.

**#301 is fixed, 2026-09-26, and §3b below is left exactly as this branch
recorded it.** `WAKIL_KEYCHAIN` now names the keychain file the product passes
to `security` itself, so the fixture isolates the shipped binary rather than
only a `PATH` shim the product had stopped resolving through (Decision 33). On
`main` plus that fix — the run's own record names `d84032c`, and every commit
after it on that branch is documentation — `make e2e` completed for the first
time since
[#201](https://github.com/yehia-khalil/rafiq/issues/201) — **20 checks green,
both agent checks among them, coverage gate exit 0**, and
`security find-generic-password` confirms the operator's login keychain holds no
`wakil:e2e-fixture:` item at all.

**Why §3b is not re-rendered to show that.** Its two other columns are
*branch-relative*: *"red against the base"* is `make e2e-new`'s finding against
`753b6ff7a8ab`, this branch's merge-base, and the counts of new actions and
controls are this branch's diff. A re-render from any later branch would
truthfully report *"this branch added no check"* and erase 2e's own proof that
its five checks were seen to fail before they passed — which is the evidence the
rung rests on. So §3b stays the record 2e left, the two red lines are #301's and
are explained here, and the machine walk for the **next** sub-phase renders with
no hole in it.

**That the choice had to be made at all is
[#305](https://github.com/yehia-khalil/rafiq/issues/305)**: the merge-base
verdict is already recorded, and the renderer recomputes it rather than carrying
it forward — so a document's failability evidence depends on a branch that a
merge deletes. Either resolution here is a human noticing; that is the defect.

**What the checks do cover**, all in `e2e/checks/seeded/`:

| Check | What it reaches |
|---|---|
| `2e-settings-pane.jsonl` | the pane over the Landing, both tree nodes, the account table's columns, Reload, `ctx_config_tree` and `settings_open` |
| `2e-settings-organisation.jsonl` | the organisation form, and a **parity** step on `ctx_update_org` — the save clicked, the same action dispatched, the two states compared |
| `2e-settings-unlink.jsonl` | `ctx_list_accounts`, the unlink confirmation, its cancel, its confirm, and the three sentences the report owes about what survives at Anthropic |
| `2e-settings-doors.jsonl` | the register door, the pre-flight and its *Not now*, the adopt door, an adoption, and USE on the second row |
| `2e-settings-databases.jsonl` | the whole database form — all three drivers, the refusal before the confirmation, and both sides of the confirmation |

**What no check covers.** Every entry is in `e2e/checks/uncoverable.tsv` with
the same reason, and the three groups are not equal — only the first is a claim
about the harness.

1. **The parity vocabulary cannot express it.** A `parity` step drives one
   action down both channels with the *same* params. That cannot describe a
   destructive or creative action: the click consumes its own subject, so the
   dispatch either finds the id gone (`ctx_unlink_provider`) or collides with
   what the click just made (`ctx_add_provider`). `settings_open` is the third,
   for a different reason — its only UI path is the `Settings…` **menu item**,
   and a menu's buttons are not in the accessibility tree until the menu is
   open. All three are *dispatched* by a check; what is missing is only the
   comparison.

2. **Blocked on [#254](https://github.com/yehia-khalil/rafiq/issues/254) — the
   browser leg.** `ctx_provider_login`, `settings.login.start`,
   `settings.row.<id>.reauthenticate`, `settings.login.someoneElse`,
   `settings.login.cancel`, `settings.mint.stopWaiting`,
   `settings.login.dismiss`. Each needs a real browser trip and a real one-year
   credential at Anthropic, so a check that reached them would mint a credential
   on every run. **This is exactly why checks 3, 4 and 7 above are the
   operator's and are marked ⚠️.** They become ordinary work the day #254's
   seeded login binary lands.

3. **Blocked on [#300](https://github.com/yehia-khalil/rafiq/issues/300) — a
   hang.** `db_set_dsn` does not return for a project path that exists, over
   either channel, and leaves the agent stream out of step afterwards; so
   `db_remove_database` and `settings.db.<name>.remove`, which both need a
   stored database to exist, cannot be reached either. Not an argument about the
   harness: the action is broken, and the pane waits on it forever with no error
   shown. The database check drives the whole form and stops short of the write.

   **Corrected 2026-09-28 — no longer blocked.** #300 was #301 seen from the
   database form: `db_set_dsn` is the one 2e action whose UI path writes the
   Keychain, and its `security add-generic-password` named no keychain, so it
   waited on the operator's login keychain. #304's `WAKIL_KEYCHAIN` scoped it
   with every other call. `2e-settings-databases.jsonl` now asserts the write,
   the redacted journal entry and the remove, and all three entries left
   `uncoverable.tsv`.

**Two defects found by writing the checks**, neither of them in 2e's plan:

- [#300](https://github.com/yehia-khalil/rafiq/issues/300) above. Found because
  a check asserted the write landed and it had not.
- [#301](https://github.com/yehia-khalil/rafiq/issues/301) — the fixture's
  keychain shim could not reach the shipped binary. `wakilcore` resolves
  `/usr/bin/security` absolutely, so a PATH shim never intercepted it, and the
  one seam that could is gated behind `testing.Testing()`. The agent checks hung
  on an authorization prompt aimed at the operator's **real login keychain**,
  and `make e2e` had not completed on this machine since #201 — while
  `VerifyIsolation` went on certifying those runs as isolated, because it
  checked `PATH` and `PATH` was perfect. That second half is the worse one and
  the issue did not name it. **Fixed 2026-09-26**, by naming the keychain rather
  than the tool; Decision 33.

**And one in the gate itself.** `make controls` reported *"54 actionable
control(s), all named"* while four controls were unnamed: `confirmButton` and
`plainField` defaulted their identifier parameter to `""`, and the gate audits
control *constructors*, so a helper is named once at its definition and every
call site is invisible to it. The defaults are gone — the compiler requires a
name now — and `LeakyHelpers` fails the gate on any other helper that grows one.

## 3b. The machine walk

**Generated — write nothing here by hand.** Everything between the markers is
rendered by `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2e-acceptance.md`
from the records the runs left, and is overwritten on every render. It is the
counterpart to §3a: what the machine established, against what it could not.

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against edea12ff27b4, rendered 2026-09-29 16:18 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

| Check | `make e2e` | Red against the base | Assertions | Evidence |
|---|---|---|---|---|
| `org-plane.jsonl` | ✓ exit 0 | not new on this branch | 3 | — |
| `2c-iii-1-bundle-path.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2c-iii-2-block.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-3-live-prompt.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-4-interrupt.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2c-iii-5-full-screen.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-6-no-orphan.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2c-iii-7-org-switch.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2e-settings-databases-dispatch.jsonl` | ✓ exit 0 | ✓ red vs 09d363d33eab | 10 | — |
| `2e-settings-databases.jsonl` | ✓ exit 0 | ✓ red vs 09d363d33eab | 20 | — |
| `2e-settings-doors.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2e-settings-organisation.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2e-settings-pane.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `2e-settings-unlink.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `agent-pane-is-drawn.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
| `api-open.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `api-recent.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-send.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-set-request.jsonl` | ✓ exit 0 | not new on this branch | 25 | — |
| `api-surface.jsonl` | ✓ exit 0 | not new on this branch | 14 | — |
| `landing.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `vocabulary.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `both-surfaces.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `two-enter.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |

**`make e2e-new` saw every check this branch added go red against 09d363d33eab.**

**Every action and control this branch added carries a check.** 0 action(s) and 9 control(s) are new on this branch.

- actions:  14 of 65 dispatched by a check
- writes:   4 of 40 carry a parity check
- controls: 48 of 86 exercised by a check

**16 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `api_unbind` — #308, until docs/superpowers/plans/2026-09-29-phase-2c-iv-the-hand-bind.md, Task 8. Only a binding can be unbound, and only api_bind makes one. Covered by WakilKitTests: ApiBindTests, ApiDropBridgeTests.
- `api_bind` — #308, until docs/superpowers/plans/2026-09-29-phase-2c-iv-the-hand-bind.md, Task 8. No database-pane row exists to drop. The matching and re-bind rulings are covered by WakilKitTests: ApiBindTests, and the drop's bridge by ApiDropBridgeTests.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `api.recent.<…>.curl` — Its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read — the act is real and its result leaves the window, so a check could press it and assert nothing, which is the check-that-cannot-fail this file exists to prevent rather than permit. `TerminalPane`'s own Copy is silent for the same reason and carries no indicator. The line it copies is `apiRenderCurl`'s, covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses. If this pane ever draws a "copied" acknowledgement, the act becomes observable and this line should go.
- `settings.login.cancel` — #254. Only exists while a browser trip is in flight.
- `settings.login.dismiss` — #254. Drawn only by the states a finished trip reaches — added, refused, cancelled, timedOut, uncertain, failed.
- `settings.login.someoneElse` — #254. Starts a fresh trip, and only appears when the config dir is already signed in, which itself needs a real credential.
- `settings.login.start` — #254. The control that does the above.
- `settings.mint.stopWaiting` — #254. Only exists while waiting on a live mint.
- `settings.row.<…>.reauthenticate` — #254. Goes straight to the browser by design — no confirmation step — so pressing it IS starting a real trip.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->

## 4. Provenance

Tickets: [#196](https://github.com/yehia-khalil/rafiq/issues/196)–[#207](https://github.com/yehia-khalil/rafiq/issues/207),
[#236](https://github.com/yehia-khalil/rafiq/issues/236),
[#238](https://github.com/yehia-khalil/rafiq/issues/238),
[#240](https://github.com/yehia-khalil/rafiq/issues/240),
[#244](https://github.com/yehia-khalil/rafiq/issues/244),
[#259](https://github.com/yehia-khalil/rafiq/issues/259),
[#269](https://github.com/yehia-khalil/rafiq/issues/269),
[#270](https://github.com/yehia-khalil/rafiq/issues/270),
[#271](https://github.com/yehia-khalil/rafiq/issues/271).

Measured halves: `provider-login-probe.md` (§9 the live login, §10 the expiry, §11 the
mint — and **§11.0, the live run that corrected §11's reading**) and
`phase-2e-probe.md`.

**Eight of those nineteen tickets did not exist when the phase was planned.** Five came
from running the app and three from reviewing it, and none was reachable by the 1,240
tests that were green the whole time. That is the argument for this walk, and the
argument for the Cover rung this sub-phase still owes.
