# 2c-ii walk defects — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the eleven fixable defects 2c-ii's acceptance walk found, so that a pane never
says something untrue about what it is pointed at.

**Architecture:** Three layers, in dependency order. **Go first** — the multi-term sort and
the `SHOW TABLES` recognition both move SQL knowledge toward the driver, where the read-only
gate already lives, and Swift consumes them as JSON. **Then `WakilKit`** — every decision
that can be tested lands here, because `WakilApp` is an executable and a test target cannot
import one. **Then `WakilApp`** — views only, verified at the window.

**Tech Stack:** Go 1.27 (`CGO_ENABLED=0`), Swift 6.3 / SwiftUI, Swift Testing
(`@Test`/`#expect`), MCP over JSON-RPC/stdio.

**Spec:** `docs/superpowers/specs/2026-09-13-phase-2c-ii-walk-defects-design.md`

**Walk:** `docs/wakil/phase-2c-ii-acceptance.md` §5 — the twelve defects, with evidence.

## Global Constraints

- **No SQL parsing in Swift.** Ever. Tasks 1 and 2 exist to keep it that way.
- **The read-only gate judges the operator's raw text, first**, before any wrap Wakil
  composes. Task 1 adds a second reader of that text and must normalise identically.
- **`WakilApp` has no test target and cannot have one.** A decision that needs a test goes
  in `WakilKit`. Tasks 13–16 touch views only and carry no unit tests by design.
- **New JSON fields that report a fact carry no `omitempty`.** `false`/`null` is the answer
  that matters, and a reader must not have to tell it from "this build is too old to say".
  Follows `Rows.Pageable`.
- **Every task ends green on its own suite** (`make test` for Go, `make app-test` for
  Swift) and commits.
- **`make app-test` must be run on a quiet machine.** The DB action suite spawns a real
  subprocess per test and is `@Suite(.serialized)` for that reason (2c-ii ruling R8). A
  timeout on `initialize` is that, not your change — but confirm by re-running before
  concluding it.
- **Commit messages describe the behaviour, not the defect id.** `D7` means nothing to
  someone reading `git log` in a year; "a refusal leaves the statement to be corrected"
  does.

---

## File Structure

**Go — `internal/wakilcore/`**
- `readonly.go` — gains `SQLReadListsTables`. Sibling of `SQLReadIsPageable`; same
  normalisation, different verb.
- `dbdriver.go` — `QuerySpec.Sort` widens to a slice; `Rows.ListsTables` added;
  `Conn.ReadTable`'s signature widens.
- `sqlconn.go` — `pageWrap` emits multi-term `ORDER BY`; `Read` sets `ListsTables`.
- `driver_mongo.go` — `appendSortStage` emits one ordered `$sort`.

**Go — `cmd/wakil-db/`**
- `main.go` — `queryArg`'s two scalar sort fields become one `Sort []sortArg`, on both
  `query` and `read_table`.

**Swift — `WakilKit` (all testable)**
- `Panes/PaneStore.swift` — `Contents.failure`, `setFailure`, `snapshot`.
- `Panes/PaneContents.swift` — `PaneSort` unchanged as a type; its *uses* become arrays.
- `Panes/PaneFetch.swift` — `sort: [PaneSort]`, `sorted(by:)` appends,
  `shouldAdoptSubject(refused:)`, `offersDrill(subject:listsTables:)`.
- `App/WindowModel.swift` — `PaneTable.failure`/`.listsTables`, failure recording at three
  call sites, `setEnvironment`, `runMutation(pane:)`, `confirmationDescription`,
  `parkAndAwait` fallback.
- `Gate/WriteGate.swift` — production on either side.
- `Registry/StandardActions.swift` — `pane_sort` appends; `refetchPane` passes the array.
- `Harness/AgentInstructions.swift` — **new**; the system prompt.
- `Harness/ClaudeCodeCLIHarness.swift` — `--append-system-prompt`.

**Swift — `WakilApp` (views, no tests)**
- `DBPane.swift` — failure in place of rows; refusal keeps the draft.
- `DataSurface.swift` — page resets scroll; an arrow per sorted column; drill clears the
  scroller; footer truncates.

---

## Task Order and Why

Tasks 1–3 are Go and have no Swift dependency; they can land first and be verified by
`make test` alone. Task 3 **breaks the Swift build** (the tool argument shape changes), so
Task 10 — Swift's half of the same change — must follow it closely; do not leave the tree
broken across a review boundary longer than that.

Tasks 4–5 are D12 and must precede Task 6 (D11), because D11's fix makes failures *common*
and a fix that produces three panes claiming to be empty is worse than the bug it replaced.

Tasks 12–16 depend on nothing and could run any time; they are last because they are the
ones the walk verifies rather than the suite.

---

## Task 1: `SHOW TABLES` is recognised where SQL knowledge lives (D2, Go half)

**Files:**
- Modify: `internal/wakilcore/readonly.go` — add `SQLReadListsTables` beside
  `SQLReadIsPageable` (currently line 693)
- Modify: `internal/wakilcore/dbdriver.go` — add `Rows.ListsTables`
- Modify: `internal/wakilcore/sqlconn.go:140` — `Read` sets it
- Test: `internal/wakilcore/readonly_test.go`, `internal/wakilcore/sqlconn_test.go`

**Interfaces:**
- Produces: `func SQLReadListsTables(sql string) bool`; `Rows.ListsTables bool`
  (json `listsTables`). Task 11 consumes `listsTables` from the JSON.

- [ ] **Step 1: Write the failing test**

In `internal/wakilcore/readonly_test.go`:

```go
// SQLReadListsTables must normalise exactly as AssertSQLReadOnly does, or a
// statement the gate accepted would be judged here on different text. The
// comment and trailing-semicolon cases below are the ones that prove it:
// both are stripped by the gate and must be stripped here too.
func TestSQLReadListsTables(t *testing.T) {
	for _, tc := range []struct {
		name string
		sql  string
		want bool
	}{
		{"bare", "SHOW TABLES", true},
		{"lowercase", "show tables", true},
		{"trailing semicolon", "SHOW TABLES;", true},
		{"leading comment", "-- what is here\nSHOW TABLES", true},
		{"surrounding space", "   SHOW TABLES  \n", true},
		// FULL returns a second column, so the first cell is still a table
		// name but the result is a different shape than the drill assumes.
		{"full", "SHOW FULL TABLES", false},
		// Names a database this connection's drill would not open.
		{"from another database", "SHOW TABLES FROM other", false},
		{"in another database", "SHOW TABLES IN other", false},
		{"like", "SHOW TABLES LIKE 'a%'", false},
		{"columns", "SHOW COLUMNS FROM events", false},
		{"select", "SELECT * FROM events", false},
		{"select named tables", "SELECT name FROM tables", false},
		{"empty", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := wakilcore.SQLReadListsTables(tc.sql); got != tc.want {
				t.Fatalf("SQLReadListsTables(%q) = %v, want %v", tc.sql, got, tc.want)
			}
		})
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `go test ./internal/wakilcore/ -run TestSQLReadListsTables -v`
Expected: FAIL — `undefined: wakilcore.SQLReadListsTables`

- [ ] **Step 3: Implement it**

In `internal/wakilcore/readonly.go`, immediately after `SQLReadIsPageable`:

```go
// SQLReadListsTables reports whether sql is a bare table listing whose rows
// name tables in this connection's own database — which is what lets a
// caller offer a drill on the result without inferring anything from the
// shape of the rows.
//
// It normalises exactly as SQLReadIsPageable and AssertSQLReadOnly do, and
// for the same reason: a statement the gate accepted must not be judged
// here on different text.
//
// Deliberately narrow. SHOW FULL TABLES returns a second column, and
// SHOW TABLES FROM other names a database the drill would not open — both
// would make a drill that opens the wrong thing, which is a worse failure
// than a drill that is absent. A narrow rule that is always right beats a
// broad one that is usually right.
//
// Like SQLReadIsPageable, this decides nothing about safety and must never
// be used to. AssertSQLReadOnly is the only gate.
func SQLReadListsTables(sql string) bool {
	clean := strings.TrimSpace(stripSQLComments(sql))
	trimmed := strings.TrimRight(clean, "; \t\n")
	upper := strings.ToUpper(strings.TrimSpace(trimmed))
	return upper == "SHOW TABLES"
}
```

The equality test — not `HasPrefix` — is what refuses `FULL`, `FROM`, `IN` and `LIKE`
without naming any of them.

- [ ] **Step 4: Run it and watch it pass**

Run: `go test ./internal/wakilcore/ -run TestSQLReadListsTables -v`
Expected: PASS, all 13 subtests.

- [ ] **Step 5: Carry it onto `Rows`**

In `internal/wakilcore/dbdriver.go`, beside `Pageable`:

```go
	// ListsTables is whether this result's rows name tables in this
	// connection's database, so a caller can offer a drill without
	// inferring one from the shape of the rows. True for SHOW TABLES;
	// false for everything else, Mongo included.
	//
	// No `omitempty`, for Pageable's reason: false is the answer that
	// matters, and a reader must not have to tell "these are not tables"
	// apart from "this server is too old to say".
	ListsTables bool `json:"listsTables"`
