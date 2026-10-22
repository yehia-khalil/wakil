import Foundation

// The api kind's store methods (pluggable pane kinds): same actor, same names as before.
extension PaneStore {
    /// The active scope's resolution generation. Moves whenever what its api panes' entries should
    /// resolve against may have changed: its environment switch (`clearApiResponses`) or an org
    /// change. A re-resolve captures it before asking `list_apis` and writes
    /// only if it has not moved (fix round 1). **Per scope** (`ApiShared.resolutionGenerations`):
    /// the active scope is the caller's own, so an agent's listing in its own place is judged by
    /// that place's generation, not the screen's.
    var apiResolutionGeneration: Int {
        var s = kindState(ApiPaneKind.self)
        let generation = s.resolutionGeneration(in: activeScope)
        setKindState(ApiPaneKind.self, s)
        return generation
    }

    /// The generation a re-resolve captures before it asks (`reresolveApis`).
    func apiResolutionMark() -> Int { apiResolutionGeneration }

    /// Who is listening for a send's flight to start or end (`apiFlights()`).
    var flightSubscribers: [UUID: AsyncStream<String>.Continuation] {
        get { kindState(ApiPaneKind.self).flightSubscribers }
        set { var s = kindState(ApiPaneKind.self); s.flightSubscribers = newValue; setKindState(ApiPaneKind.self, s) }
    }
    /// The api contents for `paneId`, or a fresh empty set — the third
    /// member of the pair above, on the same terms: a pane of another
    /// kind answers empty and has its write discarded rather than its
    /// contents silently corrupted.
    func api(_ paneId: String) -> ApiContents { contents(ApiPaneKind.self, paneId) }

    func setApi(_ paneId: String, _ contents: ApiContents) { setContents(ApiPaneKind.self, paneId, contents) }

    /// Records which api entry `paneId`'s draft targets, where that entry
    /// resolved to, and whether it has a credential configured.
    ///
    /// **`origin` is stored, not re-derived on read.** A snapshot is built
    /// on every change, for the screen as much as for `read_pane`, and
    /// resolving an entry means asking another process — so re-deriving it
    /// there would put an MCP call inside the draw loop. It cannot go stale
    /// across a switch: each environment is a scope of its own, so an origin
    /// is only ever read in the environment it was resolved for, and a canvas
    /// read off disk re-resolves it (`ApiPaneResolver.reresolve`).
    ///
    /// **`origin` may be nil, and that is the point.** A pane opened
    /// against an entry that does not resolve draws an empty origin in its
    /// URL line, which is the failure being visible before any send.
    public func openApi(
        paneId: String, entry: String, environment: String, origin: String?, credentialed: Bool,
        entries: [String] = []
    ) {
        var contents = api(paneId)
        // Re-pointing the draft is a write to it (Amendment 11a).
        if contents.draft.entry != entry { contents.forgetFill() }
        contents.draft.entry = entry
        contents.environment = environment
        contents.origin = origin
        contents.credentialed = credentialed
        // **Absent leaves what is there.** `--dispatch` and this module's
        // tests open a pane with no listing to hand, and emptying the list
        // would disable the chooser on a re-open that learned nothing new.
        if !entries.isEmpty { contents.entries = entries }
        setApi(paneId, contents)
    }

    /// The draft `paneId` is holding, for an action that is about to write
    /// a subset of its regions back.
    ///
    /// **Read-then-write rather than a per-region setter**, and #190's
    /// ruling is why: one action writes any subset of the regions, absent
    /// meaning unchanged, so the merge is the caller's and the store holds
    /// exactly one whole draft. Ten setters would be ten places to enforce
    /// one whole-draft rule that is about none of them.
    public func apiDraft(paneId: String) -> ApiDraft {
        api(paneId).draft
    }

    /// Amendment 11a: keeps the draft a cURL fill replaced, once, for **Undo**, with the line the
    /// fill left. **Called after the fill's own `setApiDraft`**, which forgets what was kept.
    public func keepApiDraft(paneId: String, _ draft: ApiDraft, line: String? = nil) {
        var contents = api(paneId)
        contents.kept = draft
        contents.fillLine = line
        setApi(paneId, contents)
    }

    /// The draft the last fill replaced, while it is still kept.
    public func apiKeptDraft(paneId: String) -> ApiDraft? { api(paneId).kept }

    /// The line the last fill left on this pane, while its draft is still kept.
    public func apiFillLine(paneId: String) -> String? { api(paneId).fillLine }

