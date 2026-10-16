# Pane layouts keyed by conversation — acceptance

**Status: WALKED 2026-09-21 — the operator reports it good.**

The walk ran in two passes. The first, on 2026-09-20, **failed at step 10 and changed the
design**: a project switch inside a conversation did not move a pane, which is what this
runbook then said it should do. That produced
[#160](https://github.com/yehia-khalil/rafiq/issues/160), the row was rewritten to the new
ruling, and the second pass walked it in that form.

[#161](https://github.com/yehia-khalil/rafiq/issues/161) came from **reading the files
after the walk passed** — a conversation with nothing open was emptying the project's
seed. Nothing on screen was wrong at any point, which is why the file-side rows of this
runbook exist.

The account is in `phase-log.md`, 2026-09-21. The **Result** column is left as the
operator's single verdict rather than ten cells filled in after the fact: they walked it
and reported it good, and a transcript nobody took is not one this document should invent.

**Spec:** [#142](https://github.com/yehia-khalil/rafiq/issues/142) — *Key pane layouts by
session lineage, so continuing a conversation restores its workspace.* Delivered by four
tickets: [#146](https://github.com/yehia-khalil/rafiq/issues/146) (the scope value),
[#147](https://github.com/yehia-khalil/rafiq/issues/147) (a conversation's panes come back
when you resume it), [#148](https://github.com/yehia-khalil/rafiq/issues/148) (switching
conversations swaps the canvas), and
[#160](https://github.com/yehia-khalil/rafiq/issues/160) (switching project inside a
conversation swaps it too) — the last of which the **first walk of this runbook produced**,
by overturning #142's user story 12 at step 10.

**Not a numbered sub-phase.** #142 is cross-cutting — there is no row for it in
`north-star.md` §8 — so this runbook is named for the work rather than for a phase, on the
same footing as `permission-prompt-acceptance.md` and `shared-accounts-acceptance.md`.

**What it claims, in one sentence:** an arrangement belongs to a *conversation* rather than
to a project, so resuming one gives you back the workspace it happened in, two
conversations in one project stop overwriting each other, and switching between them with
⌘P swaps the canvas the way switching project already does.

## Before you start

**Copy your layouts first.**

```
cp -R ~/.wakil/layouts ~/.wakil/layouts.before-142
```

This is not boilerplate. The defect #148 found *destroyed layout files* — a switch onto a
conversation with no arrangement of its own wrote an empty canvas over both that
conversation's file and the project's seed, and the seed is what every later conversation
in that project opens on. Checks 3 and 6 are the ones that would catch it coming back, and
both are read against your real files. Walk with a copy in hand.

**Record the starting state**, because three checks below compare against it:

```
find ~/.wakil/layouts -type f | sort
cat ~/.wakil/layouts/<org>/<project>.json | jq '.panes | length'
ls ~/.wakil/orgs/<org>/sessions.json
```

Two files exist on this machine today, both pre-#142 and both project-keyed:
`acceptance-b/wakil-acceptance.json` and `personal/wakil-acceptance.json`. They are check
6's subject.

**You need, in one project, at least two conversations with real transcripts** — two that
⌘P lists as separate rows. If you do not have them, make them: send a turn, quit, relaunch,
send a different turn. A conversation with no turn has no transcript and does not appear in
the listing, which is a state check 7 covers deliberately.

**Run the bundle, not a test run.** `make app-bundle`, then launch it with
`phase-2b-i-acceptance.md` §1's command — the explicit `WAKIL_ORG` / `WAKIL_PROVIDER` /
`CLAUDE_CONFIG_DIR` form, unchanged, because checks 1, 2 and 9 need a real agent and a real
transcript store. Nothing below is reachable from `swift test`: every automated test in
this work drives a `session_get` **double**, so the real `wakilcore` lineage resolver has
never once answered a window. Check 4 is the only place it does.

## The checks

**Ten, and these are the walk.**

| # | Do | Pass | Stands for |
|---|---|---|---|
| 1 | From the Landing, resume the **older** of two conversations in a project you have worked in since | Its panes come back — not the ones you had most recently | #147's headline |
| 2 | ⌘P → the other conversation. Then ⌘P → back. Open a pane, ⌘P away, ⌘P back again | The canvas swaps both ways, and the second return still has the pane you opened after leaving | #148's headline, and the in-memory return |
| 3 | ⌘P → a **brand-new** conversation (one with no arrangement). Then `cat ~/.wakil/layouts/<org>/<project>.json` | The canvas shows the project's seed, and the file still holds an arrangement — **not** `"panes": []` | The defect #148 found, on real disk |
| 4 | Resume one conversation three times. Then `ls ~/.wakil/layouts/<org>/conversations/`, and walk `~/.wakil/orgs/<org>/sessions.json` child→parent by hand from the newest id | One file, not three, and its name **is** the oldest ancestor that walk reaches | The Go resolver, which no test has run |
| 5 | Arrange a `db` pane with rows on screen. Quit. Relaunch and resume that conversation | The pane comes back **with rows**, not reading "no rows" | The swallowed-refetch class (2c-iii) |
| 6 | Open the project whose layout file predates this work — `wakil-acceptance` in `acceptance-b` or `personal` | It loads as the seed, and `find ~/.wakil/layouts -type f` shows it neither renamed nor deleted | "No file is discarded" |
| 7 | From the Landing of a fresh conversation, open a pane and **type nothing**. Quit. Relaunch and resume it | The pane is there | A pane filed before any turn exists |
| 8 | Switch organisation, then switch back and reopen the same project | Going out: an empty canvas. Coming back: the arrangement is read from disk again, not drawn empty | Invariant 4, and `loadedLayoutScopes` |
| 9 | In ⌘P, pick a session belonging to a **different provider** | It is refused in the status line, and not one pane moves | A refused switch costs nothing |
| 10 | Mid-conversation, switch **project** with ⌘P, then back | The panes swap **both ways**, and a project the conversation has never been arranged in opens on that project's seed — or empty | #160 |

**Result: walked 2026-09-21, reported good**, in the two passes the status line above
describes. Step 10 is the row that failed on the first pass and was rewritten; steps 3, 6
and the file half of 10 were additionally checked against the files on disk, and what that
found is #161.

No per-check cells: the operator walked it and gave one verdict, and this document should
record that rather than invent ten results nobody wrote down. A future walk of this runbook
should fill them in as it goes — that is what the column is for, and the difference between
a transcript and a memory is the whole reason this repository distinguishes *walked* from
*accepted*.

## What each check is really asking

**1 and 2 are the sub-phase.** Everything else is a variation or a way it could be quietly
wrong. If 1 fails, read `~/.wakil/layouts/<org>/conversations/` first: a missing directory
means no conversation ever got its own file and the window is still filing everything under
the project.

**2's third leg is the one that matters.** Switching away and back is easy to get right by
reloading from disk; what that would cost is the pane you opened *after* leaving, because a
reload replaces an arrangement wholesale. The window keeps every visited conversation in
memory and deliberately does not re-read one it has already read. If the pane you opened
after the switch away is missing on the second return, the read guard has gone.

**3 is the defect this work found latest, and it is the one check where a pass means
nothing happened.** Pointing the stores at an incoming conversation takes two actor hops
and a file read, and in between the store answers with an *empty* arrangement filed under a
conversation nothing has restored yet. A commit landing in that window wrote that empty
canvas — and because a conversation's save also refreshes the project's seed, one switch
emptied both files. Watch the file, not the screen: the canvas can look right while the
seed on disk is already `[]`, and you would not find out until the next new conversation
opened on nothing.

**4 is the only check in this document that runs the real lineage resolver.** Every
automated test drives a `session_get` double, because a real one needs a real transcript
store with a real fork chain in it. So the claim *"six forks are one workspace, not six"* is
pinned in tests only against a fake that was told the answer. Here the answer comes from
`wakilcore.LineageRootIn`, resolved through `session_get` against
`~/.wakil/orgs/<org>/sessions.json` — a flat child→parent map, which is why you can check
its answer by hand:

```
jq . ~/.wakil/orgs/<org>/sessions.json
```

Find the newest session id as a **key**, read its parent, look that up as a key in turn,
and keep going until an id is not a key any more. That id is the root, and it must be the
filename under `conversations/`. Three files instead of one means the root is not being
inherited and every resume is starting a new workspace. A filename that is *not* that root
means Swift and Go disagree about what a conversation is — the failure #142 chose to
resolve in Go precisely to avoid, and the one that loses a workspace with nothing
anywhere failing.

**5 is inherited, not new.** A layout file persists a pane's *subject* and never its rows,
on purpose — redrawing yesterday's rows would show a database state that may no longer
exist — so restoring one gives a pane with a frame, a title and a query and nothing in it,
and something has to run the query. That refetch is gated on the arrangement having come
from **disk**, so a restore that silently came from memory will look identical and be
empty. This is the shape that survived to the 2c-iii walk once already.

**6 is the migration that deliberately did not happen.** Nothing was renamed, nothing was
converted and nothing was deleted: a project's file stays where it is and *becomes* the
seed a conversation with no arrangement of its own opens on. The check is therefore as much
about `find` as about the window — a file that loads correctly but has been rewritten under
a new name has failed it.

**7 is the case the window cannot look up.** A session that has never taken a turn has no
transcript, so it is in no listing at all — and that is exactly the case this has to work
for, because opening a pane from the Landing is an act of work that happens before any
turn. The conversation identity and the pane have to be born together. If the pane is
missing after the relaunch, it was filed under nothing.

**8 is Invariant 4 and has a second half worth naming.** An organisation is a credential
boundary, so a switch forgets every arrangement — that is the easy half, and a blank canvas
on the way out is the pass. The half that is easy to break is coming *back*: the record of
which arrangements have already been read must be cleared along with them, or the window
believes it has already read this conversation, skips the disk, and draws you the empty
canvas the switch just left behind.

**9 is a refusal, and refusals are where half-applied state lives.** The switch is refused
before anything is touched, so the canvas belongs to the session still running. Try the
other refusal too if you can stage it — picking the session *this window is already
running* — and check the wording differs.

**10 was written the other way round, and the walk overturned it.** Until 2026-09-20 this
step said the panes must *not* swap — one conversation, one workspace, whichever project it
was visited from (#142's user story 12). The operator walked it, switched to a project with
no sessions at all, found the previous project's panes still on screen, and ruled the other
way. An arrangement is now keyed by conversation **and** project.

What story 12 was actually protecting is untouched: a fork chain must not resolve to a
different root depending on what a listing happened to show, and that is bought by
resolving the root in **Go** against the organisation's complete parent map. Read it as:
the same conversation in the same project resolves to the same arrangement every time.

The second half of this check is on disk. A conversation's panes must never be written into
a *different* project's seed — measured during the first walk, standing in one project while
working in another's conversation created that project's seed file holding the other's
panes. `cat ~/.wakil/layouts/<org>/<the other project>.json` and confirm it is that
project's own arrangement, not the one you carried in.

The ruling is [on #142](https://github.com/yehia-khalil/rafiq/issues/142#issuecomment-5752598571);
the work is [#160](https://github.com/yehia-khalil/rafiq/issues/160).

## What this walk cannot establish

- **Reclamation.** #142 defines when an arrangement becomes eligible to be dropped — its
  conversation no longer appearing in `list_sessions` — and deliberately builds no sweeper.
  The layout directory grows. Nothing here checks otherwise.
- **A conversation's name.** Untitled conversations fall back to a raw id in ⌘P and on the
  Landing, so checks 1, 2 and 9 are walked against UUIDs.
  [#145](https://github.com/yehia-khalil/rafiq/issues/145) is that gap, filed separately.
- **A long chain.** Check 4 resumes three times because that is what an afternoon affords.
  The property claimed is *any* depth, and the pure resolver's own tests are where depth,
  cycles and self-parents are pinned (`sessions_lineage_test.go`).
- **Whether `make app-test` is green.** It is not, and
  [#127](https://github.com/yehia-khalil/rafiq/issues/127) is why — a varying set of
  pre-existing failures across three suites. #148 measured five full runs against five on
  its parent rather than asserting a number; see its closing comment.
- **Concurrent windows.** One window is assumed throughout. Two windows in one conversation
  writing one file is not a case this work reasoned about.
