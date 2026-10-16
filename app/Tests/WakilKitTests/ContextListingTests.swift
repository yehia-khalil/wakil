import Foundation
import Testing
@testable import WakilKit

/// The two pure mappers behind the context line's Project and Environment
/// segments (`ContextLine.swift`, `WakilApp`), pinned here because
/// `WakilApp` has no test target and this is the half that can be asserted
/// without a window, a registry or a child process — the same split
/// `orgListings(from:)` and `sessionItems(from:)` already use.

// MARK: - Environments

/// `list_environments` answers a flat `map[string]bool` with **no wrapper
/// key**, unlike `list_projects` (a `projects` object) and `list_sessions`
/// (a `sessions` array). Reaching for a key that is not there is the exact
/// bug `projectPaletteItems`' own guard exists to report, so the shape is
/// pinned rather than assumed.
@Test func environmentListingsReadTheStructuredObjectDirectly() {
    let rows = WindowModel.environmentListings(from: [
        "staging": .bool(false),
        "production": .bool(true),
        "local": .bool(true),
    ])

    #expect(rows.map(\.name) == ["local", "production", "staging"])
    #expect(rows.map(\.isReadOnly) == [true, true, false])
}

/// Sorted by name, for the reason `projectListings` is: a dictionary has no
/// order, and two controls listing the same environments in two different
/// orders is a defect the operator sees long before anyone reads the code.
@Test func environmentListingsSortByName() {
    let rows = WindowModel.environmentListings(from: [
        "zeta": .bool(true), "alpha": .bool(true), "mid": .bool(false),
    ])
    #expect(rows.map(\.name) == ["alpha", "mid", "zeta"])
}

/// **A non-boolean value is dropped, never coerced.** The Go tool's
/// contract is `bool`; an environment whose read-only state cannot be read
/// must not be drawn as writable, which is the direction `?? false` fails
/// in. Dropping the row makes it absent — a state the menu already draws
/// honestly — rather than present and wrong about the one field that says
/// whether a write can reach it.
@Test func environmentListingsDropUnreadableValuesRatherThanDefaultingThem() {
    let rows = WindowModel.environmentListings(from: [
        "staging": .bool(false),
        "broken": .string("true"),
        "missing": .null,
    ])

    #expect(rows.map(\.name) == ["staging"])
    #expect(rows.map(\.isReadOnly) == [false])
}

/// **UPDATED DELIBERATELY BY #182, not silenced.** This test used to assert
/// `row(name).isProduction == isProductionEnvironment(name)` — that the
/// listing re-derived production from the name, the same way the gate did.
/// Decision 26 makes production a thing an environment DECLARES, and
/// `list_environments` publishes the flag's effect, so re-deriving it here
/// is now the second copy of the rule rather than the defence against one.
/// The claim the old test was protecting is unchanged and is protected
/// better: the menu, the badge, the room and the gate still cannot disagree
/// — they now agree by reading one published answer instead of by running
/// the same predicate.
///
/// The name rule survives in exactly one place, and this pins it there: a
/// `wakil-ctx` too old to publish `production` at all.
@Test func environmentListingPublishesTheToolsAnswerRatherThanTheName() {
    func row(_ name: String, production: Bool) -> EnvironmentListing {
        WindowModel.environmentListings(from: [
            "environments": .object([name: .object([
                "readOnly": .bool(true), "production": .bool(production),
            ])]),
        ])[0]
    }

    // The flag wins in both directions, and the name is not consulted.
    #expect(row("blue", production: true).isProduction)
    #expect(!row("production", production: false).isProduction)
    #expect(row("prod", production: true).isProduction)

    // Against a binary that predates the flag, and only there, the name
    // rule answers — `prod` deliberately still does not match, because
    // widening the name set would turn a confirmable `prod` mutation into a
    // blocked one (`EnvironmentName.swift` records that asymmetry).
    func stale(_ name: String) -> EnvironmentListing {
        WindowModel.environmentListings(from: [name: .bool(true)])[0]
    }
    #expect(stale("production").isProduction)
    #expect(stale("  Production  ").isProduction)
    #expect(stale("PRODUCTION").isProduction)
    #expect(!stale("prod").isProduction)
    #expect(!stale("live").isProduction)
    #expect(!stale("staging").isProduction)
    for name in ["production", "  Production  ", "prod", "live", "staging"] {
        #expect(stale(name).isProduction == isProductionEnvironment(name))
    }
}

/// An environment with no databases reports read-only **vacuously**, by the
/// Go tool's own stated rule — so `isReadOnly` is never evidence that an
/// environment is configured. Pinned because the obvious reading of a
/// `true` here is "this one is safe", and the honest reading is "nothing
/// here is writable, possibly because nothing here exists".
@Test func readOnlyIsNotEvidenceOfConfiguration() {
    let rows = WindowModel.environmentListings(from: [
        "sandbox": .bool(true),      // no databases at all
        "production": .bool(true),   // one database, no writeRef
    ])
    #expect(rows.count == 2)
    #expect(rows.map(\.isReadOnly) == [true, true])
}

