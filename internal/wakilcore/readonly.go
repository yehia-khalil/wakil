package wakilcore

import (
	"encoding/json"
	"regexp"
	"strings"
)

// writeKeyword matches any keyword that can mutate data, schema, or session
// state, or that can execute arbitrary SQL supplied as a string, across the
// engines Wakil targets (Postgres, MySQL, SQLite):
//
//   - INSERT/UPDATE/DELETE/REPLACE/UPSERT/MERGE: data writes.
//   - DROP/ALTER/CREATE/TRUNCATE/RENAME/REINDEX/VACUUM: schema/storage
//     writes.
//   - GRANT/REVOKE/LOCK/SET/ATTACH/DETACH/PRAGMA: session or
//     access-control state changes (SQLite's ATTACH/PRAGMA can rebind the
//     database file or change write-affecting settings).
//   - COPY/LOAD: bulk data movement to/from disk (Postgres COPY TO/FROM,
//     MySQL LOAD DATA), which is a write in the FROM direction and a
//     disk-write side channel in the TO direction.
//   - CALL/HANDLER/DO: procedure/anonymous-block execution, which can
//     perform arbitrary writes.
//   - PREPARE/EXECUTE/DEALLOCATE: prepare and run arbitrary SQL supplied
//     as a string, which would otherwise defeat this entire gate.
//   - INTO: "SELECT ... INTO OUTFILE/DUMPFILE" (MySQL) writes a file to
//     disk, and "SELECT ... INTO" (T-SQL/Postgres) can create a table or
//     assign into a variable — both despite the statement starting with
//     SELECT and containing none of the other keywords above.
var writeKeyword = regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|REPLACE|MERGE|GRANT|REVOKE|CALL|LOCK|RENAME|SET|INTO|ATTACH|DETACH|PRAGMA|VACUUM|REINDEX|COPY|LOAD|PREPARE|EXECUTE|DEALLOCATE|HANDLER|DO|UPSERT)\b`)

// showSafeWriteKeyword is writeKeyword with CREATE and GRANT removed. It is
// used, instead of writeKeyword, only for statements whose leading keyword
// is SHOW — see the SHOW carve-out in AssertSQLReadOnly. CREATE and GRANT
// are two of the three tokens that collide with legitimate SHOW forms
// (SHOW CREATE TABLE/VIEW/..., SHOW GRANTS); the third, SET (from SHOW
// CHARACTER SET), is handled separately and positionally by
// showCharacterSetPhrase below, since SET must otherwise remain blocked
// under SHOW (e.g. "SHOW SET x=1" must still be rejected). Every other
// blocked keyword remains active for SHOW statements, so e.g.
// "SHOW DELETE FROM t" is still rejected.
var showSafeWriteKeyword = regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|REPLACE|MERGE|REVOKE|CALL|LOCK|RENAME|SET|INTO|ATTACH|DETACH|PRAGMA|VACUUM|REINDEX|COPY|LOAD|PREPARE|EXECUTE|DEALLOCATE|HANDLER|DO|UPSERT)\b`)

// showCharacterSetPhrase matches the exact phrase "CHARACTER SET" (with
// arbitrary whitespace between the two words), the one place a SHOW
// statement legitimately contains the word SET ("SHOW CHARACTER SET").
// It is used, only under a SHOW prefix, to blank out that specific phrase
// before running showSafeWriteKeyword, so the SET inside it doesn't match
// — while a bare SET anywhere else in a SHOW statement (e.g.
// "SHOW SET x=1") still does, because it was never part of this phrase.
var showCharacterSetPhrase = regexp.MustCompile(`(?i)\bCHARACTER\s+SET\b`)

// firstKeyword extracts the leading alphabetic token of a (whitespace
// trimmed, upper-cased) statement, used to detect a leading SHOW.
var firstKeyword = regexp.MustCompile(`^([A-Za-z]+)`)

