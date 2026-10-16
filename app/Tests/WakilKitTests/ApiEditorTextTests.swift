import Foundation
import Testing
@testable import WakilKit

/// Amendment 10a: a field is one editor's text, and a hole or a bound value is one token in it.

@Test("Parts round-trip exactly: adjacent literals merge, empty ones drop, tokens keep identity")
func partsRoundTripExactly() {
    let bound = liveBinding(name: "id")
    let parts: [ApiPart] = [
        .literal("/a"), .literal(""), .literal("/"), .slot("x"), .bound(bound), .literal(""),
    ]
    let text = ApiEditorText(parts: parts)
    #expect(text.parts == [.literal("/a/"), .slot("x"), .bound(bound)])
    #expect(text.parts == apiMergedLiterals(parts))
    #expect(ApiEditorText(parts: text.parts) == text)
    #expect(ApiEditorText(units: text.units) == text)
    #expect(ApiEditorText(runs: text.runs) == text)
}

@Test("A token is one unit and text counts UTF-16, as NSTextView does")
func aTokenIsOneUnit() {
    let text = ApiEditorText(parts: [.literal("é😀"), .slot("id"), .literal("/b")])
    // é = 1 unit, 😀 = 2 units, the token = 1, "/b" = 2.
    #expect(text.length == 6)
    #expect(text.token(at: 3) == .hole("id"))
    #expect(text.token(at: 2) == nil)
}

@Test("Review Focus 5: a token is one unit wherever it sits — first, last, between tokens")
func aTokenIsOneUnitWhereverItSits() {
    let text = ApiEditorText(parts: [.slot("a"), .slot("b"), .literal("x"), .slot("c")])
    #expect(text.length == 4)
    #expect(text.token(at: 0) == .hole("a"))
    #expect(text.token(at: 1) == .hole("b"))
    #expect(text.token(at: 3) == .hole("c"))
    #expect(text.ordinal(ofTokenAt: 3) == 2)
    #expect(text.partIndex(ofTokenAt: 3) == 3)
    #expect(text.partIndex(ofTokenAt: 2) == nil)
}

@Test("A token's index is its index among the editor's parts — the identifiers' <i>")
func aTokensPartIndexIsAmongTheMergedParts() {
    let text = ApiEditorText(parts: [.literal("/a"), .literal("/b/"), .slot("id"), .literal("/c")])
    // Merged: ["/a/b/", <id>, "/c"]: the token is part 1, at offset 5.
    #expect(text.partIndex(ofTokenAt: 5) == 1)
    #expect(text.ordinal(ofTokenAt: 5) == 0)
}

@Test("Spike: a bare U+FFFC (a token whose attachment was lost, as a cross-field drag delivers) is dropped — never a token, never text")
func aBareObjectReplacementCharacterIsDropped() {
    let text = ApiEditorText(units: [.code(0xFFFC), .code(0x61)])
    #expect(text.parts == [.literal("a")])
    #expect(text.length == 1)
    #expect(text.tokens(in: 0..<2).isEmpty)
    // The same from a run read off the text storage, and from a part handed in: one rule.
    #expect(ApiEditorText(runs: [.text("x\u{FFFC}y")]).parts == [.literal("xy")])
    #expect(ApiEditorText(parts: [.literal("\u{FFFC}")]).parts == [])
}

@Test("Slice and replace work in units, and keep tokens and their identity")
func sliceAndReplace() {
    let bound = liveBinding(name: "id")
    let text = ApiEditorText(parts: [.literal("ab"), .bound(bound), .literal("cd")])
    #expect(text.slice(1..<4).parts == [.literal("b"), .bound(bound), .literal("c")])
    let replaced = text.replacing(0..<2, with: ApiEditorText(parts: [.slot("x")]))
    #expect(replaced.parts == [.slot("x"), .bound(bound), .literal("cd")])
    #expect(text.tokens(in: 0..<5) == [.bound(bound)])
    #expect(text.plain == "ab<id>cd")
}

@Test("A replace inside a surrogate pair that puts it back together keeps the character")
func aReplaceAcrossASurrogatePairRejoins() {
    let text = ApiEditorText(parts: [.literal("a😀b")])
    // Units: a, high, low, b. Replace nothing at offset 2, between the halves.
    #expect(text.replacing(2..<2, with: ApiEditorText(parts: [])).parts == [.literal("a😀b")])
}

@Test("An out-of-range slice is clamped, never a trap")
func outOfRangeIsClamped() {
    let text = ApiEditorText(parts: [.literal("ab")])
    #expect(text.slice(1..<9).parts == [.literal("b")])
    #expect(text.slice(-3..<1).parts == [.literal("a")])
    #expect(text.token(at: 9) == nil)
    #expect(text.token(at: -1) == nil)
    #expect(text.tokens(in: -4..<40).isEmpty)
}

