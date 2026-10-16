package wakilcore

import (
	"context"
	"database/sql"
	"net/url"
	"strings"

	_ "modernc.org/sqlite"
)

func init() { RegisterDriver("sqlite", sqliteDriver{}) }

type sqliteDriver struct{}

func (sqliteDriver) Kind() string { return "sqlite" }

func (sqliteDriver) AssertReadOnly(spec QuerySpec) error { return AssertSQLReadOnly(spec.Raw) }

func (sqliteDriver) AssertMutation(spec QuerySpec) error { return AssertSQLMutation(spec.Raw) }

func (sqliteDriver) Connect(ctx context.Context, c Connection) (Conn, error) {
	dsn := sqliteReadOnlyDSN(c.URL)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, UserError("cannot open sqlite database: " + err.Error())
	}
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, UserError("sqlite database unreachable: " + err.Error())
	}
	return &sqlConn{
		db:       db,
		gate:     AssertSQLReadOnly,
		writable: c.Writable,
		listSQL:  "SELECT name FROM sqlite_master WHERE type='table'",
		columnsSQL: "SELECT m.name, p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p " +
			"WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' ORDER BY m.name, p.cid",
		quoteIdent:    sqliteQuoteIdent,
		primaryKeySQL: "SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk",
		quoteLiteral:  sqliteQuoteLiteral,
	}, nil
}

// sqliteReadOnlyDSN turns a Connection.URL — a bare filesystem path or an
// already-formed "file:" URI — into a "file:" URI with the SQLite-native
// mode=ro query parameter set, so the engine itself refuses any write
// regardless of what SQL text reaches it. Phase 1 is read-only everywhere
// with no override, so this is applied unconditionally rather than being
// conditioned on Connection.ReadOnly. Every transformation this function
// performs is a plain string operation, so it never fails.
func sqliteReadOnlyDSN(raw string) string {
	if !strings.HasPrefix(raw, "file:") {
		// Bare filesystem path: build a "file:" URI through net/url so
		// characters that are meaningful in a URI (?, #, space, ...) are
		// percent-encoded in the path component, rather than
		// concatenated verbatim. Concatenation would let a raw "?" or
		// "#" in the path terminate the path early (or introduce a
		// fragment), silently dropping "?mode=ro" and leaving the
		// engine open read-write. OmitHost keeps this correct for
		// relative paths too: without it, url.URL.String() renders a
		// host-less, non-rooted Path as "file://<path>", which
		// round-trips as an (empty-path) authority, not a filename.
		u := url.URL{Scheme: "file", OmitHost: true, Path: raw}
		return setMode(u.String(), "ro")
	}
	// Already a "file:" URI. modernc.org/sqlite's own DSN convention
	// (mirrored here rather than using url.Parse on the whole string) is
	// to treat everything up to the *first* "?" as the path and
	// everything after as an ordinary "&"-separated query string; it has
	// no concept of a URI fragment. Using url.Parse instead would
	// misinterpret a literal, unescaped "#" in the path as introducing a
	// fragment and silently detach the trailing text (including any
	// "?mode=ro" we add) from the path modernc/SQLite actually opens.
	// Working on the raw string preserves any such "#" as literal
	// path text, matching how modernc/SQLite itself will read it.
	return setMode(raw, "ro")
}

// setMode sets (or overrides) the "mode" query parameter on a "file:" DSN
// to the requested mode, given the first "?" (if any) as the path/query
// boundary — the same boundary modernc.org/sqlite itself uses. Any
// existing query string is preserved; any existing "mode" value is
// overridden, since neither Phase 1's read-only guarantee nor this
// task's write path has a caller override.
func setMode(dsn, mode string) string {
	// A literal, unescaped "#" introduces a URI fragment at the engine
	// level. Unlike "?" — which both modernc.org/sqlite's own DSN
	// pre-processing and this function split on consistently — an
	// unescaped "#" is handled only by the underlying SQLite engine
	// itself, which truncates the filename there and never sees
	// anything after it, silently dropping any "?mode=..." that follows
	// (and, with SQLITE_OPEN_CREATE always set, opening a different,
	// possibly brand-new file read-write instead of failing). Escaping
	// it here removes that ambiguity for both callers of this function:
	// the bare-path branch's percent-encoded output never contains a
	// raw "#" already, so this is a no-op there, and it neutralizes a
	// raw "#" carried in from an already-formed "file:" URI.
	dsn = strings.ReplaceAll(dsn, "#", "%23")
	prefix, query, hasQuery := strings.Cut(dsn, "?")
	var q url.Values
	if hasQuery {
		// Best-effort parse: an existing query string that fails to
		// parse is dropped rather than causing this function to fail
		// (it has no error return — see sqliteReadOnlyDSN and
		// sqliteWriteDSN), but the requested mode is still set on the
		// resulting (possibly empty) query below either way, so the
		// override always applies.
		if parsed, err := url.ParseQuery(query); err == nil {
			q = parsed
		}
	}
	if q == nil {
		q = url.Values{}
	}
	q.Set("mode", mode)
	return prefix + "?" + q.Encode()
}

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
		db:        db,
		gate:      AssertSQLReadOnly,
		writeGate: AssertSQLMutation,
		writable:  c.Writable,
		listSQL:   "SELECT name FROM sqlite_master WHERE type='table'",
		columnsSQL: "SELECT m.name, p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p " +
			"WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' ORDER BY m.name, p.cid",
		quoteIdent:    sqliteQuoteIdent,
		primaryKeySQL: "SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk",
		quoteLiteral:  sqliteQuoteLiteral,
	}, nil
}

// sqliteQuoteIdent implements SQL identifier quoting for SQLite (standard
// double-quote form): wrap the identifier in double quotes and double any
// embedded double quote, so a hostile identifier (e.g. from a
// describe_table tool argument) cannot terminate the identifier early and
// have the remainder parsed as SQL.
func sqliteQuoteIdent(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}

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
