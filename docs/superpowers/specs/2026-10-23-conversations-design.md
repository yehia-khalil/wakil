# Conversations in a place: start a new one, keep the others running, switch between them

**Date:** 2026-10-23
**Status:** spec awaiting the operator's review; builder-checked twice 2026-10-23. Every decision beyond the operator's three is the
designer's call, listed under *Calls made for the operator*.
**Sub-phase:** folds the north-star rows **New conversation** and **Track** into one (after 2e-iv,
main 1fb2b49). Answers the Track agenda (`parked.md` #78–#86) on the record.

---

## Problem

A place (organization, project, environment) holds one conversation (Decision 41). Once work
begins there, the Landing never comes back: nothing clears `sessionStarted` in-window
(`WindowModel.swift` ~7986, "Owed: … A `session_new` action is that return path"), so starting
fresh means quitting, and quitting stops every agent. The operator works with several agents at
once, often on the same project: one running a long job while another answers a question. Today
that needs a second place or a second app.

## Decided by the operator (2026-10-23)

1. **New conversation** returns the place to its Landing.
2. **If the agent is active, it keeps running in the background**; nothing is ended to start
   something new.
3. **Make it dynamic**: several conversations live at once, in the same place or different
   places, and the operator switches to any of them and continues it. *"this allows a real flow
   of how i work and others using agents do. having multiple sessions running and switching and
   continueing each of them."*

## What the operator gets

1. **⌘N / File ▸ New Conversation / ⌘K "New conversation"** puts the conversation on screen into the
   background, untouched, and shows the place's Landing. The next turn, pane or Continue there
   begins a new conversation. Nothing is asked: nothing is lost (Rule 1).
2. **Every live conversation not on screen is a chip**, top right, as other places' agents are
   today: violet while it works, amber while it waits for the operator, green when it finished
   unseen, red when it failed. A chip now names its conversation as well as its place:
   `api · staging — fix the flaky login test`. An idle, seen conversation shows no chip, as today,
   but stays listed (item 3).
3. **The Landing gains a Running column** before Continue: every live conversation in this place,
   newest activity first, with its state. A click switches to it. Continue keeps listing ended
   sessions, as today.
4. **⌘P lists live conversations first** under "Running", across all places; picking one switches
   to it (no fork, no cost). Ended ones follow, as today, and resume as a fork (2b-v).
5. **Switching to a live conversation brings back exactly what was left**: its thread, its canvas
   and panes (live, not reloaded; a terminal's shell kept running), its composer draft. A turn
   still running carries on; its thread streams in.
6. **Close Conversation, ⌘⇧W / ⌘K "Close conversation"**, ends the conversation on screen: its agent
   stops, its panes close as on quit, and it moves to Continue. If its turn is running or it has a
   write waiting, one question first: "Close this conversation? The agent is still working; what
   it is doing now stops." **Close it** / **Keep it** (Rule 1: this destroys work in flight).
   After it, the place shows its next live conversation, or its Landing if none.
7. **Quit** stops every conversation, as today; each is in its place's Continue.

## Calls made for the operator

1. **A conversation is the unit, not the place.** `WindowModel.agents` goes from one `PlaceAgent`
   per place to a list of conversations per place, each with its own harness, socket, thread,
   composer draft (text only; dictation stops on a switch) and canvas. A place has at most one
   conversation *on screen*, or none: a place with none on screen draws its Landing, whatever runs
   in the background. A conversation's identity is the id Wakil already mints before the first
   session (`PlaceAgent.assignedSessionId`), reused, not a new id: the socket path, `DispatchCaller`,
   `shownSockets` (rekeyed by it) and `session_switch` all carry that one id. Its lineage root keeps
   naming it on disk once it has one.
2. **Pinning moves from place to conversation.** Each agent's calls arrive on its own socket, so they
   resolve to its conversation and its place, whatever is on screen (Decision 41's pin, one level
   down). Dispatch callers, the event pump and chip flags are keyed by conversation where they are
   keyed by place today. **`ConfirmationBroker` is rekeyed by conversation**, so two agents in one
   place each park their own proposal and neither gets `.busy` because of the other; the
   operator's own gated actions keep a place-level slot. Each proposal shows on its own
   conversation's chip or Running row; the plane shows the on-screen conversation's.
2a. **The place-level actions act on a conversation.** `session_resume`, `session_set_provider`
   (`setProvider`) and `resume(in:)` act on the caller's conversation for an agent and on the
   on-screen one for the operator. `session_list` takes an optional place filter.
2b. **A canvas before a turn.** A conversation with no lineage root yet has an in-memory canvas scope
   keyed by its conversation id (`LayoutScope` with that id where the root goes), so two un-turned
   conversations in one place never share a scope, and a terminal opened before any turn keeps its
   shell when its conversation goes to the background. A new conversation's canvas starts from the
   project seed on disk, as at launch (copied, so the conversation it came from keeps its own).
   At its first lineage root the scope is re-filed under the root (the existing adoption path).
3. **Switching never forks.** A live conversation is the same running session, brought on screen;
   no new session id, no fresh `claude` process (Track #80). Only an ended one (after quit or
   Close) resumes as a fork, as today.
4. **An in-flight turn is never touched by switching** (Track #85): it finishes in the background;
   a proposal it raises waits on its chip (amber) and in Running.
5. **The agent doesn't know about the others** (Track #82). Each is pinned to its place and sees
   only its own thread. Two agents in one place can both write there; each write passes the write
   gate on its own, as two terminals do today. The journal already records which agent (session)
   caused each entry; the label gains the conversation title.
6. **A conversation's title** is its first message to the agent, cut to 48 characters (middle kept
   whole words); before any message, "New conversation". This also gives ⌘P and Continue
   something better than a UUID (parked #145, partly). Renaming a conversation is not in scope.
7. **Nothing new on disk** (Track #84). A live conversation's canvas is filed under its lineage root
   once it has one, as today (`LayoutScope` already carries it); before that it lives in memory and
   the project seed rule (`LayoutPersistence`) is unchanged. Lineage stays in `sessions.json`.
   The set of live conversations is not persisted: quit ends them all (item 7), as today.
8. **No cap.** Each live conversation is one `claude` process; the operator closes what they don't
   need. The chip row scrolls rather than wrapping past the window (issue #44's edge,
   design-language §14).
9. **Actions.** `session_new` and `session_close`, `.control`, **operator-only** (added to
   `operatorOnlyActions` with their own denial sentences: an agent must not end or push aside the
   operator's conversation), and `session_switch {conversation}`, `.control`, operator-only too.
   Each is pinned to the place (and conversation) it is dispatched in, through a broker drained by
   a pump, as `session_resume` is. `session_list` gains the live conversations with their state
   and title, so an agent and the e2e harness can read them.
10. **New Conversation on a Landing** does nothing visible and is disabled in the menu; its ⌘K
    command is hidden there.
11. **Focus.** After New Conversation the Landing's composer is focused; after a switch, the
    focus the conversation had when it was left (Rule 3, Rule 6).
12. **Production stays red.** A chip or Running row for a production environment keeps its red
    segment (Invariant 8).

## What it does not do

- No second window; no side-by-side conversations on one screen.
- No naming or renaming a conversation; no delete from Continue.
- No limit or queue on concurrent agents; no cost meter.
- No agent-to-agent messages; no agent tool to start or switch conversations.
- No change to the write gate, resume-as-fork, or what Continue lists.

## Errors and edges

- A conversation's harness dies while off screen: its chip goes red ("— failed"); switching to it
  shows the failure whole (Rule 8), and the composer starts a resume of it.
- Close on a conversation whose turn ends while the question is open: **Close it** still closes,
  with no second question. Two Closes on one conversation: the second is ignored (Rule 5).
- Renaming or removing a project or environment: Invariant 5 stands unchanged. It is refused while
  any of the place's conversations has an agent running, as today, with the same sentence; idle
  live conversations are carried by a rename (`carryAgents`) and closed by a removal.
- Org switch: conversations in other orgs keep running and keep their chips (Decision 41 stands).

## Testing

- **WakilKit:** conversations per place: New conversation backgrounds an idle and a busy one (the
  busy one's turn completes and its chip goes green); switching back returns the same session id,
  thread, canvas and draft; an agent's call from a background conversation resolves to its own
  place and conversation; a proposal from a background conversation waits on its chip and is
  approved there; Close asks only with work in flight; operator-only denials for all three
  actions; a fresh conversation's first turn mints a new session id and lineage root; quit stops
  all.
- **e2e (seeded, e2e agent stub):** a turn → ⌘N → Landing shows the first conversation under
  Running; a second turn → ⌘P lists both under Running; switch → the first thread is back; the
  chip of a working background conversation is drawn and clicks through; Close with an idle agent
  asks nothing and the conversation appears in Continue. Parity: ⌘K click vs dispatch for each of
  the three actions.
- **Runbook** `docs/wakil/phase-conversations-acceptance.md`: two real agents in one place, one on a
  long task; switch between them mid-turn; approve a write from the background one's chip; quit and
  Continue each.

## Charter changes

- **Decision 41 amended** (operator, 2026-10-23): a place holds any number of live conversations,
  one on screen; pinning is per conversation. The "one agent per place" headline and "a finished
  agent's session stays alive until quit or a new conversation" are replaced.
- North-star phase map: **New conversation** and **Track** become one row, *Conversations*.
- `parked.md` Track agenda: each item points to the call here that answers it (#78/#79 → calls 1–2,
  #80 → 3, #82 → 5, #83 → items 2–4, #84 → 7, #85 → 4, #86 → the phase-map row).
- `WindowModel.swift` "Owed" comment on `sessionStarted` replaced by a pointer to `session_new`.
- PRODUCT.md: a line on conversations and the Running column.

## Build order (for the plan)

Three stacked plans, each green on its own:
1. **Rekey by conversation, no visible change.** `agents`, `ConfirmationBroker`, `DispatchCaller`,
   sockets, the event pump, chips and the pre-turn canvas scope keyed by conversation; one
   conversation per place; every existing test unchanged and green.
2. **Background and switch.** `session_new`, `session_switch`, the Landing's Running column, ⌘P
   Running, chip titles, per-conversation drafts, ⌘N.
3. **Close and the record.** `session_close` and its question, the rename/remove behaviour,
   Decision 41 and the charter, e2e checks and the runbook.
