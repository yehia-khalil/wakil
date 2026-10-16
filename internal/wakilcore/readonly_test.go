package wakilcore

import (
	"strings"
	"testing"
)

// --- Brief's original tables, kept intact verbatim. ---

func TestAssertSQLReadOnly(t *testing.T) {
	ok := []string{
		"SELECT * FROM users WHERE id = 42",
		"  select 1",
		"EXPLAIN SELECT 1",
		"SHOW TABLES",
		"/* c */ SELECT 1",
	}
	for _, q := range ok {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("should allow %q: %v", q, err)
		}
	}
	bad := []string{
		"INSERT INTO t VALUES (1)",
		"UPDATE t SET x=1",
		"DELETE FROM t",
		"DROP TABLE t",
		"SELECT 1; DROP TABLE t",
		"select 1; delete from t",
		"WITH x AS (SELECT 1) DELETE FROM t",
		"TRUNCATE t",
	}
	for _, q := range bad {
		if err := AssertSQLReadOnly(q); err == nil {
			t.Errorf("should reject %q", q)
		}
	}
}

func TestAssertHTTPReadOnly(t *testing.T) {
	for _, m := range []string{"GET", "get", "HEAD"} {
		if err := AssertHTTPReadOnly(m); err != nil {
			t.Errorf("allow %q: %v", m, err)
		}
	}
	for _, m := range []string{"POST", "PUT", "PATCH", "DELETE"} {
		if err := AssertHTTPReadOnly(m); err == nil {
			t.Errorf("reject %q", m)
		}
	}
}

// --- Adversarial coverage added for this task. ---

// assertRejectedAsUserError fails the test unless err is non-nil and is a
// UserError (i.e. carries a human-facing message), not merely non-nil.
func assertRejectedAsUserError(t *testing.T, label string, err error) {
	t.Helper()
	if err == nil {
		t.Fatalf("should reject %s, got nil error", label)
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("rejection of %s should be a UserError, got %T: %v", label, err, err)
	}
}

// Resolution 1: a bare INTO must be blocked, because "SELECT ... INTO
// OUTFILE/DUMPFILE" (MySQL) writes a file to disk despite starting with
// SELECT and containing none of the brief's original write keywords.
func TestAssertSQLReadOnly_IntoWriteBypass(t *testing.T) {
	bad := []string{
		"SELECT * FROM users INTO OUTFILE '/tmp/x'",
		"SELECT * FROM users INTO DUMPFILE '/tmp/x'",
	}
	for _, q := range bad {
		assertRejectedAsUserError(t, q, AssertSQLReadOnly(q))
	}
}

// Resolution 2: the blocked keyword set is extended to cover write and
// side-effect verbs from engines the brief's list missed (SQLite ATTACH/
// PRAGMA, Postgres COPY, and PREPARE/EXECUTE which run arbitrary SQL
// supplied as a string). Each shape below passes the allowed-prefix check
// and contains no ";" (so it isn't caught by the multiple-statement guard)
// and must instead be caught by the keyword scan itself.
func TestAssertSQLReadOnly_ExtendedKeywords(t *testing.T) {
	cases := []struct {
		name string
		sql  string
	}{
		{"ATTACH", "SELECT 1 ATTACH DATABASE 'x' AS y"},
		{"DETACH", "SELECT 1 DETACH DATABASE y"},
		{"PRAGMA", "WITH x AS (SELECT 1) PRAGMA journal_mode=WAL"},
		{"VACUUM", "WITH x AS (SELECT 1) VACUUM"},
		{"REINDEX", "SELECT 1 REINDEX TABLE t"},
		{"COPY", "SELECT 1 COPY (SELECT 1) TO '/tmp/x'"},
		{"LOAD", "SELECT 1 LOAD DATA INFILE '/tmp/x'"},
		{"PREPARE", "SELECT 1 PREPARE stmt FROM 'DELETE FROM t'"},
		{"EXECUTE", "SELECT 1 EXECUTE stmt"},
		{"DEALLOCATE", "SELECT 1 DEALLOCATE stmt"},
		{"HANDLER", "SELECT 1 HANDLER t OPEN"},
		{"DO", "WITH x AS (SELECT 1) DO 1"},
		{"UPSERT", "SELECT 1 UPSERT t (x) VALUES (1)"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assertRejectedAsUserError(t, c.sql, AssertSQLReadOnly(c.sql))
		})
	}
}

// Comment smuggling: comments are stripped before the keyword scan, but a
// write that lives outside the comment (after a line comment's newline, or
// after a block comment closes) must still be caught. The nested-looking
// block comment is the classic bypass attempt: real SQL does not nest
// comments, so "/* /* */ DELETE FROM t */" closes at the FIRST "*/",
// leaving "DELETE FROM t */" as live text. A naive/greedy stripper would be
// fooled into treating the whole thing as one comment and let the DELETE
// through; the non-greedy regexp used here must not be fooled.
func TestAssertSQLReadOnly_CommentSmuggling(t *testing.T) {
	cases := map[string]string{
		"write after line comment":     "SELECT 1 -- comment\nDELETE FROM t",
		"write after block comment":    "SELECT 1 /* comment */ DELETE FROM t",
		"nested-looking block comment": "SELECT 1 /* /* */ DELETE FROM t */",
	}
	for name, q := range cases {
		t.Run(name, func(t *testing.T) {
			assertRejectedAsUserError(t, q, AssertSQLReadOnly(q))
		})
	}
}

