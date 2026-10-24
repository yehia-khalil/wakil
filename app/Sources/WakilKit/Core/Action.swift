import Foundation

/// Whether an action only reads state, changes Wakil's own state, or can
/// change the world outside Wakil. `ActionRegistry` consults this on every
/// `dispatch` call, before the handler runs, to decide what `writeGate`
/// does about it.
///
/// **Why there are three and not two.** The gate asks one question —
/// *could this damage the world outside Wakil?* — and some actions answer
/// "no" while still changing something. Moving a pane, switching the
/// active project: nothing outside the app is touched. Filed `.mutate`,
/// the gate blocks them in `production`, so a pane could not be dragged
/// while pointed at a production database. Filed `.read`, they run
/// unchecked from every origin, agent included — which is how 2a's
/// acceptance run found the agent re-pointing the active context unasked
/// (`docs/wakil/phase-2a-acceptance.md` §6). `.control` is the answer to
/// both: never blocked by environment, but distinguishable at the gate.
public enum ActionKind: String, Sendable {
    /// Observes state. Changes nothing. Never gated.
    case read
    /// Not gated by the environment. Usually because the world outside
    /// Wakil is untouched — pane geometry, the active context — and in
    /// exactly one case (`term_run`) because the environment is the wrong
    /// instrument: `.mutate` would gate every `ls` on a typed
    /// confirmation and block the pane outright in production, which is
    /// where an operator most wants a shell. What protects that one is
    /// `operatorOnlyActions` and the in-pane `⏎`.
    case control
    /// Changes the world outside Wakil. What that costs is the **action's
    /// own** `price` (Decision 25), not this case: the gate reads the
    /// pair, and the default pair — `(.block, .gate)` — is what this
    /// comment used to state as a rule.
    ///
    /// **This comment used to say "gated everywhere, blocked in
    /// production", and it was false twice over by 2026-09-17.** Once
    /// because `.control` now covers an action that runs a shell command
    /// (`term_run`), so "changes the world outside Wakil" no longer
    /// separates the two cases cleanly — `.control` was redefined by
    /// 2c-iii as *"not gated by environment"* rather than *"doesn't touch
    /// the world"*, and the instrument protecting a shell run is
    /// `operatorOnlyActions` plus the operator's own Enter, never the
    /// gate. And once because the price moved the gating off the kind
    /// entirely.
    case mutate
}

/// Whether the AI agent may reach an action at all.
///
/// **This is not `ActionKind` one case over, and the two must not be
/// collapsed.** `ActionKind` answers *could this damage the world outside
/// Wakil?*, which is the gate's question and is asked of every origin
/// alike — the operator's own `db_run_mutation` is gated in production
/// exactly as the agent's is. This answers *may the agent ask for it at
/// all?*, which the gate never asks: `agentAllowedTools` filters `.control`
/// IN by design, so no `.control` action can be kept from the agent by its
/// kind, and every member of `operatorOnlyActions` today is `.control`.
///
/// **Why it exists on the action rather than only in a list.**
/// `operatorOnlyActions` is an enumerated denylist and is still what
/// `permissionDecision` refuses on — this type does not replace it. What
/// it adds is **totality**. A name absent from a denylist is reachable,
/// and absence is not something a denylist can notice; `nil` here is,
/// which is what `ActionClassificationTests` counts. An action added
/// without a thought about the agent now fails a named test instead of
/// becoming agent-reachable by omission.
///
/// **Why it is optional.** So that "unclassified" is expressible and
/// therefore catchable. A required initialiser parameter would make
/// omission a compile error, which is stricter — and would also force an
/// audience onto every test double and fixture that constructs an `Action`
/// and never registers one. See `ActionClassificationTests` for the full
/// argument.
public enum ActionAudience: String, Sendable, Equatable {
    /// The agent may dispatch it. This is what every action not named in
    /// `operatorOnlyActions` is today — stated here rather than inferred
    /// from an absence.
    case agentReachable
    /// Only the operator may dispatch it. A name classified this way must
    /// also be in `operatorOnlyActions`, which is what actually performs
    /// the refusal; the two are pinned to agree by
    /// `ActionClassificationTests`.
    case operatorOnly
}

