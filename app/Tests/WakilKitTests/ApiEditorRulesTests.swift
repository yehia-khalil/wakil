import Foundation
import Testing
@testable import WakilKit

/// Amendment 10b: a token is one atomic character, and these are its rules.

private func text(_ parts: [ApiPart]) -> ApiEditorText { ApiEditorText(parts: parts) }

@Test("Backspace just after a hole removes it as one character")
func backspaceAfterAHoleRemovesIt() {
    let t = text([.literal("/a/"), .slot("id"), .literal("/b")])
    #expect(apiEditorVerdict(t, replacing: 3..<4, with: "", insertedTokens: [], replaying: false, key: .backspace, singleLine: true) == .allow)
    #expect(apiEditorVerdict(t, replacing: 3..<4, with: "", insertedTokens: [], replaying: false, key: .delete, singleLine: true) == .allow)
}

@Test("W4/W16: Backspace or Delete on a bound value unbinds it, by its ordinal among the tokens")
func aKeyOnABoundValueUnbindsIt() {
    let bound = liveBinding(name: "v")
    let t = text([.slot("x"), .literal("/"), .bound(bound)])
    #expect(apiEditorVerdict(t, replacing: 2..<3, with: "", insertedTokens: [], replaying: false, key: .backspace, singleLine: true)
        == .unbind(ordinal: 1, name: "v"))
    #expect(apiEditorVerdict(t, replacing: 2..<3, with: "", insertedTokens: [], replaying: false, key: .delete, singleLine: false)
        == .unbind(ordinal: 1, name: "v"))
}

@Test("M17: Option-Backspace (delete word) reaching a bound value is refused, never an unbind")
func aWordDeleteOnABoundValueIsRefused() {
    // The editor names a key only for plain Backspace and Delete; a word delete comes keyless.
    let t = text([.literal("a "), .bound(liveBinding(name: "v")), .literal(" b")])
    #expect(apiEditorVerdict(t, replacing: 2..<3, with: "", insertedTokens: [], replaying: false, singleLine: true)
        == .refuse(apiBoundSelectionLine))
    #expect(apiEditorVerdict(t, replacing: 0..<3, with: "", insertedTokens: [], replaying: false, singleLine: true)
        == .refuse(apiBoundSelectionLine))
    // A hole reached the same way goes as text.
    let hole = text([.literal("a "), .slot("x"), .literal(" b")])
    #expect(apiEditorVerdict(hole, replacing: 2..<3, with: "", insertedTokens: [], replaying: false, singleLine: true) == .allow)
}

@Test("P8: a held key's repeat never acts on a token, hole or bound")
func aRepeatNeverActsOnAToken() {
    let t = text([.slot("x"), .bound(liveBinding(name: "v"))])
    #expect(apiEditorVerdict(t, replacing: 0..<1, with: "", insertedTokens: [], replaying: false, key: .backspace, isRepeat: true,
                             singleLine: true) == .ignore)
    #expect(apiEditorVerdict(t, replacing: 1..<2, with: "", insertedTokens: [], replaying: false, key: .backspace, isRepeat: true,
                             singleLine: true) == .ignore)
}

@Test("P8: a held key's repeat still eats text up to the token")
func aRepeatEatsText() {
    let t = text([.slot("x"), .literal("ab")])
    #expect(apiEditorVerdict(t, replacing: 2..<3, with: "", insertedTokens: [], replaying: false, key: .backspace, isRepeat: true,
                             singleLine: true) == .allow)
}

@Test("A selection holding holes deletes them as text")
func aSelectionWithHolesDeletesAsText() {
    let t = text([.literal("a"), .slot("x"), .literal("b"), .slot("y")])
    #expect(apiEditorVerdict(t, replacing: 0..<4, with: "", insertedTokens: [], replaying: false, key: .backspace, singleLine: true) == .allow)
    #expect(apiEditorVerdict(t, replacing: 0..<4, with: "z", insertedTokens: [], replaying: false, singleLine: true) == .allow)
}

