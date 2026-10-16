# Phase 2c-i — The Data Surface: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move pane contents out of the window and into panes, and draw them on a virtualizing data surface that holds `design-language.md` §8's row heights, type annotations, explicit `NULL`, selection and honest sort — all dual-driven.

**Architecture:** A SwiftUI `LazyVStack` of fixed-height rows inside a `ScrollView`, with the column header drawn *above* that scroll view and its horizontal offset shared by hand. Contents, selection and sort live per pane in `PaneStore`; column widths live per pane on `Pane` and persist with the layout. Five new `.control` actions make selection, sort, width and scroll reachable from the pointer, ⌘K, the agent and `--dispatch` alike.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing (`@Test`/`#expect`), Go 1.27 for the driver half, `make` for the perf target.

**Spec:** `docs/superpowers/specs/2026-09-11-phase-2c-i-data-surface-design.md`
**Probe:** `docs/wakil/phase-2c-i-probe.md` — every performance number quoted below comes from it.

## Global Constraints

- **No `Section` inside the data surface's `ScrollView`.** Measured: it under-reports document height by 2.8%, pinned or not. Header goes *above* the scroll view. (Spec §2.1.)
- **Row heights come from `PaneDensity.rowHeight`** — 40pt airy, 23pt dense — applied as `.frame(height:)` on the row, never as padding. Measured exact to 23.0000 / 40.0000.
- **Rows are built lazily.** A construction that builds every row it is given is a regression, not a style choice: `Grid` at 5,000 rows costs a 5.3-second first layout and misses the 8.33ms frame budget on 300 steps out of 300.
- **Every new action is `.control`** and carries no `targetEnvironmentParam`. They change Wakil's own state and nothing outside it. (`ActionKind`'s doc comment is the authority.)
- **`row` parameters index the order currently displayed**, not the underlying result. (Spec §4's amendment; Invariant 3.)
- **Every key in a `read_pane` payload is always present**, including when false or empty — `PaneStore.snapshot`'s existing rule for `truncated`, applied to everything new.
- **Go: `CGO_ENABLED=0`** is exported by the Makefile for build, test and vet alike. Do not override it.
- **Swift tests run headless** via `make app-test` (which is `scripts/swift-test.sh`). Nothing in `WakilKitTests` may need a display.
- **Commit after every task.** Never leave the tree dirty between tasks.

## File Structure

**Go — the typed-columns half**

| File | Responsibility |
|---|---|
| `internal/wakilcore/dbdriver.go` | `Rows` gains `ColumnTypes []string` and `ColumnTypesInferred bool` |
| `internal/wakilcore/sqlconn.go` | `collectRows` fills `ColumnTypes` from `sql.Rows.ColumnTypes()` |
| `internal/wakilcore/mongo_util.go` | `docsToRows` infers per-column types and sets `ColumnTypesInferred` |

**Swift — state**

| File | Responsibility |
|---|---|
| `app/Sources/WakilKit/Panes/PaneContents.swift` | **New.** `PaneCell`, `PaneColumn`, `PaneSelection`, `PaneSort` — the value types the store holds and the view draws |
| `app/Sources/WakilKit/Panes/PaneStore.swift` | Per-pane contents *plus* selection and sort; snapshot reports all of it |
| `app/Sources/WakilKit/Layout/Pane.swift` | `columnWidths: [String: Double]`, persisted like `density` |
| `app/Sources/WakilKit/Panes/PaneContentActions.swift` | **New.** The five actions |

**Swift — projection and view**

| File | Responsibility |
|---|---|
| `app/Sources/WakilKit/App/WindowModel.swift` | `PaneTable` gains types/selection/sort; `paneCellText` stops collapsing `null`; per-pane contents replace the single flattened set |
| `app/Sources/WakilApp/DataSurface.swift` | **New.** The whole surface: header, rows, footer, selection chrome, horizontal offset sync |
| `app/Sources/WakilApp/Canvas.swift` | `paneView` draws `DataSurface` instead of frame numerals |
| `app/Sources/WakilApp/WakilWindow.swift` | The window-level table is **deleted** |

**Tooling and docs**

| File | Responsibility |
|---|---|
| `app/Sources/WakilApp/SurfaceBench.swift` | **New.** `--bench-surface`: 50,000 rows offscreen, row-body count and per-step timings |
| `Makefile` | `bench-surface` target |
| `docs/wakil/design-language.md` | §8 and §13 amendments |
| `docs/wakil/north-star.md` | 2c's five-way split |

---
## Task 1: `ColumnTypes` on `wakilcore.Rows`, from the SQL drivers

**Why this is first:** every layer above it is shaped by whether a column's type is
available at all, and it is the only task with no Swift in it.

**Files:**
- Modify: `internal/wakilcore/dbdriver.go:79-88`
- Modify: `internal/wakilcore/sqlconn.go` (`collectRows`, around line 218)
- Test: `internal/wakilcore/driver_sqlite_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `Rows.ColumnTypes []string` (JSON key `columnTypes`) and
  `Rows.ColumnTypesInferred bool` (JSON key `columnTypesInferred`). `ColumnTypes` is
  either empty (the driver could not say) or exactly as long as `Columns`.

- [ ] **Step 1: Write the failing test**

Add to `internal/wakilcore/driver_sqlite_test.go`:

```go
func TestSQLiteReadReportsColumnTypes(t *testing.T) {
	conn := newSQLiteTestConn(t, `
		CREATE TABLE customers (id INTEGER, name TEXT, balance REAL);
		INSERT INTO customers VALUES (1, 'widgets', 4.5);
	`)
	got, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT id, name, balance FROM customers"}, 0)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if len(got.ColumnTypes) != len(got.Columns) {
		t.Fatalf("ColumnTypes has %d entries for %d columns: %v",
			len(got.ColumnTypes), len(got.Columns), got.ColumnTypes)
	}
	want := []string{"INTEGER", "TEXT", "REAL"}
	for i := range want {
		if got.ColumnTypes[i] != want[i] {
			t.Errorf("column %q: type %q, want %q", got.Columns[i], got.ColumnTypes[i], want[i])
		}
	}
	// A SQL driver DECLARES its types. Only Mongo infers, and saying so is
	// the difference between an annotation the operator can trust and a
	// guess wearing the same clothes.
	if got.ColumnTypesInferred {
		t.Error("ColumnTypesInferred is true for a SQL driver, which declares its types")
	}
}
```

If `newSQLiteTestConn` does not already exist with that signature, read the top of
`driver_sqlite_test.go` and use whatever helper the existing tests use to get a
`*sqlConn` over a seeded in-memory database; do not add a second helper.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestSQLiteReadReportsColumnTypes -v`
Expected: FAIL — `got.ColumnTypes` undefined (compile error).

- [ ] **Step 3: Add the fields**

In `internal/wakilcore/dbdriver.go`, replace the `Rows` struct:

```go
type Rows struct {
	Columns []string `json:"columns"`
	// ColumnTypes is the database's own name for each column's type,
	// positionally aligned with Columns, or empty when the driver could not
	// say. It is never partially filled: a driver either reports a type for
	// every column or reports none, because a half-annotated header is worse
	// than an unannotated one — the operator cannot tell an absent
	// annotation from a column whose type the driver happened to omit.
	//
	// Inferring these from the values on screen was considered and rejected:
	// it is wrong for an empty result, wrong for an all-NULL column, and
	// wrong for a column whose first 500 rows happen to be integers.
	ColumnTypes []string `json:"columnTypes"`
	// ColumnTypesInferred is true when ColumnTypes was worked out from the
	// values rather than declared by the engine. Only the Mongo driver sets
	// it, because Mongo has no schema to ask. It exists for the same reason
	// Truncated does: so a caller can tell a fact from a guess instead of
	// reading both as facts.
	ColumnTypesInferred bool    `json:"columnTypesInferred"`
	Rows                [][]any `json:"rows"`
	Millis              int64   `json:"millis"`
	// Truncated is true when more rows matched the query than were
	// returned, so a caller (in particular, an LLM) can distinguish a
	// complete result from a partial one instead of reporting a partial
	// answer as the whole answer.
	Truncated bool `json:"truncated,omitempty"`
}
```

Note `columnTypes` and `columnTypesInferred` carry **no** `omitempty`, unlike
`truncated`. That is deliberate and is the Swift side's requirement: `PaneStore`'s
snapshot rule is that an absent key is a thing a reader has to know to interpret,
whereas an explicit value is an answer.

- [ ] **Step 4: Fill it in `collectRows`**

In `internal/wakilcore/sqlconn.go`, inside `collectRows`, immediately after the
existing `cols, err := rows.Columns()` error check:

```go
	var out Rows
	out.Columns = cols
	// ColumnTypes() fails in the same states Columns() does, and this
	// function has already survived that check — but a driver is permitted
	// to return fewer type descriptors than columns, and a positionally
	// aligned slice that is short is worse than none. So it is all or
	// nothing, matching the field's contract.
	if cts, cterr := rows.ColumnTypes(); cterr == nil && len(cts) == len(cols) {
		types := make([]string, len(cts))
		for i, ct := range cts {
			types[i] = ct.DatabaseTypeName()
		}
		out.ColumnTypes = types
	}
```

replacing the existing two lines `var out Rows` / `out.Columns = cols`.

- [ ] **Step 5: Run the test and the package**

Run: `go test ./internal/wakilcore/ -run TestSQLiteReadReportsColumnTypes -v`
Expected: PASS

Run: `make test`
Expected: PASS — no existing test asserts on the shape of a serialised `Rows` in a way
the two new keys break. If `TestRowsJSON` (or similar, in `dbdriver_test.go:187`) pins
exact JSON, update its expectation to include `"columnTypes":null,"columnTypesInferred":false`
and keep the test.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/dbdriver.go internal/wakilcore/sqlconn.go internal/wakilcore/driver_sqlite_test.go internal/wakilcore/dbdriver_test.go
git commit -m "Rows carries the database's own column types"
```

---

## Task 2: Inferred column types for Mongo

**Files:**
- Modify: `internal/wakilcore/mongo_util.go` (`docsToRows`, line 57)
- Test: `internal/wakilcore/driver_mongo_test.go`

**Interfaces:**
- Consumes: `Rows.ColumnTypes`, `Rows.ColumnTypesInferred` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Add to `internal/wakilcore/driver_mongo_test.go` (this needs no server — `docsToRows`
is a pure function):

```go
func TestDocsToRowsInfersColumnTypes(t *testing.T) {
	docs := []map[string]any{
		{"_id": "abc", "name": "widgets", "qty": int32(4), "active": true},
		// A later document with a nil where an earlier one had a value must
		// not erase the type already established: a null is the absence of a
		// value, not evidence about the column.
		{"_id": "def", "name": nil, "qty": int32(9), "active": false},
	}
	got := docsToRows(docs, 10, 7)
	if !got.ColumnTypesInferred {
		t.Error("ColumnTypesInferred is false; Mongo has no schema to declare")
	}
	if len(got.ColumnTypes) != len(got.Columns) {
		t.Fatalf("ColumnTypes has %d entries for %d columns", len(got.ColumnTypes), len(got.Columns))
	}
	want := map[string]string{"_id": "string", "name": "string", "qty": "int", "active": "bool"}
	for i, c := range got.Columns {
		if got.ColumnTypes[i] != want[c] {
			t.Errorf("column %q: type %q, want %q", c, got.ColumnTypes[i], want[c])
		}
	}
}

