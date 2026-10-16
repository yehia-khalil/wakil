# Phase 2c-iv — the walk's first findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator can add and remove query and header rows, edit the query from the path box
and the Query region alike, and write a multi-line JSON body — the three things the first walk of
2c-iv could not do.

**Architecture:** No new action, no new `read_pane` key. Three pure WakilKit units, each in its own
file because `ApiActions.swift` is already ~2,200 lines: the path↔query view and its parser
(`ApiPathQuery.swift`), the row add/remove rulings (`ApiRows.swift`), and an order-preserving JSON
re-indenter (`ApiBodyFormat.swift`). `ApiPane.swift` calls them; `WindowModel` gains one awaited,
ordered dispatch so Send can commit the body first.

**Tech Stack:** SwiftUI (`WakilApp`, no tests, macOS 14.4 target), `WakilKit` (swift-testing),
JSONL checks under `e2e/checks/seeded/`.

**Spec:** `docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md`, **Amendment 8**
(8a, 8b, 8c) and the plan-time corrections recorded under it (8d). Read both.

## Global Constraints

- **Every ruling goes in `WakilKit`, not in the view.** A string, an `if` choosing an action, or a
  parse done inline in a `View` is a ruling nothing can pin.
- **Every actionable control carries an `.accessibilityIdentifier` on an element with an
  accessibility action** — `Button`, `TextField`, `TextEditor`, `Menu`. Never on a `Text`.
- **No shipped check changes an identifier.** `api-surface.jsonl` changes one *gesture* (Return →
  `hotkey cmd+Return` for the body) and nothing else.
- **Every dispatch in `ApiPane` goes through `operate(_:_:)`**, which clears the drop's result line;
  the new ordered dispatch (Task 5) goes through an `operate`-equivalent that clears it too.
- **No new action; no new `read_pane` key; no line added to `e2e/checks/uncoverable.tsv`.**
- **Identifiers:** `api.query.add`, `api.query.add.name`, `api.header.add`, `api.header.add.name`,
  `api.query.<name>.remove`, `api.header.<name>.remove` (duplicates: `api.query[<row>].<name>.remove`),
  `api.body.format`. The path box keeps `api.path` / `api.path.part.<i>`.
- **Header deny list, refused at the gesture, case-insensitive:** `authorization`, `cookie`, `host`,
  and any name starting `proxy-`. `content-type` is **not** refused: it routes to Wakil's own row.
- **Query names may not contain `=`, `&`, `?`, `#`.** A hole may not sit in a query name.
- **Format never reorders a key and never rewrites a number or a string.**
- **Every new check is seen red by `make e2e-new` before it is called done. GUI runs (`make e2e`,
  `make e2e-new`, launching the app) need the operator's OK each time and a message to the peer
  session (wakil-56) before and after.**

## Review Focus

1. **A query value holding `&` (set from the Query region or by the agent)** — the path view cannot
   show it faithfully. Expected: the path box draws read-only with the note *"a query value holds
   `&` — edit it in the Query region"*, and the Query region stays editable. *Task 1,
   `aValueWithAnAmpersandDoesNotRoundTrip`; Task 4 draws it.*
2. **Typing `?` twice (`/a?x=1?y=2`)** — expected: only the first `?` starts the query; the second
   is literal text inside the value `1?y=2`. *Task 1, `onlyTheFirstQuestionMarkSplits`.*
3. **`=x` or `&&` in the path box** — expected: `=x` is refused (*"a query row needs a name"*);
   empty pairs from `&&` are dropped. *Task 1, `aNamelessRowIsRefused`, `emptyPairsAreDropped`.*
4. **A body with a hole between two JSON tokens, formatted** — expected: the chip survives in place
   and the JSON around it is re-indented. *Task 3, `aHoleIsAnOpaqueValue`.*
5. **Send pressed with an uncommitted multi-line body** — expected: the body is written first, then
   the request is sent with it; never the old body. *Task 5, `theSendSequenceWritesTheBodyFirst`.*

---

