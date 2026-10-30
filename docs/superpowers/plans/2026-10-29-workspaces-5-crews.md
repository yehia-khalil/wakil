# Workspaces 5 — crews and the hand-off: plan

**Spec:** `docs/superpowers/specs/2026-10-29-workspaces-design.md`, piece 5 (decisions 2, 9, 16, 17;
Decision 106). **Branch:** `yehia-khalil/workspaces-5-crews`, from piece 4's head fdb50a44 (on piece 1).
Pieces 2 (running) and 3 (home) are built beside it: nothing here reads them. Each task is
test-first: the failing test, then the code, then `make test` / `make app-test` green, then a commit
`workspaces: <what>`.

## Decisions this plan makes (recorded in the spec's amendment, piece 5)

- **A proposal belongs to the proposer's workspace** (piece 4's `MessageWorkspace` key: the
  workspace id, or `main/<org>/<project>/<env>`), and to one repo, named by Main's folder path or
  its folder name. A second proposal for the same repo in the same workspace **replaces** the first
  (Rule 7: a later value overrides). A dismissed one is refused for that repo in that workspace,
  naming decision 17.
- **Refused, whole:** an empty brief; one over 4,000 characters; no proposing conversation; a repo
  that is not one of the project's; the proposer's own repo (it holds its copy); a repo a live
  conversation of the same workspace already holds (it names it: message it instead); a dismissed one.
- **No confirmation anywhere.** Proposing changes only Wakil's own state (`.control`); Start and
  Dismiss are the operator's click (operator-only `.control`): neither destroys nor is *gate*
  (Rule 1). Start does not move the screen (Rule 6); its brief field is focused (Rule 3) and kept
  on blur (Rule 2).
- **Starting a teammate**: in the proposer's place, on its provider, in its workspace. A proposer
  in Main has no workspace yet: Start makes a **record-only** workspace (no copies; they come at the
  first write, from each repo's base — the umbrella's "Start on a ticket") and moves the proposer
  into it — it holds nothing in Main, so nothing is stranded (decision 6). A handed proposer's
  teammate is handed on the same ticket, **May push off** (fail closed; only the operator ticks it).
- **A crew up front**: the Hand to agent popover's **Agents: one / one per repo**, offered when the
  project has more than one repo. One by default (Rule 9). One per repo pre-ticks the subject's repo
  and every repo where the ticket has a branch or PR in flight. Start then starts one handed
  conversation per ticked repo, all in the ticket's workspace (found by its key in the project and
  environment, else a record-only one), each brief naming who holds what.
- **Who holds what** is plain text Wakil appends below the operator's words (Invariant 1): the
  agent's own repo, each teammate's title and repo, that they talk only through
  `conversation_message` (information only, within the wake budget), and to call
  `conversation_nothing_to_do` when its repo needs nothing.
- **Nothing to do**: `conversation_nothing_to_do {why?}`, agent-reachable `.control`, marks the
  caller's conversation; its state words read *"done · nothing to do in web"* (its repo, else its
  why) until the operator's next message; **Close** is the existing close.
- **Where it shows**: the proposer's thread (a row), a **Teammates** strip over the thread of the
  conversation on screen while its workspace has proposals (brief, **Start**, **Dismiss**), and
  `session_list` rows (`proposals`, `nothingToDo`) so piece 3's card can draw the violet line
  (`teammateProposalLine`). A proposal goes with its proposer when that conversation closes.

## Phase A — pure parts (`Workspace/Crews.swift`)

1. `TeammateProposal`, `TeammateProposals` (`propose`, `dismiss`, `take`, `pending(in:)`,
   `drop(from:)`), `checkTeammateProposal(...)` with each refusal's sentence.
2. `crewBriefLines(...)` (who holds what), `teammateProposalLine(_:)`, `nothingToDoWords(_:)`.
3. `crewRepoChoices(...)`: the repos the popover lists and pre-ticks.

## Phase B — the record

`WorkspaceRouter.crewWorkspace(for:ticket:)`: the conversation's workspace, else the ticket's (by
key, project, environment, unarchived), else a new record-only one; the conversation moved in.
`WorkspaceRouter.join(_:workspace:)` for a new conversation (holds nothing).

## Phase C — actions (`Workspace/CrewActions.swift`, through `CrewLookup`)

`conversation_propose_teammate` (agent), `conversation_teammate_start` and
`conversation_teammate_dismiss` (operator-only, in `operatorOnlyActions` and the pinned list),
`conversation_nothing_to_do` (agent). Tests: each refusal, classification.

## Phase D — the window (`App/WindowModel+Crews.swift`)

