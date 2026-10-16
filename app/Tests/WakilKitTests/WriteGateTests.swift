import Testing
@testable import WakilKit

@Test func actionKindHasThreeCasesWithStableRawValues() {
    #expect(ActionKind.read.rawValue == "read")
    #expect(ActionKind.control.rawValue == "control")
    #expect(ActionKind.mutate.rawValue == "mutate")
}

// MARK: - Reads

@Test func readsAreAllowedInEveryEnvironmentFromEveryOrigin() {
    for env in ["local", "staging", "production", "anything-else"] {
        for origin in [ActionOrigin.ui, .agent, .debug] {
            #expect(
                writeGate(environment: env, kind: .read, origin: origin, targetEnvironment: nil, production: .undeclared)
                    == .allow)
        }
    }
}

// MARK: - Mutations (unchanged from 2a)

@Test func mutationsAreGatedOutsideProduction() {
    for origin in [ActionOrigin.ui, .agent, .debug] {
        #expect(
            writeGate(environment: "staging", kind: .mutate, origin: origin, targetEnvironment: nil, production: .undeclared)
                == .gate)
        #expect(
            writeGate(environment: "local", kind: .mutate, origin: origin, targetEnvironment: nil, production: .undeclared)
                == .gate)
    }
}

@Test func mutationsAreBlockedOutrightInProduction() {
    for origin in [ActionOrigin.ui, .agent, .debug] {
        #expect(
            writeGate(environment: "production", kind: .mutate, origin: origin, targetEnvironment: nil, production: .undeclared)
                == .block)
    }
}

@Test func productionMatchIsExactAndCaseInsensitive() {
    #expect(
        writeGate(environment: "PRODUCTION", kind: .mutate, origin: .ui, targetEnvironment: nil, production: .undeclared)
            == .block)
    #expect(
        writeGate(environment: "Production", kind: .mutate, origin: .ui, targetEnvironment: nil, production: .undeclared)
            == .block)
    // An unknown environment is gated, not blocked — but never silently allowed.
    #expect(
        writeGate(environment: "prod", kind: .mutate, origin: .ui, targetEnvironment: nil, production: .undeclared)
            == .gate)
}

// MARK: - Control

@Test func controlIsAllowedFromTheUIAndDebugEverywhere() {
    for env in ["local", "staging", "production"] {
        for origin in [ActionOrigin.ui, .debug] {
            // Including when the target is production: an operator typing it
            // has already decided.
            #expect(
                writeGate(
                    environment: env, kind: .control, origin: origin,
                    targetEnvironment: "production", production: .undeclared) == .allow)
            #expect(
                writeGate(environment: env, kind: .control, origin: origin, targetEnvironment: nil, production: .undeclared)
                    == .allow)
        }
    }
}

@Test func controlIsAllowedFromTheAgentWhenNoProductionTargetIsNamed() {
    // The overwhelming majority: every layout action, and a project switch,
    // which never carries a target at all — allowed regardless of the
    // active environment, production included (D10:
    // `aControlActionWithNoTargetIsAllowedInProduction` pins the same
    // point for `production` specifically).
    for env in ["local", "staging", "production"] {
        #expect(
            writeGate(environment: env, kind: .control, origin: .agent, targetEnvironment: nil, production: .undeclared)
                == .allow)
    }
    // A context switch between two environments neither of which is
    // production is allowed too. `production` is deliberately absent from
    // this loop: switching *out* of it is D10's other half and is gated —
    // see `anAgentLeavingProductionIsGated`.
    for env in ["local", "staging"] {
        #expect(
            writeGate(environment: env, kind: .control, origin: .agent, targetEnvironment: "staging", production: .undeclared)
                == .allow)
    }
}

@Test func controlIsGatedWhenTheAgentTargetsProduction() {
    // The one row that exists because of the 2a acceptance finding: an agent
    // may propose entering production, never perform it unasked.
    #expect(
        writeGate(
            environment: "staging", kind: .control, origin: .agent,
            targetEnvironment: "production", production: .undeclared) == .gate)
    // Leaving production for another environment is gated too — the target is not all that
    // counts (`anAgentLeavingProductionIsGated`).
    #expect(
        writeGate(
            environment: "production", kind: .control, origin: .agent,
            targetEnvironment: "staging", production: .undeclared) == .gate)
    // **9b W12: a switch to the environment already active changes nothing**, so it is not
    // priced — production to production used to raise a plane for a no-op.
    #expect(
        writeGate(
            environment: "production", kind: .control, origin: .agent,
            targetEnvironment: " production ", production: .undeclared) == .allow)
}

@Test func theAgentsProductionTargetMatchIsCaseInsensitiveToo() {
    for target in ["PRODUCTION", "Production", "production"] {
        #expect(
            writeGate(
                environment: "staging", kind: .control, origin: .agent,
                targetEnvironment: target, production: .undeclared) == .gate)
    }
    // A near-miss is not production and is not gated: `.control` has no
    // "unknown environment" caution rule, because there is nothing outside
    // Wakil for an unrecognised name to endanger.
    #expect(
        writeGate(
            environment: "staging", kind: .control, origin: .agent, targetEnvironment: "prod", production: .undeclared)
            == .allow)
}

// MARK: - Production on either side (D10)

/// D10, and a recurrence: `ActionKind`'s own doc comment records 2a's
/// acceptance run finding "the agent re-pointing the active context
/// unasked", and `.control` exists because of it. The gate built then
/// guards one direction.
///
/// Entering production silently arms the next mutation. LEAVING production
/// silently invalidates everything the operator believes the window is
/// pointed at — and they read that banner, so the belief is Wakil's fault.
@Test func anAgentLeavingProductionIsGated() {
    #expect(writeGate(environment: "production", kind: .control,
                      origin: .agent, targetEnvironment: "staging", production: .undeclared) == .gate)
}