```

In `internal/wakilcore/sqlconn.go`, in `Read`, beside `out.Pageable = pageable`:

```go
	// Judged on the operator's RAW text, never on the wrapped statement —
	// the wrap is Wakil's, and a gate or a claim made about Wakil's own
	// composition is a claim about the wrong thing. Same rule as the
	// read-only gate above.
	out.ListsTables = SQLReadListsTables(spec.Raw)
```

- [ ] **Step 6: Test that the flag reaches a result**

In `internal/wakilcore/sqlconn_test.go`, using the existing sqlite fixture helper:

```go
// A SHOW TABLES cannot run on sqlite, so the flag is asserted on the two
// statements that CAN, in both directions — the point is that Read sets it
// from the raw text rather than leaving the zero value everywhere.
func TestReadReportsListsTablesFromTheRawText(t *testing.T) {
	conn := openTestSQLite(t)
	rows, err := conn.Read(context.Background(), wakilcore.QuerySpec{Raw: "SELECT 1"}, 10)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if rows.ListsTables {
		t.Fatal("a SELECT must not claim to list tables")
	}
}
```

Replace `openTestSQLite` with whatever the file's existing fixture helper is called — read
the top of `sqlconn_test.go` first and match it; do not add a second fixture.

- [ ] **Step 7: Green and commit**

```bash
go test ./internal/wakilcore/ && go vet ./...
git add internal/wakilcore/
git commit -m "A table listing says so, where SQL knowledge already lives"
```

---

## Task 2: a sort is a list of terms, not one (D5, driver half)

**Files:**
- Modify: `internal/wakilcore/dbdriver.go` — `QuerySpec.Sort`, `Conn.ReadTable` signature
- Modify: `internal/wakilcore/sqlconn.go` — `Read`, `ReadTable`, `pageWrap`
- Modify: `internal/wakilcore/driver_mongo.go` — `Read`, `ReadTable`, `appendSortStage`
- Test: `internal/wakilcore/sqlconn_test.go`, `internal/wakilcore/driver_mongo_test.go`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `QuerySpec.Sort []QuerySort`;
  `Conn.ReadTable(ctx, name string, limit, offset int, sort []QuerySort) (Rows, error)`.
  Task 3 exposes these over MCP; Task 10 mirrors them in Swift.

- [ ] **Step 1: Write the failing tests**

In `internal/wakilcore/sqlconn_test.go`:

```go
// Two terms, in the order asked for. The single-term case was already
// correct; what could not be expressed at all was "and then by".
func TestPageWrapEmitsEverySortTermInOrder(t *testing.T) {
	conn := openTestSQLite(t)
	rows, err := conn.Read(context.Background(), wakilcore.QuerySpec{
		Raw: "SELECT id, kind FROM events",
		Sort: []wakilcore.QuerySort{
			{Column: "kind", Descending: false},
			{Column: "id", Descending: true},
		},
	}, 10)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	// Seeded rows are (1,'b'), (2,'a'), (3,'a'). Ordered by kind ASC then
	// id DESC that is 3,2,1 — and ONLY the second term distinguishes 3
	// from 2, so a wrap that dropped it would still pass a weaker test.
	var got []int64
	for _, row := range rows.Rows {
		got = append(got, row[0].(int64))
	}
	want := []int64{3, 2, 1}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
}

