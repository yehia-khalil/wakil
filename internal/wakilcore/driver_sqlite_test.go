package wakilcore

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

func seedSQLite(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
		INSERT INTO customers (id,name) VALUES (42,'Layla'),(43,'Omar');`); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSQLiteReadAndGate(t *testing.T) {
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

	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT id,name FROM customers WHERE id=42"}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows.Rows) != 1 || rows.Rows[0][1] != "Layla" {
		t.Fatalf("bad rows: %+v", rows)
	}
	if err := d.AssertReadOnly(QuerySpec{Raw: "DELETE FROM customers"}); err == nil {
		t.Fatal("driver must reject writes")
	}
	cs, err := conn.ListContainers(context.Background())
	if err != nil || len(cs) == 0 || cs[0].Kind != "table" {
		t.Fatalf("containers: %+v %v", cs, err)
	}
}

// TestSQLiteEngineLevelReadOnly proves the SQLite engine itself refuses a
// write, independent of the AssertSQLReadOnly gate. It reaches the
// underlying *sql.DB directly (bypassing the gate in sqlConn.Read) to
// confirm the connection was opened read-only at the engine level (via a
// file: URI with mode=ro), per resolution 3.
func TestSQLiteEngineLevelReadOnly(t *testing.T) {
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

	sc, ok := conn.(*sqlConn)
	if !ok {
		t.Fatalf("expected *sqlConn, got %T", conn)
	}
	// Bypass the gate entirely and hit the engine directly.
	_, err = sc.db.ExecContext(context.Background(), "INSERT INTO customers (id,name) VALUES (99,'Hacker')")
	if err == nil {
		t.Fatal("expected engine to reject write on read-only connection")
	}
}

// TestQuoteIdentEscapesHostileNames proves Describe's identifier quoting
// performs real SQL identifier quoting (doubling embedded quote
// characters) rather than Go string escaping, so a hostile table name
// cannot terminate the identifier early and inject SQL, per resolution 1.
func TestQuoteIdentEscapesHostileNames(t *testing.T) {
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

	hostile := `x" ; DROP TABLE customers --`
	if _, err := conn.Describe(context.Background(), hostile); err == nil {
		t.Fatal("expected Describe to fail for hostile/unknown table name")
	}

	// customers must still exist and be readable.
	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT id,name FROM customers WHERE id=42"}, 100)
	if err != nil {
		t.Fatalf("customers table should still exist: %v", err)
	}
	if len(rows.Rows) != 1 {
		t.Fatalf("expected customers to be intact: %+v", rows)
	}
}

// TestDescribeRejectsNulByteIdentifier proves Describe rejects an
// identifier containing a NUL byte with a UserError, per resolution 1,
// rather than passing it through to the underlying query.
func TestDescribeRejectsNulByteIdentifier(t *testing.T) {
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

	_, err = conn.Describe(context.Background(), "bad\x00name")
	if err == nil {
		t.Fatal("expected error for NUL byte in identifier")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %v", err)
	}
}

// TestReadTruncation proves Read reports Truncated=true when more rows
// exist than the limit, and Truncated=false when the result set fits
// entirely within the limit, per resolution 4.
func TestReadTruncation(t *testing.T) {
	path := seedSQLite(t)
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	// Seed extra rows beyond the two from seedSQLite so a small limit
	// truncates.
	for i := 0; i < 10; i++ {
		if _, err := db.Exec("INSERT INTO customers (id, name) VALUES (?, ?)", 100+i, "Extra"); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()

	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: path})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT id,name FROM customers"}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows.Rows) != 5 {
		t.Fatalf("expected exactly 5 rows, got %d", len(rows.Rows))
	}
	if !rows.Truncated {
		t.Fatal("expected Truncated=true when more rows exist than the limit")
	}

	rows2, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT id,name FROM customers WHERE id=42"}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if rows2.Truncated {
		t.Fatal("expected Truncated=false when result fits within the limit")
	}
}

