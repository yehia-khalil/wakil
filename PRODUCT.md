# Product

<!-- impeccable:product-schema 1 -->

**Status:** living · **Created:** 2026-09-20 · **Owner:** Yehia Khalil

The product record the Impeccable design skill reads. **It is not a second charter.**
`docs/wakil/north-star.md` is the authority: its §4 Invariants are binding, §9 is the
glossary, and where this file and the charter disagree, **the charter wins and this file
is wrong.** This file cites the charter by section and decision number rather than
restating it. It holds **no** visual world: `docs/wakil/design-language.md` does (see
`## Brand Commitments`).

---

## Platform

macos

Off-schema, deliberately: Wakil is a native macOS window (Swift/SwiftUI + Metal, minimum
macOS 14.4), and none of `web`, `ios`, `android`, `adaptive` is true of it. `ios` is
rejected: its guidance (safe areas, tab bars, 44pt touch targets, Dynamic Type, HIG
structure) contradicts `design-language.md` §1, which removes window chrome, sidebars and
tab bars. No platform reference loads for `macos`; no reference beats a wrong one.

## Users

**One operator** (charter §2), across two organizations — Initech Labs and Umbrella — with
separate Jira sites, chat identities and Claude subscriptions, and multi-repository
projects. **No second audience may be designed for today**; multi-user is a non-goal (§5).

## Product Purpose

A native macOS workspace that collapses everything work-related into one surface driven by
conversation, in a single active context — organization, project, environment — that every
tool inherits (charter §1).

A place can hold several live conversations. The Landing's Running column lists them; ⌘N
starts one and ⌘⇧W closes one.

**The test that settles scope arguments** (§1): *a feature earns its place in Wakil only
when its absence forces you to leave.* Success is the removal of §3's five frictions.

## Positioning

The invention is not integration but two things (§1):

- **Ambient context** — `(org, project, environment)` as implicit state every tool
  resolves against, never an explicit project argument (Invariant 5).
- **Dual-driven panes** — speaking and clicking dispatch the same registered actions on the
  same state (Invariant 2, Decision 9).

Downstream: the editor's AI ghost-text runs on the org's quick-tasks provider (its Claude
account by default, a local model when the operator adds one; Decision 42) with file and
schema context (`design-language.md` §11). Claude access is subscription-only, never an
API key (§5).

## Operating Context

- Two organizations reached daily, switched **in the window** without quitting. An org
  switch invalidates the active project, the environment, every pane's contents and every
  Keychain reference in flight.
- Three environments per project — local, staging, production — and production is a real
  target. The active environment is on screen at all times and production looks alarming
  (Invariant 8).
- **Panes float on a magnetic canvas**, not a fixed tiling grid (`design-language.md` §10).
- **Push-to-talk voice** (hold ⌥), no wake word (Decision 11). On-device STT, Apple by
  default; audio never leaves the machine. Voice produces the exact string the ⌘K box would
  send, through one code path (Invariant 10). Release lands the transcript in the composer
  unsent; Return sends. A line Return sends may run one navigation action at once on the
  org's quick-tasks model (the fast path); anything else is an agent turn.
- Projects have **1..n roots**, not one repository (Decision 7).

## Capabilities and Constraints

**Binding constraints live in charter §4; read them there.** The ones that most often bear
on interface work:

| | Constraint |
|---|---|
| Inv. 2 | Actions are the only mutation path. Every control dispatches a registered action. |
| Inv. 3 | Panes are observable — deictic reference ("this table", "that response") resolves against what is actually on screen. |
| Inv. 5 | Exactly one active `(org, project, environment)` on screen. The provider is a fourth, session-scoped axis, not in the triple (Decision 4). |
| Inv. 6 | Read-only until a write earns its way in. §4's table lists the writes that have, and what stays refused. |
| Inv. 7 | Writes are never voice-confirmable **where the write's price is `gate`** — typed confirmation only. An adapter may declare a price of `allow` (Decision 25). |
| Inv. 8 | The active environment is always visible. |
| Inv. 10 | Capability and action layers stay separate: capabilities headless and usable without the app, actions owning pane state inside it. |

**Stack:** a Go capability layer (`cmd/`, `internal/wakilcore`) running as separate
headless processes, under a Swift/SwiftUI + Metal shell (`app/`). `WakilKit` is testable;
`WakilApp` has no test target, so anything worth asserting belongs in the kit. SwiftTerm's
headless engine is `WakilKit`'s only external dependency (Decision 23). Minimum macOS 14.4.

**Performance is a requirement** (`design-language.md` §13): 120fps shell, org/project
switch under ~400ms covered by motion, the room a Metal shader, data grids a fixed-height
`LazyVStack` with no `Section`.

**Vocabulary is fixed by §9's glossary**; do not drift to synonyms. `Connection` is
knowingly ambiguous: an org-level account in §9, an environment-level database in seven
`wakil-db` schema strings (open question 16).

**Settings** can add, rename and remove a project and an environment (Decision 21), each as
the operator's own act with no dialog; a project's other fields and the machine block stay
in the file. Settings also edits an environment's API entries (its token goes to the
Keychain behind one confirmation) and renames a database, removes its write access, or
edits its connection (host, port, database and user in the project file, only the password
in the Keychain); removing an entry or a database asks first.

**Explicitly undecided, and not to be invented:**

- **Signing and notarisation are externally blocked** — no paid Developer ID (2b-vii).
  There is no build another person runs.
