package wakilcore

// This file holds one test: a differential check that stripSQLComments
// never deletes a byte a target engine would have executed.
//
// It exists because SIX separate bypasses of stripSQLComments have been the
// same mistake — the stripper's idea of where a comment span begins or ends
// diverging from an engine's — and reading the code caught none of them.
// Each was live, and each was found by running something rather than by
// thinking about it:
//
//	SELECT 1--1 INTO OUTFILE '...'                    (fixed in 567fc08)
//	SELECT 1 -- /* \n INTO OUTFILE '...' \n -- */      (and its "#" spelling)
//	SELECT 'a\' -- ' INTO OUTFILE '...'                (backslash)
//	SELECT 1--/* \n ; ATTACH ... \n -- */              (non-introducer --)
//	SELECT 1 AS [a-- ];ATTACH ...                     (bracket identifier)
//	SELECT 1 /*!50000 ' */ -- ' INTO OUTFILE '...' */  (exec-comment close)
//
// Example-based tests only cover the shapes someone thought of; this one
// covers the property directly, over generated input. It found two of the
// six itself — and missed two others, which is why its limits are spelled
// out below rather than left to be discovered again.

import (
	"math/rand"
	"strings"
	"testing"
)

// deadSpan is a half-open byte range [a, b) that a stripper replaces.
type deadSpan struct{ a, b int }

func spanLineEnd(s string, i int) int {
	if n := strings.IndexByte(s[i:], '\n'); n >= 0 {
		return i + n
	}
	return len(s)
}

// --- The scanner under test, mirrored. ---

// stripperDeadSpans mirrors stripSQLComments' control flow and reports the
// spans it replaces. It is a duplicate of that logic, which would normally
// be a liability — so rebuildFromDeadSpans below is applied to every
// generated input and its result compared against the real
// stripSQLComments. A mirror that has drifted fails loudly as "mirror
// diverged" rather than silently weakening the property being tested.
func stripperDeadSpans(s string) []deadSpan {
	var out []deadSpan
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '\'' || c == '"' || c == '`':
			end := scanQuotedSpan(s, i)
			if scanQuotedSpanEscaped(s, i) != end {
				return out // gave up: nothing after this is stripped
			}
			i = end
		case c == '#':
			return out // gave up
		case c == '[':
			return out // gave up
		case startsLineComment(s, i):
			e := spanLineEnd(s, i)
			out = append(out, deadSpan{i, e})
			i = e
		case c == '-' && i+1 < len(s) && s[i+1] == '-' && i+2 < len(s) && s[i+2] != '\n':
			return out // gave up
		case c == '/' && i+1 < len(s) && s[i+1] == '*' && i+2 < len(s) && s[i+2] == '!':
			return out // gave up
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			rel := strings.Index(s[i+2:], "*/")
			if rel == -1 {
				return out // unterminated: remainder copied verbatim
			}
			end := i + 2 + rel + 2
			out = append(out, deadSpan{i, end})
			i = end
		default:
			i++
		}
	}
	return out
}

func rebuildFromDeadSpans(s string, dead []deadSpan) string {
	var b strings.Builder
	i := 0
	for _, d := range dead {
		b.WriteString(s[i:d.a])
		b.WriteByte(' ')
		i = d.b
	}
	b.WriteString(s[i:])
	return b.String()
}

// --- The two engine references. ---
//
// Both are written out longhand and call NOTHING in readonly.go. That is
// deliberate and it is the point of the file: an earlier version of this
// test reused startsLineComment and scanQuotedSpan, so an error in either
// of those was invisible to the reference by construction — the reference
// made the same mistake in the same place and the subset check still
// passed. Every rule below therefore restates the engine's behaviour from
// the probes recorded in readonly.go's comments, not from the production
// code.

