import Foundation
import Testing
@testable import WakilKit

// Background agents, 4 of 4, Task 1: one chip per agent in another place, and the click that
// goes there.

private let org = "initech"
private let placeA = Place(organization: org, project: "api", environment: "staging")
private let placeB = Place(organization: org, project: "billing", environment: "staging")
private let placeC = Place(organization: org, project: "crm", environment: "staging")

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2 * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// Puts `place` on the screen's context fields, with no `wakil-ctx` behind them.
@MainActor
private func show(_ place: Place, in model: WindowModel) {
    model.seedForTesting(
        providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
        project: place.project, environment: place.environment)
}

/// `show`, then the activation a real switch ends in: the place becomes the screen's.
@MainActor
private func visit(_ place: Place, in model: WindowModel) async {
    show(place, in: model)
    await model.activateLayoutForTesting()
}

@MainActor
private func chipWindow(_ harnesses: Harnesses, confirmations: ConfirmationBroker = ConfirmationBroker()) -> WindowModel {
    WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: org,
        harnessFactory: { place, _ in harnesses.make(place) }, confirmations: confirmations)
}

/// Starts a turn in `place` and leaves the screen on `screen`.
@MainActor
private func startTurn(in place: Place, thenShow screen: Place, _ model: WindowModel) async {
    show(place, in: model)
    #expect(await model.send("hello \(place.project)"))
    show(screen, in: model)
}

@MainActor
struct AgentChipTests {
    @Test func noAgentsElsewhereMeansNoChips() {
        let model = chipWindow(Harnesses())
        show(placeA, in: model)
        #expect(model.chips.isEmpty)
    }

    @Test func aWorkingAgentElsewhereIsAVioletChip() async throws {
        let harnesses = Harnesses()
        let model = chipWindow(harnesses)
        await startTurn(in: placeA, thenShow: placeB, model)

        let chip = try #require(model.chips.first)
        #expect(model.chips.count == 1)
        #expect(chip.place == placeA)
        #expect(chip.state == .working)
        #expect(chip.label == "initech · api · staging — hello api")
        #expect(!chip.productionEnvironment)
    }