@Test("W16: a selection holding a bound value is refused, deleted or replaced, on the field's line")
func aSelectionWithABoundValueIsRefused() {
    let t = text([.literal("a"), .bound(liveBinding(name: "v")), .literal("b")])
    #expect(apiEditorVerdict(t, replacing: 0..<3, with: "", insertedTokens: [], replaying: false, key: .backspace, singleLine: true)
        == .refuse(apiBoundSelectionLine))
    #expect(apiEditorVerdict(t, replacing: 0..<3, with: "x", insertedTokens: [], replaying: false, singleLine: true)
        == .refuse(apiBoundSelectionLine))
}

@Test("Ambiguity 6: dragging a bound value out leaves the source whole, silently")
func dragOutOfABoundSelectionIsIgnored() {
    let t = text([.literal("a"), .bound(liveBinding(name: "v"))])
    #expect(apiEditorVerdict(t, replacing: 0..<2, with: "", insertedTokens: [], replaying: false, draggingOut: true, singleLine: true) == .ignore)
}

@Test("Review Focus 1: a composition never acts on a token")
func aCompositionNeverActsOnAToken() {
    let t = text([.literal("a"), .slot("x"), .bound(liveBinding(name: "v"))])
    // The key belongs to the input method while text is marked.
    #expect(apiEditorVerdict(t, replacing: 1..<2, with: "", insertedTokens: [], replaying: false, key: .backspace, composing: true,
                             singleLine: true) == .ignore)
    #expect(apiEditorVerdict(t, replacing: 2..<3, with: "", insertedTokens: [], replaying: false, key: .backspace, composing: true,
                             singleLine: true) == .ignore)
    // A composition that would replace a selection holding a bound value is refused.
    #expect(apiEditorVerdict(t, replacing: 0..<3, with: "か", insertedTokens: [], replaying: false, composing: true, singleLine: true)
        == .refuse(apiBoundSelectionLine))
}

@Test("A single-line field takes no line break: it is substituted out")
func aSingleLineFieldTakesNoBreak() {
    let t = text([.literal("/a")])
    #expect(apiEditorVerdict(t, replacing: 2..<2, with: "b\nc", insertedTokens: [], replaying: false, singleLine: true) == .substitute("bc"))
    #expect(apiEditorVerdict(t, replacing: 2..<2, with: "b\r\nc", insertedTokens: [], replaying: false, singleLine: true) == .substitute("bc"))
    #expect(apiEditorVerdict(t, replacing: 2..<2, with: "b\nc", insertedTokens: [], replaying: false, singleLine: false) == .allow)
}

@Test("10b: copying a bound value carries its HOLE; outside Wakil it reads <name>")
func aCopyCarriesHolesOnly() {
    let t = text([.literal("/a/"), .bound(liveBinding(name: "id")), .literal("/"), .slot("x")])
    let clip = ApiEditorClip(t, range: 0..<6)
    #expect(clip.text.parts == [.literal("/a/"), .slot("id"), .literal("/"), .slot("x")])
    #expect(clip.plain == "/a/<id>/<x>")
    let alone = ApiEditorClip(t, range: 3..<4)
    #expect(alone.runs == [.hole("id")])
    #expect(alone.plain == "<id>")
}

@Test("10b: Wakil's own clip pastes tokens; outside text pastes literal, <id> and all")
func pastes() {
    let clip = ApiEditorClip(text([.slot("id"), .literal("\n/b")]), range: 0..<4)
    #expect(apiEditorPasted(clip: clip, plain: "<id>/b", singleLine: true)?.parts
        == [.slot("id"), .literal("/b")])
    #expect(apiEditorPasted(clip: clip, plain: "<id>/b", singleLine: false)?.parts
        == [.slot("id"), .literal("\n/b")])
    #expect(apiEditorPasted(clip: nil, plain: "<id>/b", singleLine: true)?.parts == [.literal("<id>/b")])
    #expect(apiEditorPasted(clip: nil, plain: nil, singleLine: true) == nil)
}

