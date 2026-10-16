# Phase 2b-iii — The Write Gate Earns a Subject: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register Wakil's first `ActionKind.mutate` action — a gated, confirmable database write — so that `phase-2a-acceptance.md`'s checks 5 and 6 can finally run.

**Architecture:** Write authority arrives as a *second Keychain credential* (`Database.writeRef`) reached by a *second code path* (`DbDriver.ConnectWritable`). The existing read path is not edited at all. Above that, an agent-proposed mutation is refused by the unchanged `writeGate`, parked in a `ConfirmationBroker`, surfaced in the window as a red plane showing the full statement, and re-dispatched only after the operator types `confirm`.

**Tech Stack:** Go 1.27 (`internal/wakilcore`, `cmd/wakil-db`, `CGO_ENABLED=0`), Swift 6.3 (`WakilKit`, `WakilApp`, SwiftPM + Swift Testing), MCP over stdio and a unix socket.

**Spec:** `docs/superpowers/specs/2026-09-09-phase-2b-iii-write-gate-design.md`

## Global Constraints

- **The read path is not edited.** `OpenDatabase`, `DbDriver.Connect`, `hardenMySQLConfig`, `sqliteReadOnlyDSN` and `sqlConn.gate` keep their current behaviour and their current doc comments. Spec §2.
- **`Connection.ReadOnly` and `Database.ReadOnly` stay inert.** Do not make them load-bearing. Spec §2.
- **Allowed mutation verbs are exactly `INSERT`, `UPDATE`, `DELETE`.** No DDL — no `CREATE`, `DROP`, `ALTER`, `TRUNCATE`, `RENAME`, `GRANT`, `REVOKE`, `LOAD DATA`. Spec §5.
- **The confirmation token on the wire is the literal string `"confirm"`.** `ActionRegistry.dispatch` is not modified. Spec §7, §8.
- **The agent can never self-confirm.** Do not move `confirmation` into any tool's argument schema. Spec §7.
- **Action names must match `^[a-zA-Z0-9_-]{1,128}$`** — underscores, never dots. Pinned by `everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule`.
- **Go commands run from the repo root**; `make test` uses `CGO_ENABLED=0` (exported by the Makefile). Swift tests run via `make app-test`, never bare `swift test`.
- **Mongo mutation is out of scope** and must fail with wording that reads as *not implemented yet*, distinguishable from a refusal. Spec §11.

---

## File Structure

**Go — created:**

| File | Responsibility |
|---|---|
| `internal/wakilcore/mutation.go` | `AssertSQLMutation`, `MutationAffectsEveryRow`. Deliberately not added to `readonly.go`, which is 900 lines about the opposite question. |
| `internal/wakilcore/mutation_test.go` | Tests for both, including the five bypass fixtures re-run against the new gate. |

**Go — modified:**

| File | Change |
|---|---|
| `internal/wakilcore/dbdriver.go` | `Written` type; `Conn.Write`; `DbDriver.ConnectWritable`, `DbDriver.AssertMutation` |
| `internal/wakilcore/sqlconn.go` | `sqlConn.writeGate` field; `sqlConn.Write` |
| `internal/wakilcore/driver_mysql.go` | `ConnectWritable`, `AssertMutation`, `hardenMySQLWriteConfig` |
| `internal/wakilcore/driver_sqlite.go` | `ConnectWritable`, `AssertMutation`, `sqliteWriteDSN`, `setMode` factored out of `setModeRO` |
| `internal/wakilcore/driver_mongo.go` | `ConnectWritable`, `AssertMutation`, `mongoConn.Write` — all not-implemented |
| `internal/wakilcore/config.go` | `Database.WriteRef` |
| `internal/wakilcore/dbresolve.go` | `OpenDatabaseWritable` |
| `cmd/wakil-db/main.go` | `mutateArg`, `openPickedWritable`, the `mutate` tool |

**Swift — created:**

| File | Responsibility |
|---|---|
| `app/Sources/WakilKit/Gate/PendingMutation.swift` | The value describing a parked proposal, plus `ConfirmationDecision`. |
| `app/Sources/WakilKit/Gate/ConfirmationBroker.swift` | The actor that parks one proposal, awaits a decision, and times out. |
| `app/Sources/WakilApp/ConfirmationPlane.swift` | The red plane the operator types into. |
| `app/Tests/WakilKitTests/ConfirmationBrokerTests.swift` | Broker behaviour. |
| `app/Tests/WakilKitTests/MutationActionTests.swift` | `db_run_mutation`'s registration, gate matrix, and journal pair. |

**Swift — modified:** `Registry/StandardActions.swift`, `MCP/MCPServer.swift`, `App/AppWiring.swift`, `App/WindowModel.swift`, `WakilApp/Canvas.swift`.

**Docs — modified/created:** `docs/wakil/phase-2a-acceptance.md`, `docs/wakil/phase-2b-iii-acceptance.md` (new), `docs/wakil/north-star.md`, `docs/wakil/operator-todo.md`.

---

## Task 1: The mutation gate

**Files:**
- Create: `internal/wakilcore/mutation.go`
- Test: `internal/wakilcore/mutation_test.go`

**Interfaces:**
- Consumes: `stripSQLComments(string) string` and `firstKeyword` (both already in `internal/wakilcore/readonly.go`), `UserError(string) error`.
- Produces: `AssertSQLMutation(sql string) error`, `MutationAffectsEveryRow(sql string) bool`.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/mutation_test.go`:

```go
package wakilcore

import "testing"

func TestAssertSQLMutationAllowsTheThreeVerbs(t *testing.T) {
	ok := []string{
		"INSERT INTO t VALUES (1)",
		"  insert into t values (1)",
		"UPDATE t SET x=1 WHERE id=2",
		"DELETE FROM t WHERE id=2",
		"/* c */ UPDATE t SET x=1",
		"INSERT INTO t SELECT * FROM u",
		"DELETE FROM t WHERE id=2;",
	}
	for _, s := range ok {
		if err := AssertSQLMutation(s); err != nil {
			t.Errorf("should allow %q: %v", s, err)
		}
	}
}

func TestAssertSQLMutationRefusesReadsAndDDL(t *testing.T) {
	bad := []string{
		"",
		"   ",
		"SELECT * FROM t",
		"EXPLAIN SELECT 1",
		"SHOW TABLES",
		"WITH x AS (SELECT 1) DELETE FROM t",
		"CREATE TABLE t (id INT)",
		"DROP TABLE t",
		"ALTER TABLE t ADD COLUMN x INT",
		"TRUNCATE t",
		"RENAME TABLE t TO u",
		"GRANT ALL ON *.* TO 'x'@'%'",
		"REVOKE ALL ON *.* FROM 'x'@'%'",
		"LOAD DATA INFILE '/etc/passwd' INTO TABLE t",
		"REPLACE INTO t VALUES (1)",
		"DELETE FROM t; DROP TABLE u",
		"INSERT INTO t VALUES (1); DROP TABLE u",
	}
	for _, s := range bad {
		if err := AssertSQLMutation(s); err == nil {
			t.Errorf("should reject %q", s)
		}
	}
}

// The five bypasses readonly.go documents were all found against the READ
// gate. They are re-run here rather than assumed inapplicable: the
// mutation gate shares stripSQLComments with it, so a regression there
// would land on both.
func TestAssertSQLMutationRefusesDDLHiddenInComments(t *testing.T) {
	bad := []string{
		"/*! DROP TABLE t */",
		"SELECT 1--1 INTO OUTFILE '/tmp/x'",
		"/*!50000 DROP */ TABLE t",
		"--\nDROP TABLE t",
	}
	for _, s := range bad {
		if err := AssertSQLMutation(s); err == nil {
			t.Errorf("should reject %q", s)
		}
	}
}

func TestAssertSQLMutationRefusesOutfile(t *testing.T) {
	bad := []string{
		"INSERT INTO t SELECT * FROM u INTO OUTFILE '/tmp/x'",
		"UPDATE t SET x=1 INTO DUMPFILE '/tmp/x'",
	}
	for _, s := range bad {
		if err := AssertSQLMutation(s); err == nil {
			t.Errorf("should reject %q", s)
		}
	}
}

