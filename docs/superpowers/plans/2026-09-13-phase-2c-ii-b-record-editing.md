# Phase 2c-ii-b — Record Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-click a cell in a DB pane, it becomes an input, Enter composes one `UPDATE` and sends it through the existing `db_run_mutation` gate, plane and production block.

**Architecture:** Go decides everything and Swift renders. The driver reports, per read, whether the result is editable, which table it came from, which columns are writable, and — per row — the rendered `WHERE` predicate that identifies it. Swift stores that predicate as an opaque token and hands it back untouched, so a key above 2^53 never becomes a number on the Swift side. Composition goes through a new read-only `render_update` tool, so the one `.mutate` action keeps exactly one input shape.

**Tech Stack:** Go 1.27 (`internal/wakilcore`, `cmd/wakil-db`, `modelcontextprotocol/go-sdk`), Swift 6 / SwiftUI (`app/Sources/WakilKit`, `app/Sources/WakilApp`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-13-phase-2c-ii-b-record-editing-design.md`

## Global Constraints

- **Build:** `make build` (Go) and `make app-build` (Swift). **Test:** `make test`, `make app-test`, `make vet`. Live-engine tests: `make test-live`, which needs the `wakil-acc-mysql` and `wakil-acc-mongo` containers up.
- **Prerequisite:** `docs/superpowers/plans/2026-09-13-integer-fidelity.md` is complete and its Task 9 is ticked. The edit does not depend on it; the operator's ability to *read* the key they are editing does.
- **Swift never composes SQL.** It may carry a predicate the driver produced and hand it back unmodified. It must never parse, split, concatenate or build one. This is 2c-ii's rule (`PaneFetch.swift`'s type doc comment) and it is not relaxed here.
- **`WakilApp` has no test target and cannot have one.** Any decision that must be tested lives in `WakilKit` as a free function on values — the rule `shouldAdoptSubject`, `offersDrill` and `queryLineDatabase` already follow.
- **No `.keyboardShortcut` may be added to any view inside a pane, ever.** `DBPane`'s doc comment records the measurement: a per-pane shortcut is window-scoped and fires the first-registered pane's control whatever has focus.
- **`db_run_mutation` stays the only `.mutate` action, with exactly its current parameters** (`statement`, optional `database`). Decision 20. Nothing in this plan adds a `.mutate` action or a second input shape to that one.
- **Invariant 2:** nothing in the view writes to a database. Every path goes through `ActionRegistry.dispatch`.
- **Commit after every task.** Message body explains behaviour, never a task number or a defect id.

---

## File Structure

### Go

| File | Responsibility | Task |
|---|---|---|
| `internal/wakilcore/dbdriver.go` | `Conn.PrimaryKey`; `Rows.Editable` type | 1, 5 |
| `internal/wakilcore/sqlconn.go` | `PrimaryKey` via a per-driver query; `quoteLiteral` field; `Editable` on `Read`/`ReadTable` | 1, 3, 5 |
| `internal/wakilcore/driver_sqlite.go` | sqlite key query, literal quoting, NUL refusal | 1, 3 |
| `internal/wakilcore/driver_mysql.go` | MySQL key query, literal quoting, `sql_mode` read at connect | 1, 3 |
| `internal/wakilcore/driver_mongo.go` | `PrimaryKey` returns nothing — no key, not editable | 1 |
| `internal/wakilcore/editable.go` | **new** — the one-named-table recogniser | 4 |
| `internal/wakilcore/updatestmt.go` | **new** — validation and `UPDATE` composition | 6 |
| `cmd/wakil-db/main.go` | `render_update` tool | 7 |

### Swift

| File | Responsibility | Task |
|---|---|---|
| `app/Sources/WakilKit/Panes/PaneEditable.swift` | **new** — `PaneEditable` value + the projection from a tool result + the "is this cell editable" predicate | 8 |
| `app/Sources/WakilKit/Panes/PaneContents.swift` | `sortedRows` returns a permutation | 9 |
| `app/Sources/WakilKit/Panes/PaneStore.swift` | stores `editable` + row keys, permutes both, excludes keys from `snapshot` | 9 |
| `app/Sources/WakilKit/Registry/StandardActions.swift` | `dbPaneContents` carries `Editable`; `db_render_update` action | 8, 10 |
| `app/Sources/WakilKit/App/WindowModel.swift` | `commitCellEdit` — render, then mutate, then refetch | 11 |
| `app/Sources/WakilApp/DataSurface.swift` | double-click editor, hover cue, footer label | 12, 13 |
| `docs/wakil/phase-2c-ii-b-acceptance.md` | **new** — the runbook | 14 |

---

## Task 1: `Conn.PrimaryKey`

**Files:**
- Modify: `internal/wakilcore/dbdriver.go:197-223` (the `Conn` interface)
- Modify: `internal/wakilcore/sqlconn.go` (add the method, add a `primaryKeySQL` field)
- Modify: `internal/wakilcore/driver_sqlite.go`, `internal/wakilcore/driver_mysql.go` (set the field)
- Modify: `internal/wakilcore/driver_mongo.go` (add the method)
- Test: `internal/wakilcore/sqlconn_test.go`, `internal/wakilcore/driver_mysql_test.go`

**Interfaces:**
- Produces: `Conn.PrimaryKey(ctx context.Context, table string) ([]string, error)` — key columns in the engine's reported key order; an empty slice and a nil error for a table with no key, a view, or Mongo.

- [ ] **Step 1: Write the failing sqlite test**

Append to `internal/wakilcore/sqlconn_test.go`:

```go
func TestSQLitePrimaryKey(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE ints (id INTEGER PRIMARY KEY, name TEXT)`,
		`CREATE TABLE comp (a INT, b TEXT, c INT, PRIMARY KEY (b, a))`,
		`CREATE TABLE nopk (x INT, y TEXT)`,
		`CREATE TABLE wr (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID`,
		`CREATE VIEW v1 AS SELECT id, name FROM ints`,
	})
	for _, tc := range []struct {
		table string
		want  []string
	}{
		{"ints", []string{"id"}},
		// Declared (a, b, c) and keyed (b, a): the ENGINE'S key order,
		// which is not declaration order.
		{"comp", []string{"b", "a"}},
		{"nopk", nil},
		{"wr", []string{"k"}},
		{"v1", nil},
		{"missing", nil},
	} {
		got, err := conn.PrimaryKey(context.Background(), tc.table)
		if err != nil {
			t.Fatalf("%s: %v", tc.table, err)
		}
		if len(got) != len(tc.want) {
			t.Fatalf("%s: got %v want %v", tc.table, got, tc.want)
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Fatalf("%s: got %v want %v", tc.table, got, tc.want)
			}
		}
	}
}
```

**`newSQLiteTestConn` may not exist under that name.** Read the top of `sqlconn_test.go` and use whatever helper that file already uses to build a `*sqlConn` over a temp sqlite file with DDL applied. If there is none, write one and keep it unexported in the test file.

- [ ] **Step 2: Run it and watch it fail**

Run: `go test ./internal/wakilcore -run TestSQLitePrimaryKey`
Expected: FAIL — `conn.PrimaryKey undefined`.

- [ ] **Step 3: Add the interface method and the shared implementation**

In `dbdriver.go`, inside `type Conn interface`, after `Describe`:

```go
	// PrimaryKey reports a table's primary-key columns, in the order the
	// engine reports them for the key — which is NOT declaration order:
	// PRIMARY KEY (b, a) on a table declared (a, b, c) reports b first,
	// measured on both engines.
	//
	// An empty result and a nil error mean "this has no primary key", and
	// that is the answer for a keyless table, for a view, and for a table
	// that does not exist. A missing table is Describe's failure to
	// report, not this one's; answering "no key" for one costs nothing,
	// because "no key" already means "not editable".
	//
	// A UNIQUE NOT NULL column is not a primary key and is not reported.
	// It would identify a row just as well; Decision 20 says primary key,
	// and the gap is deliberate.
	PrimaryKey(ctx context.Context, table string) ([]string, error)
```

In `sqlconn.go`, add a field to `sqlConn`:

```go
	// primaryKeySQL returns a table's primary-key columns in key order,
	// taking the table name as its ONE bound parameter.
	//
	// A parameter and not an interpolated identifier, unlike Describe:
	// both engines offer a parameterised route — sqlite's
	// pragma_table_info table-valued function and MySQL's
	// information_schema — so quoting is not needed here and quoteIdent's
	// compromise does not have to be repeated.
	primaryKeySQL string
```

and the method:

```go
func (c *sqlConn) PrimaryKey(ctx context.Context, table string) ([]string, error) {
	if c.primaryKeySQL == "" {
		return nil, nil
	}
	// Describe's NUL rule, for Describe's reason: both engines truncate an
	// identifier at a NUL, so the answer would be about a table nobody
	// asked for.
	if strings.IndexByte(table, 0) >= 0 {
		return nil, UserError("invalid table name")
	}
	rows, err := c.db.QueryContext(ctx, c.primaryKeySQL, table)
	if err != nil {
		return nil, UserError("cannot read the primary key of " + table + ": " + err.Error())
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out = append(out, name)
	}
	return out, rows.Err()
}
```

In `driver_sqlite.go`, add to **both** the `Connect` and (if present) any other `sqlConn` construction:

```go
		primaryKeySQL: "SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk",
```

In `driver_mysql.go`, add to **both** `Connect` and `ConnectWritable`:

```go
		primaryKeySQL: "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE " +
			"WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? " +
			"AND CONSTRAINT_NAME = 'PRIMARY' ORDER BY ORDINAL_POSITION",
```

**`information_schema` and not `SHOW KEYS`**, for two measured reasons: `SHOW KEYS FROM <name>` has nowhere to put a parameter and would have to interpolate the name, and it returns `Error 1146` for a missing table where `information_schema` returns nothing.

In `driver_mongo.go`, add:

```go
// PrimaryKey reports no key. Mongo's write path is unimplemented — Write
// refuses every statement — so a Mongo result is never editable, and
// "no key columns" is already exactly how that is expressed.
func (m *mongoConn) PrimaryKey(context.Context, string) ([]string, error) {
	return nil, nil
}
```

- [ ] **Step 4: Run the sqlite test**

Run: `go test ./internal/wakilcore -run TestSQLitePrimaryKey -v`
Expected: PASS.

- [ ] **Step 5: Write and run the live MySQL test**

Append to `internal/wakilcore/driver_mysql_test.go`, following that file's existing
`os.Getenv("WAKIL_MYSQL_DSN")` + `t.Skip` preamble exactly:

```go
func TestMySQLPrimaryKey(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("WAKIL_MYSQL_DSN not set")
	}
	conn := mustConnectMySQL(t, dsn) // use this file's existing helper
	defer conn.Close()
	exec(t, conn, `DROP TABLE IF EXISTS pk_ints`)
	exec(t, conn, `CREATE TABLE pk_ints (id INT PRIMARY KEY, v VARCHAR(10))`)
	exec(t, conn, `DROP TABLE IF EXISTS pk_comp`)
	exec(t, conn, `CREATE TABLE pk_comp (a INT, b VARCHAR(20), c INT, PRIMARY KEY (b, a))`)
	exec(t, conn, `DROP TABLE IF EXISTS pk_none`)
	exec(t, conn, `CREATE TABLE pk_none (x INT)`)
	exec(t, conn, `DROP TABLE IF EXISTS pk_uniq`)
	exec(t, conn, `CREATE TABLE pk_uniq (u VARCHAR(20) UNIQUE NOT NULL)`)

	check := func(table string, want ...string) {
		t.Helper()
		got, err := conn.PrimaryKey(context.Background(), table)
		if err != nil {
			t.Fatalf("%s: %v", table, err)
		}
		if len(got) != len(want) {
			t.Fatalf("%s: got %v want %v", table, got, want)
		}
		for i := range got {
			if got[i] != want[i] {
				t.Fatalf("%s: got %v want %v", table, got, want)
			}
		}
	}
	check("pk_ints", "id")
	check("pk_comp", "b", "a") // key order, not declaration order
	check("pk_none")
	check("pk_uniq") // UNIQUE NOT NULL is not a primary key
	check("missing") // no rows, no error
}
```

**`mustConnectMySQL` and `exec` are placeholders for this file's real helpers.** Read
`driver_mysql_test.go` and use whatever it actually uses to obtain a `Conn` and run DDL.

Run: `make test-live 2>&1 | tail -20`
Expected: PASS, with no SKIPs (the target fails on a skip by design).

- [ ] **Step 6: Fill in `Column.Key`, which has been waiting for this**

`wakilcore.Column` already declares `Key bool`, and `schemaPaneContents` in
`StandardActions.swift` already draws a `key` column — the comment there says the field
"is here so that when a driver learns keyness the surface already has somewhere to draw
it; until then it is honestly false everywhere." It has now learned.

In `sqlConn.Describe`, after building `sch.Columns`, mark the key columns:

```go
	// Column.Key has been declared and unset since Phase 1, and
	// schemaPaneContents already draws it. PrimaryKey is what it was
	// waiting for.
	key, err := c.PrimaryKey(ctx, name)
	if err != nil {
		return Schema{}, err
	}
	inKey := make(map[string]bool, len(key))
	for _, k := range key {
		inKey[k] = true
	}
	for i := range sch.Columns {
		sch.Columns[i].Key = inKey[sch.Columns[i].Name]
	}
```

Add to the sqlite test: describing `comp` reports `Key == true` for exactly `a` and `b`.

- [ ] **Step 7: Run everything and commit**

Run: `make test && make vet && make test-live`

```bash
git add internal/wakilcore cmd
git commit -m "Teach the drivers a table's primary key

Nothing in the stack knew one. Describe returned name and type, and
Column.Key has been declared and unset since Phase 1 — the schema pane
has been drawing an honestly-false column all along.

Both engines answer through a bound parameter: sqlite's pragma_table_info
table-valued form and MySQL's information_schema. So this needs no
identifier quoting at all, which is why information_schema beats SHOW
KEYS — that has nowhere to put a parameter and errors on a missing table
where this returns nothing.

Key order is the engine's, not declaration order: PRIMARY KEY (b, a) on a
table declared (a, b, c) reports b first on both. A view and a keyless
table both report nothing, which is already how 'not editable' is
spelled. A UNIQUE NOT NULL column is not a key and is not reported.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: MySQL learns its backslash mode

**Files:**
- Modify: `internal/wakilcore/driver_mysql.go` (`ConnectWritable`, and a `backslashEscapes` field on `sqlConn`)
- Modify: `internal/wakilcore/sqlconn.go` (the field)
- Test: `internal/wakilcore/driver_mysql_test.go`

**Interfaces:**
- Produces: `sqlConn.backslashEscapes bool` — true when a `\` in a string literal must be doubled. Read once at connect; never inferred later.

**Why.** Measured: `''`-doubling alone stores `C:\path\n` as `C:path` plus a newline on MySQL, with **no error**. `NO_BACKSLASH_ESCAPES` is not in MySQL 8's default `sql_mode`, so this is the ordinary case. And the correct escaper flips with the server's mode, which Wakil does not control — so it is read, not assumed.

- [ ] **Step 1: Write the failing test**

Append to `driver_mysql_test.go`:

```go
func TestMySQLReadsItsBackslashMode(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("WAKIL_MYSQL_DSN not set")
	}
	conn := mustConnectMySQLWritable(t, dsn) // this file's existing helper
	defer conn.Close()
	sc, ok := conn.(*sqlConn)
	if !ok {
		t.Fatalf("expected *sqlConn, got %T", conn)
	}
	// MySQL 8's default sql_mode does NOT include NO_BACKSLASH_ESCAPES,
	// so a backslash IS an escape character and must be doubled.
	if !sc.backslashEscapes {
		t.Fatal("expected backslashEscapes true under MySQL 8's default sql_mode")
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make test-live 2>&1 | grep -A 3 BackslashMode`
Expected: FAIL — `sc.backslashEscapes undefined`.

- [ ] **Step 3: Implement**

In `sqlconn.go`, add to `sqlConn`:

```go
	// backslashEscapes says whether a "\" inside a string literal must be
	// doubled for this connection.
	//
	// **It is a property of the SERVER, not of the dialect**, which is why
	// it is a field and not a constant in the driver. MySQL treats "\" as
	// an escape character unless sql_mode carries NO_BACKSLASH_ESCAPES,
	// and that is a setting Wakil does not own — so ConnectWritable reads
	// it rather than assuming it. Measured: with the default mode and a
	// naive escaper, "C:\path\n" stored as "C:path" plus a newline, no
	// error, against a statement whose text contained the right value.
	//
	// SQLite leaves this false: a backslash is an ordinary character
	// there, and doubling it would store two.
	backslashEscapes bool
```

In `driver_mysql.go`'s `ConnectWritable`, after the successful `PingContext` and before
building the `sqlConn`:

```go
	// One query on a connection that has just answered a ping. It cannot
	// be set behind Wakil's back: hardenMySQLWriteConfig REPLACES
	// cfg.Params wholesale, so no stored DSN can carry a sql_mode and
	// every pooled session sees the same server default.
	backslashEscapes := true
	var mode string
	if err := db.QueryRowContext(ctx, "SELECT @@SESSION.sql_mode").Scan(&mode); err == nil {
		backslashEscapes = !strings.Contains(strings.ToUpper(mode), "NO_BACKSLASH_ESCAPES")
	}
	// A failure to read the mode leaves it true — the default MySQL
	// behaviour, and the direction that escapes MORE rather than less.
```

and set `backslashEscapes: backslashEscapes` in the returned `sqlConn`.

**`Connect` (the read-only path) is deliberately left alone.** Nothing on a read connection
composes a literal.

- [ ] **Step 4: Run and commit**

Run: `make test-live 2>&1 | tail -20`

```bash
git add internal/wakilcore
git commit -m "Read MySQL's backslash mode instead of assuming it

Whether a backslash inside a string literal must be doubled is a property
of the server, not of the dialect: MySQL treats it as an escape character
unless sql_mode carries NO_BACKSLASH_ESCAPES, and that is not in MySQL
8's default mode.

Measured with a naive escaper: C:\\path\\n stored as C:path plus a
newline, no error, against a statement whose text held the right value.
So the write connection asks, once, on a connection that has just
answered a ping. A failed read leaves it true, which escapes more rather
than less.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Per-driver literal quoting

**Files:**
- Modify: `internal/wakilcore/sqlconn.go` (a `quoteLiteral` field, beside `quoteIdent`)
- Modify: `internal/wakilcore/driver_sqlite.go`, `internal/wakilcore/driver_mysql.go`
- Test: `internal/wakilcore/sqlconn_test.go`, `internal/wakilcore/driver_mysql_test.go`

**Interfaces:**
- Produces:
  - `func sqliteQuoteLiteral(s string) (string, error)`
  - `func mysqlQuoteLiteral(s string, backslashEscapes bool) (string, error)`
  - `sqlConn.quoteLiteral func(string) (string, error)` — the connection's own, bound to its mode.

- [ ] **Step 1: Write the failing sqlite test**

Append to `sqlconn_test.go`:

```go
func TestSQLiteQuoteLiteral(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"hello", `'hello'`},
		{"O'Brien", `'O''Brien'`},
		{`C:\path`, `'C:\path'`},  // backslash is ORDINARY in sqlite
		{"", `''`},
		{"x' WHERE 1=1 -- ", `'x'' WHERE 1=1 -- '`},
	} {
		got, err := sqliteQuoteLiteral(tc.in)
		if err != nil {
			t.Fatalf("%q: %v", tc.in, err)
		}
		if got != tc.want {
			t.Fatalf("%q: got %s want %s", tc.in, got, tc.want)
		}
	}
	// A NUL is a syntax error on sqlite — measured: the engine truncates
	// the literal at the NUL and reports an unterminated one.
	if _, err := sqliteQuoteLiteral("a\x00b"); err == nil {
		t.Fatal("expected a NUL to be refused")
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `go test ./internal/wakilcore -run TestSQLiteQuoteLiteral`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement sqlite's**

In `driver_sqlite.go`:

```go
// sqliteQuoteLiteral renders s as a SQLite string literal.
//
// **Doubling the single quote is the whole rule, and a backslash is an
// ORDINARY CHARACTER** — doubling one would store two. That is the
// opposite of MySQL's default, which is exactly why this is a per-driver
// function and not shared code: measured, a dialect-blind escaper stores
// C:\path\n as C:path plus a newline on MySQL with no error.
//
// **A NUL is refused rather than escaped**, because it cannot be
// expressed: measured, the engine truncates the literal at the NUL and
// fails on the unterminated remainder, naming a value nobody typed. This
// is Describe's and ReadTable's NUL rule applied to a value instead of an
// identifier.
func sqliteQuoteLiteral(s string) (string, error) {
	if strings.IndexByte(s, 0) >= 0 {
		return "", UserError("a value cannot contain a NUL byte")
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'", nil
}
```

Set it on the `sqlConn` built by `Connect` and by any writable sqlite path:

```go
		quoteLiteral: sqliteQuoteLiteral,
```

Add the field to `sqlConn` in `sqlconn.go`:

```go
	// quoteLiteral renders a value as a string literal for this dialect
	// and this connection.
	//
	// It returns an error because not every value can be expressed: a NUL
	// is a syntax error on sqlite. It sits beside quoteIdent because it is
	// the same kind of thing — the one guard between caller-controlled
	// text and a statement — and because the probe proved the two dialects
	// disagree about it.
	quoteLiteral func(string) (string, error)
```

- [ ] **Step 4: Write and implement MySQL's**

Append to `driver_mysql_test.go`:

```go
func TestMySQLQuoteLiteral(t *testing.T) {
	for _, tc := range []struct {
		in         string
		escapes    bool
		want       string
	}{
		{"hello", true, `'hello'`},
		{"O'Brien", true, `'O''Brien'`},
		{`C:\path`, true, `'C:\\path'`},
		// Under NO_BACKSLASH_ESCAPES the backslash is literal and must
		// NOT be doubled — doubling would store two.
		{`C:\path`, false, `'C:\path'`},
		{"", true, `''`},
	} {
		got, err := mysqlQuoteLiteral(tc.in, tc.escapes)
		if err != nil {
			t.Fatalf("%q/%v: %v", tc.in, tc.escapes, err)
		}
		if got != tc.want {
			t.Fatalf("%q/%v: got %s want %s", tc.in, tc.escapes, got, tc.want)
		}
	}
}
```

In `driver_mysql.go`:

```go
// mysqlQuoteLiteral renders s as a MySQL string literal.
//
// **Doubling the backslash is conditional on the SERVER'S sql_mode**, read
// at ConnectWritable — see sqlConn.backslashEscapes. Under the default
// mode a backslash is an escape character and must be doubled; under
// NO_BACKSLASH_ESCAPES it is literal and doubling would store two. There
// is no value of this parameter that is right for both.
//
// A NUL needs no special case here: measured, MySQL accepts one inside a
// quoted literal and stores it, unlike sqlite.
func mysqlQuoteLiteral(s string, backslashEscapes bool) (string, error) {
	if backslashEscapes {
		s = strings.ReplaceAll(s, `\`, `\\`)
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'", nil
}
```

In `ConnectWritable`, bind the mode into the field:

```go
		quoteLiteral: func(s string) (string, error) {
			return mysqlQuoteLiteral(s, backslashEscapes)
		},
```

and in `Connect`, bind it the same way with the default `true`.

- [ ] **Step 5: Write the live round-trip test**

This is the test that would have caught the corruption. Append to `driver_mysql_test.go`:

```go
// Every payload written through the composed literal and read back byte
// for byte. The backslash case is the one a naive escaper corrupts
// SILENTLY — it is why this test exists.
func TestMySQLLiteralRoundTrip(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("WAKIL_MYSQL_DSN not set")
	}
	conn := mustConnectMySQLWritable(t, dsn)
	defer conn.Close()
	sc := conn.(*sqlConn)
	exec(t, conn, `DROP TABLE IF EXISTS lit`)
	exec(t, conn, `CREATE TABLE lit (id INT PRIMARY KEY, v VARBINARY(200))`)
	for _, payload := range []string{
		"hello", "O'Brien", `C:\path\n`, "a\nb", "a\tb", "100%_x",
		"café 🚀", "", "a\x00b", "x' WHERE 1=1 -- ", `say "hi"`, "a`b",
	} {
		exec(t, conn, `DELETE FROM lit`)
		exec(t, conn, `INSERT INTO lit VALUES (1, 'seed')`)
		lit, err := sc.quoteLiteral(payload)
		if err != nil {
			t.Fatalf("%q: %v", payload, err)
		}
		exec(t, conn, `UPDATE lit SET v = `+lit+` WHERE id = 1`)
		var back []byte
		if err := sc.db.QueryRow(`SELECT v FROM lit WHERE id = 1`).Scan(&back); err != nil {
			t.Fatalf("%q: %v", payload, err)
		}
		if string(back) != payload {
			t.Fatalf("%q round-tripped as %q", payload, string(back))
		}
	}
}
```

Write the sqlite equivalent in `sqlconn_test.go` over a `TEXT` column, with the NUL
payload removed and asserted refused instead.

- [ ] **Step 6: Run and commit**

Run: `make test && make test-live && make vet`

```bash
git add internal/wakilcore
git commit -m "Render a value as a literal, per driver

Escaping sits beside quoteIdent because it is the same kind of thing and
because the two dialects disagree about it. SQLite doubles the quote and
treats a backslash as an ordinary character; MySQL doubles both, unless
the server's sql_mode says otherwise.

A NUL is refused on sqlite rather than escaped: the engine truncates the
literal at it and fails on the unterminated remainder, naming a value
nobody typed. That is Describe's NUL rule applied to a value instead of
an identifier. MySQL stores one happily and needs no case.

Twelve payloads round-trip byte for byte against a live server, including
the backslash that a dialect-blind escaper corrupts with no error at all.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: The one-named-table recogniser

**Files:**
- Create: `internal/wakilcore/editable.go`
- Test: `internal/wakilcore/editable_test.go`

**Interfaces:**
- Produces:
  ```go
  // SQLReadSingleTable reports the one table a read's rows came from, and
  // the result columns that are plain references to its columns.
  // Returns ("", nil) when it cannot prove both.
  func SQLReadSingleTable(sql string) (table string, plainColumns []string)
  ```
  `plainColumns` is `nil` for `SELECT *` — meaning "every result column is plain" — and
  the explicit list otherwise. The caller (Task 5) intersects it with the actual result
  columns.

- [ ] **Step 1: Write the failing fixture test**

Create `internal/wakilcore/editable_test.go` with the probe's nineteen shapes:

```go
package wakilcore

import "testing"

func TestSQLReadSingleTable(t *testing.T) {
	for _, tc := range []struct {
		name  string
		sql   string
		table string
	}{
		{"plain star", `SELECT * FROM events`, "events"},
		{"alias", `SELECT * FROM events e`, "events"},
		{"alias with AS", `SELECT e.* FROM events AS e`, "events"},
		{"quoted name", `SELECT * FROM "events"`, "events"},
		{"backticked name", "SELECT * FROM `events`", "events"},
		{"trailing semicolon", `SELECT * FROM events;`, "events"},
		{"comment before FROM", `SELECT * FROM /*x*/ events`, "events"},
		{"named columns", `SELECT id, kind FROM events`, "events"},
		{"where and order and limit", `SELECT id FROM events WHERE id > 1 ORDER BY id LIMIT 5`, "events"},
		{"subquery in WHERE is fine", `SELECT id FROM events WHERE id IN (SELECT id FROM users)`, "events"},

		{"aliased column", `SELECT id AS ident FROM events`, ""},
		{"expression column", `SELECT id, kind || '!' AS kind FROM events`, ""},
		{"duplicate column", `SELECT id, id FROM events`, ""},
		{"CTE shadowing a table", `WITH events AS (SELECT 1 AS id) SELECT * FROM events`, ""},
		{"join", `SELECT * FROM events JOIN users ON users.id = events.id`, ""},
		{"comma join", `SELECT * FROM events, users`, ""},
		{"subquery in FROM", `SELECT * FROM (SELECT id FROM events) x`, ""},
		{"distinct", `SELECT DISTINCT kind FROM events`, ""},
		{"group by", `SELECT kind, count(*) n FROM events GROUP BY kind`, ""},
		{"union", `SELECT id FROM events UNION SELECT id FROM users`, ""},
		{"window function", `SELECT id, row_number() OVER () rn FROM events`, ""},
		{"values", `SELECT * FROM (VALUES (1,2))`, ""},
		{"qualified name", `SELECT * FROM otherdb.events`, ""},
		{"not a select", `SHOW TABLES`, ""},
		{"explain", `EXPLAIN SELECT * FROM events`, ""},
		{"empty", ``, ""},
	} {
		got, _ := SQLReadSingleTable(tc.sql)
		if got != tc.table {
			t.Errorf("%s: got %q want %q", tc.name, got, tc.table)
		}
	}
}

// SELECT * means "every result column is plain"; a named list is returned
// so the caller can intersect it with the columns that actually came back.
func TestSQLReadSingleTablePlainColumns(t *testing.T) {
	if _, cols := SQLReadSingleTable(`SELECT * FROM events`); cols != nil {
		t.Errorf("SELECT * should report nil columns, got %v", cols)
	}
	_, cols := SQLReadSingleTable(`SELECT id, kind FROM events`)
	if len(cols) != 2 || cols[0] != "id" || cols[1] != "kind" {
		t.Errorf("got %v", cols)
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `go test ./internal/wakilcore -run TestSQLReadSingleTable`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

Create `internal/wakilcore/editable.go`. The doc comment carries the two traps, because
they are the reason the refusals are not tidiness:

```go
package wakilcore

import (
	"regexp"
	"strings"
)

// SQLReadSingleTable reports the one table a read's rows came from, and
// which result columns are plain references to that table's columns.
//
// It exists so that a cell can be written back through a WHERE clause that
// names exactly one row. Where it cannot PROVE both facts it answers
// nothing, and the surface stays read-only — which is the failure
// direction this must always prefer.
//
// THE ACCEPTED SHAPE, and nothing else:
//
//	SELECT, with no DISTINCT, of * / <alias>.* / a list of bare
//	identifiers, FROM exactly one unqualified table name with an optional
//	alias, followed by nothing but WHERE / ORDER BY / LIMIT / OFFSET.
//
// TWO OF THE REFUSALS ARE NOT TIDINESS, and both were measured.
//
// A CTE that shadows a table name produces a well-formed, confirmable
// UPDATE against the wrong data:
//
//	WITH events AS (SELECT 1 AS id, 'z' AS kind) SELECT * FROM events
//
// returns columns named id and kind. A recogniser that read the last
// "FROM <name>" would call this table events, look up the REAL events'
// primary key, find id, and declare the result editable — and the
// operator's edit would write to the real events table, to a row that was
// never on screen. Any WITH token refuses the whole statement; a CTE
// cannot appear in a statement this would otherwise accept.
//
// An expression aliased back to its own source name is the quiet one:
//
//	SELECT id, kind || '!' AS kind FROM events
//
// produces a result column named kind that is NOT the table's kind.
// Editing it would compose SET kind = ... against the real column, so the
// operator edits a derived value and silently overwrites its source.
// Requiring every selected item to be a bare identifier stops it, and is
// the same rule that drops SELECT id AS ident.
//
// A subquery in the WHERE clause is NOT refused and does not need to be:
// the rows still come from the one named table, and its key still
// identifies them.
//
// A qualified name IS refused, because the key lookup is scoped to the
// connection's own database — measured, a bare-name lookup answers the
// current schema's key for a name that pointed at another schema's table.
//
// It reads SQL, which only readonly.go otherwise does, and it shares that
// file's stripSQLComments deliberately: that scanner is hardened across
// five documented bypasses, and a second comment-stripper would be a
// second thing to get wrong.
func SQLReadSingleTable(sql string) (string, []string) {
	clean := strings.TrimSpace(stripSQLComments(sql))
	clean = strings.TrimRight(clean, "; \t\n")
	if clean == "" {
		return "", nil
	}
	upper := strings.ToUpper(clean)
	// A single refusal list, checked on word boundaries so a column named
	// "union_id" or a table named "distinct_values" is not caught by it.
	for _, word := range []string{
		"WITH", "JOIN", "DISTINCT", "GROUP", "HAVING",
		"UNION", "INTERSECT", "EXCEPT", "OVER",
	} {
		if wordBoundary(word).MatchString(upper) {
			return "", nil
		}
	}
	if !strings.HasPrefix(upper, "SELECT") {
		return "", nil
	}
	fromAt := wordBoundary("FROM").FindStringIndex(upper)
	if fromAt == nil {
		return "", nil
	}
	items := strings.TrimSpace(clean[len("SELECT"):fromAt[0]])
	columns, ok := plainSelectItems(items)
	if !ok {
		return "", nil
	}
	// The FROM clause runs to the first of WHERE / ORDER / LIMIT / OFFSET,
	// or to the end.
	rest := clean[fromAt[1]:]
	end := len(rest)
	for _, word := range []string{"WHERE", "ORDER", "LIMIT", "OFFSET"} {
		if at := wordBoundary(word).FindStringIndex(strings.ToUpper(rest)); at != nil && at[0] < end {
			end = at[0]
		}
	}
	table, ok := singleTableName(strings.TrimSpace(rest[:end]))
	if !ok {
		return "", nil
	}
	return table, columns
}

var boundaryCache = map[string]*regexp.Regexp{}

func wordBoundary(word string) *regexp.Regexp {
	if re, ok := boundaryCache[word]; ok {
		return re
	}
	re := regexp.MustCompile(`\b` + word + `\b`)
	boundaryCache[word] = re
	return re
}

// bareIdent is a single unquoted SQL identifier and nothing else: no dot,
// no parenthesis, no operator, no space.
var bareIdent = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_$]*$`)

// plainSelectItems returns the selected column names, or ok=false if any
// item is not a bare identifier. A "*" (or "<alias>.*") yields nil
// columns, meaning "all of them, and all of them are plain".
func plainSelectItems(items string) ([]string, bool) {
	if items == "*" {
		return nil, true
	}
	if strings.HasSuffix(items, ".*") && bareIdent.MatchString(strings.TrimSuffix(items, ".*")) {
		return nil, true
	}
	parts := strings.Split(items, ",")
	out := make([]string, 0, len(parts))
	seen := map[string]bool{}
	for _, part := range parts {
		name := strings.TrimSpace(part)
		if !bareIdent.MatchString(name) {
			return nil, false
		}
		// A duplicate result name has no single column to write to.
		if seen[strings.ToLower(name)] {
			return nil, false
		}
		seen[strings.ToLower(name)] = true
		out = append(out, name)
	}
	if len(out) == 0 {
		return nil, false
	}
	return out, true
}

// singleTableName accepts "t", "t a", "t AS a", and the quoted forms of
// the name. Anything else — a comma, a parenthesis, a dot, more than two
// words after the alias keyword — is not one table.
func singleTableName(clause string) (string, bool) {
	if clause == "" || strings.ContainsAny(clause, ",()") {
		return "", false
	}
	fields := strings.Fields(clause)
	if len(fields) == 0 {
		return "", false
	}
	// "t a" is two fields, "t AS a" is three; anything longer is not a
	// single aliased table.
	if len(fields) == 3 && !strings.EqualFold(fields[1], "AS") {
		return "", false
	}
	if len(fields) > 3 {
		return "", false
	}
	name := unquoteIdent(fields[0])
	// A dot survives unquoting only on a qualified name, which is refused.
	if !bareIdent.MatchString(name) {
		return "", false
	}
	return name, true
}

// unquoteIdent strips one layer of "..." or `...` and undoubles any
// embedded quote character, matching how each engine reads one.
func unquoteIdent(s string) string {
	if len(s) >= 2 {
		switch s[0] {
		case '"':
			if s[len(s)-1] == '"' {
				return strings.ReplaceAll(s[1:len(s)-1], `""`, `"`)
			}
		case '`':
			if s[len(s)-1] == '`' {
				return strings.ReplaceAll(s[1:len(s)-1], "``", "`")
			}
		}
	}
	return s
}
```

- [ ] **Step 4: Run the fixtures**

Run: `go test ./internal/wakilcore -run TestSQLReadSingleTable -v`
Expected: PASS, all 26 cases.

**If a case fails, fix the recogniser, never the fixture.** Each fixture is a measured
engine behaviour from the probe, not a preference.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/editable.go internal/wakilcore/editable_test.go
git commit -m "Recognise a read whose rows came from exactly one table

It answers nothing wherever it cannot prove both the table and that every
result column is a plain reference to one of its columns — the failure
direction this has to prefer.

Two of the refusals are not tidiness. A CTE shadowing a table name
returns columns that look like the table's, so a recogniser reading the
last FROM would look up the real table's key and let an operator edit a
row that came from a literal in their own WITH clause — writing to the
real table, to a row never on screen. And an expression aliased back to
its source name produces a result column that is not the table's column,
so editing it silently overwrites what it was derived from.

A subquery in the WHERE clause is fine and is not refused: the rows still
come from the one table and its key still identifies them.

Shares readonly.go's comment stripper rather than growing a second one.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `Rows.Editable`

**Files:**
- Modify: `internal/wakilcore/dbdriver.go` (the `Editable` type, a field on `Rows`)
- Modify: `internal/wakilcore/sqlconn.go` (`Read` and `ReadTable` populate it)
- Test: `internal/wakilcore/sqlconn_test.go`

**Interfaces:**
- Consumes: `SQLReadSingleTable` (Task 4), `Conn.PrimaryKey` (Task 1), `sqlConn.quoteLiteral` (Task 3).
- Produces:
  ```go
  type Editable struct {
      Table      string   `json:"table"`
      KeyColumns []string `json:"keyColumns"`
      RowKeys    []string `json:"rowKeys"`
      Columns    []string `json:"columns"`
  }
  ```
  and `Rows.Editable *Editable` — `nil` on every result that is not editable.

- [ ] **Step 1: Write the failing test**

Append to `sqlconn_test.go`:

```go
func TestReadReportsEditability(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT, note TEXT)`,
		`INSERT INTO events VALUES (1,'a','x'), (2,'b','y')`,
		`CREATE TABLE nopk (x INT)`,
		`INSERT INTO nopk VALUES (1)`,
		`CREATE TABLE comp (a INT, b TEXT, v TEXT, PRIMARY KEY (b, a))`,
		`INSERT INTO comp VALUES (7,'k','v')`,
	})
	ctx := context.Background()

	out, err := conn.Read(ctx, QuerySpec{Raw: `SELECT * FROM events`}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if out.Editable == nil {
		t.Fatal("SELECT * FROM events should be editable")
	}
	if out.Editable.Table != "events" {
		t.Fatalf("table = %q", out.Editable.Table)
	}
	if len(out.Editable.KeyColumns) != 1 || out.Editable.KeyColumns[0] != "id" {
		t.Fatalf("key = %v", out.Editable.KeyColumns)
	}
	// The key columns are NOT writable — editing a key changes the row's
	// identity and invalidates every key the pane is holding.
	if len(out.Editable.Columns) != 2 {
		t.Fatalf("columns = %v", out.Editable.Columns)
	}
	if len(out.Editable.RowKeys) != 2 {
		t.Fatalf("rowKeys = %v", out.Editable.RowKeys)
	}
	if out.Editable.RowKeys[0] != `"id" = '1'` {
		t.Fatalf("rowKey[0] = %q", out.Editable.RowKeys[0])
	}

	// A composite key names both columns, in the engine's key order.
	out, err = conn.Read(ctx, QuerySpec{Raw: `SELECT * FROM comp`}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if out.Editable == nil || out.Editable.RowKeys[0] != `"b" = 'k' AND "a" = '7'` {
		t.Fatalf("composite rowKey = %#v", out.Editable)
	}

	// Not editable, four ways.
	for _, sql := range []string{
		`SELECT * FROM nopk`,                         // no key
		`SELECT kind FROM events`,                    // key not in result
		`SELECT * FROM events JOIN nopk ON 1=1`,      // more than one table
		`SELECT id, kind || '!' AS kind FROM events`, // derived column
	} {
		out, err := conn.Read(ctx, QuerySpec{Raw: sql}, 10)
		if err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		if out.Editable != nil {
			t.Errorf("%s should not be editable, got %#v", sql, out.Editable)
		}
	}
}

func TestReadTableIsEditableByConstruction(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT)`,
		`INSERT INTO events VALUES (1,'a')`,
	})
	out, err := conn.ReadTable(context.Background(), "events", 10, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if out.Editable == nil || out.Editable.Table != "events" {
		t.Fatalf("read_table should be editable: %#v", out.Editable)
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `go test ./internal/wakilcore -run 'TestRead(ReportsEditability|TableIsEditable)'`
Expected: FAIL — `out.Editable undefined`.

- [ ] **Step 3: Implement**

In `dbdriver.go`, beside `Rows`:

```go
// Editable is what a result reports about being written back to.
//
// nil means "not editable", and that is the answer wherever a single row
// cannot be named: a join, an aggregate, a view, a keyless table, a
// derived column, or a SELECT that omitted the key. A result grid holds
// the rows of a QUERY, not the rows of a TABLE, and inventing a WHERE
// clause for one is how a tool updates the wrong row — or every row.
type Editable struct {
	// Table is the single unqualified table the rows came from.
	Table string `json:"table"`
	// KeyColumns is its primary key, in the engine's key order.
	KeyColumns []string `json:"keyColumns"`
	// RowKeys is positionally aligned with Rows.Rows: the rendered,
	// dialect-escaped WHERE predicate naming that one row.
	//
	// **Rendered HERE, at read time, from the values the engine
	// returned** — which is the whole answer to a problem one layer up.
	// Swift's JSONValue held numbers as Double, so a key above 2^53
	// arrived rounded and an UPDATE composed from it named a different
	// row. A predicate is text; it crosses unchanged.
	//
	// It also describes the row AS IT WAS READ. If someone else changed
	// that row in between, the UPDATE matches nothing and says so, rather
	// than stamping over a change nobody saw.
	RowKeys []string `json:"rowKeys"`
	// Columns are the result columns that may be written to: every plain
	// reference to a column of Table, minus the key columns.
	//
	// Key columns are excluded deliberately. Changing a key is a
	// legitimate thing to want and a bad thing to do by double-click: it
	// changes the row's identity, which makes every RowKey the pane holds
	// — including the one the edit was composed from — describe a row that
	// no longer exists. The query line remains its route.
	Columns []string `json:"columns"`
}
```

and on `Rows`:

```go
	// Editable is nil unless this result's rows can each be named by a
	// WHERE clause. See the type.
	Editable *Editable `json:"editable,omitempty"`
```

In `sqlconn.go`, one shared helper, called by both `Read` and `ReadTable`:

```go
// describeEditability builds out.Editable, or leaves it nil.
//
// It never returns an error: a result that cannot be proven editable is a
// read-only result, not a failed read. A key lookup that fails for its own
// reasons costs the operator an editing affordance, never their rows.
func (c *sqlConn) describeEditability(ctx context.Context, out *Rows, table string, plain []string) {
	if table == "" || c.quoteLiteral == nil {
		return
	}
	key, err := c.PrimaryKey(ctx, table)
	if err != nil || len(key) == 0 {
		return
	}
	// Every key column must be present in the result UNDER ITS OWN NAME.
	index := make(map[string]int, len(out.Columns))
	for i, name := range out.Columns {
		if _, seen := index[name]; seen {
			// A duplicate result column name has no single column to
			// write to; the recogniser refuses this for a named list, and
			// this covers the SELECT * case where two columns collide.
			return
		}
		index[name] = i
	}
	keyAt := make([]int, 0, len(key))
	for _, name := range key {
		at, ok := index[name]
		if !ok {
			return
		}
		keyAt = append(keyAt, at)
	}

	// Which columns may be written to: every plain one, minus the key.
	inKey := make(map[string]bool, len(key))
	for _, name := range key {
		inKey[name] = true
	}
	allowed := plain
	if allowed == nil {
		// SELECT * — every result column is plain.
		allowed = out.Columns
	}
	writable := make([]string, 0, len(allowed))
	for _, name := range allowed {
		if !inKey[name] {
			writable = append(writable, name)
		}
	}
	if len(writable) == 0 {
		return
	}

	rowKeys := make([]string, 0, len(out.Rows))
	for _, row := range out.Rows {
		var b strings.Builder
		for i, at := range keyAt {
			if at >= len(row) {
				return
			}
			lit, err := c.literalFor(row[at])
			if err != nil {
				return
			}
			if i > 0 {
				b.WriteString(" AND ")
			}
			b.WriteString(c.quoteIdent(key[i]))
			b.WriteString(" = ")
			b.WriteString(lit)
		}
		rowKeys = append(rowKeys, b.String())
	}
	out.Editable = &Editable{
		Table: table, KeyColumns: key, RowKeys: rowKeys, Columns: writable,
	}
}

// literalFor renders one scanned value as a literal.
//
// collectRows has already turned every []byte into a string, so the cases
// here are what database/sql hands back for the rest. A NULL key is
// refused: "IS NULL" would not name one row, and a nullable primary key
// does not exist on either engine anyway.
func (c *sqlConn) literalFor(v any) (string, error) {
	switch value := v.(type) {
	case nil:
		return "", UserError("a key column cannot be NULL")
	case string:
		return c.quoteLiteral(value)
	case int64:
		return strconv.FormatInt(value, 10), nil
	case float64:
		return strconv.FormatFloat(value, 'g', -1, 64), nil
	case bool:
		if value {
			return "1", nil
		}
		return "0", nil
	case time.Time:
		return c.quoteLiteral(value.Format("2006-01-02 15:04:05"))
	default:
		return c.quoteLiteral(fmt.Sprint(value))
	}
}
```

**An `int64` and a `float64` are emitted BARE here and that is correct** — unlike a typed
value (Task 6), these are not operator text. They came out of the engine as numbers, they
are being compared rather than assigned, and a quoted numeric literal in a `WHERE` would
make MySQL compare a string to an int.

Call it at the end of `Read`, after `out.ListsTables` is set:

```go
	table, plain := SQLReadSingleTable(spec.Raw)
	c.describeEditability(ctx, &out, table, plain)
```

and at the end of `ReadTable`, after `out.Pageable = true`:

```go
	// A table read names its table by construction and selects every
	// column, so there is no statement to recognise.
	c.describeEditability(ctx, &out, name, nil)
```

Add `strconv`, `time` and `fmt` to `sqlconn.go`'s imports if absent.

- [ ] **Step 4: Run and iterate**

Run: `go test ./internal/wakilcore -run 'TestRead(ReportsEditability|TableIsEditable)' -v`
Expected: PASS.

- [ ] **Step 5: Run the whole Go suite and commit**

Run: `make test && make vet && make test-live`

```bash
git add internal/wakilcore
git commit -m "Report, per read, whether its rows can be written back

A result grid holds the rows of a query, not the rows of a table, so the
driver says which of the two it just produced — and where it cannot prove
a single row can be named, it says nothing and the surface stays
read-only.

The per-row WHERE predicate is rendered here, at read time, from the
values the engine returned. That is deliberate and load-bearing: a key
above 2^53 could not survive the trip through Swift as a number, and a
predicate is text. It also describes the row as it was read, so an edit
racing someone else's change matches nothing and says so rather than
stamping over it.

Key columns are not writable. Editing a key changes the row's identity
and invalidates every key the pane is holding, including the one the edit
was composed from.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Compose the `UPDATE`

**Files:**
- Create: `internal/wakilcore/updatestmt.go`
- Test: `internal/wakilcore/updatestmt_test.go`

**Interfaces:**
- Consumes: `sqlConn.quoteIdent`, `sqlConn.quoteLiteral`.
- Produces:
  ```go
  // RenderUpdate composes one UPDATE from a cell edit. It runs nothing.
  func (c *sqlConn) RenderUpdate(table, rowKey, column, columnType, value string) (string, error)
  ```

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/updatestmt_test.go`:

```go
package wakilcore

import "strings"
import "testing"

func TestRenderUpdate(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}

	// Every value is QUOTED, including a numeric column's. A bare literal
	// is a COLUMN REFERENCE on both engines and both take it silently:
	// SET name = secret stored the secret, no error. That is the failure
	// this rule exists against.
	got, err := c.RenderUpdate("events", `"id" = '1'`, "kind", "TEXT", "b")
	if err != nil {
		t.Fatal(err)
	}
	want := `UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'`
	if got != want {
		t.Fatalf("got %s want %s", got, want)
	}

	got, _ = c.RenderUpdate("events", `"id" = '1'`, "n", "INTEGER", "42")
	if got != `UPDATE "events" SET "n" = '42' WHERE "id" = '1'` {
		t.Fatalf("a numeric column's value is quoted too, got %s", got)
	}

	// A leading "=" is the operator asking for SQL. It passes through
	// verbatim: unquoted, unescaped, unvalidated.
	got, _ = c.RenderUpdate("events", `"id" = '1'`, "ts", "DATETIME", "=NOW()")
	if got != `UPDATE "events" SET "ts" = NOW() WHERE "id" = '1'` {
		t.Fatalf("got %s", got)
	}
	got, _ = c.RenderUpdate("events", `"id" = '1'`, "kind", "TEXT", "=NULL")
	if got != `UPDATE "events" SET "kind" = NULL WHERE "id" = '1'` {
		t.Fatalf("got %s", got)
	}

	// An empty field is the empty string, NOT null. The grid draws the
	// two differently and this keeps the distinction writable.
	got, _ = c.RenderUpdate("events", `"id" = '1'`, "kind", "TEXT", "")
	if got != `UPDATE "events" SET "kind" = '' WHERE "id" = '1'` {
		t.Fatalf("got %s", got)
	}

	// Quoting is applied, so a quote in a value cannot end the literal.
	got, _ = c.RenderUpdate("events", `"id" = '1'`, "kind", "TEXT", "x' WHERE 1=1 -- ")
	if !strings.Contains(got, `'x'' WHERE 1=1 -- '`) {
		t.Fatalf("got %s", got)
	}
}

// sqlite stores "abc" in an INTEGER column AS TEXT, silently; MySQL
// refuses it with an engine error. Validating first gives both engines
// the same behaviour and gives the operator a sentence rather than an
// error code.
func TestRenderUpdateValidatesNumericColumns(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}
	for _, typ := range []string{"INTEGER", "INT", "BIGINT", "DECIMAL", "NUMERIC", "REAL", "DOUBLE", "FLOAT"} {
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, "abc"); err == nil {
			t.Errorf("%s should refuse abc", typ)
		}
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, "42"); err != nil {
			t.Errorf("%s should accept 42: %v", typ, err)
		}
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, " 8 "); err != nil {
			t.Errorf("%s should accept a padded number: %v", typ, err)
		}
		// An expression is never validated — it is not a value.
		if _, err := c.RenderUpdate("t", `"id" = '1'`, "n", typ, "=n + 1"); err != nil {
			t.Errorf("%s should accept an expression: %v", typ, err)
		}
	}
	// A BIT column cannot be expressed as a quoted literal at all.
	if _, err := c.RenderUpdate("t", `"id" = '1'`, "b", "BIT", "1"); err == nil {
		t.Error("BIT should be refused")
	}
}