func TestDocsToRowsReportsNoTypeForAnAllNullColumn(t *testing.T) {
	// An all-null column has no evidence in it. Reporting "string" here
	// because that is what a nil marshals to would be exactly the guess
	// ColumnTypesInferred exists to keep honest.
	got := docsToRows([]map[string]any{{"a": nil}, {"a": nil}}, 10, 0)
	if len(got.ColumnTypes) != 1 || got.ColumnTypes[0] != "" {
		t.Errorf("ColumnTypes = %v, want one empty entry", got.ColumnTypes)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestDocsToRows -v`
Expected: FAIL — `ColumnTypesInferred is false`.

- [ ] **Step 3: Implement the inference**

In `internal/wakilcore/mongo_util.go`, add above `docsToRows`:

```go
// inferMongoType names the type of a single decoded BSON value, or "" for
// a nil. The names are deliberately Mongo's vocabulary rather than Go's —
// this string is drawn in a column header for a human, and "primitive.M"
// would tell them nothing.
func inferMongoType(v any) string {
	switch v.(type) {
	case nil:
		return ""
	case bool:
		return "bool"
	case int32, int64, int:
		return "int"
	case float32, float64:
		return "double"
	case string:
		return "string"
	case time.Time:
		return "date"
	case []any, primitive.A:
		return "array"
	default:
		// Everything else — embedded documents, ObjectIDs, Decimal128,
		// binary — is named by its own Go type rather than lumped into
		// "object". A wrong-looking name an operator can search for beats a
		// right-looking name that hides which of six things this is.
		return fmt.Sprintf("%T", v)
	}
}
```

Add `"fmt"` and `"time"` to that file's imports if absent, and confirm `primitive` is
already imported (it is used elsewhere in the Mongo driver; if `mongo_util.go` does not
import it, drop the `primitive.A` case rather than adding the import — `[]any` covers
the decoded-array case this code path actually sees).

Then, inside `docsToRows`, replace the row-building loop's surroundings so types are
gathered as rows are built:

```go
	var out Rows
	out.Columns = cols
	out.Millis = millis
	// Mongo has no schema, so the type is whatever the documents show. The
	// FIRST non-nil value per column wins and later ones do not overwrite
	// it: a column that is int in one document and string in the next is a
	// real thing in Mongo, and picking the last would make the annotation
	// depend on scroll position.
	types := make([]string, len(cols))
	for i, d := range docs {
		if i >= limit {
			break
		}
		row := make([]any, len(cols))
		for j, c := range cols {
			row[j] = d[c]
			if types[j] == "" {
				types[j] = inferMongoType(d[c])
			}
		}
		out.Rows = append(out.Rows, row)
	}
	out.ColumnTypes = types
	out.ColumnTypesInferred = true
	return out
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/wakilcore/ -run TestDocsToRows -v`
Expected: PASS

Run: `make test && make vet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/mongo_util.go internal/wakilcore/driver_mongo_test.go
git commit -m "Mongo infers column types, and says that it inferred them"
```

---
## Task 3: `PaneContents` — the value types the surface is made of

**Why a new file:** `PaneStore.swift` is 73 lines and does one thing. The types below
are consumed by the store, by `WindowModel`'s projection, by the actions and by the
view; putting them in the store would make the store the thing everything imports for
reasons unrelated to storage.

**Files:**
- Create: `app/Sources/WakilKit/Panes/PaneContents.swift`
- Test: `app/Tests/WakilKitTests/PaneContentsTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (existing, in `WakilKit`).
- Produces:
  - `PaneCell` — `init(_ value: JSONValue)`, members `text: String`, `isNull: Bool`
  - `PaneColumn` — `init(name: String, type: String?)`, members `name`, `type`
  - `PaneSortDirection` — `.ascending` / `.descending`, `rawValue` `"asc"` / `"desc"`
  - `PaneSort` — `init(column: String, direction: PaneSortDirection)`
  - `PaneSelection` — `init(anchorRow: Int?, anchorColumn: String?, rows: Set<Int>)`,
    plus `static let empty`

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/PaneContentsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func aNullCellIsDistinguishableFromAnEmptyString() {
    let null = PaneCell(.null)
    let empty = PaneCell(.string(""))
    #expect(null.isNull)
    #expect(!empty.isNull)
    // The text is empty for both; `isNull` is the whole difference, and it
    // is what lets the view draw one as a dimmed NULL and the other as
    // nothing. Before this type existed both rendered as "" and a real NULL
    // was indistinguishable from an empty string on screen.
    #expect(null.text.isEmpty)
    #expect(empty.text.isEmpty)
}

@Test func cellTextMatchesTheOldProjectionForEveryNonNullKind() {
    #expect(PaneCell(.string("widgets")).text == "widgets")
    #expect(PaneCell(.bool(true)).text == "true")
    #expect(PaneCell(.bool(false)).text == "false")
    // An integral number prints without the ".0" String(Double) would add —
    // database ids are the commonest cell here and "1.0" is wrong on sight.
    #expect(PaneCell(.number(1)).text == "1")
    #expect(PaneCell(.number(2.5)).text == "2.5")
    // Past 1e15 a Double stops representing every integer exactly, so an
    // Int64 conversion there would assert precision the value lacks.
    #expect(PaneCell(.number(1e16)).text.contains("e+16"))
    #expect(PaneCell(.array([.number(1)])).text == "[1]")
}

@Test func aColumnWithNoTypeCarriesNil() {
    #expect(PaneColumn(name: "id", type: "INTEGER").type == "INTEGER")
    // An empty type string from the wire is "the driver could not say",
    // which is nil here rather than "" so a view cannot draw an empty
    // annotation and call it an annotation.
    #expect(PaneColumn(name: "id", type: "").type == nil)
    #expect(PaneColumn(name: "id", type: nil).type == nil)
}

@Test func anEmptySelectionHasNoAnchorAndNoRows() {
    #expect(PaneSelection.empty.anchorRow == nil)
    #expect(PaneSelection.empty.anchorColumn == nil)
    #expect(PaneSelection.empty.rows.isEmpty)
}

@Test func aSelectionAlwaysContainsItsAnchorRow() {
    // The anchor is the row §8's luminous edge is drawn on, so a selection
    // whose anchor is outside its own row set would draw that edge on a row
    // the set says is not selected.
    let s = PaneSelection(anchorRow: 4, anchorColumn: "name", rows: [1, 2])
    #expect(s.rows.contains(4))
}

@Test func sortDirectionRoundTripsThroughItsWireName() {
    #expect(PaneSortDirection(rawValue: "asc") == .ascending)
    #expect(PaneSortDirection(rawValue: "desc") == .descending)
    #expect(PaneSortDirection.descending.rawValue == "desc")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — `cannot find 'PaneCell' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Sources/WakilKit/Panes/PaneContents.swift`:

```swift
import Foundation

/// One cell of a data surface: the single line of text it shows, and
/// whether the value behind it was JSON `null`.
///
/// **`isNull` is the reason this type exists.** Until 2c-i the projection
/// rendered `null` as the empty string, which made a real database NULL and
/// an empty string identical on screen — the exact confusion
/// `design-language.md` §8's "explicit null rendering" exists to prevent.
/// The text alone cannot carry the distinction, because both are empty; the
/// flag can.
public struct PaneCell: Sendable, Equatable {
    public let text: String
    public let isNull: Bool

    public init(_ value: JSONValue) {
        switch value {
        case .null:
            text = ""
            isNull = true
        case .bool(let flag):
            text = flag ? "true" : "false"
            isNull = false
        case .number(let number):
            // The `< 1e15` bound is where a Double stops being able to
            // represent every integer exactly; past it, printing an Int64
            // conversion would assert precision the value does not have.
            if number == number.rounded(), abs(number) < 1e15 {
                text = String(Int64(number))
            } else {
                text = String(number)
            }
            isNull = false
        case .string(let value):
            text = value
            isNull = false
        case .array, .object:
            if let data = try? JSONEncoder().encode(value),
               let encoded = String(data: data, encoding: .utf8) {
                text = encoded
            } else {
                text = ""
            }
            isNull = false
        }
    }
}

/// One column of a data surface: its name, and the database's own name for
/// its type when there is one.
///
/// `type` is `nil` rather than `""` when the driver could not say, so that
/// a view cannot draw an empty annotation and have it read as an
/// annotation. The conversion happens here, once, rather than at each of
/// the several places that will ask.
public struct PaneColumn: Sendable, Equatable {
    public let name: String
    public let type: String?

    public init(name: String, type: String?) {
        self.name = name
        self.type = (type?.isEmpty ?? true) ? nil : type
    }
}

/// Which way a sort runs. The raw values are the wire names an action
/// parameter and `read_pane` both use.
public enum PaneSortDirection: String, Sendable, Equatable, CaseIterable {
    case ascending = "asc"
    case descending = "desc"
}

/// A pane's current sort *intent* — which column, which way.
///
/// Intent, not result: the grid never sorts. It records this, and the
/// pane's owner decides how to honour it (spec §6). A pane that can
/// re-query re-queries; one that cannot sorts the rows it holds and says
/// so in its footer.
public struct PaneSort: Sendable, Equatable {
    public let column: String
    public let direction: PaneSortDirection

    public init(column: String, direction: PaneSortDirection) {
        self.column = column
        self.direction = direction
    }
}

/// What is selected in a pane: an anchor cell, and the set of rows.
///
/// **Two things and not one.** The anchor is a (row, column) pair because
/// `design-language.md` §11 has the API client pane consuming *values* from
/// other panes, and a value lives in a cell rather than a row. The row set
/// is what copy — and, in 2c-ii, a multi-row delete — operates on.
///
/// The anchor's row is always a member of `rows`. §8 draws its luminous
/// left edge on the anchor's row, and an anchor outside the selection would
/// put that edge on a row the selection says is not selected.
///
/// Multi-row selection is here in 2c-i rather than deferred because this
/// shape is published — it is in `read_pane`'s payload and in the schemas
/// of `pane_select_cell` and `pane_select_rows`, both of which an agent
/// reads. Widening it later changes a contract, not a data structure.
public struct PaneSelection: Sendable, Equatable {
    public let anchorRow: Int?
    public let anchorColumn: String?
    public let rows: Set<Int>

    public static let empty = PaneSelection(anchorRow: nil, anchorColumn: nil, rows: [])

    public init(anchorRow: Int?, anchorColumn: String?, rows: Set<Int>) {
        self.anchorRow = anchorRow
        self.anchorColumn = anchorColumn
        if let anchorRow {
            self.rows = rows.union([anchorRow])
        } else {
            self.rows = rows
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneContents.swift app/Tests/WakilKitTests/PaneContentsTests.swift
git commit -m "The value types a data surface is made of, with NULL distinguishable"
```

---
## Task 4: `PaneStore` holds typed contents, selection and sort — per pane

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (whole file)
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — `db_run_query`'s
  `panes.setRows(...)` call (line ~360) and `dbPaneContents` (line 744)
- Test: `app/Tests/WakilKitTests/PaneStoreTests.swift` (new)

**Interfaces:**
- Consumes: `PaneCell`, `PaneColumn`, `PaneSelection`, `PaneSort` (Task 3).
- Produces:
  - `PaneStore.setRows(paneId:columns:columnTypes:columnTypesInferred:rows:millis:truncated:)`
  - `PaneStore.setSelection(paneId:_:)`, `PaneStore.setSort(paneId:_:)`,
    `PaneStore.setScrollTarget(paneId:row:)`
  - `PaneStore.snapshot(paneId:) -> JSONValue` — now carrying `columnTypes`,
    `columnTypesInferred`, `millis`, `selection`, `sort`, `scrollTarget`
  - `PaneStore.paneIds() -> [String]`

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/PaneStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let o) = value else { return [:] }
    return o
}

@Test func anUntouchedPaneAnswersWithEveryKeyPresent() async {
    let store = PaneStore()
    let snap = object(await store.snapshot(paneId: "nothing-here"))
    // An unknown pane id is not an error — it is a pane with nothing in it
    // yet — and every key is present rather than omitted, because an absent
    // key is a thing a reader has to know to interpret whereas an explicit
    // empty value is an answer. This object is read by an LLM.
    for key in ["columns", "columnTypes", "columnTypesInferred", "rows", "rowCount",
                "millis", "truncated", "selection", "sort", "scrollTarget"] {
        #expect(snap[key] != nil, "missing key \(key)")
    }
    #expect(snap["sort"] == .null)
    #expect(snap["scrollTarget"] == .null)
}

@Test func rowsAndTypesRoundTripPerPane() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id", "name"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.number(1), .string("widgets")]],
        millis: 12, truncated: true)
    await store.setRows(
        paneId: "db-2", columns: ["k"], columnTypes: [], columnTypesInferred: false,
        rows: [], millis: 0, truncated: false)

    let one = object(await store.snapshot(paneId: "db-1"))
    #expect(one["columnTypes"] == .array([.string("INTEGER"), .string("TEXT")]))
    #expect(one["millis"] == .number(12))
    #expect(one["truncated"] == .bool(true))
    #expect(one["rowCount"] == .number(1))

    // The second pane is untouched by the first. Before 2c-i exactly one
    // pane id was ever read, so "per pane" was a claim the store made and
    // nothing tested.
    let two = object(await store.snapshot(paneId: "db-2"))
    #expect(two["rowCount"] == .number(0))
    #expect(two["columnTypes"] == .array([]))
}

@Test func selectionRoundTripsAndAlwaysContainsItsAnchor() async {
    let store = PaneStore()
    await store.setSelection(
        paneId: "db", PaneSelection(anchorRow: 7, anchorColumn: "name", rows: [2, 3]))
    let snap = object(await store.snapshot(paneId: "db"))
    let selection = object(snap["selection"] ?? .null)
    #expect(selection["anchorRow"] == .number(7))
    #expect(selection["anchorColumn"] == .string("name"))
    guard case .array(let rows)? = selection["rows"] else {
        Issue.record("selection.rows is not an array")
        return
    }
    // Sorted on the way out. A Set has no order, and an agent diffing two
    // read_pane calls must not see a change that is only the hash seed.
    #expect(rows == [.number(2), .number(3), .number(7)])
}

@Test func sortIsRecordedAsIntentAndIsNullUntilSet() async {
    let store = PaneStore()
    #expect(object(await store.snapshot(paneId: "db"))["sort"] == .null)
    await store.setSort(paneId: "db", PaneSort(column: "balance", direction: .descending))
    let sort = object(object(await store.snapshot(paneId: "db"))["sort"] ?? .null)
    #expect(sort["column"] == .string("balance"))
    #expect(sort["direction"] == .string("desc"))
}

@Test func settingRowsDoesNotDisturbSelectionOrSort() async {
    // These have different writers and different lifetimes: a query replaces
    // rows, and a click replaces selection. Folding them into one setter
    // would make every refresh silently clear what the operator picked.
    let store = PaneStore()
    await store.setSelection(paneId: "db", PaneSelection(anchorRow: 1, anchorColumn: "id", rows: [1]))
    await store.setSort(paneId: "db", PaneSort(column: "id", direction: .ascending))
    await store.setRows(
        paneId: "db", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 1, truncated: false)
    let snap = object(await store.snapshot(paneId: "db"))
    #expect(object(snap["selection"] ?? .null)["anchorRow"] == .number(1))
    #expect(object(snap["sort"] ?? .null)["column"] == .string("id"))
}

