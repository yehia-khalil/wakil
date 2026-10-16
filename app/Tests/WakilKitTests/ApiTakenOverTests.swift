import Foundation
import Testing
@testable import WakilKit

/// Task 9 fix round 2: Format, the one gesture that writes the field the cursor is in over its
/// held text, takes that field over (Amendment 10: `+ hole` and a token's remove are edits in the
/// field's own editor). The field never writes its text back over Format, and it is let go once
/// that write lands, so the screen shows what was written.

private let box = ApiFieldRow(.body)
private let typed = "{\"a\":1,\n\"b\":2}"
private let formattedText = "{\n  \"a\": 1,\n  \"b\": 2\n}"

/// A gesture's hold on the box, by the token of the dispatch that carried it.
private func hold(_ text: String, token: Int = 1) -> ApiHeldTakeover {
    ApiHeldTakeover(held: [.literal(text)], token: token)
}

private func req(body: [ApiPart]) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: "POST", origin: "https://httpbin.org", path: [], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: body)
}

@Test("Format over the focused body: its old text is never written back, and it goes when Format lands")
func formatTakesTheFocusedBoxOver() {
    // The typed text's own write landed: the box is let go, focused or not (round 5), so a
    // Format pressed after it has no box to take over.
    let landedTyped = req(body: [.literal(typed)])
    #expect(apiHeldAfterLanding(landedTyped, held: [box: [.literal(typed)]], focused: box).isEmpty)
    // Format pressed before that write landed: the box still holds the typed text.
    let boxes: ApiHeld = [box: [.literal(typed)]]
    // Format is pressed: its write carries the box, which it takes over.
    let takenOver = [box: hold(typed)]
    let formatted = req(body: [.literal(formattedText)])
    // The focus-out flush (or a pause) never writes the box's old text over the format…
    #expect(apiFlush(formatted, held: boxes, pane: "p", takenOver: takenOver).writes.isEmpty)
    // …and Format's dispatch landing lets the box go, so it shows the format.
    let settled = apiGestureSettled(
        takenOver: takenOver, held: boxes, carried: takenOver, landed: true)
    #expect(settled.held.isEmpty)
    #expect(settled.takenOver.isEmpty)
}

@Test("A refused gesture leaves its box owing its write")
func aRefusedGestureLeavesTheBoxOwing() {
    // Typed and not yet flushed: the gesture carried the only copy of the text.
    let draft = req(body: [.literal("{\"a\":1,")])
    let boxes: ApiHeld = [box: [.literal(typed)]]
    let takenOver = [box: hold(typed)]
    #expect(apiFlush(draft, held: boxes, pane: "p", takenOver: takenOver).writes.isEmpty)
    let settled = apiGestureSettled(
        takenOver: takenOver, held: boxes, carried: takenOver, landed: false)
    #expect(settled.takenOver.isEmpty)
    #expect(settled.held == boxes)
    #expect(apiFlush(draft, held: settled.held, pane: "p", takenOver: settled.takenOver)
        .writes.count == 1)
    #expect(apiHeldAfterLanding(draft, held: settled.held, focused: nil,
                                 takenOver: settled.takenOver) == boxes)
}

@Test("Final review 4: a refused gesture whose box survives owes a pause, so the box is written")
func aRefusedGestureRestartsThePause() {
    let boxes: ApiHeld = [box: [.literal(typed)]]
    let takenOver = [box: hold(typed)]
    // Refused: the box survives owing its write, and nothing else would ever flush it.
    #expect(apiGestureSettled(
        takenOver: takenOver, held: boxes, carried: takenOver, landed: false).owed)
    // Landed: the box is let go, and nothing is owed.
    #expect(!apiGestureSettled(
        takenOver: takenOver, held: boxes, carried: takenOver, landed: true).owed)
    // Refused, but the box is already gone (Escape): nothing is owed.
    #expect(!apiGestureSettled(
        takenOver: takenOver, held: [:], carried: takenOver, landed: false).owed)
    // Refused, but a later gesture holds the box: that gesture's outcome settles it.
    #expect(!apiGestureSettled(
        takenOver: [box: hold(typed, token: 2)], held: boxes, carried: takenOver, landed: false)
        .owed)
}

@Test("Only what a dispatch carried is settled: a later gesture on the box stays in flight")
func onlyWhatADispatchCarriedIsSettled() {
    let takenOver = [box: hold(typed + "x", token: 2)]
    let boxes: ApiHeld = [box: [.literal(typed + "x")]]
    let settled = apiGestureSettled(
        takenOver: takenOver, held: boxes, carried: [box: hold(typed)], landed: true)
    #expect(settled.takenOver == takenOver)
    #expect(settled.held == boxes)
}

