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

/// Pins the defect Task 7 closes and the contract it builds to close it.
///
/// **Both halves of that defect, and they are no longer the same
/// mechanism.** It was that both stores keyed on a project NAME alone
/// while `LayoutPersistence` keyed on `(org, project)`, so disk was safe
/// and memory was not: two orgs each holding a project named `core` —
/// unremarkable — collided, drawing the first org's arrangement and rows
/// under the second org's name, from a different credential boundary's
/// database, with nothing anywhere failing. `clearAllProjects()` was the
/// only thing standing in the way.
///
/// `LayoutScope` carries the organisation, so **the collision can no
/// longer be expressed** — the first expectation below now holds by
/// construction, and `LayoutStoreTests`/`PaneStoreTests` pin it directly.
/// What `clearAllScopes()` still buys is the second: an org switch forgets
/// every arrangement, including the one belonging to the org being left,
/// because an organisation is a credential boundary (Invariant 4). Delete
/// the `clearAllScopes()` line and that expectation fails on its own.
@MainActor
@Test func twoOrgsWithTheSameProjectNameDoNotShareACanvas() async {
    let layout = LayoutStore()
    let inOrgA = LayoutScope(organization: "orga", project: "core")
    let inOrgB = LayoutScope(organization: "orgb", project: "core")
    await layout.switchScope(to: inOrgA)
    await layout.load(
        LayoutSnapshot(panes: [
            Pane(id: "db-1", kind: "db", title: "One", frame: PaneFrame(x: 0, y: 0, width: 100, height: 100))
        ]), for: inOrgA)
    #expect(await layout.snapshot().panes.count == 1)

    // The org changed. "core" in org B is a DIFFERENT project that merely
    // shares a name.
    await layout.clearAllScopes()
    await layout.switchScope(to: inOrgB)

    #expect(
        await layout.snapshot().panes.isEmpty,
        "org A's canvas must not be drawn under org B's identically-named project")

    // And the org being LEFT is forgotten too, which is the part the scope
    // does not do for free: both stores otherwise keep an outgoing scope
    // so that returning to it finds it as it was left.
    await layout.switchScope(to: inOrgA)
    #expect(
        await layout.snapshot().panes.isEmpty,
        "an org switch must forget the outgoing org's arrangement, not park it")
}

/// The `PaneStore` half of the same collision — this store holds what is
/// IN the panes, `LayoutStore` holds where they are, and an org change
/// invalidates both for the same reason.
@MainActor
@Test func twoOrgsWithTheSameProjectNameDoNotShareRows() async {
    let panes = PaneStore(kinds: PaneKinds.standard)
    let inOrgA = LayoutScope(organization: "orga", project: "core")
    let inOrgB = LayoutScope(organization: "orgb", project: "core")
    await panes.switchScope(to: inOrgA)
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 1, truncated: false, pageable: false, offset: 0,
        sort: [], listsTables: false, editable: nil)
    #expect(object(await panes.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(1))

    await panes.clearAllScopes()
    await panes.switchScope(to: inOrgB)

    #expect(
        object(await panes.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(0),
        "org A's rows must not be drawn under org B's identically-named project's pane")

    await panes.switchScope(to: inOrgA)
    #expect(
        object(await panes.readPane(paneId: "db-1", kind: "db"))["rowCount"] == .number(0),
        "an org switch must forget the outgoing org's rows, not park them")
}

