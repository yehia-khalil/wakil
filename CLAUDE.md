# Wakil

A Go capability layer (`cmd/`, `internal/wakilcore`) under a Swift macOS app
(`app/` — `WakilKit` is testable, `WakilApp` has no test target).

**Code map:** `docs/architecture/README.md` (the whole app, Swift and Go) and `CONTRIBUTING.md`
(where code goes, recipes, the tests each change needs). Read them before changing structure.

Start with `docs/wakil/north-star.md` — the charter. Its §4 Invariants are
binding; §9 is the glossary.

## Agent skills

### Workflow

Five rungs — **Design → Plan → Build → Cover → Walk** — driven by
`superpowers:brainstorming`, `superpowers:writing-plans` and
`superpowers:executing-plans`, then the repo's own e2e auditor, then the operator.
Two files per sub-phase: a spec and a plan, both under `docs/superpowers/`. Feature documents
(specs, plans, runbooks) live on the feature's branch and leave `main` with it.

**End every turn that finished a unit of work by naming the next step and its tool.**

**Do not invoke** `/wayfinder`, `/to-spec`, `/to-tickets`, `/implement` or
`/mattpocock-skills:code-review` — retired 2026-09-26. See `docs/agents/workflow.md`.

### Interaction rules

Nine rules for how every control behaves: `PRODUCT.md` §Interaction Rules. **Any spec,
plan task or review that touches UI checks against them**, and the e2e auditor covers
them. Don't propose a confirmation, a refusal, Enter-to-commit or a jump away from where
the operator was without naming the rule that allows it.

### Issue tracker

GitHub Issues on `yehia-khalil/wakil`, via the `gh` CLI. **A bug inbox, not a work
tracker** — specs and plans are files. See `docs/agents/issue-tracker.md`.

### Triage labels

Three: `bug`, `needs-triage`, `wontfix`. See `docs/agents/triage-labels.md`.

### The e2e auditor

Reads the branch, writes the checks that cover what it touched, proves each one
could fail, and reports only what it **could not** cover. Turns the **Cover**
rung. See `docs/agents/e2e.md`.

### Domain docs

Single-context, but **not** at the default paths: this repo's context and decision
records live under `docs/wakil/`. See `docs/agents/domain.md`.
