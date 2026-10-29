import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 3: ⌘P's Running grouped by workspace (decision 27).

private let staging = Place(organization: "initech", project: "estate", environment: "staging")
private let prod = Place(organization: "initech", project: "estate", environment: "production")

private func live(_ id: String, _ title: String, place: Place = staging, workspace: (String, String)? = nil,
                  production: Bool = false) -> LiveConversation {
    var c = LiveConversation(id: id, session: id, place: place, title: title, state: .idle, onScreen: false,
                             lastActivity: Date(), isProduction: production)
    c.workspace = workspace.map { (id: $0.0, name: $0.1) }
    return c
}

@Test func runningIsGroupedByWorkspaceMainIncludedEachWorkspaceARow() async {
    let source = RunningConversationsSource(
        conversations: {
            [live("c1", "backend", workspace: ("w1", "Login rate limit")), live("c2", "asking"),
             live("c3", "frontend", workspace: ("w1", "Login rate limit"))]
        },
        workspaces: {
            [RunningWorkspace(id: "w1", name: "Login rate limit", place: staging),
             RunningWorkspace(id: "w2", name: "Quiet one", place: staging)]
        },
        main: staging)
    let rows = await source.entries()
    #expect(rows.map(\.id) == [
        "workspace:main:initech/estate/staging", "running:c2",
        "workspace:w1", "running:c1", "running:c3",
        "workspace:w2",
    ])
    #expect(rows[0].title == "Main" && rows[0].subtitle == "initech · estate · staging · your folders")
    #expect(rows[0].action == .dispatch(action: "workspace_open", params: .object([
        "workspace": .string("main"), "project": .string("estate"), "environment": .string("staging"),
    ])))
    #expect(rows[2].action == .dispatch(action: "workspace_open", params: .object(["workspace": .string("w1")])))
    #expect(rows[2].kindLabel == "workspace" && rows[2].verb == "open")
}

@Test func mainOfAnotherPlaceIsARowWhileAConversationIsInItAndProductionStaysRed() async {
    let source = RunningConversationsSource(
        conversations: { [live("c1", "hotfix question", place: prod, production: true)] },
        workspaces: { [RunningWorkspace(id: "w9", name: "Prod fix", place: prod, isProduction: true)] },
        main: staging)
    let rows = await source.entries()
    #expect(rows.map(\.id) == ["workspace:main:initech/estate/staging", "workspace:main:initech/estate/production",
                               "running:c1", "workspace:w9"])
    #expect(rows.map(\.isProduction) == [false, true, true, true])
}

@Test func withoutWorkspacesTheRowsAreAsBefore() async {
    let rows = await RunningConversationsSource(conversations: { [live("c1", "a")] }).entries()
    #expect(rows.map(\.id) == ["running:c1"])
}
