import Foundation

/// Thrown by `ActionRegistry.dispatch` for every way a dispatch can fail to
/// run the handler. Each case's associated `String` is the action name, so
/// a caller (or a test) can distinguish "action doesn't exist" from "this
/// action exists but was refused" without parsing a message string.
public enum ActionError: Error, Equatable {
    case unknown(String)
    case needsConfirmation(String)
    case blockedInProduction(String)
    /// Refused before anything ran because the caller is gone (conversations 3 of 3): a late call
    /// on a closed conversation's still-open connection (`setCallerRefusal`). `reason` is the
    /// whole sentence, beginning `"<action>: "`.
    case callerGone(String, reason: String)
    /// Refused before anything ran because the agent asked for an action only the operator may
    /// run: one registered `.operatorOnly`, or named in `operatorOnlyActions`. The permission
    /// prompt denies these first; this is the refusal that holds when it is not in the way.
    case operatorOnly(String)
}

/// **The operator reads these**, so they are sentences rather than the
/// enum's synthesized form.
///
/// `WindowModel.statusDescribingFailure` renders a failed dispatch into
/// `status` — and, for a query, into the failing pane itself in red. Without
/// this, the 2b-viii acceptance walk's production check put
/// `db_run_mutation: blockedInProduction("db_run_mutation")` in front of the
/// operator: a Swift case name, its payload quoted, and the action named
/// twice. `StandardActionError` has carried a `description` all along; this
/// type never did, and the two are read in exactly the same place.
///
/// **Each one begins `"<action>: "` deliberately.**
/// `statusDescribingFailure` asks whether a sentence already names its own
/// action and prepends the name only when it does not — so a description
/// reading "`db_run_mutation` is blocked in production" would be rendered
/// `db_run_mutation: db_run_mutation is blocked in production`. The prefix
/// form is what keeps that check satisfied.
///
/// **Blocked and gated say different things, because they are.** A `.gate`
/// refusal is an invitation: type `confirm` and it runs. A `.block` is not —
/// the handler is never reached in production, no confirmation exists that
/// would change that, and an operator who reads "blocked" as "confirm
/// harder" will hunt for a plane that is never going to appear. The wording
/// says so outright.
///
/// `MCPServer.jsonRPCError` states the same three facts over the wire with
/// its own codes, for a caller that parses rather than reads. Same
/// vocabulary, two audiences.
extension ActionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown(let name):
            return "\(name): no such action"
        case .needsConfirmation(let name):
            return "\(name): needs confirmation \u{2014} type confirm to run it"
        case .blockedInProduction(let name):
            return "\(name): blocked in production \u{2014} not gated, so no confirmation will run it"
        case .callerGone(_, let reason):
            return reason
        case .operatorOnly(let name):
            return "\(name): only the operator can run this \u{2014} the agent may not. "
                + "Ask the operator to do it in the Wakil window."
        }
    }
}

