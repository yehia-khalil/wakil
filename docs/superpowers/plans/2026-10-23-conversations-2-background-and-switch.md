# Conversations 2 of 3: background and switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘N puts the conversation on screen into the background, untouched, and shows the place's
Landing; every live conversation is listed (Landing's Running column, ⌘P Running, a chip when it has
something to show) and a click switches to it — same session, thread, canvas and draft, no fork.

**Architecture:** Two operator-only `.control` actions, `session_new` and `session_switch`, park on a
new `ConversationBroker` drained by a pump in `WindowModel.init`, as `session_resume` parks on
`ResumeBroker`. `newConversation()` clears the place's `screenConversations` entry (plan 1) and puts
up the Landing over the scope of the place's reserved conversation id; `switchToConversation(_:)`
goes to its place and sets the entry. Pure pieces — the title rule, the state, the one-list rule —
live in `Core/` and `App/PaletteItems.swift`; `WakilApp` only draws them.

**Tech Stack:** Swift 6 / SwiftUI (WakilKit, WakilApp), Swift Testing; Go for the e2e driver's socket choice.

**Spec:** `docs/superpowers/specs/2026-10-23-conversations-design.md` (Build order, step 2). **Starts
from the head of plan 1's branch** (`2026-10-23-conversations-1-rekey.md`); plan 3 stacks on this one.

## Rulings the planner made

1. **The Landing after ⌘N draws over the reserved conversation's canvas, seeded from disk, and the
   #264 hook ignores what was already there.** Spec 2b: a new conversation's canvas starts from the
   project seed on disk, as at launch, in a scope keyed by its conversation id. `LayoutPersistence.load`
   already falls back to the seed for an id with no file, so ⌘N activates
   `LayoutScope(…, lineageRoot: reservedId)` and gets the seed copy. But the #264 hook
   (`WindowModel.swift` ~1205) clears the Landing whenever the screen's canvas has panes, and the seed
   almost always has some, so ⌘N would show the Landing for one dispatch. The ruling: `newConversation`
   records the pane ids the canvas held (`landingBaselines[place]`), and the hook fires only for a pane
   not in that set. At launch no baseline exists and #264 behaves as today. *Cost if wrong:* if the
   operator expected an empty canvas after ⌘N, drop the seed load — one line — and the baseline goes with it.
2. **Chip and Running-row identifiers are ordinal, not ids.** A check cannot know a conversation's
   UUID. Chips: `window.agentChip.<org>/<project>/<env>` for the place's first live conversation (so
   every existing check stays green), `…#<n>` for the n-th by creation. Running rows:
   `landing.row.running:<i>`, `i` from 0 in the column's order. *Cost if wrong:* an ordinal shifts when
   an earlier conversation closes; a check addressing `#2` after a Close addresses the next one.
3. **`session_switch {conversation}` takes an id or a title.** Parity (plan 3) needs a static param;
   a title (the first message) is unique in practice. An exact title matching more than one live
   conversation in the caller's place is refused naming both ids (Rule 7 allows a refusal an
   ambiguity forces). *Cost if wrong:* drop the title lookup; parity then needs a step that can read an id.
4. **The title rule's "middle kept whole words"** is read as: whitespace collapsed; at most 48
   characters; when longer, the first words that fit in 24 characters, `" … "`, then the last words
   that fit in 21 — whole words only; when no whole word fits the first budget, the first 47
   characters and `"…"`. *Cost if wrong:*
   one function and its table test.
5. **⌘N cannot be disabled in the menu.** `AppScene`'s commands reach the model only through
   `delegate.startup`'s task (`withModel`), so a menu item cannot read `conversationOnScreen`
   synchronously. File ▸ New Conversation stays enabled and does nothing on a Landing (call 10's
   "does nothing visible"); its ⌘K row is hidden there as specified. *Cost if wrong:* the scene keeps
   a `@State` reference to the started session — a scene change, not a model one.
6. **⌘N materialises a File menu, which SwiftUI fills with Close and Close All** (AppScene's comment
   at ~384: either shuts the only window). Replacing `.newItem` with New Conversation therefore also
   replaces `.saveItem` with nothing here; plan 3 puts Close Conversation (⌘⇧W) in it. The File menu
   must hold New Conversation only, and the Window menu's ⌘W still Close Pane — checked by hand in
   Task 5. *Cost if wrong:* a stray Close All quits the app from the File menu.