// An empty slice is "no sort" and must behave exactly as nil did — no
// ORDER BY, and no wrap forced on a statement that cannot survive one.
func TestAnEmptySortIsNoSort(t *testing.T) {
	conn := openTestSQLite(t)
	rows, err := conn.Read(context.Background(), wakilcore.QuerySpec{
		Raw:  "SELECT 1",
		Sort: []wakilcore.QuerySort{},
	}, 10)
	if err != nil {
		t.Fatalf("an empty sort must not force a wrap: %v", err)
	}
	if len(rows.Rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows.Rows))
	}
}
```

Seed the fixture with those three rows if it does not already have distinguishable ones.
**The seed matters**: the second term must be the only thing that orders two rows, or the
test passes with a one-term implementation.

In `internal/wakilcore/driver_mongo_test.go`:

```go
// The $sort stage must be a bson.D, not a map. A Go map has undefined
// iteration order, so a two-key map would sort by whichever column the
// runtime happened to marshal first — differently between runs of the same
// query. This asserts the TYPE, because the ordering bug it prevents is
// not reliably reproducible.
func TestSortStageIsOrdered(t *testing.T) {
	pipeline := appendSortStage(nil, []QuerySort{
		{Column: "kind"},
		{Column: "id", Descending: true},
	})
	if len(pipeline) != 1 {
		t.Fatalf("stages = %d, want 1", len(pipeline))
	}
	doc, ok := pipeline[0]["$sort"].(bson.D)
	if !ok {
		t.Fatalf("$sort is %T, want bson.D — a map would sort in random order", pipeline[0]["$sort"])
	}
	want := bson.D{{Key: "kind", Value: 1}, {Key: "id", Value: -1}}
	if !reflect.DeepEqual(doc, want) {
		t.Fatalf("$sort = %v, want %v", doc, want)
	}
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/wakilcore/ -run 'TestPageWrap|TestAnEmptySort|TestSortStageIsOrdered' -v`
Expected: FAIL to compile — `cannot use []wakilcore.QuerySort as *wakilcore.QuerySort`.
That compile failure IS the red state for this task; do not work around it.

- [ ] **Step 3: Widen the type**

`internal/wakilcore/dbdriver.go`:

```go
type QuerySpec struct {
	Raw string
	// Offset is how many rows to skip before the first one returned.
	Offset int
	// Sort, when non-empty, is pushed into the statement as an ORDER BY
	// whose terms appear in exactly this order — index 0 is the primary
	// key, index 1 breaks its ties, and so on.
	//
	// A slice rather than a pointer to one term: an operator who sorts by
	// a second column has not replaced the first, they have refined it,
	// and a driver told only about the second would silently discard the
	// refinement it was asked for. Nil and empty both mean "no sort";
	// callers must not have to tell them apart.
	Sort []QuerySort
}
```

and on the interface:

```go
	ReadTable(ctx context.Context, name string, limit, offset int, sort []QuerySort) (Rows, error)
```

- [ ] **Step 4: Widen `sqlconn.go`**

`needsWrap` becomes `offset > 0 || len(spec.Sort) > 0`. `pageWrap`:

```go
func (c *sqlConn) pageWrap(raw string, sort []QuerySort, limit, offset int) string {
	inner := strings.TrimRight(strings.TrimSpace(raw), "; \t\n")
	var b strings.Builder
	b.WriteString("SELECT * FROM (")
	b.WriteString(inner)
	b.WriteString("\n) AS wakil_page")
	for i, term := range sort {
		if i == 0 {
			b.WriteString(" ORDER BY ")
		} else {
			b.WriteString(", ")
		}
		b.WriteString(c.quoteIdent(term.Column))
		if term.Descending {
			b.WriteString(" DESC")
		} else {
			b.WriteString(" ASC")
		}
	}
	fmt.Fprintf(&b, " LIMIT %d OFFSET %d", limit+1, offset)
	return b.String()
}
```

Every term still goes through `c.quoteIdent` — that is the sole guard against a column name
from a header click or an agent, and the loop must not become the place it is forgotten.
The direction remains one of two literals, never interpolated.

- [ ] **Step 5: Widen `driver_mongo.go`**

```go
// appendSortStage returns a copy of pipeline with a trailing {"$sort": ...}
// naming every term in order.
//
// The $sort value is a bson.D — an ORDERED slice — and not a map. A Go map
// has undefined iteration order, so a two-key map would be marshalled with
// whichever column the runtime chose first, making the sort precedence vary
// between runs of the same query. With one key that was harmless, which is
// why it was correct until a second term became expressible.
func appendSortStage(pipeline []map[string]any, sort []QuerySort) []map[string]any {
	if len(sort) == 0 {
		return pipeline
	}
	doc := make(bson.D, 0, len(sort))
	for _, term := range sort {
		dir := 1
		if term.Descending {
			dir = -1
		}
		doc = append(doc, bson.E{Key: term.Column, Value: dir})
	}
	return append(append([]map[string]any{}, pipeline...),
		map[string]any{"$sort": doc})
}
```

The two `findOpts.SetSort(bson.D{{Key: spec.Sort.Column, Value: dir}})` call sites (around
lines 154 and 226) build the same `bson.D` by the same loop. Factor the loop into one
unexported `sortDocument(sort []QuerySort) bson.D` and call it from all three, so the
ordering guarantee lives in one place.

- [ ] **Step 6: Run every wakilcore test**

Run: `go test ./internal/wakilcore/ -v`
Expected: PASS. Existing single-sort tests must still pass unchanged — if one needs editing
beyond `&QuerySort{...}` → `[]QuerySort{{...}}`, stop and say so; that is a behaviour change
this task did not intend.

- [ ] **Step 7: Commit**

```bash
go test ./... && go vet ./...
git add internal/wakilcore/
git commit -m "A sort is a list of terms, and Mongo's is ordered"
```

---

## Task 3: the sort crosses the wire as a list (D5, MCP half)

**Files:**
- Modify: `cmd/wakil-db/main.go` — `queryArg`, the `query` tool, the `read_table` tool
- Test: `cmd/wakil-db/main_test.go`

**Interfaces:**
- Consumes: `QuerySpec.Sort []QuerySort` and `Conn.ReadTable(..., sort []QuerySort)`
  from Task 2.
- Produces: the `sort` argument shape Task 10's Swift side sends:
  `"sort": [{"column": "kind", "descending": false}, ...]`.

**This task breaks the seam, not the build** (pre-flight ruling F1). Swift sends JSON keys
(`StandardActions.swift:1197`), so nothing stops compiling and `make app-test` stays green
against its stub harness. What breaks is behaviour: a real `wakil-db` silently drops a sort
it no longer has a field for, visible only in `make test-live`. **Task 10 runs immediately
after this one** to close that window.

- [ ] **Step 1: Write the failing test**

In `cmd/wakil-db/main_test.go`, beside the existing `read_table` tests:

```go
// The wire carries every term, in order. Two terms is the case that could
// not be expressed before and the only one that proves the array is read
// as an array rather than as its first element.
func TestReadTableAcceptsMultipleSortTerms(t *testing.T) {
	client := connectedClient(t)
	result := callTool(t, client, "read_table", map[string]any{
		"table": "events",
		"sort": []map[string]any{
			{"column": "kind", "descending": false},
			{"column": "id", "descending": true},
		},
	})
	ids := idColumn(t, result)
	want := []int64{3, 2, 1}
	if !reflect.DeepEqual(ids, want) {
		t.Fatalf("ids = %v, want %v", ids, want)
	}
}
```

Match `connectedClient`, `callTool` and the id-extraction helper to whatever the file already
uses (2c-ii ruling R7 put real fixtures here) — read the file's existing tests first and
reuse them; add `idColumn` only if no equivalent exists.

- [ ] **Step 2: Run it and watch it fail**

Run: `go test ./cmd/wakil-db/ -run TestReadTableAcceptsMultipleSortTerms -v`
Expected: FAIL — the `sort` argument is ignored, so the ids come back in insertion order.

- [ ] **Step 3: Change the argument shape**

In `cmd/wakil-db/main.go`:

```go
// sortArg is one ORDER BY term as it crosses the wire.
type sortArg struct {
	Column     string `json:"column" jsonschema:"the column to order by"`
	Descending bool   `json:"descending,omitempty" jsonschema:"order descending instead of ascending"`
}

func (s sortArg) spec() wakilcore.QuerySort {
	return wakilcore.QuerySort{Column: s.Column, Descending: s.Descending}
}

func sortSpecs(args []sortArg) []wakilcore.QuerySort {
	if len(args) == 0 {
		return nil
	}
	out := make([]wakilcore.QuerySort, 0, len(args))
	for _, a := range args {
		out = append(out, a.spec())
	}
	return out
}
```

`queryArg`'s `SortColumn string` and `SortDescending bool` are **removed** and replaced by:

```go
	// Sort is the ORDER BY, in precedence order: index 0 is the primary
	// key and later terms break its ties. Pushed into the statement rather
	// than applied to the rows afterwards, so a sort over a truncated
	// result orders everything that matches.
	Sort []sortArg `json:"sort,omitempty" jsonschema:"order the result by these columns, in precedence order"`
```

Removed rather than deprecated: nothing outside this repo calls these tools, `wakil-db` and
the app ship from one `make build`, and two ways to express a sort would raise a precedence
question with no right answer.

Both call sites become `Sort: sortSpecs(args.Sort)`.

- [ ] **Step 4: Run it and watch it pass**

Run: `go test ./cmd/wakil-db/ -v`
Expected: PASS.

- [ ] **Step 5: Confirm the tool schema advertises the new shape**

Run: `go test ./cmd/wakil-db/ -run 'Schema|ToolList' -v`
If a test asserts the advertised schema of `query` or `read_table`, it will fail with the
old field names — update it to the new ones. If no such test exists, do not add one; the
schema is generated from the struct tags and asserting it would test the library.

- [ ] **Step 6: Commit**

```bash
go test ./... && go vet ./...
git add cmd/wakil-db/
git commit -m "The sort crosses the wire as a list, in precedence order"
```

---

## Task 4: a pane knows its fetch failed (D12, store half)

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` — `Contents.failure`, `setFailure`,
  `setRows` clears it, `snapshot` emits it
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `PaneTable.failure`,
  `paneTable(from:)` around line 231
- Test: `app/Tests/WakilKitTests/PaneStoreTests.swift`

**Interfaces:**
- Produces: `PaneStore.setFailure(paneId: String, message: String)`;
  `PaneStore.failure(paneId: String) -> String?`; `PaneTable.failure: String?`;
  snapshot key `failure` (string or null, **always present**). Task 5 calls `setFailure`;
  Task 13 draws `PaneTable.failure`.

- [ ] **Step 1: Write the failing tests**

```swift
/// D12, the fifth cause of "rows returned, nothing on screen". A pane that
/// could not fetch and a pane that fetched nothing are different facts, and
/// before this they shared one empty `columns` array.
@Test func aFailureIsRememberedWithoutErasingTheLastGoodResult() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["integer"],
        columnTypesInferred: false, rows: [[.number(1)]], millis: 3,
        truncated: false, pageable: true, offset: 0, sort: [])

    await store.setFailure(paneId: "db-1", message: "no such database: docs")

    #expect(await store.failure(paneId: "db-1") == "no such database: docs")
    // The rows survive. A pane showing its last good result under a line
    // saying the refetch failed is honest; a pane blanked by a transient
    // failure has thrown away the only thing it knew.
    #expect(await store.rowCount(paneId: "db-1") == 1)
}

/// A result arriving IS the success signal — there is no path where rows
/// and a live failure are both true.
@Test func rowsClearAPreviousFailure() async {
    let store = PaneStore()
    await store.setFailure(paneId: "db-1", message: "connection refused")
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["integer"],
        columnTypesInferred: false, rows: [[.number(1)]], millis: 3,
        truncated: false, pageable: true, offset: 0, sort: [])
    #expect(await store.failure(paneId: "db-1") == nil)
}

/// Emitted unconditionally, for `pageable`'s reason: a reader — the agent
/// included — must not have to tell "did not fail" from "this build is too
/// old to say".
@Test func theSnapshotAlwaysCarriesFailure() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["integer"],
        columnTypesInferred: false, rows: [], millis: 0,
        truncated: false, pageable: true, offset: 0, sort: [])
    guard case .object(let object)? = await store.snapshot(paneId: "db-1") else {
        Issue.record("no snapshot"); return
    }
    #expect(object["failure"] == .null)
}
```

`rowCount(paneId:)` may not exist — if it does not, assert on
`store.snapshot(paneId:)`'s `rows` array instead rather than adding an accessor for a test.

Note `sort: []` — **Task 10 has already run** (pre-flight ruling F1 reordered it ahead of
this task), so `setRows` takes `[PaneSort]` and `sort: []` is correct exactly as written.

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | grep -A4 'aFailureIsRemembered'`
Expected: compile failure — `value of type 'PaneStore' has no member 'setFailure'`.

- [ ] **Step 3: Implement**

In `Contents`, beside `scrollTarget`:

```swift
        /// Why this pane's last fetch did not produce rows, or `nil` if it
        /// succeeded.
        ///
        /// **Beside `rows` rather than replacing them.** A pane showing its
        /// last good result under a line saying the refetch failed is
        /// honest; a pane blanked by a transient failure has thrown away
        /// the only thing it knew.
        var failure: String?
```

`setRows` sets `contents.failure = nil` — placed beside the existing assignments, not at the
end, so a later edit that returns early cannot skip it.

```swift
    /// Records that this pane's last fetch failed, without disturbing the
    /// rows, offset or sort it already had.
    ///
    /// **D12.** `DBPane` drew "no rows" for this state because nothing
    /// distinguished it from an empty result — the fetch's failure was
    /// known, journalled, and then discarded by every caller with `_ =`.
    public func setFailure(paneId: String, message: String) {
        var contents = panes[paneId] ?? Contents()
        contents.failure = message
        byProject[project, default: [:]][paneId] = contents
    }

    public func failure(paneId: String) -> String? {
        panes[paneId]?.failure
    }
```

Match the existing mutation helpers' shape for reading and writing `byProject` — read
`setRows` and copy its idiom rather than inventing a second one.

In `snapshot`, beside `"scrollTarget"`:

```swift
            "failure": contents.failure.map { .string($0) } ?? .null,
```

In `WindowModel`'s `PaneTable`, beside `pageable`:

```swift
    /// Why the last fetch failed, or `nil`. Drawn in place of the rows —
    /// see `DBPane`. Never conflated with an empty result (D12).
    public let failure: String?
```

Add it to `PaneTable.init`, to `PaneTable.empty` (as `nil`), and to `paneTable(from:)`:

```swift
    var failure: String?
    if case .string(let message)? = object["failure"] { failure = message }
```

`SurfaceBench.swift` constructs a `PaneTable` too and will stop compiling — pass `nil`.

- [ ] **Step 4: Run and watch it pass**

Run: `make app-test`
Expected: PASS. Re-run once if a `db_*` test times out on `initialize` (see Global
Constraints).

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/ app/Sources/WakilApp/SurfaceBench.swift app/Tests/
git commit -m "A pane can tell 'I found nothing' from 'I could not look'"
```

---

## Task 5: every fetch that fails says so, on its own pane (D12, wiring)

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `restorePaneContents` (~1493),
  `refetchPane(id:)` (~1386), `pagePane(id:to:)` (~1380)
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `PaneStore.setFailure(paneId:message:)` from Task 4.

- [ ] **Step 1: Write the failing test**

```swift
/// The walked failure: reopening on `production`, `db_refetch` returned an
/// error for two panes and both drew "no rows". Each pane must carry its
/// OWN failure — a message about pane B drawn under pane A is the same
/// class of lie in a smaller font, which is the fix Task 14 of 2c-ii
/// already had to make once for the query line's refusals.
@Test func aFailedRestoreMarksEachPaneSeparately() async throws {
    let model = try await modelWithTwoDBPanes()   // existing fixture
    await model.restorePaneContents()

    #expect(await model.paneTable("db-1").failure != nil)
    #expect(await model.paneTable("db-2").failure != nil)
    #expect(await model.paneTable("db-1").failure != model.paneTable("db-2").failure
            || true)  // see note
}
```

**Note on the third expectation:** two panes failing the same way legitimately produce the
same message. Assert *presence* on each pane, not difference. Delete the third `#expect`
and replace it with an assertion that a pane whose refetch **succeeded** has `failure ==
nil` in the same run — that is what proves the failure is per-pane rather than global.

Build the fixture so one pane's subject resolves and the other's does not; the existing
`DBActionHarness` fixtures already register a `wakil-db` stub whose behaviour you can key on
the table name. Read `WindowModelTests.swift`'s existing fixtures before writing a new one.

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | grep -A6 aFailedRestoreMarks`
Expected: FAIL — `failure` is `nil` on both panes.

- [ ] **Step 3: Implement, at all three call sites**

```swift
    public func restorePaneContents() async {
        for pane in layoutSnapshot.panes where pane.kind == "db" && pane.fetch != nil {
            // D12. The result was discarded with `_ =` here, so a refetch
            // that failed left the pane indistinguishable from an empty
            // one. `status` carries the message `dispatch` just wrote; it
            // is read per pane because the loop overwrites it, which is
            // exactly why one window-scoped message was never enough.
            if await dispatch("db_refetch", .object(["pane": .string(pane.id)])) == nil {
                await panes.setFailure(paneId: pane.id, message: status)
            }
        }
        await refreshPanes()
    }

    public func refetchPane(id: String) async {
        if await dispatch("db_refetch", .object(["pane": .string(id)])) == nil {
            await panes.setFailure(paneId: id, message: status)
        }
        await refreshPanes()
        await refreshLayout()
    }

    public func pagePane(id: String, to: String) async {
        if await dispatch("db_page", .object(["pane": .string(id), "to": .string(to)])) == nil {
            await panes.setFailure(paneId: id, message: status)
        }
        await refreshPanes()
        await refreshLayout()
    }
```

**`status` and not a fabricated sentence.** `dispatch` has just set it to
`"\(name): \(error)"`, which names the action and the engine's own words. Wakil must not
paraphrase an error it did not generate.

- [ ] **Step 4: Run and watch it pass**

Run: `make app-test`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/
git commit -m "A refetch that failed marks the pane it failed for"
```

---

## Task 6: an environment switch is a relaunch into that environment (D11)

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:1347` — `setEnvironment`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `restorePaneContents()` (existing) and Task 5's failure recording, which is what
  makes the panes that cannot resolve say so rather than claiming to be empty.

**Task 5 must land first.** Without it this task turns three lying panes into three panes
claiming to be empty, which is worse than the bug it replaces.

- [ ] **Step 1: Write the failing test**

```swift
/// The walked failure, seen live: with the banner reading
/// `environment: production`, three panes showed rows from `staging` —
/// including a Mongo collection `production` does not have — and went on
/// showing them until the app was quit.
///
/// The persistence boundary refuses to write rows to disk because
/// redrawing yesterday's rows would show a database state that may no
/// longer exist. An environment switch guarantees exactly that, and was
/// the one path that did not refetch.
@Test func switchingEnvironmentRefetchesEveryPane() async throws {
    let model = try await modelWithOneDBPane()
    await model.runQuery("SELECT 1", database: "core", pane: "db-1")
    let before = await harness.refetchCount

    await model.setEnvironment("production")

    #expect(await harness.refetchCount > before)
}
```

Use the test harness's existing call-recording mechanism — `DBActionHarness` already records
tool calls; read it and assert on `db_refetch` appearing after the switch rather than adding
a counter.

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | grep -A6 switchingEnvironmentRefetches`
Expected: FAIL — no refetch is issued.

- [ ] **Step 3: Implement**

```swift
    public func setEnvironment(_ name: String) async {
        guard await dispatch("ctx_set_environment", .object(["name": .string(name)])) != nil
        else { return }
        await refreshContext()
        // D11. The panes on screen describe the environment we just left.
        // This is the relaunch path, and a switch must leave the canvas
        // exactly as reopening the app in the new environment would — the
        // same argument that refuses rows a place on disk, applied to a
        // change that guarantees they describe a different database.
        await restorePaneContents()
    }
```

The `if` becomes a `guard`: a refused switch (the gate in Task 7 makes these common) must
not refetch, because the environment did not change.

- [ ] **Step 4: Run and watch it pass**

Run: `make app-test`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/
git commit -m "Switching environment leaves the canvas where reopening there would"
```

---

## Task 7: production on either side of an agent's switch (D10)

**Files:**
- Modify: `app/Sources/WakilKit/Gate/WriteGate.swift:74`
- Create: `confirmationDescription` in `app/Sources/WakilKit/App/WindowModel.swift`
  (file-scope function, not a method — it must be reachable from a test)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:2358` — `parkAndAwait`
- Test: `app/Tests/WakilKitTests/WriteGateTests.swift`,
  `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Produces: `func confirmationDescription(action: String, params: JSONValue) -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
/// D10, and a recurrence: `ActionKind`'s own doc comment records 2a's
/// acceptance run finding "the agent re-pointing the active context
/// unasked", and `.control` exists because of it. The gate built then
/// guards one direction.
///
/// Entering production silently arms the next mutation. LEAVING production
/// silently invalidates everything the operator believes the window is
/// pointed at — and they read that banner, so the belief is Wakil's fault.
@Test func anAgentLeavingProductionIsGated() {
    #expect(writeGate(environment: "production", kind: .control,
                      origin: .agent, targetEnvironment: "staging") == .gate)
}

