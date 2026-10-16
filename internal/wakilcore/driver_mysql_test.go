package wakilcore

import (
	"context"
	"database/sql"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

// Requires: docker run -d --name wakil-mysql-test -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=app -p 3307:3306 mysql:8
// Then: export WAKIL_MYSQL_DSN='root:root@tcp(127.0.0.1:3307)/app'
func TestMySQLReadAndGate(t *testing.T) {
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
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT name FROM customers WHERE id=42"}, 10)
	if err != nil || len(rows.Rows) != 1 || rows.Rows[0][0] != "Layla" {
		t.Fatalf("bad read: %+v %v", rows, err)
	}
	if err := d.AssertReadOnly(QuerySpec{Raw: "UPDATE customers SET name='x'"}); err == nil {
		t.Fatal("must reject write")
	}
}

// TestMySQLReadReportsListsTables pins ListsTables in both directions
// against a real engine. sqlite cannot run SHOW TABLES at all (see
// TestReadReportsListsTablesFromTheRawText in sqlconn_test.go, which can
// therefore only pin the false direction), so the true direction — a
// genuine SHOW TABLES coming back through sqlConn.Read with
// ListsTables == true — is only provable here, against MySQL.
func TestMySQLReadReportsListsTables(t *testing.T) {
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

	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	tables, err := conn.Read(context.Background(), QuerySpec{Raw: "SHOW TABLES"}, 10)
	if err != nil {
		t.Fatalf("SHOW TABLES: %v", err)
	}
	if !tables.ListsTables {
		t.Fatal("SHOW TABLES must report ListsTables true")
	}

	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT id FROM customers"}, 10)
	if err != nil {
		t.Fatalf("SELECT: %v", err)
	}
	if rows.ListsTables {
		t.Fatal("a SELECT must not claim to list tables")
	}
}

// TestMySQLEngineLevelReadOnly proves the MySQL connection itself refuses a
// write, independent of the AssertSQLReadOnly gate, per resolution 2: the
// DSN carries transaction_read_only=1 (applied by go-sql-driver/mysql to
// every new pooled connection), not a one-shot "SET SESSION" statement
// that only reaches a single connection out of the pool. It reaches the
// underlying *sql.DB directly (bypassing the gate in sqlConn.Read) to
// confirm the connection was opened read-only at the engine level.
// TestMySQLHashCommentSurvivesWrapping is the MySQL half of the wrapping
// fix (final review, Important 5), and it is here rather than beside its
// sqlite sibling because sqlite does not accept "#" as a comment
// introducer at all — a fixture that cannot express the case cannot test
// it. `make test-live` runs this (it matches TestMySQL) and fails if it
// skips, so the coverage is real rather than nominal.
//
// The failure it pins: pageWrap emitted the wrap on one line, so
// "SELECT id FROM customers # recent" wrapped into a statement whose
// closing paren sat inside the comment. The newline before the paren is
// what fixes it, and it is dialect-independent for the reason this test
// exists to confirm on a second dialect: every SQL line comment ends at a
// newline.
func TestMySQLHashCommentSurvivesWrapping(t *testing.T) {
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
	for i := 1; i <= 12; i++ {
		if _, err := raw.Exec("INSERT INTO customers VALUES (?,?)", i, fmt.Sprintf("n%d", i)); err != nil {
			t.Fatal(err)
		}
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

	// Page two of a statement the operator ended with a "#" comment. The
	// gate permits the comment — it is an ordinary one, not an executable
	// or introducer bypass — so the wrap is what has to survive it.
	const stmt = "SELECT id FROM customers ORDER BY id # recent only"
	rows, err := conn.Read(context.Background(), QuerySpec{Raw: stmt, Offset: 5}, 5)
	if err != nil {
		t.Fatalf("a trailing # comment must not swallow the wrap: %v", err)
	}
	var got []int64
	for _, r := range rows.Rows {
		n, ok := r[0].(int64)
		if !ok {
			t.Fatalf("first column is %T, not int64", r[0])
		}
		got = append(got, n)
	}
	if !reflect.DeepEqual(got, []int64{6, 7, 8, 9, 10}) {
		t.Fatalf("page two = %v", got)
	}

	// And the same statement on the pushed-sort path, which is the other
	// branch pageWrap builds and the one pane_sort's re-query reaches.
	sorted, err := conn.Read(context.Background(),
		QuerySpec{Raw: stmt, Sort: []QuerySort{{Column: "id", Descending: true}}}, 3)
	if err != nil {
		t.Fatalf("a pushed sort over a # commented statement: %v", err)
	}
	if len(sorted.Rows) != 3 || sorted.Rows[0][0] != int64(12) {
		t.Fatalf("sorted page one = %+v", sorted.Rows)
	}
}

func TestMySQLEngineLevelReadOnly(t *testing.T) {
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
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	sc, ok := conn.(*sqlConn)
	if !ok {
		t.Fatalf("expected *sqlConn, got %T", conn)
	}
	// Bypass AssertSQLReadOnly entirely and hit the engine directly.
	_, err = sc.db.ExecContext(context.Background(), "INSERT INTO customers VALUES (99,'Hacker')")
	if err == nil {
		t.Fatal("expected engine to reject write on read-only connection")
	}
	t.Logf("engine-level read-only rejection: %v", err)
}

// TestMySQLQuoteIdentAndDescribe proves Describe works at all against a
// live MySQL server (the call that would panic outright with a nil
// quoteIdent field, since the brief's sqlConn literal omits it), and that
// the quoting doubles embedded backticks so a hostile identifier cannot
// terminate the identifier early, per resolution 1.
func TestMySQLQuoteIdentAndDescribe(t *testing.T) {
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
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// Describe must work at all on the seeded table (this is the call
	// that would panic with a nil quoteIdent field).
	sch, err := conn.Describe(context.Background(), "customers")
	if err != nil {
		t.Fatalf("describe failed: %v", err)
	}
	if len(sch.Columns) != 2 {
		t.Fatalf("expected 2 columns, got %+v", sch.Columns)
	}

	// A hostile name containing a backtick must not be able to terminate
	// the identifier early and inject SQL.
	hostile := "customers` ; DROP TABLE customers -- "
	if _, err := conn.Describe(context.Background(), hostile); err == nil {
		t.Fatal("expected Describe to fail for hostile/unknown table name")
	}

	// customers must still exist and be readable.
	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT name FROM customers WHERE id=42"}, 10)
	if err != nil {
		t.Fatalf("customers table should still exist: %v", err)
	}
	if len(rows.Rows) != 1 || rows.Rows[0][0] != "Layla" {
		t.Fatalf("expected customers to be intact: %+v", rows)
	}
}

// TestMySQLConnectRedactsPassword pins what each of Connect's two
// DSN-error paths actually guarantees, which is NOT the same thing on
// both — the previous version of this test asserted only "the password
// is absent from the message" on both, and could not fail on either.
// Measured, with password "s3cr3t-not-real":
//
//	mysql.ParseDSN  -> "invalid DSN: missing the slash separating the
//	                    database name"                (contains pw: false)
//	db.PingContext  -> "dial tcp 127.0.0.1:1: connect: connection refused"
//	                                                  (contains pw: false)
//
// Neither raw driver error carried the password, so deleting the
// redaction left the old assertions green. What each path really owes
// its caller is pinned separately below.
func TestMySQLConnectRedactsPassword(t *testing.T) {
	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}

	// The parse path interpolates NO underlying error text at all, which
	// is the actual defence: mysql.ParseDSN quotes whichever fragment of
	// the DSN it choked on, and which fragment that is, is the driver's
	// choice and can change between versions. An exact-message assertion
	// is the only one that can fail if someone appends err.Error() here
	// "for debuggability" — a substring or absence check would not.
	t.Run("malformed DSN carries no driver text", func(t *testing.T) {
		const password = "s3cr3t-not-real"
		malformed := "user:" + password + "@badformat"
		_, err := d.Connect(context.Background(), Connection{URL: malformed})
		if err == nil {
			t.Fatal("expected error for malformed DSN")
		}
		msg, ok := IsUserError(err)
		if !ok {
			t.Fatalf("expected UserError, got %v (%T)", err, err)
		}
		if msg != "cannot parse mysql connection string" {
			t.Fatalf("the parse path must surface no driver text at all, got %q", msg)
		}
	})

	// The ping path DOES interpolate the driver's error, so it runs it
	// through redactPassword — and this subtest makes that sanitiser
	// fire. The password is "127.0.0.1", chosen because the dial error
	// contains that string: a password is an arbitrary secret and nothing
	// stops it coinciding with text the driver echoes. Asserting the
	// "[redacted]" marker APPEARED is what makes this test able to fail;
	// with the redaction deleted the raw address comes through and both
	// assertions below break.
	t.Run("unreachable DSN redacts a password present in the error", func(t *testing.T) {
		const password = "127.0.0.1"
		unreachable := "user:" + password + "@tcp(127.0.0.1:1)/db"
		_, err := d.Connect(context.Background(), Connection{URL: unreachable})
		if err == nil {
			t.Fatal("expected error for unreachable DSN")
		}
		msg, ok := IsUserError(err)
		if !ok {
			t.Fatalf("expected UserError, got %v (%T)", err, err)
		}
		if !strings.Contains(msg, "[redacted]") {
			t.Fatalf("the password sanitiser did not fire on the ping error: %q", msg)
		}
		if strings.Contains(msg, password) {
			t.Fatalf("error message leaked password: %q", msg)
		}
	})
}

// --- Fix round: DSN-borne bypasses of the read-only guarantee. ---

// TestHardenMySQLConfigNeutralisesHostileDSN pins the rewrite Connect
// applies to every stored DSN. It needs no live server because it works
// on the parsed config, which is exactly what Connect hands the driver.
//
// The DSN below is not hypothetical: `wakil secrets set <ref>` accepts an
// arbitrary DSN on stdin (cmd/wakil/main.go documents that path), so
// every parameter here is something an operator — or anything that can
// write a Keychain item — can put in front of this driver.
func TestHardenMySQLConfigNeutralisesHostileDSN(t *testing.T) {
	const hostile = "u:p@tcp(h:3306)/db?multiStatements=true&allowAllFiles=true&clientFoundRows=true" +
		"&autocommit=1%2C%20transaction_read_only%3D0&wait_timeout=100%2C%20transaction_read_only%3D0"
	cfg, err := mysql.ParseDSN(hostile)
	if err != nil {
		t.Fatalf("ParseDSN: %v", err)
	}
	// Guard: if the driver ever stops honouring these DSN keys, this test
	// would silently stop proving anything, so assert the hostile input
	// really did arrive hostile before asserting it was neutralised.
	if !cfg.MultiStatements || !cfg.AllowAllFiles {
		t.Fatalf("fixture no longer parses as hostile: multi=%v allowAllFiles=%v", cfg.MultiStatements, cfg.AllowAllFiles)
	}
	for _, key := range []string{"autocommit", "wait_timeout"} {
		if got := cfg.Params[key]; !strings.Contains(got, ", transaction_read_only=0") {
			t.Fatalf("fixture no longer carries the SET-injection payload under %q, got %q", key, got)
		}
	}

	hardenMySQLConfig(cfg)

	if cfg.MultiStatements {
		t.Error("MultiStatements survived: a single query string could carry several statements")
	}
	if cfg.AllowAllFiles {
		t.Error("AllowAllFiles survived: the server could ask this client for any readable file")
	}
	if len(cfg.Params) != 1 || cfg.Params["transaction_read_only"] != "1" {
		// The injection matters more than the individual keys: the driver
		// concatenates Params raw into one "SET k = v, ..." statement, so
		// any surviving parameter value can append its own assignment.
		t.Errorf("Params must be exactly transaction_read_only=1, got %v", cfg.Params)
	}
	// Non-Params fields the DSN legitimately owns must survive, or this
	// would be "safe" by discarding the connection itself.
	if cfg.User != "u" || cfg.Passwd != "p" || cfg.Addr != "h:3306" || cfg.DBName != "db" {
		t.Errorf("connection identity was mangled: %+v", cfg)
	}
	if !strings.Contains(cfg.FormatDSN(), "transaction_read_only=1") {
		t.Errorf("formatted DSN lost the read-only marker: %s", cfg.FormatDSN())
	}
}

// TestHardenMySQLConfigPinsCharset is the regression test for the charset
// injection code review found: a DSN carrying a charset whose multi-byte
// trailing byte can equal 0x5C (gbk here; the same class covers big5,
// sjis, cp932, gb18030, gb2312 — precisely go-sql-driver's own
// unsafeCollations, v1.10.1 collations.go) makes mysqlQuoteLiteral's
// backslash doubling unsafe: the doubled byte can be read as pairing with
// the PRECEDING byte as one character instead of as an escape. See
// pinMySQLCharset's doc comment for the measured live exploit against
// this exact charset.
//
// mysql.Config's charset field (cfg.charsets) is unexported, so this test
// cannot inspect it directly and instead asserts against cfg.FormatDSN(),
// the same surface sql.Open is actually handed — and the same surface
// TestHardenMySQLConfigNeutralisesHostileDSN already asserts Params
// against.
func TestHardenMySQLConfigPinsCharset(t *testing.T) {
	const hostile = "u:p@tcp(h:3306)/db?charset=gbk&collation=gbk_chinese_ci"

	for _, tc := range []struct {
		name   string
		harden func(*mysql.Config)
	}{
		{"read", hardenMySQLConfig},
		{"write", hardenMySQLWriteConfig},
	} {
		cfg, err := mysql.ParseDSN(hostile)
		if err != nil {
			t.Fatalf("%s: ParseDSN: %v", tc.name, err)
		}
		// Guard: prove the fixture really did arrive hostile before
		// asserting it was neutralised, the same discipline
		// TestHardenMySQLConfigNeutralisesHostileDSN applies.
		if cfg.Collation != "gbk_chinese_ci" || !strings.Contains(cfg.FormatDSN(), "charset=gbk") {
			t.Fatalf("%s: fixture no longer parses as hostile: collation=%q dsn=%q",
				tc.name, cfg.Collation, cfg.FormatDSN())
		}

		tc.harden(cfg)

		if cfg.Collation != "" {
			t.Errorf("%s: Collation survived hardening: %q", tc.name, cfg.Collation)
		}
		dsn := cfg.FormatDSN()
		if strings.Contains(dsn, "gbk") {
			t.Errorf("%s: the gbk charset/collation survived hardening: %s", tc.name, dsn)
		}
		if !strings.Contains(dsn, "charset=utf8mb4") {
			t.Errorf("%s: charset was not pinned to utf8mb4: %s", tc.name, dsn)
		}
	}
}

// TestMySQLSetInjectionCannotDisableReadOnly is the live half of the
// test above: a DSN whose parameter VALUE injects a second assignment
// into the driver's connection-time "SET" statement must not be able to
// turn transaction_read_only back off.
//
// It loops 200 times, and both the loop and its length are the point.
// The pre-fix failure is intermittent by nature: the driver emits the
// assignments by ranging cfg.Params, Go randomises map iteration, and the
// injected "transaction_read_only=0" only wins when it lands AFTER this
// driver's own "transaction_read_only=1" in that one statement.
//
// The rate was measured, not guessed. With this test looping only 12
// times, a build carrying the pre-fix behaviour escaped 5 times out of 20
// runs — a per-iteration detection rate of roughly 1 in 8, which matches
// Go's small-map iteration picking a random start slot among 8 rather
// than shuffling. At that rate 200 iterations reduce the chance of a
// broken build slipping through to about 1e-12. Two injected parameters
// are used, one sorting before "transaction_read_only" and one after, so
// neither the driver's DSN key sorting nor its map layout can line them
// both up on the harmless side. Re-measured with that fixture and this
// loop count: the same broken build was caught 20 out of 20 runs.
//
// The deterministic guard for this is TestHardenMySQLConfigNeutralisesHostileDSN;
// this test is the proof that the guard is about a real engine behaviour.
func TestMySQLSetInjectionCannotDisableReadOnly(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	hostile := dsn + "?autocommit=1%2C%20transaction_read_only%3D0" +
		"&wait_timeout=100%2C%20transaction_read_only%3D0"

	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 500; i++ {
		conn, err := d.Connect(context.Background(), Connection{URL: hostile})
		if err != nil {
			t.Fatalf("connect %d: %v", i, err)
		}
		sc, ok := conn.(*sqlConn)
		if !ok {
			conn.Close()
			t.Fatalf("expected *sqlConn, got %T", conn)
		}
		var readOnly string
		if err := sc.db.QueryRow("SELECT @@session.transaction_read_only").Scan(&readOnly); err != nil {
			conn.Close()
			t.Fatalf("read @@session.transaction_read_only on iteration %d: %v", i, err)
		}
		if readOnly != "1" {
			conn.Close()
			t.Fatalf("iteration %d: the DSN turned the engine-level read-only guarantee off (@@session.transaction_read_only=%s)", i, readOnly)
		}
		// Belt and braces: ask the engine directly, bypassing the SQL gate.
		_, werr := sc.db.ExecContext(context.Background(), "CREATE TABLE IF NOT EXISTS wakil_set_injection_probe (id INT)")
		conn.Close()
		if werr == nil {
			t.Fatalf("iteration %d: a write succeeded through a connection that is supposed to be read-only", i)
		}
	}
	// The write must never have happened, on any iteration.
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	var n int
	if err := raw.QueryRow("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'wakil_set_injection_probe'").Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		raw.Exec("DROP TABLE wakil_set_injection_probe")
		t.Fatal("the probe table exists: a write got through the read-only connection")
	}
}

