import Foundation
import Testing

@testable import WakilKit

private let placeA = Place(organization: "org", project: "api", environment: "staging")
private let placeB = Place(organization: "org", project: "billing", environment: "staging")

private func proposal(
    _ id: String = "p1", statement: String = "DELETE FROM t WHERE id=1",
    place: Place = placeA, origin: ActionOrigin = .agent, conversation: String? = "conv"
) -> PendingMutation {
    PendingMutation(
        id: id, action: "db_run_mutation",
        params: .object(["statement": .string(statement)]),
        database: "orders", statement: statement,
        affectsEveryRow: false, origin: origin, place: place, conversation: conversation)
}

@Test func approvingAParkedProposalResolvesTheWaiter() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal()

    async let decision = broker.request(p)
    // Wait for the proposal to actually park before approving it.
    while await broker.current(for: placeA) == nil { await Task.yield() }
    #expect(await broker.current(for: placeA) == p)
    await broker.approve(id: p.id)

    #expect(await decision == .approved)
    #expect(await broker.current(for: placeA) == nil)
}

@Test func cancellingAParkedProposalResolvesTheWaiter() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal()

    async let decision = broker.request(p)
    while await broker.current(for: placeA) == nil { await Task.yield() }
    await broker.cancel(id: p.id)

    #expect(await decision == .cancelled)
    #expect(await broker.current(for: placeA) == nil)
}

// The operator's own proposal still expires: they are at the keyboard, and a plane they walked
// away from should not hold their place's slot for ever.
@Test func anOperatorsParkedProposalExpires() async throws {
    let broker = ConfirmationBroker(timeout: .milliseconds(50))
    #expect(await broker.request(proposal(origin: .ui)) == .expired)
    #expect(await broker.current(for: placeA) == nil)
}

// R1: an agent's proposal waits until the operator answers it (Rule 4: Cancel is how it ends).
// The UI's in the same broker, with the same short timeout, still expires.
@Test func anAgentsProposalWaitsPastTheOldTimeout() async throws {
    let broker = ConfirmationBroker(timeout: .milliseconds(50))
    let agents = proposal("agent", place: placeA)

    async let agentDecision = broker.request(agents)
    #expect(await broker.request(proposal("ui", place: placeB, origin: .ui)) == .expired)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await broker.current(for: placeA) == agents)

    await broker.cancel(id: agents.id)
    #expect(await agentDecision == .cancelled)
}

// One waiting approval per place: a second proposal in the same place is refused immediately
// rather than queued. A queue needs an ordering rule and a story for contradictory
// confirmations, and neither is worth building.
@Test func aSecondProposalInTheSamePlaceIsStillRefused() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let first = proposal("p1")

    async let firstDecision = broker.request(first)
    while await broker.current(for: placeA) == nil { await Task.yield() }

    #expect(await broker.request(proposal("p2")) == .busy)
    // The first is still parked and unaffected.
    #expect(await broker.current(for: placeA) == first)

    await broker.approve(id: first.id)
    #expect(await firstDecision == .approved)
}

// Two places' agents each wait on their own approval; answering one leaves the other parked.
@Test func twoPlacesEachHoldTheirOwnParkedProposal() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let a = proposal("a", place: placeA)
    let b = proposal("b", place: placeB)

    async let aDecision = broker.request(a)
    async let bDecision = broker.request(b)
    while await broker.all().count < 2 { await Task.yield() }
    #expect(await broker.all() == [placeA: a, placeB: b])

    await broker.approve(id: a.id)
    #expect(await aDecision == .approved)
    #expect(await broker.all() == [placeB: b])

    await broker.cancel(id: b.id)
    #expect(await bDecision == .cancelled)
    #expect(await broker.all().isEmpty)
}

// The plane draws the screen's place's proposal only, and a switch shows the other's.
@MainActor
@Test func thePlaneShowsOnlyTheScreensPlace() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot, organization: "org", confirmations: broker)
    func show(_ place: Place) {
        model.seedForTesting(
            providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing",
            thoughts: 0, project: place.project, environment: place.environment)
    }
    show(placeA)
    // The operator's, so each takes its place's own slot: no conversation is on screen here.
    let a = proposal("a", place: placeA, origin: .ui)
    let b = proposal("b", place: placeB, origin: .ui)
    let aTask = Task { await broker.request(a) }
    let bTask = Task { await broker.request(b) }
    while model.waitingPlaces != [placeA, placeB] { await Task.yield() }

    #expect(model.pending == a)
    show(placeB)
    #expect(model.pending == b)

    await model.cancelPending()
    #expect(await bTask.value == .cancelled)
    show(placeA)
    #expect(model.pending == a)
    await broker.cancel(id: a.id)
    #expect(await aTask.value == .cancelled)
}

// A decision naming a proposal that is not the parked one is ignored — a
// stale click on a plane that has already been dismissed must not approve
// whatever happens to be parked next.
@Test func aDecisionForAStaleIdIsIgnored() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal("p1")

    async let decision = broker.request(p)
    while await broker.current(for: placeA) == nil { await Task.yield() }

    await broker.approve(id: "some-other-id")
    #expect(await broker.current(for: placeA) == p)  // still parked

    await broker.approve(id: "p1")
    #expect(await decision == .approved)
}

@Test func updatesPublishParkAndRelease() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let stream = await broker.updates()
    var iterator = stream.makeAsyncIterator()

    let p = proposal()
    async let decision = broker.request(p)

    let parked = await iterator.next()
    #expect(parked == [placeA: p])

    await broker.approve(id: p.id)
    let released = await iterator.next()
    #expect(released == [:])
    _ = await decision
}

@Test func twoConversationsInOnePlaceEachParkTheirOwn() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let a = proposal("a", place: placeA, conversation: "conv-a")
    let b = proposal("b", place: placeA, conversation: "conv-b")
    async let aDecision = broker.request(a)
    async let bDecision = broker.request(b)
    while await broker.allSlots().count < 2 { await Task.yield() }
    #expect(await broker.current(in: ProposalSlot(place: placeA, conversation: "conv-b")) == b)
    await broker.cancelAgentProposal(inConversation: "conv-a")
    #expect(await aDecision == .cancelled)
    #expect(await broker.allSlots() == [b.slot: b])
    await broker.approve(id: b.id)
    #expect(await bDecision == .approved)
}

@Test func theOperatorsProposalKeepsThePlaceSlotBesideAnAgentsInThatPlace() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let agent = proposal("agent", place: placeA, conversation: "conv-a")
    let mine = proposal("mine", place: placeA, origin: .ui, conversation: "conv-a")
    async let agentDecision = broker.request(agent)
    async let mineDecision = broker.request(mine)
    while await broker.allSlots().count < 2 { await Task.yield() }
    #expect(mine.slot == ProposalSlot(place: placeA, conversation: nil))
    #expect(await broker.current(for: placeA) == mine, "the plane's projection shows the operator's")
    await broker.cancelAll()
    _ = await (agentDecision, mineDecision)
}