@Test func anAgentEnteringProductionIsStillGated() {
    #expect(writeGate(environment: "staging", kind: .control,
                      origin: .agent, targetEnvironment: "production") == .gate)
}

/// The operator's own switches are untouched, in both directions.
@Test func theOperatorMayLeaveProductionFreely() {
    #expect(writeGate(environment: "production", kind: .control,
                      origin: .ui, targetEnvironment: "staging") == .allow)
}

/// An agent moving between two non-production environments is nobody's
/// emergency.
@Test func anAgentMovingBetweenNonProductionEnvironmentsIsAllowed() {
    #expect(writeGate(environment: "staging", kind: .control,
                      origin: .agent, targetEnvironment: "dev") == .allow)
}

/// A `.control` action with no target — pane_move, ctx_set_project — must
/// not become gated merely because production is active. Moving a pane is
/// not a context switch.
@Test func aControlActionWithNoTargetIsAllowedInProduction() {
    #expect(writeGate(environment: "production", kind: .control,
                      origin: .agent, targetEnvironment: nil) == .allow)
}
```

**That last test is the one that constrains the implementation.** The naive fix — gate
whenever the active environment is production — would block an agent from moving a pane, and
`.control` exists precisely so that it cannot.

- [ ] **Step 2: Run and watch the first one fail**

Run: `make app-test 2>&1 | grep -A4 anAgentLeavingProduction`
Expected: FAIL — `.allow` where `.gate` is wanted. The other four already pass; they are
there to stop the fix breaking them.

- [ ] **Step 3: Implement**

```swift
    case .control:
        // D10. Production on EITHER side, and only for an action that
        // names a target at all — `targetEnvironment == nil` is a pane
        // move or a project switch, and `.control` exists so those are
        // never blocked by the environment.
        //
        // Entering production silently arms the next mutation. Leaving it
        // silently invalidates every belief the operator holds about the
        // window: they read a banner saying production, and every read,
        // proposal and confirmation after that point is judged against an
        // environment they did not choose.
        guard origin == .agent, targetEnvironment != nil,
              isProduction(targetEnvironment) || isProduction(environment)
        else { return .allow }
        return .gate
