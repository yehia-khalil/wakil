import Foundation
import Observation
import Testing
@testable import WakilKit

/// A pane's update redraws only that pane (pluggable pane kinds, PR 7) — the 240.5 ms/frame
/// regression `refreshTerminal`'s doc comment records must not come back.
@MainActor
@Test func aTerminalTickInvalidatesOnlyItsOwnPane() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    // A terminal pane in the store; the first refresh adds its cell (a pane opening may redraw).
    await model.panesForTesting.setTerminalProposal(paneId: "t1", nil)
    await model.refreshTerminal(pane: "t1")
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    withObservationTracking {
        _ = model.api("a1")
        _ = model.editor("e1")
    } onChange: { flag.fired = true }
    // Every later tick must touch only t1's own cell.
    await model.refreshTerminal(pane: "t1")
    #expect(!flag.fired)
    #expect(model.terminal("t1") != nil)
}

/// The watched pane has a real cell: a tick on t1 that also wrote t2's existing cell would fire.
@MainActor
@Test func aTerminalTickDoesNotInvalidateAnotherPanesExistingCell() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    await model.panesForTesting.setTerminalProposal(paneId: "t1", nil)
    await model.panesForTesting.setTerminalProposal(paneId: "t2", nil)
    await model.refreshTerminal(pane: "t1")
    await model.refreshTerminal(pane: "t2")
    #expect(model.terminal("t2") != nil)
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    withObservationTracking {
        _ = model.terminal("t2")
    } onChange: { flag.fired = true }
    await model.refreshTerminal(pane: "t1")
    #expect(!flag.fired)
}
