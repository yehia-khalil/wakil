# Integer Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `JSONValue` carry whole numbers exactly, so a database key above 2^53 is displayed, sorted and reported to the agent as the value the database actually holds.

**Architecture:** `JSONValue` gains a second numeric case, `case integer(Int64)`, decoded before `Double`. The danger is not the case — it is that twelve of the fourteen sites reading `.number` are `if case` / `guard case` patterns, which do **not** fail to compile when a case is added; they silently stop matching. So accessors are introduced first, every reading site is migrated to them, a `grep` proves none are left, and only then does the case exist.

**Tech Stack:** Swift 6, SwiftPM, swift-testing (`@Test` / `#expect`), `app/Sources/WakilKit`.

**Spec:** `docs/superpowers/specs/2026-09-13-integer-fidelity-design.md`

## Global Constraints

- **Build:** `make app-build`. **Test:** `make app-test`. Both from the repository root. Never `cd` out of the worktree.
- **`WakilApp` has no test target and cannot have one.** Any decision that must be tested lives in `WakilKit`. This plan touches `WakilApp` in no task.
- **Nothing in `internal/wakilcore` or `cmd/` changes.** The wire format is unchanged; Go emits `9007199254740993` before and after.
- **`JSONValue` does not gain `Hashable`.** It does not conform today. §5 of the spec records that if it is ever added, the two numeric cases must hash identically for equal values.
- **The `1e15` guard stays exactly as it is on the `.number` path.** `safeInt` and `safeInt64` refuse a `NaN`, an infinity and an out-of-range magnitude rather than trapping; that behaviour is preserved verbatim.
- **Three `case .number` sites match unrelated enums and must NOT be touched:** `MCPClient.swift:423` and `JSONRPC.swift:90` match the JSON-RPC id enum (a separate two-case type that already decodes `Int` before `String`); `PaneFetch.swift:435` matches `PaneFetch.Page.number`. Grep finds all three; only the type they match decides whether they matter.
- **Commit after every task.** Message body explains the behaviour, never a task number.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `app/Sources/WakilKit/MCP/JSONRPC.swift` | `JSONValue`: accessors (T1), the new case + decoder order + encoder (T5), hand-written `==` (T6) | 1, 5, 6 |
| `app/Sources/WakilKit/App/WindowModel.swift` | 5 reading sites → accessors | 2 |
| `app/Sources/WakilKit/Layout/LayoutActions.swift` | 2 reading sites → accessors | 2 |
| `app/Sources/WakilKit/Panes/PaneContentActions.swift` | 3 reading sites → accessors | 2 |
| `app/Sources/WakilKit/Registry/StandardActions.swift` | 2 reading sites → accessors | 2 |
| `app/Sources/WakilKit/Panes/PaneContents.swift` | `PaneCell` renders `.integer` exactly (T7); `sortedRows` compares integers as integers (T8) | 7, 8 |
| `app/Tests/WakilKitTests/JSONValueIntegerTests.swift` | **new** — decode/encode round-trip, equality matrix, accessors | 1, 5, 6 |
| `app/Tests/WakilKitTests/IntegerPassthroughTests.swift` | **new** — one test per silent site, proving an integer still reaches it | 3 |

---

## Task 1: Accessors on `JSONValue`

**Files:**
- Modify: `app/Sources/WakilKit/MCP/JSONRPC.swift` (after `safeInt64`, around line 210)
- Test: `app/Tests/WakilKitTests/JSONValueIntegerTests.swift` (create)

**Interfaces:**
- Consumes: `safeInt(_:) -> Int?`, `safeInt64(_:) -> Int64?` — existing, unchanged.
- Produces: `JSONValue.doubleValue: Double?`, `JSONValue.int64Value: Int64?`, `JSONValue.intValue: Int?`. These three are the ONLY way any code outside `JSONRPC.swift` reads a number from a `JSONValue` after Task 3.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/JSONValueIntegerTests.swift`:

```swift
import Testing
@testable import WakilKit

@Test func accessorsReadTodaysNumberCase() {
    #expect(JSONValue.number(42).doubleValue == 42)
    #expect(JSONValue.number(42).int64Value == 42)
    #expect(JSONValue.number(42).intValue == 42)
    #expect(JSONValue.number(1.5).doubleValue == 1.5)
}