```

- [ ] **Step 4: Give the plane something to show**

`parkAndAwait` refuses anything without a `statement`, so a gated environment switch dies
with *"no statement to confirm — nothing ran"*. **This is live today** for the
into-production case; Step 3 only makes it reachable more often.

At file scope in `WindowModel.swift`:

```swift
/// What the confirmation plane shows for a gated action that carries no
/// `statement` of its own.
///
/// **A `switch` over known action names, not string-building over
/// arbitrary params.** An action that gains a gate later must state its own
/// sentence; inheriting a generic one would put a machine-shaped
/// description in front of a human being asked to approve it.
///
/// Returns `nil` for anything else, which preserves `parkAndAwait`'s
/// existing refusal for an action that genuinely has nothing to show.
public func confirmationDescription(action: String, params: JSONValue) -> String? {
    switch action {
    case "ctx_set_environment":
        guard case .object(let object) = params,
              case .string(let name)? = object["name"] else { return nil }
        return "switch the active environment to \(name)"
    default:
        return nil
    }
}
```

and in `parkAndAwait`, replacing the `guard`:

```swift
        guard let statement = stringParam(params, "statement").flatMap({ $0.isEmpty ? nil : $0 })
                ?? confirmationDescription(action: name, params: params)
        else {
            status = "\(name): no statement to confirm — nothing ran"
            return nil
        }
```

`affectsEveryRow` is `false` for a context switch — `mutationAffectsEveryRow` reads SQL and
a context switch is not SQL. Pass `false` explicitly when the statement came from
`confirmationDescription`, rather than letting a sentence be scanned for `WHERE`.

- [ ] **Step 5: Test the plane actually rises**

```swift
/// Before this, a gated context switch died at the plane with "no
/// statement to confirm" — the refusal shown to the operator described a
/// mutation, for an action that is not one.
@Test func aGatedEnvironmentSwitchRaisesThePlane() async throws {
    #expect(confirmationDescription(
        action: "ctx_set_environment",
        params: .object(["name": .string("staging")]))
        == "switch the active environment to staging")
    #expect(confirmationDescription(action: "pane_move", params: .object([:])) == nil)
}
```

- [ ] **Step 6: Run and commit**

```bash
make app-test
git add app/Sources/WakilKit/ app/Tests/
git commit -m "An agent that moves the operator out of production is stopped at the plane"
```

---

## Task 8: a confirmed mutation's pane re-reads itself (D8b)

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:1512` — `runMutation`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `runFromQueryLine`'s mutation branch
- Modify: `app/Sources/WakilApp/WakilWindow.swift` — the window's mutation control passes
  `pane: nil`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
/// The walked failure: after `confirm` on
/// `update events set customer_id = 42 where id = 3`, the plane closed,
/// the line correctly snapped back to `events` — and the pane went on
/// showing `customer_id = 7` for `id = 3`, a value the database no longer
/// held. Rows may not outlive the state they describe, least of all
/// across the one action guaranteed to have changed it.
@Test func aConfirmedMutationRefetchesItsPane() async throws {
    let model = try await modelWithOneDBPane()
    await model.runQuery("SELECT * FROM events", database: "events", pane: "db-1")
    let before = await harness.callCount(tool: "read_table")

    await model.runMutation("UPDATE events SET kind = 'x' WHERE id = 1",
                            database: "events", pane: "db-1")

    #expect(await harness.callCount(tool: "read_table") > before)
}

/// A cancelled mutation must NOT refetch. Redrawing the pane for no reason
/// would teach the operator that cancelling does something.
@Test func aCancelledMutationLeavesThePaneAlone() async throws {
    let model = try await modelWithOneDBPane(confirmationAnswer: .cancelled)
    let before = await harness.callCount(tool: "read_table")
    await model.runMutation("UPDATE events SET kind = 'x' WHERE id = 1",
                            database: "events", pane: "db-1")
    #expect(await harness.callCount(tool: "read_table") == before)
}
```

Adapt `callCount(tool:)` to the harness's existing recording API.

- [ ] **Step 2: Run and watch them fail**

Run: `make app-test 2>&1 | grep -A6 aConfirmedMutationRefetches`
Expected: the first FAILs (no refetch), the second PASSes already.

- [ ] **Step 3: Implement**

```swift
    /// Runs one mutation. It will not execute until the operator confirms
    /// it in the plane — see `dispatch`.
    ///
    /// **It does not draw the mutation's output**, which is why this is not
    /// `runQuery`: a mutation returns no rows, and re-reading the pane's
    /// result into the grid would put a fabricated shape on a surface
    /// Invariant 3 promises reflects what is on screen.
    ///
    /// **It does refetch `pane`'s own subject, when one was named (D8b).**
    /// `refetchPane` re-runs `Pane.fetch` — still `events`, not the
    /// UPDATE — so the pane shows the same subject against the state the
    /// mutation just produced. `pane` is `nil` from the window's own
    /// mutation control, which has no pane to speak for.
    ///
    /// **Only when it ran.** `dispatch` returns `nil` for a refusal and for
    /// a cancel alike, and the `guard` is the whole distinction: redrawing
    /// after a cancel would teach the operator that cancelling does
    /// something.
    public func runMutation(_ statement: String, database: String?, pane: String?) async {
        var params: [String: JSONValue] = ["statement": .string(statement)]
        if let database { params["database"] = .string(database) }
        guard await dispatch("db_run_mutation", .object(params)) != nil else { return }
        if let pane, !pane.isEmpty { await refetchPane(id: pane) }
    }
```

Update `runFromQueryLine`'s mutation branch to pass its own `paneId`, and
`WakilWindow.swift`'s call to pass `pane: nil`.

- [ ] **Step 4: Run and commit**

```bash
make app-test
git add app/Sources/WakilKit/ app/Sources/WakilApp/WakilWindow.swift app/Tests/
git commit -m "A confirmed mutation's pane re-reads itself; a cancelled one does not"
```

---

## Task 9: a refusal leaves the statement to be corrected (D7)

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneFetch.swift` — `shouldAdoptSubject`
- Modify: `app/Sources/WakilApp/DBPane.swift` — pass the refusal through
- Test: `app/Tests/WakilKitTests/PaneFetchTests.swift`

**Interfaces:**
- Produces:
  `shouldAdoptSubject(currentText:lastRendered:incoming:refused:) -> Bool` — **a fourth
  parameter with no default**, so every call site is forced to state what it knows. Task 13
  is the only caller.

- [ ] **Step 1: Write the failing tests**

```swift
/// The walked failure: typing `upadte events set customer_id = 42 where
/// id = 3` produced the right refusal and then erased the statement,
/// leaving the operator to retype all of it to fix two characters.
///
/// A refused line is an unsaved edit by another name: the text did not
/// become the pane's subject, and it is the only copy of what they meant.
@Test func aRefusedLineIsNotOverwritten() {
    #expect(shouldAdoptSubject(
        currentText: "upadte events set customer_id = 42 where id = 3",
        lastRendered: "upadte events set customer_id = 42 where id = 3",
        incoming: "events",
        refused: true) == false)
}

/// Without a refusal the existing rule is unchanged: an untouched line
/// follows its pane's subject.
@Test func anUntouchedLineStillFollowsItsSubject() {
    #expect(shouldAdoptSubject(
        currentText: "events", lastRendered: "events",
        incoming: "SELECT * FROM events ORDER BY id", refused: false) == true)
}