/// `invalidateForOrgChange()` is the single named contract that clears
/// everything the outgoing org owned. Every org-derived property added to
/// `WindowModel` must be added here too.
///
/// **Seeds and asserts all four properties fix round 1 added a reset for**
/// (`databaseChoices`, `pending`, `databases`, `layoutSnapshot`), each with a
/// non-default value, so that deleting any one reset line would make this
/// test fail — a `Mirror`-based tripwire (Task 8) can catch an
/// unclassified NEW property, but it cannot catch an EXISTING one quietly
/// dropped from the reset list. Only a behavioural assertion like this one
/// can.
@MainActor
@Test func invalidationClearsEveryOrgDerivedValue() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    model.seedForTesting(
        providerId: "acct", rootPath: "/a/core", thoughts: 3,
        databaseChoices: [
            "db-1": QueryLineDatabaseChoice(database: "orders", subjectDatabase: "orders")
        ],
        pending: PendingMutation(
            action: "test_only_proposal", params: .object([:]), database: "orders",
            statement: "DELETE FROM orders", affectsEveryRow: true, origin: .agent),
        databases: ["orders", "billing"],
        layoutSnapshot: LayoutSnapshot(panes: [
            Pane(id: "db-1", kind: "db", title: "Orders", frame: PaneFrame(x: 0, y: 0, width: 100, height: 100))
        ]))

    // `async`, and both store clears are awaited by the method itself —
    // so by the time this call returns, `layout` and `panes` have
    // genuinely been cleared, not merely asked to clear on some detached
    // task this assertion would otherwise race.
    await model.invalidateForOrgChange()

    #expect(model.providerId.isEmpty)
    #expect(model.thoughts.isEmpty)
    #expect(model.project.isEmpty)
    #expect(model.environment.isEmpty)
    #expect(
        model.databaseChoices.isEmpty,
        "a pane in the new org must not inherit the outgoing org's database choice")
    #expect(
        model.pending == nil,
        "the outgoing org's parked confirmation must not survive the switch")
    #expect(
        model.databases.isEmpty,
        "the outgoing org's database list must not linger as a stale chooser projection")
    #expect(
        model.layoutSnapshot == LayoutSnapshot(),
        "the outgoing org's cached layout projection must not still be drawn after the switch")
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
        origin: .ui, environment: "staging", confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("staging")]),
        origin: .ui, environment: "staging", confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_provider", params: .object(["name": .string("work")]),
        origin: .ui, environment: "staging", confirmation: nil)

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
@Test func aParkedMutationRefusesTheSwitch() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    await model.parkAProposalForTesting()
    await model.setOrganization("beta")
    #expect(model.status.contains("waiting for confirmation"))
    #expect(model.organization == "alpha", "the switch must not have happened")
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

// MARK: - Task 11: the queue — three states, and the send refusal

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

/// A minimal `AgentHarness` double, local to this file because
/// `WindowModelTests.StubHarness` is `private` to that file. Originally
/// built for `aRealResultEventFiresTheQueuedSwitchThroughTheProductionEventPump`
/// (a `start`/`send` that succeed, and an `events()` stream that test feeds
/// by hand); T11-R7b's
/// `aSendThatFailsAfterATurnStartedFiresAQueuedSwitchRatherThanStrandingIt`
/// reuses it with `nextSendError`/`holdNextSend` added, the same gate
/// shape `WindowModelTests.StubHarness.holdNextSend` uses — needed to land
/// a `requestOrganizationSwitch` call deterministically inside `send(_:)`'s
/// `try await harness.send(text)` suspension, rather than by scheduling
/// luck, before that call throws.
private final class FakeHarnessForQueueTests: AgentHarness, @unchecked Sendable {
    private let stream: AsyncStream<HarnessEvent>
    let continuation: AsyncStream<HarnessEvent>.Continuation

    /// If set, the *next* `send` throws this — after the gate below (if
    /// held) releases — instead of succeeding.
    var nextSendError: Error?
    /// When true, the *next* `send` suspends immediately, before either
    /// succeeding or throwing, until `releaseSend()` is called.
    var holdNextSend = false { didSet { if holdNextSend { sendGate.arm() } } }
    private let sendGate = HoldGate()