func TestRenderUpdateRefusesEmptyParts(t *testing.T) {
	c := &sqlConn{quoteIdent: sqliteQuoteIdent, quoteLiteral: sqliteQuoteLiteral}
	for _, tc := range []struct{ table, key, column string }{
		{"", `"id" = '1'`, "kind"},
		{"events", "", "kind"},
		{"events", `"id" = '1'`, ""},
	} {
		if _, err := c.RenderUpdate(tc.table, tc.key, tc.column, "TEXT", "x"); err == nil {
			t.Errorf("%#v should be refused", tc)
		}
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `go test ./internal/wakilcore -run TestRenderUpdate`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

Create `internal/wakilcore/updatestmt.go`:

```go
package wakilcore

import (
	"strconv"
	"strings"
)

// ExpressionPrefix marks a typed cell value as SQL rather than as a value.
//
// The spreadsheet convention, and it is a convention rather than a guess:
// inferring "NOW() looks like a function" from the text is exactly the
// kind of guess the chip rule and the drill rule already refuse, and it
// would make a name column holding "Doe(x)" into a function call.
const ExpressionPrefix = "="

// numericTypePrefixes are the declared type names whose values must parse
// as numbers before a statement is composed.
//
// **Validation, NOT quoting.** Everything is quoted (see RenderUpdate);
// this list decides only what is REFUSED. It exists because the two
// engines disagree about a wrong value: measured, sqlite's type affinity
// stores 'abc' in an INTEGER column as TEXT and says nothing — a cell that
// read 7 now reads abc, and the next numeric comparison against that
// column quietly stops working — while MySQL under STRICT_TRANS_TABLES
// refuses it with Error 1366. One sentence the operator can read beats two
// engine behaviours.
//
// Matched as a PREFIX, case-insensitively, so DECIMAL(10,2), INT UNSIGNED
// and NUMERIC(8) are all covered by their stems.
var numericTypePrefixes = []string{
	"INT", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT",
	"DECIMAL", "NUMERIC", "REAL", "DOUBLE", "FLOAT",
}

// uneditableTypePrefixes are the declared types no quoted literal can
// express. BIT is the only one either engine has: measured, a quoted
// literal into BIT(1) is Error 1406 "Data too long", while a bare one
// works — and a bare literal is a column reference, which is the one thing
// this surface must never emit. The query line remains its route.
var uneditableTypePrefixes = []string{"BIT"}

// RenderUpdate composes one UPDATE from a cell edit, and runs nothing.
//
// **Every value is quoted, and that is the probe's most important
// result.** A bare literal is a COLUMN REFERENCE on both engines, and both
// take it silently:
//
//	UPDATE tt SET name = secret WHERE id = 1
//	  sqlite: name = "hunter2", no error
//	  mysql:  name = "hunter2", no error
//
// So a cell holding the word "active", "count", "status" or "id" would not
// store that word — it would copy another column of the same row, with no
// warning, behind a confirmation plane showing a statement that reads
// perfectly well. Quoting costs nothing: '42' into an INT stores 42 and
// '9.99' into a DECIMAL(10,2) stores 9.99, measured on both.
//
// rowKey is a predicate the DRIVER rendered at read time (Rows.Editable)
// and is interpolated unmodified. Nothing outside this package composes
// one, and nothing anywhere parses one.
func (c *sqlConn) RenderUpdate(table, rowKey, column, columnType, value string) (string, error) {
	if strings.TrimSpace(table) == "" {
		return "", UserError("no table to update")
	}
	if strings.TrimSpace(rowKey) == "" {
		return "", UserError("no row to update")
	}
	if strings.TrimSpace(column) == "" {
		return "", UserError("no column to update")
	}
	if hasTypePrefix(columnType, uneditableTypePrefixes) {
		return "", UserError(
			"a " + columnType + " column cannot be edited in the grid; use the query line")
	}

	var assigned string
	if expression, ok := strings.CutPrefix(value, ExpressionPrefix); ok {
		// Not a value: the operator asked for SQL in so many words. It is
		// neither escaped nor validated, and it is still composed into ONE
		// statement that passes AssertSQLMutation, is shown whole in the
		// confirmation plane, and needs a typed confirmation. That is the
		// same authority the query line has given them since 2c-ii,
		// reached by a shorter route.
		if strings.TrimSpace(expression) == "" {
			return "", UserError("an expression cannot be empty")
		}
		assigned = expression
	} else {
		if hasTypePrefix(columnType, numericTypePrefixes) {
			if _, err := strconv.ParseFloat(strings.TrimSpace(value), 64); err != nil {
				return "", UserError(
					"\"" + value + "\" is not a number, and " + column + " is a " +
						columnType + " column")
			}
		}
		literal, err := c.quoteLiteral(value)
		if err != nil {
			return "", err
		}
		assigned = literal
	}

	return "UPDATE " + c.quoteIdent(table) +
		" SET " + c.quoteIdent(column) + " = " + assigned +
		" WHERE " + rowKey, nil
}

func hasTypePrefix(columnType string, prefixes []string) bool {
	upper := strings.ToUpper(strings.TrimSpace(columnType))
	for _, prefix := range prefixes {
		if strings.HasPrefix(upper, prefix) {
			return true
		}
	}
	return false
}
```

- [ ] **Step 4: Run and commit**

Run: `go test ./internal/wakilcore -run TestRenderUpdate -v && make test && make vet`

```bash
git add internal/wakilcore/updatestmt.go internal/wakilcore/updatestmt_test.go
git commit -m "Compose one UPDATE from a cell edit, and run nothing

Every value is quoted, including a numeric column's, because a bare
literal is a column reference on both engines and both take it silently:
SET name = secret stored the secret with no error. A cell holding the
word 'status' would copy another column behind a plane showing a
statement that reads perfectly well. Quoting costs nothing — '42' into an
INT stores 42.

The column type validates instead. sqlite stores 'abc' in an INTEGER
column as text and says nothing; MySQL refuses it with an error code. One
sentence the operator can read beats two engine behaviours.

A leading = is the operator asking for SQL: NOW(), NULL, price * 1.1 pass
through unescaped and unvalidated. They are still one statement, still
gated, still shown whole and still confirmed by hand.

BIT is the one type a quoted literal cannot express, so it is refused
here and stays with the query line.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: The `render_update` tool

**Files:**
- Modify: `cmd/wakil-db/main.go` (an arg struct, a result struct, the tool)
- Test: `cmd/wakil-db/main_test.go`

**Interfaces:**
- Produces: MCP tool `render_update`, arguments `{database?, table, rowKey, column, columnType, value}`, result `{statement}`.

- [ ] **Step 1: Add the arg and result types**

In `cmd/wakil-db/main.go`, beside the other `*Arg` structs:

```go
type renderUpdateArg struct {
	Database   string `json:"database,omitempty"`
	Table      string `json:"table"`
	RowKey     string `json:"rowKey"`
	Column     string `json:"column"`
	ColumnType string `json:"columnType,omitempty"`
	Value      string `json:"value"`
}

// RenderedUpdate wraps the composed statement, for the reason
// ContainerList and DatabaseList wrap theirs: MCP requires a tool result's
// structuredContent to be a JSON OBJECT.
type RenderedUpdate struct {
	Statement string `json:"statement"`
}
```

- [ ] **Step 2: Register the tool**

After `read_table`'s registration:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "render_update", Description: "Compose the UPDATE that writes one cell back, and return it WITHOUT running it. rowKey must be a value that came from a query or read_table result's editable.rowKeys — it is the driver's own rendering of the WHERE clause naming one row, and composing one yourself is how a tool updates the wrong row. value is a literal unless it begins with \"=\", which passes the rest through as SQL (\"=NOW()\", \"=NULL\"). Every literal is quoted and escaped for the dialect; a value for a numeric column must parse as a number. This runs nothing: pass the statement it returns to mutate, which still requires the write gate and a human confirmation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a renderUpdateArg) (*mcp.CallToolResult, RenderedUpdate, error) {
			// Writable, because the escaping depends on the WRITE
			// connection's own sql_mode (see sqlConn.backslashEscapes) —
			// composing against the read connection's could quote a
			// backslash for the wrong mode and silently store the wrong
			// value.
			conn, err := openPickedWritable(ctx, a.Database)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), RenderedUpdate{}, nil
			}
			defer conn.Close()
			sc, ok := conn.(interface {
				RenderUpdate(table, rowKey, column, columnType, value string) (string, error)
			})
			if !ok {
				return mcpx.ToolErr("wakil-db",
					wakilcore.UserError("this database cannot compose an update")),
					RenderedUpdate{}, nil
			}
			statement, err := sc.RenderUpdate(a.Table, a.RowKey, a.Column, a.ColumnType, a.Value)
			if err != nil {
				return mcpx.ToolErr("wakil-db", err), RenderedUpdate{}, nil
			}
			return nil, RenderedUpdate{Statement: statement}, nil
		})
```

**The interface assertion rather than a `*sqlConn` type assertion** keeps `mongoConn` out
without importing the concrete type, and makes "this database cannot compose an update"
the honest answer for Mongo rather than a panic.

- [ ] **Step 3: Test it**

Append to `cmd/wakil-db/main_test.go`. That file already has a fixture that builds a
project with a sqlite database and calls a tool by name — find it (`grep -n "func Test" cmd/wakil-db/main_test.go`
and read the closest `query` or `mutate` test) and reuse it rather than building a second
one. The test body, in full:

```go
func TestRenderUpdateComposesAndRunsNothing(t *testing.T) {
	// Build the same project/env/database fixture the query and mutate
	// tests use, with a writeRef configured — render_update opens the
	// WRITABLE connection, so a database without one must fail here the
	// same way mutate does.
	env := newDBFixture(t, []string{
		`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT)`,
		`INSERT INTO events VALUES (1, 'a')`,
	})

	out := callTool(t, env, "render_update", map[string]any{
		"table":      "events",
		"rowKey":     `"id" = '1'`,
		"column":     "kind",
		"columnType": "TEXT",
		"value":      "b",
	})
	got := structured(t, out)["statement"]
	want := `UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'`
	if got != want {
		t.Fatalf("got %v want %s", got, want)
	}

	// IT RAN NOTHING. This is the whole contract: the statement goes to
	// mutate, which is where the gate, the production block and the human
	// confirmation are.
	var kind string
	if err := env.db.QueryRow(`SELECT kind FROM events WHERE id = 1`).Scan(&kind); err != nil {
		t.Fatal(err)
	}
	if kind != "a" {
		t.Fatalf("render_update changed the row: kind = %q", kind)
	}

	// A refusal comes back as a tool error carrying the gate's own
	// sentence, not as a composed statement.
	out = callTool(t, env, "render_update", map[string]any{
		"table": "events", "rowKey": `"id" = '1'`, "column": "id",
		"columnType": "INTEGER", "value": "abc",
	})
	if !isToolError(out) {
		t.Fatal("a non-numeric value for an INTEGER column should be refused")
	}
}
```

**`newDBFixture`, `callTool`, `structured` and `isToolError` are placeholders for this
file's real helpers.** Read the neighbouring tests and substitute the actual names; the
three assertions that matter are the exact statement text, that the row is unchanged, and
that a bad value comes back as a tool error.

- [ ] **Step 4: Run and commit**

Run: `make build && make test && make vet`

```bash
git add cmd/wakil-db
git commit -m "Serve the composed UPDATE without running it

