# Review — the org switch design (2b-viii)

**Status:** assessment · **Date:** 2026-09-15 · **Reviewer:** Claude Code, at the
operator's request

Subject: `docs/superpowers/specs/2026-09-15-phase-2b-viii-org-switch-design.md`,
committed as `df77bc2`.

This document changed nothing when it was written. The spec, the charter, the probe and
every source file were exactly as they were. It records what a full read of the spec
against the tree found, with a `file:line` for each claim so every one of them can be
checked or refuted.

> **All eleven findings were closed in the spec later the same day.** The revised
> `2026-09-15-phase-2b-viii-org-switch-design.md` carries them; this document is left as
> it was written, because what it records is the state of the spec on the day it was
> reviewed. The one finding that needed a ruling rather than an edit — #6, whether the
> switched-to org survives a relaunch — was ruled by the operator: **it does not**, and
> the spec's new §7.1 records that as a decision with its cost stated. Where each
> finding landed:
>
> | # | Closed in |
> |---|---|
> | 1 | §9 split into §9.1 (four new tools) and §9.2 (`get_context` amended, both rules scoped away from it) |
> | 2 | §4.4 rewritten as a five-row table — the window runs four, `wakil-http` runs in neither set |
> | 3 | §8's Creating row and §8.3 — the field is dropped; `SaveOrg` named as where it goes instead |
> | 4 | §5.3, plus §6's Go half now reporting `ActiveProvider`, plus §4.3 step 6 |
> | 5 | §5's list gains `rootPath`; §5.3 covers all three `let`s |
> | 6 | §7.1 — ruled session-only; §13 carries the cost; §12 check 13 walks it |
> | 7 | §3 — `start(environment:)` chosen over `restart(environment:)`, with the actor-isolation reason |
> | 8 | §4.2 — three enumerated states, a send-refusal rule against starvation, and the `setProvider` interaction |
> | 9 | §5.2 — naming-not-behavioural stated outright, plus the `@Observable`/`Mirror` mechanics |
> | 10 | §6's closing paragraph — the headless caller named as the beneficiary |
> | 11 | §12 checks 13, 14, 15, and check 7 extended to the held-switch case |

**The spec is strong where it is hardest.** §5.1 is a real defect found by reading
rather than by a walk, and check 4 pins it. §3.1's asymmetry with 2b-vi is correctly
argued and correctly *forced*. §2's three-site table is exactly right, including the
one site it says only looks like a fourth. §8.1 removes a state rather than adding one.

**Where it is weak is in the two places a spec is normally weakest: the sentences that
generalise over a list, and the steps between the steps.** Eleven findings follow, five
of them blocking. Four of the five are the same failure in different clothes: a claim
that is true of most of a set and is then stated over the whole set.

---

## Summary

| # | Finding | Severity |
|---|---|---|
| 1 | §9's "all five" contradicts §6 twice — `get_context` can be neither operator-only nor `CurrentOrg()`-free | blocking |
| 2 | §4.4's correction of the charter is itself wrong: `wakil-http` runs in neither set | blocking |
| 3 | The creation form's optional `defaultProvider` can never succeed — Go refuses it by construction | blocking |
| 4 | Nothing re-derives the new org's provider, and §7 depends on it | blocking |
| 5 | `rootPath` and `lookup` are `let`s that the switch must change; §5 names one and misses the other | blocking |
| 6 | Whether the switched-to org survives a relaunch is never ruled on — and the probe asked for the ruling | significant |
| 7 | §3's "nothing else in `MCPClient` changes" is not implementable as stated | significant |
| 8 | §4.2's queue is a new state machine, under-specified in three places | significant |
| 9 | §5.2's tripwire is a naming test, not a behavioural one, and `@Observable` changes what `Mirror` sees | significant |
| 10 | §6 is right, but the Go half buys the *window* nothing; only the headless surface gains | editorial |
| 11 | §12 is missing the two checks the spec's own reasoning implies | editorial |

---

