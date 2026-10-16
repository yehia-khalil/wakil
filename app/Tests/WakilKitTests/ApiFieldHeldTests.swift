import Foundation
import Testing
@testable import WakilKit

/// Amendment 10a: saved as typed (9a), one held part list per field.

private func req(
    method: String = "POST", path: [ApiPart] = [], query: [ApiQueryRow] = [],
    headers: [ApiHeaderRegionRow] = ApiRequestSnapshot.empty.headers, body: [ApiPart] = []
) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: method, origin: "https://httpbin.org", path: path, query: query,
        headers: headers, body: body)
}

private func q(_ name: String, _ value: [ApiPart]) -> ApiQueryRow { ApiQueryRow(name: name, value: value) }
private let body = ApiFieldRow(.body)
private let path = ApiFieldRow(.path)
private let contentType = ApiFieldRow(.contentType)

private func bodyWrite(_ parts: [JSONValue], pane: String = "p") -> ApiPendingWrite {
    .write(.object(["pane": .string(pane), "body": .array(parts)]))
}

private func lit(_ text: String) -> JSONValue { .object(["literal": .string(text)]) }
private func slot(_ name: String) -> JSONValue { .object(["slot": .string(name)]) }

// MARK: - The plan's tests

@Test("A held body is one write carrying the field whole, its holes as slots")
func aHeldBodyIsOneWrite() {
    #expect(apiPendingWrite(req(), box: body, holding: [.literal("{\"a\":"), .slot("id"), .literal("}")],
                            pane: "p")
        == bodyWrite([lit("{\"a\":"), slot("id"), lit("}")]))
}

@Test("Parts the draft already holds, merged or not, write nothing")
func heldEqualToTheDraftWritesNothing() {
    let r = req(body: [.literal("{"), .literal("}")])
    #expect(apiPendingWrite(r, box: body, holding: [.literal("{}")], pane: "p") == .unchanged)
    #expect(apiFlush(r, held: [body: [.literal("{}")]], pane: "p").writes.isEmpty)
}

@Test("W16: a binding the region holds rides along unchanged")
func aHeldBindingRidesAlong() {
    let bound = liveBinding(name: "id")
    let r = req(body: [.bound(bound)])
    #expect(apiPendingWrite(r, box: body, holding: [.bound(bound), .literal("x")], pane: "p")
        == bodyWrite([apiPartJSON(.bound(bound), sources: [:]), lit("x")]))
}

@Test("Review Focus 2: a binding the region no longer holds is written as its hole, never made")
func aBindingTheRegionNoLongerHoldsIsWrittenAsItsHole() {
    // Undo brought a bound token back after its unbind landed: the draft holds the hole.
    let bound = liveBinding(name: "id")
    let r = req(body: [.slot("id")])
    #expect(apiPendingWrite(r, box: body, holding: [.bound(bound), .literal("x")], pane: "p")
        == bodyWrite([slot("id"), lit("x")]))
    // And held twice, the second copy is a hole too: a write never makes a binding.
    let r2 = req(body: [.bound(bound)])
    #expect(apiPendingWrite(r2, box: body, holding: [.bound(bound), .bound(bound)], pane: "p")
        == bodyWrite([apiPartJSON(.bound(bound), sources: [:]), slot("id")]))
}

@Test("The path view parses back to path and query in one write")
func thePathViewIsOneWrite() {
    #expect(apiPendingWrite(req(), box: path, holding: [.literal("/test?page=2")], pane: "p")
        == .write(apiPathQueryWrite(path: [.literal("/test")], query: [q("page", [.literal("2")])], pane: "p")))
}

@Test("A path view the parse refuses is refused in its own words")
func aRefusedPathView() {
    let flush = apiFlush(req(), held: [path: [.literal("/o?=x")]], pane: "p")
    #expect(flush.writes.isEmpty)
    #expect(flush.refusals == [path: ApiPathQueryRefusal.namelessRow.line])
    #expect(flush.written.isEmpty)
}

