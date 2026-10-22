import Foundation

/// Holds what every pane currently shows — columns, their types, rows —
/// together with what is selected in it and how it is sorted, keyed by pane
/// id **within a `LayoutScope`**.
///
/// **Why the scope is part of the key** (final review Finding 6). Pane
/// ids are unique within one process because `LayoutStore.open` counts up
/// across every scope, but they are not unique across *sessions*:
/// `LayoutStore.load` raises that counter only from the snapshot being
/// loaded, so two projects saved on disk can each contain a pane called
/// `db-1`. Keyed by pane id alone and never cleared, this store answered
/// project B's `db-1` with project A's rows — a different project's, and
/// possibly a different environment's, database — on screen and in
/// `read_pane` alike. Keying by scope makes that impossible rather than
/// unlikely, and it keeps what clearing on switch would have cost:
/// `design-language.md` §13 requires that panes are never torn down on a
/// switch and that their state stays warm, so coming back to a scope
/// finds its rows where they were left.
///
/// **The scope, not the project name.** The same key on both stores and on
/// disk is what stops memory and disk disagreeing about what an
/// arrangement belongs to — see `LayoutScope`, which carries the
/// organisation for exactly that reason.
///
/// `switchScope` matches `LayoutStore`'s, is called from the same place,
/// and means the same thing.
///
/// `snapshot(paneId:kind:)` is what an AI agent reads to answer questions
/// about what is on screen, so it must be honest: it never errors, the
/// `rowCount` it reports always matches the number of rows actually held,
/// and `truncated` says whether those rows are the whole answer. A pane the
/// canvas still holds but that has never been written to is not a special
/// or invalid state — it gets the same empty shape a pane that was
/// explicitly cleared would get, keyed by its own `kind`, for every kind
/// this build knows (`PaneKind`, `App/PaneKinds.swift`). A pane the canvas
/// does not hold at all (`kind: nil`) answers `kind: null` with no payload,
/// which is not an error either — a pane can close between the
/// `read_layout` that named it and the `read_pane` that asks, and an error
/// there would turn a correct sequence of calls into a failure.
///
/// **Three writers, three lifetimes, three setters.** A query replaces
/// rows; a click replaces the selection; a header click replaces the sort.
/// Folding them into one setter would make every refresh silently clear
/// what the operator picked, which is why `setRows` leaves selection and
/// sort alone and each has a test saying so.
///
/// An actor: these are called from different tasks — a dispatched action, a
/// pointer gesture, an agent's tool call — and must not race.
public actor PaneStore {
    /// Every scope's panes. The outer key is the scope, the inner one the
    /// pane id.
    ///
    /// **One store, one slot per pane** (Decision 24). A second store for the terminal would
    /// re-implement everything this one earns its keep on and that a terminal needs identically:
    /// scope-keyed contents (2c-i final review Finding 6, where one project's `db-1` answered with
    /// another project's rows), `switchScope`, and §13's requirement that a pane's state stays warm
    /// across a switch — and a shell the operator left running is the most warm-state thing on the
    /// canvas. Each slot names the `PaneKind` holding it and carries that kind's contents.
    ///
    /// **Only the live OS resource is elsewhere.** The pty master fd, the
    /// child pid and the drain thread live in `TerminalStore`, because no
    /// `deinit` in `WakilKit` releases an OS resource and a cleared
    /// dictionary does not kill a shell — `close(2)` on a pty master
    /// blocks forever while a thread is parked in `read(2)`.
    private var byScope: [LayoutScope: [String: PaneSlot]] = [:]
    /// The scope on screen: what `switchScope` installs.
    ///
    /// Starts on `LayoutScope.initial` — the same scope `LayoutStore`
    /// starts on — so that a `--dispatch` run, or a window before
    /// `refreshContext()` has answered, writes and reads one consistent
    /// place rather than needing a context to exist first.
    private var screen = LayoutScope.initial
    /// The scope `inScope` has pinned for the body it is running, over everything else.
    private var pinned: LayoutScope?
    /// The scope whose panes every method below reads and writes — the one resolved-scope
    /// accessor both forms of routing go through: `inScope`'s pin, synchronous, for a flight
    /// landing where it left from; else the dispatching caller's own (`ScopeRouting.home`,
    /// background agents 3 of 4), for an agent working in a place the operator has left; else
    /// the one on screen.
    private var scope: LayoutScope { pinned ?? ScopeRouting.home ?? screen }
    /// The scope on screen, whatever scope the caller is routed to: the window asks it to tell
    /// whether a swap is owed.
    public var screenScope: LayoutScope { screen }
    /// Each kind's store-wide state, created on first touch (read or write) so that a scope change
    /// reaches state that has only been read so far.
    private var sharedByKind: [ObjectIdentifier: (kind: any PaneKind.Type, value: any Sendable)] = [:]
    /// The kinds this store knows, for a never-written pane's empty snapshot (`App/PaneKinds.swift`).
    private let kinds: [any PaneKind.Type]


    public init(kinds: [any PaneKind.Type] = []) {
        self.kinds = kinds
    }

    /// The active scope's panes, or an empty set for one nothing has been
    /// written to yet.
    private var panes: [String: PaneSlot] {
        get { byScope[scope] ?? [:] }
        set { byScope[scope] = newValue }
    }

    // MARK: - Generic access, for each kind's store methods

    /// The pane's contents if it holds `kind`, else the kind's empty contents.
    func contents<K: PaneKind>(_ kind: K.Type, _ paneId: String) -> K.Contents {
        guard let slot = panes[paneId], slot.kindID == ObjectIdentifier(kind) else { return K.emptyContents }
        return slot.contents as! K.Contents
    }

    /// Writes `contents` unless the pane already holds another kind — the rule each kind's setter had.
    func setContents<K: PaneKind>(_ kind: K.Type, _ paneId: String, _ contents: K.Contents) {
        if let slot = panes[paneId], slot.kindID != ObjectIdentifier(kind) { return }
        panes[paneId] = PaneSlot(kind: kind, contents: contents)
    }

    func holds<K: PaneKind>(_ kind: K.Type, _ paneId: String) -> Bool {
        panes[paneId]?.kindID == ObjectIdentifier(kind)
    }

    func kindState<K: PaneKind>(_ kind: K.Type) -> K.Shared {
        if let entry = sharedByKind[ObjectIdentifier(kind)] { return entry.value as! K.Shared }
        sharedByKind[ObjectIdentifier(kind)] = (kind, K.emptyShared)
        return K.emptyShared
    }

    func setKindState<K: PaneKind>(_ kind: K.Type, _ value: K.Shared) {
        sharedByKind[ObjectIdentifier(kind)] = (kind, value)
    }

    /// The scope whose pane `paneId` holds `kind` and matches — the active scope first.
    func scope<K: PaneKind>(
        holding kind: K.Type, paneId: String, where match: (K.Contents) -> Bool
    ) -> LayoutScope? {
        func holds(_ panes: [String: PaneSlot]) -> Bool {
            guard let slot = panes[paneId], slot.kindID == ObjectIdentifier(kind) else { return false }
            return match(slot.contents as! K.Contents)
        }
        if holds(panes) { return scope }
        return byScope.first { holds($0.value) }?.key
    }

    /// Every scope's panes holding `kind`: the active scope first, then the others by project and
    /// conversation, each by pane id. A scope switch keeps the outgoing scope's contents in memory,
    /// so whatever must not be lost unasked (an editor's unsaved tabs) lives in all of them.
    func everyScope<K: PaneKind>(_ kind: K.Type) -> [(scope: LayoutScope, active: Bool, paneId: String, contents: K.Contents)] {
        let others = byScope.keys.filter { $0 != scope }
            .sorted { ($0.project, $0.lineageRoot ?? "") < ($1.project, $1.lineageRoot ?? "") }
        var out: [(scope: LayoutScope, active: Bool, paneId: String, contents: K.Contents)] = []
        for home in [scope] + others {
            for (id, slot) in (byScope[home] ?? [:]).sorted(by: { $0.key < $1.key }) where slot.kindID == ObjectIdentifier(kind) {
                out.append((home, home == scope, id, slot.contents as! K.Contents))
            }
        }
        return out
    }

    /// Runs `body` with `home` as the active scope, synchronously, so nothing interleaves.
    func inScope<T>(_ home: LayoutScope, _ body: () -> T) -> T {
        let outer = pinned
        pinned = home
        defer { pinned = outer }
        return body()
    }

    private func switching<K: PaneKind>(_ kind: K.Type, _ value: any Sendable) -> any Sendable {
        K.sharedAfterSwitchingScope(value as! K.Shared)
    }

    private func adopting<K: PaneKind>(
        _ kind: K.Type, _ value: any Sendable, from outgoing: LayoutScope, to incoming: LayoutScope
    ) -> any Sendable {
        K.sharedAfterAdoptingScope(value as! K.Shared, from: outgoing, to: incoming)
    }

    private func slotSnapshot<K: PaneKind>(_ kind: K.Type, _ contents: any Sendable, label: String) -> PaneSnapshot {
        let typed = contents as! K.Contents
        return PaneSnapshot(kind: label, failure: K.failure(of: typed), contents: K.snapshot(of: typed, in: self))
    }

    private func slotFailure<K: PaneKind>(_ kind: K.Type, _ contents: any Sendable) -> String? {
        K.failure(of: contents as! K.Contents)
    }

    private func emptySnapshot<K: PaneKind>(_ kind: K.Type, label: String) -> PaneSnapshot {
        PaneSnapshot(kind: label, failure: nil, contents: K.emptySnapshot)
    }

    /// The data surface's contents for `paneId`, or a fresh empty set.
    ///
    /// **A pane that is not a data surface answers with a fresh empty set
    /// and the write is discarded**, which is deliberately NOT how an agent
    /// reaches these: the five data-surface actions refuse a pane of
    /// another kind by name
    /// at the action layer (`registerPaneContentActions`), so the only way
    /// to arrive here with a terminal pane id is an internal caller that
    /// has already gone wrong. Silently corrupting a terminal pane's
    /// contents would be worse than dropping the write.
    func dataSurface(_ paneId: String) -> DataSurfaceContents { contents(DataSurfacePaneKind.self, paneId) }

    private func setDataSurface(_ paneId: String, _ contents: DataSurfaceContents) {
        setContents(DataSurfacePaneKind.self, paneId, contents)
    }


    /// Every scope holding pane contents in memory, the one on screen among them: what a rename
    /// of a project or an environment carries to the new name (2e-ii).
    public var scopes: Set<LayoutScope> { Set(byScope.keys) }

    /// Makes `scope` the active set of panes, keeping the outgoing one.
    ///
    /// Called beside `LayoutStore.switchScope`, from
    /// `WindowModel.activateLayout`, because the two answer the same
    /// question about the same panes: that one holds where they are, this
    /// one holds what is in them.
    public func switchScope(to scope: LayoutScope) {
        screen = scope
        // Each kind's store-wide state hears of it. (Not Api's any more: its generations are per
        // scope and never shared between two, so a switch leaves every listing in flight to land
        // in its own scope — an agent's among them.)
        for (id, entry) in sharedByKind { sharedByKind[id] = (entry.kind, switching(entry.kind, entry.value)) }
    }

    /// Makes `scope` the active set of panes, MOVING `outgoing`'s contents into it, beside
    /// `LayoutStore.switchScope(to:adoptingFrom:)` (re-walk finding #4): every draft, reply and
    /// row stays with its pane when a conversation is minted over the canvas.
    public func switchScope(to scope: LayoutScope, adoptingFrom outgoing: LayoutScope) {
        let carried = byScope[outgoing] ?? [:]
        byScope[outgoing] = nil
        byScope[scope] = carried
        screen = scope
        // **No generation bump** (review minor): the same panes, in the same org, project and
        // environment, under a new key. A `list_apis` in flight still describes them, so each
        // kind carries its per-scope state across to the new key.
        for (id, entry) in sharedByKind {
            sharedByKind[id] = (entry.kind, adopting(entry.kind, entry.value, from: outgoing, to: scope))
        }
    }

    /// Forgets everything held for pane `paneId` in the active scope.
    ///
    /// **Called when a pane closes** (`pane_close`). Without it a closed
    /// pane's rows stayed in memory for the life of the process — every
    /// result set an operator ever looked at, held indefinitely — and a
    /// later pane that happened to be given the same id would have drawn
    /// them.
    public func drop(paneId: String) {
        // A db read in flight stops on the database, not just loses its pane (final review, Minor 4).
        _ = cancelDBRead(paneId: paneId)
        panes[paneId] = nil
        dropObservers.forEach { $0(paneId) }
    }

    /// Who is told a pane was dropped — the editor actions, whose diff-tab fetches for it must stop.
    private var dropObservers: [@Sendable (String) -> Void] = []

    /// Calls `observer` with the pane id each time `drop(paneId:)` runs, after its contents
    /// are gone. For work a pane owns outside this store (an editor pane's diff-tab fetches in
    /// flight, `EditorDiffFlights`).
    public func onDrop(_ observer: @escaping @Sendable (String) -> Void) {
        dropObservers.append(observer)
    }

    /// Every pane id held in the active scope, in the dictionary's own order (the api kind's loops).
    var paneKeys: some Collection<String> { panes.keys }

    /// The active scope: the caller's own, else the one on screen (the api kind's Recent key).
    var activeScope: LayoutScope { scope }

    /// Whether anything is held for `paneId` in the active scope.
    func holdsContents(paneId: String) -> Bool { panes[paneId] != nil }

    /// Replaces pane `paneId`'s columns and rows entirely. There is no
    /// incremental append: a pane always holds exactly what the most recent
    /// `setRows` gave it, and a second page REPLACES the first rather than
    /// being added to it.
    ///
    /// **No parameter here has a default, deliberately, and 2c-ii's three
    /// new ones keep that rule for a sharper reason than the original
    /// three.** `sort` is a COPY: the authority is `Pane.fetch.sort`, in
    /// `LayoutStore`, and what is kept here is the value `displayRows` was
    /// ordered by — the same relationship `displayRows` already has to
    /// `rows`. A default would let a caller forget to pass the authority's
    /// value, and the two would silently disagree about what the operator
    /// had sorted by. There is no default, so no caller can forget.
    public func setRows(
        paneId: String, columns: [String], columnTypes: [String],
        columnTypesInferred: Bool, rows: [[JSONValue]], millis: Int64, truncated: Bool,
        pageable: Bool, offset: Int, sort: [PaneSort], listsTables: Bool,
        editable: PaneEditable?
    ) {
        var contents = dataSurface(paneId)
        // Before anything else: these are different rows from the ones
        // that were here, whatever they came back as, so every capture
        // taken from the old ones is now dead.
        contents.generation += 1
        contents.columns = columns
        contents.columnTypes = columnTypes
        contents.columnTypesInferred = columnTypesInferred
        contents.rows = rows
        contents.failure = nil
        contents.millis = millis
        contents.truncated = truncated
        contents.pageable = pageable
        contents.offset = max(0, offset)
        contents.sort = sort
        contents.listsTables = listsTables
        contents.sourceEditable = editable
        reorder(&contents)
        clampToRowCount(&contents)
        setDataSurface(paneId, contents)
    }

    // MARK: - A db read in flight

    func dbFlightScope(paneId: String, token: UUID) -> LayoutScope? {
        scope(holding: DataSurfacePaneKind.self, paneId: paneId) { $0.flight?.token == token }
    }

    /// Opens a flight on `paneId`, or refuses with `nil` when one is already in flight.
    /// `byAgent`: an agent session made it (`DBFlight.byAgent`).
    public func beginDBRead(paneId: String, at since: Date, byAgent: Bool = false) -> UUID? {
        var contents = dataSurface(paneId)
        guard contents.flight == nil else { return nil }
        let token = UUID()
        contents.flight = DBFlight(token: token, since: since, byAgent: byAgent)
        setDataSurface(paneId, contents)
        publishFlight(paneId)
        return token
    }

    /// Whether a db read is in flight on `paneId` (`pane_sort` refuses under one, Rule 5).
    public func dbReadRunning(paneId: String) -> Bool { dataSurface(paneId).flight != nil }

    /// Hands the flight its canceller. A cancel that arrived first runs it now.
    public func armDBRead(paneId: String, token: UUID, cancel: @escaping @Sendable () -> Void) {
        guard let home = dbFlightScope(paneId: paneId, token: token) else {
            cancel()   // cancelled and cleared before the canceller arrived
            return
        }
        inScope(home) {
            var contents = dataSurface(paneId)
            guard var flight = contents.flight else { return }
            flight.cancel = cancel
            contents.flight = flight
            setDataSurface(paneId, contents)
        }
    }

    /// Ends the flight at once: clears it, records how long it ran, keeps the rows, and runs
    /// the canceller. A reply that still arrives is dropped by `finishDBRead`. `false` when
    /// nothing is in flight.
    public func cancelDBRead(paneId: String, at now: Date = Date()) -> Bool {
        var contents = dataSurface(paneId)
        guard let flight = contents.flight else { return false }
        contents.flight = nil
        contents.cancelledAfterMs = max(0, Int(now.timeIntervalSince(flight.since) * 1000))
        setDataSurface(paneId, contents)
        publishFlight(paneId)
        flight.cancel?()
        return true
    }

    /// Ends flight `token`. `true` only when it is still the pane's flight AND its scope is the
    /// active one — the caller writes the reply's rows into the active scope, and pane ids repeat
    /// across projects. A reply for a project switched away is dropped; that pane keeps its
    /// previous rows. A read made inside a dispatch — every one, since the registry homes each
    /// dispatch where it began (`ScopeRouting`) — lands there however the screen has moved: its
    /// active scope is that home. A landed read clears the last `cancelled after` line.
    public func finishDBRead(paneId: String, token: UUID) -> Bool {
        guard let home = dbFlightScope(paneId: paneId, token: token) else { return false }
        inScope(home) {
            var contents = dataSurface(paneId)
            contents.flight = nil
            contents.cancelledAfterMs = nil
            setDataSurface(paneId, contents)
            publishFlight(paneId)
        }
        return home == scope
    }

    /// Cancels the operator's db reads in flight in every scope of `organization` — called by an
    /// org switch before the window's clients are re-pointed, so a read the operator started in
    /// the org left cannot reach the incoming org's restarted process (Invariant 4). An agent's
    /// read goes through the client pinned to its own place and is left to land.
    public func cancelOperatorDBReads(inOrganization organization: String, at now: Date = Date()) {
        for entry in everyScope(DataSurfacePaneKind.self)
        where entry.scope.organization == organization && entry.contents.flight?.byAgent == false {
            inScope(entry.scope) { _ = cancelDBRead(paneId: entry.paneId, at: now) }
        }
    }

    /// Drops selected rows, the anchor and the scroll target that the new
    /// row count cannot support.
    ///
    /// **Why this is not a contradiction of "setRows leaves the selection
    /// alone"** (final review Finding 8). Preserving the selection across a
    /// refresh is deliberate and has tests: re-running the same query must
    /// not cost the operator what they had picked. But a *different* query
    /// leaves indices behind that index nothing — `read_pane` reporting
    /// `anchorRow: 480` on a three-row result is a claim about a row that
    /// does not exist, made to an LLM, and the surface would draw a
    /// luminous edge on nothing. What survives here is every index the new
    /// rows can actually carry, which on a re-run of the same query is all
    /// of them.
    ///
    /// **Dropped, not renumbered.** Pulling `480` down to `2` would say the
    /// operator selected the last row, which they did not. An index that no
    /// longer means anything is better absent than reassigned.
    ///
    /// An anchor that went out of range while some of its selected rows
    /// survived moves to the smallest survivor — the same rule
    /// `paneSelectionAfterClick` uses when a command-click removes the
    /// anchor: `rows` is a `Set`, so "the nearest row" has no cheaper a
    /// definition than "the smallest index that survived".
    private func clampToRowCount(_ contents: inout DataSurfaceContents) {
        let count = contents.displayRows.count
        if let target = contents.scrollTarget, target >= count { contents.scrollTarget = nil }

        let selection = contents.selection
        let surviving = selection.rows.filter { $0 < count }
        guard !surviving.isEmpty else {
            contents.selection = .empty
            return
        }
        let anchorRow = selection.anchorRow.map { $0 < count ? $0 : surviving.min() ?? $0 }
        contents.selection = PaneSelection(
            anchorRow: anchorRow, anchorColumn: selection.anchorColumn, rows: surviving)
    }

    /// Whether pane `paneId`'s most recent `setRows` reported a pageable
    /// result — `false` for a pane nothing has written to yet, exactly the
    /// same "unwritten is not special" default `snapshot(paneId:kind:)`
    /// already gives every other field of a data-surface pane.
    ///
    /// **Why `db_page` asks this before moving anything.** `refetchPane`
    /// forces `offset: 0` for `.tables`/`.columns` regardless of what
    /// `fetch.offset` says, so a pane showing a table list can already
    /// hold a `Pane.fetch.offset` a page move would silently disagree
    /// with. Checking here, before `db_page` calls `current.page(to:)` or
    /// `setFetch`, is what keeps that disagreement from ever being written.
    public func pageable(paneId: String) -> Bool {
        dataSurface(paneId).pageable
    }

    /// The sort `displayRows` is currently ordered by — the CACHED copy
    /// `reorder` and `setRows` write, not `Pane.fetch.sort`'s authority.
    /// `[]` for a pane nothing has written to yet.
    ///
    /// **What `pane_sort`'s handler builds its next candidate from (final
    /// review, Minor 6), instead of `Pane.fetch.sort`.** A non-pageable
    /// pane's `fetch.sort` is never written — `sortCanBeRecorded` is false
    /// for it, so `pane_sort`'s handler never calls `setFetch` — so every
    /// click was building its next term onto the SAME never-updated `[]`,
    /// discarding whatever the previous click had already recorded here.
    /// This field does not have that problem: `reorder` writes it on every
    /// call, recordable or not, so it always holds the sort the pane is
    /// actually showing.
    public func sort(paneId: String) -> [PaneSort] {
        dataSurface(paneId).sort
    }

    /// What the driver said about writing pane `paneId` back to, with its
    /// `rowKeys` in DISPLAY order — the same order `displayRows` is in, so
    /// a caller pairing `editable(paneId:)?.rowKeys[i]` with row `i` of
    /// what it drew always names that same row.
    public func editable(paneId: String) -> PaneEditable? { dataSurface(paneId).editable }

    /// Whether the rows a pane holds are only part of what its query
    /// matched — truncated, or a page past the first.
    ///
    /// **Both halves are needed and the second is the one the probe
    /// added.** `offset > 0` with `truncated` false is the LAST page of a
    /// paged result: complete as a page and a subset as an answer. Sorting
    /// it locally would order the last page and present it as the table.
    public func resultIsIncomplete(paneId: String) -> Bool {
        let contents = dataSurface(paneId)
        return contents.truncated || contents.offset > 0
    }

    public func setSelection(paneId: String, _ selection: PaneSelection) {
        var contents = dataSurface(paneId)
        contents.selection = selection
        setDataSurface(paneId, contents)
    }

    /// Records that this pane's last fetch failed, without disturbing the
    /// rows, offset or sort it already had.
    ///
    /// **D12.** `DBPane` drew "no rows" for this state because nothing
    /// distinguished it from an empty result — the fetch's failure was
    /// known, journalled, and then discarded by every caller with `_ =`.
    public func setFailure(paneId: String, message: String) {
        var contents = dataSurface(paneId)
        contents.failure = message
        setDataSurface(paneId, contents)
    }

    /// Why this pane's last fetch or shell failed, whatever kind it is.
    ///
    /// **The pane's own kind answers (`PaneKind.failure(of:)`), not a route through `dataSurface(_:)`.**
    /// Routing through `dataSurface(_:)` answered `nil` for every terminal pane
    /// even though `TerminalContents` carries its own `failure` and
    /// `snapshot(paneId:kind:)` has always read it correctly — latent
    /// while no terminal pane could exist, and wrong the moment one could.
    public func failure(paneId: String) -> String? {
        guard let slot = panes[paneId] else { return nil }
        return slotFailure(slot.kind, slot.contents)
    }

    /// Re-orders a pane's rows by `sort` without re-fetching them.
    ///
    /// **This is the client-side branch of spec §7 and only that.** It is
    /// the correct answer when every row that matches is already in hand:
    /// ordering them locally produces exactly what the engine would
    /// return, without a round trip. When the result is a subset, the
    /// caller re-fetches instead (`pane_sort`'s handler in
    /// `StandardActions.swift`, which is what actually makes the
    /// complete-vs-incomplete decision) and this is not called at all.
    ///
    /// **It is not the sort's home.** `Pane.fetch.sort` is; this writes the
    /// cached copy that `displayRows` was produced from and that `snapshot`
    /// reports, and its callers write the authority first.
    public func reorder(paneId: String, sort: [PaneSort]) {
        var contents = dataSurface(paneId)
        contents.sort = sort
        reorder(&contents)
        setDataSurface(paneId, contents)
    }

    /// Refreshes `displayRows` from `rows` and `sort`.
    ///
    /// **The sort happens here, at the store, and nowhere else.** Until
    /// the 2c-i final review it happened only in the view's projection
    /// (`WindowModel.refreshPanes` → `PaneTable.sorted()`), so `snapshot`
    /// — and therefore `read_pane` — reported rows in insertion order
    /// while `selection.rows` and `scrollTarget` indexed the sorted order
    /// the operator could see. An agent that sorted a pane and then asked
    /// for "row 0" named a row nobody else meant. One ordering, produced
    /// once, read by both.
    private func reorder(_ contents: inout DataSurfaceContents) {
        // One permutation, computed once, applied to both things a
        // client-side sort has to move together: `rows` and — if this
        // pane has any — the keys that name where each row writes back to.
        // Computing `displayRows` from `sortedRows` and separately
        // re-deriving an ordering for `editable` would let the two drift,
        // which is exactly the wrong-row write this whole feature exists
        // to prevent, one layer below the layer that prevents it.
        let order = sortedRowOrder(contents.rows, by: contents.sort, columns: contents.columns)
        contents.displayRows = order.map { contents.rows[$0] }
        contents.editable = contents.sourceEditable?.reordered(by: order)
    }

    public func setScrollTarget(paneId: String, row: Int?) {
        var contents = dataSurface(paneId)
        contents.scrollTarget = row
        setDataSurface(paneId, contents)
    }

    /// Every pane id anything has been written to, sorted.
    ///
    /// Sorted rather than in dictionary order for the same reason
    /// `selection.rows` is: an agent diffing two reads must not see a
    /// change that is only the hash seed.
    public func paneIds() -> [String] { panes.keys.sorted() }

    /// What `read_pane` returns, and what the view draws from.
    ///
    /// **`kind` is supplied by the caller, because this store is not the
    /// registry of panes and `LayoutStore` is.** That correction is the
    /// whole of Decision 24's wiring: `MCPSurface` has held `layout`
    /// beside `panes` since 2b-i, and `readPane` was simply handed only
    /// one of the two. Pass `nil` for an id the layout does not hold and
    /// the answer is `kind: null` — not an error, because a pane can close
    /// between the `read_layout` that named it and the `read_pane` that
    /// asks, and an error there would turn a correct sequence of calls
    /// into a failure.
    ///
    /// **Every key of the answered kind is always present**, including
    /// when false, empty or null. That rule is unchanged in purpose since
    /// 2a and narrowed in scope: it used to describe ONE shape, and this
    /// is now a union, so it is scoped to the kind. `failure` is the one
    /// kind-independent key, because any pane can fail to produce what it
    /// was asked for.
    ///
    /// **A pane that exists and has never been written to is not
    /// contentless.** It answers with its own kind and an empty payload — the
    /// freshly launched window, drawing "no rows" before any query, is the
    /// common case of it (`PaneKind.emptySnapshot`). **Unless this build does
    /// not know its kind** (no entry in `kinds`, from `App/PaneKinds.swift`),
    /// which is no contents WITH a failure naming the kind; see `PaneKind`
    /// for why that is the honest answer and not an empty grid (#181).
    public func snapshot(paneId: String, kind: String?) -> PaneSnapshot {
        guard let kind else { return PaneSnapshot(kind: nil, failure: nil, contents: nil) }
        if let slot = panes[paneId] { return slotSnapshot(slot.kind, slot.contents, label: kind) }
        // A pane that exists and has never been written to answers with its own kind and an empty
        // payload of that kind. An unknown kind says so rather than answering as an empty grid.
        guard let paneKind = kinds.first(where: { $0.names.contains(kind) }) else {
            return PaneSnapshot(
                kind: kind,
                failure: "this build has no contents for a pane of kind \"\(kind)\"",
                contents: nil)
        }
        return emptySnapshot(paneKind, label: kind)
    }

    /// `read_pane`'s answer for one pane: the envelope every kind shares, plus the kind's own keys.
    ///
    /// **Built here, once, from the store's own snapshot**, so the agent's rows and the screen's
    /// rows are one sequence sorted once (2c-i final review, Finding 1). `failure` is the one
    /// kind-independent key, because any pane can fail to produce what it was asked for. The keys
    /// on the wire are the kinds' own, not Swift's type names (`GridSnapshot` became
    /// `DataSurfaceSnapshot` without changing one).
    public func readPane(paneId: String, kind: String?) -> JSONValue {
        let snapshot = snapshot(paneId: paneId, kind: kind)
        var object: [String: JSONValue] = [
            "kind": snapshot.kind.map { .string($0) } ?? .null,
            "failure": snapshot.failure.map { .string($0) } ?? .null,
        ]
        if let slot = panes[paneId] {
            object.merge(slotReadPane(slot.kind, snapshot.contents)) { _, kindKey in kindKey }
        } else if let kind, let paneKind = kinds.first(where: { $0.names.contains(kind) }) {
            object.merge(slotReadPane(paneKind, snapshot.contents)) { _, kindKey in kindKey }
        }
        return .object(object)
    }

    private func slotReadPane<K: PaneKind>(_ kind: K.Type, _ contents: (any PaneKindSnapshot)?) -> [String: JSONValue] {
        guard let typed = contents as? K.Snapshot else { return [:] }
        return K.readPane(typed, in: self)
    }
}
