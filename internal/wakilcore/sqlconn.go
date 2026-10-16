package wakilcore

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// sqlConn is a database/sql-backed Conn, shared by every SQL driver
// (SQLite, MySQL, ...). Each driver supplies its own read-only gate,
// container-listing query, and identifier-quoting function via the
// fields below, since those three things are the only dialect-specific
// behavior a database/sql driver needs.
type sqlConn struct {
	db   *sql.DB
	gate func(string) error
	// writeGate is the mutation gate, and NIL MEANS READ-ONLY. Every
	// sqlConn built by a driver's Connect leaves it nil; only
	// ConnectWritable sets it. That is why Write's first act is a nil
	// check rather than a boolean test: there is no value of a bool that
	// a zero-valued struct literal gets wrong, but a missing function is
	// unambiguous, and a Conn assembled anywhere without explicitly
	// opting into writing cannot write.
	writeGate func(string) error
	// writable is whether this database has a write credential configured
	// at all, copied from Connection.Writable — advertisement, never
	// permission, and no gate may read it.
	//
	// It is NOT writeGate's boolean twin and cannot be replaced by one.
	// writeGate is nil on every connection Connect builds, which is every
	// connection a READ runs on, so it answers "may this connection
	// write" (always no here) where describeEditability needs "could this
	// database be written by the write route" — a question only
	// configuration can answer.
	writable bool
	listSQL  string
	// columnsSQL yields (table, column) rows ordered by table then column
	// position; ListColumns groups them.
	columnsSQL string
	// quoteIdent quotes a SQL identifier for this dialect (e.g. double
	// quotes for SQLite/standard SQL, backticks for MySQL), doubling any
	// embedded quote character so the identifier cannot be terminated
	// early by attacker- or hallucination-controlled input (e.g. a
	// describe_table tool argument).
	quoteIdent func(string) string
	// primaryKeySQL returns a table's primary-key columns in key order,
	// taking the table name as its ONE bound parameter.
	//
	// A parameter and not an interpolated identifier, unlike Describe:
	// both engines offer a parameterised route — sqlite's
	// pragma_table_info table-valued function and MySQL's
	// information_schema — so quoting is not needed here and quoteIdent's
	// compromise does not have to be repeated.
	primaryKeySQL string
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
	// quoteLiteral renders a value as a string literal for this dialect
	// and this connection.
	//
	// It returns an error because not every value can be expressed: a NUL
	// is a syntax error on sqlite. It sits beside quoteIdent because it is
	// the same kind of thing — the one guard between caller-controlled
	// text and a statement — and because the probe proved the two dialects
	// disagree about it.
	quoteLiteral func(string) (string, error)
	// killsOnCancel is true for engines that keep running a statement after
	// its client goes away. MySQL does (measured 2026-10-13: a cancelled
	// SELECT SLEEP(20) was still in PROCESSLIST 3 s later); SQLite is
	// in-process and Mongo kills the operation itself.
	killsOnCancel bool
}

func (c *sqlConn) Close() error { return c.db.Close() }

// queryContext runs a read. On an engine that does not stop a statement
// when its client leaves (killsOnCancel), it pins one connection, reads its
// thread id and server uuid, and when ctx ends takes a second connection
// and issues KILL QUERY for that id on it, only if that connection reports
// the same server uuid. Behind a load balancer the second connection can
// reach a different backend, where the id names an unrelated session; the
// uuid check skips the kill then. A multiplexing proxy (ProxySQL with
// multiplexing) can still defeat the check. release must be called after
// the rows are closed: it waits for a kill already under way before the
// pinned connection goes back to the pool, so a kill can never land on a
// later statement that reuses it.
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
	var uuid string
	if err := pinned.QueryRowContext(ctx, "SELECT CONNECTION_ID(), @@server_uuid").Scan(&id, &uuid); err != nil {
		pinned.Close()
		return nil, func() {}, err
	}
	killed := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		defer close(killed)
		kctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		killer, err := c.db.Conn(kctx)
		if err != nil {
			return
		}
		defer killer.Close()
		var other string
		if err := killer.QueryRowContext(kctx, "SELECT @@server_uuid").Scan(&other); err != nil || other != uuid {
			return
		}
		_, _ = killer.ExecContext(kctx, fmt.Sprintf("KILL QUERY %d", id))
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

func (c *sqlConn) ListContainers(ctx context.Context) ([]Container, error) {
	rows, err := c.db.QueryContext(ctx, c.listSQL)
	if err != nil {
		return nil, UserError("cannot list tables: " + err.Error())
	}
	defer rows.Close()
	var out []Container
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out = append(out, Container{Name: name, Kind: "table"})
	}
	return out, rows.Err()
}

