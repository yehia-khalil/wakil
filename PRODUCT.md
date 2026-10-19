# Product

<!-- impeccable:product-schema 1 -->

**Status:** living · **Created:** 2026-09-20 · **Owner:** Yehia Khalil

This is the product record the Impeccable design skill reads. **It is not a second
charter.** `docs/wakil/north-star.md` is the authority: its §4 Invariants are binding,
§9 is the glossary, and where this file and the charter disagree, **the charter wins and
this file is wrong.** This file cites the charter by section and decision number rather
than restating it, so it cannot drift into a paraphrase that contradicts its source.

It deliberately holds **no** visual world. `docs/wakil/design-language.md` holds that,
and it is approved and living — see `## Brand Commitments`.

---

## Platform

macos

Recorded off-schema, deliberately. Wakil is a native macOS window (Swift/SwiftUI + Metal,
minimum macOS 14.4), and none of the schema's four values (`web`, `ios`, `android`,
`adaptive`) is true of it. `ios` would be the nearest legal value and is rejected: its
guidance governs safe areas, tab bars, 44pt touch targets and Dynamic Type, and its rule
that HIG conformance governs structure contradicts `design-language.md` §1, which removes
window chrome, sidebars and tab bars on purpose. No native platform reference loads for
`macos`; that is the intended cost, on the reasoning that no reference beats a wrong one.

## Users

**One operator** (charter §2), working across two organizations — Initech Labs
and Umbrella — with separate Jira sites, separate chat identities, separate Claude
subscriptions, and projects spanning several repositories.

**Later, possibly other developers.** This shapes exactly one thing: the capability layer
stays headless and provider-agnostic, so the shell is replaceable and nothing assumes a
single user. It does **not** justify building multi-user features, and multi-user is an
explicit non-goal (§5). No second audience may be designed for today.

## Product Purpose

A native macOS workspace that collapses everything work-related into one surface driven by
conversation. It holds a single active context — an organization, a project, an
environment — and every tool inside it inherits that context automatically. You never tell
Wakil *which* Jira, *which* database, *which* Claude account; you tell it what you want.

**The test that settles scope arguments** (§1): *a feature earns its place in Wakil only
when its absence forces you to leave.*

Success is the removal of five named frictions, in rough order of daily pain (§3):
identity re-selection, context reconstruction, source-blind search, tool fragmentation,
and hands-on-keyboard multi-step chores.

## Positioning

**The invention is not integration.** Integrations are assembly work. The two things a
neighboring product could not truthfully copy (§1):

- **Ambient context** — `(org, project, environment)` as implicit state every tool
  resolves against, rather than an explicit project argument on every call. Invariant 5
  keeps exactly one triple active; an explicit argument everywhere would forfeit the
  product.
- **Dual-driven panes** — speaking and clicking are the same operation on the same state.
  Every pane exposes one enumerated action registry, and UI controls and the agent
  dispatch the same actions (Invariant 2, Decision 9). Two code paths to one state is
  forbidden.

Downstream of those: the editor's AI ghost-text runs on the org's quick-tasks provider (its Claude account by default, a local model when the operator adds one; Decision 42) with file and schema context, which is the stated edge over generic completion
(`design-language.md` §11). Claude access is subscription-only, never an API key (§5).

## Operating Context

- Two organizations reached daily, switched **in the window** without quitting (sub-phase
  2b-viii, open question 13). An org switch invalidates the active project, the
  environment, every pane's contents and every Keychain reference in flight.
- Three environments per project — local, staging, production — and production is a real
  target the operator reaches, not a hypothetical. The active environment is on screen at
  all times and production looks alarming (Invariant 8).
- The tools Wakil is replacing at the desk, each with its own idea of which project you
  are in: a DB client, an API client, a terminal, an editor, a browser, Jira.
- **Panes float on a magnetic canvas**, not a fixed tiling grid — dragged anywhere,
  snapped flush, shared edges coordinated (`design-language.md` §10).
- **Push-to-talk voice** (hold ⌥), no wake word (Decision 11). On-device STT, Apple by
  default as of open question 10; audio never leaves the machine. Voice is a transport,
  not a command language: it produces the exact string the ⌘K box would send, through one
  code path (Invariant 10). Release lands the transcript in the composer unsent; Return sends.
- Projects have **1..n roots**, not one repository (Decision 7). A microservice project
  has several.

## Capabilities and Constraints

**Binding constraints live in charter §4 and are not duplicated here.** Read them there.
The ones that most often bear on interface work:

| | Constraint |
|---|---|
| Inv. 2 | Actions are the only mutation path. Every control dispatches a registered action. |
| Inv. 3 | Panes are observable — deictic reference ("this table", "that response") resolves against what is actually on screen. |
| Inv. 5 | Exactly one active `(org, project, environment)`. The provider is a fourth, session-scoped axis, deliberately not in the triple (Decision 4). |
| Inv. 6 | Read-only until a write earns its way in. Three have: row mutation (SQL), issue status transition (Jira), mutation-method request (HTTP). Schema mutation, Mongo mutation, and an agent-run terminal command stay refused. |
| Inv. 7 | Writes are never voice-confirmable **where the write's price is `gate`** — typed confirmation only. An adapter may declare a price of `allow`; two do (Decision 25). |
| Inv. 8 | The active environment is always visible. |
| Inv. 10 | Capability and action layers stay separate: capabilities headless and usable without the app, actions owning pane state inside it. |

**Stack**, as the codebase already fixes it: a Go capability layer (`cmd/`,
`internal/wakilcore`) running as separate headless processes, under a Swift/SwiftUI +
Metal shell (`app/`). `WakilKit` is testable; `WakilApp` has no test target, so anything
worth asserting belongs in the kit. SwiftTerm's headless engine is `WakilKit`'s only
external dependency (Decision 23). Minimum macOS 14.4.

**Performance is a requirement, not a hope** (`design-language.md` §13): 120fps shell on
ProMotion, org/project switch under ~400ms to interactive with the latency covered by
motion, the room drawn as a Metal shader and never on the CPU, data grids virtualized as
a fixed-height `LazyVStack` with no `Section`. Native makes the container fast and does
nothing for content latency; warmth and motion mask that, not the choice of language.

**Vocabulary is fixed by §9's glossary.** Name a concept the way the glossary names it and
do not drift to synonyms. One term is knowingly ambiguous: `Connection` means an org-level
account in §9 and an environment-level database in seven `wakil-db` schema strings (open
question 16, blocking nothing).

**Explicitly undecided, and not to be invented:**

- **Signing and notarisation are externally blocked** — no paid Developer ID on this
  machine (sub-phase 2b-vii). There is no build another person runs.
- **The exact typeface is unresolved.** System sans is an assumption; no display face has
  been chosen (`design-language.md` §15).
- **No light-environment variant exists.** Only the dark treatment. `VoidPalette` is the
  seam one would arrive through.
- **The room's motion numbers are untuned** and were invented rather than measured; they
  sit in one file (`WakilKit/Visual/CoreMotion.swift`) so tuning is a one-file edit.
- **The density toggle has never been worked against for a full day.**
- Five questions are open in `open-questions.md`; none blocks anything startable.

**Not a product** (§5): no pricing, packaging, marketing, or distribution work. Also not a
VS Code replacement, not multi-user, not proactive before Phase 4, not a Jira/Slack/email
client, and not cross-organization — no query spans two orgs.

## Brand Commitments

**The name is Wakil.**

**`docs/wakil/design-language.md` is the approved, living visual authority** (v0, direction
approved 2026-09-03, conforming to the charter). It is the incumbent visual world, and it
is specific: a chrome-less near-black void that is itself the agent's presence, three depth
planes, reserved semantic hues that are never decorative, no ornaments of any kind, and one
deliberate carve-out where a quoted program's own colours ride Wakil's palette values.

Any Impeccable work here **refines or documents that world; it does not replace it.** This
project is not greenfield, and the absence of a file named `DESIGN.md` is not evidence that
it is — `design-language.md` is that file under this repo's own naming. A redesign would
need the charter changed first, deliberately and with a dated entry, exactly as the charter
requires of itself.

**The register of this project's own writing is a commitment too:** dated amendments,
stated reversal conditions, and costs admitted rather than waved away. Interface copy
should sound like the documents, not like a product.

## Evidence on Hand

Real, and to be inspected before editing anything:

- **14 design comps** at `docs/wakil/screens/*.dc.html`, laid out as artboards by
  `canvas.json` (some marked interactive). These are the nearest thing to visual truth for
  surfaces not yet built.
- **Acceptance runbooks**, one per phase, in `docs/wakil/*-acceptance.md`. The charter's
  §8 distinguishes *walked* (an operator ran it against the live app) from *accepted*
  (marked met without one). Do not read an accepted check as a verified one.
