import Foundation
import Testing
@testable import WakilKit

private func object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let o) = value else { return [:] }
    return o
}

private func orgSwitchRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)         // app/Tests/WakilKitTests/OrgSwitchTests.swift
        .deletingLastPathComponent()         // WakilKitTests
        .deletingLastPathComponent()         // Tests
        .deletingLastPathComponent()         // app
        .deletingLastPathComponent()         // repo root
}

/// Writes a minimal provider record directly to a scratch `HOME`, the same
/// way `StandardActionsTests.writeProviderFixture` does — duplicated here
/// (rather than made internal there) because that file's copy is `private`
/// and this task's tests need the same shape.
private func writeProviderFixtureForOrgSwitch(home: URL, org: String, id: String) throws {
    let dir = home.appendingPathComponent(".wakil/orgs/\(org)/providers")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"kind":"local"}"#.write(
        to: dir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
}

/// Pins the defect Task 7 closed: both stores once keyed on a project NAME
/// alone while `LayoutPersistence` keyed on `(org, project)`, so two orgs
/// each holding a project named `core` drew the first org's arrangement and
/// rows under the second org's name. `LayoutScope` carries the organisation,
/// so the collision cannot be expressed — and that is what lets an org switch
/// keep every scope (background agents 3 of 4): the org left is not drawn
/// under the incoming one, and it is still there to come back to.
@MainActor
@Test func twoOrgsWithTheSameProjectNameDoNotShareACanvas() async {
    let layout = LayoutStore()
    let inOrgA = LayoutScope(organization: "orga", project: "core", environment: "")
    let inOrgB = LayoutScope(organization: "orgb", project: "core", environment: "")
    await layout.switchScope(to: inOrgA)
    await layout.load(
        LayoutSnapshot(panes: [
            Pane(id: "db-1", kind: "db", title: "One", frame: PaneFrame(x: 0, y: 0, width: 100, height: 100))
        ]), for: inOrgA)
    #expect(await layout.snapshot().panes.count == 1)

    // "core" in org B is a DIFFERENT project that merely shares a name.
    await layout.switchScope(to: inOrgB)
    #expect(
        await layout.snapshot().panes.isEmpty,
        "org A's canvas must not be drawn under org B's identically-named project")

    await layout.switchScope(to: inOrgA)
    #expect(await layout.snapshot().panes.map(\.id) == ["db-1"], "the org left keeps its canvas")
}

/// The `PaneStore` half of the same collision — this store holds what is
/// IN the panes, `LayoutStore` holds where they are.
@MainActor
@Test func twoOrgsWithTheSameProjectNameDoNotShareRows() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    let inOrgA = LayoutScope(organization: "orga", project: "core", environment: "")
    let inOrgB = LayoutScope(organization: "orgb", project: "core", environment: "")
    await panes.switchScope(to: inOrgA)
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 1, truncated: false, pageable: false, offset: 0,
        sort: [], listsTables: false, editable: nil)
    #expect(object(await panes.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(1))

    await panes.switchScope(to: inOrgB)
    #expect(
        object(await panes.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(0),
        "org A's rows must not be drawn under org B's identically-named project's pane")

    await panes.switchScope(to: inOrgA)
    #expect(
        object(await panes.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(1),
        "the org left keeps its rows")
}

/// `invalidateForOrgChange()` resets what belongs to the organisation and
/// nothing that belongs to a place in it (background agents 3 of 4). Seeds
/// both kinds with non-default values, so a reset dropped from the contract
/// — or one added back for a place's state — fails here: a `Mirror` tripwire
/// can catch an unclassified NEW property, but not a reset quietly changed.
@MainActor
@Test func invalidationResetsTheOrgsContextAndKeepsEveryPlacesState() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let place = Place(organization: "alpha", project: "core", environment: "staging")
    model.seedForTesting(
        providerId: "acct", rootPath: "/a/core", thoughts: 3,
        databaseChoices: [
            "db-1": QueryLineDatabaseChoice(database: "orders", subjectDatabase: "orders")
        ],
        databases: ["orders", "billing"],
        layoutSnapshot: LayoutSnapshot(panes: [
            Pane(id: "db-1", kind: "db", title: "Orders", frame: PaneFrame(x: 0, y: 0, width: 100, height: 100))
        ]),
        project: "core", environment: "staging")

    await model.invalidateForOrgChange()

    // The organisation's own: reset, and re-derived by `refreshContext`.
    #expect(model.providerId.isEmpty)
    #expect(model.project.isEmpty)
    #expect(model.environment.isEmpty)
    #expect(model.rootPathForTesting == NSHomeDirectory())
    // The place's own: kept, under its place. (A waiting approval is the broker's, mirrored;
    // `anOrgSwitchWithAParkedApprovalSwitchesAnyway` parks a real one.)
    #expect(model.agents[place]?.thoughts.count == 3, "the place's thread is its own")
    #expect(model.databaseChoices["db-1"]?.database == "orders")
    #expect(model.databases == ["orders", "billing"])
    #expect(model.layoutSnapshot.panes.map(\.id) == ["db-1"])
}

/// Task 9's success half. Spec §5.3 and §6 item 2:
/// `invalidateForOrgChange()` clears `providerId` and `rootPath`, and
/// `refreshContext()` is the ONLY place that rebuilds them for the org just
/// switched to — off the very same `get_context` answer that already
/// supplies `project` and `environment`. Without this, `startHarness`
/// refuses the empty `providerId` outright and auto-resume has nothing to
/// select for, so the window would land in the new org with no agent.
///
/// Run against the real `bin/wakil-ctx` binary end to end — the same way
/// `ContextStoreTests` and `StandardActionsTests` exercise `ContextStore` —
/// rather than a fake double, because `get_context`'s wire shape
/// (`ActiveProvider`, `RootPaths`) is exactly the contract this path leans
/// on.
@MainActor
@Test func refreshContextRebuildsTheProviderAndTheRoot() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    try writeProviderFixtureForOrgSwitch(home: home, org: "beta", id: "work")
    let client = try await startedClient(bin: bin, home: home, org: "beta")

    let registry = ActionRegistry(
        journalDirectory: testScratchRoot
            .appendingPathComponent(UUID().uuidString),
        sessionId: "org-switch-refresh-success")
    await registerStandardActions(
        into: registry, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    // `makeFixture`'s one project is always named "widgets" and always
    // declares one root, "/tmp/widgets" — see that helper's own doc
    // comment in `ContextStoreTests.swift`.
    _ = try await registry.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("staging")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_provider", params: .object(["name": .string("work")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "beta", context: ContextStore(client: client))

    await model.refreshContext()
    await client.stop()

    #expect(model.providerId == "work")
    #expect(model.rootPathForTesting == "/tmp/widgets")
    // 2d-ii walk: the launch note "no project root available yet" is
    // derived from this read, so a project with a root clears it.
    #expect(model.noProjectRootNote == nil)
}

/// Task 9's failure half — the one that matters more. Before this change,
/// `refreshContext`'s `catch` set `status` and returned WITHOUT touching
/// `project`, `environment`, `providerId` or `rootPath` — so a `get_context`
/// failure right after an org switch left the outgoing org's provider and
/// root in place while `organization` already named the new org. That is
/// the wrong credential boundary, drawn confidently: a window that looks
/// exactly like a healthy session under org B while its agent would still
/// run under org A's provider (spec §6, Invariant 4).
///
/// Forced by pointing a real `bin/wakil-ctx` at an org whose registry exists
/// but which has never had a project set active — `get_context` refuses
/// that outright with "no active project" (`StandardActionsTests`'
/// `ctxSetProviderPersistsThroughTheRealBinaryAndIsVisibleToGetContext`
/// documents the same refusal) — exactly the shape a freshly switched-to
/// org is in before its own `active.json` exists.
@MainActor
@Test func refreshContextFailureClearsRatherThanKeepsAnotherOrgsValues() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    let client = try await startedClient(bin: bin, home: home, org: "beta")

    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "beta", context: ContextStore(client: client))
    // `project`/`environment` seeded non-default too — both are
    // `private(set)` and otherwise written only by `refreshContext()`
    // itself, so without seeding them here they would already be `""`
    // before the call, and the two assertions below would pass whether or
    // not the catch block still clears them (fix round 1, Important
    // finding).
    model.seedForTesting(
        providerId: "stale", rootPath: "/a/core", thoughts: 0,
        project: "orders", environment: "staging")

    await model.refreshContext()
    await client.stop()

    #expect(model.project.isEmpty, "a failed read must not leave org A's project in place")
    #expect(model.environment.isEmpty, "a failed read must not leave org A's environment in place")
    #expect(
        model.providerId.isEmpty, "a failed read must not leave org A's provider in place")
    #expect(
        model.rootPathForTesting == NSHomeDirectory(),
        "a failed read must fall back to home, not keep org A's root")
    #expect(
        model.noProjectRootNote?.contains("runs in \(NSHomeDirectory()) instead") == true,
        "with no root read, the window says where it runs instead")
}

/// 2d-ii walk: the note used to be a `notes` append in `WindowSession`,
/// fixed at launch, so it stayed on screen after a project with a root
/// was opened. Before any context is read there is no root.
@MainActor
@Test func noProjectRootNoteIsPresentUntilARootIsRead() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "beta")
    #expect(model.noProjectRootNote != nil)
}

// MARK: - Task 12: `autoResumeAfterSwitch()`

/// Newest first, which is `session_list`'s own guarantee. `s-other` is
/// newer than `s-new` in the fixture below but belongs to `personal`, not
/// `work` — the window's actual running provider — so it must lose to
/// `s-new` even though `s-new` appears second in the list. Picking
/// `s-other` would hand `resume(sessionId:)` a session it can only refuse
/// (that method's own `thread.provider == providerId` guard), which is
/// exactly the confusing-refusal outcome this method exists to avoid.
@MainActor
@Test func returningToAnOrgResumesItsNewestSessionForTheActiveProvider() async {
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        sessionRows: [
            .object(["id": .string("s-other"), "provider": .string("personal"), "cwd": .string("/b/orders")]),
            .object(["id": .string("s-new"), "provider": .string("work"), "cwd": .string("/b/orders")]),
            .object(["id": .string("s-old"), "provider": .string("work"), "cwd": .string("/b/orders")]),
        ])
    await model.seedForTesting(providerId: "work", rootPath: "/b/orders", thoughts: 0)

    await model.autoResumeAfterSwitch()

    #expect(model.resumedParentForTesting == "s-new",
            "newest FOR THIS PROVIDER — s-other is newer but belongs to another account")
}

