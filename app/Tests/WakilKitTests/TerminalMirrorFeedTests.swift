import Foundation
import Testing
@testable import WakilKit

@MainActor
private func makeFeed() -> TerminalMirrorFeed {
    let panes = PaneStore()
    let layout = LayoutStore()
    return TerminalMirrorFeed(panes: panes, layout: layout)
}

private let bash = HarnessEvent.toolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")]))
private let bashResult = HarnessEvent.toolResult(id: "t1", content: .string("a\nb"), isError: false)

@MainActor
@Test func onlyTheAgentsBashCallsAndTheirResultsAreRetained() {
    let feed = makeFeed()
    feed.retain(.toolUse(id: "r1", name: "Read", input: .object([:])), at: Date())
    feed.retain(.toolResult(id: "r1", content: .string("x"), isError: false), at: Date())
    feed.retain(bash, at: Date())
    feed.retain(bashResult, at: Date())
    #expect(feed.events.map(\.event) == [bash, bashResult])
}

@MainActor
@Test func retainedEventsAreCappedAtTwiceTheHistory() {
    let feed = makeFeed()
    for n in 0..<(TerminalBlock.historyCap * 2 + 5) {
        feed.retain(.toolUse(id: "t\(n)", name: "Bash", input: .object([:])), at: Date())
    }
    #expect(feed.events.count == TerminalBlock.historyCap * 2)
}

@MainActor
@Test func anOrgSwitchKeepsEachAgentsCommandsInItsOwnPlace() async {
    // Each place's agent has its own mirror (background agents 3 of 4), and a switch drops none:
    // a terminal opened in the incoming org backfills with nothing of the outgoing org's agent,
    // and one opened back in the outgoing org still backfills with its commands.
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    await model.receiveForTesting(bash)
    #expect(model.mirrorEventsForTesting.map(\.event) == [bash])

    await model.setOrganization("beta")
    #expect(model.mirrorEventsForTesting.isEmpty, "beta's agent ran nothing")

    await model.setOrganization("alpha")
    #expect(model.mirrorEventsForTesting.map(\.event) == [bash], "alpha's agent's commands are still its own")
}