// ListColumns runs the driver's columnsSQL, which yields (table, column)
// rows ordered by table then column position, and groups them.
func (c *sqlConn) ListColumns(ctx context.Context) ([]TableColumns, error) {
	rows, err := c.db.QueryContext(ctx, c.columnsSQL)
	if err != nil {
		return nil, UserError("cannot list columns: " + err.Error())
	}
	defer rows.Close()
	var out []TableColumns
	for rows.Next() {
		var table, column string
		if err := rows.Scan(&table, &column); err != nil {
			return nil, err
		}
		if n := len(out); n == 0 || out[n-1].Table != table {
			out = append(out, TableColumns{Table: table})
		}
		out[len(out)-1].Columns = append(out[len(out)-1].Columns, column)
	}
	return out, rows.Err()
}

// Describe reports the column names and types of a single table, by
// running a fixed template — "SELECT * FROM <quoted name> LIMIT 0" — and
// reading the result's column metadata. Reading zero rows is the portable
// way to do this: it needs no information_schema, no PRAGMA, and no
// dialect-specific DESCRIBE.
//
// Why this path does NOT call c.gate, unlike Read.
//
// The asymmetry is deliberate, not an omission. c.gate (AssertSQLReadOnly)
// validates a whole caller-supplied SQL *statement*; what Describe builds
// is a constant template with exactly one variable substituted, and that
// substitution goes through c.quoteIdent, which cannot produce anything
// but a single well-formed identifier token (see the fixtures in
// sqlconn_test.go, which describe a table literally named
// `t ; DROP TABLE u; --` through this function and prove the sacrificial
// table u survives). There is no caller-controlled SQL here for the gate
// to have an opinion about.
//
// Running the gate here anyway would not be free — it would break real
// databases. Measured by creating each of the following as a table in BOTH
// a live MySQL 8.4.11 and modernc.org/sqlite (all 11 accepted by both
// engines), then describing it through this template on SQLite (all 11
// described correctly), then handing the generated SQL to
// AssertSQLReadOnly — which REJECTS 9 of the 11:
//
//	do, call, load, copy, set, create, delete, merge
//	                     -> "query contains a write operation and was
//	                         blocked (read-only)"   (the word-boundary
//	                         keyword scan matches the table name itself)
//	a;b                  -> "multiple statements are not allowed in
//	                         read-only mode"
//	orders, "audit log"  -> allowed
//
// So the gate would reject a table named `delete` or `call` while adding
// nothing against the only input that is actually variable. The right and
// sufficient guard HERE is quoting, and it is pinned directly rather than
// left to a second, ill-fitting layer.
//
// The NUL check below is the one thing quoting cannot express. Measured on
// both engines, an identifier containing a NUL is truncated at the NUL
// before parsing — "SELECT * FROM \"customers\x00zzz\" LIMIT 0" is read as
// "SELECT * FROM \"customers", i.e. an unterminated identifier:
//
//	sqlite: SQL logic error: unrecognized token: ""customers"
//	mysql:  Error 1064 ... right syntax to use near '`customers'
//
// Both engines therefore happen to fail today, but they fail on a string
// that is a *prefix* of the identifier the caller asked for, with a
// message naming a table nobody requested. Rejecting the NUL here turns
// that engine-dependent accident into one deterministic, actionable
// UserError and removes any dependence on truncate-then-unterminated-quote
// holding in every driver Wakil might add.
func (c *sqlConn) Describe(ctx context.Context, name string) (Schema, error) {
	if strings.IndexByte(name, 0) >= 0 {
		return Schema{}, UserError("invalid table name")
	}
	rows, err := c.db.QueryContext(ctx, "SELECT * FROM "+c.quoteIdent(name)+" LIMIT 0")
	if err != nil {
		return Schema{}, UserError("cannot describe " + name + ": " + err.Error())
	}
	defer rows.Close()
	cts, err := rows.ColumnTypes()
	if err != nil {
		return Schema{}, UserError("cannot describe " + name + ": " + err.Error())
	}
	var sch Schema
	for _, ct := range cts {
		sch.Columns = append(sch.Columns, Column{Name: ct.Name(), Type: ct.DatabaseTypeName()})
	}
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
	return sch, nil
}