@Test func paneIdsListsEveryPaneWrittenTo() async {
    let store = PaneStore()
    await store.setRows(paneId: "b", columns: [], columnTypes: [], columnTypesInferred: false,
                        rows: [], millis: 0, truncated: false)
    await store.setSelection(paneId: "a", PaneSelection(anchorRow: 0, anchorColumn: nil, rows: []))
    // Sorted, for the same reason selection.rows is.
    #expect(await store.paneIds() == ["a", "b"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — `setRows` has no `columnTypes` parameter.

- [ ] **Step 3: Rewrite `PaneStore`**

Replace the whole of `app/Sources/WakilKit/Panes/PaneStore.swift`:

```swift
import Foundation

/// Holds what every pane currently shows — columns, their types, rows —
/// together with what is selected in it and how it is sorted, keyed by pane
/// id.
///
/// `snapshot(paneId:)` is what an AI agent reads to answer questions about
/// what is on screen, so it must be honest: it never errors, the `rowCount`
/// it reports always matches the number of rows actually held, and
/// `truncated` says whether those rows are the whole answer. An unknown
/// pane id is not a special or invalid state — it is simply a pane with
/// nothing in it yet — so it gets the same empty shape a pane that was
/// explicitly cleared would get, rather than a thrown error.
///
/// **Three writers, three lifetimes, three setters.** A query replaces
/// rows; a click replaces the selection; a header click replaces the sort.
/// Folding them into one setter would make every refresh silently clear
/// what the operator picked, which is why `setRows` leaves selection and
/// sort alone and each has a test saying so.
///
/// An actor: these are called from different tasks — a dispatched action, a
/// pointer gesture, an agent's tool call — and must not race.
public actor PaneStore {
    private struct Contents {
        var columns: [String] = []
        var columnTypes: [String] = []
        var columnTypesInferred = false
        var rows: [[JSONValue]] = []
        var millis: Int64 = 0
        var truncated = false
        var selection: PaneSelection = .empty
        var sort: PaneSort?
        /// The row the surface has been asked to bring into view, cleared
        /// once it has been. Runtime state: it describes a scroll that is
        /// about to happen, and a persisted one would scroll a pane on
        /// launch for a request nobody made.
        var scrollTarget: Int?
    }

    private var panes: [String: Contents] = [:]

    public init() {}

    /// Replaces pane `paneId`'s columns and rows entirely. There is no
    /// incremental append: a pane always holds exactly what the most recent
    /// `setRows` gave it.
    ///
    /// **No parameter here has a default, deliberately.** Every producer of
    /// rows knows whether it handed over everything it found and how long
    /// it took, and the one that forgets to say is the failure these
    /// parameters exist to prevent: `wakil-db` caps a result at 500 rows
    /// and reports the cap, and a pane that dropped that flag would serve a
    /// capped result to `read_pane` — and so to an LLM — as a complete one.
    /// A default would make dropping it the quiet path again.
    public func setRows(
        paneId: String, columns: [String], columnTypes: [String],
        columnTypesInferred: Bool, rows: [[JSONValue]], millis: Int64, truncated: Bool
    ) {
        var contents = panes[paneId] ?? Contents()
        contents.columns = columns
        contents.columnTypes = columnTypes
        contents.columnTypesInferred = columnTypesInferred
        contents.rows = rows
        contents.millis = millis
        contents.truncated = truncated
        panes[paneId] = contents
    }

    public func setSelection(paneId: String, _ selection: PaneSelection) {
        var contents = panes[paneId] ?? Contents()
        contents.selection = selection
        panes[paneId] = contents
    }

    public func setSort(paneId: String, _ sort: PaneSort?) {
        var contents = panes[paneId] ?? Contents()
        contents.sort = sort
        panes[paneId] = contents
    }

    public func setScrollTarget(paneId: String, row: Int?) {
        var contents = panes[paneId] ?? Contents()
        contents.scrollTarget = row
        panes[paneId] = contents
    }

    /// Every pane id anything has been written to, sorted.
    ///
    /// Sorted rather than in dictionary order for the same reason
    /// `selection.rows` is: an agent diffing two reads must not see a
    /// change that is only the hash seed.
    public func paneIds() -> [String] { panes.keys.sorted() }

    /// What `read_pane` returns, and what the view draws from.
    ///
    /// **Every key is always present**, including when false, empty or
    /// null. The Go side omits `truncated` when false, which is right for a
    /// wire format and wrong here: this object is read by an LLM, and an
    /// absent key is a thing a reader has to know how to interpret whereas
    /// an explicit value is an answer.
    public func snapshot(paneId: String) -> JSONValue {
        let contents = panes[paneId] ?? Contents()
        return .object([
            "columns": .array(contents.columns.map { .string($0) }),
            "columnTypes": .array(contents.columnTypes.map { .string($0) }),
            "columnTypesInferred": .bool(contents.columnTypesInferred),
            "rows": .array(contents.rows.map { .array($0) }),
            "rowCount": .number(Double(contents.rows.count)),
            "millis": .number(Double(contents.millis)),
            "truncated": .bool(contents.truncated),
            "selection": .object([
                "anchorRow": contents.selection.anchorRow.map { .number(Double($0)) } ?? .null,
                "anchorColumn": contents.selection.anchorColumn.map { .string($0) } ?? .null,
                "rows": .array(contents.selection.rows.sorted().map { .number(Double($0)) }),
            ]),
            "sort": contents.sort.map {
                .object(["column": .string($0.column), "direction": .string($0.direction.rawValue)])
            } ?? .null,
            "scrollTarget": contents.scrollTarget.map { .number(Double($0)) } ?? .null,
        ])
    }
}
```

- [ ] **Step 4: Update the one existing caller**

In `app/Sources/WakilKit/Registry/StandardActions.swift`, `dbPaneContents` (line 744)
must return the new fields. Replace it:

```swift
func dbPaneContents(from result: JSONValue) -> (
    columns: [String], columnTypes: [String], columnTypesInferred: Bool,
    rows: [[JSONValue]], millis: Int64, truncated: Bool
)? {
    guard case .object(let resultObj) = result,
        case .object(let structured)? = resultObj["structuredContent"],
        case .array(let columnValues)? = structured["columns"],
        case .array(let rowValues)? = structured["rows"]
    else {
        return nil
    }
    let columns = columnValues.compactMap { value -> String? in
        if case .string(let s) = value { return s }
        return nil
    }
    // All or nothing, matching wakilcore.Rows.ColumnTypes' own contract: a
    // positionally aligned slice that is short would annotate the wrong
    // columns, which is worse than annotating none.
    var columnTypes: [String] = []
    if case .array(let typeValues)? = structured["columnTypes"] {
        let decoded = typeValues.map { value -> String in
            if case .string(let s) = value { return s }
            return ""
        }
        if decoded.count == columns.count { columnTypes = decoded }
    }
    var columnTypesInferred = false
    if case .bool(let flag)? = structured["columnTypesInferred"] { columnTypesInferred = flag }
    let rows = rowValues.compactMap { value -> [JSONValue]? in
        if case .array(let row) = value { return row }
        return nil
    }
    var millis: Int64 = 0
    if case .number(let value)? = structured["millis"] { millis = Int64(value) }
    var truncated = false
    if case .bool(let flag)? = structured["truncated"] { truncated = flag }
    return (columns, columnTypes, columnTypesInferred, rows, millis, truncated)
}
```

And in `db_run_query`'s handler, replace the `setRows` call:

```swift
            if let contents = dbPaneContents(from: result) {
                await panes.setRows(
                    paneId: paneId, columns: contents.columns,
                    columnTypes: contents.columnTypes,
                    columnTypesInferred: contents.columnTypesInferred,
                    rows: contents.rows, millis: contents.millis,
                    truncated: contents.truncated)
            }
```

`paneId` does not exist yet — for this task only, write `paneId: "db"` and leave the
parameter to Task 5. Fixing both in one task would make a failing build the boundary
between them.

- [ ] **Step 5: Run the tests**

Run: `make app-test`
Expected: PASS. `MCPServerTests` and `WindowModelTests` may fail on the new snapshot
keys; update their expectations to include the new keys rather than weakening the
assertion — the keys being present is the contract.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneStore.swift app/Tests/WakilKitTests/PaneStoreTests.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/
git commit -m "PaneStore holds typed contents, selection and sort, per pane"
```

---

## Task 5: `db_run_query` writes to the pane it was told to

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — `db_run_query` (line 331)
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: `PaneStore.setRows` (Task 4).
- Produces: `db_run_query` accepts an optional `pane` param, defaulting to `"db"`.

- [ ] **Step 1: Write the failing test**

Add to `app/Tests/WakilKitTests/StandardActionsTests.swift`, following whatever fake
`MCPClient` the file already uses for `db_run_query` (read the existing
`db_run_query` tests and reuse their harness — do not add a second one):

```swift
@Test func dbRunQueryWritesToTheNamedPane() async throws {
    let (registry, panes) = try await standardActionsOverStubbedDatabase(
        queryResult: .object([
            "structuredContent": .object([
                "columns": .array([.string("id")]),
                "columnTypes": .array([.string("INTEGER")]),
                "rows": .array([.array([.number(7)])]),
                "millis": .number(3),
            ])
        ]))

    _ = try await registry.dispatch(
        name: "db_run_query",
        params: .object(["query": .string("select 1"), "pane": .string("db-2")]),
        origin: .agent, environment: "staging", confirmation: nil)

    guard case .object(let named) = await panes.snapshot(paneId: "db-2"),
          case .object(let fallback) = await panes.snapshot(paneId: "db") else {
        Issue.record("snapshot is not an object")
        return
    }
    #expect(named["rowCount"] == .number(1))
    // The old hardcoded "db" must be genuinely unwritten, not merely also
    // written — two panes showing one result is the bug this parameter
    // exists to make impossible.
    #expect(fallback["rowCount"] == .number(0))
}

@Test func dbRunQueryStillDefaultsToTheDbPane() async throws {
    let (registry, panes) = try await standardActionsOverStubbedDatabase(
        queryResult: .object([
            "structuredContent": .object([
                "columns": .array([.string("id")]),
                "rows": .array([.array([.number(7)])]),
            ])
        ]))
    _ = try await registry.dispatch(
        name: "db_run_query", params: .object(["query": .string("select 1")]),
        origin: .agent, environment: "staging", confirmation: nil)
    guard case .object(let fallback) = await panes.snapshot(paneId: "db") else {
        Issue.record("snapshot is not an object")
        return
    }
    #expect(fallback["rowCount"] == .number(1))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — the named pane has `rowCount` 0 and `"db"` has 1.

- [ ] **Step 3: Add the parameter**

In `db_run_query`'s `schema`, add to `properties`:

```swift
                "pane": .object(["type": .string("string")]),
```

and extend the description so an agent knows what it is for:

```swift
        description: "Run a read-only query against the active environment's database and "
            + "return rows. The rows are also written into a pane so that what is on screen "
            + "and what this returns are the same thing; pane names which one, defaulting to "
            + "\"db\".",
```

In the handler, above the `callChecked` call:

```swift
            let paneId = optionalStringParam(params, "pane") ?? "db"
```

If `optionalStringParam` does not exist in this file, use the same shape the file's
other optional reads use (`if case .object(let obj) = params, case .string(let s)? =
obj["pane"]`), and do not add a new helper for one call site.

- [ ] **Step 4: Run the tests**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "db_run_query writes to the pane it was told to, not always \"db\""
```

---
## Task 6: `Pane.columnWidths`, persisted

**Files:**
- Modify: `app/Sources/WakilKit/Layout/Pane.swift`
- Test: `app/Tests/WakilKitTests/PaneTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Pane.columnWidths: [String: Double]`, defaulting to `[:]`, in `CodingKeys`.

**Why widths live here and not in `PaneStore`:** `Pane`'s own comment draws the line —
runtime state is dropped on save, settings are kept. `busy` is dropped, `density` is
kept. A width an operator dragged is a setting, and it belongs with the geometry that
persists beside it.

- [ ] **Step 1: Write the failing test**

Add to `app/Tests/WakilKitTests/PaneTests.swift`:

```swift
@Test func columnWidthsSurviveAJSONRoundTrip() throws {
    var pane = Pane(
        id: "db-1", kind: "db", title: "Query results",
        frame: PaneFrame(x: 1, y: 2, width: 3, height: 4))
    pane.columnWidths = ["id": 60, "name": 240]
    let data = try JSONEncoder().encode(pane)
    #expect(try JSONDecoder().decode(Pane.self, from: data).columnWidths == pane.columnWidths)
}

@Test func aLayoutWrittenBeforeColumnWidthsExistedStillDecodes() throws {
    // The same tolerance `density` needed: a field added after some layout
    // was last saved must decode with its default rather than taking the
    // whole file down. This is why Pane has a hand-written init(from:) at
    // all — a synthesized decoder treats a listed non-optional key as
    // required.
    let json = """
        {"id":"db-1","kind":"db","title":"T","frame":{"x":1,"y":2,"width":3,"height":4}}
        """
    let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    #expect(pane.columnWidths.isEmpty)
    #expect(pane.density == .airy)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — `value of type 'Pane' has no member 'columnWidths'`.

- [ ] **Step 3: Add the field**

In `app/Sources/WakilKit/Layout/Pane.swift`, after `density`:

```swift
    /// Each column's width in canvas points, by column name, for the
    /// columns the operator has resized. A column absent from this
    /// dictionary is laid out by `paneColumnWidth`'s even division of the
    /// space available; one present overrides it.
    ///
    /// **Keyed by name rather than by index**, because a query that returns
    /// the same columns in a different order — or one more of them — must
    /// not hand column 2's width to a different column. An index would
    /// silently do exactly that.
    ///
    /// **In `CodingKeys`, like `density` and unlike `busy`.** A width the
    /// operator dragged is a setting, not runtime state.
    public var columnWidths: [String: Double] = [:]
```

Add `columnWidths` to `CodingKeys`:

```swift
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, frame, density, columnWidths
    }
```

Add it to the memberwise initialiser, after `density`:

```swift
        columnWidths: [String: Double] = [:]
```
```swift
        self.columnWidths = columnWidths
```

And to `init(from:)`, tolerantly:

```swift
        columnWidths = try container.decodeIfPresent([String: Double].self, forKey: .columnWidths) ?? [:]
```

- [ ] **Step 4: Run the tests**

Run: `make app-test`
Expected: PASS. `LayoutPersistenceTests` should be unaffected — if a test pins the
exact encoded JSON of a `Pane`, update it to include `"columnWidths":{}`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Layout/Pane.swift app/Tests/WakilKitTests/PaneTests.swift
git commit -m "A pane remembers the column widths its operator dragged"
```

---

## Task 7: The five actions

**Files:**
- Create: `app/Sources/WakilKit/Panes/PaneContentActions.swift`
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` — call the new registrar
- Test: `app/Tests/WakilKitTests/PaneContentActionsTests.swift` (new)

**Interfaces:**
- Consumes: `PaneStore` (Task 4), `LayoutStore`, `Pane.columnWidths` (Task 6),
  `ActionRegistry`, `PaneSelection`, `PaneSort`, `PaneSortDirection` (Task 3).
- Produces: `registerPaneContentActions(into:panes:layout:) async`, and these five
  registered action names: `pane_select_cell`, `pane_select_rows`, `pane_sort`,
  `pane_set_column_width`, `pane_scroll_to_row`.

Read `app/Sources/WakilKit/Layout/LayoutActions.swift` before starting: this file is
its sibling and should match it in shape, in error type usage
(`LayoutActionError.missingParam` / `.badParam`) and in how params are read.
`LayoutStore` needs a `setColumnWidth(id:column:width:)` method — add it there beside
`setBusy`, not here.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/PaneContentActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let o) = value else { return [:] }
    return o
}

/// The same construction `LayoutActionsTests.makeRegistry` uses — a real
/// ActionRegistry over a throwaway journal directory. The caller deletes
/// the directory.
private func fixture() async -> (ActionRegistry, PaneStore, LayoutStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pane-content-actions-\(UUID().uuidString)", isDirectory: true)
    let panes = PaneStore()
    let layout = LayoutStore()
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerLayoutActions(into: registry, layout: layout)
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    return (registry, panes, layout, directory)
}

/// Dispatches through the registry the way every caller does, so these
/// tests exercise the gate and the journal rather than the handler alone.
private func run(
    _ registry: ActionRegistry, _ name: String, _ params: JSONValue,
    origin: ActionOrigin = .ui
) async throws -> JSONValue {
    try await registry.dispatch(
        name: name, params: params, origin: origin, environment: "staging", confirmation: nil)
}

@Test func selectCellSetsTheAnchorAndCollapsesTheSelectionToItsRow() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_select_rows", .object([
        "pane": .string("db"), "rows": .array([.number(1), .number(2)]),
        "anchor": .number(1)]))
    _ = try await run(registry, "pane_select_cell", .object([
        "pane": .string("db"), "row": .number(9), "column": .string("name")]))
    let selection = object(object(await panes.snapshot(paneId: "db"))["selection"] ?? .null)
    #expect(selection["anchorRow"] == .number(9))
    #expect(selection["anchorColumn"] == .string("name"))
    // Collapsed, not extended: clicking a cell is how you START a
    // selection. Shift- and command-click go through pane_select_rows.
    #expect(selection["rows"] == .array([.number(9)]))
}