/// The guards `safeInt`/`safeInt64` already enforce must survive being
/// moved behind an accessor: these values trap if converted with a bare
/// `Int(_:)`, which is the whole reason those functions exist.
@Test func accessorsRefuseWhatSafeIntRefuses() {
    #expect(JSONValue.number(1.5).int64Value == nil)
    #expect(JSONValue.number(1.5).intValue == nil)
    #expect(JSONValue.number(1e300).intValue == nil)
    #expect(JSONValue.number(.nan).intValue == nil)
    #expect(JSONValue.number(.infinity).int64Value == nil)
    // 1e15 is where a Double stops representing every integer exactly.
    #expect(JSONValue.number(1e15).int64Value == nil)
}

@Test func accessorsAreNilForNonNumbers() {
    #expect(JSONValue.string("42").doubleValue == nil)
    #expect(JSONValue.string("42").intValue == nil)
    #expect(JSONValue.bool(true).int64Value == nil)
    #expect(JSONValue.null.doubleValue == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test 2>&1 | grep -A 3 JSONValueInteger`
Expected: FAIL — compile error, `value of type 'JSONValue' has no member 'doubleValue'`.

- [ ] **Step 3: Write minimal implementation**

In `app/Sources/WakilKit/MCP/JSONRPC.swift`, immediately after `safeInt64`:

```swift
/// The three ways anything outside this file reads a number out of a
/// `JSONValue`.
///
/// **They exist so that adding a numeric case cannot break a reader
/// silently.** `if case .number(let n)? = object["offset"]` does not fail
/// to compile when a second numeric case appears — it compiles, runs, and
/// takes the `else` branch for every integer that arrives. An accessor has
/// one implementation, in one file, and gains the new case there once.
///
/// `intValue` and `int64Value` apply `safeInt`/`safeInt64`'s guards to the
/// `.number` path unchanged: a fraction, a `NaN`, an infinity and anything
/// at or past `1e15` are refused rather than converted, because `Int(_:)`
/// *traps* on them rather than returning a wrong answer.
extension JSONValue {
    /// This value as a `Double`, or `nil` if it is not a number.
    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        default: return nil
        }
    }

    /// This value as an `Int64`, or `nil` if it is not a number that can be
    /// one exactly.
    public var int64Value: Int64? {
        switch self {
        case .number(let n): return safeInt64(n)
        default: return nil
        }
    }

    /// This value as an `Int`, or `nil` if it is not a number that can be
    /// one exactly.
    public var intValue: Int? {
        switch self {
        case .number(let n): return safeInt(n)
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS, and the whole existing suite still green.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/JSONRPC.swift app/Tests/WakilKitTests/JSONValueIntegerTests.swift
git commit -m "Read JSONValue numbers through accessors, not patterns

A `guard case .number(let n)?` does not fail to compile when a second
numeric case appears. It compiles, runs, and takes the else branch for
every integer that arrives. Three accessors give those reads one
implementation in one file, so the case can be added later in exactly one
place instead of fourteen.

Behaviour is unchanged: intValue and int64Value apply safeInt and
safeInt64's existing guards to the .number path verbatim.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Migrate all twelve reading sites

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:196,206,215,237,249`
- Modify: `app/Sources/WakilKit/Layout/LayoutActions.swift:282,291`
- Modify: `app/Sources/WakilKit/Panes/PaneContentActions.swift:99,135,210`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift:1457,1539`

**Interfaces:**
- Consumes: `doubleValue` / `int64Value` / `intValue` from Task 1.
- Produces: nothing new. Every function keeps its exact signature and behaviour.

**This task changes no behaviour.** Every edit below reads what it reads today, through an accessor instead of a pattern. The existing suite is the proof.

- [ ] **Step 1: Migrate `WindowModel.swift`**

Five edits. Each keeps the surrounding declarations exactly as they are.

Line 196 — keep the `var millis: Int64 = 0` and the comment above it:
```swift
    if let value = object["millis"]?.int64Value { millis = value }
```

Line 206 — replaces both the `var anchorRow: Int?` declaration and the `if case` line;
the later `PaneSelection(anchorRow: anchorRow, …)` is untouched:
```swift
        let anchorRow: Int? = selectionObject["anchorRow"]?.intValue
```

Line 215 — inside `for value in rowValues`, keeping the comment above it:
```swift
                if let row = value.intValue { selected.insert(row) }
```

Line 237 — replaces both the `var scrollTarget: Int?` declaration and the `if case` line:
```swift
    let scrollTarget: Int? = object["scrollTarget"]?.intValue
```

Line 249 — keep the comment above it:
```swift
    var offset = 0
    if let parsed = object["offset"]?.intValue, parsed >= 0 {
        offset = parsed
    }
```

- [ ] **Step 2: Migrate `LayoutActions.swift`**

```swift
private func requireNumber(_ params: JSONValue, _ key: String, action: String) throws -> Double {
    guard case .object(let object) = params, let value = object[key]?.doubleValue else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    return value
}

/// A number param that may be absent. Absent and non-numeric both read as
/// `nil`; the caller decides whether that is legal.
private func optionalNumber(_ params: JSONValue, _ key: String) -> Double? {
    guard case .object(let object) = params else { return nil }
    return object[key]?.doubleValue
}
```

- [ ] **Step 3: Migrate `PaneContentActions.swift`**

Line 99 — keep the comment above it verbatim, replace the `guard`:
```swift
                guard let row = value.intValue, row >= 0 else {
                    throw LayoutActionError.badParam(
                        action: "pane_select_rows", param: "rows", value: "\(value)")
                }
```

Line 135:
```swift
            guard case .object(let obj) = params, let width = obj["width"]?.doubleValue,
                  width > 0
            else {
```

Line 210 — inside `requireRowIndex`:
```swift
    guard let row = value.intValue, row >= 0 else {
        throw LayoutActionError.badParam(action: action, param: key, value: "\(value)")
    }
    return row
```

`rowIndex(_:)` at line 229 now has no callers. **Delete it**, along with its doc comment — `intValue` plus an explicit `>= 0` says the same thing at both call sites, and a private helper with no callers is a thing for a later reader to wonder about.

- [ ] **Step 4: Migrate `StandardActions.swift`**

Line 1457:
```swift
func optionalIntParam(_ params: JSONValue, _ name: String) -> Int? {
    guard case .object(let obj) = params, let parsed = obj[name]?.intValue, parsed >= 0
    else { return nil }
    return parsed
}
```

Line 1539 — keep the comment block above it verbatim:
```swift
    if let value = structured["millis"]?.int64Value { millis = value }
```

- [ ] **Step 5: Run the full suite**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS. **Zero behaviour changed, so zero tests should change.** If any test fails, the migration is wrong — fix the migration, never the test.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit
git commit -m "Move every JSONValue number read onto the accessors

Twelve sites: millis, anchorRow, selected rows, scrollTarget, offset,
two numeric params, two row indices, column width, a numeric param and a
second millis. Each reads exactly what it read before.

rowIndex() goes with them — intValue plus an explicit >= 0 says the same
thing at both of its call sites, and it had no other callers left.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Protection tests for the twelve silent sites

**Files:**
- Test: `app/Tests/WakilKitTests/IntegerPassthroughTests.swift` (create) — the two pure-function sites
- Test: `app/Tests/WakilKitTests/PaneContentActionsTests.swift` (append) — the three action sites, because that file already owns the `fixture()` / `run()` / `object()` helpers and they are `private` to it

**Interfaces:**
- Consumes: `paneTable(from:) -> PaneTable` (public, `WindowModel.swift:162`), `optionalIntParam(_:_:) -> Int?` (`StandardActions.swift:1456`), and `PaneContentActionsTests`' own private helpers:
  - `fixture() async -> (ActionRegistry, PaneStore, LayoutStore, URL)`
  - `run(_ registry:, _ name:, _ params:, origin: ActionOrigin = .ui, environment: String = "staging") async throws -> JSONValue`
  - `object(_ value: JSONValue) -> [String: JSONValue]`
- Produces: nothing. This task is a net.

**Why this exists.** These twelve sites have no compiler to protect them. When Task 5 adds
the case, a mistake here is silent at build time and wrong at run time. These tests are the
protection the compiler cannot give, and they must be written **before** the case exists so
that they are known to pass on today's code.

- [ ] **Step 1: Write the pure-function tests**

Create `app/Tests/WakilKitTests/IntegerPassthroughTests.swift`:

```swift
import Testing
@testable import WakilKit

/// Drives the sites that read a number out of a `JSONValue` through an
/// `if case` / `guard case` pattern. None of them would fail to COMPILE if
/// a numeric case stopped matching, so each asserts the value arrived.
@Test func paneSnapshotProjectionReadsItsNumbers() {
    let snapshot = JSONValue.object([
        "columns": .array([.string("id")]),
        "columnTypes": .array([.string("INTEGER")]),
        "rows": .array([.array([.number(7)])]),
        "millis": .number(12),
        "truncated": .bool(true),
        "pageable": .bool(true),
        "offset": .number(500),
        "scrollTarget": .number(3),
        "selection": .object([
            "anchorRow": .number(2),
            "anchorColumn": .string("id"),
            "rows": .array([.number(2), .number(4)]),
        ]),
    ])
    let table = paneTable(from: snapshot)
    #expect(table.millis == 12)
    #expect(table.offset == 500)
    #expect(table.scrollTarget == 3)
    #expect(table.selection.anchorRow == 2)
    #expect(table.selection.rows == [2, 4])
}

@Test func optionalIntParamReadsAnInteger() {
    #expect(optionalIntParam(.object(["limit": .number(250)]), "limit") == 250)
    #expect(optionalIntParam(.object(["limit": .number(250)]), "absent") == nil)
    #expect(optionalIntParam(.object(["limit": .number(-1)]), "limit") == nil)
}
```

- [ ] **Step 2: Append the three action tests**

Append to `app/Tests/WakilKitTests/PaneContentActionsTests.swift`, using that file's own
helpers. The shape is copied from `selectCellSetsTheAnchorAndCollapsesTheSelectionToItsRow`
directly above, including the `defer` that deletes the journal directory:

```swift
/// The three action sites that read a number through a `guard case`
/// pattern. Each asserts the number arrived, because nothing about these
/// would fail to compile if the pattern stopped matching.
@Test func selectRowsReadsIntegerIndices() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_select_rows", .object([
        "pane": .string("db"), "rows": .array([.number(1), .number(3)]),
        "anchor": .number(1)]))
    let selection = object(object(await panes.snapshot(paneId: "db"))["selection"] ?? .null)
    #expect(selection["rows"] == .array([.number(1), .number(3)]))
}