// A trailing semicolon on an otherwise valid single read must still be
// allowed: it is not a second statement, just terminator punctuation.
func TestAssertSQLReadOnly_TrailingSemicolonAllowed(t *testing.T) {
	if err := AssertSQLReadOnly("SELECT 1;"); err != nil {
		t.Errorf("trailing semicolon on a single read should be allowed: %v", err)
	}
}

// Case and whitespace variations must not affect the verdict.
func TestAssertSQLReadOnly_CaseAndWhitespace(t *testing.T) {
	ok := []string{
		"sElEcT 1",
		"\t\n  SELECT 1",
		"\n\t\tselect 1 from dual",
	}
	for _, q := range ok {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("should allow %q: %v", q, err)
		}
	}
}

// Resolution 3 (fix round 1): SHOW statements need a narrow CREATE/GRANT
// carve-out, not a blanket exemption from the write-keyword scan. SHOW
// CREATE TABLE and SHOW GRANTS are ordinary reads that happen to contain
// the substrings CREATE and GRANT, so those two tokens are suppressed for
// SHOW-prefixed statements. Every other blocked keyword must remain
// active: a fix-round-1 review found that the original blanket exemption
// let literal write keywords (DELETE, DROP, SET, UPSERT, ...) pass
// straight through a SHOW-prefixed string with no comment trick or
// semicolon needed at all.
func TestAssertSQLReadOnly_ShowExemption(t *testing.T) {
	ok := []string{
		"SHOW CREATE TABLE t",
		"SHOW GRANTS",
	}
	for _, q := range ok {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("should allow %q: %v", q, err)
		}
	}
	// The exemption must not defeat the multiple-statement guard.
	if err := AssertSQLReadOnly("SHOW GRANTS; DELETE FROM t"); err == nil {
		t.Error("SHOW exemption must not bypass the multiple-statement guard")
	} else if _, ok := IsUserError(err); !ok {
		t.Errorf("rejection should be a UserError, got %T: %v", err, err)
	}
}

// The blanket SHOW exemption (fix round 1 finding) let any write keyword
// other than CREATE/GRANT straight through a SHOW-prefixed statement, with
// no comment trick or semicolon required. These must all still be
// rejected after narrowing the carve-out to CREATE/GRANT only.
func TestAssertSQLReadOnly_ShowDoesNotExemptOtherWriteKeywords(t *testing.T) {
	bad := []string{
		"SHOW DELETE FROM t",
		"SHOW DROP TABLE t",
		"SHOW SET x=1",
		"SHOW UPSERT t (x) VALUES (1)",
	}
	for _, q := range bad {
		t.Run(q, func(t *testing.T) {
			assertRejectedAsUserError(t, q, AssertSQLReadOnly(q))
		})
	}
}

// The SHOW carve-out must compose correctly with the /*! */ executable-
// comment handling: a write hidden inside a MySQL executable comment must
// still be caught even when the statement starts with SHOW.
func TestAssertSQLReadOnly_ShowDoesNotExemptExecutableCommentWrites(t *testing.T) {
	q := "SHOW /*!50000 DELETE FROM t */ TABLES"
	assertRejectedAsUserError(t, q, AssertSQLReadOnly(q))
}

// Fix round 2: the CREATE/GRANT-only carve-out (fix round 1) was itself
// too narrow — "SHOW CHARACTER SET" is a legitimate MySQL read containing
// the standalone word SET, and SET must stay blocked in general (a bare
// "SHOW SET x=1" must still be rejected). The carve-out must be positional
// — only the exact phrase "CHARACTER SET" (with arbitrary whitespace
// between the words) is exempted, not every occurrence of SET.
func TestAssertSQLReadOnly_ShowCharacterSetCarveOut(t *testing.T) {
	ok := []string{
		"SHOW CHARACTER SET",
		"SHOW CHARACTER   SET", // tolerant of extra whitespace
	}
	for _, q := range ok {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("should allow %q: %v", q, err)
		}
	}
	// A bare SET (not preceded by CHARACTER) must still be rejected: the
	// carve-out is positional, not a blanket exemption for SET.
	q := "SHOW SET x=1"
	assertRejectedAsUserError(t, q, AssertSQLReadOnly(q))
}

// Regression cover for the enumeration approach: SHOW CREATE ... and SHOW
// GRANTS remain allowed (as of fix round 1), and non-colliding SHOW forms
// that were never blocked remain allowed too.
func TestAssertSQLReadOnly_ShowNonCollidingFormsStillAllowed(t *testing.T) {
	ok := []string{
		"SHOW CREATE TABLE t",
		"SHOW GRANTS",
		"SHOW TABLES",
		"SHOW COLLATION",
		"SHOW BINARY LOGS",
	}
	for _, q := range ok {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("should allow %q: %v", q, err)
		}
	}
}

// All previously-required SHOW rejections must still hold after adding the
// CHARACTER SET carve-out.
func TestAssertSQLReadOnly_ShowStillRejectsWriteKeywords(t *testing.T) {
	bad := []string{
		"SHOW DELETE FROM t",
		"SHOW DROP TABLE t",
		"SHOW UPSERT t (x) VALUES (1)",
		"SHOW /*!50000 DELETE FROM t */ TABLES",
	}
	for _, q := range bad {
		t.Run(q, func(t *testing.T) {
			assertRejectedAsUserError(t, q, AssertSQLReadOnly(q))
		})
	}
}

// Resolution 4: this gate is a textual scan, not a literal-aware SQL
// parser. A write keyword inside a quoted string literal is rejected along
// with everything else — that is a deliberate, accepted false rejection
// (erring toward rejection is correct for a safety gate), pinned here so a
// future maintainer does not "fix" it by adding literal-aware parsing and
// quietly opening a bypass.
func TestAssertSQLReadOnly_StringLiteralFalsePositive(t *testing.T) {
	q := "SELECT * FROM t WHERE action = 'DELETE'"
	assertRejectedAsUserError(t, q, AssertSQLReadOnly(q))
}

