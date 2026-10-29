# Ticket work: connections, the Ticket view, reviews, hand-off and routines

**Date:** 2026-10-25
**Status:** umbrella design awaiting the operator's review. Shaped with the operator in one session
(mockups in `.superpowers/brainstorm/`, not committed). Each numbered piece below gets its own
design before it is planned; piece 1 has one already:
`2026-10-25-connections-design.md`. Calls the designer made are under *Calls made for the
operator*.
**Sub-phase:** a new row after 3a-v. It absorbs the deferred **2c-vi PM board** (its read half
becomes the Ticket view and the Landing's list; its writes stay behind open question 15) and
answers part of Phase 4's "earned write paths".

---

## Problem

The operator's day is tickets, not panes. A ticket starts in a PM tool, becomes one or more
branches and pull requests, collects review comments from people and bots, passes gates
(tests, CI, a PM status check), is deployed somewhere to be checked, and has its PM status
moved on. Every repo does this differently:

- **Initech Labs** (the operator leads): stacked pull requests merged top-down by squash, a QA
  deploy by a manual CI dispatch, then the tickets moved to *Ready for QA*.
- **Umbrella** (the operator is one developer among many): twin pull requests against a staging
  and a production branch, reviewers who are other people, review bots, and a CI check that
  fails until the ticket is *Ready for Deployment*.
- **This repo**: Design → Plan → Build → Cover → Walk, specs and plans as files, e2e gates.

Today Wakil knows the PM tool (`wakil-pm`: read issues, one transition) and git. It knows
nothing about pull requests, reviews, CI, deploys, or any other service the operator uses
(design files, logs and metrics, analytics, chat, wikis), and an agent inside Wakil can reach
none of the operator's own MCP servers, because every session starts with
`--strict-mcp-config` and Wakil's own servers alone (`AgentMCPConfig.swift`). The operator
holds the record of where each ticket stands in per-account handoff notes that only one
harness reads.

## Decided by the operator (2026-10-25)

1. **Every repo keeps its own process.** Wakil reads it; it never imposes one. A repo that
   declares none still gets the plain ticket loop (ticket, branch, PRs, comments, next step).
2. **Both directions.** Work the operator starts, and work that arrives — review comments from
   people and bots — which the operator answers, fixes, or hands to an agent.
3. **Provider- and harness-agnostic.** Nothing here may depend on one harness's skills,
   subagents or hooks (Invariant 1). A step goes to whichever harness and provider the operator
   picks, with a plain-text brief.
4. **Skills stay out of Wakil.** They live where they live today (the account's config dir, the
   repo); Wakil neither lists nor manages them.
5. **The per-harness handoff notes stay.** Wakil's ticket record sits beside them; it does not
   replace or rewrite them.
6. **Connections are per organization**, with room for a project to override one later (a
   project whose PM tool differs from the rest of its organization: open question 6, Azure
   DevOps).
7. **The UX is the point: clean and streamlined.** Nothing new is permanently on screen. Things
   appear where they will be handled, and only while there is something to handle.
8. **No new pane** for any of this. The ticket lives in the editor's left column.
9. **The agent chips stay about agents.** A review arriving is not shown beside them.

## The pieces, in build order

### 1. Connections — the operator's own MCP servers, per organization

Full design: `2026-10-25-connections-design.md`. In short: in organization settings the
operator adds a connection from a ready-made list (GitHub, Jira, Confluence, a design tool, a
logs-and-metrics service, an analytics service, a chat workspace) or as a custom server; signs
in the way that server needs (one token, several fields, a browser sign-in, or nothing); every
secret goes to the Keychain. The connection's page lists the server's tools, each with an
**Allow agent** switch. Every session in that organization gets its connections, whatever
harness runs it. **This is the foundation:** pieces 2–6 read GitHub, the PM tool and CI through
it.

### 2. The Ticket view — reviews and the ticket record in one place

A **fourth view in the editor's left column**: **Files · Search · Changes · Ticket**. It
follows the branch the editor is on.

**Its header** (when the branch has a ticket): the ticket's key and title, its PM status, who
it is waiting on, and **Next:** one line. In a repo that declares a process, the header also
carries the **steps row** (piece 4).

**Below the header:** the branch's pull requests, each with its open review threads (file:line
and the first words), its CI checks, and its state (open, merged, blocked). At the bottom,
folded under one line, **Decisions · Not done · Verified ▸** — the content of today's handoff
note.

