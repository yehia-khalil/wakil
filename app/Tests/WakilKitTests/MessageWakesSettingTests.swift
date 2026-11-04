import Foundation
import Testing
@testable import WakilKit

// Workspaces piece 4 (decision 16): Agents woken by messages — an organisation setting with a
// project override, 8 by default, 0 never wakes.

private actor WakesRecordingCaller: ToolCaller {
    private(set) var arguments: [JSONValue] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        self.arguments.append(arguments)
        return .object(["structuredContent": .object([:])])
    }
}

@Test func theMessageWakesSettingIsForwardedAsANumber() async throws {
    let caller = WakesRecordingCaller()
    let registry = ActionRegistry(
        journalDirectory: testScratchRoot.appendingPathComponent(UUID().uuidString), sessionId: "message-wakes")
    await registerStandardActions(into: registry, context: caller, panes: PaneStore(), db: nil, resumes: ResumeBroker())
    _ = try await registry.dispatch(
        name: "ctx_update_org", params: .object(["id": .string("o"), "messageWakes": .integer(3)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "ctx_set_project_agent_instructions",
        params: .object(["projectPath": .string("/p/project.json"), "messageWakes": .integer(-1)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    // A string is not a number: dropped, as a mistyped switch is.
    _ = try await registry.dispatch(
        name: "ctx_update_org", params: .object(["id": .string("o"), "messageWakes": .string("3")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await caller.arguments == [
        .object(["id": .string("o"), "messageWakes": .integer(3)]),
        .object(["projectPath": .string("/p/project.json"), "messageWakes": .integer(-1)]),
        .object(["id": .string("o")]),
    ])
}

@Test func theMessageWakesSettingIsReadAtBothLevels() throws {
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(#"{"id":"o","messageWakes":0}"#.utf8))
    #expect(org.messageWakes == 0)
    let unread = try JSONDecoder().decode(SettingsOrg.self, from: Data(#"{"id":"o"}"#.utf8))
    #expect(unread.messageWakes == defaultMessageWakes && defaultMessageWakes == 8)
    let project = try JSONDecoder().decode(
        SettingsProject.self, from: Data(#"{"name":"api","agent":{"messageWakes":3}}"#.utf8))
    #expect(project.agent.messageWakes == 3)
    let inherits = try JSONDecoder().decode(SettingsProject.self, from: Data(#"{"name":"api","agent":{}}"#.utf8))
    #expect(inherits.agent.messageWakes == nil)
}

@Test func theProjectOverridesTheOrganisationWhichOverridesTheDefault() {
    let tree = SettingsTree(
        org: SettingsOrg(id: "initech", messageWakes: 5),
        projects: [
            SettingsProject(name: "api", agent: SettingsAgentTexts(messageWakes: 2)),
            SettingsProject(name: "web"),
        ])
    #expect(messageWakesSetting(in: tree, project: "api") == 2)
    #expect(messageWakesSetting(in: tree, project: "web") == 5)
    #expect(messageWakesSetting(in: tree, project: "gone") == 5)
    #expect(messageWakesSetting(in: nil, project: "api") == 8)
}