### Task 1: The path↔query view and its parser

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiPathQuery.swift`
- Test: `app/Tests/WakilKitTests/ApiPathQueryTests.swift` (create)

**Interfaces:**
- Consumes: `ApiPart` (`.literal`, `.slot`, `.bound`), `ApiQueryRow(name:value:)`,
  `ApiRequestSnapshot`, `apiPartJSON(_:sources:)`, `apiDraftForWrite(_:)`.
- Produces:
  ```swift
  /// The path box's parts: path, then `?`, then `name=value` rows joined by `&`.
  public func apiPathQueryView(path: [ApiPart], query: [ApiQueryRow]) -> [ApiPart]
  /// Whether every query row can be shown in the view and parsed back unchanged.
  public func apiPathQueryRoundTrips(_ query: [ApiQueryRow]) -> Bool
  public enum ApiPathQueryRefusal: Error, Equatable {
      case holeInName, namelessRow, forbiddenInName(Character)
      public var line: String { get }   // operator-facing sentence
  }
  public func apiPathQueryParse(_ parts: [ApiPart])
      -> Result<(path: [ApiPart], query: [ApiQueryRow]), ApiPathQueryRefusal>
  /// The one api_set_request a path-box commit sends: path AND query together.
  public func apiPathQueryWrite(path: [ApiPart], query: [ApiQueryRow], pane: String) -> JSONValue
  ```

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import WakilKit

/// Amendment 8a: the path box is a view of path AND query, parsed back on commit.

private func q(_ name: String, _ value: [ApiPart]) -> ApiQueryRow { ApiQueryRow(name: name, value: value) }

@Test("An empty query draws no question mark")
func anEmptyQueryDrawsNoQuestionMark() {
    #expect(apiPathQueryView(path: [.literal("/orders")], query: []) == [.literal("/orders")])
}

@Test("Rows draw as name=value joined by &, adjacent literals merged")
func rowsDrawAsAQueryString() {
    let view = apiPathQueryView(
        path: [.literal("/orders")],
        query: [q("status", [.literal("open")]), q("limit", [.literal("5")])])
    #expect(view == [.literal("/orders?status=open&limit=5")])
}

@Test("A hole in a query value draws as its chip in place")
func aHoleInAValueIsAChip() {
    let view = apiPathQueryView(path: [.literal("/o")], query: [q("id", [.slot("id")])])
    #expect(view == [.literal("/o?id="), .slot("id")])
}

@Test("The view parses back to the same path and rows", arguments: [
    ([ApiPart.literal("/orders")], [ApiQueryRow]()),
    ([.literal("/o")], [q("a", [.literal("1")]), q("b", [])]),
    ([.literal("/o/"), .slot("id"), .literal("/x")], [q("k", [.literal("v"), .slot("s"), .literal("w")])]),
    ([.literal("/o")], [q("tag", [.literal("a")]), q("tag", [.literal("b")])]),
])
func theViewRoundTrips(path: [ApiPart], query: [ApiQueryRow]) throws {
    let parsed = try apiPathQueryParse(apiPathQueryView(path: path, query: query)).get()
    #expect(parsed.path == path)
    #expect(parsed.query == query)
}

@Test("Only the first question mark splits")
func onlyTheFirstQuestionMarkSplits() throws {
    let parsed = try apiPathQueryParse([.literal("/a?x=1?y=2")]).get()
    #expect(parsed.path == [.literal("/a")])
    #expect(parsed.query == [q("x", [.literal("1?y=2")])])
}

@Test("A trailing question mark is no rows")
func aTrailingQuestionMarkIsNoRows() throws {
    let parsed = try apiPathQueryParse([.literal("/a?")]).get()
    #expect(parsed.path == [.literal("/a")])
    #expect(parsed.query.isEmpty)
}

@Test("Empty pairs from && are dropped")
func emptyPairsAreDropped() throws {
    let parsed = try apiPathQueryParse([.literal("/a?x=1&&y=2&")]).get()
    #expect(parsed.query == [q("x", [.literal("1")]), q("y", [.literal("2")])])
}

@Test("A name with no = is a row with an empty value")
func aBareNameIsAnEmptyValue() throws {
    let parsed = try apiPathQueryParse([.literal("/a?debug")]).get()
    #expect(parsed.query == [q("debug", [])])
}

@Test("A hole in a query name is refused")
func aHoleInANameIsRefused() {
    #expect(apiPathQueryParse([.literal("/a?"), .slot("k"), .literal("=1")]) == .failure(.holeInName))
}

@Test("A nameless row is refused")
func aNamelessRowIsRefused() {
    #expect(apiPathQueryParse([.literal("/a?=x")]) == .failure(.namelessRow))
}

@Test("A # in a query name is refused")
func aHashInANameIsRefused() {
    #expect(apiPathQueryParse([.literal("/a?x#y=1")]) == .failure(.forbiddenInName("#")))
}

@Test("What is typed is what is meant: no percent-decoding")
func nothingIsDecoded() throws {
    let parsed = try apiPathQueryParse([.literal("/a?q=a%20b")]).get()
    #expect(parsed.query == [q("q", [.literal("a%20b")])])
}

@Test("A value with an ampersand does not round-trip")
func aValueWithAnAmpersandDoesNotRoundTrip() {
    #expect(!apiPathQueryRoundTrips([q("q", [.literal("a&b")])]))
    #expect(!apiPathQueryRoundTrips([q("a=b", [.literal("1")])]))
    #expect(apiPathQueryRoundTrips([q("q", [.literal("a=b")]), q("id", [.slot("id")])]))
}

@Test("A path-box commit writes path and query in one write")
func oneWriteCarriesBoth() {
    let written = apiPathQueryWrite(
        path: [.literal("/o")], query: [q("id", [.slot("id")])], pane: "api-1")
    guard case .object(let fields) = written else { Issue.record("not an object"); return }
    #expect(fields["path"] == .array([.object(["literal": .string("/o")])]))
    #expect(fields["query"] == .array([.object([
        "name": .string("id"), "value": .array([.object(["slot": .string("id")])]),
    ])]))
    #expect(fields["pane"] == .string("api-1"))
}
```