// MARK: - Projects

@Test func projectListingsCarryProviderAndPath() {
    let rows = WindowModel.projectListings(from: [
        "wakil-acceptance": .object([
            "provider": .string("main"),
            "path": .string("/Users/y/src/wakil/.wakil/project.json"),
        ]),
        "booking-api": .object(["path": .string("/Users/y/src/booking/.wakil/project.json")]),
    ])

    #expect(rows.map(\.name) == ["booking-api", "wakil-acceptance"])
    #expect(rows[0].provider == nil)
    #expect(rows[0].path == "/Users/y/src/booking/.wakil/project.json")
    #expect(rows[1].provider == "main")
}

/// An entry whose value is not an object still yields a row carrying its
/// name. The name is the payload `ctx_set_project` needs and the only field
/// the control cannot do without; dropping the row would hide a registered
/// project because its metadata was malformed, which is a harsher failure
/// than drawing it with no subtitle.
@Test func projectListingsSurviveAnEntryWithNoObjectBody() {
    let rows = WindowModel.projectListings(from: [
        "telemetry": .string("unexpected"),
        "ops": .object(["provider": .string("work")]),
    ])

    #expect(rows.map(\.name) == ["ops", "telemetry"])
    #expect(rows[1].provider == nil)
    #expect(rows[1].path == nil)
}

/// An empty string on the wire is the same as an absent field, for both
/// optionals — `stringField`'s own rule, relied on here so the menu draws
/// no subtitle rather than an empty line that reads as a loading state.
@Test func projectListingsTreatEmptyStringsAsAbsent() {
    let rows = WindowModel.projectListings(from: [
        "p": .object(["provider": .string(""), "path": .string("")]),
    ])
    #expect(rows[0].provider == nil)
    #expect(rows[0].path == nil)
}

// MARK: - The chip form

/// The chip is the one place the environment badge is drawn as a filled
/// token rather than as a line of text, and it takes §5's reserved hues:
/// green for local and staging ("healthy"), red for production. Pinned
/// because the obvious mistake is to reach for `ordinaryColour` — correct
/// for a text label, and the one treatment that would make the context line
/// the only place in the app showing an environment with no semantic hue.
@Test func theChipTakesTheReservedHueRatherThanOrdinaryText() {
    #expect(EnvironmentBadge.chipColour(isProduction: true) == EnvironmentBadge.productionColour)
    #expect(EnvironmentBadge.chipColour(isProduction: false) == TerminalPalette.green)
    #expect(EnvironmentBadge.chipColour(isProduction: false) != EnvironmentBadge.ordinaryColour)
}

/// Both hues are read from the one home §5's colours already have, never
/// respelled — the rule `productionColour` follows by reading
/// `VoidPalette.red`. Two copies of a hue drift.
@Test func theChipsHuesAreReadFromTheSharedPaletteNotRestated() {
    #expect(EnvironmentBadge.productionColour == VoidPalette.red)
    #expect(TerminalPalette.red == VoidPalette.red)
}

/// Production is tinted a shade stronger: the one chip that must be
/// unmissable gets the most present fill (Invariant 8).
@Test func productionCarriesTheStrongerTint() {
    #expect(EnvironmentBadge.chipTintOpacity(isProduction: true)
            > EnvironmentBadge.chipTintOpacity(isProduction: false))
}

// MARK: - The session flag

/// The Landing is gated on the SESSION, not on the pane count — so this is
/// sticky, set by whichever entrance happens first, and never cleared by
/// closing panes. Pinned because the obvious implementation is
/// `panes.isEmpty`, which is the rule this supersedes: a pane-less window
/// mid-session is not empty, it is the room with a thought thread in it.
@MainActor
@Test func aFreshWindowIsSessionless() async {
    let model = await sessionlessModel()
    #expect(!model.sessionStarted)
}

/// All three entrances set it, and it is idempotent — a turn and a pane can
/// land in the same gesture.
@MainActor
@Test func anyEntranceIntoWorkStartsTheSession() async {
    let model = await sessionlessModel()
    model.markSessionStarted()
    #expect(model.sessionStarted)
    model.markSessionStarted()
    #expect(model.sessionStarted)
}

/// **Nothing clears it.** There is no in-window path back to the Landing
/// today: `session_resume` exists and nothing mints a fresh session without
/// relaunching. This pins the gap so that adding `session_new` has an
/// assertion to change rather than a behaviour to discover.
@MainActor
@Test func nothingInTheWindowReturnsToSessionless() async {
    let model = await sessionlessModel()
    model.markSessionStarted()
    await model.closePane(id: "nothing")
    await model.refreshLayout()
    #expect(model.sessionStarted)
}