/// And an edited line is still protected, refusal or not.
@Test func anEditedLineIsStillProtected() {
    #expect(shouldAdoptSubject(
        currentText: "SELECT * FROM ev", lastRendered: "events",
        incoming: "events", refused: false) == false)
}
```

- [ ] **Step 2: Run and watch the first fail**

Run: `make app-test 2>&1 | grep -A4 aRefusedLineIsNot`
Expected: compile failure — `extra argument 'refused' in call`.

- [ ] **Step 3: Implement**

Add the parameter and the early return, keeping the existing doc comment and adding:

```swift
/// **A refusal counts as an unsaved edit (D7).** The operator's text did
/// not become the pane's subject — it was rejected before it could — so
/// the line still holds the only copy of what they meant. Adopting over it
/// would make them retype a whole statement to fix two characters, at
/// exactly the moment they are least inclined to trust the pane.
///
/// A subsequent successful submit clears the refusal, which restores
/// adoption; no new clearing path is introduced.
public func shouldAdoptSubject(
    currentText: String, lastRendered: String, incoming: String, refused: Bool
) -> Bool {
    if refused { return false }
    return currentText == lastRendered && currentText != incoming
}
```

Keep the existing body's exact comparison — read it and preserve it rather than retyping it
from this plan, in case it differs.

- [ ] **Step 4: Update the one caller**

In `DBPane.swift`'s `onChange`, pass `refused: refusal != nil`.

- [ ] **Step 5: Run and commit**

```bash
make app-test && make app-build
git add app/Sources/ app/Tests/
git commit -m "A refused statement stays in the line to be corrected"
```

---

## Task 10: the sort is a list in Swift too (D5, Swift half)

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneFetch.swift` — `sort: [PaneSort]`, `sorted(by:)`
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` — `setRows(sort:)`,
  `reorder(paneId:sort:)`, `Contents.sort`, `snapshot`
- Modify: `app/Sources/WakilKit/Panes/PaneContents.swift` — the row-ordering function
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `PaneTable.sort`,
  `paneTable(from:)`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — `pane_sort`,
  `refetchPane(paneId:fetch:db:panes:)`, the `db_read_table` argument
- Test: `app/Tests/WakilKitTests/PaneFetchTests.swift`, `PaneStoreTests.swift`

**Interfaces:**
- Consumes: Task 3's wire shape — `"sort": [{"column": …, "descending": …}]`.
- Produces: `PaneFetch.sort: [PaneSort]`;
  `PaneFetch.sorted(by column: String, descending: Bool) -> PaneFetch` (appends);
  `PaneTable.sort: [PaneSort]`. Task 15 draws them.

**This task repairs the build Task 3 broke.** Run `make app-build` first to see the damage;
it is the task list.

- [ ] **Step 1: Write the failing tests**

```swift
/// The walked failure: sorting by one column drew an arrow and changed
/// nothing in the query line; sorting by a SECOND column made the agent
/// fall back to writing `ORDER BY` into the SQL, which put the sort in the
/// line as text and made the arrow vanish. Two defensible behaviours, and
/// no rule an operator could learn.
///
/// The rule is unchanged — the query line shows your subject, the headers
/// show the ordering Wakil applied. What was too small was the type.
@Test func aSecondSortRefinesTheFirstRatherThanReplacingIt() {
    let fetch = PaneFetch(query: .table(database: "events", name: "events"))
        .sorted(by: "kind", descending: false)
        .sorted(by: "id", descending: true)
    #expect(fetch.sort.map(\.column) == ["kind", "id"])
    #expect(fetch.sort.map { $0.direction == .descending } == [false, true])
}

/// A column appears at most once. Clicking a header that already sorts
/// flips it and promotes it, rather than adding a second term for the same
/// column — which would be an ORDER BY whose later term can never apply.
@Test func sortingByAColumnTwiceFlipsItRatherThanDuplicatingIt() {
    let fetch = PaneFetch(query: .table(database: "events", name: "events"))
        .sorted(by: "kind", descending: false)
        .sorted(by: "id", descending: false)
        .sorted(by: "kind", descending: true)
    #expect(fetch.sort.map(\.column) == ["kind", "id"])
    #expect(fetch.sort[0].direction == .descending)
}

/// Offset still resets on any sort change — unchanged from 2c-ii, and the
/// reason check 5 passes: a sort is over the whole result, so page three
/// of the old ordering is meaningless in the new one.
@Test func aSortStillReturnsToTheFirstPage() {
    let fetch = PaneFetch(query: .table(database: "events", name: "events"))
        .page(to: 1000)
        .sorted(by: "id", descending: false)
    #expect(fetch.offset == 0)
}
```

**The second test decides the semantics and must not be softened.** "Sort by kind, then
sort by id, then sort by kind again" is an operator refining, not restarting; `kind`
returning to the front with a flipped direction is what a header click means.

- [ ] **Step 2: Run and watch them fail**

Run: `make app-build`
Expected: many errors, starting at `PaneFetch.sort`. That is this task's red state.

- [ ] **Step 3: Widen `PaneFetch`**

```swift
    /// The pane's sort intent, in precedence order: index 0 is the primary
    /// key and later terms break its ties.
    ///
    /// **An array rather than one optional term (D5).** A second header
    /// click means "and then by this", and a single term could not express
    /// it — so the agent fell back to writing `ORDER BY` into the SQL,
    /// which moved the sort from the headers into the query line and took
    /// the arrow away with it. Empty is "no sort".
    public var sort: [PaneSort]
```

```swift
    /// Makes `column` the primary sort term, removing any existing term for
    /// the same column first, and returns to the first page.
    ///
    /// **Appending rather than replacing is what makes a second header
    /// click mean what the operator means by it.** Removing the column's
    /// own earlier term first keeps each column at most once: a repeated
    /// term is an `ORDER BY` whose later mention can never apply.
    public func sorted(by column: String, descending: Bool) -> PaneFetch {
        var terms = sort.filter { $0.column != column }
        terms.insert(PaneSort(column: column, direction: descending ? .descending : .ascending),
                     at: 0)
        var copy = self
        copy.sort = terms
        copy.offset = 0
        return copy
    }
```

**Check `sorted(by:)`'s existing signature before replacing it** — 2c-ii's version may take
a `PaneSort` rather than two scalars. Preserve whatever `pane_sort`'s handler passes and
adapt only the body plus the type, so this task does not silently change the action's API.

- [ ] **Step 4: Follow the compiler**

`Codable` on `PaneFetch`: the hand-written `init(from:)` decodes `sort`. **A layout saved by
2c-ii holds a single object where an array is now expected**, so decode defensively:

```swift
        // A layout written before D5's fix holds one sort object where an
        // array now lives. Decode either, because the alternative is a
        // pane silently losing its subject at the first relaunch after an
        // upgrade — the failure `Pane.init(from:)` already guards against
        // for an unknown subject, applied one level down.
        if let terms = try? container.decodeIfPresent([PaneSort].self, forKey: .sort) {
            sort = terms ?? []
        } else if let single = try? container.decodeIfPresent(PaneSort.self, forKey: .sort) {
            sort = single.map { [$0] } ?? []
        } else {
            sort = []
        }
```

`PaneStore.setRows(sort:)` and `reorder(paneId:sort:)` take `[PaneSort]`. `snapshot` emits an
array. `PaneContents`'s row-ordering function compares terms in order, falling through to the
next on a tie. `StandardActions.refetchPane` passes
`"sort": .array(fetch.sort.map { .object(["column": .string($0.column), "descending": .bool($0.direction == .descending)]) })`
— matching Task 3's `sortArg`. `sortCanBeRecorded(on:pageable:)` is unchanged in signature
and meaning; an empty array is "no sort" wherever `nil` was.

- [ ] **Step 5: Run everything**

Run: `make app-build && make app-test && make test`
Expected: all green. Tests that constructed `sort: nil` become `sort: []`; tests that
constructed one term become a one-element array. **If a test's assertion needs changing
beyond that, stop** — a behaviour change was introduced that this task did not intend.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/ app/Tests/
git commit -m "A second header click refines the sort instead of escaping into SQL"
```

---

## Task 11: a declared table listing offers its drill (D2, Swift half)

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `PaneTable.listsTables`,
  `paneTable(from:)`
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` — carry it through `setRows`,
  `Contents`, `snapshot`
- Modify: `app/Sources/WakilKit/Panes/PaneFetch.swift` — `offersDrill`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — read `listsTables` off the
  tool result and pass it to `setRows`
- Test: `app/Tests/WakilKitTests/PaneFetchTests.swift`

**Interfaces:**
- Consumes: Task 1's `listsTables` JSON field.
- Produces: `offersDrill(subject:listsTables:) -> Bool`; `PaneTable.listsTables: Bool`.
  Task 13 passes it.

- [ ] **Step 1: Write the failing tests**

```swift
/// The walked failure: asking the agent for the tables gave every row an
/// `open` button; typing `show tables` gave a result that was visibly the
/// same list and opened nothing.
///
/// Wakil still refuses to infer a table list from the SHAPE of the rows —
/// the first `SELECT name FROM …` would prove that wrong. The driver
/// declares it instead, where the read-only gate already reads the verb.
@Test func aDeclaredListingOffersTheDrill() {
    #expect(offersDrill(subject: .sql(database: "core", raw: "show tables"),
                        listsTables: true) == true)
}