@Test("An unrelated landing while a gesture is in flight keeps the taken-over box")
func anUnrelatedLandingKeepsTheBox() {
    let takenOver = [box: hold(typed)]
    let boxes: ApiHeld = [box: [.literal(typed)]]
    // Some other write lands first; the draft does not hold the typed text yet.
    let unrelated = ApiRequestSnapshot(
        method: "PUT", origin: "https://httpbin.org", path: [], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [.literal("{\"a\":1,")])
    #expect(apiHeldAfterLanding(unrelated, held: boxes, focused: nil, takenOver: takenOver)
        == boxes)
    #expect(apiHeldAfterLanding(unrelated, held: boxes, focused: box, takenOver: takenOver)
        == boxes)
}

@Test("Send and a gesture's sequence never flush a taken-over box")
func sendAndSequencesSkipTakenOverBoxes() {
    let draft = req(body: [.literal("{\"a\":1,")])
    let boxes: ApiHeld = [box: [.literal(typed)]]
    let takenOver = [box: hold(typed)]
    let plan = apiSendPlan(draft: draft, pane: "p", held: boxes, takenOver: takenOver)
    #expect(!plan.calls.contains { $0.0 == "api_set_request" })
    #expect(plan.written.isEmpty)
    #expect(apiSendPlan(draft: draft, pane: "p", held: boxes).calls
        .contains { $0.0 == "api_set_request" })
    // A gesture's batch is the flush (`apiFlush`, as `operateFlushed` builds it) and then its
    // own calls: the flush writes nothing for the taken-over box.
    #expect(apiFlush(draft, held: boxes, pane: "p", takenOver: takenOver).writes.isEmpty)
}

@Test("Typed past a gesture, the box is the operator's again and owes its write")
func typedPastAGestureOwesItsWrite() {
    let takenOver = [box: hold(typed)]
    let formatted = req(body: [.literal(formattedText)])
    let boxes: ApiHeld = [box: [.literal(typed + "x")]]
    #expect(apiHeldAfterLanding(formatted, held: boxes, focused: box, takenOver: takenOver)
        == boxes)
    #expect(apiFlush(formatted, held: boxes, pane: "p", takenOver: takenOver).writes.count == 1)
}

@Test("A box nobody took over is unchanged: kept while focused, written while owed")
func anUntakenBoxIsUnchanged() {
    let formatted = req(body: [.literal(formattedText)])
    let boxes: ApiHeld = [box: [.literal(typed)]]
    #expect(apiHeldAfterLanding(formatted, held: boxes, focused: box) == boxes)
    #expect(apiFlush(formatted, held: boxes, pane: "p").writes.count == 1)
}

@Test("A taken-over entry is spent once its box is let go or typed past")
func takenOverSettles() {
    let takenOver = [box: hold(typed)]
    #expect(apiTakenOverSettled(takenOver, held: [:]).isEmpty)
    #expect(apiTakenOverSettled(takenOver, held: [box: [.literal(typed + "x")]]).isEmpty)
    #expect(apiTakenOverSettled(takenOver, held: [box: [.literal(typed)]]) == takenOver)
}

@Test("Escape after re-entry restores what the field held at the most recent focus-in")
func escapeRestoresTheMostRecentFocusIn() {
    let before = req(body: [.literal(typed)])
    let formatted = req(body: [.literal(formattedText)])
    var tracker = ApiFocusTracker()
    _ = tracker.took(box, identifier: "api.body", request: before)
    _ = tracker.lost(identifier: "api.body")
    _ = tracker.took(ApiFieldRow(.path), identifier: "api.path", request: formatted)
    _ = tracker.lost(identifier: "api.path")
    _ = tracker.took(box, identifier: "api.body", request: formatted)
    let focused = try! #require(tracker.focused)
    let current = req(body: [.literal(formattedText + "x")])
    #expect(apiRestoreWrite(focused, current: current, pane: "p")
        == .object(["pane": .string("p"), "body": .array([.object(["literal": .string(formattedText)])])]))
}

@Test("Round 4: two gestures carrying the same text — the first one's refusal does not settle the second's hold")
func aRefusedGestureDoesNotSettleALaterOneCarryingTheSameText() {
    // Two quick removes on the body, both pressed before either landed: both carried `typed`.
    let draft = req(body: [.literal("{\"a\":1,")])
    let boxes: ApiHeld = [box: [.literal(typed)]]
    let first = hold(typed, token: 1)
    let second = hold(typed, token: 2)
    // The second press replaced the first's hold.
    let takenOver = [box: second]
    // The first is refused. Its hold is gone already; the second's stays, and the box with it.
    let afterFirst = apiGestureSettled(
        takenOver: takenOver, held: boxes, carried: [box: first], landed: false)
    #expect(afterFirst.takenOver == takenOver)
    #expect(afterFirst.held == boxes)
    // So no flush writes the stale box back behind the second gesture's write.
    #expect(apiFlush(draft, held: afterFirst.held, pane: "p", takenOver: afterFirst.takenOver)
        .writes.isEmpty)
    // The second's own outcome settles it.
    let afterSecond = apiGestureSettled(
        takenOver: afterFirst.takenOver, held: afterFirst.held, carried: [box: second],
        landed: true)
    #expect(afterSecond.takenOver.isEmpty)
    #expect(afterSecond.held.isEmpty)
}