// TestMySQLPrimaryKey pins sqlConn.PrimaryKey against a real MySQL server,
// the composite/declaration-order counterpart to TestSQLitePrimaryKey: a
// single-column key, a key whose reported order is the engine's key order
// rather than the declaration order, a keyless table, a UNIQUE NOT NULL
// column (which is not a primary key and must not be reported), and a
// table that does not exist at all.
func TestMySQLPrimaryKey(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	for _, stmt := range []string{
		`DROP TABLE IF EXISTS pk_ints`,
		`CREATE TABLE pk_ints (id INT PRIMARY KEY, v VARCHAR(10))`,
		`DROP TABLE IF EXISTS pk_comp`,
		`CREATE TABLE pk_comp (a INT, b VARCHAR(20), c INT, PRIMARY KEY (b, a))`,
		`DROP TABLE IF EXISTS pk_none`,
		`CREATE TABLE pk_none (x INT)`,
		`DROP TABLE IF EXISTS pk_uniq`,
		`CREATE TABLE pk_uniq (u VARCHAR(20) UNIQUE NOT NULL)`,
	} {
		if _, err := raw.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
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

// TestMySQLEditabilityRowKeysMatchExactlyOneRow proves literalFor's MySQL
// path end to end against a live server, for the three cases unit tests
// (which stub quoteLiteral) cannot: a composite key, a TEXT key holding a
// quote, and a VARBINARY key holding both a quote and a backslash under
// MySQL 8's default (backslash-escaping) sql_mode.
//
// It does not stop at asserting the rendered predicate's text — go/sql's
// scan and MySQL's own parse of that same text are both in the loop —
// TestSQLite already covers the shape of the rule, and what a live
// counterpart adds is running the predicate as a real WHERE clause
// against a real row and checking exactly one row moved. Each table
// carries a second row chosen to collide under the escaping bug this
// would catch (same key characters, wrong escaping merges them).
func TestMySQLEditabilityRowKeysMatchExactlyOneRow(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	for _, stmt := range []string{
		`DROP TABLE IF EXISTS edit_comp`,
		`CREATE TABLE edit_comp (a INT, b VARCHAR(20), v VARCHAR(20), PRIMARY KEY (b, a))`,
		`DROP TABLE IF EXISTS edit_quote`,
		`CREATE TABLE edit_quote (k VARCHAR(20) PRIMARY KEY, v VARCHAR(20))`,
		`DROP TABLE IF EXISTS edit_bin`,
		`CREATE TABLE edit_bin (k VARBINARY(20) PRIMARY KEY, v VARCHAR(20))`,
	} {
		if _, err := raw.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	// Every value below goes in through a bound parameter, never through
	// Go source text concatenated into SQL, so what lands in the table is
	// exactly the byte sequence named here regardless of MySQL's own
	// literal-quoting rules.
	if _, err := raw.Exec(`INSERT INTO edit_comp (a, b, v) VALUES (?, ?, 'first'), (?, ?, 'second')`,
		7, "k", 8, "k2"); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`INSERT INTO edit_quote (k, v) VALUES (?, 'first'), (?, 'second')`,
		"a'b", "ab"); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`INSERT INTO edit_bin (k, v) VALUES (?, 'first'), (?, 'second')`,
		[]byte("a'\\b"), []byte("plain")); err != nil {
		t.Fatal(err)
	}

	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	// Writable: true, because describeEditability (sqlconn.go) returns
	// at its FIRST line when the connection is not writable — a
	// database with no write credential must not advertise an editor
	// it can never honour. Without it Editable came back nil and this
	// test failed for a reason that had nothing to do with what it
	// measures; it shipped that way in 4eb85f1 and was found by the
	// 2c-ii-b walk (defect D5), not by anything that ran in CI, since
	// `make test` cannot reach a live MySQL at all.
	conn, err := d.Connect(context.Background(), Connection{URL: dsn, Writable: true})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx := context.Background()

	check := func(table string) {
		t.Helper()
		// The row named 'first' is the one this table's key was chosen
		// to make interesting; WHERE v = 'first' finds it independently
		// of RowKeys, so this test never trusts the thing it is proving.
		out, err := conn.Read(ctx, QuerySpec{Raw: "SELECT * FROM " + table + " WHERE v = 'first'"}, 10)
		if err != nil {
			t.Fatalf("%s: read: %v", table, err)
		}
		if out.Editable == nil || len(out.Editable.RowKeys) != 1 {
			t.Fatalf("%s: not editable: %#v", table, out.Editable)
		}
		predicate := out.Editable.RowKeys[0]
		res, err := raw.ExecContext(ctx, "UPDATE "+table+" SET v = 'updated' WHERE "+predicate)
		if err != nil {
			t.Fatalf("%s: UPDATE %s: %v", table, predicate, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			t.Fatal(err)
		}
		if n != 1 {
			t.Fatalf("%s: predicate %q matched %d rows, want 1", table, predicate, n)
		}
		var untouched int
		if err := raw.QueryRowContext(ctx,
			"SELECT COUNT(*) FROM "+table+" WHERE v = 'second'").Scan(&untouched); err != nil {
			t.Fatal(err)
		}
		if untouched != 1 {
			t.Fatalf("%s: predicate %q also touched the OTHER row", table, predicate)
		}
	}
	check("edit_comp")
	check("edit_quote")
	check("edit_bin")
}

// TestMySQLEditableColumnsExcludeBIT is the live half of the final review's
// finding 2: describeEditability (sqlconn.go) excludes a column from
// Editable.Columns when its declared type is one uneditableTypePrefixes
// (updatestmt.go) names, checked against a REAL BIT(1) column rather than
// assumed from the type name alone.
//
// A quoted literal into BIT(1) is Error 1406 "Data too long" — measured in
// RenderUpdate's own probe — so RenderUpdate already refuses to compose an
// UPDATE against one. That refusal alone was not enough: before this fix,
// describeEditability never read out.ColumnTypes, so a BIT column still
// came back in Editable.Columns — the grid would hover the cell, open an
// editor, accept a value, and only THEN learn from RenderUpdate that none
// of that could ever commit. This proves the exclusion now happens at read
// time, one step before the grid offers the affordance at all, and that it
// costs nothing else: an ordinary VARCHAR neighbour must still come back
// writable.
func TestMySQLEditableColumnsExcludeBIT(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	for _, stmt := range []string{
		`DROP TABLE IF EXISTS edit_bit`,
		`CREATE TABLE edit_bit (id INT PRIMARY KEY, flag BIT(1), name VARCHAR(20))`,
	} {
		if _, err := raw.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	if _, err := raw.Exec(`INSERT INTO edit_bit (id, flag, name) VALUES (1, b'1', 'first')`); err != nil {
		t.Fatal(err)
	}

	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	// Writable: true, because describeEditability (sqlconn.go) returns
	// at its FIRST line when the connection is not writable — a
	// database with no write credential must not advertise an editor
	// it can never honour. Without it Editable came back nil and this
	// test failed for a reason that had nothing to do with what it
	// measures; it shipped that way in 4eb85f1 and was found by the
	// 2c-ii-b walk (defect D5), not by anything that ran in CI, since
	// `make test` cannot reach a live MySQL at all.
	conn, err := d.Connect(context.Background(), Connection{URL: dsn, Writable: true})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx := context.Background()

	out, err := conn.Read(ctx, QuerySpec{Raw: "SELECT * FROM edit_bit WHERE id = 1"}, 10)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if out.Editable == nil {
		t.Fatalf("not editable: %#v", out.Editable)
	}
	var sawBit, sawName bool
	for _, col := range out.Editable.Columns {
		switch col {
		case "flag":
			sawBit = true
		case "name":
			sawName = true
		}
	}
	if sawBit {
		t.Fatalf("Editable.Columns includes the BIT column %q: %v", "flag", out.Editable.Columns)
	}
	if !sawName {
		t.Fatalf("Editable.Columns dropped its VARCHAR neighbour %q too: %v",
			"name", out.Editable.Columns)
	}
}

// removeServerFileOnCleanup schedules best-effort deletion of a file this
// test caused MySQL to write on the DATABASE HOST.
//
// A test that proves "this payload really writes a file, and the gate is
// the only thing stopping it" has to actually make the server write one.
// There is no SQL that deletes it again — SELECT ... INTO OUTFILE creates,
// LOAD_FILE reads, and neither the client nor the server offers a remove —
// so before this helper existed every run left another file behind in
// secure_file_priv, permanently, with a unique UnixNano name so they
// accumulated rather than being overwritten.
//
// Reaching the file means reaching the database host's filesystem, which
// only the operator can describe. make test-live sets
// WAKIL_MYSQL_CONTAINER in the path where it started the container itself;
// when the connection details were overridden the engine belongs to the
// caller and this says so rather than guessing. Failures are logged, never
// fatal: leaving a stray probe file is untidy, not a reason to fail a test
// whose subject is the read-only gate.
func removeServerFileOnCleanup(t *testing.T, path string) {
	t.Helper()
	t.Cleanup(func() {
		container := os.Getenv("WAKIL_MYSQL_CONTAINER")
		if container == "" {
			t.Logf("left %s on the database host; set WAKIL_MYSQL_CONTAINER "+
				"(make test-live does, when it started the container) to have "+
				"probe files removed automatically", path)
			return
		}
		if out, err := exec.Command("docker", "exec", container,
			"rm", "-f", path).CombinedOutput(); err != nil {
			t.Logf("could not remove %s from container %s: %v: %s",
				path, container, err, strings.TrimSpace(string(out)))
		}
	})
}

// TestMySQLDoubleDashOutfileBypassIsBlocked is the live half of
// TestAssertSQLReadOnly_MySQLDoubleDashIsNotAlwaysAComment: it proves
// against a real server that (a) the payload the gate used to allow is
// genuinely live SQL that really writes a file on the DATABASE HOST, and
// (b) the same payload through the gated read path is refused and no file
// appears.
//
// Half (a) is what makes this test non-vacuous. A test that only asserted
// "conn.Read returns an error" would pass just as happily against a
// server that rejected the statement for its own reasons, or against a
// gate that rejects everything; here the raw driver executes the same
// statement first, and LOAD_FILE proves the file materialised.
func TestMySQLDoubleDashOutfileBypassIsBlocked(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()

	var dir string
	if err := raw.QueryRow("SELECT @@secure_file_priv").Scan(&dir); err != nil || dir == "" {
		t.Skipf("server has no writable secure_file_priv directory (err=%v, dir=%q)", err, dir)
	}
	// Unique per run: INTO OUTFILE refuses to overwrite, and -count=2
	// runs this twice in one process.
	stamp := time.Now().UnixNano()
	proof := fmt.Sprintf("%sdd_proof_%d.txt", dir, stamp)
	blocked := fmt.Sprintf("%sdd_blocked_%d.txt", dir, stamp)
	removeServerFileOnCleanup(t, proof)
	removeServerFileOnCleanup(t, blocked)

	// The premise: MySQL parses "1--1" as 1 - (-1), NOT as a comment.
	var parsed int
	if err := raw.QueryRow("SELECT 1--1").Scan(&parsed); err != nil {
		t.Fatalf("SELECT 1--1: %v", err)
	}
	if parsed != 2 {
		t.Fatalf("this server does not parse 1--1 as arithmetic (got %d); the bypass this test pins does not apply to it", parsed)
	}

	// (a) The payload really writes a file when it reaches the server.
	if _, err := raw.Exec("SELECT 1--1 INTO OUTFILE '" + proof + "'"); err != nil {
		t.Skipf("cannot write an OUTFILE on this server (%v); nothing to prove the gate against", err)
	}
	var wrote bool
	if err := raw.QueryRow("SELECT LOAD_FILE(?) IS NOT NULL", proof).Scan(&wrote); err != nil {
		t.Fatal(err)
	}
	if !wrote {
		t.Fatalf("expected %s to exist after the raw driver wrote it", proof)
	}

	// (b) The same payload through the gated read path is refused, with
	// the message the write-keyword scan produces (INTO), not some other
	// incidental failure.
	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	_, rerr := conn.Read(context.Background(), QuerySpec{Raw: "SELECT 1--1 INTO OUTFILE '" + blocked + "'"}, 10)
	if rerr == nil {
		t.Fatal("the read-only gate allowed SELECT 1--1 INTO OUTFILE")
	}
	msg, ok := IsUserError(rerr)
	if !ok || msg != "query contains a write operation and was blocked (read-only)" {
		t.Fatalf("unexpected rejection: %T %q", rerr, msg)
	}
	var appeared bool
	if err := raw.QueryRow("SELECT LOAD_FILE(?) IS NOT NULL", blocked).Scan(&appeared); err != nil {
		t.Fatal(err)
	}
	if appeared {
		t.Fatalf("a file (%s) was written on the database host by a read-only tool", blocked)
	}

	// And the multi-statement variant, caught by a different check.
	_, rerr = conn.Read(context.Background(), QuerySpec{Raw: "SELECT 1--1; DROP TABLE customers"}, 10)
	msg, ok = IsUserError(rerr)
	if !ok || msg != "multiple statements are not allowed in read-only mode" {
		t.Fatalf("unexpected rejection for the multi-statement variant: %T %q", rerr, msg)
	}
}

// TestMySQLGenuineDoubleDashQueriesStillWork is the anti-over-rejection
// half: the fix must not have turned "--" into a token the gate simply
// refuses. Each query below runs through the gated read path against the
// real server and must return the value MySQL itself computes for it.
func TestMySQLGenuineDoubleDashQueriesStillWork(t *testing.T) {
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

	cases := []struct {
		name string
		sql  string
		want string
	}{
		{"genuine line comment", "SELECT 1 AS v -- a comment", "1"},
		{"arithmetic double minus", "SELECT 10--5 AS v", "15"},
		{"tab introduces a comment", "SELECT 5 AS v --\tignored", "5"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rows, err := conn.Read(context.Background(), QuerySpec{Raw: c.sql}, 10)
			if err != nil {
				t.Fatalf("gate or server rejected an ordinary read %q: %v", c.sql, err)
			}
			// fmt.Sprint, not a direct comparison: a numeric MySQL column
			// scans into an int64 here, not a string (only []byte columns
			// are converted — see sqlConn.Read).
			if len(rows.Rows) != 1 || len(rows.Rows[0]) != 1 || fmt.Sprint(rows.Rows[0][0]) != c.want {
				t.Fatalf("%q returned %+v, want a single %q", c.sql, rows.Rows, c.want)
			}
		})
	}
}

// TestMySQLQuoteIdent pins mysqlQuoteIdent as a pure function. This is the
// half of the MySQL quoting guard that runs on a bare `go test ./...`:
// TestMySQLQuoteIdentAndDescribe above needs WAKIL_MYSQL_DSN and is
// skipped by default, so without this the backtick-doubling rule had
// nothing pinning it in the ordinary test run at all.
//
// The rules are: WRAP in backticks, and DOUBLE every embedded backtick.
// A mutant doing only one of the two still emits something backtick-shaped,
// so both halves get their own case.
func TestMySQLQuoteIdent(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
		why  string
	}{
		{
			name: "ordinary identifier", in: "customers", want: "`customers`",
			why: "the common case must not be mangled",
		},
		{
			name: "empty identifier", in: "", want: "``",
			why: "an empty name yields the empty quoted identifier, not the empty string, which would splice \"SELECT * FROM  LIMIT 0\"",
		},
		{
			name: "single embedded backtick", in: "a`b", want: "`a``b`",
			why: "the doubling rule, minimally",
		},
		{
			name: "nothing but backticks", in: "```", want: "````````",
			why: "3 backticks -> 6 doubled + 2 wrapping = 8; an off-by-one in the doubling shows up here and nowhere else",
		},
		{
			name: "injection payload", in: "t` ; DROP TABLE u; -- ", want: "`t`` ; DROP TABLE u; -- `",
			why: "the doubled backtick is what stops the identifier terminating early; the rest is inert text inside it",
		},
		{
			name: "NUL byte is passed through untouched", in: "a\x00b", want: "`a\x00b`",
			why: "quoting has no opinion about NUL — rejecting it is sqlConn.Describe's job, and splitting that responsibility would leave each side assuming the other did it",
		},
		{
			name: "double quote is not special here", in: `a"b`, want: "`a\"b`",
			why: `MySQL's identifier quote is the backtick; with the default sql_mode a double quote is a STRING delimiter, so doubling it here would corrupt the name`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mysqlQuoteIdent(tc.in); got != tc.want {
				t.Fatalf("mysqlQuoteIdent(%q) = %q, want %q — %s", tc.in, got, tc.want, tc.why)
			}
		})
	}
}