@Test func anOrdinarySelectOffersNoDrill() {
    #expect(offersDrill(subject: .sql(database: "core", raw: "SELECT name FROM tables"),
                        listsTables: false) == false)
}

/// The subject still answers for the agent's path, which produces no Rows
/// at all — `db_list_tables` goes through `ListContainers` and
/// `schemaPaneContents`, so `listsTables` is false there and must not be
/// what decides it.
@Test func theTablesSubjectStillOffersTheDrillWithoutTheFlag() {
    #expect(offersDrill(subject: .tables(database: "core"), listsTables: false) == true)
}
```

**The third test is the one that stops a wrong simplification.** `Conn.ListContainers`
returns `[]Container`, not `Rows`; there is no `listsTables` on that path and deleting the
subject check would break the drill that already works.

- [ ] **Step 2: Run and watch them fail**

Run: `make app-test 2>&1 | grep -A4 aDeclaredListingOffers`
Expected: compile failure — `extra argument 'listsTables'`.

- [ ] **Step 3: Implement**

```swift
/// Whether this pane's rows may be opened into panes of their own.
///
/// **Two sources, and neither is the shape of the rows (D2).** The subject
/// answers for `.tables`, which is the agent's path and produces no `Rows`
/// at all. `listsTables` answers for `.sql`, and is set by the driver from
/// the operator's raw text — `SQLReadListsTables`, beside the read-only
/// gate, which is the only place in Wakil that reads SQL.
///
/// Inferring "a one-column result of table-ish strings is a table list"
/// would be wrong the first time someone ran `SELECT name FROM tables`,
/// and a drill that opens the wrong table is a worse failure than one
/// that is absent.
public func offersDrill(subject: PaneQuery?, listsTables: Bool) -> Bool {
    if listsTables { return true }
    guard let subject else { return false }
    if case .tables = subject { return true }
    return false
}
```

Preserve whatever the existing `offersDrill(subject:)` already returned for `.columns` and
the other cases — **read it first** and add `listsTables` to it rather than replacing its
body with this sketch.

Carry `listsTables` through `PaneStore.Contents`, `setRows` (**a new parameter with no
default**, matching `pageable`'s rule from 2c-ii), `snapshot`, `PaneTable` and
`paneTable(from:)`. In `StandardActions`, read it off the `db_run_query` result:

```swift
            var listsTables = false
            if case .bool(let flag)? = object["listsTables"] { listsTables = flag }
```

and pass `listsTables: true` from the `db_list_tables` handler, `false` from
`db_describe_table` and the other schema paths.

- [ ] **Step 4: Run and commit**

```bash
make app-test && make app-build
git add app/Sources/WakilKit/ app/Tests/
git commit -m "A table listing offers its drill however it was asked for"
```

---

## Task 12: the agent is told what the canvas is (D3)

**Files:**
- Create: `app/Sources/WakilKit/Harness/AgentInstructions.swift`
- Modify: `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift:110` — the argument list
- Test: `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift`

**Interfaces:**
- Produces: `public let agentSystemPrompt: String`

- [ ] **Step 1: Write the failing test**

```swift
/// The walked failure: the operator closed a pane and asked for its
/// contents again, and the agent replied "You've asked this exact same
/// question four times in a row now, and the answer hasn't changed" and
/// drew nothing.
///
/// That is not disobedience. Wakil passed NO system prompt at all —
/// `--append-system-prompt` appeared nowhere in the source tree — so the
/// agent was generic Claude Code holding some MCP tools, reasoning about
/// the only surface it had been told about: the conversation.
@Test func theHarnessPassesTheAgentItsInstructions() {
    let launch = claudeCodeCLILaunch(
        configDir: "/tmp/cfg", oauthToken: "t", sessionId: "s",
        mcpConfigJSON: "{}", allowedTools: ["db_run_query"])
    guard let flag = launch.arguments.firstIndex(of: "--append-system-prompt") else {
        Issue.record("the agent is launched with no instructions"); return
    }
    #expect(launch.arguments[flag + 1] == agentSystemPrompt)
}

/// `--append-system-prompt`, never `--system-prompt`: replacing Claude
/// Code's own prompt would discard its tool-use discipline and its refusal
/// behaviour, both of which Wakil relies on and neither of which it wants
/// to restate.
@Test func theInstructionsAreAppendedAndDoNotReplace() {
    let launch = claudeCodeCLILaunch(
        configDir: "/tmp/cfg", oauthToken: "t", sessionId: "s",
        mcpConfigJSON: "{}", allowedTools: [])
    #expect(!launch.arguments.contains("--system-prompt"))
}
```

Match `claudeCodeCLILaunch`'s real signature — read the top of `ClaudeCodeCLIHarness.swift`
and the existing harness tests first.

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | grep -A4 theHarnessPassesTheAgent`
Expected: FAIL — "the agent is launched with no instructions".

- [ ] **Step 3: Write the prompt**

Create `app/Sources/WakilKit/Harness/AgentInstructions.swift`:

```swift
/// What Wakil tells the agent about the surface it is driving.
///
/// **It lives here, in `WakilKit`, as a `let` on no type at all rather than
/// a file read at runtime.** `WakilApp` has no test target and cannot have
/// one, so a decision that needs a test lives in `WakilKit`; and a prompt
/// read from disk at launch would be a deployment artefact that could go
/// missing, turning a silent regression into the default.
///
/// **Appended, never substituted.** `--append-system-prompt` keeps Claude
/// Code's own prompt — its tool-use discipline and its refusal behaviour —
/// which Wakil relies on and does not want to restate.
///
/// **Whether the agent OBEYS this is not testable and must not be
/// pretended otherwise.** The tests beside it assert that the string is
/// non-empty and reaches the CLI. The five claims below are settled at the
/// window, in the acceptance walk, or not at all.
public let agentSystemPrompt = """
You are the agent inside Wakil, a canvas of panes on the operator's screen. \
You cannot see the canvas. These are the rules it runs by.

1. The canvas is the deliverable. A question about data is answered by \
opening or refining a pane, not by describing the data in this \
conversation. Say what you drew and where. Do not paste rows into the \
transcript in place of drawing them.

2. A closed pane is not a cached answer. If the operator asks again for \
something you have already answered, they are asking to see it on screen. \
Draw it. Never decline on the grounds that you have answered it before or \
that the result will not have changed — whether a pane is open is not a \
fact this conversation contains, and you have no way to check.

3. Naming a pane refines it; omitting one opens a new pane. Declare which \
you mean by passing `pane` or leaving it out. Wakil never infers it.

4. The operator's context is theirs. Do not switch the active environment, \
project or provider to make your own work easier. If the work needs a \
different environment, say so and let the operator decide. Wakil will stop \
you at a confirmation plane if you try, and being stopped there is a \
mistake you have already made.

5. Never claim a pane shows something you have not confirmed it shows. The \
result of a tool you just called is what you asked for, which is not the \
same as what is on screen. `read_pane` is what is on screen.
"""
```

- [ ] **Step 4: Pass it**

In `claudeCodeCLILaunch`, after `--strict-mcp-config`:

```swift
        // D3. Before this, Wakil passed no system prompt at all, and the
        // agent's entire knowledge of the app was the tool descriptions.
        // Asked a fourth time for a pane it had already described in chat,
        // it declined to draw one — reasoning about the conversation,
        // because that was the only surface it had been told about.
        "--append-system-prompt", agentSystemPrompt,
```

- [ ] **Step 5: Run and commit**

```bash
make app-test && make app-build
git add app/Sources/WakilKit/Harness/ app/Tests/
git commit -m "Tell the agent the canvas is the answer"
```

---

## Task 13: the pane draws its failure where the rows would go (D12, view half)

**Files:**
- Modify: `app/Sources/WakilApp/DBPane.swift:63-80` — the body's three-way branch
- Modify: `app/Sources/WakilApp/Canvas.swift` — pass `listsTables` into the drill predicate
- No tests. `WakilApp` has no test target; this is verified at the window.

**Interfaces:**
- Consumes: `PaneTable.failure` (Task 4), `PaneTable.listsTables` (Task 11),
  `shouldAdoptSubject(…refused:)` (Task 9).

- [ ] **Step 1: Replace the two-way branch with a three-way one**

```swift
            if let failure = table.failure {
                // D12. "No rows" said "I looked in `docs` and found
                // nothing"; the truth was "`docs` is not a database in this
                // environment". The error was known and journalled, and
                // every caller discarded it with `_ =`. Drawn here, in this
                // pane, because a message about pane B under pane A is the
                // same class of lie in a smaller font.
                Text(failure)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.361, blue: 0.361).opacity(0.75))
                    .textSelection(.enabled)
                Spacer()
            } else if table.columns.isEmpty {
                Text("no rows")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30))
                Spacer()
            } else {
                DataSurface(table: table, pane: pane, dispatch: dispatch, drill: drill())
            }
```

