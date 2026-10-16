# Workflow: the superpowers migration

**Date:** 2026-09-26
**Status:** approved by the operator 2026-09-26
**Supersedes:** the ten-rung ladder in `docs/agents/workflow.md` as it stood 2026-09-24

---

## Problem Statement

The ladder works and nobody can afford it.

Ten rungs, five tools, and a sub-phase's worth of GitHub issues per rung that has
one. 2c-iv's map ([#106](https://github.com/yehia-khalil/rafiq/issues/106)) charted
**nineteen tickets, eighteen of them HITL** — eighteen sittings with the operator for
one sub-phase's design, and the map was still open five days later. The workflow doc
itself records this as a defect and prescribes clustering; clustering reduced the
number of sittings and did not touch the number of artefacts.

Three costs, named:

**Planning outweighs building.** Fog, Spec, Probe and Tickets are four rungs and four
tools before a line is written. Each emits an artefact that the next rung reads and
restates. The doc already amputated one such restatement — the design-spec rung,
removed 2026-09-17 — on exactly this reasoning, and stopped one rung short.

**Tickets create tickets.** A map emits grilling tickets; a grilling ticket that needs
a fact emits a blocking research ticket; a spec emits child tickets; a design question
reopened mid-build is, by rule, *a new grilling ticket on the map*. Every one of them
is a unit to open, claim, comment, close and re-sync. The tracker grew to **47 open
issues** across four sub-phases, two of them not started.

**The work unit is smaller than a session.** *One ticket, one session* was adopted
deliberately — it replaces the fresh-context discipline `/implement` dropped. Its cost
is a context rebuild per ticket and an operator context-switch per ticket. 2c-iv and
2e together hold thirteen such tickets, which is thirteen switches for two panes.

None of this is a tooling failure. The rungs each do something real. There are simply
more of them than the work justifies.

## Solution

**Five rungs, three tools, two files per sub-phase.**

```
Design   superpowers:brainstorming    →  docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md
Plan     superpowers:writing-plans    →  docs/superpowers/plans/YYYY-MM-DD-<topic>.md
Build    superpowers:executing-plans  →  the branch  (calls test-driven-development per task)
Cover    the e2e auditor              →  make e2e green, make e2e-new red    [unchanged]
Walk     the operator                 →  phase-log.md, §8 Met                [unchanged]
```

The design interrogation that produced nineteen grilling tickets happens **inside one
brainstorming session**. It is the same questioning — purpose, constraints, approaches,
section-by-section approval — asked in one loaded context and ending in one file. That
substitution is the whole of the saving: nineteen artefacts become one.

**Issues stop being work units.** GitHub Issues become a bug inbox. A defect found in
the field is filed; nothing else is. The board is then small enough to read, which is
the property it lost.

**Probe and Review stop being rungs and become tasks.** A sub-phase with something
to measure gets a measurement task in its plan, and its findings go in the plan's own
notes and back into the spec. A plan phase ends with `superpowers:requesting-code-review`.
Neither needed a rung of its own; both needed to happen, and a plan task makes them
happen without a tracker state to maintain.

**What does not move.** Cover and Walk are untouched, for the reason the doc already
gives: `make e2e-new`'s proof-of-failability is what lets a machine-written runbook half
be trusted, and *Walk is never an agent* is what stops an agent grading its own work.
Those are acceptance machinery, not planning ceremony, and the complaint was about
planning.

## Implementation Decisions

**1. The end-of-turn slot survives verbatim.** `**Next:** … · **Tool:** … · **Blocked
by:** …`, emitted when a turn finished a unit of work. It costs one line and it is what
stops the "how do I pick this up?" round-trip that motivated it. Carried into the new
doc unchanged.

**2. Read state off artefacts, never off memory — still true, and cheaper.** Two files
per sub-phase and a branch. The first of `specs/`, `plans/`, a green `make test` that
is missing is where the work is.

**3. Ten checks at most in a runbook.** Unchanged, with its two selection tests (*what
can a test not see*, *what broke latest*).

**4. Three rules the ladder does not relax.** Carried unchanged, with one amendment.
- A phase is not met until the operator has walked its runbook.
- Where a spec and the shipped code disagree, the code is what ships — say so and
  correct the spec. **Amendment:** the spec is now a file, so the correction is a
  dated amendment section in that file and the body edited to match. The append-only
  argument that made it a GitHub comment was about issue bodies leaving no diff; a
  file in git leaves a diff by construction.
- A design question reopened mid-build is **an amendment to the spec file**, dated,
  not a silent plan edit. (Was: a new grilling ticket on the map.)

**5. Retired, and not to be invoked in this repo:** `/wayfinder`, `/to-spec`,
`/to-tickets`, `/implement`, `/mattpocock-skills:code-review`. The prohibition on
`superpowers:brainstorming` is **lifted** — it is now the first rung. The reason it was
banned (*"it writes the spec file that no longer has a rung"*) is void: the rung is back.

**6. `mattpocock-skills:grilling` stays available as a tool, not a rung.** When a design
question genuinely needs adversarial interrogation, brainstorming can hand off to it
inside the Design rung. It no longer produces tickets.