// TestMySQLCommentIntroducerBypassIsBlocked is the live half of
// TestAssertSQLReadOnly_CommentIntroducersAreNotContextFree and
// TestAssertSQLReadOnly_BackslashLiteralAmbiguity. Like
// TestMySQLDoubleDashOutfileBypassIsBlocked above, it first proves against
// a real server that each payload is genuinely live SQL — otherwise
// "conn.Read returned an error" would prove nothing — and only then that
// the gated read path refuses it and no file appears.
//
// The payloads carry no ";", so hardenMySQLConfig's MultiStatements=false
// does not help; the gate is the only thing between them and the server.
func TestMySQLCommentIntroducerBypassIsBlocked(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()

	// (a1) A "/*" written inside a "--" comment does NOT open a comment for
	// MySQL: the second and third lines are live SQL, so this one statement
	// returns two rows.
	rows, err := raw.Query("SELECT 1 -- /*\nUNION SELECT 2\n-- */")
	if err != nil {
		t.Fatalf("the premise failed: this server rejected the payload: %v", err)
	}
	var got []int
	for rows.Next() {
		var n int
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		got = append(got, n)
	}
	rows.Close()
	if len(got) != 2 || got[0] != 1 || got[1] != 2 {
		t.Fatalf("this server does not treat the hidden UNION as live SQL (got %v); "+
			"the bypass this test pins does not apply to it", got)
	}

	var dir string
	if err := raw.QueryRow("SELECT @@secure_file_priv").Scan(&dir); err != nil || dir == "" {
		t.Skipf("server has no writable secure_file_priv directory (err=%v, dir=%q)", err, dir)
	}
	// Unique per run: INTO OUTFILE refuses to overwrite, and -count=2 runs
	// this twice in one process.
	stamp := time.Now().UnixNano()

	// Each case: a payload the gate must refuse, the message it must refuse
	// with, and the same payload with a different target path used to prove
	// the server really writes when nothing stops it.
	cases := []struct {
		name string
		// tmpl takes a filename and returns the statement.
		tmpl    func(string) string
		wantMsg string
	}{
		{
			name:    "block comment opened inside a -- comment",
			tmpl:    func(f string) string { return "SELECT 1 -- /*\nINTO OUTFILE '" + f + "'\n-- */" },
			wantMsg: "query contains a write operation and was blocked (read-only)",
		},
		{
			name:    "block comment opened inside a # comment",
			tmpl:    func(f string) string { return "SELECT 1 # /*\nINTO OUTFILE '" + f + "'\n# */" },
			wantMsg: "query contains a write operation and was blocked (read-only)",
		},
		{
			// The backslash ambiguity: MySQL reads 'a\' -- ' as ONE literal,
			// so the "--" never introduces a comment and the INTO OUTFILE is
			// live. A scanner that ended the literal at the escaped quote
			// would strip the rest of the line and allow this.
			name:    "escaped quote inside a literal re-arming a -- comment",
			tmpl:    func(f string) string { return `SELECT 'a\' -- ' INTO OUTFILE '` + f + `'` },
			wantMsg: "query contains a write operation and was blocked (read-only)",
		},
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

	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			proof := fmt.Sprintf("%sci_proof_%d_%d.txt", dir, stamp, i)
			blocked := fmt.Sprintf("%sci_blocked_%d_%d.txt", dir, stamp, i)
			removeServerFileOnCleanup(t, proof)
			removeServerFileOnCleanup(t, blocked)

			// (a2) The payload really writes a file when it reaches the server.
			if _, err := raw.Exec(c.tmpl(proof)); err != nil {
				t.Skipf("cannot write an OUTFILE on this server (%v); nothing to prove the gate against", err)
			}
			var wrote bool
			if err := raw.QueryRow("SELECT LOAD_FILE(?) IS NOT NULL", proof).Scan(&wrote); err != nil {
				t.Fatal(err)
			}
			if !wrote {
				t.Fatalf("expected %s to exist after the raw driver wrote it", proof)
			}

			// (b) The same payload through the gated read path is refused,
			// with the message the write-keyword scan produces.
			_, rerr := conn.Read(context.Background(), QuerySpec{Raw: c.tmpl(blocked)}, 10)
			if rerr == nil {
				t.Fatal("the read-only gate ALLOWED a payload that writes a file on the database host")
			}
			msg, ok := IsUserError(rerr)
			if !ok || msg != c.wantMsg {
				t.Fatalf("unexpected rejection: %T %q", rerr, msg)
			}
			var appeared bool
			if err := raw.QueryRow("SELECT LOAD_FILE(?) IS NOT NULL", blocked).Scan(&appeared); err != nil {
				t.Fatal(err)
			}
			if appeared {
				t.Fatalf("a file (%s) was written on the database host by a read-only tool", blocked)
			}
		})
	}
}