@Test func selectRowsKeepsTheAnchorInsideTheSetItNames() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_select_rows", .object([
        "pane": .string("db"), "rows": .array([.number(2), .number(3)]),
        "anchor": .number(8)]), origin: .agent)
    let selection = object(object(await panes.snapshot(paneId: "db"))["selection"] ?? .null)
    #expect(selection["rows"] == .array([.number(2), .number(3), .number(8)]))
}

@Test func aNegativeRowIsRefused() async throws {
    let (registry, _, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: LayoutActionError.self) {
        _ = try await run(
            registry, "pane_select_cell",
            .object(["pane": .string("db"), "row": .number(-1)]), origin: .agent)
    }
}

@Test func sortRecordsIntentAndClearsWhenAskedTo() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_sort", .object([
        "pane": .string("db"), "column": .string("balance"),
        "direction": .string("desc")]))
    #expect(object(object(await panes.snapshot(paneId: "db"))["sort"] ?? .null)["direction"]
            == .string("desc"))
    // Omitting the column is how a sort is removed. There is no separate
    // pane_clear_sort, because "sorted by nothing" is a value of this
    // action's own parameter rather than a different operation.
    _ = try await run(registry, "pane_sort", .object(["pane": .string("db")]))
    #expect(object(await panes.snapshot(paneId: "db"))["sort"] == .null)
}

@Test func anUnknownSortDirectionIsRefusedRatherThanDefaulted() async throws {
    let (registry, _, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: LayoutActionError.self) {
        _ = try await run(registry, "pane_sort", .object([
            "pane": .string("db"), "column": .string("id"),
            "direction": .string("sideways")]), origin: .agent)
    }
}

@Test func columnWidthLandsOnThePaneAndPersistsWithIt() async throws {
    let (registry, _, layout, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = await layout.open(kind: "db", title: "Results")
    _ = try await run(registry, "pane_set_column_width", .object([
        "pane": .string(pane.id), "column": .string("name"), "width": .number(240)]))
    let stored = await layout.snapshot().panes.first { $0.id == pane.id }
    #expect(stored?.columnWidths["name"] == 240)
}

@Test func scrollToRowIsRecordedAsATarget() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_scroll_to_row", .object([
        "pane": .string("db"), "row": .number(4812)]), origin: .agent)
    #expect(object(await panes.snapshot(paneId: "db"))["scrollTarget"] == .number(4812))
}

@Test func allFiveAreControlAndNameNoTargetEnvironment() async {
    let (registry, _, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let byName = Dictionary(uniqueKeysWithValues: await registry.all().map { ($0.name, $0) })
    for name in ["pane_select_cell", "pane_select_rows", "pane_sort",
                 "pane_set_column_width", "pane_scroll_to_row"] {
        guard let action = byName[name] else {
            Issue.record("\(name) is not registered")
            continue
        }
        // .control, not .mutate: these change Wakil's own state and nothing
        // outside it, so being pointed at a production database is no
        // reason to be unable to select a row. Filed .mutate, the gate
        // would block all five in production.
        #expect(action.kind == .control, "\(name) is \(action.kind)")
    }
}

@Test func theSameSelectionFromUiAgentAndDebugJournalsIdentically() async throws {
    // 2a's acceptance check, in its 2c form. The whole point of routing
    // every state change through the registry is that origin is the only
    // thing that distinguishes them afterwards.
    var entries: [JournalEntry] = []
    for origin in [ActionOrigin.ui, .agent, .debug] {
        let (registry, _, _, directory) = await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await run(
            registry, "pane_select_cell",
            .object(["pane": .string("db"), "row": .number(3), "column": .string("id")]),
            origin: origin)
        entries.append(try await registry.journalEntries().last!)
    }
    #expect(Set(entries.map(\.origin)) == [.ui, .agent, .debug])
    #expect(Set(entries.map(\.action)) == ["pane_select_cell"])
    #expect(Set(entries.map(\.params)).count == 1)
    #expect(Set(entries.map(\.outcome)).count == 1)
}
```

The fixture above is the verified construction: `ActionRegistry(journalDirectory:sessionId:)`
over a throwaway directory, entries read back with `await registry.journalEntries()`.
`JournalEntry` has `id`, `ts`, `action`, `params`, `origin`, `paneId`, `environment`,
`outcome` — and **no** `kind`, which is why the last test compares `params` and
`outcome` instead. `LayoutActionsTests.makeRegistry` is the same shape.

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — `cannot find 'registerPaneContentActions' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Sources/WakilKit/Panes/PaneContentActions.swift`:

```swift
import Foundation

/// Registers the five actions that drive a pane's *contents* — as distinct
/// from `LayoutActions`, which drives its geometry.
///
/// **Why these are actions at all.** Invariant 2 says every pane is
/// dual-driven, and selecting a row is driving a pane: "use the id from the
/// row you just highlighted" is a thing to say out loud, and an agent that
/// can neither see nor set the selection can only answer half of "what's on
/// screen?". Registering them also puts them in ⌘K for free, since the
/// palette is `registry.all()`.
///
/// **Why `.control` and why none names a target environment.** They change
/// Wakil's own state and nothing outside it, so the write gate's production
/// rule must not apply — being pointed at a production database is no
/// reason to be unable to select a row. And none of them changes which
/// environment is active, so none can be an agent walking into production.
///
/// **Why `row` is an index into the displayed order.** A sort reorders what
/// is on screen, so a displayed index and an underlying one diverge the
/// moment one is applied, and only one of them can be what these actions
/// and `read_pane` both mean. Invariant 3 settles it: the surface reflects
/// what is actually on screen. A sort therefore invalidates a
/// previously-held index, which is correct — after re-sorting, row 4 *is* a
/// different row, to the operator's eye as much as to the agent's.
public func registerPaneContentActions(
    into registry: ActionRegistry, panes: PaneStore, layout: LayoutStore
) async {
    await registry.register(Action(
        name: "pane_select_cell",
        description: "Select one cell in a pane: its row becomes the anchor and the "
            + "selection collapses to that row. row is an index into the order currently "
            + "displayed, which a sort changes.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "row": .object(["type": .string("number")]),
                "column": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("row")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_select_cell")
            let row = try requireRowIndex(params, "row", action: "pane_select_cell")
            let column = optionalString(params, "column")
            await panes.setSelection(
                paneId: pane,
                PaneSelection(anchorRow: row, anchorColumn: column, rows: [row]))
            return .object(["pane": .string(pane), "row": .number(Double(row))])
        }
    ))

    await registry.register(Action(
        name: "pane_select_rows",
        description: "Select several rows in a pane. anchor names which of them carries "
            + "the anchor, and is added to the set if it is not already in it. Row indices "
            + "are into the order currently displayed.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "rows": .object([
                    "type": .string("array"), "items": .object(["type": .string("number")]),
                ]),
                "anchor": .object(["type": .string("number")]),
                "column": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("rows")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_select_rows")
            guard case .object(let obj) = params, case .array(let rowValues)? = obj["rows"] else {
                throw LayoutActionError.missingParam(action: "pane_select_rows", param: "rows")
            }
            var rows: Set<Int> = []
            for value in rowValues {
                guard case .number(let number) = value, number >= 0, number == number.rounded()
                else {
                    throw LayoutActionError.badParam(
                        action: "pane_select_rows", param: "rows", value: "\(value)")
                }
                rows.insert(Int(number))
            }
            var anchor: Int?
            if obj["anchor"] != nil {
                anchor = try requireRowIndex(params, "anchor", action: "pane_select_rows")
            } else {
                anchor = rows.min()
            }
            await panes.setSelection(
                paneId: pane,
                PaneSelection(
                    anchorRow: anchor, anchorColumn: optionalString(params, "column"), rows: rows))
            return .object(["pane": .string(pane), "rowCount": .number(Double(rows.count))])
        }
    ))

    await registry.register(Action(
        name: "pane_sort",
        description: "Sort a pane by a column. This records INTENT: a pane that can "
            + "re-query re-queries, and one that cannot sorts only the rows it holds and "
            + "says so. Omit column to remove the sort.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "column": .object(["type": .string("string")]),
                "direction": .object([
                    "type": .string("string"),
                    "enum": .array([.string("asc"), .string("desc")]),
                ]),
            ]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_sort")
            guard let column = optionalString(params, "column") else {
                await panes.setSort(paneId: pane, nil)
                return .object(["pane": .string(pane), "sorted": .bool(false)])
            }
            let raw = optionalString(params, "direction") ?? "asc"
            // Refused rather than defaulted: silently reading "sideways" as
            // ascending would sort the wrong way round and tell nobody.
            guard let direction = PaneSortDirection(rawValue: raw) else {
                throw LayoutActionError.badParam(
                    action: "pane_sort", param: "direction", value: raw)
            }
            await panes.setSort(paneId: pane, PaneSort(column: column, direction: direction))
            return .object([
                "pane": .string(pane), "column": .string(column),
                "direction": .string(direction.rawValue),
            ])
        }
    ))

    await registry.register(Action(
        name: "pane_set_column_width",
        description: "Set one column's width in a pane, in points. Persisted with the pane.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "column": .object(["type": .string("string")]),
                "width": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("pane"), .string("column"), .string("width")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_set_column_width")
            let column = try requireString(params, "column", action: "pane_set_column_width")
            guard case .object(let obj) = params, case .number(let width)? = obj["width"],
                  width > 0
            else {
                throw LayoutActionError.badParam(
                    action: "pane_set_column_width", param: "width", value: "\(params)")
            }
            await layout.setColumnWidth(id: pane, column: column, width: width)
            return .object(["pane": .string(pane), "column": .string(column),
                            "width": .number(width)])
        }
    ))

    await registry.register(Action(
        name: "pane_scroll_to_row",
        description: "Bring a row into view in a pane. Row indices are into the order "
            + "currently displayed.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "row": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("pane"), .string("row")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "pane_scroll_to_row")
            let row = try requireRowIndex(params, "row", action: "pane_scroll_to_row")
            await panes.setScrollTarget(paneId: pane, row: row)
            return .object(["pane": .string(pane), "row": .number(Double(row))])
        }
    ))
}

/// A row index: present, a number, non-negative, and whole.
///
/// Whole matters as much as non-negative. A `row` of 3.5 from an agent is a
/// mistake, and `Int(3.5)` would silently make it 3 — a selection one row
/// off from what was asked for, with nothing anywhere saying so.
private func requireRowIndex(_ params: JSONValue, _ key: String, action: String) throws -> Int {
    guard case .object(let obj) = params else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    guard let value = obj[key] else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    guard case .number(let number) = value, number >= 0, number == number.rounded() else {
        throw LayoutActionError.badParam(action: action, param: key, value: "\(value)")
    }
    return Int(number)
}
```

`requireString` and `optionalString` are `LayoutActions.swift`'s existing private
helpers. If they are `private` to that file, change them to `internal` (drop the
keyword) rather than duplicating them here — two copies of a param reader is exactly
the drift this codebase's comments keep warning about.

- [ ] **Step 4: Add `LayoutStore.setColumnWidth`**

In `app/Sources/WakilKit/Layout/LayoutStore.swift`, beside `setBusy`:

```swift
    /// Sets one column's width on pane `id`, or does nothing if no such
    /// pane is open.
    ///
    /// Silent on an unknown id, matching `setBusy`: a pane closed between a
    /// drag starting and finishing is an ordinary race, not an error worth
    /// failing a dispatch over.
    public func setColumnWidth(id: String, column: String, width: Double) {
        guard var current = byProject[project],
              let index = current.panes.firstIndex(where: { $0.id == id })
        else { return }
        current.panes[index].columnWidths[column] = width
        byProject[project] = current
    }
```

This mirrors `setBusy` (`LayoutStore.swift:213`) exactly, including the per-project
storage — panes live in `byProject[project]`, never in a flat array, and a version that
reached for `self.panes` would not compile.

- [ ] **Step 5: Wire it up**

In `app/Sources/WakilKit/App/AppWiring.swift`, wherever `registerLayoutActions` is
called, add immediately after it:

```swift
        await registerPaneContentActions(into: registry, panes: panes, layout: layout)
```

- [ ] **Step 6: Run the tests**

Run: `make app-test`
Expected: PASS. `PaletteTests` may assert a ⌘K item count — update the expected number
by five rather than loosening the assertion; the palette growing is the point.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneContentActions.swift app/Sources/WakilKit/Layout/LayoutStore.swift app/Sources/WakilKit/Layout/LayoutActions.swift app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/
git commit -m "Selection, sort, column width and scroll are actions like everything else"
```

