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

		// Adversarial cases beyond the probe's 26 — see task-4-report.md for
		// the rationale behind each one.
		{"word-boundary protects a column named union_id", `SELECT union_id FROM events`, "events"},
		{"word-boundary protects a table named distinct_values", `SELECT * FROM distinct_values`, "distinct_values"},
		{"word-boundary protects a table named grouping_sets", `SELECT * FROM grouping_sets`, "grouping_sets"},
		{"string literal containing JOIN is not a real join", `SELECT id FROM events WHERE kind = 'JOIN'`, ""},
		{"string literal containing UNION is not a real union", `SELECT id FROM events WHERE kind = 'UNION ALL'`, ""},
		{"FROM inside a WHERE subquery is not the outer FROM", `SELECT id FROM events WHERE id IN (SELECT id FROM users WHERE kind = 'x')`, "events"},
		{"nested parens in WHERE subquery", `SELECT id FROM events WHERE id IN (SELECT id FROM users WHERE id IN (SELECT id FROM admins))`, "events"},
		{"tabs and newlines instead of spaces", "SELECT\tid\nFROM\tevents", "events"},
		{"mixed case keywords", `SeLeCt * fRoM events`, "events"},
		{"trailing line comment", "SELECT * FROM events -- trailing note", "events"},
		{"trailing block comment", `SELECT * FROM events /* trailing note */`, "events"},
		{"lowercase table name unaffected", `select * from events`, "events"},
		{"case-insensitive WITH still refused", `with events as (select 1 as id) select * from events`, ""},
		{"case-insensitive JOIN still refused", `select * from events join users on users.id = events.id`, ""},
		{"whitespace-only", "   \t\n  ", ""},
		{"select with no from at all", `SELECT 1`, ""},
		{"double-quoted alias survives", `SELECT * FROM events AS "e"`, "events"},
		{"three-part qualified name refused", `SELECT * FROM catalog.otherdb.events`, ""},
		{"stacked statement after WHERE is refused, not silently table=events", `SELECT * FROM events WHERE id = 1; DROP TABLE events`, ""},
		{"stacked SELECT after WHERE is refused, not silently table=events", `SELECT * FROM events WHERE id = 1; SELECT secret FROM other_table`, ""},

		// Regression: strings.ToUpper is not byte-length-preserving, so an
		// index found in strings.ToUpper(clean)/strings.ToUpper(rest) and
		// then applied back to clean/rest silently truncates the FROM
		// clause whenever a byte-shrinking case fold appears before the
		// match — letting a real comma join through as a false "single
		// table" accept. Verified against modernc.org/sqlite; see
		// fromKeyword's doc in editable.go. Five confirmed shapes plus one
		// of our own construction.
		{"long s (ſ) shrinks on upper-casing and must not truncate the comma join", `SELECT * FROM events eıııııııııı, users u WHERE 1=1`, ""},
		{"long s in an alias must not truncate the comma join", `SELECT * FROM a ſſſſſſx, b y WHERE 1=1`, ""},
		{"long s inside FOR ... UPDATE must not smuggle a real table qualifier past the parser", `SELECT * FROM a FORſſſſſſſ UPDATE WHERE 1=1`, ""},
		{"long s inside INTO OUTFILE must not be misparsed as a plain alias", `SELECT * FROM a INTOſx17 OUTFILE '/tmp/x' WHERE 1=1`, ""},
		{"dotless i (ı) shrinks on upper-casing and must not truncate the comma join", `SELECT * FROM a ıx, b y WHERE 1=1`, ""},
		{"our own: several dotless i's inside the FROM clause ahead of a comma join", `SELECT * FROM events ııııı, admins a WHERE 1=1`, ""},
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

// TestSQLReadSingleTableConcurrent guards against reintroducing an earlier
// defect: a package-level regexp cache (map[string]*regexp.Regexp), filled
// lazily on first use with no lock, read and written by every call. Under
// `go test -race` with concurrent callers that was a confirmed DATA RACE,
// and in production a concurrent map write there is fatal, not just
// racy. The fix was to precompile every regexp as a plain package-level
// var (the same pattern readonly.go already uses) so there is nothing left
// to build lazily and nothing shared to race on. This test calls
// SQLReadSingleTable from many goroutines at once so a reintroduced cache
// would be caught here under -race before it reached production.
func TestSQLReadSingleTableConcurrent(t *testing.T) {
	const callers = 64
	done := make(chan struct{})
	for i := 0; i < callers; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			for _, sql := range []string{
				`SELECT * FROM events`,
				`SELECT id, kind FROM events WHERE id > 1 ORDER BY id LIMIT 5`,
				`WITH events AS (SELECT 1 AS id) SELECT * FROM events`,
				`SELECT * FROM events JOIN users ON users.id = events.id`,
			} {
				SQLReadSingleTable(sql)
			}
		}()
	}
	for i := 0; i < callers; i++ {
		<-done
	}
}