// TestMySQLCommentHandlingDidNotOverReject is the anti-over-rejection half
// of the rewrite: making the scanner literal-aware must not have cost any
// ordinary read. Each query runs through the GATED read path against the
// real server and must return the value MySQL itself computes for it.
func TestMySQLCommentHandlingDidNotOverReject(t *testing.T) {
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

	for _, c := range []struct{ name, sql, want string }{
		{"ordinary line comment", "SELECT 1 AS v -- an ordinary comment", "1"},
		{"ordinary block comment", "SELECT 1 AS v /* a note */ FROM DUAL", "1"},
		{"literal containing a comment introducer", "SELECT '-- not a comment' AS v", "-- not a comment"},
		{"literal containing a block introducer", "SELECT '/*' AS v", "/*"},
		{"backslash both readings agree about", `SELECT 'C:\path' AS v -- a note`, `C:path`},
	} {
		t.Run(c.name, func(t *testing.T) {
			rows, err := conn.Read(context.Background(), QuerySpec{Raw: c.sql}, 10)
			if err != nil {
				t.Fatalf("gate or server rejected an ordinary read %q: %v", c.sql, err)
			}
			if len(rows.Rows) != 1 || len(rows.Rows[0]) != 1 || fmt.Sprint(rows.Rows[0][0]) != c.want {
				t.Fatalf("%q returned %+v, want a single %q", c.sql, rows.Rows, c.want)
			}
		})
	}
}