**7. Labels reduce to three:** `bug`, `needs-triage`, `wontfix`. Retired:
`ready-for-agent`, `ready-for-human`, `needs-info`, and every `wayfinder:*` label.

**8. Existing artefacts keep their standing.** The eighteen files in
`docs/superpowers/specs/` and the five in `plans/` are binding for what shipped under
them and are cited by path across the repo. They are now joined rather than frozen.
[#179](https://github.com/yehia-khalil/rafiq/issues/179) (2c-iv) and
[#89](https://github.com/yehia-khalil/rafiq/issues/89) (2e) are the **last two
issues-as-spec**. Both stay open and binding, because both carry dated probe corrections
in their comments that an exported file would flatten. Nothing after them.

## Testing Decisions

A process change has no test suite. It has an observable:

**The board.** 47 open issues today. After the cut: **six** — two specs and four bugs.
If the count climbs back above ten without a defect surge to explain it, the migration
did not take.

**The artefact count per sub-phase.** Two files. 2c-iv shipped its design as one issue
plus nineteen map tickets plus a probe doc plus four child tickets; the next sub-phase
after 2e ships a spec and a plan.

## The backlog cut

Forty-one issues close on 2026-09-26, and seventeen stale pull requests with them. Each closes `not planned` with a one-line comment
pointing at `docs/wakil/parked.md`, which lists them by number and title under the
heading it was parked beneath. Reopening is `gh issue reopen N`; nothing is destroyed.

| Pile | Count | Disposition |
|---|---|---|
| **Track** — #78 map, #79–86 grilling | 8 | Parked. A future feature with no phase-map row; its design was never settled and will be re-done under Design when it earns a slot. |
| **needs-triage findings** — #131 #136 #141 #144 #145 #156 #159 #167 #171 #177 #230 #235 | 12 | Parked. Real observations, none tied to a live sub-phase. They return as spec input when their area is next worked. |
| **Drift and docs** — #45 #47 #87 #104 #105 #254 | 6 | Parked. Documentation overstatement and dead-seam cleanup; none blocks a phase. |
| **Flakes** — #222 #262 #282 | 3 | Parked. Known-flaky assertions under load, already characterised in the issue bodies. |
| **Absorbed into the 2c-iv plan** — #192, #193, #194, #195 | 4 | Genuinely unbuilt. Closed as *absorbed*, each pointing at the plan file that now carries it as a phase. |
| **Shipped in #297** — #236 #238 #240 #244 #259 #269 #270 #271 (2e) | 8 | Closed as *completed*. Not parked and not absorbed — the code is on `main`. #269's one unmet criterion is a visual ruling, carried into the runbook's walk. |

**Stays open (6):** the two specs — [#179](https://github.com/yehia-khalil/rafiq/issues/179)
(2c-iv) and [#89](https://github.com/yehia-khalil/rafiq/issues/89) (2e) — and the four bugs
blocking live work:
[#300](https://github.com/yehia-khalil/rafiq/issues/300) (`db_set_dsn` never returns),
[#301](https://github.com/yehia-khalil/rafiq/issues/301) (e2e keychain shim),
[#242](https://github.com/yehia-khalil/rafiq/issues/242) (integers above 2^53 in the Go
MCP SDK), [#292](https://github.com/yehia-khalil/rafiq/issues/292) (an act loses the
foreground and the failure blames the app).

## The two plans

**2c-iv — API client pane.** Spec is #179, already corrected by
`docs/wakil/2c-iv-probe.md` (ran 2026-09-22, cost the spec a ruling). The plan is
written from #179 as corrected, absorbing #192–195 as its phases.

**2e — the settings pane. Already built and merged**, which the cut discovered rather
than assumed. [PR #297](https://github.com/yehia-khalil/rafiq/pull/297) landed the whole
nineteen-branch stack on `main` on 2026-09-26 — 17,843 insertions across 109 files. The
eight absorbed tickets are **shipped**, not pending, so they close as *completed*. The
plan therefore builds almost nothing: it lands the two PRs still out (#303, #304), turns
the **Cover** rung — possible for the first time, because the runbook's own header records
the blocker as *"the e2e harness lives on `main` and this stack is not yet rebased onto
it"* — and gets the runbook walked.

**The seventeen stale PRs are the real backlog.** #209, #210, #218, #219, #220, #221,
#223, #226, #227, #228, #229, #237, #239, #241, #245, #260 and #272 all have heads
**already contained in `main`**, verified with `git merge-base --is-ancestor`. Seventeen
open drafts that look like pending work and are not — a bigger contributor to the
unreadable board than any issue, and invisible in an issue count.

## Out of Scope

- **Rewriting `docs/agents/e2e.md`.** The Cover rung is unchanged.
- **Rewriting `docs/agents/domain.md`.** Domain records are orthogonal to the ladder.
- **Migrating the eighteen historical specs or five historical plans** to any new shape.
- **Touching `phase-log.md` history** beyond appending this migration's own entry.
- **The project board's automation.** With issues reduced to a bug inbox the board's
  derived `Status` still works; no field changes.
- **Re-litigating any ruling made under the old ladder.** The rulings stand; only the
  process that produced them changes.
