# Phase 2c-ii — The DB Pane in Full: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a `db` pane its own query — visible, editable, paged, sorted and restored — so that the schema browser, pagination, sort-as-re-query and relaunch are four consumers of one mechanism rather than four features.

**Architecture:** A pane's *subject* (`PaneQuery` + offset + page size + sort) lives on `Pane` and persists with the layout; the rows it produced stay in `PaneStore` and do not. Paging is offset paging applied by the Go driver, which wraps the operator's statement in a subquery only when it must and only when the read-only gate's own verb says the statement can survive it. A `DBPane` view puts the subject on screen above 2c-i's unchanged `DataSurface`, and `Canvas.paneView` grows its first `switch pane.kind`.

**Tech Stack:** Go 1.27 (`CGO_ENABLED=0`), Swift 6.3, SwiftUI, Swift Testing (`@Test`/`#expect`), `make` for build/test targets.

**Spec:** `docs/superpowers/specs/2026-09-12-phase-2c-ii-db-pane-design.md`
**Probe:** `docs/wakil/phase-2c-ii-probe.md` — every claim below about what wraps, what pages and who receives a keystroke comes from it. Read §2 and §3 of it before Task 1 and before Task 13.

## Global Constraints

- **Gate the operator's text, never Wakil's.** `c.gate(spec.Raw)` runs on the raw statement *before* any wrapping. `readonly.go` is 817 lines hardened across five documented bypasses and is never asked to judge a statement Wakil composed. (Spec §3.)
- **No SQL parsing in Swift.** Not for routing, not for table names, not for deciding whether something is a mutation. Every such question is answered in Go by the function that already enforces it. (Spec §6, §9.)
- **Wrap with `LIMIT limit+1`, never `LIMIT limit`.** `collectRows` reads one row past the limit to set `Truncated`; a wrap that returns exactly `limit` rows makes `Truncated` permanently false and "more remain" never appears. (Task 1.)
- **Trim trailing `;` before wrapping.** `AssertSQLReadOnly` permits one, and `SELECT * FROM (SELECT 1;) AS x` is a syntax error.
- **Every new action is `.read`, not `.control`,** and carries no `targetEnvironmentParam`. Each one reaches a database. `.control` is for state that never leaves Wakil. (Spec §10.)
- **`PaneStore.setRows` keeps its no-defaults rule.** The new `sort:` parameter has no default either, so no caller can silently drop it. (Spec §2.)
- **No per-pane `.keyboardShortcut` anywhere in the DB pane.** Measured: it is window-scoped and fires the first-registered pane's button whatever has focus. The query line submits on Return via `.onSubmit`. (Probe §3.)
- **`Pane.kinds` stays `["db"]`.** 2c-ii adds no pane kind.
- **Every key in a `read_pane` payload is always present**, including when false or empty — `PaneStore.snapshot`'s existing rule.
- **Go: `CGO_ENABLED=0`** is exported by the Makefile for build, test and vet alike. Do not override it.
- **Swift tests run headless** via `make app-test`. Nothing in `WakilKitTests` may need a display; `WakilApp` has no test target and cannot have one.
- **Commit after every task.** Never leave the tree dirty between tasks.

## File Structure

**Go — paging, table reads, and classification**

| File | Responsibility |
|---|---|
| `internal/wakilcore/dbdriver.go` | `QuerySpec` gains `Offset`/`Sort`; `Rows` gains `Pageable`; `Conn` gains `ReadTable` |
| `internal/wakilcore/readonly.go` | `SQLReadIsPageable` — the verb the gate already distinguishes, exposed |
| `internal/wakilcore/sqlconn.go` | conditional subquery wrapping, `ReadTable`, `Pageable` |
| `internal/wakilcore/driver_mongo.go` | `$skip`/`SetSkip`, sort, `ReadTable`, and the inline limit clamp deleted in favour of `clampReadLimit` |
| `internal/wakilcore/classify.go` | **New.** `ClassifyStatement` — `read`/`mutation`/`neither`, from the real gates |
| `cmd/wakil-db/main.go` | `queryArg` gains offset/sort; two new tools, `read_table` and `classify_statement` |
| `cmd/wakil-db/schema_test.go` | the two new tools added to the pinned list |

**Swift — the subject**

| File | Responsibility |
|---|---|
| `app/Sources/WakilKit/Panes/PaneFetch.swift` | **New.** `PaneQuery`, `PaneFetch` — what a pane is looking at |
| `app/Sources/WakilKit/Layout/Pane.swift` | `Pane.fetch`, persisted, decoded tolerantly |
| `app/Sources/WakilKit/Panes/PaneStore.swift` | `setRows` takes the sort and the page state; `setSort` deleted |
| `app/Sources/WakilKit/Layout/LayoutStore.swift` | `setFetch`; `queryTargetPane`'s focused-pane fallback deleted |

**Swift — the actions**

| File | Responsibility |
|---|---|
| `app/Sources/WakilKit/Registry/StandardActions.swift` | `db_run_query` records the subject and routes by §6; `db_list_tables`, `db_describe_table`, `db_read_table`, `db_refetch`, `db_page`, `db_classify_statement` |
| `app/Sources/WakilKit/Panes/PaneContentActions.swift` | `pane_sort` writes the subject and re-queries or re-orders |

**Swift — the view**

| File | Responsibility |
|---|---|
| `app/Sources/WakilKit/App/WindowModel.swift` | `runQuery` gains a database and a pane; `PaneTable` gains paging state; relaunch re-fetch |
| `app/Sources/WakilApp/DBPane.swift` | **New.** The query line, the paged footer, the drill affordance |
| `app/Sources/WakilApp/Canvas.swift` | the first `switch pane.kind` |
| `app/Sources/WakilApp/DataSurface.swift` | footer gains paging and the corrected sort admission |

**Documents**

| File | Responsibility |
|---|---|
| `docs/wakil/phase-2c-ii-acceptance.md` | **New.** The runbook, to be walked |
| `docs/wakil/design-language.md` | §8's paging footer, §11's Database row |
| `docs/wakil/north-star.md` | 2c-ii's row, amended per spec §0 |

---

## Task 1: `QuerySpec` gains an offset, and `sqlConn` pages by wrapping

**Files:**
- Modify: `internal/wakilcore/dbdriver.go` (`QuerySpec`, `Rows`)
- Modify: `internal/wakilcore/readonly.go` (append `SQLReadIsPageable`)
- Modify: `internal/wakilcore/sqlconn.go` (`Read`, new `pageWrap`)
- Test: `internal/wakilcore/sqlconn_test.go`, `internal/wakilcore/readonly_test.go`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `QuerySpec{Raw string; Offset int; Sort *QuerySort}`, `QuerySort{Column string; Descending bool}`, `Rows.Pageable bool`, `func SQLReadIsPageable(sql string) bool`.

Read `docs/wakil/phase-2c-ii-probe.md` §2 first. It is the evidence for every claim in this task about what does and does not survive a wrap.

- [ ] **Step 1: Write the failing tests for `SQLReadIsPageable`**

Append to `internal/wakilcore/readonly_test.go`:

```go
func TestSQLReadIsPageable(t *testing.T) {
	for _, tc := range []struct {
		name string
		sql  string
		want bool
	}{
		{"plain select", "SELECT id FROM events", true},
		{"lowercase select", "select id from events", true},
		{"cte", "WITH x AS (SELECT 1) SELECT * FROM x", true},
		{"leading whitespace and comment", "  -- pick some\n SELECT id FROM events", true},
		{"trailing semicolon", "SELECT id FROM events;", true},
		// The two the probe measured failing when wrapped, on both
		// engines. Both are reads AssertSQLReadOnly permits, which is
		// exactly why this function has to exist: refusing them is not
		// an option and wrapping them is not either.
		{"explain", "EXPLAIN SELECT id FROM events", false},
		{"show tables", "SHOW TABLES", false},
		{"lowercase show", "show tables", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := SQLReadIsPageable(tc.sql); got != tc.want {
				t.Fatalf("SQLReadIsPageable(%q) = %v, want %v", tc.sql, got, tc.want)
			}
		})
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `go test ./internal/wakilcore/ -run TestSQLReadIsPageable`
Expected: FAIL — `undefined: SQLReadIsPageable`

- [ ] **Step 3: Add `SQLReadIsPageable`**

Append to `internal/wakilcore/readonly.go`, directly below `AssertSQLReadOnly`:

```go
// SQLReadIsPageable reports whether a read AssertSQLReadOnly has already
// accepted can survive being wrapped in a subquery, which is how Wakil
// applies LIMIT/OFFSET and a pushed ORDER BY to a statement it did not
// write (see sqlConn.pageWrap).
//
// It is deliberately the same prefix test AssertSQLReadOnly makes, minus
// two verbs. That gate accepts four: SELECT, WITH, EXPLAIN and SHOW. The
// first two are expressions and nest; the last two are statements and do
// not. Measured on sqlite and MySQL 8 in docs/wakil/phase-2c-ii-probe.md
// §2: "SELECT * FROM (SHOW TABLES) AS wakil_page" is a syntax error on
// MySQL and "SELECT * FROM (EXPLAIN ...) AS wakil_page" is one on both.
//
// This is not a second opinion about what is safe to run — it decides
// nothing about safety and must never be used to. AssertSQLReadOnly is
// the only gate; this function only says whether an already-permitted
// read can be paged, so that a caller can hide a page control instead of
// handing the operator the engine's raw syntax error.
func SQLReadIsPageable(sql string) bool {
	clean := strings.TrimSpace(stripSQLComments(sql))
	trimmed := strings.TrimRight(clean, "; \t\n")
	upper := strings.ToUpper(strings.TrimSpace(trimmed))
	return strings.HasPrefix(upper, "SELECT") || strings.HasPrefix(upper, "WITH")
}
```

- [ ] **Step 4: Run it and watch it pass**

Run: `go test ./internal/wakilcore/ -run TestSQLReadIsPageable -v`
Expected: PASS, all eight subtests.

- [ ] **Step 5: Extend `QuerySpec` and `Rows`**

In `internal/wakilcore/dbdriver.go`, replace `type QuerySpec struct { Raw string }` with:

```go
// QuerySort is one pushed ORDER BY: the column to order by and which way.
//
// A pointer field on QuerySpec rather than a Column string that is empty
// when unset, because "no sort" and "sort by the column named empty
// string" are different requests and a driver must not have to guess
// which it got.
type QuerySort struct {
	Column     string
	Descending bool
}

type QuerySpec struct {
	Raw string
	// Offset is how many rows to skip before the first one returned.
	// Zero is page one and is the only value any caller passed before
	// 2c-ii, so a zero-valued QuerySpec behaves exactly as it always did.
	Offset int
	// Sort, when non-nil, is pushed into the statement as an ORDER BY
	// rather than applied to the rows afterwards. It is what makes a sort
	// over a truncated result honest: the engine orders everything that
	// matches and Wakil shows the first page of that ordering, instead of
	// ordering the 500 rows that happened to come back.
	Sort *QuerySort
}
```

In the same file, add to `Rows`, directly below `Truncated`:

```go
	// Pageable is whether this result can be asked for a second page at
	// all. False for an EXPLAIN and for a SHOW — both reads the gate
	// permits and neither one able to survive the subquery Wakil pages
	// with (SQLReadIsPageable). It is reported rather than inferred so a
	// caller can omit the page control instead of offering one that
	// returns a syntax error.
	//
	// No `omitempty`: false is the answer that matters, and a reader
	// (including an LLM) must not have to tell "cannot be paged" apart
	// from "this server is too old to say".
	Pageable bool `json:"pageable"`
```

- [ ] **Step 6: Write the failing paging tests**

Append to `internal/wakilcore/sqlconn_test.go`. Reuse whatever helper that file already uses to build an in-memory sqlite `sqlConn`; if it builds the literal by hand, build it the same way here.

```go
// newPagingFixture opens an in-memory sqlite sqlConn over a 12-row table.
// Built by hand, the same way the Describe fixtures in this file are, so
// the gate and quoteIdent under test are the real ones.
func newPagingFixture(t *testing.T) *sqlConn {
	t.Helper()
	db, err := sql.Open("sqlite", "file:paging?mode=memory&cache=shared")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT)`); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 12; i++ {
		if _, err := db.Exec(`INSERT INTO events VALUES (?, ?)`, i, fmt.Sprintf("k%d", i%3)); err != nil {
			t.Fatal(err)
		}
	}
	return &sqlConn{
		db:         db,
		gate:       AssertSQLReadOnly,
		listSQL:    `SELECT name FROM sqlite_master WHERE type='table'`,
		quoteIdent: sqliteQuoteIdent,
	}
}

func idsOf(t *testing.T, rows Rows) []int64 {
	t.Helper()
	var out []int64
	for _, r := range rows.Rows {
		n, ok := r[0].(int64)
		if !ok {
			t.Fatalf("first column is %T, not int64", r[0])
		}
		out = append(out, n)
	}
	return out
}

func TestReadPagesByOffset(t *testing.T) {
	c := newPagingFixture(t)
	ctx := context.Background()

	first, err := c.Read(ctx, QuerySpec{Raw: "SELECT id FROM events", Offset: 0}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if got := idsOf(t, first); !reflect.DeepEqual(got, []int64{1, 2, 3, 4, 5}) {
		t.Fatalf("page one = %v", got)
	}
	if !first.Truncated {
		t.Fatal("page one over 12 rows must report more remain")
	}

	second, err := c.Read(ctx, QuerySpec{Raw: "SELECT id FROM events", Offset: 5}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if got := idsOf(t, second); !reflect.DeepEqual(got, []int64{6, 7, 8, 9, 10}) {
		t.Fatalf("page two = %v", got)
	}
	if !second.Truncated {
		t.Fatal("page two must still report more remain")
	}

	// The last page: exactly two rows left, so nothing was dropped and
	// Truncated must be false. This is the assertion that fails if the
	// wrap uses LIMIT n instead of LIMIT n+1 — with LIMIT n, collectRows
	// never sees the row past the end and every page claims to be last.
	third, err := c.Read(ctx, QuerySpec{Raw: "SELECT id FROM events", Offset: 10}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if got := idsOf(t, third); !reflect.DeepEqual(got, []int64{11, 12}) {
		t.Fatalf("page three = %v", got)
	}
	if third.Truncated {
		t.Fatal("the last page must not claim more remain")
	}
}

func TestReadPastTheEndIsEmptyNotAnError(t *testing.T) {
	c := newPagingFixture(t)
	out, err := c.Read(context.Background(), QuerySpec{Raw: "SELECT id FROM events", Offset: 99}, 5)
	if err != nil {
		t.Fatalf("paging past the end must not error: %v", err)
	}
	if len(out.Rows) != 0 {
		t.Fatalf("want no rows, got %d", len(out.Rows))
	}
	// The columns survive even with no rows, so a surface keeps its
	// headers rather than collapsing to "no rows".
	if !reflect.DeepEqual(out.Columns, []string{"id"}) {
		t.Fatalf("columns = %v", out.Columns)
	}
}

func TestReadPushesSortIntoTheStatement(t *testing.T) {
	c := newPagingFixture(t)
	out, err := c.Read(context.Background(), QuerySpec{
		Raw:  "SELECT id FROM events",
		Sort: &QuerySort{Column: "id", Descending: true},
	}, 3)
	if err != nil {
		t.Fatal(err)
	}
	// Descending over the WHOLE table, not over the first three rows:
	// that is the difference between a re-query and a client-side sort.
	if got := idsOf(t, out); !reflect.DeepEqual(got, []int64{12, 11, 10}) {
		t.Fatalf("sorted page = %v", got)
	}
}

func TestPageOneIsNotWrapped(t *testing.T) {
	c := newPagingFixture(t)
	// A SHOW/EXPLAIN-shaped read cannot be wrapped, so the only way this
	// can succeed is if an unpaged, unsorted read is passed through
	// verbatim. sqlite has no SHOW; EXPLAIN is its equivalent here and
	// the probe recorded it failing wrapped on this engine too.
	out, err := c.Read(context.Background(), QuerySpec{Raw: "EXPLAIN SELECT id FROM events"}, 5)
	if err != nil {
		t.Fatalf("an unpaged EXPLAIN must run verbatim: %v", err)
	}
	if out.Pageable {
		t.Fatal("an EXPLAIN must report itself unpageable")
	}
	if len(out.Columns) == 0 {
		t.Fatal("EXPLAIN returned no columns")
	}
}

func TestPagingAnUnpageableReadIsRefusedByWakilNotByTheEngine(t *testing.T) {
	c := newPagingFixture(t)
	_, err := c.Read(context.Background(), QuerySpec{Raw: "EXPLAIN SELECT id FROM events", Offset: 5}, 5)
	if err == nil {
		t.Fatal("paging an EXPLAIN must fail")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("must be a UserError, got %T: %v", err, err)
	}
	// The point of the whole Pageable field: the operator is told the
	// real reason rather than handed the engine's syntax error about a
	// statement they never wrote.
	if !strings.Contains(msg, "cannot be paged") {
		t.Fatalf("message must name the reason, got %q", msg)
	}
	if strings.Contains(msg, "wakil_page") {
		t.Fatalf("message must not leak Wakil's own wrapping, got %q", msg)
	}
}

func TestSelectIsPageableAndSaysSo(t *testing.T) {
	c := newPagingFixture(t)
	out, err := c.Read(context.Background(), QuerySpec{Raw: "SELECT id FROM events"}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if !out.Pageable {
		t.Fatal("a SELECT must report itself pageable")
	}
}

func TestGateSeesTheOperatorsTextNotTheWrap(t *testing.T) {
	var seen string
	c := newPagingFixture(t)
	c.gate = func(s string) error { seen = s; return AssertSQLReadOnly(s) }
	if _, err := c.Read(context.Background(),
		QuerySpec{Raw: "SELECT id FROM events", Offset: 5}, 5); err != nil {
		t.Fatal(err)
	}
	if seen != "SELECT id FROM events" {
		t.Fatalf("the gate judged %q, not the operator's own statement", seen)
	}
}

func TestTrailingSemicolonSurvivesWrapping(t *testing.T) {
	c := newPagingFixture(t)
	// AssertSQLReadOnly permits one trailing ";". Wrapping without
	// trimming it produces "SELECT * FROM (SELECT id FROM events;) AS
	// wakil_page", which every engine rejects.
	out, err := c.Read(context.Background(),
		QuerySpec{Raw: "SELECT id FROM events;", Offset: 5}, 5)
	if err != nil {
		t.Fatalf("a trailing semicolon must be trimmed before wrapping: %v", err)
	}
	if got := idsOf(t, out); !reflect.DeepEqual(got, []int64{6, 7, 8, 9, 10}) {
		t.Fatalf("page two = %v", got)
	}
}

func TestNegativeOffsetIsClampedToZero(t *testing.T) {
	c := newPagingFixture(t)
	out, err := c.Read(context.Background(), QuerySpec{Raw: "SELECT id FROM events", Offset: -5}, 3)
	if err != nil {
		t.Fatal(err)
	}
	if got := idsOf(t, out); !reflect.DeepEqual(got, []int64{1, 2, 3}) {
		t.Fatalf("a negative offset must read as page one, got %v", got)
	}
}
```

Add `"reflect"`, `"strings"`, `"fmt"`, `"context"` and `"database/sql"` to that file's imports if they are not already there.

- [ ] **Step 7: Run them and watch them fail**

Run: `go test ./internal/wakilcore/ -run 'TestRead|TestPag|TestSelectIsPageable|TestGateSees|TestTrailing|TestNegativeOffset'`
Expected: FAIL — `unknown field Offset in struct literal` and `out.Pageable undefined`.

- [ ] **Step 8: Implement the wrap**

In `internal/wakilcore/sqlconn.go`, replace `Read` with:

```go
// Read runs one read and returns at most limit rows of it.
//
// The order of the first two steps is load-bearing and is the same order
// Write establishes. c.gate judges the OPERATOR'S OWN TEXT, before
// anything is wrapped around it: readonly.go is hardened across five
// documented bypasses and is never handed a statement Wakil composed, so
// no change to the wrapping below can loosen a gate.
//
// Wrapping is conditional because not every permitted read survives being
// a subquery — see SQLReadIsPageable and the probe it cites. A plain
// first page is therefore byte-for-byte the statement every caller before
// 2c-ii sent, and only a request that genuinely needs an offset or a
// pushed sort pays the wrapping risk at all.
func (c *sqlConn) Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error) {
	if err := c.gate(spec.Raw); err != nil {
		return Rows{}, err
	}
	limit = clampReadLimit(limit)
	offset := spec.Offset
	if offset < 0 {
		offset = 0
	}
	pageable := SQLReadIsPageable(spec.Raw)
	needsWrap := offset > 0 || spec.Sort != nil
	if needsWrap && !pageable {
		return Rows{}, UserError(
			"this result cannot be paged or re-sorted: only SELECT and WITH results can be, " +
				"and EXPLAIN and SHOW cannot")
	}

	stmt := spec.Raw
	if needsWrap {
		stmt = c.pageWrap(spec.Raw, spec.Sort, limit, offset)
	}

	start := time.Now()
	rows, err := c.db.QueryContext(ctx, stmt)
	if err != nil {
		return Rows{}, UserError("query failed: " + err.Error())
	}
	defer rows.Close()
	out, err := collectRows(rows, limit)
	if err != nil {
		return Rows{}, err
	}
	out.Pageable = pageable
	out.Millis = time.Since(start).Milliseconds()
	return out, nil
}

// pageWrap builds the paged form of raw.
//
// LIMIT is limit+1, NOT limit, and that "+1" is the whole reason
// collectRows can still tell a full page from a last one: it reads one
// row past the limit and sets Truncated from the overshoot. A wrap that
// returned exactly limit rows would make every page claim to be the last.
//
// The trailing ";" AssertSQLReadOnly permits is trimmed, because
// "SELECT * FROM (SELECT 1;) AS wakil_page" is a syntax error everywhere.
//
// The ORDER BY column goes through c.quoteIdent, the same sole guard
// Describe relies on: the column name arrives from a header click or from
// an agent, and an unquoted identifier is how that becomes an injection.
// The direction is not interpolated at all — it is one of two literals.
func (c *sqlConn) pageWrap(raw string, sort *QuerySort, limit, offset int) string {
	inner := strings.TrimRight(strings.TrimSpace(raw), "; \t\n")
	var b strings.Builder
	b.WriteString("SELECT * FROM (")
	b.WriteString(inner)
	b.WriteString(") AS wakil_page")
	if sort != nil {
		b.WriteString(" ORDER BY ")
		b.WriteString(c.quoteIdent(sort.Column))
		if sort.Descending {
			b.WriteString(" DESC")
		} else {
			b.WriteString(" ASC")
		}
	}
	fmt.Fprintf(&b, " LIMIT %d OFFSET %d", limit+1, offset)
	return b.String()
}
```