    init() {
        (stream, continuation) = AsyncStream<HarnessEvent>.makeStream()
    }

    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {}
    func send(_ text: String) async throws {
        if holdNextSend {
            holdNextSend = false
            await sendGate.wait()
        }
        if let nextSendError {
            self.nextSendError = nil
            throw nextSendError
        }
    }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }

    /// Lets a `send` gated by `holdNextSend` proceed, whether it is parked
    /// already or still on its way to the gate: the test releases on
    /// `turnInFlight`, which `WindowModel.send` raises BEFORE this double's
    /// `send` (nonisolated, so on the cooperative pool) reaches the gate.
    /// `HoldGate` latches that early release; a bare continuation lost it
    /// and hung the suite (2026-10-09). A no-op if no hold was asked for.
    func releaseSend() {
        sendGate.release()
    }
}

/// Records how many times `setOrganization` actually ran the org switcher —
/// what `concurrentFiresOfAQueuedSwitchProduceExactlyOneSwitch` counts.
/// `@unchecked Sendable`, the same shape as this file's own
/// `FlakyOrgSwitcherForTesting` above, because `WindowModel`'s
/// `orgSwitcher` parameter is `@Sendable` and a plain mutable `var` cannot
/// be captured by one directly.
private final class SwitchCounterForTesting: @unchecked Sendable {
    private(set) var count = 0
    func attempt(_ org: String) async -> [String] {
        count += 1
        return []
    }
}

@MainActor
@Test func aTurnInFlightQueuesTheSwitchAndItFiresWhenTheTurnEnds() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    await model.beginTurnForTesting()

    await model.requestOrganizationSwitch("beta")
    #expect(model.queuedOrgSwitch == "beta")
    #expect(model.organization == "alpha", "queued means not yet")

    await model.endTurnForTesting()
    #expect(model.organization == "beta")
    #expect(model.queuedOrgSwitch == nil)
}

/// Rewritten from the brief (T11-R3): the brief's own version asserted
/// `model.status.contains("switching to beta")`, but
/// `requestOrganizationSwitch` already writes `"switching to beta when
/// this turn finishes"` into `status` — which contains that substring —
/// so that assertion alone passes even with `send`'s own guard deleted
/// entirely. This version instead asserts the refusal's OWN phrase (only
/// `send`'s guard writes "cancel the switch, or wait for it"), that no new
/// turn actually started, and that the queue survived the refused send.
@MainActor
@Test func sendIsRefusedWhileASwitchIsQueuedSoItCannotBeStarved() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    await model.beginTurnForTesting()
    await model.requestOrganizationSwitch("beta")
    await model.endTurnForTestingWithoutFiring()

    await model.send("another turn")

    #expect(
        model.status.contains("cancel the switch, or wait for it"),
        "\(model.status)")
    #expect(model.turnInFlight == false, "the refusal must not have started a new turn")
    #expect(model.queuedOrgSwitch == "beta", "the queue must survive the refused send")
}

@MainActor
@Test func aParkedMutationHoldsTheQueuedSwitchRatherThanCancellingIt() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    await model.beginTurnForTesting()
    await model.requestOrganizationSwitch("beta")
    await model.parkAProposalForTesting()
    await model.endTurnForTesting()

    #expect(model.queuedOrgSwitch == "beta", "held, not cancelled")
    #expect(model.organization == "alpha")

    await model.cancelPending()
    #expect(model.organization == "beta", "a cancel clears the park and the switch fires")
}

/// T11-R4: none of the three tests above proves the PRODUCTION call site —
/// `startEventPump`'s event pump — was ever wired to
/// `fireQueuedSwitchIfReady()` at all; all three drive the queue through
/// `beginTurnForTesting`/`endTurnForTesting`, which a version that never
/// touched `append(_:)`'s call site would still pass. This test drives a
/// real `send()` (a real turn, through a real fake `AgentHarness`) and
/// delivers a real `.result` `HarnessEvent` through that harness's own
/// `events()` stream — the same `continuation.yield(.result(...))` idiom
/// `WindowModelTests.swift`'s
/// `staleEventsFromTheSupersededHarnessNeverReachTheClearedThreadAfterASwitch`
/// uses to end a turn for real — rather than the test-only helpers.
@MainActor
@Test func aRealResultEventFiresTheQueuedSwitchThroughTheProductionEventPump() async {
    let harness = FakeHarnessForQueueTests()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        harnessFactory: { _, _ in harness })

    await model.send("go")
    #expect(model.turnInFlight, "send must have actually started a turn")

    await model.requestOrganizationSwitch("beta")
    #expect(model.queuedOrgSwitch == "beta")
    #expect(model.organization == "alpha", "queued means not yet")

    harness.continuation.yield(.result(isError: false, text: nil))

    #expect(await waitUntilOrgSwitch { model.organization == "beta" })
    #expect(model.queuedOrgSwitch == nil)
}

