# DB pane: copy, cancel and row detail — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A DB pane read can be cancelled (and is stopped on the server), rows can be copied out of the grid as TSV or JSON, and a row can be read whole in a side strip that scrolls for big cells.

**Architecture:** Go proves cancellation per driver and adds `KILL QUERY` for MySQL only. WakilKit gains a per-pane DB *flight* on `PaneStore` (the shape of the API pane's `ApiFlight`), a `db_cancel` action, and three pure modules — `GridCopy`, `RowDetail`, and the grid's key rule. WakilApp draws: keys and a context menu on `DataSurface`, a footer `running · N s` with Cancel, and a new `RowDetailStrip`.

**Tech Stack:** Go 1.27 (go-sql-driver/mysql v1.10.1, modernc.org/sqlite v1.58.0, mongo-driver v2.8.2, go-sdk MCP), Swift 6 / SwiftUI / AppKit (TextKit 2), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-13-db-pane-copy-cancel-detail-design.md` — read it first. It carries the measurements (MySQL keeps running a cancelled statement; Mongo does not) and the Interaction Rules table this plan builds against.

## Global Constraints

- `PRODUCT.md` §Interaction Rules bind every UI step. Rule 4: anything that waits can be cancelled. Rule 5: a second read on a running pane is refused. Rule 6: stay where the operator was. Rule 8: never truncate an error or a strip value.
- **No `.keyboardShortcut` in a pane view, ever** (`DBPane.swift:193-197`, `DataSurface.swift:755-761`). Keys go through `.onKeyPress(phases: .down)` on the focused surface.
- Pure decisions live in `WakilKit`, never `WakilApp` (which has no test target) — `CONTRIBUTING.md` "Where does my code go?".
- A new action declares an `audience` (`ActionClassificationTests`).
- `db_run_mutation` is never part of a flight and never cancellable.
- Footer copy, verbatim: `running · 3.2 s`, `cancelled after 3.2 s` (one decimal, as `apiSeconds` formats). The Cancel verb's label is `Cancel`.
- Commits: no `Co-Authored-By` and no "Generated with" lines (`CONTRIBUTING.md` "Before a PR").
- Go runs with `CGO_ENABLED=0` (the Makefile exports it). Swift tests run from `app/` with `../scripts/swift-test.sh --filter <Name>`.
- **Subagents run only scoped filters.** The full `make test`, `make app-test`, `make e2e` gates are the controller's.

## Review Focus

1. **A reply that lands in the same instant as Cancel.** Expect: the rows that were on screen stay, the footer says `cancelled after`, and the late reply is dropped. → Task 4 test `aLateReplyAfterCancelIsDropped`.
2. **An environment switch while a read is running.** Expect: the read is cancelled and the pane re-runs its subject in the new environment — not "a read is already running". → Task 6 test `restoreCancelsReadsInFlightFirst`.
3. **A MySQL kill landing on a reused connection.** Expect: a fast read that finishes before the kill fires is never followed by a `KILL QUERY` on that connection id. → Task 1 test `TestMySQLKillNeverOutlivesItsRead`.
4. **Copying a cell whose text holds a tab, newline or quote, or an Int64 past 2^53.** Expect: the pasted table keeps its shape and the number keeps every digit. → Task 2 tests.
5. **A text cell that merely looks like JSON (`"42"`, `"true"`, `"[oops"`).** Expect: shown as plain text, not reformatted. → Task 3 tests.

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `internal/wakilcore/sqlconn.go` | Modify | `killsOnCancel` field; `queryContext` pins a connection and kills its statement when ctx ends; `Read`/`ReadTable` use it |
| `internal/wakilcore/driver_mysql.go` | Modify | Set `killsOnCancel: true` in `Connect` |
| `internal/wakilcore/sqlconn_cancel_test.go` | Create | SQLite cancel test (always runs) |
| `internal/wakilcore/driver_mysql_test.go` | Modify | Live MySQL cancel + no-stray-kill tests |
| `internal/wakilcore/driver_mongo_test.go` | Modify | Live Mongo cancel test |
| `cmd/wakil-db/cancel_test.go` | Create | Server-level: `notifications/cancelled` ends the handler |
| `app/Sources/WakilKit/Core/PaneContents.swift` | Modify | `PaneCell.value` |
| `app/Sources/WakilKit/Panes/GridCopy.swift` | Create | `gridCopyText`, `gridCopyJSON`, `gridCopyCell`, `gridCopyRows` |
| `app/Sources/WakilKit/Panes/RowDetail.swift` | Create | `RowDetailField`, `rowDetailFields` |
| `app/Sources/WakilKit/Panes/DataSurfacePaneKind.swift` | Modify | `DBFlight`, `flight`/`cancelledAfterMs` on contents; snapshot + `read_pane` |
| `app/Sources/WakilKit/Panes/PaneSnapshot.swift` | Modify | `DataSurfaceSnapshot.runningSince`, `.cancelledAfterMs` |
| `app/Sources/WakilKit/Panes/PaneTable.swift` | Modify | `PaneTable.runningSince`, `.cancelledAfterMs` |
| `app/Sources/WakilKit/Panes/PaneStore.swift` | Modify | `beginDBRead`, `armDBRead`, `cancelDBRead`, `finishDBRead`, `cancelAllDBReads` |
| `app/Sources/WakilKit/Registry/StandardActions.swift` | Modify | `dbReadInFlight`; flights in `refetchPane` + four handlers; `db_cancel`; two error cases |
| `app/Sources/WakilKit/Panes/DataSurfaceKeys.swift` | Create | `DataSurfaceKey`, `dataSurfaceKeyClaim`, `dbFlightLine` |
| `app/Sources/WakilKit/App/WindowModel.swift` | Modify | `cancelAllDBReads` before restore and before the org switch clears |
| `app/Sources/WakilApp/DataSurface.swift` | Modify | Keys, context menu, footer flight line + Cancel, strip host |
| `app/Sources/WakilApp/RowDetailStrip.swift` | Create | The strip and its read-only `NSTextView` value view |
| `app/Sources/WakilApp/QueryLineEditor.swift` | Modify | `cancel` closure for Esc while a read runs |
| `app/Sources/WakilApp/DBPane.swift` | Modify | Pass `cancel` to the query line |
| `docs/architecture/wakilkit.md`, `docs/architecture/wakilapp.md` | Modify | New files named under their folders |

---

### Task 1: Go — a cancelled read stops, on every engine

**Files:**
- Modify: `internal/wakilcore/sqlconn.go` (struct at top; `Read` ~line 258; `ReadTable` ~line 310)
- Modify: `internal/wakilcore/driver_mysql.go:69` (the `&sqlConn{` in `Connect`)
- Create: `internal/wakilcore/sqlconn_cancel_test.go`
- Modify: `internal/wakilcore/driver_mysql_test.go`, `internal/wakilcore/driver_mongo_test.go`
- Create: `cmd/wakil-db/cancel_test.go`

**Interfaces:**
- Produces: `func (c *sqlConn) queryContext(ctx context.Context, stmt string) (*sql.Rows, func(), error)` — callers `defer release()` after `rows.Close()`.
- Consumes: `seedSQLite(t)` (`driver_sqlite_test.go:13`), `setupSQLiteEventsProject(t)` (`cmd/wakil-db/main_test.go`), `resultWriter` pattern from `cmd/wakil-http/cancel_test.go`.

- [ ] **Step 1: Write the SQLite cancel test**

`internal/wakilcore/sqlconn_cancel_test.go`:

```go
package wakilcore

import (
	"context"
	"testing"
	"time"
)

// endlessCTE counts to two billion: minutes of work on any machine, and a
// WITH statement, so AssertSQLReadOnly lets it through like any read.
const endlessCTE = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 2000000000) SELECT max(x) AS n FROM c"

// A cancelled read returns at once rather than running to the end. modernc's
// driver interrupts the statement when the context ends; this pins it.
func TestSQLiteCancelledReadReturnsAtOnce(t *testing.T) {
	path := seedSQLite(t)
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: path})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(300*time.Millisecond, cancel)
	start := time.Now()
	_, err = conn.Read(ctx, QuerySpec{Raw: endlessCTE}, 10)
	if err == nil {
		t.Fatal("the read finished; it should have been cancelled")
	}
	if waited := time.Since(start); waited > 2*time.Second {
		t.Fatalf("the read returned %s after start — the cancel did not interrupt it", waited)
	}
}
```

- [ ] **Step 2: Run it**

Run: `go test ./internal/wakilcore/ -run TestSQLiteCancelledReadReturnsAtOnce -count=1 -v`
Expected: PASS (SQLite needs no code change). If it FAILS by timing out, stop and report — the spec assumes modernc interrupts on ctx, and a failure here changes the design.

- [ ] **Step 3: Write the failing live MySQL tests**

Append to `internal/wakilcore/driver_mysql_test.go` (keep the file's existing `WAKIL_MYSQL_DSN` gate shape; names start `TestMySQL` so `make test-live` selects them):

```go
// mysqlSleepsRunning counts SELECT SLEEP statements the server is still
// executing, on a connection of its own.
func mysqlSleepsRunning(t *testing.T, dsn string) int {
	t.Helper()
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	var n int
	err = raw.QueryRow(
		"SELECT COUNT(*) FROM information_schema.PROCESSLIST " +
			"WHERE COMMAND = 'Query' AND INFO LIKE 'SELECT SLEEP(%'").Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// Measured 2026-10-13: without a kill, MySQL keeps a cancelled SELECT SLEEP
// running after go-sql-driver drops the connection. The read must stop it.
func TestMySQLCancelledReadStopsOnTheServer(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(500*time.Millisecond, cancel)
	if _, err := conn.Read(ctx, QuerySpec{Raw: "SELECT SLEEP(20) AS s"}, 10); err == nil {
		t.Fatal("the read finished; it should have been cancelled")
	}
	deadline := time.Now().Add(2 * time.Second)
	for mysqlSleepsRunning(t, dsn) > 0 {
		if time.Now().After(deadline) {
			t.Fatal("SELECT SLEEP(20) is still running on the server 2 s after the cancel")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// Review Focus 3: a read that finishes first must never be followed by a
// kill — its connection goes back to the pool and the next statement on it
// would be the one killed.
func TestMySQLKillNeverOutlivesItsRead(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	for i := 0; i < 50; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		if _, err := conn.Read(ctx, QuerySpec{Raw: "SELECT 1 AS one"}, 10); err != nil {
			t.Fatalf("read %d: %v", i, err)
		}
		cancel() // after the read: must not kill anything
	}
	// A long read on the same pool, started after all fifty cancels: it must
	// run to completion, not be killed by a stray KILL QUERY.
	if _, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT SLEEP(1) AS s"}, 10); err != nil {
		t.Fatalf("a later read was killed: %v", err)
	}
}
```

Add `"database/sql"` and `"time"` to the file's imports if they are not there.

- [ ] **Step 4: Run them against a live MySQL and see the first fail**

Run:
```bash
docker start wakil-acc-mysql
WAKIL_MYSQL_DSN='root:rootpw@tcp(127.0.0.1:13306)/wakilacc' go test ./internal/wakilcore/ -run 'TestMySQLCancelledReadStopsOnTheServer|TestMySQLKillNeverOutlivesItsRead' -count=1 -v
```
Expected: `TestMySQLCancelledReadStopsOnTheServer` FAILS with "still running on the server 2 s after the cancel". `TestMySQLKillNeverOutlivesItsRead` PASSES (nothing kills yet).

- [ ] **Step 5: Implement `queryContext` and `killsOnCancel`**

In `internal/wakilcore/sqlconn.go`, add the field to `sqlConn` (after `quoteLiteral`):

```go
	// killsOnCancel is true for engines that keep running a statement after
	// its client goes away. MySQL does (measured 2026-10-13: a cancelled
	// SELECT SLEEP(20) was still in PROCESSLIST 3 s later); SQLite is
	// in-process and Mongo kills the operation itself.
	killsOnCancel bool
```

Add, below `Close`:

```go
// queryContext runs a read. On an engine that does not stop a statement
// when its client leaves (killsOnCancel), it pins one connection, reads its
// id, and when ctx ends issues KILL QUERY for that id on a second pooled
// connection. release must be called after the rows are closed: it waits
// for a kill already under way before the pinned connection goes back to
// the pool, so a kill can never land on a later statement that reuses it.
func (c *sqlConn) queryContext(ctx context.Context, stmt string) (*sql.Rows, func(), error) {
	if !c.killsOnCancel {
		rows, err := c.db.QueryContext(ctx, stmt)
		return rows, func() {}, err
	}
	pinned, err := c.db.Conn(ctx)
	if err != nil {
		return nil, func() {}, err
	}
	var id int64
	if err := pinned.QueryRowContext(ctx, "SELECT CONNECTION_ID()").Scan(&id); err != nil {
		pinned.Close()
		return nil, func() {}, err
	}
	killed := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		defer close(killed)
		kctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = c.db.ExecContext(kctx, fmt.Sprintf("KILL QUERY %d", id))
	})
	release := func() {
		if !stop() {
			<-killed // the kill started: let it finish before the connection is reused
		}
		pinned.Close()
	}
	rows, err := pinned.QueryContext(ctx, stmt)
	if err != nil {
		release()
		return nil, func() {}, err
	}
	return rows, release, nil
}
```

In `Read`, replace

```go
	rows, err := c.db.QueryContext(ctx, stmt)
	if err != nil {
		return Rows{}, UserError("query failed: " + err.Error())
	}
	defer rows.Close()