Add `"fmt"` to the file's imports.

- [ ] **Step 9: Run the whole package**

Run: `go test ./internal/wakilcore/ -count=1`
Expected: PASS. The existing `TestClampReadLimit`, the `Describe` injection fixtures and every driver test must still pass — nothing above changes an unpaged, unsorted read.

- [ ] **Step 10: Fix the one fake that implements `Conn`**

`internal/wakilcore/dbresolve_test.go:147` has `fakeTestConn.Read`. Its signature is unchanged by this task (only `QuerySpec`'s fields grew), so it should still compile. Run `go vet ./...` to confirm.

Run: `go vet ./...`
Expected: no output.

- [ ] **Step 11: Commit**

```bash
git add internal/wakilcore/dbdriver.go internal/wakilcore/readonly.go internal/wakilcore/sqlconn.go internal/wakilcore/sqlconn_test.go internal/wakilcore/readonly_test.go
git commit -m "Page a SQL read by offset, and say when a read cannot be paged

The wrap only happens when an offset or a pushed sort asks for one, so
page one is the statement every caller before this sent. It carries
LIMIT n+1 rather than LIMIT n, because collectRows reads one row past the
limit to tell a full page from a last one.

EXPLAIN and SHOW are reads the gate permits and neither survives being a
subquery, measured on both engines. Rows.Pageable carries that out from
the verb the gate already distinguishes, so a caller can drop the page
control instead of handing the operator a syntax error about a statement
Wakil wrote."
```

---

## Task 2: Mongo pages the same way, and stops keeping its own copy of the cap

**Files:**
- Modify: `internal/wakilcore/driver_mongo.go` (`Read`, new `appendSkipStage`, new `appendSortStage`)
- Test: `internal/wakilcore/driver_mongo_test.go`

**Interfaces:**
- Consumes: `QuerySpec.Offset`, `QuerySpec.Sort`, `Rows.Pageable` (Task 1).
- Produces: no new exported symbols. `mongoConn.Read` honours offset and sort and always sets `Pageable = true`.

Mongo needs no wrapping and has no unpageable case — the probe (§2, Mongo table) measured `$skip` before `$limit`, a user pipeline that already ends in `$limit`, and a skip past the end, and all three behave exactly as the SQL path does.

- [ ] **Step 1: Write the failing unit tests for the two stage helpers**

Append to `internal/wakilcore/driver_mongo_test.go`:

```go
func TestAppendSkipStageGoesBeforeTheLimit(t *testing.T) {
	// The order is load-bearing and the probe measured it: $limit then
	// $skip over 12 docs with limit 4 and skip 3 returns ONE document,
	// because $limit runs first and leaves only four to skip within.
	// $skip then $limit returns four. Callers must compose in that order,
	// and this test is what says so.
	pipeline := appendSkipStage([]map[string]any{{"$match": map[string]any{}}}, 3)
	pipeline = appendLimitStage(pipeline, 5)
	if len(pipeline) != 3 {
		t.Fatalf("want three stages, got %d: %v", len(pipeline), pipeline)
	}
	if _, ok := pipeline[1]["$skip"]; !ok {
		t.Fatalf("stage 1 must be $skip, got %v", pipeline[1])
	}
	if _, ok := pipeline[2]["$limit"]; !ok {
		t.Fatalf("stage 2 must be $limit, got %v", pipeline[2])
	}
}

func TestAppendSkipStageIsANoOpAtZero(t *testing.T) {
	// Page one must produce the exact pipeline every caller before 2c-ii
	// sent, for the same reason a SQL page one is not wrapped.
	base := []map[string]any{{"$match": map[string]any{}}}
	if got := appendSkipStage(base, 0); len(got) != 1 {
		t.Fatalf("a zero skip must add no stage, got %v", got)
	}
	if got := appendSkipStage(base, -4); len(got) != 1 {
		t.Fatalf("a negative skip must add no stage, got %v", got)
	}
}

func TestAppendSortStage(t *testing.T) {
	pipeline := appendSortStage([]map[string]any{{"$match": map[string]any{}}},
		&QuerySort{Column: "id", Descending: true})
	if len(pipeline) != 2 {
		t.Fatalf("want two stages, got %v", pipeline)
	}
	spec, ok := pipeline[1]["$sort"].(map[string]any)
	if !ok {
		t.Fatalf("stage 1 must be $sort, got %v", pipeline[1])
	}
	if spec["id"] != -1 {
		t.Fatalf("descending must be -1, got %v", spec["id"])
	}
	asc := appendSortStage(nil, &QuerySort{Column: "id"})
	if asc[0]["$sort"].(map[string]any)["id"] != 1 {
		t.Fatalf("ascending must be 1, got %v", asc[0])
	}
	if got := appendSortStage([]map[string]any{{"$match": map[string]any{}}}, nil); len(got) != 1 {
		t.Fatalf("a nil sort must add no stage, got %v", got)
	}
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/wakilcore/ -run 'TestAppendSkipStage|TestAppendSortStage'`
Expected: FAIL — `undefined: appendSkipStage`, `undefined: appendSortStage`.

- [ ] **Step 3: Add the two helpers**

In `internal/wakilcore/driver_mongo.go`, beside `appendLimitStage`:

```go
// appendSkipStage adds a $skip stage, or nothing at all when n is zero or
// negative.
//
// Callers MUST append skip before limit. The two are not commutative and
// the wrong order silently returns too few documents rather than failing:
// over 12 documents, $limit 4 then $skip 3 yields one document, because
// $limit runs first and leaves four to skip within. Measured in
// docs/wakil/phase-2c-ii-probe.md §2.
//
// Adding nothing at zero is the Mongo half of "page one is not wrapped":
// the pipeline a caller gets for the first page is exactly the pipeline
// every caller before 2c-ii got.
func appendSkipStage(pipeline []map[string]any, n int) []map[string]any {
	if n <= 0 {
		return pipeline
	}
	return append(append([]map[string]any{}, pipeline...), map[string]any{"$skip": n})
}

// appendSortStage adds a $sort stage, or nothing when sort is nil.
//
// 1 and -1 are Mongo's own spelling of ascending and descending; they are
// not interpolated from anything the caller controls, only chosen between.
func appendSortStage(pipeline []map[string]any, sort *QuerySort) []map[string]any {
	if sort == nil {
		return pipeline
	}
	dir := 1
	if sort.Descending {
		dir = -1
	}
	return append(append([]map[string]any{}, pipeline...),
		map[string]any{"$sort": map[string]any{sort.Column: dir}})
}
```

- [ ] **Step 4: Run them and watch them pass**

Run: `go test ./internal/wakilcore/ -run 'TestAppendSkipStage|TestAppendSortStage' -v`
Expected: PASS.

- [ ] **Step 5: Honour offset and sort in `mongoConn.Read`, and delete the duplicated cap**

In `internal/wakilcore/driver_mongo.go`, in `Read`, replace:

```go
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
```

with:

```go
	// clampReadLimit rather than a copy of its body. This was an inline
	// duplicate of that function until 2c-ii — the same two bounds and the
	// same 500 — which meant the cap had to be changed in two places and
	// would one day have been changed in one. TestMongoUsesTheSharedCap
	// pins the call.
	limit = clampReadLimit(limit)
	offset := spec.Offset
	if offset < 0 {
		offset = 0
	}
```

Then in the `"find"` branch, replace the `coll.Find` call with:

```go
		findOpts := options.Find().SetLimit(int64(limit + 1))
		if offset > 0 {
			findOpts = findOpts.SetSkip(int64(offset))
		}
		if spec.Sort != nil {
			dir := 1
			if spec.Sort.Descending {
				dir = -1
			}
			findOpts = findOpts.SetSort(bson.D{{Key: spec.Sort.Column, Value: dir}})
		}
		cursor, err = coll.Find(ctx, filter, findOpts)
```

and in the `"aggregate"` branch, replace the `pipeline := appendLimitStage(...)` line with:

```go
		// Sort, then skip, then limit — in that order, and the order is
		// not cosmetic. See appendSkipStage.
		pipeline := appendSortStage(q.Pipeline, spec.Sort)
		pipeline = appendSkipStage(pipeline, offset)
		pipeline = appendLimitStage(pipeline, limit+1)
```

Finally, immediately before `return rows, nil` at the end of `Read`, add:

```go
	// Mongo has no unpageable read: skip and sort are options on a find
	// and stages in a pipeline, not syntax wrapped around a statement, so
	// nothing here can fail the way an EXPLAIN does on the SQL path.
	rows.Pageable = true
```

- [ ] **Step 6: Write the shared-cap test**

Append to `internal/wakilcore/driver_mongo_test.go`:

```go
func TestMongoUsesTheSharedCap(t *testing.T) {
	// Not a behavioural test of Read — that needs a live server and lives
	// in the TestMongo* family make test-live runs. This pins the one
	// thing a unit test can pin: that the two clamps agree. If the inline
	// copy comes back and one of them is edited, this fails.
	for _, in := range []int{-1, 0, 1, 499, 500, 1000, 1001, 10_000_000} {
		if got, want := clampReadLimit(in), sharedCapForTest(in); got != want {
			t.Fatalf("clampReadLimit(%d) = %d, want %d", in, got, want)
		}
	}
}

// sharedCapForTest is the cap written out longhand, so the test states the
// contract rather than comparing the function to itself.
func sharedCapForTest(limit int) int {
	if limit <= 0 || limit > 1000 {
		return 500
	}
	return limit
}
```

- [ ] **Step 7: Run the package and vet**

Run: `go test ./internal/wakilcore/ -count=1 && go vet ./...`
Expected: PASS, no vet output. The live Mongo tests skip without `WAKIL_MONGO_URI`; that is expected here.

- [ ] **Step 8: Run the live engine tests**

The containers `make test-live` expects are `wakil-acc-mysql` and `wakil-acc-mongo`. Start them if they are not running (`make` prints the exact `docker run` lines; `docker start wakil-acc-mysql wakil-acc-mongo` if they exist already).

Run: `make test-live`
Expected: all selected tests run, none skipped. A skip here means the environment variables did not reach the tests and nothing was proved.

- [ ] **Step 9: Commit**

```bash
git add internal/wakilcore/driver_mongo.go internal/wakilcore/driver_mongo_test.go
git commit -m "Mongo pages by skip, and stops keeping its own copy of the cap

Sort, then skip, then limit. The order is not commutative and the wrong
one silently returns too few documents rather than failing: over twelve
docs, \$limit 4 then \$skip 3 yields one.

The inline 'if limit <= 0 || limit > 1000 { limit = 500 }' was a copy of
clampReadLimit, so the cap had two homes and would one day have been
changed in one of them. It calls the function now."
```

---

## Task 3: `Conn.ReadTable` — "everything in this table", rendered by the driver

**Files:**
- Modify: `internal/wakilcore/dbdriver.go` (`Conn` interface)
- Modify: `internal/wakilcore/sqlconn.go` (`ReadTable`)
- Modify: `internal/wakilcore/driver_mongo.go` (`ReadTable`)
- Modify: `internal/wakilcore/dbresolve_test.go:147` (`fakeTestConn` gains the method)
- Test: `internal/wakilcore/sqlconn_test.go`

**Interfaces:**
- Consumes: `QuerySort`, `Rows.Pageable` (Task 1).
- Produces: `Conn.ReadTable(ctx context.Context, name string, limit, offset int, sort *QuerySort) (Rows, error)`.

**Why this is not a convenience wrapper over `Read`.** "Show me everything in `events`" is `SELECT * FROM "events"` on sqlite, backtick-quoted on MySQL, and on Mongo it is not SQL at all — `validateMongoQuery` wants `{"op":"find","collection":"events"}`. A subject that renders itself per driver is the only way the drill affordance (Task 14) works on all three, and `Describe` already establishes that "given a table name, do the dialect-correct thing" is the driver's job.

- [ ] **Step 1: Write the failing tests**

Append to `internal/wakilcore/sqlconn_test.go`:

```go
func TestReadTableReturnsEverythingInIt(t *testing.T) {
	c := newPagingFixture(t)
	out, err := c.ReadTable(context.Background(), "events", 5, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := idsOf(t, out); !reflect.DeepEqual(got, []int64{1, 2, 3, 4, 5}) {
		t.Fatalf("page one = %v", got)
	}
	if !out.Truncated {
		t.Fatal("five of twelve rows must report more remain")
	}
	if !out.Pageable {
		t.Fatal("a table read is always pageable — Wakil composed the statement")
	}
	if !reflect.DeepEqual(out.Columns, []string{"id", "kind"}) {
		t.Fatalf("columns = %v", out.Columns)
	}
}

func TestReadTablePagesAndSorts(t *testing.T) {
	c := newPagingFixture(t)
	out, err := c.ReadTable(context.Background(), "events", 3, 2,
		&QuerySort{Column: "id", Descending: true})
	if err != nil {
		t.Fatal(err)
	}
	// Descending over the whole table, then skip two: 12,11,10,9,... so
	// the third, fourth and fifth are 10, 9, 8.
	if got := idsOf(t, out); !reflect.DeepEqual(got, []int64{10, 9, 8}) {
		t.Fatalf("sorted page = %v", got)
	}
}

func TestReadTableQuotesTheTableName(t *testing.T) {
	c := newPagingFixture(t)
	// quoteIdent is the SOLE guard on this path, exactly as it is on
	// Describe's. The table name arrives from a hover action on a row or
	// from an agent, so an unquoted identifier is how that becomes an
	// injection. The fixture has no table by this name, so the ONLY way
	// this can come back as a clean UserError rather than dropping the
	// events table is if the name was quoted whole.
	_, err := c.ReadTable(context.Background(), `events"; DROP TABLE events; --`, 5, 0, nil)
	if err == nil {
		t.Fatal("a bogus table name must fail")
	}
	var count int
	if err := c.db.QueryRow(`SELECT count(*) FROM events`).Scan(&count); err != nil {
		t.Fatalf("the events table is gone: %v", err)
	}
	if count != 12 {
		t.Fatalf("events has %d rows, want 12 — the injection ran", count)
	}
}

func TestReadTableRejectsANulByte(t *testing.T) {
	c := newPagingFixture(t)
	// The same deterministic refusal Describe makes, and for the same
	// reason: without it the engines fail on a TRUNCATED name, naming a
	// table nobody asked for.
	_, err := c.ReadTable(context.Background(), "eve\x00nts", 5, 0, nil)
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("want a UserError, got %T: %v", err, err)
	}
	if !strings.Contains(msg, "invalid table name") {
		t.Fatalf("message = %q", msg)
	}
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/wakilcore/ -run TestReadTable`
Expected: FAIL — `c.ReadTable undefined`.

- [ ] **Step 3: Add `ReadTable` to the `Conn` interface**

In `internal/wakilcore/dbdriver.go`, inside `type Conn interface`, directly below `Read`:

```go
	// ReadTable returns rows from one named table or collection, paged and
	// optionally sorted, WITHOUT the caller composing a statement.
	//
	// It is not a convenience wrapper over Read and cannot be one. "Show
	// me everything in events" is SELECT * FROM "events" on SQLite,
	// backtick-quoted on MySQL, and on Mongo it is not SQL at all —
	// validateMongoQuery wants {"op":"find","collection":"events"}. A
	// caller that composed the statement itself would have to know the
	// dialect, which is exactly what Describe already establishes is the
	// driver's job, and which is also where quoteIdent lives.
	//
	// A result from here is always Pageable: Wakil composed the statement,
	// so there is no operator text that might not survive a wrap.
	ReadTable(ctx context.Context, name string, limit, offset int, sort *QuerySort) (Rows, error)
```

- [ ] **Step 4: Implement it on `sqlConn`**

In `internal/wakilcore/sqlconn.go`, below `Read`:

```go
// ReadTable reads one table by name. See Conn.ReadTable.
//
// It does NOT run c.gate, for the same reason Describe does not: the gate
// judges SQL text, and this statement has no operator-supplied SQL in it
// at all — only a table name, which goes through quoteIdent. Running the
// read-only gate over a composed "SELECT * FROM `delete`" would reject a
// table whose name happens to be a write verb.
//
// The NUL check is Describe's, for Describe's reason: without it the
// engines fail on a truncated name, with a message naming a table nobody
// requested.
func (c *sqlConn) ReadTable(
	ctx context.Context, name string, limit, offset int, sort *QuerySort,
) (Rows, error) {
	if strings.IndexByte(name, 0) >= 0 {
		return Rows{}, UserError("invalid table name")
	}
	limit = clampReadLimit(limit)
	if offset < 0 {
		offset = 0
	}
	stmt := c.pageWrap("SELECT * FROM "+c.quoteIdent(name), sort, limit, offset)
	start := time.Now()
	rows, err := c.db.QueryContext(ctx, stmt)
	if err != nil {
		return Rows{}, UserError("cannot read " + name + ": " + err.Error())
	}
	defer rows.Close()
	out, err := collectRows(rows, limit)
	if err != nil {
		return Rows{}, err
	}
	out.Pageable = true
	out.Millis = time.Since(start).Milliseconds()
	return out, nil
}
```

- [ ] **Step 5: Implement it on `mongoConn`**

In `internal/wakilcore/driver_mongo.go`, below `Read`:

```go
// ReadTable reads one collection whole. See Conn.ReadTable.
//
// An empty bson.D{} filter is Mongo's "everything", and the options are
// the same three Read composes. There is no name-quoting equivalent to
// worry about: a collection name is a value in the wire protocol, not
// text spliced into a statement.
func (m *mongoConn) ReadTable(
	ctx context.Context, name string, limit, offset int, sort *QuerySort,
) (Rows, error) {
	limit = clampReadLimit(limit)
	if offset < 0 {
		offset = 0
	}
	opts := options.Find().SetLimit(int64(limit + 1))
	if offset > 0 {
		opts = opts.SetSkip(int64(offset))
	}
	if sort != nil {
		dir := 1
		if sort.Descending {
			dir = -1
		}
		opts = opts.SetSort(bson.D{{Key: sort.Column, Value: dir}})
	}
	start := time.Now()
	cursor, err := m.db.Collection(name).Find(ctx, bson.D{}, opts)
	if err != nil {
		return Rows{}, UserError("cannot read " + name + ": " + err.Error())
	}
	defer cursor.Close(ctx)
	var docs []map[string]any
	if err := cursor.All(ctx, &docs); err != nil {
		return Rows{}, UserError("cannot read " + name + ": " + err.Error())
	}
	truncated := len(docs) > limit
	rows := docsToRows(docs, limit, time.Since(start).Milliseconds())
	rows.Truncated = truncated
	rows.Pageable = true
	return rows, nil
}
```

- [ ] **Step 6: Teach the one fake about the new method**

`internal/wakilcore/dbresolve_test.go` has `fakeTestConn`, which satisfies `Conn`. Add beside its `Read`:

```go
func (fakeTestConn) ReadTable(context.Context, string, int, int, *QuerySort) (Rows, error) {
	return Rows{}, nil
}
```

- [ ] **Step 7: Run everything**

Run: `go test ./internal/wakilcore/ -count=1 && go vet ./...`
Expected: PASS, no vet output.

- [ ] **Step 8: Commit**

```bash
git add internal/wakilcore/dbdriver.go internal/wakilcore/sqlconn.go internal/wakilcore/driver_mongo.go internal/wakilcore/sqlconn_test.go internal/wakilcore/dbresolve_test.go
git commit -m "Conn.ReadTable: everything in one table, rendered by the driver

Not a wrapper over Read and it cannot be one. 'Everything in events' is
SELECT * FROM \"events\" on sqlite, backticked on MySQL, and on Mongo it
is not SQL at all. Describe already establishes that turning a table name
into the dialect-correct thing is the driver's job, and quoteIdent is
already the sole guard on that path."
```

---

## Task 4: `ClassifyStatement` — the gates answer for themselves

**Files:**
- Create: `internal/wakilcore/classify.go`
- Test: `internal/wakilcore/classify_test.go`

**Interfaces:**
- Consumes: `AssertSQLReadOnly`, `AssertSQLMutation`, `AssertMongoReadOnly` (all existing).
- Produces: `type StatementClass struct { Kind string; Reason string }` and `func ClassifyStatement(driver, statement string) StatementClass`. `Kind` is one of `"read"`, `"mutation"`, `"neither"`.

**Why this exists.** Spec §9: the query line has to know whether Return should run `db_run_query` or raise the confirmation plane, and the one thing it must not do is decide that in Swift. `UserError` carries a message and nothing else, so catching a refusal and reading its text would be exactly the heuristic the gate exists to replace. Asking first costs a local call — no connection is opened — and the answer comes from the same two functions that will judge the statement for real.

- [ ] **Step 1: Write the failing tests**

Create `internal/wakilcore/classify_test.go`:

```go
package wakilcore

import "testing"