/// T11-R2: `fireQueuedSwitchIfReady()`'s own `await
/// confirmations.current()` is a suspension point between reading
/// `queuedOrgSwitch` and clearing it, so two calls landing back-to-back —
/// here, two concurrent invocations via `async let` — can both observe the
/// queue non-nil, both pass the guard, and (without the
/// `firingQueuedSwitch` reentrancy flag) both call `setOrganization`,
/// firing one queued request twice. Counting `orgSwitcher` invocations
/// through `SwitchCounterForTesting` is what makes "exactly one switch"
/// checkable — `model.organization == "beta"` alone would read identically
/// whether the switcher ran once or twice.
@MainActor
@Test func concurrentFiresOfAQueuedSwitchProduceExactlyOneSwitch() async {
    let switcher = SwitchCounterForTesting()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        orgSwitcher: { org in await switcher.attempt(org) })

    await model.beginTurnForTesting()
    await model.requestOrganizationSwitch("beta")
    await model.endTurnForTestingWithoutFiring()

    async let first: Void = model.fireQueuedSwitchIfReady()
    async let second: Void = model.fireQueuedSwitchIfReady()
    _ = await (first, second)

    #expect(model.organization == "beta")
    #expect(model.queuedOrgSwitch == nil)
    #expect(
        switcher.count == 1,
        "two concurrent fires of one queued switch must produce exactly one setOrganization call, got \(switcher.count)")
}

/// T11-R7b (a correction of T11-R7): `send(_:)` sets `turnInFlight = true`
/// SYNCHRONOUSLY, immediately before the genuine suspension inside `try
/// await harness.send(text)` — so a `requestOrganizationSwitch` call
/// landing in exactly that window sees a turn genuinely in flight and
/// queues, precisely as it is meant to. If `harness.send` then throws,
/// `send`'s own `catch` is the ONLY place `turnInFlight` ever becomes
/// false for that attempt — no `.result` event is coming, because the
/// turn never actually started — so without a fire call there, the queued
/// switch would never drain: no turn end arrives to trigger it, and the
/// top-of-`send` refusal turns the operator away from starting a new turn
/// to shake it loose. `FakeHarnessForQueueTests`'s `holdNextSend` gate
/// makes the interleaving deterministic rather than a matter of
/// scheduling luck: `send(_:)` is suspended (with `turnInFlight` already
/// `true`) exactly where it would be mid-flight in production, the switch
/// is requested there, and only then is the gate released to let the
/// fake's `send` throw.
@MainActor
@Test func aSendThatFailsAfterATurnStartedFiresAQueuedSwitchRatherThanStrandingIt() async {
    struct SendFailureForTesting: Error {}
    let harness = FakeHarnessForQueueTests()
    harness.holdNextSend = true
    harness.nextSendError = SendFailureForTesting()
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        organization: "alpha",
        harnessFactory: { _, _ in harness })

    let sendTask = Task { await model.send("go") }
    // Polled, not asserted immediately after `Task { ... }` returns:
    // `send` is a separate, unstructured task from this test's own, so
    // this waits for it to have actually reached (and set)
    // `turnInFlight` before this test acts on that being true — the same
    // reason `WindowModelTests.swift`'s own `waitUntil` exists.
    #expect(await waitUntilOrgSwitch { model.turnInFlight })

    await model.requestOrganizationSwitch("beta")
    #expect(model.queuedOrgSwitch == "beta")

    harness.releaseSend()
    await sendTask.value

    #expect(
        model.organization == "beta",
        "the queued switch must not be stranded by the send that failed to start its turn")
    #expect(model.queuedOrgSwitch == nil)
}

