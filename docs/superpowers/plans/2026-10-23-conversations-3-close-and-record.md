# Conversations 3 of 3: close, and the record — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘⇧W / ⌘K "Close conversation" ends the conversation on screen (asking first only when work
is in flight), renaming and removing a place treat its live conversations as the spec says, quit
stops them all, and the charter, e2e checks and runbook record the phase.

**Architecture:** `session_close` parks on plan 2's `ConversationBroker` as `.close`; the window's
`closeConversation` either closes at once or raises a `CloseConversationQuestion` the plane-style
view answers. Closing stops the harness and socket (`stopSession`), persists and shuts its canvas's
shells, drops the entry and shows the place's next live conversation or its Landing. The record is
docs and e2e files.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing; Go (the e2e stub); Markdown.

**Spec:** `docs/superpowers/specs/2026-10-23-conversations-design.md` (Build order, step 3). **Starts
from the head of plan 2's branch** (`2026-10-23-conversations-2-background-and-switch.md`).

## Rulings the planner made

1. **The turn-driven checks go in `e2e/checks/agent/`, not `seeded/`.** The spec says "seeded, e2e
   agent stub"; the directory picks the launch (`docs/agents/e2e.md` step 3), and only `agent/` is
   seeded *and* carries the stub. *Cost if wrong:* none — `seeded/` cannot run a turn.
2. **The stub writes a one-record transcript per session**, so a closed conversation can appear in
   Continue: `e2e/stub` writes `<CLAUDE_CONFIG_DIR>/projects/<wakilcore.EncodeRootPath(cwd)>/<--session-id>.jsonl`
   holding the first prompt as a `user` record, which `wakilcore.ListSessions` reads (`firstCwd`,
   `firstPrompt`). Today it writes none, so "Close … appears in Continue" is unreachable. *Cost if
   wrong:* that assertion moves to the runbook and the stub stays as it is.
3. **One question for both cases.** The spec gives one sentence for "its turn is running or it has a
   write waiting"; it is used for both. A waiting write is cancelled by **Close it**, as the session's
   other proposals are (`stopSession`). *Cost if wrong:* a second sentence in `CloseConversationQuestion`.
4. **"Its panes close as on quit"** is read as: its arrangement is written to its file, its shells are
   killed (`TerminalStore.close(scope:)`), and its scope is dropped from memory; nothing is deleted on
   disk. *Cost if wrong:* if the operator expected the canvas kept in memory for a resume, drop the
   memory release; the resume reads the file anyway.