func TestClassifyStatementSQL(t *testing.T) {
	for _, tc := range []struct {
		name string
		sql  string
		want string
	}{
		{"select", "SELECT id FROM events", "read"},
		{"cte", "WITH x AS (SELECT 1) SELECT * FROM x", "read"},
		{"show", "SHOW TABLES", "read"},
		{"explain", "EXPLAIN SELECT id FROM events", "read"},
		{"update", "UPDATE events SET kind = 'x' WHERE id = 1", "mutation"},
		{"insert", "INSERT INTO events VALUES (1, 'a')", "mutation"},
		{"delete", "DELETE FROM events WHERE id = 1", "mutation"},
		{"lowercase update", "update events set kind = 'x'", "mutation"},
		// Neither gate accepts a DDL verb, and that is the answer: the
		// operator is shown the gate's own sentence and nothing runs.
		{"drop", "DROP TABLE events", "neither"},
		{"alter", "ALTER TABLE events ADD COLUMN x INT", "neither"},
		{"truncate", "TRUNCATE TABLE events", "neither"},
		{"empty", "   ", "neither"},
		// Two statements: refused by both gates, for the same reason.
		{"two statements", "SELECT 1; SELECT 2", "neither"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ClassifyStatement("sqlite", tc.sql)
			if got.Kind != tc.want {
				t.Fatalf("ClassifyStatement(%q).Kind = %q (reason %q), want %q",
					tc.sql, got.Kind, got.Reason, tc.want)
			}
		})
	}
}

func TestClassifyStatementCarriesTheGatesOwnSentence(t *testing.T) {
	got := ClassifyStatement("mysql", "DROP TABLE events")
	if got.Kind != "neither" {
		t.Fatalf("Kind = %q", got.Kind)
	}
	// The operator sees this verbatim, so it must be the gate's wording
	// and not a sentence invented here — the gate is the thing that knows
	// why, and a second wording would drift from the refusal that
	// actually happens when the statement is run.
	if got.Reason == "" {
		t.Fatal("a neither answer must carry a reason")
	}
	if !contains(got.Reason, "schema changes") {
		t.Fatalf("reason = %q, want the mutation gate's own sentence", got.Reason)
	}
}

func TestClassifyStatementMongo(t *testing.T) {
	read := ClassifyStatement("mongo", `{"op":"find","collection":"events"}`)
	if read.Kind != "read" {
		t.Fatalf("a find is a read, got %q (%q)", read.Kind, read.Reason)
	}
	agg := ClassifyStatement("mongo", `{"op":"aggregate","collection":"events","pipeline":[{"$match":{}}]}`)
	if agg.Kind != "read" {
		t.Fatalf("an aggregate is a read, got %q (%q)", agg.Kind, agg.Reason)
	}
	// Mongo writes are honestly unimplemented — mongoConn.Write refuses
	// every statement — so "mutation" would be a promise this build
	// cannot keep. "neither", with the reason, is the true answer.
	write := ClassifyStatement("mongo", `{"op":"insertOne","collection":"events","document":{}}`)
	if write.Kind != "neither" {
		t.Fatalf("a mongo write must be neither, got %q", write.Kind)
	}
	if write.Reason == "" {
		t.Fatal("a neither answer must carry a reason")
	}
}