func TestMutationAffectsEveryRow(t *testing.T) {
	cases := []struct {
		sql  string
		want bool
	}{
		{"DELETE FROM t", true},
		{"UPDATE t SET x=1", true},
		{"delete from t", true},
		{"DELETE FROM t WHERE id=1", false},
		{"UPDATE t SET x=1 WHERE id=1", false},
		{"update t set x=1 where id=1", false},
		// INSERT never affects existing rows, so it is never flagged.
		{"INSERT INTO t VALUES (1)", false},
		// A WHERE surviving only inside a COMMENT does not suppress the
		// warning, because stripSQLComments removes it first.
		{"DELETE FROM t -- WHERE id=1", true},
		{"DELETE FROM t /* WHERE id=1 */", true},
		// A WHERE inside a STRING LITERAL does suppress it, because
		// stripSQLComments preserves literals verbatim and this is a
		// regexp scan, not a parser. That is an UNDER-warning — the
		// operator is shown the full statement regardless — and
		// under-warning is the safe direction for an advisory. Pinned
		// here so the weakness is a recorded property rather than a
		// surprise.
		{"UPDATE t SET note='WHERE'", false},
	}
	for _, c := range cases {
		if got := MutationAffectsEveryRow(c.sql); got != c.want {
			t.Errorf("MutationAffectsEveryRow(%q) = %v, want %v", c.sql, got, c.want)
		}
	}
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `go test ./internal/wakilcore/ -run 'TestAssertSQLMutation|TestMutationAffectsEveryRow' -v`
Expected: FAIL to compile — `undefined: AssertSQLMutation`, `undefined: MutationAffectsEveryRow`.

- [ ] **Step 3: Write the implementation**

Create `internal/wakilcore/mutation.go`:

```go
package wakilcore

import (
	"regexp"
	"strings"
)

// mutationVerbs is the complete allowlist of statements AssertSQLMutation
// permits. It is three entries, and it is short on purpose.
//
// Invariant 6 ("read-only until a write earns its way in") says writes are
// added per adapter with deliberate justification, never by default. Row
// mutation has been justified — it is the subject Phase 2b-iii's write gate
// exists to gate. Schema mutation has not been justified anywhere, and must
// not arrive as a side effect of the first row mutation, so every DDL verb
// is refused here rather than merely undocumented.
//
// TRUNCATE is the entry most likely to be argued back in, and is the one to
// argue hardest about: it reads like a DELETE and is not one. In MySQL it is
// DDL, it is not transactional (so it cannot be rolled back), it resets
// AUTO_INCREMENT, and it cannot take a WHERE clause at all — which means
// MutationAffectsEveryRow below could not warn about it even in principle.
var mutationVerbs = map[string]bool{
	"INSERT": true,
	"UPDATE": true,
	"DELETE": true,
}

// outfileKeyword matches MySQL's two file-writing SELECT suffixes.
//
// This is belt-and-braces and is recorded as such. It was NOT proven
// reachable from an INSERT/UPDATE/DELETE prefix — MySQL rejects
// "INSERT ... SELECT ... INTO OUTFILE" at parse time — and it is not the
// primary defence either, since hardenMySQLWriteConfig forces
// AllowAllFiles off, which is what stops the SERVER asking this host for
// files. It costs one regexp scan and closes the question instead of
// leaving it argued.
var outfileKeyword = regexp.MustCompile(`(?i)\bINTO\s+(OUT|DUMP)FILE\b`)

// whereKeyword matches a WHERE token. Used ONLY by
// MutationAffectsEveryRow, never by the gate.
var whereKeyword = regexp.MustCompile(`(?i)\bWHERE\b`)

// AssertSQLMutation reports whether sql is a statement this adapter is
// willing to execute against a writable connection.
//
// WHY THIS NEEDS NO KEYWORD SCAN, WHERE AssertSQLReadOnly DOES.
// AssertSQLReadOnly must scan the whole statement after its prefix check,
// because a statement legitimately beginning SELECT can still write —
// "SELECT 1 INTO OUTFILE" is the documented case and drove three of that
// function's five hardening rounds. This gate has no equivalent hole: with
// ";" refused here and MultiStatements forced off in
// hardenMySQLWriteConfig, a statement beginning INSERT/UPDATE/DELETE is
// exactly one statement of that verb, and the writes it can perform are
// precisely the writes the operator is being asked to confirm. The
// outfileKeyword scan below is the one exception, and see its comment for
// why it is not load-bearing.
//
// It shares stripSQLComments with the read gate deliberately: that scanner
// is the genuinely hard-won part of readonly.go, hardened across five
// documented bypasses, and a second comment-stripper would be a second
// thing to get wrong.
func AssertSQLMutation(sql string) error {
	clean := strings.TrimSpace(stripSQLComments(sql))
	if clean == "" {
		return UserError("empty statement")
	}
	trimmed := strings.TrimRight(clean, "; \t\n")
	if strings.Contains(trimmed, ";") {
		return UserError("multiple statements are not allowed in a mutation")
	}
	if outfileKeyword.MatchString(trimmed) {
		return UserError("writing to a file is not allowed")
	}
	m := firstKeyword.FindStringSubmatch(strings.TrimSpace(trimmed))
	if len(m) != 2 || !mutationVerbs[strings.ToUpper(m[1])] {
		return UserError("only INSERT/UPDATE/DELETE statements are allowed; " +
			"schema changes (CREATE/DROP/ALTER/TRUNCATE/RENAME/GRANT) are not")
	}
	return nil
}

// MutationAffectsEveryRow reports whether an UPDATE or DELETE carries no
// WHERE clause, and therefore touches every row in its table.
//
// ADVISORY ONLY. Its sole consumer is the confirmation surface, which
// renders "no WHERE clause — this affects every row" beside the statement.
// It NEVER refuses anything, and nothing may make it do so. That is the
// whole design: a wrong answer here produces a missing or a spurious
// warning, never a blocked legitimate write — and never an unwarned
// dangerous one that the operator was not already shown the full statement
// for. Wakil does not second-guess a deliberate "DELETE FROM sessions"; it
// makes sure the operator read it.
//
// INSERT is never flagged: it adds rows and cannot affect existing ones,
// so the warning would be meaningless.
//
// It strips comments first, so a WHERE that survives only inside a comment
// does not suppress the warning.
func MutationAffectsEveryRow(sql string) bool {
	clean := strings.TrimSpace(stripSQLComments(sql))
	m := firstKeyword.FindStringSubmatch(clean)
	if len(m) != 2 {
		return false
	}
	switch strings.ToUpper(m[1]) {
	case "UPDATE", "DELETE":
		return !whereKeyword.MatchString(clean)
	default:
		return false
	}
}
```

- [ ] **Step 4: Run the test and verify it passes**

Run: `go test ./internal/wakilcore/ -run 'TestAssertSQLMutation|TestMutationAffectsEveryRow' -v`
Expected: PASS, all five tests.

- [ ] **Step 5: Run the whole Go suite and vet**

Run: `make test && make vet && make fmt`
Expected: all pass, gofmt clean.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/mutation.go internal/wakilcore/mutation_test.go
git commit -m "2b-iii: AssertSQLMutation — INSERT/UPDATE/DELETE only, no DDL

The mutation gate is a new file rather than an addition to readonly.go:
that file is 900 lines about whether a statement writes, and this one
answers the opposite question. They share stripSQLComments, which is the
part worth sharing.

MutationAffectsEveryRow is advisory and must stay so — its only consumer
is the confirmation surface's warning line, and a wrong answer there
misleads rather than blocks."
```

---

## Task 2: `Conn.Write` and the `Written` result

**Files:**
- Modify: `internal/wakilcore/dbdriver.go` (the `Conn` interface, ~line 92; add `Written` beside `Rows`, ~line 78)
- Modify: `internal/wakilcore/sqlconn.go` (the `sqlConn` struct, ~line 15; add `Write` after `Read`, ~line 135)
- Modify: `internal/wakilcore/driver_mongo.go` (add `mongoConn.Write`)
- Test: `internal/wakilcore/sqlconn_test.go`, `internal/wakilcore/driver_mongo_test.go`

**Interfaces:**
- Consumes: `AssertSQLMutation` (Task 1), `UserError`.
- Produces: `Written{RowsAffected int64, RowsAffectedKnown bool, Millis int64}`; `Conn.Write(ctx, QuerySpec) (Written, error)`; the `sqlConn.writeGate func(string) error` field, whose **nil value means the connection is read-only**.

- [ ] **Step 1: Write the failing test**

Append to `internal/wakilcore/sqlconn_test.go`:

```go
// A Conn built by the READ path has a nil writeGate, and Write must refuse
// on that ground alone — before any SQL is parsed and before the engine is
// reached. This is the property that makes the two connections asymmetric
// in exactly one direction (spec §4).
func TestSQLConnWriteRefusesOnAReadOnlyConnection(t *testing.T) {
	c := &sqlConn{gate: AssertSQLReadOnly} // writeGate deliberately nil
	_, err := c.Write(context.Background(), QuerySpec{Raw: "DELETE FROM t"})
	if err == nil {
		t.Fatal("a read-only connection must refuse Write")
	}
	if !strings.Contains(err.Error(), "read-only") {
		t.Errorf("message should say the connection is read-only, got %q", err)
	}
}

// The gate runs before the engine: a nil c.db would panic if Write reached
// it, so surviving this call proves the refusal happened first.
func TestSQLConnWriteGatesBeforeTouchingTheEngine(t *testing.T) {
	c := &sqlConn{gate: AssertSQLReadOnly, writeGate: AssertSQLMutation, db: nil}
	_, err := c.Write(context.Background(), QuerySpec{Raw: "DROP TABLE t"})
	if err == nil {
		t.Fatal("DDL must be refused")
	}
}
```

Append to `internal/wakilcore/driver_mongo_test.go`:

```go
// Mongo mutation is deferred, not refused. The wording must read as "not
// implemented yet" so a caller (including an LLM) does not report it to the
// operator as a policy rejection. See spec §11.
func TestMongoWriteIsNotImplementedRatherThanRefused(t *testing.T) {
	m := &mongoConn{}
	_, err := m.Write(context.Background(), QuerySpec{Raw: `{"collection":"c","op":"insertOne"}`})
	if err == nil {
		t.Fatal("mongo Write must fail")
	}
	if !strings.Contains(err.Error(), "not implemented") {
		t.Errorf("message must say not implemented, got %q", err)
	}
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `go test ./internal/wakilcore/ -run 'TestSQLConnWrite|TestMongoWriteIsNotImplemented' -v`
Expected: FAIL to compile — `c.Write undefined`, `unknown field writeGate`.

- [ ] **Step 3: Add `Written` and widen `Conn`**

In `internal/wakilcore/dbdriver.go`, add after the `Rows` struct:

```go
// Written is what a mutation reports back: how many rows it changed and
// how long it took. It is deliberately not a Rows — a mutation returns no
// columns and no rows, and projecting a row count into a rows grid would
// put a fabricated shape on a surface Invariant 3 promises reflects what
// is actually on screen.
//
// RowsAffectedKnown exists for the same reason Rows.Truncated does: to let
// a caller tell "zero rows changed" apart from "the driver did not say".
// database/sql's Result.RowsAffected is documented as optional and returns
// an error on drivers that do not support it. Both drivers Wakil ships
// today (go-sql-driver/mysql, modernc.org/sqlite) do support it, so the
// false case is not expected to be reachable in practice — but a silent 0
// would be a lie in the one case it is, and the honest alternative costs
// one bool.
type Written struct {
	RowsAffected      int64 `json:"rowsAffected"`
	RowsAffectedKnown bool  `json:"rowsAffectedKnown"`
	Millis            int64 `json:"millis"`
}
```

Widen the `Conn` interface:

```go
type Conn interface {
	ListContainers(ctx context.Context) ([]Container, error)
	Describe(ctx context.Context, name string) (Schema, error)
	Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error)
	// Write executes one mutating statement. A Conn obtained from
	// DbDriver.Connect ALWAYS fails this call; only one obtained from
	// DbDriver.ConnectWritable can succeed. See spec §4 — the asymmetry
	// runs one way: a write connection can still Read, because refusing
	// that would force a second connection to be opened just to show the
	// operator which rows a DELETE is about to remove.
	Write(ctx context.Context, spec QuerySpec) (Written, error)
	Close() error
}
```

- [ ] **Step 4: Implement `sqlConn.Write`**

In `internal/wakilcore/sqlconn.go`, add the field to the struct:

```go
type sqlConn struct {
	db      *sql.DB
	gate    func(string) error
	// writeGate is the mutation gate, and NIL MEANS READ-ONLY. Every
	// sqlConn built by a driver's Connect leaves it nil; only
	// ConnectWritable sets it. That is why Write's first act is a nil
	// check rather than a boolean test: there is no value of a bool that
	// a zero-valued struct literal gets wrong, but a missing function is
	// unambiguous, and a Conn assembled anywhere without explicitly
	// opting into writing cannot write.
	writeGate func(string) error
	listSQL   string
	quoteIdent func(string) string
}
```

Add after `Read`:

```go
// Write executes one mutating statement and reports how many rows changed.
//
// The order of the two refusals below is load-bearing. The nil check comes
// first so a read connection is refused on the grounds of what it IS,
// without the statement ever being parsed; only then is the statement
// judged. A connection that cannot write refuses every statement,
// including a well-formed one.
func (c *sqlConn) Write(ctx context.Context, spec QuerySpec) (Written, error) {
	if c.writeGate == nil {
		return Written{}, UserError("this connection is read-only")
	}
	if err := c.writeGate(spec.Raw); err != nil {
		return Written{}, err
	}
	start := time.Now()
	res, err := c.db.ExecContext(ctx, spec.Raw)
	if err != nil {
		return Written{}, UserError("statement failed: " + err.Error())
	}
	out := Written{Millis: time.Since(start).Milliseconds()}
	if n, err := res.RowsAffected(); err == nil {
		out.RowsAffected = n
		out.RowsAffectedKnown = true
	}
	return out, nil
}
```

- [ ] **Step 5: Implement `mongoConn.Write` as not-implemented**

In `internal/wakilcore/driver_mongo.go`, add after `Read`:

```go
// Write is deferred, not refused, and the wording says so.
//
// Mongo mutation is out of Phase 2b-iii's scope for a reason worth keeping
// at the call site: the dangerous input is not the OP but the FILTER.
// Inverting AssertMongoReadOnly's allowlist would admit deleteMany({}) — a
// whole-collection wipe that passes any op-name check — so a Mongo write
// surface needs its own thinking about unbounded filters, about updateMany
// versus updateOne, and about $out/$merge. That thinking does not belong
// in the same phase as the gate itself.
//
// This is the same shape Read uses for "count" and "distinct" above:
// wording a caller can tell apart from a policy rejection, because
// reporting "Wakil refused this" when the truth is "Wakil cannot do this
// yet" would send the operator looking for a permission to grant.
func (m *mongoConn) Write(ctx context.Context, spec QuerySpec) (Written, error) {
	return Written{}, UserError("mongo mutation is not implemented yet (Wakil writes to SQL databases only)")
}
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `go test ./internal/wakilcore/ -run 'TestSQLConnWrite|TestMongoWriteIsNotImplemented' -v`
Expected: PASS.

Then: `make test && make vet && make fmt`
Expected: all pass. If `sqlconn_test.go` or `driver_mongo_test.go` lack the `strings` or `context` import, add it.

- [ ] **Step 7: Commit**

```bash
git add internal/wakilcore/dbdriver.go internal/wakilcore/sqlconn.go internal/wakilcore/driver_mongo.go internal/wakilcore/sqlconn_test.go internal/wakilcore/driver_mongo_test.go
git commit -m "2b-iii: Conn.Write, with nil writeGate meaning read-only

A missing function is unambiguous where a boolean is not: every sqlConn
assembled without explicitly opting into writing cannot write, including
one built by a struct literal in a test.

Mongo's Write is deferred with the reason named at the call site — the
dangerous input is the filter, not the op."
```

---

## Task 3: `ConnectWritable` on all three drivers

**Files:**
- Modify: `internal/wakilcore/dbdriver.go` (the `DbDriver` interface, ~line 99)
- Modify: `internal/wakilcore/driver_mysql.go`, `internal/wakilcore/driver_sqlite.go`, `internal/wakilcore/driver_mongo.go`
- Test: `internal/wakilcore/driver_mysql_test.go`, `internal/wakilcore/driver_sqlite_test.go`, `internal/wakilcore/driver_mongo_test.go`

**Interfaces:**
- Consumes: `AssertSQLMutation` (Task 1), the `writeGate` field (Task 2).
- Produces: `DbDriver.ConnectWritable(ctx, Connection) (Conn, error)`, `DbDriver.AssertMutation(QuerySpec) error`, `hardenMySQLWriteConfig(*mysql.Config)`, `sqliteWriteDSN(string) string`, `setMode(dsn, mode string) string`.

- [ ] **Step 1: Write the failing tests**

Append to `internal/wakilcore/driver_mysql_test.go`:

```go
// Both hardening functions are checked in ONE test so they cannot drift.
// MultiStatements and AllowAllFiles must be off on both; only the
// transaction_read_only parameter distinguishes them.
func TestHardenMySQLConfigReadAndWriteAgree(t *testing.T) {
	hostile := "u:p@tcp(h:3306)/d?autocommit=1%2C%20transaction_read_only%3D0&multiStatements=true&allowAllFiles=true"

	ro, err := mysql.ParseDSN(hostile)
	if err != nil {
		t.Fatal(err)
	}
	hardenMySQLConfig(ro)
	if ro.MultiStatements || ro.AllowAllFiles {
		t.Error("read config must force MultiStatements and AllowAllFiles off")
	}
	if ro.Params["transaction_read_only"] != "1" {
		t.Errorf("read config must set transaction_read_only=1, got %v", ro.Params)
	}
	if len(ro.Params) != 1 {
		t.Errorf("read config must discard every other param, got %v", ro.Params)
	}

	rw, err := mysql.ParseDSN(hostile)
	if err != nil {
		t.Fatal(err)
	}
	hardenMySQLWriteConfig(rw)
	if rw.MultiStatements || rw.AllowAllFiles {
		t.Error("write config must force MultiStatements and AllowAllFiles off")
	}
	if _, ok := rw.Params["transaction_read_only"]; ok {
		t.Errorf("write config must NOT set transaction_read_only, got %v", rw.Params)
	}
	if len(rw.Params) != 0 {
		t.Errorf("write config must discard every param, got %v", rw.Params)
	}
}
```

Append to `internal/wakilcore/driver_sqlite_test.go`:

```go
// mode=rw, never rwc: a mutation must not bring a database into existence.
// A missing file is an error, not an empty database to write into.
func TestSQLiteWriteDSNIsRWNeverRWC(t *testing.T) {
	cases := []string{
		"/tmp/app.db",
		"file:/tmp/app.db",
		"file:/tmp/app.db?mode=ro",
		"/tmp/we ird?.db",
		"/tmp/hash#name.db",
	}
	for _, raw := range cases {
		got := sqliteWriteDSN(raw)
		if !strings.Contains(got, "mode=rw") {
			t.Errorf("sqliteWriteDSN(%q) = %q, want mode=rw", raw, got)
		}
		if strings.Contains(got, "mode=rwc") {
			t.Errorf("sqliteWriteDSN(%q) = %q, must never be rwc", raw, got)
		}
		if strings.Contains(got, "mode=ro") {
			t.Errorf("sqliteWriteDSN(%q) = %q, must override an existing mode=ro", raw, got)
		}
		if strings.Contains(got, "#") {
			t.Errorf("sqliteWriteDSN(%q) = %q, must escape a literal #", raw, got)
		}
	}
}

// The read path must be entirely unaffected by the factoring in this task.
func TestSQLiteReadOnlyDSNStillSaysRO(t *testing.T) {
	for _, raw := range []string{"/tmp/app.db", "file:/tmp/app.db?mode=rw"} {
		if got := sqliteReadOnlyDSN(raw); !strings.Contains(got, "mode=ro") {
			t.Errorf("sqliteReadOnlyDSN(%q) = %q, want mode=ro", raw, got)
		}
	}
}

// A writable SQLite connection can still read (spec §4's one-way
// asymmetry), and its Write really writes.
func TestSQLiteConnectWritableReadsAndWrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app.db")
	seed, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Exec("CREATE TABLE t (id INT, name TEXT)"); err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Exec("INSERT INTO t VALUES (1,'a')"); err != nil {
		t.Fatal(err)
	}
	seed.Close()

	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.ConnectWritable(context.Background(), Connection{URL: path})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	w, err := conn.Write(context.Background(), QuerySpec{Raw: "UPDATE t SET name='b' WHERE id=1"})
	if err != nil {
		t.Fatal(err)
	}
	if !w.RowsAffectedKnown || w.RowsAffected != 1 {
		t.Errorf("want 1 row affected and known, got %+v", w)
	}

	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT name FROM t WHERE id=1"}, 10)
	if err != nil || len(rows.Rows) != 1 || rows.Rows[0][0] != "b" {
		t.Fatalf("write did not take effect: %+v %v", rows, err)
	}
}

// The read connection refuses the same statement, and does so on the
// grounds of what the connection is.
func TestSQLiteConnectRefusesWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app.db")
	seed, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Exec("CREATE TABLE t (id INT)"); err != nil {
		t.Fatal(err)
	}
	seed.Close()

	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: path})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write(context.Background(), QuerySpec{Raw: "DELETE FROM t"}); err == nil {
		t.Fatal("a read connection must refuse Write")
	}
}
```

Append to `internal/wakilcore/driver_mongo_test.go`:

```go
func TestMongoConnectWritableIsNotImplemented(t *testing.T) {
	d, err := GetDriver("mongo")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.ConnectWritable(context.Background(), Connection{URL: "mongodb://127.0.0.1/db"}); err == nil {
		t.Fatal("mongo ConnectWritable must fail")
	} else if !strings.Contains(err.Error(), "not implemented") {
		t.Errorf("want not-implemented wording, got %q", err)
	}
	if err := d.AssertMutation(QuerySpec{Raw: `{"collection":"c","op":"insertOne"}`}); err == nil {
		t.Fatal("mongo AssertMutation must fail")
	} else if !strings.Contains(err.Error(), "not implemented") {
		t.Errorf("want not-implemented wording, got %q", err)
	}
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `go test ./internal/wakilcore/ -run 'TestHardenMySQLConfigReadAndWriteAgree|TestSQLite(Write|ReadOnly|Connect)|TestMongoConnectWritable' -v`
Expected: FAIL to compile — `hardenMySQLWriteConfig`, `sqliteWriteDSN`, `ConnectWritable`, `AssertMutation` all undefined.

- [ ] **Step 3: Widen the `DbDriver` interface**

In `internal/wakilcore/dbdriver.go`:

```go
type DbDriver interface {
	Kind() string
	// Connect opens a READ-ONLY connection. Unchanged by Phase 2b-iii,
	// and deliberately so: it takes no mode parameter, so no caller can
	// ask it for a writable connection and no bug in a flag's plumbing
	// can turn one into one. See spec §2.
	Connect(ctx context.Context, conn Connection) (Conn, error)
	// ConnectWritable opens a connection whose Write can succeed. It is a
	// separate method rather than Connect(readOnly bool) precisely so that
	// a bug here produces a broken WRITE and never a loosened read.
	ConnectWritable(ctx context.Context, conn Connection) (Conn, error)
	AssertReadOnly(spec QuerySpec) error
	AssertMutation(spec QuerySpec) error
}
```

- [ ] **Step 4: Implement the MySQL half**

In `internal/wakilcore/driver_mysql.go`, add:

```go
func (mysqlDriver) AssertMutation(spec QuerySpec) error { return AssertSQLMutation(spec.Raw) }

// ConnectWritable opens a MySQL connection whose Write can succeed.
//
// It is a near-copy of Connect, and that duplication is the point rather
// than a thing to factor away. A shared Connect(readOnly bool) would put
// the read path's engine-level guarantee at the mercy of one boolean's
// plumbing, which is exactly what spec §2 forbids and what four doc
// comments in this package currently promise does not happen. The two
// functions are meant to be edited independently.
//
// The credential is NOT the same one Connect uses: OpenDatabaseWritable
// reads Database.WriteRef, a separate Keychain entry. Write authority is
// proven to the server by presenting a credential the server itself has
// granted write roles to, rather than by Wakil asserting it to itself.
func (mysqlDriver) ConnectWritable(ctx context.Context, c Connection) (Conn, error) {
	cfg, err := mysql.ParseDSN(c.URL)
	if err != nil {
		// Same reasoning as Connect: this DSN came from the Keychain
		// with a password in it, and which fragment the driver quotes
		// back is its choice, not ours. No underlying error text.
		return nil, UserError("cannot parse mysql connection string")
	}

	hardenMySQLWriteConfig(cfg)
	dsn := cfg.FormatDSN()

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, UserError("cannot open mysql connection")
	}
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, UserError("mysql database unreachable: " + redactPassword(err.Error(), cfg.Passwd))
	}
	return &sqlConn{
		db: db,
		// Reads through a write connection are still gated read-only:
		// Read is Read regardless of which connection serves it.
		gate:       AssertSQLReadOnly,
		writeGate:  AssertSQLMutation,
		listSQL:    "SHOW TABLES",
		quoteIdent: mysqlQuoteIdent,
	}, nil
}

// hardenMySQLWriteConfig is hardenMySQLConfig's write-path sibling.
//
// It is a SEPARATE FUNCTION, deliberately not hardenMySQLConfig(readOnly
// bool). See ConnectWritable's comment for why, and
// TestHardenMySQLConfigReadAndWriteAgree for the test that stops the two
// drifting on the properties they must share.
//
// What it keeps from its sibling, and why each still matters when writing
// is the whole point:
//
//  1. Params is REPLACED, not merged, so every stored connection
//     parameter is discarded. The read path does this to stop a DSN
//     injecting "transaction_read_only=0" into the driver's unquoted
//     "SET k1 = v1, ..." statement (measured against live MySQL 8: over
//     six Connects the guarantee was off on two). Here there is no
//     read-only flag to protect, but the injection primitive is
//     identical and the parameter grammar is no safer for a writer.
//
//  2. MultiStatements stays OFF. On the read path it is a second lock on
//     AssertSQLReadOnly's ";" refusal. Here it is doing MORE work, not
//     less: it is what makes AssertSQLMutation's prefix check
//     exhaustive. A statement that begins INSERT can only be an INSERT
//     if the driver cannot be handed a second statement after it.
//
//  3. AllowAllFiles stays OFF, so the SERVER cannot ask this client for
//     an arbitrary file it can read. Nothing about writing rows should
//     let the far end read the operator's filesystem.
//
// What it drops is exactly one thing: transaction_read_only.
func hardenMySQLWriteConfig(cfg *mysql.Config) {
	cfg.Params = map[string]string{}
	cfg.MultiStatements = false
	cfg.AllowAllFiles = false
}
```

- [ ] **Step 5: Implement the SQLite half**

In `internal/wakilcore/driver_sqlite.go`, rename `setModeRO(dsn string)` to `setMode(dsn, mode string)`, replacing its final `q.Set("mode", "ro")` with `q.Set("mode", mode)`, updating its doc comment's "mode=ro" references to "the requested mode", and changing `sqliteReadOnlyDSN`'s two call sites to `setMode(..., "ro")`. Then add:

```go
func (sqliteDriver) AssertMutation(spec QuerySpec) error { return AssertSQLMutation(spec.Raw) }

// sqliteWriteDSN is sqliteReadOnlyDSN's write-path sibling, sharing setMode
// — and therefore sharing the "#"-escaping and the first-"?" path/query
// boundary that modernc.org/sqlite itself uses — while differing in the one
// value that matters.
//
// mode=rw, NEVER mode=rwc. SQLite's rwc creates the database if it is
// absent, and a mutation must not bring a database into existence: a path
// that does not resolve is a misconfiguration to report, not an empty
// database to start writing into. Getting this wrong would turn a typo in
// a Keychain entry into a silently-successful write to a brand-new file
// that nothing will ever read.
func sqliteWriteDSN(raw string) string {
	if !strings.HasPrefix(raw, "file:") {
		u := url.URL{Scheme: "file", OmitHost: true, Path: raw}
		return setMode(u.String(), "rw")
	}
	return setMode(raw, "rw")
}

// ConnectWritable opens a SQLite connection whose Write can succeed. A
// near-copy of Connect by design — see mysqlDriver.ConnectWritable's
// comment for why the duplication is deliberate.
func (sqliteDriver) ConnectWritable(ctx context.Context, c Connection) (Conn, error) {
	dsn := sqliteWriteDSN(c.URL)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, UserError("cannot open sqlite database: " + err.Error())
	}
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, UserError("sqlite database unreachable: " + err.Error())
	}
	return &sqlConn{
		db:         db,
		gate:       AssertSQLReadOnly,
		writeGate:  AssertSQLMutation,
		listSQL:    "SELECT name FROM sqlite_master WHERE type='table'",
		quoteIdent: sqliteQuoteIdent,
	}, nil
}
```

- [ ] **Step 6: Implement the Mongo half**

In `internal/wakilcore/driver_mongo.go`, add:

```go
// ConnectWritable and AssertMutation are both deferred. See mongoConn.Write
// for the reason — the dangerous input in a Mongo mutation is the filter,
// not the op, and deleteMany({}) passes any op-name allowlist.
//
// Failing at Connect rather than only at Write means an operator who
// configures a writeRef on a Mongo database is told so at the moment they
// try to use it, naming the limitation, rather than getting a connection
// that looks usable and refuses every statement.
func (mongoDriver) ConnectWritable(ctx context.Context, c Connection) (Conn, error) {
	return nil, UserError("mongo mutation is not implemented yet (Wakil writes to SQL databases only)")
}

func (mongoDriver) AssertMutation(spec QuerySpec) error {
	return UserError("mongo mutation is not implemented yet (Wakil writes to SQL databases only)")
}
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `go test ./internal/wakilcore/ -run 'TestHardenMySQLConfigReadAndWriteAgree|TestSQLite|TestMongo' -v`
Expected: PASS. Add any missing imports (`path/filepath`, `database/sql`, `strings`, `context`) to the test files.

Then: `make test && make vet && make fmt`
Expected: all pass. `TestMySQLSetInjectionCannotDisableReadOnly` and the other live-gated MySQL tests will skip without `WAKIL_MYSQL_DSN`; that is expected here.

- [ ] **Step 8: Commit**

```bash
git add internal/wakilcore/dbdriver.go internal/wakilcore/driver_mysql.go internal/wakilcore/driver_sqlite.go internal/wakilcore/driver_mongo.go internal/wakilcore/driver_mysql_test.go internal/wakilcore/driver_sqlite_test.go internal/wakilcore/driver_mongo_test.go
git commit -m "2b-iii: ConnectWritable, a second code path rather than a flag

The near-duplication between Connect and ConnectWritable is the design,
not an oversight to factor away: a shared Connect(readOnly bool) would put
the read path's engine-level guarantee at the mercy of one boolean, which
is what four doc comments in this package promise does not happen.

One test covers both MySQL hardening functions so they cannot drift on the
properties they must share — MultiStatements and AllowAllFiles stay off on
the write path too, where the first is doing more work than it does on the
read path: it is what makes AssertSQLMutation's prefix check exhaustive."
```

---

## Task 4: `writeRef` — write authority as a credential

**Files:**
- Modify: `internal/wakilcore/config.go` (`Database`, ~line 36)
- Modify: `internal/wakilcore/dbresolve.go` (add `OpenDatabaseWritable` after `OpenDatabase`, ~line 57)
- Test: `internal/wakilcore/dbresolve_test.go`, `internal/wakilcore/config_test.go`

**Interfaces:**
- Consumes: `GetDriver`, `SecretGet`, `DbDriver.ConnectWritable` (Task 3).
- Produces: `Database.WriteRef string`, `OpenDatabaseWritable(ctx, Database) (Conn, error)`.

- [ ] **Step 1: Write the failing test**

Append to `internal/wakilcore/dbresolve_test.go`:

```go
// No writeRef means the database cannot be mutated by anything, by anyone.
// The refusal must happen WITHOUT reading the Keychain: this test would
// otherwise touch the operator's login keychain, which no test here may do,
// so a passing run is itself the evidence that no lookup was attempted.
func TestOpenDatabaseWritableRefusesWithoutAWriteRef(t *testing.T) {
	d := Database{Name: "orders", Driver: "sqlite", Ref: "db:staging"}
	_, err := OpenDatabaseWritable(context.Background(), d)
	if err == nil {
		t.Fatal("a database with no writeRef must not be mutable")
	}
	for _, want := range []string{"orders", "writeRef"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("message should name %q, got %q", want, err)
		}
	}
}