7. **Focus after a switch** is the switched-to canvas's focused pane (its own `LayoutScope` keeps
   `focusedId`), else the composer. WakilKit cannot see AppKit's first responder, so "the focus it had
   when it was left" is approximated by what its canvas recorded. *Cost if wrong:* a conversation left
   with the composer focused over a focused pane returns to the pane.
8. **⌘P's Running group sits first, above Open panes** (`PaletteGroup.running`, raw value `-1`, so no
   other group's value moves). *Cost if wrong:* raw value only; nothing else depends on it.
9. **The chip label keeps the organisation**: `<org> · <project> · <env> — <title>`; the spec's
   `api · staging — …` is read as the same label abbreviated. The fold to "+N more" already keeps the
   row inside the window, so call 8's "scrolls rather than wrapping" adds nothing here.
10. **Denial sentences** (the spec names their point, not their words) are fixed in Global Constraints.

## Global Constraints

- ⌘N / File ▸ **New Conversation** / ⌘K **"New conversation"** puts the conversation on screen into the
  background, untouched, and shows the place's Landing. Nothing is asked (Rule 1). On a Landing it
  does nothing visible; its ⌘K command is hidden there.
- Every live conversation not on screen is a chip: violet while it works, amber while it waits for the
  operator, green when it finished unseen, red when it failed. Label `<place> — <title>`. An idle, seen
  conversation shows no chip but stays listed.
- The Landing gains a **Running** column before Continue: every live conversation in this place, newest
  activity first, with its state. A click switches to it. Continue keeps listing ended sessions.
- **Running and past never mix.** A Running row and a ⌘P Running row carry a state dot: violet working,
  amber waiting, green done unseen, red failed, **grey idle**. A past row carries no dot. A conversation
  is in one list only: a past one resumed moves to Running and leaves Continue (its chain is one row).
- ⌘P lists live conversations first under **"Running"**, across all places; picking one switches to it
  (no fork, no cost). Ended ones follow, as today, and resume as a fork.
- Switching brings back exactly what was left: thread, canvas and panes (live; a terminal's shell kept
  running), composer draft (text only; dictation stops on a switch). A running turn carries on.
- Switching never forks: no new session id, no fresh `claude` process. An in-flight turn is never
  touched by switching.
- Title: the first message to the agent, cut to **48** characters; before any message **"New conversation"**.
- `session_new`, `session_switch {conversation}`: `.control`, operator-only (in `operatorOnlyActions`),
  each pinned to the place and conversation it is dispatched in, through a broker drained by a pump.
  Denials, verbatim:
  - `session_new`: `"<tool>: only the operator starts a new conversation — an agent must not push aside the operator's conversation. Ask the operator to press ⌘N in the Wakil window."`
  - `session_switch`: `"<tool>: only the operator switches between conversations — an agent must not push aside the operator's conversation. Tell the operator which conversation the work needs; they can switch to it with ⌘P."`
- `session_list` gains the live conversations with their state and title, and an optional place filter.
- Focus: after New Conversation the Landing's composer is focused; after a switch, the conversation's
  (ruling 7). Production stays red: a chip or Running row for production keeps its red segment (Invariant 8).
- No second window, no cap, no persistence of the live set.
- No commit carries `Co-Authored-By` or a "Generated with" line.

## Review Focus

1. **⌘N while a turn streams**: the turn finishes in the background, its rows land in its own thread,
   the chip goes violet then green, and switching back shows every row. Pinned in Task 2.
2. **A past session resumed from Continue** leaves Continue in the same refresh (its chain's head and
   its live child both excluded). Pinned in Task 3.
3. **A draft typed on the Landing, then a switch, then back** keeps both drafts apart, and a
   dictation in progress stops on the switch. Pinned in Task 4.
4. **Switching to a conversation in another organisation** goes through `goTo` and lands on that
   conversation, not on the place's other one. Pinned in Task 2.
5. **⌘N, then a dispatch on the screen's socket** (the e2e harness's channel) acts as the reserved
   conversation, creating it, not as the backgrounded one. Pinned in Task 5.

---

### Task 1: Title, state, live entry and the one-list rule

