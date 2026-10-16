package wakilcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// newHostileSQLConn builds a *sqlConn over a real, freshly created,
// READ-WRITE SQLite database seeded with three tables:
//
//	u                       - the sacrificial table an injection would drop
//	t                       - a decoy, so that the SQL an UNQUOTED hostile
//	                          identifier produces is syntactically valid and
//	                          the injected statement actually runs
//	<hostile>               - a table whose NAME is the attack payload
//
// Two things about this fixture are deliberate and load bearing.
//
// First, it does NOT go through sqliteDriver.Connect, which opens the
// database with mode=ro. That engine-level read-only flag would refuse the
// injected DROP no matter what quoteIdent did, and would therefore mask
// exactly the defect these tests exist to detect. Finding 8 is that
// quoteIdent is the SOLE guard on the Describe path; the fixture has to
// remove the other guard to be able to observe it.
//
// Second, the decoy table t exists because modernc.org/sqlite's Query
// really does execute every statement in the string it is handed —
// measured: Query("SELECT * FROM v; DROP TABLE u") returns no error and u
// is gone afterwards — but it stops at the first statement that fails.
// With no table t, an unquoted "SELECT * FROM t ; DROP TABLE u; -- LIMIT 0"
// dies on "no such table: t" and u SURVIVES, which would make the
// "u still exists" assertion pass even with quoting deleted. Seeding t
// makes the injection genuinely fire, so the assertion can fail.
func newHostileSQLConn(t *testing.T, hostile string) (*sqlConn, *sql.DB) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "hostile.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	stmts := []string{
		`CREATE TABLE u (sacrificial INTEGER)`,
		`CREATE TABLE t (decoy INTEGER)`,
		// The hostile table has three columns, so Describe's result
		// identifies WHICH table was described: t has one column, u has
		// one, this has three.
		//
		// The quoting here is written out longhand rather than calling
		// sqliteQuoteIdent, deliberately: the fixture must not depend on
		// the function under test, or mutating sqliteQuoteIdent would
		// break the SEEDING and the tests below would fail for the wrong
		// reason instead of on their own assertions.
		`CREATE TABLE "` + strings.ReplaceAll(hostile, `"`, `""`) + `" (id INTEGER, name TEXT, note TEXT)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("seeding %q: %v", s, err)
		}
	}
	return &sqlConn{
		db:         db,
		gate:       AssertSQLReadOnly,
		listSQL:    "SELECT name FROM sqlite_master WHERE type='table'",
		quoteIdent: sqliteQuoteIdent,
	}, db
}

// newSQLiteTestConn builds a *sqlConn over a fresh, file-backed sqlite
// database in a temp directory, with every statement in ddl applied in
// order, and every field a production sqliteDriver.Connect would set —
// including primaryKeySQL and quoteLiteral, which none of this file's
// existing fixtures set because none of them predate needing them.
func newSQLiteTestConn(t *testing.T, ddl []string) *sqlConn {
	t.Helper()
	path := filepath.Join(t.TempDir(), "pk.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	for _, s := range ddl {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("applying %q: %v", s, err)
		}
	}
	return &sqlConn{
		db:   db,
		gate: AssertSQLReadOnly,
		// Models a database configured WITH a writeRef, which is what
		// every editability test here is about. A test that wants the
		// other case sets this false itself — see
		// TestReadOffersNoEditWhenTheDatabaseCannotBeWritten.
		writable:      true,
		listSQL:       "SELECT name FROM sqlite_master WHERE type='table'",
		quoteIdent:    sqliteQuoteIdent,
		primaryKeySQL: "SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk",
		quoteLiteral:  sqliteQuoteLiteral,
	}
}

// TestSQLiteQuoteLiteral pins sqliteQuoteLiteral's rule: doubling the
// single quote is the whole rule, and a backslash is an ORDINARY
// character (unlike MySQL's default), so it must NOT be doubled.
func TestSQLiteQuoteLiteral(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"hello", `'hello'`},
		{"O'Brien", `'O''Brien'`},
		{`C:\path`, `'C:\path'`}, // backslash is ORDINARY in sqlite
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

// TestSQLiteLiteralRoundTrip is TestMySQLLiteralRoundTrip's sqlite
// equivalent: every payload written through the composed literal and read
// back byte for byte over a TEXT column, with the NUL payload removed and
// asserted REFUSED instead of round-tripped, since sqliteQuoteLiteral
// cannot express one.
func TestSQLiteLiteralRoundTrip(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE lit (id INTEGER PRIMARY KEY, v TEXT)`,
	})
	for _, payload := range []string{
		"hello", "O'Brien", `C:\path\n`, "a\nb", "a\tb", "100%_x",
		"café 🚀", "", "x' WHERE 1=1 -- ", `say "hi"`, "a`b",
	} {
		if _, err := conn.db.Exec(`DELETE FROM lit`); err != nil {
			t.Fatal(err)
		}
		if _, err := conn.db.Exec(`INSERT INTO lit VALUES (1, 'seed')`); err != nil {
			t.Fatal(err)
		}
		lit, err := conn.quoteLiteral(payload)
		if err != nil {
			t.Fatalf("%q: %v", payload, err)
		}
		if _, err := conn.db.Exec(`UPDATE lit SET v = ` + lit + ` WHERE id = 1`); err != nil {
			t.Fatalf("%q: %v", payload, err)
		}
		var back string
		if err := conn.db.QueryRow(`SELECT v FROM lit WHERE id = 1`).Scan(&back); err != nil {
			t.Fatalf("%q: %v", payload, err)
		}
		if back != payload {
			t.Fatalf("%q round-tripped as %q", payload, back)
		}
	}
	// The NUL payload is refused rather than escaped: measured, the
	// engine truncates the literal at the NUL and fails on the
	// unterminated remainder, naming a value nobody typed.
	if _, err := conn.quoteLiteral("a\x00b"); err == nil {
		t.Fatal("expected a NUL to be refused rather than round-tripped")
	}
}