@Test("A hole at a caret in a query value of the path view lands in that value")
func aHoleInAQueryValueOfTheView() {
    let r = req(path: [.literal("/o")], query: [q("id", [.literal("7")])])
    #expect(apiPendingWrite(r, box: path, holding: [.literal("/o?id="), .slot("id")], pane: "p")
        == .write(apiPathQueryWrite(path: [.literal("/o")], query: [q("id", [.slot("id")])], pane: "p")))
}

@Test("A query value and a header value write their region whole, other rows carried")
func rowsWriteTheirRegion() {
    let r = req(query: [q("a", [.literal("1")]), q("b", [.literal("2")])])
    #expect(apiPendingWrite(r, box: ApiFieldRow(.query("b")), holding: [.literal("3")], pane: "p")
        == .write(.object(["pane": .string("p"), "query": .array([
            .object(["name": .string("a"), "value": .array([lit("1")])]),
            .object(["name": .string("b"), "value": .array([lit("3")])]),
        ])])))
    let headers = ApiRequestSnapshot.empty.headers + [
        .operatorRow(name: "x-a", value: [.literal("1")]),
        .operatorRow(name: "x-b", value: [.literal("2")]),
    ]
    let h = req(headers: headers)
    #expect(apiPendingWrite(h, box: ApiFieldRow(.header("x-a")), holding: [.literal("9")], pane: "p")
        == .write(.object(["pane": .string("p"), "headers": .array([
            .object(["name": .string("x-a"), "value": .array([lit("9")])]),
            .object(["name": .string("x-b"), "value": .array([lit("2")])]),
        ])])))
}

@Test("F23: a field whose write is in flight at exactly these parts is skipped")
func anInFlightFieldIsSkipped() {
    let held: ApiHeld = [body: [.literal("x")]]
    #expect(apiFlush(req(), held: held, pane: "p", queued: held).writes.isEmpty)
    let typedPast = apiFlush(req(), held: [body: [.literal("xy")]], pane: "p", queued: held)
    #expect(typedPast.writes.map(\.0) == ["api_set_request"])
    #expect(typedPast.writes.map(\.1) == [.object(["pane": .string("p"), "body": .array([lit("xy")])])])
    #expect(typedPast.written == [body: [.literal("xy")]])
    #expect(apiQueuedSettled(held, written: held).isEmpty)
}

@Test("A field a gesture took over is never flushed at the parts it carried")
func aTakenOverFieldIsNotFlushed() {
    let held: ApiHeld = [body: [.literal("x")]]
    let takenOver = [body: ApiHeldTakeover(held: [.literal("x")], token: 1)]
    #expect(apiFlush(req(), held: held, pane: "p", takenOver: takenOver).writes.isEmpty)
    // Typed past what the gesture carried, the field is the operator's again.
    let past = apiFlush(req(), held: [body: [.literal("xz")]], pane: "p", takenOver: takenOver)
    #expect(past.written == [body: [.literal("xz")]])
}

@Test("A held field is let go once the draft shows it; kept while focused and owing")
func heldAfterLanding() {
    let r = req(body: [.literal("x")])
    #expect(apiHeldAfterLanding(r, held: [body: [.literal("x")]], focused: body).isEmpty)
    #expect(apiHeldAfterLanding(r, held: [body: [.literal("xy")]], focused: nil) == [body: [.literal("xy")]])
    // A-B-A: shown, focused, but another write for it is still in flight: kept.
    #expect(apiHeldAfterLanding(r, held: [body: [.literal("x")]], focused: body,
                                queued: [body: [.literal("xy")]]) == [body: [.literal("x")]])
}

@Test("A set that changes nothing types nothing (round 6), up to merging")
func aSetThatChangesNothing() {
    #expect(apiHeldTyping([:], box: body, parts: [.literal("a"), .literal("b")],
                          rendered: [.literal("ab")]) == nil)
    #expect(apiHeldTyping([:], box: body, parts: [.literal("abc")], rendered: [.literal("ab")])
        == [body: [.literal("abc")]])
}