/// Same provider is not enough on its own — the candidate also has to be
/// rooted at `rootPath`. `s-wrong-root` shares `work` with the active
/// provider AND is newer than `s-new` (`session_list`'s own newest-first
/// guarantee), so if the `cwd == rootPath` half of the candidate filter
/// were ever dropped, this row would win — silently, since nothing about
/// it looks wrong from the provider check alone. Fix round 1 (Important):
/// the first version of this file's four tests all reused the same `cwd`
/// literal for both the model's `rootPath` and every fixture row, so
/// deleting that clause left every one of them green.
@MainActor
@Test func returningToAnOrgIgnoresASameProviderSessionRootedElsewhere() async {
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        sessionRows: [
            .object(["id": .string("s-wrong-root"), "provider": .string("work"), "cwd": .string("/other/project")]),
            .object(["id": .string("s-new"), "provider": .string("work"), "cwd": .string("/b/orders")]),
            .object(["id": .string("s-old"), "provider": .string("work"), "cwd": .string("/b/orders")]),
        ])
    await model.seedForTesting(providerId: "work", rootPath: "/b/orders", thoughts: 0)

    await model.autoResumeAfterSwitch()

    #expect(model.resumedParentForTesting == "s-new",
            "same provider is not enough — s-wrong-root is newer but rooted in a different project")
}

/// No candidate at all — an empty `session_list` — must still leave the
/// window in a usable state: a fresh session, and a note saying why there
/// was nothing to resume, never silence.
@MainActor
@Test func autoResumeFallsBackToAFreshSessionWithANote() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha", sessionRows: [])
    await model.seedForTesting(providerId: "work", rootPath: "/b/orders", thoughts: 0)

    await model.autoResumeAfterSwitch()

    #expect(model.resumedParentForTesting == nil)
    #expect(model.status.contains("fresh session"))
}

/// A candidate IS found, but `resume(sessionId:)` itself cannot complete —
/// here because `forTesting`'s default `harnessFactory` returns `nil`, so
/// `resume` refuses with "no agent session available" and never replaces
/// `sessionId`. This must fall back exactly as the no-candidate case does
/// (never a dead window) but say a DIFFERENT thing, because the operator's
/// actual problem is different: a session existed and could not be
/// resumed, not that none existed at all.
@MainActor
@Test func autoResumeFallsBackWithANoteWhenResumeItselfFails() async {
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        sessionRows: [
            .object(["id": .string("s-1"), "provider": .string("work"), "cwd": .string("/b/orders")])
        ])
    await model.seedForTesting(providerId: "work", rootPath: "/b/orders", thoughts: 0)

    await model.autoResumeAfterSwitch()

    #expect(model.resumedParentForTesting == "s-1", "the session it TRIED to resume")
    #expect(model.sessionId == nil, "resume must not have actually replaced the session")
    #expect(model.status.contains("could not resume"), "\(model.status)")
    #expect(
        !model.status.contains("no previous session"),
        "a candidate existed — this must read differently from the no-candidate case: \(model.status)")
}

/// An empty `providerId` — a fresh org, or one that has never had an
/// account chosen — must return before dispatching anything at all.
/// `noActiveProviderNote` already names the fix, so `status` here must be
/// left exactly as it was: seeded first with a `resume` failure (a
/// deterministic sentinel this test can tell apart from anything
/// `autoResumeAfterSwitch` itself would write), so an implementation that
/// forgot the early-return guard — and fell through to the no-candidate
/// fallback, since nothing in the fixture has `provider == ""` — would
/// overwrite that sentinel and fail this assertion.
@MainActor
@Test func autoResumeWithNoActiveProviderLeavesStatusUntouched() async {
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        sessionRows: [
            .object(["id": .string("s-1"), "provider": .string("work"), "cwd": .string("/b/orders")])
        ])
    await model.seedForTesting(providerId: "work", rootPath: "/b/orders", thoughts: 0)
    // Seeds a deterministic, recognisable `status` — `session_read` is not
    // registered on this fixture's registry, so this always fails the
    // same way.
    await model.resume(sessionId: "nonexistent-id")
    let sentinel = model.status
    #expect(sentinel.contains("resume nonexistent-id"), "\(sentinel)")

    await model.seedForTesting(providerId: "", rootPath: "/b/orders", thoughts: 0)
    await model.autoResumeAfterSwitch()

    #expect(model.resumedParentForTesting == nil)
    #expect(model.status == sentinel, "an unset provider must return before touching status: \(model.status)")
}

// MARK: - Task 10: `setOrganization`

@MainActor
@Test func switchingToTheCurrentOrgIsRefused() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    await model.setOrganization("alpha")
    #expect(model.status.contains("already open"))
}

@MainActor
@Test func aFailedRestartLeavesTheWindowSayingSoRatherThanClaimingTheNewOrg() async {
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        orgSwitcher: { _ in ["wakil-db did not come back under beta: transportClosed"] })
    await model.setOrganization("beta")
    #expect(model.status.contains("did not come back"))
}

/// Fix round 1 (Important, upgraded from a reviewer Minor): the failure
/// path used to leave `organization` naming the OUTGOING org even though
/// `invalidateForOrgChange()` had already wiped every org-scoped property
/// the window held — a window claiming an org of which nothing usable
/// remains, and the same-org guard (`org != organization`) would then
/// refuse a retry of the very org whose state was just torn down. Only a
/// switch to some THIRD org could move the window at all.
///
/// A `@Sendable` mutable box, not two separate models, is what makes this
/// test actually exercise the retry: the first `setOrganization` call must
/// fail and the second must succeed, off the SAME `orgSwitcher` closure —
/// two models would each start fresh and never touch the guard this test
/// pins.
private final class FlakyOrgSwitcherForTesting: @unchecked Sendable {
    var diagnostics: [String] = []
    func attempt(_ org: String) async -> [String] { diagnostics }
}

@MainActor
@Test func aFailedSwitchClearsOrganizationSoARetryOfTheOutgoingOrgIsNotRefused() async {
    let switcher = FlakyOrgSwitcherForTesting()
    switcher.diagnostics = ["wakil-db did not come back under beta: transportClosed"]
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        orgSwitcher: { org in await switcher.attempt(org) })

    await model.setOrganization("beta")
    #expect(
        model.organization == "",
        "a failed switch must not leave the window claiming the gutted outgoing org")

    switcher.diagnostics = []
    await model.setOrganization("alpha")
    #expect(
        model.organization == "alpha",
        "the same-org guard must not refuse a retry of the org the failed switch just wiped")
}

// MARK: - Waiting

/// Polls `condition` until it holds or the budget runs out. The production
/// event pump `startEventPump` starts is a separate `Task`, so a test that
/// checked immediately after yielding an event onto a harness's stream
/// would be asserting on a race rather than on the model — the same reason
/// `WindowModelTests.swift`'s own (`private`, so not reusable here)
/// `waitUntil` exists.
///
/// `seconds` defaults to ten, not the two this file's model-only tests
/// first had. A switch that lands in ~9ms alone took up to 6.9s inside the
/// full suite with a second copy of it running on the same 8-core machine
/// — every one of this file's main-actor tests queued on one thread — and
/// two tests failed at two seconds while never actually losing the switch.
/// Every caller waits for something to HAPPEN, so the budget costs nothing
/// on a pass. A caller that has to wait on a real shell spawning, running a
/// command and sealing its block passes its own, larger budget.
@MainActor
private func waitUntilOrgSwitch(
    seconds: Double = 10, _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

// MARK: - A lookup that always succeeds

/// Always succeeds, ignoring the provider id — the same shape every one
/// of this codebase's several private `AlwaysSucceedsCredentialsLookup`
/// copies takes (`WindowModelTests.swift`, `WindowModel.swift` itself,
/// `StandardActionsTests.swift`), reproduced here for the same reason:
/// each is `private` to its own file.
private struct AlwaysSucceedsCredentialsLookupForOrgSwitch: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}

// MARK: - Task 11 fix round 3

/// Restarts a SHARED, real `MCPClient` in place under a new `WAKIL_ORG` —
/// the identical stop-then-start-in-place shape
/// `WakilWiring.switchOrg(to:)` uses in production (`AppWiring.swift`) —
/// rather than a synthetic double, so `fix round 3`'s coherence test reads
/// `organization`/`providerId` off a REAL `get_context` answer, not two
/// values this test set by hand and merely hopes agree the way production
/// would.
///
/// `armHold()`/`isHolding()`/`release()` gate the FIRST call's restart the
/// same one-shot `CheckedContinuation` way `ConfirmationBroker`'s testing
/// hold does — deterministic, not scheduling luck, per this task's own
/// standing rule: plain scheduling measured unreliable once other tests
/// shared the executor.
private actor SharedClientOrgSwitcherForTesting {
    private let client: MCPClient
    private let home: URL
    private(set) var attempts: [String] = []
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?

    init(client: MCPClient, home: URL) {
        self.client = client
        self.home = home
    }

    func armHold() { holdNext = true }
    func isHolding() -> Bool { gate != nil }
    func release() {
        gate?.resume()
        gate = nil
    }

    func attempt(_ org: String) async -> [String] {
        attempts.append(org)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                gate = k
            }
        }
        await client.stop()
        do {
            try await client.start(environment: [
                "HOME": home.path, "PATH": "/usr/bin:/bin", "WAKIL_ORG": org,
            ])
        } catch {
            return ["\(error)"]
        }
        return []
    }
}