@Test func scrollToRowReadsAnIntegerIndex() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_scroll_to_row", .object([
        "pane": .string("db"), "row": .number(42)]))
    #expect(object(await panes.snapshot(paneId: "db"))["scrollTarget"] == .number(42))
}

@Test func setColumnWidthReadsAnIntegerWidth() async throws {
    let (registry, _, layout, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_set_column_width", .object([
        "pane": .string("db"), "column": .string("id"), "width": .number(180)]))
    #expect(await layout.pane(id: "db")?.columnWidths["id"] == 180)
}
```

**Two names to check before writing, not after.** `pane_scroll_to_row`'s snapshot key and
`LayoutStore`'s accessor for a pane both have exact spellings this plan is quoting from
memory. Before running, `grep -n "scrollTarget" app/Sources/WakilKit/Panes/PaneStore.swift`
and `grep -n "func pane(" app/Sources/WakilKit/Layout/LayoutStore.swift`, and use what they
say. If `pane_set_column_width` stores its width on `PaneStore` rather than `LayoutStore`,
follow the existing width test in `LayoutActionsTests.swift` instead. **The assertion must
read the width back from wherever the action actually wrote it** — a test that asserts
nothing is worse here than no test.

- [ ] **Step 3: Run the tests to verify they PASS**

Run: `make app-test 2>&1 | tail -20`
Expected: **PASS.** This is the one task whose tests must pass on first run — they describe
today's behaviour, and their job is to still pass after Task 5. A failure here means the
test is wrong, not the code.

- [ ] **Step 4: Commit**

```bash
git add app/Tests/WakilKitTests/IntegerPassthroughTests.swift app/Tests/WakilKitTests/PaneContentActionsTests.swift
git commit -m "Pin that integers still reach the twelve sites with no compiler