/// The single chokepoint every state change in Wakil passes through —
/// whether it was triggered by a UI control, the AI agent, or a debug
/// script. `dispatch` is the only way to run a registered action's handler.
///
/// Handlers are reachable only through `dispatch`: `all()` returns
/// `ActionDescriptor`, which has no executable member, and the executable
/// `Action` values (handler included) live in `actions`, a `private` stored
/// property of this actor. So the compiler rejects any ordinary expression
/// a caller could write — against anything this type returns — that would
/// run a registered action's handler directly. `dispatch` journals every
/// outcome it can produce, including an unrecognized name, so the journal
/// is a complete record of every attempt that went through that path.
///
/// This is a guard against accidental misuse, not a security boundary.
/// `Mirror(reflecting:)` can reach the stored properties of any Swift type,
/// actors included, and no design here can prevent that; `customMirror`
/// below only defeats the specific `Mirror(reflecting: registry)` walk a
/// reviewer used to recover `actions` during this task's review, by
/// reporting no children. A determined caller inside the same process can
/// still reach `actions` some other reflective way. The threat this type
/// actually defends against is a future developer — including whoever
/// writes the MCP server in a later task — reaching for the handler by
/// ordinary means; it does not defend against deliberate reflection abuse.
///
/// An actor, so registration and dispatch from concurrent callers (a UI
/// event and an in-flight agent turn, say) are serialized without a
/// separate lock.
public actor ActionRegistry {
    private var actions: [String: Action] = [:]

    /// The active project's production declarations (Decision 26, #182),
    /// handed to `writeGate` on every dispatch.
    ///
    /// **State on the registry rather than a `dispatch` parameter**, and
    /// that is the safety argument rather than convenience. `dispatch` has
    /// fifteen call sites in `WindowModel` alone; a parameter makes the
    /// gate's view of production a list somebody must keep in step, and the
    /// one call site that forgot it would silently price a production
    /// mutation as staging. One writer — `refreshContext`, which is the
    /// only place the active project can change — and one reader.
    ///
    /// `.undeclared` until the first context read, which is the name rule:
    /// a window that has not yet learned its project behaves as this
    /// build's predecessor did, not as though nothing were production.
    private var environmentProduction: EnvironmentProduction = .undeclared

    /// Called by `WindowModel.refreshContext` when the active project is
    /// read or re-read. Nothing else may set it.
    public func setEnvironmentProduction(_ production: EnvironmentProduction) {
        environmentProduction = production
    }

    /// The production declarations of an agent caller's own place (`pinnedPlace(of:)`): an
    /// agent session is priced by ITS project's flags, never by the ones on screen, even while
    /// the screen shows its place (background agents, 2 of 4). Nil from the lookup — or no
    /// lookup, as in `--dispatch` and in tests with no window — means `environmentProduction`
    /// applies.
    ///
    /// Installed by `WindowModel` when it is built, and nonisolated for that reason: its
    /// initialiser is synchronous. Read on every dispatch, before the gate.
    public nonisolated func setProductionLookup(
        _ lookup: @escaping @Sendable (DispatchCaller) async -> EnvironmentProduction?
    ) {
        productionLookup.set(lookup)
    }

    /// The scope a caller's dispatch reads and writes (background agents, 3 of 4): an agent
    /// session's own canvas, which need not be the one on screen. Bound around the handler as
    /// `ScopeRouting.home`. Nil from the lookup — or no lookup, as in `--dispatch` and in tests
    /// with no window — means the on-screen scope, which is every operator dispatch.
    ///
    /// Installed by `WindowModel`, nonisolated for `setProductionLookup`'s reason.
    public nonisolated func setScopeLookup(
        _ lookup: @escaping @Sendable (DispatchCaller) async -> LayoutScope?
    ) {
        scopeLookup.set(lookup)
    }

    /// The scope on screen, read at the start of every dispatch the scope lookup does not home
    /// elsewhere: the operator's own, `--dispatch`'s, an incomplete place's. Bound as
    /// `ScopeRouting.home` too, so a handler's writes after an await land in the canvas it
    /// began in however the screen moves meanwhile (background agents 3 of 4). Unset — a
    /// registry with no pane store — binds nothing, and the stores follow the screen.
    ///
    /// Installed by whoever holds the pane store the screen is read from:
    /// `registerStandardActions` and `WindowModel`. Nonisolated for `setProductionLookup`'s
    /// reason.
    public nonisolated func setScreenScope(_ screen: @escaping @Sendable () async -> LayoutScope) {
        screenScope.set { _ in await screen() }
    }

    /// Why a caller may not dispatch at all, read first on every dispatch (conversations 3 of
    /// 3): the window refuses a call from a session of a conversation since closed, which has no
    /// canvas to act on any more (Invariant 4). Nil — or no lookup — lets it through. The
    /// sentence is the whole refusal (`ActionError.callerGone`).
    ///
    /// Installed by `WindowModel`, nonisolated for `setProductionLookup`'s reason.
    public nonisolated func setCallerRefusal(
        _ lookup: @escaping @Sendable (_ action: String, _ caller: DispatchCaller) async -> String?
    ) {
        callerRefusal.set(lookup)
    }

    /// The hand-off of a caller's conversation, when it is handed (ticket noticing, Task 9), with
    /// May push as the gate prices it now: read before the gate for an agent's `.mutate` that a
    /// handed agent pays more for (`handedAgentPrice`), which then replaces the action's agent
    /// price. Nil — or no lookup, as in `--dispatch` and in tests with no window — is a caller not
    /// handed.
    ///
    /// Installed by `WindowModel`, nonisolated for `setProductionLookup`'s reason.
    public nonisolated func setHandedLookup(_ f: @escaping @Sendable (DispatchCaller) async -> PlaceAgentHandoff?) {
        handedLookup.set(f)
    }

    private nonisolated let handedLookup = CallerLookupBox<PlaceAgentHandoff>()
    private nonisolated let callerRefusal = CallerRefusalBox()
    private nonisolated let productionLookup = CallerLookupBox<EnvironmentProduction>()
    private nonisolated let scopeLookup = CallerLookupBox<LayoutScope>()
    private nonisolated let screenScope = CallerLookupBox<LayoutScope>()
    private let journalDirectory: URL
    private let sessionId: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var dispatchSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    /// `initialActions` seeds `actions` synchronously, inside `init`, rather
    /// than through a follow-up `await register(_:)` call. That matters for
    /// exactly one caller: `WindowModel.forTesting`, which is itself
    /// synchronous (its own tests call it with no `await`, on the main
    /// actor), so it has no `async` context in which to `await` this
    /// actor's `register(_:)` after construction. An `init` parameter is
    /// ordinary, non-isolated initialisation — legal before the actor's
    /// isolation boundary is even live — so `forTesting` can hand it a
    /// ready-made test double (Task 12: a `session_list` fixture) without
    /// becoming `async` itself and forcing every existing call site to grow
    /// an `await`.
    public init(journalDirectory: URL, sessionId: String, initialActions: [Action] = []) {
        self.journalDirectory = journalDirectory
        self.sessionId = sessionId
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        for action in initialActions { actions[action.name] = action }
    }

    public func register(_ action: Action) {
        actions[action.name] = action
    }

    /// The schema-only description of every registered action: name,
    /// description, kind, audience, and schema, but never the handler.
    /// This is the only way to enumerate registered actions from outside
    /// this actor, and it is deliberately incapable of yielding anything
    /// executable.
    ///
    /// **`audience` rides along because this is the only enumeration.**
    /// "Is every registered action classified?" is a question about the
    /// set of registrations, and this method is the one place that set is
    /// visible from outside. Without it on the descriptor the question
    /// would have no answer short of reading the source —
    /// `ActionClassificationTests` asks it here.
    public func all() -> [ActionDescriptor] {
        actions.values.map {
            ActionDescriptor(
                name: $0.name, description: $0.description, kind: $0.kind,
                audience: $0.audience, schema: $0.schema)
        }
    }

    /// One action's descriptor by name, or nil (3b-ix: the fast path checks params against it).
    public func descriptor(named name: String) -> ActionDescriptor? {
        all().first { $0.name == name }
    }

    /// The words the confirmation plane shows for a gated `name`, in one order for the operator's
    /// window and the agent's server alike: the action's own `describe` (which may ask a service
    /// where the write goes, and refuses by throwing), else Wakil's `confirmationDescription`, else
    /// the caller's own `statement` (SQL, an HTTP request). `own` says the words are the caller's,
    /// the only case `affectsEveryRow` is read from. Nil when there is nothing to show.
    ///
    /// **Wakil's words first.** A caller's `statement` beside a described action is ignored, so a
    /// stray one can never put other words on the plane than the ones the write carries.
    public func planeStatement(name: String, params: JSONValue, origin: ActionOrigin,
                               caller: DispatchCaller) async throws -> (text: String, own: Bool)? {
        if let describe = actions[name]?.describe {
            let text = try await Self.$dispatchOrigin.withValue(origin) {
                try await Self.$dispatchCaller.withValue(caller) { try await describe(params) }
            }
            return (text, false)
        }
        if let text = confirmationDescription(action: name, params: params) { return (text, false) }
        if case .object(let o) = params, case .string(let own)? = o["statement"], !own.isEmpty { return (own, true) }
        return nil
    }

    /// Runs `name`'s handler and returns its result, or throws without
    /// running it. Every outcome this method can produce — an unrecognized
    /// name, a gated refusal, an outright block, a handler that throws, or
    /// a handler that succeeds — is journalled before `dispatch` returns or
    /// throws.
    ///
    /// The order below is fixed and is the entire point of this method:
    ///
    /// 1. Look the action up. An unknown name journals `"unknown"` — using
    ///    the requested name as-is, since there is no registered action to
    ///    read a kind from — and throws `.unknown` without touching a
    ///    handler.
    /// 2. Consult `writeGate(environment:kind:origin:targetEnvironment:price:production:)`
    ///    before anything else runs, resolving the target environment out
    ///    of `params` first (see `targetEnvironment(of:in:)`), and passing
    ///    `price` as the action's own declared pair, defaulting to
    ///    `(.block, .gate)` — or, for a `.mutate` with a `callPrice`, that
    ///    call's own answer as both halves, asked once just before the gate.
    /// 3. `.block` journals `"blocked"` and throws `.blockedInProduction`
    ///    without going anywhere near the handler.
    /// 4. `.gate` without the exact confirmation string `"confirm"` journals
    ///    `"gated"` and throws `.needsConfirmation` without going anywhere
    ///    near the handler.
    /// 5. Only once the gate has cleared (`.allow`, or `.gate` with the
    ///    right confirmation) does the handler run, and its outcome —
    ///    `"ok"` or `"error"` — is journalled after it returns or throws.
    ///
    /// A handler that could run before step 2 would already have done the
    /// thing the gate exists to prevent.
    public func dispatch(
        name: String,
        params: JSONValue,
        origin: ActionOrigin,
        caller: DispatchCaller,
        confirmation: String?,
        asked: ActionProposal? = nil
    ) async throws -> JSONValue {
        guard let action = actions[name] else {
            try appendJournalEntry(action: name, params: params, origin: origin,
                                   caller: caller, outcome: "unknown",
                                   secretParams: nil)
            throw ActionError.unknown(name)
        }

        // An operator-only action is never the agent's, whatever let the call through.
        if origin == .agent, action.audience == .operatorOnly || operatorOnlyActions.contains(name) {
            try appendJournalEntry(action: name, params: params, origin: origin,
                                   caller: caller, outcome: "refused",
                                   secretParams: action.secretParams)
            throw ActionError.operatorOnly(name)
        }

        // A caller with nothing left to act for is refused before anything reads or writes.
        if let refusal = await callerRefusal.current()?(name, caller) {
            try appendJournalEntry(action: name, params: params, origin: origin,
                                   caller: caller, outcome: "refused",
                                   secretParams: action.secretParams)
            throw ActionError.callerGone(name, reason: refusal)
        }

        // An agent caller's own place's declarations; the window's otherwise.
        // Read before anything else runs, like the gate itself. A read is allowed whatever
        // they say, so it asks nothing.
        let lookup = action.kind == .read ? nil : productionLookup.current()
        let production = await lookup?(caller) ?? environmentProduction
        // 3c-ii: a `.mutate` that prices each call is asked once, before the gate, under the
        // handler's own task-locals and canvas (ruling C5a); its answer is the whole price. The
        // canvas it was priced in is the one the handler then runs in.
        let callPrice = action.kind == .mutate ? action.callPrice : nil
        var home: LayoutScope?
        var price = action.price
        var agentPrice = action.agentPrice
        if let callPrice {
            home = await self.home(of: caller)
            let priced = await bindingDispatch(origin: origin, caller: caller, home: home) {
                await callPrice(params, caller, origin)
            }
            price = (priced, priced)
            agentPrice = nil
        }
        // A handed agent's push, sync, publish, merge and rebase cost more; asked only for those.
        if origin == .agent, action.kind == .mutate, handedAgentPrice(name, mayPush: false) != nil,
           let handed = await handedLookup.current()?(caller) {
            agentPrice = handedAgentPrice(name, mayPush: handed.mayPush) ?? agentPrice
        }
        let decision = writeGate(
            environment: caller.place.environment,
            kind: action.kind,
            origin: origin,
            targetEnvironment: targetEnvironment(of: action, in: params),
            price: price,
            agentPrice: agentPrice,
            production: production)
        switch decision {
        case .block:
            try appendJournalEntry(action: name, params: params, origin: origin,
                                   caller: caller, outcome: "blocked",
                                   secretParams: action.secretParams)
            throw ActionError.blockedInProduction(name)
        case .gate:
            if confirmation != "confirm" {
                try appendJournalEntry(action: name, params: params, origin: origin,
                                   caller: caller, outcome: "gated",
                                   secretParams: action.secretParams)
                throw ActionError.needsConfirmation(name)
            }
        case .allow:
            break
        }

        do {
            // Bound by `bindingDispatch` and nowhere else: `dispatch` is the one place
            // that knows who asked. See `ActionRegistry.dispatchOrigin`.
            // The caller's own canvas, else the one on screen now — never whatever the screen
            // shows when the handler's later writes land. Already read if the call was priced.
            if callPrice == nil { home = await self.home(of: caller) }
            let result = try await ActionRegistry.$dispatchConfirmedGate.withValue(decision == .gate) {
                try await ActionRegistry.$dispatchAsked.withValue(asked) {
                    try await bindingDispatch(origin: origin, caller: caller, home: home) {
                        try await action.handler(params)
                    }
                }
            }
            try appendJournalEntry(action: name, params: params, origin: origin,
                                   caller: caller, outcome: "ok",
                                   secretParams: action.secretParams)
            publishDispatch(name)
            return result
        } catch ActionError.needsConfirmation(let gated) where gated == name {
            // 3c-ii: a handler found the consent it was priced on gone (a browser act whose site was
            // revoked since the price) and asks for the confirmation the call now costs: a gate.
            try appendJournalEntry(action: name, params: params, origin: origin,
                                   caller: caller, outcome: "gated",
                                   secretParams: action.secretParams)
            throw ActionError.needsConfirmation(name)
        } catch {
            try appendJournalEntry(action: name, params: params, origin: origin,
                                   caller: caller, outcome: "error",
                                   secretParams: action.secretParams,
                                   reason: Self.reason(for: error, params: params,
                                                       secretParams: action.secretParams))
            throw error
        }
    }

    /// The caller's own canvas, else the one on screen now.
    private func home(of caller: DispatchCaller) async -> LayoutScope? {
        if let own = await scopeLookup.current()?(caller) { return own }
        return await screenScope.current()?(caller)
    }

    /// Runs `body` under the three task-locals a handler runs under: who asked, the caller, and
    /// the canvas its writes land in. `dispatch` binds them here and nowhere else, for the handler,
    /// the call price and the action's own proposal alike.
    private func bindingDispatch<T: Sendable>(
        origin: ActionOrigin, caller: DispatchCaller, home: LayoutScope?,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await ActionRegistry.$dispatchOrigin.withValue(origin) {
            try await ActionRegistry.$dispatchCaller.withValue(caller) {
                try await ScopeRouting.$home.withValue(home) {
                    try await body()
                }
            }
        }
    }

    /// Whether `name` describes its own proposals (`Action.proposal`).
    public func declaresProposal(name: String) -> Bool { actions[name]?.proposal != nil }

    /// 3c-ii: `name`'s own description of this call for the confirmation plane, or nil when the
    /// action has none (or does not exist). Run under the task-locals and canvas `dispatch` would
    /// run its handler under for `caller` (ruling C5b), so a background agent's proposal names its
    /// own pane and site. Its only caller is the agent's park, so the origin bound is `.agent`.
    public func proposal(name: String, params: JSONValue, caller: DispatchCaller) async -> ActionProposal? {
        guard let propose = actions[name]?.proposal else { return nil }
        let home = await home(of: caller)
        return await bindingDispatch(origin: .agent, caller: caller, home: home) {
            await propose(params)
        }
    }

    /// The name of every action that actually **ran**, as it finishes.
    ///
    /// **What this is for.** A dispatch changes `PaneStore` or
    /// `LayoutStore`, and those are actors the view cannot await while
    /// rendering — so the window holds cached copies (`tables`,
    /// `layoutSnapshot`) and re-reads them after each of its own
    /// dispatches. A dispatch that did *not* come from the window — an
    /// agent's `tools/call`, or `--dispatch` — changed the same stores with
    /// nothing on screen to re-read them, so until the operator happened to
    /// click, a selection set by the agent was invisible (final review
    /// Finding 3). 2c-i's exit criterion is that a selection is "set
    /// identically by clicking and by the agent"; a selection only one of
    /// them can see does not meet it.
    ///
    /// **Why the registry and not the stores.** Invariant 2 says every
    /// state change goes through `dispatch`. So this is the one place that
    /// sees all of them, and subscribing here is one subscription rather
    /// than one per store plus one more for every store a later sub-phase
    /// adds. It also keeps the dependency direction as it was: nothing in
    /// `PaneStore` knows a view exists — a subscriber asks, and this actor
    /// answers.
    ///
    /// **Only `"ok"` outcomes are published.** An unknown name, a blocked
    /// action and a gated one never reached a handler, and a handler that
    /// threw is reported to its caller; none of them changed any store, so
    /// none is a reason to re-read one.
    ///
    /// `bufferingNewest(1)`, not the default unbounded buffer: a subscriber
    /// that is behind does not need to know how many dispatches it missed,
    /// only that it is out of date. This is a wake-up, not a log — the
    /// journal is the log.
    public func dispatches() -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let key = UUID()
            dispatchSubscribers[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribeDispatches(key) }
            }
        }
    }

    private func unsubscribeDispatches(_ key: UUID) { dispatchSubscribers[key] = nil }

    /// For tests: how many `dispatches()` streams are listening. A window subscribes from a
    /// `Task` started in its `init`, so a dispatch made straight after constructing one can be
    /// published before anything is listening, and a wake-up nobody heard is never repeated.
    var dispatchSubscriberCount: Int { dispatchSubscribers.count }

    private func publishDispatch(_ name: String) {
        for continuation in dispatchSubscribers.values { continuation.yield(name) }
    }

    /// Appends the one journal outcome `dispatch` cannot name for itself:
    /// `"uncertain"`, meaning a mutation was sent to a database and Wakil
    /// does not know whether it ran.
    ///
    /// **The deliberately narrow shape of this method is the whole of its
    /// design.** It takes no outcome string — it writes exactly one, and
    /// there is no way to reach `appendJournalEntry` from outside this
    /// actor for any other. So it is not a general back door into the
    /// audit log; it adds one specific fact that `dispatch` structurally
    /// cannot record.
    ///
    /// **Why `dispatch` cannot record it.** `dispatch` journals `"error"`
    /// whenever a handler throws, and it decides that without looking at
    /// which error was thrown — that indifference is what makes it a
    /// chokepoint rather than a policy engine, and it is not being changed.
    /// A mutation whose reply budget ran out throws like any other failure
    /// while meaning something else entirely: the statement was sent, the
    /// server was never told to stop, and it may well have committed. See
    /// `recordUncertainMutation`, which is the only caller.
    ///
    /// **Reading the journal.** That same action's `"error"` line always
    /// comes first, immediately followed by `"uncertain"` — because
    /// `dispatch` writes `"error"` the moment the handler throws, and only
    /// once `dispatch` has returned (by throwing) does its caller reach
    /// its own `catch` and append this line. The order is forced, not
    /// chosen: this method cannot run before `dispatch`'s write does. Read
    /// the pair together, the way `"gated"` → `"ok"` is read: the
    /// `"error"` is Wakil reporting that it stopped waiting, not evidence
    /// that the database did nothing.
    public func journalUncertainMutation(
        action: String, params: JSONValue, origin: ActionOrigin, caller: DispatchCaller
    ) throws {
        // The mark is looked up by name rather than taken from the caller,
        // for the same reason `dispatch` reads it off the registered
        // action: the caller here is `recordUncertainMutation`, which
        // holds the params it sent and no `Action` at all. An action that
        // is not registered — which this method cannot rule out, being
        // `public` — falls to the unknown path's rule, so the line beside
        // a redacted one is never the leak.
        try appendJournalEntry(action: action, params: params, origin: origin,
                               caller: caller, outcome: "uncertain",
                               secretParams: actions[action]?.secretParams)
    }

    /// Appends the line naming **the URL that actually left**, for a send
    /// that reached the wire (#194).
    ///
    /// **Forced rather than chosen, exactly as
    /// `journalUncertainMutation` is.** `api_send`'s gated `statement` is
    /// written *before* resolution — it has to be, because the operator
    /// confirms before anything is resolved — so no artefact `dispatch`
    /// writes can name what went on the wire. The dispatch line records
    /// params as the caller passed them, which for a draft built of parts
    /// is a pane id and a sentence. This is the only place the resolved
    /// URL exists.
    ///
    /// **Do not widen the dispatch journal to carry this instead.** That
    /// line records what was *asked*; this records what was *sent*, and
    /// collapsing them would lose the distinction that makes the pair
    /// readable — the same reason `"gated"` → `"ok"` is two lines.
    ///
    /// **Only when something left.** A refused send writes nothing here:
    /// there is no URL, and a line claiming one would record a request
    /// that never existed.
    ///
    /// **The accepted cost, stated rather than discovered.** A resolved
    /// path segment can carry a value out of a database cell, so it
    /// reaches an org-blind, unpruned file. Recording the parts alone
    /// would not have avoided it — a live part already carries its row's
    /// key values — and a record that cannot name what left is not a
    /// record of a send.
    public func journalSentRequest(
        action: String, params: JSONValue, origin: ActionOrigin, caller: DispatchCaller,
        url: String, outcome: String
    ) throws {
        var recorded: [String: JSONValue] = [:]
        if case .object(let fields) = params { recorded = fields }
        recorded["url"] = .string(url)
        try appendJournalEntry(
            action: action, params: .object(recorded), origin: origin,
            caller: caller, outcome: outcome,
            secretParams: actions[action]?.secretParams)
    }

    /// A handler's own second line after its dispatch's, for what the dispatch line cannot hold: what
    /// was asked is the dispatch's params, what was done is this (`ticket_hand_off`'s `started`
    /// line: the whole text Wakil sent, the operator's brief with what Wakil appended). The
    /// action's secret parameters are redacted here as in the dispatch line.
    public func journalFollowUp(
        action: String, params: JSONValue, origin: ActionOrigin, caller: DispatchCaller, outcome: String
    ) throws {
        try appendJournalEntry(
            action: action, params: params, origin: origin,
            caller: caller, outcome: outcome,
            secretParams: actions[action]?.secretParams)
    }

    /// 2d-ii: a turn whose text landed from speech. Carries no transcript —
    /// the turn itself is the agent's record; this line says only how it
    /// was entered.
    public func journalVoiceTurn(caller: DispatchCaller) throws {
        try appendJournalEntry(
            action: "voice_turn", params: .object(["via": .string("voice")]), origin: .ui,
            caller: caller, outcome: "ok", secretParams: [])
    }

    /// A connection call `wakil-connect` asked the app about, and how it was decided
    /// (`ConnectionApprovalServer`). Not a registered action; nothing it records is a credential —
    /// the arguments are the agent's own words — so its secret parameters are declared empty.
    public func journalConnectionCall(
        _ request: ConnectionCallRequest, outcome: String, caller: DispatchCaller
    ) throws {
        try appendJournalEntry(
            action: "connection_call", params: request.params, origin: .agent,
            caller: caller, outcome: outcome, secretParams: [])
    }

    /// 2d-i: a note handed to the agent, or a vocabulary source that
    /// failed. Not a registered action, so its secret parameters are
    /// declared here: **none**. Nothing it records is a credential, and the
    /// spec wants the note journalled whole. `nil` would mean "unknown
    /// action" to `redacting`, which keeps the keys and replaces every
    /// value with `[redacted]` — a record of a note nobody could read.
    public func journalIdentifierEvent(
        action: String, params: JSONValue, caller: DispatchCaller, outcome: String
    ) throws {
        try appendJournalEntry(
            action: action, params: params, origin: .ui,
            caller: caller, outcome: outcome, secretParams: [])
    }

    /// Names phase: one line per quick task that sends the operator's text out — `conversation_named`.
    /// Not an action, so its secret parameters are declared here: none. The params say where the text
    /// went and how much of it, never the words (they are in the transcript); the outcome is the
    /// result or the error whole.
    public func journalQuickTask(
        action: String, params: JSONValue, caller: DispatchCaller, outcome: String
    ) throws {
        try appendJournalEntry(
            action: action, params: params, origin: .ui,
            caller: caller, outcome: outcome, secretParams: [])
    }

    /// Appends the mint's own outcome line — the second fact `dispatch`
    /// structurally cannot record (#204).
    ///
    /// **Why the mint needs its own method rather than
    /// `journalUncertainMutation`.** Two reasons, and the first is a bug
    /// that method's shape would guarantee. The mint is deliberately NOT
    /// an action — it is a one-shot `wakil` verb Swift spawns — so its
    /// name is not in `actions`, so `secretParams` resolves to `nil`, so
    /// `redacting` takes the unknown-action branch and replaces EVERY
    /// value. The line would read `{"id":"[redacted]"}`: an audit record
    /// saying a credential may exist uncaught, and refusing to say for
    /// which account. Nothing here is secret — a provider credential is
    /// minted and stored in Go precisely so nothing travels — so the mark
    /// is stated as empty rather than inferred from an absence.
    ///
    /// And the mint owes a line on BOTH outcomes, because "minted and
    /// stored" and "a one-year credential exists that Wakil never caught"
    /// are the two facts the operator must be able to tell apart. The
    /// outcome string is the one that differs.
    ///
    /// Deliberately as narrow as `journalUncertainMutation`: two fixed
    /// outcomes, no caller-supplied string, and no route to
    /// `appendJournalEntry` for anything else.
    public func journalMintOutcome(
        id: String, stored: Bool, origin: ActionOrigin, caller: DispatchCaller
    ) throws {
        try appendJournalEntry(
            action: "provider_mint", params: .object(["id": .string(id)]),
            origin: origin, caller: caller,
            outcome: stored ? "minted" : "uncertain",
            // Empty, not nil: this call KNOWS nothing here is secret.
            secretParams: [])
    }

    /// Reads back every entry this registry's session has journalled so
    /// far, in the order they were written. Returns an empty array if
    /// nothing has been journalled yet — the journal directory and file are
    /// created lazily on the first `dispatch` call that needs to write an
    /// entry, not by `init`.
    public func journalEntries() throws -> [JournalEntry] {
        let url = journalFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(JournalEntry.self, from: Data($0.utf8)) }
    }

    /// The environment `action` will make active, read out of its own
    /// `params` — or `nil` when the action names no target (the usual
    /// case) or when the key it names is absent or not a string.
    ///
    /// A missing or non-string value resolves to `nil`, which
    /// `writeGate` treats as "not production" and therefore allows. That
    /// is safe here and would not be for a mutation: a `.control` action
    /// changes nothing outside Wakil, so the worst a malformed target can
    /// do is skip a confirmation on a switch that the handler is itself
    /// about to reject for the same malformed value.
    private func targetEnvironment(of action: Action, in params: JSONValue) -> String? {
        guard let key = action.targetEnvironmentParam,
              case .object(let object) = params,
              case .string(let value)? = object[key]
        else { return nil }
        return value
    }

    private func journalFileURL() -> URL {
        journalDirectory.appendingPathComponent("\(sessionId).jsonl")
    }

    /// `params` with every secret-bearing value replaced by `[redacted]`,
    /// the parameter's own name left in place.
    ///
    /// **`secretParams` is `nil` for one caller and one only** — the
    /// unknown-action-name path, which has no registered action and
    /// therefore no mark to read. That path wrote `params` verbatim, which
    /// made it the single dispatch path capable of journalling a secret in
    /// the clear from the first secret-bearing action onward: a near miss
    /// on the name (`db_set_dsnn`) is enough, and the caller still sends
    /// the DSN. The close available without a registry-wide list of
    /// parameter names — which would be byte-matching by another route —
    /// is to redact **every** value and keep every key. The attempt stays
    /// legible as an attempt: who asked, under what name, with which
    /// parameters, and none of it worth anything to a reader of the file.
    ///
    /// **Top level only, and that is the contract rather than an
    /// omission.** An action's parameters are a flat object — every schema
    /// in the registry says so — and a mark names one of its keys. A
    /// recursive search for the key at any depth would redact an unrelated
    /// nested field that happens to share the name, which is the
    /// byte-matching failure mode wearing a different hat. A marked action
    /// whose params are not an object has no position to redact, so the
    /// whole value goes: an unredactable shape must not fall through to
    /// verbatim.
    /// Decision 35 (#323): why a handler failed — the sentence it threw, which
    /// the pane shows and the agent is sent. **A byte search, unlike
    /// `redacting`**: the sentence is a blob this registry did not compose, so
    /// each marked parameter's string value is looked for and replaced. A
    /// secret the handler re-encoded before quoting is not found; Go's own
    /// scrubber is what keeps those out of its messages. Capped at 300
    /// characters so one runaway message cannot swell the journal.
    static func reason(for error: Error, params: JSONValue, secretParams: Set<String>) -> String {
        var sentence = String(describing: error)
        if case .object(let object) = params {
            for name in secretParams {
                if case .string(let secret)? = object[name], !secret.isEmpty {
                    sentence = sentence.replacingOccurrences(of: secret, with: redactedPlaceholder)
                }
            }
        }
        return sentence.count <= 300 ? sentence : String(sentence.prefix(300)) + "…"
    }

    private static func redacting(_ params: JSONValue, secretParams: Set<String>?) -> JSONValue {
        // `.null` is the absence of parameters, not a parameter whose
        // value is withheld. Replacing it would put `[redacted]` in front
        // of a reader where nothing was ever sent — a claim that a secret
        // existed, which is its own kind of false record.
        if case .null = params { return params }

        guard let secretParams else {
            // Unknown action: keys survive, every value goes.
            guard case .object(let object) = params else { return .string(redactedPlaceholder) }
            return .object(object.mapValues { _ in .string(redactedPlaceholder) })
        }
        guard !secretParams.isEmpty else { return params }
        guard case .object(let object) = params else { return .string(redactedPlaceholder) }
        var redacted = object
        for key in secretParams where redacted[key] != nil {
            redacted[key] = .string(redactedPlaceholder)
        }
        return .object(redacted)
    }

    /// What a redacted value reads as. A literal rather than an empty
    /// string or a dropped key, so that a reader of the journal can tell
    /// "this was a secret and is not recorded" from "this was absent".
    static let redactedPlaceholder = "[redacted]"

    private func appendJournalEntry(
        action: String,
        params: JSONValue,
        origin: ActionOrigin,
        caller: DispatchCaller,
        outcome: String,
        secretParams: Set<String>?,
        reason: String? = nil
    ) throws {
        let entry = JournalEntry(
            id: UUID().uuidString,
            ts: Date(),
            action: action,
            params: Self.redacting(params, secretParams: secretParams),
            origin: origin,
            // Absent means unset, never the empty string: a caller with no
            // organisation, project or session (the `--dispatch` runner, the
            // vocabulary store's reports) journals nothing for it.
            //
            // `environment` is the exception, and deliberately: every line
            // since 2026-09-10 records it, `""` for "none active", so an absent
            // key keeps meaning "written before environments were journalled"
            // (`JournalEntry.environment`). Dropping `""` would blur the two.
            organization: caller.place.organization.nilIfEmpty,
            project: caller.place.project.nilIfEmpty,
            environment: caller.place.environment,
            session: caller.session?.nilIfEmpty,
            outcome: outcome,
            reason: reason,
            via: caller.via,
            conversation: caller.conversation
        )
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))

        // The operator's alone, like the transcripts beside it: every line
        // carries params, and a failure's reason (Decision 35). Set on every
        // write, so a journal made before this rule is tightened by its next
        // line rather than left as it was.
        let files = FileManager.default
        try files.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journalDirectory.path)
        let url = journalFileURL()
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            handle.seekToEndOfFile()
            handle.write(line)
        } else if !files.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600]) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