    /// Forgets what a fill kept, and its line.
    public func forgetApiKeptDraft(paneId: String) {
        guard holds(ApiPaneKind.self, paneId) else { return }
        var contents = api(paneId)
        contents.forgetFill()
        setApi(paneId, contents)
    }

    /// Replaces `paneId`'s draft request entirely, and with it what the
    /// draft's entry resolved to when the caller re-pointed it.
    ///
    /// **Entirely, because the merge already happened.** `api_set_request`
    /// reads the draft, overwrites the regions it was given and writes the
    /// result back; a store that also merged would be a second answer to
    /// what "absent" means.
    ///
    /// **One write, and `resolution` is why it is one.** Re-pointing the
    /// entry moves the origin and the credential with it — and the
    /// credential decides whether the header region has an `authorization`
    /// row at all — so a second call for those would leave a moment where
    /// the draft names `auth` and the region is still drawn against
    /// `billing`'s credential. `nil` means the entry did not change and
    /// what it resolved to is kept.
    /// **A landed write clears no mark, and that is Decision 27's own
    /// clearing rule rather than an omission** (#191 review). The marks
    /// are the surface's, maintained by content: a field the operator
    /// committed is rendered into and then reads as what was rendered, so
    /// it goes clean on its own, one field at a time. A store that dropped
    /// the marks of every field a call NAMED would be a second clearing
    /// path — and a wrong one, because `query` and `headers` are written
    /// entire: adding one query row would have cleared the mark on a
    /// different row the operator was still typing in, and handed the next
    /// agent write the very field this rule exists to protect.
    public func setApiDraft(
        paneId: String, draft: ApiDraft, resolution: (origin: String?, credentialed: Bool)? = nil
    ) {
        var contents = api(paneId)
        // Amendment 11a: any write to the draft forgets what a fill kept. The fill itself writes
        // first and keeps after (`keepApiDraft`).
        contents.forgetFill()
        contents.draft = draft
        if let resolution {
            contents.origin = resolution.origin
            contents.credentialed = resolution.credentialed
        }
        setApi(paneId, contents)
    }

    /// Replaces `paneId`'s response.
    ///
    /// **Replaced, never appended to.** One request, one reply: the
    /// response is the bottom of the request's own surface and not a log
    /// that grows.
    public func setApiResponse(paneId: String, response: ApiResponseSnapshot) {
        var contents = api(paneId)
        contents.response = response
        setApi(paneId, contents)
    }

    /// Clears every api pane's response, because the environment changed.
    ///
    /// **The reply on screen describes the environment we just left**
    /// (D11's argument, applied to this pane kind): a 200 from staging
    /// sitting under a pane that is now pointed at production is a record
    /// attributed to the wrong environment, which spec story 15 exists to
    /// prevent.
    ///
    /// **`.cleared` rather than `.none`.** A pane reset to `.none` reads
    /// as one that has never sent; this says what happened, and names the
    /// environment it happened for.
    ///
    /// **A pane that has never sent is left at `.none`** — there is
    /// nothing to clear, and saying "cleared" about it would invent a
    /// history it does not have.
    ///
    /// **The draft is kept and nothing is sent.** A switch that re-sent
    /// would put an unattended request on the wire in the new
    /// environment, which is the one thing this must never do.
    public func clearApiResponses(to environment: String) {
        // Fix round 1: every re-resolve begun before this, in this scope, answers for the
        // environment left. Other scopes' environments did not change.
        var shared = kindState(ApiPaneKind.self)
        shared.bumpResolution(in: activeScope)
        setKindState(ApiPaneKind.self, shared)
        for paneId in paneKeys {
            guard holds(ApiPaneKind.self, paneId) else { continue }
            var contents = api(paneId)
            contents.environment = environment
            // **`origin` and `credentialed` are cleared, not kept.** Both
            // are the ENTRY's facts in the environment that was active
            // when they were resolved, and `ApiPaneResolver` re-resolves
            // them next, in `restorePaneContents`; until it answers, absent
            // is honest where stale is not. Keeping them draws staging's
            // origin beside a pane that now sends to production and
            // composes the `authorization` row from staging's answer: the
            // surface says one environment and the bytes go to the other.
            //
            // Cleared rather than recomputed because this store cannot
            // ask — resolving an entry is a `list_apis` round trip the
            // resolver owns.
            contents.origin = nil
            contents.credentialed = false
            // Same reasoning: the list belongs to the environment being
            // left, and a chooser offering it would re-point the draft at
            // an entry the new environment may not declare.
            contents.entries = []
            // **The write-back happens either way.** An early `continue`
            // here discarded the new environment for every pane that had
            // never sent, so `read_pane` reported the old one forever and
            // every later row was stamped with it.
            if case .none = contents.response {
                setApi(paneId, contents)
                continue
            }
            contents.response = .cleared(environment: environment)
            setApi(paneId, contents)
        }
    }

