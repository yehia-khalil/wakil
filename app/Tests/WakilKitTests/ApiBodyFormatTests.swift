import Testing
@testable import WakilKit

/// Amendment 8c: Format re-indents and changes nothing else.

@Test("A flat object is indented at two spaces")
func aFlatObjectIsIndented() {
    #expect(apiFormatBody([.literal(#"{"a":1,"b":[true,null]}"#)])
        == [.literal("{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null\n  ]\n}")])
}

@Test("Key order survives")
func keyOrderSurvives() {
    #expect(apiFormatBody([.literal(#"{"z":1,"a":2}"#)]) == [.literal("{\n  \"z\": 1,\n  \"a\": 2\n}")])
}

@Test("A number above 2^53 is not rewritten")
func aBigIntegerSurvives() {
    #expect(apiFormatBody([.literal(#"{"id":9007199254740993}"#)]) == [.literal("{\n  \"id\": 9007199254740993\n}")])
}

@Test("Strings, escapes and whitespace inside them are untouched")
func stringsAreUntouched() {
    #expect(apiFormatBody([.literal(#"{"s":"a , b\" {x}"}"#)]) == [.literal("{\n  \"s\": \"a , b\\\" {x}\"\n}")])
}

@Test("A hole is an opaque value")
func aHoleIsAnOpaqueValue() {
    #expect(apiFormatBody([.literal(#"{"id":"#), .slot("id"), .literal(#","paid":true}"#)])
        == [.literal("{\n  \"id\": "), .slot("id"), .literal(",\n  \"paid\": true\n}")])
}

@Test("Empty containers stay on one line")
func emptyContainers() {
    #expect(apiFormatBody([.literal(#"{"a":{},"b":[]}"#)]) == [.literal("{\n  \"a\": {},\n  \"b\": []\n}")])
}

