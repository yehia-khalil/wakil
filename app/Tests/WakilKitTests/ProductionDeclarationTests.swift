import Foundation
import Testing
@testable import WakilKit

// Production was a name comparison (Decision 26, #182). An environment
// spelled `prod` silently lost both the red room and the typed
// confirmation, and one named `production` that is not one could not say
// so. It is DECLARED now, and the name supplies only the default.
//
// The three readers that must agree are the write gate, the void palette
// and the environment listing. They agree by all three taking the same
// `EnvironmentProduction` value rather than by three predicates staying in
// step — the construction that was put in place on 2026-09-14 when the
// palette and the gate had drifted on whitespace.

private let declaredProd = EnvironmentProduction(declarations: ["blue": true, "production": false])

@Test func theFlagDecidesAndTheNameIsOnlyItsDefault() {
    #expect(declaredProd.isProduction("blue"), "declared true is production whatever it is named")
    #expect(!declaredProd.isProduction("production"), "a declared false is honoured")
    // Undeclared falls back to the name, exactly as before. Wakil never
    // materialises the default: "absent means not production" would stop
    // every shipped project's production environment being production on
    // one release.
    #expect(EnvironmentProduction.undeclared.isProduction("production"))
    #expect(!EnvironmentProduction.undeclared.isProduction("prod"))
    #expect(!EnvironmentProduction.undeclared.isProduction(nil))
    // Trimmed and case-folded, unchanged since 2026-09-14.
    #expect(EnvironmentProduction.undeclared.isProduction(" PRODUCTION "))
    // And the lookup itself folds, so a declaration reaches a name the
    // operator typed with different case or stray space.
    #expect(EnvironmentProduction(declarations: ["Blue": true]).isProduction(" blue "))
}

@Test func theGateReadsTheFlag() {
    // `blue` declares production, so a default-priced mutation is BLOCKED
    // there — where under the name rule it would have been merely gated.
    #expect(writeGate(environment: "blue", kind: .mutate, origin: .agent,
                      targetEnvironment: nil, production: declaredProd) == .block)
    // And `production` declaring false is gated rather than blocked, which
    // is the disarm doing the thing it was written down to do.
    #expect(writeGate(environment: "production", kind: .mutate, origin: .agent,
                      targetEnvironment: nil, production: declaredProd) == .gate)
    // Unchanged with nothing declared.
    #expect(writeGate(environment: "production", kind: .mutate, origin: .agent,
                      targetEnvironment: nil, production: .undeclared) == .block)
    #expect(writeGate(environment: "prod", kind: .mutate, origin: .agent,
                      targetEnvironment: nil, production: .undeclared) == .gate)
    // `.control` reads the flag on both sides too: entering a declared
    // production silently arms the next mutation, and that is the whole
    // reason D10 looks at the target as well as the current environment.
    #expect(writeGate(environment: "staging", kind: .control, origin: .agent,
                      targetEnvironment: "blue", production: declaredProd) == .gate)
    #expect(writeGate(environment: "staging", kind: .control, origin: .agent,
                      targetEnvironment: "production", production: declaredProd) == .allow)
}

@Test func theRoomReadsTheSameFlag() {
    // A treatment that disagreed with the gate about what production is
    // would paint a safe-looking room around a refusal — the claim
    // `VoidPalette.forEnvironment` has carried since it was written.
    #expect(VoidPalette.forEnvironment("blue", production: declaredProd).isProduction)
    #expect(!VoidPalette.forEnvironment("production", production: declaredProd).isProduction)
    #expect(VoidPalette.forEnvironment("production", production: .undeclared).isProduction)
    #expect(!VoidPalette.forEnvironment("prod", production: .undeclared).isProduction)
}

@Test func theListingPublishesTheFlagsEffectRatherThanComparingTheName() {
    // `list_environments` now answers {environments:{…},notices:[…]}, each
    // environment carrying readOnly AND production. The app must read the
    // published boolean: re-deriving it from the name here is exactly the
    // second copy of the rule Decision 26 removes.
    let structured: [String: JSONValue] = [
        "environments": .object([
            "blue": .object(["readOnly": .bool(false), "production": .bool(true)]),
            "production": .object([
                "readOnly": .bool(true), "production": .bool(false),
                "notice": .string("Named production, and declares \"production\": false"),
            ]),
            "staging": .object(["readOnly": .bool(true), "production": .bool(false)]),
        ]),
    ]
    let rows = WindowModel.environmentListings(from: structured)
    #expect(rows.map(\.name) == ["blue", "production", "staging"], "sorted by name")
    #expect(rows[0].isProduction, "blue declares production")
    #expect(!rows[1].isProduction, "the disarmed production is honoured, not re-derived from its name")
    #expect(!rows[0].isReadOnly)
    #expect(rows[1].isReadOnly)
    // The notice rides on the row it is about, so the menu can draw it
    // there instead of heaping every notice above the list.
    #expect(rows[1].notice?.contains("declares") == true, "the disarmed production carries its notice")
    #expect(rows[0].notice == nil, "an unremarkable environment carries none")
    #expect(rows[2].notice == nil)
}