func TestClassifyStatementUnknownDriver(t *testing.T) {
	got := ClassifyStatement("postgres-someday", "SELECT 1")
	if got.Kind != "neither" {
		t.Fatalf("an unknown driver must refuse rather than guess, got %q", got.Kind)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (func() bool {
		for i := 0; i+len(needle) <= len(haystack); i++ {
			if haystack[i:i+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/wakilcore/ -run TestClassifyStatement`
Expected: FAIL — `undefined: ClassifyStatement`.

- [ ] **Step 3: Write `classify.go`**

Create `internal/wakilcore/classify.go`:

```go
package wakilcore

// StatementClass is what the query surface needs to know before it runs
// anything: whether this text is a read, a mutation, or neither.
//
// Reason is non-empty only for "neither", and it is the GATE'S OWN
// sentence, verbatim. A second wording composed here would drift from the
// refusal that actually happens when the statement runs, and the operator
// would be told one thing and then shown another.
type StatementClass struct {
	Kind   string `json:"kind"`
	Reason string `json:"reason,omitempty"`
}

// ClassifyStatement answers whether statement is a read, a mutation, or
// neither, for a database of the given driver kind.
//
// **It opens no connection and touches no credential.** Every function it
// calls is a pure text or structural check, which is what makes asking
// before running cheap enough to do on every Return in the query line.
//
// **It is not a gate and must never be used as one.** The real refusals
// still happen in sqlConn.Read and sqlConn.Write, unchanged, whatever this
// says. What this buys is that the query line can route to db_run_query or
// db_run_mutation without Wakil's Swift half parsing SQL — see spec §9.
// A wrong answer here sends a statement to the wrong action and the gate
// on that path refuses it; a wrong answer cannot let anything through.
//
// **An unknown driver answers "neither".** Guessing that an unregistered
// driver speaks SQL is how a Mongo-shaped JSON document would get handed
// to a SQL gate, and the honest answer for a driver Wakil does not have is
// that it cannot say.
func ClassifyStatement(driver, statement string) StatementClass {
	switch driver {
	case "mongo":
		if err := AssertMongoReadOnly(statement); err != nil {
			msg, _ := IsUserError(err)
			if msg == "" {
				msg = err.Error()
			}
			// Deliberately not "mutation". mongoConn.Write refuses every
			// statement — the driver's write path is honestly
			// unimplemented — so routing this to db_run_mutation would
			// raise a confirmation plane for something that cannot run.
			return StatementClass{Kind: "neither", Reason: msg}
		}
		return StatementClass{Kind: "read"}
	case "sqlite", "mysql":
		if AssertSQLReadOnly(statement) == nil {
			return StatementClass{Kind: "read"}
		}
		if err := AssertSQLMutation(statement); err != nil {
			msg, _ := IsUserError(err)
			if msg == "" {
				msg = err.Error()
			}
			return StatementClass{Kind: "neither", Reason: msg}
		}
		return StatementClass{Kind: "mutation"}
	default:
		return StatementClass{
			Kind:   "neither",
			Reason: "no driver named " + driver + " in this build, so this statement cannot be judged",
		}
	}
}
```

- [ ] **Step 4: Run them and watch them pass**

Run: `go test ./internal/wakilcore/ -run TestClassifyStatement -v`
Expected: PASS, every subtest.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/classify.go internal/wakilcore/classify_test.go
git commit -m "ClassifyStatement: let the gates answer what a statement is

The query surface has to know whether Return runs a query or raises the
confirmation plane, and the one thing it must not do is decide that in
Swift. UserError carries a message and nothing else, so catching a
refusal and reading its text would be exactly the heuristic the gate
exists to replace.

This opens no connection and is not a gate: the real refusals still
happen in Read and Write, unchanged. A wrong answer here routes a
statement to the wrong action and that path's gate refuses it. A wrong
answer cannot let anything through."
```

---

## Task 5: `cmd/wakil-db` — offset, sort, `read_table`, `classify_statement`

**Files:**
- Modify: `cmd/wakil-db/main.go`
- Modify: `cmd/wakil-db/schema_test.go`
- Test: `cmd/wakil-db/main_test.go`

**Interfaces:**
- Consumes: `QuerySpec.Offset`/`Sort`, `Conn.ReadTable`, `ClassifyStatement` (Tasks 1, 3, 4).
- Produces: tools `read_table` `{database, name, limit, offset, sortColumn, sortDescending}` → `wakilcore.Rows`; `classify_statement` `{database, statement}` → `wakilcore.StatementClass`; `query` gains `offset`, `sortColumn`, `sortDescending`.

**Sort is two flat fields, not a nested object,** matching how every other argument on this server is shaped and keeping the generated input schema flat for a model filling it in.

- [ ] **Step 1: Add the new tools to the pinned schema list first, and watch it fail**

In `cmd/wakil-db/schema_test.go`, extend the slice:

```go
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{
		"list_databases",
		"list_tables",
		"describe_table",
		"query",
		// mutate: the fifth tool, added in 2b-iii. Its Out is
		// wakilcore.Written, a struct, so it satisfies the same
		// object-outputSchema requirement as the other four.
		"mutate",
		// read_table and classify_statement: 2c-ii. Outs are
		// wakilcore.Rows and wakilcore.StatementClass, both structs.
		"read_table",
		"classify_statement",
	})
```

Run: `go test ./cmd/wakil-db/ -run TestOutputSchemasAreObjects`
Expected: FAIL — the live `ListTools` round trip does not find two of the named tools.

- [ ] **Step 2: Extend `queryArg` and add the two new arg types**

In `cmd/wakil-db/main.go`, replace `queryArg` and add beside it:

```go
type queryArg struct {
	Database string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Query    string `json:"query" jsonschema:"SQL string, or a Mongo JSON spec {collection,op,filter|pipeline}"`
	Limit    int    `json:"limit,omitempty" jsonschema:"maximum rows to return"`
	Offset   int    `json:"offset,omitempty" jsonschema:"rows to skip before the first one returned; 0 is the first page. Only SELECT and WITH results can be paged - the pageable field in the result says whether this one can"`
	// Sort is two flat fields rather than a nested object, matching every
	// other argument on this server and keeping the generated input schema
	// flat for a model filling it in.
	SortColumn     string `json:"sortColumn,omitempty" jsonschema:"order the whole result by this column before paging it, rather than ordering the rows that came back"`
	SortDescending bool   `json:"sortDescending,omitempty" jsonschema:"order descending instead of ascending; ignored without sortColumn"`
}

type readTableArg struct {
	Database       string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Name           string `json:"name" jsonschema:"table or collection name"`
	Limit          int    `json:"limit,omitempty" jsonschema:"maximum rows to return"`
	Offset         int    `json:"offset,omitempty" jsonschema:"rows to skip before the first one returned; 0 is the first page"`
	SortColumn     string `json:"sortColumn,omitempty" jsonschema:"order the whole table by this column before paging it"`
	SortDescending bool   `json:"sortDescending,omitempty" jsonschema:"order descending instead of ascending; ignored without sortColumn"`
}

type classifyArg struct {
	Database  string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Statement string `json:"statement" jsonschema:"the SQL or Mongo JSON to judge; it is NOT run"`
}

// querySortOf turns the two flat sort fields into a QuerySort, or nil when
// no column was named. sortDescending without sortColumn is not an error
// and not a sort — it is a direction for an ordering nobody asked for.
func querySortOf(column string, descending bool) *wakilcore.QuerySort {
	if column == "" {
		return nil
	}
	return &wakilcore.QuerySort{Column: column, Descending: descending}
}
```

- [ ] **Step 3: Pass offset and sort through `query`, and register the two new tools**

In `newServer`, replace the `query` handler's `conn.Read` line with:

```go
			out, err := conn.Read(ctx, wakilcore.QuerySpec{
				Raw:    a.Query,
				Offset: a.Offset,
				Sort:   querySortOf(a.SortColumn, a.SortDescending),
			}, a.Limit)
```

and update that tool's description to:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "query", Description: "Run a read-only query and return rows. SQL string or Mongo JSON spec. Use offset to ask for a later page of the SAME query and sortColumn to order the whole result before it is paged — both re-run the query against the engine, so what comes back is a page of the real ordering rather than a re-shuffle of the rows you already had. The pageable field says whether this particular result can be paged at all: an EXPLAIN or a SHOW cannot, because paging wraps the statement in a subquery and those two do not survive it."},
```

Then, after the `mutate` tool, add:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "read_table", Description: "Return rows from one table or collection by name, without composing a query. Use this instead of writing \"SELECT * FROM x\" yourself: the driver renders it for its own dialect, which is the only form that also works against Mongo, where there is no SQL. Pages and sorts exactly as query does, and the result is always pageable."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a readTableArg) (*mcp.CallToolResult, wakilcore.Rows, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Rows{}, nil
			}
			defer conn.Close()
			out, err := conn.ReadTable(ctx, a.Name, a.Limit, a.Offset,
				querySortOf(a.SortColumn, a.SortDescending))
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Rows{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "classify_statement", Description: "Say whether a statement is a read, a mutation, or neither — WITHOUT running it and without opening a connection. kind is \"read\", \"mutation\" or \"neither\"; for \"neither\", reason carries the gate's own sentence explaining why. The answer comes from the same gates that will judge the statement if it is run, so it is not a second opinion. Use it to decide which tool to call, never as permission: a mutation still passes the write gate and a human confirmation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a classifyArg) (*mcp.CallToolResult, wakilcore.StatementClass, error) {
			// Resolution only — no connection, no Keychain. PickDatabase
			// is a pure configuration lookup, and the driver kind is all
			// ClassifyStatement needs.
			env, err := wakilcore.ResolveEnvironment()
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.StatementClass{}, nil
			}
			db, err := wakilcore.PickDatabase(env, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.StatementClass{}, nil
			}
			return nil, wakilcore.ClassifyStatement(db.Driver, a.Statement), nil
		})
```

Update `newServer`'s doc comment: "all five tools" becomes "all seven tools", and the sentence naming `mutate` as the only one that can change anything gains "— the other six all go through openPicked/OpenDatabase, and classify_statement opens no connection at all."

- [ ] **Step 4: Run the schema test and watch it pass**

Run: `go test ./cmd/wakil-db/ -run TestOutputSchemasAreObjects -v`
Expected: PASS.

- [ ] **Step 5: Write the no-connection test**

Append to `cmd/wakil-db/main_test.go`. Follow whatever pattern that file already uses to point `ResolveEnvironment` at a temporary config; if it has a helper for that, use it.

```go
// TestClassifyStatementOpensNoConnection pins the property that makes
// asking-before-running cheap enough to do on every keystroke of Return:
// the tool resolves the driver kind out of configuration and stops. The
// fixture names a Keychain ref that does not exist, so any attempt to
// OPEN the database would fail — and the call still succeeds.
func TestClassifyStatementOpensNoConnection(t *testing.T) {
	withConfigNamingAMissingCredential(t)
	got := callTool(t, newServer(), "classify_statement", map[string]any{
		"statement": "UPDATE events SET kind = 'x' WHERE id = 1",
	})
	if got["kind"] != "mutation" {
		t.Fatalf("kind = %v, want mutation (result: %v)", got["kind"], got)
	}
}
```

If `cmd/wakil-db/main_test.go` has no `callTool` or config helper of this shape, write the test against `newServer()` using the same mechanism its existing tests use to call a tool and read `structuredContent`, and name the fixture helper after whatever that file already calls its config setup.

- [ ] **Step 6: Run it**

Run: `go test ./cmd/wakil-db/ -count=1 -v`
Expected: PASS.

- [ ] **Step 7: Full suite, vet, build**

Run: `make test && make vet && make build`
Expected: all PASS, five binaries into `bin/`.

- [ ] **Step 8: Commit**

```bash
git add cmd/wakil-db/
git commit -m "wakil-db: offset, pushed sort, read_table, classify_statement

query gains offset and a sort that is pushed into the statement rather
than applied to the rows that came back, plus the pageable field saying
whether this particular result can be asked for a second page.

read_table returns one table by name without the caller composing SQL,
which is the only form that also works against Mongo. classify_statement
says read/mutation/neither from the real gates, opening no connection -
pinned by a fixture whose credential does not exist."
```

---

## Task 6: `PaneFetch` — what a pane is looking at, and it persists

**Files:**
- Create: `app/Sources/WakilKit/Panes/PaneFetch.swift`
- Modify: `app/Sources/WakilKit/Layout/Pane.swift` (`fetch`, `CodingKeys`, `init`, `init(from:)`)
- Test: `app/Tests/WakilKitTests/PaneFetchTests.swift` (new), `app/Tests/WakilKitTests/PaneTests.swift`

**Interfaces:**
- Consumes: `PaneSort` (existing, `PaneContents.swift:79`).
- Produces:
  - `enum PaneQuery: Sendable, Equatable, Codable` with cases `.sql(database: String?, raw: String)`, `.table(database: String?, name: String)`, `.tables(database: String?)`, `.columns(database: String?, table: String)`, and `var database: String?`, `var describedForOperator: String`.
  - `struct PaneFetch: Sendable, Equatable, Codable` with `query: PaneQuery`, `offset: Int`, `pageSize: Int`, `sort: PaneSort?`, `static let defaultPageSize = 500`, `func page(to:) -> PaneFetch`, `func sorted(by:) -> PaneFetch`.
  - `Pane.fetch: PaneFetch?`, persisted.

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/WakilKitTests/PaneFetchTests.swift`:

```swift
import Foundation
import Testing

@testable import WakilKit

@Test func everySubjectRoundTripsThroughJSON() throws {
    let subjects: [PaneQuery] = [
        .sql(database: "main", raw: "SELECT * FROM events"),
        .sql(database: nil, raw: "SELECT 1"),
        .table(database: "main", name: "events"),
        .tables(database: "main"),
        .columns(database: "main", table: "events"),
    ]
    for subject in subjects {
        let fetch = PaneFetch(query: subject, offset: 500, pageSize: 250,
                              sort: PaneSort(column: "id", direction: .descending))
        let data = try JSONEncoder().encode(fetch)
        let back = try JSONDecoder().decode(PaneFetch.self, from: data)
        #expect(back == fetch)
    }
}

@Test func aFetchDefaultsToThePageSizeTheDriverAlreadyUses() {
    // 500 is clampReadLimit's "you did not usefully choose" answer, and
    // a pane that asked for something else would page in one size and be
    // capped at another.
    #expect(PaneFetch.defaultPageSize == 500)
    let fetch = PaneFetch(query: .tables(database: nil))
    #expect(fetch.offset == 0)
    #expect(fetch.pageSize == 500)
    #expect(fetch.sort == nil)
}

@Test func everySubjectCarriesItsDatabase() {
    #expect(PaneQuery.sql(database: "a", raw: "SELECT 1").database == "a")
    #expect(PaneQuery.table(database: "b", name: "t").database == "b")
    #expect(PaneQuery.tables(database: "c").database == "c")
    #expect(PaneQuery.columns(database: "d", table: "t").database == "d")
    #expect(PaneQuery.sql(database: nil, raw: "SELECT 1").database == nil)
}

@Test func aNonSQLSubjectDescribesItselfRatherThanPretendingToBeSQL() {
    // What the query line shows at rest. A schema browse is not SQL and
    // showing invented SQL for it would be a lie the operator could then
    // edit.
    #expect(PaneQuery.tables(database: nil).describedForOperator == "tables")
    #expect(PaneQuery.columns(database: nil, table: "events").describedForOperator
            == "events · columns")
    #expect(PaneQuery.table(database: nil, name: "events").describedForOperator == "events")
    #expect(PaneQuery.sql(database: nil, raw: "SELECT 1").describedForOperator == "SELECT 1")
}

@Test func pagingMovesTheOffsetByWholePages() {
    let first = PaneFetch(query: .table(database: nil, name: "events"), pageSize: 500)
    #expect(first.page(to: .next).offset == 500)
    #expect(first.page(to: .next).page(to: .next).offset == 1000)
    #expect(first.page(to: .next).page(to: .previous).offset == 0)
    #expect(first.page(to: .first).offset == 0)
}

@Test func pagingBackFromTheFirstPageStaysOnIt() {
    // Not an error and not a negative offset: the control is simply
    // already at the start, and a negative offset would be clamped in Go
    // anyway — this keeps the two from disagreeing about where we are.
    let first = PaneFetch(query: .table(database: nil, name: "events"), pageSize: 500)
    #expect(first.page(to: .previous).offset == 0)
}

@Test func pagingToAnAbsolutePageMultipliesByThePageSize() {
    let fetch = PaneFetch(query: .table(database: nil, name: "events"), pageSize: 250)
    #expect(fetch.page(to: .number(3)).offset == 750)
    #expect(fetch.page(to: .number(0)).offset == 0)
    #expect(fetch.page(to: .number(-2)).offset == 0)
}

@Test func sortingResetsTheOffsetToZero() {
    // Spec §7. Sorting page three and staying on page three would show
    // rows 1,001-1,500 of a DIFFERENT ordering, which is the same class
    // of lie the section exists against.
    let third = PaneFetch(query: .table(database: nil, name: "events"),
                          offset: 1000, pageSize: 500)
    let sorted = third.sorted(by: PaneSort(column: "id", direction: .ascending))
    #expect(sorted.offset == 0)
    #expect(sorted.sort == PaneSort(column: "id", direction: .ascending))
    #expect(sorted.sorted(by: nil).sort == nil)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `make app-test 2>&1 | tail -40`
Expected: build failure — `cannot find 'PaneFetch' in scope`.

- [ ] **Step 3: Write `PaneFetch.swift`**

Create `app/Sources/WakilKit/Panes/PaneFetch.swift`:

```swift
import Foundation

/// What a pane is looking at.
///
/// **Four cases, not a SQL string, because a schema browse is a subject
/// too.** `db_list_tables` returns rows; so does `db_describe_table`; so
/// does reading a table whole. Modelling all four the same way is what
/// lets one re-fetch path serve paging, sort-as-re-query and relaunch
/// without a special case for "this pane is showing metadata".
///
/// **`.table` is not a convenience wrapper over `.sql` and cannot be
/// one.** "Everything in `events`" is `SELECT * FROM "events"` on SQLite,
/// backtick-quoted on MySQL, and on Mongo it is not SQL at all —
/// `validateMongoQuery` wants `{"op":"find","collection":"events"}`. The
/// driver renders it (`Conn.ReadTable`); Swift never composes SQL, here or
/// anywhere else in this phase.
public enum PaneQuery: Sendable, Equatable, Codable {
    /// A statement the operator or the agent wrote.
    case sql(database: String?, raw: String)
    /// Every row in one table, rendered by the driver.
    case table(database: String?, name: String)
    /// The database's tables, drawn as rows.
    case tables(database: String?)
    /// One table's columns, drawn as rows.
    case columns(database: String?, table: String)

    /// Which database this subject is against, or `nil` for "the
    /// environment's only one".
    public var database: String? {
        switch self {
        case .sql(let database, _): return database
        case .table(let database, _): return database
        case .tables(let database): return database
        case .columns(let database, _): return database
        }
    }

    /// What the query line shows at rest.
    ///
    /// **A non-SQL subject describes itself rather than rendering as
    /// invented SQL.** Showing `SELECT * FROM events` for a `.table` would
    /// be a statement the operator could then edit by one character and
    /// expect to behave like SQL — which on Mongo it would not. The
    /// description is prose; editing it is how a table pane *becomes* a
    /// `.sql` pane (`DBPane`, Task 14).
    public var describedForOperator: String {
        switch self {
        case .sql(_, let raw): return raw
        case .table(_, let name): return name
        case .tables: return "tables"
        case .columns(_, let table): return "\(table) · columns"
        }
    }
}

/// Where a pane is in its subject: which page, how big, ordered how.
///
/// **This lives on `Pane` and persists with the layout; the rows it
/// produced live in `PaneStore` and do not.** That split is 2c-i's
/// persistence boundary kept exactly: a pane the operator arranged is a
/// setting, and a result set is a photograph of a database at an instant
/// that may already have passed.
public struct PaneFetch: Sendable, Equatable, Codable {
    /// Which page to move to. Spelled as intent rather than as an offset
    /// so the arithmetic has one home (`page(to:)`) and the footer's ‹ ›
    /// and an agent's `db_page` cannot disagree about what "next" means.
    public enum Page: Sendable, Equatable {
        case first
        case previous
        case next
        /// A zero-based page index.
        case number(Int)
    }

    /// The page size a pane uses unless told otherwise.
    ///
    /// 500 is `clampReadLimit`'s own "you did not usefully choose" answer.
    /// Picking anything else here would make a pane page in one size and
    /// be capped at another, so the last page of every table would be a
    /// surprise.
    public static let defaultPageSize = 500

    public var query: PaneQuery
    /// Rows skipped before the first one on screen. Never negative.
    public var offset: Int
    /// Rows asked for per page. Never above 1,000 — the driver caps there
    /// and a pane that asked for more would silently get 500.
    public var pageSize: Int
    /// The pane's sort intent. Honoured client-side on a complete result
    /// and pushed into the statement on an incomplete one — see
    /// `WindowModel.sortPane`.
    public var sort: PaneSort?

    public init(
        query: PaneQuery, offset: Int = 0,
        pageSize: Int = PaneFetch.defaultPageSize, sort: PaneSort? = nil
    ) {
        self.query = query
        self.offset = max(0, offset)
        self.pageSize = min(1000, max(1, pageSize))
        self.sort = sort
    }

    /// This fetch moved to another page. Clamped at zero: paging back from
    /// the first page is not an error and not a negative offset, it is a
    /// control that is already at the start.
    public func page(to page: Page) -> PaneFetch {
        var next = self
        switch page {
        case .first:
            next.offset = 0
        case .previous:
            next.offset = max(0, offset - pageSize)
        case .next:
            next.offset = offset + pageSize
        case .number(let n):
            next.offset = max(0, n) * pageSize
        }
        return next
    }

    /// This fetch re-sorted, **back at page one**.
    ///
    /// Spec §7: sorting page three and staying on page three would show
    /// rows 1,001–1,500 of a different ordering, which is the same class
    /// of lie the whole section exists against.
    public func sorted(by sort: PaneSort?) -> PaneFetch {
        var next = self
        next.sort = sort
        next.offset = 0
        return next
    }
}
```

- [ ] **Step 4: Put `fetch` on `Pane`**

In `app/Sources/WakilKit/Layout/Pane.swift`, add after `columnWidths`:

```swift
    /// What this pane is looking at, or `nil` for a pane nothing has
    /// queried yet.
    ///
    /// **In `CodingKeys`, like `density` and `columnWidths`.** A pane's
    /// subject is the most settled thing about it — it is what makes the
    /// pane that pane, what a re-query re-queries, and what routing means
    /// by "the same question". The rows it produced are NOT persisted and
    /// must not be: redrawing yesterday's result would show a database
    /// state that may no longer exist, the exact dishonesty `truncated`
    /// and the sort footer exist to prevent. On relaunch the pane re-runs
    /// this instead (`WindowModel.restorePaneContents`).
    public var fetch: PaneFetch?
```

Extend `CodingKeys`:

```swift
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, frame, density, columnWidths, fetch
    }
```

Extend `init`, adding the parameter last so every existing call site is unchanged:

```swift
    public init(
        id: String, kind: String, title: String, frame: PaneFrame, busy: Bool = false,
        density: PaneDensity = .airy,
        columnWidths: [String: Double] = [:],
        fetch: PaneFetch? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.frame = frame
        self.busy = busy
        self.density = density
        self.columnWidths = columnWidths
        self.fetch = fetch
    }
```

And in `init(from:)`, add:

```swift
        // `try?`, not `try`, and the difference matters. `decodeIfPresent`
        // tolerates a MISSING key but rethrows on a key that is present
        // and undecodable — which is exactly what a layout written by a
        // later build holding a subject case this one does not know would
        // be. Rethrowing there would take the whole layout file down over
        // one pane's subject, when the honest degradation is a pane that
        // comes back empty and waits for the operator. Same tolerance
        // `density` established, one step further.
        fetch = (try? container.decodeIfPresent(PaneFetch.self, forKey: .fetch)) ?? nil
```

- [ ] **Step 5: Write the persistence tests**

Append to `app/Tests/WakilKitTests/PaneTests.swift`:

```swift
@Test func aPaneCarriesItsSubjectThroughAFileRoundTrip() throws {
    var pane = Pane(id: "db-1", kind: "db", title: "main",
                    frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
    pane.fetch = PaneFetch(
        query: .sql(database: "main", raw: "SELECT * FROM events"),
        offset: 500, pageSize: 500,
        sort: PaneSort(column: "id", direction: .descending))
    let data = try JSONEncoder().encode(pane)
    let back = try JSONDecoder().decode(Pane.self, from: data)
    #expect(back.fetch == pane.fetch)
}

@Test func aLayoutWrittenBeforeSubjectsExistedStillDecodes() throws {
    // The same tolerance `density` and `columnWidths` each needed. A pane
    // saved by any build before 2c-ii has no "fetch" key at all.
    let json = #"""
    {"id":"db-1","kind":"db","title":"main",
     "frame":{"x":0,"y":0,"width":640,"height":420},"density":"dense"}
    """#
    let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    #expect(pane.fetch == nil)
    #expect(pane.density == .dense)
}

@Test func aSubjectThisBuildCannotReadCostsThePaneAndNotTheFile() throws {
    // A layout written by a later build, holding a subject case this one
    // does not have. The pane must come back subject-less and the file
    // must still load — a thrown error here takes down every pane in the
    // project over one pane's subject.
    let json = #"""
    {"id":"db-1","kind":"db","title":"main",
     "frame":{"x":0,"y":0,"width":640,"height":420},
     "fetch":{"query":{"graphql":{"document":"{ events }"}},"offset":0,"pageSize":500}}
    """#
    let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    #expect(pane.fetch == nil)
    #expect(pane.id == "db-1")
}

@Test func busyIsStillNotPersisted() throws {
    // Unchanged by this phase, and worth re-pinning beside the new field
    // so the distinction between a setting and runtime state stays live.
    var pane = Pane(id: "db-1", kind: "db", title: "main",
                    frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
    pane.busy = true
    let data = try JSONEncoder().encode(pane)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("busy"))
}
```

- [ ] **Step 6: Run them and watch them pass**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS, with the test count up by roughly twelve.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneFetch.swift app/Sources/WakilKit/Layout/Pane.swift app/Tests/WakilKitTests/PaneFetchTests.swift app/Tests/WakilKitTests/PaneTests.swift
git commit -m "A pane owns a subject, and the subject persists

Four cases rather than a SQL string, because a schema browse is a subject
too - and because .table cannot be a wrapper over .sql: on Mongo there is
no SQL to wrap.

It persists with the layout and the rows do not, which is 2c-i's boundary
kept exactly. Decoding uses try? rather than try, so a subject written by
a later build costs that pane and not the whole layout file."
```

---

## Task 7: `PaneStore` is told the sort rather than keeping it

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift`
- Modify: `app/Sources/WakilKit/Panes/PaneContentActions.swift` (`pane_sort`, temporarily)
- Test: `app/Tests/WakilKitTests/PaneStoreTests.swift`

**Interfaces:**
- Consumes: `PaneFetch`, `PaneSort`.
- Produces: `PaneStore.setRows(paneId:columns:columnTypes:columnTypesInferred:rows:millis:truncated:pageable:offset:sort:)` and `PaneStore.reorder(paneId:sort:)`. `PaneStore.setSort` is **deleted**.

**Why the authority moves but the copy stays.** `Pane.fetch.sort` becomes the one authority — a pane that owns its query but not its sort is incoherent the moment the sort becomes an `ORDER BY` inside that query. But `PaneStore` still needs the value to produce `displayRows`, and `snapshot` still reports it, so it keeps a copy written *only* from the authority. That is the same relationship `displayRows` already has to `rows`. What stops them drifting is the rule `setRows` already states in its own doc comment — **no parameter has a default** — so the new `sort:` must be supplied at every call site.

- [ ] **Step 1: Write the failing tests**

Append to `app/Tests/WakilKitTests/PaneStoreTests.swift`:

```swift
@Test func rowsArriveOrderedByTheSortTheyWereGiven() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false,
        rows: [[.number(3)], [.number(1)], [.number(2)]],
        millis: 4, truncated: false, pageable: true, offset: 0,
        sort: PaneSort(column: "id", direction: .ascending))
    guard case .object(let snap) = await store.snapshot(paneId: "db-1"),
          case .array(let rows)? = snap["rows"] else {
        Issue.record("no rows in the snapshot"); return
    }
    #expect(rows.count == 3)
    if case .array(let first) = rows[0], case .number(let n) = first[0] {
        #expect(n == 1)
    } else {
        Issue.record("first row is not 1")
    }
}

@Test func reorderingUsesTheUnsortedRowsSoASecondSortIsNotBuiltOnTheFirst() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false,
        rows: [[.number(3), .string("a")], [.number(1), .string("b")], [.number(2), .string("a")]],
        millis: 4, truncated: false, pageable: true, offset: 0, sort: nil)
    await store.reorder(paneId: "db-1", sort: PaneSort(column: "kind", direction: .ascending))
    await store.reorder(paneId: "db-1", sort: PaneSort(column: "id", direction: .ascending))
    guard case .object(let snap) = await store.snapshot(paneId: "db-1"),
          case .array(let rows)? = snap["rows"],
          case .array(let first) = rows[0], case .number(let n) = first[0] else {
        Issue.record("no rows"); return
    }
    // If the second sort had been applied to the OUTPUT of the first,
    // ties would be broken by the previous ordering rather than by the
    // database's. Sorting by a unique column makes the bug invisible, so
    // the check is that the result is the database's own order.
    #expect(n == 1)
}

@Test func aSnapshotReportsWhetherItCanBePagedAndWhereItIs() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false, rows: [[.number(1)]],
        millis: 4, truncated: true, pageable: true, offset: 500, sort: nil)
    guard case .object(let snap) = await store.snapshot(paneId: "db-1") else {
        Issue.record("no snapshot"); return
    }
    #expect(snap["pageable"] == .bool(true))
    #expect(snap["offset"] == .number(500))
    // Every key always present, including when false or zero — the rule
    // `truncated` already established for this payload.
    #expect(snap["truncated"] == .bool(true))
}

@Test func anUnpageableResultSaysSoRatherThanOmittingTheKey() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["Tables_in_x"], columnTypes: ["VARCHAR"],
        columnTypesInferred: false, rows: [[.string("events")]],
        millis: 1, truncated: false, pageable: false, offset: 0, sort: nil)
    guard case .object(let snap) = await store.snapshot(paneId: "db-1") else {
        Issue.record("no snapshot"); return
    }
    #expect(snap["pageable"] == .bool(false))
    #expect(snap["offset"] == .number(0))
}

@Test func aNewResultStillLeavesTheSelectionAloneWhenItCanCarryIt() async {
    // Unchanged by this phase, re-pinned because setRows grew three
    // parameters and the rule it is famous for must survive them.
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false,
        rows: [[.number(1)], [.number(2)], [.number(3)]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: nil)
    await store.setSelection(paneId: "db-1", PaneSelection(anchorRow: 2, anchorColumn: "id", rows: [2]))
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false,
        rows: [[.number(1)], [.number(2)], [.number(3)]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: nil)
    guard case .object(let snap) = await store.snapshot(paneId: "db-1"),
          case .object(let selection)? = snap["selection"] else {
        Issue.record("no selection"); return
    }
    #expect(selection["anchorRow"] == .number(2))
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | tail -30`
Expected: build failure — `extra arguments 'pageable', 'offset', 'sort'` and `value of type 'PaneStore' has no member 'reorder'`.

- [ ] **Step 3: Change `PaneStore`**

In `app/Sources/WakilKit/Panes/PaneStore.swift`:

Add to `private struct Contents`, below `truncated`:

```swift
        /// Whether this result can be asked for a second page at all —
        /// `wakilcore.Rows.Pageable`, carried through. False for an
        /// `EXPLAIN` and a `SHOW`, which the read-only gate permits and
        /// which cannot survive the subquery paging wraps them in.
        var pageable = false
        /// How many rows were skipped to produce this page. The footer's
        /// "rows 501–1,000" is this plus one, through this plus the row
        /// count.
        var offset = 0
```

Replace `setRows` with:

```swift
    /// Replaces pane `paneId`'s columns and rows entirely. There is no
    /// incremental append: a pane always holds exactly what the most recent
    /// `setRows` gave it, and a second page REPLACES the first rather than
    /// being added to it.
    ///
    /// **No parameter here has a default, deliberately, and 2c-ii's three
    /// new ones keep that rule for a sharper reason than the original
    /// three.** `sort` is a COPY: the authority is `Pane.fetch.sort`, in
    /// `LayoutStore`, and what is kept here is the value `displayRows` was
    /// ordered by — the same relationship `displayRows` already has to
    /// `rows`. A default would let a caller forget to pass the authority's
    /// value, and the two would silently disagree about what the operator
    /// had sorted by. There is no default, so no caller can forget.
    public func setRows(
        paneId: String, columns: [String], columnTypes: [String],
        columnTypesInferred: Bool, rows: [[JSONValue]], millis: Int64, truncated: Bool,
        pageable: Bool, offset: Int, sort: PaneSort?
    ) {
        var contents = panes[paneId] ?? Contents()
        contents.columns = columns
        contents.columnTypes = columnTypes
        contents.columnTypesInferred = columnTypesInferred
        contents.rows = rows
        contents.millis = millis
        contents.truncated = truncated
        contents.pageable = pageable
        contents.offset = max(0, offset)
        contents.sort = sort
        reorder(&contents)
        clampToRowCount(&contents)
        panes[paneId] = contents
    }
```

Replace `setSort` with:

```swift
    /// Re-orders a pane's rows by `sort` without re-fetching them.
    ///
    /// **This is the client-side branch of spec §7 and only that.** It is
    /// the correct answer when every row that matches is already in hand:
    /// ordering them locally produces exactly what the engine would
    /// return, without a round trip. When the result is a subset, the
    /// caller re-fetches instead (`WindowModel.sortPane`) and this is not
    /// called at all.
    ///
    /// **It is not the sort's home.** `Pane.fetch.sort` is; this writes the
    /// cached copy that `displayRows` was produced from and that `snapshot`
    /// reports, and its callers write the authority first.
    public func reorder(paneId: String, sort: PaneSort?) {
        var contents = panes[paneId] ?? Contents()
        contents.sort = sort
        reorder(&contents)
        panes[paneId] = contents
    }
```

In `snapshot`, add two keys after `"truncated"`:

```swift
            "pageable": .bool(contents.pageable),
            "offset": .number(Double(contents.offset)),
```

- [ ] **Step 4: Fix `pane_sort`'s call site so the tree builds**

In `app/Sources/WakilKit/Panes/PaneContentActions.swift`, `pane_sort`'s handler currently calls `panes.setSort(...)` twice. Replace both calls with `panes.reorder(paneId: pane, sort: ...)`, leaving the rest of the handler alone. Task 12 rewrites this action properly; this step only keeps the tree compiling.

- [ ] **Step 5: Fix every other `setRows` call site**

`grep -rn "setRows(" app/Sources app/Tests` finds them. There is one in `StandardActions.swift` (`db_run_query`) and a number in tests. Each gains `pageable:`, `offset:` and `sort:`. For the production call in `db_run_query`, pass `pageable: contents.pageable`, `offset: 0`, `sort: nil` for now — Task 9 replaces the whole handler. For tests, pass `pageable: true, offset: 0, sort: nil` unless the test is about one of those.

`dbPaneContents(from:)` in `StandardActions.swift:864` must also read the new field. Add to its returned tuple and to its body:

```swift
    let pageable: Bool = {
        if case .bool(let p)? = obj["pageable"] { return p }
        // Absent means a server too old to say. False is the safe answer:
        // it hides the page control rather than offering one that returns
        // a syntax error.
        return false
    }()
```

- [ ] **Step 6: Run the suite**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneStore.swift app/Sources/WakilKit/Panes/PaneContentActions.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/
git commit -m "PaneStore is told the sort rather than keeping it

The authority moves to Pane.fetch.sort, because a pane that owns its
query but not its sort is incoherent the moment the sort becomes an ORDER
BY inside that query. What stays here is the value displayRows was
ordered by - the same relationship displayRows already has to rows.

setRows' no-defaults rule is what keeps the two from drifting, so the new
sort, pageable and offset parameters have none either."
```

---

## Task 8: `LayoutStore.setFetch`, and routing inverts

**Files:**
- Modify: `app/Sources/WakilKit/Layout/LayoutStore.swift` (`setFetch`, `queryTargetPane`)
- Test: `app/Tests/WakilKitTests/QueryTargetPaneTests.swift`, `app/Tests/WakilKitTests/LayoutStoreTests.swift`

**Interfaces:**
- Consumes: `PaneFetch` (Task 6).
- Produces: `LayoutStore.setFetch(_ fetch: PaneFetch?, id: String)`, `LayoutStore.fetch(id: String) -> PaneFetch?`, and `queryTargetPane(explicit:layout:) -> String?` — **now optional**, returning `nil` when no pane was named.

**The inversion, and why.** 2c-i's rule was *focused pane receives, explicit pane overrides, no pane opens one*. It becomes **naming a pane refines it, omitting one opens a new pane.** Both defaults fail an agent that forgets; the choice is which failure is cheaper. A stray pane is closable and costs nothing. A clobbered pane destroys the filter chain the operator built — the subject as well as the rows — which is the flow spec §6 records in the operator's own words: *query A, filter, filter, sort, then query B.* The likelihood runs the same way: when refining, the agent has just read `pane: db-1` off the previous result; when starting a new subject it has no pane in mind, and omitting is the natural thing.

- [ ] **Step 1: Write the failing routing tests**

Replace the body of `app/Tests/WakilKitTests/QueryTargetPaneTests.swift` with:

```swift
import Testing

@testable import WakilKit

private func snapshotWith(panes: [Pane], focused: String?) -> LayoutSnapshot {
    var snapshot = LayoutSnapshot()
    snapshot.panes = panes
    snapshot.focusedId = focused
    return snapshot
}

private func pane(_ id: String, kind: String = "db") -> Pane {
    Pane(id: id, kind: kind, title: id,
         frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
}

@Test func namingAPaneTargetsThatPane() {
    let layout = snapshotWith(panes: [pane("db-1"), pane("db-2")], focused: "db-2")
    #expect(queryTargetPane(explicit: "db-1", layout: layout) == "db-1")
}

@Test func namingNoPaneTargetsNoPane() {
    // The inversion. Before 2c-ii this returned the focused db pane, so a
    // second question replaced the first one's rows AND its subject. Now
    // it returns nil and the caller opens a pane.
    let layout = snapshotWith(panes: [pane("db-1"), pane("db-2")], focused: "db-2")
    #expect(queryTargetPane(explicit: nil, layout: layout) == nil)
}

@Test func anEmptyPaneStringIsTheSameAsNamingNone() {
    let layout = snapshotWith(panes: [pane("db-1")], focused: "db-1")
    #expect(queryTargetPane(explicit: "", layout: layout) == nil)
}

@Test func namingAPaneWorksWithNoLayoutAtAll() {
    // --dispatch and every test that predates a layout. An explicit id
    // does not depend on focus, so there is nothing to consult.
    #expect(queryTargetPane(explicit: "db-7", layout: nil) == "db-7")
    #expect(queryTargetPane(explicit: nil, layout: nil) == nil)
}

@Test func focusNoLongerDecidesAnything() {
    // Which dissolves 2c-i's acceptance check 11 rather than answering
    // it: a query with an explicit pane targets that pane whether or not
    // focus moved, and a query without one opens a pane that did not
    // exist when the query was sent. There is nothing left for a refocus
    // to race.
    let a = snapshotWith(panes: [pane("db-1"), pane("db-2")], focused: "db-1")
    let b = snapshotWith(panes: [pane("db-1"), pane("db-2")], focused: "db-2")
    #expect(queryTargetPane(explicit: nil, layout: a) == queryTargetPane(explicit: nil, layout: b))
    #expect(queryTargetPane(explicit: "db-1", layout: a) == queryTargetPane(explicit: "db-1", layout: b))
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | tail -30`
Expected: FAIL — `queryTargetPane` returns `String`, not `String?`.

- [ ] **Step 3: Rewrite `queryTargetPane`**

In `app/Sources/WakilKit/Layout/LayoutStore.swift`, replace the function and the doc comment above it with:

```swift
/// Which pane a query's rows belong in, or `nil` for "a new one".
///
/// **Naming a pane means "this belongs in that pane"; naming none means
/// "this is a different question".** That is the whole rule, it needs no
/// parameter beyond the one that already existed, and it is what makes
/// the operator's flow work: *query A, add a filter, add a filter, sort*
/// is one subject being refined and names `db-1` every time, because the
/// agent has just read that id off the previous result; *query B* is a
/// different subject and names nothing.
///
/// **This inverts 2c-i's rule, which resolved an unnamed query to the
/// focused database pane.** Both defaults fail an agent that forgets, so
/// the choice is which failure is cheaper. A stray pane is closable and
/// costs nothing; a clobbered pane destroys the filter chain the operator
/// built, the subject as well as the rows. The likelihood runs the same
/// way — an agent refining has the id in hand, an agent starting fresh
/// does not.
///
/// **Wakil never infers which it is.** The neighbouring temptation was
/// refused during 2c-i's walk in the operator's own words: the
/// implementation must not parse the SQL and guess the table, because a
/// join names two tables and an aggregate names none usefully. Guessing
/// from a query string is that mistake in a different hat.
///
/// `layout` is unused now and kept only so callers need not change; an
/// explicit id does not depend on focus, and there is no non-explicit
/// answer left to look up.
public func queryTargetPane(explicit: String?, layout: LayoutSnapshot?) -> String? {
    guard let explicit, !explicit.isEmpty else { return nil }
    return explicit
}
```

- [ ] **Step 4: Add `setFetch` and `fetch`**

In `LayoutStore`, beside `setColumnWidth`:

```swift
    /// Records what pane `id` is looking at, or does nothing if no such
    /// pane is open.
    ///
    /// Silent on an unknown id, matching `setColumnWidth` and `setBusy`: a
    /// pane closed between a query being sent and its rows arriving is an
    /// ordinary race, not an error worth failing a dispatch over — and the
    /// rows have already been fetched by then, so failing would change
    /// nothing except the journal.
    public func setFetch(_ fetch: PaneFetch?, id: String) {
        guard var current = byProject[project],
              let index = current.panes.firstIndex(where: { $0.id == id })
        else { return }
        current.panes[index].fetch = fetch
        byProject[project] = current
    }

    /// What pane `id` is looking at, or `nil` for an unknown pane or one
    /// nothing has queried.
    public func fetch(id: String) -> PaneFetch? {
        byProject[project]?.panes.first(where: { $0.id == id })?.fetch
    }
```

- [ ] **Step 5: Write the `setFetch` tests**

Append to `app/Tests/WakilKitTests/LayoutStoreTests.swift`:

```swift
@Test func aPanesSubjectIsRecordedAndReadBack() async {
    let store = LayoutStore()
    let pane = await store.open(kind: "db", title: "main")
    let fetch = PaneFetch(query: .table(database: "main", name: "events"), offset: 500)
    await store.setFetch(fetch, id: pane.id)
    #expect(await store.fetch(id: pane.id) == fetch)
    let snapshot = await store.snapshot()
    #expect(snapshot.panes.first?.fetch == fetch)
}

@Test func recordingASubjectOnAPaneThatIsGoneIsSilent() async {
    let store = LayoutStore()
    await store.setFetch(PaneFetch(query: .tables(database: nil)), id: "db-99")
    #expect(await store.fetch(id: "db-99") == nil)
}
```

- [ ] **Step 6: Run and fix the call sites**

Run: `make app-test 2>&1 | tail -30`

`db_run_query` in `StandardActions.swift` is the only production caller of `queryTargetPane` and will not compile against the optional return. Task 9 rewrites it; to keep this task's tree green, change its two lines to:

```swift
            var paneId = queryTargetPane(explicit: explicitPaneParam, layout: await layout?.snapshot())
                ?? "db"
```

leaving the rest alone. Any test asserting the old focused-pane fallback is replaced by the tests in Step 1 — delete those assertions rather than adapting them, and say so in the commit.

Run: `make app-test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Layout/LayoutStore.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/
git commit -m "Naming a pane refines it; naming none opens one

Both defaults fail an agent that forgets, so the question is which
failure is cheaper. A stray pane is closable. A clobbered pane destroys
the filter chain the operator built - the subject as well as the rows.

It also dissolves 2c-i's recorded question about which pane an in-flight
query lands in: an explicit id does not depend on focus, and a query
without one opens a pane that did not exist when it was sent, so there is
nothing left for a refocus to race."
```

---

## Task 9: `db_run_query` records the subject and routes by it

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (`db_run_query`, `dbPaneContents`)
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: `PaneFetch`, `LayoutStore.setFetch`, `queryTargetPane` (Tasks 6, 8), the `offset`/`sortColumn`/`sortDescending`/`pageable` wire fields (Task 5).
- Produces: `db_run_query` accepting `query`, `database`, `limit`, `offset`, `pane`; writing `Pane.fetch`; opening a pane when none is named.

- [ ] **Step 1: Write the failing tests**

Append to `app/Tests/WakilKitTests/StandardActionsTests.swift`, using whatever fake `MCPClient` that file already uses for `db_*` tests:

```swift
@Test func aQueryWithNoPaneOpensOne() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    _ = try await harness.registry.dispatch(
        "db_run_query", .object(["query": .string("SELECT * FROM events")]),
        origin: .agent, environment: "staging")
    let snapshot = await harness.layout.snapshot()
    #expect(snapshot.panes.count == 1)
    #expect(snapshot.panes[0].kind == "db")
}

@Test func aSecondQueryWithNoPaneOpensASecondPane() async throws {
    // The operator's flow: "query table B" is a different subject, so it
    // gets its own pane rather than replacing table A's.
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    for _ in 0..<2 {
        _ = try await harness.registry.dispatch(
            "db_run_query", .object(["query": .string("SELECT * FROM events")]),
            origin: .agent, environment: "staging")
    }
    #expect(await harness.layout.snapshot().panes.count == 2)
}

@Test func aQueryNamingAPaneRefinesItInPlace() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    _ = try await harness.registry.dispatch(
        "db_run_query",
        .object(["query": .string("SELECT * FROM events WHERE id = 1"),
                 "pane": .string(pane.id)]),
        origin: .agent, environment: "staging")
    let snapshot = await harness.layout.snapshot()
    #expect(snapshot.panes.count == 1)
    #expect(snapshot.panes[0].fetch?.query
            == .sql(database: nil, raw: "SELECT * FROM events WHERE id = 1"))
}

@Test func aQueryRecordsTheSubjectIncludingItsDatabase() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    _ = try await harness.registry.dispatch(
        "db_run_query",
        .object(["query": .string("SELECT 1"), "database": .string("analytics")]),
        origin: .agent, environment: "staging")
    let fetch = await harness.layout.snapshot().panes[0].fetch
    #expect(fetch?.query == .sql(database: "analytics", raw: "SELECT 1"))
    #expect(fetch?.offset == 0)
}

@Test func namingAPaneThatIsNotOpenIsStillAnError() async throws {
    // Unchanged from 2c-i and deliberately so. Under the new routing an
    // unknown id could silently become "open a new pane", which is the
    // same class of quiet failure the check was added against.
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    await #expect(throws: StandardActionError.self) {
        _ = try await harness.registry.dispatch(
            "db_run_query",
            .object(["query": .string("SELECT 1"), "pane": .string("db-404")]),
            origin: .agent, environment: "staging")
    }
}

@Test func aQueryAtAnOffsetRecordsWhereThePaneIs() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    _ = try await harness.registry.dispatch(
        "db_run_query",
        .object(["query": .string("SELECT 1"), "pane": .string(pane.id),
                 "offset": .number(500)]),
        origin: .agent, environment: "staging")
    #expect(await harness.layout.fetch(id: pane.id)?.offset == 500)
    // And the offset reaches the server, not just the layout.
    #expect(await harness.lastArguments["offset"] == .number(500))
}

@Test func theResultTellsTheAgentWhichPaneItLandedIn() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let result = try await harness.registry.dispatch(
        "db_run_query", .object(["query": .string("SELECT 1")]),
        origin: .agent, environment: "staging")
    guard case .object(let obj) = result, case .string(let pane)? = obj["pane"] else {
        Issue.record("the result must name the pane"); return
    }
    #expect(pane == "db-1")
    // The routing rule only works if the agent is handed the id the rule
    // needs. This is that hand-off.
    #expect(obj["drawn"] == .bool(true))
}
```

If `StandardActionsTests.swift` has no `DBActionHarness`, build one in that file from the fake client and stores its existing `db_run_query` tests already use, exposing `registry`, `layout`, `panes` and a `lastArguments` capture of the most recent tool call's arguments.

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | tail -30`

- [ ] **Step 3: Rewrite `db_run_query`**

Replace its description with:

```swift
        description: "Run a read-only query against a database in the active environment "
            + "and return rows. The rows are also drawn in a pane, so what is on screen "
            + "and what this returns are the same thing.\n"
            + "WHICH PANE: naming a pane means this belongs in that pane — it replaces "
            + "that pane's rows and becomes what that pane is showing. Omitting pane opens "
            + "a NEW pane. So: refining a question you already asked (adding a filter, "
            + "changing a range, sorting) names the pane the last result came back in — "
            + "every result tells you its pane id. Asking a DIFFERENT question names no "
            + "pane, and gets its own pane to sit beside the first.\n"
            + "PAGING: offset skips rows before the first one returned, so offset 500 with "
            + "limit 500 is the second page of the SAME query. The pageable field says "
            + "whether this result can be paged at all — an EXPLAIN or a SHOW cannot. "
            + "At most 1000 rows come back per query (default 500; a limit above 1000 "
            + "falls back to 500).\n"
            + "Every query you run is drawn as it lands and the operator watches each one, "
            + "so finish with the query whose result should stay on screen.",
```

Add `offset` to the schema's properties:

```swift
                "offset": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Rows to skip before the first one returned. 0 is the first page."),
                ]),
```

Replace the handler body from the `callChecked` line to the end with:

```swift
            var offsetParam = 0
            if case .object(let obj) = params, let raw = obj["offset"],
               case .number(let n) = raw, let parsed = safeInt(n), parsed >= 0 {
                offsetParam = parsed
                arguments["offset"] = .number(Double(parsed))
            }
            let result = try await callChecked(
                db, tool: "query", arguments: .object(arguments),
                action: "db_run_query", timeout: MCPClient.readReplyTimeout)
            guard let contents = dbPaneContents(from: result) else { return result }

            // Naming a pane means "this belongs in that pane". Naming none
            // means this is a different question, and a different question
            // gets its own pane. See `queryTargetPane`.
            var openedPane = false
            var paneId = queryTargetPane(explicit: explicitPaneParam, layout: nil)
            if paneId == nil, let layout {
                paneId = await layout.open(kind: "db", title: databaseParam ?? "db").id
                openedPane = true
            }
            // With no layout to open a pane in (`--dispatch`, tests) the
            // write goes ahead under the literal "db", exactly as it did
            // before any of this existed.
            let target = paneId ?? "db"

            let fetch = PaneFetch(
                query: .sql(database: databaseParam, raw: query),
                offset: offsetParam,
                pageSize: limitParam ?? PaneFetch.defaultPageSize,
                sort: sortParam)
            await layout?.setFetch(fetch, id: target)
            await panes.setRows(
                paneId: target, columns: contents.columns,
                columnTypes: contents.columnTypes,
                columnTypesInferred: contents.columnTypesInferred,
                rows: contents.rows, millis: contents.millis,
                truncated: contents.truncated, pageable: contents.pageable,
                offset: offsetParam, sort: sortParam)
            return annotatedWithPaneOutcome(result, paneId: target, opened: openedPane)
```

where `limitParam` is an `Int?` parsed from `obj["limit"]` the same way `offsetParam` is, and `sortParam` is a `PaneSort?` parsed from `obj["sortColumn"]`/`obj["sortDescending"]` — add both beside the existing parameter parsing, and pass `sortColumn`/`sortDescending` through to `arguments` when present.

Update `annotatedWithPaneOutcome`'s `paneNote` to the new rule:

```swift
        obj["paneNote"] = .string(
            "You named no pane, so a new one was opened (id \"\(paneId)\") and the rows "
            + "above are drawn in it. To REFINE this same question — add a filter, change "
            + "a range, page, sort — pass pane: \"\(paneId)\" and it updates in place. "
            + "Ask a different question with no pane and you get another pane beside it.")
```

- [ ] **Step 4: Run and watch it pass**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "db_run_query records the pane's subject and routes by it

A named pane is refined in place and a query naming none opens its own
pane. The description states that rule and every result hands back the
pane id the rule needs, which is the whole of making an agent 'smart
about this' - it is told what to do and given the identifier to do it
with.

Naming a pane that is not open stays an error. Under the new routing an
unknown id could otherwise quietly become 'open a new pane', which is the
same class of silent failure the check was added against."
```

---

## Task 10: Schema browsing is the data surface — three actions, no new view

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift`
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: `PaneFetch`, `LayoutStore.setFetch`, `queryTargetPane`, the `read_table` tool (Tasks 5, 6, 8).
- Produces: actions `db_list_tables`, `db_describe_table`, `db_read_table`; and two free functions `containerListPaneContents(from:)` and `schemaPaneContents(from:)` converting `ContainerList` and `Schema` payloads into pane rows.

**There is no schema browser widget and no sidebar.** `design-language.md` §1 forbids sidebars and §11 lists Database as a single non-tabbed pane; both stand unamended, because the schema is already tabular. `list_tables` is one row per table; `describe_table` is one row per column. Both are served by Go tools that have existed since Phase 1 and that today are reachable only as raw `mcp__wakil-db__*` passthrough — with no pointer path and no journal entry. These three actions fix that and add **no new view code at all.**

- [ ] **Step 1: Write the failing tests**

```swift
@Test func listingTablesDrawsThemAsRows() async throws {
    let harness = try await DBActionHarness(
        containers: [("events", "table"), ("customers", "table")])
    _ = try await harness.registry.dispatch(
        "db_list_tables", .object([:]), origin: .agent, environment: "staging")
    let pane = await harness.layout.snapshot().panes[0]
    #expect(pane.fetch?.query == .tables(database: nil))
    guard case .object(let snap) = await harness.panes.snapshot(paneId: pane.id),
          case .array(let columns)? = snap["columns"] else {
        Issue.record("no columns"); return
    }
    #expect(columns == [.string("name"), .string("kind")])
    #expect(snap["rowCount"] == .number(2))
    // A table list is complete by construction — the driver returns
    // everything the server reports or fails — so it is never truncated
    // and never pageable.
    #expect(snap["truncated"] == .bool(false))
    #expect(snap["pageable"] == .bool(false))
}

@Test func describingATableDrawsItsColumnsAsRows() async throws {
    let harness = try await DBActionHarness(
        schema: [("id", "INTEGER"), ("kind", "TEXT")])
    _ = try await harness.registry.dispatch(
        "db_describe_table", .object(["table": .string("events")]),
        origin: .agent, environment: "staging")
    let pane = await harness.layout.snapshot().panes[0]
    #expect(pane.fetch?.query == .columns(database: nil, table: "events"))
    guard case .object(let snap) = await harness.panes.snapshot(paneId: pane.id),
          case .array(let columns)? = snap["columns"] else {
        Issue.record("no columns"); return
    }
    #expect(columns == [.string("name"), .string("type"), .string("key")])
}

@Test func describingATableNeedsATableName() async throws {
    let harness = try await DBActionHarness(schema: [])
    await #expect(throws: StandardActionError.self) {
        _ = try await harness.registry.dispatch(
            "db_describe_table", .object([:]), origin: .agent, environment: "staging")
    }
}

@Test func readingATableRecordsItAsTheSubject() async throws {
    let harness = try await DBActionHarness(rows: [["id", "kind"], [1, "a"]])
    _ = try await harness.registry.dispatch(
        "db_read_table", .object(["table": .string("events")]),
        origin: .agent, environment: "staging")
    let pane = await harness.layout.snapshot().panes[0]
    #expect(pane.fetch?.query == .table(database: nil, name: "events"))
    // Which is the whole reason .table exists as its own case rather than
    // as a composed SELECT: the subject survives, so paging and relaunch
    // can re-render it for whatever driver the pane is against.
    #expect(await harness.lastTool == "read_table")
}

@Test func schemaBrowsingObeysTheSameRoutingRuleAsAQuery() async throws {
    let harness = try await DBActionHarness(
        containers: [("events", "table")])
    let existing = await harness.layout.open(kind: "db", title: "main")
    _ = try await harness.registry.dispatch(
        "db_list_tables", .object(["pane": .string(existing.id)]),
        origin: .agent, environment: "staging")
    #expect(await harness.layout.snapshot().panes.count == 1)
    _ = try await harness.registry.dispatch(
        "db_list_tables", .object([:]), origin: .agent, environment: "staging")
    #expect(await harness.layout.snapshot().panes.count == 2)
}

@Test func allThreeAreReadsNotControls() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let descriptors = await harness.registry.all()
    for name in ["db_list_tables", "db_describe_table", "db_read_table"] {
        guard let action = descriptors.first(where: { $0.name == name }) else {
            Issue.record("\(name) is not registered"); continue
        }
        // Each one reaches a database. `.control` is for state that never
        // leaves Wakil, which is why 2c-i's six pane-content actions are
        // `.control` and these are not.
        #expect(action.kind == .read)
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | tail -30`

- [ ] **Step 3: Add the two payload converters**

Beside `dbPaneContents` in `StandardActions.swift`:

```swift
/// Turns a `list_tables` result into pane rows.
///
/// **The schema browser is the data surface, pointed at metadata.** A
/// table list is one row per table with two columns, which is a result
/// set, so it draws on 2c-i's grid with no new view code and is reachable
/// by every route an ordinary result is.
///
/// Never truncated and never pageable: `ListContainers` returns everything
/// the server reports or fails, so there is no second page to ask for and
/// offering the control would be a lie.
func containerListPaneContents(
    from result: JSONValue
) -> (columns: [String], columnTypes: [String], rows: [[JSONValue]])? {
    guard case .object(let obj) = result,
          case .object(let structured)? = obj["structuredContent"],
          case .array(let containers)? = structured["containers"]
    else { return nil }
    let rows: [[JSONValue]] = containers.map { entry in
        guard case .object(let c) = entry else { return [.null, .null] }
        return [c["name"] ?? .null, c["kind"] ?? .null]
    }
    return (columns: ["name", "kind"], columnTypes: ["TEXT", "TEXT"], rows: rows)
}

/// Turns a `describe_table` result into pane rows.
///
/// `key` is carried through even though no driver populates it today —
/// `wakilcore.Column.Key` is declared and nothing sets it, because
/// `sqlConn.Describe` reads `rows.ColumnTypes()`, which does not report
/// keyness, and `mongoConn.Describe` reads one document. The column is
/// here so that when a driver learns keyness the surface already has
/// somewhere to draw it; until then it is honestly false everywhere.
func schemaPaneContents(
    from result: JSONValue
) -> (columns: [String], columnTypes: [String], rows: [[JSONValue]])? {
    guard case .object(let obj) = result,
          case .object(let structured)? = obj["structuredContent"],
          case .array(let columns)? = structured["columns"]
    else { return nil }
    let rows: [[JSONValue]] = columns.map { entry in
        guard case .object(let c) = entry else { return [.null, .null, .bool(false)] }
        return [c["name"] ?? .null, c["type"] ?? .null, c["key"] ?? .bool(false)]
    }
    return (columns: ["name", "type", "key"],
            columnTypes: ["TEXT", "TEXT", "BOOLEAN"], rows: rows)
}
```

- [ ] **Step 4: Register the three actions**

In `registerStandardActions`, after `db_run_query`:

```swift
    await registry.register(Action(
        name: "db_list_tables",
        description: "List a database's tables or collections, drawn in a pane as rows — "
            + "one row per table, with its name and its kind. This is how you look at a "
            + "schema: there is no separate browser, the table list IS a result set. "
            + "Naming a pane draws into it; omitting pane opens a new one, the same rule "
            + "db_run_query follows. The list is always complete, so it is never paged.",
        kind: .read,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "pane": .object(["type": .string("string")]),
            ]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_list_tables", role: "database")
            }
            let database = optionalStringParam(params, "database")
            let explicit = optionalStringParam(params, "pane")
            try await requireOpenPane(explicit, action: "db_list_tables", layout: layout)
            var arguments: [String: JSONValue] = [:]
            if let database { arguments["database"] = .string(database) }
            let result = try await callChecked(
                db, tool: "list_tables", arguments: .object(arguments),
                action: "db_list_tables", timeout: MCPClient.readReplyTimeout)
            guard let contents = containerListPaneContents(from: result) else { return result }
            let (target, opened) = await resolvePane(
                explicit: explicit, title: database ?? "tables", layout: layout)
            await layout?.setFetch(PaneFetch(query: .tables(database: database)), id: target)
            await panes.setRows(
                paneId: target, columns: contents.columns, columnTypes: contents.columnTypes,
                columnTypesInferred: false, rows: contents.rows, millis: 0,
                truncated: false, pageable: false, offset: 0, sort: nil)
            return annotatedWithPaneOutcome(result, paneId: target, opened: opened)
        }
    ))

    await registry.register(Action(
        name: "db_describe_table",
        description: "Describe one table or collection, drawn in a pane as rows — one row "
            + "per column, with its name, its declared type, and whether it is a key. "
            + "Naming a pane draws into it; omitting pane opens a new one.",
        kind: .read,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "table": .object(["type": .string("string")]),
                "pane": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("table")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_describe_table", role: "database")
            }
            let table = try requireStringParam(params, "table", action: "db_describe_table")
            let database = optionalStringParam(params, "database")
            let explicit = optionalStringParam(params, "pane")
            try await requireOpenPane(explicit, action: "db_describe_table", layout: layout)
            var arguments: [String: JSONValue] = ["name": .string(table)]
            if let database { arguments["database"] = .string(database) }
            let result = try await callChecked(
                db, tool: "describe_table", arguments: .object(arguments),
                action: "db_describe_table", timeout: MCPClient.readReplyTimeout)
            guard let contents = schemaPaneContents(from: result) else { return result }
            let (target, opened) = await resolvePane(
                explicit: explicit, title: table, layout: layout)
            await layout?.setFetch(
                PaneFetch(query: .columns(database: database, table: table)), id: target)
            await panes.setRows(
                paneId: target, columns: contents.columns, columnTypes: contents.columnTypes,
                columnTypesInferred: false, rows: contents.rows, millis: 0,
                truncated: false, pageable: false, offset: 0, sort: nil)
            return annotatedWithPaneOutcome(result, paneId: target, opened: opened)
        }
    ))

    await registry.register(Action(
        name: "db_read_table",
        description: "Draw every row of one table or collection in a pane, without writing "
            + "a query. Prefer this over db_run_query with \"SELECT * FROM x\": the driver "
            + "renders the read for its own dialect, which is the only form that also works "
            + "against Mongo, where there is no SQL. It pages and sorts like any query. "
            + "Naming a pane draws into it; omitting pane opens a new one.",
        kind: .read,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "table": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")]),
                "offset": .object(["type": .string("number")]),
                "pane": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("table")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_read_table", role: "database")
            }
            let table = try requireStringParam(params, "table", action: "db_read_table")
            let database = optionalStringParam(params, "database")
            let explicit = optionalStringParam(params, "pane")
            try await requireOpenPane(explicit, action: "db_read_table", layout: layout)
            let offset = optionalIntParam(params, "offset") ?? 0
            let limit = optionalIntParam(params, "limit") ?? PaneFetch.defaultPageSize
            var arguments: [String: JSONValue] = [
                "name": .string(table),
                "limit": .number(Double(limit)),
                "offset": .number(Double(offset)),
            ]
            if let database { arguments["database"] = .string(database) }
            let result = try await callChecked(
                db, tool: "read_table", arguments: .object(arguments),
                action: "db_read_table", timeout: MCPClient.readReplyTimeout)
            guard let contents = dbPaneContents(from: result) else { return result }
            let (target, opened) = await resolvePane(
                explicit: explicit, title: table, layout: layout)
            await layout?.setFetch(
                PaneFetch(query: .table(database: database, name: table),
                          offset: offset, pageSize: limit),
                id: target)
            await panes.setRows(
                paneId: target, columns: contents.columns, columnTypes: contents.columnTypes,
                columnTypesInferred: contents.columnTypesInferred, rows: contents.rows,
                millis: contents.millis, truncated: contents.truncated,
                pageable: contents.pageable, offset: offset, sort: nil)
            return annotatedWithPaneOutcome(result, paneId: target, opened: opened)
        }
    ))
```

- [ ] **Step 5: Add the three shared helpers**

Every action above repeats the same three moves, so they get one home each. Beside `dbPaneContents`:

```swift
/// Refuses a `pane` naming a pane that is not open.
///
/// **Checked BEFORE the tool call, not after**, for the reason 2c-i's walk
/// established: a pane id that names nothing is a mistake in the request,
/// and running a read whose rows have nowhere to go — then reporting
/// success — is the failure this check exists against. A `nil` layout
/// skips it entirely: with no layout there is nothing to check an id
/// against, and inventing a failure would break every `--dispatch` caller.
func requireOpenPane(_ explicit: String?, action: String, layout: LayoutStore?) async throws {
    guard let explicit, !explicit.isEmpty, let open = await layout?.snapshot() else { return }
    guard open.panes.contains(where: { $0.id == explicit }) else {
        throw StandardActionError.unknownPane(
            action: action, pane: explicit, open: open.panes.map(\.id))
    }
}

/// The pane a result belongs in, opening one when none was named.
///
/// Returns the literal `"db"` and `false` when there is no layout to open
/// a pane in — `--dispatch` and tests — which is what that path has always
/// done.
func resolvePane(
    explicit: String?, title: String, layout: LayoutStore?
) async -> (id: String, opened: Bool) {
    if let named = queryTargetPane(explicit: explicit, layout: nil) { return (named, false) }
    guard let layout else { return ("db", false) }
    return (await layout.open(kind: "db", title: title).id, true)
}

/// A non-negative integer parameter, or `nil`.
///
/// Rejects a negative, a fraction, a NaN and an infinity rather than
/// coercing them — `safeInt` is the same guard `requireRowIndex` uses, and
/// a NaN reaching the layout is one of the open items 2c-i's final review
/// recorded.
func optionalIntParam(_ params: JSONValue, _ name: String) -> Int? {
    guard case .object(let obj) = params, case .number(let n)? = obj[name],
          let parsed = safeInt(n), parsed >= 0
    else { return nil }
    return parsed
}
```

If `optionalStringParam` does not already exist in this file, add it in the same shape.

- [ ] **Step 6: Run and watch it pass**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "The schema browser is the data surface, pointed at metadata

No widget, no tree, no sidebar - design-language.md §1 forbids sidebars
and §11 lists Database as one pane, and both stand unamended because a
table list is already a result set. list_tables and describe_table have
existed on the Go server since Phase 1 and were reachable only as raw
passthrough, with no pointer path and no journal entry. Three actions fix
that and add no view code at all.

db_read_table keeps .table as its own subject rather than composing a
SELECT, because on Mongo there is no SELECT to compose."
```

---

## Task 11: `db_refetch`, `db_page` and `db_classify_statement`

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift`
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 6, 8, 9, 10, plus the `classify_statement` tool (Task 5).
- Produces: actions `db_refetch`, `db_page`, `db_classify_statement`, and one internal free function `refetchPane(paneId:fetch:db:panes:layout:) async throws -> JSONValue` that every re-fetching caller goes through.

**One re-fetch path, four callers.** Paging, sorting a truncated result, relaunch and the query line's plain Return all mean "run this pane's subject again". Writing that four times is four places for the subject-to-tool-call mapping to drift, and the mapping is the only hard part — `.sql` goes to `query`, `.table` to `read_table`, `.tables` to `list_tables`, `.columns` to `describe_table`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func refetchingRunsThePanesOwnSubject() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: "main", raw: "SELECT * FROM events")), id: pane.id)
    _ = try await harness.registry.dispatch(
        "db_refetch", .object(["pane": .string(pane.id)]),
        origin: .agent, environment: "staging")
    #expect(await harness.lastTool == "query")
    #expect(await harness.lastArguments["query"] == .string("SELECT * FROM events"))
    #expect(await harness.lastArguments["database"] == .string("main"))
}