/// Fix round 3 (Critical, credential boundary — the gap fix round 2 flagged
/// rather than fixed unasked, now fixed). `setOrganization` had no
/// reentrancy guard of its own: a `requestOrganizationSwitch` landing
/// while `fireQueuedSwitchIfReady()` (or another `requestOrganizationSwitch`)
/// was mid-flight would see `turnInFlight == false` and call
/// `setOrganization` directly, running two switches concurrently —
/// interleaving at `orgSwitcher`, `refreshContext` and
/// `autoResumeAfterSwitch`'s own suspension points, any of which can leave
/// `organization` naming one org while the provider/harness/session
/// actually wired up belongs to the other (Invariant 4).
///
/// **Real backend, not a synthetic pairing.** `gamma` is a bare, empty org
/// directory — no project, no provider — the same shape
/// `refreshContextFailureClearsRatherThanKeepsAnotherOrgsValues` above
/// uses to force a real `get_context` refusal, so if `gamma`'s switch ever
/// reached the backend at all, that would be independently observable
/// (a `context:` status, not "already in progress"). `beta` has a real
/// project and a real persisted provider (`work`), exactly like
/// `refreshContextRebuildsTheProviderAndTheRoot` above sets up, so a
/// successful switch's `providerId` is read off a genuine `get_context`
/// answer, not asserted by fiat.
@MainActor
@Test func twoConcurrentSetOrganizationCallsProduceExactlyOneCoherentSwitch() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    try writeProviderFixtureForOrgSwitch(home: home, org: "beta", id: "work")
    // `gamma`: a real org directory with nothing registered under it — see
    // this test's own doc comment for why that is the shape that makes a
    // reached-the-backend-at-all switch to it independently observable.
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".wakil/orgs/gamma"), withIntermediateDirectories: true)

    // Persists beta's own active project/environment/provider selection —
    // exactly the three dispatches `refreshContextRebuildsTheProviderAndTheRoot`
    // above makes — through a short-lived client of its own, BEFORE the
    // shared client below ever exists: without this, `get_context` has
    // nothing to answer with and `providerId` reads back empty regardless
    // of which switch wins, which would make this test's own coherence
    // assertion vacuous rather than diagnostic.
    do {
        let setupClient = try await startedClient(bin: bin, home: home, org: "beta")
        let setupRegistry = ActionRegistry(
            journalDirectory: testScratchRoot
                .appendingPathComponent(UUID().uuidString),
            sessionId: "fix-round-3-setup")
        await registerStandardActions(
            into: setupRegistry, context: setupClient, panes: PaneStore(), db: nil, resumes: ResumeBroker())
        _ = try await setupRegistry.dispatch(
            name: "ctx_set_project", params: .object(["name": .string("widgets")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        _ = try await setupRegistry.dispatch(
            name: "ctx_set_environment", params: .object(["name": .string("staging")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        _ = try await setupRegistry.dispatch(
            name: "ctx_set_provider", params: .object(["name": .string("work")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
        await setupClient.stop()
    }

    let client = MCPClient(
        executable: bin, arguments: [],
        environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
    try await client.start()

    let switcher = SharedClientOrgSwitcherForTesting(client: client, home: home)
    let scratch = testScratchRoot.appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: scratch, sessionId: "fix-round-3-reentrancy")
    let model = WindowModel(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        context: ContextStore(client: client),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForOrgSwitch() },
        orgSwitcher: { org in await switcher.attempt(org) },
        rootWatcher: nil, editorRootWatcher: nil, fileLists: nil, gitStatus: nil, paletteClients: PaletteClients(), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() })
    model.setOrganizationForTesting("alpha")

    await switcher.armHold()
    let first = Task { await model.setOrganization("beta") }
    // Deterministic, not scheduling luck: waits for `beta`'s own attempt
    // to have actually reached (and parked inside) the armed hold.
    #expect(await waitUntilOrgSwitch { await switcher.isHolding() })

    // The loser: lands while `beta`'s switch is mid-flight (`switching`
    // already true), before its own restart of the shared client has even
    // happened.
    await model.setOrganization("gamma")
    #expect(model.status.contains("a switch is already in progress"), "\(model.status)")
    #expect(model.organization == "alpha", "the refused call must not have touched organization")

    await switcher.release()
    await first.value

    #expect(model.organization == "beta")
    #expect(model.providerId == "work", "organization and providerId must agree about which org won")
    #expect(
        await switcher.attempts == ["beta"],
        "gamma's switch must never have reached the org switcher (the real backend) at all")

    await client.stop()
}

// MARK: - Final fix pass, Critical 1: the credentials lookup and the live org

/// Records every org `lookupFactory` was called with, in order.
///
/// **Recording rather than discarding is the entire point of this type.**
/// Every other `lookupFactory:`/`lookup:` call site in this suite passes
/// `{ _ in … }` and throws the org argument on the floor, which is exactly
/// why a `lookupFactory` that was never once called with a real org
/// survived fifteen task reviews: the stub made every test pass no matter
/// what org the model asked for. `OrgRecorder` in `WindowModelTests.swift`
/// is the harness-factory half's twin and is `private` to that file, so
/// this is the same shape kept here.
private final class LookupOrgRecorder: @unchecked Sendable {
    private(set) var orgs: [String] = []
    func record(_ org: String) { orgs.append(org) }
    var last: String? { orgs.last }
}

/// **(a) At launch.** The credentials lookup a window resolves every
/// provider through must be built for the org the window is actually
/// running under — and at launch the only path that learns that org is
/// `refreshContext()`.
///
/// The regression this pins (final fix pass, Critical 1) needed no switch
/// at all. `lookup` had exactly two assignment sites, `init` and
/// `invalidateForOrgChange()`, and both passed `""`; nothing ever called
/// `lookupFactory` with a real org. Production builds
/// `WakilCLICredentialsLookup(executable:organization:)`, which shells out
/// to `wakil --org <organization> provider credentials <id>`, and
/// `--org ""` makes `cmd/wakil/main.go` do `os.Setenv("WAKIL_ORG", "")` —
/// defeating the inherited parent environment — after which `CurrentOrg()`
/// refuses outright. So `startHarness()`, `resume(sessionId:)`,
/// `setProvider(_:)` and `autoResumeAfterSwitch()` all ended at
/// `ProviderCredentialsLookupError.refused`, and no agent session could
/// start in any window. Fail-CLOSED — no wrong org's credential was ever
/// handed out, so Invariant 4 held — but the app's whole agent capability
/// was gone.
///
/// **Built like a real window, not via `forTesting`**: `organization` is
/// `""` until `refreshContext()` answers, which is what a launch actually
/// is. Run against the real `bin/wakil-ctx`, like
/// `refreshContextRebuildsTheProviderAndTheRoot` above, so the org the
/// lookup is asserted against is one a genuine `get_context` reported.
@MainActor
@Test func theCredentialsLookupIsBuiltForTheOrgTheWindowLaunchesInto() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    try writeProviderFixtureForOrgSwitch(home: home, org: "beta", id: "work")
    let client = try await startedClient(bin: bin, home: home, org: "beta")

    let registry = ActionRegistry(
        journalDirectory: testScratchRoot
            .appendingPathComponent(UUID().uuidString),
        sessionId: "org-switch-lookup-at-launch")
    await registerStandardActions(
        into: registry, context: client, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    _ = try await registry.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("staging")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_provider", params: .object(["name": .string("work")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let seen = LookupOrgRecorder()
    let model = WindowModel(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        context: ContextStore(client: client),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { org in
            seen.record(org)
            return AlwaysSucceedsCredentialsLookupForOrgSwitch()
        },
        rootWatcher: nil, editorRootWatcher: nil, fileLists: nil, gitStatus: nil, paletteClients: PaletteClients(), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() })
    #expect(
        seen.orgs == [""],
        "init's org-less placeholder is all a window has before it has learned its org")

    await model.refreshContext()
    await client.stop()

    #expect(model.organization == "beta")
    #expect(
        seen.last == "beta",
        """
        the lookup every provider is resolved through must be built for the org the window \
        launched into, not for the empty placeholder — a lookup built for "" shells out to \
        `wakil --org ""`, which refuses, so no agent session can start at all
        """)
}

/// **(b) After a switch.** The same property on the other path: moving a
/// window to another organisation must rebuild the lookup for the org it
/// moved to. `setOrganization` writes `organization` itself, and this
/// asserts the lookup follows that write.
///
/// **`context` is `nil` here deliberately, which is the sharp half.**
/// `refreshContext()` also rebuilds the lookup (the test above), so a
/// rebuild that lived only there would look correct on the happy path and
/// fail exactly where it matters: a freshly created org whose
/// `get_context` refuses takes `refreshContext`'s `catch` and rebuilds
/// nothing, leaving a window that claims org B holding org A's — or, as
/// shipped, nobody's — credential lookup
/// (`refreshContextFailureClearsRatherThanKeepsAnotherOrgsValues` above
/// pins that refusal as a real shape). A `nil` context is the same
/// no-answer case, reached without a second binary. So the rebuild is
/// asserted on `setOrganization`'s own path, independent of any refresh.
@MainActor
@Test func theCredentialsLookupIsRebuiltForTheOrgTheWindowSwitchesTo() async {
    let seen = LookupOrgRecorder()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        lookupFactory: { org in
            seen.record(org)
            return AlwaysSucceedsCredentialsLookupForOrgSwitch()
        })
    #expect(seen.last == "alpha", "the launch org, before any switch")

    await model.setOrganization("beta")

    #expect(model.organization == "beta")
    #expect(
        seen.last == "beta",
        """
        `organization` and `lookup` must name the same org after a switch. Built for the \
        OUTGOING org it would resolve org A's credentials inside org B — the cross-org pairing \
        Invariant 4 exists to make structurally impossible; built for the "" placeholder \
        (what shipped) it resolves nobody's, and the org just switched to gets no agent \
        session at all
        """)
}

// MARK: - The stores survive the switch