    @Test func aWaitingAgentShowsAmberWhateverElseIsTrue() async throws {
        let harnesses = Harnesses()
        let broker = ConfirmationBroker()
        let model = chipWindow(harnesses, confirmations: broker)
        await startTurn(in: placeA, thenShow: placeB, model)
        let proposal = PendingMutation(
            action: "db_run_mutation", params: .object([:]), database: nil, statement: "DELETE FROM t",
            affectsEveryRow: true, origin: .agent, place: placeA,
            conversation: try #require(model.agents[placeA]?.id))
        let parked = Task { await broker.request(proposal) }

        #expect(await waitUntil { model.chips.first?.state == .waiting }, "\(model.chips)")
        #expect(model.agents[placeA]?.turnInFlight == true, "the turn is in flight too")
        #expect(model.chips.count == 1)

        await broker.cancel(id: proposal.id)
        _ = await parked.value
    }

    @Test func theOperatorsOwnProposalDoesNotMakeAChipWait() async throws {
        // Final review, minor 1: only the agent's proposal is the agent waiting on the operator.
        let harnesses = Harnesses()
        let broker = ConfirmationBroker()
        let model = chipWindow(harnesses, confirmations: broker)
        await startTurn(in: placeA, thenShow: placeB, model)
        let proposal = PendingMutation(
            action: "db_run_mutation", params: .object([:]), database: nil, statement: "DELETE FROM t",
            affectsEveryRow: true, origin: .ui, place: placeA)
        let parked = Task { await broker.request(proposal) }

        #expect(await waitUntil { model.waitingPlaces == [placeA] }, "parked")
        #expect(model.chips.map(\.state) == [.working], "\(model.chips)")

        await broker.cancel(id: proposal.id)
        _ = await parked.value
    }

    @Test func aResultOffScreenIsDoneUntilVisited() async throws {
        let harnesses = Harnesses()
        let model = chipWindow(harnesses)
        await startTurn(in: placeA, thenShow: placeB, model)
        let harnessA = try #require(harnesses.in(placeA).first)

        harnessA.emit(.result(isError: false, text: "done A"))

        #expect(await waitUntil { model.chips.first?.state == .done }, "\(model.chips)")
        #expect(model.agents[placeA]?.turnInFlight == false)

        await visit(placeA, in: model)
        await visit(placeB, in: model)

        #expect(model.chips.isEmpty, "seen, and idle: no chip")
    }

    @Test func visitingAPlaceClearsOnlyItsChip() async throws {
        let harnesses = Harnesses()
        let model = chipWindow(harnesses)
        await startTurn(in: placeA, thenShow: placeB, model)
        await startTurn(in: placeC, thenShow: placeB, model)
        try #require(harnesses.in(placeA).first).emit(.result(isError: false, text: "done A"))
        try #require(harnesses.in(placeC).first).emit(.result(isError: false, text: "done C"))
        #expect(await waitUntil { model.chips.map(\.state) == [.done, .done] }, "\(model.chips)")

        await visit(placeA, in: model)
        #expect(model.chips.map(\.place) == [placeC], "A is on screen; C's result is still unseen")
        await visit(placeB, in: model)

        #expect(model.chips.map(\.place) == [placeC])
        #expect(model.chips.first?.state == .done)
    }

    @Test func aFailedSessionOffScreenIsAFailedChip() async throws {
        let harnesses = Harnesses()
        let model = chipWindow(harnesses)
        await startTurn(in: placeA, thenShow: placeB, model)
        await startTurn(in: placeC, thenShow: placeB, model)

        // A's turn ends in an error; C's process goes away mid-turn.
        try #require(harnesses.in(placeA).first).emit(.result(isError: true, text: "overloaded"))
        let harnessC = try #require(harnesses.in(placeC).first)
        await harnessC.stop()

        #expect(await waitUntil { model.chips.map(\.state) == [.failed, .failed] }, "\(model.chips)")
        #expect(model.chips.map(\.place) == [placeA, placeC])

        await visit(placeC, in: model)
        await visit(placeB, in: model)
        #expect(model.chips.map(\.place) == [placeA], "visiting C cleared C's failure, not A's")
    }

    @Test func theScreensOwnAgentHasNoChip() async throws {
        let harnesses = Harnesses()
        let model = chipWindow(harnesses)
        show(placeA, in: model)
        #expect(await model.send("hello A"))
        #expect(model.chips.isEmpty, "working on screen: no chip")

        try #require(harnesses.in(placeA).first).emit(.result(isError: false, text: "done A"))
        #expect(await waitUntil { model.agents[placeA]?.turnInFlight == false })
        show(placeB, in: model)

        #expect(model.chips.isEmpty, "a result seen on screen leaves nothing to show elsewhere")
    }

    @Test func aProductionPlacesChipMarksItsEnvironment() async throws {
        let production = Place(organization: org, project: "api", environment: "production")
        let harnesses = Harnesses()
        let model = chipWindow(harnesses)
        await startTurn(in: production, thenShow: placeA, model)
        await startTurn(in: placeB, thenShow: placeA, model)

        #expect(model.chips.map(\.place) == [production, placeB], "ordered by org, project, environment")
        #expect(model.chips.map(\.productionEnvironment) == [true, false])
        #expect(model.chips.first?.label == "initech · api · production — hello api")
    }

    @Test func goToReachesAPlaceInAnotherOrg() async throws {
        let ctx = FakeContext()
        let model = await goToWindow(ctx)
        await model.refreshContext()
        #expect(model.place == Place(organization: "initech", project: "api", environment: "staging"))

        let target = Place(organization: "globex", project: "shop", environment: "staging")
        await model.goTo(target)

        #expect(model.place == target, "\(model.status)")
        #expect(await ctx.calls == ["set_project:shop", "set_environment:staging"])
    }

    @Test func goToStopsAtTheFirstRefusal() async throws {
        let ctx = FakeContext()
        let model = await goToWindow(ctx)
        await model.refreshContext()
        let start = model.place

        await model.goTo(Place(organization: "initech", project: "nosuch", environment: "production"))

        #expect(model.status.contains("no project nosuch"), "\(model.status)")
        #expect(model.place == start)
        #expect(await ctx.calls == ["set_project:nosuch"], "no environment switch after the refusal")

        await model.goTo(Place(organization: "umbrella", project: "api", environment: "staging"))

        #expect(model.status.contains("umbrella: no such organisation"), "\(model.status)")
        #expect(await ctx.calls == ["set_project:nosuch"], "no project switch after the org refusal")
    }

    // Final review I1: a chip's click passes through places on its way, and only the one it
    // lands on has been seen.

    @Test func goToClearsOnlyThePlaceItLandsOn() async throws {
        let ctx = FakeContext()
        let harnesses = Harnesses()
        let model = await goToWindow(ctx, harnesses: harnesses)
        await model.refreshContext()
        let home = model.place
        // Done agents in globex's remembered place (web · dev) and in globex · shop · staging.
        let webDev = Place(organization: "globex", project: "web", environment: "dev")
        let shopStaging = Place(organization: "globex", project: "shop", environment: "staging")
        try await finishOffScreen(in: [shopStaging, webDev], returningTo: home, model, harnesses)
        // The org switch below lands on web · dev first, globex's remembered place.
        #expect(await ctx.remembered("globex") == "web:dev")

        await model.goTo(shopStaging)

        #expect(model.place == shopStaging, "\(model.status)")
        #expect(model.agents[shopStaging]?.unseenResult == false, "landed on: seen")
        #expect(model.chips.map(\.place) == [webDev], "passed through, never seen")
        #expect(model.chips.first?.state == .done)
    }

    @Test func goToWithinAnOrgLeavesTheEnvironmentItPassedThrough() async throws {
        let ctx = FakeContext()
        let harnesses = Harnesses()
        let model = await goToWindow(ctx, harnesses: harnesses)
        await model.refreshContext()
        let apiStaging = model.place
        let apiProduction = Place(organization: "initech", project: "api", environment: "production")
        let billing = Place(organization: "initech", project: "billing", environment: "staging")
        try await finishOffScreen(in: [apiStaging], returningTo: billing, model, harnesses)

        // billing → api lands on api's first environment, staging, before production.
        await model.goTo(apiProduction)

        #expect(model.place == apiProduction, "\(model.status)")
        #expect(model.chips.map(\.place) == [apiStaging])
        #expect(model.chips.first?.state == .done)
    }

    @Test func aRefusedGoToClearsOnlyWhereItStopped() async throws {
        let ctx = FakeContext()
        let harnesses = Harnesses()
        let model = await goToWindow(ctx, harnesses: harnesses)
        await model.refreshContext()
        let home = model.place
        let webDev = Place(organization: "globex", project: "web", environment: "dev")
        let shopDev = Place(organization: "globex", project: "shop", environment: "dev")
        try await finishOffScreen(in: [shopDev, webDev], returningTo: home, model, harnesses)
        #expect(await ctx.remembered("globex") == "web:dev")

        // Through web · dev to shop · dev, where the environment is refused: the operator stands
        // in shop · dev, which is on screen and so seen; web · dev was only passed through.
        await model.goTo(Place(organization: "globex", project: "shop", environment: "nosuch"))

        #expect(model.status.contains("no environment nosuch"), "\(model.status)")
        #expect(model.place == shopDev)
        #expect(model.agents[shopDev]?.unseenResult == false, "where it stopped is on screen: seen")
        #expect(model.chips.map(\.place) == [webDev])
        #expect(model.chips.first?.state == .done)
    }
}

/// Goes to each of `places`, starts a turn there, comes back to `home` and finishes every turn
/// off screen, so each place's chip is `.done`.
@MainActor
private func finishOffScreen(
    in places: [Place], returningTo home: Place, _ model: WindowModel, _ harnesses: Harnesses
) async throws {
    for place in places {
        await model.goTo(place)
        try #require(model.place == place, "\(model.status)")
        #expect(await model.send("hello \(place.project)"))
    }
    await model.goTo(home)
    try #require(model.place == home, "\(model.status)")
    for place in places {
        try #require(harnesses.in(place).first).emit(.result(isError: false, text: "done"))
    }
    #expect(await waitUntil { model.chips.map(\.state) == places.map { _ in .done } }, "\(model.chips)")
}

// Task 2's controller ruling: the chip's production flag, read off the place's own project.

private let live = Place(organization: org, project: "api", environment: "live")
private let namedProduction = Place(organization: org, project: "api", environment: "production")

/// A `wakil-ctx` pinned to one place, answering `get_context` with the declarations it holds
/// when asked. `holdNext()` parks the next call until `release()`, as a slow read would be.
private actor GatedContext: ToolCaller {
    private let place: Place
    private var declarations: [String: Bool]
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private let fails: Bool
    private(set) var answered = 0
    private(set) var asked = 0

    init(place: Place, declarations: [String: Bool], fails: Bool = false) {
        self.place = place
        self.declarations = declarations
        self.fails = fails
    }

    func holdNext() { holding = true }
    func release() {
        held.forEach { $0.resume() }
        held = []
    }
    var waiting: Int { held.count }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        asked += 1
        struct Unreachable: Error {}
        if fails { throw Unreachable() }
        let answer = Self.context(place, declarations, provider: "test-provider")
        if holding {
            holding = false
            await withCheckedContinuation { held.append($0) }
        }
        answered += 1
        return answer
    }