// startsLineComment reports whether a "--" line comment begins at i.
//
// MySQL requires the second dash to be followed by whitespace or a
// control character, or by end of input; "--" followed by anything else
// is a binary minus applied to a unary minus. Re-measured for this change
// against the live MySQL 8.4.11 used for acceptance:
//
//	SELECT 1--1 AS v           -> 2   (1 - (-1); NOT a comment)
//	SELECT 10--5 AS v          -> 15  (NOT a comment)
//	SELECT 1--(2) AS v         -> 3   (NOT a comment)
//	SELECT 1 AS v -- a comment -> 1   (comment)
//	SELECT 5 AS v --<TAB>6     -> 5   (comment)
//	SELECT 1 AS v --<DEL>6     -> 1   (comment; DEL is a control character)
//	SELECT 1 AS v --<EOF>      -> 1   (comment)
//
// The rule used to be the regexp `--[^\n]*`, which stripped
// unconditionally. That DELETED text MySQL EXECUTES, before every check in
// AssertSQLReadOnly, so both of these were ALLOWED — reproduced end to end
// through the wakil-db read path against a real server, where the first
// actually wrote a file (/var/lib/mysql-files/ctl_probe.txt) on the
// database host from a tool that is supposed to be read-only:
//
//	SELECT 1--1 INTO OUTFILE '/var/lib/mysql-files/ctl_probe.txt'
//	SELECT 1--1; DROP TABLE customers
//
// The governing principle, here and in stripSQLComments: when engines
// disagree about whether a span is a dead comment or live SQL, this gate
// assumes LIVE. Keeping non-comment text visible to the checks below can
// only ever over-reject; stripping live text under-rejects, and
// under-rejection is what puts a write on a real database. Two deliberate
// consequences of that bias, both in the safe direction:
//
//   - NEWLINE IS EXCLUDED FROM THE INTRODUCER CLASS ON PURPOSE, so that
//     "SELECT 1--\nDELETE FROM t" does not match. For MySQL a "--" comment
//     opens and closes on its own line and the NEXT line is live SQL:
//     measured, "SELECT 1 AS v --\nUNION SELECT 2" returns rows 1 AND 2.
//     Letting "--\n" introduce a comment would let the span run on and
//     swallow that live line — i.e. it would re-create, in a new shape,
//     the very bug this file has now been fixed for three times. Do not
//     "simplify" the class by adding \n to it. The cost is that the empty
//     comment "--" at end of line is left in place; it contains no keyword
//     and no separator, so it changes no verdict.
//   - DEL (0x7f) is excluded even though the probe above shows MySQL
//     treats it as an introducer, so this class is NARROWER than MySQL's
//     own rule. The only thing a wider class would buy is the ability to
//     strip a "--\x7f..." comment; omitting it costs at most a false
//     rejection of a query nobody writes. It is the same posture that
//     leaves "#" unstripped entirely (see stripSQLComments).
//
// For Postgres and SQLite, which treat "--" as a comment unconditionally,
// this under-strips: "SELECT 1--1 INTO OUTFILE '/tmp/x'" is a bare
// "SELECT 1" to them and is rejected here anyway, on the INTO. Measured on
// modernc.org/sqlite, "SELECT 1--1" returns 1, not 2. Over-rejection
// again, i.e. the safe direction.
func startsLineComment(s string, i int) bool {
	if i+1 >= len(s) || s[i] != '-' || s[i+1] != '-' {
		return false
	}
	if i+2 == len(s) {
		return true
	}
	c := s[i+2]
	return c <= 0x20 && c != '\n'
}

// scanToLineEnd returns the index of the newline that ends the line
// containing i, or len(s) if there is none. The newline itself is NOT
// consumed, so the caller copies it and the text keeps its line structure.
func scanToLineEnd(s string, i int) int {
	if n := strings.IndexByte(s[i:], '\n'); n >= 0 {
		return i + n
	}
	return len(s)
}

// scanQuotedSpan returns the index just past the quoted span that starts
// at i, where s[i] is one of ' " or `, reading a backslash as an ORDINARY
// character. An unterminated span runs to end of input.
//
// A doubled quote (two of the same quote byte in a row inside the span)
// closes and reopens, which every engine Wakil targets agrees on.
//
// Treating a backslash as an ordinary character, as this function does, is
// how SQLite reads it, how Postgres reads it in standard-conforming
// strings, and how MySQL reads it under NO_BACKSLASH_ESCAPES. It is NOT
// MySQL's default, where a backslash escapes the next byte;
// scanQuotedSpanEscaped is that other reading. Neither reading is safe on
// its own, so stripSQLComments computes both and stops stripping as soon
// as they disagree — see the note there, which is where the reason lives.
func scanQuotedSpan(s string, i int) int {
	q := s[i]
	for j := i + 1; j < len(s); j++ {
		if s[j] != q {
			continue
		}
		if j+1 < len(s) && s[j+1] == q {
			j++ // doubled quote: consume both, stay inside
			continue
		}
		return j + 1
	}
	return len(s)
}

// scanQuotedSpanEscaped is scanQuotedSpan under MySQL's DEFAULT reading,
// in which a backslash escapes the following byte, so "\'" does not close
// the span. Measured on the live MySQL 8.4.11 used for acceptance:
// LENGTH('a\' -- ') is 6, i.e. that whole thing is ONE literal whose
// content is "a' -- ". Measured on modernc.org/sqlite, LENGTH('a\') is 2,
// i.e. the same bytes are a CLOSED two-character literal there.
func scanQuotedSpanEscaped(s string, i int) int {
	q := s[i]
	for j := i + 1; j < len(s); j++ {
		if s[j] == '\\' {
			j++ // escaped byte: consume it, stay inside
			continue
		}
		if s[j] != q {
			continue
		}
		if j+1 < len(s) && s[j+1] == q {
			j++ // doubled quote: consume both, stay inside
			continue
		}
		return j + 1
	}
	return len(s)
}