/// `invalidateForOrgChange()` once ended by clearing both stores, which made
/// an org switch forget every canvas and every row. Background agents 3 of 4
/// keeps them: each is keyed by its scope, which carries the organisation,
/// so nothing of the org left can be drawn under the incoming one — and
/// returning finds it as it was left.
///
/// **Seeded through the model, not around it.** The stores here are the
/// model's own; the project is switched by `refreshContext()` (which is
/// what calls `activateLayout()`), the pane is opened by `pane_open`
/// through `openPane(kind:)`, and the assertions read the projections the
/// window actually draws from, after the `refreshLayout()`/`refreshPanes()`
/// a landing performs. Rows go in through `PaneStore.setRows` directly, as
/// `LayoutActionsTests` and `WindowModelTests` seed them.
@MainActor
@Test func invalidationKeepsBothStoresAndTheirRows() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    let client = try await startedClient(bin: bin, home: home, org: "beta")

    // The model's OWN stores, held here so the test can see what the
    // teardown did to them — not a second pair standing in for them.
    let panes = PaneStore()
    let layout = LayoutStore()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot
            .appendingPathComponent(UUID().uuidString),
        sessionId: "org-switch-store-clears")
    await registerStandardActions(
        into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker())
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    _ = try await registry.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("staging")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        context: ContextStore(client: client),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForOrgSwitch() },
        rootWatcher: nil, editorRootWatcher: nil, fileLists: nil, gitStatus: nil, paletteClients: PaletteClients(), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() })

    // The project switch, through the one path that makes one: this is
    // what puts both stores on project "widgets".
    await model.refreshContext()
    #expect(model.project == "widgets", "\(model.status)")

    // A pane on the canvas, and rows inside it.
    await model.openPane(kind: "db")
    let paneId = try #require(model.layoutSnapshot.panes.first?.id)
    await panes.setRows(
        paneId: paneId, columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 1, truncated: false, pageable: false, offset: 0,
        sort: [], listsTables: false, editable: nil)
    await model.refreshPanes()
    #expect(model.layoutSnapshot.panes.count == 1, "seeded, or the assertions below are vacuous")
    #expect(model.table(paneId).rows.count == 1, "seeded, or the assertions below are vacuous")

    await model.invalidateForOrgChange()
    // Re-read exactly the way a landing re-reads them.
    await model.refreshLayout()
    await model.refreshPanes()
    await client.stop()

    #expect(model.layoutSnapshot.panes.map(\.id) == [paneId], "the arrangement is kept")
    #expect(model.table(paneId).rows.count == 1, "and the rows in it")
}

// MARK: - Spec §6.3: what a failed `get_context` still tells the window

/// The pure half of §6.3, with no process involved.
///
/// `PartialContext` exists because `get_context` answers `isError: true`
/// *and* a `structuredContent` naming the org and the active provider —
/// Go's `wakilcore.PartialResolved`. This pins the parse, including the
/// two shapes an older binary produces, because the whole point of the
/// type is that it is read on a path where nothing may throw.
@Test func parsePartialContextReadsWhatItCanAndInventsNothing() {
    let full = ContextStore.parsePartialContext(.object([
        "Org": .string("initech"), "ActiveProvider": .string("main"),
        "Environment": .string(""), "Project": .null,
    ]))
    #expect(full == PartialContext(org: "initech", activeProvider: "main"))

    // An org that has never picked a provider: `ActiveProvider` carries
    // `omitempty`, so the key is simply absent. Not a parse failure.
    #expect(
        ContextStore.parsePartialContext(.object(["Org": .string("initech")]))
            == PartialContext(org: "initech", activeProvider: ""))

    // A `wakil-ctx` built before §6.1 reports no partial at all, and a
    // transport that returned no structured content at all is the same
    // case. Both must read as "not knowable" rather than throwing on the
    // error path.
    #expect(ContextStore.parsePartialContext(nil) == PartialContext())
    #expect(ContextStore.parsePartialContext(.string("nope")) == PartialContext())

    // Mistyped keys are ignored individually rather than failing the
    // whole parse: a readable org is still worth having when the provider
    // is garbage.
    #expect(
        ContextStore.parsePartialContext(.object([
            "Org": .string("initech"), "ActiveProvider": .number(7),
        ])) == PartialContext(org: "initech", activeProvider: ""))
}

/// **The launch defect, found on the 2b-viii acceptance walk (check 13).**
///
/// `organization` is assigned in exactly three places: `refreshContext`'s
/// success path and `setOrganization`'s two. Spec §6.2 says the switch path
/// assigns it authoritatively before `refreshContext` runs — true, and it
/// is why the `catch` deliberately left `organization` alone. But a
/// **launch** takes neither: there is no `setOrganization` on the way into
/// the first org, and an org with no active project never reaches the
/// success path. So `WAKIL_ORG=initech` — a real, healthy org whose only
/// distinction is that no project is active in it yet — opened a window
/// with `organization == ""`, which `WakilWindow`'s `hasOpenOrg` reads as
/// "no organisation is open" and answers by force-opening the org plane,
/// undismissable, over an org that was perfectly fine. Launching into an
/// org that *did* have an active project worked, which is what made this
/// look like a per-org quirk rather than a code path.
///
/// The fixture is `initech`'s exact shape: a registered org, an `active.json`
/// naming a provider, and no active project.
@MainActor
@Test func aLaunchIntoAnOrgWithNoActiveProjectStillLearnsTheOrgAndItsProvider() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    // No project made active, but a provider picked — `initech`'s own
    // `active.json`, verbatim in shape.
    try #"{"project":"","environment":"","provider":"work"}"#.write(
        to: home.appendingPathComponent(".wakil/orgs/beta/active.json"),
        atomically: true, encoding: .utf8)
    let client = try await startedClient(bin: bin, home: home, org: "beta")

    // `organization: ""` is the launch shape: nothing has told this window
    // which org it is in yet. That is the whole point — a test seeded with
    // an org would pass with or without the fix.
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "", context: ContextStore(client: client))

    await model.refreshContext()
    await client.stop()

    #expect(
        model.organization == "beta",
        "a launch must learn its org from the error's partial, or the window opens org-less")
    #expect(
        model.providerId == "work",
        "active.json named a provider and the server reported it; clearing it strands autoResumeAfterSwitch at its first guard")
}

/// The switch path's half of the same change, and the reason `organization`
/// is assigned conditionally rather than unconditionally.
///
/// §6.2's ruling stands: the id `setOrganization` switched to is more
/// authoritative than anything `get_context` reports, because it is the
/// string Wakil itself put into the child's environment. So a window that
/// already knows its org must keep that answer, and only a window that does
/// not (the launch above) may take the server's.
@MainActor
@Test func aFailedReadDoesNotOverwriteAnOrgTheSwitchPathAlreadyAssigned() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    let client = try await startedClient(bin: bin, home: home, org: "beta")

    // The window believes it is in `alpha` — what `setOrganization` would
    // have assigned — while the server it is talking to is running as
    // `beta`. Contrived on purpose: it is the one arrangement that can
    // tell "assigned only when empty" apart from "always assigned".
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha", context: ContextStore(client: client))

    await model.refreshContext()
    await client.stop()

    #expect(
        model.organization == "alpha",
        "spec §6.2: the id the switch assigned outranks what get_context reports")
}

// MARK: - Spec §12 check 3: a restored canvas re-runs its subjects

/// **The defect the acceptance walk found in checks 3, 5, 8, 12 and 13.**
///
/// A layout file persists the pane's *subject* and never its rows, on
/// purpose. So loading one produces panes with a frame, a title and a query
/// and nothing in them, and something has to run the query.
/// `restorePaneContents()` is that something, and before this fix it had
/// three callers — `WakilWindow` at launch, `setEnvironment`, and the
/// observation pump's `ctx_set_environment` branch. `activateLayout()`, the
/// one place an **org switch** reaches, was none of them.
///
/// The failure was silent by construction: `restorePaneContents` swallows
/// per-pane failures so one dropped table cannot stop the others, so a
/// refetch that never happened looks exactly like a refetch that came back
/// empty. Every pane restored by a switch read "no rows" — not an error,
/// not empty-because-empty — and the operator's journal showed zero
/// `db_refetch` rows after any org switch.
///
/// This drives the real chain (`refreshContext` → `activateLayout` → load
/// from disk → refetch) rather than calling `restorePaneContents()`
/// directly, because calling it directly is precisely what the shipped code
/// did not do.
@MainActor
@Test func restoringAnOrgsCanvasFromDiskRerunsEachDbPanesSubject() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    let client = try await startedClient(bin: bin, home: home, org: "beta")

    let layoutDir = testScratchRoot
        .appendingPathComponent("org-switch-restore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: layoutDir) }
    let persistence = LayoutPersistence(directory: layoutDir)
    // A canvas saved under (beta, widgets) exactly as a previous session in
    // this org would have left it — `makeFixture`'s project is `widgets`.
    try persistence.save(
        LayoutSnapshot(
            panes: [
                Pane(id: "db-1", kind: "db", title: "events",
                     frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                     fetch: PaneFetch(query: .sql(database: "events", raw: "select * from events"))),
            ],
            focusedId: "db-1"),
        for: LayoutScope(organization: "beta", project: "widgets", environment: ""))

    let registry = ActionRegistry(
        journalDirectory: testScratchRoot
            .appendingPathComponent(UUID().uuidString),
        sessionId: "restore-after-switch")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerStandardActions(
        into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker(),
        layout: layout)
    // Make `widgets` the active project, so `refreshContext` resolves and
    // `activateLayout` has a project to file the canvas under.
    _ = try await registry.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, persistence: persistence,
        context: ContextStore(client: client), harnessFactory: { _ in nil },
        resumes: ResumeBroker(), rootPath: "/tmp/widgets", providerId: "work",
        lookup: AlwaysSucceedsCredentialsLookupForOrgSwitch())

    await model.refreshContext()
    await client.stop()

    // The arrangement came back…
    #expect(model.layoutSnapshot.panes.map(\.id) == ["db-1"])
    // …and so did the attempt to fill it. With no database client the
    // refetch fails, which is fine and is not what is under test: what is
    // under test is that the subject was run at all, for the right pane.
    let refetches = try await registry.journalEntries().filter { $0.action == "db_refetch" }
    #expect(
        !refetches.isEmpty,
        "a canvas restored from disk must re-run each db pane's subject (spec §12 check 3)")
    for entry in refetches {
        #expect(entry.params == .object(["pane": .string("db-1")]))
    }
}