// The driver is resolved before the credential, so an unknown driver is
// reported as an unknown driver rather than as a missing secret.
func TestOpenDatabaseWritableRefusesAnUnknownDriver(t *testing.T) {
	d := Database{Name: "orders", Driver: "postgres", Ref: "db:staging", WriteRef: "db:staging:write"}
	if _, err := OpenDatabaseWritable(context.Background(), d); err == nil {
		t.Fatal("an unknown driver must fail")
	}
}
```

Append to `internal/wakilcore/config_test.go`:

```go
// writeRef round-trips, and is omitted entirely when empty so every
// project.json written before Phase 2b-iii stays byte-identical.
func TestDatabaseWriteRefRoundTripsAndOmitsWhenEmpty(t *testing.T) {
	withRef := Database{Name: "orders", Driver: "mysql", Ref: "db:staging", WriteRef: "db:staging:write"}
	b, err := json.Marshal(withRef)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"writeRef":"db:staging:write"`) {
		t.Errorf("writeRef must marshal, got %s", b)
	}
	var back Database
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if back.WriteRef != "db:staging:write" {
		t.Errorf("writeRef must unmarshal, got %q", back.WriteRef)
	}

	without := Database{Name: "orders", Driver: "mysql", Ref: "db:staging"}
	b2, err := json.Marshal(without)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b2), "writeRef") {
		t.Errorf("an empty writeRef must be omitted, got %s", b2)
	}
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `go test ./internal/wakilcore/ -run 'TestOpenDatabaseWritable|TestDatabaseWriteRef' -v`
Expected: FAIL to compile — `OpenDatabaseWritable` undefined, `unknown field WriteRef`.

- [ ] **Step 3: Add the field**

In `internal/wakilcore/config.go`:

```go
type Database struct {
	Name   string `json:"name"`
	Driver string `json:"driver"`
	Ref    string `json:"ref"`
	// WriteRef names a SECOND Keychain entry, holding a credential the
	// database server has granted write permission to. Empty — which is
	// every database configured before Phase 2b-iii — means this database
	// cannot be mutated by anything: not by the agent, not by the
	// operator, not by --dispatch.
	//
	// That is Invariant 6 ("read-only until a write earns its way in")
	// applied per resource rather than per phase. A second credential
	// rather than a boolean because write authority should be proven TO
	// THE SERVER, by presenting something the server itself granted,
	// rather than asserted by Wakil to itself — the same reasoning
	// keychainService uses to put the org in the service name, and that
	// hardenMySQLConfig uses to discard rather than filter.
	//
	// It is also the only shape Mongo could ever use: driver_mongo.go
	// records that no client setting makes a *mongo.Client refuse a
	// write, so the read/write distinction there IS the credential's
	// grants and cannot be anything else.
	WriteRef string `json:"writeRef,omitempty"`
	// ReadOnly is carried and NOT consulted. See OpenDatabase.
	ReadOnly bool `json:"readOnly,omitempty"`
}
```

- [ ] **Step 4: Add `OpenDatabaseWritable`**

In `internal/wakilcore/dbresolve.go`, after `OpenDatabase` (leave `OpenDatabase` and its doc comment untouched):

```go
// OpenDatabaseWritable resolves d's driver and its SEPARATE write
// credential, and opens a connection whose Write can succeed.
//
// The order of the three steps is deliberate. The writeRef check comes
// first, so a database that was never configured for writing is refused
// without a Keychain lookup — the operator's login keychain is not
// consulted to answer a question that configuration alone already answers.
// The driver is resolved second, so an unknown driver is reported as an
// unknown driver rather than as a missing secret. Only then is the
// credential read.
//
// This function is the ONLY route to a writable Conn. OpenDatabase is
// untouched and still cannot produce one.
func OpenDatabaseWritable(ctx context.Context, d Database) (Conn, error) {
	if d.WriteRef == "" {
		return nil, UserError("database " + strconv.Quote(d.Name) +
			" is not configured for writing: add a \"writeRef\" naming a Keychain entry " +
			"whose credential the server has granted write permission to")
	}
	drv, err := GetDriver(d.Driver)
	if err != nil {
		return nil, err
	}
	url, err := SecretGet(d.WriteRef)
	if err != nil {
		return nil, err
	}
	return drv.ConnectWritable(ctx, Connection{Ref: d.WriteRef, URL: url, ReadOnly: false})
}
```

Add `"strconv"` to the file's imports if absent.

- [ ] **Step 5: Run the tests and verify they pass**

Run: `go test ./internal/wakilcore/ -run 'TestOpenDatabaseWritable|TestDatabaseWriteRef' -v`
Expected: PASS. Add `encoding/json`, `strings`, `context` imports to the test files as needed.

Then: `make test && make vet && make fmt`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/config.go internal/wakilcore/dbresolve.go internal/wakilcore/dbresolve_test.go internal/wakilcore/config_test.go
git commit -m "2b-iii: Database.writeRef — no write credential, no mutation

Empty writeRef, which is every database configured before today, means the
database cannot be mutated by anything. Invariant 6 applied per resource
rather than per phase.

The refusal happens before any Keychain lookup, so a question that
configuration alone answers never reaches the operator's login keychain."
```

---

## Task 5: The `mutate` tool on `wakil-db`

**Files:**
- Modify: `cmd/wakil-db/main.go`
- Test: `cmd/wakil-db/main_test.go`, `cmd/wakil-db/schema_test.go`

**Interfaces:**
- Consumes: `wakilcore.OpenDatabaseWritable` (Task 4), `wakilcore.Written` (Task 2), `wakilcore.ResolveEnvironment`, `wakilcore.PickDatabase`, `mcpx.ToolErr`.
- Produces: an MCP tool named `mutate` taking `{database?, statement}` and returning `wakilcore.Written`.

- [ ] **Step 1: Write the failing test**

Read `cmd/wakil-db/schema_test.go` first to match its existing style for asserting a tool's advertised schema, then append to `cmd/wakil-db/main_test.go`:

```go
// The mutate tool is registered and advertises the two params it takes.
// Kept alongside the other tool-surface tests because a tool that is
// registered but not advertised is unreachable to a client.
func TestMutateToolIsRegistered(t *testing.T) {
	s := newServer()
	if s == nil {
		t.Fatal("newServer returned nil")
	}
	// Mirror the existing tool-listing assertion in this file; the tool
	// name is "mutate" and it must appear alongside the four read tools.
	names := listToolNames(t, s)
	want := []string{"list_databases", "list_tables", "describe_table", "query", "mutate"}
	for _, w := range want {
		if !slices.Contains(names, w) {
			t.Errorf("tool %q must be registered; got %v", w, names)
		}
	}
}
```

If `cmd/wakil-db/main_test.go` has no `listToolNames` helper, write the test using whatever mechanism the existing tests in that file use to enumerate tools, and keep the same assertion.

- [ ] **Step 2: Run the test and verify it fails**

Run: `go test ./cmd/wakil-db/ -run TestMutateToolIsRegistered -v`
Expected: FAIL — `mutate` is not in the list.

- [ ] **Step 3: Implement the tool**

In `cmd/wakil-db/main.go`, add the arg type beside `queryArg`:

```go
type mutateArg struct {
	Database  string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
	Statement string `json:"statement" jsonschema:"one INSERT, UPDATE or DELETE statement; schema changes are refused"`
}
```

Add the writable opener beside `openPicked`:

```go
// openPickedWritable is openPicked's write-path sibling. It differs in one
// call — OpenDatabaseWritable rather than OpenDatabase — and that call is
// what selects the separate write credential and the separate connection
// path. Written out rather than parameterised for the same reason
// ConnectWritable is a separate method: a shared opener with a mode
// argument would put the read path at the mercy of an argument.
func openPickedWritable(ctx context.Context, name string) (wakilcore.Conn, error) {
	env, err := wakilcore.ResolveEnvironment()
	if err != nil {
		return nil, err
	}
	db, err := wakilcore.PickDatabase(env, name)
	if err != nil {
		return nil, err
	}
	return wakilcore.OpenDatabaseWritable(ctx, db)
}
```

Register the tool immediately after `query`, before `return s`:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "mutate", Description: "Run ONE INSERT, UPDATE or DELETE against the active environment's database and report how many rows changed. Schema changes (CREATE/DROP/ALTER/TRUNCATE/RENAME/GRANT) are refused, as are multiple statements. The database must have a writeRef configured or this fails without connecting. Mongo databases are not supported yet. The rowsAffectedKnown field says whether rowsAffected is a real count: false means the driver did not report one, NOT that zero rows changed."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a mutateArg) (*mcp.CallToolResult, wakilcore.Written, error) {
			conn, err := openPickedWritable(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Written{}, nil
			}
			defer conn.Close()
			out, err := conn.Write(ctx, wakilcore.QuerySpec{Raw: a.Statement})
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), wakilcore.Written{}, nil
			}
			return nil, out, nil
		})