Proposals held per window; the thread rows; `startTeammate`; `startCrew`; nothing-to-do state on
`PlaceAgent`, `LiveConversation.nothingToDo`, `stateWords`, `session_list`'s `proposals`. Tests with
the scripted harness (`ConversationMessageTests`' wiring).

## Phase E — the popover and the strip (WakilApp)

`TicketHandOffState.agents` / `crewRepos`, `ticket_hand_off_brief {agents, repos}` (operator only),
`ticket_hand_off {agents, repos}` → `startCrew`. The popover's picker and repo toggles; the
Teammates strip. Identifiers for e2e.

## Phase F — cover and charter

e2e checks under `e2e/checks/agent/` and `seeded/` (written, not run), stub rules; architecture
lines (`wakilkit.md`, `flows.md`); the spec's piece 5 amendment.

## Phase G — finish (2026-10-30)

1. **Cancel for a one-per-repo start under way** (Rule 4). Test first: `ticket_hand_off_cancel` while
   the second member starts ends both members and the reply reads `cancelled`, the popover kept
   (`EditorTicketHandOffTests.cancelEndsAOnePerRepoStartAndStartsNoMore`); a member reserved after
   Cancel is refused (`aMemberAfterCancelIsNotAdmitted`); the window ends a member not admitted unsent
   and starts no more (`CrewWindowTests.aCrewMemberNotAdmittedNeverStartsAndStopsTheRest`). Then:
   the store keeps every conversation a start reserved; `startCrew(_:admit:)` asks before each
   member's first message; Cancel ends them all. **e2e: walk-only** — a start is a stub spawn of
   milliseconds, and the harness has no hold before a turn starts, so no press of Cancel can be
   made to land inside one.
2. **e2e for the popover's controls.** The Teammates strip's Start, Dismiss and brief were already
   pressed (`agent/workspaces-5-teammate*.jsonl`). The Hand to agent popover's piece 5 controls were
   not, and could not be: `ticket` was no registered surface, so the resolver dropped every
   `ticket.handoff.*`. Register it; draw **Agents** as two buttons (`ticket.handoff.agents:one` /
   `:perRepo` — a segmented Picker's segments carry no identifier); write
   `agent/ticket-workspaces-5-one-per-repo.jsonl`: one by default (Rule 9), one per repo and back,
   each repo toggled, the agent's `agents` refused, the toggles' frames at the narrow window, Start
   — two handed agents, the popover closed, the view kept (Rule 6).

## Phase H — on the restack (2026-10-30)

1. **The proposal on the home.** Test: `aProposalIsDrawnOnItsWorkspacesCardAndInMainForOneMadeThere`
   (`HomeScreenTests`), `theHomeDrawsAProposalMadeInMainInMainsBlock` (`CrewWindowTests`). Code:
   `HomeInput.proposals`, `HomeCard.proposals`, `HomeMain.proposals`, `HomeScreen.teammateOffers`; the
   home's `proposalLine` with a Start popover reusing `TeammateProposalRow` (focused, own identifiers).
   Checks: `agent/workspaces-5-home-teammate.jsonl`, `-dismiss.jsonl`.
2. **One per repo hides a root that is no git repository.** Test:
   `crewReposLeaveOutARootThatIsNotAGitRepository`. Code: `handOffCrewRepos(notRepositories:)`, fed by
   the git status's "not a git repository" roots. Check: `ticket-workspaces-5-one-per-repo.jsonl`.
3. **The popover's brief focused** (Rule 3), a beat after it appears. Check: the same, step 18.

## On the comp's home (2026-10-30, after piece 3's redesign)

- [x] A proposal is a NEEDS YOU why (*suggests a teammate*, amber, after comments and before done), Start
  (the brief in its popover) and Dismiss on the row; its card counts it in `● n`. In Main's block and an
  expanded card the line reads **Suggests a teammate** for `<repo>` — `<brief>`, whole. Tests:
  `HomeScreenTests.aProposalIsDrawnOnItsWorkspacesCardAndInMainForOneMadeThere`. Checks: the two
  `workspaces-5-home-teammate*` read the new words and the NEEDS YOU row.

## Item 8 — Hand to agent on a ticket a conversation carries (2026-10-30)

The operator's agreed behaviour and the build's calls: the spec's amendment of the same name.

- [x] **The record and status.** Go: `GitStatus.head` (the head's short SHA), `Workspace.BranchOff`.
  Tests: `TestStatusNamesTheHeadsShortCommit`, `TestWorkspacesRoundTrip`.
- [x] **Branch off, always.** `WorkspaceStore.markBranchOff/mustBranchOff/clearBranchOff`,
  `WorkspaceRouter.join(branchOff:)`, `branchOffMarked`, `WorkspaceLine.branchedOffAt/branchedOffNoCopy`.
  Tests (`WorkspaceRouterTests`): `aStartAnotherConversationBranchesOffAnIdleHoldersCopyAtItsLastCommit`,
  `aResumedStartAnotherConversationStillBranchesOff`,
  `aStartAnotherConversationWritingARepoTheWorkspaceHasNoCopyOfGetsAChildOfItsOwn`,
  `theBranchOffLineNamesTheCommitAndTheHoldersUncommittedChanges`.
- [x] **The popover's choices and the actions.** `TicketHandOffCarrier`, `handOffCarriers`,
  `handOffAnotherNumber`, `TicketHandOffState.offersSend/sendTarget/sendLabel/sendParams`,
  `ticket_hand_off_send`, `conversation_queued_cancel`, `sendTo` on `ticket_hand_off_brief`, Start
  another's `number`/`branchOffFrom`. Tests (`EditorTicketHandOffTests`): carriers, numbering, Send to
  offered and its ▾, one per repo offers Start alone, Send to sends and closes, queued, operator-only
  and a failure kept, Start another numbered past the carriers read at the press.
- [x] **The window.** `handOffCarriers()`, `sendToHandOff`, `unqueueTurn`, `deliverQueuedTurn` at the
  turn's end, `PlaceAgent.queuedTurns`, Start another's title and join. Tests
  (`HandOffSendToWindowTests`): the context lists carriers; idle sends off screen; working queues and
  delivers at the turn's end; Cancel takes it back; Start another is `#2`, in the carrier's workspace,
  holding no copy, marked.
- [x] **WakilApp.** `TicketHandOffPopover` (`ticket.handoff.send`, `.sendTo`, `.sendTo:<n>`,
  `.startAnother`), `QueuedTurnsStrip` (`window.queued`, `.text:<n>`, `.cancel:<n>`).
- [x] **Cover.** `agent/ticket-workspaces-8-send-to.jsonl` (new; the stub holds the first agent's turn),
  `agent/ticket-workspaces-5-one-per-repo.jsonl` (extended); `uncoverable.tsv` for the two actions'
  parity and the strip's container and text. Not run here: the coordinator runs them.

