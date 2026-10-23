# New conversation: `session_new`

**Date:** 2026-10-23
**Status:** spec awaiting the operator's review; builder-checked 2026-10-23 (calls 9–14 came from it). The operator skipped the design questions, so
every decision below is the designer's call, listed under *Calls made for the operator*.
**Sub-phase:** the **New conversation** row of the north-star phase map (after 2e-iv, main
1fb2b49). **Track** depends on it.

---

## Problem

Once work begins in a place (a turn, a pane opened, a resume), the place's `PlaceAgent` sets
`sessionStarted` and the Landing never comes back: nothing clears it in-window
(`WindowModel.swift` ~7986, "Owed: … A `session_new` action is that return path"). The only way
to start fresh in a place is to quit Wakil. Decision 41 already names the end this needs: "A
finished agent's session stays alive until quit **or a new conversation in that place**."

## What the operator gets

1. **File ▸ New Conversation, ⌘N**, and a ⌘K command **New conversation**. Both act on the place on
   screen and only appear enabled once that place has a conversation (`sessionStarted`).
2. The place goes back to its **Landing**: Continue lists the conversation just ended at the top (once it has taken a turn; call 11),
   Open lists what it always lists. The composer stays where it is, with any draft still in it.
3. The next thing the operator does there (a turn, a pane, a Continue) begins as it does after a
   launch: a fresh session id, its own lineage root, the canvas from the project's seed.
4. The conversation that ended is not lost: its transcript stays in the provider's store, its
   panes stay filed under its lineage root, and **Continue** or ⌘P resumes it as a fork with its
   panes back, as 2b-v does today.
5. Other places are untouched: their agents keep running and their chips stay as they are.

## Calls made for the operator