```

Update `newServer`'s doc comment: "all four tools" becomes "all five tools", and add a sentence saying `mutate` is the only one that can change anything and that it reaches a different credential and a different connection than the other four.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `go test ./cmd/wakil-db/ -v`
Expected: PASS, including `schema_test.go`. If `schema_test.go` asserts an exact tool count, update it to five and add a comment naming `mutate` as the addition.

Then: `make test && make vet && make fmt && make build`
Expected: all pass; `bin/wakil-db` builds.

- [ ] **Step 5: Commit**

```bash
git add cmd/wakil-db/
git commit -m "2b-iii: wakil-db grows a mutate tool

The fifth tool, and the only one of the five that can change anything. It
reaches a different credential and a different connection than the other
four: openPickedWritable is written out rather than sharing openPicked with
a mode argument."
```

---

## Task 6: Live MySQL proof

**Files:**
- Test: `internal/wakilcore/driver_mysql_test.go`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: nothing consumed by later tasks. This task's deliverable is evidence.

These tests are selected by the Makefile's `LIVE_TESTS ?= TestMySQL|TestMongo|TestHardenMySQLConfig` prefix pattern, so naming them `TestMySQL…` is what enrols them — no Makefile change is needed.

- [ ] **Step 1: Start the throwaway container**

```bash
docker run -d --name wakil-acc-mysql -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=wakilacc -p 13306:3306 mysql:8
```

Wait ~15s for it to accept connections. If it already exists but is stopped: `docker start wakil-acc-mysql`.

- [ ] **Step 2: Write the failing test**

Append to `internal/wakilcore/driver_mysql_test.go`:

```go
// The write path really writes, and the read path really cannot — proved
// against a live engine rather than against the gate, because the gate is
// only half the guarantee. The read half is asserted by reaching
// sc.db.ExecContext DIRECTLY, bypassing AssertSQLReadOnly entirely, so
// what fails is the engine's transaction_read_only and not Wakil's own
// scanner.
func TestMySQLWritableConnectionWritesAndReadOnlyOneStillCannot(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	if _, err := raw.Exec("DROP TABLE IF EXISTS customers"); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec("CREATE TABLE customers (id INT PRIMARY KEY, name VARCHAR(64))"); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec("INSERT INTO customers VALUES (42,'Layla')"); err != nil {
		t.Fatal(err)
	}

	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}

	rw, err := d.ConnectWritable(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer rw.Close()

	w, err := rw.Write(context.Background(), QuerySpec{Raw: "UPDATE customers SET name='Ada' WHERE id=42"})
	if err != nil {
		t.Fatalf("write failed: %v", err)
	}
	if !w.RowsAffectedKnown || w.RowsAffected != 1 {
		t.Errorf("want 1 row affected and known, got %+v", w)
	}

	var name string
	if err := raw.QueryRow("SELECT name FROM customers WHERE id=42").Scan(&name); err != nil {
		t.Fatal(err)
	}
	if name != "Ada" {
		t.Fatalf("the write did not reach the engine: name=%q", name)
	}

	ins, err := rw.Write(context.Background(), QuerySpec{Raw: "INSERT INTO customers VALUES (43,'Sara')"})
	if err != nil || ins.RowsAffected != 1 {
		t.Fatalf("insert failed: %+v %v", ins, err)
	}
	del, err := rw.Write(context.Background(), QuerySpec{Raw: "DELETE FROM customers WHERE id=43"})
	if err != nil || del.RowsAffected != 1 {
		t.Fatalf("delete failed: %+v %v", del, err)
	}

	// The read connection, opened from the same DSN, still cannot write —
	// at the engine, not at the gate.
	ro, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer ro.Close()
	sc, ok := ro.(*sqlConn)
	if !ok {
		t.Fatalf("expected *sqlConn, got %T", ro)
	}
	if _, err := sc.db.ExecContext(context.Background(), "INSERT INTO customers VALUES (99,'Hacker')"); err == nil {
		t.Fatal("the read connection's engine must still refuse a write")
	}
	if _, err := ro.Write(context.Background(), QuerySpec{Raw: "DELETE FROM customers"}); err == nil {
		t.Fatal("the read connection's Write must refuse")
	}
}