/// Who asked for an action to run. The whole point of routing every state
/// change through `ActionRegistry.dispatch` is that a UI button, the AI
/// agent, and a debug script are indistinguishable to the gate and to
/// almost every handler — `origin` exists so the journal can tell them
/// apart after the fact, and `writeGate` reads it to decide what an agent
/// may do in production.
///
/// **This comment used to end "solely so the journal can still tell them
/// apart", and #191 is where that stopped being true.** Decision 27 makes
/// one handler's answer depend on who asked: an agent's write to an api
/// pane's draft is refused while the operator has unsaved edits in a field
/// it names, and the operator's own write always lands. A handler is
/// handed only its params, so the origin reaches that one through
/// `ActionRegistry.dispatchOrigin`, which `dispatch` binds around the
/// handler call. A second reader was decided on for background agents: a
/// handler that journals a follow-up line (`api_send`'s sent-URL line) reads
/// the whole caller, place and session, through `ActionRegistry.dispatchCaller`,
/// so that line names the same place as the dispatch line it follows. Any
/// further reader should still be a decision rather than a habit.
public enum ActionOrigin: String, Codable, Sendable {
    case ui
    case agent
    case debug
}

/// One entry in the action registry: a name the caller dispatches by, a
/// declared kind that determines whether `writeGate` applies, a JSON schema
/// describing the expected params (for callers such as the MCP layer that
/// need to advertise or validate shape), and the handler that actually does
/// the work.
///
/// `Action` values are only ever consumed by `ActionRegistry.register(_:)`.
/// Once registered, an `Action` lives solely inside the registry's private,
/// actor-isolated storage — no public method on `ActionRegistry` returns an
/// `Action` (see `ActionDescriptor` and `all()`), so there is no way for
/// code holding a registry to retrieve a *different* caller's registered
/// handler and invoke it directly. The only remaining route to run a
/// registered handler is `ActionRegistry.dispatch`.
public struct Action: Sendable {
    public var name: String
    public var description: String
    public var kind: ActionKind
    /// Whether the agent may reach this action — see `ActionAudience`.
    /// `nil` means nobody has said, which is a state `ActionRegistry` is
    /// happy to hold and `ActionClassificationTests` fails on for anything
    /// a real assembly registers.
    public var audience: ActionAudience?
    public var schema: JSONValue
    public var handler: @Sendable (JSONValue) async throws -> JSONValue

    /// The name of the params key holding this action's *target*
    /// environment — the environment that will be active after it runs —
    /// or `nil` for the actions that have none, which is almost all of
    /// them.
    ///
    /// Only `ctx_set_environment` sets this. It is read by
    /// `ActionRegistry.dispatch` and handed to `writeGate`, which uses it
    /// for exactly one decision: whether an agent is entering production.
    /// The agent cannot reach `ctx_set_environment` (it is operator-only:
    /// an agent's place is fixed when its session starts), so this is a
    /// second layer behind the audience rather than what stops the agent.
    ///
    /// **`ctx_set_project` deliberately does not set it.**
    /// `wakilcore.SetProjectChecked` keeps the current environment name if
    /// the incoming project defines one by that name and otherwise clears
    /// it to `""` — there is no per-project "last environment" on disk to
    /// restore. So switching project can only preserve the current
    /// environment or drop to none; it can never elevate staging into
    /// production, and there is nothing for the gate to catch.
    /// `StandardActionsTests` pins that Phase 1 behaviour so a change to it
    /// fails a test here rather than quietly widening this gate.
    public var targetEnvironmentParam: String?

    /// What this action's write costs, as a pair: the gate's answer in
    /// `production`, and its answer everywhere else.
    ///
    /// **The default pair is today's hardcoded rule**, so every action
    /// written before Decision 25 keeps exactly the gate decision it had —
    /// by construction rather than by inspection. `(.block, .gate)` is
    /// verbatim what `writeGate`'s `.mutate` branch used to compute for
    /// itself.
    ///
    /// **Read only for `.mutate`.** `.read` and `.control` are answered
    /// before the gate looks at a price; an action that declared a
    /// hostile pair and a harmless kind changes nothing, which is what
    /// keeps the price a per-adapter cost rather than a second policy
    /// engine (`WriteGateTests.thePriceIsNeverConsultedForAReadOrAControlAction`).
    ///
    /// **Why a pair on the action and not a fourth `ActionKind`.** Two of
    /// `ActionKind`'s three consumers compare by equality rather than
    /// switching, so a fourth case would have made `isMutation` silently
    /// false and the confirmation plane stop appearing — a safety
    /// chokepoint failing quietly, which is the one failure mode the gate
    /// exists to prevent.
    public var price: (production: GateDecision, otherwise: GateDecision) = (.block, .gate)