// TestMySQLExecutableCommentCloseBypassIsBlocked is the live half of the
// "/*! ... */" disagreement: MySQL parses an executable comment's content
// as LIVE SQL and therefore honours string literals while hunting for the
// closing "*/", so a "*/" inside a literal does not close it. SQLite, and
// any plain search for the first "*/", says it does. Taking the shorter
// reading ends the comment early and re-arms the text after it.
//
// The premise is proved with a statement that leaves nothing behind —
// SELECT /*!50000 LENGTH(' */ -- ') AS v */ answers 7 if and only if MySQL
// read " */ -- " as a seven-character literal rather than a terminator —
// and only then is the file-writing payload run.
func TestMySQLExecutableCommentCloseBypassIsBlocked(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()

	// The premise, with no side effect at all.
	var n int
	if err := raw.QueryRow(`SELECT /*!50000 LENGTH(' */ -- ') AS v */`).Scan(&n); err != nil {
		t.Skipf("this server rejected the literal probe (%v); the bypass this test pins does not apply to it", err)
	}
	if n != 7 {
		t.Fatalf(`SELECT /*!50000 LENGTH(' */ -- ') AS v */ answered %d, want 7: this server does not `+
			`honour literals inside an executable comment, so the bypass this test pins does not apply`, n)
	}

	var dir string
	if err := raw.QueryRow("SELECT @@secure_file_priv").Scan(&dir); err != nil || dir == "" {
		t.Skipf("server has no writable secure_file_priv directory (err=%v, dir=%q)", err, dir)
	}
	stamp := time.Now().UnixNano()
	proof := fmt.Sprintf("%sp7_proof_%d.txt", dir, stamp)
	blocked := fmt.Sprintf("%sp7_blocked_%d.txt", dir, stamp)
	removeServerFileOnCleanup(t, proof)
	removeServerFileOnCleanup(t, blocked)

	payload := func(f string) string {
		return `SELECT 1 /*!50000 ' */ -- ' INTO OUTFILE '` + f + `' */`
	}

	// (a) The payload really writes a file when it reaches the server.
	if _, err := raw.Exec(payload(proof)); err != nil {
		t.Skipf("cannot write an OUTFILE on this server (%v); nothing to prove the gate against", err)
	}
	var wrote bool
	if err := raw.QueryRow("SELECT LOAD_FILE(?) IS NOT NULL", proof).Scan(&wrote); err != nil {
		t.Fatal(err)
	}
	if !wrote {
		t.Fatalf("expected %s to exist after the raw driver wrote it", proof)
	}

	// (b) The same payload through the gated read path is refused, and no
	// file appears.
	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	_, rerr := conn.Read(context.Background(), QuerySpec{Raw: payload(blocked)}, 10)
	if rerr == nil {
		t.Fatal("the read-only gate ALLOWED a payload that writes a file on the database host")
	}
	msg, ok := IsUserError(rerr)
	if !ok || msg != "query contains a write operation and was blocked (read-only)" {
		t.Fatalf("unexpected rejection: %T %q", rerr, msg)
	}
	var appeared bool
	if err := raw.QueryRow("SELECT LOAD_FILE(?) IS NOT NULL", blocked).Scan(&appeared); err != nil {
		t.Fatal(err)
	}
	if appeared {
		t.Fatalf("a file (%s) was written on the database host by a read-only tool", blocked)
	}

	// The ";" variant, caught by a different check.
	_, rerr = conn.Read(context.Background(),
		QuerySpec{Raw: `SELECT 1 /*!50000 ' */ -- ' ; DROP TABLE customers */`}, 10)
	msg, ok = IsUserError(rerr)
	if !ok || msg != "multiple statements are not allowed in read-only mode" {
		t.Fatalf("unexpected rejection for the multi-statement variant: %T %q", rerr, msg)
	}

	// The anti-over-rejection half: giving up on "/*!" must not cost the
	// ordinary executable-comment hints. Each runs through the GATED path
	// and must return what MySQL itself computes.
	for _, c := range []struct{ name, sql, want string }{
		{"versioned hint", "SELECT /*!50000 1 */ AS v", "1"},
		{"unversioned hint", "SELECT /*! 1 */ AS v", "1"},
		{"optimizer hint shape", "SELECT /*! SQL_NO_CACHE */ 1 AS v", "1"},
	} {
		t.Run(c.name, func(t *testing.T) {
			rows, err := conn.Read(context.Background(), QuerySpec{Raw: c.sql}, 10)
			if err != nil {
				t.Fatalf("gate or server rejected an ordinary read %q: %v", c.sql, err)
			}
			if len(rows.Rows) != 1 || len(rows.Rows[0]) != 1 || fmt.Sprint(rows.Rows[0][0]) != c.want {
				t.Fatalf("%q returned %+v, want a single %q", c.sql, rows.Rows, c.want)
			}
		})
	}
}