5. **Removal closes idle live conversations without asking**; a running one already refuses the
   removal (Invariant 5). Rename now carries **every** idle conversation of the place (plan 1 kept
   today's "one whose new place already has an agent stays where it is", which no longer applies).
6. **Close Conversation lives in the File menu** (`CommandGroup(replacing: .saveItem)`, which plan 2
   emptied to keep SwiftUI's Close / Close All out), ⌘⇧W. Nothing in the app binds ⌘⇧W today (checked:
   no `keyboardShortcut("w", modifiers: [.command, .shift])`, no `cmd+shift+w` in `e2e/checks`); the
   hand check confirms SwiftUI adds no ⌘⇧W item of its own. Like ⌘N (plan 2 ruling 5) it cannot be
   disabled in the menu and does nothing on a Landing; its ⌘K row is hidden there.
7. **Parity for hotkey-only paths.** A `parity` step needs a click. Each of the three actions gets
   its parity through a clickable control: `session_switch` through the Landing's Running row,
   `session_new` and `session_close` through their ⌘K rows (`palette.row.global.newConversation`,
   `palette.row.global.closeConversation`) if the runner holds the palette open for the click half;
   otherwise those two get an `uncoverable.tsv` line ("a hotkey or palette row reached only after a
   `do` step; parity's UI half is one click") and a dispatch check each.
8. **Close copy** (the spec fixes the question and buttons, not the denial): see Global Constraints.

## Global Constraints

- **Close Conversation, ⌘⇧W / ⌘K "Close conversation"**, ends the conversation on screen: its agent
  stops, its panes close as on quit, and it moves to Continue.
- If its turn is running or it has a write waiting, one question first, verbatim:
  `Close this conversation? The agent is still working; what it is doing now stops.` Buttons
  **Close it** / **Keep it** (Rule 1: this destroys work in flight). Otherwise nothing is asked.
- After it, the place shows its next live conversation, or its Landing if none.
- A turn that ends while the question is open: **Close it** still closes, with no second question. Two
  Closes on one conversation: the second is ignored (Rule 5).
- A conversation whose harness died off screen: chip red ("— failed"); switching shows the failure
  whole (Rule 8); the composer starts a resume of it.
- Renaming or removing a project or environment: Invariant 5 unchanged — refused while any of the
  place's conversations has an agent running, with today's sentence; idle live conversations are
  carried by a rename (`carryAgents`) and closed by a removal.
- **Quit** stops every conversation, as today; each is in its place's Continue.
- `session_close`: `.control`, operator-only, pinned to the conversation it is dispatched in. Denial,
  verbatim: `"<tool>: only the operator closes a conversation — an agent must not end the operator's conversation. Ask the operator to close it in the Wakil window (⌘⇧W)."`
- Charter: Decision 41 amended (operator, 2026-10-23): a place holds any number of live
  conversations, one on screen; pinning is per conversation. The "one agent per place" headline and
  "a finished agent's session stays alive until quit or a new conversation" are replaced. North-star:
  **New conversation** and **Track** become one row, *Conversations*. `parked.md` Track agenda:
  #78/#79 → calls 1–2, #80 → 3, #82 → 5, #83 → items 2–4, #84 → 7, #85 → 4, #86 → the phase-map row.
- On-screen e2e runs (`make e2e-new`, `make e2e`, `make e2e-full`) wait for the operator's go.
- No commit carries `Co-Authored-By` or a "Generated with" line.

## Review Focus

1. **⌘⇧W pressed twice fast with a turn running** — one question, not two; the second press does
   nothing. Pinned in Task 1.
2. **The turn ends while the question is up** — **Close it** closes without asking again; **Keep it**
   leaves a now-idle conversation on screen. Pinned in Task 1.
3. **Close the on-screen conversation while another in the place is working** — the place shows that
   one (newest activity), its chip goes, nothing is forked. Pinned in Task 1.
4. **Removing an environment that holds an idle background conversation with a terminal pane** — the
   conversation is gone from chips and Running, its shell is dead, no orphan socket. Pinned in Task 2.
5. **Quit with one conversation holding a waiting write** — the proposal is cancelled, the agent's
   call returns, and every `claude` child stops. Pinned in Task 2.

---

### Task 1: `session_close` and its question

**Files:**
- Modify: `app/Sources/WakilKit/Harness/ConversationBroker.swift` (`.close`)
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (beside `session_new`), `app/Sources/WakilKit/MCP/PermissionPrompt.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`closeConversation`, `closeQuestion`, `answerCloseQuestion`, the pump's `.close` arm)
- Modify: `app/Tests/WakilKitTests/ActionClassificationTests.swift`, `AppWiringTests.swift:236`, `InvalidationContractTests.swift` (`closeQuestion`, `closing`)
- Test: Create `app/Tests/WakilKitTests/ConversationCloseTests.swift`; extend `PermissionPromptTests.swift`

**Interfaces:**
- Consumes: plan 2's `ConversationBroker`, `ConversationRequest`, `liveConversationRows(in:)`, `switchToConversation`; plan 1's `stopSession(of:)`, `parkedSlots`.
- Produces:
  - `ConversationRequest.close(conversation: String?)` (`nil` = the screen's).
  - `session_close {}` → `{"closing": <id or null>}`.
  - `public struct CloseConversationQuestion: Sendable, Equatable { public let conversation: String; public static let text = "Close this conversation? The agent is still working; what it is doing now stops."; public static let closeLabel = "Close it"; public static let keepLabel = "Keep it" }`.
  - `public private(set) var closeQuestion: CloseConversationQuestion?`.
  - `public func closeConversation(_ conversation: String? = nil) async` — asks only when the target's `turnInFlight` or `parkedSlots` holds an `.agent` proposal for its id; ignored while that conversation is already asked about or closing.
  - `public func answerCloseQuestion(close: Bool) async` — `close: true` closes whatever the turn did since.
  - `PlaceAgent.sessionEnded: Bool` — set where the event pump sees its stream end unreplaced; `send` on such a
    conversation first calls `resume(sessionId: agent.sessionId!, conversation: agent.id)`, then sends (spec, Errors and edges).
  - `private func endConversation(_ agent: PlaceAgent) async` — `stopSession`, persist its canvas, `terminals.close(scope:)`, drop its scope from memory and `loadedLayoutScopes`, remove from `conversations` / `screenConversations`; then the place shows `liveConversationRows(in: place).first` or its Landing (plan 2's Landing path).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func closingAnIdleConversationAsksNothingAndShowsTheLanding() async throws {
    // send, wait for .result
    await model.closeConversation()
    #expect(model.closeQuestion == nil && model.currentAgent == nil && !model.sessionStarted)
    #expect(sessions.harnesses.in(placeA)[0].stopped && sessions.issuedSockets[0].stopped)
}

@Test func closingWithATurnRunningAsksOnceAndIgnoresASecondClose() async throws {
    // send, turn in flight
    await model.closeConversation(); await model.closeConversation()
    #expect(model.closeQuestion?.conversation == id)
    #expect(CloseConversationQuestion.text == "Close this conversation? The agent is still working; what it is doing now stops.")
    await model.answerCloseQuestion(close: false)
    #expect(model.currentAgent?.id == id && !sessions.harnesses.in(placeA)[0].stopped)
}

@Test func aTurnThatEndsWhileAskedStillClosesWithoutASecondQuestion() async throws {
    // closeConversation() with a turn running; emit .result; answerCloseQuestion(close: true)
    #expect(model.conversation(id: id) == nil && model.closeQuestion == nil)
}

@Test func aWaitingWriteAsksAndCloseItCancelsIt() async throws {
    // park an .agent PendingMutation(place: placeA, conversation: id); closeConversation(); answer close
    #expect(await parked.value == .cancelled)
}

@Test func closingShowsThePlacesNextLiveConversation() async throws {
    // two conversations in placeA (plan 2 newConversation), second on screen
    await model.closeConversation()
    #expect(model.currentAgent?.id == firstId && sessions.harnesses.in(placeA).count == 2, "no fork")
}

@Test func aClosedConversationIsInContinueAndNotInRunning() async throws {
    // sessionRows fixture lists the closed session's id
    #expect(model.liveConversationRows(in: placeA).isEmpty)
    #expect(await model.landingSessions().map(\.payload).contains(sessionId))
}

@Test func aConversationWhoseProcessDiedOffScreenShowsItAndItsNextTurnResumesIt() async throws {
    // two conversations; the background one's harness stream finishes (process gone)
    #expect(await waitUntil { model.chips.first?.state == .failed })
    await model.switchToConversation(deadId)
    #expect(model.thoughts.last?.isError == true, "the failure is shown whole (Rule 8)")
    #expect(await model.send("carry on"))
    #expect(sessions.harnesses.in(placeA).last?.log.first == "start:\(model.sessionId!):\(deadSession)", "a resume of it, forked")
}
```

  `PermissionPromptTests.sessionCloseIsDeniedToTheAgentWithItsOwnSentence`.

- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'ConversationCloseTests|PermissionPromptTests|ActionClassificationTests|AppWiringTests'` — FAIL.
- [ ] **Step 3: Implement** per Interfaces; `closing: Set<String>` guards Rule 5.
- [ ] **Step 4: Run** the filter, then `make app-test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "Conversations 3: session_close ends the conversation on screen, asking only with work in flight"`

### Task 2: ⌘⇧W, ⌘K, the question's view; rename, remove and quit

**Files:**
- Create: `app/Sources/WakilApp/CloseConversationPrompt.swift` (drawn where `ConfirmationPlane`/the unsaved prompt are, `Canvas.swift`)
- Modify: `app/Sources/WakilApp/AppScene.swift` (`CommandGroup(replacing: .saveItem)`), `app/Sources/WakilKit/Command/CommandCatalog.swift` (`global.closeConversation`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:3522-3532` (`carryAgents` carries every idle conversation), `:3615-3700` (`removeProject`, `removeEnvironment` close idle conversations), `shutdown`
- Test: `ConversationCloseTests.swift`, `CommandCatalogTests.swift`, `WindowModelProjectLifecycleTests.swift`

**Interfaces:**
- Consumes: Task 1's `closeQuestion`, `answerCloseQuestion`, `endConversation`.
- Produces:
  - `CatalogCommand` `global.closeConversation`: label `"Close conversation"`, `action "session_close"`, `available: { $0.conversationOnScreen }`.
  - File menu: `Button("Close Conversation")` ⌘⇧W → `dispatchSessionClose()` (registry, origin `.ui`), beside plan 2's New Conversation.
  - Prompt view: the question text whole (Rule 8), **Close it** (`window.closeConversation.close`) and **Keep it** (`window.closeConversation.keep`, the default and Esc — Rule 4), focus on **Keep it** when it appears (Rule 3).
  - `private func closeConversations(project: String, environment: String?) async` — every idle conversation of the removed place through `endConversation`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func renameCarriesEveryIdleConversationOfThePlace() async throws {
    #expect(model.liveConversationRows(in: renamedA).map(\.id).sorted() == [a, b].sorted())
}

@Test func removingAnEnvironmentClosesItsIdleConversationsAndTheirShells() async throws {
    // idle background conversation in staging with a terminal pane; remove staging
    #expect(model.liveConversationRows(in: staging).isEmpty && model.chips.isEmpty)
    #expect(await terminals.isRunning(paneId: "terminal-1") == false)
}

@Test func removalIsStillRefusedWhileAnyConversationThereRuns() async throws {
    // one idle + one running in the place: today's Invariant 5 sentence, whole
    #expect(refusal == expectedTodaysSentence)
}

@Test func quitStopsEveryConversationAndCancelsTheirWrites() async throws {
    await model.shutdown()
    #expect(sessions.harnesses.issued.allSatisfy(\.stopped) && (await parked.value) == .cancelled)
}

@Test func closeConversationIsOfferedOnlyWithAConversationOnScreen() { /* as plan 2's newConversation catalog test */ }
```

- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'ConversationCloseTests|CommandCatalogTests|WindowModelProjectLifecycleTests'` — FAIL.
- [ ] **Step 3: Implement**; `make app-build`; `make controls` reports the two new buttons named.
- [ ] **Step 4: Run** `make app-test` — PASS.
- [ ] **Step 5: Hand check (operator's go):** the File menu holds **New Conversation ⌘N** and **Close Conversation ⇧⌘W** and nothing else; no second ⇧⌘W item anywhere in the menu bar.
- [ ] **Step 6: Commit** `git commit -m "Conversations 3: ⌘⇧W and ⌘K close; removal closes idle conversations; rename carries them all"`

### Task 3: e2e checks and parity

**Files:**
- Modify: `e2e/stub/main.go` (ruling 2), `e2e/stub/script.json` (no new rule needed: `thread turn one/two` answer, `hold a turn open here` holds until `~/wakil-e2e-release-held`)
- Create: `e2e/checks/agent/conversations-new-shows-running.jsonl`, `conversations-palette-switch.jsonl`,
  `conversations-background-chip.jsonl`, `conversations-close-idle.jsonl`, `conversations-close-asks.jsonl`,
  `conversations-parity.jsonl`; their proofs under `e2e/checks/proofs/`
- Modify: `e2e/checks/uncoverable.tsv` only per ruling 7, each line with its reason
- Test: `go test ./e2e/...` (the stub's transcript writer: `TestTheStubWritesATranscriptListSessionsReads` in `e2e/stub/main_test.go`)

**Interfaces:**
- Consumes: identifiers `landing.row.running:<i>`, `window.agentChip.e2e-fixture/e2e-project/staging[#n]`,
  `window.closeConversation.close|keep`, `palette.row.global.newConversation|closeConversation`, `window.composer`; plan 2's socket choice by conversation.

- [ ] **Step 1: Write the checks.** One launch per file; names that are not prefixes of each other; a
  positive read after every click; focus with `expect.focus`, layout with `expect.frame` at
  `{"do":{"resize":{"width":1000,"height":888}}}`.
  - `conversations-new-shows-running`: type `thread turn one`, Return, expect `first reply in the thread`;
    `cmd+n`; expect tree contains `RUNNING` and `thread turn one`, absent `first reply in the thread`;
    `expect.focus window.composer` (call 11); resize to 1000×888 and `expect.frame landing.row.running:0 inside window`.
  - `conversations-palette-switch`: turn one, `cmd+n`, `thread turn two`, expect `second reply in the thread`;
    `cmd+p`, type `thread turn one`, Return; expect `first reply in the thread`, absent `second reply in the thread`;
    `cmd+p` again, expect both titles listed (both live).
  - `conversations-background-chip`: `hold a turn open here`; `cmd+n`; expect frame
    `window.agentChip.e2e-fixture/e2e-project/staging` inside window and `Value: working`; click
    `landing.row.open:terminal` (a second conversation begins); `touch ~/wakil-e2e-release-held`, Return;
    expect `Value: done`; click the chip; expect `a held turn was released`.
  - `conversations-close-idle`: turn one; `cmd+shift+w`; expect absent `Close this conversation?`;
    expect `Nothing to continue` absent and `thread turn one` present (Continue, ruling 2), `RUNNING` absent.
  - `conversations-close-asks`: hold a turn; `cmd+shift+w`; expect the question sentence whole and
    `expect.focus window.closeConversation.keep`; click keep; expect `hold a turn open here` still on screen;
    `cmd+shift+w`; click `window.closeConversation.close`; expect the Landing (`Open` column row
    `landing.row.open:terminal` present).
  - `conversations-parity`: a turn, `cmd+n`, a second turn, `cmd+n`; then
    `{"parity":{"action":"session_switch","params":{"conversation":"thread turn one"},"click":"landing.row.running:1","assert":"tree"}}`;
    the two ⌘K parities or their uncoverable lines (ruling 7).
- [ ] **Step 2: Stub transcript** test red then green: `go test ./e2e/stub/`.
- [ ] **Step 3: Wait for the operator's go**, then `make e2e-new` (each new check red against the merge-base, for the branch's reason — read `acts.txt`), commit the proofs; then `make e2e`; read its UNMAPPED list.
- [ ] **Step 4: Commit** `git commit -m "Conversations 3: e2e checks for new, switch, background chips and close"`

### Task 4: The runbook and the charter

**Files:**
- Create: `docs/wakil/phase-conversations-acceptance.md` (human section by hand, machine section rendered)
- Modify: `docs/wakil/decisions.md:1379-…` (Decision 41), `docs/wakil/north-star.md:272-273` (phase map), `docs/wakil/parked.md:18-30` (Track agenda), `PRODUCT.md` (a line beside the Landing/background-agents description), `app/Sources/WakilKit/App/WindowModel.swift` ~7986 (the "Owed" paragraph on `sessionStarted`), `docs/architecture/flows.md` (switch and close)

- [ ] **Step 1: Runbook**, setup (an organisation with one project and staging, two real agents), rows only
  for what checks cannot reach: two real agents in one place, one on a long task; switch between them
  mid-turn and watch the thread keep streaming; approve a write from the background one's chip
  (amber), then from its Running row; quit and find each in Continue; the chip and Running row of a
  production environment keep their red segment (Invariant 8, walk-only); colour of the five dots,
  including grey idle (walk-only).
- [ ] **Step 2: Charter.** Decision 41: an *Amended 2026-10-23 (operator)* paragraph — a place holds
  any number of live conversations, one on screen; pinning is per conversation; replace the headline
  and the "stays alive until quit or a new conversation" sentence, pointing at the spec. North-star:
  one row `| **Conversations** | Several live conversations per place: new (⌘N), switch (Running, ⌘P, chips), close (⌘⇧W); folds New conversation and Track | — | — |`.
  `parked.md`: each Track item gets `→ answered: <call>` per Global Constraints, the section intro says
  the agenda is answered by the Conversations spec. PRODUCT.md: one line — a place can hold several
  live conversations; the Landing's Running column lists them; ⌘N starts one, ⌘⇧W closes one.
  `WindowModel` comment: replace "Owed: nothing clears it in-window … A `session_new` action is that
  return path …" with "Cleared in-window by `session_new` (`newConversation`): the place's Landing returns
  and the conversation keeps running in the background."
- [ ] **Step 3: Render** `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-conversations-acceptance.md`; `make docs-check` shows no new failure.
- [ ] **Step 4: Commit** `git commit -m "Conversations 3: runbook, Decision 41 amended, one phase-map row, Track agenda answered"`

Before merge: `make e2e-full` on the head that merges, unattended, with the operator's go; re-render the runbook after it.