// TestSQLConnLiteralForArms is finding 3 of the final review:
// sqlConn.literalFor was roughly 30% covered — only the string arm, via
// TestSQLiteLiteralRoundTrip's own use of quoteLiteral — with the NULL
// refusal and the int64/float64/bool/time.Time/default arms exercised by
// nothing in `make test`. This calls literalFor directly, once per arm, so
// each one is pinned independently of whatever row shapes the rest of the
// suite happens to read.
//
// nil is the load-bearing case: a NULL key must be refused rather than
// rendered as "IS NULL", which would not name one row, or as the bare
// text "<nil>", which would name a row that does not exist. It is also
// genuinely REACHABLE, not just a defensive branch — see
// TestSQLiteNullPrimaryKeyIsNotEditable below, which reaches it through a
// real NULL in a TEXT PRIMARY KEY rather than calling literalFor by hand.
func TestSQLConnLiteralForArms(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{`CREATE TABLE t (id INTEGER PRIMARY KEY)`})

	if _, err := conn.literalFor(nil); err == nil {
		t.Fatal("expected a NULL key to be refused")
	}

	if got, err := conn.literalFor("O'Brien"); err != nil || got != `'O''Brien'` {
		t.Fatalf("string: got %q, %v", got, err)
	}

	if got, err := conn.literalFor(int64(-42)); err != nil || got != "-42" {
		t.Fatalf("int64: got %q, %v", got, err)
	}

	if got, err := conn.literalFor(float64(3.5)); err != nil || got != "3.5" {
		t.Fatalf("float64: got %q, %v", got, err)
	}

	if got, err := conn.literalFor(true); err != nil || got != "1" {
		t.Fatalf("bool true: got %q, %v", got, err)
	}
	if got, err := conn.literalFor(false); err != nil || got != "0" {
		t.Fatalf("bool false: got %q, %v", got, err)
	}

	when := time.Date(2026, 9, 14, 12, 30, 0, 0, time.UTC)
	if got, err := conn.literalFor(when); err != nil || got != `'2026-09-14 12:30:00'` {
		t.Fatalf("time.Time: got %q, %v", got, err)
	}

	// The default arm: any type database/sql might hand back that is
	// none of the above — collectRows has already turned []byte into
	// string, so this is not that case, but int32 is a type database/sql
	// drivers can and do report (e.g. a narrower integer column) that
	// literalFor's switch does not name explicitly. fmt.Sprint renders it
	// as plain text, then quoteLiteral quotes it exactly as the string
	// arm would.
	if got, err := conn.literalFor(int32(7)); err != nil || got != `'7'` {
		t.Fatalf("default: got %q, %v", got, err)
	}
}

// TestSQLiteNullPrimaryKeyIsNotEditable proves literalFor's NULL refusal
// is reachable through the real read path, not just callable directly —
// sqlite, unlike an INTEGER PRIMARY KEY rowid alias, does not imply NOT
// NULL on an ordinary TEXT PRIMARY KEY, so a row with a NULL key is
// something the engine will genuinely hand back. describeEditability
// bails out (via literalFor's error) before ever assigning out.Editable,
// so the whole result comes back non-editable rather than carrying a
// RowKeys entry that does not name any one row.
func TestSQLiteNullPrimaryKeyIsNotEditable(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE nullkey (k TEXT PRIMARY KEY, v TEXT)`,
	})
	if _, err := conn.db.Exec(`INSERT INTO nullkey (k, v) VALUES (NULL, 'orphan')`); err != nil {
		t.Fatal(err)
	}
	out, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT * FROM nullkey"}, 10)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if out.Editable != nil {
		t.Fatalf("expected a NULL key to make the result non-editable, got %#v", out.Editable)
	}
}

// TestSQLitePrimaryKey pins sqlConn.PrimaryKey against a real sqlite
// engine: an ordinary single-column key, a composite key whose reported
// order is the engine's rather than the declaration's, a keyless table, a
// WITHOUT ROWID table (whose declared key is still pk > 0 in
// pragma_table_info), a view, and a table that does not exist at all.
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

// TestSQLiteDescribeReportsKeyColumns is Step 6: Column.Key has been
// declared and unset since Phase 1, and sqlConn.Describe now fills it in
// from PrimaryKey. comp's key is (b, a) — a composite, so this must mark
// exactly those two columns and no others, regardless of the order
// Describe (SELECT * ... LIMIT 0) reports the columns in.
func TestSQLiteDescribeReportsKeyColumns(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE comp (a INT, b TEXT, c INT, PRIMARY KEY (b, a))`,
	})
	sch, err := conn.Describe(context.Background(), "comp")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, col := range sch.Columns {
		got[col.Name] = col.Key
	}
	want := map[string]bool{"a": true, "b": true, "c": false}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Key by column = %v, want %v", got, want)
	}
}