// Self-discovered bypass (not one of the four listed resolutions): MySQL's
// "/*! ... */" executable-comment syntax is not a dead comment to MySQL's
// own parser. It strips only the /*! and */ delimiters and executes the
// content in between as live SQL (unconditionally, or conditionally on
// server version if digits follow the "!"). Treating it as an ordinary,
// discardable comment — as a naive stripper would — hides both a write
// keyword and a statement-separating ";" from every check in this gate,
// while a real MySQL server would still see and potentially execute that
// content. The gate must treat the content of "/*! ... */" as live text.
func TestAssertSQLReadOnly_MySQLExecutableCommentBypass(t *testing.T) {
	cases := map[string]string{
		"write hidden in executable comment":        "SELECT 1 /*! DELETE FROM t */",
		"versioned executable comment with write":   "SELECT 1 /*!50000 DELETE FROM t */",
		"second statement smuggled via ; inside it": "SELECT 1 /*!50000; DELETE FROM t*/",
	}
	for name, q := range cases {
		t.Run(name, func(t *testing.T) {
			assertRejectedAsUserError(t, q, AssertSQLReadOnly(q))
		})
	}
	// A genuinely harmless /*! ... */ hint that contains no write keyword
	// and no ";" must still be allowed — the fix must not reject every
	// executable comment outright, only ones that carry blocked content.
	if err := AssertSQLReadOnly("SELECT /*! SQL_NO_CACHE */ * FROM t"); err != nil {
		t.Errorf("a benign executable-comment hint should still be allowed: %v", err)
	}
}

func TestAssertHTTPReadOnly_Adversarial(t *testing.T) {
	assertRejectedAsUserError(t, "empty method", AssertHTTPReadOnly(""))

	for _, m := range []string{"Get", "hEaD"} {
		if err := AssertHTTPReadOnly(m); err != nil {
			t.Errorf("should allow %q: %v", m, err)
		}
	}

	for _, m := range []string{"OPTIONS", "TRACE", "CONNECT"} {
		assertRejectedAsUserError(t, m, AssertHTTPReadOnly(m))
	}
}

// --- Mongo gate (Task 12). Brief's table, kept intact verbatim. ---

func TestAssertMongoReadOnly(t *testing.T) {
	ok := []string{
		`{"collection":"u","op":"find","filter":{"id":42}}`,
		`{"collection":"u","op":"aggregate","pipeline":[{"$match":{"x":1}}]}`,
		`{"collection":"u","op":"count"}`,
	}
	for _, q := range ok {
		if err := AssertMongoReadOnly(q); err != nil {
			t.Errorf("allow %q: %v", q, err)
		}
	}
	bad := []string{
		`{"collection":"u","op":"insertOne","doc":{}}`,
		`{"collection":"u","op":"updateMany"}`,
		`{"collection":"u","op":"deleteOne"}`,
		`{"collection":"u","op":"bulkWrite"}`,
		`{"collection":"u","op":"findAndModify"}`,
		`{"collection":"u","op":"aggregate","pipeline":[{"$out":"copy"}]}`,
		`{"collection":"u","op":"aggregate","pipeline":[{"$merge":"copy"}]}`,
	}
	for _, q := range bad {
		if err := AssertMongoReadOnly(q); err == nil {
			t.Errorf("reject %q", q)
		}
	}
}

// TestAssertMongoReadOnly_RecursiveOutMerge proves the gate scans an
// aggregation pipeline recursively, not just the top-level stage keys, per
// resolution 2. A naive top-level-only scan (the brief's original sample)
// would miss $out/$merge nested inside a $unionWith or $facet
// sub-pipeline. MongoDB's server currently rejects $out/$merge in those
// positions too, but this gate does not rely on that — the SQL gate above
// needed three separate bypass-hardening rounds precisely because it
// depended on assumptions like this one turning out to be wrong.
func TestAssertMongoReadOnly_RecursiveOutMerge(t *testing.T) {
	bad := map[string]string{
		"$out nested inside $unionWith": `{"collection":"u","op":"aggregate","pipeline":[
			{"$unionWith":{"coll":"other","pipeline":[{"$out":"copy"}]}}
		]}`,
		"$merge nested inside $unionWith": `{"collection":"u","op":"aggregate","pipeline":[
			{"$unionWith":{"coll":"other","pipeline":[{"$merge":"copy"}]}}
		]}`,
		"$out nested inside $facet": `{"collection":"u","op":"aggregate","pipeline":[
			{"$facet":{"a":[{"$match":{"x":1}}],"b":[{"$out":"copy"}]}}
		]}`,
		"$merge nested inside $facet": `{"collection":"u","op":"aggregate","pipeline":[
			{"$facet":{"a":[{"$merge":"copy"}]}}
		]}`,
		"$out nested two levels deep inside $lookup": `{"collection":"u","op":"aggregate","pipeline":[
			{"$lookup":{"from":"other","pipeline":[{"$facet":{"a":[{"$out":"copy"}]}}],"as":"joined"}}
		]}`,
	}
	for name, q := range bad {
		t.Run(name, func(t *testing.T) {
			assertRejectedAsUserError(t, name, AssertMongoReadOnly(q))
		})
	}
	// A benign nested pipeline containing no $out/$merge at any depth
	// must still be allowed.
	ok := `{"collection":"u","op":"aggregate","pipeline":[
		{"$unionWith":{"coll":"other","pipeline":[{"$match":{"x":1}}]}}
	]}`
	if err := AssertMongoReadOnly(ok); err != nil {
		t.Errorf("should allow nested read-only pipeline: %v", err)
	}
}