@Test("A gesture's dispatch settles only what it carried: landed lets go, refused owes")
func gestureSettled() {
    let entry = ApiHeldTakeover(held: [.literal("x")], token: 7)
    let landed = apiGestureSettled(takenOver: [body: entry], held: [body: [.literal("x")]],
                                   carried: [body: entry], landed: true)
    #expect(landed.takenOver.isEmpty)
    #expect(landed.held.isEmpty)
    #expect(landed.owed == false)
    let refused = apiGestureSettled(takenOver: [body: entry], held: [body: [.literal("x")]],
                                    carried: [body: entry], landed: false)
    #expect(refused.takenOver.isEmpty)
    #expect(refused.held == [body: [.literal("x")]])
    #expect(refused.owed == true)
}

@Test("Send: every held field's write, then the send, built on what the screen shows")
func sendPlanCarriesHeldWritesFirst() {
    let plan = apiSendPlan(draft: req(), pane: "p", held: [body: [.literal("{}")]])
    #expect(plan.calls.map(\.0) == ["api_set_request", "api_send"])
    #expect(plan.calls.first?.1 == .object(["pane": .string("p"), "body": .array([lit("{}")])]))
    #expect(plan.written == [body: [.literal("{}")]])
    #expect(plan.refusals.isEmpty)
    #expect(plan.refusal == nil)
}

@Test("Format formats the held body, tokens in place")
func formatHolding() {
    #expect(apiFormatBodyWrite(
        draft: req(), pane: "p",
        holding: [.literal("{\"a\":"), .slot("a"), .literal(",\"b\":"), .slot("b"), .literal("}")])
        == .object(["pane": .string("p"), "body": .array([
            lit("{\n  \"a\": "), slot("a"), lit(",\n  \"b\": "), slot("b"), lit("\n}"),
        ])]))
}

// MARK: - Preflight rulings (D1, D2, M7)

@Test("D1: the content type's text is its literals joined, a token dropped")
func plainLiteralJoinsLiterals() {
    #expect(apiPlainLiteral([.literal("a"), .slot("x"), .literal("b")]) == "ab")
    #expect(apiPlainLiteral([]) == "")
}

@Test("D2: held fields are taken in wire order, field then row")
func heldInWireOrder() {
    let held: ApiHeld = [
        body: [], ApiFieldRow(.query("b"), row: 1): [], ApiFieldRow(.query("b")): [],
        ApiFieldRow(.header("h")): [], path: [], ApiFieldRow(.query("a")): [], contentType: [],
    ]
    #expect(apiHeldInWireOrder(held) == [
        path, ApiFieldRow(.query("a")), ApiFieldRow(.query("b")), ApiFieldRow(.query("b"), row: 1),
        ApiFieldRow(.header("h")), contentType, body,
    ])
}

@Test("The content type writes its literals as one line, and a commit the draft holds writes nothing")
func contentTypeHeld() {
    #expect(apiPendingWrite(req(), box: contentType, holding: [.literal("text/plain")], pane: "p")
        == .write(apiFieldWrite(field: .contentType, text: "text/plain", pane: "p")))
    let r = req(headers: apiWakilHeaderRows(entry: "", contentType: "text/plain", credentialed: false))
    #expect(apiHeldView(r, contentType) == [.literal("text/plain")])
    #expect(apiPendingWrite(r, box: contentType, holding: [.literal("text/plain ")], pane: "p") == .unchanged)
    #expect(apiHeldView(req(), contentType) == [])
}

@Test("M7: Format over a held binding the body no longer holds writes its hole")
func formatWritesAnUnheldBindingAsItsHole() {
    let bound = liveBinding(name: "id")
    let r = req(body: [.literal("{\"a\":"), .slot("id"), .literal("}")])
    let holding: [ApiPart] = [.literal("{\"a\":"), .bound(bound), .literal("}")]
    #expect(apiFormatBodyWrite(draft: r, pane: "p", holding: holding)
        == .object(["pane": .string("p"), "body": .array([
            lit("{\n  \"a\": "), slot("id"), lit("\n}"),
        ])]))
    // Held by the body, the binding is carried as published.
    let held = req(body: [.bound(bound)])
    #expect(apiFormatBodyWrite(draft: held, pane: "p", holding: holding)
        == .object(["pane": .string("p"), "body": .array([
            lit("{\n  \"a\": "), apiPartJSON(.bound(bound), sources: [:]), lit("\n}"),
        ])]))
}

