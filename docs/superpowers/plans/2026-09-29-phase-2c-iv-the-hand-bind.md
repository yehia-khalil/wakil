# Phase 2c-iv — the hand bind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator can make a hole, drop a grid row on it, unbind it and remove it without
the agent — so the 2c-iv exit criterion's second clause, *"a value bound from another pane
resolves in the URL before the send"*, is walkable by hand.

**Architecture:** No new actions and no new rulings. Every gesture dispatches one that exists:
`api_set_request` for holes and literals, `api_bind` for the drop, `api_unbind` for the chip's
`×`. Every decision the view makes — what a write carries, whether a field is typable, whether
a drop still names the row that was picked up, what the result line says — is a pure function
in `WakilKit`, because `WakilApp` has no test target. The harness gains one act, a drag, driven
by `axresolve` rather than Orca.

**Tech Stack:** SwiftUI (`WakilApp`, no tests), `WakilKit` (swift-testing, `@Test`/`#expect`),
Swift `axresolve` (CGEvent), Go `e2e/driver`, JSONL checks under `e2e/checks/seeded/`.

**Spec:** [`docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md`](../specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md),
read with its **Amendments** section — four corrections made while writing this plan, each of
which changes a task below. Binding spec behind it: [#179](https://github.com/yehia-khalil/rafiq/issues/179).
Closes [#308](https://github.com/yehia-khalil/rafiq/issues/308).

## Global constraints

- **Every ruling goes in `WakilKit`, not in the view.** A `disabled(…)`, an `if` choosing an
  action, or a string built inline in a `View` is a ruling nothing can pin.
- **Every actionable control carries an `.accessibilityIdentifier` on an element with an
  accessibility action behind it** — a `Button`, a `TextField`, a `Menu`. An identifier on a
  `Text` announces a button that does nothing (`Landing.swift:265`).
- **Identifiers (spec §1, Amendment 3):** the **last** literal box of a field keeps the field's
  own id — `api.path`, `api.body`, `api.query.<name>`, `api.header.<name>`. Earlier literal
  boxes are `<field>.part.<i>`. Then `<field>.hole`, `<field>.hole.name`,
  `<field>.part.<i>.remove`, `<field>.part.<i>.unbind`, `db.row.<i>.grip`, `api.bind.result`.
  `<i>` counts from zero within the field's parts.
- **No shipped check changes an identifier.** If one has to, the plan was wrong; stop and amend
  the spec.
- **A hole's name is taken exactly as typed.** No trimming, no case folding.
- **No new actions, no new `read_pane` keys.** `DataSurfaceSnapshot` is held to *"exactly the
  fields `read_pane` has served since 2c-i"*.
- **No line is added to `e2e/checks/uncoverable.tsv`**, and Task 8 removes `api_bind`'s and
  `api_unbind`'s if #317 has added them.
- **The amber is `#e8b45a` and only for caution** — an unfilled hole, and the zero-match result
  line. Nothing here is a failure colour.
- **Every new check is seen red by `make e2e-new` against the merge-base before it is called
  done.**

## Review Focus

The five inputs the spec implies and no happy-path test reaches, most likely first. Each has its
test in the task that owns the code.

1. **A query row edited while a neighbouring row is bound** — today refused whole by
   `boundValueIsAGesture`. Expected: the region is read-only, so the edit cannot be attempted.
   *Task 3, `aRegionHoldingABoundRowLocksWhole`.*
2. **A drop after the source was re-sorted mid-drag** — the index now names a different row.
   Expected: refused on screen, nothing dispatched. *Task 6, `aResortedRowIsNotTheRowPickedUp`.*
3. **A hole named with surrounding whitespace, or `ID` against a column `id`** — expected: the
   name kept exactly, so it matches nothing and the result line says so.
   *Task 2, `aHoleNameIsKeptExactly`.*
4. **A text box between two holes committed empty** — expected: the literal is removed, the two
   holes become adjacent, neither is lost. *Task 2, `anEmptiedLiteralBetweenHolesIsDropped`.*
5. **A null cell against an empty-string cell** in the drop comparison — expected: never equal,
   so a re-fetch that turned `NULL` into `""` refuses. *Task 6, `aNullIsNotAnEmptyString`.*

---

## Phase 0 — Measure before building

### Task 1: The three things this plan assumes and nothing has measured

**Files:**
- Scratch only: a throwaway branch `spike/hand-bind-drag`, never merged.
- Modify: `docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md` — a dated
  amendment recording the findings.

**Why first.** Every later phase stands on three unmeasured claims, and each has a cheap
fallback that changes a later task's code. Measuring after building would mean rebuilding.

- [ ] **Step 1: The grip wins against the pane's drag.** On the spike branch, add to
  `DataSurface`'s row an overlay grip — applied **after** `.accessibilityElement(children:
  .ignore)`, so it is its own AX element — carrying `.draggable("probe")` and
  `.accessibilityIdentifier("db.row.\(row.id).grip")`. Add `.dropDestination(for: String.self)
  { items, _ in print("DROP", items); return true }` to `ApiPane`'s root. `make app-bundle`, open
  a DB pane and an api pane, drag the grip by hand onto the api pane.
  Record: **did the pane move, or did a drag session start and print `DROP probe`?**
  - **Step 1b (only if the pane moved):** do **not** reach for `.highPriorityGesture` on the
    grip — a `DragGesture` there would win and swallow the drag session it exists to start. The
    fallback is to narrow the canvas's `DragGesture` from the whole pane to the pane's header
    strip. Measure both halves: a pane still moves by its header, and the grip starts a
    session. Record which variant later tasks use.
- [ ] **Step 2: The grip is in the accessibility tree.** With the build from Step 1:
  `e2e/bin/axresolve --pid <pid> --identifier db.row.0.grip --press` — expect it to resolve (a
  press on a `draggable` may be a no-op; resolving is what is measured). If it does not resolve,
  record it; the fallback is `.accessibilityElement(children: .contain)` on the row with the
  row's label moved onto its first cell, measured the same way.
- [ ] **Step 3: A synthetic drag starts a SwiftUI drag session.** In a scratch Swift file,
  post from the grip's centre to the api pane's centre: `leftMouseDown`, then **ten**
  `leftMouseDragged` events 10 ms apart along the line, then `leftMouseUp`, all via
  `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` and
  `.post(tap: .cghidEventTap)`. Expect `DROP probe`. If a straight-line post does not start a
  session, try: a 150 ms hold after mouse-down before the first drag; then twenty steps. Record
  the smallest sequence that works three times in a row.
- [ ] **Step 4: Write the findings as a dated amendment** under the spec's `## Amendments`:
  `### 2026-09-29 — the measurements (Task 1)`, one paragraph per step: what was tried, what
  happened, which variant later tasks use. **Tasks 5 and 7 read this amendment.**
- [ ] **Step 5: Commit the amendment only** (the spike branch is not merged).

```bash
git add docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md
git commit -m "The hand bind's three measurements, before anything is built on them"
```

---

## Phase 1 — Split fields, `+ hole`, and the locking rule

### Task 2: `apiPartsWrite` — what a field's write carries

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift` — add beside `apiFieldWrite` (~line 1556)
- Test: `app/Tests/WakilKitTests/ApiHandBindTests.swift` (create)

**Interfaces:**
- Consumes: `ApiPart` (`.literal`, `.slot`, `.bound`), `ApiDraftField`, `apiPartJSON(_:sources:)`,
  `ApiRequestSnapshot`, `apiDraftForWrite(_:)`.
- Produces:
  ```swift
  public enum ApiPartsEdit: Sendable, Equatable {
      case text(index: Int, String)   // commit the literal box at `index`
      case appendHole(String)         // + hole, named
      case remove(index: Int)         // × on an unbound hole
  }
  /// `nil` when the edit is refused before dispatch (a blank hole name).
  public func apiPartsWrite(
      draft: ApiRequestSnapshot, field: ApiDraftField, edit: ApiPartsEdit, pane: String
  ) -> JSONValue?
  /// The parts a field holds in the snapshot — path, body, or one row's value.
  public func apiFieldParts(_ request: ApiRequestSnapshot, _ field: ApiDraftField) -> [ApiPart]
  ```

**Why one function for three gestures.** All three compute the field's new part list and write
it whole; the only difference is the list. One function means one place where "neighbouring holes
are carried as `{"slot":}`" is true, and one table test.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import WakilKit

/// The hand bind — the operator's half of G4 (#179 stories 31, 33–35).

private func request(path: [ApiPart], body: [ApiPart] = [],
                     query: [ApiQueryRow] = []) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: "POST", origin: nil, path: path, query: query,
        headers: ApiRequestSnapshot.empty.headers, body: body)
}

private func pathParts(_ json: JSONValue?) -> [JSONValue]? {
    guard case .object(let fields)? = json, case .array(let parts)? = fields["path"] else {
        return nil
    }
    return parts
}

@Test("Committing one literal box writes the whole field and carries its holes as slots")
func aLiteralCommitCarriesItsNeighbours() {
    let draft = request(path: [.literal("/v1/bookings/"), .slot("id"), .literal("/confirm")])
    let written = apiPartsWrite(
        draft: draft, field: .path, edit: .text(index: 2, "/cancel"), pane: "api-1")
    #expect(pathParts(written) == [
        .object(["literal": .string("/v1/bookings/")]),
        .object(["slot": .string("id")]),
        .object(["literal": .string("/cancel")]),
    ])
}

@Test("+ hole appends the slot and an empty place to keep typing")
func appendingAHoleLeavesSomewhereToType() {
    let draft = request(path: [.literal("/v1/bookings/")])
    let written = apiPartsWrite(draft: draft, field: .path, edit: .appendHole("id"), pane: "api-1")
    // The empty literal is not WRITTEN — an empty literal is not a wire state — so the
    // trailing box is the view's, drawn after any trailing hole (Task 4).
    #expect(pathParts(written) == [
        .object(["literal": .string("/v1/bookings/")]),
        .object(["slot": .string("id")]),
    ])
}

@Test("A hole's name is kept exactly as typed", arguments: [" id", "id ", "ID", "booking id"])
func aHoleNameIsKeptExactly(name: String) {
    let written = apiPartsWrite(
        draft: request(path: []), field: .path, edit: .appendHole(name), pane: "api-1")
    #expect(pathParts(written) == [.object(["slot": .string(name)])])
}

@Test("A blank hole name is refused before anything is dispatched", arguments: ["", "   ", "\t"])
func aBlankHoleNameIsRefused(name: String) {
    #expect(apiPartsWrite(
        draft: request(path: []), field: .path, edit: .appendHole(name), pane: "api-1") == nil)
}

@Test("An emptied literal between two holes is dropped, and both holes survive")
func anEmptiedLiteralBetweenHolesIsDropped() {
    let draft = request(path: [.slot("a"), .literal("-"), .slot("b")])
    let written = apiPartsWrite(draft: draft, field: .path, edit: .text(index: 1, ""), pane: "p")
    #expect(pathParts(written) == [
        .object(["slot": .string("a")]), .object(["slot": .string("b")]),
    ])
}

@Test("× on an unbound hole removes that part and nothing else")
func removingAHoleRemovesOnlyIt() {
    let draft = request(path: [.literal("/x/"), .slot("id"), .literal("/y")])
    let written = apiPartsWrite(draft: draft, field: .path, edit: .remove(index: 1), pane: "p")
    #expect(pathParts(written) == [
        .object(["literal": .string("/x/")]), .object(["literal": .string("/y")]),
    ])
}

@Test("Typing into the trailing box past the last part appends a literal")
func typingPastTheEndAppends() {
    let draft = request(path: [.literal("/v1/"), .slot("id")])
    let written = apiPartsWrite(draft: draft, field: .path, edit: .text(index: 2, "/confirm"),
                                pane: "p")
    #expect(pathParts(written)?.last == .object(["literal": .string("/confirm")]))
}

@Test("A query row's value is written with the whole region, the row's holes carried")
func aQueryRowCarriesItsRegion() {
    let draft = request(path: [], query: [
        ApiQueryRow(name: "expand", value: [.literal("lines")]),
        ApiQueryRow(name: "id", value: [.slot("id")]),
    ])
    let written = apiPartsWrite(draft: draft, field: .query("expand"),
                                edit: .text(index: 0, "guest"), pane: "p")
    guard case .object(let fields)? = written, case .array(let rows)? = fields["query"] else {
        Issue.record("no query region written"); return
    }
    #expect(rows.count == 2)
    #expect(rows[1] == .object(["name": .string("id"),
                                "value": .array([.object(["slot": .string("id")])])]))
}
```

`ApiRequestSnapshot`'s memberwise `init` is public (`ApiSnapshot.swift`), and its query rows
are `ApiQueryRow`; header rows are `ApiHeaderRegionRow`, whose `value` is optional and whose
`isEditable` is false for Wakil's own rows.

- [ ] **Step 2: Run and watch every test fail.**
  `make app-test 2>&1 | grep -E "ApiHandBind|error:" | head -30` — expect `cannot find
  'apiPartsWrite' in scope`.
- [ ] **Step 3: Implement.**

```swift
/// What a split field's gesture writes (spec §1).
///
/// **The whole field, always.** `api_set_request` has one write per region, so a field's new
/// part list is computed here and sent entire — its holes carried as `{"slot":}` so that no
/// gesture's work is lost to a keystroke's.
///
/// **A bound part is never carried**, because `api_set_request` refuses one
/// (`boundValueIsAGesture`). A field holding one is read-only (`apiFieldIsTypable`), so no
/// caller reaches this with one; if one does, the part is written as its slot name rather
/// than as a binding, which `api_set_request` accepts and which loses nothing a hand could
/// have kept — and `apiFieldIsTypable` is what stops it happening at all.
public func apiPartsWrite(
    draft: ApiRequestSnapshot, field: ApiDraftField, edit: ApiPartsEdit, pane: String
) -> JSONValue? {
    var parts = apiFieldParts(draft, field)
    switch edit {
    case .text(let index, let text):
        if index < parts.count {
            if text.isEmpty { parts.remove(at: index) } else { parts[index] = .literal(text) }
        } else if !text.isEmpty {
            parts.append(.literal(text))
        }
    case .appendHole(let name):
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        parts.append(.slot(name))
    case .remove(let index):
        guard parts.indices.contains(index) else { return nil }
        parts.remove(at: index)
    }
    let written: [JSONValue] = parts.map { part in
        switch part {
        case .literal(let text): return .object(["literal": .string(text)])
        case .slot(let name): return .object(["slot": .string(name)])
        case .bound(let bound): return .object(["slot": .string(bound.name)])
        }
    }
    var params: [String: JSONValue] = ["pane": .string(pane)]
    switch field {
    case .path: params["path"] = .array(written)
    case .body: params["body"] = .array(written)
    case .query(let name), .header(let name):
        let base = apiDraftForWrite(draft)
        let rows: [(name: String, value: [ApiPart])] = {
            if case .query = field { return base.query.map { ($0.name, $0.value) } }
            return base.headers.map { ($0.name, $0.value) }
        }()
        let region: JSONValue = .array(rows.map { row in
            .object([
                "name": .string(row.name),
                "value": row.name == name
                    ? .array(written)
                    : .array(row.value.map { apiPartJSON($0, sources: [:]) }),
            ])
        })
        params[{ if case .query = field { return "query" } else { return "headers" } }()] = region
    case .method, .contentType:
        return nil
    }
    return .object(params)
}

public func apiFieldParts(_ request: ApiRequestSnapshot, _ field: ApiDraftField) -> [ApiPart] {
    switch field {
    case .path: return request.path
    case .body: return request.body
    case .query(let name): return request.query.first { $0.name == name }?.value ?? []
    case .header(let name):
        return request.headers.first { $0.name == name && $0.isEditable }?.value ?? []
    case .method, .contentType: return []
    }
}
```

- [ ] **Step 4: Run and watch it pass.** `make app-test 2>&1 | grep -E "ApiHandBind|passed|failed" | tail -15`
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiActions.swift app/Tests/WakilKitTests/ApiHandBindTests.swift
git commit -m "apiPartsWrite: a split field's three gestures write the whole field"
```

### Task 3: The locking rule — a binding is never typed over

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift` — beside `apiRowIsTypable` (~line 1663)
- Test: `app/Tests/WakilKitTests/ApiHandBindTests.swift`

**Interfaces:**
- Consumes: `apiRowIsTypable(_:)`, `ApiRequestSnapshot`.
- Produces:
  ```swift
  /// Whether a field can be typed into, `+ hole`d, or have a hole removed.
  public func apiFieldIsTypable(_ request: ApiRequestSnapshot, _ field: ApiDraftField) -> Bool
  ```

**The two defects this closes** (spec, *A defect found while designing this*; Amendment 2): the
path and body were always typable over a binding, and a query or header region written whole
carried a bound neighbour that `api_set_request` refuses.

- [ ] **Step 1: Write the failing tests.** A bound value needs an `ApiBoundValue`.
  `ApiBindTests.swift` has `private func liveBinding(name:generation:)` and the `valueSource`
  it calls; **move both** to a new `app/Tests/WakilKitTests/ApiTestSupport.swift` as
  `internal`, unchanged, and call `liveBinding(name:)` from both files. Reuse, never a copy.

```swift
@Test("A path or body holding a bound value cannot be typed into")
func aBoundFieldIsNotTypable() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(!apiFieldIsTypable(request(path: [.literal("/b/"), bound]), .path))
    #expect(!apiFieldIsTypable(request(path: [], body: [bound]), .body))
    #expect(apiFieldIsTypable(request(path: [.literal("/b/"), .slot("id")]), .path))
}

@Test("A region holding a bound row locks whole, not only that row")
func aRegionHoldingABoundRowLocksWhole() {
    let draft = request(path: [], query: [
        ApiQueryRow(name: "expand", value: [.literal("lines")]),
        ApiQueryRow(name: "id", value: [.bound(liveBinding(name: "id"))]),
    ])
    // `expand` holds only a literal and is STILL locked: its write would carry `id`, and
    // `api_set_request` refuses a bound part with boundValueIsAGesture.
    #expect(!apiFieldIsTypable(draft, .query("expand")))
    #expect(!apiFieldIsTypable(draft, .query("id")))
    #expect(apiFieldIsTypable(draft, .path))
}
```

- [ ] **Step 2: Run and watch both fail** (`cannot find 'apiFieldIsTypable'`).
- [ ] **Step 3: Implement.**

```swift
/// Whether a field can be typed into (spec §1, the locking rule; Amendment 2).
///
/// **The whole field, and for a row the whole REGION.** A write is the whole field, and a
/// row's write is the whole region (`apiRowWrite`, #190) — so one bound part anywhere in what
/// the write would carry makes the write one `api_set_request` refuses. Locking only the chip
/// would leave a text box whose every commit is refused.
public func apiFieldIsTypable(_ request: ApiRequestSnapshot, _ field: ApiDraftField) -> Bool {
    switch field {
    case .path: return apiRowIsTypable(request.path)
    case .body: return apiRowIsTypable(request.body)
    case .query: return request.query.allSatisfy { apiRowIsTypable($0.value) }
    case .header:
        return request.headers.allSatisfy { !$0.isEditable || apiRowIsTypable($0.value ?? []) }
    case .method, .contentType: return true
    }
}
```

- [ ] **Step 4: Run and watch it pass.**
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiActions.swift app/Tests/WakilKitTests/
git commit -m "A binding is never typed over: the path, the body, and a whole region lock"
```

### Task 4: The split field on screen, and the `+ hole` check

**Files:**
- Modify: `app/Sources/WakilApp/ApiPane.swift` — `parts(_:)` (~line 378), `field(...)` (~429),
  the path row (~139), `queryRegion`/header region/body region
- Create: `e2e/checks/seeded/api-hole.jsonl`

**Interfaces:**
- Consumes: `apiPartsWrite`, `apiFieldParts`, `apiFieldIsTypable`, `ApiPartsEdit` (Tasks 2–3).
- Produces: a view builder `splitField(_ base: String, _ field: ApiDraftField, multiline: Bool)`
  used for all four places; identifiers per the Global constraints.

- [ ] **Step 1: Write the check first** — `e2e/checks/seeded/api-hole.jsonl`:

```jsonl
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"do":{"type":{"into":"api.path","text":"/v1/bookings/"}}}
{"do":{"press":"Return"}}
{"do":{"click":"api.path.hole"}}
{"do":{"type":{"into":"api.path.hole.name","text":"id"}}}
{"do":{"press":"Return"}}
{"expect":{"pane":"api-1","field":"request.path[1].slot","equals":"id"}}
{"do":{"type":{"into":"api.path","text":"/confirm"}}}
{"do":{"press":"Return"}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/v1/bookings/"}}
{"expect":{"pane":"api-1","field":"request.path[1].slot","equals":"id"}}
{"expect":{"pane":"api-1","field":"request.path[2].literal","equals":"/confirm"}}
{"do":{"click":"api.path.part.1.remove"}}
{"expect":{"pane":"api-1","field":"request.path","absent":"slot"}}
{"do":{"click":"api.path.hole"}}
{"do":{"type":{"into":"api.path.hole.name","text":"   "}}}
{"do":{"press":"Return"}}
{"expect":{"tree":"contains","text":"a hole needs a name"}}
{"parity":{"action":"api_set_request","params":{"pane":"api-1","path":[{"literal":"/v1/bookings/"},{"slot":"id"}]},"click":"api.path.hole","assert":"read_pane"}}
```

Before relying on `"absent"` inside a pane `expect`, read `e2e/driver/check.go`'s pane-expect
predicates; if only `equals`/`contains` exist, assert `request.path[1].literal` equals
`/confirm` instead. **The parity line cannot use a click that opens a name box** — if the
parity runner needs the click alone to change state, replace it with a `do` sequence plus a
`dispatch` and two `expect`s of the same field, and note why in the check's commit message.

- [ ] **Step 2: `make e2e-new` — watch it fail** against the merge-base (no `api.path.hole`).
- [ ] **Step 3: Build the split field.** Replace the path row's single `field(...)`, and the
  query/header/body value fields, with:

```swift
/// A field of parts (spec §1): literal boxes, chips between them, `+ hole` at the end.
///
/// **The last literal box keeps the field's own identifier** (Amendment 3), so typing
/// continues where every shipped check already types.
@ViewBuilder
private func splitField(_ base: String, _ draftField: ApiDraftField, multiline: Bool = false)
    -> some View
{
    let parts = apiFieldParts(snapshot.request, draftField)
    let typable = apiFieldIsTypable(snapshot.request, draftField)
    // The trailing box sits after the last part unless the last part is itself a literal.
    let trailing: Int = {
        if case .literal = parts.last { return parts.count - 1 }
        return parts.count
    }()
    HStack(spacing: 2) {
        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
            switch part {
            case .literal(let text):
                if typable {
                    literalBox(index == trailing ? base : "\(base).part.\(index)",
                               draftField, index: index, text: text, multiline: multiline)
                } else {
                    Text(text).foregroundStyle(ink.opacity(0.85))
                }
            case .slot(let name):
                chip(name, filled: false)
                if typable {
                    chipButton("×", "\(base).part.\(index).remove") {
                        write(draftField, .remove(index: index))
                    }
                }
            case .bound(let value):
                chip(value.name, filled: true)
                chipButton("×", "\(base).part.\(index).unbind") {
                    dispatch("api_unbind", .object([
                        "pane": .string(pane.id),
                        "region": .string(apiRegionName(draftField)),
                        "index": .number(Double(index)),
                    ]))
                }
            }
        }
        if typable {
            if trailing == parts.count {
                literalBox(base, draftField, index: parts.count, text: "", multiline: multiline)
            }
            holeControl(base, draftField)
        }
    }
}