**Each review comment is also drawn in the file**, under the line it is on, the way the
conflict actions row is drawn today (`monaco-host.html`, `placeConflictRows`): author, time,
text, and **Reply · Hand to agent · Resolve · "1 of 5 · ⌥↓ next"**. There is no "fix it"
button: the operator is already in the file and types. **Reply** opens a draft inside the box;
nothing is posted until **Send** (the operator's draft-first rule; Interaction Rule 1 — posting
is a write whose price is *gate*). Clicking a thread in the column opens its file at its line
and leaves the column where it was (Rule 6).

**When the branch is not one ticket:**

| Case | What the view shows |
|---|---|
| On the default or a long-lived branch (`main`, `staging`) | No header. **Waiting on you** (threads and gates that need the operator), then **In flight** — every ticket in flight in this organization. |
| A branch with no ticket found | "No ticket found for this branch", where Wakil looked, and **Link a ticket…** (optional; one field that keeps what is typed, Rules 2 and 9). The branch's own PRs and comments still show: comments belong to the branch, not the ticket. |
| Several tickets (one branch, or a stack of branches) | The header lists every ticket the branch or its stack carries, marks the one this branch is for, and gives one **Next** for the lot. |

**Picking a ticket from the In flight list shows it in the view; it never switches the branch**
(Rule 6).

**How Wakil links a branch to a ticket**, first answer wins, all answers shown when several
match:

1. a link the operator or an agent made (stored in Wakil's record);
2. the branch name;
3. the branch's pull request, title and body;
4. commit trailers (`Ticket: INI-142`);
5. the PM tool's own development panel (the issue's linked branches and PRs).

Only keys that belong to a project of the organization's PM connection count, so `fix-UTF-8`
is not ticket UTF-8.

**"In flight"** means a ticket with a branch, an open pull request, or an agent working on it,
in this organization.

### 3. Noticing, finding, and handing to an agent

- **Noticing.** When something needs the operator (a new review comment, a failing gate), the
  **Editor's row in the rail gets an amber tick and a count** (`Editor · 5`), and the Ticket view
  label carries the same count. Nothing appears at the top of the window. The tick clears when
  every thread is handled. (Amber is §5's *pending*; the 2pt tick is §10's rail mark in a third
  hue.)
- **The Landing** gains **Tickets in flight** above *Sessions to continue*, each ticket with its
  single most urgent state in words ("#212 · 5 comments", "Jira gate", "Build 4/9 · working").
  Choosing one opens the editor on its Ticket view.
- **⌘P.** The empty list is unchanged — no tickets. Typing that matches a ticket in flight adds
  it: a key or number puts the ticket first with its PRs under it; words put it after files and
  tables. A leading **`#`** lists tickets in flight alone (as `>` switches to ⌘K). Return opens
  the editor on its Ticket view. ⌘P is never a search of the whole PM tool.
- **Hand to agent** — one popover, the same from a review comment, the Ticket header, or ⌘P:
  a **brief, prefilled** from the thread or the record and editable (focused, Rule 3), a
  **harness** and a **provider** (defaulting to the last used, Rule 9), a **Similar before** line
  from recall (piece 6, deletable), and **Start ⌘↩**. It starts a background conversation (the
  Conversations feature): its chip is an ordinary agent chip. Its replies land as drafts on their
  threads; its progress lands in the ticket record; pushes, posts and merges still raise the
  permission plane.

### 4. The steps row — a repo's declared process

If a repo declares a process (this repo: `docs/agents/workflow.md`; others: their CLAUDE.md,
AGENTS.md or workflow docs), the Ticket header shows one row of steps:
**✓ Design · ✓ Plan · ● Build 4/9 · Cover · Walk · PR**. The row lives only there; the Landing
and ⌘P show the current step as words.

- **A step is done when its evidence exists** — a file, a branch, a PR, a ledger line — never by
  a hand tick.
- **Rulings** (choices an agent made while the operator was away) are a count in the header,
  each listed for the operator to keep or overrule.
- A repo with no declared process shows no row: same view, one row fewer.