`ApiQueryRow` must be `Equatable` for these; it is (`ApiDraft.swift:170`, `Sendable, Equatable`). If
`apiPathQueryParse`'s `Result` with a tuple success cannot be compared with `==`, compare through a
`switch` in the three refusal tests instead — same assertions.

- [ ] **Step 2: Run and watch every test fail** — `make app-test 2>&1 | grep -E "ApiPathQuery|error:" | head`
  (expect `cannot find 'apiPathQueryView' in scope`).
- [ ] **Step 3: Implement.**

```swift
import Foundation

/// Amendment 8a — the path box is a VIEW of two regions the draft keeps apart.
///
/// **The draft never stores a `?`.** Path parts and query rows stay separate, so the wire,
/// `read_pane` and every action are unchanged; this file only draws the two as one string of
/// parts and reads that string back. Splitting happens inside literal text alone, so a chip is
/// never cut and always lands in the value it was drawn in.

public func apiPathQueryView(path: [ApiPart], query: [ApiQueryRow]) -> [ApiPart] {
    var parts = path
    if !query.isEmpty {
        parts.append(.literal("?"))
        for (index, row) in query.enumerated() {
            parts.append(.literal((index == 0 ? "" : "&") + row.name + "="))
            parts.append(contentsOf: row.value)
        }
    }
    return apiMergedLiterals(parts)
}

/// Adjacent literals join, and empty ones vanish, so the view has one box per run of text.
func apiMergedLiterals(_ parts: [ApiPart]) -> [ApiPart] {
    var out: [ApiPart] = []
    for part in parts {
        if case .literal(let text) = part {
            if text.isEmpty { continue }
            if case .literal(let previous)? = out.last {
                out[out.count - 1] = .literal(previous + text)
                continue
            }
        }
        out.append(part)
    }
    return out
}

let apiQueryNameForbidden: Set<Character> = ["=", "&", "?", "#"]

public func apiPathQueryRoundTrips(_ query: [ApiQueryRow]) -> Bool {
    query.allSatisfy { row in
        !row.name.isEmpty && row.name.allSatisfy { !apiQueryNameForbidden.contains($0) }
            && row.value.allSatisfy { part in
                if case .literal(let text) = part { return !text.contains("&") }
                return true
            }
    }
}

public enum ApiPathQueryRefusal: Error, Equatable {
    case holeInName, namelessRow, forbiddenInName(Character)

    public var line: String {
        switch self {
        case .holeInName: return "a hole can sit only in a query value"
        case .namelessRow: return "a query row needs a name"
        case .forbiddenInName(let c): return "a query name may not contain \(c)"
        }
    }
}

public func apiPathQueryParse(_ parts: [ApiPart])
    -> Result<(path: [ApiPart], query: [ApiQueryRow]), ApiPathQueryRefusal>
{
    enum State { case path, name, value }
    var state = State.path
    var path: [ApiPart] = []
    var rows: [ApiQueryRow] = []
    var name = ""
    var value: [ApiPart] = []
    var pending = ""   // literal text accumulating in the current position

    func flushPending() {
        guard !pending.isEmpty else { return }
        switch state {
        case .path: path.append(.literal(pending))
        case .value: value.append(.literal(pending))
        case .name: break
        }
        pending = ""
    }
    func finishRow() -> ApiPathQueryRefusal? {
        if state == .name { name = pending; pending = "" } else { flushPending() }
        defer { name = ""; value = []; state = .name }
        if name.isEmpty { return value.isEmpty ? nil : .namelessRow }
        rows.append(ApiQueryRow(name: name, value: apiMergedLiterals(value)))
        return nil
    }

    for part in parts {
        guard case .literal(let text) = part else {
            switch state {
            case .path: flushPending(); path.append(part)
            case .value: flushPending(); value.append(part)
            case .name: return .failure(.holeInName)
            }
            continue
        }
        for character in text {
            switch (state, character) {
            case (.path, "?"):
                flushPending(); state = .name
            case (.name, "="):
                name = pending; pending = ""
                if name.isEmpty { return .failure(.namelessRow) }
                state = .value
            case (.name, "&"), (.value, "&"):
                if let refusal = finishRow() { return .failure(refusal) }
            case (.name, let c) where apiQueryNameForbidden.contains(c):
                return .failure(.forbiddenInName(c))
            default:
                pending.append(character)
            }
        }
    }
    if state == .path { flushPending() } else if let refusal = finishRow() { return .failure(refusal) }
    return .success((path: apiMergedLiterals(path), query: rows))
}

public func apiPathQueryWrite(path: [ApiPart], query: [ApiQueryRow], pane: String) -> JSONValue {
    .object([
        "pane": .string(pane),
        "path": .array(path.map { apiPartJSON($0, sources: [:]) }),
        "query": .array(query.map { row in
            .object([
                "name": .string(row.name),
                "value": .array(row.value.map { apiPartJSON($0, sources: [:]) }),
            ])
        }),
    ])
}
```