private func write(_ draftField: ApiDraftField, _ edit: ApiPartsEdit) {
    guard let params = apiPartsWrite(
        draft: snapshot.request, field: draftField, edit: edit, pane: pane.id)
    else { return }
    dispatch("api_set_request", params)
}
```

`apiRegionName(_:)` returns `api_unbind`'s `region` string for a field — read `api_unbind`'s
handler (`ApiActions.swift` ~line 781) for the exact names it accepts and add the function to
`ApiActions.swift` with a one-line test in `ApiHandBindTests.swift` per region. `literalBox`
is today's `field(...)` with `commit: { write(draftField, .text(index: index, $0)) }` and a
`TextEditor` when `multiline`. `chip` is today's `.chip` drawing lifted into a function.
`chipButton` is a `Button` with `.buttonStyle(.plain)`, 9pt, `ink.opacity(0.5)`, and the
identifier. `holeControl` is a `Button("+ hole")` with id `"\(base).hole"` that sets
`@State holeNaming: String?` to `base`; while it equals `base`, draw a `TextField("name")` with
id `"\(base).hole.name"`, `.onSubmit` calling `write(draftField, .appendHole(text))` — when
`apiPartsWrite` returns `nil`, set `@State holeRefusal = "a hole needs a name"` and draw it
beside the box in amber — and `.onExitCommand` clearing `holeNaming`.

Delete `pathText` and the path's old `field(...)` call; `apiFieldWrite` stays for `.method`
and `.contentType` only — change its `.path`/`.body` arms to `fatalError` is **not** allowed;
leave them, and leave its tests, because the agent-facing tests pin them.

- [ ] **Step 4: `make app-test` green; `make app-bundle`; `make e2e` green, including every
  shipped `api-*.jsonl` unchanged.** If a shipped check fails on an identifier, stop — the
  Global constraint says the plan was wrong.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilApp/ApiPane.swift app/Sources/WakilKit/Api/ApiActions.swift \
  app/Tests/WakilKitTests/ApiHandBindTests.swift e2e/checks/seeded/api-hole.jsonl
git commit -m "The operator can make a hole: split fields, + hole, and × on an unbound one"
```