// Both hardening functions are checked in ONE test so they cannot drift.
// MultiStatements, AllowAllFiles and the charset pin must be identical on
// both; only the transaction_read_only parameter distinguishes them.
func TestHardenMySQLConfigReadAndWriteAgree(t *testing.T) {
	hostile := "u:p@tcp(h:3306)/d?autocommit=1%2C%20transaction_read_only%3D0&multiStatements=true&allowAllFiles=true" +
		"&charset=gbk&collation=gbk_chinese_ci"

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
	if ro.Collation != "" || !strings.Contains(ro.FormatDSN(), "charset=utf8mb4") {
		t.Errorf("read config must pin charset to utf8mb4 and clear Collation, got dsn=%s collation=%q",
			ro.FormatDSN(), ro.Collation)
	}

	rw, err := mysql.ParseDSN(hostile)
	if err != nil {
		t.Fatal(err)
	}
	hardenMySQLWriteConfig(rw)
	if rw.MultiStatements || rw.AllowAllFiles {
		t.Error("write config must force MultiStatements and AllowAllFiles off")
	}
	if rw.Collation != "" || !strings.Contains(rw.FormatDSN(), "charset=utf8mb4") {
		t.Errorf("write config must pin charset to utf8mb4 and clear Collation, got dsn=%s collation=%q",
			rw.FormatDSN(), rw.Collation)
	}
	if _, ok := rw.Params["transaction_read_only"]; ok {
		t.Errorf("write config must NOT set transaction_read_only, got %v", rw.Params)
	}
	if len(rw.Params) != 0 {
		t.Errorf("write config must discard every param, got %v", rw.Params)
	}
}

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

