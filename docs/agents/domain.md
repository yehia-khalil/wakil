# Domain Docs

How the engineering skills consume this repo's domain documentation.

## Before exploring, read these

This repo does **not** use `CONTEXT.md` or `docs/adr/`; they are absent by design, so
**do not proceed silently** when you cannot find them. Read these instead — an agent that
skips them misses the invariants:

- **`docs/wakil/north-star.md`** — the charter, and the context doc.
  **§4 Invariants are binding constraints, not guidance**; §9 is the glossary. It stays
  under 4,000 words, so it points outward rather than growing.
- **`docs/wakil/decisions.md`** — numbered decisions that still stand, in short form.
  These are the ADRs; cite them as "Decision N".
- **`docs/wakil/open-questions.md`** — numbered questions, some already ruled on. Check
  here before proposing something that looks novel; it may have been asked and settled.
- **`docs/superpowers/specs/`**, **`docs/superpowers/plans/`** and
  **`docs/wakil/*-acceptance.md`** — a feature's spec, plan and runbook. They are on its
  branch while it is built, and the spec is binding for that sub-phase; they leave `main`
  with it, after its standing decisions move to `decisions.md`. A phase is not met until
  an operator has walked its runbook. A cited path that no longer exists:
  `git log --all -- <path>`.
- **`PRODUCT.md`** (repository root) — the product record the Impeccable design skill
  reads. A **pointer, not an authority**: where it disagrees with the charter or
  `design-language.md`, they win and `PRODUCT.md` is the file to correct.

## Use the glossary's vocabulary

When your output names a domain concept — an issue title, a refactor proposal, a
hypothesis, a test name — use the term as `north-star.md` §9 defines it. Don't drift to
synonyms. A concept missing from the glossary means you are inventing language
(reconsider) or there is a real gap worth recording.

## Flag conflicts with an invariant or a decision

Contradicting an invariant is a design change, not a judgement call inside a task.
Surface it explicitly rather than silently overriding:

> _Contradicts Invariant 4 (an organisation is a credential boundary), but worth
> reopening because…_

The same applies to a numbered decision in `decisions.md`. Where a spec and the shipped
code disagree, **the code is what ships** — say so, and correct the spec rather than
quietly matching it.