/// The other half of the gate, and the reason it is not "refetch whenever
/// `activateLayout` runs".
///
/// `LayoutStore`/`PaneStore` keep an outgoing project's contents in memory
/// so that coming back to a project finds it as it was left — a feature
/// earlier sub-phases accepted and tested. Re-running every subject on an
/// in-memory return would quietly repeal it. Only a genuine read from disk
/// produces panes holding no rows, so only that case refetches.
@MainActor
@Test func returningToAProjectAlreadyInMemoryDoesNotRerunItsSubjects() async throws {
    let bin = orgSwitchRepoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeFixture(org: "beta", projectOrg: "beta", environments: ["staging"])
    let client = try await startedClient(bin: bin, home: home, org: "beta")

    // No layout file on disk for (beta, widgets): `persistence.load`
    // answers `nil`, so nothing was restored and nothing may be refetched.
    let layoutDir = testScratchRoot
        .appendingPathComponent("org-switch-no-restore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: layoutDir) }

    let registry = ActionRegistry(
        journalDirectory: testScratchRoot
            .appendingPathComponent(UUID().uuidString),
        sessionId: "no-restore")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerStandardActions(
        into: registry, context: client, panes: panes, db: nil, resumes: ResumeBroker(),
        layout: layout)
    _ = try await registry.dispatch(
        name: "ctx_set_project", params: .object(["name": .string("widgets")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        persistence: LayoutPersistence(directory: layoutDir),
        context: ContextStore(client: client), harnessFactory: { _ in nil },
        resumes: ResumeBroker(), rootPath: "/tmp/widgets", providerId: "work",
        lookup: AlwaysSucceedsCredentialsLookupForOrgSwitch())

    await model.refreshContext()
    await client.stop()

    let refetches = try await registry.journalEntries().filter { $0.action == "db_refetch" }
    #expect(
        refetches.isEmpty,
        "nothing was restored from disk, so nothing may be refetched — the in-memory find-it-as-you-left-it property must survive")
}

/// **The operator reads `status`, so an error in it must be the server's
/// sentence and nothing else.**
///
/// `refreshContext`'s `catch` sets `status = "context: \(error)"`. While
/// `serverError` carried one string that produced `context:
/// serverError("no active project — run set_project first")` — ugly, and
/// nobody had called it. Adding §6.3's `partial` made it a leak: the walk
/// photographed a status line reading `context: serverError("no active
/// project — run set_project first", partial: WakilKit.PartialContext(org:
/// "orga", activeProvider: ""))` — a Swift type name and a memberwise
/// initializer, shown to a human.
///
/// `partial` is for code. This pins that it never reaches the screen, and
/// that the server's message arrives verbatim, which is `ContextStore`'s
/// own stated contract.
@Test func aContextErrorPrintsTheServersSentenceAndNoSwiftDetail() {
    let error = ContextStoreError.serverError(
        "no active project — run set_project first",
        partial: PartialContext(org: "orga", activeProvider: ""))

    let rendered = "context: \(error)"

    #expect(rendered == "context: no active project — run set_project first")
    #expect(!rendered.contains("PartialContext"), "the operator must never be shown a Swift type")
    #expect(!rendered.contains("serverError"), "nor an enum case name")
    #expect(!rendered.contains("partial:"), "nor a memberwise label")

    // The other case carries no payload to leak, and must still print its
    // own message rather than its case name.
    #expect("\(ContextStoreError.malformedResult("no structuredContent"))" == "no structuredContent")
}

/// **The third instance of one defect, so this pins the class rather than
/// the instance.**
///
/// `WindowModel` renders caught errors straight into `status` — and, for a
/// query, into the failing pane in red. Any `Error` without a `description`
/// therefore shows the operator Swift's synthesized enum form. The
/// acceptance walk met it three times: `ContextStoreError` leaking a
/// `PartialContext` struct, and then `db_run_mutation:
/// blockedInProduction("db_run_mutation")` on the production check — a case
/// name, its payload quoted, and the action named twice.
///
/// Every type below can reach `status`. A new one that can must be added
/// here, and a case added to any of them will fail this test only if its
/// wording regresses — which is the most a test can do about prose.
@Test func noOperatorFacingErrorPrintsItsSwiftCaseName() {
    // Each description must read as a sentence: no case name, no payload
    // parentheses, no Swift type name.
    let rendered: [String] = [
        "\(ActionError.unknown("db_run_query"))",
        "\(ActionError.needsConfirmation("db_run_mutation"))",
        "\(ActionError.blockedInProduction("db_run_mutation"))",
        "\(ContextStoreError.serverError("no active project", partial: PartialContext(org: "a")))",
        "\(ContextStoreError.malformedResult("no structuredContent"))",
        "\(ProviderCredentialsLookupError.refused("no credential stored for ref provider:main"))",
        "\(ClaudeCodeCLIHarnessError.notRunning)",
        "\(ClaudeCodeCLIHarnessError.alreadyStarted)",
        "\(ClaudeCodeCLIHarnessError.alreadyStopped)",
        "\(MCPClientError.notRunning)",
        "\(MCPClientError.timeout(method: "initialize"))",
        "\(MCPClientError.rpcError(code: -32601, message: "Unknown action: x"))",
        "\(MCPClientError.transportClosed(underlying: nil))",
        "\(MCPClientError.malformedResult("tools/list without a tools array"))",
    ]
    let caseNames = [
        "unknown(", "needsConfirmation(", "blockedInProduction(", "serverError(",
        "malformedResult(", "refused(", "notRunning", "alreadyStarted", "alreadyStopped",
        "timeout(", "rpcError(", "transportClosed(", "PartialContext", "WakilKit.",
    ]
    for text in rendered {
        #expect(!text.isEmpty)
        for name in caseNames {
            #expect(!text.contains(name), "\(text) still prints the Swift name \(name)")
        }
    }

    // `blockedInProduction` and `needsConfirmation` must not read alike:
    // one is an invitation to type `confirm`, the other is a wall.
    // `WindowModel.statusDescribingFailure` prepends the action name only
    // when the sentence does not already carry it, so both start with it.
    let blocked = "\(ActionError.blockedInProduction("db_run_mutation"))"
    #expect(blocked.hasPrefix("db_run_mutation:"), "or statusDescribingFailure will stutter it")
    #expect(blocked.contains("blocked in production"))
    #expect(
        blocked.contains("no confirmation will run it"),
        "blocked is not gated, and an operator who reads it as 'confirm harder' hunts for a plane that never appears")
    #expect("\(ActionError.needsConfirmation("db_run_mutation"))".contains("type confirm"))
}

/// **An org switch kills no shell** (background agents 3 of 4). It used to
/// await `terminals.shutdownAll()` beside the store clears; a shell now lives
/// until its pane closes or the window does, wherever the screen goes, and
/// keeps its own place's `WAKIL_ORG` — it was started with it.
@MainActor
@Test func anOrgSwitchKeepsEveryShellRunning() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    let pid = try #require(await model.terminals.pidForTesting(paneId: pane))

    await model.setOrganization("beta")

    #expect(model.organization == "beta", "\(model.status)")
    #expect(kill(pid, 0) == 0, "the shell left behind is still running")
    await model.shutdown()
    #expect(kill(pid, 0) == -1, "the window's end is what ends it")
}

/// **The run pump outlives the switch** — final review's Critical 1, and
/// the assertion whose absence let that ship: one org switch once ended
/// `terminalRunPump`'s `for await` for good, and every command run in every
/// pane from then on went unjournalled. A switch no longer touches the
/// terminals at all; this keeps the claim pinned.
@MainActor
@Test func theRunPumpKeepsJournallingAfterAnOrgSwitch() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let before = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: before, text: "printf before\n")
    #expect(
        await waitUntilOrgSwitch(seconds: 10) { await model.journalledRuns().count == 1 },
        "the first run must journal even before any switch")

    await model.setOrganization("beta")

    let after = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: after, text: "printf after\n")
    #expect(
        await waitUntilOrgSwitch(seconds: 10) { await model.journalledRuns().count == 2 },
        "a run in the new org went unjournalled — the pump died with the switch")

    let commands = await model.journalledRuns().compactMap { entry -> String? in
        guard case .object(let params) = entry.params,
              case .string(let command)? = params["command"] else { return nil }
        return command
    }
    #expect(commands == ["printf before", "printf after"])
    await model.shutdown()
}

/// **An organisation switch must not be blocked by a running shell**, and
/// now does not stop it either: `yes wakil` never exits, so a switch that
/// waited for it would hang rather than fail. Reaching the end is the claim.
@MainActor
@Test func anOrgSwitchIsNotBlockedByAShellThatIsStillRunning() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: pane, text: "yes wakil\n")

    await model.setOrganization("beta")

    #expect(model.organization == "beta", "\(model.status)")
    await model.shutdown()
}

// MARK: - Background agents 3 of 4, Task 6: an organisation switch tears nothing down

private let initechPlace = Place(organization: "initech", project: "api", environment: "staging")
private let umbrellaPlace = Place(organization: "umbrella", project: "web", environment: "staging")

/// A `wakil-ctx` that answers for whichever organisation the window last switched to — the
/// switcher below moves it — each with a project of its own, so a switch really changes the
/// place on screen and `refreshContext` really re-reads it. `hollow` has no active project, nor
/// has `noProjectIn` when set.
private actor TwoOrgContext: ToolCaller {
    private var org = "initech"
    private let noProjectIn: String?
    init(noProjectIn: String? = nil) { self.noProjectIn = noProjectIn }
    func use(_ org: String) { self.org = org }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard name == "get_context" else { return .object(["structuredContent": .object([:])]) }
        if org == "hollow" || org == noProjectIn {
            return .object(["structuredContent": .object([
                "Org": .string(org), "Environment": .string(""), "Project": .null,
                "ActiveProvider": .string("main"),
            ])])
        }
        let place = org == "umbrella" ? umbrellaPlace : initechPlace
        return .object(["structuredContent": .object([
            "Org": .string(place.organization), "Environment": .string(place.environment),
            "Project": .object(["name": .string(place.project)]),
            "RootPaths": .array([.string(NSTemporaryDirectory())]),
            "ActiveProvider": .string(place == umbrellaPlace ? "umbrella-main" : "main"),
        ])])
    }
}