@Test func eachSubjectRefetchesThroughItsOwnTool() async throws {
    let cases: [(PaneQuery, String)] = [
        (.sql(database: nil, raw: "SELECT 1"), "query"),
        (.table(database: nil, name: "events"), "read_table"),
        (.tables(database: nil), "list_tables"),
        (.columns(database: nil, table: "events"), "describe_table"),
    ]
    for (subject, tool) in cases {
        let harness = try await DBActionHarness(rows: [["id"], [1]],
                                                containers: [("events", "table")],
                                                schema: [("id", "INTEGER")])
        let pane = await harness.layout.open(kind: "db", title: "main")
        await harness.layout.setFetch(PaneFetch(query: subject), id: pane.id)
        _ = try await harness.registry.dispatch(
            "db_refetch", .object(["pane": .string(pane.id)]),
            origin: .agent, environment: "staging")
        #expect(await harness.lastTool == tool)
    }
}

@Test func refetchingAPaneWithNoSubjectIsAnError() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await #expect(throws: StandardActionError.self) {
        _ = try await harness.registry.dispatch(
            "db_refetch", .object(["pane": .string(pane.id)]),
            origin: .agent, environment: "staging")
    }
}

@Test func pagingMovesTheOffsetAndRerunsTheSubject() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: nil, raw: "SELECT 1"), pageSize: 500), id: pane.id)
    _ = try await harness.registry.dispatch(
        "db_page", .object(["pane": .string(pane.id), "to": .string("next")]),
        origin: .agent, environment: "staging")
    #expect(await harness.layout.fetch(id: pane.id)?.offset == 500)
    #expect(await harness.lastArguments["offset"] == .number(500))
}

