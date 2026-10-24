import Foundation
import Testing
@testable import WakilKit

/// `term_open(path:)` — the first of the terminal pane's four actions, and
/// the only one that does not name a pane's contents: a shell has to
/// *exist* before anything runs in it, and the shell owns the input line,
/// so the operator's first typed command never passes through an action
/// at all.
///
/// Every test that opens a store goes through `terminalFixture` (this
/// file) or `withTerminalStore` (`TerminalStoreTests.swift`, no longer
/// `private` for exactly this reason) so no shell survives the test that
/// opened it.

private func scratchDirectory() throws -> URL {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A registry with `term_open` registered, plus the stores it was
/// registered against — the shape every test below needs, assembled once.
private func terminalFixture() async throws -> (
    registry: ActionRegistry, terminals: TerminalStore, layout: LayoutStore, panes: PaneStore
) {
    let registry = ActionRegistry(journalDirectory: try scratchDirectory(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let terminals = TerminalStore(scratchRoot: testScratchRoot, panes: panes)
    await registerTerminalActions(into: registry, terminals: terminals, panes: panes, layout: layout)
    return (registry, terminals, layout, panes)
}

private struct NoPaneIdReturned: Error {}

/// Dispatches `term_open` at `path`, naming no pane, and returns the id
/// the handler opened — the id a test needs to reopen or replace it.
private func open(_ registry: ActionRegistry, path: String) async throws -> String {
    let result = try await registry.dispatch(
        name: "term_open", params: .object(["path": .string(path)]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    guard case .object(let fields) = result, case .string(let paneId)? = fields["pane"] else {
        throw NoPaneIdReturned()
    }
    return paneId
}

/// A terminal-kind pane with no shell behind it — straight through
/// `LayoutStore`, bypassing `term_open` entirely.
///
/// `term_scroll` (unlike `term_open`/`term_propose`/`term_run`) never
/// touches `TerminalStore`: `requireOpenPane` only checks that the id is
/// in `layout.snapshot().panes`, and the block it scrolls to comes from
/// `PaneStore` directly. A real PTY is a live child process — cheap for
/// the handful of `term_open` tests that are actually testing the shell,
/// expensive multiplied across every test that merely needs *a pane id*.
/// Fix round 1 (full-gate bisection) traced a deterministic failure of
/// `WindowModelTests`' `aDispatchThatArrangesNothingWritesNothingEvenWithAPaneBusy`
/// to the added process load of three such spawns per run; this is the
/// same pane `term_scroll`'s own tests need, at none of that cost.
private func openBarePane(_ layout: LayoutStore) async -> String {
    await layout.open(kind: "terminal", title: "t").id
}

@Test func termOpenOpensAndTitlesAPaneWhenTheCallNamesNone() async throws {
    let registry = ActionRegistry(journalDirectory: try scratchDirectory(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let terminals = TerminalStore(scratchRoot: testScratchRoot, panes: panes)
    await registerTerminalActions(into: registry, terminals: terminals, panes: panes, layout: layout)

    let result = try await registry.dispatch(
        name: "term_open", params: .object(["path": .string(NSTemporaryDirectory())]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    guard case .object(let fields) = result, case .string(let paneId)? = fields["pane"] else {
        Issue.record("no pane id returned"); return
    }
    let opened = await layout.snapshot().panes.first { $0.id == paneId }
    #expect(opened?.kind == "terminal")
    // Titled from the path, through the same helper by which a query
    // titles a pane by its database.
    #expect(opened?.title.isEmpty == false)
    #expect(await terminals.isRunning(paneId: paneId))

    await terminals.shutdownAll()
}

/// Walk-defects B2, part 1: `term_open` must leave the pane remembering
/// the path it opened at, not only the title derived from it — otherwise
/// a dead pane restored after `clearForOrgSwitch` has a name and nowhere
/// to reopen at.
@Test func termOpenRecordsThePathOnThePaneNotOnlyTheTitle() async throws {
    let (registry, terminals, layout, _) = try await terminalFixture()
    let path = NSTemporaryDirectory()

    let paneId = try await open(registry, path: path)

    let opened = await layout.snapshot().panes.first { $0.id == paneId }
    #expect(opened?.terminalPath == path)

    await terminals.shutdownAll()
}

/// `term_open` naming an EXISTING pane at a new path updates the
/// remembered path too, exactly as it already updates the title.
@Test func termOpenOnAnExistingPaneUpdatesItsRememberedPath() async throws {
    let (registry, terminals, layout, _) = try await terminalFixture()
    let first = try await open(registry, path: NSTemporaryDirectory())

    let second = try await scratchDirectory()
    _ = try await registry.dispatch(
        name: "term_open",
        params: .object(["pane": .string(first), "path": .string(second.path)]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    let opened = await layout.snapshot().panes.first { $0.id == first }
    #expect(opened?.terminalPath == second.path)

    await terminals.shutdownAll()
}

@Test func termOpenIsAControlActionAllowedEverywhereIncludingProduction() async throws {
    // `.mutate` breaks twice: it gates EVERYWHERE outside production, so
    // every `ls` would cost a typed confirmation, and it blocks IN
    // production regardless of origin, so the pane would die exactly where
    // an operator most wants a shell.
    let (registry, terminals, _, _) = try await terminalFixture()

    let result = try await registry.dispatch(
        name: "term_open", params: .object(["path": .string(NSTemporaryDirectory())]),
        origin: .agent, caller: .test("production"), confirmation: nil)

    #expect(result != .null)
    let descriptor = await registry.all().first { $0.name == "term_open" }
    #expect(descriptor?.kind == .control)
    await terminals.shutdownAll()
}

@Test func aPathOutsideEveryProjectRootIsAcceptedSilently() async throws {
    // Refusing one would be theatre: it is a real PTY and `cd` walks out
    // of any fence. Deliberately more permissive than session reads, which
    // refuse a cwd outside the active project's roots — a shell is not an
    // agent session, and the real boundary for a shell is the write gate
    // and the injected environment.
    let (registry, terminals, _, _) = try await terminalFixture()

    _ = try await registry.dispatch(
        name: "term_open", params: .object(["path": .string("/usr/lib")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    await terminals.shutdownAll()
}

@Test func termOpenOnAPaneThatAlreadyHasAShellReplacesItRatherThanLeaking() async throws {
    let (registry, terminals, layout, _) = try await terminalFixture()
    let first = try await open(registry, path: NSTemporaryDirectory())
    let pidBefore = await terminals.pidForTesting(paneId: first)

    _ = try await registry.dispatch(
        name: "term_open",
        params: .object(["pane": .string(first), "path": .string("/usr/lib")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    #expect(await terminals.pidForTesting(paneId: first) != pidBefore)
    #expect(kill(pidBefore!, 0) == -1)
    #expect(await layout.snapshot().panes.count == 1)
    await terminals.shutdownAll()
}

@Test func anUnsupportedShellIsRefusedWithAReasonRatherThanOpeningDegraded() async throws {
    let (registry, terminals, _, _) = try await terminalFixture()

    await #expect(throws: TerminalOpenError.self) {
        _ = try await registry.dispatch(
            name: "term_open",
            params: .object(["path": .string("/tmp"), "shell": .string("/bin/fish")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }
    await terminals.shutdownAll()
}

/// Polls `condition` until it holds or `seconds` elapse, recording an
/// issue on timeout rather than silently letting the test's own
/// assertions fail with no explanation of how long it waited.
///
/// A file-local copy of `TerminalStoreTests.swift`'s helper of the same
/// name and shape, which is `private` to that file.
private func waitUntil(
    seconds: Double, _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(seconds * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("condition did not hold within \(seconds)s")
}

// MARK: - term_propose and term_run (Task 11)

/// `term_propose` — the agent's half of Invariant 7's "two Enters,
/// deliberately": a proposal is drawn as a block that has NOT run, at
/// the tail of the history, directly above the operator's live prompt.
@Test func aProposalIsABlockThatHasNotRunAtTheTailOfTheHistory() async throws {
    let (registry, terminals, layout, panes) = try await terminalFixture()
    let pane = try await open(registry, path: NSTemporaryDirectory())

    _ = try await registry.dispatch(
        name: "term_propose",
        params: .object(["pane": .string(pane), "command": .string("kubectl get pods")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    guard let snapshot = (await panes.snapshot(paneId: pane, kind: "terminal")).terminal
    else { Issue.record("no terminal snapshot"); return }
    // A band or a card would give one thing two homes: the agent reads a
    // block where the operator sees a banner.
    #expect(snapshot.blocks.last?.origin == .proposed)
    #expect(snapshot.blocks.last?.command == "kubectl get pods")
    #expect(snapshot.blocks.last?.exitCode == nil)
    await terminals.shutdownAll()
}

@Test func atMostOneProposalIsPendingAndTheReplacementIsItselfJournalled() async throws {
    let (registry, terminals, _, panes) = try await terminalFixture()
    let pane = try await open(registry, path: NSTemporaryDirectory())

    for command in ["aws s3 ls", "aws s3 ls s3://other"] {
        _ = try await registry.dispatch(
            name: "term_propose",
            params: .object(["pane": .string(pane), "command": .string(command)]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }

    let proposals = (await panes.terminalBlocks(paneId: pane)).filter { $0.origin == .proposed }
    #expect(proposals.count <= 1)
    #expect(await panes.terminalProposal(paneId: pane)?.command == "aws s3 ls s3://other")
    // An agent must not be able to silently swap the command under a hand
    // already moving to Enter — so the replacement leaves its own line.
    let entries = try await registry.journalEntries().filter { $0.action == "term_propose" }
    #expect(entries.count == 2)
    await terminals.shutdownAll()
}

/// **Drives the real `WindowModel.acceptProposal(pane:)`**, not a
/// reproduction of what it does. The brief's own Step-1 test for this
/// case called `terminals.write` and `panes.setTerminalProposal(nil)`
/// directly — this repository's own standing lesson about a passing test
/// that calls a method the shipped path does not call, caught on review.
/// Carried through to the `term_run` journal entry the acceptance
/// eventually produces, so `accepted == "proposed"` is proven end to end,
/// not merely asserted as a proxy.
@MainActor
@Test func acceptingAProposalPutsItInThePromptUnrunThenJournalsItAsProposedOnceRun() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "initech")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.proposeForTesting(pane: pane, command: "printf hi; exit 4")
    #expect(await model.terminalProposalForTesting(pane: pane)?.command == "printf hi; exit 4")

    // The operator's first ⏎: `acceptProposal` writes the bytes WITHOUT a
    // newline, so the command sits in the shell's own prompt unrun, and
    // clears the proposal — or the operator would see the same command
    // twice, once as the dashed block, once as the live prompt it just
    // filled.
    await model.acceptProposal(pane: pane)

    #expect(await model.terminalProposalForTesting(pane: pane) == nil)
    try await waitUntil(seconds: 5) {
        await model.screenContainsForTesting(pane: pane, "printf hi; exit 4")
    }
    // Not run yet: no block exists for it.
    #expect(await model.terminalBlocksForTesting(pane: pane).isEmpty)

    // The operator's second ⏎: just the newline, into the same pty —
    // indistinguishable, from this instant on, from a command the
    // operator typed and submitted by hand.
    await model.sendToTerminalForTesting(pane: pane, text: "\n")

    try await waitUntil(seconds: 8) { await model.journalledRuns().count == 1 }
    let entry = await model.journalledRuns()[0]
    guard case .object(let params) = entry.params else { Issue.record("no params"); return }
    #expect(params["command"] == .string("printf hi; exit 4"))
    #expect(params["exitCode"] == .number(4))
    // The one field that survives the fact that, from the instant
    // `acceptProposal` wrote it, the bytes are indistinguishable from
    // typed ones: this is the only place "the agent proposed this and a
    // human accepted it" is still legible after the fact.
    #expect(params["accepted"] == .string("proposed"))
    await model.shutdown()
}

/// The sibling of the case above: `⌫` clears the proposal and writes
/// nothing to the shell at all — no bytes, unrun or otherwise, ever
/// reach the pty.
@MainActor
@Test func discardingAProposalClearsItAndWritesNothingToTheShell() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "initech")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.proposeForTesting(pane: pane, command: "echo discarded")
    #expect(await model.terminalProposalForTesting(pane: pane) != nil)

    await model.discardProposal(pane: pane)

    #expect(await model.terminalProposalForTesting(pane: pane) == nil)
    #expect(await model.screenContainsForTesting(pane: pane, "echo discarded") == false)
    #expect(await model.terminalBlocksForTesting(pane: pane).isEmpty)
    await model.shutdown()
}

@MainActor
@Test func aRunIsJournalledWithItsCommandContextExitCodeAndHowItWasAccepted() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "initech")
    // Drives the REAL pump, not a store method the shipped path may not
    // call — 2b-viii's standing lesson.
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: pane, text: "printf hi; exit 4\n")

    try await waitUntil(seconds: 8) { await model.journalledRuns().count == 1 }
    let entry = await model.journalledRuns()[0]

    guard case .object(let params) = entry.params else { Issue.record("no params"); return }
    #expect(params["command"] == .string("printf hi; exit 4"))
    #expect(params["exitCode"] == .number(4))
    #expect(params["accepted"] == .string("typed"))
    #expect(params["cwd"] != nil)
    #expect(entry.environment == "")      // whatever the model's is
    #expect(entry.origin == .ui)
    // NOT the output. It is unbounded, and this pane's own worked example
    // is a `keychain` grep, so the journal would become where secrets
    // accumulate. Output is read through read_pane.
    #expect(params["output"] == nil)
    await model.shutdown()
}

/// **All seven of the issue's named fields, on one journalled run**
/// (two-axis review, Spec 3). Issue #72: *"What a run's journal entry
/// records: the command, the cwd, the active (organisation, project,
/// environment), the origin, the exit code, the duration, and whether the
/// command was proposed by the agent and accepted or typed by the
/// operator."*
///
/// **Organisation and project were recorded nowhere at all** until this
/// wave — `journalTerminalRun` wrote five params plus `pane`, and
/// `JournalEntry` supplied `origin` and `environment`, which left two of
/// the seven unrecorded while `term_open` was already reading both from
/// the same `activeShellContext`. Asserted here on a real run through the
/// real pump, with a seeded org/project/environment, so the values are the
/// window's own and not a constant.
@MainActor
@Test func aJournalledRunCarriesTheActiveOrganisationAndProjectToo() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "initech")
    model.seedForTesting(
        providerId: "test-provider", rootPath: NSTemporaryDirectory(), thoughts: 0,
        project: "booking", environment: "staging")

    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: pane, text: "printf hi; exit 0\n")

    try await waitUntil(seconds: 8) { await model.journalledRuns().count == 1 }
    let entry = await model.journalledRuns()[0]
    guard case .object(let params) = entry.params else { Issue.record("no params"); return }

    // The two that were missing.
    #expect(params["org"] == .string("initech"))
    #expect(params["project"] == .string("booking"))
    // And the other five, so this test states the whole shape rather than
    // only its repair: environment and origin are `JournalEntry`'s own
    // columns, the rest are params.
    #expect(entry.environment == "staging")
    #expect(entry.origin == .ui)
    #expect(params["command"] == .string("printf hi; exit 0"))
    #expect(params["cwd"] != nil)
    #expect(params["exitCode"] == .number(0))
    #expect(params["durationMs"] != nil)
    #expect(params["accepted"] == .string("typed"))
    await model.shutdown()
}

/// **The wiring `WindowModel.forTesting` must not skip.**
/// `WindowModel.closePane(id:)` dispatches `"pane_close"` — not a
/// `LayoutStore` call `forTesting`'s own registry could route around —
/// so a `forTesting` model whose `initialActions:` omitted the layout
/// action set would find `pane_close` unknown, swallow the failure into
/// `status`, and leave the pane (and, in a real assembly, its shell)
/// never closed at all. This asserts the pane actually disappears from
/// `layoutSnapshot`, not merely that the registry contains the name.
@MainActor
@Test func closingATerminalPaneThroughTheModelActuallyClosesIt() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "initech")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    #expect(!pane.isEmpty)
    // `openTerminalForTesting` dispatches straight through the registry,
    // bypassing the window's own `dispatch`/`dispatchLayout` wrappers, so
    // `layoutSnapshot` needs an explicit refresh here — exactly what the
    // observation pump would otherwise do on its own timing.
    await model.refreshLayout()
    #expect(model.layoutSnapshot.panes.contains { $0.id == pane })

    await model.closePane(id: pane)

    #expect(!model.layoutSnapshot.panes.contains { $0.id == pane })
    await model.shutdown()
}

/// `term_scroll` — the fourth and last terminal action, bringing a block
/// into view by its id rather than a row index.
@Test func termScrollBringsABlockIntoViewByIdRatherThanByPosition() async throws {
    let (registry, terminals, layout, panes) = try await terminalFixture()
    let pane = await openBarePane(layout)
    for index in 0..<3 {
        await panes.recordTerminal(paneId: pane, block: TerminalBlock(
            id: "b\(index)", command: "echo \(index)", origin: .operatorTyped, exitCode: 0,
            durationMs: 1, output: [], heldTheGrid: false,
            startedAt: Date(timeIntervalSince1970: Double(index))))
    }

    _ = try await registry.dispatch(
        name: "term_scroll", params: .object(["pane": .string(pane), "block": .string("b1")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    #expect(await panes.terminalScrollTarget(paneId: pane) == "b1")
    await terminals.shutdownAll()
}

@Test func termScrollDoesNotTakeARowBecauseThatWordAlreadyMeansSomethingElse() async throws {
    // `row` is documented three times over as a zero-based index into a
    // displayed order that a SORT changes. A terminal has no sort, and
    // reusing the parameter would give it three incompatible meanings
    // behind one name — a table row, a block, or a terminal line,
    // depending on kind and current screen.
    let (registry, terminals, _, _) = try await terminalFixture()
    let descriptor = await registry.all().first { $0.name == "term_scroll" }

    guard case .object(let schema)? = descriptor?.schema,
          case .object(let properties)? = schema["properties"] else {
        Issue.record("no schema"); return
    }
    #expect(properties["row"] == nil)
    #expect(properties["block"] != nil)
    await terminals.shutdownAll()
}

@Test func termScrollWithNoBlockClearsThePendingTarget() async throws {
    // The surface dispatches this itself once it has scrolled, so the same
    // block can be asked for again — the shape pane_scroll_clear already
    // has, folded into one action because a terminal has one of them.
    let (registry, terminals, layout, panes) = try await terminalFixture()
    let pane = await openBarePane(layout)
    await panes.setTerminalScrollTarget(paneId: pane, blockId: "b1")

    _ = try await registry.dispatch(
        name: "term_scroll", params: .object(["pane": .string(pane)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    #expect(await panes.terminalScrollTarget(paneId: pane) == nil)
    await terminals.shutdownAll()
}

@Test func termScrollRefusesABlockThePaneDoesNotHold() async throws {
    // An id that names nothing would write a scroll target the view can
    // never satisfy and return success — the no-op shape the five grid
    // actions were just cured of.
    let (registry, terminals, layout, _) = try await terminalFixture()
    let pane = await openBarePane(layout)

    await #expect(throws: LayoutActionError.self) {
        _ = try await registry.dispatch(
            name: "term_scroll",
            params: .object(["pane": .string(pane), "block": .string("b-nope")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
    }
    await terminals.shutdownAll()
}

// MARK: - The pane carries the active context (final review, Critical 3)

/// **`term_open` folds the window's live organisation, project and
/// environment into the shell it starts** — the claim the action's own
/// description makes (*"The shell carries the active organisation, project
/// and environment — the context a credentialed command is run against,
/// and exactly why you may not run in it. It carries no secrets of its
/// own"*), and the claim the acceptance runbook's Check 3 walks.
///
/// **That last sentence is the two-axis review's Spec 2.** The description
/// used to say the shell is "what makes a credentialed command work here
/// without exporting anything by hand", which claimed more than
/// `terminalChildEnvironment` does: it exports three `WAKIL_*` variables
/// and `TERM`, and no Keychain material at all. The code is right and the
/// prose was wrong, so the prose moved.
///
/// **It was not true until the final fix wave.** `terminalActions`'
/// `activeContext:` defaulted to always-empty and no call site anywhere
/// overrode it, so none of the three was ever exported. Worse for
/// diagnosis: `WAKIL_ORG` is *inherited* from Wakil's own process
/// environment, so a walk could see the org apparently right and the other
/// two empty and go looking in the wrong place.
///
/// Driven through the real `term_open` — `openTerminalForTesting`
/// dispatches it — into a real shell, and read back off that shell's own
/// screen: the only assertion that cannot pass against a builder called
/// with the right arguments and wired to nothing.
@MainActor
@Test func aShellCarriesTheWindowsActiveOrgProjectAndEnvironment() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "initech")
    model.seedForTesting(
        providerId: "test-provider", rootPath: NSTemporaryDirectory(), thoughts: 0,
        project: "booking", environment: "staging")

    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    // Printed as one bracketed line so the assertion cannot be satisfied by
    // the echo of the command itself, which carries the variable NAMES.
    await model.sendToTerminalForTesting(
        pane: pane,
        text: "printf 'ctx=[%s|%s|%s]\\n' \"$WAKIL_ORG\" \"$WAKIL_PROJECT\" \"$WAKIL_ENVIRONMENT\"\n")

    try await waitUntil(seconds: 8) {
        await model.screenContainsForTesting(pane: pane, "ctx=[initech|booking|staging]")
    }
    await model.shutdown()
}

/// The other half of Critical 3's ruling: the context must be a **closure
/// read at dispatch time**, not a value captured when the actions were
/// registered.
///
/// This is not a style preference. `WakilWiring.build` registers the
/// terminal actions before any window exists, and the active context then
/// changes for the rest of the app's life — a project switch, an
/// environment switch, an org switch. A captured value would pin every
/// shell Wakil ever opens to the launch context, which is the same
/// reasoning `MCPSocketServer`'s `caller` already follows for
/// the environment the write gate judges.
@MainActor
@Test func theActiveContextIsReadAtDispatchTimeAndNotCapturedAtRegistration() async throws {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    model.seedForTesting(
        providerId: "p", rootPath: "/tmp", thoughts: 0, project: "one", environment: "staging")

    let context = ActiveShellContext()
    // Installed once, exactly as `WakilWiring.useActiveContext(of:)` does.
    context.use { [weak model] in
        guard let model else { return ("", "", "", "") }
        return await model.activeShellContext
    }
    #expect(await context.current() == ("alpha", "one", "staging", "/tmp"))

    model.seedForTesting(
        providerId: "p", rootPath: "/tmp", thoughts: 0, project: "two", environment: "production")

    #expect(await context.current() == ("alpha", "two", "production", "/tmp"))
    await model.shutdown()
}

/// With no source installed — `--dispatch`, and every test that builds a
/// bare registry — the three env-var keys stay ABSENT from the shell's
/// environment rather than being exported as empty strings, which is the
/// rule `terminalChildEnvironment` already holds itself to. `rootPath` is
/// the fourth member and has no env-var key at all; unwired, it comes
/// back `""` too, and `term_open`'s own handler is what falls back to
/// `NSHomeDirectory()` for that case (see
/// `termOpenDefaultsToHomeWhenUnwiredAndNoPathIsGiven` below).
@Test func anUnwiredContextLeavesTheThreeKeysAbsentRatherThanEmpty() async throws {
    let context = ActiveShellContext()
    let empty = await context.current()
    #expect(empty == ("", "", "", ""))

    let environment = terminalChildEnvironment(
        org: empty.org, project: empty.project, environment: empty.environment,
        base: ["PATH": "/usr/bin"])
    #expect(environment["WAKIL_ORG"] == nil)
    #expect(environment["WAKIL_PROJECT"] == nil)
    #expect(environment["WAKIL_ENVIRONMENT"] == nil)
}

// MARK: - `term_open`'s default `path` (walk-defects B1)
//
// Before this wave, `path` was `term_open`'s one required param, so ⌘K's
// param-less dispatch (the old `WindowModel.runPaletteItem`) and a bare mouse
// button both failed with `term_open: missing required param "path"` — the
// same §6.1 gap the old "Open pane" button worked around, hit again by
// a second pane kind. `path` is now optional, and its omission resolves to
// the active context's `rootPath` (the active project's root), or to the
// operator's home directory when no context is wired at all.

@Test func termOpenDoesNotRequirePathInItsSchemaAnyMore() async throws {
    let (registry, terminals, _, _) = try await terminalFixture()
    let descriptor = await registry.all().first { $0.name == "term_open" }
    guard case .object(let schema)? = descriptor?.schema else {
        Issue.record("no schema"); return
    }
    if case .array(let required)? = schema["required"] {
        #expect(!required.contains(.string("path")))
    }
    // Absent altogether is equally acceptable; either way `path` must not
    // be required.
    await terminals.shutdownAll()
}

@Test func termOpenDefaultsToTheActiveContextsRootPathWhenPathIsOmitted() async throws {
    let registry = ActionRegistry(journalDirectory: try scratchDirectory(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let terminals = TerminalStore(scratchRoot: testScratchRoot, panes: panes)
    let root = try scratchDirectory().path
    for action in terminalActions(
        terminals: terminals, panes: panes, layout: layout,
        activeContext: { ("org", "proj", "staging", root) }
    ) {
        await registry.register(action)
    }

    let result = try await registry.dispatch(
        name: "term_open", params: .object([:]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    guard case .object(let fields) = result, case .string(let paneId)? = fields["pane"] else {
        Issue.record("no pane id returned"); return
    }
    // The pane is titled from the path `term_open` actually used
    // (`terminalPaneTitle(forPath:)`), which is how this asserts which
    // path was chosen without depending on the shell's own realpath
    // resolution of a scratch directory.
    let opened = await layout.snapshot().panes.first { $0.id == paneId }
    #expect(opened?.title == terminalPaneTitle(forPath: root))

    await terminals.shutdownAll()
}

@Test func termOpenDefaultsToHomeWhenUnwiredAndNoPathIsGiven() async throws {
    // `terminalFixture` registers through `registerTerminalActions` with
    // no `activeContext:` override — the always-empty default `--dispatch`
    // and a bare registry get — so `context.rootPath` is `""` and the
    // handler's own `NSHomeDirectory()` fallback is what fires.
    let (registry, terminals, layout, _) = try await terminalFixture()

    let result = try await registry.dispatch(
        name: "term_open", params: .object([:]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    guard case .object(let fields) = result, case .string(let paneId)? = fields["pane"] else {
        Issue.record("no pane id returned"); return
    }
    let opened = await layout.snapshot().panes.first { $0.id == paneId }
    #expect(opened?.title == "~")

    await terminals.shutdownAll()
}

/// Final fix wave, item 6 (ruling P11): `term_open`'s description names no control the window no
/// longer has. The *Open terminal* button was deleted with the palette; ⌘P and the Landing open a
/// terminal now.
@Test func termOpenDescribesTheControlsThatExist() async throws {
    let panes = PaneStore()
    let terminals = TerminalStore(scratchRoot: testScratchRoot, panes: panes)
    let open = try #require(terminalActions(terminals: terminals, panes: panes, layout: LayoutStore())
        .first { $0.name == "term_open" })
    #expect(!open.description.contains("Open terminal"))
    #expect(open.description.contains("⌘P"))
    #expect(open.description.contains("Landing"))
}

/// #1: `pane_open {kind: terminal}` opened a pane with no shell behind it — "no shell · 0×0"
/// for good, and keys typed into it went nowhere. It opens through `term_open`'s handler now.
@Test func paneOpenOfATerminalStartsItsShell() async throws {
    let registry = ActionRegistry(journalDirectory: try scratchDirectory(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let terminals = TerminalStore(scratchRoot: testScratchRoot, panes: panes)
    let termOpen = terminalActions(terminals: terminals, panes: panes, layout: layout)
        .first { $0.name == "term_open" }?.handler
    await registerLayoutActions(
        into: registry, layout: layout, panes: panes, terminals: terminals, openTerminal: termOpen)

    let result = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("terminal"), "title": .string("mine")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

    guard case .object(let fields) = result, case .string(let paneId)? = fields["id"] else {
        Issue.record("no pane id returned"); return
    }
    #expect(await terminals.isRunning(paneId: paneId))
    #expect(await layout.snapshot().panes.first { $0.id == paneId }?.title == "mine")
    #expect(await layout.snapshot().panes.count == 1)
    await terminals.shutdownAll()
}