/// A window launched into initech, whose org switcher re-points `TwoOrgContext` as
/// `WakilWiring.switchOrg` re-points the window's clients.
@MainActor
private func twoOrgWindow(
    _ harnesses: Harnesses = Harnesses(), persistence: LayoutPersistence? = nil,
    lookups: LookupOrgRecorder? = nil, failingRestart: String? = nil,
    lookup: (any ProviderCredentialsLookup)? = nil, placeClients: PlaceClients? = nil,
    vocabulary: VocabularyStore? = nil, refusesHarnesses: HarnessRefusal? = nil,
    confirmations: ConfirmationBroker = ConfirmationBroker(), noProjectIn: String? = nil
) async -> WindowModel {
    let context = TwoOrgContext(noProjectIn: noProjectIn)
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "initech",
        harnessFactory: { place, _ in refusesHarnesses?.on == true ? nil : harnesses.make(place) },
        lookupFactory: { org in
            lookups?.record(org)
            return lookup ?? AlwaysSucceedsCredentialsLookupForOrgSwitch()
        },
        context: ContextStore(client: context),
        orgSwitcher: { org in
            if org == failingRestart { return ["wakil-db did not come back under \(org): transportClosed"] }
            await context.use(org)
            return []
        },
        confirmations: confirmations, vocabulary: vocabulary, placeClients: placeClients,
        persistence: persistence)
    await model.refreshContext()
    return model
}

/// Review focus 3: no queue, no prompt, no refusal. The agent keeps streaming into its own
/// thread and its shell keeps running, while the screen shows the other organisation.
@MainActor
@Test func anOrgSwitchLeavesTheRunningAgentAlone() async throws {
    let harnesses = Harnesses()
    let model = await twoOrgWindow(harnesses)
    #expect(model.place == initechPlace)
    #expect(await model.send("a long job"))
    let agent = try #require(model.agents[initechPlace])
    let harness = try #require(harnesses.in(initechPlace).first)
    let shell = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    let pid = try #require(await model.terminals.pidForTesting(paneId: shell))

    await model.requestOrganizationSwitch("umbrella")

    #expect(model.organization == "umbrella", "switched at once, not queued: \(model.status)")
    #expect(model.place == umbrellaPlace)
    #expect(!harness.stopped, "initech's harness is not stopped")
    #expect(model.agents[initechPlace] === agent)
    #expect(agent.turnInFlight, "its turn is still in flight")
    harness.emit(.assistantText("still working"))
    #expect(
        await waitUntilOrgSwitch { agent.thoughts.contains { $0.detail == "still working" } },
        "its events still land in its own thread")
    #expect(!model.thoughts.contains { $0.detail == "still working" }, "umbrella's thread is umbrella's")
    #expect(kill(pid, 0) == 0, "its shell is still running")
    await model.shutdown()
}

/// A waiting approval in one organisation holds nothing in another: the switch goes, and the
/// proposal is still parked, on its own plane, when the operator comes back.
@MainActor
@Test func anOrgSwitchWithAParkedApprovalSwitchesAnyway() async throws {
    let model = await twoOrgWindow()
    await model.parkAProposalForTesting()
    #expect(await waitUntilOrgSwitch { model.pending != nil })
    let parked = try #require(model.pending)

    await model.requestOrganizationSwitch("umbrella")

    #expect(model.organization == "umbrella", "\(model.status)")
    #expect(model.pending == nil, "umbrella's plane shows nothing of initech's")
    #expect(model.waitingPlaces == [initechPlace], "still parked")

    await model.requestOrganizationSwitch("initech")

    #expect(model.place == initechPlace)
    #expect(model.pending?.id == parked.id, "coming back shows it")
    await model.shutdown()
}

/// R2: nothing is discarded any more, so nothing is asked. A dirty buffer is still dirty, with
/// its text, after going away and coming back.
@MainActor
@Test func anOrgSwitchWithUnsavedTabsAsksNothingAndKeepsThem() async throws {
    let context = TwoOrgContext()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("org-switch-editor-\(UUID().uuidString)"),
        sessionId: "org-switch-editor")
    let panes = PaneStore()
    let layout = LayoutStore()
    let fileLists = EditorFileLists(files: FakeFiles())
    await registerLayoutActions(
        into: registry, layout: layout, panes: panes, unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: ContextStore(client: context),
        harnessFactory: { _, _, _ in nil }, resumes: ResumeBroker(), rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in EditorWindowLookup() },
        orgSwitcher: { org in
            await context.use(org)
            return []
        },
        rootWatcher: nil, editorRootWatcher: nil, fileLists: fileLists, gitStatus: nil,
        paletteClients: PaletteClients(files: fileLists), placeClients: nil,
        agentSocketFactory: { _, _ in NoAgentSocket() })
    await registerEditorActions(
        into: registry, panes: panes, layout: layout, files: fileLists, fileLists: fileLists,
        gitStatus: nil, roots: { [weak model] in await model?.gitRootPaths ?? [] })
    await model.refreshContext()
    await model.newScratch()
    let pane = try #require(model.layoutSnapshot.focusedId)
    await model.editorBufferDidChange(pane: pane, tab: 0, text: "select 1", basis: 0)

    await model.requestOrganizationSwitch("umbrella")

    #expect(model.unsavedPrompt == nil, "nothing asked")
    #expect(model.organization == "umbrella", "\(model.status)")
    #expect(!model.layoutSnapshot.panes.contains { $0.id == pane }, "umbrella's canvas is umbrella's")

    await model.requestOrganizationSwitch("initech")

    #expect(model.unsavedPrompt == nil)
    let tab = try #require(model.editor(pane)?.tabs.first)
    #expect(tab.dirty && tab.text == "select 1", "the buffer is intact and still dirty")
}

/// Coming back to an organisation finds its canvas as it was left: the same panes, the same
/// rows, and no subject re-run — only a canvas read off disk is refetched.
@MainActor
@Test func comingBackToAnOrgFindsItsCanvasAsLeft() async throws {
    let layoutDir = testScratchRoot
        .appendingPathComponent("org-switch-return-\(UUID().uuidString)", isDirectory: true)
    let persistence = LayoutPersistence(directory: layoutDir)
    try persistence.save(
        LayoutSnapshot(panes: [
            Pane(id: "db-1", kind: "db", title: "events",
                 frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                 fetch: PaneFetch(query: .sql(database: "events", raw: "select * from events"))),
        ], focusedId: "db-1"),
        for: LayoutScope(organization: "initech", project: "api", environment: "staging"))
    let refetches = RefetchCounter()
    let model = await twoOrgWindow(persistence: persistence)
    await model.registryForTesting.register(Action(
        name: "db_refetch", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            await refetches.bump()
            return .object([:])
        }))
    // The launch read the canvas off disk before the double existed; re-read it now, so the
    // one refetch a disk load owes is counted.
    await model.restorePaneContents()
    #expect(await refetches.count == 1)
    await model.panesForTesting.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.number(7)]], millis: 1, truncated: false, pageable: false, offset: 0,
        sort: [], listsTables: false, editable: nil)
    await model.refreshPanes()
    #expect(model.table("db-1").rows.count == 1)

    await model.requestOrganizationSwitch("umbrella")
    #expect(model.organization == "umbrella", "\(model.status)")
    #expect(!model.layoutSnapshot.panes.contains { $0.id == "db-1" })

    await model.requestOrganizationSwitch("initech")

    #expect(model.layoutSnapshot.panes.map(\.id) == ["db-1"], "the panes as left")
    #expect(model.table("db-1").rows.count == 1, "the rows as left")
    #expect(await refetches.count == 1, "no subject re-run on the way back")
}

private actor RefetchCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Invariant 4: every scope survives a switch, so landing in an org with no project — or in
/// none, a failed restart — must not leave the org left drawn under the new name. Its canvas is
/// put away, still in memory, and coming back finds it.
@MainActor
@Test func anOrgWithNoProjectDrawsNothingOfTheOrgLeft() async throws {
    let model = await twoOrgWindow(failingRestart: "umbrella")
    await model.openPane(kind: "db")
    let pane = try #require(model.layoutSnapshot.panes.first?.id)

    await model.requestOrganizationSwitch("hollow")
    #expect(model.organization == "hollow", "\(model.status)")
    #expect(model.layoutSnapshot.panes.isEmpty, "initech's canvas is not drawn under hollow")

    await model.requestOrganizationSwitch("initech")
    #expect(model.layoutSnapshot.panes.map(\.id) == [pane], "and is there to come back to")

    await model.requestOrganizationSwitch("umbrella")
    #expect(model.organization.isEmpty, "the restart failed: \(model.status)")
    #expect(model.layoutSnapshot.panes.isEmpty, "an org-less window draws no org's canvas")

    await model.requestOrganizationSwitch("initech")
    #expect(model.layoutSnapshot.panes.map(\.id) == [pane])
}

/// Invariant 4: an agent left in initech resolves its account in initech. Its own resume —
/// a fork, a fresh credential read — runs while umbrella is on screen, and the window's
/// `lookup` is umbrella's by then.
@MainActor
@Test func anAgentLeftInAnotherOrgResolvesItsCredentialsInItsOwnOrg() async throws {
    let harnesses = Harnesses()
    let lookups = LookupOrgRecorder()
    let model = await twoOrgWindow(harnesses, lookups: lookups)
    await model.registryForTesting.register(Action(
        name: "session_read", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string(NSTemporaryDirectory()), "provider": .string("main"), "parent": .string(""),
                "truncated": .bool(false), "entries": .array([]),
            ])])
        }))
    #expect(await model.send("a long job"))
    let agent = try #require(model.agents[initechPlace])
    let before = agent.sessionId
    await model.requestOrganizationSwitch("umbrella")
    let mark = lookups.orgs.count

    await model.resume(sessionId: "parent-1", in: initechPlace)

    #expect(agent.sessionId != before, "the fork replaced initech's session: \(model.status)")
    #expect(Array(lookups.orgs.dropFirst(mark)) == ["initech"], "\(lookups.orgs)")
    #expect(harnesses.in(initechPlace).count == 2)
    await model.shutdown()
}