## 1. §9's "all five" contradicts §6 twice — blocking

§9 tabulates five tools and then makes two statements over all five. Both are false of
the fifth, and the fifth is `get_context` — the one tool in the table that already
exists.

**"All five join `operatorOnlyActions`."** `get_context` is how the window reads its own
context: `ContextStore.current()` calls it (`ContextStore.swift:108`) and
`WindowModel.refreshContext` calls `current()` (`WindowModel.swift:1422`) — which is
step 6 of this spec's own sequence. Beyond that there is no name to add:
`operatorOnlyActions` is a set of *action* names (`PermissionPrompt.swift:74`), and
there is no `ctx_get_context` action to name. Both `ContextStore.swift:38` and
`WindowModel.swift:1410` say so in terms — reading stays off the registry deliberately,
because Invariant 2 governs mutation paths.

**"None may call `CurrentOrg()`."** §6.1 requires the opposite of `get_context`, in the
same document: *"The org comes from `CurrentOrg()` and is knowable whenever the process
started at all."* That is the whole Go half of §6.

Both statements are correct and well-argued **about the four new tools**. The fix is a
scope, not a rewrite: say *the four new tools*, and give `get_context` its own sentence
saying it stays reachable and keeps its `CurrentOrg()` read.

One thing to get right while editing it. The two cross-org reads (`list_orgs`,
`list_machine_providers`) are grouped under the mutators' justification — *"an agent
that could create or switch an org could move Invariant 4's own boundary"* — which is
an argument about `create_org` and `adopt_provider`. The reads do not move the boundary;
the case for denying them is the weaker "an agent should not enumerate the machine",
and it is worth making explicitly rather than by association, because §9's last
paragraph then argues the *opposite* direction for the same two tools (reading across
orgs is established, `provider add` has always done it). As written the section both
denies them to the agent and justifies their existence by precedent for cross-org reads.

Worth recording for the implementer: the agent cannot reach `wakil-ctx` at all.
`agentFacingServers = ["wakil-pm", "wakil-recall"]` (`WindowModel.swift:652`), and the
comment above it says `wakil-ctx`, `wakil-db` and `wakil-http` are deliberately absent.
So `operatorOnlyActions` here is about the shim/registry path, not the MCP config.

## 2. §4.4's correction is itself wrong — blocking

§4.4 corrects the charter's *"the five servers respawn"* to: two are Wakil's to restart
(`wakil-ctx`, `wakil-db`), and *"the other three (`wakil-http`, `wakil-pm`,
`wakil-recall`) are spawned by the `claude` CLI from the `--mcp-config` JSON"*.

`wakil-http` is in neither set.

- `WakilWiring.build` spawns exactly two clients: `startClient("wakil-ctx")` and
  `startClient("wakil-db")` (`AppWiring.swift:143-144`), and the file's own header says
  so (`AppWiring.swift:6`, `:99-100`).
