import Foundation
import Testing
@testable import WakilKit

/// 3a-iii-b, Task 4 (amended by the probe): a live agent whose instructions changed receives them in
/// its next turn, ahead of the operator's words; the process is not restarted.
@Suite @MainActor struct WindowModelAgentInstructionsTests {
    private func window(_ harness: RecordingHarness) -> (WindowModel, AgentInstructionsBox) {
        let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
        let box = AgentInstructionsBox()
        model.agentInstructionsBox = box
        return (model, box)
    }

    @Test func theFirstTurnCarriesNothingTheLaunchHasTheText() async throws {
        let harness = RecordingHarness()
        let (model, box) = window(harness)
        box.set(org: model.place.organization, project: model.place.project, text: "## Organisation o — general\nA")
        await model.send("hi")
        #expect(await harness.sentTexts == ["hi"])
    }

    @Test func aSaveDeliversTheNewTextInTheNextTurn() async throws {
        let harness = RecordingHarness()
        let (model, box) = window(harness)
        box.set(org: model.place.organization, project: model.place.project, text: "A")
        await model.send("hi")
        box.set(org: model.place.organization, project: model.place.project, text: "## Organisation o — general\nB")
        await model.send("again")
        let sent = try #require(await harness.sentTexts.last)
        #expect(sent == agentInstructionsUpdateHeader + "\n\n## Organisation o — general\nB\n\nagain")
        #expect(model.thoughts.contains { $0.detail == "Instructions updated — the agent has the new ones from this turn." })
        #expect(model.thoughts.contains { $0.label == "you" && $0.detail == "again" })
    }

    @Test func anUnchangedTextAddsNothing() async throws {
        let harness = RecordingHarness()
        let (model, box) = window(harness)
        box.set(org: model.place.organization, project: model.place.project, text: "A")
        await model.send("one")
        await model.send("two")
        #expect(await harness.sentTexts == ["one", "two"])
    }

    @Test func clearedInstructionsSaySo() async throws {
        let harness = RecordingHarness()
        let (model, box) = window(harness)
        box.set(org: model.place.organization, project: model.place.project, text: "A")
        await model.send("one")
        box.set(org: model.place.organization, project: model.place.project, text: "")
        await model.send("two")
        #expect(await harness.sentTexts.last == agentInstructionsUpdateHeader + "\n\n(The operator removed their instructions.)\n\ntwo")
    }
}