// DDL is refused by the gate before the engine is asked, even though the
// write credential here (root) is perfectly capable of executing it. This
// is the test that proves the refusal is Wakil's policy rather than a
// permission the server happened not to grant.
func TestMySQLWritableConnectionStillRefusesDDL(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	rw, err := d.ConnectWritable(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer rw.Close()

	for _, stmt := range []string{
		"DROP TABLE customers",
		"CREATE TABLE evil (id INT)",
		"TRUNCATE customers",
		"ALTER TABLE customers ADD COLUMN x INT",
		"DELETE FROM customers; DROP TABLE customers",
	} {
		if _, err := rw.Write(context.Background(), QuerySpec{Raw: stmt}); err == nil {
			t.Errorf("must refuse %q", stmt)
		}
	}

	// And the table is still there.
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	if err := raw.QueryRow("SELECT 1 FROM customers LIMIT 1").Scan(new(int)); err != nil && err != sql.ErrNoRows {
		t.Fatalf("customers should have survived: %v", err)
	}
}
```

- [ ] **Step 3: Run the live tests**

Run:
```bash
make test-live
```
Expected: PASS, with the preflight reporting both containers running and the final line reading `test-live: all selected tests ran, none skipped.` The two new tests appear in the verbose output as `--- PASS`.

If the Mongo container is not running, `make test-live`'s preflight fails before running anything. Start it: `docker run -d --name wakil-acc-mongo -p 27018:27017 mongo:7`.

- [ ] **Step 4: Confirm they are enrolled, not skipped**

Run: `make test-live 2>&1 | grep -c -- '--- SKIP'`
Expected: `0`. A skip here means the tests certified nothing, which is the exact failure `test-live` exists to catch.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/driver_mysql_test.go
git commit -m "2b-iii: live MySQL proof that the write path writes

Two tests, both enrolled in make test-live by their TestMySQL prefix. The
first proves a write reaches the engine and that the read connection still
cannot write when addressed directly, bypassing AssertSQLReadOnly, so what
refuses is transaction_read_only and not Wakil's own scanner.

The second runs DDL through a root credential that is perfectly capable of
executing it, and proves the refusal is Wakil's policy rather than a
permission the server happened not to grant."
```

---

## Task 7: `db_run_mutation` — the first `.mutate` action

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift`
- Create: `app/Tests/WakilKitTests/MutationActionTests.swift`

**Interfaces:**
- Consumes: `wakil-db`'s `mutate` tool (Task 5), `callChecked`, `requireStringParam`, `ActionKind.mutate`.
- Produces: a registered action named `db_run_mutation`, `kind: .mutate`, params `{statement (required), database}`.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/MutationActionTests.swift`:

```swift
import Foundation
import Testing

@testable import WakilKit

// MARK: - Registration

@Test func dbRunMutationIsRegisteredAsTheFirstMutateAction() async throws {
    let registry = ActionRegistry(journalDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-test-\(UUID().uuidString)"), sessionId: "t")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil)

    let all = await registry.all()
    guard let mutation = all.first(where: { $0.name == "db_run_mutation" }) else {
        Issue.record("db_run_mutation must be registered; got \(all.map(\.name))")
        return
    }
    #expect(mutation.kind == .mutate)

    // It is the ONLY .mutate action. If a second one lands, this
    // expectation is the place to decide deliberately that it should.
    let mutations = all.filter { $0.kind == .mutate }.map(\.name)
    #expect(mutations == ["db_run_mutation"])
}

@Test func dbRunMutationRequiresAStatement() async throws {
    let registry = ActionRegistry(journalDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-test-\(UUID().uuidString)"), sessionId: "t")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil)

    let all = await registry.all()
    let mutation = all.first { $0.name == "db_run_mutation" }
    guard case .object(let schema)? = mutation?.schema,
          case .array(let required)? = schema["required"]
    else {
        Issue.record("db_run_mutation's schema must declare required params")
        return
    }
    #expect(required == [.string("statement")])
}

// MARK: - The gate now has a live subject

@Test func theFirstMutationIsBlockedInProductionAndGatedElsewhere() {
    for origin in [ActionOrigin.ui, .agent, .debug] {
        #expect(
            writeGate(environment: "production", kind: .mutate, origin: origin, targetEnvironment: nil)
                == .block)
        #expect(
            writeGate(environment: "staging", kind: .mutate, origin: origin, targetEnvironment: nil)
                == .gate)
    }
}

// MARK: - Dispatch reaches the gate, not the handler

@Test func dispatchingTheMutationInProductionJournalsBlockedAndNeverRunsTheHandler() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    // db is nil, so if the handler ever ran it would throw
    // StandardActionError.missingClient — a different error than the one
    // expected below, which is how this test distinguishes "the gate
    // stopped it" from "it failed for another reason".
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil)

    await #expect(throws: ActionError.blockedInProduction("db_run_mutation")) {
        _ = try await registry.dispatch(
            name: "db_run_mutation",
            params: .object(["statement": .string("DELETE FROM t WHERE id=1")]),
            origin: .agent, environment: "production", confirmation: "confirm")
    }

    let entries = try await registry.journalEntries()
    #expect(entries.last?.outcome == "blocked")
}

@Test func dispatchingTheMutationWithoutConfirmationJournalsGated() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil)

    await #expect(throws: ActionError.needsConfirmation("db_run_mutation")) {
        _ = try await registry.dispatch(
            name: "db_run_mutation",
            params: .object(["statement": .string("DELETE FROM t WHERE id=1")]),
            origin: .agent, environment: "staging", confirmation: nil)
    }

    let entries = try await registry.journalEntries()
    #expect(entries.last?.outcome == "gated")
}
```

Before running, open `app/Tests/WakilKitTests/StandardActionsTests.swift` and copy that file's exact way of constructing an `ActionRegistry` and a `PaneStore` — the initialiser signatures above are the plan's best reading of the source and must match the real ones.

- [ ] **Step 2: Run the test and verify it fails**

Run: `make app-test 2>&1 | grep -A3 dbRunMutation`
Expected: FAIL — `db_run_mutation` is not registered.

- [ ] **Step 3: Register the action**

In `app/Sources/WakilKit/Registry/StandardActions.swift`, add at the end of `registerStandardActions`, after `session_list`:

```swift
    // Wakil's FIRST `.mutate` action, and as of this writing its only one.
    //
    // Everything about the gate has been in place and untested against a
    // live subject since 2a: `writeGate` blocks `.mutate` outright in
    // production and gates it everywhere else, `ActionRegistry.dispatch`
    // consults it before the handler runs, and `WriteGateTests` covers the
    // full matrix. What was missing was something to gate.
    // `phase-2a-acceptance.md`'s checks 5 and 6 have said "not expressible
    // in 2a" since 2026-09-08 for exactly this reason.
    //
    // It writes NOTHING to the `db` pane, unlike `db_run_query` above. That
    // pane holds columns and rows; a mutation has neither, and projecting a
    // row count into a rows grid would put a fabricated shape on the
    // surface Invariant 3 promises reflects what is actually on screen.
    await registry.register(Action(
        name: "db_run_mutation",
        description:
            "Run ONE INSERT, UPDATE or DELETE against the active environment's database. "
            + "Requires a typed confirmation from the operator, which YOU CANNOT SUPPLY — "
            + "proposing this action parks it until a human confirms it at the keyboard. "
            + "Refused outright when the active environment is production. Schema changes "
            + "(CREATE/DROP/ALTER/TRUNCATE/RENAME/GRANT), multiple statements, and Mongo "
            + "databases are not supported.",
        kind: .mutate,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "statement": .object(["type": .string("string")]),
                "database": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("statement")]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(action: "db_run_mutation", role: "database")
            }
            let statement = try requireStringParam(params, "statement", action: "db_run_mutation")
            var arguments: [String: JSONValue] = ["statement": .string(statement)]
            if case .object(let obj) = params, let database = obj["database"] {
                arguments["database"] = database
            }
            return try await callChecked(
                db, tool: "mutate", arguments: .object(arguments), action: "db_run_mutation")
        }
    ))
```

- [ ] **Step 4: Update the file's header doc comment**

In the same file, find the sentence `/// Wakil still ships zero `.mutate` actions.` and replace it with:

```swift
/// **Wakil ships exactly one `.mutate` action, and this is where it lives.**
/// `db_run_mutation` (below) is it, added by Phase 2b-iii. Until 2026-09-09
/// this sentence read "Wakil still ships zero `.mutate` actions", which is
/// what made `phase-2a-acceptance.md`'s checks 5 and 6 unrunnable: the gate
/// was fully built and fully tested with nothing to gate.
///
/// A second `.mutate` action is a deliberate decision, not a routine
/// addition — Invariant 6 asks for a justification per adapter, and
/// `MutationActionTests` pins the count at one so that adding another fails
/// a test rather than passing unremarked.
```

Also update the header's opening count: "Registers Wakil's 2a action set" and "Five of the seven are `ActionKind.read`" must be corrected to reflect the new total. Count the registered actions in the file and state the real numbers.

- [ ] **Step 5: Run the tests and verify they pass**

Run: `make app-test`
Expected: PASS, including `everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule` and any test in `StandardActionsTests` or `AppWiringTests` asserting an action count — update those counts if they fail, adding a comment naming `db_run_mutation` as the addition.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/MutationActionTests.swift
git commit -m "2b-iii: db_run_mutation, the first .mutate action Wakil has shipped

The gate has been complete and fully tested since 2a with nothing to gate,
which is why phase-2a-acceptance.md's checks 5 and 6 have read 'not
expressible' since 2026-09-08. This is the subject.

MutationActionTests pins the count of .mutate actions at one, so a second
one fails a test rather than landing unremarked — Invariant 6 asks for a
justification per adapter and the test is where that gets noticed."
```

---

## Task 8: The confirmation broker

**Files:**
- Create: `app/Sources/WakilKit/Gate/PendingMutation.swift`
- Create: `app/Sources/WakilKit/Gate/ConfirmationBroker.swift`
- Create: `app/Tests/WakilKitTests/ConfirmationBrokerTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks — this is a standalone actor.
- Produces: `PendingMutation` (a `Sendable`, `Equatable` struct with `id: String`, `action: String`, `params: JSONValue`, `database: String?`, `statement: String`, `affectsEveryRow: Bool`, `origin: ActionOrigin`); `ConfirmationDecision` (`.approved`, `.cancelled`, `.expired`, `.busy`); `actor ConfirmationBroker` with `init(timeout: Duration = .seconds(120))`, `request(_:) async -> ConfirmationDecision`, `approve(id:)`, `cancel(id:)`, `current() -> PendingMutation?`, `updates() -> AsyncStream<PendingMutation?>`.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/ConfirmationBrokerTests.swift`:

```swift
import Foundation
import Testing

@testable import WakilKit

private func proposal(_ id: String = "p1", statement: String = "DELETE FROM t WHERE id=1")
    -> PendingMutation
{
    PendingMutation(
        id: id, action: "db_run_mutation",
        params: .object(["statement": .string(statement)]),
        database: "orders", statement: statement,
        affectsEveryRow: false, origin: .agent)
}

@Test func approvingAParkedProposalResolvesTheWaiter() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal()

    async let decision = broker.request(p)
    // Wait for the proposal to actually park before approving it.
    while await broker.current() == nil { await Task.yield() }
    #expect(await broker.current() == p)
    await broker.approve(id: p.id)

    #expect(await decision == .approved)
    #expect(await broker.current() == nil)
}