/// A model with no clients behind it — enough to exercise the flag, which
/// touches neither the registry nor a child process. The lookup is a local
/// stub rather than a shared one because `ProviderCredentialsLookup` is a
/// protocol with no public initialiser, and the copy in `ProviderSwitchTests`
/// is `private` to that file.
private struct SessionlessLookup: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(
            claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

@MainActor
private func sessionlessModel() async -> WindowModel {
    WindowModel(
        registry: ActionRegistry(
            journalDirectory: testScratchRoot
                .appendingPathComponent("wakil-sessionless-\(UUID().uuidString)"),
            sessionId: "sessionless"),
        panes: PaneStore(),
        layout: LayoutStore(),
        context: nil,
        harnessFactory: { _ in nil },
        resumes: ResumeBroker(),
        rootPath: NSTemporaryDirectory(),
        providerId: "main",
        lookup: SessionlessLookup())
}

// MARK: - The session age

/// `SessionMeta.ModTime` has been on the wire since Phase 1 and nothing in
/// `app/` read it until 2026-09-20 — which is how the artboards came to draw
/// an age the palette could not produce, and then how it came to be struck
/// from them for "not existing". It exists. These pin the vocabulary the
/// artboards use so the two cannot drift again.
@Test func theAgeUsesTheArtboardsOwnVocabulary() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func age(_ secondsAgo: TimeInterval) -> String? {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
        return WindowModel.age(ofRFC3339: stamp, now: now)
    }

    #expect(age(20) == "now")
    #expect(age(9 * 60) == "9m")
    #expect(age(60 * 60) == "1h")
    #expect(age(2 * 3600 + 14 * 60) == "2h 14m")
    #expect(age(30 * 3600) == "yesterday")
    #expect(age(4 * 86400) == "4d")
}

/// **Never a future time.** The value is a file's mtime on this machine, so a
/// clock that moved backwards or a transcript copied from another machine can
/// date it ahead of now. "in 3h" is nonsense about a session you already had.
@Test func aSessionDatedInTheFutureReadsAsNow() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ahead = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 3600))
    #expect(WindowModel.age(ofRFC3339: ahead, now: now) == "now")
}

/// An unparseable stamp yields no age rather than a wrong one — the subtitle
/// then carries provider and resume count alone, which is what it carried
/// before this existed.
@Test func anUnreadableTimestampYieldsNoAge() {
    #expect(WindowModel.age(ofRFC3339: "") == nil)
    #expect(WindowModel.age(ofRFC3339: "not a date") == nil)
}

/// The age leads the subtitle, ahead of the provider and the resume count,
/// because the list is ordered by it.
@Test func theAgeLeadsTheSessionSubtitle() {
    let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-4 * 86400))
    let items = WindowModel.sessionItems(from: [
        .object([
            "id": .string("s1"), "provider": .string("main"),
            "modTime": .string(stamp), "firstPrompt": .string("walk the acceptance"),
        ])
    ])
    #expect(items.count == 1)
    #expect(items[0].subtitle == "4d · main")
}

// MARK: - Session identity at the first act of work

/// **The prerequisite for #142.** Keying a pane arrangement on the
/// conversation needs an identity at the moment a pane opens, and a pane can
/// open before any turn: the Landing's Open column marks the session started
/// without sending anything. `sessionId` is minted inside `send` as part of
/// spawning `claude`, so it is `nil` at that point — and a database pane must
/// not launch a subprocess just to be filed.
@MainActor
@Test func aFreshWindowHasNoConversationIdentityYet() async {
    let model = await sessionlessModel()
    #expect(model.assignedSessionId == nil)
    #expect(!model.sessionStarted)
}

/// Assigned by whichever entrance reaches `markSessionStarted()` first — a
/// turn, a pane, or a resume — and **without** a harness, which is the whole
/// point.
@MainActor
@Test func openingAPaneAssignsAConversationIdentityWithNoAgent() async {
    let model = await sessionlessModel()
    model.markSessionStarted()

    #expect(model.sessionStarted)
    #expect(model.assignedSessionId != nil)
    // `sessionId` still means "the id the running child was started with",
    // and no child has been started. The two are deliberately not the same
    // fact; conflating them is what left the first pane of a session with
    // nothing to belong to.
    #expect(model.sessionId == nil)
}

/// Stable across repeated entrances: a turn and a pane can land in one
/// gesture, and a conversation must not change identity because two things
/// started it.
@MainActor
@Test func theConversationIdentityIsMintedOnceAndHeld() async {
    let model = await sessionlessModel()
    model.markSessionStarted()
    let first = model.assignedSessionId
    model.markSessionStarted()
    model.markSessionStarted()

    #expect(first != nil)
    #expect(model.assignedSessionId == first)
}

/// It is a UUID, because that is what `send` would otherwise have minted and
/// what the harness is started with — the value has to be usable as
/// `--session-id`, not merely unique.
@MainActor
@Test func theConversationIdentityIsAUsableSessionId() async {
    let model = await sessionlessModel()
    model.markSessionStarted()
    #expect(UUID(uuidString: model.assignedSessionId ?? "") != nil)
}