// TestAssertMongoReadOnly_MalformedAndIncomplete proves the gate rejects
// (as a UserError, never a raw parse panic or generic error) invalid JSON
// and specs missing required fields, rather than only checking the op.
func TestAssertMongoReadOnly_MalformedAndIncomplete(t *testing.T) {
	cases := map[string]string{
		"invalid JSON":       `{"collection":"u","op":`,
		"missing collection": `{"op":"find","filter":{}}`,
		"missing op":         `{"collection":"u","filter":{}}`,
		"empty string":       ``,
	}
	for name, q := range cases {
		t.Run(name, func(t *testing.T) {
			assertRejectedAsUserError(t, name, AssertMongoReadOnly(q))
		})
	}
}

// --- Fix round: MySQL's "--" is not always a comment. ---

// assertRejectedWithMessage fails unless err is a UserError whose message
// is exactly want. The exact message matters here and a bare "some error
// came back" assertion would not: the two bypasses below are caught by
// two DIFFERENT checks in AssertSQLReadOnly (the write-keyword scan and
// the multiple-statement guard), and a fix that accidentally routed one
// through the other's check would still be a fix, but a fix that stopped
// stripping "--" comments ENTIRELY would also turn every one of these
// green while breaking ordinary queries — so the allow cases below are
// just as load bearing as the reject cases.
func assertRejectedWithMessage(t *testing.T, sql, want string) {
	t.Helper()
	err := AssertSQLReadOnly(sql)
	if err == nil {
		t.Fatalf("should reject %q, got nil error", sql)
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("rejection of %q should be a UserError, got %T: %v", sql, err, err)
	}
	if msg != want {
		t.Fatalf("rejecting %q: got message %q, want %q", sql, msg, want)
	}
}

// TestAssertSQLReadOnly_MySQLDoubleDashIsNotAlwaysAComment pins the
// critical bypass this fix round closed. The gate used to strip
// `--[^\n]*` unconditionally, but MySQL only starts a comment when the
// second dash is followed by whitespace or a control character —
// "SELECT 1--1" is 1 - (-1) = 2, measured on the live MySQL 8 used for
// acceptance. So the gate DELETED text the server EXECUTES, before every
// one of its own checks ran.
//
// The first case below was reproduced end to end through the wakil-db
// read path against a real server and wrote a file on the database host
// (/var/lib/mysql-files/ctl_probe.txt) from a tool that is supposed to be
// read-only; the live half of that reproduction is
// TestMySQLDoubleDashOutfileBypassIsBlocked in driver_mysql_test.go. The
// second case slipped past the multiple-statement guard for a related
// reason: comment stripping runs BEFORE the ";" check, so the entire
// second statement was gone by the time anything looked for a ";".
func TestAssertSQLReadOnly_MySQLDoubleDashIsNotAlwaysAComment(t *testing.T) {
	t.Run("INTO OUTFILE hidden behind --1", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1--1 INTO OUTFILE '/var/lib/mysql-files/ctl_probe.txt'",
			"query contains a write operation and was blocked (read-only)")
	})
	t.Run("second statement hidden behind --1", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1--1; DROP TABLE customers",
			"multiple statements are not allowed in read-only mode")
	})
	t.Run("DUMPFILE hidden behind --1", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1--1 INTO DUMPFILE '/var/lib/mysql-files/x'",
			"query contains a write operation and was blocked (read-only)")
	})
	// A newline may NOT introduce the comment: to MySQL, "--" at the end
	// of a line opens and closes an empty comment there, and the NEXT
	// line is live SQL. A pattern that let its "rest of line" tail start
	// after a newline would swallow that live line and re-create this bug
	// in a new shape.
	t.Run("write on the line after a bare --", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1--\nDELETE FROM t",
			"query contains a write operation and was blocked (read-only)")
	})
}

// TestAssertSQLReadOnly_GenuineDoubleDashCommentsStillAllowed is the
// other half of the fix and is not optional: a gate that simply stopped
// treating "--" as a comment introducer would pass every case in the
// test above while rejecting ordinary queries, i.e. it would be "secure"
// by being useless. Each case here was executed against the live MySQL 8
// used for acceptance and returned the value in the comment, so these are
// real reads a user can legitimately send, not invented shapes.
func TestAssertSQLReadOnly_GenuineDoubleDashCommentsStillAllowed(t *testing.T) {
	ok := []string{
		"SELECT 1 -- a comment",       // live MySQL -> 1
		"SELECT 10--5 AS arith",       // live MySQL -> 15 (10 - (-5))
		"SELECT 1--(2) AS p",          // live MySQL -> 3
		"SELECT 5--\t6 AS c",          // live MySQL -> 5 (tab starts a comment)
		"SELECT 1 --",                 // live MySQL -> 1 (comment at end of input)
		"SELECT id FROM t -- by id\n", // trailing newline after a comment
	}
	for _, q := range ok {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("should allow %q: %v", q, err)
		}
	}
}