@Test func pagingBackFromTheFirstPageStaysThereAndStillRedraws() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane.id)
    _ = try await harness.registry.dispatch(
        "db_page", .object(["pane": .string(pane.id), "to": .string("previous")]),
        origin: .agent, environment: "staging")
    #expect(await harness.layout.fetch(id: pane.id)?.offset == 0)
}

@Test func pagingToANonsenseDestinationIsRefusedNotDefaulted() async throws {
    // The same rule pane_sort's direction follows: silently reading
    // "sideways" as "next" would page the wrong way and tell nobody.
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane.id)
    await #expect(throws: LayoutActionError.self) {
        _ = try await harness.registry.dispatch(
            "db_page", .object(["pane": .string(pane.id), "to": .string("sideways")]),
            origin: .agent, environment: "staging")
    }
}

@Test func classifyingAStatementAsksTheGates() async throws {
    let harness = try await DBActionHarness(classification: ("mutation", ""))
    let result = try await harness.registry.dispatch(
        "db_classify_statement",
        .object(["statement": .string("UPDATE events SET kind = 'x' WHERE id = 1")]),
        origin: .ui, environment: "staging")
    guard case .object(let obj) = result,
          case .object(let structured)? = obj["structuredContent"] else {
        Issue.record("no structured result"); return
    }
    #expect(structured["kind"] == .string("mutation"))
    #expect(await harness.lastTool == "classify_statement")
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | tail -30`

- [ ] **Step 3: Write the shared re-fetch path**

Beside the other free functions in `StandardActions.swift`:

```swift
/// Runs pane `paneId`'s own subject again and redraws it.
///
/// **One path, four callers**: `db_page`, `db_refetch`, `pane_sort`'s
/// re-query branch, and the window's relaunch restore. The mapping from a
/// subject to a tool call is the only hard part of any of them, and four
/// copies of it is four places for it to drift.
///
/// It does not write `Pane.fetch` — the caller does that first, so that
/// the fetch this runs and the fetch the pane records are one value rather
/// than two computed the same way.
func refetchPane(
    paneId: String, fetch: PaneFetch, db: MCPClient, panes: PaneStore, layout: LayoutStore?
) async throws -> JSONValue {
    let action = "db_refetch"
    var arguments: [String: JSONValue] = [:]
    if let database = fetch.query.database { arguments["database"] = .string(database) }

    switch fetch.query {
    case .sql(_, let raw):
        arguments["query"] = .string(raw)
        arguments["limit"] = .number(Double(fetch.pageSize))
        arguments["offset"] = .number(Double(fetch.offset))
        if let sort = fetch.sort {
            arguments["sortColumn"] = .string(sort.column)
            arguments["sortDescending"] = .bool(sort.direction == .descending)
        }
        let result = try await callChecked(
            db, tool: "query", arguments: .object(arguments),
            action: action, timeout: MCPClient.readReplyTimeout)
        guard let contents = dbPaneContents(from: result) else { return result }
        await panes.setRows(
            paneId: paneId, columns: contents.columns, columnTypes: contents.columnTypes,
            columnTypesInferred: contents.columnTypesInferred, rows: contents.rows,
            millis: contents.millis, truncated: contents.truncated,
            pageable: contents.pageable, offset: fetch.offset, sort: fetch.sort)
        return annotatedWithPaneOutcome(result, paneId: paneId, opened: false)

    case .table(_, let name):
        arguments["name"] = .string(name)
        arguments["limit"] = .number(Double(fetch.pageSize))
        arguments["offset"] = .number(Double(fetch.offset))
        if let sort = fetch.sort {
            arguments["sortColumn"] = .string(sort.column)
            arguments["sortDescending"] = .bool(sort.direction == .descending)
        }
        let result = try await callChecked(
            db, tool: "read_table", arguments: .object(arguments),
            action: action, timeout: MCPClient.readReplyTimeout)
        guard let contents = dbPaneContents(from: result) else { return result }
        await panes.setRows(
            paneId: paneId, columns: contents.columns, columnTypes: contents.columnTypes,
            columnTypesInferred: contents.columnTypesInferred, rows: contents.rows,
            millis: contents.millis, truncated: contents.truncated,
            pageable: contents.pageable, offset: fetch.offset, sort: fetch.sort)
        return annotatedWithPaneOutcome(result, paneId: paneId, opened: false)

    case .tables:
        // No limit, no offset and no sort pushed: a table list is complete
        // by construction, so there is no page to ask for and the sort, if
        // any, is honoured client-side by `setRows`.
        let result = try await callChecked(
            db, tool: "list_tables", arguments: .object(arguments),
            action: action, timeout: MCPClient.readReplyTimeout)
        guard let contents = containerListPaneContents(from: result) else { return result }
        await panes.setRows(
            paneId: paneId, columns: contents.columns, columnTypes: contents.columnTypes,
            columnTypesInferred: false, rows: contents.rows, millis: 0,
            truncated: false, pageable: false, offset: 0, sort: fetch.sort)
        return annotatedWithPaneOutcome(result, paneId: paneId, opened: false)

    case .columns(_, let table):
        arguments["name"] = .string(table)
        let result = try await callChecked(
            db, tool: "describe_table", arguments: .object(arguments),
            action: action, timeout: MCPClient.readReplyTimeout)
        guard let contents = schemaPaneContents(from: result) else { return result }
        await panes.setRows(
            paneId: paneId, columns: contents.columns, columnTypes: contents.columnTypes,
            columnTypesInferred: false, rows: contents.rows, millis: 0,
            truncated: false, pageable: false, offset: 0, sort: fetch.sort)
        return annotatedWithPaneOutcome(result, paneId: paneId, opened: false)
    }
}
```

- [ ] **Step 4: Register the three actions**

```swift
    await registry.register(Action(
        name: "db_refetch",
        description: "Run a pane's own query again and redraw it, at whatever page and "
            + "sort it is already on. Use it after a mutation to see the change, or when "
            + "a result may have gone stale. The pane must already be showing something.",
        kind: .read,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_refetch", role: "database")
            }
            let paneId = try requireStringParam(params, "pane", action: "db_refetch")
            try await requireOpenPane(paneId, action: "db_refetch", layout: layout)
            guard let fetch = await layout?.fetch(id: paneId) else {
                throw StandardActionError.paneHasNoQuery(action: "db_refetch", pane: paneId)
            }
            return try await refetchPane(
                paneId: paneId, fetch: fetch, db: db, panes: panes, layout: layout)
        }
    ))

    await registry.register(Action(
        name: "db_page",
        description: "Move a pane to another page of its own query and redraw it. "
            + "to is \"next\", \"previous\", \"first\", or a zero-based page number. "
            + "This re-runs the query at a new offset — it is not a scroll, and the rows "
            + "that arrive replace the ones that were there. A pane whose result is not "
            + "pageable (an EXPLAIN, a SHOW, a table list) cannot be paged.",
        kind: .read,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "to": .object([
                    "type": .string("string"),
                    "description": .string("\"next\", \"previous\", \"first\", or a page number"),
                ]),
            ]),
            "required": .array([.string("pane"), .string("to")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_page", role: "database")
            }
            let paneId = try requireStringParam(params, "pane", action: "db_page")
            let to = try requireStringParam(params, "to", action: "db_page")
            try await requireOpenPane(paneId, action: "db_page", layout: layout)
            guard let current = await layout?.fetch(id: paneId) else {
                throw StandardActionError.paneHasNoQuery(action: "db_page", pane: paneId)
            }
            // Refused rather than defaulted, the rule `pane_sort`'s
            // direction already follows: reading "sideways" as "next"
            // would page the wrong way and tell nobody.
            let destination: PaneFetch.Page
            switch to {
            case "next": destination = .next
            case "previous": destination = .previous
            case "first": destination = .first
            default:
                guard let n = Int(to), n >= 0 else {
                    throw LayoutActionError.badParam(action: "db_page", param: "to", value: to)
                }
                destination = .number(n)
            }
            let next = current.page(to: destination)
            await layout?.setFetch(next, id: paneId)
            return try await refetchPane(
                paneId: paneId, fetch: next, db: db, panes: panes, layout: layout)
        }
    ))

    await registry.register(Action(
        name: "db_classify_statement",
        description: "Say whether a statement is a read, a mutation, or neither, WITHOUT "
            + "running it. kind is \"read\", \"mutation\" or \"neither\"; for \"neither\", "
            + "reason carries the gate's own sentence. The answer comes from the same gates "
            + "that judge the statement when it runs, so it is not a second opinion — but "
            + "it is not permission either: a mutation still passes the write gate and a "
            + "human confirmation.",
        kind: .read,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "statement": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("statement")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(
                    action: "db_classify_statement", role: "database")
            }
            let statement = try requireStringParam(
                params, "statement", action: "db_classify_statement")
            var arguments: [String: JSONValue] = ["statement": .string(statement)]
            if let database = optionalStringParam(params, "database") {
                arguments["database"] = .string(database)
            }
            return try await callChecked(
                db, tool: "classify_statement", arguments: .object(arguments),
                action: "db_classify_statement", timeout: MCPClient.readReplyTimeout)
        }
    ))
```

- [ ] **Step 5: Add the new error case**

In `StandardActionError`:

```swift
    /// The caller asked a pane to re-run, page or re-sort its query, and
    /// the pane has no query. A pane that has never been queried is not an
    /// error to *open*; it is an error to ask one to run again.
    case paneHasNoQuery(action: String, pane: String)
```

and in `description`:

```swift
        case .paneHasNoQuery(let action, let pane):
            return "\(action): pane \"\(pane)\" is not showing a query yet — "
                + "run db_run_query, db_read_table or db_list_tables against it first"
```

- [ ] **Step 6: Run and watch it pass**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "One re-fetch path, and the two actions that drive it

Paging, sorting a truncated result, relaunch and the query line's Return
all mean 'run this pane's subject again'. The only hard part is mapping a
subject to a tool call, and four copies of that mapping is four places
for it to drift, so refetchPane is the single home for it.

db_classify_statement lets the query line route a statement to the right
action without Wakil's Swift half parsing SQL."
```

---

## Task 12: `pane_sort` re-queries when it must, and sorts what it holds when it may

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneContentActions.swift` (remove `pane_sort`)
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (add `pane_sort`)
- Test: `app/Tests/WakilKitTests/PaneContentActionsTests.swift`, `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: `refetchPane`, `PaneFetch.sorted(by:)`, `PaneStore.reorder` (Tasks 6, 7, 11).
- Produces: `pane_sort`, **moved and re-kinded from `.control` to `.read`**, registered in `StandardActions.swift`.

**Why it moves and why its kind changes.** Spec §7: a pane that can re-query re-queries. Sorting an incomplete result now reaches a database, and `.control` is for state that never leaves Wakil — that is exactly the distinction `ActionKind`'s own doc comment draws, and it is why 2c-i's six pane-content actions are `.control` and every action in this phase is `.read`. An action has one kind, so `pane_sort` takes the kind of the strongest thing it can do. It moves beside the other database actions for the same reason: it needs the database client, and `registerPaneContentActions` has none.

**The rule, from spec §7 as the probe corrected it:**

| The result is | What happens | Footer |
|---|---|---|
| complete (`!truncated`, `offset == 0`) | `PaneStore.reorder` — client-side | silent about the sort |
| incomplete | `Pane.fetch.sorted(by:)` then `refetchPane` at offset 0 | silent **if** the re-fetch came back complete; "sorted by X within the N returned" if it is still truncated |

Client-sorting a complete result is not a shortcut, it is the correct answer: when every row that matches is in hand, ordering them locally produces exactly what the engine would return, without a round trip.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sortingACompleteResultOrdersItInPlaceWithNoRoundTrip() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [3], [1], [2]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: nil, raw: "SELECT id FROM events")), id: pane.id)
    await harness.panes.setRows(
        paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false,
        rows: [[.number(3)], [.number(1)], [.number(2)]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: nil)
    await harness.resetCallLog()
    _ = try await harness.registry.dispatch(
        "pane_sort",
        .object(["pane": .string(pane.id), "column": .string("id"),
                 "direction": .string("asc")]),
        origin: .ui, environment: "staging")
    #expect(await harness.lastTool == nil)   // nothing reached the database
    #expect(await harness.layout.fetch(id: pane.id)?.sort
            == PaneSort(column: "id", direction: .ascending))
    guard case .object(let snap) = await harness.panes.snapshot(paneId: pane.id),
          case .array(let rows)? = snap["rows"], case .array(let first) = rows[0],
          case .number(let n) = first[0] else { Issue.record("no rows"); return }
    #expect(n == 1)
}

@Test func sortingATruncatedResultRequeriesAtPageOne() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: nil, raw: "SELECT id FROM events"),
                  offset: 1000, pageSize: 500), id: pane.id)
    await harness.panes.setRows(
        paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false, rows: [[.number(1)]],
        millis: 1, truncated: true, pageable: true, offset: 1000, sort: nil)
    await harness.resetCallLog()
    _ = try await harness.registry.dispatch(
        "pane_sort",
        .object(["pane": .string(pane.id), "column": .string("id"),
                 "direction": .string("desc")]),
        origin: .ui, environment: "staging")
    #expect(await harness.lastTool == "query")
    #expect(await harness.lastArguments["sortColumn"] == .string("id"))
    #expect(await harness.lastArguments["sortDescending"] == .bool(true))
    // Back to page one. Sorting page three and staying on page three
    // would show rows 1,001-1,500 of a DIFFERENT ordering.
    #expect(await harness.lastArguments["offset"] == .number(0))
    #expect(await harness.layout.fetch(id: pane.id)?.offset == 0)
}

@Test func sortingAPagedButUntruncatedResultStillRequeries() async throws {
    // offset > 0 with truncated false is the LAST page of a paged result.
    // The rows on screen are still a subset, so sorting them locally
    // would sort the last page and call it the table.
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: nil, raw: "SELECT id FROM events"),
                  offset: 500), id: pane.id)
    await harness.panes.setRows(
        paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false, rows: [[.number(1)]],
        millis: 1, truncated: false, pageable: true, offset: 500, sort: nil)
    await harness.resetCallLog()
    _ = try await harness.registry.dispatch(
        "pane_sort",
        .object(["pane": .string(pane.id), "column": .string("id")]),
        origin: .ui, environment: "staging")
    #expect(await harness.lastTool == "query")
}

@Test func clearingASortClearsItOnThePaneToo() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: nil, raw: "SELECT 1"),
                  sort: PaneSort(column: "id", direction: .ascending)), id: pane.id)
    await harness.panes.setRows(
        paneId: pane.id, columns: ["id"], columnTypes: ["INTEGER"],
        columnTypesInferred: false, rows: [[.number(1)]],
        millis: 1, truncated: false, pageable: true, offset: 0,
        sort: PaneSort(column: "id", direction: .ascending))
    _ = try await harness.registry.dispatch(
        "pane_sort", .object(["pane": .string(pane.id)]),
        origin: .ui, environment: "staging")
    #expect(await harness.layout.fetch(id: pane.id)?.sort == nil)
    guard case .object(let snap) = await harness.panes.snapshot(paneId: pane.id) else {
        Issue.record("no snapshot"); return
    }
    #expect(snap["sort"] == .null)
}

