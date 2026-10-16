# Domain Docs

How the engineering skills should consume this repo's domain documentation when
exploring the codebase.

## Before exploring, read these

This repo does **not** use `CONTEXT.md` or `docs/adr/`. The equivalents predate
this setup, are actively maintained, and are where the binding material lives:

- **`docs/wakil/north-star.md`** — the charter, and the context doc.
  **§4 Invariants are binding constraints, not guidance**; §9 is the glossary.
  It holds itself under 4,000 words, so it points outward rather than growing.
- **`docs/wakil/decisions.md`** — numbered decisions with their rationale.
  These are the ADRs; cite them as "Decision N".
- **`docs/wakil/open-questions.md`** — numbered open questions, some already
  ruled on. Check here before proposing something that looks novel; it may be
  a question that was asked and settled.
- **`docs/wakil/*-acceptance.md`** — one acceptance runbook per phase. A phase
  is not met until an operator has walked its runbook; writing one is not
  walking it.
- **`docs/superpowers/specs/`** — per-sub-phase design specs. A spec is binding
  authority for its own sub-phase, and the plan beside it in
  `docs/superpowers/plans/` argues from it.
- **`PRODUCT.md`** (repository root) — the product record the Impeccable design
  skill reads, at the one path its tooling resolves. It is a **pointer, not an
  authority**: it cites the charter and `design-language.md` by section rather
  than restating them, and where it disagrees with either, the charter or the
  design language wins and `PRODUCT.md` is the file to correct.

Unlike the default version of this file, **do not proceed silently** when you
cannot find `CONTEXT.md` or `docs/adr/`. They are absent by design. Read the
files above instead — an agent that skips them misses the invariants entirely.

## Use the glossary's vocabulary

When your output names a domain concept — an issue title, a refactor proposal, a
hypothesis, a test name — use the term as `north-star.md` §9 defines it. Don't
drift to synonyms.

If the concept you need isn't in the glossary, that's a signal: either you're
inventing language the project doesn't use (reconsider), or there's a real gap
worth recording.

## Flag conflicts with an invariant or a decision

Invariants are the strong form. Contradicting one is a design change, not a
judgement call you can make inside a task. Surface it explicitly rather than
silently overriding:

> _Contradicts Invariant 4 (an organisation is a credential boundary), but worth
> reopening because…_

The same applies to a numbered decision in `decisions.md`. Where a spec and the
shipped code disagree, **the code is what ships** — say so, and correct the spec
rather than quietly matching it.