- The agent's config publishes exactly two: `agentFacingServers = ["wakil-pm",
  "wakil-recall"]` (`WindowModel.swift:652`). The comment immediately above it
  (`WindowModel.swift:645-651`) names `wakil-http` as one of the three *deliberately*
  absent, because it affects panes.

So in the window four servers run, not five: two Wakil-owned, two CLI-spawned. The
charter's "five" is the set an operator gets in a *provider config dir* from
`scripts/register-provider.sh` (`cmd/wakil/providercmd.go:58`) — a different surface
from the window, which is exactly why the row needed correcting in the first place.

This matters more than an ordinary slip because §14's table instructs the implementer
to write §4.4's sentence into `north-star.md` §8. As written it would replace one wrong
claim about this sub-phase with another, in the document that is meant to be binding.

## 3. The creation form's `defaultProvider` field can never succeed — blocking

§8's Creating state is *"id, Jira base (**optional**), optional default provider"*, and
§8.3 says the form submits and renders Go's refusal verbatim rather than re-implementing
validation. The second half is right. Applied to `defaultProvider`, it guarantees a
refusal every time.

`CreateOrg`'s own doc comment (`internal/wakilcore/org.go:89-95`):

> One consequence: `wakil org create <org> --default-provider X` can never succeed,
> because X cannot already be registered under an org that does not exist yet. That is
> intentional …

Enforced at `org.go:170-176`: `normaliseOrg` runs `LoadProviderFor(org, o.DefaultProvider)`
and returns its *"no provider … — register it with: `wakil provider add`"*. So a form
that offers the field will, whenever it is used, create nothing and show an error about
registering a provider — the least legible possible moment to be told that.

§8.2 caught precisely this class of problem for Jira ("a flag cannot show you what you
did not type; a form can") and is the best paragraph in the section. The same reading
was not applied one row down.

Two ways out, and they differ in scope:

- **Drop the field.** Creation writes id and Jira base only. Cheapest, and consistent
  with the ordering `operator-todo.md` already teaches (orgs at step 2, providers at
  step 3).
- **Move it downstream.** `SaveOrg` (`org.go:122`) has no such constraint, so a default
  provider becomes settable once an account has been adopted — which is a natural
  continuation of the Adopting state and needs no new Go capability beyond a
  `set_org_default_provider`. This is a scope increase and should be said out loud if
  taken.

Either way §8's table and §12's check 10 should agree; check 10 currently verifies an
org created with no Jira base and says nothing about the provider field.

## 4. Nothing re-derives the new org's provider — blocking

§4.3's step 6 says `refreshContext()` *"resolves project and environment"*. It resolves
exactly those two and the org (`WindowModel.swift:1421-1434`). It does not touch
`providerId`.

`providerId` is set once, at window-open, in `WindowSession` — from
`activeContext?.activeProvider` (`WindowSession.swift:96`), read off the same
`get_context` call that supplies `rootPath`. `WindowModel` has no path back to that
resolution; the only thing that assigns `providerId` after launch is `setProvider`
(`WindowModel.swift:3262`), which is the operator picking an account.

§5 correctly lists `providerId` as org-derived, so after `invalidateForOrgChange()` it
is `""`. Follow the sequence from there:

- Step 7's auto-resume selects *"the newest session for the org's active provider"* —
  there is no such value.
- `startHarness` refuses an empty `providerId` outright (`WindowModel.swift:2935`), and
  `resume` refuses a session whose provider does not match (`WindowModel.swift:3093`).

So steps 7 and 8 are unreachable as written, and the window lands in the new org with no
agent — the degrade `WindowSession.swift:110-140` was built for, reached here by
omission rather than by decision.

The natural source is `ContextStore.current().activeProvider`, and it has the same
hole §6 is about: `Resolve()` in Go requires an active project before it will look at
`active.Provider` (`WindowSession.swift:87-91`), so on a fresh org the call throws and
the provider is unknown for the same reason the org was.

Recommendation, and it is close to free: have §6's Go amendment report `ActiveProvider`
alongside `Org` on the error path, for the same reason and with the same argument —
both are knowable without a resolved project, and withholding them because a *different*
resolution step failed is what makes the error unreadable. Then add an explicit step
between 5 and 6 that re-derives the provider, and say what the window does when the new
org has no active provider (the honest answer is the existing no-agent note, but it
should be chosen rather than inherited).

## 5. Two `let`s the switch must change, one of them unnamed — blocking

§5 names "the credentials lookup" as org-derived. It is `private let lookup:
ProviderCredentialsLookup` (`WindowModel.swift:1072`). §2 already makes it a
`lookupFactory`, so this is a consequence the spec has half-stated: the property has to
become a `var` fed from the factory, and `invalidateForOrgChange()` cannot "reset" a
`let`.

The one §5 does not name is worse. `private let rootPath: String`
(`WindowModel.swift:1085`) is *"the directory a FRESH session runs in: the project's
first declared root"* — derived, at window-open, from the **outgoing** org's
`ActiveContext.rootPaths` (`WindowSession.swift:78-92`). It is org-derived by
construction, it is absent from §5's enumeration, and it is a `let`.

Left as it is, a fresh session in the new org launches `claude` with the previous org's
project root as its working directory. Nothing fails: `buildLaunch` takes the path it is
given. The first thing that would notice is `read_session`'s refusal that a session's
cwd is not a root of the active project (`cmd/wakil-ctx/main.go:186`) — surfacing as a
confusing resume failure, one org later.

This is §5.1's own shape — state that is correct per-project on disk and stale in memory
— which suggests the enumeration deserves one more pass against the property list rather
than against the narrative. Note also that §5.2's tripwire is exactly what would have
caught `rootPath`: it is the argument *for* the tripwire, and simultaneously the
argument for not deferring the enumeration to it.

## 6. Whether the org survives a relaunch is never ruled on — significant

The probe asks for this ruling by name (`org-switch-probe.md` §6, third bullet):

> **Whether the app should remember its last org across launches is untouched by this
> probe** — it is a ruling about Invariant 4's scope, not a fact to measure, and it is
> still open.

The spec closes q13 and q14, amends q5, and never rules on it. §13's "what stays open"
does not list it; §14 schedules no charter edit for it; §12 has no check that relaunches.

As written, the behaviour is: switch to org B, quit, relaunch — and the window opens in
whatever `WAKIL_ORG` the launching shell exports, silently. The provider precedent runs
the other way: `setProvider` ends by dispatching `ctx_set_provider`
(`WindowModel.swift:3274-3277`) precisely so the pick *"survives past this window's
lifetime"*. There is no symmetric place for an org: `active.json` lives under `OrgDir()`
(`internal/wakilcore/active.go:31-37`), so persisting the active org needs a new
machine-level record — a real decision, with an Invariant 4 argument on both sides.

The related looseness is §1.3 and §14's framing: *"`WAKIL_ORG` stops being a launch-time
environment read. It is the last one."* §8.5 requires the opposite — the plane opens
*"when `WAKIL_ORG` is set but names an org that does not exist"*, which is a launch-time
read of `WAKIL_ORG`. What actually stops is `WAKIL_ORG` being read at the three
*child-spawn* sites, which is the accurate and still-sufficient claim. Worth correcting
because 2b-vi's parallel is exact and this sentence is what the charter row will inherit.

Either ruling is defensible; the spec should make one, and §12 should walk it.

## 7. §3's "nothing else in `MCPClient` changes" — significant

Everything §3 says about the latch is correct and checks out: `stdoutReachedEOF` sets
`transportError` (`MCPClient.swift:468-470`), `sendRequest` throws it
(`MCPClient.swift:359`), the four fields are `frameReader` (`:65`), `transportError`
(`:82`), `stdoutFinished`/`stderrFinished` (`:87-88`), and the structural-safety
argument holds — `performTeardown` awaits `waitForDrainToFinish()` before returning
(`:287`), so no old thread survives to re-latch.

The one sentence that does not survive contact is *"`environment` becomes a `var`.
Nothing else in `MCPClient` changes."*

`environment` is `private let` on an **actor** (`MCPClient.swift:53`, `:56`). Making it
`var` is necessary and not sufficient: Swift forbids assigning an actor-isolated
property from outside the actor, so re-pointing needs an isolated entry point. The probe
used one — `restart(environment:)` (`org-switch-probe.md` §2) — so the spec and the
measurement it rests on disagree about the surface.

Decide and state it: either `restart(environment:)` on the client (which also fixes
where stop-then-start is ordered, and keeps it out of `WindowModel`), or
`start(environment:)` taking the new value as a parameter. The second is the smaller
change and reads better against §3's own argument that the reset "is a statement about
what starting means".

Immaterial, inherited from the probe: `sendRequest`'s *first* act is the `notRunning`
guard (`:358`); the `transportError` throw is second. The argument is unaffected.

## 8. The queued switch is a new state machine — significant

§4.2's reasoning about stakes is sound. What it does not engage is the reason
`setProvider` gives for refusing (`WindowModel.swift:3169-3175`):

> A queued switch needs a deferred-state machine nothing else in this window has, and it
> defers a decision the operator can simply re-make in a few seconds.

This spec builds that machine. That is a legitimate overturn — the second half of that
sentence is much weaker for an org than for a provider — but it should be recorded as
overturning a stated cost, not only as a difference in stakes, because the cost was the
actual objection and it is now being paid.

Three states the section leaves undefined:

1. **"Held" is not defined.** *"A turn that parks a mutation while a switch is queued
   hits guard 2 at firing time and the switch is held with that message."* Held meaning
   still queued, and firing when the operator resolves the confirmation? Or cancelled,
   with the operator's queued intent discarded at the moment they are looking at an
   unrelated SQL statement? These are materially different, and the second is close to
   the thing §4.1 guard 2 exists to prevent.
2. **Starvation is unaddressed.** If the operator sends a second turn while a switch is
   queued, does the switch fire in the gap, or wait behind it? `turnInFlight`
   (`WindowModel.swift:3148`, `:3259`) is a single flag with no "closing" state, so
   "fires when the turn completes" needs a defined interaction with "the next turn
   starts".
3. **Interaction with `setProvider`.** `setProvider` refuses while `turnInFlight`
   (`WindowModel.swift:3181`), so the two cannot be *initiated* together — but a queued
   org switch that fires after a provider switch has changed `providerId` is reachable,
   and §7's auto-resume is provider-sensitive.

Separately, the window will now refuse a provider switch mid-turn and queue an org
switch mid-turn. Two switches, two behaviours, one idiom claimed in §4.1. If that
divergence is intended and permanent, §14 should say so in one line — the table
currently records six charter edits and none of them is "`setProvider` is deliberately
left as it is".

## 9. §5.2's tripwire — what it proves, and what `Mirror` will actually see — significant

Two things to pin before implementation.

**It is a naming test, not a behavioural one.** `Mirror` yields labels and `Any` values;
partitioning labels against two hard-coded lists catches an *unclassified* property,
which is the stated deliverable and which it does achieve. It proves nothing about
whether `invalidateForOrgChange()` resets the org-derived ones — yet §5.2 describes that
list as "must be reset by `invalidateForOrgChange`", which reads as a behavioural claim.
Say which is intended. If both, the test has to mutate every org-derived property to a
non-default value and re-check after the call, which is a much larger test and worth
scoping now rather than discovering.

**`@Observable` changes what `Mirror` returns.** `WindowModel` is `@MainActor
@Observable` (`WindowModel.swift:895-897`). The Observation macro rewrites stored
properties into computed ones over `_`-prefixed backing storage and adds
`_$observationRegistrar`, so `Mirror(reflecting:)` will yield `_organization`,
`_project`, … plus a `$`-named registrar, with any `@ObservationIgnored` property
appearing under its plain name. The two lists must be written against that reality (or
normalised: strip one leading `_`, exclude `$`-bearing labels). This is a half-hour of
confusion if it is discovered at implementation time and a sentence if it is recorded
here.

Worth stating the size, too: `WindowModel` carries on the order of eighty stored
properties today, eleven of them `let`. The lists will be long, and a reviewer seeing
them for the first time in a PR should know they were expected to be.

The precedent is good and worth citing in the spec: `ActionRegistryTests.swift:122-131`
already uses a `Mirror` walk as a structural assertion, and `ActionRegistry.swift:293-301`
deliberately defeats one — so both the technique and its limits are established here.

## 10. §6 is right; be exact about who gains from which half — editorial

The finding and both halves are correct, and the Swift half is doing all the work in the
window: `callChecked` throws on `isError` (`ContextStore.swift:108ff`) before anything
parses `Org`, so the Go amendment alone would leave `refreshContext`'s `catch` exactly
where it is — which is what §6 says.

The beneficiary of the Go half is therefore the headless surface, not the in-window
agent. §6.1's *"today `ctx_get_context` on a fresh org tells an agent nothing about where
it is"* names a tool that does not exist and an agent that cannot reach `wakil-ctx`
(`WindowModel.swift:645-652`). The real beneficiary is a plain `claude` session started
in a provider config dir, which `scripts/register-provider.sh` wires to all five servers
(`cmd/wakil/providercmd.go:58`). Same conclusion, accurate sentence — and it matters
because finding 1 is the same confusion, one section later, with consequences.

## 11. §12's runbook — two checks the spec's own reasoning implies — editorial

The runbook is good, and check 4 is exactly right: it is the only check that could catch
§5.1, and the note explaining *why* it exists ("both orgs draw something, and only the
rows say which") is the kind of thing walks lose without.

Missing:

- **Switch into an org with no active project.** This is §6's motivating case, the
  "fresh org, the common case and the first one a new operator meets" — and no check
  walks it. Checks 1 and 2 cover launching with no org and with a bad org; neither
  covers switching into a good org that has nothing selected inside it, which is where
  the org/project/environment/provider quartet is most likely to come apart (findings 4
  and 6 both land here).
- **Switch, quit, relaunch.** Whichever way finding 6 is ruled, the runbook should
  observe it once.

One more worth considering, cheap and adjacent to check 11: switch into an org with no
providers registered at all. That is the state `WindowSession.swift:110-140` was
rewritten for in 2b-vi, and the org switch is the first thing that can reach it without
a relaunch.

## Checks run for this review

Every claim above was read out of the tree at `df77bc2`. The spec's own factual claims
were checked in the same pass; these held:

- The three `WAKIL_ORG` process reads, and that `WindowModel.swift:687` is not a fourth
  (`AppWiring.swift:346`, `WindowSession.swift:141`, `:171`; `WindowModel.swift:687` sits
  inside `agentMCPConfigJSON`, which takes `organization` as a parameter). §2's table is
  exact.
- §5.1's defect, in full. `LayoutStore.byProject` (`LayoutStore.swift:177`) and
  `PaneStore.byProject` (`PaneStore.swift:116`) are both keyed by project name alone;
  both `switchProject` implementations keep the outgoing project
  (`LayoutStore.swift:589-601`, `PaneStore.swift:140`); `LayoutPersistence` keys by
  `(org, project)` (`LayoutPersistence.swift:33`, `:63`, `:83`); `loadedLayoutProjects`
  is a bare `Set<String>` (`WindowModel.swift:1118`) and its insert is gated on
  `!organization.isEmpty` but not on the org's *identity* (`WindowModel.swift:1486`).
- §3.1's "it is forced": `registerStandardActions` closes over the client instances, so
  there is no new client to prove healthy without re-registering the action set.
- §6's Swift observation: `refreshContext`'s `catch` sets `status` and returns without
  touching `organization`, `project` or `environment` (`WindowModel.swift:1427-1429`).
- §11's approach B: `WindowModel` holds exactly six wiring components as `let` —
  `registry`, `panes`, `layout`, `persistence`, `context`, `confirmations`.
- §8's chord: ⌘⇧O is free against the five bound (`WakilWindow.swift:484`, `:486`;
  `AppScene.swift:256`, `:260`, `:264`).
- §8.2: `normaliseOrg` validates `JiraBase` only when non-empty (`org.go:148`), and
  `operator-todo.md:21` carries the quoted correction verbatim.
- §9's feasibility: `LoadOrgFor(org)` (`org.go:53`) and `ListProvidersFor(org)`
  (`provider.go:633`) are org-parameterised, so `list_orgs` can report Jira base and
  account count without `CurrentOrg()`.

One citation to reconsider: §8 places the plane "in `design-language.md` §3's plane
idiom". §3 is the *depth* model — far/mid/near, with treatments for each
(`design-language.md:50-64`) — not an idiom for modal surfaces, and the confirmation
plane's treatment is not specified there. Citing `ConfirmationPlane.swift`, or §3's near
plane explicitly, would survive a reader who follows the pointer.