// TestConnectFailureIsUserError proves that a nonexistent/unopenable
// database returns a UserError, not a raw error, so callers never see a
// stack trace.
func TestConnectFailureIsUserError(t *testing.T) {
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	// A directory path is not a valid sqlite database file and cannot be
	// opened/pinged successfully.
	_, err = d.Connect(context.Background(), Connection{URL: dir})
	if err == nil {
		t.Fatal("expected error connecting to an unopenable path")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected UserError, got %v (%T)", err, err)
	}
}

// seedSQLiteAt creates and seeds a customers table at an exact path (no
// t.TempDir() indirection), so tests can exercise filenames containing
// characters that are meaningful in a URI (?, #, space).
//
// It seeds through a percent-encoded "file:" URI built the same way
// sqliteReadOnlyDSN's bare-path branch builds one (minus mode=ro), rather
// than through sql.Open("sqlite", path) directly. That matters for a path
// containing a literal '?': modernc.org/sqlite's own DSN convention
// treats the first '?' in *any* dsn string as a query-parameter
// delimiter, even one with no "file:" prefix at all (mirroring
// mattn/go-sqlite3's historical DSN format) — so sql.Open("sqlite",
// ".../has?query.db") would silently truncate the path to ".../has" and
// seed the wrong file. Routing the seed step through the same encoding
// the driver itself uses guarantees the file this helper creates is the
// exact file the driver later opens.
func seedSQLiteAt(t *testing.T, path string) {
	t.Helper()
	u := url.URL{Scheme: "file", OmitHost: true, Path: path}
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
		INSERT INTO customers (id,name) VALUES (42,'Layla');`); err != nil {
		t.Fatal(err)
	}
}

// assertReadOnlyDSNBlocksWrites connects through the sqlite driver using
// the given Connection.URL, then bypasses the AssertSQLReadOnly gate
// entirely and writes straight through the underlying *sql.DB (exactly
// like TestSQLiteEngineLevelReadOnly). It fails the test if the write
// succeeds, proving the DSN produced by sqliteReadOnlyDSN genuinely
// carries mode=ro through to the engine for this input, not just that
// the DSN string looks right.
func assertReadOnlyDSNBlocksWrites(t *testing.T, connURL string) {
	t.Helper()
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: connURL})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	sc, ok := conn.(*sqlConn)
	if !ok {
		t.Fatalf("expected *sqlConn, got %T", conn)
	}
	_, err = sc.db.ExecContext(context.Background(), "INSERT INTO customers (id,name) VALUES (99,'Hacker')")
	if err == nil {
		t.Fatalf("expected engine to reject write for Connection.URL=%q, but it succeeded", connURL)
	}
	// The failure must specifically be the read-only rejection, not some
	// unrelated error (e.g. a mangled URI silently opening a different,
	// missing/empty file and failing with "no such table" instead) — that
	// kind of false-positive is exactly what let the original bug ship.
	if !strings.Contains(strings.ToLower(err.Error()), "readonly") {
		t.Fatalf("expected a read-only rejection for Connection.URL=%q, got a different error: %v", connURL, err)
	}
}

// TestSQLiteReadOnlyDSNSurvivesHostilePathCharacters proves that
// sqliteReadOnlyDSN's mode=ro guarantee holds for filesystem paths
// containing characters ('?', '#') that are meaningful in a URI. Naive
// string concatenation ("file:" + raw + "?mode=ro") lets a raw '?' or '#'
// in the path terminate the path component early, so mode=ro either lands
// in the wrong place or is dropped outright and the engine opens
// read-write.
func TestSQLiteReadOnlyDSNSurvivesHostilePathCharacters(t *testing.T) {
	dir := t.TempDir()

	cases := []struct {
		name string
		file string
	}{
		{"plain path (control)", "plain.db"},
		{"path with space (control)", "has space.db"},
		{"path with question mark", "has?query.db"},
		{"path with hash", "has#fragment.db"},
	}

	// Bare filesystem path: this is the primary defect the DSN must
	// survive, for both hostile characters. A raw path is not itself a
	// URI, so there is no ambiguity in what the caller meant — the fix
	// must percent-encode the characters that would otherwise be
	// misread as URI delimiters.
	for _, tc := range cases {
		path := filepath.Join(dir, "bare-"+tc.name+"-"+tc.file)
		seedSQLiteAt(t, path)
		t.Run("bare path/"+tc.name, func(t *testing.T) {
			assertReadOnlyDSNBlocksWrites(t, path)
		})
	}

	// Already-formed "file:" URI, benign controls: confirm ordinary
	// paths still work through this branch too.
	for _, tc := range cases[:2] {
		path := filepath.Join(dir, "file-uri-"+tc.name+"-"+tc.file)
		seedSQLiteAt(t, path)
		t.Run("file: URI/"+tc.name, func(t *testing.T) {
			assertReadOnlyDSNBlocksWrites(t, "file:"+path)
		})
	}

	// Already-formed "file:" URI: this branch's contract is that the
	// caller hands us a URI, so any reserved character it needs as
	// literal path text must already be percent-encoded by the caller
	// (that's true of any URI, not something specific to SQLite) — a
	// raw, unescaped '?' here is irreducibly ambiguous (nothing can tell
	// "start of query" from "literal path text" without encoding), so
	// the realistic case to test is a *well-formed* URI, confirming
	// mode=ro is still correctly layered onto it.
	questionMarkPath := filepath.Join(dir, "file-uri-question-mark-has?query.db")
	seedSQLiteAt(t, questionMarkPath)
	t.Run("file: URI/well-formed, path had a question mark", func(t *testing.T) {
		wellFormed := (&url.URL{Scheme: "file", OmitHost: true, Path: questionMarkPath}).String()
		assertReadOnlyDSNBlocksWrites(t, wellFormed)
	})

	// '#', by contrast, is not ambiguous in the same way: nothing about
	// a "file:" URI's grammar (per SQLite's own documented DSN
	// convention, mirrored in setMode) requires '#' to separate
	// anything. But the underlying SQLite engine itself truncates the
	// filename at an unescaped '#' regardless, silently dropping
	// whatever follows — including a "?mode=ro" this package appends.
	// So an already-formed "file:" URI containing a raw, unescaped '#'
	// is a real, defensible case to guard, and setMode does so by
	// percent-encoding it. This is tested with the raw character
	// (unlike the '?' case above) specifically to prove that guard.
	hashPath := filepath.Join(dir, "file-uri-hash-has#fragment.db")
	seedSQLiteAt(t, hashPath)
	t.Run("file: URI/raw hash in path", func(t *testing.T) {
		assertReadOnlyDSNBlocksWrites(t, "file:"+hashPath)
	})
}

// TestSQLiteQuoteIdent pins sqliteQuoteIdent as a pure function, so the
// rule it implements is stated once and directly rather than only being
// inferable from a Describe round-trip. The two rules are: WRAP in double
// quotes, and DOUBLE every embedded double quote. A mutant that does only
// one of the two produces a string that still looks quoted, which is
// exactly why both halves get their own case.
func TestSQLiteQuoteIdent(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
		why  string
	}{
		{
			name: "ordinary identifier", in: "customers", want: `"customers"`,
			why: "the common case must not be mangled",
		},
		{
			name: "empty identifier", in: "", want: `""`,
			why: `an empty name yields the empty quoted identifier "" — SQLite's own syntax for one — not the empty string, which would splice "SELECT * FROM  LIMIT 0"`,
		},
		{
			name: "single embedded quote", in: `a"b`, want: `"a""b"`,
			why: "the doubling rule, minimally",
		},
		{
			name: "nothing but quote characters", in: `"""`, want: `""""""""`,
			why: "3 quotes -> 6 doubled + 2 wrapping = 8; an off-by-one in the doubling shows up here and nowhere else",
		},
		{
			name: "injection payload", in: `t" ; DROP TABLE u; --`, want: `"t"" ; DROP TABLE u; --"`,
			why: "the doubled quote is what stops the identifier terminating early; the rest is inert text inside it",
		},
		{
			name: "NUL byte is passed through untouched", in: "a\x00b", want: "\"a\x00b\"",
			why: "quoting has no opinion about NUL — rejecting it is sqlConn.Describe's job, and splitting that responsibility would leave each side assuming the other did it",
		},
		{
			name: "backtick is not special here", in: "a`b", want: "\"a`b\"",
			why: "SQLite's standard identifier quote is the double quote; a backtick inside one is ordinary text and must NOT be doubled",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := sqliteQuoteIdent(tc.in); got != tc.want {
				t.Fatalf("sqliteQuoteIdent(%q) = %q, want %q — %s", tc.in, got, tc.want, tc.why)
			}
		})
	}
}

