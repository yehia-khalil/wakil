import Testing
@testable import WakilKit

/// Every stored property on `WindowModel`, classified.
///
/// **`WindowModel` is `@Observable`, so `Mirror` does not see what the
/// source says.** The macro rewrites each stored property into a computed
/// one over `_`-prefixed backing storage and adds `_$observationRegistrar`.
/// So labels arrive as `_organization`, `_project`, … plus a `$`-bearing
/// one — and an `@ObservationIgnored` property arrives under its PLAIN
/// name. Normalising (strip one leading `_`, drop `$` labels) rather than
/// hard-coding the underscored spellings is what keeps this test working
/// if a property is ever marked `@ObservationIgnored`.
///
/// **What this proves, and what it does not.** This test proves every
/// stored property on `WindowModel` has been CLASSIFIED — org-derived (reset),
/// kept per place (survives), org-derived behind a reference, or
/// org-independent — not that `invalidateForOrgChange()` actually resets
/// every org-derived one correctly. That behaviour is covered by Task 7's
/// assertions and by the acceptance runbook. The failure mode this test
/// defends against is a property nobody thought about at all; it is not a
/// substitute for checking the reset logic itself.
private let orgDerived: Set<String> = [
    "project", "projectKey", "environment", "environmentProduction",
    // 3b-v: the settings in force include the active project's tabs, so they follow the org.
    "editorSettings",
    // 3b-viii: the quick tasks route to the org's providers on its credentials, and each pane's
    // ghost session asks them; `invalidateForOrgChange` shuts both down, and the switch rebuilds.
    "quickTasks", "ghostSessions", "ghostTextEnabled", "quickTasksConfigError",
    "providerId",
    "lookup", "rootPaths", "hasProjectRoot",
    "organization", "resumedParentForTesting",
    // 2e (#198): `settings` is the active organisation's whole
    // configuration — its three strings, its accounts, its projects —
    // and `settingsFailure` is why the last read of THAT organisation did
    // not produce one. Every field in the tree is inside the boundary
    // Invariant 4 defines, so left set across a switch the settings pane
    // would draw one organisation's configuration under another's name
    // until the next read landed.
    "settings", "settingsFailure",
    // 2e (#200): `accounts` carries `mine` on every row — a statement
    // about which organisation the operator is standing in, false for
    // every row the moment that changes.
    "accounts",
    // 2e (#202): an in-flight login belongs to the organisation the
    // operator was standing in when they started it. A switch ends that
    // context, and a band left on screen would be offering to add an
    // account to an organisation nobody is looking at.
    "providerLogin",
    // The task mirroring the session's states onto `providerLogin`. Left
    // running across a switch it would write the OUTGOING organisation's
    // states onto the incoming one's band — the same shape as a stale
    // harness pump, and cancelled in `invalidateForOrgChange` for the
    // same reason.
    "providerLoginObserver",
    // 2e (#204): which account the in-flight add is for. Org-scoped for
    // the same reason `providerLogin` is — the add belongs to the
    // organisation it was started in.
    "addingAccountId",
    // Palette: what ⌘P/⌘K read in the outgoing org — the root build's context and identity, each
    // step's stamp, the last list, the fresh tables and the per-org table caches. Left set, a row
    // read in org A could run, or a cached table list answer, in org B (Invariant 4).
    // `invalidatePalette` empties them; `paletteBuiltIn` becomes `.organisationLeft`, not nil,
    // because nil means "never built" and runs unchecked.
    "paletteBuiltFor", "paletteBuiltIn", "paletteStepStamps", "paletteLatest", "paletteFreshTables",
    "paletteTableCaches",
    // The build in flight and each delivered build's identity and context, by generation: read in
    // the outgoing org, emptied with the rest.
    "paletteBuilding", "paletteBuilds",
    // What the operator typed into a free-text step (a cURL command) in the outgoing org — its
    // hosts, paths and tokens. Emptied; `paletteEpoch` is bumped (not zeroed, `paletteGeneration`'s
    // reason) so a palette opened before the switch keeps nothing into the next org.
    "paletteRecents", "paletteEpoch",
    // SET, not cleared, by `invalidatePalette`: the open palette's steps were read in the org
    // left, so one with no stamp is refused. `paletteClosed` clears it.
    "paletteLeftOrganisation",
    // Bumped, not zeroed, by `invalidatePalette`: a late answer asked under the outgoing org's
    // number is dropped, and a zeroed counter would let an old number match again.
    "paletteGeneration",
    // ⌘K's Send asks per api pane, and the token that orders them — `queryLineRestores`' shape:
    // every pane closes with the org, and pane ids are reused by the next one.
    "apiSendRequests", "apiSendRequestToken",
    // 3b-i PR 8: the pane whose path field is open names a pane on the screen being left, and
    // pane ids repeat across scopes. Cleared
    // (WindowModelEditorTests.anOrgSwitchClosesThePathFieldAndKeepsTheTabsWrite).
    "editorSaveAsRequest",
    // 3b-ii PR 7: the trees' mirror of the file list — the outgoing project's listings. Emptied
    // (WindowModelEditorTests.anOrgSwitchEmptiesTheTreesAndTheirList).
    "editorFiles",
    // 3b-iii PR 1: the window's mirror of the git status, the outgoing org's roots. Reset in the
    // same place as `gitStatus` (WindowModelGitTests.anOrgSwitchEmptiesTheMirror).
    "gitRoots",
    // 3b-ii final review: ⌘B / ⌘⇧F's pending request for the keyboard names an outgoing pane id
    // the next org reuses; carried over, it would move the keyboard in another organisation
    // (Rule 6). Cleared (WindowModelEditorTests.anOrgSwitchClearsAPendingColumnFocusRequest).
    "editorColumnFocusRequest",
    // 3b-ii-b: the reveal button's or ⌘K's pending selection names an outgoing pane id the next org
    // reuses. Cleared (WindowModelEditorTests.anOrgSwitchClearsAPendingRevealRequest).
    "editorTreeRevealRequest",
    // 3b-i Task 9: the Save / Don't Save / Cancel prompt names the screen's panes, and pane
    // ids repeat across scopes — a Don't Save after the switch would close a pane it never
    // asked about. A quit prompt cleared this way counts as a Cancel (`quitCancelled`); the
    // buffers it asked about stay dirty in their own scope.
    "unsavedPrompt",
]

