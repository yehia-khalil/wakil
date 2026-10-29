import Testing
import Foundation
@testable import WakilKit

// After merging main into the Ticket view: the words the plane shows for a call the agent parks.
// One order — the action's own proposal, else its own describe, else Wakil's confirmationDescription,
// else the caller's `statement` (SQL, an HTTP request) — pinned per kind of action.

private let noProps = JSONValue.object(["type": .string("object"), "properties": .object([:])])

/// Parks `name` with `arguments` through `handle`, returns what the plane was asked, then approves.
private func parkedStatement(_ action: Action, arguments: [String: JSONValue]) async -> PendingMutation? {
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent("wakil-test-\(UUID().uuidString)"),
        sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    await registry.register(action)
    let surface = MCPSurface(registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: broker)
    let call = JSONRPCMessage(id: .number(1), method: "tools/call", params: .object([
        "name": .string(action.name), "arguments": .object(arguments),
    ]))
    async let reply = handle(call, surface: surface, caller: { .test("staging", conversation: "c1") })
    var spins = 0
    while await broker.all().isEmpty, spins < 5_000 { await Task.yield(); spins += 1 }
    let parked = await broker.all().values.first
    if let parked { await broker.approve(id: parked.id) }
    _ = await reply
    return parked
}

@Test func aBrowserActParksWithItsOwnProposalNotAStrayStatement() async {
    let parked = await parkedStatement(Action(
        name: "browser_act", description: "t", kind: .mutate, schema: noProps,
        handler: { _ in .object([:]) }, price: (.allow, .allow), agentPrice: .gate,
        proposal: { _ in ActionProposal(statement: "click “Pay now” on shop.test", ask: .change) }),
        arguments: ["statement": .string("something else entirely")])
    #expect(parked?.statement == "click “Pay now” on shop.test")
}

@Test func aDatabaseMutationParksWithItsSQL() async {
    let parked = await parkedStatement(Action(
        name: "db_run_mutation", description: "t", kind: .mutate, schema: noProps,
        handler: { _ in .object([:]) }),
        arguments: ["statement": .string("DELETE FROM t WHERE id=1")])
    #expect(parked?.statement == "DELETE FROM t WHERE id=1")
    #expect(parked?.affectsEveryRow == false)
}

@Test func anEveryRowSQLMutationIsStillFlagged() async {
    let parked = await parkedStatement(Action(
        name: "db_run_mutation", description: "t", kind: .mutate, schema: noProps,
        handler: { _ in .object([:]) }),
        arguments: ["statement": .string("DELETE FROM t")])
    #expect(parked?.statement == "DELETE FROM t")
    #expect(parked?.affectsEveryRow == true)
}

@Test func anHTTPSendParksWithItsRequest() async {
    let parked = await parkedStatement(Action(
        name: "http_send", description: "t", kind: .mutate, schema: noProps,
        handler: { _ in .object([:]) }),
        arguments: ["statement": .string("POST https://api.test/orders")])
    #expect(parked?.statement == "POST https://api.test/orders")
}

@Test func aTicketReplyParksWithTheWordsItPostsDespiteAStrayStatement() async {
    let parked = await parkedStatement(Action(
        name: "review_reply_send", description: "t", kind: .mutate, schema: noProps,
        handler: { _ in .object([:]) }, price: (.gate, .gate),
        describe: { params in
            guard case .object(let o) = params, case .string(let body)? = o["body"] else { return "" }
            return reviewReplyStatement(repo: "github.com/initech/api", pr: 7, path: "a.swift", line: 3, body: body)
        }),
        arguments: ["body": .string("Fixed in the next commit."), "statement": .string("DROP TABLE users")])
    #expect(parked?.statement == "Reply on initech/api#7 · a.swift:3\n\nFixed in the next commit.")
    #expect(parked?.affectsEveryRow == false)
}

@Test func aConfirmationDescriptionActionParksWithItsSentenceDespiteAStrayStatement() async {
    let parked = await parkedStatement(Action(
        name: "editor_changes_branch_delete", description: "t", kind: .mutate, schema: noProps,
        handler: { _ in .object([:]) }, price: (.allow, .allow), agentPrice: .gate),
        arguments: ["root": .string("/p/api"), "branch": .string("fix-login"), "statement": .string("rm -rf /")])
    #expect(parked?.statement == "delete branch fix-login in api")
}