Then: `superpowers:requesting-code-review` for Phase 1.

---

## Phase 2 — The fixture and the drag act

### Task 5: The seeded SQLite file (#308)

**Files:**
- Modify: `e2e/driver/seed.go` — after `project.json` is written (~line 290)
- Test: `e2e/driver/seed_test.go`

**Interfaces:**
- Produces: `const FixtureBookingsFile = "bookings.db"` and `func seedBookings(root string)
  error`, called by `Seed` — a file at `<fixture root>/bookings.db`.

**Why the seed writes only the file** — Amendment 1: the fixture keychain is recreated at
launch, after `Seed`, so the DSN is stored by the check through `db_set_dsn`.

- [ ] **Step 1: Write the failing test.**

```go
func TestSeedWritesTheBookingsDatabase(t *testing.T) {
	root := t.TempDir()
	if err := seedBookings(root); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(root, FixtureBookingsFile))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var bookingID string
	// The demo row: a hole named `id` must take 8842 and never BK-2026-8842.
	if err := db.QueryRow(`SELECT booking_id FROM bookings WHERE id = 8842`).Scan(&bookingID); err != nil {
		t.Fatal(err)
	}
	if bookingID != "BK-2026-8842" {
		t.Fatalf("booking_id = %q", bookingID)
	}
	var count int
	_ = db.QueryRow(`SELECT count(*) FROM bookings`).Scan(&count)
	if count != 2 {
		t.Fatalf("rows = %d, want 2", count)
	}
}

func TestSeedingBookingsTwiceIsNotAnError(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 2; i++ {
		if err := seedBookings(root); err != nil {
			t.Fatalf("seed %d: %v", i, err)
		}
	}
}
```