The red is the same literal the refusal line above already uses — one colour for "Wakil
refused" and "Wakil could not", because from the operator's side both mean *this did not
happen*.

`.textSelection(.enabled)` because an error naming a database or a driver is something the
operator will want to copy.

- [ ] **Step 2: Verify the refusal reaches the adoption guard**

Task 9 already added `refused: refusal != nil` to the `onChange` that calls
`shouldAdoptSubject` — its own build required it (pre-flight ruling F3). Confirm it is there
and per-pane; do not add a second one.

- [ ] **Step 3: Pass `listsTables` into the drill**

`drill()`'s guard consults `offersDrill(subject:listsTables:)`; pass `table.listsTables`.

- [ ] **Step 4: Build, then look at it**

```bash
make app-build && make app-bundle
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil
```

Open a pane on `staging`'s `docs` database, then switch the environment to `production`.
**Expected:** the pane refetches (Task 6) and draws the driver's own error in red where its
rows were — not `no rows`, and not a blank pane. That single action exercises Tasks 4, 5, 6
and 13 together, and is the walk's check 11 in miniature.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/
git commit -m "A pane that could not look says so, where its rows would be"
```

---

## Task 14: a new page starts at its first row (D4)

**Files:**
- Modify: `app/Sources/WakilApp/DataSurface.swift:289-335` — inside the `ScrollViewReader`
- No tests.

- [ ] **Step 1: Add the trigger**

Beside the existing `.onChange(of: table.scrollTarget)`:

```swift
            .onChange(of: table.offset) { _, _ in
                // D4. A new page is a new result and starts at its first
                // row. Keyed on `offset` rather than `scrollTarget`
                // because two consecutive pages both want row 0, and
                // `scrollTarget` would not change between them — so the
                // existing handler cannot serve this.
                //
                // Unanimated, unlike `scrollTarget`'s: that one follows a
                // selection the operator can see moving, while this
                // replaces every row at once. Animating a scroll through
                // rows that are already gone would draw motion that means
                // nothing.
                guard let first = table.rows.first?.id else { return }
                proxy.scrollTo(first, anchor: .top)
            }
```

- [ ] **Step 2: Build and walk it**

```bash
make app-build && make app-bundle
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil
```

Open a table with more than 500 rows, scroll to the middle of page one, press `›`.
**Expected:** page two, at its first row. Press `‹`. **Expected:** page one, at its first
row — not where you left it.

- [ ] **Step 3: Commit**

```bash
git add app/Sources/WakilApp/DataSurface.swift
git commit -m "A new page starts at its first row"
```

---

## Task 15: an arrow on every sorted column (D5, view half)

**Files:**
- Modify: `app/Sources/WakilApp/DataSurface.swift` — the header, and `footer()` at ~520
- No tests.

**Interfaces:**
- Consumes: `PaneTable.sort: [PaneSort]` (Task 10).

- [ ] **Step 1: Draw an arrow per term, with its ordinal**

The header currently draws ▲/▼ when `table.sort?.column == column`. It becomes a lookup into
the array:

```swift
    /// The sort indicator for one column: its direction, and its position
    /// when more than one column is sorted.
    ///
    /// **The ordinal is not decoration.** Two arrows with no precedence
    /// shown would replace the old ambiguity (a sort that was sometimes
    /// text and sometimes a glyph) with a new one — which column breaks
    /// the tie. With one term there is no precedence to state, so none is
    /// drawn.
    private func sortIndicator(for column: String) -> String? {
        guard let index = table.sort.firstIndex(where: { $0.column == column }) else {
            return nil
        }
        let arrow = table.sort[index].direction == .descending ? "▼" : "▲"
        return table.sort.count > 1 ? "\(arrow)\(index + 1)" : arrow
    }
```

- [ ] **Step 2: Name every term in the footer's warning**

```swift
            if !table.sort.isEmpty, table.truncated {
                // Spec §7, as the probe corrected it, now naming every
                // term: a sort the operator asked for and a warning that
                // mentioned only its first column would understate what
                // the result is ordered by.
                let columns = table.sort.map(\.column).joined(separator: ", ")
                Text("sorted by \(columns) within the \(table.rows.count) returned")
            }
```

- [ ] **Step 3: Build and walk it**

Click one header, then a second. **Expected:** `▼1` and `▲2` (or as clicked), both visible,
the query line unchanged, and the result ordered by the first then the second. Click the
first header again. **Expected:** it flips and stays in position 1.

- [ ] **Step 4: Commit**

```bash
make app-build
git add app/Sources/WakilApp/DataSurface.swift
git commit -m "Every sorted column carries its arrow, in precedence order"
```

---

## Task 16: the drill clears the scrollbar, the footer truncates, and the walk is re-run

**Files:**
- Modify: `app/Sources/WakilApp/DataSurface.swift:367-373` — the drill overlay's padding
- Modify: `app/Sources/WakilApp/DataSurface.swift:524-559` — `footer()`
- Modify: `docs/wakil/phase-2c-ii-acceptance.md` — §5 outcomes, §7
- Modify: `docs/wakil/north-star.md` — the 2c-ii row

- [ ] **Step 1: D6 — clear the scroller's gutter**

```swift
                Button("open") { drill(row.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.0)
                    .foregroundStyle(Color(red: 0.62, green: 0.51, blue: 1.0))
                    // D6. The vertical scroller is drawn over this edge and
                    // clipped "open" to "ope". Not fixed by hiding the
                    // scroller: it is the only indication of position in a
                    // 500-row page.
                    .padding(.trailing, 20)
```

- [ ] **Step 2: D9 — the footer truncates instead of wrapping**

Every `Text` in `footer()` takes `.lineLimit(1)`, and the `HStack` takes
`.fixedSize(horizontal: false, vertical: true)`:

```swift
        .font(.system(size: 9, weight: .medium))
        .tracking(1.0)
        .lineLimit(1)
        // D9. Without this every segment wrapped to one character per line
        // at small widths, turning the footer into a column of vertical
        // letters. `rows`, the range and `read-only` are the claims an
        // operator checks a result against, so they are what must survive
        // narrowing.
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
```

- [ ] **Step 3: Build and check both at the window**

Hover a schema row: `open` is fully visible and clickable. Resize a pane to its narrowest:
the footer truncates on one line.

- [ ] **Step 4: Full verification**

```bash
make test && make vet && make test-live && make app-test && make app-build && make bench-surface
```

All six green, with `wakil-acc-mysql` and `wakil-acc-mongo` up. **Paste the real output into
the acceptance document's §3/§4** — do not summarise it.

**Steps 5 and 6 are the operator's, not an implementer's** (pre-flight ruling F6). A
subagent has no window and cannot walk a GUI runbook; it finishes at Step 4 and reports.

- [ ] **Step 5: Re-walk the runbook** *(operator)*

`docs/wakil/phase-2c-ii-acceptance.md` §2, all fourteen checks, **with check 11 walked the
way §5 says it must be**: switch the environment *while panes are open*, which is the case
that produced both blockers, and confirm the banner still reads `production` immediately
before quitting.

Record each outcome in its Result row. Mark each §5 defect fixed, with the commit that fixed
it, or record why it still stands.

- [ ] **Step 6: Only then, the verdict** *(operator)*

If — and only if — the walk is clean, update §7 and `north-star.md`'s 2c-ii row to **met**,
and say by what: a walked runbook, not a green suite. **If any check fails, it stays
unmarked.** That discipline is the only reason 2c-i's "met" means anything, and this round
exists because twelve defects survived 605 green tests.

```bash
git add docs/ app/Sources/WakilApp/DataSurface.swift
git commit -m "The last two layout fixes, and a runbook walked a third time"
```

---

## Self-review

**Spec coverage.** §3 → Tasks 4, 5, 13. §4 → Task 6. §5 → Task 12. §6 → Task 7. §7 → Task 8.
§8 → Task 14. §9 → Task 9. §10 → Tasks 2, 3, 10, 15. §11 → Tasks 1, 11. §12 → Task 16.
§13 → no task, by design. §15's exit criterion → Task 16 Steps 4–6.

**Ordering hazards, stated once more because they are the ones that bite:**
- **Task 3 breaks the Swift build; Task 10 repairs it.** Do not review a green tree between
  them — there will not be one.
- **Task 5 before Task 6.** D11's fix makes failures common, and without D12's wiring it
  would turn three lying panes into three panes claiming to be empty.
- **Task 4 before Task 10.** Task 4's tests are written against today's `sort:` parameter and
  Task 10 updates them with every other call site.

**Known gaps left deliberately:**
- **The five claims in the system prompt are untested prose** (§5.4). Their only verification
  is the re-walk.
- **D1 is not fixed** and §13 says why.
- **`SHOW FULL TABLES` and `SHOW TABLES FROM x` are not drillable**, on purpose.