### 5. Then — what comes after a step

When a step finishes (a merge, a deploy, a gate passing), the Ticket header offers a short
**Then** list of next moves, each one click: **Run** a deploy (a CI workflow dispatch, shown
live under the ticket, cancellable — Rule 4), **Move** the ticket(s) to a status, **Draft** a
comment on the ticket. A gate that fails says why in full (Rule 8) and offers its fix ("#213
blocked: the ticket must be *Ready for Deployment*" → **Move**).

**Where the Then list comes from** (decided): the repo's own docs where the routine is written
down, **plus what the operator did last time** — Wakil notices "after a merge here you deployed
QA and moved the ticket" and offers it; the operator keeps or drops each suggestion. Nothing
runs by itself.

A footer line under the ticket shows **time tracking** and **presence** for the ticket on
screen, only when the organization has those connections.

### 6. People, recall and cost — one line each

- **People.** "Waiting on" comes from the PR's requested reviewers and its open threads. Opening
  a PR suggests reviewers from who reviewed this repo before; the operator chooses. A question
  that waits on a person is a **Not done** line with **Draft message** (sent only on sign-off).
- **Recall.** The hand-off brief carries **Similar before** — past tickets that look like this one
  — from `wakil-recall`.
- **Cost.** Each agent run records its provider, seat and tokens; the ticket's folded section
  says "Agent time: 3 runs · 410k tokens · <provider>". No dashboard.

## The ticket record

One record per ticket per organization, written by Wakil (from what it reads) and by whoever
works the ticket (the operator or any agent, through a Wakil action — Invariant 2): branches and
PRs, decisions and why, not done, waiting on, verified, next step, rulings. It is what the
Ticket view's header and folded section show. Agents read and write it through an MCP tool, so
every harness sees the same record. It never replaces a harness's own notes.

## Non-goals

- A PM client, a code-review website, or a CI dashboard. Wakil shows what needs the operator and
  links to the rest (charter §5).
- Managing skills.
- Searching the whole PM tool from ⌘P.
- A board pane. 2c-vi's board is not built; its read half is the Ticket view and the Landing.
- Anything that posts, moves or deploys without the operator's click.

## Anti-goals (a failure even if it works)

- A new always-on surface: a dashboard, a sidebar, a second row of chips.
- An empty ⌘P that is longer than today's.
- A review notification confused with an agent's state.
- A design that only works with one harness.

## Interaction Rules

| Rule | Where it bites | How this meets it |
|---|---|---|
| 1 Confirm only what destroys or gates | Reply, Move, Run, Draft message | Each is one click on a draft or a named action; posting and deploying raise the permission plane (price *gate*); nothing else asks. |
| 2 Enter never required | Reply draft, Link a ticket, the brief | Fields keep what is typed on blur. |
| 3 New input focused | Reply box, Link a ticket, hand-off brief | Focused on open. |
| 4 Waiting can be cancelled | Deploy run, hand-off agent | Cancel on the deploy row; the agent's chip stops it. |
| 5 Work in flight shows, can't fire twice | Run, Start | The row shows *running*; the control is disabled while it runs. |
| 6 Stay where the operator was | Picking a ticket, a thread, Then actions | No branch switch, column stays, record stays open. |
| 7 Override or ignore, don't refuse | Linking | A later link overrides an inferred one. |
| 8 Errors whole | Gates, deploys, connections | The gate's or server's message, untruncated. |
| 9 Defaults suggest | Harness/provider, Then list, reviewers | Pre-filled, never enforced. |

## Calls made for the operator

- The ticket record is Wakil's own store, per organization, readable by agents through MCP.
- The steps row's evidence is read, not ticked.
- Amber is the tick's hue (pending), reusing the rail's existing 2pt mark.
- "In flight" is defined as above.
- 2c-vi is absorbed rather than built.
- Build order is 1 → 6; 2 and 3 ship together (the view is useless without noticing it).

## Open questions

- Open question 15 (can a PM transition automation break Invariant 6's reversibility?) now
  applies to **Move** in the Then list.
- Open question 16 (`Connection` means an org account in §9 but a database in `wakil-db`) — this
  design uses §9's meaning; the database sense should be renamed when piece 1 is planned.
- How "what you did last time" is learned and stored (piece 5's own design).