---
## Task 8: `read_pane` describes what it now returns

**Files:**
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift:238-249` (`readPaneToolListEntry`)
- Test: `app/Tests/WakilKitTests/MCPServerTests.swift`

`read_pane`'s *payload* already grew in Task 4 — it returns `PaneStore.snapshot`
verbatim. What has not grown is its **description**, and that is what an agent reads
before deciding whether to call it. A tool that returns a selection nobody advertised is
a tool nobody uses.

**Interfaces:**
- Consumes: `PaneStore.snapshot`'s new keys (Task 4).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Add to `app/Tests/WakilKitTests/MCPServerTests.swift`:

```swift
@Test func readPaneAdvertisesEverythingItReturns() async throws {
    let surface = try await testMCPSurface()
    let listed = try await toolsList(surface)
    guard let entry = listed.first(where: { $0["name"] == .string("read_pane") }),
          case .string(let description)? = entry["description"] else {
        Issue.record("read_pane is not in tools/list")
        return
    }
    // Every key the payload carries is named here, because a key an agent
    // was not told about is a key it will not look for. The list is the
    // same one PaneStoreTests pins on the payload itself.
    for term in ["columnTypes", "truncated", "selection", "sort", "millis"] {
        #expect(description.contains(term), "read_pane does not mention \(term)")
    }
}
```

`testMCPSurface` and `toolsList` are whatever helpers this file already uses to build a
surface and read `tools/list` — reuse them; do not add new ones.

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — the description mentions none of `columnTypes`, `selection`, `sort`.

- [ ] **Step 3: Rewrite the description**

```swift
private let readPaneToolListEntry = JSONValue.object([
    "name": .string(readPaneToolName),
    "description": .string(
        "Read what a Wakil UI pane is currently showing. Returns columns and, when the "
        + "driver could say, columnTypes alongside them (columnTypesInferred is true when "
        + "those types were worked out from the values rather than declared, which only "
        + "happens for Mongo); rows and rowCount; millis, how long the query behind them "
        + "took; truncated, true when more rows matched than were returned — treat a "
        + "truncated pane as a partial answer, never as the whole one; selection, the "
        + "operator's anchor cell and selected rows; and sort, the column and direction "
        + "the pane is sorted by, or null. Every row index in selection, in sort's effect "
        + "and in the rows array is an index into the order currently DISPLAYED, which a "
        + "sort changes."),
    "inputSchema": .object([
        "type": .string("object"),
        "properties": .object(["paneId": .object(["type": .string("string")])]),
        "required": .array([.string("paneId")]),
    ]),
])
```

- [ ] **Step 4: Run the tests**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/MCPServer.swift app/Tests/WakilKitTests/MCPServerTests.swift
git commit -m "read_pane says what it now returns"
```

---

## Task 9: `WindowModel` projects contents per pane

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `PaneRow`, `PaneTable`,
  `paneTable(from:)`, `paneCellText`, and the `columns` / `rows` / `truncated`
  properties plus `refreshPane()` and `paneId`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `PaneCell`, `PaneColumn`, `PaneSelection`, `PaneSort` (Task 3);
  `PaneStore.snapshot`, `PaneStore.paneIds` (Task 4).
- Produces:
  - `PaneRow` — `id: Int`, `cells: [PaneCell]`
  - `PaneTable` — `columns: [PaneColumn]`, `columnTypesInferred: Bool`, `rows: [PaneRow]`,
    `millis: Int64`, `truncated: Bool`, `selection: PaneSelection`, `sort: PaneSort?`,
    `scrollTarget: Int?`, plus `static let empty`
  - `paneTable(from: JSONValue) -> PaneTable` — unchanged name, widened result
  - `WindowModel.tables: [String: PaneTable]` replacing `columns` / `rows` / `truncated`
  - `WindowModel.table(_ paneId: String) -> PaneTable` — `.empty` for an unknown id

**What goes away:** `WindowModel.paneId` (the hardcoded `"db"` at line 738 and 834),
`WindowModel.columns`, `WindowModel.rows`, `WindowModel.truncated`, and the free
function `paneCellText`. `PaneCell`'s initialiser replaces the last of those and Task 3
already carries its tests, so delete it rather than leaving two projections of the same
JSON.

- [ ] **Step 1: Write the failing test**

Add to `app/Tests/WakilKitTests/WindowModelTests.swift`:

```swift
@Test func paneTableCarriesTypesSelectionAndSort() {
    let snapshot = JSONValue.object([
        "columns": .array([.string("id"), .string("name")]),
        "columnTypes": .array([.string("INTEGER"), .string("TEXT")]),
        "columnTypesInferred": .bool(false),
        "rows": .array([.array([.number(1), .null])]),
        "rowCount": .number(1),
        "millis": .number(9),
        "truncated": .bool(true),
        "selection": .object([
            "anchorRow": .number(0), "anchorColumn": .string("name"),
            "rows": .array([.number(0)]),
        ]),
        "sort": .object(["column": .string("id"), "direction": .string("desc")]),
        "scrollTarget": .null,
    ])
    let table = paneTable(from: snapshot)
    #expect(table.columns.map(\.name) == ["id", "name"])
    #expect(table.columns.map(\.type) == ["INTEGER", "TEXT"])
    #expect(table.millis == 9)
    #expect(table.truncated)
    #expect(table.selection.anchorRow == 0)
    #expect(table.sort?.direction == .descending)
    // The NULL survives the projection as a NULL rather than as "".
    #expect(table.rows[0].cells[1].isNull)
}

@Test func paneTableStaysTotalOnAShapeItDoesNotRecognise() {
    // Total, deliberately: `snapshot` never errors and answers an untouched
    // pane with empty columns and rows, so an unrecognised shape is treated
    // the same way — an empty table, not a thrown error there is no place
    // in a SwiftUI body to catch.
    #expect(paneTable(from: .string("nonsense")).columns.isEmpty)
    #expect(paneTable(from: .object([:])).rows.isEmpty)
    #expect(paneTable(from: .object([:])).sort == nil)
}

@Test func columnTypesOfTheWrongLengthAreDroppedEntirely() {
    // All or nothing, the same contract wakilcore.Rows.ColumnTypes states:
    // a short positionally-aligned slice annotates the WRONG columns, which
    // is worse than annotating none.
    let table = paneTable(from: .object([
        "columns": .array([.string("a"), .string("b")]),
        "columnTypes": .array([.string("INTEGER")]),
        "rows": .array([]),
    ]))
    #expect(table.columns.allSatisfy { $0.type == nil })
}

@Test func aModelHoldsATablePerPane() async throws {
    let model = try await testWindowModel()
    await model.panesForTesting.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 0, truncated: false)
    await model.refreshPanes()
    #expect(model.table("db-1").rows.count == 1)
    // An unknown pane is empty rather than absent, so a SwiftUI body can
    // ask for one unconditionally.
    #expect(model.table("never-written").rows.isEmpty)
}
```

`testWindowModel` and `panesForTesting` must match what `WindowModelTests.swift`
already does to reach a model's `PaneStore` — read the file and use its existing route;
add a `@testable`-visible accessor only if none exists.

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — `PaneTable` has no member `millis`.

- [ ] **Step 3: Widen the projection**

In `app/Sources/WakilKit/App/WindowModel.swift`, replace `PaneRow`, `PaneTable`,
`paneTable(from:)` and delete `paneCellText`:

```swift
/// One row of a data surface, identified by its position in the order
/// currently displayed.
public struct PaneRow: Sendable, Equatable, Identifiable {
    public let id: Int
    public let cells: [PaneCell]

    public init(id: Int, cells: [PaneCell]) {
        self.id = id
        self.cells = cells
    }
}

/// Everything a pane's data surface needs to draw itself, projected out of
/// `PaneStore.snapshot`'s JSON.
public struct PaneTable: Sendable, Equatable {
    public let columns: [PaneColumn]
    /// True when `columns`' types were worked out from the values rather
    /// than declared by the engine. The footer says so, because an
    /// annotation the operator cannot tell from a guess is worse than none.
    public let columnTypesInferred: Bool
    public let rows: [PaneRow]
    /// How long the query behind these rows took. §8's footer wants it, and
    /// `wakilcore.Rows` has carried it since Phase 1.
    public let millis: Int64
    /// True when the query behind these rows returned more than were kept.
    /// Drawn in the footer, because a human reading 500 rows has exactly the
    /// same way of being wrong about them as the agent reading `read_pane`.
    public let truncated: Bool
    public let selection: PaneSelection
    public let sort: PaneSort?
    public let scrollTarget: Int?

    public static let empty = PaneTable(
        columns: [], columnTypesInferred: false, rows: [], millis: 0, truncated: false,
        selection: .empty, sort: nil, scrollTarget: nil)

    public init(
        columns: [PaneColumn], columnTypesInferred: Bool, rows: [PaneRow], millis: Int64,
        truncated: Bool, selection: PaneSelection, sort: PaneSort?, scrollTarget: Int?
    ) {
        self.columns = columns
        self.columnTypesInferred = columnTypesInferred
        self.rows = rows
        self.millis = millis
        self.truncated = truncated
        self.selection = selection
        self.sort = sort
        self.scrollTarget = scrollTarget
    }
}

/// Projects a `PaneStore.snapshot(paneId:)` result into a drawable table.
///
/// Total, and deliberately so: `snapshot` never errors and answers for a
/// pane nothing has written to with empty columns and rows, so a shape this
/// function does not recognise is treated the same way — an empty table,
/// not a thrown error there is no place in a SwiftUI body to catch. Cells
/// shorter than the column list are not padded and longer ones are not
/// truncated; the view draws `cells[index]` only where the index exists.
public func paneTable(from snapshot: JSONValue) -> PaneTable {
    guard case .object(let object) = snapshot else { return .empty }

    var names: [String] = []
    if case .array(let columnValues)? = object["columns"] {
        names = columnValues.map { PaneCell($0).text }
    }
    // All or nothing — see the test, and wakilcore.Rows.ColumnTypes.
    var types: [String?] = Array(repeating: nil, count: names.count)
    if case .array(let typeValues)? = object["columnTypes"], typeValues.count == names.count {
        types = typeValues.map { value in
            if case .string(let s) = value { return s }
            return nil
        }
    }
    let columns = zip(names, types).map { PaneColumn(name: $0, type: $1) }

    var columnTypesInferred = false
    if case .bool(let flag)? = object["columnTypesInferred"] { columnTypesInferred = flag }

    var rows: [PaneRow] = []
    if case .array(let rowValues)? = object["rows"] {
        rows = rowValues.enumerated().map { index, value in
            guard case .array(let cells) = value else {
                return PaneRow(id: index, cells: [PaneCell(value)])
            }
            return PaneRow(id: index, cells: cells.map(PaneCell.init))
        }
    }

    var millis: Int64 = 0
    if case .number(let value)? = object["millis"] { millis = Int64(value) }
    // Absent or non-boolean reads as `false`, the same way an unrecognised
    // snapshot shape reads as an empty table: "not marked truncated" is
    // what every complete pane says.
    var truncated = false
    if case .bool(let flag)? = object["truncated"] { truncated = flag }

    var selection = PaneSelection.empty
    if case .object(let selectionObject)? = object["selection"] {
        var anchorRow: Int?
        if case .number(let value)? = selectionObject["anchorRow"] { anchorRow = Int(value) }
        var anchorColumn: String?
        if case .string(let value)? = selectionObject["anchorColumn"] { anchorColumn = value }
        var selected: Set<Int> = []
        if case .array(let rowValues)? = selectionObject["rows"] {
            for value in rowValues {
                if case .number(let number) = value { selected.insert(Int(number)) }
            }
        }
        selection = PaneSelection(anchorRow: anchorRow, anchorColumn: anchorColumn, rows: selected)
    }

    var sort: PaneSort?
    if case .object(let sortObject)? = object["sort"],
       case .string(let column)? = sortObject["column"] {
        var direction = PaneSortDirection.ascending
        if case .string(let raw)? = sortObject["direction"],
           let parsed = PaneSortDirection(rawValue: raw) {
            direction = parsed
        }
        sort = PaneSort(column: column, direction: direction)
    }

    var scrollTarget: Int?
    if case .number(let value)? = object["scrollTarget"] { scrollTarget = Int(value) }

    return PaneTable(
        columns: columns, columnTypesInferred: columnTypesInferred, rows: rows, millis: millis,
        truncated: truncated, selection: selection, sort: sort, scrollTarget: scrollTarget)
}
```

- [ ] **Step 4: Replace the single flattened set on the model**

In `WindowModel`, delete `columns`, `rows`, `truncated` and `paneId` (all four), and add:

```swift
    /// One table per pane, keyed by pane id.
    ///
    /// **Before 2c-i this was a single flattened `columns`/`rows` pair read
    /// under a `paneId` that defaulted to `"db"` and was never anything
    /// else**, drawn by the window rather than by any pane — which is why
    /// "every pane is dual-driven" was unreachable in that shape. Nothing
    /// here writes to `PaneStore`; these are refreshed *from* it, so what
    /// the operator sees and what `read_pane` hands the agent are the same
    /// object read twice, never two objects kept in step (Invariant 3).
    public private(set) var tables: [String: PaneTable] = [:]

    /// A pane's table, empty for one nothing has written to — so a SwiftUI
    /// body can ask unconditionally, the same way `PaneStore.snapshot` can
    /// be asked for any id at all.
    public func table(_ paneId: String) -> PaneTable { tables[paneId] ?? .empty }
```

Replace `refreshPane()` with:

```swift
    /// Re-reads every pane that has contents out of `PaneStore`.
    public func refreshPanes() async {
        var next: [String: PaneTable] = [:]
        for id in await panes.paneIds() {
            next[id] = paneTable(from: await panes.snapshot(paneId: id))
        }
        tables = next
    }
```

Update every call site of `refreshPane()` (line ~989 and anywhere the dispatch path
calls it) to `refreshPanes()`.

- [ ] **Step 5: Run the tests**

