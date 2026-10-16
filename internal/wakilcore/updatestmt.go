package wakilcore

import (
	"regexp"
	"strings"
)

// ExpressionPrefix marks a typed cell value as SQL rather than as a value.
//
// The spreadsheet convention, and it is a convention rather than a guess:
// inferring "NOW() looks like a function" from the text is exactly the
// kind of guess the chip rule and the drill rule already refuse, and it
// would make a name column holding "Doe(x)" into a function call.
const ExpressionPrefix = "="

// numericLiteralPattern is what a NUMBER looks like to both engines: an
// optional sign, digits, an optional single decimal point, and an optional
// e/E exponent. Nothing else.
//
// strconv.ParseFloat is deliberately NOT used here, because Go's float
// grammar is wider than SQL's: measured, ParseFloat happily accepts "NaN",
// "Inf", "+Inf", "infinity", the hex float "0x1p4", and the digit-grouped
// "1_000" — and every one of those, quoted and sent to a numeric column,
// is read differently by the two engines: sqlite's affinity stores the
// text verbatim (typeof() reports "text", the column silently stopped
// being a number), while live MySQL under strict mode refuses it with
// Error 1366. That is exactly the divergence this whole validation step
// exists to collapse into one sentence, so accepting Go's float syntax
// here would reopen it. A regexp says the shape of a SQL number directly,
// rather than through the accident of what a general-purpose float parser
// happens to also accept.
var numericLiteralPattern = regexp.MustCompile(`^[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?$`)

// numericTypePrefixes are the declared type names whose values must match
// numericLiteralPattern before a statement is composed.
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
// Matched by hasTypePrefix as a whole LEADING WORD, case-insensitively, so
// "DECIMAL(10,2)" and "INT UNSIGNED" are covered by their stems ("DECIMAL",
// "INT" — the type name up to its first non-letter character) — but
// "INTERVAL" is one leading word, the whole word "INTERVAL", and is not
// swept in by "INT" the way a bare prefix scan would (see hasTypePrefix's
// own doc comment for why a bare prefix scan over-reaches in both
// directions). "INT" and "INTEGER" are consequently both listed, as two
// different whole words for the same concept, rather than one being
// treated as a prefix of the other.
//
// "UNSIGNED BIG INT" is sqlite's own documented, multi-word type name (its
// column-affinity rules give it INTEGER affinity), and is listed here in
// full because it is not one leading word at all — without this entry a
// column declared that way would validate nothing and let 'abc' through
// silently, the exact failure this list exists against.
var numericTypePrefixes = []string{
	"INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT", "UNSIGNED BIG INT",
	"DECIMAL", "NUMERIC", "REAL", "DOUBLE", "FLOAT",
}