The same shape classify_statement established: ask Go before running, so
Wakil's Swift half never parses or composes SQL. It opens the WRITE
connection because the escaping depends on that connection's own
sql_mode — composing against the read connection's could quote a
backslash for the wrong mode and store the wrong value silently.

Mongo answers that it cannot compose one, rather than panicking on a type
assertion.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `PaneEditable` and the projection

**Files:**
- Create: `app/Sources/WakilKit/Panes/PaneEditable.swift`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (`dbPaneContents`)
- Test: `app/Tests/WakilKitTests/PaneEditableTests.swift` (create)

**Interfaces:**
- Produces:
  ```swift
  public struct PaneEditable: Sendable, Equatable {
      public let table: String
      public let keyColumns: [String]
      public let columns: [String]
      public let rowKeys: [String]
      public init(table: String, keyColumns: [String], columns: [String], rowKeys: [String])
  }
  public func paneEditable(from structured: [String: JSONValue]) -> PaneEditable?
  public func editableCell(_ editable: PaneEditable?, column: String, row: Int) -> String?
  ```
  `editableCell` returns the row's key when that cell may be edited, and `nil` otherwise —
  the one predicate the view asks, living in `WakilKit` because `WakilApp` has no test target.
- `dbPaneContents` gains an `editable: PaneEditable?` element in its returned tuple.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/PaneEditableTests.swift`:

```swift
import Testing
@testable import WakilKit