// stripSQLComments removes dead comment spans in ONE left-to-right pass
// that tracks quoted-span state.
//
// WHY ONE PASS. This used to be two independent passes — block comments,
// then line comments — and neither knew about string literals or about the
// other's syntax. That made a comment introducer context-free, so a "/*"
// written inside a "--" comment opened a block comment that swallowed
// every line up to a later "*/", DELETING LIVE SQL before any check in
// AssertSQLReadOnly ran. Reproduced end to end against the live MySQL
// 8.4.11 acceptance container:
//
//	SELECT 1 -- /*
//	UNION SELECT 2
//	-- */                 -> gate allowed it; MySQL returned rows 1 AND 2
//
//	SELECT 1 -- /*
//	INTO OUTFILE '/var/lib/mysql-files/x.txt'
//	-- */                 -> gate allowed it; a file appeared on the server
//
// No ";" is involved, so MultiStatements=false does not help. This was the
// THIRD bypass found in this function (after "SELECT 1--1 INTO OUTFILE",
// fixed in 567fc08), which is why the fix is structural: any scheme where
// one syntax can open a span inside another has the same shape of hole.
//
// WHAT IS AND IS NOT REMOVED. Only spans that are dead in every engine
// Wakil targets are replaced, and always with a single space so two tokens
// can never fuse and hide a keyword from the \b-anchored scan:
//
//   - "-- ..." to end of line          -> replaced (see startsLineComment)
//   - "/* ... */" without "!"          -> replaced
//
// Everything else is copied VERBATIM, including three things that might
// look like candidates for removal and are not:
//
//   - QUOTED SPANS ('...', "...", `...`). Their contents stay visible to
//     the keyword scan, so "SELECT 'DELETE FROM t'" keeps being rejected
//     exactly as before this rewrite. Literal-awareness here is only about
//     deciding where a comment STARTS; it must never become a licence to
//     hide text from the checks.
//   - "# ...", MySQL's other line comment, and everything after it.
//     Nothing stripped a "#" line before and nothing does now, so
//     "SELECT 1 # DELETE FROM t" is still rejected. It must still be
//     RECOGNISED, though, or "SELECT 1 # /*\nDELETE FROM t\n# */" is the
//     identical bypass in a new costume — that shape really does return
//     rows 1 and 2, and really does write a file with INTO OUTFILE, on the
//     live MySQL 8.4.11 acceptance container.
//   - "/*! ... */", MySQL's executable comment (optionally "/*!NNNNN ...
//     */" with a version number), and everything after it. To MySQL's own
//     parser that is not a dead comment: it strips only the "/*!" and "*/"
//     delimiters and parses the content between them as live SQL, executed
//     unconditionally, or conditionally on the server version when digits
//     follow the "!". Since this gate cannot know the target server's
//     version, and other engines treat "/*!...*/" as an ordinary comment,
//     the safe assumption is that the content may be live: stripping it
//     would hide an injected write, and any ";" inside it, from every
//     check in AssertSQLReadOnly. Keeping the CONTENT was never enough on
//     its own, though — see the fifth disagreement below, where finding the
//     comment's END the wrong way let a payload hide after it. See also the
//     long note on AssertSQLReadOnly for how this composes with the SHOW
//     carve-out.
//
// An ORDINARY "/* ... */" — one without the "!" — closes at the FIRST
// "*/", matching real SQL semantics: comments do not nest, and no engine
// honours a quote inside one, so "/* /* */ DELETE FROM t */" leaves the
// DELETE as live text instead of swallowing it. That plain scan is correct
// only because the content is dead to everybody. It is NOT correct for
// "/*!", whose content is live to MySQL and therefore lexed with literals
// honoured; that is the fifth disagreement below. An unterminated "/*"
// leaves the remainder untouched rather than silently discarding text of
// unknown intent.
//
// WHERE THE ENGINES DISAGREE, THE SCANNER GIVES UP. There are five known
// places where the target engines lex the SAME bytes differently, so no
// single reading is safe. In all five the scanner copies the ENTIRE
// remainder of the input verbatim and strips nothing more. That leaves
// strictly more text visible than any one reading would, so it can only
// over-reject.
//
// FIVE IS THE COUNT OF THE ONES THAT ARE CLOSED, NOT A PROOF THAT THERE ARE
// NO OTHERS, and the trend is the point: every one of the five was found by
// running something, four of them AFTER this scanner was written and
// believed correct, and the fifth after four rounds of review had passed
// over it. Two got past the generated-input test in this file as well,
// because a reference lexer written from the same mental model as the
// scanner cannot find the scanner's blind spots. Treat the list as the
// current state of a search, not as a completed one. A sixth is known and
// NOT closed — Postgres dollar-quoting, at the end — and the difference
// that matters is that it is UNREACHABLE today while all five below were
// reachable, four of them demonstrated by making a real engine write a
// real file.
//
// The first is a "--" that MySQL does NOT read as a comment introducer:
// "SELECT 1--1" is arithmetic to MySQL but a comment to SQLite and
// Postgres, so the rest of that line is live to one engine and dead to the
// others. Keeping it (MySQL's reading) is the safe half, but it is not
// enough on its own, because a "/*" sitting in that live-to-MySQL text
// then opens a block comment for THIS scanner that SQLite never opens.
// Measured end to end against modernc.org/sqlite, on the same mode=ro DSN
// sqliteDriver.Connect builds:
//
//	SELECT 1--/*
//	; ATTACH DATABASE '<tmp>/side.db' AS s
//	-- */                 -> stripped to "SELECT 1-- "; gate ALLOWED it;
//	                         side.db was created on disk
//
// (The DROP variant of the same payload reached the engine too and was
// stopped only by mode=ro — "attempt to write a readonly database". ATTACH
// is not stopped by mode=ro, which is why it is the payload used here.)
//
// The second is "#", which is a dead comment to MySQL and live text to
// SQLite and Postgres. Anything on that line is therefore inert to one
// engine and a live token to the others — a quote that opens a literal, or
// a "/*" that opens a block comment, either of which runs on past the end
// of the line and moves every span boundary after it. Nothing on a "#"
// line was ever stripped; from the first "#" onward, nothing after it is
// stripped either. (No exploit is known for this one: measured,
// modernc.org/sqlite refuses the whole string with
// `unrecognized token: "#"` before executing anything. The scanner does
// not rely on that — depending on an engine's current refusal instead of
// checking for the dangerous shape is the posture that produced the
// bypasses above.)
//
// The third is the backslash, and here BOTH choices are exploitable, which
// is why neither is made. Measured:
//
//	MySQL 8.4.11 (default sql_mode): LENGTH('a\' -- ') is 6 — one literal.
//	  So reading "\" as ordinary ends the literal early and re-arms the
//	  "--", and "SELECT 'a\' -- ' INTO OUTFILE '/var/lib/mysql-files/x'"
//	  strips to "SELECT 'a\' " and is ALLOWED, while the server writes a
//	  7-byte file. (Confirmed against the container.)
//	modernc.org/sqlite: LENGTH('a\') is 2, and "SELECT 'a\' , 'b -- c'"
//	  really is two columns. So reading "\" as an escape runs the literal
//	  on to the NEXT quote, re-arming a "--" further right, and
//	  "SELECT 'a\' , 'b -- c' ; DROP TABLE t" would strip to
//	  "SELECT 'a\' , 'b  " and be ALLOWED — and that driver executes both
//	  statements in one Query (measured: the table was gone afterwards).
//
// So when the two readings disagree about where a literal ends, every byte
// after it is of unknown status and the scanner stops stripping. The cost
// is a genuine comment going unstripped in a query that also contains a
// backslash inside a literal, which only changes a verdict if that comment
// itself holds a blocked keyword or a ";". Where the two readings AGREE —
// which is every literal without a backslash, and also ordinary ones like
// 'C:\path' — nothing is given up and stripping proceeds.
//
// The fourth is "[ ... ]". SQLite (and T-SQL) quote identifiers that way;
// MySQL has no such span, so there is no pair of readings to compare here
// — the disagreement is that one engine has a span and the other has
// none. A "--" written inside a bracket identifier is live SQL to SQLite
// and a comment introducer to this scanner, which then deletes the rest of
// the line. Measured through Conn.Read on the mode=ro DSN
// sqliteDriver.Connect builds:
//
//	SELECT 1 AS [a-- ];ATTACH DATABASE '<tmp>/e2e_side.db' AS s
//	  -> stripped to "SELECT 1 AS [a "; gate ALLOWED it; Conn.Read
//	     returned no error; e2e_side.db was created on disk
//
// The two halves of the disagreement, both measured: modernc.org/sqlite
// answers 1 to "SELECT 1 AS [a-- ]", while MySQL 8.4.11 answers
// "ERROR 1064 (42000) ... near '[a-- ]'". (Also measured, and the reason
// no bracket span is modelled anywhere in this file: SQLite does NOT honour
// a doubled "]]" inside brackets — "SELECT 1 AS [a]]b]" is
// `unrecognized token: "]"` — so a bracket span would end at the first
// "]". Giving up needs none of that.)
//
// The fifth is "/*! ... */" itself, and it is the subtlest of the five
// because the delimiters look symmetrical and are not. MySQL parses an
// executable comment's content as LIVE SQL, which means it honours string
// literals while doing so, so a "*/" written inside a literal does NOT
// close the comment. SQLite reads the same bytes as an ordinary comment
// that closes at the first "*/". Locating the close with a plain
// strings.Index — which is what this function used to do — picks SQLite's
// reading, ends the comment early, and re-arms whatever follows:
//
//	SELECT 1 /*!50000 ' */ -- ' INTO OUTFILE
//	  '/var/lib/mysql-files/p7probe.txt' */
//	  -> stripped to "SELECT 1 /*!50000 ' */  ", because the trailing
//	     "-- ' INTO OUTFILE ... */" then looked like a line comment;
//	     gate ALLOWED it, and MySQL 8.4.11 wrote a 2-byte p7probe.txt
//	     on the database host
//
// No ";" is involved, so MultiStatements=false does not help. The
// underlying fact, measured directly rather than inferred from the
// exploit: "SELECT /*!50000 LENGTH(' */ -- ') AS v */" answers 7 on
// 8.4.11, i.e. MySQL reads the " */ -- " between those quotes as a
// seven-character string literal and keeps looking for the real close.
//
// So "/*!" gets the same give-up as the other four. The content stays
// visible either way — that has always been the point of not stripping it —
// but now so does everything AFTER it, which is where the payload lived.
// Measured after the change: "SELECT /*!50000 1 */" and
// "SELECT /*! SQL_NO_CACHE */ * FROM t" are still allowed, because the
// remainder carries no blocked keyword and no ";", and the payload above is
// rejected on INTO.
//
// KNOWN AND NOT CLOSED: Postgres dollar-quoting. "$$ ... $$" is a string
// literal to Postgres, so the "--" inside one is inert there, while this
// scanner reads it as a comment introducer and deletes the rest of the
// line: "SELECT $$ -- $$ ; DROP TABLE t" strips to "SELECT $$ " and is
// ALLOWED. It is not reachable today, for two reasons that are checked
// rather than assumed: only "mysql", "sqlite" and "mongo" are registered
// with RegisterDriver, so no Postgres connection can be opened at all;
// and on the one SQL engine that could receive the text, MySQL 8.4.11,
// "SELECT $$ -- $$ AS v" is "ERROR 1064 (42000) ... near '$$ -- $$ AS v'"
// (measured). Do not add a sixth give-up arm for it as things stand —
// closing it and adding a Postgres driver belong in the same change, and
// a guard with no engine behind it cannot be tested against one. If a
// Postgres driver is ever registered, this is a bypass on day one.
//
// All five rules were arrived at by construction, not by argument, and not
// one of the five was found by reading the code. The property they
// enforce is checked directly by
// TestStripSQLCommentsNeverDeletesEngineLiveBytes: over inputs generated
// from an alphabet of SQL comment and literal fragments, the set of bytes
// this function deletes must be a subset of the bytes a reference MySQL
// lexer calls dead AND a subset of the bytes a reference SQLite lexer
// calls dead — i.e. it must never delete a byte either engine would have
// executed. Two million inputs were run while this was written; the
// committed test runs 160000 on every `go test`.
func stripSQLComments(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		switch c := s[i]; {
		case c == '\'' || c == '"' || c == '`':
			end := scanQuotedSpan(s, i)
			if scanQuotedSpanEscaped(s, i) != end {
				// The two readings disagree about where this literal
				// ends. Third disagreement, same answer. See the note
				// above.
				b.WriteString(s[i:])
				i = len(s)
				break
			}
			b.WriteString(s[i:end])
			i = end
		case c == '#':
			// A "#" line is a dead comment to MySQL and live text to
			// SQLite and Postgres. Second disagreement, same answer. See
			// the note above.
			b.WriteString(s[i:])
			i = len(s)
		case c == '[':
			// SQLite (and T-SQL) quote identifiers with "[ ... ]"; MySQL
			// has no such span at all. Fourth disagreement, same answer.
			// See the note above.
			b.WriteString(s[i:])
			i = len(s)
		case startsLineComment(s, i):
			b.WriteByte(' ')
			i = scanToLineEnd(s, i)
		case c == '-' && i+1 < len(s) && s[i+1] == '-' && i+2 < len(s) && s[i+2] != '\n':
			// startsLineComment said no, so the byte after "--" is not an
			// introducer: MySQL reads this as arithmetic and SQLite and
			// Postgres read the whole rest of the line as a comment. First
			// disagreement, same answer. See the note above.
			b.WriteString(s[i:])
			i = len(s)
		case c == '/' && i+1 < len(s) && s[i+1] == '*' && i+2 < len(s) && s[i+2] == '!':
			// MySQL parses an executable comment's content as LIVE SQL and
			// therefore honours string literals inside it, so a "*/" within
			// a literal does not close it; SQLite reads the same bytes as
			// an ordinary comment closing at the first "*/". Fifth
			// disagreement, same answer. See the note above.
			b.WriteString(s[i:])
			i = len(s)
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			rel := strings.Index(s[i+2:], "*/")
			if rel == -1 {
				b.WriteString(s[i:])
				i = len(s)
				break
			}
			b.WriteByte(' ')
			i = i + 2 + rel + 2
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String()
}

// AssertSQLReadOnly allows only a single read statement: SELECT, EXPLAIN,
// SHOW, or WITH (a read-only CTE). This is Phase 1's core safety gate — an
// LLM drives the tools that call this, so this function is the only thing
// standing between a generated query and a destructive write against a
// real database. There is no override.
//
// It works in three passes over the input:
//
//  1. Strip dead comment spans, in the SINGLE literal-aware left-to-right
//     pass in stripSQLComments. This used to be two independent, sequential
//     passes — block comments, then line comments — and an earlier version
//     of this comment claimed that being unaware of string literals could
//     only make the gate over-reject. That claim was FALSE, and it was
//     false in the direction that matters. Measured against this code
//     before the rewrite:
//
//     SELECT '/*' ; DROP TABLE t -- */
//
//     stripped to "SELECT ' " and was ALLOWED. The "/*" inside the string
//     literal opened a block comment for the stripper that no engine opens,
//     and it swallowed the ";" and the DROP. The same shape worked with a
//     "/*" written inside a "--" or "#" comment; both were reproduced end
//     to end against the live MySQL 8.4.11 acceptance container, one of
//     them writing a file on the database host. So pass 1 under-rejected,
//     and literal-awareness is now REQUIRED — not to hide literal contents
//     from the checks (they are copied verbatim and still scanned) but to
//     decide where a comment can legally START. See stripSQLComments for
//     what it removes, what it copies verbatim ("#" lines, quoted spans,
//     and MySQL's live "/*! ... */"), and why "SELECT 1--1 INTO OUTFILE
//     '/x'" is arithmetic rather than a comment (startsLineComment).
//
//  2. Reject anything after a statement separator (";"), other than a
//     single trailing one, and reject anything that isn't a SELECT/
//     EXPLAIN/SHOW/WITH statement.
//
//  3. Reject any occurrence, anywhere in the remaining text, of a keyword
//     in writeKeyword — this catches CTEs that end in a write (WITH x AS
//     (...) DELETE ...) and writes hidden behind comments, since the scan
//     runs on the already-stripped text. SHOW statements use a narrowed
//     keyword list for this pass (see below); every other prefix uses the
//     full writeKeyword list unmodified.
//
// SHOW carve-out (fix rounds 1 and 2): SHOW CREATE TABLE/VIEW/..., SHOW
// GRANTS, and SHOW CHARACTER SET are ordinary read statements, but each
// contains a substring (CREATE, GRANT, and SET respectively) that would
// otherwise be flagged by the keyword scan. Rather than exempting SHOW
// statements from the scan entirely — which would let a real write
// keyword like DELETE or DROP pass straight through a SHOW-prefixed
// string with no comment trick or semicolon needed (fix round 1's
// finding) — statements whose leading keyword is SHOW are handled as
// follows before the scan:
//
//  1. The exact phrase "CHARACTER SET" (tolerant of arbitrary whitespace
//     between the words) is blanked out of the text handed to the scan.
//     This is positional: it removes only that phrase, so a bare SET
//     anywhere else (e.g. "SHOW SET x=1") is untouched and still matches.
//  2. The scan then runs with showSafeWriteKeyword, which is writeKeyword
//     minus exactly CREATE and GRANT.
//
// Every other blocked keyword remains active, so "SHOW DELETE FROM t",
// "SHOW DROP TABLE t", "SHOW SET x=1", and "SHOW UPSERT t (x) VALUES (1)"
// are all still rejected. The multiple-statement guard in pass 2 has
// already run regardless, so "SHOW x; DELETE y" is rejected before this
// pass is even reached.
//
// How this interacts with the /*! */ handling above — stated precisely,
// because an earlier version of this comment claimed it "composes
// correctly" and that claim was too broad. For every keyword the carve-out
// does NOT remove, composition does hold: "SHOW /*!50000 DELETE FROM t */
// TABLES" is rejected, because DELETE is still in showSafeWriteKeyword.
// For the two keywords the carve-out DOES remove, it does not:
//
//	SHOW/*!50000 GRANT ALL ON *.* TO 'x'@'%' */    <- ALLOWED by this gate
//	SHOW/*!50000 CREATE TABLE zz (a int) */        <- ALLOWED by this gate
//
// Both were run end to end against the live MySQL 8.4.11 used for
// acceptance, through go-sql-driver, and neither had any effect:
//
//	both -> Error 1064 (42000): You have an error in your SQL syntax ...
//	        near 'GRANT ALL ON *.* TO 'x'@'%' */' / near '(a int) */'
//	afterwards: user 'x' did not exist, table zz did not exist
//
// The reason is the ENGINE'S PARSER, not this gate, and that distinction
// is the whole point of writing it down. MySQL splices an executable
// comment's contents inline, so the spliced result must still parse as one
// statement whose leading keyword is SHOW — and MySQL's SHOW grammar
// contains no form with an effect. "SHOW GRANT ALL ON ..." is not a
// statement; "SHOW CREATE TABLE customers" is, and it is a read.
//
// AN EARLIER VERSION OF THIS PARAGRAPH GOT THE NEXT STEP WRONG, and the
// correction is not cosmetic. It said "reaching an effectful statement
// would need a second statement, which needs a ';'". That is false: MySQL
// has effectful SINGLE statements, and "SELECT ... INTO OUTFILE '/x'" is
// one — no ";" anywhere, and it writes a file on the database host. That
// exact shape, hidden behind an executable comment, was the seventh bypass
// of this gate (see the fifth disagreement in stripSQLComments). Any
// argument of the form "it would need a ';'" is unsound here.
//
// What actually keeps this carve-out narrow is two things, both checked:
//
//  1. The carve-out removes CREATE and GRANT and NOTHING ELSE. INTO is
//     still in showSafeWriteKeyword, so "SHOW /*!50000 ... INTO OUTFILE
//     '/x' */" is refused by the keyword scan. The parser argument below
//     is a second lock, not the first one.
//
//  2. MySQL's SHOW grammar has no effectful form to reach even when the
//     scan is satisfied. Measured on the live 8.4.11 used for acceptance,
//     with the effect checked afterwards rather than assumed from the
//     error text:
//
//     SHOW TABLES INTO OUTFILE '/var/lib/mysql-files/show_probe.txt'
//     -> Error 1064; no file was created
//     SHOW/*!50000 GRANT ALL ON *.* TO 'x'@'%' */
//     -> Error 1064; user 'x' still absent
//     SHOW/*!50000 CREATE TABLE zz (a int) */
//     -> Error 1064; table zz still absent
//     SHOW CREATE TABLE customers        -> works, and is a read
//
// The ";" route is separately closed — pass 2 now scans the whole verbatim
// remainder after a "/*!", so "SELECT 1 /*!50000; DROP TABLE t*/" is
// caught, and go-sql-driver refuses multiple statements anyway
// (hardenMySQLConfig forces MultiStatements off) — but that is a third
// lock and not the reason this is safe. Also probed and found equally
// inert: "SHOW TABLES /*!50000 GRANT ... */",
// "SHOW/*!50000 CHARACTER SET GLOBAL general_log=1 */",
// "SHOW/*!00000 GRANT ... */ TABLES" — all Error 1064, nothing executed.
//
// So this is a known, measured over-permission with no known exploit, kept
// because narrowing it means giving up SHOW CREATE / SHOW GRANTS. If
// anyone ever finds a statement of this shape that MySQL both accepts and
// acts on, that is a bypass of the whole gate and the carve-out has to go,
// not be patched.
//
// This carve-out is an enumerated list (CREATE, GRANT, and the positional
// CHARACTER-SET phrase), not a generalised allowlist of SHOW sub-forms —
// do not widen it to one. The set of SHOW forms that collide with a
// blocked keyword is finite and was derived by walking MySQL's SHOW
// grammar: only SHOW CREATE {DATABASE|EVENT|FUNCTION|PROCEDURE|TABLE|
// TRIGGER|VIEW|USER}, SHOW GRANTS, and SHOW CHARACTER SET collide. Every
// other documented SHOW form (TABLES, COLUMNS, INDEX, STATUS, VARIABLES,
// PROCESSLIST, ENGINE, WARNINGS, ERRORS, TRIGGERS, EVENTS, COLLATION,
// PRIVILEGES, PLUGINS, PROFILE/PROFILES, BINARY LOGS, BINLOG EVENTS,
// RELAYLOG EVENTS, MASTER STATUS, REPLICA STATUS, SLAVE STATUS, OPEN
// TABLES, TABLE STATUS, PROCEDURE CODE, DATABASES, ...) contains no
// blocked keyword and needs no carve-out at all. If a future engine
// version introduces a new SHOW form that collides with a blocked
// keyword, add it here as its own enumerated, positional exception —
// never by exempting SHOW from the scan in general, and never by trying
// to allowlist every valid SHOW shape (there are dozens, and an allowlist
// would need constant upkeep and would over-reject as engines add more).
//
// Known, accepted limitation: passes 2 and 3 are a textual scan, not a
// SQL parser. A write keyword or a ";" that appears inside a quoted string
// literal — e.g. SELECT * FROM t WHERE action = 'DELETE', or
// SELECT 'a;b' — is rejected even though the statement is actually a read.
// This is deliberate. For a safety gate whose entire job is standing
// between a generated query and a real database, a false rejection is an
// acceptable cost and a false acceptance is not.
//
// Note precisely what pass 1 does and does not do about literals, because
// an earlier version of this paragraph said "do NOT fix this by teaching
// the gate to skip contents inside string literals" and that instruction,
// read as written, is what left the "SELECT '/*' ; DROP TABLE t -- */"
// hole open. Two different things were being conflated:
//
//   - SKIPPING literal contents — hiding them from passes 2 and 3 — is
//     still forbidden, and is still what the paragraph above is about.
//     stripSQLComments copies every quoted span VERBATIM, so a ";" or a
//     DELETE inside one is as visible to the scan as it ever was.
//   - RECOGNISING where a literal begins and ends is REQUIRED, and pass 1
//     now does it, because a comment introducer written inside a literal
//     must not open a comment span that DELETES live SQL. Not recognising
//     it was a bypass, not a conservative simplification.
//
// If deeper analysis is ever wanted, it belongs in a real SQL parser used
// in addition to, not instead of, this scan.
func AssertSQLReadOnly(sql string) error {
	clean := strings.TrimSpace(stripSQLComments(sql))
	if clean == "" {
		return UserError("empty query")
	}
	// Reject anything after a statement separator (ignoring a trailing ";").
	trimmed := strings.TrimRight(clean, "; \t\n")
	if strings.Contains(trimmed, ";") {
		return UserError("multiple statements are not allowed in read-only mode")
	}
	upper := strings.ToUpper(strings.TrimSpace(trimmed))
	if !(strings.HasPrefix(upper, "SELECT") || strings.HasPrefix(upper, "EXPLAIN") ||
		strings.HasPrefix(upper, "SHOW") || strings.HasPrefix(upper, "WITH")) {
		return UserError("only SELECT/EXPLAIN/SHOW queries are allowed (read-only)")
	}
	m := firstKeyword.FindStringSubmatch(upper)
	scanText := trimmed
	kw := writeKeyword
	if len(m) == 2 && m[1] == "SHOW" {
		// Blank out the one positional exception (the exact phrase
		// "CHARACTER SET") before scanning, so its SET doesn't match; a
		// bare SET anywhere else in the statement is untouched.
		scanText = showCharacterSetPhrase.ReplaceAllString(trimmed, " ")
		kw = showSafeWriteKeyword
	}
	if kw.MatchString(scanText) {
		return UserError("query contains a write operation and was blocked (read-only)")
	}
	return nil
}

// SQLReadIsPageable reports whether a read AssertSQLReadOnly has already
// accepted can survive being wrapped in a subquery, which is how Wakil
// applies LIMIT/OFFSET and a pushed ORDER BY to a statement it did not
// write (see sqlConn.pageWrap).
//
// It is deliberately the same prefix test AssertSQLReadOnly makes, minus
// two verbs. That gate accepts four: SELECT, WITH, EXPLAIN and SHOW. The
// first two are expressions and nest; the last two are statements and do
// not. Measured on sqlite and MySQL 8 in docs/wakil/phase-2c-ii-probe.md
// §2: "SELECT * FROM (SHOW TABLES) AS wakil_page" is a syntax error on
// MySQL and "SELECT * FROM (EXPLAIN ...) AS wakil_page" is one on both.
//
// This is not a second opinion about what is safe to run — it decides
// nothing about safety and must never be used to. AssertSQLReadOnly is
// the only gate; this function only says whether an already-permitted
// read can be paged, so that a caller can hide a page control instead of
// handing the operator the engine's raw syntax error.
func SQLReadIsPageable(sql string) bool {
	clean := strings.TrimSpace(stripSQLComments(sql))
	trimmed := strings.TrimRight(clean, "; \t\n")
	upper := strings.ToUpper(strings.TrimSpace(trimmed))
	return strings.HasPrefix(upper, "SELECT") || strings.HasPrefix(upper, "WITH")
}

// SQLReadListsTables reports whether sql is a bare table listing whose rows
// name tables in this connection's own database — which is what lets a
// caller offer a drill on the result without inferring anything from the
// shape of the rows.
//
// It normalises exactly as SQLReadIsPageable and AssertSQLReadOnly do, and
// for the same reason: a statement the gate accepted must not be judged
// here on different text.
//
// Deliberately narrow. SHOW FULL TABLES returns a second column, and
// SHOW TABLES FROM other names a database the drill would not open — both
// would make a drill that opens the wrong thing, which is a worse failure
// than a drill that is absent. A narrow rule that is always right beats a
// broad one that is usually right.
//
// Like SQLReadIsPageable, this decides nothing about safety and must never
// be used to. AssertSQLReadOnly is the only gate.
func SQLReadListsTables(sql string) bool {
	clean := strings.TrimSpace(stripSQLComments(sql))
	trimmed := strings.TrimRight(clean, "; \t\n")
	upper := strings.ToUpper(strings.TrimSpace(trimmed))
	return upper == "SHOW TABLES"
}

// AssertHTTPReadOnly allows only GET and HEAD requests. Method matching is
// case-insensitive; any other value (including the empty string) is
// rejected, with no override.
func AssertHTTPReadOnly(method string) error {
	switch strings.ToUpper(method) {
	case "GET", "HEAD":
		return nil
	default:
		return UserError("only GET/HEAD requests are allowed in read-only mode")
	}
}

// --- Mongo read-only gate (Task 12). ---
//
// Mongo has no SQL text to scan: a "query" here is a JSON operation
// document — {"collection":..., "op":..., "filter":...} for a find, or
// {"collection":..., "op":"aggregate", "pipeline":[...]} for an
// aggregation. The gate below is therefore structural rather than
// textual: it decodes the document once and checks the declared op
// against an allowlist of read-only ops, then walks any aggregation
// pipeline for the two stages ($out, $merge) that write data despite
// living inside an "aggregate" call.

// mongoReadOps is the allowlist of operations AssertMongoReadOnly permits.
// Every other op name — including ones not listed here at all, such as a
// driver method Wakil doesn't yet support for reads — is rejected by
// default; this is an allowlist, not a blocklist, so a new write-shaped
// op added to some future Mongo version is rejected automatically rather
// than requiring this list to be kept in sync with every write op Mongo
// ships.
var mongoReadOps = map[string]bool{"find": true, "aggregate": true, "count": true, "distinct": true}

// mongoSpec is the decoded shape of QuerySpec.Raw for the "mongo" driver.
type mongoSpec struct {
	Collection string           `json:"collection"`
	Op         string           `json:"op"`
	Filter     json.RawMessage  `json:"filter,omitempty"`
	Pipeline   []map[string]any `json:"pipeline,omitempty"`
}

// parseMongo decodes raw into a mongoSpec, rejecting invalid JSON and
// specs missing the two fields every op needs (collection, op) — both as
// a UserError, since raw here can originate from an LLM-generated tool
// argument and this is a human-facing rejection, not an internal fault.
func parseMongo(raw string) (mongoSpec, error) {
	var m mongoSpec
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		return m, UserError("invalid mongo query JSON: " + err.Error())
	}
	if m.Collection == "" || m.Op == "" {
		return m, UserError("mongo query needs collection and op")
	}
	return m, nil
}