These read numbers out of JSONValue through patterns that will not fail
to compile when a second numeric case exists — they will simply stop
matching and take the else branch. Row selection, column width, scroll
target, paging offset and two timings would break at run time and
nowhere else.

Written before the case exists, so they are known to pass on today's
code and any later failure means the case broke something.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Prove no reading patterns are left

**Files:** none modified. This task is a check.

- [ ] **Step 1: Run the grep**

```bash
grep -rn "case \.number" app/Sources
```

- [ ] **Step 2: Confirm the output is exactly four lines**

Expected, and nothing else:

| Line | Why it stays |
|---|---|
| `MCP/JSONRPC.swift:90` | JSON-RPC **id** enum's encoder — a different two-case type |
| `MCP/JSONRPC.swift:167` | `JSONValue`'s own encoder — the one place that must switch |
| `MCP/JSONRPC.swift` (×3, in the accessors) | Task 1's `doubleValue` / `int64Value` / `intValue` |
| `MCP/MCPClient.swift:423` | JSON-RPC **id** enum — a different type |
| `Panes/PaneContents.swift:24` | `PaneCell`'s own switch — the other place that must switch |
| `Panes/PaneFetch.swift:435` | `PaneFetch.Page.number` — an unrelated enum |

**If any other line appears, Task 2 is incomplete.** Go back and migrate it. Do not proceed.