Run: `make app-test`
Expected: FAIL to **compile** in `WakilApp` — `WakilWindow.swift` still reads
`model.columns`. That is Task 11's work. To keep this task's boundary at a green build,
temporarily replace the window table's body with `EmptyView()` and leave a
`// TASK 11: the window-level table is deleted here` marker; Task 11 removes both.

Run: `make app-test` again after that edit.
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp/WakilWindow.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "WindowModel holds a table per pane, not one flattened set"
```

---
## Task 10: `DataSurface` — the view

**Files:**
- Create: `app/Sources/WakilApp/DataSurface.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — add `paneColumnLayout`
- Test: `app/Tests/WakilKitTests/PaneColumnLayoutTests.swift` (new)

`WakilApp` has no test target of its own, which is why the *arithmetic* goes into
`WakilKit` where it can be tested and only the drawing stays here — the same split
`paneColumnWidth` already established.

**Interfaces:**
- Consumes: `PaneTable`, `PaneCell`, `PaneColumn`, `PaneSelection`, `PaneSort`,
  `Pane.columnWidths`, `PaneDensity.rowHeight`, `paneColumnWidth`.
- Produces:
  - `paneColumnLayout(columns:overrides:availableWidth:horizontalSpacing:) -> [Double]`
    in `WakilKit`
  - `DataSurface` — `init(table: PaneTable, pane: Pane, dispatch: @escaping (String, JSONValue) -> Void)`

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/PaneColumnLayoutTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func columnsWithNoOverrideDivideTheSpaceEvenly() {
    let widths = paneColumnLayout(
        columns: ["a", "b", "c"], overrides: [:], availableWidth: 332, horizontalSpacing: 16)
    // (332 - 32) / 3 = 100 each, the same arithmetic paneColumnWidth does.
    #expect(widths == [100, 100, 100])
}

@Test func anOverriddenColumnKeepsItsWidthAndTheRestDivideWhatIsLeft() {
    let widths = paneColumnLayout(
        columns: ["a", "b", "c"], overrides: ["b": 200], availableWidth: 432,
        horizontalSpacing: 16)
    // 432 - 32 spacing = 400; b takes 200; a and c split the remaining 200.
    #expect(widths == [100, 200, 100])
}

@Test func overridesAreKeyedByNameSoReorderingDoesNotMisapplyThem() {
    // The reason columnWidths is a dictionary and not an array: a query
    // returning the same columns in a different order must not hand one
    // column's width to another.
    let forward = paneColumnLayout(
        columns: ["a", "b"], overrides: ["b": 200], availableWidth: 316, horizontalSpacing: 16)
    let reversed = paneColumnLayout(
        columns: ["b", "a"], overrides: ["b": 200], availableWidth: 316, horizontalSpacing: 16)
    #expect(forward == [100, 200])
    #expect(reversed == [200, 100])
}

@Test func aColumnNeverShrinksBelowTheFloor() {
    // Once there are enough columns the floored total exceeds the pane's
    // width on its own — `select *` against a twenty-column table is an
    // ordinary query, not a corner case. The floor is what makes horizontal
    // scrolling the escape hatch rather than a fallback: the cap divides
    // the width fairly when the columns fit, and the ScrollView carries
    // them when the floor says they cannot.
    let widths = paneColumnLayout(
        columns: (0..<20).map { "c\($0)" }, overrides: [:], availableWidth: 400,
        horizontalSpacing: 16)
    #expect(widths.allSatisfy { $0 == 60 })
}

@Test func overridesAloneCanExceedTheWidthAndAreStillHonoured() {
    // An operator who dragged a column to 400pt meant it. The surface
    // scrolls horizontally; it does not silently undo the drag.
    let widths = paneColumnLayout(
        columns: ["a", "b"], overrides: ["a": 400, "b": 400], availableWidth: 300,
        horizontalSpacing: 16)
    #expect(widths == [400, 400])
}

@Test func noColumnsIsNoWidths() {
    #expect(paneColumnLayout(
        columns: [], overrides: [:], availableWidth: 400, horizontalSpacing: 16).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — `cannot find 'paneColumnLayout' in scope`.

- [ ] **Step 3: Add the arithmetic**

In `app/Sources/WakilKit/App/WindowModel.swift`, beside `paneColumnWidth`:

```swift
/// Each column's width, in order, given which ones the operator has
/// resized.
///
/// Overridden columns keep exactly what they were dragged to; the rest
/// divide whatever horizontal space is left, floored by `paneColumnWidth`'s
/// own minimum. The two rules do not compete: the division is what shares
/// the width fairly when the columns fit, and the floor plus the surface's
/// horizontal `ScrollView` is what happens when they cannot.
public func paneColumnLayout(
    columns: [String], overrides: [String: Double], availableWidth: Double,
    horizontalSpacing: Double, minimum: Double = 60
) -> [Double] {
    guard !columns.isEmpty else { return [] }
    let spacing = horizontalSpacing * Double(columns.count - 1)
    let overridden = columns.filter { overrides[$0] != nil }
    let overriddenTotal = overridden.reduce(0.0) { $0 + (overrides[$1] ?? 0) }
    let free = columns.count - overridden.count
    let remaining = availableWidth - spacing - overriddenTotal
    let each = free > 0 ? max(minimum, remaining / Double(free)) : 0
    return columns.map { overrides[$0] ?? each }
}
```

- [ ] **Step 4: Run the test**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Write the view**

Create `app/Sources/WakilApp/DataSurface.swift`:

```swift
import AppKit
import WakilKit
import SwiftUI

/// `design-language.md` §8's data surface: the one place the aesthetic
/// yields to utility.
///
/// **Why this construction and not another**, measured in
/// `docs/wakil/phase-2c-i-probe.md`:
///
/// - A `LazyVStack` of rows at `.frame(height:)` measures **exactly**
///   23.0000 and 40.0000 pt/row, which is what makes §8's dense row
///   reachable at all. `Table`'s `NSTableView` floors at 24pt (2b-ii), and
///   a `Grid` builds every row it is given — 5,000 rows cost a 5.3-second
///   first layout and missed the 8.33ms frame budget on 300 steps of 300.
///   This construction builds ~1,086 row bodies for 50,000 rows and misses
///   the budget once in 300.
/// - **No `Section`.** A `Section`'s pinned header is the obvious way to
///   get a header that scrolls horizontally with its columns, and it
///   under-reports the scroll view's document height by 2.8% — pinned or
///   not, so pinning is not the cause. That is a scrollbar of the wrong
///   size and a `pane_scroll_to_row` that lands in the wrong place. The
///   header is therefore drawn *above* the `ScrollView`, measured exact,
///   and its horizontal offset is shared by hand through
///   `HorizontalOffsetKey` below.
struct DataSurface: View {
    let table: PaneTable
    let pane: Pane
    /// Dispatches an action by name. Every interaction in this view goes
    /// through it — there is no path from a click to state that does not
    /// journal, which is Invariant 2 in one sentence.
    let dispatch: (String, JSONValue) -> Void

    @State private var headerOffset: CGFloat = 0

    private var rowHeight: Double { pane.density.rowHeight }

    var body: some View {
        GeometryReader { geometry in
            let widths = paneColumnLayout(
                columns: table.columns.map(\.name), overrides: pane.columnWidths,
                availableWidth: geometry.size.width, horizontalSpacing: 16)
            VStack(alignment: .leading, spacing: 0) {
                header(widths)
                rows(widths)
                footer()
            }
        }
    }

    // MARK: - Header

    /// Outside the vertical `ScrollView` — see the type's doc comment — and
    /// offset horizontally to match the rows beneath it.
    private func header(_ widths: [Double]) -> some View {
        HStack(spacing: 16) {
            ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                headerCell(column)
                    .frame(width: widths.indices.contains(index) ? widths[index] : 60,
                           alignment: .leading)
            }
        }
        .offset(x: headerOffset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.bottom, 6)
    }

    private func headerCell(_ column: PaneColumn) -> some View {
        HStack(spacing: 5) {
            // §6 micro-label, the same treatment a pane's title gets.
            Text(column.name.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
            if let type = column.type {
                // §8's column type annotation. Dimmer than the name: it is
                // context for the name, not a second label competing with it.
                Text(type.lowercased())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.25))
            }
            if table.sort?.column == column.name {
                Text(table.sort?.direction == .descending ? "▼" : "▲")
                    .font(.system(size: 7))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityAddTraits(.isHeader)
        .contentShape(Rectangle())
        .onTapGesture { sort(column.name) }
    }

    /// A click cycles ascending → descending → unsorted on the clicked
    /// column, and starts ascending on any other. Unsorted is reachable
    /// because a sort is a claim about the data and the operator must be
    /// able to withdraw it.
    private func sort(_ column: String) {
        var params: [String: JSONValue] = ["pane": .string(pane.id)]
        if table.sort?.column == column {
            switch table.sort?.direction {
            case .ascending:
                params["column"] = .string(column)
                params["direction"] = .string("desc")
            case .descending:
                break  // omitting `column` clears the sort
            case nil:
                params["column"] = .string(column)
            }
        } else {
            params["column"] = .string(column)
            params["direction"] = .string("asc")
        }
        dispatch("pane_sort", .object(params))
    }

    // MARK: - Rows

    private func rows(_ widths: [Double]) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(table.rows) { row in
                        rowView(row, widths)
                            .id(row.id)
                    }
                }
                .background(
                    // Reports the content's horizontal position so the
                    // header above can follow it. `.global` rather than a
                    // named space because the header is outside this
                    // ScrollView's own space entirely.
                    GeometryReader { inner in
                        Color.clear.preference(
                            key: HorizontalOffsetKey.self,
                            value: inner.frame(in: .global).minX)
                    })
            }
            .onPreferenceChange(HorizontalOffsetKey.self) { minX in
                // Relative to wherever the content started, so a pane that
                // is not at the window's left edge does not offset its
                // header by the pane's own position.
                headerOffset = minX - (contentOrigin ?? minX)
                if contentOrigin == nil { contentOrigin = minX }
            }
            .onChange(of: table.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
                // Cleared so the same row can be asked for twice. This is
                // why scrollTarget is runtime state in PaneStore and not
                // persisted: it describes a scroll about to happen.
                dispatch("pane_scroll_clear", .object(["pane": .string(pane.id)]))
            }
        }
    }

    @State private var contentOrigin: CGFloat?

    private func rowView(_ row: PaneRow, _ widths: [Double]) -> some View {
        HStack(spacing: 16) {
            ForEach(table.columns.indices, id: \.self) { index in
                cellView(row, index)
                    .frame(width: widths.indices.contains(index) ? widths[index] : 60,
                           alignment: .leading)
            }
        }
        // Exact in both directions, which is the whole reason this is not a
        // Table. Never padding: padding can only grow a row past a floor.
        .frame(height: rowHeight)
        .background(rowBackground(row))
        .overlay(alignment: .leading) {
            // §8 permits exactly one luminous element inside a data
            // surface, and this is it: the anchor row's left edge.
            if table.selection.anchorRow == row.id {
                Rectangle()
                    .fill(Color(red: 0.62, green: 0.51, blue: 1.0))
                    .frame(width: 2)
                    .shadow(color: Color(red: 0.62, green: 0.51, blue: 1.0).opacity(0.7), radius: 4)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(row))
        .accessibilityAddTraits(table.selection.rows.contains(row.id) ? [.isSelected] : [])
    }

    /// Selected rows that are not the anchor get a lifted background rather
    /// than a glow — §8's single-luminous-element rule holds, and the
    /// amendment recording this treatment is in the spec's §7.
    private func rowBackground(_ row: PaneRow) -> some View {
        Group {
            if table.selection.rows.contains(row.id) {
                Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.06)
            } else {
                Color.clear
            }
        }
    }

    private func cellView(_ row: PaneRow, _ index: Int) -> some View {
        Group {
            if index >= row.cells.count {
                // Cells shorter than the column list are not padded; the
                // view draws only where the index exists.
                Text("")
            } else if row.cells[index].isNull {
                // §8's explicit null rendering. Before 2c-i this drew as ""
                // and a real NULL was indistinguishable from an empty
                // string — which is the confusion the rule exists against.
                Text("NULL")
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30))
            } else if isChip(row.cells[index], column: index) {
                chip(row.cells[index].text)
            } else {
                Text(row.cells[index].text)
                    .help(row.cells[index].text)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        .contentShape(Rectangle())
        .onTapGesture { select(row: row.id, column: index) }
    }

    /// §8's status chips, scoped to what can be identified honestly: a
    /// boolean. Guessing which *string* columns are "statuses" would put a
    /// chip on a `name` column that happens to read "active", which is a
    /// worse failure than no chip at all.
    private func isChip(_ cell: PaneCell, column index: Int) -> Bool {
        cell.text == "true" || cell.text == "false"
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color(red: 0.910, green: 0.925, blue: 0.965)
                    .opacity(text == "true" ? 0.14 : 0.06)))
    }

    /// Shift extends the selection from the anchor; command toggles one
    /// row; a plain click starts a new selection at that cell.
    private func select(row: Int, column index: Int) {
        let name = table.columns.indices.contains(index) ? table.columns[index].name : ""
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = table.selection.anchorRow {
            let span = Set(min(anchor, row)...max(anchor, row))
            dispatch("pane_select_rows", .object([
                "pane": .string(pane.id),
                "rows": .array(span.sorted().map { .number(Double($0)) }),
                "anchor": .number(Double(anchor)),
                "column": .string(name),
            ]))
        } else if modifiers.contains(.command) {
            var rows = table.selection.rows
            if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
            dispatch("pane_select_rows", .object([
                "pane": .string(pane.id),
                "rows": .array(rows.sorted().map { .number(Double($0)) }),
                "anchor": .number(Double(row)),
                "column": .string(name),
            ]))
        } else {
            dispatch("pane_select_cell", .object([
                "pane": .string(pane.id), "row": .number(Double(row)), "column": .string(name),
            ]))
        }
    }

    private func rowAccessibilityLabel(_ row: PaneRow) -> String {
        zip(table.columns, row.cells)
            .map { "\($0.name): \($1.isNull ? "null" : $1.text)" }
            .joined(separator: ", ")
    }

    // MARK: - Footer

    /// §8's footer: row count, timing, and every claim the surface is
    /// making about the rows above it.
    private func footer() -> some View {
        HStack(spacing: 10) {
            Text("\(table.rows.count) rows")
            if table.millis > 0 { Text("\(table.millis) ms") }
            if table.truncated {
                // The same honesty `read_pane`'s `truncated` gives the
                // agent: a human counting the rows on screen reaches the
                // same wrong answer an agent counting `rowCount` would.
                Text("more matched than were returned")
            }
            if let sort = table.sort, table.truncated {
                // Spec §6. The grid sorted the rows it holds, not the
                // table — and on a truncated result those are different
                // answers.
                Text("sorted by \(sort.column) within the \(table.rows.count) returned")
            }
            if table.columnTypesInferred {
                Text("types inferred from values")
            }
            Spacer()
            Text("read-only")
        }
        .font(.system(size: 9, weight: .medium))
        .tracking(1.0)
        .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.35))
        .padding(.top, 6)
    }
}

/// Carries the row content's horizontal position out of the `ScrollView`
/// so the header outside it can follow. This is the hand-built half of what
/// a pinned `Section` header would have given for free, and the price of
/// the 2.8% document-height error that construction costs.
private struct HorizontalOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
```