@Test("Format is a no-op only when it would write the body the draft holds")
func formatIsNoOpHolding() {
    let r = req(body: [.literal("{\n  \"a\": 1\n}")])
    #expect(apiFormatIsNoOp(draft: r, holding: [.literal("{\"a\":1}")]) == true)
    #expect(apiFormatIsNoOp(draft: r, holding: [.literal("{\"a\":2}")]) == false)
    #expect(apiFormatIsNoOp(draft: r, holding: [.literal("{")]) == false)
    // The held binding the body no longer holds formats as its hole: a write, not a no-op.
    let bound = liveBinding(name: "id")
    let holed = req(body: [.literal("{\n  \"a\": "), .slot("id"), .literal("\n}")])
    #expect(apiFormatIsNoOp(draft: holed, holding: [.literal("{\"a\":"), .bound(bound), .literal("}")]) == true)
}

@Test("Format is live over a typable body with something in it")
func formatIsEnabledHolding() {
    #expect(apiFormatIsEnabled(draft: req(), holding: [.literal("{}")]) == true)
    #expect(apiFormatIsEnabled(draft: req(), holding: [.literal("")]) == false)
    #expect(apiFormatIsEnabled(draft: req(), holding: []) == false)
}

@Test("M7: the request the screen shows names no binding its region no longer holds")
func applyingWritesAnUnheldBindingAsItsHole() {
    let bound = liveBinding(name: "id")
    let r = req(query: [q("a", [.slot("id")])], body: [.slot("id")])
    let applied = apiRequestApplying(r, held: [
        body: [.bound(bound), .literal("x")],
        ApiFieldRow(.query("a")): [.bound(bound)],
    ])
    #expect(applied.body == [.slot("id"), .literal("x")])
    #expect(applied.query == [q("a", [.slot("id")])])
    // Held by the region, carried.
    let kept = apiRequestApplying(req(body: [.bound(bound)]), held: [body: [.literal("y"), .bound(bound)]])
    #expect(kept.body == [.literal("y"), .bound(bound)])
}

@Test("M7: a header row's unheld binding is its hole on Send's statement path")
func applyingHeaderUnheldBinding() {
    let bound = liveBinding(name: "tok")
    let headers = ApiRequestSnapshot.empty.headers + [.operatorRow(name: "x-t", value: [.slot("tok")])]
    let applied = apiRequestApplying(req(headers: headers), held: [ApiFieldRow(.header("x-t")): [.bound(bound)]])
    #expect(applied.headers.last == .operatorRow(name: "x-t", value: [.slot("tok")]))
}

@Test("M7, ruled: the path view writes a binding no region holds as its hole")
func pathViewUnheldBindingIsItsHole() {
    let bound = liveBinding(name: "id")
    let r = req(path: [.literal("/o/"), .slot("id")])
    #expect(apiPendingWrite(r, box: path, holding: [.literal("/o/"), .bound(bound), .literal("/x")], pane: "p")
        == .write(apiPathQueryWrite(path: [.literal("/o/"), .slot("id"), .literal("/x")], query: [], pane: "p")))
    #expect(apiPathViewWrite(r, view: [.literal("/o/"), .bound(bound), .literal("/x")], pane: "p")
        == .write(apiPathQueryWrite(path: [.literal("/o/"), .slot("id"), .literal("/x")], query: [], pane: "p")))
    // Applied, the same.
    #expect(apiRequestApplying(r, held: [path: [.literal("/o/"), .bound(bound)]]).path
        == [.literal("/o/"), .slot("id")])
}