// validateMongoQuery parses raw and applies the read-only gate to it in a
// single pass, returning the parsed mongoSpec alongside the gate result so
// a caller that also needs the parsed document (mongoConn.Read) can reuse
// this one parse instead of unmarshaling raw a second time. Two
// independent parses of the same input is a divergence class worth
// eliminating outright: it would otherwise be possible for the gate to
// see one interpretation of raw and the executor a different one.
// AssertMongoReadOnly is the public wrapper for callers that only need
// the error.
func validateMongoQuery(raw string) (mongoSpec, error) {
	m, err := parseMongo(raw)
	if err != nil {
		return m, err
	}
	if !mongoReadOps[m.Op] {
		return m, UserError("mongo op " + m.Op + " is a write and was blocked (read-only)")
	}
	if key, found := findWriteStageKey(m.Pipeline); found {
		if key == "$out" {
			return m, UserError("aggregate $out writes data and was blocked (read-only)")
		}
		return m, UserError("aggregate $merge writes data and was blocked (read-only)")
	}
	return m, nil
}

// findWriteStageKey scans an aggregation pipeline recursively — not just
// the top-level stage keys — for "$out" or "$merge", and reports which one
// it found first. Either stage writes data even when it appears nested
// inside a sub-pipeline (e.g. $unionWith's "pipeline" field, $facet's
// per-branch pipelines, or $lookup's "pipeline" field). MongoDB's server
// currently rejects $out/$merge in those nested positions too, but this
// gate does not depend on that holding forever: relying on the current
// set of server-side restrictions, rather than checking for the
// dangerous stage ourselves wherever it might appear, is exactly the
// posture that required three separate bypass-hardening rounds on the SQL
// gate above.
func findWriteStageKey(pipeline []map[string]any) (string, bool) {
	for _, stage := range pipeline {
		if key, found := scanForWriteKey(stage); found {
			return key, true
		}
	}
	return "", false
}