/// **Kept per place: survives an org switch** (background agents 3 of 4). Each is keyed by its
/// place or scope, or describes the screen's scope and is re-read when the incoming one is
/// activated (`activateLayout` → `refreshPanes`), so nothing of the outgoing org is drawn or
/// resolved under the incoming one, and coming back finds it as it was left
/// (`OrgSwitchTests.comingBackToAnOrgFindsItsCanvasAsLeft`). `invalidateForOrgChange` must NOT
/// reset these: doing so is the teardown this plan removed.
private let keptPerPlace: Set<String> = [
    // One `PlaceAgent` per place — harness, socket, session, thread, turn, conversation and
    // `Bash` mirror (OrgSwitchTests.anOrgSwitchLeavesTheRunningAgentAlone), and what its chip
    // shows: an unseen result or failure, and whether its environment is production (Plan 4).
    "agents",
    // The socket each shown place opened before a session took it, pinned to that place.
    "shownSockets",
    // Every proposal waiting, by place (OrgSwitchTests.anOrgSwitchWithAParkedApprovalSwitchesAnyway).
    "parkedProposals",
    // The screen's scope and every scope this window has read or written for an agent: kept so
    // a return reads nothing off disk and re-runs no subject.
    "layoutScope", "loadedLayoutScopes", "scopesAwaitingRestore", "backgroundLayouts",
    // A note an off-screen read gave, keyed by its scope and said on the return to it.
    "layoutNotesAwaitingReturn",
    // Projections of the screen's scope, rebuilt from the stores whenever a scope is activated.
    "tables", "editables", "paneCells", "layoutSnapshot", "databases", "databaseDrivers",
    // Per pane of the screen's canvas, as on a project switch. `apiSendRequests` is emptied by
    // the swap itself (`activateLayout`).
    "queryLineRefusals", "queryLineRestores", "queryLineRestoreToken",
    "databaseChoices", "apiSendRequests", "apiSendRequestToken",
    // The editor's saves in flight, debounced saved-tabs writes and autosave: each acts on a
    // buffer in its own scope, which stays (OrgSwitchTests.anOrgSwitchWithUnsavedTabsAsksNothingAndKeepsThem).
    "editorSaves", "editorTabsWrites", "editorAutosave", "editorAutosaveTimers", "editorAutosaveRuns",
    // The stores themselves: every scope's arrangement, contents and shells.
    "panes", "layout", "terminals",
    // The pool of clients pinned to agent places, and what their `wakil-ctx`s said: the places
    // with a live agent are still in use after a switch.
    "placeClients", "placeContexts",
]