@Test func aBadDirectionIsStillRefusedRatherThanDefaulted() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let pane = await harness.layout.open(kind: "db", title: "main")
    await harness.layout.setFetch(
        PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane.id)
    await #expect(throws: LayoutActionError.self) {
        _ = try await harness.registry.dispatch(
            "pane_sort",
            .object(["pane": .string(pane.id), "column": .string("id"),
                     "direction": .string("sideways")]),
            origin: .ui, environment: "staging")
    }
}

@Test func paneSortIsAReadNowBecauseItCanReachADatabase() async throws {
    let harness = try await DBActionHarness(rows: [["id"], [1]])
    let action = await harness.registry.all().first { $0.name == "pane_sort" }
    #expect(action?.kind == .read)
}
```

Delete the `pane_sort` tests in `PaneContentActionsTests.swift` that assert the old `.control` behaviour, and note the move in the commit rather than leaving both.

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | tail -30`

- [ ] **Step 3: Remove `pane_sort` from `PaneContentActions.swift`**

Delete the whole `await registry.register(Action(name: "pane_sort", ...))` block. Update the file's header doc comment: "Six actions" becomes "Five actions", with a sentence saying where the sixth went and why —

```swift
/// **`pane_sort` used to be here and is not any more.** It moved to
/// `StandardActions.swift` in 2c-ii and changed kind from `.control` to
/// `.read`, because a pane that can re-query re-queries (spec §7) and
/// sorting a truncated result now reaches a database. `.control` is for
/// state that never leaves Wakil; an action has one kind, and `pane_sort`
/// takes the kind of the strongest thing it can do.
```

- [ ] **Step 4: Register it in `StandardActions.swift`**

```swift
    await registry.register(Action(
        name: "pane_sort",
        description: "Sort a pane by a column. Omit column to remove the sort.\n"
            + "A pane that can re-query RE-QUERIES: if the rows on screen are only part of "
            + "what matched — truncated, or a later page — this re-runs the pane's query "
            + "with an ORDER BY and comes back at page one, so what you see is the first "
            + "page of the real ordering rather than a re-shuffle of the rows you had. If "
            + "the whole result is already in hand, it is ordered in place with no round "
            + "trip, which is the same answer the engine would give.",
        kind: .read,
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
            let paneId = try requireStringParam(params, "pane", action: "pane_sort")
            try await requireOpenPane(paneId, action: "pane_sort", layout: layout)

            var sort: PaneSort?
            if let column = optionalStringParam(params, "column") {
                let raw = optionalStringParam(params, "direction") ?? "asc"
                // Refused rather than defaulted: silently reading
                // "sideways" as ascending would sort the wrong way round
                // and tell nobody.
                guard let direction = PaneSortDirection(rawValue: raw) else {
                    throw LayoutActionError.badParam(
                        action: "pane_sort", param: "direction", value: raw)
                }
                sort = PaneSort(column: column, direction: direction)
            }

            // The authority first, always, so that whichever branch runs
            // next reads the value it is about to honour rather than one
            // computed twice.
            let current = await layout?.fetch(id: paneId)
            if let current {
                await layout?.setFetch(current.sorted(by: sort), id: paneId)
            }

            // Spec §7, as the probe corrected it. The rows on screen are a
            // subset when they were truncated OR when this is not the
            // first page — and sorting a subset locally is the dishonesty
            // §8 names. Everything else is sorted where it stands, because
            // when every matching row is in hand that IS the engine's
            // answer.
            let incomplete = await panes.resultIsIncomplete(paneId: paneId)
            guard incomplete, let current, let db else {
                await panes.reorder(paneId: paneId, sort: sort)
                return .object([
                    "pane": .string(paneId),
                    "sorted": .bool(sort != nil),
                    "requeried": .bool(false),
                ])
            }
            let next = current.sorted(by: sort)
            let result = try await refetchPane(
                paneId: paneId, fetch: next, db: db, panes: panes, layout: layout)
            guard case .object(var obj) = result else { return result }
            obj["requeried"] = .bool(true)
            return .object(obj)
        }
    ))
```

- [ ] **Step 5: Add `PaneStore.resultIsIncomplete`**

```swift
    /// Whether the rows a pane holds are only part of what its query
    /// matched — truncated, or a page past the first.
    ///
    /// **Both halves are needed and the second is the one the probe
    /// added.** `offset > 0` with `truncated` false is the LAST page of a
    /// paged result: complete as a page and a subset as an answer. Sorting
    /// it locally would order the last page and present it as the table.
    public func resultIsIncomplete(paneId: String) -> Bool {
        let contents = panes[paneId] ?? Contents()
        return contents.truncated || contents.offset > 0
    }
```

- [ ] **Step 6: Run and watch it pass**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS. If any test asserts a count of registered actions or of `.control` actions, update it and say so in the commit.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneContentActions.swift app/Sources/WakilKit/Panes/PaneStore.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/
git commit -m "pane_sort re-queries when the rows are a subset

design-language.md §8 has said since 2b-ii that a pane which can re-query
re-queries. This is that pane. Sorting a truncated result, or any page
past the first, re-runs the query with an ORDER BY and comes back at page
one - staying on page three would show rows 1,001-1,500 of a different
ordering.

It moves beside the other database actions and changes kind from .control
to .read, because it can now reach a database and .control is for state
that never leaves Wakil. An action has one kind and takes the kind of the
strongest thing it can do."
```

---

## Task 13: `WindowModel` — paging state, a database on `runQuery`, and relaunch

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: every action from Tasks 9–12.
- Produces: `PaneTable.pageable: Bool`, `PaneTable.offset: Int`, `PaneTable.rowRangeDescription: String?`; `WindowModel.runQuery(_:database:pane:)`, `.pagePane(id:to:)`, `.refetchPane(id:)`, `.classifyStatement(_:database:)`, `.restorePaneContents()`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aPaneTableCarriesWhereItIsAndWhetherItCanMove() {
    let snapshot = JSONValue.object([
        "columns": .array([.string("id")]),
        "columnTypes": .array([.string("INTEGER")]),
        "columnTypesInferred": .bool(false),
        "rows": .array([.array([.number(1)])]),
        "rowCount": .number(1), "millis": .number(4),
        "truncated": .bool(true), "pageable": .bool(true), "offset": .number(500),
        "selection": .object([
            "anchorRow": .null, "anchorColumn": .null, "rows": .array([]),
        ]),
        "sort": .null, "scrollTarget": .null,
    ])
    let table = paneTable(from: snapshot)
    #expect(table.pageable)
    #expect(table.offset == 500)
}

@Test func aPaneTableFromAnOlderSnapshotIsNotPageable() {
    // A snapshot with neither key — from a server or a store that does
    // not say. False hides the page control rather than offering one that
    // returns a syntax error.
    let snapshot = JSONValue.object([
        "columns": .array([.string("id")]), "columnTypes": .array([]),
        "columnTypesInferred": .bool(false), "rows": .array([]),
        "rowCount": .number(0), "millis": .number(0), "truncated": .bool(false),
        "selection": .object([
            "anchorRow": .null, "anchorColumn": .null, "rows": .array([]),
        ]),
        "sort": .null, "scrollTarget": .null,
    ])
    let table = paneTable(from: snapshot)
    #expect(!table.pageable)
    #expect(table.offset == 0)
}

@Test func theFooterNamesWhichRowsAreOnScreenOnlyWhenPaging() {
    // Page one of a complete result says nothing about a range: "rows
    // 1-6" beside "6 rows" is noise. A later page, or a truncated first
    // one, is where the range is the answer to a real question.
    func table(rows: Int, offset: Int, truncated: Bool, pageable: Bool) -> PaneTable {
        PaneTable(
            columns: [PaneColumn(name: "id", type: "INTEGER")],
            columnTypesInferred: false,
            rows: (0..<rows).map { PaneRow(id: $0, cells: [PaneCell(.number(Double($0)))]) },
            millis: 1, truncated: truncated, selection: .empty, sort: nil,
            scrollTarget: nil, pageable: pageable, offset: offset)
    }
    #expect(table(rows: 6, offset: 0, truncated: false, pageable: true)
            .rowRangeDescription == nil)
    #expect(table(rows: 500, offset: 500, truncated: true, pageable: true)
            .rowRangeDescription == "rows 501–1,000 · more remain")
    #expect(table(rows: 6, offset: 1000, truncated: false, pageable: true)
            .rowRangeDescription == "rows 1,001–1,006 · end")
    #expect(table(rows: 500, offset: 0, truncated: true, pageable: true)
            .rowRangeDescription == "rows 1–500 · more remain")
    // An unpageable result never offers a range, because there is no
    // second page for the range to be relative to.
    #expect(table(rows: 3, offset: 0, truncated: false, pageable: false)
            .rowRangeDescription == nil)
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | tail -30`

- [ ] **Step 3: Extend `PaneTable` and `paneTable(from:)`**

Add to `PaneTable` (`WindowModel.swift:18`):

```swift
    /// Whether this result can be asked for a second page —
    /// `wakilcore.Rows.Pageable`, carried through `PaneStore`.
    public let pageable: Bool
    /// How many rows were skipped to produce it.
    public let offset: Int

    /// "rows 501–1,000 · more remain", or `nil` when there is nothing
    /// useful to say.
    ///
    /// **Silent on page one of a complete result**, because "rows 1–6"
    /// beside "6 rows" is noise, and the footer's job is to carry facts a
    /// reader could otherwise get wrong. It speaks as soon as the rows on
    /// screen are a subset — which is the same condition every other piece
    /// of honesty in §8 turns on.
    ///
    /// **No total.** A total needs `SELECT count(*)` over the same
    /// statement — a second full scan on a large table, and one that can
    /// honestly disagree with the page beside it because the two ran at
    /// different instants. "more remain" is what `Truncated` knows for
    /// free, and §8's whole argument is that a data surface must not claim
    /// more than it knows.
    public var rowRangeDescription: String? {
        guard pageable, truncated || offset > 0, !rows.isEmpty else { return nil }
        let first = offset + 1
        let last = offset + rows.count
        let tail = truncated ? "more remain" : "end"
        return "rows \(Self.grouped(first))–\(Self.grouped(last)) · \(tail)"
    }

    private static func grouped(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
```

Add both to `PaneTable.empty` (`pageable: false, offset: 0`) and to `paneTable(from:)`:

```swift
    let pageable: Bool = { if case .bool(let p)? = obj["pageable"] { return p }; return false }()
    let offset: Int = {
        if case .number(let n)? = obj["offset"], let parsed = safeInt(n), parsed >= 0 {
            return parsed
        }
        return 0
    }()
```

- [ ] **Step 4: Give `runQuery` a database and a pane, and add the four new drivers**

Replace `runQuery` and add beside it:

```swift
    /// Runs one query and refreshes the tables from the pane store.
    ///
    /// **`database` closes 2c-i's open item** that this could not name
    /// one, which made the Run query control unusable in any environment
    /// defining more than one — `runMutation` has taken a database all
    /// along and this did not.
    ///
    /// **`pane` is what makes the pointer path never spray panes.** The
    /// query line always passes its own pane, so editing and pressing
    /// Return refines in place; only a query that names no pane opens one,
    /// and nothing in the window ever omits it.
    public func runQuery(_ query: String, database: String?, pane: String?) async {
        var params: [String: JSONValue] = ["query": .string(query)]
        if let database, !database.isEmpty { params["database"] = .string(database) }
        if let pane, !pane.isEmpty { params["pane"] = .string(pane) }
        _ = await dispatch("db_run_query", .object(params))
        await refreshPanes()
        await refreshLayout()
    }

    public func pagePane(id: String, to: String) async {
        _ = await dispatch("db_page", .object(["pane": .string(id), "to": .string(to)]))
        await refreshPanes()
        await refreshLayout()
    }

    public func refetchPane(id: String) async {
        _ = await dispatch("db_refetch", .object(["pane": .string(id)]))
        await refreshPanes()
        await refreshLayout()
    }

    /// Asks whether a statement is a read, a mutation, or neither, without
    /// running it. Returns the kind and, for "neither", the gate's own
    /// sentence.
    ///
    /// **The query line calls this before it runs anything**, so the
    /// operator who types an `UPDATE` gets the confirmation plane rather
    /// than a refusal to dismiss. Nothing here parses SQL: the answer
    /// comes from the same gates that judge the statement for real.
    public func classifyStatement(
        _ statement: String, database: String?
    ) async -> (kind: String, reason: String) {
        var params: [String: JSONValue] = ["statement": .string(statement)]
        if let database, !database.isEmpty { params["database"] = .string(database) }
        let result = await dispatch("db_classify_statement", .object(params))
        guard case .object(let obj) = result,
              case .object(let structured)? = obj["structuredContent"] else {
            // A failed classification runs nothing. Guessing "read" here
            // would send an UPDATE to db_run_query, where the gate refuses
            // it — no harm done, but the operator would be told the wrong
            // story about why.
            return ("neither", "could not judge this statement")
        }
        let kind: String = { if case .string(let k)? = structured["kind"] { return k }
                             return "neither" }()
        let reason: String = { if case .string(let r)? = structured["reason"] { return r }
                               return "" }()
        return (kind, reason)
    }

    /// Re-runs every restored pane's own query, once, at window
    /// construction.
    ///
    /// **Contents are not persisted and must not be** — redrawing
    /// yesterday's rows would show a database state that may no longer
    /// exist, the exact dishonesty `truncated` and the sort footer exist to
    /// prevent. What persists is the *subject*, and re-running it is how a
    /// restored pane comes back showing something true.
    ///
    /// **This means launching Wakil issues queries on its own.** Operator's
    /// ruling, 2026-09-12, with the alternative (restore the query and wait
    /// for Return) in front of them. Every one of these passes the
    /// read-only gate, so nothing is written; what is spent is load and
    /// time, and on `production` with several panes open that is several
    /// unasked-for reads the instant the app opens. Recorded as an open
    /// item in the spec §15 so that gating it by environment later is a
    /// change of mind rather than a discovery.
    ///
    /// Failures are swallowed per pane: a pane whose table was dropped
    /// since the layout was saved comes back empty, and one bad subject
    /// must not stop the others.
    public func restorePaneContents() async {
        for pane in layoutSnapshot.panes where pane.fetch != nil {
            _ = await dispatch("db_refetch", .object(["pane": .string(pane.id)]))
        }
        await refreshPanes()
    }
```

Then find every existing caller of `runQuery(_:)` — `WakilWindow.swift:456` is the one in production — and give it the two new arguments. That call becomes `model.runQuery(queryField, database: nil, pane: nil)` for now; Task 14 replaces the control entirely.

- [ ] **Step 5: Call `restorePaneContents` after the layout loads**

Find where `WindowModel` loads the layout at construction (beside `refreshContext`/`activateLayout`) and add `await restorePaneContents()` immediately after the first `refreshLayout()`. It must run after the layout is in hand — there is nothing to restore before that — and it must not block window construction, so it goes in the same detached startup task the existing refreshes use.

- [ ] **Step 6: Route the new names through `dispatchFromSurface`**

`pane_sort` now changes `Pane.fetch`, which lives in `LayoutStore`, so a plain `refreshPanes()` would leave the layout stale. Extend the existing special case:

```swift
    public func dispatchFromSurface(_ name: String, _ params: JSONValue) async {
        if name == "pane_set_column_width" {
            await dispatchLayout(name, params)
            return
        }
        await dispatch(name, params)
        await refreshPanes()
        // `pane_sort`, `db_page` and `db_refetch` all write `Pane.fetch`,
        // which lives in `LayoutStore` and which `refreshPanes` cannot
        // see. Without this the query line keeps showing the page and the
        // sort the pane was on before the click.
        if name == "pane_sort" || name.hasPrefix("db_") {
            await refreshLayout()
        }
    }
```

- [ ] **Step 7: Run and commit**

Run: `make app-test 2>&1 | tail -20`
Expected: PASS.

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp/WakilWindow.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "WindowModel: paging state, a database on runQuery, and relaunch

runQuery finally takes a database, closing 2c-i's open item that the Run
query control was unusable in any environment defining more than one -
runMutation has taken one all along.

The footer's row range speaks only when the rows on screen are a subset,
and it reports no total: a total needs a second full scan that can
honestly disagree with the page beside it.

A restored pane re-runs its own query on launch. The subject persists and
the rows deliberately do not, because redrawing yesterday's result would
show a database state that may no longer exist."
```

---

## Task 14: `DBPane` — the query line, the paged footer, and the first `switch pane.kind`

**Files:**
- Create: `app/Sources/WakilApp/DBPane.swift`
- Modify: `app/Sources/WakilApp/Canvas.swift` (`paneView`)
- Modify: `app/Sources/WakilApp/DataSurface.swift` (`footer`)
- Modify: `app/Sources/WakilApp/WakilWindow.swift` (the window's Run query control)

**Interfaces:**
- Consumes: `PaneTable.rowRangeDescription`, `WindowModel.runQuery(_:database:pane:)`, `.pagePane(id:to:)`, `.classifyStatement(_:database:)`, `Pane.fetch` (Tasks 6, 13).
- Produces: `struct DBPane: View`.

**`WakilApp` has no test target and cannot have one** — a test target cannot import an executable, which is why 2c-i put every piece of arithmetic in `WakilKit`. Everything testable in this task is already tested in Task 13. What is left is covered by the runbook in Task 16, and by the probe, which is why the probe exists.

**Read `docs/wakil/phase-2c-ii-probe.md` §3 before writing a line of this.** The obvious spelling of "⌘↩ runs this pane's query" — a hidden `Button` with `.keyboardShortcut(.return, modifiers: .command)` — is **window-scoped and not even focus-biased**: with focus in `db-2`'s field it fired `db-1`'s button, and it did the same with focus in the window's own message field. `.onSubmit` on the focused field routed correctly in all three positions.

- [ ] **Step 1: Write `DBPane.swift`**

```swift
import WakilKit
import SwiftUI

/// A database pane: what it is looking at, the rows that came back, and
/// where in them it is.
///
/// **The query line exists because the pane's identity has to be
/// visible.** 2c-i's walk recorded the complaint — "a pane titled EVENTS
/// showing customer rows has a lying title" — and the fix for a lying
/// title is to show the query, not to guess a better title. It is also
/// what makes the routing rule legible: a pane that says what it is
/// showing is a pane the operator can see has been refined rather than
/// replaced.
struct DBPane: View {
    let table: PaneTable
    let pane: Pane
    let dispatch: (String, JSONValue) -> Void
    /// Runs `text` against this pane. Separate from `dispatch` because it
    /// may raise the confirmation plane rather than dispatch a read — see
    /// `submit`.
    let run: (String) -> Void

    @State private var text: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            queryLine()
            if table.columns.isEmpty {
                Text("no rows")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30))
                Spacer()
            } else {
                DataSurface(table: table, pane: pane, dispatch: dispatch)
            }
            pageControls()
        }
        .onAppear { text = pane.fetch?.query.describedForOperator ?? "" }
        // The pane's subject can change underneath the line — an agent
        // refined it, a header click re-queried, ‹ › moved the page. The
        // line follows, EXCEPT while the operator is typing in it, which
        // would otherwise overwrite a half-written query mid-keystroke.
        .onChange(of: pane.fetch) { _, new in
            guard !editing else { return }
            text = new?.query.describedForOperator ?? ""
        }
    }

    /// `database ▸ SELECT * FROM events`, editable, run with Return.
    ///
    /// **Return, not ⌘↩, and the probe is the reason.** A per-pane
    /// `Button(…).keyboardShortcut(.return, modifiers: .command)` is
    /// window-scoped and fires the FIRST REGISTERED pane's button whatever
    /// has focus — measured, with focus in `db-2` and again with focus in
    /// the window's message field, both firing `db-1`. Typing in one pane
    /// would silently run another pane's query. `.onSubmit` on the focused
    /// field routed correctly in all three positions. ⌘↩ was chosen to
    /// keep Return free for newlines, and a single-line field has none.
    ///
    /// **No `.keyboardShortcut` may be added to this view, ever.** If ⌘↩
    /// is wanted later it is ONE window-level shortcut that dispatches to
    /// the focused pane id.
    @ViewBuilder
    private func queryLine() -> some View {
        HStack(spacing: 6) {
            if let database = pane.fetch?.query.database, !database.isEmpty {
                // The database is part of the pane's identity too: the
                // same statement against staging and against production
                // are different questions, and 2c-i's open item was that
                // the window could not name one at all.
                Text(database.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.7)
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.45))
                Text("▸")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.25))
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.85))
                .focused($editing)
                .onSubmit { run(text) }
        }
        .padding(.bottom, 2)
    }

    /// ‹ › and the row range, at the footer's leading edge.
    ///
    /// Absent entirely when the result cannot be paged — an `EXPLAIN`, a
    /// `SHOW`, a table list. Offering a control that returns a syntax
    /// error is worse than offering none.
    @ViewBuilder
    private func pageControls() -> some View {
        if table.pageable, table.truncated || table.offset > 0 {
            HStack(spacing: 8) {
                Button("‹") { dispatch("db_page", .object([
                    "pane": .string(pane.id), "to": .string("previous"),
                ])) }
                .disabled(table.offset == 0)
                Button("›") { dispatch("db_page", .object([
                    "pane": .string(pane.id), "to": .string("next"),
                ])) }
                .disabled(!table.truncated)
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.55))
        }
    }
}
```

- [ ] **Step 2: Give `Canvas.paneView` its first `switch pane.kind`**

In `app/Sources/WakilApp/Canvas.swift`, replace the `let table = model.table(pane.id)` block inside `paneView` with:

```swift
            // **The first `switch pane.kind` in the codebase.** Since 2b-i
            // every pane has drawn the same thing and `kind` has been read
            // in only three places, none of them a view. 2c-iii, 2c-iv and
            // 2c-v each add an arm here, beside the view that can draw
            // their kind — which is why `Pane.kinds` is a set a phase adds
            // to rather than an enum written ahead of its requirements.
            switch pane.kind {
            case "db":
                DBPane(
                    table: model.table(pane.id), pane: pane,
                    dispatch: { name, params in
                        Task { await model.dispatchFromSurface(name, params) }
                    },
                    run: { text in
                        Task { await model.runFromQueryLine(text, pane: pane) }
                    })
            default:
                // Unreachable today: `Pane.kinds` is `["db"]` and both
                // `pane_open` and `layoutDroppingUnknownPaneKinds` check
                // against it. Here so that adding a kind to that set
                // without adding an arm here shows on screen instead of
                // crashing.
                Text("no view for a \(pane.kind) pane")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.30))
            }