Import the driver the way `wakilcore/driver_sqlite.go` does (blank import of its sqlite
package) — read it and copy the import line.

- [ ] **Step 2: `go test ./e2e/driver -run Bookings` — watch it fail.**
- [ ] **Step 3: Implement** `seedBookings`: remove any existing file, open, `CREATE TABLE
  bookings(id INTEGER PRIMARY KEY, booking_id TEXT, status TEXT)`, insert `(8842,
  'BK-2026-8842', 'held')` and `(8843, 'BK-2026-8843', 'confirmed')`, close. Call it from `Seed`
  with `fixture.Root`. Comment it with Amendment 1's reason in two sentences.
- [ ] **Step 4: `make test` green.**
- [ ] **Step 5: Commit.**

```bash
git add e2e/driver/seed.go e2e/driver/seed_test.go
git commit -m "The fixture seeds a bookings table, so a pane can hold a row to drop (#308)"
```

### Task 6: The drop's rulings — `apiDropRow` and `apiBindSummary`

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`
- Test: `app/Tests/WakilKitTests/ApiHandBindTests.swift`

**Interfaces:**
- Consumes: `PaneRow`, `PaneCell`.
- Produces:
  ```swift
  public struct ApiDragPayload: Sendable, Equatable, Codable {
      public let pane: String
      public let index: Int
      public let cells: [String?]          // PaneCell.text, nil when isNull
      public init(pane: String, row: PaneRow)
  }
  public func apiDropRow(_ picked: ApiDragPayload, current: [PaneRow]) -> Int?
  public enum ApiBindOutcome: Sendable, Equatable { case result(JSONValue), refused(String) }
  public struct ApiBindLine: Sendable, Equatable { public let text: String; public let caution: Bool }
  public func apiBindSummary(_ outcome: ApiBindOutcome) -> ApiBindLine
  public let apiDropMovedRefusal = "the grid changed while the row was being dragged — drop it again"
  ```

- [ ] **Step 1: Write the failing tests.**

```swift
private func row(_ id: Int, _ values: [JSONValue]) -> PaneRow {
    PaneRow(id: id, cells: values.map(PaneCell.init))
}