// uneditableTypePrefixes are the declared types no quoted literal can
// express. BIT is the only one either engine has: measured, a quoted
// literal into BIT(1) is Error 1406 "Data too long", while a bare one
// works — and a bare literal is a column reference, which is the one thing
// a VALUE composed by this function must never emit. The query line
// remains its route — and so does an expression: see RenderUpdate, this
// check runs only on the value path, not the expression path, precisely
// so that "=b'1'" (a genuine MySQL bit literal) is not refused by the same
// rule that refuses a bare "1".
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
//
// # The unescapable "="
//
// **A value that begins with "=" cannot be written as literal text through
// this function, and there is no escape hatch for it.** ExpressionPrefix
// is stripped and everything after it is treated as the operator's own
// SQL — so a cell edit typed as "=secret" composes "SET \"v\" = secret",
// the exact bare-literal hazard the quoting rule above exists against:
// measured, it silently COPIED another column (a column literally named
// secret, or the value hunter2 sitting in it) with no error, on both
// engines. Doubling the sigil does not help ("==x" is still "=" followed
// by the expression "=x", i.e. a different, equally bare hazard) and no
// second sigil was added to escape the first: a value beginning with "="
// is spec'd, deliberately, as the operator asking for SQL, and adding an
// escape for it would mean this one function must now also decide when an
// escaped "=" is "really" a value versus really an escape — which is
// exactly the kind of guessing ExpressionPrefix's own doc comment already
// refuses to do for "NOW() looks like a function". **If the literal text
// of a cell must begin with "=", it cannot be typed into the grid — it
// must be written from the query line**, where there is no sigil to
// collide with and the operator's raw text is never split into an
// expression at all. The confirmation plane still shows the composed
// statement whole before anything runs, so a mistaken "=identifier" is
// visible, if not prevented, at the last moment before it executes.
//
// # The semicolon decision
//
// AssertSQLMutation (mutation.go) refuses any statement containing a ";",
// to block stacked statements, and its scan runs over the WHOLE composed
// statement text — including string literals — because it deliberately
// shares that simplicity with stripSQLComments rather than adding a second,
// literal-aware scanner next to a gate that is already hardened across five
// documented bypasses (see AssertSQLMutation's own doc comment). The
// consequence: an utterly ordinary edit —
//
//	UPDATE "notes" SET "body" = 'hello; world' WHERE "id" = 1
//
// — is FALSELY refused, "multiple statements are not allowed in a
// mutation", because the gate cannot tell a ";" inside a quoted literal
// from one splitting two statements. This was the known defect this task
// was handed to decide between two fixes:
//
//	(a) Teach AssertSQLMutation's ";" check to skip quoted literals.
//	(b) Have RenderUpdate refuse a value containing ";" itself, before the
//	    gate ever sees it, with a sentence telling the operator to use the
//	    query line instead.
//
// **(b) is what this function does, and (a) was rejected.** Not because
// (a) is impossible, but because making it SAFE means re-deriving, in a
// second scanner living beside the first, every rule stripSQLComments and
// the gate around it needed five hardening rounds to get right: a doubled
// quote mark inside a string literal, MySQL's backslash-escaping mode
// (which is a property of the SERVER — see sqlConn.backslashEscapes — not
// a constant this function could assume), an unterminated literal at end
// of input, and a ";" sitting inside a comment or inside a double-quoted or
// backtick-quoted identifier rather than a value. Getting any one of those
// wrong does not make the false refusal come back — it reopens the
// stacked-statement hole the gate exists to close, which is the one
// failure mode worse than an operator reading "use the query line" for a
// semicolon they typed into a text field. A false refusal the operator can
// read and work around is a far better failure than a widened security
// gate whose new edge case nobody has stress-tested the way readonly.go's
// five rounds did. So: refuse early, refuse legibly, and leave the
// hardened gate exactly as hardened.
//
// ";" is not the gate's only literal-blind scan — outfileKeyword
// (mutation.go) is the other, matching "INTO OUTFILE"/"INTO DUMPFILE"
// anywhere in the composed text. Measured, a value like
// "export INTO OUTFILE '/tmp/x'" composes without complaint here and is
// then refused by AssertSQLMutation — the same false-refusal class as the
// ";" case above. It is not pre-empted the way ";" is: outfileKeyword is
// documented in mutation.go as belt-and-braces rather than load-bearing
// (MySQL rejects that shape from an INSERT/UPDATE/DELETE prefix at parse
// time regardless, and hardenMySQLWriteConfig separately turns off
// AllowAllFiles), so a rarer false refusal here was judged not worth a
// second bespoke pre-check. It is recorded so the next reader knows there
// are two literal-blind scans, not one.
//
// This refusal applies only to an ordinary VALUE. A leading "=" (see
// ExpressionPrefix) is the operator's own SQL, not a value the engine will
// quote — a ";" there is a genuine attempt at a second statement, and it
// is correctly left to reach AssertSQLMutation and be refused there, where
// the hardened scan actually runs over live SQL rather than the contents
// of a string literal.
//
// One consequence of that is worth writing down rather than discovering
// later: an expression that reopens the WHERE clause, e.g. a value of
// "=1 WHERE 1=1 --", composes one statement that AssertSQLMutation
// accepts (it is one statement, well-formed, and begins UPDATE) and that
// changes every row in the table. MutationAffectsEveryRow reports this as
// NOT affecting every row, because a WHERE token is textually present —
// the advisory scan cannot tell a real predicate from a comment eating one.
// This is intended, not a bug to fix here: the operator asked for SQL in
// so many words, the composed statement is shown whole in the confirmation
// plane before anything runs, and they confirm it by hand. The absence of
// the "no WHERE clause" warning in this one case is a known gap in an
// ADVISORY-ONLY signal, not a gap in the gate that actually runs the
// statement.
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

	var assigned string
	if expression, ok := strings.CutPrefix(value, ExpressionPrefix); ok {
		// Not a value: the operator asked for SQL in so many words. It is
		// neither escaped nor validated, and it is still composed into ONE
		// statement that passes AssertSQLMutation, is shown whole in the
		// confirmation plane, and needs a typed confirmation. That is the
		// same authority the query line has given them since 2c-ii,
		// reached by a shorter route.
		//
		// uneditableTypePrefixes is deliberately NOT consulted here: it
		// exists to stop a bare, unquotable VALUE from being emitted (see
		// its own doc comment), and an expression is not a value — a BIT
		// column can only ever be written through its own bit-literal
		// syntax ("b'1'"), which is exactly what this branch lets through.
		if strings.TrimSpace(expression) == "" {
			return "", UserError("an expression cannot be empty")
		}
		assigned = expression
	} else {
		if hasTypePrefix(columnType, uneditableTypePrefixes) {
			return "", UserError(
				"a " + columnType + " column cannot be edited in the grid; use the query line")
		}
		// The semicolon decision above, applied: refuse here, before the
		// value is ever quoted into a statement, rather than let it reach
		// AssertSQLMutation and be misread as a stacked statement.
		if strings.Contains(value, ";") {
			return "", UserError(
				"a value containing \";\" cannot be edited in the grid, because the " +
					"safety check that blocks multiple statements cannot tell a " +
					"semicolon in your text from one splitting two statements; " +
					"use the query line for this edit")
		}
		// Validation and quoting run on the SAME string. Trimming only for
		// the ParseFloat-equivalent check, then quoting the untrimmed
		// original, was measured to disagree with itself: a value of
		// "\n8" validated (its trimmed form is a plain number) and was
		// then quoted verbatim, and MySQL under strict mode refused the
		// resulting '\n8' literal with Error 1366 — a value this function
		// had just told the operator was fine. Reassigning value to its
		// trimmed form before quoting keeps what is checked and what is
		// sent in agreement, and a numeric column has no legitimate use
		// for leading or trailing whitespace in its stored text anyway.
		if hasTypePrefix(columnType, numericTypePrefixes) {
			value = strings.TrimSpace(value)
			if !numericLiteralPattern.MatchString(value) {
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

// hasTypePrefix reports whether columnType names one of prefixes, matched
// as a whole LEADING WORD rather than as a bare string prefix.
//
// A bare strings.HasPrefix over-reaches in both directions, measured:
// "BIT" as a prefix matches "BITTER" and "BITS" (neither is a BIT column),
// and "INT" as a prefix matches both "INTEGER" (which IS an integer
// column — that one should match) and "INTERVAL" (which is not, on
// either engine, a numeric column at all — a bare prefix scan cannot
// tell these two apart, because both simply continue past "INT" with
// more letters of one longer word).
//
// So this does not try to find a clever boundary rule inside a single
// word — instead it splits columnType into its LEADING WORD (the run of
// letters at the very start, stopping at the first digit, space,
// parenthesis, or end of string: "DECIMAL(10,2)" -> "DECIMAL", "INT
// UNSIGNED" -> "INT", "INTERVAL" -> "INTERVAL" — a whole word, distinct
// from "INT") and compares that whole word for EQUALITY against each
// single-word prefix. "INT" and "INTEGER" are consequently both listed
// wherever both are meant to match, as two whole words, rather than one
// standing in as a prefix of the other.
//
// A prefix containing a space (currently only "UNSIGNED BIG INT", see
// numericTypePrefixes) is not a single leading word at all, so it is
// matched the other way: as a phrase, present at the start of columnType,
// ending at columnType's end or at a non-letter character — i.e. not
// itself extended by more letters of the same word.
func hasTypePrefix(columnType string, prefixes []string) bool {
	upper := strings.ToUpper(strings.TrimSpace(columnType))
	word := leadingWord(upper)
	for _, prefix := range prefixes {
		if !strings.Contains(prefix, " ") {
			if word == prefix {
				return true
			}
			continue
		}
		if !strings.HasPrefix(upper, prefix) {
			continue
		}
		if len(upper) == len(prefix) {
			return true
		}
		if next := upper[len(prefix)]; next < 'A' || next > 'Z' {
			return true
		}
	}
	return false
}

// leadingWord returns the run of ASCII letters at the start of s, stopping
// at the first byte that is not A-Z (a digit, a space, "(", or the end of
// the string). It is what distinguishes "INT" from "INTEGER" from
// "INTERVAL" as three different whole words, rather than treating any one
// of them as a prefix of another.
func leadingWord(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] < 'A' || s[i] > 'Z' {
			return s[:i]
		}
	}
	return s
}
