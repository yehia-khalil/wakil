import Foundation
import Testing
@testable import WakilKit

/// Amendment 9a: what the operator types is written within a pause, and before any gesture.
/// Nothing here holds a timer. These are the values the pane's timer and gestures dispatch.

private func req(
    method: String = "POST", path: [ApiPart] = [], query: [ApiQueryRow] = [],
    headers: [ApiHeaderRegionRow] = ApiRequestSnapshot.empty.headers, body: [ApiPart] = []
) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: method, origin: "https://httpbin.org", path: path, query: query,
        headers: headers, body: body)
}

private func q(_ name: String, _ value: [ApiPart]) -> ApiQueryRow { ApiQueryRow(name: name, value: value) }

@Test("A typed path is one write carrying path and query together")
func aTypedPathIsOneWrite() {
    #expect(apiPendingWrite(req(), box: ApiFieldRow(.path), holding: [.literal("/test?page=2")], pane: "p")
        == .write(apiPathQueryWrite(
            path: [.literal("/test")], query: [q("page", [.literal("2")])], pane: "p")))
}

@Test("Text the draft already holds writes nothing")
func textTheDraftHoldsWritesNothing() {
    let r = req(path: [.literal("/test")], body: [.literal("{}")])
    #expect(apiPendingWrite(r, box: ApiFieldRow(.path), holding: [.literal("/test")], pane: "p") == .unchanged)
    #expect(apiPendingWrite(r, box: ApiFieldRow(.body), holding: [.literal("{}")], pane: "p") == .unchanged)
    #expect(apiFlush(r, held: [ApiFieldRow(.path): [.literal("/test")]], pane: "p").writes.isEmpty)
}

@Test("A path the view cannot parse is refused in its own words, and nothing is written")
func anUnparsablePathIsRefused() {
    let flush = apiFlush(req(), held: [ApiFieldRow(.path): [.literal("/o?=x")]], pane: "p")
    #expect(flush.writes.isEmpty)
    #expect(flush.refusals[ApiFieldRow(.path)] == ApiPathQueryRefusal.namelessRow.line)
}

@Test("A typed body, query value, header value and content type each write their field")
func eachFieldWritesItself() {
    let r = req(
        query: [q("page", [.literal("1")])],
        headers: ApiRequestSnapshot.empty.headers + [.operatorRow(name: "x-a", value: [.literal("1")])])
    let flush = apiFlush(r, held: [
        ApiFieldRow(.body): [.literal("{\n}")],
        ApiFieldRow(.query("page")): [.literal("2")],
        ApiFieldRow(.header("x-a")): [.literal("2")],
        ApiFieldRow(.contentType): [.literal("application/json")],
    ], pane: "p")
    // Wire order: query, header, content type, body.
    #expect(flush.writes.count == 4)
    #expect(flush.writes.allSatisfy { $0.0 == "api_set_request" })
    guard case .object(let last) = flush.writes[3].1 else { Issue.record("not an object"); return }
    #expect(last["body"] == .array([.object(["literal": .string("{\n}")])]))
}

@Test("W16: a body beside a binding is written, and the binding rides along unchanged")
func aBodyBesideABindingIsWritten() {
    let bound = liveBinding(name: "id")
    let r = req(body: [.bound(bound)])
    #expect(apiPendingWrite(r, box: ApiFieldRow(.body), holding: [.bound(bound), .literal("x")], pane: "p")
        == .write(.object(["pane": .string("p"), "body": .array([
            apiPartJSON(.bound(bound), sources: [:]), .object(["literal": .string("x")]),
        ])])))
}

@Test("Review Focus 1, on screen: a path box that would move a binding applies nothing")
func aBindingMoveIsNotApplied() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    let r = req(path: [.literal("/o")], query: [q("id", [bound])])
    // The view drew `/o?id=` and the query's chip; with the `?` gone the chip would land in the
    // path, a region that does not hold it.
    let applied = apiRequestApplying(r, held: [ApiFieldRow(.path): [.literal("/oid="), bound]])
    #expect(applied.path == r.path)
    #expect(applied.query == r.query)
}

