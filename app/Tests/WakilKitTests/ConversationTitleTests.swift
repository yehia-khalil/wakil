import Foundation
import Testing

@testable import WakilKit

@Test(arguments: [
    ("fix the flaky login test", "fix the flaky login test"),
    ("  fix\nthe   flaky\tlogin test ", "fix the flaky login test"),
    ("please look at why the staging deploy keeps failing on the migration step",
     "please look at why the … on the migration step"),
    (String(repeating: "x", count: 60), String(repeating: "x", count: 47) + "…"),
    // No whole word fits the tail: the 47-and-"…" form, never a head and an empty tail.
    ("fix the flaky login test " + String(repeating: "x", count: 30),
     "fix the flaky login test " + String(repeating: "x", count: 22) + "…"),
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
        "state": .string("working"), "onScreen": .bool(true), "handed": .bool(false), "titleSource": .string("message"),
        "workspace": .string("main"),
    ]))
}

@Test func theOperatorsNameWinsThenTheModelsThenTheMessage() {
    #expect(conversationDisplayTitle(operatorName: "Mine", aiName: "Model", messageTitle: "fix it").title == "Mine")
    #expect(conversationDisplayTitle(operatorName: "Mine", aiName: "Model", messageTitle: "fix it").source == .operator_)
    #expect(conversationDisplayTitle(operatorName: nil, aiName: "Model", messageTitle: "fix it") == ("Model", .ai))
    #expect(conversationDisplayTitle(operatorName: nil, aiName: nil, messageTitle: "fix it") == ("fix it", .message))
    #expect(conversationDisplayTitle(operatorName: nil, aiName: nil, messageTitle: newConversationTitle).source == .none)
}

@Test(arguments: [("  a\n b\t c ", "a b c"), ("   ", nil), ("\n", nil), ("Fix C++ 2c-ii", "Fix C++ 2c-ii")] as [(String, String?)])
func aNameIsCleanedNotCut(_ raw: String, _ clean: String?) { #expect(cleanConversationName(raw) == clean) }

@Test @MainActor func theFirstSendSetsTheMessageTitleAndFirstMessageOnce() {
    let agent = PlaceAgent(
        id: "c1", place: Place(organization: "o", project: "p", environment: "e"),
        providerId: "main", mirror: TerminalMirrorFeed(panes: PaneStore(kinds: PaneKinds.standard), layout: LayoutStore()))
    #expect(agent.firstMessage == nil)
    #expect(agent.titleSource == .none)
    agent.noteSend("first")
    agent.noteSend("second")
    #expect(agent.firstMessage == "first")
    #expect(agent.title == "first")
    #expect(agent.titleSource == .message)
    agent.aiName = "Model"
    #expect(agent.title == "Model")
    agent.operatorName = "Mine"
    #expect(agent.title == "Mine")
    #expect(agent.titleSource == .operator_)
}

@Test func aLiveConversationsJSONCarriesItsTitleSource() {
    let live = LiveConversation(
        id: "c1", session: nil, place: Place(organization: "o", project: "p", environment: "e"),
        title: "t", titleSource: .ai, state: .working, onScreen: true, lastActivity: Date())
    guard case .object(let o) = live.json else { Issue.record("not an object"); return }
    #expect(o["titleSource"] == .string("ai"))
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