// tableExists reports whether a table of exactly this name is present.
func tableExists(t *testing.T, db *sql.DB, name string) bool {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?`, name).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n > 0
}

// TestDescribeQuotingDefeatsIdentifierInjection is the test Finding 8 asks
// for: it kills the "no quoting of identifiers" mutant on a bare
// `go test ./...` with no environment variables and no Docker, because
// modernc.org/sqlite is a pure-Go in-process driver and a real hostile
// database can be built in a temp dir.
//
// It asserts two things per case, and both matter:
//
//  1. Describe SUCCEEDS on the hostile table and returns THAT table's
//     three columns. A test that only asserted "Describe returns an error
//     for a hostile name" — which is what the pre-existing
//     TestQuoteIdentEscapesHostileNames asserts — is satisfied by deleting
//     quoting entirely, since the resulting SQL usually fails too. Only
//     "the hostile name was handled as a NAME" distinguishes the two.
//  2. The sacrificial table u still exists. This is what makes the test
//     non-vacuous: it proves the injection did not FIRE, not merely that
//     some string got wrapped in quotes.
func TestDescribeQuotingDefeatsIdentifierInjection(t *testing.T) {
	cases := []struct {
		name string
		// hostile is the table name, i.e. the describe_table argument.
		hostile string
		// unquoted is the SQL "SELECT * FROM " + hostile + " LIMIT 0"
		// that the mutant would produce, recorded so the reader can see
		// why each case is dangerous.
		unquoted string
	}{
		{
			// No quote character at all, so a quoteIdent mutated to
			// `return s` produces perfectly valid SQL: three statements,
			// the first of which succeeds against the decoy table t, so
			// the DROP really runs. This case fails BOTH assertions under
			// the mutant.
			name:     "no quote char, injection is valid SQL and fires",
			hostile:  `t ; DROP TABLE u; --`,
			unquoted: `SELECT * FROM t ; DROP TABLE u; -- LIMIT 0`,
		},
		{
			// The classic shape, and the one that pins DOUBLING rather
			// than mere wrapping: a quoteIdent that wrapped in quotes but
			// forgot to double the embedded one emits
			// SELECT * FROM "t" ; DROP TABLE u; --" LIMIT 0
			// which closes the identifier early and drops u.
			name:     "embedded double quote must be doubled, not just wrapped",
			hostile:  `t" ; DROP TABLE u; --`,
			unquoted: `SELECT * FROM t" ; DROP TABLE u; -- LIMIT 0`,
		},
		{
			// The backtick equivalent from the brief. SQLite accepts
			// backticks as an identifier quote too, so this is a real
			// payload against this engine and not only against MySQL.
			name:     "backtick payload",
			hostile:  "t` ; DROP TABLE u; -- ",
			unquoted: "SELECT * FROM t` ; DROP TABLE u; --  LIMIT 0",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, db := newHostileSQLConn(t, tc.hostile)

			sch, describeErr := c.Describe(context.Background(), tc.hostile)

			// The load-bearing assertion, checked FIRST and deliberately
			// before describeErr: whether Describe succeeded is secondary
			// to whether it damaged the database, and checking the error
			// first would abort the subtest before this ever ran.
			if !tableExists(t, db, "u") {
				t.Fatalf("SQL injection FIRED: describing %q dropped the sacrificial table u "+
					"(the generated SQL must have been %q)", tc.hostile, tc.unquoted)
			}
			// ... and the decoy is still there too, so a future refactor
			// cannot make the check above pass by dropping the wrong
			// table or by failing before any statement ran.
			if !tableExists(t, db, "t") {
				t.Fatal("decoy table t was dropped; the fixture no longer proves what it claims")
			}

			if describeErr != nil {
				t.Fatalf("Describe(%q) must succeed — the hostile string is a real table NAME, "+
					"and quoting is what makes it one; unquoted this would be %q: %v",
					tc.hostile, tc.unquoted, describeErr)
			}
			if len(sch.Columns) != 3 {
				t.Fatalf("Describe(%q) returned %d columns (%+v), want the hostile table's 3 — "+
					"a different count means a DIFFERENT table was described, i.e. the name "+
					"was parsed as SQL rather than quoted as an identifier",
					tc.hostile, len(sch.Columns), sch.Columns)
			}
			if got := sch.Columns[0].Name; got != "id" {
				t.Fatalf("first column %q, want \"id\" (the hostile table's own schema)", got)
			}
		})
	}
}

// TestDescribeInjectionFixtureIsRealisticallyDangerous guards the fixture
// itself. Every assertion in TestDescribeQuotingDefeatsIdentifierInjection
// rests on the claim that the unquoted SQL would really have dropped u on
// this driver. If that stopped being true — a driver upgrade that refused
// multi-statement Query, say — the sibling test would go on passing while
// proving nothing at all, which is the "coverage that cannot fail" failure
// mode. So assert the danger directly, against the same engine.
func TestDescribeInjectionFixtureIsRealisticallyDangerous(t *testing.T) {
	_, db := newHostileSQLConn(t, `t ; DROP TABLE u; --`)
	if !tableExists(t, db, "u") {
		t.Fatal("fixture is wrong: u should exist before the injection")
	}
	// Exactly the string sqlConn.Describe would build if quoteIdent were
	// mutated to the identity function.
	rows, err := db.QueryContext(context.Background(), `SELECT * FROM `+`t ; DROP TABLE u; --`+` LIMIT 0`)
	if err != nil {
		t.Fatalf("the unquoted payload must be valid SQL for the sibling test to mean anything: %v", err)
	}
	rows.Close()
	if tableExists(t, db, "u") {
		t.Fatal("the unquoted payload did NOT drop u on this driver, so " +
			"TestDescribeQuotingDefeatsIdentifierInjection can no longer fail; " +
			"rebuild the fixture around whatever this driver now does execute")
	}
}

// TestDescribeRejectsNulByteWithSpecificMessage kills the "Describe skips
// NUL check" mutant, which the pre-existing
// TestDescribeRejectsNulByteIdentifier could not: without the check, the
// query is still built and still fails, and its failure is still wrapped
// as a UserError, so "err != nil and is a UserError" stays green. The
// distinguishing evidence is WHICH message comes back, so pin it exactly.
//
// Measured on both engines, a NUL inside a quoted identifier truncates the
// statement at the NUL:
//
//	sqlite: SQL logic error: unrecognized token: ""customers"
//	mysql:  Error 1064 ... right syntax to use near '`customers'
//
// i.e. without this check the caller is told about a table it never named.
func TestDescribeRejectsNulByteWithSpecificMessage(t *testing.T) {
	c, _ := newHostileSQLConn(t, "harmless")
	for _, name := range []string{"\x00", "bad\x00name", "customers\x00 ; DROP TABLE u; --"} {
		t.Run(fmt.Sprintf("%q", name), func(t *testing.T) {
			_, err := c.Describe(context.Background(), name)
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("expected a UserError for a NUL-bearing identifier, got %T: %v", err, err)
			}
			if msg != "invalid table name" {
				t.Fatalf("got %q, want %q — a message mentioning the engine means the NUL "+
					"reached the query builder instead of being rejected here", msg, "invalid table name")
			}
		})
	}
}