@Test("M7, ruled: a binding the path view carried across the ? is still refused, in boundMoved's words")
func pathViewMovedBindingIsRefused() {
    let bound = liveBinding(name: "id")
    let r = req(path: [.literal("/o/"), .bound(bound)])
    #expect(apiPathViewWrite(r, view: [.literal("/o?id="), .bound(bound)], pane: "p")
        == .refused(ApiPathQueryRefusal.boundMoved.line))
    #expect(apiFlush(r, held: [path: [.literal("/o?id="), .bound(bound)]], pane: "p").refusals
        == [path: ApiPathQueryRefusal.boundMoved.line])
    // A refused view applies nothing.
    let applied = apiRequestApplying(r, held: [path: [.literal("/o?id="), .bound(bound)]])
    #expect(applied.path == r.path)
    #expect(applied.query == r.query)
}

@Test("The path view that parses to the draft is unchanged; a locked path view writes nothing")
func pathViewUnchangedAndLocked() {
    let r = req(path: [.literal("/o")])
    #expect(apiPathViewWrite(r, view: [.literal("/o?")], pane: "p") == .unchanged)
    #expect(apiPendingWrite(r, box: path, holding: [.literal("/o?")], pane: "p") == .unchanged)
    let locked = req(path: [.literal("/o")], query: [q("a", [.literal("1&2")])])
    #expect(apiPendingWrite(locked, box: path, holding: [.literal("/p")], pane: "p") == .unchanged)
}

// MARK: - Plan B's lessons, one test each

@Test("Lesson: a re-set that echoes what the field shows is no change (SwiftUI/AppKit echo)")
func anEchoIsNoChange() {
    // An editor re-setting the parts it was handed, with nothing held: no hold, no pause.
    #expect(apiHeldTyping([:], box: path, parts: [.literal("/orders?page=2")],
                          rendered: [.literal("/orders?page=2")]) == nil)
    // The content type's TextField echoing an empty field.
    #expect(apiHeldTyping([:], box: contentType, parts: [.literal("")], rendered: []) == nil)
    // Held, an echo of the held parts is no change either; the rendered parts don't matter.
    let held: ApiHeld = [body: [.literal("ab")]]
    #expect(apiHeldTyping(held, box: body, parts: [.literal("ab")], rendered: [.literal("zz")]) == nil)
    // But typing back to what the draft shows over a held field IS a change: it must be written.
    #expect(apiHeldTyping(held, box: body, parts: [.literal("zz")], rendered: [.literal("zz")])
        == [body: [.literal("zz")]])
}

@Test("Lesson: a landed field is let go, focused or not, so a change from elsewhere redraws it")
func aLandedFieldIsLetGo() {
    // Round 5: the path editor wrote `/orders?page=2` and it landed. Focused, it is let go.
    let landed = req(path: [.literal("/orders")], query: [q("page", [.literal("2")])])
    let held: ApiHeld = [path: [.literal("/orders?page=2")]]
    let after = apiHeldAfterLanding(landed, held: held, focused: path)
    #expect(after.isEmpty)
    // Then the Query region writes page=5: nothing held pins the view, and no flush reverts it.
    let changed = req(path: [.literal("/orders")], query: [q("page", [.literal("5")])])
    #expect(apiHeldView(changed, path) == [.literal("/orders?page=5")])
    #expect(apiFlush(changed, held: after, pane: "p").writes.isEmpty)
    // Kept instead (the bug), the next flush would have written page=2 back.
    #expect(apiFlush(changed, held: held, pane: "p").writes.map(\.1)
        == [apiPathQueryWrite(path: [.literal("/orders")], query: [q("page", [.literal("2")])], pane: "p")])
}

@Test("Lesson: a focused field that writes nothing is kept; at focus-out (focused nil) it goes")
func aFocusedNoOpIsKeptUntilFocusOut() {
    let r = req(path: [.literal("/o")])
    let held: ApiHeld = [path: [.literal("/o?")]]
    #expect(apiHeldAfterLanding(r, held: held, focused: path) == held)
    #expect(apiHeldAfterLanding(r, held: held, focused: nil).isEmpty)
}

@Test("A held field whose write can carry no unheld binding is let go once its hole landed")
func aHeldUnheldBindingIsLetGoOnceItsHoleLanded() {
    let bound = liveBinding(name: "id")
    let r = req(body: [.slot("id"), .literal("x")])
    #expect(apiHeldAfterLanding(r, held: [body: [.bound(bound), .literal("x")]], focused: body).isEmpty)
}