// TestAssertSQLReadOnly_MultipleStatementsLayer pins the ";" guard on
// inputs where it is the ONLY thing rejecting: every statement below is a
// pair of perfectly ordinary READS, so the prefix allowlist is satisfied
// and the write-keyword scan finds nothing. Delete the ";" check and these
// are allowed.
//
// The existing multi-statement cases elsewhere in this file all pair a
// SELECT with a write (";DROP", ";DELETE"), so the keyword scan catches
// them anyway and they cannot tell the two layers apart.
//
// Why the guard matters even though go-sql-driver's MultiStatements is
// forced off (driver_mysql.go, hardenMySQLConfig): that is one engine's
// client library. SQLite's driver executes every statement in the string
// it is handed — measured on modernc.org/sqlite, Query("SELECT * FROM v;
// DROP TABLE u") returns no error and u is gone — so for SQLite this
// textual check is not a second lock, it is the lock.
//
// The exact message is asserted, not merely "an error", so the test also
// pins WHICH layer refused.
func TestAssertSQLReadOnly_MultipleStatementsLayer(t *testing.T) {
	const want = "multiple statements are not allowed in read-only mode"
	cases := []struct {
		name string
		sql  string
	}{
		{"two selects", "SELECT 1; SELECT 2"},
		{"select then show", "SELECT 1; SHOW TABLES"},
		{"select then explain", "SELECT 1; EXPLAIN SELECT 2"},
		{"three reads", "SELECT 1; SELECT 2; SELECT 3"},
		{"separator in the middle of a read", "SELECT id FROM t WHERE x=1; SELECT id FROM u"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assertRejectedWithMessage(t, c.sql, want)
		})
	}
	// The other half: a SINGLE trailing ";" is not a second statement and
	// must still be allowed, so the guard cannot be "fixed" by rejecting
	// every ";" outright.
	for _, q := range []string{"SELECT 1;", "SELECT 1 ;  ", "SELECT 1;\n"} {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("a single trailing ';' is not a second statement; should allow %q: %v", q, err)
		}
	}
}

// TestAssertSQLReadOnly_PrefixAllowlistLayer pins the leading-keyword
// allowlist on the inputs where it is the ONLY layer that refuses.
//
// Every statement below is a REAL MySQL statement with a REAL effect, and
// none of them contains any keyword in writeKeyword — that is precisely
// what makes them the right fixture. Each was executed against the live
// MySQL 8.4.11 used for acceptance; these are the responses, not guesses:
//
//	OPTIMIZE TABLE t -> "Table does not support optimize, doing recreate +
//	                     analyze instead" / status OK. On InnoDB it
//	                     REBUILDS the table. Unambiguously a write.
//	REPAIR TABLE t   -> "The storage engine for the table doesn't support
//	                     repair". Accepted and dispatched; a no-op on
//	                     InnoDB only because of the storage engine, and on
//	                     MyISAM it rewrites the table and its indexes.
//	FLUSH TABLES     -> accepted, no error. Closes open tables server-wide.
//	KILL 5           -> "ERROR 1094 (HY000): Unknown thread id: 5", i.e.
//	                     parsed and dispatched, and it only failed because
//	                     nothing had id 5. Aimed at a live thread it really
//	                     terminates the victim: killing a running
//	                     "SELECT SLEEP(30)" gave that session "ERROR 2013
//	                     Lost connection to MySQL server during query" and
//	                     the row vanished from information_schema.processlist.
//	USE otherdb      -> accepted; SELECT DATABASE() in the same session then
//	                     returned "otherdb". The session really moved.
//
// Delete the prefix allowlist and all five sail through the keyword scan
// untouched, because there is no INSERT/UPDATE/DELETE/DROP/... anywhere in
// them. No other layer in AssertSQLReadOnly would notice.
//
// The exact message is asserted, not merely "an error", so the test pins
// WHICH layer refused rather than accepting a coincidental rejection from
// the keyword scan.
func TestAssertSQLReadOnly_PrefixAllowlistLayer(t *testing.T) {
	const want = "only SELECT/EXPLAIN/SHOW queries are allowed (read-only)"
	cases := []struct {
		name string
		sql  string
	}{
		{"OPTIMIZE TABLE", "OPTIMIZE TABLE t"},
		{"REPAIR TABLE", "REPAIR TABLE t"},
		{"FLUSH TABLES", "FLUSH TABLES"},
		{"KILL", "KILL 5"},
		{"USE", "USE otherdb"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// Guard the premise: if a future edit adds one of these verbs
			// to writeKeyword, the keyword scan starts covering this case
			// and the test silently stops testing the allowlist.
			if writeKeyword.MatchString(c.sql) {
				t.Fatalf("%q now matches writeKeyword, so it no longer isolates the prefix "+
					"allowlist; pick a statement no other layer catches", c.sql)
			}
			assertRejectedWithMessage(t, c.sql, want)
		})
	}
	// The other half: the four allowed prefixes must still be allowed, so
	// the allowlist cannot be "fixed" by rejecting everything.
	for _, q := range []string{"SELECT 1", "EXPLAIN SELECT 1", "SHOW TABLES", "WITH x AS (SELECT 1) SELECT * FROM x"} {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("should allow %q: %v", q, err)
		}
	}
}

// --- Fix round: a comment introducer is not context-free. ---