    /// 3a-iv (Decision 46): this write's price when the agent asks, outside production's block.
    /// Nil prices every channel alike. Branch delete and stash drop carry `.gate` here: the
    /// operator's own click has already confirmed in place, so only the agent's (and voice's,
    /// which reaches them through the agent) ask raises the plane.
    public var agentPrice: GateDecision? = nil

    /// The names of this action's parameters whose **values** must never
    /// reach the journal. `ActionRegistry` writes `[redacted]` in place of
    /// each, keeping the parameter's name.
    ///
    /// **Why the mark is here and not on `ActionDescriptor`.** `dispatch`
    /// holds an `Action` and never builds a descriptor, so a mark on the
    /// descriptor is a mark nothing on the write path can read.
    ///
    /// **Why the name survives.** `JournalEntry` exists so that *what
    /// changed, who asked, and what happened* is reconstructable. Dropping
    /// the parameter entirely would lose the "what changed" — *a DSN was
    /// set on `orders`* is the fact worth recording, and it is unreadable
    /// if the key vanishes with the value.
    ///
    /// **Why this is positional and the Go scrubber is not.** The scrubber
    /// is handed output it did not compose and must go looking for a
    /// secret's bytes in it. This is handed the action's own parameters
    /// and already knows which one is the secret, so looking would be both
    /// unnecessary and wrong: a byte search redacts an innocent parameter
    /// that happens to equal the secret, and misses one that arrived
    /// re-encoded.
    ///
    /// Empty for every action registered today. 2e's database DSN write is
    /// the first caller.
    public var secretParams: Set<String> = []

    public init(
        name: String,
        description: String,
        kind: ActionKind,
        audience: ActionAudience? = nil,
        schema: JSONValue,
        handler: @escaping @Sendable (JSONValue) async throws -> JSONValue,
        targetEnvironmentParam: String? = nil,
        price: (production: GateDecision, otherwise: GateDecision) = (.block, .gate),
        agentPrice: GateDecision? = nil,
        secretParams: Set<String> = []
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.audience = audience
        self.schema = schema
        self.handler = handler
        self.targetEnvironmentParam = targetEnvironmentParam
        self.price = price
        self.agentPrice = agentPrice
        self.secretParams = secretParams
    }
}

/// The non-executable half of a registered `Action`: everything about it
/// except the handler. This is what `ActionRegistry.all()` returns, and
/// deliberately all it returns — it has no `handler` member at all, so
/// `someDescriptor.handler` is not a permission error but a compile error.
/// There is no expression a caller can write against this type that invokes
/// a registered action's handler; the only method on `ActionRegistry` that
/// can do that is `dispatch`, which is also the only method that consults
/// `writeGate` and journals the outcome.
public struct ActionDescriptor: Sendable, Equatable {
    public let name: String
    public let description: String
    public let kind: ActionKind
    /// The registered action's own `audience`, carried through so that
    /// "is every registered action classified?" is answerable from the
    /// one method that enumerates them. `nil` means the registration
    /// declared none.
    public let audience: ActionAudience?
    public let schema: JSONValue

    /// Spelled out rather than left to the memberwise initialiser so that
    /// `audience` can default. Callers that build a descriptor by hand are
    /// tests and fixtures asking about *some other* property — whether a
    /// palette item is offered, whether a kind is a mutation — and an
    /// audience they do not care about would be noise in every one of
    /// them. `ActionRegistry.all()`, the only caller that matters, always
    /// passes the registered action's own.
    public init(
        name: String,
        description: String,
        kind: ActionKind,
        audience: ActionAudience? = nil,
        schema: JSONValue
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.audience = audience
        self.schema = schema
    }
}
