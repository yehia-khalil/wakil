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
    public private(set) var project = ""
    public private(set) var environment = ""
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
    public var activeShellContext: (org: String, project: String, environment: String, rootPath: String) {
        (org: organization, project: project, environment: environment, rootPath: rootPath)
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
    public private(set) var thoughts: [ThoughtRow] = []
    /// Monotonic row ids. **Not `thoughts.count`**, which was correct while
    /// every event produced a row and repeats an id the moment one does not —
    /// `ThoughtRow` is `Identifiable`, so a repeated id makes SwiftUI draw one
    /// row twice and omit another.
    private var nextThoughtId = 0
    /// The agent's own `Bash` `toolUse`/`toolResult` events, retained so a
    /// terminal pane opened after the fact can be backfilled — the record
    /// predates the pane, and `mirroredBlocks(from:cap:)` is pure, so it
    /// needs its own copy of the events rather than replaying `thoughts`
    /// (already projected down to display text) or the harness's own
    /// stream (already drained and gone). Task 15.
    ///
    /// **Each event is paired with the `Date()` `append(_:)` observed it
    /// at (fix round 1, Critical).** The first cut kept plain
    /// `[HarnessEvent]` and let `mirroredBlocks` synthesise an
    /// index-derived `startedAt`, which sorted every mirrored block ahead
    /// of every real operator block, unconditionally — see
    /// `MirrorEvent`'s own doc comment. Arrival time is captured exactly
    /// once, here, at the one place the event actually arrives, and
    /// carried through rather than recomputed.
    ///
    /// **Org-derived, not org-independent.** These are the agent's own
    /// commands in THIS organisation's session — the same boundary
    /// `thoughts` and `harness` already sit behind — so
    /// `invalidateForOrgChange()` clears this alongside them. Left set, a
    /// terminal pane opened fresh in a new organisation would backfill
    /// with the outgoing org's commands.
    ///
    /// **Capped at `TerminalBlock.historyCap * 2` events, not blocks.**
    /// One mirrored block is two events (`toolUse` then `toolResult`), and
    /// the cap must survive a long run of still-running calls whose result
    /// has not arrived yet without prematurely evicting blocks
    /// `mirroredBlocks` would otherwise still be able to pair.
    private let mirror: TerminalMirrorFeed
    /// Provider capacity — see `CapacityFeed`.
    public let capacity: CapacityFeed
    /// Whether a turn is in flight: true from a successful `send`, false on
    /// the `.result` event that ends it. The Core reads it through
    /// `coreState` and nothing else does.
    ///
    /// Set on the *successful* path only. A `send` that failed — no harness,
    /// which is the ordinary degraded launch — never started a turn, and a
    /// Core left thinking forever is worse than one that never started.
    public private(set) var turnInFlight = false
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
    /// The organisation a queued switch is waiting to move to, or `nil`.
    ///
    /// **Window state, not plane state** (spec §4.2): dismissing the org
    /// plane does not cancel it and the status line carries it. Only
    /// `cancelQueuedSwitch()` cancels it, and only the operator calls that.
    /// Org-derived (`InvalidationContractTests`): a queue naming a
    /// DESTINATION org is exactly the kind of state a fresh org must not
    /// inherit, even though every real path that clears `queuedOrgSwitch`
    /// already nils it before `invalidateForOrgChange()` ever runs —
    /// reset here anyway as defence in depth, the same reasoning `pending`'s
    /// own reset in that method gives for itself.
    public private(set) var queuedOrgSwitch: String?
    /// How many times `cancelQueuedSwitch()` has actually cancelled
    /// something. Monotonic, and org-independent (`InvalidationContractTests`)
    /// — it describes an event count, not either org's state.
    ///
    /// **Task 14, fix round 1 (Important 2).** Exists so the org plane can
    /// tell "the queue was cancelled" from "the queue is about to fire"
    /// without inferring it from the relative timing of two OTHER
    /// properties. `fireQueuedSwitchIfReady()` clears `queuedOrgSwitch`
    /// synchronously and only sets `switching = true` later, after a
    /// further `await confirmations.current()` suspension inside
    /// `setOrganization` — so a view watching "`queuedOrgSwitch` went
    /// `nil` while `switching` is still `false`" cannot distinguish a
    /// genuine cancel from a fire that simply has not reached `switching
    /// = true` yet. Observed against SwiftUI's own change delivery, that
    /// ambiguity silently dropped a switch's outcome: the plane inferred
    /// "cancelled", reset itself to Choosing, and then never noticed
    /// `switching` flip true→false for the switch that was actually
    /// running — on failure, `organization` clears to `""` with nothing on
    /// screen saying why. This counter is bumped ONLY by an actual
    /// cancellation (never by a fire), so a view can watch it alone and
    /// never has to guess.
    public private(set) var queuedSwitchCancellationCount = 0
    /// True from the moment `fireQueuedSwitchIfReady()` begins until it
    /// returns, guarding the whole method against a second, concurrent
    /// invocation. Two call sites can land back-to-back on the same
    /// suspension point inside that method's own `await
    /// confirmations.current()` — see its doc comment — and without this
    /// flag both would observe `queuedOrgSwitch` still non-nil and both
    /// call `setOrganization`, firing one queued request twice.
    /// Org-independent: like `switching`, it describes the firing
    /// transition itself, not either org's state.
    private var firingQueuedSwitch = false
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

    /// The mutation currently waiting for this operator, or `nil`. The
    /// confirmation plane renders from this. Mirrored from `confirmations`
    /// by `confirmationPump`, started in `init` — not lazily, unlike
    /// `eventPump`, because a mutation can park before the operator ever
    /// sends anything to the agent.
    public private(set) var pending: PendingMutation?

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

    private let registry: ActionRegistry
    /// 2d-i: the names in scope this window's turns resolve against. Nil
    /// means no hint is ever added; production always passes
    /// `wiring.vocabulary` (`WindowSession.start`).
    private let vocabulary: VocabularyStore?
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
    private let context: ContextStore?
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
    /// **The org is a parameter as of 2b-viii, for the same reason the
    /// provider became one in 2b-vi**: the config JSON this closure builds
    /// carries `WAKIL_ORG` to every MCP server the agent talks to, so a
    /// factory that captured the launch org would run a post-switch
    /// session's servers under the org the window was opened with.
    private let harnessFactory: @Sendable (String, ProviderSelection) -> AgentHarness?
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
    private var harness: AgentHarness?
    private let resumes: ResumeBroker
    private var resumePump: Task<Void, Never>?
    /// Where a `session_set_provider` request parks — the identical
    /// broker-and-pump shape `resumes`/`resumePump` use, for the same
    /// structural reason: `registerStandardActions` registers the
    /// dispatchable action before any `WindowModel` exists, so it cannot
    /// close over `self`. See `ProviderSwitchBroker`'s own doc comment.
    private let providerSwitches: ProviderSwitchBroker
    private var providerSwitchPump: Task<Void, Never>?
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
    private let gitStatus: GitStatus?
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
    /// Every scope whose saved layout has already been read this session.
    /// Separate from `layoutScope` because they answer different
    /// questions: that one is "which arrangement is on screen", this one
    /// is "which have been read from disk", and only the second may never
    /// be re-answered. See `activateLayout`.
    private var loadedLayoutScopes: Set<LayoutScope> = []
    /// True from the moment `activateLayout` points the stores at the
    /// incoming scope until the arrangement that belongs to it is in hand.
    ///
    /// **It describes the swap, not either side of it**, which is why
    /// `invalidateForOrgChange()` never touches it — the same shape
    /// `switching` and `firingQueuedSwitch` already have. An organisation
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
    /// The id the current agent session was started under, or `nil` before
    /// the first `send`. Per spec §3.3 a session starts fresh and keeps one
    /// id; the second and later `send` calls reuse it rather than starting
    /// another session.
    ///
    /// `private(set)`, not `private` — as of Task 9, `ProviderSwitchTests`
    /// reads this directly (`model.sessionId`) to pin that a provider
    /// switch mints a fresh id rather than forking, the same reason
    /// `providerId` just below is already `private(set)` rather than
    /// `private`.
    private(set) var sessionId: String?
    private var eventPump: Task<Void, Never>?
    /// Bumped by `resume`, immediately before it stops the harness it is
    /// leaving. `startEventPump` captures the value in effect when a pump
    /// starts; the pump's loop compares its captured value against this on
    /// every event and drops the event if they no longer match. See
    /// `resume`'s doc comment (Finding 1, acceptance review 2026-09-10) for
    /// why this exists rather than relying on `Task.cancel()` alone.
    private var eventPumpGeneration = 0

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
        harnessFactory: @escaping @Sendable (String, ProviderSelection) -> AgentHarness?,
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
        environment: String
    ) {
        self.registry = registry
        self.paletteClients = paletteClients
        self.vocabulary = vocabulary
        self.panes = panes
        self.layout = layout
        self.mirror = TerminalMirrorFeed(panes: panes, layout: layout)
        self.capacity = CapacityFeed()
        self.terminals = terminals
        self.persistence = persistence
        self.context = context
        self.harnessFactory = harnessFactory
        self.resumes = resumes
        self.providerSwitches = providerSwitches
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
            // stale non-nil `pending` would never be told to clear it.
            // Safe unforced here even though `self` is weak: this task is
            // created from inside `self`'s own `init`, so `self` cannot
            // have deallocated yet.
            self?.pending = nil
            for await parked in await confirmations.updates() {
                // Re-checked on every iteration, like `eventPump` below —
                // `updates()` never terminates on its own, so hoisting a
                // `guard let self` above this loop (checked once) would
                // keep `self` strong for the model's entire lifetime, and
                // the model → task → model cycle would break only by hand,
                // in `shutdown()`.
                guard let self else { return }
                self.pending = parked
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
                // **Final review, Critical 2.** `ctx_set_environment` has
                // exactly one caller on the operator's side —
                // `setEnvironment`, the UI chooser — which follows it with
                // `refreshContext()` and `restorePaneContents()` by hand.
                // The agent's own `ctx_set_environment` never goes through
                // `setEnvironment` at all — it lands here, like any other
                // dispatch this pump did not make — so without this branch
                // every open pane kept the environment just left showing on
                // screen, the banner kept naming it, and `environment`
                // itself (what `environmentProvider` feeds `writeGate` for
                // the agent's own next dispatch) stayed stale: a switch
                // into production judged by the environment just left,
                // gating a mutation policy says must be blocked outright.
                // This makes the agent's path do exactly what
                // `setEnvironment` does for the operator's.
                //
                // **`ctx_set_project` gets a branch of its own below, and
                // #182 is why the gap became material.** A project switch
                // replaces the whole set of environments, and the
                // operator's `setProject` refreshes by hand — but the
                // agent's never did, so the window kept the outgoing
                // project's name and environment. Those were at least
                // stale TOGETHER. Decision 26's production flags are not:
                // `targetEnvironment` reaches `writeGate` fresh from the
                // caller's params while the declarations stayed the old
                // project's, so an agent that switched project and then
                // entered an environment the NEW project declares
                // production was judged against flags that never
                // mentioned it — the name rule again, silently, for the
                // one case the flag exists to cover. D10's own comment
                // says entering production must cost a gate.
                if name == "ctx_set_environment" {
                    // Fix round 1, item 5: the operator's own switch is seen here too, and
                    // `setEnvironment` is already handling it. Wait for it to finish, THEN
                    // compare: the operator's switch reads as a no-op and is not done twice
                    // (whose late clear wiped a reply already received under the new
                    // environment), while an agent's switch that landed meanwhile still shows.
                    _ = await self.operatorEnvironmentSwitch?.value
                    let before = self.environment
                    await self.refreshContext()
                    // W12: a switch to the active environment changes nothing on screen.
                    if !environmentSwitchIsNoOp(from: before, to: self.environment) {
                        // The agent's switch now does what the operator's does, replies included.
                        await self.panes.clearApiResponses(to: self.environment)
                        await self.restorePaneContents()
                    }
                }
                // **`ctx_set_project` refreshes and does NOT restore**, which
                // is exactly what the operator's `setProject` does — it calls
                // `refreshContext()` alone, where `setEnvironment` calls both.
                // The branch above exists to make the agent's path do what the
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
                    await self.mirror.backfill()
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
                if !self.sessionStarted, !self.layoutSnapshot.panes.isEmpty {
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
                await self.resume(sessionId: request.sessionId)
                // Fix round 2, Finding 1. This call site — NOT
                // `resume(sessionId:)`'s own body — is where a queued
                // switch is fired for THIS caller specifically: an
                // agent-initiated `session_resume` (or `--dispatch`) is
                // never nested inside `setOrganization`, unlike
                // `autoResumeAfterSwitch()`'s own call to `resume`, and
                // `resume`'s teardown sets `turnInFlight = false` with no
                // `.result` ever coming afterwards for that turn. See
                // `fireQueuedSwitchIfReady()`'s own doc comment for why
                // this cannot live inside `resume(sessionId:)` instead.
                await self.fireQueuedSwitchIfReady()
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
                                                    environment: self.environment, confirmation: nil)
        }
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
            harnessFactory: { _, selection in harnessFactory(selection) },
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
        harnessFactory: @escaping @Sendable (String, ProviderSelection) -> AgentHarness?,
        resumes: ResumeBroker,
        rootPath: String,
        providerId: String,
        lookupFactory: @escaping @Sendable (String) -> ProviderCredentialsLookup,
        confirmations: ConfirmationBroker = ConfirmationBroker(),
        providerSwitches: ProviderSwitchBroker = ProviderSwitchBroker(),
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
        paletteClients: PaletteClients
    ) {
        self.init(
            registry: registry, panes: panes, layout: layout, persistence: persistence,
            context: context, harnessFactory: harnessFactory,
            resumes: resumes, rootPath: rootPath, providerId: providerId,
            lookupFactory: lookupFactory, confirmations: confirmations,
            terminals: terminals, providerSwitches: providerSwitches,
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
        harnessFactory: @escaping @Sendable (String, ProviderSelection) -> AgentHarness? = { _, _ in nil },
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
        // test that needs to arm `armHoldNextCurrentForTesting()` on the
        // SAME broker instance the model actually calls (T11 fix round 2)
        // passes its own instance here and keeps a reference to it.
        confirmations: ConfirmationBroker = ConfirmationBroker(),
        // 2d-i. Nil by default, as in production's initialiser.
        vocabulary: VocabularyStore? = nil
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
            context: context,
            harnessFactory: harnessFactory,
            resumes: ResumeBroker(),
            rootPath: rootPath,
            providerId: providerId,
            lookupFactory: resolvedLookupFactory,
            confirmations: confirmations,
            orgSwitcher: orgSwitcher,
            terminals: terminals,
            vocabulary: vocabulary,
            rootWatcher: nil,
            editorRootWatcher: nil,
            fileLists: nil,
            gitStatus: nil,
            paletteClients: PaletteClients())
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
    func startHarnessForTesting() async -> AgentHarness? {
        await startHarness()
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
        for i in 0..<thoughts {
            self.thoughts.append(
                ThoughtRow(id: nextThoughtId, label: "test", detail: "seed \(i)", isError: false))
            nextThoughtId += 1
        }
        self.databaseChoices = databaseChoices
        self.pending = pending
        self.databases = databases
        self.databaseDrivers = databaseDrivers
        self.layoutSnapshot = layoutSnapshot
        self.project = project
        self.environment = environment
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
            + "headlessly with `--dispatch ctx_set_provider` (phase-2b-vi-acceptance.md §1.4)"
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
            environment = active.environment
            // **The one writer of the gate's view of production**
            // (Decision 26, #182). `get_context` carried the whole project
            // already, so the flags cost nothing extra — and they are set
            // HERE, on the only call that can change the active project,
            // so the gate and the room can never be reading a previous
            // project's declarations.
            environmentProduction = active.environmentProduction
            await registry.setEnvironmentProduction(active.environmentProduction)
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

    /// Clears every piece of state that belongs to the organisation being
    /// left. **The teardown contract 2c-iii inherits** (spec §5).
    ///
    /// **Adding org-scoped state to this type means adding it here.**
    /// `InvalidationContractTests` fails on any stored property that is
    /// classified as neither org-derived nor org-independent, so a new
    /// pane's state cannot be added without its author being told to make
    /// the call. That test proves CLASSIFICATION, not behaviour — the
    /// resets themselves are covered by the acceptance runbook's checks 3,
    /// 4 and 14.
    ///
    /// Called from `setOrganization` BEFORE the clients restart, so no
    /// handler can write the outgoing org's data into a store while the
    /// new org's server is coming up.
    ///
    /// **`async`, and both store clears are awaited.** `layout` and
    /// `panes` are actors; firing their clears from inside a detached
    /// `Task` would let this method return — and a test's very next
    /// assertion run — before either clear has actually happened, racing
    /// the thing it exists to pin down. Awaiting both here is what makes
    /// "call this, then look" a safe sequence for every caller, tests
    /// included.
    func invalidateForOrgChange() async {
        // Invariant 4 for names: nothing of the old org resolves after this line.
        await vocabulary?.dropAll()
        // Context. `organization` is deliberately NOT cleared here: the
        // caller assigns it from the id it switched to, which is more
        // authoritative than anything get_context will say (spec §6).
        project = ""
        environment = ""
        // Org-derived, and a credential boundary rather than a display
        // detail: the declarations describe the OUTGOING org's project.
        // Left standing until the first context read of the new org, the
        // gate would price the incoming environments by the outgoing
        // org's flags — and a stale `production: false` is a production
        // mutation priced as staging. Invariant 4 (#182). The registry's
        // copy is cleared with it, because the gate reads that one.
        environmentProduction = .undeclared
        await registry.setEnvironmentProduction(.undeclared)
        // **The session ends with the org, so the window is sessionless
        // again.** An org switch closes every pane, respawns the servers a
        // session carries, and crosses a credential boundary — there is no
        // sense in which the work continues. Returning to an org auto-resumes
        // its most recent session (open question 5, amended 2026-09-15), and
        // `resume` sets this again when that fires; an org with nothing to
        // resume correctly lands on the Landing instead. Leaving it set would
        // put the operator in the new org with no panes, no thread and no way
        // to reach either.
        sessionStarted = false
        assignedSessionId = nil
        lineageRoot = nil
        // 3b-i: the editor's save state names the outgoing org's panes, whose ids the next org
        // reuses. A save in flight is abandoned (its buffer goes with the pane), a pending
        // saved-tabs write would land the old tabs on a new pane, and a path field would open
        // on one.
        editorSaves.values.forEach { $0.cancel() }
        editorSaves = [:]
        editorTabsWrites.values.forEach { $0.cancel() }
        editorTabsWrites = [:]
        // Cancelled, not just dropped: a run waiting on a save, or between its checks, must not
        // write into the next org's panes (each run checks `Task.isCancelled` before dispatching).
        cancelAutosaveTimers()
        editorAutosaveRuns.values.forEach { $0.cancel() }
        editorAutosaveRuns = [:]
        editorAutosave.reset()
        editorSaveAsRequest = nil
        editorColumnFocusRequest = nil
        editorTreeRevealRequest = nil
        // The trees' listings are the outgoing project's roots; the list itself is emptied when
        // `syncEditorWatcher` below finds no roots and stops watching.
        editorFiles = .empty
        // The unsaved prompt names the outgoing org's panes, whose ids the next org reuses. A quit
        // it was holding is answered no, or AppKit would wait on it forever.
        if unsavedPrompt?.intent == .quit { quitCancelled += 1 }
        unsavedPrompt = nil
        unsavedSwitchApproved = nil

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

        // Panes and their contents.
        tables = [:]
        editables = [:]
        paneCells = [:]
        // The query line's per-pane state, all three parts: a refusal and
        // a restore both describe a pane in the OUTGOING org, and the
        // token is what orders restores within one window's life.
        queryLineRefusals = [:]
        queryLineRestores = [:]
        queryLineRestoreToken = 0
        // Keyed by pane id, which is sequential (`db-1`, `db-2`, …) and
        // reused by a fresh session in the NEW org. Left set, a pane in
        // org B would silently inherit org A's chosen database and
        // subject — a query line pointed at the previous credential
        // boundary's database, with nothing failing. The same shape as
        // the same-project-name collision this task exists to close, one
        // level down (fix round 1, Finding 1).
        databaseChoices = [:]
        layoutScope = nil
        loadedLayoutScopes = []
        // A cached projection `refreshContext`/`activateLayout` rebuild on
        // the common path, so "it gets refreshed anyway" would normally be
        // enough — except `refreshDatabases` explicitly PRESERVES a stale
        // list when its dispatch fails, which is exactly the path where a
        // switch has gone wrong. Reset here for the same reason `tables`
        // and `editables` are above (fix round 1, Finding 3).
        databases = []
        databaseDrivers = [:]

        // The agent.
        thoughts = []
        // The outgoing org's own `Bash` history — left set, a terminal
        // pane opened fresh in the new organisation would backfill with
        // commands that ran under the outgoing org's credentials (Task 15).
        mirror.reset()
        // The outgoing org's readings (CapacityFeedTests.resetForgetsReadingsAndFailure).
        capacity.reset()
        providerId = ""
        harness = nil
        sessionId = nil
        turnInFlight = false
        // TEST-ONLY, but still a record of which session
        // `autoResumeAfterSwitch()` last picked for the OUTGOING org — left
        // set, a test could read a stale org A session id as if it were
        // org B's just-made selection (Task 12).
        resumedParentForTesting = nil
        // The window's OWN mirror of the parked confirmation (set at
        // `confirmationPump`'s subscription, cleared there too) — not the
        // `confirmations` broker itself. The switch's guard 2 already
        // refuses to start while a mutation is parked, so in the normal
        // path this is already `nil`; cleared here anyway as defence in
        // depth, because a contract that relies on a SEPARATE check
        // staying correct is the kind of coupling this codebase has been
        // bitten by before (fix round 1, Finding 2). Left set, the
        // outgoing org's SQL statement would stay on the confirmation
        // plane after the switch — an operator asked to type `confirm`
        // for a mutation belonging to an org they have left.
        pending = nil
        // Every real path that clears this already sets it `nil` before
        // this method ever runs (`fireQueuedSwitchIfReady()` clears it
        // before calling `setOrganization`; `stopTurnAndSwitchNow()` does
        // the same). Reset here anyway, for the identical defence-in-depth
        // reason `pending` just above gives for itself — a queue naming a
        // destination org must not be able to survive under a fresh one.
        queuedOrgSwitch = nil
        // Same reasoning as `databases` just above: a cached projection
        // that self-heals on the common path, but not on every path, so
        // "it gets refreshed anyway" is not sufficient on its own (fix
        // round 1, Finding 3).
        layoutSnapshot = LayoutSnapshot()
        apiSendRequests = [:]
        apiSendRequestToken = 0
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

        // All three stores, wholesale. Awaited, not fired into a detached
        // `Task`: see this method's own doc comment. Pinned by
        // `invalidationClearsBothStoresAndNotJustTheModelsOwnProperties`
        // (`OrgSwitchTests`), which seeds both stores THROUGH this model
        // and asserts the projections come back empty — deleting either
        // line fails it on its own. Until that test existed, both lines
        // could be replaced with `_ = layout; _ = panes` with the whole
        // suite still passing (final fix pass, Important 2).
        //
        // **The third is not like the other two.** They clear
        // dictionaries; this one kills processes and closes file
        // descriptors, and it is the reason the tripwire needed a third
        // bucket (`orgDerivedBehindAReference`,
        // `InvalidationContractTests`). The switch is deliberately NOT
        // gated on a running shell — a `tail -f` the operator forgot about
        // dies silently, because making a shell a parked mutation would
        // let it block a switch indefinitely, which is the worse failure.
        await layout.clearAllScopes()
        await panes.cancelAllDBReads()   // stop the old org's reads on its database, not just forget them
        await panes.clearAllScopes()
        // **`.keepOpen`, and that word is the whole of final review's
        // Critical 1.** This window subscribes to `completedRuns()`
        // exactly once, in `init`; finishing the stream here — which is
        // what this call did when it was written for app quit and reused
        // here — ended `terminalRunPump`'s `for await` permanently, so
        // after ONE org switch no command run in any pane was ever
        // journalled again. The shells still die; only the stream
        // survives. See `TerminalRunStreamDisposition`.
        await terminals.shutdownAll(runStream: .keepOpen)
        // No pane and no root survive the switch, so nothing of the outgoing org's is
        // watched past it.
        await gitStatus?.reset()
        gitRoots = []
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
        // No project, no arrangement. `refreshContext`'s error branch
        // clears `project` deliberately — keeping the outgoing org's would
        // draw the wrong credential boundary confidently (spec §6) — and
        // then reaches here. **The scope is cleared with it**, not merely
        // left behind: `persistLayout` writes under `layoutScope`, so a
        // stale one would file the canvas under the very project that
        // branch just refused to keep showing.
        guard !project.isEmpty else {
            layoutScope = nil
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
        let scope = LayoutScope(
            organization: organization, project: project, lineageRoot: lineageRoot)
        // **Equal key means equal on all three fields** (#160): same
        // organisation, same project, same conversation. It did not until
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
            let uncommitted = await layout.snapshot()
            if uncommitted.withoutTransientState != layoutSnapshot.withoutTransientState {
                await persistLayout(uncommitted, for: outgoing)
            }
        }

        // Re-walk finding #4: a conversation minted over the conversation-less canvas takes it.
        let adopted = adoptingCanvas && outgoing.map {
            conversationAdoptsCanvas(from: $0, to: scope)
        } == true
        if adopted, let outgoing {
            await layout.switchScope(to: scope, adoptingFrom: outgoing)
            await panes.switchScope(to: scope, adoptingFrom: outgoing)
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
            // A read in flight on the panes left behind would land nowhere — its reply is dropped —
            // but it would keep running on the database. Stopped here (spec edge: a project switch
            // mid-read cancels it). Under adoption the panes move with it, so it still lands.
            await panes.cancelAllDBReads()
            await panes.switchScope(to: scope)
        }
        // The insert is last so that it only records a scope the read was
        // actually attempted for: marking one loaded while the org was
        // still unresolved would suppress the read that should follow.
        var loadedFromDisk = false
        if let persistence, !scope.organization.isEmpty, loadedLayoutScopes.insert(scope).inserted {
            let saved = persistence.load(for: scope)
            if let snapshot = saved.snapshot {
                await layout.load(snapshot, for: scope)
                loadedFromDisk = true
            }
            // Degradation is visible or it is nothing: an unreadable layout
            // opens an empty canvas *and* says so, in the same place a
            // refused dispatch says so.
            if let note = saved.note { status = note }
        }
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
        if loadedFromDisk { await restorePaneContents() }
        layoutActivating = false
        let waiters = layoutSwapWaiters
        layoutSwapWaiters = []
        for waiter in waiters { waiter.resume() }
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
        await refreshContext()
        // **Every api pane's reply describes the environment we just
        // left**, so it is cleared before anything is refetched — D11's
        // argument for this pane kind. The DRAFT is kept and nothing is
        // re-sent: a switch that re-sent would put an unattended request
        // on the wire in the new environment. A captured value dies here
        // too, by `restorePaneContents` below bumping every source pane's
        // generation (#137 ruling 2).
        await panes.clearApiResponses(to: environment)
        // D11. The panes on screen describe the environment we just left.
        // This is the relaunch path, and a switch must leave the canvas
        // exactly as reopening the app in the new environment would — the
        // same argument that refuses rows a place on disk, applied to a
        // change that guarantees they describe a different database. The
        // `if` above is a `guard`: a REFUSED switch must not refetch,
        // because the environment did not change.
        await restorePaneContents()
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
            environment: environment, confirmation: nil)
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
            environment: environment, confirmation: nil)) != nil
        else { return }
        await refreshLayout()
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
        await locateClaudeIfNeeded()
        do {
            let result = try await registry.dispatch(
                name: "ctx_config_tree", params: .object([:]), origin: .ui,
                environment: environment, confirmation: nil)
            guard let tree = decodeSettingsTree(fromResult: result) else {
                settingsFailure = "settings could not be read: the reply was not a configuration tree"
                return
            }
            settings = tree
            settingsFailure = nil

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
                    environment: environment, confirmation: nil))
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
                origin: .ui, environment: environment, confirmation: nil)
            await refreshSettings()
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
                  environment: environment, confirmation: nil),
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

    private func saveEditorSettings(action: String, params: JSONValue) async -> String? {
        var refusal: String?
        do {
            _ = try await registry.dispatch(
                name: action, params: params, origin: .ui, environment: environment, confirmation: nil)
        } catch {
            refusal = statusDescribingFailure(action, error)
        }
        await refreshSettings()
        await refreshEditorSettings()
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

        /// A stable fragment for this field's accessibility identifier —
        /// the case name, not the label, which is prose and may be
        /// reworded without meaning anything has moved.
        public var identifierFragment: String { rawValue }

        /// What the form labels it.
        public var label: String {
            switch self {
            case .displayName: return "Display name"
            case .jiraBase: return "Jira site"
            case .defaultProvider: return "Default provider"
            case .speechProvider: return "Speech"
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
                environment: environment, confirmation: nil)
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
            id: id, stored: stored, origin: .ui, environment: environment)
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
            origin: .ui, environment: environment, confirmation: nil)
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
                environment: self.environment, confirmation: nil)
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure("db_set_dsn", error)
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
                origin: .ui, environment: self.environment, confirmation: nil)
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure("db_remove_database", error)
        }
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
            origin: .ui, environment: environment, confirmation: nil),
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
        // (Interaction Rule 5) and the pane would keep the environment just left. Cancelled first.
        await panes.cancelAllDBReads()
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
        // Resolving the confirmation is one of the moments a switch that
        // was HELD (rather than cancelled) behind a parked mutation is
        // free to fire — see `fireQueuedSwitchIfReady()`'s doc comment.
        await fireQueuedSwitchIfReady()
    }

    /// What Cancel and ESC call. Cancelling is always the safe default.
    public func cancelPending() async {
        guard let parked = pending else { return }
        await confirmations.cancel(id: parked.id)
        // Same reasoning as `confirmPending` just above: cancelling the
        // parked mutation is exactly as much "nothing is in the way now"
        // as confirming it is.
        await fireQueuedSwitchIfReady()
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
                origin: .ui, environment: environment, confirmation: nil)
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
                origin: .ui, environment: environment, confirmation: nil))
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
                origin: .ui, environment: environment, confirmation: nil))
            status = ""
        } catch {
            outcome = .refused(String(describing: error))
        }
        await refreshPanes()
        return outcome
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
        let reading = await layout.reading()
        layoutSnapshot = reading.snapshot
        pruneApiSendRequests()
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
            && layoutScope == LayoutScope(
                organization: organization, project: project, lineageRoot: lineageRoot)
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
            && layoutScope == LayoutScope(
                organization: organization, project: project, lineageRoot: lineageRoot)
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
                origin: .ui, environment: environment, confirmation: nil)
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
                origin: .ui, environment: environment, confirmation: nil)
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
        let minting = lineageRoot == nil
        markSessionStarted()
        await activateLayout(adoptingCanvas: minting && lineageRoot != nil)
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
        return sessions.items
    }

    /// A Continue row: `session_resume` through the registry, origin `ui`, as ⌘P's session row
    /// runs it.
    public func continueSession(_ id: String) async {
        await dispatchLayout("session_resume", .object(["id": .string(id)]))
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
                                            environment: environment, confirmation: nil)
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
    /// What the operator already said a queued switch may drop (Don't Save on its prompt) while
    /// it waits for the turn to end: the organisation, and each dirty tab's text as it stood. The
    /// queue firing asks again only if something is dirty that is not in it, or has changed since.
    @ObservationIgnored private var unsavedSwitchApproved: UnsavedDropApproval?

    private struct UnsavedDropApproval {
        /// `scope` nil is the scope on screen.
        struct Tab: Hashable { let scope: LayoutScope?; let pane: String; let subject: EditorTabSubject }
        let org: String
        let texts: [Tab: String]
    }

    /// One dirty tab a quit or an organisation switch would lose, in any scope (final review I3).
    private struct UnsavedTab {
        /// nil: the scope on screen. Otherwise a project or conversation the window left, whose
        /// panes `PaneStore` keeps in memory.
        let scope: LayoutScope?
        let pane: String
        let subject: EditorTabSubject
        /// The tab's title, with where it is for a hidden scope: `confirm.go (billing)`.
        let title: String
        let text: String
        var key: UnsavedDropApproval.Tab { .init(scope: scope, pane: pane, subject: subject) }
    }

    /// Every dirty tab in every scope of the organisation: the one on screen in canvas order, then
    /// each hidden scope's (`PaneStore.editorDirtyTabsInHiddenScopes`). What a quit or an
    /// organisation switch would lose — a project or conversation switch keeps them, so they must
    /// be asked about here.
    private func everyUnsavedTab() async -> [UnsavedTab] {
        let visible = dirtyEditorTabs().map {
            UnsavedTab(scope: nil, pane: $0.pane, subject: $0.subject, title: $0.title, text: $0.text)
        }
        let hidden = await panes.editorDirtyTabsInHiddenScopes().map {
            UnsavedTab(scope: $0.scope, pane: $0.paneId, subject: $0.subject, title: "\($0.title) (\($0.place))",
                       text: $0.text)
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
            // The app stays, so a queued switch held behind this prompt may go now.
            if prompt.intent == .quit { quitCancelled += 1 }
            await fireQueuedSwitchIfReady()
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
        case .switchOrganisation(let org):
            var texts: [UnsavedDropApproval.Tab: String] = [:]
            for t in await everyUnsavedTab() { texts[t.key] = t.text }
            unsavedSwitchApproved = UnsavedDropApproval(org: org, texts: texts)
            await performOrganisationSwitch(org)
            if queuedOrgSwitch != org { unsavedSwitchApproved = nil }
        case .quit:
            quitApproved += 1
            await refreshLayout()
            await refreshPanes()
            return   // the app is quitting; a queued switch has nowhere to go
        }
        await refreshLayout()
        await refreshPanes()
        await fireQueuedSwitchIfReady()
    }

    private enum UnsavedSaveOutcome { case proceed, stop, reasked }

    /// Save's half of `resolveUnsaved`: `.proceed` when the intent may run. Don't Save has nothing
    /// to write. A scratch tab on screen is made active and opens its path field, and a failed save
    /// keeps everything (Rule 8: its error is in the tab); either answers `.stop`.
    ///
    /// A quit or an organisation switch then asks again, alone, about the dirty tabs of hidden
    /// scopes (final review I3), with Don't Save and Cancel only (`.reasked`): Save cannot reach
    /// them (`saveCanReach`), and the window never jumps to another scope to save them (Rule 6).
    private func saveForUnsaved(_ prompt: UnsavedPrompt, _ choice: UnsavedChoice) async -> UnsavedSaveOutcome {
        guard choice == .save else { return .proceed }
        let scope: String?
        switch prompt.intent {
        case .closeTab(let pane, _), .closePane(let pane): scope = pane
        case .switchOrganisation, .quit: scope = nil
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

    /// A switch about to fire from the queue would drop unsaved tabs the operator has not been
    /// asked about.
    private func switchNeedsAsking(_ org: String) async -> [UnsavedTab]? {
        let dirty = await everyUnsavedTab()
        guard !dirty.isEmpty else { return nil }
        if let approved = unsavedSwitchApproved, approved.org == org,
           dirty.allSatisfy({ approved.texts[$0.key] == $0.text }) {
            return nil
        }
        return dirty
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
    /// Autosaves running now, by id: each removes itself when it ends, an org change cancels
    /// them all, and a test can wait for them.
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
            // cancelled by an org change. Nothing suspends between these checks and the dispatch.
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
                                                     environment: environment, confirmation: nil)
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
    /// so an org change cancels them like any other autosave.
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
        let clean = (path as NSString).standardizingPath
        guard gitRootPaths.contains(where: { clean == $0 || clean.hasPrefix($0 + "/") }) else { return nil }
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
    private let paletteClients: PaletteClients

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
        return PaletteContext(
            focusedPane: focused.map { FocusedPane(id: $0.id, kind: $0.kind) },
            apiSendInFlight: sending != nil,
            // The DB pane's own ‹ › rules (`DBPane.pageControls`).
            dbPageHasNext: table.map { $0.pageable && $0.truncated } ?? false,
            dbPageHasPrevious: table.map { $0.pageable && $0.offset > 0 } ?? false,
            hasEnvironments: hasEnvironments, projectCount: projectCount, providerCount: providerCount,
            editorActiveIsFile: editorActiveIsFile, organisation: organisation, project: project)
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
    private func focusedEditorPane() -> String? {
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

    /// ⌘P's sources, in group order.
    private func paletteOpenSources(tables: TablesSource?) -> [any PaletteSource] {
        var sources: [any PaletteSource] = [
            OpenPanesSource(panes: { [weak self] in await self?.palettePaneSummaries() ?? [] }),
            NewPaneSource(),
        ]
        if let tables { sources.append(tables) }
        if let http = paletteClients.http {
            let environment = environment
            sources.append(ApiEntriesSource(http: http, environment: { environment }))
        }
        let changed = ChangedFilesSource(status: { [weak self] in await self?.paletteGitStatus() ?? [] })
        let fileSource: FilesSource? = paletteClients.files.map { files in
            FilesSource(files: files, roots: { [weak self] in await self?.gitRootPaths ?? [] },
                        showIgnored: { [weak self] in await self?.editorSettings.app.showIgnored ?? true })
        }
        // An editor in focus puts the project's files first: sources keep their own order within a group.
        let editorFocused = layoutSnapshot.panes.first { $0.id == layoutSnapshot.focusedId }?.kind == "editor"
        if let fileSource, editorFocused { sources.append(fileSource) }
        sources.append(changed)
        if let fileSource, !editorFocused { sources.append(fileSource) }
        sources.append(ItemsSource.projects(
            organisation: { [weak self] in await self?.organization ?? "" },
            read: { [weak self] org in await self?.currentOrganisationProjects(org) ?? ([], nil) }))
        sources.append(ItemsSource.sessions(read: { [weak self] in await self?.sessionPaletteItems() ?? ([], nil) }))
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
                environment: environment, confirmation: nil)
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
    private func statusDescribingFailure(_ name: String, _ error: Error) -> String {
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
            let result = try await registry.dispatch(
                name: name, params: params, origin: .ui,
                environment: environment, confirmation: nil)
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
                environment: environment, confirmation: nil)
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
    /// asking them to confirm nothing, and would occupy the single-flight
    /// broker for up to 120s while every unrelated agent proposal got
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
            origin: .ui)

        switch await confirmations.request(proposal) {
        case .approved:
            // `environment` is the property, read here rather than
            // captured before the park, so the gate judges the environment
            // as it stands at the moment the operator confirmed — a ⌘K
            // switch into production while the plane was up must block
            // this, not run it. `MCPServer.parkForConfirmation` re-reads
            // its provider at this same point, for this same reason.
            //
            // Bound to a local rather than read once per use: the `"error"`
            // and `"uncertain"` lines this path can write are read as a
            // pair, and a pair that disagreed about the environment would
            // be worse than one that named none. The binding is outside the
            // `do` so the `catch` can see it.
            let judged = environment
            do {
                let result = try await registry.dispatch(
                    name: name, params: params, origin: .ui,
                    environment: judged, confirmation: "confirm")
                status = ""
                return .ran(result)
            } catch {
                await recordUncertainMutation(
                    error, registry: registry, action: name, params: params, origin: .ui,
                    environment: judged)
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
    private func resolveCredentials(forProvider id: String, statusPrefix: String) async -> ProviderCredentials? {
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
    private func startHarness() async -> AgentHarness? {
        guard !providerId.isEmpty else {
            status = "no agent session: no provider is active for this window yet"
            return nil
        }
        guard let credentials = await resolveCredentials(forProvider: providerId, statusPrefix: "no agent session")
        else {
            return nil
        }
        guard let harness = harnessFactory(organization, ProviderSelection(id: providerId, credentials: credentials)) else {
            status = "no agent session: no agent available for provider \(providerId)"
            return nil
        }
        return harness
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
    /// queued switch, a missing harness or a failed send return false, and
    /// the composer gives the operator's draft back.
    @discardableResult
    public func send(_ text: String, via source: TurnSource = .typed) async -> Bool {
        // Before the guard below, deliberately: an operator who typed a turn
        // has started work whether or not a queued switch defers it, and
        // bouncing them back to the Landing would lose what they typed.
        //
        // The canvas comes with it, for the same reason `openPane` does: a
        // first turn mints the conversation, and the arrangement belongs to
        // the conversation rather than to the window that happened to be
        // open when it started.
        //
        // **Including when the guard below refuses the turn**, which looks
        // wrong and is not. `markSessionStarted` has already run by then,
        // so the window IS in a conversation; leaving the canvas keyed to
        // the one it left would mean `persistLayout` writing these panes
        // into another conversation's file. Nothing visible moves in any
        // case: a conversation minted this moment over the canvas on screen
        // ADOPTS that canvas, pane contents and drafts with it (re-walk #4),
        // rather than re-reading the project seed, which holds no drafts.
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
        if harness == nil, sessionId == nil {
            status = "starting the agent…"
        }
        await enterConversation()
        // A queued switch wins the next gap and cannot be starved.
        // `turnInFlight` is one flag with no "closing" state, so letting
        // the next turn start would make "fires when the turn completes" a
        // sentence with no bound on it (spec §4.2).
        if let queued = queuedOrgSwitch {
            status = "switching to \(queued) — cancel the switch, or wait for it"
            return false
        }
        if harness == nil, sessionId == nil {
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
            //
            // **Not `turnInFlight` raised earlier instead**, which is the
            // tidier-looking fix. That flag is what `requestOrganizationSwitch`
            // reads to decide whether to queue, and what `fireQueuedSwitchIfReady`
            // is owed by whoever lowers it — so raising it here would let a
            // switch queue against a turn that may return early, with no
            // `.result` ever coming to fire it. That is the starvation the
            // `catch` below exists to prevent, and widening the flag wants
            // its own change rather than a ride on this one.
            harness = await startHarness()
        }
        guard let harness else {
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
            if sessionId == nil {
                // `markSessionStarted()` above assigned this before anything
                // else in `send` ran, so the `??` is a belt-and-braces
                // fallback rather than a live path — and it mints rather than
                // refusing, because a turn that failed over a missing id
                // would be a worse outcome than a conversation whose first
                // pane was filed under a different one.
                let id = assignedSessionId ?? UUID().uuidString
                try await harness.start(sessionId: id, resumingFrom: nil, workingDirectory: rootPath)
                sessionId = id
                assignedSessionId = id
                // Only if the fallback above actually fired: a conversation
                // started fresh is its own root, and one resumed already has
                // the root it inherited, which must not be overwritten here.
                if lineageRoot == nil { lineageRoot = id }
                startEventPump(harness)
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
            turnInFlight = true
            // 2d-ii: the operator's own turn is a row, so what was actually
            // sent — a misheard sentence included — stays on screen.
            thoughts.append(ThoughtRow(id: nextThoughtId, label: "you", detail: text, isError: false))
            nextThoughtId += 1
            try await harness.send(await textWithIdentifierNote(text))
            // After the send succeeded: a turn that never went leaves no
            // `voice_turn` line, and no suspension sits before the
            // org-switch generation guard in `textWithIdentifierNote`.
            if source == .voice {
                try? await registry.journalVoiceTurn(environment: environment)
            }
            status = ""
            return true
        } catch {
            // A failed send did not start a turn — including a failed
            // `harness.start` or `harness.send` after the line above already
            // set the flag — so nothing may be left in flight.
            turnInFlight = false
            status = "agent: \(error)"
            // T11-R7b. `turnInFlight = true` above runs synchronously
            // right before the genuine suspensions — first inside
            // `textWithIdentifierNote(text)`, then inside `try await
            // harness.send(...)` — so a `requestOrganizationSwitch` can
            // land in either window, see a turn genuinely in flight,
            // and queue. If `harness.send` then throws, this `catch` is
            // the only place `turnInFlight` ever becomes false for that
            // attempt: no `.result` event is coming (the turn never
            // really started), so nothing else will ever call
            // `fireQueuedSwitchIfReady()` for it — and the top-of-`send`
            // refusal now turns the operator away from starting a new
            // turn to shake it loose. Without this call the queue would
            // sit there, technically recoverable
            // (`cancelQueuedSwitch()`/`stopTurnAndSwitchNow()` still
            // work) but effectively starved, which is the one failure
            // this queue exists to prevent. Placed after the `status`
            // assignment above so that, when a switch really is queued,
            // its own status ("switch to … held/…" or the successful
            // switch's own seam) is what is left on screen rather than
            // being overwritten by the send error a moment later. A
            // no-op in the ordinary no-queue case — `fireQueuedSwitchIfReady()`
            // already guards on `queuedOrgSwitch != nil`.
            await fireQueuedSwitchIfReady()
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
    private func startEventPump(_ harness: AgentHarness) {
        eventPump?.cancel()
        // Captured now, not read fresh inside the loop: this is what makes
        // the check below compare THIS pump's generation against whatever
        // is current at the moment each event arrives, rather than always
        // trivially agreeing with itself. See `resume`'s doc comment.
        let generation = eventPumpGeneration
        let pumpProvider = providerId
        // The `Task` inherits this method's `@MainActor` isolation, so the
        // loop appends on the main actor with no hop — it is the `for
        // await` that suspends, not the append, so a long-running session
        // does not hold the main actor between events. `append(_:)` itself
        // stays synchronous (Task 11): only the `.result` case below,
        // AFTER it has already flipped `turnInFlight`, does anything
        // `async` — the one genuine turn end this window has, and the
        // seam `fireQueuedSwitchIfReady()` is called from in production
        // (see that method's own doc comment for the sites it is
        // deliberately NOT called from).
        eventPump = Task { [weak self] in
            for await event in harness.events() {
                // `Task.cancel()` above does not stop an `AsyncStream` from
                // delivering values already sitting in its buffer — this
                // check is what actually does, for a pump a resume has
                // superseded. See `resume`'s doc comment for the full case.
                guard let self, self.eventPumpGeneration == generation else { return }
                self.append(event)
                // Task 15: the same event, projected a second time into
                // every open terminal pane's mirror. `append(_:)` stays
                // synchronous (Task 11); this is the one genuinely `async`
                // step this loop takes per event other than `.result`'s
                // own queued-switch check just below.
                await self.mirror.pump(event)
                await self.recordCapacity(event, provider: pumpProvider)
                if case .result = event {
                    await self.fireQueuedSwitchIfReady()
                    // A queued switch must not wait on a network read.
                    self.startCapacityProbe()
                }
            }
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
    public func resume(sessionId parent: String) async {
        markSessionStarted()
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
        guard parent != sessionId else {
            status = "resume \(parent): that is the session already running in this window"
            return
        }
        let thread: SessionThreadSnapshot
        do {
            thread = try await readThread(parent)
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
        guard let credentials = await resolveCredentials(forProvider: providerId, statusPrefix: "resume \(parent)")
        else {
            return
        }
        guard let next = harnessFactory(organization, ProviderSelection(id: providerId, credentials: credentials)) else {
            status = "resume \(parent): no agent session available"
            return
        }

        // Read BEFORE the swap and before `session_record_parent` below
        // adds this fork to the map, so it is the parent's own lineage
        // being asked about and not one this call has already altered.
        let inheritedRoot = await lineageRootOfSession(parent)

        let child = UUID().uuidString
        do {
            try await next.start(
                sessionId: child, resumingFrom: parent, workingDirectory: thread.cwd)
        } catch {
            // Nothing above this line touched the existing session — see
            // this method's own doc comment.
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
        eventPumpGeneration += 1
        await harness?.stop()

        thoughts = rebuiltThread(thread, parent: parent)
        turnInFlight = false

        harness = next
        self.sessionId = child
        // A resume is a fork: the child is a new conversation id, so the
        // window's assigned identity moves with it.
        self.assignedSessionId = child
        // **The conversation, unlike the id, does NOT move.** That is the
        // whole point of the root: six resumes are six session ids and one
        // workspace. `inheritedRoot` was read before the swap, from the
        // parent's own lineage, so a chain of any length resolves to the
        // same arrangement.
        self.lineageRoot = inheritedRoot
        startEventPump(next)
        status = ""
        // Best effort, and after the swap: a lineage record that failed to
        // write costs ⌘P a grouping, while a resume that refused because
        // of it would cost the operator the session.
        _ = try? await registry.dispatch(
            name: "session_record_parent",
            params: .object(["child": .string(child), "parent": .string(parent)]),
            origin: .ui, environment: environment, confirmation: nil)
        // Last, and only once the swap has actually happened: the canvas
        // follows the conversation. A resume that returned early above
        // never reaches here, so a refused resume leaves the arrangement
        // exactly as it was.
        await activateLayout()
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
    private func lineageRootOfSession(_ id: String) async -> String? {
        guard let result = try? await registry.dispatch(
            name: "session_get", params: .object(["id": .string(id)]),
            origin: .ui, environment: environment, confirmation: nil)
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
    /// QUEUE. A queued switch needs a deferred-state machine nothing else
    /// in this window has, and it defers a decision the operator can simply
    /// re-make in a few seconds. A parked `.mutate` proposal is the sharper
    /// case: it belongs to an agent that is about to stop existing, and
    /// expiring it on the operator's behalf reaches that agent as a refusal
    /// it cannot interpret.
    public func setProvider(_ id: String) async {
        guard id != providerId else {
            status = "set provider \(id): that provider is already running in this window"
            return
        }
        guard !turnInFlight else {
            status = "set provider \(id): a turn is in flight — wait for it to finish"
            return
        }
        // `ConfirmationBroker.current()` is NOT `async` on its own — it is
        // an ordinary actor method, `await`ed here only because calling
        // ANY method on an actor from outside it hops across isolation.
        // There is no `parked()` on this type; `current()` is what it
        // actually exposes for "is something parked right now".
        guard await confirmations.current() == nil else {
            status = "set provider \(id): a mutation is waiting for confirmation — "
                + "confirm or cancel it first"
            return
        }
        let credentials: ProviderCredentials
        do {
            credentials = try await lookup.credentials(forProvider: id)
        } catch let ProviderCredentialsLookupError.refused(reason) {
            // The lookup's own message names the fix (`decodeProviderCredentials`'s
            // doc comment: "the exact `wakil secrets set` to run") — passed
            // through verbatim rather than wrapped, exactly as
            // `resolveCredentials` does for `send` and `resume`, so
            // rewording it here does not lose that.
            status = "set provider \(id): \(reason)"
            return
        } catch {
            status = "set provider \(id): \(error)"
            return
        }
        guard let next = harnessFactory(
            organization, ProviderSelection(id: id, credentials: credentials)) else {
            status = "set provider \(id): no agent session available"
            return
        }

        let fresh = UUID().uuidString
        do {
            // START-THEN-SWAP. Nothing about the running session is touched
            // until `next.start` has returned. `resume(sessionId:)`'s doc
            // comment records what stop-then-start cost when it was tried:
            // a `start` that threw left the operator with no session at all,
            // its process already stopped and its thread already replaced.
            // Do not "fix" this back to stop-then-start.
            try await next.start(
                sessionId: fresh, resumingFrom: nil, workingDirectory: rootPath)
        } catch {
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
        eventPumpGeneration += 1
        await harness?.stop()

        // A FRESH SESSION, NOT A FORK. A resume forks from the parent's
        // transcript; a provider switch cannot, because transcripts live
        // under the provider's own config dir (`sessions.go`'s
        // `providerSessionsRoot`) and the new account's `claude` cannot
        // read a file under the old account's directory. That is the same
        // fact `resume(sessionId:)` enforces when it refuses a session
        // belonging to another provider. So `resumingFrom` is nil above,
        // and the thread is cleared rather than rebuilt.
        let previous = providerId
        thoughts = []
        // Just the two names, no "account changed:" prefix. With the row's
        // own label reading `SESSION` beside it, the prefix said "account"
        // a second time in a row that is four words long — and the arrow
        // already says "changed". Both accounts still appear, which is what
        // the check-2 judgement ("does the seam claim continuity?") needs
        // and what `ProviderSwitchTests` asserts.
        appendSeam("\(previous.isEmpty ? Self.unsetProviderLabel : previous) → \(id)")
        turnInFlight = false

        harness = next
        sessionId = fresh
        assignedSessionId = fresh
        // A provider switch starts a new conversation, not a fork of the
        // one being left, so it is its own root.
        //
        // Review I3 of the re-walk fixes: a switch out of NO conversation mints one over the
        // canvas on screen, exactly as a first turn does, and adopts that canvas the same way
        // (re-walk #4) — re-reading the seed would rebuild every api pane from an empty draft.
        let previousRoot = lineageRoot
        lineageRoot = fresh
        providerId = id
        startEventPump(next)
        status = ""

        // Best effort, and after the swap: exactly the ordering
        // `resume(sessionId:)` uses for `session_record_parent` below, and
        // for the identical reason. `ctx_set_provider` only persists the
        // operator's choice into `active.json` (Task 7's fourth axis) so it
        // survives past this window's lifetime — the live swap above has
        // already happened by the time this runs, so a failed write here
        // costs a future launch its remembered default, never the session
        // the operator is looking at right now.
        _ = try? await registry.dispatch(
            name: "ctx_set_provider",
            params: .object(["name": .string(id)]),
            origin: .ui, environment: environment, confirmation: nil)
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
        // position and jump back. An organisation switch still clears it.
        let settingsPane = layoutSnapshot.panes.first { $0.kind == Pane.settingsKind }
        await activateLayout(carrying: settingsPane, adoptingCanvas: previousRoot == nil)
        startCapacityProbe()
    }

    /// Switches the window to `org`, tearing down everything the outgoing
    /// organisation owned. Spec §4.
    ///
    /// **Guards 1 and 2 mirror `setProvider`'s wording** so the two
    /// switches refuse in one idiom. Guard 3 does NOT: a turn in flight
    /// queues rather than refusing, because an org carries the operator's
    /// whole context where a provider does not (spec §4.2). That branch
    /// lives in `requestOrganizationSwitch`.
    ///
    /// **Fix round 3 (Critical, credential boundary).** The re-entrancy
    /// guard below is what makes `switching` do real work rather than
    /// merely being read by the org plane: this method has no lock of its
    /// own otherwise, and two independent callers can both reach it
    /// concurrently. Concretely: `fireQueuedSwitchIfReady()` reads
    /// `queuedOrgSwitch`, suspends at `await confirmations.current()`, and
    /// — once its OWN re-check (fix round 2, Finding 2) passes — calls
    /// `await setOrganization("beta")`. If a fresh
    /// `requestOrganizationSwitch("gamma")` lands anywhere in that window,
    /// it sees `turnInFlight == false` (a queued switch only exists once a
    /// turn already ended) and calls `await setOrganization("gamma")`
    /// DIRECTLY — no queue involved at all, so the fix round 2 guards
    /// never see it. Without THIS guard, both calls would run at once and
    /// interleave at each other's own suspension points
    /// (`await orgSwitcher(org)`, `await refreshContext()`, `await
    /// autoResumeAfterSwitch()`) — each of which can itself suspend for a
    /// real network/process round trip. That is not merely "the wrong
    /// org's status message wins" the way the same-org and
    /// parked-mutation guards below are: it is the SAME shape
    /// `resume(sessionId:)`'s own doc comment on `eventPumpGeneration`
    /// worries about, one level up — one call's `organization = org`
    /// assignment, `providerId`/`harness`/`sessionId` writes and the
    /// other's can land in any order, so the window can end up with
    /// `organization` naming one org while the running provider, harness
    /// and resumed session belong to the other. That is precisely the
    /// cross-org credential pairing Invariant 4 exists to make
    /// structurally impossible, and it is reachable through two
    /// independent paths — the queue, and two operator-driven switches in
    /// quick succession through Task 10's surface alone, no queue
    /// involved. Refusing the second call outright, before it touches
    /// ANYTHING (`invalidateForOrgChange()`, `orgSwitcher`,
    /// `organization` itself), is what makes that pairing impossible
    /// rather than merely unlikely.
    public func setOrganization(_ org: String) async {
        guard !switching else {
            status = "switch org \(org): a switch is already in progress"
            return
        }
        guard org != organization else {
            status = "switch org \(org): that organisation is already open in this window"
            return
        }
        guard await confirmations.current() == nil else {
            status = "switch org \(org): a mutation is waiting for confirmation — "
                + "confirm or cancel it first"
            return
        }

        // Cleared before anything else, once both guards have passed: a
        // stale sentence naming the OUTGOING org's provider must not be
        // able to linger on screen through a successful switch. `status`
        // is a window-scoped message surface, not org state — that is
        // exactly why it is classified org-independent in
        // `InvalidationContractTests` rather than reset by
        // `invalidateForOrgChange()` — and clearing it here, rather than
        // relying on that method, is what makes the classification honest.
        status = ""

        switching = true
        defer { switching = false }

        // The generation bump precedes `stop()`, exactly as `setProvider`
        // does above and for the identical reason: `ClaudeCodeCLIHarness.stop()`
        // waits for stdout to become buffered events, not for this window
        // to have drained them, so the old pump must already be comparing
        // against a moved-on value or it will append the dead org's
        // events after the seam.
        eventPumpGeneration += 1
        await harness?.stop()

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
            // `invalidateForOrgChange()` above has already wiped every
            // org-scoped property this window held — `providerId`,
            // `harness`, `rootPath`, `lookup`, `project`, `environment`,
            // and both `panes`/`layout` stores — but `organization` still
            // named the OUTGOING org until this line. Leaving it there
            // would strand the operator: `organization` would claim an
            // org of which nothing usable remains, AND the same-org guard
            // above (`org != organization`) would refuse a retry of the
            // very org whose state was just torn down, since `org` here
            // still equals that name. Clearing it is the honest option —
            // an org-less window is a real, designed state this sub-phase
            // already renders (a launch with no org lands there too) —
            // and it is what makes both the outgoing and the intended org
            // reachable again by a subsequent `setOrganization` call.
            //
            // **No `lookup` rebuild on this path, and none is owed.**
            // `invalidateForOrgChange()` already reset it to
            // `lookupFactory("")`, so this assignment leaves the two
            // agreeing: an org-less window holding an org-less lookup,
            // which refuses every credential rather than resolving one
            // under a boundary the window no longer claims.
            organization = ""
            return
        }

        // Authoritative in a way get_context is not: this is the string
        // Wakil itself put into the child environment (spec §6).
        let previous = organization
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
        // **The switch no longer auto-resumes. Ruled 2026-09-20.**
        //
        // Open question 5's 2026-09-15 amendment made returning to an org
        // resume its most recent session, and that was right when there was
        // nowhere else to land. The Landing now exists, and the two rules
        // collided in a way only the first operator walk could show: a switch
        // that resumes sets `sessionStarted`, so the Landing never draws —
        // and the Landing draws only when there was nothing to resume, which
        // is exactly when its Continue column is empty. The one surface built
        // to offer you a session to continue was unreachable whenever a
        // session existed to continue.
        //
        // So the choice goes back to the operator: land sessionless, and
        // Continue lists what `autoResumeAfterSwitch` would have picked, plus
        // everything it would not have. Decision 12's drift argument is
        // untouched — a resume is still a fork under a fresh Wakil-minted id
        // with recorded lineage; what changed is who chooses it.
        //
        // `autoResumeAfterSwitch()` is kept, tested and unreachable from the
        // switch on purpose: it is the whole of the behaviour a `session_new`
        // action would need to offer as "resume the latest", and deleting it
        // would throw away the provider filter and the two fallback paths
        // that are the hard part.
        appendSeam("\(previous.isEmpty ? "none" : previous) → \(org)")
    }

    /// The operator asked to switch. Queues if a turn is in flight,
    /// switches immediately otherwise — spec §4.2's three states.
    /// Unsaved editor tabs ask first (`unsavedPrompt`); its Save or Don't Save switches.
    public func requestOrganizationSwitch(_ org: String) async {
        // Every scope (final review I3): the switch clears all of them.
        let dirty = await everyUnsavedTab()
        if !dirty.isEmpty {
            askUnsaved(.switchOrganisation(org), tabs: dirty)
            return
        }
        await performOrganisationSwitch(org)
    }

    private func performOrganisationSwitch(_ org: String) async {
        guard turnInFlight else {
            await setOrganization(org)
            return
        }
        queuedOrgSwitch = org
        status = "switching to \(org) when this turn finishes"
    }

    /// What the operator's own cancel control on the queued-switch
    /// affordance calls. Only ever cancels — see `queuedOrgSwitch`'s own
    /// doc comment for why nothing else may.
    public func cancelQueuedSwitch() {
        guard let org = queuedOrgSwitch else { return }
        queuedOrgSwitch = nil
        unsavedSwitchApproved = nil
        queuedSwitchCancellationCount += 1
        status = "switch to \(org) cancelled"
    }

    /// Cuts the running turn and switches at once. Same ordering
    /// `setProvider` records: the generation bump precedes `stop()`.
    ///
    /// Unsaved editor tabs (3b-i Task 9): the turn is still cut — that is what was asked — and the
    /// switch then asks Save / Don't Save / Cancel like any other. Held, touching nothing, while
    /// another unsaved prompt is up.
    public func stopTurnAndSwitchNow() async {
        guard let org = queuedOrgSwitch else { return }
        let unsaved = await switchNeedsAsking(org)
        guard queuedOrgSwitch == org else { return }   // the await above let a cancel land
        if unsaved != nil, unsavedPrompt != nil {
            status = "switch to \(org) held: unsaved changes are being asked about"
            return
        }
        queuedOrgSwitch = nil
        eventPumpGeneration += 1
        await harness?.stop()
        turnInFlight = false
        appendSeam("turn cut short")
        if let unsaved {
            askUnsaved(.switchOrganisation(org), tabs: unsaved)
            return
        }
        unsavedSwitchApproved = nil
        await setOrganization(org)
    }

    /// Fires a queued switch at the first moment nothing is in its way.
    ///
    /// Called wherever `turnInFlight` genuinely becomes false at a TURN
    /// END — the `.result` case in the event pump that drives `append(_:)`,
    /// `send(_:)`'s own `catch` (T11-R7b: a turn that never really started
    /// still needs this, or a switch queued against it while
    /// `harness.send` was suspended would never drain) — and wherever a
    /// confirmation is resolved (`confirmPending`, `cancelPending`).
    ///
    /// Also called from `resumePump`'s closure, immediately after
    /// `await self.resume(sessionId:)` — NOT from inside
    /// `resume(sessionId:)` itself. That distinction matters:
    /// `resume(sessionId:)` has two callers with different reentrancy
    /// properties. Nested inside `setOrganization` via
    /// `autoResumeAfterSwitch()`, firing from `resume`'s own body would be
    /// reentrant — a switch calling into a switch. Called from
    /// `resumePump` (the agent's own `session_resume`, or `--dispatch`),
    /// it is never nested inside a switch and IS a genuine turn end (fix
    /// round 2, Finding 1): a turn in flight, a switch queued, then the
    /// agent resumes a different session — `resume`'s own teardown sets
    /// `turnInFlight = false` with no `.result` ever coming for that turn,
    /// so without a fire call at the `resumePump` call site specifically,
    /// the queue would never drain and the top-of-`send` refusal would
    /// turn the operator away from the one action (starting a new turn)
    /// that would otherwise shake it loose. Putting the call in
    /// `resume(sessionId:)` itself would fire on BOTH callers and break
    /// the first.
    ///
    /// Deliberately NOT called from `invalidateForOrgChange()`'s own
    /// `turnInFlight = false` (that is a reset mid-switch, not an end), nor
    /// from `setProvider(_:)`'s teardown (not a turn ending — it hands the
    /// window a fresh turn state for an unrelated reason).
    ///
    /// **A parked mutation HOLDS rather than cancels** — discarding the
    /// operator's intent while they are looking at an unrelated SQL
    /// statement would take the switch away at the one moment they have no
    /// reason to connect the two (spec §4.2 state 2). Checks the
    /// `confirmations` BROKER directly, not `self.pending`: `pending` is
    /// this window's own mirror, updated asynchronously by a subscriber
    /// (see `confirmationPump` in `init`), so immediately after
    /// `confirmPending`/`cancelPending` resolve the broker, the broker's
    /// own state is already clear while `pending` may still be stale for
    /// one more loop iteration. Checking `pending` here would leave a held
    /// switch stuck forever.
    ///
    /// **Reentrancy-guarded against a SECOND CALL TO THIS METHOD.** `await
    /// confirmations.current()` below is a suspension point, so two calls
    /// landing back-to-back (say the event pump's `.result` handling and a
    /// `cancelPending` racing it) could otherwise both observe
    /// `queuedOrgSwitch` non-nil, both pass the guard, and both call
    /// `setOrganization` — two switches firing for one queued request.
    /// `firingQueuedSwitch` makes every call after the first, while one is
    /// already running, a no-op instead.
    ///
    /// **That flag does NOT cover an unrelated mutator racing the same
    /// suspension** (fix round 2, Finding 2) — a different mechanism, not
    /// a second call to this method. `WindowModel` is `@MainActor`, so
    /// other MainActor work, including the plain synchronous
    /// `cancelQueuedSwitch()`, can run during the `await
    /// confirmations.current()` hop. Without the `queuedOrgSwitch == org`
    /// re-check below, a cancel landing there would be silently
    /// overridden: this method would resume holding the stale captured
    /// `org`, clear nothing, and switch the operator to an org they had
    /// just explicitly declined — a credential-boundary violation, not
    /// merely a UI glitch. See the re-check's own comment.
    ///
    /// **`requestOrganizationSwitch` landing in the same window does NOT
    /// re-target the queue the way it might look like it should.** By
    /// construction, `turnInFlight` is already `false` by the time this
    /// method reaches this suspension (its own guard just above requires
    /// it), and `requestOrganizationSwitch`'s own `guard turnInFlight`
    /// takes the OTHER branch when false — it calls `setOrganization`
    /// directly rather than writing `queuedOrgSwitch` at all. So a
    /// third-org request here does not retarget the stale `org`; it
    /// reaches `setOrganization` directly while this method is still
    /// suspended.
    ///
    /// **`setOrganization` refuses it, and that is where the safety
    /// lives.** Fix round 3 gave that method a real reentrancy guard of
    /// its own — `guard !switching` is its very first line, ahead of
    /// `invalidateForOrgChange()`, `orgSwitcher` and the `organization`
    /// assignment — so the second call returns with "a switch is already
    /// in progress" having touched nothing. Two switches therefore cannot
    /// interleave at each other's suspension points and leave
    /// `organization` naming one org while the provider, harness and
    /// resumed session belong to the other (Invariant 4).
    /// `twoConcurrentSetOrganizationCallsProduceExactlyOneCoherentSwitch`
    /// (`OrgSwitchTests.swift`) pins it against the real `wakil-ctx`
    /// backend: it parks the first switch inside the org switcher, lands
    /// a second one on top, and asserts the loser never reached the
    /// backend at all. An earlier version of this comment called the race
    /// "a real gap… flagged rather than patched here"; it was patched,
    /// and this paragraph now describes the code as it is.
    func fireQueuedSwitchIfReady() async {
        guard !firingQueuedSwitch else { return }
        firingQueuedSwitch = true
        defer { firingQueuedSwitch = false }

        guard let org = queuedOrgSwitch, !turnInFlight else { return }
        guard await confirmations.current() == nil else {
            status = "switch to \(org) held: a mutation is waiting for confirmation"
            return
        }
        // Fix round 2, Finding 2. `org` was captured before the suspension
        // just above; re-read `queuedOrgSwitch` now rather than trusting
        // that capture. A plain synchronous mutator — `cancelQueuedSwitch()`
        // — can run on this same `@MainActor` during that `await`, and
        // `firingQueuedSwitch` above does not protect against it: that
        // flag only stops a SECOND call to this method, not a different
        // method altogether. If the queue no longer names `org`, this
        // must not switch to the stale value: a cancel that got silently
        // overridden would move credentials to an org the operator
        // explicitly declined (Invariant 4). (`requestOrganizationSwitch`
        // landing in this same window is a related but separate case,
        // closed by `setOrganization`'s own `guard !switching` rather
        // than by this re-check — see this method's own doc comment.)
        guard queuedOrgSwitch == org else { return }
        // 3b-i Task 9: unsaved editor tabs ask first, as a direct switch does — the queue leaves
        // and the prompt's Save or Don't Save runs the switch. Held behind a prompt already up;
        // `resolveUnsaved` fires again once it is answered.
        if let unsaved = await switchNeedsAsking(org) {
            guard unsavedPrompt == nil else {
                status = "switch to \(org) held: unsaved changes are being asked about"
                return
            }
            guard queuedOrgSwitch == org else { return }   // the await above let a cancel land
            queuedOrgSwitch = nil
            askUnsaved(.switchOrganisation(org), tabs: unsaved)
            return
        }
        queuedOrgSwitch = nil
        unsavedSwitchApproved = nil
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
    /// **Owed: nothing clears it in-window.** `session_resume` exists and
    /// nothing mints a fresh session without relaunching, so there is no way
    /// back to the Landing short of quitting. A `session_new` action is that
    /// return path; it is recorded here and on `LandingStates.dc.html` rather
    /// than invented.
    public private(set) var sessionStarted = false

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
    /// conversation id and a provider switch mints a fresh one.
    public private(set) var assignedSessionId: String?

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
    /// Org-derived, and cleared by `invalidateForOrgChange` for the reason
    /// `assignedSessionId` is: an org switch ends the session, and left
    /// set, the next org's first pane would be filed under the outgoing
    /// org's conversation.
    public private(set) var lineageRoot: String?

    /// Called by the three entrances into work. Idempotent on purpose — it is
    /// reached from a turn, a pane and a resume, and two of those can happen
    /// in the same gesture.
    public func markSessionStarted() {
        sessionStarted = true
        // Minted here rather than in `send`, so a pane opened from the
        // Landing belongs to a conversation before a turn exists. Idempotent
        // with the flag above: this is reached from a turn, a pane and a
        // resume, and two of those can happen in one gesture.
        if assignedSessionId == nil {
            let id = UUID().uuidString
            assignedSessionId = id
            // **A conversation started fresh is its own root**, which is
            // the same answer `wakilcore.LineageRootIn` gives for an id
            // with no recorded parent. `resume` overwrites this with the
            // root it inherits, and it runs after this: `resume` calls
            // `markSessionStarted()` at its own first line, so a resume
            // that gets as far as swapping the harness has already minted
            // a throwaway root here and replaces it deliberately.
            lineageRoot = id
        }
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
        sessionStarted = true
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

    // MARK: - Test-only queue helpers (Task 11)

    /// TEST-ONLY: puts the window into the `turnInFlight` state a test
    /// needs to observe `requestOrganizationSwitch` queue rather than
    /// switch immediately, without driving a real `send()`/harness turn to
    /// get there. Asserts its own precondition, the same way
    /// `parkAProposalForTesting()` above does: calling this while a turn
    /// is already in flight would silently paper over a test that set up
    /// its fixture wrong.
    func beginTurnForTesting() async {
        precondition(!turnInFlight, "beginTurnForTesting: a turn is already in flight")
        turnInFlight = true
    }

    /// TEST-ONLY: ends the turn `beginTurnForTesting()` started AND fires
    /// a queued switch — the production event pump's `.result` handling
    /// does both together (see `fireQueuedSwitchIfReady()`'s doc comment),
    /// so a test exercising "the switch fires when the turn ends" needs
    /// this, not two separate calls a real turn end never makes
    /// separately.
    func endTurnForTesting() async {
        precondition(turnInFlight, "endTurnForTesting: no turn is in flight")
        turnInFlight = false
        await fireQueuedSwitchIfReady()
    }

    /// TEST-ONLY: ends the turn WITHOUT firing — for a test that needs to
    /// land in between the two (a switch queued, the turn over, but the
    /// fire not yet attempted), such as the send-refusal test, which must
    /// prove `send` refuses while a switch is queued and turnInFlight is
    /// already false, independent of whether the fire has run yet.
    func endTurnForTestingWithoutFiring() async {
        precondition(turnInFlight, "endTurnForTestingWithoutFiring: no turn is in flight")
        turnInFlight = false
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
    private func appendSeam(_ detail: String) {
        thoughts.append(ThoughtRow(id: nextThoughtId, label: "session", detail: detail, isError: false))
        nextThoughtId += 1
    }

    /// Parks a throwaway `.mutate` proposal into `confirmations` and
    /// returns once it is either actually parked or definitively not
    /// going to be — built for `ProviderSwitchTests`' "a mutation is
    /// waiting for confirmation" refusal, which needs
    /// `confirmations.current()` to answer non-`nil` without any human,
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
            statement: "SELECT 1", affectsEveryRow: false, origin: .ui)
        Task { [confirmations] in _ = await confirmations.request(proposal) }
        for _ in 0..<1_000 {
            if await confirmations.current()?.id == proposal.id { return }
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
    private func rebuiltThread(_ thread: SessionThreadSnapshot, parent: String) -> [ThoughtRow] {
        var rows: [ThoughtRow] = []
        for entry in thread.entries.suffix(Self.rebuiltThreadLimit) {
            // 2d-i: the transcript holds what was sent — the typed text
            // plus the note — so the operator's turn is split back into
            // the text they typed and the `RESOLVED` row the live turn showed.
            var detail = entry.detail
            var resolvedRow: String?
            if entry.label == "you" { (detail, resolvedRow) = TurnNote.split(entry.detail) }
            rows.append(ThoughtRow(id: nextThoughtId, label: entry.label, detail: detail, isError: entry.isError))
            nextThoughtId += 1
            if let resolvedRow {
                rows.append(ThoughtRow(id: nextThoughtId, label: "resolved", detail: resolvedRow, isError: false))
                nextThoughtId += 1
            }
        }
        var seam = "resumed from \(parent)"
        if thread.truncated { seam += " (earlier turns not shown)" }
        rows.append(ThoughtRow(id: nextThoughtId, label: "resumed", detail: seam, isError: false))
        nextThoughtId += 1
        return rows
    }

    /// 2d-ii: a speech engine's failure, whole, as a red thread row
    /// (interaction rule 8).
    public func appendSpeechFailure(_ message: String) {
        thoughts.append(ThoughtRow(id: nextThoughtId, label: "speech", detail: message, isError: true))
        nextThoughtId += 1
    }

    /// The active organisation's speech engine id, `""` when unset. Reads
    /// the cached settings tree, and fetches only the tree — never the
    /// account table `refreshSettings` also reads — when there is none,
    /// because this runs on every hold of ⌥.
    public func speechEngineId() async -> String {
        if let settings { return settings.org.speechProvider }
        guard let result = try? await registry.dispatch(
            name: "ctx_config_tree", params: .object([:]), origin: .ui,
            environment: environment, confirmation: nil),
              let tree = decodeSettingsTree(fromResult: result) else { return "" }
        settings = tree
        return tree.org.speechProvider
    }

    /// 2d-i: the operator's text, unchanged, plus the hint when anything in
    /// it folds to a name in scope. Appends the `RESOLVED` row and journals
    /// the note whole; the row is one truncated line like every other.
    ///
    /// A switch (or a "stop and switch now") that lands while `current()`
    /// is suspended bumps `eventPumpGeneration` and appends its seam; the
    /// old turn's row must not follow it, so a moved generation sends the
    /// text unchanged, with no row and no journal entry.
    private func textWithIdentifierNote(_ text: String) async -> String {
        guard let vocabulary else { return text }
        let generation = eventPumpGeneration
        let current = await vocabulary.current()
        guard generation == eventPumpGeneration else { return text }
        let resolutions = IdentifierResolver.resolve(text, in: current)
        guard let note = TurnNote.render(resolutions) else { return text }
        thoughts.append(ThoughtRow(id: nextThoughtId, label: "resolved", detail: TurnNote.row(resolutions), isError: false))
        nextThoughtId += 1
        try? await registry.journalIdentifierEvent(
            action: "identifiers_resolved", params: .object(["note": .string(note)]),
            environment: environment, outcome: "ok")
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
    private func readThread(_ id: String) async throws -> SessionThreadSnapshot {
        let result = try await registry.dispatch(
            name: "session_read",
            params: .object(["id": .string(id), "limit": .number(Double(Self.rebuiltThreadLimit))]),
            origin: .ui, environment: environment, confirmation: nil)
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

    private func append(_ event: HarnessEvent) {
        debugLogIfEnabled(event)
        if case .result = event { turnInFlight = false }
        // Task 15, fix round 1 (Critical): `Date()` is captured exactly
        // here, at the one place a harness event actually arrives, and
        // carried alongside it into `mirror.events` — not recomputed later,
        // and not synthesised at all inside `mirroredBlocks`, which is
        // what the first cut got wrong. See `MirrorEvent`'s own doc
        // comment for the regression this replaced.
        mirror.retain(event, at: Date())
        guard let row = thoughtRow(id: nextThoughtId, for: event) else { return }
        nextThoughtId += 1
        thoughts.append(row)
    }

    // MARK: - Terminal mirror (Task 15) — see `TerminalMirrorFeed`

    /// TEST-ONLY: feeds `event` through exactly the path a live harness
    /// event takes — `append(_:)` for the thought thread, then
    /// `mirror.pump(_:)` for every open terminal pane — and waits for both
    /// before returning, so an assertion immediately afterwards sees the
    /// result with no race to poll for. `startEventPump`'s own loop does
    /// the same two calls, in the same order, for the same reason.
    func receiveForTesting(_ event: HarnessEvent, provider: String? = nil) async {
        append(event)
        await mirror.pump(event)
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

    private func recordCapacity(_ event: HarnessEvent, provider: String) async {
        if case .rateLimit(let windows) = event {
            await capacity.receive(windows, provider: provider)
        }
    }

    /// TEST-ONLY: the agent `Bash` events the mirror is holding for a terminal
    /// pane opened later — what an org switch must leave empty.
    var mirrorEventsForTesting: [MirrorEvent] { mirror.events }

    /// TEST-ONLY: the raw `PaneStore` this model reads and writes, for a
    /// test that wants its own narrower API (`terminalBlocks(paneId:)`,
    /// `snapshot(paneId:kind:)`) directly rather than one of the
    /// `...ForTesting` wrappers below, which exist for the handful of
    /// reads or writes common enough to be worth naming here.
    var panesForTesting: PaneStore { panes }

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
    private func journalTerminalRun(_ run: TerminalRun) async {
        let context = activeShellContext
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
            environment: environment, confirmation: nil)
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
            origin: .ui, environment: environment, confirmation: nil),
            case .object(let fields) = result, case .string(let pane)? = fields["pane"]
        else { return "" }
        await mirror.backfill()
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
            origin: .agent, environment: environment, confirmation: nil)
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
        eventPump?.cancel()
        confirmationPump?.cancel()
        observationPump?.cancel()
        flightPump?.cancel()
        editorFlightPump?.cancel()
        editorFilesPump?.cancel()
        resumePump?.cancel()
        providerSwitchPump?.cancel()
        terminalRunPump?.cancel()
        await harness?.stop()
        // No shell outlives the window. Without this line `terminals` was
        // the one live-resource store `shutdown()` forgot — every pump
        // above is cancelled, but a cancelled pump does not kill a child
        // process, and neither does dropping this model.
        //
        // `.finish` here and `.keepOpen` in `invalidateForOrgChange()`:
        // this is the end of the window, so the run stream ends with it.
        await terminals.shutdownAll(runStream: .finish)
    }
}

// MARK: - Unsaved edits (3b-i Task 9)

/// What asked before unsaved editor tabs would be lost.
public enum UnsavedIntent: Sendable, Equatable {
    /// One tab, named by its subject rather than its position, which can move while it waits.
    case closeTab(pane: String, subject: EditorTabSubject)
    case closePane(pane: String)
    case switchOrganisation(String)
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