**Files:**
- Create: `app/Sources/WakilKit/Core/Conversation.swift`
- Modify: `app/Sources/WakilKit/App/PlaceAgent.swift` (`title`, `lastActivity`, `ordinal`, `sessionIds`)
- Modify: `app/Sources/WakilKit/App/PaletteItems.swift` (`continueItems`)
- Test: Create `app/Tests/WakilKitTests/ConversationTitleTests.swift`; extend `app/Tests/WakilKitTests/PaletteSourcesTests.swift`

**Interfaces:**
- Consumes: plan 1's `PlaceAgent.id`.
- Produces:
  - `public enum ConversationState: String, Sendable, Equatable { case working, waiting, done, failed, idle }`;
    `public static func of(waiting: Bool, failed: Bool, working: Bool, done: Bool) -> ConversationState` (precedence as `AgentChip.state`, else `.idle`).
  - `public let newConversationTitle = "New conversation"`; `public func conversationTitle(_ firstMessage: String) -> String`.
  - `public struct LiveConversation: Sendable, Equatable { public let id: String; public let session: String?; public let place: Place; public let title: String; public let state: ConversationState; public let onScreen: Bool; public let lastActivity: Date }`;
    `public var json: JSONValue` → `{"conversation","session","organization","project","environment","title","state","onScreen"}`.
  - `PlaceAgent.title: String` (starts `newConversationTitle`; set once, by the first `send`, from the typed text);
    `lastActivity: Date` (creation, each `send`, each event appended); `ordinal: Int` (window-wide creation counter);
    `sessionIds: Set<String>` (every session it ran plus the parent it forked from).
  - `PaletteItems.continueItems(_ items: [PaletteItem], excluding sessions: Set<String>) -> [PaletteItem]`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: [
    ("fix the flaky login test", "fix the flaky login test"),
    ("  fix\nthe   flaky\tlogin test ", "fix the flaky login test"),
    ("please look at why the staging deploy keeps failing on the migration step",
     "please look at why the … on the migration step"),
    (String(repeating: "x", count: 60), String(repeating: "x", count: 47) + "…"),
    ("", "New conversation"),
])
func theTitleIsTheFirstMessageCutTo48(_ message: String, _ title: String) {
    #expect(conversationTitle(message) == title)
    #expect(conversationTitle(message).count <= 48)
}

@Test func stateTakesTheChipsPrecedenceAndIdleOtherwise() {
    #expect(ConversationState.of(waiting: true, failed: true, working: true, done: true) == .waiting)
    #expect(ConversationState.of(waiting: false, failed: false, working: false, done: false) == .idle)
}

@Test func continueLeavesOutEveryChainALiveConversationHolds() {
    let rows = PaletteItems.sessionItems(from: [row("p"), row("c", parent: "p"), row("other")])
    #expect(PaletteItems.continueItems(rows, excluding: ["c"]).map(\.payload) == ["other"])
    #expect(PaletteItems.continueItems(rows, excluding: ["p"]).map(\.payload) == ["other"],
            "the child's transcript not listed yet: its parent is the chain's row")
}
```

  (Use the existing row-fixture helper in `PaletteSourcesTests`/`WindowModelPaletteTests` for `row`; a row whose chain contains an excluded id is excluded — walk `parent` as `sessionItems` does.)

- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'ConversationTitleTests|PaletteSourcesTests'` — FAIL (symbols missing).
- [ ] **Step 3: Implement** the three pieces; `continueItems` needs each item's chain, so
  `sessionItems` records the absorbed ids on `PaletteItem` (`chain: Set<String>`, default empty).
- [ ] **Step 4: Run** the same filter, then `make app-test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "Conversations 2: a conversation's title, state and live entry; Continue leaves live chains out"`

### Task 2: `session_new` and `session_switch`