/// Invariant 4, the capacity half: initech's agent hits a rate limit while umbrella is on
/// screen. Its reading is recorded as that agent — so through the client pinned to its own
/// place — never through the window's `wakil-ctx`, which answers for umbrella now.
@MainActor
@Test func anAgentLeftInAnotherOrgRecordsItsCapacityInItsOwnOrg() async throws {
    let harnesses = Harnesses()
    let model = await twoOrgWindow(harnesses)
    let callers = CallerLog()
    await model.registryForTesting.register(Action(
        name: "capacity_record", description: "test double", kind: .control,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            await callers.record(ActionRegistry.dispatchCaller)
            return .object([:])
        }))
    #expect(await model.send("a long job"))
    let agent = try #require(model.agents[initechPlace])
    let harness = try #require(harnesses.in(initechPlace).first)
    await model.requestOrganizationSwitch("umbrella")

    harness.emit(.rateLimit(CapacityWindows(
        fiveHour: CapacityWindow(percentLeft: 40, resetsAt: Date().addingTimeInterval(3_600)), sevenDay: nil)))

    #expect(await waitUntilOrgSwitch { await !callers.entries.isEmpty })
    let caller = try #require(await callers.entries.first ?? nil)
    #expect(caller.place == initechPlace)
    #expect(caller.session == agent.sessionId, "dispatched as the agent, so its pinned client answers")
    await model.shutdown()
}

private actor CallerLog {
    private(set) var entries: [DispatchCaller?] = []
    func record(_ caller: DispatchCaller?) { entries.append(caller) }
}

// MARK: - Fix round 1: what an agent left in another organisation still reaches

/// Set, the harness factory has none to give.
final class HarnessRefusal: @unchecked Sendable {
    private let lock = NSLock()
    private var refusing = false
    var on: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }
}

/// Which client answered each call: the window's, or the pool's for a place.
private final class ClientLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var calls: [String] { lock.withLock { entries } }
    func record(_ entry: String) { lock.withLock { entries.append(entry) } }
}

/// A `wakil-ctx` stand-in that says who it is and answers `read_session` with a minimal thread.
private struct NamedCtx: ToolCaller {
    let name: String
    let log: ClientLog
    func callTool(name tool: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        log.record("\(name):\(tool)")
        return .object(["structuredContent": .object([
            "cwd": .string(NSTemporaryDirectory()), "provider": .string("main"), "parent": .string(""),
            "truncated": .bool(false), "entries": .array([]),
        ])])
    }
}

/// The three session actions `resume` dispatches, each answered by the client the REAL router
/// picks for the dispatch it runs in — the window's `wakil-ctx` or the one pinned to the
/// caller's place — so the test reads routing, not what a stub was handed.
@MainActor
private func registerRoutedSessionActions(on model: WindowModel, log: ClientLog, pool: PlaceClients) async {
    let routed = PlaceRoutedCaller(role: .context, window: NamedCtx(name: "window", log: log), pool: pool)
    for name in ["session_read", "session_get", "session_record_parent"] {
        await model.registryForTesting.register(Action(
            name: name, description: "routed test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { params in try await routed.callTool(name: name, arguments: params, timeout: 5) }))
    }
}

/// Invariant 4: an initech agent's own resume, while umbrella is on screen, reads its parent's
/// transcript, its lineage and records the fork in INITECH's session store — through the client
/// pinned to its place, never the window's `wakil-ctx`, which answers for umbrella now.
@MainActor
@Test func anAgentLeftInAnotherOrgResumesAgainstItsOwnSessionStore() async throws {
    let log = ClientLog()
    let pool = PlaceClients(
        start: { _, place in NamedCtx(name: "pinned:\(place.organization)", log: log) },
        stop: { _ in })
    let harnesses = Harnesses()
    let model = await twoOrgWindow(harnesses, placeClients: pool)
    await registerRoutedSessionActions(on: model, log: log, pool: pool)
    #expect(await model.send("a long job"))
    await model.requestOrganizationSwitch("umbrella")
    let mark = log.calls.count

    await model.resume(sessionId: "parent-1", in: initechPlace)

    let calls = Array(log.calls.dropFirst(mark))
    #expect(calls == ["pinned:initech:session_read", "pinned:initech:session_get",
                      "pinned:initech:session_record_parent"], "\(calls) \(model.status)")
    #expect(harnesses.in(initechPlace).count == 2, "the fork started")
    await model.shutdown()
}

/// Invariant 4: the same resume for an agent with NO session yet (its first turn never started).
/// Its `PlaceAgent.caller` carries no session id, and a caller is pinned to its place only with
/// one, so without the id `resume` mints the reads would answer from umbrella's store.
@MainActor
@Test func anAgentWithNoSessionLeftInAnotherOrgResumesAgainstItsOwnSessionStore() async throws {
    let log = ClientLog()
    let pool = PlaceClients(
        start: { _, place in NamedCtx(name: "pinned:\(place.organization)", log: log) },
        stop: { _ in })
    let refusal = HarnessRefusal()
    refusal.on = true
    let harnesses = Harnesses()
    let model = await twoOrgWindow(harnesses, placeClients: pool, refusesHarnesses: refusal)
    await registerRoutedSessionActions(on: model, log: log, pool: pool)
    #expect(await !model.send("no agent yet"))
    let agent = try #require(model.agents[initechPlace])
    #expect(agent.sessionId == nil, "no session yet")
    await model.requestOrganizationSwitch("umbrella")
    refusal.on = false
    let mark = log.calls.count

    await model.resume(sessionId: "parent-1", in: initechPlace)

    let calls = Array(log.calls.dropFirst(mark))
    #expect(calls == ["pinned:initech:session_read", "pinned:initech:session_get",
                      "pinned:initech:session_record_parent"], "\(calls) \(model.status)")
    #expect(harnesses.in(initechPlace).count == 1, "the fork started")
    await model.shutdown()
}

/// Invariant 4: an initech agent with no harness yet resumes under its own account, not the
/// one the window holds for umbrella now.
@MainActor
@Test func anAgentWithNoHarnessLeftInAnotherOrgResumesUnderItsOwnProvider() async throws {
    let refusal = HarnessRefusal()
    refusal.on = true
    let harnesses = Harnesses()
    let model = await twoOrgWindow(harnesses, refusesHarnesses: refusal)
    await model.registryForTesting.register(Action(
        name: "session_read", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string(NSTemporaryDirectory()), "provider": .string("main"), "parent": .string(""),
                "truncated": .bool(false), "entries": .array([]),
            ])])
        }))
    #expect(await !model.send("no agent yet"))
    #expect(model.agents[initechPlace]?.harness == nil)
    #expect(model.agents[initechPlace]?.providerId == "main")
    await model.requestOrganizationSwitch("umbrella")
    #expect(model.providerId == "umbrella-main")
    refusal.on = false

    await model.resume(sessionId: "parent-1", in: initechPlace)

    #expect(!model.status.contains("belongs to provider"), "\(model.status)")
    #expect(harnesses.in(initechPlace).count == 1, "forked under initech's own account")
    await model.shutdown()
}

/// A command run in an initech shell that finishes after the switch to umbrella is journalled
/// under initech — where the shell is — not the place on screen.
@MainActor
@Test func aShellsRunIsJournalledUnderItsOwnPlaceAfterAnOrgSwitch() async throws {
    let model = await twoOrgWindow()
    let shell = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: shell, text: "sleep 1; printf done\n")
    await model.requestOrganizationSwitch("umbrella")
    #expect(model.place == umbrellaPlace)

    #expect(await waitUntilOrgSwitch(seconds: 15) { await model.journalledRuns().count == 1 })
    let entry = try #require(await model.journalledRuns().first)
    guard case .object(let params) = entry.params else { Issue.record("\(entry.params)"); return }
    #expect(params["org"] == .string("initech"), "\(params)")
    #expect(params["project"] == .string("api"))
    await model.shutdown()
}

/// A lookup that parks every read until released.
private actor ParkedLookup: ProviderCredentialsLookup {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var parked = 0
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        parked += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Invariant 4 for names: a first turn typed in initech parks in its harness start, the operator
/// switches to umbrella, and the vocabulary is umbrella's by the time the turn reads it. The
/// turn goes to initech's agent with no identifier note.
@MainActor
@Test func aTurnTypedBeforeAnOrgSwitchGetsNoneOfTheIncomingOrgsNames() async throws {
    let named = Identifier(text: "transaction_read_only", kind: .column, origin: "umbrella db", source: .schema)
    let source = FixedSource(kind: .schema, name: "fixed") { _ in [named] }
    let store = VocabularyStore(live: [source], cached: [], report: { _, _ in })
    let lookup = ParkedLookup()
    let harnesses = Harnesses()
    let model = await twoOrgWindow(harnesses, lookup: lookup, vocabulary: store)

    let sending = Task { await model.send("what's in transaction read only") }
    #expect(await waitUntilOrgSwitch { await lookup.parked > 0 })
    await model.requestOrganizationSwitch("umbrella")
    #expect(await store.current().count == 1, "the vocabulary now holds umbrella's names")
    await lookup.release()
    _ = await sending.value

    let harness = try #require(harnesses.in(initechPlace).first)
    #expect(harness.log.contains("send:what's in transaction read only"), "\(harness.log)")
    #expect(!(model.agents[initechPlace]?.thoughts.contains { $0.label == "resolved" } ?? true))
    await model.shutdown()
}

/// A provider switch asked in initech whose lookup parks while the operator switches to
/// umbrella: initech's agent takes the new account, but neither umbrella's window provider nor
/// its `active.json` (`ctx_set_provider`, through umbrella's `wakil-ctx` now) is written.
@MainActor
@Test func aProviderSwitchInterruptedByAnOrgSwitchWritesNothingOfTheIncomingOrg() async throws {
    let lookup = ParkedLookup()
    let model = await twoOrgWindow(lookup: lookup)
    let writes = CallerLog()
    await model.registryForTesting.register(Action(
        name: "ctx_set_provider", description: "test double", kind: .control,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            await writes.record(ActionRegistry.dispatchCaller)
            return .object([:])
        }))
    let switching = Task { await model.setProvider("work") }
    #expect(await waitUntilOrgSwitch { await lookup.parked > 0 })
    await model.requestOrganizationSwitch("umbrella")
    await lookup.release()
    await switching.value

    #expect(model.providerId == "umbrella-main", "umbrella's provider is umbrella's")
    #expect(await writes.entries.isEmpty, "no remembered default written into umbrella")
    #expect(model.agents[initechPlace]?.providerId == "work", "initech's agent took the switch")
    await model.shutdown()
}