// TestClampReadLimit pins the row cap (Finding 12) as a pure function. The
// in-range case is not filler: without it, the "limit cap removed" mutant
// can be "fixed" by clamping every input to 500, which would pass a test
// that only checked the two out-of-range directions.
func TestClampReadLimit(t *testing.T) {
	cases := []struct {
		name string
		in   int
		want int
		why  string
	}{
		{"unset", 0, 500, "callers that omit the argument pass 0; returning 0 rows is useless"},
		{"negative", -1, 500, "same default as unset, not a negative slice bound"},
		{"one", 1, 1, "smallest in-range value must pass through"},
		{"in range", 250, 250, "an in-range limit must NOT be rewritten to 500"},
		{"at the cap", 1000, 1000, "1000 is in range and must pass through unchanged"},
		{"one past the cap", 1001, 500, "the cap is exclusive above 1000, and out-of-range collapses to the default"},
		{"absurd", 10_000_000, 500, "an LLM-chosen limit must not be able to flood the context window"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := clampReadLimit(tc.in); got != tc.want {
				t.Fatalf("clampReadLimit(%d) = %d, want %d — %s", tc.in, got, tc.want, tc.why)
			}
		})
	}
}

// seedCountingTable creates a table with exactly n rows numbered 1..n and
// returns a *sqlConn over it. Read-write is fine here: nothing in these
// tests writes through the conn.
func seedCountingTable(t *testing.T, n int) *sqlConn {
	t.Helper()
	path := filepath.Join(t.TempDir(), "rows.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(`CREATE TABLE nums (n INTEGER)`); err != nil {
		t.Fatal(err)
	}
	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	stmt, err := tx.Prepare(`INSERT INTO nums (n) VALUES (?)`)
	if err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= n; i++ {
		if _, err := stmt.Exec(i); err != nil {
			t.Fatal(err)
		}
	}
	stmt.Close()
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	return &sqlConn{
		db:         db,
		gate:       AssertSQLReadOnly,
		listSQL:    "SELECT name FROM sqlite_master WHERE type='table'",
		quoteIdent: sqliteQuoteIdent,
	}
}

// TestReadTruncationBoundary pins the exact-boundary case Finding 10 says
// is missing: len(rows) == limit. That is the ONLY input on which the
// off-by-one mutation (">" -> ">=") differs — the result is exactly full,
// nothing was dropped, and Truncated must therefore be FALSE. The
// one-under and one-over neighbours are included so the boundary is
// straddled rather than merely touched.
func TestReadTruncationBoundary(t *testing.T) {
	const limit = 5
	cases := []struct {
		rows      int
		wantLen   int
		truncated bool
	}{
		{rows: limit - 1, wantLen: limit - 1, truncated: false},
		{rows: limit, wantLen: limit, truncated: false}, // the boundary
		{rows: limit + 1, wantLen: limit, truncated: true},
	}
	for _, tc := range cases {
		t.Run(fmt.Sprintf("%d rows, limit %d", tc.rows, limit), func(t *testing.T) {
			c := seedCountingTable(t, tc.rows)
			got, err := c.Read(context.Background(), QuerySpec{Raw: "SELECT n FROM nums ORDER BY n"}, limit)
			if err != nil {
				t.Fatal(err)
			}
			if len(got.Rows) != tc.wantLen {
				t.Fatalf("got %d rows, want %d", len(got.Rows), tc.wantLen)
			}
			if got.Truncated != tc.truncated {
				t.Fatalf("Truncated = %v, want %v (%d rows available, limit %d): a result of "+
					"exactly `limit` rows is COMPLETE — nothing was dropped — so reporting it "+
					"as truncated would tell the model its answer is partial when it is whole",
					got.Truncated, tc.truncated, tc.rows, limit)
			}
		})
	}
}

// TestReadAppliesTheLimitClamp pins the clamp where it is actually
// USED, which TestClampReadLimit alone does not: deleting the
// clampReadLimit call from Read would leave that pure test green.
//
// 501 rows is the smallest fixture that separates all three cases from
// each other and from "no clamp at all".
func TestReadAppliesTheLimitClamp(t *testing.T) {
	c := seedCountingTable(t, 501)
	cases := []struct {
		name      string
		limit     int
		wantLen   int
		truncated bool
		why       string
	}{
		{
			name: "unset collapses to the default", limit: 0, wantLen: 500, truncated: true,
			why: "with no clamp, limit 0 returns an empty, truncated result",
		},
		{
			name: "above the cap collapses to the default", limit: 5000, wantLen: 500, truncated: true,
			why: "with no clamp, all 501 rows come back untruncated and the context window is the only limit",
		},
		{
			name: "in-range limit passes through unchanged", limit: 7, wantLen: 7, truncated: true,
			why: "a clamp that rewrote every limit to 500 would break this, so it is what stops the mutant being 'fixed' that way",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := c.Read(context.Background(), QuerySpec{Raw: "SELECT n FROM nums ORDER BY n"}, tc.limit)
			if err != nil {
				t.Fatal(err)
			}
			if len(got.Rows) != tc.wantLen || got.Truncated != tc.truncated {
				t.Fatalf("Read(limit=%d) returned %d rows (Truncated=%v), want %d (Truncated=%v) — %s",
					tc.limit, len(got.Rows), got.Truncated, tc.wantLen, tc.truncated, tc.why)
			}
		})
	}
}

