# Conversations 1 of 3: rekey by conversation, no visible change — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything keyed by place that a second conversation in that place would collide on —
the agents store, the confirmation slots, the dispatch caller, the sockets, the event pump, the chip
flags, the canvas scope an agent works in — is keyed by conversation instead, with one conversation
per place and nothing on screen changed.

**Architecture:** `PlaceAgent` gains a stable `id`, the conversation id: the id Wakil already mints
before the first session (today's `assignedSessionId` at creation), never moved by a resume or a
provider switch. `WindowModel` stores conversations by that id and which one each place shows;
`agents: [Place: PlaceAgent]` becomes a projection, so every reader and every existing test keeps
working. `DispatchCaller` and `PendingMutation` carry the conversation; `ConfirmationBroker` keys its
slots by `ProposalSlot(place, conversation)`, with `conversation == nil` the operator's place-level slot.

**Tech Stack:** Swift 6 (WakilKit), Swift Testing. No Go change, no WakilApp change.

**Spec:** `docs/superpowers/specs/2026-10-23-conversations-design.md` (Build order, step 1). Plans 2
(`2026-10-23-conversations-2-background-and-switch.md`) and 3 (`…-3-close-and-record.md`) stack on
this one's branch head.

## Rulings the planner made

1. **The conversation id is fixed at creation; `assignedSessionId` keeps moving.** The spec says the
   conversation's identity is `PlaceAgent.assignedSessionId`, reused. The code moves
   `assignedSessionId` to the child on every resume (`WindowModel.resume`, "the window's assigned
   identity moves with it") and on a provider switch, so it cannot be a dictionary key. The ruling:
   `PlaceAgent.id` is the value `assignedSessionId` has when the conversation is created (the id the
   place's shown socket reserved), and stays; `assignedSessionId` keeps today's meaning. The first
   session, its socket path and `DispatchCaller.conversation` all carry that id, as the spec says; a
   fork's socket path is still the fork's session id (one path per session, `agentSocketPath`). *Cost
   if wrong:* if the operator wanted `session_switch` to name the newest fork's id, plan 2's
   `session_switch` must also accept a session id (cheap: look it up in `PlaceAgent.sessionIds`).
2. **The pre-turn canvas scope keyed by conversation id needs no new type here.** `markSessionStarted`
   already mints `lineageRoot = assignedSessionId`, so every conversation that has begun has
   `LayoutScope(lineageRoot: id)` from its first pane, before any turn. The one rootless canvas is the
   launch seed (#264's shown-work path), which must stay as it is for "no visible change". The scope
   that is keyed by an id with no conversation yet — the Landing after `session_new` — is plan 2's.
   *Cost if wrong:* none in this plan; plan 2 Task 2 owns it.
3. **`session_list`'s place filter moves to plan 2**, with the live entries it filters: Go's
   `list_sessions` already answers for the caller's pinned place, so a filter has nothing to narrow
   until live entries exist. *Cost if wrong:* none; no caller needs it before plan 2.
4. **The journal records the conversation id, not its title** (spec call 5: "the label gains the
   conversation title"). Titles are not persisted and are minted after the first message; an id joins
   `session_list`'s live entries (plan 2). *Cost if wrong:* a reader of `journal.jsonl` resolves the
   title through `session_list`; adding `conversationTitle` later is additive.
5. **The existing tests are unchanged except two fixtures** that CONTRIBUTING requires for any stored
   property change: `InvalidationContractTests`' `keptPerPlace` set (`agents` and `parkedProposals`
   become computed; `conversations`, `screenConversations`, `reservedConversations`, `parkedSlots`
   are classified there, same reason).

## Global Constraints

- A conversation is the unit, not the place: one conversation per place in this plan; nothing visible changes.
- Its identity is the id Wakil mints before the first session; the socket path, `DispatchCaller`,
  `shownSockets` (rekeyed by it) and `session_switch` (plan 2) all carry that one id.
- Pinning moves from place to conversation: each agent's calls arrive on its own socket and resolve to
  its conversation and its place, whatever is on screen.
- `ConfirmationBroker` is rekeyed by conversation; the operator's own gated actions keep a place-level slot.
- `session_resume`, `session_set_provider` (`setProvider`) and `resume(in:)` act on the caller's
  conversation for an agent and on the on-screen one for the operator.
- Nothing new on disk: lineage stays in `sessions.json`; the set of live conversations is not persisted.
- Every existing test unchanged and green (fixtures in ruling 5 excepted).
- No commit carries `Co-Authored-By` or a "Generated with" line.

## Review Focus

1. **A resume in a background place**: the agent's own `session_resume` while the operator is
   elsewhere must fork *its* conversation, keep `PlaceAgent.id`, and leave the screen's alone. Pinned in Task 3.
2. **The operator's proposal and an agent's in the same place**: both park; neither is `.busy`
   because of the other; the plane shows the operator's. Pinned in Task 1.
3. **A socket call that lands after its conversation's session was replaced** (old shim still
   connected): it resolves by the caller's conversation id to the same conversation, not to the
   screen's. Pinned in Task 3.
4. **Renaming a project with an idle conversation** keeps that conversation reachable under the new
   place (`agents[newPlace]`, `conversation(id:)`), its id unchanged. Pinned in Task 4.
5. **Shutdown with a socket reserved but never taken** stops it once, and stops every conversation's
   socket. Pinned in Task 4.

---

### Task 1: The caller, the proposal and the broker carry the conversation

**Files:**
- Modify: `app/Sources/WakilKit/Core/Place.swift:23-35` (`DispatchCaller`)
- Modify: `app/Sources/WakilKit/Gate/PendingMutation.swift:16-52`
- Modify: `app/Sources/WakilKit/Gate/ConfirmationBroker.swift` (storage, `request`, `resolve`, new reads)
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift:821-829` (`parkForConfirmation` passes the conversation)
- Modify: `app/Sources/WakilKit/Registry/Journal.swift:40-85` and where `ActionRegistry` builds a `JournalEntry` from the caller
- Test: `app/Tests/WakilKitTests/ConfirmationBrokerTests.swift`, `app/Tests/WakilKitTests/JournalPlaceTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `DispatchCaller.conversation: String?`; `init(place: Place, session: String?, via: String? = nil, conversation: String? = nil)`.
  - `public struct ProposalSlot: Hashable, Sendable { public let place: Place; public let conversation: String? }` (in `ConfirmationBroker.swift`).
  - `PendingMutation.conversation: String?` (init param `conversation: String? = nil`, after `place`);
    `public var slot: ProposalSlot` — `ProposalSlot(place: place, conversation: origin == .agent ? conversation : nil)`.
  - `ConfirmationBroker`: `current(in slot: ProposalSlot) async -> PendingMutation?`;
    `allSlots() -> [ProposalSlot: PendingMutation]`; `slotUpdates() -> AsyncStream<[ProposalSlot: PendingMutation]>`;
    `cancelAgentProposal(inConversation id: String)`. Kept, as place projections: `current(for: Place)`
    (place slot, else the place's agent proposal with the lowest conversation id), `all()`, `updates()`,
    `cancelAgentProposal(in: Place)` (every agent slot in the place).
  - `JournalEntry.conversation: String?`, encoded only when non-nil (as `via`).

- [ ] **Step 1: Write the failing tests** (`ConfirmationBrokerTests.swift`)

```swift
@Test func twoConversationsInOnePlaceEachParkTheirOwn() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let a = proposal("a", place: placeA, conversation: "conv-a")
    let b = proposal("b", place: placeA, conversation: "conv-b")
    async let aDecision = broker.request(a)
    async let bDecision = broker.request(b)
    while await broker.allSlots().count < 2 { await Task.yield() }
    #expect(await broker.current(in: ProposalSlot(place: placeA, conversation: "conv-b")) == b)
    await broker.cancelAgentProposal(inConversation: "conv-a")
    #expect(await aDecision == .cancelled)
    #expect(await broker.allSlots() == [b.slot: b])
    await broker.approve(id: b.id)
    #expect(await bDecision == .approved)
}

@Test func theOperatorsProposalKeepsThePlaceSlotBesideAnAgentsInThatPlace() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let agent = proposal("agent", place: placeA, conversation: "conv-a")
    let mine = proposal("mine", place: placeA, origin: .ui, conversation: "conv-a")
    async let agentDecision = broker.request(agent)
    async let mineDecision = broker.request(mine)
    while await broker.allSlots().count < 2 { await Task.yield() }
    #expect(mine.slot == ProposalSlot(place: placeA, conversation: nil))
    #expect(await broker.current(for: placeA) == mine, "the plane's projection shows the operator's")
    await broker.cancelAll()
    _ = await (agentDecision, mineDecision)
}
```

  Extend the file's `proposal(_:place:)` helper with `origin: ActionOrigin = .agent, conversation: String? = nil`.
  In `JournalPlaceTests.swift`: `anAgentsEntryNamesItsConversation` — dispatch with
  `DispatchCaller(place: p, session: "s-1", conversation: "conv-1")`, read the journal line,
  `#expect(line.contains("\"conversation\":\"conv-1\""))`; `theOperatorsEntryNamesNoConversation` —
  `#expect(!line.contains("\"conversation\""))`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'ConfirmationBrokerTests|JournalPlaceTests'`
Expected: FAIL — `ProposalSlot`, `current(in:)`, `allSlots()` and the `conversation:` labels do not exist.

- [ ] **Step 3: Implement.** Broker storage `pending`, `waiters`, `timeoutTasks` keyed by `ProposalSlot`;
  `.busy` when `pending[proposal.slot] != nil`; `publish()` yields both the slot map to `slotUpdates()`
  subscribers and its place projection to `updates()` subscribers. `parkForConfirmation` passes
  `conversation: await caller().conversation`. The journal writes `caller.conversation`.

- [ ] **Step 4: Run the tests and the whole suite**

Run: `cd app && ../scripts/swift-test.sh --filter 'ConfirmationBrokerTests|JournalPlaceTests'` then `make app-test`
Expected: PASS; every existing broker and MCPServer test unchanged and green.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Core/Place.swift app/Sources/WakilKit/Gate app/Sources/WakilKit/MCP/MCPServer.swift app/Sources/WakilKit/Registry app/Tests/WakilKitTests/ConfirmationBrokerTests.swift app/Tests/WakilKitTests/JournalPlaceTests.swift
git commit -m "Conversations 1: the caller, the proposal and the confirmation slot carry the conversation"
```

### Task 2: Conversations stored by id; sockets keyed by conversation

**Files:**
- Modify: `app/Sources/WakilKit/App/PlaceAgent.swift` (`id`, `init`, `caller`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:42-60` (store), `:504` (`shownSockets`), `:6925-7060`
  (`ShownSocket`, `openSocket`, `openShownSocket`, `makeSession`, `stopSession`), `:8051-8085`
  (`markSessionStarted(in:)`, `agent(for:)`), `:1650-1665` (testing accessors keep their place-taking shape)
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift:118-135` (ruling 5)
- Test: Create `app/Tests/WakilKitTests/ConversationKeyTests.swift` (reuse `Sessions`, `Harnesses`,
  `resumableWindow`-style setup from `PlaceAgentTests.swift`; make those helpers `internal` if private)

**Interfaces:**
- Consumes: `DispatchCaller(place:session:via:conversation:)` (Task 1).
- Produces:
  - `PlaceAgent.id: String` (`public let`); `init(id: String, place: Place, providerId: String, mirror: TerminalMirrorFeed)`;
    `caller` → `DispatchCaller(place: place, session: sessionId, conversation: id)`.
  - `WindowModel.conversations: [String: PlaceAgent]` (`public private(set)`, stored);
    `screenConversations: [Place: String]` (`public private(set)`, stored: which conversation each place shows);
    `reservedConversations: [Place: String]` (private, stored: the id a place's next conversation takes);
    `agents: [Place: PlaceAgent]` (computed: `screenConversations` resolved through `conversations`);
    `currentAgent` (computed, unchanged meaning); `public func conversation(id: String) -> PlaceAgent?`;
    `public func liveConversations(in place: Place? = nil) -> [PlaceAgent]` (creation order).
  - `shownSockets: [String: ShownSocket]` keyed by conversation id; `ShownSocket` gains `let place: Place`.
  - `makeSession(in:_:sessionId:conversation:)`; `openSocket(_:in:sessionId:conversation:)` builds
    `DispatchCaller(place:, session: sessionId, conversation:)`.

- [ ] **Step 1: Write the failing tests** (`ConversationKeyTests.swift`)

```swift
@Test func aConversationsIdIsTheIdItsFirstSessionAndSocketCarry() async throws {
    let sessions = Sessions(); let (model, _) = try await resumableWindow(sessions)
    show(placeA, in: model)
    #expect(await model.send("hello"))
    let agent = try #require(model.currentAgent)
    #expect(agent.sessionId == agent.id)
    #expect(sessions.issuedSockets.first?.path == agentSocketPath(agentSessionId: agent.id))
    #expect(await sessions.issuedSockets.first?.caller().conversation == agent.id)
    #expect(model.conversations[agent.id] === agent && model.agents[placeA] === agent)
}

@Test func aResumeKeepsTheConversationIdAndMovesTheSession() async throws {
    // send, then model.resume(sessionId: "parent-1"):
    #expect(agent.id == idBefore)
    #expect(agent.sessionId != idBefore && agent.assignedSessionId == agent.sessionId)
    #expect(await sessions.issuedSockets.last?.caller().conversation == idBefore,
            "the fork's own socket still answers for its conversation")
}

@Test func aProviderSwitchKeepsTheConversationId() async throws { /* setProvider("other-provider"); same shape */ }

@Test func theShownSocketReservesTheIdThePlacesFirstConversationTakes() async throws {
    // show placeA, activateLayoutForTesting(), settleShownSocketsForTesting();
    let reserved = try #require(model.shownSocketSessionIdForTesting(placeA))   // existing accessor
    model.markSessionStarted()
    #expect(model.currentAgent?.id == reserved)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter ConversationKeyTests`
Expected: FAIL — `PlaceAgent.id`, `conversations`, `DispatchCaller.conversation` on the socket caller do not exist.

- [ ] **Step 3: Implement.** `agent(for place:)`: return `currentAgent` for that place if any, else
  create with `id = reservedConversations.removeValue(forKey: place) ?? UUID().uuidString`, store in
  `conversations`, set `screenConversations[place]`. `openShownSocket`: the id is the screen
  conversation's when it has no harness and no socket, else the place's reserved id (minted and stored
  in `reservedConversations` when absent); `shownSockets[id] = ShownSocket(sessionId: id, place:, opening:)`.
  `markSessionStarted(in:)`: `assignedSessionId = agent.id` when nil (replaces the `shownSockets[place]`
  read). `stopSession(of:)`: removes `shownSockets[agent.id]`, calls `cancelAgentProposal(inConversation: agent.id)`.
  `refreshChipProduction`'s identity check becomes `self.conversations[agent.id] === agent`.
  Testing accessors (`shownSocketSessionIdForTesting(_ place:)`, `settleShownSocketsForTesting()`) keep their
  signatures; the first finds the shown socket whose `place` is the one given.

- [ ] **Step 4: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'ConversationKeyTests|PlaceAgentTests|ShownSocketTests|InvalidationContractTests'` then `make app-test`
Expected: PASS, nothing else changed.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/PlaceAgent.swift app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/ConversationKeyTests.swift app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "Conversations 1: conversations stored by their id; sockets keyed by conversation"
```

### Task 3: Calls, proposals, chips and turns resolve to their conversation

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `init` (`confirmationPump` → `slotUpdates()`,
  `registry.setScopeLookup`), `:363-369` (`parkedSlots` stored, `parkedProposals`/`pending`/`waitingPlaces`
  computed), `:1286-1289` (`agentScope`), `:7069-7080` (`send` resolves `TurnScope.conversation`),
  `:7275-7282` (`markUnseen`), `:7343-7345` (`resume`), `:4857-4862` (`followConversation`),
  `:4880-4915` (`backfillTerminals`, `pumpMirror`, `persistBackgroundLayouts`), `:7895-7912` (`chips`)
- Modify: `app/Sources/WakilKit/App/AgentChip.swift` (`conversation`)
- Modify: `app/Sources/WakilKit/Harness/ResumeBroker.swift:4-19`; `app/Sources/WakilKit/Registry/StandardActions.swift:2384-2405` (`session_resume`)
- Test: `app/Tests/WakilKitTests/ConversationKeyTests.swift`

**Interfaces:**
- Consumes: Task 1's `ProposalSlot`, `slotUpdates()`, `PendingMutation.slot`; Task 2's `conversation(id:)`, `PlaceAgent.id`.
- Produces:
  - `ResumeRequest.conversation: String?`; `init(sessionId: String, place: Place? = nil, conversation: String? = nil)`.
    `session_resume` passes `ActionRegistry.dispatchCaller?.conversation` when `pinnedPlace(of:)` is non-nil.
  - `WindowModel.resume(sessionId: String, in place: Place? = nil, conversation: String? = nil) async` —
    `conversation.flatMap(conversation(id:)) ?? agent(for: place ?? self.place)`.
  - `TurnScope.conversation: String?` (the on-screen conversation's id when read; memberwise init gains it with default `nil`).
  - `parkedSlots: [ProposalSlot: PendingMutation]` (`public private(set)`); `pending` =
    `parkedSlots[ProposalSlot(place: place, conversation: nil)] ?? currentAgent.flatMap { parkedSlots[ProposalSlot(place: place, conversation: $0.id)] }`.
  - `AgentChip.conversation: String`; init gains `conversation: String = ""` (last param). `chips`:
    one per conversation `!== currentAgent`, waiting when `parkedSlots` holds an `.agent` proposal for its id.
  - `private func agentScope(for caller: DispatchCaller) -> LayoutScope` — by `caller.conversation`,
    else by place as today.
  - Off-screen tests in `markUnseen`, `followConversation`, mirror and background-persist read
    `agent !== currentAgent` instead of `agent.place != place`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aCallOnABackgroundConversationsSocketWritesItsOwnCanvas() async throws {
    // A sends (pane-less), show B; dispatch pane_open through A's recorded socket caller:
    let caller = try #require(await sessions.issuedSockets.first?.caller())
    _ = try await registry.dispatch(name: "pane_open", params: ["kind": "db"], origin: .agent, caller: caller, confirmation: nil)
    #expect(model.layoutSnapshot.panes.isEmpty, "B's canvas is untouched")
    #expect(await layout.snapshot(in: try #require(model.agents[placeA]?.layoutScope)).panes.count == 1)
}

@Test func aResumeRequestNamingAConversationForksThatOne() async throws {
    // A and B each send; screen on B; resumes.request(ResumeRequest(sessionId: "parent-1", place: placeA, conversation: idA))
    #expect(await waitUntil { sessions.harnesses.in(placeA).count == 2 })
    #expect(model.agents[placeA]?.id == idA && sessions.harnesses.in(placeB).count == 1)
}

@Test func aLateCallFromAReplacedSessionStillResolvesItsConversation() async throws {
    // A sends; keep the first socket's caller; resume A; dispatch through the OLD caller:
    #expect(oldCaller.conversation == idA)   // agentScope routes to A's scope, not the screen's
}

@Test func aChipWaitsOnItsOwnConversationsProposalOnly() async throws {
    // park an .agent PendingMutation(place: placeA, conversation: idA) while B is on screen
    #expect(await waitUntil { model.chips.first?.state == .waiting })
    #expect(model.chips.first?.conversation == idA)
}
```

  (`layout.snapshot(in:)` is `ScopeRouting.$home.withValue(scope) { await layout.snapshot() }` — a local test helper.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter ConversationKeyTests`
Expected: FAIL — `ResumeRequest(conversation:)`, `AgentChip.conversation` missing; scope lookup still by place.

- [ ] **Step 3: Implement** per the Interfaces block. `setProvider` keeps its signature and replaces the
  on-screen conversation's session (it is operator-only); its `confirmations.current(for:)` guard reads
  `current(in: ProposalSlot(place: startPlace, conversation: currentAgent?.id))` and the place slot.

- [ ] **Step 4: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'ConversationKeyTests|PlaceAgentTests|AgentChipTests|ConfirmationBrokerTests|OrgSwitchTests|ResumeBrokerTests'` then `make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests/ConversationKeyTests.swift
git commit -m "Conversations 1: calls, proposals, chips and turns resolve to their conversation"
```

### Task 4: Place-level paths walk conversations; the docs say so

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:50-60` (`runningAgent`, `agentPlaces`),
  `:3522-3532` (`carryAgents`), `:9044-9075` (`shutdown`)
- Modify: `docs/architecture/state.md` (the in-memory line for `agents` → conversations by id), `docs/architecture/flows.md` (the agent tool-call flow: the caller names its conversation)
- Test: `app/Tests/WakilKitTests/ConversationKeyTests.swift`

**Interfaces:**
- Consumes: Task 2's store.
- Produces: `carryAgents` re-keys `screenConversations` and `reservedConversations` for a renamed place
  and sets each carried conversation's `place`; a conversation whose new place already shows one stays
  where it is (today's rule, kept until plan 3). `shutdown` stops every entry of `conversations` and
  every `shownSockets` value once.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aRenamedPlacesIdleConversationKeepsItsIdUnderTheNewPlace() async throws {
    // markSessionStarted in placeA (no harness), then the rename path the lifecycle tests use
    #expect(model.agents[renamedA]?.id == idA)
    #expect(model.conversation(id: idA)?.place == renamedA)
    #expect(model.agents[placeA] == nil)
}

@Test func shutdownStopsEveryConversationAndEveryReservedSocketOnce() async throws {
    // A sends; show B (a socket reserved, not taken)
    await model.shutdown()
    #expect(sessions.issuedSockets.allSatisfy(\.stopped))
    #expect(sessions.harnesses.issued.allSatisfy(\.stopped))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter ConversationKeyTests`
Expected: the rename test FAILS (the carried conversation's place and `screenConversations` key disagree) until `carryAgents` re-keys.

- [ ] **Step 3: Implement**, then update the two architecture docs in a sentence each.

- [ ] **Step 4: Run everything**

Run: `make build && make test && make app-test && make docs-check`
Expected: all green; `git diff --stat main -- app/Tests` shows only `ConversationKeyTests.swift`, the
two new cases in `ConfirmationBrokerTests.swift` / `JournalPlaceTests.swift`, and the
`InvalidationContractTests.swift` fixture.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift docs/architecture app/Tests/WakilKitTests/ConversationKeyTests.swift
git commit -m "Conversations 1: rename, shutdown and the running-agent check walk conversations"
```

No e2e run is owed: nothing visible changed. `make e2e` on this head waits for the operator's go.