@Test("Review Focus 4: an echo of the editor's own typing is not taken while it has the cursor")
func anEchoOfOwnTypingIsNotTaken() {
    let typed: [[ApiPart]] = [[.literal("/a")], [.literal("/ab")]]
    #expect(!apiEditorTakesParts([.literal("/a")], showing: [.literal("/ab")],
                                 typedSinceTaken: typed, focused: true))
    // Without the cursor it is an outside change, and taken.
    #expect(apiEditorTakesParts([.literal("/a")], showing: [.literal("/ab")],
                                typedSinceTaken: typed, focused: false))
    // Something the editor never showed is outside, cursor or not.
    #expect(apiEditorTakesParts([.literal("/z")], showing: [.literal("/ab")],
                                typedSinceTaken: typed, focused: true))
    // The same parts, merged differently, are not a change.
    #expect(!apiEditorTakesParts([.literal("/a"), .literal("b")], showing: [.literal("/ab")],
                                 typedSinceTaken: [], focused: true))
}

@Test("Review Focus 4: the caret survives an outside change beside it")
func theCaretSurvivesAnOutsideChangeBesideIt() {
    let bound = liveBinding(name: "id")
    let old = ApiEditorText(parts: [.literal("/a/"), .bound(bound), .literal("/b")])
    let new = ApiEditorText(parts: [.literal("/a/"), .slot("id"), .literal("/b")])
    // An unbind landing: the caret just after the token stays just after it.
    #expect(apiEditorSelection(from: old, to: new, selection: 4..<4) == 4..<4)
    // Text added before the caret moves it by that much.
    let longer = ApiEditorText(parts: [.literal("/v1/a/"), .bound(bound), .literal("/b")])
    #expect(apiEditorSelection(from: old, to: longer, selection: 5..<5) == 8..<8)
    // A caret inside text that was replaced goes to the end of the replacement.
    let other = ApiEditorText(parts: [.literal("/zzzz")])
    #expect(apiEditorSelection(from: old, to: other, selection: 2..<2) == 5..<5)
    // A selection spanning the change keeps its head and its tail.
    #expect(apiEditorSelection(from: old, to: longer, selection: 1..<6) == 1..<9)
    // A selection past the end is clamped into the new text.
    #expect(apiEditorSelection(from: old, to: other, selection: 40..<40) == 5..<5)
}

@Test("M6: a large pasted body maps through runs, not unit by unit")
func aLargeBodyMapsInLinearTime() {
    let big = String(repeating: "{\"k\": \"v\"}\n", count: 20_000)  // ~220 KB
    let parts: [ApiPart] = [.literal(big), .slot("a"), .literal(big), .slot("b"), .literal("}")]
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        let text = ApiEditorText(parts: parts)
        let end = text.length - 2
        #expect(text.token(at: end) == .hole("b"))
        #expect(text.ordinal(ofTokenAt: end) == 1)
        #expect(text.partIndex(ofTokenAt: end) == 3)
        #expect(text.tokens(in: 0..<text.length).count == 2)
        let typed = text.replacing(end + 1..<end + 1, with: ApiEditorText(parts: [.literal("x")]))
        #expect(typed.length == text.length + 1)
        #expect(apiEditorSelection(from: text, to: typed, selection: end + 1..<end + 1)
                == end + 1..<end + 1)  // an insertion at the caret is after it
        #expect(ApiEditorText(runs: typed.runs) == typed)
        #expect(typed.slice(end..<typed.length).parts == [.slot("b"), .literal("x}")])
    }
    // A unit-by-unit walk per call took seconds in a debug build; runs take well under one.
    #expect(elapsed < .seconds(1))
}

@Test("Task 2 carry: incoming parts are compared as the editor would show them, so a U+FFFC literal is not retaken")
func incomingPartsAreComparedAsTheEditorShowsThem() {
    // An agent's write with a literal U+FFFC: the editor drops it, so it shows `ab` already.
    #expect(!apiEditorTakesParts([.literal("a\u{FFFC}b")], showing: [.literal("ab")],
                                 typedSinceTaken: [], focused: false))
    #expect(!apiEditorTakesParts([.literal("\u{FFFC}")], showing: [], typedSinceTaken: [],
                                 focused: true))
    // An echo of its own typing, compared the same way.
    #expect(!apiEditorTakesParts([.literal("x\u{FFFC}")], showing: [.literal("xy")],
                                 typedSinceTaken: [[.literal("x")]], focused: true))
    // Still a change when it differs by more than the U+FFFC.
    #expect(apiEditorTakesParts([.literal("a\u{FFFC}c")], showing: [.literal("ab")],
                                typedSinceTaken: [], focused: false))
}