// TestCollectRowsPropagatesColumnsError kills the "cols, _ :=" discard
// (Finding 10). A closed *sql.Rows is the deterministic way to make
// Columns() fail, and it is deliberately the case where rows.Err() does
// NOT report the same problem — measured on go1.27.1:
//
//	after rows.Close():  Columns() -> "sql: Rows are closed"   Err() -> nil
//
// so with the error discarded this function returns (empty Rows, nil): a
// SUCCESSFUL read with no columns and no rows. That is the silent failure
// the discard actually caused; note it is NOT the "expected 0 destination
// arguments" mis-scan it looks like it should cause, because a closed
// *sql.Rows also makes Next() false, so the scan loop never runs (measured
// over 3000 cancelled-context iterations: Columns() failed 1981 times and
// Next() was true 0 of them).
func TestCollectRowsPropagatesColumnsError(t *testing.T) {
	c := seedCountingTable(t, 3)
	rows, err := c.db.QueryContext(context.Background(), "SELECT n FROM nums")
	if err != nil {
		t.Fatal(err)
	}
	if err := rows.Close(); err != nil {
		t.Fatal(err)
	}
	// Pin the premise, so this test cannot quietly decay into one that
	// exercises a healthy *sql.Rows.
	if _, cerr := rows.Columns(); cerr == nil {
		t.Fatal("premise broken: Columns() on a closed *sql.Rows no longer fails")
	}
	if rerr := rows.Err(); rerr != nil {
		t.Fatalf("premise broken: rows.Err() now reports %v, so discarding the Columns() "+
			"error would no longer lose the failure", rerr)
	}

	out, err := collectRows(rows, 10)
	if err == nil {
		t.Fatalf("collectRows swallowed the Columns() error and returned a successful, "+
			"silently empty result: %+v", out)
	}
}

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
		Sort: []QuerySort{{Column: "id", Descending: true}},
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

// TestTrailingLineCommentSurvivesWrapping is final review, Important 5.
//
// pageWrap emitted the whole wrapped statement on ONE line, and inner is
// deliberately NOT stripped of comments — the gate has to see them. So a
// statement the operator ended with a line comment became
//
//	SELECT id FROM events -- logins only) AS wakil_page LIMIT 6 OFFSET 5
//
// where everything after "--" is comment: an unclosed paren and a syntax
// error, on exactly the reads SQLReadIsPageable had just certified as
// pageable. A newline before the closing paren is the whole fix, and it
// covers MySQL's "#" and the pushed-sort path with it.
func TestTrailingLineCommentSurvivesWrapping(t *testing.T) {
	c := newPagingFixture(t)
	ctx := context.Background()

	out, err := c.Read(ctx, QuerySpec{Raw: "SELECT id FROM events -- logins only", Offset: 5}, 5)
	if err != nil {
		t.Fatalf("a trailing line comment must not swallow the wrap: %v", err)
	}
	if got := idsOf(t, out); !reflect.DeepEqual(got, []int64{6, 7, 8, 9, 10}) {
		t.Fatalf("page two = %v", got)
	}

	// The same statement on the pushed-sort path, which is the other half
	// of what pageWrap builds and the one pane_sort's re-query reaches.
	sorted, err := c.Read(ctx, QuerySpec{
		Raw:  "SELECT id FROM events -- logins only",
		Sort: []QuerySort{{Column: "id", Descending: true}},
	}, 3)
	if err != nil {
		t.Fatalf("a pushed sort over a commented statement: %v", err)
	}
	if got := idsOf(t, sorted); !reflect.DeepEqual(got, []int64{12, 11, 10}) {
		t.Fatalf("sorted page one = %v", got)
	}

	// MySQL's other line-comment marker, "#", is NOT covered here: sqlite
	// does not accept it, so this fixture cannot express the case. It is
	// covered against a real MySQL by TestMySQLHashCommentSurvivesWrapping
	// in driver_mysql_test.go, which `make test-live` runs and which that
	// target fails on if it skips.
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
		[]QuerySort{{Column: "id", Descending: true}})
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
	// A second table holding a value that must never be reachable through
	// a forged table name. See the payload comment below for why this
	// table — rather than merely checking that `events` survives — is
	// what makes this test able to fail.
	if _, err := c.db.Exec(`CREATE TABLE secrets (id INTEGER PRIMARY KEY, val TEXT)`); err != nil {
		t.Fatal(err)
	}
	if _, err := c.db.Exec(`INSERT INTO secrets VALUES (999, 'TOPSECRET')`); err != nil {
		t.Fatal(err)
	}

	// quoteIdent is the SOLE guard on this path, exactly as it is on
	// Describe's. The table name arrives from a hover action on a row or
	// from an agent, so an unquoted identifier is how that becomes an
	// injection.
	//
	// This payload is NOT the same shape as Describe's hostile fixture
	// (a lone stray quote, or a bare semicolon), and deliberately so.
	// Describe never wraps its statement, so a stray quote breaking the
	// token is enough to prove the point there. ReadTable's statement is
	// always passed through pageWrap, which appends
	// ") AS wakil_page LIMIT n OFFSET n" after whatever the name
	// contributes — so a payload that merely breaks the token (Describe's
	// shape) produces an unterminated-token parse error EITHER WAY,
	// quoted or not, and proves nothing: measured against
	// modernc.org/sqlite, `events"; DROP TABLE events; --` fails to parse
	// once wrapped regardless of quoteIdent, so the old version of this
	// test passed even with quoting deleted.
	//
	// This payload instead CLOSES pageWrap's own paren, UNIONs in the
	// secrets table, and comments out the rest of the wrap with "--", so
	// that UNQUOTED it is syntactically VALID SQL:
	//
	//   SELECT * FROM (SELECT * FROM events) UNION SELECT id, val FROM
	//   secrets --) AS wakil_page LIMIT 6 OFFSET 0
	//
	// Measured directly against modernc.org/sqlite: that statement runs
	// and returns the events rows unioned with (999, "TOPSECRET") — a
	// real leak, not a syntax error. Quoted through c.quoteIdent, the
	// name instead becomes one well-formed identifier token naming a
	// table that does not exist, and the query fails cleanly with
	// "no such table". So THIS payload can tell the two apart, which is
	// the property the old one lacked.
	payload := `events) UNION SELECT id, val FROM secrets --`
	out, err := c.ReadTable(context.Background(), payload, 5, 0, nil)
	if err == nil {
		t.Fatalf("a bogus table name must fail, got rows: %v", out.Rows)
	}
	for _, row := range out.Rows {
		for _, v := range row {
			if s, ok := v.(string); ok && s == "TOPSECRET" {
				t.Fatalf("the secrets table leaked through: %v", out.Rows)
			}
		}
	}
	var count int
	if err := c.db.QueryRow(`SELECT count(*) FROM events`).Scan(&count); err != nil {
		t.Fatalf("the events table is gone: %v", err)
	}
	if count != 12 {
		t.Fatalf("events has %d rows, want 12 — the injection ran", count)
	}
}