@Test func cancellingAParkedProposalResolvesTheWaiter() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal()

    async let decision = broker.request(p)
    while await broker.current() == nil { await Task.yield() }
    await broker.cancel(id: p.id)

    #expect(await decision == .cancelled)
    #expect(await broker.current() == nil)
}

@Test func aParkedProposalExpires() async throws {
    let broker = ConfirmationBroker(timeout: .milliseconds(50))
    #expect(await broker.request(proposal()) == .expired)
    #expect(await broker.current() == nil)
}

// Single-flight: a second proposal arriving while one is parked is refused
// immediately rather than queued. A queue needs an ordering rule and a
// story for contradictory confirmations, and neither is worth building
// before anyone has confirmed one mutation.
@Test func aSecondProposalIsRefusedWhileOneIsPending() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let first = proposal("p1")

    async let firstDecision = broker.request(first)
    while await broker.current() == nil { await Task.yield() }

    #expect(await broker.request(proposal("p2")) == .busy)
    // The first is still parked and unaffected.
    #expect(await broker.current() == first)

    await broker.approve(id: first.id)
    #expect(await firstDecision == .approved)
}

// A decision naming a proposal that is not the parked one is ignored — a
// stale click on a plane that has already been dismissed must not approve
// whatever happens to be parked next.
@Test func aDecisionForAStaleIdIsIgnored() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let p = proposal("p1")

    async let decision = broker.request(p)
    while await broker.current() == nil { await Task.yield() }

    await broker.approve(id: "some-other-id")
    #expect(await broker.current() == p)  // still parked

    await broker.approve(id: "p1")
    #expect(await decision == .approved)
}

@Test func updatesPublishParkAndRelease() async throws {
    let broker = ConfirmationBroker(timeout: .seconds(60))
    let stream = await broker.updates()
    var iterator = stream.makeAsyncIterator()

    let p = proposal()
    async let decision = broker.request(p)

    let parked = await iterator.next()
    #expect(parked ?? nil == p)

    await broker.approve(id: p.id)
    let released = await iterator.next()
    #expect(released ?? nil == nil)
    _ = await decision
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `make app-test 2>&1 | grep -i 'ConfirmationBroker\|PendingMutation' | head`
Expected: FAIL to compile — `cannot find 'ConfirmationBroker' in scope`.

- [ ] **Step 3: Write `PendingMutation`**

Create `app/Sources/WakilKit/Gate/PendingMutation.swift`:

```swift
import Foundation

/// One mutation that `writeGate` refused for want of a confirmation, held
/// while a human decides.
///
/// It carries the `params` it was dispatched with, verbatim, because the
/// approval path re-dispatches *this* call rather than reconstructing one
/// from the fields below. A reconstruction could differ from what was
/// refused, which would mean the operator confirmed one statement and
/// another ran.
///
/// `statement` and `database` are projections of `params` for the surface
/// to render, not the source of truth. `affectsEveryRow` likewise: it comes
/// from `wakilcore.MutationAffectsEveryRow`'s advisory scan, is used only to
/// render a warning line, and never decides anything.
public struct PendingMutation: Sendable, Equatable, Identifiable {
    public let id: String
    public let action: String
    public let params: JSONValue
    public let database: String?
    public let statement: String
    public let affectsEveryRow: Bool
    /// Who proposed it. Both origins park in the same broker and are
    /// confirmed through the same surface — one confirmation mechanism,
    /// not two — but the surface says which, because "the agent wants to
    /// delete these rows" and "you asked to delete these rows" are
    /// different things to be reading at 6pm.
    public let origin: ActionOrigin

    public init(
        id: String = UUID().uuidString,
        action: String,
        params: JSONValue,
        database: String?,
        statement: String,
        affectsEveryRow: Bool,
        origin: ActionOrigin
    ) {
        self.id = id
        self.action = action
        self.params = params
        self.database = database
        self.statement = statement
        self.affectsEveryRow = affectsEveryRow
        self.origin = origin
    }
}

/// How a parked proposal ended.
///
/// `.expired` is deliberately distinct from `.cancelled`: "you were
/// refused" and "nobody was at the keyboard" are different facts, and an
/// agent told the first when the second is true will go looking for a
/// permission to ask for instead of simply trying again.
public enum ConfirmationDecision: Sendable, Equatable {
    case approved
    case cancelled
    case expired
    /// Another proposal was already parked. The new one was never shown to
    /// anyone and never ran.
    case busy
}
```

- [ ] **Step 4: Write `ConfirmationBroker`**

Create `app/Sources/WakilKit/Gate/ConfirmationBroker.swift`:

```swift
import Foundation

/// Holds at most one refused mutation while a human decides about it.
///
/// This is the whole of the answer to a problem
/// `phase-2b-i-acceptance.md` recorded on 2026-09-08 and left open:
/// `MCPServer` reads `confirmation` as a sibling of `name`/`arguments` in
/// `tools/call` params, *"a field no conforming MCP client sends, so a real
/// agent hitting this row gets a hard refusal rather than a confirmable
/// gate."*
///
/// **The fix is not to let the agent send it.** Invariant 7 — "voice may
/// propose a mutation; only typed confirmation may execute one" — is a
/// statement about *who* confirms, and an agent emitting the string
/// "confirm" is not a human typing it. So `confirmation` stays a sibling
/// no client can reach, and the refusal stops being a dead end instead:
/// the proposal parks here, a human decides, and the same call is
/// re-dispatched.
///
/// `ActionRegistry.dispatch` knows nothing about any of this and is
/// unchanged. Parking happens strictly above it.
///
/// **Single-flight.** One proposal at a time; a second is refused `.busy`.
/// A queue would need an ordering rule, a UI that can show more than one,
/// and an answer for what happens when two confirmations contradict each
/// other — none of it worth building before anyone has confirmed one
/// mutation.
public actor ConfirmationBroker {
    private var pending: PendingMutation?
    private var waiter: CheckedContinuation<ConfirmationDecision, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<PendingMutation?>.Continuation] = [:]
    private let timeout: Duration

    /// 120 seconds. Long enough to read a statement and decide; short
    /// enough that an agent whose operator walked away is eventually told
    /// so rather than blocking forever. One constant, in one place, so the
    /// tuning pass is a one-line edit.
    public static let defaultTimeout: Duration = .seconds(120)

    public init(timeout: Duration = ConfirmationBroker.defaultTimeout) {
        self.timeout = timeout
    }

    /// Parks `proposal` and suspends until someone decides, or the timeout
    /// expires. Returns `.busy` immediately, without parking, if another
    /// proposal is already held.
    public func request(_ proposal: PendingMutation) async -> ConfirmationDecision {
        if pending != nil { return .busy }
        pending = proposal
        publish(proposal)

        // Nothing between here and the continuation suspends, so `waiter`
        // is set before any `approve`/`cancel`/expiry can run on this
        // actor — actor reentrancy needs a suspension point to interleave,
        // and creating a Task is not one.
        let id = proposal.id
        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(id: id, with: .expired)
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    public func approve(id: String) { resolve(id: id, with: .approved) }
    public func cancel(id: String) { resolve(id: id, with: .cancelled) }

    /// What is parked right now, for the surface to render.
    public func current() -> PendingMutation? { pending }

    /// A stream of the parked proposal, or `nil` when nothing is parked.
    /// The current value is delivered immediately on subscribe, so a
    /// subscriber that arrives after a proposal parked still sees it.
    public func updates() -> AsyncStream<PendingMutation?> {
        AsyncStream { continuation in
            let key = UUID()
            subscribers[key] = continuation
            continuation.yield(pending)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(key) }
            }
        }
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    /// Resolves the parked proposal, but only if `id` names it.
    ///
    /// The id check is what makes a stale decision harmless: a click on a
    /// plane that has already been dismissed, or a timeout that fires just
    /// after an approval, names a proposal that is no longer parked and is
    /// ignored — rather than approving whatever happens to be parked next.
    private func resolve(id: String, with decision: ConfirmationDecision) {
        guard let parked = pending, parked.id == id else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = waiter
        waiter = nil
        publish(nil)
        continuation?.resume(returning: decision)
    }

    private func publish(_ value: PendingMutation?) {
        for continuation in subscribers.values { continuation.yield(value) }
    }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `make app-test 2>&1 | grep -iA2 'ConfirmationBroker\|aParkedProposal\|aSecondProposal\|aDecisionForAStale\|updatesPublish'`
Expected: PASS, all six tests. If `withCheckedContinuation` warns about a leaked continuation, that indicates a path where `resolve` returns early without resuming — re-read the id guard.

Then: `make app-test`
Expected: the whole suite passes.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Gate/PendingMutation.swift app/Sources/WakilKit/Gate/ConfirmationBroker.swift app/Tests/WakilKitTests/ConfirmationBrokerTests.swift
git commit -m "2b-iii: ConfirmationBroker — a refusal stops being a dead end

phase-2b-i-acceptance.md recorded on 2026-09-08 that an agent hitting the
gate 'gets a hard refusal rather than a confirmable gate', because
confirmation is a sibling field no conforming MCP client sends. The fix is
not to let the agent send it: Invariant 7 is a statement about who
confirms. So the sibling stays unreachable and the refusal parks instead.

ActionRegistry.dispatch is untouched. Parking happens strictly above it.
Single-flight, 120s, and a stale decision naming an unparked proposal is
ignored rather than approving whatever is parked next."
```

---

## Task 9: Wiring the broker into the agent's path

**Files:**
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (`WakilWiring`, `mcpSurface`)
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift` (`MCPSurface`, `handleToolsCall`, `jsonRPCError`)
- Test: `app/Tests/WakilKitTests/MCPServerTests.swift`

**Interfaces:**
- Consumes: `ConfirmationBroker`, `PendingMutation`, `ConfirmationDecision` (Task 8); `db_run_mutation` (Task 7).
- Produces: `WakilWiring.confirmations: ConfirmationBroker`; `MCPSurface.confirmations`; JSON-RPC codes `-32004` (expired) and `-32005` (busy).

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/MCPServerTests.swift`:

```swift
// MARK: - Parked confirmations

// The agent proposes a mutation, the gate refuses it, it parks, a human
// approves, and the SAME call runs. Read `handle`'s reply and the journal
// together: the journal must carry the gated → ok pair of spec §7, which is
// what makes "proposed, refused, then confirmed" recoverable after the
// fact without any new journal field.
@Test func anAgentProposedMutationParksAndRunsOnceApproved() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    // A hand-registered mutation so this test needs no wakil-db binary.
    await registry.register(Action(
        name: "test_mutate",
        description: "test",
        kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }
    ))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(),
        confirmations: broker)

    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object([
            "name": .string("test_mutate"),
            "arguments": .object(["statement": .string("DELETE FROM t WHERE id=1")]),
        ]))

    async let reply = handle(message: call, surface: surface, environment: "staging")
    while await broker.current() == nil { await Task.yield() }
    let parked = await broker.current()
    #expect(parked?.statement == "DELETE FROM t WHERE id=1")
    #expect(parked?.origin == .agent)
    await broker.approve(id: parked!.id)

    let answered = await reply
    #expect(answered?.error == nil)

    let entries = try await registry.journalEntries()
    let outcomes = entries.filter { $0.action == "test_mutate" }.map(\.outcome)
    #expect(outcomes == ["gated", "ok"])
}

@Test func cancellingAParkedMutationRefusesTheAgent() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: broker)

    let call = JSONRPCMessage(
        id: .number(1), method: "tools/call",
        params: .object([
            "name": .string("test_mutate"),
            "arguments": .object(["statement": .string("DELETE FROM t")]),
        ]))

    async let reply = handle(message: call, surface: surface, environment: "staging")
    while await broker.current() == nil { await Task.yield() }
    await broker.cancel(id: (await broker.current())!.id)

    #expect(await reply?.error?.code == -32002)

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["gated"])
}

@Test func anExpiredConfirmationIsDistinguishableFromARefusal() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .milliseconds(50))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: broker)

    let reply = await handle(
        message: JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object([
                "name": .string("test_mutate"),
                "arguments": .object(["statement": .string("DELETE FROM t")]),
            ])),
        surface: surface, environment: "staging")

    #expect(reply?.error?.code == -32004)
    #expect(reply?.error?.code != -32002)
}

// Production is blocked, not parked. Nothing reaches the broker, because
// there is no confirmation that could make it run.
@Test func aProductionMutationIsBlockedAndNeverParks() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-test-\(UUID().uuidString)")
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let broker = ConfirmationBroker(timeout: .seconds(60))
    await registry.register(Action(
        name: "test_mutate", description: "test", kind: .mutate,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in .object(["ok": .bool(true)]) }))
    let surface = MCPSurface(
        registry: registry, panes: PaneStore(), layout: LayoutStore(), confirmations: broker)

    let reply = await handle(
        message: JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object([
                "name": .string("test_mutate"),
                "arguments": .object(["statement": .string("DELETE FROM t")]),
            ])),
        surface: surface, environment: "production")

    #expect(reply?.error?.code == -32003)
    #expect(await broker.current() == nil)
}
```

Match `MCPServerTests.swift`'s existing helpers for building a `JSONRPCMessage` and calling `handle` — the shapes above are the plan's reading of the source and the real ones win.

- [ ] **Step 2: Run the test and verify it fails**

Run: `make app-test 2>&1 | grep -i 'parked\|MCPSurface' | head`
Expected: FAIL to compile — `MCPSurface` has no `confirmations` parameter.

- [ ] **Step 3: Add the broker to the surface and the wiring**

In `app/Sources/WakilKit/MCP/MCPServer.swift`:

```swift
public struct MCPSurface: Sendable {
    public let registry: ActionRegistry
    public let panes: PaneStore
    public let layout: LayoutStore
    /// Where a refused mutation waits for a human. Paired here with the
    /// registry for the same reason `panes` and `layout` are: a server
    /// given this registry and some other assembly's broker would park
    /// proposals nobody is watching.
    public let confirmations: ConfirmationBroker

    init(
        registry: ActionRegistry, panes: PaneStore, layout: LayoutStore,
        confirmations: ConfirmationBroker
    ) {
        self.registry = registry
        self.panes = panes
        self.layout = layout
        self.confirmations = confirmations
    }
}
```

In `app/Sources/WakilKit/App/AppWiring.swift`, add a stored property to `WakilWiring`:

```swift
    /// Where a mutation refused by the gate waits for a human. One per
    /// assembly, shared by the agent's path (`MCPServer`) and the window's
    /// (`WindowModel`) — one confirmation mechanism, not two, for the same
    /// reason there is one action set behind both `--dispatch` and the
    /// window.
    public let confirmations: ConfirmationBroker
```

Set it in `WakilWiring.build` (`ConfirmationBroker()`), add it to the memberwise construction, and extend `mcpSurface`:

```swift
    public var mcpSurface: MCPSurface {
        MCPSurface(
            registry: registry, panes: panes, layout: layout,
            confirmations: confirmations)
    }
```

- [ ] **Step 4: Park in `handleToolsCall`**

In `app/Sources/WakilKit/MCP/MCPServer.swift`, replace the `do`/`catch` at the end of `handleToolsCall`:

```swift
    do {
        let result = try await surface.registry.dispatch(
            name: name, params: arguments, origin: .agent,
            environment: environment, confirmation: confirmation)
        return JSONRPCMessage(id: id, result: result)
    } catch ActionError.needsConfirmation {
        // The gate refused for want of a confirmation the agent cannot
        // supply — `confirmation` is a sibling of `name`/`arguments` that
        // no conforming MCP client sends, and Invariant 7 means it must
        // stay that way. So the proposal parks and a human decides.
        //
        // This request is held open while that happens, which is
        // deliberate: it is the same shape as the CLI's own permission
        // prompts, and it means the agent gets the real result of the real
        // call rather than a "pending" it has to learn to poll.
        return await parkForConfirmation(
            id: id, name: name, arguments: arguments,
            surface: surface, environment: environment)
    } catch let error as ActionError {
        return JSONRPCMessage(id: id, error: jsonRPCError(for: error))
    } catch {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32603, message: "\(error)"))
    }
```

Add below `handleToolsCall`:

```swift
/// JSON-RPC error codes for the two outcomes that are neither a refusal nor
/// a success. Both are distinct from `-32002` ("requires confirmation") on
/// purpose: an agent told it was refused, when the truth is that nobody was
/// at the keyboard, will go looking for a permission to ask for instead of
/// simply trying again later.
private let confirmationExpiredCode = -32004
private let confirmationBusyCode = -32005

/// Parks a refused mutation, waits for a human, and re-dispatches the
/// *same* call on approval.
///
/// The re-dispatch passes `arguments` unchanged rather than rebuilding them
/// from the parked projection: the operator confirmed a specific statement,
/// and anything reconstructed could differ from what they read.
///
/// `origin` stays `.agent` on both dispatches, and that is correct rather
/// than a compromise — the agent is who asked. The human's participation is
/// recorded by the transition itself: the journal's `gated` → `ok` pair for
/// one action cannot be produced by an agent retrying, because an agent has
/// no way to send a confirmation.
private func parkForConfirmation(
    id: JSONRPCID,
    name: String,
    arguments: JSONValue,
    surface: MCPSurface,
    environment: String
) async -> JSONRPCMessage {
    let proposal = PendingMutation(
        action: name,
        params: arguments,
        database: stringArgument(arguments, "database"),
        statement: stringArgument(arguments, "statement") ?? "",
        affectsEveryRow: mutationAffectsEveryRow(stringArgument(arguments, "statement") ?? ""),
        origin: .agent)

    switch await surface.confirmations.request(proposal) {
    case .approved:
        do {
            let result = try await surface.registry.dispatch(
                name: name, params: arguments, origin: .agent,
                environment: environment, confirmation: "confirm")
            return JSONRPCMessage(id: id, result: result)
        } catch let error as ActionError {
            return JSONRPCMessage(id: id, error: jsonRPCError(for: error))
        } catch {
            return JSONRPCMessage(id: id, error: JSONRPCError(code: -32603, message: "\(error)"))
        }
    case .cancelled:
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32002, message: "\(name) requires confirmation"))
    case .expired:
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: confirmationExpiredCode,
            message: "\(name): the operator did not confirm in time — propose it again"))
    case .busy:
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: confirmationBusyCode,
            message: "\(name): another confirmation is already waiting — try again once it is answered"))
    }
}

private func stringArgument(_ arguments: JSONValue, _ key: String) -> String? {
    guard case .object(let object) = arguments, case .string(let value)? = object[key] else {
        return nil
    }
    return value
}
```

- [ ] **Step 5: Add the Swift-side every-row scan**

`wakilcore.MutationAffectsEveryRow` is Go and unreachable from Swift, and calling `wakil-db` for a warning line would mean a round trip before a modal can render. Add to `app/Sources/WakilKit/Gate/PendingMutation.swift`:

```swift
/// Whether an `UPDATE` or `DELETE` carries no `WHERE`, and so touches every
/// row. A Swift mirror of `wakilcore.MutationAffectsEveryRow`, duplicated
/// deliberately: it exists only to render a warning line, and reaching
/// across the MCP boundary for that would mean a round trip before the
/// confirmation plane could appear.
///
/// **Advisory only, and nothing may make it otherwise.** A wrong answer
/// produces a missing or a spurious warning beside a statement the operator
/// is reading in full anyway — never a blocked legitimate write. The Go
/// gate is what refuses statements; this only decorates one.
public func mutationAffectsEveryRow(_ statement: String) -> Bool {
    let upper = statement.uppercased()
    let verb = upper.drop(while: { $0.isWhitespace }).prefix(while: { $0.isLetter })
    guard verb == "UPDATE" || verb == "DELETE" else { return false }
    return upper.range(of: #"\bWHERE\b"#, options: .regularExpression) == nil
}
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `make app-test`
Expected: PASS. Every existing `MCPSurface(...)` construction in `MCPServerTests.swift` and `AppWiringTests.swift` needs the new `confirmations:` argument — add `ConfirmationBroker()` to each.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/MCP/MCPServer.swift app/Sources/WakilKit/App/AppWiring.swift app/Sources/WakilKit/Gate/PendingMutation.swift app/Tests/WakilKitTests/MCPServerTests.swift
git commit -m "2b-iii: the agent's refused mutation parks instead of dying

handleToolsCall catches needsConfirmation, parks the proposal, holds the
JSON-RPC request open, and re-dispatches the SAME arguments on approval —
not a reconstruction, because the operator confirmed a specific statement.

Expired and busy get their own codes, distinct from -32002: an agent told
it was refused when nobody was at the keyboard goes looking for a
permission to ask for instead of trying again.

The journal needs no new field. gated → ok for one action cannot be
produced by an agent retrying, because an agent cannot send a
confirmation."
```

---

## Task 10: The confirmation plane, and the operator's own path

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`dispatch`, ~line 1117; add `runMutation` near `runQuery`, ~line 721)
- Create: `app/Sources/WakilApp/ConfirmationPlane.swift`
- Modify: `app/Sources/WakilApp/Canvas.swift`
- Modify: `app/Sources/WakilApp/WindowSession.swift` (pass `wiring.confirmations` into `WindowModel`)
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `ConfirmationBroker`, `PendingMutation`, `mutationAffectsEveryRow` (Tasks 8–9); `db_run_mutation` (Task 7).
- Produces: `WindowModel.runMutation(_ statement: String, database: String?) async`; `WindowModel.pending: PendingMutation?` (`@Published`-equivalent observable state); `WindowModel.confirmPending(typed: String) async`; `WindowModel.cancelPending() async`; `ConfirmationPlane` view.

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/WindowModelTests.swift`:

```swift
// The operator's own mutation goes through the same gate and the same
// broker as the agent's — one confirmation mechanism, not two.
@Test @MainActor func anOperatorMutationParksAndRunsOnceConfirmed() async throws {
    let model = try await makeTestModel(environment: "staging")
    await model.registerTestMutation()

    async let run: Void = model.runMutation("DELETE FROM t WHERE id=1", database: "orders")
    while model.pending == nil { await Task.yield() }
    #expect(model.pending?.origin == .ui)
    #expect(model.pending?.affectsEveryRow == false)

    await model.confirmPending(typed: "confirm")
    await run
    #expect(model.pending == nil)
    #expect(model.status == "")
}