    static func context(_ place: Place, _ declarations: [String: Bool], provider: String) -> JSONValue {
        let environments = declarations.mapValues { JSONValue.object(["production": .bool($0)]) }
        return .object(["structuredContent": .object([
            "Org": .string(place.organization), "Environment": .string(place.environment),
            "ProjectKey": .string(place.project),
            "Project": .object(["name": .string(place.project), "environments": .object(environments)]),
            "RootPaths": .array([]), "ActiveProvider": .string(provider),
        ])])
    }
}

/// The window's own `wakil-ctx`, on `place` with `declarations`.
private struct WindowContext: ToolCaller {
    let place: Place
    let declarations: [String: Bool]
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        GatedContext.context(place, declarations, provider: "test-provider")
    }
}

@MainActor
private func flagWindow(
    _ harnesses: Harnesses, pinned: GatedContext, context: ContextStore? = nil
) -> WindowModel {
    WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: org,
        harnessFactory: { place, _ in harnesses.make(place) }, context: context,
        placeClients: PlaceClients(start: { _, _ in pinned }, stop: { _ in }))
}

@MainActor
struct AgentChipProductionTests {
    @Test func stateOrdersWaitingFailedWorkingDone() {
        #expect(AgentChip.state(waiting: false, failed: false, working: false, done: false) == nil)
        #expect(AgentChip.state(waiting: true, failed: true, working: true, done: true) == .waiting)
        #expect(AgentChip.state(waiting: false, failed: true, working: true, done: true) == .failed)
        #expect(AgentChip.state(waiting: false, failed: false, working: true, done: true) == .working)
        #expect(AgentChip.state(waiting: false, failed: false, working: false, done: true) == .done)
        #expect(AgentChip.state(waiting: true, failed: false, working: false, done: false) == .waiting)
        #expect(AgentChip.state(waiting: false, failed: true, working: false, done: false) == .failed)
    }