- [ ] **Step 3: Record the check in the plan**

Tick this task's boxes only once the grep output matches. There is nothing to commit.

---

## Task 5: Add `case integer(Int64)`

**Files:**
- Modify: `app/Sources/WakilKit/MCP/JSONRPC.swift:132-173` (the enum, its decoder, its encoder, and the accessors from Task 1)
- Modify: `app/Sources/WakilKit/Panes/PaneContents.swift:24` (compile error — fixed properly in Task 7; a minimal arm here)
- Test: `app/Tests/WakilKitTests/JSONValueIntegerTests.swift` (extend)

**Interfaces:**
- Produces: `JSONValue.integer(Int64)`. From here on, a JSON whole number decodes to `.integer`, never `.number`.

- [ ] **Step 1: Write the failing test**

Append to `JSONValueIntegerTests.swift`:

```swift
import Foundation

@Test func aWholeNumberDecodesExactlyAndReEncodesUnchanged() throws {
    let wire = #"[9007199254740993,1.5,42]"#
    let decoded = try JSONDecoder().decode([JSONValue].self, from: Data(wire.utf8))

    #expect(decoded[0] == .integer(9007199254740993))
    #expect(decoded[0].int64Value == 9007199254740993)
    #expect(decoded[1] == .number(1.5))
    #expect(decoded[2] == .integer(42))

    let reencoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)
    #expect(reencoded == wire)
}

@Test func accessorsReadTheIntegerCase() {
    #expect(JSONValue.integer(9007199254740993).int64Value == 9007199254740993)
    #expect(JSONValue.integer(42).intValue == 42)
    #expect(JSONValue.integer(42).doubleValue == 42)
    // An Int64 needs no narrowing, so no bound applies to it — unlike the
    // .number path, where 1e15 is where a Double stops being exact.
    #expect(JSONValue.integer(9007199254740993).intValue == 9007199254740993)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test 2>&1 | grep -A 3 aWholeNumber`
Expected: FAIL — `type 'JSONValue' has no member 'integer'`.

- [ ] **Step 3: Add the case, the decoder order and the encoder arm**

In `JSONRPC.swift`, the enum gains one case:

```swift
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    /// A whole number, held exactly.
    ///
    /// **Tried before `number` when decoding**, because a `Double` cannot
    /// represent every integer past 2^53: a database key of
    /// 9007199254740993 arrived as ...992, and an `UPDATE` composed from it
    /// named a different row. JSON has one number type; Wakil needs two
    /// cases to hold it without lying, and the JSON-RPC id enum in this
    /// same file has decoded `Int` before `String` since Phase 2a for the
    /// same reason.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
```

In `init(from:)`, insert **before** the `Double` attempt:

```swift
        } else if let i = try? container.decode(Int64.self) {
            self = .integer(i)
        } else if let n = try? container.decode(Double.self) {
```

In `encode(to:)`, add the arm:

```swift
        case .integer(let i): try container.encode(i)
```

In the Task 1 accessors, add the `.integer` arm to each:

```swift
    public var doubleValue: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .number(let n): return n
        default: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .integer(let i): return i
        case .number(let n): return safeInt64(n)
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        // An Int64 is already exact; only the conversion to the platform
        // Int can fail, and on a 64-bit platform it cannot.
        case .integer(let i): return Int(exactly: i)
        case .number(let n): return safeInt(n)
        default: return nil
        }
    }
```

- [ ] **Step 4: Fix the two compile errors**

`make app-build` now fails on the two exhaustive switches. Add a minimal arm to each; Task 7 gives `PaneCell`'s its real form.

`PaneContents.swift`, in `PaneCell.init`, above the `.number` case:
```swift
        case .integer(let i):
            text = String(i)
            isNull = false
```

`JSONRPC.swift:167` is the encoder, already handled in Step 3.

- [ ] **Step 5: Run the full suite**

Run: `make app-test 2>&1 | tail -30`
Expected: PASS — including every test from Task 3, which is the point of Task 3.

**If a Task 3 test fails**, a silent site was missed in Task 2. Find it with Task 4's grep, migrate it, re-run. Do not weaken the test.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests/JSONValueIntegerTests.swift
git commit -m "Hold whole numbers exactly