**Files:**
- Create: `app/Sources/WakilKit/Harness/ConversationBroker.swift` (shape and single-consumer guard of `ProviderSwitchBroker`)
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (two actions beside `session_resume`; new param)
- Modify: `app/Sources/WakilKit/MCP/PermissionPrompt.swift:91-…` (`operatorOnlyActions`, `operatorOnlyDenialMessage`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift:390-400,502` (build and pass the broker); `app/Sources/WakilApp/WindowSession.swift:327`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — init (broker param, `conversationPump`), `newConversation`,
  `switchToConversation`, `currentLayoutScope` (reserved id while `landingBaselines[place]` is set), the #264 hook (~1205)
- Modify: `app/Tests/WakilKitTests/ActionClassificationTests.swift` (pinned operator-only list), `AppWiringTests.swift:236` (registry list), `InvalidationContractTests.swift` (`landingBaselines`, `conversationPump`)
- Test: Create `app/Tests/WakilKitTests/ConversationSwitchTests.swift`; extend `PermissionPromptTests.swift`

**Interfaces:**
- Consumes: plan 1's `screenConversations`, `reservedConversations`, `conversation(id:)`, `agent(for:)`; Task 1's `PlaceAgent.title`.
- Produces:
  - `public enum ConversationRequest: Sendable, Equatable { case new(conversation: String?); case switchTo(conversation: String, place: Place?) }` (`nil` = the screen's); plan 3 adds `.close`.
  - `public actor ConversationBroker { public init(); public func request(_ r: ConversationRequest); public func requests() -> AsyncStream<ConversationRequest> }`.
  - `registerStandardActions(…, conversationRequests: ConversationBroker = ConversationBroker(), liveConversations: (@Sendable (Place?) async -> [LiveConversation])? = nil)` — the second is Task 5's.
  - `session_new {}` → `{"backgrounded": <id or null>}`; `session_switch {conversation}` → `{"switching": <conversation>}`. Both read `ActionRegistry.dispatchCaller` for the pin (`conversation` / `place` when `pinnedPlace(of:)` is non-nil).
  - `WindowModel.init(…, conversationRequests: ConversationBroker = ConversationBroker(), …)`.
  - `public func newConversation(_ conversation: String? = nil) async` — no-op when the target is not on screen in its place or the place shows none.
  - `public func switchToConversation(_ idOrTitle: String, in place: Place? = nil) async` — refusals in `status`:
    `"switch to <x>: no live conversation is called that"`, `"switch to <x>: two conversations here are called that — <id1>, <id2>"`.
  - `public var conversationOnScreen: Bool { currentAgent != nil }`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func newConversationBackgroundsABusyOneAndItsTurnFinishesThere() async throws {
    show(placeA, in: model); #expect(await model.send("first job"))
    let first = try #require(model.currentAgent)
    await model.newConversation()
    #expect(!model.sessionStarted && model.currentAgent == nil && model.thoughts.isEmpty)
    #expect(first.harness != nil && sessions.harnesses.in(placeA).first?.stopped == false)
    sessions.harnesses.in(placeA)[0].emit(.result(/* a successful turn end, as PlaceAgentTests builds one */))
    #expect(await waitUntil { model.chips.first?.state == .done })
    await model.switchToConversation(first.id)
    #expect(model.currentAgent === first && model.sessionId == first.sessionId)
    #expect(sessions.harnesses.in(placeA).count == 1, "no fork, no fresh process")
}

@Test func theNextTurnOnTheLandingMintsANewSessionAndRoot() async throws {
    // after newConversation():
    #expect(await model.send("second job"))
    #expect(model.currentAgent?.id != first.id && model.lineageRoot == model.currentAgent?.id)
}

@Test func theLandingAfterNewConversationSurvivesTheSeedsPanes() async throws {
    // persistence with a seed holding one db pane; send, newConversation(), then any dispatch
    #expect(!model.sessionStarted, "the #264 hook ignores the seed's own panes")
    #expect(model.layoutSnapshot.panes.count == 1, "the new conversation starts from the seed")
}

@Test func newConversationOnALandingDoesNothing() async throws { /* no agent; newConversation(); reservedConversations unchanged via shownSocketSessionIdForTesting */ }

@Test func switchingToAnotherOrgsConversationGoesThere() async throws { /* conv in org B; goTo lands; currentAgent === it */ }

@Test func aTitleMatchingTwoConversationsIsRefusedNamingBoth() async throws {
    #expect(model.status == "switch to job: two conversations here are called that — \(a), \(b)")
}
```

  `PermissionPromptTests`: `sessionNewAndSwitchAreDeniedToTheAgentWithTheirOwnSentences` — `permissionDecision` for each returns `deny` and the Global Constraints sentence.

- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'ConversationSwitchTests|PermissionPromptTests|ActionClassificationTests|AppWiringTests'` — FAIL.
- [ ] **Step 3: Implement.** `newConversation`: `screenConversations[place] = nil`; `markSeen` nothing;
  record `landingBaselines[place]` = the canvas's pane ids; `activateLayout()` (which, with no
  conversation, installs `LayoutScope(…, lineageRoot: reservedConversations[place])` and reads the seed
  copy off disk); bump the Landing's composer focus (Task 4's hook). The first entrance into work there
  (`agent(for:)`) clears the baseline. `switchToConversation`: resolve, `goTo(target.place)` when it
  differs, set `screenConversations`, `activateLayout()`, `markSeen`. Pump: `.new` → `newConversation`,
  `.switchTo` → `switchToConversation`.
- [ ] **Step 4: Run** the same filter, then `make app-test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "Conversations 2: session_new backgrounds the conversation on screen; session_switch brings one back"`

### Task 3: The Landing's Running column and ⌘P's Running group

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `landingSessions()` (one-list rule), `paletteOpenSources` (~6245), `liveConversationRows(in:)`
- Modify: `app/Sources/WakilKit/Command/PaletteEntry.swift` (`PaletteGroup.running`, `PaletteEntry.state`), `app/Sources/WakilKit/Command/PaletteSources.swift` (`RunningConversationsSource`)
- Modify: `app/Sources/WakilApp/Landing.swift` (column, rows, dots), the palette row view in `app/Sources/WakilApp/` (draws `entry.state`)
- Test: extend `app/Tests/WakilKitTests/ConversationSwitchTests.swift`, `PaletteSourcesTests.swift`, `WindowModelPaletteTests.swift`

**Interfaces:**
- Consumes: Task 1's `LiveConversation`, `continueItems`; Task 2's `session_switch`.
- Produces:
  - `public func liveConversationRows(in place: Place? = nil) -> [LiveConversation]` — newest `lastActivity` first; `nil` = every place.
  - `case running = -1` in `PaletteGroup`, label `"Running"`; `PaletteEntry.state: ConversationState?` (init param, default `nil`).
  - `public struct RunningConversationsSource: PaletteSource` — `id "running"`, `group .running`, one row per entry:
    title = `title`, subtitle = `<place label> · <state word>`, `kindLabel "conversation"`, verb `"switch to"`,
    `action .dispatch(action: "session_switch", params: ["conversation": id])`, `isProduction` from the place, `state`.
  - Landing (has a project): `Running` (width 300) · `Continue · newest first` (width 360) · `Open` (width 300), Running drawn only when non-empty, else today's two columns unchanged. Row id `running:<i>`, title, subtitle `<state word> · <age>`, a 6 pt dot in the state's hue (grey idle = `coolWhite.opacity(0.50)`), and a production place's red segment as its chip draws it (Invariant 8). A click dispatches `session_switch` through the registry with origin `.ui`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func runningListsThePlacesLiveConversationsNewestFirstWithTheirState() async throws {
    // two conversations in placeA (send, newConversation, send, newConversation)
    #expect(model.liveConversationRows(in: placeA).map(\.title) == ["second job", "first job"])
    #expect(model.liveConversationRows(in: placeA).map(\.state) == [.working, .working])
}

@Test func aResumedPastSessionLeavesContinueAndJoinsRunning() async throws {
    // sessionRows fixture lists "parent-1"; on the Landing, continueSession("parent-1")
    await model.newConversation()
    #expect(await model.landingSessions().map(\.payload).contains("parent-1") == false)
}

@Test func openModeListsRunningFirstAcrossPlaces() async throws {
    let entries = await model.paletteRootEntries(mode: .open) { _ in }   // as WindowModelPaletteTests reads ⌘P
    #expect(entries.first?.group == .running)
    #expect(entries.filter { $0.group == .running }.count == 2)
}
```

- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'ConversationSwitchTests|PaletteSourcesTests|WindowModelPaletteTests'` — FAIL.
- [ ] **Step 3: Implement**; `landingSessions()` filters with `continueItems(excluding:)` over every live conversation's `sessionIds`. The Landing's `.task(id:)` also re-reads on `liveConversationRows(in:)` changes.
- [ ] **Step 4: Run** the filter, `make app-build`, `make app-test` — PASS; `make controls` reports no new unnamed control.
- [ ] **Step 5: Commit** `git commit -m "Conversations 2: the Landing's Running column and ⌘P's Running group, one list per conversation"`

### Task 4: Chips name their conversation; drafts and focus per conversation; ⌘N and ⌘K

**Files:**
- Modify: `app/Sources/WakilKit/App/AgentChip.swift` (`title`, `ordinal`, `identifier`, `id`), `app/Sources/WakilKit/App/WindowModel.swift` (`chips`, `screenKey`, `onScreenChange`), `app/Sources/WakilKit/App/ComposerModel.swift` (`drafts`, `screenChanged`)
- Modify: `app/Sources/WakilApp/AgentChips.swift:181-186` (identifier, click dispatches `session_switch`), `app/Sources/WakilApp/AppScene.swift:369` (File menu), `app/Sources/WakilKit/Command/CommandCatalog.swift` (`global.newConversation`, `PaletteContext.conversationOnScreen`), `WindowModel.paletteContext()` (~5809)
- Test: extend `AgentChipTests.swift`, `ComposerModelTests.swift`, `CommandCatalogTests.swift`, `ConversationSwitchTests.swift`

**Interfaces:**
- Consumes: Task 1's `PlaceAgent.title/ordinal`, Task 2's `newConversation`/`switchToConversation`.
- Produces:
  - `AgentChip`: `title: String`, `ordinal: Int` (1-based within its place), `label` = place label + `" — " + title`,
    `public var identifier: String` (`window.agentChip.<org>/<project>/<env>` for ordinal 1, else `…#<ordinal>`),
    `id: String` (= `conversation`). The memberwise defaults keep plan 1's call sites compiling.
  - `WindowModel.screenKey: String` — `currentAgent?.id ?? "landing:" + (reserved id of the place)`;
    `public var onScreenChange: (@MainActor (_ from: String, _ to: String, _ focusComposer: Bool) -> Void)?`
    (called by `newConversation` with `true`, by `switchToConversation` with `false` unless its canvas has no focused pane).
  - `ComposerModel.screenChanged(from: String, to: String, focusComposer: Bool)` — stores `draft`/`caret`
    under `from`, loads `to`'s (empty when none), calls `resigned()` to stop dictation, bumps `focusToken` when asked; registered in `init`.
  - `CatalogCommand` `global.newConversation`: label `"New conversation"`, `action "session_new"`, `available: { $0.conversationOnScreen }`.
  - File menu: `CommandGroup(replacing: .newItem) { Button("New Conversation") { withModel { m in Task { await m.dispatchSessionNew() } } }.keyboardShortcut("n", modifiers: .command) }` and `CommandGroup(replacing: .saveItem) {}` (ruling 6). `dispatchSessionNew()` dispatches `session_new` through the registry, origin `.ui`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aBackgroundConversationInThePlaceOnScreenHasAChipNamingIt() async throws {
    // send "fix the flaky login test" in placeA; newConversation()
    let chip = try #require(model.chips.first)
    #expect(chip.label == "initech · api · staging — fix the flaky login test")
    #expect(chip.identifier == "window.agentChip.initech/api/staging" && chip.state == .working)
}

@Test func aPlacesSecondConversationsChipIsOrdinal() async throws { #expect(model.chips.map(\.identifier).last == "window.agentChip.initech/api/staging#2") }

@Test func aBackgroundConversationsProposalWaitsOnItsChipAndIsApprovedThere() async throws {
    // conversation A parks an .agent PendingMutation(place: placeA, conversation: a) while the Landing is up
    #expect(await waitUntil { model.chips.first?.state == .waiting } && model.pending == nil)
    await model.switchToConversation(a)
    #expect(model.pending?.conversation == a)
    await model.confirmPending(typed: "confirm")   // the plane's own typed confirmation (Invariant 7)
    #expect(await parked.value == .approved)
}

@Test func eachScreenKeepsItsOwnDraftAndASwitchStopsDictation() {
    composer.edited(draft: "half a thought", caret: 14)
    composer.screenChanged(from: "conv-a", to: "landing:r", focusComposer: true)
    #expect(composer.draft.isEmpty && composer.focusToken == before + 1)
    composer.screenChanged(from: "landing:r", to: "conv-a", focusComposer: false)
    #expect(composer.draft == "half a thought" && composer.caret == 14)
}

@Test func newConversationIsOfferedOnlyWithAConversationOnScreen() {
    #expect(CommandCatalog.entries(for: PaletteContext(conversationOnScreen: true)).contains { $0.id == "global.newConversation" })
    #expect(!CommandCatalog.entries(for: PaletteContext()).contains { $0.id == "global.newConversation" })
}
```

- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'AgentChipTests|ComposerModelTests|CommandCatalogTests|ConversationSwitchTests'` — FAIL.
- [ ] **Step 3: Implement.** `AgentChips.swift` uses `chip.identifier` and dispatches `session_switch {conversation: chip.conversation}`; the dot breathes as today.
- [ ] **Step 4: Run** the filter, `make app-build`, `make app-test` — PASS; existing chip e2e checks keep their identifiers (ruling 2).
- [ ] **Step 5: Commit** `git commit -m "Conversations 2: chips name their conversation; drafts and focus per conversation; ⌘N and ⌘K"`

### Task 5: `session_list` live entries; the e2e channel picks the screen's conversation

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift:2502-2520` (`session_list`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (`useActiveContext(of:)` points a `LiveConversationLookup` box at the window, as `ActiveAgentLookup`)
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift:255-276` (`initializeMeta`), `app/Sources/WakilApp/WindowSession.swift:64-78` (`ScreenPlace` carries the screen key)
- Modify: `e2e/driver/mcp.go:140-186`, `e2e/driver/screenchannel.go` (`SelectScreenSocket`, `screenClient`)
- Test: `app/Tests/WakilKitTests/ConversationSwitchTests.swift`, `MCPServerTests.swift`; `e2e/driver/socket_test.go`

**Interfaces:**
- Consumes: Task 1's `LiveConversation.json`; Task 3's `liveConversationRows(in:)`.
- Produces:
  - `session_list {project?, environment?}`: Go's answer unchanged plus `structuredContent.live: [LiveConversation.json]`, every place, narrowed by the filter when given (organisation = the caller's). Schema gains the two optional strings.
  - `public final class LiveConversationLookup: @unchecked Sendable { public func use(_ source: @escaping @Sendable (Place?) async -> [LiveConversation]); public func live(in place: Place?) async -> [LiveConversation] }` in `App/ActiveAgentLookup.swift`.
  - `initializeMeta(place: Place, screen: Place?, conversation: String?, screenConversation: String?)` → adds `"wakil/conversation"`, `"wakil/screenConversation"` (null when unknown). The socket's is `caller().conversation`; the screen's is `WindowModel.screenKey` without the `landing:` prefix.
  - Go: `Meta.Conversation`, `Meta.ScreenConversation *string`; `SocketPlace` gains both; the screen socket is the one whose place is the screen's **and**, when both sides carry a conversation, whose conversation is the screen's; a socket without the field is chosen by place as today.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sessionListCarriesTheLiveConversationsNarrowedByPlace() async throws {
    let out = try await registry.dispatch(name: "session_list", params: ["project": "api"], origin: .ui, caller: nil, confirmation: nil)
    #expect(liveTitles(out) == ["second job", "first job"])
    #expect(liveStates(out) == ["working", "idle"])
}
```

  `socket_test.go`: `TestTwoSocketsOfOnePlacePickTheScreensConversation` (two probes, same place, conversations `a` and `b`, screen `b` → picks `b`'s path); `TestASocketWithoutConversationMetaIsChosenByPlace`.

- [ ] **Step 2: Run** `cd app && ../scripts/swift-test.sh --filter 'ConversationSwitchTests|MCPServerTests'` and `go test ./e2e/driver/ -run 'Screens|ByPlace'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make build && make test && make app-test` — PASS.
- [ ] **Step 5: Hand check (operator's go, on screen):** `make app-bundle`, open `.build/…/Wakil.app` as the e2e runbooks do; the File menu holds only **New Conversation ⌘N**; the Window menu's ⌘W is Close Pane; ⌘N on a conversation shows the Landing with the composer focused. Not run without the operator's go.
- [ ] **Step 6: Commit** `git commit -m "Conversations 2: session_list lists live conversations; the e2e channel picks the screen's conversation"`

The checks for this plan's controls are plan 3 Task 3; `make e2e` on this head waits for the operator's go.