private let orgIndependent: Set<String> = [
    // 2d-ii: the operator's hand on ⌥, not either organisation's state.
    "isListening",
    // 2e (#202). Both are injected at construction and describe HOW to
    // log in, never WHO for: the factory picks a conformance by provider
    // KIND, and the binary is the agent executable a login spawns as.
    // Neither carries an organisation, and replacing them on a switch
    // would replace them with themselves.
    "providerLoginFactory",
    // 2e (#204). `providerMintFactory` makes the thing that spawns
    // `wakil provider mint`. It is a FACTORY over the organisation for
    // exactly the reason `lookupFactory` above is: `WakilCLIProviderMint`
    // bakes the org in at construction, so a minter held directly would
    // be org-derived and a switch would have to replace it. Held as a
    // factory it is not — the org arrives at the call, and the same
    // instance stays correct across a switch. (It began as a held
    // minter and was converted when running the app showed the org
    // switch could strand a mint in flight.) The in-flight state lives
    // on the session, which is classified separately.
    "providerMintFactory",
    // 9b W1. `apiResolver` holds the wiring's pane store and its `wakil-http` client, which an
    // org switch restarts in place (`WakilWiring.switchOrg`) rather than replaces; it reads the
    // org-derived listing at each call, so the same instance stays correct across a switch.
    "apiResolver",
    // Fix round 1. The operator's environment switch in progress: a task the pump waits on,
    // not org-derived state. An org switch starts no environment switch of its own.
    "operatorEnvironmentSwitch",
    // Plan 4 final review I1: `goTosInFlight` counts chip clicks between switches, raised and
    // lowered by the `goTo` that runs each, whichever org it ends in — the shape of `switching`.
    "goTosInFlight",
    "registry", "persistence", "context",
    "harnessFactory", "lookupFactory", "resumes", "confirmations",
    // 3b-viii: takes the organisation per call, like `harnessFactory`; the generation only orders
    // rebuilds, whichever org each was for.
    "quickModelFactory", "quickTasksGeneration",
    // Background agents 3 of 4, Task 4: how a session's socket is started. It names no
    // organisation; a socket answers for the place it was started for.
    "agentSocketFactory",
    // Set by `shutdown`: no organisation's state, the window's end.
    "socketsClosed",
    "providerSwitches", "providerSwitchPump", "resumePump",
    "status",
    "dragCandidate", "confirmationPump", "observationPump",
    "pendingSave", "debugEventSink", "debugEventsEnabledOverride",
    // Task 11: `terminalRunPump` describes the run-journalling transition
    // itself, not either org's state, the same shape `switching` below
    // already is. (`terminals` itself is `keptPerPlace`: every shell survives.)
    "terminalRunPump",
    // W14 (preflight F1): `flightPump` is `observationPump`'s sibling — a wake-up on the one
    // `PaneStore`, which an org switch clears in place rather than replacing.
    "flightPump",
    // Final review C1: the editor's siblings of `flightPump` — wake-ups on the one `PaneStore` and
    // the one `EditorFileLists`, which an org switch clears in place rather than replacing.
    "editorFlightPump",
    "editorFilesPump",
    // Task 10: `switching` describes the org-switch transition itself,
    // not either org's state; `orgSwitcher` is a capability
    // (`WakilWiring.switchOrg(to:)`, injected), not state at all.
    "switching", "orgSwitcher",
    // `capacityProbe` is the last capacity probe task, a handle for tests; not either org's state.
    "capacityProbe",
    // 2026-09-20 (#148): `layoutSwapInFlight` describes the canvas swap
    // itself — the window between the stores being pointed at the
    // incoming scope and the arrangement for it being in hand — and not
    // either org's state, the same shape as `switching` above. The flag
    // is cleared by the `activateLayout` that set it, whichever org it
    // ends up in.
    "layoutSwapInFlight",
    // 2026-10-08 (#328): `layoutActivating` and `layoutSwapWaiters` widen
    // the same guard — the activation in flight, and the callers waiting on
    // it. Both are emptied by the `activateLayout` that set them, whichever
    // org it ends up in, for the reason above.
    "layoutActivating", "layoutSwapWaiters",
    // Task 14: `showOrgPlane` describes what is on screen — the org plane
    // is open or it is not — never either organisation's state. A switch
    // must not open or close it as a side effect, so `invalidateForOrgChange()`
    // never touches it either.
    "showOrgPlane",
    // 3b-v final review I-2: `unsavedResolving` is the answer-the-prompt transition itself —
    // set and cleared by the `resolveUnsaved` that runs it, whichever org it ends in — the
    // same shape as `switching`.
    "unsavedResolving",
    // 3b-i PR 8: the saved-tabs debounce's length (configuration, shortened by tests) and the
    // count of writes it ran (a test seam). Neither describes an organisation.
    "editorTabsDelay", "editorTabsWriteCount", "editorAutosaveDelay", "editorAutosaveCount",
    // 3b-i Task 9: event counts again — a quit prompt resolved to quit, or to stay. The app
    // replies to AppKit when either DIFFERS from the last value it saw.
    "quitApproved", "quitCancelled",
    // 2026-09-24 (#284): `keyboardFocusRequests` is the same shape again —
    // how many times an operator control asked for a pane to be focused.
    // Nothing reads its value; a view reacts to it DIFFERING from the last
    // one it saw, which is why resetting it here would be worse than
    // leaving it. A reset is a change, every focused pane would answer it,
    // and an org switch would end by pulling first responder into a pane
    // nobody clicked.
    "keyboardFocusRequests",
    // The palette's close asking the focused pane to take the keyboard back — the same
    // counter shape: a reset is a change, and the focused pane would pull the keyboard on it.
    "keyboardReturns",
    // 2026-10-03 (2c-iv Amendment 9a): `surfaceChain` is the order an api
    // pane's calls land in — the tail of a queue, not either org's state,
    // the same shape `terminalRunPump` is. Each link dispatches through the
    // registry exactly as the bare `Task` it replaced did, so an org switch
    // meets a queued call no differently than it met one in flight before;
    // and dropping the tail would only let a later call overtake an earlier
    // one, which is the one thing the chain exists to prevent.
    "surfaceChain",
    // Palette. `paletteClients` is injected capability — the wiring's `wakil-db`/`wakil-http`/
    // `wakil-git` clients, restarted in place by `WakilWiring.switchOrg`, the same shape as
    // `apiResolver` above.
    "paletteClients",
    // `statusWrites` counts writes to `status`, `keyboardFocusRequests`' shape: a run compares it
    // with the mark it took, so a reset could make a later write look like none.
    "statusWrites",
    // ⌘P/⌘K pressed, and its serial: the operator's hand on a key, `isListening`'s shape. A view
    // reacts to a NEW press, so a reset would be read as one.
    "paletteKeyPress", "paletteKeySerial",
    // Every palette close, counted — `statusWrites`' shape: a run compares it with the count it
    // began under, so a reset could make a later close look like none.
    "paletteCloses",
    // Whether the plane is up — what is on screen, `showOrgPlane`'s shape. The window closes
    // the palette itself when the org plane rises (`WakilWindow`), through `paletteClosed`.
    "paletteShowing",
    // Background agents, 2 of 4: the tail of the pool's retain queue, `surfaceChain`'s shape —
    // the order retains land in, not either org's state.
    "placeRetain",
]