/// Defeats the casual `Mirror(reflecting: registry)` walk by reporting no
/// children, so a future reader who reaches for reflection out of habit
/// (rather than deliberately trying to defeat this type's isolation) finds
/// nothing there. See the doc comment on `ActionRegistry` above: this is
/// not a security boundary, and other reflective techniques can still
/// reach `actions`.
extension ActionRegistry: CustomReflectable {
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

extension ActionRegistry {
    /// Who asked for the dispatch that is running right now.
    ///
    /// **One action reads this, and it is `api_set_request`** (#191,
    /// Decision 27): an agent's write to a draft request is refused while
    /// the operator has unsaved edits in a field it names, while the
    /// operator's own write always lands. The rule is keyed to the write's
    /// origin, and a handler is otherwise handed nothing but its params —
    /// `ActionOrigin`'s own doc comment used to say origin existed
    /// "solely so the journal can tell them apart", and this is where that
    /// stopped being true.
    ///
    /// **Why a task-local and not a fourth handler parameter.** Ninety
    /// registration sites would have had to grow a `_ in` for one action's
    /// need, and the two that matter would still have read it out of the
    /// same place this does. `dispatch` is the one chokepoint that knows
    /// the origin (Invariant 2), and it binds this around the handler
    /// call, so the value a handler reads is always the one its own
    /// dispatch was given — including under the actor reentrancy that
    /// makes a stored `currentOrigin` property wrong: a second dispatch
    /// suspending inside the first would overwrite it, and the handler
    /// that resumed would read the other caller's answer.
    ///
    /// **The default is `.agent`, which is the refusing side.** Anything
    /// that reaches a handler without going through `dispatch` is by
    /// definition not the operator's own control, and a rule that protects
    /// the operator's typing should fail towards keeping it.
    /// **Internal, so "one action reads this" is structural rather than
    /// asserted.** A `public` task-local is one anything outside this
    /// module could bind, and a rule that protects the operator's typing
    /// should not be overridable by a caller that merely knows the name.
    @TaskLocal static var dispatchOrigin: ActionOrigin = .agent

