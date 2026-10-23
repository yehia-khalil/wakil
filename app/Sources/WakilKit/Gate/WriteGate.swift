import Foundation

/// Whether a switch asks for the environment already active (W12). It changes nothing, so it
/// prices nothing and refreshes nothing: no plane rises, no reply is cleared.
public func environmentSwitchIsNoOp(from current: String, to requested: String) -> Bool {
    current.trimmingCharacters(in: .whitespacesAndNewlines)
        == requested.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The single policy function standing between "an action was requested"
/// and "an action's handler ran". `ActionRegistry.dispatch` calls this
/// before running any handler, for every dispatch, regardless of origin.
///
/// | Kind | Origin | Decision |
/// |---|---|---|
/// | `.read` | any | `.allow` |
/// | `.control` | `.ui`, `.debug` | `.allow` |
/// | `.control` | any, names the environment already active (W12) | `.allow` |
/// | `.control` | `.agent`, names a target, production on either side | `.gate` |
/// | `.control` | `.agent`, otherwise | `.allow` |
/// | `.mutate` | any | `price.production` in production, `price.otherwise` elsewhere |
///
/// **The last row used to read "`.block` in production, `.gate`
/// elsewhere", and that pair is now the DEFAULT rather than the rule**
/// (Decision 25). An action declares its own price, so two adapters'
/// writes can cost different things without a fourth `ActionKind` and
/// without changing any SQL. Every action written before that decision
/// declares nothing and therefore gets `(.block, .gate)` — the old rule,
/// preserved by construction.
///
/// **Reads** are always allowed: read-only actions cannot corrupt state, so
/// there is nothing for an environment check to protect against.
///
/// **Mutations** cost whatever the action says they cost: `price.production`
/// in production and `price.otherwise` everywhere else, including an
/// environment string this function doesn't recognize. This function no
/// longer decides *which* two decisions those are — the action does, and an
/// action that declares nothing gets `(.block, .gate)`, which is the rule
/// this paragraph used to state outright. Read the table above, not a
/// remembered sentence: "blocked in production, gated elsewhere" is now the
/// DEFAULT price and is true of every action written before Decision 25,
/// but it is no longer what `.mutate` *means*.
///
/// What is unconditional is where an **unrecognized** environment falls:
/// with the non-production price, never with the production one. An
/// unrecognized environment name is a sign of a misconfiguration, not a
/// request to skip caution — but the caution it buys is the action's own
/// `price.otherwise`, which for everything shipped today is `.gate` and is
/// never silently `.allow` by accident, because an action that wants
/// `.allow` there has to have written it down.
///
/// **Control** actions change Wakil and not the world, so `environment`
/// never blocks them: dragging a pane while pointed at a production
/// database must work, and gating a context switch in production would
/// block it exactly when an operator most needs to go *look* at something.
///
/// The one exception is `origin == .agent` with a named `targetEnvironment`
/// where production is on either side of the move, and it exists because of
/// a specific incident rather than a general worry. During the 2026-09-08
/// acceptance run the agent, asked only to *list* projects, also set the
/// active one (`docs/wakil/phase-2a-acceptance.md` §6). Nothing stopped it,
/// because the setters were `.read`. The active `(org, project,
/// environment)` is what every later action resolves against, so an agent
/// that moves it unasked silently redirects everything after it. A later
/// acceptance walk found the other half of that: an agent switched *out* of
/// production, unasked, 63 seconds after the operator had switched into it
/// — leaving production silently invalidates every belief the operator
/// holds about the window just as entering it does, so both directions gate
/// the same way. Requiring a named target keeps the Phase 2 exit
/// criterion — *"open the booking project on staging, fetch the latest
/// reservation…"*, spoken in one breath — free of confirmations, while
/// making any move touching production cost a human keystroke whoever asked
/// for it.
///
/// **Note the asymmetry in unknown names.** `.mutate` treats an
/// unrecognised `environment` as cause for caution — `price.otherwise`,
/// which is `.gate` by default — because something outside Wakil might be
/// at stake. `.control` treats an unrecognised `targetEnvironment` as
/// simply not-production (`.allow`), because nothing outside Wakil is.
/// `"prod"` therefore gates a default-priced mutation and allows a control
/// action, and that is intended rather than an inconsistency.
///
/// Both environment comparisons go through `EnvironmentProduction`, which
/// reads the environment's own `production` flag and falls back to the name
/// — trimmed and lowercased, compared to exactly `"production"`, so
/// `"PRODUCTION"` and `" production"` match while `"prod"` does not
/// (Decision 26, #182). The same value is handed to
/// `VoidPalette.forEnvironment`, so the gate and the room cannot disagree
/// about what production is; see `isProductionEnvironment` for why the trim
/// was added on 2026-09-14 and why the NAME set was not widened then or now.
///
/// **A declared environment can be blocked where its name would only have
/// gated it, and that is the point.** `"prod"` still gates a default-priced
/// mutation on its name alone; declaring `production: true` is how it comes
/// to block one, which is a configuration edit somebody made rather than a
/// word this function guessed at.
public func writeGate(
    environment: String,
    kind: ActionKind,
    origin: ActionOrigin,
    targetEnvironment: String?,
    price: (production: GateDecision, otherwise: GateDecision) = (.block, .gate),
    agentPrice: GateDecision? = nil,
    production: EnvironmentProduction
) -> GateDecision {
    // Both comparisons read the project's declarations (Decision 26, #182).
    //
    // **No default, and that is the enforcement.** `.undeclared` means "read
    // the name", which is exactly the rule Decision 26 exists to replace — so
    // a defaulted parameter would let a call site revert to it silently, by
    // omission, with nothing to see in a diff. Every caller now says which it
    // wants: the registry passes the active project's declarations, and a
    // caller with no project in hand passes `.undeclared` where a reader can
    // see it.
    func isProduction(_ name: String?) -> Bool { production.isProduction(name) }
    switch kind {
    case .read:
        return .allow
    case .control:
        // D10. Production on EITHER side, and only for an action that
        // names a target at all — `targetEnvironment == nil` is a pane
        // move or a project switch, and `.control` exists so those are
        // never blocked by the environment.
        //
        // Entering production silently arms the next mutation. Leaving it
        // silently invalidates every belief the operator holds about the
        // window: they read a banner saying production, and every read,
        // proposal and confirmation after that point is judged against an
        // environment they did not choose.
        //
        // **W12: a switch to the environment already active changes nothing**, so it prices
        // nothing. Production on both sides used to raise a plane for a no-op.
        if let target = targetEnvironment, environmentSwitchIsNoOp(from: environment, to: target) {
            return .allow
        }
        guard origin == .agent, targetEnvironment != nil,
              isProduction(targetEnvironment) || isProduction(environment)
        else { return .allow }
        return .gate
    case .mutate:
        let priced = isProduction(environment) ? price.production : price.otherwise
        // A production block stands for every channel; otherwise the agent pays its own price.
        if priced == .block { return .block }
        if origin == .agent, let agentPrice { return agentPrice }
        return priced
    }
}