// scanForWriteKey walks a decoded JSON value (as produced by
// encoding/json's default decoding into `any`: maps become map[string]any,
// arrays become []any) at any depth, looking for a map key of "$out" or
// "$merge". It returns as soon as it finds one, so pipelines with no
// write stage anywhere pay the cost of a full walk while ones with an
// early write stage return quickly.
func scanForWriteKey(v any) (string, bool) {
	switch t := v.(type) {
	case map[string]any:
		if _, ok := t["$out"]; ok {
			return "$out", true
		}
		if _, ok := t["$merge"]; ok {
			return "$merge", true
		}
		for _, val := range t {
			if key, found := scanForWriteKey(val); found {
				return key, true
			}
		}
	case []any:
		for _, item := range t {
			if key, found := scanForWriteKey(item); found {
				return key, true
			}
		}
	}
	return "", false
}

// AssertMongoReadOnly allows only find/aggregate/count/distinct
// operations, and — for aggregate — rejects any pipeline that contains a
// $out or $merge stage at any depth (see findWriteStageKey). This is
// Phase 1's Mongo safety gate, with the same no-override posture as
// AssertSQLReadOnly: an LLM drives the tools that call this, so it is the
// only thing standing between a generated query document and a
// destructive write against a real Mongo deployment.
func AssertMongoReadOnly(raw string) error {
	_, err := validateMongoQuery(raw)
	return err
}