// mysqlScanQuoted returns the index just past the literal starting at i,
// as MySQL 8 reads it under the default sql_mode: a backslash escapes the
// next byte inside '...' and "..." (measured: LENGTH('a\' -- ') is 6), and
// a doubled quote closes and reopens. Backticks are identifier quotes
// where backslash is NOT special, only doubling.
func mysqlScanQuoted(s string, i int) int {
	q := s[i]
	esc := q != '`'
	for j := i + 1; j < len(s); j++ {
		if esc && s[j] == '\\' {
			j++
			continue
		}
		if s[j] != q {
			continue
		}
		if j+1 < len(s) && s[j+1] == q {
			j++
			continue
		}
		return j + 1
	}
	return len(s)
}

// mysqlIntroducesLineComment states MySQL's OWN "--" rule, which is wider
// than the production class in startsLineComment: MySQL accepts any
// whitespace or control character including newline and DEL (0x7f, probed
// on 8.4.11), where production deliberately excludes both. Stating the
// wider rule here is what lets this test notice a production class that
// has been widened past MySQL's.
func mysqlIntroducesLineComment(s string, i int) bool {
	if i+1 >= len(s) || s[i] != '-' || s[i+1] != '-' {
		return false
	}
	if i+2 == len(s) {
		return true
	}
	c := s[i+2]
	return c <= 0x20 || c == 0x7f
}

// mysqlExecCommentEnd returns the index just past the "*/" that closes the
// executable comment starting at i, found THE WAY MYSQL FINDS IT: MySQL
// parses "/*! ... */" content as live SQL, so string literals inside it are
// honoured and a "*/" written inside one does not terminate the comment.
//
// This is stated here independently, and it is the whole reason the
// function exists. The previous version of this reference located the close
// with the same naive strings.Index the scanner used, so reference and
// scanner made the identical mistake in the same place and the subset check
// passed on
//
//	SELECT 1 /*!50000 ' */ -- ' INTO OUTFILE '/var/lib/mysql-files/p7probe.txt' */
//
// which really did write a file on the server. Measured on MySQL 8.4.11:
// "SELECT /*!50000 LENGTH(' */ -- ') AS v */" answers 7, i.e. the " */ -- "
// between the quotes is a seven-character literal and not a terminator.
//
// Returns -1 when no "*/" appears outside a literal, which is a statement
// MySQL rejects; the caller then treats the remainder as live.
//
// KNOWN LIMIT OF THIS MODEL: it honours literals inside the content but not
// comments. MySQL would also treat a "-- x" or "#" inside an executable
// comment as a comment when hunting for the close. That is not modelled
// because production now gives up at "/*!" and so deletes nothing after it,
// which means the gap cannot produce a false alarm here — but it does mean
// this reference is a lower bound on MySQL's parse, not a replica of it.
func mysqlExecCommentEnd(s string, i int) int {
	for j := i + 3; j < len(s); {
		switch c := s[j]; {
		case c == '\'' || c == '"' || c == '`':
			j = mysqlScanQuoted(s, j)
		case c == '*' && j+1 < len(s) && s[j+1] == '/':
			return j + 2
		default:
			j++
		}
	}
	return -1
}

// mysqlDeadSpans is the reference for MySQL 8 under the default sql_mode:
// "#" is a comment, "--" needs an introducer, "/*! ... */" is LIVE rather
// than a comment, and "[" is not special at all (measured:
// "SELECT 1 AS [a]" is ERROR 1064).
func mysqlDeadSpans(s string) []deadSpan {
	var out []deadSpan
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '\'' || c == '"' || c == '`':
			i = mysqlScanQuoted(s, i)
		case c == '#':
			e := spanLineEnd(s, i)
			out = append(out, deadSpan{i, e})
			i = e
		case mysqlIntroducesLineComment(s, i):
			e := spanLineEnd(s, i)
			out = append(out, deadSpan{i, e})
			i = e
		case c == '/' && i+1 < len(s) && s[i+1] == '*' && i+2 < len(s) && s[i+2] == '!':
			// Executable comment: every byte of it is LIVE to MySQL, so
			// nothing is recorded dead. Only the position it ends at
			// matters, and that is literal-aware.
			end := mysqlExecCommentEnd(s, i)
			if end == -1 {
				return out // MySQL errors; treat the remainder as live
			}
			i = end
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			rel := strings.Index(s[i+2:], "*/")
			if rel == -1 {
				return out // unterminated: MySQL errors; treat as live
			}
			end := i + 2 + rel + 2
			out = append(out, deadSpan{i, end})
			i = end
		default:
			i++
		}
	}
	return out
}