    @Test func anOffScreenPlaceDeclaredProductionIsAProductionChip() async throws {
        let pinned = GatedContext(place: live, declarations: ["live": true])
        let model = flagWindow(Harnesses(), pinned: pinned)
        await startTurn(in: live, thenShow: placeB, model)

        #expect(await waitUntil { model.chips.first?.productionEnvironment == true }, "\(model.chips)")
        #expect(model.chips.map(\.place) == [live])
    }

    @Test func aDeclarationWinsOverTheNameOnceRead() async throws {
        // Decision 26: an environment named production that declares it is not, is not.
        let pinned = GatedContext(place: namedProduction, declarations: ["production": false])
        let model = flagWindow(Harnesses(), pinned: pinned)
        await startTurn(in: namedProduction, thenShow: placeB, model)

        #expect(await waitUntil { model.chips.first?.productionEnvironment == false }, "\(model.chips)")
        #expect(model.chips.map(\.place) == [namedProduction])
    }

    @Test func theNameRuleStandsWhenTheReadFails() async throws {
        let pinned = GatedContext(place: namedProduction, declarations: ["production": false], fails: true)
        let model = flagWindow(Harnesses(), pinned: pinned)
        await startTurn(in: namedProduction, thenShow: placeB, model)

        #expect(await waitUntil { await pinned.asked > 0 })
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.chips.first?.productionEnvironment == true, "unread, the name says production")
    }

    @Test func aChipIsNamedByItsConversationAndOrdinal() {
        let first = AgentChip(place: placeA, state: .working, productionEnvironment: false, conversation: "c1")
        #expect(first.title == "New conversation" && first.ordinal == 1)
        #expect(first.label == "initech · api · staging — New conversation")
        #expect(first.identifier == "window.agentChip.initech/api/staging")
        #expect(first.id == "c1")
        let third = AgentChip(
            place: placeA, state: .done, productionEnvironment: false, conversation: "c3",
            title: "fix the flaky login test", ordinal: 3)
        #expect(third.label == "initech · api · staging — fix the flaky login test")
        #expect(third.identifier == "window.agentChip.initech/api/staging#3")
        #expect(third.id != first.id, "two chips in one place are two rows")
    }

    @Test func aTrayOfTwoOrFewerShowsThemAll() {
        let two = [AgentChip(place: placeA, state: .working, productionEnvironment: false, conversation: "conv-placeA"),
                   AgentChip(place: placeB, state: .done, productionEnvironment: false, conversation: "conv-placeB")]
        let tray = AgentChipTray(two)
        #expect(tray.shown == two)
        #expect(tray.hidden.isEmpty)
        #expect(tray.hiddenState == nil)
        #expect(AgentChipTray([]).shown.isEmpty)
    }

    @Test func aTrayOfMoreThanTwoCollapsesTheRestUnderTheirStrongestState() {
        let placeD = Place(organization: org, project: "docs", environment: "staging")
        let chips = [AgentChip(place: placeA, state: .working, productionEnvironment: false, conversation: "conv-placeA"),
                     AgentChip(place: placeB, state: .done, productionEnvironment: false, conversation: "conv-placeB"),
                     AgentChip(place: placeC, state: .done, productionEnvironment: false, conversation: "conv-placeC"),
                     AgentChip(place: placeD, state: .failed, productionEnvironment: false, conversation: "conv-placeD")]
        let tray = AgentChipTray(chips)
        #expect(tray.shown == Array(chips.prefix(2)))
        #expect(tray.hidden == Array(chips.suffix(2)))
        #expect(tray.hiddenState == .failed)
        #expect(tray.moreLabel == "+2 more")

        let waitingHidden = AgentChipTray(Array(chips.prefix(2)) + [
            AgentChip(place: placeC, state: .working, productionEnvironment: false, conversation: "conv-placeC"),
            AgentChip(place: placeD, state: .waiting, productionEnvironment: false, conversation: "conv-placeD")])
        #expect(waitingHidden.hiddenState == .waiting)
        #expect(AgentChipTray(Array(chips.prefix(3))).hiddenState == .done)
    }

    @Test func anOlderReadLandingLastDoesNotUndoANewerOne() async throws {
        // The chip's read of `live` is slow and says not production; meanwhile the window's own,
        // newer read of the same place says it is.
        let pinned = GatedContext(place: live, declarations: ["live": false])
        await pinned.holdNext()
        let model = flagWindow(
            Harnesses(), pinned: pinned,
            context: ContextStore(client: WindowContext(place: live, declarations: ["live": true])))
        show(live, in: model)
        #expect(await model.send("hello live"))
        #expect(await waitUntil { await pinned.waiting == 1 })

        await model.refreshContext()
        #expect(model.agents[live]?.productionEnvironment == true, "the window's read is the newer")

        await pinned.release()
        #expect(await waitUntil { await pinned.answered == 1 })
        try await Task.sleep(nanoseconds: 50_000_000)
        show(placeB, in: model)

        #expect(model.chips.map(\.place) == [live])
        #expect(model.chips.first?.productionEnvironment == true, "the older read landed last and was dropped")
    }
}