JSONValue had one numeric case, Double, so a row keyed 9007199254740993
was a row Wakil believed was keyed ...992 — measured on both engines.
The grid drew the wrong digits, read_pane handed the agent a key that was
not the row's, and two distinct keys sorted as equal.

A second case, decoded before Double, and the accessors gain one arm
each. The wire format is untouched: 9007199254740993 in, 9007199254740993
out, asserted byte for byte.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Numeric equality across the two cases

**Files:**
- Modify: `app/Sources/WakilKit/MCP/JSONRPC.swift` (add `==` to `JSONValue`)
- Test: `app/Tests/WakilKitTests/JSONValueIntegerTests.swift` (extend)

**Interfaces:**
- Produces: `JSONValue.==` — hand-written, replacing the synthesised one.

**Why.** `app/Tests` constructs `.number(…)` **236 times**, overwhelmingly as expected values in assertions whose actual values now arrive as `.integer`. Under the synthesised `Equatable` they would not compare equal and roughly that many tests would fail for a reason that is not a bug.

- [ ] **Step 1: Write the failing test**

Append to `JSONValueIntegerTests.swift`:

```swift
@Test func twoRepresentationsOfOneValueAreEqual() {
    #expect(JSONValue.integer(5) == .number(5))
    #expect(JSONValue.number(5) == .integer(5))
    #expect(JSONValue.integer(0) == .number(0))
    #expect(JSONValue.integer(-7) == .number(-7))
    // Nested, because this is how the test suite actually compares things.
    #expect(JSONValue.object(["n": .integer(5)]) == .object(["n": .number(5)]))
    #expect(JSONValue.array([.integer(1)]) == .array([.number(1)]))
}

/// The pair that must be UNEQUAL, and the reason the whole fix exists.
/// `Double(9007199254740993)` IS `9007199254740992.0`, so a comparison that
/// converts the integer to a Double would call these equal and reintroduce
/// the bug inside the equality operator.
@Test func twoDistinctLargeIntegersAreNotEqual() {
    #expect(JSONValue.integer(9007199254740993) != .number(9007199254740992))
    #expect(JSONValue.integer(9007199254740993) != .integer(9007199254740992))
}

@Test func aFractionIsNeverEqualToAnInteger() {
    #expect(JSONValue.integer(5) != .number(5.5))
    #expect(JSONValue.number(.nan) != .integer(0))
    #expect(JSONValue.number(.infinity) != .integer(Int64.max))
}

@Test func nonNumericEqualityIsUnchanged() {
    #expect(JSONValue.string("5") != .integer(5))
    #expect(JSONValue.bool(true) != .integer(1))
    #expect(JSONValue.null != .integer(0))
    #expect(JSONValue.string("a") == .string("a"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test 2>&1 | grep -A 3 twoRepresentations`
Expected: FAIL — `.integer(5) == .number(5)` is `false` under the synthesised operator.

- [ ] **Step 3: Write the implementation**

In `JSONRPC.swift`, after the enum:

```swift
extension JSONValue {
    /// Two numeric cases hold one number between them, so they compare
    /// **by value, across cases**: `.integer(5) == .number(5)`.
    ///
    /// **Hand-written rather than synthesised**, because `app/Tests`
    /// constructs `.number(…)` 236 times as an expected value, and after
    /// the decoder change the actual value arrives as `.integer`. The
    /// synthesised operator would fail every one of those for a reason
    /// that is not a bug.
    ///
    /// **The comparison narrows the `Double` to an `Int64`, never the
    /// other way.** `Double(9007199254740993)` is `9007199254740992.0`, so
    /// widening the integer would call two distinct keys equal — the exact
    /// defect this case was added to remove, reintroduced inside the
    /// operator that is supposed to tell them apart.
    ///
    /// **`Hashable` is deliberately NOT added.** `JSONValue` does not
    /// conform today. If it ever does, `hash(into:)` must hash `.integer(5)`
    /// and `.number(5)` identically, or a dictionary will hold two entries
    /// this operator says are one.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let l), .bool(let r)):
            return l == r
        case (.integer(let l), .integer(let r)):
            return l == r
        case (.number(let l), .number(let r)):
            return l == r
        case (.integer(let i), .number(let d)), (.number(let d), .integer(let i)):
            guard let narrowed = Int64(exactly: d) else { return false }
            return narrowed == i
        case (.string(let l), .string(let r)):
            return l == r
        case (.array(let l), .array(let r)):
            return l == r
        case (.object(let l), .object(let r)):
            return l == r
        default:
            return false
        }
    }
}
```