@Test("Spike: a bare U+FFFC from outside is a token that lost its attachment, and is dropped")
func aBareAttachmentCharacterPastesAsNothing() {
    #expect(apiEditorPasted(clip: nil, plain: "a\u{FFFC}b", singleLine: true)?.parts == [.literal("ab")])
    #expect(apiEditorPasted(clip: nil, plain: "\u{FFFC}", singleLine: true)?.parts == [])
}

@Test("The clip survives the pasteboard: it encodes and decodes to itself")
func theClipRoundTripsThroughJSON() throws {
    let clip = ApiEditorClip(text([.literal("a"), .slot("x")]), range: 0..<2)
    let data = try JSONEncoder().encode(clip)
    #expect(try JSONDecoder().decode(ApiEditorClip.self, from: data) == clip)
    #expect(apiEditorPasteboardType == "com.wakil.api.editor-text")
}

@Test("10b: a same-field drag moves the selection, the bound value with it")
func aSameFieldDragMoves() {
    let bound = liveBinding(name: "id")
    let t = text([.literal("ab"), .bound(bound), .literal("cd")])
    let moved = apiEditorMoving(t, range: 2..<3, to: 5)
    #expect(moved?.text.parts == [.literal("abcd"), .bound(bound)])
    #expect(moved?.selection == 4..<5)
    let back = apiEditorMoving(t, range: 2..<3, to: 0)
    #expect(back?.text.parts == [.bound(bound), .literal("abcd")])
    #expect(back?.selection == 0..<1)
    #expect(apiEditorMoving(t, range: 2..<3, to: 3) == nil)
    #expect(apiEditorMoving(t, range: 2..<3, to: 2) == nil)
    #expect(apiEditorMoving(t, range: 2..<2, to: 0) == nil)
}

@Test("10b: + hole lands at the caret, or the selection's end, and never replaces text")
func aHoleLandsAtTheCaret() {
    let t = text([.literal("{\"a\":1}")])
    #expect(apiEditorHoleOffset(t, selection: 6..<6, isPathView: false) == 6)
    #expect(apiEditorHoleOffset(t, selection: 2..<4, isPathView: false) == 4)
    // A caret in the path view goes where it is, even past the `?` (ambiguity 2).
    #expect(apiEditorHoleOffset(text([.literal("/o?p=2")]), selection: 6..<6, isPathView: true) == 6)
    // A stale selection past the end is clamped to it.
    #expect(apiEditorHoleOffset(t, selection: 40..<40, isPathView: false) == 7)
}

@Test("A field the caret has not been in takes + hole at the end; the path view at the PATH's end")
func aNeverFocusedFieldTakesTheHoleAtItsEnd() {
    #expect(apiEditorHoleOffset(text([.literal("{}")]), selection: nil, isPathView: false) == 2)
    // I4: before the `?`, never inside the last query value.
    let view = text([.literal("/orders?page=2")])
    #expect(apiEditorHoleOffset(view, selection: nil, isPathView: true) == 7)
    #expect(apiEditorHoleOffset(text([.literal("/orders")]), selection: nil, isPathView: true) == 7)
    // A token counts one, and a `?` in a hole's NAME is not the path's end.
    let tokens = text([.literal("/a/"), .slot("q?"), .literal("/b?x=1")])
    #expect(apiEditorHoleOffset(tokens, selection: nil, isPathView: true) == 6)
}

@Test("A blank hole name is refused in its own words; any other name is taken exactly")
func blankHoleNames() {
    #expect(apiHoleNameRefused("  ") == apiHoleNameRefusal)
    #expect(apiHoleNameRefused("") == apiHoleNameRefusal)
    #expect(apiHoleNameRefused(" id ") == nil)
}