/// The operator's db read in flight in initech stops at the switch — it went out on the
/// window's client, which is about to answer for umbrella — while an initech agent's read, on
/// its own pinned client, keeps running.
@MainActor
@Test func anOrgSwitchStopsTheOperatorsReadsInTheOrgLeftAndNoAgents() async throws {
    let model = await twoOrgWindow()
    await model.openPane(kind: "db")
    await model.openPane(kind: "db")
    let ids = model.layoutSnapshot.panes.map(\.id)
    try #require(ids.count == 2)
    let panes = model.panesForTesting
    let cancelled = ClientLog()
    let mine = try #require(await panes.beginDBRead(paneId: ids[0], at: Date()))
    await panes.armDBRead(paneId: ids[0], token: mine) { cancelled.record("operator") }
    let agents = try #require(await panes.beginDBRead(paneId: ids[1], at: Date(), byAgent: true))
    await panes.armDBRead(paneId: ids[1], token: agents) { cancelled.record("agent") }

    await model.requestOrganizationSwitch("umbrella")

    #expect(cancelled.calls == ["operator"])
    await model.requestOrganizationSwitch("initech")
    #expect(await panes.dbReadRunning(paneId: ids[1]), "the agent's read is still in flight")
    #expect(await !panes.dbReadRunning(paneId: ids[0]))
}

// MARK: - Final review fix wave

/// Final review C1: an agent started in an organisation with no project is still pinned — by its
/// organisation and session — so once the operator switches to umbrella its calls stay in
/// initech: its `wakil-ctx` call and its capacity reading through the client pinned to its own
/// place, its shell under `WAKIL_ORG=initech`, and its pane in its own canvas, not umbrella's.
@MainActor
@Test func anAgentWithNoProjectStaysInItsOwnOrgAfterASwitch() async throws {
    let log = ClientLog()
    let pool = PlaceClients(
        start: { _, place in NamedCtx(name: "pinned:\(place.organization)", log: log) },
        stop: { _ in })
    let harnesses = Harnesses()
    let model = await twoOrgWindow(harnesses, placeClients: pool, noProjectIn: "initech")
    let bare = Place(organization: "initech", project: "", environment: "")
    #expect(model.place == bare, "\(model.status)")
    let routed = PlaceRoutedCaller(role: .context, window: NamedCtx(name: "window", log: log), pool: pool)
    for name in ["ctx_probe", "capacity_record"] {
        await model.registryForTesting.register(Action(
            name: name, description: "routed test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { params in try await routed.callTool(name: name, arguments: params, timeout: 5) }))
    }
    #expect(await model.send("a job with no project"), "\(model.status)")
    let agent = try #require(model.agents[bare])
    let harness = try #require(harnesses.in(bare).first)
    await model.requestOrganizationSwitch("umbrella")
    #expect(model.place == umbrellaPlace, "\(model.status)")
    let mark = log.calls.count

    _ = try await model.registryForTesting.dispatch(
        name: "ctx_probe", params: .object([:]), origin: .agent, caller: agent.caller, confirmation: nil)
    harness.emit(.rateLimit(CapacityWindows(
        fiveHour: CapacityWindow(percentLeft: 40, resetsAt: Date().addingTimeInterval(3_600)), sevenDay: nil)))
    #expect(await waitUntilOrgSwitch { log.calls.dropFirst(mark).contains("pinned:initech:capacity_record") })
    #expect(log.calls.dropFirst(mark).contains("pinned:initech:ctx_probe"))
    #expect(!log.calls.dropFirst(mark).contains { $0.hasPrefix("window:") }, "\(log.calls.dropFirst(mark))")

    let shell = await model.shellContext(forCaller: agent.caller)
    #expect(shell.org == "initech", "its shell is started with WAKIL_ORG=initech")

    let opened = try await model.registryForTesting.dispatch(
        name: "pane_open", params: .object(["kind": .string("db"), "title": .string("initech's")]),
        origin: .agent, caller: agent.caller, confirmation: nil)
    guard case .object(let fields) = opened, case .string(let id)? = fields["id"] else {
        Issue.record("pane_open answered \(opened)")
        return
    }
    #expect(!model.layoutSnapshot.panes.contains { $0.id == id }, "umbrella's canvas is umbrella's")
    let home = LayoutScope(organization: "initech", project: "", environment: "")
    let homePanes = await model.layoutSnapshotForTesting(in: home).panes
    #expect(homePanes.contains { $0.id == id }, "the pane is in initech's own canvas")
    await model.shutdown()
}

/// Final review minor 5: a provider switch asked in initech resolves the account in initech,
/// even when the operator has switched to umbrella by the time it reads the credentials.
@MainActor
@Test func aProviderSwitchResolvesItsCredentialsInTheOrgItWasAskedIn() async throws {
    let lookups = LookupOrgRecorder()
    let broker = ConfirmationBroker()
    let model = await twoOrgWindow(lookups: lookups, confirmations: broker)
    await broker.holdNextCurrentForTesting()
    let switching = Task { await model.setProvider("work") }
    #expect(await waitUntilOrgSwitch { await broker.holdingCurrentForTesting })
    await model.requestOrganizationSwitch("umbrella")
    #expect(model.organization == "umbrella", "\(model.status)")
    let mark = lookups.orgs.count

    await broker.releaseHeldCurrentForTesting()
    await switching.value

    #expect(Array(lookups.orgs.dropFirst(mark)) == ["initech"], "\(lookups.orgs) \(model.status)")
    #expect(model.agents[initechPlace]?.providerId == "work", "\(model.status)")
    await model.shutdown()
}

/// Final review minor 9: the operator's api send in flight in initech went out on the window's
/// `wakil-http`, which the switch re-points at umbrella, so it stops at the switch, as the
/// operator's db reads do. An initech agent's send, on its own pinned client, keeps running.
@MainActor
@Test func anOrgSwitchStopsTheOperatorsApiSendsInTheOrgLeftAndNoAgents() async throws {
    let model = await twoOrgWindow()
    await model.openPane(kind: "api")
    await model.openPane(kind: "api")
    let ids = model.layoutSnapshot.panes.map(\.id)
    try #require(ids.count == 2)
    let panes = model.panesForTesting
    let cancelled = ClientLog()
    let mine = try #require(await panes.beginApiSend(paneId: ids[0], method: "POST", at: Date()))
    await panes.armApiSend(paneId: ids[0], token: mine) { cancelled.record("operator") }
    let agents = try #require(
        await panes.beginApiSend(paneId: ids[1], method: "POST", at: Date(), byAgent: true))
    await panes.armApiSend(paneId: ids[1], token: agents) { cancelled.record("agent") }

    await model.requestOrganizationSwitch("umbrella")

    #expect(cancelled.calls == ["operator"])
    await model.shutdown()
}

/// Ruling on the fix wave's concern 1: an organisation with no project shows its own canvas,
/// `LayoutScope(org, "", "")` — the one its no-project agent works in — so that agent's pane is
/// on screen while the operator is there.
@MainActor
@Test func aNoProjectAgentsPaneShowsOnScreenInItsOwnOrg() async throws {
    let harnesses = Harnesses()
    let model = await twoOrgWindow(harnesses, noProjectIn: "initech")
    let bare = Place(organization: "initech", project: "", environment: "")
    #expect(model.place == bare, "\(model.status)")
    #expect(await model.send("a job with no project"), "\(model.status)")
    let agent = try #require(model.agents[bare])

    let opened = try await model.registryForTesting.dispatch(
        name: "pane_open", params: .object(["kind": .string("db"), "title": .string("initech's")]),
        origin: .agent, caller: agent.caller, confirmation: nil)
    guard case .object(let fields) = opened, case .string(let id)? = fields["id"] else {
        Issue.record("pane_open answered \(opened)")
        return
    }

    #expect(await waitUntilOrgSwitch { model.layoutSnapshot.panes.contains { $0.id == id } },
            "the agent's pane is drawn on the screen of its own org")
    await model.shutdown()
}

/// Two organisations with no project each have their own canvas: what the operator opened in
/// one is not drawn in the other, and is there on the return.
@MainActor
@Test func twoOrgsWithNoProjectDoNotShareACanvas() async throws {
    let model = await twoOrgWindow(noProjectIn: "initech")
    #expect(model.place == Place(organization: "initech", project: "", environment: ""), "\(model.status)")
    await model.openPane(kind: "db")
    let pane = try #require(model.layoutSnapshot.panes.first?.id, "\(model.status)")

    await model.requestOrganizationSwitch("hollow")
    #expect(model.organization == "hollow", "\(model.status)")
    #expect(model.layoutSnapshot.panes.isEmpty, "hollow does not draw initech's canvas")

    await model.requestOrganizationSwitch("initech")
    #expect(model.layoutSnapshot.panes.map(\.id) == [pane], "initech's canvas is as it was left")
    await model.shutdown()
}

/// Spec §1: arriving in another organisation shows its Landing when no work has begun there —
/// even when the organisation left had a pane open. A dispatch finishing while the switch is
/// between the incoming context and the incoming canvas (here `ctx_editor_settings`, which
/// `refreshContext` makes in exactly that gap) wakes the observation pump, which read the
/// outgoing canvas's panes as work begun in the incoming place and dropped its Landing.
@MainActor
@Test func arrivingFromAnOrgWithAPaneOpenStillShowsTheLanding() async throws {
    let model = await twoOrgWindow()
    let registry = model.registryForTesting
    await registry.register(Action(
        name: "test_noop", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]), handler: { _ in .object([:]) }))
    await registry.register(Action(
        name: "ctx_editor_settings", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            // Another dispatch lands meanwhile, and the pump gets its turn before this returns.
            if ActionRegistry.dispatchCaller?.place.organization == "umbrella" {
                _ = try? await registry.dispatch(
                    name: "test_noop", params: .object([:]), origin: .ui,
                    caller: DispatchCaller(place: umbrellaPlace, session: nil), confirmation: nil)
                try? await Task.sleep(for: .milliseconds(300))
            }
            return .object([:])
        }))
    await model.openPane(kind: "db")
    #expect(model.sessionStarted, "initech has work on its canvas")

    await model.requestOrganizationSwitch("umbrella")

    #expect(model.place == umbrellaPlace, "\(model.status)")
    #expect(model.layoutSnapshot.panes.isEmpty, "umbrella's canvas is empty")
    #expect(!model.sessionStarted, "and so its Landing shows")
    #expect(model.agents[umbrellaPlace]?.sessionStarted != true)
}