@Test func anAgentEnteringProductionIsStillGated() {
    #expect(writeGate(environment: "staging", kind: .control,
                      origin: .agent, targetEnvironment: "production", production: .undeclared) == .gate)
}

/// The operator's own switches are untouched, in both directions.
@Test func theOperatorMayLeaveProductionFreely() {
    #expect(writeGate(environment: "production", kind: .control,
                      origin: .ui, targetEnvironment: "staging", production: .undeclared) == .allow)
}

/// An agent moving between two non-production environments is nobody's
/// emergency.
@Test func anAgentMovingBetweenNonProductionEnvironmentsIsAllowed() {
    #expect(writeGate(environment: "staging", kind: .control,
                      origin: .agent, targetEnvironment: "dev", production: .undeclared) == .allow)
}

/// A `.control` action with no target — pane_move, ctx_set_project — must
/// not become gated merely because production is active. Moving a pane is
/// not a context switch.
@Test func aControlActionWithNoTargetIsAllowedInProduction() {
    #expect(writeGate(environment: "production", kind: .control,
                      origin: .agent, targetEnvironment: nil, production: .undeclared) == .allow)
}

// MARK: - The gate and the room agree on what production is (§H, 2026-09-14)
//
// `VoidPalette.forEnvironment` trims before it compares; `writeGate` did
// not. The two therefore disagreed about a name with surrounding
// whitespace — which a `TextField` will hand over verbatim, since
// `WindowModel.setEnvironment` does not normalise and
// `WakilWindow`'s environment field feeds it raw.
//
// The direction of the disagreement is the bad one. The room went red
// (the palette trimmed and saw production) while the gate saw an
// unrecognised name and returned `.gate` rather than `.block` — an
// alarming room around a *confirmable* write, which is the exact state
// `VoidPalette.swift`'s own doc comment says cannot happen.

@Test func aPaddedProductionNameIsBlockedLikeAnUnpaddedOne() {
    for name in [" production", "production ", "  production  ", "\tproduction\n"] {
        #expect(
            writeGate(environment: name, kind: .mutate, origin: .ui, targetEnvironment: nil, production: .undeclared)
                == .block,
            "\(name.debugDescription) must block a mutation")
    }
}

@Test func aPaddedProductionTargetGatesAnAgentsControlAction() {
    #expect(writeGate(environment: "staging", kind: .control,
                      origin: .agent, targetEnvironment: " production", production: .undeclared) == .gate)
    #expect(writeGate(environment: " production ", kind: .control,
                      origin: .agent, targetEnvironment: "staging", production: .undeclared) == .gate)
}

/// The property that matters, stated once over both types rather than as
/// two lists that can drift apart: for every name, the room is red exactly
/// when a mutation is refused outright. This is the assertion
/// `VoidPalette.swift:50-53` promises in prose and nothing checked.
@Test func theRoomIsRedExactlyWhenAMutationIsBlocked() {
    let names = [
        "production", "Production", "PRODUCTION", " production", "production ",
        "  production  ", "staging", "local", "development", "prod", "prd",
        "live", "preproduction", "production-2", "", "unknown",
    ]
    for name in names {
        let roomIsRed = VoidPalette.forEnvironment(name, production: .undeclared).isProduction
        let mutationBlocked =
            writeGate(environment: name, kind: .mutate, origin: .ui, targetEnvironment: nil, production: .undeclared)
            == .block
        #expect(
            roomIsRed == mutationBlocked,
            "\(name.debugDescription): room red \(roomIsRed), mutation blocked \(mutationBlocked)")
    }
}

// MARK: - The write price (Decision 25)

@Test func theDefaultPriceIsTodaysHardcodedRuleSoNoExistingActionMoves() {
    // Every action shipped before Decision 25 declares no price, so the
    // pair below is what the gate reads for all of them. If this ever
    // fails, an existing action's gate decision has moved without anyone
    // saying so.
    let action = Action(
        name: "anything", description: "", kind: .mutate,
        schema: .object([:]), handler: { _ in .null })
    #expect(action.price == (production: .block, otherwise: .gate))
    #expect(writeGate(environment: "production", kind: .mutate, origin: .ui,
                      targetEnvironment: nil, price: action.price, production: .undeclared) == .block)
    #expect(writeGate(environment: "staging", kind: .mutate, origin: .ui,
                      targetEnvironment: nil, price: action.price, production: .undeclared) == .gate)
}

@Test func anActionMayDeclareAWriteThatCostsNothingOutsideProduction() {
    // The shape Invariant 7's 2026-09-17 amendment already requires and
    // that no mechanism existed for: a write that a spoken turn may
    // execute outside production.
    let price: (production: GateDecision, otherwise: GateDecision) = (.block, .allow)
    #expect(writeGate(environment: "staging", kind: .mutate, origin: .agent,
                      targetEnvironment: nil, price: price, production: .undeclared) == .allow)
    #expect(writeGate(environment: "production", kind: .mutate, origin: .agent,
                      targetEnvironment: nil, price: price, production: .undeclared) == .block)
}

@Test func thePriceIsNeverConsultedForAReadOrAControlAction() {
    // A price that could make a read gate would be a second policy
    // engine. The gate short-circuits before it looks.
    let hostile: (production: GateDecision, otherwise: GateDecision) = (.block, .block)
    #expect(writeGate(environment: "production", kind: .read, origin: .agent,
                      targetEnvironment: nil, price: hostile, production: .undeclared) == .allow)
    #expect(writeGate(environment: "production", kind: .control, origin: .ui,
                      targetEnvironment: nil, price: hostile, production: .undeclared) == .allow)
}
