package wakilcore

import (
	"context"
	"database/sql"
	"strings"

	"github.com/go-sql-driver/mysql"
)

func init() { RegisterDriver("mysql", mysqlDriver{}) }

type mysqlDriver struct{}

func (mysqlDriver) Kind() string { return "mysql" }

func (mysqlDriver) AssertReadOnly(spec QuerySpec) error { return AssertSQLReadOnly(spec.Raw) }

func (mysqlDriver) AssertMutation(spec QuerySpec) error { return AssertSQLMutation(spec.Raw) }

func (mysqlDriver) Connect(ctx context.Context, c Connection) (Conn, error) {
	cfg, err := mysql.ParseDSN(c.URL)
	if err != nil {
		// mysql.ParseDSN's messages quote whichever fragment of the DSN
		// they choked on ("invalid dbname %q", "invalid bool value:
		// <value>"), and this DSN comes from the Keychain with a
		// password in it. No error in v1.10.1 carries the userinfo
		// itself — checked against the module source — but which
		// fragment surfaces is the driver's choice, not ours, so this
		// path carries no underlying error text at all. See resolution 3.
		return nil, UserError("cannot parse mysql connection string")
	}

	hardenMySQLConfig(cfg)
	dsn := cfg.FormatDSN()

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		// sql.Open for this driver re-parses the DSN internally, so a
		// failure here is the same class of DSN-shaped error as above:
		// no underlying error text, to avoid ever echoing the password.
		return nil, UserError("cannot open mysql connection")
	}
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, UserError("mysql database unreachable: " + redactPassword(err.Error(), cfg.Passwd))
	}

	// One query on a connection that has just answered a ping, exactly as
	// ConnectWritable does below. This USED TO be unnecessary on the read
	// path — nothing here composed a literal — but describeEditability
	// (sqlconn.go) now runs on every Read, and it renders a key value
	// through quoteLiteral. Against a NO_BACKSLASH_ESCAPES server, a
	// hardcoded backslashEscapes:true would double a literal backslash in
	// a TEXT/VARBINARY key, and the resulting WHERE clause would not just
	// fail to match — it would match a DIFFERENT row than the one the
	// operator saw, if a row differing only by that doubled backslash
	// exists. It cannot be set behind Wakil's back: hardenMySQLConfig
	// REPLACES cfg.Params wholesale, so no stored DSN can carry a
	// sql_mode and every pooled session sees the same server default.
	backslashEscapes := true
	var mode string
	if err := db.QueryRowContext(ctx, "SELECT @@SESSION.sql_mode").Scan(&mode); err == nil {
		backslashEscapes = !strings.Contains(strings.ToUpper(mode), "NO_BACKSLASH_ESCAPES")
	}
	// A failure to read the mode leaves it true — the default MySQL
	// behaviour, and the direction that escapes MORE rather than less.

	return &sqlConn{
		db:            db,
		gate:          AssertSQLReadOnly,
		writable:      c.Writable,
		killsOnCancel: true,
		listSQL:       "SHOW TABLES",
		columnsSQL: "SELECT table_name, column_name FROM information_schema.columns " +
			"WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position",
		quoteIdent: mysqlQuoteIdent,
		primaryKeySQL: "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE " +
			"WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? " +
			"AND CONSTRAINT_NAME = 'PRIMARY' ORDER BY ORDINAL_POSITION",
		backslashEscapes: backslashEscapes,
		quoteLiteral: func(s string) (string, error) {
			return mysqlQuoteLiteral(s, backslashEscapes)
		},
	}, nil
}