1. **One action, `session_new`, `.control`, operator-only.** Registered in `StandardActions` beside
   `session_set_provider` (the operator-only precedent), added to `operatorOnlyActions` (`PermissionPrompt.swift`) and given its own
   denial sentence. An agent ending its own conversation would pull the floor from under the
   operator (the Decision 30 reasoning for Settings). Params: none; it acts on the place it is
   dispatched in (pinned like `session_resume`'s `ResumeRequest.place`), never "the screen" read
   later.
2. **Nothing to end: refused.** A place with no conversation refuses with "there is no conversation
   in this place to end" (the UI controls are disabled there, so only a dispatch meets this).
3. **Ending is not destroying, so it asks nothing (Rule 1)** — when the agent is idle. The
   conversation is resumable, the panes are filed, nothing is lost.
4. **A turn in flight or a proposal waiting: ask, don't refuse (Rules 1 and 7).** Stopping a running
   turn or dropping a waiting write destroys work in flight, so the operator sees one question:
   "End this conversation? The agent is still working; what it is doing now stops." (or "… a
   write it proposed is waiting; it will be dropped."). **End it** / **Keep it**. This differs from
   `setProvider`, which refuses; `setProvider` is a swap the operator can retry, `session_new` is
   the operator saying stop.
5. **What ending does** (in `WindowModel`, one method beside `resume` and `setProvider`, taking a
   place): bump `eventPumpGeneration`, `stopSession(of:)` (stops the harness, the socket, cancels
   the place's proposal), then clear `sessionId`, `assignedSessionId`, `lineageRoot`, `thoughts`,
   `turnInFlight`, and set `sessionStarted = false`. The canvas scope falls back to the project
   seed through the existing `activateLayout`. The old conversation's layout file is left on disk.
6. **The provider stays.** The new conversation uses the place's current provider; switching
   provider is its own action.
7. **⌘N.** The File menu's `.newItem` group is empty today (`AppScene.swift` replaces it with
   nothing), so New Conversation goes there with ⌘N. No other control is added to the canvas or
   the context line.
8. **Focus after.** The Landing's composer is focused (Rule 3); the operator lands where a launch
   leaves them, which is where they asked to go (Rule 6 does not apply: the old surface is gone by
   request).
9. **The place ends in exactly the state a launch leaves it in**, and the builder matches the launch
   path rather than inventing one: the old arrangement is persisted under the old lineage root
   *first*, then the canvas is emptied and its scope set to the project seed, then
   `sessionStarted = false`. The seed is not loaded until the next conversation begins, as at
   launch. The #264 hook (~WindowModel 1205, "a non-empty canvas sets `sessionStarted`") must not
   undo the reset: the reset's own dispatch finds an empty canvas. A test pins both orders (seed
   with panes, seed empty).
10. **Live panes close as on quit.** Terminals' shells end, API and database panes drop their
    in-memory state; nothing beyond what quit already asks is asked. Continue restores them from the
    file, as after a relaunch.
11. **A conversation with no turn is not listed.** Continue lists only sessions with a transcript
    (`session_list`), so a pane-only conversation is not listed after it ends. Its panes are not
    lost: the project seed is rewritten from the latest non-empty arrangement (existing
    `LayoutPersistence` behaviour), so the next conversation opens on them. No listing change.
12. **A fresh id really is fresh.** The place's shown socket (`shownSockets[place]`) is stopped and
    cleared with the rest, so `markSessionStarted` cannot reuse the ended conversation's id. The
    place's chip flags (`unseenResult`, `unseenFailure`) are cleared too.
13. **Dispatch path.** A third broker beside `ResumeBroker` and `ProviderSwitchBroker`, drained by a
    pump in `WindowModel.init`; the dispatch returns as `session_resume` does. Every check reads the
    *pinned* place's agent (`turnInFlight`, `confirmations.current(for:)`), never the screen's.
    The question uses the window's existing confirmation look but is not a `.mutate` proposal
    (`ConfirmationBroker` is not used). If the turn ends while the question is open, **End it**
    still ends the (now idle) conversation, with no second question. A second `session_new` for a
    place whose question is open is ignored (Rule 5). Without a window (`--dispatch` alone) it is
    refused as other window actions are.
14. **Disabled vs hidden.** The menu item greys out on a Landing; the ⌘K command is hidden there
    (its `available:` guard), as other place-dependent commands are.

## What it does not do

- No Track (two sessions in one place); that is its own row and revisits Decision 41.
- No delete or archive of a conversation; Continue still lists it.
- No stop-turn control on its own (`AgentHarness.interrupt()` stays unused).
- No auto-resume (Decision 12 / q5 stand).

## Errors and edges

- The harness fails to stop: the place still resets; the stop error goes to status whole (Rule 8).
- The operator switches place while the question is open: the question belongs to the place it was
  asked in and ends that one, not the place now on screen.
- A Continue resume right after: the ended session resumes as a fork with its lineage root, so its
  panes come back (existing 2b-v path).
- Relaunch after a `session_new`: the place opens on its Landing, as every launch does.

## Testing

- **WakilKit:** `session_new` operator-only (an agent dispatch is denied with its sentence);
  refused with no conversation; idle place resets (`sessionStarted` false, ids and lineage nil,
  harness stopped) and asks nothing; turn in flight → question, **Keep it** changes nothing, **End
  it** resets; another place's agent untouched; ended place's next turn mints a fresh id and root.
- **e2e (seeded):** a turn through the e2e agent stub (so a transcript exists), ⌘K **New
  conversation** → the Landing shows and Continue lists the ended conversation; open a pane only,
  New conversation → the Landing shows; the ⌘K command is absent on a Landing; parity: the ⌘K click
  and a `session_new` dispatch leave the same Landing.
- **Runbook** `docs/wakil/phase-new-conversation-acceptance.md`: a real turn, ⌘N, Landing; Continue
  brings the conversation and its panes back; ⌘N during a long turn asks, Keep it keeps it running.

## Charter changes

- North-star phase map: the New conversation row gets its date when walked.
- `WindowModel.swift` "Owed" comment on `sessionStarted` replaced by a pointer to `session_new`.
- Decision 41: a one-line note that `session_new` is how a place's conversation ends before quit.
- `open-questions.md` q5: the "owed `session_new`" line points here.