@Test("C4: a hole's × is drawn only where the field is editable; a bound value's always (spec §3)")
func theTokenCloseIsShown() {
    #expect(apiTokenCloseShown(editable: true, isBound: false) == true)
    #expect(apiTokenCloseShown(editable: false, isBound: false) == false)
    #expect(apiTokenCloseShown(editable: true, isBound: true) == true)
    #expect(apiTokenCloseShown(editable: false, isBound: true) == true)
}

@Test("C4/ambiguity 5: an outside change maps the selection while focused, else puts it at the end")
func anOutsideChangePlacesTheCaret() {
    let old = text([.literal("ab"), .slot("x"), .literal("cd")])
    let new = text([.literal("ab"), .bound(liveBinding(name: "x")), .literal("cd")])
    // An unbind landing: the caret just after the token stays just after it.
    #expect(apiEditorSelection(from: old, to: new, selection: 3..<3, focused: true) == 3..<3)
    #expect(apiEditorSelection(from: old, to: new, selection: 3..<3, focused: false) == 5..<5)
}

@Test("W16 fix round 1: an insertion carrying a bound value is refused; a hole inserted is allowed")
func anInsertionCarryingABoundValueIsRefused() {
    let bound = liveBinding(name: "v")
    let t = text([.literal("ab")])
    // An undo of a move after the value was unbound, a stale undo record, a native drop: the
    // insertion would MAKE a binding the draft no longer has.
    #expect(apiEditorVerdict(t, replacing: 0..<0, with: "\u{FFFC}", insertedTokens: [.bound(bound)], replaying: false,
                             singleLine: true) == .refuse(apiBoundSelectionLine))
    #expect(apiEditorVerdict(t, replacing: 0..<2, with: "x\u{FFFC}", insertedTokens: [.bound(bound)], replaying: false,
                             singleLine: false) == .refuse(apiBoundSelectionLine))
    // Wakil's own paste of a hole stays allowed.
    #expect(apiEditorVerdict(t, replacing: 0..<0, with: "\u{FFFC}", insertedTokens: [.hole("id")], replaying: false,
                             singleLine: true) == .allow)
}

@Test("Fix round 1: a single-line field's substitute never carries a U+FFFC")
func aSingleLineSubstituteCarriesNoAttachmentCharacter() {
    let t = text([.literal("/a")])
    #expect(apiEditorVerdict(t, replacing: 2..<2, with: "\u{FFFC}\n", insertedTokens: [], replaying: false, singleLine: true) == .substitute(""))
    #expect(apiEditorVerdict(t, replacing: 2..<2, with: "b\u{FFFC}\nc", insertedTokens: [], replaying: false, singleLine: true) == .substitute("bc"))
}

@Test("Final review I1: a plain insert carrying a bare U+FFFC is stripped of it, in every field")
func aPlainInsertCarryingABareAttachmentCharacterIsStripped() {
    // The Character Viewer, an accessibility value set: a string with a U+FFFC and no attachment.
    // Left in storage it would shift every storage offset off the model's (`editorText` drops it).
    let t = text([.literal("a"), .bound(liveBinding(name: "v")), .literal("b")])
    #expect(apiEditorVerdict(t, replacing: 0..<0, with: "x\u{FFFC}y", insertedTokens: [], replaying: false,
                             singleLine: false) == .substitute("xy"))
    #expect(apiEditorVerdict(t, replacing: 0..<0, with: "x\u{FFFC}y", insertedTokens: [], replaying: false,
                             singleLine: true) == .substitute("xy"))
    // Nothing left to insert: nothing changes.
    #expect(apiEditorVerdict(t, replacing: 0..<0, with: "\u{FFFC}", insertedTokens: [], replaying: false,
                             singleLine: false) == .ignore)
    #expect(apiEditorVerdict(t, replacing: 3..<3, with: "\u{FFFC}\u{FFFC}", insertedTokens: [], replaying: false,
                             singleLine: true) == .ignore)
}