**One known risk, with its fallback named.** Mutating `@State` from
`onPreferenceChange` can fail Swift 6's strict concurrency checking depending on the
SDK, because the closure is `@Sendable` on some and not others. If it does not compile
as written, do **not** silence it with `nonisolated(unsafe)` or `@preconcurrency`.
Replace the preference-key mechanism with a small `NSViewRepresentable` that walks up to
the enclosing `NSScrollView` and publishes `contentView.bounds.origin.x` through a
`@State` binding on the main actor — the same approach `VoidView` already uses to reach
AppKit from SwiftUI in this codebase. The header's offset is the only thing that depends
on it, so the swap is local to `rows(_:)` and `header(_:)`.

`pane_scroll_clear` is referenced above and does not exist. Add it to
`PaneContentActions.swift` in this task — a sixth action, `.control`, one param `pane`,
calling `panes.setScrollTarget(paneId:row: nil)` — with a test in
`PaneContentActionsTests.swift` mirroring `scrollToRowIsRecordedAsATarget`. Update
Task 7's count in the header comment if you touch it.

- [ ] **Step 6: Build and test**

Run: `make app-build && make app-test`
Expected: PASS. `DataSurface` is not yet drawn anywhere — Task 11 places it.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilApp/DataSurface.swift app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/Panes/PaneContentActions.swift app/Tests/WakilKitTests/
git commit -m "The data surface: exact rows, lazy, honest footer, one luminous edge"
```

---
## Task 11: The surface moves into the pane, and the window's table is deleted

**This is the task 2c-i exists for.** Everything before it was groundwork.

**Files:**
- Modify: `app/Sources/WakilApp/Canvas.swift:246-292` (`paneView`)
- Modify: `app/Sources/WakilApp/WakilWindow.swift:520-700` — delete the window-level
  table, its `if model.columns.isEmpty` branch, the `GeometryReader`/`Grid`/`ScrollView`
  construction, the `.frame(maxHeight: 360)` and the `model.truncated` line
- Test: manual, plus `make app-build`

**Interfaces:**
- Consumes: `DataSurface` (Task 10), `WindowModel.table(_:)` (Task 9).
- Produces: nothing new.

- [ ] **Step 1: Draw the surface inside the pane**

In `Canvas.swift`, replace `paneView`'s body — keep the slab treatment exactly (§2's
near-opaque fill, half-pixel luminous edge, drop shadow) and replace only what is
*inside* it:

```swift
    /// One pane: its title, and what it is showing.
    ///
    /// **The frame numerals are gone.** They were on screen because in 2b-i
    /// they were the only evidence a drag or a resize committed at all — a
    /// pane had no contents of its own. It has contents now, and a pane
    /// that moves while showing rows is evidence enough.
    ///
    /// §2's slab treatment is unchanged: a near-opaque rounded surface, a
    /// half-pixel luminous edge in place of a border, and a drop shadow.
    /// §1's second register — the atmosphere stops at the slab's edge,
    /// never bleeding through — matters more now than it did, because a
    /// data surface with the void showing through it is unreadable at
    /// exactly the moment it matters (§8).
    private func paneView(_ model: WindowModel, _ pane: Pane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pane.title.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.7)
                .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))

            let table = model.table(pane.id)
            if table.columns.isEmpty {
                // "No rows" is the honest thing to say for a pane nothing
                // has queried yet — with no columns there is nothing to lay
                // out, and an empty grid would look like an empty result.
                Text("no rows")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30))
                Spacer()
            } else {
                DataSurface(table: table, pane: pane) { name, params in
                    Task { await model.dispatchFromSurface(name, params) }
                }
            }

            HStack {
                Spacer()
                Text("resize")
                    .gesture(resizeGesture(model, pane))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.055, green: 0.063, blue: 0.098))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
    }
```

`dispatchFromSurface` does not exist yet; add it to `WindowModel` in this task. It must
**not** be a second dispatch path — `WindowModel` already has `private func dispatch(_
name: JSONValue…)` at line 1635, which sets `origin: .ui`, passes the live `environment`
the gate judges, and handles `ActionError.needsConfirmation` by parking the mutation.
Wrap that one:

```swift
    /// What a click inside a data surface goes through.
    ///
    /// Thin on purpose: it is `dispatch` plus a refresh, in the same shape
    /// `dispatchLayout` wraps it for pane geometry. A second dispatch path
    /// would be a second place `origin`, the environment and the
    /// confirmation parking could drift — and Invariant 2 is exactly the
    /// claim that there is only one.
    public func dispatchFromSurface(_ name: String, _ params: JSONValue) async {
        await dispatch(name, params)
        await refreshPanes()
    }
```

If `pane_set_column_width` needs the layout persisted afterwards, route that one name
through `dispatchLayout` instead — it already writes the layout file on a real change.

- [ ] **Step 2: Delete the window-level table**

In `WakilWindow.swift`, remove everything from the comment beginning *"The pane. Bound
to `WindowModel.rows`…"* through the `if model.truncated { … }` block inclusive —
including the `EmptyView()` marker Task 9 left. The `VStack` that held it keeps the
canvas, the message field, the status line and the notes.

Leave a short comment where it was:

```swift
        // The data surface lives in the pane now, not here. Until 2c-i this
        // was a window-level table bound to one flattened columns/rows pair
        // read under a paneId that defaulted to "db" and was never anything
        // else — which is why "every pane is dual-driven" was unreachable in
        // that shape. See Canvas.paneView.
```

- [ ] **Step 3: Build**

Run: `make app-build`
Expected: build succeeds with no reference to `model.columns`, `model.rows`,
`model.truncated` or `model.paneId` anywhere.

Verify: `grep -rn "model\.columns\|model\.rows\|model\.truncated\|model\.paneId" app/Sources`
Expected: no output.

- [ ] **Step 4: Run it and look**

Run: `make app-bundle && open app/.build/Wakil.app` (or whatever path
`scripts/make-app-bundle.sh` reports).

Check by hand, and record what you see:
1. A `db` pane opens with "no rows".
2. Running a query through the message field fills that pane, not the window.
3. ⌘⇧D switches density and the rows visibly change height.
4. Clicking a cell draws a luminous left edge on its row.
5. Shift-clicking another row lifts the background of every row between.
6. Clicking a header sorts, and clicking it twice more clears the sort.
7. A `NULL` reads as a dimmed `NULL`, not as blank.

- [ ] **Step 5: Run the full suite**

Run: `make test && make app-test && make vet`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp/Canvas.swift app/Sources/WakilApp/WakilWindow.swift app/Sources/WakilKit/App/WindowModel.swift
git commit -m "The data surface is drawn by the pane, and the window's table is gone"
```

---

## Task 12: Sort is honoured, and the footer is honest about how

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — sorting applied in `refreshPanes`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

Spec §6: the grid records intent, the pane's owner honours it. 2c-i has no re-querying
owner yet — 2c-ii's DB pane is that — so what ships here is the client-side branch and
the hook the re-query plugs into.

**Interfaces:**
- Consumes: `PaneTable.sort`, `PaneTable.rows`, `PaneCell`.
- Produces: `sortedRows(_ rows: [PaneRow], by: PaneSort?, columns: [PaneColumn]) -> [PaneRow]`
  in `WakilKit`.

- [ ] **Step 1: Write the failing test**

Add to `app/Tests/WakilKitTests/WindowModelTests.swift`:

```swift
private func rows(_ values: [[JSONValue]]) -> [PaneRow] {
    values.enumerated().map { PaneRow(id: $0.offset, cells: $0.element.map(PaneCell.init)) }
}

@Test func sortingReindexesRowsToTheirDisplayedPosition() {
    let columns = [PaneColumn(name: "name", type: "TEXT")]
    let sorted = sortedRows(
        rows([[.string("c")], [.string("a")], [.string("b")]]),
        by: PaneSort(column: "name", direction: .ascending), columns: columns)
    #expect(sorted.map { $0.cells[0].text } == ["a", "b", "c"])
    // Re-identified 0,1,2 in the NEW order. Every row index in this
    // codebase — read_pane's, pane_select_cell's, pane_scroll_to_row's —
    // indexes what is displayed, so a sorted row keeps its displayed
    // position as its id or the agent and the operator mean different rows
    // by the same number.
    #expect(sorted.map(\.id) == [0, 1, 2])
}

@Test func numericColumnsSortNumericallyNotLexically() {
    let columns = [PaneColumn(name: "id", type: "INTEGER")]
    let sorted = sortedRows(
        rows([[.number(10)], [.number(9)], [.number(100)]]),
        by: PaneSort(column: "id", direction: .ascending), columns: columns)
    // Lexical would give 10, 100, 9 — which looks like a bug to anyone
    // reading it and is one.
    #expect(sorted.map { $0.cells[0].text } == ["9", "10", "100"])
}

@Test func nullsSortLastInBothDirections() {
    // A NULL is the absence of a value, so it has no place in an ordering
    // of values. Putting it at the end both ways means a sort never buries
    // the rows the operator asked to see under the rows that have nothing.
    let columns = [PaneColumn(name: "name", type: "TEXT")]
    let source = rows([[.string("b")], [.null], [.string("a")]])
    let ascending = sortedRows(
        source, by: PaneSort(column: "name", direction: .ascending), columns: columns)
    let descending = sortedRows(
        source, by: PaneSort(column: "name", direction: .descending), columns: columns)
    #expect(ascending.last!.cells[0].isNull)
    #expect(descending.last!.cells[0].isNull)
}

@Test func noSortAndAnUnknownColumnBothLeaveTheOrderAlone() {
    let columns = [PaneColumn(name: "name", type: "TEXT")]
    let source = rows([[.string("c")], [.string("a")]])
    #expect(sortedRows(source, by: nil, columns: columns).map { $0.cells[0].text } == ["c", "a"])
    // An unknown column is not an error to throw in a projection that has
    // to be total — it is a sort with nothing to sort by.
    #expect(sortedRows(
        source, by: PaneSort(column: "nope", direction: .ascending),
        columns: columns).map { $0.cells[0].text } == ["c", "a"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test`
Expected: FAIL — `cannot find 'sortedRows' in scope`.

- [ ] **Step 3: Implement**

In `app/Sources/WakilKit/App/WindowModel.swift`:

```swift
/// Orders `rows` by `sort`, re-identifying each to its new displayed
/// position.
///
/// **This is the client-side branch of spec §6, and it is not the whole
/// answer.** A pane that can re-query should re-query with an `ORDER BY`,
/// because sorting 500 rows of a 50,000-row table orders what is on screen
/// and *looks* like it ordered the table — the same class of dishonesty
/// `truncated` exists to prevent, one layer up. 2c-i has no re-querying
/// owner yet; `DataSurface`'s footer says "sorted within the N returned"
/// whenever the result is truncated, and 2c-ii replaces this call for the
/// DB pane rather than extending it.
///
/// On an untruncated result this *is* correct and is the right answer.
public func sortedRows(
    _ rows: [PaneRow], by sort: PaneSort?, columns: [PaneColumn]
) -> [PaneRow] {
    guard let sort, let index = columns.firstIndex(where: { $0.name == sort.column }) else {
        return rows
    }
    let ordered = rows.sorted { left, right in
        let l = index < left.cells.count ? left.cells[index] : PaneCell(.null)
        let r = index < right.cells.count ? right.cells[index] : PaneCell(.null)
        // Nulls last in BOTH directions, so they are never the first thing
        // a sort shows.
        if l.isNull != r.isNull { return !l.isNull }
        if l.isNull && r.isNull { return false }
        // Numerically when both sides are numbers: lexically, 100 sorts
        // before 9, which reads as a bug because it is one.
        if let ln = Double(l.text), let rn = Double(r.text), ln != rn {
            return sort.direction == .ascending ? ln < rn : ln > rn
        }
        let comparison = l.text.localizedStandardCompare(r.text)
        return sort.direction == .ascending
            ? comparison == .orderedAscending
            : comparison == .orderedDescending
    }
    // Re-identified to displayed position — see the test.
    return ordered.enumerated().map { PaneRow(id: $0.offset, cells: $0.element.cells) }
}
```

- [ ] **Step 4: Apply it in the projection**

In `WindowModel.refreshPanes()`, sort each table as it is read:

```swift
    public func refreshPanes() async {
        var next: [String: PaneTable] = [:]
        for id in await panes.paneIds() {
            let table = paneTable(from: await panes.snapshot(paneId: id))
            next[id] = table.sorted()
        }
        tables = next
    }
```

and add to `PaneTable`:

```swift
    /// This table with `sortedRows` applied. Separate from `paneTable(from:)`
    /// so that the projection stays a pure read of the snapshot and the
    /// ordering stays a thing a pane's owner can replace (spec §6).
    public func sorted() -> PaneTable {
        PaneTable(
            columns: columns, columnTypesInferred: columnTypesInferred,
            rows: sortedRows(rows, by: sort, columns: columns), millis: millis,
            truncated: truncated, selection: selection, sort: sort, scrollTarget: scrollTarget)
    }
```