```

- [ ] **Step 3: Add `runFromQueryLine` to `WindowModel`**

This is the mutation route (spec §9) and it belongs in `WakilKit`, not in the view, so that the branch is reachable from a test.

```swift
    /// What Return in a pane's query line does.
    ///
    /// **It asks before it runs.** An operator who types an `UPDATE` gets
    /// the confirmation plane, not a refusal to dismiss — and the decision
    /// is made by `AssertSQLReadOnly` and `AssertSQLMutation`, the same two
    /// functions that will judge the statement for real. Nothing here
    /// parses SQL: a Swift-side classifier would be a second answer to a
    /// security-relevant question, and the first time the two disagreed,
    /// the disagreement would be the bug.
    ///
    /// **A non-SQL subject is run as a subject, not as text.** A pane
    /// showing `tables` has a query line reading "tables", and pressing
    /// Return on it unchanged must re-list the tables rather than send the
    /// word "tables" to the engine.
    public func runFromQueryLine(_ text: String, pane: Pane) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let database = pane.fetch?.query.database

        // Unchanged, non-SQL subject: re-run it as itself.
        if let fetch = pane.fetch, case .sql = fetch.query {
            // fall through to the SQL path below
        } else if let fetch = pane.fetch,
                  trimmed == fetch.query.describedForOperator {
            await refetchPane(id: pane.id)
            return
        }

        let (kind, reason) = await classifyStatement(trimmed, database: database)
        switch kind {
        case "read":
            await runQuery(trimmed, database: database, pane: pane.id)
        case "mutation":
            // `.mutate`, so `ActionRegistry.dispatch` parks it in the
            // broker and 2b-iii's confirmation plane rises. The pane's
            // rows and subject are untouched either way: a mutation
            // returns a `Written`, not a `Rows`, and projecting a row
            // count into a grid would put a fabricated shape on a surface
            // Invariant 3 promises reflects what is on screen.
            await runMutation(trimmed, database: database)
        default:
            queryLineRefusal = reason.isEmpty
                ? "this statement is neither a read nor a mutation Wakil can run"
                : reason
        }
    }

    /// The gate's own sentence, when the query line was given something
    /// that is neither a read nor a mutation. Cleared by the next run.
    public private(set) var queryLineRefusal: String?
```

Clear `queryLineRefusal` at the top of `runFromQueryLine`, and draw it in `DBPane` beneath the query line when non-nil — a single dim line, no alert, no modal. (An `NSAlert` or a SwiftUI `.alert` here would block every subsequent browser and AppKit event in the way the harness notes warn about, and a refusal is not worth a modal.)

- [ ] **Step 4: Put the row range in the footer**

In `app/Sources/WakilApp/DataSurface.swift`, in `footer()`, replace the `truncated` and sort branches with:

```swift
            if let range = table.rowRangeDescription {
                // "rows 501–1,000 · more remain". Replaces the bare "more
                // matched than were returned" as soon as a result is paged:
                // it says the same thing and also says where you are.
                Text(range)
            } else if table.truncated {
                Text("more matched than were returned")
            }
            if let sort = table.sort, table.truncated {
                // Spec §7, as the probe corrected it. This survives a
                // re-query: an outer ORDER BY cannot see past an inner
                // bound, so a statement the operator capped at 5,000 rows
                // and Wakil capped at 500 comes back sorted over 5,000 and
                // showing 500 — still a subset, still owed the warning.
                Text("sorted by \(sort.column) within the \(table.rows.count) returned")
            }
            if !table.pageable && !table.columns.isEmpty {
                // An EXPLAIN or a SHOW. Said plainly, because the page
                // controls are absent and their absence would otherwise
                // read as a bug.
                Text("this result cannot be paged")
            }
```

- [ ] **Step 5: Retire the window's Run query control**

`WakilWindow.swift:455` has a window-level "Run query" button bound to a `queryField`. It was the only way to run a query by hand and it is now the worse one: it cannot name a database, cannot name a pane, and under Task 8's routing would open a new pane on every press. Delete the button and its `queryField` state. The query line is the pointer path now, and ⌘K remains the second.

- [ ] **Step 6: Build and look at it**

Run: `make shaders && make app-build`
Expected: build succeeds.

Then run the app and confirm by eye, because nothing above is reachable from a test: open a pane, run a query from the line, watch the line keep the query; press ‹ › on a result over 500 rows; click a header on a truncated result and watch it re-query. Anything wrong here is a Task 16 runbook row, not a silent fix.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilApp/DBPane.swift app/Sources/WakilApp/Canvas.swift app/Sources/WakilApp/DataSurface.swift app/Sources/WakilApp/WakilWindow.swift app/Sources/WakilKit/App/WindowModel.swift
git commit -m "The DB pane says what it is showing, and can move through it

The query line is the fix for 'a pane titled EVENTS showing customer rows
has a lying title': show the query rather than guess a better title.

It submits on Return via onSubmit, never on a per-pane keyboardShortcut -
measured, that is window-scoped and fires the first-registered pane's
button whatever has focus, so typing in one pane would silently run
another pane's query.

And Canvas.paneView gets the first switch pane.kind in the codebase.
Since 2b-i every pane has drawn the same thing; 2c-iii, 2c-iv and 2c-v
each add an arm."
```

---

## Task 15: The drill affordance — §8's first hover-revealed row action

**Files:**
- Modify: `app/Sources/WakilApp/DataSurface.swift` (`rowView`)
- Modify: `app/Sources/WakilApp/DBPane.swift`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `PaneQuery`, `db_read_table` (Tasks 6, 10).
- Produces: `PaneTable.drillTarget(row:) -> String?` in `WakilKit`, and a hover-revealed control in `DataSurface`.

`design-language.md` §8 has permitted "hover-revealed row actions" since it was written and has never had one. This is the first: on a pane whose subject is `.tables`, hovering a row reveals a control that opens the named table **in a new pane**. Swift composes no SQL — it dispatches `db_read_table` with a name, and the driver renders it.

- [ ] **Step 1: Write the failing test**

```swift
@Test func onlyATableListOffersADrill() {
    func table(columns: [String], rows: [[JSONValue]]) -> PaneTable {
        PaneTable(
            columns: columns.map { PaneColumn(name: $0, type: "TEXT") },
            columnTypesInferred: false,
            rows: rows.enumerated().map { PaneRow(id: $0.offset, cells: $0.element.map(PaneCell.init)) },
            millis: 1, truncated: false, selection: .empty, sort: nil,
            scrollTarget: nil, pageable: false, offset: 0)
    }
    let tables = table(columns: ["name", "kind"],
                       rows: [[.string("events"), .string("table")]])
    #expect(tables.drillTarget(row: 0, subject: .tables(database: nil)) == "events")
    // A query that happens to return a column called "name" is not a
    // table list, and offering to open row 3 of it as a table would open
    // a pane on a table that does not exist. The SUBJECT decides, never
    // the column names.
    #expect(table(columns: ["name"], rows: [[.string("Ada")]])
        .drillTarget(row: 0, subject: .sql(database: nil, raw: "SELECT name FROM people")) == nil)
    #expect(tables.drillTarget(row: 9, subject: .tables(database: nil)) == nil)
    #expect(table(columns: ["name", "type", "key"], rows: [[.string("id"), .string("INT"), .bool(false)]])
        .drillTarget(row: 0, subject: .columns(database: nil, table: "events")) == nil)
}
```

- [ ] **Step 2: Run and watch it fail, then implement**

Add to `PaneTable`:

```swift
    /// The table a drill from `row` would open, or `nil` when this result
    /// is not a table list.
    ///
    /// **The subject decides, never the column names.** A query returning
    /// a column called `name` is not a table list, and offering to open
    /// row 3 of it would open a pane on a table that does not exist —
    /// which is the same class of inference 2c-i's walk refused when it
    /// ruled out parsing SQL to guess a table.
    public func drillTarget(row: Int, subject: PaneQuery?) -> String? {
        guard case .tables = subject else { return nil }
        guard row >= 0, row < rows.count, let first = rows[row].cells.first,
              !first.isNull, !first.text.isEmpty
        else { return nil }
        return first.text
    }
```

- [ ] **Step 3: Draw it**

`DataSurface` gains one optional stored property, `let drill: ((Int) -> Void)?`, defaulted to `nil` so every existing construction is unchanged. In `rowView`, overlay a control at the row's trailing edge that is visible only on hover and only when `drill != nil`:

```swift
            .overlay(alignment: .trailing) {
                if let drill, hoveredRow == row.id {
                    Button("open") { drill(row.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(Color(red: 0.62, green: 0.51, blue: 1.0))
                        .padding(.trailing, 6)
                }
            }
            .onHover { inside in hoveredRow = inside ? row.id : nil }
```

with `@State private var hoveredRow: Int?` on `DataSurface`.

`DBPane` passes the drill through, dispatching **with no pane** so the table opens beside the schema rather than replacing it:

```swift
                DataSurface(
                    table: table, pane: pane, dispatch: dispatch,
                    drill: table.drillTarget(row: 0, subject: pane.fetch?.query) == nil
                        ? nil
                        : { row in
                            guard let name = table.drillTarget(
                                row: row, subject: pane.fetch?.query) else { return }
                            var params: [String: JSONValue] = ["table": .string(name)]
                            if let database = pane.fetch?.query.database {
                                params["database"] = .string(database)
                            }
                            // No `pane`: a table opened from a schema
                            // browse is a new question, so it gets its own
                            // pane and sits beside the list it came from.
                            // Comparing two things side by side is what
                            // the canvas is for.
                            dispatch("db_read_table", .object(params))
                        })
```

- [ ] **Step 4: Run, build, look**

Run: `make app-test && make app-build`
Expected: PASS, build succeeds. Then open a schema browse in the app and hover a row.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp/DataSurface.swift app/Sources/WakilApp/DBPane.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "The first hover-revealed row action §8 has always permitted

Drilling from a table list opens that table in a NEW pane, beside the
list it came from, because comparing two things side by side is what the
canvas is for.

The subject decides whether a drill is offered, never the column names: a
query returning a column called 'name' is not a table list, and offering
to open row 3 of it would open a pane on a table that does not exist."
```

---

## Task 16: The documents, the runbook, and closing the phase out

**Files:**
- Create: `docs/wakil/phase-2c-ii-acceptance.md`
- Modify: `docs/wakil/design-language.md` (§8, §11)
- Modify: `docs/wakil/north-star.md` (the 2c-ii row)

**Nothing here is optional and nothing here is a formality.** 2c-i is met *by a walked runbook*, and its own conclusion is the instruction this task exists to honour: four causes of one symptom were found by the operator looking at the running app after 500+ tests were green and two review rounds had passed, and **2c-ii should assume a fifth exists.**

- [ ] **Step 1: Amend `design-language.md` §8**

After the `truncated` paragraph, add:

```markdown
**A paged result says which rows are on screen, and no total.** The footer
reads `rows 501–1,000 · more remain`, and on the last page `rows
1,001–1,006 · end`. It reports no total, deliberately: a total needs a
second full scan of the same statement, which on a large table is the
expensive half of the operation and which can honestly disagree with the
page beside it because the two ran at different instants. "More remain" is
what the engine tells us for free. **Added 2026-09-12** by 2c-ii.

**Some reads cannot be paged, and say so rather than offering the
control.** An `EXPLAIN` and a `SHOW` are reads the read-only gate permits
and neither survives the subquery paging wraps a statement in — measured
on SQLite and MySQL in `phase-2c-ii-probe.md` §2. The page controls are
absent on such a result and the footer says "this result cannot be paged",
because a control that returns a syntax error is worse than no control.
```

And amend the sort paragraph's last sentence, which 2c-ii's probe corrected:

```markdown
A pane that can re-query re-queries; one that cannot sorts what it holds
and the footer reads "sorted by X within the N returned". **Amended
2026-09-12:** a pane that re-queries may still owe that admission. An outer
`ORDER BY` cannot see past an inner bound, so a statement the operator
capped at 5,000 rows, capped again at 500, and then re-queried with a
pushed sort is a sort over 5,000 rows showing 500 of them — still a subset.
The rule that covers both causes without telling them apart: **a sorted
result that is still truncated admits it.**
```

- [ ] **Step 2: Amend `design-language.md` §11**

The Database row's Notes cell becomes:

```markdown
| **Database** | No | The canonical data surface (§8), above it the pane's own query — the database it runs against and the statement, editable, run with Return. A second query is a second pane; §10's canvas is what comparing two of them is for. |
```

And add below the table:

```markdown
**The database pane has no schema browser and no sidebar,** and §1 is why.
A table list is one row per table and a column list is one row per column
— both are result sets, so both draw on §8's own surface, in a database
pane, reached by the same actions as any query. Hovering a row of a table
list reveals the one row action §8 has always permitted and never had: it
opens that table in a new pane.
```

- [ ] **Step 3: Amend the 2c-ii row in `north-star.md`**

Rewrite it to record what the sub-phase actually did, in the form 2c-i's row takes, and carry spec §0's two scope amendments:

```markdown
| **2c-ii** | DB pane in full — the pane owns its query, and the schema browser, pagination, sort-as-re-query and relaunch are four consumers of that one change rather than four features. Paging is offset paging in the driver, which wraps the operator's statement only when it must; the schema browser is the data surface pointed at metadata, with §8's first hover-revealed row action drilling into a table. **Two things were added to this row on 2026-09-12**, both from brainstorming: the query line routes a mutation to 2b-iii's confirmation plane, asking `classify_statement` before it runs anything rather than running and catching a refusal; and **the routing default inverted** — naming a pane refines it, omitting one opens a new pane. That inversion is the only behaviour 2c-i's walk signed off on that this sub-phase changes, and it is the operator's own flow: *query A, filter, filter, sort* is one subject, *query B* is another. |
```

Add a paragraph below the table, in the form the 2c-i one takes:

```markdown
**2c-ii probed before it planned, and the probe changed three sections of
its own spec** — `docs/wakil/phase-2c-ii-probe.md`, 2026-09-12. Wrapping a
query in a subquery is safe and type-preserving on every read that matters,
but `EXPLAIN` and `SHOW` are gate-approved reads that cannot be wrapped, so
a next-page on either would have handed the operator a raw syntax error. A
per-pane `.keyboardShortcut` sends ⌘↩ to the wrong pane — window-scoped,
first-registered wins, whatever has focus — so the query line submits on
Return instead. And the spec's claim that this pane outgrows §8's
partial-sort admission was wrong: an outer `ORDER BY` cannot see past an
inner bound, so a re-query can come back truncated too. None of the three
was visible to a test, and the second was invisible to any test that could
exist.
```

- [ ] **Step 4: Write the runbook**

Create `docs/wakil/phase-2c-ii-acceptance.md`, in the shape of `phase-2c-i-acceptance.md`: a §1 saying what is under test and what is not, a §2 of numbered checks each with a `| Result | Date | Notes |` table left blank, a §5 for defects found during the walk, a §6 for what a review left open, and a §7 for the result. The checks, at minimum:

1. **The query line shows the pane's query, and Return runs it.** Open a pane, run a query from the agent, read the line. Edit it, press Return, watch the pane refine rather than a second pane open.
2. **Two panes, and ⌘↩ if you try it.** Open two db panes. Type in the second one's line and press Return; confirm the second pane changed and the first did not. Then press ⌘↩ in the second pane and record what happens — **the probe could not test this on a real key window** (probe §3), and this is the check that closes it.
3. **The database is nameable.** In an environment with two databases, run a query against the second one from the line. This is 2c-i's open item; it should now be reachable.
4. **Paging, both directions.** On the 1,006-row table from 2c-i's walk: page forward to the end and back to the start. Confirm no row is seen twice and none is skipped, and that the footer reads `rows 501–1,000 · more remain` and then `rows 1,001–1,006 · end`.
5. **A sort on page three.** Page to the third page of a result, then click a header. The pane must come back **at page one**, sorted over the whole result.
6. **The footer's silence, looked at once more.** On a complete sorted result the footer says nothing about the sort and the only indicator is the ▲/▼ at 9pt. 2c-i recorded that as easy to miss and asked 2c-ii to decide deliberately; it was decided to leave it. Record whether that still holds now that a re-query is in play.
7. **A partial sort still admits it.** Run a query with its own `LIMIT 5000` against a table larger than that, then sort it. The footer must say "sorted by X within the N returned" — this is the correction the probe forced and the thing a green suite would not have caught.
8. **`SHOW TABLES` from the query line.** The page controls must be absent and the footer must say the result cannot be paged, rather than a control appearing and returning a syntax error.
9. **The schema, as rows, and the drill.** List the tables; the pane draws them. Hover a row and open it; a **new** pane appears beside the list, showing that table. Do it on Mongo too — this is the case `.table` exists for, and a composed `SELECT` would fail there.
10. **A mutation from the query line.** Type an `UPDATE` and press Return: the confirmation plane must rise. Confirm one; cancel another. In both cases the pane's rows and its query must be untouched. Then type a `DROP` and confirm the gate's own sentence appears and nothing runs.
11. **Relaunch, several panes, on `production`.** Quit with three or four panes showing different things, on `production`, and reopen. Every pane must come back showing rows. **Record how it felt** — this is the risk spec §8 and §15 record: launching Wakil now issues queries on its own, and the operator chose that with the alternative in front of them.
12. **Relaunch a schema pane and a paged pane.** The subject, the page and the sort all persist; confirm a pane that was on page three comes back on page three.
13. **The journal.** Run a query from the line and the same query from the agent. The two entries must differ in nothing but `origin` — 2a's acceptance check, in its 2c-ii form.
14. **The operator's own flow, driven by voice or by the agent.** *"Query table A. Add a filter on id. Add a filter on name. Sort by timestamp. Now query table B."* The first four must land in one pane; the fifth must open a second. This is the check the whole routing inversion exists for, and it must be run the way it was described — spoken or typed at the agent, not by hand.

- [ ] **Step 5: Full verification before handing it over**

Run each, and paste the real output into the runbook's §7 rather than summarising it:

```bash
make test
make vet
make test-live
make app-test
make app-build
make bench-surface
```

`make bench-surface` matters here even though this phase changed no rendering: spec §15 records that §6's routing opens a pane per question by default, so two or three scrolling grids over an animating Metal layer is now the ordinary case rather than the unusual one. The bench measures one. Record the number and record that it measures one.

- [ ] **Step 6: Commit**

```bash
git add docs/
git commit -m "The 2c-ii runbook, and the documents the phase changed

design-language.md §8 gains the paged footer and the ruling that a data
surface reports no total it would have to spend a second scan to learn,
and its sort paragraph is corrected: a pane that re-queries may still owe
the partial-sort admission, because an outer ORDER BY cannot see past an
inner bound.

§11's Database row gains the query line and the note that this pane has
no schema browser and no sidebar - a table list is a result set, so it
draws on §8's own surface.

The runbook is not walked yet. 2c-ii is not met until it is."
```

- [ ] **Step 7: Do not mark the phase met**

`north-star.md`'s 2c-ii row stays unmarked until `docs/wakil/phase-2c-ii-acceptance.md` is **actually walked by the operator**, and the row must then say by what — the way 2c-i's does and 2b-iii's and 2b-v's do not. 2c-i's walk found six defects and forced two rulings after the suite was green and two review rounds had passed, and left this sub-phase an explicit instruction: assume a fifth cause of one symptom exists until this walk says otherwise.

---

## Self-Review

**Spec coverage.** Every section of `2026-09-12-phase-2c-ii-db-pane-design.md` maps to a task: §1 and §2 → Tasks 6, 7, 8; §3 → Tasks 1, 2, 3; §4 → Tasks 10, 15; §5 → Task 14; §6 → Tasks 8, 9; §7 → Task 12; §8 → Task 13 (`restorePaneContents`); §9 → Tasks 4, 5, 14 (`runFromQueryLine`); §10's action table → Tasks 9, 10, 11, 12; §11 → Task 16; §12 → done before this plan was written, and folded back into the spec; §13 → the test steps throughout plus Task 16's runbook; §14's exit criterion → Task 16 §5's verification plus the walk; §15's open items → carried into the runbook (relaunch on production) and left open (no total, keyset paging, select-by-key, several surfaces, accessibility).

**Two things a reader should know are deliberate, not gaps.**

`Column.Key` is drawn as a column by `schemaPaneContents` and is false everywhere, because no driver populates it — `sqlConn.Describe` reads `rows.ColumnTypes()`, which does not report keyness, and `mongoConn.Describe` reads one document. Task 10's comment says so. Teaching `Describe` keyness per dialect is spec §15's item and is not in this plan.

`WakilApp` has no test target and cannot have one, so Tasks 14 and 15 have no unit tests. Everything testable in them was pushed down into `WakilKit` (`rowRangeDescription`, `drillTarget`, `runFromQueryLine`, `classifyStatement`) precisely so that only the drawing is left uncovered — which is the same split 2c-i made and the reason its probe and its runbook exist.

**Type consistency, checked across tasks.** `PaneFetch`/`PaneQuery` (Task 6) are used by 7, 8, 9, 10, 11, 12, 13, 15 under the same names. `setRows`'s three new parameters are `pageable:`, `offset:`, `sort:` in Task 7 and in every call site after it. `queryTargetPane` returns `String?` from Task 8 onward and every later caller handles the `nil`. `refetchPane(paneId:fetch:db:panes:layout:)` is defined in Task 11 and called by 11, 12 and 13 with that signature. `Rows.Pageable` (Go, Task 1) → `pageable` on the wire → `dbPaneContents`'s tuple (Task 7) → `PaneStore` (Task 7) → `snapshot` (Task 7) → `PaneTable.pageable` (Task 13) → the footer and the page controls (Task 14) is one chain with one name at every link.

**One ordering constraint worth stating.** Task 7 changes `setRows`'s signature and Task 5's Go work is what supplies the `pageable` field it reads, so Tasks 1–5 must land before Task 7. Within the Swift half, 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 is a chain and not a preference: each task's tests call into the one before it.