A bound part never reaches `apiPathQueryWrite` from the window: Task 4's locking rule draws the
path box read-only whenever the path or the query holds one. `apiPartJSON` on a `.bound` would
emit a binding `api_set_request` refuses, which is the correct loud failure if that rule ever breaks.

- [ ] **Step 4: Run and watch it pass.** `make app-test 2>&1 | grep -E "ApiPathQuery|passed|failed" | tail`
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiPathQuery.swift app/Tests/WakilKitTests/ApiPathQueryTests.swift
git commit -m "The path box is a view of path and query, and parses back to both"
```

### Task 2: Adding and removing rows

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiRows.swift`
- Test: `app/Tests/WakilKitTests/ApiRowsTests.swift` (create)

**Interfaces:**
- Consumes: `ApiRequestSnapshot`, `apiDraftForWrite(_:)`, `apiPartJSON(_:sources:)`,
  `apiQueryNameForbidden` (Task 1).
- Produces:
  ```swift
  public enum ApiRowRegion: Sendable, Equatable { case query, header }
  public enum ApiRowAdd: Equatable {
      case write(JSONValue)          // dispatch this api_set_request
      case focusContentType          // header named content-type: go to Wakil's own row
      case refused(String)           // operator-facing line, nothing dispatched
  }
  public func apiRowAdd(draft: ApiRequestSnapshot, region: ApiRowRegion, name: String, pane: String) -> ApiRowAdd
  /// `row` is the occurrence among rows with this name (0 for the first), as `apiRowOccurrence` counts.
  public func apiRowRemoveWrite(draft: ApiRequestSnapshot, region: ApiRowRegion, name: String, row: Int, pane: String) -> JSONValue?
  public let apiAuthorizationRefusal: String
  ```

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import WakilKit

/// Amendment 8b: + query, + header, and × on a row.

private func draft(query: [ApiQueryRow] = [], headers: [(String, [ApiPart])] = []) -> ApiRequestSnapshot {
    var rows = ApiRequestSnapshot.empty.headers
    rows.append(contentsOf: headers.map { ApiHeaderRegionRow.operatorRow(name: $0.0, value: $0.1) })
    return ApiRequestSnapshot(method: "GET", origin: nil, path: [], query: query, headers: rows, body: [])
}

private func region(_ result: ApiRowAdd, _ key: String) -> [JSONValue]? {
    guard case .write(.object(let f)) = result, case .array(let rows)? = f[key] else { return nil }
    return rows
}

@Test("+ query appends a named row with an empty value, keeping the others")
func addingAQueryRowAppends() {
    let rows = region(apiRowAdd(draft: draft(query: [ApiQueryRow(name: "a", value: [.slot("x")])]),
                                region: .query, name: "limit", pane: "p"), "query")
    #expect(rows?.count == 2)
    #expect(rows?.last == .object(["name": .string("limit"), "value": .array([])]))
    #expect(rows?.first == .object(["name": .string("a"), "value": .array([.object(["slot": .string("x")])])]))
}

@Test("+ header appends a custom header, name exactly as typed")
func addingAHeaderKeepsTheName() {
    let rows = region(apiRowAdd(draft: draft(), region: .header, name: "X-Trace-Id", pane: "p"), "headers")
    #expect(rows?.last == .object(["name": .string("X-Trace-Id"), "value": .array([])]))
}

@Test("A blank name is refused", arguments: ["", "  ", "\t"])
func aBlankNameIsRefused(name: String) {
    guard case .refused = apiRowAdd(draft: draft(), region: .header, name: name, pane: "p") else {
        Issue.record("not refused"); return
    }
}

@Test("The deny list is refused at the gesture", arguments: ["authorization", "Authorization", "cookie", "HOST", "proxy-authorization", "Proxy-Foo"])
func theDenyListIsRefused(name: String) {
    guard case .refused = apiRowAdd(draft: draft(), region: .header, name: name, pane: "p") else {
        Issue.record("\(name) not refused"); return
    }
}

@Test("authorization's refusal names the honest route")
func authorizationTeachesTheRoute() {
    #expect(apiRowAdd(draft: draft(), region: .header, name: "Authorization", pane: "p")
        == .refused(apiAuthorizationRefusal))
    #expect(apiAuthorizationRefusal.contains("wakil secrets set-api"))
}