/// A window whose context reads and switches go to `ctx`, and whose org switch moves `ctx`.
@MainActor
private func goToWindow(_ ctx: FakeContext, harnesses: Harnesses? = nil) async -> WindowModel {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("agent-chip-\(UUID().uuidString)"),
        sessionId: "agent-chip")
    let panes = PaneStore()
    let layout = LayoutStore()
    let resumes = ResumeBroker()
    await registerStandardActions(into: registry, context: ctx, panes: panes, db: nil, resumes: resumes)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: ContextStore(client: ctx),
        harnessFactory: { place, _, _ in harnesses?.make(place) }, resumes: resumes, rootPath: "/tmp",
        providerId: "test-provider",
        lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
        orgSwitcher: { org in await ctx.switchOrg(org) },
        environment: "")
    model.setOrganizationForTesting("initech")
    return model
}

/// `wakil-ctx` for two organisations, each with an active project and environment.
private actor FakeContext: ToolCaller {
    private let projects: [String: [String: [String]]] = [
        "initech": ["api": ["staging", "production"], "billing": ["staging"]],
        "globex": ["web": ["dev"], "shop": ["dev", "staging"]],
    ]
    private var active: [String: (project: String, environment: String)] = [
        "initech": ("api", "staging"),
        "globex": ("web", "dev"),
    ]
    private var org = "initech"
    /// Every switch asked of it, as `<tool>:<name>`.
    private(set) var calls: [String] = []

    /// `org`'s active project and environment, as `<project>:<environment>`.
    func remembered(_ org: String) -> String? {
        active[org].map { "\($0.project):\($0.environment)" }
    }

    func switchOrg(_ next: String) -> [String] {
        guard projects[next] != nil else { return ["\(next): no such organisation"] }
        org = next
        return []
    }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        var argument = ""
        if case .object(let fields) = arguments, case .string(let value)? = fields["name"] { argument = value }
        let current = active[org]!
        switch name {
        case "get_context":
            return .object(["structuredContent": .object([
                "Org": .string(org), "Environment": .string(current.environment),
                "Project": .object(["name": .string(current.project)]), "ProjectKey": .string(current.project),
                "RootPaths": .array([]), "ActiveProvider": .string("test-provider"),
            ])])
        case "set_project":
            calls.append("set_project:\(argument)")
            guard let environments = projects[org]?[argument] else { return refusal("no project \(argument)") }
            active[org] = (argument, environments[0])
            return .object([:])
        case "set_environment":
            calls.append("set_environment:\(argument)")
            guard projects[org]?[current.project]?.contains(argument) == true else {
                return refusal("no environment \(argument)")
            }
            active[org] = (current.project, argument)
            return .object([:])
        default:
            return refusal("\(name): not faked")
        }
    }

    private func refusal(_ text: String) -> JSONValue {
        .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }
}