// PrimaryKey reports table's primary-key columns via c.primaryKeySQL — see
// that field's doc comment for why a bound parameter needs no identifier
// quoting — and returns them in the engine's own key order.
//
// c.primaryKeySQL == "" (a sqlConn built without one, e.g. by a test
// fixture) answers "no key" rather than panicking or erroring: the zero
// value of the field is exactly the "I do not know how to ask" case, and
// that is already how "not editable" is spelled everywhere else in this
// method.
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
	needsWrap := offset > 0 || len(spec.Sort) > 0
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
	rows, release, err := c.queryContext(ctx, stmt)
	if err != nil {
		return Rows{}, UserError("query failed: " + err.Error())
	}
	out, err := collectRows(rows, limit)
	// Closed and released here, not deferred: describeEditability below can
	// run for a while, and the pinned connection must not stay pinned (a
	// cancel then would kill an idle thread).
	rows.Close()
	release()
	if err != nil {
		return Rows{}, err
	}
	out.Pageable = pageable
	// Judged on the operator's RAW text, never on the wrapped statement —
	// the wrap is Wakil's, and a gate or a claim made about Wakil's own
	// composition is a claim about the wrong thing. Same rule as the
	// read-only gate above.
	out.ListsTables = SQLReadListsTables(spec.Raw)
	table, plain := SQLReadSingleTable(spec.Raw)
	// Timed AFTER describeEditability, not before: that call can issue its
	// own round trip (PrimaryKey), and a Millis that stopped the clock
	// before it would under-report what this Read actually cost.
	c.describeEditability(ctx, &out, table, plain)
	out.Millis = time.Since(start).Milliseconds()
	return out, nil
}

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
	ctx context.Context, name string, limit, offset int, sort []QuerySort,
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
	rows, release, err := c.queryContext(ctx, stmt)
	if err != nil {
		return Rows{}, UserError("cannot read " + name + ": " + err.Error())
	}
	out, err := collectRows(rows, limit)
	// Closed and released here, not deferred: describeEditability below can
	// run for a while, and the pinned connection must not stay pinned (a
	// cancel then would kill an idle thread).
	rows.Close()
	release()
	if err != nil {
		return Rows{}, err
	}
	out.Pageable = true
	// A table read names its table by construction and selects every
	// column, so there is no statement to recognise.
	//
	// Timed AFTER describeEditability, for Read's reason: it can issue its
	// own PrimaryKey round trip, and stopping the clock before it would
	// under-report what this call actually cost.
	c.describeEditability(ctx, &out, name, nil)
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
// Every ORDER BY term goes through c.quoteIdent, the same sole guard
// Describe relies on: the column name arrives from a header click or from
// an agent, and an unquoted identifier is how that becomes an injection.
// The direction is not interpolated at all — it is one of two literals.
//
// THE NEWLINE BEFORE THE CLOSING PAREN IS LOAD-BEARING (final review,
// Important 5). inner is trimmed of whitespace and of the one trailing ";"
// the gate permits, and it is deliberately NOT stripped of comments —
// the gate must judge the operator's text including them. Emitted on one
// line, "SELECT * FROM events -- logins only" became
//
//	SELECT * FROM (SELECT * FROM events -- logins only) AS wakil_page LIMIT 501 OFFSET 500
//
// where the whole wrap after "--" is comment: an unclosed paren, and a
// syntax error from the engine on a read SQLReadIsPageable had just said
// was pageable. The same applies to MySQL's "#". Ending inner with a
// newline puts the closing paren on its own line, where no line comment
// can reach it — one character, and it is dialect-independent because
// every SQL line comment ends at a newline by definition.
func (c *sqlConn) pageWrap(raw string, sort []QuerySort, limit, offset int) string {
	inner := strings.TrimRight(strings.TrimSpace(raw), "; \t\n")
	var b strings.Builder
	b.WriteString("SELECT * FROM (")
	b.WriteString(inner)
	b.WriteString("\n) AS wakil_page")
	for i, term := range sort {
		if i == 0 {
			b.WriteString(" ORDER BY ")
		} else {
			b.WriteString(", ")
		}
		b.WriteString(c.quoteIdent(term.Column))
		if term.Descending {
			b.WriteString(" DESC")
		} else {
			b.WriteString(" ASC")
		}
	}
	fmt.Fprintf(&b, " LIMIT %d OFFSET %d", limit+1, offset)
	return b.String()
}

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

// clampReadLimit bounds the number of rows a single read may return.
//
// The upper bound is the load-bearing half: every row returned here is
// serialised into a tool result and spent out of the model's context
// window, so an LLM-chosen (or hallucinated) limit of 10_000_000 must not
// be honoured. The lower bound covers "unset" — callers that omit the
// argument pass 0, and a literal 0 would otherwise return nothing.
//
// Both out-of-range directions collapse to the same default rather than to
// the nearest bound, which is why 1001 yields 500 and not 1000: 500 is the
// "you did not usefully choose" answer, and a caller that really wants 1000
// rows can ask for 1000 and get exactly 1000. An in-range limit is passed
// through UNCHANGED — clamping everything to 500 would silently cap
// legitimate smaller and larger requests alike, so that pass-through is
// pinned as its own case in TestClampReadLimit.
func clampReadLimit(limit int) int {
	if limit <= 0 || limit > 1000 {
		return 500
	}
	return limit
}