@Test("A held row the region no longer has is let go, and writes nothing")
func aHeldRowPastTheEndIsLetGo() {
    let r = req(query: [q("a", [.literal("1")])])
    let gone = ApiFieldRow(.query("a"), row: 1)
    #expect(apiPendingWrite(r, box: gone, holding: [.literal("2")], pane: "p") == .unchanged)
    #expect(apiHeldAfterLanding(r, held: [gone: [.literal("2")]], focused: gone).isEmpty)
    #expect(apiRequestApplying(r, held: [gone: [.literal("2")]]).query == r.query)
}

@Test("Lesson: a queued write is skipped only while it is in flight; refused, it is owed again")
func aQueuedWriteIsSkippedOnlyInFlight() {
    let held: ApiHeld = [body: [.literal("x")]]
    let first = apiFlush(req(), held: held, pane: "p")
    #expect(first.written == held)
    var queued = first.written
    // In flight: a second flush (focus-out just after Send) does not write it twice.
    #expect(apiFlush(req(), held: held, pane: "p", queued: queued).writes.isEmpty)
    // The dispatch completes refused: settled, and the next flush owes the write again.
    queued = apiQueuedSettled(queued, written: first.written)
    #expect(queued.isEmpty)
    #expect(apiFlush(req(), held: held, pane: "p", queued: queued).written == held)
    // A later dispatch at newer parts stays queued when the older one settles.
    let newer: ApiHeld = [body: [.literal("xy")]]
    #expect(apiQueuedSettled(newer, written: held) == newer)
}

@Test("Lesson: a takeover settles by token, on its own dispatch's completion only")
func aTakeoverSettlesByToken() {
    let parts: [ApiPart] = [.literal("x")]
    let first = ApiHeldTakeover(held: parts, token: 1)
    let second = ApiHeldTakeover(held: parts, token: 2)
    // Two quick gestures at the same parts: the second's entry replaced the first's.
    let settled = apiGestureSettled(takenOver: [body: second], held: [body: parts],
                                    carried: [body: first], landed: false)
    #expect(settled.takenOver == [body: second])
    #expect(settled.held == [body: parts])
    #expect(settled.owed == false)
    // Still taken over, no flush writes it behind the second gesture.
    #expect(apiFlush(req(), held: settled.held, pane: "p", takenOver: settled.takenOver).writes.isEmpty)
    // A landing in between keeps it too: only the gesture's dispatch settles it.
    #expect(apiHeldAfterLanding(req(body: [.literal("q")]), held: [body: parts], focused: nil,
                                takenOver: [body: second]) == [body: parts])
    // Typed past, the entry is spent.
    #expect(apiTakenOverSettled([body: second], held: [body: [.literal("xy")]]).isEmpty)
    #expect(apiTakenOverSettled([body: second], held: [body: parts]) == [body: second])
}

@Test("Lesson: Escape's restore is built against the stored draft at its turn, not the held parts")
func escapeRestoreAgainstTheStoredDraft() {
    // Path /a, type X, the pause writes /aX, backspace to /a, Escape.
    let focusIn = ApiFocusedField(box: path, request: req(path: [.literal("/a")]))
    let stored = req(path: [.literal("/aX")])
    #expect(apiRestoreCalls(focusIn, box: path, draft: stored, pane: "p").map(\.1)
        == [apiPathQueryWrite(path: [.literal("/a")], query: [], pane: "p")])
    // The screen (draft with the held /a applied) reads /a, which is why it is not the baseline.
    #expect(apiRequestApplying(stored, held: [path: [.literal("/a")]]).path == [.literal("/a")])
}

@Test("A row's × lets go every held field of that name at or after the row")
func removingARowLetsGoLaterHeld() {
    let a0 = ApiFieldRow(.query("a")), a1 = ApiFieldRow(.query("a"), row: 1)
    let a2 = ApiFieldRow(.query("a"), row: 2), b0 = ApiFieldRow(.query("b"))
    let held: ApiHeld = [a0: [.literal("0")], a1: [.literal("1")], a2: [.literal("2")],
                         b0: [.literal("b")], body: [.literal("{}")]]
    #expect(apiBoxesRemovingRow(held, region: .query, name: "a", row: 1)
        == [a0: [.literal("0")], b0: [.literal("b")], body: [.literal("{}")]])
}