@Test func aStaleBinaryStillListsEnvironments() {
    // `bin/` is per-worktree and routinely stale, and an older wakil-ctx
    // answers the flat map[string]bool this tool used to return. Degrade to
    // the NAME rule rather than to nothing: the alternative is a context
    // line with no environments at all, and the name rule is what every
    // build before this one used anyway.
    let old: [String: JSONValue] = ["production": .bool(true), "staging": .bool(true)]
    let rows = WindowModel.environmentListings(from: old)
    #expect(rows.map(\.name) == ["production", "staging"])
    #expect(rows[0].isProduction)
    #expect(!rows[1].isProduction)
    #expect(rows.allSatisfy { $0.notice == nil }, "a stale binary has nothing to say")
}

@Test func theContextCarriesEachEnvironmentsDeclaration() throws {
    // get_context already carries the whole project, so the flag reaches
    // Swift free — no second call, and no second source of truth.
    let structured = JSONValue.object([
        "Org": .string("initech"),
        "Environment": .string("blue"),
        "Project": .object([
            "name": .string("widgets"),
            "environments": .object([
                "blue": .object(["production": .bool(true)]),
                "production": .object(["production": .bool(false)]),
                "staging": .object(["databases": .array([])]),
            ]),
        ]),
    ])
    let ctx = try ContextStore.parseActiveContext(structured)
    #expect(ctx.environmentProduction.isProduction("blue"))
    #expect(!ctx.environmentProduction.isProduction("production"))
    #expect(!ctx.environmentProduction.isProduction("staging"))
    // An environment that declares nothing is absent from the map, not
    // recorded as false — absent means "read the name".
    #expect(ctx.environmentProduction.declarations["staging"] == nil)
}

@Test func aProjectlessContextDeclaresNothing() throws {
    let ctx = try ContextStore.parseActiveContext(.object([
        "Org": .string("initech"), "Environment": .string(""), "Project": .null,
    ]))
    #expect(ctx.environmentProduction == .undeclared)
}

@Test func twoNamesThatFoldAlikeResolveDeterministicallyTowardProduction() {
    // `Dictionary.map` has no defined order and Swift seeds its hashing
    // per process, so `{ _, last in last }` would let a safety property be
    // decided by the hash seed — the same configuration answering
    // differently on different launches. `||` is deterministic and fails
    // toward production, which is the direction this value may be wrong in.
    for _ in 0..<200 {
        let folded = EnvironmentProduction(declarations: ["Prod": true, "prod ": false])
        #expect(folded.isProduction("prod"), "either declaration being true must win, every time")
    }
    #expect(!EnvironmentProduction(declarations: ["Prod": false, "prod ": false]).isProduction("prod"))
}

@MainActor
@Test func anAgentsProjectSwitchReachesTheGatesViewOfProduction() async throws {
    // **The hole the flag opened, closed.** `ctx_set_project` is a
    // registered action the agent can dispatch, and the observation pump
    // had a branch for `ctx_set_environment` and none for it — so the
    // window kept the outgoing project's name, environment and panes.
    // Those three were at least stale together. The declarations are not:
    // `targetEnvironment` reaches `writeGate` fresh from the caller's
    // params, so an agent that switched project and then entered an
    // environment the NEW project declares production was judged against
    // flags that never mentioned it.
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "initech")
    #expect(model.environmentProduction == .undeclared)

    model.seedEnvironmentProductionForTesting(
        EnvironmentProduction(declarations: ["blue": true]))
    #expect(model.environmentProduction.isProduction("blue"))

    // And an org switch takes it away again — the declarations describe
    // the outgoing org's project, and a stale `production: false` is a
    // production mutation priced as staging.
    await model.invalidateForOrgChange()
    #expect(model.environmentProduction == .undeclared)
}