// hardenMySQLConfig rewrites a parsed DSN into the only shape this
// driver is willing to hand go-sql-driver, discarding whatever the
// stored connection string asked for.
//
// It is a separate function from Connect so it can be tested against a
// hostile DSN without a live server; Connect is its only caller.
//
// Why rewriting is necessary at all: the DSN does not have to have come
// from composeMySQLDSN. `wakil secrets set <ref>` reads an arbitrary DSN
// on stdin — a path cmd/wakil/main.go documents as supported — and
// Connect re-parses whatever comes back out of the Keychain. Connect
// already had to rewrite the config to add transaction_read_only, so it
// is the one place that can state what the driver is finally given.
//
// 1. transaction_read_only=1 forces EVERY connection the pool opens to
// be read-only at the engine level, not just whichever one a one-shot
// "SET SESSION" statement happens to land on. database/sql opens
// additional connections on demand as load requires, and each is a fresh
// TCP connection made by the driver's own connector rather than by any
// SQL text this package controls; the DSN is the one thing applied to
// all of them. Phase 1's read-only guarantee has no caller override, so
// this is unconditional rather than conditioned on Connection.ReadOnly.
//
// 2. Every OTHER connection parameter is DISCARDED, not merged. Anything
// go-sql-driver does not recognise as a config key lands in cfg.Params,
// and the driver concatenates those raw into a single
// "SET k1 = v1, k2 = v2" statement it runs on every new connection
// (mysql@v1.10.1, connection.go, handleParams) with no quoting and no
// escaping. A stored DSN ending in
//
//	?autocommit=1%2C%20transaction_read_only%3D0
//
// therefore injects a second assignment into that SET and turns the
// engine-level guarantee off. Measured against the live MySQL 8 used for
// acceptance, before this rewrite existed: over six Connects with that
// DSN, @@session.transaction_read_only came back 0 on two of them and a
// CREATE TABLE issued through the pool succeeded — the table was really
// created. It is intermittent because Go randomises map iteration, so
// whether the injected assignment lands before or after ours varies per
// connection. Discarding rather than filtering is deliberate: a filter
// has to enumerate what is dangerous, and this shows the danger is in
// the VALUE grammar, not in any particular key name. The cost is that a
// hand-written DSN can no longer set session variables (sql_mode,
// time_zone, ...), which is a capability Wakil never offered on purpose
// and which composeMySQLDSN cannot produce.
//
// 3. MultiStatements is forced off. It lets one query string carry
// several statements separated by ";". AssertSQLReadOnly rejects a ";"
// in the query text, so this is a second lock on the same door — but it
// is the lock that turns a bypass of that textual gate into nothing at
// all, and that gate has needed repeated hardening rounds — including
// the one that landed alongside this function.
//
// 4. AllowAllFiles is forced off. It removes the driver's allowlist for
// LOAD DATA LOCAL INFILE, which lets the SERVER ask this client for any
// file the Wakil process can read. Nothing about a read-only database
// tool should let the far end read the operator's filesystem.
//
// The rest of mysql.Config was audited alongside these and is
// deliberately left as the stored DSN set it. AllowCleartextPasswords,
// AllowOldPasswords, AllowFallbackToPlaintext and TLSConfig (the DSN's
// "tls" key, which accepts "skip-verify") weaken how the DATABASE
// PASSWORD and the query traffic travel — cleartext auth plugin, pre-4.1
// password hash, silent TLS downgrade, unverified certificate. That is
// real exposure, but of the operator's own credential to the server they
// themselves named, not a route past the read-only guarantee, and
// forcing them off would break deployments that legitimately need them
// (PAM/LDAP auth needs the cleartext plugin; a self-signed internal CA
// needs a custom tls config name).
// RejectReadOnly is the closest false alarm: it only decides whether a
// server-side read-only error is retried as a bad connection, and with
// transaction_read_only=1 on every connection the retry fails the same
// way. InterpolateParams, ClientFoundRows, ColumnsWithAlias, ParseTime,
// Loc, MaxAllowedPacket and the timeouts change result shape, size or
// timing only. DialFunc, TLS (the *tls.Config field, as opposed to the
// TLSConfig name above) and Logger are struct-only fields that no DSN
// string can reach.
//
// Collation is NOT on that harmless list any more, and this comment used
// to say it was (wrongly). It, and the charset field it pairs with, are
// forced to utf8mb4 — see pinMySQLCharset, called from both harden
// functions below — because a charset whose multi-byte trail bytes can
// equal 0x5C defeats mysqlQuoteLiteral's backslash doubling: the escaping
// byte this package adds is exactly the byte such a charset can read as
// the SECOND HALF of the preceding character instead, letting a value
// containing that character break out of the literal it was quoted
// into. Measured against a live server with charset=gbk (one of
// go-sql-driver's own unsafeCollations charsets): a two-byte payload
// ending 0x5C, quoted through mysqlQuoteLiteral and executed, updated
// every row in the table instead of the one it named. That is squarely
// "can a stored DSN use this to write" — the question the rest of this
// list is judged against — so charset/collation moves into the
// forced-off set alongside transaction_read_only, MultiStatements and
// AllowAllFiles.
//
// The question to ask of a field, if this list is ever revisited, is
// "can a stored DSN use this to write, or to make the server read this
// host's files" — that is what selects the fields forced off above.
func hardenMySQLConfig(cfg *mysql.Config) {
	cfg.Params = map[string]string{"transaction_read_only": "1"}
	cfg.MultiStatements = false
	cfg.AllowAllFiles = false
	pinMySQLCharset(cfg)
}