@Test("The screen's request applies every box, and a parse refusal leaves path and query alone")
func theAppliedRequestIsWhatTheScreenShows() {
    let r = req(path: [.literal("/a")], query: [q("page", [.literal("1")])])
    let applied = apiRequestApplying(r, held: [
        ApiFieldRow(.query("page")): [.literal("2")],
        ApiFieldRow(.contentType): [.literal("text/plain")],
    ])
    #expect(applied.query == [q("page", [.literal("2")])])
    #expect(apiContentTypeText(applied) == "text/plain")
    #expect(apiRequestApplying(r, held: [ApiFieldRow(.path): [.literal("/o?=x")]]).path == [.literal("/a")])
    // `except` leaves one box out, so a gesture on that field can carry it against the drawn parts.
    #expect(apiRequestApplying(
        r, held: [ApiFieldRow(.query("page")): [.literal("2")]], except: ApiFieldRow(.query("page"))).query
        == r.query)
}

@Test("A gesture is built on the request the screen shows, after the flush")
func aGestureIsBuiltOnWhatTheScreenShows() {
    let r = req(query: [q("page", [.literal("1")])])
    let boxes: ApiHeld = [ApiFieldRow(.query("page")): [.literal("2")]]
    // What the pane runs (`operateFlushed`): the gesture's calls built now on the request the
    // screen shows, and the flush built at the batch's turn, ahead of them.
    let applied = apiRequestApplying(r, held: boxes)
    let gesture: [(String, JSONValue)] =
        [("api_set_request", .object(["pane": .string("p"), "method": .string("PUT")]))]
    let sequence = apiFlush(r, held: boxes, pane: "p").writes + gesture
    #expect(sequence.map(\.0) == ["api_set_request", "api_set_request"])
    #expect(applied.query == [q("page", [.literal("2")])])
}

@Test("B5: Send writes a typed path first, and its statement names that path")
func sendWritesATypedPathFirst() {
    let sequence = apiSendPlan(draft: req(), pane: "p", held: [ApiFieldRow(.path): [.literal("/test")]]).calls
    #expect(sequence.map(\.0) == ["api_set_request", "api_send"])
    guard case .object(let send) = sequence[1].1, case .string(let statement)? = send["statement"]
    else { Issue.record("no statement"); return }
    #expect(statement.hasPrefix("Send POST https://httpbin.org/test"), "\(statement)")
}

@Test("With nothing typed, Send is the send alone")
func sendWithNothingTypedIsTheSendAlone() {
    let r = req(path: [.literal("/v1")])
    #expect(apiSendPlan(draft: r, pane: "p", held: [:]).calls.map(\.0) == ["api_send"])
    #expect(apiSendPlan(draft: r, pane: "p", held: [ApiFieldRow(.path): [.literal("/v1")]]).calls.map(\.0)
        == ["api_send"])
}

@Test("A box whose text the draft now holds is let go once the write lands")
func aLandedBoxIsLetGo() {
    let landed = req(path: [.literal("/test")])
    #expect(apiHeldAfterLanding(landed, held: [ApiFieldRow(.path): [.literal("/test")]], focused: nil).isEmpty)
}

@Test("A box whose write is still in flight, or that was typed past it, is kept")
func aBoxWhoseWriteIsInFlightIsKept() {
    // The draft still holds the text from before the write; the box holds newer text.
    let r = req(path: [.literal("/te")])
    let boxes: ApiHeld = [ApiFieldRow(.path): [.literal("/test")]]
    #expect(apiHeldAfterLanding(r, held: boxes, focused: nil) == boxes)
}

