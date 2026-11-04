import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 1 (spec, "The agent sees real paths"): the map an agent's instructions carry.

private let copy = Workspace(
    id: "w1", name: "Fix OTP guard order", slug: "fix-otp", project: "api", environment: "staging",
    checkouts: [WorkspaceCheckout(repo: "/p/core", path: "/h/ws/api/fix-otp/core", branch: "fix-otp",
                                  ports: PortBlock(first: 41200, count: 10))])

struct WorkspaceMapTests {
    @Test func aConversationInMainIsGivenMainsFoldersItsNeighboursAndTheProjectsWorkspaces() {
        let text = workspaceMapText(WorkspaceMapInput(
            conversation: "c1", project: "api", environment: "staging", own: nil,
            mainRoots: ["/p/core", "/p/web"], mainBranches: ["/p/core": "main"],
            workspaces: [WorkspaceListing(workspace: copy, holders: ["/p/core": "c3"], live: ["c3": .working])],
            mainLive: ["c1": .working, "c2": .idle],
            titles: ["c1": "me", "c2": "reading logs", "c3": "the guard"]))
        #expect(text == """
        You are in Main of project api (staging): the operator's own folders. You read here and never write; your first change starts a workspace of your own.
        Repos:
        - /p/core — Main's folder on main
        - /p/web — Main's folder
        Other conversations in Main:
        - ‘reading logs’ (idle)
        The project's workspaces (each one's copies are written only by its own conversations):
        - ‘Fix OTP guard order’ (staging): /h/ws/api/fix-otp/core on fix-otp, ports 41200–41209 · ‘the guard’ (working)
        """)
    }

    @Test func aConversationInMainOfAProjectWithNoWorkspacesIsToldSo() {
        let text = workspaceMapText(WorkspaceMapInput(
            conversation: "c1", project: "api", environment: "staging", own: nil, mainRoots: ["/p/core"],
            workspaces: [WorkspaceListing(workspace: Workspace(id: "w9", name: "Other", slug: "o", project: "web",
                                                               environment: "staging"), holders: [:], live: [:])]))
        #expect(text.hasSuffix("No other conversation works in Main.\nThe project has no workspaces yet."))
    }

    @Test func aConversationInAWorkspaceIsGivenItsCopiesAndMainsFolderForTheRest() {
        let text = workspaceMapText(WorkspaceMapInput(
            conversation: "c1", project: "api", environment: "staging",
            own: WorkspaceListing(workspace: copy, holders: ["/p/core": "c1"], live: ["c1": .working, "c2": .waiting]),
            mainRoots: ["/p/core", "/p/web"], titles: ["c2": "frontend"]))
        #expect(text == """
        You are in workspace ‘Fix OTP guard order’ of project api (staging). Your writes land in its copies; a repo with no copy yet gets one at your first change there.
        Repos:
        - /h/ws/api/fix-otp/core — copy of /p/core on fix-otp, ports 41200–41209, held by you
        - /p/web — Main's folder (no copy yet)
        Other conversations in this workspace:
        - ‘frontend’ (waiting)
        """)
    }
}

@MainActor
struct WindowModelWorkspaceMapTests {
    private func window(_ harness: RecordingHarness) async -> WindowModel {
        let model = WindowModel.forTesting(scratchRoot: testScratchRoot, harnessFactory: { _, _ in harness })
        model.agentInstructionsBox = AgentInstructionsBox()
        model.seedForTesting(providerId: "test-provider", rootPath: "/tmp/wakil-window-model-for-testing", thoughts: 0,
                             project: "api", environment: "staging")
        let store = WorkspaceStore()
        await store.use(load: { WorkspacesFile() }, save: { _ in })
        await store.ensure(org: model.place.organization)
        model.useWorkspaces(WorkspaceRouter(store: store, git: nil))
        return model
    }

    /// A conversation in Main gets the map on its first turn, after its words, and not again
    /// while nothing in it changed.
    @Test func aMainConversationsFirstTurnCarriesTheMapOnce() async throws {
        let harness = RecordingHarness()
        let model = await window(harness)
        await model.send("hi")
        let first = try #require(await harness.sentTexts.first)
        #expect(first.hasPrefix("hi\n\n" + workspaceMapHeader + "\nYou are in Main of project \(model.place.project)"))
        await model.send("again")
        #expect(await harness.sentTexts.last == "again")
    }

    /// Moved into a workspace, its next turn carries the new map.
    @Test func aConversationMovedIntoAWorkspaceIsSentItsNewMap() async throws {
        let harness = RecordingHarness()
        let model = await window(harness)
        await model.send("hi")
        let agent = try #require(model.currentAgent)
        agent.workspace = Workspace(id: "w1", name: "Fix OTP guard order", slug: "fix-otp",
                                    project: model.place.project, environment: model.place.environment)
        await model.send("go on")
        let sent = try #require(await harness.sentTexts.last)
        #expect(sent.hasPrefix("go on\n\n" + workspaceMapHeader + "\nYou are in workspace ‘Fix OTP guard order’"))
    }
}