// collectRows drains rows into a Rows value, stopping once limit rows have
// been kept.
//
// It is a free function taking *sql.Rows, rather than inline in Read, so
// the rows.Columns() error path below can be exercised deterministically.
// database/sql (go1.27.1) fails Columns() in exactly two states — the
// *sql.Rows is closed, or it was never populated — and a test can hand
// this function a closed *sql.Rows directly, which it cannot do to Read
// (Read closes rows only via defer, after this call).
//
// That Columns() error used to be discarded ("cols, _ :="). Measured on
// go1.27.1: when Columns() returns an error, sql.Rows is closed, so
// rows.Next() is false and the scan loop never runs — over 3000 iterations
// of a cancelled-context race, Columns() failed 1981 times and Next() was
// true on 0 of them. So the discard could NOT produce the mis-scan it
// looks like it should ("expected 0 destination arguments"). What it could
// produce is worse and quieter: rows.Err() does not always carry the same
// failure. On an explicitly closed *sql.Rows, measured,
//
//	Columns() -> "sql: Rows are closed"      Err() -> nil
//
// so the discarded error was the only report of the failure, and Read
// returned a successful, silently EMPTY result with no columns. Returning
// it makes the failure impossible to lose.
func collectRows(rows *sql.Rows, limit int) (Rows, error) {
	cols, err := rows.Columns()
	if err != nil {
		return Rows{}, err
	}
	var out Rows
	out.Columns = cols
	// Empty, not nil — see Rows.Rows. A query that matched nothing has to
	// marshal as `"rows": []`, and `append` to a nil slice would leave it
	// nil in exactly that case. rows.Columns() has already succeeded above,
	// so out.Columns is non-nil here for free.
	out.Rows = [][]any{}
	// ColumnTypes() fails in the same states Columns() does, and this
	// function has already survived that check — but a driver is permitted
	// to return fewer type descriptors than columns, and a positionally
	// aligned slice that is short is worse than none. So it is all or
	// nothing, matching the field's contract.
	if cts, cterr := rows.ColumnTypes(); cterr == nil && len(cts) == len(cols) {
		types := make([]string, len(cts))
		for i, ct := range cts {
			types[i] = ct.DatabaseTypeName()
		}
		out.ColumnTypes = types
	}
	// Read one row past the limit so a full-vs-truncated result can be
	// distinguished; the extra row is dropped below. This is why the
	// comparison that sets Truncated is ">" and not ">=": a result of
	// exactly limit rows means the query produced no (limit+1)'th row and
	// nothing was dropped, so it is complete, not truncated.
	for rows.Next() && len(out.Rows) < limit+1 {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return Rows{}, err
		}
		for i, v := range vals {
			if b, ok := v.([]byte); ok {
				vals[i] = string(b)
			}
		}
		out.Rows = append(out.Rows, vals)
	}
	if len(out.Rows) > limit {
		out.Rows = out.Rows[:limit]
		out.Truncated = true
	}
	return out, rows.Err()
}