@Test("The focused box keeps a trailing ? that writes nothing; an unfocused one lets it go")
func aTrailingQuestionMarkSurvivesWhileTyping() {
    let r = req(path: [.literal("/o")])
    let boxes: ApiHeld = [ApiFieldRow(.path): [.literal("/o?")]]
    #expect(apiHeldAfterLanding(r, held: boxes, focused: ApiFieldRow(.path)) == boxes)
    #expect(apiHeldAfterLanding(r, held: boxes, focused: nil).isEmpty)
}

@Test("Escape writes back what the field held at focus-in, once, and nothing when it is unchanged")
func escapeRestoresTheFieldAtFocusIn() {
    let then = req(path: [.literal("/v1")], query: [q("a", [.literal("1")])])
    let now = req(path: [.literal("/v1x")], query: [q("a", [.literal("1")])])
    let focused = ApiFocusedField(box: ApiFieldRow(.path), request: then)
    #expect(apiRestoreWrite(focused, current: now, pane: "p")
        == apiPathQueryWrite(path: then.path, query: then.query, pane: "p"))
    #expect(apiRestoreWrite(focused, current: then, pane: "p") == nil)
}

@Test("Escape in one query row puts that row back and keeps the others as they are now")
func escapeInARowRestoresOnlyThatRow() {
    let then = req(query: [q("a", [.literal("1")]), q("b", [.literal("x")])])
    let now = req(query: [q("a", [.literal("19")]), q("b", [.literal("y")])])
    let write = apiRestoreWrite(
        ApiFocusedField(box: ApiFieldRow(.query("a")), request: then), current: now, pane: "p")
    guard case .object(let fields)? = write, case .array(let rows)? = fields["query"] else {
        Issue.record("no query write"); return
    }
    #expect(rows == [
        .object(["name": .string("a"), "value": .array([.object(["literal": .string("1")])])]),
        .object(["name": .string("b"), "value": .array([.object(["literal": .string("y")])])]),
    ])
}

@Test("P5: Escape after an unbind restores the text and the hole, never the binding")
func anEscapeAfterAnUnbindRestoresTheTextAndTheHole() {
    // Under W16 a field holding a chip can hold the cursor, and its chip can be unbound while
    // it does. Escape must not name a binding the region no longer holds: `api_set_request`
    // would refuse the whole write, and Escape would silently do nothing.
    let bound = liveBinding(name: "id")
    let other = liveBinding(name: "k")
    let hole = JSONValue.object(["slot": .string("id")])
    func lit(_ text: String) -> JSONValue { .object(["literal": .string(text)]) }
    func restore(_ box: ApiFieldRow, _ then: ApiRequestSnapshot, _ now: ApiRequestSnapshot) -> JSONValue? {
        apiRestoreWrite(ApiFocusedField(box: box, request: then), current: now, pane: "p")
    }

    // Body: typed, then unbound. The text comes back, and the hole in the binding's place.
    let then = req(body: [.literal("{\"id\":"), .bound(bound)])
    #expect(restore(ApiFieldRow(.body), then, req(body: [.literal("{\"id\":9"), .slot("id")]))
        == .object(["pane": .string("p"), "body": .array([lit("{\"id\":"), hole])]))
    // Unbound and nothing holding: the hole is what the field holds, so nothing is written.
    #expect(restore(ApiFieldRow(.body), then, req(body: [.literal("{\"id\":"), .slot("id")])) == nil)
    // Still held: carried as published, as every write carries it (W16).
    #expect(restore(ApiFieldRow(.body), then, req(body: [.literal("{\"id\":9"), .bound(bound)]))
        == .object(["pane": .string("p"), "body": .array([
            lit("{\"id\":"), apiPartJSON(.bound(bound), sources: [:]),
        ])]))

    // The path box: the path's chip unbound, the query's still held.
    let pathThen = req(path: [.literal("/o/"), .bound(bound)], query: [q("k", [.bound(other)])])
    let pathNow = req(path: [.literal("/o/x"), .slot("id")], query: [q("k", [.bound(other)])])
    #expect(restore(ApiFieldRow(.path), pathThen, pathNow) == apiPathQueryWrite(
        path: [.literal("/o/"), .slot("id")], query: [q("k", [.bound(other)])], pane: "p"))

    // A query row: its own binding unbound, a neighbour's carried as it is now.
    let rowThen = req(query: [q("a", [.literal("1"), .bound(bound)]), q("b", [.bound(other)])])
    let rowNow = req(query: [q("a", [.literal("12"), .slot("id")]), q("b", [.bound(other)])])
    guard case .object(let fields)? = restore(ApiFieldRow(.query("a")), rowThen, rowNow),
          case .array(let rows)? = fields["query"]
    else { Issue.record("no query write"); return }
    #expect(rows == [
        .object(["name": .string("a"), "value": .array([lit("1"), hole])]),
        .object(["name": .string("b"), "value": .array([apiPartJSON(.bound(other), sources: [:])])]),
    ])
}

