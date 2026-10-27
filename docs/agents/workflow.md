# Workflow

How a sub-phase travels from a row in `north-star.md` §8 to a walked acceptance
runbook, and which tool drives each leg.

**Five rungs, three tools, two files.** Set 2026-09-26, replacing a ten-rung ladder
whose Fog / Spec / Probe / Tickets front end cost four tools and a sub-phase's worth
of GitHub issues before a line was written. The reasoning and the full accounting are
in `docs/superpowers/specs/2026-09-26-workflow-superpowers-migration-design.md`.

## End every turn that finished something with this block

**Required, as a slot rather than a reminder:**

```
**Next:** <the one next step>  ·  **Tool:** <skill or command>  ·  **Blocked by:** <thing, or —>
```

Emit it when the turn **finished a unit of work**: a spec written, a plan phase
landed, a suite green, a question answered that unblocks a decision.

Do **not** emit it mid-task — inside a lookup, or between two tool calls of one step.
The operator is reading for the next decision, not narrating the current one.

**Why this is a slot and not advice.** On 2026-09-17 the assistant published the
2c-iii spec and stopped, and the operator had to ask *"how can i pick this up? is it
ready for implementing?"*; it answered with the full sequence and stopped again, and
the operator had to ask *"superpowers plugin or matpocock skills?"*. Both answers were
already known in both turns. What was missing was never the knowledge — it was the
place to put it.

## The ladder