- [ ] **Step 5: Run the tests**

Run: `make app-test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "Sort is honoured client-side, and the footer says when that is partial"
```

---
## Task 13: `make bench-surface` — the measurement that would have caught 2b-ii's regression

**Files:**
- Create: `app/Sources/WakilApp/SurfaceBench.swift`
- Modify: `app/Sources/WakilApp/main.swift` — a `--bench-surface` flag beside `--capture`
- Modify: `Makefile` — a `bench-surface` target

**Why a target and not a test.** The 2b-ii spec §11 gives the reasoning for the
captures and it applies here: an assertion on a wall-clock number fails on a toolchain
update and gets disabled within a week, and a disabled test is worse than an honest
runbook line. This exists to be *run and read*. What makes it worth having anyway is
that `Grid` shipped in 2b-ii missing the frame budget on 300 steps out of 300 at 5,000
rows, and nothing anywhere would have said so.

**Interfaces:**
- Consumes: `DataSurface`, `PaneTable`, `PaneCell`, `Pane`.
- Produces: `runSurfaceBench(rows:)`.

- [ ] **Step 1: Write the bench**

Create `app/Sources/WakilApp/SurfaceBench.swift`:

```swift
import AppKit
import QuartzCore
import WakilKit
import SwiftUI

/// Hosts `DataSurface` offscreen over a synthetic result and prints what it
/// costs: how many row bodies SwiftUI builds, and how long a scroll step
/// takes against the 8.33ms a 120fps frame allows.
///
/// **Not a gate.** See the task note and the 2b-ii spec §11: a wall-clock
/// assertion fails on a toolchain update and gets disabled. This is read,
/// not asserted on. What it protects against is the failure it was written
/// after — `Grid` shipping in 2b-ii over budget on every step at 5,000
/// rows, with nothing anywhere to say so.
@MainActor
func runSurfaceBench(rows rowCount: Int) {
    let columns = (0..<8).map { PaneColumn(name: "column_\($0)", type: "TEXT") }
    let paneRows = (0..<rowCount).map { i in
        PaneRow(id: i, cells: (0..<8).map { c in PaneCell(.string("r\(i)c\(c)")) })
    }
    let table = PaneTable(
        columns: columns, columnTypesInferred: false, rows: paneRows, millis: 12,
        truncated: false, selection: .empty, sort: nil, scrollTarget: nil)
    var pane = Pane(
        id: "bench", kind: "db", title: "Bench",
        frame: PaneFrame(x: 0, y: 0, width: 900, height: 400))
    pane.density = .dense

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    let hosting = NSHostingView(
        rootView: DataSurface(table: table, pane: pane, dispatch: { _, _ in }))
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
    window.contentView = hosting
    // Offscreen, but ordered in: SwiftUI neither lays out nor runs onAppear
    // for a window that was never brought on screen, so a bench that skips
    // this measures nothing and reports zero.
    window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
    window.orderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))

    guard let scroll = firstScrollView(hosting) else {
        print("bench-surface: no NSScrollView found — the construction changed shape")
        return
    }
    let documentHeight = Double(scroll.documentView?.frame.height ?? 0)
    let expected = Double(rowCount) * pane.density.rowHeight
    print(String(format: "  rows              %d at %.0fpt", rowCount, pane.density.rowHeight))
    print(String(format: "  document height   %.0f pt (exact would be %.0f, %+.2f%%)",
                 documentHeight, expected, (documentHeight - expected) / expected * 100))

    // 10pt per step — how a scroll actually moves. A teleport across a
    // fraction of the document makes every row new and measures the worst
    // case rather than the case the budget is about.
    var times: [Double] = []
    for i in 1...300 {
        let t = CFAbsoluteTimeGetCurrent()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 10 * Double(i)))
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()
        times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
    }
    times.sort()
    let over = times.filter { $0 > 8.33 }.count
    print(String(format: "  scroll step       median %.3f ms   p95 %.3f ms   worst %.3f ms",
                 times[times.count / 2], times[Int(Double(times.count) * 0.95)], times.last!))
    print(String(format: "  over 8.33ms       %d / 300   %@", over,
                 over > 15 ? "<-- OVER BUDGET" : "ok"))
    window.orderOut(nil)
}

@MainActor
private func firstScrollView(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for sub in view.subviews {
        if let scroll = firstScrollView(sub) { return scroll }
    }
    return nil
}
```

- [ ] **Step 2: Add the flag**

In `app/Sources/WakilApp/main.swift`, beside the existing `--capture` / `--capture-motion`
handling, add a `--bench-surface` case that reads an optional row count (default 50000)
and calls `runSurfaceBench(rows:)`, then exits — matching exactly how `--capture`
short-circuits the normal app launch in that file.

- [ ] **Step 3: Add the target**

In the `Makefile`, after `captures-motion`, and add `bench-surface` to the `.PHONY` list:

```make
# Hosts the data surface offscreen over 50,000 rows and prints what a scroll
# step costs against the 8.33ms budget. Read, not asserted on — the 2b-ii
# spec §11 gives the reasoning, and a wall-clock assertion would be disabled
# within a week of a toolchain update.
#
# It exists because the Grid this replaced shipped in 2b-ii missing the
# budget on 300 steps out of 300 at 5,000 rows, with a 5.3-second first
# layout, and nothing anywhere said so. See docs/wakil/phase-2c-i-probe.md.
bench-surface: app-build
	cd app && swift run -c release WakilApp --bench-surface 50000
```

- [ ] **Step 4: Run it**

Run: `make bench-surface`
Expected, on an M3 (the probe's numbers, which this should land near):
- document height exact to 0.00%
- median well under 1 ms, p95 under 2 ms
- over-8.33ms count in the low single digits out of 300

If the over-budget count is high or the document height is off by percent, **stop and
investigate before continuing** — either a `Section` crept back in or the rows stopped
being fixed-height, and both are the specific failures this target exists to name.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/SurfaceBench.swift app/Sources/WakilApp/main.swift Makefile
git commit -m "make bench-surface: what the data surface costs, measured not assumed"
```

---

## Task 14: The document amendments, and closing the phase out

**Files:**
- Modify: `docs/wakil/design-language.md` §8 and §13
- Modify: `docs/wakil/north-star.md` §8 — 2c's row
- Create: `docs/wakil/phase-2c-i-acceptance.md`

- [ ] **Step 1: Amend §13**

In `docs/wakil/design-language.md` §13, replace the bullet:

> - **Data-grid virtualization.** Grids render only visible rows. On very dense tabular
>   data, prefer AppKit over SwiftUI for the grid specifically — SwiftUI list perf is
>   the known weak spot.

with:

```markdown
- **Data-grid virtualization.** Grids render only visible rows. **Amended 2026-09-11**
  — this bullet used to end "on very dense tabular data, prefer AppKit over SwiftUI for
  the grid specifically". That advice predated the two measurements that contradict it,
  and as written it could not be followed without breaking §8: 2b-ii measured that
  `NSTableView` floors its row height at the platform default of 24pt, putting §8's 23pt
  dense row out of reach inside AppKit's table entirely. `phase-2c-i-probe.md` then
  measured the alternative in release, on 50,000 rows: a SwiftUI `LazyVStack` of
  fixed-height rows holds **23.0000 pt/row exactly**, builds **1,086** row bodies for
  50,000 rows, and scrolls at a **0.574ms median** with **1 step in 300** over the
  8.33ms budget. The `Grid` it replaced missed the budget on **300 steps out of 300** at
  5,000 rows. So: a virtualizing SwiftUI `LazyVStack`, fixed row heights, and **no
  `Section`** — a `Section` under-reports the scroll view's document height by 2.8%,
  pinned or not, which is a scrollbar of the wrong size and a scroll-to-row that lands
  in the wrong place.
```

- [ ] **Step 2: Amend §8**

In §8, replace the line *"The only luminous element permitted inside a data surface is
the active row's left edge."* with:

```markdown
The only luminous element permitted inside a data surface is the **anchor** row's left
edge. **Amended 2026-09-11** by 2c-i, which needed a word for "the selected row the
selection is anchored on" once selection stopped being a single row: the anchor is a
(row, column) pair, because §11 has the API client pane consuming *values* from other
panes and a value lives in a cell. Other selected rows get a **lifted background** —
opaque, non-luminous — so that this rule stays literally true rather than being
contradicted by the code.

**Sort is intent, not action, and the footer says which it got.** A click on a header of
a 500-row result truncated from 50,000 that sorts client-side orders the rows on screen
and *looks* like it ordered the table — the same class of dishonesty `truncated` exists
to prevent, one layer up. A pane that can re-query re-queries; one that cannot sorts
what it holds and the footer reads "sorted by X within the N returned".

**A `NULL` is drawn as a dimmed `NULL`**, never as an empty cell — an empty string is
also an empty cell, and until 2c-i the two were indistinguishable on screen.
```

- [ ] **Step 3: Record the split in `north-star.md`**

In §8, after 2c's row in the 2a–2d table, add the five-way split table from the spec's
§0, in the same form 2b's and 2b-iii's splits are already recorded, with a sentence
giving the reason (four independent subsystems are not one spec) and the date
2026-09-11.

Also add, to the paragraph beginning *"2c inherits two things from 2b-ii it did not ask
for"*, a closing note:

```markdown
**Both are discharged by 2c-i, and a third thing was found.** The selection model exists
(an anchor cell plus a row set), and the `Grid` is replaced by a virtualizing
`LazyVStack` that also recovers column resizing and header-driven sort — the two
options 2b-ii recorded as foreclosed. The third: that `Grid` was **missing the 120fps
budget on every frame at 5,000 rows**, with a 5.3-second first layout, which nothing had
measured. `docs/wakil/phase-2c-i-probe.md`.
```

- [ ] **Step 4: Write the acceptance runbook**

Create `docs/wakil/phase-2c-i-acceptance.md` in the form of
`docs/wakil/phase-2b-vi-acceptance.md` — read that file first and match its structure.
The checks, each with a stated expected result and a place to record what was seen:

1. **A pane draws rows.** Open a `db` pane, run a query, see the rows *in the pane*.
2. **Both densities.** ⌘⇧D; rows visibly change height; the change persists across a
   relaunch.
3. **Types and NULL.** A table with a nullable column shows the type in the header and
   a dimmed `NULL` in the cell, distinguishable from an empty string in an adjacent row.
4. **Selection, both ways.** Click a cell — luminous left edge. Then, from the agent,
   *"select rows 3 through 8 in the db pane"* — the same treatment, with the anchor's
   edge on one row and lifted backgrounds on the rest. `read_pane` reports both.
5. **Sort, and its honesty.** Sort a truncated result; the footer says "within the N
   returned". Sort an untruncated one; it does not.
6. **Column width.** Drag a header edge; relaunch; the width is still there.
7. **Scroll to row.** Ask the agent to scroll to a row past 10,000 in a large result and
   confirm it lands on that row, not near it.
8. **The journal.** Every one of checks 4–7 has an entry, with `origin` distinguishing
   the pointer from the agent and nothing else differing.
9. **`make bench-surface`** run and its output pasted in.

- [ ] **Step 5: Full suite and commit**

Run: `make test && make vet && make fmt && make app-test && make bench-surface`
Expected: all pass.

```bash
git add docs/wakil/design-language.md docs/wakil/north-star.md docs/wakil/phase-2c-i-acceptance.md
git commit -m "2c-i's amendments: §13 stops preferring AppKit, §8 gains the anchor"
```

- [ ] **Step 6: Hand back**

2c-i is **not met** until the runbook in `docs/wakil/phase-2c-i-acceptance.md` is walked
by the operator. Do not mark it met in `north-star.md`. Report: what was built, the
`bench-surface` output, anything in §10 of the spec that moved, and the runbook waiting
to be walked.

---

## Self-Review

**Spec coverage.** §1 (structure inverts) → Tasks 9, 11. §2 (LazyVStack) → Task 10.
§2.1 (no `Section`) → Task 10 and the Global Constraints. §3.1 (types from the driver) →
Tasks 1, 2. §3.2 (`PaneStore` carries them) → Task 4. §3.3 (`NULL`) → Tasks 3, 10.
§4 (anchor + row set) → Tasks 3, 7, 10. §5 (the actions) → Task 7, plus
`pane_scroll_clear` added in Task 10. §6 (sort ownership) → Tasks 7, 12. §7 (document
amendments) → Task 14. §8 (testing) → Tasks 3–12, with the `make` target in Task 13.
§9 (exit criterion) → Task 11's manual checks and Task 14's runbook. §10 (open items) →
carried into the acceptance document, not closed.

**Two things the plan adds that the spec did not name**, both discovered while writing
it and both worth keeping: `pane_scroll_clear` (a scroll target that is never cleared
can only be asked for once) and `PaneStore.paneIds()` (a model that holds a table per
pane needs to know which panes have contents). Neither changes a decision.

**Task 5's `db_run_query` pane parameter** is a spec gap the plan closes: §1 names the
hardcoded `paneId: "db"` as part of the problem but §3 never says what replaces it.

**Type consistency.** `PaneCell(_:)`, `PaneColumn(name:type:)`, `PaneSelection(anchorRow:anchorColumn:rows:)`,
`PaneSort(column:direction:)`, `PaneStore.setRows(paneId:columns:columnTypes:columnTypesInferred:rows:millis:truncated:)`,
`PaneTable(columns:columnTypesInferred:rows:millis:truncated:selection:sort:scrollTarget:)`,
`paneColumnLayout(columns:overrides:availableWidth:horizontalSpacing:minimum:)` and
`sortedRows(_:by:columns:)` are each used in later tasks exactly as defined in the task
that introduces them.

**One known rough edge, left deliberately.** Task 9 Step 5 leaves `WakilWindow.swift`
holding an `EmptyView()` marker that Task 11 removes. That is a two-task window in which
the app builds and shows no table at all. The alternative — folding Tasks 9 and 11
together — makes one task that rewrites the model, the canvas and the window at once,
which is worse to review and worse to revert.