// TestAssertSQLReadOnly_CommentIntroducersAreNotContextFree pins the third
// bypass of this gate (see the plan's Finding 1). Each case hides live SQL
// from the gate by making one comment syntax open a span that another
// syntax, or a string literal, should have made inert.
//
// These are not hypotheticals. The controller ran the first two against the
// live MySQL 8.4.11 acceptance container: the UNION form returned rows 1 and
// 2, and the INTO OUTFILE form wrote a 2-byte file on the database server.
func TestAssertSQLReadOnly_CommentIntroducersAreNotContextFree(t *testing.T) {
	for _, tc := range []struct {
		name, query, wantMsg string
	}{
		{
			name:    "block comment opened inside a -- line comment hides INTO OUTFILE",
			query:   "SELECT 1 -- /*\nINTO OUTFILE '/var/lib/mysql-files/x.txt'\n-- */",
			wantMsg: "query contains a write operation",
		},
		{
			name:    "block comment opened inside a -- line comment hides DELETE",
			query:   "SELECT 1 -- /*\nDELETE FROM customers\n-- */",
			wantMsg: "query contains a write operation",
		},
		{
			name:    "block comment opened inside a # line comment hides DELETE",
			query:   "SELECT 1 # /*\nDELETE FROM customers\n# */",
			wantMsg: "query contains a write operation",
		},
		{
			name:    "block comment opened inside a string literal hides a second statement",
			query:   "SELECT '/*' ; DROP TABLE t -- */",
			wantMsg: "multiple statements are not allowed",
		},
		{
			name:    "line comment introducer inside a string literal does not start a comment",
			query:   "SELECT '-- ' , x FROM t WHERE y = 1 ; DROP TABLE t",
			wantMsg: "multiple statements are not allowed",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := AssertSQLReadOnly(tc.query)
			if err == nil {
				t.Fatalf("gate ALLOWED a query that hides live SQL: %q (stripped to %q)",
					tc.query, stripSQLComments(tc.query))
			}
			if !strings.Contains(err.Error(), tc.wantMsg) {
				t.Errorf("rejected for the wrong reason: got %q, want a message containing %q",
					err.Error(), tc.wantMsg)
			}
		})
	}
}

// TestStripSQLComments pins the exact output of the scanner on the corpus
// the design was validated against, including the four cases that are pure
// regression cover for behaviour earlier rounds got right. Asserting the
// STRING, not just the eventual verdict, is what makes this test able to
// notice a scanner that reaches the right answer for the wrong reason.
func TestStripSQLComments(t *testing.T) {
	for _, tc := range []struct {
		name, in, want string
	}{
		{
			name: "block comment opened inside a -- comment does not swallow the next line",
			in:   "SELECT 1 -- /*\nINTO OUTFILE '/var/lib/mysql-files/x.txt'\n-- */",
			want: "SELECT 1  \nINTO OUTFILE '/var/lib/mysql-files/x.txt'\n ",
		},
		{
			name: "a # line is copied verbatim, so nothing inside it opens a span",
			in:   "SELECT 1 # /*\nDELETE FROM customers\n# */",
			want: "SELECT 1 # /*\nDELETE FROM customers\n# */",
		},
		{
			name: "a /* inside a string literal opens nothing",
			in:   "SELECT '/*' ; DROP TABLE t -- */",
			want: "SELECT '/*' ; DROP TABLE t  ",
		},
		{
			name: "a -- inside a string literal opens nothing",
			in:   "SELECT '-- ' , x FROM t WHERE y = 1 ; DROP TABLE t",
			want: "SELECT '-- ' , x FROM t WHERE y = 1 ; DROP TABLE t",
		},
		// The remaining cases are regression cover: each is behaviour a
		// previous round established and this rewrite must not change.
		{"ordinary line comment", "SELECT 1 -- an ordinary comment", "SELECT 1  "},
		{
			name: "ordinary block comment",
			in:   "SELECT * FROM customers /* a note */ WHERE id = 1",
			want: "SELECT * FROM customers   WHERE id = 1",
		},
		{
			name: "567fc08: --1 is arithmetic, not a comment",
			in:   "SELECT 1--1 INTO OUTFILE '/tmp/x'",
			want: "SELECT 1--1 INTO OUTFILE '/tmp/x'",
		},
		{
			name: "MySQL executable comment stays live",
			in:   "SELECT 1 /*!50000; DROP TABLE t*/",
			want: "SELECT 1 /*!50000; DROP TABLE t*/",
		},
		{
			name: "block comments do not nest",
			in:   "SELECT 1 /* /* */ DELETE FROM t */",
			want: "SELECT 1   DELETE FROM t */",
		},
		{
			name: "newline is not a -- introducer",
			in:   "SELECT 1--\nDELETE FROM t",
			want: "SELECT 1--\nDELETE FROM t",
		},
		{
			name: "unterminated block comment leaves the remainder alone",
			in:   "SELECT 1 /* DELETE FROM t",
			want: "SELECT 1 /* DELETE FROM t",
		},
		// The five give-up rules. Each copies the whole remainder.
		{
			name: "a non-introducer -- stops stripping",
			in:   "SELECT 1--/*\n; ATTACH DATABASE '/tmp/x' AS s\n-- */",
			want: "SELECT 1--/*\n; ATTACH DATABASE '/tmp/x' AS s\n-- */",
		},
		{
			name: "a # stops stripping",
			in:   "SELECT 1 # x\n-- ; DROP TABLE t",
			want: "SELECT 1 # x\n-- ; DROP TABLE t",
		},
		{
			name: "an ambiguous backslash literal stops stripping",
			in:   `SELECT 'a\' -- ' ; DROP TABLE t`,
			want: `SELECT 'a\' -- ' ; DROP TABLE t`,
		},
		{
			name: "a [ bracket identifier stops stripping",
			in:   "SELECT 1 AS [a-- ];ATTACH DATABASE '/tmp/x' AS s",
			want: "SELECT 1 AS [a-- ];ATTACH DATABASE '/tmp/x' AS s",
		},
		{
			name: "a /*! executable comment stops stripping",
			in:   "SELECT 1 /*!50000 ' */ -- ' INTO OUTFILE '/tmp/p7' */",
			want: "SELECT 1 /*!50000 ' */ -- ' INTO OUTFILE '/tmp/p7' */",
		},
		{
			name: "a benign /*! is still copied whole",
			in:   "SELECT /*! SQL_NO_CACHE */ * FROM t",
			want: "SELECT /*! SQL_NO_CACHE */ * FROM t",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := stripSQLComments(tc.in); got != tc.want {
				t.Errorf("stripSQLComments(%q)\n got  %q\n want %q", tc.in, got, tc.want)
			}
		})
	}
}