// pinMySQLCharset forces the connection charset to utf8mb4 and clears any
// stored collation, so that no stored DSN can select a charset under
// which mysqlQuoteLiteral's escaping is unsafe.
//
// This is a real, demonstrated injection, not a hypothetical one. A
// DSN's charset and collation are NOT part of cfg.Params — they live in
// cfg.charsets (unexported) and cfg.Collation — so wiping cfg.Params
// (point 2 above) does nothing to them, and unlike Params they SURVIVE
// cfg.FormatDSN() untouched; a DSN ending "?charset=gbk" reaches the
// driver exactly as asked. Under gbk (and big5, sjis, cp932, gb18030,
// gb2312 — precisely go-sql-driver's own unsafeCollations list, v1.10.1
// collations.go), a multi-byte character's trailing byte can equal 0x5C,
// the ASCII backslash mysqlQuoteLiteral doubles as an ESCAPE. The server
// parses the byte stream a character at a time under the connection's
// own charset, not byte by byte, so it can read a lead byte plus that
// trailing 0x5C as one character rather than as "escaped backslash",
// leaving the escaping byte free to close the literal early.
//
// Measured against the live acceptance container: with charset=gbk, the
// payload "\xBF\x5C', id = 99 #" run through mysqlQuoteLiteral (which
// doubles the 0x5C as an ordinary backslash, believing it needs escaping)
// produced a composed statement that MySQL parsed as
//
//	UPDATE ... SET v='…', id = 99 #' WHERE id = 2
//
// — the doubled backslash paired with the preceding 0xBF as one gbk
// character, so the quote right after it closed the literal for real,
// and everything from "id = 99" onward became live SQL with the WHERE
// clause commented out by "#". Every row updated, not just the one
// named. The identical payload under utf8mb4 fails safely instead, with
// MySQL error 1366: utf8mb4's continuation bytes are always in the range
// 0x80-0xBF, so 0x5C can never appear as anything but a literal,
// standalone backslash there.
//
// mysql.Config's charset field is unexported (cfg.charsets), so it
// cannot be assigned directly from this package. mysql.Charset(...) is
// the exported Option the driver itself provides for setting it, applied
// through cfg.Apply. Charset's own implementation (v1.10.1, dsn.go) only
// assigns two fields and always returns a nil error, so that error is
// deliberately discarded here rather than threading a new error return
// through hardenMySQLConfig and hardenMySQLWriteConfig, whose two callers
// both already assume they cannot fail.
func pinMySQLCharset(cfg *mysql.Config) {
	_ = cfg.Apply(mysql.Charset("utf8mb4", ""))
}

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

	return &sqlConn{
		db: db,
		// Reads through a write connection are still gated read-only:
		// Read is Read regardless of which connection serves it.
		gate:      AssertSQLReadOnly,
		writeGate: AssertSQLMutation,
		writable:  c.Writable,
		listSQL:   "SHOW TABLES",
		columnsSQL: "SELECT table_name, column_name FROM information_schema.columns " +
			"WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position",
		quoteIdent: mysqlQuoteIdent,
		primaryKeySQL: "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE " +
			"WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? " +
			"AND CONSTRAINT_NAME = 'PRIMARY' ORDER BY ORDINAL_POSITION",
		backslashEscapes: backslashEscapes,
		quoteLiteral: func(s string) (string, error) {
			return mysqlQuoteLiteral(s, backslashEscapes)
		},
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
//  4. Charset stays pinned to utf8mb4 via pinMySQLCharset, for the same
//     reason as the read path — see hardenMySQLConfig's and
//     pinMySQLCharset's own comments — except here the stakes are higher:
//     this connection actually composes and executes literals through
//     mysqlQuoteLiteral, which is exactly the escaping the charset
//     injection defeats.
//
// What it drops is exactly one thing: transaction_read_only.
func hardenMySQLWriteConfig(cfg *mysql.Config) {
	cfg.Params = map[string]string{}
	cfg.MultiStatements = false
	cfg.AllowAllFiles = false
	pinMySQLCharset(cfg)
}

// mysqlQuoteIdent implements SQL identifier quoting for MySQL (backtick
// form): wrap the identifier in backticks and double any embedded
// backtick, so a hostile identifier (e.g. from a describe_table tool
// argument) cannot terminate the identifier early and have the remainder
// parsed as SQL.
func mysqlQuoteIdent(s string) string {
	return "`" + strings.ReplaceAll(s, "`", "``") + "`"
}

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

// redactPassword removes any occurrence of a non-empty password from an
// error message before it is wrapped and returned to a caller, per
// resolution 3: the DSN contains the password, and driver/engine error
// text can otherwise echo it back verbatim.
func redactPassword(msg, password string) string {
	if password == "" {
		return msg
	}
	return strings.ReplaceAll(msg, password, "[redacted]")
}