// TestReadTableQuotesTheSortColumn is the sort-column analogue of
// TestReadTableQuotesTheTableName above: quoteIdent is the SOLE guard on
// pageWrap's sort loop too, and the column name arrives from the same two
// places a table name does — a header click or an agent.
//
// It cannot reuse the table-name payload's SHAPE, though, and that is
// worth recording rather than silently copying it. That payload closes
// pageWrap's own "(" and UNIONs a second SELECT into the FROM subquery —
// which works there because the FROM clause's paren is still open at the
// point the name is substituted. The sort column is substituted AFTER
// pageWrap has already closed that paren ("... AS wakil_page ORDER BY
// <column> ..."), and ORDER BY must be the last clause of the whole
// (possibly compound) statement — "ORDER BY x UNION SELECT ..." is
// invalid syntax whether or not the column is quoted, so it would prove
// nothing here.
//
// What DOES survive unquoted at this position is a stacked statement: a
// bare ";" ends pageWrap's own SELECT and opens a second one, and "--"
// comments out the rest of pageWrap's own text (the ASC/DESC literal and
// the LIMIT/OFFSET that follow). Measured directly against
// modernc.org/sqlite: c.db.QueryContext on a semicolon-separated pair of
// statements runs BOTH and returns the SECOND one's result set — not an
// error, and not the first statement's rows. So the payload below,
// unquoted, makes ReadTable return columns ["val"] and the row
// ["TOPSECRET"] instead of events' own ["id","kind"] — a different
// result, not merely different SQL text. Quoted, the whole payload
// becomes one identifier/literal token that pageWrap's ORDER BY does not
// resolve to any real column, and — this was measured too, since
// SQLite's fallback here is a genuine surprise: a double-quoted token
// that names no column is treated as a harmless constant STRING LITERAL
// rather than raising an error, so the sort is silently a no-op and
// events' own rows and columns come back unchanged. Either outcome
// (error or a no-op) is safe; only the leak is not, so that is the one
// thing this test checks for.
func TestReadTableQuotesTheSortColumn(t *testing.T) {
	c := newPagingFixture(t)
	// Same secrets table TestReadTableQuotesTheTableName uses, and the
	// same reason: something that must never be reachable through a
	// forged sort column.
	if _, err := c.db.Exec(`CREATE TABLE secrets (id INTEGER PRIMARY KEY, val TEXT)`); err != nil {
		t.Fatal(err)
	}
	if _, err := c.db.Exec(`INSERT INTO secrets VALUES (999, 'TOPSECRET')`); err != nil {
		t.Fatal(err)
	}

	payload := `id; SELECT val FROM secrets --`
	out, err := c.ReadTable(context.Background(), "events", 5, 0,
		[]QuerySort{{Column: payload}})
	if err != nil {
		// A safe failure is fine (SQLite may also raise "no such column"
		// for a payload shaped differently than this one) — it is not
		// what this test is pinning. What matters is checked below,
		// unconditionally on err.
		return
	}
	for _, row := range out.Rows {
		for _, v := range row {
			if s, ok := v.(string); ok && s == "TOPSECRET" {
				t.Fatalf("the secrets table leaked through: columns=%v rows=%v", out.Columns, out.Rows)
			}
		}
	}
	if len(out.Columns) > 0 && !reflect.DeepEqual(out.Columns, []string{"id", "kind"}) {
		t.Fatalf("the statement executed against the wrong table entirely: columns=%v, want events' own [id kind]", out.Columns)
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

// openTestSQLite opens a fresh, file-backed sqlite sqlConn seeded with an
// "events" table of exactly three rows: (1,'b'), (2,'a'), (3,'a'). The
// kind column alone puts 2 and 3 in the same bucket ('a') — telling them
// apart takes a second sort term, by id — which is exactly the property
// TestPageWrapEmitsEverySortTermInOrder needs: without it, a wrap that
// implemented only the first sort term would still pass.
func openTestSQLite(t *testing.T) *sqlConn {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sorttest.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT)`); err != nil {
		t.Fatal(err)
	}
	for _, row := range [][2]any{{1, "b"}, {2, "a"}, {3, "a"}} {
		if _, err := db.Exec(`INSERT INTO events VALUES (?, ?)`, row[0], row[1]); err != nil {
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

// Two terms, in the order asked for. The single-term case was already
// correct; what could not be expressed at all was "and then by".
func TestPageWrapEmitsEverySortTermInOrder(t *testing.T) {
	conn := openTestSQLite(t)
	rows, err := conn.Read(context.Background(), QuerySpec{
		Raw: "SELECT id, kind FROM events",
		Sort: []QuerySort{
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
	rows, err := conn.Read(context.Background(), QuerySpec{
		Raw:  "SELECT 1",
		Sort: []QuerySort{},
	}, 10)
	if err != nil {
		t.Fatalf("an empty sort must not force a wrap: %v", err)
	}
	if len(rows.Rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows.Rows))
	}
}

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
	if out.Editable.RowKeys[0] != `"id" = 1` {
		t.Fatalf("rowKey[0] = %q", out.Editable.RowKeys[0])
	}

	// A composite key names both columns, in the engine's key order.
	out, err = conn.Read(ctx, QuerySpec{Raw: `SELECT * FROM comp`}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if out.Editable == nil {
		t.Fatalf("composite rowKey = %#v", out.Editable)
	}
	if out.Editable.RowKeys[0] != `"b" = 'k' AND "a" = 7` {
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

// TestEditabilityKeyExclusionIsCaseInsensitive pins a fix from an
// adversarial review's Critical finding: SQL column names are not
// case-sensitive on either engine, but Columns used to be built from
// SQLReadSingleTable's as-typed SELECT list and excluded from it by an
// EXACT string match against PrimaryKey's own spelling. A key column
// typed in a different case than PrimaryKey reported slipped through as
// "writable" — "SELECT ID, kind FROM events" against a key declared "id"
// produced Editable.Columns = [ID kind], and the resulting
// "UPDATE events SET ID = 99 WHERE id = 1" really does change the row's
// identity on sqlite, invalidating every RowKey the read just produced —
// precisely what Editable.Columns' own doc comment says must not happen.
//
// Both directions are pinned: the key declared lowercase and typed
// uppercase, and the reverse. Every asserted Columns entry is also
// checked to appear VERBATIM in out.Columns, since the same bug let
// Columns be built from a list (SQLReadSingleTable's plain) whose
// spelling need not match what the engine actually reported — a grid
// doing a name-keyed lookup against out.Columns would otherwise miss it.
func TestEditabilityKeyExclusionIsCaseInsensitive(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT)`,
		`INSERT INTO events VALUES (1,'a')`,
		`CREATE TABLE events2 ("ID" INTEGER PRIMARY KEY, kind TEXT)`,
		`INSERT INTO events2 VALUES (1,'a')`,
	})
	ctx := context.Background()

	assertKeyExcluded := func(out Rows, key string) {
		t.Helper()
		if out.Editable == nil {
			t.Fatal("should be editable")
		}
		for _, name := range out.Editable.Columns {
			if strings.EqualFold(name, key) {
				t.Fatalf("the key column is writable: %v", out.Editable.Columns)
			}
			verbatim := false
			for _, c := range out.Columns {
				if c == name {
					verbatim = true
				}
			}
			if !verbatim {
				t.Fatalf("%q is not a verbatim entry of out.Columns %v", name, out.Columns)
			}
		}
	}

	// The key is declared "id"; the operator typed "ID".
	out, err := conn.Read(ctx, QuerySpec{Raw: `SELECT ID, kind FROM events`}, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertKeyExcluded(out, "id")
	if len(out.Editable.Columns) != 1 || out.Editable.Columns[0] != "kind" {
		t.Fatalf("columns = %v", out.Editable.Columns)
	}

	// The reverse: the key is declared "ID"; the operator typed "id".
	out, err = conn.Read(ctx, QuerySpec{Raw: `SELECT id, kind FROM events2`}, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertKeyExcluded(out, "id")
	if len(out.Editable.Columns) != 1 || out.Editable.Columns[0] != "kind" {
		t.Fatalf("columns = %v", out.Editable.Columns)
	}
}

// TestEditabilityKeyComparisonIsASCIIOnly pins a fix from an adversarial
// review's Important finding: strings.ToLower performs UNICODE case
// folding, and neither sqlite nor MySQL folds a SQL identifier's case
// beyond ASCII. U+212A KELVIN SIGN is the proof — Unicode calls it the
// same letter as ASCII "k", but the engines do not, so comparing
// identifiers with strings.ToLower conflated two distinct columns and
// built a WHERE predicate from the WRONG column's values: a key
// literally named "K" (U+212A) got matched against an unrelated ordinary
// column "k", and the resulting RowKeys named a different row than the
// one the key actually identifies ("editing row 1 writes row 2").
//
// The fail-open case below is exactly that: the key ("K", U+212A) is not
// present in a result that selected only the unrelated ordinary column
// "k" — this MUST refuse, not silently build RowKeys from "k"'s values.
//
// The fail-safe case is recorded for completeness: under the bug, a
// table carrying BOTH "k" and "K" (U+212A) as ordinary columns lost
// editability entirely through the duplicate-name guard — harmless, but
// wrong. Once folding is ASCII-only (asciiLower, not strings.ToLower),
// they are correctly recognised as two distinct, independently writable
// columns.
func TestEditabilityKeyComparisonIsASCIIOnly(t *testing.T) {
	kelvin := "K" // KELVIN SIGN — Unicode-folds to ASCII "k"; ASCII does not.
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE kelvin ("` + kelvin + `" TEXT PRIMARY KEY, k TEXT, v TEXT)`,
		`INSERT INTO kelvin VALUES ('realkey','decoy','one'), ('decoy','other','two')`,
		`CREATE TABLE dupfold (id INTEGER PRIMARY KEY, k TEXT, "` + kelvin + `" TEXT)`,
		`INSERT INTO dupfold VALUES (1,'a','b')`,
	})
	ctx := context.Background()

	// Fail-open case: the key ("K", U+212A) is absent from a result that
	// selected only the unrelated ordinary column "k" — this MUST refuse,
	// and must NOT build RowKeys from "k"'s values (proved by asserting
	// Editable is nil outright: there is no RowKeys to inspect at all).
	out, err := conn.Read(ctx, QuerySpec{Raw: `SELECT k, v FROM kelvin`}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if out.Editable != nil {
		t.Fatalf("must refuse: the key (U+212A) is not in the result under its own name, got %#v", out.Editable)
	}

	// Fail-safe case, now corrected: "k" and "K" (U+212A) are two
	// distinct ordinary columns and both are writable.
	out, err = conn.Read(ctx, QuerySpec{Raw: `SELECT * FROM dupfold`}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if out.Editable == nil {
		t.Fatalf("dupfold should be editable: %#v", out.Editable)
	}
	if len(out.Editable.Columns) != 2 {
		t.Fatalf(`expected both "k" and "K"(U+212A) as distinct writable columns, got %v`, out.Editable.Columns)
	}
	sawASCII, sawKelvin := false, false
	for _, name := range out.Editable.Columns {
		switch name {
		case "k":
			sawASCII = true
		case kelvin:
			sawKelvin = true
		}
	}
	if !sawASCII || !sawKelvin {
		t.Fatalf("expected both distinct spellings among %v", out.Editable.Columns)
	}
}

// TestEmptyResultMarshalsRowsAsArrayNotNull pins the shape of a zero-row
// read as an MCP CLIENT sees it, which is the only place the difference is
// visible: in Go, a nil [][]any and an empty one behave identically, so a
// test that asserts on the struct cannot catch this at all. It has to
// marshal.
//
// **The bug this exists against was live and cost an agent six retries.**
// Reading a genuinely empty table returned `"rows": null`, and null is not
// how a reader spells "zero rows" — it is how it spells "no answer". The
// agent read a successful, complete, empty result as a failed read, tried
// `read_table`, `query` and a fresh pane in turn, and reported the table as
// unreadable. Nothing had failed; the table had no rows.
//
// This is the same rule Rows.Pageable already states for itself ("a reader
// (including an LLM) must not have to tell 'cannot be paged' apart from
// 'this server is too old to say'"), and the same one the list_databases
// and list_tables descriptions spell out in prose. Rows and Columns are
// the two fields that carry it for a result.
//
// Columns is asserted alongside Rows because a zero-row read still knows
// its columns — losing them would turn "this table is empty" into "this
// table has no shape", which is the failure the collectRows comment above
// describes surviving once already.
func TestEmptyResultMarshalsRowsAsArrayNotNull(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE empty (id INTEGER PRIMARY KEY, v TEXT)`,
	})
	out, err := conn.Read(context.Background(),
		QuerySpec{Raw: "SELECT * FROM empty"}, 100)
	if err != nil {
		t.Fatalf("reading an empty table is not an error: %v", err)
	}
	blob, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	var seen map[string]json.RawMessage
	if err := json.Unmarshal(blob, &seen); err != nil {
		t.Fatal(err)
	}
	if got := string(seen["rows"]); got != "[]" {
		t.Errorf("rows = %s, want [] — null reads as \"no answer\", not \"no rows\"", got)
	}
	if got := string(seen["columns"]); got != `["id","v"]` {
		t.Errorf("columns = %s, want [\"id\",\"v\"] — an empty result still has a shape", got)
	}
}