// MARK: - Task 11 fix round 2

/// A scratch journal directory for the two fix-round-2 tests below, which
/// build a `WindowModel` directly (not through `forTesting`) because they
/// need a custom `session_read` action registered — `forTesting`'s own
/// registry only ever seeds `session_list`. The same shape as
/// `WindowModelTests.swift`'s own (`private` to that file, so not
/// reusable here) `windowScratchDirectory()`.
private func orgSwitchFixRound2ScratchDirectory() throws -> URL {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Registers a `session_read` action returning a fixed, minimal thread —
/// just enough for `resume(sessionId:)`'s own guards to pass (`provider`
/// matching the window's `providerId`, some `cwd`) — the same shape
/// `WindowModelTests.swift`'s (`private`) `registerFakeReadSession` uses,
/// reproduced here because that copy is not reusable from this file.
private func registerFakeReadSessionForOrgSwitch(provider: String, cwd: String) -> Action {
    Action(
        name: "session_read", description: "Task 11 fix round 2 test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string(cwd),
                "provider": .string(provider),
                "parent": .string(""),
                "truncated": .bool(false),
                "entries": .array([]),
            ])])
        })
}

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

/// Fix round 2, Finding 1. `resume(sessionId:)` has two callers with
/// different reentrancy properties: nested inside `setOrganization` via
/// `autoResumeAfterSwitch()` (where firing from `resume`'s own body would
/// be reentrant — T11-R1's original ruling was right about THAT caller),
/// and `resumePump` — draining the agent's own `session_resume` tool call,
/// or `--dispatch` — which is never nested inside a switch and IS a
/// genuine turn end. Before this fix, `resume`'s teardown setting
/// `turnInFlight = false` fired nothing for either caller, so a switch
/// queued against a turn the agent then resumed away from would never
/// drain: no `.result` is coming for a turn that got abandoned this way,
/// and the top-of-`send` refusal turns the operator away from starting a
/// new turn to shake it loose.
///
/// Delivers the resume request through `resumes.request(_:)` — the real
/// broker, the same one `resumePump` (subscribed once, in `init`) drains —
/// rather than calling `model.resume(sessionId:)` directly, because the
/// fix lives at the `resumePump` call site specifically, not inside
/// `resume(sessionId:)` itself; calling `resume` directly would prove
/// nothing about whether that call site was ever wired up.
@MainActor
@Test func aResumeRequestFromTheAgentFiresAQueuedSwitchThroughTheResumePump() async throws {
    let journalDirectory = try orgSwitchFixRound2ScratchDirectory()
    let registry = ActionRegistry(
        journalDirectory: journalDirectory, sessionId: "org-switch-fix-round-2-resume-pump",
        initialActions: [
            registerFakeReadSessionForOrgSwitch(provider: "test-provider", cwd: "/tmp/org-switch-resume")
        ])
    let harness = FakeHarnessForQueueTests()
    let resumes = ResumeBroker()
    let model = WindowModel(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), context: nil,
        harnessFactory: { _ in harness }, resumes: resumes,
        rootPath: "/tmp/org-switch-resume", providerId: "test-provider",
        lookup: AlwaysSucceedsCredentialsLookupForOrgSwitch(), environment: "staging")
    model.setOrganizationForTesting("alpha")

    await model.beginTurnForTesting()
    await model.requestOrganizationSwitch("beta")
    #expect(model.queuedOrgSwitch == "beta")

    // The agent's own `session_resume` — indistinguishable, from this
    // broker's perspective, from `--dispatch` reaching the same path.
    await resumes.request(ResumeRequest(sessionId: "parent-1"))

    #expect(await waitUntilOrgSwitch { model.organization == "beta" })
    #expect(model.queuedOrgSwitch == nil)
}

