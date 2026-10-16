package wakilcore

import (
	"regexp"
	"strings"
)

// mutationVerbs is the complete allowlist of statements AssertSQLMutation
// permits. It is three entries, and it is short on purpose.
//
// Invariant 6 ("read-only until a write earns its way in") says writes are
// added per adapter with deliberate justification, never by default. Row
// mutation has been justified — it is the subject Phase 2b-iii's write gate
// exists to gate. Schema mutation has not been justified anywhere, and must
// not arrive as a side effect of the first row mutation, so every DDL verb
// is refused here rather than merely undocumented.
//
// TRUNCATE is the entry most likely to be argued back in, and is the one to
// argue hardest about: it reads like a DELETE and is not one. In MySQL it is
// DDL, it is not transactional (so it cannot be rolled back), it resets
// AUTO_INCREMENT, and it cannot take a WHERE clause at all — which means
// MutationAffectsEveryRow below could not warn about it even in principle.
var mutationVerbs = map[string]bool{
	"INSERT": true,
	"UPDATE": true,
	"DELETE": true,
}

// outfileKeyword matches MySQL's two file-writing SELECT suffixes.
//
// This is belt-and-braces and is recorded as such. It was NOT proven
// reachable from an INSERT/UPDATE/DELETE prefix — MySQL rejects
// "INSERT ... SELECT ... INTO OUTFILE" at parse time — and it is not the
// primary defence either, since hardenMySQLWriteConfig forces
// AllowAllFiles off, which is what stops the SERVER asking this host for
// files. It costs one regexp scan and closes the question instead of
// leaving it argued.
var outfileKeyword = regexp.MustCompile(`(?i)\bINTO\s+(OUT|DUMP)FILE\b`)

// whereKeyword matches a WHERE token. Used ONLY by
// MutationAffectsEveryRow, never by the gate.
var whereKeyword = regexp.MustCompile(`(?i)\bWHERE\b`)

// AssertSQLMutation reports whether sql is a statement this adapter is
// willing to execute against a writable connection.
//
// WHY THIS NEEDS NO KEYWORD SCAN, WHERE AssertSQLReadOnly DOES.
// AssertSQLReadOnly must scan the whole statement after its prefix check,
// because a statement legitimately beginning SELECT can still write —
// "SELECT 1 INTO OUTFILE" is the documented case and drove three of that
// function's five hardening rounds. This gate has no equivalent hole: with
// ";" refused here and MultiStatements forced off in
// hardenMySQLWriteConfig, a statement beginning INSERT/UPDATE/DELETE is
// exactly one statement of that verb, and the writes it can perform are
// precisely the writes the operator is being asked to confirm. The
// outfileKeyword scan below is the one exception, and see its comment for
// why it is not load-bearing.
//
// It shares stripSQLComments with the read gate deliberately: that scanner
// is the genuinely hard-won part of readonly.go, hardened across five
// documented bypasses, and a second comment-stripper would be a second
// thing to get wrong.
func AssertSQLMutation(sql string) error {
	clean := strings.TrimSpace(stripSQLComments(sql))
	if clean == "" {
		return UserError("empty statement")
	}
	trimmed := strings.TrimRight(clean, "; \t\n")
	if strings.Contains(trimmed, ";") {
		return UserError("multiple statements are not allowed in a mutation")
	}
	if outfileKeyword.MatchString(trimmed) {
		return UserError("writing to a file is not allowed")
	}
	m := firstKeyword.FindStringSubmatch(strings.TrimSpace(trimmed))
	if len(m) != 2 || !mutationVerbs[strings.ToUpper(m[1])] {
		return UserError("only INSERT/UPDATE/DELETE statements are allowed; " +
			"schema changes (CREATE/DROP/ALTER/TRUNCATE/RENAME/GRANT) are not")
	}
	return nil
}

// MutationAffectsEveryRow reports whether an UPDATE or DELETE carries no
// WHERE clause, and therefore touches every row in its table.
//
// ADVISORY ONLY. Its sole consumer is the confirmation surface, which
// renders "no WHERE clause — this affects every row" beside the statement.
// It NEVER refuses anything, and nothing may make it do so. That is the
// whole design: a wrong answer here produces a missing or a spurious
// warning, never a blocked legitimate write — and never an unwarned
// dangerous one that the operator was not already shown the full statement
// for. Wakil does not second-guess a deliberate "DELETE FROM sessions"; it
// makes sure the operator read it.
//
// INSERT is never flagged: it adds rows and cannot affect existing ones,
// so the warning would be meaningless.
//
// It strips comments first, so a WHERE that survives only inside a comment
// does not suppress the warning.
func MutationAffectsEveryRow(sql string) bool {
	clean := strings.TrimSpace(stripSQLComments(sql))
	m := firstKeyword.FindStringSubmatch(clean)
	if len(m) != 2 {
		return false
	}
	switch strings.ToUpper(m[1]) {
	case "UPDATE", "DELETE":
		return !whereKeyword.MatchString(clean)
	default:
		return false
	}
}