    /// The caller of the dispatch the running handler is part of, bound beside
    /// `dispatchOrigin` for the same reasons. Read by a handler that journals a
    /// follow-up line of its own (`api_send`'s sent-URL line), so that line names
    /// the same place and session as the dispatch line it follows. `nil` outside
    /// `dispatch`, where no caller is known.
    @TaskLocal static var dispatchCaller: DispatchCaller?

    /// 3c-ii: true while the running handler's dispatch was priced `.gate` and confirmed — the one
    /// case a browser act may add its site to the conversation's allow-list. A call priced `.allow`
    /// (its site already allowed) never adds one, so a revoke landing between the price and the
    /// handler is never undone. False outside `dispatch`, the refusing side.
    @TaskLocal static var dispatchConfirmedGate = false

    /// 3c-ii (final review I1): what the plane asked when this dispatch is the operator's approval of a
    /// parked proposal — the proposal the park raised, target and question included. A browser act
    /// refuses as page-changed when its target, site or price no longer match it. Nil outside an
    /// approved re-dispatch.
    @TaskLocal static var dispatchAsked: ActionProposal?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// `ActionRegistry.setCallerRefusal`'s slot: `CallerLookupBox`'s, for a lookup that also names
/// the action.
final class CallerRefusalBox: @unchecked Sendable {
    typealias Lookup = @Sendable (String, DispatchCaller) async -> String?

    private let lock = NSLock()
    private var lookup: Lookup?

    func set(_ lookup: @escaping Lookup) {
        lock.lock()
        self.lookup = lookup
        lock.unlock()
    }

    func current() -> Lookup? {
        lock.lock()
        defer { lock.unlock() }
        return lookup
    }
}

/// `ActionRegistry.setProductionLookup`'s and `setScopeLookup`'s slot: the same lock-and-closure
/// box as `ActiveShellContext`, so a synchronous initialiser can install it.
final class CallerLookupBox<Value: Sendable>: @unchecked Sendable {
    typealias Lookup = @Sendable (DispatchCaller) async -> Value?

    private let lock = NSLock()
    private var lookup: Lookup?

    func set(_ lookup: @escaping Lookup) {
        lock.lock()
        self.lookup = lookup
        lock.unlock()
    }

    func current() -> Lookup? {
        lock.lock()
        defer { lock.unlock() }
        return lookup
    }
}