/// Fix round 2, Finding 2 (credential boundary). `fireQueuedSwitchIfReady()`
/// captures `org` before its only suspension point (`await
/// confirmations.current()`). `WindowModel` is `@MainActor`, so other
/// MainActor work — including the plain synchronous `cancelQueuedSwitch()`
/// — can run during that hop. `firingQueuedSwitch` guards against a
/// SECOND CALL TO THIS SAME METHOD racing it, but does nothing about an
/// unrelated method mutating `queuedOrgSwitch` out from under it: without
/// the `queuedOrgSwitch == org` re-check, this method would resume holding
/// the stale captured `org`, clear nothing, and switch anyway — silently
/// overriding the operator's own cancel and moving credentials to an org
/// they explicitly declined.
///
/// Landed deterministically via `ConfirmationBroker`'s own
/// `armHoldNextCurrentForTesting()`/`releaseHeldCurrentForTesting()` gate
/// (the same one-shot `CheckedContinuation` shape
/// `WindowModelTests.StubHarness.holdNextSend` uses), NOT by racing two
/// `async let`s or a bare `Task.yield()` against each other — both were
/// tried first here and measured unreliable: in isolation they landed the
/// race often enough to look convincing (a `Task.yield()`-based version
/// passed 10/10 alone), but under the full suite's load — with hundreds of
/// other `@MainActor` tasks sharing the same executor — the assumption
/// that `fire`'s continuation is the very next thing scheduled stopped
/// holding, and the same version failed to reproduce the race when run as
/// part of `make app-test`. The gate removes scheduling from the picture
/// entirely: `fireQueuedSwitchIfReady()`'s only suspension point,
/// `await confirmations.current()`, is held open by the broker itself
/// until this test explicitly releases it, so `cancelQueuedSwitch()` is
/// guaranteed to run while `fire` is suspended there — not merely likely
/// to.
@MainActor
@Test func aCancelLandingDuringTheConfirmationsCheckIsNotOverriddenByAStaleCapturedOrg() async {
    let confirmations = ConfirmationBroker()
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha", confirmations: confirmations)
    await model.beginTurnForTesting()
    await model.requestOrganizationSwitch("beta")
    await model.endTurnForTestingWithoutFiring()
    #expect(model.queuedOrgSwitch == "beta")

    await confirmations.armHoldNextCurrentForTesting()
    let fire = Task { await model.fireQueuedSwitchIfReady() }
    // Polled, not asserted immediately: `fire` is a separate task from
    // this test's own, so this waits for it to have actually reached (and
    // parked inside) the armed hold before this test acts on that — the
    // same reason `waitUntilOrgSwitch`/`waitUntil` exist elsewhere in this
    // file and `WindowModelTests.swift`.
    #expect(await waitUntilOrgSwitch { await confirmations.isHoldingCurrentForTesting() })

    model.cancelQueuedSwitch()
    await confirmations.releaseHeldCurrentForTesting()
    await fire.value

    #expect(
        model.organization == "alpha",
        "a cancel landing mid-fire must not be silently overridden by a switch that had already captured the stale org")
    #expect(model.queuedOrgSwitch == nil)
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
/// standing rule (see `aCancelLandingDuringTheConfirmationsCheckIsNotOverriddenByAStaleCapturedOrg`'s
/// doc comment for why that rule exists).
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
            origin: .ui, environment: "staging", confirmation: nil)
        _ = try await setupRegistry.dispatch(
            name: "ctx_set_environment", params: .object(["name": .string("staging")]),
            origin: .ui, environment: "staging", confirmation: nil)
        _ = try await setupRegistry.dispatch(
            name: "ctx_set_provider", params: .object(["name": .string("work")]),
            origin: .ui, environment: "staging", confirmation: nil)
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
        harnessFactory: { _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForOrgSwitch() },
        orgSwitcher: { org in await switcher.attempt(org) },
        rootWatcher: nil, editorRootWatcher: nil, fileLists: nil, gitStatus: nil, paletteClients: PaletteClients())
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
        origin: .ui, environment: "staging", confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("staging")]),
        origin: .ui, environment: "staging", confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_provider", params: .object(["name": .string("work")]),
        origin: .ui, environment: "staging", confirmation: nil)

    let seen = LookupOrgRecorder()
    let model = WindowModel(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        context: ContextStore(client: client),
        harnessFactory: { _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { org in
            seen.record(org)
            return AlwaysSucceedsCredentialsLookupForOrgSwitch()
        },
        rootWatcher: nil, editorRootWatcher: nil, fileLists: nil, gitStatus: nil, paletteClients: PaletteClients())
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

// MARK: - Final fix pass, Important 2: spec §5.1's store clears

/// `invalidateForOrgChange()`'s last two lines — `await
/// layout.clearAllScopes()` and `await panes.clearAllScopes()`, spec
/// §5.1 — were **dead to the whole suite**: replacing both with
/// `_ = layout; _ = panes` left 782 tests passing, 0 failures. This is the
/// test that makes them load-bearing.
///
/// **Why the two tests at the top of this file do not cover them.**
/// `twoOrgsWithTheSameProjectNameDoNotShareACanvas` and
/// `…DoNotShareRows` build a bare `LayoutStore`/`PaneStore`, call
/// `clearAllScopes()` *themselves*, and assert the store came back
/// empty. They prove the two store methods work. They say nothing at all
/// about whether `invalidateForOrgChange()` ever calls them — and
/// `invalidationClearsEveryOrgDerivedValue` above asserts nine of the
/// model's own properties and never touches either store.
///
/// **Seeded through the model, not around it.** The stores here are the
/// model's own; the project is switched by `refreshContext()` (which is
/// what calls `activateLayout()`, the only thing that moves either store
/// to a project), the pane is opened by `pane_open` through
/// `openPane(kind:)` — Invariant 2's one way to open a pane — and the
/// assertions read the projections the window actually draws from, after
/// the `refreshLayout()`/`refreshPanes()` that a landing in the new org
/// performs. So what is pinned is the model's teardown, not the stores'
/// own API.
///
/// The defect underneath, restated: both stores key `byProject` by project
/// NAME ALONE and deliberately keep a departed project's contents in
/// memory, while `LayoutPersistence` keys by `(org, project)`. Two orgs
/// that each hold a project called `core` — unremarkable — therefore
/// collide in memory and nowhere on disk: org B's `core` draws org A's
/// panes and org A's rows, under org B's credential boundary, with nothing
/// anywhere failing.
///
/// Rows go in through `PaneStore.setRows` directly, the way
/// `LayoutActionsTests` and `WindowModelTests` seed pane contents: the
/// action that writes them is `db_run_query`, which needs a live
/// `wakil-db` and a real database, and none of that would make the
/// clearing any more or less true.
@MainActor
@Test func invalidationClearsBothStoresAndNotJustTheModelsOwnProperties() async throws {
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
        origin: .ui, environment: "staging", confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_environment", params: .object(["name": .string("staging")]),
        origin: .ui, environment: "staging", confirmation: nil)

    let model = WindowModel(
        registry: registry, panes: panes, layout: layout,
        context: ContextStore(client: client),
        harnessFactory: { _, _ in nil }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForOrgSwitch() },
        rootWatcher: nil, editorRootWatcher: nil, fileLists: nil, gitStatus: nil, paletteClients: PaletteClients())

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
    // Re-read exactly the way the landing in the new org re-reads them.
    await model.refreshLayout()
    await model.refreshPanes()
    await client.stop()

    #expect(
        model.layoutSnapshot.panes.isEmpty,
        """
        invalidateForOrgChange() must clear LayoutStore itself — `byProject` is keyed by \
        project name alone, so the outgoing org's arrangement would otherwise be drawn under \
        an identically-named project in the org just switched to
        """)
    #expect(
        model.table(paneId).rows.isEmpty,
        """
        invalidateForOrgChange() must clear PaneStore itself — the outgoing org's ROWS, read \
        under the outgoing org's credentials, would otherwise be drawn in the new org's pane \
        of the same id
        """)
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
        for: LayoutScope(organization: "beta", project: "widgets"))

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
        origin: .ui, environment: "staging", confirmation: nil)

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
        origin: .ui, environment: "staging", confirmation: nil)

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