// MARK: - Preflight rulings F7, F8, F23

@Test("F7: focus-out lets go of a box that writes nothing, so a later agent write is not reverted")
func focusOutLetsGoOfANoOpBox() {
    // `/o?` over `/o` writes nothing, so no snapshot lands to let it go.
    let r = req(path: [.literal("/o")])
    let boxes: ApiHeld = [ApiFieldRow(.path): [.literal("/o?")]]
    #expect(apiFlush(r, held: boxes, pane: "p").writes.isEmpty)
    // Focus-out runs the landing rule with nothing focused.
    let kept = apiHeldAfterLanding(r, held: boxes, focused: nil)
    #expect(kept.isEmpty)
    // The hazard it closes: an agent writes `/agent`, and the stale box would write `/o` back.
    let agent = req(path: [.literal("/agent")])
    #expect(!apiFlush(agent, held: boxes, pane: "p").writes.isEmpty)
    #expect(apiFlush(agent, held: kept, pane: "p").writes.isEmpty)
}

@Test("F8: Send sends nothing while the path box's parse refuses, not the draft's old path")
func sendSendsNothingPastARefusal() {
    let r = req(path: [.literal("/a")], body: [.literal("{}")])
    #expect(apiSendPlan(draft: r, pane: "p", held: [ApiFieldRow(.path): [.literal("/o?=x")]]).calls.isEmpty)
    // Not even another box's write: the screen shows a request that cannot be written.
    #expect(apiSendPlan(draft: r, pane: "p", held: [
        ApiFieldRow(.path): [.literal("/o?=x")], ApiFieldRow(.body): [.literal("{\n}")],
    ]).calls.isEmpty)
}

@Test("F23: a box whose write is already queued is not written a second time")
func aQueuedWriteIsNotWrittenTwice() {
    let r = req()
    let boxes: ApiHeld = [ApiFieldRow(.path): [.literal("/test")]]
    #expect(apiFlush(r, held: boxes, pane: "p", queued: boxes).writes.isEmpty)
    // Typed past the queued write, the box owes a new one.
    #expect(apiFlush(r, held: [ApiFieldRow(.path): [.literal("/tests")]], pane: "p", queued: boxes)
        .writes.count == 1)
    // Send still builds on what the screen shows, without writing the path again.
    let sequence = apiSendPlan(draft: r, pane: "p", held: boxes, queued: boxes).calls
    #expect(sequence.map(\.0) == ["api_send"])
    guard case .object(let send) = sequence[0].1, case .string(let statement)? = send["statement"]
    else { Issue.record("no statement"); return }
    #expect(statement.hasPrefix("Send POST https://httpbin.org/test"), "\(statement)")
}