// mustConnectMySQLWritable opens a writable MySQL connection through the
// real driver path — GetDriver("mysql").ConnectWritable — and fails the
// test immediately if that does not succeed, so every writable-connection
// test below shares one place that does it rather than repeating the same
// six lines.
func mustConnectMySQLWritable(t *testing.T, dsn string) Conn {
	t.Helper()
	d, err := GetDriver("mysql")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.ConnectWritable(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

// TestMySQLReadsItsBackslashMode pins sqlConn.backslashEscapes against a
// live server: MySQL 8's default sql_mode does not carry
// NO_BACKSLASH_ESCAPES, so a backslash IS an escape character there and
// must be doubled.
func TestMySQLReadsItsBackslashMode(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("WAKIL_MYSQL_DSN not set")
	}
	conn := mustConnectMySQLWritable(t, dsn)
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

// TestMySQLQuoteLiteral pins mysqlQuoteLiteral's rule under both readings
// of backslashEscapes: doubled under the (default) true reading, left
// alone under NO_BACKSLASH_ESCAPES's false reading, since doubling there
// would store two.
func TestMySQLQuoteLiteral(t *testing.T) {
	for _, tc := range []struct {
		in      string
		escapes bool
		want    string
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

// TestMySQLCharsetInjectionCannotReviveBackslashUnsafety is the live half
// of TestHardenMySQLConfigPinsCharset: a stored DSN carrying charset=gbk
// (or any charset in the class pinMySQLCharset's doc comment describes)
// must not be able to make ConnectWritable's connection actually speak
// gbk, because that would leave mysqlQuoteLiteral's backslash doubling
// unsafe on a real server, not just on paper.
//
// This is the exact live exploit review found, reproduced and then
// disproved: with the hostile charset in the DSN, quoteLiteral doubles
// the payload's 0x5C as an ordinary backslash — a gbk connection would
// read that doubled byte as pairing with the preceding byte into one
// character, closing the literal early and exposing "id = 99 #" as live
// SQL with the WHERE clause commented out. Asserting only "row 2 is
// unchanged" would not be enough on its own (a statement that failed
// outright for an unrelated reason would look the same); the id=99
// fragment is chosen so that if it ever did escape the literal, it would
// update row 2 specifically, which the row-2 check would catch.
func TestMySQLCharsetInjectionCannotReviveBackslashUnsafety(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("WAKIL_MYSQL_DSN not set")
	}
	hostile := dsn + "?charset=gbk&collation=gbk_chinese_ci"
	conn := mustConnectMySQLWritable(t, hostile)
	defer conn.Close()
	sc := conn.(*sqlConn)

	mustExec(t, sc, `DROP TABLE IF EXISTS gbk_injection`)
	mustExec(t, sc, `CREATE TABLE gbk_injection (id INT PRIMARY KEY, v VARBINARY(200))`)
	mustExec(t, sc, `INSERT INTO gbk_injection VALUES (1, 'seed1'), (2, 'seed2')`)

	// 0xBF plus a doubled 0x5C is exactly the two-byte tail a gbk reading
	// would fuse into one character, if the connection were really
	// speaking gbk. Followed by a real closing quote and a fragment that
	// would touch row 2 if it ever became live SQL.
	payload := "\xBF\x5C', id = 99 #"
	lit, err := sc.quoteLiteral(payload)
	if err != nil {
		t.Fatalf("quoteLiteral: %v", err)
	}
	if _, err := sc.db.Exec(`UPDATE gbk_injection SET v = ` + lit + ` WHERE id = 1`); err != nil {
		t.Fatalf("UPDATE with the composed literal failed: %v", err)
	}

	var v1, v2 string
	if err := sc.db.QueryRow(`SELECT v FROM gbk_injection WHERE id = 1`).Scan(&v1); err != nil {
		t.Fatal(err)
	}
	if err := sc.db.QueryRow(`SELECT v FROM gbk_injection WHERE id = 2`).Scan(&v2); err != nil {
		t.Fatal(err)
	}
	if v1 != payload {
		t.Errorf("row 1 = %q, want the payload round-tripped intact: %q", v1, payload)
	}
	if v2 != "seed2" {
		t.Errorf("row 2 = %q: the WHERE clause was defeated, exactly the exploit this test guards against", v2)
	}
}

// mustExec runs stmt directly against sc.db and fails the test if it
// errors. It bypasses conn.Write's mutation gate deliberately: this
// fixture needs DROP TABLE / CREATE TABLE to set up, and AssertSQLMutation
// refuses schema changes by design (see TestMySQLWritableConnectionStillRefusesDDL)
// — that refusal is the thing under test elsewhere, not an obstacle to
// route around for THIS test, whose subject is quoteLiteral, not the gate.
func mustExec(t *testing.T, sc *sqlConn, stmt string) {
	t.Helper()
	if _, err := sc.db.Exec(stmt); err != nil {
		t.Fatalf("%s: %v", stmt, err)
	}
}

// TestMySQLLiteralRoundTrip is the test that would have caught the
// corruption. Every payload is written through the composed literal and
// read back byte for byte. The backslash case is the one a naive escaper
// corrupts SILENTLY — it is why this test exists.
func TestMySQLLiteralRoundTrip(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("WAKIL_MYSQL_DSN not set")
	}
	conn := mustConnectMySQLWritable(t, dsn)
	defer conn.Close()
	sc := conn.(*sqlConn)
	mustExec(t, sc, `DROP TABLE IF EXISTS lit`)
	mustExec(t, sc, `CREATE TABLE lit (id INT PRIMARY KEY, v VARBINARY(200))`)
	for _, payload := range []string{
		"hello", "O'Brien", `C:\path\n`, "a\nb", "a\tb", "100%_x",
		"café 🚀", "", "a\x00b", "x' WHERE 1=1 -- ", `say "hi"`, "a`b",
	} {
		mustExec(t, sc, `DELETE FROM lit`)
		mustExec(t, sc, `INSERT INTO lit VALUES (1, 'seed')`)
		lit, err := sc.quoteLiteral(payload)
		if err != nil {
			t.Fatalf("%q: %v", payload, err)
		}
		mustExec(t, sc, `UPDATE lit SET v = `+lit+` WHERE id = 1`)
		var back []byte
		if err := sc.db.QueryRow(`SELECT v FROM lit WHERE id = 1`).Scan(&back); err != nil {
			t.Fatalf("%q: %v", payload, err)
		}
		if string(back) != payload {
			t.Fatalf("%q round-tripped as %q", payload, string(back))
		}
	}

	// Two values that cannot be expressed as this COLUMN's contents at
	// all — not because mysqlQuoteLiteral has any opinion about them (it
	// is a byte-level escaper with no charset or length awareness, and
	// measured, it does not refuse either one), but because the ENGINE
	// does. In the spirit of sqlite's NUL refusal, both must fail CLOSED
	// against a column that can reject them, rather than being silently
	// truncated or corrupted.
	//
	// This needs its own column: lit above is VARBINARY, which stores
	// arbitrary bytes with no charset or length opinion of its own (up to
	// its declared size) — that is why the NUL and non-ASCII payloads in
	// the loop above round-trip through it cleanly. VARCHAR ... CHARACTER
	// SET utf8mb4 is the column type that actually enforces "this must be
	// valid utf8mb4" and "this must fit", so it is what proves the
	// closed-failure rather than proving VARBINARY's permissiveness by
	// accident. Measured against the live container: invalid UTF-8 into
	// this column fails with MySQL error 1366 ("Incorrect string value"),
	// and an oversized value fails with error 1406 ("Data too long").
	mustExec(t, sc, `DROP TABLE IF EXISTS lit_charset`)
	mustExec(t, sc, `CREATE TABLE lit_charset (id INT PRIMARY KEY, v VARCHAR(200) CHARACTER SET utf8mb4)`)
	for _, tc := range []struct{ name, payload string }{
		{"invalid UTF-8", "\xff\xfe\x80"},
		{"oversized for VARCHAR(200)", strings.Repeat("x", 500)},
	} {
		mustExec(t, sc, `DELETE FROM lit_charset`)
		mustExec(t, sc, `INSERT INTO lit_charset VALUES (1, 'seed')`)
		lit, err := sc.quoteLiteral(tc.payload)
		if err != nil {
			t.Fatalf("%s: quoteLiteral refused, want the ENGINE to be the one refusing: %v", tc.name, err)
		}
		if _, err := sc.db.Exec(`UPDATE lit_charset SET v = ` + lit + ` WHERE id = 1`); err == nil {
			t.Fatalf("%s: expected the engine to refuse this value, it was accepted", tc.name)
		}
	}
}

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

	// Cancels race the reads: some land mid-read and fire a kill, some land
	// after the read returned and must fire none. A read that fails while
	// its own cancel is still pending was hit by a stray kill.
	for i := 0; i < 500; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		time.AfterFunc(time.Duration(rand.Intn(1000))*time.Microsecond, cancel)
		if _, err := conn.Read(ctx, QuerySpec{Raw: "SELECT 1 AS one"}, 10); err != nil && ctx.Err() == nil {
			// Its own cancel had not fired, so the error is a kill aimed at an
			// earlier read that landed on this one.
			t.Fatalf("read %d failed without being cancelled: %v", i, err)
		}
	}
	// The window the race above rarely reaches: the cancel lands after the rows
	// are closed but before release. release must wait for the kill it
	// started, so the statement that reuses the connection is never its target.
	sc := conn.(*sqlConn)
	for i := 0; i < 10; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		rows, release, err := sc.queryContext(ctx, "SELECT 1 AS one")
		if err != nil {
			t.Fatal(err)
		}
		_, _ = collectRows(rows, 10)
		rows.Close()
		cancel()
		release()
		var slept int
		if err := sc.db.QueryRowContext(context.Background(), "SELECT SLEEP(0.3)").Scan(&slept); err != nil {
			t.Fatalf("round %d: the statement after a released read failed: %v", i, err)
		}
		if slept != 0 {
			t.Fatalf("round %d: the statement after a released read was killed (SLEEP returned %d)", i, slept)
		}
	}
	// A long read on the same pool after all of them: a stray KILL QUERY would
	// make SLEEP return 1 rather than error, so check the value.
	out, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT SLEEP(1) AS s"}, 10)
	if err != nil {
		t.Fatalf("a later read failed: %v", err)
	}
	if got := fmt.Sprint(out.Rows[0][0]); got != "0" {
		t.Fatalf("a later read was killed: SLEEP returned %s", got)
	}
}