/// The org switch's third kill point: `invalidateForOrgChange()` awaits
/// `terminals.shutdownAll()` as well as clearing `layout` and `panes`
/// (Task 14). The BEHAVIOURAL half of that claim — the tripwire in
/// `InvalidationContractTests` can only prove `terminals` was classified,
/// not that the shell dies, and a dropped reference leaks a live process
/// holding org A's working directory open.
@MainActor
@Test func theOrgSwitchKillsEveryShellItLeavesBehind() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    let pid = await model.terminals.pidForTesting(paneId: pane)
    #expect(pid != nil)

    await model.invalidateForOrgChange()

    #expect(kill(pid!, 0) == -1)
    #expect(!(await model.terminals.isRunning(paneId: pane)))
    await model.shutdown()
}

/// **The run pump outlives the switch** — final review's Critical 1, and
/// the assertion whose absence let that ship.
///
/// `invalidateForOrgChange()` reuses `TerminalStore.shutdownAll`, which was
/// written for app quit and ended the run stream on its way out; the window
/// subscribes to `completedRuns()` exactly ONCE, in `init`. So after one
/// org switch, `terminalRunPump`'s `for await` had ended, the continuation
/// was `nil`, and every command run in every pane from then on went
/// unjournalled — silently, with no failure anywhere, against Invariant 2's
/// one chokepoint. `switchOrg` keeps the same store instance, so this was
/// the shipped path.
///
/// **Two entries is the whole claim.** The sibling tests above prove the
/// shells die; this one proves the journalling survives them. Written
/// against the real pump and two real shells, because a test that asserted
/// on `runContinuation != nil` would pass against a stream nobody is
/// draining any more.
@MainActor
@Test func theRunPumpKeepsJournallingAfterAnOrgSwitch() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let before = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: before, text: "printf before\n")
    #expect(
        await waitUntilOrgSwitch(seconds: 10) { await model.journalledRuns().count == 1 },
        "the first run must journal even before any switch")

    await model.invalidateForOrgChange()

    let after = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: after, text: "printf after\n")
    #expect(
        await waitUntilOrgSwitch(seconds: 10) { await model.journalledRuns().count == 2 },
        "a run in the new org went unjournalled — the pump died with the outgoing org's shells")

    let commands = await model.journalledRuns().compactMap { entry -> String? in
        guard case .object(let params) = entry.params,
              case .string(let command)? = params["command"] else { return nil }
        return command
    }
    #expect(commands == ["printf before", "printf after"])
    await model.shutdown()
}

/// **An organisation switch must not be blocked by a running shell.** A
/// forgotten `tail -f` dies silently, with no warning and no prompt.
/// Making a shell a parked mutation would let it block a switch
/// indefinitely, which is the worse failure — Guard 2 refuses to start
/// while a MUTATION is parked; a shell is not one.
@MainActor
@Test func anOrgSwitchIsNotBlockedByAShellThatIsStillRunning() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: pane, text: "yes wakil\n")

    await model.invalidateForOrgChange()

    // **The shape, not the clock** (#307). This asserted the switch finished
    // within three seconds, which measured suite load rather than the switch:
    // observed red at 6.2 s and 11.0 s under `make app-test`, and green in
    // 0.066 s alone on the same commit.
    //
    // The shell above runs `yes wakil` and never exits, so a switch that
    // waited for it would never return and this test would hang rather than
    // fail. Reaching this line is the claim the test's own name makes.
    await model.shutdown()
}