// TestSQLiteCommentIntroducerBypassIsBlocked is the SQLite half of
// TestAssertSQLReadOnly_CommentIntroducersAreNotContextFree. It matters
// separately from the MySQL half for two reasons measured here:
//
//   - This driver executes EVERY statement in the string it is handed, so
//     for SQLite the gate's ";" check is not a second lock, it is the lock.
//   - The engine-level mode=ro on the connection does NOT stop ATTACH from
//     creating a file: the premise below runs the payload through the raw
//     driver on the SAME read-only DSN sqliteDriver.Connect builds, and
//     side.db appears on disk.
//
// Before this fix the gate stripped the payload to "SELECT 1  " — the "/*"
// on the first line, written inside a "--" comment, opened a block comment
// for the stripper that no engine opens, and it swallowed the ";" and the
// ATTACH — so the gate ALLOWED it.
func TestSQLiteCommentIntroducerBypassIsBlocked(t *testing.T) {
	dir := t.TempDir()
	main := filepath.Join(dir, "main.db")
	seed, err := sql.Open("sqlite", main)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Exec("CREATE TABLE t (x int)"); err != nil {
		t.Fatal(err)
	}
	seed.Close()

	payload := func(target string) string {
		return "SELECT 1 -- /*\n; ATTACH DATABASE '" + target + "' AS s\n-- */"
	}

	// The premise: on the very DSN the driver builds — mode=ro and all —
	// this payload really is live SQL and really creates a file.
	proof := filepath.Join(dir, "proof.db")
	rawDB, err := sql.Open("sqlite", sqliteReadOnlyDSN(main))
	if err != nil {
		t.Fatal(err)
	}
	rows, err := rawDB.Query(payload(proof))
	if err != nil {
		rawDB.Close()
		t.Skipf("this build of modernc.org/sqlite refused the payload (%v); nothing to prove the gate against", err)
	}
	rows.Close()
	rawDB.Close()
	if _, err := os.Stat(proof); err != nil {
		t.Skipf("ATTACH did not create %s (%v); nothing to prove the gate against", proof, err)
	}

	// The gate must refuse the same payload, and refuse it as a
	// multiple-statement rejection — the ";" the old stripper deleted.
	blocked := filepath.Join(dir, "side.db")
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: main})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	_, rerr := conn.Read(context.Background(), QuerySpec{Raw: payload(blocked)}, 10)
	if rerr == nil {
		t.Fatal("the read-only gate ALLOWED a payload that creates a database file on disk")
	}
	msg, ok := IsUserError(rerr)
	if !ok || msg != "multiple statements are not allowed in read-only mode" {
		t.Fatalf("unexpected rejection: %T %q", rerr, msg)
	}
	if _, err := os.Stat(blocked); err == nil {
		t.Fatalf("%s was created on disk by a read-only tool", blocked)
	}

	// The other half: ordinary comments must still be stripped, so the
	// gate did not buy this by refusing everything with a "--" in it.
	if _, err := conn.Read(context.Background(),
		QuerySpec{Raw: "SELECT 1 -- an ordinary comment"}, 10); err != nil {
		t.Fatalf("an ordinary commented read must still be allowed: %v", err)
	}
}