// sqliteScanQuoted is SQLite's literal rule: doubling closes and reopens,
// a backslash is an ordinary character (measured: LENGTH('a\') is 2).
func sqliteScanQuoted(s string, i int) int {
	q := s[i]
	for j := i + 1; j < len(s); j++ {
		if s[j] != q {
			continue
		}
		if j+1 < len(s) && s[j+1] == q {
			j++
			continue
		}
		return j + 1
	}
	return len(s)
}

// sqliteScanBracket is SQLite's "[ ... ]" identifier quote. It ends at the
// FIRST "]": measured, "SELECT 1 AS [a]]b]" is `unrecognized token: "]"`,
// so there is no "]]" doubling to honour. An unterminated span runs to end
// of input.
func sqliteScanBracket(s string, i int) int {
	if n := strings.IndexByte(s[i+1:], ']'); n >= 0 {
		return i + 1 + n + 1
	}
	return len(s)
}

// sqliteDeadSpans is the reference for SQLite: no backslash escapes, no
// "#" comment, "[ ... ]" IS an identifier quote, "--" introduces a comment
// unconditionally, every "/*" is a dead comment (there is no "/*!"
// carve-out), and an unterminated "/*" runs to end of input.
func sqliteDeadSpans(s string) []deadSpan {
	var out []deadSpan
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '\'' || c == '"' || c == '`':
			i = sqliteScanQuoted(s, i)
		case c == '[':
			i = sqliteScanBracket(s, i)
		case c == '-' && i+1 < len(s) && s[i+1] == '-':
			e := spanLineEnd(s, i)
			out = append(out, deadSpan{i, e})
			i = e
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			rel := strings.Index(s[i+2:], "*/")
			end := len(s)
			if rel >= 0 {
				end = i + 2 + rel + 2
			}
			out = append(out, deadSpan{i, end})
			i = end
		default:
			i++
		}
	}
	return out
}

func deadMask(s string, spans []deadSpan) []bool {
	m := make([]bool, len(s))
	for _, d := range spans {
		for k := d.a; k < d.b && k < len(s); k++ {
			m[k] = true
		}
	}
	return m
}