@Test("F23: once a queued write's dispatch completes, refused or failed, the box is written again")
func aCompletedDispatchIsRetried() {
    // The write for `/test` was queued, then its dispatch completed without landing: the draft
    // still lacks it. The pane clears `queued` on completion, whatever the outcome.
    let r = req()
    let boxes: ApiHeld = [ApiFieldRow(.path): [.literal("/test")]]
    #expect(apiFlush(r, held: boxes, pane: "p", queued: boxes).writes.isEmpty)
    let afterCompletion: ApiHeld = [:]
    let flush = apiFlush(r, held: boxes, pane: "p", queued: afterCompletion)
    #expect(flush.writes.map(\.0) == ["api_set_request"])
    #expect(flush.writes.first?.1 == apiPathQueryWrite(path: [.literal("/test")], query: [], pane: "p"))
}

@Test("The path box applies before a query row's box, whatever the dictionary's order")
func pathAndQueryApplyInADeterministicOrder() {
    // The result must not depend on hashing: the path view (wire order before query) applies
    // first, the row after.
    let r = req(path: [.literal("/a")], query: [q("page", [.literal("1")])])
    // Different capacities put the two keys in different buckets, so iteration order varies.
    for capacity in 2..<64 {
        var boxes = ApiHeld(minimumCapacity: capacity)
        boxes[ApiFieldRow(.query("page"))] = [.literal("2")]
        boxes[ApiFieldRow(.path)] = [.literal("/b?page=3")]
        let applied = apiRequestApplying(r, held: boxes)
        #expect(applied.path == [.literal("/b")])
        #expect(applied.query == [q("page", [.literal("2")])])
    }
}

// MARK: - Task 4: what the pane holds as queued while a flush is in flight

@Test("A flush names each box it wrote, as dispatched, and no box it refused or skipped")
func aFlushNamesTheBoxesItWrote() {
    let r = req(path: [.literal("/o")], body: [.literal("{}")])
    let boxes: ApiHeld = [
        ApiFieldRow(.body): [.literal("{\n}")],
        ApiFieldRow(.path): [.literal("/o?=x")],
        ApiFieldRow(.query("gone")): [.literal("x")],
    ]
    let flush = apiFlush(r, held: boxes, pane: "p")
    #expect(flush.written == [ApiFieldRow(.body): [.literal("{\n}")]])
    #expect(flush.writes.count == 1)
    // A box already queued at this text writes nothing, so it is not named again.
    #expect(apiFlush(r, held: boxes, pane: "p", queued: flush.written).written.isEmpty)
}

@Test("A dispatch completing clears only the queued boxes it carried, at the text it carried")
func aCompletedDispatchClearsOnlyWhatItCarried() {
    let body = ApiFieldRow(.body)
    let path = ApiFieldRow(.path)
    let queued: ApiHeld = [body: [.literal("{\n}")], path: [.literal("/p")]]
    // The body's dispatch completes: the path's, still in flight, stays queued.
    #expect(apiQueuedSettled(queued, written: [body: [.literal("{\n}")]]) == [path: [.literal("/p")]])
    // A later dispatch queued the body at newer text: the earlier one's completion leaves it.
    let newer: ApiHeld = [body: [.literal("{\n }")]]
    #expect(apiQueuedSettled(newer, written: [body: [.literal("{\n}")]]) == newer)
}

@Test("Send's plan is one flush: its calls, the boxes it writes, and the refusal that empties it")
func sendsPlanIsOneFlush() {
    let r = req(path: [.literal("/o")])
    let plan = apiSendPlan(draft: r, pane: "p", held: [ApiFieldRow(.path): [.literal("/test")]])
    #expect(plan.calls.map(\.0) == ["api_set_request", "api_send"])
    #expect(plan.written == [ApiFieldRow(.path): [.literal("/test")]])
    #expect(plan.refusals.isEmpty)
    let refused = apiSendPlan(draft: r, pane: "p", held: [ApiFieldRow(.path): [.literal("/o?=x")]])
    #expect(refused.calls.isEmpty)
    #expect(refused.written.isEmpty)
    #expect(refused.refusals[ApiFieldRow(.path)] == ApiPathQueryRefusal.namelessRow.line)
}

// MARK: - Round 5: a box whose text the draft now shows is let go, focused or not