// TestScanQuotedSpan pins the span boundaries the scanner depends on,
// including the deliberate decision NOT to honour backslash escapes.
func TestScanQuotedSpan(t *testing.T) {
	for _, tc := range []struct {
		name, in string
		want     int
	}{
		{"simple", `'abc' rest`, 5},
		{"doubled quote stays inside", `'a''b' rest`, 6},
		{"unterminated runs to end", `'abc`, 4},
		{"backslash does NOT escape", `'a\' , x`, 4},
		{"double quotes", `"ab" x`, 4},
		{"backtick identifier", "`ab` x", 4},
		{"empty span", `'' x`, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := scanQuotedSpan(tc.in, 0); got != tc.want {
				t.Errorf("scanQuotedSpan(%q, 0) = %d, want %d (span %q)",
					tc.in, got, tc.want, tc.in[:min(got, len(tc.in))])
			}
		})
	}
}

// TestScanQuotedSpanEscaped pins the OTHER reading of the same bytes —
// MySQL's default, where a backslash escapes the next byte. The two
// scanners exist to be COMPARED (see stripSQLComments); a change that made
// them agree on the backslash cases below would silently disable the
// ambiguity guard, so the disagreements are asserted, not incidental.
func TestScanQuotedSpanEscaped(t *testing.T) {
	for _, tc := range []struct {
		name, in        string
		want, wantPlain int
	}{
		{"no backslash: agrees with the plain reading", `'abc' rest`, 5, 5},
		{"doubled quote stays inside", `'a''b' rest`, 6, 6},
		{"backslash before an ordinary byte: still agrees", `'C:\path' x`, 9, 9},
		{"escaped backslash then close: still agrees", `'a\\' -- x`, 5, 5},
		{"escaped quote: DISAGREES, span runs on", `'a\' , x`, 8, 4},
		{"escaped quote then a later quote: DISAGREES", `'a\' , 'b`, 8, 4},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := scanQuotedSpanEscaped(tc.in, 0); got != tc.want {
				t.Errorf("scanQuotedSpanEscaped(%q, 0) = %d, want %d", tc.in, got, tc.want)
			}
			if got := scanQuotedSpan(tc.in, 0); got != tc.wantPlain {
				t.Errorf("scanQuotedSpan(%q, 0) = %d, want %d", tc.in, got, tc.wantPlain)
			}
		})
	}
}

// TestStartsLineComment pins the MySQL introducer rule, especially the two
// exclusions that are load-bearing: newline (whose inclusion would recreate
// the swallow-the-next-line bug) and the non-comment "--1".
func TestStartsLineComment(t *testing.T) {
	for _, tc := range []struct {
		in   string
		i    int
		want bool
	}{
		{"-- x", 0, true},
		{"--\tx", 0, true},
		{"--", 0, true},
		{"--1", 0, false},
		{"--\nDELETE FROM t", 0, false},
		{"-x", 0, false},
		{"SELECT 1 -- c", 9, true},
	} {
		if got := startsLineComment(tc.in, tc.i); got != tc.want {
			t.Errorf("startsLineComment(%q, %d) = %v, want %v", tc.in, tc.i, got, tc.want)
		}
	}
}

// TestAssertSQLReadOnly_BackslashLiteralAmbiguity pins the FOURTH bypass of
// this gate, which the brief for this task did not know about and which the
// design as briefed would have preserved. It is a bypass in BOTH directions,
// which is why the scanner refuses to pick one:
//
//   - Reading "\" as an ordinary byte (scanQuotedSpan) ends the literal at
//     the escaped quote and re-arms the "--" that follows. Measured on the
//     live MySQL 8.4.11 acceptance container, LENGTH('a\' -- ') is 6 — one
//     literal — and running the first case below through the raw driver
//     wrote a 7-byte file under /var/lib/mysql-files/. Before this change
//     the gate ALLOWED it.
//   - Reading "\" as an escape (scanQuotedSpanEscaped) runs the literal on
//     to the next quote and re-arms a "--" further right. Measured on
//     modernc.org/sqlite, LENGTH('a\') is 2 and "SELECT 'a\' , 'b -- c'"
//     really is two columns, so the second case below is a live
//     ";"-separated DROP that that driver executes.
//
// stripSQLComments therefore stops stripping entirely once the two readings
// disagree, which leaves both payloads fully visible to the scans.
func TestAssertSQLReadOnly_BackslashLiteralAmbiguity(t *testing.T) {
	t.Run("MySQL reading: INTO OUTFILE after an escaped quote", func(t *testing.T) {
		assertRejectedWithMessage(t,
			`SELECT 'a\' -- ' INTO OUTFILE '/var/lib/mysql-files/bs_probe.txt'`,
			"query contains a write operation and was blocked (read-only)")
	})
	t.Run("MySQL reading: second statement after an escaped quote", func(t *testing.T) {
		assertRejectedWithMessage(t,
			`SELECT 'a\' -- ' ; DROP TABLE t`,
			"multiple statements are not allowed in read-only mode")
	})
	t.Run("SQLite reading: second statement after a later literal", func(t *testing.T) {
		assertRejectedWithMessage(t,
			`SELECT 'a\' , 'b -- c' ; DROP TABLE t`,
			"multiple statements are not allowed in read-only mode")
	})
	// The other half, so the guard is not "secure by being useless": a
	// backslash the two readings AGREE about costs nothing, and an ordinary
	// comment after it is still stripped.
	for _, q := range []string{
		`SELECT 'C:\path' FROM t -- a note about DELETE`,
		`SELECT 'a\\' FROM t -- a note about DELETE`,
	} {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("an unambiguous backslash must not disable comment stripping; %q: %v", q, err)
		}
	}
}