- **The exact typeface**, **a light-environment variant**, **the room's motion tuning**
  and **a full-day density test** are open (`design-language.md` §15).
- The open questions in `open-questions.md`.

**Not a product** (§5): no pricing, packaging, marketing or distribution, nor any other
§5 non-goal.

## Brand Commitments

**The name is Wakil.**

**`docs/wakil/design-language.md` is the approved, living visual authority**: a
chrome-less near-black void that is itself the agent's presence, three depth planes,
reserved semantic hues that are never decorative, no ornaments, and one carve-out where a
quoted program's own colours ride Wakil's palette values.

Impeccable work here **refines or documents that world; it does not replace it.** The
project is not greenfield: `design-language.md` is its `DESIGN.md` under this repo's
naming. A redesign needs the charter changed first, deliberately and with a dated entry.

**The register of this project's writing is a commitment too:** dated amendments, stated
reversal conditions, costs admitted. Interface copy should sound like the documents, not
like a product.

## Evidence on Hand

Inspect before editing anything:

- **Design comps** at `docs/wakil/screens/*.dc.html`, laid out as artboards by
  `canvas.json` — the nearest thing to visual truth for surfaces not yet built.
- **Acceptance runbooks**, one per phase, live on the feature's branch and leave `main`
  when it merges. Charter §8's *walked* means an operator ran it against the live app;
  *accepted* means marked met without one. Do not read an accepted check as verified.
- **Measured probes**: `2d-stt-probe.md`, `phase-2c-i-probe.md`, `void-as-core-probe.md`.
- **Real organizations**: Initech Labs (Jira project `INI` on `initech.atlassian.net`) and
  Umbrella.

**Absences that must not be filled by invention:** no users besides the operator, no
customers, testimonials, pricing, competitor benchmarks or distribution, and no shipped
build in anyone else's hands. Anything not met in charter §8 is unbuilt; a surface for it
is a proposal, never a description.

## Product Principles

1. **Absence forces you to leave.** The only admission test for a feature. Convenience is
   not a reason; having to open another app is.
2. **Implicit context beats an explicit argument.** Anything that makes the operator name
   the org, project, environment or account again is the friction this product exists to
   remove.
3. **One state, two drivers.** A control that cannot be spoken, or a spoken command with
   no visible control, is a design defect.
4. **Partiality is carried, never inferred.** A short answer and a trimmed one must never
   look alike (§9, *Partiality*). Whatever the surface could not read travels beside the
   data — truncation, skipped sessions, unread providers, an unpageable result, a sort
   that only ordered what was returned.
5. **Writes earn in one at a time, and each declares its own price.** Read-only is the
   default; a new write is a dated justification (Invariant 6, Decision 25).

## Interaction Rules

How every control behaves, set by the operator on walks. **A spec that touches UI says how
it meets each rule it can break, and the e2e auditor covers them** (`docs/agents/workflow.md`,
`docs/agents/e2e.md`). The charter still wins where they meet: Invariant 7's typed
confirmation and Invariant 6's refusals stand.

1. **Confirm only what destroys, or a write whose price is *gate*.** An ordinary edit
   saves without a dialog; deleting asks.
2. **Enter is never required to keep input.** A field keeps what was typed when focus
   leaves it; Enter is a shortcut, not the only way.
3. **A new input arrives focused.** The operator never clicks a field that just appeared.
4. **Anything that waits can be cancelled.** A cancel control, not a wait for the timeout.
5. **Work in flight shows it, and cannot be fired twice by accident.** A loading state;
   no spamming Send.
6. **After an action, stay where the operator was.** No jump to a parent, no reopened
   node.
7. **Override or ignore; don't refuse.** A later value overrides an earlier one, and a
   part that does not apply is dropped (a body on a GET). Refuse only what an invariant
   or a recorded decision forbids, and say which.
8. **Errors are shown whole and block only what they must.** Never truncated; a
   malformed part does not stop the parts that are fine. Principle 4 applied to errors.
9. **Defaults suggest; they do not enforce. Optional stays optional.** An environment
   named production pre-sets the flag, which the operator can unset; nothing optional is
   made mandatory.

## Accessibility & Inclusion

Two binding requirements:

- **WCAG 4.5:1 for read text on data surfaces, the environment badge, the context line and
  the rail**, measured against the **actual composite** over the void, not the
  foreground's own colour (a badge computing at 5.9:1 once shipped at 1.46:1). Enforced in
  `Contrast.swift`; `EnvironmentBadgeTests` asserts the badge clears the floor and the far
  plane's own treatment would fail it. Atmospheric chrome is exempt; anything being *read*
  is not. The rail clears the floor by being *promoted* under the pointer — the moment it
  is read is the moment it is promoted (`RailTreatmentTests`; `design-language.md` §3).
- **Reduce Motion is honored.** The room's breath, thinking turnover and speech pulse, and
  the planes' parallax, must collapse when Reduce Motion is on. **Only partly
  implemented:** the room's breath holds still at its mean (`BreathClock`, read in
  `VoidView`), and the background-agent chips' working dot stops breathing and arrives by
  fade alone (`AgentChips.swift`). The planes' parallax and the rail's promotion do not
  collapse yet — known debt.

Nothing else is committed to. The data grid's row-level VoiceOver label (`DataSurface.swift`)
is a shipped fact, not a standard this record binds future work to.
