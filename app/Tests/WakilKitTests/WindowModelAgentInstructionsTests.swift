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

    /// Review I3: a resumed session keeps the system prompt it was first launched with (the probe),
    /// which may predate the current text — so its first turn carries the text as an update.
    @Test func aResumedSessionsFirstTurnCarriesTheInstructions() async throws {
        let harness = RecordingHarness()
        let (model, box) = window(harness)
        await model.registryForTesting.register(Action(
            name: "session_read", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                .object(["structuredContent": .object([
                    "cwd": .string("/tmp"), "provider": .string("test-provider"), "parent": .string(""),
                    "truncated": .bool(false), "entries": .array([]),
                ])])
            }))
        box.set(org: model.place.organization, project: model.place.project, text: "## Organisation o — general\nB")
        await model.resume(sessionId: "parent-1")
        await model.send("go on")
        #expect(await harness.sentTexts.last == agentInstructionsUpdateHeader + "\n\n## Organisation o — general\nB\n\ngo on")
        await model.send("more")
        #expect(await harness.sentTexts.last == "more")
    }

    @Test func aResumedSessionWithNoInstructionsAddsNothing() async throws {
        let harness = RecordingHarness()
        let (model, _) = window(harness)
        await model.registryForTesting.register(Action(
            name: "session_read", description: "test double", kind: .read,
            schema: .object(["type": .string("object")]),
            handler: { _ in
                .object(["structuredContent": .object([
                    "cwd": .string("/tmp"), "provider": .string("test-provider"), "parent": .string(""),
                    "truncated": .bool(false), "entries": .array([]),
                ])])
            }))
        await model.resume(sessionId: "parent-1")
        await model.send("go on")
        #expect(await harness.sentTexts.last == "go on")
    }

    /// Task 5: a project box saves through its own action, the one field and the project's path.
    @Test func aProjectBoxSavesThroughTheProjectAction() async throws {
        let (model, _) = window(RecordingHarness())
        let sent = SentParams()
        await model.registryForTesting.register(Action(
            name: "ctx_set_project_agent_instructions", description: "stub", kind: .control, audience: .operatorOnly,
            schema: .object([:]),
            handler: { params in await sent.record(params); return .object([:]) }))
        let refusal = await model.saveProjectAgentInstructions(projectPath: "/p/project.json", commits: "Imperative")
        #expect(refusal == nil)
        #expect(await sent.all == [.object(["projectPath": .string("/p/project.json"), "commits": .string("Imperative")])])
    }

    @Test func aRefusedProjectBoxSaysWhy() async throws {
        let (model, _) = window(RecordingHarness())
        await model.registryForTesting.register(Action(
            name: "ctx_set_project_agent_instructions", description: "stub", kind: .control, audience: .operatorOnly,
            schema: .object([:]),
            handler: { _ in throw StandardActionError.missingParam(action: "ctx_set_project_agent_instructions", param: "projectPath") }))
        #expect(await model.saveProjectAgentInstructions(projectPath: "", general: "x") != nil)
    }
}

private actor SentParams {
    var all: [JSONValue] = []
    func record(_ params: JSONValue) { all.append(params) }
}