@Test("Send refused: nothing is sent while a held field's write is refused")
func sendRefusedByAHeldField() {
    let plan = apiSendPlan(draft: req(), pane: "p", held: [path: [.literal("/o?=x")], body: [.literal("{}")]])
    #expect(plan.calls.isEmpty)
    #expect(plan.refusals == [path: ApiPathQueryRefusal.namelessRow.line])
    #expect(plan.written.isEmpty)
}

@Test("Send unpointed: the held fields are written, the send withheld")
func sendUnpointedWritesOnly() {
    let plan = apiSendPlan(draft: req(), pane: "p", held: [body: [.literal("{}")]], unpointed: true)
    #expect(plan.calls.map(\.0) == ["api_set_request"])
    #expect(plan.refusal == apiPickAnEntryFirst)
    #expect(plan.written == [body: [.literal("{}")]])
}

@Test("apiHeldWrite writes the field whole, and nothing for a field that holds no parts")
func heldWriteShapes() {
    #expect(apiHeldWrite(draft: req(), field: .path, parts: [.literal("/a"), .literal("")], pane: "p")
        == .object(["pane": .string("p"), "path": .array([lit("/a")])]))
    #expect(apiHeldWrite(draft: req(), field: .contentType, parts: [.literal("x")], pane: "p") == nil)
    #expect(apiHeldWrite(draft: req(), field: .method, parts: [], pane: "p") == nil)
}

// MARK: - Fix round 1: one write per region per flush

private func queryJSON(_ rows: [(String, [JSONValue])]) -> JSONValue {
    .array(rows.map { .object(["name": .string($0.0), "value": .array($0.1)]) })
}

@Test("Fix 1: two held query rows flush as ONE write of the region, neither edit lost")
func twoHeldQueryRowsAreOneWrite() {
    let r = req(query: [q("a", [.literal("A")]), q("b", [.literal("B")])])
    let a = ApiFieldRow(.query("a")), b = ApiFieldRow(.query("b"))
    let held: ApiHeld = [a: [.literal("A2")], b: [.literal("B2")]]
    let flush = apiFlush(r, held: held, pane: "p")
    #expect(flush.writes.map(\.0) == ["api_set_request"])
    #expect(flush.writes.map(\.1) == [.object(["pane": .string("p"), "query": queryJSON([
        ("a", [lit("A2")]), ("b", [lit("B2")]),
    ])])])
    #expect(flush.written == held)
    #expect(flush.refusals.isEmpty)
}

@Test("Fix 1: two held header rows flush as ONE write of the region")
func twoHeldHeaderRowsAreOneWrite() {
    let headers = ApiRequestSnapshot.empty.headers + [
        .operatorRow(name: "x-a", value: [.literal("1")]),
        .operatorRow(name: "x-b", value: [.literal("2")]),
    ]
    let a = ApiFieldRow(.header("x-a")), b = ApiFieldRow(.header("x-b"))
    let held: ApiHeld = [a: [.literal("8")], b: [.literal("9")]]
    let flush = apiFlush(req(headers: headers), held: held, pane: "p")
    #expect(flush.writes.map(\.1) == [.object(["pane": .string("p"), "headers": queryJSON([
        ("x-a", [lit("8")]), ("x-b", [lit("9")]),
    ])])])
    #expect(flush.written == held)
}

@Test("Fix 1: the path view and a held query row flush as ONE write, neither edit lost")
func pathViewAndQueryRowAreOneWrite() {
    let r = req(path: [.literal("/o")], query: [q("a", [.literal("0")])])
    let a = ApiFieldRow(.query("a"))
    let held: ApiHeld = [path: [.literal("/new?a=0")], a: [.literal("9")]]
    let flush = apiFlush(r, held: held, pane: "p")
    #expect(flush.writes.map(\.1)
        == [apiPathQueryWrite(path: [.literal("/new")], query: [q("a", [.literal("9")])], pane: "p")])
    #expect(flush.written == held)
}