// TestStripSQLCommentsNeverDeletesEngineLiveBytes checks the property that
// makes this gate sound: whatever stripSQLComments removes should be dead
// to every engine Wakil targets. Removing a byte one engine executes is how
// all six bypasses listed at the top of this file worked.
//
// The check is a subset test on byte positions: the set stripSQLComments
// deletes must be contained in the set mysqlDeadSpans calls dead, AND in
// the set sqliteDeadSpans calls dead. Note the direction — the references
// may call MORE bytes dead than production does (that is over-rejection,
// the safe side, and not an error here); the failure is deleting anything
// they call LIVE.
//
// WHAT THIS DOES AND DOES NOT GUARANTEE, stated precisely because an
// earlier version of this comment claimed the stronger thing:
//
//   - It does NOT prove "never deletes a byte either engine would have
//     executed". It proves the weaker "never deletes a byte MY MODEL of
//     either engine calls dead".
//   - The references no longer share code with the scanner, and no longer
//     share its idea of where an executable comment ends. Both of those
//     were true before and both let a real bypass through.
//
// FIVE CLASSES OF BYPASS THIS TEST STILL CANNOT FIND. Two have already got
// past it, so this list is written from experience rather than caution, and
// it is the first thing to extend when a sixth appears.
//
//  1. A construct BOTH the scanner and a reference model wrongly, in the
//     same way. This is the one that has bitten twice: bracket identifiers
//     (neither knew SQLite had such a span) and the executable-comment
//     close (both located it with the same non-literal-aware search). A
//     reference written from the same mental model as the scanner cannot
//     find the scanner's blind spots, and "I wrote them separately" is not
//     the same as "I was right twice". Note one such gap is KNOWN and open
//     right now: mysqlExecCommentEnd honours literals inside an executable
//     comment but not comments, which MySQL also honours.
//  2. A construct with no fragment in frags below. It is generated input,
//     not exhaustive input. Postgres dollar-quoting is deliberately absent
//     (a KNOWN unclosed gap — see stripSQLComments — so including it would
//     make this permanently red rather than a regression guard), and
//     nothing here produces E'...' , N'...' , _utf8'...' or multi-byte
//     quoting.
//  3. Anything about an engine with no reference here at all. There are
//     two references and Wakil names three SQL engines; Postgres has none.
//     If a Postgres driver is ever registered this test says nothing about
//     it.
//  4. Any bypass that is not a DELETION. The subset check only ever asks
//     what stripSQLComments removed. It is blind to every later pass in
//     AssertSQLReadOnly: a hole in the SHOW carve-out, a verb missing from
//     writeKeyword, a mistake in the ";" scan, or a keyword the
//     \b-anchored regex fails to see in text that was correctly KEPT.
//     Three of this gate's earlier fix rounds were in that territory.
//  5. Engine drift. The references encode MySQL 8.4.11 under its DEFAULT
//     sql_mode and one build of modernc.org/sqlite. NO_BACKSLASH_ESCAPES,
//     ANSI_QUOTES, a different server version or a different SQLite build
//     can change what is true without changing a line of this file, and
//     the test will keep passing.
//
// So: a pass here is evidence, not proof, and the way to strengthen it is
// to widen the alphabet and correct the references when an engine surprises
// someone — not to relax the check.
//
// The alphabet is deliberately made of comment and literal punctuation
// rather than realistic SQL: the interesting inputs are the ambiguous ones,
// and realistic queries never reach the branches that broke. Run at two
// million inputs while this was being written; the count here is trimmed so
// the default suite stays fast.
func TestStripSQLCommentsNeverDeletesEngineLiveBytes(t *testing.T) {
	frags := []string{
		"SELECT", " ", "1", "--", "-- ", "\n", "/*", "*/", "/*!", "#", "'", `"`, "`",
		"\\", ";", "DELETE", "t", "INTO", "\t", "''", "x", "*", "/", "-", "'/*'", `\'`,
		"/*!50000", "--\n", `\"`, "``", `""`, "\x00", "ATTACH", "'--'", "#/*", "*/;",
		"[", "]", "[a-- ]", "[a", "]]", "AS", "\x7f",
		"/*! ' */", "' */ ", "/*!50000 ' */", "' */ -- '", "*/ ", "OUTFILE", "'*/'",
	}
	for seed := 1; seed <= 4; seed++ {
		rng := rand.New(rand.NewSource(int64(seed)))
		for iter := 0; iter < 40000; iter++ {
			var b strings.Builder
			for k := 1 + rng.Intn(12); k > 0; k-- {
				b.WriteString(frags[rng.Intn(len(frags))])
			}
			q := b.String()

			ours := stripperDeadSpans(q)
			if got, want := rebuildFromDeadSpans(q, ours), stripSQLComments(q); got != want {
				t.Fatalf("mirror diverged from stripSQLComments on %q:\n mirror %q\n real   %q\n"+
					"stripperDeadSpans must be updated to match stripSQLComments", q, got, want)
			}
			om := deadMask(q, ours)
			for engine, ref := range map[string][]deadSpan{
				"MySQL":  mysqlDeadSpans(q),
				"SQLite": sqliteDeadSpans(q),
			} {
				rm := deadMask(q, ref)
				for k := range om {
					if om[k] && !rm[k] {
						t.Fatalf("stripSQLComments deleted byte %d (%q) of %q, which %s treats as LIVE SQL\n"+
							"  stripped to %q", k, q[k], q, engine, stripSQLComments(q))
					}
				}
			}
		}
	}
}