private let sample = PaneEditable(
    table: "events", keyColumns: ["id"], columns: ["kind", "note"],
    rowKeys: [#""id" = '1'"#, #""id" = '2'"#])

@Test func anEditableCellReportsItsRowKey() {
    #expect(editableCell(sample, column: "kind", row: 0) == #""id" = '1'"#)
    #expect(editableCell(sample, column: "note", row: 1) == #""id" = '2'"#)
}

@Test func aKeyColumnIsNotEditable() {
    #expect(editableCell(sample, column: "id", row: 0) == nil)
}

@Test func anUnknownColumnOrRowIsNotEditable() {
    #expect(editableCell(sample, column: "nope", row: 0) == nil)
    #expect(editableCell(sample, column: "kind", row: 9) == nil)
    #expect(editableCell(sample, column: "kind", row: -1) == nil)
    #expect(editableCell(nil, column: "kind", row: 0) == nil)
}

@Test func theProjectionReadsAnEditableBlock() {
    let structured: [String: JSONValue] = [
        "editable": .object([
            "table": .string("events"),
            "keyColumns": .array([.string("id")]),
            "columns": .array([.string("kind")]),
            "rowKeys": .array([.string(#""id" = '1'"#)]),
        ]),
    ]
    let editable = paneEditable(from: structured)
    #expect(editable?.table == "events")
    #expect(editable?.columns == ["kind"])
    #expect(editable?.rowKeys == [#""id" = '1'"#])
}

@Test func anAbsentOrMalformedBlockIsNotEditable() {
    #expect(paneEditable(from: [:]) == nil)
    #expect(paneEditable(from: ["editable": .null]) == nil)
    // A block naming no table, no key or no writable column is not
    // editable — the driver should never send one, and a surface that
    // trusted it would offer an edit it cannot compose.
    #expect(paneEditable(from: ["editable": .object(["table": .string("")])]) == nil)
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make app-test 2>&1 | grep -A 3 PaneEditable`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

Create `app/Sources/WakilKit/Panes/PaneEditable.swift`:

```swift
import Foundation

/// What a result reported about being written back to —
/// `wakilcore.Editable`, carried through.
///
/// **`nil` means "not editable", and the driver is the only thing that
/// decides it.** Nothing in Swift parses SQL, names a table, or knows what
/// a primary key is; this type holds an answer rather than computing one.
///
/// **`rowKeys` are opaque.** Each is a `WHERE` predicate the driver
/// rendered at read time from the values the engine returned, and Swift's
/// only permitted operations on one are to store it, reorder it with its
/// row, and hand it back. It must never be parsed, split, concatenated or
/// built — that is 2c-ii's "Swift never composes SQL" rule, and the reason
/// these are text at all: a key above 2^53 could not cross as a number.
public struct PaneEditable: Sendable, Equatable {
    public let table: String
    public let keyColumns: [String]
    /// The result columns that may be written to. Never includes a key
    /// column: editing a key changes the row's identity and invalidates
    /// every `rowKey` this value holds.
    public let columns: [String]
    /// Positionally aligned with the pane's rows **in the order they are
    /// displayed** — see `PaneStore`, which permutes these with the rows
    /// whenever a client-side sort reorders them.
    public let rowKeys: [String]

    public init(table: String, keyColumns: [String], columns: [String], rowKeys: [String]) {
        self.table = table
        self.keyColumns = keyColumns
        self.columns = columns
        self.rowKeys = rowKeys
    }

    /// This value with its row keys in another order — the permutation a
    /// client-side sort produced. Indices outside the range are dropped
    /// rather than trapping; a short `rowKeys` simply makes the rows past
    /// it uneditable, which is the safe direction.
    public func reordered(by permutation: [Int]) -> PaneEditable {
        PaneEditable(
            table: table, keyColumns: keyColumns, columns: columns,
            rowKeys: permutation.compactMap { rowKeys.indices.contains($0) ? rowKeys[$0] : nil })
    }
}

/// The row key for a cell that may be edited, or `nil`.
///
/// **The one predicate the view asks, and it lives here** for the reason
/// `shouldAdoptSubject`, `offersDrill` and `queryLineDatabase` do:
/// `WakilApp` has no test target and cannot have one, and this decides
/// whether a double-click turns a cell into an input.
public func editableCell(_ editable: PaneEditable?, column: String, row: Int) -> String? {
    guard let editable, editable.columns.contains(column),
          row >= 0, editable.rowKeys.indices.contains(row)
    else { return nil }
    return editable.rowKeys[row]
}

/// Reads `wakilcore.Editable` out of a tool result's `structuredContent`.
///
/// Anything missing, malformed, or naming no table / no key / no writable
/// column yields `nil` — a surface that trusted a half-formed block would
/// offer an edit it cannot compose.
public func paneEditable(from structured: [String: JSONValue]) -> PaneEditable? {
    guard case .object(let block)? = structured["editable"],
          case .string(let table)? = block["table"], !table.isEmpty
    else { return nil }
    func strings(_ key: String) -> [String] {
        guard case .array(let values)? = block[key] else { return [] }
        return values.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
    let keyColumns = strings("keyColumns")
    let columns = strings("columns")
    guard !keyColumns.isEmpty, !columns.isEmpty else { return nil }
    return PaneEditable(
        table: table, keyColumns: keyColumns, columns: columns, rowKeys: strings("rowKeys"))
}
```

- [ ] **Step 4: Carry it through `dbPaneContents`**

In `StandardActions.swift`, add `editable: PaneEditable?` to `dbPaneContents`' return
tuple and set it with `paneEditable(from: structured)`. Update every call site the
compiler points at.

- [ ] **Step 5: Run and commit**

Run: `make app-test 2>&1 | tail -20`

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests/PaneEditableTests.swift
git commit -m "Carry what the driver said about writing a result back

The row keys are opaque here on purpose. Each is a WHERE predicate the
driver rendered from the values the engine returned, and Swift's only
permitted operations on one are to store it, reorder it with its row, and
hand it back — never parse, split or build one. That is why they are text
at all: a key above 2^53 could not cross as a number.

The is-this-cell-editable predicate lives in WakilKit rather than in the
view, for the reason shouldAdoptSubject and offersDrill do — WakilApp has
no test target, and this decides whether a double-click opens an input.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Keys travel with their rows

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneContents.swift` (`sortedRows`)
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (`Contents`, `setRows`, `reorder`, `snapshot`)
- Test: `app/Tests/WakilKitTests/PaneStoreTests.swift` (append)

**Interfaces:**
- Produces:
  ```swift
  /// The order `rows` should be displayed in, as indices into `rows`.
  public func sortedRowOrder(_ rows: [[JSONValue]], by sort: [PaneSort], columns: [String]) -> [Int]
  ```
  `sortedRows` keeps its current signature and becomes a one-line wrapper over it, so no
  existing caller or test changes.

**Why.** `Contents` holds `rows` (as the database gave them) and `displayRows` (sorted).
A `rowKeys` array left unpermuted would pair every key with the wrong row — the single
worst failure this whole feature exists to prevent, reintroduced one layer below the
layer that prevents it.

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/PaneStoreTests.swift`:

```swift
/// The failure this exists against: a client-side sort reorders the rows,
/// and an unpermuted key array then names a DIFFERENT row than the one on
/// screen — so editing the top row would update whichever row happened to
/// be first before the sort.
@Test func sortingAPaneCarriesEachRowKeyWithItsRow() async {
    let panes = PaneStore()
    await panes.setRows(
        paneId: "db", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false,
        rows: [[.integer(3), .string("c")], [.integer(1), .string("a")],
               [.integer(2), .string("b")]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '3'"#, #""id" = '1'"#, #""id" = '2'"#]))

    await panes.reorder(paneId: "db", sort: [PaneSort(column: "id", direction: .ascending)])

    let editable = await panes.editable(paneId: "db")
    // Display order is now 1, 2, 3 — and so are the keys.
    #expect(editable?.rowKeys == [#""id" = '1'"#, #""id" = '2'"#, #""id" = '3'"#])
    #expect(editableCell(editable, column: "kind", row: 0) == #""id" = '1'"#)
}

/// read_pane feeds an LLM's context; five hundred WHERE fragments in it
/// buy the agent nothing it cannot see in the key column itself.
@Test func theSnapshotNamesTheTableButNotEveryRowKey() async {
    let panes = PaneStore()
    await panes.setRows(
        paneId: "db", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.integer(1), .string("a")]],
        millis: 1, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '1'"#]))
    guard case .object(let snapshot) = await panes.snapshot(paneId: "db"),
          case .object(let block)? = snapshot["editable"]
    else { return #expect(Bool(false), "expected an editable block") }
    #expect(block["table"] == .string("events"))
    #expect(block["columns"] == .array([.string("kind")]))
    #expect(block["rowKeys"] == nil)
}
```

**`panes.editable(paneId:)` and `setRows`' `editable:` parameter do not exist yet** —
that is what makes this test red.

- [ ] **Step 2: Run it and watch it fail**

Run: `make app-test 2>&1 | grep -A 3 sortingAPaneCarries`
Expected: FAIL — extra argument `editable`.

- [ ] **Step 3: Add `sortedRowOrder`**

In `PaneContents.swift`, refactor `sortedRows` so the comparison it already performs
produces indices, and keep `sortedRows` as a wrapper:

```swift
/// The order `rows` should be displayed in, as indices into `rows`.
///
/// **Indices rather than reordered rows, because rows are not the only
/// thing that has to move.** A pane's `rowKeys` are positionally aligned
/// with its rows, and an ordering applied to one but not the other pairs
/// every key with the wrong row — which would make editing the top row
/// update whichever row happened to be first before the sort. One
/// permutation, computed once, applied to everything aligned with a row.
///
/// Every rule `sortedRows` documents holds unchanged: nulls last in both
/// directions, numeric comparison for two numbers, `localizedStandardCompare`
/// otherwise, sort keys built once per row, and a term naming an unknown
/// column dropped rather than thrown on.
public func sortedRowOrder(
    _ rows: [[JSONValue]], by sort: [PaneSort], columns: [String]
) -> [Int] {
    // ... the existing body, sorting `Array(rows.indices)` by the same
    // keys instead of sorting the rows themselves ...
}

public func sortedRows(
    _ rows: [[JSONValue]], by sort: [PaneSort], columns: [String]
) -> [[JSONValue]] {
    sortedRowOrder(rows, by: sort, columns: columns).map { rows[$0] }
}
```

Move the existing key-building and comparator into `sortedRowOrder` verbatim; the only
change is what the sort returns.

- [ ] **Step 4: Store and permute the keys**

In `PaneStore.swift`:

```swift
        /// What the driver said about writing this result back, with its
        /// `rowKeys` in the SAME order as `displayRows`.
        ///
        /// It is refreshed exactly where `displayRows` is, and by the same
        /// permutation, because a key that is not in its row's position
        /// names a different row.
        var editable: PaneEditable?
        /// `editable` as it arrived, before any client-side sort — the
        /// same reason `rows` is kept beside `displayRows`: re-sorting by
        /// a second column must order what the database gave, not the
        /// result of the previous sort.
        var sourceEditable: PaneEditable?
```

`setRows` gains `editable: PaneEditable?` and stores both, applying the permutation; the
existing `reorder` (or wherever `displayRows` is recomputed) applies the same permutation
to `sourceEditable`. Add:

```swift
    public func editable(paneId: String) -> PaneEditable? { panes[paneId]?.editable }
```

In `snapshot`, add the block **without** `rowKeys`:

```swift
        // `table`, `keyColumns` and `columns` are facts about the pane
        // worth the agent knowing. `rowKeys` are not: `read_pane` feeds an
        // LLM's context, and five hundred WHERE fragments buy nothing the
        // key column does not already show.
        if let editable = contents.editable {
            object["editable"] = .object([
                "table": .string(editable.table),
                "keyColumns": .array(editable.keyColumns.map { .string($0) }),
                "columns": .array(editable.columns.map { .string($0) }),
            ])
        }
```

- [ ] **Step 5: Run, fix call sites, commit**

Every `setRows` call site now needs the new argument; the compiler lists them. Pass `nil`
from any path that has no editability to report (the schema browser, the table list).

Run: `make app-test 2>&1 | tail -20`

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests/PaneStoreTests.swift
git commit -m "Keep every row key in its own row's position

A pane holds its rows twice — as the database gave them, and in the order
they are displayed — and the keys have to make the same trip. Sorting
produced a permutation applied to one and not the other, which would pair
every key with the wrong row and make editing the top row update whichever
row was first before the sort.

So the sort returns indices and one permutation is applied to everything
aligned with a row. sortedRows is now a wrapper over it and no caller
changed.

read_pane gets the table and the writable columns but not the row keys:
it feeds an LLM's context, and five hundred WHERE fragments buy nothing
the key column does not already show.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: The `db_render_update` action

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift`
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift` (append)

**Interfaces:**
- Produces: action `db_render_update`, `kind: .read`, parameters `{database?, table, rowKey, column, columnType?, value}`, returning the `wakil-db` result whose `structuredContent.statement` is the composed text.

- [ ] **Step 1: Write the failing test**

Append to `StandardActionsTests.swift`, following that file's existing fake-`MCPClient`
pattern:

```swift
@Test func renderUpdateIsAReadThatComposesAStatement() async throws {
    let registry = ActionRegistry()
    let db = FakeDBClient(reply: .object([
        "structuredContent": .object([
            "statement": .string(#"UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'"#),
        ]),
    ]))
    await registerStandardActions(on: registry, db: db /* … this file's real signature … */)
    let all = await registry.all()
    guard let action = all.first(where: { $0.name == "db_render_update" }) else {
        Issue.record("db_render_update must be registered")
        return
    }
    // `.read`, so it is reachable by the agent and cannot write anything.
    #expect(action.kind == .read)
    #expect(db.lastTool == "render_update")
}
```

Read the top of `StandardActionsTests.swift` and use its real fake client and
registration helper; the two assertions that matter are the action's `kind` and that it
calls `render_update`.

- [ ] **Step 2: Run it and watch it fail**

Run: `make app-test 2>&1 | grep -A 3 renderUpdateIsARead`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `StandardActions.swift`, beside `db_run_mutation`:

```swift
    // Composes the statement a cell edit will run, and runs nothing.
    //
    // **`.read`, and that is not a loophole.** It opens a writable
    // connection — the escaping depends on that connection's own
    // `sql_mode` — but it executes no statement against user data, and the
    // text it returns still has to pass `db_run_mutation`'s gate, the
    // production block and a typed human confirmation before anything
    // happens. An agent reaching it can compose statements it could
    // already write by hand.
    //
    // **It exists so that Wakil's Swift half never composes SQL**, the
    // same reason `classify_statement` exists: the dialect's quoting, the
    // server's backslash mode and the column's type all live in Go, and a
    // second implementation nearer the screen would be a second answer to
    // a question that decides what gets escaped.
    await registry.register(Action(
        name: "db_render_update",
        description:
            "Compose the UPDATE that writes one cell back, and return it WITHOUT running it. "
            + "rowKey must come from a result's editable.rowKeys — it is the driver's own "
            + "rendering of the WHERE clause naming one row, and composing one yourself is how "
            + "a tool updates the wrong row. value is a literal unless it begins with \"=\", "
            + "which passes the rest through as SQL. Pass the statement to db_run_mutation, "
            + "which still requires the write gate and a human confirmation.",
        kind: .read,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "database": .object(["type": .string("string")]),
                "table": .object(["type": .string("string")]),
                "rowKey": .object(["type": .string("string")]),
                "column": .object(["type": .string("string")]),
                "columnType": .object(["type": .string("string")]),
                "value": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("table"), .string("rowKey"), .string("column"), .string("value"),
            ]),
        ]),
        handler: { params in
            guard let db else {
                throw StandardActionError.missingClient(
                    action: "db_render_update", role: "database")
            }
            var arguments: [String: JSONValue] = [:]
            for key in ["database", "table", "rowKey", "column", "columnType", "value"] {
                if case .object(let obj) = params, let value = obj[key] {
                    arguments[key] = value
                }
            }
            return try await callChecked(
                db, tool: "render_update", arguments: .object(arguments),
                action: "db_render_update", timeout: MCPClient.readReplyTimeout)
        }
    ))
```

- [ ] **Step 4: Run and commit**

Run: `make app-test 2>&1 | tail -20`

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/StandardActionsTests.swift
git commit -m "Ask Go for the statement a cell edit will run

The same shape classify_statement established. The dialect's quoting, the
server's backslash mode and the column's type all live in Go, and a
second implementation nearer the screen would be a second answer to the
question that decides what gets escaped.

It is a read: it executes nothing against user data, and what it returns
still passes the write gate, the production block and a typed human
confirmation before anything happens.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: `WindowModel.commitCellEdit`

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (beside `runMutation`, ~line 1600)
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift` (append)

**Interfaces:**
- Produces:
  ```swift
  /// The outcome of a cell edit, so the view knows whether to leave edit mode.
  public enum CellEditOutcome: Sendable, Equatable {
      case committed
      case refused(String)
      case cancelled
  }
  public func commitCellEdit(
      pane: Pane, rowKey: String, column: String, columnType: String?, value: String
  ) async -> CellEditOutcome
  ```

- [ ] **Step 1: Write the failing test**

Append to `WindowModelTests.swift`. It builds the model the way every other test in that
file does — `makeRegistry()` then `WindowModel(...)` with `AlwaysSucceedsCredentialsLookup()`
— and registers two stand-in actions rather than a fake MCP client, because what is under
test is the sequence `commitCellEdit` performs, not the transport:

```swift
@Test @MainActor func aCommittedCellEditRendersThenMutatesThenRefetches() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let calls = Recorder()
    await registry.register(Action(
        name: "db_render_update", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_render_update", params)
            return .object(["structuredContent": .object([
                "statement": .string(#"UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'"#),
            ])])
        }))
    await registry.register(Action(
        name: "db_run_mutation", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_run_mutation", params)
            return .object(["structuredContent": .object(["rowsAffected": .integer(1)])])
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())

    await panes.setRows(
        paneId: "db-1", columns: ["id", "kind"], columnTypes: ["INTEGER", "TEXT"],
        columnTypesInferred: false, rows: [[.integer(1), .string("a")]],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "events", keyColumns: ["id"], columns: ["kind"],
            rowKeys: [#""id" = '1'"#]))
    let pane = Pane(id: "db-1", kind: "db")

    let outcome = await model.commitCellEdit(
        pane: pane, rowKey: #""id" = '1'"#, column: "kind", columnType: "TEXT", value: "b")

    #expect(outcome == .committed)
    // The statement Go composed is what reached the gated action —
    // nothing here rewrote it.
    #expect(await calls.names() == ["db_render_update", "db_run_mutation"])
    guard case .object(let mutateParams)? = await calls.params(for: "db_run_mutation") else {
        return #expect(Bool(false), "db_run_mutation should have been called")
    }
    #expect(mutateParams["statement"]
        == .string(#"UPDATE "events" SET "kind" = 'b' WHERE "id" = '1'"#))
}

/// A refusal carries the driver's own sentence and runs NOTHING — the
/// statement is never composed, so there is nothing to confirm.
@Test @MainActor func aRefusedCellEditRunsNothing() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let calls = Recorder()
    await registry.register(Action(
        name: "db_render_update", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            throw StandardActionError.serverError(
                action: "db_render_update",
                message: "\"abc\" is not a number, and n is a INTEGER column")
        }))
    await registry.register(Action(
        name: "db_run_mutation", description: "stub", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { params in
            await calls.record("db_run_mutation", params)
            return .null
        }))
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())
    await panes.setRows(
        paneId: "db-1", columns: ["id", "n"], columnTypes: ["INTEGER", "INTEGER"],
        columnTypesInferred: false, rows: [[.integer(1), .integer(7)]],
        millis: 0, truncated: false, pageable: true, offset: 0, sort: [], listsTables: false,
        editable: PaneEditable(
            table: "t", keyColumns: ["id"], columns: ["n"], rowKeys: [#""id" = '1'"#]))

    let outcome = await model.commitCellEdit(
        pane: Pane(id: "db-1", kind: "db"), rowKey: #""id" = '1'"#, column: "n",
        columnType: "INTEGER", value: "abc")

    guard case .refused(let reason) = outcome else {
        return #expect(Bool(false), "expected a refusal, got \(outcome)")
    }
    #expect(reason.contains("not a number"))
    #expect(await calls.names().isEmpty)
}

/// A pane the driver never called editable refuses before any round trip.
@Test @MainActor func aCellEditOnAReadOnlyPaneRefusesWithoutDispatching() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { _ in nil }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main",
        lookup: AlwaysSucceedsCredentialsLookup())
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["INTEGER"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 0, truncated: false, pageable: true,
        offset: 0, sort: [], listsTables: false, editable: nil)
    let outcome = await model.commitCellEdit(
        pane: Pane(id: "db-1", kind: "db"), rowKey: "x", column: "id",
        columnType: nil, value: "2")
    guard case .refused = outcome else {
        return #expect(Bool(false), "expected a refusal")
    }
}

/// A tiny recorder, because two of the tests above assert on WHICH actions
/// ran and in what order. `actor` rather than a class with a lock: these
/// handlers run off the main actor.
private actor Recorder {
    private var calls: [(name: String, params: JSONValue)] = []
    func record(_ name: String, _ params: JSONValue) { calls.append((name, params)) }
    func names() -> [String] { calls.map(\.name) }
    func params(for name: String) -> JSONValue? { calls.first { $0.name == name }?.params }
}
```

**Both stubs are registered `.read` deliberately.** Registering `db_run_mutation` as
`.mutate` would park it in the confirmation broker and the test would hang waiting for a
human. The gate itself is covered by `MutationActionTests` and `WriteGateTests`; what is
under test here is the sequence.

**`Pane(id:kind:)` and `makeRegistry()`** are quoted from this file's existing tests —
check their real signatures at the top of `WindowModelTests.swift` and match them.

- [ ] **Step 2: Run it and watch it fail**

Run: `make app-test 2>&1 | grep -A 3 CellEdit`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

In `WindowModel.swift`, after `runMutation`:

```swift
    /// The outcome of a cell edit, so the view knows whether to leave edit
    /// mode.
    ///
    /// **`.refused` and `.cancelled` are distinct even though the view
    /// treats them alike** — both keep the operator's text — because they
    /// are different events and a later change to either must not silently
    /// change the other.
    public enum CellEditOutcome: Sendable, Equatable {
        case committed
        case refused(String)
        case cancelled
    }

    /// What Enter in an edited cell does.
    ///
    /// **Two round trips, and neither is optional.** The first composes
    /// the statement in Go — where the dialect's quoting, the server's
    /// backslash mode and the column's type live — and runs nothing. The
    /// second is `runMutation`, unchanged: the same `db_run_mutation`, the
    /// same `writeGate`, the same confirmation plane and the same
    /// production block a statement typed into the query line takes. Enter
    /// **requests** confirmation; it does not supply it.
    ///
    /// **It composes no SQL and reads none.** `rowKey` came from the
    /// driver and goes back to the driver untouched; the statement is
    /// whatever Go answered.
    public func commitCellEdit(
        pane: Pane, rowKey: String, column: String, columnType: String?, value: String
    ) async -> CellEditOutcome {
        var params: [String: JSONValue] = [
            "table": .string(table),
            "rowKey": .string(rowKey),
            "column": .string(column),
            "value": .string(value),
        ]
        if let columnType, !columnType.isEmpty { params["columnType"] = .string(columnType) }
        if let database = databaseForQueryLine(pane: pane), !database.isEmpty {
            params["database"] = .string(database)
        }
        guard let rendered = await dispatch("db_render_update", .object(params)) else {
            // `status` is the window's own last failure sentence — the
            // driver's wording, never a second one composed here, which is
            // the discipline `classify_statement` established.
            return .refused(status)
        }
        guard case .object(let obj) = rendered,
              case .object(let structured)? = obj["structuredContent"],
              case .string(let statement)? = structured["statement"],
              !statement.isEmpty
        else {
            return .refused("could not compose the update")
        }
        // `dispatch` returns nil for a refusal AND for a cancel alike, and
        // the two must not be told apart here: both leave the cell in edit
        // mode holding what the operator typed. `runMutation` already
        // re-fetches the pane on success (D8b) and does nothing otherwise.
        guard await dispatch("db_run_mutation", .object([
            "statement": .string(statement),
        ].merging(params["database"].map { ["database": $0] } ?? [:]) { a, _ in a })) != nil
        else {
            return .cancelled
        }
        await refetchPane(id: pane.id)
        return .committed
    }
```

`commitCellEdit` must refuse before its first round trip when the pane reports no table,
rather than sending an empty one. `panes` is `WindowModel`'s own `private let panes:
PaneStore`, and Task 9 added `PaneStore.editable(paneId:)`, so the guard is:

```swift
        guard let table = await panes.editable(paneId: pane.id)?.table, !table.isEmpty else {
            // The pane is not editable, so the view should not have
            // offered an editor. Refusing here rather than trusting the
            // caller keeps the rule in one place: `editableCell` decides
            // what may be edited, and this is the same answer read from
            // the same store.
            return .refused("these rows cannot be written back to a single table")
        }
```

placed as the method's first statement, with `"table": .string(table)` in `params`.

- [ ] **Step 4: Run and commit**

Run: `make app-test 2>&1 | tail -20`

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "Turn an edited cell into a confirmed statement

Two round trips, neither optional: Go composes, because the dialect's
quoting and the server's backslash mode live there, and then the same
db_run_mutation the query line uses — same gate, same plane, same
production block. Enter requests confirmation; it does not supply it.

A refusal and a cancel are not told apart at the surface, because both
leave the cell holding what the operator typed. That is D7's lesson at
close range: here the discarded text would be the value they just
entered.

A committed edit re-reads the pane's own subject, which runMutation
already does — the grid must not go on showing a value the database no
longer holds.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: The cell editor

**Files:**
- Modify: `app/Sources/WakilApp/DataSurface.swift` (`cellView`, plus two `@State`s)
- Modify: `app/Sources/WakilApp/DBPane.swift` (pass the edit closure through)
- Modify: `app/Sources/WakilApp/Canvas.swift` (wire `commitCellEdit`) — follow how `run` and `dispatch` are already threaded

**Interfaces:**
- Consumes: `editableCell(_:column:row:)` (Task 8), `WindowModel.commitCellEdit` (Task 11).
- Produces: no new value types. `DataSurface` gains
  `var editing: ((_ rowKey: String, _ column: String, _ columnType: String?, _ value: String) async -> WindowModel.CellEditOutcome)? = nil`
  and `var editable: PaneEditable? = nil`, both defaulted so every existing construction compiles.

- [ ] **Step 1: Add the state**

In `DataSurface`:

```swift
    /// Which cell is being edited — row index and column index — and the
    /// text in it. `nil` when nothing is.
    ///
    /// **One cell at a time**: a second double-click abandons the first.
    /// Two live editors would be two uncommitted values with one
    /// confirmation plane between them.
    @State private var editingCell: (row: Int, column: Int)?
    @State private var editingText: String = ""
    /// The gate's or the driver's own sentence for the cell being edited.
    @State private var editingRefusal: String?
```

- [ ] **Step 2: Make an editable cell an input on double-click**

In `cellView`, wrap the existing `Group` so an editing cell draws a field instead:

```swift
    private func cellView(_ row: PaneRow, _ index: Int) -> some View {
        let columnName = table.columns.indices.contains(index) ? table.columns[index].name : ""
        let rowKey = editableCell(editable, column: columnName, row: row.id)
        return Group {
            if editingCell?.row == row.id, editingCell?.column == index {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    // No `.keyboardShortcut`, ever — `DBPane`'s standing
                    // prohibition. `.onSubmit` on the focused field is
                    // what routes Return to the pane it was typed in;
                    // a shortcut is window-scoped and fires the
                    // first-registered pane's control instead.
                    .onSubmit { commit(row: row.id, column: index, columnName: columnName) }
                    .onExitCommand { editingCell = nil; editingRefusal = nil }
            } else {
                existingCellContent(row, index)   // the current Group body, extracted
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        .contentShape(Rectangle())
        .onTapGesture { select(row: row.id, column: index) }
        // The affordance: revealed under the pointer, invisible at rest,
        // the same pattern `hoveredRow` already drives for the drill
        // button. §8's "row separation by whitespace" holds, and a cell
        // that CAN be edited stops looking like one that cannot.
        .background(
            rowKey != nil && hoveredRow == row.id
                ? Color(red: 0.910, green: 0.925, blue: 0.965).opacity(0.05)
                : Color.clear)
        .onTapGesture(count: 2) {
            guard rowKey != nil else { return }
            editingCell = (row: row.id, column: index)
            editingText = row.cells.indices.contains(index) ? row.cells[index].text : ""
            editingRefusal = nil
        }
    }
```

Extract the current `Group { … }` body into `existingCellContent(_:_:)` unchanged — NULL
rendering, chips and the `.help` tooltip all stay exactly as they are.

**A NULL cell seeds as empty, and an empty field means the empty string, not NULL.**
`=NULL` is NULL. The grid already draws the two differently; this keeps the distinction
writable.

- [ ] **Step 3: Commit the edit**

```swift
    /// Enter in an edited cell. The outcome decides whether the editor
    /// closes: only a confirmed run changed anything, so only a confirmed
    /// run leaves edit mode. A refusal and a cancel both keep the
    /// operator's text, because at this range the discarded text is the
    /// value they just typed.
    private func commit(row: Int, column index: Int, columnName: String) {
        guard let editing, let rowKey = editableCell(editable, column: columnName, row: row)
        else { return }
        let type = table.columns.indices.contains(index) ? table.columns[index].type : nil
        let value = editingText
        Task {
            switch await editing(rowKey, columnName, type, value) {
            case .committed:
                editingCell = nil
                editingRefusal = nil
            case .refused(let reason):
                editingRefusal = reason
            case .cancelled:
                break
            }
        }
    }
```

Draw `editingRefusal` as one dim red line beneath the grid, matching `DBPane`'s existing
refusal styling.

- [ ] **Step 4: Thread it through**

`DBPane` passes `editable:` and `editing:` into `DataSurface`; `Canvas.paneView` reads
`editable` from the window model for that pane id and passes a closure calling
`commitCellEdit`. Follow exactly how `refusal`, `restore` and `run` are already threaded
per pane — including that `editable` must be read **per pane id**, which is the fix
`DBPane`'s `refusal` doc comment records: a window-scoped value painted one pane's state
under every other pane.

- [ ] **Step 5: Build, run the app, commit**

Run: `make app-build && make app-test`

```bash
git add app/Sources/WakilApp
git commit -m "Double-click a cell, type, press Enter

The affordance is revealed on hover and invisible at rest, the pattern
the drill button already uses, so §8's whitespace-only row separation
holds and a cell that can be edited stops looking like one that cannot.

Escape abandons. Only a confirmed run closes the editor: a refusal and a
cancel both keep what was typed, because at this range that is the value
the operator just entered.

No keyboardShortcut anywhere in here — a per-pane one is window-scoped
and fires the first-registered pane's control whatever has focus.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: The footer says so

**Files:**
- Modify: `app/Sources/WakilApp/DataSurface.swift` (`footer()`, the trailing label)
- Modify: `app/Sources/WakilKit/Panes/PaneEditable.swift` (the sentence, so it is testable)
- Test: `app/Tests/WakilKitTests/PaneEditableTests.swift` (append)

**Interfaces:**
- Produces: `public func editabilityLabel(_ editable: PaneEditable?, hasRows: Bool) -> String`

- [ ] **Step 1: Write the failing test**

```swift
@Test func theFooterSaysWhetherTheResultCanBeEdited() {
    #expect(editabilityLabel(sample, hasRows: true) == "editable")
    #expect(editabilityLabel(nil, hasRows: true) == "read-only")
    // No result at all: the bare label, with nothing to explain.
    #expect(editabilityLabel(nil, hasRows: false) == "read-only")
}
```

- [ ] **Step 2: Implement**

```swift
/// The footer's trailing label.
///
/// **The footer has always ended with a fixed `read-only`.** It is one of
/// the three segments D9 established must survive narrowing, and it is now
/// carrying a fact rather than a constant: `design-language.md` §8's rule
/// is that a surface which cannot do the thing must not look like it can —
/// and its other half, which this is, is that one which can must not look
/// like it cannot.
public func editabilityLabel(_ editable: PaneEditable?, hasRows: Bool) -> String {
    editable == nil ? "read-only" : "editable"
}
```

**The per-reason wording the spec sketches** (`read-only · more than one table`,
`· no primary key`) needs the driver to say *why* it declined, which `Editable` does not
carry — it is `nil` or it is not. Ship the two-state label, and record the reason as
something the acceptance walk should be asked about: if the operator cannot tell why a
pane is read-only, that is a defect for the walk to find and a `reason` field to add,
rather than four sentences guessed at here.

- [ ] **Step 3: Use it in the footer**

Replace `Text("read-only")` with `Text(editabilityLabel(editable, hasRows: !table.rows.isEmpty))`,
keeping `.layoutPriority(1)` exactly as it is.

- [ ] **Step 4: Run and commit**

Run: `make app-test && make app-build`

```bash
git add app/Sources/WakilApp/DataSurface.swift app/Sources/WakilKit/Panes/PaneEditable.swift app/Tests/WakilKitTests/PaneEditableTests.swift
git commit -m "Make the footer's read-only label tell the truth

It has been a constant since 2c-i. §8's rule is that a surface which
cannot do the thing must not look like it can, and its other half is that
one which can must not look like it cannot.

Two states, not four: saying WHY a result declined needs the driver to
report a reason, and guessing four sentences here would be inventing an
explanation the code does not have. Left for the walk to ask for.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: The acceptance runbook

**Files:**
- Create: `docs/wakil/phase-2c-ii-b-acceptance.md`

**This sub-phase is not met until this is walked.** 2c-i's walk found six defects and
forced two rulings after 500+ tests were green; 2c-ii's found thirteen more. The tests in
Tasks 1–13 prove the rules; only the walk proves the feature.

- [ ] **Step 1: Write the runbook**

Follow `docs/wakil/phase-2c-ii-acceptance.md`'s structure exactly: the north-star
sentence at the top, numbered checks each with a **Do this** and an **Expect**, a
Pass/Fail column filled in at the window, and a defect section at the bottom.

The checks, at minimum:

1. A `db_read_table` pane: double-click a cell, it becomes an input seeded with its value.
2. Enter raises the confirmation plane showing the composed `UPDATE`. Type `confirm`: it runs, and the pane re-reads itself and shows the new value.
3. Cancel the plane: the cell stays in edit mode holding what was typed.
4. Escape: the editor closes and the original value is back.
5. A key column does not open an editor.
6. `SELECT * FROM <table>` typed into the query line is editable; `SELECT * FROM a JOIN b` is not, and the footer says `read-only`.
7. `SELECT id, kind || '!' AS kind FROM events` is not editable — the derived-column trap.
8. `WITH events AS (…) SELECT * FROM events` is not editable — the CTE trap.
9. A value containing a quote (`O'Brien`) and one containing a backslash (`C:\path`) both store exactly, on **both** engines.
10. `=NOW()` stores a timestamp; `=NULL` stores NULL and the cell draws as `NULL`.
11. Typing `abc` into an integer column is refused with a readable sentence and nothing runs.
12. Sort a pane by a column, then edit the top row: the row that changes is the one on screen.
13. On a `production` environment, a cell edit is blocked outright with no plane.
14. **Open question 12, asked explicitly:** after editing several cells, is typing `confirm` each time the right price for a change you never wrote a statement for? Record the answer as walked evidence, not as a preference.

- [ ] **Step 2: Commit**

```bash
git add docs/wakil/phase-2c-ii-b-acceptance.md
git commit -m "Write the runbook 2c-ii-b is not met without

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 3: Hand it to the operator**

Stop here. **Do not mark the sub-phase met.** Report that the runbook is ready to walk
and that the north star's 2c-ii-b row stays unmarked until it has been.

---

## Notes for the executor

- **Every fixture in Task 4 is a measured engine behaviour**, from `docs/wakil/phase-2c-ii-b-probe.md` §5. If one fails, fix the recogniser. Never the fixture.
- **Never emit a bare literal for a typed value.** It is a column reference on both engines and both take it silently. This is the single rule most likely to look like an optimisation and most costly to get wrong.
- **Never let Swift touch a `rowKey`** beyond storing, reordering and returning it.
- **Tasks 1, 2, 3 and 5 need `make test-live`**, which needs the containers up: `docker start wakil-acc-mysql wakil-acc-mongo`. The target fails on a SKIP by design — a skipped live test certifies nothing.
- **If `Editable` gains a `reason` field** (Task 13 leaves the door open), it belongs in Go beside the recogniser, not as four sentences composed in Swift.