// TestSQLiteDashSlashStarBypassIsBlocked pins the bypass that came from
// MySQL and SQLite disagreeing about "--". MySQL needs whitespace or a
// control character after the second dash, so "SELECT 1--/*" is arithmetic
// to it and the "/*" is live; SQLite treats "--" as a comment introducer
// unconditionally, so for SQLite that whole line is dead and the NEXT line
// is a live statement. A stripper that keeps the line (MySQL's reading) but
// still lets the "/*" on it open a block comment deletes the next two
// lines — which is what happened, and this is the end-to-end proof.
//
// ATTACH is the payload rather than DROP for a specific reason, recorded
// here because it is the difference between "the gate held" and "the second
// lock held": measured, the DROP variant of this payload also reached the
// engine and was refused only by the connection's mode=ro ("attempt to
// write a readonly database"). ATTACH is NOT refused by mode=ro. It creates
// a file.
func TestSQLiteDashSlashStarBypassIsBlocked(t *testing.T) {
	dir := t.TempDir()
	main := filepath.Join(dir, "main.db")
	seed, err := sql.Open("sqlite", main)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Exec("CREATE TABLE t (x int)"); err != nil {
		t.Fatal(err)
	}
	seed.Close()

	payload := func(target string) string {
		return "SELECT 1--/*\n; ATTACH DATABASE '" + target + "' AS s\n-- */"
	}

	// The premise: on the DSN sqliteDriver.Connect builds, mode=ro and all,
	// this really is live SQL and really creates a file.
	proof := filepath.Join(dir, "dss_proof.db")
	rawDB, err := sql.Open("sqlite", sqliteReadOnlyDSN(main))
	if err != nil {
		t.Fatal(err)
	}
	rows, err := rawDB.Query(payload(proof))
	if err != nil {
		rawDB.Close()
		t.Skipf("this build of modernc.org/sqlite refused the payload (%v); nothing to prove the gate against", err)
	}
	rows.Close()
	rawDB.Close()
	if _, err := os.Stat(proof); err != nil {
		t.Skipf("ATTACH did not create %s (%v); nothing to prove the gate against", proof, err)
	}

	blocked := filepath.Join(dir, "dss_side.db")
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: main})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	_, rerr := conn.Read(context.Background(), QuerySpec{Raw: payload(blocked)}, 10)
	if rerr == nil {
		t.Fatal("the read-only gate ALLOWED a payload that creates a database file on disk")
	}
	msg, ok := IsUserError(rerr)
	if !ok || msg != "multiple statements are not allowed in read-only mode" {
		t.Fatalf("unexpected rejection: %T %q", rerr, msg)
	}
	if _, err := os.Stat(blocked); err == nil {
		t.Fatalf("%s was created on disk by a read-only tool", blocked)
	}

	// The other half: an ordinary arithmetic "--" read, which SQLite reads
	// as a comment, must still be allowed rather than caught by the
	// give-up rule turning into a blanket refusal.
	if _, err := conn.Read(context.Background(),
		QuerySpec{Raw: "SELECT 10--5 AS v"}, 10); err != nil {
		t.Fatalf("an ordinary double-minus read must still be allowed: %v", err)
	}
}