// The wrong word does not confirm, and does not dismiss the plane either —
// a typo must not cost the operator the proposal.
@Test @MainActor func typingTheWrongWordDoesNotConfirm() async throws {
    let model = try await makeTestModel(environment: "staging")
    await model.registerTestMutation()

    async let run: Void = model.runMutation("DELETE FROM t", database: "orders")
    while model.pending == nil { await Task.yield() }
    #expect(model.pending?.affectsEveryRow == true)

    await model.confirmPending(typed: "yes")
    #expect(model.pending != nil)  // still parked

    await model.confirmPending(typed: "confirm")
    await run
    #expect(model.pending == nil)
}

@Test @MainActor func cancellingLeavesTheMutationUnrunAndSaysSo() async throws {
    let model = try await makeTestModel(environment: "staging")
    await model.registerTestMutation()

    async let run: Void = model.runMutation("DELETE FROM t WHERE id=1", database: "orders")
    while model.pending == nil { await Task.yield() }
    await model.cancelPending()
    await run

    #expect(model.pending == nil)
    #expect(model.status.contains("cancelled"))
}

// Production never parks: there is no word that would run it.
@Test @MainActor func aProductionMutationNeverReachesTheOperator() async throws {
    let model = try await makeTestModel(environment: "production")
    await model.registerTestMutation()

    await model.runMutation("DELETE FROM t WHERE id=1", database: "orders")
    #expect(model.pending == nil)
    #expect(model.status.contains("blocked"))
}
```

Add whatever `makeTestModel(environment:)` and `registerTestMutation()` helpers this file needs, following the construction `WindowModelTests.swift` already uses for a `WindowModel`. `registerTestMutation` registers a `.mutate` action named `test_mutate` whose handler returns `.object([:])`, so no `wakil-db` binary is needed.

- [ ] **Step 2: Run the test and verify it fails**

Run: `make app-test 2>&1 | grep -i 'runMutation\|pending' | head`
Expected: FAIL to compile — `value of type 'WindowModel' has no member 'runMutation'`.

- [ ] **Step 3: Teach `WindowModel.dispatch` to park**

In `app/Sources/WakilKit/App/WindowModel.swift`, add the broker to the initialiser (`confirmations: ConfirmationBroker`), store it, and add observable state:

```swift
    /// The mutation currently waiting for this operator, or `nil`. The
    /// confirmation plane renders from this.
    public private(set) var pending: PendingMutation?
```

Replace `dispatch`'s doc comment — the existing one says *"`confirmation` is always `nil`: 2a registers zero `.mutate` actions … The typed-confirmation control Invariant 7 requires arrives with the first mutation, in 2b"* — with:

```swift
    /// How this window's controls call the registry — every one of them,
    /// and the only caller of `ActionRegistry.dispatch` here besides
    /// `paletteSource`. Returns `nil` on failure, having put the reason in
    /// `status`.
    ///
    /// The first dispatch always passes `confirmation: nil`, including for
    /// a `.mutate`. That is not an oversight: the operator has not typed
    /// anything yet, and pre-supplying the word the gate wants would make
    /// the window a caller that confirms on the human's behalf — exactly
    /// what Invariant 7 forbids the agent from doing. A refusal parks in
    /// `confirmations` and the plane asks; only `confirmPending` re-enters
    /// with `"confirm"`.
    ///
    /// `environment` is passed through as read from `wakil-ctx`, so the
    /// string the gate judges is the same string Invariant 8 puts on
    /// screen.