/// **A stable reference whose CONTENTS are org-scoped and must be torn
/// down.** `orgIndependent` does not mean *"this reference is not
/// reassigned"*: a store whose contents belong to the org left would be
/// misfiled there. (The stores and the terminals were this bucket's first
/// members; they are `keptPerPlace` now that every scope survives a switch.)
///
/// That reading is how the app tears down. `WakilWiring.switchOrg(to:)` stops and restarts the SAME
/// `MCPClient` instances in place, never replacing them, because
/// `registerStandardActions` closed over those instances. A live child
/// process dying while its owning reference never changes is the shape
/// this app uses everywhere, and the tripwire had no vocabulary for it.
///
/// **Widening the skip rule is still the wrong fix**, which is what the
/// message below has always said. Each bucket's NAME is the instruction
/// the next author needs.
private let orgDerivedBehindAReference: Set<String> = [
    // PR 6 of the split. `claude` holds the operator's typed `claude` path (org-derived:
    // `invalidateForOrgChange` clears it through `claudePathOverride`,
    // ClaudeLocatorTests.anOrgSwitchClearsTheTypedOverride) and the machine lookup
    // (org-independent: one machine).
    "claude",
    // Provider capacity. `capacity` holds the outgoing org's readings; `invalidateForOrgChange`
    // calls `capacity.reset()` (CapacityFeedTests.resetForgetsReadingsAndFailure).
    "capacity",
    // PR 3 of the split. `gitWatcher` holds the watcher and the roots it watches —
    // one for the window's life, whose CONTENTS are the outgoing project's roots.
    // `invalidateForOrgChange` ends with `syncGitWatcher`, which syncs it to no roots:
    // the watcher stops and `watchedRoots` empties (GitRootWatcherTests.noRootsStopsAndForgetsThem).
    "gitWatcher",
    // 3b-i PR 5. `editorWatcher` is `gitWatcher`'s twin for editor panes — one for the window's
    // life, watching the outgoing project's roots while an editor pane is open.
    // `invalidateForOrgChange` ends with `syncEditorWatcher`, which syncs it to no roots, so it
    // stops (WindowModelEditorTests.anOrgSwitchStopsTheEditorWatcher).
    "editorWatcher",
    // 3b-ii PR 7. `fileLists` is one for the window's life (the wiring's), whose CONTENTS are the
    // outgoing project's listings. `invalidateForOrgChange` ends with `syncEditorWatcher`, which
    // finds no roots and calls `setWatching(false)` on it, emptying it
    // (WindowModelEditorTests.anOrgSwitchEmptiesTheTreesAndTheirList).
    "fileLists",
    // 3b-iii PR 1: one for the window's life (the wiring's), its CONTENTS the status of the screen's
    // roots. `invalidateForOrgChange` resets it (WindowModelGitTests.anOrgSwitchEmptiesTheMirror).
    "gitStatus",
    // 2e (#202). `providerLoginSession` is exactly the shape this third
    // bucket was created for: the reference is stable — every login goes
    // through the one session this window owns — while its CONTENTS are
    // an in-flight browser trip belonging to the organisation it was
    // started in. `invalidateForOrgChange` calls `dismiss()` on it, which
    // cancels the running task rather than merely clearing a field: a
    // nilled reference does not kill a spawned `claude auth login`, the
    // same way a cleared dictionary does not kill a shell.
    "providerLoginSession",
    // 2d-i. `vocabulary` is the same shape: one store for the window's
    // life, whose CONTENTS are the outgoing org's names. Its first
    // statement, `invalidateForOrgChange` calls `dropAll()` on it, so
    // nothing of the old org resolves after the switch (Invariant 4).
    "vocabulary",
]

@MainActor
@Test func everyWindowModelPropertyIsClassifiedForTheOrgSwitch() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    var unclassified: [String] = []

    for child in Mirror(reflecting: model).children {
        guard var label = child.label else { continue }
        if label.contains("$") { continue }
        if label.hasPrefix("_") { label.removeFirst() }
        if orgDerived.contains(label) || orgIndependent.contains(label)
            || orgDerivedBehindAReference.contains(label) || keptPerPlace.contains(label) { continue }
        unclassified.append(label)
    }

    #expect(
        unclassified.isEmpty,
        """
        WindowModel gained stored properties that no one has decided about \
        for an org switch: \(unclassified.sorted().joined(separator: ", ")).

        An org change invalidates every credential boundary the window holds. \
        Add each name to orgDerived (and reset it in invalidateForOrgChange), \
        to orgDerivedBehindAReference (and TEAR ITS CONTENTS DOWN there — a \
        cleared dictionary does not kill a shell), to keptPerPlace (keyed by \
        its place or scope, so it survives), or to orgIndependent. Do not \
        widen the skip rule instead — this test exists to make you choose.
        """)
}