@Test("Round 5: the path box is let go once its text lands, so a Query-region edit redraws it")
func aLandedPathBoxIsLetGoAndFollowsTheQueryRegion() {
    let path = ApiFieldRow(.path)
    let boxes: ApiHeld = [path: [.literal("/orders?page=2")]]
    // Its own write landed while the cursor was still in it.
    let landed = req(path: [.literal("/orders")], query: [q("page", [.literal("2")])])
    #expect(apiHeldAfterLanding(landed, held: boxes, focused: path).isEmpty)
    // Kept, it would hold `page=2` over a Query-region write of `page=5`, and owe a write that
    // reverts it.
    let edited = req(path: [.literal("/orders")], query: [q("page", [.literal("5")])])
    #expect(apiPendingWrite(edited, box: path, holding: [.literal("/orders?page=2")], pane: "p") != .unchanged)
    // Let go, the box draws the derived view.
    #expect(apiPathQueryView(path: edited.path, query: edited.query) == [.literal("/orders?page=5")])
}

@Test("Round 5: a focused query, header or body box is let go once the draft shows its text")
func aLandedFocusedRowBoxIsLetGo() {
    let r = req(
        path: [.literal("/orders")], query: [q("page", [.literal("5")])],
        headers: ApiRequestSnapshot.empty.headers
            + [.operatorRow(name: "X-Trace", value: [.literal("abc")])],
        body: [.literal("{}")])
    for (box, typed): (ApiFieldRow, [ApiPart]) in [
        (ApiFieldRow(.query("page")), [.literal("5")]),
        (ApiFieldRow(.header("X-Trace")), [.literal("abc")]),
        (ApiFieldRow(.body), [.literal("{}")]),
    ] {
        #expect(apiHeldAfterLanding(r, held: [box: typed], focused: box).isEmpty, "\(box)")
    }
}

@Test("Round 5: a focused box the view cannot show yet is still kept (`/o?`, the empty trailing box typed into)")
func aFocusedBoxTheViewDoesNotShowIsKept() {
    let path = ApiFieldRow(.path)
    let r = req(path: [.literal("/o")])
    #expect(apiHeldAfterLanding(r, held: [path: [.literal("/o?")]], focused: path) == [path: [.literal("/o?")]])
    // A box typed past the landing is kept, focused or not.
    let typedOn: ApiHeld = [path: [.literal("/ord")]]
    #expect(apiHeldAfterLanding(r, held: typedOn, focused: path) == typedOn)
}

// MARK: - Round 6: a set that changes nothing types nothing

@Test("Round 6: a TextField re-setting the text it shows creates no box and starts no pause")
func aSetOfTheShownTextTypesNothing() {
    let path = ApiFieldRow(.path)
    // The path box was let go at its landing; the field ends editing and sets what it shows.
    #expect(apiHeldTyping(
        [:], box: path, parts: [.literal("/orders?page=2")], rendered: [.literal("/orders?page=2")])
        == nil)
    // A field already at that text is unchanged too.
    #expect(apiHeldTyping(
        [path: [.literal("/o?")]], box: path, parts: [.literal("/o?")], rendered: [.literal("/o")])
        == nil)
    // A real keystroke is a hold.
    #expect(apiHeldTyping(
        [:], box: path, parts: [.literal("/orders?page=23")], rendered: [.literal("/orders?page=2")])
        == [path: [.literal("/orders?page=23")]])
    // Typing back to the rendered text over a hold is a change, and is kept until it lands.
    #expect(apiHeldTyping(
        [path: [.literal("/o?")]], box: path, parts: [.literal("/o")], rendered: [.literal("/o")])
        == [path: [.literal("/o")]])
}

// MARK: - Final review: Escape against the draft, the A-B-A let-go