@Test("An unchanged row is the row picked up")
func anUnchangedRowDrops() {
    let rows = [row(0, [.integer(8842), .string("BK-2026-8842")]),
                row(1, [.integer(8843), .string("BK-2026-8843")])]
    #expect(apiDropRow(ApiDragPayload(pane: "db-1", row: rows[1]), current: rows) == 1)
}

@Test("A re-sort that put another row at the index is not the row picked up")
func aResortedRowIsNotTheRowPickedUp() {
    let before = [row(0, [.integer(8842)]), row(1, [.integer(8843)])]
    let after = [row(0, [.integer(8843)]), row(1, [.integer(8842)])]
    #expect(apiDropRow(ApiDragPayload(pane: "db-1", row: before[0]), current: after) == nil)
}

@Test("An index past the end refuses")
func anIndexPastTheEndRefuses() {
    let before = [row(0, [.integer(1)]), row(1, [.integer(2)])]
    #expect(apiDropRow(ApiDragPayload(pane: "db-1", row: before[1]),
                       current: [before[0]]) == nil)
}

@Test("A null is not an empty string")
func aNullIsNotAnEmptyString() {
    let picked = ApiDragPayload(pane: "db-1", row: row(0, [.null]))
    #expect(apiDropRow(picked, current: [row(0, [.string("")])]) == nil)
}