// TestAssertSQLReadOnly_EngineDisagreementGiveUp pins the two shapes, found
// by TestStripSQLCommentsNeverDeletesEngineLiveBytes rather than by
// inspection, where the stripper stops stripping because the target engines
// lex the same bytes differently.
//
// Both were live in the code BEFORE this task, including in the design this
// task was briefed to implement, and the first was reproduced end to end:
// see TestSQLiteDashSlashStarBypassIsBlocked in driver_sqlite_test.go,
// where the gate allowed it and a database file appeared on disk.
func TestAssertSQLReadOnly_EngineDisagreementGiveUp(t *testing.T) {
	// "--/*" is arithmetic to MySQL and a comment to SQLite/Postgres. A
	// scanner that keeps the line (MySQL's reading) but still lets the "/*"
	// on it open a block comment deletes the next two lines, which SQLite
	// executes.
	t.Run("block comment opened by a non-introducer --", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1--/*\n; ATTACH DATABASE '/tmp/side.db' AS s\n-- */",
			"multiple statements are not allowed in read-only mode")
	})
	// The same, with a write keyword instead of a separator.
	t.Run("write hidden by a non-introducer --", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1--/*\nDELETE FROM customers\n-- */",
			"query contains a write operation and was blocked (read-only)")
	})
	// "#" is a comment to MySQL and live text to SQLite/Postgres, so a
	// quote or a "/*" on a "#" line moves every span boundary after it.
	t.Run("quote on a # line", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1 # '\n-- ; ATTACH DATABASE '/tmp/side.db' AS s",
			"multiple statements are not allowed in read-only mode")
	})
	t.Run("block comment opened on a # line", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1 # /*\nDELETE FROM customers\n# */",
			"query contains a write operation and was blocked (read-only)")
	})
	// SQLite (and T-SQL) quote identifiers with "[ ... ]"; MySQL has no
	// such span, so a "--" inside one is live SQL to SQLite and a comment
	// introducer to a scanner that does not know about brackets. See
	// TestSQLiteBracketIdentifierBypassIsBlocked for the end-to-end half:
	// before this arm existed the gate allowed the first case below and a
	// database file was created on disk.
	t.Run("second statement after a -- inside a bracket identifier", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1 AS [a-- ];ATTACH DATABASE '/tmp/side.db' AS s",
			"multiple statements are not allowed in read-only mode")
	})
	t.Run("write after a -- inside a bracket identifier", func(t *testing.T) {
		assertRejectedWithMessage(t,
			"SELECT 1 AS [a-- ] DELETE FROM customers",
			"query contains a write operation and was blocked (read-only)")
	})
	// MySQL parses "/*! ... */" content as LIVE SQL and so honours string
	// literals while hunting for the closing "*/"; SQLite closes at the
	// first "*/" regardless. Locating the close with a plain search picks
	// SQLite's reading, ends the comment early, and re-arms the text after
	// it — which is how the payload below hid an INTO OUTFILE that MySQL
	// 8.4.11 executed, writing a file on the database host. See
	// TestMySQLExecutableCommentCloseBypassIsBlocked for the live half.
	t.Run("write hidden after an early-closed executable comment", func(t *testing.T) {
		assertRejectedWithMessage(t,
			`SELECT 1 /*!50000 ' */ -- ' INTO OUTFILE '/var/lib/mysql-files/p7probe.txt' */`,
			"query contains a write operation and was blocked (read-only)")
	})
	t.Run("unversioned executable comment, same shape", func(t *testing.T) {
		assertRejectedWithMessage(t,
			`SELECT 1 /*! ' */ -- ' INTO OUTFILE '/tmp/x' */`,
			"query contains a write operation and was blocked (read-only)")
	})
	t.Run("second statement hidden after an early-closed executable comment", func(t *testing.T) {
		assertRejectedWithMessage(t,
			`SELECT 1 /*!50000 ' */ -- ' ; DROP TABLE t */`,
			"multiple statements are not allowed in read-only mode")
	})
	// The other half: giving up must not be the scanner's normal state. A
	// query with no ambiguous construct still has its comments stripped,
	// which these prove by hiding a blocked keyword in the comment.
	for _, q := range []string{
		"SELECT 1 -- a note about DELETE",
		"SELECT 1 /* a note about DELETE */ FROM t",
		"SELECT 'no # here' FROM t -- a note about DELETE",
	} {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("comments must still be stripped when nothing is ambiguous; %q: %v", q, err)
		}
	}
	// And giving up on "/*!" must not cost the ordinary executable-comment
	// hints, which carry no blocked keyword and no ";" in the remainder.
	// Both were run through the gated read path against the live server;
	// see TestMySQLExecutableCommentCloseBypassIsBlocked.
	for _, q := range []string{
		"SELECT /*!50000 1 */",
		"SELECT /*! SQL_NO_CACHE */ * FROM t",
		"SELECT 1 /*!40101 */ FROM t",
	} {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("a benign executable comment must still be allowed; %q: %v", q, err)
		}
	}
}

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
			if got := SQLReadListsTables(tc.sql); got != tc.want {
				t.Fatalf("SQLReadListsTables(%q) = %v, want %v", tc.sql, got, tc.want)
			}
		})
	}
}
