import Foundation
import Testing
@testable import WakilKit

/// W18: Recent shows the values sent; the Bound list shows each hole's current value.

private let bound = liveBinding(name: "reference")   // p3, key id 99, column reference
private func sources(_ value: String) -> [String: ApiSourcePane] {
    ["p3": ApiSourcePane(columns: ["id", "reference"], rows: [[.integer(99), .string(value)]],
                         generation: 1)]
}

@Test("A sent path shows each bound value beside its name")
func theShownPathCarriesTheValues() {
    #expect(apiShownPath([.literal("/customers/"), .bound(bound), .literal("/confirm")],
                         sources: sources("3"))
        == "/customers/<reference:3>/confirm")
    #expect(apiShownPath([.literal("/c/"), .slot("id")], sources: [:]) == "/c/<id>")
}

@Test("A value over 24 characters is shortened with …")
func aLongValueIsShortened() {
    #expect(apiShortened("abcdefghijklmnopqrstuvwx") == "abcdefghijklmnopqrstuvwx")   // 24
    #expect(apiShortened("abcdefghijklmnopqrstuvwxy") == "abcdefghijklmnopqrstuvw…")  // 25
    #expect(apiShownPath([.bound(bound)], sources: sources(String(repeating: "z", count: 40)))
        == "<reference:\(String(repeating: "z", count: 23))…>")
}

@Test("The Bound list shows each hole's current value")
func theBoundLineShowsTheValue() {
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.bound(bound)], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [])
    let rows = apiBoundValues(in: request, sources: sources("BK-2026-8842"))
    #expect(rows.map(apiBoundLine) == ["reference = BK-2026-8842 · live · bookings"])
}

@Test("Review Focus 5: a value with no source shows none, never a stale one")
func aValueWithNoSourceShowsNone() {
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.literal("/c/"), .bound(bound)], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [])
    #expect(apiBoundValues(in: request).map(apiBoundLine)
        == ["reference · live · bookings · no value now"])
    #expect(apiShownPath(request.path, sources: [:]) == "/c/<reference>")
}

@Test("A recent row's label shows the path as sent")
func theRowLabelShowsTheSentPath() {
    let row = ApiRecentRow(
        method: "GET", entry: "e", environment: "staging", path: "/c/<id>",
        status: 200, durationMs: 12, draft: .empty, shownPath: "/c/<id:3>")
    #expect(apiRecentRowLabel(row).hasPrefix("GET /c/<id:3> · 200 · 12 ms"))
    // read_pane's `path` is unchanged: the draft as written, `<name>` for a bound value.
    #expect(row.path == "/c/<id>")
}

@Test("A send's outcome carries the path as shown, whatever its fate")
func everyOutcomeCarriesTheShownPath() async {
    var draft = ApiDraft.empty
    draft.entry = "e"
    draft.method = "GET"
    draft.path = [.literal("/c/"), .bound(bound)]
    // No client: fate-unknown, and the draft resolved, so the value is there.
    let unknown = await apiRequest(draft: draft, sources: sources("3"), environment: "s", http: nil)
    #expect(unknown.shownPath == "/c/<reference:3>")
    // A refusal: nothing resolved, and the shown path says so without a value.
    let refused = await apiRequest(draft: draft, sources: [:], environment: "s", http: nil)
    #expect(refused.shownPath == "/c/<reference>")
}

@Test("Two holes with one name read apart by region; a name used once carries none")
func aSharedNameNamesItsRegion() {
    let other = liveBinding(name: "id")
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.literal("/c/"), .bound(bound), .bound(other)],
        query: [ApiQueryRow(name: "x", value: [.bound(bound)])],
        headers: ApiRequestSnapshot.empty.headers, body: [])
    #expect(apiBoundLines(apiBoundValues(in: request, sources: sources("3"))) == [
        "reference = 3 · live · bookings · Path",
        "id = 99 · live · bookings",
        "reference = 3 · live · bookings · Query · x",
    ])
}

@Test("A request with no bound part has no Bound rows, and the grids are not read for it")
func noBoundPartNoRows() {
    #expect(!apiHasBoundPart(.empty))
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.literal("/c")], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [.bound(bound)])
    #expect(apiHasBoundPart(request))
}