@Test("The result line", arguments: [
    (#"{"filled":2,"rebound":0,"unmatched":[]}"#, "Filled 2", false),
    (#"{"filled":2,"rebound":1,"unmatched":[]}"#, "Filled 2 · re-bound 1", false),
    (#"{"filled":1,"rebound":0,"unmatched":["booking_ref","guest"]}"#,
     "Filled 1 · no column for booking_ref, guest", false),
    (#"{"filled":0,"rebound":0,"unmatched":["id"]}"#, "No hole matches a column of this row", true),
])
func theResultLine(json: String, text: String, caution: Bool) throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    #expect(apiBindSummary(.result(value)) == ApiBindLine(text: text, caution: caution))
}

@Test("A refusal is drawn in its own words")
func aRefusalIsItsOwnWords() {
    #expect(apiBindSummary(.refused("api_bind: no such row")).text == "api_bind: no such row")
}
```

- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement.** `ApiDragPayload.init(pane:row:)` maps `row.cells` to
  `$0.isNull ? nil : $0.text` and takes `row.id` as `index`. `apiDropRow` returns `index` when
  `current.indices.contains(index)` and the current row's cells map to the same `[String?]`,
  else `nil`. `apiBindSummary` reads `filled`/`rebound` through `intValue` (never `case
  .number` — `api_bind`'s own comment records why) and `unmatched` as strings: zero filled and
  zero rebound → the caution line; otherwise `Filled N`, then ` · re-bound N` when non-zero,
  then ` · no column for ` + the misses joined by `", "` when any.
- [ ] **Step 4: Run and watch it pass.**
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiActions.swift app/Tests/WakilKitTests/ApiHandBindTests.swift
git commit -m "A drop binds the row picked up or refuses, and says what it filled once"
```

### Task 7: The drag act — `axresolve --drag-to`, and a `drag` arm on `do` and `parity`

**Files:**
- Modify: `e2e/axresolve/main.swift` — a `--drag-to <identifier>` mode beside `--press` (~line 287)
- Modify: `e2e/driver/axresolve.go` — `func (r Resolver) Drag(pid int, from, to string) (Response, error)`
- Modify: `e2e/driver/check.go` — `Do.Drag *DragStep`, `Parity.Drag *DragStep`, `validateDo`,
  `Describe`, the parity validator
- Modify: `e2e/driver/run.go` — the `do` switch (~line 467) and `parity` (~line 856)
- Modify: `e2e/driver/coverage.go` — a drag's `From` counts as exercised
- Test: `e2e/driver/check_test.go`, `e2e/driver/coverage_test.go`

**Interfaces:**
- Consumes: Task 1's recorded event sequence (the amendment).
- Produces: `type DragStep struct { From string \`json:"from"\`; To string \`json:"to"\` }`;
  in a check, `{"do":{"drag":{"from":"db.row.0.grip","to":"api.pane"}}}` and
  `{"parity":{"action":"api_bind","params":{…},"drag":{"from":…,"to":…},"assert":"read_pane"}}`.
  The api pane's root carries `.accessibilityIdentifier("api.pane")` — added in Task 8.

- [ ] **Step 1: Write the failing Go tests.**

```go
func TestADoDragParses(t *testing.T) {
	checks, err := ParseChecks(strings.NewReader(
		`{"do":{"drag":{"from":"db.row.0.grip","to":"api.pane"}}}` + "\n" +
			`{"expect":{"tree":"contains","text":"x"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := checks[0].Do.Describe(); got != "drag db.row.0.grip onto api.pane" {
		t.Fatalf("Describe = %q", got)
	}
}

func TestADragWithNoTargetIsRefused(t *testing.T) {
	_, err := ParseChecks(strings.NewReader(`{"do":{"drag":{"from":"db.row.0.grip"}}}`))
	if err == nil || !strings.Contains(err.Error(), "drag") {
		t.Fatalf("err = %v", err)
	}
}

func TestAParityCarriesExactlyOneOfClickAndDrag(t *testing.T) {
	_, err := ParseChecks(strings.NewReader(
		`{"parity":{"action":"api_bind","click":"a","drag":{"from":"b","to":"c"},"assert":"tree"}}`))
	if err == nil {
		t.Fatal("a parity with both a click and a drag was accepted")
	}
}

func TestADragParityCountsAsParityAndExercisesTheGrip(t *testing.T) {
	checks, _ := ParseChecks(strings.NewReader(
		`{"parity":{"action":"api_bind","params":{"pane":"api-1"},"drag":{"from":"db.row.0.grip","to":"api.pane"},"assert":"read_pane"}}`))
	cover := CoverageOf(checks)
	if !cover.HasParity("api_bind") || !cover.Exercised("db.row.0.grip") {
		t.Fatal("a drag parity did not count")
	}
}
```

Read `check_test.go` and `coverage_test.go` first for the real names of `ParseChecks`,
`CoverageOf` and the exercised accessor, and use them — these tests are written against the
shape, not a guess to be kept.

- [ ] **Step 2: `go test ./e2e/driver -run 'Drag'` — watch them fail.**
- [ ] **Step 3: Implement.** In `axresolve`: resolve both identifiers to frames with the
  existing `frame(of:)`, post Task 1's recorded sequence from the source centre to the target
  centre, and report `acted: true, verified: false` — a drag, like a press, reports no outcome;
  the runner's rule that an unverified act must be confirmed by a later positive read is what
  establishes it landed. In Go: the `do` arm calls `r.Resolver.Drag`; the parity runner uses
  the drag half where it used `Press` today, with the same *"changed nothing"* refusal; the
  coverage walker marks `Drag.From` exercised; `validateDo` and `Describe` gain the arm, and the
  arm count in both error messages becomes seven.
- [ ] **Step 4: `make test` green; `make axresolve` builds.**
- [ ] **Step 5: Commit.**

```bash
git add e2e/axresolve/main.swift e2e/driver/
git commit -m "The harness can drag: an axresolve mode, and a drag arm on do and parity"
```

Then: `superpowers:requesting-code-review` for Phase 2.

---

## Phase 3 — The drop and the unbind, on screen

### Task 8: The grip, the drop, the result line, and the checks that close the gate

**Files:**
- Modify: `app/Sources/WakilApp/DataSurface.swift` — the row (~line 615), per Task 1's finding
- Modify: `app/Sources/WakilApp/ApiPane.swift` — root `.dropDestination`, `api.pane`,
  `api.bind.result`, a `bind` closure
- Modify: `app/Sources/WakilApp/Canvas.swift` — pass `bind` into `ApiPane` (~line 346)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `bindFromSurface`
- Modify: `e2e/driver/identifiers.go` — `DataSurface.swift` joins `AuditedSources` if it is not
  already there
- Create: `e2e/checks/seeded/api-bind.jsonl`, `api-unbind.jsonl`, `api-bound-locks.jsonl`

**Interfaces:**
- Consumes: `ApiDragPayload`, `apiDropRow`, `apiBindSummary`, `ApiBindOutcome`,
  `apiDropMovedRefusal` (Task 6); `DragStep` (Task 7); `splitField`'s `.unbind` (Task 4);
  `bookings.db` (Task 5).
- Produces: `WindowModel.bindFromSurface(pane: String, source: String, row: Int) async ->
  ApiBindOutcome` — `api_bind` through the SAME `registry.dispatch` with `origin: .ui`, then
  `refreshPanes()`, returning the result or `String(describing: error)`.

**Why a second dispatch entry on `WindowModel`.** `dispatch(_:_:)` answers every caller's
question — *did something run?* — and sends a refusal to the window-wide `status` line. The
result line needs the result's counts and the refusal's own words in the pane that was dropped
on. It is the same registry call with the same origin, so Invariant 2 is untouched; only what
comes back is kept.

- [ ] **Step 1: Write the checks.** All three open the same way:

```jsonl
{"dispatch":{"action":"db_set_dsn","params":{"projectPath":"{fixtureRoot}/e2e-project/.wakil/project.json","environment":"staging","name":"bookings","driver":"sqlite","dsn":"{fixtureRoot}/bookings.db"}}}
{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}
{"dispatch":{"action":"db_run_query","params":{"pane":"db-1","database":"bookings","query":"SELECT * FROM bookings ORDER BY id"}}}
{"expect":{"pane":"db-1","field":"grid.rowCount","equals":"2"}}
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-2","path":[{"literal":"/v1/bookings/"},{"slot":"id"},{"literal":"/confirm"}]}}}
```

Read `2e-settings-databases.jsonl` and `db_set_dsn`'s handler for the exact `projectPath` the
fixture uses, `pane_open`'s `kind` value for a DB pane, and the pane ids the fixture assigns (a
second pane may be `api-2` or `api-1`) — correct the lines above to what is true before running.

`api-bind.jsonl`, after the opening:

```jsonl
{"parity":{"action":"api_bind","params":{"pane":"api-2","source":"db-1","row":0},"drag":{"from":"db.row.0.grip","to":"api.pane"},"assert":"read_pane"}}
{"expect":{"pane":"api-2","field":"request.path[1].preview","equals":"8842"}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"expect":{"tree":"contains","text":"Filled 1"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-2","query":[{"name":"ref","value":[{"slot":"booking_ref"}]}]}}}
{"do":{"drag":{"from":"db.row.1.grip","to":"api.pane"}}}
{"expect":{"tree":"contains","text":"no column for booking_ref"}}
```

`api-unbind.jsonl`, after the opening:

```jsonl
{"do":{"drag":{"from":"db.row.0.grip","to":"api.pane"}}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"parity":{"action":"api_unbind","params":{"pane":"api-2","region":"path","index":1},"click":"api.path.part.1.unbind","assert":"read_pane"}}
{"expect":{"pane":"api-2","field":"request.path[1].slot","equals":"id"}}
```

The unbind parity's dispatch half runs on an already-unbound slot; if `api_unbind` refuses a
non-binding (`unbindNotABinding`), the parity runner reports the dispatch half refused. In that
case re-drag between the halves is not expressible — replace the parity with: drag, click
`.unbind`, expect the slot; drag, dispatch `api_unbind`, expect the slot, and record in the
commit message that the two halves were compared by two identical `expect`s because the action
is not idempotent.

`api-bound-locks.jsonl`, after the opening:

```jsonl
{"do":{"drag":{"from":"db.row.0.grip","to":"api.pane"}}}
{"expect":{"tree":"absent","text":"+ hole"}}
{"expect":{"tree":"contains","text":"/confirm"}}
{"do":{"click":"api.path.part.1.unbind"}}
{"expect":{"tree":"contains","text":"+ hole"}}
```

- [ ] **Step 2: `make e2e-new` — watch all three fail** against the merge-base.
- [ ] **Step 3: Build.**
  - **The grip** (spec Amendment 5 — the operator's revision): a **leading gutter** on every
    row, `gripGutter = 14` pt, which `paneColumnLayout`'s available width is reduced by so the
    columns start after it — **never an overlay on a cell**. In it, one `Text("\u{22EE}")`
    (`⋮`), 11pt, `ink.opacity(hoveredRow == row.id ? 0.55 : 0.30)`, centred, on every row. The
    header row gets the same empty gutter so the columns stay aligned. The anchor row's luminous
    left edge stays at the very edge, outside the grip. **Over the grip the pointer is an open
    hand:** on the grip alone (not the row), `.onHover` pushes `NSCursor.openHand` and sets a
    `@State gripHovered` flag, and pops it on exit — `.pointerStyle` is macOS 15, the target is
    14.4. `.onDisappear` pops **only if `gripHovered` is set**, so a row scrolled away mid-hover
    cannot leave the hand stuck on, and a grip that never pushed never pops someone else's
    cursor. Placed as Task 1 measured — outside
    `.accessibilityElement(children: .ignore)` so the grip is its own AX element — with
    `.draggable(ApiDragPayload(pane: pane.id, row: row))` and
    `.accessibilityIdentifier("db.row.\(row.id).grip")`. `ApiDragPayload` becomes
    `Transferable` in `WakilApp` with `CodableRepresentation(contentType: .wakilDragRow)`, a
    `UTType(exportedAs: "com.wakil.drag-row")` declared in the same file — exported types need
    an `Info.plist` entry; if the bundle's plist is generated by `make app-bundle`, add it
    there and say so in the commit.
  - **The drop**, on `ApiPane`'s root: `.accessibilityIdentifier("api.pane")` on the root
    container, and `.dropDestination(for: ApiDragPayload.self) { items, _ in … } isTargeted:
    { dropTargeted = $0 }`. The action looks up the source pane's current rows through a new
    `sourceRows: (String) -> [PaneRow]` closure passed from `Canvas` (read from
    `model`'s grid snapshot for that pane), calls `apiDropRow`; `nil` sets the result line to
    `ApiBindLine(text: apiDropMovedRefusal, caution: true)`; an index calls `bind(source,
    index)` and sets the line to `apiBindSummary(outcome)`. While `dropTargeted`, overlay a
    `RoundedRectangle` stroke at the focus ring's colour and width — read the focus ring's
    modifier in `Canvas.swift` and use its values.
  - **The result line**: `Text(line.text)` with id `api.bind.result`, amber when `caution`,
    `ink.opacity(0.7)` otherwise; cleared (set `nil`) in `write(...)` and in the Send control's
    action.
- [ ] **Step 3b: Remove section 3 of `e2e/checks/uncoverable.tsv` whole.** #317 (merged,
  `fdd055d`) added `# ---- 3. Blocked on #308, the fixture has no database` with its comment
  block and the `api_bind` and `api_unbind` lines. Delete the header, its comment block and both
  lines, **and** the `#   3. blocked on #308 — the fixture has no database` line in the
  top-of-file list of entry kinds, so the file names no empty section. They go in this commit
  because this is the commit whose checks make them false. `api_reopen`'s line stays — nothing
  here lets a check carry a row id from `read_pane` into a dispatch.
- [ ] **Step 4: `make app-test`, `make app-bundle`, `make e2e` all green; `make e2e-new` saw
  the three red; **and the gate measured from BEFORE 2c-iv names neither `api_bind` nor
  `api_unbind`**: `go run ./e2e/cmd/wakil-e2e-cover --trunk 18f9762`. Against the default
  trunk that claim holds trivially, because both actions predate this branch's merge-base (#305's
  family) — so the default-trunk run proves nothing about them.** Paste the
  gate's `writes:` line into the commit message.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/ e2e/driver/identifiers.go e2e/checks/seeded/
git commit -m "The operator can drop a row on a hole, and unbind it, and the gate is clear (#308)"
```

Then: `superpowers:requesting-code-review` for Phase 3.

---

## Phase 4 — The runbook

### Task 9: The walk says what is now true

**Files:**
- Modify: `docs/wakil/phase-2c-iv-acceptance.md`

- [ ] **Step 1:** Delete the paragraph that begins **"The drop gesture does not exist."** under
  *What this walk CANNOT establish*. Keep *"No check has ever drawn a reply"* — still true.
- [ ] **Step 2:** Rewrite check 4, keeping the count at ten:

```markdown
- [ ] **4. A request built entirely by hand reaches a real server.** Against a live
      entry: pick it from the chooser, type a path, **make a hole in it with `+ hole`, open
      a DB pane on a table whose column matches the hole's name, and drag a row's grip onto
      the api pane** — the chip fills. Add a query row, a header, a content type and a body,
      press Send. **Every step by hand, no agent.** That is the sub-phase's exit criterion,
      both clauses, and no check can prove it, because every check sends at an `.invalid`
      host and has never drawn a reply.
```

- [ ] **Step 2b: Correct the header's *"the coverage gate passes"*.** It was true per PR and
  false for the phase: #310 added `api_bind`, `api_unbind` and `api_reopen`, and every later PR
  in the stack gated against a merge-base that already had them (#305's family, measured by
  #317 against `18f9762`). Say that, dated, and say which of the three this branch closed.
- [ ] **Step 3:** Update the header's *Cover rung* line to add this branch's PR, and re-render
  the machine half: `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2c-iv-acceptance.md`. Nothing
  between the markers is edited by hand.
- [ ] **Step 4: Commit.**

```bash
git add docs/wakil/phase-2c-iv-acceptance.md
git commit -m "2c-iv's runbook: the drop exists, and check 4 walks both clauses by hand"
```

- [ ] **Step 5:** `superpowers:finishing-a-development-branch` — the PR body says `Closes #308`.
  **2c-iv is not `Met` until the operator walks the ten.** No agent fills §8's `Met` column or
  writes the `phase-log.md` entry for the walk.

---

## Gate — the plan is done when

- [ ] `make test`, `make app-test`, `make e2e` green
- [ ] `make e2e-new` saw `api-hole`, `api-bind`, `api-unbind` and `api-bound-locks` red against
      the merge-base
- [ ] `go run ./e2e/cmd/wakil-e2e-cover --trunk 18f9762` names neither `api_bind` nor
      `api_unbind`, and `uncoverable.tsv` has no section 3
- [ ] No shipped check changed an identifier
- [ ] The runbook is re-rendered, ten checks, and the drop paragraph is gone
