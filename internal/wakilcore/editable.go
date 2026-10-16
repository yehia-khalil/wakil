package wakilcore

import (
	"regexp"
	"strings"
)

// SQLReadSingleTable reports the one table a read's rows came from, and
// which result columns are plain references to that table's columns.
//
// It exists so that a cell can be written back through a WHERE clause that
// names exactly one row. Where it cannot PROVE both facts it answers
// nothing, and the surface stays read-only — which is the failure
// direction this must always prefer.
//
// THE ACCEPTED SHAPE, and nothing else:
//
//	SELECT, with no DISTINCT, of * / <alias>.* / a list of bare
//	identifiers, FROM exactly one unqualified table name with an optional
//	alias, followed by nothing but WHERE / ORDER BY / LIMIT / OFFSET, and
//	no semicolon anywhere but a single one at the very end (a second
//	statement stacked after one is refused outright — see the semicolon
//	check below).
//
// TWO OF THE REFUSALS ARE NOT TIDINESS, and both were measured.
//
// A CTE that shadows a table name produces a well-formed, confirmable
// UPDATE against the wrong data:
//
//	WITH events AS (SELECT 1 AS id, 'z' AS kind) SELECT * FROM events
//
// returns columns named id and kind. A recogniser that read the last
// "FROM <name>" would call this table events, look up the REAL events'
// primary key, find id, and declare the result editable — and the
// operator's edit would write to the real events table, to a row that was
// never on screen. Any WITH token refuses the whole statement; a CTE
// cannot appear in a statement this would otherwise accept.
//
// An expression aliased back to its own source name is the quiet one:
//
//	SELECT id, kind || '!' AS kind FROM events
//
// produces a result column named kind that is NOT the table's kind.
// Editing it would compose SET kind = ... against the real column, so the
// operator edits a derived value and silently overwrites its source.
// Requiring every selected item to be a bare identifier stops it, and is
// the same rule that drops SELECT id AS ident.
//
// A subquery in the WHERE clause is NOT refused and does not need to be:
// the rows still come from the one named table, and its key still
// identifies them.
//
// A qualified name IS refused, because the key lookup is scoped to the
// connection's own database — measured, a bare-name lookup answers the
// current schema's key for a name that pointed at another schema's table.
//
// NOT A FINDING, BUT WORTH KNOWING: a reserved word that appears only
// inside a string literal can cause a conservative FALSE REFUSAL, not a
// false accept. WHERE kind = 'JOIN', WHERE kind = 'UNION ALL',
// WHERE x = 'WITH y AS (...)', and WHERE x = 'a;b' are all refused, because
// the refusal-keyword scan and the semicolon check both run over the
// whole raw SQL text — literal content included — without distinguishing
// a keyword from the same letters sitting inside a quoted string.
// WHERE note = 'FROM users' is, by contrast, ACCEPTED: "FROM" inside that
// literal is not on the refusal list, and it is never confused with the
// true FROM because the true FROM appears earlier in the string and is
// matched first. This is inconsistent as a general rule — some words
// inside literals cause a refusal, most do not — but every one of these
// inconsistencies lands in the safe direction (a refusal, never an
// accept), which is the direction this function must always prefer. It
// is recorded here so a future reader finds it stated, not rediscovers it
// by surprise.
//
// It reads SQL, which only readonly.go otherwise does, and it shares that
// file's stripSQLComments deliberately: that scanner is hardened across
// five documented bypasses, and a second comment-stripper would be a
// second thing to get wrong.
func SQLReadSingleTable(sql string) (string, []string) {
	clean := strings.TrimSpace(stripSQLComments(sql))
	clean = strings.TrimRight(clean, "; \t\n")
	if clean == "" {
		return "", nil
	}
	// A second statement stacked after a semicolon (ignoring one trailing
	// terminator, already trimmed above) is refused outright: everything
	// below only ever inspects the FROM-to-WHERE span, so a "WHERE id = 1;
	// DROP TABLE events" tail would otherwise be reported as a clean
	// single-table read of "events" with the second statement invisible
	// to every check that follows. AssertSQLReadOnly makes the same call
	// on the same text for the same reason; this function must not assume
	// it always runs downstream of that gate.
	if strings.Contains(clean, ";") {
		return "", nil
	}
	// A single refusal scan, checked on word boundaries so a column named
	// "union_id" or a table named "distinct_values" is not caught by it.
	// Matched case-insensitively with the (?i) flag directly against
	// clean — see refusalKeyword's doc for why that, and not
	// strings.ToUpper, is load bearing.
	if refusalKeyword.MatchString(clean) {
		return "", nil
	}
	selectAt := selectKeyword.FindStringIndex(clean)
	if selectAt == nil {
		return "", nil
	}
	fromAt := fromKeyword.FindStringIndex(clean)
	if fromAt == nil {
		return "", nil
	}
	items := strings.TrimSpace(clean[selectAt[1]:fromAt[0]])
	columns, ok := plainSelectItems(items)
	if !ok {
		return "", nil
	}
	// The FROM clause runs to the first of WHERE / ORDER / LIMIT / OFFSET,
	// or to the end. clauseKeyword is matched directly against rest — a
	// subslice of clean — and its offset is used to slice that SAME
	// string, never a transformed copy of it.
	rest := clean[fromAt[1]:]
	end := len(rest)
	if at := clauseKeyword.FindStringIndex(rest); at != nil {
		end = at[0]
	}
	table, ok := singleTableName(strings.TrimSpace(rest[:end]))
	if !ok {
		return "", nil
	}
	return table, columns
}

