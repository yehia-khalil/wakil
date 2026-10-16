import Foundation
import Testing
@testable import WakilKit

/// W4, W16: a bound token's Backspace, Delete or `×` unbinds it, built on the chain behind the
/// flush (P10) and addressed by the token's ordinal among the field's tokens (Review Focus 3).
/// Kept from `ApiChipKeysTests` when the editor's verdict (`apiEditorVerdict`) replaced the keys.

private let bound = ApiPart.bound(liveBinding(name: "v"))

private func snap(path: [ApiPart], query: [ApiQueryRow] = [], body: [ApiPart] = []) -> ApiRequestSnapshot {
    ApiRequestSnapshot(method: "POST", origin: nil, path: path, query: query,
                       headers: ApiRequestSnapshot.empty.headers, body: body)
}

@Test("Review Focus 3: an unbind after an emptied box targets the same chip, by its ordinal")
func anUnbindAfterAnEmptiedBoxTargetsTheSameChip() {
    let r = snap(path: [.literal("/a/"), bound, .literal("/x")])
    // The token sits after "/a/", three UTF-16 units in.
    let ordinal = ApiEditorText(parts: apiFieldViewParts(r, .path)).ordinal(ofTokenAt: 3)
    #expect(ordinal == 0)
    // The operator emptied the first box. The flush drops that literal, so the chip is at 0, and
    // the unbind, built on the chain behind the flush, finds it there.
    let flushed = apiRequestApplying(r, held: [ApiFieldRow(.path): [bound, .literal("/x")]])
    #expect(apiChipUnbindParams(flushed, field: .path, row: 0, ordinal: 0, name: "v", pane: "p")
        == apiUnbindParams(field: .path, index: 0, pane: "p"))
    // Nothing typed: the drawn index.
    #expect(apiChipUnbindParams(r, field: .path, row: 0, ordinal: 0, name: "v", pane: "p")
        == apiUnbindParams(field: .path, index: 1, pane: "p"))
}

@Test("P10: an unbind whose chip is no longer that binding sends nothing")
func anUnbindOfAChipThatMovedSendsNothing() {
    // A remove in flight ahead of it took a chip away, and the ordinal now names another.
    let r = snap(path: [.literal("/a/"), .bound(liveBinding(name: "w"))])
    #expect(apiChipUnbindParams(r, field: .path, row: 0, ordinal: 0, name: "v", pane: "p") == nil)
    // Or an unbind ahead of it already made it a hole.
    #expect(apiChipUnbindParams(
        snap(path: [.slot("v")]), field: .path, row: 0, ordinal: 0, name: "v", pane: "p") == nil)
    // Or there is no such chip at all.
    #expect(apiChipUnbindParams(
        snap(path: [.literal("/a")]), field: .path, row: 0, ordinal: 0, name: "v", pane: "p") == nil)
}

@Test("A chip the path box draws from a query value unbinds in its row")
func aQueryChipInThePathBoxUnbindsInItsRow() {
    let r = snap(path: [.literal("/o")], query: [ApiQueryRow(name: "id", value: [bound])])
    #expect(apiChipUnbindParams(r, field: .path, row: 0, ordinal: 0, name: "v", pane: "p")
        == apiUnbindParams(field: .query("id"), index: 0, pane: "p", row: 0))
}

@Test("A body chip unbinds by its index in the body")
func aBodyChipUnbinds() {
    let r = snap(path: [], body: [.literal("{\"a\": "), .slot("s"), bound, .literal("}")])
    #expect(apiChipUnbindParams(r, field: .body, row: 0, ordinal: 1, name: "v", pane: "p")
        == apiUnbindParams(field: .body, index: 2, pane: "p"))
}

@Test("A chip's × removes a hole and unbinds a bound value; a literal is text, not a chip")
func aChipsActIsItsKind() {
    #expect(apiChipAct(.literal("/a")) == nil)
    #expect(apiChipAct(.slot("id")) == .remove)
    #expect(apiChipAct(bound) == .unbind)
}

@Test("Only an &-locked path view is read-only; a body beside a binding stays typable (W16)")
func onlyAnAmpersandLockedPathViewIsReadOnly() {
    let locked = snap(path: [.literal("/o")], query: [ApiQueryRow(name: "q", value: [.literal("a&b")])])
    #expect(!apiFieldViewIsTypable(locked, .path))
    #expect(apiFieldViewIsTypable(snap(path: [.literal("/o")]), .path))
    #expect(apiFieldViewIsTypable(snap(path: [], body: [.literal("x"), bound]), .body))
}
