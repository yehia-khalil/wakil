import Testing
import Foundation
@testable import WakilKit

/// Task 8 of Phase 2b-vi: `WindowModel.setProvider(_:)` and every reason it
/// refuses, plus the one test that matters most to the design — the agent
/// cannot dispatch `session_set_provider` at all. Task 9 covers the swap
/// itself; every scenario here stops at a refusal, or (for the credentials
/// path) at `_ = credentials  // Task 9 performs the swap.`
///
/// SAFETY. Nothing here runs the `claude` CLI: `HangingHarness` spawns
/// nothing, and every registry is built in-process against a scratch
/// journal directory, never `~/.wakil`.

// MARK: - Test doubles

/// Always succeeds unless told to fail one specific way, so one type
/// covers every scenario this file needs: default (both `nil`) resolves
/// `stubCredentials`; `refusal:` set mirrors
/// `ProviderCredentialsLookupError.refused`, whose message
/// `setProvider` must surface VERBATIM (see
/// `surfacesTheLookupRefusalVerbatim` — it names the exact `wakil secrets
/// set` to run, and wrapping it would bury that); `genericError:` set
/// stands in for anything else a real lookup might throw, which
/// `setProvider`'s second `catch` handles without inspecting it.
private struct FakeLookup: ProviderCredentialsLookup {
    var refusal: String?
    var genericError: Error?
    var stubCredentials = ProviderCredentials(
        claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")

    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        if let refusal { throw ProviderCredentialsLookupError.refused(refusal) }
        if let genericError { throw genericError }
        return stubCredentials
    }
}

/// Anything a lookup might throw that is not `ProviderCredentialsLookupError
/// .refused` — a Keychain read failing outright, say. `setProvider`'s
/// generic `catch` must still land this in `status` rather than crashing or
/// silently doing nothing.
private struct StubLookupError: Error, CustomStringConvertible, Equatable {
    var description: String { "stub lookup failure" }
}

/// A harness whose `send` never returns, so `turnInFlight` stays `true` for
/// as long as a test needs it. `turnInFlight` has no external setter
/// (`private(set)` on `WindowModel`) precisely so nothing outside it can
/// claim a turn is in flight without one genuinely being stuck mid-flight —
/// this is what makes that claim true rather than asserted.
private final class HangingHarness: AgentHarness, @unchecked Sendable {
    private let stream: AsyncStream<HarnessEvent>
    private let continuation: AsyncStream<HarnessEvent>.Continuation

    init() { (stream, continuation) = AsyncStream<HarnessEvent>.makeStream() }

    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {}
    func send(_ text: String) async throws {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}

/// Thrown by `SwitchableHarness.start` when `nextStartError` is armed —
/// stands in for whatever a real `ClaudeCodeCLIHarness.start` might throw
/// (a bad binary path, a spawn failure), which Task 9's swap must treat
/// identically: `setProvider`'s only reaction to any `Error` here is to
/// land its description in `status` and touch nothing else. See
/// `WindowModelTests`' `StubHarness.nextStartError`, built for the
/// identical resume-side property.
private struct StubStartError: Error, CustomStringConvertible, Equatable {
    var description: String { "stub start failure" }
}

/// A harness that behaves, unlike `HangingHarness` above: `start` succeeds
/// unless `nextStartError` is armed (mirroring `WindowModelTests`'
/// `StubHarness.nextStartError`), and `send` completes its turn
/// immediately by yielding one `.result` event — enough for `append(_:)`
/// to both clear `turnInFlight` and add exactly one row to `thoughts`
/// (`thoughtRow(id:for:)` maps `.result` to a `"turn"` row), which is what
/// lets `aFailingStartLeavesTheExistingSessionUntouched` start from a
/// session that is genuinely running rather than one merely constructed.
private final class SwitchableHarness: AgentHarness, @unchecked Sendable {
    private let stream: AsyncStream<HarnessEvent>
    private let continuation: AsyncStream<HarnessEvent>.Continuation
    var nextStartError: Error?

