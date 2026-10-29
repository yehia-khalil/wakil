# Docs lifecycle — feature documents leave with the feature

**Status:** proposed 2026-10-29 · **Owner:** Yehia Khalil

## Why

Wakil and Jarvis (`mmAbdelhay/jarvis`) carry about the same amount of production code
(165k vs 139k lines), but Wakil's repo holds 1.41M words of Markdown against Jarvis's
57k. Reads in every Wakil session transcript since 2026-10-16 show what that prose is
used for:

| Pile on `main` | Words | Read again after its feature merged |
|---|---|---|
| `docs/superpowers/plans/` (81) | 672k | 3 reads, one session |
| `docs/superpowers/specs/` (61) | 181k | 85% of the words never |
| `docs/wakil/` (107) | 596k | half the words never |

Plans, specs and acceptance runbooks are working documents for one feature's build.
After merge nothing reads them. The ongoing cost comes from the few files every
session does read and that grow without limit: `decisions.md` (23k words, read 1,092
times) and `phase-log.md` (48k words, 84 reads).

## Goals

- Feature documents exist only while their feature is being built.
- The files every session reads stay small.
- Nothing a later feature needs is lost.

**The operator's bar for every trim (2026-10-29):** trim as much as possible, as long
as it doesn't change the logic or how well an agent does on a new task. In practice:
cut a sentence if an agent starting a new task would act no differently without it.
This applies to every file this design touches, and to the files every session reads:
`north-star.md`, `design-language.md`, `decisions.md`, `PRODUCT.md`,
`docs/agents/*.md` and `CLAUDE.md`. §4 Invariants and §9 Glossary keep their meaning
word for word, though their prose may tighten.

## Non-goals

- **The rungs and gates do not change.** Design, Plan, Build, Cover and Walk stay,
  including `make e2e`/`make e2e-new` and the operator's walk before merge. The
  operator: these catch bugs that would have been catastrophic on `main`.
- Shrinking plans or specs while they are in use.
- Running e2e away from the operator's screen. That is a separate design (a macOS VM),
  to follow this one.

## Anti-goals

- A decision that still governs the code disappears from `main` with its spec.
- A rule that only holds when someone remembers it.

## What changes

1. **Plans, specs and acceptance runbooks live on the feature's branch.** They are
   committed there as today, so stacked branches and other worktrees can use them. The
   PR that lands the feature on `main` deletes them. Git history keeps them.
2. **A spec's lasting decisions move before it goes.** Before the delete, every
   decision in the spec (or its amendments) that still governs the shipped code
   becomes an entry in `decisions.md`: the call, one line of why, and the commit. The
   operator reviews these in the PR.
3. **`decisions.md` holds only decisions that still stand, each in short form.** An
   entry is the call, one line of why, one line of what would reverse it, and the
   commit. Amendment history is dropped; git keeps it. A ruling counts as a decision
   when reversing it would change the code or a check. When a later decision replaces
   one, the old entry becomes a one-line tombstone, *"Replaced by Decision M
   (commit)"*, so the 247 `Decision N` citations in code still resolve. Numbers stay
   permanent. The file's own rule "never deleted — the history is the point" is
   changed to match.
4. **`phase-log.md` holds only sub-phases not yet merged.** *(My call on what
   "current" means.)* A sub-phase's entry is written on its branch, and its merge PR
   deletes it. Anything still owed moves to `parked.md`. The walk record itself is the
   runbook, which git keeps. The file's preamble shrinks to a few lines. `north-star.md`
   §8 keeps the status table and the `Met` column as today.
5. **A spec or plan never merges to `main` alone.** No separate design or plan PRs (as
   #71 was). They ride the stack and leave with the build.
6. **The rule is checked.** A `make merge-check` target fails if the tree contains any
   file under `docs/superpowers/plans/` or `docs/superpowers/specs/`, or any
   `docs/wakil/*-acceptance.md`. It is not part of `make test`, which runs on branches
   where these files belong. *(My calls on timing:)*
   - The delete is the branch's last commit, made **after the walk passes**. A PR can
     be open before that; `merge-check` gates merging, not opening.
   - In a stack, each PR deletes only its own feature's files. `merge-check` runs only
     on the PR that targets `main`, once the branches below it have landed.
   - The night run on `main` runs it too, starting after the cleanup PR lands.
7. **The agent docs say so, briefly.** `docs/agents/workflow.md`, `docs/agents/domain.md`,
   `docs/agents/e2e.md` and `docs/architecture/README.md` are updated to match. One line
   in `domain.md` covers a cited path that no longer exists: find it with
   `git log --all -- <path>`.

## One-time cleanup (a separate PR, after the rules land)

- Delete all plans on `main`, all specs on `main` and all 54 `*-acceptance.md`.
- Before deleting specs, apply rule 2 to them.
- Rewrite `decisions.md` to rule 3's short form, and apply rule 4 to `phase-log.md`.
- Trim the always-read files to the operator's bar above.
- Specs and plans on unmerged branches (connections, ticket view) are not touched
  there. They follow rule 1 when their own PRs land.

## Left to the builder

- How `merge-check` is written and how the night run reports a failure.
- The wording of the doc updates, kept short.
- Code comments that cite a deleted path stay as they are (rule 7 covers them). This is
  my call, so the cleanup doesn't touch 36 source files.

## Out of scope, noted

- `docs/wakil/*-probe.md` (17 files) are per-feature too and could follow the same
  rule. They are not included because it wasn't discussed.
- Long prose comments in code (the `Makefile`, for one).
