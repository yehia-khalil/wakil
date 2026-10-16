# The org switch — design

**Sub-phase 2b-viii.** Binding authority for the implementation that follows.
Written 2026-09-15, on the measurements in `docs/wakil/org-switch-probe.md` (run
2026-09-14) and the rulings in `north-star.md` §7 q13, which scheduled this
sub-phase and placed it **before 2c-iii**.

**Revised 2026-09-15**, the same day, against
`docs/wakil/2b-viii-design-review-2026-09-15.md` — a read of this spec back
against the tree, which found five blocking defects in it. Four were one failure
repeated: a claim true of most of a set, stated over the whole set (§9's "all
five", §4.4's server count, §8's creation form, §5's invalidation list). The
fifth, §5.3, was a step the sequence assumed was free. All are closed here, and
each correction says what it is correcting so the next reader can see the shape of
the mistake rather than only its repair. §7.1 records the one item the review
escalated to the operator rather than fixed.

**Amended 2026-09-15 again, after the first operator walk of the acceptance
runbook** — the first time any of this was driven by a human rather than a test.
Three of §8's rulings did not survive contact, and all three were mine rather than
the operator's misreading:

- **§8.6.1** — a row click went to *adoption* instead of the switch. The operator
  had predicted this during design ("it's done in two steps?") and I kept the
  edge table anyway.
- **§8.4.1** — an adopted account could not be given a free id, so on a machine
  where every org's account is called `main`, in-window adoption was unreachable
  in every direction the operator tried.
- **§8.1.1** — `DisplayName` existed on disk and was carried by neither
  `OrgSummary` nor `createOrgArgs`, so the plane showed raw ids and an
  in-window-created org could never have a name at all. The operator found it by
  typing a space into the identifier field and asking why that was refused.

The pattern across all three: each was a *plausible* reading of the spec that no
test could fail on, because `WakilApp` has no test target and none of them is a
correctness bug. They are what a walk is for, and they are the argument for
walking the runbook before marking the row met.

**Amended 2026-09-15 a third time, after the operator walked checks 3–15.** The
first walk found presentation rulings; this one found three defects, two of them
correctness bugs in `WakilKit` that fifteen task reviews and a whole-branch review
all passed over:

- **§6.3 (new)** — `get_context`'s error path names the org and the active
  provider (§6.1, shipped in Go and verified against the binary), and Swift threw
  the whole payload away at `ContextStore.callChecked`. §6.2 reasoned about
  *switching* into a fresh org and never asked what a **launch** into one does:
  nothing assigns `organization` on that path, so `WAKIL_ORG=initech` — a healthy org
  whose only distinction is that no project is active in it yet — opened a window
  that believed it was in no org at all and force-opened this plane over it,
  undismissable. The same drop cleared `providerId` where `active.json` named one.
- **§5.4 (new)** — an org switch restored the canvas's *arrangement* from disk and
  never re-ran the panes' subjects, so every restored `db` pane read "no rows".
  §12 check 3 states the requirement in so many words; `restorePaneContents()`
  existed, was correct, and had three callers, none of them the switch.
- **§8.4.2 (new)** — adoption registers a binding and does not carry a credential,
  which is Invariant 4 working correctly, and the plane never said so. The
  operator adopted an account, saw it appear in ⌘P, picked it, and met "no
  credential stored for ref provider:main" several screens later.

The first two are the more interesting failure. Both were invisible to the whole
review chain for the same reason the final fix pass's Critical was: the tests
that *covered* the area asserted the behaviour at a level where the missing call
did not show. §5.4's `restorePaneContents()` had a passing test that called it
directly — which is exactly what the shipped code did not do. A test that drives
the real chain is the only kind that could have caught either, and both now have
one, each verified to fail with its fix reverted.

Supersedes nothing. `docs/superpowers/specs/2026-09-14-multi-org-window-design.md`
was already marked SUPERSEDED on the day it was written and answers the same
question in the opposite direction (N orgs live at once); it is not binding and
nothing in it is implemented here.

---

## 1. What this delivers

1. The window changes organisation **without quitting**.
2. A launch with no `WAKIL_ORG` set **asks for an org** instead of opening an
   inert window — the failure that raised open question 13.
3. `WAKIL_ORG` stops being read from the **process environment at the three
   child-spawn sites** — §2's table. It is the last variable still read that way;
   `WAKIL_PROVIDER` stopped being one in 2b-vi, by the same move.

   **It remains the launch seed, and that is deliberate — see §7.1.** A launch
   still reads `WAKIL_ORG` once, to decide which org the window opens in and to
   detect one that does not exist (§8.5). What ends is every *later* read: after
   launch the org is a value the window holds and passes, not a variable its
   children inherit from whatever shell started it.
4. An org can be **created** in-window, and an account already registered
   somewhere on this machine can be **adopted** into it.
5. The teardown becomes **one named contract**, which 2c-iii's terminal pane
   extends rather than rediscovers.

Item 5 is why the charter sequenced this sub-phase where it did. The blast
radius of an org change is every pane's contents, and the window has one pane
kind today against the four it will have after 2c-iii, 2c-iv and 2c-v. Designing
the teardown once, against a switch that already exists, is strictly cheaper than
retrofitting it per pane — Decision 9's finding in its general form, and the same
reason 2c-i was built before the panes that consume it.

## 2. The three reads that become parameters

`WAKIL_ORG` is read from the **process** environment in exactly three places.
Each becomes a parameter, which is the whole of the mechanism and is precisely
what 2b-vi did to `WAKIL_PROVIDER`.

| Site | Today | Becomes |
|---|---|---|
| `AppWiring.swift:346` | `if let org = environment["WAKIL_ORG"]` inside `childProcessEnvironment` | an `org:` parameter beside the `provider:` parameter already there |
| `WindowSession.swift:141` | `WakilCLICredentialsLookup(organization: environment["WAKIL_ORG"] ?? "")` | built per-org by a `lookupFactory: (String) -> ProviderCredentialsLookup` |
| `WindowSession.swift:171` | `agentMCPConfigJSON(organization: environment["WAKIL_ORG"], ...)` | `harnessFactory` takes the org alongside its `ProviderSelection` |

`WindowModel.swift:687` looks like a fourth and is not: it is *inside*
`agentMCPConfigJSON`, which already receives its org as a parameter. It needs a
caller that passes the live value, not a change of its own.

**`childProcessEnvironment`'s doc comment must be updated, not merely its code.**
It currently explains at length why `provider` is a parameter while `WAKIL_ORG`
is "forwarded from `environment` only when set". After this sub-phase both are
parameters for the same reason, and a comment still drawing the distinction would
be actively misleading to the next reader.

## 3. Restart in place, and why this is stop-then-start

`MCPClient` re-points at a new org by restarting its child process under a new
environment. Probe §2 measured the three things this rests on.

**The client does not survive a restart today, and four lines fix it.** `stop()`
lets the stdout drain thread reach EOF, which latches
`transportError = .transportClosed`; `start()` ends by sending `initialize`
through `sendRequest`, whose first act is to throw any latched `transportError`.
So a restarted client rejects its own handshake. Resetting `transportError`,
`stdoutFinished`, `stderrFinished` and `frameReader` at the top of `start()` is
sufficient, and is safe for a structural reason rather than a lucky one:
`stop()` awaits `waitForDrainToFinish()`, which does not return until both drain
threads have run their actor-isolated callbacks, so no old thread survives to
re-set the error. The reset belongs in `start()` rather than in a `restart`
method — it is a statement about what starting means, and it leaves the
started-once path byte-identical, since all four values already hold these
settings on a fresh instance.

**Re-pointing needs an entry point, not only a `var`.** `environment` is
`private let` on an **actor** (`MCPClient.swift:53`, `:56`), and Swift forbids
assigning an actor-isolated property from outside the actor — so making it `var`
is necessary and not sufficient. The probe used `restart(environment:)` for
exactly this reason (probe §2), and the spec chooses the narrower of the two
shapes: **`start(environment:)` takes the new value as a parameter**, alongside
the four-field reset above. That keeps the reset and the re-point in one place,
keeps the stop-then-start ordering at the call site where §4.3 can order it
against the invalidation, and needs no second lifecycle method. Nothing else in
`MCPClient` changes. Probe §2 confirmed a restarted `wakil-ctx` answers for its
new org: `list_providers` returned `["alpha-acct"]` before and `["beta-acct"]`
after.

(Immaterial to the argument, corrected for the next reader: `sendRequest`'s
*first* act is the `notRunning` guard (`MCPClient.swift:358`); the latched
`transportError` is thrown immediately after it (`:359`). The handshake is
rejected either way.)

### 3.1 The deliberate asymmetry with 2b-vi

`WindowModel.setProvider` uses START-THEN-SWAP and its doc comment says, in
terms, *"Do not 'fix' this back to stop-then-start."* This sub-phase does the
opposite. That is a considered asymmetry and the spec records it here so a
reviewer does not read it as an oversight.

**It is forced.** `registerStandardActions` closes its handlers over the
`MCPClient` **instances**. There is no "new client" to prove healthy before
retiring the old one without re-registering the entire action set — which is
§11's rejected approach B, in full.

**And the risk start-then-swap guards does not transfer.** A provider switch can
fail for a *provider-specific* reason: bad credentials, a missing `claudePath`, a
Keychain refusal. A server start cannot fail because of the target org — probe §3
measured `wakil-ctx` completing its handshake and advertising its full tool set
with `WAKIL_ORG` **unset entirely**. The org is not an input to whether the
process starts.

**The residual failure is narrowed, not closed**, and gets an honest degrade: a
restart that fails leaves the client `nil`, which is an already-representable
state (`WakilWiring.build` produces it for a missing binary, and every action
handler throws `StandardActionError.missingClient` naming the action and the role
it needed). The plane shows what failed and offers a retry. The window does not
claim to be in the new org: `organization` is assigned only after the restart
returns.

**Corrected 2026-09-15, by task 15's acceptance work, against the code that
actually shipped.** The paragraph above is wrong on two facts, and the fix
matters less for what it repairs than for what it rules out. `AppWiring
.switchOrg`'s own doc comment says it plainly: **a failed client is left
stopped, not `nil`** — `stop()` clears the actor's own `process`; it cannot
reach back into `registerStandardActions`'s captured `Optional<MCPClient>`
and nil it out. A subsequent handler's `guard let client else { throw
.missingClient }` therefore still sees a client and does not fire; what
actually throws is `MCPClient.call`'s own `guard let process, process
.isRunning else { throw MCPClientError.notRunning }`. So the error a caller
sees is `.notRunning`, not `.missingClient` — an honest signal, not a lesser
one, since `.notRunning` means the child process is dead and nothing
downstream of it can have executed.

**Neither error engages the uncertain-mutation machinery, and that was
verified against the code rather than argued from it.**
`recordUncertainMutation` begins `guard case StandardActionError
.mutationFateUnknown = error else { return }` (`StandardActions.swift:1727`),
so it acts on `.mutationFateUnknown` and nothing else — `.notRunning` and
`.missingClient` both pass through it as a no-op, identically. A reader could
take the paragraph above to imply that which of the two a caller sees changes
whether `recordUncertainMutation` is bypassed. It does not: there is nothing
to bypass, because neither error ever reaches its guard.
`AppWiring.swift:371-385` carries this same correction inline and is the more
precise citation for a future reader.

## 4. The switch, ordered

### 4.1 Guards

In order, before anything is torn down:

1. **Same org** — refused. ("that organisation is already open in this window")
2. **A mutation parked on the confirmation plane** — refused. It is a pending
   write decision against the *current* org's database and the operator must make
   it consciously; a switch that silently discarded it would be the one thing
   this app has been most deliberate about not doing.
3. **A turn in flight** — **queued, not refused.** See §4.2.

Guards 1 and 2 mirror `setProvider`'s wording shape so the two switches refuse in
one idiom.

### 4.2 The queued switch

An in-flight turn does not block the switch and does not get cut by default.
The switch is **accepted immediately and fires when the turn completes.**

The reasoning, recorded because it departs from `setProvider`: a provider switch
and an org switch have different stakes. Holding an operator inside org A because
org A's agent is mid-answer is the cost `setProvider` accepts for simplicity; for
an org it is the operator's whole context, and the turn's answer is worth
delivering before the thread is cleared.

**This overturns a stated cost, not only a judgement about stakes, and the
difference matters.** `setProvider`'s doc comment (`WindowModel.swift:3169-3175`)
refuses for two reasons: that the deferred decision is cheap to re-make, and that
*"a queued switch needs a deferred-state machine nothing else in this window
has."* The first is much weaker for an org than for a provider, which is the
argument above. The second is simply a cost, and this sub-phase pays it — the
machine below is that machine. It is recorded as a purchase so a later reader does
not think the objection was answered when it was accepted.

The plane offers **"stop the turn and switch now"** as an explicit cut. Taken, it
follows `setProvider`'s recorded ordering exactly: bump `eventPumpGeneration`
**before** `harness.stop()`, because `stop()` waits for stdout to become buffered
events rather than for this window to have drained them, and `Task.cancel()` does
not stop an `AsyncStream` from delivering values already buffered. The seam
records that the turn was cut short.

**A queued switch is window state, not plane state.** Dismissing the plane does
not cancel it; the status line carries it. Only Cancel cancels it.

**A turn that parks a mutation while a switch is queued** hits guard 2 at firing
time, rather than executing a write against an org the operator has already left.

**The three states the queue actually has.** A queue is a state machine or it is a
bug, so it is enumerated rather than described:

1. **Queued.** The switch fires at the first moment `turnInFlight` becomes false
   and no mutation is parked. Window state, not plane state: dismissing the plane
   does not cancel it, the status line carries it, only Cancel cancels it.
2. **Held.** Guard 2 was true at firing time. The switch stays queued with that
   message and fires when the confirmation is resolved, either way — a confirm and
   a cancel both clear the park, and the operator's queued intent survives both.
   **Held is not cancelled**: discarding it here would take the switch away at the
   moment the operator is looking at an unrelated SQL statement and has no reason
   to connect the two.
3. **Cancelled.** Only by Cancel, and only by the operator.

**A queued switch wins the next gap, and cannot be starved.** `turnInFlight` is
one flag (`WindowModel.swift:3148`, `:3259`) with no "closing" state, so the rule
has to be written rather than inferred: while a switch is queued, `send` is
**refused** with the queued switch named ("switching to *X* — cancel the switch,
or wait for it"). An operator who keeps typing therefore cannot postpone their own
switch indefinitely, and the alternative — letting the next turn start first —
makes "fires when the turn completes" a sentence with no bound on it.

**Against a provider switch.** `setProvider` refuses while `turnInFlight`
(`WindowModel.swift:3181`), so the two cannot be started together. A queued org
switch that fires *after* a provider switch has changed `providerId` is reachable,
and is correct as written: the org switch re-derives the provider from the new org
anyway (§4.3 step 6), so the intervening pick is discarded with everything else
org A owned.

### 4.3 The sequence

Once the guards pass:

1. Mark the window switching. The canvas behind the plane is visibly inert.
2. `eventPumpGeneration += 1`, then stop the harness.
3. **`invalidateForOrgChange()`** — §5.
4. Restart `wakil-ctx` and `wakil-db` under the new org's child environment.
5. Assign `organization` from the id switched to — see §6.
6. `refreshContext()`, which resolves project, environment **and the new org's
   provider**, rebuilds `rootPath`, activates the layout, refreshes the database
   chooser and restores pane contents. See §5.3 — the provider and the root are
   not free, and the sequence used to assume they were.
7. Auto-resume — §7.
8. Append the seam row naming both orgs.

### 4.4 "The five servers respawn" — the window runs four, in two ways

`phase-log.md`'s row for this sub-phase says the five servers respawn under
the new org. *(That row was `north-star.md` §8's until the charter split on
2026-09-15; §8 now carries the status table and the log carries the detail.)* **Five is the wrong surface and four is the number.** The five are
what an operator gets in a *provider config dir* from
`scripts/register-provider.sh` (`cmd/wakil/providercmd.go:58`), which is the
headless surface, not this window.

Inside the window:

| Server | Who spawns it | What the switch does |
|---|---|---|
| `wakil-ctx` | Wakil — `WakilWiring.build` (`AppWiring.swift:143`) | restarted, step 4 |
| `wakil-db` | Wakil — `WakilWiring.build` (`AppWiring.swift:144`) | restarted, step 4 |
| `wakil-pm` | the `claude` CLI, from `--mcp-config` | dies with the harness in step 2, comes back under the new org with the next one |
| `wakil-recall` | the `claude` CLI, from `--mcp-config` | same |
| `wakil-http` | **nobody — it does not run in the window** | nothing |

`agentFacingServers` is two names, not three (`WindowModel.swift:652`), and the
comment above it names `wakil-ctx`, `wakil-db` and `wakil-http` as *deliberately*
absent from the agent's config because they affect panes
(`WindowModel.swift:645-651`). The CLI-spawned pair carry the new org through
`agentMCPConfigJSON(organization:)`.

The row should be corrected so nobody goes looking for restarts that should not
exist — and §14's edit must carry *this* table rather than an earlier draft of
this section, which said three CLI-spawned servers and named `wakil-http` among
them. Replacing one wrong claim with another, in the document that is binding, is
the specific failure the correction exists to prevent.

## 5. The invalidation contract

One method, `WindowModel.invalidateForOrgChange()`, covering every piece of
org-derived state: panes, tables, editables, query-line drafts, `layoutProject`,
`loadedLayoutProjects`, thoughts, `providerId`, **`rootPath`**, the credentials
lookup, the harness — **and both stores' in-memory contents.**

Three of those — `providerId`, `rootPath` and the credentials lookup — cannot be
honoured as `WindowModel` stands today, each for a different reason. §5.3 is about
them, and is the section this contract was incomplete without.

### 5.1 A defect the switch would otherwise expose

That last item is not housekeeping. `LayoutStore.switchProject` and
`PaneStore.switchProject` both key `byProject` **by project name alone**, and
both deliberately keep the outgoing project's contents in memory so that "coming
back to a project finds it as it was left". `LayoutPersistence`, by contrast,
keys by `(org, project)`.

So the disk is safe and memory is not. Two orgs each holding a project named
`core` — unremarkable, and the likeliest case there is — would collide: switching
from one to the other would draw the first org's arrangement and the first org's
rows under the second org's name, from a different credential boundary's
database, with nothing anywhere failing. `loadedLayoutProjects`, a bare
`Set<String>`, would suppress the correct read on top of it.

This is `phase-2c-ii-b-acceptance.md`'s D3 one level up, and it is the same shape
as final review Finding 6 in 2c-i (which is why `panes.switchProject` exists at
all) — with the org substituted for the project. Clearing both stores wholesale
on an org change is the fix, and it is why the contract names them.

### 5.2 The tripwire test

The contract is pinned by a test that fails when state is **added** rather than
only when it is mishandled. `Mirror(reflecting:)` enumerates `WindowModel`'s
stored properties and compares their labels against two hard-coded lists:
org-derived (must be reset by `invalidateForOrgChange`) and org-independent
(must not be). A property in neither list fails the test, naming it.

This is the deliverable 2c-iii inherits. A terminal pane holding a PTY open in
org A's project root cannot be added without the author being told, by a failing
test, that they must classify it. Without the tripwire the contract is a comment,
and a comment is what the charter says is not good enough here.

`WindowModel` lives in `WakilKit`, which has a test target; `WindowSession` lives
in `WakilApp`, which cannot have one (`phase-2c-ii-b-acceptance.md` §3). That is
why the contract lives on the model.

**It is a NAMING test, and deliberately only that.** The paragraph above says
org-derived properties "must be reset by `invalidateForOrgChange`", which reads
like a behavioural claim and is not one: `Mirror` yields labels and `Any` values,
so what the test proves is that every stored property has been *classified*, not
that the method then honours the classification. That is the whole intended
deliverable — the failure mode being defended against is a new property nobody
thought about, not a reset someone wrote wrongly — and saying so here stops the
next reader from trusting it for more than it does. Behaviour is covered where
behaviour is always covered in this window: §12's runbook, check 3 and check 4.

**Two mechanical facts the lists must be written against.** `WindowModel` is
`@MainActor @Observable` (`WindowModel.swift:895-897`). The Observation macro
rewrites each stored property into a computed one over `_`-prefixed backing
storage and adds `_$observationRegistrar`, so `Mirror(reflecting:)` returns
`_organization`, `_project`, … plus a `$`-bearing label, with any
`@ObservationIgnored` property appearing under its plain name. Normalise — strip
one leading `_`, exclude `$`-bearing labels — rather than hard-coding the
underscored spellings, which would silently stop matching if a property were ever
marked `@ObservationIgnored`. And the lists will be long: `WindowModel` carries
on the order of eighty stored properties today, eleven of them `let`. A reviewer
meeting them for the first time in a diff should know they were expected to be.

### 5.3 Three things the sequence assumed were free

§4.3's step 6 used to read *"resolves project and environment"*. It resolves
those and the org (`WindowModel.swift:1421-1434`), and that is all it resolves.

Three properties are org-derived and none of them was actually reachable as the
contract was first written — but each for a *different* reason, which is why
naming them in a list was not enough. `providerId` was named and has nothing to
re-derive it. `lookup` was named and is a `let`. `rootPath` was neither named nor
resettable. An enumeration catches the third kind and silently passes the first
two, which is the argument for walking the property list rather than the
narrative.

**`providerId` has no path back.** It is assigned once, at window-open, from
`activeContext?.activeProvider` (`WindowSession.swift:96`) — a resolution that
happens in `WindowSession`, which `WindowModel` cannot re-run. After
`invalidateForOrgChange()` correctly clears it, nothing in steps 4-8 sets it
again. Follow that through: `startHarness` refuses an empty `providerId` outright
(`WindowModel.swift:2935`) and `resume` refuses a session whose provider does not
match (`WindowModel.swift:3093`), so **§7's auto-resume has nothing to select for
and steps 7 and 8 are unreachable.** The window would land in the new org with no
agent — reaching `WindowSession`'s honest degrade by omission rather than by
decision, and presenting as a symptom ("no agent after switching") indistinguishable
from the restart failure §3.1 warns about.

**`rootPath` is a `let` holding the outgoing org's project root.**
`WindowModel.swift:1085` — *"the directory a FRESH session runs in: the project's
first declared root"* — derived at window-open from the same `get_context` call
(`WindowSession.swift:78-92`). Unreset, a fresh session in org B launches `claude`
with org A's project root as its cwd. **Nothing fails**: `buildLaunch` takes the
path it is given. The first thing to notice is `read_session`'s refusal that a
session's cwd is not a root of the active project (`cmd/wakil-ctx/main.go:186`),
surfacing as a confusing resume failure several switches later. That is §5.1's own
shape — right on disk, stale in memory — which is why it belongs in §5 and not in
a footnote.

**`lookup` is also a `let`** (`WindowModel.swift:1072`). §2 already replaces it
with a `lookupFactory`; this records the consequence, which is that the property
itself becomes a `var` fed from that factory. A `let` cannot be reset, and this
contract is a list of resets.

**Where the two re-derived values come from.** Both `providerId` and `rootPath`
are on `get_context`'s answer, which is the call §6 is already amending — so the
fix is one more field, not a new mechanism:

- **Go:** `get_context` reports **`ActiveProvider` as well as `Org`** when it
  errors, on §6's first item's argument unchanged. Both are knowable without a resolved
  project — the provider is `active.json`'s fourth axis
  (`internal/wakilcore/active.go:24`), read from the org's own directory — and
  withholding either because a *different* resolution step failed is what makes
  the error unreadable. Without this the fresh-org case (§6's whole subject) has
  no provider for the same reason it had no org.
- **Swift:** `refreshContext` assigns `providerId` and rebuilds `rootPath` from
  the same answer it already reads project and environment off, and its `catch`
  clears both rather than keeping another org's.

**When the new org has no active provider** — a fresh org, or one that has never
run a switch — the window says so and offers ⌘P, which is
`WindowSession.swift:110-140`'s existing note reached deliberately this time. The
operator picks an account and the window works; auto-resume is skipped with the
note §7 already specifies for "when there is none".

### 5.4 The restored canvas has to be *filled*, not only arranged

§5.1 is about the canvas being cleared, and §12 check 3 states the other half:
"panes clear, the new org's canvas is restored from disk, **each `db` pane's
subject re-runs live**." The second clause is a separate mechanism from the
first, and it was not wired.

A layout file persists the pane's *subject* and never its rows, deliberately —
redrawing yesterday's rows would show a database state that may no longer exist,
which is the dishonesty `truncated` and the sort footer exist to prevent. A
loaded layout is therefore a set of panes with a frame, a title and a query and
nothing in them, and something has to run the query. `restorePaneContents()` is
that something. It existed, it was correct, and it had three callers —
`WakilWindow` at launch, `setEnvironment`, and the observation pump's
`ctx_set_environment` branch. The org switch reaches `activateLayout()`, which
was none of them.

The failure is silent by construction. `restorePaneContents` swallows per-pane
failures so that one dropped table cannot stop the others, which means a refetch
that never ran is indistinguishable on screen from one that came back empty:
every restored pane read "no rows". Not an error, not empty-because-empty. The
walk found it in checks 3, 5, 8, 12 and 13 at once, and the operator's journal
settled it — zero `db_refetch` rows after any org switch, in a session with
several.

**The rule.** `activateLayout()` re-runs the restored subjects, **gated on the
layout having genuinely been read from disk**, not merely on the method running.
`LayoutStore`/`PaneStore` keep an outgoing project's contents in memory so that
coming back to a project finds it as it was left — a property earlier sub-phases
accepted and tested — and re-running every subject on an in-memory return would
quietly repeal it. Only a read from disk produces panes that hold no rows to
begin with, and only that case needs filling.

## 6. `get_context` will not tell you which org you are

Probe §4 is the finding that changed this design, and it needs **both** halves.

In an org with no active project, `get_context` returns `isError: true` with
`"Org":""` — though the server knows perfectly well which org it is, the value
being in its own environment. Follow that through the window:
`ContextStore.callChecked` throws on `isError`, and `refreshContext`'s `catch`
sets `status` and **returns without touching `organization`, `project` or
`environment`**.

So switching into an org with no active project — a fresh org, the common case
and the first one a new operator meets — would leave the bottom edge reading
`org: initech` while every spawned child runs as `umbrella`, every Keychain lookup
resolves under `umbrella`, and the write gate judges `umbrella`'s environment. The
window would be drawing **the wrong credential boundary**, which is Invariant 4's
own subject.

1. **Go:** `get_context` reports `Org` **and `ActiveProvider`** even when it
   errors. The org comes from `CurrentOrg()` and is knowable whenever the process
   started at all; the provider is `active.json`'s fourth axis, read from the org's
   own directory (`internal/wakilcore/active.go:24`). Withholding either because a
   *different* resolution step failed is what makes the error unreadable. The
   provider half is what §5.3 needs, and it is the same sentence twice rather than
   a second mechanism.
2. **Swift:** `setOrganization` assigns `organization` from the id it switched to,
   before `refreshContext` runs. That value is authoritative in a way
   `get_context`'s answer is not — it is the string Wakil itself put into the
   child environment. `refreshContext`'s `catch` additionally **clears `project`,
   `environment`, `providerId` and `rootPath`** rather than keeping another org's.

Neither is optional. With only the first, a `get_context` that fails for some
other reason still leaves a stale org on screen. With only the second, the
headless surface stays mute.

**Be exact about which caller the Go half serves, because the neighbouring
sections get this wrong when it is left vague.** One beneficiary is the
**headless** surface — a plain `claude` session started in a provider config dir,
which `scripts/register-provider.sh` wires to all five servers
(`cmd/wakil/providercmd.go:58`). It is *not* the in-window agent: there is no
`ctx_get_context` action (`ContextStore.swift:38`), and the agent cannot reach
`wakil-ctx` at all, since `agentFacingServers` publishes only `wakil-pm` and
`wakil-recall`. The other beneficiary is the window itself — see §6.3, which
corrects what this paragraph used to say.

> **Superseded ruling, kept visible.** This paragraph previously concluded that
> the Go half "moves nothing on screen", on the reasoning that
> `ContextStore.callChecked` throws on `isError` before anything parses `Org` —
> and then treated that as the design rather than as the bug it was describing.
> The observation was correct and the conclusion was backwards: Swift discarding
> a payload Go went to the trouble of reporting is not a fact to design around,
> it is the defect §6.3 fixes. Recorded rather than deleted because a reader who
> only saw the corrected text would not know the trap was there.

### 6.3 A launch is not a switch, and the error still answers

§6.2 above is written entirely in terms of `setOrganization` — "the caller
assigns `organization` from the id it switched to, before `refreshContext` runs".
That is true, and it is why `refreshContext`'s `catch` deliberately left
`organization` alone. It is also **the only path §6 considered**.

`organization` is assigned in exactly three places: `refreshContext`'s *success*
path, and `setOrganization`'s two. A **launch** takes neither. There is no
`setOrganization` on the way into the first org — `WAKIL_ORG` reaches the child
environment and `CurrentOrg()`, never the window's own field — and an org with no
active project never reaches the success path, because that is precisely the case
§6.1 exists for.

So, before this amendment, launching into an org with no active project produced
a window with `organization == ""`. `WakilWindow`'s `hasOpenOrg` reads that as "no
organisation is open" and force-opens the org plane, undismissable, per §8.5 —
which is correct behaviour for the state it was told about and wrong about the
state that actually held. The operator saw it as a per-org quirk: `WAKIL_ORG=initech`
opened the chooser, `WAKIL_ORG=personal` did not, and the only difference between
those two orgs is that one of them happened to have a project active.

The same discard cleared `providerId` even where `active.json` named one, which
stops `autoResumeAfterSwitch` at its opening `guard !providerId.isEmpty` — no
agent, no session, and no message saying why. That is §5.3's own subject, failing
in the exact case §5.3 was written for.

**The rule.** `ContextStoreError.serverError` carries a `PartialContext` — the
`Org` and `ActiveProvider` the error already reported — and `refreshContext`'s
`catch`:

1. assigns `organization` from the partial **only when it is still empty**. §6.2's
   ruling stands where it applies: an id `setOrganization` put into the child
   environment outranks what `get_context` reads back. They cannot disagree; the
   condition exists so that the switch path keeps its authority and the launch
   path stops having none.
2. assigns `providerId` from the partial rather than clearing it.
3. **rebuilds `lookup` for whatever `organization` now holds.** The success path's
   own comment explains why every credential resolution in the window's life
   depends on this object being built for the right org (it is the final fix
   pass's Critical 1). A branch that can now *learn* the org must rebuild it too,
   or it reintroduces that Critical one path over. Fail-closed is unchanged: when
   the partial knows no org either, this rebuilds the `""` lookup, which hands out
   no org's credentials at all.

`project`, `environment` and `rootPath` are still cleared, unchanged from §6.2 —
those genuinely are another org's values and keeping them is the confidently-drawn
wrong boundary that section exists to prevent.

## 7. Auto-resume on return, and the charter amendment it requires

**Returning to an org resumes its most recent session.** This amends
`north-star.md` §7 open question 5, closed 2026-09-07 as *always start fresh,
with resume as a visible enumerated action, never a default.*

**The amendment, and why it is narrow.** q5 was decided about **launching the
app**. Returning to an org you left ten minutes ago is a different event, and the
sub-phase that creates it did not exist when q5 was written. Decision 12's
concern — that long-lived sessions drift undebuggably — is answered by 2b-v's
mechanic rather than waived: a resume is a **fork**, minted under a fresh
Wakil-assigned `--session-id` with lineage recorded through
`record_session_parent`. A chain of org switches therefore produces a chain of
short sessions with a readable lineage, not one long session that drifts. "Wakil
assigns the id" stays literally true.

**What it inherits.** A session belongs to a provider: transcripts live under the
provider's own config dir (`sessions.go`'s `providerSessionsRoot`), and a
different account's `claude` cannot read them — which is why
`resume(sessionId:)` already refuses a session belonging to another provider. So
auto-resume selects the newest session **for the org's active provider** whose
`cwd` is a root of the active project, and falls back to a fresh session with a
note when there is none, when the provider has changed, or when the resume fails.
A switch never lands the operator in a dead window.

**It starts a session; it does not spend anything.** Auto-resume mints a session
and rebuilds the thought thread. No turn is sent and no tokens are consumed until
the operator types. The spec says this plainly because "switching orgs silently
started an agent" is a reasonable thing to be alarmed by on first reading.

### 7.1 The switch does not survive a relaunch, and that is a decision

`org-switch-probe.md` §6 leaves this open by name, and correctly calls it a ruling
rather than a measurement: *"Whether the app should remember its last org across
launches is untouched by this probe — it is a ruling about Invariant 4's scope,
not a fact to measure."* **Ruled 2026-09-15: it does not. The switch is
session-scoped, and `WAKIL_ORG` remains the launch seed** (§1, item 3).

So: switch to org B, quit, relaunch, and the window opens in whatever `WAKIL_ORG`
the launcher declares — which for `open app/Wakil.app` with nothing set is §8.5's
plane, asking.

**Why not the other way, given `setProvider` persists its pick.** The asymmetry is
real and the reason is that the provider had somewhere to go and the org does not.
`ctx_set_provider` writes `active.json`'s fourth axis so the pick outlives the
window — but `active.json` lives *under* `OrgDir()`
(`internal/wakilcore/active.go:31-37`), which means a per-org file cannot record
which org is active. Persisting the org needs a new machine-level record outside
every org, plus a stated precedence rule for when a stored value and an exported
`WAKIL_ORG` disagree. That is a real design with an Invariant 4 argument on both
sides, and this sub-phase — which has already grown twice on operator rulings
(§8.1, §7) — is not where it gets decided in passing.

**What it costs, stated so it is a choice and not a gap.** An operator who lives
in two orgs re-picks on each launch, or exports `WAKIL_ORG` in the launcher as
they do today. §12's check 13 walks it once so the behaviour is observed rather
than assumed, and §13 carries it as an open item rather than a silent one.

## 8. The plane

One surface on ⌘⇧O — free, verified against the five chords the window already
binds (⌘↩, ⌘W, ⌘⇧D, ⌘P, ⌘K) — built as `ConfirmationPlane.swift` is built, on
`design-language.md` §3's **near** plane (*"holds only what rises out of"* the
room). Cited that way rather than as "§3's plane idiom": §3 is the depth model,
far/mid/near with a treatment for each, and it specifies where a surface sits, not
how a modal one is composed. The composition precedent is the confirmation plane
itself. It is deliberately **not** a fourth ⌘P
source: an org change is a credential-boundary change, and burying it among
ordinary picks would give it the weight of choosing a project.

| State | Contents |
|---|---|
| **Choosing** | One row per org: display name (falling back to the id), then id, Jira site or "no Jira site", account count — §8.1.1. The current org is marked and not selectable. The row's primary action is the **switch**; adoption is a secondary affordance on it — §8.6.1. **Always ends with a "new organisation" affordance** — see §8.1. |
| **Creating** | name, identifier (derived from the name, editable), Jira base (**optional**) — §8.1.1. No default-provider field — §8.3. |
| **Adopting** | Accounts registered anywhere on this machine: `org/provider`, config dir, kind, label — each adoptable under an **editable id**, defaulted to the source id, because an id is unique per org and a collision is otherwise a dead end (§8.4). An explicit empty state when every account is already registered in the target org. |
| **Switching** | Progress. The canvas behind is visibly inert. |
| **Queued** | "switching to *X* when this turn finishes" · Cancel · Stop the turn and switch now. |
| **Error** | A failed restart, named, with a retry. |

### 8.1 Creation is always reachable, and there is no empty state

The "new organisation" affordance is a permanent part of the choosing state, not
a mode the plane falls into when the list is empty. An operator with three orgs
can create a fourth without leaving the window.

This also removes a state rather than adding one. An earlier cut of this design
had a separate **Empty** state for a machine with no orgs; with creation always
present, "empty" is simply the choosing state with zero org rows, and one mode
transition that existed only to answer a question the list already answers
disappears.

### 8.1.1 The org has a name as well as an id, and the plane shows both

**Added 2026-09-15, after the first operator walk.** The operator typed
`test org` into the identifier field and got Go's refusal — *"an org id must
start with a letter or digit and contain only letters, digits, dot, dash or
underscore"* — and asked the right question: why are we not allowing spaces?

The id is not a name. It is a directory (`~/.wakil/orgs/<id>/`), the org
component of a Keychain service name (`wakil:<org>:provider:main`, where a colon
would collide with the next field), the `WAKIL_ORG` value handed to every child
process, and `--org <id>` in `scripts/register-provider.sh`. `validateOrgToken`'s
own comment records that `security` *accepts* a space, so the ban is conservative
rather than forced — but loosening it would put spaces into four places that
would then need quoting forever, to buy something Wakil already has.

Because it does already have it: `Org.DisplayName` exists, and the operator's
own orgs use it — `initech` is *"Initech Labs"*, `umbrella` is *"Umbrella"*. Two gaps hid
it, and together they are why a space in the id looked like the only way to get
a readable name:

- **`OrgSummary` drops it.** `ctx_list_orgs` returns `{id, jiraBase, accounts}`,
  so the plane renders raw ids and the display name is invisible in the one place
  an operator reads the org list.
- **`createOrgArgs` lacks it.** `create_org` takes `{id, jiraBase?}` only, so an
  org created in-window can never have a display name at all, while
  `wakil org create --display NAME` can. The in-window route is the poorer one,
  which inverts §8.1's whole argument for having it.

So `DisplayName` is carried through both: added to `OrgSummary` and to
`createOrgArgs`. The creation form takes a **Name** ("Initech Labs") and shows the
**identifier** beneath it as a derived, editable slug (`initech-labs`) — the same
shape as every tool that has both, and it makes the id's constraint legible at
the moment it applies rather than as a refusal after submitting. The choosing
list leads with the display name and carries the id as secondary detail beside
the Jira site, so the thing an operator recognises is the thing they read first.

This keeps the id strict, which is what the four consumers above need, and stops
the strictness being the operator's problem.

### 8.2 Jira is optional, and the plane makes the omission visible

`normaliseOrg` validates `JiraBase` only when it is non-empty, so an org without
one is **already** legal in Go and no capability change is needed.

What it is not is *visible*. `operator-todo.md` records the correction learned by
running the procedure: `wakil org create` "accepts no `--jira-base` silently, and
the omission does not surface until the first Jira call — check
`cat ~/.wakil/orgs/<org>/org.json` after Step 2." A flag cannot show you what you
did not type. A form can: the field is marked optional, and every org without one
reads **"no Jira site"** in its row, so the omission is legible from the list
instead of being discovered much later as a confusing Jira failure.

### 8.3 The creation form does not re-implement Go's validation — and has no default-provider field

It submits and renders the refusal **verbatim**. `normaliseOrg` already enforces
absolute-https with no userinfo, query, fragment or path, and that
`defaultProvider` names a provider actually registered under the org. A Swift
copy of those rules would be a second implementation of one rule, which is
exactly the failure the design review's §H found between `writeGate` and
`VoidPalette.forEnvironment` — two implementations agreeing to stay in step until
they quietly did not.

**Which is exactly why the form must not offer a default provider at creation
time.** An earlier cut of §8 listed it as an optional third field. Rendering Go's
refusal verbatim is right; applied to that field it would render a refusal
*every single time*, because Go refuses it by construction. `CreateOrg`'s own doc
comment (`internal/wakilcore/org.go:89-95`):

> One consequence: `wakil org create <org> --default-provider X` can never
> succeed, because X cannot already be registered under an org that does not exist
> yet. That is intentional …

Enforced at `org.go:170-176`, where `normaliseOrg` calls
`LoadProviderFor(org, o.DefaultProvider)` and returns its *"no provider … —
register it with: `wakil provider add`"*. A field whose every use creates nothing
and returns an error about registering providers is worse than no field: it
teaches the operator that creation is broken, at the first moment they use the
surface this sub-phase exists to build.

This is §8.2's reading applied one row down. §8.2 caught the Jira case — *a flag
cannot show you what you did not type; a form can* — and the same question asked
of the neighbouring field answers itself.

**Where it goes instead.** `SaveOrg` (`org.go:122`) carries no such constraint, so
a default provider is settable the moment an account exists under the org. That
belongs with the Adopting state, not the Creating one, and it is deliberately
**not scheduled here**: it needs a `set_org_default_provider` on `wakil-ctx` and a
sixth tool is scope this sub-phase does not need. §8.7's forward pointer covers
the same ground — the affordance grows, the plane does not get redesigned.

### 8.4 Adoption shows the warning the CLI already prints

`wakil provider add --share` prints that the config dir still pins `WAKIL_ORG`
for a plain `claude` session started there, so such a session runs as the
**homing** org, and that only *inside Wakil* does it run as this one. The plane
shows the same thing. Hiding it would make `--share` feel like a move rather than
a binding, which is the one thing about shared accounts that is genuinely
surprising.

#### 8.4.1 The id is editable, because it is unique per org

**Amended 2026-09-15, after the first operator walk.** As first built, the plane
registered an adopted account under the id it carries at its home org, with no
way to change it. A provider id is scoped to one org's directory
(`~/.wakil/orgs/<org>/providers/<id>.json`), so it is unique *per org* and
collides across them freely — and the conventional id is `main`, so on a machine
where every org's account is called `main`, adopting into any org that already
has one fails with `provider "main" already exists in org "<target>"` and there
is no way forward from that screen. The operator hit this on the first attempt,
in both directions, and in-window adoption was unreachable for them entirely.

The CLI never had this problem: `wakil provider add <id> --share` names the id
positionally, so choosing a free one is the normal gesture. The plane takes the
same input — an **editable id, defaulted to the source row's**, labelled as the
name the account will carry *in the target org*, not a rename at its home.

Rows whose id already exists in the target are **not** filtered out. That case is
exactly what the field is for, and a silently shortened list would answer a
collision by hiding the account.

Where there is nothing to adopt — every account on the machine already registered
in the target org, which is an ordinary state for an operator's main org — the
plane **says so**. Rendering an empty list as a blank gap reads as a broken
screen, and the operator read it that way.

#### 8.4.2 Adopting binds an account and does not carry its credential

An adopted account cannot start a session until its token is stored **in the
adopting org**. `ProviderTokenRef` is org-scoped by construction: a binding
`initech-main` registered in `personal` reads `wakil:personal:provider:initech-main`, an
item that does not exist merely because `wakil:initech:provider:main` does.

**This is Invariant 4 working, not failing.** An organisation is a credential
boundary; a plane that copied a token across one to be helpful would be putting a
hole in the invariant this whole sub-phase exists to serve. The rule is right and
stays.

What was wrong is that nothing said so at the moment it mattered.
`internal/wakilcore/provider.go` has carried the sentence in a comment since the
shared-accounts sub-phase — "Registering the share is half the job" — and the
plane, which is the only surface an operator meets, never repeated it. So the walk
went: adopt an account, watch the row appear in ⌘P, pick it, and meet `no
credential stored for ref provider:main in org test-org` several screens later,
with no way to connect that message back to the step that caused it. §8.6.1's own
text reads as though adoption alone makes an org usable, which compounded it.

**The rule.** After a successful adoption the plane names the remaining step and
the exact command, with the id the adoption actually used — not a generic id,
since §8.4.1 lets the operator choose one, and a generic sentence would name the
wrong ref about as often as the right one. Shown only after adopting, because
before that there is nothing to name.

Registering the credential in-window is out of scope here for the same reason
"Register a new account" is: it means taking a secret through the window, which
is its own design with its own threat model. §15 carries it.

### 8.5 Dismissal, and the org-less launch

The deliberate switch takes Esc. The org-less launch does not — there is nothing
behind it to use. The plane also opens, with the reason named, when `WAKIL_ORG`
is set but names an org that does not exist, instead of today's inert window.

**The room behind an org-less launch has no colour in it, and that is a ruling
rather than a style note.** `design-language.md` §2 states that "the environment
alone owns which two colours are in the room, and `VoidPalette` is never touched
by state". Before an org is chosen there is no active project, therefore no
environment, therefore nothing that owns a hue.

The alternative is not neutral, which is why this needs deciding rather than
defaulting. `VoidPalette.forEnvironment` (`VoidPalette.swift:61`) branches only on
`isProductionEnvironment`, so it answers an **empty** environment string with the
ordinary violet/blue pair — the same room `staging` gets. An org-less window that
consulted it would therefore assert, in the one channel Invariant 8 reserves for
exactly this, that the operator is in an ordinary non-production environment. They
are in no environment at all. That is a small lie told by the most reliable
signal in the app, at the first surface a new operator ever sees.

So the org-less launch renders the field, the vignette and the grain, and **no
bleeds at all** — the room is not yet anybody's. `VoidPalette` is not consulted,
rather than consulted with an empty string: the render path takes an *optional*
palette, and `nil` means "draw no bleeds". Deliberately **not** a third
`VoidPalette` case — an uncoloured room is the absence of a colour decision, and
giving it a palette value would put one back in, which is the shape of the §H
failure this spec already cites twice.

This settles what `docs/wakil/screens/canvas.json`'s `uncoloured-room` annotation
raised as a proposal against an earlier cut of this section, and
`OrgFirstRun.dc.html` renders it.

**Esc has to arrive through a path that does not need focus.** The first
implementation used SwiftUI's `.onExitCommand`, which on macOS delivers only to a
view in the key window's first-responder chain. This plane is an ordinary `ZStack`
child of `WakilWindow` and never takes focus — nothing in Choosing is focusable at
all — so the handler was correct and simply never received the key. The walk found
a plane whose own footer read "Esc to dismiss" above an org that Esc would not
leave: worse than no affordance, because the window stated one.

A `.keyboardShortcut(.cancelAction)` control binds Escape through the window's
key-equivalent path, which is focus-independent and keeps working while a
TextField in Creating or Adopting holds focus. It must be **rendered** (zero-size
and transparent) rather than `.hidden()`, since a hidden view leaves the
key-equivalent search along with everything else.

`canDismiss` is checked in the action rather than by omitting the control, so an
org-less plane **swallows** Esc deliberately — there is nothing behind it to
return to — instead of letting the key fall through to whatever is underneath.

**A window may hold exactly one live `.cancelAction` at a time, and the
front-most plane owns it.** Binding Escape focus-independently is what made it
reachable and also what made it collidable: `ConfirmationPlane` claims
`.cancelAction` too, and AppKit resolves a key equivalent by searching the view
tree and taking the first match — an arbitrary winner, not the front-most one.
The walk found the consequence immediately: with a mutation parked and the org
plane opened over it, Escape cancelled the **mutation behind the plane the
operator was looking at**. Cancelling an unrelated, invisible confirmation is the
worst available outcome for a key pressed to dismiss something else.

So `ConfirmationPlane` takes an `ownsEscape` flag and surrenders its key
equivalent — never its Cancel *button*, which stays clickable for an operator who
dismisses the org plane first — whenever the org plane is on screen. The flag is
computed from the same predicate `WakilWindow` mounts the org plane with
(`showOrgPlane || organization.isEmpty`), read from the same model, so the two
cannot disagree about which plane the operator is looking at. `Palettes` also
binds `.cancelAction` and does **not** need this: it is presented in a `.sheet`,
which is its own responder scope, and a sheet is front-most by construction.

This generalises: any future plane that binds Escape joins this ordering
explicitly or does not bind it at all. `DBPane` already carries a standing "no
`.keyboardShortcut` on this view, ever" rule for the neighbouring reason.

### 8.6 How the states connect

The table above names the states; this names the edges. Neither the first cut of
this section nor its revision specified them, which left the plane's most
ordinary flow — create an org, put an account in it — undefined.

| From | To | On |
|---|---|---|
| *(entry)* | **Choosing** | ⌘⇧O, or a launch with no org (§8.5) |
| Choosing | **Creating** | the always-present "new organisation" affordance (§8.1) |
| Creating | **Adopting**, for the org just created | a successful `create_org` — skippable |
| Choosing | **Adopting**, for any org | that row's **secondary** adopt affordance — §8.6.1 |
| Adopting | **Choosing** | done, or skipped |
| Choosing | **Switching** / **Queued** | **that org's row** — the row's primary action (§4.1) |

#### 8.6.1 A row's primary action is the switch, not adoption

**Amended 2026-09-15, after the first operator walk.** As first written, this
table sent a row click to **Adopting**, and the switch was reachable only from a
button *inside* that screen. That is the wrong default, and walking the runbook
proved it within minutes: the operator clicked `personal` to open `personal`,
landed on "adopt an account into personal" — a screen they had not asked for,
for a question they had not raised — and had to find "Switch to personal now"
to do the thing the click meant. They had in fact predicted this during design
("it's done in two steps?") and the objection was not taken.

The plane's subject is **which organisation this window is in**. A row names an
organisation; clicking it means *go there*. Adoption is a different verb on the
same noun, and a rarer one — an operator switches orgs many times a day and
adopts an account into one perhaps twice in its life.

So: **the row's primary action is the switch.** Adoption stays reachable from
the row as a secondary affordance, which preserves the requirement the paragraph
below establishes — that per-org adoption must have a home in the window, since
⌘P can only list accounts already registered in the *active* org.

The edge from **Creating** is unchanged: a freshly created org has no accounts,
so chaining into Adopting is still the right move there, and it is still
skippable.

**Creation chains into adoption, because a created org always has zero
accounts.** §8.3 removed the default-provider field, and that field was never an
account route anyway — it set `org.json`'s `defaultProvider`, which must name a
provider already registered under the org. So a newly created org is guaranteed
to hold no accounts and to be unable to run an agent until one is adopted.
Returning the operator to a list at that moment would hide the only thing the new
org certainly needs.

**The chain is skippable**, because creating an org to use later is legitimate.
An org left with no account opens with `WindowModel.noActiveProviderNote` already
on screen naming the fix, which is the degrade 2b-vi built for exactly this.

**Adoption is also reachable per-org, and that edge is not a convenience.**
Adding a second account to an org that already exists has no other home in the
window: ⌘P's provider picker lists accounts *registered in the active org*, so an
account that has never been adopted cannot appear there. Without this edge that
case returns to the CLI — the dead end this sub-phase exists to close. It also
covers adopting into the **current** org, where no switch is involved at all: the
account simply becomes available to ⌘P.

**Neither creating nor adopting ever switches the window on its own.** The plane
*offers* it — and only when the affected org is not already the current one. An
org switch tears down every pane, the thought thread, the active project and every
Keychain reference in flight (§4.3, §5); making that the unrequested side effect
of a gesture the operator made to *create a record* would be a large consequence
from a small act, and it would fire the teardown path on a window with work in it
without being asked. The switch stays what §4.1 describes: a thing the operator
selects.

### 8.7 Forward compatibility for provider registration

The adopting state ends with an "add a new account" affordance that today
explains the CLI path. When Decision 21's costed half is scheduled, that
affordance becomes a form — an addition to one state, not a redesign of the
plane. This is recorded because the row is expected, not hypothetical.

## 9. New Go capabilities

**Four new tools on `wakil-ctx`, and one amendment to a tool that already
exists.** The distinction is load-bearing and an earlier cut of this section lost
it, stating two rules over "all five" that are false of the fifth — in one case in
a way that would have cost §6 entirely. They are separated here for that reason.

### 9.1 The four new tools

| Tool | Does |
|---|---|
| `list_orgs` | Every registered org: id, Jira base, account count. |
| `create_org` | Wraps `CreateOrg`; returns its refusal verbatim. |
| `list_machine_providers` | Every `(org, provider)` on the machine: id, kind, label, config dir, homing org. |
| `adopt_provider` | `AddProvider(org, p)` with `Shared: true` against an existing config dir. |

**None of these four may call `CurrentOrg()`.** This is probe §3's stated
condition, and it is the whole reason they can live on `wakil-ctx` at all: the
server starts happily with no org and fails only on the *calls* that need one. A
`list_orgs` that demanded an org would rebuild the dead end inside the surface
built to end it. Each has an org-parameterised function to build on —
`ListOrgs()` reads `~/.wakil/orgs/` (`org.go:195`), `LoadOrgFor(org)`
(`org.go:53`) supplies the Jira base and `ListProvidersFor(org)`
(`provider.go:633`) the account count — so the rule costs nothing to keep.

**All four join `operatorOnlyActions`**, for two different reasons that are worth
separating rather than blurring:

- **`create_org` and `adopt_provider`** are the strong case. An agent that could
  create an org or bind an account into one could move Invariant 4's own
  boundary. The refusal is the same mechanism that already denies
  `ctx_set_provider` and `session_set_provider`, with a message in the same shape.
- **`list_orgs` and `list_machine_providers`** are the weaker case, and it is
  stated plainly rather than inherited by association: they move no boundary, and
  reading across orgs is established practice (probe §5 — `provider add` has
  always done it; #25's `--share` made cross-org binding explicit). They are
  denied because enumerating every org and config dir on the machine is not
  something a session scoped to one org has any business doing, not because
  reading across orgs is itself suspect. Both halves of that are true at once, and
  the section used to argue only the half that suited each paragraph.

**The two cross-org reads return ids, paths and labels — never a credential.**
This inherits the rule `ctx_list_providers`' own description already states.

### 9.2 `get_context` is amended, not added — and neither rule above applies to it

Amended per §6 to report `Org` and `ActiveProvider` even when it errors.

**It stays reachable, and it keeps its `CurrentOrg()` call.** Both §9.1 rules
would be actively wrong here:

- It **cannot** join `operatorOnlyActions`, and there is nothing to add if it
  tried. That set holds *action* names (`PermissionPrompt.swift:74`), and reading
  the context is deliberately not an action — `ContextStore.swift:38` and
  `WindowModel.swift:1410` both say so, because Invariant 2 governs mutation paths
  and this is a read. More to the point, it is how the window reads its own
  context: `refreshContext` calls it (`WindowModel.swift:1422`), which is §4.3's
  step 6.
- It **must** call `CurrentOrg()`. That is the entire Go half of §6 — the org is
  knowable whenever the process started at all, and reporting it is the fix.

Read the §9.1 prohibition as scoped to the four new tools, which is where probe §3
scoped it. An implementer who applied it here would skip the §6 amendment and
reintroduce the wrong-credential-boundary bug the probe exists to have found.

## 10. Not in scope

- **Registering a brand-new provider**, including storing an OAuth token. That is
  Decision 21's costed half and the first Keychain **write** from Swift. It is
  expected to get a row of its own; it does not get one here. §8.7 keeps the
  plane ready for it.
- **N orgs live at once.** Superseded, and it multiplies per pane rather than per
  org.
- **Org removal or editing in-window.** `wakil org rm` is destructive and refuses
  non-empty orgs for reasons that do not translate to a click.
- **One window per org.**

## 11. Approaches rejected

**B — rebuild the assembly.** Switching drops the whole `WakilWiring` and builds
a fresh one, so invalidation is by construction and a new `PaneStore` cannot hold
the old org's rows. Rejected: `WindowModel` holds six of those as `let`, the
socket server was built against `wiring.mcpSurface`, and the entire action set
must be re-registered because the handlers captured the old clients. It amounts
to relaunching the window without relaunching the process, in files 2c-iii will
also touch.

**C — an `OrgScope` value** owning everything org-derived, swapped wholesale.
Rejected for a narrower reason: the handlers' captures mean a scope swap still
forces re-registration, so it pays most of B's cost for part of B's benefit.

The safety B buys is recovered instead by §5.2's tripwire, which is the cheaper
half of B's guarantee without B's diff.

## 12. Acceptance

A walked runbook, `docs/wakil/phase-2b-viii-acceptance.md`, verified in the
journal and on disk rather than from the window alone — the standard
`permission-prompt-acceptance.md` set.

1. Launch with no `WAKIL_ORG`: the plane opens; the window is not inert.
2. Launch with `WAKIL_ORG` naming an org that does not exist: the plane opens
   with the reason named.
3. Switch with panes open: panes clear, the new org's canvas is restored from
   disk, each `db` pane's subject re-runs live.
4. **Two orgs each holding a project of the same name**, switched between — pins
   §5.1's collision directly. This check exists because the defect is invisible:
   both orgs draw something, and only the rows say which.
5. A turn in flight: the switch queues, and fires when the turn completes.
6. The same, with "stop the turn and switch now": the turn is cut and the seam
   says so.
7. A mutation parked: the switch is refused. **And, parked while a switch is
   queued:** the switch is held, not cancelled, and fires when the confirmation is
   resolved — walked both ways, confirm and cancel (§4.2 state 2).
8. Auto-resume rebuilds the thread and records lineage.
9. Auto-resume after an account switch: no cross-provider resume; a fresh session
   with a note.
10. An org created in-window, **with no Jira base**, verified in
    `~/.wakil/orgs/<id>/org.json`, and reading "no Jira site" in its row.
11. An account adopted: `providers/<id>.json` carries `shared: true`, and the
    homing org's pin is untouched.
12. `production` survives the round trip: the badge alarming, the gate blocking.
13. **Switch, quit, relaunch** — the window opens in the launcher's org, not the
    switched-to one. Pins §7.1's ruling as observed behaviour rather than an
    assumption, and is the check that would catch it if someone later makes the
    switch persist without saying so.
14. **Switch into an org with no active project.** §6's motivating case, and the
    first org a new operator meets — checks 1 and 2 cover launching without an org
    and with a bad one, and neither covers arriving in a good org with nothing
    selected inside it. The bottom edge must read the org switched *to*, the
    project and environment must be empty rather than the previous org's, and the
    window must say what it needs.
15. **Switch into an org with no providers registered at all.** The state
    `WindowSession.swift:110-140` was rewritten for in 2b-vi, reachable for the
    first time without a relaunch. No agent, the reason on screen, ⌘P offered —
    and, per §5.3, no crash and no silent empty `providerId`.

## 13. Risks and what stays open

- **The restart's failure window is narrowed, not closed** (§3.1). The degrade is
  honest and retryable, but a window whose clients both failed to come back is a
  window with no capability layer until the retry succeeds.
- **`wakil-db` mid-fetch was not measured.** Probe §6 says so explicitly: the
  restart was measured against `wakil-ctx` only. The mechanism carries — same
  type, same transport — but what happens to a pane whose fetch is in flight when
  its client restarts under it does not carry automatically. §4.3 orders the
  invalidation before the restart for this reason, and check 3 exercises it.
- **The credentials lookup was not exercised** by the probe either
  (`WakilCLICredentialsLookup` bakes `organization:` in at construction). §2 makes
  it a factory; no measurement backs that yet.
- **Where org creation lives is now answered; where provider registration lives
  is not.** Open question 14 closes with this sub-phase (§8.1); Decision 21's
  credential half stays unscheduled.
- **The org is not remembered across launches** (§7.1). Ruled, not overlooked —
  but it is a cost carried rather than paid off: an operator who lives in two orgs
  re-picks on every launch. Persisting it needs a machine-level record outside
  every org and a precedence rule against an exported `WAKIL_ORG`, and that
  belongs to whichever sub-phase is willing to argue Invariant 4's scope properly.
  Check 13 pins today's behaviour so the day it changes is a decision.
- **Setting an org's default provider has no in-window route** (§8.3). Creation
  cannot take one — Go refuses it by construction — and `SaveOrg` can, but that
  needs a `set_org_default_provider` this sub-phase does not add. An org created
  in the plane therefore has no declared default until it is set from the CLI.
  Small, and named here so it is not discovered as a gap.
- **The tripwire proves classification, not behaviour** (§5.2). A property added
  without being classified fails the test; a property classified as org-derived
  and then not actually reset does not. Checks 3, 4 and 14 are what stand behind
  the resets themselves.

## 14. Edits this sub-phase makes to the charter

Consolidated so the implementer does not have to reconstruct them from the
sections above. Every one is an edit to `north-star.md`.

| Where | Edit |
|---|---|
| §7 q5 | **Amended.** Fresh-by-default gains one exception: returning to an org auto-resumes. Record §7's reasoning — q5 was decided about *launching the app*, and a resume is a fork under a fresh Wakil-minted id with recorded lineage, so Decision 12's drift concern is answered rather than waived. |
| §7 q13 | **Already closed** on 2026-09-14. No edit beyond pointing at this spec. |
| §7 q14 | **Closed.** Org creation lives in the org plane — the surface q14 itself predicted this sub-phase would create. Provider *registration* is explicitly not closed with it. |
| §6 Decision 21 | Note that its near-free half (creating an org from the window) shipped here, and that its costed half — credential entry, the first Keychain write from Swift — remains unscheduled. Its stated ordering held: the provider picker's Keychain read landed first, in 2b-vi. |
| §8, the 2b-viii row | Correct "the five servers respawn" per §4.4, **from that section's table and not from memory**: the window runs **four** — `wakil-ctx` and `wakil-db` restarted by Wakil, `wakil-pm` and `wakil-recall` respawned with the harness, and `wakil-http` not running in the window at all. Five is the headless config-dir set. Also correct the row's "`WAKIL_ORG` stops being a launch-time environment read" per §1 item 3: it stops being read at the three child-spawn sites and remains the launch seed (§7.1). Mark the row met only once §12's runbook is walked. |
| §7, a new question or a note on q13 | **Record §7.1's ruling**: the switched-to org does not survive a relaunch, `WAKIL_ORG` remains the launch seed, and persisting it stays open because `active.json` is per-org and a machine-level record needs a precedence rule this sub-phase did not argue. The probe (§6) raised it and called it a ruling about Invariant 4's scope; it should be visible in the charter rather than only in this spec. |
| §4 Invariant 4 | **No amendment.** The switch is operator-initiated, not config-derived; §9.1's `operatorOnlyActions` rule is what keeps it that way. Recorded here because a reader will reasonably ask. |
| §6 Decision 12 / `setProvider` | **No amendment, recorded deliberately.** A provider switch still *refuses* a turn in flight while an org switch *queues* it (§4.2). Two switches, two behaviours, on purpose: the org carries the operator's whole context and the provider does not. `setProvider` is not migrated to the queue in this sub-phase, and its doc comment's stated cost — that a queue needs a deferred-state machine the window lacks — is now paid, so a later migration is cheaper than it was. |
| §4 Invariant 5 | **No amendment.** Exactly one active `(org, project, environment)` is preserved — this sub-phase changes the triple, it does not multiply it. This is the invariant the superseded N-live design strained and never named. |