| Rung | Done when this exists | Next step | Tool |
|---|---|---|---|
| **Design** | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`, committed and reviewed by the operator, and, if it touches UI, saying how it meets each `PRODUCT.md` §Interaction Rules rule it could break | Interrogate the design in one session — purpose, constraints, 2–3 approaches, then sections approved one at a time | `superpowers:brainstorming` |
| **Plan** | `docs/superpowers/plans/YYYY-MM-DD-<topic>.md` | Decompose the spec into phases of tasks, each demoable, each test-first | `superpowers:writing-plans` |
| **Build** | the plan's tasks checked off, `make test` and `make app-test` green | Work the plan top to bottom | `superpowers:executing-plans`, which calls `superpowers:test-driven-development` per task and ends a phase at `superpowers:requesting-code-review` |
| **Cover** | every action and identifier the branch touched carries a check, `make e2e` green (the checks the diff reaches), `make e2e-new` red against the merge-base | An agent reads the branch, writes the missing checks, proves each red then green, and reports only what it could not cover | The e2e auditor, `docs/agents/e2e.md`; `make e2e-new`, `make e2e`, `make e2e-runbook` |
| **Walk** | `docs/wakil/phase-<sub-phase>-acceptance.md` written, its checks marked and dated, an entry in `phase-log.md`, and `Met` filled in §8. The full suite runs after the merge, in the night run on `main` | The machine half is `make e2e-runbook`'s; write the human half from what Cover could not reach. Then **the operator walks it — never an agent** | `make e2e-runbook E2E_RUNBOOK=<the document>`; prose for the rest |

**Probe and Review are tasks, not rungs.** A sub-phase with something to measure gets
a measurement task in its plan, and its findings amend the spec. A plan phase ends at
`superpowers:requesting-code-review`. Both still happen; neither needs a tracker state.

**Read the state off artefacts, never off memory.** The first of the spec file, the
plan file, a green suite that is missing is where the work is. A conversation that has
drifted, a compacted context, or a fresh session all recover the position by looking.

## Issues are a bug inbox

**GitHub Issues are not work units.** A defect found in the field is filed; nothing
else is. No maps, no grilling tickets, no research tickets, no child tickets, no
issue-as-spec. The spec is a file and the plan is a file.

[#179](https://github.com/yehia-khalil/rafiq/issues/179) (2c-iv) and
[#89](https://github.com/yehia-khalil/rafiq/issues/89) (2e) are the **last two
issues-as-spec** and stay open, binding, because both carry dated probe corrections in
their comments. Nothing after them.

Three labels: `bug`, `needs-triage`, `wontfix`. See `docs/agents/issue-tracker.md`.

## Three rules the ladder does not relax

- **A phase is not met until the operator has walked its runbook.** Writing one is not
  walking it. `Met` says *walked* or *accepted*, and the difference is the whole point
  of the column.
- **Where a spec and the shipped code disagree, the code is what ships.** Say so, and
  correct the spec — never quietly match it. The correction is a **dated amendment
  section** in the spec file, with the body edited to match it. A probe that
  contradicts the spec is the same move, made before any code exists.
- **A design question reopened mid-build is a dated amendment to the spec file**, not
  a silent plan edit. The spec's rulings are cited across the repo; changing one
  without a record breaks the citation and the reasoning at once.

## A runbook is ten checks at most

**Ten, chosen for what a test cannot see.** Not twenty-six, which is what 2c-iii wrote
and what the operator declined to walk on 2026-09-18 — correctly. A long runbook is an
inventory, an inventory is not a plan for an afternoon, and **a runbook nobody walks
defends nothing**. Twenty-six unwalked checks are worth less than ten walked ones, and
the rule that a phase is not met until the operator has walked its runbook is what
makes the difference material rather than tidy.

The cap forces the question that matters: *of everything this sub-phase claims, which
ten would I most regret not having looked at?* Two tests for choosing:

- **What can a test not see?** Anything needing the shipped bundle rather than a test
  run, anything visual, anything about live input. 2c-iii's bundle-`PATH` check is the
  type specimen: a bundled app inherits launchd's environment, so a shell spawned
  without being a login shell ships unable to find `kubectl` while every unit test
  passes.
- **What broke latest?** The defects found in the final days are the ones least worn
  in. Four of 2c-iii's ten covered defects still live at its final review.

Longer documents may still exist — 2c-iii keeps its full twenty-six below a `## 0. The
short walk` section — but the **walk** is the ten, and the record says so. Write the
ten first, at the top, and let anything else be reference rather than obligation.

## A runbook has a machine half and a human half

**The machine half is rendered, and nothing writes it by hand.** It lives between two
markers, and `make e2e-runbook E2E_RUNBOOK=<the document>` replaces everything between
them from the records the runs left — which check ran, against which build, with what
exit status and how many assertions, which were seen to fail against the merge-base,
and what the coverage gate said. A red run renders too, with the harness's own words
for what went wrong, because a generator that wrote nothing until everything was green
would leave the document describing the last build that was.

```
<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
```

A runbook without those two lines is **refused** rather than guessed at: where the
section belongs is a judgement about that document.

**Why generated and not written.** The Walk rung keeps its *"never an agent"*, which
guards against an agent declaring its own work good. The proof-of-failability in
`make e2e-new` is what lets the machine-walked half be trusted without the operator
re-checking it — and that argument holds for the *records*, not for an agent's prose
summary of them. So the summary is computed from the records.

**The human half stays prose, and the ten-check cap is its cap.** It holds only what
the machine cannot see: the visual rulings, *did the right real account get used*
against a live provider, and whatever the Cover rung reported as residue.

## Retired 2026-09-26

**Do not invoke in this repo:** `/wayfinder`, `/mattpocock-skills:to-spec`,
`/mattpocock-skills:to-tickets`, `/mattpocock-skills:implement`,
`/mattpocock-skills:code-review`.

`mattpocock-skills:grilling` stays available as a **tool inside the Design rung** when
a question needs adversarial interrogation. It no longer produces tickets.

The prohibition on `superpowers:brainstorming` that stood in this file until
2026-09-26 is **lifted**. Its stated reason — *"it writes the spec file that no longer
has a rung"* — is void: the rung is back, and it is the first one.

**The historical artefacts stay where they are.** The nineteen files in
`docs/superpowers/specs/` and the five in `docs/superpowers/plans/` are binding for the
sub-phases that shipped under them and are cited by path across the repo. They are now
joined rather than frozen. The parked issues are indexed in `docs/wakil/parked.md`.