// TestEmptyMongoResultMarshalsRowsAsArrayNotNull is the same contract for
// the driver that builds its Rows somewhere else entirely. docsToRows is
// pure — it takes decoded documents, not a connection — so the empty case
// is reachable without a Mongo server, which is what makes this one part
// of the DEFAULT suite rather than of test-live.
//
// Mongo needs its own test because it is strictly worse off than SQL here:
// it derives Columns from the documents themselves, so zero documents means
// zero columns, and BOTH fields were nil. A SQL driver at least still had
// its column list.
func TestEmptyMongoResultMarshalsRowsAsArrayNotNull(t *testing.T) {
	blob, err := json.Marshal(docsToRows(nil, 100, 0))
	if err != nil {
		t.Fatal(err)
	}
	var seen map[string]json.RawMessage
	if err := json.Unmarshal(blob, &seen); err != nil {
		t.Fatal(err)
	}
	if got := string(seen["rows"]); got != "[]" {
		t.Errorf("rows = %s, want []", got)
	}
	if got := string(seen["columns"]); got != "[]" {
		t.Errorf("columns = %s, want []", got)
	}
}

// TestReadOffersNoEditWhenTheDatabaseCannotBeWritten is the regression for
// a surface that lied. Reading a table in a database with no writeRef
// returned a full Editable block, so the pane's footer said "editable",
// the hover outline appeared, a double-click opened an editor and typing
// Enter got `database "core" is not configured for writing` from
// OpenDatabaseWritable — the first and only moment anything said no.
//
// design-language.md §8: a surface which cannot do the thing must not look
// like it can. describeEditability answers a STRUCTURAL question (one
// table, a primary key, that key present in the result) and structure is
// not the only thing that can refuse an edit.
//
// The writable field is checked here rather than writeGate, which is nil
// on EVERY read connection by construction (see sqlConn.writeGate) and so
// cannot distinguish these two cases at all.
func TestReadOffersNoEditWhenTheDatabaseCannotBeWritten(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT)`,
		`INSERT INTO events VALUES (1, 'click')`,
	})
	// What OpenDatabase produces for a database configured with no
	// writeRef — everything else about the connection is unchanged.
	conn.writable = false

	out, err := conn.Read(context.Background(),
		QuerySpec{Raw: "SELECT * FROM events"}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if out.Editable != nil {
		t.Errorf("a database with no write credential must offer no edit, got %#v",
			out.Editable)
	}
}

// The converse, so the guard above cannot be over-tightened into refusing
// every edit. A structurally editable result in a database that DOES carry
// a write credential still says so — this is the case that works today and
// must keep working.
func TestReadStillOffersAnEditWhenTheDatabaseCanBeWritten(t *testing.T) {
	conn := newSQLiteTestConn(t, []string{
		`CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT)`,
		`INSERT INTO events VALUES (1, 'click')`,
	})
	conn.writable = true

	out, err := conn.Read(context.Background(),
		QuerySpec{Raw: "SELECT * FROM events"}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if out.Editable == nil {
		t.Fatal("a keyed single-table read of a writable database is editable")
	}
	if len(out.Editable.RowKeys) != 1 {
		t.Errorf("rowKeys = %v, want one", out.Editable.RowKeys)
	}
}