// refusalKeyword, selectKeyword, fromKeyword, and clauseKeyword are all
// matched with the (?i) flag directly against the string whose bytes will
// then be sliced (clean, or rest — a subslice of clean) — never against a
// strings.ToUpper copy of it.
//
// strings.ToUpper is NOT byte-length-preserving. "ſ" (U+017F, LATIN SMALL
// LETTER LONG S) uppercases to "S", and "ı" (U+0131, LATIN SMALL LETTER
// DOTLESS I) uppercases to "I" — each SHRINKS by one byte in UTF-8, and a
// ligature can shrink by more than one. An earlier version of this
// function matched keywords against strings.ToUpper(clean) (or
// strings.ToUpper(rest)) and then applied the byte index the match
// reported back to clean (or rest) itself. Every such shrunk byte
// appearing before a match shifts that index left of where it belongs
// once applied to the un-uppercased string, so rest[:end] silently
// truncated the tail of the FROM clause before it ever reached the
// comma-joined table that followed. Verified end to end against a live
// engine (modernc.org/sqlite):
//
//	SELECT * FROM events eıııııııııı, users u WHERE 1=1
//
// truncated the FROM clause right before ", users u", so this function
// reported table="events", cols=nil — a clean single-table read — for a
// statement that is in fact a comma join returning the 4-column cross
// product [id kind id name]. AssertSQLReadOnly allows the statement to
// run (it contains no write keyword), so the next stage would have
// composed an UPDATE against events for what is actually a users column
// the operator never saw labelled as one — exactly the failure this
// function exists to prevent. (?i) does not have this problem: the
// regexp engine matches case-insensitively via Unicode simple case
// folding without ever transforming or reallocating the string being
// matched, so every index it reports already belongs to that string. Do
// not reintroduce strings.ToUpper, or any other transform that can change
// byte length, upstream of a slice anywhere in this file.
var (
	refusalKeyword = regexp.MustCompile(`(?i)\b(WITH|JOIN|DISTINCT|GROUP|HAVING|UNION|INTERSECT|EXCEPT|OVER)\b`)
	selectKeyword  = regexp.MustCompile(`(?i)^SELECT\b`)
	fromKeyword    = regexp.MustCompile(`(?i)\bFROM\b`)
	clauseKeyword  = regexp.MustCompile(`(?i)\b(WHERE|ORDER|LIMIT|OFFSET)\b`)
)

// bareIdent is a single unquoted SQL identifier and nothing else: no dot,
// no parenthesis, no operator, no space.
var bareIdent = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_$]*$`)

// plainSelectItems returns the selected column names, or ok=false if any
// item is not a bare identifier. A "*" (or "<alias>.*") yields nil
// columns, meaning "all of them, and all of them are plain".
func plainSelectItems(items string) ([]string, bool) {
	if items == "*" {
		return nil, true
	}
	if strings.HasSuffix(items, ".*") && bareIdent.MatchString(strings.TrimSuffix(items, ".*")) {
		return nil, true
	}
	parts := strings.Split(items, ",")
	out := make([]string, 0, len(parts))
	seen := map[string]bool{}
	for _, part := range parts {
		name := strings.TrimSpace(part)
		if !bareIdent.MatchString(name) {
			return nil, false
		}
		// A duplicate result name has no single column to write to.
		if seen[strings.ToLower(name)] {
			return nil, false
		}
		seen[strings.ToLower(name)] = true
		out = append(out, name)
	}
	if len(out) == 0 {
		return nil, false
	}
	return out, true
}

// singleTableName accepts "t", "t a", "t AS a", and the quoted forms of
// the name. Anything else — a comma, a parenthesis, a dot, more than two
// words after the alias keyword — is not one table.
func singleTableName(clause string) (string, bool) {
	if clause == "" || strings.ContainsAny(clause, ",()") {
		return "", false
	}
	fields := strings.Fields(clause)
	if len(fields) == 0 {
		return "", false
	}
	// "t a" is two fields, "t AS a" is three; anything longer is not a
	// single aliased table.
	if len(fields) == 3 && !strings.EqualFold(fields[1], "AS") {
		return "", false
	}
	if len(fields) > 3 {
		return "", false
	}
	name := unquoteIdent(fields[0])
	// A dot survives unquoting only on a qualified name, which is refused.
	if !bareIdent.MatchString(name) {
		return "", false
	}
	return name, true
}

// unquoteIdent strips one layer of "..." or `...` and undoubles any
// embedded quote character, matching how each engine reads one.
func unquoteIdent(s string) string {
	if len(s) >= 2 {
		switch s[0] {
		case '"':
			if s[len(s)-1] == '"' {
				return strings.ReplaceAll(s[1:len(s)-1], `""`, `"`)
			}
		case '`':
			if s[len(s)-1] == '`' {
				return strings.ReplaceAll(s[1:len(s)-1], "``", "`")
			}
		}
	}
	return s
}