// describeEditability builds out.Editable, or leaves it nil.
//
// It never returns an error: a result that cannot be proven editable is a
// read-only result, not a failed read. A key lookup that fails for its own
// reasons costs the operator an editing affordance, never their rows.
func (c *sqlConn) describeEditability(ctx context.Context, out *Rows, table string, plain []string) {
	// A database with no write credential can never honour an edit, so it
	// must not advertise one — design-language.md §8, and the reason this
	// check is FIRST is that it is the cheapest: it costs no query, where
	// PrimaryKey below issues one. Checked before quoteLiteral for the
	// same reason.
	if !c.writable {
		return
	}
	if table == "" || c.quoteLiteral == nil {
		return
	}
	key, err := c.PrimaryKey(ctx, table)
	if err != nil || len(key) == 0 {
		return
	}
	// Every key column must be present in the result UNDER ITS OWN NAME,
	// compared CASE-INSENSITIVELY, and folded with asciiLower — NOT
	// strings.ToLower. See asciiLower's own doc comment for why: SQL
	// identifier comparison is an ASCII-only rule on both engines, and
	// Unicode case folding disagrees with it for real characters (U+212A
	// KELVIN SIGN, which Unicode calls the same letter as ASCII "k" and
	// both engines do not). PrimaryKey's spelling need not match the case
	// an operator happened to type in a SELECT list ("SELECT ID, kind
	// FROM events" against a key information_schema (or
	// pragma_table_info) reports as "id"). The map is keyed by the
	// folded name, but its VALUE is the column's real position, so keyAt
	// below still indexes into each row exactly as the engine returned
	// it.
	index := make(map[string]int, len(out.Columns))
	for i, name := range out.Columns {
		lower := asciiLower(name)
		if _, seen := index[lower]; seen {
			// A duplicate result column name — compared the same
			// case-insensitive way, since "id" and "ID" name the same
			// column on both engines — has no single column to write
			// to; the recogniser refuses this for a named list, and
			// this covers the SELECT * case where two columns collide.
			return
		}
		index[lower] = i
	}
	keyAt := make([]int, 0, len(key))
	for _, name := range key {
		at, ok := index[asciiLower(name)]
		if !ok {
			return
		}
		keyAt = append(keyAt, at)
	}

	// Which columns may be written to: every plain one, minus the key —
	// each compared case-insensitively, for the same reason as above.
	//
	// Columns is built from out.Columns — the names the engine ACTUALLY
	// reported for this result — never from plain (the operator's
	// as-typed SELECT list) or from key (PrimaryKey's own spelling).
	// Building it from either of those instead was a real, two-part bug:
	// a name from plain/key need not be a name out.Columns actually
	// carries, so a grid doing a name-keyed lookup would miss it; and
	// comparing key membership by exact string match let a key column
	// typed in a different case than PrimaryKey reported ("SELECT ID,
	// kind FROM events" against a key declared "id") through as
	// writable — "UPDATE events SET ID = 99 WHERE id = 1" changes the
	// row's identity and invalidates every RowKey this very read just
	// produced, which is precisely what this field's doc comment says
	// must not happen. plain now serves only as a case-insensitive
	// MEMBERSHIP FILTER over out.Columns, never as a source of names.
	// Folded with asciiLower for the same reason as the key lookup above.
	inKey := make(map[string]bool, len(key))
	for _, name := range key {
		inKey[asciiLower(name)] = true
	}
	var allowedLower map[string]bool
	if plain != nil {
		allowedLower = make(map[string]bool, len(plain))
		for _, name := range plain {
			allowedLower[asciiLower(name)] = true
		}
	}
	// out.ColumnTypes is positionally aligned with out.Columns — see
	// Rows.ColumnTypes's own doc comment — but the contract is
	// all-or-nothing: a driver that could not determine types leaves it
	// empty rather than partially filled. hasTypesByIndex reflects that:
	// an empty ColumnTypes means "unknown", not "no types", so nothing is
	// excluded on that basis alone. The alternative — treating "no type
	// info" as "assume editable" for a per-column decision instead of
	// this all-or-nothing one — would silently offer BIT for editing on
	// whatever driver or query shape produces an empty ColumnTypes, the
	// exact affordance-without-backing failure this fix exists against.
	hasTypes := len(out.ColumnTypes) == len(out.Columns)
	writable := make([]string, 0, len(out.Columns))
	for i, name := range out.Columns {
		lower := asciiLower(name)
		if inKey[lower] {
			continue
		}
		// allowedLower == nil means plain == nil, i.e. SELECT * — every
		// result column is plain.
		if allowedLower != nil && !allowedLower[lower] {
			continue
		}
		// A BIT column (uneditableTypePrefixes, updatestmt.go) is
		// excluded here rather than left for RenderUpdate to refuse at
		// commit time. RenderUpdate's own refusal fails closed — nothing
		// can be written wrongly — but a column the grid still hovers,
		// opens an editor for, and accepts a value into, only to refuse
		// it after Enter, is a surface that looks like it can do a thing
		// it never could: the design's own corollary that Editable.Columns
		// exists to prevent. Reusing hasTypePrefix/uneditableTypePrefixes
		// rather than a second list keeps RenderUpdate and this check from
		// ever disagreeing about which types are unquotable.
		if hasTypes && hasTypePrefix(out.ColumnTypes[i], uneditableTypePrefixes) {
			continue
		}
		writable = append(writable, name)
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
//
// Recorded, not fixed: a float64 key holding +Inf or -Inf renders as
// literal text "+Inf"/"-Inf" via strconv.FormatFloat, which neither
// engine accepts as a numeric literal. That composes a WHERE clause that
// is invalid SQL rather than one that silently names the wrong row —
// this fails closed (the query errors) rather than open, so it is left
// as is.
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