```

and its body:

```swift
    @discardableResult
    private func dispatch(_ name: String, _ params: JSONValue) async -> JSONValue? {
        do {
            let result = try await registry.dispatch(
                name: name, params: params, origin: .ui,
                environment: environment, confirmation: nil)
            status = ""
            return result
        } catch ActionError.needsConfirmation {
            return await parkAndAwait(name, params)
        } catch {
            status = "\(name): \(error)"
            return nil
        }
    }

    /// Parks a refused mutation, shows it, and re-dispatches it if the
    /// operator confirms — the same three steps `MCPServer` takes for the
    /// agent, through the same broker.
    private func parkAndAwait(_ name: String, _ params: JSONValue) async -> JSONValue? {
        let statement = stringParam(params, "statement") ?? ""
        let proposal = PendingMutation(
            action: name, params: params,
            database: stringParam(params, "database"),
            statement: statement,
            affectsEveryRow: mutationAffectsEveryRow(statement),
            origin: .ui)

        switch await confirmations.request(proposal) {
        case .approved:
            do {
                let result = try await registry.dispatch(
                    name: name, params: params, origin: .ui,
                    environment: environment, confirmation: "confirm")
                status = ""
                return result
            } catch {
                status = "\(name): \(error)"
                return nil
            }
        case .cancelled:
            status = "\(name): cancelled — nothing ran"
            return nil
        case .expired:
            status = "\(name): the confirmation expired — nothing ran"
            return nil
        case .busy:
            status = "\(name): another confirmation is already waiting"
            return nil
        }
    }

    private func stringParam(_ params: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = params, case .string(let value)? = object[key] else {
            return nil
        }
        return value
    }
```

Add the entry point beside `runQuery`:

```swift
    /// Runs one mutation. It will not execute until the operator confirms
    /// it in the plane — see `dispatch`.
    ///
    /// It does NOT refresh the pane afterwards, unlike `runQuery`: a
    /// mutation returns no rows, and re-reading the pane would leave the
    /// previous query's results on screen looking like this statement's
    /// output.
    public func runMutation(_ statement: String, database: String?) async {
        var params: [String: JSONValue] = ["statement": .string(statement)]
        if let database { params["database"] = .string(database) }
        _ = await dispatch("db_run_mutation", .object(params))
    }

    /// What the plane's confirm control calls. Only the exact string
    /// `"confirm"` approves; anything else leaves the proposal parked, so
    /// a typo does not cost the operator the proposal.
    public func confirmPending(typed: String) async {
        guard let parked = pending else { return }
        guard typed == "confirm" else { return }
        await confirmations.approve(id: parked.id)
    }

    /// What Cancel and ESC call. Cancelling is always the safe default.
    public func cancelPending() async {
        guard let parked = pending else { return }
        await confirmations.cancel(id: parked.id)
    }
```

Start an observation task in the model's setup (wherever `WindowModel` already starts long-lived work) that mirrors the broker into `pending`:

```swift
        Task { [weak self] in
            guard let self else { return }
            for await parked in await confirmations.updates() {
                await MainActor.run { self.pending = parked }
            }
        }
```

- [ ] **Step 4: Run the model tests and verify they pass**

Run: `make app-test 2>&1 | grep -iA2 'Mutation\|pending'`
Expected: PASS. Every `WindowModel(...)` construction in the app and tests needs the new `confirmations:` argument — `WindowSession.start` passes `wiring.confirmations`.

- [ ] **Step 5: Build the plane**

Create `app/Sources/WakilApp/ConfirmationPlane.swift`:

```swift
import WakilKit
import SwiftUI

/// The typed-confirmation surface Invariant 7 has required since the
/// charter and that nothing could render until Phase 2b-iii gave the gate a
/// subject.
///
/// A plane above the canvas (design-language §3's depth model), edged in
/// §5's reserved destructive red — deliberately NOT an `NSAlert`. A system
/// modal is off-language, and it spins its own run loop, which the void's
/// `CAMetalLayer` and 2b-iv's motion are not written to survive.
///
/// The statement is shown VERBATIM AND UNELIDED. An operator confirming a
/// statement they cannot entirely see is not confirming it, so this scrolls
/// rather than truncating.
struct ConfirmationPlane: View {
    let pending: PendingMutation
    let environment: String
    @Binding var typed: String
    let confirm: () -> Void
    let cancel: () -> Void

    private var destructive: Color { Color(hex: 0xE8_5C_5C) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(pending.origin == .agent ? "The agent proposes a change" : "Confirm this change")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Text(environment.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(destructive)
            }

            if let database = pending.database {
                Text(database).font(.system(size: 12, design: .monospaced)).opacity(0.7)
            }

            ScrollView {
                Text(pending.statement)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            if pending.affectsEveryRow {
                Text("No WHERE clause — this affects every row.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(destructive)
            }

            HStack(spacing: 12) {
                TextField("type confirm", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(confirm)
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Run", action: confirm).disabled(typed != "confirm")
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(.black.opacity(0.86))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(destructive, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 30)
    }
}
```

If `Color(hex:)` does not already exist in `WakilApp`, use whatever `Palettes.swift` provides for the destructive hue — check it first; 2b-ii assigned `#e85c5c` and it should already be named there.

- [ ] **Step 6: Present it from the canvas**

In `app/Sources/WakilApp/Canvas.swift`, overlay the plane above the existing canvas content when `model.pending != nil`, centred, with a dimming backdrop. Hold the typed text in a `@State private var typedConfirmation = ""` and clear it whenever `model.pending` becomes `nil`, so a previous proposal's typing never carries into the next one. Wire `confirm` to `model.confirmPending(typed:)` and `cancel` to `model.cancelPending()`.

- [ ] **Step 7: Build and look at it**

Run: `make app-bundle && app/Wakil.app/Contents/MacOS/Wakil`
Expected: the window opens. There is no UI entry point for a mutation yet, so the plane cannot be triggered by hand at this step; confirm only that the app builds and the window still renders. The plane's real judgement happens in Task 11's acceptance run.

Run: `make app-test`
Expected: the whole suite passes.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp/ConfirmationPlane.swift app/Sources/WakilApp/Canvas.swift app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "2b-iii: the confirmation plane, and one mechanism for both origins

The operator's own mutation parks in the same broker as the agent's and is
confirmed through the same surface — the same argument WakilWiring.build
makes for having one action set behind both --dispatch and the window.

The window's first dispatch passes confirmation: nil even for a .mutate.
Pre-supplying the word would make the window a caller that confirms on the
human's behalf, which is exactly what Invariant 7 forbids the agent from
doing.

A plane rather than an NSAlert: a system modal is off-language and spins
its own run loop, which the void's CAMetalLayer is not written to survive."
```

---

## Task 11: Documentation, and the runbook that closes 2a

**Files:**
- Modify: `docs/wakil/phase-2a-acceptance.md` (checks 5 and 6, ~lines 414-475)
- Create: `docs/wakil/phase-2b-iii-acceptance.md`
- Modify: `docs/wakil/north-star.md` (the 2b table, ~line 431; Invariant 6's note)
- Modify: `docs/wakil/operator-todo.md`

**Interfaces:**
- Consumes: everything. This task is the phase's honest record.
- Produces: no code.

- [ ] **Step 1: Make checks 5 and 6 concrete**

In `docs/wakil/phase-2a-acceptance.md`, replace `<the mutating action>` with `db_run_mutation` and the `{...}` params with a real object in both check 5's and check 6's scripts, and add a dated note above each saying the check became runnable on 2026-09-09 with Phase 2b-iii, naming the spec. Keep the surrounding prose about *why* each check exists — only the placeholders change.

Check 5's scripts become:

```bash
# Expected: the mutation is refused for want of confirmation. Exit code 2.
printf '%s\n' '{"action":"db_run_mutation","params":{"statement":"DELETE FROM customers WHERE id=43","database":"orders"}}' > /tmp/wakil-check5.jsonl
app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check5.jsonl --environment staging
[ $? -eq 2 ] && echo "gated as expected"

# Expected: with the confirmation, it runs. Exit code 0.
printf '%s\n' '{"action":"db_run_mutation","params":{"statement":"DELETE FROM customers WHERE id=43","database":"orders"},"confirmation":"confirm"}' \
  > /tmp/wakil-check5-confirmed.jsonl
app/Wakil.app/Contents/MacOS/Wakil --dispatch /tmp/wakil-check5-confirmed.jsonl --environment staging
[ $? -eq 0 ] && echo "confirmed and ran"
```

Check 6's becomes the same statement with `--environment production` and the `confirmation` present, expecting exit 2 and a `"outcome":"blocked"` journal line.

Add a precondition paragraph before check 5: the `orders` database must have a `writeRef` configured and the credential it names must have write permission, or both scripts fail at the connection rather than at the gate — which would pass check 5's first half for the wrong reason. Give the exact commands:

```bash
wakil secrets set 'db:staging:write'   # paste the write DSN on stdin
# then add "writeRef": "db:staging:write" to that database in project.json
```

- [ ] **Step 2: Write the 2b-iii runbook**

Create `docs/wakil/phase-2b-iii-acceptance.md`, following `phase-2b-iv-acceptance.md`'s structure. It must contain:

- **§0 — what was implemented and what was not**, naming the three items split out of 2b-iii (session resume, provider picker, signing) and Mongo mutation, each with its reason.
- **§1 — before you start:** the `writeRef` precondition, the throwaway MySQL container, and the launch command from `phase-2a-acceptance.md` §1.
- **§2 — the standing checks**, each with an explicit *not yet run* marker to be dated when walked:
  1. 2a check 5 (gated, then confirmed) — script above.
  2. 2a check 6 (blocked in production, not recoverable by confirmation) — script above.
  3. **The live agent turn owed since 2026-09-08** (`phase-2b-i-acceptance.md` §5): ask the agent to change one row, watch the plane appear, confirm it by hand, and check the journal carries `gated` then `ok` for `db_run_mutation` with `origin: agent`.
  4. **Cancel** the same proposal instead, and confirm nothing ran.
  5. **Walk away** for two minutes and confirm the agent is told the confirmation expired, in wording distinguishable from a refusal.
  6. **By eye, and the reason the phase exists:** does the plane read as *alarming* rather than as *an obstacle*? Is the full statement legible? Does the every-row warning land? Is `#e85c5c` right against the void, or does it vibrate?
- **§3 — known gaps**, mirroring the spec's §11 rather than restating it: Mongo, DDL, the `"confirm"` token's weakness, the missing fifth `CoreState`, single-flight only.

Mark every check **not yet run**, exactly as `phase-2b-ii-acceptance.md` does. Do not write a date next to a check nobody has walked.

- [ ] **Step 3: Update the north-star**

In `docs/wakil/north-star.md`:

- Change the 2b-iii row's *Delivers* to name only the write-gate UI and the first `.mutate`, and add rows for the three split-out items (2b-v session resume, 2b-vi provider picker, 2b-vii signing), each with its exit criterion. Note that signing needs a Developer ID Application certificate not currently held.
- Add a paragraph under the table, dated 2026-09-09, in the style of the existing 2b-iv paragraph: 2b-iii was split for the reason 2b itself was, and record that it is **implemented, not met** — its acceptance runbook has not been walked.
- Under Invariant 6, add a sentence recording that the first write to earn its way in is row mutation on SQL databases, gated by `AssertSQLMutation`, and that schema mutation has not.

- [ ] **Step 4: Update the operator todo**

In `docs/wakil/operator-todo.md`, add a section for the `writeRef` setup: what to run, and — stated as the spec's §12 risk states it — that Wakil cannot audit a grant it did not make, so the write credential should be granted the narrowest permission the statements actually need. Say plainly that a `writeRef` pointing at a `root` credential works and defeats the point.

- [ ] **Step 5: Verify the docs agree with the code**

Run:
```bash
grep -rn "zero .mutate\|no \`\.mutate\`\|not expressible" docs/ app/Sources/ | grep -v phase-2b-iii
```
Expected: no hit that is still asserting Wakil has no mutating action as a present-tense fact. Any survivor is either a historical note (fine, and should read as one) or a stale claim (fix it).

Run: `make test && make vet && make fmt && make app-test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add docs/
git commit -m "2b-iii: acceptance runbook, and checks 5 and 6 become runnable

phase-2a-acceptance.md's checks 5 and 6 have read 'not expressible in 2a'
since 2026-09-08 because there was no .mutate action to gate. The
placeholders are now db_run_mutation and a real statement.

The new runbook also carries the live agent turn owed since 2026-09-08
(phase-2b-i-acceptance.md §5), which could not be satisfied before today:
an agent hitting the gate got a hard refusal, because confirmation is a
sibling no conforming MCP client sends.

Every check is marked not yet run. The code being written and the phase
being done are different claims."
```

---

## Final verification

- [ ] **Full suite, both languages**

```bash
make test && make vet && make fmt && make build && make app-test
```
Expected: all green. Record the Swift test count — `phase-2b-iv-acceptance.md` H1 expects 294 before this phase, so the new total should be 294 plus the tests added here.

- [ ] **Live suite**

```bash
make test-live
```
Expected: `test-live: all selected tests ran, none skipped.`

- [ ] **Do not claim the phase is met.** Every check in `phase-2b-iii-acceptance.md` is unwalked. The correct closing statement is *implemented, not met* — the same distinction the north-star draws for 2b-ii and 2b-iv.