    /// Every api pane's entry, re-resolved against a new environment's listing (W1). The draft
    /// is kept and nothing is sent. Re-sending here would put an unattended request on the wire.
    ///
    /// **The active scope's panes**, as `clearApiResponses` before it: a scope left behind is
    /// re-resolved when it is next the active one and the environment next changes or launches.
    ///
    /// `restored` names api panes the canvas holds that this store may not — a pane restored
    /// from the layout at launch, whose draft was never persisted (W1, "at launch for panes
    /// restored from the layout"). Each is resolved like any other, from an empty draft.
    ///
    /// **`generation` is `apiResolutionGeneration` as it was BEFORE `list_apis` was asked**
    /// (fix round 1). `list_apis` names no environment and answers can arrive out of order, so a
    /// listing read before a later switch, a scope change or an org change describes a context
    /// this store has left: it is dropped, and the later switch's own re-resolve writes instead.
    /// Without this a stale answer stamped production's origin and credential on a pane the
    /// window says is on staging.
    ///
    /// **Returns `nil` when it wrote nothing** (a stale generation), else each pane whose entry
    /// the re-resolve changed, paneId → its new entry (W8: the resolver retitles those). A
    /// pane created here from `restored` is always in it, unpointed or not.
    @discardableResult
    func reresolveApis(
        environment: String, listing: [ApiEntryListing], restored: [String] = [],
        generation: Int? = nil
    ) -> [String: String]? {
        if let generation, generation != apiResolutionGeneration { return nil }
        var changed: [String: String] = [:]
        for paneId in Set(paneKeys).union(restored) {
            // **A pane just created from `restored` always counts as changed** (final review
            // I3): its title is the layout's, persisted from the entry it had, and its draft was
            // not persisted. Left out, a pane that stays unpointed (`""` → `""`) kept `catalog`
            // over "pick an entry — staging declares 3".
            var fresh = false
            if !holdsContents(paneId: paneId), restored.contains(paneId) {
                setApi(paneId, ApiContents())
                fresh = true
            }
            guard holds(ApiPaneKind.self, paneId) else { continue }
            var contents = api(paneId)
            let resolved = apiReresolution(entry: contents.draft.entry, listing: listing)
            // Compared BEFORE the draft is written.
            if fresh || resolved.entry != contents.draft.entry { changed[paneId] = resolved.entry }
            contents.environment = environment
            if resolved.entry != contents.draft.entry { contents.forgetFill() }
            contents.draft.entry = resolved.entry
            contents.origin = resolved.origin
            contents.credentialed = resolved.credentialed
            contents.entries = listing.map(\.name)
            setApi(paneId, contents)
        }
        return changed
    }

    /// An API entry was renamed: every api pane of the active scope whose draft targets `old`
    /// now targets `new` (2e-iii). Stashed scopes re-resolve on return.
    /// Answers the panes it re-pointed, for the caller to retitle (W8).
    @discardableResult
    func renameApiEntry(from old: String, to new: String) -> [String] {
        var touched: [String] = []
        for paneId in Array(paneKeys) where holds(ApiPaneKind.self, paneId) {
            var contents = api(paneId)
            guard contents.draft.entry == old else { continue }
            contents.draft.entry = new
            setApi(paneId, contents)
            touched.append(paneId)
        }
        return touched
    }

    // MARK: - A send in flight (W14)