    init() { (stream, continuation) = AsyncStream<HarnessEvent>.makeStream() }

    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {
        if let nextStartError {
            self.nextStartError = nil
            throw nextStartError
        }
    }
    func send(_ text: String) async throws {
        continuation.yield(.result(isError: false, text: nil))
    }
    func events() -> AsyncStream<HarnessEvent> { stream }
    func interrupt() async {}
    func stop() async { continuation.finish() }
}

private func providerSwitchScratchDirectory() -> URL {
    testScratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

/// Builds a `WindowModel` with no filesystem underneath it — the same
/// no-filesystem construction `WindowModelTests` uses throughout — for a
/// test that only cares about `setProvider`'s refusals.
///
/// `turnInFlight: true` does not poke a flag by hand (there is nothing to
/// poke — see `HangingHarness`'s doc comment); it starts a real `send` on a
/// `HangingHarness` and waits for `turnInFlight` to actually go `true`,
/// which is what makes `refusesASwitchWhileATurnIsInFlight` a test of the
/// real guard rather than of a fixture.
///
/// `factoryFails: true` (Task 9) switches the harness supply entirely, to
/// `SwitchableHarness`: the initial provider (`providerId`) still gets a
/// harness that starts and completes turns normally — this is what
/// establishes the "existing session" `aFailingStartLeavesTheExisting
/// SessionUntouched` must find genuinely running before it ever calls
/// `setProvider` — but every OTHER provider id resolves to a harness whose
/// `start` is armed to throw, standing in for the switch target's harness
/// failing to come up. The setup below sends one real turn and waits for
/// it to land before returning, exactly as the `turnInFlight` branch waits
/// for its own precondition to become true, so a test built on this never
/// depends on a race against the pump to have already happened.
@MainActor
private func makeModel(
    providerId: String,
    turnInFlight: Bool = false,
    factoryFails: Bool = false,
    lookup: ProviderCredentialsLookup = FakeLookup(),
    // Lets a test register a stand-in `ctx_set_provider` into the exact
    // registry this model dispatches through — a spy that records calls,
    // or one that throws — without every other call site in this file
    // having to know or care that the persistence step (Step 5) exists at
    // all. `@Sendable` because `ActionRegistry` is an actor and the
    // closure crosses into its isolation via `register`.
    configureRegistry: (@Sendable (ActionRegistry) async -> Void)? = nil
) async -> WindowModel {
    let registry = ActionRegistry(journalDirectory: providerSwitchScratchDirectory(), sessionId: "provider-switch")
    if let configureRegistry { await configureRegistry(registry) }
    let harness = HangingHarness()
    let workingHarness = SwitchableHarness()
    let failingHarness = SwitchableHarness()
    failingHarness.nextStartError = StubStartError()

    let model = WindowModel(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), context: nil,
        harnessFactory: { selection in
            guard factoryFails else { return harness }
            return selection.id == providerId ? workingHarness : failingHarness
        },
        resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: providerId, lookup: lookup)

    if turnInFlight {
        Task { await model.send("this turn never finishes") }
        for _ in 0..<400 {
            if model.turnInFlight { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    if factoryFails {
        await model.send("hello")
        for _ in 0..<400 {
            if !model.turnInFlight && !model.thoughts.isEmpty { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    return model
}

/// The registry the agent's `--allowedTools` argv is actually derived
/// from in production: `registerStandardActions`, exactly as
/// `WindowSession.start` builds it — which, as of this file's fix round,
/// DOES include `session_set_provider`. Registering it here rather than
/// from `WindowModel` (Fix round 1's revert) is what makes it
/// dispatchable through `--dispatch`'s own separate wiring, the same way
/// `session_resume` and `session_record_parent` are — see
/// `registerStandardActions`'s own comment on `session_set_provider` for
/// why that no longer costs the agent-unreachability property.
private func registryForTesting() async -> ActionRegistry {
    let registry = ActionRegistry(journalDirectory: providerSwitchScratchDirectory(), sessionId: "allow-list")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    return registry
}

// MARK: - Refusals

@Test func refusesASwitchToTheProviderAlreadyRunning() async {
    let model = await makeModel(providerId: "main")
    await model.setProvider("main")
    #expect(await model.status.contains("already running"))
}

@Test func refusesASwitchWhileATurnIsInFlight() async {
    let model = await makeModel(providerId: "main", turnInFlight: true)
    await model.setProvider("work")
    #expect(await model.status.contains("a turn is in flight"))
}

@Test func refusesASwitchWithAProposalParked() async {
    let model = await makeModel(providerId: "main")
    await model.parkAProposalForTesting()
    await model.setProvider("work")
    #expect(await model.status.contains("waiting for confirmation"))
}

/// Background agents 3 of 4: only the switching place's own waiting proposal holds its
/// provider switch — the session it belongs to is the one replaced. Another place's waits for
/// its own agent, which keeps its provider, and is still parked afterwards.
@Test func aProposalParkedInAnotherPlaceDoesNotRefuseTheSwitch() async {
    let model = await makeModel(providerId: "main")
    await model.parkAProposalForTesting()
    let parkedIn = await model.place
    await model.seedForTesting(providerId: "main", rootPath: "/tmp", thoughts: 0,
                               project: "billing", environment: "staging")
    #expect(await model.place != parkedIn)

    await model.setProvider("work")

    let status = await model.status
    #expect(await model.providerId == "work", "\(status)")
    #expect(await model.waitingPlaces == [parkedIn], "the other place's proposal still waits")
}

@Test func surfacesTheLookupRefusalVerbatim() async {
    let model = await makeModel(providerId: "main", lookup: FakeLookup(
        refusal: "no credential stored for ref provider:work in org acme — store it with: wakil secrets set provider:work"))
    await model.setProvider("work")
    #expect(await model.status.contains("wakil secrets set provider:work"))
}

@Test func refusesWhenTheLookupThrowsAnythingElse() async {
    let model = await makeModel(providerId: "main", lookup: FakeLookup(genericError: StubLookupError()))
    await model.setProvider("work")
    #expect(await model.status.contains("stub lookup failure"))
}

// MARK: - The ⌘P route (Task 12)
//
// Every scenario above drives `setProvider` directly, which is exactly
// what Task 12 found nothing in the window actually did: the old `runPaletteItem`
// dispatched `.action` items with an empty params object, so choosing
// `session_set_provider` from a palette failed on a missing "provider"
// param, and no ⌘P row or ⌘K item ever named one to switch to at all.
// This is the regression test for the fix — `.provider`, a new
// `PaletteItem.Kind`, reaching `setProvider` — now ⌘P's provider row, `.setProvider`,
// through `performPalette`.

/// Proves the route reaches `setProvider` itself, and specifically
/// `setProvider` rather than a dispatch of `session_set_provider` through
/// the registry. The two are NOT interchangeable: dispatching
/// `session_set_provider` only parks a `ProviderSwitchRequest` (see that
/// action's own registration comment) for `providerSwitchPump` to drain
/// later, so it would report the park's own success immediately and
/// surface any of `setProvider`'s five refusals — if at all — only after
/// the pump next woke up. The "already running" message below is one of
/// those five refusals (`refusesASwitchToTheProviderAlreadyRunning`
/// above pins the identical guard called directly), so seeing it land in
/// `status` synchronously, right after `performPalette` returns, is only
/// possible if the palette item called `setProvider` itself.
@Test func aProviderPaletteItemRoutesToSetProviderWithTheRightId() async {
    let model = await makeModel(providerId: "main")
    _ = await model.performPalette(.run(.setProvider("main")))

    let status = await model.status
    #expect(status.contains("already running"), "\(status)")
    #expect(status.contains("main"), "\(status)")
}

// MARK: - The agent's reach
//
// Fix round 1 (review of the first version of this file) found that the
// original `theAgentCannotSwitchItsOwnAccount` — a registry-snapshot
// check — asserted a REGISTRATION-ORDER accident, not reachability, and
// kept passing while an agent could in fact still call
// `session_set_provider`: an unlisted MCP tool is routed to
// `approve_tool_use` rather than auto-denied
// (`permission-prompt-probe.md` §1), and `permissionDecision`'s
// `knownActions` check — derived from the LIVE registry
// (`MCPServer.swift`) — already allowed it by the time any real call
// could arrive. The tests below assert the DECISION instead, which is
// where the actual refusal now lives (`operatorOnlyActions` in
// `PermissionPrompt.swift`).

/// The test that carries this task's whole point: an agent that could
/// switch its own account could move itself to a provider whose sessions
/// the operator is not watching. Must fail if `operatorOnlyActions` loses
/// its `session_set_provider` entry.
@Test func theAgentCannotSwitchItsOwnAccount() {
    let decision = permissionDecision(
        toolName: "mcp__\(wakilShimServerName)__session_set_provider",
        knownActions: ["session_set_provider"])
    guard case .deny = decision else {
        Issue.record("expected the agent to be denied session_set_provider, got \(decision)")
        return
    }
}

/// The companion the ruling asked for: the denylist must not widen by
/// accident to swallow an ordinary `.control` action. `pane_move` is
/// `.control` for the same "changes nothing outside Wakil" reason
/// `session_set_provider` is, and unlike it, must stay reachable.
@Test func anOrdinaryControlActionIsStillAllowed() {
    let decision = permissionDecision(
        toolName: "mcp__\(wakilShimServerName)__pane_move",
        knownActions: ["pane_move", "session_set_provider"])
    #expect(decision == .allow)
}

/// The other half of the fix: `permissionDecision` alone is not enough.
/// `permission-prompt-probe.md` §6 measured that an ALLOW-LISTED tool
/// never even reaches `approve_tool_use` — pre-approval bypasses the
/// bridge entirely — so `session_set_provider` must also be missing from
/// `agentAllowedTools`'s own output, by name, or the denial above would
/// simply never run. `registryForTesting()` builds the registry the way
/// production actually does, `session_set_provider` included, so this is
/// a real exclusion rather than one true by omission.
@Test func sessionSetProviderNeverReachesTheAllowedToolsList() async {
    let allowed = agentAllowedTools(actions: await registryForTesting().all())
    #expect(!allowed.contains { $0.contains("session_set_provider") })
}

/// `session_set_provider` IS registered in the ordinary place now (Fix
/// round 1's revert), so `--dispatch`'s own separate `WakilWiring` knows
/// the name — unlike the version this replaces, which left it fully
/// unregistered outside a live window. This does not make a switch
/// happen headlessly (nothing drains `ProviderSwitchBroker` without a
/// `WindowModel` subscribed to it — see `main.swift`'s `runDispatchFile`,
/// which never constructs one), but the action is no longer "unknown".
@Test func sessionSetProviderIsKnownToARegistryBuiltWithoutAnyWindow() async {
    let names = await registryForTesting().all().map(\.name)
    #expect(names.contains("session_set_provider"))
}

/// Fix round 1 of the acceptance review, applied to `ctx_set_provider`:
/// it cannot swap the agent's OWN running session — that still requires
/// `session_set_provider`, which the tests above already pin as
/// unreachable — but it writes `active.json`'s `Provider` field, which
/// `WindowSession.swift` reads to decide which account the NEXT window
/// opens under. An agent free to call this could not move itself today,
/// but could choose which account Wakil runs under after the next
/// relaunch — a deferred form of exactly what excluding
/// `session_set_provider` exists to forbid. Must fail if
/// `operatorOnlyActions` loses its `ctx_set_provider` entry.
@Test func theAgentCannotChooseTheNextLaunchsAccountEither() {
    let decision = permissionDecision(
        toolName: "mcp__\(wakilShimServerName)__ctx_set_provider",
        knownActions: ["ctx_set_provider"])
    guard case .deny = decision else {
        Issue.record("expected the agent to be denied ctx_set_provider, got \(decision)")
        return
    }
}

/// The other half, exactly as `sessionSetProviderNeverReachesTheAllowed
/// ToolsList` pins for its own action: `permissionDecision` alone is not
/// enough, because an ALLOW-LISTED tool never even reaches
/// `approve_tool_use` (`permission-prompt-probe.md` §6). `ctx_set_provider`
/// must also be missing from `agentAllowedTools`'s own output, by name, or
/// the denial above would simply never run.
@Test func ctxSetProviderNeverReachesTheAllowedToolsList() async {
    let allowed = agentAllowedTools(actions: await registryForTesting().all())
    #expect(!allowed.contains { $0.contains("ctx_set_provider") })
}

// MARK: - The swap (Task 9)
//
// `_ = credentials  // Task 9 performs the swap.` is where Task 8 stopped.
// These three are the brief's own failing tests, run first and confirmed
// to fail before any of `setProvider`'s swap code below them was written.

/// Finding 2 of the acceptance review, applied to a provider switch
/// instead of a resume: nothing about the running session may be touched
/// until `next.start` has returned successfully. `makeModel(factoryFails:
/// true)` establishes a genuinely running session on `"main"` first (see
/// its own doc comment), so this is a test that a real session survives a
/// failed switch, not that an empty one stays empty.
@Test func aFailingStartLeavesTheExistingSessionUntouched() async {
    let model = await makeModel(providerId: "main", factoryFails: true)
    let before = await model.sessionId
    await model.setProvider("work")
    #expect(await model.sessionId == before)
    #expect(await model.providerId == "main")
    #expect(await model.thoughts.isEmpty == false)
}

/// The success path's two visible effects: the thread is cleared rather
/// than rebuilt (a provider switch cannot fork — see `setProvider`'s own
/// "A FRESH SESSION, NOT A FORK" comment), and the seam it leaves behind
/// names both accounts, not just one, so an operator scrolling back can
/// tell which turns ran under which.
@Test func aSuccessfulSwitchClearsTheThreadAndDrawsASeam() async {
    let model = await makeModel(providerId: "main")
    await model.setProvider("work")
    #expect(await model.providerId == "work")
    let seam = await model.thoughts.last?.detail ?? ""
    #expect(seam.contains("main"))
    #expect(seam.contains("work"))
}

/// The other half of "not a fork": a switch mints its own fresh session id
/// rather than reusing whatever this window had going, which is what makes
/// it safe for the new account's `claude` to write a transcript nothing
/// else is appending to.
@Test func aSwitchMintsAFreshSessionRatherThanForking() async {
    let model = await makeModel(providerId: "main")
    let before = await model.sessionId
    await model.setProvider("work")
    #expect(await model.sessionId != before)
}

/// The final whole-branch review's Fix 2: a window that opens with NO
/// active provider (`providerId: ""` — a fresh org, or one that has
/// never switched) must not be a dead end. Before the fix,
/// `WindowSession.start` treated an empty `providerId` as equivalent to
/// a broken credentials lookup and threw INSIDE the same `do` block that
/// built `lookup` and `harnessFactory`, so its `catch` installed a
/// `FailingCredentialsLookup` that refuses every id — meaning picking
/// ANY provider from ⌘P on a fresh org failed, regardless of which one
/// was chosen, against a lookup that was never the real one.
/// `WindowModel.setProvider` itself never had that bug: it resolves
/// credentials for the id it is asked to switch TO, not for this
/// window's current (possibly empty) `providerId`. This test pins that
/// contract directly — a switch away from an unset provider, given a
/// working `lookup` and `harnessFactory` (what `WindowSession` now
/// always builds, per the fix), succeeds exactly like a switch between
/// two already-set providers does in `aSuccessfulSwitchClearsTheThread
/// AndDrawsASeam` above — so nothing above `WindowModel` can silently
/// swap back in a lookup that refuses everything.
@Test func aWindowWithNoActiveProviderCanStillAcquireOne() async {
    let model = await makeModel(providerId: "")
    #expect(await model.providerId == "")

    await model.setProvider("main")

    #expect(await model.providerId == "main")
    let status = await model.status
    #expect(status.isEmpty, "\(status)")
    let seam = await model.thoughts.last?.detail ?? ""
    #expect(seam.contains("unset"), "\(seam)")
    #expect(seam.contains("main"), "\(seam)")
}

// MARK: - The "no active provider" note (shared-accounts D3)
//
// The sentence itself used to be appended to `WindowSession.notes`, a
// `let [String]` fixed at launch that `WakilWindow` draws forever — so it
// stayed on screen after ⌘P had chosen an account, contradicting the
// account indicator beside it (`shared-accounts-acceptance.md` D3, seen in
// every screenshot of that walk). It is derived state now, which is both
// what makes it retractable and what puts it somewhere a test can reach:
// `WindowSession` lives in `WakilApp`, which has no test target and cannot
// have one (`phase-2c-ii-b-acceptance.md` §3).

/// Workspaces, piece 3 (the operator's walk of an organisation's first-run home): the home already
/// says what to do, so no standing sentence about the provider is drawn above the composer — only
/// when the operator sends with none set, one plain line naming where to fix it.
@Test func theNoActiveProviderNoteWaitsForASend() async {
    let model = await makeModel(providerId: "")
    #expect(await model.noActiveProviderNote == nil, "the home draws no developer sentence before a send")

    #expect(await model.send("hello") == false)

    let note = await model.noActiveProviderNote ?? ""
    #expect(note == "No provider is set for this organisation — choose one in Settings (⌘,).", "\(note)")
    let status = await model.status
    #expect(status.isEmpty, "said once, by the note: \(status)")
}

/// The defect D3 named. Nothing about the note is right if it survives the switch that makes it false.
@Test func theNoActiveProviderNoteGoesOnceAProviderIsChosen() async {
    let model = await makeModel(providerId: "")
    await model.send("hello")
    #expect(await model.noActiveProviderNote != nil)

    await model.setProvider("main")

    #expect(await model.noActiveProviderNote == nil)
}

/// A window that launched with an account never shows it at all.
@Test func theNoActiveProviderNoteIsAbsentWhenAProviderWasSetAtLaunch() async {
    let model = await makeModel(providerId: "main")
    #expect(await model.noActiveProviderNote == nil)
}

/// The first-run home lists sessions with no project, and `session_list` refuses that — an expected
/// answer, not an error to draw (the home says what to do). Any other failure is still said, whole,
/// and once (Rule 8): it was drawn `session_list: session_list: …`.
@Test func theHomesSessionReadSaysNothingForNoProjectYetAndTheRestOnce() async {
    func model(failingWith message: String) async -> WindowModel {
        await makeModel(providerId: "main", configureRegistry: { registry in
            await registry.register(Action(
                name: "session_list", description: "fails", kind: .read, audience: .agentReachable,
                schema: .object(["type": .string("object")]),
                handler: { _ in throw StandardActionError.serverError(action: "session_list", message: message) }))
        })
    }
    let noProject = await model(failingWith: "no active project — run set_project first")
    _ = await noProject.landingSessions()
    let quiet = await noProject.status
    #expect(!quiet.contains("session_list"), "\(quiet)")

    let broken = await model(failingWith: "the session index could not be read")
    _ = await broken.landingSessions()
    let status = await broken.status
    #expect(status.contains("session_list: the session index could not be read"), "\(status)")
    #expect(!status.contains("session_list: session_list:"), "\(status)")
}

// MARK: - The persistence write (Task 9, Step 5)
//
// `setProvider` dispatches `ctx_set_provider` after the swap has already
// succeeded, exactly the way `resume(sessionId:)` dispatches
// `session_record_parent` after its own swap — best effort, so a failed
// write costs a remembered default on the next launch rather than costing
// the operator the session they just switched to. `ctx_set_provider`
// itself (`StandardActions.swift`) is what actually calls `wakil-ctx`'s
// `set_provider` tool, which is what writes `active.json`
// (`cmd/wakil-ctx/main.go`'s `setActiveProvider`, Task 7's `WriteActive`);
// none of that machinery is spun up here — these two tests only pin that
// `WindowModel` calls it, and calls it with the right shape, through a
// registry `makeModel`'s `configureRegistry:` lets a test observe or fail
// without spawning `wakil-ctx`.

/// Records what it was dispatched with, so a test can assert `setProvider`
/// actually reached the persistence action rather than merely not
/// crashing without it (every OTHER test in this file registers no
/// `ctx_set_provider` at all, and still passes — proving the dispatch is
/// best-effort, but not that it happens).
private actor DispatchSpy {
    private(set) var calls: [JSONValue] = []
    func record(_ params: JSONValue) { calls.append(params) }
}

@Test func aSuccessfulSwitchDispatchesThePersistenceWriteWithTheChosenProvider() async {
    let spy = DispatchSpy()
    let model = await makeModel(providerId: "main", configureRegistry: { registry in
        await registry.register(Action(
            name: "ctx_set_provider",
            description: "test spy",
            kind: .control,
            schema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { params in
                await spy.record(params)
                return .object([:])
            }
        ))
    })

    await model.setProvider("work")

    let calls = await spy.calls
    #expect(calls == [.object(["name": .string("work")])])
}

/// The "best effort" half made explicit, rather than left to be inferred
/// from every other test's silence: a persistence write that fails
/// outright — not merely absent, but registered and throwing — still
/// leaves the swap that already happened standing.
@Test func aPersistenceWriteFailureDoesNotUndoTheSwap() async {
    let model = await makeModel(providerId: "main", configureRegistry: { registry in
        await registry.register(Action(
            name: "ctx_set_provider",
            description: "test spy that always fails",
            kind: .control,
            schema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in throw StubLookupError() }
        ))
    })

    await model.setProvider("work")

    #expect(await model.providerId == "work")
    #expect(await model.sessionId != nil)
}

// MARK: - The settings pane survives a switch made from it

/// **From the 2e walk: pressing USE in the settings pane closed the pane.**
/// A switch starts a fresh conversation and activates its layout, and the
/// settings pane is never saved in one (`aSavedLayoutNeverHoldsASettingsPane`),
/// so the swap dropped it. The operator was in the middle of using it, and
/// nothing about a provider switch within one organisation is a reason to
/// close it.
@Test @MainActor func switchingProviderKeepsAnOpenSettingsPaneOpen() async {
    let registry = ActionRegistry(journalDirectory: providerSwitchScratchDirectory(), sessionId: "switch-keeps-settings")
    let layout = LayoutStore()
    let panes = PaneStore()
    await registerLayoutActions(into: registry, layout: layout, panes: panes)
    let working = SwitchableHarness()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in working }, resumes: ResumeBroker(),
        rootPath: "/tmp", providerId: "main", lookup: FakeLookup())
    // A project, so the switch really swaps layouts: the scope is
    // (organisation, project, lineage), and a switch mints a new lineage.
    // With no project `activateLayout` does nothing and this passed vacuously.
    model.setOrganizationForTesting("acme")
    model.seedForTesting(providerId: "main", rootPath: "/tmp", thoughts: 0, project: "widgets")

    await model.openSettings()
    #expect(model.layoutSnapshot.panes.contains { $0.kind == Pane.settingsKind })
    // Where the operator left it, which the reopened pane must come back to.
    let settingsId = model.layoutSnapshot.panes.first { $0.kind == Pane.settingsKind }!.id
    _ = try? await registry.dispatch(
        name: "pane_move", params: .object(["id": .string(settingsId), "x": .number(40), "y": .number(60)]),
        origin: .ui, caller: .test(""), confirmation: nil)
    _ = try? await registry.dispatch(
        name: "pane_resize",
        params: .object(["id": .string(settingsId), "width": .number(900), "height": .number(520)]),
        origin: .ui, caller: .test(""), confirmation: nil)
    await model.refreshLayout()
    let before = model.layoutSnapshot.panes.first { $0.kind == Pane.settingsKind }!.frame

    await model.setProvider("work")

    #expect(model.providerId == "work")
    #expect(model.layoutSnapshot.panes.contains { $0.kind == Pane.settingsKind },
            "USE in the settings pane closed the settings pane")
    #expect(model.layoutSnapshot.panes.first { $0.kind == Pane.settingsKind }?.frame == before,
            "the settings pane came back somewhere other than where the operator left it")
    // **The same pane, not a reopened one.** A reopen closed it, drew a fresh
    // pane at the cascade position with nothing loaded, then moved it back,
    // and the operator saw all three. Carried across, it never leaves.
    #expect(model.layoutSnapshot.panes.first { $0.kind == Pane.settingsKind }?.id == settingsId,
            "the settings pane was closed and reopened, which is the twitch")
}