@Test("Not JSON is refused", arguments: [#"{"a":1,}"#, #"{"a":1"#, "hello", #"{"a" 1}"#, ""])
func notJSONIsRefused(text: String) {
    #expect(apiFormatBody([.literal(text)]) == nil)
}

@Test("Already formatted is a fixed point")
func formattingTwiceChangesNothing() {
    let once = apiFormatBody([.literal(#"{"a":[1,{"b":2}]}"#)])!
    #expect(apiFormatBody(once) == once)
}

// Edge cases beyond the brief.

@Test("An escaped backslash right before the closing quote ends the string")
func anEscapedBackslashEndsTheString() {
    #expect(apiFormatBody([.literal(#"{"s":"a\\","t":1}"#)])
        == [.literal("{\n  \"s\": \"a\\\\\",\n  \"t\": 1\n}")])
}

@Test("A string split across two literal parts is one string")
func aStringSplitAcrossLiteralsIsOneString() {
    #expect(apiFormatBody([.literal(#"{"s":"a , "#), .literal(#"b","t":[]}"#)])
        == [.literal("{\n  \"s\": \"a , b\",\n  \"t\": []\n}")])
}

@Test("A chip inside a string is refused")
func aChipInsideAStringIsRefused() {
    #expect(apiFormatBody([.literal(#"{"s":"a"#), .slot("x"), .literal(#"b"}"#)]) == nil)
}

@Test("A chip as an object key is refused")
func aChipAsAKeyIsRefused() {
    #expect(apiFormatBody([.literal("{"), .slot("k"), .literal(":1}")]) == nil)
}

@Test("A top-level scalar formats as itself", arguments: ["42", "-1.5e10", "true", "null", #""x , y""#])
func aTopLevelScalarFormatsAsItself(text: String) {
    #expect(apiFormatBody([.literal("  \(text)\n")]) == [.literal(text)])
}

@Test("A top-level chip formats as itself")
func aTopLevelChipFormatsAsItself() {
    #expect(apiFormatBody([.literal(" "), .slot("body"), .literal("\n")]) == [.slot("body")])
}

@Test("Negative numbers and exponents are copied verbatim")
func numbersAreCopiedVerbatim() {
    #expect(apiFormatBody([.literal("[-1.5e10,0.25E-3,-0,1e+2]")])
        == [.literal("[\n  -1.5e10,\n  0.25E-3,\n  -0,\n  1e+2\n]")])
}

@Test("A bare run that is not a JSON number or literal is refused",
      arguments: ["01", "1.", ".5", "+1", "1e", "True", "nul", "--1", #"{"a":"x"#])
func badScalarsAreRefused(text: String) {
    #expect(apiFormatBody([.literal(text)]) == nil)
}

@Test("Adjacent chips with no comma are refused")
func adjacentChipsAreRefused() {
    #expect(apiFormatBody([.literal("["), .slot("a"), .slot("b"), .literal("]")]) == nil)
}

@Test("Chips in an array, and a body that is only a chip-holding array")
func chipsInAnArray() {
    #expect(apiFormatBody([.literal("[ "), .slot("a"), .literal(" , "), .slot("b"), .literal(" ]")])
        == [.literal("[\n  "), .slot("a"), .literal(",\n  "), .slot("b"), .literal("\n]")])
}

@Test("The refusal line")
func theRefusalLine() {
    #expect(apiNotJSONLine == "not JSON — nothing formatted")
}

// Fix round 1: nesting depth is capped, so a deep body is refused rather than overflowing the stack.

private func nestedArrays(_ depth: Int) -> String {
    String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
}

@Test("A body nested exactly to the cap formats")
func nestedToTheCapFormats() {
    #expect(apiFormatBody([.literal(nestedArrays(apiFormatMaxDepth))]) != nil)
}

@Test("A body nested one past the cap is refused")
func nestedPastTheCapIsRefused() {
    #expect(apiFormatBody([.literal(nestedArrays(apiFormatMaxDepth + 1))]) == nil)
}

@Test("A body nested 100,000 deep is refused without crashing")
func nestedVeryDeepIsRefused() {
    #expect(apiFormatBody([.literal(nestedArrays(100_000))]) == nil)
    let objects = String(repeating: #"{"a":"#, count: 100_000) + "1" + String(repeating: "}", count: 100_000)
    #expect(apiFormatBody([.literal(objects)]) == nil)
}

@Test("A bare scalar as an object key is refused")
func aBareScalarAsAKeyIsRefused() {
    #expect(apiFormatBody([.literal("{true:1}")]) == nil)
}

// MARK: - Final review M7: only a no-op Format clears the boxes before its write

private func bodyDraft(_ body: [ApiPart]) -> ApiRequestSnapshot {
    ApiRequestSnapshot(method: "POST", origin: nil, path: [], query: [],
                       headers: ApiRequestSnapshot.empty.headers, body: body)
}

@Test("Format is a no-op when the formatted body is the draft already")
func formatOverAFormattedBodyIsANoOp() {
    let formatted = bodyDraft([.literal("{\n  \"a\": 1\n}")])
    #expect(apiFormatIsNoOp(draft: formatted, holding: formatted.body))
    // Typed text that formats back to the draft is a no-op too: the draft already holds it.
    #expect(apiFormatIsNoOp(draft: formatted, holding: [.literal(#"{"a":1}"#)]))
    // A body that formatting changes is not, nor typed text that formats to something new.
    #expect(!apiFormatIsNoOp(
        draft: bodyDraft([.literal(#"{"a":1}"#)]), holding: [.literal(#"{"a":1}"#)]))
    #expect(!apiFormatIsNoOp(draft: formatted, holding: [.literal(#"{"a":2}"#)]))
    // Not JSON is never a no-op: Format refuses it instead.
    #expect(!apiFormatIsNoOp(draft: bodyDraft([.literal("{")]), holding: [.literal("{")]))
}

// MARK: - Task 4 fix round 1: the refused-Format line follows the body the screen shows

private func refusalDraft(_ body: [ApiPart]) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: "POST", origin: nil, path: [], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: body)
}

@Test("A refused Format's line goes on a keystroke that changes the body")
func aKeystrokeClearsTheFormatRefusal() {
    let draft = refusalDraft([.literal("{")])
    let refused = apiRequestApplying(draft, held: [ApiFieldRow(.body): [.literal("{a")]]).body
    #expect(apiFormatRefusalShows(refused: refused, body: refused))
    let typed = apiRequestApplying(draft, held: [ApiFieldRow(.body): [.literal("{ab")]]).body
    #expect(!apiFormatRefusalShows(refused: refused, body: typed))
}

@Test("A refused Format's line goes when an agent's write changes the body")
func anAgentWriteClearsTheFormatRefusal() {
    let refused = refusalDraft([.literal("{")]).body
    #expect(!apiFormatRefusalShows(refused: refused, body: refusalDraft([.literal("[")]).body))
}

@Test("A refused Format's line stays when the flush of that same text lands")
func aLandingFlushKeepsTheFormatRefusal() {
    let typed = apiRequestApplying(
        refusalDraft([.literal("{")]), held: [ApiFieldRow(.body): [.literal("{a")]]).body
    // The flush lands: the draft holds the text, and the box is let go.
    let landed = apiRequestApplying(refusalDraft([.literal("{a")]), held: [:]).body
    #expect(apiFormatRefusalShows(refused: typed, body: landed))
    #expect(!apiFormatRefusalShows(refused: nil, body: landed))
}
