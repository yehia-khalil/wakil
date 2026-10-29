# Workspaces 3 — the home screen and ⌘P: plan

**Spec:** `docs/superpowers/specs/2026-10-29-workspaces-design.md`, piece 3 (decisions 5, 18–27, 29;
the piece 1 amendment's "Main's view is still per conversation"). **Branch:**
`yehia-khalil/workspaces-3-home`, from piece 1's head 38d5a5f3. Mockup (not committed):
`.scratch/workspaces/home.html`, panels A, A2–A5, B, C.
Each task is test-first: the failing test, then the code, then `make test` / `make app-test` green,
then a commit `workspaces: <what>`. Everything decided is in WakilKit; `WakilApp/Home.swift` draws.

## Decisions this plan makes (recorded in the spec's piece 3 amendment)

- **A view with no agent is a conversation slot with no turn.** The window already mints a
  conversation the moment a pane opens over the Landing, with no process behind it. Opening a view
  (Main's, or a workspace's with no live conversation) does the same with no pane: the slot's canvas
  is Main's view (the project + environment seed, as the Landing draws over today) or, moved into the
  workspace, the workspace's view. Typing in its composer starts the agent there. Main's **Open**
  goes back to the place's slot when one is live, so Main keeps one view per environment.
- **`workspace_open {workspace, project?, environment?}`**, operator-only `.control`: `main` (with
  the project and environment, else the screen's) or a workspace id. A workspace opens on its most
  recent live conversation, else its view with none. The card, a project's Open, ⌘P's workspace
  rows and the first-run line all dispatch it (Invariant 2). It parks on the conversation broker
  (`ConversationRequest.openView`), as `session_switch` does.
- **`workspace_new_conversation {workspace}`**, operator-only `.control`: New conversation here —
  a fresh slot in that workspace's view, composer focused (Rule 3).
- **Start on a ticket not started here opens the ticket** (`ticket_open`), where Hand to agent
  starts it: the record-only workspace for a ticket comes with crews (piece 5), which own Start.
- **PRs on a card** are the in-flight rows of the workspace's tickets (or its branches): counted,
  never fetched again here. Archive is always in ⋯ (decision 11 forbids only automatic archive);
  the merged-PRs offer waits for a read that carries merged PRs (ticket work piece 4).
- **The composer's project picker is a place switch**: its choices are each project of the
  organization (at the environment it was last in, else its first) and the current project's other
  environments; choosing one runs the same switch the context line does, and the draft stays.

## Phase A — the home, pure (`WakilKit/Workspace/HomeScreen.swift`)

1. `HomeInput` → `HomeScreen`: title *Work in <org>*; sections per project, the current first
   (*you are here*), then by latest activity; a project with nothing going on not drawn (the
   current one is, for Main and its Open).
2. Within a project: Main (its live conversations; drawn while one is in it), then cards needing
   the operator, then working, then the rest by latest activity; a child under its parent, a
   child of an archived parent on its own.
3. `HomeCard`: name (`<KEY> <title>` or the workspace's name), environment and production, each
   repo with its branch or *in Main*, the PRs line (`7 PRs open · 2 checks failing`), what needs the
   operator (amber), one line per live conversation (state, title, repos it holds), menu facts
   (Bring to Main's repos, Move candidates, archive confirm when one waits).
4. Pills: *All projects* and each drawn project with its needs-you count; a filter narrows the
   sections and never moves the place.
5. Tickets not started here: in-flight rows whose key no workspace carries, needs-you first.
6. Earlier: archived workspaces (each Restore) and past conversations grouped by workspace (by
   lineage chain), newest first; the folded line's words (`3 archived workspaces, 11 past
   conversations`).
7. Help line in full with three cards or fewer, else ⓘ; first run (nothing live, no workspace): the
   help line, tickets, *Open a pane: Database · Terminal · Browser*.
8. Conversation lines numbered in drawing order (`landing.row.running:<n>`, kept from the Landing so
   the checks that click a conversation still name it).

## Phase B — ⌘P and the composer (`Command/`, `Workspace/`)

1. `RunningConversationsSource` grouped by workspace: a row per workspace (Main per place
   included; Return dispatches `workspace_open`), its live conversations under it.
2. `homeStartChoices` (the picker's rows) and `homeComposerPlaceholder` (*Ask anything — in estate ·
   staging*; one project: *in estate*).

## Phase C — actions and the window

1. `ConversationRequest.openView` / `.newHere`; `workspace_open` and `workspace_new_conversation`
   registered with the workspace actions; added to `operatorOnlyActions` and the pinned list.
2. `WindowModel.openWorkspaceView` / `newConversationHere` (slot, move into the workspace, view
   follows); `LiveConversation.workspace` filled from `PlaceAgent.workspace`.
3. `WindowModel.homeScreen()` reads the listings, live rows, tickets, sessions and projects into
   `HomeInput`.

## Phase D — drawing (`WakilApp/Home.swift`) and checks

1. `Home` replaces `Landing`: one scroll for the page, no column caps; text wraps whole.
2. Card ⋯: Bring to Main…, Move a conversation here…, Archive (asks only with a conversation waiting,
   Rule 1); Earlier's Restore. Errors whole in `status` (Rule 8).
3. ⌘P workspace rows; composer picker over the home.
4. e2e checks under `e2e/checks/seeded/` and `agent/` (not run tonight); checks that read the old
   Landing's words move to the home's.

## Interaction Rules

| Rule | Control | How |
|---|---|---|
| 1 | Archive | Asks only when a conversation in it waits on the operator; Restore, Open, Move, pills never ask |
| 2 | — | No field is added but the picker, which commits on choice |
| 3 | New conversation here, ⌘N, Open | The composer is focused |
| 4 | — | Nothing new waits (worktrees are made at the first write, piece 1) |
| 5 | Archive, Restore, Bring to Main | Disabled while their dispatch is in flight |
| 6 | Pills, Archive, Restore, Start | The screen stays; only a card, a line, Open or a project's name moves it |
| 7 | Move a conversation here | Refused only by decision 6, naming it |
| 8 | Every card action | Refusal whole in the status line |
| 9 | The picker | Pre-set to the current place |