```

with

```go
	rows, release, err := c.queryContext(ctx, stmt)
	if err != nil {
		return Rows{}, UserError("query failed: " + err.Error())
	}
	defer release()
	defer rows.Close()
```

(`defer` runs last-in-first-out, so `rows.Close()` runs before `release()`.)

Make the same replacement in `ReadTable` — its error text stays `"cannot read " + name + ": " + err.Error()`.

In `internal/wakilcore/driver_mysql.go`, in `Connect`'s `return &sqlConn{`, add `killsOnCancel: true,`. Do **not** set it in `ConnectWritable` — writes are never cancelled (spec, "Not covered").

- [ ] **Step 6: Run the MySQL tests and the SQLite test**

Run:
```bash
WAKIL_MYSQL_DSN='root:rootpw@tcp(127.0.0.1:13306)/wakilacc' go test ./internal/wakilcore/ -run 'TestMySQLCancelledReadStopsOnTheServer|TestMySQLKillNeverOutlivesItsRead|TestSQLiteCancelledReadReturnsAtOnce|TestMySQLReadAndGate' -count=1 -v
```
Expected: all PASS.

- [ ] **Step 7: Write the live Mongo test**

Append to `internal/wakilcore/driver_mongo_test.go`, using its `mongoTestConn(t)` helper (returns `(Conn, string)` — the string is the database name; read the helper first and match it):

```go
// Measured 2026-10-13: Mongo ends an operation whose client went away. Pinned
// here so a driver upgrade that changes it is caught.
func TestMongoCancelledReadStopsOnTheServer(t *testing.T) {
	conn, _ := mongoTestConn(t)
	uri := os.Getenv("WAKIL_MONGO_URI")
	client, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect(context.Background())
	dbName := strings.TrimPrefix(mustParseURIPath(t, uri), "/")
	coll := client.Database(dbName).Collection("zz_cancel")
	_ = coll.Drop(context.Background())
	if _, err := coll.InsertMany(context.Background(), []any{bson.M{"a": 1}, bson.M{"a": 2}, bson.M{"a": 3}}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = coll.Drop(context.Background()) })

	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(500*time.Millisecond, cancel)
	q := `{"op":"find","collection":"zz_cancel","filter":{"$where":"sleep(5000) || true"}}`
	if _, err := conn.Read(ctx, QuerySpec{Raw: q}, 10); err == nil {
		t.Fatal("the read finished; it should have been cancelled")
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		var res bson.M
		err := client.Database("admin").RunCommand(context.Background(),
			bson.D{{Key: "currentOp", Value: 1}, {Key: "ns", Value: dbName + ".zz_cancel"}}).Decode(&res)
		if err != nil {
			t.Fatal(err)
		}
		if len(res["inprog"].(bson.A)) == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the $where sleep is still running on the server 5 s after the cancel")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func mustParseURIPath(t *testing.T, uri string) string {
	t.Helper()
	u, err := url.Parse(uri)
	if err != nil {
		t.Fatal(err)
	}
	return u.Path
}
```

Imports to add if missing: `"net/url"`, `"strings"`, `"time"`, `"go.mongodb.org/mongo-driver/v2/bson"`, `"go.mongodb.org/mongo-driver/v2/mongo"`, `"go.mongodb.org/mongo-driver/v2/mongo/options"`. (5 s, not 2 s: Mongo checks for interrupts between documents, and each `$where` sleeps 5 s; the 2026-10-13 measurement saw it gone inside 3 s.)

- [ ] **Step 8: Run it**

Run:
```bash
docker start wakil-acc-mongo
WAKIL_MONGO_URI='mongodb://127.0.0.1:27018/wakilacc' go test ./internal/wakilcore/ -run TestMongoCancelledReadStopsOnTheServer -count=1 -v
```
Expected: PASS.

- [ ] **Step 9: Write the server-level test**

`cmd/wakil-db/cancel_test.go` — the shape of `cmd/wakil-http/cancel_test.go`, against the SQLite fixture:

```go
package main

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// resultWriter signals when the server writes a tool result — the handler returning.
type resultWriter struct{ ch chan time.Time }

func (w *resultWriter) Write(p []byte) (int, error) {
	if bytes.Contains(p, []byte(`"isError"`)) || bytes.Contains(p, []byte(`"structuredContent"`)) {
		select {
		case w.ch <- time.Now():
		default:
		}
	}
	return len(p), nil
}

// The window cancels a read by cancelling the call: the go-sdk client sends
// notifications/cancelled, the server cancels the handler's ctx, and the
// driver's QueryContext ends. Observable: the handler returns within 2 s.
func TestACancelledQueryEndsTheHandler(t *testing.T) {
	setupSQLiteEventsProject(t)

	rw := &resultWriter{ch: make(chan time.Time, 1)}
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(context.Background(),
		&mcp.LoggingTransport{Transport: serverTransport, Writer: rw}, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "wakil-db-cancel-test", Version: "0.0.0"}, nil).
		Connect(context.Background(), clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = cs.CallTool(ctx, &mcp.CallToolParams{Name: "query", Arguments: map[string]any{
			"query": "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 2000000000) SELECT max(x) AS n FROM c",
		}})
	}()
	time.Sleep(300 * time.Millisecond)
	cancelledAt := time.Now()
	cancel()

	select {
	case at := <-rw.ch:
		if waited := at.Sub(cancelledAt); waited > 2*time.Second {
			t.Fatalf("the handler returned %s after the cancel — that is the query finishing, not a cancel", waited)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the handler was still running 10 s after the cancel")
	}
	<-done
}
```

If `resultWriter` collides with a name already in `package main` of `cmd/wakil-db`, rename it `cancelResultWriter`.

- [ ] **Step 10: Run it and the package**

Run: `go test ./cmd/wakil-db/ -count=1`
Expected: PASS, including `TestACancelledQueryEndsTheHandler`.

- [ ] **Step 11: Run the wakilcore package without live engines, then stop the containers**

Run: `go test ./internal/wakilcore/ -count=1 && docker stop wakil-acc-mysql wakil-acc-mongo`
Expected: `ok` (live tests skip without their env vars).

- [ ] **Step 12: Commit**

```bash
git add internal/wakilcore/sqlconn.go internal/wakilcore/driver_mysql.go internal/wakilcore/sqlconn_cancel_test.go internal/wakilcore/driver_mysql_test.go internal/wakilcore/driver_mongo_test.go cmd/wakil-db/cancel_test.go
git commit -m "wakil-db: a cancelled read stops on the server — KILL QUERY on MySQL, proved on SQLite and Mongo"
```

---

### Task 2: WakilKit — copy formatters

**Files:**
- Modify: `app/Sources/WakilKit/Core/PaneContents.swift:12-50` (`PaneCell`)
- Create: `app/Sources/WakilKit/Panes/GridCopy.swift`
- Test: `app/Tests/WakilKitTests/GridCopyTests.swift`

**Interfaces:**
- Produces:
  - `PaneCell.value: JSONValue` (the value it was built from)
  - `public func gridCopyCell(_ cell: PaneCell) -> String`
  - `public func gridCopyText(columns: [PaneColumn], rows: [PaneRow]) -> String`
  - `public func gridCopyJSON(columns: [PaneColumn], rows: [PaneRow]) -> String`
  - `public func gridCopyRows(selection: PaneSelection, clickedRow: Int?, rowCount: Int) -> [Int]`

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/GridCopyTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private let columns = [PaneColumn(name: "id", type: "int"), PaneColumn(name: "note", type: "text")]
private func row(_ id: Int, _ values: [JSONValue]) -> PaneRow {
    PaneRow(id: id, cells: values.map(PaneCell.init))
}

struct GridCopyTests {
    @Test func aCellKeepsTheValueItWasBuiltFrom() {
        let nested: JSONValue = .object(["a": .integer(1)])
        #expect(PaneCell(nested).value == nested)
        #expect(PaneCell(.null).value == .null)
    }

    @Test func oneCellCopiesAsItsTextAndNullAsEmpty() {
        #expect(gridCopyCell(PaneCell(.string("Omar"))) == "Omar")
        #expect(gridCopyCell(PaneCell(.null)) == "")
    }

    @Test func rowsCopyAsTabSeparatedWithAHeaderInColumnOrder() {
        let text = gridCopyText(columns: columns, rows: [
            row(0, [.integer(1), .string("a")]),
            row(1, [.integer(2), .null]),
        ])
        #expect(text == "id\tnote\n1\ta\n2\t")
    }

    @Test func aFieldWithATabNewlineOrQuoteIsQuotedExcelStyle() {
        let text = gridCopyText(columns: columns, rows: [
            row(0, [.integer(1), .string("a\tb")]),
            row(1, [.integer(2), .string("line1\nline2")]),
            row(2, [.integer(3), .string("say \"hi\"")]),
        ])
        #expect(text == "id\tnote\n1\t\"a\tb\"\n2\t\"line1\nline2\"\n3\t\"say \"\"hi\"\"\"")
    }

    @Test func unicodeAndALargeIntegerSurviveTSV() {
        let text = gridCopyText(columns: columns, rows: [row(0, [.integer(9_007_199_254_740_993), .string("قهوة ☕")])])
        #expect(text == "id\tnote\n9007199254740993\tقهوة ☕")
    }

    @Test func jsonIsAnArrayEvenForOneRowAndKeepsTypes() throws {
        let json = gridCopyJSON(columns: columns, rows: [row(0, [.integer(9_007_199_254_740_993), .null])])
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(parsed == .array([.object(["id": .integer(9_007_199_254_740_993), "note": .null])]))
    }

    @Test func jsonKeepsANestedDocumentAsAnObject() throws {
        let doc: JSONValue = .object(["nights": .integer(3), "addons": .array([.string("parking")])])
        let json = gridCopyJSON(columns: columns, rows: [row(0, [.integer(1), doc])])
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(parsed == .array([.object(["id": .integer(1), "note": doc])]))
    }

    @Test func theRowsCopiedAreTheSelectionWhenTheClickedRowIsInIt() {
        let selection = PaneSelection(anchorRow: 3, anchorColumn: "id", rows: [1, 3])
        #expect(gridCopyRows(selection: selection, clickedRow: 1, rowCount: 5) == [1, 3])
        #expect(gridCopyRows(selection: selection, clickedRow: 4, rowCount: 5) == [4])
        #expect(gridCopyRows(selection: selection, clickedRow: nil, rowCount: 5) == [1, 3])
        #expect(gridCopyRows(selection: .empty, clickedRow: nil, rowCount: 5) == [])
        #expect(gridCopyRows(selection: PaneSelection(anchorRow: 9, anchorColumn: nil, rows: [9]), clickedRow: nil, rowCount: 5) == [])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter GridCopyTests`
Expected: build FAILS — `value`, `gridCopyCell`, `gridCopyText`, `gridCopyJSON`, `gridCopyRows` not defined.

- [ ] **Step 3: Add `PaneCell.value`**

In `app/Sources/WakilKit/Core/PaneContents.swift`, in `PaneCell`, add the stored property after `isNull`:

```swift
    /// The value this cell was built from. `text` is its display form and loses types — a
    /// number and a numeric string draw alike — so anything that must keep them (Copy as JSON,
    /// the row detail strip) reads this.
    public let value: JSONValue
```

and make `value = value` the first line of `init(_ value: JSONValue)`. Leave every existing `switch` arm unchanged.

- [ ] **Step 4: Write `GridCopy.swift`**

`app/Sources/WakilKit/Panes/GridCopy.swift`:

```swift
import Foundation

/// What the DB grid's Copy puts on the pasteboard. View-only, like the terminal's Copy: it
/// changes no Wakil state, so it is no action — the agent reads the same values with
/// `read_pane`. Only the rows on screen are copied; nothing re-runs the query.

/// One cell, as plain text. NULL is empty, as a spreadsheet shows it.
public func gridCopyCell(_ cell: PaneCell) -> String {
    cell.isNull ? "" : cell.text
}

/// Rows as tab-separated text with a header row, columns in result order — what Sheets,
/// Numbers and Jira paste as a table. A field holding a tab, newline, carriage return or `"`
/// is quoted Excel-style, inner `"` doubled, so the pasted table keeps its shape.
public func gridCopyText(columns: [PaneColumn], rows: [PaneRow]) -> String {
    func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    let header = columns.map { field($0.name) }.joined(separator: "\t")
    let lines = rows.map { row in
        columns.indices.map { index in
            index < row.cells.count ? field(gridCopyCell(row.cells[index])) : ""
        }.joined(separator: "\t")
    }
    return ([header] + lines).joined(separator: "\n")
}

/// Rows as a JSON array of objects keyed by column name — an array even for one row. Values
/// keep their types (`PaneCell.value`): numbers stay numbers, NULL is `null`, a nested document
/// stays an object. Keys are sorted so the output is stable.
public func gridCopyJSON(columns: [PaneColumn], rows: [PaneRow]) -> String {
    let array = JSONValue.array(rows.map { row in
        var object: [String: JSONValue] = [:]
        for (index, column) in columns.enumerated() {
            object[column.name] = index < row.cells.count ? row.cells[index].value : .null
        }
        return .object(object)
    })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(array), let text = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return text
}

/// Which rows a copy takes, in display order. A right-click on a row inside the selection
/// copies the selection; on a row outside it, that row alone. With no click (⌘C), the
/// selection. Indexes past the rows on screen are dropped.
public func gridCopyRows(selection: PaneSelection, clickedRow: Int?, rowCount: Int) -> [Int] {
    let chosen: Set<Int>
    if let clickedRow, !selection.rows.contains(clickedRow) {
        chosen = [clickedRow]
    } else {
        chosen = selection.rows
    }
    return chosen.filter { $0 >= 0 && $0 < rowCount }.sorted()
}
```

- [ ] **Step 5: Run the tests and the other PaneCell users**

Run: `cd app && ../scripts/swift-test.sh --filter 'GridCopyTests|PaneContentsTests|JSONValueIntegerTests'`
Expected: PASS. If `JSONValueIntegerTests` fails on the large integer through `JSONEncoder`, check how `JSONValue.encode` writes `.integer` (it must write the Int64 digits, not a Double) and report rather than work around it.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Core/PaneContents.swift app/Sources/WakilKit/Panes/GridCopy.swift app/Tests/WakilKitTests/GridCopyTests.swift
git commit -m "WakilKit: the grid's copy formats — one cell, TSV with a header, JSON that keeps types"
```

---

### Task 3: WakilKit — row detail fields

**Files:**
- Create: `app/Sources/WakilKit/Panes/RowDetail.swift`
- Test: `app/Tests/WakilKitTests/RowDetailTests.swift`

**Interfaces:**
- Consumes: `PaneCell.value` (Task 2).
- Produces:
  ```swift
  public struct RowDetailField: Sendable, Equatable, Identifiable {
      public let name: String
      public let display: String
      public let isNull: Bool
      public let isJSON: Bool
      public var id: String { name }
  }
  public func rowDetailFields(columns: [PaneColumn], row: PaneRow) -> [RowDetailField]
  ```

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/RowDetailTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func fields(_ values: [(String, JSONValue)]) -> [RowDetailField] {
    rowDetailFields(
        columns: values.map { PaneColumn(name: $0.0, type: "") },
        row: PaneRow(id: 0, cells: values.map { PaneCell($0.1) }))
}

struct RowDetailTests {
    @Test func everyColumnIsAFieldInResultOrder() {
        let result = fields([("id", .integer(4102)), ("guest", .string("Omar K."))])
        #expect(result.map(\.name) == ["id", "guest"])
        #expect(result.map(\.display) == ["4102", "Omar K."])
    }

    @Test func nullIsMarkedAndHasNoText() {
        let field = fields([("notes", .null)])[0]
        #expect(field.isNull)
        #expect(field.display == "")
        #expect(!field.isJSON)
    }

    @Test func aNestedDocumentIsPrettyPrinted() {
        let field = fields([("payload", .object(["nights": .integer(3), "addons": .array([.string("parking")])]))])[0]
        #expect(field.isJSON)
        #expect(field.display == "{\n  \"addons\" : [\n    \"parking\"\n  ],\n  \"nights\" : 3\n}")
    }

    @Test func aTextValueHoldingAnObjectOrArrayIsPrettyPrinted() {
        let field = fields([("payload", .string("  {\"b\":1,\"a\":[2]} "))])[0]
        #expect(field.isJSON)
        #expect(field.display == "{\n  \"a\" : [\n    2\n  ],\n  \"b\" : 1\n}")
    }

    @Test func textThatOnlyLooksLikeJSONStaysText() {
        for raw in ["42", "true", "\"quoted\"", "[oops", "{not json}", "null"] {
            let field = fields([("v", .string(raw))])[0]
            #expect(!field.isJSON, "\(raw) should stay text")
            #expect(field.display == raw)
        }
    }

    @Test func unicodeIsKeptAsIs() {
        #expect(fields([("note", .string("قهوة ☕ — late"))])[0].display == "قهوة ☕ — late")
    }

    @Test func aRowShorterThanItsColumnsGivesEmptyFields() {
        let result = rowDetailFields(
            columns: [PaneColumn(name: "a", type: ""), PaneColumn(name: "b", type: "")],
            row: PaneRow(id: 0, cells: [PaneCell(.integer(1))]))
        #expect(result.map(\.display) == ["1", ""])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter RowDetailTests`
Expected: build FAILS — `RowDetailField`, `rowDetailFields` not defined.

- [ ] **Step 3: Write `RowDetail.swift`**

`app/Sources/WakilKit/Panes/RowDetail.swift`:

```swift
import Foundation

/// One column of the row detail strip: its name and its whole value. Read-only — editing
/// stays in the grid's double-click path, so a surface keeps one cell editor and one
/// confirmation plane (2c-ii-b check 22).
public struct RowDetailField: Sendable, Equatable, Identifiable {
    public let name: String
    /// The whole value: pretty-printed when `isJSON`, else the cell's text. Never truncated.
    public let display: String
    public let isNull: Bool
    public let isJSON: Bool
    public var id: String { name }
}

/// The strip's fields for `row`, in result order. A JSON object or array — a nested Mongo
/// document, or a text value that parses as one after trimming whitespace — is pretty-printed
/// with sorted keys. Only objects and arrays count: `"42"`, `"true"` and `"null"` are text a
/// person typed, and reformatting them would show something the cell does not hold.
public func rowDetailFields(columns: [PaneColumn], row: PaneRow) -> [RowDetailField] {
    columns.enumerated().map { index, column in
        guard index < row.cells.count else {
            return RowDetailField(name: column.name, display: "", isNull: false, isJSON: false)
        }
        let cell = row.cells[index]
        if cell.isNull {
            return RowDetailField(name: column.name, display: "", isNull: true, isJSON: false)
        }
        if let pretty = rowDetailPrettyJSON(cell.value) {
            return RowDetailField(name: column.name, display: pretty, isNull: false, isJSON: true)
        }
        return RowDetailField(name: column.name, display: cell.text, isNull: false, isJSON: false)
    }
}

private func rowDetailPrettyJSON(_ value: JSONValue) -> String? {
    let structured: JSONValue
    switch value {
    case .object, .array:
        structured = value
    case .string(let text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
        else { return nil }
        switch parsed {
        case .object, .array: structured = parsed
        default: return nil
        }
    default:
        return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(structured) else { return nil }
    return String(data: data, encoding: .utf8)
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && ../scripts/swift-test.sh --filter RowDetailTests`
Expected: PASS. If the two pretty-print expectations differ only in spacing (`"a" : 1` vs `"a": 1`), Foundation's `JSONEncoder` on this toolchain writes `" : "`; adjust the **expected strings**, not the encoder, and note it in the commit.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Panes/RowDetail.swift app/Tests/WakilKitTests/RowDetailTests.swift
git commit -m "WakilKit: the row detail strip's fields — whole values, JSON pretty-printed, look-alikes left as text"
```

---

### Task 4: WakilKit — the DB flight on PaneStore

**Files:**
- Modify: `app/Sources/WakilKit/Panes/DataSurfacePaneKind.swift` (contents struct, `snapshot()`, `readPane`)
- Modify: `app/Sources/WakilKit/Panes/PaneSnapshot.swift:80-125` (`DataSurfaceSnapshot`)
- Modify: `app/Sources/WakilKit/Panes/PaneTable.swift` (`PaneTable` fields, `empty`, `init`, `init(dataSurface:)`)
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (beside `setRows`, ~line 271)
- Test: `app/Tests/WakilKitTests/DBFlightTests.swift`

**Interfaces:**
- Consumes: `PaneStore.publishFlight(_ paneId: String)` (`PaneStore+Api.swift`, internal), `scope(holding:paneId:where:)` and `inScope(_:_:)` (`PaneStore.swift:121-153`).
- Produces (all on `PaneStore`):
  - `public func beginDBRead(paneId: String, at since: Date) -> UUID?` — `nil` when one is in flight
  - `public func armDBRead(paneId: String, token: UUID, cancel: @escaping @Sendable () -> Void)`
  - `public func cancelDBRead(paneId: String, at now: Date = Date()) -> Bool`
  - `public func finishDBRead(paneId: String, token: UUID) -> Bool` — `true` only when `token` is still the pane's flight; the caller writes rows only then
  - `public func cancelAllDBReads(at now: Date = Date())`
  - `DataSurfaceSnapshot.runningSince: Date?`, `.cancelledAfterMs: Int?`; same two on `PaneTable`
  - `read_pane` keys `running` (Bool) and `cancelledAfterMs` (number or null)

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/DBFlightTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func storeWithRows() async -> PaneStore {
    let panes = PaneStore()
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 4, truncated: false, pageable: true, offset: 0,
        sort: [], listsTables: false, editable: nil)
    return panes
}

struct DBFlightTests {
    @Test func aSecondReadOnARunningPaneIsRefused() async {
        let panes = await storeWithRows()
        let first = await panes.beginDBRead(paneId: "db-1", at: Date())
        #expect(first != nil)
        #expect(await panes.beginDBRead(paneId: "db-1", at: Date()) == nil)
    }

    @Test func runningShowsInTheSnapshotAndReadPane() async {
        let panes = await storeWithRows()
        let since = Date(timeIntervalSince1970: 1000)
        _ = await panes.beginDBRead(paneId: "db-1", at: since)
        let snap = await panes.dataSurfaceSnapshot(paneId: "db-1")
        #expect(snap.runningSince == since)
        guard case .object(let read) = await panes.readPane(paneId: "db-1", kind: "db") else {
            Issue.record("read_pane is not an object"); return
        }
        #expect(read["running"] == .bool(true))
    }

    @Test func cancelEndsTheFlightAtOnceAndKeepsTheRows() async {
        let panes = await storeWithRows()
        let since = Date(timeIntervalSince1970: 1000)
        _ = await panes.beginDBRead(paneId: "db-1", at: since)
        #expect(await panes.cancelDBRead(paneId: "db-1", at: since.addingTimeInterval(3.2)))
        let snap = await panes.dataSurfaceSnapshot(paneId: "db-1")
        #expect(snap.runningSince == nil)
        #expect(snap.cancelledAfterMs == 3200)
        #expect(snap.rows == [[.integer(1)]])
        // The pane is free again straight away — an environment switch relies on it.
        #expect(await panes.beginDBRead(paneId: "db-1", at: Date()) != nil)
    }

    @Test func cancelRunsTheArmedCanceller() async {
        let panes = await storeWithRows()
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        let fired = Fired()
        await panes.armDBRead(paneId: "db-1", token: token) { Task { await fired.set() } }
        _ = await panes.cancelDBRead(paneId: "db-1")
        #expect(await dbEventually { await fired.value })
    }

    @Test func aCancelBeforeTheCancellerIsArmedIsHonouredWhenItArrives() async {
        let panes = await storeWithRows()
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        _ = await panes.cancelDBRead(paneId: "db-1")
        let fired = Fired()
        await panes.armDBRead(paneId: "db-1", token: token) { Task { await fired.set() } }
        #expect(await dbEventually { await fired.value })
    }

    @Test func aLateReplyAfterCancelIsDropped() async {
        let panes = await storeWithRows()
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        _ = await panes.cancelDBRead(paneId: "db-1")
        #expect(await panes.finishDBRead(paneId: "db-1", token: token) == false)
    }

    @Test func finishingTheCurrentFlightClearsItAndTheCancelledLine() async {
        let panes = await storeWithRows()
        let old = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        _ = await panes.cancelDBRead(paneId: "db-1")
        _ = old
        let token = try! #require(await panes.beginDBRead(paneId: "db-1", at: Date()))
        #expect(await panes.finishDBRead(paneId: "db-1", token: token))
        let snap = await panes.dataSurfaceSnapshot(paneId: "db-1")
        #expect(snap.runningSince == nil)
        #expect(snap.cancelledAfterMs == nil)
    }

    @Test func cancelWithNothingInFlightReportsFalse() async {
        let panes = await storeWithRows()
        #expect(await panes.cancelDBRead(paneId: "db-1") == false)
    }

    @Test func cancelAllEndsEveryFlight() async {
        let panes = await storeWithRows()
        _ = await panes.beginDBRead(paneId: "db-1", at: Date())
        await panes.cancelAllDBReads()
        #expect(await panes.dataSurfaceSnapshot(paneId: "db-1").runningSince == nil)
    }
}

private actor Fired {
    var value = false
    func set() { value = true }
}

func dbEventually(_ seconds: Double = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}
```

`dataSurfaceSnapshot(paneId:)` may not exist under that name. Before running, find how existing tests read a db pane's `DataSurfaceSnapshot` from a `PaneStore` (`grep -rn "DataSurfaceSnapshot" app/Tests/WakilKitTests | head`) and use that accessor in every test above. `testWaitLoadMultiplier` is the repo's existing constant (`grep -rn "testWaitLoadMultiplier" app/Tests | head -2`).

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter DBFlightTests`
Expected: build FAILS — `beginDBRead` etc. not defined.

- [ ] **Step 3: Add the flight to the pane's contents**

In `DataSurfacePaneKind.swift`, above `struct DataSurfaceContents`:

```swift
/// A read in flight on a db pane — the shape of `ApiFlight`. One per pane: a second read is
/// refused (Interaction Rule 5). Writes are never flights; a cancelled write may still land.
struct DBFlight {
    let token: UUID
    let since: Date
    /// Cancels the read's task. `nil` until `armDBRead`. Unlike `ApiFlight` there is no
    /// `cancelRequested`: a cancel clears the flight, so an arm that finds none cancels itself.
    var cancel: (@Sendable () -> Void)?
}
```

Add to `DataSurfaceContents`, after `sourceEditable`:

```swift
    var flight: DBFlight?
    /// How long the last read ran before it was cancelled. Cleared when a read lands.
    var cancelledAfterMs: Int?
```

In `snapshot()`, pass the two new snapshot fields: `runningSince: flight?.since, cancelledAfterMs: cancelledAfterMs` (after `editable:`).

In `readPane`, before `return object`:

```swift
        object["running"] = .bool(snapshot.runningSince != nil)
        object["cancelledAfterMs"] = snapshot.cancelledAfterMs.map { .number(Double($0)) } ?? .null
```

- [ ] **Step 4: Add the fields to `DataSurfaceSnapshot` and `PaneTable`**

In `PaneSnapshot.swift`'s `DataSurfaceSnapshot`: add `public let runningSince: Date?` and `public let cancelledAfterMs: Int?`; add `runningSince: Date? = nil, cancelledAfterMs: Int? = nil` as the **last two** init parameters (defaults keep every existing caller compiling) and assign them. `empty` needs no change.

In `PaneTable.swift`: add the same two `public let` properties with doc comments (`/// When the read in flight started, or nil.` / `/// How long the last read ran before it was cancelled, or nil.`), the same two defaulted trailing init parameters, and in `init(dataSurface:)` pass `runningSince: grid.runningSince, cancelledAfterMs: grid.cancelledAfterMs`.

- [ ] **Step 5: Add the store methods**

In `PaneStore.swift`, after `setRows` (they need the file-private `setDataSurface`):

```swift
    // MARK: - A db read in flight

    func dbFlightScope(paneId: String, token: UUID) -> LayoutScope? {
        scope(holding: DataSurfacePaneKind.self, paneId: paneId) { $0.flight?.token == token }
    }

    /// Opens a flight on `paneId`, or refuses with `nil` when one is already in flight.
    public func beginDBRead(paneId: String, at since: Date) -> UUID? {
        var contents = dataSurface(paneId)
        guard contents.flight == nil else { return nil }
        let token = UUID()
        contents.flight = DBFlight(token: token, since: since)
        setDataSurface(paneId, contents)
        publishFlight(paneId)
        return token
    }

    /// Hands the flight its canceller. A cancel that arrived first runs it now.
    public func armDBRead(paneId: String, token: UUID, cancel: @escaping @Sendable () -> Void) {
        guard let home = dbFlightScope(paneId: paneId, token: token) else {
            cancel()   // cancelled and cleared before the canceller arrived
            return
        }
        inScope(home) {
            var contents = dataSurface(paneId)
            guard var flight = contents.flight else { return }
            flight.cancel = cancel
            contents.flight = flight
            setDataSurface(paneId, contents)
        }
    }

    /// Ends the flight at once: clears it, records how long it ran, keeps the rows, and runs
    /// the canceller. A reply that still arrives is dropped by `finishDBRead`. `false` when
    /// nothing is in flight.
    public func cancelDBRead(paneId: String, at now: Date = Date()) -> Bool {
        var contents = dataSurface(paneId)
        guard let flight = contents.flight else { return false }
        contents.flight = nil
        contents.cancelledAfterMs = max(0, Int(now.timeIntervalSince(flight.since) * 1000))
        setDataSurface(paneId, contents)
        publishFlight(paneId)
        flight.cancel?()
        return true
    }

    /// Ends flight `token`. `true` only when it is still the pane's flight — the caller writes
    /// the reply's rows only then. A landed read clears the last `cancelled after` line.
    public func finishDBRead(paneId: String, token: UUID) -> Bool {
        guard let home = dbFlightScope(paneId: paneId, token: token) else { return false }
        inScope(home) {
            var contents = dataSurface(paneId)
            contents.flight = nil
            contents.cancelledAfterMs = nil
            setDataSurface(paneId, contents)
        }
        publishFlight(paneId)
        return true
    }

    /// Cancels every db read in flight in every scope. Called before anything re-runs every
    /// pane's subject (`restorePaneContents`) and before an org switch drops the panes.
    public func cancelAllDBReads(at now: Date = Date()) {
        for entry in everyScope(DataSurfacePaneKind.self) where entry.contents.flight != nil {
            inScope(entry.scope) { _ = cancelDBRead(paneId: entry.paneId, at: now) }
        }
    }
```

Note the `armDBRead` difference from `armApiSend`: because `cancelDBRead` clears the flight immediately (the API's cancel only marks it), an arm that finds no flight means the cancel already happened, so it runs the canceller itself. That is what `aCancelBeforeTheCancellerIsArmedIsHonouredWhenItArrives` pins.

**Caveat:** `armDBRead` with no matching flight cannot tell "cancelled" from "never begun". Callers only arm a token `beginDBRead` returned, so "never begun" does not happen.

- [ ] **Step 6: Run the tests and the existing pane tests**

Run: `cd app && ../scripts/swift-test.sh --filter 'DBFlightTests|PaneStoreTests|PaneKindStorageTests|PaneContentsTests'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Panes/DataSurfacePaneKind.swift app/Sources/WakilKit/Panes/PaneSnapshot.swift app/Sources/WakilKit/Panes/PaneTable.swift app/Sources/WakilKit/Panes/PaneStore.swift app/Tests/WakilKitTests/DBFlightTests.swift
git commit -m "WakilKit: a db pane's read in flight — one per pane, cancel ends it at once and keeps the rows"
```

---

### Task 5: WakilKit — reads run as flights; `db_cancel`

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — `StandardActionError` (`:6-96`), `db_run_query` (`:1147`), `db_list_tables` (`:1230`), `db_describe_table` (`:1279`), `db_read_table` (`:1331`), `refetchPane` (`:2125`), a new `db_cancel` registration after `db_refetch` (`:1397`), a new `dbReadInFlight` beside `callCheckedTool` (`:2571`)
- Test: `app/Tests/WakilKitTests/DBCancelTests.swift`

**Interfaces:**
- Consumes: Task 4's `beginDBRead`/`armDBRead`/`finishDBRead`/`cancelDBRead`.
- Produces:
  - `StandardActionError.readInFlight(action: String, pane: String)` and `.nothingInFlight(action: String, pane: String)`
  - `func dbReadInFlight(paneId: String?, action: String, panes: PaneStore, read: @escaping @Sendable () async throws -> JSONValue) async throws -> DBReadOutcome`
  - `enum DBReadOutcome { case landed(JSONValue), cancelled }`
  - action `db_cancel(pane)` — `.control`, `.agentReachable`, returns `{"pane": id}`; a cancelled read action returns `{"pane": id, "cancelled": true}`

- [ ] **Step 1: Write the failing tests**

`app/Tests/WakilKitTests/DBCancelTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// Answers every db tool at once, except `query`/`read_table` when `stall` is on: those sleep
/// 30 s and throw `CancellationError` when cancelled, as a real call does.
/// Internal, not private: `WindowModelTests.restoreCancelsReadsInFlightFirst` uses it too.
actor StallingDB: ToolCaller {
    var stall = true
    private(set) var calls = 0
    func setStall(_ on: Bool) { stall = on }
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls += 1
        if stall, name == "query" || name == "read_table" {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return .object(["structuredContent": .object([
            "columns": .array([.string("id")]),
            "rows": .array([.array([.integer(2)])]),
            "millis": .number(1),
        ])])
    }
}

private func fixture(_ db: StallingDB) async throws -> (ActionRegistry, PaneStore, String) {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir.appendingPathComponent("journal"), sessionId: "s1")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(), layout: layout)
    let pane = await layout.open(kind: "db", title: "db").id
    await panes.setRows(
        paneId: pane, columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 4, truncated: false, pageable: true, offset: 0,
        sort: [], listsTables: false, editable: nil)
    await layout.setFetch(PaneFetch(query: .sql(database: nil, raw: "SELECT 1")), id: pane)
    return (registry, panes, pane)
}

private func run(_ registry: ActionRegistry, _ name: String, _ params: [String: JSONValue]) async throws -> JSONValue {
    try await registry.dispatch(
        name: name, params: .object(params), origin: .agent, environment: "staging", confirmation: nil)
}

struct DBCancelTests {
    @Test(.timeLimit(.minutes(1))) func aCancelledQueryKeepsTheRowsAndSaysSo() async throws {
        let (registry, panes, pane) = try await fixture(StallingDB())
        let read = Task { try await run(registry, "db_run_query", ["pane": .string(pane), "query": .string("SELECT 2")]) }
        #expect(await dbEventually { await panes.dataSurfaceSnapshot(paneId: pane).runningSince != nil })
        _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        let result = try await read.value
        guard case .object(let fields) = result else { Issue.record("not an object"); return }
        #expect(fields["cancelled"] == .bool(true))
        let snap = await panes.dataSurfaceSnapshot(paneId: pane)
        #expect(snap.rows == [[.integer(1)]])
        #expect(snap.cancelledAfterMs != nil)
        #expect(snap.runningSince == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondReadWhileOneRunsIsRefused() async throws {
        let (registry, panes, pane) = try await fixture(StallingDB())
        let read = Task { try await run(registry, "db_refetch", ["pane": .string(pane)]) }
        #expect(await dbEventually { await panes.dataSurfaceSnapshot(paneId: pane).runningSince != nil })
        await #expect(throws: StandardActionError.readInFlight(action: "db_page", pane: pane)) {
            _ = try await run(registry, "db_page", ["pane": .string(pane), "to": .string("next")])
        }
        _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        _ = try await read.value
    }

    @Test func cancelWithNothingInFlightIsRefused() async throws {
        let (registry, _, pane) = try await fixture(StallingDB())
        await #expect(throws: StandardActionError.nothingInFlight(action: "db_cancel", pane: pane)) {
            _ = try await run(registry, "db_cancel", ["pane": .string(pane)])
        }
    }

    @Test func aReadThatLandsWritesItsRowsAndEndsTheFlight() async throws {
        let db = StallingDB()
        await db.setStall(false)
        let (registry, panes, pane) = try await fixture(db)
        _ = try await run(registry, "db_refetch", ["pane": .string(pane)])
        let snap = await panes.dataSurfaceSnapshot(paneId: pane)
        #expect(snap.rows == [[.integer(2)]])
        #expect(snap.runningSince == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aQueryNamingNoPaneIsNotAFlight() async throws {
        let db = StallingDB()
        await db.setStall(false)
        let (registry, _, _) = try await fixture(db)
        // Opens its own pane when it lands; nothing to show `running` on before then (spec, "What it does not do").
        _ = try await run(registry, "db_run_query", ["query": .string("SELECT 2")])
    }

    @Test func dbCancelIsAgentReachableControl() async throws {
        let (registry, _, _) = try await fixture(StallingDB())
        let action = try #require(await registry.action(named: "db_cancel"))
        #expect(action.kind == .control)
        #expect(action.audience == .agentReachable)
    }
}
```

Two names to check against the code before running and fix in the test if they differ: the snapshot accessor (same as Task 4), and `registry.action(named:)` (`grep -n "func action\|func lookup" app/Sources/WakilKit/Registry/ActionRegistry.swift`).

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter DBCancelTests`
Expected: build FAILS — `readInFlight`, `nothingInFlight`, `db_cancel` not defined.

- [ ] **Step 3: Add the two error cases**

In `StandardActionError`, after `paneNotPageable`:

```swift
    /// A read is already running on this pane (Interaction Rule 5).
    case readInFlight(action: String, pane: String)
    /// `db_cancel` on a pane with no read running. Refused rather than a silent success, which
    /// would tell the agent it stopped something.
    case nothingInFlight(action: String, pane: String)
```

and in `description`:

```swift
        case .readInFlight(let action, let pane):
            return "\(action): a read is already running on pane \(pane) — wait for it, or cancel it with db_cancel"
        case .nothingInFlight(let action, let pane):
            return "\(action): nothing is running on pane \(pane) — there is no read to cancel"
```

- [ ] **Step 4: Add `dbReadInFlight`**

Beside `callCheckedTool` (`:2571`):

```swift
enum DBReadOutcome {
    case landed(JSONValue)
    case cancelled
}

/// Runs a db read as `paneId`'s flight — the shape of `apiSendInFlight`. With no pane (a
/// query that opens its own pane when it lands) it is a plain call: there is nothing to show
/// `running` on yet. `.cancelled` when `db_cancel` ended the flight, whether the call then
/// threw `CancellationError` or its reply arrived anyway — that reply is dropped.
func dbReadInFlight(
    paneId: String?, action: String, panes: PaneStore,
    read: @escaping @Sendable () async throws -> JSONValue
) async throws -> DBReadOutcome {
    guard let paneId else { return .landed(try await read()) }
    guard let token = await panes.beginDBRead(paneId: paneId, at: Date()) else {
        throw StandardActionError.readInFlight(action: action, pane: paneId)
    }
    let task = Task { try await read() }
    await panes.armDBRead(paneId: paneId, token: token) { task.cancel() }
    let result: Result<JSONValue, Error> = await withTaskCancellationHandler {
        do { return .success(try await task.value) } catch { return .failure(error) }
    } onCancel: {
        task.cancel()
    }
    guard await panes.finishDBRead(paneId: paneId, token: token) else { return .cancelled }
    return .landed(try result.get())
}

/// What a read action returns when its flight was cancelled.
func dbCancelledResult(paneId: String) -> JSONValue {
    .object(["pane": .string(paneId), "cancelled": .bool(true)])
}
```

- [ ] **Step 5: Wrap every pane-bound read**

`refetchPane` — in each of its four arms, replace

```swift
        let result = try await callChecked(
            db, tool: "<tool>", arguments: .object(arguments),
            action: action, timeout: MCPClient.readReplyTimeout)
```

with

```swift
        let outcome = try await dbReadInFlight(paneId: paneId, action: action, panes: panes) {
            try await callChecked(
                db, tool: "<tool>", arguments: .object(arguments),
                action: action, timeout: MCPClient.readReplyTimeout)
        }
        guard case .landed(let result) = outcome else { return dbCancelledResult(paneId: paneId) }
```

keeping each arm's own `<tool>` (`query`, `read_table`, `list_tables`, `describe_table`). `arguments` is a `var`; capture a `let` copy first (`let sent = arguments` above the call, and pass `.object(sent)`) so the `@Sendable` closure does not capture a mutable variable.

`refetchPane` takes `action` as the literal `"db_refetch"` today, but `db_page` and `pane_sort` also call it. Add a parameter `action: String = "db_refetch"` to `refetchPane`, use it in place of the local `let action`, and pass `action: "db_page"` from `db_page` and `action: "pane_sort"` from `pane_sort`, so the refusal names the action the caller dispatched (the test expects `db_page`).

`db_run_query`, `db_list_tables`, `db_describe_table`, `db_read_table` — the same replacement around each handler's `callChecked`, with `paneId: explicitPaneParam` (or `explicit` in the three schema handlers): `nil` when no pane was named, so those stay plain calls. On `.cancelled` return `dbCancelledResult(paneId: <the explicit pane>!)` — safe, because `.cancelled` only happens with a pane.

Do **not** touch `db_run_mutation`.

- [ ] **Step 6: Register `db_cancel`**

After the `db_refetch` registration:

```swift
    await registry.register(Action(
        name: "db_cancel",
        description: "Cancel the read running on a db pane, as the operator's Cancel does. "
            + "The query is stopped on the database too. The rows that were on screen stay, and "
            + "read_pane's cancelledAfterMs says how long it ran. While a read runs, read_pane's "
            + "running is true and a second read on that pane is refused. With nothing running "
            + "it is refused. Writes (db_run_mutation) are never cancellable.",
        // `.control`: it ends a read Wakil started; it changes nothing outside Wakil and is
        // never priced by the gate.
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let action = "db_cancel"
            let paneId = try requireStringParam(params, "pane", action: action)
            try await requireOpenPane(paneId, action: action, layout: layout)
            guard await panes.cancelDBRead(paneId: paneId) else {
                throw StandardActionError.nothingInFlight(action: action, pane: paneId)
            }
            return .object(["pane": .string(paneId)])
        }
    ))
```

- [ ] **Step 7: Run the new tests and every suite that touches db actions**

Run: `cd app && ../scripts/swift-test.sh --filter 'DBCancelTests|DBActionTests|StandardActionsTests|MutationActionTests|ActionClassificationTests|ActionRegistryTests|MCPServerTests'`
Expected: PASS. If `ActionClassificationTests` or `MCPServerTests` enumerate actions and fail on the new `db_cancel`, add it to the list they keep, in the same style as `api_cancel`.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/DBCancelTests.swift
git commit -m "WakilKit: db reads into a pane run as flights; db_cancel stops one and keeps the rows"
```

(Add any test list files Step 7 touched.)

---

### Task 6: WakilKit — switches cancel reads; the grid's key rule and footer line

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — `restorePaneContents()` (`:3099`); the org switch (`:2019-2020`, before `await panes.clearAllScopes()`)
- Create: `app/Sources/WakilKit/Panes/DataSurfaceKeys.swift`
- Test: `app/Tests/WakilKitTests/DataSurfaceKeysTests.swift`; `app/Tests/WakilKitTests/WindowModelTests.swift` (beside `relaunchOnlyRefetchesDbPanes`)

**Interfaces:**
- Consumes: `cancelAllDBReads` (Task 4).
- Produces:
  ```swift
  public enum DataSurfaceKey: Equatable, Sendable { case copy, toggleDetail, closeDetail, move(Int) }
  public func dataSurfaceKeyClaim(key: String, command: Bool, editing: Bool, detailOpen: Bool) -> DataSurfaceKey?
  public func dbFlightLine(runningSince: Date?, cancelledAfterMs: Int?, now: Date) -> String?
  public func dbSeconds(_ milliseconds: Int) -> String
  ```
  `key` is one of `"c"`, `" "`, `"up"`, `"down"`, `"escape"` — the view maps `KeyPress` to these.

- [ ] **Step 1: Write the failing key and footer tests**

`app/Tests/WakilKitTests/DataSurfaceKeysTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

struct DataSurfaceKeysTests {
    @Test func commandCCopies() {
        #expect(dataSurfaceKeyClaim(key: "c", command: true, editing: false, detailOpen: false) == .copy)
        #expect(dataSurfaceKeyClaim(key: "c", command: false, editing: false, detailOpen: false) == nil)
    }

    @Test func spaceTogglesTheStrip() {
        #expect(dataSurfaceKeyClaim(key: " ", command: false, editing: false, detailOpen: false) == .toggleDetail)
        #expect(dataSurfaceKeyClaim(key: " ", command: false, editing: false, detailOpen: true) == .toggleDetail)
    }

    @Test func arrowsMoveTheAnchorRow() {
        #expect(dataSurfaceKeyClaim(key: "up", command: false, editing: false, detailOpen: true) == .move(-1))
        #expect(dataSurfaceKeyClaim(key: "down", command: false, editing: false, detailOpen: false) == .move(1))
    }

    @Test func escapeClosesTheStripOnlyWhenOpen() {
        #expect(dataSurfaceKeyClaim(key: "escape", command: false, editing: false, detailOpen: true) == .closeDetail)
        #expect(dataSurfaceKeyClaim(key: "escape", command: false, editing: false, detailOpen: false) == nil)
    }

    @Test func aCellBeingEditedOwnsEveryKey() {
        for key in ["c", " ", "up", "down", "escape"] {
            #expect(dataSurfaceKeyClaim(key: key, command: key == "c", editing: true, detailOpen: true) == nil)
        }
    }

    @Test func theFooterCountsWhileRunningAndThenSaysCancelled() {
        let since = Date(timeIntervalSince1970: 1000)
        #expect(dbFlightLine(runningSince: since, cancelledAfterMs: nil, now: since.addingTimeInterval(3.24)) == "running · 3.2 s")
        #expect(dbFlightLine(runningSince: nil, cancelledAfterMs: 4000, now: since) == "cancelled after 4.0 s")
        #expect(dbFlightLine(runningSince: nil, cancelledAfterMs: nil, now: since) == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter DataSurfaceKeysTests`
Expected: build FAILS.

- [ ] **Step 3: Write `DataSurfaceKeys.swift`**

```swift
import Foundation

/// What a key does on a focused db grid. Bound by `.onKeyPress` on the surface, never by
/// `.keyboardShortcut` (`DBPane`'s rule: a per-pane shortcut fires the first pane's control).
public enum DataSurfaceKey: Equatable, Sendable {
    /// ⌘C: the anchor cell, or the selected rows as TSV (`GridCopy`).
    case copy
    /// Space: open or close the row detail strip.
    case toggleDetail
    /// Esc with the strip open.
    case closeDetail
    /// ↑ / ↓: move the anchor row through `pane_select_cell` — no new action.
    case move(Int)
}

/// The key rule, kept here so it is tested. A cell being edited owns every key. Esc with the
/// strip closed is not claimed, so it falls through to whatever owns it outside the grid.
public func dataSurfaceKeyClaim(key: String, command: Bool, editing: Bool, detailOpen: Bool) -> DataSurfaceKey? {
    guard !editing else { return nil }
    switch key {
    case "c": return command ? .copy : nil
    case " ": return command ? nil : .toggleDetail
    case "up": return command ? nil : .move(-1)
    case "down": return command ? nil : .move(1)
    case "escape": return detailOpen ? .closeDetail : nil
    default: return nil
    }
}

/// Seconds to one decimal, as the api pane writes them (`apiSeconds`). Kept separate so
/// `Panes/` does not reach into `Api/`.
public func dbSeconds(_ milliseconds: Int) -> String {
    String(format: "%.1f s", Double(milliseconds) / 1000)
}

/// The footer's flight line: `running · 3.2 s` while a read runs, `cancelled after 3.2 s`
/// after a cancel, nothing otherwise.
public func dbFlightLine(runningSince: Date?, cancelledAfterMs: Int?, now: Date) -> String? {
    if let runningSince {
        return "running · " + dbSeconds(max(0, Int(now.timeIntervalSince(runningSince) * 1000)))
    }
    if let cancelledAfterMs { return "cancelled after " + dbSeconds(cancelledAfterMs) }
    return nil
}
```

- [ ] **Step 4: Run them**

Run: `cd app && ../scripts/swift-test.sh --filter DataSurfaceKeysTests`
Expected: PASS.

- [ ] **Step 5: Write the failing restore test**

Append to `app/Tests/WakilKitTests/WindowModelTests.swift`, beside `relaunchOnlyRefetchesDbPanes` (it uses that test's `makeRegistry()` and model construction; `StallingDB` is Task 5's, `dbEventually` Task 4's):

```swift
/// Review Focus 2: a restore re-runs every pane's subject. A read still in flight on a pane
/// must be cancelled first, or the restore's own `db_refetch` is refused (Interaction Rule 5)
/// and the pane keeps showing the environment just left.
@Test @MainActor func restoreCancelsReadsInFlightFirst() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let db = StallingDB()
    await registerStandardActions(
        into: registry, context: nil, panes: panes, db: db, resumes: ResumeBroker(),
        layout: layout)
    await layout.load(LayoutSnapshot(
        panes: [Pane(id: "db-1", kind: "db", title: "main",
                     frame: PaneFrame(x: 0, y: 0, width: 640, height: 420),
                     fetch: PaneFetch(query: .sql(database: nil, raw: "SELECT 1")))],
        focusedId: "db-1"), for: .initial)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())
    await model.refreshLayout()

    let first = Task {
        try await registry.dispatch(
            name: "db_refetch", params: .object(["pane": .string("db-1")]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    #expect(await dbEventually { await panes.dataSurfaceSnapshot(paneId: "db-1").runningSince != nil })
    await db.setStall(false)

    await model.restorePaneContents()

    #expect(!"\(model.status)".contains("already running"))
    #expect(await panes.dataSurfaceSnapshot(paneId: "db-1").rows == [[.integer(2)]])
    _ = try? await first.value
}
```

Run: `cd app && ../scripts/swift-test.sh --filter restoreCancelsReadsInFlightFirst`
Expected: FAIL — the restore's `db_refetch` is refused with "a read is already running", so `status` names it and the rows are not `[[2]]`.

- [ ] **Step 6: Cancel before restore and before the org switch drops panes**

In `WindowModel.restorePaneContents()`, as its first line:

```swift
        // A restore re-runs every pane's subject; a read still in flight would refuse it
        // (Interaction Rule 5) and the pane would keep the environment just left. Cancelled first.
        await panes.cancelAllDBReads()
```

In the org switch, immediately before `await panes.clearAllScopes()`:

```swift
        await panes.cancelAllDBReads()   // stop the old org's reads on its database, not just forget them
```

- [ ] **Step 7: Run the restore test and the window suites**

Run: `cd app && ../scripts/swift-test.sh --filter 'restoreCancelsReadsInFlightFirst|WindowModelTests|OrgSwitchTests|PaneKindRestoreTests|InvalidationContractTests'`
Expected: PASS. No stored property was added to `WindowModel`, so `InvalidationContractTests` should not need a change.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/Panes/DataSurfaceKeys.swift app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/DataSurfaceKeysTests.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "WakilKit: an environment or org switch cancels db reads first; the grid's key rule and footer line"
```

---

### Task 7: WakilApp — keys, Copy, context menu, footer Cancel

**Files:**
- Modify: `app/Sources/WakilApp/DataSurface.swift` — body (`:195-295`), `rowCells` (`:636-680`), `cellView` (`:737`), `select(row:column:)` (`:1045`), `footer()` (`:1087-1154`)
- Modify: `app/Sources/WakilApp/QueryLineEditor.swift` — properties (`:15-31`), `doCommandBy` (`:181-205`)
- Modify: `app/Sources/WakilApp/DBPane.swift` — the `QueryLineEditor(` call (`:213-219`)

**Interfaces:**
- Consumes: `gridCopyCell`, `gridCopyText`, `gridCopyJSON`, `gridCopyRows` (Task 2); `dataSurfaceKeyClaim`, `dbFlightLine` (Task 6); `PaneTable.runningSince`, `.cancelledAfterMs` (Task 4); action `db_cancel` (Task 5).
- Produces: `@State var showsDetail: Bool` on `DataSurface`, read by Task 8.

`WakilApp` has no test target. This task's checks are a build plus the e2e auditor at the Cover rung.

- [ ] **Step 1: Copy helpers on `DataSurface`**

Add to `DataSurface` (near `select`):

```swift
    @State var showsDetail = false

    private func writePasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// ⌘C: one row selected copies its anchor cell; several copy as TSV with a header.
    private func copySelection() {
        let indexes = gridCopyRows(selection: table.selection, clickedRow: nil, rowCount: table.rows.count)
        guard !indexes.isEmpty else { return }
        if indexes.count == 1,
           let column = table.selection.anchorColumn,
           let columnIndex = table.columns.firstIndex(where: { $0.name == column }),
           columnIndex < table.rows[indexes[0]].cells.count {
            writePasteboard(gridCopyCell(table.rows[indexes[0]].cells[columnIndex]))
        } else {
            writePasteboard(gridCopyText(columns: table.columns, rows: indexes.map { table.rows[$0] }))
        }
    }

    private func moveAnchor(by delta: Int) {
        guard !table.rows.isEmpty else { return }
        let current = table.selection.anchorRow ?? (delta > 0 ? -1 : table.rows.count)
        let next = min(max(current + delta, 0), table.rows.count - 1)
        let column = table.selection.anchorColumn ?? table.columns.first?.name ?? ""
        dispatch("pane_select_cell", .object([
            "pane": .string(pane.id), "row": .number(Double(next)), "column": .string(column),
        ]))
    }
```

- [ ] **Step 2: Bind the keys on the focused surface**

In `body`, after `.focusEffectDisabled()` (`:244`):

```swift
            .onKeyPress(phases: .down) { press in
                let key: String
                switch press.key {
                case .upArrow: key = "up"
                case .downArrow: key = "down"
                case .escape: key = "escape"
                case .space: key = " "
                default: key = press.characters.lowercased()
                }
                guard let claim = dataSurfaceKeyClaim(
                    key: key, command: press.modifiers.contains(.command),
                    editing: editingCell != nil, detailOpen: showsDetail)
                else { return .ignored }
                switch claim {
                case .copy: copySelection()
                case .toggleDetail: showsDetail.toggle()
                case .closeDetail: showsDetail = false
                case .move(let delta): moveAnchor(by: delta)
                }
                return .handled
            }
```

The surface must hold focus for keys to arrive. In `select(row:column:)`, as its first line, add `surfaceFocused = true`, so a click on a row gives the grid the keyboard.

- [ ] **Step 3: The context menu on a cell**

In `cellView` (`:737`), on the resting cell's outermost view (the one carrying the single-tap `select`), add:

```swift
            .contextMenu {
                let indexes = gridCopyRows(selection: table.selection, clickedRow: row.id, rowCount: table.rows.count)
                Button("Copy cell") {
                    if index < row.cells.count { writePasteboard(gridCopyCell(row.cells[index])) }
                }
                Button(indexes.count > 1 ? "Copy \(indexes.count) rows" : "Copy row") {
                    writePasteboard(gridCopyText(columns: table.columns, rows: indexes.map { table.rows[$0] }))
                }
                Button("Copy as JSON") {
                    writePasteboard(gridCopyJSON(columns: table.columns, rows: indexes.map { table.rows[$0] }))
                }
            }
```

(`row` and `index` are `cellView`'s parameters.) Not on the editing `TextField` — its own menu stays.

- [ ] **Step 4: The footer's flight line and Cancel**

In `footer()`, wrap the `HStack` in a `TimelineView` that ticks only while a read runs — the api pane's pattern (`ApiPane+Sending.swift:31`):

```swift
    private func footer() -> some View {
        TimelineView(.periodic(from: .now, by: table.runningSince == nil ? 3600 : 0.1)) { context in
            HStack(spacing: 10) {
                if let line = dbFlightLine(
                    runningSince: table.runningSince, cancelledAfterMs: table.cancelledAfterMs,
                    now: context.date) {
                    Text(line)
                        .layoutPriority(2)
                        .accessibilityIdentifier("db.\(pane.id).flight")
                }
                if table.runningSince != nil {
                    Button("Cancel") {
                        dispatch("db_cancel", .object(["pane": .string(pane.id)]))
                    }
                    .buttonStyle(.plain)
                    .modifier(Verb(heading: false, enabled: true))
                    .fixedSize()
                    .accessibilityIdentifier("db.\(pane.id).cancel")
                }
                // … every existing footer item, unchanged …
            }
            // … every existing modifier on the HStack, unchanged …
        }
    }
```

Keep every existing `Text`, `Spacer` and modifier exactly as it is; only the two new items go first and the `TimelineView` wraps the whole thing. `Verb` sets its own font, which overrides the footer's 9 pt for the button only.

- [ ] **Step 5: The run control refuses while running**

The query line's Return goes to `WindowModel.runFromQueryLine`, which dispatches `db_run_query` naming the pane, and that is refused while a read runs (Task 5) — the refusal shows in the pane's refusal line, which satisfies Rule 5's "cannot be fired twice". Also gate the `‹ ›` page controls: in `DBPane.pageControls()`, add `.disabled(table.runningSince != nil)` to each button.

- [ ] **Step 6: Esc in the query line cancels a running read**

In `QueryLineEditor`, add a property after `formatRequest`:

```swift
    /// Esc while a read runs on this pane: cancels it and returns true. Otherwise false, and
    /// Esc leaves the line as before.
    var cancel: () -> Bool = { false }
```

In the Coordinator's `doCommandBy`, change the `cancelOperation` case to:

```swift
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc cancels a running read first; otherwise it leaves the line. The text stays
            // either way (Interaction Rule 2).
            if parent.cancel() { return true }
            textView.window?.makeFirstResponder(nil)
            return true
```

In `DBPane`'s `QueryLineEditor(` call, add:

```swift
                cancel: {
                    guard table.runningSince != nil else { return false }
                    dispatch("db_cancel", .object(["pane": .string(pane.id)]))
                    return true
                },
```

(If `QueryLineEditor` has an explicit `init`, add the parameter there with the same default.)

- [ ] **Step 7: Build**

Run: `cd app && swift build 2>&1 | tail -20`
Expected: `Build complete!` with no new warnings in the files touched.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilApp/DataSurface.swift app/Sources/WakilApp/QueryLineEditor.swift app/Sources/WakilApp/DBPane.swift
git commit -m "DB pane: ↑↓, Space, Esc and ⌘C on the grid; Copy cell, rows and JSON from the menu; running · N s with Cancel"
```

---

### Task 8: WakilApp — the row detail strip

**Files:**
- Create: `app/Sources/WakilApp/RowDetailStrip.swift`
- Modify: `app/Sources/WakilApp/DataSurface.swift` — the `VStack` in `body`; `rowCells`' hover overlay (`:660-677`)

**Interfaces:**
- Consumes: `rowDetailFields`, `RowDetailField` (Task 3); `showsDetail` (Task 7).
- Produces: `struct RowDetailStrip: View { let table: PaneTable; let pane: Pane; let close: () -> Void }`.

- [ ] **Step 1: Write the strip**

`app/Sources/WakilApp/RowDetailStrip.swift`:

```swift
import AppKit
import WakilKit
import SwiftUI

/// The row detail strip: the anchor row, one block per column, every value whole. Read-only.
/// It scrolls as a whole; a value taller than the strip scrolls inside its own region, capped
/// at the strip's visible height, so a 5,000-line JSON never pushes the other columns out of
/// reach. Values render through a non-editable TextKit 2 `NSTextView`, which lays out lazily,
/// so a 1 MB cell does not freeze the pane. Nothing scrolls sideways: long lines wrap at any
/// character.
struct RowDetailStrip: View {
    let table: PaneTable
    let pane: Pane
    let close: () -> Void

    private static let ink = Color(red: 0.910, green: 0.925, blue: 0.965)

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let anchor = table.selection.anchorRow, anchor < table.rows.count {
                        ForEach(rowDetailFields(columns: table.columns, row: table.rows[anchor])) { field in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.name)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Self.ink.opacity(0.45))
                                if field.isNull {
                                    Text("NULL")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Self.ink.opacity(0.30))
                                } else {
                                    RowDetailValue(text: field.display, maxHeight: geometry.size.height - 24)
                                        .accessibilityIdentifier("db.\(pane.id).detail.\(field.name)")
                                }
                            }
                        }
                    } else {
                        Text("no row selected")
                            .font(.system(size: 10))
                            .foregroundStyle(Self.ink.opacity(0.35))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Self.ink.opacity(0.03))
        .overlay(alignment: .leading) {
            Rectangle().fill(Self.ink.opacity(0.10)).frame(width: 1)
        }
        .accessibilityIdentifier("db.\(pane.id).detail")
    }
}

/// One value: a read-only, selectable, wrapping text view whose height is its content's,
/// capped at `maxHeight`, past which it scrolls inside itself.
private struct RowDetailValue: NSViewRepresentable {
    let text: String
    let maxHeight: CGFloat

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = NSColor(red: 0.910, green: 0.925, blue: 0.965, alpha: 0.85)
        textView.textContainerInset = .zero
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // Wrap at any character: base64 and minified JSON have no break points.
        textView.textContainer?.lineBreakMode = .byCharWrapping

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.scroll(.zero)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let textView = scroll.documentView as? NSTextView,
              let manager = textView.textLayoutManager
        else { return nil }
        textView.frame.size.width = width
        manager.ensureLayout(for: manager.documentRange)
        let content = manager.usageBoundsForTextContainer.height
        return CGSize(width: width, height: min(max(content, Self.font.pointSize + 4), max(maxHeight, 60)))
    }
}
```

**On `ensureLayout` for a 1 MB value:** laying out the whole document to measure it defeats TextKit 2's lazy layout. Measure it first (Step 4). If opening the strip on the 1 MB fixture takes over ~200 ms, change `sizeThatFits` to estimate: when `text.utf8.count > 64_000`, return `maxHeight` without calling `ensureLayout` — a value that big always fills the cap — and record the threshold in the commit message.

- [ ] **Step 2: Host the strip and add ⓘ**

In `DataSurface.body`, replace `rows(live, minimumRowWidth: content)` with:

```swift
                HStack(spacing: 0) {
                    rows(live, minimumRowWidth: content)
                    if showsDetail {
                        RowDetailStrip(table: table, pane: pane, close: { showsDetail = false })
                            .frame(width: max(220, geometry.size.width / 3))
                    }
                }
```

In `rowCells`' trailing hover overlay (`:660`), beside the drill's `open` button, add an ⓘ toggle shown on the hovered row:

```swift
            if hoveredRow == row.id {
                Button {
                    select(row: row.id, column: 0)
                    showsDetail.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.62, green: 0.51, blue: 1.0))
                .padding(.trailing, drill == nil ? 8 : 48)
                .accessibilityIdentifier("db.row.\(row.id).detail")
            }
```

Keep the existing `if let drill, hoveredRow == row.id { … }` as it is; put both inside one `HStack(spacing: 6)` in the overlay if they overlap.

When the strip closes, focus goes back to the grid: in the `.closeDetail` and `.toggleDetail` key handlers (Task 7) focus is already on the surface; for the ⓘ button, `select(row:column:)` sets `surfaceFocused = true` (Task 7, Step 2). Rule 6 is met.

If the anchor row disappears after a re-query (`table.rows.count <= anchor`), the strip shows "no row selected" — the spec's edge, satisfied by the `if` above.

- [ ] **Step 3: Build**

Run: `cd app && swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 4: Measure the big-cell case by hand (controller only — it needs the GUI)**

**Ask the operator and any peer sessions before using the GUI** (memory: shared GUI between sessions). Then: `make build && make app-bundle`, open the app on a seeded SQLite database with a table holding a 1 MB text cell and a 5,000-line JSON cell (create it with `sqlite3 /tmp/wakil-big.db "CREATE TABLE big(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO big VALUES (1, hex(randomblob(500000))), (2, (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<5000) SELECT '[' || group_concat('{\"i\":' || i || '}', ',') || ']' FROM n));"`, then point a database entry at it with `wakil secrets set-db`). Select row 1, press Space; select row 2; scroll each value to its end; press ↓ and ↑. Record the time to open and whether scrolling and ↑↓ stay responsive. Apply Step 1's fallback if needed.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/RowDetailStrip.swift app/Sources/WakilApp/DataSurface.swift
git commit -m "DB pane: the row detail strip — Space or ⓘ, follows the selection, big values scroll inside a capped region"
```

---

### Task 9: Docs

**Files:**
- Modify: `docs/architecture/wakilkit.md` — the `Panes/` section: `GridCopy.swift`, `RowDetail.swift`, `DataSurfaceKeys.swift`, and the DB flight on `PaneStore`; the `Registry/` section: `db_cancel`
- Modify: `docs/architecture/wakilapp.md` — `RowDetailStrip.swift`; `DataSurface`'s keys and context menu
- Modify: `docs/superpowers/specs/2026-10-13-db-pane-copy-cancel-detail-design.md` — `**Status:**` line: add "built <date>, plan `docs/superpowers/plans/2026-10-13-db-pane-copy-cancel-detail.md`"

- [ ] **Step 1: Read each architecture file's section format, then add one line per new file in that format.** One sentence each: what it holds and who uses it. No restating the spec.

- [ ] **Step 2: Check the docs gate**

Run: `make docs-check`
Expected: passes.

- [ ] **Step 3: Commit**

```bash
git add docs/architecture/wakilkit.md docs/architecture/wakilapp.md docs/superpowers/specs/2026-10-13-db-pane-copy-cancel-detail-design.md
git commit -m "Docs: the DB pane's copy, cancel and row detail in the architecture map"
```

---

## After the plan (controller)

1. Full gates, in this order: `make build`, `make test`, `make test-live` (starts nothing — `docker start wakil-acc-mysql wakil-acc-mongo` first, stop them after), `make app-test`.
2. **Cover rung:** the e2e auditor (`docs/agents/e2e.md`) writes checks for: Cancel mid-read keeps the rows and shows `cancelled after`; Esc in the query line cancels; ⌘C on one row and on several; the context menu's three items; the strip opening, following ↑↓, closing onto the same row; the 1 MB and 5,000-line cells. A blocking SQLite query (the recursive CTE in Task 1) is the slow read. Ask before `make e2e` — it takes over the screen.
3. **Walk:** the operator.