@Test("content-type is not refused: it goes to Wakil's own row", arguments: ["content-type", "Content-Type"])
func contentTypeRoutesToItsRow(name: String) {
    #expect(apiRowAdd(draft: draft(), region: .header, name: name, pane: "p") == .focusContentType)
}

@Test("A duplicate header is admitted at the gesture")
func aDuplicateHeaderIsAdmitted() {
    let rows = region(apiRowAdd(draft: draft(headers: [("x-a", [])]), region: .header, name: "X-A", pane: "p"), "headers")
    #expect(rows?.count == 2)
}

@Test("A query name with = & ? # is refused", arguments: ["a=b", "a&b", "a?b", "a#b"])
func aQueryNameWithASeparatorIsRefused(name: String) {
    guard case .refused = apiRowAdd(draft: draft(), region: .query, name: name, pane: "p") else {
        Issue.record("\(name) not refused"); return
    }
}

@Test("× removes that occurrence and keeps every other row")
func removingARowKeepsTheRest() {
    let d = draft(query: [ApiQueryRow(name: "t", value: [.literal("a")]), ApiQueryRow(name: "t", value: [.literal("b")]),
                          ApiQueryRow(name: "u", value: [.slot("s")])])
    guard case .object(let f)? = apiRowRemoveWrite(draft: d, region: .query, name: "t", row: 1, pane: "p"),
          case .array(let rows)? = f["query"] else { Issue.record("no write"); return }
    #expect(rows.count == 2)
    #expect(rows[0] == .object(["name": .string("t"), "value": .array([.object(["literal": .string("a")])])]))
    #expect(rows[1] == .object(["name": .string("u"), "value": .array([.object(["slot": .string("s")])])]))
}

@Test("Wakil's own header rows are never removed")
func wakilsRowsAreNotRemovable() {
    #expect(apiRowRemoveWrite(draft: draft(), region: .header, name: "content-type", row: 0, pane: "p") == nil)
}
```

`ApiHeaderRegionRow.operatorRow(name:value:)` is a test helper: if `ApiHeaderRegionRow` has no such
constructor, read `ApiHeaderRegion.swift` and build the operator's row the way
`apiHeaderRegion(...)` builds one (editable, value present) — put that helper in
`ApiTestSupport.swift`, never in `Sources`.

- [ ] **Step 2: Run and watch them fail** (`cannot find 'apiRowAdd' in scope`).
- [ ] **Step 3: Implement** in `ApiRows.swift`:
  - `apiAuthorizationRefusal = "authorization comes from the API entry's credential (wakil secrets set-api), not from a typed header"`.
  - `apiRowAdd`: trim only to test blankness (the name is kept exactly as typed — the hole rule). For
    `.header`: lowercase compare; `content-type` → `.focusContentType`; `authorization` →
    `.refused(apiAuthorizationRefusal)`; `cookie`, `host`, or prefix `proxy-` →
    `.refused("\(name) is never set by hand: wakil-http refuses authorization, cookie, host and proxy-* headers")`.
    For `.query`: a character in `apiQueryNameForbidden` → `.refused(ApiPathQueryRefusal.forbiddenInName(c).line)`.
    Otherwise build the region from `apiDraftForWrite(draft)` (which already leaves Wakil's own rows
    out), append `{name, value: []}`, every other row carried through `apiPartJSON(_:sources: [:])`,
    and return `.write(["pane": pane, "query"|"headers": rows])`.
  - `apiRowRemoveWrite`: from `apiDraftForWrite(draft)`, drop the `row`-th occurrence of `name`
    (exact name match for query; case-insensitive for headers, as `api_unbind` counts — read
    `apiRowOccurrence` and match its counting); `nil` when no such occurrence exists, which is also
    the result for Wakil's own rows because `apiDraftForWrite` never holds them.
- [ ] **Step 4: Run and watch it pass.**
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiRows.swift app/Tests/WakilKitTests/ApiRowsTests.swift app/Tests/WakilKitTests/ApiTestSupport.swift
git commit -m "Rows are added and removed by hand, and the header deny list is refused at the gesture"
```