`Int64(exactly:)` returns `nil` for a fraction, a `NaN`, an infinity and an out-of-range magnitude, so each of those is unequal to every integer without a separate branch.

- [ ] **Step 4: Run the full suite**

Run: `make app-test 2>&1 | tail -30`
Expected: PASS, all of it — including the ~236 `.number(…)` assertions across the existing suite, which is what this operator exists to keep true.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/JSONRPC.swift app/Tests/WakilKitTests/JSONValueIntegerTests.swift
git commit -m "Compare the two numeric cases by value

.integer(5) and .number(5) are one number held two ways, so == compares
across the cases. The suite constructs .number(...) 236 times as an
expected value and those actuals now arrive as .integer; without this
they would all fail for a reason that is not a bug.

The comparison narrows the Double to an Int64, never the reverse.
Double(9007199254740993) is ...992, so widening would call two distinct
keys equal inside the very operator added to tell them apart.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `PaneCell` renders an integer exactly

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneContents.swift:12-45`
- Test: `app/Tests/WakilKitTests/JSONValueIntegerTests.swift` (extend)

**Interfaces:**
- Consumes: `JSONValue.integer` from Task 5.
- Produces: nothing new. `PaneCell.text` and `PaneCell.isNull` keep their meaning.

- [ ] **Step 1: Write the failing test**

Append to `JSONValueIntegerTests.swift`:

```swift
@Test func aLargeKeyDrawsItsOwnDigits() {
    #expect(PaneCell(.integer(9007199254740993)).text == "9007199254740993")
    #expect(PaneCell(.integer(42)).text == "42")
    #expect(PaneCell(.integer(-1)).text == "-1")
    #expect(PaneCell(.integer(Int64.max)).text == "9223372036854775807")
    #expect(PaneCell(.integer(0)).isNull == false)
}

/// The .number path keeps its 1e15 guard, because a Double is still a
/// Double — this is what the fix REPLACES, not what it changes.
@Test func theDoublePathIsUnchanged() {
    #expect(PaneCell(.number(42)).text == "42")
    #expect(PaneCell(.number(1.5)).text == "1.5")
}
```

- [ ] **Step 2: Run the test — it is EXPECTED TO PASS**

Run: `make app-test 2>&1 | grep -A 3 aLargeKeyDraws`
Expected: **PASS.** Task 5's minimal arm was `text = String(i)`, which is already the right
implementation — this test pins it rather than driving it. That is deliberate: the arm had
to exist in Task 5 for the build to compile at all, so there is no honest way to write this
one red first.

**If it fails**, Task 5's arm is wrong. Fix the arm, not the test.

- [ ] **Step 3: Give the arm its doc comment**

In `PaneContents.swift`, the `.integer` arm added in Task 5 becomes:

```swift
        case .integer(let i):
            // No bound and no fallback, unlike the `.number` branch below:
            // that one guards at 1e15 because a Double cannot be trusted
            // past it, and an Int64 can be trusted everywhere. A database
            // key of 9007199254740993 used to draw as
            // "9.007199254740992e+15" — wrong digits, unreadable format —
            // because it had been a Double since it left the driver.
            text = String(i)
            isNull = false
```

- [ ] **Step 4: Run the suite**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneContents.swift app/Tests/WakilKitTests/JSONValueIntegerTests.swift
git commit -m "Draw a large key as its own digits

A BIGINT id drew as 9.007199254740992e+15 — wrong value, unreadable
format — because it had been a Double since it left the driver. An Int64
needs no bound and no fallback; the .number branch keeps its 1e15 guard,
because a Double is still a Double.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `sortedRows` compares integers as integers

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneContents.swift` — the `compare(_:_:direction:)` closure inside `sortedRows`
- Test: `app/Tests/WakilKitTests/JSONValueIntegerTests.swift` (extend)

**Interfaces:**
- Consumes: `PaneCell`, `JSONValue.integer`.
- Produces: nothing new. `sortedRows`' signature is unchanged in this plan. *(Plan 2 changes it to return a permutation; that is that plan's task, not this one's.)*

**Why.** The comparator sorts on `PaneCell`, whose `.integer` text is now exact — but if it compares two numeric cells by converting both to `Double`, two distinct large keys tie and their order becomes whatever the sort's stability gives. That is the same defect, surviving inside the sort where no test would see it.