@Test("Final review I1: no bare U+FFFC before a bound value, so Backspace after it still unbinds")
func aBareAttachmentCharacterNeverShiftsABoundValuesKey() {
    // The reviewer's path: a bare U+FFFC typed before a bound value made the storage one unit
    // longer than the model, and Backspace after the value checked the wrong unit and was allowed:
    // AppKit deleted the attachment and the binding went silently (W16). The strip keeps it out.
    let t = text([.literal("a"), .bound(liveBinding(name: "v"))])
    let typed = apiEditorVerdict(t, replacing: 0..<0, with: "\u{FFFC}", insertedTokens: [], replaying: false,
                                 singleLine: false)
    #expect(typed == .ignore)
    #expect(apiEditorVerdict(t, replacing: 1..<2, with: "", insertedTokens: [], replaying: false,
                             key: .backspace, singleLine: false) == .unbind(ordinal: 0, name: "v"))
}

@Test("Final review I1: an undo or redo replay keeps its U+FFFC — it restores attachments")
func anUndoReplayKeepsItsAttachmentCharacters() {
    let t = text([.literal("ab")])
    #expect(apiEditorVerdict(t, replacing: 1..<1, with: "\u{FFFC}", insertedTokens: [], replaying: true,
                             singleLine: false) == .allow)
    #expect(apiEditorVerdict(t, replacing: 1..<1, with: "x\u{FFFC}", insertedTokens: [], replaying: true,
                             singleLine: true) == .allow)
    // Wakil's own insertion names its tokens, and keeps their characters.
    #expect(apiEditorVerdict(t, replacing: 1..<1, with: "\u{FFFC}", insertedTokens: [.hole("id")], replaying: false,
                             singleLine: false) == .allow)
}

@Test("Fix round 1: a move to an offset outside the text moves nothing")
func aMoveOutsideTheTextIsNil() {
    let t = text([.literal("ab"), .bound(liveBinding(name: "id")), .literal("cd")])
    #expect(apiEditorMoving(t, range: 0..<1, to: 6) == nil)
    #expect(apiEditorMoving(t, range: 2..<3, to: -1) == nil)
    #expect(apiEditorMoving(t, range: 0..<1, to: 5)?.selection == 4..<5)
}

@Test("W16, Task 5: a change that leaves more copies of a binding than before made one; a move, a hole or an unbind did not")
func aChangeThatAddsABindingMadeOne() {
    let v = liveBinding(name: "v")
    let w = liveBinding(name: "w")
    let before = text([.literal("a"), .bound(v)])
    // A second copy of a binding the field holds (an undo replaying a drop, say).
    #expect(apiEditorMadeBinding(from: before, to: text([.literal("a"), .bound(v), .bound(v)])))
    // A binding where its hole was.
    #expect(apiEditorMadeBinding(from: text([.literal("a"), .slot("v")]), to: before))
    // A binding the field never held.
    #expect(apiEditorMadeBinding(from: before, to: text([.literal("a"), .bound(v), .bound(w)])))
    // Fewer bindings in all, and still one made: two of `v` gone, one `w` arrived.
    #expect(apiEditorMadeBinding(from: text([.bound(v), .bound(v)]), to: text([.bound(w)])))
    // A move within the field, typing, a hole, and an unbind make none.
    #expect(!apiEditorMadeBinding(from: before, to: text([.bound(v), .literal("a")])))
    #expect(!apiEditorMadeBinding(from: before, to: text([.literal("ab"), .bound(v), .slot("x")])))
    #expect(!apiEditorMadeBinding(from: before, to: text([.literal("a"), .slot("v")])))
}

