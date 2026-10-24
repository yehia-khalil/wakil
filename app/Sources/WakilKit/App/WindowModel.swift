import Foundation
import Observation

// MARK: - WindowModel

/// Everything the Task 11 window does that is not drawing.
///
/// It exists as a separate type in `WakilKit`, rather than as state inside
/// the SwiftUI view, because a test target cannot import an executable
/// target: anything left in `WakilApp` is covered by the operator runbook
/// alone (`docs/wakil/phase-2a-acceptance.md`). `WindowModelTests` therefore
/// covers the dispatch origin, the pane projection and the thought thread,
/// and the view is left with layout.
///
/// **Every state change goes through `registry.dispatch(..., origin: .ui)`**
/// (Invariant 2). Nothing here writes to `PaneStore`; the table is refreshed
/// by *reading* a snapshot back after a dispatch, so what the window draws
/// is the same registry-owned state `read_pane` serialises for the agent
/// (`MCPServer.readPane` returns `PaneStore.snapshot` verbatim), never a
/// reconstruction the UI made for itself.
///
/// `@MainActor` because SwiftUI observes these properties from the main
/// actor; `@Observable` so the view re-renders when they change.
@MainActor
@Observable
public final class WindowModel {
    /// The active organisation, project and environment (Invariant 8: the
    /// environment is on screen at all times). Empty until
    /// `refreshContext()` has answered — `environmentLabel` is what the view
    /// draws, and it says so rather than showing a blank.
    public private(set) var organization = ""
    /// `project.json`'s name, for drawing. Never what a pin carries — that is `projectKey`.
    public private(set) var project = ""
    /// The active project's registry key (`ContextStore.ActiveContext.projectKey`), which
    /// `WAKIL_PROJECT` is looked up by. Set and cleared with `project`.
    public private(set) var projectKey = ""
    public private(set) var environment = ""

    /// The place on screen now, which a harness is pinned to when it starts.
    public var place: Place {
        Place(organization: organization, project: projectKey, environment: environment)
    }
    /// Every conversation, by its id (`PlaceAgent.id`, conversations 1 of 3): each with its own
    /// harness, session, thread and turn, alive while the screen shows another place. Created on
    /// the first work in a place; no switch of organisation, project or environment stops or
    /// drops one.
    public private(set) var conversations: [String: PlaceAgent] = [:]
    /// The conversations' ids in the order they were created: what `liveConversations` lists by.
    @ObservationIgnored private var conversationOrder: [String] = []
    /// How many conversations this window has made: the next one's `PlaceAgent.ordinal`.
    @ObservationIgnored private var conversationsMade = 0
    /// Which conversation each place shows: the one its screen, its thread and its turn are.
    public private(set) var screenConversations: [Place: String] = [:]
    /// The id each place's next conversation takes: reserved by the socket the place opened when
    /// it was shown (`openShownSocket`), and taken when the conversation is created (`agent(for:)`).
    private var reservedConversations: [Place: String] = [:]
    /// The pane ids each place's canvas held when `newConversation` put its conversation into the
    /// background (conversations 2 of 3, ruling 1). While set, the place's Landing draws over the
    /// canvas of its reserved conversation (`landingRoot(in:)`), read off disk from the project
    /// seed, and the #264 hook ends the Landing only for a pane not among these. The first
    /// conversation created there (`agent(for:)`) clears it.
    private var landingBaselines: [Place: Set<String>] = [:]
    /// The places whose Landing `newConversation` is still bringing in: the #264 hook waits for
    /// the baseline rather than reading the seed's panes as work.
    @ObservationIgnored private var landingsLoading: Set<Place> = []
    /// The conversation each place shows, by place (background agents, 3 of 4): what every
    /// place-level reader reads, one per place.
    public var agents: [Place: PlaceAgent] {
        screenConversations.compactMapValues { conversations[$0] }
    }
    /// The agent of the place on screen, if work has begun there.
    public var currentAgent: PlaceAgent? { screenConversations[place].flatMap { conversations[$0] } }
    /// The conversation stored under `id`, on screen or not.
    public func conversation(id: String) -> PlaceAgent? { conversations[id] }
    /// Every conversation — or, given a place, that place's — in the order they were created.
    public func liveConversations(in place: Place? = nil) -> [PlaceAgent] {
        conversationOrder.compactMap { conversations[$0] }.filter { place == nil || $0.place == place }
    }
    /// The name of an agent whose session is live in `project` (and, when given, in that
    /// `environment` of it) of the window's current organisation, or nil: what renaming or
    /// removing the place checks first (Invariant 5). Live is a harness, as in `agentPlaces`, or a
    /// session start in flight (`PlaceAgent.runsOrStarts`), which already holds a socket
    /// answering for the place as it is.
    public func runningAgent(in project: String, environment: String?) -> String? {
        runningAgentName(
            among: conversations.values.map { (place: $0.place, live: $0.runsOrStarts, providerId: $0.providerId) },
            organization: place.organization, project: project, environment: environment)
    }

    /// The places whose agent has a live harness: what the pool keeps clients for.
    public var agentPlaces: Set<Place> { Set(conversations.values.compactMap { $0.harness == nil ? nil : $0.place }) }
    /// The clients pinned to agent sessions' places (`WakilWiring.placeClients`). Told the places
    /// still in use after every harness change, so a client for a place no session holds any
    /// more is stopped. Nil in tests that route no call; production passes the wiring's.
    private let placeClients: PlaceClients?
    /// What an agent's place's own `wakil-ctx` says about it — its roots and production
    /// flags — read through `placeClients`. Nil exactly when that is: a window that routes no
    /// call has no place but its own to answer for.
    private let placeContexts: PlaceContexts?
    /// The last `retain` handed to `placeClients`, so each waits for the one before it and
    /// the pool always ends on the latest place.
    private var placeRetain: Task<Void, Never>?
    /// The active project's production declarations (Decision 26, #182).
    ///
    /// Held so the VIEW can hand them to `VoidPalette.forEnvironment` and
    /// get the same answer the gate got. The gate's copy lives on
    /// `ActionRegistry`, set from the same line of `refreshContext`, for
    /// the reason its own doc gives; these two are not a drift risk because
    /// neither is derived — both are assignments of one value read once.
    public private(set) var environmentProduction: EnvironmentProduction = .undeclared
    /// The three of them, plus `rootPath`, as one value, for `term_open`
    /// to fold into a shell's own environment
    /// (`WakilWiring.useActiveContext(of:)`) and to default its `path`
    /// from (walk-defects B1).
    ///
    /// **Read in one hop, deliberately.** Four separate `await`s on this
    /// `@MainActor` model could interleave with a context switch between
    /// them and hand a shell one org's name beside another's project;
    /// this returns all four from a single isolated read. Empty members
    /// stay empty here and are dropped by `terminalChildEnvironment`,
    /// never exported as empty strings. `rootPath` is never empty — it is
    /// already the active project's root, falling back to the operator's
    /// home directory when no project is active — so `term_open` need not
    /// repeat that fallback.
    /// `project` here is the registry key, since it becomes the shell's `WAKIL_PROJECT`.
    public var activeShellContext: (org: String, project: String, environment: String, rootPath: String) {
        (org: organization, project: projectKey, environment: environment, rootPath: rootPath)
    }

    /// `activeShellContext` for a dispatch made for `caller`: what `term_open` and the api pane
    /// read (`WakilWiring.useActiveContext(of:)`). An agent session (`pinnedPlace(of:)`) gets its
    /// own place and its own project's first root, so its shell opens where it works, even while
    /// the screen shows that place. Anything else — the operator's own — gets the window's.
    ///
    /// Its own place even when its context cannot be read, starting in the home directory
    /// then: the window's root is the other project's, and a shell for one place opened in
    /// another's directory is the mismatch this exists to prevent.
    public func shellContext(
        forCaller caller: DispatchCaller?
    ) async -> (org: String, project: String, environment: String, rootPath: String) {
        guard let placeContexts, let away = pinnedPlace(of: caller) else { return activeShellContext }
        let roots = (try? await placeContexts.context(for: away).rootPaths) ?? []
        return (org: away.organization, project: away.project, environment: away.environment,
                rootPath: roots.first ?? NSHomeDirectory())
    }

    /// `gitRootPaths` for a dispatch made for `caller`: the roots the git and editor actions
    /// confine to. An agent session gets its own project's roots, and none when they cannot be
    /// read — never the window's, which belong to the project on screen.
    public func gitRootPaths(forCaller caller: DispatchCaller?) async -> [String] {
        guard let placeContexts, let away = pinnedPlace(of: caller) else { return gitRootPaths }
        return (try? await placeContexts.context(for: away).rootPaths) ?? []
    }

    /// The gate's lookup (`ActionRegistry.setProductionLookup`): nil for anything but an agent
    /// session (`pinnedPlace(of:)`), so the window's own flags apply. For an agent its own
    /// project's declarations — and `.undeclared`, the name rule, when they cannot be read.
    /// Never nil there: nil would let the screen's project judge another project's
    /// environments, and a `production: false` written for one would disarm the other.
    func productionFlags(forCaller caller: DispatchCaller) async -> EnvironmentProduction? {
        guard let placeContexts, let away = pinnedPlace(of: caller) else { return nil }
        return (try? await placeContexts.context(for: away).environmentProduction) ?? .undeclared
    }
    /// One table per pane, keyed by pane id.
    ///
    /// **Before 2c-i this was a single flattened `columns`/`rows` pair read
    /// under a `paneId` that defaulted to `"db"` and was never anything
    /// else**, drawn by the window rather than by any pane — which is why
    /// "every pane is dual-driven" was unreachable in that shape. Nothing
    /// here writes to `PaneStore`; these are refreshed *from* it, so what
    /// the operator sees and what `read_pane` hands the agent are the same
    /// object read twice, never two objects kept in step (Invariant 3).
    public private(set) var tables: [String: PaneTable] = [:]
    /// The pane's `PaneEditable`, cached per pane id in step with `tables`
    /// — refreshed by the same `refreshPanes` loop, from the same
    /// `PaneStore`. `DataSurface`'s double-click editor reads this **per
    /// pane id**, never as one window-scoped value: `DBPane`'s `refusal`
    /// doc comment records the walked failure a shared value causes — one
    /// pane's state painted under every other open pane.
    public private(set) var editables: [String: PaneEditable] = [:]
    /// Every open pane's snapshot, one observable cell per pane (`PaneSnapshotCell`), cached in
    /// step with `tables` — refreshed by the same `refreshPanes` loop, from the same `PaneStore`,
    /// so the screen reads the snapshot `read_pane` reads (Invariant 3). A terminal's blocks are
    /// captured at each `D` mark by `TerminalStore`'s frame-rate publisher and stored there;
    /// nothing here reads them back out of the emulator's buffer. Git is not a pane's contents: the
    /// window's status (`gitStatus`, mirrored in `gitRoots`) is re-read only by the git watcher.
    public private(set) var paneCells: [String: PaneSnapshotCell] = [:]
    /// The thread of the place on screen (`currentAgent`), empty where no work has begun.
    /// Row ids are monotonic per thread, never `thoughts.count`: `ThoughtRow` is
    /// `Identifiable`, and a repeated id makes SwiftUI draw one row twice and omit another.
    public var thoughts: [ThoughtRow] { currentAgent?.thoughts ?? [] }
    /// Provider capacity — see `CapacityFeed`.
    public let capacity: CapacityFeed
    /// Whether the on-screen place's turn is in flight: true from a successful `send`, false
    /// on the `.result` event that ends it. The Core reads it through `coreState`.
    ///
    /// Set on the *successful* path only. A `send` that failed — no harness,
    /// which is the ordinary degraded launch — never started a turn, and a
    /// Core left thinking forever is worse than one that never started.
    public var turnInFlight: Bool { currentAgent?.turnInFlight ?? false }
    /// True while push-to-talk is listening or finishing (2d-ii). Set only
    /// by `ComposerModel`. Org-independent: it describes the operator's
    /// hand on ⌥, not either organisation's state.
    public private(set) var isListening = false
    /// Which of §4's four states the Core draws. See `CoreState`. Listening wins over a turn
    /// in flight: the operator speaking the next turn is what the room
    /// should show.
    public var coreState: CoreState {
        isListening ? .listening : CoreState.forTurn(inFlight: turnInFlight)
    }

    public func setListening(_ on: Bool) {
        if isListening != on { isListening = on }
    }

    /// Where a turn's text came from, for the journal.
    public enum TurnSource: String, Sendable { case typed, voice }

    /// What `send` pins to the place the operator typed in (3b-ix): the composer reads it at
    /// Return and hands it back, so a turn that waits on the fast path still goes to that place.
    public struct TurnScope: Sendable, Equatable {
        public let place: Place
        public let rootPath: String
        public let providerId: String
        /// The screen's conversation when the scope was read — the one on screen, or on a Landing
        /// the id it reserves for the conversation its first message starts — so the turn goes to
        /// that one wherever the screen is by then, and to no other (Invariant 4). Nil on a Landing
        /// that had reserved none (`pinTurnScope` reserves one).
        public var conversation: String? = nil
    }

    public var turnScope: TurnScope {
        TurnScope(
            place: place, rootPath: rootPath, providerId: providerId,
            conversation: currentAgent?.id ?? reservedConversations[place])
    }

    /// `turnScope` as a gesture pins it, read the moment the gesture is made: a Landing that has
    /// reserved no id for its next conversation reserves one now — told as `openShownSocket`'s
    /// reservation is, the same screen re-keyed — so the gesture names the conversation it
    /// starts. Mid organisation switch it reserves nothing, as `openShownSocket` does not.
    public func pinTurnScope() -> TurnScope {
        if currentAgent == nil, reservedConversations[place] == nil, !switching {
            reservedConversations[place] = UUID().uuidString
            if !layoutActivating { tellScreenChange() }
        }
        return turnScope
    }

    /// The operator's dispatches that act on a conversation: each is pinned, when it is made, to
    /// the screen's (`pinTurnScope`), and the window acts on that one when the request drains —
    /// or on none (`conversation(pinned:landingIn:)`).
    static let screenPinnedActions: Set<String> = ["session_new", "session_resume", "session_close"]

    /// The conversation a gesture pinned to `id` acts on, resolved when it runs: the live one
    /// `id` names; else — `id` being the one a place's Landing reserves, while that place still
    /// shows its Landing — the conversation that Landing's first message starts, created now
    /// under `id`. Nil `id` (a Landing that had reserved none) is `place`'s Landing, while it
    /// still shows one. Nil when the screen the gesture was made on has gone — its Landing
    /// shows another conversation now, or the conversation `id` names is no longer live
    /// (`whyGone(pinned:)` says which) — so the caller refuses rather than act on a conversation
    /// the operator did not gesture at (Invariant 4).
    private func conversation(pinned id: String?, landingIn place: Place) -> PlaceAgent? {
        if let id, let live = conversations[id] { return live }
        let landing = id.map { id in reservedConversations.first { $0.value == id }?.key } ?? place
        guard let landing, screenConversations[landing] == nil else { return nil }
        return agent(for: landing)
    }

    /// Why `conversation(pinned:landingIn:)` found none for `id`, so the refusal says what is
    /// true (Rule 8): a Landing's — none reserved, or the id it reserves — whose place shows
    /// another conversation now, or an id that is neither live nor reserved (a conversation
    /// closed since, say).
    private enum PinnedConversationGone { case landingShowsAnother, noLongerLive }
    private func whyGone(pinned id: String?) -> PinnedConversationGone {
        guard let id, !reservedConversations.values.contains(id) else { return .landingShowsAnother }
        return .noLongerLive
    }
    /// True from the moment `setOrganization`'s OTHER guards pass until
    /// its whole sequence (success or failure) finishes. Org-independent:
    /// it describes the transition itself, not either the outgoing or the
    /// incoming org's state, so `invalidateForOrgChange()` never touches
    /// it and it is classified `orgIndependent` in
    /// `InvalidationContractTests`.
    ///
    /// **Not merely observed — a lock.** Originally write-only (kept
    /// because the org plane reads it for its in-progress state, per a
    /// prior review that flagged the dead write), `setOrganization`'s own
    /// first guard now refuses re-entry while this is already `true`
    /// (fix round 3) — see that guard's own doc comment for the concrete
    /// interleaving two independent, unguarded `setOrganization` calls
    /// could otherwise produce.
    ///
    /// **`public` since Task 14.** The org plane lives in `WakilApp`, a
    /// separate module — an `internal` property is invisible there, and a
    /// property this method's own review already flagged once as dead
    /// (written, never read) must actually be read by the one surface it
    /// was kept for, or it should come out entirely.
    public private(set) var switching = false
    /// The last thing that went wrong, as text. A SwiftUI control has
    /// nowhere to throw to, so a refusal or a transport failure has to
    /// become something on screen or it becomes nothing at all.
    public private(set) var status = "" {
        didSet { statusWrites &+= 1 }
    }
    /// Every write to `status`, counted, so the palette can tell a failure its run wrote from
    /// an older one still showing (`paletteFailure(since:)`).
    @ObservationIgnored private var statusWrites = 0

    /// The gate's own sentence, when a pane's last `runFromQueryLine` was
    /// given something that is neither a read nor a mutation — keyed by
    /// pane id, so a refusal raised by ONE pane's query line is drawn under
    /// that pane alone.
    ///
    /// **Fix round 1.** A single window-scoped `String?` here — what this
    /// property used to be — is drawn under EVERY open `DBPane`
    /// (`Canvas.paneView` passes it unconditionally into each one), so
    /// typing a refused statement into `db-2`'s line painted the refusal
    /// under `db-1` too: a pane misreporting what it is showing, the exact
    /// failure the query line exists to prevent, and the same shape as the
    /// ⌘↩ defect the probe caught — per-pane state that was actually
    /// window-scoped. Keyed storage is what makes `runFromQueryLine`
    /// clearing only ITS OWN pane's entry (not the dictionary wholesale)
    /// leave every other pane's refusal untouched.
    public private(set) var queryLineRefusals: [String: String] = [:]

    /// The refusal `pane` should draw beneath its own query line, or `nil`.
    /// What `DBPane` reads — never the raw dictionary, so the view cannot
    /// reach across panes by accident.
    public func queryLineRefusal(pane paneId: String) -> String? {
        queryLineRefusals[paneId]
    }

    /// What a pane's query line must go back to showing, and a token that
    /// makes each restoration its own event.
    ///
    /// **A mutation leaves the pane's subject alone, and the line has to be
    /// put back to it** (final review, Important 9) — see
    /// `queryLineTextAfterRun(outcome:subject:)`, which decides the text.
    /// `shouldAdoptSubject` cannot do this job: after a submit the line's
    /// `lastRendered` IS what was typed, so by that rule the line is
    /// untouched and already agrees with the subject, which is exactly the
    /// state this corrects.
    ///
    /// **A refusal also leaves the subject alone, but never publishes one
    /// of these** (final review, Critical 1). A refusal ran nothing, so the
    /// line and the subject never disagreed in the first place, and
    /// publishing a restore for one would overwrite the operator's own
    /// still-refused draft the moment it is rejected — see
    /// `runFromQueryLine`'s refusal branch.
    ///
    /// **The token is why this is a struct rather than a `String`.** Two
    /// confirmed mutations of the same statement on the same pane restore
    /// the same text, and a value that did not change is a value SwiftUI's
    /// `.onChange` never reports — so the second refusal would leave the
    /// line showing the refused statement. The token changes on every
    /// restoration, so each one is an event of its own.
    public struct QueryLineRestore: Sendable, Equatable {
        public let text: String
        public let token: Int
    }

    public private(set) var queryLineRestores: [String: QueryLineRestore] = [:]
    /// Monotonic across the window, not per pane: uniqueness is all it is
    /// for, and one counter cannot get out of step with itself.
    private var queryLineRestoreToken = 0

    /// What `pane`'s query line must go back to showing, or `nil` if
    /// nothing has asked it to. What `DBPane` reads — never the raw
    /// dictionary, the same rule `queryLineRefusal(pane:)` follows.
    public func queryLineRestore(pane paneId: String) -> QueryLineRestore? {
        queryLineRestores[paneId]
    }

    /// The databases the active environment defines, as `db_list_databases`
    /// lists them — what the query line's chooser offers (spec §5).
    ///
    /// Empty until `refreshDatabases()` has answered, and empty again if it
    /// fails: a window that cannot list databases still draws every pane,
    /// and the chooser simply has nothing to offer.
    public private(set) var databases: [String] = []

    /// Each listed database's driver, by name; `queryDialect(pane:)` reads it.
    /// Refreshed and reset together with `databases`.
    public private(set) var databaseDrivers: [String: String] = [:]

    /// The active organisation's configuration, as the settings pane draws
    /// it, or `nil` when the pane has not read yet or the read failed.
    ///
    /// **Not a cache, and the distinction is the ruling** (Decision 30).
    /// This is a render buffer: the view cannot `await` an actor while
    /// drawing, so the last read has to live somewhere a `body` can reach
    /// synchronously — the same reason `tables` and `layoutSnapshot`
    /// exist. What makes it not a cache is that nothing ever draws from it
    /// without a read having just filled it: `refreshSettings` runs on
    /// open and after every dispatch, so the pane shows what is on disk
    /// rather than what was on disk.
    ///
    /// That beats a watcher this app has never had, and it makes staleness
    /// structurally impossible rather than merely unlikely. Measured
    /// affordable during the map.
    public private(set) var settings: SettingsTree?

    /// Every account on this machine, as the settings pane's flat table
    /// draws it — or `nil` when it has not been read yet or the read
    /// failed.
    ///
    /// Filled by the same `refreshSettings` that fills `settings`, so the
    /// two halves of the pane are always one moment of disk rather than
    /// two. Not a cache, for the reason `settings` is not: nothing draws
    /// from it without a read having just filled it.
    public private(set) var accounts: AccountListing?

    /// What the settings pane's in-flight band is showing (#202).
    ///
    /// **A band on the pane, not a modal**, so the rest of settings stays
    /// visible while a browser trip runs. Mirrored here from
    /// `ProviderLoginSession` for the reason `layoutSnapshot` is mirrored:
    /// a view cannot await an actor while drawing.
    public private(set) var providerLogin: ProviderLoginState = .idle

    /// Why the last settings read did not produce a tree, or `nil`.
    ///
    /// Kept beside `settings` rather than folded into it because a pane
    /// that could not read and a pane that read an empty organisation must
    /// not draw alike — "could not look" rendered as "there is nothing
    /// there" is the failure the whole partiality convention exists to
    /// prevent.
    public private(set) var settingsFailure: String?

    /// The editor settings in force (3b-v): app-wide plus the active project's, read through
    /// `ctx_editor_settings` on every context read and after every editor-settings write. Every
    /// editor pane is drawn with `editorSettings.viewOptions`, and autosave reads its mode here.
    public internal(set) var editorSettings: EditorSettings = .defaults

    /// The database each pane's query line has been pointed at by the
    /// operator, keyed by pane id — see `QueryLineDatabaseChoice`, which
    /// carries what the pane's subject named at the time so a choice
    /// cannot outlive its own premise.
    public private(set) var databaseChoices: [String: QueryLineDatabaseChoice] = [:]

    /// Every proposal waiting for this operator, by slot: the operator's in its place's own,
    /// an agent's in its conversation's. Mirrored from `confirmations` by `confirmationPump`,
    /// started in `init` — not lazily, unlike `eventPump`, because a mutation can park before
    /// the operator ever sends anything to the agent.
    public private(set) var parkedSlots: [ProposalSlot: PendingMutation] = [:]
    /// One waiting proposal per place, as `ConfirmationBroker.all()` projects them.
    public var parkedProposals: [Place: PendingMutation] { ConfirmationBroker.project(parkedSlots) }
    /// The on-screen place's waiting proposal, or `nil`: the operator's own, else the on-screen
    /// conversation's. The confirmation plane renders from this; another place's or another
    /// conversation's waits, unseen, until the operator goes there.
    public var pending: PendingMutation? {
        parkedSlots[ProposalSlot(place: place, conversation: nil)]
            ?? currentAgent.flatMap { parkedSlots[ProposalSlot(place: place, conversation: $0.id)] }
    }
    /// The places with a proposal waiting, whoever proposed it. The chips count only the agent's
    /// (`chips`).
    public var waitingPlaces: Set<Place> { Set(parkedSlots.keys.map(\.place)) }

    /// The arrangement the canvas draws. A cached copy of
    /// `LayoutStore.snapshot()`, refreshed after every dispatch that could
    /// have changed it — the store is an actor and SwiftUI cannot await one
    /// while rendering.
    public private(set) var layoutSnapshot = LayoutSnapshot()

    /// `LayoutStore.focusRequests`, mirrored: how many times *anything* has
    /// asked for a pane to be focused, counting the requests that named the
    /// pane already focused.
    ///
    /// **First responder is not `focusedId`, and #284 is what that costs.**
    /// A pane takes the keyboard back when it becomes the focused pane, which
    /// is a *change* — and the commonest way to lose the keyboard does not
    /// change anything: typing to the agent moves first responder to the
    /// composer while `focusedId` stays exactly where it was. The rail click
    /// that is supposed to bring the operator back then dispatched
    /// `pane_focus` with the value the pane already had, nothing changed, no
    /// view reacted, and the keyboard stayed in the composer — so a proposal
    /// waiting on `⏎` could never be accepted at all.
    ///
    /// A counter rather than a flag to reset, or a `focusedId` the rail
    /// clears and re-sets: this is an *event*, and the only thing a view
    /// needs from it is that it differs from the last one it saw. Nothing
    /// reads its value.
    ///
    /// **Mirrored rather than raised here, and that is Invariant 2.** This
    /// used to be incremented in `focusPane`, which the rail and `⌘K` reach
    /// and the agent does not: an agent's `pane_focus` moved `focusedId` and
    /// no pane took the keyboard back, so the same action had two different
    /// effects depending on who asked for it. The count now lives where both
    /// channels meet — `LayoutStore.focus(id:)`, the registry action behind
    /// both — and every read of the store brings it along. That store's own
    /// doc comment carries the rest of the reasoning, including why it is
    /// neither in `LayoutSnapshot` nor in `byScope`.
    public private(set) var keyboardFocusRequests = 0

    /// Raised when the window hands the keyboard back to its focused pane without anyone asking
    /// for a pane: the palette closing over a SwiftUI-focused pane (`PaletteFocusReturn`).
    /// The panes answer it exactly as they answer `keyboardFocusRequests` — the focused one
    /// takes the keyboard — but it is **window-local and kept apart**: nothing is dispatched
    /// or journalled (the operator focused nothing), and `keyboardFocusRequests` keeps meaning
    /// "a focus request reached the layout store", which the palette's close compares to tell
    /// whether a run moved focus.
    public private(set) var keyboardReturns = 0

    public func returnKeyboardToFocusedPane() {
        keyboardReturns += 1
    }

    /// The snap the canvas should preview, or `nil`. Set by
    /// `previewDrag`, cleared by `endDrag` and by `commitDrag`.
    public private(set) var dragCandidate: SnapCandidate?

    let registry: ActionRegistry
    /// 2d-i: the names in scope this window's turns resolve against. Nil
    /// means no hint is ever added; production always passes
    /// `wiring.vocabulary` (`WindowSession.start`).
    let vocabulary: VocabularyStore?
    /// 3b-viii: makes a quick model for a provider record in an organisation. Nil means this
    /// window runs no quick task and answers no ghost request.
    @ObservationIgnored let quickModelFactory: (@Sendable (QuickProviderRecord, String) async throws -> (any QuickModel)?)?
    /// The quick tasks the window's organisation and provider route to, rebuilt whole on every
    /// change that could move them (`rebuildQuickTasks`, Ruling R4). Nil until the first build.
    @ObservationIgnored var quickTasks: QuickTasks?
    /// One ghost-text conversation per pane id, so a new request supersedes only its own pane's.
    @ObservationIgnored var ghostSessions: [String: GhostTextSession] = [:]
    /// Bumped by every rebuild, so a slower one that started earlier installs nothing.
    @ObservationIgnored var quickTasksGeneration = 0
    /// Why the last rebuild could not read the organisation's configuration, whole; nil once one
    /// has. Settings shows it as `quickTaskStatus().configError` (Rule 8).
    @ObservationIgnored var quickTasksConfigError: String?
    /// The operator's ghost-text switch, as the last rebuild read it. Off until a tree has been read.
    public internal(set) var ghostTextEnabled = false
    /// The organisation's fast-path switch (3b-ix), as the last rebuild read it. Off until a tree has been read.
    public internal(set) var fastPathEnabled = false
    /// The organisation's commit-drafts switch (3a-ii-b), read with the quick tasks.
    public internal(set) var commitDraftsEnabled = false
    private let panes: PaneStore
    private let layout: LayoutStore
    /// Every live PTY a terminal pane in this window opened. One per
    /// window, shared with the agent's path the same way `panes` and
    /// `layout` are — `WakilWiring.build` registers `term_open`,
    /// `term_propose` and `term_run` against this exact instance
    /// (`WindowSession.start` passes `wiring.terminals`), so a window
    /// holding some other instance would run the run pump below against a
    /// store no shell of this window's ever actually opens in.
    ///
    /// Not `private`, unlike `panes` and `layout` just above: Task 14's
    /// behavioural teardown tests assert reaping by pid
    /// (`terminals.pidForTesting(paneId:)`, `terminals.isRunning(paneId:)`)
    /// from outside this file, and a dictionary lookup on some OTHER
    /// store would not prove the shell this window actually opened is the
    /// one that died.
    let terminals: TerminalStore
    /// Where the active project's arrangement is written on commit and read
    /// back on switch (spec §4.3), or `nil` for a window that persists
    /// nothing — which is what a test that must not touch the filesystem
    /// asks for.
    private let persistence: LayoutPersistence?
    let context: ContextStore?
    /// Builds a harness for a given (org, provider) pair. A factory rather
    /// than an instance, because a resume is a new process: `stop()` makes
    /// a `ClaudeCodeCLIHarness` spent, and `events()` refuses a second
    /// consumer, so the only correct way to continue a conversation is a
    /// new instance. It takes the selection as a PARAMETER, rather than
    /// closing over one credential set captured at window-open, because
    /// `startHarness()` resolves fresh credentials from `lookup` every
    /// time it is called — on the window's first `send`, on every
    /// `resume`, and (Task 8/9) on a provider switch — and rebuilds the
    /// MCP config JSON from `selection.id` inside the closure itself
    /// (`WindowSession.start`'s doc comment on that closure has the full
    /// reason: a captured, stale JSON would run the new account's session
    /// with the OLD provider id on every MCP server). `nil` is the
    /// ordinary degraded launch — no provider available, or `lookup`
    /// refused it — and says so rather than appearing to send.
    ///
    /// **The place is a parameter, for the same reason the provider
    /// became one in 2b-vi**: the config JSON this closure builds carries
    /// the whole `Place` — `WAKIL_ORG`, `WAKIL_PROJECT`, `WAKIL_ENVIRONMENT`
    /// — to every MCP server the agent talks to, pinning the session where
    /// it starts. A factory that captured the launch place would run a
    /// later session's servers in the place the window was opened in.
    ///
    /// **And the socket path** (background agents 3 of 4, Task 4): each session has a socket of
    /// its own (`agentSocketFactory`), and its `--mcp-config` names that one.
    private let harnessFactory: @Sendable (Place, ProviderSelection, String) -> AgentHarness?
    /// Starts the socket one agent session's shim reaches Wakil on, answering for that session's
    /// place wherever the screen is. One per session, opened when its place is first shown
    /// (`openShownSocket`) and stopped with the session that took it.
    private let agentSocketFactory: AgentSocketFactory
    /// The socket each shown place opened before a session there took it, by the conversation
    /// it answers for (`openShownSocket`). A conversation's first session takes its socket and its
    /// id (`makeSession`); a session replaced before then (`resume`, `setProvider`) stops it
    /// (`stopSession`).
    @ObservationIgnored private var shownSockets: [String: ShownSocket] = [:]
    /// Set by `shutdown`: no place opens a socket after it.
    @ObservationIgnored private var socketsClosed = false
    /// Builds a credentials lookup for a given org.
    ///
    /// A factory rather than an instance because `WakilCLICredentialsLookup`
    /// bakes `organization:` in at construction (`WindowSession.swift`), so
    /// the instance is org-derived state and an org switch has to replace
    /// it. `lookup` below is what it feeds.
    private let lookupFactory: @Sendable (String) -> ProviderCredentialsLookup

    /// Picks the login conformance for a provider kind (#202).
    ///
    /// A factory for `lookupFactory`'s reason one object over: the
    /// conformance is chosen by kind, and a test drives the states through
    /// a fake one rather than spawning a browser. Decision 31's seam is
    /// this parameter.
    private let providerLoginFactory: @Sendable (String) throws -> any ProviderLogin
    /// Which `claude` a login spawns — see `ClaudeLocator` (#322): an injected binary
    /// (tests), the path the operator typed, this organisation's own record, the machine
    /// lookup. `nil` locator in tests, so none of them spawns the operator's shell.
    private let claude: ClaudeLocator
    /// The `claude` path the operator typed on the register form, which wins over every
    /// lookup (#322). Empty means "use what Wakil found".
    public var claudePathOverride: String {
        get { claude.override }
        set { claude.override = newValue }
    }
    /// Holds the in-flight trip. One per window: a second login started
    /// while one is running is refused by the session itself.
    private let providerLoginSession: ProviderLoginSession? = ProviderLoginSession()
    /// Mirrors the session's states onto `providerLogin`.
    private var providerLoginObserver: Task<Void, Never>?
    /// Builds a minter for one organisation. `nil` in a window that
    /// cannot add an account — a test, or a half-installed tree.
    ///
    /// **A factory, for `lookupFactory`'s reason.**
    /// `WakilCLIProviderMint` bakes the organisation in at construction,
    /// so an instance built at window-open would keep minting into the
    /// launch organisation after a live switch — storing a 365-day
    /// credential under the wrong organisation's Keychain name, which is
    /// the cross-organisation bleed Invariant 4 exists to make
    /// impossible. Held as a factory the organisation arrives at the
    /// call, so the same value stays correct across a switch.
    private let providerMintFactory: (@Sendable (String) -> any ProviderMinting)?
    /// Re-resolves every api pane's entry when the environment changes and at launch (9b W1).
    /// `nil` in a window that has no `wakil-http` to ask — a test. **The e2e check
    /// `api-env-roundtrip` is what fails if production forgets to pass it**, the defect shape
    /// `providerMintFactory` names: a defaulted injectable only running the app finds missing.
    @ObservationIgnored private let apiResolver: ApiPaneResolver?
    /// Which account the in-flight add is for.
    ///
    /// Held here rather than read off `providerLogin`, because the states
    /// that most need it — `.uncertain`, `.failed` — carry a sentence and
    /// not an id, and by the time the observer sees one the previous
    /// state is already gone.
    private var addingAccountId: String = ""
    /// The live lookup, rebuilt from `lookupFactory` wherever
    /// `organization` becomes authoritative — `refreshContext()`, which
    /// covers launch and every refresh, and `setOrganization`, which
    /// covers the switch without depending on that refresh succeeding.
    /// (Both named explicitly because this comment's earlier wording, "on
    /// an org change", was true of nothing: the only two sites that
    /// assigned it passed `""`, and the final fix pass is what made the
    /// sentence describe the code — see `init`'s own note.) No
    /// default: every caller, real or test, must say what a provider id
    /// resolves to explicitly — see `WindowModelTests`'
    /// `AlwaysSucceedsCredentialsLookup` for the fake the large majority
    /// of call sites there pass, since they do not exercise credential
    /// plumbing. Production (`WindowSession.start`) always supplies a
    /// real `WakilCLICredentialsLookup`.
    ///
    /// `var`, not `let`: a `let` cannot be reset, and this is on the
    /// invalidation contract's list (spec §5.3).
    private var lookup: ProviderCredentialsLookup
    private let resumes: ResumeBroker
    private var resumePump: Task<Void, Never>?
    /// Where a `session_set_provider` request parks — the identical
    /// broker-and-pump shape `resumes`/`resumePump` use, for the same
    /// structural reason: `registerStandardActions` registers the
    /// dispatchable action before any `WindowModel` exists, so it cannot
    /// close over `self`. See `ProviderSwitchBroker`'s own doc comment.
    private let providerSwitches: ProviderSwitchBroker
    private var providerSwitchPump: Task<Void, Never>?
    /// Where `session_new` and `session_switch` park (conversations 2 of 3) — the
    /// `providerSwitches` shape, for its reason. Drained by `conversationPump`.
    private let conversationRequests: ConversationBroker
    private var conversationPump: Task<Void, Never>?
    private var capacityProbe: Task<Void, Never>?
    /// Journals `term_run` for every command a terminal pane's shell
    /// finishes, from `terminals.completedRuns()`. Subscribed in `init`,
    /// unconditionally, for the same reason `confirmationPump` is: a pane
    /// can seal a block before the operator has done anything else in
    /// this window, and a run nobody read is a run nobody journalled. See
    /// `journalTerminalRun` for what each dispatch carries and why it
    /// fires once, at the block's `D` mark, rather than at its `C`.
    private var terminalRunPump: Task<Void, Never>?
    /// Restarts every Go client under `org`'s credentials — production is
    /// `WakilWiring.switchOrg(to:)`, injected as a closure rather than a
    /// direct call because `WindowModel` lives in `WakilKit` while
    /// `WakilWiring` and its clients are assembled in `WakilApp`
    /// (`WindowSession.start`), and because a closure is what lets a test
    /// drive `setOrganization` without spawning a real child process.
    /// Returns diagnostics on failure and an EMPTY array on success — never
    /// throws, since `setOrganization` has nowhere to catch to but
    /// `status`. A capability, not state: org-independent in
    /// `InvalidationContractTests`.
    private let orgSwitcher: @Sendable (String) async -> [String]
    /// The directory a FRESH session runs in: the project's first declared
    /// root. A resumed session runs in its own recorded cwd instead.
    ///
    /// **`var` as of 2b-viii.** It holds the outgoing org's project root
    /// across a switch otherwise, and nothing fails — `buildLaunch` takes
    /// the path it is given, so a fresh session in org B would simply run
    /// `claude` in org A's directory. The first symptom is `read_session`
    /// refusing a cwd that is not a root of the active project
    /// (`cmd/wakil-ctx/main.go:186`), several switches later. `refreshContext`
    /// rebuilds it (spec §5.3).
    ///
    /// **`public private(set)` as of Task 16.** The terminal pane's mirror
    /// draws "Wakil's shell · `<cwd>` · bare environment" for a mirrored
    /// block, and the cwd it names is THIS — the mirror never ran in the
    /// pane's own pty, so the block itself carries no cwd of its own to
    /// read (`TerminalMirror.swift`'s ruling 2). Reading it here, rather
    /// than threading a `harnessCwd` parameter through the mirror decode,
    /// keeps `mirroredBlocks` pure and keeps the snapshot to its seven
    /// published keys — the drawing task reads the window's own knowledge
    /// directly, exactly as 2c-iii's plan called for.
    ///
    /// **Computed from `rootPaths` as of 3a-i**, and only ever its first: every consumer that
    /// predates the git pane — `term_open`'s default path, the harness's launch directory, the
    /// no-root note, the mirror's cwd — sees exactly what it saw when this was stored.
    public var rootPath: String { rootPaths.first ?? NSHomeDirectory() }
    /// Every root of the active project, in the operator's declared order — what the git
    /// pane lists and the watcher watches (3a-i). Set by `refreshContext` from the same
    /// `get_context` answer `rootPath` always rode on, and cleared with it.
    ///
    /// The initialiser seeds it with the one `rootPath` it is handed, so a window keeps that
    /// launch directory until its first context read. That seed can be the home directory
    /// standing in for "no root", which is why git reads `gitRootPaths`, never this.
    public private(set) var rootPaths: [String]
    /// The roots git may read (the window's status, the editor's git actions): `rootPaths` when
    /// the last context read gave this window a project root, and none otherwise — never the
    /// home directory `rootPath` falls back to.
    public var gitRootPaths: [String] { hasProjectRoot ? rootPaths : [] }
    /// Keeps the window's git status live (3a-i; 3b-iii: while an editor pane is open). Started
    /// when an editor pane is open and the project has a root, restarted when the roots change,
    /// stopped when the last editor pane closes or the organisation changes — all in
    /// `syncGitWatcher`. Nil only in tests that show no git; production passes the wiring's
    /// (`WindowSession.start`), and the initialiser it calls has no default for it (`wakil-never-wired-parameters`). The chaining and the
    /// roots it watches live in `GitRootWatcher`.
    private let gitWatcher: GitRootWatcher?
    /// Keeps open editor panes' files current (3b-i): the project's roots are watched while an
    /// editor pane is open, and a change dispatches `editor_refresh` (`syncEditorWatcher`).
    /// `GitRootWatcher` is only the chained sync wrapper; nothing in it is git-specific.
    private let editorWatcher: GitRootWatcher?
    /// The shared per-root file list (3b-i's ⌘P source and 3b-ii's trees read one list). Nil in tests
    /// that open no editor; production passes the wiring's, and the public initialiser has no default.
    /// Watched exactly while `editorWatcher` watches (`syncEditorWatcher`); a wake invalidates it.
    private let fileLists: EditorFileLists?
    /// The window's git status (3b-iii): one `git_status` per root per wake, shared by every pane that
    /// shows git. No default, for `rootWatcher`'s reason (`wakil-never-wired-parameters`): production
    /// passes `wiring.gitStatus`, the one the actions were registered with; a test that shows no git
    /// says `nil` out loud.
    let gitStatus: GitStatus?
    /// 3a-ii. The Changes view's state, per root, for the window's life only (R3: nothing persists).
    /// The message being typed; absent is empty.
    public internal(set) var changesMessages: [String: String] = [:]
    /// Messages committed, newest first, at most `changesHistoryLimit`.
    public internal(set) var changesHistory: [String: [String]] = [:]
    /// Where ↑/↓ stands in `changesHistory`; nil once the box was typed in.
    var changesHistoryCursor: [String: Int] = [:]
    /// The last write's error in that root, whole (Rule 8); cleared by the next write that succeeds.
    public internal(set) var changesErrors: [String: String] = [:]
    /// Roots with a write running from this window.
    public internal(set) var changesInFlight: Set<String> = []
    /// Who a commit there would be authored as (`git_identity`).
    public internal(set) var changesIdentity: [String: (email: String, fromConfig: Bool)] = [:]
    /// The dispatch running per root, so a cancel can end it.
    var changesTasks: [String: Task<JSONValue, Error>] = [:]
    /// Bumped by an org switch: a write that lands under another generation is not shown.
    var changesGeneration = 0
    /// 3a-ii-b. Roots with a ✨ draft in flight, and the task each runs, so typing or ✕ can end it.
    public internal(set) var changesDrafting: Set<String> = []
    var changesDraftTasks: [String: Task<String, Error>] = [:]
    /// The last draft that landed, by any path (✨, the agent, voice): what it replaced, for the view's
    /// one ⌘Z (final review I4). `serial` tells two drafts with the same text apart.
    public internal(set) var changesLastDraft: ChangesDraftReplacement?
    /// 3a-iii-a: a quiet note per root from the last background fetch (shown on the root's header,
    /// never as an error); the fetch loop, its interval, its sleep (tests replace it), and whether the
    /// app is frontmost.
    public internal(set) var changesRemoteNotes: [String: String] = [:]
    /// 3a-iii-b: where the composed agent instructions go; the process's own unless a test swaps it.
    var agentInstructionsBox: AgentInstructionsBox = .shared
    public let backgroundFetchInterval: Duration = .seconds(300)
    var backgroundFetchSleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var backgroundFetchTask: Task<Void, Never>?
    /// How long one background fetch may take before it is given up: a host that never answers
    /// must not hold the root's write slot (review I5).
    var backgroundFetchTimeout: Duration = .seconds(60)
    /// The background fetch running now and its root, which an operator's write on that root cancels.
    var backgroundFetchCurrent: (root: String, cancel: () -> Void, done: Task<Void, Never>)?
    var appActive = true
    /// The status as last mirrored, for the views: the Changes view, the tree's letters, ⌘P.
    public private(set) var gitRoots: [GitRootState] = []
    /// What the trees draw: listings, loaded heavy folders, loads in flight. Mirrored on refreshPanes.
    public private(set) var editorFiles: EditorFileListsState = .empty
    /// The provider this window's session currently runs under, from
    /// `wakil-ctx`'s `get_context` (`ActiveContext.activeProvider`) at
    /// window-open. A session found under another provider cannot be
    /// resumed here (see `resume`), and saying which is why is 2b-vi's
    /// hook. `var`, not `let`: Task 9's `setProvider` is what a live
    /// switch actually assigns it through, mid-session, with no relaunch.
    ///
    /// `public private(set)` since 2e (#270): the settings pane draws
    /// which account is RUNNING beside the rest of what it says about
    /// that account, and it lives in `WakilApp` rather than `WakilKit`.
    /// Still writable only here — `setProvider` remains the one path.
    public private(set) var providerId: String
    /// How many of a resumed session's transcript entries are rebuilt into
    /// `thoughts`. Passed straight through to `read_session`'s `limit`, so
    /// the app and the Go read agree on how much of a long session's
    /// history is worth keeping.
    public static let rebuiltThreadLimit = 200
    /// Where a refused mutation waits for this operator. Shared with the
    /// agent's path (`MCPServer`, via `WakilWiring.confirmations`) — one
    /// confirmation mechanism, not two, for both origins.
    private let confirmations: ConfirmationBroker
    private var confirmationPump: Task<Void, Never>?
    /// Re-reads `tables` and `layoutSnapshot` after any dispatch that ran,
    /// whoever made it. Started in `init` for the same reason
    /// `confirmationPump` is: the agent can act before the operator has
    /// touched anything, and a change nobody re-read is a change nobody can
    /// see. See `ActionRegistry.dispatches()` for the whole reasoning.
    private var observationPump: Task<Void, Never>?
    /// Re-reads panes when an api send STARTS or ENDS (W14, preflight F1). `observationPump`
    /// wakes when a dispatch finishes, and a send's flight is the whole of its own dispatch, so
    /// without this Send could never read Cancel, from either channel.
    private var flightPump: Task<Void, Never>?
    /// Redraws an editor pane while its search, folder load or roots' listing is in flight (final
    /// review C1), for `flightPump`'s reason: each of those awaits inside its own dispatch.
    private var editorFlightPump: Task<Void, Never>?
    /// Mirrors the file lists whenever they change: a root listed, a folder loading or loaded.
    private var editorFilesPump: Task<Void, Never>?
    /// The scope `LayoutStore` is currently showing, or `nil` before the
    /// first `refreshContext()`. Compared against the scope `activateLayout`
    /// computes, so that a context refresh that changed nothing does no
    /// layout work at all.
    ///
    /// **`activateLayout` is the only place a scope is derived from the
    /// active context**, and everything else, `persistLayout` included,
    /// reads the answer from here. (`LayoutScope.initial` is the other
    /// value in the process, and it is a starting point rather than a
    /// derivation: both stores hold it before anything has told them what
    /// is active, and nothing writes it to disk.) One derivation is what
    /// keeps the three layers it keys from drifting; see `LayoutScope`.
    private var layoutScope: LayoutScope?
    /// The scope the active context names: the place — organisation, the project's **registry
    /// key** and the environment (Plan 3) — and the conversation. The one derivation
    /// `activateLayout` installs and the watchers compare against. Before Plan 3 it was built
    /// from the display name and carried no environment, so a switch of environment kept the
    /// canvas and refetched it (D11); staging and production are now two canvases.
    private var currentLayoutScope: LayoutScope {
        LayoutScope(
            organization: organization, project: projectKey, environment: environment,
            lineageRoot: lineageRoot ?? landingRoot(in: place))
    }
    /// The conversation whose canvas `place`'s Landing draws over after `newConversation`: the id
    /// it reserves for its next conversation, while `landingBaselines` holds the place and it
    /// shows none. Nil otherwise — the Landing at launch draws over the place's own canvas.
    private func landingRoot(in place: Place) -> String? {
        guard screenConversations[place] == nil, landingBaselines[place] != nil else { return nil }
        return reservedConversations[place]
    }
    /// Every scope whose saved layout has already been read this session.
    /// Separate from `layoutScope` because they answer different
    /// questions: that one is "which arrangement is on screen", this one
    /// is "which have been read from disk", and only the second may never
    /// be re-answered. See `activateLayout`.
    private var loadedLayoutScopes: Set<LayoutScope> = []
    /// Scopes read off disk while off screen (`followConversation`), whose panes' contents are
    /// re-run when the operator first comes back to them.
    private var scopesAwaitingRestore: Set<LayoutScope> = []
    /// The note an off-screen read gave with the arrangement it did read (a stale pane kind
    /// dropped), said in `status` when the operator first comes back to that scope, as an
    /// on-screen read says it (final review minor 6).
    private var layoutNotesAwaitingReturn: [LayoutScope: String] = [:]
    /// The arrangement last written for each place off screen (`persistBackgroundLayouts`), so
    /// only a change costs a file.
    private var backgroundLayouts: [LayoutScope: LayoutSnapshot] = [:]
    /// True from the moment `activateLayout` points the stores at the
    /// incoming scope until the arrangement that belongs to it is in hand.
    ///
    /// **It describes the swap, not either side of it**, which is why
    /// `invalidateForOrgChange()` never touches it — the same shape
    /// `switching` already has. An organisation
    /// switch does of course raise and clear it, by way of the
    /// `activateLayout` that follows: it is the swap's own flag, and an
    /// org switch is a swap like any other.
    ///
    /// **What it stops is a write of a canvas that belongs to nobody.**
    /// Switching scope takes two actor hops (`LayoutStore` and
    /// `PaneStore`) and a file read, and between the first of those and
    /// the read the store answers with an EMPTY arrangement filed under
    /// the incoming scope — a scope that has not been restored yet.
    /// `refreshLayout` runs off the back of every dispatch the
    /// observation pump sees, including the `session_record_parent` that
    /// `resume` itself makes, so it lands in exactly that window: it
    /// compared the outgoing conversation's panes against that empty
    /// canvas, called it a change, and wrote it. Measured, not reasoned
    /// about — switching to a conversation with no arrangement of its own
    /// wrote an empty file for it AND, because a conversation's save
    /// refreshes the project's seed, emptied the seed every later
    /// conversation opens on. The arrangement the operator had was gone
    /// from disk before the read that was meant to restore it ran.
    ///
    /// Not a lock and not a queue: the window it covers is one
    /// `activateLayout` opens and closes itself, under the mutual
    /// exclusion its own scope guard already provides, and the only thing
    /// it suppresses is a commit. A change dispatched inside the window
    /// still lands in the store — but the store is already pointed at the
    /// incoming scope, so it lands there, which is a narrower and older
    /// hazard than the one this closes and is not made worse by it.
    private var layoutSwapInFlight = false
    /// Callers that asked for the scope a swap had already claimed, resumed
    /// when that swap has finished (`activateLayout`, #328).
    private var layoutSwapWaiters: [CheckedContinuation<Void, Never>] = []
    /// From a swap's claim to its last line — wider than `layoutSwapInFlight`,
    /// which ends before the panes' contents are re-run.
    private var layoutActivating = false
    /// The most recently started layout write, or `nil` if none has been.
    /// Each new write awaits it, which is what orders them; see
    /// `persistLayout`. It carries the failure note rather than throwing,
    /// so that a write which fails does not cancel the one chained behind
    /// it.
    private var pendingSave: Task<String?, Never>?
    /// The id the on-screen place's agent session was started under, or `nil` before its
    /// first `send`. Per spec §3.3 a session starts fresh and keeps one id; the second and later
    /// `send` calls reuse it rather than starting another session.
    var sessionId: String? { currentAgent?.sessionId }

    /// - Parameters:
    ///   - confirmations: Where this window's own refused mutations park —
    ///     see the property's doc comment. Defaults to a fresh broker of
    ///     its own so that every existing `WindowModel(...)` call site (24
    ///     of them in `WindowModelTests`, none of which exercise
    ///     confirmation) keeps compiling unchanged. Production has exactly
    ///     one call site, `WindowSession.start`, and it always passes
    ///     `wiring.confirmations` explicitly: a window with its own private
    ///     broker there would mean the agent's proposals — parked in
    ///     `wiring.confirmations` by `MCPServer` — never reach this
    ///     window's plane at all.
    ///   - environment: Overrides `environment`'s initial value, rather
    ///     than requiring `refreshContext()` to run first. No default —
    ///     see why below — so every real call site reaches this window
    ///     through the `public` convenience initialiser instead, which
    ///     does not declare this parameter at all and always passes `""`,
    ///     learning the real value from `wakil-ctx` exactly as before. A
    ///     test that only cares whether the write gate treats `"staging"`
    ///     or `"production"` as the target has no `wakil-ctx` process to
    ///     ask, and this stands in for one without spinning up a real
    ///     binary just to name a string.
    ///
    ///     Deliberately not `public`, and deliberately not defaulted:
    ///     `WindowModelTests` uses `@testable import WakilKit`, which
    ///     elevates `internal` to accessible, so this access level buys
    ///     the identical test seam with zero public API widening — and
    ///     the missing default is what keeps a call site that omits both
    ///     this parameter and `environment:`'s label from being ambiguous
    ///     between this initialiser and the convenience one below: with a
    ///     default here, both would apply to the same call and neither
    ///     would win.
    ///
    /// **The true designated initialiser as of 2b-viii.** `harnessFactory`
    /// and `lookupFactory` are both org-aware here — see their own doc
    /// comments — which is new; everything else is unchanged from before
    /// 2b-viii. The two convenience initialisers below adapt the
    /// pre-2b-viii (org-oblivious) shape onto this one, which is what lets
    /// every one of `WindowModelTests`' 71 existing `WindowModel(...)`
    /// call sites keep compiling unchanged.
    init(
        registry: ActionRegistry,
        panes: PaneStore,
        layout: LayoutStore,
        persistence: LayoutPersistence? = nil,
        context: ContextStore?,
        harnessFactory: @escaping @Sendable (Place, ProviderSelection, String) -> AgentHarness?,
        resumes: ResumeBroker,
        rootPath: String,
        providerId: String,
        lookupFactory: @escaping @Sendable (String) -> ProviderCredentialsLookup,
        confirmations: ConfirmationBroker = ConfirmationBroker(),
        // Defaulted to a store of its own, holding no shells and paired
        // with no `PaneStore`, for the identical reason `confirmations`
        // above is: it keeps every existing `WindowModel(...)` call site —
        // none of which opens a terminal pane — compiling and behaving
        // unchanged. Production (`WindowSession.start`) always passes
        // `wiring.terminals` explicitly, the same instance
        // `WakilWiring.build` registered `term_open`/`term_propose`/
        // `term_run` against.
        terminals: TerminalStore = TerminalStore(),
        // Defaulted for the identical reason `confirmations` above is: it
        // keeps every existing `WindowModel(...)` call site in
        // `WindowModelTests` — none of which dispatches
        // `session_set_provider` — compiling unchanged. Production
        // (`WindowSession.start`) always passes `wiring.providerSwitches`
        // explicitly, the same way it already does for `resumes`.
        providerSwitches: ProviderSwitchBroker = ProviderSwitchBroker(),
        // Conversations 2 of 3. Defaulted for `providerSwitches`' reason; production passes
        // `wiring.conversationRequests`.
        conversationRequests: ConversationBroker = ConversationBroker(),
        // Defaulted so every pre-2b-viii call site — real and test —
        // keeps compiling unchanged; a switch that never fires is exactly
        // as capable as none of them exercising a live org switch was
        // before this task. Production (`WindowSession.start`) always
        // passes `wiring.switchOrg(to:)` explicitly, through the
        // `lookupFactory:`-labelled convenience initialiser below.
        orgSwitcher: @escaping @Sendable (String) async -> [String] = { _ in [] },
        // 2e (#202). Defaulted to the real kind-keyed picker for the same
        // reason `confirmations` and `terminals` above are defaulted: it
        // keeps every existing call site compiling unchanged. A test that
        // drives the login states passes a factory returning a fake
        // conformance, which is what keeps a browser out of the suite —
        // the same injected-factory shape `lookupFactory` already
        // established.
        providerLoginFactory: @escaping @Sendable (String) throws -> any ProviderLogin
            = { try makeProviderLogin(forKind: $0) },
        // The agent binary a login is spawned as. Empty means the one on
        // PATH, which is what an operator adding their FIRST account has:
        // there is no record to read a path from yet, because no record
        // exists until the mint succeeds.
        providerLoginBinary: String = "",
        // 2e (#204). The mint is a SPAWN, not a dispatch, for the same
        // three reasons the credential read has always been one — see
        // `ProviderMinting`. A FACTORY over the organisation rather than
        // an instance — see the property's doc comment. Defaulted to nil
        // so every existing call site compiles unchanged; a window with
        // no minter cannot add an account, which is exactly what a test
        // that does not exercise one wants.
        providerMintFactory: (@Sendable (String) -> any ProviderMinting)? = nil,
        claudeLocator: ClaudeExecutableLocator? = nil,
        // 9b W1. Defaulted to nil for `providerMintFactory`'s reason: a window with no resolver
        // re-resolves no api pane, which is what a test that opens none wants.
        apiResolver: ApiPaneResolver? = nil,
        // 2d-i. Defaulted to nil for the same reason: a window with no store
        // sends every turn exactly as typed.
        vocabulary: VocabularyStore? = nil,
        // 3a-i. Defaulted to nil here for the same reason; the public initialiser production
        // calls takes it with no default.
        rootWatcher: (any RootWatcher)? = nil,
        // 3b-i. Defaulted to nil here for `rootWatcher`'s reason; the public initialiser
        // production calls takes it with no default.
        editorRootWatcher: (any RootWatcher)? = nil,
        // 3b-ii. Defaulted to nil here for `rootWatcher`'s reason; the public initialiser
        // production calls takes it with no default.
        fileLists: EditorFileLists? = nil,
        // 3b-iii. Defaulted to nil here for `rootWatcher`'s reason; the public initialiser
        // production calls takes it with no default.
        gitStatus: GitStatus? = nil,
        // The palette's direct reads. Defaulted to none here for `rootWatcher`'s reason; the
        // public initialiser production calls takes it with no default.
        paletteClients: PaletteClients = PaletteClients(),
        // Background agents, 2 of 4. Defaulted to nil here for `rootWatcher`'s reason; the
        // public initialiser production calls takes it with no default.
        placeClients: PlaceClients? = nil,
        // Background agents, 3 of 4 (Task 4). Defaulted to no socket here for `rootWatcher`'s
        // reason; the public initialiser production calls takes it with no default.
        agentSocketFactory: @escaping AgentSocketFactory = { _, _ in NoAgentSocket() },
        // 3b-viii. Record and organisation in, a quick model out. Defaulted to nil: a window with no
        // factory answers no ghost request, which is what a test that asks none wants.
        quickModelFactory: (@Sendable (QuickProviderRecord, String) async throws -> (any QuickModel)?)? = nil,
        environment: String
    ) {
        self.registry = registry
        self.quickModelFactory = quickModelFactory
        self.agentSocketFactory = agentSocketFactory
        self.placeClients = placeClients
        self.placeContexts = placeClients.map { PlaceContexts(clients: $0) }
        self.paletteClients = paletteClients
        self.vocabulary = vocabulary
        self.panes = panes
        self.layout = layout
        self.capacity = CapacityFeed()
        self.terminals = terminals
        self.persistence = persistence
        self.context = context
        self.harnessFactory = harnessFactory
        self.resumes = resumes
        self.providerSwitches = providerSwitches
        self.conversationRequests = conversationRequests
        self.orgSwitcher = orgSwitcher
        self.providerLoginFactory = providerLoginFactory
        self.claude = ClaudeLocator(locator: claudeLocator, injected: providerLoginBinary)
        self.providerMintFactory = providerMintFactory
        self.apiResolver = apiResolver
        self.rootPaths = [rootPath]
        self.gitWatcher = rootWatcher.map { GitRootWatcher(watcher: $0) }
        self.editorWatcher = editorRootWatcher.map { GitRootWatcher(watcher: $0) }
        self.fileLists = fileLists
        self.gitStatus = gitStatus
        self.providerId = providerId
        self.lookupFactory = lookupFactory
        // `organization` is still `""` at this point — it is learned
        // asynchronously from `wakil-ctx` by `refreshContext()`, called
        // after this initialiser returns (see that property's own doc
        // comment) — so this is the placeholder lookup every window
        // starts with, and it is the ONLY lookup an org-less window ever
        // has. **`refreshContext()` is what replaces it**, in the same
        // breath as it learns the org — at launch and on every refresh —
        // and `setOrganization` rebuilds it again from the org it just
        // switched to, so the rebuild does not depend on that refresh
        // succeeding. `invalidateForOrgChange()` resets it *back* to this
        // same org-less placeholder mid-switch; it is a teardown, not the
        // rebuild (final fix pass, Critical 1: this comment used to name
        // it as the rebuild, and nothing else did the rebuilding at all,
        // so every window shelled out to `wakil --org "" …` for its
        // credentials and no agent session could start). Literal
        // `""` rather than reading `self.organization`: `@Observable`
        // routes every property read through a macro-generated accessor,
        // and the compiler rejects any such read on `self` before every
        // stored property (`_organization` included) is initialized —
        // `organization`'s value at this exact point is always `""`
        // anyway, so this reads identically without tripping that rule.
        self.lookup = lookupFactory("")
        self.confirmations = confirmations
        self.environment = environment

        // Started here, unconditionally, rather than lazily like
        // `eventPump`: the operator's own mutation can park before `send`
        // is ever called, and the plane must be able to show it from the
        // window's first frame.
        confirmationPump = Task { [weak self, confirmations] in
            // `updates()` yields at subscribe time only when something is
            // already parked — it does not replay an initial `nil` (Task
            // 8's review finding). So this subscriber clears any stale
            // `pending` itself; otherwise a re-subscribe while holding a
            // stale `parkedSlots` would never be told to clear it.
            // Safe unforced here even though `self` is weak: this task is
            // created from inside `self`'s own `init`, so `self` cannot
            // have deallocated yet.
            self?.parkedSlots = [:]
            for await parked in await confirmations.slotUpdates() {
                // Re-checked on every iteration, like `eventPump` below —
                // `updates()` never terminates on its own, so hoisting a
                // `guard let self` above this loop (checked once) would
                // keep `self` strong for the model's entire lifetime, and
                // the model → task → model cycle would break only by hand,
                // in `shutdown()`.
                guard let self else { return }
                self.parkedSlots = parked
                for slot in parked.keys {
                    let agent = slot.conversation.flatMap(self.conversation(id:)) ?? self.agents[slot.place]
                    if let agent { self.refreshChipProduction(of: agent) }
                }
            }
        }

        // The same shape as `confirmationPump` above, for the same
        // reason one iteration down: a dispatch the window did not make —
        // an agent's `tools/call`, or `--dispatch` — changes `PaneStore`
        // and `LayoutStore` with nothing on screen re-reading them, so
        // until this existed an agent's selection was invisible until the
        // operator happened to click (final review Finding 3).
        //
        // **Not a poll.** It waits on `dispatches()` and does exactly one
        // pass per dispatch that ran; between dispatches it costs nothing
        // at all, which a timer checking every frame would not.
        //
        // **Refreshing twice is cheaper than deciding not to.** The
        // window's own paths (`dispatchFromSurface`, `dispatchLayout`,
        // `runQuery`) still refresh inline, because they must have the new
        // state before their next statement — `dispatchLayout` compares
        // the snapshot to decide whether to write the layout file — and
        // this pump then refreshes the same values again. Both reads are
        // of an in-memory actor, and a rule for suppressing one of them
        // would be a second place the answer to "is the screen current?"
        // is decided.
        flightPump = Task { [weak self, panes] in
            for await _ in await panes.apiFlights() {
                // Re-checked every iteration, as `observationPump` does below.
                guard let self else { return }
                await self.refreshPanes()
            }
        }

        editorFlightPump = Task { [weak self, panes] in
            for await _ in await panes.editorChanges() {
                guard let self else { return }
                await self.refreshPanes()
            }
        }
        if let fileLists {
            editorFilesPump = Task { [weak self] in
                for await _ in await fileLists.changes() {
                    guard let self else { return }
                    await self.mirrorEditorFiles()
                }
            }
        }

        observationPump = Task { [weak self, registry] in
            for await name in await registry.dispatches() {
                // Re-checked every iteration, like the pumps above:
                // `dispatches()` never finishes on its own, so hoisting
                // the unwrap would hold `self` for the model's whole life.
                guard let self else { return }
                // **A backstop for a context switch the setters did not make.**
                // The operator's switches go through `setEnvironment` and
                // `setProject`, which refresh by hand, and the agent can no
                // longer make one at all: `ctx_set_environment` and
                // `ctx_set_project` are operator-only, because an agent's
                // place is fixed when its session starts (Invariant 5). These
                // branches were written for the agent's switch, when it could
                // make one; they stay so that any dispatch reaching the
                // registry by another route still leaves the panes, the
                // banner and `environment` naming the place actually active,
                // and the gate reading the active project's production flags
                // (#182) rather than the previous project's.
                if name == "ctx_set_environment" {
                    // Fix round 1, item 5: the operator's own switch is seen here too, and
                    // `setEnvironment` is already handling it. Wait for it to finish, THEN
                    // refresh: the operator's switch reads as a no-op and is not done twice,
                    // while a switch from any other route that landed meanwhile still shows.
                    _ = await self.operatorEnvironmentSwitch?.value
                    // Such a switch does what the operator's does (Plan 3): the environment's
                    // own canvas comes in through `activateLayout`, and nothing is cleared or
                    // re-run. A switch to the active environment (W12) names the scope already
                    // installed, which `activateLayout` leaves alone.
                    await self.refreshContext()
                }
                // **`ctx_set_project` refreshes and does NOT restore**, which
                // is exactly what the operator's `setProject` does — it calls
                // `refreshContext()` alone, as `setEnvironment` now does too.
                // The branch above exists to make any other route do what the
                // operator's does; doing MORE here would be this pump
                // inventing a pane policy for project switches that the UI
                // path does not have, and #179 lists pane restoration on a
                // project switch as out of scope.
                if name == "ctx_set_project" {
                    await self.refreshContext()
                }
                // Task 15: an agent-issued `term_open` never goes through
                // `openTerminalForTesting` (test-only) or any operator UI
                // path either — it lands here, like `ctx_set_environment`
                // above, as a dispatch this window did not itself make.
                // Without this branch a pane the agent opened stayed empty
                // until its next `Bash` call, which is exactly the
                // "starting empty" the backfill requirement exists to
                // avoid.
                if name == "term_open" {
                    await self.backfillTerminals()
                }
                // A database added or removed changes the environment's list, which was read only
                // on a context change: the query line's chooser and the fast path's scope missed
                // a database added since (3b-ix e2e).
                if name == "db_set_dsn" || name == "db_remove_database" || name == "db_update_database"
                    || name == "db_set_connection" {
                    await self.refreshDatabases()
                }
                // **An agent's settings write, and the pane it lands under.**
                // Every operator edit goes through a wrapper here that calls
                // `refreshSettings()` after it (`setDatabaseDSN`,
                // `saveOrganisationField`, …). The agent's same write reaches
                // `dispatch` straight from the socket and never passes one,
                // so it landed on disk and an open pane kept drawing the read
                // before it — measured by `2e-settings-databases-dispatch`
                // against the shipped bundle. "Caches nothing" was true and
                // the screen was still stale: nothing asked it to read.
                //
                // **Only while the pane is open, and only for a write to what
                // it draws.** A refresh re-reads the account table too, which
                // is a Keychain lookup and a CLI spawn per row, and a
                // `pane_resize` has no business paying that. The two reads
                // `refreshSettings` itself dispatches are `.read`, so this
                // cannot wake itself.
                if self.layoutSnapshot.panes.contains(where: { $0.kind == Pane.settingsKind }),
                   await self.writesSettings(name) {
                    await self.refreshSettings()
                }
                await self.refreshPanes()
                await self.refreshLayout()
                await self.persistBackgroundLayouts()
                // **A canvas with something on it is work begun. #264.**
                //
                // The Landing draws while `!sessionStarted`, and
                // `markSessionStarted()` is reached from `enterConversation()`
                // and `resume()` — every entrance the WINDOW has into work. A
                // dispatch over the MCP socket goes through none of them: it
                // reaches `ActionRegistry.dispatch` and the handler directly,
                // writes `LayoutStore`, and returns. So the agent could open a
                // pane with a live shell on a real pty while the window kept
                // drawing the Landing over it — measured against the shipped
                // bundle, `read_layout` answering with `terminal-1` focused
                // and the tree holding no rail at all. It is Invariant 2 with
                // the two paths reaching the same store and only one of them
                // the same window.
                //
                // **Read off the canvas rather than matched on action names.**
                // The set that arranges something is not fixed — `pane_open`,
                // `term_open`, `api_open`, a `db_*` that opens its own pane,
                // and whatever is registered next — and a list here would go
                // stale silently, which is the failure being fixed. The
                // condition the Landing is actually wrong about is that there
                // are panes, so that is what is asked.
                //
                // **It only ever sets.** Closing the last pane returns to the
                // room, not to the Landing: the axis is the session, and
                // nothing clears this in-window (see `sessionStarted`).
                //
                // **Only while the canvas drawn is the place's own.** An org switch names the
                // incoming place (`refreshContext`) a few suspensions before `activateLayout`
                // brings in its canvas, and a dispatch finishing in that gap found the outgoing
                // canvas's panes here and marked work begun in a place that has none — so the
                // incoming organisation lost its Landing. Asked of the store's screen, not
                // `layoutScope`: that is nil both before any arrangement and on a no-project
                // canvas, which is `bareScope`.
                let shownScope = await self.panes.screenScope
                let canvasIsThePlaces = !self.layoutSwapInFlight
                    && shownScope == (self.projectKey.isEmpty ? self.bareScope : self.currentLayoutScope)
                // **After `newConversation`, only a pane the seed did not bring** (ruling 1): the
                // Landing draws over the reserved conversation's canvas, read from the seed,
                // which almost always has panes.
                let baseline = self.landingBaselines[self.place] ?? []
                if canvasIsThePlaces, !self.sessionStarted, !self.landingsLoading.contains(self.place),
                   self.layoutSnapshot.panes.contains(where: { !baseline.contains($0.id) }) {
                    self.showTheWorkAlreadyOnTheCanvas()
                }
            }
        }

        // Subscribed in `init`, not lazily: a resume can be dispatched by
        // the agent or by `--dispatch` before this window has ever sent
        // anything, and a request parked into a broker nobody is draining
        // is a request that silently never happens.
        resumePump = Task { [weak self, resumes] in
            for await request in await resumes.requests() {
                guard let self else { return }
                await self.resume(
                    sessionId: request.sessionId, in: request.place, conversation: request.conversation)
            }
        }

        // Subscribed in `init` for the identical reason `resumePump`
        // above is: `session_set_provider` can be dispatched by
        // `--dispatch` or from ⌘K before this window has ever sent
        // anything, and a request parked into a broker nobody is
        // draining is a request that silently never happens. (The agent
        // cannot reach this path at all — see `operatorOnlyActions` in
        // `PermissionPrompt.swift` — so in practice every request this
        // drains is `origin: .ui`.)
        providerSwitchPump = Task { [weak self, providerSwitches] in
            for await request in await providerSwitches.requests() {
                guard let self else { return }
                await self.setProvider(request.providerId)
            }
        }

        // Subscribed in `init` for `resumePump`'s reason: `session_new` and `session_switch`
        // can be dispatched from ⌘K or `--dispatch` before this window has sent anything.
        conversationPump = Task { [weak self, conversationRequests] in
            for await request in await conversationRequests.requests() {
                guard let self else { return }
                switch request {
                case .new(let conversation):
                    await self.newConversation(conversation)
                case .switchTo(let conversation, let place):
                    await self.switchToConversation(conversation, in: place)
                case .close(let conversation):
                    await self.closeConversation(conversation)
                }
            }
        }

        // Subscribed in `init`, unconditionally, like `confirmationPump`
        // above: a terminal pane can seal a block — the operator's own
        // typed command, or `--dispatch` driving the same action set —
        // before this window has sent anything of its own, and a run
        // nobody is draining `completedRuns()` for is a run that is never
        // journalled. `completedRuns()` itself is safe to call this early:
        // it only replaces `TerminalStore`'s stored continuation, and does
        // not require a pane to already be open.
        terminalRunPump = Task { [weak self, terminals] in
            for await run in await terminals.completedRuns() {
                guard let self else { return }
                await self.journalTerminalRun(run)
            }
        }

        capacity.attach { [weak self] name, params in
            guard let self else { return .null }
            return try await self.registry.dispatch(name: name, params: params, origin: .ui,
                                                    caller: DispatchCaller(place: self.place, session: nil), confirmation: nil)
        }

        // The gate prices an agent caller by its own place's flags. Only with a pool to read them
        // through; without one every caller is judged by `refreshContext`'s, as before. The
        // operator's dispatches never hop here: they take the window's flags.
        if placeContexts != nil {
            registry.setProductionLookup { [weak self] caller in
                guard pinnedPlace(of: caller) != nil else { return nil }
                return await self?.productionFlags(forCaller: caller)
            }
        }

        // The trees draw the place on screen: an agent session pinned to it lists into them.
        fileLists?.setScreenPlace { [weak self] in await self?.place }

        // Background agents 3 of 4: an agent's dispatch reads and writes its own place's canvas
        // (`ScopeRouting.home`), wherever the screen is; everything else is homed on the screen
        // it began on.
        // Conversations 3 of 3: a session of a conversation since closed acts for nothing.
        registry.setCallerRefusal { [weak self] action, caller in
            await self?.closedConversationRefusal(action, caller)
        }
        registry.setScopeLookup { [weak self] caller in
            guard pinnedPlace(of: caller) != nil else { return nil }
            return await self?.agentScope(for: caller)
        }
        registry.setScreenScope { [panes] in await panes.activeScope }
    }

    /// The scope an agent session works in: its own conversation's — named by the caller, so a
    /// late call from a session since replaced still reaches it — else its place's agent's, or
    /// the place's own canvas before it has one. Never nil, so an agent is never homed on the screen's
    /// canvas by default — a place's pane must not land in another place's. A place with no
    /// project has no conversation's arrangement (`PlaceAgent.layoutScope`), so its agent works
    /// in its organisation's own canvas, with project and environment empty (final review C1).
    ///
    /// **A caller that names its conversation gets that one's, or none** (conversations 3 of 3):
    /// never the place's other conversation's. Only a caller that names none falls back to the
    /// place's agent. One naming a conversation no longer live is refused before it gets here
    /// (`closedConversationRefusal`); one naming its Landing's reserved id gets the place's canvas.
    private func agentScope(for caller: DispatchCaller) -> LayoutScope {
        let place = caller.place
        let agent = caller.conversation.map { conversations[$0] } ?? agents[place]
        return agent?.layoutScope
            ?? LayoutScope(
                organization: place.organization, project: place.project, environment: place.environment,
                lineageRoot: landingRoot(in: place))
    }

    /// Adapts the pre-2b-viii (org-oblivious) initialiser shape onto the
    /// designated one above, for `WindowModelTests` call sites that pass
    /// `environment:` explicitly — reachable only because `@testable
    /// import WakilKit` elevates `internal` to visible there, exactly like
    /// the designated initialiser itself before 2b-viii. Not `public`: no
    /// real call site needs to fix `environment` to anything but `""` at
    /// construction (see that property's own doc comment), so the two
    /// `public` convenience initialisers below never expose it.
    ///
    /// `harnessFactory` and `lookup` here ignore the org they are handed —
    /// wrapped into the designated initialiser's org-aware shape by
    /// discarding the first parameter — which is correct for every one of
    /// this file's call sites: none of them exercises a live org switch,
    /// so a harness factory or lookup that cannot tell which org it is
    /// building for is exactly as capable as the pre-2b-viii ones were.
    convenience init(
        registry: ActionRegistry,
        panes: PaneStore,
        layout: LayoutStore,
        persistence: LayoutPersistence? = nil,
        context: ContextStore?,
        harnessFactory: @escaping @Sendable (ProviderSelection) -> AgentHarness?,
        resumes: ResumeBroker,
        rootPath: String,
        providerId: String,
        lookup: ProviderCredentialsLookup,
        confirmations: ConfirmationBroker = ConfirmationBroker(),
        providerSwitches: ProviderSwitchBroker = ProviderSwitchBroker(),
        terminals: TerminalStore = TerminalStore(),
        environment: String
    ) {
        self.init(
            registry: registry, panes: panes, layout: layout, persistence: persistence,
            context: context,
            harnessFactory: { _, selection, _ in harnessFactory(selection) },
            resumes: resumes, rootPath: rootPath, providerId: providerId,
            lookupFactory: { _ in lookup },
            confirmations: confirmations,
            terminals: terminals, providerSwitches: providerSwitches,
            environment: environment)
    }

    /// The pre-2b-viii shape, kept `public` and unchanged so every one of
    /// `WindowModelTests`' (and `StandardActionsTests`', and
    /// `ProviderSwitchTests`') 71 existing `WindowModel(...)` call sites
    /// keeps compiling exactly as written — see the internal convenience
    /// initialiser just above for how `harnessFactory`/`lookup` adapt onto
    /// the org-aware designated one. `environment` always starts `""`
    /// here — see that property's own doc comment — and is learned from
    /// `wakil-ctx` by `refreshContext()`.
    public convenience init(
        registry: ActionRegistry,
        panes: PaneStore,
        layout: LayoutStore,
        persistence: LayoutPersistence? = nil,
        context: ContextStore?,
        harnessFactory: @escaping @Sendable (ProviderSelection) -> AgentHarness?,
        resumes: ResumeBroker,
        rootPath: String,
        providerId: String,
        lookup: ProviderCredentialsLookup,
        confirmations: ConfirmationBroker = ConfirmationBroker(),
        providerSwitches: ProviderSwitchBroker = ProviderSwitchBroker(),
        terminals: TerminalStore = TerminalStore()
    ) {
        self.init(
            registry: registry, panes: panes, layout: layout, persistence: persistence,
            context: context, harnessFactory: harnessFactory,
            resumes: resumes, rootPath: rootPath, providerId: providerId,
            lookup: lookup, confirmations: confirmations,
            providerSwitches: providerSwitches,
            terminals: terminals,
            environment: "")
    }

    /// The org-aware shape, added by 2b-viii for `WindowSession.start` —
    /// the one production call site that needs `harnessFactory` and the
    /// credentials lookup to react to a live org switch rather than the
    /// org the window happened to open with. Distinguished from the
    /// `public` initialiser above by argument labels alone
    /// (`lookupFactory:` vs. `lookup:`, and `harnessFactory`'s own arity),
    /// so both stay callable with no ambiguity.
    public convenience init(
        registry: ActionRegistry,
        panes: PaneStore,
        layout: LayoutStore,
        persistence: LayoutPersistence? = nil,
        context: ContextStore?,
        harnessFactory: @escaping @Sendable (Place, ProviderSelection, String) -> AgentHarness?,
        resumes: ResumeBroker,
        rootPath: String,
        providerId: String,
        lookupFactory: @escaping @Sendable (String) -> ProviderCredentialsLookup,
        confirmations: ConfirmationBroker = ConfirmationBroker(),
        providerSwitches: ProviderSwitchBroker = ProviderSwitchBroker(),
        // Conversations 2 of 3. Production (`WindowSession.start`) passes
        // `wiring.conversationRequests`.
        conversationRequests: ConversationBroker = ConversationBroker(),
        // Defaulted for the same reason `confirmations`/`providerSwitches`
        // above are: it keeps every call site that predates Task 10
        // compiling unchanged. `WindowSession.start` (Task 10) is the one
        // production call site that passes this explicitly —
        // `WakilWiring.switchOrg(to:)` wrapped in a closure.
        orgSwitcher: @escaping @Sendable (String) async -> [String] = { _ in [] },
        // Defaulted for the same reason, added by Task 11:
        // `WindowSession.start` passes `wiring.terminals` explicitly —
        // the same instance `WakilWiring.build` registered
        // `term_open`/`term_propose`/`term_run` against — and
        // `WindowModel.forTesting` builds and passes its own.
        terminals: TerminalStore = TerminalStore(),
        // 2e (#204). The minter has to travel THROUGH this initialiser,
        // because this is the one production call site that builds a
        // window (`WindowSession.start`) and the designated initialiser
        // is not `public`. Defaulted to nil for the same reason every
        // parameter above it is: a window with no minter cannot add an
        // account, which is what a test that does not exercise one wants.
        providerMintFactory: (@Sendable (String) -> any ProviderMinting)? = nil,
        // #322. Defaulted to nil for the same reason: no test spawns the
        // operator's login shell unless it asks to.
        claudeLocator: ClaudeExecutableLocator? = nil,
        // 9b W1. The resolver travels through here for the minter's reason: this is the one
        // production call site (`WindowSession.start`). Defaulted to nil for the same reason.
        apiResolver: ApiPaneResolver? = nil,
        // 2d-i. Travels through here for the same reason; production passes
        // `wiring.vocabulary`.
        vocabulary: VocabularyStore? = nil,
        // 3a-i. **No default, unlike everything above it.** Each of those parameters
        // defaulted to nil and went unpassed at least once, and only running the app found
        // it (`wakil-never-wired-parameters`); a git status with no watcher would simply never
        // update, with nothing failing. Production passes `wiring.rootWatcher`; a test that
        // shows no git says `nil` out loud.
        rootWatcher: (any RootWatcher)?,
        // 3b-i. No default, for `rootWatcher`'s reason: an editor with no watcher never
        // notices a change on disk, with nothing failing. Production passes
        // `wiring.editorRootWatcher`; a test that opens no editor says `nil` out loud.
        editorRootWatcher: (any RootWatcher)?,
        // 3b-ii. No default, for `rootWatcher`'s reason: an editor with no list draws a tree
        // that never lists, with nothing failing. Production passes `wiring.fileLists`; a test
        // that opens no editor says `nil` out loud.
        fileLists: EditorFileLists?,
        // 3b-iii. No default, for `rootWatcher`'s reason: a window with no status shows no git,
        // with nothing failing. Production passes `wiring.gitStatus`; a test that shows no git says
        // `nil` out loud.
        gitStatus: GitStatus?,
        // The palette's direct reads (`PaletteClients`). No default, for `rootWatcher`'s
        // reason: production passes the wiring's clients, and a test with no palette says
        // `PaletteClients()` out loud.
        paletteClients: PaletteClients,
        // Background agents, 2 of 4. No default, for `rootWatcher`'s reason: without it a
        // client pinned to a session's old place is never stopped, with nothing failing.
        // Production passes `wiring.placeClients`; a test that routes no call says `nil`.
        placeClients: PlaceClients?,
        // Background agents, 3 of 4 (Task 4). No default, for `rootWatcher`'s reason: without
        // it no agent reaches Wakil's own tools, with nothing failing. Production passes one
        // that starts an `MCPSocketServer`.
        agentSocketFactory: @escaping AgentSocketFactory,
        // 3b-viii. No default, for `rootWatcher`'s reason: without it no ghost request is ever
        // answered, with nothing failing. Production passes the factory `WindowSession.start` builds
        // beside `harnessFactory`; a test that asks none says `nil` out loud.
        quickModelFactory: (@Sendable (QuickProviderRecord, String) async throws -> (any QuickModel)?)?
    ) {
        self.init(
            registry: registry, panes: panes, layout: layout, persistence: persistence,
            context: context, harnessFactory: harnessFactory,
            resumes: resumes, rootPath: rootPath, providerId: providerId,
            lookupFactory: lookupFactory, confirmations: confirmations,
            terminals: terminals, providerSwitches: providerSwitches,
            conversationRequests: conversationRequests,
            orgSwitcher: orgSwitcher,
            providerMintFactory: providerMintFactory,
            claudeLocator: claudeLocator,
            apiResolver: apiResolver,
            vocabulary: vocabulary,
            rootWatcher: rootWatcher,
            editorRootWatcher: editorRootWatcher,
            fileLists: fileLists,
            gitStatus: gitStatus,
            paletteClients: paletteClients,
            placeClients: placeClients,
            agentSocketFactory: agentSocketFactory,
            quickModelFactory: quickModelFactory,
            environment: "")
    }

    /// TEST-ONLY. Builds a `WindowModel` with sensible defaults so a test
    /// that only cares about one or two knobs — the org-switch tests from
    /// Task 6 on — does not have to thread every `WindowModel.init`
    /// parameter through by hand. Reachable only via `@testable import
    /// WakilKit`, like `parkAProposalForTesting()` below; production has
    /// exactly one call site for a `WindowModel` (`WindowSession.start`),
    /// and it does not use this.
    ///
    /// Builds its own scratch `ActionRegistry` (a fresh temp directory,
    /// touched only if a test actually dispatches something), `PaneStore`
    /// and `LayoutStore`, and a `ProviderCredentialsLookup` that always
    /// succeeds unless the caller supplies its own — see
    /// `AlwaysSucceedsCredentialsLookupForTesting` (`ProviderCredentials.swift`).
    ///
    /// `sessionRows:` (Task 12) seeds a `session_list` test double —
    /// `autoResumeAfterSwitch()`'s own tests need `session_list` to answer
    /// with a specific fixture, not the "unregistered action" refusal every
    /// other `forTesting` caller gets by relying on the default `[]`. It has
    /// to reach the registry through `ActionRegistry`'s `initialActions:`
    /// (set inside `init`, not a follow-up `await register(_:)`) because
    /// this method is itself synchronous.
    ///
    /// `scratchRoot:` is where its journal and its terminals' rc
    /// directories go. **Required, not defaulted**: this is test-only, so a
    /// default would serve nobody but the next caller who forgets it, and
    /// every model built against the temp dir leaves a directory behind
    /// there (#279). The suite passes its per-run `testScratchRoot`.
    static func forTesting(
        scratchRoot: URL,
        organization: String = "test-org",
        harnessFactory: @escaping @Sendable (Place, ProviderSelection) -> AgentHarness? = { _, _ in nil },
        lookup: ProviderCredentialsLookup? = nil,
        lookupFactory: (@Sendable (String) -> ProviderCredentialsLookup)? = nil,
        context: ContextStore? = nil,
        rootPath: String = "/tmp/wakil-window-model-for-testing",
        providerId: String = "test-provider",
        sessionRows: [JSONValue] = [],
        // Defaults to always-succeeds-with-no-diagnostics, so a test that
        // does not care about `setOrganization`'s restart step (most of
        // them) gets a switch that simply works.
        orgSwitcher: @escaping @Sendable (String) async -> [String] = { _ in [] },
        // Defaulted to a fresh broker for every existing call site. A
        // test that needs to arm `holdNextCurrentForTesting()` on the
        // SAME broker instance the model actually calls (T11 fix round 2)
        // passes its own instance here and keeps a reference to it.
        confirmations: ConfirmationBroker = ConfirmationBroker(),
        // 2d-i. Nil by default, as in production's initialiser.
        vocabulary: VocabularyStore? = nil,
        placeClients: PlaceClients? = nil,
        persistence: LayoutPersistence? = nil,
        agentSocketFactory: @escaping AgentSocketFactory = { _, _ in NoAgentSocket() },
        quickModelFactory: (@Sendable (QuickProviderRecord, String) async throws -> (any QuickModel)?)? = nil,
        paletteClients: PaletteClients = PaletteClients(),
        gitStatus: GitStatus? = nil,
        claudeLocator: ClaudeExecutableLocator? = nil,
        apiHTTP: (any ToolCaller)? = nil
    ) -> WindowModel {
        let scratch = scratchRoot
            .appendingPathComponent("wakil-window-model-for-testing-\(UUID().uuidString)")
        let panes = PaneStore(kinds: PaneKinds.standard)
        let layout = LayoutStore()
        // A real `TerminalStore`, paired with THIS `panes` — not the
        // parameterless default `WindowModel`'s own designated init falls
        // back to — so a test that opens a terminal pane through the
        // model gets the same store `term_open`'s handler (registered
        // just below, into `initialActions:`) actually calls, and the
        // blocks it records land in the pane store this model reads back.
        let terminals = TerminalStore(scratchRoot: scratchRoot, panes: panes)
        let shellContext = ActiveShellContext()
        let registry = ActionRegistry(
            journalDirectory: scratch, sessionId: "window-model-for-testing",
            // `layoutActions(...)` (`LayoutActions.swift`) and
            // `terminalActions(...)` (`TerminalActions.swift`) are the
            // synchronous builders — the same ones `registerLayoutActions`
            // and `registerTerminalActions` loop over to `await
            // registry.register` each into a live registry. Handing the
            // built `[Action]`s straight to `initialActions:` is what lets
            // `forTesting` register them without ever needing an `await`;
            // see `ActionRegistry.init`'s own doc comment on that
            // parameter for why that constraint exists at all. Both sets
            // are registered — not just the terminal one — so a model
            // built by `forTesting` can dispatch `pane_close` (what
            // `closePane` calls) and actually close a pane, not merely
            // find the name unregistered.
            initialActions: [
                Action(
                    name: "session_list",
                    description: "WindowModel.forTesting's session_list fixture (Task 12)",
                    kind: .read,
                    audience: .agentReachable,
                    schema: .object(["type": .string("object")]),
                    handler: { _ in
                        .object(["structuredContent": .object(["sessions": .array(sessionRows)])])
                    })
            ] + layoutActions(
                layout: layout, panes: panes, terminals: terminals,
                unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
                // Wired to the model built below, exactly as
                // `WakilWiring.build` + `WindowSession.start` wire the
                // shipped one — so a test that sets a context on the
                // window and opens a pane exercises the real path rather
                // than the always-empty default (final review, Critical 3).
                + terminalActions(
                    terminals: terminals, panes: panes, layout: layout,
                    activeContext: { await shellContext.current() }))
        let resolvedLookupFactory: @Sendable (String) -> ProviderCredentialsLookup
        if let lookupFactory {
            resolvedLookupFactory = lookupFactory
        } else if let lookup {
            resolvedLookupFactory = { _ in lookup }
        } else {
            resolvedLookupFactory = { _ in AlwaysSucceedsCredentialsLookupForTesting() }
        }
        let model = WindowModel(
            registry: registry,
            panes: panes,
            layout: layout,
            persistence: persistence,
            context: context,
            harnessFactory: { place, selection, _ in harnessFactory(place, selection) },
            resumes: ResumeBroker(),
            rootPath: rootPath,
            providerId: providerId,
            lookupFactory: resolvedLookupFactory,
            confirmations: confirmations,
            orgSwitcher: orgSwitcher,
            terminals: terminals,
            claudeLocator: claudeLocator,
            apiResolver: apiHTTP.map { ApiPaneResolver(panes: panes, http: $0, layout: layout) },
            vocabulary: vocabulary,
            rootWatcher: nil,
            editorRootWatcher: nil,
            fileLists: nil,
            gitStatus: gitStatus,
            paletteClients: paletteClients,
            placeClients: placeClients,
            agentSocketFactory: agentSocketFactory,
            quickModelFactory: quickModelFactory)
        model.setOrganizationForTesting(organization)
        shellContext.use { [weak model] in
            guard let model else { return ("", "", "", "") }
            return await model.activeShellContext
        }
        return model
    }

    /// TEST-ONLY: sets `organization` directly, bypassing the
    /// `wakil-ctx` round trip `refreshContext()` otherwise requires — how
    /// `forTesting`'s `organization:` parameter takes effect, and how a
    /// test simulates a live org switch (Task 7 on) without a real
    /// `ContextStore`.
    ///
    /// **Rebuilds `lookup` too**, because both production paths that
    /// assign `organization` do (`refreshContext()` and
    /// `setOrganization`), and a seam that set one without the other
    /// would hand every test that uses it the exact inconsistency the
    /// final fix pass's Critical 1 was: a model claiming org `alpha`
    /// while its credential lookup is still built for `""`. It stays a
    /// seam, not a switch — nothing else `setOrganization` does happens
    /// here.
    /// TEST-ONLY: installs a machine lookup for `claude` (#322), the seam
    /// `forTesting` has no parameter for.
    func useClaudeLocatorForTesting(_ locator: ClaudeExecutableLocator) {
        claude.use(locator)
    }

    /// TEST-ONLY: the path a browser sign-in would spawn right now.
    func loginBinaryForTesting() -> String { loginBinary() }

    func setOrganizationForTesting(_ org: String) {
        organization = org
        lookup = lookupFactory(org)
    }

    /// TEST-ONLY: exposes the `private` `startHarness()` so a test can
    /// confirm what org `harnessFactory` was actually invoked with,
    /// without going through `send()`'s full turn machinery.
    /// TEST-ONLY: brings the canvas in line with the place seeded on screen, as
    /// `refreshContext` does once `wakil-ctx` has answered.
    func activateLayoutForTesting() async {
        await activateLayout()
    }

    /// TEST-ONLY: the session id `place`'s shown socket answers for, while no session has taken
    /// it (`openShownSocket`).
    func shownSocketSessionIdForTesting(_ place: Place) -> String? {
        shownSockets.values.first { $0.place == place }?.sessionId
    }

    /// TEST-ONLY: the id `place` reserves for its next conversation, if any.
    func reservedConversationForTesting(_ place: Place) -> String? {
        reservedConversations[place]
    }

    /// TEST-ONLY: the pane ids `place`'s Landing ignores after `newConversation`, if any.
    func landingBaselineForTesting(_ place: Place) -> Set<String>? {
        landingBaselines[place]
    }

    /// TEST-ONLY: waits for every shown socket's start.
    func settleShownSocketsForTesting() async {
        for shown in shownSockets.values { _ = await shown.opening.value }
    }

    /// TEST-ONLY: waits for the pool to have been told the places in use.
    func settlePlaceRetainForTesting() async {
        await placeRetain?.value
    }

    func startHarnessForTesting() async -> AgentHarness? {
        let id = UUID().uuidString
        guard let started = await startHarness(in: place, provider: providerId, sessionId: id, conversation: id)
        else { return nil }
        await started.socket?.stop()
        return started.harness
    }

    /// TEST-ONLY: exposes the `private` `rootPath` so a test can assert
    /// what `refreshContext()` rebuilt (or cleared) it to, without making
    /// the property itself readable by production code that has no
    /// business reaching around `startHarness`'s use of it.
    var rootPathForTesting: String { rootPath }

    /// TEST-ONLY: the watcher this window was handed, so the wiring test can pin that the
    /// one `WindowSession.start` passes is the one held (`wakil-never-wired-parameters`).
    var rootWatcherForTesting: (any RootWatcher)? { gitWatcher?.watcher }

    /// TEST-ONLY: the file list this window was handed (`AppWiringTests`).
    var fileListsForTesting: EditorFileLists? { fileLists }

    /// TEST-ONLY: the registry this window journals into, so a test can
    /// read back what `send` recorded (2d-i's `identifiers_resolved`).
    var registryForTesting: ActionRegistry { registry }
    var layoutForTesting: LayoutStore { layout }

    /// TEST-ONLY: puts a settings tree in place, or clears it as
    /// `invalidateForOrgChange` does.
    func setSettingsForTesting(_ tree: SettingsTree?) { settings = tree }

    /// TEST-ONLY: seeds state a real session would only reach by way of a
    /// live turn — a chosen provider, a launch directory, some agent
    /// thoughts, a per-pane database choice, a parked confirmation, a
    /// database list, a cached layout, and (Task 9's fix round 1) a project
    /// and environment — so `invalidateForOrgChange()`'s test, and
    /// `refreshContext()`'s failure-path test, can each assert their own
    /// fields are actually cleared without driving `send()`, a live
    /// confirmation round trip, or a real `get_context` failure to produce
    /// them.
    ///
    /// **`project`/`environment` matter here for the same reason the other
    /// six do.** Both are `private(set)` and otherwise written only by
    /// `refreshContext()` itself, so a failure-path test with no way to
    /// seed a non-default value first would find them already `""` before
    /// the call — passing whether or not the catch block still clears them.
    /// Reachable only from inside this type (this method lives in
    /// `WindowModel` itself), which `private(set)` does not block.
    ///
    /// All eight added parameters default to values equal to what a fresh
    /// `WindowModel` already holds, so every existing call site seeds
    /// exactly what it did before this method grew them.
    /// Seeds the production declarations without a `get_context` round
    /// trip, so a test can assert what `invalidateForOrgChange` does to
    /// them. Test-only, like `seedForTesting` below.
    func seedEnvironmentProductionForTesting(_ production: EnvironmentProduction) {
        environmentProduction = production
    }

    /// Puts `text` on the status line, for a test asserting something leaves it alone.
    func setStatusForTesting(_ text: String) { status = text }

    func seedForTesting(
        providerId: String, rootPath: String, thoughts: Int,
        databaseChoices: [String: QueryLineDatabaseChoice] = [:],
        pending: PendingMutation? = nil,
        databases: [String] = [],
        databaseDrivers: [String: String] = [:],
        layoutSnapshot: LayoutSnapshot = LayoutSnapshot(),
        project: String = "",
        environment: String = ""
    ) {
        self.providerId = providerId
        self.rootPaths = [rootPath]
        self.databaseChoices = databaseChoices
        self.databases = databases
        self.databaseDrivers = databaseDrivers
        self.layoutSnapshot = layoutSnapshot
        self.project = project
        self.projectKey = project
        self.environment = environment
        // On the place just seeded, so the plane draws it. Nil leaves what is parked alone,
        // so a test that moves the screen does not clear other places' proposals.
        if let pending { parkedSlots[ProposalSlot(place: place, conversation: nil)] = pending }
        // Into the thread of the place just seeded, so the rows are on screen.
        if thoughts > 0 {
            let agent = agent(for: place)
            for i in 0..<thoughts { agent.appendRow(label: "test", detail: "seed \(i)") }
        }
    }

    /// What the view draws for the environment label. Never empty: Invariant
    /// 8 says the active environment is visible at all times, and a blank
    /// space would read as "no environment" rather than "not resolved yet".
    public var environmentLabel: String {
        environment.isEmpty ? "unknown" : environment
    }

    /// What Task 10's bottom-edge indicator draws for the running account.
    /// Never empty, for the same reason `environmentLabel` is never empty —
    /// a blank space renders as nothing at all, not as "no provider".
    ///
    /// **"unset", not "unknown".** An empty `providerId` is not an unread
    /// value the way a fresh `environment` is (that case is "not resolved
    /// yet") — `providerId`'s own doc comment, and the identical branch in
    /// `resume`'s refusal message above, are both explicit that empty means
    /// this window has never had a provider chosen for it (a fresh install,
    /// or an org with none configured). Reusing "unset" here rather than
    /// inventing a second word for the same state is what keeps that one
    /// meaning attached to one word across the status line and this label.
    public var providerLabel: String {
        providerId.isEmpty ? Self.unsetProviderLabel : providerId
    }

    /// The launch-time note for an org whose `active.json` names no
    /// provider yet, or `nil` once one is running.
    ///
    /// DERIVED, NOT APPENDED. This sentence used to be pushed onto
    /// `WindowSession.notes` — a `let [String]` fixed while the window was
    /// being assembled, which `WakilWindow` then draws for the window's
    /// whole life. Nothing could retract it, so it stayed on screen after
    /// ⌘P had chosen an account, contradicting the account indicator a few
    /// inches away that was by then reading the new provider. That is
    /// `shared-accounts-acceptance.md` D3, visible in every screenshot of
    /// that walk including the ones where the shared account is
    /// demonstrably running. Reading `providerId` instead means the note
    /// cannot outlive the condition it describes, because there is no
    /// second copy of that condition to go stale.
    ///
    /// It lives on `WindowModel` rather than on `WindowSession` for a
    /// second reason: `WindowSession` is in `WakilApp`, which has no test
    /// target and cannot have one (`phase-2c-ii-b-acceptance.md` §3), and
    /// `WindowModel` is in `WakilKit`, which does. A string that was
    /// unreachable by every automated test is now pinned by three
    /// (`ProviderSwitchTests`).
    /// Whether the last `get_context` read gave this window a project
    /// root to run in. Org-derived: `invalidateForOrgChange` clears it with
    /// `rootPath`, and `refreshContext` sets it again from the same answer.
    public private(set) var hasProjectRoot = false

    /// The sentence for a window that runs in the home directory because
    /// it has no project root yet. **Derived, not carried** — it used to be
    /// a `notes` append in `WindowSession`, fixed at launch, so a window
    /// opened before any organisation kept saying it after a project with
    /// a root was open (found on the 2d-ii walk). The same defect, and the
    /// same fix, as `noActiveProviderNote` below (D3).
    public var noProjectRootNote: String? {
        guard !hasProjectRoot else { return nil }
        return "no project root available yet, so this session runs in \(rootPath) instead"
    }

    public var noActiveProviderNote: String? {
        guard providerId.isEmpty else { return nil }
        return "no active provider is set for this org yet — pick one in ⌘P, or bootstrap "
            + "headlessly with `--dispatch ctx_set_provider`"
    }

    /// The word this codebase uses for "no provider chosen yet", shared so
    /// the one meaning stays attached to one literal rather than being
    /// retyped at each call site (`resume`'s refusal message above,
    /// `providerLabel` here, and `WakilWindow`'s indicator before the
    /// window's first `WindowModel` exists to ask).
    public static let unsetProviderLabel = "unset"

    /// A pane's table, empty for one nothing has written to — so a SwiftUI
    /// body can ask unconditionally, the same way `PaneStore.snapshot` can
    /// be asked for any id at all.
    public func table(_ paneId: String) -> PaneTable { tables[paneId] ?? .empty }

    /// The pane's `TerminalSnapshot`, or `nil` when it is not a terminal pane, or when it has
    /// not been refreshed yet. `api(_:)` and `editor(_:)` answer the same way for their kinds.
    public func terminal(_ paneId: String) -> TerminalSnapshot? { paneCells[paneId]?.snapshot.terminal }
    public func api(_ paneId: String) -> ApiSnapshot? { paneCells[paneId]?.snapshot.api }
    public func editor(_ paneId: String) -> EditorSnapshot? { paneCells[paneId]?.snapshot.editor }

    /// Puts `snapshot` in `paneId`'s cell, adding the cell only if the pane is new.
    private func setCell(_ paneId: String, _ snapshot: PaneSnapshot) {
        if let cell = paneCells[paneId] { cell.snapshot = snapshot } else { paneCells[paneId] = PaneSnapshotCell(snapshot) }
        if let editor = snapshot.editor { autosaveObserve(pane: paneId, snapshot: editor) }
    }

    // MARK: Context

    /// Re-reads the active org/project/environment from `wakil-ctx`.
    ///
    /// This is a read of Wakil's own selection, not a state change, so it
    /// goes through `ContextStore` rather than `dispatch`: the 2a action set
    /// has no `get_context` action to dispatch (see `registerStandardActions`),
    /// and Invariant 2 governs mutation paths, not reads. The two *changes* —
    /// `setProject` and `setEnvironment` — do dispatch.
    ///
    /// The canvas follows the answer, because a project's arrangement
    /// belongs to that project; `activateLayout` is where that happens and
    /// says what it does and does not touch.
    ///
    /// `probe` asks for a capacity probe once the canvas has followed: only
    /// launch and an org switch pass it. Every other caller (project and
    /// environment switches, the observation pump the agent can drive) reads
    /// the stored numbers only, so the agent cannot make Wakil spend the
    /// operator's limit. The probe never holds the canvas (Rule 4).
    public func refreshContext(probe: Bool = false) async {
        var contextRead = false
        guard let context else {
            status = "no wakil-ctx client: org, project and environment are unknown"
            return
        }
        do {
            let active = try await context.current()
            organization = active.org
            project = active.project
            projectKey = active.projectKey
            environment = active.environment
            // **The one writer of the gate's view of production**
            // (Decision 26, #182). `get_context` carried the whole project
            // already, so the flags cost nothing extra — and they are set
            // HERE, on the only call that can change the active project,
            // so the gate and the room can never be reading a previous
            // project's declarations.
            environmentProduction = active.environmentProduction
            await registry.setEnvironmentProduction(active.environmentProduction)
            if let agent = currentAgent {
                // Newer than any chip read still in flight for this place: those are dropped.
                agent.productionReads += 1
                agent.showProduction(active.environmentProduction)
            }
            // An agent session may have kept this place's context. This read is newer, so that
            // copy goes: the agent's next call is priced by what the project declares now, not
            // by what it declared then.
            await placeContexts?.forget(place)
            // An agent with no project reads its organisation's active project (`pinnedPlace(of:)`),
            // which this read may just have moved: its copy goes too.
            await placeContexts?.forget(Place(organization: organization, project: "", environment: ""))
            // **Re-derived, not carried.** All three are org-derived
            // state that `invalidateForOrgChange` cleared, and this is
            // the one call that can rebuild them from the org this
            // window is actually running under — `providerId` and
            // `rootPath` ride on the same `get_context` answer the
            // project and environment do, and `lookup` is rebuilt from
            // the org that answer just reported. Without the first two,
            // `startHarness` refuses the empty providerId and
            // auto-resume has nothing to select for, so the window lands
            // in the new org with no agent for a reason no message
            // explains (spec §5.3).
            providerId = active.activeProvider
            rootPaths = active.rootPaths
            hasProjectRoot = !active.rootPaths.isEmpty
            // **The lookup is org-derived too, and this is where the org
            // first becomes known.** `WakilCLICredentialsLookup` bakes
            // `organization:` in at construction and shells out to
            // `wakil --org <organization> provider credentials <id>`, so
            // the placeholder built in `init` — and rebuilt by
            // `invalidateForOrgChange()` — runs `wakil --org ""`, which
            // `cmd/wakil/main.go` turns into `WAKIL_ORG=""` and
            // `CurrentOrg()` refuses outright ("WAKIL_ORG is not set").
            // Every credential resolution in the window's life goes
            // through this one object — `startHarness`, `resume`,
            // `setProvider`, `autoResumeAfterSwitch` — so leaving it
            // built for `""` costs the window its entire agent
            // capability, at launch, with no switch involved (final fix
            // pass, Critical 1). Fail-CLOSED, so Invariant 4 held
            // throughout: a lookup for `""` hands out no org's
            // credentials at all, least of all the wrong org's.
            //
            // Rebuilt here rather than only in `setOrganization` because
            // this is the ONLY path a launch takes: no operator switch
            // happens on the way into the first org.
            lookup = lookupFactory(organization)
            // 2d-i: the names in scope follow the context just read.
            await vocabulary?.contextChanged(active)
            // 3b-v: the tabs follow the project, so the settings in force are read with it.
            await refreshEditorSettings()
            // Capacity is read once the providers and the org are known,
            // so the hairlines are not empty until a turn ends or
            // Settings opens. Launch and an org switch both come here, so
            // this is the one that asks for a probe, after the canvas below.
            await capacity.refresh()
            contextRead = true
        } catch {
            status = "context: \(error)"
            // **Cleared, not kept.** Keeping them would leave the window
            // showing the outgoing org's project and running its
            // provider while `organization` names the new one — the
            // wrong credential boundary, drawn confidently (spec §6).
            project = ""
            projectKey = ""
            environment = ""
            // The flags belong to the project that could not be read, so
            // they go with it. Keeping them would price the new org's
            // environments by the old org's declarations, and a stale
            // `production: false` is a production mutation priced as
            // staging (#182).
            environmentProduction = .undeclared
            await registry.setEnvironmentProduction(.undeclared)
            rootPaths = []
            hasProjectRoot = false
            // **The error still names the org and the provider** — spec
            // §6.1's Go half, reaching Swift for the first time (§6.3).
            // `ContextStoreError.serverError` carries `PartialContext`
            // precisely so this branch is not blind, and both fields are
            // load-bearing here:
            //
            // - `organization`: §6.2 says `setOrganization` assigns it
            //   from the id it switched to, before this runs, and that
            //   value is more authoritative than anything `get_context`
            //   reports. True for a SWITCH — and a LAUNCH takes neither
            //   `setOrganization` nor the success path above, so before
            //   §6.3 nothing assigned it at all. Launching into an org
            //   with no active project therefore left `organization` at
            //   `""`, which `WakilWindow`'s `hasOpenOrg` reads as "no org
            //   is open" and answers by force-opening the org plane,
            //   undismissable, over an org that was perfectly fine. So:
            //   assign only when the switch path did not already (it
            //   cannot disagree — both are the same org id, one from the
            //   child environment and one from `CurrentOrg()` reading
            //   it back), and only when the partial actually knows one.
            // - `providerId`: cleared unconditionally before §6.3, which
            //   discarded an `active.json` pick the server had just
            //   reported. `autoResumeAfterSwitch` opens with `guard
            //   !providerId.isEmpty`, so the window landed in the org
            //   with no agent and no message — §5.3's own subject.
            var partial = PartialContext()
            if case ContextStoreError.serverError(_, let reported) = error { partial = reported }
            if organization.isEmpty, !partial.org.isEmpty { organization = partial.org }
            providerId = partial.activeProvider
            // Rebuilt for whatever `organization` now holds, which on the
            // launch path is a value this branch just learned. The success
            // path's own comment explains why every credential resolution
            // in the window's life depends on this one object being built
            // for the right org; leaving it on `init`'s `""` after we know
            // better would cost the window its agent for the same reason,
            // one path over. Fail-closed is unchanged: when the partial
            // knows no org either, this rebuilds the `""` lookup, which
            // hands out no org's credentials at all.
            lookup = lookupFactory(organization)
        }
        await activateLayout()
        if probe && contextRead { startCapacityProbe() }
        // The roots may have changed with the project — a launch, a project switch (the
        // operator's `setProject` and the agent's `ctx_set_project` both end here) or an
        // org switch's re-read — so the watcher follows them. `activateLayout` usually got
        // there first through its own layout read; this covers a switch that left the
        // arrangement where it was.
        await syncGitWatcher()
        await syncEditorWatcher()
        // The chooser's rows belong to the environment, so they are re-read
        // wherever the environment can have changed — launch, a project
        // switch, an environment switch — which is exactly this one place.
        await refreshDatabases()
    }

    /// Resets what belongs to the organisation itself, and nothing that belongs to a place in
    /// it. **The org switch's whole teardown** (background agents 3 of 4).
    ///
    /// **What goes:** the context (`project`, `environment`, the production flags the gate
    /// prices the screen by), the settings, accounts and login, `lookup`, `providerId` and the
    /// roots, the palette's and the vocabulary's caches, capacity, and the editor's pending
    /// requests and unsaved prompt, which name panes on the screen being left. The window's
    /// clients are re-pointed by `orgSwitcher` after this, and `refreshContext` re-derives the
    /// rest for the incoming org. **What stays:** every place's agent, thread, turn, waiting
    /// approval and conversation; both stores' scopes, so each canvas and its rows; every shell;
    /// every editor buffer, save and autosave; reads in flight. Each is keyed by its place or
    /// scope, so nothing of the outgoing org is drawn or resolved under the incoming one, and
    /// coming back finds it as it was left (`comingBackToAnOrgFindsItsCanvasAsLeft`).
    ///
    /// **Adding org-scoped state to this type means deciding here.**
    /// `InvalidationContractTests` fails on any stored property not classified as org-derived
    /// (reset here), kept per place, or org-independent.
    ///
    /// Called from `setOrganization` BEFORE the clients restart, so no
    /// handler can resolve against the outgoing org's context while the
    /// new org's server is coming up.
    func invalidateForOrgChange() async {
        // Invariant 4 for names: nothing of the old org resolves after this line.
        await vocabulary?.dropAll()
        // 3b-viii: nothing answers a ghost request on the outgoing org's providers, and a rebuild
        // still reading its tree installs nothing (`quickTasksGeneration`). The switch rebuilds.
        quickTasksGeneration += 1
        ghostTextEnabled = false
        quickTasksConfigError = nil
        await shutDownQuickTasks()
        // Context. `organization` is deliberately NOT cleared here: the
        // caller assigns it from the id it switched to, which is more
        // authoritative than anything get_context will say (spec §6).
        project = ""
        projectKey = ""
        environment = ""
        // Org-derived, and a credential boundary rather than a display
        // detail: the declarations describe the OUTGOING org's project.
        // Left standing until the first context read of the new org, the
        // gate would price the incoming environments by the outgoing
        // org's flags — and a stale `production: false` is a production
        // mutation priced as staging. Invariant 4 (#182). The registry's
        // copy is cleared with it, because the gate reads that one. An agent
        // in the org left is priced by its own place's flags (`productionFlags(forCaller:)`).
        environmentProduction = .undeclared
        await registry.setEnvironmentProduction(.undeclared)
        // Requests addressed to a pane on the screen being left. Pane ids repeat across
        // scopes, so carried over one would act on the incoming screen's pane of the same id:
        // the path field, the keyboard (Rule 6) or a tree's selection.
        editorSaveAsRequest = nil
        editorColumnFocusRequest = nil
        editorTreeRevealRequest = nil
        // The unsaved prompt names the screen's panes for the same reason. A quit it was
        // holding is answered no, or AppKit would wait on it forever; the buffers it asked
        // about stay dirty in their own scope.
        if unsavedPrompt?.intent == .quit { quitCancelled += 1 }
        unsavedPrompt = nil

        // The settings tree describes the OUTGOING organisation — its
        // three strings, its accounts, its projects. Every one of those is
        // the boundary Invariant 4 defines, so leaving it set would draw
        // one organisation's configuration under another's name until the
        // next read landed. `settingsFailure` goes with it: a failure to
        // read the old org says nothing about the new one.
        settings = nil
        settingsFailure = nil
        editorSettings = .defaults
        // The account table carries `mine`, which is a statement about
        // WHICH organisation the operator is standing in — false for
        // every row the moment that changes, and silently wrong until the
        // next read if it were left.
        accounts = nil
        // An in-flight login belongs to the organisation it was started
        // in. A switch ends that context, and a band left on screen would
        // be offering to add an account to an organisation nobody is
        // looking at. The observer goes with it, or it would write the
        // outgoing organisation's states back onto the incoming one.
        providerLoginObserver?.cancel()
        providerLoginObserver = nil
        providerLogin = .idle
        addingAccountId = ""
        claudePathOverride = ""
        // **A mint in flight is NOT dismissed**, and that is the one
        // exception here. `dismiss()` cancels the running task, which on
        // the capture step is the cancel this phase spent a ticket
        // ensuring has no control — reached by another gesture. The mint
        // is a separate process storing under the organisation it started
        // in, so letting it finish is both correct and the only
        // disposition that does not risk a credential Wakil never caught.
        //
        // The commit afterwards will refuse, because it resolves the
        // organisation the window is in NOW — which is the honest
        // outcome, and the one the operator is told costs no further
        // browser trip because the credential is already kept.
        if let session = providerLoginSession, await !session.isMinting() {
            await session.dismiss()
        }

        // The outgoing org's readings (CapacityFeedTests.resetForgetsReadingsAndFailure).
        capacity.reset()
        providerId = ""
        // TEST-ONLY, but still a record of which session
        // `autoResumeAfterSwitch()` last picked for the OUTGOING org — left
        // set, a test could read a stale org A session id as if it were
        // org B's just-made selection (Task 12).
        resumedParentForTesting = nil
        // The palette's cache of the outgoing org (Invariant 4): see `invalidatePalette`.
        invalidatePalette()

        // Org-derived services. `lookup` is reset to the ORG-LESS
        // placeholder rather than nilled, because every caller expects
        // one to exist and a lookup for `""` resolves nothing — the
        // fail-closed state a window mid-switch should be in. **This is a
        // teardown, not the rebuild**: `setOrganization` rebuilds it from
        // the org it switched to the moment it assigns `organization`,
        // and `refreshContext()` rebuilds it again from the org
        // `get_context` reports (spec §5.3). Leaving this line as the
        // last word on `lookup` is what shipped, and it cost the app
        // every agent session — see `init`'s note (final fix pass,
        // Critical 1). `rootPath` likewise falls back to home until
        // `refreshContext` rebuilds it.
        lookup = lookupFactory("")
        rootPaths = []
        hasProjectRoot = false

        // The watchers follow the screen's roots, which are none until the incoming org's
        // context is read (`refreshContext` syncs them again). A place left behind catches up
        // when the operator returns (R4). The trees' mirror of their listing goes with it, and
        // so does the window's git status, which is of the screen's roots only.
        editorFiles = .empty
        await gitStatus?.reset()
        gitRoots = []
        // 3a-ii: the Changes view's drafts, history, errors and identity are the outgoing org's roots'.
        // A write still running is NOT cancelled: a commit finishes, hooks and all, in the repository it
        // started in, and only its result is dropped (`changesGeneration`), so nothing of it shows here.
        changesGeneration += 1
        changesTasks = [:]
        for task in changesDraftTasks.values { task.cancel() }
        changesDraftTasks = [:]
        changesDrafting = []
        changesLastDraft = nil
        changesRemoteNotes = [:]
        changesMessages = [:]
        changesHistory = [:]
        changesHistoryCursor = [:]
        changesErrors = [:]
        changesInFlight = []
        changesIdentity = [:]
        await syncGitWatcher()
        await syncEditorWatcher()
    }

    /// Brings the canvas in line with whatever context is now active:
    /// commits the arrangement being left, switches `LayoutStore` and
    /// `PaneStore` to the incoming scope and, the first time this session
    /// sees that scope, reads its saved arrangement off disk (spec §4.3,
    /// "read at project switch").
    ///
    /// **Those three steps are one act, and the middle of it is not a
    /// state anything may commit.** The outgoing arrangement is written
    /// before the incoming one is restored, and from the switch until the
    /// restore `layoutSwapInFlight` holds every other writer off — see
    /// that property for the arrangement a switch destroyed before it did.
    ///
    /// **This is the one place a scope is derived from the active
    /// context.** All three layers it keys — `LayoutStore`, `PaneStore`,
    /// `LayoutPersistence` — take the value and none of them works one
    /// out, so there is exactly one answer in the process to "what does
    /// this arrangement belong to" and memory and disk cannot drift apart.
    /// `persistLayout` writes under `layoutScope`, which this method set,
    /// rather than recomputing it.
    ///
    /// Called from `refreshContext`, which is the one place that learns
    /// which project is active, and from the three places that change
    /// which *conversation* the window is in: `enterConversation` (a pane
    /// or a turn), `resume`, and `setProvider`. Every writer of
    /// `lineageRoot` ends by calling this, which is what keeps
    /// `layoutScope` from naming a conversation the window has left —
    /// `persistLayout` writes under `layoutScope`, so a stale one puts one
    /// conversation's panes in another's file.
    ///
    /// **The conversation joins the scope, and a pane opened at the
    /// Landing still lands in it.** `enterConversation` mints the identity
    /// and activates *before* dispatching `pane_open`, so the order is:
    /// the window acquires a conversation, the canvas switches to it — for
    /// a brand-new one, onto the project's seed, because that is what
    /// `LayoutPersistence` falls back to — and only then does the pane
    /// open, into the arrangement it belongs to. Nothing is rekeyed after
    /// the fact and no pane is opened into a scope that is about to
    /// change.
    ///
    /// **Only on a change, and the read only once per scope per
    /// session** — tracked in `loadedLayoutScopes`, a set, not by
    /// comparing against the scope last shown. `LayoutStore` keeps every
    /// visited scope's arrangement in memory and promises that "coming
    /// back to a scope finds it as it was left", so a second read is not
    /// merely redundant: `layout.load` replaces an arrangement wholesale,
    /// and re-reading on the way back in would destroy anything opened or
    /// moved there since — an agent's `pane_open`, or any change whose
    /// save failed. A set is used rather than "skip the read when the
    /// store already holds panes" because an operator who closed every
    /// pane in a project meant to close them, and would not thank us for
    /// resurrecting them on the way back in.
    ///
    /// The read is taken inline, unlike the save in `persistLayout`, which
    /// goes off the main actor. It happens once per scope per session
    /// rather than on every drag release, and its result is needed before
    /// the canvas can draw anything, so hopping off and back would buy a
    /// frame's latency and nothing else.
    ///
    /// **`layout.load` is not a second write path.** It is a restore of
    /// state that a previous session's dispatches produced, there is
    /// deliberately no action for it (Task 11 made `LayoutPersistence` and
    /// `LayoutStore.load` that seam), and nothing the operator or the agent
    /// can ask for reaches it. Every *change* still goes out as a dispatch.
    /// `carrying` is a window-owned pane (the settings pane) to move into the
    /// incoming arrangement before it is published, so the swap never shows
    /// it closing. See `LayoutStore.carry`.
    ///
    /// `adoptingCanvas`: the incoming scope is a conversation minted this moment over the canvas
    /// on screen (`enterConversation`). When the outgoing scope is the same organisation and
    /// project under no conversation, both stores MOVE its contents into the incoming scope and
    /// nothing is read off disk — a brand-new conversation has no file of its own, and the seed
    /// is what is already on screen, minus every draft (re-walk finding #4).
    private func activateLayout(carrying overlay: Pane? = nil, adoptingCanvas: Bool = false) async {
        // Every way the screen changes converges here — a picker, a ⌘P jump, an org switch, a new
        // conversation, a switch — so this is where the composer is told (`tellScreenChange`),
        // once, whichever return this takes.
        defer { tellScreenChange() }
        // The place is on screen: it has a socket from now on, before any turn (`openShownSocket`).
        openShownSocket()
        // The place is the screen's now: what its agent did while away has been seen, and its
        // chip goes (background agents 4 of 4). Not while `goTo` is passing through it: only
        // where that lands has been seen, and `goTo` clears it there (final review I1).
        if goTosInFlight == 0 { markSeen(currentAgent) }
        // No project, no arrangement. `refreshContext`'s error branch
        // clears `project` deliberately — keeping the outgoing org's would
        // draw the wrong credential boundary confidently (spec §6) — and
        // then reaches here. **The scope is cleared with it**, not merely
        // left behind: `persistLayout` writes under `layoutScope`, so a
        // stale one would file the canvas under the very project that
        // branch just refused to keep showing.
        //
        // **Another organisation's canvas is put away, not drawn** (background agents 3 of 4):
        // an org switch keeps every scope in memory, so landing in an org with no project — or
        // in none, a failed restart — would otherwise leave the org left on screen under the new
        // name (Invariant 4). It is committed and kept for the return, as any swap keeps it.
        //
        // **An organisation with no project shows its own canvas**, `LayoutScope(org, "", "")`
        // (final review, ruling on concern 1): the one its no-project agent works in
        // (`agentScope(for:)`), so that agent's panes are drawn while the operator is there,
        // and two such organisations never share one. `.initial` — the same value with no
        // organisation — is left only for a window with none. Nothing of it is written to disk.
        guard !projectKey.isEmpty else {
            let outgoing = layoutScope
            layoutScope = nil
            if let outgoing, outgoing.organization != organization {
                await putAwayCanvas(outgoing)
            } else if outgoing == nil, await panes.screenScope != bareScope {
                await showCanvas(bareScope)
            }
            return
        }
        // The scope, not the project, is what a change is measured
        // against. Today the two answers differ only when the organisation
        // changed under a same-named project, which
        // `invalidateForOrgChange` already clears `layoutScope` for — so
        // this is less a behaviour change than the one comparison that
        // stays right as the scope widens.
        //
        // **It rests on the org never arriving after the project**, and
        // that is enforced a layer down rather than assumed here:
        // `wakilcore.Resolve` calls `CurrentOrg()` first and returns an
        // error when `WAKIL_ORG` is unset, so a successful `get_context`
        // always carries an org, and the failure branch that does not
        // clears `project` and returns above. Were an org to resolve
        // *after* a project, the key would move under a canvas the
        // operator had already arranged and `switchScope` would hand back
        // an empty one — which is why the guarantee is named here instead
        // of being re-derived by the next reader.
        let scope = currentLayoutScope
        // **Equal key means equal on all four fields** (#160, Plan 3): same
        // organisation, same project, same environment, same conversation. It did not until
        // 2026-09-20 — inside a conversation the project was excluded from
        // the identity, so this branch caught a project switch and
        // returned without moving a pane, which is the defect the operator
        // walked into. There is nothing left for it to swallow, and
        // nothing to replace: a scope that compares equal carries the same
        // values.
        guard scope != layoutScope else {
            // **Installed is not finished** (#328, #312). A swap claims its
            // scope before it suspends, so a second caller for the same scope
            // — `setProject`'s own `refreshContext` racing `observationPump`'s
            // — found it here and returned while the store was still being
            // switched, and its caller wrote rows the swap then cleared. It
            // waits for that swap instead; with none in flight, it returns.
            if layoutActivating {
                await withCheckedContinuation { layoutSwapWaiters.append($0) }
            }
            return
        }
        // **The swap is claimed before anything suspends**, which is why
        // these three lines carry no `await` between them and the guard
        // above. The guard is the whole of this method's mutual
        // exclusion: a second `activateLayout` arriving while this one is
        // mid-swap finds its own scope already installed and returns. Put
        // a suspension between the check and the claim — a flush of the
        // outgoing arrangement is the obvious candidate — and two calls
        // both pass the guard, both swap, and the first to finish clears
        // the flag while the second is still inside the window the flag
        // exists to close.
        let outgoing = layoutScope
        layoutScope = scope
        // A Send asked of a pane on the canvas being left is not one to answer on the next.
        apiSendRequests = [:]
        layoutSwapInFlight = true
        layoutActivating = true

        // **The outgoing arrangement is written before the incoming one
        // is restored** (#148), and under the name it belongs to rather
        // than the one just installed above. Everything the operator did
        // in the conversation being left has already been committed by
        // the dispatch that did it; what this catches is the last change
        // that had not, and it must be caught HERE rather than left to
        // the next commit — the next commit belongs to the incoming
        // conversation and would file it under that name.
        //
        // The comparison is `refreshLayout`'s own, so only a real change
        // costs a file. It is spelled out here rather than delegated to
        // `refreshLayout` because that method now declines to act while a
        // swap is in flight, and this is the one write that must happen
        // inside one. The store is still showing the outgoing scope —
        // nothing has switched it yet, and no other `activateLayout` can
        // be about to, per the claim above.
        if let outgoing {
            // Named, not read through `ScopeRouting.home`: the store still shows `outgoing`.
            let uncommitted = await ScopeRouting.$home.withValue(outgoing) { await layout.snapshot() }
            if uncommitted.withoutTransientState != layoutSnapshot.withoutTransientState {
                await persistLayout(uncommitted, for: outgoing)
            }
            // From here its own agent's changes reach its file (`persistBackgroundLayouts`).
            backgroundLayouts[outgoing] = uncommitted
        }
        // Left earlier this session and kept in memory: a return, which catches up below.
        let returning = backgroundLayouts[scope] != nil
        backgroundLayouts[scope] = nil

        // Re-walk finding #4: a conversation minted over the conversation-less canvas takes it.
        let adopted = adoptingCanvas && outgoing.map {
            conversationAdoptsCanvas(from: $0, to: scope)
        } == true
        if adopted, let outgoing {
            await layout.switchScope(to: scope, adoptingFrom: outgoing)
            await panes.switchScope(to: scope, adoptingFrom: outgoing)
            // Its shells too: they are keyed by the scope they were opened in.
            await terminals.rehome(from: outgoing, to: scope)
            loadedLayoutScopes.insert(scope)
        } else {
            await layout.switchScope(to: scope)
        }
        // Contents follow the arrangement. Pane ids are unique within one
        // process but not across sessions — `LayoutStore.load` raises its
        // counter only from the snapshot it is loading — so two projects
        // saved on disk can each hold a pane called `db-1`. Without this,
        // switching to project B drew project A's rows in B's `db-1`, from
        // a different project's and possibly a different environment's
        // database (final review Finding 6). Not under adoption: the contents moved with the
        // arrangement, and a listing in flight still describes them.
        if !adopted {
            // **No read in flight is stopped** (background agents 3 of 4; the spec's "in-flight
            // reads stay", ruled over the earlier "a project switch mid-read cancels it"). Every
            // place stays alive while the operator is elsewhere, and a read on the canvas left
            // behind may be that place's agent's. A restore cancels what it re-runs itself.
            await panes.switchScope(to: scope)
        }
        // The insert is last so that it only records a scope the read was
        // actually attempted for: marking one loaded while the org was
        // still unresolved would suppress the read that should follow.
        var loadedFromDisk = false
        if let persistence, !scope.organization.isEmpty, loadedLayoutScopes.insert(scope).inserted {
            // `project`, the display name, is what this window filed under before the scope
            // carried the registry key and the environment (R3): read, never written.
            let saved = persistence.load(for: scope, legacyName: project)
            if let snapshot = saved.snapshot {
                await layout.load(snapshot, for: scope)
                loadedFromDisk = true
            }
            // Degradation is visible or it is nothing: an unreadable layout
            // opens an empty canvas *and* says so, in the same place a
            // refused dispatch says so.
            if let note = saved.note { status = note }
        }
        // Read off screen with a note (`followConversation`): said now, where it is shown.
        if let note = layoutNotesAwaitingReturn.removeValue(forKey: scope) { status = note }
        // A plain read: what makes this snapshot differ from the one in
        // hand is the file that was just loaded, or another project's
        // arrangement being swapped out — neither is a change to commit.
        if let overlay { await layout.carry(overlay) }
        await readLayoutSnapshot()
        // The incoming arrangement is in hand, so the canvas belongs to
        // the new scope again and a commit means what it says. Cleared
        // before `refreshPanes` and `restorePaneContents` rather than at
        // the end of the method: those two re-run the subjects of the
        // panes just restored, and a `Pane.fetch` written by one of them
        // is a change of the incoming conversation's own that must still
        // reach its file.
        layoutSwapInFlight = false
        // The new project's panes, which for a project not yet queried is
        // an empty set — and must be drawn as one rather than left showing
        // the project that was just switched away from.
        await refreshPanes()
        // **Contents follow the arrangement off disk too** — spec §12
        // check 3: "the new org's canvas is restored from disk, each `db`
        // pane's subject re-runs live."
        //
        // A layout file persists the *subject* and never the rows, on
        // purpose (`restorePaneContents`' own doc comment: redrawing
        // yesterday's rows would show a database state that may no longer
        // exist). Loading one therefore produces panes with a frame, a
        // title and a query and nothing in them, and something has to run
        // the query. Before this, three call sites did — `WakilWindow` at
        // launch, `setEnvironment`, and the observation pump's
        // `ctx_set_environment` branch — and the org switch was none of
        // them, so every pane restored by a switch came back reading "no
        // rows". Not an error, not empty-because-empty: the designed
        // failure mode of a swallowed refetch, which is what made it
        // survive to the acceptance walk. The journal is unambiguous —
        // zero `db_refetch` rows after any org switch.
        //
        // **Gated on `loadedFromDisk`, not merely on reaching here.**
        // `LayoutStore`/`PaneStore` keep an outgoing project's contents in
        // memory so that coming back to a project finds it as it was left,
        // and that is a feature earlier sub-phases accepted. Re-running
        // every subject on an in-memory return would quietly repeal it.
        // Only a genuine read from disk has panes that hold no rows to
        // begin with, and only that case needs this.
        if loadedFromDisk || scopesAwaitingRestore.remove(scope) != nil {
            await restorePaneContents()
        } else if returning {
            await catchUpReturnedCanvas()
        }
        layoutActivating = false
        let waiters = layoutSwapWaiters
        layoutSwapWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// R4's catch-up: a canvas come back to from memory re-reads what the disk may have changed
    /// while it was off screen, because no watcher followed it there. Its editor panes re-read
    /// their open files (`paths: []`: a tab is re-read, a search is not marked stale for nothing);
    /// the window's git status is re-read by `syncGitWatcher`, whose watch starts on the returned
    /// roots (3b-iii). Rows and subjects are not re-run — the canvas is as it was left. A canvas
    /// read off disk is `restorePaneContents`' instead.
    private func catchUpReturnedCanvas() async {
        var refreshed = false
        for pane in layoutSnapshot.panes where PaneKinds.is(pane.kind, EditorPaneKind.self) {
            _ = try? await registry.dispatch(
                name: "editor_refresh", params: .object(["pane": .string(pane.id), "paths": .array([])]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            refreshed = true
        }
        if refreshed { await refreshPanes() }
    }

    /// The canvas the screen shows while its organisation has no project: the organisation's
    /// own, which is `.initial` when there is no organisation either.
    private var bareScope: LayoutScope {
        LayoutScope(organization: organization, project: "", environment: "")
    }

    /// Commits `outgoing`'s arrangement, as `activateLayout` commits the one it leaves, and
    /// shows the canvas of the organisation now on screen with no project (`bareScope`). Both stores keep `outgoing` — its panes,
    /// rows and shells — so a later `activateLayout` back to it finds it as it was left, and its
    /// own agent's changes keep reaching its file (`persistBackgroundLayouts`).
    private func putAwayCanvas(_ outgoing: LayoutScope) async {
        // A Send asked of a pane on the canvas being left is not one to answer on the next.
        apiSendRequests = [:]
        let uncommitted = await ScopeRouting.$home.withValue(outgoing) { await layout.snapshot() }
        if uncommitted.withoutTransientState != layoutSnapshot.withoutTransientState {
            await persistLayout(uncommitted, for: outgoing)
        }
        backgroundLayouts[outgoing] = uncommitted
        await showCanvas(bareScope)
    }

    /// Shows `scope`, an organisation's canvas with no project, as it is held in memory: no
    /// file is read or written for it.
    private func showCanvas(_ scope: LayoutScope) async {
        // A Send asked of a pane on the canvas being left is not one to answer on the next.
        apiSendRequests = [:]
        await layout.switchScope(to: scope)
        await panes.switchScope(to: scope)
        await readLayoutSnapshot()
        await refreshPanes()
    }

    // MARK: Controls

    /// Switches project. The canvas follows, via `refreshContext` — see
    /// `activateLayout`.
    ///
    /// It follows the *resolved* project rather than the name asked for:
    /// `wakil-ctx` is what decides which project is active, and filing a
    /// canvas under a name it refused would leave the two disagreeing.
    ///
    /// Answers whether the switch ran; a refusal is in `status`, whole.
    @discardableResult
    public func setProject(_ name: String) async -> Bool {
        guard await dispatch("ctx_set_project", .object(["name": .string(name)])) != nil else { return false }
        await refreshContext()
        return true
    }

    /// Answers whether the switch ran (a no-op switch counts as run); a refusal is in `status`,
    /// whole.
    @discardableResult
    public func setEnvironment(_ name: String) async -> Bool {
        // W12: choosing the environment already active changes nothing, so it dispatches
        // nothing — no plane, no cleared reply, no refetch.
        guard !environmentSwitchIsNoOp(from: environment, to: name) else { return true }
        // Run as a task the pump can wait on (fix round 1, item 5): `observationPump` sees this
        // dispatch too, and waits for this to finish before judging whether anything changed.
        let previous = operatorEnvironmentSwitch
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            return await self?.switchEnvironment(to: name) ?? false
        }
        operatorEnvironmentSwitch = task
        return await task.value
    }

    /// The operator's environment switch in progress, if any (fix round 1, item 5).
    @ObservationIgnored private var operatorEnvironmentSwitch: Task<Bool, Never>?

    private func switchEnvironment(to name: String) async -> Bool {
        guard await dispatch("ctx_set_environment", .object(["name": .string(name)])) != nil
        else { return false }
        // **The incoming environment's own canvas, not this one refetched** (Plan 3; operator,
        // 2026-10-16). `refreshContext` reads the new environment and `activateLayout` swaps to
        // its scope: what it holds in memory as it was left, else what it saved — re-run on the
        // way in, since a file holds no rows — else the project's legacy file (R3). D11 cleared
        // every api reply and refetched every pane here, because one canvas served every
        // environment and its rows described the one just left. Nothing on the outgoing canvas
        // describes the incoming environment now, so nothing is cleared and nothing re-run: the
        // canvas left keeps its rows and replies for the operator's return.
        await refreshContext()
        return true
    }

    /// Runs one query and refreshes the tables from the pane store.
    ///
    /// **`database` closes 2c-i's open item** that this could not name
    /// one, which made the Run query control unusable in any environment
    /// defining more than one — `runMutation` has taken a database all
    /// along and this did not.
    ///
    /// **`pane` is what makes the pointer path never spray panes.** The
    /// query line always passes its own pane, so editing and pressing
    /// Return refines in place; only a query that names no pane opens one,
    /// and nothing in the window ever omits it.
    ///
    /// The refresh happens whether or not the dispatch succeeded, because a
    /// failed query leaves the previous result on screen and the table must
    /// still agree with `PaneStore` — the same snapshot `read_pane` hands
    /// the agent. The layout is refreshed too: `db_run_query` writes
    /// `Pane.fetch`, which lives in `LayoutStore`, not `PaneStore`, and
    /// `refreshPanes` alone cannot see that.
    public func runQuery(_ query: String, database: String?, pane: String?) async {
        var params: [String: JSONValue] = ["query": .string(query)]
        if let database, !database.isEmpty { params["database"] = .string(database) }
        if let pane, !pane.isEmpty { params["pane"] = .string(pane) }
        // D12, same reasoning as `pagePane` and `refetchPane` above: only a
        // query that named a pane has a pane to mark, and `status` is read
        // right after the failed dispatch, before anything else can
        // overwrite it, so this carries the engine's own words rather than
        // a paraphrase.
        if await dispatch("db_run_query", .object(params)) == nil {
            if let pane, !pane.isEmpty { await panes.setFailure(paneId: pane, message: status) }
        }
        await refreshPanes()
        await refreshLayout()
    }

    public func pagePane(id: String, to: String) async {
        // D12. `status` is read right after the failed dispatch, before
        // anything else can overwrite it — `dispatch` has just set it to
        // `"\(name): \(error)"`, the engine's own words, and Wakil must not
        // paraphrase an error it did not generate.
        if await dispatch("db_page", .object(["pane": .string(id), "to": .string(to)])) == nil {
            await panes.setFailure(paneId: id, message: status)
        }
        await refreshPanes()
        await refreshLayout()
    }

    public func refetchPane(id: String) async {
        // D12, same reasoning as `pagePane` above.
        if await dispatch("db_refetch", .object(["pane": .string(id)])) == nil {
            await panes.setFailure(paneId: id, message: status)
        }
        await refreshPanes()
        await refreshLayout()
    }

    /// Re-reads the active environment's databases for the query line's
    /// chooser (spec §5; final review, Important 8).
    ///
    /// **It handles its own failure rather than going through
    /// `dispatch`**, the same way `paletteSource` does and for the same
    /// reason: this runs as part of every context refresh, and an
    /// environment with no `wakil-db` client — every headless test, and the
    /// documented degraded launch — would otherwise overwrite whatever
    /// `status` was actually telling the operator with a note about a
    /// control they never touched. The list simply stays as it was.
    ///
    /// The projection lives in `databaseNames(fromListResult:)`, on values,
    /// where a test can reach it.
    /// **A failure and an empty environment are told apart**, and they
    /// must be: an environment that genuinely defines no databases has to
    /// empty the chooser, or it goes on offering the previous
    /// environment's — a control naming a database this environment does
    /// not have. A dispatch that never answered leaves the list exactly as
    /// it was instead, because it learned nothing.
    public func refreshDatabases() async {
        guard let result = try? await registry.dispatch(
            name: "db_list_databases", params: .object([:]), origin: .ui,
            caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        else { return }
        databases = databaseNames(fromListResult: result)
        databaseDrivers = databaseDriverMap(fromListResult: result)
    }

    /// The fields of an api pane the operator's cursor is in (Decision 27 by focus). **Set on
    /// focus in, not through the chain**: it waits for no call the pane queued, only for the
    /// store, so the mark is down before the first pause can write. It is not synchronous with
    /// the focus-in: `focusFromSurface` starts it in an unstructured `Task`, so an agent's write
    /// already running on the store when the cursor arrives can still land first.
    ///
    /// **Added on top of what the chain holds** (`PaneStore.addApiFocus`, preflight F6): moving
    /// from A to B, A stays marked until its flush has landed. The pane queues B's own setting
    /// on the chain too (`enqueueApiFocus`), behind A's flush, and that is what releases A.
    public func noteApiFocus(pane: String, fields: Set<ApiDraftField>, generation: Int) async {
        await panes.addApiFocus(paneId: pane, fields: fields, generation: generation)
    }


    /// Opens the settings pane, or focuses the one already open, and
    /// fills it.
    ///
    /// **⌘, reaches the canvas through here and through `dispatch`**, not
    /// by touching `LayoutStore`: Invariant 2 admits no second path to a
    /// state change, and a menu item that opened a pane directly would be
    /// exactly that. The singleton is enforced in `LayoutStore
    /// .openSettings` rather than here, so `--dispatch` and a second
    /// window get it too.
    ///
    /// The read follows the open rather than the pane asking for itself,
    /// because a pane drawn before its first read has nothing to draw and
    /// a momentarily empty settings pane reads as a broken one.
    public func openSettings() async {
        guard (try? await registry.dispatch(
            name: "settings_open", params: .object([:]), origin: .ui,
            caller: DispatchCaller(place: place, session: nil), confirmation: nil)) != nil
        else { return }
        await refreshLayout()   // `settings_open` opened it full screen
        await refreshSettings()
    }

    /// Whether `name` changes what the settings pane draws.
    ///
    /// **Read off the action's kind and its owner, not a list of names.**
    /// The tree is `wakil-ctx`'s, so any `ctx_*` action that is not a read
    /// can change it — including the ones a later phase registers. The two
    /// `db_*` exceptions write `project.json` rather than a database, which
    /// is why they are named: every other `db_*` write is a customer's.
    func writesSettings(_ name: String) async -> Bool {
        guard name.hasPrefix("ctx_") || name == "db_set_dsn" || name == "db_remove_database"
                || name == "db_update_database" || name == "db_set_connection" || name.hasPrefix("api_") && name.hasSuffix("_entry")
        else { return false }
        guard let action = await registry.all().first(where: { $0.name == name }) else { return false }
        return action.kind != .read
    }

    /// Re-reads the active organisation's configuration from disk.
    ///
    /// **Called on open and after every dispatch**, which is what "the
    /// pane caches nothing" means in practice — see `settings`.
    ///
    /// **A failure and an empty organisation are told apart**, the same
    /// distinction `refreshDatabases` draws and for the same reason: a
    /// freshly created organisation genuinely has no projects, and a read
    /// that never answered has learned nothing about whether it does.
    public func refreshSettings() async {
        do {
            let result = try await registry.dispatch(
                name: "ctx_config_tree", params: .object([:]), origin: .ui,
                caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            guard let tree = decodeSettingsTree(fromResult: result) else {
                settingsFailure = "settings could not be read: the reply was not a configuration tree"
                return
            }
            settings = tree
            settingsFailure = nil
            publishAgentInstructions(tree)
            // The tree first, so the pane fills at once; finding `claude` (a login-shell lookup)
            // is for the account table below, and waits until the tree is drawn.
            await locateClaudeIfNeeded()

            // The account table, in the same refresh. **One read, two
            // halves**: the tree's Providers node and this table describe
            // the same machine, and filling them from two separate
            // refreshes would let the pane draw one organisation's
            // accounts beside another moment's configuration.
            //
            // A failure here does NOT clear the tree. The table costs a
            // Keychain lookup and a CLI spawn per row and can fail on its
            // own — a locked keychain, a `claude` that is not installed —
            // and losing the whole pane to that would be the read half
            // punishing the operator for the credential half.
            if let listing = decodeAccountListing(
                fromResult: try? await registry.dispatch(
                    name: "ctx_list_accounts", params: .object([:]), origin: .ui,
                    caller: DispatchCaller(place: place, session: nil), confirmation: nil))
            {
                accounts = listing
            }
            await capacity.refresh()
        } catch {
            settingsFailure = statusDescribingFailure("ctx_config_tree", error)
        }
    }

    /// Saves one of the organisation's four strings, then re-reads.
    ///
    /// **One field per call, and that is the read-modify-write rule made
    /// operational** (#199). Sending all three would flush the pane's own
    /// idea of the record and silently overwrite a hand edit made while
    /// the pane was open; sending only what the operator changed lets Go
    /// read the rest back off disk at the moment of the write.
    ///
    /// Returns the refusal's own sentence, or `nil` on success. Refusals
    /// are rendered **on the pane** beside the field that caused them —
    /// this phase adds no new modal — which is why this answers rather
    /// than writing to `status`: a message about the Jira site belongs
    /// under the Jira site, not in a window-wide line that outlives the
    /// form.
    public func saveOrganisationField(
        _ field: OrganisationField, to value: String, organisation: String
    ) async -> String? {
        do {
            _ = try await registry.dispatch(
                name: "ctx_update_org",
                params: .object(["id": .string(organisation), field.rawValue: .string(value)]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            await refreshSettings()
            await rebuildQuickTasks()
            if field == .gitName || field == .gitEmail {
                for root in changesIdentity.keys { await refreshChangesIdentity(root: root) }
            }
            return nil
        } catch {
            // The pane still re-reads. A refused write changed nothing,
            // but the operator is about to look at the form again and it
            // must show disk rather than the value that was rejected.
            await refreshSettings()
            return statusDescribingFailure("ctx_update_org", error)
        }
    }

    /// Re-reads the editor settings in force. A failed read keeps what the window had — the
    /// defaults until the first read lands — because an editor drawn with the defaults is
    /// usable, and a refusal here would block nothing worth blocking (Rule 8).
    public func refreshEditorSettings() async {
        guard let result = try? await registry.dispatch(
                  name: "ctx_editor_settings", params: .object([:]), origin: .ui,
                  caller: DispatchCaller(place: place, session: nil), confirmation: nil),
              let decoded = decodeEditorSettings(fromResult: result)
        else { return }
        editorSettings = decoded
    }

    /// Saves app-wide editor fields, then re-reads the tree and the settings in force. Answers
    /// the refusal's own sentence, or nil — `saveOrganisationField`'s shape.
    public func saveEditorSettings(_ fields: [String: JSONValue]) async -> String? {
        await saveEditorSettings(action: "ctx_set_editor_settings", params: .object(fields))
    }

    /// Saves one project's editor fields into its project.json. A heavy-folder change that lands
    /// re-lists every root, as a disk wake does: the list decides what each root lists (3b-v
    /// part 2). The re-list covers the active project's roots whichever project was written — a
    /// spare re-list costs one `files_list` per root, and the window does not hold project paths
    /// to compare.
    public func saveProjectEditorSettings(projectPath: String, _ fields: [String: JSONValue]) async -> String? {
        var params = fields
        params["projectPath"] = .string(projectPath)
        let refusal = await saveEditorSettings(action: "ctx_set_project_editor_settings", params: .object(params))
        if refusal == nil, fields["heavyFolders"] != nil {
            for root in gitRootPaths { await editorRootChanged(root, paths: nil) }
        }
        return refusal
    }

    /// 3a-iii-b: saves one project's agent instructions into its project.json — only the boxes
    /// passed. The re-read publishes the new text, which the agent receives in its next turn.
    public func saveProjectAgentInstructions(
        projectPath: String, general: String? = nil, commits: String? = nil, pullRequests: String? = nil
    ) async -> String? {
        var params: [String: JSONValue] = ["projectPath": .string(projectPath)]
        if let general { params["general"] = .string(general) }
        if let commits { params["commits"] = .string(commits) }
        if let pullRequests { params["pullRequests"] = .string(pullRequests) }
        do {
            _ = try await registry.dispatch(
                name: "ctx_set_project_agent_instructions", params: .object(params), origin: .ui,
                caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure("ctx_set_project_agent_instructions", error)
        }
    }

    private func saveEditorSettings(action: String, params: JSONValue) async -> String? {
        var refusal: String?
        do {
            _ = try await registry.dispatch(
                name: action, params: params, origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        } catch {
            refusal = statusDescribingFailure(action, error)
        }
        await refreshSettings()
        await refreshEditorSettings()
        // The ghost-text switch is app-wide; a project's editor fields move no quick task.
        if refusal == nil, action == "ctx_set_editor_settings" { await rebuildQuickTasks() }
        return refusal
    }

    /// Which of the organisation's four strings an edit names.
    ///
    /// An enum rather than a bare string so the pane cannot dispatch a
    /// field `update_org` does not have — a typo there is silently a
    /// no-op, which is the worst outcome a save can have.
    public enum OrganisationField: String, Sendable, CaseIterable {
        case displayName
        case jiraBase
        case defaultProvider
        case speechProvider
        case quickProvider
        case gitName
        case gitEmail
        /// 3a-iii: how Pull and Sync integrate (rebase, merge, ff-only).
        case pullStrategy
        /// 3a-iii-b: the organisation's agent instructions — General under AGENT, the other two under GIT.
        case agentGeneral
        case gitCommitInstructions
        case gitPRInstructions

        /// A stable fragment for this field's accessibility identifier —
        /// the case name, not the label, which is prose and may be
        /// reworded without meaning anything has moved.
        public var identifierFragment: String { rawValue }

        /// Whether leaving the field saves it — by focus moving on or its page going (3a-ii,
        /// Rule 2). The agent boxes are multi-line, so Return is a new line and leaving is the
        /// only save. The others keep Return and Save.
        public var savesOnLeave: Bool {
            switch self {
            case .gitName, .gitEmail, .agentGeneral, .gitCommitInstructions, .gitPRInstructions: return true
            default: return false
            }
        }

        /// What the form labels it.
        public var label: String {
            switch self {
            case .displayName: return "Display name"
            case .jiraBase: return "Jira site"
            case .defaultProvider: return "Default provider"
            case .speechProvider: return "Speech"
            case .quickProvider: return "Quick tasks"
            case .gitName: return "Git name"
            case .gitEmail: return "Git email"
            case .pullStrategy: return "Pull strategy"
            case .agentGeneral: return "General"
            case .gitCommitInstructions: return "Commits"
            case .gitPRInstructions: return "Pull requests"
            }
        }
    }

    /// Puts the add-an-account flow in front of the operator with its
    /// cost stated, and runs nothing (#202).
    ///
    /// **Nothing happens until they say so.** An operator told after the
    /// fact that this takes a minute has already spent it — so the
    /// pre-flight states the cost, and how many trips it will actually be,
    /// before a browser opens.
    ///
    /// The trip count comes from reading the derived directory's existing
    /// sign-in, which is the same signal the account table's liveness
    /// column shows. Liveness and re-entry are the same signal read twice,
    /// so the counter needs no rule of its own.
    /// The agent executable a login spawns.
    ///
    /// **Resolved from a provider record, because nothing else on this
    /// machine can answer (#238).** `executableURL` does not search PATH,
    /// and a GUI launched from Finder inherits launchd's minimal one —
    /// which does not contain `~/.local/bin`, where this machine's
    /// `claude` lives. Go already resolves the path per account for the
    /// liveness read, following a shared directory to its homing record;
    /// that resolved value now travels on the row, and this is the only
    /// absolute path the app has.
    ///
    /// The injected `providerLoginBinary` still wins when it is set, which
    /// is how a test pins a fake without a listing behind it.
    private func loginBinary() -> String {
        // **`mine` only, because Invariant 4 does not bend for a path**
        // (#271). `ctx_list_accounts` enumerates every organisation on the
        // machine — that is what `credentialLessElsewhere` and `adoptable`
        // are built on — so reading a binary off the first row with one
        // would let this organisation spawn an executable another
        // organisation recorded. `configDirForLogin` below already
        // filters; this did not, and the argument that "they all name the
        // same CLI on this machine" is exactly the kind of probable-but-
        // unenforced claim Inv 4 exists to refuse.
        return claude.loginBinary(ownBinaries: ownClaudeBinaries)
    }

    private var ownClaudeBinaries: [String] {
        accounts?.accounts.filter(\.mine).map(\.binary) ?? []
    }

    /// What the register form prefills its `claude` field with: this
    /// organisation's own record, else what the machine lookup found (#322).
    /// Never the override: the form shows the operator what Wakil would use
    /// by itself.
    public func resolvedClaudePath() -> String {
        claude.resolvedPath(ownBinaries: ownClaudeBinaries)
    }

    /// Runs the machine lookup once, off the main actor.
    public func locateClaudeIfNeeded() async {
        await claude.locateIfNeeded()
    }

    public func offerProviderLogin(id: String, kind: String, label: String = "") async {
        guard let session = providerLoginSession else { return }
        guard let configDir = await configDirForLogin(id: id) else { return }

        let existing: ProviderLoginIdentity
        if let login = try? providerLoginFactory(kind) {
            existing = await login.identity(
                configDir: configDir, binary: loginBinary())
        } else {
            existing = ProviderLoginIdentity()
        }
        await session.offer(id: id, kind: kind, label: label, existing: existing)
        providerLogin = await session.current()
    }

    /// Starts the first browser trip for the offer on screen.
    ///
    /// Returns as soon as the trip has STARTED, never when it finishes: a
    /// browser login is minutes and nothing here may wait for one.
    public func startProviderLogin() async {
        guard let session = providerLoginSession,
              case .preflight(let offer) = providerLogin
        else { return }
        guard let configDir = await configDirForLogin(id: offer.id) else { return }
        guard let login = try? providerLoginFactory(offer.kind) else {
            providerLogin = .failed(ProviderLoginError.unsupportedKind(offer.kind).description)
            return
        }
        // The mint and the commit are handed over before the trip
        // starts, because the session advances to the mint on its own —
        // there is no pause between the trips for a caller to supply
        // them in.
        addingAccountId = offer.id
        if let providerMintFactory {
            await session.use(
                mint: providerMintFactory(organization),
                commit: commitMintedProvider(id:configDir:))
        }
        let binary = loginBinary()
        guard !binary.isEmpty else {
            // **Named, rather than spawned and blamed on the filesystem.**
            // With no binary the spawn fell back to bare `claude`, which
            // `executableURL` resolves against the working directory rather
            // than searching PATH — so it failed with `NSFilePath=/claude`,
            // a path nobody configured and nothing an operator can act on
            // (#238).
            providerLogin = .failed(
                "Wakil could not find the claude executable to sign in with — no account "
                    + "here records one, and it is not in your shell's PATH or the usual "
                    + "install locations. Type its full path in the claude field and add "
                    + "the account again.")
            return
        }
        await session.start(
            id: offer.id, configDir: configDir, binary: binary,
            login: login, trips: offer.trips)
        providerLogin = await session.current()
        observeProviderLogin()
    }

    /// Writes the binding, after the credential is stored.
    ///
    /// **`nonisolated` and `@Sendable`**, because the session calls it
    /// from its own actor once the mint returns. It dispatches, which is
    /// the only path a state change may take (Invariant 2), and the
    /// dispatch is what journals the commit.
    ///
    /// Answers `nil` on refusal, which the session renders as "the
    /// credential was created and stored, but the binding could not be
    /// written" — a retry costs no browser trip, because the token is
    /// already kept.
    private nonisolated func commitMintedProvider(
        id: String, configDir: String
    ) async -> ProviderCommitOutcome {
        // **The executable the sign-in and the mint just ran** (#259).
        // Without it Go writes a binding with no `claudePath`, which
        // resolves to "" for ever once it homes its own directory:
        // `setProvider` then refuses it with "the provider record is
        // missing claudePath", and the pane has no field to repair it
        // with because an operator never types a path. Every account
        // added through the pane was born that way.
        let params = JSONValue.object([
            "id": .string(id), "configDir": .string(configDir),
            "claudePath": .string(await self.loginBinary()),
        ])
        let environment = await self.environment
        do {
            let result = try await registry.dispatch(
                name: "ctx_add_provider", params: params, origin: .ui,
                caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            guard case .object(let object) = result,
                  case .object(let structured)? = object["structuredContent"],
                  let data = try? JSONEncoder().encode(JSONValue.object(structured)),
                  let row = try? JSONDecoder().decode(Account.self, from: data)
            else { return .refused("the reply did not describe an account") }
            return .added(row)
        } catch {
            return .refused(await self.statusDescribingFailure("ctx_add_provider", error))
        }
    }

    /// Records the mint's outcome line.
    ///
    /// **The mint owes a line on its OUTCOME, and BOTH outcomes get
    /// one** (#204). Every action returns before its work finishes and an
    /// uncaught token is unrecoverable, so the journal must distinguish
    /// *minted and stored* from *a one-year credential now exists at
    /// Anthropic that Wakil never caught* — which means recording the
    /// first as well as the second, or the distinction is an absence.
    ///
    /// **The parameters carry identifiers only**, and the mark is stated
    /// as empty rather than inferred: the mint is not a registered action,
    /// so an inferred mark resolves to "unknown" and redacts the account
    /// id itself. See `ActionRegistry.journalMintOutcome`.
    private func journalMintOutcome(id: String, stored: Bool) async {
        try? await registry.journalMintOutcome(
            id: id, stored: stored, origin: .ui,
            caller: DispatchCaller(place: place, session: nil))
    }

    /// Re-authenticates an existing row, in place (#205).
    ///
    /// **This is the add flow re-entered, never a different one**, and it
    /// never skips the mint: the minted token is what launches sessions,
    /// so a sign-in-only repair leaves the account exactly as broken as it
    /// was.
    ///
    /// **The trip count comes from liveness, not from the directory
    /// existing** (`phase-2e-probe.md` §3.2, §4). Under the rejected
    /// reading — a directory that merely resolves counts as live —
    /// pressing this on a red row succeeded and LEFT THE ROW RED, because
    /// nothing on a mint-only path writes the sign-in. Liveness and
    /// re-entry are the same signal read twice, so the counter needs no
    /// rule of its own: `offerProviderLogin` reads the directory and the
    /// offer computes `1 of 1` or `2 of 2` from what came back.
    ///
    /// **A credential-less binding is repaired from the row that names
    /// it**, so diagnosis and repair are in the same place — and this is
    /// the same call, because a binding missing its credential needs
    /// exactly what a lapsed one needs: whatever trips liveness says, then
    /// the mint.
    /// **It does not stop at the pre-flight, and that is the point of the
    /// button's label** (#238). The pre-flight exists to state a cost
    /// before a browser opens; the row's own button already states it —
    /// `Re-authenticate (2 trips)` — so an operator who pressed it has
    /// read the same sentence and chosen. A second screen saying the same
    /// thing is a click between a decision and its effect.
    ///
    /// **It does not stop when the directory names somebody either**, and
    /// that exception was tried and withdrawn (#244). The argument for it
    /// was that continuing as the signed-in human is a different question
    /// from restating a cost. The answer is that the row ALREADY shows
    /// that human — the SIGN-IN column names the email — so the operator
    /// chose the row with the identity in front of them, and the
    /// pre-flight was repeating it. Re-authenticating is the one gesture
    /// whose whole purpose is "use this account again".
    ///
    /// The identity is not hidden by skipping the stop: it is in the row
    /// above the button, in the band while the trip runs, and in the
    /// table after. `Sign in as someone else` remains the way to reject
    /// it, reached from the band rather than from a question asked before
    /// anything happens.
    public func reauthenticateAccount(_ account: Account) async {
        await offerProviderLogin(
            id: account.accountId,
            kind: account.kind.isEmpty ? "claude-code" : account.kind,
            label: account.label)
        guard case .preflight = providerLogin else { return }
        await startProviderLogin()
    }

    /// Discards the sign-in the directory holds and signs in as somebody
    /// else (#205).
    ///
    /// **It asks for no confirmation**, and that is a ruling rather than
    /// an omission: it escalates nothing and is undone by the gesture that
    /// did it — one `claude auth login`, which replaces in place and
    /// upserts the same Keychain item under an unchanged name. The
    /// pane-local confirmation list has two entries and this is not one.
    ///
    /// It always costs two trips, whatever the directory currently holds:
    /// the point is that what is in there is not the account the operator
    /// wants.
    public func signInAsSomeoneElse() async {
        guard let session = providerLoginSession,
              case .preflight(let offer) = providerLogin
        else { return }
        guard let configDir = await configDirForLogin(id: offer.id) else { return }
        guard let login = try? providerLoginFactory(offer.kind) else {
            providerLogin = .failed(ProviderLoginError.unsupportedKind(offer.kind).description)
            return
        }
        addingAccountId = offer.id
        // The same handover `startProviderLogin` does, and through the
        // same factory (#204): the organisation arrives at the call, so a
        // second sign-in after a live switch mints into the organisation
        // the window is showing rather than the one it opened with.
        if let providerMintFactory {
            await session.use(
                mint: providerMintFactory(organization),
                commit: commitMintedProvider(id:configDir:))
        }
        await session.startAsSomeoneElse(
            id: offer.id, configDir: configDir, binary: loginBinary(), login: login)
        providerLogin = await session.current()
        observeProviderLogin()
    }

    /// Unlinks a binding from the organisation that holds it (#206).
    ///
    /// **Behind a pane-local confirmation, which the VIEW owns** — see
    /// `SettingsPane`. Confirmation here is pane-local, destructive-only,
    /// and never the gate, the broker or the confirmation plane: that
    /// plane renders verbatim and unelided, which is survivable for an
    /// account id and is not for #207's DSN, and one mechanism for both is
    /// what keeps the second from being the leak.
    ///
    /// A destructive action owes a pane-local confirm **only where the
    /// gate supplies none**, and `.control` actions reach no gate at all.
    /// The list ships with exactly two entries: this and the DSN write.
    /// Removing a *database* is off it — its Keychain entry is kept, so
    /// nothing is destroyed — and granting write access is off it because
    /// it escalates rather than destroys.
    ///
    /// Returns what the unlink did and could not do, or `nil` on refusal.
    public func unlinkAccount(_ account: Account) async -> UnlinkReport? {
        guard let result = try? await registry.dispatch(
            name: "ctx_unlink_provider",
            params: .object(["id": .string(account.accountId), "org": .string(account.org)]),
            origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        else {
            await refreshSettings()
            return nil
        }
        await refreshSettings()
        // **The account a window runs as can be the one just unlinked**
        // (#324). `providerId`, which the bottom-edge ACCOUNT indicator
        // draws, is only ever re-read by `refreshContext()`, so without
        // this the window went on naming an account that is no longer
        // bound. Go has already cleared the active pick; this reads it.
        if account.accountId == providerId {
            await refreshContext()
        }
        // The unlinked account may have been the quick provider or the active one (Ruling R4).
        await rebuildQuickTasks()
        return decodeUnlinkReport(fromResult: result)
    }

    /// Stores a database's connection string (#207).
    ///
    /// **The one action in this phase whose parameters carry a secret**,
    /// which is why `db_set_dsn` marks `dsn` and `writeDsn` secret-bearing:
    /// `JournalEntry.params` is written verbatim on every dispatch,
    /// refused ones included, so without the mark a database password
    /// would land in the audit log on the first attempt.
    ///
    /// **Behind a pane-local confirmation the VIEW owns**, and that
    /// confirmation renders no part of the DSN — see `SettingsPane`. The
    /// existing confirmation plane renders verbatim and unelided and would
    /// have put a password on screen, which is why this phase does not use
    /// it for either of its two confirmations.
    ///
    /// Returns the refusal's own sentence, or `nil` on success.
    public func setDatabaseDSN(
        projectPath: String, environment: String, name: String, driver: String,
        dsn: String, grantWrite: Bool = false, writeDsn: String = ""
    ) async -> String? {
        var params: [String: JSONValue] = [
            "projectPath": .string(projectPath), "environment": .string(environment),
            "name": .string(name), "driver": .string(driver), "dsn": .string(dsn),
        ]
        if grantWrite {
            params["grantWrite"] = .bool(true)
            params["writeDsn"] = .string(writeDsn)
        }
        do {
            _ = try await registry.dispatch(
                name: "db_set_dsn", params: .object(params), origin: .ui,
                caller: DispatchCaller(place: self.place, session: nil), confirmation: nil)
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure("db_set_dsn", error)
        }
    }

    /// Saves a database as its parts (2e-iv). Only the passwords are secrets, and an empty one is
    /// not sent at all — "keep the stored one" — so a blank field cannot overwrite a credential.
    ///
    /// Returns the refusal's own sentence, or `nil` on success. Settings are re-read either way.
    public func setDatabaseConnection(
        projectPath: String, environment: String, name: String, driver: String,
        connection: SettingsDatabaseConnection, password: String = "",
        grantWrite: Bool = false, writePassword: String = ""
    ) async -> String? {
        var params: [String: JSONValue] = [
            "projectPath": .string(projectPath), "environment": .string(environment),
            "name": .string(name), "driver": .string(driver),
        ]
        let parts: [(String, String)] = [
            ("host", connection.host), ("port", connection.port), ("database", connection.database),
            ("user", connection.user), ("path", connection.path),
        ]
        for (key, value) in parts where !value.isEmpty { params[key] = .string(value) }
        if !password.isEmpty { params["password"] = .string(password) }
        if grantWrite {
            params["grantWrite"] = .bool(true)
            if !connection.writeUser.isEmpty { params["writeUser"] = .string(connection.writeUser) }
            if !writePassword.isEmpty { params["writePassword"] = .string(writePassword) }
        }
        do {
            _ = try await registry.dispatch(
                name: "db_set_connection", params: .object(params), origin: .ui,
                caller: DispatchCaller(place: self.place, session: nil), confirmation: nil)
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure("db_set_connection", error)
        }
    }

    /// Drops a database from an environment, **keeping its Keychain
    /// entry** (#207).
    ///
    /// Not on the pane-local confirmation list, and that is a ruling: the
    /// credential is kept, so nothing is destroyed. The list ships with
    /// exactly two entries — the provider unlink and the DSN write.
    public func removeDatabase(
        projectPath: String, environment: String, name: String
    ) async -> String? {
        do {
            _ = try await registry.dispatch(
                name: "db_remove_database",
                params: .object([
                    "projectPath": .string(projectPath), "environment": .string(environment),
                    "name": .string(name),
                ]),
                origin: .ui, caller: DispatchCaller(place: self.place, session: nil), confirmation: nil)
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure("db_remove_database", error)
        }
    }

    // MARK: API entries and database edits (2e-iii)

    /// Whether `(projectPath, environment)` is the place on screen. The window knows its project
    /// by name; the path comes from the settings tree.
    private func isActivePlace(projectPath: String, environment: String) -> Bool {
        guard environment == self.environment,
              let project = settings?.projects.first(where: { $0.name == projectKey })
        else { return false }
        return project.path == projectPath
    }

    /// Runs one API-entry action as the operator. On success in the active place the open api
    /// panes follow: a rename re-points their drafts, and every write re-resolves them.
    private func apiEntryWrite(
        _ action: String, _ params: [String: JSONValue],
        projectPath: String, environment: String, renamedFrom: String? = nil, to newName: String? = nil
    ) async -> String? {
        let active = isActivePlace(projectPath: projectPath, environment: environment)
        do {
            _ = try await registry.dispatch(
                name: action, params: .object(params), origin: .ui,
                caller: DispatchCaller(place: self.place, session: nil), confirmation: nil)
            if active {
                if let old = renamedFrom, let new = newName {
                    for id in await panes.renameApiEntry(from: old, to: new) {
                        await layout.retitle(id: id, to: apiPaneTitle(entry: new))
                    }
                }
                await apiResolver?.reresolve(environment: environment)
                if apiResolver != nil { await refreshLayout() }
            }
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure(action, error)
        }
    }

    /// Adds or replaces an API entry. `token` is the secret (the action's `secretParams`).
    public func setApiEntry(
        projectPath: String, environment: String, name: String, baseUrl: String,
        authHeader: String? = nil, token: String? = nil
    ) async -> String? {
        var params: [String: JSONValue] = [
            "projectPath": .string(projectPath), "environment": .string(environment),
            "name": .string(name), "baseUrl": .string(baseUrl),
        ]
        if let authHeader { params["authHeader"] = .string(authHeader) }
        if let token { params["token"] = .string(token) }
        return await apiEntryWrite("api_set_entry", params, projectPath: projectPath, environment: environment)
    }

    /// Edits an API entry; nil means unchanged and is not sent.
    public func updateApiEntry(
        projectPath: String, environment: String, name: String, newName: String? = nil,
        baseUrl: String? = nil, authHeader: String? = nil, clearToken: Bool? = nil
    ) async -> String? {
        var params: [String: JSONValue] = [
            "projectPath": .string(projectPath), "environment": .string(environment),
            "name": .string(name),
        ]
        if let newName { params["newName"] = .string(newName) }
        if let baseUrl { params["baseUrl"] = .string(baseUrl) }
        if let authHeader { params["authHeader"] = .string(authHeader) }
        if let clearToken { params["clearToken"] = .bool(clearToken) }
        return await apiEntryWrite(
            "api_update_entry", params, projectPath: projectPath, environment: environment,
            renamedFrom: newName == nil ? nil : name, to: newName)
    }

    public func removeApiEntry(projectPath: String, environment: String, name: String) async -> String? {
        await apiEntryWrite(
            "api_remove_entry",
            ["projectPath": .string(projectPath), "environment": .string(environment),
             "name": .string(name)],
            projectPath: projectPath, environment: environment)
    }

    /// Renames a database or revokes its write access; nil means unchanged.
    public func updateDatabase(
        projectPath: String, environment: String, name: String, newName: String? = nil,
        revokeWrite: Bool? = nil
    ) async -> String? {
        var params: [String: JSONValue] = [
            "projectPath": .string(projectPath), "environment": .string(environment),
            "name": .string(name),
        ]
        if let newName { params["newName"] = .string(newName) }
        if let revokeWrite { params["revokeWrite"] = .bool(revokeWrite) }
        do {
            _ = try await registry.dispatch(
                name: "db_update_database", params: .object(params), origin: .ui,
                caller: DispatchCaller(place: self.place, session: nil), confirmation: nil)
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure("db_update_database", error)
        }
    }

    // MARK: Projects and environments (2e-ii)

    /// Runs one of the six project and environment actions as the operator and answers its
    /// `structuredContent`, or the failure text whole. The settings are re-read either way.
    private func projectLifecycle(
        _ action: String, _ params: [String: JSONValue]
    ) async -> (result: [String: JSONValue], error: String?) {
        do {
            let reply = try await registry.dispatch(
                name: action, params: .object(params), origin: .ui,
                caller: DispatchCaller(place: self.place, session: nil), confirmation: nil)
            if case .object(let object) = reply, case .object(let structured)? = object["structuredContent"] {
                return (structured, nil)
            }
            return ([:], nil)
        } catch {
            await refreshSettings()
            return ([:], statusDescribingFailure(action, error))
        }
    }

    /// Reads the place back off disk after a success: the Go side has already moved or picked the
    /// active place, and the window follows it.
    private func followDisk() async {
        await refreshContext()
        await refreshSettings()
    }

    /// Whether `scope` is one a rename or removal of this project (and environment, when given)
    /// touches, a conversation's included.
    private func scopeIsAffected(_ scope: LayoutScope, project: String, environment: String?) -> Bool {
        scope.organization == organization && scope.project == project
            && (environment == nil || scope.environment == environment)
    }

    /// Lets go of every canvas this window holds for a removed place, so the next `activateLayout`
    /// reads whatever is on disk instead of swapping the removed one out and writing it back under
    /// a name that is gone (a rename carries them instead: `carryScopes`). A canvas on screen is
    /// dropped without a flush: `layoutScope` goes to nil, and `activateLayout` has no outgoing
    /// arrangement to save.
    private func releaseLayouts(project: String, environment: String?) {
        let affected = { (scope: LayoutScope) in
            self.scopeIsAffected(scope, project: project, environment: environment)
        }
        loadedLayoutScopes = loadedLayoutScopes.filter { !affected($0) }
        scopesAwaitingRestore = scopesAwaitingRestore.filter { !affected($0) }
        backgroundLayouts = backgroundLayouts.filter { !affected($0.key) }
        layoutNotesAwaitingReturn = layoutNotesAwaitingReturn.filter { !affected($0.key) }
        if let shown = layoutScope, affected(shown) { layoutScope = nil }
    }

    /// Every scope this window holds anything for in memory — an arrangement, pane contents, a
    /// shell, or its own bookkeeping — that a rename or removal of the place touches.
    private func scopesInMemory(project: String, environment: String?) async -> Set<LayoutScope> {
        var all = await layout.scopes.union(panes.scopes).union(terminals.scopes)
        all.formUnion(loadedLayoutScopes)
        all.formUnion(scopesAwaitingRestore)
        all.formUnion(backgroundLayouts.keys)
        all.formUnion(layoutNotesAwaitingReturn.keys)
        if let layoutScope { all.insert(layoutScope) }
        return all.filter { scopeIsAffected($0, project: project, environment: environment) }
    }

    /// Carries everything this window holds in memory for a renamed place to the new name, through
    /// the seams a conversation minted over the canvas adopts it by (`activateLayout`): each
    /// arrangement, its panes' contents (an unsaved tab among them) and its running shells. Left
    /// under the old key they were unreachable — a dev server's shell running unseen, a dirty tab a
    /// quit would name under a place that no longer exists (final review Important 1).
    ///
    /// **The screen's scope goes last.** Each seam also puts its store's screen on the scope it
    /// adopts into, so the stores end on the screen's new key; a rename that does not touch the
    /// screen puts them back on it. Until then the stores show a canvas that is not the place's,
    /// so the moves run under `layoutSwapInFlight`: the observation pump's refresh after the
    /// rename's own dispatch would otherwise publish and commit a half-moved canvas — measured, an
    /// empty one under load.
    private func carryScopes(
        project: String, environment: String?, renamed: (LayoutScope) -> LayoutScope
    ) async {
        let affected = await scopesInMemory(project: project, environment: environment)
        guard !affected.isEmpty else { return }
        let outerSwap = layoutSwapInFlight
        layoutSwapInFlight = true
        let screen = await panes.screenScope
        let order = affected.filter { $0 != screen } + (affected.contains(screen) ? [screen] : [])
        for from in order {
            let to = renamed(from)
            await layout.switchScope(to: to, adoptingFrom: from)
            await panes.switchScope(to: to, adoptingFrom: from)
            await terminals.rehome(from: from, to: to)
        }
        if !affected.contains(screen) {
            await layout.switchScope(to: screen)
            await panes.switchScope(to: screen)
        }
        func carried(_ scope: LayoutScope) -> LayoutScope { affected.contains(scope) ? renamed(scope) : scope }
        loadedLayoutScopes = Set(loadedLayoutScopes.map(carried))
        scopesAwaitingRestore = Set(scopesAwaitingRestore.map(carried))
        backgroundLayouts = Dictionary(backgroundLayouts.map { (carried($0.key), $0.value) }) { new, _ in new }
        layoutNotesAwaitingReturn = Dictionary(layoutNotesAwaitingReturn.map { (carried($0.key), $0.value) }) { new, _ in new }
        layoutScope = layoutScope.map(carried)
        layoutSwapInFlight = outerSwap
        guard !outerSwap else { return }
        // What a refresh skipped meanwhile, read now the canvas is the place's again.
        await readLayoutSnapshot()
        await refreshPanes()
    }

    /// Moves each conversation of the renamed place that has no live session to the new name
    /// (`PlaceAgent.place`), so its conversation — what its canvas is filed under — and its thread
    /// come along rather than vanishing with the old key: every one of them, the place's
    /// background conversations as well as the one on screen (conversations 2 of 3). The screen's
    /// entry (`screenConversations`), the id reserved for the place's next conversation
    /// (`reservedConversations`) and the Landing's baseline (`landingBaselines`) move each on its
    /// own, and every socket opened for a carried id is stopped and opened again answering for the
    /// new place, under the same id (`ShownSocket`), so `openShownSocket` finds it there and the
    /// session that takes it answers for the place that exists. A live one cannot be here: the
    /// rename is refused while an agent runs in the place (Invariant 5). A reservation or baseline
    /// whose new place already holds one is left where it is; a screen conversation whose new
    /// place already shows one joins it in the background.
    private func carryAgents(project: String, environment: String?, renamed: (Place) -> Place) {
        func isRenamed(_ p: Place) -> Bool {
            p.organization == organization && p.project == project
                && (environment == nil || p.environment == environment)
        }
        var moved: [String: (from: Place, to: Place)] = [:]
        for agent in conversations.values where agent.harness == nil && isRenamed(agent.place) {
            let from = agent.place
            agent.place = renamed(from)
            moved[agent.id] = (from, agent.place)
        }
        for from in Set(screenConversations.keys).union(reservedConversations.keys)
            .union(landingBaselines.keys).filter(isRenamed) {
            let to = renamed(from)
            // Its conversation is `to`'s now; it is that place's screen unless `to` has one.
            if let id = screenConversations[from], moved[id] != nil {
                screenConversations[from] = nil
                if screenConversations[to] == nil { screenConversations[to] = id }
            }
            if let id = reservedConversations[from], reservedConversations[to] == nil {
                reservedConversations[from] = nil
                reservedConversations[to] = id
                moved[id] = (from, to)
            }
            if let baseline = landingBaselines[from], landingBaselines[to] == nil {
                landingBaselines[from] = nil
                landingBaselines[to] = baseline
            }
        }
        for (id, move) in moved {
            guard let shown = shownSockets[id], shown.place == move.from else { continue }
            // Its caller is fixed when it opens (`openSocket`), so relabelling it would leave
            // every call on it answering for the place that no longer exists (Invariant 4).
            // Stopped, then opened again for the new place under the same id — in that
            // order, so the path is free before the new one binds it.
            let factory = agentSocketFactory
            let sessionId = shown.sessionId
            let to = move.to
            let reopening = Task { () -> OpenedSocket in
                await shown.opening.value.socket?.stop()
                return await Self.openSocket(factory, in: to, sessionId: sessionId, conversation: id)
            }
            shownSockets[id] = ShownSocket(sessionId: sessionId, place: to, opening: reopening)
        }
    }

    /// The refusal a removal gives while the place holds unsaved editor tabs, on screen or in any
    /// canvas of it kept in memory (controller ruling, final review Important 1): removing it would
    /// leave them where nothing reaches them. The files are named, whole (Rule 8).
    private func unsavedTabsRefusal(removing name: String, project: String, environment: String?) async -> String? {
        let organization = organization
        return await unsavedTabsRefusal(naming: name) { scope in
            scope.organization == organization && scope.project == project
                && (environment == nil || scope.environment == environment)
        }
    }

    /// The refusal for losing the unsaved editor tabs of every canvas `include` takes, said as
    /// `name` holding them: a removal's place (above), or a closed conversation's canvas
    /// (`closeConversation`). Nil when none is unsaved.
    private func unsavedTabsRefusal(
        naming name: String, where include: @escaping @Sendable (LayoutScope) -> Bool
    ) async -> String? {
        let titles = await panes.editorDirtyTabTitles(where: include)
        guard !titles.isEmpty else { return nil }
        return "\(name) has unsaved changes in \(titles.joined(separator: ", ")) — save or close them first."
    }

    /// Closes every conversation of a removed place (plan 3, ruling 5), without asking: each is
    /// idle — the removal was refused while any of them ran (Invariant 5) — so nothing in flight is
    /// lost. Each ends as Close Conversation ends one (`endConversation`), its session in its
    /// place's Continue, except that nothing is shown after it and nothing is written back: the
    /// place is gone.
    private func closeConversations(project: String, environment: String?) async {
        let organization = organization
        for agent in liveConversations() where agent.place.organization == organization
            && agent.place.project == project && (environment == nil || agent.place.environment == environment) {
            await endConversation(agent, placeRemoved: true)
        }
    }

    /// Drops what a removed place's Landing held (final review M1), as `carryAgents` moves it on a
    /// rename: the id it reserved for its next conversation (`reservedConversations`), its
    /// baseline (`landingBaselines`, and `landingsLoading`'s entry), and every socket opened for
    /// it that no session took (`shownSockets`), stopped — otherwise it listens until quit,
    /// answering for a place that no longer exists, and a place added again under the same name
    /// would find the old baseline.
    private func dropLandings(project: String, environment: String?) async {
        func isRemoved(_ p: Place) -> Bool {
            p.organization == organization && p.project == project
                && (environment == nil || p.environment == environment)
        }
        for removed in Set(reservedConversations.keys).union(landingBaselines.keys).filter(isRemoved) {
            reservedConversations[removed] = nil
            landingBaselines[removed] = nil
            landingsLoading.remove(removed)
        }
        for (id, shown) in shownSockets where isRemoved(shown.place) {
            shownSockets.removeValue(forKey: id)
            await shown.opening.value.socket?.stop()
        }
    }

    /// Kills the shells of every canvas of a removed place: nothing can reach them any more.
    private func closeShells(project: String, environment: String?) async {
        for scope in await scopesInMemory(project: project, environment: environment) {
            await terminals.close(scope: scope)
        }
    }

    /// A refusal whose control is no longer on screen — a Settings Name field left by moving to
    /// another page, refused after its page went — said here so it is not dropped (Rules 2, 8).
    public func showUnseenRefusal(_ text: String) {
        status = text
    }

    /// 3a-iii-a: Clone from a link…, then the clone becomes a project as a chosen folder does.
    public func cloneProject(link: String, into folder: String) async -> (name: String?, error: String?) {
        let reply: JSONValue
        do {
            reply = try await registry.dispatch(
                name: "editor_clone", params: .object(["url": .string(link), "folder": .string(folder)]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        } catch {
            return (nil, statusDescribingFailure("editor_clone", error))
        }
        guard case .object(let o) = reply, case .string(let path)? = o["path"] else {
            return (nil, "editor_clone: the clone answered no path")
        }
        return await createProject(folder: path)
    }

    /// Adds a project from a folder. The name defaults to the folder's last path component.
    public func createProject(folder: String) async -> (name: String?, error: String?) {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        let reply = await projectLifecycle(
            "ctx_create_project", ["folder": .string(folder), "name": .string(name)])
        if let error = reply.error { return (nil, error) }
        await followDisk()
        if case .string(let created)? = reply.result["name"] { return (created, nil) }
        return (name, nil)
    }

    /// Renames a registered project. Its saved arrangements move with it, and so does what is in
    /// memory — canvases, shells, unsaved tabs, an agent's conversation — so the panes come back.
    public func renameProject(_ old: String, to new: String) async -> String? {
        // What is on screen is saved first, so the move carries it.
        if let shown = layoutScope, scopeIsAffected(shown, project: old, environment: nil) {
            await persistLayout()
        }
        let reply = await projectLifecycle("ctx_rename_project", ["name": .string(old), "newName": .string(new)])
        if let error = reply.error { return error }
        do {
            try persistence?.renameProject(organization: organization, from: old, to: new)
        } catch {
            status = "layout move: \(error)"
        }
        // What is in memory follows the files, before the window reads the place back.
        await carryScopes(project: old, environment: nil) {
            LayoutScope(organization: $0.organization, project: new, environment: $0.environment,
                        lineageRoot: $0.lineageRoot)
        }
        carryAgents(project: old, environment: nil) {
            Place(organization: $0.organization, project: new, environment: $0.environment)
        }
        await followDisk()
        return nil
    }

    /// Removes a project from the registry; its folder is left alone. Refused while any of its
    /// canvases holds an unsaved tab; its shells are closed.
    public func removeProject(_ name: String) async -> String? {
        if let refusal = await unsavedTabsRefusal(removing: name, project: name, environment: nil) {
            return refusal
        }
        let reply = await projectLifecycle("ctx_remove_project", ["name": .string(name)])
        if let error = reply.error { return error }
        await closeConversations(project: name, environment: nil)
        await dropLandings(project: name, environment: nil)
        await closeShells(project: name, environment: nil)
        releaseLayouts(project: name, environment: nil)
        await followDisk()
        return nil
    }

    /// Adds an environment to a project; `wakil-ctx` picks the name.
    public func createEnvironment(
        project: String, projectPath: String
    ) async -> (name: String?, error: String?) {
        let reply = await projectLifecycle(
            "ctx_create_environment", ["project": .string(project), "projectPath": .string(projectPath)])
        if let error = reply.error { return (nil, error) }
        await followDisk()
        if case .string(let created)? = reply.result["name"] { return (created, nil) }
        return (nil, nil)
    }

    /// Renames an environment. Its saved arrangements move with it, and what is in memory too, as
    /// `renameProject`.
    public func renameEnvironment(
        project: String, projectPath: String, _ old: String, to new: String
    ) async -> String? {
        if let shown = layoutScope, scopeIsAffected(shown, project: project, environment: old) {
            await persistLayout()
        }
        let reply = await projectLifecycle(
            "ctx_rename_environment",
            ["project": .string(project), "projectPath": .string(projectPath),
             "name": .string(old), "newName": .string(new)])
        if let error = reply.error { return error }
        do {
            try persistence?.renameEnvironment(organization: organization, project: project, from: old, to: new)
        } catch {
            status = "layout move: \(error)"
        }
        await carryScopes(project: project, environment: old) {
            LayoutScope(organization: $0.organization, project: $0.project, environment: new,
                        lineageRoot: $0.lineageRoot)
        }
        carryAgents(project: project, environment: old) {
            Place(organization: $0.organization, project: $0.project, environment: new)
        }
        await followDisk()
        return nil
    }

    /// Removes an environment; its file goes to the Trash. Removing the one on screen lands the
    /// window on the first that remains (`wakil-ctx` picks it), through the same swap as a switch.
    /// Refused while it holds an unsaved tab; its shells are closed.
    public func removeEnvironment(
        project: String, projectPath: String, _ name: String
    ) async -> (receipt: String?, error: String?) {
        if let refusal = await unsavedTabsRefusal(removing: name, project: project, environment: name) {
            return (nil, refusal)
        }
        let reply = await projectLifecycle(
            "ctx_remove_environment",
            ["project": .string(project), "projectPath": .string(projectPath), "name": .string(name)])
        if let error = reply.error { return (nil, error) }
        await closeConversations(project: project, environment: name)
        await dropLandings(project: project, environment: name)
        await closeShells(project: project, environment: name)
        releaseLayouts(project: project, environment: name)
        await followDisk()
        return ("Removed \(name) — a copy of project.json is in the Trash", nil)
    }

    /// Cancels the browser trip that is running.
    ///
    /// **Trip 1's cancel is free and says so** — the only provably clean
    /// cancel in the flow. The session decides what the claim is; this
    /// just asks.
    public func cancelProviderLogin() async {
        guard let session = providerLoginSession else { return }
        await session.cancel()
        providerLogin = await session.current()
    }

    /// Stops waiting for the mint (#240).
    ///
    /// **Not a cancel, and the surface must not call it one.** Nothing is
    /// undone; Wakil stops listening and says a credential may already
    /// exist. See `ProviderLoginSession.stopWaitingForMint`.
    public func stopWaitingForMint() async {
        guard let session = providerLoginSession else { return }
        await session.stopWaitingForMint()
        providerLogin = await session.current()
    }

    /// Takes the band off the pane.
    public func dismissProviderLogin() async {
        guard let session = providerLoginSession else { return }
        // `abandon`, not `dismiss`: dismissing the band DURING the capture
        // step is abandoning between the trips, and that owes the trip-2
        // claim — the sign-in is kept, and a credential may already exist
        // that Wakil did not catch. Everywhere else it is an ordinary
        // dismiss.
        await session.abandon()
        providerLogin = await session.current()
        await refreshSettings()
    }

    /// Mirrors the session's states onto this model, so the band redraws.
    ///
    /// One observer at a time: starting a second trip re-enters `start`,
    /// which the session itself refuses while one is running.
    private func observeProviderLogin() {
        guard let session = providerLoginSession else { return }
        providerLoginObserver?.cancel()
        providerLoginObserver = Task { [weak self] in
            for await state in await session.states() {
                guard let self else { return }
                await MainActor.run { self.providerLogin = state }
                // **The mint's outcome line, for BOTH outcomes.** The id
                // comes from the account being added rather than from the
                // state: `.uncertain` carries a sentence and `.added`
                // carries a row, and reading either back off
                // `providerLogin` would read the state just assigned.
                if case .uncertain = state {
                    await self.journalMintOutcome(
                        id: await self.addingAccountId, stored: false)
                }
                if case .added = state {
                    await self.journalMintOutcome(
                        id: await self.addingAccountId, stored: true)
                }
                if case .signedIn = state {
                    // The table's liveness column is now stale for this
                    // account: a trip that just succeeded is exactly when
                    // the row must stop saying "signed out".
                    await self.refreshSettings()
                }
            }
        }
    }

    /// The derived config dir for `id`, through the action — so the string
    /// the spawn uses is the one Go resolved, and there is no second
    /// derivation to disagree with it.
    /// The directory a login, a mint or a re-authentication must run in.
    ///
    /// **A registered account's own directory wins; the derivation is only
    /// for an id nothing holds yet** (#244).
    ///
    /// `DeriveConfigDir` answers `~/.claude-<id>`, which is right for a
    /// NEW account and wrong for every existing one — and the ids on this
    /// machine make it wrong constantly, because the account is the
    /// directory and the id is not: `personal/main` lives in
    /// `~/.claude-personal`, `personal/work` in `~/.claude-initech`.
    ///
    /// Using the derivation for a re-authentication sent every trip into a
    /// directory the account has nothing to do with. Measured on this
    /// machine after several attempts: `~/.claude-main` had been created
    /// and signed in as the operator, while `~/.claude-personal` — the
    /// account being repaired — was still signed out. The row therefore
    /// stayed red no matter how many times the flow "succeeded", and the
    /// pre-flight read the fresh directory and announced the operator was
    /// already signed in, which was true of a directory nobody had asked
    /// about.
    ///
    /// The row already carries the answer and the pane already draws it.
    private func configDirForLogin(id: String) async -> String? {
        if let recorded = accounts?.accounts.first(where: { $0.mine && $0.accountId == id })?
            .configDir, !recorded.isEmpty {
            return recorded
        }
        return await deriveProviderConfigDir(id: id)
    }

    private func deriveProviderConfigDir(id: String) async -> String? {
        guard let result = try? await registry.dispatch(
            name: "ctx_provider_login", params: .object(["id": .string(id)]),
            origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil),
            case .object(let fields) = result,
            case .string(let configDir)? = fields["configDir"], !configDir.isEmpty
        else {
            providerLogin = .failed(status.isEmpty ? "the config dir could not be derived" : status)
            return nil
        }
        return configDir
    }

    /// Points `pane`'s query line at `database`, for its next run.
    ///
    /// **This is the control 2c-i's open item asked for**: until it
    /// existed, a pane could only ever run against a database it had
    /// inherited from whoever last wrote its subject, so an operator
    /// facing an environment with two databases had no way to reach the
    /// second one except through the agent. It works on a pane with no
    /// fetch at all, which is the fresh-⌘K-pane case acceptance check 3
    /// walks.
    ///
    /// It runs nothing. Choosing a database is not asking a question; the
    /// next Return is.
    public func chooseDatabase(_ database: String, pane: Pane) {
        databaseChoices[pane.id] = QueryLineDatabaseChoice(
            database: database, subjectDatabase: pane.fetch?.query.database)
    }

    /// The database `pane`'s next run goes against — the operator's own
    /// choice while it is still current, the pane's subject otherwise. What
    /// the chooser shows and what `runFromQueryLine` sends.
    public func databaseForQueryLine(pane: Pane) -> String? {
        queryLineDatabase(choice: databaseChoices[pane.id], subject: pane.fetch?.query)
    }

    /// The query line's dialect: Mongo's JSON spec, or SQL for every other driver.
    public func queryDialect(pane: Pane) -> QueryDialect {
        guard let name = databaseForQueryLine(pane: pane) else { return .sql }
        return databaseDrivers[name] == "mongo" ? .mongo : .sql
    }

    /// Asks whether a statement is a read, a mutation, or neither, without
    /// running it. Returns the kind and, for "neither", the gate's own
    /// sentence.
    ///
    /// **The query line calls this before it runs anything**, so the
    /// operator who types an `UPDATE` gets the confirmation plane rather
    /// than a refusal to dismiss. Nothing here parses SQL: the answer
    /// comes from the same gates that judge the statement for real.
    public func classifyStatement(
        _ statement: String, database: String?
    ) async -> (kind: String, reason: String) {
        var params: [String: JSONValue] = ["statement": .string(statement)]
        if let database, !database.isEmpty { params["database"] = .string(database) }
        let result = await dispatch("db_classify_statement", .object(params))
        guard case .object(let obj) = result,
              case .object(let structured)? = obj["structuredContent"] else {
            // A failed classification runs nothing. Guessing "read" here
            // would send an UPDATE to db_run_query, where the gate refuses
            // it — no harm done, but the operator would be told the wrong
            // story about why.
            return ("neither", "could not judge this statement")
        }
        let kind: String = { if case .string(let k)? = structured["kind"] { return k }
                             return "neither" }()
        let reason: String = { if case .string(let r)? = structured["reason"] { return r }
                               return "" }()
        return (kind, reason)
    }

    /// Re-runs every restored pane's own query, once, at window
    /// construction.
    ///
    /// **Contents are not persisted and must not be** — redrawing
    /// yesterday's rows would show a database state that may no longer
    /// exist, the exact dishonesty `truncated` and the sort footer exist to
    /// prevent. What persists is the *subject*, and re-running it is how a
    /// restored pane comes back showing something true.
    ///
    /// **This means launching Wakil issues queries on its own.** Operator's
    /// ruling, 2026-09-12, with the alternative (restore the query and wait
    /// for Return) in front of them. Every one of these passes the
    /// read-only gate, so nothing is written; what is spent is load and
    /// time, and on `production` with several panes open that is several
    /// unasked-for reads the instant the app opens. Recorded as an open
    /// item in the spec §15 so that gating it by environment later is a
    /// change of mind rather than a discovery.
    ///
    /// Failures are swallowed per pane: a pane whose table was dropped
    /// since the layout was saved comes back empty, and one bad subject
    /// must not stop the others.
    public func restorePaneContents() async {
        // A restore re-runs every pane's subject; a read still in flight would refuse it
        // (Interaction Rule 5) and the pane would keep the environment just left. Cancelled first —
        // only on the panes about to re-run, in the scope being restored: any other read is left
        // to land (background agents 3 of 4).
        for pane in layoutSnapshot.panes {
            guard let kind = PaneKinds.kind(named: pane.kind),
                  (kind as? PaneRestorable.Type)?.restoreStep(for: pane) != nil else { continue }
            _ = await panes.cancelDBRead(paneId: pane.id)
        }
        // The editor's watch starts before `editor_restore` runs (3b-ii), so the restored panes
        // share one kept listing per root instead of each listing every root fresh. Inside
        // `activateLayout` the swap's own layout read came too early to start it.
        await syncEditorWatcher()
        // 9b W1: every api pane's entry, re-resolved by name against the environment now active,
        // before anything else is restored. This covers launch, a switch and an org switch
        // loaded from disk. The draft is kept and nothing is sent.
        await apiResolver?.reresolve(
            environment: environment,
            restored: layoutSnapshot.panes.filter { PaneKinds.is($0.kind, ApiPaneKind.self) }.map(\.id))
        // W8: a pane the re-resolve pointed at another entry was retitled in the layout store;
        // re-read it, so launch and an org switch draw the title too, not only the paths a
        // dispatch's own refresh follows.
        if apiResolver != nil { await refreshLayout() }
        // **Classified, not compared** (#181). This read `where pane.kind == "db" && pane.fetch != nil`,
        // a negative test that silently skipped every other kind. Each kind names its own step
        // (`PaneRestorable`); the loop names none. A kind with no entry in `PaneKinds` is
        // skipped, the safe direction. D12: `status` is read per pane, because each dispatch
        // overwrites it.
        for pane in layoutSnapshot.panes {
            guard let kind = PaneKinds.kind(named: pane.kind), let step = (kind as? PaneRestorable.Type)?.restoreStep(for: pane) else { continue }
            if await dispatch(step.action, step.params) == nil, step.recordsFailure {
                await panes.setFailure(paneId: pane.id, message: status)
            }
        }
        await refreshPanes()
    }

    /// Runs one mutation. It will not execute until the operator confirms
    /// it in the plane — see `dispatch`.
    ///
    /// **It does not draw the mutation's output**, which is why this is not
    /// `runQuery`: a mutation returns no rows, and re-reading the pane's
    /// result into the grid would put a fabricated shape on a surface
    /// Invariant 3 promises reflects what is on screen.
    ///
    /// **It does refetch `pane`'s own subject afterwards (D8b).**
    /// `refetchPane` re-runs `Pane.fetch` — still `events`, not the
    /// UPDATE — so the pane shows the same subject against the state the
    /// mutation just produced. Every mutation is typed into some pane's
    /// query line — `runFromQueryLine` is the only caller, and it always
    /// holds a concrete `Pane` — so there is always a pane to re-read;
    /// `pane` is not optional because there is no caller for which it
    /// could be absent.
    ///
    /// **Only when it ran.** `dispatch` returns `nil` for a refusal and for
    /// a cancel alike, and the `guard` is the whole distinction: redrawing
    /// after a cancel would teach the operator that cancelling does
    /// something.
    public func runMutation(_ statement: String, database: String?, pane: String) async {
        var params: [String: JSONValue] = ["statement": .string(statement)]
        if let database { params["database"] = .string(database) }
        guard await dispatch("db_run_mutation", .object(params)) != nil else { return }
        // The write supersedes a read in flight: left running, it would refuse this refetch and
        // then land the pre-write rows (final review, Important 1).
        _ = await panes.cancelDBRead(paneId: pane)
        await refetchPane(id: pane)
    }

    /// The outcome of a cell edit, so the view knows whether to leave edit
    /// mode.
    ///
    /// **`.refused` and `.cancelled` are distinct even though the view
    /// treats them alike** — both keep the operator's typed text — because
    /// they are different events and a later change to either must not
    /// silently change the other. That is D7's lesson at close range: here
    /// the discarded text would be the value the operator just entered.
    public enum CellEditOutcome: Sendable, Equatable {
        case committed
        case refused(String)
        case cancelled
    }

    /// What Enter in an edited cell does.
    ///
    /// **Two round trips, and neither is optional.** The first,
    /// `db_render_update`, composes the statement in Go — where the
    /// dialect's quoting, the server's backslash mode and the column's own
    /// type live — and runs nothing; it is a `.read` action for exactly
    /// that reason. The second is `runMutation`'s own action,
    /// `db_run_mutation`, unchanged: the same `writeGate`, the same
    /// confirmation plane and the same production block a statement typed
    /// into the query line takes. Enter **requests** confirmation here; it
    /// does not supply it.
    ///
    /// **It composes no SQL and reads none.** `rowKey` came from the pane's
    /// own `PaneEditable` (by way of `editableCell`, before this is ever
    /// called) and goes back to the driver untouched; the statement handed
    /// to `db_run_mutation` is whatever Go answered — never rebuilt, never
    /// inspected.
    ///
    /// **Refuses before the first round trip when the pane reports no
    /// table.** `editableCell` is what decided this cell could be edited
    /// at all, and it reads `PaneEditable` from the same `PaneStore` this
    /// does; asking again here rather than trusting the caller keeps the
    /// rule in one place, and catches the pane an agent re-pointed at a
    /// non-editable subject between the double-click and the Enter key.
    ///
    /// **`rowKey` and `column` are checked for membership in that same
    /// `PaneEditable`, not just `table` — Fix Round 1 of the acceptance
    /// review, 2026-09-13.** `rowKey` and `column` arrive as parameters
    /// captured at the double-click, not re-read here, so a `table` that
    /// is fresh can still be paired with a `rowKey` from whatever the pane
    /// showed before an agent re-pointed it. `db_render_update`'s own
    /// description says plainly that it does not cross-check a `rowKey`
    /// against the `table` it is handed — "a rowKey paired with the wrong
    /// table composes a well-formed UPDATE against that other table's
    /// row" — so the only thing standing between that and a wrong-row
    /// write would otherwise be the confirmation plane, which shows the
    /// operator a statement, not the mismatch that produced it. This is a
    /// value comparison against the same store `editableCell` already
    /// trusted, not SQL inspection: it does not touch the no-SQL-in-Swift
    /// rule any more than the `table` guard already didn't.
    public func commitCellEdit(
        pane: Pane, rowKey: String, column: String, columnType: String?, value: String
    ) async -> CellEditOutcome {
        guard let editable = await panes.editable(paneId: pane.id), !editable.table.isEmpty
        else {
            return .refused("these rows cannot be written back to a single table")
        }
        guard editable.rowKeys.contains(rowKey), editable.columns.contains(column) else {
            // The pane no longer shows what was double-clicked — reordered,
            // re-fetched, or re-pointed at another table entirely — so the
            // row key captured then is no longer known to belong to this
            // table's rows now. Refusing here is the same rule
            // `editableCell` enforces before offering the editor in the
            // first place, asked again because time passed between that
            // decision and this one.
            return .refused("this cell no longer matches what is on screen")
        }
        var params: [String: JSONValue] = [
            "table": .string(editable.table),
            "rowKey": .string(rowKey),
            "column": .string(column),
            "value": .string(value),
        ]
        if let columnType, !columnType.isEmpty { params["columnType"] = .string(columnType) }
        // Deliberately NOT `databaseForQueryLine(pane:)`. That method
        // answers a different question — "where does the next TYPED
        // statement go" — and folds in the operator's pending chooser
        // pick for exactly that purpose (`runFromQueryLine`'s own
        // comment). A cell edit is not a typed statement; `table`,
        // `rowKey` and every value on screen came from `pane.fetch`, so
        // the edit belongs to the database THOSE rows came from. Using
        // the query line's pending choice here would let an operator who
        // picks a different database from the chooser — without pressing
        // Enter — have their next cell edit run against that other
        // database while `table` and `rowKey` still name a row in the one
        // actually on screen: a well-formed `UPDATE` against the wrong
        // database's table.
        let database = pane.fetch?.query.database
        if let database, !database.isEmpty { params["database"] = .string(database) }

        guard let rendered = await dispatch("db_render_update", .object(params)) else {
            // `status` is the driver's own last failure sentence, never a
            // second wording composed in Swift — the discipline
            // `classifyStatement` established for exactly this reason.
            // `db_render_update` is a `.read` action, so `dispatch` cannot
            // have parked it: a `nil` here is always a thrown error, never
            // a cancel, so `.refused` is unconditionally the right case.
            return .refused(status)
        }
        // A successful dispatch with no usable statement is still a
        // refusal, not a crash: a driver that answered with an empty or
        // malformed `structuredContent` has not actually composed
        // anything to run.
        guard case .object(let obj) = rendered,
              case .object(let structured)? = obj["structuredContent"],
              case .string(let statement)? = structured["statement"],
              !statement.isEmpty
        else {
            return .refused("could not compose the update")
        }

        var mutateParams: [String: JSONValue] = ["statement": .string(statement)]
        if let database, !database.isEmpty { mutateParams["database"] = .string(database) }

        // Unlike the render round trip above, `db_run_mutation` IS a
        // `.mutate` action, so its `nil`-producing paths are not all the
        // same kind of nothing: the production block, a handler error, an
        // expired or busy confirmation and a blank-statement guard are all
        // refusals with the gate's own sentence to show, and only an
        // operator who actually typed something other than "confirm" (or
        // tapped cancel) produced a real cancel. `dispatchMutation` keeps
        // that distinction; the plain `dispatch(_:_:)` above collapses it
        // to `nil` for every OTHER caller, none of which reports an
        // outcome to the operator the way a cell edit does.
        switch await dispatchMutation("db_run_mutation", .object(mutateParams)) {
        case .ran:
            // Only a confirmed run re-fetches the pane (D8b) — redrawing
            // after a cancel would teach the operator that cancelling
            // does something. A read in flight is superseded, as in `runMutation`.
            _ = await panes.cancelDBRead(paneId: pane.id)
            await refetchPane(id: pane.id)
            return .committed
        case .refused(let reason):
            return .refused(reason)
        case .cancelled:
            return .cancelled
        }
    }

    /// What Return in a pane's query line does.
    ///
    /// **It asks before it runs.** An operator who types an `UPDATE` gets
    /// the confirmation plane, not a refusal to dismiss — and the decision
    /// is made by `AssertSQLReadOnly` and `AssertSQLMutation`, the same two
    /// functions that will judge the statement for real, reached here only
    /// through `classifyStatement`. Nothing here parses SQL: a Swift-side
    /// classifier would be a second answer to a security-relevant question,
    /// and the first time the two disagreed, the disagreement would be the
    /// bug.
    ///
    /// **An unchanged, non-SQL subject re-runs as itself, not as text.** A
    /// pane showing `tables` has a query line reading "tables", and
    /// pressing Return on it unchanged must re-list the tables rather than
    /// send the word "tables" to the engine — so that one case is checked
    /// FIRST and returns early. Everything else — the line was edited, or
    /// the subject is (and stays) `.sql` — falls through to classification:
    /// re-running an untouched `SELECT 1` is still a statement, and must be
    /// judged like one every time, not waved through because it looks
    /// unchanged.
    public func runFromQueryLine(_ text: String, pane: Pane) async {
        // Only THIS pane's entry — never the whole dictionary. A refusal
        // raised by another pane's line must survive a run in this one.
        queryLineRefusals.removeValue(forKey: pane.id)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The operator's own choice if they made one, and the pane's
        // subject otherwise — see `databaseForQueryLine(pane:)`. This is
        // the only place the query line decides which database a statement
        // is sent to, so the chooser and the run cannot disagree.
        let database = databaseForQueryLine(pane: pane)

        if let fetch = pane.fetch, trimmed == fetch.query.describedForOperator {
            if case .sql = fetch.query {
                // An unchanged SQL subject. Do NOT return early — it still
                // has to pass classification below like any other statement.
            } else {
                await refetchPane(id: pane.id)
                return
            }
        }

        let (kind, reason) = await classifyStatement(trimmed, database: database)
        switch kind {
        case "read":
            await runQuery(trimmed, database: database, pane: pane.id)
        case "mutation":
            // `.mutate`, so `ActionRegistry.dispatch` parks it in the
            // broker and 2b-iii's confirmation plane rises. The pane's rows
            // and subject are untouched either way: a mutation returns a
            // `Written`, not a `Rows`, and projecting a row count into a
            // grid would put a fabricated shape on a surface Invariant 3
            // promises reflects what is on screen.
            await runMutation(trimmed, database: database, pane: pane.id)
            await restoreQueryLine(pane: pane.id)
        default:
            // **Final review, Critical 1: no `restoreQueryLine` here.**
            // `DBPane.onChange(of: restore)` sets `text = new.text`
            // UNCONDITIONALLY — it has no way to know a restore is "only"
            // the pane's already-current subject — so publishing one for a
            // refusal wipes the operator's own typed statement off the
            // line the instant it is refused: type `upadte events set
            // customer_id = 42 where id = 3`, press Return, get the
            // correct refusal, and the line snapped back to `events`,
            // typo and all, with nothing left to fix. A refusal ran
            // nothing, so the pane's subject and the rows on screen never
            // stopped agreeing with each other — there is nothing to
            // restore the line TO that it does not already, wrongly,
            // think it shows; the only correct thing to preserve is the
            // operator's own draft, which is preserved by leaving the
            // line alone. `queryLineRefusals[pane.id]`, set just above,
            // is what `shouldAdoptSubject(refused:)` reads to keep a
            // later, unrelated subject change (the agent refining this
            // very pane) from adopting itself over that draft either.
            queryLineRefusals[pane.id] = reason.isEmpty
                ? "this statement is neither a read nor a mutation Wakil can run"
                : reason
        }
    }

    /// Puts `pane`'s query line back to the pane's own subject, after a
    /// mutation that did not become that subject.
    ///
    /// **The subject is re-read from `LayoutStore` — the authority —
    /// rather than taken from the `Pane` value the run started with.**
    /// That value is a snapshot from before the round trip, and between
    /// the two the agent may have refined this very pane; restoring the
    /// line to a subject the pane no longer has would be the same lie in
    /// the other direction. `layoutSnapshot` is the window's cached copy
    /// and can lag the store by a dispatch, so this asks the store.
    ///
    /// **The only caller is the mutation branch of `runFromQueryLine`.**
    /// A confirmed or cancelled mutation both leave the rows and the
    /// query where they were, per spec §9, but the LINE still shows the
    /// statement that was typed — so it alone has to be told to go back.
    /// A refusal also leaves the subject alone, but never reaches here
    /// (final review, Critical 1): nothing ran, so the line and the
    /// subject never disagreed in the first place, and publishing a
    /// restore for it would overwrite the operator's still-unfixed draft.
    /// A read is not restored either: it BECAME the subject, and
    /// `shouldAdoptSubject` carries the line from there.
    private func restoreQueryLine(pane paneId: String) async {
        let subject = await layout.fetch(id: paneId)?.query
        guard let text = queryLineTextAfterRun(
            outcome: .leftTheSubjectAlone, subject: subject) else { return }
        queryLineRestoreToken += 1
        queryLineRestores[paneId] = QueryLineRestore(text: text, token: queryLineRestoreToken)
    }

    /// What the plane's confirm control calls. Only the exact string
    /// `"confirm"` approves; anything else leaves the proposal parked, so
    /// a typo does not cost the operator the proposal.
    public func confirmPending(typed: String) async {
        guard let parked = pending else { return }
        guard typed == "confirm" else { return }
        await confirmations.approve(id: parked.id)
    }

    /// What Cancel and ESC call. Cancelling is always the safe default.
    public func cancelPending() async {
        guard let parked = pending else { return }
        await confirmations.cancel(id: parked.id)
    }

    /// Re-reads every pane on the canvas out of `PaneStore`.
    ///
    /// **It iterates the LAYOUT, not `panes.paneIds()`.** The snapshot is
    /// a union keyed by kind and `LayoutStore` is the registry that knows
    /// each pane's kind — the same correction Decision 24 made to
    /// `read_pane`. Iterating the contents store would answer `kind: nil`
    /// for every pane, which is the one answer reserved for a pane that is
    /// not on the canvas at all.
    ///
    /// **It does not sort.** `PaneStore` already hands back rows in
    /// displayed order — that is where `sortedRows` is applied, so that
    /// the agent's `read_pane` and the operator's screen see one ordering
    /// produced once (2c-i final review Finding 1). Sorting again here
    /// would be a second implementation of the same intent, free to drift.
    public func refreshPanes() async {
        var next: [String: PaneTable] = [:]
        var nextEditables: [String: PaneEditable] = [:]
        let layoutPanes = await layout.snapshot().panes
        for pane in layoutPanes {
            // Only what `PaneStore` already holds. Git's re-reads are `restorePaneContents`
            // and the watcher's (`gitRootChanged`) — not this, which runs after every
            // dispatch and would re-read git on each.
            let snapshot = await panes.snapshot(paneId: pane.id, kind: pane.kind)
            if let surface = snapshot.dataSurface {
                var table = PaneTable(dataSurface: surface)
                table.failure = snapshot.failure
                next[pane.id] = table
                if let editable = await panes.editable(paneId: pane.id) {
                    nextEditables[pane.id] = editable
                }
            }
            setCell(pane.id, snapshot)
        }
        tables = next
        editables = nextEditables
        gitRoots = await gitStatus?.roots ?? []
        // The dictionary itself changes only when a pane opens or closes.
        let open = Set(layoutPanes.map(\.id))
        if Set(paneCells.keys) != open {
            for gone in paneCells.keys where !open.contains(gone) { editorAutosave.forget(pane: gone) }
            paneCells = paneCells.filter { open.contains($0.key) }
        }
        await mirrorEditorFiles()
    }

    /// Copies the file lists' state into `editorFiles`, for the trees.
    private func mirrorEditorFiles() async {
        if let fileLists { editorFiles = await fileLists.state() }
    }

    /// `editables[paneId]` — the pane's `PaneEditable`, or `nil` when its
    /// current subject cannot be written back to a single table. Reads
    /// **per pane id**, the fix `DBPane`'s `refusal` doc comment records:
    /// a window-scoped value painted one pane's state under every other
    /// pane. `DataSurface` calls this once per construction, in
    /// `Canvas.paneView`, the same place `queryLineRefusal(pane:)` and
    /// `queryLineRestore(pane:)` are already read per pane.
    public func editable(paneId: String) -> PaneEditable? { editables[paneId] }

    /// What a click inside a data surface goes through.
    ///
    /// Thin on purpose: it is `dispatch` plus a refresh, in the same shape
    /// `dispatchLayout` wraps it for pane geometry. A second dispatch path
    /// would be a second place `origin`, the environment and the
    /// confirmation parking could drift — and Invariant 2 is exactly the
    /// claim that there is only one.
    ///
    /// **`pane_set_column_width` is the one name routed through
    /// `dispatchLayout` instead.** A column width lives on `Pane`, in
    /// `LayoutStore`, not in `PaneStore` — `refreshPanes` would not even
    /// see it change, and only `dispatchLayout` persists the layout file
    /// afterwards.
    public func dispatchFromSurface(_ name: String, _ params: JSONValue) async {
        await dispatchFromSurfaceRan(name, params)
    }

    /// Several surface calls, **each awaited before the next begins**, in the order given —
    /// Send's "commit the pending body, then send" (2c-iv Amendment 8c), so the send cannot race
    /// the write it depends on.
    ///
    /// **It stops at the first call that did not run.** The send's statement names the body the
    /// write was to leave; sending after a refused write would put a different body on the wire
    /// from the one the confirmation plane reads back. The refusal is in `status`, as for any
    /// other control.
    ///
    /// **A send is started and not awaited** (9a, `apiSurfaceCallDetaches`): the calls before
    /// it have landed when it starts, which is all Send needs, and nothing after it waits for
    /// the reply. **So a send may only be the LAST call of a batch.** A call after it could not
    /// be stopped by its refusal, which would make the rule above untrue, so such a batch is
    /// refused whole, before anything runs, with the refusal in `status`.
    @discardableResult
    public func dispatchFromSurfaceInOrder(_ calls: [(String, JSONValue)]) async -> Bool {
        if let send = calls.dropLast().first(where: { apiSurfaceCallDetaches($0.0) }) {
            status = "\(send.0): a send must be the last call of its batch, so nothing was run."
            return false
        }
        for (name, params) in calls {
            if apiSurfaceCallDetaches(name) {
                // Started, not awaited: see `surfaceChain`.
                Task { @MainActor [weak self] in await self?.dispatchFromSurfaceRan(name, params) }
                continue
            }
            guard await dispatchFromSurfaceRan(name, params) else { return false }
        }
        return true
    }

    /// The operator's calls from an api pane, **in the order the pane made them** (9a). A
    /// debounced write, a focus-out flush and a gesture are separate enqueues, and a later one
    /// must never overtake an earlier one: a gesture writes its region whole, and overtaking would
    /// erase the write before it. Each call is awaited, **except a send**
    /// (`apiSurfaceCallDetaches`). A send is started and left running, so a write typed during
    /// it, or the Cancel that ends it, is not held behind it.
    @ObservationIgnored private let surfaceChain = SurfaceChain()

    /// An api pane's batch, **built when its turn comes** (Task 9 fix round 4), and answering
    /// whether every call landed.
    ///
    /// `build` runs once everything queued before it has completed, and is handed the pane's
    /// stored snapshot as it then is. **Send needs this**: `api_send` sends the stored draft, so
    /// Send's flush and the statement the confirmation plane reads back must be built on the
    /// draft every gesture queued ahead of it left, landed or refused. Built at the press, with
    /// a gesture in flight, the statement named one request and the wire carried another. The
    /// batch is then run as `dispatchFromSurfaceInOrder` runs it, so a send may still only be
    /// its last call.
    ///
    /// `settled` runs on the chain once the batch has run, **before the next batch is built**,
    /// with `false` when a call was refused or failed (which stops the batch). A gesture that
    /// took a box over settles it there (`apiGestureSettled`): refused, the box owes its write
    /// again, and the Send queued behind it writes it. A batch that builds no calls has nothing
    /// to refuse and answers `true`.
    @discardableResult
    public func enqueueFromSurface(
        pane: String,
        building build: @escaping @MainActor (ApiSnapshot) -> [(String, JSONValue)],
        settled: @escaping @MainActor (_ landed: Bool) -> Void = { _ in }
    ) -> Task<Bool, Never> {
        surfaceChain.enqueue { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let calls = build(await self.panes.apiSnapshot(paneId: pane))
            let landed = calls.isEmpty ? true : await self.dispatchFromSurfaceInOrder(calls)
            settled(landed)
            return landed
        }
    }

    /// Sets a pane's focus marks **after** every call queued before it has landed. The pane
    /// queues this on every focus-in, behind the flush of the field the cursor came from
    /// (preflight F6), so that field stays marked (`noteApiFocus` added the new one off the chain)
    /// until its last write is on the draft.
    public func enqueueApiFocus(pane: String, fields: Set<ApiDraftField>, generation: Int) {
        surfaceChain.enqueue { @MainActor [weak self] in
            await self?.panes.setApiFocus(paneId: pane, fields: fields, generation: generation)
        }
    }

    /// Releases a pane's focus mark **after** every call queued before it has landed (Review
    /// Focus 1). The focus-out flush rides the chain, so the agent stays refused until the
    /// field's last write is on the draft.
    public func enqueueFocusRelease(pane: String, generation: Int) {
        enqueueApiFocus(pane: pane, fields: [], generation: generation)
    }

    /// The next focus generation, **issued here and never counted in a view** (fix round 1).
    /// One counter for the whole process, on the main actor, so it only ever rises: a pane view
    /// SwiftUI rebuilds starts its state again, and a store that had seen generation N would
    /// drop every mark below it. Shared across windows, so two windows over one `PaneStore`
    /// cannot issue the same number either.
    func nextFocusGeneration() -> Int { SurfaceChain.nextFocusGeneration() }

    /// The cursor arrived in `fields` of an api pane (Decision 27 by focus). **Marked off the
    /// chain** (`noteApiFocus`, started here in an unstructured `Task`, so it lands on the store
    /// shortly after this returns rather than before) and **set again on the chain**
    /// (`enqueueApiFocus`), behind any flush the pane queued before it (preflight F6), both under
    /// one generation issued now.
    public func focusFromSurface(pane: String, fields: Set<ApiDraftField>) {
        let generation = nextFocusGeneration()
        enqueueApiFocus(pane: pane, fields: fields, generation: generation)
        Task { await noteApiFocus(pane: pane, fields: fields, generation: generation) }
    }

    /// The cursor left the pane's field: its mark is released on the chain, after the field's
    /// last write. **Also what the pane calls when it appears** (fix round 1): a view SwiftUI
    /// tore down never delivered its focus-out, and a mark it held must not stick.
    public func releaseFocusFromSurface(pane: String) {
        enqueueFocusRelease(pane: pane, generation: nextFocusGeneration())
    }

    /// For tests: waits until everything enqueued so far has landed.
    func surfaceChainSettled() async { await surfaceChain.settled() }

    /// `dispatchFromSurface`, answering whether the call ran. A layout call always counts as
    /// run: `dispatchLayout` reports its own failures and answers nothing.
    @discardableResult
    private func dispatchFromSurfaceRan(_ name: String, _ params: JSONValue) async -> Bool {
        if name == "pane_set_column_width" {
            await dispatchLayout(name, params)
            return true
        }
        let ran = await dispatch(name, params) != nil
        await refreshPanes()
        // `pane_sort`, `db_page` and `db_refetch` all write `Pane.fetch`,
        // which lives in `LayoutStore` and which `refreshPanes` cannot
        // see. Without this the query line keeps showing the page and the
        // sort the pane was on before the click.
        if name == "pane_sort" || name.hasPrefix("db_") {
            await refreshLayout()
        }
        return ran
    }

    /// The operator's drop of one grid row on an api pane: `api_bind`, and what it said.
    ///
    /// **A second entry beside `dispatchFromSurface`, not a second path.** It is the same
    /// `registry.dispatch` with the same `origin: .ui`, so Invariant 2 holds as it does for
    /// every other control. What differs is only what comes back: `dispatch(_:_:)` answers
    /// *did something run?* and sends a refusal to the window-wide `status`, while the drop's
    /// result line needs the result's counts, and the refusal's own words, in the pane that
    /// was dropped on. So a refusal is not sent to `status` — and a success clears it, as
    /// `dispatch(_:_:)`'s does, so an earlier control's refusal does not outlive the drop.
    ///
    /// `refreshPanes()` runs either way, as `dispatchFromSurface`'s does: a refusal applies
    /// no part of the call, and re-reading costs nothing but a redraw.
    ///
    /// **It waits for the surface chain first** (9a): a drop is one more of the pane's calls,
    /// and must not overtake a write the pane queued before it.
    public func bindFromSurface(pane: String, source: String, row: Int) async -> ApiBindOutcome {
        // A drop lands after the flush the pane queued for it (9a), and after every call before.
        await surfaceChain.settled()
        let outcome: ApiBindOutcome
        do {
            let result = try await registry.dispatch(
                name: "api_bind",
                params: .object([
                    "pane": .string(pane), "source": .string(source),
                    "row": .integer(Int64(row)),
                ]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            outcome = .result(result)
            status = ""
        } catch {
            outcome = .refused(String(describing: error))
        }
        await refreshPanes()
        return outcome
    }

    /// Amendment 11: the path editor's `curl …` paste — `api_fill_from_curl`, after every call
    /// the pane queued before it, on `bindFromSurface`'s terms. The line and **Undo** it leaves
    /// are pane state (`ApiSnapshot.fillLine`), so the pane draws them from the snapshot; a
    /// refusal reaches it only through the outcome.
    public func fillFromCurlSurface(pane: String, text: String) async -> ApiBindOutcome {
        await surfaceChain.settled()
        let outcome: ApiBindOutcome
        do {
            outcome = .result(try await registry.dispatch(
                name: "api_fill_from_curl",
                params: .object(["pane": .string(pane), "text": .string(text)]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil))
            status = ""
        } catch {
            outcome = .refused(String(describing: error))
        }
        await refreshPanes()
        return outcome
    }

    /// Amendment 11: the fill line's **Undo** — `api_undo_fill`, on the same terms.
    public func undoFillFromSurface(pane: String) async -> ApiBindOutcome {
        await surfaceChain.settled()
        let outcome: ApiBindOutcome
        do {
            outcome = .result(try await registry.dispatch(
                name: "api_undo_fill", params: .object(["pane": .string(pane)]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil))
            status = ""
        } catch {
            outcome = .refused(String(describing: error))
        }
        await refreshPanes()
        return outcome
    }

    /// 3b-iv: a surface call whose refusal belongs to the control that made it — the editor
    /// tree's name field shows it under itself, whole (Rule 8), and keeps the typed text.
    ///
    /// **A sibling of `dispatchFromSurface`, on `bindFromSurface`'s terms**: the same
    /// `registry.dispatch` with `origin: .ui` (Invariant 2), a success clears `status`, a
    /// refusal is thrown to the caller and not put on `status`, and `refreshPanes()` runs
    /// either way. No confirmation is parked: its callers' actions are priced *allow*.
    @discardableResult
    public func dispatchFromSurfaceThrowing(_ name: String, _ params: JSONValue) async throws -> JSONValue {
        do {
            let result = try await registry.dispatch(
                name: name, params: params, origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            status = ""
            await refreshPanes()
            return result
        } catch {
            await refreshPanes()
            throw error
        }
    }

    // MARK: - Layout

    /// Re-reads the active project's arrangement out of `LayoutStore` —
    /// and writes it to disk if what persists actually changed.
    ///
    /// **This is the one seam every writer already passes through, which
    /// is why the write lives here** (final review, Critical 1).
    /// `persistLayout()` used to have exactly one caller, `dispatchLayout`,
    /// which handles only the `pane_*` geometry actions, `session_resume`
    /// and palette items — so `Pane.fetch`, written by `runQuery`,
    /// `pagePane`, `refetchPane`, `dispatchFromSurface` and by the agent's
    /// own dispatches, never reached the file at all. A pane came back
    /// from a relaunch empty, with an empty query line, and the fetch
    /// survived only when the operator happened to drag a pane afterwards
    /// and flush the whole snapshot as a side effect.
    ///
    /// Every one of those paths — the pointer's and the agent's alike —
    /// already called THIS method: the window's own methods call it
    /// inline, and `observationPump` calls it once per dispatch that ran,
    /// whoever made it. So one place decides that the arrangement changed
    /// and one place writes it, instead of a `persistLayout()` call at
    /// each of five sites that a sixth writer would forget to join.
    ///
    /// **Only a real change is written**, on the same comparison
    /// `dispatchLayout` used to make: `withoutTransientState` ignores
    /// `busy`, so the two refreshes that bracket a dispatch cannot write a
    /// file for a pane that merely started or stopped spinning, and ⌘K
    /// commands that arrange nothing write nothing.
    ///
    /// **`activateLayout` calls this once, for the conversation it is
    /// LEAVING**, and reads the one it is arriving at with the plain read
    /// below instead. The two halves of a swap are not the same act: the
    /// outgoing arrangement may hold a change nothing has committed yet,
    /// and this is its last chance to reach the right file — the next
    /// commit belongs to the incoming conversation. The incoming one is
    /// a restore of what a file already says, and writing it straight
    /// back would rewrite an unchanged file with a modification time that
    /// means nothing.
    public func refreshLayout() async {
        // **Nothing commits a half-swapped canvas** — see
        // `layoutSwapInFlight`. Between `activateLayout` pointing the
        // stores at the incoming scope and the arrangement for it being
        // in hand, the store answers with an empty canvas filed under a
        // scope nothing has restored yet; writing that is how a switch
        // came to destroy the arrangement it was about to read. The
        // refresh is skipped whole rather than only its write, because
        // publishing that canvas is wrong for the same reason writing it
        // is, and `activateLayout` ends with a read of its own.
        guard !layoutSwapInFlight else { return }
        let before = layoutSnapshot
        // One hop for both, so a view reading them together reads one moment
        // — see `LayoutStore.reading()`.
        let reading = await layout.reading()
        layoutSnapshot = reading.snapshot
        // 3b-v: focus leaving an editor pane is `focus` mode's trigger.
        if let left = before.focusedId, left != layoutSnapshot.focusedId { autosaveFocusLeft(pane: left) }
        pruneApiSendRequests()
        pruneGhostSessions(before: before)
        keyboardFocusRequests = reading.focusRequests
        // Every pane opened or closed — the operator's or the agent's — passes through here
        // or `readLayoutSnapshot`, so the watchers follow the editor panes from these two.
        await syncGitWatcher()
        await syncEditorWatcher()
        if layoutSnapshot.withoutTransientState != before.withoutTransientState {
            await persistLayout()
        } else {
            // **No change here does not mean nothing is being written.**
            // `observationPump` refreshes after every dispatch too, so it can
            // see this same change first and start the save; this refresh
            // then finds nothing new. Returning before that save lands let a
            // caller read the file a moment too early (#344, #312). Waiting
            // keeps the promise every caller relies on: once a refresh has
            // returned, the file says what the canvas says.
            _ = await pendingSave?.value
        }
        // 3a-iii-a: the background fetch follows whether an editor pane is open.
        updateBackgroundFetch()
    }

    /// Re-reads the arrangement and writes nothing.
    ///
    /// The callers are the places where a difference between the snapshot
    /// in hand and the store is not a change to be committed:
    /// `activateLayout`, where the difference IS the file that was just
    /// read off disk (writing it straight back would rewrite a file that
    /// did not change, with a modification time that means nothing);
    /// `dispatchLayout`'s busy-marking pass, which publishes a transient
    /// flag before the action it belongs to has even run; and
    /// `setCanvasSize`, which is the window reporting its own size — see
    /// its doc comment for why that is not an operator asking for
    /// anything.
    private func readLayoutSnapshot() async {
        let before = layoutSnapshot
        let reading = await layout.reading()
        layoutSnapshot = reading.snapshot
        pruneApiSendRequests()
        pruneGhostSessions(before: before)
        keyboardFocusRequests = reading.focusRequests
        await syncGitWatcher()
        await syncEditorWatcher()
    }

    // MARK: The git watcher (3a-i; the window's since 3b-iii)

    /// Starts, restarts or stops `rootWatcher` so it watches `gitRootPaths` exactly while an
    /// editor pane is open (3b-iii: the Git pane folded into the editor). A no-op when that set
    /// has not changed, so it is called from every place the panes or the roots can change rather
    /// than from the few that usually do.
    ///
    /// **Chained, not merely awaited.** Two calls can overlap — a refresh landing during a
    /// project switch — and each hops to the watcher's actor; chaining is what keeps the
    /// watcher's last instruction this method's last decision.
    ///
    /// **The panes and the roots must belong to the same moment.** `refreshContext` assigns
    /// the incoming project's roots and then suspends before `activateLayout` swaps the
    /// canvas, so a refresh landing in between (`observationPump`'s, after any dispatch)
    /// saw the outgoing project's git pane beside the incoming project's roots — and
    /// watched, and read into that pane, roots its project does not have. Measured under
    /// load as `["watch p", "watch q", "stop"]` for a switch into a project with no git
    /// pane. Until the canvas in hand is the current scope's, only "no roots, so stop" is
    /// decided; the swap's own `refreshPanes` and `refreshContext`'s trailing call decide
    /// the rest once it is.
    ///
    /// **Returning means the watcher has been told.** A call that finds its decision
    /// already made by an overlapping one still waits for that instruction to land — the
    /// promise `invalidateForOrgChange` makes to "call this, then look" (stop measured
    /// arriving after an org switch, a pane close and a project switch had returned).
    private func syncGitWatcher() async {
        guard let gitWatcher else { return }
        let roots = gitRootPaths
        let canvasIsCurrent = !layoutSwapInFlight
            && layoutScope == currentLayoutScope
        guard canvasIsCurrent || roots.isEmpty else { return }
        let showsGit = layoutSnapshot.panes.contains { PaneKinds.is($0.kind, EditorPaneKind.self) }
        let wanted = showsGit ? roots : []
        let changed: @Sendable (String) async -> Void = { [weak self] root in
            await self?.gitRootChanged(root)
        }
        switch await gitWatcher.sync(to: wanted, changed: changed) {
        case .unchanged:
            // An editor pane opened while another is open reads the window's status, which the
            // running watch already keeps: nothing to read.
            break
        case .started:
            // **A watch that starts reads first** (fix round 1, I1), once for the window. The roots
            // changed, so what the editor panes show is either nothing yet or the state as of some
            // earlier moment — a project left and come back to keeps its canvas in memory and runs
            // no restore, so anything changed meanwhile would wait for the next file event. The
            // watcher only reports changes from now on; this read covers everything before it. The
            // panes list every root loading before the read, and take what it found after.
            await readStatus(only: nil)
        case .stopped:
            await gitStatus?.reset()
            gitRoots = []
        }
    }

    /// The editor's watch: the project's roots while an editor pane is open (3b-i). A change
    /// dispatches `editor_refresh` for that root in every editor pane.
    private func syncEditorWatcher() async {
        guard let editorWatcher else {
            // No watcher, so nothing would tell a kept list the disk changed: read it fresh.
            await fileLists?.setWatching(false)
            return
        }
        let roots = gitRootPaths
        let canvasIsCurrent = !layoutSwapInFlight
            && layoutScope == currentLayoutScope
        guard canvasIsCurrent || roots.isEmpty else { return }
        let hasEditor = layoutSnapshot.panes.contains { PaneKinds.is($0.kind, EditorPaneKind.self) }
        let changed: @Sendable (String, [String]?) async -> Void = { [weak self] root, paths in
            await self?.editorRootChanged(root, paths: paths)
        }
        _ = await editorWatcher.sync(to: hasEditor ? roots : [], changedPaths: changed)
        // The list is kept exactly while something will tell it the disk changed, and only for
        // the roots watched: a project switch drops the outgoing roots' lists and re-reads the
        // incoming ones that were listed (final review I1).
        if let fileLists {
            let reloads = await fileLists.watch(roots: hasEditor ? roots : [])
            await mirrorEditorFiles()
            Task { [weak self] in
                await reloads.value
                await self?.mirrorEditorFiles()
            }
        }
    }

    /// A wake: the list first (it re-reads a listed root, so the refresh below draws the new
    /// listing), then `editor_refresh` in every editor pane. Open heavy folders reload in the
    /// background, so the next wake is not held behind them; the trees redraw when they land.
    /// `paths`, the burst's own, let a search mark its results changed only when one of their files
    /// changed (final review I4); nil (the watcher cannot say) marks every result under the root.
    private func editorRootChanged(_ root: String, paths: [String]?) async {
        guard gitRootPaths.contains(root) else { return }   // a wake from a project just left
        if let reloads = await fileLists?.invalidate(root: root) {
            Task { [weak self] in
                await reloads.value
                await self?.mirrorEditorFiles()
            }
        }
        // The file watcher never reads git (R5): the git watcher's wake does, once, for the window.
        var params: [String: JSONValue] = ["root": .string(root), "what": .string("files")]
        if let paths { params["paths"] = .array(paths.map { .string($0) }) }
        for pane in layoutSnapshot.panes where PaneKinds.is(pane.kind, EditorPaneKind.self) {
            params["pane"] = .string(pane.id)
            _ = try? await registry.dispatch(
                name: "editor_refresh", params: .object(params),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        }
        await refreshPanes()
    }

    /// Something under `root` changed: re-read that root of the window's status, then bring every
    /// editor pane's git state up to it.
    ///
    /// **Straight to the registry, not through `dispatch(_:_:)`**, which clears `status` on
    /// success — a file saved in an editor would wipe a refusal the operator has not read
    /// yet. It is still the one dispatch path, journalled as every refresh is; a failure is
    /// already in the window's status, under the root that failed, and the Changes view shows it
    /// on that root's line (Interaction Rule 8).
    private func gitRootChanged(_ root: String) async {
        guard gitRootPaths.contains(root) else { return }   // a wake from a project just left
        await readStatus(only: root)
    }

    /// One read of the window's status, for `only` or every root, shown as it happens: the status
    /// marks its roots loading (and the window's mirror lists them so), then the read is awaited
    /// and the editor panes take what it found. Without a status there is no git to show.
    private func readStatus(only root: String?) async {
        guard let gitStatus else { return }
        let ticket = await gitStatus.begin(only: root)
        gitRoots = await gitStatus.roots
        await gitStatus.finish(ticket)
        // The editor panes' git state (the Changes highlight, and later their diff tabs and gutter
        // baselines) against the status just read: `what: git` reads nothing itself.
        for pane in layoutSnapshot.panes where PaneKinds.is(pane.kind, EditorPaneKind.self) {
            var params: [String: JSONValue] = ["pane": .string(pane.id), "what": .string("git")]
            if let root { params["root"] = .string(root) }
            _ = try? await registry.dispatch(
                name: "editor_refresh", params: .object(params),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        }
        await refreshPanes()
    }

    /// Tells the layout how big the canvas actually is.
    ///
    /// **Not a dispatched action, and deliberately so.** This is not
    /// something an operator or an agent *asks for* — it is the window
    /// reporting a fact about itself, in the same family as
    /// `switchScope` and `load`. Nothing outside Wakil is touched and
    /// there is no intent to journal; a `pane_*` action for "the window is
    /// now this big" would put a hundred entries in the journal for one
    /// window resize and mean nothing to a reader.
    ///
    /// It matters more than it looks. The void is what `SnapSolver`
    /// measures every canvas-edge snap against, and what `maximize` fills.
    /// Left at `LayoutStore.defaultVoid` — a fixed 1440×900 — a smaller
    /// window puts the right and bottom snap edges outside the visible
    /// canvas, so two of the four edges silently stop being reachable and
    /// `read_layout` reports a maximized pane at a size that is not on
    /// screen.
    public func setCanvasSize(width: Double, height: Double) async {
        // A zero or negative canvas is SwiftUI mid-layout, not a window
        // the user can see. Snapping to it would put every pane at the
        // origin.
        guard width > 0, height > 0 else { return }
        await layout.setVoid(PaneFrame(x: 0, y: 0, width: width, height: height))
        // **A plain read, not `refreshLayout()`** (re-review, Fix 1). The
        // same sentence three paragraphs up is the whole argument: this is
        // not something anyone asked for, so there is nothing here to
        // commit. `WakilWindow`'s `.task(id: geometry.size)` fires this on
        // every size change while a window edge is being dragged, and with
        // a pane maximized `LayoutStore.setVoid` moves that pane's frame
        // to follow — so the snapshot differs on every tick and a
        // persisting refresh performed dozens of atomic-rename saves a
        // second. The pane's real position is still written the moment
        // anything actually commits; a resize is not that moment.
        await readLayoutSnapshot()
    }

    /// Answers whether the pane opened; a refusal is in `status`, whole.
    @discardableResult
    public func openPane(kind: String) async -> Bool {
        await enterConversation()
        return await dispatchLayout("pane_open", .object(["kind": .string(kind)])) != nil
    }

    /// Marks work begun and brings the canvas in line with the conversation
    /// that begins with it.
    ///
    /// **The activation has to come before whatever follows it.** Opening
    /// the first pane of a session mints the conversation identity, which
    /// changes the scope; dispatching `pane_open` first would put the pane
    /// in the Landing's scope and then switch away from it, and
    /// `LayoutStore` hands back an empty arrangement for a scope it has
    /// not seen — the pane would simply vanish. Activating first means the
    /// pane opens into the arrangement it is going to live in.
    ///
    /// Cheap when nothing changed: `markSessionStarted` is idempotent, and
    /// `activateLayout` returns without touching a store when the scope it
    /// derives equals the one already active — which is every call after
    /// the first.
    ///
    /// **A conversation minted here adopts the canvas already on screen** (re-walk finding #4,
    /// 2026-10-04). A launch restores the project's arrangement under no conversation, and the
    /// window leaves the Landing for it without minting one (#264). The first turn or pane then
    /// mints one here, which moves the scope — and `activateLayout` used to read the project seed
    /// back off disk into the new scope, so `restorePaneContents` rebuilt every api pane from an
    /// empty draft (drafts are never persisted): the operator's draft and entry vanished on their
    /// first message to the agent. The arrangement and the pane contents are the same work, so
    /// they move into the conversation as they are.
    private func enterConversation() async {
        await enterConversation(agent(for: place))
    }

    /// `enterConversation` for the agent a turn was typed to. The canvas follows only while
    /// that place is on screen.
    private func enterConversation(_ agent: PlaceAgent) async {
        let minting = agent.lineageRoot == nil
        markSessionStarted(in: agent)
        await followConversation(of: agent, adoptingCanvas: minting && agent.lineageRoot != nil)
    }

    /// The canvas follows a change of `agent`'s conversation. On screen that is
    /// `activateLayout`. Off screen — an agent's own resume while the operator is elsewhere —
    /// its arrangement is read into memory once, as `activateLayout` would, so its next write
    /// lands on it rather than on an empty canvas a later return would then overwrite; the
    /// contents are restored when the operator returns.
    ///
    /// **A file it cannot read is not marked read** (final review minor 6), so
    /// `persistBackgroundLayouts` never writes the agent's changes over the arrangement the
    /// operator made, and the operator's return reads it again — on screen — and says so in
    /// `status`, as an on-screen read does. Said off screen, the note would name a place the
    /// operator is not looking at, or be overwritten before they got there.
    private func followConversation(
        of agent: PlaceAgent, carrying overlay: Pane? = nil, adoptingCanvas: Bool = false
    ) async {
        guard agent !== currentAgent else {
            await activateLayout(carrying: overlay, adoptingCanvas: adoptingCanvas)
            return
        }
        guard let scope = agent.layoutScope else { return }
        await loadOffScreen(scope)
    }

    /// Reads `scope`'s arrangement into memory off screen, once, as `activateLayout` would; its
    /// contents are restored when the operator comes to it (`followConversation`).
    private func loadOffScreen(_ scope: LayoutScope) async {
        guard let persistence, !scope.organization.isEmpty,
              !loadedLayoutScopes.contains(scope) else { return }
        let saved = persistence.load(for: scope)
        // Unreadable: a note and no arrangement. Left unread for the return to read and report.
        if saved.snapshot == nil, saved.note != nil { return }
        loadedLayoutScopes.insert(scope)
        if let note = saved.note { layoutNotesAwaitingReturn[scope] = note }
        if let snapshot = saved.snapshot {
            await layout.load(snapshot, for: scope)
            scopesAwaitingRestore.insert(scope)
        }
    }

    /// Every agent's `Bash` history into the terminal panes of its own canvas: the screen's
    /// agent into the screen, each other agent into its place's scope.
    private func backfillTerminals() async {
        for agent in agents.values {
            if agent === currentAgent {
                await agent.mirror.backfill(into: nil)
            } else if let scope = agent.layoutScope {
                await agent.mirror.backfill(into: scope)
            }
        }
    }

    /// One harness event into the terminal panes of its agent's own canvas.
    private func pumpMirror(_ event: HarnessEvent, for agent: PlaceAgent) async {
        if agent === currentAgent {
            await agent.mirror.pump(event, into: nil)
        } else if let scope = agent.layoutScope {
            await agent.mirror.pump(event, into: scope)
        }
    }

    /// Ruling 2 of background agents 3 of 4: an agent's change to a canvas off screen reaches
    /// that canvas's file, as the screen's changes reach its own through `refreshLayout`. Only
    /// a scope this window has read (`loadedLayoutScopes`): writing one it never read would
    /// replace a saved arrangement with an empty one. Read with the scope named, never through
    /// whatever `ScopeRouting.home` the caller carries.
    private func persistBackgroundLayouts() async {
        // Mid-move, a scope's arrangement may be empty or already under its new key
        // (`carryScopes`); the next dispatch writes whatever changed.
        guard !layoutSwapInFlight else { return }
        for agent in agents.values where agent !== currentAgent {
            guard let scope = agent.layoutScope, scope != layoutScope,
                  loadedLayoutScopes.contains(scope) else { continue }
            let snapshot = await ScopeRouting.$home.withValue(scope) { await layout.snapshot() }
            guard snapshot.withoutTransientState != backgroundLayouts[scope]?.withoutTransientState else {
                continue
            }
            backgroundLayouts[scope] = snapshot
            await persistLayout(snapshot, for: scope)
        }
    }

    /// The mouse's way into a terminal pane (walk-defects B1), dispatching
    /// `term_open` with no params through the same `dispatchLayout` every
    /// other pane control here goes through. Unlike `pane_open`, this
    /// both opens the pane AND starts its shell in one call — `term_open`
    /// is what a terminal pane kind needs, `pane_open` alone would leave a
    /// dead pane with "no shell" exactly as B2 describes. Nameless on
    /// purpose: `term_open`'s own default `path` (the active project's
    /// root, else home) is what makes a param-less call work at all,
    /// mirroring what dropping `path` from `required` bought ⌘K.
    @discardableResult
    public func openTerminalPane() async -> Bool {
        await enterConversation()
        return await dispatchLayout("term_open", .object([:])) != nil
    }

    /// A pane holding unsaved editor tabs asks first (`unsavedPrompt`) and answers false; the
    /// prompt's Save or Don't Save closes it. Every other pane closes as it always did.
    @discardableResult
    public func closePane(id: String) async -> Bool {
        let dirty = dirtyEditorTabs(in: id)
        if !dirty.isEmpty {
            askUnsaved(.closePane(pane: id), titles: dirty.map(\.title))
            return false
        }
        return await dispatchLayout("pane_close", .object(["id": .string(id)])) != nil
    }

    /// The rail, `⌘K` and anything else whose whole purpose is *put me back
    /// in that pane*.
    ///
    /// **It raises nothing itself**, and #284's first fix did.
    /// `dispatchLayout` runs the registry's `pane_focus` — the same action
    /// the agent calls — and `LayoutStore.focus(id:)` counts the request
    /// there, for both channels at once. `dispatchLayout` ends in
    /// `refreshLayout()`, so the new count and the new `focusedId` reach the
    /// window in the same read and a view sees one moment rather than two.
    @discardableResult
    public func focusPane(id: String) async -> Bool {
        await dispatchLayout("pane_focus", .object(["id": .string(id)])) != nil
    }

    /// A click landing on a pane on the canvas.
    ///
    /// The canvas is the third way to reach a pane, alongside the rail and
    /// ⌘K, and it was the one that was never wired: `LayoutStore.focus`
    /// describes itself as "the one call a click on an unfocused pane
    /// dispatches", but `Canvas.paneView` carried only a `DragGesture` and
    /// a resize handle. A click that did not move the pointer therefore
    /// dispatched nothing, and focus stayed wherever `open` or `maximize`
    /// last put it — so ⌘⏎ kept maximizing a pane the operator had clicked
    /// away from.
    ///
    /// **Why this is not just `focusPane`.** It dispatches only when focus
    /// would actually move. Every dispatch journals, and a click is the
    /// most repeated gesture there is — without the guard the journal fills
    /// with entries recording that focus did not change.
    ///
    /// **And why the guard is not pushed down into `focusPane` instead.**
    /// `LayoutStore.focus` also *recovers*: a pane that has drifted outside
    /// the void — a layout saved on a large canvas and restored on a small
    /// one — is pulled back to the nearest visible position. The rail is
    /// the only handle such a pane has left, so a rail click on the
    /// already-focused pane is real work and must still dispatch. A canvas
    /// click can never be that case, because a pane you can click is a pane
    /// already on screen.
    ///
    /// **But it is still a request for the keyboard, and #284's first fix
    /// missed that.** Clicking the pane you are already "in" is exactly what
    /// an operator does after typing to the agent, and the click does not
    /// move first responder by itself: the canvas gesture is a
    /// `DragGesture`/`TapGesture`, neither of which touches the pane's
    /// `@FocusState`. Dispatching nothing was right; answering nothing was
    /// not. `noteFocusRequest()` raises the count without a dispatch, a
    /// journal entry or a change to the arrangement, and the read after it
    /// is what carries the new count to the view.
    public func paneClicked(id: String) async {
        guard layoutSnapshot.focusedId != id else {
            await layout.noteFocusRequest()
            await readLayoutSnapshot()
            return
        }
        await focusPane(id: id)
    }

    /// The end of a drag: one action, carrying where the pane actually
    /// landed.
    ///
    /// If a snap was being previewed, this commits `pane_snap` instead of
    /// `pane_move` — the snap is what the user was aiming at, and
    /// recording the move they happened to release on would journal the
    /// wrong intent and leave the edges uncoordinated.
    public func commitDrag(id: String, x: Double, y: Double) async {
        if let candidate = dragCandidate {
            dragCandidate = nil
            var params: [String: JSONValue] = [
                "id": .string(id), "edge": .string(candidate.edge.rawValue),
            ]
            // Absent, not null, when the snap is to the canvas edge:
            // `pane_snap`'s handler reads `toPaneId` as an optional string
            // and a `null` would not be one.
            if let toPaneId = candidate.toPaneId { params["toPaneId"] = .string(toPaneId) }
            // Where the pane was *released*. Without it the store flushes
            // from the frame the drag started at — the drag itself never
            // moved the store — and the pane lands somewhere the snap line
            // never showed. See `LayoutStore.snap`.
            params["x"] = .number(x)
            params["y"] = .number(y)
            await dispatchLayout("pane_snap", .object(params))
            return
        }
        await dispatchLayout("pane_move", .object([
            "id": .string(id), "x": .number(x), "y": .number(y),
        ]))
    }

    public func commitResize(id: String, width: Double, height: Double) async {
        await dispatchLayout("pane_resize", .object([
            "id": .string(id), "width": .number(width), "height": .number(height),
        ]))
    }

    /// Mid-drag. **Dispatches nothing** — it only asks the store what would
    /// happen, so the canvas can draw a snap line. Spec §4.1: the gesture
    /// is not the action; its commit is.
    public func previewDrag(id: String, x: Double, y: Double) async {
        dragCandidate = await layout.candidate(forDragging: id, to: (x: x, y: y))
    }

    /// A drag that ended without committing — cancelled, or released
    /// outside the canvas. Takes the pane id it was dragging so the call
    /// reads the same as its siblings, and so a future implementation that
    /// has something to undo does not change the view's call.
    public func endDrag(id: String) async {
        dragCandidate = nil
    }

    /// ⌘⏎ (R10): in a focused editor pane whose active tab is a diff that may open its file, opens it
    /// (`editor_open_file`); anywhere else, Maximize Pane as before.
    public func commandReturn() async {
        guard let id = layoutSnapshot.focusedId else { return }
        if let pane = focusedEditor, editorCommandReturnOpensFile(editor(pane), roots: gitRoots) {
            _ = await dispatch("editor_open_file", .object(["pane": .string(pane)]))
            await refreshLayout()
            await refreshPanes()
            return
        }
        await toggleMaximize(id: id)
    }

    public func toggleMaximize(id: String) async {
        if layoutSnapshot.maximizedId == id {
            await dispatchLayout("pane_restore", .object([:]))
        } else {
            await dispatchLayout("pane_maximize", .object(["id": .string(id)]))
        }
    }

    /// Toggles the focused pane's density (§8's ⌘⇧D).
    ///
    /// Dispatches rather than mutating, like every other control in this
    /// window: Invariant 2 does not stop at layout, and a toggle wired
    /// straight to `@State` would be the first thing here the agent cannot
    /// do and the journal cannot see.
    public func toggleDensity(id: String) async {
        let current = layoutSnapshot.panes.first { $0.id == id }?.density ?? .airy
        await dispatchLayout("pane_set_density", .object([
            "id": .string(id),
            "density": .string(current.toggled.rawValue),
        ]))
    }

    // MARK: - The Landing's Continue column

    /// This project's sessions, as ⌘P's Sessions group lists them. **"None" and "could not
    /// read" must not look alike**: what any of the Landing's reads could not answer — the
    /// sessions, the projects, the providers — goes to `status`, which the window draws under
    /// the Landing, as the old ⌘P sheet's `openItems` did. Written last, after every read, so
    /// a later success cannot clear an earlier note; the Landing calls this after
    /// `listProjects`, whose own success clears `status`.
    public func landingSessions() async -> [PaletteItem] {
        let sessions = await sessionPaletteItems()
        let projects = await currentOrganisationProjects()
        let providers = await providerPaletteItems()
        let notes = [projects.note, sessions.note, providers.note].compactMap { $0 }
        if !notes.isEmpty { status = notes.joined(separator: "; ") }
        return PaletteItems.continueItems(sessions.items, excluding: liveSessionIds)
    }

    /// A Continue row: `session_resume` through the registry, origin `ui`, as ⌘P's session row
    /// runs it.
    public func continueSession(_ id: String) async {
        await dispatchLayout("session_resume", .object(["id": .string(id)]))
    }

    /// A Running row: `session_switch` through the registry, origin `ui`, as ⌘P's Running row
    /// runs it — the same session brought back, no fork.
    public func switchToRunning(_ conversation: String) async {
        await dispatchLayout("session_switch", .object(["conversation": .string(conversation)]))
    }

    // MARK: Editor (3b-i)

    /// The pane ⌘T, ⌘S and ⌘W act on: the focused pane if it is an editor.
    private var focusedEditor: String? {
        guard let id = layoutSnapshot.focusedId,
              layoutSnapshot.panes.first(where: { $0.id == id })?.kind == "editor" else { return nil }
        return id
    }

    /// The scratch tab ⌘S could not save without a path: the pane whose path field should show.
    public private(set) var editorSaveAsRequest: String?

    /// ⌘B / ⌘⇧F showed a pane's column: that pane's column takes the keyboard on this view (Rule 3). Only
    /// the operator's toggle sets it — an agent's `editor_tree` never moves their keyboard (Rule 6).
    public private(set) var editorColumnFocusRequest: EditorColumnFocusRequest?

    /// The pane's column took the keyboard: the request is spent.
    public func editorColumnFocusTaken() { editorColumnFocusRequest = nil }

    /// The reveal button's or ⌘K's row to select: the pane's tree selects it once its row is drawn,
    /// scrolls to it, and leaves the keyboard where it is (Rule 6). Only the operator's reveal sets it;
    /// the agent's `editor_tree_reveal` opens folders only.
    public private(set) var editorTreeRevealRequest: EditorTreeRevealRequest?

    /// The pane selected the revealed row: the request is spent.
    public func editorTreeRevealTaken() { editorTreeRevealRequest = nil }

    /// The reveal button and ⌘K's *Reveal Active File in Tree* (3b-ii-b): Files shown, every folder
    /// above the active file opened, its row selected. Nothing with no file tab in front.
    public func revealActiveFileInTree(pane: String? = nil) async {
        guard let pane = pane ?? focusedEditorPane(), let s = editor(pane), let i = s.active, i < s.tabs.count,
              let path = s.tabs[i].path else { return }
        let column = s.column ?? editorColumnDefault
        if !(column.shown && column.view == .files) {
            let shown: JSONValue = .object(["pane": .string(pane), "view": .string("files"), "shown": .bool(true)])
            guard await dispatch("editor_tree", shown) != nil else { return }
        }
        guard await dispatch("editor_tree_reveal", .object(["pane": .string(pane), "path": .string(path)])) != nil else { return }
        await refreshPanes()
        editorTreeRevealRequest = EditorTreeRevealRequest(pane: pane, path: path, serial: (editorTreeRevealRequest?.serial ?? 0) + 1)
    }

    /// A middle-click on a tab (3b-ii-b): ⌘W's rule for that one tab — a clean tab closes, a dirty one
    /// asks Save / Don't Save / Cancel. By subject, never by position.
    public func closeEditorTab(pane: String, subject: EditorTabSubject) async {
        guard let s = editor(pane), let i = s.tabs.firstIndex(where: { $0.subject == subject }) else { return }
        if s.tabs[i].dirty {
            askUnsaved(.closeTab(pane: pane, subject: subject), titles: [editorTabTitles(s.tabs)[i]])
            return
        }
        // No discard: a keystroke landing between the check and the close is refused, never dropped.
        var params: [String: JSONValue] = ["pane": .string(pane)]
        params.merge(editorTabParams(subject)) { $1 }
        _ = await dispatch("editor_close", .object(params))
        await refreshLayout()
        await refreshPanes()
    }

    /// The save ⌘S started in a pane, while it runs (Rule 4: anything that waits can be cancelled).
    @ObservationIgnored private var editorSaves: [String: Task<Void, Never>] = [:]

    /// ⌘T: a scratch tab in the focused editor pane, else the first, else a new one — which then
    /// takes focus. Opening a pane opens it into the conversation, as `openPane` does.
    public func newScratch() async {
        var params: [String: JSONValue] = [:]
        if let pane = focusedEditor { params["pane"] = .string(pane) }
        let before = paneIds
        if !layoutSnapshot.panes.contains(where: { $0.kind == "editor" }) { await enterConversation() }
        guard let reply = await dispatch("editor_new_scratch", .object(params)) else { return }
        await refreshLayout()
        await refreshPanes()
        if let pane = optionalString(reply, "pane"), layoutSnapshot.focusedId != pane || !before.contains(pane) {
            await focusPane(id: pane)
        }
    }

    /// The column a pane that has never set its own starts from: the one last left in any editor pane.
    public var editorColumnDefault: EditorColumnState { layoutSnapshot.editorColumnDefault ?? .initial }

    /// ⌘B (`.files`) and ⌘⇧F (`.search`): show the focused editor's column on that view, or hide it when it
    /// already shows it. With no editor focused, the first editor pane, else a new one (editor_tree's own rule).
    public func toggleEditorColumn(_ view: EditorColumnView) async {
        var params: [String: JSONValue] = ["view": .string(view.rawValue)]
        // The pane editor_tree will act on (its own rule: the focused editor, else the first), so the
        // toggle reads that pane's column, not the one last left in some other pane.
        let pane = focusedEditor ?? layoutSnapshot.panes.first { $0.kind == "editor" }?.id
        if let pane { params["pane"] = .string(pane) }
        let current = pane.flatMap { editor($0)?.column } ?? editorColumnDefault
        params["shown"] = .bool(!(current.shown && current.view == view))
        if !layoutSnapshot.panes.contains(where: { $0.kind == "editor" }) { await enterConversation() }
        guard let reply = await dispatch("editor_tree", .object(params)) else { return }
        await refreshLayout()
        await refreshPanes()
        // Rule 3: the operator showed it, so its view takes their keyboard (set before the pane is
        // focused, so the focus change finds the column already holding it).
        if params["shown"] == .bool(true), let p = optionalString(reply, "pane") {
            editorColumnFocusRequest = EditorColumnFocusRequest(
                pane: p, view: view, serial: (editorColumnFocusRequest?.serial ?? 0) + 1)
        }
        if let p = optionalString(reply, "pane"), layoutSnapshot.focusedId != p { await focusPane(id: p) }
    }

    /// Monaco's find bar reporting its query and match count for a pane (the pane's find record).
    public func editorFindDidReport(pane: String, report: EditorFindReport) async {
        await panes.editorFindDidReport(paneId: pane, report: report)
        await refreshEditor(pane: pane)
    }

    /// ⌘S in a focused editor pane. A scratch tab asks for a path (the pane draws its field).
    public func saveFocusedEditor() async {
        guard let pane = focusedEditor, let s = editor(pane), let i = s.active, i < s.tabs.count else { return }
        if s.tabs[i].isScratch {
            editorSaveAsRequest = pane
            return
        }
        // Rule 5: one save in flight per pane. A second ⌘S would only be refused as busy — and
        // replacing the entry would cost the first save its Cancel.
        guard editorSaves[pane] == nil else { return }
        let save = Task { _ = await self.dispatch("editor_save", .object(["pane": .string(pane)])) }
        editorSaves[pane] = save
        await save.value
        editorSaves[pane] = nil
        await refreshPanes()
    }

    /// The saving tick's Cancel: the write is abandoned and the buffer stays dirty.
    public func cancelSave(pane: String) {
        editorSaves[pane]?.cancel()
    }

    /// The path field's Save. `.saved` closes the field; `.exists` asks "Replace <name>?" inline
    /// before anything is written (Rule 1: a confirmation before destroying), and the field's
    /// Replace calls this again with `replace`; `.failed` carries the failure text, whole.
    public func saveScratch(pane: String, as path: String, replace: Bool = false) async -> EditorSaveAsResult {
        var params: [String: JSONValue] = ["pane": .string(pane), "as": .string(path)]
        if replace { params["replace"] = .bool(true) }
        do {
            _ = try await registry.dispatch(name: "editor_save", params: .object(params), origin: .ui,
                                            caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            status = ""
        } catch EditorActionError.targetExists(let existing) {
            return .exists(name: (existing as NSString).lastPathComponent)
        } catch where isRoutineCancel(error) {
            return .failed("editor_save was cancelled; nothing was written")
        } catch {
            status = statusDescribingFailure("editor_save", error)
            await refreshPanes()
            return .failed(status.isEmpty ? "editor_save failed" : status)
        }
        editorSaveAsRequest = nil
        await refreshLayout()
        await refreshPanes()
        return .saved
    }

    /// The path field's Esc or Cancel.
    public func cancelSaveAs() { editorSaveAsRequest = nil }

    /// ⌘W: the active tab of a focused editor pane, else the pane, as before. A tab with unsaved
    /// edits asks first (`askUnsaved`, Task 9).
    public func closeFocusedTabOrPane() async {
        guard let id = layoutSnapshot.focusedId else { return }
        let s = focusedEditor.flatMap { editor($0) } ?? .empty
        guard let pane = focusedEditor, editorCloseTarget(tabs: s.tabs.count) == .tab,
              let i = s.active, i < s.tabs.count else {
            await closePane(id: id)
            return
        }
        if s.tabs[i].dirty {
            askUnsaved(.closeTab(pane: pane, subject: s.tabs[i].subject), titles: [editorTabTitles(s.tabs)[i]])
            return
        }
        _ = await dispatch("editor_close", .object(["pane": .string(pane), "discard": .bool(true)]))
        await refreshLayout()
        await refreshPanes()
    }

    // MARK: Unsaved edits (3b-i Task 9)

    /// Save / Don't Save / Cancel, waiting on the operator: what would be lost, and what asked.
    /// The editor pane draws a `.closeTab` prompt over its tab strip; the window draws the rest.
    public private(set) var unsavedPrompt: UnsavedPrompt? {
        // Raising it stops every pending autosave timer (Rule 1): a timer firing behind it would
        // write the file its Don't Save is about to discard. Cancel leaves the tab dirty; the
        // next edit or focus change re-arms.
        didSet { if unsavedPrompt != nil { cancelAutosaveTimers() } }
    }
    /// True while `resolveUnsaved` carries out the operator's answer — the prompt is down, but
    /// its Save or Don't Save is still running. Autosave stays off for it as for the prompt.
    @ObservationIgnored private var unsavedResolving = false
    /// Bumps when a quit prompt resolved to quit — the app replies yes to AppKit's terminate.
    public private(set) var quitApproved = 0
    /// Bumps when a quit prompt resolved to stay — Cancel, or a Save that could not finish — and
    /// the app replies no.
    public private(set) var quitCancelled = 0
    /// One dirty tab a quit would lose, in any scope (final review I3).
    private struct UnsavedTab {
        /// nil: the scope on screen. Otherwise a project or conversation the window left, whose
        /// panes `PaneStore` keeps in memory.
        let scope: LayoutScope?
        /// The tab's title, with where it is for a hidden scope: `confirm.go (billing)`.
        let title: String
    }

    /// Every dirty tab in every scope: the one on screen in canvas order, then each hidden
    /// scope's, in every organisation (`PaneStore.editorDirtyTabsInHiddenScopes`). What a quit
    /// would lose — every switch keeps them, so only a quit must ask about them all.
    private func everyUnsavedTab() async -> [UnsavedTab] {
        let visible = dirtyEditorTabs().map { UnsavedTab(scope: nil, title: $0.title) }
        let hidden = await panes.editorDirtyTabsInHiddenScopes().map {
            UnsavedTab(scope: $0.scope, title: "\($0.title) (\($0.place))")
        }
        return visible + hidden
    }

    /// Whether Save can write `t` from here: only what is on screen (a scratch tab opens its path
    /// field). A hidden tab would be written outside an action (Invariant 2) or need the window to
    /// jump to its scope (Rule 6), so hidden tabs offer Don't Save and Cancel only; the operator
    /// saves them from their own scope.
    private func saveCanReach(_ t: UnsavedTab) -> Bool {
        t.scope == nil
    }

    /// Every dirty tab, by pane, in canvas order — what closing everything would lose.
    private func dirtyEditorTabs(
        in only: String? = nil
    ) -> [(pane: String, tab: Int, subject: EditorTabSubject, title: String, isScratch: Bool, text: String)] {
        var out: [(pane: String, tab: Int, subject: EditorTabSubject, title: String, isScratch: Bool, text: String)] = []
        for pane in layoutSnapshot.panes where pane.kind == "editor" && (only == nil || pane.id == only) {
            guard let s = editor(pane.id) else { continue }
            let titles = editorTabTitles(s.tabs)
            for (i, t) in s.tabs.enumerated() where t.dirty {
                out.append((pane.id, i, t.subject, titles[i], t.isScratch, t.text))
            }
        }
        return out
    }

    /// Raises the prompt — unless one is already up, which this never replaces: it answers false
    /// and nothing happens, the question on screen still waiting (a quit's above all: replacing
    /// it would leave AppKit's terminate unanswered).
    @discardableResult
    private func askUnsaved(_ intent: UnsavedIntent, titles: [String], canSave: Bool = true) -> Bool {
        guard unsavedPrompt == nil else {
            status = "unsaved changes are already being asked about — answer that first"
            return false
        }
        unsavedPrompt = UnsavedPrompt(intent: intent, files: titles, canSave: canSave)
        return true
    }

    /// The quit or organisation-switch prompt for `tabs`: Save is offered while it can write at
    /// least one of them (`saveCanReach`).
    private func askUnsaved(_ intent: UnsavedIntent, tabs: [UnsavedTab]) {
        askUnsaved(intent, titles: tabs.map(\.title), canSave: tabs.contains(where: saveCanReach))
    }

    /// Save / Don't Save / Cancel. Save writes every listed tab (a scratch tab asks for its path
    /// first, and the intent does not run); Don't Save drops them; then the intent runs. Cancel
    /// runs nothing. A quit that does not run says so through `quitCancelled`.
    public func resolveUnsaved(_ choice: UnsavedChoice) async {
        guard let prompt = unsavedPrompt else { return }
        unsavedResolving = true
        defer { unsavedResolving = false }
        unsavedPrompt = nil
        let saved = choice == .cancel ? UnsavedSaveOutcome.stop : await saveForUnsaved(prompt, choice)
        // Save wrote what it could reach and the rest is asked about again: nothing is answered yet.
        if saved == .reasked { return }
        guard saved == .proceed else {
            if prompt.intent == .quit { quitCancelled += 1 }
            return
        }
        switch prompt.intent {
        case .closeTab(let pane, let subject):
            // By subject, in one dispatch: the operator or the agent may make another tab active
            // meanwhile, and a close of "the active tab" would drop that one (final review I1). A
            // tab already gone closes nothing.
            guard editor(pane)?.tabs.contains(where: { $0.subject == subject }) == true else { break }
            var params: [String: JSONValue] = ["pane": .string(pane), "discard": .bool(true)]
            params.merge(editorTabParams(subject)) { $1 }
            _ = await dispatch("editor_close", .object(params))
        case .closePane(let pane):
            // `discard`: the operator chose; `pane_close` refuses dirty tabs without it.
            _ = await dispatchLayout("pane_close", .object(["id": .string(pane), "discard": .bool(true)]))
        case .quit:
            quitApproved += 1
            await refreshLayout()
            await refreshPanes()
            return
        }
        await refreshLayout()
        await refreshPanes()
    }

    private enum UnsavedSaveOutcome { case proceed, stop, reasked }

    /// Save's half of `resolveUnsaved`: `.proceed` when the intent may run. Don't Save has nothing
    /// to write. A scratch tab on screen is made active and opens its path field, and a failed save
    /// keeps everything (Rule 8: its error is in the tab); either answers `.stop`.
    ///
    /// A quit then asks again, alone, about the dirty tabs of hidden
    /// scopes (final review I3), with Don't Save and Cancel only (`.reasked`): Save cannot reach
    /// them (`saveCanReach`), and the window never jumps to another scope to save them (Rule 6).
    private func saveForUnsaved(_ prompt: UnsavedPrompt, _ choice: UnsavedChoice) async -> UnsavedSaveOutcome {
        guard choice == .save else { return .proceed }
        let scope: String?
        switch prompt.intent {
        case .closeTab(let pane, _), .closePane(let pane): scope = pane
        case .quit: scope = nil
        }
        var targets = dirtyEditorTabs(in: scope)
        if case .closeTab(let pane, let subject) = prompt.intent {
            targets = targets.filter { $0.pane == pane && $0.subject == subject }
        }
        for t in targets {
            guard let s = editor(t.pane), let i = s.tabs.firstIndex(where: { $0.subject == t.subject }) else { continue }
            if t.isScratch {
                // The path field saves the ACTIVE tab, so this one becomes it first.
                if s.active != i { _ = await focusEditorTab(pane: t.pane, index: i) }
                editorSaveAsRequest = t.pane
                await refreshPanes()
                return .stop
            }
            guard let path = s.tabs[i].path,
                  await dispatch("editor_save", .object(["pane": .string(t.pane), "path": .string(path)])) != nil
            else {
                await refreshPanes()
                return .stop
            }
        }
        guard scope == nil else { return .proceed }
        let unreachable = await everyUnsavedTab().filter { !saveCanReach($0) }
        guard unreachable.isEmpty else {
            unsavedPrompt = UnsavedPrompt(intent: prompt.intent, files: unreachable.map(\.title), canSave: false)
            return .reasked
        }
        return .proceed
    }

    private func focusEditorTab(pane: String, index: Int) async -> Bool {
        let ok = await dispatch("editor_focus_tab", .object([
            "pane": .string(pane), "index": .integer(Int64(index)),
        ])) != nil
        await refreshPanes()
        return ok
    }

    /// AppKit asked to quit: true when nothing is unsaved; otherwise the quit prompt is up, and
    /// `quitApproved` or `quitCancelled` answers later. **A quit outranks any other prompt on
    /// screen**: that one's intent simply does not run (as its Cancel would), because a quit left
    /// unasked would leave AppKit's terminate waiting forever.
    ///
    /// Every scope counts (final review I3): a tab left dirty in another project or conversation
    /// is lost by a quit as surely as one on screen.
    public func requestQuit() async -> Bool {
        let dirty = await everyUnsavedTab()
        guard !dirty.isEmpty else { return true }
        if unsavedPrompt?.intent != .quit {
            unsavedPrompt = UnsavedPrompt(intent: .quit, files: dirty.map(\.title),
                                          canSave: dirty.contains(where: saveCanReach))
        }
        return false
    }

    /// The operator's typing (the one non-action path) — straight to the store, then the cell.
    /// By the tab's subject, never its position; `basis` is the agent-edit serial the page had
    /// applied (`PaneStore.editorBufferDidChange`).
    public func editorBufferDidChange(pane: String, subject: EditorTabSubject, text: String, basis: Int) async {
        await panes.editorBufferDidChange(paneId: pane, subject: subject, text: text, basis: basis)
        await refreshEditor(pane: pane)
    }

    /// Cursor, selection, visible lines and scroll from Monaco: into the store at once; into the
    /// layout's saved tabs on a trailing debounce (`editorTabsDelay` after the last report), never
    /// awaited here — a scroll reports every frame, and each layout write is a file.
    public func editorViewDidReport(pane: String, subject: EditorTabSubject, cursor: EditorPosition,
                                    selection: EditorRange?, visibleRange: ClosedRange<Int>?, scrollTop: Double) async {
        await panes.editorViewDidReport(paneId: pane, subject: subject, cursor: cursor, selection: selection,
                                        visibleRange: visibleRange, scrollTop: scrollTop)
        await refreshEditor(pane: pane)
        scheduleEditorTabsWrite(pane: pane)
    }

    // MARK: Autosave (3b-v)

    /// How long after the last edit `pause` mode saves. Tests shorten it.
    @ObservationIgnored var editorAutosaveDelay: Duration = .seconds(1)
    /// Autosave's memory of each pane's tabs (`EditorAutosave`).
    @ObservationIgnored private var editorAutosave = EditorAutosave()
    /// The pending pause timer per "pane\npath".
    @ObservationIgnored private var editorAutosaveTimers: [String: Task<Void, Never>] = [:]
    /// Autosaves dispatched (a test seam).
    @ObservationIgnored private(set) var editorAutosaveCount = 0
    /// Autosaves running now, by id: each removes itself when it ends, and a test can wait for
    /// them.
    @ObservationIgnored private var editorAutosaveRuns: [UUID: Task<Void, Never>] = [:]

    /// What asked for an autosave: the mode it requires when it dispatches (M-3 — switching
    /// Autosave to Off, or to the other mode, before it fires saves nothing).
    private enum AutosaveTrigger { case pause, focus }

    /// One look at an editor pane's snapshot: arm the timers for edited tabs, save the tab a
    /// pane switched away from. Called from `setCell`, which every editor refresh passes through.
    private func autosaveObserve(pane: String, snapshot: EditorSnapshot) {
        let step = editorAutosave.observe(pane: pane, snapshot: snapshot, mode: editorSettings.app.autosave)
        for path in step.arm { armAutosave(pane: pane, path: path) }
        if !step.saveNow.isEmpty { runAutosave(pane: pane, paths: step.saveNow, trigger: .focus) }
    }

    private func armAutosave(pane: String, path: String) {
        // Behind the unsaved prompt nothing arms: its Don't Save must still be able to discard.
        guard unsavedPrompt == nil, !unsavedResolving else { return }
        let key = pane + "\n" + path
        editorAutosaveTimers[key]?.cancel()
        let delay = editorAutosaveDelay
        editorAutosaveTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.editorAutosaveTimers[key] = nil
            // A run, not an inline await: a later edit re-arms this key, and must not cancel a save in flight.
            self.runAutosave(pane: pane, paths: [path], trigger: .pause)
        }
    }

    private func cancelAutosaveTimers() {
        editorAutosaveTimers.values.forEach { $0.cancel() }
        editorAutosaveTimers = [:]
    }

    /// Saves `paths` in `pane` one after another, in ONE task, so no two of them race for the
    /// pane's single save slot (I-1). Answers the run, which ends by removing itself.
    @discardableResult
    private func runAutosave(pane: String, paths: [String], trigger: AutosaveTrigger) -> Task<Void, Never> {
        let id = UUID()
        // The body cannot start before this method returns (both on the main actor), so the
        // entry is in place before the body's last line removes it.
        let run = Task { [weak self] in
            for path in paths {
                guard !Task.isCancelled, let self else { break }
                await self.autosave(pane: pane, path: path, trigger: trigger)
            }
            self?.editorAutosaveRuns[id] = nil
        }
        editorAutosaveRuns[id] = run
        return run
    }

    /// Whether an autosave may write now, apart from the tab itself: never behind the unsaved
    /// prompt or while it is being answered (Rule 1 — Don't Save must mean what it says), never
    /// during an organisation switch (`switching`) or a project / conversation swap
    /// (`layoutActivating`, which covers the whole swap), and only in the mode that asked (M-3).
    private func autosaveMayWrite(_ trigger: AutosaveTrigger) -> Bool {
        let mode: EditorAutosaveMode = trigger == .pause ? .pause : .focus
        return !Task.isCancelled && unsavedPrompt == nil && !unsavedResolving && !switching
            && !layoutActivating && editorSettings.app.autosave == mode
    }

    /// Saves one tab through `editor_save` — the same path as ⌘S (Decision 36). Eligibility is
    /// re-checked now: since the timer was armed the tab may have been saved, closed, or marked
    /// changed on disk.
    ///
    /// **A save in flight for the pane is waited for, never dropped** (I-1): Rule 5 allows one
    /// `editor_save` per pane at a time, so this waits for that save to end and then looks at
    /// the tab again — an edit typed during a slow ⌘S is then written. If the save it waited
    /// on was cancelled (the saving tick's Cancel), the operator's Cancel stands and this
    /// writes nothing; the next edit or focus change tries again.
    ///
    /// A failed write leaves the tab dirty with the failure on it, as a failed ⌘S does. A
    /// success leaves `status` alone (I-3, Rule 8): it does not go through `dispatch`, which
    /// clears the line on success and would wipe an unread failure.
    private func autosave(pane: String, path: String, trigger: AutosaveTrigger) async {
        var waited: Task<Void, Never>?
        while true {
            while let inFlight = editorSaves[pane] {
                if inFlight == waited {
                    // Finished, but its owner has not cleared the slot yet: let it run first.
                    // Registering over it would let the owner's clear wipe this save's entry.
                    await Task.yield()
                    continue
                }
                await inFlight.value
                if inFlight.isCancelled { return }
                waited = inFlight
            }
            guard autosaveMayWrite(trigger) else { return }
            let snapshot = await panes.editorSnapshot(paneId: pane)
            guard let tab = snapshot.tabs.first(where: { $0.path == path }), editorAutosaveEligible(tab) else { return }
            // The snapshot read above suspended: a ⌘S may have registered since — wait for it and
            // look again — or a prompt been raised, a switch begun, the mode changed, or this run
            // cancelled. Nothing suspends between these checks and the dispatch.
            if editorSaves[pane] != nil { continue }
            guard autosaveMayWrite(trigger) else { return }
            break
        }
        editorAutosaveCount += 1
        // Registered like ⌘S's save, so the saving tick's Cancel (`cancelSave`) reaches it (Rule 4).
        let params: JSONValue = .object(["pane": .string(pane), "path": .string(path)])
        let environment = self.environment
        let save = Task {
            do {
                _ = try await self.registry.dispatch(name: "editor_save", params: params, origin: .ui,
                                                     caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            } catch where self.isRoutineCancel(error) || apiSurfaceRefusalIsSilent(error) {
                // A cancelled save is told nothing, as `dispatch` does.
            } catch {
                self.status = self.statusDescribingFailure("editor_save", error)
            }
        }
        editorSaves[pane] = save
        await save.value
        editorSaves[pane] = nil
        await refreshEditor(pane: pane)
    }

    /// `focus` mode, when focus leaves `pane`: every eligible tab in it saves, in turn.
    private func autosaveFocusLeft(pane: String) {
        guard let snapshot = editor(pane) else { return }
        let paths = EditorAutosave.focusLeft(snapshot, mode: editorSettings.app.autosave)
        if !paths.isEmpty { runAutosave(pane: pane, paths: paths, trigger: .focus) }
    }

    /// Wakil stopped being the active app (WakilApp forwards the notification): in `focus` mode,
    /// every eligible tab in every editor pane on the canvas saves. Each pane's saves are a run,
    /// like any other autosave.
    public func editorAppDidResignActive() async {
        for pane in layoutSnapshot.panes where pane.kind == "editor" {
            guard let snapshot = editor(pane.id) else { continue }
            let paths = EditorAutosave.focusLeft(snapshot, mode: editorSettings.app.autosave)
            guard !paths.isEmpty else { continue }
            await runAutosave(pane: pane.id, paths: paths, trigger: .focus).value
        }
    }

    /// TEST-ONLY: waits until no autosave timer or run is pending.
    func settleEditorAutosave() async {
        while !editorAutosaveTimers.isEmpty || !editorAutosaveRuns.isEmpty {
            let timers = Array(editorAutosaveTimers.values), runs = Array(editorAutosaveRuns.values)
            for t in timers { await t.value }
            for r in runs { await r.value }
            await Task.yield()
        }
    }

    /// How long after the last view report the saved tabs are written. Tests shorten it.
    @ObservationIgnored var editorTabsDelay: Duration = .milliseconds(500)
    /// The pending debounced write per pane.
    @ObservationIgnored private var editorTabsWrites: [String: Task<Void, Never>] = [:]
    /// Debounced saved-tabs writes that ran (a test seam).
    @ObservationIgnored private(set) var editorTabsWriteCount = 0

    /// (Re)starts `pane`'s trailing write. It reads the store when it fires, so what it writes is
    /// the latest; tab switches and closes persist through their own actions.
    ///
    /// **`refreshLayout`, not `persistLayout`**: the saved tabs live on the `Pane` in
    /// `LayoutStore`, and `persistLayout` writes the snapshot already in hand — the one from
    /// before this change. `refreshLayout` reads it back and writes only when it moved.
    private func scheduleEditorTabsWrite(pane: String) {
        editorTabsWrites[pane]?.cancel()
        let delay = editorTabsDelay
        editorTabsWrites[pane] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.editorTabsWrites[pane] = nil
            await self.layout.setEditorTabs(id: pane, to: editorSavedTabs(await self.panes.editorSnapshot(paneId: pane)))
            self.editorTabsWriteCount += 1
            await self.refreshLayout()
        }
    }

    /// TEST-ONLY: waits for `pane`'s pending saved-tabs write, if any.
    func settleEditorTabsWrite(pane: String) async {
        await editorTabsWrites[pane]?.value
    }

    /// The file's text on disk now, for Compare — a read through the files client, no state change.
    /// Nil when the path is outside the project's roots, missing, or the read failed.
    public func editorDiskText(pane: String, path: String) async -> String? {
        guard let files = paletteClients.files else { return nil }
        guard let clean = confinedPath(path, roots: gitRootPaths)?.path else { return nil }
        guard case .object(let o)? = try? await files.callTool(
                  name: "files_read", arguments: .object(["path": .string(clean)]), timeout: MCPClient.readReplyTimeout),
              o["isError"] != .bool(true),
              case .object(let content)? = o["structuredContent"],
              content["exists"] != .bool(false),
              case .string(let text)? = content["text"] else { return nil }
        return text
    }

    /// One editor pane's cell, re-read — `refreshTerminal`'s shape, for a keystroke.
    private func refreshEditor(pane: String) async {
        let snapshot = await panes.snapshot(paneId: pane, kind: "editor")
        guard snapshot.editor != nil else { return }
        setCell(pane, snapshot)
        // A tree action's reply comes through here, not `refreshPanes`.
        await mirrorEditorFiles()
    }

    // MARK: Palette — one plane, ⌘P and ⌘K

    /// The clients ⌘P reads directly: tables, API entries and changed files are listed without
    /// drawing a pane, so none of them is a dispatch.
    let paletteClients: PaletteClients

    /// Bumped by every root build and by `paletteClosed()`. A late answer — a slow source, a
    /// background table refresh — carries the number it was asked under and is dropped unless
    /// it is still current, so rows never land in a palette that closed or moved on.
    @ObservationIgnored private var paletteGeneration = 0

    /// The context the current root list was built in. `performPalette` refuses once the
    /// organisation or project has moved past it, and a `…` command's params read it.
    @ObservationIgnored private var paletteBuiltFor: PaletteContext?

    /// Where a list was read: organisation, project and environment. The environment is in it
    /// because a table row read in `staging` must not open the same-named table in `qa`.
    struct PaletteIdentity: Equatable {
        var organisation: String
        var project: String
        var environment: String

        /// Stamped by `invalidatePalette` when the window leaves an organisation: whatever rows
        /// are still on screen were read in an organisation the window has left, and no build
        /// since has said where. It names no organisation — a NUL is no org's name — so it
        /// matches no identity and `performPalette` refuses until the next root build.
        static let organisationLeft = PaletteIdentity(organisation: "\u{0}", project: "", environment: "")
    }

    private var paletteIdentity: PaletteIdentity {
        PaletteIdentity(organisation: organization, project: project, environment: environment)
    }

    /// Where the root list last DELIVERED was read — stamped when its rows reach the caller, never
    /// when a build begins (final fix wave, item 1): a refresh in a new environment leaves the old
    /// rows on screen until its own land, and those rows must still be checked against the place
    /// they were read, not the one the refresh is reading.
    @ObservationIgnored private var paletteBuiltIn: PaletteIdentity?

    /// The build in progress — its generation, where it reads, and the context ⌘K's predicates
    /// read — until its rows are delivered (`paletteDelivered`).
    @ObservationIgnored private var paletteBuilding: (generation: Int, identity: PaletteIdentity, context: PaletteContext)?

    /// Each delivered build, by generation (the last few): the controller names the generation of
    /// the rows on screen (`performPalette(_:shown:)`), and they are checked against where THAT
    /// build read, whatever build has landed since.
    @ObservationIgnored private var paletteBuilds: [Int: (identity: PaletteIdentity, context: PaletteContext)] = [:]

    /// The window left an organisation while this palette was open. A step row with no stamp is
    /// then refused rather than checked against a root built since, in the new organisation.
    /// Cleared by `paletteClosed()`.
    @ObservationIgnored private var paletteLeftOrganisation = false

    /// Every close, counted: a run compares it with the count it began under, and one that
    /// finishes after its palette closed moves no keyboard (rule 6).
    @ObservationIgnored private var paletteCloses = 0

    /// recentKey → typed values, newest first: this window's recents (spec rule 9), handed to
    /// every palette it opens (`makePalette`) and kept from each (`keepPaletteRecents`). What was
    /// typed in one organisation is that organisation's: `invalidatePalette` empties it.
    @ObservationIgnored public private(set) var paletteRecents: [String: [String]] = [:]

    /// Bumped by `invalidatePalette`: a palette opened before an organisation switch keeps
    /// nothing into the next one.
    @ObservationIgnored public private(set) var paletteEpoch = 0

    /// Where each step's rows were read, by the step's `commandId`, stamped when
    /// `paletteChoices` answers. **A step outlives a root refresh** (`PaletteModel.contextChanged`
    /// keeps a drill step and a still-listed command step), so its rows are checked against this,
    /// never against the root's newer identity. Cleared by `paletteClosed()`.
    @ObservationIgnored private var paletteStepStamps: [String: PaletteIdentity] = [:]

    /// The whole ⌘P list last handed out for a generation, so a background table refresh can
    /// replace the tables in it without dropping a late source's rows.
    @ObservationIgnored private var paletteLatest: (generation: Int, rows: [PaletteEntry])?

    /// The tables a background refresh brought for a generation, laid over every later
    /// delivery so a slow source landing after it cannot put the cached tables back.
    @ObservationIgnored private var paletteFreshTables: (generation: Int, rows: [PaletteEntry])?

    /// One table cache per organisation and project (P7 b); the environment is keyed inside
    /// each. **A cache per pair rather than one cleared on a switch**: a background refresh
    /// asked under the old project can still land after the switch, and it lands in that
    /// project's cache, where it is true, instead of in the new one. An ORGANISATION switch
    /// does clear them all (`invalidatePalette`, Invariant 4).
    @ObservationIgnored private var paletteTableCaches: [String: TableCache] = [:]

    /// ⌘K's Send, per api pane: a token the pane watches and answers by pressing its own Send
    /// (`ApiPane.press`) — the flush of every held field, the `api_request`/`api_send` choice
    /// and the statement the plane reads back all live in the pane, not here. A token rather
    /// than a flag, for `QueryLineRestore`'s reason: two presses must be two events.
    public private(set) var apiSendRequests: [String: Int] = [:]
    @ObservationIgnored private var apiSendRequestToken = 0

    /// The token `pane` last had Send asked of it under, or `nil`.
    public func apiSendRequest(pane paneId: String) -> Int? { apiSendRequests[paneId] }

    /// What ⌘K's predicates and params read, taken now. The organisation and project are read
    /// first, so the context names the moment it began.
    public func paletteContext() async -> PaletteContext {
        let organisation = organization, project = self.project
        let focused = layoutSnapshot.focusedId.flatMap { id in layoutSnapshot.panes.first { $0.id == id } }
        let table = focused.flatMap { tables[$0.id] }
        let sending = focused.flatMap { api($0.id)?.sending }
        // A listing that failed keeps the command: its step shows the failure whole (rule 8).
        let environments = await paletteEnvironments()
        let hasEnvironments = !environments.listings.isEmpty || environments.note != nil
        let projectCount = await currentOrganisationProjects().items.count
        let providerCount = await providerPaletteItems().items.count
        let editorActiveIsFile: Bool = {
            guard let f = focused, f.kind == "editor", let s = editor(f.id), let i = s.active, i < s.tabs.count else { return false }
            return s.tabs[i].path != nil
        }()
        let editorActiveDiff: EditorActiveDiff? = {
            guard let f = focused, f.kind == "editor", let s = editor(f.id), let i = s.active, i < s.tabs.count,
                  case .diff(let root, let path, let group) = s.tabs[i].subject else { return nil }
            return EditorActiveDiff(path: root + "/" + path, group: group)
        }()
        return PaletteContext(
            focusedPane: focused.map { FocusedPane(id: $0.id, kind: $0.kind) },
            apiSendInFlight: sending != nil,
            // The DB pane's own ‹ › rules (`DBPane.pageControls`).
            dbPageHasNext: table.map { $0.pageable && $0.truncated } ?? false,
            dbPageHasPrevious: table.map { $0.pageable && $0.offset > 0 } ?? false,
            hasEnvironments: hasEnvironments, projectCount: projectCount, providerCount: providerCount,
            editorActiveIsFile: editorActiveIsFile, organisation: organisation, project: project,
            editorActiveDiff: editorActiveDiff, conversationOnScreen: conversationOnScreen)
    }

    /// The root list for `mode`: ⌘K's catalog for the context now, or ⌘P's sources.
    ///
    /// **Every call is a new generation** (P7 a): a source that answers after this returns
    /// reaches `onLate` with the whole list — but only while this is still the latest build and
    /// the palette has not closed. A ⌘P whose tables came from the cache asks `wakil-db` again
    /// in the background (P7 d), and the fresh tables arrive the same way.
    public func paletteRootEntries(
        mode: PaletteMode, onLate: @escaping @Sendable ([PaletteEntry]) -> Void
    ) async -> [PaletteEntry] {
        await paletteRoot(mode: mode) { onLate($0.rows) }.rows
    }

    /// One root list and the generation it was built under: what the controller holds on screen
    /// and names back to `performPalette(_:shown:)`.
    public struct PaletteRoot: Sendable {
        public let generation: Int
        public let rows: [PaletteEntry]
    }

    /// `paletteRootEntries`, with each delivery's generation. **The rows are stamped as they are
    /// delivered** — here, and for a late source or a table refresh in `paletteLate` and
    /// `paletteTablesRefreshed` — never when the build begins.
    public func paletteRoot(
        mode: PaletteMode, onLate: @escaping @Sendable (PaletteRoot) -> Void
    ) async -> PaletteRoot {
        paletteGeneration += 1
        let generation = paletteGeneration
        let identity = paletteIdentity
        let context = await paletteContext()
        // An older build finishing after a newer one must not leave its context behind.
        if generation == paletteGeneration {
            paletteBuilding = (generation, identity, context)
        }
        guard mode == .open else {
            let rows = CommandCatalog.entries(for: context)
            paletteDelivered(generation)
            return PaletteRoot(generation: generation, rows: rows)
        }

        let tables = paletteTables()
        var cached = false
        if let tables { cached = await tables.cache.databases(env: tables.environment) != nil }
        let late: @Sendable ([PaletteEntry]) -> Void = { [weak self] rows in
            Task { @MainActor in self?.paletteLate(rows, generation: generation, onLate: onLate) }
        }
        let rows = await openModeEntries(paletteOpenSources(tables: tables?.source), onLate: late)
        if generation == paletteGeneration, paletteLatest?.generation != generation {
            paletteLatest = (generation, rows)
        }
        paletteDelivered(generation)
        if cached, let source = tables?.source {
            Task { [weak self] in
                let fresh = await source.refresh()
                self?.paletteTablesRefreshed(fresh, generation: generation, onLate: onLate)
            }
        }
        return PaletteRoot(generation: generation, rows: rows)
    }

    /// The build of `generation` reached the caller: its rows are now the ones on screen, read
    /// where it began. A build superseded before delivery stamps nothing.
    private func paletteDelivered(_ generation: Int) {
        guard generation == paletteGeneration, let building = paletteBuilding, building.generation == generation
        else { return }
        paletteBuiltFor = building.context
        paletteBuiltIn = building.identity
        paletteBuilds[generation] = (building.identity, building.context)
        paletteBuilds = paletteBuilds.filter { $0.key > generation - Self.paletteBuildsKept }
    }

    /// How many delivered builds are remembered: the controller shows the latest, and an older
    /// one only in a race, so a few is plenty.
    private static let paletteBuildsKept = 4

    /// ⌘P or ⌘K, pressed. A token rather than a flag, for `QueryLineRestore`'s reason: two
    /// presses are two events.
    public struct PaletteKeyPress: Sendable, Equatable {
        public let mode: PaletteMode
        public let serial: Int
    }

    /// The last ⌘P / ⌘K. **Pressed through the menu** (`AppScene`), which is the one place a
    /// shortcut fires whatever holds focus — the composer, a query line, a terminal, the diff.
    /// The window opens the palette in `mode`, or, when it is open, switches it (`modeKey`).
    public private(set) var paletteKeyPress: PaletteKeyPress?
    @ObservationIgnored private var paletteKeySerial = 0

    /// Whether the palette's plane is up. Panes stop owning the keyboard under it, as they do
    /// under the org plane and the confirmation plane.
    public private(set) var paletteShowing = false

    /// Until when a fast-path action leaves the keyboard in the composer (spec: Rule 6), so the
    /// next line can be typed. Set before the dispatch; a pane that would take the keyboard as the
    /// action lands (an editor's arriving tab, Rule 3) stands down until then. Timed, because the
    /// editor's own take is retried for up to a second while its web view joins the window.
    public internal(set) var composerHoldsKeyboardUntil: ContinuousClock.Instant?
    public var composerHoldsKeyboard: Bool {
        composerHoldsKeyboardUntil.map { ContinuousClock.now < $0 } ?? false
    }

    public func paletteKey(_ mode: PaletteMode) {
        paletteKeySerial += 1
        paletteKeyPress = PaletteKeyPress(mode: mode, serial: paletteKeySerial)
    }

    /// The plane went up. `paletteClosed()` is its other half, on every close path.
    public func paletteOpened() {
        paletteShowing = true
    }

    /// The palette closed: anything still on its way to it is dropped.
    public func paletteClosed() {
        paletteGeneration += 1
        paletteCloses += 1
        paletteStepStamps = [:]
        paletteBuilding = nil
        paletteBuilds = [:]
        paletteLeftOrganisation = false
        paletteShowing = false
    }

    /// A fresh palette for one open, holding this window's recents.
    public func makePalette(mode: PaletteMode) -> PaletteModel {
        var palette = PaletteModel(mode: mode)
        palette.recents = paletteRecents
        return palette
    }

    /// Keeps a palette's recents as this window's — after a run, a pop and a close. A palette
    /// opened before the window left its organisation (`epoch` is `paletteEpoch` at open) keeps
    /// nothing: its recents were typed in the organisation left.
    public func keepPaletteRecents(_ recents: [String: [String]], openedAt epoch: Int) {
        guard epoch == paletteEpoch else { return }
        paletteRecents = recents
    }

    /// The window left an organisation (`invalidateForOrgChange`): nothing the palette read
    /// there survives it (Invariant 4). **The generation is bumped, not zeroed** — zeroing
    /// would let a late answer asked under an old number match again — so every source and
    /// table refresh still on its way is dropped. The table caches go wholesale: a refresh
    /// already in flight holds its own cache and lands there, in a cache nothing reads.
    /// `paletteBuiltIn` becomes `.organisationLeft` rather than `nil`, because `nil` means
    /// "never built" and `performPalette` lets that run unchecked.
    private func invalidatePalette() {
        paletteGeneration += 1
        paletteBuiltFor = nil
        paletteBuiltIn = .organisationLeft
        paletteBuilding = nil
        paletteBuilds = [:]
        paletteLeftOrganisation = true
        paletteStepStamps = [:]
        paletteLatest = nil
        paletteFreshTables = nil
        paletteTableCaches = [:]
        paletteRecents = [:]
        paletteEpoch += 1
    }

    /// What the palette holds of the organisation it was built in, for the org-switch test.
    struct PaletteCacheForTesting {
        let builtFor: PaletteContext?
        let builtIn: PaletteIdentity?
        let building: Bool
        let builds: [Int]
        let stepStamps: [String: PaletteIdentity]
        let latest: [PaletteEntry]?
        let freshTables: [PaletteEntry]?
        let tableCacheKeys: [String]
    }

    var paletteCacheForTesting: PaletteCacheForTesting {
        PaletteCacheForTesting(
            builtFor: paletteBuiltFor, builtIn: paletteBuiltIn, building: paletteBuilding != nil,
            builds: Array(paletteBuilds.keys), stepStamps: paletteStepStamps,
            latest: paletteLatest?.rows, freshTables: paletteFreshTables?.rows,
            tableCacheKeys: Array(paletteTableCaches.keys))
    }

    /// A choice step's rows: a database row's tables (`drill:tables:<db>`), else the catalog
    /// command's `ChoiceSource`. **Projects are the current organisation's only** (P7 e,
    /// Invariant 4), through the same reader ⌘P's Projects group uses.
    public func paletteChoices(for commandId: String) async -> [PaletteEntry] {
        paletteStepStamps[commandId] = paletteIdentity
        if let rows = await paletteTables()?.source.drillEntries(commandId: commandId) { return rows }
        guard case .choice(let source, _)? = CommandCatalog.command(id: commandId)?.input else { return [] }
        return await choiceEntries(source, readers: ChoiceReaders(
            environments: { [weak self] in await self?.paletteEnvironments() ?? ([], nil) },
            projects: { [weak self] in await self?.currentOrganisationProjects() ?? ([], nil) },
            providers: { [weak self] in await self?.providerPaletteItems() ?? ([], nil) }))
    }

    /// Runs one effect. Answers the **whole** error text when it failed (rule 8), `nil` when it
    /// ran — or when there was nothing to run (`.needChoices` is answered by `paletteChoices`,
    /// `.close` by the caller). A pane it opens is focused (spec §7).
    ///
    /// **Through the registry, origin `ui`, on the window's own paths**: a plain action goes
    /// through `dispatchLayout`, so busy, the journal, the write gate and the confirmation plane
    /// are the ones every other control meets. Four do more than one dispatch and run the path
    /// their control already runs (P5): Send asks the api pane to press its own Send, and the
    /// environment, project and provider switches run `setEnvironment`, `setProject` and
    /// `setProvider` — the provider's five refusals included. `setProvider` is called rather than
    /// `session_set_provider` dispatched, because that action only parks a request for
    /// `providerSwitchPump` and would report the park's success before any refusal could run.
    ///
    /// **Refused when the context moved** (Review Focus 3): rows built for one organisation and
    /// project never act on another; nothing is dispatched.
    ///
    /// `shown` is the generation of the root rows on screen (`PaletteRoot`), when the caller has
    /// one: a root row is checked against where THAT build read — not a refresh begun or landed
    /// since (final fix wave, item 1). A step's rows are checked against the step's own stamp.
    public func performPalette(_ effect: PaletteEffect, shown: Int? = nil) async -> String? {
        if let refusal = paletteRefusal(effect, shown: shown) { return refusal }
        let mark = PaletteRunMark(status: statusWrites, closes: paletteCloses)
        switch effect {
        case .run(let action, _):
            return await performPaletteAction(action, mark: mark)
        case .runCommand(let commandId, let value):
            guard let command = CommandCatalog.command(id: commandId) else {
                return "no palette command \(commandId)"
            }
            let context: PaletteContext
            if let built = shown.flatMap({ paletteBuilds[$0]?.context }) ?? paletteBuiltFor {
                context = built
            } else {
                context = await paletteContext()
            }
            return await performPaletteAction(
                .dispatch(action: command.action, params: command.params(context, value)), mark: mark)
        case .needChoices, .close:
            return nil
        }
    }

    /// Why `effect` must not run here, or `nil`. A step's rows answer to the step's stamp; a
    /// step read before the window left its organisation has none, and is refused. A root row
    /// answers to the build named by `shown`, else to the last one delivered.
    private func paletteRefusal(_ effect: PaletteEffect, shown: Int?) -> String? {
        let orgChanged = "the organisation changed under the palette; reopen it"
        let step: String?
        switch effect {
        case .run(_, let s): step = s
        case .runCommand(let commandId, _):
            // A text command's value was typed, not read: only a choice step's rows are a read.
            if case .choice? = CommandCatalog.command(id: commandId)?.input { step = commandId } else { step = nil }
        default: step = nil
        }
        let stamp: PaletteIdentity?
        if let step, let stepStamp = paletteStepStamps[step] {
            stamp = stepStamp
        } else if step != nil, paletteLeftOrganisation {
            return orgChanged
        } else if let shown {
            guard let build = paletteBuilds[shown] else {
                return paletteBuiltIn == .organisationLeft || paletteLeftOrganisation
                    ? orgChanged : "the palette's list is out of date; reopen it"
            }
            stamp = build.identity
        } else {
            stamp = paletteBuiltIn
        }
        if stamp == .organisationLeft { return orgChanged }
        if let stamp, stamp != paletteIdentity {
            let place = "\(stamp.organisation)/\(stamp.project)"
                + (stamp.environment.isEmpty ? "" : " in \(stamp.environment)")
            return "the palette was opened for \(place); reopen it"
        }
        return nil
    }

    /// Where a palette run began: the `status` write count (`paletteFailure`) and the close count
    /// (`focusActedOn`).
    private struct PaletteRunMark {
        let status: Int
        let closes: Int
    }

    private func performPaletteAction(_ action: PaletteAction, mark: PaletteRunMark) async -> String? {
        switch action {
        case .dispatch(let name, let params):
            return await paletteDispatch(name, params, mark: mark)
        case .focusPane(let id):
            return await focusPane(id: id) ? nil : paletteFailure(since: mark)
        case .setProject(let name):
            return await setProject(name) ? nil : paletteFailure(since: mark)
        case .setProvider(let id):
            // `setProvider`'s every refusal lands in `status`, and its success clears it.
            await setProvider(id)
            return paletteFailure(since: mark)
        case .resumeSession(let id):
            return await dispatchLayout("session_resume", .object(["id": .string(id)])) != nil
                ? nil : paletteFailure(since: mark)
        case .openInEditor(let path):
            let before = paneIds
            guard await dispatchLayout("editor_open", .object(["path": .string(path)])) != nil else {
                return paletteFailure(since: mark)
            }
            await refreshPanes()
            return await focusActedOn(since: before, named: focusedEditorPane(), mark: mark)
        case .pushStep, .drill:
            return nil
        }
    }

    /// The focused pane if it is an editor, else the first editor pane.
    func focusedEditorPane() -> String? {
        let panes = layoutSnapshot.panes
        if let focused = panes.first(where: { $0.id == layoutSnapshot.focusedId }), focused.kind == "editor" { return focused.id }
        return panes.first { $0.kind == "editor" }?.id
    }

    /// One catalog or source dispatch, on the path its control runs.
    private func paletteDispatch(_ name: String, _ params: JSONValue, mark: PaletteRunMark) async -> String? {
        let value = { (key: String) in optionalString(params, key) ?? "" }
        switch name {
        case "window.editorReveal":
            await revealActiveFileInTree(pane: value("pane"))
            return nil
        case "window.apiSend":
            apiSendRequestToken += 1
            apiSendRequests[value("pane")] = apiSendRequestToken
            return nil
        case "ctx_set_environment":
            return await setEnvironment(value("name")) ? nil : paletteFailure(since: mark)
        case "ctx_set_project":
            return await setProject(value("name")) ? nil : paletteFailure(since: mark)
        case "ctx_set_provider":
            return await performPaletteAction(.setProvider(value("name")), mark: mark)
        case "pane_close":
            // P6: what the pane's own close control (⌘W, *Close Pane*) runs.
            return await closePane(id: value("id")) ? nil : paletteFailure(since: mark)
        case "pane_open":
            // The Landing's split: `term_open` opens a terminal AND starts its shell; `pane_open`
            // alone would leave a dead pane (walk defect B2).
            let before = paneIds
            let opened = value("kind") == "terminal" ? await openTerminalPane() : await openPane(kind: value("kind"))
            return opened ? await focusActedOn(since: before, named: nil, mark: mark) : paletteFailure(since: mark)
        default:
            let before = paneIds
            // An action that opens a pane when it names none opens it into the conversation, as
            // `openPane` does: the first pane of a session mints the scope it lives in.
            if Self.paletteOpensAPane.contains(name), optionalString(params, "pane") == nil {
                await enterConversation()
            }
            guard await dispatchLayout(name, params) != nil else { return paletteFailure(since: mark) }
            await refreshPanes()
            // A changed file names no pane (3b-iii): the editor pane it went to is the one acted on,
            // by `editor_changes_select`'s own rule — the focused editor pane, else the first.
            let named = optionalString(params, "pane") ?? optionalString(params, "id")
                ?? (name == "editor_changes_select" ? focusedEditorPane() : nil)
            return await focusActedOn(since: before, named: named, mark: mark)
        }
    }

    /// The palette's actions that open a pane when they name none. `editor_changes_select` (3b-iii)
    /// opens an editor pane when there is none, as the Git pane it replaced was opened.
    private static let paletteOpensAPane: Set<String> = ["db_read_table", "api_open", "editor_changes_select"]

    /// Drops a Send request whose pane has closed.
    private func pruneApiSendRequests() {
        guard !apiSendRequests.isEmpty else { return }
        let open = paneIds
        apiSendRequests = apiSendRequests.filter { open.contains($0.key) }
    }

    private var paneIds: Set<String> { Set(layoutSnapshot.panes.map(\.id)) }

    /// The failure the run that began at `mark` left in `status`, whole; `nil` when it wrote
    /// none. A run cancelled from elsewhere says nothing, as in `dispatch`, and an older error
    /// still showing is not this run's.
    private func paletteFailure(since mark: PaletteRunMark) -> String? {
        statusWrites != mark.status && !status.isEmpty ? status : nil
    }

    /// Focus goes to the pane acted on (spec §7, rule 6): the one pane opened since `before`,
    /// else the open pane the params `named`. A param that names no open pane — a closed pane,
    /// a session id — moves nothing. **Nor does a run that outlived its palette**: the operator
    /// closed it and may be anywhere by now, so the keyboard stays where they are (rule 6).
    private func focusActedOn(since before: Set<String>, named: String?, mark: PaletteRunMark) async -> String? {
        guard paletteCloses == mark.closes else { return nil }
        let opened = layoutSnapshot.panes.map(\.id).filter { !before.contains($0) }
        let target = opened.count == 1 ? opened.first : named.flatMap { paneIds.contains($0) ? $0 : nil }
        guard let target, layoutSnapshot.focusedId != target else { return nil }
        return await focusPane(id: target) ? nil : paletteFailure(since: mark)
    }

    /// The environments, read as projects and providers are: through `paletteSource`, so an
    /// open palette never writes the window's `status`, not even when the read fails.
    ///
    /// **The failure is kept** (rule 8): a listing that failed answers its note, so *Switch
    /// environment…* stays in ⌘K and its step draws the error whole instead of the command
    /// vanishing with no word.
    private func paletteEnvironments() async -> (listings: [EnvironmentListing], note: String?) {
        let source = await paletteSource("ctx_list_environments")
        guard let structured = source.structured else { return ([], source.note) }
        return (Self.environmentListings(from: structured), nil)
    }

    /// The project's files as ⌘P lists them; the fast path ranks the same entries.
    func paletteFilesSource() -> FilesSource? {
        paletteClients.files.map { files in
            FilesSource(files: files, roots: { [weak self] in await self?.gitRootPaths ?? [] },
                        showIgnored: { [weak self] in await self?.editorSettings.app.showIgnored ?? true })
        }
    }

    /// ⌘P's sources, in group order.
    private func paletteOpenSources(tables: TablesSource?) -> [any PaletteSource] {
        // Read now, on the main actor: the live set as the palette opens.
        let running = liveConversationRows()
        var sources: [any PaletteSource] = [
            RunningConversationsSource(conversations: { running }),
            OpenPanesSource(panes: { [weak self] in await self?.palettePaneSummaries() ?? [] }),
            NewPaneSource(),
        ]
        if let tables { sources.append(tables) }
        if let http = paletteClients.http {
            let environment = environment
            sources.append(ApiEntriesSource(http: http, environment: { environment }))
        }
        let changed = ChangedFilesSource(status: { [weak self] in await self?.paletteGitStatus() ?? [] })
        let fileSource = paletteFilesSource()
        // An editor in focus puts the project's files first: sources keep their own order within a group.
        let editorFocused = layoutSnapshot.panes.first { $0.id == layoutSnapshot.focusedId }?.kind == "editor"
        if let fileSource, editorFocused { sources.append(fileSource) }
        sources.append(changed)
        if let fileSource, !editorFocused { sources.append(fileSource) }
        sources.append(ItemsSource.projects(
            organisation: { [weak self] in await self?.organization ?? "" },
            read: { [weak self] org in await self?.currentOrganisationProjects(org) ?? ([], nil) }))
        // Ended sessions only: a live conversation's chain is listed once, under Running.
        sources.append(ItemsSource.sessions(read: { [weak self] in
            guard let self else { return ([], nil) }
            let (items, note) = await self.sessionPaletteItems()
            return (PaletteItems.continueItems(items, excluding: await self.liveSessionIds), note)
        }))
        sources.append(ItemsSource.providers(read: { [weak self] in await self?.providerPaletteItems() ?? ([], nil) }))
        return sources
    }

    /// The projects of `organisation` if it is still this window's, else none: `wakil-ctx`
    /// lists the active organisation's, so a reader asked for another answers nothing rather
    /// than the wrong organisation's (Invariant 4).
    private func currentOrganisationProjects(_ organisation: String? = nil) async -> (items: [PaletteItem], note: String?) {
        guard organisation == nil || organisation == organization else { return ([], nil) }
        return await projectPaletteItems()
    }

    /// The tables source for this organisation, project and environment, over its cache, and
    /// whether that cache can already answer.
    private func paletteTables() -> (source: TablesSource, cache: TableCache, environment: String)? {
        guard let db = paletteClients.database else { return nil }
        let key = "\(organization)\u{0}\(project)"
        let cache = paletteTableCaches[key] ?? TableCache()
        paletteTableCaches[key] = cache
        let environment = environment
        return (TablesSource(db: db, environment: { environment }, cache: cache), cache, environment)
    }

    private func palettePaneSummaries() async -> [PaneSummary] {
        layoutSnapshot.panes.map { pane in
            PaneSummary(pane: pane, apiEntry: api(pane.id)?.entry)
        }
    }

    /// ⌘P's changed files: the window's status while an editor pane keeps it live, else a read made
    /// for the palette alone (as before, when no Git pane was open).
    private func paletteGitStatus() async -> [GitRootState] {
        if !gitRoots.isEmpty { return gitRoots }
        return await paletteGitStatusWithoutPane()
    }

    /// Every project root's status, read straight from `wakil-git` for the palette, with no pane
    /// to draw it in.
    private func paletteGitStatusWithoutPane() async -> [GitRootState] {
        guard let git = paletteClients.git else { return [] }
        let roots = gitRootPaths
        let states = await withTaskGroup(of: (Int, GitRootState).self) { group in
            for (i, root) in roots.enumerated() {
                group.addTask {
                    let result: Result<JSONValue, Error>
                    do {
                        result = .success(try await git.callTool(
                            name: "git_status", arguments: .object(["root": .string(root)]),
                            timeout: MCPClient.readReplyTimeout))
                    } catch {
                        result = .failure(error)
                    }
                    return (i, gitRootState(root: root, result: result))
                }
            }
            var byIndex: [Int: GitRootState] = [:]
            for await (i, state) in group { byIndex[i] = state }
            return byIndex
        }
        return roots.indices.compactMap { states[$0] }
    }

    /// A late source's whole list, for the generation it was asked under.
    private func paletteLate(
        _ rows: [PaletteEntry], generation: Int, onLate: @Sendable (PaletteRoot) -> Void
    ) {
        guard generation == paletteGeneration else { return }
        var rows = rows
        if let fresh = paletteFreshTables, fresh.generation == generation {
            rows = Self.replacingTables(in: rows, with: fresh.rows)
        }
        paletteLatest = (generation, rows)
        paletteDelivered(generation)
        onLate(PaletteRoot(generation: generation, rows: rows))
    }

    /// A background table refresh landed: the latest list with its tables replaced.
    private func paletteTablesRefreshed(
        _ fresh: [PaletteEntry], generation: Int, onLate: @Sendable (PaletteRoot) -> Void
    ) {
        guard generation == paletteGeneration, let latest = paletteLatest, latest.generation == generation
        else { return }
        paletteFreshTables = (generation, fresh)
        let rows = Self.replacingTables(in: latest.rows, with: fresh)
        paletteLatest = (generation, rows)
        paletteDelivered(generation)
        onLate(PaletteRoot(generation: generation, rows: rows))
    }

    /// `rows` with the tables source's rows swapped for `fresh`, in the place they held.
    nonisolated static func replacingTables(in rows: [PaletteEntry], with fresh: [PaletteEntry]) -> [PaletteEntry] {
        func fromTables(_ e: PaletteEntry) -> Bool {
            ["db:", "table:", "error:databases", "error:db:", "loading:tables"].contains { e.id.hasPrefix($0) }
        }
        let at = rows.firstIndex(where: fromTables)
            ?? rows.firstIndex { $0.group > .resources }
            ?? rows.count
        var kept = rows
        kept.removeAll(where: fromTables)
        let insertion = rows[..<at].filter { !fromTables($0) }.count
        kept.insert(contentsOf: fresh, at: insertion)
        return kept
    }

    /// Dispatches through the registry, marks the named pane busy while it
    /// runs, and refreshes the cached snapshot — persisting it if the
    /// arrangement actually moved.
    ///
    /// Every layout control in the window goes through here, and here goes
    /// through `dispatch` like everything else, so every *control* in this
    /// model reaches the registry through one place. (`paletteSource` is
    /// the one other caller of `ActionRegistry.dispatch` here: it reads
    /// two lists to fill ⌘P and must report a failure as a palette note
    /// rather than as the window's status, so it does its own error
    /// handling.)
    /// Nothing in the view layer touches `LayoutStore` directly — that is
    /// Invariant 2 for layout, and it is what makes the `--dispatch`
    /// scripts in the runbook equivalent to clicking.
    ///
    /// Answers the dispatch's result, or `nil` when it did not run — the reason in `status`.
    @discardableResult
    private func dispatchLayout(_ name: String, _ params: JSONValue) async -> JSONValue? {
        var paneId: String?
        if case .object(let object) = params, case .string(let id)? = object["id"] {
            paneId = id
            await layout.setBusy(true, id: id)
            // Published *before* the dispatch runs, not after it:
            // `Pane.busy` is what the rail draws while an action naming
            // this pane is in flight, and a snapshot re-read only at the
            // end would never once observe it true. A plain read: a busy
            // flag is not a change anything should be written for.
            await readLayoutSnapshot()
        }

        let result = await dispatch(name, params)

        if let paneId { await layout.setBusy(false, id: paneId) }
        // Only a real change is written, and `refreshLayout` is what
        // decides that now — for every writer at once rather than for this
        // one path (final review, Critical 1). The comparison it makes is
        // the one that used to be here, `withoutTransientState` and all:
        // two dispatches can overlap — a drag release landing while a
        // palette command is in flight — and the one that finishes first
        // would otherwise see the other's pane still marked busy, call
        // that a change, and write the file for an arrangement that did
        // not move.
        await refreshLayout()
        return result
    }

    /// Writes the arrangement the model just re-read (spec §4.3: "written
    /// on commit").
    ///
    /// Skipped before `refreshContext()` has answered, because a layout
    /// filed under an empty org is filed where no later session will look
    /// for it — worse than not filing one at all.
    ///
    /// The write happens off the main actor. It is small and atomic, but it
    /// is on the path of every drag release, and §7's frame budget does not
    /// survive filesystem calls taken inline. A failure lands in `status`
    /// like any other: it must not break the action that triggered it, the
    /// arrangement on screen is still correct, and only the next session
    /// would notice.
    ///
    /// **Writes are chained, not merely concurrent.** Each one waits for
    /// the previous one to finish before it starts. Two overlapping
    /// dispatches otherwise hand two writers the same path, and because
    /// each write is an atomic rename the *older* snapshot's rename can
    /// land last, leaving a superseded arrangement on disk with nothing to
    /// correct it until the next commit. Chaining on the main actor —
    /// `pendingSave` is read and replaced with no suspension between —
    /// makes the order of the writes the order the snapshots were read in,
    /// which is the order that ends with the freshest.
    private func persistLayout() async {
        // **The scope is read, never re-derived.** `activateLayout` is the
        // only place one is worked out (see `layoutScope`), so a write and
        // the read that preceded it cannot land under two different names.
        //
        // Both halves of the old guard survive, here and in the method
        // below. It is `nil` until the first `refreshContext()` has
        // answered and whenever there is no active project, which is what
        // `!project.isEmpty` used to catch; and the empty-organisation
        // case is checked where the write actually happens.
        guard let scope = layoutScope else { return }
        await persistLayout(layoutSnapshot, for: scope)
    }

    /// The write itself, under a scope the caller names.
    ///
    /// Split out for `activateLayout`'s flush of the arrangement it is
    /// leaving, which is the one write that happens while `layoutScope`
    /// has already moved on — everything else means "the canvas as it is
    /// now, under the name it is under now" and comes through the method
    /// above.
    private func persistLayout(_ snapshot: LayoutSnapshot, for scope: LayoutScope) async {
        // A layout filed under an empty org is filed where no later
        // session will look for it — worse than not filing one at all.
        guard let persistence, !scope.organization.isEmpty else { return }
        let previous = pendingSave
        let save = Task.detached(priority: .utility) { () -> String? in
            _ = await previous?.value
            do {
                try persistence.save(snapshot, for: scope)
                return nil
            } catch {
                return "layout save: \(error)"
            }
        }
        pendingSave = save
        if let note = await save.value { status = note }
    }

    /// ⌘P's project rows.
    ///
    /// **`ctx_list_projects` answers with an object, not an array.**
    /// `wakilcore.ProjectListing.Projects` is a `map[string]ProjectEntry`
    /// (`internal/wakilcore/registry.go`), so `structuredContent.projects`
    /// is a JSON object *keyed by project name*, and a `ProjectEntry`
    /// carries only `path` and an optional `provider` — there is no `name`
    /// field inside it, because the name is the key. Reading it as an
    /// array of records, which is what the first cut of this method did,
    /// yields an empty ⌘P against a real org with real projects and
    /// nothing anywhere to say why.
    ///
    /// Keys are sorted: a JSON object has no order of its own, and a
    /// palette whose rows moved between openings would be unusable.
    private func projectPaletteItems() async -> (items: [PaletteItem], note: String?) {
        let source = await paletteSource("ctx_list_projects")
        guard let structured = source.structured else { return ([], source.note) }
        guard case .object(let projects)? = structured["projects"] else {
            return ([], "ctx_list_projects: the result carried no \"projects\" object")
        }
        let items = projects.keys.sorted().map { name -> PaletteItem in
            var subtitle = ""
            if case .object(let entry)? = projects[name] {
                if case .string(let provider)? = entry["provider"], !provider.isEmpty {
                    subtitle = provider
                } else if case .string(let path)? = entry["path"] {
                    subtitle = path
                }
            }
            return PaletteItem(
                id: "project:\(name)", kind: .project, title: name,
                subtitle: subtitle, payload: name)
        }
        return (items, nil)
    }

    /// ⌘P's session rows. `structuredContent.sessions` really is an array
    /// here — `wakilcore.SessionList.Sessions` is a `[]SessionMeta` — and
    /// each element carries `id`, `provider`, and (Tasks 2, 4, 5) `title`,
    /// `firstPrompt`, and `parent`.
    ///
    /// The row-mapping itself — title precedence and chain-collapsing —
    /// lives in `sessionItems(from:)` below, pure and `internal`, so it can
    /// be pinned by a fixture test without a registry or a live
    /// `wakil-ctx` behind it. This method keeps only what needs the
    /// registry: dispatching `session_list` and reporting a row without an
    /// id, which `sessionItems(from:)` silently drops because it cannot be
    /// resumed. How many were dropped is reported rather than swallowed,
    /// for the same reason `SessionList.Skipped` exists on the Go side: an
    /// incomplete listing must say it is incomplete.
    private func sessionPaletteItems() async -> (items: [PaletteItem], note: String?) {
        let source = await paletteSource("session_list")
        guard let structured = source.structured else { return ([], source.note) }
        guard case .array(let rows)? = structured["sessions"] else {
            return ([], "session_list: the result carried no \"sessions\" array")
        }
        let items = Self.sessionItems(from: rows)
        let withoutId = rows.count { row in
            guard case .object(let fields) = row, case .string? = fields["id"] else { return true }
            return false
        }
        guard withoutId == 0 else {
            return (items, "session_list: \(withoutId) of \(rows.count) sessions had no id")
        }
        return (items, nil)
    }

    nonisolated internal static func sessionItems(from rows: [JSONValue]) -> [PaletteItem] {
        PaletteItems.sessionItems(from: rows)
    }

    nonisolated internal static func age(
        ofRFC3339 stamp: String, now: Date = Date()
    ) -> String? {
        PaletteItems.age(ofRFC3339: stamp, now: now)
    }

    /// How long ago `date` was, in Continue's vocabulary (`2m`, `1h 5m`, `yesterday`): a Running
    /// row's age since its conversation's last activity.
    public nonisolated static func age(since date: Date, now: Date = Date()) -> String {
        PaletteItems.age(since: date, now: now)
    }

    /// ⌘P's provider rows — Task 12, the fix for the sub-phase's own
    /// headline defect: `setProvider` had no palette route to it at all.
    ///
    /// **`ctx_list_providers` answers with `structuredContent.providers`
    /// as a JSON ARRAY**, unlike `ctx_list_projects`'s object keyed by
    /// name. `wakilcore.ProviderListing.Providers` is `[]ProviderSummary`
    /// — a provider's id genuinely IS its only name (unlike a project,
    /// where the registry key and the declared `project.json` name can
    /// disagree — see `providerReport`'s doc comment in `resolve.go`),
    /// so there is no second name for a map key to protect against
    /// disagreeing with, and `ProviderListing`'s own doc comment records
    /// that as the deliberate reason the two commands do not share a
    /// shape.
    ///
    /// The row-mapping lives in `providerItems(from:running:)` below,
    /// pure and `internal`, for the same reason `sessionItems(from:)` is:
    /// a fixture test can pin it without a registry or a live
    /// `wakil-ctx` behind it.
    private func providerPaletteItems() async -> (items: [PaletteItem], note: String?) {
        let source = await paletteSource("ctx_list_providers")
        guard let structured = source.structured else { return ([], source.note) }
        guard case .array(let rows)? = structured["providers"] else {
            return ([], "ctx_list_providers: the result carried no \"providers\" array")
        }
        await capacity.refresh()
        return (Self.providerItems(from: rows, running: providerId,
                                   capacity: capacity.readings, now: Date()), nil)
    }

    nonisolated internal static func providerItems(
        from rows: [JSONValue], running: String, capacity: [CapacityReading] = [], now: Date = Date()
    ) -> [PaletteItem] {
        PaletteItems.providerItems(from: rows, running: running, capacity: capacity, now: now)
    }

    /// Dispatches one list-returning action and hands back its
    /// `structuredContent`, or `nil` and a note saying what went wrong.
    ///
    /// A `nil` still means the palette opens — ⌘P is three sources and
    /// losing one must not lose the other two — but it no longer means
    /// silence. The palette draws the note as one error row (`ItemsSource`).
    private func paletteSource(_ action: String) async -> (structured: [String: JSONValue]?, note: String?) {
        do {
            let result = try await registry.dispatch(
                name: action, params: .object([:]), origin: .ui,
                caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            guard case .object(let object) = result,
                  case .object(let structured)? = object["structuredContent"]
            else {
                return (nil, "\(action): the result carried no structuredContent object")
            }
            return (structured, nil)
        } catch where isRoutineCancel(error) {
            // Silent, as in `dispatch`: a palette closed while it loads cancels this.
            return (nil, nil)
        } catch {
            return (nil, "\(action): \(error)")
        }
    }

    // MARK: - Dispatch

    /// The `status` text for a dispatch of `name` that threw `error`: the
    /// action name, followed by the error's own description — once.
    ///
    /// **A string check, not a `case is StandardActionError`.**
    /// `StandardActionError.description` (`StandardActions.swift`) already
    /// begins with the action for every one of its cases — `.serverError`
    /// returns `"\(action): \(message)"`, `.missingParam` returns
    /// `"\(action): missing required param …"`, and so on — so prepending
    /// `name` unconditionally, as both call sites below used to, drew the
    /// action name twice in text that is now drawn inside the failing pane
    /// itself, in red: the most-read error text in the app stuttering
    /// `"db_run_query: db_run_query: query failed: …"`. A type switch would
    /// go stale the moment some other `Error` learns to name its own
    /// action, and would silently start stuttering again with no test here
    /// to catch it; asking "does this sentence already say which action
    /// failed?" keeps working whoever throws.
    func statusDescribingFailure(_ name: String, _ error: Error) -> String {
        let described = "\(error)"
        return described.hasPrefix("\(name):") ? described : "\(name): \(described)"
    }

    /// How this window's controls call the registry — every one of them,
    /// and the only caller of `ActionRegistry.dispatch` here besides
    /// `paletteSource`. Returns `nil` on failure, having put the reason in
    /// `status`.
    ///
    /// The first dispatch always passes `confirmation: nil`, including for
    /// a `.mutate`. That is not an oversight: the operator has not typed
    /// anything yet, and pre-supplying the word the gate wants would make
    /// the window a caller that confirms on the human's behalf — exactly
    /// what Invariant 7 forbids the agent from doing. A refusal parks in
    /// `confirmations` and the plane asks; only `confirmPending` re-enters
    /// with `"confirm"`.
    ///
    /// `environment` is passed through as read from `wakil-ctx`, so the
    /// string the gate judges is the same string Invariant 8 puts on
    /// screen.
    @discardableResult
    private func dispatch(_ name: String, _ params: JSONValue) async -> JSONValue? {
        do {
            // The conversation actions name the screen's conversation as it is now, not as it is
            // when their request drains (Invariant 4).
            let pinned = Self.screenPinnedActions.contains(name) ? pinTurnScope().conversation : nil
            let result = try await registry.dispatch(
                name: name, params: params, origin: .ui,
                caller: DispatchCaller(place: place, session: nil, conversation: pinned), confirmation: nil)
            status = ""
            return result
        } catch ActionError.needsConfirmation {
            // `parkAndAwait` tells a refusal from a real cancel apart (see
            // `MutationDispatchOutcome`); this caller is the one that has
            // never needed the distinction, because none of `dispatch`'s
            // OTHER callers report an outcome to the operator the way a
            // cell edit does — they just don't redraw, either way. So it
            // collapses both back down to `nil` here, at the boundary,
            // rather than the distinction never being computed at all.
            switch await parkAndAwait(name, params) {
            case .ran(let result): return result
            case .refused, .cancelled: return nil
            }
        } catch where isRoutineCancel(error) {
            // **A cancelled caller is told nothing** (2c-iv W14, fix round 1). Since `MCPClient`
            // honours cancellation, a read in a SwiftUI `.task(id:)` ends with
            // `CancellationError` whenever its id changes — `ContextLine` and `Landing` on every
            // project switch, `OrgPlane` on every phase. The view that asked is gone; reporting
            // that as a failure would put a routine event on the status line.
            return nil
        } catch where apiSurfaceRefusalIsSilent(error) {
            // Cancel pressed as the reply landed (`apiSurfaceRefusalIsSilent`): the reply on
            // screen answers the press, so nothing goes on the status line.
            return nil
        } catch {
            status = statusDescribingFailure(name, error)
            return nil
        }
    }

    /// Whether `error` is the caller's own task being cancelled rather than a failure: a
    /// `CancellationError`, or any error thrown into a task already cancelled (a handler may
    /// wrap the cancel in an error of its own).
    nonisolated private func isRoutineCancel(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    /// What a `.mutate` dispatch's second half actually meant. Plain
    /// `dispatch(_:_:)` above answers every caller's question — "did
    /// something run?" — with a `JSONValue?`, and that is enough for every
    /// caller except `commitCellEdit`: a cell edit's `CellEditOutcome`
    /// distinguishes a refusal (the gate's own sentence, worth telling the
    /// operator) from a cancel (nothing to say, the operator or the clock
    /// decided), and `JSONValue?` cannot carry that distinction — `nil`
    /// means both. Fix Round 1 of the acceptance review, 2026-09-13, found
    /// `commitCellEdit` reporting the production block, a handler error,
    /// an expired confirmation and a busy broker all as `.cancelled`,
    /// which drops the gate's sentence on the floor for every one of them
    /// except the actual cancel.
    ///
    /// **Only `confirmations.request` answering `.cancelled` is a real
    /// cancel.** Every other way `parkAndAwait` can fail to run something
    /// — a blank statement, an approved confirmation whose re-dispatch
    /// still throws, an expired wait, a broker already occupied — carries
    /// a sentence describing what happened, so all of those are
    /// `.refused`, not `.cancelled`.
    private enum MutationDispatchOutcome {
        case ran(JSONValue)
        case refused(String)
        case cancelled
    }

    /// The `.mutate` counterpart to `dispatch(_:_:)`, for the one caller
    /// that needs `MutationDispatchOutcome`'s finer distinction rather
    /// than `dispatch`'s `JSONValue?`. Shares `parkAndAwait` with
    /// `dispatch` itself rather than re-implementing the confirmation
    /// broker's three-way outcome a second time.
    private func dispatchMutation(_ name: String, _ params: JSONValue) async -> MutationDispatchOutcome {
        do {
            let result = try await registry.dispatch(
                name: name, params: params, origin: .ui,
                caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            status = ""
            return .ran(result)
        } catch ActionError.needsConfirmation {
            return await parkAndAwait(name, params)
        } catch {
            status = statusDescribingFailure(name, error)
            return .refused(status)
        }
    }

    /// Parks a refused mutation, shows it, and re-dispatches it if the
    /// operator confirms — the same three steps `MCPServer` takes for the
    /// agent, through the same broker.
    ///
    /// **Refuses to park a blank statement.** ⌘K once (`commandItems`, gone with the
    /// curated catalog) listed every registered action with no filter on kind, so
    /// `db_run_mutation` is selectable there exactly like any read — and
    /// running it that way dispatches with `.object([:])`, no `statement`
    /// at all. Parking that anyway would show the operator a red plane
    /// asking them to confirm nothing, and would occupy the screen's place's
    /// slot in the broker for up to 120s while every unrelated agent proposal there got
    /// `.busy` in the meantime. `MCPServer.parkForConfirmation`'s doc
    /// comment already states the invariant this guards — "a blank
    /// confirmation reads as a bug to whoever is asked to approve it" —
    /// and refuses the same shape on the agent's side, where an
    /// `arguments`-less `tools/call` produces it. This is the window's
    /// half of that one rule.
    ///
    /// Returns `MutationDispatchOutcome`, not `JSONValue?`, so that
    /// `dispatchMutation` can hand `commitCellEdit` the refusal/cancel
    /// distinction and `dispatch(_:_:)` can still collapse it for
    /// everyone else — one confirmation flow, read two ways at its edges
    /// rather than implemented twice.
    private func parkAndAwait(_ name: String, _ params: JSONValue) async -> MutationDispatchOutcome {
        guard let statement = stringParam(params, "statement"), !statement.isEmpty else {
            status = "\(name): no statement to confirm — nothing ran"
            return .refused(status)
        }
        let proposal = PendingMutation(
            action: name, params: params,
            database: stringParam(params, "database"),
            statement: statement,
            affectsEveryRow: mutationAffectsEveryRow(statement),
            origin: .ui,
            // The screen's, where the operator asked: the plane shows it while they stay.
            place: place)

        switch await confirmations.request(proposal) {
        case .approved:
            // **Run where it was asked, or not at all** (final review minor 4). `place` is the
            // property, read here rather than captured before the park: a ⌘K switch while the
            // plane was up — into production, or into another organisation — means the
            // screen is no longer where the operator approved this, so nothing runs and the
            // status says why. Otherwise it runs in the proposal's own place, which the gate
            // judges as it stands now. `MCPServer.parkForConfirmation` re-reads its provider at
            // this same point, for this same reason.
            //
            // Bound to a local rather than read once per use: the `"error"`
            // and `"uncertain"` lines this path can write are read as a
            // pair, and a pair that disagreed about the environment would
            // be worse than one that named none. The binding is outside the
            // `do` so the `catch` can see it.
            guard place == proposal.place else {
                status = "\(name): approved after the screen left the place it was asked in — nothing ran"
                return .refused(status)
            }
            let judged = proposal.place
            do {
                let result = try await registry.dispatch(
                    name: name, params: params, origin: .ui,
                    caller: DispatchCaller(place: judged, session: nil), confirmation: "confirm")
                status = ""
                return .ran(result)
            } catch {
                await recordUncertainMutation(
                    error, registry: registry, action: name, params: params, origin: .ui,
                    caller: DispatchCaller(place: judged, session: nil))
                status = statusDescribingFailure(name, error)
                return .refused(status)
            }
        case .cancelled:
            status = "\(name): cancelled — nothing ran"
            return .cancelled
        case .expired:
            status = "\(name): the confirmation expired — nothing ran"
            return .refused(status)
        case .busy:
            status = "\(name): another confirmation is already waiting"
            return .refused(status)
        }
    }

    private func stringParam(_ params: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = params, case .string(let value)? = object[key] else {
            return nil
        }
        return value
    }

    // MARK: The agent

    /// Resolves `id`'s credentials through `lookup` and turns a refusal
    /// into `status` text prefixed by `statusPrefix` — the shape `send`,
    /// `resume` and (Task 8) `setProvider` all refuse in, so a lookup
    /// failure reads the same way no matter which of the three triggered
    /// it. `nil` means `status` is already set and the caller should
    /// return without doing anything else.
    ///
    /// **In `place`'s own organisation** (Invariant 4, background agents 3 of 4): an agent the
    /// screen has left — its own resume, or a first turn whose start the operator switched away
    /// from — resolves its account where it lives, never under the org on screen, whose
    /// `lookup` would read another org's secret of the same name, or refuse.
    private func resolveCredentials(
        forProvider id: String, in place: Place, statusPrefix: String
    ) async -> ProviderCredentials? {
        let lookup = place.organization == organization ? lookup : lookupFactory(place.organization)
        do {
            return try await lookup.credentials(forProvider: id)
        } catch let ProviderCredentialsLookupError.refused(reason) {
            // The lookup's own message names the fix (`decodeProviderCredentials`'s
            // doc comment: "the exact `wakil secrets set` to run") — passed
            // through verbatim rather than wrapped, so rewording it here
            // does not lose that.
            status = "\(statusPrefix): \(reason)"
            return nil
        } catch {
            status = "\(statusPrefix): \(error)"
            return nil
        }
    }

    /// Resolves this window's CURRENT `providerId` into a harness: fresh
    /// credentials from `lookup`, then `harnessFactory`. Shared by `send`
    /// (the window's first turn) and `resume` (a forked session, which
    /// `resume`'s own guard has already confirmed belongs to this same
    /// provider) — Task 9's `setProvider` does not call this, because a
    /// switch resolves credentials for a NEW id, not this window's
    /// current one.
    ///
    /// An empty `providerId` is refused here rather than handed to
    /// `lookup`: it is the ordinary state of a window that has never had
    /// a provider chosen for it (a fresh install, or an org that has
    /// never run a switch), not a broken credential, and deserves its own
    /// legible message rather than whatever a lookup call for the empty
    /// string happens to fail with.
    /// Tells the pool which places are still in use after a harness changed: every place with a
    /// live agent (`agentPlaces`). Chained, not awaited, so the switch that changed it never
    /// waits on a child process stopping, and two retains in a row land in the order they were
    /// made.
    private func retainAgentPlace() {
        guard let placeClients else { return }
        let places = agentPlaces
        let previous = placeRetain
        let placeContexts = placeContexts
        placeRetain = Task {
            await previous?.value
            await placeContexts?.retain(places)
            await placeClients.retain(places)
        }
    }

    ///
    /// **The place, the provider and the session id are parameters**, not read here: `send`
    /// captures the first two when the turn is typed, and the operator can have moved the screen
    /// by the time this runs. The session id names the socket, which is started first.
    private func startHarness(
        in startPlace: Place, provider: String, sessionId: String, conversation: String
    ) async -> StartedSession? {
        guard !provider.isEmpty else {
            status = "no agent session: no provider is active for this window yet"
            return nil
        }
        guard let credentials = await resolveCredentials(
            forProvider: provider, in: startPlace, statusPrefix: "no agent session")
        else {
            return nil
        }
        guard let started = await makeSession(
            in: startPlace, ProviderSelection(id: provider, credentials: credentials), sessionId: sessionId,
            conversation: conversation)
        else {
            status = "no agent session: no agent available for provider \(provider)"
            return nil
        }
        return started
    }

    /// A session `makeSession` built and has not yet installed: its harness, its socket, and
    /// why it has none if it would not start.
    private struct StartedSession {
        let harness: AgentHarness
        let socket: (any AgentSocket)?
        let socketFailure: String?
    }

    /// A socket a place opened when it was shown, before any session there took it: the session
    /// id it answers for, the place it is pinned to, and its start, which whoever takes or stops
    /// it awaits.
    private struct ShownSocket {
        let sessionId: String
        let place: Place
        let opening: Task<OpenedSocket, Never>
        /// This entry's own identity: a failed open forgets its own entry only, never the one a
        /// rename put under the same conversation and session id meanwhile (`carryAgents`).
        var token = UUID()
    }

    /// One socket's start: the socket, or why it would not start.
    private struct OpenedSocket {
        let socket: (any AgentSocket)?
        let failure: String?
    }

    /// Starts the socket at `agentSocketPath(agentSessionId:)`, answering for `place`,
    /// `sessionId` and `conversation` — every call on it is that session's, in that conversation,
    /// from its first frame to its last, wherever the screen is. A throw is kept as the sentence
    /// the session's status shows.
    private nonisolated static func openSocket(
        _ factory: AgentSocketFactory, in place: Place, sessionId: String, conversation: String
    ) async -> OpenedSocket {
        let path = agentSocketPath(agentSessionId: sessionId)
        let caller = DispatchCaller(place: place, session: sessionId, conversation: conversation)
        do {
            return OpenedSocket(socket: try await factory(path, { caller }), failure: nil)
        } catch {
            return OpenedSocket(
                socket: nil,
                failure: "MCP socket \(path): \(error) — the agent cannot reach Wakil's own tools this session")
        }
    }

    /// Opens the socket of the place on screen, the moment it is shown — at launch and on every
    /// switch, before any turn — so the place's agent channel is listening before its agent is
    /// (the e2e harness drives the window through it). It reserves the session id the place's
    /// first session then starts with, and that session takes this socket (`makeSession`).
    ///
    /// **Pinned to the place it opened for**, never one that follows the screen: a switch away
    /// leaves it answering for its own place, and the place switched to opens its own. Once per
    /// place, not per visit: a place with a socket waiting, or a live session, keeps what it has.
    /// Not awaited — a switch waits on nothing (Rule 1); whoever takes or stops it awaits its start.
    /// One that would not start refuses nothing (Rule 7): the session that takes it tries again,
    /// and runs without Wakil's own tools if that fails too, its status saying why.
    ///
    /// **Not mid organisation switch** (`switching`): the window passes through the outgoing
    /// organisation with its project cleared, which is no place the operator was shown.
    /// `setOrganization` opens the place it lands on once the switch is over.
    ///
    /// **Keyed by the conversation it answers for**: the place's screen conversation when it has
    /// one, else the id the place reserves for its next conversation (`reservedConversations`),
    /// which `agent(for:)` gives the conversation it creates there.
    private func openShownSocket() {
        let place = self.place
        guard !socketsClosed, !switching else { return }
        let screen = currentAgent
        if let screen, screen.harness != nil || screen.socket != nil { return }
        // Once per conversation (conversations 2 of 3): a place whose conversation went to the
        // background without a session keeps that one's socket, and its Landing opens its own.
        let conversation = screen?.id ?? reservedConversations[place] ?? UUID().uuidString
        guard shownSockets[conversation] == nil else { return }
        let sessionId: String
        if let screen {
            sessionId = screen.assignedSessionId ?? screen.id
        } else {
            reservedConversations[place] = conversation
            sessionId = conversation
        }
        let factory = agentSocketFactory
        // One that would not start is forgotten, so the place's next showing tries again — this
        // entry only: a rename that replaced it meanwhile keeps its reopened one (plan 1's race).
        let token = UUID()
        let opening = Task { [weak self] () -> OpenedSocket in
            let opened = await Self.openSocket(
                factory, in: place, sessionId: sessionId, conversation: conversation)
            if opened.socket == nil, let self, self.shownSockets[conversation]?.token == token {
                self.shownSockets[conversation] = nil
            }
            return opened
        }
        shownSockets[conversation] = ShownSocket(sessionId: sessionId, place: place, opening: opening, token: token)
    }

    /// A new session's socket, then its harness, told that socket's path (background agents 3
    /// of 4, Task 4). The socket answers for `place` and `sessionId` — the id the harness is
    /// about to be started with — so every call on it is that session's, from its first frame
    /// to its last, wherever the screen is. **The socket the place opened when it was shown,
    /// when it was opened for this id** (`openShownSocket`): a place's first session reaches
    /// Wakil on the socket that was already listening. Any other id — a resume's fork, a
    /// provider switch's fresh session — opens its own. Nil when the factory has no harness for
    /// `selection`, with the socket stopped again, or left to the place if it was the shown one.
    ///
    /// **A socket that will not start does not refuse the session** (Rule 7, and what the one
    /// window-wide socket did before): the agent runs without Wakil's own tools, and
    /// `socketFailure` is the sentence its status shows, the reason whole.
    private func makeSession(
        in place: Place, _ selection: ProviderSelection, sessionId: String, conversation: String
    ) async -> StartedSession? {
        let path = agentSocketPath(agentSessionId: sessionId)
        var opened: OpenedSocket?
        // Taken before the await, so nothing else can take or stop it meanwhile.
        let shown = shownSockets[conversation].flatMap { $0.sessionId == sessionId ? $0 : nil }
        if let shown {
            shownSockets[conversation] = nil
            opened = await shown.opening.value
        }
        // None shown for this id, or it would not start: once more, now.
        if opened?.socket == nil {
            opened = await Self.openSocket(
                agentSocketFactory, in: place, sessionId: sessionId, conversation: conversation)
        }
        let socket = opened?.socket
        guard let harness = harnessFactory(place, selection, path) else {
            if let shown, let opened, socket != nil, !socketsClosed, shownSockets[conversation] == nil {
                shownSockets[conversation] = ShownSocket(
                    sessionId: shown.sessionId, place: shown.place, opening: Task { opened })
            } else {
                await socket?.stop()
            }
            return nil
        }
        return StartedSession(harness: harness, socket: socket, socketFailure: opened?.failure)
    }

    /// Installs `started` as `agent`'s live session: its harness and its socket. False, with
    /// `started` stopped, when `agent` is no longer live (final review I1): a Close it, or a
    /// removal (`closeConversations`), landed while the session started, so nothing would ever
    /// reach or stop a session put on the detached conversation — not Close, and not `shutdown`,
    /// which stops only the live ones. Every caller returns without its session on false.
    private func install(_ started: StartedSession, in agent: PlaceAgent, resumed: Bool = false) async -> Bool {
        guard conversations[agent.id] === agent else {
            await started.harness.stop()
            await started.socket?.stop()
            return false
        }
        agent.harness = started.harness
        // A new session's first turn records what it launched with. A resumed one keeps the prompt
        // its parent was first launched with (the 3a-iii-b probe), which may predate the current
        // text — so its first turn carries the text as an update.
        agent.launchedInstructions = resumed ? resumedInstructionsUnknown : nil
        agent.socket = started.socket
        agent.socketFailure = started.socketFailure
        return true
    }

    /// Stops an agent's harness, then the socket its shim reached Wakil on: the `claude` child,
    /// and the shim with it, are gone before the socket closes. The approval its conversation is
    /// waiting on, if any, is cancelled with it (final review I2): it belongs to the
    /// session being stopped — `resume` and `setProvider` replace it, `shutdown` ends it — and,
    /// never expiring (R1), it would otherwise answer the next session's every gated call `.busy`.
    private func stopSession(of agent: PlaceAgent) async {
        await agent.harness?.stop()
        await agent.socket?.stop()
        agent.socket = nil
        agent.socketFailure = nil
        // A socket the place opened for a session of this conversation that never started: the
        // one replacing it has its own, and two for one conversation would leave its channel
        // ambiguous.
        if let shown = shownSockets.removeValue(forKey: agent.id) {
            await shown.opening.value.socket?.stop()
        }
        // Every agent proposal names its conversation (`MCPServer.parkForConfirmation` parks
        // under its socket caller's), so this one is the session's and no sibling's.
        await confirmations.cancelAgentProposal(inConversation: agent.id)
    }

    /// Sends one turn to the agent, starting the session on the first call.
    ///
    /// Failures land in `status` rather than propagating: this is called
    /// from a SwiftUI action, which cannot throw. A `nil` harness from
    /// `startHarness()` is the ordinary case when this window has no
    /// active provider yet, or `lookup` refuses the one it has — see that
    /// method's own doc comment — and says so instead of appearing to
    /// send.
    /// True only when a turn started: the harness accepted the text. A
    /// missing harness or a failed send returns false, and the composer
    /// gives the operator's draft back.
    @discardableResult
    public func send(_ text: String, via source: TurnSource = .typed, scope: TurnScope? = nil) async -> Bool {
        // The place the operator typed in: its agent takes the turn, wherever the screen is by
        // the time a suspension below returns. Its root and provider are captured with it: a
        // first turn's harness starts after `enterConversation` suspends, and starting it with
        // whatever the screen shows by then would run A's agent in B's root.
        let typedIn = scope ?? pinTurnScope()
        guard let agent = conversation(pinned: typedIn.conversation, landingIn: typedIn.place) else {
            // Rule 8, whole; Rule 2: the composer gives the words back to the screen they were
            // typed on.
            switch whyGone(pinned: typedIn.conversation) {
            case .landingShowsAnother:
                status = "not sent: the Landing this was typed on shows another conversation now — "
                    + "the message is back in that Landing's composer"
            case .noLongerLive:
                status = "not sent: the conversation this was typed in is no longer live — "
                    + "the message went to no other conversation"
            }
            return false
        }
        let (startRoot, startProvider) = (typedIn.rootPath, typedIn.providerId)
        // The canvas comes with the conversation, for the same reason `openPane` does: a
        // first turn mints the conversation, and the arrangement belongs to the conversation
        // rather than to the window that happened to be open when it started. Nothing visible
        // moves: a conversation minted this moment over the canvas on screen ADOPTS that
        // canvas, pane contents and drafts with it (re-walk #4), rather than re-reading the
        // project seed, which holds no drafts.
        // **The window says it is starting BEFORE the first thing that can
        // suspend, and `enterConversation()` is that thing. #284.**
        //
        // 72ad932 put this line further down, immediately before
        // `startHarness()`, on the reasoning that the credential lookup and
        // the spawn are the slow part of a turn. The evidence says otherwise.
        // Nine recorded failures captured a tree with the prompt typed, the
        // composer focused, the Send button present — and no status element
        // at all, twenty seconds after the click. Every path below this point
        // writes `status`, so an empty one places the stall ABOVE them, and
        // the only await above them is `enterConversation()`: a scope swap
        // that persists the outgoing arrangement to disk and hops to the
        // `LayoutStore` actor. A turn that stalls there is a turn the window
        // says nothing about, which is precisely how #284 was reported —
        // *clicking send sometimes spawned no agent process and produced no
        // status text*.
        //
        // **Guarded on the first turn**, so this stays the sentence it was:
        // a second turn already has a harness, takes none of this path's
        // slow steps, and would only flicker.
        //
        // **Nothing clears it here, deliberately**, as before: every path out
        // writes `status` itself — each `nil` from `startHarness()` carries
        // its reason, the `catch` carries the error, and a turn that gets
        // away ends at `status = ""`.
        if agent.harness == nil, agent.sessionId == nil {
            status = "starting the agent…"
        }
        await enterConversation(agent)
        // Rule 5: a turn typed while this place's session is still being started by an earlier
        // one waits for that start, then goes to the same session — the way a turn typed while
        // one is in flight goes to the running harness. Without this the two would each start a
        // harness and a socket under the one assigned id, and the first pair would leak.
        while agent.startWaiters != nil {
            await withCheckedContinuation { agent.startWaiters?.append($0) }
        }
        // Conversations 3 of 3: a session whose process went away is resumed first, as a fork of
        // it, and the turn goes to the fork. A turn typed meanwhile waits for it (Rule 5), as for
        // a first start. A resume refused says why in `status`, and nothing is sent.
        if agent.sessionEnded, let ended = agent.sessionId {
            agent.startWaiters = []
            await resume(sessionId: ended, conversation: agent.id)
            agent.releaseStartWaiters()
            guard !agent.sessionEnded else { return false }
        }
        let startsSession = agent.sessionId == nil
        if startsSession { agent.startWaiters = [] }
        defer { if startsSession { agent.releaseStartWaiters() } }
        if agent.harness == nil, agent.sessionId == nil {
            // **The window says it is starting before it starts. #284.**
            //
            // This is the slow part of a turn and, until now, the silent
            // one: `resolveCredentials` reads the keychain and
            // `harness.start` spawns a child process, and neither is
            // instant on a loaded machine. `turnInFlight` — the Core's
            // glow, and the only other thing that says a turn is happening
            // — is not raised until after both, so an operator who clicked
            // Send saw a window indistinguishable from one that had
            // ignored the click: no glow, no text, nothing.
            //
            // That is the shape #284 was reported as: *"clicking send
            // sometimes spawned no agent process and produced no status
            // text"*. The missing process is a timing question that may
            // yet have an answer; the missing TEXT was this, and it is
            // what made the timing question unreadable — every failing
            // path in `send` sets `status`, so an empty one said the turn
            // had not reached any of them, and nothing said which side of
            // the click that was.
            //
            // **Nothing clears this, deliberately.** Every path out of
            // here writes `status` itself: each `nil` from
            // `startHarness()` carries its own reason, the `catch` below
            // carries the error, and a turn that gets away ends at
            // `status = ""`. A clear here would be a fourth answer to a
            // question three places already answer.
            // The id is fixed here, before anything starts: it names the socket, which starts
            // before the harness. `markSessionStarted` has assigned it already; the mint is the
            // fallback described where the session starts below.
            let id = agent.assignedSessionId ?? UUID().uuidString
            agent.assignedSessionId = id
            if let started = await startHarness(
                in: agent.place, provider: startProvider, sessionId: id, conversation: agent.id
            ) {
                // Closed while it started: the session is stopped, and the turn goes nowhere.
                guard await install(started, in: agent) else {
                    status = ""
                    return false
                }
                agent.providerId = startProvider
            }
            retainAgentPlace()
        }
        guard let harness = agent.harness else {
            // Unreachable today — `harness` and `sessionId` are only ever
            // set together, below — but `startHarness()` already set
            // `status` on every path that can produce `nil` here, and
            // repeating a status assignment costs nothing. Kept as a
            // guard against a future change that clears `harness` (say,
            // on an unexpected `stop()`) without also clearing
            // `sessionId`: without this, `send` would silently become a
            // no-op instead of saying why.
            if status.isEmpty {
                status = "no agent session: nothing to send to"
            }
            return false
        }
        do {
            if agent.sessionId == nil {
                // `markSessionStarted()` above assigned this before anything
                // else in `send` ran, so the `??` is a belt-and-braces
                // fallback rather than a live path — and it mints rather than
                // refusing, because a turn that failed over a missing id
                // would be a worse outcome than a conversation whose first
                // pane was filed under a different one.
                let id = agent.assignedSessionId ?? UUID().uuidString
                try await harness.start(sessionId: id, resumingFrom: nil, workingDirectory: startRoot)
                agent.sessionId = id
                agent.assignedSessionId = id
                // Only if the fallback above actually fired: a conversation
                // started fresh is its own root, and one resumed already has
                // the root it inherited, which must not be overwritten here.
                if agent.lineageRoot == nil { agent.lineageRoot = id }
                startEventPump(harness, for: agent)
            }
            // Set *before* the `await`s, not after: `textWithIdentifierNote`
            // suspends first (reading the vocabulary), then `harness.send`
            // suspends on the main actor while the child's stdin write
            // completes, and the event pump appends on that same actor.
            // Finding 5 (final review): a turn fast enough to land its
            // `.result` inside a suspension used to have this line run
            // *after* `append` had already cleared the flag, re-setting it
            // to `true` with no event left to ever clear it again — the
            // Core then "thinks" forever. Setting it first means the
            // ordering can only go the other way: if `.result` lands during
            // either suspension, `append` clears what is already there,
            // and nothing re-sets it once `send` returns.
            agent.turnInFlight = true
            refreshChipProduction(of: agent)
            // 2d-ii: the operator's own turn is a row, so what was actually
            // sent — a misheard sentence included — stays on screen.
            agent.noteSend(text)
            agent.appendRow(label: "you", detail: text)
            var outgoing = await textWithIdentifierNote(text, for: agent)
            // 3a-iii-b: instructions edited since this session started ride ahead of the words.
            if let update = instructionsUpdate(for: agent) {
                outgoing = update + "\n\n" + outgoing
                agent.appendRow(label: "instructions", detail: "Instructions updated — the agent has the new ones from this turn.")
            }
            try await harness.send(outgoing)
            // After the send succeeded: a turn that never went leaves no
            // `voice_turn` line, and no suspension sits before the
            // org-switch generation guard in `textWithIdentifierNote`.
            if source == .voice {
                try? await registry.journalVoiceTurn(
                    caller: DispatchCaller(place: agent.place, session: nil, conversation: agent.id))
            }
            // A session running without its socket says so after each turn, not only once.
            status = agent.socketFailure ?? ""
            return true
        } catch {
            // A failed send did not start a turn — including a failed
            // `harness.start` or `harness.send` after the line above already
            // set the flag — so nothing may be left in flight.
            agent.turnInFlight = false
            status = "agent: \(error)"
            return false
        }
    }

    /// Drains `events()` into `thoughts` for as long as *this* session
    /// lives.
    ///
    /// Cancel-and-replace rather than start-once: 2b-v swaps the harness
    /// on a resume, and a pump still draining the old instance's finished
    /// stream would leave the new one's events unread. Each instance still
    /// has exactly one consumer, which is what `events()`'s
    /// `preconditionFailure` requires.
    ///
    /// **The pump belongs to its agent** (background agents 3 of 4): rows, the mirror and the
    /// turn's end land in that place's entry wherever the screen is.
    private func startEventPump(_ harness: AgentHarness, for agent: PlaceAgent) {
        agent.eventPump?.cancel()
        // Captured now, not read fresh inside the loop: this is what makes
        // the check below compare THIS pump's generation against whatever
        // is current at the moment each event arrives, rather than always
        // trivially agreeing with itself. See `resume`'s doc comment.
        let generation = agent.eventPumpGeneration
        let pumpProvider = agent.providerId
        agent.sessionEnded = false
        // The `Task` inherits this method's `@MainActor` isolation, so the
        // loop appends on the main actor with no hop — it is the `for
        // await` that suspends, not the append, so a long-running session
        // does not hold the main actor between events. `append(_:)` itself
        // stays synchronous (Task 11): the mirror, capacity and the
        // `.result` case's probe below are the loop's `async` steps.
        agent.eventPump = Task { [weak self] in
            for await event in harness.events() {
                // `Task.cancel()` above does not stop an `AsyncStream` from
                // delivering values already sitting in its buffer — this
                // check is what actually does, for a pump a resume has
                // superseded. See `resume`'s doc comment for the full case.
                guard let self, agent.eventPumpGeneration == generation else { return }
                self.append(event, to: agent)
                // Task 15: the same event, projected a second time into
                // every open terminal pane's mirror. `append(_:)` stays
                // synchronous (Task 11).
                await self.pumpMirror(event, for: agent)
                await self.recordCapacity(event, provider: pumpProvider, for: agent)
                if case .result = event { self.startCapacityProbe() }
            }
            // The stream ended under a pump nothing replaced or cancelled: the session's process
            // went away, and no turn runs on in it. Off screen, its chip says it failed (background
            // agents 4 of 4) — and, once seen, not that it is still working.
            guard !Task.isCancelled, let self, agent.eventPumpGeneration == generation else { return }
            agent.turnInFlight = false
            // Conversations 3 of 3: the conversation stays live, its failure said whole in its
            // thread (Rule 8), and its next turn resumes it (`send`).
            agent.sessionEnded = true
            agent.appendRow(
                label: "agent",
                detail: "The agent's process ended, so this conversation stopped. Your next message resumes it.",
                isError: true)
            self.markUnseen(failed: true, for: agent)
        }
    }

    /// Marks a turn's end, or a session's failure, for a chip when `agent`'s place is off screen;
    /// on screen the operator sees it happen. Activating the place clears both.
    private func markUnseen(failed: Bool, for agent: PlaceAgent) {
        guard agent !== currentAgent else { return }
        if failed { agent.unseenFailure = true } else { agent.unseenResult = true }
        refreshChipProduction(of: agent)
    }

    /// Reads whether `agent`'s environment is production from its own project's flags, for its
    /// chip, so `chips` stays synchronous. Unread, or when the read fails, the name rule
    /// `PlaceAgent` starts with stands; once read, the declaration wins. Fire-and-forget, so a read
    /// lands only if it is still the newest for an agent still holding the place: an older read
    /// landing last, or one for an agent since replaced, is dropped.
    private func refreshChipProduction(of agent: PlaceAgent) {
        guard let placeContexts, !agent.place.organization.isEmpty else { return }
        let place = agent.place
        agent.productionReads += 1
        let read = agent.productionReads
        Task { [weak self] in
            guard let flags = try? await placeContexts.context(for: place).environmentProduction else { return }
            guard let self, self.conversations[agent.id] === agent, agent.productionReads == read else { return }
            agent.showProduction(flags)
        }
    }

    /// Leaves the current agent session and forks a past one.
    ///
    /// Every resume is a fork — see `buildLaunch` for why continuing in
    /// place is not offered — so this mints a fresh id,
    /// records the lineage, and leaves the parent's transcript untouched.
    ///
    /// Refusals land in `status` rather than throwing: this is reached
    /// from a palette selection and from a parked agent request, neither
    /// of which has anywhere to throw to.
    ///
    /// **Start-then-swap, not stop-then-start.** Finding 2 of the
    /// acceptance review (2026-09-10): an earlier version of this method —
    /// the brief's own pseudocode — stopped the existing harness and
    /// overwrote `thoughts` *before* attempting `next.start`. When `start`
    /// threw, the operator lost the working session entirely: its process
    /// was already stopped and its thread already replaced, and nothing
    /// under `catch` could recreate either — the window ended up looking
    /// like one that had never started a session at all. Starting `next`
    /// first, and touching the existing session only once `next` has
    /// actually come up, means a failure here leaves the operator exactly
    /// where they were: same harness, same pump, same thoughts.
    ///
    /// Two `claude` processes are briefly alive at once during the `start`
    /// call below — the existing one, still the session on screen, and
    /// `next`, not yet adopted. That is safe: each writes to its own
    /// session id and therefore its own transcript file, so the
    /// two-writers-one-file race probe §9 measured (two live processes
    /// racing to write ONE transcript) cannot occur here — `next` writes
    /// to `child`, a freshly minted id nothing else can be operating on.
    /// Do not "fix" this back to stop-then-start.
    ///
    /// `place`: whose session is replaced — an agent's own `session_resume` names its place
    /// (`ResumeRequest.place`), so the fork happens there wherever the screen is. Nil is the
    /// place on screen. `conversation`: the one whose session is replaced — an agent's own, or
    /// the operator's screen's as it was when they asked (`ResumeRequest.conversation`), its
    /// Landing's creating it; refused in `status` when that Landing shows another conversation
    /// now, or the conversation is no longer live. Nil is the place's agent.
    public func resume(sessionId parent: String, in place: Place? = nil, conversation: String? = nil) async {
        let agent: PlaceAgent
        if let conversation {
            // Pinned when it was asked for (`screenPinnedActions`): that conversation, or its
            // Landing's, or none.
            guard let pinned = self.conversation(pinned: conversation, landingIn: place ?? self.place) else {
                switch whyGone(pinned: conversation) {
                case .landingShowsAnother:
                    status = "resume \(parent): the Landing it was asked on shows another conversation now — "
                        + "nothing was resumed"
                case .noLongerLive:
                    status = "resume \(parent): the conversation it was asked in is no longer live — "
                        + "nothing was resumed"
                }
                return
            }
            agent = pinned
        } else {
            agent = self.agent(for: place ?? self.place)
        }
        markSessionStarted(in: agent)
        // Checked first, before `readThread` even dispatches a read: the
        // live session's own transcript is filed under the project root as
        // soon as it starts (`ClaudeCodeCLIHarnessTests`'
        // `startRunsTheChildInTheGivenWorkingDirectory` is what pins that
        // `workingDirectory` reaches the spawned child), so it is exactly
        // as visible to ⌘P's session listing as any past one and gets
        // offered right alongside them. Picking it would fork from a
        // transcript this window's OWN process is still appending to:
        // `next.start` would run a second `claude` reading that file
        // mid-write. The two-writers race probe §9 `resume`'s own doc
        // comment cites, for why two forks can safely run concurrently,
        // does not cover this case — that argument rests on the fork
        // writing to a FRESH id nothing else touches, not on the PARENT
        // being read while a live process still owns it.
        // A session whose process went away is no longer written to: forking it is its revival.
        guard parent != agent.sessionId || agent.sessionEnded else {
            status = "resume \(parent): that is the session already running in this window"
            return
        }
        // A running agent forks under its own account; a place with none takes the window's —
        // only while it is the conversation on screen: one the screen has left keeps the account
        // it was given in its own organisation (Invariant 4).
        let providerId = agent.harness == nil && agent === currentAgent ? self.providerId : agent.providerId
        // **As the agent** (Invariant 4): its session store is its own place's, which only the
        // client pinned to that place answers for once the screen is elsewhere. A caller is
        // pinned only with a session id (`pinnedPlace(of:)`), and an agent with no session yet
        // has none (`PlaceAgent.caller`), so this one carries the id `markSessionStarted` minted
        // above: the reads and the fork's `session_record_parent` go to this place's client, not
        // the window's.
        let caller = DispatchCaller(
            place: agent.place, session: agent.sessionId ?? agent.assignedSessionId, conversation: agent.id)
        let thread: SessionThreadSnapshot
        do {
            thread = try await readThread(parent, as: caller)
        } catch {
            status = "resume \(parent): \(error)"
            return
        }
        guard thread.provider == providerId else {
            // `providerId` empty is not "no provider" as a display
            // string — it is this window never having had a provider
            // chosen for it yet (`WindowSession.start` notes exactly that
            // at window launch, if `get_context`'s `ActiveProvider` came
            // back empty). Naming it explicitly here, rather than
            // interpolating an empty string, keeps this refusal legible
            // on its own rather than trailing off after "running ".
            let runningDescription = providerId.isEmpty ? Self.unsetProviderLabel : providerId
            status = "resume \(parent): that session belongs to provider "
                + "\(thread.provider), and this window's provider is \(runningDescription)"
            return
        }
        guard let credentials = await resolveCredentials(
            forProvider: providerId, in: agent.place, statusPrefix: "resume \(parent)")
        else {
            return
        }
        // Minted before the harness: it names the fork's own socket, started first.
        let child = UUID().uuidString
        // From here to `install`, a session start is in flight (`runsOrStarts`).
        agent.sessionStartsInFlight += 1
        defer { agent.sessionStartsInFlight -= 1 }
        guard let started = await makeSession(
            in: agent.place, ProviderSelection(id: providerId, credentials: credentials), sessionId: child,
            conversation: agent.id)
        else {
            status = "resume \(parent): no agent session available"
            return
        }
        let next = started.harness

        // Read BEFORE the swap and before `session_record_parent` below
        // adds this fork to the map, so it is the parent's own lineage
        // being asked about and not one this call has already altered.
        let inheritedRoot = await lineageRootOfSession(parent, as: caller)

        do {
            try await next.start(
                sessionId: child, resumingFrom: parent, workingDirectory: thread.cwd)
        } catch {
            // Nothing above this line touched the existing session — see
            // this method's own doc comment.
            await started.socket?.stop()
            status = "resume \(parent): \(error)"
            return
        }

        // Only now, with `next` confirmed running, is anything about the
        // session being left touched.
        //
        // The generation is bumped FIRST, before `stop()` is even called —
        // Finding 1 of the same review. `ClaudeCodeCLIHarness.stop()`
        // waits for stdout to finish being turned into buffered events,
        // not for this window to have drained them, and
        // `startEventPump`'s `for await` loop has no cancellation check of
        // its own: `Task.cancel()` does not stop an `AsyncStream` from
        // delivering values already sitting in its buffer — the
        // `tool_result` for the very `session_resume` call that triggered
        // this swap, say, or a trailing `.result`. Bumping the counter
        // here, before that suspension, means the OLD pump's every
        // subsequent iteration — however many buffered events it still has
        // queued, and however long after `cancel()` it actually gets
        // scheduled — compares its captured generation against a value
        // that has already moved on, and drops the event instead of
        // appending it after the seam.
        agent.eventPumpGeneration += 1
        await stopSession(of: agent)

        agent.thoughts = rebuiltThread(thread, parent: parent, for: agent)
        agent.turnInFlight = false

        // Closed while the fork started: the fork is stopped, and nothing else is done.
        guard await install(started, in: agent, resumed: true) else { return }
        agent.providerId = providerId
        retainAgentPlace()
        agent.sessionId = child
        agent.sessionIds.insert(parent)
        // A resume is a fork: the child is a new conversation id, so the
        // window's assigned identity moves with it.
        agent.assignedSessionId = child
        // **The conversation, unlike the id, does NOT move.** That is the
        // whole point of the root: six resumes are six session ids and one
        // workspace. `inheritedRoot` was read before the swap, from the
        // parent's own lineage, so a chain of any length resolves to the
        // same arrangement.
        agent.lineageRoot = inheritedRoot
        startEventPump(next, for: agent)
        status = agent.socketFailure ?? ""
        // Best effort, and after the swap: a lineage record that failed to
        // write costs ⌘P a grouping, while a resume that refused because
        // of it would cost the operator the session.
        _ = try? await registry.dispatch(
            name: "session_record_parent",
            params: .object(["child": .string(child), "parent": .string(parent)]),
            origin: .ui, caller: caller, confirmation: nil)
        // Last, and only once the swap has actually happened: the canvas
        // follows the conversation. A resume that returned early above
        // never reaches here, so a refused resume leaves the arrangement
        // exactly as it was.
        await followConversation(of: agent)
    }

    /// The lineage root `resume` files the forked conversation under: the
    /// root of the session being forked FROM, because a fork continues its
    /// parent's conversation rather than starting one.
    ///
    /// **Asked of `wakilcore`, never walked here.** `SessionMeta.lineageRoot`
    /// is resolved against the whole organisation's parent map, while
    /// anything this window could walk is limited to the rows in a listing
    /// filtered to the active project's roots. A chain whose ancestor ran
    /// in another project would resolve differently depending on what
    /// happened to be listed — harmless for ⌘P's grouping, and fatal for a
    /// storage key, because an arrangement filed under one root and looked
    /// up under another is an arrangement silently lost.
    ///
    /// **It costs a round trip, and #142 expected it not to.** That
    /// decision — "surfaced as a new field on `SessionMeta`, so
    /// `list_sessions` carries it and both ⌘P and the Landing get it with
    /// no extra round trip" — holds for the two surfaces it names, which
    /// read the field off rows they already have. It does not reach here:
    /// `resume` is also entered from a parked agent request, which has no
    /// listing in hand, and a second path that inferred the root from
    /// whatever ⌘P happened to be showing is exactly the filtered-listing
    /// mistake above. One call, one answer, both entrances. It sits beside
    /// the transcript read `resume` already makes, which is the heavier of
    /// the two.
    ///
    /// **`nil` rather than a guess when the answer does not come back.**
    /// Falling back to the parent's own id would be the plausible-looking
    /// wrong answer: mid-chain it names a different file from the one the
    /// conversation's panes are actually in, so the operator would get an
    /// empty canvas and a second workspace filed beside the real one.
    /// `nil` means the project's seed — the same thing a brand-new
    /// conversation gets, which is a state the operator already
    /// understands.
    private func lineageRootOfSession(_ id: String, as caller: DispatchCaller) async -> String? {
        guard let result = try? await registry.dispatch(
            name: "session_get", params: .object(["id": .string(id)]),
            origin: .ui, caller: caller, confirmation: nil)
        else { return nil }
        guard case .object(let object) = result,
            case .object(let structured)? = object["structuredContent"],
            case .string(let root)? = structured["lineageRoot"],
            !root.isEmpty
        else { return nil }
        return root
    }

    /// TEST-ONLY: the session id `autoResumeAfterSwitch()` last decided to
    /// resume, or `nil` if it found no candidate and fell back to a fresh
    /// session instead. Set at selection time, not at `resume(sessionId:)`'s
    /// own success — this exists so a test can pin the SELECTION (newest
    /// session for the active provider whose `cwd` matches) independently
    /// of whatever a fake `harnessFactory`/registry in that test does or
    /// does not wire up underneath `resume` itself.
    private(set) var resumedParentForTesting: String?

    /// Resumes the organisation's most recent session for the account now
    /// running in this window, or starts fresh and says so. Spec §7.
    ///
    /// **This is the q5 amendment.** The charter's rule is fresh-by-default,
    /// with resume as an explicit operator action — but that rule was
    /// decided about LAUNCHING THE APP, and returning to an org you left ten
    /// minutes ago is a different event: the operator did not ask to start
    /// over, they asked to come back. Decision 12's drift concern (a long
    /// session accreting unrelated context across many org switches) is
    /// answered rather than waived: 2b-v's `resume(sessionId:)` is a FORK
    /// under a fresh Wakil-minted session id, with lineage recorded via
    /// `session_record_parent` — so a chain of switches is a chain of short
    /// forked sessions, not one long one silently reused.
    ///
    /// **It mints a session; it spends nothing.** `resume(sessionId:)`
    /// starts a new `claude` process continuing the chosen transcript — no
    /// turn is sent and no tokens are consumed until the operator actually
    /// types. Calling this method is not the same thing as "switching orgs
    /// silently started an agent running up a bill".
    ///
    /// **The RAW `session_list` rows, not `sessionPaletteItems()`, and the
    /// reason is the fields rather than the collapse.** `PaletteItem`
    /// (⌘P's row type) carries only `id`/`kind`/`title`/`subtitle`/
    /// `payload` — no `provider`, no `cwd` — so there is nothing on it to
    /// filter by, and both filters below are load-bearing.
    ///
    /// **`sessionItems(from:)`'s collapse is not the objection**, which is
    /// what this comment used to say before refuting itself one clause
    /// later. It reduces a resume chain to its newest member, which is
    /// right for ⌘P (one row per conversation) and is *also* exactly what
    /// this method wants, since the newest member of a chain is the one a
    /// return visit should continue. The collapse and this method agree;
    /// the missing fields are why the raw rows are read.
    ///
    /// `session_list` itself guarantees newest-first, so the first row
    /// that matches is the newest one — no sorting needed here.
    ///
    /// **Why the provider filter is not optional.** A session's transcript
    /// lives under its OWN provider's config dir, and another account's
    /// `claude` binary cannot read it — `resume(sessionId:)` above already
    /// refuses a session belonging to a different provider than the one
    /// this window is running (see its `thread.provider == providerId`
    /// guard). Picking the newest session *for this org's active provider*,
    /// rather than the newest session overall, is what keeps this method
    /// from handing `resume` a session it is only going to refuse — with a
    /// confusing message, right after the operator switched orgs.
    ///
    /// **Empty `providerId` returns early.** A fresh org, or one that has
    /// never had an account chosen for it, has no provider to filter
    /// sessions by and nothing to resume under. `noActiveProviderNote`
    /// already names the fix ("pick one in ⌘P…"); this method does not
    /// duplicate that message into `status`.
    ///
    /// **Falls back to a fresh session, with a note, on either failure
    /// mode** — no candidate found, or `resume(sessionId:)` itself failing
    /// (wrong provider somehow, a dead transcript, no agent available for
    /// the credential). A switch must never leave the operator looking at
    /// a dead window with no explanation. "Fresh" here means simply not
    /// resuming: whatever session this window already has (typically none,
    /// just after `invalidateForOrgChange()`) is left alone, and `status`
    /// says why nothing was resumed.
    func autoResumeAfterSwitch() async {
        resumedParentForTesting = nil
        guard !providerId.isEmpty else { return }

        let source = await paletteSource("session_list")
        guard let structured = source.structured,
              case .array(let rows)? = structured["sessions"] else {
            status = "no previous session in \(organization) — starting a fresh session"
            return
        }

        let candidate = rows.first { row in
            guard case .object(let fields) = row,
                  case .string(let provider)? = fields["provider"],
                  case .string(let cwd)? = fields["cwd"] else { return false }
            return provider == providerId && cwd == rootPath
        }
        guard case .object(let fields)? = candidate,
              case .string(let id)? = fields["id"] else {
            status = "no previous session in \(organization) — starting a fresh session"
            return
        }

        resumedParentForTesting = id
        let sessionIdBeforeResume = sessionId
        await resume(sessionId: id)
        if sessionId == sessionIdBeforeResume {
            // `resume(sessionId:)` already put its own reason in `status`
            // (a wrong provider, an unreadable transcript, no agent
            // available) — this overwrites it with the fallback note
            // rather than appending, so `status` names the thing the
            // operator actually ends up looking at: a fresh session, not
            // the resume attempt that did not pan out.
            status = "could not resume \(id) — starting a fresh session"
        }
    }

    /// Switches the account this window's session runs under.
    ///
    /// Refusals land in `status` rather than throwing, for the same reason
    /// `resume(sessionId:)`'s do: this is reached from a palette selection,
    /// which has nowhere to throw to.
    ///
    /// WHY A TURN IN FLIGHT AND A PARKED PROPOSAL BOTH REFUSE RATHER THAN
    /// QUEUE. A queued provider switch would need a deferred-state machine
    /// nothing in this window has, and it would defer a decision the operator can simply
    /// re-make in a few seconds. A parked `.mutate` proposal in this place is the sharper
    /// case: it belongs to the session about to be replaced, and
    /// expiring it on the operator's behalf reaches that agent as a refusal
    /// it cannot interpret.
    public func setProvider(_ id: String) async {
        // The place on screen when the switch was asked for, with its root and the provider it
        // leaves, for `send`'s reason: the lookup below suspends, and the operator can move the
        // screen meanwhile. Its session is the one replaced; other places keep theirs.
        let (startPlace, startRoot, previous) = (place, rootPath, providerId)
        guard id != providerId else {
            status = "set provider \(id): that provider is already running in this window"
            return
        }
        guard !turnInFlight else {
            status = "set provider \(id): a turn is in flight — wait for it to finish"
            return
        }
        // Only this place's own waiting proposal refuses it — the operator's, or the on-screen
        // conversation's, whose session is the one replaced. Another place's or another
        // conversation's waits for its own agent, which keeps its provider.
        let startConversation = currentAgent?.id
        let placeSlot = await confirmations.current(in: ProposalSlot(place: startPlace, conversation: nil))
        let ownSlot = await confirmations.current(in: ProposalSlot(place: startPlace, conversation: startConversation))
        guard placeSlot == nil, ownSlot == nil else {
            status = "set provider \(id): a mutation is waiting for confirmation — "
                + "confirm or cancel it first"
            return
        }
        // In the starting place's organisation, as `send` and `resume` resolve (final review
        // minor 5): the guard above suspended, and an org switch landing there has made the
        // window's `lookup` another organisation's.
        guard let credentials = await resolveCredentials(
            forProvider: id, in: startPlace, statusPrefix: "set provider \(id)")
        else { return }
        // The conversation the slot checks above were made for, not whatever the place shows
        // after those awaits — as `send` resolves its own.
        let agent = startConversation.flatMap(conversation(id:)) ?? agent(for: startPlace)
        // Minted before the harness: it names the new session's own socket, started first.
        let fresh = UUID().uuidString
        // From here to `install`, a session start is in flight (`runsOrStarts`).
        agent.sessionStartsInFlight += 1
        defer { agent.sessionStartsInFlight -= 1 }
        guard let started = await makeSession(
            in: agent.place, ProviderSelection(id: id, credentials: credentials), sessionId: fresh,
            conversation: agent.id)
        else {
            status = "set provider \(id): no agent session available"
            return
        }
        let next = started.harness

        do {
            // START-THEN-SWAP. Nothing about the running session is touched
            // until `next.start` has returned. `resume(sessionId:)`'s doc
            // comment records what stop-then-start cost when it was tried:
            // a `start` that threw left the operator with no session at all,
            // its process already stopped and its thread already replaced.
            // Do not "fix" this back to stop-then-start.
            try await next.start(
                sessionId: fresh, resumingFrom: nil, workingDirectory: startRoot)
        } catch {
            await started.socket?.stop()
            status = "set provider \(id): \(error)"
            return
        }

        // The generation is bumped BEFORE `stop()`, not after.
        // `ClaudeCodeCLIHarness.stop()` waits for stdout to become buffered
        // events, not for this window to have drained them, and
        // `Task.cancel()` does not stop an `AsyncStream` from delivering
        // values already in its buffer. Bumping here means the old pump
        // compares against a value that has already moved on and drops
        // those events instead of appending them after the seam.
        agent.eventPumpGeneration += 1
        await stopSession(of: agent)

        // A FRESH SESSION, NOT A FORK. A resume forks from the parent's
        // transcript; a provider switch cannot, because transcripts live
        // under the provider's own config dir (`sessions.go`'s
        // `providerSessionsRoot`) and the new account's `claude` cannot
        // read a file under the old account's directory. That is the same
        // fact `resume(sessionId:)` enforces when it refuses a session
        // belonging to another provider. So `resumingFrom` is nil above,
        // and the thread is cleared rather than rebuilt.
        agent.thoughts = []
        // Just the two names, no "account changed:" prefix. With the row's
        // own label reading `SESSION` beside it, the prefix said "account"
        // a second time in a row that is four words long — and the arrow
        // already says "changed". Both accounts still appear, which is what
        // the check-2 judgement ("does the seam claim continuity?") needs
        // and what `ProviderSwitchTests` asserts.
        appendSeam("\(previous.isEmpty ? Self.unsetProviderLabel : previous) → \(id)", in: agent)
        agent.turnInFlight = false

        // Closed while the new session started: it is stopped, and nothing else is done.
        guard await install(started, in: agent) else { return }
        agent.providerId = id
        retainAgentPlace()
        agent.sessionId = fresh
        agent.assignedSessionId = fresh
        // A provider switch starts a new conversation, not a fork of the
        // one being left, so it is its own root.
        //
        // Review I3 of the re-walk fixes: a switch out of NO conversation mints one over the
        // canvas on screen, exactly as a first turn does, and adopts that canvas the same way
        // (re-walk #4) — re-reading the seed would rebuild every api pane from an empty draft.
        let previousRoot = agent.lineageRoot
        agent.lineageRoot = fresh
        // The window's provider, and the remembered default below, are the screen's place's:
        // written only while that is still the place switched (Invariant 4). The lookup and the
        // start suspended, and an org switch landing there moved the screen — and the window's
        // `wakil-ctx` — to another organisation, whose `active.json` this is not.
        let stillOnScreen = place == startPlace
        if stillOnScreen { providerId = id }
        startEventPump(next, for: agent)
        status = agent.socketFailure ?? ""

        // Best effort, and after the swap: exactly the ordering
        // `resume(sessionId:)` uses for `session_record_parent` below, and
        // for the identical reason. `ctx_set_provider` only persists the
        // operator's choice into `active.json` (Task 7's fourth axis) so it
        // survives past this window's lifetime — the live swap above has
        // already happened by the time this runs, so a failed write here
        // costs a future launch its remembered default, never the session
        // the operator is looking at right now.
        if stillOnScreen {
            _ = try? await registry.dispatch(
                name: "ctx_set_provider",
                params: .object(["name": .string(id)]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        }
        // The new account's capacity, probed: a switch is one of the three
        // moments that asks for it (launch and a turn's end are the others).
        // Started after the canvas below, unawaited: it never holds the switch (Rule 4).
        // The probe is operator-only here: `session_set_provider` is in `operatorOnlyActions`.
        // The canvas follows the conversation, for the reason `resume` ends
        // the same way. Without this the window would be in a NEW
        // conversation while `layoutScope` still named the old one, and
        // `persistLayout` writes under `layoutScope` — so the new
        // conversation's panes would be written over the previous one's
        // file, which is the exact loss #142 exists to stop.
        // **The settings pane survives a switch made from it** (from the 2e
        // walk). A switch mints a fresh lineage, so the layout swaps, and the
        // settings pane is never saved in a layout. It is CARRIED into the
        // incoming arrangement before that is published (same id, same frame,
        // and `WakilWindow.settingsSelection` holds its node), so the only
        // change on screen is USE becoming RUNNING. An earlier version
        // reopened it, and the operator saw it close, redraw at the cascade
        // position and jump back. An organisation switch leaves it in the
        // canvas it was open in, with the rest of that place.
        let settingsPane = layoutSnapshot.panes.first { $0.kind == Pane.settingsKind }
        await followConversation(of: agent, carrying: settingsPane, adoptingCanvas: previousRoot == nil)
        startCapacityProbe()
        // The active provider is the quick tasks' fallback, so they follow it (Ruling R4).
        if stillOnScreen { await rebuildQuickTasks() }
    }

    /// Switches the window to `org`: the org-bound resets (`invalidateForOrgChange`), then the
    /// window's own clients (`orgSwitcher`), then the context read (`refreshContext`). **It
    /// never stops, holds or discards anything** (background agents 3 of 4): every place the
    /// operator leaves — its agent, turn, waiting approval, canvas, rows, shells and buffers —
    /// stays as it was, so nothing here waits on a turn or a confirmation, and nothing asks.
    ///
    /// **The re-entrancy guard is the credential boundary** (fix round 3, Invariant 4). Two
    /// operator switches in quick succession would otherwise interleave at each other's
    /// suspension points (`orgSwitcher`, `refreshContext`) and leave `organization` naming one
    /// org while `lookup`, `providerId` and the window's clients belong to the other. Refusing
    /// the second call before it touches anything makes that pairing impossible
    /// (`twoConcurrentSetOrganizationCallsProduceExactlyOneCoherentSwitch`).
    public func setOrganization(_ org: String) async {
        guard !switching else {
            status = "switch org \(org): a switch is already in progress"
            return
        }
        guard org != organization else {
            status = "switch org \(org): that organisation is already open in this window"
            return
        }

        // Cleared once both guards have passed: a stale sentence naming the outgoing org must
        // not linger through a successful switch. `status` is a message surface, not org state
        // (`InvalidationContractTests`), so it is cleared here rather than in the resets.
        status = ""

        switching = true
        defer { switching = false }

        // The operator's reads and api sends in flight in the org being left went out on the
        // window's clients, which `orgSwitcher` is about to re-point: stopped first, so none
        // reaches the incoming org's process (Invariant 4). An agent's run on its own place's
        // client: untouched.
        await panes.cancelOperatorDBReads(inOrganization: organization)
        await panes.cancelOperatorApiSends(inOrganization: organization)
        await invalidateForOrgChange()

        let diagnostics = await orgSwitcher(org)
        guard diagnostics.isEmpty else {
            // The window does NOT claim the new org. Every action handler
            // now throws `MCPClientError.notRunning` — NOT
            // `StandardActionError.missingClient`, which this comment
            // used to claim (spec §3.1 carried the same false claim and
            // was corrected in place by Task 15; this is the last copy of
            // it). A failed restart leaves the client object in place and
            // merely STOPPED, so each handler's `guard let client else {
            // throw .missingClient }` still finds one and it is
            // `MCPClient.call`'s own `guard let process,
            // process.isRunning` that refuses. That is the honest and in
            // fact STRONGER signal: the child is dead, so nothing can
            // have half-executed. Retryable from the plane either way.
            status = "switch org \(org): \(diagnostics.joined(separator: "; "))"
            // `invalidateForOrgChange()` above has already reset everything org-bound —
            // `providerId`, `lookup`, `rootPath`, `project`, `environment` — but
            // `organization` still named the OUTGOING org until this line. Left there, the
            // window would claim an org whose context it no longer holds, AND the same-org
            // guard above would refuse a retry of that very org. An org-less window is a real,
            // designed state (a launch with no org lands there too), and clearing it makes both
            // the outgoing and the intended org reachable again. Every place's own state — its
            // agent, canvas and shells — is untouched, so a retry of the outgoing org finds it
            // as it was left.
            //
            // **No `lookup` rebuild on this path, and none is owed.**
            // `invalidateForOrgChange()` already reset it to
            // `lookupFactory("")`, so this assignment leaves the two
            // agreeing: an org-less window holding an org-less lookup,
            // which refuses every credential rather than resolving one
            // under a boundary the window no longer claims.
            organization = ""
            await activateLayout()
            switching = false
            openShownSocket()
            // The reservation that just minted renames the Landing told about mid-switch.
            tellScreenChange()
            // No organisation is open: the old one's quick tasks go, and none are built.
            await rebuildQuickTasks()
            return
        }

        // Authoritative in a way get_context is not: this is the string
        // Wakil itself put into the child environment (spec §6).
        organization = org
        // Rebuilt from that same authoritative string, here and not only
        // in `refreshContext()` below (final fix pass, Critical 1).
        // `invalidateForOrgChange()` above reset `lookup` to the org-less
        // placeholder, and a `get_context` that fails — a freshly created
        // org with no active project answers "no active project", the
        // shape `refreshContextFailureClearsRatherThanKeepsAnotherOrgsValues`
        // pins — takes the `catch` and rebuilds nothing. Doing it here
        // means the window's credential lookup names the org the window
        // now claims no matter how that refresh goes, which is the only
        // way `organization` and `lookup` cannot disagree (Invariant 4).
        lookup = lookupFactory(org)

        await refreshContext(probe: true)
        // The place landed on is shown, and the switch is over: its socket (`openShownSocket`).
        switching = false
        openShownSocket()
        // The reservation that just minted renames the Landing told about mid-switch.
        tellScreenChange()
        // **No auto-resume and no seam.** Returning to an org lands where that place was left —
        // its own agent and thread, or the Landing where no work has begun (whose Continue lists
        // what `autoResumeAfterSwitch` would have picked; ruled 2026-09-20). A seam row naming
        // the orgs would be written into a thread that never changed: each place's thread is its
        // own, and the context line already says where the operator is.
        await rebuildQuickTasks()
    }

    /// One chip per conversation not on screen that has something to show — in another place,
    /// or backgrounded in this one — ordered by organisation, project and environment, then by
    /// creation within a place (background agents 4 of 4; conversations 2 of 3). Each names its
    /// conversation (`title`) and its rank among its place's live ones (`ordinal`, ruling 2).
    /// Empty when no agent works elsewhere, so the window's resting state is unchanged.
    public var chips: [AgentChip] {
        let waiting = waitingConversations
        let shown = currentAgent
        var ordinals: [Place: Int] = [:]
        return liveConversations()
            .compactMap { agent -> AgentChip? in
                ordinals[agent.place, default: 0] += 1
                let waits = waiting.contains(agent.id)
                guard agent !== shown, let state = AgentChip.state(
                    waiting: waits, failed: agent.unseenFailure,
                    working: agent.turnInFlight, done: agent.unseenResult)
                else { return nil }
                return AgentChip(
                    place: agent.place, state: state, productionEnvironment: agent.productionEnvironment,
                    conversation: agent.id, title: agent.title, ordinal: ordinals[agent.place, default: 1])
            }
            .sorted {
                ($0.place.organization, $0.place.project, $0.place.environment, $0.ordinal)
                    < ($1.place.organization, $1.place.project, $1.place.environment, $1.ordinal)
            }
    }

    /// The conversations an agent's own proposal waits on. A conversation waits only on its own
    /// proposal; the operator's, parked in the same place, is not the agent asking for anything
    /// (final review, minor 1), nor is another conversation's.
    private var waitingConversations: Set<String> {
        Set(parkedSlots.filter { $0.value.origin == .agent }.keys.compactMap(\.conversation))
    }

    /// Every live conversation — or, given a place, that place's — newest `lastActivity` first,
    /// with its state: what the Landing's Running column and ⌘P's Running group list. Unlike a
    /// chip, an idle, seen conversation and the one on screen are listed too (`.idle`).
    public func liveConversationRows(in place: Place? = nil) -> [LiveConversation] {
        let waiting = waitingConversations
        let shown = currentAgent
        return liveConversations(in: place)
            .sorted { $0.lastActivity > $1.lastActivity }
            .map { agent in
                LiveConversation(
                    id: agent.id, session: agent.sessionId, place: agent.place, title: agent.title,
                    state: .of(
                        waiting: waiting.contains(agent.id), failed: agent.unseenFailure,
                        working: agent.turnInFlight, done: agent.unseenResult),
                    onScreen: agent === shown, lastActivity: agent.lastActivity,
                    isProduction: agent.productionEnvironment)
            }
    }

    /// Every session a live conversation holds, its own and the parent it forked from: what
    /// Continue and ⌘P's Sessions leave out, so a conversation is in one list only.
    private var liveSessionIds: Set<String> {
        conversations.values.reduce(into: Set<String>()) { $0.formUnion($1.sessionIds) }
    }

    // MARK: - Conversations 2 of 3: new and switch

    /// Whether the place on screen shows a conversation rather than its Landing.
    public var conversationOnScreen: Bool { currentAgent != nil }

    /// Puts `conversation` — nil, the one on screen — into the background, untouched: its
    /// harness, session, thread, canvas and any turn in flight carry on, and its chip says what
    /// it does. Its place shows its Landing, over the canvas of the id the place reserves for its
    /// next conversation, which `activateLayout` reads off disk — the project seed, as at launch
    /// (ruling 1). Nothing is asked (Rule 1). Does nothing when the conversation is not the one
    /// its place shows, or the place shows none.
    public func newConversation(_ conversation: String? = nil) async {
        let target = conversation.map { self.conversation(id: $0) } ?? currentAgent
        guard let target, screenConversations[target.place] == target.id else { return }
        await showLanding(in: target.place)
    }

    /// The Landing path (`newConversation`, and a close that leaves its place none live): `place`
    /// shows its Landing, over the canvas of the id it reserves for its next conversation.
    private func showLanding(in place: Place) async {
        screenConversations[place] = nil
        let reserved = reservedConversations[place] ?? UUID().uuidString
        reservedConversations[place] = reserved
        // The baseline is the canvas the Landing draws over — the seed as loaded for the reserved
        // conversation — never the one left: a seed pane closed there comes back with the seed,
        // and is not work begun. Empty, and loading (the #264 hook waits), until it is in.
        landingBaselines[place] = []
        landingsLoading.insert(place)
        defer { landingsLoading.remove(place) }
        if place == self.place {
            // After New Conversation the Landing's composer takes the keyboard, whatever its canvas holds.
            composerFocusForced = true
            defer { composerFocusForced = false }
            await activateLayout()
        } else {
            await loadOffScreen(LayoutScope(
                organization: place.organization, project: place.project, environment: place.environment,
                lineageRoot: reserved))
        }
        // Whatever came first meanwhile — work begun there, a switch back — wins.
        guard landingBaselines[place] != nil, screenConversations[place] == nil else { return }
        let scope = LayoutScope(
            organization: place.organization, project: place.project, environment: place.environment,
            lineageRoot: reserved)
        let shown = place == self.place
            ? layoutSnapshot.panes
            : await ScopeRouting.$home.withValue(scope) { await layout.snapshot() }.panes
        if landingBaselines[place] != nil { landingBaselines[place] = Set(shown.map(\.id)) }
    }

    /// Brings back the live conversation `idOrTitle` names — its id, or its title when that names
    /// one live conversation in `place` (nil, the screen's; ruling 3) — exactly as it was left:
    /// the same session, thread and canvas, no fork and no fresh process, a turn in flight
    /// untouched. Goes to its place first (`goTo`) when it is elsewhere. A title naming none, or
    /// more than one, is refused in `status` (Rule 7: an ambiguity forces it).
    public func switchToConversation(_ idOrTitle: String, in place: Place? = nil) async {
        let target: PlaceAgent
        if let byId = conversation(id: idOrTitle) {
            target = byId
        } else {
            let named = liveConversations(in: place ?? self.place).filter { $0.title == idOrTitle }
            guard let only = named.first else {
                status = "switch to \(idOrTitle): no live conversation is called that"
                return
            }
            guard named.count == 1 else {
                status = "switch to \(idOrTitle): two conversations here are called that — "
                    + named.map(\.id).joined(separator: ", ")
                return
            }
            target = only
        }
        let previous = screenConversations[target.place]
        // Named before `goTo`, so the place is landed on showing it, and only it is seen; put
        // back if `goTo` stops short and nothing has replaced it meanwhile.
        screenConversations[target.place] = target.id
        if target.place != self.place {
            await goTo(target.place)
            guard self.place == target.place else {
                if screenConversations[target.place] == target.id { screenConversations[target.place] = previous }
                return
            }
        }
        // A conversation is on screen in its place: the place's Landing, and its baseline, are over.
        landingBaselines[target.place] = nil
        await activateLayout()
        markSeen(target)
    }

    // MARK: - Conversations 3 of 3: close

    /// The Close question on show, if any: asked when the conversation a close names has its
    /// turn running, its session starting or a write waiting (Rule 1: closing destroys work in
    /// flight). Answered by `answerCloseQuestion`.
    public private(set) var closeQuestion: CloseConversationQuestion?
    /// The conversations `endConversation` is ending now: a second close of one is ignored
    /// (Rule 5), as is a second close while one is asked about.
    @ObservationIgnored private var closing: Set<String> = []

    /// Ends `conversation` — nil, the one on screen — as Close Conversation does: its agent stops,
    /// its panes close as on quit, and it moves to Continue; its place then shows its next live
    /// conversation, or its Landing. Asks first (`closeQuestion`) only when its turn is running,
    /// its session is starting (`PlaceAgent.startsSession`, the start Invariant 5 counts as
    /// running) or its agent has a write waiting; otherwise nothing is asked. Does nothing on a Landing
    /// (an id no conversation has), for an id no longer live, or for a conversation already
    /// asked about or closing (Rule 5).
    public func closeConversation(_ conversation: String? = nil) async {
        let target = conversation.map { self.conversation(id: $0) } ?? currentAgent
        guard let target, closeQuestion?.conversation != target.id, !closing.contains(target.id) else { return }
        // Rule 1: an unsaved tab is work a close would lose, so it refuses — before any question,
        // and stopping nothing — as a removal does.
        if let refusal = await unsavedTabsRefusal(closing: target) {
            status = refusal
            return
        }
        // A second close of it that came in across that await is ignored (Rule 5), as it is above.
        guard closeQuestion?.conversation != target.id, !closing.contains(target.id),
              conversations[target.id] === target else { return }
        // A start in flight is the operator's message on its way to an agent (final review I1):
        // closing it silently would lose that message, so it asks, as for a turn running.
        guard target.turnInFlight || target.startsSession || waitingConversations.contains(target.id) else {
            await endConversation(target)
            return
        }
        guard closeQuestion == nil else {
            status = "close: another conversation's Close question is open — answer it first"
            return
        }
        closeQuestion = CloseConversationQuestion(conversation: target.id)
    }

    /// The operator's answer to `closeQuestion`: **Close it** (`close: true`) ends the
    /// conversation whatever its turn did since — a turn that ended meanwhile asks nothing more;
    /// **Keep it** leaves it exactly as it was, and gives the keyboard back to the composer
    /// (`onCloseQuestionKept`; Rule 6, final review M3): the question took it from there.
    public func answerCloseQuestion(close: Bool) async {
        guard let question = closeQuestion else { return }
        closeQuestion = nil
        guard close else {
            onCloseQuestionKept?()
            return
        }
        guard let target = conversation(id: question.conversation) else { return }
        // A tab left unsaved while it asked is refused as it would have been before.
        if let refusal = await unsavedTabsRefusal(closing: target) {
            status = refusal
            return
        }
        await endConversation(target)
    }

    /// `unsavedTabsRefusal` for `agent`'s canvas, naming it by its title. Nil with no canvas.
    private func unsavedTabsRefusal(closing agent: PlaceAgent) async -> String? {
        guard let canvas = agent.layoutScope else { return nil }
        return await unsavedTabsRefusal(naming: agent.title) { $0 == canvas }
    }

    /// Ends `agent`'s conversation (plan 3, ruling 4): `stopSession` stops its harness and socket
    /// and cancels its proposals; it leaves `conversations`, and its place shows its next live
    /// conversation (`liveConversationRows(in:)`, newest first) or its Landing (`showLanding`).
    /// Its panes close as on quit: its arrangement is written to its file — by `activateLayout`'s
    /// flush of the canvas it leaves, on screen — its shells are killed and its scope is let go
    /// of in memory (`releaseCanvas`). Nothing is deleted on disk, so Continue lists it and a
    /// resume reads its canvas back.
    ///
    /// `placeRemoved`: the place itself was removed (`closeConversations`), so its arrangement is
    /// not written back under a name that is gone, and the place shows nothing after it — neither
    /// its next conversation, which closes too, nor its Landing.
    private func endConversation(_ agent: PlaceAgent, placeRemoved: Bool = false) async {
        guard conversations[agent.id] === agent, closing.insert(agent.id).inserted else { return }
        defer { closing.remove(agent.id) }
        if closeQuestion?.conversation == agent.id { closeQuestion = nil }
        // The stream the stop ends is the close, not a failure: the pump drops it.
        agent.eventPumpGeneration += 1
        agent.eventPump?.cancel()
        await stopSession(of: agent)
        agent.turnInFlight = false
        let place = agent.place
        let scope = agent.layoutScope
        let shown = screenConversations[place] == agent.id
        // Off screen, its arrangement as its agent last left it reaches its file now.
        if !placeRemoved, !(shown && place == self.place), let scope, scope != layoutScope,
           loadedLayoutScopes.contains(scope) {
            let snapshot = await ScopeRouting.$home.withValue(scope) { await layout.snapshot() }
            await persistLayout(snapshot, for: scope)
        }
        conversations[agent.id] = nil
        conversationOrder.removeAll { $0 == agent.id }
        if shown, placeRemoved {
            screenConversations[place] = nil
        } else if shown {
            screenConversations[place] = nil
            if let next = liveConversationRows(in: place).first {
                if place == self.place {
                    await switchToConversation(next.id)
                } else {
                    screenConversations[place] = next.id
                }
            } else {
                await showLanding(in: place)
            }
        }
        if let scope { await releaseCanvas(scope) }
        retainAgentPlace()
        onConversationClosed?(agent.id)
    }

    /// The refusal for `caller`, an agent session whose conversation is no longer live — a late
    /// call on a closed conversation's still-open connection — so it writes into no canvas: not
    /// the place's next conversation's, not its Landing's, and not the closed one's, let go of
    /// (Invariant 4). Whole (Rule 8). Nil for anyone else: the operator, a caller that names no
    /// conversation, and a Landing's reserved id, which its first message's conversation takes.
    private func closedConversationRefusal(_ action: String, _ caller: DispatchCaller) -> String? {
        guard pinnedPlace(of: caller) != nil, let id = caller.conversation, conversations[id] == nil,
              !reservedConversations.values.contains(id) else { return nil }
        return "\(action): the conversation this call came from was closed — nothing was done"
    }

    /// Kills `scope`'s shells and lets go of everything this window and its stores hold for it in
    /// memory, as `releaseLayouts` does for a removed place. Its file stays.
    private func releaseCanvas(_ scope: LayoutScope) async {
        await terminals.close(scope: scope)
        loadedLayoutScopes.remove(scope)
        scopesAwaitingRestore.remove(scope)
        backgroundLayouts[scope] = nil
        layoutNotesAwaitingReturn[scope] = nil
        await layout.forget(scope)
        await panes.forget(scope)
    }

    /// What the screen shows, as the composer keys its drafts (`ComposerModel.screenChanged`):
    /// the conversation on screen's id, else `"landing:"` and the id the place reserves for its
    /// next conversation — the one its Landing's first message will start — else, before the
    /// place has reserved one, `"landing:@<org>/<project>/<env>"`: never a bucket two places share.
    public var screenKey: String {
        if let id = currentAgent?.id { return id }
        if let reserved = reservedConversations[place] { return "landing:" + reserved }
        return Self.unreservedLandingKey(place)
    }

    /// The conversation the screen shows, for a socket's `initialize` (`initializeMeta`): the
    /// one on screen, else the one its Landing reserves — `screenKey` without `"landing:"`. Nil
    /// on a Landing that has reserved none, which no socket answers for yet.
    public var screenConversation: String? {
        if let id = currentAgent?.id { return id }
        return reservedConversations[place]
    }

    /// `place`'s Landing before it has reserved its next conversation.
    nonisolated static func unreservedLandingKey(_ place: Place) -> String {
        "landing:@\(place.organization)/\(place.project)/\(place.environment)"
    }

    /// Told when what the screen shows changes (`screenKey`), by whatever moved it: the `screenKey`
    /// left, the one arrived at, and whether the composer takes the keyboard — after a new
    /// conversation always, otherwise when the canvas arrived at has no focused pane (ruling 7).
    /// `ComposerModel` registers itself here in its `init`.
    @ObservationIgnored
    public var onScreenChange: (@MainActor (_ from: String, _ to: String, _ focusComposer: Bool) -> Void)? {
        // Whoever registers starts on the screen as it is now, so the next tell is from it.
        didSet { toldScreenKey = screenKey }
    }

    /// Told the id of each conversation closed (`endConversation`), after the screen has moved
    /// off it: `ComposerModel` drops the draft it kept for it. Registered in its `init`.
    @ObservationIgnored
    public var onConversationClosed: (@MainActor (_ conversation: String) -> Void)?

    /// Told when the Close question is answered **Keep it** (`answerCloseQuestion`), by click,
    /// Return or Esc: `ComposerModel` takes the keyboard back, as after New Conversation.
    /// Registered in its `init`.
    @ObservationIgnored
    public var onCloseQuestionKept: (@MainActor () -> Void)?

    /// The `screenKey` `onScreenChange` was last told about — set when it is registered, so the
    /// listener and the window agree on where they start; nil only with no one listening.
    @ObservationIgnored private var toldScreenKey: String?
    /// Set by `newConversation` around its activation: the Landing's composer takes the keyboard.
    @ObservationIgnored private var composerFocusForced = false

    /// Whether `from` and `to` — `to` being the screen now — are one screen renamed rather than
    /// two: a Landing's first message makes its reserved id the conversation's (`"landing:R"`
    /// becomes `"R"`), and the place on screen reserving its next conversation — or starting
    /// one — renames its unreserved Landing (`"landing:@<place>"`) into that id alone (`"landing:R"`
    /// or `"R"`), never into another conversation. The composer re-keys its draft for these and
    /// leaves it, and the keyboard, where they are.
    public func isSameScreenRenamed(from: String, to: String) -> Bool {
        if from == "landing:" + to { return true }
        guard from == Self.unreservedLandingKey(place) else { return false }
        // Only into the Landing's own id — reserved, or taken by the conversation it is becoming
        // (`agent(for:)`) — never into another conversation the screen moved to.
        let own = [reservedConversations[place], landingBecoming].compactMap { $0 }
        return own.contains { to == $0 || to == "landing:" + $0 }
    }

    /// Set by `agent(for:)` while it tells the screen its Landing became `landingBecoming`: the
    /// id an unreserved Landing is renamed to (`isSameScreenRenamed`).
    @ObservationIgnored private var landingBecoming: String?

    /// The one place a change of what the screen shows is told: the end of every
    /// `activateLayout`, and a conversation's creation (`agent(for:)`), which re-keys its
    /// Landing. Each change is told once; an unchanged `screenKey` tells nothing.
    private func tellScreenChange() {
        let now = screenKey
        guard let told = toldScreenKey, told != now else { return }
        toldScreenKey = now
        if isSameScreenRenamed(from: told, to: now) {
            onScreenChange?(told, now, false)
            return
        }
        // Ruling 7: the focus it had is what its canvas recorded — its focused pane, else the composer.
        let paneFocused = !composerFocusForced && layoutSnapshot.focusedId != nil
        onScreenChange?(told, now, !paneFocused)
        if paneFocused { returnKeyboardToFocusedPane() }
    }

    /// File ▸ New Conversation (⌘N): `session_new` through the registry, origin `ui`, as ⌘K's
    /// row runs it. On a Landing it does nothing visible (ruling 5).
    public func dispatchSessionNew() async {
        await dispatchLayout("session_new", .object([:]))
    }

    /// File ▸ Close Conversation (⌘⇧W): `session_close` through the registry, origin `ui`, as ⌘K's
    /// row runs it — pinned to the conversation on screen at the press (`screenPinnedActions`). On
    /// a Landing it does nothing (plan 3, ruling 6).
    public func dispatchSessionClose() async {
        await dispatchLayout("session_close", .object([:]))
    }

    /// Goes to `target` the way the operator would by hand — the organisation, then the
    /// project, then the environment, each only when it differs — so a chip's click asks nothing
    /// (Rule 1) and is the one thing that moves the operator (Rule 6). It stops at the first
    /// switch refused, whose refusal stays in `status`.
    ///
    /// Each switch lands somewhere first — an org switch on that org's remembered place, a
    /// project switch on its first environment — and none of those has been seen: only the place
    /// the screen ends on, the target or wherever a refusal stopped it, loses its unseen marks.
    public func goTo(_ target: Place) async {
        goTosInFlight += 1
        defer {
            goTosInFlight -= 1
            if goTosInFlight == 0 { markSeen(currentAgent) }
        }
        if target.organization != organization {
            await requestOrganizationSwitch(target.organization)
            guard organization == target.organization else { return }
        }
        if !target.project.isEmpty, target.project != projectKey {
            guard await setProject(target.project) else { return }
        }
        if !target.environment.isEmpty, target.environment != environment {
            _ = await setEnvironment(target.environment)
        }
    }

    /// The `goTo`s still between switches — a count, as a second click can start one before the
    /// first ends — so a place one lands on may be one it is only passing through.
    private var goTosInFlight = 0

    /// `agent`'s place is on screen: what it did while away has been seen.
    private func markSeen(_ agent: PlaceAgent?) {
        agent?.unseenResult = false
        agent?.unseenFailure = false
    }

    /// The operator asked to switch: it happens at once. Nothing is asked about unsaved tabs
    /// (R2) — they stay in their own place's canvas — and a turn in flight anywhere keeps
    /// running (Rule 1: switching away asks nothing).
    public func requestOrganizationSwitch(_ org: String) async {
        await setOrganization(org)
    }

    // MARK: - Org plane (Task 14)

    /// Whether ⌘⇧O's plane is open. Org-independent (`InvalidationContractTests`):
    /// this describes what is on screen, not either organisation's state, so an
    /// org switch must never open or close it as a side effect. The one place
    /// that forces it open regardless of this flag is `WakilWindow` itself, for
    /// an org-less window (spec §8.5) — there is nothing else to show.
    ///
    /// A plain `var`, not `private(set)`: the plane closes itself (Esc, or a
    /// successful switch) exactly the way `AppScene`'s menu command opens it —
    /// by setting this property directly, not by dispatching an action. It is
    /// presentation state, not a credential boundary, so Invariant 2 does not
    /// govern it the way it governs everything the plane itself goes on to do.
    /// Whether this window's session has done anything yet — the one fact
    /// the Landing is gated on.
    ///
    /// **The axis is the session, not the pane count.** Settled 2026-09-20,
    /// correcting the same day's earlier ruling. The Landing draws on a fresh
    /// open, before this session has done anything; the moment work starts —
    /// continuing a session, opening a pane, or speaking — it goes, and it
    /// does NOT come back when the last pane closes. A pane-less window
    /// mid-session is not empty: the room carries §4's four states, §9's
    /// thread is at the bottom edge, and redrawing a session list over that
    /// would offer to start work on top of work already in flight.
    ///
    /// **Sticky, and deliberately not derived.** `panes.isEmpty` is the rule
    /// this supersedes. `thoughts.isEmpty` misses the pane case, because
    /// opening a pane adds no thought. So this is set once, by whichever of
    /// the three happens first, and cleared only by a new session.
    ///
    /// Cleared in-window by `session_new` (`newConversation`): the place's
    /// Landing returns and the conversation keeps running in the background.
    ///
    /// Per place (`PlaceAgent.sessionStarted`): a place where no work has begun draws its
    /// Landing, whatever has begun elsewhere.
    public var sessionStarted: Bool { currentAgent?.sessionStarted ?? false }

    /// The id Wakil has assigned to this window's session, whether or not the
    /// agent has been started with it yet.
    ///
    /// **Not the same thing as `sessionId`, and the difference is the point.**
    /// `sessionId` means *the id the running child was started with* — it and
    /// `harness` are set together on all three paths that swap a child (a
    /// first turn, a resume, a provider switch), with ordering around event
    /// pump generations that is load-bearing and is not disturbed here. This
    /// means *which conversation this window is in*, which is knowable earlier.
    ///
    /// **Why earlier matters.** Work can begin without a turn: opening a pane
    /// from the Landing marks the session started, and `sessionId` stays `nil`
    /// until the operator types something, because it is minted inside `send`
    /// as part of spawning `claude`. So the first pane of a session had no
    /// session to belong to. Keying a pane arrangement on the conversation
    /// (#142) needs an identity at that moment, and spawning an agent to get
    /// one would be absurd — a database pane must not launch a subprocess.
    ///
    /// Wakil assigns the id rather than discovering it (open question 5), so
    /// there is nothing to wait for: the value is Wakil's to mint the moment
    /// work begins, and `send` starts the child with it rather than minting a
    /// second one.
    ///
    /// Follows `sessionId` wherever that moves, because a fork is a new
    /// conversation id and a provider switch mints a fresh one. The on-screen place's.
    public var assignedSessionId: String? { currentAgent?.assignedSessionId }

    /// The **lineage root** of the conversation this window is in: the
    /// oldest ancestor of its session, and the identity one conversation
    /// keeps across every resume that forked it. `nil` before any work has
    /// begun, which is the Landing.
    ///
    /// **Not `assignedSessionId`, and the gap between them is the whole of
    /// #147.** A resume is a fork, so `assignedSessionId` moves on every
    /// one: six resumes are six ids. They are one *conversation*, and this
    /// is what stays put across all six. Keyed on the session id instead,
    /// an arrangement would be abandoned by the very act of continuing the
    /// work it belongs to.
    ///
    /// **Tracked here rather than looked up.** A session that has never
    /// taken a turn has no transcript, so it does not appear in
    /// `list_sessions` at all — and that is exactly the case this has to
    /// work for, because a pane opened from the Landing is filed before
    /// any turn exists. So the window carries the answer: a freshly
    /// assigned conversation is its own root, and a resume inherits the
    /// root of the session it forked from, which the listing *does* carry
    /// for a session old enough to be resumed.
    ///
    /// The on-screen place's (`PlaceAgent.lineageRoot`): each place keeps its own across every
    /// switch, so a place's panes are only ever filed under its own conversation.
    public var lineageRoot: String? { currentAgent?.lineageRoot }

    /// Called by the three entrances into work. Idempotent on purpose — it is
    /// reached from a turn, a pane and a resume, and two of those can happen
    /// in the same gesture.
    public func markSessionStarted() {
        markSessionStarted(in: agent(for: place))
    }

    /// `markSessionStarted` for one place's agent, on screen or not.
    private func markSessionStarted(in agent: PlaceAgent) {
        agent.sessionStarted = true
        // Minted here rather than in `send`, so a pane opened from the
        // Landing belongs to a conversation before a turn exists. Idempotent
        // with the flag above: this is reached from a turn, a pane and a
        // resume, and two of those can happen in one gesture.
        if agent.assignedSessionId == nil {
            // The conversation's own id: the one the place's shown socket reserved, so the
            // session that starts here takes that socket (`openShownSocket`, `agent(for:)`).
            let id = agent.id
            agent.assignedSessionId = id
            // **A conversation started fresh is its own root**, which is
            // the same answer `wakilcore.LineageRootIn` gives for an id
            // with no recorded parent. `resume` overwrites this with the
            // root it inherits, and it runs after this: `resume` calls
            // `markSessionStarted()` at its own first line, so a resume
            // that gets as far as swapping the harness has already minted
            // a throwaway root here and replaces it deliberately.
            agent.lineageRoot = id
        }
    }

    /// The place's screen conversation, created the first time work begins there under the id the
    /// place's shown socket reserved, or a fresh one.
    private func agent(for place: Place) -> PlaceAgent {
        if let existing = agents[place] { return existing }
        let id = reservedConversations.removeValue(forKey: place) ?? UUID().uuidString
        let created = PlaceAgent(
            id: id, place: place, providerId: providerId,
            mirror: TerminalMirrorFeed(panes: panes, layout: layout), ordinal: conversationsMade)
        // Created over the Landing `newConversation` showed: that canvas is already filed under
        // this id (`landingRoot(in:)`), so the conversation is rooted there from its first moment
        // and the scope never moves out from under it — whichever entrance created it.
        if landingBaselines.removeValue(forKey: place) != nil { created.lineageRoot = id }
        landingsLoading.remove(place)
        conversationsMade += 1
        conversations[id] = created
        conversationOrder.append(id)
        screenConversations[place] = id
        // Its row is listed from now, sent to or not: production red from its first moment.
        refreshChipProduction(of: created)
        // On screen, its Landing is now this conversation: the same screen, re-keyed. Mid-activation
        // the activation's own tell comes after its canvas is in, and says it.
        if place == self.place, !layoutActivating {
            landingBecoming = id
            defer { landingBecoming = nil }
            tellScreenChange()
        }
        return created
    }

    /// Stops the Landing being drawn over a canvas that already has panes on
    /// it, **without minting a conversation for them**.
    ///
    /// #264: an agent's `pane_open` reaches `ActionRegistry.dispatch` and the
    /// handler directly and never enters this window, so the pane is on the
    /// canvas, focused and live, with the Landing drawn over it.
    ///
    /// **Not `markSessionStarted()`, and the difference is load-bearing.**
    /// That mints `assignedSessionId` and `lineageRoot`, and `lineageRoot` is
    /// part of `LayoutScope` — so minting one here moves the scope out from
    /// under panes that are already filed under the old one, and the next
    /// `activateLayout` hands back an empty arrangement for a scope nothing
    /// has restored. The pane would vanish, which is a worse version of the
    /// bug being fixed. Measured: two layout-persistence tests went red on
    /// exactly that.
    ///
    /// `openPane` avoids it by entering the conversation BEFORE dispatching,
    /// so the pane is opened into the arrangement it is going to live in. The
    /// agent's dispatch offers no such moment — by the time this window hears
    /// about it, the write has happened.
    ///
    /// **Owed: the pane is filed under no conversation.** It is drawn and it
    /// works, and a relaunch will not restore it into the conversation it
    /// belongs to, because it never belonged to one. Fixing that means the
    /// agent's entrance minting the identity before the handler writes —
    /// which is a change to where the MCP path meets this window, not to what
    /// it does afterwards. Recorded on #264 rather than guessed at here.
    private func showTheWorkAlreadyOnTheCanvas() {
        agent(for: place).sessionStarted = true
    }

    public var showOrgPlane = false

    /// One row of `ctx_list_orgs`: an organisation registered on this machine,
    /// never a credential (Task 13's own doc comment on the action).
    public struct OrgListing: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        /// `nil` when the organisation has no display name — the wire omits
        /// the field rather than sending an empty string, the same precedent
        /// `jiraBase` below sets. The plane falls back to `name` (the id) in
        /// that case (spec §8.1.1).
        public let displayName: String?
        /// `nil` when the organisation has no Jira site — the wire omits the
        /// field rather than sending an empty string, and the plane draws
        /// "no Jira site" for that, never a blank.
        public let jiraBase: String?
        public let accounts: Int
    }

    /// One row of `ctx_list_machine_providers`: an account registered anywhere
    /// on this machine, as an `(org, provider)` pair.
    ///
    /// **`org` and `homeOrg` differ exactly for a `--share` binding.** `org` is
    /// the organisation this row is registered under; `homeOrg`, when present
    /// and different, is the organisation whose config dir the account's
    /// credentials actually live in — the one fact worth surfacing, because a
    /// plain `claude` session started in that config dir runs as `homeOrg`,
    /// not `org` (Task 13's own doc comment on `adopt_provider`).
    public struct MachineProviderListing: Sendable, Equatable, Identifiable {
        public var id: String { "\(org)/\(providerId)" }
        public let org: String
        public let providerId: String
        public let kind: String
        public let label: String?
        public let configDir: String?
        public let homeOrg: String?
    }

    /// Runs an operator-only read/control action expecting a
    /// `structuredContent` object back, through the same `dispatch(_:_:)`
    /// every other control on this window already uses — a refusal (the
    /// permission layer denying an agent-origin call is irrelevant here;
    /// `origin: .ui` always passes it) lands in `status` exactly like any
    /// other dispatch's does, rather than being reported a second way.
    private func structuredResult(_ name: String, _ params: JSONValue) async -> [String: JSONValue]? {
        guard let result = await dispatch(name, params) else { return nil }
        guard case .object(let object) = result,
              case .object(let structured)? = object["structuredContent"]
        else {
            status = "\(name): the result carried no structuredContent object"
            return nil
        }
        return structured
    }



    /// ⌘⇧O's Choosing state: every organisation registered on this machine.
    /// Operator-only (`ctx_list_orgs` is reachable with no active org set by
    /// design), and the one caller of that action in `WakilApp`.
    public func listOrgs() async -> [OrgListing] {
        guard let structured = await structuredResult("ctx_list_orgs", .object([:])) else { return [] }
        guard case .array(let rows)? = structured["orgs"] else {
            status = "ctx_list_orgs: the result carried no \"orgs\" array"
            return []
        }
        return Self.orgListings(from: rows)
    }

    nonisolated internal static func orgListings(from rows: [JSONValue]) -> [OrgListing] {
        OrgListings.orgListings(from: rows)
    }

    /// ⌘⇧O's Adopting state: every account registered anywhere on this
    /// machine. Operator-only, for the identical reason `listOrgs()` is.
    public func listMachineProviders() async -> [MachineProviderListing] {
        guard let structured = await structuredResult("ctx_list_machine_providers", .object([:]))
        else { return [] }
        guard case .array(let rows)? = structured["providers"] else {
            status = "ctx_list_machine_providers: the result carried no \"providers\" array"
            return []
        }
        return Self.machineProviderListings(from: rows)
    }

    nonisolated internal static func machineProviderListings(
        from rows: [JSONValue]
    ) -> [MachineProviderListing] {
        OrgListings.machineProviderListings(from: rows)
    }

    // MARK: - The context line's own listings

    /// One row of `ctx_list_projects`, for the context line's Project
    /// segment.
    ///
    /// **Separate from `projectPaletteItems`' `PaletteItem`, deliberately.**
    /// A palette row is a title, a subtitle and an opaque payload string —
    /// everything the palette needs and nothing a control can branch on.
    /// The context line needs the fields themselves, and flattening them
    /// into a subtitle here only to parse them back out in the view is how
    /// `kind` came to be carried by `PaletteItem` and thrown away by the
    /// view that drew it.
    public struct ProjectListing: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        /// `nil` when the entry names no provider — the wire omits the field
        /// rather than sending an empty string, the precedent `OrgListing`
        /// already sets for every optional on this wire.
        public let provider: String?
        /// `nil` likewise. A project has 1..n roots (Decision 7); this is
        /// the registry entry's own recorded path, not "the" root.
        public let path: String?
    }

    // `EnvironmentListing`, one row of `ctx_list_environments`, lives in Core/ so the palette's
    // sources can name it without reaching into App/.

    /// The context line's Project segment, when it opens.
    public func listProjects() async -> [ProjectListing] {
        guard let structured = await structuredResult("ctx_list_projects", .object([:]))
        else { return [] }
        guard case .object(let projects)? = structured["projects"] else {
            status = "ctx_list_projects: the result carried no \"projects\" object"
            return []
        }
        return Self.projectListings(from: projects)
    }

    nonisolated internal static func projectListings(
        from projects: [String: JSONValue]
    ) -> [ProjectListing] {
        OrgListings.projectListings(from: projects)
    }

    /// The context line's Environment segment, when it opens.
    ///
    /// Each row carries its own notice, so there is no window-scoped copy
    /// to hold, clear on an org switch, or let go stale (#182).
    public func listEnvironments() async -> [EnvironmentListing] {
        guard let structured = await structuredResult("ctx_list_environments", .object([:]))
        else { return [] }
        return Self.environmentListings(from: structured)
    }

    nonisolated internal static func environmentListings(
        from structured: [String: JSONValue]
    ) -> [EnvironmentListing] {
        OrgListings.environmentListings(from: structured)
    }

    /// Configurations a reader of `project.json` would misread, as
    /// `list_environments` reports them — a `prod`, `prd`, `live` or
    /// `preprod` carrying no production flag, and a `production` declaring
    /// false.
    ///
    /// **Surfaced once, with the listing, and never per call.** A warning on
    /// every action that touches the environment is a warning nobody reads.
    /// Empty against a stale binary, which simply has nothing to say.
    /// Adopting's candidate list: every machine-provider row not already
    /// registered under `org`, one row per PHYSICAL account.
    ///
    /// **Task 14, fix round 1 (Important 1).** Moved out of `OrgPlane`
    /// (`WakilApp`, no test target) and into `WakilKit` after this
    /// function's de-duplication identity was wrong twice in a row, in two
    /// different ways — a signal about where the function lived, not about
    /// how carefully it was written.
    ///
    /// **Identity is `configDir`, not `providerId`.** A provider id is
    /// scoped to one org's own directory
    /// (`~/.wakil/orgs/<org>/providers/<id>.json`) — it is not globally
    /// unique. Two unrelated physical accounts under different orgs can
    /// share an id (`main` under both `personal` and `work`, say); a
    /// de-dup keyed on the bare id silently drops one of them. `configDir`
    /// is the right identity because it is the credential boundary a
    /// `--share` binding does NOT move (`ctx_adopt_provider`'s own
    /// registration comment: "the config dir keeps its existing headless
    /// home") — two rows sharing a `configDir` are the same account under
    /// two names, and two rows with different `configDir`s are two
    /// different accounts even when their ids collide. Only when
    /// `configDir` is absent (`omitempty` on the wire — a `--kind codex`
    /// or `--kind local` account, which Wakil does not manage a directory
    /// for) does this fall back to `(homeOrg ?? org, providerId)`, the
    /// closest available proxy for "the same account" with no config dir
    /// to key on at all.
    ///
    /// **Excludes anything already registered under `org` by identity, not
    /// by row.** Filtering rows to `row.org != org` alone let a provider's
    /// OWN native row re-offer itself as a candidate for the very org it
    /// had just been adopted into, because that org's row for the same
    /// account sits elsewhere in the same list — fixed in the prior round,
    /// kept here.
    // `public`, unlike `orgListings(from:)`/`machineProviderListings(from:)`
    // just above: those two are only ever called from inside this class
    // (`listOrgs()`/`listMachineProviders()`), so `internal` plus
    // `@testable import` is enough for `WindowModelTests` to reach them.
    // `OrgPlane` (`WakilApp`, a separate module, no `@testable` available
    // to it) calls this one directly — it has to be `public` or it could
    // not.
    nonisolated public static func adoptionCandidates(
        from rows: [MachineProviderListing], excluding org: String
    ) -> [MachineProviderListing] {
        OrgListings.adoptionCandidates(from: rows, excluding: org)
    }

    nonisolated public static func slugForOrgIdentifier(from name: String) -> String? {
        OrgListings.slugForOrgIdentifier(from: name)
    }

    /// Creating: mints a new organisation. `.control`, operator-only
    /// (`ctx_create_org`'s own registration comment) — this dispatches it
    /// exactly as `setProject`/`setEnvironment` above dispatch their own
    /// `.control` actions, so a refusal (Go's `normaliseOrg` rule, verbatim)
    /// lands in `status` the same way theirs does. The plane renders it
    /// rather than re-implementing the rule Swift-side — the same reasoning
    /// `VoidPalette.forEnvironment`/`writeGate`'s prior drift is a warning
    /// against.
    ///
    /// Returns whether it succeeded; `status` names the reason on failure.
    @discardableResult
    public func createOrg(id: String, displayName: String?, jiraBase: String?) async -> Bool {
        var params: [String: JSONValue] = ["id": .string(id)]
        if let displayName, !displayName.isEmpty { params["displayName"] = .string(displayName) }
        if let jiraBase, !jiraBase.isEmpty { params["jiraBase"] = .string(jiraBase) }
        return await dispatch("ctx_create_org", .object(params)) != nil
    }

    /// Adopting: binds an account that already exists on this machine into
    /// `org`, as a shared registration. `.control`, operator-only, dispatched
    /// the same way `createOrg` is above.
    @discardableResult
    public func adoptProvider(
        org: String, id: String, configDir: String, kind: String, label: String?,
        fromOrg: String? = nil, fromId: String? = nil
    ) async -> Bool {
        var params: [String: JSONValue] = [
            "org": .string(org), "id": .string(id),
            "configDir": .string(configDir), "kind": .string(kind),
        ]
        if let label, !label.isEmpty { params["label"] = .string(label) }
        // 2e (#201). Naming the source is what makes the adoption instant:
        // the credential is copied Keychain-to-Keychain in Go, so no
        // browser opens. Absent means copy nothing, which is what the org
        // plane's own Adopt still sends — it is a different surface with a
        // different gesture, and widening it is not this ticket's.
        if let fromOrg, !fromOrg.isEmpty { params["fromOrg"] = .string(fromOrg) }
        if let fromId, !fromId.isEmpty { params["fromId"] = .string(fromId) }
        return await dispatch("ctx_adopt_provider", .object(params)) != nil
    }

    /// Adopts `account` into the organisation the operator is standing in,
    /// from the settings pane's own row, and re-reads.
    ///
    /// **It renders in place and stops pointing at the organisation
    /// plane** (#201). The row the operator pressed IS the source, so the
    /// credential copy needs nothing typed and nothing searched for.
    ///
    /// Returns the refusal's own sentence, or `nil` on success — drawn
    /// beside the row, the same discipline `saveOrganisationField` follows
    /// and for the same reason.
    public func adoptAccount(_ account: Account) async -> String? {
        guard !organization.isEmpty else {
            return "no organisation is open, so there is nothing to adopt into"
        }
        guard !account.mine else {
            return "\(account.accountId) is already registered in \(organization)"
        }
        let adopted = await adoptProvider(
            org: organization, id: account.accountId, configDir: account.configDir,
            kind: account.kind, label: account.label,
            fromOrg: account.org, fromId: account.accountId)
        await refreshSettings()
        // `status` carries the dispatch's own sentence on failure — see
        // `dispatch`, which sets it. Read after the refresh so a refusal
        // is not lost to the re-read.
        return adopted ? nil : status
    }

    /// Appends one seam row marking a provider switch, using the same
    /// monotonic `nextThoughtId` counter `rebuiltThread` draws from — see
    /// that method's doc comment for why the counter is never reset: this
    /// seam is appended onto a `thoughts` array that was just replaced
    /// wholesale (`setProvider` clears it immediately before calling this),
    /// and a repeated id would make `ThoughtRow`'s `Identifiable`
    /// conformance draw one row twice and drop another, exactly as a reset
    /// counter would for a rebuilt resume thread.
    /// **The label is `session`, not `account`, and that is not cosmetic.**
    /// The account indicator (`WakilWindow.accountIndicator`) renders the
    /// micro-label `ACCOUNT` at the bottom-trailing corner, and this row
    /// renders its own label in the same 8.5px tracked uppercase idiom at
    /// the bottom-leading corner — the same horizontal band, ~1400pt apart.
    /// Labelling both `ACCOUNT` put two identical words on one edge meaning
    /// two different things: this row is *news* (a switch happened once, and
    /// scrolls away), the indicator is *state* (which account you are on
    /// right now, permanently). The operator's first hands-on walk on
    /// 2026-09-11 found exactly that collision. `session` names what this
    /// row actually marks — the session boundary — and leaves `ACCOUNT`
    /// meaning one thing in the window.
    /// Into `agent`'s thread, or the on-screen place's.
    private func appendSeam(_ detail: String, in agent: PlaceAgent? = nil) {
        (agent ?? self.agent(for: place)).appendRow(label: "session", detail: detail)
    }

    /// Parks a throwaway `.mutate` proposal into `confirmations` and
    /// returns once it is either actually parked or definitively not
    /// going to be — built for `ProviderSwitchTests`' "a mutation is
    /// waiting for confirmation" refusal, which needs
    /// `confirmations.all()` to answer non-`nil` without any human,
    /// or any expiry, ever resolving it.
    ///
    /// `ConfirmationBroker.request(_:)` does not return until a decision
    /// arrives, so awaiting it directly here would hang this method
    /// forever. It fires `request` from a detached task instead and polls
    /// `current()` for the moment `request` sets its `pending` — which
    /// `ConfirmationBroker.request`'s own body does as its very first
    /// action, before it ever suspends — so the poll below resolves
    /// almost immediately rather than racing anything real.
    ///
    /// **Bounded, and checked against `.busy`.** An unbounded `while
    /// current() == nil` would spin forever if `confirmations` already
    /// held a proposal when this was called — `request(_:)` resolves
    /// `.busy` immediately without ever touching `pending` in that case,
    /// so `current()` would stay whatever it already was (possibly
    /// `nil`, if the broker's existing proposal had itself already been
    /// decided) and this loop would never see the one it just sent. A
    /// fixed retry budget, with a `preconditionFailure` naming exactly
    /// what went wrong, turns that hang into an immediate, legible test
    /// failure instead.
    func parkAProposalForTesting() async {
        let proposal = PendingMutation(
            action: "test_only_proposal", params: .object([:]), database: nil,
            statement: "SELECT 1", affectsEveryRow: false, origin: .ui, place: place)
        Task { [confirmations] in _ = await confirmations.request(proposal) }
        for _ in 0..<1_000 {
            if await confirmations.current(for: proposal.place)?.id == proposal.id { return }
            await Task.yield()
        }
        preconditionFailure(
            "parkAProposalForTesting: the proposal never parked — confirmations may already "
                + "have held one (request(_:) resolves .busy without touching pending)")
    }

    /// Maps a read thread into rows, oldest first, with the seam last so
    /// the six-row window (`ThoughtThread` renders only
    /// `Array(rows.suffix(6))`) shows it.
    ///
    /// `nextThoughtId` is NOT reset here, deliberately. Every id — live or
    /// rebuilt — is handed out from this one monotonic counter, and it is
    /// that single source, not any reset, that keeps a rebuilt batch's ids
    /// distinct from whatever the live thread already used: the counter
    /// simply keeps counting up from wherever it was. Resetting it to 0
    /// would instead make this batch's ids collide with a *previous*
    /// batch's — ids 0…n get reused every rebuild — which is worse than
    /// inert: `thoughts` is replaced wholesale on a rebuild, so `ThoughtRow`
    /// stays `Identifiable`-unique either way, but SwiftUI would then see
    /// the new rows as content changes to existing identities rather than
    /// as insertions, and `ThoughtThread`'s transition would not fire on
    /// the seam. `ThoughtRow` is `Identifiable`; a repeated id makes
    /// SwiftUI draw one row twice and omit another — the bug
    /// `droppedEventsDoNotCollapseRowIds` already pinned once for the live
    /// path, which a reset here would have reintroduced for the rebuilt one.
    private func rebuiltThread(
        _ thread: SessionThreadSnapshot, parent: String, for agent: PlaceAgent
    ) -> [ThoughtRow] {
        var rows: [ThoughtRow] = []
        for entry in thread.entries.suffix(Self.rebuiltThreadLimit) {
            // 2d-i: the transcript holds what was sent — the typed text
            // plus the note — so the operator's turn is split back into
            // the text they typed and the `RESOLVED` row the live turn showed.
            var detail = entry.detail
            var resolvedRow: String?
            if entry.label == "you" { (detail, resolvedRow) = TurnNote.split(entry.detail) }
            rows.append(ThoughtRow(id: agent.nextThoughtId, label: entry.label, detail: detail, isError: entry.isError))
            agent.nextThoughtId += 1
            if let resolvedRow {
                rows.append(ThoughtRow(id: agent.nextThoughtId, label: "resolved", detail: resolvedRow, isError: false))
                agent.nextThoughtId += 1
            }
        }
        var seam = "resumed from \(parent)"
        if thread.truncated { seam += " (earlier turns not shown)" }
        rows.append(ThoughtRow(id: agent.nextThoughtId, label: "resumed", detail: seam, isError: false))
        agent.nextThoughtId += 1
        return rows
    }

    /// 2d-ii: a speech engine's failure, whole, as a red thread row
    /// (interaction rule 8).
    public func appendSpeechFailure(_ message: String) {
        agent(for: place).appendRow(label: "speech", detail: message, isError: true)
    }

    /// The active organisation's speech engine id, `""` when unset. Reads
    /// the cached settings tree, and fetches only the tree — never the
    /// account table `refreshSettings` also reads — when there is none,
    /// because this runs on every hold of ⌥.
    public func speechEngineId() async -> String {
        if let settings { return settings.org.speechProvider }
        guard let result = try? await registry.dispatch(
            name: "ctx_config_tree", params: .object([:]), origin: .ui,
            caller: DispatchCaller(place: place, session: nil), confirmation: nil),
              let tree = decodeSettingsTree(fromResult: result) else { return "" }
        settings = tree
        return tree.org.speechProvider
    }

    /// 2d-i: the operator's text, unchanged, plus the hint when anything in
    /// it folds to a name in scope. Appends the `RESOLVED` row and journals
    /// the note whole; the row is one truncated line like every other.
    ///
    /// A resume or provider switch that lands while `current()` is suspended bumps
    /// `eventPumpGeneration` and appends its seam; the old turn's row must not follow it, so a
    /// moved generation sends the text unchanged, with no row and no journal entry.
    ///
    /// **The vocabulary is the screen's place's** (Invariant 4 for names). `send` suspends before
    /// it gets here — the conversation, the credentials, the harness start — and a switch that
    /// lands in between leaves the vocabulary describing another place, another organisation's
    /// included. So a turn whose place is no longer on screen when the names are in hand goes
    /// unchanged too: no note is better than another place's.
    private func textWithIdentifierNote(_ text: String, for agent: PlaceAgent) async -> String {
        guard let vocabulary, agent.place == place else { return text }
        let generation = agent.eventPumpGeneration
        let current = await vocabulary.current()
        guard generation == agent.eventPumpGeneration, agent.place == place else { return text }
        let resolutions = IdentifierResolver.resolve(text, in: current)
        guard let note = TurnNote.render(resolutions) else { return text }
        agent.appendRow(label: "resolved", detail: TurnNote.row(resolutions))
        try? await registry.journalIdentifierEvent(
            action: "identifiers_resolved", params: .object(["note": .string(note)]),
            caller: DispatchCaller(place: agent.place, session: nil, conversation: agent.id), outcome: "ok")
        return text + "\n\n" + note
    }

    /// One session's transcript, read back through the registry — `Sendable`
    /// because it crosses from `readThread`'s `await registry.dispatch` back
    /// onto the main actor with nothing but value types.
    struct SessionThreadSnapshot: Sendable {
        struct Entry: Sendable {
            let label: String
            let detail: String
            let isError: Bool
        }
        let entries: [Entry]
        let cwd: String
        let provider: String
        let truncated: Bool
    }

    /// Errors `readThread` throws itself, as opposed to whatever
    /// `ActionRegistry.dispatch` throws when `session_read` itself fails.
    enum ReadThreadError: Error, CustomStringConvertible {
        case malformedResult(String)

        var description: String {
            switch self {
            case .malformedResult(let text): return text
            }
        }
    }

    /// Dispatches `session_read` for `id` and decodes its
    /// `structuredContent` into a `SessionThreadSnapshot`.
    ///
    /// Goes through the registry like every other read this window makes
    /// (Invariant 2 in the small): the agent and the operator's ⌘P both
    /// reach the same transcript through the same journaled path, rather
    /// than this window reading `wakil-ctx` directly and the agent reading
    /// it through `session_read` — two paths to the same fact.
    ///
    /// `kind` is mapped to the same words `thoughtRow` draws for a live
    /// event — `assistant` → `"assistant"`, `tool` → `"tool"`, `toolResult`
    /// → `"tool result"` — so a rebuilt row and a live one read identically.
    /// `user` → `"you"` is drawn the same way by live sends and the rebuilt
    /// thread (2d-ii), so the two read identically: a history of tool calls
    /// with no record of what was asked is a log, not a conversation.
    private func readThread(_ id: String, as caller: DispatchCaller) async throws -> SessionThreadSnapshot {
        let result = try await registry.dispatch(
            name: "session_read",
            params: .object(["id": .string(id), "limit": .number(Double(Self.rebuiltThreadLimit))]),
            origin: .ui, caller: caller, confirmation: nil)
        guard case .object(let object) = result, case .object(let structured)? = object["structuredContent"] else {
            throw ReadThreadError.malformedResult("session_read: the result carried no structuredContent object")
        }
        guard case .string(let cwd)? = structured["cwd"] else {
            throw ReadThreadError.malformedResult("session_read: the result carried no string \"cwd\"")
        }
        guard case .string(let provider)? = structured["provider"] else {
            throw ReadThreadError.malformedResult("session_read: the result carried no string \"provider\"")
        }
        var truncated = false
        if case .bool(let flag)? = structured["truncated"] { truncated = flag }
        var entries: [SessionThreadSnapshot.Entry] = []
        if case .array(let rawEntries)? = structured["entries"] {
            for raw in rawEntries {
                guard case .object(let fields) = raw, case .string(let kind)? = fields["kind"] else { continue }
                var text = ""
                if case .string(let value)? = fields["text"] { text = value }
                var toolName = ""
                if case .string(let value)? = fields["toolName"] { toolName = value }
                var isError = false
                if case .bool(let flag)? = fields["isError"] { isError = flag }
                let label: String
                let detail: String
                switch kind {
                case "user":
                    label = "you"
                    detail = text
                case "assistant":
                    label = "assistant"
                    detail = text
                case "tool":
                    label = "tool"
                    detail = toolName.isEmpty ? text : "\(toolName) \(text)"
                case "toolResult":
                    label = "tool result"
                    detail = text
                default:
                    continue
                }
                entries.append(SessionThreadSnapshot.Entry(label: label, detail: detail, isError: isError))
            }
        }
        // `structured["parent"]` (the session's own lineage-recorded
        // parent, per `session_read`'s `SessionThread.Parent`) is
        // deliberately not decoded here. It was carried into a `parent`
        // field on this struct and never read anywhere afterwards: the
        // seam's "resumed from …" label (`rebuiltThread`) names the id
        // THIS resume was given, a separate value already in scope at the
        // call site, not this session's own recorded parent. Nothing else
        // in this window reads it either. A field that is decoded and
        // never used is worse than one that is absent — it invites a
        // future caller to assume it already does something (name the
        // conversation's chain root, say) that it does not.
        return SessionThreadSnapshot(entries: entries, cwd: cwd, provider: provider, truncated: truncated)
    }

    /// Where `debugLogIfEnabled` writes. Defaults to stderr — the seam
    /// exists only so `WindowModelTests` can capture what would otherwise
    /// leave the process, per Finding 1 of the final review (2026-09-09).
    var debugEventSink: (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Overrides the `WAKIL_DEBUG_EVENTS` check below for tests. `nil` (the
    /// default, and the only value production ever sees) means "read the
    /// real process environment," exactly as before. A test cannot safely
    /// use `setenv`/`unsetenv` for this: Swift Testing runs tests in
    /// parallel by default, and the environment is process-wide state, so
    /// two tests toggling it race each other. This is instance state on
    /// the model under test instead, which carries no such risk.
    var debugEventsEnabledOverride: Bool?

    private var debugEventsEnabled: Bool {
        debugEventsEnabledOverride ?? (ProcessInfo.processInfo.environment["WAKIL_DEBUG_EVENTS"] != nil)
    }

    /// Finding 1 of the final review (2026-09-09): every event this pump
    /// receives lands here, including the ~77% that `thoughtRow` maps to
    /// `nil` and `append` then drops on the floor — before this fix, that
    /// meant a session stalled between a `tool_use` and its `tool_result`
    /// had no artefact anywhere to inspect. This is the debug route: gated
    /// on `WAKIL_DEBUG_EVENTS` in the process environment (see
    /// `debugEventsEnabled` above), checked fresh on every call rather than
    /// cached, so it costs one dictionary lookup — not the formatting or
    /// the write — when unset. It runs before `thoughtRow` so it sees every
    /// event that arrives here, not just the ones that survive projection.
    private func debugLogIfEnabled(_ event: HarnessEvent) {
        guard debugEventsEnabled else { return }
        let line: String
        switch event {
        case .systemInit(let sessionId):
            line = "systemInit sessionId=\(sessionId)"
        case .assistantText(let text):
            line = "assistantText chars=\(text.count)"
        case .toolUse(let id, let name, _):
            line = "toolUse id=\(id) name=\(name)"
        case .toolResult(let id, _, let isError):
            line = "toolResult id=\(id) isError=\(isError)"
        case .result(let isError, let text):
            line = "result isError=\(isError) textChars=\(text?.count ?? 0)"
        case .unknown(let type):
            line = "unknown type=\(type)"
        case .rateLimit(let w):
            line = "rateLimit fiveHourLeft=\(w.fiveHour.percentLeft) sevenDayLeft=\(w.sevenDay.map { String($0.percentLeft) } ?? "-")"
        }
        debugEventSink("[WAKIL_DEBUG_EVENTS] \(line)")
    }

    private func append(_ event: HarnessEvent, to agent: PlaceAgent) {
        debugLogIfEnabled(event)
        if case .result(let isError, _) = event {
            agent.turnInFlight = false
            markUnseen(failed: isError, for: agent)
        }
        // Task 15, fix round 1 (Critical): `Date()` is captured exactly
        // here, at the one place a harness event actually arrives, and
        // carried alongside it into `mirror.events` — not recomputed later,
        // and not synthesised at all inside `mirroredBlocks`, which is
        // what the first cut got wrong. See `MirrorEvent`'s own doc
        // comment for the regression this replaced.
        agent.mirror.retain(event, at: Date())
        guard let row = thoughtRow(id: agent.nextThoughtId, for: event) else { return }
        agent.nextThoughtId += 1
        agent.thoughts.append(row)
        agent.lastActivity = Date()
    }

    // MARK: - Terminal mirror (Task 15) — see `TerminalMirrorFeed`

    /// TEST-ONLY: feeds `event` through exactly the path a live harness
    /// event takes — `append(_:)` for the thought thread, then
    /// `mirror.pump(_:)` for every open terminal pane — and waits for both
    /// before returning, so an assertion immediately afterwards sees the
    /// result with no race to poll for. `startEventPump`'s own loop does
    /// the same two calls, in the same order, for the same reason.
    func receiveForTesting(_ event: HarnessEvent, provider: String? = nil) async {
        let agent = agent(for: place)
        append(event, to: agent)
        await agent.mirror.pump(event, into: nil)
        await recordCapacity(event, provider: provider ?? providerId)
        // Awaited here so tests are deterministic; the live pump loop starts it unawaited.
        if case .result = event { await capacity.refresh(probe: true) }
    }

    /// The probe, started unawaited so it never holds the operator's canvas.
    private func startCapacityProbe() {
        capacityProbe = Task { [weak self] in await self?.capacity.refresh(probe: true) }
    }

    /// TEST-ONLY: waits for the probe the last trigger started.
    func settleCapacityForTesting() async {
        await capacityProbe?.value
    }

    /// One stream reading, recorded against the account the producing session ran under.
    ///
    /// **An agent in an organisation the screen has left records under its own** (background
    /// agents 3 of 4): its account is one of that org's providers, and the window's `wakil-ctx`
    /// now answers for the org on screen, where the same id names another account or none.
    /// Dispatched as that agent, so it reaches the client pinned to its place
    /// (`PlaceRoutedCaller`). The window's readings are the screen's org's, so none is re-read.
    private func recordCapacity(_ event: HarnessEvent, provider: String, for agent: PlaceAgent? = nil) async {
        guard case .rateLimit(let windows) = event else { return }
        if let agent, agent.place.organization != organization {
            guard !provider.isEmpty else { return }
            _ = try? await registry.dispatch(
                name: "capacity_record",
                params: capacityRecordParams(provider: provider, windows: windows, asOf: Date()),
                origin: .ui, caller: agent.caller, confirmation: nil)
            return
        }
        await capacity.receive(windows, provider: provider)
    }

    /// TEST-ONLY: the on-screen place's agent's `Bash` events, held for a terminal pane opened
    /// later — none of another place's.
    var mirrorEventsForTesting: [MirrorEvent] { currentAgent?.mirror.events ?? [] }

    /// TEST-ONLY: the raw `PaneStore` this model reads and writes, for a
    /// test that wants its own narrower API (`terminalBlocks(paneId:)`,
    /// `snapshot(paneId:kind:)`) directly rather than one of the
    /// `...ForTesting` wrappers below, which exist for the handful of
    /// reads or writes common enough to be worth naming here.
    var panesForTesting: PaneStore { panes }

    /// TEST-ONLY: the arrangement of `scope`, read with the scope named, whichever is on screen.
    func layoutSnapshotForTesting(in scope: LayoutScope) async -> LayoutSnapshot {
        await ScopeRouting.$home.withValue(scope) { await layout.snapshot() }
    }

    // MARK: - Terminal

    /// Journals `term_run` for one command a terminal pane's shell just
    /// finished — `terminalRunPump`'s only job.
    ///
    /// **Dispatched once, at the block's `D` mark, not at its `C`.** The
    /// plan's own text says the action is journalled *from* the shell's
    /// `C`, and `C` is indeed what makes the run an action — it is where
    /// the block opens and where the command text is captured. But the
    /// entry this carries has the exit code and the duration, and neither
    /// exists until `D`. One dispatch carrying every field beats two
    /// carrying half each, so this fires from `completedRuns()`, which
    /// only yields a sealed block.
    ///
    /// **A block still open at teardown is journalled with a null exit
    /// code, never dropped.** `TerminalStore.performTeardown` seals
    /// whatever block was open when the shell died and publishes it like
    /// any other, so `completedRuns()` yields a `TerminalRun` for it too —
    /// with `exitCode: nil`, because the shell never got to report one.
    /// That is exactly what reaches this method and is journalled below:
    /// `exitCode`/`durationMs` fall back to `.null` rather than being
    /// left out of `params` entirely, so a reader of the journal sees
    /// that the field was asked about and came back unknown, not that it
    /// was never asked at all. Nothing here special-cases teardown; the
    /// null just flows through.
    ///
    /// **`origin: .ui`, always.** It was the operator: the agent cannot
    /// reach `term_run` — it is the seventh member of `operatorOnlyActions`
    /// (`MCP/PermissionPrompt.swift`), landed on this branch, and nothing
    /// here routes an agent's own `term_open`/`term_propose` call through
    /// this method either way — and a command the agent proposed was still
    /// submitted by a human hand. `accepted` is what records that
    /// distinction — `"proposed"` or `"typed"` — never `origin`.
    ///
    /// **All seven of the issue's named fields, and where each comes
    /// from.** The spec lists *"the command, the cwd, the active
    /// (organisation, project, environment), the origin, the exit code,
    /// the duration, and whether the command was proposed by the agent and
    /// accepted or typed by the operator."* `origin` and `environment` are
    /// `JournalEntry`'s own columns and are supplied by `dispatch`; the
    /// rest are `params` below. `org` and `project` were recorded nowhere
    /// at all until the two-axis review's Spec 3 — `term_open` already read
    /// both from the window's `activeShellContext`, and the journal, which
    /// is the only place a run survives, did not. They are read from the
    /// same one-hop property for the same reason `term_open` does: three
    /// separate reads of this `@MainActor` model could interleave with an
    /// organisation switch and pair one org's name with another's project.
    /// An empty member is journalled as the empty string rather than
    /// omitted — the journal's readers are diffing entries, and a missing
    /// key and a known-empty one are different facts.
    ///
    /// **Never the output.** `TerminalRun` does not carry it at all
    /// (`TerminalStore.swift`'s own doc comment on that type says why),
    /// so there is nothing here to omit by hand — the journal cannot
    /// become where a `keychain` grep's secrets accumulate because the
    /// type reaching this method never held them.
    ///
    /// **Under the shell's own place** (background agents 3 of 4): a shell keeps running in the
    /// place it was opened in while the screen goes elsewhere, so a run is journalled with that
    /// place — the screen's only for a shell with no scope of its own.
    private func journalTerminalRun(_ run: TerminalRun) async {
        let screen = activeShellContext
        let home = run.scope.flatMap { $0.organization.isEmpty ? nil : $0 }
        let context = home.map {
            (org: $0.organization, project: $0.project, environment: $0.environment)
        } ?? (org: screen.org, project: screen.project, environment: screen.environment)
        let params: JSONValue = .object([
            "pane": .string(run.paneId),
            "command": .string(run.command),
            "cwd": .string(run.cwd),
            "org": .string(context.org),
            "project": .string(context.project),
            "accepted": .string(run.wasProposed ? "proposed" : "typed"),
            "exitCode": run.exitCode.map { JSONValue.number(Double($0)) } ?? .null,
            "durationMs": run.durationMs.map { JSONValue.number(Double($0)) } ?? .null,
        ])
        // Best effort, like `session_record_parent`'s dispatch above: the
        // shell has already run the command, so a journal write that
        // fails costs the record, not the run. `term_run`'s handler does
        // no work of its own — `dispatch` writing the entry IS the work
        // — so there is nothing to retry here even if this did throw.
        _ = try? await registry.dispatch(
            name: "term_run", params: params, origin: .ui,
            caller: DispatchCaller(
                place: Place(organization: context.org, project: context.project,
                             environment: context.environment),
                session: nil),
            confirmation: nil)
    }

    /// The operator's `⏎` on a proposal.
    ///
    /// **Not an action, and that is consistent rather than convenient.**
    /// Keystrokes into the prompt are text-field editing, not actions —
    /// the precedent is the DB pane, which has no action for typing in
    /// the query editor. This writes the same bytes a hand would,
    /// **without a newline**, so the command sits in the operator's own
    /// prompt unrun; from that instant injected bytes are indistinguishable
    /// from typed ones, and it is theirs in every sense. The run that
    /// follows is the action, and `markNextRunProposed` is what records
    /// that this command was proposed rather than typed, so `term_run`'s
    /// eventual `accepted` field can say so.
    ///
    /// **The proposed block is cleared right after writing**, before the
    /// pty has had time to echo anything back — or the operator would see
    /// the same command twice: once as the dashed proposal, once as the
    /// live prompt it just filled.
    ///
    /// Does nothing if `pane` has no pending proposal.
    public func acceptProposal(pane: String) async {
        guard let proposal = await panes.terminalProposal(paneId: pane) else { return }
        await terminals.markNextRunProposed(paneId: pane, command: proposal.command)
        await terminals.write(paneId: pane, bytes: Array(proposal.command.utf8))
        await panes.setTerminalProposal(paneId: pane, nil)
    }

    /// `⌫`. The proposal is discarded and nothing is written to the
    /// shell. Does nothing if `pane` has no pending proposal.
    public func discardProposal(pane: String) async {
        await panes.setTerminalProposal(paneId: pane, nil)
    }

    /// Every keystroke the pane receives, straight to the pty and
    /// otherwise untouched — no newline appended, no escape sequence
    /// substituted. This is what makes `^C` reach the foreground process
    /// group: the byte the operator's hand produced is the byte the shell
    /// gets, and that only works **because** the shell was spawned with
    /// `forkpty` (`TerminalSession.spawn`'s own doc comment). Task 16's
    /// drawing code is the one caller — there is no action for this, for
    /// the same reason `acceptProposal`'s doc comment gives for typing:
    /// a keystroke is text-field editing, not something Invariant 2 has
    /// an opinion about.
    public func sendToTerminal(pane: String, bytes: [UInt8]) async {
        await terminals.write(paneId: pane, bytes: bytes)
    }

    /// A pane resize, straight to the pty: sets `TIOCSWINSZ` and signals
    /// the foreground process. The COLUMN/ROW arithmetic — the pane's
    /// pixel size divided by the monospaced font's own cell metrics — is
    /// the view's to measure and belongs there (Task 16's own rule is the
    /// other way only for a calculation *worth asserting*, and a
    /// `GeometryReader` frame is not a value `WakilKitTests` could ever
    /// see); this method is the one line of the resize that has to reach
    /// past `WakilApp`'s own module boundary.
    public func resizeTerminal(pane: String, cols: Int, rows: Int) async {
        await terminals.resize(paneId: pane, cols: cols, rows: rows)
    }

    /// Re-reads ONE pane's terminal contents out of `PaneStore` — the
    /// "poll ... at the display's frame rate" half of the probe's redraw
    /// rule (§4.2/§4.3): `TerminalStore`'s own 60 Hz loop is what decides
    /// WHEN the screen changed (the dirty range, taken and cleared every
    /// pass), and this is what carries that decision from `PaneStore` into
    /// the pane's own cell (`paneCells`), where the view actually reads it.
    ///
    /// **Deliberately not `refreshPanes()`,** which a naive polling loop
    /// would have reached for instead. `refreshPanes()` re-reads the
    /// WHOLE layout — every pane, every kind, an actor hop into `layout`
    /// plus one into `panes` per pane — and reassigns `tables`,
    /// `editables` AND every pane's cell unconditionally on every call,
    /// which under `@Observable` invalidates every open pane's view on
    /// every tick, DB panes included, for a change that happened in one
    /// terminal. At the display's frame rate that is the 240.5 ms/frame
    /// mistake one level up: paying for the whole canvas's redraw to
    /// answer a question about one pane. This reads only `panes`, for the
    /// one pane id the caller already knows is a terminal — `kind:
    /// "terminal"` is hardcoded rather than looked up, because a caller
    /// that already holds a `TerminalSnapshot` to redraw already knows
    /// what kind its own pane is.
    public func refreshTerminal(pane: String) async {
        let snapshot = await panes.snapshot(paneId: pane, kind: "terminal")
        guard snapshot.terminal != nil else { return }
        setCell(pane, snapshot)
    }

    /// TEST-ONLY: dispatches `term_open` at `path`, naming no pane, and
    /// returns the id it opened, or `""` on failure. Drives the REAL
    /// action through `registry.dispatch` — the same path a real
    /// `term_open` call takes — rather than calling `terminals.open`
    /// directly, so a test exercising `terminalRunPump` sees the shipped
    /// wiring, not a shortcut around it.
    ///
    /// **Backfills the mirror itself, deterministically** (Task 15),
    /// rather than leaving it to `observationPump`'s own `term_open`
    /// branch: this call does not go through `registry.dispatch` from
    /// inside a detached pump, so there is no separate task for a caller
    /// to race, and a test asserting on the returned pane's blocks right
    /// after this returns needs no poll. The production, agent-issued
    /// path — which never calls this method — still relies on
    /// `observationPump`'s branch, the same as `ctx_set_environment` does
    /// for the agent's own environment switch.
    func openTerminalForTesting(path: String) async -> String {
        guard let result = try? await registry.dispatch(
            name: "term_open", params: .object(["path": .string(path)]),
            origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil),
            case .object(let fields) = result, case .string(let pane)? = fields["pane"]
        else { return "" }
        await currentAgent?.mirror.backfill(into: nil)
        return pane
    }

    /// TEST-ONLY: writes `text`'s bytes straight to `pane`'s pty — what
    /// the operator's own keystrokes do. There is no action for this
    /// (see `acceptProposal`'s own doc comment on why typing is not one),
    /// so there is nothing to dispatch through; a real `\n` at the end
    /// runs the command, the same as it would under a real hand.
    ///
    /// **Delegates to `sendToTerminal` (Task 16)** rather than calling
    /// `terminals.write` a second time, so a test exercises the exact
    /// method the pane's own keystroke handler calls.
    func sendToTerminalForTesting(pane: String, text: String) async {
        await sendToTerminal(pane: pane, bytes: Array(text.utf8))
    }

    /// TEST-ONLY: every `term_run` entry this model's registry has
    /// journalled so far, in the order they were written.
    func journalledRuns() async -> [JournalEntry] {
        ((try? await registry.journalEntries()) ?? []).filter { $0.action == "term_run" }
    }

    /// TEST-ONLY: dispatches `term_propose` for `pane`, as the agent
    /// would — the only origin that can actually reach this action.
    /// Drives the real action through `registry.dispatch` rather than
    /// calling `panes.setTerminalProposal` directly, for the same reason
    /// `openTerminalForTesting` does: a test exercising `acceptProposal`/
    /// `discardProposal` needs the shipped path underneath, not a
    /// shortcut that happens to leave the same value in the store.
    func proposeForTesting(pane: String, command: String) async {
        _ = try? await registry.dispatch(
            name: "term_propose",
            params: .object(["pane": .string(pane), "command": .string(command)]),
            origin: .agent, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
    }

    /// TEST-ONLY: `pane`'s pending proposal, or `nil`.
    func terminalProposalForTesting(pane: String) async -> TerminalBlock? {
        await panes.terminalProposal(paneId: pane)
    }

    /// TEST-ONLY: `pane`'s recorded (run) blocks — empty means nothing
    /// has run in it yet, proposal or not: a proposal is never stored
    /// among these (`PaneStore.TerminalContents.proposal` is a separate
    /// field, folded in only at `snapshot()` time).
    func terminalBlocksForTesting(pane: String) async -> [TerminalBlock] {
        await panes.terminalBlocks(paneId: pane)
    }

    /// TEST-ONLY: whether `pane`'s live screen currently contains
    /// `needle` — what proves accepted bytes actually reached the
    /// shell's own prompt line, unrun.
    func screenContainsForTesting(pane: String, _ needle: String) async -> Bool {
        await terminals.screenContains(pane, needle)
    }

    /// Ends the agent session. The window calls this on termination,
    /// alongside `WakilWiring.shutdown()`; without it the `claude` child
    /// outlives the window.
    public func shutdown() async {
        socketsClosed = true
        stopBackgroundFetch()
        for agent in conversations.values { agent.eventPump?.cancel() }
        confirmationPump?.cancel()
        observationPump?.cancel()
        flightPump?.cancel()
        editorFlightPump?.cancel()
        editorFilesPump?.cancel()
        resumePump?.cancel()
        providerSwitchPump?.cancel()
        conversationPump?.cancel()
        terminalRunPump?.cancel()
        // Every place's agent, and the socket each reached Wakil on: one left running would
        // outlive the window.
        for agent in Array(conversations.values) { await stopSession(of: agent) }
        // And every place's socket no session took.
        let shown = shownSockets.values
        shownSockets = [:]
        for socket in shown { await socket.opening.value.socket?.stop() }
        // And every approval still waiting, the operator's among them: each parked request
        // returns rather than waiting on a window that is gone.
        await confirmations.cancelAll()
        // No shell outlives the window. Without this line `terminals` was
        // the one live-resource store `shutdown()` forgot — every pump
        // above is cancelled, but a cancelled pump does not kill a child
        // process, and neither does dropping this model. The run stream
        // ends with the window.
        await terminals.shutdownAll()
        // And the quick models: a warm `claude` session is a child process too.
        await shutDownQuickTasks()
    }
}

// MARK: - Unsaved edits (3b-i Task 9)

/// What asked before unsaved editor tabs would be lost.
public enum UnsavedIntent: Sendable, Equatable {
    /// One tab, named by its subject rather than its position, which can move while it waits.
    case closeTab(pane: String, subject: EditorTabSubject)
    case closePane(pane: String)
    case quit
}

/// The Save / Don't Save / Cancel prompt: what asked, and the titles of the tabs it would lose.
public struct UnsavedPrompt: Sendable, Equatable {
    public var intent: UnsavedIntent
    public var files: [String]
    /// False when Save could write none of `files` from here — scratch tabs or other projects'
    /// files in scopes not on screen (final review I3). The prompt then offers Don't Save and
    /// Cancel only; it never jumps to their scope (Rule 6).
    public var canSave: Bool
    public init(intent: UnsavedIntent, files: [String], canSave: Bool = true) {
        self.intent = intent
        self.files = files
        self.canSave = canSave
    }
}

public enum UnsavedChoice: Sendable { case save, dontSave, cancel }

/// Close Conversation's one question (conversations 3 of 3), asked when the conversation has its
/// turn running or a write waiting — one sentence for both (plan 3, ruling 3). **Close it** ends
/// it, cancelling the write; **Keep it** leaves it as it was.
public struct CloseConversationQuestion: Sendable, Equatable {
    /// The conversation it asks about, by id: the one the close named when it was asked.
    public let conversation: String
    public static let text = "Close this conversation? The agent is still working; what it is doing now stops."
    public static let closeLabel = "Close it"
    public static let keepLabel = "Keep it"
    public init(conversation: String) { self.conversation = conversation }
}

/// The operator's reveal asking a pane's tree to select and scroll to a file's row (`WindowModel.editorTreeRevealRequest`).
public struct EditorTreeRevealRequest: Sendable, Equatable {
    public var pane: String
    public var path: String
    /// Bumps per request, so the same file revealed twice is two requests.
    public var serial: Int
    public init(pane: String, path: String, serial: Int) {
        self.pane = pane
        self.path = path
        self.serial = serial
    }
}

/// ⌘B / ⌘⇧F asking a pane's column for the keyboard (`WindowModel.editorColumnFocusRequest`).
public struct EditorColumnFocusRequest: Sendable, Equatable {
    public var pane: String
    public var view: EditorColumnView
    /// Bumps per request, so the same view asked for twice is two requests.
    public var serial: Int
    public init(pane: String, view: EditorColumnView, serial: Int) {
        self.pane = pane
        self.view = view
        self.serial = serial
    }
}

/// The pin's predicate, pure so it is testable without a harness: the first live agent whose
/// place is in `organization` and `project`, and in `environment` when one is given. Another
/// organisation's project of the same name never matches — the actions act on the current org.
func runningAgentName(
    among agents: [(place: Place, live: Bool, providerId: String)],
    organization: String, project: String, environment: String?
) -> String? {
    for agent in agents where agent.live && agent.place.organization == organization
        && agent.place.project == project
        && (environment == nil || agent.place.environment == environment) {
        return "agent (\(agent.providerId))"
    }
    return nil
}