- [ ] **Step 1: Read the comparator**

Open `app/Sources/WakilKit/Panes/PaneContents.swift` and find `func compare(_ l: PaneCell, _ r: PaneCell, direction:)` inside `sortedRows`. It currently parses `PaneCell.text` into `Double` for its numeric branch. Note the exact shape before editing.

- [ ] **Step 2: Write the failing test**

Append to `JSONValueIntegerTests.swift`:

```swift
@Test func twoDistinctLargeKeysDoNotTieInTheSort() {
    let rows: [[JSONValue]] = [
        [.integer(9007199254740993)],
        [.integer(9007199254740992)],
        [.integer(9007199254740994)],
    ]
    let sorted = sortedRows(
        rows, by: [PaneSort(column: "id", direction: .ascending)], columns: ["id"])
    #expect(sorted.map { PaneCell($0[0]).text } == [
        "9007199254740992", "9007199254740993", "9007199254740994",
    ])
}

@Test func integersAndFractionsSortTogetherByValue() {
    let rows: [[JSONValue]] = [[.integer(10)], [.number(2.5)], [.integer(1)]]
    let sorted = sortedRows(
        rows, by: [PaneSort(column: "n", direction: .ascending)], columns: ["n"])
    #expect(sorted.map { PaneCell($0[0]).text } == ["1", "2.5", "10"])
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `make app-test 2>&1 | grep -A 5 twoDistinctLargeKeys`
Expected: FAIL — the three keys parse to two distinct `Double`s, so two of them tie and the order is the input order.

- [ ] **Step 4: Implement**

Give the comparator an exact-integer branch **before** its `Double` branch. Keep every other behaviour — nulls last in both directions, `localizedStandardCompare` for the rest — exactly as it is:

```swift
        // Two exact integers compare as integers. Parsing both into Double
        // first would tie 9007199254740992 and ...993, which is the defect
        // the `.integer` case was added to remove, surviving one layer
        // down where no visible symptom would point at it.
        if let li = Int64(l.text), let ri = Int64(r.text) {
            if li == ri { return 0 }
            let ascending = li < ri
            return (direction == .ascending) == ascending ? -1 : 1
        }
```

Place it immediately after the null handling and before the existing two-`Double` branch, so a mixed integer/fraction column falls through to the `Double` comparison and still sorts by value.

- [ ] **Step 5: Run test to verify it passes**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS, including the existing `sortedRows` tests, which must not change.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneContents.swift app/Tests/WakilKitTests/JSONValueIntegerTests.swift
git commit -m "Sort exact integers as integers

The comparator parsed every numeric cell into a Double, so two keys that
differ by one past 2^53 tied and their order became whatever the sort's
stability gave. Same defect as the display one, one layer down, with no
visible symptom to point at it.

A mixed integer/fraction column still falls through to the Double
comparison and sorts by value.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Verify end to end and record it

**Files:**
- Modify: `docs/superpowers/specs/2026-09-13-integer-fidelity-design.md` (add a "met" line)

- [ ] **Step 1: Run everything**

```bash
make app-build && make app-test && make test && make vet
```
Expected: all green.

- [ ] **Step 2: Re-run Task 4's grep**

```bash
grep -rn "case \.number" app/Sources
```
Expected: the same six locations Task 4 listed, plus the `.integer` arms added in Task 5 — and no reading pattern outside `JSONRPC.swift` and `PaneContents.swift`.

- [ ] **Step 3: Record it on the spec**

Add under the spec's `**Status:**` line:

```markdown
**Met:** 2026-09-13 — `JSONValue.integer(Int64)` decoded before `Double`, fourteen sites
migrated to accessors ahead of the case existing, cross-case numeric equality, `PaneCell`
and `sortedRows` exact. Verified by `make app-test`, `make test` and `make vet`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-09-13-integer-fidelity-design.md
git commit -m "Mark integer fidelity met, and say how

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the executor

- **Task 4 is a gate, not a formality.** If its grep shows a reading pattern outside the six named locations, Task 5 will break that site silently and no test will say so.
- **Task 3's tests must pass when written.** They describe today's behaviour. Their value is entirely in still passing after Task 5.
- **Never weaken a Task 3 or Task 6 test to make a build green.** Both exist to catch exactly the failure a green build would otherwise hide.
- **`sortedRows` keeps its current signature here.** Plan 2 (`2c-ii-b`) changes it to return a permutation; doing that early would make this plan's diff larger and its tests harder to read.