@Test("Final review 1: Escape restores the draft when an earlier write reached it, though the box is back at its focus-in text")
func escapeRestoresTheDraftAnEarlierWriteReached() {
    let path = ApiFieldRow(.path)
    let then = req(path: [.literal("/a")])
    let focused = ApiFocusedField(box: path, request: then)
    // Type X: the pause writes `/aX`, and it lands.
    let flush = apiFlush(then, held: [path: [.literal("/aX")]], pane: "p")
    #expect(flush.writes.count == 1)
    let draft = req(path: [.literal("/aX")])
    let afterLanding = apiHeldAfterLanding(draft, held: [path: [.literal("/aX")]], focused: path)
    #expect(afterLanding.isEmpty)
    // Backspace: the box shows `/a` again. The screen matches the focus-in text, the draft does not.
    let boxes = try! #require(apiHeldTyping(
        afterLanding, box: path, parts: [.literal("/a")], rendered: [.literal("/aX")]))
    #expect(apiRequestApplying(draft, held: boxes) == then)
    // Escape within the pause: built at its turn against the stored draft, it writes `/a` back.
    let calls = apiRestoreCalls(focused, box: path, draft: draft, pane: "p")
    #expect(calls.map(\.0) == ["api_set_request"])
    #expect(calls.first?.1 == apiPathQueryWrite(path: then.path, query: then.query, pane: "p"))
    // Nothing reached the draft: Escape writes nothing.
    #expect(apiRestoreCalls(focused, box: path, draft: then, pane: "p").isEmpty)
    // Escape in a box other than the focused one writes nothing.
    #expect(apiRestoreCalls(focused, box: ApiFieldRow(.body), draft: draft, pane: "p").isEmpty)
    #expect(apiRestoreCalls(nil, box: path, draft: draft, pane: "p").isEmpty)
}

@Test("Final review 9: a focused box showing the view is kept while a write of other text is in flight (A-B-A)")
func aFocusedBoxIsKeptWhileADifferentWriteIsInFlight() {
    let path = ApiFieldRow(.path)
    // `/aB` was dispatched; the operator backspaced to `/a`, which the draft still shows.
    let draft = req(path: [.literal("/a")])
    let boxes: ApiHeld = [path: [.literal("/a")]]
    let queued: ApiHeld = [path: [.literal("/aB")]]
    // Let go here, `/aB` lands next and the typed `/a` is lost.
    #expect(apiHeldAfterLanding(draft, held: boxes, focused: path, queued: queued) == boxes)
    // Kept, the flush built after `/aB` lands writes `/a` back.
    #expect(apiFlush(req(path: [.literal("/aB")]), held: boxes, pane: "p").writes.count == 1)
    // In flight at the same text, or nothing in flight: let go, as round 5.
    #expect(apiHeldAfterLanding(draft, held: boxes, focused: path, queued: boxes).isEmpty)
    #expect(apiHeldAfterLanding(draft, held: boxes, focused: path).isEmpty)
}

// MARK: - Plan B preflight P7: the Escape baseline is taken after the left field lands

@Test("P7: Escape in the path box writes nothing once the Query edit it came from is in the baseline")
func escapeKeepsTheQueryEditTheCursorCameFrom() {
    let path = ApiFieldRow(.path)
    // The operator typed `page=5` in the Query region, then clicked into the path box. The
    // path box's focus-in saw the draft before the Query box's flush landed.
    let before = req(path: [.literal("/o")], query: [q("page", [.literal("2")])])
    let landed = req(path: [.literal("/o")], query: [q("page", [.literal("5")])])
    var focus = ApiFocusTracker()
    _ = focus.took(path, identifier: "api.path", request: before)
    // Taken before the flush landed, Escape would undo the operator's own Query edit.
    #expect(apiRestoreCalls(focus.focused, box: path, draft: landed, pane: "p").first?.1
        == apiPathQueryWrite(path: before.path, query: before.query, pane: "p"))
    // Rebased on the chain, behind that flush: Escape writes nothing.
    let took = focus.rebased(identifier: "api.path", request: landed)
    #expect(took)
    #expect(apiRestoreCalls(focus.focused, box: path, draft: landed, pane: "p").isEmpty)
}