- **Measured probes with real numbers**, not estimates: `2d-stt-probe.md` (Apple 4/29
  against WhisperKit large-v3-turbo 3/29 on 25 utterances of the operator's own speech),
  `phase-2c-i-probe.md` (23.0000pt/row exactly, 1,086 row bodies built for 50,000 rows,
  0.574ms median scroll step), `void-as-core-probe.md` (twelve renders).
- **Real organizations**: Initech Labs (Jira project `INI` on `initech.atlassian.net`) and
  Umbrella.

**Absences that must not be filled by invention:** there are no users besides the
operator, no customers, no testimonials, no pricing, no benchmarks against competitors,
no distribution, and no shipped build in anyone else's hands. Phase 2c-iv, 2c-vi, 2d and
Phases 3–4 are unbuilt; a surface for them is a proposal, never a description.

## Product Principles

1. **Absence forces you to leave.** The only admission test for a feature. Convenience is
   not a reason; having to open another app is.
2. **Implicit context beats an explicit argument.** Anything that makes the operator name
   the org, project, environment or account again is the friction this product exists to
   remove.
3. **One state, two drivers.** Speaking and clicking are the same operation. A control
   that cannot be spoken, or a spoken command with no visible control, is a design defect.
4. **Partiality is carried, never inferred.** A short answer and a trimmed one must never
   look alike (§9, *Partiality*). Whatever the surface could not read travels beside the
   data — truncation, skipped sessions, unread providers, an unpageable result, a sort
   that only ordered what was returned.
5. **Writes earn in one at a time, and each declares its own price.** Read-only is the
   default; a new write is a dated justification, not a default (Invariant 6, Decision 25).

## Interaction Rules

How every control behaves, set by the operator on walks and collected 2026-10-03. Each
was found as a defect at least once after the suites were green, which is why it is
written down: **a spec that touches UI says how it meets each rule it can break, and the
e2e auditor covers them** (`docs/agents/workflow.md`, `docs/agents/e2e.md`). The charter
still wins where they meet: Invariant 7's typed confirmation and Invariant 6's refusals
stand.

1. **Confirm only what destroys, or a write whose price is *gate*.** An ordinary edit
   saves without a dialog. *"confirmation is needed only for destructive actions like
   deleting but not every edit"* (2026-09-21).
2. **Enter is never required to keep input.** A field keeps what was typed when focus
   leaves it; Enter is a shortcut, not the only way. *"i dont have to press enter to save
   my input in a field"* (2026-10-03).
3. **A new input arrives focused.** *"the input field that shows should be auto focused,
   i now have to click on it again"* (2026-10-03).
4. **Anything that waits can be cancelled.** *"why no cancel button? i might want to kill
   early and not wait the whole 30 seconds"* (2026-10-03).
5. **Work in flight shows it, and cannot be fired twice by accident.** *"can we add a
   loading state when requests are in sending still? right now i can just spam send"*
   (2026-10-03).
6. **After an action, stay where the operator was.** No jump to a parent, no reopened
   node. *"why not stay on provider? dont reopen organisaiton node"* (2026-09-29).
7. **Override or ignore; don't refuse.** A later value overrides an earlier one, and a
   part that does not apply is dropped (a body on a GET). Refuse only what an invariant
   or a recorded decision forbids, and say which. *"why not override whatever value set
   before?"* (2026-10-01); *"why refuse? i just want to unlink it"* (2026-09-21); *"why
   ban {{}}?"* (2026-09-22); *"why not just ignore the body in get requests"*
   (2026-10-03).
8. **Errors are shown whole and block only what they must.** Never truncated; a
   malformed part does not stop the parts that are fine. Principle 4 applied to errors.
   *"error is truncated i cannot see it … im blocked cant send the request"*
   (2026-10-03).
9. **Defaults suggest; they do not enforce. Optional stays optional.** *"if it is named
   production mark the flag to true by default, then user gets to unmark it. so its a ui
   check and not enforced by the name"* (2026-09-21); *"why enforce adding the logged in
   account to other orgs … its not mandatory"* (2026-09-20).

## Accessibility & Inclusion

Two binding requirements, confirmed 2026-09-20:

- **WCAG 4.5:1 for read text on data surfaces and for the environment badge**, measured
  against the **actual composite** over the void rather than against the foreground's own
  colour — the mistake that let a badge computing at 5.9:1 ship at 1.46:1. Enforced in
  `Contrast.swift`, and `EnvironmentBadgeTests` asserts both that the badge clears the
  floor and that the far plane's own treatment would fail it, so the exemption cannot be
  quietly undone. Atmospheric chrome is exempt; anything being *read* is not. **The rail
  is the third surface this reached** (2026-09-21, #138), and the first to clear the floor
  by being *promoted* under the pointer rather than by a standing exemption — the moment
  it is read is the moment it is promoted. `RailTreatmentTests` holds both ends of that;
  `design-language.md` §3 has the reasoning and the numbers.
- **Reduce Motion is honored.** The room's breath, thinking turnover and speech pulse, and
  the planes' parallax against cursor and window motion, must collapse when System
  Settings' Reduce Motion is on. **This is only partly implemented.** Two places read it: the
  room, whose breath holds still at its mean (`BreathClock`, read in `VoidView`), and, since
  2026-10-17, the background-agent chips, whose working dot stops breathing and whose
  arrival is a fade alone (`AgentChips.swift`). The planes' parallax does not collapse yet,
  and is recorded here as known debt rather than an oversight, on a shell that animates
  continuously by design. The debt grew on 2026-09-21: the rail's promotion is another
  thing that would have to collapse.

Nothing else is committed to. The data grid already carries a row-level VoiceOver label
(`DataSurface.swift`, because SwiftUI's `Grid` of `Text` gives no real row and column
enumeration for free); that is a shipped fact, not a standard this record binds future
work to.
