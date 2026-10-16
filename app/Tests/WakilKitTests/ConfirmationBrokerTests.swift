import Foundation
import Testing

@testable import WakilKit

private func proposal(_ id: String = "p1", statement: String = "DELETE FROM t WHERE id=1")
    -> PendingMutation
{
    PendingMutation(
        id: id, action: "db_run_mutation",
        params: .object(["statement": .string(statement)]),
        database: "orders", statement: statement,
        affectsEveryRow: false, origin: .agent)
}

@Test func approvingAParkedProposalResolvesTheWaiter() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal()

    async let decision = broker.request(p)
    // Wait for the proposal to actually park before approving it.
    while await broker.current() == nil { await Task.yield() }
    #expect(await broker.current() == p)
    await broker.approve(id: p.id)

    #expect(await decision == .approved)
    #expect(await broker.current() == nil)
}

@Test func cancellingAParkedProposalResolvesTheWaiter() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal()

    async let decision = broker.request(p)
    while await broker.current() == nil { await Task.yield() }
    await broker.cancel(id: p.id)

    #expect(await decision == .cancelled)
    #expect(await broker.current() == nil)
}

@Test func aParkedProposalExpires() async throws {
    let broker = ConfirmationBroker(timeout: .milliseconds(50))
    #expect(await broker.request(proposal()) == .expired)
    #expect(await broker.current() == nil)
}

// Single-flight: a second proposal arriving while one is parked is refused
// immediately rather than queued. A queue needs an ordering rule and a
// story for contradictory confirmations, and neither is worth building
// before anyone has confirmed one mutation.
@Test func aSecondProposalIsRefusedWhileOneIsPending() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let first = proposal("p1")

    async let firstDecision = broker.request(first)
    while await broker.current() == nil { await Task.yield() }

    #expect(await broker.request(proposal("p2")) == .busy)
    // The first is still parked and unaffected.
    #expect(await broker.current() == first)

    await broker.approve(id: first.id)
    #expect(await firstDecision == .approved)
}

// A decision naming a proposal that is not the parked one is ignored — a
// stale click on a plane that has already been dismissed must not approve
// whatever happens to be parked next.
@Test func aDecisionForAStaleIdIsIgnored() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal("p1")

    async let decision = broker.request(p)
    while await broker.current() == nil { await Task.yield() }

    await broker.approve(id: "some-other-id")
    #expect(await broker.current() == p)  // still parked

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
    #expect(parked ?? nil == p)

    await broker.approve(id: p.id)
    let released = await iterator.next()
    #expect(released ?? nil == nil)
    _ = await decision
}