// TestSQLiteBracketIdentifierBypassIsBlocked pins the bypass that came from
// SQLite having a span MySQL does not have at all. SQLite (and T-SQL) quote
// identifiers with "[ ... ]", so the "--" inside "[a-- ]" is live SQL to
// SQLite; to a scanner that does not know brackets exist it is a comment
// introducer, and the rest of the line — here a ";" and an ATTACH — is
// deleted before any check in AssertSQLReadOnly runs.
//
// Both halves of the disagreement are measured. modernc.org/sqlite answers
// 1 to "SELECT 1 AS [a-- ]"; MySQL 8.4.11 answers
// "ERROR 1064 (42000) ... near '[a-- ]'". That is why the scanner gives up
// on "[" rather than modelling a bracket span: there is no reading both
// engines share.
func TestSQLiteBracketIdentifierBypassIsBlocked(t *testing.T) {
	dir := t.TempDir()
	main := filepath.Join(dir, "main.db")
	seed, err := sql.Open("sqlite", main)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Exec("CREATE TABLE t (x int)"); err != nil {
		t.Fatal(err)
	}
	seed.Close()

	payload := func(target string) string {
		return "SELECT 1 AS [a-- ];ATTACH DATABASE '" + target + "' AS s"
	}

	rawDB, err := sql.Open("sqlite", sqliteReadOnlyDSN(main))
	if err != nil {
		t.Fatal(err)
	}
	defer rawDB.Close()

	// The premise, part one: "[a-- ]" is an identifier to SQLite, not the
	// start of a comment. If that ever stops being true this test is
	// pinning a payload that no longer means anything.
	var v int
	if err := rawDB.QueryRow("SELECT 1 AS [a-- ]").Scan(&v); err != nil || v != 1 {
		t.Skipf("this build does not read [a-- ] as an identifier (v=%d err=%v); "+
			"the bypass this test pins does not apply to it", v, err)
	}

	// The premise, part two: on the DSN sqliteDriver.Connect builds,
	// mode=ro and all, the payload really creates a file.
	proof := filepath.Join(dir, "bracket_proof.db")
	rows, err := rawDB.Query(payload(proof))
	if err != nil {
		t.Skipf("this build of modernc.org/sqlite refused the payload (%v); nothing to prove the gate against", err)
	}
	rows.Close()
	if _, err := os.Stat(proof); err != nil {
		t.Skipf("ATTACH did not create %s (%v); nothing to prove the gate against", proof, err)
	}

	blocked := filepath.Join(dir, "bracket_side.db")
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: main})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	_, rerr := conn.Read(context.Background(), QuerySpec{Raw: payload(blocked)}, 10)
	if rerr == nil {
		t.Fatal("the read-only gate ALLOWED a payload that creates a database file on disk")
	}
	msg, ok := IsUserError(rerr)
	if !ok || msg != "multiple statements are not allowed in read-only mode" {
		t.Fatalf("unexpected rejection: %T %q", rerr, msg)
	}
	if _, err := os.Stat(blocked); err == nil {
		t.Fatalf("%s was created on disk by a read-only tool", blocked)
	}

	// The other half: an ordinary bracket-quoted read must still work
	// through the gate, so the give-up arm is not a blanket refusal of "[".
	got, err := conn.Read(context.Background(),
		QuerySpec{Raw: "SELECT 1 AS [my col]"}, 10)
	if err != nil {
		t.Fatalf("an ordinary bracket-quoted read must still be allowed: %v", err)
	}
	if len(got.Columns) != 1 || got.Columns[0] != "my col" {
		t.Fatalf("bracket-quoted read returned columns %v, want [my col]", got.Columns)
	}
}

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

// TestSQLiteReadReportsColumnTypes proves the sqlite driver DECLARES a
// type for every column it returns, rather than leaving the caller to
// infer one from the values — the same guarantee the Mongo driver cannot
// make, which is why ColumnTypesInferred exists.
func TestSQLiteReadReportsColumnTypes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "types.db")
	seed, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Exec(`
		CREATE TABLE customers (id INTEGER, name TEXT, balance REAL);
		INSERT INTO customers VALUES (1, 'widgets', 4.5);
	`); err != nil {
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

func TestSQLiteListColumns(t *testing.T) {
	path := seedSQLite(t) // customers(id, name)
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE edit_quote (id INTEGER PRIMARY KEY, transaction_read_only TEXT)`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: path})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	got, err := conn.ListColumns(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := []TableColumns{
		{Table: "customers", Columns: []string{"id", "name"}},
		{Table: "edit_quote", Columns: []string{"id", "transaction_read_only"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ListColumns = %#v, want %#v", got, want)
	}
}