    /// The id of every api pane whose send STARTS or ENDS (preflight F1).
    ///
    /// **Why the store and not the registry.** The window re-reads panes when a dispatch
    /// finishes (`ActionRegistry.dispatches()`), and a send's flight is the whole length of its
    /// own dispatch: it starts after that dispatch began and ends just before it finishes. So no
    /// dispatch boundary falls while a send is in flight, and Send could never read Cancel. The
    /// start and the end are this store's own facts, so this store announces them.
    ///
    /// `bufferingNewest(1)` for the reason `dispatches()` gives: a wake-up, not a log.
    public func apiFlights() -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let key = UUID()
            flightSubscribers[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribeApiFlights(key) }
            }
        }
    }

    func unsubscribeApiFlights(_ key: UUID) { flightSubscribers[key] = nil }

    /// For tests: how many `apiFlights()` streams are listening. A window subscribes from a
    /// `Task` started in its `init`, so a flight begun straight after constructing one can be
    /// announced before anything is listening.
    var apiFlightSubscriberCount: Int { flightSubscribers.count }

    func publishFlight(_ paneId: String) {
        for continuation in flightSubscribers.values { continuation.yield(paneId) }
    }

    /// The scope holding the flight named `token` on `paneId`: the active one first, then any
    /// other. `nil` when no scope holds it any more (every scope was cleared, an org change).
    func flightScope(paneId: String, token: UUID) -> LayoutScope? {
        scope(holding: ApiPaneKind.self, paneId: paneId) { $0.flight?.token == token }
    }

    /// Starts a send on `paneId` and names it, or answers `nil` when one is already in flight.
    /// The token is what `armApiSend` and `finishApiSend` match on.
    public func beginApiSend(paneId: String, method: String, at since: Date, byAgent: Bool = false) -> UUID? {
        var contents = api(paneId)
        guard contents.flight == nil else { return nil }
        // Amendment 11a: a Send forgets what a fill kept, AT THE PRESS — Undo after it would put
        // back a draft from before a request already sent. Not at the reply: a fill made while
        // this send is in flight keeps its Undo when the reply lands. A refused send never gets
        // here, so it forgets nothing.
        contents.forgetFill()
        let token = UUID()
        contents.flight = ApiFlight(
            token: token, since: since, method: method, environment: contents.environment,
            credentialed: contents.credentialed, byAgent: byAgent)
        setApi(paneId, contents)
        publishFlight(paneId)
        return token
    }

    /// Hands the flight `token` its canceller. A cancel that arrived first is honoured now.
    public func armApiSend(paneId: String, token: UUID, cancel: @escaping @Sendable () -> Void) {
        guard let home = flightScope(paneId: paneId, token: token) else { return }
        let honour = inScope(home) { () -> Bool in
            var contents = api(paneId)
            guard var flight = contents.flight else { return false }
            flight.cancel = cancel
            contents.flight = flight
            setApi(paneId, contents)
            return flight.cancelRequested
        }
        if honour { cancel() }
    }

    /// Cancels the send in flight on `paneId` in the ACTIVE scope — the pane the operator and
    /// the agent can see. `false` when there is none, which `api_cancel` refuses.
    public func cancelApiSend(paneId: String) -> Bool {
        var contents = api(paneId)
        guard var flight = contents.flight else { return false }
        flight.cancelRequested = true
        contents.flight = flight
        setApi(paneId, contents)
        flight.cancel?()
        return true
    }

    /// Cancels the operator's api sends in flight in every scope of `organization` — called by
    /// an org switch before the window's clients are re-pointed (final review minor 9). A send
    /// suspends between its flight starting and its call reaching `wakil-http`, so one the
    /// operator made in the org left could otherwise go out on the incoming org's restarted
    /// process, resolving its entry against that org's environments and credentials
    /// (Invariant 4). An agent's send goes through the client pinned to its own place and is
    /// left to land. The cancel is the operator's own Cancel: a mutation already sent reads as
    /// fate-unknown, never as not sent.
    public func cancelOperatorApiSends(inOrganization organization: String) {
        for entry in everyScope(ApiPaneKind.self)
        where entry.scope.organization == organization && entry.contents.flight?.byAgent == false {
            inScope(entry.scope) { _ = cancelApiSend(paneId: entry.paneId) }
        }
    }

    /// Ends the flight `token`. The response replaces the pane's **only while the environment is
    /// the one the send left in**. A reply from staging must not sit under a pane cleared for
    /// production (Review Focus 4). The send is recorded either way, under its own environment.
    ///
    /// **It lands in the scope the send left from**, found by its token, which is not always the
    /// active one: a project switch mid-flight moves the window on, and the reply belongs to the
    /// pane it was sent from — not to another scope's pane that happens to share its id. A
    /// flight no scope holds any more lands nowhere, rather than conjuring an api pane.
    public func finishApiSend(paneId: String, token: UUID, outcome: ApiRequestOutcome) {
        guard let home = flightScope(paneId: paneId, token: token) else { return }
        inScope(home) {
            var contents = api(paneId)
            let flight = contents.flight
            contents.flight = nil
            setApi(paneId, contents)
            if flight?.environment == contents.environment {
                setApiResponse(paneId: paneId, response: outcome.response)
            }
            // Inside `inScope(home)`, so the row is filed under the send's own project and the
            // environment it ran in (P15), whatever the window has moved to since.
            recordApiSend(
                paneId: paneId, draft: outcome.draft, response: outcome.response,
                cancelled: outcome.cancelled, shownPath: outcome.shownPath,
                credentialed: flight?.credentialed)
        }
        publishFlight(paneId)
    }

    /// How many rows one Recent list keeps — the project and environment's past tense (W15),
    /// shared by every api pane in it.
    ///
    /// **200, and dead with the session.** The cost of a longer strip is
    /// paid in memory for a surface that cannot search it; the cost of a
    /// shorter one is an operator losing the send they wanted to reopen.
    public static let recentCap = 200

    /// In memory, capped at `recentCap` per list, dead with the session. Persisting it is a
    /// decision of its own (Amendment 9c). Held in the api kind's store-wide state (`ApiShared`).
    var apiRecent: [ApiRecentKey: ApiRecentList] {
        get { kindState(ApiPaneKind.self).recent }
        set { var s = kindState(ApiPaneKind.self); s.recent = newValue; setKindState(ApiPaneKind.self, s) }
    }

    /// The key for `environment` in the ACTIVE scope — which `finishApiSend` has set to the
    /// send's own home scope by the time it records.
    func recentKey(_ environment: String) -> ApiRecentKey {
        ApiRecentKey(
            organization: activeScope.organization, project: activeScope.project, environment: environment)
    }

    /// One api pane's snapshot: its own contents, the shared Recent for its environment, and
    /// its bound values resolved against the panes on screen now (W18).
    func apiSnapshot(of contents: ApiContents) -> ApiSnapshot {
        let list = apiRecent[recentKey(contents.environment)] ?? ApiRecentList()
        return contents.snapshot(
            recent: list.rows, recentTruncated: list.truncated,
            bound: { request in
                // No bound part, no rows: skip reading every grid on screen.
                guard apiHasBoundPart(request) else { return [] }
                return apiBoundValues(in: request, sources: self.apiSources())
            })
    }

    /// Records one send in the project and environment's past tense (W15), if it had an
    /// outcome — filed under the environment it ran in, which every api pane of this project in
    /// that environment reads. `paneId` names the pane it was sent from; the row is not its.
    ///
    /// **A row joins only when the send had an OUTCOME.** A refusal never
    /// does: nothing was sent, and a history of things that never happened
    /// is not a history. A transport failure and a fate-unknown do —
    /// something left, or may have, and that is exactly what an operator
    /// needs to see later.
    ///
    /// **Newest first**, because the strip is read from the top and the
    /// send just made is the one being looked for.
    ///
    /// **The draft is kept on the row** so `api_reopen` can put it back
    /// without re-deriving it from a rendered string — a path rendered for
    /// a human cannot be parsed back into parts, and parsing one would be
    /// the delimiter this whole pane exists without.
    public func recordApiSend(
        paneId: String, draft: ApiDraft, response: ApiResponseSnapshot, cancelled: Bool = false,
        shownPath: String? = nil, credentialed: Bool? = nil
    ) {
        // The sending pane's credential, unless the flight carried the one it left with.
        let credentialed = credentialed ?? api(paneId).credentialed
        let status: Int?
        let millis: Int?
        let environment: String
        switch response {
        case .refusal, .none, .cleared:
            // Nothing left, so there is nothing to remember.
            return
        case .ok(let reply):
            status = reply.status
            millis = reply.durationMs
            environment = reply.environment
        case .transport(let failure):
            status = nil
            millis = failure.waitedMs
            environment = failure.environment
        case .unknown(let record):
            status = nil
            millis = nil
            environment = record.environment
        case .cancelled(let cancelled):
            // A cancelled read: it left, and the operator stopped waiting for it (W14).
            status = nil
            millis = cancelled.waitedMs
            environment = cancelled.environment
        }
        let key = recentKey(environment)
        var list = apiRecent[key] ?? ApiRecentList()
        list.rows.insert(
            ApiRecentRow(
                method: draft.method,
                entry: draft.entry,
                environment: environment,
                path: apiRenderedPath(draft.path),
                // Only an `ok` knows what left; a failure and a fate
                // unknown cannot say, and must not guess.
                sentUrl: { if case .ok(let reply) = response { return reply.url } else { return nil } }(),
                status: status,
                durationMs: millis,
                draft: draft,
                cancelled: cancelled,
                shownPath: shownPath,
                credentialed: credentialed),
            at: 0)
        if list.rows.count > Self.recentCap {
            list.rows.removeLast(list.rows.count - Self.recentCap)
            // A short history and a trimmed one must never look alike.
            list.truncated = true
        }
        apiRecent[key] = list
    }

    /// Puts a past send's draft back, by **row id and never by index**.
    ///
    /// **Keyed, on the terminal scroll action's precedent.** The strip is
    /// newest-first under a cap that trims from the end, so every row's
    /// position changes on every send — an index would reopen whatever had
    /// moved into that slot, which is a request the operator did not pick.
    /// A row that has been trimmed away returns `nil` rather than the
    /// nearest survivor.
    ///
    /// **It always lands, even while the operator's cursor is in a field,
    /// and this is the one place in the pane where that is true.** Decision
    /// 27 stops one author overwriting the field under the other's hand; reopening is
    /// the operator's OWN whole-draft gesture, so refusing it would mean
    /// refusing them their own click on the grounds that they had been
    /// typing. `api_bind` and `api_unbind` are refused there precisely
    /// because they can be an agent's.
    ///
    @discardableResult
    public func reopenApiRow(paneId: String, rowId: String) -> ApiDraft? {
        reopenApiRow(paneId: paneId, rowId: rowId, listing: nil)
    }

    /// **`listing` is the environment's `list_apis` answer, read by `api_reopen` when the row
    /// targeted another entry** (final review I1), and `generation` is `apiResolutionMark()` as
    /// it was before that read. The row's entry is resolved against it as `api_set_request`'s
    /// `entry` is, so the origin and the credential follow the entry the row brings. A listing
    /// overtaken by a switch, a failed read (`nil`) or no client clears them instead.
    @discardableResult
    func reopenApiRow(
        paneId: String, rowId: String, listing: [ApiEntryListing]?, generation: Int? = nil
    ) -> ApiDraft? {
        var contents = api(paneId)
        // W15: from the shared list for this pane's environment, into THIS pane's draft.
        guard let row = apiRecent[recentKey(contents.environment)]?.rows
            .first(where: { $0.id == rowId }) else { return nil }
        // **A row that targeted another entry takes that entry with it,
        // and this pane's origin belongs to a different one.** Reopening
        // restores `entry`, so keeping `origin` would draw one entry's
        // host beside another entry's draft. Resolved from `listing` when
        // the caller read a current one; otherwise cleared, for the same
        // reason the environment switch clears it: absent is honest where
        // stale is not.
        if row.draft.entry != contents.draft.entry {
            if let listing, generation == nil || generation == apiResolutionGeneration {
                let resolved = apiReresolution(entry: row.draft.entry, listing: listing)
                contents.origin = resolved.origin
                contents.credentialed = resolved.credentialed
                contents.entries = listing.map(\.name)
            } else {
                contents.origin = nil
                contents.credentialed = false
            }
        }
        contents.forgetFill()
        contents.draft = row.draft
        setApi(paneId, contents)
        return row.draft
    }

    /// `paneId`'s response, for a caller that needs to read it back.
    public func apiResponse(paneId: String) -> ApiResponseSnapshot { api(paneId).response }

    /// Records which fields the cursor is in, unless `generation` is older than the last one
    /// recorded. The surface counts its focus changes, and a release queued behind a write can
    /// arrive after the cursor has already moved on.
    ///
    /// **The surface chain's setter** (`WindowModel.enqueueApiFocus`), so it lands in the order
    /// the pane made its calls. A focus-in noted at once (`addApiFocus`) at or before
    /// `generation` is settled by it.
    public func setApiFocus(paneId: String, fields: Set<ApiDraftField>, generation: Int) {
        var contents = api(paneId)
        guard generation >= contents.focusGeneration else { return }
        contents.focused = fields
        contents.focusGeneration = generation
        contents.arriving = contents.arriving.filter { $0.key > generation }
        setApi(paneId, contents)
    }

    /// Marks `fields` **at once, on top of what the chain holds** (preflight F6): the cursor
    /// arriving in a field refuses an agent from the first instant, and the field it came from
    /// stays marked until the chain, behind that field's flush, sets the new focus. Ignored when
    /// the chain has already set `generation` or later.
    public func addApiFocus(paneId: String, fields: Set<ApiDraftField>, generation: Int) {
        var contents = api(paneId)
        guard generation > contents.focusGeneration else { return }
        contents.arriving[generation] = fields
        setApi(paneId, contents)
    }

    /// What `apiDraftCollisions` reads, and nothing else. **Not published**, because `read_pane`
    /// reports the screen, not where the cursor is.
    public func apiFocus(paneId: String) -> Set<ApiDraftField> {
        let contents = api(paneId)
        return contents.arriving.values.reduce(contents.focused) { $0.union($1) }
    }

    /// What `paneId` would publish as an api pane.
    ///
    /// **Not optional, and not a second `snapshot(paneId:kind:)`.** A pane
    /// of another kind answers with a fresh empty draft on `api(_:)`'s own
    /// terms; the callers that must not reach that are refused at the
    /// action layer by kind, where every other pane-kind refusal already
    /// lives. Inventing a failure here would be a second place to get that
    /// answer from.
    public func apiSnapshot(paneId: String) -> ApiSnapshot {
        apiSnapshot(of: api(paneId))
    }

    /// This pane as a bound value resolves against it, or `nil` when it
    /// holds no result at all.
    ///
    /// **The UNSORTED rows, deliberately.** Resolution finds a row by its
    /// key column values and never by position (#112), so the order is
    /// irrelevant to it — and passing the displayed order would invite a
    /// future reader to index into it.
    /// **An OPEN pane that holds no result yet is still a source**, and
    /// returning `nil` for one was wrong. `resolvePart` distinguishes a
    /// pane that is closed from one that has not re-fetched — "Rows are
    /// never persisted, so a pane that holds no result at all has not
    /// re-fetched yet" — and it can only do so if the empty pane reaches
    /// it. Omitting it made every binding from it report *"came from a
    /// pane that is closed … Re-bind it from a grid that is open"* about a
    /// grid that was open, and made that branch unreachable in production.
    ///
    /// `nil` now means what it says: this pane is not a data surface.
    public func sourcePane(paneId: String) -> ApiSourcePane? {
        guard holds(DataSurfacePaneKind.self, paneId) else { return nil }
        let contents = dataSurface(paneId)
        return ApiSourcePane(
            columns: contents.columns, rows: contents.rows, generation: contents.generation)
    }

    /// Every pane that a bound value could resolve against, keyed by id.
    ///
    /// **All of them, not the one a binding names.** A draft may hold
    /// values from several panes, and `resolvePart` looks each up by its
    /// own recorded pane id; handing it one pane would resolve one
    /// binding and report every other as coming from a closed pane.
    public func apiSources() -> [String: ApiSourcePane] {
        var sources: [String: ApiSourcePane] = [:]
        for paneId in paneKeys {
            if let source = sourcePane(paneId: paneId) { sources[paneId] = source }
        }
        return sources
    }

    /// The payload of a drop: one row of this pane, with everything a
    /// binding pins.
    ///
    /// **`row` indexes what is ON SCREEN.** The operator drags the row
    /// they can see, and `displayRows` is that order — reading the
    /// unsorted rows would bind a different booking from the one under
    /// the pointer whenever the grid is sorted.
    ///
    /// **`nil` rather than an empty drop** when the pane holds no result
    /// or the index is not one of its rows: a drop that cannot name a row
    /// has nothing to bind, and inventing an empty one would produce a
    /// binding with invented provenance.
    public func dropSource(paneId: String, row: Int) -> ApiDropSource? {
        let contents = dataSurface(paneId)
        guard !contents.columns.isEmpty, contents.displayRows.indices.contains(row) else {
            return nil
        }
        let editable = contents.editable
        return ApiDropSource(
            pane: paneId,
            table: editable?.table ?? "",
            keyColumns: editable?.keyColumns ?? [],
            columns: contents.columns,
            columnTypes: contents.columnTypes,
            row: contents.displayRows[row],
            generation: contents.generation,
            // **The driver decides, and nothing here second-guesses it.**
            // `editable` is `nil` exactly when the driver named no table
            // and no key columns — a join, most often — and a row with no
            // stable identity cannot be re-read by key, so a value taken
            // out of one is held rather than resolved live (#112).
            editable: editable != nil)
    }
}
