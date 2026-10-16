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
