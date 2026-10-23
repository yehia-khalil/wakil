import Foundation
import Testing

@testable import WakilKit

@Test(arguments: [
    ("fix the flaky login test", "fix the flaky login test"),
    ("  fix\nthe   flaky\tlogin test ", "fix the flaky login test"),
    ("please look at why the staging deploy keeps failing on the migration step",
     "please look at why the … on the migration step"),
    (String(repeating: "x", count: 60), String(repeating: "x", count: 47) + "…"),
    ("", "New conversation"),
])
func theTitleIsTheFirstMessageCutTo48(_ message: String, _ title: String) {
    #expect(conversationTitle(message) == title)
    #expect(conversationTitle(message).count <= 48)
}

@Test func stateTakesTheChipsPrecedenceAndIdleOtherwise() {
    #expect(ConversationState.of(waiting: true, failed: true, working: true, done: true) == .waiting)
    #expect(ConversationState.of(waiting: false, failed: true, working: true, done: true) == .failed)
    #expect(ConversationState.of(waiting: false, failed: false, working: true, done: true) == .working)
    #expect(ConversationState.of(waiting: false, failed: false, working: false, done: true) == .done)
    #expect(ConversationState.of(waiting: false, failed: false, working: false, done: false) == .idle)
}

@Test func aLiveConversationReadsAsItsJSON() {
    let live = LiveConversation(
        id: "c1", session: nil, place: Place(organization: "o", project: "p", environment: "e"),
        title: "t", state: .working, onScreen: true, lastActivity: Date())
    #expect(live.json == .object([
        "conversation": .string("c1"), "session": .null, "organization": .string("o"),
        "project": .string("p"), "environment": .string("e"), "title": .string("t"),
        "state": .string("working"), "onScreen": .bool(true),
    ]))
}

@MainActor
@Test func aConversationRecordsEverySessionItRanAndItsParent() {
    let agent = PlaceAgent(
        id: "c", place: Place(organization: "o", project: "p", environment: "e"),
        providerId: "main", mirror: TerminalMirrorFeed(panes: PaneStore(kinds: PaneKinds.standard), layout: LayoutStore()))
    #expect(agent.title == newConversationTitle)
    agent.assignedSessionId = "a"
    agent.sessionId = "b"
    #expect(agent.sessionIds == ["a", "b"])
}