@Test("Task 6: a move is undoable only while the field holds no bound value, wherever it sits")
func aMoveIsUndoableOnlyWithNoBoundValueInTheField() {
    let v = liveBinding(name: "v")
    // A move's undo replaces the whole field, so a bound value anywhere in it — moved or not —
    // would be refused, and a refused replay leaves the stack stale (Ruling 12).
    #expect(!apiEditorMoveIsUndoable(text([.bound(v), .literal("ab")])))
    #expect(!apiEditorMoveIsUndoable(text([.literal("ab"), .slot("x"), .bound(v)])))
    #expect(apiEditorMoveIsUndoable(text([.literal("ab"), .slot("x")])))
    #expect(apiEditorMoveIsUndoable(text([])))
}

// MARK: #342 — an accessibility client's whole-value set, narrowed to what it changed

private let mark = "\u{FFFC}"

@Test("#342: appending after holes keeps every hole")
func aWholeValueSetThatAppendsKeepsTheHoles() throws {
    let t = text([.slot("a"), .literal("/"), .slot("b")])
    let narrowed = try #require(apiEditorNarrowed(t, to: mark + "/" + mark + "x", singleLine: true))
    #expect(narrowed.range == 3..<3)
    #expect(narrowed.inserted == text([.literal("x")]))
    #expect(t.replacing(narrowed.range, with: narrowed.inserted).parts
        == [.slot("a"), .literal("/"), .slot("b"), .literal("x")])
}

@Test("#342: typing beside a bound value touches only the typed range, so the verdict allows it")
func aWholeValueSetBesideABoundValueIsAllowed() throws {
    let t = text([.literal("a"), .bound(liveBinding(name: "v")), .literal("b")])
    let narrowed = try #require(apiEditorNarrowed(t, to: "a" + mark + "Xb", singleLine: true))
    #expect(narrowed.range == 2..<2)
    #expect(narrowed.inserted == text([.literal("X")]))
    #expect(apiEditorVerdict(t, replacing: narrowed.range, with: "X", insertedTokens: [],
                             replaying: false, singleLine: true) == .allow)
}

@Test("#342: a value with no mark where a token stood replaces that token, as asked")
func aWholeValueSetWithoutTheMarkReplacesTheToken() throws {
    let t = text([.slot("id")])
    let narrowed = try #require(apiEditorNarrowed(t, to: "abc", singleLine: true))
    #expect(narrowed.range == 0..<1)
    #expect(narrowed.inserted == text([.literal("abc")]))
}

@Test("#342: the same value changes nothing")
func aWholeValueSetToTheSameValueIsNothing() {
    let t = text([.literal("/a/"), .slot("id")])
    #expect(apiEditorNarrowed(t, to: "/a/" + mark, singleLine: true) == nil)
}

@Test("#342: a mark in the changed middle names no token and is dropped")
func aMarkInTheChangedMiddleIsDropped() throws {
    let t = text([.literal("a")])
    let narrowed = try #require(apiEditorNarrowed(t, to: "a" + mark + "b", singleLine: true))
    #expect(narrowed.range == 1..<1)
    #expect(narrowed.inserted == text([.literal("b")]))
}

@Test("#342: a single-line field takes the inserted text on one line")
func aWholeValueSetInASingleLineFieldDropsLineBreaks() throws {
    let t = text([.literal("a")])
    let narrowed = try #require(apiEditorNarrowed(t, to: "a\nb", singleLine: true))
    #expect(narrowed.inserted == text([.literal(apiSingleLineText("\nb"))]))
    let multi = try #require(apiEditorNarrowed(t, to: "a\nb", singleLine: false))
    #expect(multi.inserted == text([.literal("\nb")]))
}

@Test("#342: the changed range never splits a surrogate pair")
func aWholeValueSetNeverSplitsASurrogatePair() throws {
    // 😀 and 😃 share their lead surrogate (D83D) and differ in the trail.
    let t = text([.literal("a😀")])
    let narrowed = try #require(apiEditorNarrowed(t, to: "a😃", singleLine: true))
    #expect(narrowed.range == 1..<3)
    #expect(narrowed.inserted == text([.literal("😃")]))
}