### Task 3: The order-preserving JSON re-indenter

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiBodyFormat.swift`
- Test: `app/Tests/WakilKitTests/ApiBodyFormatTests.swift` (create)

**Interfaces:**
- Consumes: `ApiPart`, `apiMergedLiterals(_:)` (Task 1).
- Produces:
  ```swift
  /// The body re-indented at two spaces, or nil when it does not tokenize as JSON.
  public func apiFormatBody(_ parts: [ApiPart]) -> [ApiPart]?
  public let apiNotJSONLine: String   // "not JSON — nothing formatted"
  ```

- [ ] **Step 1: Write the failing tests.**

```swift
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
```

- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement** a tokenizer over the parts: tokens are `{ } [ ] : ,`, a string (from
  `"` to the matching unescaped `"`, copied verbatim), a bare scalar (a maximal run of
  `[A-Za-z0-9+\-.eE]`, copied verbatim — then validated as `true`/`false`/`null` or a JSON number by
  a regex `^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$`), or a **chip** (any non-literal part,
  an opaque value token). Whitespace between tokens is discarded; anything else makes the result
  `nil`. Then a recursive-descent check of the grammar (value := object | array | string | scalar |
  chip; object := `{` (string `:` value (`,` string `:` value)*)? `}`; array likewise) — any failure
  or trailing tokens → `nil`; an empty token stream → `nil`. Emit while walking the grammar: after
  `{`/`[` with content, newline + indent+2; `,` → `,` newline + indent; before the closing bracket,
  newline + indent−2; `:` → `": "` rendering as `:` followed by one space; an empty container prints
  `{}`/`[]`. Text is emitted into a running literal; a chip closes the current literal, is appended
  as itself, and a new literal starts. Finish with `apiMergedLiterals`.
  `apiNotJSONLine = "not JSON — nothing formatted"`.
- [ ] **Step 4: Run and watch it pass.**
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiBodyFormat.swift app/Tests/WakilKitTests/ApiBodyFormatTests.swift
git commit -m "Format re-indents a JSON body and changes nothing else, a hole included"
```

Then: `superpowers:requesting-code-review` for Phase 1 (Tasks 1–3).

---

### Task 4: The path box on screen is the path↔query view

**Files:**
- Modify: `app/Sources/WakilApp/ApiPane.swift` — the path row and `splitField` for `.path`
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift` — `apiFieldIsTypable(_, .path)` and
  `apiDropRefusal`'s path naming only if needed
- Test: `app/Tests/WakilKitTests/ApiPathQueryTests.swift`

**Interfaces:**
- Consumes: `apiPathQueryView`, `apiPathQueryRoundTrips`, `apiPathQueryParse`,
  `apiPathQueryWrite`, `ApiPathQueryRefusal.line` (Task 1); `apiFieldTypedText`,
  `apiTypingBoxIndex`, the existing `boxes` / `operate` / `noteEdit` machinery.
- Produces: `public func apiPathBoxIsTypable(_ request: ApiRequestSnapshot) -> Bool` — the path box
  is typable only when the path AND the query hold no bound value AND `apiPathQueryRoundTrips`.
  And `public let apiPathQueryAmpersandNote = "a query value holds & — edit it in the Query region"`.

- [ ] **Step 1: Write the failing tests** (in `ApiPathQueryTests.swift`; `liveBinding(name:)` is in
  `ApiTestSupport.swift`):

```swift
private func req(path: [ApiPart], query: [ApiQueryRow]) -> ApiRequestSnapshot {
    ApiRequestSnapshot(method: "GET", origin: nil, path: path, query: query,
                       headers: ApiRequestSnapshot.empty.headers, body: [])
}

@Test("The path box locks over a binding in the path or the query, and over an &")
func thePathBoxLocks() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(!apiPathBoxIsTypable(req(path: [.literal("/o/"), bound], query: [])))
    #expect(!apiPathBoxIsTypable(req(path: [.literal("/o")], query: [q("id", [bound])])))
    #expect(!apiPathBoxIsTypable(req(path: [.literal("/o")], query: [q("q", [.literal("a&b")])])))
    #expect(apiPathBoxIsTypable(req(path: [.literal("/o/"), .slot("id")], query: [q("k", [.slot("s")])])))
}
```
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement and wire.**
  - `apiPathBoxIsTypable` in `ApiPathQuery.swift`.
  - In `ApiPane`, the path row's parts become `apiPathQueryView(path: request.path, query:
    request.query)`; its typability is `apiPathBoxIsTypable`; when it is false because of `&` (not a
    binding), draw `apiPathQueryAmpersandNote` in amber beside it.
  - A commit in the path box: compose the view's parts with the typed text exactly as the split
    field does today (`apiTyped`), parse with `apiPathQueryParse`; on `.success` dispatch
    `apiPathQueryWrite(...)` through `operate`; on `.failure(r)` draw `r.line` in amber under the
    path and dispatch nothing.
  - `+ hole` on the path appends to the VIEW: when the view has a `?` the hole lands in the last
    query value, which is what the operator sees — the parse puts it there.
  - Decision 27: every keystroke in the path box calls `noteEdit(.path, …)` **and**
    `noteEdit(.query(<each row name>), …)` — read how `apiFieldMark` keys query rows and mark each
    one the view shows, so an agent's write to either region is refused under the operator's hand.
  - Identifiers unchanged: `api.path` for the typing box, `api.path.part.<i>` for earlier boxes
    (indices are the VIEW's parts).
- [ ] **Step 4:** `make app-test`, `make app-bundle`, `make controls` — all headless. No `make e2e`.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilApp/ApiPane.swift app/Sources/WakilKit/Api/ApiPathQuery.swift app/Tests/WakilKitTests/ApiPathQueryTests.swift
git commit -m "The path box shows the query too, and a commit there writes both"
```

### Task 5: Rows on screen, the body editor, Format, and Send-commits-first

**Files:**
- Modify: `app/Sources/WakilApp/ApiPane.swift` — region headings, row `×`, body boxes, Format, Send
- Modify: `app/Sources/WakilApp/Canvas.swift` — pass the ordered dispatch into `ApiPane`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `dispatchFromSurfaceInOrder`
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift` — `apiDropRefusal`'s body line, and
  `apiSendSequence`
- Test: `app/Tests/WakilKitTests/ApiHandBindTests.swift`, `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `apiRowAdd`, `ApiRowAdd`, `apiRowRemoveWrite`, `apiAuthorizationRefusal` (Task 2);
  `apiFormatBody`, `apiNotJSONLine` (Task 3); `apiPartsWrite(... typed:)`, `apiSendParams`,
  `apiSendControl`.
- Produces:
  ```swift
  /// What Send dispatches, in order: the pending body write (if any), then the send.
  public func apiSendSequence(draft: ApiRequestSnapshot, pane: String, bodyTyped: [Int: String]) -> [(String, JSONValue)]
  // WindowModel:
  public func dispatchFromSurfaceInOrder(_ calls: [(String, JSONValue)]) async
  ```

- [ ] **Step 1: Write the failing tests.**
  - `theSendSequenceWritesTheBodyFirst`: with an uncommitted body box, `apiSendSequence` is
    `[("api_set_request", <body write>), (<api_request|api_send>, <params>)]`, the body write
    carrying the typed text; with nothing typed, it is the send alone. The send's params are built
    from the draft **with the typed body applied**, so `api_send`'s statement names the body that
    will actually be sent.
  - `aBodyDropRefusalNamesCmdReturn`: `apiDropRefusal` with uncommitted body text returns
    `"press ⌘Return in the body first, then drop"`; the path's line is unchanged.
  - In `WindowModelTests`, `dispatchFromSurfaceInOrderAwaitsEach`: two calls through a recording
    registry land in order, the second after the first returned.
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement and wire.**
  - `WindowModel.dispatchFromSurfaceInOrder`: `for (name, params) in calls { await dispatchFromSurface(name, params) }`.
  - `ApiPane` gets `dispatchInOrder: ([(String, JSONValue)]) -> Void` from `Canvas`
    (`Task { await model.dispatchFromSurfaceInOrder(calls) }`), and a private
    `operateInOrder(_:)` that clears the result line and bumps `bindGeneration` like `operate`.
  - **Region headings:** `Query · n` gets a `Button("+ query")` (`api.query.add`); `Headers · n` a
    `Button("+ header")` (`api.header.add`). Each opens a name box (`api.query.add.name` /
    `api.header.add.name`) exactly as `+ hole` does; Return calls `apiRowAdd`: `.write` →
    `operate("api_set_request", …)` and move focus to the new row's value box (`@FocusState` keyed
    by the row's identifier); `.focusContentType` → focus the content-type field; `.refused(line)` →
    draw `line` in amber beside the name box, dispatch nothing. Escape cancels.
  - **Row `×`:** each operator row (never Wakil's) whose value holds no bound part draws
    `Button("×")` with `api.query.<name>.remove` / `api.header.<name>.remove` (the `[row]` form for a
    later duplicate, built with `apiFieldKey`), dispatching `apiRowRemoveWrite`.
  - **Body:** each literal box in the body is a `TextEditor` (identifiers unchanged: `api.body` for
    the typing box, `api.body.part.<i>` for earlier ones), `.frame(minHeight:)` one line, growing to
    16 lines then scrolling. `.onKeyPress(.return, phases: .down)` with `.command` in the event's
    modifiers commits (returns `.handled`); plain Return falls through as a newline; Tab inserts two
    spaces. Every keystroke still marks Decision 27 through the existing `mark:` closure.
  - **Format:** `Button("Format")` (`api.body.format`) on the Body heading line: compose the body
    with its typed text (`apiTyped`), `apiFormatBody`; non-nil → `operate("api_set_request",
    ["pane", "body": <formatted parts>])` and clear the body's `boxes`; nil → draw `apiNotJSONLine`
    in amber on the Body heading. Disabled when the body is empty.
  - **Send:** `operateInOrder(apiSendSequence(draft: snapshot.request, pane: pane.id, bodyTyped: <body boxes>))`.
- [ ] **Step 4:** `make app-test`, `make app-bundle`, `make controls` — headless. No `make e2e`.
- [ ] **Step 5: Commit** (two commits: rows; body + Format + Send).

```bash
git commit -m "+ query, + header and × on a row, by hand"
git commit -m "The body is an editor: newlines, Cmd-Return, Format, and Send commits it first"
```

Then: `superpowers:requesting-code-review` for Phase 2 (Tasks 4–5).

---

### Task 6: The checks — and the one GUI session

**Files:**
- Create: `e2e/checks/seeded/api-query-sync.jsonl`, `api-rows.jsonl`, `api-body-editor.jsonl`
- Modify: `e2e/checks/seeded/api-surface.jsonl` — the body commit step only

**Before any GUI command: ask the operator for the screen and message wakil-56; message wakil-56
again when done.**

- [ ] **Step 1: Write the checks.** Read `e2e/driver/check.go` for the exact `expect` predicates
  and `docs/agents/e2e.md` for the vocabulary. Each opens `{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}`.
  - `api-query-sync.jsonl`: type `/orders?status=open&limit=5` into `api.path`, `press Return`;
    expect `request.path[0].literal == "/orders"`, `request.query[0].name == "status"`,
    `request.query[1].value[0].literal == "5"`. Then add a row through the region (`click
    api.query.add`, `type` `page` into `api.query.add.name`, `press Return`, `type` `2` into
    `api.query.page`, `press Return`) and expect the tree to contain `limit=5&page=2`. Then type
    `/o?=x` into `api.path` and `press Return` → the tree contains `a query row needs a name`, and
    `request.query` is unchanged. (A hole in a name cannot be typed — chips are never typed — so
    that refusal is pinned by Task 1's unit test alone.)
  - `api-rows.jsonl`: `+ header` `X-Trace-Id`, type a value, expect `request.headers` contains
    `X-Trace-Id`; `+ header` `Authorization` → tree contains `wakil secrets set-api`, headers
    unchanged; `+ header` `content-type` → no new row (headers count unchanged); `click
    api.header.X-Trace-Id.remove` → `request.headers` no longer contains it; `+ query` `a=b` →
    tree contains `may not contain =`.
  - `api-body-editor.jsonl`: `type` `{"a":1,` then `press Return` then `"b":2}` into `api.body`;
    expect `request.body` absent/unchanged (not committed yet); `hotkey cmd+Return`; expect
    `request.body[0].literal` contains a newline (assert `contains` `"b"` and that the field equals
    the three-line text exactly). `click api.body.format`; expect `request.body[0].literal` equals
    `{\n  "a": 1,\n  "b": 2\n}`. Then type `x` into `api.body` without committing and `click
    api.send`; expect the sent request's body (read `response`/`recent[0]` as `api-recent.jsonl`
    does) to carry the new text.
  - `api-surface.jsonl`: the step after `{"do":{"type":{"into":"api.body",…}}}` changes from
    `{"do":{"press":"Return"}}` to `{"do":{"hotkey":"cmd+Return"}}`. Nothing else in the file.
- [ ] **Step 2: GUI — `make e2e-new`:** the three new checks red against the merge-base.
- [ ] **Step 3: GUI — `make e2e`:** every file green, the gate clean.
- [ ] **Step 4: Commit** the checks.

```bash
git add e2e/checks/seeded/
git commit -m "The checks for a query both ways, rows by hand, and the body editor"
```

### Task 7: The runbook

**Files:** Modify `docs/wakil/phase-2c-iv-acceptance.md`.

- [ ] **Step 1:** Rewrite check 4's gesture sequence to include: type `/anything/customers/` + `+ hole id`
  + `/confirm` with Return; then type `?expand=all` at the end of the path and Return — the Query
  region shows the row; then `+ query` `page` = `2` — the path shows `&page=2`; `+ header`
  `X-Trace-Id`; a multi-line body committed with ⌘Return, then **Format**. Keep the drop and the two
  visual questions. Still ten checks.
- [ ] **Step 2:** Update check 3: the empty regions now carry `+ query` / `+ header`.
- [ ] **Step 3:** `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2c-iv-acceptance.md` (headless;
  reads Task 6's records). It must render green against Task 6's build; commit the hand edits first
  if it refuses a dirty tree, and never edit between the markers.
- [ ] **Step 4: Commit.**

```bash
git add docs/wakil/phase-2c-iv-acceptance.md
git commit -m "2c-iv's runbook walks a query both ways, rows by hand, and a body you can format"
```

---

## Gate — done when

- [ ] `make test`, `make app-test` green; `make e2e` green; `make e2e-new` saw the three new checks red
- [ ] No shipped identifier changed; `api-surface.jsonl` changed one gesture only
- [ ] `uncoverable.tsv` gained no line
- [ ] The runbook re-rendered green, ten checks; the walk restarts from check 1