@Test("Fix 1, ruled: a refused path view is refused alone; the held query rows still write")
func aRefusedPathViewLetsQueryRowsWrite() {
    let r = req(path: [.literal("/o")], query: [q("a", [.literal("0")])])
    let a = ApiFieldRow(.query("a"))
    let flush = apiFlush(r, held: [path: [.literal("/o?=x")], a: [.literal("9")]], pane: "p")
    #expect(flush.refusals == [path: ApiPathQueryRefusal.namelessRow.line])
    #expect(flush.writes.map(\.1) == [.object(["pane": .string("p"), "query": queryJSON([
        ("a", [lit("9")]),
    ])])])
    #expect(flush.written == [a: [.literal("9")]])
}

@Test("Fix 1: a taken-over row stays at its stored value in the region's write; a queued one at its queued parts")
func skippedRowsInTheRegionWrite() {
    let r = req(query: [q("a", [.literal("A")]), q("b", [.literal("B")]), q("c", [.literal("C")])])
    let a = ApiFieldRow(.query("a")), b = ApiFieldRow(.query("b")), c = ApiFieldRow(.query("c"))
    let held: ApiHeld = [a: [.literal("A2")], b: [.literal("B2")], c: [.literal("C2")]]
    let flush = apiFlush(r, held: held, pane: "p", queued: [b: [.literal("B2")]],
                         takenOver: [c: ApiHeldTakeover(held: [.literal("C2")], token: 4)])
    #expect(flush.writes.map(\.1) == [.object(["pane": .string("p"), "query": queryJSON([
        ("a", [lit("A2")]), ("b", [lit("B2")]), ("c", [lit("C")]),
    ])])])
    // Only the row this flush owes is recorded: b is already queued, c is the gesture's.
    #expect(flush.written == [a: [.literal("A2")]])
    // Skipped rows alone owe no write.
    #expect(apiFlush(r, held: [b: [.literal("B2")]], pane: "p", queued: [b: [.literal("B2")]]).writes.isEmpty)
}

@Test("Fix 1: Send with two held rows dispatches one region write, then the send")
func sendWithTwoHeldRows() {
    let r = req(query: [q("a", [.literal("A")]), q("b", [.literal("B")])])
    let held: ApiHeld = [ApiFieldRow(.query("a")): [.literal("A2")], ApiFieldRow(.query("b")): [.literal("B2")]]
    let plan = apiSendPlan(draft: r, pane: "p", held: held)
    #expect(plan.calls.map(\.0) == ["api_set_request", "api_send"])
    #expect(plan.written == held)
}

@Test("Task 5 carry: the pane's last flush is built at its turn — built before an unbind lands, it would bind the value again")
func theLastFlushIsBuiltAtItsTurnNeverBeforeAGestureLands() {
    // The body holds a typed space beside a bound value, and its unbind is on the chain.
    let bound = liveBinding(name: "id")
    let held: ApiHeld = [body: [.literal("{\"a\": "), .bound(bound), .literal("}")]]
    let beforeUnbind = req(body: [.literal("{\"a\":"), .bound(bound), .literal("}")])
    let afterUnbind = req(body: [.literal("{\"a\":"), .slot("id"), .literal("}")])
    // Built out of turn, on the draft before the unbind, it writes the binding — landing after
    // the unbind, it would make the binding again (W16) and revert the gesture.
    #expect(apiFlush(beforeUnbind, held: held, pane: "p").writes.map(\.1)
        == [.object(["pane": .string("p"), "body": .array([
            lit("{\"a\": "), apiPartJSON(.bound(bound), sources: [:]), lit("}")])])])
    // Built at its turn (`flushNow` captures the held parts and builds on the chain), it writes
    // the hole the unbind left.
    #expect(apiFlush(afterUnbind, held: held, pane: "p").writes.map(\.1)
        == [.object(["pane": .string("p"), "body": .array([lit("{\"a\": "), slot("id"), lit("}")])])])
}
